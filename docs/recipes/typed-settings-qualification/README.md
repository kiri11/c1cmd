# Typed recipe settings qualification — 2026-09-19

Capture One 16.8.5.30 on Apple Silicon; owned disposable Sessions and copied RAWs.
[Summary and hashes](summary.json) identify the same archive and CLI/MCP binaries
used by regular and recovery qualification.

## Passed coverage

- [Offline checks](offline.log): 1,187 assertions; shared CLI/MCP schemas, invalid
  requests, composition restrictions and Python checks. Includes typed curves and
  enums, malformed-curve/type/policy rejection, and independent oracle mismatches
  for omitted curves, grain and vignette. The final archive repeated all core and
  Python checks in [packaged qualification](final/qualification.log).
- [Regular observations](final/recipes/results.json): all five curves with distinct
  points, grain type/impact/granularity, vignette method/amount, independent payload
  verification, per-photo curve/grain/vignette overrides, consolidated result diffs
  and durable status. A second sparse recipe preserved all omitted non-default
  native settings and explicit exposure/WB/crop preserve policies. Variant count
  and original/copied RAW hashes stayed unchanged. Grain modes exercised were
  fine, silver rich and soft; all three vignette methods were observed.
- [Recovery events](recovery/events.jsonl) and [journal](recovery/journal.jsonl):
  native settings timeout with a curve/grain/vignette payload stopped the compound,
  retained before-state/child IDs, blocked further writes, required restart and
  reconciliation, rejected stale references, and kept the parent outcome unknown.
  MCP caller death after a completed settings step retained an interrupted parent
  and its linked child without dispatching the later preview or resuming work.
  Both cases passed; cleanup left Capture One running with zero open documents.

The fault harness used the real Apple Event timeout, its independent resume
watchdog and SIGTERM only for its owned fixture. No production shutdown behavior
or automatic retry/undo was added.

## Limits and intermediate runs

This is focused recipe qualification, not the full native or recovery matrix.
Unrelated regular suites and tonal, geometry, preview and native-action faults
were omitted because their mutation and recovery paths did not change. Catalogs,
color-band transfer, layers/masks and camera/lens profiles remain outside scope.
Numeric/point equality does not establish visual quality; preview review is still
required. Grain modes cubic, tabular and harsh are schema/native enum options but
were not exercised in this live campaign.

The initial [document guard](regular/document-guard.log) stopped before live work
because the previous owned fixture was open. Its identity and journal were checked
before closing it. A [development run](development-oracle/results.json) then found
an AppleScript name collision (`points` resolved to an application object) in the
new independent reader. It failed during preparation before recipe writes. The
variable was renamed, the failed evidence retained, and the final rebuilt archive
passed on a fresh fixture. No uncertain operation was retried. Subsequent edits
only updated documentation and retained evidence.
