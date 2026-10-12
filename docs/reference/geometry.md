# Geometry reference

Orientation, crop, rotation and keystone on an existing editing reference or managed clone.
Composition choices follow the [crop policy](../../AGENT_GUIDE.md#crop-policy); writes
follow the [safety invariants](../../AGENT_GUIDE.md#safety-invariants). Geometry writes
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
`crop: {centerX, centerY, width, height}`, `rotation`, `aspectRatio`, `keystone`
and [`orientation`](#orientation). `crop` and
`aspectRatio` are mutually exclusive. Rotation is absolute native degrees
(positive clockwise), −45 to +45. `aspectRatio` fits a centered crop inside the
usable bounds. A dry run predicts values without dispatch; its token is the current
precondition, not a predicted post-write token.

### Positioned ratio fits

`anchor: {x, y}` / `--anchor x,y` moves the `aspectRatio` fit away from the center.
Each value is 0 to 1, measured on the image as viewed: `x` 0 is the left edge and 1
the right, `y` 0 is the top edge and 1 the bottom. The fit keeps its centered size
and moves inside the usable bounds. `0.5,0` aligns its top edge with the top of the
bounds, `0,1` puts it in the bottom-left corner, and `0.5,0.5` is the centered fit,
which c1 handles exactly as an omitted anchor. The result adds `anchoredCrop`, the
rectangle c1 chose. A dry run returns it without dispatch, so compare positions
with dry runs before writing. `anchor` requires `aspectRatio` and cannot be
combined with `crop` or `keystone`. Choose an explicit crop for any composition an
anchor cannot express.

```sh
c1 geometry set <working-ref> --if-geometry-state <geometryStateHash> --aspect-ratio 0.75 --anchor 0.5,0 --dry-run
```

```json
{"workingRef":"c1_edit_...","ifGeometryState":"geometry-v1:...","aspectRatio":0.75,"anchor":{"x":0.5,"y":0.2}}
```

`c1 geometry restore` / `geometry_restore` restores the saved orientation, crop,
rotation and all five keystone controls with a fresh geometry token, setting the
orientation first, and refuses a changed lens context. Its dry run reports the
saved target.

## Orientation

`orientation` / `--orientation` turns the picture in 90° steps. It is absolute:
0, 90, 180 or 270 degrees clockwise from the camera sensor's frame, which is
Capture One's own convention. A photo whose EXIF tag says "rotate 90 CW" (a
vertical frame) imports at 90 and shows upright there; at 0 it shows on its side.
So to stand a sideways picture upright, set the orientation it should have, not a
step from the current one; `get` reports the current value in
`geometry.orientation`. Setting the current orientation again changes nothing.

```sh
c1 geometry set <working-ref> --if-geometry-state <geometryStateHash> --orientation 90 --aspect-ratio 0.75
```

```json
{"workingRef":"c1_edit_...","ifGeometryState":"geometry-v1:...","orientation":90,"aspectRatio":0.75}
```

One request sets the orientation first, then keystone and rotation, then the
crop, and journals the orientation beside the before and after geometry: in the
planned `intendedGeometry` when c1 plans the crop, otherwise in
`requestedGeometry`. Rotation and keystone keep their values.

- **Orientation alone** keeps Capture One's own crop, which it turns with the
  canvas: a centred 3:2 crop becomes a centred 2:3 crop, and an off-centre crop
  moves with its content. `dryRun` rejects it because that crop is observed, not
  predicted. On an uncorrected image a turned crop that exposes a corner is
  listed in `exposedCorners`.
- **With `aspectRatio` or `crop`**, c1 crops the oriented canvas instead.
  Coordinates, bounds and anchors refer to that canvas, so a 3:4 fit after
  turning a landscape frame to 90 fills the portrait height. On an uncorrected
  image c1 plans and checks the crop before dispatch, and a dry run predicts it.
  On a lens-corrected image the bounds exist only after the native orientation,
  so the fit or check runs inside the journaled operation, `dryRun` is rejected,
  and an `anchor` is refused: set the orientation first, then the anchored ratio.

`exif.levelRotation` follows the orientation: it measures roll from the current
orientation, so after a change, read it again.


## Coordinates

Coordinates are pixels in the **oriented, rotated canvas** with a bottom-left
origin. Preview metadata includes the rendered `geometry.crop` and pixel size. For
a normalized preview point `(u, v)` measured from the top left:
`x = centerX + (u − 0.5) × width`, `y = centerY + (0.5 − v) × height`. This maps to
the current rotated canvas, not sensor coordinates, so render again after changing
rotation.

Anchors use a top-left convention on the same canvas: `y` 0 places the crop's top
edge on the top of the bounds, which is the largest canvas `y`. The canvas is
already oriented, so this holds for every orientation. An off-center position
rounds its center toward the middle of the bounds by less than a pixel, so an edge
placed on the bounds stays inside them.

Bounds use the original file's intrinsic pixel size read through ImageIO, because
Capture One can report rotated first-variant dimensions as the parent image's. If
the size cannot be read, geometry is unavailable and tonal editing still works.

`--full-frame` / `fullFrame: true` renders the largest context rectangle at the
current rotation through a temporary managed clone, then deletes it.
`contextSourceRef` names the source; `workingRef` and `nativeVariantId` name the
temporary clone. On failure the clone and journal are kept for recovery. The
source crop is never reset.

The full-frame result adds `currentCrop`: the source crop in preview pixels with a
top-left origin, as image tools address them, given as `left`, `top`, `width` and
`height` to a tenth of a pixel. With the context rectangle `geometry.crop` of the
result rendered at `width` × `height` pixels,
`left = (crop left − context left) × width ÷ context width` and
`top = (context top − crop top) × height ÷ context height`, where canvas left and
top are `centerX − width/2` and `centerY + height/2`. A crop outside the context
extends past the preview edges.

With `aspectRatio` and 1–9 `anchors` (`--aspect-ratio` and a repeated `--anchor
x,y`), the result also adds `candidateCrops`. Each entry holds the `anchor`, the
canvas `crop` that a `geometry_set` dry run with that anchor returns, and its
`preview` rectangle. c1 computes candidates from the source geometry before it
creates the temporary clone, so a request it cannot predict fails before any
write. c1 draws no overlay image.

```sh
c1 preview <working-ref> --full-frame --aspect-ratio 0.75 --anchor 0.5,0 --anchor 0.5,0.5 --anchor 0.5,1
```

## Bounds

**Uncorrected images** (no lens distortion, keystone or lens movements) use exact
containment: an explicit or ratio-fit crop is accepted when all four corners lie
inside the rotated image, allowing two pixels per edge. The image is the oriented
intrinsic size rotated about the canvas centre, so off-centre crops at any
rotation are accepted when contained, and a crop exposing a corner is rejected
before dispatch. `geometryUsableBounds` is the largest centred rectangle with the
image's proportions: the rectangle ratio fits are planned in, not the test.

**Corrected images** use Capture One's read-only `maximumCrop` at the current
rotation. Lens distortion 0–100 is supported and its amount, profile and "hide
distorted areas" setting are preserved. Existing keystone and lens tilt/shift are
preserved. Their native maximum is an upper bound: Capture One may shrink a
centered ratio fit, so the final crop must keep the requested ratio and lie inside
the proposed rectangle. A rotation change queries fresh bounds after the native
rotation, inside the journaled operation, then fits `aspectRatio` or validates the
explicit crop. With lens or perspective corrections, `dryRun` rejects rotation
changes and ratio fits because native results cannot be predicted; explicit-crop
dry runs at the current rotation remain.

**Anchored fits** use the same planning rectangle and the same validation as
centered fits. On an uncorrected image, a rotation and an anchor can share one
call, because c1 computes the bounds at the new rotation. On a lens-corrected image, c1 plans the anchored fit in
`maximumCrop` at the current rotation and dispatches it as an explicit crop, which
the journal records in `requestedGeometry.crop`. An anchor together with a
rotation change is refused there, because the new bounds exist only after the
native rotation: set the rotation first, then the anchored ratio. With keystone or
lens movements, Capture One normalizes ratio fits itself, so anchors are refused;
choose an explicit crop.

**Rotation-only requests** on either kind of image keep Capture One's automatic
crop: the native rotation runs inside the journaled operation and the observed crop
is the result, even when it differs from the stored one. `dryRun` rejects them
because that crop cannot be predicted. On an uncorrected image, a result whose crop
exposes a corner lists it in `exposedCorners` (canvas `x`, `y` and `distance` in
pixels); inspect a preview and choose an explicit crop.

A failure after orientation or rotation, including an explicit crop outside the
new bounds, can leave them applied and is an uncertain operation. Distortion
outside 0–100, flips and crop-outside-image are blocked.

### Stored crops

A stored crop is an observation, not proof that the same rectangle can be
submitted. Never widen bounds to the union of bounds and a stored crop, and never
disable lens correction to admit a request. `scripts/propose-contained-crop.py
input.json` reads a `crop` (`centerX`, `centerY`, `width`, `height`) and the
`geometry` object of the same fresh `get`. It applies exact containment on
uncorrected images and `maximumCrop` on corrected ones, scales both dimensions by
one factor (never enlarging), moves the center the minimum distance to fit, and
reports every delta. The result is a changed rectangle that needs preview review;
nothing is applied and no token is produced.

## Camera level

`c1 exif <ref>` / `exif` reads the camera's level sensor from the variant's
original with [exiftool](https://exiftool.org), which is installed separately
(`brew install exiftool`; `C1_EXIFTOOL` names a binary outside `PATH` and the
Homebrew locations). It only reads the file, needs no write opt-in and returns no
state tokens. Values the camera did not record are omitted.

`levelRotation` is the `geometry_set` rotation that levels the recorded roll,
measured from the variant's current Capture One orientation, or the EXIF
orientation when native geometry is unavailable. A vertical frame with a roll of
89.5° gives −0.5 at orientation 90 and no hint at 0, where it is 89.5° off level. Positive roll is clockwise camera rotation and is
levelled by the same clockwise rotation, so a vertical frame recorded at 93.9°
gives 3.9. It is omitted when roll is unrecorded, the variant is flipped, or the
result is more than 45° from level.

The hint levels the camera body, not the picture. Canon records roll in 0.1°
steps as a full-circle angle that passes 90° in vertical frames, so it is already
the direction of gravity in the sensor plane and pitch does not change it.
`levelRotation` therefore ignores `pitchAngle`. Canon's manuals give the level a
margin of about ±1°, larger when the camera is tilted far. Expect a
photographer's rotation to differ by a degree or two, and a hint near zero can
have the other sign. A tilted lens makes off-centre verticals converge (about 6°
at the edge of a vertical 50 mm frame pitched 24°), which rotation cannot fix, so
confirm the hint on a horizon or a line facing the camera, not on a converging
vertical, and never level an intentional diagonal.

`pitchAngle` is upward lens tilt and `focalLength35mm` the 35 mm-equivalent focal
length. Together they indicate how strongly verticals converge (strongly at 24 mm,
barely at 85 mm), but they are not a keystone amount. Verified on Canon EOS R6
Mark II CR3 files in EXIF orientations 1 and 6; orientations 3 and 8 use the same
arithmetic unverified, and other makes are reported as exiftool reads them.

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
