# c1 — Unofficial Capture One CLI & MCP Server

[![CI](https://github.com/kiri11/c1cmd/actions/workflows/ci.yml/badge.svg)](https://github.com/kiri11/c1cmd/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Did you ever want to give your agent access to Capture One? Probably not. But now You can!

`c1` reads, adjusts, compares, and previews Capture One variants through a CLI and a stdio MCP server. 

Works with the **currently open Session or Catalog**. Catalog editing requires an explicit opt-in.

Both adapters share `CaptureOneCore` and one versioned request/response schema. Creative judgment and photographer review belong in the caller.

Capture One is a trademark of Capture One A/S. This independent project is not affiliated with, endorsed by, or sponsored by Capture One A/S. Capture One and RAW fixtures are not distributed with the project.

## Support boundary for v0.1

- **Qualified application:** Capture One **16.8.5.30**, on Apple Silicon. The retained M0 evidence is from an M1 Pro running macOS 26.4.1. See [release validation](docs/RELEASE_VALIDATION.md) for the current decision and remaining distribution gates; the [M0 report](docs/m0_requalification_16.8.5.30.md) is historical evidence.
- **One open document:** the implementation rejects operations when more than one document is open. Sessions (`.cosessiondb`) support editing and preview export. Catalogs default to read-only inspection; [experimental catalog editing](#catalog-editing-experimental) requires an exact-path opt-in.
- **One operator, sequential calls:** keep the document open throughout a workflow. Do not switch/reopen/replace databases, edit in the UI, or launch competing exports during a command. The advisory lock serializes cooperating c1 writers; it does not lock the photographer UI, other automation, or delayed Apple Events. Multi-process workflows remain unqualified.
- **Reference lifetime:** a working reference is bound to the canonical database file identity, Capture One process/launch, and parent-image path. Restarting Capture One or replacing the database invalidates it; inspect current state and create a fresh editing reference. Capture One does not expose a reliable same-file close/reopen token within one application launch. Such workflows remain unsupported, rather than being presented as automatically detected.
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

Every push to `main` runs the release workflow. After unit tests, the release build, and packaged-archive checks pass, it publishes the archive and SHA-256 checksum in a GitHub release. Release names and tags use the UTC date plus a daily sequence: `YYYY-MM-DD-01`, `YYYY-MM-DD-02`, and so on, starting again at `01` each day. Runs are queued to keep numbering unique, and each tag points to the commit that triggered its build.

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

No network server, API key, or listening port is required. Diagnostics go to stderr; stdout is reserved for MCP transport. Client configuration locations differ; consult your client's documentation. Start with `doctor`, `doc_info`, and `variants_list`, and check `allChecksPassed`, `writesEnabled`, and `exactBuildMatched` before editing. `isSession` identifies the document type; it is not an editing permission.

The default server exposes 19 tools: `doctor`, `doc_info`, `capabilities`, `schema`, `variants_list`, `variant_edit`, `variant_clone`, `variant_delete`, `variant_baseline`, `get`, `set`, `add`, `geometry_set`, `geometry_restore`, `reset`, `diff`, `dump`, `preview`, and `operation_status`.

`preview` creates files and configures the reserved `c1-preview` recipe, so it is declared a mutating tool. Its response includes JPEG image content plus JSON metadata. Other tool results are JSON text content.

## Catalog editing (experimental)

You can edit existing variants directly in your main Catalog, with no extra variants. Enable **one exact catalog** in the CLI environment:

```sh
export C1_CATALOG_WRITE_PATH="/absolute/path/Main.cocatalog"
c1 doctor
c1 doc info
```

For MCP, add this to the server's `env` and restart the server:

```json
{
  "C1_CATALOG_WRITE_PATH": "/absolute/path/Main.cocatalog"
}
```

The default profile permits all supported tonal and geometry changes. Optionally add `C1_MCP_PROFILE=composition` to restrict an agent to crop/rotation. An absolute `.cocatalogdb` path inside the package is also accepted. Other catalogs remain read-only; there is no global enable-all switch. Check `doctor.allChecksPassed`, `doctor.writesEnabled`, and `exactBuildMatched` before editing. Unset `C1_CATALOG_WRITE_PATH` to disable catalog writes; existing proposals remain available for inspection.

Before using a main catalog, make a fresh **File → Backup Catalog** backup and keep your RAW backups. Capture One's [catalog backup](https://support.captureone.com/hc/en-us/articles/27502751010333-How-Catalog-and-Session-Backups-Work-in-Capture-One) includes its database and adjustments, not original image files. `c1` does not create or verify this backup automatically.

Catalog editing requires Capture One **16.8.5.30**, exactly one open document, **referenced originals** stored outside the catalog package that are online/readable, and sequential exclusive use. Every edit requires an existing-variant editing reference (or an optional managed clone) and fresh state hash. Native IDs alone do not authorize writes; existing variants cannot be deleted through editing references. Deleting a proposal also requires its source variant to remain present and refuses to delete an image's last variant. No import, move, relink, or source-file deletion tools are exposed.

Catalog references bind to the database file **inside** the package, plus the app lifetime and parent image. Replacing that database or restarting Capture One invalidates them. Journals and provenance live in `Main.cocatalog/.c1`; previews default to the sibling `Main.cocatalog.c1-output/c1-previews/<operation-id>/` folder. Preserve that state for recovery. Catalog `documentPath` now reports the package itself. Preview configures the reserved `c1-preview` recipe and therefore requires the opt-in too. Capture One also requires a valid catalog default output location: if it is missing or unavailable, preview initializes it to the preview output root; an existing usable default is preserved.

Catalog-stored originals are currently blocked: native import into the catalog crashed during qualification, so that storage mode has not been qualified. Import itself is outside the `c1` API. This feature is experimental. See [catalog validation](docs/catalog/16.8.5.30/README.md) for the tested workflows and remaining limits before using it on a main catalog. Same-file close/reopen within one app launch remains unsupported.

## Editing workflow

Open one Session, or an explicitly enabled Catalog. Photographer and agent take turns; after the agent finishes, the photographer continues editing **the same variants**.

```sh
c1 doctor
c1 doc info                     # retain openToken from this document
c1 variants list --rating 5     # also verify the requested folder/collection
c1 get <source-id>
c1 variant edit <source-id> --if-document <openToken> --if-state <stateHash-from-get>
# The result contains workingRef=c1_edit_..., the same variantId, and saved baselines.
c1 get <editing-ref>
c1 set <editing-ref> --if-state <fresh-stateHash> exposure=0.35 contrast=5
c1 preview <editing-ref>
c1 diff <editing-ref>
```

MCP uses `variant_edit: {sourceRef, ifState, ifDocument}`. Optionally include `ifGeometryState` from the source inspection to check a crop proposal's geometry before preparing the edit. `variant_edit` saves the before-state in `.c1/editing.json` without changing Capture One or creating a variant. The returned `c1_edit_` reference permits all supported tonal and geometry mutations on that same native variant, subject to the normal checks. Baselines and every mutation's journal before-state are retained for review/recovery. RAW files are not modified by the API; fixture tests verify their byte preservation.

Review the preview before handing back to the photographer. To restore the saved crop/rotation:

```sh
c1 get <editing-ref>
c1 geometry restore <editing-ref> --if-geometry-state <fresh-geometryStateHash>
```

Restoration is explicit, state-checked, and journaled. It refuses a changed orientation/lens/keystone context, and never runs automatically after failure. To restore tonal edits, use `set` with the returned `baselineAdjustments` and a fresh state hash. `reset` restores exposure/contrast/saturation defaults and baseline white balance; **it is not a full undo of the previous edit**. References expire on app restart/database replacement; saved baselines remain available as evidence but are not automatically rebound.

`variant clone <source-id>` is still available when separate comparison variants are wanted. Only those `c1_wrk_` clones can be deleted with `variant delete`; an existing `c1_edit_` variant cannot be deleted. `variant baseline` explicitly creates a new default-settings variant. `diff <ref1> <ref2>` compares two variants; single-reference `diff` uses its saved baseline. `dump` exports batched JSONL.

### Select culled photos by star rating

Filter the listing before cloning photos for crop or color work:

```sh
c1 variants list --rating 5                 # Exactly 5 stars (also: more than 4)
c1 variants list --min-rating 4             # 4 or 5 stars
c1 variants list --rating 0                 # Unrated
c1 variants list --collection Capture --selected --rating 5
```

MCP `variants_list` accepts the same filters:

```json
{"rating": 5}
```

Use `{"minRating": 4}` for four stars and above. Both arguments require integers from 0 through 5; choose either `rating` or `minRating`. Filters combine with `collection` and `selected`, narrow the returned variants, and leave Capture One's UI selection unchanged. No matches returns an empty list. Omitting both filters preserves the full listing for the requested scope.

For “crop my five-star picks,” call `variants_list` with `rating: 5`, then prepare each intended existing variant with `variant_edit` and follow the crop workflow below. Results are variants: multiple edits of the same photo can appear, including existing managed clones. Review the IDs and `isManagedWorkingClone` before creating proposals. Filtering is also available in the composition MCP profile and for read-only Catalog inspection.

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

`c1 geometry set` / MCP `geometry_set` applies an absolute crop and rotation to an existing editing reference or optional managed clone. It requires **`geometryStateHash` from `get`**, passed as `--if-geometry-state` / `ifGeometryState`. This versioned token includes geometry and the tonal hash; the existing `stateHash` and tonal commands are unchanged. `get`, `dump`, and `diff` now include geometry; editing references and newly cloned variants retain a geometry baseline. Older provenance records remain readable but lack that baseline.

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

Geometry bounds use the original file’s intrinsic pixel dimensions read through ImageIO. Capture One can report rotated first-variant canvas dimensions as parent-image dimensions, so those native dimensions are not a stable source for bounds. If intrinsic dimensions cannot be read, geometry is unavailable; supported tonal editing remains available.

`--full-frame` / `fullFrame: true` renders the largest conservative context rectangle at the current rotation through a temporary managed clone, then deletes that clone. The response's `contextSourceRef` identifies the source; `workingRef` and `nativeVariantId` identify the rendered temporary clone. On failure, retain the clone and journal for inspection and use normal recovery. The source crop is never temporarily reset.

Geometry writes require **Capture One 16.8.5.30**. Existing keystone, lens distortion/shift, flips, crop-outside-image, and unqualified orientation combinations are rejected for editing/context mapping; their settings remain intact. Valid crops are limited to a conservative centered rectangle inside the rotated image, with two-pixel native rounding tolerance. See [geometry qualification](docs/geometry/16.8.5.30/README.md) for fixture coverage and limitations.

For a composition-only MCP agent, set `C1_MCP_PROFILE=composition` in the server environment. This hides and rejects `set`, `add`, `reset`, and `variant_baseline`; existing-variant preparation, crop/rotation/restore, inspection, optional cloning, clone deletion, preview, and recovery remain available. The caller supplies visual judgment. [crop-proposals.py](examples/crop-proposals.py) demonstrates applying explicit proposals with source preconditions and before/after previews, retaining `unreviewed` sidecars for photographer decisions. It defaults to existing variants; pass `--clone` for separate proposals. `grade-folder.py` has the same default and option. Neither example infers aesthetic quality or acceptance.

### Preview files

Each preview uses a unique `c1-previews/<operationId>` subdirectory beneath the Session's default `Output`, or beneath the supplied output directory. Existing JPEGs in a custom directory are never reused. Polling requires stable size and a complete decodable JPEG. Metadata includes the native variant ID, five-field state hash, and geometry/state token when available; both states are checked across rendering. The tonal hash does **not** cover crops, and neither token covers every layer, curve, or render-affecting setting. Preview caching based on these tokens is unsupported.

The reserved `c1-preview` recipe is configured by c1 and may remain in the Session. Do not use that recipe for your own exports.

## Errors and recovery

Every dispatched write, including clone, baseline, delete, recipe setup, and preview export, has a durable pre-dispatch journal entry in the document's `.c1/journal.jsonl`. The journal appends state snapshots instead of rewriting history. Failed journal writes prevent dispatch; corrupted journals and provenance fail closed on writes.

Failures after dispatch include an **`operationId`** in CLI/MCP error JSON. Do not repeat a timed-out command:

```sh
c1 operation status <operationId>
```

An unresolved operation blocks further writes. While the original Capture One process is running, status remains unresolved: a timeout does not cancel its Apple Event. Restart Capture One, reopen the same database, and inspect status again. Reconciliation then records observed adjustments or candidate created IDs and ends the write block. **`reconciled` means the old process has ended and observations were recorded; it does not prove historical success.** Review those observations. No uncertain command is retried, no candidate clone is automatically adopted/deleted, and old working references are not rebound. Inspect current state and create a fresh editing reference to resume.

Keep `.c1` files for audit and recovery. Missing legacy identity evidence, a replaced database, or a corrupt journal requires manual inspection; deleting evidence to bypass the write gate is not a recovery workflow.

## Contract and development

`c1 schema` and the MCP `schema` tool return the same contract, including request schemas, response schemas, and the error envelope. MCP `tools/list` uses those same request definitions. Contract version is currently `1.4.0`; package version is `0.1.0`.

```sh
make check                             # build once; all offline Swift + CLI/MCP contract checks
make test                              # Swift assertions only (also available separately)
export C1_TEST_RAW_FIXTURE=/path/to/image.CR3
# Full candidate qualification: offline, packaged contract/layout, all live suites,
# and all four recovery cases. Zero open documents; exclusive Capture One use.
make qualify EVIDENCE_DIR=/private/tmp/c1-new-qualification

# Individual live suites during development:
python3 Tests/integration_test.py       # disposable Session; requires Capture One
python3 Tests/mcp_test.py               # run sequentially, never alongside CLI suite
python3 Tests/geometry_integration_test.py # zero open documents; crop/rotation + review workflow
python3 Tests/catalog_integration_test.py # zero open documents; optional clone catalog workflow
python3 Tests/existing_variant_integration_test.py # existing-variant tonal/crop edits; no duplicates
```

Live suites copy the fixture and create disposable Sessions/Catalogs under `/private/tmp`. Do not point the fixture environment variable at a nonexistent file. `C1_TEST_BIN` and `C1_TEST_MCP_BIN` select extracted release binaries for the same tests.

`make check` needs no Capture One document or RAW and provides routine feedback in seconds on a warm build. It does not replace release qualification. `make qualify` preserves every assertion and fault case, runs the packaged contract/layout check once within the extracted live runner, and reports timings. The retained recovery run took 373 seconds, including two real 120-second Apple Event timeouts; shortening or mocking those waits would change what that run proves. Live suites remain sequential because they share Capture One's document, recipe and process state. When changing only a harness or documentation, rerun affected checks; do not repeat the entire fault campaign unless its behavior or the runtime candidate changed. Verify executable/resource identity when reusing runtime results after a documentation-only repack.

Architecture: CLI / MCP → shared contract and `CaptureOneCore` → typed AppleScript executor → bundled handlers → Capture One. The executor is injectable for deterministic fault tests. Style learning and photographer-review policy belong in a separate repository consuming this public interface, not reading internal `.c1` files.

[MIT License](LICENSE).
