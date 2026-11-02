---
name: setup
description: Set up c1, the Capture One command line, before first use or when a c1 call fails with not-running, permission-denied, timeout, or "command not found". Checks the install, macOS Automation permission, doctor, the Catalog backup, and which c1 commands run without asking.
---

# Set up c1

c1 edits photos in the Capture One Catalog or Session the photographer has open. Work through these steps in order; each ends on a check.

## 1. Find c1

Run `c1 --version`.

- **Prints a version**: go on.
- **`Unknown option '--version'`**: an old c1 (v1) comes first on PATH, and the agent would run it instead of the plugin's. `command -v c1` shows where; ask the photographer to remove it (with `make uninstall` in its checkout, or by deleting that `c1` and the `c1-mcp` beside it). c1 cannot be set up while it stays.
- **Missing in Claude Code**: the plugin puts its `bin/` on the shell's PATH while it is enabled. Ask the photographer to run `/plugin`, enable `c1`, and start a new session.
- **Missing elsewhere (Codex, a plain shell)**: c1 sits in the unzipped plugin folder at `bin/c1`. Ask the photographer to link it onto their PATH, then check again:

  ```sh
  mkdir -p ~/.local/bin && ln -sf "/path/to/c1-plugin/bin/c1" ~/.local/bin/c1
  ```

  If `~/.local/bin` is not on PATH, they add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc`.

Done when `c1 --version` prints a version.

## 2. Automation permission and doctor

Capture One must be running with the Catalog or Session open. Run `c1 doctor`.

- **The first call can hang** until `timeout`: macOS is showing the Automation consent dialog for the app running c1 (Terminal, Claude, Codex), often hidden behind other windows. Tell the photographer to look for it and click **Allow**, then run `c1 doctor` again.
- **`permission-denied`**: the photographer allows it under **System Settings > Privacy & Security > Automation**, by turning on Capture One under the app that runs c1.
- **`not-running`**, or a result without `document` (its warning says no document is open): the photographer opens Capture One and the document. In Codex, `not-running` while Capture One is open means the sandbox hides it: c1 needs Codex started with `--sandbox danger-full-access`.

Done when `doctor` returns a `document`. Read its `warnings` aloud to the photographer: an untested Capture One build, an old Catalog backup, or scripting terms that differ from the ones c1 was built with. Warnings never block.

## 3. Catalog backup

Before c1 writes to a Catalog, the photographer makes a fresh **File > Backup Catalog**. c1 keeps its own snapshots for `revert`, but a native backup is the only full restore. doctor warns when the last backup is missing or older than a day; Sessions have no backup warning.

## 4. Which commands run without asking

Claude Code asks before every shell command unless an allow rule covers it. Offer the photographer two choices, and write rules only with their consent:

- **Read-only** (the default): commands that change no variant run without asking; `set`, `action` and `revert` still ask each time.
- **All**: every c1 command runs without asking.

`c1 --commands` lists each command with `readOnly`. The script writes one rule per command, `Bash(c1 <command> *)`, into `permissions.allow` of the user's Claude Code settings (`$CLAUDE_CONFIG_DIR/settings.json`, default `~/.claude/settings.json`). It keeps every other rule and is safe to run again; switching choice removes the rules the new choice leaves out.

```sh
osascript -l JavaScript "${CLAUDE_PLUGIN_ROOT}/skills/setup/allow-c1.js" read-only "$(command -v c1)"
osascript -l JavaScript "${CLAUDE_PLUGIN_ROOT}/skills/setup/allow-c1.js" all "$(command -v c1)"
```

Outside Claude Code, `${CLAUDE_PLUGIN_ROOT}` is the unzipped plugin folder. Rules take effect in a new session, and only in Claude Code's default permission mode: in auto mode its own safety check decides, so a write can run without asking. In Codex, approvals come from its own sandbox and approval settings, not from these rules.

Done when the photographer has chosen, and the script printed `updated` or `unchanged`.
