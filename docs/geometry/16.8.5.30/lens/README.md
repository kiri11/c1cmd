# Corrected-lens crop and rotation — Capture One 16.8.5.30

This report describes the committed distortion-only milestone. The [perspective and movement extension](../perspective/README.md) supersedes its tilt/shift and keystone exclusions.

**PASS for the documented Session scope on Capture One 16.8.5.30.** The final `make qualify` campaign exited zero, including all packaged functional suites and five real recovery cases with explicit SIGTERM shutdown. It finished with zero open documents. Original variant state and both source/copied RAW hashes remained unchanged.

## Evidence

The [summary](summary.json) identifies the payload, source/harness hashes, fixture, timings, and scope. [Native probe observations](native-probe.jsonl), [packaged live events](live-events.jsonl), and the [geometry journal](mutation-journal.jsonl) retain the coordinate and preservation evidence. No RAWs or exported photographs are committed.

| Check | Result |
|---|---|
| Offline checks | 728/728 Swift assertions; CLI/MCP schemas/profiles; 22 recovery-harness tests |
| Relocated package | CLI 19 steps; MCP 10 steps; standard geometry, Catalog, existing-variant, and inventory suites passed with build resources hidden |
| Corrected-lens workflows | Six cases: distortion 50/100, all four orientations, hide-distorted-areas on/off, signed rotations including ±45°, 3:2/3:4 crops, rotation-only, off-center crops, context cleanup, baseline restore |
| Preview mapping | Four comparisons, each sampling 5,329 pixels; mean absolute channel error 2.23–2.82 out of 255 (limit 8), allowing JPEG/resampling differences |
| Recovery | Real tonal, standard geometry, corrected geometry, and preview timeouts; MCP process death after export dispatch; all five passed |

The [recovery events](recovery-events.jsonl) and [fault journal](recovery-journal.jsonl) show that writes stayed blocked through restart until explicit reconciliation, old references expired, and native IDs/counts/parent paths were preserved. The corrected-lens pending record contained distortion 100 and the requested 3°/3:2 operation before a resolved target existed. Reconciliation observed state without retrying the uncertain mutation; a new reference could then edit successfully. The external pause races handler execution and does not identify which individual Apple Event timed out.

The corrected-lens suite took about 160 seconds; recovery took about 546 seconds. The [qualification log](qualification.log) retains the complete final run. Earlier [attempts](prior-attempts.json) remain failures: a negative-number harness argument error, an overly strict one-pixel rounding assertion, and a native shift-fixture setter rejected by this non-shift lens profile. The shift operation was reconciled after restart without retry; its observed shift and RAW bytes were unchanged. Native shift mutation is not claimed as tested; rejection of all tilt/shift fields is covered offline.

## Coordinate contract

Distortion correction changes the native canvas: on the retained Canon fixture, the zero-rotation center changed from `(2999, 2000)` at distortion 0 to `(3002, 2000)` at distortion 100. Disabling “hide distorted areas” changed it again. Intrinsic RAW dimensions alone therefore cannot locate the corrected crop.

For nonzero distortion, `get.geometryUsableBounds` uses `maximum crop ... apply false` at the currently observed rotation. The qualification checks both centered and off-center crops. `geometry_set` obtains new native bounds after rotation inside the journaled handler; it then fits an aspect ratio or validates the supplied rectangle. Rotation-only requests preserve Capture One's automatic crop adjustment. An explicit crop selected from an old rotation is not automatically remapped: inspect a fresh preview after rotation and use a fresh geometry token.

The pending journal retains `requestedGeometry` before dispatch; the concrete `intendedGeometry` is appended once native bounds and the target are known. Failure anywhere after dispatch retains the normal unresolved-write block. In particular, an out-of-bounds explicit crop after rotation may leave the rotation applied. No automatic undo/retry occurs. Recovery observes the variant after application restart and invalidates old references.

Dry runs can validate crops at the current rotation. A corrected-lens dry run with a new rotation is rejected because determining its bounds requires a native mutation. Baseline restoration uses the exact previously observed crop/rotation only when lens/orientation context still matches.

## Support limits

- Distortion values 0...100; correction amount, profile, hide-distorted-areas, tonal edits, and other context remain unchanged.
- Orientations 0/90/180/270 and rotations -45...45. Two-pixel native crop rounding tolerance remains unchanged.
- Lens tilt/shift, perspective corrections, flips, crop-outside-image, and other builds remain outside support.
- The fixture is one copied Canon EOS R6 Mark II CR3 with the native Canon EF 35mm f/1.4L II USM profile. This is not a 70–200 mm, multi-camera, or all-profile qualification. Native per-image bounds are queried rather than extrapolated from that lens's distortion amount.
- Corrected-lens live coverage uses disposable Sessions. Referenced-Catalog support retains its experimental opt-in boundary; this campaign does not qualify Catalog fault recovery.
- Pixel comparisons validate crop-to-preview mapping, not aesthetic composition quality.

## Reproduce

With zero open documents and exclusive Capture One use:

```sh
C1_TEST_RAW_FIXTURE=/absolute/path/to/preserved.CR3 \
C1_LENS_EVIDENCE=/absolute/path/to/new-evidence \
python3 -B Tests/lens_geometry_integration_test.py

make qualify-full C1_TEST_RAW_FIXTURE=/absolute/path/to/preserved.CR3 \
  C1_RECOVERY_SHUTDOWN_MODE=sigterm EVIDENCE_DIR=/absolute/path/to/new-campaign
```

The package runner tests the extracted CLI/MCP with build resources hidden. The recovery suite includes uncorrected and corrected geometry timeouts, tonal timeout, preview timeout, and MCP process death. It preserves the real Apple Event timeout duration and uses explicitly selected process termination; native graceful quit remains separately unqualified.
