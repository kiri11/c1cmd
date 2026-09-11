# v0.1 release validation

This is the current release authority. The M0 report preserves historical feasibility evidence; it does not override the decision here.

## Current decision (2026-09-09 UTC)

**The scoped runtime-recovery and documentation blockers are closed. GO for the documented runtime candidate; HOLD on general binary publication until the distribution gates below are resolved.** The supported candidate is Capture One 16.8.5.30 on Apple Silicon: exactly one open document, Session-only writes/preview, managed working clones, sequential calls, no UI edits, document switching or competing exports. Catalog inspection is read-only.

The original binary-distribution gates remain open: fresh-user downloaded-artifact launch, Automation consent through Terminal and an intended MCP client, and an explicit decision on Developer ID signing/notarization. Current archives are ad-hoc signed. This recovery/documentation work does not silently waive those gates or qualify other application builds, Intel, or every macOS deployment target.

## Disposition of historical gates

| Historical question | Current implementation and decision |
|---|---|
| Document lifetime | Canonical database file identity plus Capture One PID/launch and parent-image validation. App restart invalidates references; no automatic rebinding. Same-file reopening within one launch is unsupported and cannot be reliably detected. Replacement has offline tests; arbitrary live replacement/copy workflows are not qualified. |
| Integrated journal recovery | Durable pre-dispatch records, unresolved-operation write block, explicit reconciliation after the old app process ends. `reconciled` records observations, never historical success. Packaged live fault evidence is recorded below. |
| Preview polling versus callbacks | Accept unique-directory polling only within the sole-operator scope: explicit variant/recipe, fresh operation directory, stable size, JPEG end marker, complete ImageIO decode, matching five-field state before/after. Never infer completion from queue disappearance, history or an old file. Production does not install callbacks; callback ownership/coexistence is deferred. |
| Preview identity limits | Association relies on exclusive output ownership and the restricted workflow, not independent production reconciliation of the native job ID. Five fields are not a full render fingerprint. Recipe settings use exact-build tested values; not every recipe property is read back before every export. General export and competing operators remain unqualified. |
| Catalog preview | Rejected: preview configures recipe/output state. Read-only Catalog support does not include preview. |
| Signing | Packaging is ad-hoc signed, not Developer ID signed/notarized. Resolve the distribution gates above separately. |

## Retained live recovery results (2026-09-09 UTC)

[Run history and limitations](release/recovery-2026-09-09/README.md), [machine-readable summary](release/recovery-2026-09-09/summary.json), [passing run](release/recovery-2026-09-09/run-4/events.jsonl), [journal](release/recovery-2026-09-09/run-4/journal.jsonl), [exact harness](../Tests/recovery_integration_test.py) and [production patch](release/recovery-2026-09-09/run-4/source.patch).

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

Close all documents and allow exclusive use of Capture One. The harness refuses to start with an open document or a different app build. It copies a local RAW into a fresh `/private/tmp` Session; the RAW and uncertain clones are retained outside the repository. Only managed clones are adjusted. It pauses/resumes the verified app PID with an independent 150-second watchdog, kills its own MCP child after export output appears, and normally restarts the app between cases. Do not run another test suite or build concurrently.

```sh
make archive
export C1_TEST_RAW_FIXTURE=/path/to/local.CR3
caffeinate -i python3 Tests/recovery_integration_test.py \
  dist/c1-v0.1.0-macos-arm64.tar.gz \
  docs/release/recovery-YYYY-MM-DD/run-1
```

The `caffeinate` wrapper inhibits idle sleep for the test duration; a suspended machine can invalidate timeout timing. Use a new evidence directory for each run. Failures are retained, not overwritten or automatically retried. If a run fails with unresolved work, inspect its journal and end the old app process before manual reconciliation. The harness restores the build resource bundle and closes only its own Session; it does not delete uncertain clones.

The harness verifies archive checksum and records executable/handler hashes, source commit, harness hash, OS, Swift, build and fixture hash. It hides the build-tree resource bundle, runs extracted binaries, and saves raw command/error responses plus journal/provenance snapshots. No RAW or JPEG is committed. A pause immediately after a pending record races handler execution: an actual `-1712` proves the timeout path, but cannot identify which individual Apple Event was in flight or prove that a delayed setter executed. Output creation before killing MCP proves export dispatch and a lost reply, not that rendering remained outstanding at the instant of death. Those claims remain distinct from the historical M0 delayed-setter probe.


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
