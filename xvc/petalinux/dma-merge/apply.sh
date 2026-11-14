#!/bin/bash
# Install the dma-proxy module recipe and DT node into a PetaLinux project.
#
#   ./apply.sh ~/work/xvc_dma
#
# Run inside the VM (the build VM), where the repo is visible through the
# VirtualBox shared folder. The project must already have been configured with
# a hardware description that contains the AXI DMA (so `&dma` exists in
# system-conf.dtsi); this script does not import an XSA.
set -euo pipefail

PROJ=${1:?usage: $0 <petalinux-project-dir>}
HERE=$(cd "$(dirname "$0")" && pwd)
KERNEL_DIR=$(cd "$HERE/../../kernel" && pwd)

PROJ=$(cd "$PROJ" && pwd)
MU=$PROJ/project-spec/meta-user
RECIPE=$MU/recipes-modules/dma-proxy

[ -d "$MU" ] || { echo "not a PetaLinux project: $PROJ" >&2; exit 1; }

echo "== recipe =="
mkdir -p "$RECIPE/files"
install -m 0644 "$KERNEL_DIR/dma-proxy.bb" "$RECIPE/dma-proxy.bb"
install -m 0644 "$KERNEL_DIR/dma-proxy.c"  "$RECIPE/files/dma-proxy.c"
install -m 0644 "$KERNEL_DIR/dma-proxy.h"  "$RECIPE/files/dma-proxy.h"
install -m 0644 "$KERNEL_DIR/Makefile"     "$RECIPE/files/Makefile"

echo "== device tree =="
install -m 0644 "$HERE/system-user.dtsi" \
    "$MU/recipes-bsp/device-tree/files/system-user.dtsi"

echo "== image install =="
IMG=$MU/recipes-core/images/petalinux-image-minimal.bbappend
touch "$IMG"
grep -q 'kernel-module-dma-proxy' "$IMG" || \
    printf '\nIMAGE_INSTALL:append = " kernel-module-dma-proxy"\n' >> "$IMG"

echo "== autoload =="
echo "KERNEL_MODULE_AUTOLOAD is set inside the recipe; nothing to do here."

echo
echo "Done. Rebuild with:"
echo "  source /opt/Xilinx/petalinux/2023.1/settings.sh"
echo "  cd $PROJ && petalinux-build && petalinux-package --boot --u-boot --force"
