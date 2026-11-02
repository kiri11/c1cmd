#!/bin/sh
# Builds the v2 plugin: dist/c1-plugin.zip (bin/c1, skills, the Claude Code and Codex manifests),
# dist/marketplace.json pointing at that zip's release URL, and dist/SHA256SUMS.
# usage: scripts/package-plugin.sh VERSION [OUTPUT_DIR]
set -eu
VERSION=${1:?usage: package-plugin.sh VERSION [OUTPUT_DIR]}
OUTPUT=${2:-dist}
REPOSITORY=${C1_REPOSITORY:-kiri11/c1cmd}
case "$VERSION" in *[!a-zA-Z0-9._-]*|''|[!a-zA-Z0-9]*) echo "Invalid version: $VERSION" >&2; exit 1;; esac
cd "$(dirname "$0")/.."
ROOT=$(pwd)
mkdir -p "$OUTPUT"
OUTPUT=$(cd "$OUTPUT" && pwd)

STAGE=$(mktemp -d)
VERSION_FILE=Sources/C1Kit/Version.swift
cp "$VERSION_FILE" "$STAGE/Version.swift.orig"
# The version is compiled in for this build only; the checked-in file stays at dev.
trap 'cp "$STAGE/Version.swift.orig" "$ROOT/$VERSION_FILE"; rm -rf "$STAGE"' EXIT
sed "s/static let current = \"dev\"/static let current = \"$VERSION\"/" "$STAGE/Version.swift.orig" > "$VERSION_FILE"
grep -q "\"$VERSION\"" "$VERSION_FILE"
swift build -c release --product c1
BUILT=$(swift build -c release --product c1 --show-bin-path)/c1
cp "$STAGE/Version.swift.orig" "$VERSION_FILE"

PLUGIN="$STAGE/c1-plugin"
mkdir -p "$PLUGIN/bin" "$PLUGIN/.claude-plugin" "$PLUGIN/.agents/plugins"
cp "$BUILT" "$PLUGIN/bin/c1"
chmod 755 "$PLUGIN/bin/c1"
codesign -s - --force "$PLUGIN/bin/c1"
cp -R skills "$PLUGIN/skills"
cp LICENSE "$PLUGIN/LICENSE"

DESCRIPTION="Edit photos in Capture One from Claude Code or Codex: a command line and skills for setup, editing, style learning and crop policy."
manifest() {
    cat <<JSON
{
  "name": "c1",
  "version": "$VERSION",
  "description": "$DESCRIPTION",
  "author": { "name": "kiri11" },
  "homepage": "https://github.com/$REPOSITORY",
  "repository": "https://github.com/$REPOSITORY",
  "license": "MIT",
  "keywords": ["capture-one", "photo-editing", "photography"]
}
JSON
}
manifest > "$PLUGIN/.claude-plugin/plugin.json"
# Codex's docs keep a portable plugin's manifest at the root; .codex-plugin/ is their fallback.
manifest > "$PLUGIN/plugin.json"
# Codex adds the unzipped folder itself as a marketplace holding this one plugin.
cat > "$PLUGIN/.agents/plugins/marketplace.json" <<JSON
{
  "name": "c1",
  "interface": { "displayName": "c1" },
  "plugins": [
    {
      "name": "c1",
      "source": { "source": "local", "path": "./" },
      "policy": { "installation": "AVAILABLE" },
      "category": "Productivity"
    }
  ]
}
JSON

rm -f "$OUTPUT/c1-plugin.zip"
(cd "$STAGE" && COPYFILE_DISABLE=1 zip -q -r -X "$OUTPUT/c1-plugin.zip" c1-plugin)
SHA=$(shasum -a 256 "$OUTPUT/c1-plugin.zip" | cut -d' ' -f1)
cat > "$OUTPUT/marketplace.json" <<JSON
{
  "name": "c1",
  "description": "c1, the Capture One command line and skills",
  "owner": { "name": "kiri11", "url": "https://github.com/kiri11" },
  "plugins": [
    {
      "name": "c1",
      "description": "$DESCRIPTION",
      "version": "$VERSION",
      "source": {
        "source": "archive",
        "url": "https://github.com/$REPOSITORY/releases/download/$VERSION/c1-plugin.zip",
        "sha256": "$SHA"
      }
    }
  ]
}
JSON
(cd "$OUTPUT" && shasum -a 256 c1-plugin.zip marketplace.json > SHA256SUMS)
echo "$OUTPUT/c1-plugin.zip $SHA"
