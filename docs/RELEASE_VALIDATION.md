# v0.1 release validation

This is the current release authority. The M0 report preserves historical feasibility evidence; it does not override the decision here.

## Corrected-lens development candidate (2026-09-17 UTC)

Contract **1.6.0** permits crop and rotation with preserved lens distortion correction in 0...100 on Capture One **16.8.5.30**. Corrected bounds come from native `maximum crop ... apply false`; new rotations obtain fresh bounds inside the journaled operation. `requestedGeometry` records intent before those bounds are known. A corrected-lens rotation dry run is rejected; uncertain failures retain the existing write block and restart/reconciliation rules.

The [corrected-lens report](geometry/16.8.5.30/lens/README.md) covers six packaged cases, all four orientations, both hide-distorted-areas settings, signed rotations through ±45 degrees, off-center preview-coordinate checks, baseline restoration, and unchanged source/RAW bytes. **728/728 offline assertions** and **22 recovery-harness tests** passed, followed by extracted CLI, MCP, standard geometry, corrected-lens, Catalog, existing-variant, and inventory suites with build resource fallback hidden.

**All five recovery cases passed** with explicit SIGTERM shutdown: real tonal timeout, standard geometry timeout, corrected-lens geometry timeout, preview timeout, and MCP process death. The full `make qualify` invocation exited zero and finished with zero open documents, preserving native IDs, source state, corrections, and RAW bytes. The corrected-lens fixture is a single Canon CR3 with the Canon EF 35mm f/1.4L II USM profile, not a 70–200 mm or multi-lens campaign. Tilt/shift, perspective, flips, crop-outside-image, other application builds, native graceful quit, Catalog fault recovery, and general binary-distribution gates remain outside this extension. This candidate supersedes the runtime payloads below; earlier failed attempts remain recorded in its report.

## Inventory and diagnostics development candidate (2026-09-16 UTC)

Contract **1.5.0** adds `request_status` (20 MCP tools), native rating filtering on qualified Sessions, bounded inventory with a conservative Catalog fallback, background diagnostics, CLI/MCP progress, and read cancellation/deadlines between Apple Events. Mutation journaling and restart-based reconciliation remain mandatory.

The [inventory qualification report](inventory/16.8.5.30/README.md) records **679/679 offline assertions**, relocated archive checks, and passing packaged CLI, MCP, geometry, Catalog, existing-variant, and inventory suites on Capture One **16.8.5.30**. It also records native-predicate equivalence, status access while inventory occupies the MCP executor, and cancellation without partial results. Sparse-filter timings improved substantially in the disposable fixture; dense scans retained validation overhead. The measurements use variants of one RAW and do not establish performance for an entire shoot.

**All four Session recovery cases now pass with explicit SIGTERM shutdown.** The [2026-09-17 recovery report](release/recovery-2026-09-17/README.md) records real tonal/geometry Apple Event timeouts, preview timeout with eventual output, and MCP process death after export dispatch. All native-ID, count, parent-path, stale-reference, write-blocking, source-state, geometry, and RAW checks passed in a fresh fixture outside `/tmp`. This qualifies process-termination recovery on the same CLI/MCP/handler payload; graceful native quit remains unqualified. It was a separate recovery campaign, not a rerun of the entire `make qualify` command.

The earlier attempt remains a failure: native quit stalled, preview recovery lost native IDs after a continued restart, and MCP process-death coverage was not reached. The [focused diagnosis](recovery-diagnosis/16.8.5.30/README.md) reproduced quit stalls with zero documents and duplicate RAW records beneath `/tmp`; its 17 shorter restarts preserved visible IDs. The revised harness defaults to fixtures outside `/tmp`, records an explicit shutdown mode, and rejects changed IDs before reconciliation. No duplicate RAW records or visible-ID loss occurred in the subsequent four-case pass, but the exact trigger of the earlier loss remains unresolved. No uncertain mutation was retried.

This candidate supersedes the runtime payload of the historical development entries below. Catalog-stored originals, Catalog fault qualification, simultaneous UI operators, and the original binary-distribution gates remain outside its scope. Exact hashes, failed attempts, and retained evidence are in the linked report.

## Existing-variant development candidate (2026-09-14)

Contract **1.4.0** adds `variant_edit` and `geometry_restore` (19 MCP tools). Existing variants can receive all five supported tonal adjustments and crop/rotation through a saved editing reference; cloning is optional. The photographer continues on the same variant after the agent finishes. Existing references cannot authorize deletion. Catalog edits retain the exact-path opt-in and referenced-original storage limit.

