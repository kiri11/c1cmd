# Stored crops and numeric boundaries

A stored crop is an observation, not evidence that the same rectangle can be
submitted as a contained explicit crop. Corrected geometry uses Capture One's
reported `maximumCrop` at the current rotation; uncorrected geometry uses the
conservative rotated rectangle exposed as `geometryUsableBounds`. Do not replace
these bounds with the union of the bounds and the stored crop or disable lens
corrections to admit a request.

The explicit containment check allows two pixels per edge. In one dimension its
mathematical center interval is `boundsCenter ± ((boundsSize-cropSize)/2 + 2)`.
At `cropSize = boundsSize + 4` this interval has zero width; larger sizes have no
valid center. Floating-point arithmetic can affect endpoint calculations. Do not
construct a closed range without checking its endpoints, and validate the final
rectangle with the actual containment expression. The regression tests exercise
both axes and both sides, exact endpoints, inward/outward subpixel steps, and
adjacent representable center values. This does not expand the tolerance.

## Read-only proportional proposals

Run `python3 scripts/propose-contained-crop.py input.json` from the repository.
The input has `crop` and `bounds` objects, each with `centerX`, `centerY`, `width`,
and `height`. Use the observed crop and `geometryUsableBounds` from the same fresh
native read and rotation. Archived database values are planning evidence only.

The planner scales both dimensions by the same factor (never enlarging), then
moves the center the minimum distance needed to fit. It does not spend the
two-pixel edge allowance. If rounding prevents containment, it reduces the scale
by adjacent floating-point values and rechecks. An impossible fit fails closed.
Output includes the original, proposal, bounds, scale, both ratios, and all four
signed deltas. `normalized-proposal` means a changed rectangle, never an exact
copy. Nothing is applied and no mutation token is produced.

For example, `(3400,2200,5400,3600)` inside bounds
`(3000,2000,5000,3400)` becomes approximately
`(3000,2033.333333,5000,3333.333333)`: center deltas `(-400,-166.666667)`
and size deltas `(-400,-266.666667)`, retaining 3:2 proportions.
This can alter composition and needs preview review. Native rounding can alter
the applied rectangle further; report actual readback and deltas separately.

Prepare an existing variant with fresh document/state/geometry tokens before
applying any reviewed proposal. Do not automatically restore an out-of-bounds
baseline by substituting a normalized crop. An uncertain operation still requires
normal reconciliation, with no automatic retry or undo.

## Validation scope

The September 19 disposable Session probe used a copy of `2U6A7257.CR3`.
With distortion at 50 and hide-distorted-areas enabled, reported bounds were
`(3001,2000,6000,4000)`. Requesting `(3301,2000,6000,4000)` directly in native
fixture setup produced the observed stored crop `(3301,2000,5404,3603)`.
Lens settings, rotation, orientation, and keystone were unchanged across that
probe. The right edge is 6003 versus the reported bound's 6001: a two-pixel
overhang, within the existing tolerance. This fixture does **not** demonstrate a
stored overhang beyond that tolerance. It also demonstrates native normalization,
not an exact copy of the requested crop.

The strict contained proposal is `(3299,2000,5404,3603)`, with deltas
`(-2,0,0,0)` and scale 1. The original observed ratio (about 1.49986123) is retained;
it is not relabeled as exact 3:2. The proposal was not applied during this probe.
See [retained observations](qualification/crop-bounds-20260919/lens/events.jsonl).

No production bounds, dispatch, readback, journal, or recovery behavior changes
in this investigation. Offline tests cover stored-crop rejection, lens-context
preservation, numeric edge behavior, and proposal containment. The lens live
suite additionally requests an off-center full-size crop on its owned clone,
records native normalization and a contained proposal, verifies unchanged lens
context, and restores its fixture after the successful observation.

Any future production bounds change requires the packaged `geometry lens`
suites and affected `geometry lens` recovery cases against a rebuilt archive.
Broaden those selections if perspective/keystone or shared recovery paths change.
