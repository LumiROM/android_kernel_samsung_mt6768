#!/usr/bin/env bash
#
# LumiROM kernel build script for Samsung MT6768 devices.
#
# Usage:
#   ./build_kernel.sh [device]
#
# If no device is provided, the script asks for one interactively.
#
# Environment:
#   TC   Path to the Clang toolchain (default: $HOME/zyc-clang).
#
# Recommended toolchain:
#   ZyC Clang 14
#   https://github.com/ZyCromerZ/Clang/releases/tag/14.0.6-20250704-release
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

usage() {
    echo "Usage: $0 [device]"
    echo "Supported devices: a32, a22, f22, m22 (experimental), m32 (experimental)"
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
esac

# On Ubuntu 25.10, if libxml2.so.2 is missing, create the compatibility symlink:
#   sudo ln -s /lib/x86_64-linux-gnu/libxml2.so.16 /lib/x86_64-linux-gnu/libxml2.so.2

TC="${TC:-$HOME/zyc-clang}"

if [ ! -x "$TC/bin/clang" ]; then
    echo "error: Clang toolchain not found at $TC" >&2
    echo "Set TC to the toolchain directory, for example:" >&2
    echo "  TC=/path/to/clang $0 a32" >&2
    exit 1
fi

export CROSS_COMPILE="$TC/bin/aarch64-linux-gnu-"
export LD="$TC/bin/ld.lld"
export OBJCOPY="$TC/bin/llvm-objcopy"
export AS="$TC/bin/llvm-as"
export NM="$TC/bin/llvm-nm"
export STRIP="$TC/bin/llvm-strip"
export OBJDUMP="$TC/bin/llvm-objdump"
export READELF="$TC/bin/llvm-readelf"
export CC="$TC/bin/clang"
export ARCH=arm64

export KCFLAGS=' -w -pipe -O3'
export KCPPFLAGS=' -O3'
export CONFIG_SECTION_MISMATCH_WARN_ONLY=y

CFGDIR="arch/arm64/configs"
OUT_DIR="$SCRIPT_DIR/out"

choice="${1:-}"
if [ -z "$choice" ]; then
    usage
    read -r -p "Device: " choice
fi

case "${choice,,}" in
    a32) DEVICE=a32 ;;
    a22) DEVICE=a22 ;;
    f22) DEVICE=f22 ;;
    m22) DEVICE=m22 ;;
    m32) DEVICE=m32 ;;
    *)
        echo "error: unsupported device '$choice'" >&2
        exit 1
        ;;
esac

export DEVICE

if [ ! -f "$CFGDIR/$DEVICE.config" ]; then
    echo "error: device config not found: $CFGDIR/$DEVICE.config" >&2
    exit 1
fi

rm -f "$CFGDIR/compiled_defconfig"

echo "Cleaning build directory..."
make -C "$SCRIPT_DIR" O="$OUT_DIR" clean -j"$(nproc)"
make -C "$SCRIPT_DIR" O="$OUT_DIR" mrproper -j"$(nproc)"

# Build configuration:
# - Use battery.config instead of perf.config to disable performance tweaks.
# - Do not use both at the same time.
# - Optional: append $CFGDIR/ksu.config to enable KernelSU.
#
# Example (battery-oriented build with KernelSU):
#   cat "$CFGDIR/mt6768_slm_defconfig" "$CFGDIR/$DEVICE.config" \
#       "$CFGDIR/battery.config" "$CFGDIR/ksu.config" > "$CFGDIR/compiled_defconfig"
cat "$CFGDIR/mt6768_slm_defconfig" "$CFGDIR/$DEVICE.config" "$CFGDIR/battery.config" > "$CFGDIR/compiled_defconfig"

# SELinux and GPU driver configuration.
# Supported GPU drivers: mali bifrost r25p0, mali valhall r32p1,
# mali avalon r49p1 (work in progress).
cat >> "$CFGDIR/compiled_defconfig" <<'EOF'
CONFIG_ALWAYS_ENFORCE=y
# CONFIG_ALWAYS_PERMISSIVE is not set

CONFIG_MTK_GPU_VERSION="mali bifrost r25p0"

# BTF is disabled because pahole 1.32 cannot generate BTF for this 4.14 kernel.
# CONFIG_DEBUG_INFO_BTF is not set
# CONFIG_DEBUG_INFO_BTF_MODULES is not set
EOF

echo "Configuring kernel for $DEVICE..."
make -C "$SCRIPT_DIR" O="$OUT_DIR" -j"$(nproc)" compiled_defconfig

echo "Building kernel..."
make -s -C "$SCRIPT_DIR" O="$OUT_DIR" -j"$(nproc)"

IMAGECHECK="$OUT_DIR/arch/arm64/boot/Image"
if [ ! -f "$IMAGECHECK" ]; then
    echo "error: kernel image not found: $IMAGECHECK" >&2
    exit 1
fi

echo "Kernel built successfully for $DEVICE"
echo "  Image:    $IMAGECHECK"
echo "  Image.gz: $OUT_DIR/arch/arm64/boot/Image.gz"

GPU_VER="$(sed -n 's/^CONFIG_MTK_GPU_VERSION="\([^"]*\)"/\1/p' "$OUT_DIR/.config")"
if [ "$GPU_VER" != "mali bifrost r25p0" ]; then
    echo
    echo "warning: non-stock GPU driver selected: $GPU_VER" >&2
    echo "Flash a vendor image with the matching Mali userspace libraries and a" >&2
    echo "boot image with the corresponding DTS changes, or the device may bootloop." >&2
    echo
fi
