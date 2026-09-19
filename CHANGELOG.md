Releases are published automatically after each push to `main`, using UTC tags in
`YYYY-MM-DD-NN` format. The sections below group changes by feature.

Entries describe changes at their recorded contract version. See the [README](README.md)
for current behavior and [release validation](docs/RELEASE_VALIDATION.md) for current
support limits and test-selection policy.

## Bounded known-ID discovery

- CLI `variants list --ids` and MCP `variants_list.ids` resolve at most 512 known IDs without full-scope metadata discovery. Default fields are ID, exact rating and parent-image path; optional summaries add name, selection and color tag. Exact parent-path, rating and selection filtering preserve input order.
- Fresh bounded checks reject identity/document drift and missing IDs without partial responses. Browsing caches are bypassed; existing fresh `get` and editing preconditions remain required. Rich adjustment/native reads continue through per-variant `get`; multi-variant native-token batching is not added.
- Focused read-only CLI/MCP checks passed on a five-variant disposable Session, including collection/selection, filter parity and missing-ID failure. Minimal discovery measured 1.24 seconds on that fixture; the historical 100-of-1,335 workload has not been benchmarked. Recovery faults were omitted because mutation and recovery paths are unchanged.

## Documentation and qualification cleanup

- Keep current implementation, usage, support limits and validation commands in docs. Remove generated results, journals, copied harnesses/source patches and dated reports; previously committed evidence remains in Git history. Generate detailed diagnostics in ignored `.build` directories or external artifact storage.
- Cleanup validation passed `make check` in 28.64 seconds, including a 7.36-second incremental debug build and 9.44-second core assertions. Documentation links, generated-resource checks and the rebuilt relocated archive/CLI/MCP checks passed. Removed 269 report/artifact files (9.6 MB) and five closed disposable fixtures (121 MB); source RAWs were preserved.
- Scoped-recipe validation on 2026-09-19 passed 1,233 offline assertions, the 35-tool CLI/MCP contract, broad and focused recipe live runs, and six recovery cases (camera, advanced-color deletion, lens, layer-color deletion, geometry after lens, MCP caller death). RAW hashes remained unchanged. Complete wedding-look qualification, arbitrary profiles/lenses, layers/masks and Catalog recovery were not established.
- Recorded local timings: core assertions approximately 5.5–6 seconds before the scoped extension and 9 seconds afterward; typed recipe live checks 154 seconds, expanded recipe checks 546 seconds, focused scoped checks including combined lens/geometry 576 seconds. These were different payloads/runs, not a controlled benchmark. The six-case scoped recovery run took 21m46s, including five real 120-second timeouts, independent clone verification and guarded restarts.
- Development found missing indexed color-band counts; the unknown deletion was reconciled without retry and image/layer count readback was corrected. The initial recovery attempt hit transient application discovery after restart; the scoped harness now confirms the exact document through repeated read-only CLI checks. The final regular binary preceded a reporting-only change retaining failed scoped observations; offline checks and recovery used the final binary.
- Recorded broader qualification milestones: contract 1.10 passed 941 assertions and native property/action recovery; contract 1.9 passed 907 assertions and nine regular suites. Lens/perspective/keystone results were fixture-specific; later fault campaigns were incomplete, and metadata partial-write faults had mocked coverage only. No exhaustive current-payload or Catalog recovery campaign was claimed.
- Local scoped-read benchmark: combined adjustment/lens/variant reads measured 3,245 ms median versus 4,082 ms for three calls on one disposable fixture. Catalog benchmarks measured roughly 34–47× faster stored reads and 4× SQL throughput with four workers; native acknowledgements could precede SQLite visibility by more than 30 seconds. These measurements do not establish live-state equivalence or broad scaling.

## Explicit scoped recipes

