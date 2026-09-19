# Read performance and optimization work

The first implementation from `suggestions.md` establishes reproducible read timings
using local data. Historical wedding timings are motivation, not a baseline that
can be reproduced without those files and application conditions.

## Opt-in internal timing

Set `C1_PROFILE=1` on either CLI or MCP. JSON-lines diagnostics go to stderr;
normal JSON and MCP stdout are unchanged. Version 1 records contain `type`,
`version`, `pid`, `phase`, `handler`, `elapsedMs`, and `succeeded`. Arguments,
property values, image paths, and mutation tokens are not logged. Timing uses a
monotonic clock; disabled profiling invokes the original operation directly.
Errors propagate unchanged and diagnostic write failures are ignored.

Phases:

- `script_compile`: cache-miss compilation, separately for base/native scripts.
- `script_lookup`: cache lookup, resource loading and compilation if needed.
- `apple_event`: synchronous handler execution and error mapping.
- `handler_total`: lookup, event construction and execution.
- `descriptor_decode`: conversion of the native result to typed Swift data.

Phases are nested: do not sum them as independent durations. `apple_event` includes
all property reads performed by that handler, not individual native property
latencies. File/journal scans, geometry calculations inside AppleScript, export
polling and other controller work are not yet independently instrumented. This
is deliberately a first measurement slice; it does not change dispatch, locking,
timeouts, journaling, preconditions, or recovery.

## Compare fresh CLI and persistent MCP

Build both executables, open exactly one local disposable Session, and obtain a
native variant ID with `c1 variants list`. Keep Capture One and the photo untouched
until the comparison finishes. Use a small sample first:

```sh
python3 scripts/benchmark-reads.py --ref 1 --samples 5 \
  --conditions 'local disposable RAW; screen unlocked; no competing exports; debug build' \
  --output /tmp/read-benchmark.json
```

Use `--cli .build/release/c1 --mcp .build/release/c1-mcp` after `make build` for
release timings. Each pair performs the same `get` and adjustment-scope
`native_get` through a fresh CLI process and one persistent MCP process. Calls
are sequential. Order alternates; the first pair is recorded as warmup and
excluded from medians. Every returned payload must match the first observation
for that operation. Document information must match at the start and end.
Changes, errors and timeouts stop the run, retain partial evidence, and yield a
nonzero exit. No read is automatically retried. Output files cannot be overwritten.

CLI elapsed time includes process startup; MCP elapsed time excludes server
startup/initialization. This measures sustained batch use, not single-command
latency. Profiling is enabled for both sides; stderr is drained to a temporary
file for MCP to avoid pipe backpressure. The report includes raw samples and
phase records (groupable by PID), build paths, fixture document, and supplied
conditions. Record actual screen lock/application load conditions, rather than
assuming locking caused historical slowdowns.

The runner only invokes `doc_info`, `get`, and `native_get`; it does not export,
prepare editing references, apply recipes or mutate variants. It closes only its
own MCP child process and leaves Capture One open.

## Next work

Use measured handler costs to prioritize bounded multi-scope reads and a shared
validated context. Before direct palette writes, reproduce indexed-band reads
against the independent bulk oracle on disposable local data. Catalog discovery
requires local schema fixtures and SQL/native comparisons; do not infer schema
support from the absent wedding archive. Compound mutations, recipe application,
and preview caching need separate designs and affected live/recovery qualification.

## Local measurement: 2026-09-19

[Raw debug-run evidence](local-debug-reads.json) records Capture One 16.8.5.30,
one disposable Session and a copied local `2U6A7257.CR3`. Five measured pairs
followed one warmup pair. All returned read payloads stayed equal. Screen lock
state was not observed; other application load was uncontrolled.

| Read | Fresh debug CLI median | Persistent debug MCP median | Lower elapsed time |
| --- | ---: | ---: | ---: |
| `get` | 1,312 ms | 956 ms | 27% |
| `native_get` adjustments | 4,113 ms | 3,656 ms | 11% |

Across the recorded events (including warmup), median `nativeRead` execution was
2,435 ms, `getAdjustmentsBatch` 884 ms and `getAppAndDocInfo` 98 ms. Median base
compilation was 66 ms; native compilation 86 ms. The persistent process compiled
each script once; fresh CLI processes repeatedly compiled their required scripts.
The total difference also includes process startup and varying application costs;
it cannot all be attributed to compilation.

For batch consumers, reuse one MCP process and keep calls sequential. This is an
existing execution-path optimization, not a new daemon or a claim that core
native reads became faster. The data points toward reducing native property round
trips next; it does not justify removing identity or state checks. These results
are not release-build measurements, wedding-run reproduction, export measurements,
or evidence of a whole-workflow speedup.

Validation: `make check` passed 965 Swift assertions, the shared CLI/MCP contract
suite, generated native-resource checks, recovery-harness and release-runner
checks, and two benchmark protocol/evidence tests. An additional enabled-profile
run verified JSON stderr records for successful and failing closures and original
error propagation. The live read comparison is the only live coverage in this
slice. Mutation, export and recovery fault campaigns were omitted because this
change adds timing/reporting only and leaves their behavior and assertions intact.
