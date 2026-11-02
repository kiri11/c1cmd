# Maintainer guide

How c1 is built, checked and released. Usage is in the [README](../README.md); the safety rules and live-check
rules are in [AGENTS.md](../AGENTS.md).

## Layout

- `Sources/C1Kit` holds everything: the command table (`Command.swift`) with one argument spec per command, the
  queue every process waits in (`CaptureOneQueue.swift`), the Apple Event scripts (`AppleScriptCaptureOne.swift`),
  the SQLite reads (`Database.swift`), writes, snapshots and the log (`Writes.swift`, `Store.swift`), and previews.
- `Sources/c1/main.swift` parses `c1 <command> '<json>' [--document <path>] [--pretty]` and prints the result.
- `Tests/C1KitTests` is a plain executable runner (Swift Testing needs Xcode). `FakeCaptureOne.swift` answers the
  Apple Events, so writes, previews and timeouts run offline and in CI.
- `skills/` ships in the plugin zip. `scripts/package-plugin.sh` builds the zip.

### Generated files

`scripts/generate.sh` writes `Sources/C1Kit/Generated/Embedded.swift`, which builds `Resources/Defaults.json`,
`Resources/Bounds.json` and the sdef terms c1 uses into the binary, and `docs/reference/commands.md`, whose example
results are recorded against the fake Capture One. `make check` fails when either is stale.

## Checks

| Command | What it runs | Where |
|---|---|---|
| `make check` | Debug build and every offline test, including the generated-file checks | CI on every branch and pull request, and before each release |
| `make plugin [VERSION=…]` | Builds `dist/c1-plugin.zip`, then `scripts/check-plugin.sh`: execute bit, signature, help, exit codes, the permission script, and isolated plugin installs when `claude` or `codex` is on PATH | CI, and locally |
| `make smoke` | `make plugin`, then `scripts/smoke.py`: reads, writes and viewing through the zip's `c1`, on a disposable Session and a disposable Catalog | Locally only |

`make smoke` needs Capture One 16.8.5.30 with no document open, and `C1_TEST_RAW_FIXTURE` naming a RAW it may copy.
It takes a few minutes, prints a JSON report, and leaves each document's evidence in `.build/c1-smoke-<kind>-*/`.
`--kinds session` runs one kind.

Choose by what changed:

| Change | Run |
|---|---|
| Docs, skills or tests only | `make check` |
| Code that never reaches Capture One (parsing, validation, help, SQLite reads) | `make check` |
| Apple Event scripts, writes, revert, previews, the queue or packaging | `make check`, then `make smoke` |
| A new Capture One build | [Qualify a new build](#qualify-a-new-capture-one-build) |

### Deeper live checks

Each runs on its own disposable document (`C1_TEST_DOCUMENT_KIND=session|catalog`) and prints a JSON report:

| Script | Checks |
|---|---|
| `scripts/check-editor.py` | Curves and the color editor: bulk `get` against per-field reads, and a `set`/`revert` round trip beside a photographer's untagged layer |
| `scripts/check-viewing.py` | What the full-frame export renders, that a queued export ignores later changes, region mapping, and preview timings |
| `scripts/compare-fields.py` | Every field of a bulk `get` against its own Apple Event, on any variant (read-only) |
| `scripts/measure-bounds.py` | Measures every numeric field's accepted range and rewrites `Resources/Bounds.json` |
| `scripts/defaults.py` | Rewrites `Resources/Defaults.json` from an unedited variant |

## Releases

Every push to `main` publishes a release. `release.yml` runs `make check`, builds the plugin as version
`2.0.<run number>`, publishes it as the latest release (`c1-plugin.zip`, `marketplace.json` and `SHA256SUMS`), then
commits `.claude-plugin/marketplace.json` to `main` so Claude Code sees the new version. Pull before your next push:
that commit is on `main` only. A push made with the workflow's token starts no new run.

Live checks cannot run in CI, so run the checks the change needs **before pushing to `main`**.

## Qualify a new Capture One build

1. Save the new dictionary and compare it with the built-in one:

   ```sh
   sdef "/Applications/Capture One.app" > "sdef/<version>.sdef"
   diff -u sdef/16.8.5.30.sdef "sdef/<version>.sdef"
   ```

   `doctor` on the new build already reports which used terms differ.
2. Find the build assumptions with `rg -n '16\.8\.5\.30' Sources Tests scripts`: `Service.testedBuilds`, the sdef path
   in `Tests/C1KitTests/Generated.swift`, `BUILD` in `scripts/fixture.py`, and the comments that record a
   measurement.
3. Re-measure on a disposable document: `scripts/measure-bounds.py` and `scripts/defaults.py`, then
   `scripts/generate.sh` and `make check`.
4. Run `make smoke`, and `scripts/check-editor.py` and `scripts/check-viewing.py` for both document kinds. Record what
   changed in the commit message or the issue.

## Evidence

Live checks keep their documents, reports and previews under `.build`, which git ignores. Keep a failed run's folder
until the failure is understood. Do not commit RAWs, previews or disposable documents. Put a short summary in the
commit message or the issue.
