# c1 — Unofficial Capture One CLI & MCP Server

[![CI](https://github.com/kiri11/c1cmd/actions/workflows/ci.yml/badge.svg)](https://github.com/kiri11/c1cmd/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Did you ever want to give your agent access to Capture One? Probably not. Now you can!

`c1` lets an AI agent read, adjust, compare and preview photos in the Capture One Session or Catalog you have open. It comes as a command-line tool (`c1`) and a local MCP server (`c1-mcp`) that share one core and one request/response schema. Creative judgment stays with you and the agent; `c1` supplies safe, checked access.

Capture One is a trademark of Capture One A/S. This independent project is not affiliated with, endorsed by, or sponsored by Capture One A/S. Capture One and RAW fixtures are not distributed with the project.

## What it does

- **Edits your existing variants.** The agent works on the same variants you do, taking turns with you. It saves each photo's current state before editing, so a change can be reviewed with a preview and a diff and restored.
- **Tonal, rating and color-tag edits**, plus crop, rotation and keystone correction.
- **Expanded native editing** (experimental): most adjustment properties, curves, lens corrections, layers and masks.
- **Reference recipes** (experimental): capture a look from a reference photo, verify it on a disposable copy, then apply it to other photos.
- **Browsing**: filter by rating, collection and selection, and read closed Catalogs directly from their database.
- **Camera level hints**: a suggested leveling rotation and lens tilt from the camera's level sensor, read from the original file. Needs [exiftool](https://exiftool.org) (`brew install exiftool`).

RAW files are never modified. Every edit is checked against the photo's current state and recorded in a journal beside your document before it is sent, so an interrupted edit can be investigated instead of guessed at. Catalogs are read-only unless you enable editing for one specific Catalog.

**Requirements:** Capture One **16.8.5.30** on an Apple Silicon Mac is the qualified setup. Other 16.x builds are allowed but unverified.

## Install from a release archive

Download the latest `c1-<tag>-macos-arm64.tar.gz` and its `.sha256` file from [Releases](https://github.com/kiri11/c1cmd/releases), then:

```sh
shasum -a 256 -c c1-<tag>-macos-arm64.tar.gz.sha256
tar -xzf c1-<tag>-macos-arm64.tar.gz
mv c1-<tag>-macos-arm64 ~/Applications/c1
~/Applications/c1/bin/c1 doctor
```

Keep the `bin` folder intact: `c1` and `c1-mcp` need `c1_CaptureOneCore.bundle` beside them. Add `bin` to your `PATH` if you want the `c1` command everywhere. The binaries are ad-hoc signed, not notarized; if macOS blocks them, build from source instead.

The archive contains:

| Path | Contents |
|---|---|
| `bin/` | `c1`, `c1-mcp` and their resource bundle |
| `AGENT_GUIDE.md` | Setup, safety rules and workflow for the agent |
| `docs/reference/` | Command reference for editing, geometry, native editing, recipes and the Catalog reader |
| `examples/` | Example scripts and presets |

To build from source instead (Swift 5.9+ and the command line tools): `git clone https://github.com/kiri11/c1cmd.git`, then `make build install`.

## MCP setup

Add the server to your MCP client's configuration, using the absolute path:

```json
{
  "mcpServers": {
    "c1": {
      "command": "/Users/you/Applications/c1/bin/c1-mcp"
    }
  }
}
```

The first call asks macOS for permission to control Capture One. If it was refused, allow the client app under **System Settings → Privacy & Security → Automation**.

Then point your agent at [AGENT_GUIDE.md](AGENT_GUIDE.md) from the archive. It tells the agent how to check the setup and which rules keep your edits and Catalog safe.

### Editing a Catalog

Make a fresh **File → Backup Catalog** first and keep your RAW backups. Then add the exact Catalog path to the server's environment and restart the server:

```json
"env": {"C1_CATALOG_WRITE_PATH": "/Users/you/Pictures/Main.cocatalog"}
```

Remove the variable to make Catalogs read-only again.

## Development

Contributor and agent instructions are in [AGENTS.md](https://github.com/kiri11/c1cmd/blob/main/AGENTS.md), and validation and releases in the [maintainer guide](https://github.com/kiri11/c1cmd/blob/main/docs/MAINTAINING.md).

[MIT License](LICENSE).
