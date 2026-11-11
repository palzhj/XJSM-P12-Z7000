SUMMARY = "XVC server (12 channels + broadcast)"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://xvcserver_g1.c"
S = "${WORKDIR}"

do_compile() {
    ${CC} ${CFLAGS} ${LDFLAGS} -O2 -Wall -o xvcserver_g1 xvcserver_g1.c
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 xvcserver_g1 ${D}${bindir}/xvcserver_g1
}
