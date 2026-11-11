#
# xvcserver - Xilinx Virtual Cable server for the Debug Bridge (UIO)
#
SUMMARY = "Xilinx Virtual Cable (XVC) server for the Debug Bridge"
SECTION = "PETALINUX/apps"
LICENSE = "CC0-1.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/CC0-1.0;md5=0ceb3372c9595f0a8067e55da801e4a1"

SRC_URI = "file://xvcserver.c \
           file://Makefile \
           file://xvcserver.init \
          "

S = "${WORKDIR}"

do_compile() {
    oe_runmake
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 xvcserver ${D}${bindir}
    install -d ${D}${sysconfdir}/init.d
    install -m 0755 ${WORKDIR}/xvcserver.init ${D}${sysconfdir}/init.d/xvcserver
    install -d ${D}${sysconfdir}/rc5.d
    ln -sf ../init.d/xvcserver ${D}${sysconfdir}/rc5.d/S99xvcserver
}
