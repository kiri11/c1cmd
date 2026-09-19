# Read performance

Use a persistent MCP process for sequential batch workflows. `get` accepts one or
several native scopes through `nativeTargets`, sharing source validation across
scopes. See [scoped reads](../native-editing/README.md#scoped-reads).

## Internal timing

Set `C1_PROFILE=1` on CLI or MCP. JSON-lines diagnostics go to stderr, and command
results go to stdout. Version 1 timing records contain `type`, `version`, `pid`,
`phase`, `handler`, `elapsedMs`, and `succeeded`. Timing uses a monotonic clock.
Diagnostic write failures are ignored; operation errors propagate to the caller.

| Phase | Measures |
| --- | --- |
| `script_compile` | Cache-miss compilation, separately for base/native scripts |
| `script_lookup` | Cache lookup, resource loading and any required compilation |
| `apple_event` | Synchronous handler execution and error mapping |
| `handler_total` | Lookup, event construction and execution |
| `descriptor_decode` | Conversion of a native result to typed Swift data |

Phases are nested; interpret their durations separately. `apple_event` includes
all property reads performed by its handler.

## Compare fresh CLI and persistent MCP

Build both executables, open exactly one disposable Session, and obtain a native
variant ID with `c1 variants list`. Keep Capture One and the photo untouched
until the comparison finishes:

```sh
python3 scripts/benchmark-reads.py --ref 1 --samples 5 \
  --conditions 'local disposable RAW; screen unlocked; no competing exports; debug build' \
  --output /tmp/read-benchmark.json
```

Use `--cli .build/release/c1 --mcp .build/release/c1-mcp` after `make build` for
release timings. Each pair performs compact and adjustment-scope `get` calls
through fresh CLI processes and one persistent MCP process. Calls are sequential.
Order alternates; the first pair is recorded as warmup and excluded from medians.

Every returned payload must match the first observation for that operation.
Document information must match at the start and end. Changes, errors and
timeouts stop the run, preserve partial evidence, and produce a nonzero exit.
Each run requires a new output file.

CLI elapsed time includes process startup. MCP elapsed time starts after server
initialization, measuring sustained batch use. Both sides enable profiling.
MCP stderr goes to a temporary file to keep the diagnostic stream drained. The
report records raw samples, phase records grouped by PID, executable paths,
document identity and supplied conditions. Record screen lock and application
load conditions for each run.

The runner invokes `doc_info` and `get`, closes its MCP child process when finished,
and leaves Capture One open.

## Compare single-scope and combined reads

Run both forms of `get` in the same persistent release MCP process:

```sh
python3 scripts/benchmark-scoped-get.py --ref 1 --samples 5 \
  --conditions 'local disposable RAW; screen unlocked; no competing exports; release build' \
  --output /tmp/scoped-get-benchmark.json
```

Both forms request adjustment, lens and variant scopes and return compact source
fields. Native values and scope tokens must match across every observation.
Order alternates; one warmup pair is excluded. The report includes the MCP binary
SHA-256, document identity, native snapshot digest, phase timings and raw samples.

## Validation and interpretation

Use `make check` for benchmark-runner and generated-resource checks. Changes to
native reads need the affected packaged `native` or `recipes` suites; select
`native native-action` recovery only when mutation preparation or recovery changes.
Record fixture/build/application conditions with each measurement. A local speed
comparison does not establish general scaling, state freshness, or aesthetic quality.
Store generated reports outside tracked docs, for example under `.build/benchmarks`.
