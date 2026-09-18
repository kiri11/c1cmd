# Expanded native editing (experimental)

`native_get`, `native_set`, and `native_action` expose the Capture One 16.8.5.30
editing dictionary through both CLI and MCP. The original `get`, `set`, `add`,
`reset`, geometry, and metadata tools keep their existing contracts.

This is an explicit generated allowlist, not an arbitrary AppleScript executor.
`capabilities.nativeEditing` lists every field, native type, enumeration, and
permitted target. The generated resource is checked against the retained SDEF in
`make check`; regenerate with `python3 scripts/generate-native-editing.py`.

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
are **1-based**, obtained from `native_get.layers`, `basicColorCount`, and
`advancedColorCount`. These are inspected positions, not persistent native IDs.
Always read again after layer or color-element creation/deletion.

The eight geometry properties in adjustment settings are inspection-only here.
Use `geometry_set` for crop, rotation and keystone. Existing repository guards
continue to block orientation/flip changes and crop-outside-image. Container
properties (`adjustments`, `color editor settings`, `luma range`) are traversed
through typed targets rather than replaced as opaque objects. Capture One's
dictionary explicitly does not expose Skin Tone color-editor corrections.

## Workflow

Prepare the existing variant with `variant_edit` using the normal document and
state tokens. Then inspect the expanded state and write against its own token:

```sh
c1 native get c1_edit_... --scope adjustments
c1 native set c1_edit_... --if-native-state HASH \
  --json '{"highlight adjustment":20,"clarity amount":10,"noise reduction luminance":30}'
c1 native set c1_edit_... --if-native-state FRESH_HASH \
  --json '{"rgb curve":[0,0,50,55,100,100]}'
c1 preview c1_edit_...
```

Equivalent MCP requests:

```json
{"ref":"c1_edit_...","target":{"scope":"adjustments"}}
```

```json
{"workingRef":"c1_edit_...","target":{"scope":"adjustments"},"ifNativeState":"HASH","patch":{"clarity amount":10}}
```

Property keys use the exact dictionary names, including spaces. Booleans are
JSON booleans; native enumerations are the strings listed by `capabilities`.
Curves are flat `x,y` pairs in the native 0–100 scale, with strictly increasing
x coordinates. RGB colors are three integers in 0–65535. Values must have the
right native type; documented/retained ranges are enforced where available.
For properties without qualified bounds, native normalization can produce a
readback mismatch; this is an uncertain operation requiring normal recovery.

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
content and the installed application's capability.

## State, evidence, and recovery

All writes require the exact build, existing write authorization, one open
document, exclusive sequential use, and the normal referenced-Catalog guards.
`nativeStateHash` binds the target, available values, layer inventory, document
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
a deleted layer/mask. Journal revision detects cooperating API operations only.
Do not edit in the UI or through another automation during a workflow. Mask
commands record native command return and observable state, not pixel-level
readback verification. Keep native document backups when editing valuable masks.

`dryRun` validates target, permission, token, and arguments without dispatch. It
returns the current snapshot, not a predicted native rendering. On partial
failure, timeout, or missing readback, stop: inspect the operation, restart and
reopen the same database, reconcile observations, and create a fresh editing
reference. Never blindly retry or automatically undo.

`C1_MCP_PROFILE=composition` hides and rejects `native_set` and `native_action`.
The read-only native inspection tool remains available.

## Validation

Offline coverage includes schema/type guards, generated-resource drift, stale
state, unmanaged references, dry runs, durable native before-state, unresolved
write blocking, restart observations, and expired references.

`Tests/native_editing_integration_test.py` exercises the packaged CLI/MCP surface
in an owned disposable Session with a copied RAW. Select it using
`make qualify QUALIFY_SUITES=native`. Relevant real fault cases are
`make qualify-recovery RECOVERY_CASES="native native-action"` against the rebuilt
archive. Qualification results and exclusions must be recorded separately from
this implemented capability inventory.

See the [retained 16.8.5.30 qualification](16.8.5.30/README.md) for exact tested controls, payload hashes and omissions.
