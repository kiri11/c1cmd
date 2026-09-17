# Filtered inventory and request diagnostics qualification

Contract **1.5.0** adds observable, bounded inventory requests and the read-only `request_status` tool (20 MCP tools). Native rating predicates and bulk ID reads are enabled for **Capture One 16.8.5.30 Sessions**. Catalogs and other allowed builds use a rating scan followed by metadata reads for matches. `C1_INVENTORY_STRATEGY=scan` explicitly selects the fallback.

The implementation preserves summary fields, ordering, distinct variants of one image, and requested collection/selection scope. It holds the advisory lock for the inventory, checks document identity between batches, checks ID/value alignment and ratings, and validates final membership. This is not an atomic application snapshot; exclusive use and no UI edits remain required. Candidate discovery can still block inside one Apple Event.

## Measured behavior

[Packaged measurements](packaged-inventory.json) compare the new CLI with the previous full-summary AppleScript handler, retained in `Tests/fixtures/inventory-reference.applescript`. Every comparison checks complete records and ordering. Each fixture contains 12 or 120 variants of **one copied CR3**, not 120 independent photographs.

| Case | Matches | Legacy enumeration | New packaged CLI |
|---|---:|---:|---:|
| 12 variants, sparse five-star filter | 1 | 1.637 s | 0.866 s |
| 120 variants, sparse five-star filter | 1 | 16.615 s | 0.997 s |
| 120 variants, dense five-star minimum | 120 | 17.131 s | 18.840 s |
| 120 variants, selected five-star filter | 60 | 8.548 s | 9.516 s |
| 120 variants, no four-star matches | 0 | 16.765 s | 0.665 s |

Sparse filters benefit from avoiding unmatched metadata. Dense results retain batching/validation overhead. These are single-run wall-clock measurements with different fixed overhead: the reference runs through `osascript`, while the CLI also performs document, lock, and consistency checks. Application response times varied between the [debug run](run-5.json) and packaged run. They do not predict throughput for a large wedding Session or heterogeneous RAW files.

The initial MCP progress notification arrived in 0.015 seconds; it is a request-start notification, not evidence that an image was processed. The live test waited for nonzero completed work before requesting status on the same occupied MCP server, then cancelled the inventory. Status returned `running`, cancellation stopped subsequent batches, and a follow-up scan returned all 120 records. Numeric and string progress tokens were exercised. CLI SIGINT stopped after three summaries, with no partial result on stdout. The deadline test failed at the next boundary, without partial results. Offline coverage verifies a heartbeat while the main thread is blocked and conservative mutation outcomes.

`handlerCalls` counts script invocations, not individual Apple Events. Peak memory and individual Apple Event counts were not measured. First CLI progress timestamps are relative to request initialization and rounded to milliseconds. Native candidate totals describe predicate matches; they do not measure internal Capture One filtering work. A heartbeat proves the c1 diagnostics thread is alive, not that Capture One advanced.

## Regression evidence

The final candidate passed **679/679 offline assertions**, CLI/MCP schema and profile checks, and relocated archive checks with build-tree resources hidden. Packaged live suites passed sequentially:

- CLI: 19 steps; MCP: 10 steps.
- [Geometry](geometry/events.jsonl): CLI/MCP, ratios, rotations, full-frame context, orientation, source/RAW preservation.
- [Catalog](catalog/results.json): exact-path opt-in, referenced-original clone/edit/preview/delete, default-output handling, original preservation.
- [Existing variants](existing/results.json): Session and referenced Catalog edits, baseline restoration, no duplicate variants, preserved ratings and RAW bytes.
- Inventory: 16 complete-record comparisons across sizes, sparse/dense ratings, exact/minimum zero, document/collection/selected combinations, and no-match results; MCP progress/status/cancellation, CLI SIGINT, and deadline checks.

The native-predicate [probe](native-probe.json) compares ordered IDs for 20 combinations of document/collection, selected/all, exact zero/five, minimum zero/four, and no rating filter. The fallback was also exercised in [run 4](run-4.json), plus offline branch coverage and packaged Catalog workflows.

Recovery qualification results and payload identity are recorded in [summary.json](summary.json) and the [recovery events](recovery/events.jsonl). The packaged `make qualify` attempt stopped during the geometry-timeout recovery because Capture One did not exit within 60 seconds of a native quit request. The fixture had closed and zero documents remained open. The preceding tonal timeout/restart/reconciliation case passed; the geometry operation remained unresolved. This interrupted attempt is retained as a failure, not a complete four-case pass.

