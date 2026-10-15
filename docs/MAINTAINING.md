# Maintainer guide

Validation, release, new-build qualification and profiling. This is the only place
that states validation rules. Usage is in the [README](../README.md); the test
invariants are in [AGENTS.md](../AGENTS.md#development-invariants). Historical
validation summaries belong in commit messages and issue comments, not in
documentation.

## Releases

Every push to `main` publishes a release. The release workflow builds release
once, runs its unit tests, harnesses and packaged CLI/MCP checks, then publishes
the archive and SHA-256 checksum. Tags are the UTC date plus a daily sequence
(`YYYY-MM-DD-01`, `-02`, …); runs are queued so numbering stays unique, and each tag
points to the commit that triggered it. CI runs `make check` on pushes and pull
requests. Live checks drive Capture One and cannot run in GitHub CI, so run the
checks a change requires locally, **before pushing to `main`**.

Architecture: CLI / MCP → shared contract and `CaptureOneCore` → typed AppleScript
executor → bundled handlers → Capture One. The executor is injectable for
deterministic fault tests. Style learning and review policy belong in a separate
repository that uses the public interface, not internal `.c1` files.

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

The runner lists selected and skipped suites and cases. Regular suites are
`cli mcp geometry lens perspective keystone catalog existing inventory native
recipes read-workflow`. They do not inject faults. `mcp` is a smoke test of the
MCP adapter (registration, error results, preview image content and its
`inlineImage` opt-out, one compile of each AppleScript handler script per server
process); the CLI suites cover tool behaviour through the same dispatcher.
`read-workflow` covers the accelerated browsing handoff on owned Session and
Catalog fixtures and waits for the 60-second Catalog catch-up boundary.

| Area | Suites |
|---|---|
| Tonal, metadata, clone and existing-variant editing | `cli mcp existing` |
| Geometry, bounds and stored-crop proposals | `geometry lens perspective keystone` as affected |
| Native editing | `native` |
| Recipes and compound edits | `recipes` |
| Catalog reader and read workflow | `catalog read-workflow` |
| Inventory, progress and cancellation | `inventory` |

During development, individual suites run directly, for example
`python3 Tests/geometry_integration_test.py` or
`C1_INVENTORY_EVIDENCE=/private/tmp/inventory.json python3 Tests/inventory_integration_test.py`.
`C1_TEST_BIN` and `C1_TEST_MCP_BIN` select extracted release binaries. Run
`mcp_test.py` sequentially, never alongside a CLI suite.

### Recovery case selection

Run affected live faults when a change can affect recovery behavior; no separate
user request is required. Build a current archive with `make archive`, or reuse
the unchanged candidate from `make qualify`.

| Changed behavior | Relevant `RECOVERY_CASES` |
|---|---|
| Tonal dispatch | `tonal` |
| Apple Event timeout handling, the `-1712` mapping or timer values | `timeout recipe:tonal` |
| Rating/color tag dispatch | `metadata` |
| Expanded native properties/actions | `native native-action` |
| Crop/rotation dispatch or partial writes | `geometry`; add corrected-image paths when affected |
| Orientation dispatch or timeout | `orientation`; add `geometry` when the shared geometry handlers change |
| Lens, perspective/movements or keystone | `lens`, `perspective`, `keystone` as affected |
| Variant clone or delete dispatch | `clone delete` |
| Clone native-ID readback | `clone-readback` |
| Preview export, completion detection or late-preview resolution | `preview late-preview mcp-death`; add `recipe:preview recipe:late-preview` for compound previews |
| Save-stall detection | `save-stall` |
| MCP process lifetime/cancellation around dispatch | `mcp-death` |
| Probe-barrier coverage (which kinds `operation status` reconciles without a restart) or the barrier probe | `barrier` plus the cases of every kind whose coverage changed |
| Shared journal, locks, write blocking, restart/reconciliation or stale references | All affected paths; `all` when impact cannot be narrowed |
| Compound edits (`edit_apply` steps, parent reports) | `recipe:native recipe:native-action recipe:lens recipe:layer-color recipe:geometry recipe:mcp-death`; add `recipe:tonal`, or `recipe:preview recipe:late-preview`, when those steps change |
| Fault-harness pause, interruption, dispatch detection, shutdown, identity or recovery assertions | Cases using the changed behavior |

One list holds all twenty-seven cases. Generic cases are `clone-readback tonal
timeout metadata native native-action geometry orientation lens perspective
keystone clone delete preview late-preview save-stall mcp-death`. Compound-edit
cases carry a `recipe:` prefix: `recipe:native recipe:native-action recipe:lens
recipe:layer-color recipe:tonal recipe:geometry recipe:preview
recipe:late-preview recipe:mcp-death`. The `barrier` case runs first, then the
generic cases, then the compound cases; each group owns its Session, and
evidence lands in `barrier/`, `recovery/` and `recipe-recovery/` under
`EVIDENCE_DIR`. The default `all` runs every case. `recipe:layer-color` tests the
shared native deletion/readback context on a numbered layer; it does not enable
layers in recipes.

#### How fault cases interrupt and resolve

Each case is a row in the harness case table: the command, how the write is
interrupted, and how the uncertain outcome resolves.

| Case | Interruption | Resolution |
|---|---|---|
| `tonal metadata native native-action geometry orientation lens perspective keystone clone delete` | Kill | Barrier |
| `recipe:native recipe:native-action recipe:lens recipe:layer-color recipe:geometry` | Kill | Barrier |
| `timeout` | Real 120-second timeout | Restart |
| `recipe:tonal` | Real 120-second timeout | Barrier |
| `preview recipe:preview` | Preview deadline (generic) or kill (compound) | Restart |
| `late-preview recipe:late-preview` | Preview deadline | Late preview |
| `save-stall` | Backdated database | Restart |
| `mcp-death recipe:mcp-death` | Kill the MCP server | Restart for preview; barrier or restart by the coverage of the pending compound step |

- **Kill.** Once the pending journal entry appears, the harness pauses Capture
  One, kills the `c1` caller, asserts that it died by `SIGKILL` without a reply and
  that the operation is still `pending`, then resumes Capture One. Process death
  releases the lock. No timeout is shortened.
- **Real timeout.** `timeout` and `recipe:tonal` keep `c1`'s shipped 120-second
  Apple Event timeout. They are the only cases that cover the shipped `-1712` path:
  the journal's `outcome-unknown` entry and the compound report's mapping to
  `outcome-unknown`. A shortened timeout would change which timer fires first, so
  these cases keep the real value.
- **Barrier.** `operation status` must return `reconciled` with
  `resolution: probe-barrier` while the Capture One PID stays the same. The old
  working reference must still resolve, and its fresh read must equal the recorded
  after-state, both at once and again two seconds later. For `clone`, the recorded
  `observedVariantIds` must equal the new siblings; nothing is adopted.
- **Restart.** For a kind the barrier covers, the harness calls no status before
  the restart, because that call would reconcile by barrier. For a preview it reads
  the journal instead, because a status call could resolve a landed JPEG first. For
  another uncovered kind, such as a save-stalled write, status must stay unresolved
  and append nothing. After the
  restart, status must return `resolution: restart` and the old reference
  `document-changed`.

Every case also checks that a blocked write appends nothing, that native
identities stay the same, that the original variant and RAW stay untouched, and
that a fresh clone accepts writes.

The kill path has the same limitation as the pause before it: an external pause
still races the handler, so the pause can land before the write is sent or between
two setters. It cannot show which Apple Event was in flight. The deterministic
evidence for the barrier comes from the `barrier` case.

#### The barrier case

`barrier` qualifies the premise behind barrier resolution: once a later Apple
Event gets an answer, an earlier write whose sender timed out has finished. It
sends raw Apple Events from `osascript`, does not use `c1`, and never restarts
Capture One. It needs `C1_TEST_PEOPLE_FIXTURE` as well as `C1_TEST_RAW_FIXTURE`.
`C1_BARRIER_TRIALS` sets the queued trials per kind (default 3). Run it when you
qualify a new build, and when barrier coverage or reconciliation changes.

- **Queued mode.** The harness pauses Capture One and sends the write with a
  3-second instrument timeout, which must return `-1712` to prove the write is
  queued. It then sends a probe from another process and resumes. Every trial must
  answer the probe, land the write, and read the final state as soon as the probe
  answers. The watch window is 5 seconds, or 15 seconds for AI kinds and the
  control.
- **Running mode.** For the subject mask and people mask, the writer times out
  after 2 seconds while Capture One executes. The barrier must hold for every trial
  that timed out. A people mask often finishes within 2 seconds, so its running
  trials can all be uninformative; check `informative` in `summary.json`.
- **Control.** An export through a recipe owned by the case's fixture must break
  the barrier at least once, or the case fails, because the method must be able to
  detect a failure. The case deletes only its own uniquely named recipe.

Each write mirrors the statement the production handler sends: exposure, rating,
color tag, clarity, rotation, crop, lens distortion, keystone, `layer.create`,
`layer.delete`, `color.create`, `color.delete`, `dehaze.pick`,
`dehaze.recalculate`, `lens.reset`, `luma.clear`, `style.apply` (with a runtime
style that changes a fresh layer's exposure), baseline, clone, variant delete,
subject mask layer, `mask.people`, and mask clear, fill, invert, copy and
rasterize, which are observed through the layer kind.
Mask feather and refine change no scriptable property, so they cannot be qualified
and stay restart-only. `events.jsonl` keeps every trial and `summary.json` keeps
the per-kind counts. With the default 3 trials, the case takes about 18 minutes.

`save-stall` makes a clone and a tonal write, waits until Capture One has saved
them, then backdates the Session database file as a stand-in for a stalled save
and makes no write for five minutes. `doctor` must then report both writes in
`saveStall` with `save-stalled`, block the next write, and lift the block only
after a restart and reconciliation of both. A database write during the wait
fails the case. It takes about seven minutes.

`late-preview` and
`recipe:late-preview` let a 0.001-second preview timeout expire without pausing
Capture One, wait for the JPEG, and require operation status to resolve it as
`late-preview` in the same Capture One process, with no unresolved operations and
a fresh write on the same reference. The compound case also requires `edit_status`
to keep the parent `outcome-unknown`.

`orientation` interrupts two orientation writes on uncorrected clones: 90 with a 3:4
ratio, which c1 plans before dispatch and journals as `intendedGeometry`, and 90
alone, which keeps Capture One's turned crop and journals only `requestedGeometry`.
They reach the native orientation setter through the two geometry handlers. The
`edit_apply` geometry step calls the same write, so `recipe:geometry` covers its
compound reporting and there is no `recipe:orientation` case.

## Current scope and remaining gates

Capture One **16.8.5.30 on Apple Silicon** is the supported application build.
Sessions support tonal editing, crop/rotation, keystone, ratings, color tags,
[expanded native editing](reference/native-editing.md) and
[reference recipes](reference/recipes.md). Catalogs are read-only by default;
exact-path opt-in enables experimental editing of online referenced originals
outside the Catalog directory. Both `.cocatalog` packages and unpackaged directories
have regular CLI/MCP coverage; unpackaged writes require the exact `.cocatalogdb`
opt-in. Native editing, including layers, color bands and people masks, has owned
referenced-original coverage in both layouts. Recipe capture, registration,
managed-clone verification and compound application also have coverage in both,
including scoped recipes and single-pixel readback. Filtered inventories use native
rating predicates and bulk ID reads in both document kinds, qualified against the
legacy enumeration on owned album, selection and document scopes in both layouts.
AppleScript `add inside` adds every variant the image has at that moment, not only
the named ones: on 16.8.5.30, adding one variant of a four-variant image stored
variant rows for all four plus an image row, and the album listed all four. A
variant created later joins only when it is created with the album current. The
inventory album therefore holds every variant of one image and none of a second
image. Image-level album entries made in the UI are not covered by the live suite.
Catalog-stored originals and Catalog fault recovery remain unqualified. Package
Catalog default-baseline creation remains a qualification gap after uncertain
native-ID readback.

Other limits:

- Native dictionary availability does not establish exhaustive runtime support.
  Mask pixels cannot be read, hashed or restored. Recipes exclude layers/masks,
  Skin Tone, installed styles and profile installation; profile identities are
  observed native names, not hashes of external profile files.
- Camera/lens and geometry qualification is fixture-specific. Flips,
  crop-outside-image and broad camera/lens coverage remain outside qualification.
  The full lens/perspective suites have not run in Catalogs. Implementation does
  not qualify a complete photographic look.
- Concurrent operators and arbitrary live database replacement are unsupported.
- Preview association requires exclusive output ownership. State hashes are not
  complete render fingerprints. General export and callback coexistence are outside
  scope. Successful value checks do not establish aesthetic quality.
- Graceful native quit is unqualified; the recovery harness uses SIGTERM.
- Archives are ad-hoc signed. Fresh-user downloaded-artifact launch, Automation
  consent in the intended host, Developer ID signing/notarization, Intel and
  additional macOS versions remain separate distribution gates. A passing local
  campaign does not waive them.
- Metadata partial-write recovery and the full combination of corrected-geometry
  fault paths are not exhaustively qualified. A focused pass covers only its
  selected paths and exact candidate.

## Run live checks

Close all documents and reserve exclusive use of Capture One. Tests create their
own disposable Sessions/Catalogs under `/private/tmp` or `.build`. Read an open
database only through `Tests/stored_read.py` or c1's stored reads: a SQLite read
lock across a save makes Capture One drop its changes for good
([save stalls](reference/editing.md#save-stalls)), and `Tests/stored_read_test.py`
rejects locking readers. Do not run
offline core tests concurrently with live suites: both acquire the application
lock.

Set `C1_TEST_RAW_FIXTURE` to a preserved RAW outside the build tree and
`EVIDENCE_DIR` to a new ignored or external directory. For the regular catalog
suite, set `C1_TEST_CATALOG_LAYOUT=unpackaged` to exercise an unpackaged
disposable catalog; the default is `package`. Both layouts include existing-variant
rating/readback/restoration. Recipe results use `C1_RECIPE_EVIDENCE`. The native
suite also needs `C1_TEST_PEOPLE_FIXTURE`, a RAW with people. The geometry suite
adds import and orientation checks for a vertical frame when
`C1_TEST_PORTRAIT_FIXTURE` names a RAW with EXIF orientation 6.

For `native`, `recipes` and `inventory`, `QUALIFY_DOCUMENT_KINDS` selects `session`
(default), `catalog`, or `"session catalog"`. Each mode runs sequentially with separate
evidence under `native/<mode>`, `recipes/<mode>` and `inventory/<mode>.json`; Catalog
mode is labelled `catalog-package` or `catalog-unpackaged`. Other suites keep their
own fixture modes. Catalog mode creates a new owned Catalog under `.build`, imports a
copied RAW as a referenced original outside it, sets the exact fixture write path (the
`.cocatalogdb` for unpackaged), and takes a native backup before editing. It asserts
RAW preservation and the Catalog's `.c1` journal/provenance/result locations and
sibling `.c1-output/c1-previews` paths. Failed fixtures and evidence are retained,
and the failed suite then closes its owned document so later suites can start; the
catalog suite first copies the stored database to `failed-before-close.cocatalogdb`.
The native suite uses a second owned fixture for the successful people-mask cases.

The inventory suite imports a second image, clones the first image's variant up to
`C1_INVENTORY_SMALL_COUNT` (default 12) and `C1_INVENTORY_LARGE_COUNT` (default 120)
variants, adds every third variant of the first image to an album, which then lists
every variant of that image, and selects every second variant. Each case runs the default
strategy and `C1_INVENTORY_STRATEGY=scan` across document, album and selection scopes
with `rating` and `minRating`, and compares both ordered results with the legacy
enumeration; the evidence keeps both strategies' timings and request status. Set
`C1_INVENTORY_LARGE_COUNT` to several hundred for a before/after measurement.

```sh
make qualify QUALIFY_SUITES="native recipes" QUALIFY_DOCUMENT_KINDS="session catalog" \
  C1_TEST_CATALOG_LAYOUT=package EVIDENCE_DIR=.build/qualification/native-recipes-package
make qualify QUALIFY_SUITES="native recipes" QUALIFY_DOCUMENT_KINDS=catalog \
  C1_TEST_CATALOG_LAYOUT=unpackaged EVIDENCE_DIR=.build/qualification/native-recipes-unpackaged
```

When running a script directly, `C1_TEST_DOCUMENT_KIND=session|catalog` selects the
mode, and `C1_TEST_CATALOG_LAYOUT=package|unpackaged` selects the Catalog layout. Keep
`C1_NATIVE_EVIDENCE` / `C1_RECIPE_EVIDENCE` / `C1_INVENTORY_EVIDENCE` distinct for
each run.

Recovery tests keep real timeouts. Only `timeout` and `recipe:tonal` wait for the
120-second Apple Event timeout; the other cases kill the caller, and only the
restart-resolved cases restart Capture One. The `barrier` case takes about 18
minutes with 3 trials per kind. The rest of `all` waits about four minutes for the
two timeouts and about six for `save-stall`, and restarts Capture One five times
(`timeout preview save-stall mcp-death recipe:preview`). Before `orientation`,
`late-preview`, `save-stall` and `recipe:late-preview` were added, the rest of
`all` took 34 minutes on 16.8.5.30: 14 minutes for the generic group and 19 for the
compound group, most of it recipe setup. To save time, select fewer cases.

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

The harness pauses the verified PID with an independent resume watchdog and kills
only its own `c1` or MCP child. The `caffeinate` wrapper prevents idle sleep. Keep
actual timeouts, ownership/identity checks and sequential execution. A pause races
native execution: an actual `-1712` verifies timeout handling but cannot prove which
setter executed. Reconciliation records observations, never historical success.

Failures stop without retry. A failed restart suppresses further cleanup Apple
Events; otherwise cleanup closes only its owned Session and restores hidden build
resources. Restart alone does not clear write blocking; the harness inspects
operation status explicitly. New fault paths need matching cases: existing cases
do not establish metadata-specific partial-write coverage, for example.

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
   `rg -n '16\.8\.5\.30|testedBuilds|pinnedBuild' Sources Tests scripts`. Update the
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

## Profiling and probes

Set `C1_PROFILE=1` on the CLI or MCP server for JSON-lines timing on stderr
(`type`, `version`, `pid`, `phase`, `handler`, `elapsedMs`, `succeeded`; monotonic
clock). Phases nest: `script_compile` (cache-miss compilation), `script_lookup`,
`apple_event` (handler execution, including its property reads), `handler_total`
and `descriptor_decode`. Diagnostic write failures are ignored.

Work outside AppleScript has its own phases, with the Swift function as `handler`:
`journal_read` (validating the journal), `journal_fsync`, `report_write`
(recipe, reference, verification and compound report files, with their syncs), `image_dimensions` and `preview_poll` (waiting
for and decoding the exported file). `recipe_verify` and `edit_apply` emit one
`compound` record for the request and one `step` record per compound step, with
the step name as `handler`. Every record measured inside a step carries that name
in `step`, so time not covered by `handler_total` and the other phases is the
step's own overhead. Records are written when a measure ends, so a step's record
follows the records it contains.

`journal_read` decodes the whole journal on a process's first read. Later reads
in the same process decode only the bytes appended since, as long as the file
keeps its inode and its last 4 KB before the decoded offset. Any other change
makes the next read decode the whole file again. A rewrite in place that keeps
the inode, at least the decoded length and those 4 KB is detected only at the
next process start.

Benchmarks need one disposable Session or Catalog left untouched while they run,
and a new output file each run. Record screen-lock, build and load conditions with
each measurement; a local comparison does not establish general scaling.

| Script | Measures |
|---|---|
| `scripts/benchmark-reads.py --ref ID --samples 5 --conditions '...' --output FILE` | Fresh CLI processes against one persistent MCP process; add `--cli .build/release/c1 --mcp .build/release/c1-mcp` for release timings |
| `scripts/benchmark-scoped-get.py --mcp ... --ref ID --samples 5 --conditions '...' --output FILE` | Single-scope against combined `nativeTargets` reads in one MCP process |
| `scripts/benchmark-catalog.py`, `scripts/qualify-catalog-reader.py` | Stored SQLite reads against native reads on a matching disposable Catalog |
| `scripts/probe-catalog-freshness.py --cli ... --raw ... --evidence NEW_DIR` | How long committed SQLite data lags native acknowledgements, on a new disposable Catalog |
| `scripts/probe-variant-modified.py --raw ... [--evidence FILE]` | What `ZISMODIFIED` and the default/combined stored layers record after import, tonal, geometry, rating/tag-only and reset edits, on a new owned Catalog (`C1_TEST_CATALOG_LAYOUT` selects the layout) |
| `scripts/qualify-upgraded-schema.py` | Read-only upgraded-schema stored reads; no Capture One calls |

Benchmarks alternate order, exclude one warmup pair, and stop on changed payloads,
errors or timeouts while keeping partial evidence. The freshness probe backs up
its Catalog, restores saved values on success and keeps the fixture on any
failure. The variant-modified probe keeps its edits, closes its owned Catalog on
success and leaves it open on failure. Regenerate the native editing allowlist with
`python3 scripts/generate-native-editing.py`; `make check` detects drift from the
retained SDEF. Store reports under `.build/benchmarks` or `.build/qualification`.

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
