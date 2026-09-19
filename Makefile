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
ARCHIVE := dist/c1-v0.1.0-macos-$(shell uname -m).tar.gz
C1_RECOVERY_FIXTURE_PARENT ?= $(CURDIR)/.build/recovery-fixtures
C1_RECOVERY_SHUTDOWN_MODE ?= quit
QUALIFY_SUITES ?= cli mcp existing
RECOVERY_CASES ?= all
TEST_BUILD_DIR ?= .build/debug

.PHONY: all build build-debug test install uninstall clean

all: build

build:
	swift build -c release

build-debug:
	swift build

test:
	swift run CaptureOneCoreTests

# Fast development feedback: build once, then run all offline assertions.
.PHONY: check check-built-core check-python qualify qualify-extended qualify-recovery qualify-full
check: build-debug
	$(MAKE) check-built-core TEST_BUILD_DIR=.build/debug
	C1_TEST_BIN="$(CURDIR)/.build/debug/c1" C1_TEST_MCP_BIN="$(CURDIR)/.build/debug/c1-mcp" /usr/bin/time -p python3 -B Tests/contract_test.py

# Reuse already built binaries in packaged qualification and release CI.
check-built-core:
	/usr/bin/time -p "$(TEST_BUILD_DIR)/CaptureOneCoreTests"
	$(MAKE) check-python
	C1_TEST_BIN="$(abspath $(TEST_BUILD_DIR))/c1" C1_TEST_MCP_BIN="$(abspath $(TEST_BUILD_DIR))/c1-mcp" python3 -B Tests/catalog_reader_test.py

check-python:
	python3 -B Tests/contained_crop_test.py
	python3 -B Tests/catalog_freshness_probe_test.py
	python3 -B Tests/benchmark_reads_test.py
	python3 -B scripts/generate-native-editing.py --check
	python3 -B Tests/recovery_harness_test.py
	python3 -B Tests/recipe_harness_test.py
	python3 -B Tests/release_runner_test.py

# Normal qualification excludes deliberate timeout/process-death injection.
# Keep Capture One calls sequential.
qualify:
	@test -f "$(C1_TEST_RAW_FIXTURE)" || { echo 'Set C1_TEST_RAW_FIXTURE to an existing RAW file.' >&2; exit 1; }
	@test -n "$(EVIDENCE_DIR)" && test ! -e "$(EVIDENCE_DIR)" || { echo 'Set EVIDENCE_DIR to a new directory.' >&2; exit 1; }
	$(MAKE) archive
	$(MAKE) check-built-core TEST_BUILD_DIR=.build/release
	mkdir -p "$(EVIDENCE_DIR)"
	C1_TEST_RAW_FIXTURE="$(C1_TEST_RAW_FIXTURE)" C1_GEOMETRY_EVIDENCE="$(abspath $(EVIDENCE_DIR))/geometry" C1_LENS_EVIDENCE="$(abspath $(EVIDENCE_DIR))/lens" C1_PERSPECTIVE_EVIDENCE="$(abspath $(EVIDENCE_DIR))/perspective" C1_KEYSTONE_EVIDENCE="$(abspath $(EVIDENCE_DIR))/keystone" C1_CATALOG_EVIDENCE="$(abspath $(EVIDENCE_DIR))/catalog" C1_EXISTING_EVIDENCE="$(abspath $(EVIDENCE_DIR))/existing" C1_INVENTORY_EVIDENCE="$(abspath $(EVIDENCE_DIR))/inventory.json" /usr/bin/time -p caffeinate -i python3 -B Tests/release_integration_test.py "$(ARCHIVE)" --suites $(QUALIFY_SUITES)

# All regular live matrices, without deliberate fault injection.
qualify-extended:
	$(MAKE) qualify QUALIFY_SUITES=all
# Relevant recovery changes only; reuse a current archive without rerunning regular suites.
qualify-recovery:
	@test -f "$(C1_TEST_RAW_FIXTURE)" || { echo 'Set C1_TEST_RAW_FIXTURE to an existing RAW file.' >&2; exit 1; }
	@test -f "$(ARCHIVE)" || { echo 'Build an archive first with make archive or make qualify.' >&2; exit 1; }
	@test -n "$(EVIDENCE_DIR)" && test ! -e "$(EVIDENCE_DIR)" || { echo 'Set EVIDENCE_DIR to a new directory.' >&2; exit 1; }
	C1_TEST_RAW_FIXTURE="$(C1_TEST_RAW_FIXTURE)" C1_RECOVERY_FIXTURE_PARENT="$(C1_RECOVERY_FIXTURE_PARENT)" C1_RECOVERY_SHUTDOWN_MODE="$(C1_RECOVERY_SHUTDOWN_MODE)" /usr/bin/time -p caffeinate -i python3 -B Tests/recovery_integration_test.py "$(ARCHIVE)" "$(abspath $(EVIDENCE_DIR))" --cases $(RECOVERY_CASES)

# Broad qualification when the change affects all regular and recovery paths.
qualify-full: qualify-extended
	$(MAKE) qualify-recovery RECOVERY_CASES=all EVIDENCE_DIR="$(abspath $(EVIDENCE_DIR))/recovery"

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

# Dedicated compound paths; uses the normal recovery fixture/ownership guards.
.PHONY: qualify-recipes-recovery
RECIPE_RECOVERY_CASES ?= native tonal geometry preview mcp-death
qualify-recipes-recovery:
	@test -f "$(C1_TEST_RAW_FIXTURE)" || { echo 'Set C1_TEST_RAW_FIXTURE to an existing RAW file.' >&2; exit 1; }
	@test -f "$(ARCHIVE)" || { echo 'Build an archive first with make archive or make qualify.' >&2; exit 1; }
	@test -n "$(EVIDENCE_DIR)" && test ! -e "$(EVIDENCE_DIR)" || { echo 'Set EVIDENCE_DIR to a new directory.' >&2; exit 1; }
	C1_TEST_RAW_FIXTURE="$(C1_TEST_RAW_FIXTURE)" C1_RECOVERY_FIXTURE_PARENT="$(C1_RECOVERY_FIXTURE_PARENT)" C1_RECOVERY_SHUTDOWN_MODE="$(C1_RECOVERY_SHUTDOWN_MODE)" /usr/bin/time -p caffeinate -i python3 -B Tests/recipe_recovery_integration_test.py "$(ARCHIVE)" "$(abspath $(EVIDENCE_DIR))" --cases $(RECIPE_RECOVERY_CASES)
