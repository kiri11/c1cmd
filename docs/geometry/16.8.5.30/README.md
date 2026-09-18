# Crop and rotation qualification — Capture One 16.8.5.30

This report records the original geometry milestone. The subsequent [corrected-lens extension](lens/README.md) qualifies nonzero distortion with native bounds and supersedes the distortion rejection below; the subsequent [perspective and movement extension](perspective/README.md) covers existing keystone and tilt/shift. Other exclusions remain.

Scope: managed clones in one Session, sequential calls, no UI edits or competing exports. Crop and absolute rotation only; existing color/layers/lens settings remain intact. Photographer acceptance and separate-shoot composition evaluation remain pending. Distribution gates in [release validation](../../RELEASE_VALIDATION.md) remain unchanged.

## Evidence

The [summary](summary.json) identifies the runtime, fixture, binaries, handler, harnesses, and results. [Native probe observations](probe.jsonl) establish rotated-canvas coordinates, automatic crop recentering/shrinkage during rotation, and orientation handling. [Packaged workflow observations](live.jsonl) and the [geometry-write journal excerpt](journal.jsonl) cover applied/read-back geometry, previews, source preservation, and context cleanup. No RAWs or exported photographs are included.

The summary records 448/448 offline assertions, shared contract/archive checks, 19/19 CLI and 10/10 MCP steps, and passing geometry and proposal-sidecar checks. [Recovery event excerpts](recovery-events.jsonl) retain fault dispatch, blocked writes, status reconciliation and case results; the [recovery journal excerpt](recovery-journal.jsonl) retains all snapshots of the four faulted operations. Original transcript hashes and excerpt counts are recorded in the summary. Duplicate console logs and generated review sidecars are omitted.

The first probe attempts stopped on harness version-property and missing-value parsing errors before geometry writes. The first integrated run exposed an exact-list tonal precondition comparison mismatch before geometry setters. The handler now compares coerced numeric values using the established tonal tolerances. The [failed operation and reconciliation](initial-failure.json) record geometry observations after restart without claiming historical success.

An expanded harness initially iterated native crop-ratio object references instead of fetching the list values. It stopped before the preset setter with `-1700`; its fixture record was reconciled after restart and the clone retained. The harness now fetches the values before iteration. This is a probe correction, not a retried editing command.

Scratch archives, logs, exported previews and disposable test Sessions were removed after qualification at the user's request. Paths in retained observations identify historical test locations, not files expected to remain available. The source RAW was preserved.

## Coordinate and support limits

- Native crop is `{centerX, centerY, width, height}` in the oriented, rotated canvas; origin is bottom left. Positive rotation is clockwise in the rendered image. Rotating moves the canvas center and can shrink an existing crop. The handler applies rotation, then the requested final crop, and verifies both.
- A selected 3:2 UI crop preset remained intact while an explicit 3:4 rectangle was applied and rendered. The rectangle controls the output ratio in the retained probe; the API does not change the preset selection.
- Parent image dimensions and default crop sizes differ by one or two pixels in the retained fixture. Bounds and readback allow two pixels; native rounding is returned to the caller.
- The usable rectangle is conservative: centered inside the rotated image, preserving the oriented source aspect ratio. Valid corner regions outside that rectangle are excluded. Native `maximum crop ... apply false` is recorded as read-only diagnostic data; it is not treated as permission to write arbitrary bounds.
- Orientation values 0, 90, 180, and 270 are read and preserved. Production does not write orientation, flips, keystone, or lens correction settings. Existing nonzero perspective/distortion/shift, flips, and crop-outside-image require manual review for geometry editing and context mapping.
- `fullFrame` means the maximum conservative context at the current rotation, rendered on a temporary managed clone. It does not restore hidden triangles beyond valid bounds. A successful response identifies both source and temporary rendered clone; the latter has been deleted. Failures retain the clone for inspection.
- Preview coordinates map to the rendered crop in the current canvas using the README formula. They are not sensor coordinates or reusable after changing rotation.
- The geometry token includes crop, rotation, orientation, dimensions, aspect-ratio selection, modeled lens/perspective context, and the tonal hash. It is not a fingerprint of every layer, mask, curve, or render-affecting setting. Exclusive use remains required.
- Fixture coverage is one Canon EOS R6m2 CR3, including managed variants oriented in all four directions. This is not evidence for every camera/lens/RAW combination. Technical test crops are not photographer-approved compositions.

## Reproduce

```sh
swift build
swift run CaptureOneCoreTests
python3 Tests/contract_test.py
# Zero open documents; use an existing local RAW. Each run gets a fresh evidence directory.
export C1_TEST_RAW_FIXTURE=/path/to/fixture.CR3
python3 probes/geometry/probe.py "$C1_TEST_RAW_FIXTURE" /private/tmp/new-probe-evidence
make archive
caffeinate -i python3 Tests/release_integration_test.py dist/c1-v0.1.0-macos-arm64.tar.gz --suites cli mcp geometry
```

The packaged runner exercises existing tonal CLI/MCP workflows followed by geometry, with build-tree resource fallback hidden. Geometry tests cover 3:2 and 3:4 ratios, signed rotations, boundary angles, off-center rectangles, context previews, orientation, baseline restoration, proposal sidecars, stale preconditions, and unchanged source/RAW checksums. Offline fault tests cover dispatch conflicts, partial writes, timeouts/lost replies, readback mismatch, preview geometry races, blocked subsequent writes, restart reconciliation, and invalid old references. Real geometry timeout recovery is separately tracked in the summary when exercised.
