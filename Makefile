# This Makefile is a wrapper around the

# ===== Alpine tarball cache + verification (manual method) =====
ALPINE_VERSION ?= 3.22.1
ALPINE_ARCH    ?= aarch64

# Derive series (major.minor) from ALPINE_VERSION (major.minor.patch)
ALPINE_MAJOR   := $(firstword $(subst ., ,$(ALPINE_VERSION)))
ALPINE_MINOR   := $(word 2,$(subst ., ,$(ALPINE_VERSION)))
ALPINE_SERIES  := $(ALPINE_MAJOR).$(ALPINE_MINOR)

# Primary: explicit series; Fallback: latest-stable
ALPINE_BASE_URL_SERIES  := https://dl-cdn.alpinelinux.org/alpine/v$(ALPINE_SERIES)/releases/$(ALPINE_ARCH)
ALPINE_BASE_URL_LATEST  := https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/$(ALPINE_ARCH)

ALPINE_TARBALL_NAME := alpine-rpi-$(ALPINE_VERSION)-$(ALPINE_ARCH).tar.gz

CACHE_DIR        ?= cache
ALPINE_TARBALL   := $(CACHE_DIR)/$(ALPINE_TARBALL_NAME)
ALPINE_SHA_FILE  := $(ALPINE_TARBALL).sha256
APKVOL_URL = https://github.com/macmpi/alpine-linux-headless-bootstrap/archive/refs/tags/v1.2.3.tar.gz


.PHONY: qemu-image
qemu-image:
	@sudo bash scripts/build-boot-image.sh


.PHONY: test
test: qemu-image
	@scripts/test.sh


# .PHONY: sdcard
# sdcard: bundle
# 	@[ -n "$(SD)" ] || (echo "Set SD=/dev/sdX"; exit 1)
# 	@echo "Using SD=$(SD), ALPINE=$(ALPINE_TARBALL)"
# 	sudo scripts/prepare-sdcard.sh "$(SD)" --alpine "$(ALPINE_TARBALL)" --bundle boot-bundle


# .PHONY: clean

# clean:
# 	@rm -rf dist/**/*


# .PHONY: clean-all

# clean-all: clean
# 	-@rm -rf cache/**/*  # nuke cached downloads if you really want
