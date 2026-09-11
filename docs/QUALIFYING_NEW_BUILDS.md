# Qualifying New Capture One Builds for `c1`

This document provides the standard operating procedure for testing, verifying, and adding a new Capture One build to the `testedBuilds` registry in `c1`.

---

## 1. Version Compatibility Policy

`c1` implements a three-tier version compatibility model:

1. **Tested Builds (`testedBuilds`)**:
   - Explicitly verified builds (e.g. `16.8.5.30`).
   - `exactBuildMatched: true`; `allChecksPassed` also requires the other health checks.
   - Executes with **zero warnings**.
2. **Allowed Untested Builds (`16.4+ < 17.0`)**:
   - Modern Capture One 16 builds that have not yet been explicitly added to `testedBuilds`.
   - `exactBuildMatched: false`; `allChecksPassed` can still be true and is not a qualification signal.
   - Executes with an informational warning:  
     `"Running on unverified Capture One build '<version>' (tested: ...). Compatibility allowed for Capture One 16.4+. Core safety guards and readback checks remain active."`
3. **Unsupported Builds (`< 16.4` or `>= 17.0`)**:
   - Fails closed with `unsupported-version` error.
   - Can only be executed if the user explicitly overrides with environment variable `C1_ALLOW_UNTESTED_BUILD=1`.

---

## 2. Step-by-Step Qualification Workflow

Follow these steps whenever a new version of Capture One is released:

### Step 1: Dump and Diff the Scripting Definition (SDEF)

Capture One exposes its AppleScript dictionary via the OS `sdef` command. Dump the dictionary for the newly installed version:

```bash
# Dump new SDEF
sdef "/Applications/Capture One.app" > "sdef/<version>.sdef"

# Diff against the previous tested SDEF
diff -u sdef/16.8.5.30.sdef "sdef/<version>.sdef"
```

**What to check for:**
- Core adjustment properties (`exposure`, `contrast`, `saturation`, `temperature`, `tint`) and their 4-character codes (`CVex`, `CVcn`, `CVsa`, etc.).
- Range specifiers and enumerations (e.g., `recipeRootType`).
- Variant commands (`add variant`, `delete`, `process`).
- Any new, deprecated, or conflicting terms.

### Step 2: Run End-to-End CLI Integration Tests

Run the automated integration test suite against a live, disposable Capture One session using a real RAW image fixture:

```bash
# Set path to a local RAW image (CR3, ARW, NEF, etc.)
export C1_TEST_RAW_FIXTURE="/path/to/my_test_fixture.CR3"

# Build debug binaries
swift build

# Run integration tests
python3 Tests/integration_test.py
```

**Verification criteria:**
- Disposable Session created at `/private/tmp/c1-m1-e2e`.
- Working clone created (`c1 variant clone 1`).
- Mutations applied (`set`, `add`, `reset`) and verified within tolerance.
- **Zero RAW corruption**: Cryptographic SHA-256 of the source RAW file is byte-for-byte identical before and after all operations.
- Dedicated preview exported and ImageIO decoded.
- Clean variant deletion without removing source RAW or original variant.
- Catalog mutation guards fail closed.

### Step 3: Run MCP Server Integration Tests

Verify that the stdio MCP adapter communicates seamlessly with the new build:

```bash
python3 Tests/mcp_test.py
```

**Verification criteria:**
- Protocol handshake and tool listing (17 tools; 13 in the composition profile).
- Mutation operations through MCP tool calls.
- Dual text/JSON metadata + `image/jpeg` base64 preview rendering.
- Catalog protection barriers.

### Step 4: Qualify the packaged recovery paths

Run `Tests/release_integration_test.py` against the candidate archive, then close all documents and run `Tests/recovery_integration_test.py` sequentially. The recovery harness is intentionally pinned to 16.8.5.30; adapting its explicit build assertion for a new candidate is qualification work, not permission to label that build tested. Retain successful and failed runs, artifact/executable hashes, app/OS/toolchain identity, RAW checksums and journal evidence. Review the limited claims and remaining gates in [release validation](RELEASE_VALIDATION.md).

### Step 5: Qualify geometry and add the build

Crop and rotation writes have a separate exact-build gate. Run the [geometry probes and workflow](geometry/16.8.5.30/README.md), including rotated coordinates, all four orientations, aspect-ratio preset interaction, unsupported transform rejection, crop-aware previews and real geometry timeout recovery. Both geometry harnesses and the production geometry gate currently pin 16.8.5.30; changing those assertions alone does not qualify a new build. Retain evidence before extending the geometry gate.

Once the packaged workflow and recovery qualification pass and their scope has been reviewed, add the new build version string to `testedBuilds` in `Sources/CaptureOneCore/SessionController.swift`:

```swift
public static let testedBuilds: [String] = [
    "16.8.5.30",
    "<new-build-string>"
]
```

### Step 6: Run Unit Tests

Execute the unit test suite to ensure no regressions:

```bash
swift run CaptureOneCoreTests
```

### Step 7: Submit Pull Request

Commit your changes:
1. `sdef/<version>.sdef` (new dictionary snapshot)
2. Updated `SessionController.swift` with the new build added to `testedBuilds`
3. Any relevant test logs or release notes

Submit a PR with the title: `feat: qualify Capture One <version>`.
