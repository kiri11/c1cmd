# Native editing qualification — Capture One 16.8.5.30

Contract **1.10.0**, Apple Silicon, one owned disposable Session, sequential calls,
and a copied Canon CR3 fixture. Source RAW and untouched sibling preservation
passed. This report distinguishes the implemented dictionary surface from the
specific runtime cases tested.

## Results

- **941/941 offline assertions**, 29 recovery-harness tests, four release-runner
  tests, generated-resource consistency, and CLI/MCP schema/profile checks passed.
  See [offline log](offline.log).
- Relocated packaged **CLI (19 steps), MCP (10 steps), and native editing** passed
  with build-tree resources hidden. Native editing performed **40 journaled
  operations**, with fresh state checks, dry-run and stale-token checks, sibling
  isolation, RAW checksums, and preview export. The native suite took 523.313 s;
  all three selected packaged suites took 628.43 s. See [regular log](regular.log)
  and [operation evidence and payload hashes](regular.json).
- **Both final-payload native recovery cases passed**: a property write and a
  layer-creation command. Each produced a real `-1712` timeout after approximately
  120 seconds, blocked later writes, preserved identities and source state through
  explicit SIGTERM shutdown/restart, recorded reconciliation observations,
  rejected expired references, and allowed a write through a fresh reference.
  See [recovery events](recovery-events.jsonl) and [final hashes](final-payload.json).
  Both selected cases together took 384.59 s. No full fault-campaign pass is claimed.
- Final package resource/relocation and contract checks passed; see
  [package log](package.log).

The full regular run preceded four final integration changes: lazy separate
native-script compilation, invalid-input error normalization, the MCP destructive
annotation for native actions, and CLI request naming. The generated native
handlers and manifest are byte-identical between those payloads. Final offline,
package and native fault/recovery checks cover those changes; the complete regular
matrix was not repeated. Both payload identities are retained. Documentation-only
repacking can change an archive checksum without changing these executable and
runtime-resource hashes.

## Runtime coverage

| Area | Demonstrated |
|---|---|
| Curves | RGB, luma, red, green and blue: replace with three points and restore the initial two-point curve |
| HDR | Highlight, shadow, white and black values |
| Detail controls | Clarity amount/structure/method, sharpening amount/radius, luminance/color noise reduction |
| Levels/color | RGB shadow/highlight/midtone, black-and-white enable/red sensitivity, shadow color-balance saturation |
| Lens | Chromatic-aberration toggle and restore |
| Layers | Create filled/adjustment layers, name/opacity, write initially unset exposure/clarity, delete the addressed layer |
| Luma/masks | Luma low/high and clear; clear, fill, invert, rasterize, feather, refine and copy mask commands |
| AI people | Combined body-skin/face-skin request created one additional layer on the fixture |
| Color editor | Basic hue change/restore; advanced correction creation, hue change and deletion |
| Isolation | No duplicate existing variant from editing preparation; untouched sibling and source RAW preserved |

The dictionary-generated interface exposes 127 writable properties, but this run
**does not qualify every value, enumeration, property combination or image type**.
Style application, dehaze pick/recalculation, lens reset, other layer kinds,
other AI areas/separate-layer mode, most individual color/levels/lens controls,
and variant processing/LCC switches have implementation and schema coverage but
were not exercised here. New native writes in Catalogs were not qualified; their
existing opt-in/storage guards remain active.

Mask commands returned successfully and produced observable layer state, but
Capture One does not expose mask pixels. This is not pixel-level mask verification
or evidence that deleted/painted masks can be restored from property snapshots.
The existing geometry exclusions and broader distribution gates still apply.

The other seven regular matrices and eight recovery selections were omitted
because the changed native path was tested directly. Existing journal, lock,
preview, geometry and classification implementations were not changed; added
native reconciliation runs only for entries containing native before-state.

## Development findings

Early curve writes using an intermediate curve reference returned `-10006`.
Those uncertain operations were stopped and reconciled after restart, without
retry. Targeting the native curve context directly fixed replacement/restoration
for all five channels. New-layer defaults also exposed a distinction between
native `missing value` and genuinely unavailable properties: the API now reports
unset values as JSON `null` and allows typed assignments to them. See
[retained failure/reconciliation observations](development-failures.json).
Reconciliation records observations, not proof of historical completion.
