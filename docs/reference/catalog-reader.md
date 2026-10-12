# Stored Catalog discovery and SQLite archives

`c1 variants list --database /absolute/path/Library.cocatalog/Library.cocatalogdb`
uses SQLite directly, without Capture One, its application lock, or the currently open document. It returns a stored-observation object containing `variants` and database provenance. Separate processes can read concurrently. Ordinary `variants list` keeps its live AppleScript behavior and existing array response unless the caller explicitly supplies an active read-workflow ID.

```sh
c1 catalog variants --database /absolute/path/Library.cocatalog/Library.cocatalogdb --min-rating 3
c1 catalog inspect --database /absolute/path/Library.cocatalog/Library.cocatalogdb --tables variants,storedSettings --limit 1000
c1 catalog collections --database /absolute/path/Library.cocatalog/Library.cocatalogdb
c1 catalog variants --database /absolute/path/Library.cocatalog/Library.cocatalogdb --collection "Trips 2024"
c1 catalog variants --database /absolute/path/Library.cocatalog/Library.cocatalogdb --collection-id 7
c1 catalog snapshot --database /absolute/path/Library.cocatalog/Library.cocatalogdb --destination /absolute/path/archive.cocatalogdb
```

Single-variant stored inspection is `c1 get <numeric-variant-id> --database /absolute/path/Library.cocatalog/Library.cocatalogdb`. MCP equivalents are `catalog_get`, `catalog_collections`, `catalog_variants`, `catalog_inspect`, and `catalog_snapshot`, using `database`, `collectionID`, `collection`, `rating`, `minRating`, `afterVariantID`, `tables`, `afterPK`, `limit`, and `destination`. `catalog_variants` and the CLI database route share the same core. MCP stored reads run outside the AppleScript main actor and application lock. Use an independent reader per concurrent operation.

## Data and identity

Reader version 1 compares complete DDL against retained schema manifests, allowing ASCII whitespace differences outside quoted strings/identifiers and the standard SQLite `sqlite_stat1`/`sqlite_stat4` table definitions. It requires document type 1 and an exact version history for the matching schema, ordered by `Z_PK`. The original manifest requires one row with format `16.8.5.30 Pro Mac` and compatibility/version 160800. The separately qualified upgraded Catalog manifest (`catalog-schema-upgraded-16.8.5.json`) retains its specific column order and four historical version tuples ending in that same build. Histories cannot be mixed between manifests; no maximum-version or latest-row heuristic is used. Types, constraints, indexes, column order, quoted text, token boundaries and unknown objects must match a retained manifest; comments are not normalized. The manifests are bundled beside the executables in `c1_CaptureOneCore.bundle`. Unrecognized schemas and histories fail closed. This is a reverse-engineered, fixture-qualified stored-data interface. The reported `schemaFingerprint` remains the exact raw schema hash, so compatible databases can report different fingerprints.

Every response includes the canonical database path, device/inode identity, stored document UUID, schema fingerprint, transaction start time, observation time, reader version, and `storedStateOnly: true`. These identify the observation, not a live mutation precondition. Distinct variants of an image remain distinct; `variantDatabaseID` and `variantUUID` are separate from `imageDatabaseID` and `imageUUID`.

`catalog inspect` exposes raw collection, image, variant, path-location, membership, layer, metadata, retouching, and document-setting rows. Links such as `ZCOMBINEDSETTINGS`, `ZDEFAULTLAYER`, `ZADJUSTMENTLAYER`, and `ZMETADATA` remain explicit. `catalog variants` joins the combined settings layer's metadata for ratings and color tags. It resolves absolute externally referenced Mac paths only; relative, managed, or unrecognized locations retain their components and return `originalPath: null`. A stored path does not establish that an original is online.

`catalog collections` lists every stored collection with `collectionID`, `name`, the raw Core Data `entity` number and its `kind` name from `ZENTITIES`, `parentID`, and `namePath`, the names from the top level down to this one; the Catalog's hidden `root` project collection is omitted from other collections' paths. System collections are listed too. A parent cycle fails closed. Use it to find the ID of a named album.

`catalog variants --collection NAME` resolves an exact, case-sensitive name to one stored collection and reports its `collectionID`. A name shared by several collections fails with `invalid-request` and lists each candidate's ID and name path; pass the intended one as `--collection-id`. An unknown name fails the same way. `--collection` and `--collection-id` are mutually exclusive. Both use the same explicit membership, and neither evaluates smart-collection rules. A name that resolves to a smart album (stored `ZSMARTCRITERIA`) fails with `invalid-request`; list it live with `variants_list` `collection`. `--collection-id` does not check, and returns only the smart album's explicit stored membership.

