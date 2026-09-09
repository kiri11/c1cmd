# Packaged recovery qualification — 2026-09-09 UTC

Current decision: see [release validation](../../RELEASE_VALIDATION.md). This directory retains the complete passing evidence and the clone failure that motivated the fix. Other attempts are summarized below. No source RAWs or rendered images are distributed.

## Run history

| Run | Artifact / outcome |
|---|---|
| run-1 | Original archive. Real Apple Event timeout and preview-timeout recovery passed. Harness used `workingRef` instead of `ref` for MCP preview, so that request did not dispatch. Run stopped and its Session was closed. |
| [run-2](run-2/clone-failure.json) | Original archive. Real Apple Event recovery passed. A subsequent clone returned a collection-scoped reference whose ID read failed with `-1700`. c1 returned an operation ID and preserved uncertainty. Explicit reconciliation after restart recorded candidate ID `8`, without adoption, deletion or a repeated clone. The retained excerpt includes the error, its operation journal transitions and reconciliation response. |
| run-3 | Patched handler: bounded ID-read retry, with no repeated clone dispatch. Ten clone/read/delete cycles and real Apple Event recovery passed. Long wall-clock gaps occurred, and the preview case stopped on the harness's 60-second app-quit deadline. This run is incomplete, not an all-cases pass. Manual reconciliation ended the preview write block after a verified app restart. |
| [run-4](run-4/events.jsonl) | **PASS:** ten clone/read/delete cycles and all three recovery cases. Launched with `caffeinate -i`. RAW checksums and original five-field state preserved; zero open documents after cleanup. See [summary](summary.json). |

The passing `events.jsonl` records UTC timestamps, raw CLI responses, environment and artifact hashes. The exact passing harness is [Tests/recovery_integration_test.py](../../../Tests/recovery_integration_test.py); its SHA-256 matches `harnessSHA256` in the evidence. The small `source.patch` records the production delta against the base commit. `journal.jsonl` and `provenance.json` are snapshots at successful harness exit. Runs 1 and 3 are summarized rather than retaining redundant logs and script copies. Run 2 retains only the clone failure and recovery evidence.

## Additional regression checks

The same patched archive passed 331/331 offline assertions, archive/contract checks, and extracted-release live CLI (19/19) and MCP (10/10) workflows. See [validation manifest](validation.json), [unit log](unit.log), [archive log](archive.log) and [live log](release-live.log).

## Interpretation limits

An external pause at the pre-dispatch journal boundary proves the packaged timeout/recovery path when a real `-1712` occurs. It does not identify the individual Apple Event in flight or prove a setter later executed. A newly created export file proves dispatch before MCP is killed, not that rendering was still outstanding at the instant of death. Restart reconciliation records observations; it does not certify historical success. The suite does not qualify same-file reopening within one app launch, concurrent operators, callbacks, arbitrary database replacement, or other Capture One builds.
