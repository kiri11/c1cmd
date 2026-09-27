# Release validation

Every push to `main` publishes a release. Live checks drive Capture One and
cannot run in GitHub CI, so run the checks your change requires locally,
**before pushing**. Usage is in the [README](../README.md). Historical validation
summaries belong in commit messages and issue comments, not in documentation.

## Run only what the change affects

Choose checks by changed behavior. Run only the affected live suites and fault
cases, reuse the current candidate archive, and skip unrelated matrices. Full
campaigns are required only when [qualifying a new Capture One build](#qualify-a-new-capture-one-build),
or when a shared change's impact cannot be narrowed. A release checkpoint alone
does not require another fault campaign.

| Change | Required checks |
|---|---|
| Documentation only | Syntax and link checks |
| Build/CI, unrelated features, test selection or reporting that leaves fault behavior unchanged | `make check`; no live faults |
| Native behavior or a live harness | `make check`, then `make qualify QUALIFY_SUITES="..."` with the affected suites |
| Dispatch, partial application, journaling, unresolved-write blocking, locks, timeouts, application lifetime, restart/reconciliation or stale references | The affected suites plus the affected [fault cases](#recovery-case-selection) |
| A new Capture One build | `make qualify QUALIFY_SUITES=all` plus `make qualify-recovery RECOVERY_CASES=all` |

Report the selected and omitted coverage, and any required live check that could
not run. Do not claim a focused pass covers the full campaign.

There are three validation targets:

| Command | Coverage |
|---|---|
| `make check` | Incremental debug build, offline assertions, Python tests, generated-resource drift, CLI/MCP contracts and profile restrictions |
| `make qualify [QUALIFY_SUITES="..."\|all]` | Release build, offline checks, relocated package/contracts, then the selected live suites (default `cli mcp existing`) |
| `make qualify-recovery [RECOVERY_CASES="..."\|all]` | Selected real faults, including compound edits, using an already-built current archive (default `all`) |

Regular suites are `cli mcp geometry lens perspective keystone catalog existing
inventory native recipes read-workflow`. They do not inject faults. `mcp` is a smoke test of the
MCP adapter (registration, error results, preview image content, one compile of
each AppleScript handler script per server process); the CLI suites cover tool
behaviour through the same dispatcher. `read-workflow` covers the accelerated browsing
handoff on owned Session and Catalog fixtures and waits for the 60-second Catalog
catch-up boundary.

### Recovery case selection

Run affected live faults when a change can affect recovery behavior; no separate
user request is required. Build a current archive with `make archive`, or reuse
the unchanged candidate from `make qualify`.

| Changed behavior | Relevant `RECOVERY_CASES` |
|---|---|
| Tonal dispatch or timeout | `tonal` |
| Rating/color tag dispatch or timeout | `metadata` |
| Expanded native properties/actions | `native native-action` |
| Crop/rotation dispatch or partial writes | `geometry`; add corrected-image paths when affected |
| Lens, perspective/movements or keystone | `lens`, `perspective`, `keystone` as affected |
| Preview export or completion detection | `preview mcp-death` |
| MCP process lifetime/cancellation around dispatch | `mcp-death` |
| Clone native-ID readback | `clone-readback` |
| Shared journal, locks, write blocking, restart/reconciliation or stale references | All affected paths; `all` when impact cannot be narrowed |
| Compound edits (`edit_apply` steps, parent reports) | `recipe:native recipe:native-action recipe:lens recipe:layer-color recipe:geometry recipe:mcp-death`; add `recipe:tonal` or `recipe:preview` when those steps change |
| Fault-harness pause, dispatch detection, shutdown, identity or recovery assertions | Cases using the changed behavior |
| Unrelated features, docs, build/CI or selection/reporting only | Focused offline checks; no live faults |

One list holds all nineteen cases. Generic cases are `clone-readback tonal
metadata native native-action geometry lens perspective keystone preview mcp-death`.
Compound-edit cases carry a `recipe:` prefix: `recipe:native recipe:native-action
recipe:lens recipe:layer-color recipe:tonal recipe:geometry recipe:preview
recipe:mcp-death`. Generic cases run first in one owned Session and compound cases
after them in another; evidence lands in `recovery/` and `recipe-recovery/` under
`EVIDENCE_DIR`. The default `all` runs every case. `recipe:layer-color` tests the
shared native deletion/readback context on a numbered layer; it does not enable
layers in recipes.

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
- Graceful native quit is unqualified. Recovery uses SIGTERM after closing an
  owned fixture by default; there is no automatic shutdown fallback. Production
  CLI/MCP commands never quit Capture One.
- Archives are ad-hoc signed. Fresh-user downloaded-artifact launch, Automation
  consent in the intended host, Developer ID signing/notarization, Intel and
  additional macOS versions remain separate distribution gates. A passing local
  campaign does not waive them.
- Metadata partial-write recovery and the full combination of corrected-geometry
  fault paths are not exhaustively qualified. A focused pass covers only its
  selected paths and exact candidate.

## Run live checks

Close all documents and reserve exclusive use of Capture One. Tests create their
own disposable Sessions/Catalogs; never qualify against a main Catalog. Do not run
offline core tests concurrently with live suites: both acquire the application
lock. Keep native calls sequential.

Set `C1_TEST_RAW_FIXTURE` to a preserved RAW outside the build tree and
`EVIDENCE_DIR` to a new ignored or external directory. For the regular catalog
suite, set `C1_TEST_CATALOG_LAYOUT=unpackaged` to exercise an unpackaged
disposable catalog; the default is `package`. Both layouts include existing-variant
rating/readback/restoration. Recipe results use `C1_RECIPE_EVIDENCE`. The native
suite also needs `C1_TEST_PEOPLE_FIXTURE`, a RAW with people.

Live recipe tests perform sequential native calls, independent clone verification
and previews. Recovery tests retain real 120-second Apple Event timeouts; five
timeout cases therefore require at least ten minutes before setup, verification
and restarts. Do not shorten timeouts or weaken preconditions to reduce test
duration; select fewer cases instead.

### Recovery settings

The recovery harness rejects an open document or a different application build.
It copies a RAW into a fresh Session under `.build/recovery-fixtures`.
`C1_RECOVERY_FIXTURE_PARENT` may name an absolute directory outside `/tmp` and
`/private/tmp`, without symlink aliases. Image-path spelling and fixture ownership
must match before mutations.

```sh
make archive
export C1_TEST_RAW_FIXTURE=/absolute/path/to/preserved.CR3
make qualify-recovery RECOVERY_CASES="native native-action recipe:native recipe:layer-color" \
  EVIDENCE_DIR=.build/qualification/native-recovery
```

The default shutdown mode `sigterm` closes only the owned Session, confirms zero
documents, rechecks the verified PID, then terminates that process; it tests
process-termination recovery, not graceful native quit. `C1_RECOVERY_SHUTDOWN_MODE=quit`
requests native quit instead; it is not dependable (a recent run's quit timed out
after 60 seconds). There is no automatic fallback. Both modes require old process exit and a
different PID before reopening. The scoped harness also waits for repeated
read-only CLI confirmation of the exact reopened document.

The harness pauses the verified PID with an independent resume watchdog and can
kill its own MCP child. The `caffeinate` wrapper prevents idle sleep. Keep actual
timeouts, ownership/identity checks and sequential execution. A pause races native
execution: an actual `-1712` verifies timeout handling but cannot prove which setter
executed. Reconciliation records observations, never historical success.

Failures stop without retry. A failed restart suppresses further cleanup Apple
Events; otherwise cleanup closes only its owned Session and restores hidden build
resources. Uncertain operations are never retried automatically, and uncertain
clones are never deleted or adopted. Inspect unresolved journals and end the old
application process before reconciliation. Restart alone does not clear write
blocking; explicitly inspect operation status. New fault paths need matching cases:
existing cases do not establish metadata-specific partial-write coverage, for example.

## Qualify a new Capture One build

Qualification is exact-build and machine-sensitive; adding a version string alone
does not qualify a build.

| Build | Behavior |
|---|---|
| Listed in `SessionController.testedBuilds` | `exactBuildMatched: true`; other doctor checks must still pass. |
| Unlisted 16.4+ through 16.x | Allowed with a compatibility warning; `exactBuildMatched: false`. |
| Below 16.4 or 17+ | Rejected unless `C1_ALLOW_UNTESTED_BUILD=1` is explicitly set. |

Compatibility and feature authorization are separate. Existing-variant editing,
geometry, metadata, Catalog writes, and native inventory filtering have their own
build gates. An override or a passing `doctor.allChecksPassed` does not qualify
those paths or bypass their restrictions. Check `writesEnabled` and
`exactBuildMatched` too.

1. Save the installed application's dictionary and compare it with the retained
   [SDEF](../sdef/16.8.5.30.sdef):

   ```sh
   sdef "/Applications/Capture One.app" > "sdef/<version>.sdef"
   diff -u sdef/16.8.5.30.sdef "sdef/<version>.sdef"
   ```

   Review property codes and ranges, clone/delete/process commands, crop bounds and
   keystone controls, ratings/tags, recipe behavior, and inventory predicates.
   Dictionary compatibility is only a starting point; native behavior needs testing.
2. Locate explicit build assumptions with
   `rg -n '16\.8\.5\.30|testedBuilds|pinnedBuild' Sources Tests probes`. Update the
   relevant guards, capability/schema declarations, and harness assertions together
   on the candidate branch. Those changes enable qualification; do not publish them
   as supported until the corresponding checks pass. Keep unsupported paths gated if
   coverage is incomplete.
3. Run the full campaign against one extracted candidate archive, each with a new
   evidence directory:

   ```sh
   make check
   export C1_TEST_RAW_FIXTURE=/absolute/path/to/preserved.CR3
   export C1_TEST_PEOPLE_FIXTURE=/absolute/path/to/preserved-people.CR3
   make qualify QUALIFY_SUITES=all EVIDENCE_DIR=/absolute/path/to/new-feature-evidence
   make qualify-recovery RECOVERY_CASES=all EVIDENCE_DIR=/absolute/path/to/new-recovery-evidence
   ```

   Verify native identity/count and RAW preservation, concurrency tokens, clone-only
   deletion, existing-variant baseline/restore, previews and coordinate mapping,
   geometry with lens/perspective corrections, keystone controls, every metadata
   value, Catalog opt-out, filtering, request progress and cancellation. A single RAW
   does not establish broad camera/lens coverage.
4. Update the tested-build registry and relevant feature gates only for demonstrated
   support, together with their tests and capability declarations. Update
   [current scope](#current-scope-and-remaining-gates) and support documentation.
   Rerun affected offline checks after final edits; if the runtime payload changes,
   validate affected native paths on the final archive.

## Evidence

Detailed `results.json`, event logs, journals, copied harnesses, source patches,
checksums and database snapshots are generated diagnostics. Save them under ignored
`.build/qualification` directories or external artifact storage; do not commit them,
RAWs, previews or disposable databases. Preserve failed runs and unresolved-operation
evidence until recovery is complete. Keep source RAWs outside disposable directories
and remove only owned, closed fixtures.

Retain the source revision, any source patch, archive/executable/resource and
harness hashes, application/OS/toolchain identity, selected/skipped suites, fixture
checksum and outcome. Put a concise summary and material limitations in the commit
message or issue. Maintained tests, scripts, examples and the exact-build SDEF remain
in source control.
