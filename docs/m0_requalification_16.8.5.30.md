# M0 runtime requalification — Capture One 16.8.5.30

Date: 2026-09-07. **Decision: partial qualification; no-go for a writable release under the current M0 gates.** Basic editing and export are feasible. The old spike is not sufficient evidence for document lifetime, recovery, or arbitrary adjustment safety, and the current runtime exposed several reasons those gates matter.

This is a completed runtime investigation with explicitly unresolved product gates, not a claim that the missing c1 core was implemented. Continue focused M0 work on the remaining gates below. Read-only M1 scaffolding can proceed. Do not add 16.8.5.30 to a writable-build allowlist yet.

## Environment and scope

| Item | Recorded value |
|---|---|
| Capture One version/build | 16.8.5.30 / `com.captureone.captureone16` |
| macOS | 26.4.1, build 25E253 |
| Hardware | Apple M1 Pro, 32 GiB, arm64 |
| Swift | Apple Swift 6.3.1 |
| Bridge | `58946d7fd5b38b6a92c13ccb413d30ba1f0e9179` |
| aelint | `a56f5d0be22c6bc21957e5c1d0355809a2c477a5` |
| RAW fixture | Local Canon EOS R CR3, copied into disposable Session A; not the old R6 Mark II fixture |
| Bulk fixture | Session B: 1,000 copies of one exported 1000 × 1500 JPEG |

[Environment and source checksum](m0/16.8.5.30/environment.json), [dictionary snapshot](../sdef/16.8.5.30.sdef), [capability evidence matrix](m0/16.8.5.30/capabilities.json), [probe instructions](../probes/m0/README.md).

Only copies in `/private/tmp/c1-m0-1685-A` and `-B` were adjusted. No catalog variants were intentionally mutated. The original Catalog was reopened after a normal saved restart, and restored as the sole open document at cleanup. The test recipe was deleted; processing/batch callbacks ended unset; Edit All Selected Variants ended `true`, its initial value. The copied RAW's SHA-256 was unchanged after the tests. Temporary RAWs, JPEGs and Sessions remain outside the repository for inspection; no image redistribution is required to use the probes.

The unsandboxed Codex shell could send Apple Events through `osascript` and a compiled Swift probe. The first sandboxed application-ID lookup failed with -1728; that was not an observed Capture One compatibility failure. Terminal.app launch, release signing, notarization and consent across signed updates were not tested.

## Results against the M0 gates

| Gate | Result | Limits |
|---|---|---|
| Native clone and immediate addressing | Passed in fixture | Source 1 → clones 2/3; later clone 12; IDs resolved immediately |
| Clone preservation | Passed for sampled settings | Exposure/contrast/saturation, filled layer, opacity 63, layer exposure 0.75, sharpening 173 and an edited RGB curve endpoint preserved; other mask/layer types untested |
| Isolation and variant-only deletion | Passed in fixture | Five fields tested with source and sibling selected, Edit All Selected Variants off/on; temporary clone deleted without removing source/siblings; RAW checksum unchanged |
| Reorder and restart identity | Passed for native IDs | Pick operation changed order from 1/2/3 to 3/1/2; IDs survived normal saved app restart; does not prove document identity or lifetime |
| Document lifetime and replacement detection | Unresolved | Document ID is a path; stale specifier becomes valid after reopen; replacement/duplicate database cases unqualified |
| Five-field changed-value readback | Passed for sampled values | Boundaries and deltas tested; WB is coupled and numerically noisy; reset unsupported |
| Partial writes and timeout behavior | Demonstrated | Earlier field persists after later failure; real -1712 can precede eventual application |
| Integrated stale-state/journal recovery | Unresolved | No c1 implementation exists yet; primitive probes are not an integration test |
| Lost client reply | Demonstrated, limited | Killed `osascript` before its final reply; output completed; did not establish a job still pending after death |
| Preview correlation | Positive callback evidence | UUID/source/output list match; JPEG decoding passes; polling alone and full callback crash/coexistence recovery remain unqualified |
| Cross-process lock | Passed as primitive | Same application lock blocks both document labels and releases on process death; not a journal or application lock |
| Pinned bridge | Passed | Nested records, missing values, optional arrays, null/missing encode/decode and compiled-client app read |

Exact AppleScript outputs, errors and timings are in [runtime.jsonl](m0/16.8.5.30/runtime.jsonl). This is an append-only investigation log: it includes setup/terminology failures and revised-script hashes, not only successful runs. Some early invocations were made directly during setup; the retained probes document the final usable forms. Historical hashes identify the invocation; earlier source revisions are not all separately retained.

## Changes that affect the implementation

### Identity is more than an ID string

`id of document A` returned `/private/tmp/c1-m0-1685-A`; `path of document A` returned the containing `/private/tmp` folder as a file descriptor. The original Catalog's ID was its package path. Neither is an immutable document UUID or an open-instance generation.

