# M0 Spike: Historical 16.7.1.11 Findings

> **Status:** Historical evidence only. This report does not qualify the current build or establish that all current M0 exit gates passed. See [16.8.5.30 runtime requalification](m0_requalification_16.8.5.30.md) and its explicit remaining gates. Several conclusions below have been narrowed to match the retained evidence.

**Target Build**: Capture One Pro 16.7.1.11 (`com.captureone.captureone16`)  
**Environment**: macOS 15.7.2 (Sequoia), Apple Silicon (M4)  
**Test Data**: Production catalog `C1` (115,022 total images; 1,753 active variants in test collection) + dedicated test fixture session `M0_Test.cosessiondb` with Canon EOS R6 Mark II CR3 RAW files.  
**SDEF Snapshot**: Saved at [`sdef/16.7.1.11.sdef`](../sdef/16.7.1.11.sdef)  

---

## 1. Answers to M0 Open Questions (§7)

### Q1: Do native variant IDs survive app restart? Do clones get stable IDs immediately?
* **Answer**: **YES to both.**
* **Mechanism**: Capture One backs sessions (`.cosessiondb`) and catalogs (`.cocatalogdb`) with an internal SQLite database. Every variant is recorded in the `ZVARIANT` table with a primary key `Z_PK` and a persistent `ZVARIANTUUID`. The AppleScript variant `id` is the string representation of `Z_PK` (e.g. `"1"`, `"6"`, `"194375"`).
* **Verification**:
  1. Cloned variant 1 in `M0_Test.cosessiondb`. `clone variant` immediately returned the new variant object, and querying its ID yielded `"6"` (autoincrement of `Z_PK`).
  2. Captured IDs: `[1, 6, 7, 8, 2, 3, 4, 5]`.
  3. Terminated Capture One completely (`Cap1SiQt`), verified the process died via `pgrep`.
  4. Relaunched Capture One and re-opened `M0_Test.cosessiondb`.
  5. Queried variant IDs: exactly `[1, 6, 7, 8, 2, 3, 4, 5]`.
* **Qualified conclusion**: IDs survived this fixture restart. This does not establish persistent document identity, safe rebinding after replacement, or an open-document lifetime token. Native IDs alone do not authorize writes.

---

### Q2: Is `clone variant` + adjustment copy/apply reliable enough to be the safety model?
* **Answer**: **YES.**
* **Verification**:
  1. **Isolation**: Clone variant (`id: "7"`) of original variant (`id: "1"`) had initial exposure `0.0 EV`. Mutating clone exposure to `+1.5 EV` and contrast to `+25` left original variant 1 completely untouched (`0.0 EV`).
  2. **Copy/Apply**: Executing `copy adjustments vClone` followed by `apply adjustments vTarget` successfully transferred the entire adjustments clipboard state to the target clone in a single operation.
  3. **Rollback**: Executing `delete variant id "<cloneId>"` cleanly removed the cloned variant and associated SQLite records with zero side effects on the original variant.
* **Qualified conclusion**: The recorded exposure/contrast and deletion checks support clone isolation for that fixture. They do not establish absolute safety, arbitrary style safety, preservation of all unmodeled state, or rollback of shared state. Deletion removes a proposal; it is not a general rollback.

---

### Q3: Do bulk `every variant` forms work for nested adjustment properties, and what is the per-event latency on Apple Silicon?
* **Answer**: **YES for scalar adjustment properties; NO for complex objects.**
* **Per-event latency on M4**: **2.0 ms to 4.5 ms** per Apple Event round-trip.
* **What works**:
  - `exposure of adjustments of (variants 1 thru N)` works directly, returning a flat list of numbers.
  - Multi-property queries (e.g. `{exposure, contrast, saturation} of adjustments of (variants 1 thru N)`) return a list of lists (column-oriented).
  - 2-level nested properties using direct object specifiers (e.g. `EXIF camera model of parent image of (variants 1 thru N)`) work cleanly.
