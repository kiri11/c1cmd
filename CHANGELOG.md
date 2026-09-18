Entries describe changes at their recorded contract version. See the [README](README.md)
for current behavior and [release validation](docs/RELEASE_VALIDATION.md) for current
support limits and test-selection policy.

## Unreleased — metadata editing and validation workflow

- Add rating (0–5) and native color-tag (0–7) writes through CLI `metadata set` and MCP `metadata_set` (contract 1.9.0). Require an editing or managed-clone reference and a fresh metadata state token; preserve omitted fields.
- Save metadata baselines, expose metadata differences, and journal writes with native concurrency and readback checks. The composition profile excludes metadata writes. See [qualification and limits](docs/metadata/16.8.5.30/README.md).
- Default `make qualify` to packaged CLI, MCP, and existing-variant workflows; select affected suites with `QUALIFY_SUITES`, or all nine with `make qualify-extended`.
- Select recovery cases by changed behavior with `RECOVERY_CASES`. Affected recovery and fault-harness changes require live fault validation; unrelated changes and release checkpoints alone do not. A separate user request is not required.
- Remove superseded M0 feasibility probes/evidence and the old follow-up roadmap; retain feature/recovery qualification evidence and consolidate current support guidance.

## Unreleased — keystone corrections

- Add absolute keystone amount, vertical, horizontal, skew, and aspect controls to CLI `geometry set` and MCP `geometry_set` (contract 1.8.0), including the composition profile.
- Preserve omitted controls, tonal edits, lens settings, and native variant identity. Validate native ranges before dispatch, obtain fresh crop bounds after transforms, and verify all five controls on readback.
- Include keystone changes in diffs and durable geometry requests. Restore baseline keystone with crop/rotation through `geometry_restore`; reject predictive dry runs for keystone changes.
- Add CLI/MCP control-range, preview, restoration, and referenced-Catalog coverage, plus a keystone timeout-recovery test case. See [qualification](docs/geometry/16.8.5.30/keystone/README.md).

## Unreleased — preserved keystone and lens movements

- Enable crop, rotation, ratio fitting, context preview, and baseline restoration while preserving existing keystone and lens tilt/shift on Capture One 16.8.5.30 (contract 1.7.0).
- Validate native ratio-fit shrinkage inside the proposed rectangle. Keep explicit crops strict and retain native automatic crops for rotation-only requests.
- Reject dry runs that would need native rotation or perspective/movement ratio normalization. Keep journal, state, context, and recovery checks.
- Make real timeout/process-death validation opt-in via `qualify-recovery` or `qualify-full`; normal `qualify` retains offline and packaged live workflow checks.
- Add representative movement-profile and keystone workflows, coordinate checks, and a combined-correction timeout case. See [qualification](docs/geometry/16.8.5.30/perspective/README.md).

## Unreleased — corrected-lens crop and rotation

- Support preserved distortion correction from 0 through 100 on Capture One 16.8.5.30, using native bounds for crops, ratio fits, rotation, and full-frame context previews.
- Query bounds after corrected-lens rotation inside the journaled operation. Retain `requestedGeometry` before dispatch and the resolved target afterward (contract 1.6.0); reject dry runs that would require a new native rotation.
- Keep lens tilt/shift, keystone, flips, and crop-outside-image blocked. Preserve baseline restoration, state checks, and uncertain-mutation recovery.
- Add corrected-lens CLI/MCP, preview-coordinate, preservation, and timeout-recovery qualification. See [evidence and limits](docs/geometry/16.8.5.30/lens/README.md).

## Unreleased — filtered inventory and request progress

- Filter ratings before fetching full summaries. Use qualified native predicates and bulk IDs for Capture One 16.8.5.30 Sessions, with a bounded rating-scan fallback for Catalogs and other allowed builds.
- Preserve inventory fields, ordering, selection/collection scope, and duplicate variants; serialize scans with writes and validate identity and membership between work units.
- Add background request diagnostics, CLI stderr progress/quiet modes, MCP progress notifications, and file-backed `request status` / `request_status` (contract 1.5.0, 20 MCP tools).
- Support inventory batch limits, deadlines, and cancellation between Apple Events without returning partial inventories or weakening mutation recovery.
- Add offline, native-predicate, packaged inventory, and concurrent status/progress qualification. See [inventory validation](docs/inventory/16.8.5.30/README.md) for measurements and limits.

## Unreleased — edit existing variants by default

- Add `variant edit` / `variant_edit`: snapshot an existing variant and bind an editing reference without creating another variant. All supported tonal fields and crop/rotation are editable with normal state checks; deletion remains clone-only.
- Retain initial adjustments/geometry in `.c1/editing.json`, expose baseline diffs, and add explicit state-checked `geometry restore` / `geometry_restore` (contract 1.4.0, 19 MCP tools).
- Reject expired clone references before native lookup, including when the old native ID no longer exists after restart.
- Read intrinsic image dimensions through ImageIO so rotating the first variant does not invalidate geometry bounds/readback.
- Make the crop and grading examples edit existing variants by default; `--clone` opts into separate proposals. Preserve document/app identity, journal recovery, and catalog opt-in/storage restrictions.

## Unreleased — experimental catalog editing

- Add exact-path `C1_CATALOG_WRITE_PATH` opt-in for Catalog edits on Capture One 16.8.5.30; default Catalog inspection remains read-only.
- Bind Catalog references/recovery to the database inside the package, isolate journals/provenance per catalog, and expose `writesEnabled` in doctor/document responses (contract 1.3.0).
- Preserve clone/state/journal protections, reject offline originals, guard deletion against missing sources and last variants, and support catalog crop/tonal previews with a dedicated output folder.
- Initialize a missing catalog default output location for previews while preserving usable defaults. Add offline and disposable Catalog CLI/MCP coverage; see release validation for runtime limits.

## Unreleased — crop and rotation

- Add shared CLI/MCP crop and rotation support, geometry reads/diffs/baselines, and independent `geometry-v1` preconditions; preserve the tonal contract.
- Journal geometry writes and recovery observations, validate readback and preview geometry, and provide temporary-clone context previews.
- Add the composition-only MCP profile and explicit crop proposal/review sidecar example.
- Add geometry fault, contract, live orientation/ratio, and extracted-archive checks. Contract version is 1.1.0; keystone writes remain out of scope.

## Unreleased — v0.1 release hardening

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
