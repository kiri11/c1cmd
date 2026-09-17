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

## 2. Canonical Editing Workflow

1. Run `doctor` and confirm `allChecksPassed`, `writesEnabled`, and `exactBuildMatched`. Run `doc_info` and retain `openToken`.
2. List intended variants, using exact `rating` or `minRating` (integers 0–5), plus collection/selection scope. Verify parent-image paths against the requested folder; ratings alone do not establish folder membership. Results can include multiple existing variants of one image.
3. Read each intended source with `get`. Prepare **the existing variant** using `variant_edit` with its `sourceRef`, `ifState`, and the document's `ifDocument` token; supply `ifGeometryState` too for crop proposals. Retain the returned `workingRef` and baseline.
4. Read the editing reference immediately before applying changes. Tonal `set`, `add`, and `reset` require `ifState`; crop/rotation require `ifGeometryState`. These operations affect the same native variant. All supported adjustment fields are available in the default MCP profile.
5. Inspect a fresh `preview` and `diff` against the saved baseline. Photographer and agent take turns; the photographer continues on the same variant after the agent finishes.
6. For a rejected crop, use `geometry_restore` / `geometry restore` with a fresh geometry token. Restore tonal fields with `set` using saved `baselineAdjustments` and a fresh tonal token. `reset` retains its existing default-values semantics; it is not a full undo.
7. Baselines live in `.c1/editing.json`, and each dispatched mutation retains its before-state in the journal. Never automatically undo or retry an uncertain operation. References expire after application restart/database replacement; retained baselines remain evidence for manual review.

Use `variant_clone` only for explicitly requested separate proposals. Cloned references retain baseline diff/restore support and can be removed with `variant_delete` after review.

---

## Crop and Rotation Workflow

For composition corrections, prepare the existing variant with `variant_edit`; preserve its look. This creates no duplicate variant. Use `get.geometryStateHash` with `geometry_set.ifGeometryState` (CLI `geometry set --if-geometry-state`). The existing tonal `stateHash` does not cover crops. Geometry writes support crop rectangles and absolute rotation only, on Capture One 16.8.5.30. Keystone and lens settings remain unchanged. Apply the same journal, timeout, document opt-in, and managed-reference rules as tonal edits.

Use 3:2 width:height for horizontal pictures and 3:4 for vertical pictures. Straighten credible horizons/lines with rotation while preserving interesting composition. Flag rare keystone cases and ratio exceptions for review. Do not automatically level natural diagonals or treat an unchanged proposal as accepted.

`geometry_set` accepts `crop: {centerX, centerY, width, height}`, `rotation` (-45 to +45 degrees), or `aspectRatio` (1.5 landscape, 0.75 portrait) for a centered fit. Crop coordinates use the oriented, rotated canvas with bottom-left origin. After rotation, inspect a fresh preview before choosing precise crop coordinates. `preview(fullFrame: true)` uses and cleans up a temporary managed context clone; failed workflows retain evidence for normal recovery. See [README](README.md#crop-and-rotation) for mapping and limitations.

Existing lens distortion correction in 0...100 is preserved and supported using native crop bounds. Nonzero-distortion rotation changes obtain bounds after the native rotation, inside the journaled operation; `dryRun` cannot predict them and rejects that combination. Rotation-only uses Capture One's automatic crop adjustment. Prefer rotation plus `aspectRatio`, inspect the export, then choose an explicit crop with a fresh token. An invalid explicit crop after rotation can leave an uncertain partial operation and must follow normal recovery. Lens tilt/shift, keystone, flips, and crop-outside-image remain blocked. Never disable lens correction to bypass these guards.

The default profile permits all supported adjustments on existing editing references. Only use `C1_MCP_PROFILE=composition` when a crop-only restriction is wanted; that profile hides tonal mutation tools and native default-baseline creation.

## 3. Supported Adjustment Fields & Valid Ranges

The tonal `set`, `add`, and `reset` tools support only this table; use `geometry_set` for crop and rotation:

| Parameter | Aliases | Minimum | Maximum | Unit | Description |
|---|---|---|---|---|---|
| `exposure` | `exp` | `-4.0` | `+4.0` | EV | Exposure compensation |
| `contrast` | - | `-50.0` | `+50.0` | Int/Float | Contrast adjustment |
| `saturation` | `sat` | `-100.0` | `+100.0` | Int/Float | Saturation adjustment |
| `temperature` | `kelvin`, `temp` | `800.0` | `14000.0` | Kelvin | White balance Kelvin |
| `tint` | - | `-50.0` | `+50.0` | Float | White balance tint |

> **White Balance Note:** `temperature` and `tint` are coupled in Capture One. Whenever modifying white balance, always inspect both values after the write.

---

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
