# Reference recipes and compound edits (experimental)

A recipe is a versioned c1 payload, not a Capture One processing/export recipe
or an installed style. CLI and MCP use the same core and JSON request contract.
The shared contract is 2.7.0. Only Capture One 16.8.5.30 is supported. Catalog edits retain the existing exact
path opt-in and referenced-original guards. Hand over exclusive control: the
application lock coordinates c1 processes, not edits made in the Capture One UI.

## Supported settings

Global numeric settings: brightness, contrast, saturation, highlight adjustment,
shadow/white/black recovery, clarity amount/structure, sharpening amount/radius/
threshold, and luminance/color noise reduction. Exposure and white balance have
separate mandatory policies. Settings also accept:

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
separate from these five point curves and belongs in the version-2 camera scope.

All eleven image color-balance controls are supported in
`settings`/`overrides`. Camera film curves/profiles, lens controls and indexed color
bands use the explicit version-2 scopes below. Layers, masks, Skin Tone corrections,
installed styles and profile installation remain excluded from recipe application.

A reference bundle captures compact settings, metadata, geometry, full image
adjustment/lens/variant snapshots, document and parent-image identities, state
hashes, a preview with pixel hash and JPEG file checksum, and coverage metadata.
It explicitly identifies unsupported mask pixels/Skin Tone and uncaptured layer
settings and profile asset bytes. This is not a complete Capture One backup or an
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

Verification applies the payload, checks all 38 supported image settings (numbers, enums
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

## Explicit scoped recipes (version 2)

A version-2 payload keeps the required `settings`, `exposure`, `whiteBalance` and
`cropPolicy`, and may add `scopes`. For example:

```json
{
  "version": 2,
  "referenceId": "REFERENCE_SHA256",
  "settings": {
    "color balance shadow saturation": 0.2,
    "color balance shadow hue": 237
  },
  "exposure": {"mode": "preserve"},
  "whiteBalance": {"mode": "preserve"},
  "cropPolicy": "preserve",
  "scopes": {
    "camera": {
      "cameraModel": "EXACT_METADATA_CAMERA",
      "settings": {"film curve": "Linear Response"}
    },
    "lens": {
      "cameraModel": "EXACT_METADATA_CAMERA",
      "lensModel": "EXACT_METADATA_LENS",
      "geometryPolicy": "preserve-crop",
      "settings": {"light falloff": 15}
    },
    "basicColor": [
      {"index": 2, "name": "orange", "settings": {"hue change": 5}}
    ]
  }
}
```

Use identities from the destination's observed `metadata.camera` and
`metadata.lens`; mismatches fail before dispatch. Camera settings accept `film
curve` and `color profile` native names. These refer to installed Capture One
assets, not embedded ICC/profile files. Names and observed values are recorded;
profile asset bytes are neither captured nor independently hashed.

Lens settings accept the writable fields in `capabilities.nativeEditing.fields.lens`.
Every application of a lens scope requires a fresh inspected `ifGeometryState`,
even without an explicit geometry patch. `preserve-crop` requires the crop,
rotation, orientation, flip and keystone to remain unchanged. `allow-native-crop`
permits native crop adjustment and requires `cropPolicy: per-photo`; it does not
authorize rotation, flip or keystone changes. Explicit geometry still uses the
existing guarded geometry step and its own fresh token. Lens/profile side effects
that violate omitted-field or policy checks fail with partial observations; the
workflow never automatically restores or retries them.

Basic color patches are image-level, explicitly named indices (1–9). Index and
name must match the destination; omitted bands and fields retain their values.

Advanced corrections use `scopes.advancedColor: {"mode":"replace","bands":[...]}`.
Each band must include all twelve exposed fields: `enabled`, `red`, `green`,
`blue`, `hue start`, `hue end`, `saturation start`, `saturation end`, `smoothness`,
`hue change`, `saturation change`, `lightness change`. Start from the reference's
`scopedNative.advancedColor` observations; do not infer numeric values or units.
Replacement deletes existing image-level advanced bands from last to first, then
creates and writes the declared list in order. An empty list explicitly clears
all advanced bands. Omitting this scope preserves the destination list. Up to 64
advanced bands are supported; this is a limit, not a partial-capture mode.

Each profile/lens/basic-band patch and each advanced-band deletion, creation and
patch has a separate plan step, fresh native precondition, durable before-state,
operation ID and readback. Deletion verifies the count decreased by exactly one.
Scope payloads are immutable recipe content; changing a scope requires a new
registration and disposable-clone verification. Per-photo tonal, white-balance,
geometry and image-settings overrides remain explicit; arbitrary per-photo scope
replacement is not a bypass for payload verification.

Version-2 verification and application independently inspect all camera/lens and
image color-band values, including omitted scopes. They reject unexpected changes.
The result includes `scopedBefore`, `scopedObserved`, and
`resultBundle.scopedNative` with before/after/diff evidence and observation hashes.
These hashes are evidence only, never mutation preconditions. Reference capture
includes the same independent indexed-color observations. Version-1 reports
retain their narrower comparison coverage.

Layer settings, mask pixels and Skin Tone remain excluded; installed style
registration/application is not part of this route. Numeric verification must be
followed by visual review of the disposable clone. Implementing these scopes does
not qualify a complete wedding look or make a recipe portable across arbitrary
camera/lens/profile combinations.

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

Each operation handles one photo per call. Multi-photo scheduling, automatic
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
  --cases native native-action lens layer-color geometry mcp-death
```

Set `C1_TEST_RAW_FIXTURE` to an existing RAW and close other documents first.
This harness inherits the existing ownership, independent resume watchdog,
real timeout, restart, stale-reference and original-preservation checks. The
case names here select faults inside compound operations, except `layer-color`,
which checks shared native deletion/reconciliation context on a layer. It creates its own
Session and retains failed/ambiguous evidence; it never retries a faulted edit.

For focused scoped regular checks, set `C1_RECIPE_TEST_GROUP=scopes`; the default
`all` also repeats the version-1 recipe cases.

These live checks include sequential native reads/writes, independent verification
and preview exports. They are intentionally separate from the fast offline loop.
Recovery retains actual 120-second Apple Event timeouts. Save generated results
and journals under `.build/qualification` or external artifact storage, not docs;
record historical validation summaries in `CHANGELOG.md`.
