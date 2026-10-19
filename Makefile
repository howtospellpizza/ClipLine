BINARY_NAME = clipline
INSTALL_DIR = $(HOME)/.local/bin
SRC = $(shell find Sources/ClipLine -name '*.swift' | sort)
TEST_SRC = Tests/ClipLineTests.swift

.PHONY: all build test install clean

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

clean:
	rm -rf build
