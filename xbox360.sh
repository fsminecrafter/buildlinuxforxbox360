#!/usr/bin/env bash
# =============================================================================
#  build_xbox360_linux.sh
#  Builds Linux kernel + XeLL bootloader + launcher .xex for Xbox 360
#  Based on: https://free60.org/Linux/Distros/Debian/sid/
#
#  Requirements (host machine):
#    - Docker              (used for the xenon cross-compile toolchain)
#    - git, wget, curl     (source fetching)
#    - bc, make, patch     (kernel build helpers, also installed inside Docker)
#    - xz-utils            (kernel tarball extraction)
#
#  What this script does:
#    1. Checks dependencies
#    2. Clones the libxenon toolchain (Docker image)
#    3. Finds and downloads the latest 6.x Linux kernel from kernel.org
#    4. Clones the Free60 Xbox 360 kernel patch set
#    5. Applies patches and cross-compiles the kernel (zImage.xenon + .deb pkgs)
#    6. Clones and builds XeLL Reloaded  -> xell-2f.bin  (JTAG)
#                                           xell-gggggg.bin (RGH)
#    7. Clones and builds the XeLL Launch .xex (dashboard launcher)
#    8. Assembles everything into  ./output/
#
#  Run as a normal user (Docker handles root-level cross-compile work).
#  Do NOT run as root; Docker bind-mounts will be owned by you.
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
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

# ── Configuration ─────────────────────────────────────────────────────────────
WORKDIR="$(pwd)/xbox360_build"
OUTDIR="$(pwd)/output"
KERNEL_SERIES="6.19"
DOCKER_IMAGE="free60/libxenon:latest"
LIBXENON_REPO="https://github.com/Free60Project/libxenon"
PATCH_REPO="https://github.com/Free60Project/linux-kernel-xbox360"
XELL_REPO="https://github.com/Free60Project/xell-reloaded"
KERNEL_ORG="https://kernel.org"

# ── Dependency check ──────────────────────────────────────────────────────────
check_deps() {
    info "Checking host dependencies..."
    local missing=()
    for cmd in docker git wget curl xz make patch bc; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required tools: ${missing[*]}\n       Install them and re-run."
    fi

    # Docker daemon running?
    docker info &>/dev/null || die "Docker daemon is not running. Start it and re-run."
    success "All dependencies satisfied."
}

# ── Resolve the latest 6.x kernel version from kernel.org ─────────────────────
resolve_kernel_version() {
    info "Resolving latest ${KERNEL_SERIES}.x kernel from kernel.org..."
    local releases
    releases="$(curl -s https://www.kernel.org/releases.json)"
    # Extract version matching our series using grep+sed (no jq dependency)
    KERNEL_VERSION=$(echo "$releases" \
        | grep -oP '"version"\s*:\s*"\K[^"]+' \
        | grep "^${KERNEL_SERIES}\." \
        | head -n1)

    if [[ -z "$KERNEL_VERSION" ]]; then
        warn "Could not auto-detect ${KERNEL_SERIES}.x; checking for any 6.x release..."
        KERNEL_VERSION=$(echo "$releases" \
            | grep -oP '"version"\s*:\s*"\K[^"]+' \
            | grep "^6\." \
            | head -n1)
        [[ -z "$KERNEL_VERSION" ]] && die "Could not find a suitable 6.x kernel on kernel.org."
        KERNEL_SERIES=$(echo "$KERNEL_VERSION" | cut -d. -f1-2)
    fi

    KERNEL_TARBALL="linux-${KERNEL_VERSION}.tar.xz"
    KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_VERSION%%.*}.x/${KERNEL_TARBALL}"
    info "Resolved kernel: ${BOLD}${KERNEL_VERSION}${NC}"
}

# ── Pull / update Docker toolchain image ─────────────────────────────────────
setup_toolchain() {
    info "Pulling libxenon Docker image (this may take a while first time)..."
    docker pull "$DOCKER_IMAGE"
    success "Docker toolchain ready."
}

