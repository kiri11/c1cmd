# c1 — Unofficial Capture One CLI & MCP Server

[![CI](https://github.com/kiri11/c1cmd/actions/workflows/ci.yml/badge.svg)](https://github.com/kiri11/c1cmd/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Did you ever want to give your agent access to Capture One? Probably not. But now You can!

`c1` reads, adjusts, compares, and previews Capture One variants through a CLI and a stdio MCP server. 

Works with the **currently open Session or Catalog**. Catalog editing requires an explicit opt-in.

Both adapters share `CaptureOneCore` and one versioned request/response schema. Creative judgment and photographer review belong in the caller.

Capture One is a trademark of Capture One A/S. This independent project is not affiliated with, endorsed by, or sponsored by Capture One A/S. Capture One and RAW fixtures are not distributed with the project.

## Support boundary for v0.1

- **Qualified application:** Capture One **16.8.5.30** on Apple Silicon. Other 16.4+ through 16.x builds pass the compatibility check but are unverified; older or future major builds need `C1_ALLOW_UNTESTED_BUILD=1`. `doctor` reports whether the build matched. See [current scope](docs/MAINTAINING.md#current-scope-and-remaining-gates).
- **How to use it safely:** one open document, one operator, sequential calls, and turns between photographer and agent. The full rules are the [safety invariants](AGENTS.md#safety-invariants).
- **Documents:** Sessions (`.cosessiondb`) support editing and preview export. Catalogs are read-only unless [explicitly enabled](#catalog-editing-experimental).
- **Platform:** macOS 13+ is the deployment target, not a tested range. Intel and older macOS qualification is deferred.

This is a narrow first release, not a general-purpose automation API. Session creation, image import, moving or relinking originals, automatic keystone detection, style learning and general recipe export are outside v0.1. Expanded adjustments, curves, layers and masks are available through the experimental [native editing API](docs/reference/native-editing.md).

## Installation

Building requires Swift 5.9+ and the macOS command line tools. Capture One must be installed at `/Applications/Capture One.app` and running.

```sh
git clone https://github.com/kiri11/c1cmd.git
cd c1cmd
make build
make install
```

`make install` chooses a writable prefix, falling back to `~/.local`; override with `make install PREFIX="$HOME/.local"` and add its `bin` directory to `PATH` if necessary.

Both executables need **`c1_CaptureOneCore.bundle` beside them**. The Makefile installs it; with a release archive, keep its `bin` directory intact. Release archives on GitHub are ad-hoc signed, not notarized; build from source if macOS policy blocks a download.

## MCP setup

Configure your MCP client to launch the server over stdio:

```json
{
  "mcpServers": {
    "c1": {
      "command": "/absolute/path/to/bin/c1-mcp"
    }
  }
}
```

macOS Automation permission must allow the launching application to control Capture One. If calls return `permission-denied`, check **System Settings → Privacy & Security → Automation**. No network server, API key or port is involved; diagnostics go to stderr.

The server exposes 30 tools: `read_session_begin`, `read_session_end`, `read_session_status`, `catalog_get`, `catalog_inspect`, `catalog_variants`, `catalog_snapshot`, `native_set`, `native_action`, `doctor`, `doc_info`, `capabilities`, `schema`, `variants_list`, `variant_edit`, `variant_clone`, `variant_delete`, `variant_baseline`, `get`, `metadata_set`, `set`, `add`, `geometry_set`, `geometry_restore`, `reset`, `diff`, `dump`, `preview`, `operation_status`, and `request_status`. Recipe tools are listed in the [recipes reference](docs/reference/recipes.md#cli-and-mcp).

Start with `doctor` and check `allChecksPassed`, `writesEnabled` and `exactBuildMatched` before editing. `isSession` identifies the document type; it is not an editing permission. Agents should follow [AGENTS.md](AGENTS.md).

## Editing workflow

Photographer and agent take turns on **the same variants**. The agent prepares an existing variant for editing, which saves its current state and creates no duplicate:

```sh
c1 doctor
c1 doc info                     # keep openToken
c1 variants list --rating 5     # also check the folder or collection
c1 get <source-id>
c1 variant edit <source-id> --if-document <openToken> --if-state <stateHash>
c1 get <editing-ref>
c1 set <editing-ref> --if-state <fresh-stateHash> exposure=0.35 contrast=5
c1 preview <editing-ref>
c1 diff <editing-ref>
```

Review the preview before handing back. To put the saved crop, rotation and keystone back:

```sh
c1 get <editing-ref>
c1 geometry restore <editing-ref> --if-geometry-state <fresh-geometryStateHash>
```

Tonal values are restored with `set` and the saved `baselineAdjustments`; `reset` applies defaults and is not an undo. `variant clone` makes a separate comparison variant, and only such clones can be deleted.

Details: [editing](docs/reference/editing.md) (adjustment ranges, ratings and tags, selecting variants, progress, previews, errors), [crop, rotation and keystone](docs/reference/geometry.md), [native editing](docs/reference/native-editing.md) and [reference recipes](docs/reference/recipes.md).

## If a command times out

A failed write returns an `operationId`. Do not repeat the command. Check it:

```sh
c1 operation status <operationId>
```

An unresolved operation blocks further writes. Restart Capture One, reopen the same database and check the status again; the tool then records what it observes and unblocks writes. That record does not prove the edit succeeded, so review the photo and prepare a fresh editing reference to continue. Keep the `.c1` folder beside your document: it holds the journal needed for this. The rule is [safety invariant 4](AGENTS.md#safety-invariants); commands are in [recovery commands](docs/reference/editing.md#recovery-commands).

## Catalog editing (experimental)

You can edit existing variants directly in a main Catalog. First make a fresh **File → Backup Catalog** and keep your RAW backups; Capture One's [catalog backup](https://support.captureone.com/hc/en-us/articles/27502751010333-How-Catalog-and-Session-Backups-Work-in-Capture-One) covers the database and adjustments, not originals. `c1` does not create or verify it (see [safety invariant 5](AGENTS.md#safety-invariants)). Then enable **one exact Catalog**:

```sh
export C1_CATALOG_WRITE_PATH="/absolute/path/Main.cocatalog"
c1 doctor
```

For MCP, put the same variable in the server's `env` and restart the server. Unset it to turn Catalog writes off again.

- A package path is accepted when it holds exactly one `.cocatalogdb`; otherwise name the exact `.cocatalogdb` inside it.
- Unpackaged Catalog directories must name the exact `.cocatalogdb` file.
- Originals must be referenced, online and outside the Catalog; Catalog-stored originals are blocked.
- Journals and provenance live in `Main.cocatalog/.c1`; previews go to `Main.cocatalog.c1-output/c1-previews/`. If the Catalog has no usable default output location, preview sets it to that folder.

Read-only inspection needs no variable. `C1_TOOL_PROFILE=composition` restricts an agent to crop, rotation and keystone. Catalog fault recovery remains unqualified; see [current scope](docs/MAINTAINING.md#current-scope-and-remaining-gates).

## Faster browsing and closed Catalogs

During a long agent batch, `read-session begin` returns a `workflowId`; browsing calls that pass `--read-workflow <id>` use cached observations instead of per-photo native reads, and `read-session end` finishes before control returns to the photographer. Closed Catalogs can be read directly with `--database /absolute/path/Library.cocatalog/Library.cocatalogdb`, and `c1 catalog snapshot` copies one to a new SQLite file. Stored and cached reads never authorize edits. See the [Catalog reader](docs/reference/catalog-reader.md).

## Development

`make check` runs the offline Swift, Python and contract tests. Every push to `main` publishes a release, and live checks must run locally first; see the [maintainer guide](docs/MAINTAINING.md).

[MIT License](LICENSE).
