SUMMARY = "XVC status/control helper for web console"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://xvcinfo.c"
S = "${WORKDIR}"

do_compile() {
    ${CC} ${CFLAGS} ${LDFLAGS} -O2 -Wall -o xvcinfo xvcinfo.c
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 xvcinfo ${D}${bindir}/xvcinfo
}