`--collection-id` uses explicit membership: an image membership expands to every stored variant of that image; variant membership includes only that variant. Overlap does not duplicate variants. A live album lists only its variant memberships, so the expansion can include variants of that image that the album does not show. Virtual/smart collection rules, selection, manual sort order, and UI filters are not evaluated. Unscoped reads include stored trashed records, identified by `trashed`. `variants list --database` rejects the live `--selected` and `--collection` flags; use `catalog variants --collection` for a stored collection name.

Stored state may lag Capture One by about a minute. A Capture One process that has run for hours can take half an hour, or lose new collections and variants for good: the Catalog then reopens without them. It cannot supply `stateHash`, `nativeStateHash`, document tokens, or any other mutation token, and cannot replace native post-write verification. Stored white balance is not decoded into Kelvin/tint; compound settings remain raw strings. External masks are not reconstructed. Use native `get` and normal editing preconditions immediately before writes.

### Stored photographer edits

`catalog variants` reports whether each variant's stored settings differ from its stored default layer (`ZDEFAULTLAYER`). It compares the combined settings layer (`combinedSettingsID`, `ZCOMBINEDSETTINGS`) with the default layer (`defaultSettingsID`, `ZDEFAULTLAYER`):

- `settingsChanged` is `true` when at least one stored column differs, and `false` when none does.
- `changedSettings` lists the differing column names, sorted, for example `["ZCROP", "ZROTATION"]`. The row identity and link columns `Z_PK`, `Z_ENT`, `ZINDEX`, `ZVARIANT` and `ZMETADATA` are not compared. Names stay raw; they are not decoded into adjustments.
- When a variant's default or combined link is null or points to no stored layer, both fields are `null` and `settingsUnavailableReason` is `missing-default-layer` or `missing-combined-layer`. The reader does not guess.

Qualified on Capture One 16.8.5.30 with owned Catalogs in both layouts: a fresh import reports `false`; exposure reports `ZEXPOSURE`; rotation with a 3:2 crop reports `ZCROP` and `ZROTATION`; a rating and color tag change alone reports `false`; an exposure edit followed by c1 `reset` reports `false`. Imports used no auto adjust and no style. The `catalog` live suite repeats these cases.

The signal misses some edits:

- Metadata-only changes are excluded by design. Ratings and color tags are in `rating` and `colorTag`.
- Local adjustment layers, masks and retouching layers are not qualified. An edit made only there may not appear.
- Imports with auto adjust or an applied style, and Capture One's own Reset Adjustments, are not qualified.
- `ZVARIANT.ZISMODIFIED` is not used. The first adjustment sets it, and it stays set after c1 `reset`, so it means "ever modified". `catalog get` still returns it raw.

Stored state lags live state. In one qualification run, acknowledged edits took 41 to 48 seconds to appear in SQLite, and a just-imported variant's layer rows were still replaced after ten quiet seconds. Use the signal as a triage hint, for example to set aside variants that probably carry photographer edits. It is never a mutation precondition and does not replace `get` state tokens ([invariant 2](../../AGENT_GUIDE.md#safety-invariants)). `false` does not prove that a variant is unedited; read a fresh live `get` before preparing any edit.

### From a stored variant to a live edit

`variantDatabaseID` is the stored field that addresses a live variant: Capture One's native variant ID is the same number, as text. The `catalog` live suite checks this for every stored variant of its owned Catalog fixture, including several variants of one image. `variantUUID` and `imageUUID` are never live references; live `get`, `variants_list` `ids` and `dump` `ids` reject a UUID-shaped ref with `invalid-request` before contacting Capture One.

1. Take `variantDatabaseID` from `catalog variants`.
2. Confirm it live: `variants_list` with `ids` and `fields: summary` (check `name` and `parentImagePath`), or `get --live`. Compare `parentImagePath` with the stored `originalPath` after resolving symlinks in both: the stored path drops a leading `/private` that the live path can keep.
3. Prepare the edit with `variant_edit`, using the tokens from a fresh live `get`.

