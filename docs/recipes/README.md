# Reference recipes and compound edits (experimental)

A recipe is a versioned c1 payload, not a Capture One processing/export recipe
or an installed style. CLI and MCP use the same core and JSON request contract.
Only Capture One 16.8.5.30 is supported. Catalog edits retain the existing exact
path opt-in and referenced-original guards. Hand over exclusive control: the
application lock coordinates c1 processes, not edits made in the Capture One UI.

## Supported settings

Global numeric settings: brightness, contrast, saturation, highlight adjustment,
shadow/white/black recovery, clarity amount/structure, sharpening amount/radius/
threshold, and luminance/color noise reduction. Exposure and white balance have
separate mandatory policies. Contract 2.6.0 also accepts:

- `rgb curve`, `luma curve`, `red curve`, `green curve`, `blue curve`: flat x/y
  point pairs in 0–100, with strictly increasing x (2–64 points).
- `film grain type`: `fine`, `silver rich`, `soft`, `cubic`, `tabular`, `harsh`;
  `film grain impact` and `film grain granularity`: numeric native amounts.
- `vignetting method`: `elliptic on crop`, `circular on crop`, `circular`;
  `vignetting amount`: numeric native amount.

These use the same `settings` object and per-photo `overrides`. Each supplied
curve replaces that channel's complete point list; omitted curves and grain or
vignette properties retain the destination values. Method/type and amount are
independent explicit fields. Recipes do not copy unspecified reference settings.
Payload version 1 remains valid; changed content requires a new registration and
independent verification. `film curve` (the camera processing curve/profile) is
separate from these five point curves and remains excluded.

Color-editor bands, layers, masks, camera profiles and lens settings are excluded
from recipe application in this version; they remain available through their existing native APIs.

A reference bundle captures compact settings, metadata, geometry, full image
adjustment/lens/variant snapshots, document and parent-image identities, state
hashes, a preview with pixel hash and JPEG file checksum, and coverage metadata.
It explicitly identifies unsupported mask pixels/Skin Tone and uncaptured layer
settings/color-editor elements. This is not a complete Capture One backup or an
atomic snapshot. Capture rejects detected drift around preview export.

## CLI and MCP

CLI syntax is `c1 recipe ACTION --file request.json --format json`. The JSON file
is exactly the corresponding MCP argument object:

| CLI action | MCP tool | Purpose |
|---|---|---|
| `capture` | `reference_capture` | Capture reference observations and export a preview |
| `register` | `recipe_register` | Validate and save an immutable content-addressed payload |
| `verify` | `recipe_verify` | Apply to an explicitly supplied managed clone; independently verify |
| `apply` | `edit_apply` | Prepare and edit one existing photo, returning observed results |
| `status` | `edit_status` | Inspect the durable compound report and interrupted child operations |

Use `c1 schema` for exact request and response schemas. The composition MCP
profile excludes capture, registration, verification and compound application;
status inspection remains available.

### Capture and register

Run `doctor` and confirm `allChecksPassed`, `writesEnabled` and
`exactBuildMatched`, then read `doc info` and a live `get`. Capture:

```json
{"ref":"123","ifDocument":"OPEN_TOKEN","ifState":"STATE_HASH"}
```

Registration requires the returned reference ID. For example:

```json
{
  "recipe": {
    "version": 1,
    "referenceId": "REFERENCE_SHA256",
    "settings": {
      "clarity amount": 5,
      "rgb curve": [0, 0, 50, 55, 100, 100],
      "film grain type": "silver rich",
      "film grain impact": 25,
      "film grain granularity": 30,
      "vignetting method": "circular",
      "vignetting amount": -0.5
    },
    "exposure": {"mode": "preserve"},
    "whiteBalance": {"mode": "preserve"},
    "cropPolicy": "per-photo"
  }
}
```

The payload hash is its recipe ID. Registration alone does not enable reuse.
Payloads and reference manifests are saved beneath the document's `.c1/recipes`
and `.c1/references` directories. Previews remain in their unique export folders;
preserve those folders with the manifests. New payload contents produce a new ID.

### Verify before reuse

Explicitly create a disposable managed clone using `variant clone`, then read
its current state. `recipe_verify` accepts `recipeId`, `workingRef`, `ifDocument`
and `ifState`. It never chooses or creates a clone silently and rejects existing
editing references and bare native IDs.

Verification applies the payload, checks all 27 supported values (numbers, enums
and curve point lists) through an independent direct-property AppleScript reader,
checks omitted image-native properties plus geometry/metadata/layers for
preservation, and exports a preview.
The native highlight-recovery alias is checked as the negative of highlight
adjustment; it is not treated as an unrelated omitted field.

Verification evidence is bound to the recipe hash, exact build and durable report
hash. A failed verification never authorizes reuse. Inspect its preview for visual
quality; value verification is not aesthetic approval. The clone remains for
review and explicit deletion. No automatic restoration follows any failure.

### Apply one photo

