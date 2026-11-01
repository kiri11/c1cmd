#!/bin/sh
# Checks a built c1-plugin.zip without Capture One: the unzipped binary keeps its execute bit and
# signature and runs alone; setup's permission script converges; and, when their CLIs are found, the
# plugin installs into an isolated Claude Code and Codex configuration. The user's own configuration
# is never read or written.
# usage: scripts/v2-check-plugin.sh dist/c1-plugin.zip [--document <Catalog or Session>]
set -eu
ZIP=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
DOCUMENT=${3:-}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL $*" >&2; exit 1; }
pass() { echo "ok   $*"; }

cd "$WORK"
unzip -q "$ZIP"
C1="$WORK/c1-plugin/bin/c1"
[ -x "$C1" ] || fail "bin/c1 lost its execute bit"; pass "bin/c1 is executable after unzip"
codesign -v "$C1" || fail "codesign -v"; pass "codesign -v passes"
[ "$(ls "$WORK/c1-plugin/bin")" = c1 ] || fail "bin/ holds more than c1"; pass "bin/ holds c1 alone, no bundle"
VERSION=$("$C1" --version); pass "c1 --version: $VERSION"
grep -q "\"version\": \"$VERSION\"" "$WORK/c1-plugin/.claude-plugin/plugin.json" || fail "plugin.json version differs from c1 --version"
"$C1" --help | grep -q crop_preview || fail "c1 --help"
"$C1" set --help | grep -q "adjustments.exposure" || fail "c1 set --help"; pass "help prints from the built-in table"
set +e; "$C1" bogus >/dev/null 2>&1; status=$?; set -e
[ "$status" = 2 ] || fail "usage error exit $status"; pass "usage error exits 2"
if [ -n "$DOCUMENT" ]; then
    "$C1" list '{"limit":1}' --document "$DOCUMENT" | grep -q '"variants"' || fail "--document read"; pass "--document read of $DOCUMENT"
fi

SETTINGS="$WORK/settings/settings.json"
SCRIPT="$WORK/c1-plugin/skills/setup/allow-c1.js"
for mode in read-only all read-only; do
    osascript -l JavaScript "$SCRIPT" "$mode" "$C1" "$SETTINGS" | grep -q '^updated' || fail "$mode did not update"
    osascript -l JavaScript "$SCRIPT" "$mode" "$C1" "$SETTINGS" | grep -q '^unchanged' || fail "a second $mode run changed the file"
done
grep -q '"Bash(c1 get \*)"' "$SETTINGS" && ! grep -q '"Bash(c1 set \*)"' "$SETTINGS" || fail "read-only rules"
pass "permission script: read-only, all, read-only each converge, and a second run changes nothing"

CLAUDE=${CLAUDE_BIN:-$(command -v claude || true)}
if [ -n "$CLAUDE" ]; then
    export CLAUDE_CONFIG_DIR="$WORK/claude-config"
    mkdir -p "$CLAUDE_CONFIG_DIR" "$WORK/.claude-plugin"
    cat > "$WORK/.claude-plugin/marketplace.json" <<JSON
{"name": "c1-local", "owner": {"name": "check"}, "plugins": [{"name": "c1", "source": "./c1-plugin"}]}
JSON
    "$CLAUDE" plugin validate "$WORK/c1-plugin" | grep -q 'Validation passed' || fail "claude plugin validate"
    "$CLAUDE" plugin marketplace add "$WORK" >/dev/null
    "$CLAUDE" plugin install c1@c1-local >/dev/null
    "$CLAUDE" plugin list > "$WORK/list.txt"
    grep -A6 'c1@c1-local' "$WORK/list.txt" | grep -q 'Status: .* enabled' || fail "claude plugin list"
    "$CLAUDE" plugin details c1 > "$WORK/details.txt"
    for skill in setup edit learn-style crop-policy; do grep -q "$skill" "$WORK/details.txt" || fail "claude skill $skill"; done
    ROOT=$(sed -n 's/^ *Read from: //p' "$WORK/list.txt" | head -1)
    [ -x "$ROOT/bin/c1" ] && "$ROOT/bin/c1" --version >/dev/null || fail "bin/c1 in the plugin Claude Code reads"
    pass "Claude Code: validated, installed and enabled; skills setup, edit, learn-style, crop-policy; its bin/c1 runs"
    unset CLAUDE_CONFIG_DIR
else
    echo "skip Claude Code: no claude CLI (set CLAUDE_BIN)"
fi

CODEX=${CODEX_BIN:-$(command -v codex || true)}
if [ -n "$CODEX" ]; then
    export CODEX_HOME="$WORK/codex-home"
    mkdir -p "$CODEX_HOME"
    (cd "$WORK" && "$CODEX" plugin marketplace add ./c1-plugin >/dev/null)
    "$CODEX" plugin add c1@c1 >/dev/null
    "$CODEX" plugin list | grep 'c1@c1' | grep -q 'installed, enabled' || fail "codex plugin list"
    CACHED=$(find "$CODEX_HOME/plugins" -path '*/bin/c1' -type f | head -1)
    [ -x "$CACHED" ] && "$CACHED" --version >/dev/null || fail "Codex cached bin/c1"
    for skill in setup edit learn-style crop-policy; do [ -f "$(dirname "$(dirname "$CACHED")")/skills/$skill/SKILL.md" ] || fail "codex skill $skill"; done
    pass "Codex: marketplace added from the unzipped folder, plugin installed and enabled; cached bin/c1 runs; four skills cached"
    unset CODEX_HOME
else
    echo "skip Codex: no codex CLI (set CODEX_BIN)"
fi
