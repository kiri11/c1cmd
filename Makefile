# Determine sensible default PREFIX:
# 1. If explicitly passed (PREFIX=...), respect it.
# 2. Else if /usr/local/bin is writable, use /usr/local.
# 3. Else if /opt/homebrew/bin exists and is writable, use /opt/homebrew.
# 4. Otherwise, fallback to $(HOME)/.local (no sudo required).
ifeq ($(origin PREFIX), undefined)
  ifeq ($(shell [ -w /usr/local/bin ] 2>/dev/null && echo ok), ok)
    PREFIX = /usr/local
  else ifeq ($(shell [ -w /opt/homebrew/bin ] 2>/dev/null && echo ok), ok)
    PREFIX = /opt/homebrew
  else
    PREFIX = $(HOME)/.local
  endif
endif

BINDIR ?= $(PREFIX)/bin
BUILD_DIR ?= .build/release

.PHONY: all build build-debug test install uninstall clean

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
	rm -rf $(DESTDIR)$(BINDIR)/c1_CaptureOneCore.bundle
	cp -R $(BUILD_DIR)/c1_CaptureOneCore.bundle $(DESTDIR)$(BINDIR)/c1_CaptureOneCore.bundle
	codesign -s - --force $(DESTDIR)$(BINDIR)/c1 2>/dev/null || true
	codesign -s - --force $(DESTDIR)$(BINDIR)/c1-mcp 2>/dev/null || true
	@echo "Successfully installed c1 and c1-mcp to $(DESTDIR)$(BINDIR)"
	@case ":$(PATH):" in \
		*":$(BINDIR):"*) ;; \
		*) echo "\nNote: $(BINDIR) is not in your PATH. Add it with:"; \
		   echo "  export PATH=\"$(BINDIR):\$$PATH\"" ;; \
	esac

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/c1 $(DESTDIR)$(BINDIR)/c1-mcp
	rm -rf $(DESTDIR)$(BINDIR)/c1_CaptureOneCore.bundle
	@echo "Successfully uninstalled c1 and c1-mcp from $(DESTDIR)$(BINDIR)"

clean:
	swift package clean

.PHONY: archive
archive: build
	./scripts/package-release.sh v0.1.0 $(BUILD_DIR) dist