[Existing-variant validation](existing-variants/16.8.5.30/README.md) records **592/592 offline assertions**, contract/profile checks, extracted CLI/MCP/geometry/catalog regressions, and both packaged examples editing five-star variants in disposable Sessions and catalogs with no duplicates. Both fixtures ended at their saved tonal/geometry baselines with unchanged ratings and RAW checksums. The report identifies the payloads before and after the final expired-reference guard fix. Two real Session timeout cases passed on the preceding payload; the extended preview-recovery run stopped after an old native ID became absent, and MCP-client death was not reached. A full four-case recovery pass is not claimed for this extension.

The dimension calculation now uses intrinsic source-file metadata: Capture One's parent dimensions can change when its first variant rotates. No main catalog was used. Catalog-stored originals, simultaneous UI operators, and the distribution gates below remain outside this qualification.

## Retained Session release decision (2026-09-09 UTC)

**The scoped runtime-recovery and documentation blockers are closed. GO for the documented runtime candidate; HOLD on general binary publication until the distribution gates below are resolved.** The supported candidate is Capture One 16.8.5.30 on Apple Silicon: exactly one open document, Session-only writes/preview, managed working clones, sequential calls, no UI edits, document switching or competing exports. Catalog inspection is read-only by default. The opt-in development extension below has a separate scope.

The original binary-distribution gates remain open: fresh-user downloaded-artifact launch, Automation consent through Terminal and an intended MCP client, and an explicit decision on Developer ID signing/notarization. Current archives are ad-hoc signed. This recovery/documentation work does not silently waive those gates or qualify other application builds, Intel, or every macOS deployment target.

## Experimental catalog extension (2026-09-14)

`C1_CATALOG_WRITE_PATH` enables one explicitly named catalog on 16.8.5.30, for online **referenced originals only**. State preconditions, journal, app lifetime, and RAW-preservation rules still apply. Contract 1.4.0 also permits existing-variant tonal and geometry edits via saved `c1_edit_` references; cloning is optional, and deletion stays clone-only. Catalog journals are isolated inside each package and bind to the internal database identity. `writesEnabled` is exposed by doctor/document responses (introduced in contract 1.3.0).

See [catalog validation](catalog/16.8.5.30/README.md) for evidence and limits. Native catalog-stored-image import crashed during fixture setup; that storage mode remains blocked. This experimental extension does not inherit full Catalog fault qualification from the Session results below or waive distribution gates.

## Crop and rotation milestone (2026-09-11 UTC)

Contract 1.1.0 adds managed crop/rotation proposals, geometry preconditions and recovery observations, baseline differences, and crop-aware previews. The [geometry qualification report](geometry/16.8.5.30/README.md) and its machine-readable summary identify the candidate payload and new results separately from the September 9 archive below. Geometry writes are restricted to Capture One 16.8.5.30 and qualified transform combinations. Photographer evaluation on separate shoots remains pending; technical fixture checks do not establish composition quality. The distribution gates above remain open.

## Disposition of historical gates

| Historical question | Current implementation and decision |
|---|---|
| Document lifetime | Canonical database file identity plus Capture One PID/launch and parent-image validation. App restart invalidates references; no automatic rebinding. Same-file reopening within one launch is unsupported and cannot be reliably detected. Replacement has offline tests; arbitrary live replacement/copy workflows are not qualified. |
| Integrated journal recovery | Durable pre-dispatch records, unresolved-operation write block, explicit reconciliation after the old app process ends. `reconciled` records observations, never historical success. Packaged live fault evidence is recorded below. |
| Preview polling versus callbacks | Accept unique-directory polling only within the sole-operator scope: explicit variant/recipe, fresh operation directory, stable size, JPEG end marker, complete ImageIO decode, matching five-field state before/after. Never infer completion from queue disappearance, history or an old file. Production does not install callbacks; callback ownership/coexistence is deferred. |
| Preview identity limits | Association relies on exclusive output ownership and the restricted workflow, not independent production reconciliation of the native job ID. Five fields are not a full render fingerprint. Recipe settings use exact-build tested values; not every recipe property is read back before every export. General export and competing operators remain unqualified. |
| Catalog preview | Default read-only mode rejects export. Exact-path experimental opt-in permits preview of referenced originals; it configures recipe state and initializes a missing default output location. See the catalog report. |
| Signing | Packaging is ad-hoc signed, not Developer ID signed/notarized. Resolve the distribution gates above separately. |

