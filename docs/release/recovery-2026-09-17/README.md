# Four-case Session recovery with explicit process termination

**PASS for process-termination recovery on Capture One 16.8.5.30.** On 2026-09-17, the revised harness completed all four real fault cases using the retained packaged candidate and a fresh Session outside `/tmp`. The run exited zero, preserved native IDs through all four restarts, preserved the source's adjustments/geometry and RAW bytes, and finished with zero open documents. This qualifies the explicitly selected **SIGTERM** recovery path in the documented Session scope. It does not qualify graceful native quit.

## Results

| Case | Result | Native IDs before and after restart |
|---|---|---|
| Real tonal Apple Event timeout | Passed | `1`, `12` |
| Real geometry Apple Event timeout | Passed | `1`, `12`, `14` |
| Preview timeout with eventual output | Passed | `1`, `12`, `14`, `16` |
| MCP process death after export dispatch | Passed | `1`, `12`, `14`, `16`, `19` |

Both mutation-timeout cases returned actual Apple Event `-1712` errors. Capture One was paused after the durable pending record, with an independent 150-second resume watchdog. The preview-timeout case observed a completed output after the caller timed out. The MCP case killed the extracted `c1-mcp` after a new output appeared, while its latest operation record was still pending and before the preview response reached the client.

For every case, unresolved writes remained blocked before restart and after restart until explicit `operation status` reconciliation. Old references returned `document-changed`. Native IDs, count, and parent-image paths matched before and after restart, after reconciliation, and after a fresh managed clone was edited and deleted. The original variant's tonal state hash and geometry remained unchanged. Reconciliation recorded observations; it did not retry, adopt, delete, or establish historical success for an uncertain write.

The eight closed/terminated database snapshots each contained **one RAW image record** and passed SQLite `quick_check`. The fourth restart also had an exported JPEG record and two preview-folder records; those were not duplicate RAW records. The earlier `/tmp` duplication and visible-ID loss did not recur. This successful control does not establish the exact cause of the earlier ID loss.

## Shutdown and scope

`C1_RECOVERY_SHUTDOWN_MODE=sigterm` was selected before the run. Each restart closed only the owned Session, confirmed zero documents, rechecked the verified application PID, sent SIGTERM, observed process exit, and required a different PID after reopening. No native-quit fallback was used. The [application log excerpt](shutdown-excerpt.log) records one subsequent launch with a `Normal` termination label and three with `Abnormal`; the mode remains process termination regardless of those labels.

The [earlier diagnosis](../../recovery-diagnosis/16.8.5.30/README.md) still applies: native quit can stall even with zero documents. That failure is not relabeled as passing. The retained failed Session at `/private/tmp/c1-recovery-1ujzomvx/recovery` was not reused. No main Catalog or user editing document was touched. Catalog fault recovery, catalog-stored originals, other application builds, simultaneous UI editing, and binary-distribution gates remain outside this run.

## Payload and evidence

The [machine-readable summary](summary.json), [events](run-1/events.jsonl), [journal](run-1/journal.jsonl), and [provenance](run-1/provenance.json) retain the result. Snapshot paths are indexed in the summary. The full scratch run is `/private/tmp/c1-recovery-qualification-20260917-sigterm-run1`; its harness copy matches `Tests/recovery_integration_test.py` at SHA-256 `44d544dc644d1372c38835e3f8f5527d5fdc6f82cd3f94c16fb38d4af4c31903`. Production sources were unchanged and the recorded source patch is empty. The build-tree resource bundle was hidden during the run and restored afterward.

Archive SHA-256 is `258c3be50b488e9cde4265b97f6e8a5c8a4d0f303a6d329f260598389f984484`. Its wrapper differs from the earlier archive, but its CLI, MCP, and handler bytes exactly match the [inventory candidate](../../inventory/16.8.5.30/summary.json):

| Payload | SHA-256 |
|---|---|
| CLI | `8eac889a502381e0adf95e678807aee9adbeb5c59d9026d871c0f553b0664df1` |
| MCP | `0fa7dc5b5df2bc192e7c14e38800027fc1e2ec22d7f5ed90bd78146c076791a5` |
| Handler | `c0cbe307d17b601cecd224ab0e77b1fe11cf61856f47e5346dd8e7214c81a567` |

`make check` passed before the campaign: **679/679 Swift assertions**, CLI/MCP contract/profile checks, and **20 offline recovery-harness tests**. The live campaign took about **468 seconds** from its environment record through cleanup. Previously passing packaged CLI/MCP/geometry/Catalog/existing-variant/inventory suites were not repeated because their runtime payload was unchanged. This is a separate recovery run, not a new full `make qualify` invocation.

The disposable fixture is retained at `/Users/kiri11/projects/c1cmd/.build/recovery-fixtures/c1-recovery-9ow5hb0r/recovery`. Both its copied RAW and the preserved source RAW have SHA-256 `2505287a24868a162c94bc879303a76f1e76b7ccb2bba4cacfdfeb4a33c4b868`. Retain the fixture before build cleanup if further forensic inspection is wanted. RAWs, JPEGs, binary databases, and redundant harness/console copies are not committed.

## Reproduce

Close all documents and reserve exclusive Capture One use. Use a new evidence directory:

```sh
C1_TEST_RAW_FIXTURE=/absolute/path/to/preserved.CR3 \
C1_RECOVERY_SHUTDOWN_MODE=sigterm \
caffeinate -i python3 -B Tests/recovery_integration_test.py \
  dist/c1-v0.1.0-macos-arm64.tar.gz /private/tmp/new-recovery-evidence
```

The default fixture parent is the checkout's `.build/recovery-fixtures`. `C1_RECOVERY_FIXTURE_PARENT` may select another absolute path outside `/tmp` and `/private/tmp`, without symlink aliases. Omitting the shutdown setting uses native `quit`, which remains a separate, potentially failing campaign. Do not retry an uncertain mutation or relax ID-preservation assertions to obtain a pass.