```json
{
  "recipeId": "RECIPE_SHA256",
  "sourceRef": "123",
  "ifDocument": "OPEN_TOKEN",
  "ifState": "STATE_HASH",
  "overrides": {"clarity amount": 7},
  "exposure": {"mode": "relative", "value": 0.25},
  "whiteBalance": {"mode": "preserve"},
  "ifGeometryState": "GEOMETRY_HASH",
  "geometry": {"aspectRatio": 1.5},
  "preview": true
}
```

Settings overrides replace recipe fields before dispatch. Exposure is explicitly
`preserve`, `absolute` or `relative`; non-preserve modes require a value. Relative
exposure is calculated from the fresh per-step observation. White balance is
`preserve` or `absolute`, with both temperature and tint required for absolute.
Overrides may replace those policies for an individual photo.

`cropPolicy: preserve` rejects geometry changes; `per-photo` allows explicit
geometry supplied by the caller, with the inspected `ifGeometryState`. Neither
policy copies reference crop coordinates. Supply 1.5 for landscape or 0.75 for
portrait when those ratios fit the intended composition. Geometry retains native
bounds, lens preservation and existing uncertainty rules. Precise cropping after
a rotation that needs visual inspection remains a second reviewed operation.

## Consolidated result bundle

Successful `edit_apply` and `recipe_verify` reports include `resultBundle`
(contract 2.5.0). It contains:

- `observed`: final live settings, geometry, metadata and image-native snapshot.
- `diff`: net changes from the fresh pre-edit observation to the final observation,
  grouped as `adjustments`, `geometry`, `metadata` and `nativeAdjustments`.
  Nested fields use dotted paths. Changed values include `before`, `after`, presence
  flags and a numeric `delta` when applicable. Differences reflect exact observed
  values, including native normalization, rather than requested patches.
- `provenance`: document and photo identity, immutable recipe payload and reference
  ID, prior verification evidence, effective per-photo policies, initial/final
  hashes, working reference and per-step operation IDs.
- `preview`: the exported preview result, or `null` when none was requested.
- `coverage`: compared and unavailable native fields and explicit exclusions for
  masks, layers, color-editor elements and native lens/variant snapshots.

Native fields are compared only when available in both observations. Unavailable
fields are reported as coverage gaps, not deletions or proof of preservation.
Geometry includes the fields exposed by the geometry snapshot. These sequential
observations are not an atomic snapshot or a complete backup.

The same bundle is persisted for `edit_status`, so evidence-only follow-up reads
are unnecessary. Existing `observed` and per-step results remain compatible.
Failed, uncertain or interrupted runs have partial reports without a final bundle;
older saved reports may also lack it. Hashes describe those observations: obtain
fresh preconditions before any later independent mutation. This feature adds no
read caching or execution-context optimization.

## Partial completion and recovery

A bounded application holds one application lock, prepares the existing variant,
applies merged settings, applies exposure/WB, optionally changes geometry and
exports a preview, then returns a final live observation. Each mutation retains
its own fresh token, durable before-state, child operation ID and readback. The
workflow does not substitute cached browsing data for mutation reads.

The parent report is durably saved in `.c1/compounds` before preparation and at
each step. Child journal records carry `compoundId`. Results contain `completed`
step observations, `activeStep`, failure details and `unattempted` steps on failure.
CLI exits nonzero and MCP sets `isError` for a failed/unknown/interrupted report.
Earlier observations remain historical; use only the final observation as final
state, and read freshly again before a later independent mutation.

`edit_status` accepts `compoundId`. A parent left running by process death is
reported as interrupted with exactly its linked child journal records. It does
not infer completion, retry, resume or reconcile. For an uncertain child, follow
`operation status CHILD_ID` and the normal restart/reconciliation procedure.
Restart invalidates old editing references. Even reconciled child observations
do not prove the interrupted compound completed.

The first version handles one photo per call. Multi-photo scheduling, automatic
resume, native style installation, mask reconstruction and generalized native
recipe transfer are intentionally outside this contract.

## Validation

`make check` includes offline recipe validation, content/evidence integrity,
unverified rejection, clone-only verification, partial completion and interrupted
parent/child correlation. Run the packaged regular suite with
`make qualify QUALIFY_SUITES=recipes` and a copied RAW fixture. Live recovery
qualification and retained results are recorded separately; implementation alone
does not establish live fault coverage.

Run dedicated compound recovery against a freshly built archive:

```sh
C1_RECOVERY_SHUTDOWN_MODE=sigterm \
  python3 -B Tests/recipe_recovery_integration_test.py \
  dist/c1-v0.1.0-macos-arm64.tar.gz /absolute/new/evidence \
  --cases native tonal geometry preview mcp-death
```

Set `C1_TEST_RAW_FIXTURE` to an existing RAW and close other documents first.
This harness inherits the existing ownership, independent resume watchdog,
real timeout, restart, stale-reference and original-preservation checks. The
case names here select faults inside compound operations. It creates its own
Session and retains failed/ambiguous evidence; it never retries a faulted edit.

See [retained qualification results](qualification/README.md) for tested scope,
binary hashes and exclusions.

See [result bundle qualification](result-bundle-qualification/README.md) for the
contract 2.5.0 focused checks and exclusions.

See [typed settings qualification](typed-settings-qualification/README.md) for
curve/grain/vignette transfer, omitted-field preservation and focused recovery evidence.
