# Expanded native editing (experimental)

`get` with `nativeTargets`, `native_set`, and `native_action` expose the Capture One 16.8.5.30
editing dictionary through both CLI and MCP. Omitting `nativeTargets` returns a
compact read. Mutation and geometry/metadata preconditions use scope-specific tokens.

This is an explicit generated allowlist, not an arbitrary AppleScript executor.
`capabilities.nativeEditing` lists every field, native type, enumeration, and
permitted target. The generated resource is checked against the retained SDEF in
`make check`; regenerate with `python3 scripts/generate-native-editing.py`.

## Scoped reads

Use one public read operation for a single variant, with 1...16 optional native
targets. Examples:

```sh
# Compact adjustments, metadata, geometry and state tokens:
c1 get 123
# Add full adjustment and lens snapshots:
c1 get 123 --native-targets '[{"scope":"adjustments"},{"scope":"lens"}]'
# Read layer attributes and that layer's adjustments:
c1 get 123 --native-targets '[{"scope":"layer","layer":1},{"scope":"adjustments","layer":1}]'
```

Equivalent MCP `get` arguments:

```json
{"ref":"123","nativeTargets":[{"scope":"adjustments"},{"scope":"lens"}]}
```

The ordinary fields stay at the top level. Expanded responses additionally contain
`openToken` and `nativeSnapshots` in requested order. A duplicate target repeats
its first observed snapshot without another native read. Compact responses omit
these optional fields. Human-readable CLI output includes the requested snapshots.

One target uses the direct single-scope path. Multiple targets share one application
lock, source read and journal revision; a final source/document/journal check
rejects detected drift. Exceptions discard the entire response. These are
sequential live observations, not an atomic snapshot of every setting: do not edit
in the UI or switch documents during a read. Native-only changes between scopes
are not guaranteed to be detected by the final compact-state comparison. The
bounded batch completes once dispatched; inventory-specific cancellation and
deadline controls do not apply.

Use each snapshot's `target` and `nativeStateHash` for its corresponding native
mutation, with a fresh read before the next write. One scope's token cannot
validate another; a write may invalidate other snapshots. The same tokens work
for existing editing references and managed clones. Reading a bare variant ID
does not authorize a write.

Reads use Capture One's AppleScript interface to observe live application state.
Verify indexed color-band targets against an independent bulk oracle before
using them for palette transfer.

Each native mutation takes a fresh single-target read for its token and journal
before-state, then an independent readback. No observation is reused after a
write, export, failure or restart.

## Targets and coverage

| Scope | Properties exposed | Writable | Target |
|---|---:|---:|---|
| `adjustments` | 89 | 81 | Image adjustments, or a numbered layer |
| `lens` | 16 | 16 | Variant lens corrections |
| `layer` | 4 | 3 | Layer name, enabled state, opacity; kind is read-only |
| `luma` | 7 | 7 | Layer luma range, falloff, inversion, radius, sensitivity |
| `basicColor` | 4 | 3 | Numbered basic color correction; name is read-only |
| `advancedColor` | 12 | 12 | Numbered advanced color correction |
| `variant` | 5 | 5 | Processing mode and LCC switches/amount |

Adjustment fields include exposure, brightness, white balance and presets, color
profile, film curve, color balance, black-and-white channel/split-tone controls,
all RGB/channel levels, five curve channels, HDR, clarity, structure, dehaze,
vignetting, sharpening, noise reduction, grain, and moire.

`layer: 0` means the image adjustments; other layer and color-element indices
are **1-based**, obtained from each `get.nativeSnapshots` entry's `layers`, `basicColorCount`, and
`advancedColorCount`. These are inspected positions, not persistent native IDs.
Always read again after layer or color-element creation/deletion.

The eight geometry properties in adjustment settings are inspection-only here.
Use `geometry_set` for orientation, crop, rotation and keystone. Existing
repository guards continue to block flip changes and crop-outside-image. Container
properties (`adjustments`, `color editor settings`, `luma range`) are traversed
through typed targets rather than replaced as opaque objects. Capture One's
dictionary explicitly does not expose Skin Tone color-editor corrections.

## Workflow