After closing A, `exists` returned false. After reopening the same path, the old document specifier returned true. A path-bound reference can silently become usable again. The limited “current open document only” policy therefore still needs an observable lifetime mechanism; declaring a token in a sidecar does not solve this.

A normal application quit was confirmed by process exit; PID changed from 95528 to 1172. The first post-restart snapshot failed because opening B closed A. Reopening A alone established IDs `{1,3,2,12}` and preserved the sampled states/layer. Read [restart.json](m0/16.8.5.30/restart.json) together with probe 13's reconciliation in the runtime log. The failure is retained rather than relabeled as a clean first-attempt success.

Explicit document-scoped reads distinguished A's CR3 from B's JPEG despite colliding native ID `1`. This is positive evidence for explicit addressing, not an atomic guarantee against document switching.

### Initial fields and numeric comparison

| Field | Sample set → readback | Tested endpoints | Above-maximum sample |
|---|---|---|---|
| exposure | 1.234 → 1.233999967575 | -4, 4 | 4.5 rejected, -50 |
| contrast | 23.4 → 23.39999961853 | -50, 50 | 101 rejected, -50 |
| saturation | -12.3 → -12.300000190735 | -100, 100 | 110 rejected, -50 |
| temperature | 5432 → 5432 | 800, 14000 | 15000 rejected, -50 |
| tint | 3.27 → 3.269999027252 | -50, 50 | 55 rejected, -50 |

All five changed values, arithmetic deltas and restoration were exercised with Edit All Selected Variants false and true. Source/sibling reads were unchanged in each case. Boundary tests exercised a separate clone-only sequence; these are observed endpoints, not an exhaustive range/property test.

WB must be read as a pair: setting temperature to 5400 then tint to 5 read back approximately `{5400.001465, 4.999984}`. Reversed ordering produced `{6100.000488, -2.999999}`. Restoring WB left small differences, and a later reopen normalized them again. Candidate comparison tolerances in the plan are deliberately larger than these observed errors; stable hash canonicalization remains a separate implementation test. Exact floating-point equality is unsuitable.

The metadata read returned camera `Canon EOS R`, ISO as text `ISO 100`, and shutter as text `1/500 s`. Do not assume these fields arrive as normalized numeric types. Temperature/tint from `adjustments` describe current WB, not verified as-shot metadata.

Fresh clone settings, including the curve endpoint, matched their source. Decoded JPEG pixels were not identical: source/clone maximum 8-bit channel difference was 6; repeated source exports also differed by up to 3. The cause is not established. These checks prove readable output and sampled state preservation, not pixel determinism or equality of every unmodeled adjustment. See [render comparisons](m0/16.8.5.30/fresh_clone_images.json).

### Partial writes, timeout and lost replies

A patch set exposure to 0.6, then attempted a nonnumeric contrast. Contrast failed with -1700; exposure read back 0.600000023842. Patches must remain explicitly non-atomic.

The controlled timeout probe compiled a write to the disposable clone, paused the verified Capture One process for three seconds with an independent resume watchdog, and used a one-second Apple Event deadline. The reply was **-1712**, but readback after resume was **0.875**, the requested value. The probe restored exposure to 0.25. This directly demonstrates delayed application after timeout; it is an injected fault, not a measurement of natural timeout frequency. See [timeout.json](m0/16.8.5.30/timeout.json).

Two export clients were killed after dispatch and before returning their final result. Both produced readable JPEGs. Pausing `processing queue enabled` did not keep these explicit `process` jobs pending, even with A current. Therefore these runs do **not** qualify recovery while rendering remains outstanding. Keep the distinction between “reply lost” and “observed still executing.” See [foreground client-death evidence](m0/16.8.5.30/client_death_foreground.json) and [decoded images](m0/16.8.5.30/client_death_images.json).

### Preview settings, correlation and recovery

- A specifically named disabled recipe was usable by `process`; no reliance on checked recipes is needed for this observed operation.
- The setter accepted `sRGB IEC61966-2.1` without error but left Adobe RGB selected. `sRGB Color Space Profile` read back correctly and exported a JPEG whose embedded profile was sRGB IEC61966-2.1.
- Setting root location after root type left/reset the recipe to `output location`. An export addressed to A then landed in B's Output folder while B was frontmost. Setting root location first, then `custom location`, and checking readback produced the expected A output. The recipe also appeared in B: treat recipe ownership as shared application state.
- The returned job UUID appeared in polling and then disappeared. Queue disappearance did not establish a usable output by itself. Variant output history stayed stale, and a fresh clone inherited old output history. It is not a reliable standalone completion witness in these probes.
- `processing done script` delivered a matching job UUID, source RAW path and **list of output paths** for four fixture exports. The final two JPEGs decoded successfully as 1000 × 1500 images. [Callback evidence](m0/16.8.5.30/callback.json), [image verification](m0/16.8.5.30/callback_images.json).
- A recovery record was written before installation. Recovery from a separate process restored an unchanged installed value; a simulated intervening replacement was preserved. The initial string comparison failed because the getter returns a file descriptor/HFS text and POSIX conversion uses `/tmp` while installation used `/private/tmp`. The failed run is retained; the corrected normalized comparison passed, and final cleanup returned `missing value`.

