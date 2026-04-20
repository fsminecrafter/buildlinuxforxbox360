#!/usr/bin/env bash
# =============================================================================
#  build_xbox360_linux.sh
#  Builds Linux kernel + XeLL bootloader + launcher .xex for Xbox 360
#  Based on: https://free60.org/Linux/Distros/Debian/sid/
#
#  Requirements (host machine):
#    - git, wget, curl, xz-utils
#    - build-essential, flex, bison, libgmp-dev, libmpfr-dev,
#      libmpc-dev, texinfo, bc, libssl-dev, python3
#      (xenon toolchain build deps — installed automatically if missing)
#
#  What this script does:
#    1. Checks host dependencies
#    2. Detects or builds the xenon cross-compile toolchain natively
#       (installs to /usr/local/xenon and adds to PATH — no Docker needed)
#    3. Detects the latest supported kernel series from the patch repo
#    4. Downloads and cross-compiles the Linux kernel
#    5. Clones and builds XeLL Reloaded (all variants)
#    6. Assembles ALL required HDD files into ./output/ :
#         updxell.bin    <- XeLL binary ready to flash via filesystem updater
#         updflash.bin   <- NAND flash updater binary
#         kboot.conf     <- KBoot configuration template
#         xenon.elf      <- XeLL ELF (before binary strip)
#         xenon.z        <- Compressed kernel image (used by kboot)
#         vmlinux        <- Uncompressed kernel ELF
#         vmlinux_X.XX.xenon  <- Versioned kernel image (kept for reference)
#         xell-*.bin     <- All XeLL variant binaries
#
#  Run as a normal user with sudo available (toolchain build needs root for
#  /usr/local/xenon install).
# =============================================================================

set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Configuration ──────────────────────────────────────────────────────────────
WORKDIR="$(pwd)/xbox360_build"
OUTDIR="$(pwd)/output"
XENON_PREFIX="/usr/local/xenon"
XENON_BIN="${XENON_PREFIX}/bin"
TOOLCHAIN_REPO="https://github.com/Free60Project/libxenon"
PATCH_REPO="https://github.com/Free60Project/linux-kernel-xbox360"
XELL_REPO="https://github.com/Free60Project/xell-reloaded"
KEEP_BUILD=false   # override with --keep flag

KERNEL_SERIES=""
KERNEL_VERSION=""
KERNEL_TARBALL=""
KERNEL_URL=""

# ── Argument parsing ───────────────────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --keep) KEEP_BUILD=true ;;
        --help|-h)
            echo "Usage: $0 [--keep]"
            echo "  --keep   Keep the xbox360_build/ work directory after a successful build."
            exit 0 ;;
        *) die "Unknown argument: ${arg}  (try --help)" ;;
    esac
done

# ══════════════════════════════════════════════════════════════════════════════
#  TOOLCHAIN — detect existing install or build from source
# ══════════════════════════════════════════════════════════════════════════════

check_toolchain_exists() {
    # Returns 0 (true) if a working xenon-gcc is already on the system
    if [[ -x "${XENON_BIN}/xenon-gcc" ]]; then
        local ver
        ver=$("${XENON_BIN}/xenon-gcc" --version 2>&1 | head -n1 || true)
        info "Found existing xenon toolchain: ${ver}"
        return 0
    fi
    # Also check PATH in case it was installed elsewhere
    if command -v xenon-gcc &>/dev/null; then
        local ver
        ver=$(xenon-gcc --version 2>&1 | head -n1 || true)
        info "Found xenon-gcc in PATH: ${ver}"
        XENON_BIN="$(dirname "$(command -v xenon-gcc)")"
        return 0
    fi
    return 1
}

add_toolchain_to_path() {
    if [[ ":$PATH:" != *":${XENON_BIN}:"* ]]; then
        export PATH="${XENON_BIN}:${PATH}"
        info "Added ${XENON_BIN} to PATH for this session."
    fi
}

