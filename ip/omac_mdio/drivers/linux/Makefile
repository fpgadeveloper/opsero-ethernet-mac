# SPDX-License-Identifier: GPL-2.0-only OR MIT
# Copyright (C) 2026, Opsero Electronic Design Inc.
#
# Out-of-tree build of the omac_mdio MDIO bus driver (omac_mdio.ko).
#
#   make KERNEL_SRC=<configured kernel tree or kernel build dir> [ARCH=arm64 CROSS_COMPILE=<prefix>]
#   make KERNEL_SRC=... modules_install [INSTALL_MOD_PATH=<rootfs>]
#
# Yocto (module.bbclass) passes KERNEL_SRC, O, CC, LD, ... itself. The kernel needs
# CONFIG_PHYLIB and CONFIG_OF_MDIO (both set wherever a MAC driver uses phylib).

KERNEL_SRC ?= /lib/modules/$(shell uname -r)/build
SRC := $(shell pwd)

all: modules

modules:
	$(MAKE) -C $(KERNEL_SRC) M=$(SRC) modules

modules_install:
	$(MAKE) -C $(KERNEL_SRC) M=$(SRC) modules_install

clean:
	$(MAKE) -C $(KERNEL_SRC) M=$(SRC) clean

.PHONY: all modules modules_install clean