This is positive callback feasibility evidence, **not** completed crash recovery: durable fsync/atomic journal transitions, actual controller death while the callback owns pending work, unrelated exports using another recipe/document, callback loss/failure, and lost `process` replies still need a production-quality harness. The recovery probe intentionally starts from an unset callback; preserving a pre-existing user callback remains unqualified. A callback is the leading current candidate because polling evidence is insufficient, but neither route is approved for release yet.

### Bulk performance and shapes

Post-discovery results, five scalar adjustment properties per query:

| Variants | Bulk median | Bulk min–max | Per-variant loop |
|---:|---:|---:|---:|
| 1 | 41.8 ms | 37.6–63.8 ms | 52.6 ms |
| 10 | 48.6 ms | 41.8–56.7 ms | 480.5 ms |
| 100 | 62.9 ms | 45.7–220.5 ms | 4.86 s |
| 1000 | 379.3 ms | 326.2–1241.4 ms | 100.01 s |

The earlier discovery run saw a 27.22-second bulk query. These are end-to-end AppleScript query timings inside a handler, excluding process launch/compilation, not single-event timings; the multi-property form may send multiple events. Some preview activity and background work overlapped the measurements. The JPEG fixture, Capture One version, OS and workload all differ from the old M4 test; **do not interpret the ratio as an M1-versus-M4 speed comparison**. No real 10k RAW catalog was measured. [Summary data](m0/16.8.5.30/benchmark_summary.json).

Bulk scalar results were five columns of N values; nested camera metadata worked. Intermediate list dereferencing still failed with -1728, and curves returned object specifiers. **Crop returned N nested four-value lists**, for both RAW and JPEG fixtures, contradicting the old flat-list assumption.

The plan starts further qualification at 100-variant read chunks, configurable 60-second Apple Event deadlines and separate provisional 120-second preview deadlines. These choices are conservative starting points; they are not measured maximum durations or release guarantees.

## Tools and coverage

The [pinned bridge probe](../probes/m0/bridge/Package.swift) passed nested records, optional arrays with `missing value`, round trips using both `.null` and `.missingValue`, and a compiled Swift application-version query. [Results](m0/16.8.5.30/bridge.json).

Full dictionary static aelint reported **59/100 (F)** with 14 errors. These include existing ambiguous names/codes; this grade is not a runtime safety score. The new dictionary adds people masking/layer types, processing modes, Color Editor classes and batch-callback output documentation.

Unrestricted `aelint --dynamic` was not used: source inspection shows generic command probing, including commands outside a safe read/write fixture subset. Instead, a retained command-free SDEF subset marks all selected properties read-only. Its dynamic run sent 56 events with no timeouts and reported 10 tested properties; the report explicitly lists `adjustment settings` as an untested class. The subset's 100/100 grade must not be presented as full-app compatibility. The explicit five-field probes provide setter evidence separately. [Static report](m0/16.8.5.30/aelint_static.json), [subset report](m0/16.8.5.30/aelint_dynamic_read_subset.json), [subset definition](../probes/m0/aelint_read_subset.sdef).

The [application-wide flock probe](m0/16.8.5.30/lock.json) blocked workers labeled with the same and different documents and allowed acquisition after normal release and holder death. It did not test a c1 journal, photographer interference, or an atomic compare-and-set.

## Remaining exit work

1. Prove document-instance/lifetime detection and same-path replacement rejection, including duplicate Session/database cases. Native ID persistence is insufficient; fail closed until this is solved.
2. Build a minimal provenance, canonical state-hash and durable operation-journal harness. Exercise stale preconditions, two real invocations targeting different documents, document switching between validation and dispatch, partial batches and unresolved entries blocking subsequent writes. The repository currently has no c1 implementation to qualify here.
3. Complete preview recovery: a genuinely outstanding render after client death, lost process reply, callback failure, preserved pre-existing callbacks, unrelated exports and crash recovery with durable ownership. Keep ambiguous outcomes unknown; do not infer non-execution from an empty queue.
4. Broaden clone preservation to additional real layered RAW fixtures and investigate render variability if pixel comparisons will be used as an acceptance gate. Geometry, reset, styles, notes/tags, Catalog mutations and new scripting features remain disabled.
5. Verify consent for Terminal.app and intended signed CLI/MCP launch/update paths once those artifacts exist. Recheck candidate batching/deadlines on representative RAW Sessions without concurrent probe activity.

The goal is to close these focused gates, not to repeat every later M3/M5 feature or the old 10k extrapolation.
