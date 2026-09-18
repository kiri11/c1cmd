# Rating and color tag editing — Capture One 16.8.5.30

Normal qualification passed: **907/907 offline assertions**, **25 recovery-harness tests**, shared CLI/MCP contract/profile checks, and all **nine packaged live suites**. Both Session and referenced-Catalog metadata workflows passed with unchanged RAW checksums and no duplicate variants. The archived live run took 1713 seconds.

Contract **1.9.0** adds `metadata_set` / `c1 metadata set` for integer ratings
0–5 and native color tags 0–7. Zero clears the field. This API is available in
the default MCP profile and hidden in the geometry-only composition profile.

The `metadataStateHash` returned by `get` covers both fields. It is independent
of tonal and geometry tokens, which retain their existing meanings. Writes
require an authorized existing-variant or managed-clone reference, the exact
qualified application build, the normal document/image guards, and a fresh
metadata precondition. The native handler checks both metadata values and the
parent image immediately before its setters. It writes only requested fields.

New editing and clone records save `baselineMetadata`; old records remain
decodable without this optional field. `diff` includes metadata changes and the
saved baseline values can be restored with an explicit metadata set and a fresh
token. Tonal `reset` retains its previous semantics. Journals retain before,
intended, and observed metadata. Native writes are sequential: any uncertain
reply or readback failure blocks subsequent writes. Reconciliation after restart
records current observations without claiming historical completion.

Validation results and payload hashes are recorded in `summary.json` and the
retained qualification log. The metadata cases are part of
`Tests/existing_variant_integration_test.py`, run through the extracted archive
with build resources hidden. They exercise every supported rating and tag,
clearing, partial-field preservation, dry runs, stale-token rejection after a
photographer change, native-ID write rejection, baseline restoration, journals,
rating filters, unchanged tone/geometry, and RAW checksums in both a disposable
Session and an explicitly enabled referenced-original Catalog. Catalog opt-out
also rejects metadata writes on a previously authorized reference.

Offline tests additionally cover invalid types/ranges/empty patches, dispatch-time
conflicts, simulated partial writes and unexpected readback, unresolved-operation
blocking, restart reconciliation, expired references, version/document guards,
and backward-compatible baseline decoding. These are mocked failure checks.
No deliberate live timeout or process-death campaign is included or claimed.
Catalog-stored originals, concurrent UI editing during a call, and other Capture
One builds remain outside the qualified boundary.

Reproduce with:

```sh
make qualify C1_TEST_RAW_FIXTURE=/path/to/preserved.CR3 EVIDENCE_DIR=/new/evidence/path
```

Start with zero open documents and exclusive Capture One use. Source RAWs and
preview images are not included in retained repository evidence.