# ── Download and extract kernel sources ───────────────────────────────────────
download_kernel() {
    local dest="${WORKDIR}/linux-${KERNEL_VERSION}"
    if [[ -d "$dest" ]]; then
        info "Kernel source already present at ${dest}, skipping download."
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

# ── Clone or update a git repo ────────────────────────────────────────────────
git_clone_or_update() {
    local url="$1"
    local dir="$2"
    if [[ -d "${dir}/.git" ]]; then
        info "Updating $(basename "$dir")..."
        git -C "$dir" pull --ff-only || warn "git pull failed; using existing checkout."
    else
        info "Cloning ${url}..."
        git clone --depth 1 "$url" "$dir"
    fi
}

# ── Clone patch set ───────────────────────────────────────────────────────────
clone_patches() {
    git_clone_or_update "$PATCH_REPO" "${WORKDIR}/linux-kernel-xbox360"
    success "Xbox 360 kernel patches ready."
}

# ── Apply patches & cross-compile the kernel (inside Docker) ─────────────────
build_kernel() {
    local kdir="${WORKDIR}/linux-${KERNEL_VERSION}"
    local pdir="${WORKDIR}/linux-kernel-xbox360"
    local defcfg

    # Locate the defconfig for our kernel series
    defcfg=$(find "$pdir" -maxdepth 1 -name "xenon-${KERNEL_SERIES}*-defconfig" \
             | sort -V | tail -n1 || true)
    if [[ -z "$defcfg" ]]; then
        # Fall back to any xenon defconfig available
        defcfg=$(find "$pdir" -maxdepth 1 -name "xenon-*-defconfig" \
                 | sort -V | tail -n1 || true)
        [[ -z "$defcfg" ]] && die "No xenon defconfig found in ${pdir}"
        warn "Using fallback defconfig: $(basename "$defcfg")"
    fi
    info "Using defconfig: $(basename "$defcfg")"

    # Find the matching patch file
    local patchfile
    patchfile=$(find "$pdir" -maxdepth 1 -name "patch-${KERNEL_SERIES}*-xenon.diff" \
                | sort -V | tail -n1 || true)
    if [[ -z "$patchfile" ]]; then
        patchfile=$(find "$pdir" -maxdepth 1 -name "patch-*-xenon.diff" \
                    | sort -V | tail -n1 || true)
        [[ -z "$patchfile" ]] && die "No xenon patch file found in ${pdir}"
        warn "Using fallback patch: $(basename "$patchfile")"
    fi
    info "Using patch: $(basename "$patchfile")"

    # Copy config
    cp "$defcfg" "${kdir}/.config"

    # Apply patch (idempotent check)
    if [[ ! -f "${kdir}/.xbox360_patched" ]]; then
        info "Applying Xbox 360 kernel patch..."
        patch -d "$kdir" -p1 < "$patchfile"
        touch "${kdir}/.xbox360_patched"
        success "Patch applied."
    else
        info "Patch already applied, skipping."
    fi

    # Determine CPU jobs
    local jobs
    jobs=$(nproc 2>/dev/null || echo 4)
    info "Building kernel with -j${jobs} inside Docker..."

    # Run inside the libxenon Docker container
    docker run --rm \
        -v "${WORKDIR}:/work" \
        "$DOCKER_IMAGE" \
        bash -c "
            set -e
            apt-get install -yq bc >/dev/null 2>&1 || true
            cd /work/linux-${KERNEL_VERSION}
            make ARCH=powerpc CROSS_COMPILE=xenon- olddefconfig
            make -j${jobs} ARCH=powerpc CROSS_COMPILE=xenon- all
            make -j${jobs} ARCH=powerpc CROSS_COMPILE=xenon- bindeb-pkg || true
            cp arch/powerpc/boot/zImage.xenon .
        "

    success "Kernel build complete."
    info "  zImage.xenon  → ${kdir}/zImage.xenon"
}

# ── Clone and build XeLL Reloaded ─────────────────────────────────────────────
build_xell() {
    local xelldir="${WORKDIR}/xell-reloaded"
    git_clone_or_update "$XELL_REPO" "$xelldir"

    info "Building XeLL Reloaded inside Docker..."
    docker run --rm \
        -v "${xelldir}:/app" \
        "$DOCKER_IMAGE" \
        bash -c "
            set -e
            cd /app
            make clean || true
            make
        "

    success "XeLL build complete."
}

# ── Build XeLL Launch .xex (libxenon sample launcher) ─────────────────────────
build_xex_launcher() {
    # The 'launch' sample in libxenon can load XeLL / other payloads.
    # xell-reloaded also ships a xenon.xex / launch.xex in some builds.
    # We build the standard 'launch' example from libxenon.
    local libxenondir="${WORKDIR}/libxenon"
    git_clone_or_update "$LIBXENON_REPO" "$libxenondir"

    # Check if a pre-built .xex exists from XeLL build
    local xex_src
    xex_src=$(find "${WORKDIR}/xell-reloaded" \
              -maxdepth 3 -name "*.xex" 2>/dev/null | head -n1 || true)

    if [[ -n "$xex_src" ]]; then
        info "Found pre-built .xex from XeLL build: $(basename "$xex_src")"
        cp "$xex_src" "${WORKDIR}/xenon_launch.xex"
        success "Copied .xex launcher."
        return
    fi

    # Build the 'launch' sample from libxenon
    local launchdir
    launchdir=$(find "$libxenondir" -type d -name "launch" 2>/dev/null | head -n1 || true)
    if [[ -z "$launchdir" ]]; then
        warn "No 'launch' sample found in libxenon; building hello_world .xex instead."
        launchdir=$(find "$libxenondir" -type d \
                    \( -name "hello_world" -o -name "helloworld" \) 2>/dev/null | head -n1 || true)
    fi

    if [[ -z "$launchdir" ]]; then
        warn "Could not locate a suitable sample to build as .xex. Skipping."
        return
    fi

    info "Building .xex from: ${launchdir}..."
    docker run --rm \
        -v "${libxenondir}:/libxenon" \
        "$DOCKER_IMAGE" \
        bash -c "
            set -e
            cd /libxenon/$(realpath --relative-to="$libxenondir" "$launchdir")
            make clean || true
            make
        "

    local built_xex
    built_xex=$(find "$launchdir" -name "*.xex" 2>/dev/null | head -n1 || true)
    if [[ -n "$built_xex" ]]; then
        cp "$built_xex" "${WORKDIR}/xenon_launch.xex"
        success "Built .xex launcher: $(basename "$built_xex")"
    else
        warn "No .xex produced; dashboard launcher will need to be sourced separately."
    fi
}

# ── Assemble output directory ─────────────────────────────────────────────────
assemble_output() {
    info "Assembling output directory: ${OUTDIR}"
    mkdir -p "$OUTDIR"

    local kdir="${WORKDIR}/linux-${KERNEL_VERSION}"
    local xelldir="${WORKDIR}/xell-reloaded"

    # ── Kernel
    if [[ -f "${kdir}/zImage.xenon" ]]; then
        cp "${kdir}/zImage.xenon" "${OUTDIR}/vmlinux_${KERNEL_VERSION}.xenon"
        success "Kernel image → ${OUTDIR}/vmlinux_${KERNEL_VERSION}.xenon"
    fi

    # ── .deb packages (kernel + modules)
    find "$WORKDIR" -maxdepth 2 -name "*.deb" -exec cp {} "$OUTDIR/" \; 2>/dev/null || true

    # ── XeLL binaries
    local xell_bins=()
    while IFS= read -r -d '' f; do
        xell_bins+=("$f")
    done < <(find "$xelldir" -maxdepth 3 -name "*.bin" -print0 2>/dev/null)

    if [[ ${#xell_bins[@]} -gt 0 ]]; then
        for bin in "${xell_bins[@]}"; do
            cp "$bin" "$OUTDIR/"
        done
        success "XeLL binaries → ${OUTDIR}/"
    else
        warn "No .bin files found in XeLL build output."
    fi

    # ── .xex launcher
    if [[ -f "${WORKDIR}/xenon_launch.xex" ]]; then
        cp "${WORKDIR}/xenon_launch.xex" "${OUTDIR}/xenon_launch.xex"
        success ".xex launcher → ${OUTDIR}/xenon_launch.xex"
    fi

    # ── kboot.conf template
    cat > "${OUTDIR}/kboot.conf" << 'KBOOT'
#KBOOTCONFIG
; Place this file on the FAT32 partition of your USB HDD (partition 1)
; Place the kernel image (vmlinux_*.xenon renamed to e.g. vmlinux616) here too.
;
; --- VIDEO MODE ---
; videomode=10   ; 10 = HDMI 720p  (see free60.org for full list)
;
; --- CPU SPEED ---
speedup=1        ; 1 = XENON_SPEED_FULL
;
; --- BOOT TIMEOUT (seconds) ---
timeout=30
;
; --- BOOT ENTRY ---
; Adjust 'sdb3' / the root UUID to match your actual USB partition.
; Run 'blkid' on the Xbox 360 after first boot to find the correct UUID.
;
linux_usb="uda0:/vmlinux616 root=/dev/sdb3 rootfstype=ext4 console=tty0 panic=60 maxcpus=6 coherent_pool=16M rootwait video=xenosfb noplymouth"
KBOOT

    success "kboot.conf template written."

    # ── Summary README
    cat > "${OUTDIR}/README.txt" << EOF
Xbox 360 Linux Build — $(date +%Y-%m-%d)
Kernel version : ${KERNEL_VERSION}
Build host     : $(uname -n)
Based on       : https://free60.org/Linux/Distros/Debian/sid/

FILES
-----
vmlinux_${KERNEL_VERSION}.xenon  — Cross-compiled kernel image
*.bin                             — XeLL Reloaded bootloader binaries
xenon_launch.xex                  — XeLL dashboard launcher (.xex)
kboot.conf                        — KBoot configuration template (edit UUIDs!)
*.deb                             — Kernel + modules Debian packages (if built)

INSTALLATION QUICK-STEPS
------------------------
1. Partition your USB HDD (MBR):
     Part 1 : 4 GB   FAT32   <- kboot.conf, kernel, xell.bin go here
     Part 2 : 8 GB   swap
     Part 3 : rest   ext4    <- Debian rootfs

2. Flash XeLL to your console:
     JTAG : rename xell-2f.bin    -> updxell.bin  (or xell.bin)
     RGH  : rename xell-gggggg.bin -> updxell.bin  (or xell.bin)
     !! Read the XeLL updxell WARNING on free60.org before using updxell !!

3. Bootstrap Debian ppc64 (Sid) onto the ext4 partition:
     debootstrap --no-check-sig --arch ppc64 unstable /mnt/deb360 \\
         http://ftp.debian.ports.org/debian-ports/

4. Edit kboot.conf with the correct root UUID (blkid on the Xbox).

5. Place on FAT32 partition:  kboot.conf, vmlinux_*.xenon (rename as needed)

6. Boot via XeLL -> select the kboot entry.

For full instructions see: https://free60.org/Linux/Distros/Debian/sid/
EOF

    echo ""
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  Build complete!  Output directory: ${OUTDIR}${NC}"
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
    echo ""
    ls -lh "$OUTDIR"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║   Xbox 360 Linux Build Script                   ║${NC}"
    echo -e "${BOLD}${CYAN}║   Kernel + XeLL + .xex launcher                 ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""

    check_deps
    resolve_kernel_version
    setup_toolchain
    download_kernel
    clone_patches
    build_kernel
    build_xell
    build_xex_launcher
    assemble_output
}

main "$@"