- Add version-2 camera/profile, lens, named basic-color patches and explicit advanced-color replacement to shared CLI/MCP recipes (contract 2.7.0); add all image color-balance controls to settings and overrides.
- Bind camera/lens scopes to destination metadata, require explicit lens crop policy and geometry preconditions, and independently check omitted scoped values. Return scoped observations, hashes, diffs and per-step provenance.
- Keep every scoped mutation separately journaled with fresh readback; verify color-deletion counts and retain partial/unknown recovery. Layers/masks, Skin Tone and style/profile installation remain excluded; payload qualification and visual review are still required.

## Curves, grain and vignette recipes

- Extend shared CLI/MCP recipe settings and per-photo overrides to five point curves, grain type/impact/granularity and vignette method/amount (contract 2.6.0).
- Independently verify typed values and preserve omitted settings. Exposure, paired white balance and crop remain governed by explicit policies; film profiles and indexed color bands remain excluded.

## Compound result bundles

- Return and persist a consolidated final observation, aggregate before/after diff, recipe and operation provenance, coverage and optional preview for successful CLI/MCP compound edits and verification (contract 2.5.0).
- Compare against a fresh native pre-edit snapshot; preserve fresh per-step checks and partial/unknown reporting. No execution-context caching is introduced.

## Reference recipes and compound edits

- Add shared CLI/MCP reference capture, content-addressed recipe registration, managed-clone verification, single-photo compound application and durable status inspection (contract 2.4.0).
- Require explicit exposure, paired white-balance and crop policies. The initial recipe allowlist covers fourteen global numeric controls plus exposure/white balance; masks, layer reconstruction, curves, indexed color controls and camera/lens profiles remain excluded from recipe transfer.
- Independently verify registered payloads before reuse and bind evidence to the payload/build/report hashes. Exported reference bundles identify uncaptured and unsupported state.
- Preserve per-step before-state, fresh tokens, child operation IDs/readback and partial completion. Return final observed settings and optional preview; interrupted or uncertain compounds never resume automatically.
- See [recipe workflow and validation](docs/recipes/README.md) for commands and current qualification scope.

## Coupled color-balance writes

- Write requested saturation before its paired hue on all four image/layer color wheels, preserving omitted controls. On Capture One 16.8.5.30, a neutral-wheel request for hue 237 and saturation 0.2 previously returned approximately 237.14285 with hue-first ordering; saturation-first returned approximately 237.00004.
- Compare color-balance hue readback as a circular angle, treating 0 and 360 degrees as equivalent without widening the 0.0001 tolerance. Near-zero saturation remains subject to native hue quantization.
- Validation on 2026-09-19 passed 1,102 offline assertions, CLI/MCP contracts, the full packaged native suite, and native-property timeout/restart recovery. Added 32 paired/single-control/restoration writes and 68 independent observations across image and layer adjustments, including omitted-control, sibling-variant and RAW preservation checks. Recovery used a coupled color-balance fault payload; unrelated suites and the unchanged native-action path were omitted.
- Keep native-editing documentation focused on current behavior, coverage, limits, and validation commands; remove run narratives and assertion-count snapshots from the documentation.

## Native color-editor targeting

- Preserve unevaluated indexed AppleScript references so basic-color targets address the requested band. Evaluated element references could alias an indexed band to `all`.
- Qualification on 2026-09-19 compared all nine basic bands and three advanced elements against independent bulk records at image and layer scope, including changes, restoration, sibling preservation and middle-element deletion. The packaged native suite and native property/action SIGTERM recovery cases passed.

## Doctor diagnostics

- Report unknown journal status without fabricating an unresolved-operation count; preserve the original diagnostic error in CLI/MCP and human output (contract 2.1.0).
- Reuse the doctor discovery response for document inspection, eliminating its redundant application query.
- Reduce suggestions.md to remaining locally reproducible engineering work.

## Unified scoped reads

