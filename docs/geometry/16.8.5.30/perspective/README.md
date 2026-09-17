# Existing keystone and lens movements — Capture One 16.8.5.30

**PASS for regular packaged workflows on the stated build and fixtures.** Real timeout testing is now opt-in; the new six-case fault campaign was intentionally not completed. This extends crop/rotation operations to preserve existing corrections; no keystone, tilt, shift, or lens-profile setters are exposed.

## Results

- **800/800 offline assertions**, **24 offline recovery-harness tests**, 19 CLI steps, 10 MCP steps, and all packaged geometry, distortion, perspective/movement, Catalog, existing-variant, and inventory suites passed.
- **Eight perspective/movement cases** passed. Six preview-coordinate comparisons sampled 5,329 pixels each, with mean absolute channel errors of **2.12–2.66 / 255** against a threshold of 8. Original variants and RAW bytes were preserved.
- Three real timeout recoveries passed in the final campaign: tonal, standard geometry, and distortion-only geometry. At the user's request, the combined-correction pause was cancelled; its already-dispatched edit completed successfully. There were **zero unresolved operations and zero open documents** afterward. Combined-correction timeout recovery and the final two export-fault cases are **not claimed as qualified on this candidate**.

The [summary](summary.json), [workflow events](live-events.jsonl), [mutation journal](mutation-journal.jsonl), and [native probe](native-probe.jsonl) retain the regular results. [Recovery events](recovery-events.jsonl), [fault journal](recovery-journal.jsonl), and [prior attempts](prior-attempts.json) distinguish passes, the launch failure, and the user-requested stop. The [initial qualification log](initial-qualification.log) and [recovery rerun log](recovery.log) retain their actual outcomes; neither is relabeled a completed full fault campaign.

## Behavior

Native `maximum crop ... apply false` reports a rectangle in the corrected canvas. With keystone, applying it can shrink the crop; `apply true` can instead choose a different center. Ratio requests allow Capture One to normalize a proposed centered fit, then require positive dimensions, containment within that proposal (two-pixel tolerance), the requested ratio, unchanged correction context, and matching readback. In the retained vertical-keystone probe at 5° rotation, a reported 5,372-pixel rectangle became 5,292 pixels wide when assigned. Explicit crop requests keep strict two-pixel tolerance. Rotation-only returns the native automatic crop without reapplying it or rejecting it against the approximate maximum rectangle.

New rotations with corrections and ratio fits with perspective/movements cannot be predicted by a dry run. The pending journal retains the request before dispatch and the concrete target once observed. All uncertain mutations retain the normal restart/reconciliation block. Baseline restoration requires unchanged correction context.

## Fixture and limits

The source is the preserved Canon EOS R6m2 / EF 35mm f/1.4L II USM CR3, copied into disposable Sessions. Keystone uses its original profile. Tilt/shift tests deliberately select the installed `Phase One 45mm TS f/3.5` profile on an owned clone, then set movement metadata. This validates coordinate handling and preservation of native settings; it does not validate that profile's optical accuracy on the Canon image or replace a real tilt/shift capture campaign.

The matrix covers vertical/horizontal keystone, combined skew/aspect, correction amounts, all four orientations, both hide-distorted-area states, signed rotations through ±45°, lens tilt/direction and shift/direction/X/Y, distortion combinations, previews, baseline restore, and source/RAW preservation. Flips, crop-outside-image, other builds, Catalog fault recovery, simultaneous operators, and photographer composition acceptance remain outside scope.

## Reproduction

```sh
make qualify C1_TEST_RAW_FIXTURE=/absolute/path/to/fixture.CR3 \
  EVIDENCE_DIR=/absolute/new/evidence
# Optional recovery testing against the existing archive:
make qualify-recovery C1_TEST_RAW_FIXTURE=/absolute/path/to/fixture.CR3 \
  C1_RECOVERY_SHUTDOWN_MODE=sigterm EVIDENCE_DIR=/absolute/new/recovery
```

The relocated archive runner includes `Tests/perspective_geometry_integration_test.py`. Recovery adds a real timeout with combined keystone, tilt/shift, and distortion, retaining corrections and blocking writes until explicit reconciliation after restart.

## Qualification sequence

The first full packaged run passed all regular suites, then stopped during the third recovery case when Launch Services returned `-600` after the old process exited. The owned Session was reopened and its pending operation reconciled without retry; native identities, correction settings, source state, and RAW bytes were preserved. The harness now verifies that no Capture One process is running before using `open -n` to avoid the stale registration. Unknown process state or another running instance stops the launch. A separate recovery rerun against the unchanged archive passed the first three timeout cases. The user then requested excluding slow timeouts; the active pause was cancelled safely and the remaining fault cases were not completed. The earlier launch failure remains evidence rather than being relabeled a pass.

Two development probes also stopped and were reconciled: an unrecognized profile name, and a rotation-only crop rejected against the native maximum rectangle. The latter established the need to retain Capture One's observed automatic crop without reapplying it. Neither uncertain mutation was retried.
