# v0.1 release validation

This is the current support and validation authority. Usage is documented in the
[README](../README.md); build qualification follows the
[new-build guide](QUALIFYING_NEW_BUILDS.md). Dated reports below describe their
recorded payloads, not an automatic qualification of later code.

## Current scope and remaining gates

Capture One **16.8.5.30 on Apple Silicon** is the only qualified application build.
Use one open document and sequential calls, with no UI edits, document switching,
or competing exports during a workflow. Existing variants are editable through
saved `c1_edit_` references; separate managed clones remain optional. Only
agent-created clones can be deleted.

Sessions support the five legacy tonal fields, crop/rotation, keystone, ratings,
and color tags. The experimental [native editing API](native-editing/README.md) adds
127 writable properties plus layer/mask/color-editor commands. Catalogs remain read-only by default; exact-path opt-in enables
experimental editing of online referenced originals outside the Catalog package.
Catalog-stored originals and Catalog fault recovery remain unqualified.

The expanded native surface is **contract 1.10.0**: **941/941 offline assertions**,
29 recovery-harness tests, the packaged CLI/MCP/native workflows, and two final-payload
native timeout/recovery cases passed. Coverage is focused, not every native field,
mask-pixel state, or Catalog workflow. See [native qualification](native-editing/16.8.5.30/README.md).

The preceding broad regular campaign was **contract 1.9.0**:
**907/907 offline assertions**, **25 recovery-harness tests**, contract/profile
checks, and all **nine packaged live suites** passed. Metadata writes preserved
tone, geometry, variant count, and RAW checksums in Session and referenced-Catalog
fixtures. See the [metadata report](metadata/16.8.5.30/README.md) for payload hashes
and coverage. These are recorded results, not a fresh run of the current checkout.

Recovery coverage is incremental. The corrected-lens payload passed five real
fault cases with explicit SIGTERM shutdown. Later perspective and keystone
campaigns were incomplete; metadata partial-write/recovery failures have only
mocked coverage. A full live fault pass for the current payload is **not claimed**.

Remaining limits:

- Graceful native quit is unqualified. Explicit SIGTERM recovery after closing
  owned fixtures is separately demonstrated; there is no automatic fallback.
- Same-file close/reopen within one app launch is not reliably detectable.
  Application restart and database replacement invalidate references. Arbitrary
  live database replacement and concurrent operators are unqualified.
- Preview association depends on exclusive output ownership and the documented
  workflow. State hashes are not complete render fingerprints. Production uses
  polling, not callbacks; callback ownership/coexistence and general export remain
  outside scope.
- Lens/movement coverage uses the fixtures identified in each report. Flips,
  crop-outside-image, other app builds, and broad camera/lens coverage remain
  outside qualification. Fixture checks do not establish aesthetic quality;
  photographer evaluation on separate reviewed shoots remains pending.
- Archives are ad-hoc signed. Fresh-user downloaded-artifact launch, Automation
  consent through Terminal and an intended MCP client, and a Developer ID
  signing/notarization decision remain distribution gates. Automated publication
  does not establish those checks or qualify Intel and every macOS target.

## Retained qualification evidence

The detailed reports retain exact payload/environment hashes, failures, journals,
and interpretation limits. A pass applies only to its recorded scope.

