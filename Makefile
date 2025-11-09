# Makefile — OpenHVX Agent build helper
# Minimal version (for contributors)

SHELL := /bin/bash

# Paths
ROOT := $(CURDIR)
TOOLS := $(ROOT)/tools
BIN := $(ROOT)/src/powershell/bin

CLOUDINIT_SRC := $(TOOLS)/cloudinit-iso/src
SERIALBRIDGE_SRC := $(TOOLS)/serial-bridge/src

GO ?= go
GOOS ?= windows
GOARCH ?= amd64

.PHONY: all agent-bin build-src clean

# Default target
all: agent-bin

# Build main backend first (src/)
build-src:
	@echo "==> Building backend source"
	@if [ -f package.json ]; then npm ci && npm run build; else echo "No Node project found — skipping"; fi

# Build agent toolchain
agent-bin: build-src
	@echo "==> Building agent tools"
	@mkdir -p $(BIN)
	@echo " -> cloudinit-iso"
	cd $(CLOUDINIT_SRC) && GOOS=$(GOOS) GOARCH=$(GOARCH) $(GO) build -o $(BIN)/cloudinit-iso.exe .
	@echo " -> serial-bridge"
	cd $(SERIALBRIDGE_SRC) && GOOS=$(GOOS) GOARCH=$(GOARCH) $(GO) build -o $(BIN)/serial-bridge.exe .
	@echo "Binaries placed in $(BIN)"

# Cleanup
clean:
	rm -f $(BIN)/*.exe
	@echo "Cleaned built binaries"
