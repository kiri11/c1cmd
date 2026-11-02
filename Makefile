VERSION ?= dev

.PHONY: all build check plugin smoke clean

all: build

build:
	swift build -c release --product c1

# Offline: builds c1 and runs the unit tests against the fake Capture One, including the generated-file checks.
check:
	swift build --product c1
	swift run C1KitTests

# dist/c1-plugin.zip, dist/marketplace.json and dist/SHA256SUMS, with VERSION compiled in.
plugin:
	./scripts/package-plugin.sh "$(VERSION)" dist
	./scripts/check-plugin.sh dist/c1-plugin.zip

# Live, on disposable documents: needs Capture One 16.8.5.30 with no document open and C1_TEST_RAW_FIXTURE.
smoke: plugin
	@test -f "$(C1_TEST_RAW_FIXTURE)" || { echo 'Set C1_TEST_RAW_FIXTURE to an existing RAW file.' >&2; exit 1; }
	caffeinate -i python3 -B scripts/smoke.py --zip dist/c1-plugin.zip

clean:
	swift package clean
