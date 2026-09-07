PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
BUILD_DIR ?= .build/release

.PHONY: all build build-debug test install clean

all: build

build:
	swift build -c release

build-debug:
	swift build

test:
	swift run CaptureOneCoreTests

install: build
	mkdir -p $(DESTDIR)$(BINDIR)
	install -m 755 $(BUILD_DIR)/c1 $(DESTDIR)$(BINDIR)/c1
	install -m 755 $(BUILD_DIR)/c1-mcp $(DESTDIR)$(BINDIR)/c1-mcp
	codesign -s - --force $(DESTDIR)$(BINDIR)/c1 2>/dev/null || true
	codesign -s - --force $(DESTDIR)$(BINDIR)/c1-mcp 2>/dev/null || true
	@echo "Successfully installed c1 and c1-mcp to $(DESTDIR)$(BINDIR)"

clean:
	swift package clean
