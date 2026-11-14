# Kernel module Makefile for dma-proxy (XVC shift engine).
#
# Yocto/PetaLinux: `inherit module` exports KERNEL_SRC and runs plain `make`,
#   so the default goal below forwards to kbuild. The O=<kernel-build-artifacts>
#   argument reaches this sub-make through MAKEFLAGS, which is what lets kbuild
#   find auto.conf when the source and build trees are separate.
#
# Standalone: make -C <kernel-build-artifacts> M=$PWD modules

obj-m := dma-proxy.o

SRC := $(shell pwd)

all:
	$(MAKE) -C $(KERNEL_SRC) M=$(SRC)

modules_install:
	$(MAKE) -C $(KERNEL_SRC) M=$(SRC) modules_install

clean:
	rm -f *.o *~ core .depend .*.cmd *.ko *.mod.c
	rm -f Module.markers Module.symvers modules.order
	rm -rf .tmp_versions Modules.symvers
