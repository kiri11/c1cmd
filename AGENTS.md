# AGENTS.md

Rules for agents that drive Capture One through `c1` (CLI) or `c1-mcp` (MCP), and
for agents changing this repository. Setup is in the [README](README.md).

## Safety invariants

These rules protect existing photo edits and the Capture One database. This is
their only normative statement; other documents link here.

1. **RAW files are immutable.** Write only through a `c1_edit_` editing reference
   (from `variant_edit`) or an agent-created `c1_wrk_` managed clone. A native ID
   alone never authorizes a write. Only agent-created clones can be deleted; never
   delete an existing variant to reject an edit.
2. **Every write carries its fresh state token plus the document token.**
   `variant_edit` takes `ifDocument` (the `doc_info` `openToken`) and `ifState`.
   Read `get` immediately before each write and pass the token for its scope:
   `ifState` (tonal), `ifGeometryState` (crop, rotation, keystone),
   `ifMetadataState` (rating, color tag) or a snapshot's `ifNativeState`. Tokens
   do not cover each other. On `state-changed`, read again and reconcile.
3. **The journal is written durably before dispatch.** Every dispatched write,
   including clone, delete, recipe setup and preview export, is recorded in
   `.c1/journal.jsonl` first. A failed journal write blocks dispatch; a corrupt
   journal or provenance fails closed. Keep `.c1` files; deleting evidence is not
   recovery.
4. **An uncertain outcome blocks all writes until restart and reconcile.** After a
   timeout or `outcome-unknown`, never repeat the command: use
   `operation_status <operationId>`. Restart Capture One, reopen the same database
   and check status again. Never retry, undo, resume or adopt a candidate clone
   automatically. `reconciled` records observations; it does not mean the write
   succeeded. Old references stay invalid, so prepare a fresh one.
5. **Catalog writes require the exact-path opt-in and the exact build, with a
   native backup taken first.** `C1_CATALOG_WRITE_PATH` must name the exact open
   Catalog and Capture One must be 16.8.5.30; only online referenced originals
   outside the Catalog are writable. Make a fresh **File → Backup Catalog** before
   main-Catalog work; RAW backups remain separate. Other Catalogs are read-only.
6. **One document, sequential calls, the advisory lock and identity checks.** Keep
   exactly one document open and make calls one at a time. During a workflow nobody
   edits in the UI, switches, reopens or replaces documents, or runs competing
   exports; photographer and agent take turns. Identity checks reject a changed
   document. Restart and database replacement invalidate references; same-file
   close/reopen within one launch is undetectable and therefore unsupported.
7. **Production commands never quit Capture One.** Only the recovery qualification
   harness shuts it down.
8. **Recipes are verified on a disposable clone, and a changed payload is verified
   again.** Registration never authorizes reuse. Verify the exact payload on an
   explicitly created managed clone and review its preview. Value checks are not
   aesthetic approval.
9. **Tests use owned disposable fixtures, real timeouts and sequential execution,
   and keep their evidence.** Never qualify against a main Catalog or shorten a
   timeout, and keep failed-run evidence until recovery is complete.
10. **Fault cases are mandatory for mutation and recovery changes; the full
    campaign is mandatory for a new build.** Changes to mutation dispatch,
    journaling, write blocking, locks, timeouts, application lifetime,
    restart/reconciliation or stale references need the affected live fault cases.
    A new Capture One build needs every suite and fault case.

## Canonical editing workflow

1. Run `doctor` and confirm `allChecksPassed`, `writesEnabled` and
   `exactBuildMatched`. Run `doc_info` and keep `openToken`.
2. List intended variants with `rating` or `minRating` (integers 0–5) and any
   collection/selection scope. Verify parent-image paths against the requested
   folder; one image can have several variants.
3. `get` each source, then `variant_edit` with `sourceRef`, `ifState`, `ifDocument`
   and, for crop proposals, `ifGeometryState`. Keep the returned `workingRef` and
   baselines. No variant is created.
4. `get` the editing reference immediately before each change and apply `set`,
   `add`, `reset`, `geometry_set`, `metadata_set`, `native_set` or `native_action`.
5. Inspect a fresh `preview` and `diff` against the saved baseline.
6. To reject a change, restore explicitly with fresh tokens: `geometry_restore`
   for geometry; `set` with `baselineAdjustments` for tonal values;
   `metadata_set` with `baselineMetadata`; `native_set` with a reviewed patch from
   the journal's `beforeNative`. `reset` applies defaults and is not an undo.
7. Hand back to the photographer, who continues on the same variant.

Use `variant_clone` only when a separate comparison variant is wanted, and delete
it with `variant_delete` after review. For long browsing batches, the optional
[read workflow](docs/reference/catalog-reader.md#controlled-browsing-workflow)
serves cached reads; it never supplies mutation tokens, so read `get --live`
before preparing an edit.

## Crop policy

Use 3:2 (`aspectRatio` 1.5) for horizontal and 3:4 (0.75) for vertical pictures.
Straighten credible horizons and lines with rotation, and apply keystone only when
credible straight lines establish the correction. Preserve interesting
composition; do not level natural diagonals. Flag ambiguous perspective and ratio
exceptions for review; an unchanged proposal is not acceptance. After rotation or
keystone, inspect a fresh preview before choosing an explicit crop. Never disable
lens correction to pass a bounds check. `C1_TOOL_PROFILE=composition` restricts an
agent to geometry. See the [geometry reference](docs/reference/geometry.md).

## Compact results

Mutation, recipe and preview results are compact by default: IDs, changed fields,
new state tokens, coverage, status, the preview path and `evidencePath`, a file
holding the complete result. Read that file or pass `--full` / `full: true` for
before/after values. Errors, uncertain outcomes and failed or interrupted compound
edits are never compacted. Evidence files are review aids; the journal remains the
recovery record. See [compact results](docs/reference/editing.md#compact-results).

## Reference

[Editing](docs/reference/editing.md) (adjustments, selection, progress, previews,
recovery commands, error codes), [geometry](docs/reference/geometry.md),
[native editing](docs/reference/native-editing.md),
[recipes](docs/reference/recipes.md) and the
[Catalog reader](docs/reference/catalog-reader.md).

Changing this repository: a push to `main` publishes a release, and live checks
cannot run in GitHub CI. Run the checks the [maintainer guide](docs/MAINTAINING.md)
requires locally before pushing.

## Agent skills

### Issue tracker

Issues live in GitHub Issues on kiri11/c1cmd, managed with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary: needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one root `CONTEXT.md` plus `docs/adr/`, created lazily. See `docs/agents/domain.md`.
