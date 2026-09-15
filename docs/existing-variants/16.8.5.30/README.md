# Existing-variant editing — Capture One 16.8.5.30

`variant_edit` saves the current five tonal adjustments and available geometry, binds the existing native ID to a `c1_edit_` reference, and creates no variant. `set`, `add`, `reset`, `geometry_set`, preview, and diff accept that reference. The default MCP profile exposes all supported adjustments. `geometry_restore` restores the saved crop/rotation under a fresh geometry precondition while retaining current tonal adjustments. Restore tone with an explicit `set` of reviewed baseline values; `reset` keeps its default-value semantics.

The photographer and agent take turns on the same variants. Native IDs alone do not authorize mutations, and existing editing references never authorize deletion. Cloning remains optional. References expire after application restart or database replacement; `.c1/editing.json` retains baseline evidence. Journal failures and uncertain operations block further writes until explicit restart-based reconciliation.

The final build passes **592 offline assertions**, shared contracts/profile checks, and packaged existing-variant workflows in Sessions and referenced catalogs. Each live fixture kept one five-star variant, created no duplicates, and ended at its saved tonal and geometry baselines. The final [expired-reference regression](expired-reference.json) rejects the old clone reference before native lookup.

## Scope

One open document, sequential exclusive calls, Capture One 16.8.5.30. Sessions and explicitly opted-in catalogs with online originals referenced outside the package are covered. Catalog-stored originals remain blocked after the earlier native importer crashes; no inside-catalog imports were attempted in this campaign. No main catalog was opened or modified.

## Geometry finding

Rotating the first variant changed Capture One's parent-image `dimensions` from approximately the unrotated image size to the rotated canvas size. The initial live run applied the requested crop but rejected the changing dimensions during readback, retaining a partial-failure journal. That disposable Session was explicitly reconciled after restarting Capture One; the failed command was not retried.

Geometry now reads intrinsic source dimensions through ImageIO for stable bounds and state hashes. The native dispatch precondition still verifies crop, rotation, orientation, flip, aspect-ratio setting, lens/keystone context, parent identity, and tonal state. If source dimensions cannot be read, geometry is unavailable while supported tonal editing remains available. Offline coverage simulates dimensions changing with first-variant rotation, unavailable source metadata, and successful tonal editing without geometry.

## Recovery harness finding

The first fault campaign observed the expected real 120-second tonal timeout and blocked subsequent writes, but Capture One did not finish quitting with the fixture open within 60 seconds. After closing that disposable Session, the application was restarted and the operation explicitly reconciled. [Retained shutdown/reconciliation evidence](shutdown-recovery.json) records this failed run separately. The harness now closes its owned Session before quitting and waits for the old process to end before reopening it. This does not retry the uncertain mutation or reuse its reference.

The second campaign passed both real 120-second tonal and geometry timeout cases. Preview timeout produced its JPEG, blocked writes, and reconciled after restart, but its old native ID was absent. The subsequent stale clone read exposed a late lifetime check, and the campaign stopped before MCP-client death. A later read-only reopen also showed reassigned native IDs. The final guard now rejects expired clone references before native lookup; existing editing references already did so. [Recovery results](recovery-results.json) retain the completed cases and the failure. **A full four-case recovery pass is not claimed for this extension.** Catalog-specific real timeout/client-death qualification remains incomplete.

## Validation

See [summary and payload hashes](summary.json), [observed existing-variant workflows](results.json), [check output](checks.log), [geometry regressions](geometry-regression.json), [catalog regressions](catalog-regression.json), and [dimension failure/reconciliation](dimension-recovery.json). The earlier clone-based catalog report remains historical evidence for its own payload.

Live tests use copied RAW fixtures and check byte-for-byte preservation. The existing-variant harness checks all five tonal setters, add/reset, stale tokens, crop/rotation, rendered preview association, restoration without overwriting later tone edits, photographer continuation on the same ID, catalog opt-out, baseline persistence, and no clone/delete events. The crop and grading examples default to existing variants; `--clone` explicitly requests separate proposals.

Reproduce with `make qualify C1_TEST_RAW_FIXTURE=/path/to/local.CR3 EVIDENCE_DIR=/new/evidence/path`, starting with zero open documents. Catalog-wide scale, simultaneous UI editing, network storage, same-file reopening within a launch, other app builds, fresh-user Automation, and signing/notarization remain outside this qualification.