## Retained live recovery results (2026-09-09 UTC)

[Run history and limitations](release/recovery-2026-09-09/README.md), [machine-readable summary](release/recovery-2026-09-09/summary.json), [passing run](release/recovery-2026-09-09/run-4/events.jsonl), [journal](release/recovery-2026-09-09/run-4/journal.jsonl), [current harness](../Tests/recovery_integration_test.py) and [production patch](release/recovery-2026-09-09/run-4/source.patch). The current harness also covers geometry; the historical harness hash is retained in that run's summary.

Capture One **16.8.5.30**, **macOS 26.6.2 / 25G83**, arm64, Swift **6.3.1**, Canon **EOS R6m2** CR3. Base commit `06017b9366cc2f489ddd828a60c2263794e530c7` plus the retained handler patch. The archive's executables and handler were extracted and exercised with build-tree resources hidden.

| Check | Result |
|---|---|
| Clone-ID read regression | Ten consecutive managed clone/read/delete cycles passed. |
| Real Apple Event timeout | Paused verified Capture One PID after the durable pending record; packaged CLI returned actual `-1712` and the operation ID. Target resumed; recovery path passed. This run did not demonstrate a late-applied setter. |
| Preview polling timeout | Packaged preview timed out; its owned output was subsequently observed. Output existence did not clear the unresolved write block. |
| MCP process death | Killed the actual extracted `c1-mcp` after its new output appeared, before a success journal record or tool response. Pending operation survived and recovery passed. |
| Every recovery case | Writes blocked both before restart and after restart until explicit status reconciliation. Old working reference rejected with `document-changed`; no variant creation/adoption/deletion by reconciliation. Fresh clone could be adjusted and cleanly deleted. Original five-field hash and copied RAW bytes remained unchanged. |
| Cleanup | Three uncertain test clones retained for inspection; zero documents open. Original user RAW checksum also verified unchanged. |

Tested archive SHA-256: `9a3cb184a7f27a2f88bbd1f1e68589a36bb88a33b81a9d87988f26cc75aba855`. Handler SHA-256: `bc6054052a1385d4aa42c13de294555c7eb8ee92baa9da052081566620f0feb3`. Source/copied RAW SHA-256: `2505287a24868a162c94bc879303a76f1e76b7ccb2bba4cacfdfeb4a33c4b868`. Executable hashes, exact harness hash and patch hash are retained in the summary. These identify the tested candidate; a repack with updated documentation will have a different archive checksum and must preserve/verify the runtime payload identity or be requalified.

Failed attempts are summarized in the run history; the motivating clone failure and its reconciliation are retained as a [focused excerpt](release/recovery-2026-09-09/run-2/clone-failure.json). Run 1 exposed a harness MCP parameter error. Run 2 exposed a real transient clone-reference ID read failure (`-1700`); the operation was reconciled after restart and candidate ID `8` was recorded without adoption/deletion/retry. The fix bounds retries to reads of the exact returned reference (20 attempts, 0.1-second delay); other/exhausted errors still fail closed. Run 3 was incomplete after long wall-clock gaps and an app-quit deadline. Run 4 passed in full with idle sleep inhibited. No failed run is relabeled as successful.

## Current regression verification

The same patched archive also passed the [recorded regression run](release/recovery-2026-09-09/validation.json): **331/331 offline assertions**, archive checksum/relocation and shared CLI/MCP contract checks, then **19/19 CLI** and **10/10 MCP** live integration steps through extracted binaries with build-tree resources hidden. Logs: [unit](release/recovery-2026-09-09/unit.log), [archive](release/recovery-2026-09-09/archive.log), [extracted live workflows](release/recovery-2026-09-09/release-live.log). These are the retained regression results for this runtime payload.

## Reproduce packaged live recovery qualification

Close all documents and allow exclusive use of Capture One. The harness refuses to start with an open document or a different app build. It copies a local RAW into a fresh Session under `.build/recovery-fixtures` in the checkout. Set `C1_RECOVERY_FIXTURE_PARENT` to override that parent with an absolute path outside `/tmp` and `/private/tmp`, without symlink aliases. Native image-path spelling must match the copied fixture before mutations. Sessions and uncertain clones are retained; build cleanup may remove the default fixture directory, so preserve evidence elsewhere before cleaning. Keep the source RAW outside the build tree. Only managed clones are adjusted. The harness pauses/resumes the verified app PID with an independent 150-second watchdog, kills its own MCP child after export output appears, and restarts the app between cases. Do not run another test suite or build concurrently.

