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

## Validation

Offline tests cover stored-crop rejection, lens-context preservation, numeric edge
behavior and proposal containment. The lens live suite checks an off-center crop,
records native normalization and a contained proposal, verifies unchanged lens
context, and restores its fixture after a successful observation.

Production bounds changes require the packaged `geometry lens` suites and affected
`geometry lens` recovery cases against a rebuilt archive. Broaden selections when
perspective, keystone or shared recovery paths change. Run diagnostics in disposable
fixtures and keep generated observations outside tracked documentation.