| Area | Retained result and limits |
|---|---|
| [Native editing](native-editing/16.8.5.30/README.md) | CLI/MCP coverage for scoped reads, native properties/actions, color-editor targeting, and coupled color-balance writes. Select native property/action recovery by changed behavior. Dictionary availability does not establish exhaustive runtime support; mask pixels remain unavailable. |
| [Metadata, 2026-09-17](metadata/16.8.5.30/README.md) | Contract 1.9.0; all nine regular suites. Every rating/tag value, clearing, omitted fields, stale tokens, and restore passed. No new live fault campaign. |
| [Keystone, 2026-09-17](geometry/16.8.5.30/keystone/README.md) | Contract 1.8.0; nine regular suites, 13 control cases and two lens combinations. Native export variance required a pixel-error assertion instead of exact hashes. Tonal/standard-geometry faults passed; interrupted lens work was reconciled without retry. Remaining faults were not run. |
| [Perspective and movements, 2026-09-17](geometry/16.8.5.30/perspective/README.md) | Contract 1.7.0; eight perspective/movement cases and all regular suites passed. Three timeout recoveries passed; the combined-correction campaign was stopped. Native lens-profile fixtures do not establish optical accuracy or real tilt/shift capture coverage. |
| [Corrected lens, 2026-09-17](geometry/16.8.5.30/lens/README.md) | Contract 1.6.0; six packaged cases, four orientations, both hide-distorted-areas settings, preview mapping and restore. Five SIGTERM recovery cases passed: tonal, geometry, lens, preview, MCP death. One Canon CR3/profile, not a multi-lens campaign. |
| [Inventory, 2026-09-16](inventory/16.8.5.30/README.md) | Contract 1.5.0; packaged workflows, native-predicate equivalence, progress/status, and boundary cancellation passed. Timings used variants of one RAW, not a whole shoot. Initial recovery failed and remains recorded. |
| [Session recovery, 2026-09-17](release/recovery-2026-09-17/README.md) | Four cases passed on the inventory payload with explicit SIGTERM and fixtures outside /tmp. Native IDs, count, parent paths, stale-reference rejection, write blocking, state and RAW checks passed. |
| [Recovery diagnosis](recovery-diagnosis/16.8.5.30/README.md) | Quit stalls reproduced with zero documents; duplicate RAW records reproduced under /tmp. Seventeen shorter restarts preserved visible IDs; the earlier ID-loss trigger remains unresolved. Optional quit investigation is closed. |
| [Existing variants, 2026-09-14](existing-variants/16.8.5.30/README.md) | Contract 1.4.0; existing-variant workflows and examples passed in Sessions and referenced Catalogs without duplicates. Two Session faults passed on an earlier payload; preview recovery then lost an ID, and MCP death was not reached. |
| [Catalogs, 2026-09-14](catalog/16.8.5.30/README.md) | Exact-path opt-in, referenced-original editing and preview. Catalog-stored import crashed during fixture setup and remains blocked; Session fault evidence does not qualify Catalog recovery. |
| [Crop/rotation, 2026-09-11](geometry/16.8.5.30/README.md) | Initial geometry coordinates, ratios, orientations, preview mapping, baseline restore and recovery. Later reports separately extend supported corrections. |
| [Original packaged recovery, 2026-09-09](release/recovery-2026-09-09/README.md) | Historical clone-ID fix, ten clone/read/delete cycles, three real recovery cases, and relocated CLI/MCP regressions. Retains the motivating failure and production patch; not the current runtime payload. |

## Validation policy

Choose tests by changed behavior. `make check` is the offline development loop.
`make qualify` runs packaged CLI, MCP, and existing-variant workflows;
`QUALIFY_SUITES` selects affected matrices and `make qualify-extended` runs all eleven, including `native` and `recipes`.
Documentation-only changes need syntax/link checks. Live suites remain sequential.

Run affected live faults when production recovery or fault-harness behavior
changes; no separate user request is required. Skip unrelated matrices and fault
campaigns. Report selected and omitted coverage, including required checks that
could not run. The selection guide below is current; older dated descriptions of
optional recovery campaigns record historical practice.

## Recovery test selection

Keep all fast offline safeguards in routine checks. Run live faults when the changed
path can alter dispatch, partial application, write blocking, or recovery. Build a
current archive with `make archive` (or reuse the same candidate from `make qualify`).

| Changed behavior | Relevant `RECOVERY_CASES` |
|---|---|
| Tonal mutation dispatch or timeout | `tonal` |
| Expanded native property or editing-command dispatch | `native native-action` |
| Crop/rotation dispatch or partial writes | `geometry`; add `lens`, `perspective`, and `keystone` for affected corrected-image paths |
| Lens, perspective/movements, or keystone mutation/recovery | Corresponding `lens`, `perspective`, or `keystone` |
| Preview export, timeout, or completion detection | `preview mcp-death` |
| MCP process lifetime/cancellation around dispatch | `mcp-death` |
| Clone native-ID readback | `clone-readback` |
| Shared journal, unresolved-write guards, lock ownership, app lifetime, restart/reconciliation, or stale-reference behavior | All affected fault paths; use `all` when impact cannot be narrowed |
| Fault harness pause/resume, dispatch detection, shutdown, identity checks, or recovery assertions | Cases using the changed behavior |
| Unrelated features, docs, build/CI, or selection/reporting only | Offline checks; no live fault campaign |

For example, `make qualify-recovery RECOVERY_CASES="preview mcp-death" C1_RECOVERY_SHUTDOWN_MODE=sigterm EVIDENCE_DIR=/private/tmp/c1-preview-recovery` skips unrelated Apple Event timeout cases and clone stress. Cases run sequentially and stop on the first failure. Selected/skipped cases are recorded in evidence; a partial selection is never reported as an all-case pass. `all` includes the original seven faults, the two native editing faults, and the ten-cycle clone-readback regression. New recovery paths (such as metadata partial writes) need a matching regression; existing cases do not establish coverage for a path they never exercise.

A release checkpoint alone does not require a repeated fault campaign. Selection
and reporting changes can be checked with mocked orchestration; changes to actual
fault behavior need the relevant live case. Keep real timeout durations and all
RAW, ownership, identity, and reconciliation guards. If the required application,
fixture, or exclusive access is unavailable, complete offline checks and state the
remaining live-validation gap.

## Reproduce packaged live recovery qualification

