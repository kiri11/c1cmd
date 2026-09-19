# Reference recipes and compound edits (experimental)

A recipe is a versioned c1 payload, not a Capture One processing/export recipe
or an installed style. CLI and MCP use the same core and JSON request contract.
Only Capture One 16.8.5.30 is supported. Catalog edits retain the existing exact
path opt-in and referenced-original guards. Hand over exclusive control: the
application lock coordinates c1 processes, not edits made in the Capture One UI.

## Supported first version

Global numeric settings: brightness, contrast, saturation, highlight adjustment,
shadow/white/black recovery, clarity amount/structure, sharpening amount/radius/
threshold, and luminance/color noise reduction. Exposure and white balance have
separate mandatory policies. Native curves, color-editor bands, layers, masks,
camera profiles and lens settings are excluded from recipe application in this
version; they remain available through their existing native APIs.

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
    "settings": {"clarity amount": 5, "highlight adjustment": 10},
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

Verification applies the payload, checks all 17 supported numeric values through
an independent direct-property AppleScript reader, checks omitted image-native
properties plus geometry/metadata/layers for preservation, and exports a preview.
The native highlight-recovery alias is checked as the negative of highlight
adjustment; it is not treated as an unrelated omitted field.

Verification evidence is bound to the recipe hash, exact build and durable report
hash. A failed verification never authorizes reuse. Inspect its preview for visual
quality; numeric verification is not aesthetic approval. The clone remains for
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
