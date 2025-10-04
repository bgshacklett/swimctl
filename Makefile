# This Makefile is a wrapper around scripts in the <repo_root>/scripts
# directory, meant to enable tab completion and generally make life a little
# easier. You do not need `make` to use the contents of this repo.


.PHONY: image
image:
	@sudo -E scripts/alpine-rpi.sh make-image

.PHONY: populate-boot-qemu
populate-boot-qemu:
	@sudo -E scripts/alpine-rpi.sh populate-boot-qemu

.PHONY: populate-config-qemu
populate-config-qemu:
	@sudo -E scripts/alpine-rpi.sh populate-config-qemu

.PHONY: verify
verify:
	@scripts/alpine-rpi.sh verify

.PHONY: qemu
qemu: image populate-boot-qemu populate-config-qemu

.PHONY: launch
launch:
	@sudo -E scripts/alpine-rpi.sh launch

.PHONY: test
test:
	@sudo -E scripts/alpine-rpi.sh test

.PHONY: populate-boot-sd
populate-boot-sd:
	@sudo -E scripts/alpine-rpi.sh populate-boot-sd

.PHONY: populate-config-sd
populate-config-sd:
	@sudo -E scripts/alpine-rpi.sh populate-config-sd

.PHONY: sdcard
sdcard: populate-boot-sd populate-config-sd

.PHONY: clean
clean:
	@scripts/alpine-rpi.sh clean
