# Release validation

This guide defines current support limits and test selection. Usage is in the
[README](../README.md); new application builds follow the
[qualification guide](QUALIFYING_NEW_BUILDS.md). Historical validation summaries
belong in [CHANGELOG.md](../CHANGELOG.md), not in the usage documentation.

## Current scope and remaining gates

Capture One **16.8.5.30 on Apple Silicon** is the supported application build.
Use one open document and sequential calls, without UI edits, document switching
or competing exports. Existing variants are editable through `c1_edit_` references;
only agent-created managed clones can be deleted.

Sessions support tonal editing, crop/rotation, keystone, ratings, color tags,
[expanded native editing](native-editing/README.md) and
[reference recipes](recipes/README.md). Catalogs are read-only by default;
exact-path opt-in enables experimental editing of online referenced originals
outside the Catalog directory. Both `.cocatalog` packages and unpackaged directories
have regular CLI/MCP coverage; unpackaged writes require the exact `.cocatalogdb`
opt-in. The latest unpackaged run passed; the package regression run stopped at
an uncertain native default-baseline creation (variant-ID readback error). Catalog-stored originals and Catalog fault recovery remain unqualified.

Other limits:

- Native dictionary availability does not establish exhaustive runtime support.
  Mask pixels cannot be read, hashed or restored. Recipes exclude layers/masks,
  Skin Tone, installed styles and profile installation; profile identities are
  observed native names, not hashes of external profile files.
- Camera/lens and geometry qualification is fixture-specific. Flips,
  crop-outside-image and broad camera/lens coverage remain outside qualification.
  Each changed recipe needs registration, independent disposable-clone verification
  and visual review; implementation does not qualify a complete photographic look.
- Same-file close/reopen within one application launch is not reliably detectable.
  Application restart and database replacement invalidate working references.
  Concurrent operators and arbitrary live database replacement are unsupported.
- Preview association requires exclusive output ownership. State hashes are not
  complete render fingerprints. General export and callback coexistence are outside
  scope. Successful value checks do not establish aesthetic quality.
- Graceful native quit is unqualified. Recovery can explicitly select SIGTERM after
  closing an owned fixture; there is no automatic shutdown fallback. Production
  CLI/MCP commands never quit Capture One.
- Archives are ad-hoc signed. Fresh-user downloaded-artifact launch, Automation
  consent in the intended host, Developer ID signing/notarization, Intel and
  additional macOS versions remain separate distribution gates.
- Metadata partial-write recovery and the full combination of corrected-geometry
  fault paths are not exhaustively qualified. A focused pass covers only its
  selected paths and exact candidate.

## Validation policy

Choose checks by changed behavior. Do not run offline core tests concurrently
with live suites: both acquire the application lock. Keep native calls sequential.

| Command | Coverage |
|---|---|
| `make check` | Incremental debug build, offline assertions, Python tests, generated-resource drift, CLI/MCP contracts and profile restrictions |
| `make qualify` | Release build, offline checks, relocated package/contracts, then `cli mcp existing` |
| `make qualify QUALIFY_SUITES="native recipes"` | Only the selected regular matrices after package checks |
| `make qualify-extended` | All eleven regular live suites |
| `make qualify-recovery RECOVERY_CASES="..."` | Selected real faults using an already-built current archive |
| `make qualify-recipes-recovery RECIPE_RECOVERY_CASES="..."` | Selected compound-edit faults using the current archive |
| `make qualify-full` | All regular suites plus the generic recovery campaign; select recipe recovery separately when affected |

For the regular catalog suite, set `C1_TEST_CATALOG_LAYOUT=unpackaged` to exercise
an unpackaged disposable catalog; the default is `package`. Both layouts include
existing-variant rating/readback/restoration. These runs do not inject faults.

Regular selections are `cli mcp geometry lens perspective keystone catalog existing
inventory native recipes`. Set `C1_TEST_RAW_FIXTURE` to a preserved RAW outside the
build tree and `EVIDENCE_DIR` to a new ignored or external directory. Recipe results
use `C1_RECIPE_EVIDENCE`; use `C1_RECIPE_TEST_GROUP=scopes` when only the scoped
recipe block is affected. Its default `all` includes version-1 cases too.

Routine offline checks do not run Capture One fault injection. Live recipe tests
perform sequential native calls, independent clone verification and previews.
Recovery tests retain real 120-second Apple Event timeouts; five timeout cases
therefore require at least ten minutes before setup, verification and restarts.
Do not shorten timeouts or weaken preconditions to reduce test duration. Reuse a
current candidate archive and skip unrelated suites instead.

