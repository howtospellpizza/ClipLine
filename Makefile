BINARY_NAME = clipline
INSTALL_DIR = $(HOME)/.local/bin
CODESIGN_IDENTIFIER = io.github.clipline
LOGIN_KEYCHAIN ?= $(shell security default-keychain -d user 2>/dev/null | sed -n 's/.*"\(.*\)".*/\1/p')
PLIST_LABEL = io.github.clipline.daemon
PLIST_PATH = $(HOME)/Library/LaunchAgents/$(PLIST_LABEL).plist
VERSION := $(shell tr -d '[:space:]' < VERSION)
GENERATED_VERSION_FILE = Sources/ClipLine/Services/GeneratedVersion.swift
SRC = $(shell find Sources/ClipLine -name '*.swift' | sort)
TEST_SRC = $(shell find Tests -name '*.swift' | sort)
MACOS_MIN_VERSION = 14.0
TARGET = $(shell uname -m)-apple-macosx$(MACOS_MIN_VERSION)

.PHONY: all sync-version setup-codesign build test test-install install install-service uninstall clean

all: build

setup-codesign:
	@sh scripts/ensure-codesign-cert.sh --create

sync-version:
	@printf '// Auto-generated from VERSION by Makefile — committed so `swift build` also works out of the box.\nlet ClipLineGeneratedBuildVersion = "%s"\n' "$(VERSION)" > "$(GENERATED_VERSION_FILE).tmp"
	@if ! cmp -s "$(GENERATED_VERSION_FILE).tmp" "$(GENERATED_VERSION_FILE)"; then \
		mv "$(GENERATED_VERSION_FILE).tmp" "$(GENERATED_VERSION_FILE)"; \
	else \
		rm -f "$(GENERATED_VERSION_FILE).tmp"; \
	fi

build: sync-version
	@mkdir -p build
	swiftc -target $(TARGET) -O $(SRC) -o build/$(BINARY_NAME)
	@id="$$CODESIGN_IDENTITY"; \
	if [ -z "$$id" ]; then \
		id=$$(sh scripts/ensure-codesign-cert.sh --print-identity); \
	fi; \
	if [ -n "$$id" ] && [ "$$id" != "-" ]; then \
		codesign --force --sign "$$id" $(if $(LOGIN_KEYCHAIN),--keychain "$(LOGIN_KEYCHAIN)") --identifier "$(CODESIGN_IDENTIFIER)" --timestamp=none build/$(BINARY_NAME); \
		printf '✅ Built and signed build/%s (v%s, identity: %s)\n' "$(BINARY_NAME)" "$(VERSION)" "$$id"; \
	else \
		codesign --force --sign - --identifier "$(CODESIGN_IDENTIFIER)" --timestamp=none build/$(BINARY_NAME); \
		printf '✅ Built build/%s (v%s, ad-hoc signed)\n' "$(BINARY_NAME)" "$(VERSION)"; \
	fi

test: sync-version
	@mkdir -p build
	swiftc -target $(TARGET) -D CLIPLINE_TEST $(SRC) $(TEST_SRC) -o build/clipline-tests
	CLIPLINE_TEST_FILTER="$(FILTER)" ./build/clipline-tests

install: build
	@mkdir -p "$(INSTALL_DIR)"
	install -m 755 build/$(BINARY_NAME) "$(INSTALL_DIR)/$(BINARY_NAME)"
	@echo "✅ Installed to $(INSTALL_DIR)/$(BINARY_NAME)"

install-service: install
	@mkdir -p "$(HOME)/Library/LaunchAgents" "$(HOME)/Library/Logs/ClipLine"
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'    <key>Label</key>' \
		'    <string>$(PLIST_LABEL)</string>' \
		'    <key>ProgramArguments</key>' \
		'    <array>' \
		'        <string>$(INSTALL_DIR)/$(BINARY_NAME)</string>' \
		'    </array>' \
		'    <key>RunAtLoad</key>' \
		'    <true/>' \
		'    <key>KeepAlive</key>' \
		'    <dict>' \
		'        <key>SuccessfulExit</key>' \
		'        <false/>' \
		'    </dict>' \
		'    <key>ProcessType</key>' \
		'    <string>Interactive</string>' \
		'    <key>StandardOutPath</key>' \
		'    <string>$(HOME)/Library/Logs/ClipLine/clipline-launchd.log</string>' \
		'    <key>StandardErrorPath</key>' \
		'    <string>$(HOME)/Library/Logs/ClipLine/clipline-launchd.log</string>' \
		'</dict>' \
		'</plist>' > "$(PLIST_PATH)"
	@if [ "$${CLIPLINE_SKIP_LAUNCHCTL:-0}" != "1" ]; then \
		launchctl bootout gui/$$(id -u) "$(PLIST_PATH)" 2>/dev/null || true; \
		for pid in $$(pgrep -u $$(id -u) -x $(BINARY_NAME)); do \
			if [ "$$(ps -p $$pid -o comm=)" = "$(INSTALL_DIR)/$(BINARY_NAME)" ]; then \
				kill "$$pid" 2>/dev/null || true; \
			fi; \
		done; \
		launchctl bootstrap gui/$$(id -u) "$(PLIST_PATH)"; \
		launchctl kickstart -k gui/$$(id -u)/$(PLIST_LABEL); \
	fi
	@echo "✅ Installed and started LaunchAgent $(PLIST_PATH)"

test-install:
	LOGIN_KEYCHAIN= CODESIGN_IDENTITY=- $(MAKE) build
	LOGIN_KEYCHAIN= CODESIGN_IDENTITY=- sh Tests/install-smoke.sh

uninstall:
	@if [ -f "$(PLIST_PATH)" ] && [ "$${CLIPLINE_SKIP_LAUNCHCTL:-0}" != "1" ]; then \
		launchctl bootout gui/$$(id -u)/$(PLIST_LABEL) 2>/dev/null || launchctl bootout gui/$$(id -u) "$(PLIST_PATH)" 2>/dev/null || true; \
	fi
	@for pid in $$(pgrep -u $$(id -u) -x $(BINARY_NAME)); do \
		if [ "$$(ps -p $$pid -o comm=)" = "$(INSTALL_DIR)/$(BINARY_NAME)" ]; then \
			kill "$$pid"; \
		fi; \
	done
	rm -f "$(PLIST_PATH)"
	rm -f "$(INSTALL_DIR)/$(BINARY_NAME)"
	@echo "✅ Uninstalled $(BINARY_NAME)"

clean:
	rm -rf build
