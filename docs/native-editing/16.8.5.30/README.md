# Native editing qualification — Capture One 16.8.5.30

The native suite uses a disposable Session containing a copy of the local RAW
fixture. Expanded reads use `get` with `nativeTargets`; mutations use the returned
scope-specific state tokens.

## Retained evidence

- [Scope comparisons and executable hashes](../../performance/scoped-get-native-qualification.json): combined image and layer reads match independent single-scope reads, including values and state tokens. The packaged native suite passed with build-tree resources hidden.
- [Native recovery events](../../performance/scoped-get-recovery-events.jsonl): property and layer-creation faults preserve the unresolved-write block, reconcile after SIGTERM restart, reject expired references and allow edits through fresh references.
- [Release read benchmark](../../performance/local-release-scoped-get.json): five measured pairs compare separate and combined reads in one persistent MCP process.

The offline suite passes 996 assertions, including source/document drift,
partial-read failure, stale references, scope validation, duplicate targets,
compact responses and the single-scope fast path. CLI/MCP contract tests validate
23 tool schemas and rejection of invalid requests.

## Runtime coverage

| Area | Demonstrated |
|---|---|
| Combined reads | Adjustment/lens/variant and layer adjustment/attributes/luma snapshots match separate reads |
| State tokens | Scoped-read tokens authorize guarded native edits; stale tokens are rejected |
| Curves | RGB, luma, red, green and blue replacement and restoration |
| HDR | Highlight, shadow, white and black values |
| Detail controls | Clarity, sharpening and luminance/color noise reduction |
| Levels/color | RGB levels, black-and-white controls and shadow color-balance saturation |
| Lens | Chromatic-aberration toggle and restoration |
| Layers | Creation, name/opacity, initially unset exposure/clarity, addressed deletion |
| Luma/masks | Luma bounds/clear; clear, fill, invert, rasterize, feather, refine and copy commands |
| AI people | Combined body-skin/face-skin request and resulting layer snapshots |
| Color editor | Basic hue change/restoration and advanced correction creation, change and deletion through the indexed interface |
| Isolation | Existing-variant editing, untouched sibling preservation and RAW checksum comparison |
| Preview | Fresh preview export |

Qualification applies to the exercised values and fixture on Capture One
16.8.5.30. Indexed color-band targeting requires an independent bulk oracle for
palette transfer. Layer property snapshots establish observable layer state;
mask-pixel fidelity requires rendered inspection. Catalog writes require the
existing document opt-in and image-storage guards.

## Reproduce

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

Recovery tests require a candidate archive built by `make qualify` or `make archive`.
They use owned disposable fixtures and preserve real Apple Event timeout durations.
Reconciliation records observed state after restart; review those observations
before editing through a fresh reference.
