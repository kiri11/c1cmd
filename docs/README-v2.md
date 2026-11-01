# c1: Capture One for AI agents

c1 lets an AI agent in Claude Code or Codex read and edit the photos in your open Capture One Catalog or Session. It ships as a plugin: one command-line program, `c1`, and four skills that teach the agent how to set up, edit, learn your style and crop.

> Draft for c1 v2. It replaces `README.md` at the cutover.

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
claude plugin marketplace add https://github.com/kiri11/c1cmd/releases/latest/download/marketplace.json
claude plugin install c1@c1
```

Start a new session. The skills appear as `/c1:setup`, `/c1:edit`, `/c1:learn-style` and `/c1:crop-policy`, and the agent can run `c1`. To update, run `claude plugin marketplace update c1` and then `claude plugin update c1@c1`.

### Codex

1. Download `c1-plugin.zip` from the [latest release](https://github.com/kiri11/c1cmd/releases/latest) and unzip it where it can stay, for example in `~/Applications`.
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

**Codex's sandbox (pending).** Whether Codex's default sandbox lets `c1` send Apple Events to Capture One, and which setting it needs if not, is checked in the next pre-release test. Until then, run c1 in Codex with a sandbox mode that allows it, or approve each call.

### Without a plugin system

Unzip `c1-plugin.zip`, link `bin/c1` onto your PATH as in the Codex steps, and copy the folders under `skills/` into your agent's skills directory.

## First run

1. Open Capture One and the Catalog or Session you want to work on.
2. Ask your agent to run the setup skill (`/c1:setup` in Claude Code). It checks the install, runs `c1 doctor`, and offers to let read-only c1 commands run without asking each time.
3. **Allow Automation access.** The first c1 call makes macOS ask whether the app running your agent (Terminal, Claude or Codex) may control Capture One. The dialog can hide behind other windows; until you click **Allow**, the call waits and then times out. To change it later, go to **System Settings > Privacy & Security > Automation**.
4. **Back up a Catalog** with **File > Backup Catalog** before the agent edits it. `doctor` warns when the last backup is older than a day.

## Working with the agent

- Take turns: while the agent edits, leave those photos alone in Capture One, and tell it when you edit yourself.
- Keep one document open while it works.
- Ask it to revert anything you do not like: `revert` restores the settings from before its first change.
- For a mask only you can draw (a brush, gradient or a single subject among several), the agent asks you to draw a layer and name it, then continues on that layer.

## Reference

`c1 --help` lists the commands, and `c1 <command> --help` gives each one's arguments, ranges and errors. The same facts, with example results, are in [docs/reference/commands.md](reference/commands.md).
