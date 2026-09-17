# Keystone control qualification — Capture One 16.8.5.30

Regular validation passed: **844/844 Swift assertions**, **25 recovery-harness
tests**, shared CLI/MCP contract/profile checks, all **nine packaged live
suites**, **13 keystone control cases**, and **two additional keystone-write
cases with distortion and tilt/shift**. The resumed restored preview had mean
absolute channel error **0.01165/255**, below the **0.1/255** threshold, with
exact reported geometry and tonal restoration. All live suites used the
relocated archive with build resource fallback hidden. The optional real-fault campaign was stopped on user request after two
completed cases; it is not a full recovery qualification.

Contract 1.8.0 extends `geometry_set` with an optional `keystone` object and CLI
`geometry set` with `--keystone-amount`, `--keystone-vertical`,
`--keystone-horizontal`, `--keystone-skew`, and `--keystone-aspect`.
Controls are absolute, omitted controls are preserved, and native IDs alone
cannot authorize writes. Existing editing references and managed clones use the
same document, identity, concurrency, journal, and recovery guards.

The live native ranges are amount 10–120 (integer), vertical/horizontal −75–75,
skew −45–45, and aspect −50–100. Native scripting rejects vertical −100 and
skew −100 with error −50; those development probes were retained and reconciled
after application restart, without retrying the failed mutations. Final request
validation rejects those values before dispatch. Amount/aspect behavior is also
described in the [Capture One documentation](https://support.captureone.com/hc/en-us/articles/360002588058-Keystone-correction).

The handler checks the full geometry/tonal snapshot before setters, applies
keystone and rotation, obtains fresh native bounds, and then fits or validates a
requested crop. No crop request retains Capture One's observed crop. All five
keystone controls are verified along with crop/rotation and preserved lens/tonal
settings. Keystone changes cannot predict a crop in a dry run. Baseline restore
applies the saved keystone, rotation, and crop, with unchanged lens/orientation
context and a fresh geometry token.

`Tests/keystone_integration_test.py` exercises both endpoints of each control,
fractional values, partial-field preservation, combined keystone/rotation/ratio
fitting, stale-token and dry-run rejection, before/after previews, restored preview
with mean absolute channel error below 0.1/255, journal intent, baseline diff/restore, unchanged tonal state,
unchanged RAW bytes, and one existing native variant throughout. Its MCP client
uses the composition profile. `Tests/existing_variant_integration_test.py` adds
keystone to its Session and explicitly enabled referenced-Catalog workflow.

The optional recovery harness adds a real 120-second keystone Apple Event timeout.
It runs only on explicit user request, including for recovery-sensitive changes. It
requires write blocking, application restart, explicit reconciliation, expired
references, and preserved native IDs/RAW/source state. Reconciliation reports
observations and may see a partial correction; it does not establish which
setters completed historically. The offline harness tests cover those possible
observations without substituting for live timeout coverage.

This qualification uses a copied Canon CR3 with the Canon EF 35mm f/1.4L II USM
profile on one machine. It is not a multi-camera/lens optical-quality campaign.
No automatic line detection, guide-point editing, keystone acceptance judgment,
Catalog-stored-original support, or Catalog fault-recovery qualification is
claimed. Real fault injection uses managed Session clones; existing editing
references have mocked failure coverage and successful live workflow coverage. Other Capture One builds remain unqualified.

The initial packaged run stopped on an overly strict pixel-hash equality check
for the restored preview after all 13 control cases passed. Two further exports
of the untouched restored variant also produced different pixel hashes, with
mean channel differences 0.01099 and 0.01292/255; the baseline-to-restored error
was 0.01197/255. The harness now checks exact reported geometry/tonal restoration
plus a strict 0.1/255 mean pixel-error threshold. The native binaries and handler
were unchanged; the affected and remaining suites passed when rerun from that archive.

## Optional recovery campaign and cancellation

The tonal and standard-geometry timeout cases passed with explicit SIGTERM
shutdown. At the user's request, the campaign was stopped during the corrected-
lens pause. The harness resumed Capture One and stopped its watchdog/child. The
already-dispatched operation was subsequently reconciled after a restart of the
owned Session, without retrying or undoing it. The original variant and RAW bytes
were preserved, with zero unresolved operations and zero open documents afterward.
Perspective/keystone timeout, preview timeout, and MCP-death cases were not run.
No complete real-fault qualification is claimed for this candidate.

Timeout/process-death tests are **optional and require an explicit user request**.
Recovery-sensitive changes or release checkpoints do not automatically trigger
them. Normal validation retains mocked failure coverage and regular packaged
live workflows. See the policy in [AGENTS.md](../../../../AGENTS.md) and
[release validation](../../../RELEASE_VALIDATION.md).

[Summary](summary.json), [keystone results](live-results.json),
[existing-variant results](existing-results.json),
[corrected-geometry writes](corrected-geometry-events.jsonl),
[export repeatability](export-repeatability.json),
[initial qualification log](qualification-initial.log),
[resumed qualification log](qualification-resumed.log),
[recovery journal](recovery-journal.jsonl), and
[cancellation reconciliation](cancellation-reconciliation.json) retain the evidence.
