SHELL := /bin/bash
.DEFAULT_GOAL := build

RUSTUP ?= rustup
RUSTUP_CARGO := $(shell $(RUSTUP) which cargo 2>/dev/null)
RUSTUP_BIN_DIR := $(dir $(RUSTUP_CARGO))
CARGO ?= $(if $(strip $(RUSTUP_CARGO)),env PATH="$(RUSTUP_BIN_DIR):$$PATH" "$(RUSTUP_CARGO)",cargo)
CARGO_TARGET_DIR ?= target
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
DESKTOP_INSTALL_DIR ?= $(HOME)/Applications

TUI_BINARY = $(CARGO_TARGET_DIR)/release/xai-grok-pager
DESKTOP_APP = desktop/macOS/dist/Crok Desktop.app
TEST_BUILD_DIR = $(CURDIR)/target/test-builds
TEST_TUI_DIR = $(TEST_BUILD_DIR)/tui
TEST_TUI_BINARY = $(TEST_TUI_DIR)/crok-test
TEST_DESKTOP_DIR = $(TEST_BUILD_DIR)/desktop
TEST_DESKTOP_APP = $(TEST_DESKTOP_DIR)/Crok Desktop Test.app
TEST_DESKTOP_STATE = $(TEST_BUILD_DIR)/desktop-state/state.json
TEST_DESKTOP_ICON = $(TEST_DESKTOP_DIR)/CrokDesktopTestIcon.icns

.PHONY: build deploy build-desktop deploy-desktop dmg-desktop build-test-tui build-test-desktop import-grok-config help

# CROK_BINARY names an existing harness for the desktop build; GROK_BINARY still works.
CROK_BINARY ?= $(GROK_BINARY)

# The default build and deploy commands only operate on the CLI/TUI.
build:
	$(CARGO) build -p xai-grok-pager-bin --release --target-dir "$(CARGO_TARGET_DIR)"

deploy: build
	@mkdir -p "$(BINDIR)"
	@set -e; \
		tmp_binary=$$(mktemp "$(BINDIR)/.crok.XXXXXX"); \
		trap 'rm -f "$$tmp_binary"' EXIT; \
		install -m 755 "$(TUI_BINARY)" "$$tmp_binary"; \
		mv -f "$$tmp_binary" "$(BINDIR)/crok"
	@printf 'Installed TUI: %s/crok\n' "$(BINDIR)"

# Test artifacts stay under this checkout. bin/crok-test refuses to launch from another workspace.
build-test-tui:
	$(CARGO) build -p xai-grok-pager-bin --release --target-dir "$(CARGO_TARGET_DIR)"
	@mkdir -p "$(TEST_TUI_DIR)"
	@set -e; \
		tmp_binary=$$(mktemp "$(TEST_TUI_BINARY).XXXXXX"); \
		trap 'rm -f "$$tmp_binary"' EXIT; \
		install -m 755 "$(TUI_BINARY)" "$$tmp_binary"; \
		mv -f "$$tmp_binary" "$(TEST_TUI_BINARY)"
	@printf 'Built test TUI: %s\n' "$(TEST_TUI_BINARY)"
	@printf 'Launch it with: PATH="%s/bin:$$PATH" crok-test\n' "$(CURDIR)"

# Desktop packaging needs a harness. An explicit CROK_BINARY reuses that
# executable; otherwise build the current checkout before bundling it.
build-desktop:
	@if [ "$$(uname -s)" != Darwin ]; then \
		printf 'Crok Desktop requires macOS.\n' >&2; exit 1; \
	fi
ifeq ($(strip $(CROK_BINARY)),)
	$(MAKE) build
endif
	CROK_BINARY="$(if $(strip $(CROK_BINARY)),$(CROK_BINARY),$(TUI_BINARY))" ./desktop/macOS/scripts/build-app.sh

deploy-desktop: build-desktop
	@mkdir -p "$(DESKTOP_INSTALL_DIR)/Crok Desktop.app"
	rsync -a --delete "$(DESKTOP_APP)/" "$(DESKTOP_INSTALL_DIR)/Crok Desktop.app/"
	@printf 'Installed desktop app: %s/Crok Desktop.app\n' "$(DESKTOP_INSTALL_DIR)"

# The installer for new users: the app, with its bundled TUI, on a drag-to-Applications disk image.
dmg-desktop: build-desktop
	./desktop/macOS/scripts/build-dmg.sh

# This bundle has a separate identity, test-only artwork, and workspace-local UI state.
build-test-desktop: build-test-tui
	@if [ "$$(uname -s)" != Darwin ]; then \
		printf 'The test desktop app requires macOS.\n' >&2; exit 1; \
	fi
	@mkdir -p "$(TEST_DESKTOP_DIR)"
	DESKTOP_APP_NAME="Crok Desktop Test" \
	DESKTOP_BUNDLE_ID="dev.chenli.crok.desktop.test" \
	DESKTOP_APP_DIR="$(TEST_DESKTOP_APP)" \
	DESKTOP_ICON_PATH="$(TEST_DESKTOP_ICON)" \
	DESKTOP_ICON_PREVIEW_PATH="$(dir $(TEST_DESKTOP_ICON))Crok Desktop Test-icon.png" \
	DESKTOP_ICON_STYLE="test" \
	DESKTOP_STATE_FILE="$(TEST_DESKTOP_STATE)" \
	DESKTOP_TEST_BUILD=1 \
	DESKTOP_REGISTER_APP=0 \
	CROK_BINARY="$(TEST_TUI_BINARY)" ./desktop/macOS/scripts/build-app.sh
	@printf 'Launch with: open "%s"\n' "$(TEST_DESKTOP_APP)"

# One-time (re-runnable) copy of the official grok's settings, sessions, and desktop state into crok's.
import-grok-config:
	./bin/crok-import-grok

help:
	@printf '%s\n' \
		'make / make build       Build the release CLI/TUI only (default).' \
		'make deploy             Build and install the TUI to ~/.local/bin/crok.' \
		'make build-desktop      Build the harness and package the macOS desktop app.' \
		'make deploy-desktop     Build and install the desktop app to ~/Applications.' \
		'make dmg-desktop        Build the desktop app and its .dmg installer in desktop/macOS/dist.' \
		'make build-test-tui     Build the workspace-only TUI used by crok-test.' \
		'make build-test-desktop Build the TESTING-badged desktop app in target/test-builds.' \
		'make import-grok-config Copy ~/.grok settings, sessions, and Grok Desktop state into crok.' \
		'' \
		'Overrides: CARGO, RUSTUP, CARGO_TARGET_DIR, PREFIX, BINDIR, DESKTOP_INSTALL_DIR.' \
		'Set CROK_BINARY to reuse an existing harness when building the desktop app.'