Prepare the existing variant with `variant_edit` using the normal document and
state tokens. Then inspect the expanded state and write against its own token:

```sh
c1 get c1_edit_... --native-targets '[{"scope":"adjustments"}]'
c1 native set c1_edit_... --if-native-state HASH \
  --json '{"highlight adjustment":20,"clarity amount":10,"noise reduction luminance":30}'
c1 native set c1_edit_... --if-native-state FRESH_HASH \
  --json '{"rgb curve":[0,0,50,55,100,100]}'
c1 preview c1_edit_...
```

Equivalent MCP requests:

```json
{"ref":"c1_edit_...","nativeTargets":[{"scope":"adjustments"}]}
```

```json
{"workingRef":"c1_edit_...","target":{"scope":"adjustments"},"ifNativeState":"HASH","patch":{"clarity amount":10}}
```

Property keys use the exact dictionary names, including spaces. Booleans are
JSON booleans; native enumerations are the strings listed by `capabilities`.
Curves are flat `x,y` pairs in the native 0–100 scale, with strictly increasing
x coordinates. RGB colors are three integers in 0–65535. Values must have the
right native type.

### Numeric bounds

The fields below have bounds measured on Capture One 16.8.5.30. A value outside
its range fails with `invalidRequest` before dispatch, with no journal entry,
for example `Native exposure must be within -4...4.` Bounds are inclusive and
apply to every target of the scope, including layer adjustments. The `schema`
and `capabilities.nativeEditing` report each one as `minimum` and `maximum`.

| Range | Fields (`adjustments` scope unless named) |
|---|---|
| -100...100 | `black and white blue sensitivity`, `black and white cyan sensitivity`, `black and white green sensitivity`, `black and white magenta sensitivity`, `black and white red sensitivity`, `black and white yellow sensitivity`, `black recovery`, `clarity amount`, `clarity structure`, `dehaze amount`, `highlight adjustment`, `highlight recovery`, `saturation`, `shadow recovery`, `white recovery` |
| -50...50 | `brightness`, `contrast`, `tint` |
| -4...4 | `exposure`, `vignetting amount` |
| -1...1 | `color balance highlight lightness`, `color balance midtone lightness`, `color balance shadow lightness`, `level midtone blue`, `level midtone green`, `level midtone red`, `level midtone rgb` |
| 0...1 | `color balance highlight saturation`, `color balance master saturation`, `color balance midtone saturation`, `color balance shadow saturation` |
| 0...12 | `sharpening threshold` |
| 0...100 | `black and white split highlight saturation`, `black and white split shadow saturation`, `film grain granularity`, `film grain impact`, `moire amount`, `noise reduction color`, `noise reduction details`, `noise reduction luminance`, `noise reduction single pixel`, `opacity` (layer scope), `sharpening halo suppression` |
| 0...120 | `distortion` (lens scope) |
| 0...255 | `level highlight blue`, `level highlight green`, `level highlight red`, `level highlight rgb`, `level shadow blue`, `level shadow green`, `level shadow red`, `level shadow rgb`, `level target highlight blue`, `level target highlight green`, `level target highlight red`, `level target highlight rgb`, `level target shadow blue`, `level target shadow green`, `level target shadow red`, `level target shadow rgb` |
| 0...360 | `black and white split highlight hue`, `black and white split shadow hue`, `color balance highlight hue`, `color balance master hue`, `color balance midtone hue`, `color balance shadow hue` |
| 0...1000 | `sharpening amount` |
| 0.2...2.5 | `sharpening radius` |
| 4...80 | `moire pattern` |
| 800...14000 | `temperature` |

Capture One's own range errors can name the wrong limit, and it clamps an over-range color balance hue to 360 without an error, so these
checks run first. For numeric fields without bounds, native normalization can
produce a readback mismatch; this is an uncertain operation requiring normal
recovery.

Reads distinguish native unset values (`null`) from per-property `unavailable` errors. Unset layer properties may be assigned typed values; `null` is not accepted as a write or treated as zero.
Unavailable properties cannot be written. Application/permission/timeout errors
remain failures rather than being swallowed as unavailable properties.

## Layers and masks

