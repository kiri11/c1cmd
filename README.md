# c1 — Unofficial Capture One CLI & MCP Server

[![CI](https://github.com/kiri11/c1cmd/actions/workflows/ci.yml/badge.svg)](https://github.com/kiri11/c1cmd/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Did you ever want to give your agent access to Capture One? Probably not. But now You can!

`c1` reads, adjusts, compares, and previews Capture One variants through a CLI and a stdio MCP server. 

Works with the **currently open Session or Catalog**. Catalog editing requires an explicit opt-in.

Both adapters share `CaptureOneCore` and one versioned request/response schema. Creative judgment and photographer review belong in the caller.

Capture One is a trademark of Capture One A/S. This independent project is not affiliated with, endorsed by, or sponsored by Capture One A/S. Capture One and RAW fixtures are not distributed with the project.

## Support boundary for v0.1

- **Qualified application:** Capture One **16.8.5.30**, on Apple Silicon. See [release validation](docs/RELEASE_VALIDATION.md) for retained qualification evidence, scope, and remaining distribution gates.
- **One open document:** the implementation rejects operations when more than one document is open. Sessions (`.cosessiondb`) support editing and preview export. Catalogs default to read-only inspection; [experimental catalog editing](#catalog-editing-experimental) requires an exact-path opt-in.
- **One operator, sequential calls:** keep the document open throughout a workflow. Do not switch/reopen/replace databases, edit in the UI, or launch competing exports during a command. The advisory lock serializes inventory scans and cooperating c1 writers; it does not lock the photographer UI, other automation, or delayed Apple Events. Multi-process workflows remain unqualified.
- **Reference lifetime:** a working reference is bound to the canonical database file identity, Capture One process/launch, and parent-image path. Restarting Capture One or replacing the database invalidates it; inspect current state and create a fresh editing reference. Capture One does not expose a reliable same-file close/reopen token within one application launch. Such workflows remain unsupported, rather than being presented as automatically detected.
- **Other builds:** 16.4+ through 16.x are permitted by the compatibility check, but are **unverified**, not qualified support. Older/future major builds require `C1_ALLOW_UNTESTED_BUILD=1`. Check `doctor` for the tested-build match before editing.
- **Platform:** the package targets macOS 13+, but this is a deployment target, not evidence that every macOS version is tested. Intel and older macOS runtime qualification are deferred.

This is a narrow first release, not a general-purpose Capture One automation API. Session creation, image import, automatic keystone detection, style learning, and general recipe export are outside v0.1. Expanded adjustments, curves, layers and masks are available through the experimental [native editing API](docs/native-editing/README.md).

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

Use `get` for both compact and expanded reads. Optional `nativeTargets` returns one
or several native scopes in `nativeSnapshots` alongside adjustments, metadata and
geometry. Each snapshot carries its own `nativeStateHash`. The single-scope path
uses direct validation. See [scoped reads](docs/native-editing/README.md#scoped-reads).

`doctor` reports `unresolvedOperationsCount` only after successfully inspecting the journal. An absent count means unknown; `diagnosticError` preserves an inspection failure and `allChecksPassed` remains false.

The default server exposes 30 tools: `read_session_begin`, `read_session_end`, `read_session_status`, `catalog_get`, `catalog_inspect`, `catalog_variants`, `catalog_snapshot`, `native_set`, `native_action`, `doctor`, `doc_info`, `capabilities`, `schema`, `variants_list`, `variant_edit`, `variant_clone`, `variant_delete`, `variant_baseline`, `get`, `metadata_set`, `set`, `add`, `geometry_set`, `geometry_restore`, `reset`, `diff`, `dump`, `preview`, `operation_status`, and `request_status`.

`preview` creates files and configures the reserved `c1-preview` recipe, so it is declared a mutating tool. Its response includes JPEG image content plus JSON metadata. Other tool results are JSON text content.

## Faster browsing during an agent workflow

The agent can call `read-session begin`, pass its `workflowId` as `--read-workflow` on browsing calls, and call `read-session end --read-workflow <id>` before returning control to the photographer. Catalog browsing combines native-confirmed cache entries, acknowledged edits, and matching SQLite values. Sessions use the native cache. Cached responses carry `readObservation` and no mutation tokens; use `get --live` before preparing edits. Ordinary calls without a workflow ID remain native. Closed Catalogs support direct `variants list --database` and `get <id> --database` reads without a handoff. See [routing, limitations, and validation](docs/catalog-reader.md#controlled-browsing-workflow).

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

The default profile permits all supported tonal, geometry, rating, and color-tag changes. Optionally add `C1_MCP_PROFILE=composition` to restrict an agent to crop/rotation/keystone. An absolute `.cocatalogdb` path inside the package is also accepted. When Capture One reports an exact database path, sibling `.cocatalogdb` files are allowed; write authorization must resolve to that same database. With multiple databases, set the variable to the exact database path, not the package. When Capture One reports only a package path, exactly one database is required, including for read-only access. Read-only inspection does not require the variable. Other catalogs remain read-only; there is no global enable-all switch. Check `doctor.allChecksPassed`, `doctor.writesEnabled`, and `exactBuildMatched` before editing. Unset `C1_CATALOG_WRITE_PATH` to disable catalog writes; existing proposals remain available for inspection.

Read-only inspection also supports unpackaged catalog directories. A directory must contain exactly one `.cocatalogdb`, or Capture One must report the exact database path. Unpackaged catalogs remain write-disabled even with `C1_CATALOG_WRITE_PATH`; this includes preview export, which configures an output recipe.

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

Review the preview before handing back to the photographer. To restore the saved crop/rotation/keystone:

```sh
c1 get <editing-ref>
c1 geometry restore <editing-ref> --if-geometry-state <fresh-geometryStateHash>
```

Restoration is explicit, state-checked, and journaled. It restores all five keystone controls along with crop and rotation, refuses a changed orientation/lens context, and never runs automatically after failure. To restore tonal edits, use `set` with the returned `baselineAdjustments` and a fresh state hash. `reset` restores exposure/contrast/saturation defaults and baseline white balance; **it is not a full undo of the previous edit**. References expire on app restart/database replacement; saved baselines remain available as evidence but are not automatically rebound.

`variant clone <source-id>` is still available when separate comparison variants are wanted. Only those `c1_wrk_` clones can be deleted with `variant delete`; an existing `c1_edit_` variant cannot be deleted. `variant baseline` explicitly creates a new default-settings variant. `diff <ref1> <ref2>` compares two variants; single-reference `diff` uses its saved baseline. `dump` exports batched JSONL.

### Select culled photos by star rating

Filter the listing before preparing photos for crop or color work:

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

### Inventory progress and cancellation

Rating filters run before full metadata reads. On Capture One 16.8.5.30 Sessions, native rating predicates select matching variants and bulk ID reads capture the ordered candidates. Full summaries are then read in sequential batches. Catalogs and other allowed builds retain a two-stage rating scan that hydrates only matches; `C1_INVENTORY_STRATEGY=scan` explicitly selects this fallback. `batchSize` (CLI `--batch-size`) defaults to 32 and accepts 1–256. Distinct variants of the same image remain separate; response fields and ordering are preserved. A failed rating read now fails the request rather than treating the image as unrated. Native rating predicates and bulk IDs were checked against the legacy enumeration across document, collection, and selected scopes. Bulk reads of other properties remain deferred.

The [inventory qualification report](docs/inventory/16.8.5.30/README.md) records sparse-filter gains, dense-scan overhead, and the fixture limitations.

```sh
c1 variants list --rating 5 --batch-size 32 --progress human
c1 variants list --rating 5 --deadline-seconds 120 --progress json
c1 request status req-<UUID> --format json
```

The entire inventory holds the application advisory lock, rechecks the document token between batches, validates returned IDs/ratings, and compares scope membership before returning. Partial inventories are never returned as complete. This is not an atomic application snapshot: edits to already-read ratings or transient membership changes can escape detection. The one-operator/no-UI-edits requirement still applies. Candidate discovery itself remains one potentially slow script; batch size is a work limit, not an execution-time guarantee.

Every executed CLI command and MCP tool receives a diagnostic request ID, separate from mutation operation IDs. Status snapshots record elapsed time, phase, inventory strategy, actual completed counters, and an outstanding handler when known. For `native-filter`, candidate totals describe the IDs returned by the native predicate; they do not claim to count all variants examined internally by Capture One. For `rating-scan`, totals cover the unfiltered scope. A background heartbeat runs every five seconds even while the main thread is blocked. Requests are marked slow after 10 seconds (`C1_SLOW_REQUEST_SECONDS` overrides the threshold). `handlerCalls` counts script invocations, not the Apple Events executed inside them. It reports no invented percentage or ETA; progress inside an outstanding Apple Event is unknown. MCP callers supplying `_meta.progressToken` receive increasing progress notifications for observed work; heartbeats with unchanged counters are recorded locally, not sent as fictitious progress.

Progress goes to stderr, leaving stdout results/MCP messages intact. CLI `--progress human|json|quiet` or `C1_PROGRESS` selects the format; `--quiet` suppresses progress. Default progress is human on a terminal and quiet in pipelines. Status files are still written in quiet mode. Request IDs appear in progress events, error responses, and the status-cache filenames. Error envelopes add `requestId`, `phase`, and `elapsedMs`, plus recovery guidance where applicable.

Snapshots are stored in `~/Library/Caches/c1/requests`; use the same `C1_REQUEST_DIR` in CLI and MCP to override it, or `C1_REQUEST_DIR=off` to disable persistence. `request_status({"requestId":"req-..."})` and `c1 request status` read these files without the application lock or an Apple Event. They distinguish process liveness from stale observations; a live process is not proof that Capture One advanced. Set `C1_DIAGNOSTICS=1` to retain per-request JSONL events, rotated at 1 MiB with one previous file. Paths, collection names, and image names are omitted from these diagnostics; document identity is hashed. These cache files may be deleted when no request needs inspection. Diagnostic failures cannot override a command outcome or replace the mutation journal.

For inventory, Ctrl-C in the CLI or MCP cancellation requests stop work at the next boundary between Apple Events. `deadlineSeconds` / `--deadline-seconds` is an optional positive duration up to 86400 seconds, checked at those same boundaries. Neither mechanism interrupts a dispatched event or proves Capture One stopped processing it. Mutation cancellation does not release journal safeguards or authorize retries; existing outcome-unknown/restart/reconciliation rules remain in effect.

## Supported adjustments

| Field | Aliases | Absolute range |
|---|---|---|
| exposure | exp | -4 to 4 EV |
| contrast | — | -50 to 50 |
| saturation | sat | -100 to 100 |
| temperature | kelvin, temp | 800 to 14000 K |
| tint | — | -50 to 50 |

All values must be finite. Writes touch requested fields only; white balance is written and checked as a temperature/tint pair. Bounds, managed identity, and the state precondition are checked before dispatch. The handler checks the expected five-field state again immediately before its setters. Apple Event property writes are sequential, not atomic transactions: a later failure can leave an earlier field applied. Do not edit concurrently in the UI.

MCP accepts either a nested `adjustments` object or flat fields. Mixed forms, duplicate aliases, unknown fields, and wrong types are rejected. `dump.batchSize` must be 1–1000; preview timeout must be greater than zero and at most 300 seconds.

### Ratings and color tags

Use `c1 metadata set` / MCP `metadata_set` on an existing editing reference or managed clone. `rating` accepts integers **0–5** and `colorTag` accepts native integers **0–7**; **0 clears** either field. Supply one or both fields. Omitted fields, tonal adjustments, and geometry are preserved. These writes require Capture One **16.8.5.30** and the same Catalog opt-in and referenced-original restrictions as other edits.

Read `get` immediately before writing and pass its **`metadataStateHash`** as `--if-metadata-state` / `ifMetadataState`. This token covers both rating and color tag, independently of the tonal `stateHash` and geometry token. The native handler checks both values and the parent image again before writing. Stale tokens reject the request; read the state again and reconcile the photographer's changes.

```sh
c1 get <working-ref>
c1 metadata set <working-ref> --if-metadata-state <metadataStateHash> --rating 5 --color-tag 4
```

```json
{"workingRef":"c1_edit_...","ifMetadataState":"metadata-v1:...","rating":5,"colorTag":4}
```

`--dry-run` / `dryRun` reports the proposed values without writing; its metadata token is the **current** token. Responses contain `before`, `after`, `diff`, and the resulting metadata token. `get` exposes current values under `metadata`. Rating filters in `variants_list` reflect subsequent edits.

New editing references and clones retain `baselineMetadata`; `diff` includes `metadataBefore`, `metadataAfter`, and `metadataDiff`. Restore a saved rating/tag by explicitly setting those values with a fresh token. Older records remain readable but have no metadata baseline. Tonal `reset` does not reset ratings or tags. Each mutation journals its before, intended, and observed values. A partial write or uncertain reply blocks further writes until normal restart/reconciliation; never retry automatically.

The geometry-only `C1_MCP_PROFILE=composition` hides and rejects `metadata_set`. Use the default profile for culling edits. Other metadata remains read-only. See [metadata validation](docs/metadata/16.8.5.30/README.md) for test evidence.

### Crop and rotation

`c1 geometry set` / MCP `geometry_set` applies absolute crop, rotation, and keystone corrections to an existing editing reference or optional managed clone. It requires **`geometryStateHash` from `get`**, passed as `--if-geometry-state` / `ifGeometryState`. This versioned token includes geometry and the tonal hash; the existing `stateHash` and tonal commands are unchanged. `get`, `dump`, and `diff` now include geometry; editing references and newly cloned variants retain a geometry baseline. Older provenance records remain readable but lack that baseline.

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

Geometry writes require **Capture One 16.8.5.30**. Lens distortion correction from 0 through 100 is supported while preserving the correction amount, profile, and “hide distorted areas” setting. With nonzero distortion, keystone, or lens movements, reported bounds come from Capture One's read-only `maximum crop` query in the current canvas. A rotation change queries fresh native bounds after rotation, then fits `aspectRatio` or validates the explicit crop. Rotation-only requests retain Capture One's automatically recentered/shrunk crop. Inspect a fresh preview after rotation before selecting precise crop coordinates. Full-frame context previews use native bounds; with perspective or movements they allow Capture One to shrink the fitted rectangle.

For rotation changes with lens or perspective corrections, the final bounds cannot be predicted without executing the native rotation. `dryRun` therefore rejects that combination; explicit crop dry runs at the current rotation remain available. Perspective/movement ratio fits also reject dry runs because native crop normalization can shrink them. The durable pending journal stores `requestedGeometry` before dispatch and records the concrete target once native bounds are known. A failure after rotation (including an explicit crop outside the new bounds) is an uncertain mutation: it can leave the rotation applied and blocks further writes until normal restart/reconciliation. Never automatically retry or undo it.

Existing keystone and lens tilt/shift are supported and preserved. Their native maximum rectangle is an upper bound: Capture One may shrink a centered ratio fit to avoid transformed edges. The final crop must retain the requested ratio and lie inside the proposed rectangle. Explicit crops retain strict two-pixel readback tolerance; inspect a fresh preview and use a smaller rectangle if needed. Rotation-only preserves Capture One's observed automatic crop, which can extend beyond its reported maximum rectangle. Distortion outside 0...100, flips, crop-outside-image, and unqualified orientations remain blocked. Without lens or perspective transforms, bounds remain a conservative centered rectangle inside the rotated image. See [geometry qualification](docs/geometry/16.8.5.30/README.md) and [corrected-lens qualification](docs/geometry/16.8.5.30/lens/README.md) for evidence and fixture limits. The [perspective and movement report](docs/geometry/16.8.5.30/perspective/README.md) covers the extension; the tools preserve lens movement controls; keystone writes are described below.

Keystone controls are optional absolute values; unspecified controls keep their current values. They use the same geometry token, existing-variant authorization, journal, and readback checks as crop/rotation. CLI flags map to the MCP `keystone` object:

| CLI flag | MCP key | Range |
|---|---|---|
| `--keystone-amount` | `amount` | Integer 10–120 |
| `--keystone-vertical` | `vertical` | −75–75 |
| `--keystone-horizontal` | `horizontal` | −75–75 |
| `--keystone-skew` | `skew` | −45–45 |
| `--keystone-aspect` | `aspect` | −50–100 |

The amount and aspect controls follow the [Capture One keystone documentation](https://support.captureone.com/hc/en-us/articles/360002588058-Keystone-correction). `keystone.aspect` changes image proportions; `aspectRatio` selects the crop's width/height ratio. Clearing a correction means explicitly setting vertical/horizontal/skew/aspect to zero; amount remains at its requested or existing value. This API sets controls, without automatic line detection or guide-point placement.

```sh
c1 geometry set <working-ref> --if-geometry-state <geometryStateHash> \
  --keystone-vertical 12 --keystone-horizontal=-7 --aspect-ratio 1.5
```

Equivalent MCP arguments:

```json
{"workingRef":"c1_edit_...","ifGeometryState":"geometry-v1:...","keystone":{"vertical":12,"horizontal":-7},"aspectRatio":1.5}
```

Keystone setters run before rotation and crop fitting. Bounds are queried after those transforms. Without a requested crop or ratio, Capture One's resulting crop is retained. Render a fresh preview before selecting precise crop coordinates. Keystone changes reject `dryRun` because their resulting bounds and crop cannot be predicted offline. `geometry_restore` restores the saved crop, rotation, and all keystone controls; its dry run reports that saved target. Native setters are sequential: a failure can leave a partial correction, so inspect the journal and use normal restart/reconciliation without retrying. `diff.geometryDiff` and mutation diffs use `keystone.amount`, `keystone.vertical`, `keystone.horizontal`, `keystone.skew`, and `keystone.aspect`. Response `geometry.keystone` retains its existing array order `[amount, vertical, horizontal, skew, aspect]`. See the [keystone qualification report](docs/geometry/16.8.5.30/keystone/README.md) for evidence and limits.

For a composition-only MCP agent, set `C1_MCP_PROFILE=composition` in the server environment. This hides and rejects `set`, `add`, `reset`, and `variant_baseline`; existing-variant preparation, crop/rotation/keystone/restore, inspection, optional cloning, clone deletion, preview, and recovery remain available. The caller supplies visual judgment. [crop-proposals.py](examples/crop-proposals.py) demonstrates applying explicit proposals with source preconditions and before/after previews, retaining `unreviewed` sidecars for photographer decisions. It defaults to existing variants; pass `--clone` for separate proposals. `grade-folder.py` has the same default and option. Neither example infers aesthetic quality or acceptance.

### Preview files

Each preview uses a unique `c1-previews/<operationId>` subdirectory beneath the Session's default `Output`, or beneath the supplied output directory. Existing JPEGs in a custom directory are never reused. Polling requires stable size and a complete decodable JPEG. Metadata includes the native variant ID, five-field state hash, and geometry/state token when available; both states are checked across rendering. The tonal hash does **not** cover crops, and neither token covers every layer, curve, or render-affecting setting. Preview caching based on these tokens is unsupported.

The reserved `c1-preview` recipe is configured by c1 and may remain in the Session. Do not use that recipe for your own exports.

## Errors and recovery

Normal CLI/MCP commands do not quit Capture One. Application shutdown remains under user control; native quit and SIGTERM options are confined to the explicitly invoked recovery qualification harness.

Every dispatched write, including clone, baseline, delete, recipe setup, and preview export, has a durable pre-dispatch journal entry in the document's `.c1/journal.jsonl`. The journal appends state snapshots instead of rewriting history. Failed journal writes prevent dispatch; corrupted journals and provenance fail closed on writes.

Failures after dispatch include an **`operationId`** in CLI/MCP error JSON. Do not repeat a timed-out command:

```sh
c1 operation status <operationId>
```

An unresolved operation blocks further writes. While the original Capture One process is running, status remains unresolved: a timeout does not cancel its Apple Event. Restart Capture One, reopen the same database, and inspect status again. Reconciliation then records observed adjustments or candidate created IDs and ends the write block. **`reconciled` means the old process has ended and observations were recorded; it does not prove historical success.** Review those observations. No uncertain command is retried, no candidate clone is automatically adopted/deleted, and old working references are not rebound. Inspect current state and create a fresh editing reference to resume.

Keep `.c1` files for audit and recovery. Missing legacy identity evidence, a replaced database, or a corrupt journal requires manual inspection; deleting evidence to bypass the write gate is not a recovery workflow.

## Contract and development

`c1 schema` and the MCP `schema` tool return the same contract, including request schemas, response schemas, and the error envelope. MCP `tools/list` uses those same request definitions. Contract version is currently `2.2.0`; package version is `0.1.0`.

```sh
make check                             # offline Swift, CLI/MCP contracts, recovery-harness guards
make test                              # Swift assertions only (also available separately)
export C1_TEST_RAW_FIXTURE=/path/to/image.CR3
# Normal candidate validation: release build, offline, package, CLI/MCP and existing edits.
# No deliberate timeout/process-death tests. Zero open documents; exclusive use.
make qualify EVIDENCE_DIR=/private/tmp/c1-new-qualification
# Affected live suites, or every regular matrix (no deliberate faults):
make qualify QUALIFY_SUITES="geometry lens" EVIDENCE_DIR=/private/tmp/c1-geometry-check
make qualify-extended EVIDENCE_DIR=/private/tmp/c1-extended-qualification
# Relevant recovery changes: rebuild the archive, then select affected fault cases:
make archive
make qualify-recovery RECOVERY_CASES="preview mcp-death" C1_RECOVERY_SHUTDOWN_MODE=sigterm EVIDENCE_DIR=/private/tmp/c1-preview-recovery
# All recovery paths when impact is broad:
make qualify-recovery C1_RECOVERY_SHUTDOWN_MODE=sigterm EVIDENCE_DIR=/private/tmp/c1-new-recovery
# All regular suites plus recovery, when both need broad validation:
make qualify-full C1_RECOVERY_SHUTDOWN_MODE=sigterm EVIDENCE_DIR=/private/tmp/c1-full-qualification

# Individual live suites during development:
python3 Tests/integration_test.py       # disposable Session; requires Capture One
python3 Tests/mcp_test.py               # run sequentially, never alongside CLI suite
python3 Tests/geometry_integration_test.py # zero open documents; crop/rotation + review workflow
python3 Tests/keystone_integration_test.py # zero open documents; control ranges, crop fitting, restore
python3 Tests/catalog_integration_test.py # zero open documents; optional clone catalog workflow
python3 Tests/existing_variant_integration_test.py # existing-variant tonal/crop edits; no duplicates
C1_INVENTORY_EVIDENCE=/private/tmp/inventory.json python3 Tests/inventory_integration_test.py
python3 Tests/native_inventory_probe.py # independent native-predicate qualification
```

Live suites copy the fixture and create disposable Sessions/Catalogs under `/private/tmp` or `.build`. Do not point the fixture environment variable at a nonexistent file. `C1_TEST_BIN` and `C1_TEST_MCP_BIN` select extracted release binaries for the same tests.

`make check` is the default development loop: all offline Swift assertions, CLI/MCP contracts, and mocked failure safeguards. Documentation-only changes need relevant syntax/link checks. Run live tests when native behavior or the live harness changes; avoid rerunning unrelated matrices.

`make qualify` builds release once, runs the offline assertions against that build, checks the relocated archive/contract once, then runs `cli`, `mcp`, and `existing`. These cover clone and existing-variant editing, metadata, tonal and crop edits, previews, restoration, Session and referenced-Catalog behavior, and RAW preservation. `QUALIFY_SUITES` selects a space-separated subset of `cli mcp geometry lens perspective keystone catalog existing inventory native`. `make qualify-extended` runs all ten regular suites. Detailed matrices remain available for changes in those areas or broad qualification. The runner lists selected and skipped suites so a focused pass cannot be mistaken for full coverage.

CI runs debug offline checks; the publication workflow builds release once and checks its unit tests, harnesses, and packaged CLI/MCP before publishing. Release packaging is therefore checked on main rather than on every pull request.

Run relevant live recovery cases when changes affect dispatch, journaling, locking, timeouts, restart/reconciliation, stale references, or the fault harness's behavior. No separate user request is needed. `make qualify-recovery RECOVERY_CASES="..."` reuses a current candidate archive and runs only selected cases: `tonal geometry lens perspective keystone preview mcp-death clone-readback`; the default `all` retains the full campaign. Shared recovery changes need every affected path; use `all` when impact cannot be narrowed. Skip live faults for unrelated features, documentation, build/CI, or test-selection/reporting changes; use offline checks for those. Release checkpoints alone do not require rerunning faults. See the [recovery test selection guide](docs/RELEASE_VALIDATION.md#recovery-test-selection). Report actual coverage separately from omitted suites.

Recovery Sessions default to `.build/recovery-fixtures`; `C1_RECOVERY_FIXTURE_PARENT` accepts an absolute path outside `/tmp` without symlink aliases. `C1_RECOVERY_SHUTDOWN_MODE=quit` is the default; explicit `sigterm` selects the qualified process-termination path, with no automatic fallback. Recovery verifies that Capture One is stopped before launching a fresh process. See [recovery qualification](docs/RELEASE_VALIDATION.md#reproduce-packaged-live-recovery-qualification) for scope and evidence. Real fault tests retain the actual 120-second Apple Event timeout because shortening or mocking it would prove something different. Live suites remain sequential. Rerun affected checks for harness/documentation changes and verify executable/resource hashes when reusing prior runtime results.

For read latency investigations, see [performance profiling and local CLI/MCP benchmarks](docs/performance/README.md). Set `C1_PROFILE=1` for internal timing on stderr.

Architecture: CLI / MCP → shared contract and `CaptureOneCore` → typed AppleScript executor → bundled handlers → Capture One. The executor is injectable for deterministic fault tests. Style learning and photographer-review policy belong in a separate repository consuming this public interface, not reading internal `.c1` files.

[MIT License](LICENSE).

### Read-only Catalog discovery and archives

Use `c1 variants list --database /absolute/path/Library.cocatalog/Library.cocatalogdb` for concurrent SQLite stored discovery, `c1 catalog inspect` for raw stored settings and membership, and `c1 catalog snapshot` for a SQLite backup to a new file. Each response reports database provenance and observation time. Stored observations may lag Capture One and never authorize writes. See [the supported schema, commands, performance evidence, and limits](docs/catalog-reader.md).
