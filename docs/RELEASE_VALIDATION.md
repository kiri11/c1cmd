# v0.1 release validation

This document records release hardening after the M0 qualification. It does not broaden the M0 single-document, sequential-operation boundary.

## Changes under validation

- Exact canonical database path/file identity and app-launch binding; managed parent-image validation. No automatic reference rebinding across app restart.
- One-open-document guard in both Swift discovery and AppleScript dispatch.
- Pre-dispatch journaling for all write paths, durable append-only snapshots, conservative restart-based reconciliation, and operation IDs in error responses.
- Requested-field writes and a second expected-state check inside the AppleScript handler.
- Unique preview output paths, complete-file polling, and variant/state association.
- Shared CLI/MCP contract and strict input validation.
- Offline fault injection, removal of live application dependency from the unit suite, resource bundle installation, archive testing.

## Simplification decisions

Removed duplicate CLI/MCP schema definitions, hand-maintained MCP input schemas, duplicated clone/baseline orchestration, source-checkout AppleScript fallbacks, and whole-journal rewriting. These mechanisms either drifted or masked deployment failures.

Keep the native baseline operation: it is useful for controlled style comparisons and now shares creation/recovery code with cloning. Keep the M0 probes and evidence as qualification history, but do not treat their broad experimental scripts as production APIs. Defer Session creation, importing, caches, callbacks, and broader adjustments; adding them would expand the safety surface without helping the current release.

The supported fields and schemas are shared. The five-field state hash is not a complete render fingerprint. Do not use it to cache or label arbitrary layered/geometry/style renders.

## Verification results

Completed on 2026-09-07 on Apple Silicon (arm64, macOS 26.6.2 / Build 25G83) against qualified build **Capture One 16.8.5.30**:

### 1. Offline Unit Suite (`make test`)
- **331 / 331 assertions passed** across 12 test suites:
  - `FieldSpecTests`: bounds, precision, coupled white-balance normalization, and alias handling.
  - `StateHashTests`: canonical hashing across permutations and tolerance boundaries.
  - `WorkingReferenceTests` & `ProvenanceStoreTests`: working reference generation, durable serialization, and lookup.
  - `OperationJournalTests`: pre-dispatch append-only snapshots, crash simulation, and recovery state transitions.
  - `LockTests`: advisory lock acquisition, contention, and timeout handling.
  - `ResetTests`: selective and full field reset calculation.
  - `DiffTests`: single-ref baseline and two-ref differential formatting.
  - `DumpTests`: chunking and projection validation.
  - `CatalogGuardTests`: fail-closed guard verification across all mutation operations.
  - `VersionCompatibilityTests`: exact-build matching and untested-build gating.
  - `ReleaseSafetyTests`: fail-closed mutation barriers, document-token enforcement, and offline fault injection.

### 2. Contract and Schema Parity (`Tests/contract_test.py`)
- CLI (`c1 schema`) and MCP (`schema` tool) return byte-for-byte identical contract schemas.
- All 16 tools in `tools/list` match their declared request definitions.
- Read-only and destructive annotations confirmed (`preview` and `operation_status` are mutating; `variant_delete` is destructive).
- 13 invalid request and malformed parameter tests rejected with standard `invalid-request` error code before application access.
- Server survived malformed requests with zero crashes.

### 3. Archive Packaging and Relocation (`Tests/archive_test.py`)
- Packaged release archive `c1-v0.1.0-macos-arm64.tar.gz` and `.sha256` checksum verified.
- Resource bundle `c1_CaptureOneCore.bundle` verified co-located beside executables.
- Archive extracted to clean `/private/tmp` directory; relocated CLI and MCP server verified offline.

### 4. Extracted Release Live Integration (`Tests/release_integration_test.py`)
Executed against extracted release binaries with build-tree resources hidden (`.build/release/c1_CaptureOneCore.bundle` relocated):
- **CLI Suite (`Tests/integration_test.py` — 19 / 19 steps passed):**
  - Verified `doctor`, `doc info` (token binding), and `variants list`.
  - Unmanaged variant mutation strictly rejected (`unmanaged-variant`).
  - Cloned working reference created (`variant clone`) and validated against provenance.
  - Optimistic concurrency enforced (`--if-state`).
  - Absolute adjustments (`set`) and delta adjustments (`add`) applied and verified via readback.
  - Dedicated `c1-preview` recipe export, polling, ImageIO decode, and pixel SHA-256 verified.
  - Managed clone cleanly deleted (`variant delete`).
  - **Zero RAW corruption:** Canon EOS R `.CR3` RAW fixture remained byte-for-byte identical (`SHA-256: ef6a7eadaff3bdcc0c1fbff365151d375121639966337b01a6fce4a9ab67e452`) throughout all operations.
  - `examples/grade-folder.py` automated grading workflow verified on live Session with sidecar decision records.
  - Baseline variant creation (`variant baseline`), diffing (`diff`), and field reset (`reset`) verified.
  - Streaming JSONL export (`dump`) verified.
  - Catalog mutation guard strictly blocked `clone`, `set`, `add`, `reset`, `baseline`, and `delete` on an open Catalog.
- **MCP Stdio Suite (`Tests/mcp_test.py` — 10 / 10 steps passed):**
  - Handshake and tool listing (all 16 tools discovered).
  - Read-only metadata discovery and doctor check.
  - Unmanaged variant mutation rejected over MCP.
  - Managed working clone and baseline creation.
  - `set`, `add`, `diff`, and `reset` executed over MCP.
  - Preview tool verified: JSON metadata and dual `image/jpeg` base64 visual content block decoded and validated (JPEG magic header confirmed).
  - Clean variant deletion.
  - Catalog fail-closed mutation barrier verified over MCP.

