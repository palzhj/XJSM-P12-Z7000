#
# oled_ip - show the board IP on the 0.96" SSD1315 I2C OLED
#
SUMMARY = "SSD1315 OLED IP display"
SECTION = "PETALINUX/apps"
LICENSE = "CC0-1.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/CC0-1.0;md5=0ceb3372c9595f0a8067e55da801e4a1"

# Bitbake derives PN/PV from the recipe filename and splits on "_", so
# oled_ip.bb would parse as PN=oled, PV=ip and "bitbake oled_ip" could never
# resolve. Pin both here rather than renaming the recipe.
PN = "oled_ip"
PV = "0.1"

SRC_URI = "file://oled_ip.c \
           file://Makefile \
           file://oled_ip.init \
          "

S = "${WORKDIR}"

do_compile() {
    oe_runmake
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 oled_ip ${D}${bindir}
    install -d ${D}${sysconfdir}/init.d
    install -m 0755 ${WORKDIR}/oled_ip.init ${D}${sysconfdir}/init.d/oled_ip
    install -d ${D}${sysconfdir}/rc5.d
    ln -sf ../init.d/oled_ip ${D}${sysconfdir}/rc5.d/S98oled_ip
}
