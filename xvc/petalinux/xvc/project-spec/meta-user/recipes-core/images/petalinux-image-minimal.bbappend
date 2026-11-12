# Console access for bring-up:
#  - root gets a password supplied at BUILD time (no credential ships in this repo)
#  - an unprivileged 'xvc' user exists (securetty only restricts root)
#  - root login is allowed on the Zynq PS UART (ttyPS0)
#
# The password hashes are INJECTED, never committed:
#
#     ./xvc/petalinux/inject_user_passwords.sh [root-pw] [xvc-pw]
#     petalinux-build
#
# That script writes meta-user/conf/secret.conf (gitignored) holding SHA-512
# hashes; the optional include below picks it up. Note the '$' escaping: bitbake
# expands $... in values, so a crypt hash written literally would be mangled
# into an unusable password. The script escapes them for you.
#
# If secret.conf is absent the placeholders are used. They are deliberately
# invalid: the image still builds and boots, but nobody can log in. That is the
# safe default - better an image nobody can log into than one with a published
# password.
include ${THISDIR}/../../conf/secret.conf

XJSM_ROOT_PW_HASH ??= '\$6\$REPLACE_ME_SALT\$REPLACE_ME_HASH'
XJSM_XVC_PW_HASH  ??= '\$6\$REPLACE_ME_SALT\$REPLACE_ME_HASH'

inherit extrausers
EXTRA_USERS_PARAMS = "usermod -p '${XJSM_ROOT_PW_HASH}' root; useradd -m -s /bin/sh -p '${XJSM_XVC_PW_HASH}' xvc;"

ROOTFS_POSTPROCESS_COMMAND:append = " fix_securetty;"
fix_securetty() {
    [ -f ${IMAGE_ROOTFS}/etc/securetty ] || touch ${IMAGE_ROOTFS}/etc/securetty
    grep -qx ttyPS0 ${IMAGE_ROOTFS}/etc/securetty || echo ttyPS0 >> ${IMAGE_ROOTFS}/etc/securetty
    grep -qx ttyPS1 ${IMAGE_ROOTFS}/etc/securetty || echo ttyPS1 >> ${IMAGE_ROOTFS}/etc/securetty
}