```sh
make archive
export C1_TEST_RAW_FIXTURE=/path/to/local.CR3
caffeinate -i python3 Tests/recovery_integration_test.py \
  dist/c1-v0.1.0-macos-arm64.tar.gz \
  docs/release/recovery-YYYY-MM-DD/run-1
```

`C1_RECOVERY_SHUTDOWN_MODE=quit` is the default: request native quit and verify the old process exits. `C1_RECOVERY_SHUTDOWN_MODE=sigterm` explicitly selects process termination after closing the owned Session, confirming zero documents, and rechecking the verified PID. There is **no automatic fallback**. Environment, restart, case, and completion events record the mode; a SIGTERM pass is process-termination recovery evidence, not graceful-quit qualification. Capture One labeled direct SIGTERM abnormal in the diagnostic controls. Both modes require observed old-process exit before reopening and a different PID afterward.

Both settings can be passed to `make qualify`, for example `make qualify C1_RECOVERY_SHUTDOWN_MODE=sigterm EVIDENCE_DIR=/private/tmp/new-qualification` with `C1_TEST_RAW_FIXTURE` set. The evidence directory may be under `/tmp`; the Session fixture must not be.

The `caffeinate` wrapper inhibits idle sleep for the test duration; a suspended machine can invalidate timeout timing. Use a new evidence directory for each run. Failures are retained, not overwritten or automatically retried. Shutdown timeouts collect a best-effort process sample and stop. After an incomplete restart, cleanup sends no further Apple Events; it still restores the build resource bundle and retains the journal. Otherwise cleanup closes only its own Session. If a run fails with unresolved work, inspect its journal and end the old app process before manual reconciliation. No uncertain clones are deleted or adopted by cleanup.

The harness verifies archive checksum and records executable/handler hashes, source commit, harness hash, OS, Swift, build and fixture hash. It hides the build-tree resource bundle, runs extracted binaries, and saves raw command/error responses plus journal/provenance snapshots. Before/after restart inventories retain native IDs and parent paths; any change in IDs, count, or paths stops the run before reconciliation. Existing post-reconciliation identity, stale-reference, state/geometry, write-blocking, and RAW checks remain in place. Read-only database snapshots after Session close and process exit help diagnose duplicate image/folder/variant records. Snapshot failures are logged without weakening public inventory checks; private database rows never authorize writes. No RAW or JPEG is committed. A pause immediately after a pending record races handler execution: an actual `-1712` proves the timeout path, but cannot identify which individual Apple Event was in flight or prove that a delayed setter executed. Output creation before killing MCP proves export dispatch and a lost reply, not that rendering remained outstanding at the instant of death. Those claims remain distinct from the historical M0 delayed-setter probe.


## Changes under validation

- Exact canonical database path/file identity and app-launch binding; managed parent-image validation. No automatic reference rebinding across app restart.
- One-open-document guard in both Swift discovery and AppleScript dispatch.
- Pre-dispatch journaling for all write paths, durable append-only snapshots, conservative restart-based reconciliation, and operation IDs in error responses.
- Requested-field writes and a second expected-state check inside the AppleScript handler.
- Bounded reads of the exact reference returned by clone when Capture One temporarily returns `-1700`/`-1728`; clone is dispatched once, and exhausted/other errors retain the unresolved journal block.
- Unique preview output paths, complete-file polling, and variant/state association.
- Shared CLI/MCP contract and strict input validation.
- Offline fault injection, removal of live application dependency from the unit suite, resource bundle installation, archive testing.

## Simplification decisions

Removed duplicate CLI/MCP schema definitions, hand-maintained MCP input schemas, duplicated clone/baseline orchestration, source-checkout AppleScript fallbacks, and whole-journal rewriting. These mechanisms either drifted or masked deployment failures.

Keep the native baseline operation: it is useful for controlled style comparisons and now shares creation/recovery code with cloning. Keep the M0 probes and evidence as qualification history, but do not treat their broad experimental scripts as production APIs. Defer Session creation, importing, caches, callbacks, and broader adjustments; adding them would expand the safety surface without helping the current release.

The supported fields and schemas are shared. The five-field state hash is not a complete render fingerprint. Do not use it to cache or label arbitrary layered/geometry/style renders.