- Make `get` the read interface for compact data and 1...16 optional native targets; return native snapshots alongside metadata, geometry and scope-specific state tokens.
- Remove MCP `native_get` and CLI `native get` in contract 2.0.0. Single-target reads keep a direct path; multiple scopes share validation under one lock and reject detected source/document drift without partial output.
- Retain live AppleScript state semantics. See [scoped reads](docs/native-editing/README.md#scoped-reads).

## Read performance diagnostics

- Initial contract 1.10.0 local debug measurements found medians of 1,312/956 ms for CLI/persistent MCP `get`, and 4,113/3,656 ms for the former `native_get`. The original evidence is retained in profiling commit `84073e1`; current performance documentation describes the scoped `get` interface.

- Add opt-in `C1_PROFILE=1` JSON timing on stderr for script compilation/cache lookup, Apple Event execution and descriptor decoding, without changing CLI/MCP response schemas.
- Add a sequential local-fixture benchmark comparing fresh CLI reads with persistent MCP reads, with warmup separation, alternating order, state-drift rejection and retained partial evidence.
- Document measured coverage and the remaining optimization work in [performance notes](docs/performance/README.md).

## Expanded native editing

- Add `native_get`, `native_set`, and `native_action` to CLI/MCP (contract 1.10.0): 127 writable properties covering curves, levels, HDR, clarity, sharpening, noise reduction, color balance/editors, lens corrections and layer/luma settings.
- Add layer creation/deletion, native mask operations, AI people masks, style application, dehaze actions and advanced color-element creation/deletion through typed, explicit handlers.
- Retain existing editing-reference/Catalog guards, native state preconditions, before/after journal snapshots, and uncertain-operation recovery. Native unset values stay distinct from unavailable properties. Mask pixels are not exposed or restorable through property snapshots.
- Add generated-dictionary drift checks, a packaged native editing suite, and native property/action recovery cases. See [native editing coverage and limitations](docs/native-editing/README.md).

## Metadata editing and validation workflow

- Add rating (0–5) and native color-tag (0–7) writes through CLI `metadata set` and MCP `metadata_set` (contract 1.9.0). Require an editing or managed-clone reference and a fresh metadata state token; preserve omitted fields.
- Save metadata baselines, expose metadata differences, and journal writes with native concurrency and readback checks. The composition profile excludes metadata writes. See [qualification and limits](docs/RELEASE_VALIDATION.md).
- Default `make qualify` to packaged CLI, MCP, and existing-variant workflows; select affected suites with `QUALIFY_SUITES`, or all nine with `make qualify-extended`.
- Select recovery cases by changed behavior with `RECOVERY_CASES`. Affected recovery and fault-harness changes require live fault validation; unrelated changes and release checkpoints alone do not. A separate user request is not required.
- Remove superseded M0 feasibility probes/evidence and the old follow-up roadmap; retain feature/recovery qualification evidence and consolidate current support guidance.

## Keystone corrections

- Add absolute keystone amount, vertical, horizontal, skew, and aspect controls to CLI `geometry set` and MCP `geometry_set` (contract 1.8.0), including the composition profile.
- Preserve omitted controls, tonal edits, lens settings, and native variant identity. Validate native ranges before dispatch, obtain fresh crop bounds after transforms, and verify all five controls on readback.
- Include keystone changes in diffs and durable geometry requests. Restore baseline keystone with crop/rotation through `geometry_restore`; reject predictive dry runs for keystone changes.
- Add CLI/MCP control-range, preview, restoration, and referenced-Catalog coverage, plus a keystone timeout-recovery test case. See [qualification](docs/RELEASE_VALIDATION.md).

## Preserved keystone and lens movements

- Enable crop, rotation, ratio fitting, context preview, and baseline restoration while preserving existing keystone and lens tilt/shift on Capture One 16.8.5.30 (contract 1.7.0).
- Validate native ratio-fit shrinkage inside the proposed rectangle. Keep explicit crops strict and retain native automatic crops for rotation-only requests.
- Reject dry runs that would need native rotation or perspective/movement ratio normalization. Keep journal, state, context, and recovery checks.
- Make real timeout/process-death validation opt-in via `qualify-recovery` or `qualify-full`; normal `qualify` retains offline and packaged live workflow checks.
- Add representative movement-profile and keystone workflows, coordinate checks, and a combined-correction timeout case. See [qualification](docs/RELEASE_VALIDATION.md).

## Corrected-lens crop and rotation

- Support preserved distortion correction from 0 through 100 on Capture One 16.8.5.30, using native bounds for crops, ratio fits, rotation, and full-frame context previews.
- Query bounds after corrected-lens rotation inside the journaled operation. Retain `requestedGeometry` before dispatch and the resolved target afterward (contract 1.6.0); reject dry runs that would require a new native rotation.
- Keep lens tilt/shift, keystone, flips, and crop-outside-image blocked. Preserve baseline restoration, state checks, and uncertain-mutation recovery.
- Add corrected-lens CLI/MCP, preview-coordinate, preservation, and timeout-recovery qualification. See [evidence and limits](docs/RELEASE_VALIDATION.md).

## Filtered inventory and request progress

- Filter ratings before fetching full summaries. Use qualified native predicates and bulk IDs for Capture One 16.8.5.30 Sessions, with a bounded rating-scan fallback for Catalogs and other allowed builds.
- Preserve inventory fields, ordering, selection/collection scope, and duplicate variants; serialize scans with writes and validate identity and membership between work units.
- Add background request diagnostics, CLI stderr progress/quiet modes, MCP progress notifications, and file-backed `request status` / `request_status` (contract 1.5.0, 20 MCP tools).
- Support inventory batch limits, deadlines, and cancellation between Apple Events without returning partial inventories or weakening mutation recovery.
- Add offline, native-predicate, packaged inventory, and concurrent status/progress qualification. See [inventory validation](docs/RELEASE_VALIDATION.md) for measurements and limits.

## Edit existing variants by default

- Add `variant edit` / `variant_edit`: snapshot an existing variant and bind an editing reference without creating another variant. All supported tonal fields and crop/rotation are editable with normal state checks; deletion remains clone-only.
- Retain initial adjustments/geometry in `.c1/editing.json`, expose baseline diffs, and add explicit state-checked `geometry restore` / `geometry_restore` (contract 1.4.0, 19 MCP tools).
- Reject expired clone references before native lookup, including when the old native ID no longer exists after restart.
- Read intrinsic image dimensions through ImageIO so rotating the first variant does not invalidate geometry bounds/readback.
- Make the crop and grading examples edit existing variants by default; `--clone` opts into separate proposals. Preserve document/app identity, journal recovery, and catalog opt-in/storage restrictions.

## Experimental catalog editing

- Add exact-path `C1_CATALOG_WRITE_PATH` opt-in for Catalog edits on Capture One 16.8.5.30; default Catalog inspection remains read-only.
- Bind Catalog references/recovery to the database inside the package, isolate journals/provenance per catalog, and expose `writesEnabled` in doctor/document responses (contract 1.3.0).
- Preserve clone/state/journal protections, reject offline originals, guard deletion against missing sources and last variants, and support catalog crop/tonal previews with a dedicated output folder.
- Initialize a missing catalog default output location for previews while preserving usable defaults. Add offline and disposable Catalog CLI/MCP coverage; see release validation for runtime limits.

## Crop and rotation

- Add shared CLI/MCP crop and rotation support, geometry reads/diffs/baselines, and independent `geometry-v1` preconditions; preserve the tonal contract.
- Journal geometry writes and recovery observations, validate readback and preview geometry, and provide temporary-clone context previews.
- Add the composition-only MCP profile and explicit crop proposal/review sidecar example.
- Add geometry fault, contract, live orientation/ratio, and extracted-archive checks. Contract version is 1.1.0; keystone writes remain out of scope.

## v0.1 release hardening

- Bind managed clones to exact database/app identity and parent image; enforce one open document.
- Journal all write paths before dispatch, preserve append-only recovery snapshots, block unresolved writes, and return operation IDs on uncertain failures.
- Write only requested fields and recheck state in the AppleScript handler.
- Fix custom preview routing; require a complete image in a unique job directory.
- Share CLI/MCP schemas and reject malformed requests before application access.
- Install/package the required resource bundle; test relocated archives and keep automated releases as drafts until validation.
- Add offline fault regressions; narrow support claims to demonstrated sequential single-document operation.
- Retry only transient reads of the reference returned by cloning; never repeat the clone command after an uncertain result.
- Add packaged live recovery qualification for actual Apple Event timeout, eventual preview output and MCP client death, with retained command/journal evidence and explicit coverage limits.
- Make release validation the current decision authority; reconcile historical identity, preview, Catalog and signing statements.

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.1.0] - 2026-09-07

