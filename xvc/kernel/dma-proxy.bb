SUMMARY = "Xilinx DMA proxy driver for the XVC JTAG shift engine"
DESCRIPTION = "Character driver that hands the AXI DMA channels behind the XVC \
shift engine to user space as /dev/dma_proxy_tx and /dev/dma_proxy_rx, using \
zero-copy mmapped channel buffers and ioctl start/finish handshakes."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

inherit module

SRC_URI = "file://Makefile \
           file://dma-proxy.c \
           file://dma-proxy.h \
          "

S = "${WORKDIR}"

# Loaded at boot so the XVC server always finds its device nodes.
KERNEL_MODULE_AUTOLOAD += "dma-proxy"

# The split package is kernel-module-dma-proxy-<version>; the meta package below
# is what images and the autoload file reference.
RPROVIDES:${PN} += "kernel-module-dma-proxy"
