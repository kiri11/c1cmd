# AGENTS.md — Instructions for AI Coding & Reasoning Agents

This file provides rules, architectural constraints, and standard operating procedures for autonomous or interactive agents (Claude Code, Cursor, Windsurf, Codex, etc.) utilizing `c1` via the CLI or the MCP server (`c1-mcp`).

---

## 1. Core Principles & Non-Negotiable Safety Rules

1. **RAW Files Are Immutable; Existing Variants Are Editable:**
   - Edit existing variants by default. Read `doc info` and `get <source-id>`, then call `variant edit <source-id> --if-document <openToken> --if-state <stateHash>` (MCP `variant_edit`). Add `--if-geometry-state` / `ifGeometryState` when preparing a crop selected from a prior inspection.
   - This saves the existing adjustments and geometry and returns `c1_edit_<uuid>` without creating a variant. Use it with `set`, `add`, `reset`, `geometry_set`, preview, and diff.
   - Native IDs alone do not authorize writes. `variant clone` remains optional when a separate comparison variant is explicitly wanted.
   - Deletion is restricted to agent-created `c1_wrk_` clones. Never delete an existing variant to reject an edit.

2. **Sessions vs. Catalogs:**
   - Catalogs are **read-only by default**. Experimental editing requires `C1_CATALOG_WRITE_PATH` to name the exact open `.cocatalog` package (or its database) and Capture One 16.8.5.30. Other catalogs fail closed. Only online referenced originals outside the catalog package are enabled; catalog-stored originals remain blocked pending runtime qualification.
   - For editing workflows, use a Session (`.cosessiondb`) or an explicitly enabled Catalog. Confirm `doctor.allChecksPassed`, `writesEnabled`, and `exactBuildMatched`. Make a fresh native Catalog backup before main-catalog work; RAW backups remain separate. See [catalog support](README.md#catalog-editing-experimental).

3. **Optimistic Concurrency Is Mandatory:**
   - Adjustment mutations (`set`, `add`, `reset`) require a state precondition: `--if-state <hash>` (or `ifState` in MCP).
   - Obtain the current `stateHash` using `c1 get <working-ref>` immediately before calculating and applying adjustments.
   - If a mutation fails with `state-changed`, re-read the variant state with `get`, reconcile differences, and retry with the updated state hash.

4. **Never Guess or Retry Blindly on Failure/Timeout:**
   - If an operation times out or returns `outcome-unknown`, Capture One may still be executing the Apple Event. Error JSON includes `operationId`; unresolved operations block further writes.
   - Restart Capture One and reopen the same database before reconciliation can clear the block. `reconciled` records observations, not proof of historical success. Old working references stay invalid after restart.
   - Do **not** issue duplicate mutations. Check the status using `c1 operation status <operationId>` or inspect `.c1/journal.jsonl`.

---

## Supported Scope

Use exactly one open document and sequential calls. Do not edit in the UI, switch/reopen/replace documents, or launch competing exports during a workflow. Same-file close/reopen within one app launch is not reliably observable; it is unsupported. Database replacement and application restart invalidate references. Only Capture One 16.8.5.30 has retained runtime qualification; other allowed 16.x builds are unverified.

## Optional accelerated browsing handoff

The agent owns `read-session begin/end` (MCP `read_session_begin/end`). Begin only while the photographer has handed over control, retain `workflowId`, and pass `--read-workflow <id>` / `readWorkflow` on participating browsing calls. End before returning control to the photographer; after a crash begin anew. Do not export `C1_READ_WORKFLOW` globally or share the ID with unrelated callers. The workflow captures membership/selection at begin; use native reads for dynamic membership or start a new baseline.

Cached browsing results carry `readObservation` and omit mutation tokens. Use `get --live` / `get(live: true)` immediately before preparing an existing variant; editing-reference reads and all mutation checks remain native automatically. Successful tonal/metadata writes update cached observations before rating filtering. Broader actions invalidate the workflow; resume with native reads or a new begin. Sessions use a native-confirmed cache; Catalogs additionally compare stored fields with that cache. Closed-Catalog `--database` reads require no handoff and never supply mutation tokens. See [details](docs/catalog-reader.md#controlled-browsing-workflow).

## 2. Canonical Editing Workflow

1. Run `doctor` and confirm `allChecksPassed`, `writesEnabled`, and `exactBuildMatched`. Run `doc_info` and retain `openToken`.
2. List intended variants, using exact `rating` or `minRating` (integers 0–5), plus collection/selection scope. Verify parent-image paths against the requested folder; ratings alone do not establish folder membership. Results can include multiple existing variants of one image.
3. Read each intended source with `get`. Prepare **the existing variant** using `variant_edit` with its `sourceRef`, `ifState`, and the document's `ifDocument` token; supply `ifGeometryState` too for crop proposals. Retain the returned `workingRef` and baseline.
4. Read the editing reference immediately before applying changes. Tonal `set`, `add`, and `reset` require `ifState`; crop/rotation/keystone require `ifGeometryState`. These operations affect the same native variant. All supported adjustment fields are available in the default MCP profile.
5. Inspect a fresh `preview` and `diff` against the saved baseline. Photographer and agent take turns; the photographer continues on the same variant after the agent finishes.
6. For rejected geometry changes, use `geometry_restore` / `geometry restore` with a fresh geometry token. Restore tonal fields with `set` using saved `baselineAdjustments` and a fresh tonal token. `reset` retains its existing default-values semantics; it is not a full undo.
7. Baselines live in `.c1/editing.json`, and each dispatched mutation retains its before-state in the journal. Never automatically undo or retry an uncertain operation. References expire after application restart/database replacement; retained baselines remain evidence for manual review.

Use `variant_clone` only for explicitly requested separate proposals. Cloned references retain baseline diff/restore support and can be removed with `variant_delete` after review.

---

## Crop and Rotation Workflow

For composition corrections, prepare the existing variant with `variant_edit`; preserve its look. This creates no duplicate variant. Use `get.geometryStateHash` with `geometry_set.ifGeometryState` (CLI `geometry set --if-geometry-state`). The existing tonal `stateHash` does not cover crops. Geometry writes support crop rectangles, absolute rotation, and absolute keystone controls on Capture One 16.8.5.30. Omitted keystone controls and lens settings remain unchanged. Apply the same journal, timeout, document opt-in, and managed-reference rules as tonal edits.

Use 3:2 width:height for horizontal pictures and 3:4 for vertical pictures. Straighten credible horizons/lines with rotation while preserving interesting composition. Apply keystone corrections when credible straight lines establish the needed correction; flag ambiguous perspective and ratio exceptions for review. Do not automatically level natural diagonals or treat an unchanged proposal as accepted.

`geometry_set` accepts `crop: {centerX, centerY, width, height}`, `rotation` (-45 to +45 degrees), or `aspectRatio` (1.5 landscape, 0.75 portrait) for a centered fit. Crop coordinates use the oriented, rotated canvas with bottom-left origin. After rotation, inspect a fresh preview before choosing precise crop coordinates. `preview(fullFrame: true)` uses and cleans up a temporary managed context clone; failed workflows retain evidence for normal recovery. See [README](README.md#crop-and-rotation) for mapping and limitations.

Existing lens distortion correction in 0...100 is preserved and supported using native crop bounds. Nonzero-distortion rotation changes obtain bounds after the native rotation, inside the journaled operation; `dryRun` cannot predict them and rejects that combination. Rotation-only uses Capture One's automatic crop adjustment. Prefer rotation plus `aspectRatio`, inspect the export, then choose an explicit crop with a fresh token. An invalid explicit crop after rotation can leave an uncertain partial operation and must follow normal recovery. Existing lens tilt/shift and keystone use native bounds. Lens settings remain unchanged; keystone changes require explicit controls. Capture One may shrink ratio fits; accept only a contained rectangle retaining the requested ratio. Their ratio-fit dry runs are unavailable. Explicit crops remain strict and can fail if native normalization changes them. Rotation-only retains the observed native crop even when it exceeds reported bounds. Flips and crop-outside-image remain blocked. Never disable lens correction to bypass these guards.

Keystone corrections use `geometry_set.keystone: {amount, vertical, horizontal, skew, aspect}` or CLI `geometry set --keystone-<control>`. Values are absolute; omit controls to preserve them. Amount is an integer 10–120, vertical/horizontal are −75–75, skew is −45–45, and aspect is −50–100. Keystone aspect changes image proportions; crop `aspectRatio` is separate. Apply corrections plus a ratio, then inspect a fresh preview before choosing an explicit crop. Keystone changes reject dry runs. `geometry_restore` restores baseline crop, rotation, and all keystone controls with a fresh token and unchanged lens/orientation context. Partial native writes follow normal recovery; never retry or undo automatically.

The default profile permits all supported adjustments on existing editing references. Only use `C1_MCP_PROFILE=composition` when a geometry-only restriction is wanted; that profile hides tonal mutation tools and native default-baseline creation, and allows crop, rotation, and keystone corrections.

## 3. Supported Adjustment Fields & Valid Ranges

The legacy tonal `set`, `add`, and `reset` tools support only this table; use `geometry_set` for crop, rotation, and keystone:

| Parameter | Aliases | Minimum | Maximum | Unit | Description |
|---|---|---|---|---|---|
| `exposure` | `exp` | `-4.0` | `+4.0` | EV | Exposure compensation |
| `contrast` | - | `-50.0` | `+50.0` | Int/Float | Contrast adjustment |
| `saturation` | `sat` | `-100.0` | `+100.0` | Int/Float | Saturation adjustment |
| `temperature` | `kelvin`, `temp` | `800.0` | `14000.0` | Kelvin | White balance Kelvin |
| `tint` | - | `-50.0` | `+50.0` | Float | White balance tint |

> **White Balance Note:** `temperature` and `tint` are coupled in Capture One. Whenever modifying white balance, always inspect both values after the write.

---

## Rating and Color Tag Writes

Use `metadata_set` / `c1 metadata set` on a `c1_edit_` editing reference or managed clone. Read `get` immediately before writing and require `ifMetadataState` / `--if-metadata-state` from `metadataStateHash`; the tonal state hash does not cover these fields. `rating` is an integer 0–5, `colorTag` is a native integer 0–7, and 0 clears either. Omitted fields stay unchanged. Metadata writes require Capture One 16.8.5.30 and the existing Catalog/image guards. They are unavailable in the geometry-only composition profile.

New references save `baselineMetadata`; `diff` exposes metadata differences. Restore by explicitly setting the saved values with a fresh metadata token. Tonal `reset` does not reset ratings or tags. Native writes are sequential and may partially apply; the same journal, outcome-unknown, restart, and reconciliation rules apply. Never retry an uncertain classification write automatically.

## 4. MCP Server Usage Notes

When using `c1-mcp`:
- All tools take a JSON object matching their declared schema.
- Top-level adjustment keys can be passed either flat (e.g., `{"workingRef": "...", "ifState": "...", "exposure": 0.3}`) or grouped under an `adjustments` object.
- The `preview` tool returns a standard MCP image content block (`image/jpeg`) which renders directly in supporting LLM interfaces.

---

Inventory listing filters before full metadata reads and uses sequential bounded batches (`batchSize` / `--batch-size`, default 32). The exact qualified Session build uses native predicates and bulk IDs; Catalogs and other allowed builds use a rating-scan fallback. Do not narrow the scope to UI selection unless requested. Native-filter counters describe returned candidates, not Capture One's internal scan progress.

`request_status` / `c1 request status <requestId>` reads local diagnostic snapshots without contacting Capture One, so it can be used while an inventory request is running. Request IDs are separate from mutation operation IDs and never authorize writes. CLI Ctrl-C, MCP cancellation, and `deadlineSeconds` / `--deadline-seconds` stop inventory at boundaries between Apple Events; they do not interrupt an outstanding event. A heartbeat shows service activity, not completed photo processing. Keep using `operation_status` for uncertain mutations.

## 5. Error Code Reference

- `app-not-running`: Launch Capture One and ensure GUI is active.
- `no-document`: Open a Session or Catalog in Capture One.
- `unsupported-version`: Capture One version is outside supported range (16.4+ through 16.x) or unverified (<16.4 or 17+). Override with `C1_ALLOW_UNTESTED_BUILD=1`.
- `unmanaged-variant`: Attempted write without editing permission, or attempted deletion of an existing variant. Use `variant_edit` before adjustment/geometry writes; deletion remains clone-only.
- `request-cancelled`: Inventory stopped at a safe boundary, or a queued MCP request was cancelled before dispatch; no partial inventory is returned.
- `deadline-exceeded`: Inventory exceeded its read deadline at a boundary; an outstanding Apple Event cannot be interrupted.
- `capture-one-busy`: Cross-process advisory lock timed out; wait or check for hung processes.
- `document-changed`: Document count, exact identity, or application lifetime no longer matches. Same-file reopening in one app launch is not reliably detected.
- `state-changed`: Optimistic concurrency check failed (`--if-state` mismatch).
- `readback-mismatch`: Capture One returned values outside tolerance.
- `permission-denied`: Automation permission missing in macOS System Settings. Ensure parent app (Terminal, Claude Desktop, Cursor) has Capture One enabled under Privacy & Security > Automation.


## Validation workflow

Use `make check` for routine offline feedback. For native behavior or live-harness changes, use `make qualify` (packaged CLI, MCP, and existing-variant workflows), or select affected suites with `QUALIFY_SUITES="geometry lens"`. Use `make qualify-extended` for all eleven regular live suites. Avoid rerunning unrelated live matrices; documentation-only changes need relevant syntax/link checks.

Run relevant recovery tests when a change can affect recovery behavior; a separate explicit user request is not required. Changes to mutation dispatch, durable journaling, unresolved-write blocking, lock ownership, timeout handling, application lifetime, restart/reconciliation, or stale-reference invalidation require affected live fault cases as well as offline safeguards. Use `make qualify-recovery RECOVERY_CASES="..."` against an archive rebuilt from the candidate. Select `tonal`, `geometry`, `lens`, `perspective`, or `keystone` for those mutation paths, `preview` for export timeout/completion, `mcp-death` for MCP cancellation/process lifetime, and `clone-readback` for clone-ID readback. Shared recovery changes need all affected fault paths; use `RECOVERY_CASES=all` when impact cannot be narrowed. Changes to the recovery harness's pause, dispatch detection, shutdown, identity checks, or reconciliation assertions require the cases they affect.

Do not run live faults for unrelated features, documentation, build/CI changes, or test-selection/reporting changes that leave fault behavior and assertions unchanged; validate those with focused offline checks. Release checkpoints alone do not require a repeated fault campaign. `make qualify-full` combines all regular and recovery suites when broad coverage is needed. Keep Capture One calls sequential, retain real timeout durations and fixture/ownership guards, and never retry an uncertain mutation. Report selected and omitted coverage and explain any unavailable required live validation; do not claim a focused pass covers the full campaign.

## Expanded native editing

Use `get` with `nativeTargets` / `c1 get --native-targets` to inspect all exposed adjustment properties,
curves, lens corrections, layers, luma range and color-editor objects. Use each requested `nativeSnapshots` entry's
`nativeStateHash` as `ifNativeState` / `--if-native-state` for
`native_set` or `native_action`. These require an existing `c1_edit_` reference
or managed clone and all normal document/image/build guards. Property names,
types and enumerations are listed in `capabilities.nativeEditing`.

Inspect fresh previews and journal `beforeNative`/`afterNative` snapshots.
Compact `get`, `diff`, `reset`, and editing baselines do not cover all native fields.
Restore reviewed native property values with an explicit patch and fresh token.
Mask pixels cannot be read, hashed or restored from native property snapshots;
layer/mask deletion and destructive mask commands require photographer judgment.
Take turns with the photographer and never retry an uncertain native operation.
The composition profile excludes native mutations; geometry remains governed by
its existing guards. See [native editing](docs/native-editing/README.md).

Select `QUALIFY_SUITES=native` for regular native editing validation and
`RECOVERY_CASES="native native-action"` for its affected fault paths.


## Reference recipes and compound edits

Use `reference_capture`, `recipe_register`, `recipe_verify`, `edit_apply` and
`edit_status` (CLI `recipe capture/register/verify/apply/status --file REQUEST`).
Requests share the published JSON schema. Capture records a preview and explicit
coverage limits; reference hashes are evidence, never mutation permission.

Registration does not authorize reuse. Verify each exact payload on an explicitly
created disposable managed clone; inspect its preview. Only verified payloads can
be applied, and changed payloads need new verification. Recipes currently support
fourteen global numeric settings, five point curves, grain type/impact/granularity,
vignette method/amount and explicit exposure/white-balance policies. Omitted fields
retain destination values; a supplied curve replaces its full channel point list.
Mask/layer reconstruction, indexed color fields and camera/lens profiles (including
`film curve`) are excluded from recipe transfer.

`edit_apply` prepares one existing variant and retains fresh per-step native
preconditions, before-state, readback and child operation IDs. Exposure/WB policies
are mandatory in recipes; per-photo overrides are explicit. Crop policy preserves
geometry unless `per-photo` is selected and explicit geometry with the inspected
`ifGeometryState` is supplied. Do not infer a crop from reference coordinates.

Inspect the returned completion report and final observations. On failure, stop:
never automatically retry, resume or undo a compound edit. Use `edit_status` with
the parent `compoundId`; use `operation_status` with uncertain child operation IDs
for normal restart/reconciliation. Interrupted parent reports do not become
successful when a child is reconciled. Production commands never quit Capture One.

Select `QUALIFY_SUITES=recipes` for the regular suite. Use
`make qualify-recipes-recovery RECIPE_RECOVERY_CASES="native tonal geometry preview mcp-death"`
for affected compound fault paths against the candidate archive. Keep offline tests
and live suites sequential because both use the application lock. See
[recipe workflow](docs/recipes/README.md) for the full bounded contract.
