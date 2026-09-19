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

Reader version 1 compares complete DDL against retained schema manifests, allowing ASCII whitespace differences outside quoted strings/identifiers and the standard SQLite `sqlite_stat1`/`sqlite_stat4` table definitions. It requires document type 1 and an exact version history for the matching schema, ordered by `Z_PK`. The original manifest requires one row with format `16.8.5.30 Pro Mac` and compatibility/version 160800. The separately qualified upgraded Catalog manifest (`catalog-schema-upgraded-16.8.5.json`) retains its specific column order and four historical version tuples ending in that same build. Histories cannot be mixed between manifests; no maximum-version or latest-row heuristic is used. Types, constraints, indexes, column order, quoted text, token boundaries and unknown objects must match a retained manifest; comments are not normalized. The manifests are bundled beside the executables in `c1_CaptureOneCore.bundle`. Unrecognized schemas and histories fail closed. This is a reverse-engineered, fixture-qualified stored-data interface. The reported `schemaFingerprint` remains the exact raw schema hash, so compatible databases can report different fingerprints.

Every response includes the canonical database path, device/inode identity, stored document UUID, schema fingerprint, transaction start time, observation time, reader version, and `storedStateOnly: true`. These identify the observation, not a live mutation precondition. Distinct variants of an image remain distinct; `variantDatabaseID` and `variantUUID` are separate from `imageDatabaseID` and `imageUUID`. Do not treat database IDs as authorized native references, even when numeric IDs agree on a fixture.

`catalog inspect` exposes raw collection, image, variant, path-location, membership, layer, metadata, retouching, and document-setting rows. Links such as `ZCOMBINEDSETTINGS`, `ZDEFAULTLAYER`, `ZADJUSTMENTLAYER`, and `ZMETADATA` remain explicit. `catalog variants` joins the combined settings layer's metadata for ratings and color tags. It resolves absolute externally referenced Mac paths only; relative, managed, or unrecognized locations retain their components and return `originalPath: null`. A stored path does not establish that an original is online.

`--collection-id` uses explicit membership: an image membership expands to every stored variant of that image; variant membership includes only that variant. Overlap does not duplicate variants. Virtual/smart collection rules, selection, manual sort order, and UI filters are not evaluated. Unscoped reads include stored trashed records, identified by `trashed`. Live selection/collection-name flags are rejected on the explicit-database route.

Stored state may lag Capture One. It cannot supply `stateHash`, `nativeStateHash`, document tokens, or any other mutation token, and cannot replace native post-write verification. Stored white balance is not decoded into Kelvin/tint; compound settings remain raw strings. External masks are not reconstructed. Use native `get` and normal editing preconditions immediately before writes.

## Transactions and archives

Connections use `SQLITE_OPEN_READONLY`, `query_only`, ordinary locking, and WAL visibility. There is no `immutable=1`, `nolock`, forced checkpoint, journal-mode change, or direct database-file copy. Reads observe one SQLite transaction. Each operation has a ten-second monotonic deadline, 250 ms busy timeout, 10,000-row per-result limit, and 64 MiB cumulative field-data limit; oversized or failed reads return no partial inventory. Large Catalogs exceeding these limits need a future paginated reader; current results are never silently truncated.

Snapshots use incremental `sqlite3_backup` inside the validated source transaction, including committed WAL data. The destination must be a new absolute `.cocatalogdb` path outside Catalog packages; existing files and symlinks are rejected. Failed backups remove their newly reserved file. A snapshot contains database records, not original photos, previews, external mask files, or a complete native Catalog backup. Native Catalog backup and RAW backup remain separate workflows.

## Routing and validation

SQLite serves explicit stored discovery. It does not establish equivalence for
live selection, smart collections, arbitrary settings conversions or unsaved edits.
Ordinary live commands use AppleScript; `--database` selects SQLite explicitly.
An explicit database request never falls back to another document. On schema
rejection, use native commands only after verifying the intended open document.

Use `scripts/benchmark-catalog.py` and `scripts/qualify-catalog-reader.py` with a
matching disposable Catalog for read-only comparisons. Native calls stay sequential.
Keep generated results under `.build/qualification` or external artifact storage.

`make check` covers schema/type/version rejection, both membership kinds, duplicate
image variants, rating filters, path uncertainty, row limits, locking, concurrent
reads, WAL visibility, backup integrity, overwrite/symlink protection and CLI/MCP
parity. The upgraded schema has its own exact column order and version tuples.

Session databases remain rejected: similarly named tables do not establish
complete folder discovery or settings-sidecar behavior. Stored reads never change
mutation dispatch, journaling or reconciliation rules.

## Measuring freshness

Read-only agreement does not establish read-after-write consistency. `scripts/probe-catalog-freshness.py` tests freshness using a **new disposable Catalog and copied RAW**, with zero documents required at startup:

```sh
python3 scripts/probe-catalog-freshness.py \
  --cli .build/release/c1 \
  --raw /absolute/path/fixture.CR3 \
  --evidence /absolute/path/new-evidence-directory \
  --trials 2 --observe-seconds 30
```

The probe confirms doctor/build/document/original identity, makes a native backup, prepares an existing editing reference, and performs sequential guarded rating/tag and nonzero tonal writes. After each successful native acknowledgement it polls an independent SQLite connection every 20 ms, using a fresh read transaction each time. It records the first observation, changes, the last observation, poll counts, elapsed time, and an independent native `get` afterward. A separate autocommit SQLite connection observes `PRAGMA data_version`; the database mtime is recorded as well. Success restores the saved native values and closes only the owned fixture. Any failed or uncertain native operation stops with the fixture retained; there is no automatic retry or exception-path restore. Capture One is never quit.

Committed SQLite data can lag successful native acknowledgements. Neither
`PRAGMA data_version` nor database mtime is a native synchronization barrier.
Use native reads and mutation tokens for edits; do not treat an unchanged database
as proof that the application's current settings are unchanged.

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

Sessions use the same controlled native cache and journal updates, but **do not route to Catalog SQL**. Session discovery and `CaptureOne/Settings1680/*.cos` sidecars are not fully represented by the live Session database. That database alone is not a complete discovery/settings source. Offline Session folder/sidecar discovery needs a separate reader and is not implemented here.

### Workflow validation

Offline tests cover uncertainty, unsupported operations, restart invalidation, persistence across callers, rating inclusion, and token stripping. Browsing does not bypass mutation dispatch, durable journals, native locks, timeout handling or reconciliation. Select recovery tests only when those behaviors change.
