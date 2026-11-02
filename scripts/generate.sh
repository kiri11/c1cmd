#!/bin/sh
# Writes the generated files: the built-in resources and sdef terms, and docs/reference/commands.md.
# A generated Swift file changes c1's build, so the second pass regenerates from the rebuilt code.
set -eu
cd "$(dirname "$0")/.."
swift run C1KitTests --generate
swift run C1KitTests --generate
