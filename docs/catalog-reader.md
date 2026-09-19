# Stored Catalog discovery and SQLite archives

`c1 variants list --database /absolute/path/Library.cocatalog/Library.cocatalogdb`
uses SQLite directly, without Capture One, its application lock, or the currently open document. It returns a stored-observation object containing `variants` and database provenance. Separate processes can read concurrently. Ordinary `variants list` keeps its live AppleScript behavior and existing array response unless the caller explicitly supplies an active read-workflow ID.

```sh
c1 catalog variants --database /absolute/path/Library.cocatalog/Library.cocatalogdb --min-rating 3
c1 catalog inspect --database /absolute/path/Library.cocatalog/Library.cocatalogdb
c1 catalog variants --database /absolute/path/Library.cocatalog/Library.cocatalogdb --collection-id 7
c1 catalog snapshot --database /absolute/path/Library.cocatalog/Library.cocatalogdb --destination /absolute/path/archive.cocatalogdb
```

Single-variant stored inspection is `c1 get <numeric-variant-id> --database /absolute/path/Library.cocatalog/Library.cocatalogdb`. MCP equivalents are `catalog_get`, `catalog_variants`, `catalog_inspect`, and `catalog_snapshot`, using `database`, `collectionID`, `rating`, `minRating`, and `destination`. `catalog_variants` and the CLI database route share the same core. MCP stored reads run outside the AppleScript main actor and application lock. Use an independent reader per concurrent operation.

## Data and identity

Reader version 1 accepts the exact retained schema fingerprint, document type 1, format `16.8.5.30 Pro Mac`, and compatibility/version 160800. The schema manifest is bundled beside the executables in `c1_CaptureOneCore.bundle`. Unrecognized schemas and formats fail closed. This is a reverse-engineered, fixture-qualified stored-data interface.

Every response includes the canonical database path, device/inode identity, stored document UUID, schema fingerprint, transaction start time, observation time, reader version, and `storedStateOnly: true`. These identify the observation, not a live mutation precondition. Distinct variants of an image remain distinct; `variantDatabaseID` and `variantUUID` are separate from `imageDatabaseID` and `imageUUID`. Do not treat database IDs as authorized native references, even when numeric IDs agree on a fixture.

`catalog inspect` exposes raw collection, image, variant, path-location, membership, layer, metadata, retouching, and document-setting rows. Links such as `ZCOMBINEDSETTINGS`, `ZDEFAULTLAYER`, `ZADJUSTMENTLAYER`, and `ZMETADATA` remain explicit. `catalog variants` joins the combined settings layer's metadata for ratings and color tags. It resolves absolute externally referenced Mac paths only; relative, managed, or unrecognized locations retain their components and return `originalPath: null`. A stored path does not establish that an original is online.

`--collection-id` uses explicit membership: an image membership expands to every stored variant of that image; variant membership includes only that variant. Overlap does not duplicate variants. Virtual/smart collection rules, selection, manual sort order, and UI filters are not evaluated. Unscoped reads include stored trashed records, identified by `trashed`. Live selection/collection-name flags are rejected on the explicit-database route.

Stored state may lag Capture One. It cannot supply `stateHash`, `nativeStateHash`, document tokens, or any other mutation token, and cannot replace native post-write verification. Stored white balance is not decoded into Kelvin/tint; compound settings remain raw strings. External masks are not reconstructed. Use native `get` and normal editing preconditions immediately before writes.

## Transactions and archives

Connections use `SQLITE_OPEN_READONLY`, `query_only`, ordinary locking, and WAL visibility. There is no `immutable=1`, `nolock`, forced checkpoint, journal-mode change, or direct database-file copy. Reads observe one SQLite transaction. Each operation has a ten-second monotonic deadline, 250 ms busy timeout, 10,000-row per-result limit, and 64 MiB cumulative field-data limit; oversized or failed reads return no partial inventory. Large Catalogs exceeding these limits need a future paginated reader; current results are never silently truncated.

Snapshots use incremental `sqlite3_backup` inside the validated source transaction, including committed WAL data. The destination must be a new absolute `.cocatalogdb` path outside Catalog packages; existing files and symlinks are rejected. Failed backups remove their newly reserved file. A snapshot contains database records, not original photos, previews, external mask files, or a complete native Catalog backup. Native Catalog backup and RAW backup remain separate workflows.

## Performance and routing decision

