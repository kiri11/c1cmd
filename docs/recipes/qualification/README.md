# Recipe qualification — 2026-09-19

Capture One 16.8.5.30, Apple Silicon, disposable Sessions with copied RAWs.
[Summary and binary hashes](summary.json) identify the tested release archive.
The regular workflow and all five compound recovery cases used the same CLI/MCP
binary hashes. Post-qualification source edits only corrected indentation/comments;
documentation and harness evidence-copying instructions were also completed afterward.

## Passed coverage

- `make check`: 1,154/1,154 Swift assertions, CLI/MCP schemas and malformed-request
  rejection, composition-profile restrictions, generated-resource checks, existing
  Python checks and the three compound-harness checks. See [offline log](offline.log).
- Packaged `recipes` suite: reference capture and JPEG checksum, all fourteen
  recipe setting fields, relative exposure, independent payload verification,
  explicit per-photo settings/exposure/WB overrides, optional geometry and preview,
  returned final observations, durable status equality, variant-count preservation,
  and unchanged original/copied RAW checksums. See [results](packaged/results.json)
  and [packaged runner log](packaged-run/qualification.log).
- Four compound Apple Event timeouts: tonal, native settings, geometry and preview.
  Actual pause-to-reply durations were approximately 120 seconds. Each case retained
  parent/child IDs, stopped subsequent steps, blocked writes, required restart plus
  explicit reconciliation, rejected stale references and preserved the original
  compact state/geometry and RAW checksum. Reconciled children did not promote the
  parent to success. See [events](recovery/events.jsonl) and [journal](recovery/journal.jsonl).
- MCP caller death after a native settings step succeeded: parent remained
  interrupted, status recovered the exact linked child, no later child was pending,
  and no automatic continuation occurred. The retained parent does not claim
  historical compound completion.

The recovery harness used SIGTERM only for its owned fixture restarts, with an
independent resume watchdog during application suspension. Final cleanup closed
its Session and left Capture One running with zero open documents. The production
CLI/MCP gained no application-shutdown behavior.

## Scope limits and intermediate runs

This is focused recipe qualification, not the full regular/recovery campaign.
Catalog workflows, layer/mask/curve or indexed-color recipe transfer, lens/profile
transfer, unrelated native actions and cross-document recipe migration were not
qualified. Numeric verification is not aesthetic approval; previews require review.

An initial development harness run hit a JSON serialization error after a successful
reference export; its journal had no unresolved operation. A second development
run correctly refused verification when the native `highlight recovery` alias
changed with `highlight adjustment`. The final verifier explicitly checks that
opposite-sign relationship. Retained [intermediate observations](development-2/results.json)
are not qualification of that earlier implementation.

One overlapping offline run encountered the live harness's application lock. The
final offline run above was repeated sequentially after all live cases completed
and passed. Do not run offline fake-executor tests concurrently with live suites.
