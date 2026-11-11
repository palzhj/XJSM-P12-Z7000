# Console access for bring-up:
#  - root gets a password that YOU set below (no credential ships in this repo)
#  - an unprivileged 'xvc' user exists (securetty only restricts root)
#  - root login is allowed on the Zynq PS UART (ttyPS0)
#
# ⚠️ BEFORE BUILDING: set your own passwords.
#    1) Generate a SHA-512 hash for each account:
#         openssl passwd -6 '<your-root-password>'
#         openssl passwd -6 '<your-xvc-password>'
#    2) Paste each hash into EXTRA_USERS_PARAMS below.
#    3) Escape every '$' as '\$' — bitbake expands $VAR, which would otherwise
#       mangle the hash and silently produce an unusable password.
#
# The placeholders below are deliberately invalid hashes: the image still builds
# and boots, but neither account can log in until you set real ones. That is the
# safe default — it is better to ship an image nobody can log into than one with
# a published password.
inherit extrausers
EXTRA_USERS_PARAMS = "usermod -p '\$6\$REPLACE_ME_SALT\$REPLACE_ME_HASH' root; useradd -m -s /bin/sh -p '\$6\$REPLACE_ME_SALT\$REPLACE_ME_HASH' xvc;"

ROOTFS_POSTPROCESS_COMMAND:append = " fix_securetty;"
fix_securetty() {
    [ -f ${IMAGE_ROOTFS}/etc/securetty ] || touch ${IMAGE_ROOTFS}/etc/securetty
    grep -qx ttyPS0 ${IMAGE_ROOTFS}/etc/securetty || echo ttyPS0 >> ${IMAGE_ROOTFS}/etc/securetty
    grep -qx ttyPS1 ${IMAGE_ROOTFS}/etc/securetty || echo ttyPS1 >> ${IMAGE_ROOTFS}/etc/securetty
}