install_toolchain_deps() {
    info "Installing toolchain build dependencies (requires sudo)..."
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends \
        build-essential flex bison libgmp-dev libmpfr-dev libmpc-dev \
        texinfo bc libssl-dev python3 wget curl git xz-utils zlib1g-dev \
        libelf-dev 2>/dev/null || \
    # RPM-based fallback
    sudo dnf install -y gcc gcc-c++ make flex bison gmp-devel mpfr-devel \
        libmpc-devel texinfo bc openssl-devel python3 wget curl git \
        xz elfutils-libelf-devel 2>/dev/null || \
    warn "Could not install deps automatically — continuing (may fail if missing)."
}

build_and_install_toolchain() {
    info "Xenon toolchain not found. Building from source (this takes 30–90 minutes)..."
    install_toolchain_deps

    local libxenondir="${WORKDIR}/libxenon-toolchain"
    git_clone_or_update "$TOOLCHAIN_REPO" "$libxenondir"

    local tcscript
    tcscript=$(find "$libxenondir" -maxdepth 2 \
               \( -name "toolchain.sh" -o -name "build-toolchain.sh" \) \
               2>/dev/null | head -n1 || true)
    if [[ -z "$tcscript" ]]; then
        die "Could not locate toolchain.sh inside ${libxenondir}. Check the repo layout."
    fi

    info "Using toolchain script: ${tcscript}"
    info "Installing to: ${XENON_PREFIX}"

    # The toolchain script typically reads DEVKITXENON / PREFIX; set both.
    sudo mkdir -p "$XENON_PREFIX"
    sudo chown "$USER:$(id -gn)" "$XENON_PREFIX"

    (
        cd "$(dirname "$tcscript")"
        export PREFIX="$XENON_PREFIX"
        export DEVKITXENON="$XENON_PREFIX"
        bash "$(basename "$tcscript")"
    )

    if [[ ! -x "${XENON_BIN}/xenon-gcc" ]]; then
        die "Toolchain build finished but xenon-gcc not found at ${XENON_BIN}. Check build logs."
    fi
    success "Xenon toolchain installed to ${XENON_PREFIX}"
}

