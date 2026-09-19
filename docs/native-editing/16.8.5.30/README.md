# Native editing validation — Capture One 16.8.5.30

The native suite uses a disposable Session containing a copy of the local RAW
fixture. Expanded reads use `get` with `nativeTargets`; mutations use the returned
scope-specific state tokens.

## Test coverage

| Area | Checks |
|---|---|
| Combined reads | Adjustment/lens/variant and layer adjustment/attributes/luma snapshots match separate reads |
| State tokens | Scoped-read tokens authorize guarded native edits; stale tokens are rejected |
| Curves | RGB, luma, red, green and blue replacement and restoration |
| HDR | Highlight, shadow, white and black values |
| Detail controls | Clarity, sharpening and luminance/color noise reduction |
| Levels/color | RGB levels, black-and-white controls; all four color-balance wheels at image/layer scope, paired and single-control writes, omitted-control preservation and restoration |
| Lens | Chromatic-aberration toggle and restoration |
| Layers | Creation, name/opacity, initially unset exposure/clarity, addressed deletion |
| Luma/masks | Luma bounds/clear; clear, fill, invert, rasterize, feather, refine and copy commands |
| AI people | Combined body-skin/face-skin request and resulting layer snapshots |
| Color editor | All nine basic bands and three advanced elements independently checked at image/layer scope; hue change/restoration and advanced middle-element deletion preserve siblings |
| Isolation | Existing-variant editing, untouched sibling preservation and RAW checksum comparison |
| Preview | Fresh preview export |

The suite covers representative values and fixtures on Capture One 16.8.5.30;
it does not establish support for every exposed value or a complete palette
transfer. Color-editor checks use an independent bulk oracle. Color-balance
checks read the eleven supported properties directly, because whole adjustment
property records include fields unavailable on non-background layers.

Layer property snapshots establish observable layer state; mask-pixel fidelity
requires rendered inspection. Catalog writes require the existing document
opt-in and image-storage guards.

## Run validation

Close documents, provide exclusive use of Capture One, and select a source RAW:

```sh
make check
C1_NATIVE_EVIDENCE=/absolute/path/to/new-evidence/native \
  make qualify QUALIFY_SUITES=native \
  C1_TEST_RAW_FIXTURE=/absolute/path/to/source.CR3 \
  EVIDENCE_DIR=/absolute/path/to/new-evidence
make qualify-recovery RECOVERY_CASES="native native-action" \
  C1_RECOVERY_SHUTDOWN_MODE=sigterm \
  C1_TEST_RAW_FIXTURE=/absolute/path/to/source.CR3 \
  EVIDENCE_DIR=/absolute/path/to/new-recovery-evidence
```

Use `make check` for schema/type guards, generated-resource drift, stale state,
unmanaged references, dry runs, journaling, write blocking, and expired references.
Select recovery cases by affected behavior: `native` for property dispatch/readback,
`native-action` for actions, or both when shared handling changes.

Recovery tests require a candidate archive built by `make qualify` or `make archive`.
They use owned disposable fixtures and preserve real Apple Event timeout durations.
Reconciliation records observed state after restart; review those observations
before editing through a fresh reference.
