# Recovery diagnosis: quit stalls and changing native IDs

Focused investigation on **2026-09-16 local time**, Capture One **16.8.5.30**, macOS **26.6.2 (25G83)**. Full recovery qualification was not repeated during this investigation and remained incomplete at its conclusion. These probes used fresh disposable Sessions, completed mutations, successful previews, and explicit process restarts. They did not inject Apple Event timeouts or kill an MCP client. A [subsequent four-case campaign](../../release/recovery-2026-09-17/README.md) passed process-termination recovery on 2026-09-17; graceful quit remains unqualified.

Two independent problems are supported by the evidence: the application stalls while handling native quit, including with zero documents; Sessions beneath the `/tmp` alias accumulate duplicate records for the same RAW across restarts. The original visible-ID loss was **not reproduced** in these shorter probes, so its precise trigger remains unresolved.

## Quit stall

The [2026-09-17 follow-up summary](graceful-quit-summary.json) records immediate native quit succeeding twice, native quit after 15 seconds stalling twice, and one user-reported manual quit with verified process exit and termination logs. The manual run's longer uptime prevents attributing the difference solely to the UI versus scripting path.

**This optional investigation is closed.** Normal CLI/MCP editing does not quit Capture One. Shutdown modes belong to explicitly invoked recovery tests; users control shutdown in normal workflows. The qualified SIGTERM recovery path is sufficient for the current scope, and no automatic graceful-quit feature or additional Accessibility access is required.

Native `quit` stalled with an empty application before any new fixture was created. It also stalled after closing a fresh Session outside `/tmp`, whose database had one image and four folder records. `silently quit` stalled in that same clean control. Sending quit with `ignoring application responses` returned successfully to the sender, but the application remained alive after 12 seconds. A successful send is therefore insufficient evidence of shutdown.

The four [retained main-thread samples](empty-quit-sample-main-thread.txt) show the Apple Event script handler inside `NSApplication terminate:` / `_shouldTerminate`, waiting in a nested event loop. Application logs show camera-service shutdown, without completion of normal application termination. This localizes the stall to the application termination path; it does not identify the internal reason or establish that a dialog is present. The same failure outside `/tmp` shows duplicate fixture records are not required for the quit stall. Inhibited idle sleep did not prevent the fresh-fixture failures.

SIGTERM ended the verified application process after its owned Session had closed and zero documents remained. **The shutdown modes must remain distinct:** direct SIGTERM generally exited in about 3.3 seconds but the next launch logged `Previous run termination was Abnormal`. SIGTERM sent after an already-stalled native quit reached `Initiating Capture One Termination Procedure` and was followed by a `Normal` label in the observed cases. Both can log `ENDED`; that message alone does not establish graceful shutdown. See the [filtered application log](diagnostic-shutdown-excerpt.log), [empty-app quit](empty-quit.json), and [no-reply quit](async-quit.json). No SIGKILL was sent to Capture One.

Direct SIGTERM is demonstrated here only as a deliberate process-end diagnostic on closed disposable fixtures. It is not a qualified replacement for graceful quit or an automatic fallback for user documents.

## Native-ID investigation

The previously failed Session at `/private/tmp/c1-recovery-1ujzomvx/recovery` was inspected read-only and was not reopened. Its [database snapshot](retained-forensics.json) contains six records for the same RAW/image UUID, attached to different folder records spelling `Capture`, plus one exported JPEG. Its three sidecar variant UUIDs match duplicate image records, but not the currently visible native IDs `33`, `34`, `35`, which have different UUIDs. The earlier visible inventory was `1`, `12`, `18`, `32`. This was more than a harmless renumbering: the visible count also changed.

SQLite `quick_check` returned `ok`; that establishes structural database integrity, not consistency of Capture One's image/variant relationships. The [original restart log](prior-shutdown-excerpt.log) includes an image with no path and a dummy-path substitution, plus warnings about variants that are not alive. These observations make record duplication/reconstruction a plausible contributor to the ID change. They do not establish causation or which operation triggered reconstruction. Private database exposure columns are not used to infer adjustment preservation; the probe compares all five fields through public `c1 get` responses.

The fresh controls isolate the path-related duplication without uncertain writes. All rows below used direct SIGTERM only after closing the owned fixture. Counts come from successive **closed-Session snapshots before each process restart**; the snapshots are not the final post-reopen database state.

| Fixture path and exercise | Restart cycles | RAW image-record counts | Folder-record counts | Visible IDs and adjustments across each restart |
|---|---:|---|---|---|
| Outside `/tmp`, clone/edit | 2 | 1 → 1 | 4 → 4 | Preserved |
| `/private/tmp`, clone/edit | 3 | 1 → 3 → 4 | 11 → 23 → 35 | Preserved |
| `/private/tmp`, clone/edit + preview | 3 | 1 → 3 → 4 | 11 → 23 → 39 | Preserved |
| `/private/tmp`, clone/delete + preview | 3 | 1 → 3 → 4 | 11 → 23 → 39 | Preserved |
| `/tmp` spelling throughout, clone/delete + preview | 3 | 1 → 2 → 3 | 4 → 12 → 24 | Preserved |
| Outside `/tmp`, clone/delete + preview | 3 | 1 → 1 → 1 | 4 → 4 → 6 | Preserved |