* **Where bulk forms break**:
  1. **Object classes instead of values**: Properties whose type is an object class (e.g. `rgb curve of adjustments of (variants 1 thru N)`) do not return coordinates—they return lists of unresolved AppleScript object specifiers (`«class CVac» of ...`). Curves and layers must be queried on specific variants.
  2. **Variable dereferencing**: Assigning variants to an intermediate AppleScript list variable (`set vList to variants 1 thru 10`) breaks 2-level traversal (`parent image of vList` fails with -1728). Queries must use direct object specifiers `... of (variants 1 thru N)`.
  3. **Multi-element value types**: `crop of (variants 1 thru N)` returns `4 * N` integers flattened into a single list (`[cx1, cy1, w1, h1, cx2, cy2, w2, h2, ...]`). The Swift codec must unflatten this into 4-tuples.

---

### Q4: Does the batch-done callback fire reliably and with output paths, or is polling still needed?
* **Observed**: `processing done script` delivered output paths in the recorded export. Reliable completion and crash-safe shared-state recovery require additional tests.
* **Verification**:
  1. Configured `processing done script` to a compiled AppleScript handler `/tmp/c1_test_callback.scpt`.
  2. Triggered export using `process v recipe "c1-preview"`.
  3. The callback executed immediately upon file export completion with 3 positional arguments:
     - `argv 1`: batch job identifier (UUID matching string returned by `process`, e.g. `E2E2D6D0-054B-4AAD-8518-9B44C45B78CE`).
     - `argv 2`: original RAW source path (`/tmp/M0_Test/M0_Test/Capture/Catalog2 0001.CR3`).
     - `argv 3`: exact exported file path (`/private/tmp/M0_Test/M0_Test/Output/Catalog2 0001.jpg`).
* **Save/Restore Semantics**:
  - Initial value is `missing value`.
  - **Gotcha**: Setting `processing done script to missing value` errors with `-1700 (Can’t make missing value into type text or file)`.
  - **Fix**: Setting `processing done script to ""` (empty string) resets the property back to `missing value` without error.
* **Qualified conclusion**: A callback is a candidate completion signal. Its job ID, source and output list must be reconciled with the operation journal and decoded output. File existence alone is not a successful-completion fallback. Installation and recovery require normalized file identity and preservation of intervening changes.

---

### Q5: Which adjustment properties does `aelint --dynamic` report as declared-writable-but-rejecting?
* **Observed**: The retained adjustment probe reports reads and same-value writes for 90 properties. This is not qualification of meaningful changed values, valid ranges, resets, or isolation. The retained `aelint_report.json` has zero dynamic coverage and does not substantiate the narrated dynamic run below.
* **AELint Dynamic Test Summary**:
  - Out of 191 tested properties across the entire application, `aelint` reported 80 writable and 17 failed.
  - A systematic automated probe tested all 90 properties of `adjustment settings`: **90 passed, 0 failed**.
  - The 17 failing properties belong to `application`, `document`, and `image`:
    1. **Application Callbacks (10 properties)**: `capture done script`, `processing done script`, `batch done script`, `live view became ready script`, `live view will close script`, `live view done script`, `importing done script`, `barcode scanned script`, `primary variant adjusted script`, `selection changed script`. (When unset, they return `missing value`; writing `missing value` back fails with -1700 because Capture One requires text or file).
    2. **`workspace lock PIN`**: Write-only Studio property (`access="w"`). Reading returns missing value; writing same back fails.
    3. **`barcode`**: Enterprise-only property. Reading returns missing value; cannot be set to missing value as text.
    4. **`selects` & `trash`**: Document path properties fail with `"Cannot browse to this path"` when attempting to re-set the existing session path.
    5. **`normalize target color`**: SDEF type mismatch; declared `RGB color`, but coercion fails on set.
    6. **`filters`**: Declared `list of text`; setting empty list `{}` coerces incorrectly.
    7. **`EXIF capture date`**: Fails when underlying image file is read-only or locked on disk.

