# Upgraded Catalog stored-reader qualification

The upgraded schema with raw fingerprint
`f7f6e8f56cafa1c26fb1a6e5e13a0218fc905fec691efbf754ce546482ca2475`
is qualified for stored, read-only discovery. The [packaged evidence](upgraded-packaged.json)
records build/schema hashes and completed checks. Local paths, library names,
record counts, and execution timestamps are deliberately omitted.

## Schema and history contract

The earlier investigation understated the differences: besides SQLite statistics
tables and formatting, two tables reorder columns. `ZVARIANTLAYER` moves
`ZRETOUCHINGOPACITY` and `ZRETOUCHINGBLEMISHPROTECTIONMASKUUID` before the two
teeth-whitening fields; `ZRETOUCHINGLAYER` moves `ZOPACITY` before the teeth-whitening
fields. Complete column/constraint clauses, SQLite column metadata (excluding
ordinal position), foreign keys, and index metadata were compared with the original
retained schema. No additional differences were found in the application objects.

Reader projections use explicit column names; raw `SELECT *` results are mapped
using `sqlite3_column_name`, not fixed column positions. Distinct synthetic sentinel
values verify that reordered fields retain their names and values. The additional
manifest retains the exact observed column order; other permutations remain rejected.

The manifest also retains these exact `(version, compatibleVersion, format)` rows,
ordered by `Z_PK`:

| Version | Compatible version | Format |
| --- | --- | --- |
| 1650 | 1650 | 16.5.1.2546 Enterprise Win |
| 160611 | 160611 | 16.7.1.11 Studio Mac |
| 160611 | 160611 | 16.7.1.11 Pro Mac |
| 160800 | 160800 | 16.8.5.30 Pro Mac |

This qualifies the observed tuple sequence, not a general interpretation of Capture
One migration history. The original schema still requires its original single-row
history. Changed, missing, reordered, duplicated, and future entries are rejected;
histories cannot be mixed between the two manifests. Document type and UUID checks,
transaction boundaries, deadlines, result limits, and mutation authorization are unchanged.

The manifest excludes the two standard statistics definitions from its retained
application schema and records both the application-schema fingerprint and the raw
source fingerprint. Responses continue to report the raw observed fingerprint.

## Completed checks

- `make check`: 1,187 core assertions, Python offline suites, and CLI/MCP contracts passed.
- All 20 Catalog reader tests passed again against binaries extracted from the release
  archive, including reordered-field sentinels, exact-history rejection, CLI/MCP
  parity, WAL visibility, concurrent reads, and snapshot integrity/overwrite guards.
- Read-only qualification against a large Catalog compared sampled variants through
  both packaged CLI and MCP, including variants represented in its retouching table. Every returned image, variant, settings,
  metadata, and retouching value matched independent Python SQLite reads.
- An explicit collection matched independently expanded image/variant
  membership and stored rating/color-tag values. Exact-rating filtering matched.
- Unfiltered inventory hit the existing 10,000-row guard and returned no partial
  stdout. Source device/inode, size, and modification time were unchanged.

The evidence contains check results and build/schema hashes, not library sizes,
photograph paths, settings, or identifiers. Reproduce
using binaries extracted together with their resource bundle from the candidate archive:

```sh
python3 -B scripts/qualify-upgraded-schema.py \
  --cli /absolute/path/to/package/bin/c1 \
  --mcp /absolute/path/to/package/bin/c1-mcp \
  --database '/absolute/path/to/library.cocatalogdb' \
  --output /absolute/path/to/new-evidence.json
```

## Coverage limits

The actual database was opened with `mode=ro` and `query_only`; no Capture One calls,
Catalog/RAW mutations, application restarts, or main-Catalog copies were performed.
Actual-data checks are bounded samples and one collection, not exhaustive reader
validation of every photograph. Snapshot/WAL coverage uses synthetic fixtures.

This does not establish equivalence with unsaved native state, freshness, native
editing support, mask reconstruction, or support for other history sequences or
schemas. Native mutation and recovery fault suites were omitted because no mutation,
dispatch, journal, timeout, restart, or reconciliation behavior changed. Full Catalog
inspection and unfiltered inventories can still exceed the existing result limits.
