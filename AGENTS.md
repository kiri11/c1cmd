# AGENTS.md — Instructions for AI Coding & Reasoning Agents

This file provides rules, architectural constraints, and standard operating procedures for autonomous or interactive agents (Claude Code, Cursor, Windsurf, Codex, etc.) utilizing `c1` via the CLI or the MCP server (`c1-mcp`).

---

## 1. Core Principles & Non-Negotiable Safety Rules

1. **Originals Are Immutable:**
   - You **cannot** mutate original variants or native variant IDs directly. Attempting to do so will be rejected with an `unmanaged-variant` error.
   - All mutations (`set`, `add`, `reset`) must target a **managed working reference** (`c1_wrk_<uuid>`).
   - Create a managed working reference by cloning the source variant first: `c1 variant clone <source-id>`.

2. **Sessions vs. Catalogs:**
   - Catalogs are strictly **read-only**. Any mutation verb on a Catalog fails closed with an `invalid-request` error.
   - For editing workflows, ensure a Session (`.cosessiondb`) is active.

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

## 2. Canonical Grading Workflow

Always follow this sequence when automating adjustments or grading a shoot:

```mermaid
flowchart TD
    Doctor[1. c1 doctor / doctor tool] --> DocInfo[2. c1 doc info / doc_info tool]
    DocInfo --> List[3. c1 variants list / variants_list tool]
    List --> Clone[4. c1 variant clone <id> / variant_clone tool]
    Clone --> Get[5. c1 get <workingRef> / get tool]
    Get --> Mutate[6. c1 set / add --if-state <hash>]
    Mutate --> Preview[7. c1 preview <workingRef> / preview tool]
    Preview --> Review[8. Photographer Review]
    Review -->|Keep| Done[Finished / Ready]
    Review -->|Discard| Delete[9. c1 variant delete <workingRef>]
```

1. **Health Check:** Run `c1 doctor` (or `doctor` tool in MCP). Confirm `allChecksPassed: true` and `isSession: true`.
2. **Context Discovery:** Run `c1 doc info` and `c1 variants list` to discover available image files and variant IDs. For culled picks, use `--rating 5` (MCP `variants_list: {"rating": 5}`); for four stars and above, use `--min-rating 4` (`{"minRating": 4}`). Choose one filter, using integers 0–5. Filters combine with collection/selection scope and do not change UI selection. Clone only the intended matching sources; results may include existing managed clones or multiple variants of one image.
3. **Isolate Changes:** Run `c1 variant clone <sourceId>` (e.g. `c1 variant clone 1`). Record the returned `workingRef` (e.g. `c1_wrk_...`) and initial `baselineStateHash`.
4. **Inspect State:** Run `c1 get <workingRef>`. Inspect adjustments, capture metadata, and note `stateHash`.
5. **Apply Adjustments:**
   - Use `c1 set <workingRef> --if-state <stateHash> [key=value...]` for absolute targets.
   - Use `c1 add <workingRef> --if-state <stateHash> [key=value...]` for relative deltas.
   - Read the returned `diff`, `after`, and updated `stateHash`.
6. **Visual Verification:** Run `c1 preview <workingRef>` (or `preview` tool in MCP). In MCP, this returns both image metadata and a base64 `image/jpeg` visual content block for inspection.
7. **Compare Changes:** Run `c1 diff <workingRef>` to inspect adjustments against the baseline.
8. **Rejection / Cleanup:** If the proposal is rejected by the photographer or fails visual inspection, cleanly remove the proposal with `c1 variant delete <workingRef>`. Never attempt to delete original variants.

---

## Crop and Rotation Workflow

For composition corrections, clone the existing edit with `variant_clone`; preserve its look. Use `get.geometryStateHash` with `geometry_set.ifGeometryState` (CLI `geometry set --if-geometry-state`). The existing tonal `stateHash` does not cover crops. Geometry writes support crop rectangles and absolute rotation only, on Capture One 16.8.5.30. Keystone and lens settings remain unchanged. Apply the same journal, timeout, Session-only, and managed-reference rules as tonal edits.

Use 3:2 width:height for horizontal pictures and 3:4 for vertical pictures. Straighten credible horizons/lines with rotation while preserving interesting composition. Flag rare keystone cases and ratio exceptions for review. Do not automatically level natural diagonals or treat an unchanged proposal as accepted.

`geometry_set` accepts `crop: {centerX, centerY, width, height}`, `rotation` (-45 to +45 degrees), or `aspectRatio` (1.5 landscape, 0.75 portrait) for a centered fit. Crop coordinates use the oriented, rotated canvas with bottom-left origin. After rotation, inspect a fresh preview before choosing precise crop coordinates. `preview(fullFrame: true)` uses and cleans up a temporary managed context clone; failed workflows retain evidence for normal recovery. See [README](README.md#crop-and-rotation) for mapping and limitations.

Use the `C1_MCP_PROFILE=composition` server environment for an agent restricted to composition edits. Tonal mutation tools and native default-baseline creation are then disabled.

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

## 5. Error Code Reference

- `app-not-running`: Launch Capture One and ensure GUI is active.
- `no-document`: Open a Session in Capture One.
- `unsupported-version`: Capture One version is outside supported range (16.4+ through 16.x) or unverified (<16.4 or 17+). Override with `C1_ALLOW_UNTESTED_BUILD=1`.
- `unmanaged-variant`: Attempted mutation on an unmanaged original; clone first.
- `capture-one-busy`: Cross-process advisory lock timed out; wait or check for hung processes.
- `document-changed`: Document count, exact identity, or application lifetime no longer matches. Same-file reopening in one app launch is not reliably detected.
- `state-changed`: Optimistic concurrency check failed (`--if-state` mismatch).
- `readback-mismatch`: Capture One returned values outside tolerance.
- `permission-denied`: Automation permission missing in macOS System Settings. Ensure parent app (Terminal, Claude Desktop, Cursor) has Capture One enabled under Privacy & Security > Automation.