---

### Q6: Does setting `crop` depend on rotation/orientation order?
* **Answer**: **YES. Orientation and Rotation MUST ALWAYS be set BEFORE Crop.**
* **Verification**:
  - When image rotation was modified from `0.0°` to `15.0°`, existing crop `{3000, 2000, 3000, 2000}` automatically transformed its center to `{3415, 2708, 3000, 2000}` to track the rotated bounding box.
  - When attempting to set crop `{3000, 2000, 3000, 2000}` on an image *already* rotated 15.0°, Capture One clamped the width and height to `{3000, 2000, 2677, 1785}` to prevent the crop from exceeding the rotated canvas bounds.
  - When setting `orientation` to `90°`, the coordinate axes swapped (width/height and centerX/centerY inverted).
* **Rule for `c1 set/add/reset`**: The patch pipeline must apply geometric transform properties in this strict order:
  $$\text{Orientation} \longrightarrow \text{Rotation / Keystone} \longrightarrow \text{Crop}$$

---

### Q7: Which metadata fields are readable per variant in one bulk call, and how fast is `dump` over a 10k-image catalog?
* **Answer**: All standard capture and library metadata fields are readable:
  - **Camera**: `EXIF camera model of parent image of (variants ...)`
  - **Lens**: `lens profile of lens correction of (variants ...)`
  - **ISO**: `EXIF ISO of parent image of (variants ...)`
  - **Shutter**: `EXIF shutter speed of parent image of (variants ...)`
  - **Aperture**: `EXIF aperture of parent image of (variants ...)`
  - **Capture Time**: `EXIF capture date of parent image of (variants ...)`
  - **Current adjustment WB (not verified as-shot metadata)**: `temperature of adjustments of (variants ...)`, `tint of adjustments of (variants ...)`
  - **Library**: `rating`, `color tag`, `name`, `id` of `(variants ...)`
* **Dump Speed**:
  - Querying 15 metadata + adjustment fields across **1,000 variants** completed in **3.15 seconds** (3.15 ms / variant).
  - **Extrapolated for 10,000-image catalog**: **~31.5 seconds**.
  - Querying adjustments alone (exposure, contrast, saturation, WB) across 1,000 variants completed in **44.2 ms** (~0.44 seconds for 10k images).

---

### Q8: Is there a writable text metadata field suitable for `note` that Capture One shows in its UI and that survives export?
* **Answer**: **YES: `content description` (IPTC Description / Caption).**
* **Verification**:
  1. `content description of variant` is fully read/write via AppleScript.
  2. Setting `content description of vClone to "AI grading: daylight portrait regime, exposure +0.3 EV"` succeeded instantly.
  3. **Isolation**: Variant 1 (original) remained empty; the note was strictly isolated to the working variant clone.
  4. **UI**: Capture One surfaces this directly in the Metadata inspector tool under `IPTC - Content` $\rightarrow$ `Description`.
  5. **Export**: When exported to JPEG/TIFF, Capture One embeds `content description` into standard IPTC/XMP metadata (`dc:description`), readable by Lightroom, Photoshop, and ExifTool.

---

## 2. Batch Performance Benchmarks

Tested against collection `August 28, 2026 at 15:14` (1,753 variants) in `document "C1"`.

| Strategy | Description | N = 1 | N = 10 | N = 100 | N = 1000 | Projected N = 10k |
| :--- | :--- | :---: | :---: | :---: | :---: | :---: |
| **Strategy A** | Per-variant handler ($N$ Apple Events) | 33.3 ms | 166.5 ms | 1,780.0 ms | *~17.8 s* | *~178 s (3 min)* |
| **Strategy B** | Batched loop ($1$ Apple Event, AppleScript `repeat` loop) | 37.1 ms | 184.3 ms | 1,757.1 ms | 17,719.1 ms (17.7 s) | *~177 s (3 min)* |
| **Strategy C** | Bulk range queries (`get ... of (variants 1 thru N)`) | **4.5 ms** | **3.6 ms** | **10.9 ms** | **44.2 ms** | **~0.44 s** |

