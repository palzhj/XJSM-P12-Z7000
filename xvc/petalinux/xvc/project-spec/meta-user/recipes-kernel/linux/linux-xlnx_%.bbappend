FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI:append = " file://bsp.cfg file://xvc.cfg"
KERNEL_FEATURES:append = " bsp.cfg xvc.cfg"
