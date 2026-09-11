# c1 — Unofficial Capture One CLI & MCP Server

[![CI](https://github.com/kiri11/c1cmd/actions/workflows/ci.yml/badge.svg)](https://github.com/kiri11/c1cmd/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

`c1` reads, adjusts, compares, and previews Capture One variants through a CLI and a stdio MCP server. Both adapters share `CaptureOneCore` and one versioned request/response schema. Creative judgment and photographer review belong in the caller.

Capture One is a trademark of Capture One A/S. This independent project is not affiliated with, endorsed by, or sponsored by Capture One A/S. Capture One and RAW fixtures are not distributed with the project.

## Support boundary for v0.1

- **Qualified application:** Capture One **16.8.5.30**, on Apple Silicon. The retained M0 evidence is from an M1 Pro running macOS 26.4.1. See [release validation](docs/RELEASE_VALIDATION.md) for the current decision and remaining distribution gates; the [M0 report](docs/m0_requalification_16.8.5.30.md) is historical evidence.
- **One open document:** the implementation rejects operations when more than one document is open. Editing and preview export require a Session (`.cosessiondb`); Catalogs support read-only inspection.
- **One operator, sequential calls:** keep the Session open throughout a workflow. Do not switch/reopen/replace databases, edit in the UI, or launch competing exports during a command. The advisory lock serializes cooperating c1 writers; it does not lock the photographer UI, other automation, or delayed Apple Events. Multi-process workflows remain unqualified.
- **Reference lifetime:** a working reference is bound to the canonical database file identity, Capture One process/launch, and parent-image path. Restarting Capture One or replacing the database invalidates it; create a fresh clone. Capture One does not expose a reliable same-file close/reopen token within one application launch. Such workflows remain unsupported, rather than being presented as automatically detected.
- **Other builds:** 16.4+ through 16.x are permitted by the compatibility check, but are **unverified**, not qualified support. Older/future major builds require `C1_ALLOW_UNTESTED_BUILD=1`. Check `doctor` for the tested-build match before editing.
- **Platform:** the package targets macOS 13+, but this is a deployment target, not evidence that every macOS version is tested. Intel and older macOS runtime qualification are deferred.

This is a narrow first release, not a general-purpose Capture One automation API. Session creation, image import, layers/masks, keystone correction, style learning, and general recipe export are outside v0.1.

## Installation

Building requires Swift 5.9+ and the macOS command line tools. Capture One must be installed at `/Applications/Capture One.app` and running for application operations.

```sh
git clone https://github.com/kiri11/c1cmd.git
cd c1cmd
make build
make install
```

`make install` chooses a writable prefix, falling back to `~/.local`. Override with `make install PREFIX="$HOME/.local"`. Add its `bin` directory to `PATH` if necessary.

Both executables require **`c1_CaptureOneCore.bundle` beside them**. The Makefile installs it. When using a release archive, keep its `bin` directory intact; copying only `c1` or `c1-mcp` is insufficient.

Release binaries are ad-hoc signed, not Developer ID notarized. Source builds are available if macOS policy blocks a downloaded binary.

## MCP setup

Configure your MCP client to launch the installed server over stdio:

```json
{
  "mcpServers": {
    "c1": {
      "command": "/absolute/path/to/bin/c1-mcp"
    }
  }
}
```

macOS Automation permission must allow the launching application to control Capture One. If calls return `permission-denied`, inspect **System Settings → Privacy & Security → Automation**. Do not enable the untested-build override unless deliberately qualifying another build.

No network server, API key, or listening port is required. Diagnostics go to stderr; stdout is reserved for MCP transport. Client configuration locations differ; consult your client's documentation. Start with `doctor`, `doc_info`, and `variants_list`, and check `isSession` and `exactBuildMatched` before editing.

The default server exposes 17 tools: `doctor`, `doc_info`, `capabilities`, `schema`, `variants_list`, `variant_clone`, `variant_delete`, `variant_baseline`, `get`, `set`, `add`, `geometry_set`, `reset`, `diff`, `dump`, `preview`, and `operation_status`.

`preview` creates files and configures the reserved `c1-preview` recipe, so it is declared a mutating tool. Its response includes JPEG image content plus JSON metadata. Other tool results are JSON text content.

## Editing workflow

Open one Session in Capture One, then:

```sh
c1 doctor
c1 doc info
c1 variants list
c1 variant clone <source-id>
c1 get <working-ref>
c1 set <working-ref> --if-state <stateHash-from-get> exposure=0.35 contrast=5
c1 preview <working-ref>
c1 diff <working-ref>
```

Review the preview before keeping the proposal. To discard it:

```sh
c1 variant delete <working-ref>
```

Only managed working clones (`c1_wrk_<uuid>`) can be adjusted or deleted. Native IDs and original variants are rejected by mutation methods. The RAW byte-preservation evidence is from fixture tests; c1 does not hash every user's RAW before every command.

`set` applies absolute values; `add` applies deltas. `reset` restores exposure/contrast/saturation defaults and the working reference's baseline white balance. Use `variant baseline <source-id>` to create a managed variant with native New Variant defaults. `diff <ref1> <ref2>` compares two variants; `dump` exports batched JSONL.

### Supported adjustments

| Field | Aliases | Absolute range |
|---|---|---|
| exposure | exp | -4 to 4 EV |
| contrast | — | -50 to 50 |
| saturation | sat | -100 to 100 |
| temperature | kelvin, temp | 800 to 14000 K |
| tint | — | -50 to 50 |

All values must be finite. Writes touch requested fields only; white balance is written and checked as a temperature/tint pair. Bounds, managed identity, and the state precondition are checked before dispatch. The handler checks the expected five-field state again immediately before its setters. Apple Event property writes are sequential, not atomic transactions: a later failure can leave an earlier field applied. Do not edit concurrently in the UI.

MCP accepts either a nested `adjustments` object or flat fields. Mixed forms, duplicate aliases, unknown fields, and wrong types are rejected. `dump.batchSize` must be 1–1000; preview timeout must be greater than zero and at most 300 seconds.

### Crop and rotation

`c1 geometry set` / MCP `geometry_set` applies an absolute crop and rotation to a managed clone. It requires **`geometryStateHash` from `get`**, passed as `--if-geometry-state` / `ifGeometryState`. This versioned token includes geometry and the tonal hash; the existing `stateHash` and tonal commands are unchanged. `get`, `dump`, and `diff` now include geometry; newly cloned variants retain a geometry baseline. Older provenance records remain readable but lack that baseline.

```sh
c1 get <working-ref>
c1 geometry set <working-ref> --if-geometry-state <geometryStateHash> --rotation 1.2 --aspect-ratio 1.5
c1 preview <working-ref> --full-frame
# Inspect the rotated context, then choose an explicit composition and re-read get:
c1 geometry set <working-ref> --if-geometry-state <fresh-geometryStateHash> --crop 3000,2100,4500,3000
c1 preview <working-ref>
c1 diff <working-ref>
```

Use **1.5 (3:2) for landscape** and **0.75 (3:4) for portrait** as the usual ratios. `aspectRatio` fits a centered crop inside conservative usable bounds; the agent should choose an explicit crop when centering would weaken the composition. `crop` and `aspectRatio` are mutually exclusive. Preserve meaningful diagonals, subjects, breathing room, and negative space; flag exceptions for photographer review.

MCP accepts `crop: {centerX, centerY, width, height}`, `rotation`, and/or `aspectRatio`, plus `workingRef`, `ifGeometryState`, and optional `dryRun`. Rotation is absolute, in native Capture One degrees (positive clockwise), limited to -45 through +45. A dry run predicts values without dispatch; its `geometryStateHash` is the current precondition, not a reserved or predicted post-write token.

Coordinates are pixels in the **oriented, rotated canvas**, with a bottom-left origin. Preview metadata includes the rendered `geometry.crop` and pixel dimensions. For a normalized preview point `(u, v)` measured from the top left, canvas coordinates are `x = centerX + (u - 0.5) * width`, `y = centerY + (0.5 - v) * height`. This maps to the current rotated canvas, not sensor coordinates. After changing rotation, render again before placing a crop using preview coordinates.

`--full-frame` / `fullFrame: true` renders the largest conservative context rectangle at the current rotation through a temporary managed clone, then deletes that clone. The response's `contextSourceRef` identifies the source; `workingRef` and `nativeVariantId` identify the rendered temporary clone. On failure, retain the clone and journal for inspection and use normal recovery. The source crop is never temporarily reset.

Geometry writes require **Capture One 16.8.5.30**. Existing keystone, lens distortion/shift, flips, crop-outside-image, and unqualified orientation combinations are rejected for editing/context mapping; their settings remain intact. Valid crops are limited to a conservative centered rectangle inside the rotated image, with two-pixel native rounding tolerance. See [geometry qualification](docs/geometry/16.8.5.30/README.md) for fixture coverage and limitations.

For a composition-only MCP agent, set `C1_MCP_PROFILE=composition` in the server environment. This hides and rejects `set`, `add`, `reset`, and `variant_baseline`; crop/rotation, inspection, cloning, deletion, preview, and recovery remain available. The caller supplies visual judgment. [crop-proposals.py](examples/crop-proposals.py) demonstrates applying explicit proposals with source preconditions and before/after previews, retaining `unreviewed` sidecars for photographer decisions. It does not infer aesthetic quality or acceptance.

### Preview files

Each preview uses a unique `c1-previews/<operationId>` subdirectory beneath the Session's default `Output`, or beneath the supplied output directory. Existing JPEGs in a custom directory are never reused. Polling requires stable size and a complete decodable JPEG. Metadata includes the native variant ID, five-field state hash, and geometry/state token when available; both states are checked across rendering. The tonal hash does **not** cover crops, and neither token covers every layer, curve, or render-affecting setting. Preview caching based on these tokens is unsupported.

The reserved `c1-preview` recipe is configured by c1 and may remain in the Session. Do not use that recipe for your own exports.

## Errors and recovery

Every dispatched write, including clone, baseline, delete, recipe setup, and preview export, has a durable pre-dispatch journal entry in the Session's `.c1/journal.jsonl`. The journal appends state snapshots instead of rewriting history. Failed journal writes prevent dispatch; corrupted journals and provenance fail closed on writes.

Failures after dispatch include an **`operationId`** in CLI/MCP error JSON. Do not repeat a timed-out command:

```sh
c1 operation status <operationId>
```

An unresolved operation blocks further writes. While the original Capture One process is running, status remains unresolved: a timeout does not cancel its Apple Event. Restart Capture One, reopen the same database, and inspect status again. Reconciliation then records observed adjustments or candidate created IDs and ends the write block. **`reconciled` means the old process has ended and observations were recorded; it does not prove historical success.** Review those observations. No uncertain command is retried, no candidate clone is automatically adopted/deleted, and old working references are not rebound. Create a fresh working clone to resume.

Keep `.c1` files for audit and recovery. Missing legacy identity evidence, a replaced database, or a corrupt journal requires manual inspection; deleting evidence to bypass the write gate is not a recovery workflow.

## Contract and development

`c1 schema` and the MCP `schema` tool return the same contract, including request schemas, response schemas, and the error envelope. MCP `tools/list` uses those same request definitions. Contract version is currently `1.1.0`; package version is `0.1.0`.

```sh
make test                              # offline Swift regression suite
python3 Tests/contract_test.py          # offline CLI/MCP protocol and input checks
export C1_TEST_RAW_FIXTURE=/path/to/image.CR3
python3 Tests/integration_test.py       # disposable Session; requires Capture One
python3 Tests/mcp_test.py               # run sequentially, never alongside CLI suite
python3 Tests/geometry_integration_test.py # zero open documents; crop/rotation + review workflow
make archive
python3 Tests/archive_test.py dist/*.tar.gz
# Exclusive app use, zero open documents; pauses/restarts Capture One:
python3 Tests/recovery_integration_test.py dist/c1-v0.1.0-macos-arm64.tar.gz /path/to/new-evidence-dir
```

Live suites copy the fixture and create disposable Sessions/Catalogs under `/private/tmp`. Do not point the fixture environment variable at a nonexistent file. `C1_TEST_BIN` and `C1_TEST_MCP_BIN` select extracted release binaries for the same tests.

Architecture: CLI / MCP → shared contract and `CaptureOneCore` → typed AppleScript executor → bundled handlers → Capture One. The executor is injectable for deterministic fault tests. Style learning and photographer-review policy belong in a separate repository consuming this public interface, not reading internal `.c1` files.

[MIT License](LICENSE).