### Qualified interpretation
The recorded measurements favor bulk queries strongly. A single handler invocation can still send many Apple Events; the table does not establish exact event counts or Capture One's internal implementation. The 10k results are extrapolations, not measurements. Do not transfer these absolute timings to another environment.

---

## 3. Concurrency & System Behavior

### Cross-Process Advisory Lock (`flock`)
* Tested POSIX `flock` using `LOCK_EX | LOCK_NB` on `/tmp/c1_<PID>_<docToken>.lock`.
* Test Result:
  - Parent process acquired lock.
  - Concurrent worker process polled every 50ms with a 2.0s timeout. While the parent held the lock, the worker correctly reported `WORKER_BUSY after 2.040s`.
  - When the parent released the lock after 500ms, the worker immediately acquired the lock in `0.526s`.
* **Superseded decision**: The primitive test used a document-scoped lock. The current plan requires one application-instance lock shared across documents; the 2026 requalification tests that scope.

### Apple Event Responsiveness Under Export Load
* Tested Apple Event latency while Capture One was actively rendering a batch export of 5 full-size RAW images.
* Measured Apple Event latencies: `[2.69 ms, 2.31 ms, 2.03 ms, 2.90 ms, 2.87 ms]`.
* **Qualified conclusion**: Reads remained responsive during this small export. This does not identify all possible timeout causes or establish responsiveness under other loads.

---

## 4. Codec & AppleScriptBridge Findings

* **User-Defined Record Keys**:
  - Handlers must return AppleScript records with user-defined identifiers (e.g. `{exposureVal: 1.5}`), NOT application properties (`properties of adjustments`).
  - App-defined properties decode as 4-character codes (`'CVex'`), which depend on SDEF compilation.
  - User-defined record keys encode in `NSAppleEventDescriptor` under keyword `keyASUserRecordFields` (`'usrf'`), consisting of alternating key-string and value descriptors.
* **`missing value` Handling**:
  - AppleScript `missing value` produces a descriptor of type `typeType` (`'type'`) with `typeCodeValue == 0x6d736e67` (`'msng'`).
  - The Swift decoder maps `'msng'` directly to `nil` (`Optional.none`) at all nesting depths.
* **Nested Structures**:
  - Successfully verified nested dictionary decoding: `{nestedVal: {kelvinVal: 5400, tintVal: missing value}}` decodes cleanly into Swift `[String: Any?]` with `tintVal == nil`.

---

## 5. AELint & Scripting Dictionary Anomalies

* **AELint Quality Score**: 60/100 (D). 14 static errors, 22 info/warnings.
* **Term Ambiguities**:
  - Term `camera`: clashes between class `CObj` and property `COco`.
  - Term `image`: clashes between class `cimg` and property `CRwg`.
  - Term `clarity method`: clashes between property `CVcl` and enum `Ccle`.
  - Term `none`: clashes between enumerators `CRWn` and `Cfln`.
  - Code `COaf`: shared between property `available filters` and enumerator `display before`.
* **Discovered Hidden / Undocumented Command**:
  - `silently quit` (code `Cap1SiQt`): Immediately shuts down Capture One without saving or confirmation prompts. Triggered dynamically by AELint during command probing.

---

## 6. Superseded implementation checklist

Follow [the current plan](../c1_plan.md) and [the new qualification report](m0_requalification_16.8.5.30.md):

- Clone explicitly once and retain a provenance-bound working reference; do not clone before every mutation. Notes/color tags remain deferred.
- Prefer verified bulk scalar forms; validate returned shapes per build. No sub-50ms guarantee.
- Geometry, resets and arbitrary styles remain outside the initial five-field qualification.
- Use an owned recipe, verify every effective setting and completed output, and gate callbacks on durable recovery. A matching name is not ownership.
- Use an application-instance-wide lock, independent of document.
