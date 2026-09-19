# Stored Catalog discovery and SQLite archives

`c1 variants list --database /absolute/path/Library.cocatalog/Library.cocatalogdb`
uses SQLite directly, without Capture One, its application lock, or the currently open document. It returns a stored-observation object containing `variants` and database provenance. Separate processes can read concurrently. Ordinary `variants list` keeps its live AppleScript behavior and existing array response.

```sh
c1 catalog variants --database /absolute/path/Library.cocatalog/Library.cocatalogdb --min-rating 3
c1 catalog inspect --database /absolute/path/Library.cocatalog/Library.cocatalogdb
c1 catalog variants --database /absolute/path/Library.cocatalog/Library.cocatalogdb --collection-id 7
c1 catalog snapshot --database /absolute/path/Library.cocatalog/Library.cocatalogdb --destination /absolute/path/archive.cocatalogdb
```

MCP equivalents are `catalog_variants`, `catalog_inspect`, and `catalog_snapshot`, using `database`, `collectionID`, `rating`, `minRating`, and `destination`. `catalog_variants` and the CLI database route share the same core. MCP stored reads run outside the AppleScript main actor and application lock. Use an independent reader per concurrent operation.

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

This supports SQLite as the backend for explicit stored discovery. It does **not** establish equivalence for live selection, smart collections, arbitrary settings conversions, or unsaved edits. Existing live commands therefore retain AppleScript; adding `--database` selects SQLite explicitly. There is no silent fallback from an explicit database path to the current document, which could be a different Catalog or Session. On a schema rejection, use native commands only after independently verifying that the intended document is open. An automatic fallback needs an explicit live/stored result contract and qualified scope translation before it can be safe.

Reproduce with `scripts/benchmark-catalog.py` and `scripts/qualify-catalog-reader.py`; both require the matching disposable Catalog already open and perform read-only native calls sequentially. The benchmark does not run competing AppleScript calls. This small-fixture measurement is not a large-Catalog scaling claim or a screen-lock/load matrix.

## Qualification and Session assessment

`make check` includes synthetic records built from the real schema, preserving duplicate image variants, both membership kinds, rating filters, path uncertainty, changed-schema/type rejection, row limits, lock failure, concurrent reads, committed/uncommitted WAL visibility, backup integrity, overwrite/symlink protection, and CLI/MCP parity. The read-only [native comparison](qualification/catalog-reader/native-comparison.json) checks the local Catalog's combined exposure/contrast/saturation, an explicit image collection, and an archive read while the original document remains open. Its fixture values and omitted scopes are recorded in the evidence.

A local 16.8.5.30 Session database has similarly named tables and stored image/variant/layer rows. That does not qualify Session completeness: Session folder discovery and settings-sidecar behavior need separate native comparisons. Session paths and Session document types remain rejected. No mutation dispatch, journaling, restart, or reconciliation behavior changed; live recovery fault suites are not applicable to this reader work.