The retained [benchmark](qualification/catalog-reader/benchmark.json) compares equivalent ID/name/path/rating/color-tag observations from the same open disposable three-variant Catalog. The initial debug measurement was approximately 29 ms per SQLite CLI call versus 975 ms for live AppleScript inventory (34×). Twelve SQL calls took 317 ms with one worker and 80 ms with four workers (4× throughput). Process startup is included. The [packaged benchmark](qualification/catalog-reader/benchmark-packaged.json) measured about 47× faster reads and 4.0× throughput with four SQL workers.

This supports SQLite as the backend for explicit stored discovery. It does **not** establish equivalence for live selection, smart collections, arbitrary settings conversions, or unsaved edits. Ordinary live commands retain AppleScript; adding `--database` selects SQLite explicitly. The controlled workflow below separately enables automatic routing for participating browsing calls. There is no silent fallback from an explicit database path to the current document, which could be a different Catalog or Session. On a schema rejection, use native commands only after independently verifying that the intended document is open. Workflow results carry their own observation metadata and omit mutation tokens; explicit database requests never fall back to another document.

Reproduce with `scripts/benchmark-catalog.py` and `scripts/qualify-catalog-reader.py`; both require the matching disposable Catalog already open and perform read-only native calls sequentially. The benchmark does not run competing AppleScript calls. This small-fixture measurement is not a large-Catalog scaling claim or a screen-lock/load matrix.

## Qualification and Session assessment

`make check` includes synthetic records built from the real schema, preserving duplicate image variants, both membership kinds, rating filters, path uncertainty, changed-schema/type rejection, row limits, lock failure, concurrent reads, committed/uncommitted WAL visibility, backup integrity, overwrite/symlink protection, and CLI/MCP parity. The read-only [native comparison](qualification/catalog-reader/native-comparison.json) checks the local Catalog's combined exposure/contrast/saturation, an explicit image collection, and an archive read while the original document remains open. Its fixture values and omitted scopes are recorded in the evidence.

A local 16.8.5.30 Session database has similarly named tables and stored image/variant/layer rows. That does not qualify Session completeness: Session folder discovery and settings-sidecar behavior need separate native comparisons. Session paths and Session document types remain rejected. No mutation dispatch, journaling, restart, or reconciliation behavior changed; live recovery fault suites are not applicable to this reader work.

## Measuring freshness before automatic routing

The initial read-only benchmark established speed and agreement on unchanged data. It did not establish read-after-write consistency. `scripts/probe-catalog-freshness.py` tests that separately using a **new disposable Catalog and copied RAW**, with zero documents required at startup:

```sh
python3 scripts/probe-catalog-freshness.py \
  --cli .build/release/c1 \
  --raw /absolute/path/fixture.CR3 \
  --evidence /absolute/path/new-evidence-directory \
  --trials 2 --observe-seconds 30
```

The probe confirms doctor/build/document/original identity, makes a native backup, prepares an existing editing reference, and performs sequential guarded rating/tag and nonzero tonal writes. After each successful native acknowledgement it polls an independent SQLite connection every 20 ms, using a fresh read transaction each time. It records the first observation, changes, the last observation, poll counts, elapsed time, and an independent native `get` afterward. A separate autocommit SQLite connection observes `PRAGMA data_version`; the database mtime is recorded as well. Success restores the saved native values and closes only the owned fixture. Any failed or uncertain native operation stops with the fixture retained; there is no automatic retry or exception-path restore. Capture One is never quit.

Local Capture One **16.8.5.30** experiments found stale committed data **after successful native acknowledgement**. The short experiment saw six initial mismatches in six writes; five did not converge within its five-second window. The longer experiment also observed a rating/tag update still missing at 30 seconds. See the retained [short-run summary](qualification/catalog-reader/freshness-short-summary.json), [long-run summary](qualification/catalog-reader/freshness-long-summary.json), and [long-run observations](qualification/catalog-reader/freshness-long-events.json). The evidence uses the Catalog's existing `delete` journal mode; the probe never changes it. Non-convergence means a lower bound on lag, not that the write was lost.