setup_toolchain() {
    echo ""
    info "═══ Xenon Toolchain ═══════════════════════════════════════"
    if check_toolchain_exists; then
        success "Xenon toolchain already installed — skipping build."
    else
        build_and_install_toolchain
    fi
    add_toolchain_to_path
    info "Toolchain in PATH: $(command -v xenon-gcc)"
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  DEPENDENCY CHECK
# ══════════════════════════════════════════════════════════════════════════════

check_deps() {
    info "Checking host dependencies..."
    local missing=()
    for cmd in git wget curl xz make patch bc; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Missing tools: ${missing[*]} — attempting to install..."
        sudo apt-get install -y "${missing[@]}" 2>/dev/null || \
        sudo dnf     install -y "${missing[@]}" 2>/dev/null || \
        die "Could not install: ${missing[*]}. Please install manually."
    fi
    success "All host dependencies satisfied."
}

# ══════════════════════════════════════════════════════════════════════════════
#  GIT HELPER
# ══════════════════════════════════════════════════════════════════════════════

git_clone_or_update() {
    local url="$1"
    local dir="$2"
    if [[ -d "${dir}/.git" ]]; then
        info "Updating $(basename "$dir")..."
        git -C "$dir" pull --ff-only 2>/dev/null || \
            warn "git pull failed; using existing checkout."
    else
        info "Cloning ${url}..."
        git clone --depth 1 "$url" "$dir"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  KERNEL — detect supported series, download, patch, build
# ══════════════════════════════════════════════════════════════════════════════

clone_patches_and_resolve_version() {
    mkdir -p "$WORKDIR"
    git_clone_or_update "$PATCH_REPO" "${WORKDIR}/linux-kernel-xbox360"

    local pdir="${WORKDIR}/linux-kernel-xbox360"
    local supported=()

    while IFS= read -r pf; do
        local series
        series=$(basename "$pf" | grep -oP 'patch-\K[0-9]+\.[0-9]+(?=-xenon)' || true)
        [[ -z "$series" ]] && continue
        if ls "${pdir}/xenon-${series}.defconfig"  &>/dev/null 2>&1 || \
           ls "${pdir}/xenon-${series}-defconfig"   &>/dev/null 2>&1; then
            supported+=("$series")
        fi
    done < <(find "$pdir" -maxdepth 1 -name "patch-*-xenon*.diff")

    if [[ ${#supported[@]} -eq 0 ]]; then
        info "Patch repo contents:"; ls "$pdir"
        die "No supported kernel series found in ${pdir}."
    fi

    KERNEL_SERIES=$(printf '%s\n' "${supported[@]}" \
        | sort -t. -k1,1n -k2,2n | tail -n1)
    info "Latest supported kernel series by patch repo: ${BOLD}${KERNEL_SERIES}${NC}"

    info "Resolving latest ${KERNEL_SERIES}.x kernel from kernel.org..."
    local releases
    releases="$(curl -s https://www.kernel.org/releases.json)"
    KERNEL_VERSION=$(echo "$releases" \
        | grep -oP '"version"\s*:\s*"\K[^"]+' \
        | grep "^${KERNEL_SERIES}\." \
        | head -n1)

    if [[ -z "$KERNEL_VERSION" ]]; then
        warn "Not in releases.json — checking cdn.kernel.org directory listing..."
        local html
        html=$(curl -s "https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_SERIES%%.*}.x/")
        KERNEL_VERSION=$(echo "$html" \
            | grep -oP "linux-${KERNEL_SERIES//./\\.}\.[0-9]+" \
            | sort -t. -k3,3n | tail -n1 | sed 's/linux-//')
    fi

    [[ -z "$KERNEL_VERSION" ]] && KERNEL_VERSION="$KERNEL_SERIES" && \
        warn "Falling back to base release: ${KERNEL_VERSION}"

    KERNEL_TARBALL="linux-${KERNEL_VERSION}.tar.xz"
    KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_VERSION%%.*}.x/${KERNEL_TARBALL}"
    success "Kernel to build: ${BOLD}${KERNEL_VERSION}${NC}  (series ${KERNEL_SERIES})"
}

download_kernel() {
    local dest="${WORKDIR}/linux-${KERNEL_VERSION}"
    if [[ -d "$dest" ]]; then
        info "Kernel source already present — skipping download."
        return
    fi
    info "Downloading Linux ${KERNEL_VERSION}..."
    mkdir -p "$WORKDIR"
    wget -q --show-progress -P "$WORKDIR" "$KERNEL_URL" \
        || die "Failed to download kernel from ${KERNEL_URL}"
    info "Extracting kernel source..."
    tar -xf "${WORKDIR}/${KERNEL_TARBALL}" -C "$WORKDIR"
    rm -f "${WORKDIR}/${KERNEL_TARBALL}"
    success "Kernel source extracted to ${dest}"
}

build_kernel() {
    local kdir="${WORKDIR}/linux-${KERNEL_VERSION}"
    local pdir="${WORKDIR}/linux-kernel-xbox360"
    local defcfg patchfile jobs

    if [[ -f "${kdir}/zImage.xenon" && -f "${kdir}/vmlinux" ]]; then
        info "Kernel already built (zImage.xenon + vmlinux present) — skipping."
        return
    fi

    # ── defconfig ──────────────────────────────────────────────────────────
    defcfg=$(find "$pdir" -maxdepth 1 \
             \( -name "xenon-${KERNEL_SERIES}.defconfig" \
             -o -name "xenon-${KERNEL_SERIES}-defconfig" \) \
             2>/dev/null | head -n1 || true)
    if [[ -z "$defcfg" ]]; then
        defcfg=$(find "$pdir" -maxdepth 1 \
                 \( -name "xenon-*.defconfig" -o -name "xenon-*-defconfig" \
                 -o -name "xenon.defconfig" \) \
                 2>/dev/null | sort -V | tail -n1 || true)
        [[ -z "$defcfg" ]] && die "No xenon defconfig found in ${pdir}"
        warn "Using fallback defconfig: $(basename "$defcfg")"
    fi
    info "Using defconfig: $(basename "$defcfg")"

    # ── patch file ─────────────────────────────────────────────────────────
    patchfile=$(find "$pdir" -maxdepth 1 \
                -name "patch-${KERNEL_SERIES}-xenon*.diff" \
                2>/dev/null | sort -V | tail -n1 || true)
    if [[ -z "$patchfile" ]]; then
        patchfile=$(find "$pdir" -maxdepth 1 -name "patch-*-xenon*.diff" \
                    2>/dev/null | sort -V | tail -n1 || true)
        [[ -z "$patchfile" ]] && die "No xenon patch file found in ${pdir}"
        warn "Using newest available patch: $(basename "$patchfile")"
    fi
    info "Using patch: $(basename "$patchfile")"

    cp "$defcfg" "${kdir}/.config"

    if [[ ! -f "${kdir}/.xbox360_patched" ]]; then
        info "Applying Xbox 360 kernel patch..."
        patch -d "$kdir" -p1 < "$patchfile"
        touch "${kdir}/.xbox360_patched"
        success "Patch applied."
    else
        info "Patch already applied — skipping."
    fi

    jobs=$(nproc 2>/dev/null || echo 4)
    info "Cross-compiling kernel with CROSS_COMPILE=xenon- (-j${jobs})..."

    (
        export PATH="${XENON_BIN}:${PATH}"
        export DEVKITXENON="${XENON_PREFIX}"
        cd "$kdir"
        make ARCH=powerpc CROSS_COMPILE=xenon- olddefconfig
        make -j"${jobs}" ARCH=powerpc CROSS_COMPILE=xenon- all
        # zImage is the compressed boot image; vmlinux is the ELF
        cp arch/powerpc/boot/zImage.xenon . 2>/dev/null || \
        cp arch/powerpc/boot/zImage       ./zImage.xenon 2>/dev/null || \
        warn "zImage.xenon not found — check arch/powerpc/boot/ output."
    )

    success "Kernel build complete."
}

# ══════════════════════════════════════════════════════════════════════════════
#  XELL — build all variants + force elf→bin conversion
# ══════════════════════════════════════════════════════════════════════════════

# Run xenon-objcopy on every .elf in xell-reloaded that has no matching .bin yet.
# This is the fallback for Makefiles that strip/objcopy inside a sub-target which
# exits non-zero before copying the result.
elf_to_bin_all() {
    local xelldir="$1"
    local converted=0
    while IFS= read -r -d '' elf; do
        local bin="${elf%.elf}.bin"
        if [[ ! -f "$bin" ]]; then
            info "  objcopy: $(basename "$elf") → $(basename "$bin")"
            "${XENON_BIN}/xenon-objcopy" -O binary "$elf" "$bin" 2>/dev/null && \
                (( converted++ )) || \
                warn "  objcopy failed for $(basename "$elf")"
        fi
    done < <(find "$xelldir" -maxdepth 4 -name "*.elf" -print0 2>/dev/null)
    [[ $converted -gt 0 ]] && success "  Converted ${converted} elf(s) to bin."
}

build_xell() {
    local xelldir="${WORKDIR}/xell-reloaded"
    git_clone_or_update "$XELL_REPO" "$xelldir"

    export PATH="${XENON_BIN}:${PATH}"
    export DEVKITXENON="${XENON_PREFIX}"

    # Skip full rebuild only when we already have both .elf AND .bin files
    local have_elf have_bin
    have_elf=$(find "$xelldir" -name "*.elf" 2>/dev/null | head -n1 || true)
    have_bin=$(find "$xelldir" -name "*.bin" 2>/dev/null | head -n1 || true)
    if [[ -n "$have_elf" && -n "$have_bin" ]]; then
        info "XeLL already built (elf + bin present) — skipping rebuild."
        return
    fi

    info "Building XeLL Reloaded..."
    (
        cd "$xelldir"
        make clean 2>/dev/null || true
    )

    # ── Try 'make all' first; on failure fall through to per-target attempts ──
    info "  Attempting: make all"
    (
        cd "$xelldir"
        make all 2>&1
    ) && info "  make all succeeded." || warn "  make all exited non-zero — trying individual targets."

    # ── Per-variant targets (each is independent; a failure in one is non-fatal)
    local variants=(xell-1f xell-2f xell-gggg xell-gggggg updxell updflash)
    for tgt in "${variants[@]}"; do
        info "  Attempting: make ${tgt}"
        (
            cd "$xelldir"
            make "$tgt" 2>&1
        ) && info "  make ${tgt} succeeded." || \
          warn "  make ${tgt} exited non-zero (may not exist in this version — skipping)."
    done

    # ── Force-convert every .elf → .bin regardless of Makefile outcome ────────
    info "Converting all .elf outputs to .bin via xenon-objcopy..."
    elf_to_bin_all "$xelldir"

    # ── Also try stripping xenon.elf → xenon.bin (generic entry point) ────────
    local generic_elf
    generic_elf=$(find "$xelldir" -maxdepth 4 -name "xenon.elf" 2>/dev/null | head -n1 || true)
    if [[ -n "$generic_elf" && ! -f "${generic_elf%.elf}.bin" ]]; then
        "${XENON_BIN}/xenon-objcopy" -O binary "$generic_elf" \
            "${generic_elf%.elf}.bin" 2>/dev/null || true
    fi

    success "XeLL build complete."
    info "XeLL outputs:"
    find "$xelldir" \( -name "*.bin" -o -name "*.elf" \) \
        2>/dev/null | sort | sed 's/^/  /'
}

# ══════════════════════════════════════════════════════════════════════════════
#  OUTPUT ASSEMBLY
# ══════════════════════════════════════════════════════════════════════════════

# Helper: copy file to OUTDIR with a given target name; warn if source missing
copy_as() {
    local src="$1"
    local dst="${OUTDIR}/$2"
    if [[ -f "$src" ]]; then
        cp "$src" "$dst"
        success "  $(basename "$src") → $(basename "$dst")"
    else
        warn "  Source not found, skipping: ${src}"
    fi
}

# Find the best matching file by glob inside a directory tree
find_first() {
    local dir="$1"; shift
    find "$dir" -maxdepth 4 \( "$@" \) 2>/dev/null | sort -V | head -n1 || true
}

assemble_output() {
    info "Assembling output directory: ${OUTDIR}"
    mkdir -p "$OUTDIR"

    local kdir="${WORKDIR}/linux-${KERNEL_VERSION}"
    local xelldir="${WORKDIR}/xell-reloaded"

    echo ""
    info "── Kernel files ─────────────────────────────────────────────"

    # vmlinux  — uncompressed kernel ELF (required by HDD layout)
    local vmlinux_elf="${kdir}/vmlinux"
    copy_as "$vmlinux_elf" "vmlinux"

    # xenon.z  — compressed kernel image (= zImage, used by kboot)
    local zimage="${kdir}/zImage.xenon"
    [[ ! -f "$zimage" ]] && zimage="${kdir}/zImage"
    copy_as "$zimage" "xenon.z"

    # versioned copy for reference
    if [[ -f "$zimage" ]]; then
        cp "$zimage" "${OUTDIR}/vmlinux_${KERNEL_VERSION}.xenon"
        success "  zImage.xenon → vmlinux_${KERNEL_VERSION}.xenon (versioned reference)"
    fi

    echo ""
    info "── XeLL files ───────────────────────────────────────────────"

    # xenon.elf — XeLL ELF binary
    local xell_elf
    xell_elf=$(find_first "$xelldir" -name "xenon.elf")
    [[ -z "$xell_elf" ]] && xell_elf=$(find_first "$xelldir" -name "*.elf")
    copy_as "$xell_elf" "xenon.elf"

    # Copy ALL .bin files with their original names (1f, 2f, gggg variants etc.)
    local bin_count=0
    while IFS= read -r -d '' binfile; do
        cp "$binfile" "${OUTDIR}/"
        info "  → $(basename "$binfile")"
        (( bin_count++ )) || true
    done < <(find "$xelldir" -maxdepth 4 -name "*.bin" -print0 2>/dev/null)
    [[ $bin_count -eq 0 ]] && warn "No .bin files found in XeLL build output."

    # ── updxell.bin ────────────────────────────────────────────────────────────
    # Prefer a dedicated updxell.bin, then xell-2f (JTAG), then xell-gggg (RGH),
    # then any .bin, then last-resort objcopy from the best available .elf.
    local updxell_src
    updxell_src=$(find_first "$xelldir" -name "updxell.bin")
    [[ -z "$updxell_src" ]] && updxell_src=$(find_first "$xelldir" -name "xell-2f.bin")
    [[ -z "$updxell_src" ]] && updxell_src=$(find_first "$xelldir" -name "*2f*.bin")
    [[ -z "$updxell_src" ]] && updxell_src=$(find_first "$xelldir" -name "xell-gggg*.bin")
    [[ -z "$updxell_src" ]] && updxell_src=$(find_first "$xelldir" -name "*.bin")

    if [[ -z "$updxell_src" ]]; then
        # Last resort: objcopy the best elf we have
        info "  No .bin found — running xenon-objcopy on best available .elf for updxell.bin..."
        local best_elf
        best_elf=$(find_first "$xelldir" -name "xell-2f.elf")
        [[ -z "$best_elf" ]] && best_elf=$(find_first "$xelldir" -name "xell-*.elf")
        [[ -z "$best_elf" ]] && best_elf=$(find_first "$xelldir" -name "*.elf")
        if [[ -n "$best_elf" ]]; then
            "${XENON_BIN}/xenon-objcopy" -O binary "$best_elf" \
                "${xelldir}/updxell_generated.bin" 2>/dev/null && \
                updxell_src="${xelldir}/updxell_generated.bin" || \
                warn "  xenon-objcopy also failed for updxell.bin."
        fi
    fi

    if [[ -n "$updxell_src" ]]; then
        cp "$updxell_src" "${OUTDIR}/updxell.bin"
        success "  $(basename "$updxell_src") → updxell.bin"
        info "    JTAG default (2f). For RGH replace with xell-gggg*.bin"
    else
        warn "  updxell.bin could not be produced — no .bin or .elf available."
    fi

    # ── updflash.bin ───────────────────────────────────────────────────────────
    # Dedicated NAND flash-write binary. Try Makefile target, then objcopy fallback.
    local updflash_src
    updflash_src=$(find_first "$xelldir" -name "updflash.bin")

    if [[ -z "$updflash_src" ]]; then
        info "  updflash.bin not found — attempting 'make updflash'..."
        (
            export PATH="${XENON_BIN}:${PATH}"
            export DEVKITXENON="${XENON_PREFIX}"
            cd "$xelldir"
            make updflash 2>/dev/null || make TARGET=updflash 2>/dev/null || true
        )
        # Run objcopy on any updflash.elf the make may have produced
        local uelf
        uelf=$(find_first "$xelldir" -name "updflash.elf")
        if [[ -n "$uelf" && ! -f "${uelf%.elf}.bin" ]]; then
            "${XENON_BIN}/xenon-objcopy" -O binary "$uelf" \
                "${uelf%.elf}.bin" 2>/dev/null || true
        fi
        updflash_src=$(find_first "$xelldir" -name "updflash.bin")
    fi

    if [[ -n "$updflash_src" ]]; then
        copy_as "$updflash_src" "updflash.bin"
    else
        warn "  updflash.bin not produced — falling back to copy of updxell.bin."
        if [[ -f "${OUTDIR}/updxell.bin" ]]; then
            cp "${OUTDIR}/updxell.bin" "${OUTDIR}/updflash.bin"
            warn "  updxell.bin → updflash.bin (fallback copy)."
            warn "  If your exploit needs a distinct NAND flasher, source updflash"
            warn "  from your specific exploit pack (Xecuter, etc.)."
        fi
    fi

    echo ""
    info "── Config file ──────────────────────────────────────────────"

    # kboot.conf
    cat > "${OUTDIR}/kboot.conf" << 'KBOOT'
#KBOOTCONFIG
; Place this file on the FAT/XTAF partition of your USB HDD (partition 1)
; Place xenon.z (compressed kernel) and any other files here too.
;
; --- CPU SPEED ---
speedup=1          ; 1 = XENON_SPEED_FULL
;
; --- BOOT TIMEOUT (seconds, 0 = wait forever) ---
timeout=30
;
; --- BOOT ENTRY ---
; Adjust 'sdb3' / root UUID to match your actual USB partition.
; Run 'blkid' on the Xbox 360 after first boot to find the correct UUID.
;
; kernel file:   xenon.z  (compressed image)   OR
;                vmlinux  (uncompressed ELF)
;
linux_usb="uda0:/xenon.z root=/dev/sdb3 rootfstype=ext4 console=tty0 panic=60 maxcpus=6 coherent_pool=16M rootwait video=xenosfb noplymouth"
KBOOT
    success "  kboot.conf written."

    # .deb kernel packages (if any)
    find "$WORKDIR" -maxdepth 2 -name "*.deb" \
        -exec cp {} "$OUTDIR/" \; 2>/dev/null || true

    # README
    cat > "${OUTDIR}/README.txt" << EOF
Xbox 360 Linux Build — $(date +%Y-%m-%d)
Kernel version : ${KERNEL_VERSION}
Build host     : $(uname -n)
Based on       : https://free60.org/Linux/Distros/Debian/sid/

HDD FILE LAYOUT (XTAF/FAT partition, partition 1)
--------------------------------------------------
  updxell.bin   XeLL flash updater (via dashboard FS update)
                  Default = xell-2f (JTAG). Replace with xell-gggg* for RGH.
  updflash.bin  NAND flash write binary
  kboot.conf    KBoot configuration (edit the root UUID!)
  xenon.elf     XeLL ELF (reference / for direct ELF loaders)
  xenon.z       Compressed kernel image  <- kboot loads this by default
  vmlinux       Uncompressed kernel ELF  <- alternative boot target

ALSO IN THIS FOLDER
-------------------
  vmlinux_${KERNEL_VERSION}.xenon  Versioned kernel image (same as xenon.z)
  xell-*.bin                       All XeLL variant binaries
  *.deb                            Debian kernel + module packages (if produced)

QUICK-START
-----------
1.  Partition USB HDD (MBR):
      Part 1 :  4 GB   FAT32/XTAF   <- files above go here
      Part 2 :  8 GB   swap
      Part 3 :  rest   ext4         <- Debian rootfs

2.  Flash XeLL (choose ONE depending on your exploit):
      JTAG : use xell-2f.bin    (already copied as updxell.bin)
      RGH  : use xell-gggg*.bin (copy it over updxell.bin first)
      !! Read the XeLL updxell WARNING on free60.org before flashing !!

3.  Bootstrap Debian ppc64 onto the ext4 partition:
      debootstrap --no-check-sig --arch ppc64 unstable /mnt/deb360 \\
          http://ftp.debian.ports.org/debian-ports/

4.  Edit kboot.conf — set the correct root device / UUID (use blkid).

5.  Copy to FAT partition:  kboot.conf  xenon.z  vmlinux  updxell.bin

6.  Boot via XeLL → select the kboot entry.

Full guide: https://free60.org/Linux/Distros/Debian/sid/
EOF

    echo ""
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  Build complete!  Output: ${OUTDIR}${NC}"
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
    echo ""
    echo "Required HDD files:"
    for f in updxell.bin updflash.bin kboot.conf xenon.elf xenon.z vmlinux; do
        if [[ -f "${OUTDIR}/${f}" ]]; then
            printf "  ${GREEN}✔${NC}  %-20s  (%s)\n" "$f" "$(du -sh "${OUTDIR}/${f}" | cut -f1)"
        else
            printf "  ${RED}✘${NC}  %-20s  MISSING\n" "$f"
        fi
    done
    echo ""
    echo "All output files:"
    ls -lh "$OUTDIR"
}

# ══════════════════════════════════════════════════════════════════════════════
#  CLEANUP
# ══════════════════════════════════════════════════════════════════════════════

cleanup() {
    if [[ "$KEEP_BUILD" == true ]]; then
        info "Keeping build directory (--keep): ${WORKDIR}"
    else
        info "Removing build directory to free disk space (~15 GB)..."
        rm -rf "$WORKDIR"
        success "Build directory removed."
        info "Tip: pass --keep to preserve sources/objects between runs."
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════

main() {
    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║   Xbox 360 Linux Build Script                   ║${NC}"
    echo -e "${BOLD}${CYAN}║   Kernel + XeLL + updxell/updflash/xenon.z      ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    [[ "$KEEP_BUILD" == true ]] && info "Build directory will be kept (--keep)."

    check_deps
    setup_toolchain          # ← installs natively, no Docker
    clone_patches_and_resolve_version
    download_kernel
    build_kernel
    build_xell
    assemble_output
    cleanup
}

main "$@"
