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

Pending final debug and extracted release runs. This section is updated only with completed checks.
