# Allow root to log in over SSH with a password.
#
# The stock image ships no /etc/ssh/sshd_config, so OpenSSH 9.0 falls back to its
# built-in default, PermitRootLogin prohibit-password, and a password login as
# root is refused even though the account has a valid hash. The board could only
# be reached over the serial console until this file existed.
#
# No credentials live here: the password is set when the image is built.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://sshd_config"

do_install:append() {
    install -d ${D}${sysconfdir}/ssh
    install -m 0600 ${WORKDIR}/sshd_config ${D}${sysconfdir}/ssh/sshd_config
}

# keep the runtime package in step with the config
pkg_postinst:${PN}() {
    #!/bin/sh
    if [ -z "$D" ]; then
        pidof sshd > /dev/null 2>&1 && kill -HUP "$(pidof sshd)" || true
    fi
}