### Added
- **Core Library (`CaptureOneCore`)**:
  - Fail-closed working-variant safety model: originals cannot be mutated directly; mutations strictly require a document-bound working clone (`c1_wrk_<uuid>`).
  - Optimistic concurrency control via SHA-256 adjustment state hashing (`--if-state`).
  - Strict Catalog read-only mutation guards preventing edits to Catalogs.
  - Cross-process advisory locking (`flock`) to serialize operations across CLI and MCP instances.
  - Pre-dispatch operation journaling (`.c1/journal.jsonl`) for tracking, auditing, and recovery.
  - FieldSpec registry for verified adjustments (`exposure`, `contrast`, `saturation`, `temperature`, `tint`) with tolerance-aware precision rounding and coupled white balance handling.
  - Read-only capture metadata extraction (`camera`, `lens`, `iso`, `shutterSpeed`, `asShotWB`, `captureDate`, `starRating`, `colorTag`).
  - Dedicated `c1-preview` recipe export with ImageIO decoding and pixel SHA-256 verification.
  - `testedBuilds` registry supporting multiple qualified Capture One builds (starting with `16.8.5.30`), with default compatibility and warning notes for Capture One 16.4+ through 16.x.
- **`c1` CLI Executable**:
  - 15 subcommands: `doctor`, `version`, `capabilities`, `schema`, `doc info`, `variants list`, `variant clone`, `variant delete`, `variant baseline`, `get`, `set`, `add`, `reset`, `diff`, `dump`, `preview`, `operation status`.
  - Machine-readable JSON (`--format json`), streaming JSONL (`--format jsonl`), and human-friendly table outputs.
  - Standardized error codes (`app-not-running`, `no-document`, `unsupported-version`, `unmanaged-variant`, `capture-one-busy`, `document-changed`, `state-changed`, `readback-mismatch`, `permission-denied`, etc.) and non-zero exit codes.
- **`c1-mcp` Server**:
  - Full-featured Model Context Protocol (MCP) server over stdio built on the official Swift MCP SDK (`modelcontextprotocol/swift-sdk`).
  - 16 registered tools with complete JSON schemas matching the CLI contract.
  - Dual text (JSON metadata) and visual `image/jpeg` base64 content blocks for variant previews.
- **Documentation & Workflows**:
  - [docs/QUALIFYING_NEW_BUILDS.md](docs/QUALIFYING_NEW_BUILDS.md): Step-by-step qualification runbook for testing and registering newly released Capture One builds.
  - GitHub Actions CI (`.github/workflows/ci.yml`) and Release workflow (`.github/workflows/release.yml`) for automated testing and tagged asset packaging.
  - End-to-end integration test suites (`Tests/integration_test.py` and `Tests/mcp_test.py`) with disposable Sessions and real RAW file verification.
  - 237 automated unit assertions in standalone test harness (`make test`).