Documentation-only changes require syntax/link checks. Report selected and omitted
coverage and any required live checks that could not run. Release checkpoints alone
do not require another fault campaign.

## Recovery test selection

Run affected live faults when dispatch, partial application, unresolved-write
blocking, application lifetime or recovery behavior changes. No separate user
request is required. Build a current archive with `make archive`, or reuse the
unchanged candidate from `make qualify`.

| Changed behavior | Relevant `RECOVERY_CASES` |
|---|---|
| Tonal dispatch or timeout | `tonal` |
| Expanded native properties/actions | `native native-action` |
| Crop/rotation dispatch or partial writes | `geometry`; add corrected-image paths when affected |
| Lens, perspective/movements or keystone | `lens`, `perspective`, `keystone` as affected |
| Preview export or completion detection | `preview mcp-death` |
| MCP process lifetime/cancellation around dispatch | `mcp-death` |
| Clone native-ID readback | `clone-readback` |
| Shared journal, locks, write blocking, restart/reconciliation or stale references | All affected paths; `all` when impact cannot be narrowed |
| Fault-harness pause, dispatch detection, shutdown, identity or recovery assertions | Cases using the changed behavior |
| Unrelated features, docs, build/CI or selection/reporting only | Focused offline checks; no live faults |

Compound recovery accepts `native native-action lens layer-color tonal geometry
preview mcp-death`. `layer-color` tests the shared native deletion/readback context
on a numbered layer; it does not enable layers in recipes. Select these through
`RECIPE_RECOVERY_CASES`, independently of the generic recovery selector.

## Reproduce packaged live recovery qualification

Close all documents and reserve exclusive use of Capture One. The harness rejects
an open document or a different application build. It copies a RAW into a fresh
Session under `.build/recovery-fixtures`. `C1_RECOVERY_FIXTURE_PARENT` may name an
absolute directory outside `/tmp` and `/private/tmp`, without symlink aliases.
Image-path spelling and fixture ownership must match before mutations.

```sh
make archive
export C1_TEST_RAW_FIXTURE=/absolute/path/to/preserved.CR3
make qualify-recovery RECOVERY_CASES="native native-action" \
  C1_RECOVERY_SHUTDOWN_MODE=sigterm \
  EVIDENCE_DIR=.build/qualification/native-recovery
make qualify-recipes-recovery \
  RECIPE_RECOVERY_CASES="native native-action lens layer-color geometry mcp-death" \
  C1_RECOVERY_SHUTDOWN_MODE=sigterm \
  EVIDENCE_DIR=.build/qualification/recipe-recovery
```

The default shutdown mode `quit` requests native quit. Explicit `sigterm` closes
only the owned Session, confirms zero documents, rechecks the verified PID, then
terminates that process. There is no automatic fallback. Both modes require old
process exit and a different PID before reopening. The scoped harness also waits
for repeated read-only CLI confirmation of the exact reopened document.

The harness pauses the verified PID with an independent resume watchdog and can
kill its own MCP child. The `caffeinate` wrapper prevents idle sleep. Keep actual
timeouts, ownership/identity checks and sequential execution. A pause races native
execution: an actual `-1712` verifies timeout handling but cannot prove which setter
executed. Reconciliation records observations, never historical success.

Failures stop without retry. A failed restart suppresses further cleanup Apple
Events; otherwise cleanup closes only its owned Session and restores hidden build
resources. Uncertain clones are never automatically deleted or adopted. Inspect
unresolved journals and end the old application process before reconciliation.
Restart alone does not clear write blocking; explicitly inspect operation status.

## Diagnostic artifacts

Detailed `results.json`, event logs, journals, copied harnesses, source patches,
checksums and database snapshots are generated diagnostics. Save them under ignored
`.build/qualification` directories or external artifact storage; do not commit them
to docs. Preserve unresolved-operation evidence until recovery is complete. Keep
source RAWs outside disposable directories and remove only owned, closed fixtures.

For release review, record the source revision, archive/executable/resource hashes,
application/OS/toolchain identity, selected/skipped suites, fixture checksum and
outcome. Put a concise historical summary and material limitations in `CHANGELOG.md`.
Maintained tests, scripts, examples and the exact-build SDEF remain in source control.
