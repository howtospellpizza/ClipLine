BINARY_NAME = clipline
INSTALL_DIR = $(HOME)/.local/bin
PLIST_LABEL = io.github.clipline.daemon
PLIST_PATH = $(HOME)/Library/LaunchAgents/$(PLIST_LABEL).plist
VERSION := $(shell tr -d '[:space:]' < VERSION)
GENERATED_VERSION_FILE = Sources/ClipLine/Services/GeneratedVersion.swift
SRC = $(shell find Sources/ClipLine -name '*.swift' | sort)
TEST_SRC = $(shell find Tests -name '*.swift' | sort)
MACOS_MIN_VERSION = 14.0
TARGET = $(shell uname -m)-apple-macosx$(MACOS_MIN_VERSION)

.PHONY: all sync-version build test test-install install uninstall clean

all: build

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
	@echo "✅ Built build/$(BINARY_NAME) (v$(VERSION))"

test: sync-version
	@mkdir -p build
	swiftc -target $(TARGET) -D CLIPLINE_TEST $(SRC) $(TEST_SRC) -o build/clipline-tests
	CLIPLINE_TEST_FILTER="$(FILTER)" ./build/clipline-tests

install: build
	@mkdir -p "$(INSTALL_DIR)"
	install -m 755 build/$(BINARY_NAME) "$(INSTALL_DIR)/$(BINARY_NAME)"
	@echo "✅ Installed to $(INSTALL_DIR)/$(BINARY_NAME)"

test-install: build
	sh Tests/install-smoke.sh

uninstall:
	@if [ -f "$(PLIST_PATH)" ]; then \
		launchctl bootout gui/$$(id -u) "$(PLIST_PATH)" 2>/dev/null || true; \
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
