# Geometry reference

Crop, rotation and keystone on an existing editing reference or managed clone.
Composition choices follow the [crop policy](../../AGENTS.md#crop-policy); writes
follow the [safety invariants](../../AGENTS.md#safety-invariants). Geometry writes
require Capture One 16.8.5.30.

## Commands and tokens

`c1 geometry set` / `geometry_set` applies absolute values and takes
`ifGeometryState` from `get.geometryStateHash`. This versioned token covers
geometry plus the tonal hash; the tonal `stateHash` does not cover crops. `get`,
`dump` and `diff` include geometry, and editing references and new clones keep a
geometry baseline.

```sh
c1 get <working-ref>
c1 geometry set <working-ref> --if-geometry-state <geometryStateHash> --rotation 1.2 --aspect-ratio 1.5
c1 preview <working-ref> --full-frame
# Inspect the rotated context, re-read get, then choose an explicit crop:
c1 geometry set <working-ref> --if-geometry-state <fresh-geometryStateHash> --crop 3000,2100,4500,3000
c1 preview <working-ref>
c1 diff <working-ref>
```

MCP takes `workingRef`, `ifGeometryState`, optional `dryRun`, and any of
`crop: {centerX, centerY, width, height}`, `rotation` and `aspectRatio`. `crop` and
`aspectRatio` are mutually exclusive. Rotation is absolute native degrees
(positive clockwise), −45 to +45. `aspectRatio` fits a centered crop inside the
usable bounds; choose an explicit crop when centering weakens the composition. A
dry run predicts values without dispatch; its token is the current precondition,
not a predicted post-write token.

`c1 geometry restore` / `geometry_restore` restores the saved crop, rotation and
all five keystone controls with a fresh geometry token, and refuses a changed
orientation or lens context. Its dry run reports the saved target.

## Coordinates

Coordinates are pixels in the **oriented, rotated canvas** with a bottom-left
origin. Preview metadata includes the rendered `geometry.crop` and pixel size. For
a normalized preview point `(u, v)` measured from the top left:
`x = centerX + (u − 0.5) × width`, `y = centerY + (0.5 − v) × height`. This maps to
the current rotated canvas, not sensor coordinates, so render again after changing
rotation.

Bounds use the original file's intrinsic pixel size read through ImageIO, because
Capture One can report rotated first-variant dimensions as the parent image's. If
the size cannot be read, geometry is unavailable and tonal editing still works.

`--full-frame` / `fullFrame: true` renders the largest context rectangle at the
current rotation through a temporary managed clone, then deletes it.
`contextSourceRef` names the source; `workingRef` and `nativeVariantId` name the
temporary clone. On failure the clone and journal are kept for recovery. The
source crop is never reset.

## Bounds

**Uncorrected images** (no lens distortion, keystone or lens movements) use a
conservative centered rectangle inside the rotated image, exposed as
`geometryUsableBounds`.

**Corrected images** use Capture One's read-only `maximumCrop` at the current
rotation. Lens distortion 0–100 is supported and its amount, profile and "hide
distorted areas" setting are preserved. Existing keystone and lens tilt/shift are
preserved. Their native maximum is an upper bound: Capture One may shrink a
centered ratio fit, so the final crop must keep the requested ratio and lie inside
the proposed rectangle.

A rotation change queries fresh bounds after the native rotation, inside the
journaled operation, then fits `aspectRatio` or validates the explicit crop.
Rotation-only requests keep Capture One's automatically recentered crop, even when
it exceeds the reported bounds. With lens or perspective corrections, `dryRun`
rejects rotation changes and ratio fits because native results cannot be
predicted; explicit-crop dry runs at the current rotation remain. A failure after
rotation, including an explicit crop outside the new bounds, can leave the
rotation applied and is an uncertain operation.

Explicit crops allow two pixels per edge. Distortion outside 0–100, flips,
crop-outside-image and unqualified orientations are blocked.

### Stored crops

A stored crop is an observation, not proof that the same rectangle can be
submitted. Never widen bounds to the union of bounds and a stored crop, and never
disable lens correction to admit a request. `scripts/propose-contained-crop.py
input.json` reads `crop` and `bounds` objects (`centerX`, `centerY`, `width`,
`height`) from the same fresh read and rotation. It scales both dimensions by one
factor (never enlarging), moves the center the minimum distance to fit, and
reports every delta. The result is a changed rectangle that needs preview review;
nothing is applied and no token is produced.

## Keystone

Keystone controls are optional absolute values; omitted controls keep their
values. They use the same token, journal and readback as crop and rotation.

| CLI flag | MCP `keystone` key | Range |
|---|---|---|
| `--keystone-amount` | `amount` | Integer 10–120 |
| `--keystone-vertical` | `vertical` | −75–75 |
| `--keystone-horizontal` | `horizontal` | −75–75 |
| `--keystone-skew` | `skew` | −45–45 |
| `--keystone-aspect` | `aspect` | −50–100 |

```sh
c1 geometry set <working-ref> --if-geometry-state <geometryStateHash> \
  --keystone-vertical 12 --keystone-horizontal=-7 --aspect-ratio 1.5
```

```json
{"workingRef":"c1_edit_...","ifGeometryState":"geometry-v1:...","keystone":{"vertical":12,"horizontal":-7},"aspectRatio":1.5}
```

`keystone.aspect` changes image proportions; `aspectRatio` is the crop ratio. Clear
a correction by setting vertical, horizontal, skew and aspect to zero. There is no
automatic line detection. Keystone setters run before rotation and crop fitting,
and bounds are queried afterwards. Keystone changes reject `dryRun`. Native
setters are sequential, so a failure can leave a partial correction. Diffs use
`keystone.amount` through `keystone.aspect`; response `geometry.keystone` keeps the
array order `[amount, vertical, horizontal, skew, aspect]`. See the
[Capture One keystone documentation](https://support.captureone.com/hc/en-us/articles/360002588058-Keystone-correction).

## Examples

[crop-proposals.py](../../examples/crop-proposals.py) applies explicit proposals
with source preconditions and before/after previews, keeping `unreviewed` sidecars
for the photographer. It edits existing variants by default; `--clone` makes
separate proposals. Neither it nor `grade-folder.py` judges aesthetic quality.

Validation: [maintainer guide](../MAINTAINING.md#run-only-what-the-change-affects).
