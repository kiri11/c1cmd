# M0 investigation probes

These are **stateful, manually sequenced qualification probes**, not an unattended c1 integration suite. They target only the named disposable Sessions and record raw results, including failures. They are not the production handlers; there is no c1 CLI/core in this repository yet.

Read the [qualification report](../../docs/m0_requalification_16.8.5.30.md) before replay. It distinguishes passed observations from remaining gates. In particular, do not run unrestricted `aelint --dynamic` on the full dictionary: its generic command phase can invoke `silently quit`.

## Fixture creation

Use Capture One 16.8.5.30, a licensed GUI session, and Automation access for the launcher. The paths `/private/tmp/c1-m0-1685-A` and `-B` must not contain valuable or previously unresolved work. Never blindly repeat an uncertain mutation or delete existing fixtures to make a failed test pass. Archive previous evidence before starting a new investigation; the runner appends to the build's `runtime.jsonl`.

The original setup used this AppleScript (change only the fixture name to create B):

```applescript
tell application "/Applications/Capture One.app"
    make new document with properties {name:"c1-m0-1685-A", kind:session, path:"/private/tmp"}
end tell
```

Copy a local CR3 into `A/Capture/fixture.CR3`, keeping the source outside both Sessions. Record its camera and SHA-256. The investigated source was an existing local Canon EOS R CR3; no RAW or rendered photo is included in the repository. For future qualification, use your own representative RAW fixtures. To populate B after preview succeeds, copy a fixture JPEG into `B/Capture/fixture-0000.jpg` through `fixture-0999.jpg`. These are repeated JPEGs for API load/shape checks, not a real thousand-image RAW dataset.

Use `set current collection of d to collection "Capture" of d`. The initial `browse ... to path` returned -50 on the fixture; the collection form worked. Verify returned source paths: Capture One may return `/tmp` for `/private/tmp` and a variant name without its extension.

## Retained sequence

Run from the repository root:

```sh
python3 probes/m0/run_probe.py probes/m0/01_inventory.applescript
```

Use that wrapper for individual `.applescript` probes. It records the script path/hash, arguments, timestamp, elapsed process time, stdout/stderr and exit code. Outer elapsed time includes interpreter startup; timings inside the bulk/preview scripts do not. No automatic retries are performed.

| Probe | Purpose and prerequisites |
|---|---|
| 01 | Select A Capture collection; record identity and initial app settings |
| 02 | Seed source 1 with adjustment/layer edits, clone twice, return IDs |
| 03 | Five-field set/add/restore and selected-sibling isolation; IDs 1/2/3 from this run |
| 04 | Configure the test-owned recipe in A; only reuse this name if its ownership was established by the current run |
| 05 | Export: arguments `unique-job-folder variant-id`; never reuse an existing output directory |
| 06 | Temporary clone/delete, collection switch, close/reopen, stale-specifier check |
| 07 | Partial failure, WB coupling and real pick/reorder |
| 08 | Edit an existing RGB curve point and sharpening on the fixture source, then clone; **record returned new ID** |
| 09 | B bulk/loop benchmark after selecting Capture; first run can include discovery load |
| 11 | Inspect A/B binding, shared recipe behavior, history and crop result shape |
| 13 | Reopen A separately after normal restart; opening another Session may close A |
| 15 | Sample field endpoints and above-maximum rejection, restore modeled values |
| 16 | Remove the owned recipe and close test Sessions; assumes the initial Catalog is named `Capture One Catalog` and callbacks were initially unset |

Scripts contain the IDs and names from the recorded experiment. For a fresh fixture, inspect returned identities and adjust dependent probe inputs before use; notably callback tests used clone **12**, which is not promised by the application. Never substitute a matching ID from another document. Do not repeat seeding/clone scripts on an existing fixture without examining the state first.

Probe 04 retains the initially attempted profile and setter order so its readback exposes the problem. Probe 05 uses the corrected profile, root location then `custom location`, and explicit readback checks. A matching test recipe name is not a general ownership mechanism; fixture isolation and this run's creation log establish ownership here.

## Fault and recovery experiments

- `python3 probes/m0/timeout_probe.py`: compiles probe 10, verifies the Capture One executable/PID, pauses the target for three seconds with an independent resume watchdog, and sends a one-second-deadline write to A's clone 2. Reads after resumption and restores exposure to the fixture baseline 0.25. **Do not run with unrelated Capture One work in flight.** It does not retry the write.
- `python3 probes/m0/client_death_probe.py`: uses probe 12, requires A current, writes to a fresh `job-client-death-foreground` directory, kills only its own `osascript` child before the final reply, then resumes the fixture queue. Refuses an existing dispatch marker. The recorded run did not establish an outstanding job after death. `12_pending_export_off_document.applescript` retains the earlier no-current-document-guard variant; use only for deliberate off-document investigation.
- `python3 probes/m0/callback_probe.py`: requires an unset callback, records recovery intent, installs a test callback, exports clones 2/12, recovers from another process, simulates an intervening callback replacement and conditionally cleans up. Requires fresh `job-callback-3/4` outputs for replay. Its journal demonstrates ordering, **not** fsync durability or production crash recovery. Callback output plists live under `/private/tmp/c1-m0-callbacks`; filter by the current run's job IDs rather than accepting any existing file. Paths are normalized to the observed `/tmp` representation; portable file-identity handling remains implementation work.
- `python3 probes/m0/restart_probe.py`: performs a normal saved application quit, confirms process exit, relaunches and opens the original Catalog plus A/B. The recorded combined post-restart snapshot failed because opening B closed A; probe 13 reconciles A separately. Inspect the hard-coded original Catalog path before replay. Never replace normal quit with `silently quit` or a forced application kill.
- `python3 probes/m0/lock_probe.py`: tests the application-wide flock primitive using two document labels, normal release and holder death. It does not exercise a c1 journal or photographer actions.

These probes deliberately expose failure modes; a zero process exit is not by itself an M0 pass. Check readback, job identity, callbacks, completed decoded files and cleanup evidence. Restore only test-owned application settings; preserve unexpected intervening values and investigate.

## Swift codec and image verification

```sh
swift build --package-path probes/m0/bridge
probes/m0/bridge/.build/debug/M0BridgeProbe
swiftc -O probes/m0/verify_images.swift -o /private/tmp/c1-m0-verify-images
/private/tmp/c1-m0-verify-images /absolute/path/to/first.jpg /absolute/path/to/second.jpg
```

The package pins AppleScriptBridge by revision; `Package.resolved` is retained. The bridge probe exercises Codable and makes a read-only Capture One version call. The image utility decodes to sRGB RGBA, reports dimensions and pixel SHA-256, and compares adjacent outputs. A decoding failure is a failed verification, not evidence of completed preview.

## aelint

Build `alldritt/aequery` at revision `a56f5d0be22c6bc21957e5c1d0355809a2c477a5` outside the repository. Retain its resolved dependency file with the evidence. Run full static validation, then the retained read-only command-free subset against a disposable current Session:

```sh
aelint 'Capture One' --sdef-file sdef/16.8.5.30.sdef --json
aelint 'Capture One' --sdef-file probes/m0/aelint_read_subset.sdef --dynamic --max-depth 2 --timeout 5 --json
```

The subset is intentionally not the full dictionary, and its grade cannot qualify the full app. It contains no commands and marks the selected properties read-only. Setter qualification comes from explicit clone-only probes instead. Keep reduced coverage and the untested adjustment class visible in reports.
