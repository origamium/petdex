# Petdex desktop (Zig 0.16 + Native SDK).
#
# The SDK and its `native` CLI are built from the exact commit CI pins in
# .github/workflows/desktop-native-ci.yml, with the Petdex patches applied,
# into a cache outside the repo. Nothing here duplicates those pins, so an
# SDK bump in the workflow is picked up on the next `make`.
#
#   make              release-flag build (what CI builds)
#   make dev          automation build, then run it
#   make test         unit tests
#   make restart      macOS: rebuild and relaunch "Petdex Dev.app"
#
# Variables: PETDEX_PET=<slug> picks the pet, DEV_HOME=<dir> runs with an
# isolated HOME (settings, pets, chat history), SDK_DIR overrides the cache.

ROOT := $(abspath $(CURDIR)/../..)
CI_WORKFLOW := $(ROOT)/.github/workflows/desktop-native-ci.yml
pin = $(shell sed -n 's/^ *$(1): "\(.*\)"$$/\1/p' $(CI_WORKFLOW) | head -n 1)

ZIG_VERSION := 0.16.0
SDK_REMOTE ?= $(call pin,NATIVE_SDK_REMOTE)
SDK_BRANCH ?= $(call pin,NATIVE_SDK_BRANCH)
SDK_REF ?= $(call pin,NATIVE_SDK_REF)
SDK_DIR ?= $(or $(XDG_CACHE_HOME),$(HOME)/.cache)/petdex/native-sdk-$(SDK_REF)
NATIVE := $(SDK_DIR)/zig-out/bin/native
BIN := zig-out/bin/petdex-desktop-native

# The build scripts and the patch script read these.
export NATIVE_SDK_PATH := $(SDK_DIR)
export NATIVE_CLI := $(NATIVE)

# -Dtrace=off matches the release builds: tracing appends a record per
# frame to native-sdk.jsonl (#714, #773).
BUILD_FLAGS := -Dcpu=baseline -Dtrace=off

.PHONY: all build dev run test restart sdk clean help
all: build

build: $(NATIVE)
	$(NATIVE) build $(BUILD_FLAGS)

dev: $(NATIVE)
	$(NATIVE) build $(BUILD_FLAGS) -Dautomation
	$(MAKE) --no-print-directory run

run:
	$(if $(DEV_HOME),HOME="$(DEV_HOME)" )./$(BIN)

test: $(NATIVE)
	$(NATIVE) test .

restart: $(NATIVE)
	"$(ROOT)/scripts/macos-dev-restart.sh"

sdk: $(NATIVE)

# Re-run when a Petdex patch changes; the patch script is idempotent.
$(NATIVE): $(wildcard $(ROOT)/patches/*.patch)
	@test -n "$(SDK_REF)" || { echo "make: no NATIVE_SDK_REF in $(CI_WORKFLOW)" >&2; exit 1; }
	@test "$$(zig version)" = "$(ZIG_VERSION)" || { echo "make: need zig $(ZIG_VERSION), found $$(zig version)" >&2; exit 1; }
	@if [ ! -d "$(SDK_DIR)/.git" ]; then \
		git clone --depth 1 --branch "$(SDK_BRANCH)" "$(SDK_REMOTE)" "$(SDK_DIR)" && \
		git -C "$(SDK_DIR)" fetch --depth 1 origin "$(SDK_REF)" && \
		git -C "$(SDK_DIR)" checkout -q --detach "$(SDK_REF)"; \
	fi
	"$(ROOT)/scripts/patch-native-sdk.sh"
	cd "$(SDK_DIR)" && zig build cli

clean:
	rm -rf zig-out .zig-cache .native

help:
	@sed -n '2,15s/^# \{0,1\}//p' $(firstword $(MAKEFILE_LIST))
