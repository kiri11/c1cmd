# Qualifying new Capture One builds

Qualification is exact-build and machine-sensitive. The
[release validation report](RELEASE_VALIDATION.md) records current evidence and
limits; adding a version string alone does not qualify a build.

## Compatibility and feature gates

| Build | Behavior |
|---|---|
| Listed in `SessionController.testedBuilds` | `exactBuildMatched: true`; other doctor checks must still pass. |
| Unlisted 16.4+ through 16.x | Allowed with a compatibility warning; `exactBuildMatched: false`. |
| Below 16.4 or 17+ | Rejected unless `C1_ALLOW_UNTESTED_BUILD=1` is explicitly set. |

Compatibility and feature authorization are separate. Existing-variant editing,
geometry, metadata, Catalog writes, and native inventory filtering have their own
build gates. An override or a passing `doctor.allChecksPassed` does not qualify
those paths or bypass their restrictions. Check `writesEnabled` and
`exactBuildMatched` too.

## Prepare the candidate

Preserve the source RAW outside build/scratch directories. Close all documents
and reserve exclusive use of Capture One. Tests must create their own disposable
Sessions/Catalogs; do not use a main Catalog to qualify a new build.

Save the installed application's dictionary and compare it with the retained
[SDEF](../sdef/16.8.5.30.sdef):

```sh
sdef "/Applications/Capture One.app" > "sdef/<version>.sdef"
diff -u sdef/16.8.5.30.sdef "sdef/<version>.sdef"
```

Review property codes and ranges, clone/delete/process commands, crop bounds and
keystone controls, ratings/tags, recipe behavior, and inventory predicates.
Dictionary compatibility is only a starting point; native behavior needs testing.

Locate explicit build assumptions before adapting the candidate:

```sh
rg -n '16\.8\.5\.30|testedBuilds|pinnedBuild' Sources Tests probes
```

Update the relevant guards, capability/schema declarations, and harness assertions
together on the candidate branch. Those changes enable qualification; do not
publish them as supported until the corresponding checks pass. Keep unsupported
paths gated if coverage is incomplete.

## Run offline and packaged feature checks

Start with `make check` for Swift assertions, CLI/MCP contract/profile parity,
and mocked harness/recovery guards. Tool counts and supported fields come from
the shared contract, not a fixed count in this guide.

For a new application build, exercise all regular matrices against an extracted
candidate archive:

```sh
make check
export C1_TEST_RAW_FIXTURE=/absolute/path/to/preserved.CR3
make qualify-extended EVIDENCE_DIR=/absolute/path/to/new-feature-evidence
```

This builds release, checks the package with build-tree resource fallback hidden,
and runs `cli mcp geometry lens perspective keystone catalog existing inventory`
sequentially. Existing-variant cases include metadata writes in both Session and
referenced-original Catalog fixtures.

Verify native identity/count and RAW preservation, concurrency tokens, clone-only
deletion, existing-variant baseline/restore, previews and coordinate mapping,
geometry with lens/perspective corrections, keystone controls, every metadata value,
Catalog opt-out, filtering, request progress and cancellation. Preserve fixture and
lens-profile limits; a single RAW does not establish broad camera/lens coverage.

For ordinary development on an already qualified build, `make qualify` defaults
to `cli mcp existing`. Select only affected suites with `QUALIFY_SUITES`, or use
`make qualify-extended` for all ten. See each retained feature report for native
probes and detailed coverage.

## Qualify recovery separately

A new application build can affect every native recovery path. Use the archive
built above and a new evidence directory:

```sh
make qualify-recovery RECOVERY_CASES=all \
  C1_RECOVERY_SHUTDOWN_MODE=sigterm \
  EVIDENCE_DIR=/absolute/path/to/new-recovery-evidence
```

`sigterm` explicitly tests process-termination recovery after closing the owned
fixture; it does not qualify graceful native quit. The default `quit` mode is a
separate path with no automatic fallback. Recovery fixtures default to
`.build/recovery-fixtures`, outside the /tmp alias. See
[recovery settings and interpretation](RELEASE_VALIDATION.md#reproduce-packaged-live-recovery-qualification).

Keep real timeout durations, exclusive access, fixture ownership and identity
guards. An uncertain operation must never be retried automatically. Preserve
failed runs and journals; verify process exit before restart/reconciliation.
`reconciled` records observations, not historical success. New fault paths need
matching cases: existing cases do not establish metadata-specific partial-write
coverage, for example.

For changes to an already qualified build, follow the
[recovery selection guide](RELEASE_VALIDATION.md#recovery-test-selection).
Documentation, build/CI, unrelated features, and selection/reporting changes that
leave fault behavior unchanged need focused offline checks. A release checkpoint
alone does not require another fault campaign.

## Record and review the result

Retain the candidate source revision, any source patch, archive/executable/handler
and harness hashes, app/OS/toolchain identity, selected/skipped suites, fixture
checksums, results, failures, and recovery journals. Curate evidence that supports
the claims; do not commit RAWs, previews, disposable databases, or scratch copies.

Update the tested-build registry and relevant feature gates only for demonstrated
support, together with their tests and capability declarations. Update the
[release validation report](RELEASE_VALIDATION.md) and support documentation with
scope and remaining gaps. Rerun affected offline checks after final edits; if the
runtime payload changes, validate affected native paths on the final archive.

Downloaded-artifact launch, Automation consent, signing/notarization, other
architectures, and additional macOS targets remain separate distribution checks.
A passing local campaign does not silently waive them.
