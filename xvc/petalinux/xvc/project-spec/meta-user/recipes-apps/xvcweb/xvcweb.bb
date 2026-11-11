SUMMARY = "XVC web console (static pages + init script)"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "\
    file://www \
    file://xvcweb.init \
"
S = "${WORKDIR}"

do_install() {
    install -d ${D}${datadir}/xvcweb/www/cgi-bin
    install -m 0644 ${WORKDIR}/www/index.html ${D}${datadir}/xvcweb/www/
    install -m 0755 ${WORKDIR}/www/cgi-bin/status  ${D}${datadir}/xvcweb/www/cgi-bin/
    install -m 0755 ${WORKDIR}/www/cgi-bin/control ${D}${datadir}/xvcweb/www/cgi-bin/

    install -d ${D}${sysconfdir}/init.d
    install -m 0755 ${WORKDIR}/xvcweb.init ${D}${sysconfdir}/init.d/xvcweb
    install -d ${D}${sysconfdir}/rc5.d
    ln -sf ../init.d/xvcweb ${D}${sysconfdir}/rc5.d/S99xvcweb
}

FILES:${PN} += "${datadir}/xvcweb ${sysconfdir}/init.d ${sysconfdir}/rc5.d"