In the final control, the extra image was `preview.jpg`, with its two output-folder records; the RAW was not duplicated. Source exposure `0`, initial clone `0.375`, and preview clone `0.625` survived every restart. The scratch clone at `0.125` was explicitly deleted before preview, using its managed reference. The compared inventory was the Capture collection, excluding the exported JPEG.

For `/private/tmp` fixtures, native parent-image paths were returned as `/tmp/...`. Starting with `/tmp` avoided initial duplication but did not prevent it after reopening. Path alias handling is therefore implicated; the exact internal canonicalization step is unproven. Moving the next fixture outside this alias removes a demonstrated source of duplicate records. The controls do **not** prove that native IDs are always stable there or that the original fault sequence will pass.

## Changes adopted for recovery qualification

The following recommendations from the investigation were implemented before the passing 2026-09-17 campaign:

1. Create the disposable Session under a path without symlink aliases, such as the checkout's `.build/recovery-fixtures`, and verify native image paths before fault injection. Keep the preserved source RAW elsewhere. Capture pre/post-restart inventory and closed-fixture diagnostics so new duplication is visible immediately.
2. Keep native quit failure visible. If a deliberate SIGTERM mode is added, require the exact owned Session to be closed, zero documents, the same verified PID, observed process exit, and a different PID on reopen. Record it as a distinct restart mode; do not silently downgrade a graceful-quit test to process termination. Retain samples on timeout and stop without further application calls.
3. Keep native-ID/count preservation, stale-reference rejection, write blocking, and explicit reconciliation assertions unchanged. Never automatically adopt a different ID or retry an uncertain mutation. If ID loss recurs outside `/tmp`, preserve that fixture and stop for comparison.
4. Only then repeat the full packaged recovery sequence, including preview timeout and MCP process death. Report a process-termination campaign separately from graceful-quit reliability.

The production runtime and full recovery harness were not changed during these diagnostic runs. The [diagnostic probe](../../../Tests/recovery_diagnostic_probe.py) makes the bounded controls repeatable. No main Catalog or user editing document was used. All ten checked source/copied RAW files matched SHA-256 `2505287a24868a162c94bc879303a76f1e76b7ccb2bba4cacfdfeb4a33c4b868` before cleanup. The [cleanup record](cleanup-2026-09-17.json) identifies disposable copies and scratch evidence removed after qualification. The source RAW, original failed Session, and focused repository evidence remain preserved.

Follow-up on 2026-09-17: the [recovery harness](../../../Tests/recovery_integration_test.py) now implements the fixture-path and explicit shutdown-mode controls above, with read-only snapshots, failure-safe cleanup, and an additional ID/count/path check before reconciliation. The original preservation assertions remain. [Offline harness tests](../../../Tests/recovery_harness_test.py) cover shutdown guards and preservation failures; `make check` runs them. The subsequent [live campaign](../../release/recovery-2026-09-17/README.md) passed all four cases with explicit SIGTERM, preserved native IDs, and retained one RAW record in every closed/terminated snapshot. The production runtime is unchanged. See [current invocation and settings](../../RELEASE_VALIDATION.md#reproduce-packaged-live-recovery-qualification).

## Evidence and reproduction

[summary.json](summary.json) identifies every case, historical fixture path, payload hash, database snapshot, and restart result. Case directories retain event streams and read-only database extracts. Redundant scratch copies, disposable fixture databases/RAW copies, and full process samples were removed during authorized cleanup; full sample hashes and retained excerpt paths remain in the summary. The packaged CLI hash was `8eac889a502381e0adf95e678807aee9adbeb5c59d9026d871c0f553b0664df1` except the first `nonalias-normal` control, which used the local release executable identified in its environment record.

The final live probe source is retained as [tested-probe.py](tested-probe.py), SHA-256 `3f5f688b8869c3bfa0a31cc400fe0339b05f73359b15657c5b391991741a9b98`. Earlier cases preceded incremental diagnostic instrumentation; their available metadata is retained without attributing this final script hash to them. The current probe additionally guards cleanup after incomplete restart and preserves quit failure evidence if sampling fails; these failure paths were checked offline. This change was not followed by another live campaign.

Run `python3 -B Tests/recovery_diagnostic_probe_test.py` for the [four offline failure-path checks](../../../Tests/recovery_diagnostic_probe_test.py). They verify reply timeout, process-exit timeout, sampling failure, and reopen failure preserve the error without automatic signal fallback or cleanup Apple Events after an incomplete restart. [Results](offline-checks.log) passed; JSON, links, source syntax, recorded hashes, and all 17 preservation observations were also checked.

To reproduce the final focused control, close all documents first, use the exact packaged candidate, and provide new evidence storage:

```sh
C1_TEST_BIN=/absolute/path/to/extracted/bin/c1 \
C1_TEST_RAW_FIXTURE=/absolute/path/to/preserved.CR3 \
caffeinate -i python3 -B Tests/recovery_diagnostic_probe.py \
  --parent "$PWD/.build/recovery-probes" \
  --evidence /private/tmp/new-recovery-diagnostic-evidence \
  --quit-command sigterm --cycles 3 --delete-cycle 1 --preview-cycle 1
```

This explicitly requests process termination after closing each disposable fixture. `--quit-command quit` and `--quit-command 'silently quit'` instead stop on a stall without a force fallback. Probe completion means observations were collected; inspect its preservation flags before drawing conclusions. Live suites must remain sequential and exclusive.
