# SpacemiT K3 Firmware Build System
# Based on: https://github.com/openeuler-riscv/bootloader-build/blob/master/.github/workflows/spacemit-k3.yml

ARCH           := riscv
NPROC          ?= $(shell nproc)
CROSS_COMPILE  ?= riscv64-linux-gnu-
BARE_CROSS     ?= riscv64-unknown-elf-
BARE_TOOLCHAIN_URL ?= https://archive.spacemit.com/toolchain/spacemit-toolchain-elf-newlib-x86_64-v1.2.4.tar.xz
BARE_TOOLCHAIN_DIR := $(CURDIR)/toolchain/spacemit-toolchain-elf-newlib-x86_64-v1.2.4
RTT_EXEC_PATH  ?= $(BARE_TOOLCHAIN_DIR)/bin/

UBOOT_DEFCONFIG ?= k3_oerv_defconfig
LINUX_REPO     ?= https://github.com/openRuyi-Project/linux.git
LINUX_DTB_DIR  ?= $(CURDIR)/linux/arch/riscv/boot/dts/spacemit

OUTPUT         := $(CURDIR)/output
DIST           := $(CURDIR)/dist

# ─── Dependency check helpers ────────────────────────────────────────

define check_cmd
	@if ! command -v $(1) >/dev/null 2>&1; then \
		echo "WARNING: $(1) not found$(if $(2), (apt: $(2)))"; \
	fi
endef

APT_DEPS_COMMON  := git make gcc
APT_DEPS_UBOOT   := gcc-riscv64-linux-gnu device-tree-compiler
APT_DEPS_OPENSBI  := gcc-riscv64-linux-gnu
APT_DEPS_ESOS    := scons lzop u-boot-tools
APT_DEPS_LINUX   := gcc-riscv64-linux-gnu flex bison libssl-dev

# ─── Top-level targets ───────────────────────────────────────────────

.PHONY: all clean u-boot opensbi esos dist submodules linux-dtbs toolchain
.PHONY: check-deps install-deps
.PHONY: esos-lite esos-core esos-itb

all: u-boot opensbi esos dist

check-deps:
	$(call check_cmd,git,git)
	$(call check_cmd,$(CROSS_COMPILE)gcc,gcc-riscv64-linux-gnu)
	$(call check_cmd,$(BARE_CROSS)gcc,make toolchain)
	$(call check_cmd,scons,scons)
	$(call check_cmd,lzop,lzop)
	$(call check_cmd,mkimage,u-boot-tools)
	$(call check_cmd,dtc,device-tree-compiler)
	$(call check_cmd,flex,flex)
	$(call check_cmd,bison,bison)

install-deps:
	sudo apt-get update
	sudo apt-get install -y \
		$(APT_DEPS_COMMON) \
		$(APT_DEPS_UBOOT) \
		$(APT_DEPS_OPENSBI) \
		$(APT_DEPS_ESOS) \
		$(APT_DEPS_LINUX)

dist: all
	@mkdir -p $(DIST)
	cp u-boot/u-boot.itb              $(DIST)/
	cp u-boot/u-boot-env-default.bin  $(DIST)/
	cp u-boot/FSBL.bin                $(DIST)/
	cp u-boot/bootinfo_spinor.bin     $(DIST)/
	cp opensbi/build/platform/generic/firmware/fw_dynamic.itb $(DIST)/
	cp $(OUTPUT)/esos_rt24.itb        $(DIST)/
	cp scripts/partition_4M.json      $(DIST)/
	cp scripts/flash.sh              $(DIST)/
	@echo "==> Firmware collected in $(DIST)/"

# ─── Submodules ──────────────────────────────────────────────────────

submodules:
	git submodule update --init --recursive --depth 1

# ─── Bare-metal toolchain ────────────────────────────────────────────

$(BARE_TOOLCHAIN_DIR)/bin/$(BARE_CROSS)gcc:
	@mkdir -p toolchain
	curl -L --retry 3 --retry-delay 5 $(BARE_TOOLCHAIN_URL) | tar -xJ -C toolchain
	@test -x $@ && echo "==> Toolchain ready: $(BARE_TOOLCHAIN_DIR)"

toolchain: $(BARE_TOOLCHAIN_DIR)/bin/$(BARE_CROSS)gcc

# ─── U-Boot ──────────────────────────────────────────────────────────

u-boot: u-boot/.config linux-dtbs
	sed -i -e 's%compatible = "ns16550";%compatible = "spacemit,k1-uart", "intel,xscale-uart", "ns16550";%' u-boot/arch/riscv/dts/k3.dtsi
	$(MAKE) -C u-boot -j$(NPROC) CROSS_COMPILE=$(CROSS_COMPILE) \
		LINUX_DTB_DIR=$(LINUX_DTB_DIR)

u-boot/.config: | submodules
	sed -i -e 's%compatible = "ns16550";%compatible = "spacemit,k1-uart", "intel,xscale-uart", "ns16550";%' u-boot/arch/riscv/dts/k3.dtsi
	$(MAKE) -C u-boot -j$(NPROC) CROSS_COMPILE=$(CROSS_COMPILE) $(UBOOT_DEFCONFIG)

# ─── Linux DTBs ──────────────────────────────────────────────────────

linux:
	git clone --depth 1 $(LINUX_REPO) linux

linux-dtbs: | linux
	$(MAKE) -C linux -j$(NPROC) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) defconfig
	$(MAKE) -C linux -j$(NPROC) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) dtbs

# ─── OpenSBI ─────────────────────────────────────────────────────────

opensbi: | submodules
	$(MAKE) -C opensbi -j$(NPROC) \
		CROSS_COMPILE=$(CROSS_COMPILE) \
		PLATFORM=generic \
		PLATFORM_DEFCONFIG=k3_defconfig

# ─── ESOS ────────────────────────────────────────────────────────────

esos: esos-lite esos-core esos-itb

esos/components/esos-lite: | submodules
	@mkdir -p esos/components
	#@if [ ! -L esos/components/esos-lite ]; then \
	#	ln -s ../../esos-lite esos/components/esos-lite; \
	#fi
	cp -a esos-lite esos/components/esos-lite

esos-lite: esos/components/esos-lite | $(BARE_TOOLCHAIN_DIR)/bin/$(BARE_CROSS)gcc
	cd esos/components/esos-lite/rt-thread/bsp/spacemit && \
		RTT_EXEC_PATH="$(RTT_EXEC_PATH)" scons

esos-core: esos-lite
	cd esos/bsp/spacemit && \
		RTT_EXEC_PATH="$(RTT_EXEC_PATH)" scons core0 && \
		RTT_EXEC_PATH="$(RTT_EXEC_PATH)" scons core1

esos-itb: esos-core
	@mkdir -p $(OUTPUT)
	cd esos && mkimage -f esos_rt24.its $(OUTPUT)/esos_rt24.itb

# ─── Clean ───────────────────────────────────────────────────────────

clean:
	-if [ -d linux ]; then $(MAKE) -C linux ARCH=$(ARCH) clean; fi
	-$(MAKE) -C u-boot clean
	-$(MAKE) -C opensbi clean
	-rm -rf esos/components/esos-lite
	-cd esos && git checkout -- . && git clean -fdx
	-rm -rf $(OUTPUT)
	-rm -rf $(DIST)
	-rm -rf toolchain