`native_action` uses the same editing reference and `ifNativeState`, plus an
`action` and typed `arguments` object. CLI uses `c1 native action REF ACTION
--if-native-state HASH --scope SCOPE --layer N --json '{...}'`.

| Action | Target scope | Arguments |
|---|---|---|
| `layer.create` | `adjustments` | `name`, `kind`: adjustment, filled, clone, heal, subject mask, background mask |
| `layer.delete` | `layer` | None; image layer deletion is rejected |
| `mask.people` | `adjustments` | `areas` (array of native area names), `separateLayers` (boolean) |
| `mask.clear`, `mask.invert`, `mask.fill`, `mask.rasterize` | `layer` | None |
| `mask.feather` | `layer` | `amount` 0–100 |
| `mask.refine` | `layer` | `amount` 0–300 |
| `mask.copy` | `layer` (destination) | `sourceLayer` in the same variant |
| `luma.clear` | `layer` | None |
| `style.apply` | `layer` | `name` of an installed style/preset |
| `color.create` | `adjustments` | None; creates an advanced color correction |
| `color.delete` | `advancedColor` | None |
| `dehaze.pick` | `adjustments` | `point`: two pixel coordinates |
| `dehaze.recalculate` | `adjustments` | None |
| `lens.reset` | `lens` | None |

People-mask areas are `body skin`, `face skin`, `eyebrows`, `lips`, `hair`,
`iris and pupil`, `sclera`, and `clothes`. AI success depends on suitable image
content and the installed application's capability. On success Capture One keeps
the existing layers and appends one adjustment mask layer, or with `separateLayers`
up to one per area; a readback that differs is an uncertain operation.

On a photo without people, Capture One refuses the command ("No people detected",
-1728). `c1` then reads the target again, and only when values, layer inventory and
the tonal, geometry and metadata tokens are unchanged does it return the definite
error `no-people-detected`. Its journal entry resolves as `failed` and blocks no
later write. Any other error, or any observed change, stays an uncertain operation.
Live qualification on 16.8.5.30 found no change in readable state or exported
pixels across area and `separateLayers` combinations, with a filled-mask layer present.

## State, evidence, and recovery

Writes follow the [safety invariants](../../AGENT_GUIDE.md#safety-invariants) and
require Capture One 16.8.5.30. `nativeStateHash` binds the target, available values, layer inventory, document
lifetime, original-image identity, existing tonal/geometry/metadata tokens, and
latest journal operation for the variant. Native handlers recheck target values
and layer inventory immediately before dispatch. A successful mask command advances
the journal revision even when readable properties do not change.

Each write durably journals `beforeNative`, its patch or action/arguments, and
observed `afterNative`. Review both snapshots and a fresh preview. To restore
property values, submit an explicit reviewed patch from `beforeNative.values`
with a fresh token. The legacy `reset`/`diff`/editing baseline remain limited to
their established fields; they are not a full native-state undo or diff.

**Mask pixels are not exposed by the scripting dictionary.** Property snapshots
cannot detect arbitrary painted-mask changes, preserve mask pixels, or restore
a deleted layer/mask. Journal revision detects cooperating API operations only. Mask
commands record native command return and observable state, not pixel-level
readback verification. Keep native document backups when editing valuable masks.

`dryRun` validates target, permission, token, and arguments without dispatch. It
returns the current snapshot, not a predicted native rendering. A partial failure,
timeout or missing readback is an uncertain operation.

`C1_TOOL_PROFILE=composition` hides and rejects `native_set` and `native_action`.
The read-only native inspection tool remains available.

## Color balance

Color-balance patches write each requested saturation before its paired hue on
all four wheels, for both image and layer adjustments. Omitted controls are not
written. Hue readback uses circular distance, so 0 and 360 degrees are equivalent,
with a tolerance of 0.0001 degrees. At zero or very low saturation, some hue
values cannot be represented within that tolerance; a readback mismatch follows
the normal partial-failure and recovery rules.

Restoring a wheel to 0 / 0 reads back as hue 360 and a saturation residue of
about 3e-05, so the restored `nativeStateHash` differs from the baseline token.
Check a restore by comparing values, not tokens.
