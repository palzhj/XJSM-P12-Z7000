# Host is Ubuntu 26.04 (glibc 2.43, GCC 15). m4 1.4.19's bundled gnulib does
# not compile there ([[nodiscard]] placement in gl_list.h), and m4 is only a
# build-time tool. Install the host's GNU m4 (1.4.21) into the native sysroot
# instead of building 1.4.19. Remove this bbappend on a supported host distro.
do_compile() {
    :
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 /usr/bin/m4 ${D}${bindir}/m4
}