A stored ID is a lookup candidate, never a write authorization ([invariant 1](../../AGENT_GUIDE.md#safety-invariants)). Always confirm it live: stored state can lag, and the variant can have been deleted or the database replaced since the read.

## Transactions and archives

Connections use `SQLITE_OPEN_READONLY`, `query_only`, ordinary locking, and WAL visibility. There is no `immutable=1`, `nolock`, forced checkpoint, journal-mode change, or direct database-file copy. Reads observe one SQLite transaction. Each operation has a ten-second monotonic deadline, 250 ms busy timeout, 10,000-row per-result limit, and 64 MiB cumulative field-data limit; oversized or failed reads return no partial inventory.

### Paging

Large Catalogs exceed these limits, so `catalog variants` and `catalog inspect` page by key. `catalog variants` takes `--limit` (1–10,000) and `--after-variant-id`, and returns `next`, the `variantDatabaseID` to pass as `afterVariantID` for the following page, while more variants match. `catalog inspect` takes `--tables` (a subset of `document`, `version`, `collections`, `images`, `variants`, `imageMembership`, `variantMembership`, `pathLocations`, `storedSettings`, `storedMetadata`, `storedRetouching` and `documentSettings`), `--after-pk` and `--limit`. Both apply to every selected table, and `next` maps each table with more rows to its `afterPK` cursor; continue one table at a time with `--tables`. Filters and collection scope apply before paging.

A page holds either `limit` rows or the final rows, and an omitted `next` means the read reached the end. Without `limit`, a read returns every remaining row or fails. The deadline and both limits still apply to each page; on the 64 MiB limit, request fewer tables or a smaller `limit`.

Each page is a separate observation in its own transaction, with full provenance. Compare `databaseFileIdentity`, `databaseDocumentUUID` and `schemaFingerprint` across pages to detect a replaced or different database. Matching provenance does not prove the content is unchanged: rows committed between pages can be missed or appear in a later page. For one consistent view, take a `catalog snapshot` and page the snapshot.

Snapshots use incremental `sqlite3_backup` inside the validated source transaction, including committed WAL data. The destination must be a new absolute `.cocatalogdb` path outside Catalog packages; existing files and symlinks are rejected. Failed backups remove their newly reserved file. A snapshot contains database records, not original photos, previews, external mask files, or a complete native Catalog backup. Native Catalog backup and RAW backup remain separate workflows.

## Routing

SQLite serves explicit stored discovery. It does not establish equivalence for
live selection, smart collections, arbitrary settings conversions or unsaved edits.
Ordinary live commands use AppleScript; `--database` selects SQLite explicitly.
An explicit database request never falls back to another document. On schema
rejection, use native commands only after verifying the intended open document.

Session databases remain rejected: similarly named tables do not establish
complete folder discovery or settings-sidecar behavior. Stored reads never change
mutation dispatch, journaling or reconciliation rules.

## Freshness

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

MCP uses `read_session_begin`, `read_session_status`, `read_session_end`, and the `readWorkflow` argument on `variants_list`, `get`, `dump`, and two-reference `diff`. Begin only while the photographer has handed over control, and end before returning it. A CLI batch may set `C1_READ_WORKFLOW` in its own environment; never export it globally or share the ID with unrelated callers. An abandoned workflow does not affect callers without its ID; start a new baseline after a crash. Ordinary calls remain native, and `--live` / `live: true` bypasses the workflow. Editing/managed references, native-target requests, and inventory or `dump` calls with `ids` or a deadline also remain native.

Workflow output contains `readObservation` with its backend, workflow ID, native confirmation time, and SQL agreement flags. Cached `get`, `dump`, and `diff` have no mutation tokens. Use a fresh native `get --live` before `variant edit`; all mutation preparation, internal reads, verification, and recovery remain native. Workflow CLI output is JSON (or JSONL for `dump --format jsonl`).

Successful metadata and tonal journal entries update the affected variant's saved native state immediately. Rating filters apply **after** those updates, so a newly rated variant in the captured scope is included even if SQLite still holds its old rating. After 60 seconds from observing an acknowledged edit, SQL is compared with the saved native-confirmed values. This comparison does not fetch native settings again. Matching rating/tag and exposure/contrast/saturation fields can then come from SQL; white balance, geometry, selection, and other fields remain native-cached. Nonmatching fields retain confirmed values and are checked again after another minute. Elapsed time alone never proves that SQLite caught up.

The workflow captures its membership and order at begin. It does not reevaluate smart collections, UI filters, or selection; use live calls or begin again for changed membership. Structural, geometry, native, and export operations invalidate the optimization rather than guessing their effects. Unknown/failed operations, corrupt or truncated journals, application/database identity changes, SQL divergence, and SQL/schema failures fall back to native reads. An unsupported SQL projection at begin uses a native-confirmed cache instead. Cache files are disposable and never authorize writes.

Active-document workflow calls still serialize and perform native document identity checks before and after the read. They avoid native per-variant value reads after warming; they do not provide parallel AppleScript execution. Explicit `--database` reads remain independent and parallel, with no handoff or warm-up. Closed Catalogs can therefore be browsed directly; opening one elsewhere can make the stored/live distinction relevant again, so normal SQLite transaction and identity checks remain enabled.

### Capture One Sessions

Sessions use the same controlled native cache and journal updates, but **do not route to Catalog SQL**. Session discovery and `CaptureOne/Settings1680/*.cos` sidecars are not fully represented by the live Session database. That database alone is not a complete discovery/settings source. Offline Session folder/sidecar discovery needs a separate reader and is not implemented here.
