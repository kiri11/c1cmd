# Native editing qualification — Capture One 16.8.5.30

The native suite uses a disposable Session containing a copy of the local RAW
fixture. Expanded reads use `get` with `nativeTargets`; mutations use the returned
scope-specific state tokens.

## Retained evidence

- [Color-target bulk-oracle qualification](color-target-qualification.json): all nine basic bands and three advanced elements match independent bulk property records at image and layer scope. Guarded changes, restoration, sibling preservation and middle-element deletion passed in the full packaged native suite on 2026-09-19. The old evaluated basic-color reference returned `all` for element 2; direct and explicit-reference reads returned `orange`.

- [Scope comparisons and executable hashes](../../performance/scoped-get-native-qualification.json): combined image and layer reads match independent single-scope reads, including values and state tokens. The packaged native suite passed with build-tree resources hidden.
- [Color-target candidate recovery](color-target-recovery-events.jsonl): both `native` and `native-action` passed against the rebuilt candidate archive on 2026-09-19, using SIGTERM restart. These inject faults in the shared clarity-property and layer-creation paths, not individual color bands. Other regular and recovery matrices were omitted because their paths are unchanged.
- [Native recovery events](../../performance/scoped-get-recovery-events.jsonl): property and layer-creation faults preserve the unresolved-write block, reconcile after SIGTERM restart, reject expired references and allow edits through fresh references.
- [Release read benchmark](../../performance/local-release-scoped-get.json): five measured pairs compare separate and combined reads in one persistent MCP process.

The offline suite passes 1,023 assertions, including source/document drift,
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
| Color editor | All nine basic bands and three advanced elements independently checked at image/layer scope; hue change/restoration and advanced middle-element deletion preserve siblings |
| Isolation | Existing-variant editing, untouched sibling preservation and RAW checksum comparison |
| Preview | Fresh preview export |

Qualification applies to the exercised values and fixture on Capture One
16.8.5.30. Color targeting was checked against an independent bulk oracle with
the retained hue-change payloads; this is not a full palette-transfer qualification.
Layer property snapshots establish observable layer state;
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
