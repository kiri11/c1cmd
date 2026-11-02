# c1: Capture One for AI agents

c1 lets an AI agent in Claude Code or Codex read and edit the photos in your open Capture One Catalog or Session. It ships as a plugin: one command-line program, `c1`, and four skills that teach the agent how to set up, edit, learn your style and crop.

## What c1 does

- **Reads** your photos: lists and filters them by rating, color tag, collection or edit state, reads every setting of a variant, and shows previews, side-by-side crop candidates, contact sheets and the camera's own JPEG.
- **Edits** them with absolute values: exposure, white balance, curves, the color editor, lens correction, rotation, keystone, crop, rating, color tag and layers. Every value is checked against the range Capture One accepts before it is sent.
- **Keeps your work safe.** c1 never touches your original files and never deletes a variant. Before its first change to a photo it saves that photo's settings, and `revert` brings them back. Every change is logged in `~/.c1`. It never deletes or overwrites a mask it did not create.
- **Learns your style** from photos you already edited, and follows your crop policy.

c1 is tested on Capture One 16.8.5.30 on macOS. On other builds, `doctor` warns and c1 still runs.

## Install

Claude Code downloads the plugin itself; for Codex you unzip one file.

### Claude Code

```sh
claude plugin marketplace add kiri11/c1cmd
claude plugin install c1@c1
```

The marketplace is this repository; the plugin itself downloads from the latest release. If your shell has no `claude` command, run the same steps in a session as `/plugin marketplace add kiri11/c1cmd` and `/plugin install c1@c1`.

Start a new session. The skills appear as `/c1:setup`, `/c1:edit`, `/c1:learn-style` and `/c1:crop-policy`, and the agent can run `c1`. To update, run `claude plugin marketplace update c1` and then `claude plugin update c1@c1`.

### Codex

1. Download and unzip the plugin in Terminal, where it can stay:

   ```sh
   mkdir -p ~/Applications && cd ~/Applications
   curl -fLO https://github.com/kiri11/c1cmd/releases/latest/download/c1-plugin.zip
   unzip -o c1-plugin.zip && rm c1-plugin.zip
   ```

   Use `curl`, not a browser. macOS flags a file downloaded in a browser, and then refuses to run `c1` ("Apple could not verify “c1” is free of malware"). If that happened, run `xattr -dr com.apple.quarantine ~/Applications/c1-plugin`.
2. Add it and install the plugin:

   ```sh
   codex plugin marketplace add ~/Applications/c1-plugin
   codex plugin add c1@c1
   ```

3. Put `c1` on your PATH, so Codex and your shell can run it:

   ```sh
   mkdir -p ~/.local/bin
   ln -sf ~/Applications/c1-plugin/bin/c1 ~/.local/bin/c1
   ```

   If `c1 --version` then says "command not found", add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` and open a new terminal.

   `c1 --version` must print 2.0 or later. An older c1 may come first on your PATH: see [Upgrading from c1 v1](#upgrading-from-c1-v1).

**Codex's sandbox.** `c1` has to run outside Codex's sandbox. Under `read-only` it cannot write its lock file, and under `workspace-write` it cannot see Capture One, so it reports `not-running` while Capture One is open. Start Codex with `--sandbox danger-full-access` for a c1 session (tested with Codex 0.153.4). In Codex the skills appear as `$c1:setup`, `$c1:edit`, `$c1:learn-style` and `$c1:crop-policy`.

### Upgrading from c1 v1

c1 v2 replaces v1 and its MCP server. Claude Code adds the plugin's `c1` at the end of your PATH, so an old `c1` earlier on it would run instead. Remove v1 before you install:

1. Find the folder v1 was installed in: `command -v c1-mcp` prints the path of v1's MCP server there. v1 chose `/usr/local/bin`, `/opt/homebrew/bin` or `~/.local/bin`.
2. Delete `c1`, `c1-mcp` and `c1_CaptureOneCore.bundle` from that folder. `make uninstall` in a v1 checkout does the same, but a checkout updated to v2 no longer has it.
3. Remove any `c1-mcp` entry from your MCP client's configuration.

### Without a plugin system

Unzip `c1-plugin.zip`, link `bin/c1` onto your PATH as in the Codex steps, and copy the folders under `skills/` into your agent's skills directory.

## First run

1. Open Capture One and the Catalog or Session you want to work on.
2. Ask your agent to run the setup skill (`/c1:setup` in Claude Code). It checks the install, runs `c1 doctor`, and offers to let read-only c1 commands run without asking each time. Edits still ask in Claude Code's default permission mode; in auto mode, Claude Code's own check decides instead.
3. **Allow Automation access.** The first c1 call makes macOS ask whether the app running your agent (Terminal, Claude or Codex) may control Capture One. The dialog can hide behind other windows; until you click **Allow**, the call waits and then times out. To change it later, go to **System Settings > Privacy & Security > Automation**.
4. **Back up a Catalog** with **File > Backup Catalog** before the agent edits it. `doctor` warns when the last backup is older than a day.

## Working with the agent

- Take turns: while the agent edits, leave those photos alone in Capture One, and tell it when you edit yourself.
- Keep one document open while it works.
- Ask it to revert anything you do not like: `revert` restores the settings from before its first change.
- For a mask only you can draw (a brush, gradient or a single subject among several), the agent asks you to draw a layer and name it, then continues on that layer.

## Reference

`c1 --help` lists the commands, and `c1 <command> --help` gives each one's arguments, ranges and errors. The same facts, with example results, are in [docs/reference/commands.md](docs/reference/commands.md).