This is not an old SQLite read snapshot: every sample opens a new connection. [SQLite only exposes committed writes to independent connections](https://www.sqlite.org/isolation.html). [Its `data_version` counter](https://www.sqlite.org/pragma.html#pragma_data_version) detects commits by other connections when compared on the same observing connection. It does not report edits still buffered by Capture One. A stable mtime or change counter therefore cannot establish equality with native state. The installed scripting dictionary exposes no explicit save/flush or document dirty/revision property suitable as a supported freshness barrier. Forcing a WAL checkpoint would not commit application-buffered edits either.

## Controlled browsing workflow

The agent or automation script owns the handoff, under the existing rule that the photographer does not edit in the UI during its workflow. `read-session` means an automation workflow, not a Capture One Session. Begin captures a native, unfiltered inventory for the requested scope; each variant's first `get` captures its native settings. The returned `workflowId` must accompany subsequent browsing calls:

```sh
c1 read-session begin --format json
# Copy workflowId from that response; keep it local to this agent batch.
c1 variants list --read-workflow <workflowId> --min-rating 4 --format json
c1 get <native-id> --read-workflow <workflowId> --format json
c1 get <native-id> --live --format json  # Fresh tokens before preparing an edit.
c1 read-session status --read-workflow <workflowId>
c1 read-session end --read-workflow <workflowId>
```

MCP uses `read_session_begin`, `read_session_status`, `read_session_end`, and the `readWorkflow` argument on `variants_list`, `get`, `dump`, and two-reference `diff`. CLI batches can alternatively set `C1_READ_WORKFLOW` in their own environment. End in normal cleanup before returning control to the photographer. An abandoned workflow does not affect callers without its ID; start a new baseline after a crash. Ordinary calls remain native, and `--live` / `live: true` bypasses the workflow. Editing/managed references, native-target requests, and inventory calls with a deadline also remain native.

Workflow output contains `readObservation` with its backend, workflow ID, native confirmation time, and SQL agreement flags. Cached `get`, `dump`, and `diff` have no mutation tokens. Use a fresh native `get --live` before `variant edit`; all mutation preparation, internal reads, verification, and recovery remain native. Workflow CLI output is JSON (or JSONL for `dump --format jsonl`).

Successful metadata and tonal journal entries update the affected variant's saved native state immediately. Rating filters apply **after** those updates, so a newly rated variant in the captured scope is included even if SQLite still holds its old rating. After 60 seconds from observing an acknowledged edit, SQL is compared with the saved native-confirmed values. This comparison does not fetch native settings again. Matching rating/tag and exposure/contrast/saturation fields can then come from SQL; white balance, geometry, selection, and other fields remain native-cached. Nonmatching fields retain confirmed values and are checked again after another minute. Elapsed time alone never proves that SQLite caught up.

The workflow captures its membership and order at begin. It does not reevaluate smart collections, UI filters, or selection; use live calls or begin again for changed membership. Structural, geometry, native, and export operations invalidate the optimization rather than guessing their effects. Unknown/failed operations, corrupt or truncated journals, application/database identity changes, SQL divergence, and SQL/schema failures fall back to native reads. An unsupported SQL projection at begin uses a native-confirmed cache instead. Cache files are disposable and never authorize writes.

Active-document workflow calls still serialize and perform native document identity checks before and after the read. They avoid native per-variant value reads after warming; they do not provide parallel AppleScript execution. Explicit `--database` reads remain independent and parallel, with no handoff or warm-up. Closed Catalogs can therefore be browsed directly; opening one elsewhere can make the stored/live distinction relevant again, so normal SQLite transaction and identity checks remain enabled.

### Capture One Sessions

Sessions use the same controlled native cache and journal updates, but **do not route to Catalog SQL**. The live Session fixture returned no stored `ZVARIANT` rows while a native variant was visible and editable; closing the Session populated a row and left a `CaptureOne/Settings1680/*.cos` sidecar. A Session database alone is consequently not a complete live discovery/settings source. Offline Session folder/sidecar discovery needs a separate reader and is not implemented here.

### Workflow validation

`Tests/read_workflow_integration_test.py` creates disposable Session and Catalog fixtures from copied RAWs, requires zero open documents, and tests packaged CLI/MCP parity, caller isolation, native token bypass, metadata/tonal overlays, the 60-second comparison, handler traces, restoration, and closed-Catalog inspection. It never quits Capture One and retains failed fixtures without automatic retries or restoration. Run with `C1_TEST_BIN`, `C1_TEST_MCP_BIN`, `C1_TEST_RAW_FIXTURE`, and a new `C1_READ_WORKFLOW_EVIDENCE` directory. Retained results and small-fixture timings are in [workflow qualification](qualification/catalog-reader/read-workflow.json). These timings are not a large-Catalog scaling guarantee.

Offline tests cover uncertainty, unsupported operations, restart invalidation, persistence across callers, rating inclusion, and token stripping. Mutation dispatch, durable journal writing, native locks, timeout handling, and reconciliation remain unchanged; this browsing-only work does not require the unrelated live recovery fault campaign.
