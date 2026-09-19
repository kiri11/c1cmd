# Result bundle qualification — 2026-09-19

Capture One 16.8.5.30, Apple Silicon, an owned disposable Session and copied RAW.
[Summary](summary.json) records the archive, CLI/MCP and RAW hashes.

- [Offline checks](offline.log): 1,170 assertions passed, plus CLI/MCP contract,
  malformed-request, composition-profile and Python checks.
- [Packaged qualification](qualification.log): release tests, relocated binary
  contract checks and the selected `recipes` live suite passed.
- [Live observations](recipes/results.json): CLI verification and MCP application
  returned consolidated bundles. Assertions checked original-to-final exposure
  changes, native settings, recipe/reference/photo provenance, verification linkage,
  effective overrides, initial/final hashes, child operation IDs, preview existence,
  response schema and exact equality with durable status. Existing checks covered
  paired white balance, geometry, variant count and both RAW checksums.

Offline checks also cover absent bundles for unknown/interrupted runs and null
previews when omitted. The live fixture closed successfully; Capture One stayed running.

Unrelated regular suites and live fault injection were omitted: these changes add
result presentation and a fresh pre-edit native observation without changing mutation
dispatch, journaling, lock ownership, token validation or recovery decisions. The
[earlier compound recovery campaign](../qualification/README.md) remains separate
historical evidence, not a new fault qualification of this build. Catalogs and
execution-context/read-cache optimization are outside this focused validation.
