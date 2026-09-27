# Agent guide: using c1 with Capture One

For agents that drive Capture One through the `c1` CLI or the `c1-mcp` MCP server.
Read it before the first call. The [README](README.md) is the human overview.

## Install and connect

From a release archive, extract it and keep its `bin` directory intact:
`c1_CaptureOneCore.bundle` must stay beside `c1` and `c1-mcp`. In a source
checkout, `make build install` installs all three.

Configure the MCP client to launch the server over stdio, with an absolute path:

```json
{"mcpServers": {"c1": {"command": "/absolute/path/to/bin/c1-mcp"}}}
```

The host application needs macOS Automation permission for Capture One; on
`permission-denied`, ask the photographer to allow it under **System Settings →
Privacy & Security → Automation**. Settings are environment variables of the CLI
process or the MCP server's `env`, and the server must restart to see changes:

| Variable | Effect |
|---|---|
| `C1_CATALOG_WRITE_PATH` | Enables edits in exactly this open Catalog (invariant 5; [path rules](docs/reference/editing.md#catalog-editing)). The photographer sets it. |
| `C1_TOOL_PROFILE=composition` | Limits the agent to crop, rotation, keystone and inspection. |
| `C1_ALLOW_UNTESTED_BUILD=1` | Allows a Capture One build outside 16.4–16.x; it does not qualify that build. |

Then check the connection: `doctor` must report `allChecksPassed`, `writesEnabled`
and `exactBuildMatched` before any edit. Capture One 16.8.5.30 is the only
qualified build. `c1 schema` / the MCP `schema` tool is the exact contract.

## Safety invariants

These rules protect existing photo edits and the Capture One database. This is
their only statement; the reference docs link here.

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
lens correction to pass a bounds check. See the [geometry reference](docs/reference/geometry.md).

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
