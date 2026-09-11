#!/bin/sh
set -eu
TAG=${1:?usage: package-release.sh TAG BUILD_DIR OUTPUT_DIR}
BUILD_DIR=${2:-.build/release}
OUTPUT_DIR=${3:-dist}
case "$TAG" in *[!a-zA-Z0-9._-]*|'') echo 'Invalid release tag' >&2; exit 1;; esac
ARCH=$(uname -m)
NAME="c1-${TAG}-macos-${ARCH}"
mkdir -p "$OUTPUT_DIR"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/$NAME/bin"
cp "$BUILD_DIR/c1" "$BUILD_DIR/c1-mcp" "$STAGE/$NAME/bin/"
cp -R "$BUILD_DIR/c1_CaptureOneCore.bundle" "$STAGE/$NAME/bin/"
cp README.md LICENSE AGENTS.md CHANGELOG.md "$STAGE/$NAME/"
cp -R docs "$STAGE/$NAME/"
mkdir -p "$STAGE/$NAME/examples"
cp examples/crop-proposals.py "$STAGE/$NAME/examples/"
codesign -s - --force "$STAGE/$NAME/bin/c1"
codesign -s - --force "$STAGE/$NAME/bin/c1-mcp"
COPYFILE_DISABLE=1 tar -czf "$OUTPUT_DIR/$NAME.tar.gz" -C "$STAGE" "$NAME"
(cd "$OUTPUT_DIR" && shasum -a 256 "$NAME.tar.gz" > "$NAME.tar.gz.sha256")
