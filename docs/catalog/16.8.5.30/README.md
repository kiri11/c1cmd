# Experimental catalog editing — Capture One 16.8.5.30

The opt-in is restricted to **referenced originals outside the catalog package**. Catalog-stored originals remain blocked. This is a development extension, not a replacement for the retained Session release qualification or a claim of general main-catalog safety.

## Scope

Set `C1_CATALOG_WRITE_PATH` to one absolute catalog package/database path. Use one open document and sequential calls. Use `variant_edit` to bind existing variants for tonal and geometry edits; cloning is optional. Deletion remains limited to managed clones. `doctor.writesEnabled` reports the active editing gate, while `isSession` remains a document-type flag. Back up a main catalog with Capture One before enabling it, and retain separate RAW backups. `c1` does not automatically create a backup.

Identity uses the database file inside the package, Capture One process lifetime, and parent-image path. `.c1` provenance/journals are per catalog. Default preview exports go to a sibling `<catalog>.c1-output` directory. A missing/unavailable catalog default output location is initialized there (or to the explicit preview override); a usable default is preserved. Preview also configures the reserved `c1-preview` recipe.

## Earlier clone-based validation results

These hashes and results describe the preceding contract 1.3.0 candidate. Current existing-variant validation is recorded in [the release authority](../../RELEASE_VALIDATION.md).

[Summary and payload hashes](summary.json), [packaged catalog workflow](catalog-results.json), [importer crash summaries](importer-crashes.json), and [live preview reconciliation](preview-reconciliation.json).

- **533/533** offline assertions, CLI/MCP contract 1.3.0, and composition-profile checks passed.
- Extracted archive layout/contract, Session CLI, Session MCP, geometry, and referenced-catalog CLI/MCP suites passed with build-tree resources hidden.
- The packaged catalog suite verified native backup creation, exact-path denial, original protection, edits, preview image content, full-frame cleanup, diff, default-output initialization/preservation, and unchanged RAW checksums. Scratch catalogs and exported previews are not retained; the JSON records their observed results.
- The full real-timeout/MCP-death recovery campaign was not rerun for this catalog extension. This report does not claim that broader qualification.

## Findings

- Referenced-image development workflow passed: CLI/MCP clone, set/add/reset, geometry state checks, crop preview, temporary full-frame clone cleanup, diff, baseline, deletion, and composition profile. Native catalog backup was created in the disposable fixture. Source adjustments, geometry, and RAW bytes stayed unchanged.
- Native `inside catalog` import repeatedly crashed Capture One 16.8.5.30 on macOS 26.6.2, including a fresh catalog containing only that import. The faulting stack included `-[MOImage setImportDate:]` and `-[POImporter insertNewImageWithInfo:]`. This happened during test setup before `c1` editing; no main catalog was opened. That import path is outside the public API, and its storage mode is blocked pending qualification.
- Preview initially returned `-43` (`Invalid process output folder`) with both internal and external recipe roots. Readback showed the catalog's default `output` was `missing value`. Initializing that prerequisite resolved the export failure; changing the recipe root alone did not. The failed operations were explicitly reconciled after application restart without retrying exports.
- Offline regressions cover opt-in mismatch, untested builds, path aliases, ambiguous/missing database files, database replacement inside an unchanged package, cross-catalog references, offline/unqualified storage, stale tonal/geometry tokens, journal blocking, restart reconciliation, and stale-reference rejection. Existing Session regressions remain in the same suite.

## Remaining limits

Catalog-stored originals, disconnected originals, large-catalog performance, concurrent/UI operators, network catalog storage, and same-file close/reopen within one launch are not qualified. Real 120-second Apple Event timeout and MCP-death campaigns remain retained Session evidence; catalog-specific coverage includes injected offline failures and live preview-error reconciliation. Photographer review is still required. Fresh-user Automation and signing/notarization gates remain unchanged.

Run `Tests/catalog_integration_test.py` with `C1_TEST_RAW_FIXTURE` and zero open documents; it copies the RAW into a disposable referenced-image catalog. `C1_CATALOG_EVIDENCE` selects a retained evidence directory. Failed runs retain their catalog and journal. The optional `C1_TEST_CATALOG_STORAGE=managed` fixture reproduces the blocked native importer case; do not run it during ordinary qualification.