**Subsequent result:** the [2026-09-17 campaign](../../release/recovery-2026-09-17/README.md) passed all four Session recovery cases with the same CLI/MCP/handler bytes, a fresh fixture outside `/tmp`, and explicit SIGTERM shutdown. This closes process-termination recovery coverage for this payload; native graceful quit remains unqualified. The interrupted attempts below remain historical failures.

A separate continuation ended the verified empty application process with SIGTERM, reopened only the retained Session, and reconciled the same geometry operation without retrying it. Geometry recovery passed: the write block survived restart until reconciliation, the old reference was rejected, native variants were preserved, and a fresh clone could be edited and deleted. The preview-timeout test then observed eventual output and verified that it did not clear the write block. Native quit stalled again at that restart. Both interrupted attempts have separate event records; the [final append-only journal](recovery-process-end/journal.jsonl) retains the operation history. Normal unattended restart reliability is not established by these continuations.

The final continuation reconciled the preview operation after another verified process end. Capture One returned IDs `33`, `34`, `35` instead of the earlier `1`, `12`, `18`, `32`; the original target ID was absent, and the inventory-preservation assertion failed. Reconciliation recorded that absence and did not retry, adopt, or delete a variant. The expired reference returned `document-changed`. The sequence stopped there: **full preview recovery and MCP process-death qualification did not pass on this candidate**. MCP read cancellation did pass separately; it is not a substitute for mutation client-death coverage. The retained Session is `/private/tmp/c1-recovery-1ujzomvx/recovery`; both original and copied RAW hashes were rechecked unchanged, and cleanup confirmed zero open documents. See [first continuation](recovery-continuation/events.jsonl), [final continuation](recovery-process-end/events.jsonl), and their retained scripts/journals.

## Run history and limits

Run 1 failed fixture setup because selection is not a writable variant property; setup now uses the native select command. Run 2 exposed a reserved AppleScript identifier in the test reference helper. Run 3 exposed `osascript` output quoting in that helper. These were test-harness failures before comparisons, and the disposable fixtures were retained. Run 4 passed with the conservative scan strategy; run 5 passed after native filtering was qualified. Failed attempts are not represented as passing runs.

The first packaged qualification attempt stopped when a Catalog full-frame preview exceeded the test client's 15-second receive timeout. Its [journal](initial-catalog-journal.jsonl) contained nine completed operations, including the preview; cleanup deletion had not been dispatched. The disposable Catalog was closed and retained, with no mutation retried. Live test clients now allow 150 seconds; offline contract clients retain their shorter wait. The final packaged Catalog suite passed. The retained failed fixture is `/private/tmp/c1-catalog-live-yyclamyp/qualification.cocatalog`.

The repository retains focused measurements, the [qualification log](qualification.log), recovery event streams, continuation scripts, and the final recovery journal. Duplicate harness copies and intermediate snapshots are omitted: the tested harness matches `Tests/recovery_integration_test.py` at the hash in the summary. The full qualification directory remains at `/private/tmp/c1-inventory-qualification-20260916-final`.

No main Catalog or user editing document was used. Source RAW bytes remain immutable; copied and source fixture SHA-256 is `2505287a24868a162c94bc879303a76f1e76b7ccb2bba4cacfdfeb4a33c4b868`. Catalog-stored originals, Catalog fault recovery, other Capture One builds, simultaneous UI operators, and general binary-distribution gates remain outside this qualification. Projections, pagination, caches, lock-owner identification, and bulk reads of additional metadata are deferred.

## Reproduce

Close all documents, use a preserved RAW fixture, and run live suites sequentially:

```sh
make qualify C1_TEST_RAW_FIXTURE=/path/to/local.CR3 EVIDENCE_DIR=/private/tmp/new-qualification
C1_TEST_RAW_FIXTURE=/path/to/local.CR3 \
  C1_NATIVE_PROBE_EVIDENCE=/private/tmp/native-probe.json \
  python3 -B Tests/native_inventory_probe.py
```

The full qualification includes real timeout waits and application restarts. It retains uncertain clones for inspection. Status inspection itself requires neither an Apple Event nor the Capture One lock. Diagnostic snapshots are best-effort cache files, separate from durable mutation evidence; see the [usage documentation](../../../README.md#inventory-progress-and-cancellation).
