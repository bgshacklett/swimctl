# This Makefile is a wrapper around scripts in the <repo_root>/scripts
# directory, meant to enable tab completion and generally make life a little
# easier. You do not need `make` to use the contents of this repo.


.PHONY: image
image:
	@sudo -E scripts/alpine-rpi-qemu.sh make-image

.PHONY: populate-boot
populate-boot:
	@sudo -E scripts/alpine-rpi-qemu.sh populate-boot

.PHONY: populate-config
populate-config:
	@sudo -E scripts/alpine-rpi-qemu.sh populate-config

.PHONY: verify
verify:
	@scripts/alpine-rpi-qemu.sh verify

.PHONY: launch
launch:
	@sudo -E scripts/alpine-rpi-qemu.sh launch

.PHONY: test
test:
	@scripts/alpine-rpi-qemu.sh test

.PHONY: sdcard
sdcard:
	@sudo -E scripts/alpine-rpi-qemu.sh sdcard

.PHONY: clean
clean:
	@scripts/alpine-rpi-qemu.sh clean
