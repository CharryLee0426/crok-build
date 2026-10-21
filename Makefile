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
# Clones the main checkout's cargo cache into a linked worktree before its first build (see bin/crok-build-cache).
SEED_CACHE = -@"$(CURDIR)/bin/crok-build-cache" seed --quiet --profile release --target-dir "$(CARGO_TARGET_DIR)"

.PHONY: build deploy build-desktop deploy-desktop dmg-desktop build-test-tui build-test-desktop clients-prod clients-test import-grok-config cache-status cache-prune cache-hooks help

# The relay crok signs in to (relay/environments/<name>.env, read by crates/codegen/crok-remote/build.rs): production
# for every build here except the test builds (crok-test, Crok Desktop Test), which use the dev relay.
CROK_RELAY_ENV ?= prod
TEST_RELAY_ENV ?= dev

# The Agent Observability destination built into crok (crates/codegen/xai-grok-agento11y/build.rs), so an
# install reports with nothing to set up: this Mac's ~/.crok/agento11y.env when it has one. Empty builds none.
CROK_AGENTO11Y_BUILTIN_ENV ?= $(wildcard $(HOME)/.crok/agento11y.env)
export CROK_AGENTO11Y_BUILTIN_ENV

# CROK_BINARY names an existing harness for the desktop build; GROK_BINARY still works.
CROK_BINARY ?= $(GROK_BINARY)

# Signs an installed crok with the certificate every build uses, so macOS keeps the permissions
# it gave an earlier build (release/codesign.sh). Arguments: the identifier, the file.
SIGN_TUI = if [ "$$(uname -s)" = Darwin ]; then "$(CURDIR)/release/codesign.sh" --identifier $(1) "$(2)"; fi

# The default build and deploy commands only operate on the CLI/TUI.
build:
	$(SEED_CACHE)
	CROK_RELAY_ENV=$(CROK_RELAY_ENV) $(CARGO) build -p xai-grok-pager-bin --release --target-dir "$(CARGO_TARGET_DIR)"

deploy: build
	@mkdir -p "$(BINDIR)"
	@set -e; \
		tmp_binary=$$(mktemp "$(BINDIR)/.crok.XXXXXX"); \
		trap 'rm -f "$$tmp_binary"' EXIT; \
		install -m 755 "$(TUI_BINARY)" "$$tmp_binary"; \
		$(call SIGN_TUI,dev.chenli.crok,$$tmp_binary); \
		mv -f "$$tmp_binary" "$(BINDIR)/crok"
	@printf 'Installed TUI: %s/crok\n' "$(BINDIR)"

# Test artifacts stay under this checkout. bin/crok-test refuses to launch from another workspace.
build-test-tui:
	$(SEED_CACHE)
	CROK_RELAY_ENV=$(TEST_RELAY_ENV) $(CARGO) build -p xai-grok-pager-bin --release --target-dir "$(CARGO_TARGET_DIR)"
	@mkdir -p "$(TEST_TUI_DIR)"
	@set -e; \
		tmp_binary=$$(mktemp "$(TEST_TUI_BINARY).XXXXXX"); \
		trap 'rm -f "$$tmp_binary"' EXIT; \
		install -m 755 "$(TUI_BINARY)" "$$tmp_binary"; \
		$(call SIGN_TUI,dev.chenli.crok.test,$$tmp_binary); \
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
	DESKTOP_HARNESS_ID="dev.chenli.crok.test" \
	DESKTOP_APP_DIR="$(TEST_DESKTOP_APP)" \
	DESKTOP_ICON_PATH="$(TEST_DESKTOP_ICON)" \
	DESKTOP_ICON_PREVIEW_PATH="$(dir $(TEST_DESKTOP_ICON))Crok Desktop Test-icon.png" \
	DESKTOP_ICON_STYLE="test" \
	DESKTOP_STATE_FILE="$(TEST_DESKTOP_STATE)" \
	DESKTOP_TEST_BUILD=1 \
	DESKTOP_REGISTER_APP=0 \
	CROK_BINARY="$(TEST_TUI_BINARY)" ./desktop/macOS/scripts/build-app.sh
	@printf 'Launch with: open "%s"\n' "$(TEST_DESKTOP_APP)"

# The relay's web app and functions plus both phone apps for one environment: prod (crok.chenli.dev, Convex production,
# "-prod" phone builds) or test (crok-relay.vercel.app, Convex dev, "-debug" phone builds). See relay/environments.
clients-prod:
	relay/scripts/deploy.sh prod
	mobile/scripts/build-apps.sh prod

clients-test:
	relay/scripts/deploy.sh test
	mobile/scripts/build-apps.sh test

# One-time (re-runnable) copy of the official grok's settings, sessions, and desktop state into crok's.
import-grok-config:
	./bin/crok-import-grok

# Cargo build cache across rebuilds and worktrees (bin/crok-build-cache).
cache-status:
	@"$(CURDIR)/bin/crok-build-cache" status --all

cache-prune:
	@"$(CURDIR)/bin/crok-build-cache" prune --all

cache-hooks:
	@"$(CURDIR)/bin/crok-build-cache" install-git-hooks

help:
	@printf '%s\n' \
		'make / make build       Build the release CLI/TUI only (default).' \
		'make deploy             Build and install the TUI to ~/.local/bin/crok.' \
		'make build-desktop      Build the harness and package the macOS desktop app.' \
		'make deploy-desktop     Build and install the desktop app to ~/Applications.' \
		'make dmg-desktop        Build the desktop app and its .dmg installer in desktop/macOS/dist.' \
		'make build-test-tui     Build the workspace-only TUI used by crok-test (dev relay).' \
		'make build-test-desktop Build the TESTING-badged desktop app in target/test-builds (dev relay).' \
		'make clients-prod       Deploy the prod relay web + functions; build the -prod phone apps.' \
		'make clients-test       Deploy the dev relay web + functions; build the -debug phone apps.' \
		'make import-grok-config Copy ~/.grok settings, sessions, and Grok Desktop state into crok.' \
		'make cache-status       Size and stale part of every cargo target dir of this repository.' \
		'make cache-prune        Delete superseded and unused cargo build products in all of them.' \
		'make cache-hooks        Seed new worktrees from this cache and prune automatically (git hooks).' \
		'' \
		'Overrides: CARGO, RUSTUP, CARGO_TARGET_DIR, PREFIX, BINDIR, DESKTOP_INSTALL_DIR, CROK_AGENTO11Y_BUILTIN_ENV,' \
		'           CROK_RELAY_ENV (prod), TEST_RELAY_ENV (dev).' \
		'Set CROK_BINARY to reuse an existing harness when building the desktop app.'
