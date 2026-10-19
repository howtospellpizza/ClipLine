BINARY_NAME = clipline
INSTALL_DIR = $(HOME)/.local/bin
PLIST_LABEL = io.github.clipline.daemon
PLIST_PATH = $(HOME)/Library/LaunchAgents/$(PLIST_LABEL).plist
SRC = $(shell find Sources/ClipLine -name '*.swift' | sort)
TEST_SRC = Tests/ClipLineTests.swift

.PHONY: all build test install uninstall clean

all: build

build:
	@mkdir -p build
	swiftc -O $(SRC) -o build/$(BINARY_NAME)
	@echo "✅ Built build/$(BINARY_NAME)"

test:
	@mkdir -p build
	swiftc -D CLIPLINE_TEST $(SRC) $(TEST_SRC) -o build/clipline-tests
	./build/clipline-tests

install: build
	@mkdir -p $(INSTALL_DIR)
	cp build/$(BINARY_NAME) $(INSTALL_DIR)/$(BINARY_NAME)
	@echo "✅ Installed to $(INSTALL_DIR)/$(BINARY_NAME)"

uninstall:
	-launchctl bootout gui/$$(id -u)/$(PLIST_LABEL) 2>/dev/null || true
	-pkill -x $(BINARY_NAME) 2>/dev/null || true
	rm -f $(PLIST_PATH)
	rm -f $(INSTALL_DIR)/$(BINARY_NAME)
	@echo "✅ Uninstalled $(BINARY_NAME)"

clean:
	rm -rf build