Close all documents and allow exclusive use of Capture One. The harness refuses to start with an open document or a different app build. It copies a local RAW into a fresh Session under `.build/recovery-fixtures` in the checkout. Set `C1_RECOVERY_FIXTURE_PARENT` to override that parent with an absolute path outside `/tmp` and `/private/tmp`, without symlink aliases. Native image-path spelling must match the copied fixture before mutations. Sessions and uncertain clones are retained; build cleanup may remove the default fixture directory, so preserve evidence elsewhere before cleaning. Keep the source RAW outside the build tree. Only managed clones are adjusted. The harness pauses/resumes the verified app PID with an independent 150-second watchdog, kills its own MCP child after export output appears, and restarts the app between cases. Do not run another test suite or build concurrently.

```sh
make archive
export C1_TEST_RAW_FIXTURE=/path/to/local.CR3
caffeinate -i python3 Tests/recovery_integration_test.py \
  dist/c1-v0.1.0-macos-arm64.tar.gz \
  docs/release/recovery-YYYY-MM-DD/run-1
```

`C1_RECOVERY_SHUTDOWN_MODE=quit` is the default: request native quit and verify the old process exits. `C1_RECOVERY_SHUTDOWN_MODE=sigterm` explicitly selects process termination after closing the owned Session, confirming zero documents, and rechecking the verified PID. There is **no automatic fallback**. Environment, restart, case, and completion events record the mode; a SIGTERM pass is process-termination recovery evidence, not graceful-quit qualification. Capture One labeled direct SIGTERM abnormal in the diagnostic controls. Both modes require observed old-process exit before reopening and a different PID afterward.

Both settings can be passed to `make qualify-full` when all regular and recovery paths need validation, for example `make qualify-full C1_RECOVERY_SHUTDOWN_MODE=sigterm EVIDENCE_DIR=/private/tmp/new-qualification` with `C1_TEST_RAW_FIXTURE` set. For a focused recovery run, use `make qualify-recovery RECOVERY_CASES="tonal" ...` or add `--cases tonal` to the Python command above. The evidence directory may be under `/tmp`; the Session fixture must not be.

The `caffeinate` wrapper inhibits idle sleep for the test duration; a suspended machine can invalidate timeout timing. Use a new evidence directory for each run. Failures are retained, not overwritten or automatically retried. Shutdown timeouts collect a best-effort process sample and stop. After an incomplete restart, cleanup sends no further Apple Events; it still restores the build resource bundle and retains the journal. Otherwise cleanup closes only its own Session. If a run fails with unresolved work, inspect its journal and end the old app process before manual reconciliation. No uncertain clones are deleted or adopted by cleanup.

The harness verifies archive checksum and records executable/handler hashes, source commit, harness hash, OS, Swift, build and fixture hash. It hides the build-tree resource bundle, runs extracted binaries, and saves raw command/error responses plus journal/provenance snapshots. Before/after restart inventories retain native IDs and parent paths; any change in IDs, count, or paths stops the run before reconciliation. Existing post-reconciliation identity, stale-reference, state/geometry, write-blocking, and RAW checks remain in place. Read-only database snapshots after Session close and process exit help diagnose duplicate image/folder/variant records. Snapshot failures are logged without weakening public inventory checks; private database rows never authorize writes. No RAW or JPEG is committed. A pause immediately after a pending record races handler execution: an actual `-1712` proves the timeout path, but cannot identify which individual Apple Event was in flight or prove that a delayed setter executed. Output creation before killing MCP proves export dispatch and a lost reply, not that rendering remained outstanding at the instant of death.


## Evidence retention

Keep maintained source, tests, examples, the exact-build SDEF, current operating
guidance, and evidence supporting the claims above. Retain failures that explain
safety limits, and the hashes/patches needed to identify a tested payload. Generated
archives, RAW copies, previews, disposable databases, and redundant scratch logs
belong outside tracked source.

The superseded M0 feasibility probes, their report/data, and the old `follow_up.md`
roadmap were removed from the working tree. They remain in Git history at
`4da114f` (for example, `git show 4da114f:follow_up.md`). Maintained integration and
recovery suites under `Tests/` are the development entry points; the retained
geometry probes investigate native behavior. Style learning remains a separate
consumer of the public interface, as described in the README.


## Compound recipe qualification

Contract 2.4.0 adds the bounded [recipe workflow](recipes/README.md). Its regular
suite is `QUALIFY_SUITES=recipes`; dedicated fault cases use
`make qualify-recipes-recovery` and `RECIPE_RECOVERY_CASES`. They exercise compound
paths and do not replace unrelated native-action, lens/perspective, Catalog or
metadata qualification. Keep `make check` sequential with live qualification:
offline fake-executor tests also acquire the application lock.

The [2026-09-19 recipe report](recipes/qualification/README.md) records the packaged
recipe suite, five compound fault cases and final offline pass. It does not imply
coverage of the excluded transfer types or unrelated recovery paths.
