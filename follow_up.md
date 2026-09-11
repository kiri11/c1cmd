# Follow-up plan

## First milestone: crop, straighten, and align

The first agent workflow proposes composition corrections on managed working clones in a Session. It preserves the photographer's existing color, exposure, layers, lens corrections, and other edits. The first version changes crop and rotation only. Keystone correction is reserved for rare exceptional cases and is an optional later feature, not a release requirement. Style extraction and learned tonal presets come later. This is planned work: the current CLI/MCP supports only five tonal adjustment fields, and crop and rotation writes are not yet qualified.

### Photographer's composition policy

- Use **3:2 width:height for horizontal pictures** and **3:4 width:height for vertical pictures**. These are the usual output ratios, not two orientations of one ratio. Determine the intended orientation from the displayed image and composition, accounting for its orientation metadata; do not switch it merely to retain more pixels. Flag square or ambiguous compositions for review.
- Straighten the horizon using a credible visual reference. When there is no clear horizon, consider relevant architectural or scene lines. Do not assume a hillside, receding shoreline, or naturally leaning object should be level or vertical.
- Align important lines with rotation where this improves the picture. Preserve intentional diagonals and natural perspective when they contribute to the composition. Rare cases that require keystone correction can be left for manual review; they do not block the crop-and-rotation workflow.
- Preserve beautiful or interesting composition: subject placement, breathing room, leading lines, meaningful details, and useful negative space. Rotation may serve composition as well as leveling. Avoid aggressive cropping or distortion just to satisfy a geometric rule. Keep a deliberate tilt when justified, and explain it for review.
- Treat the ratios as defaults. If a ratio or alignment correction would damage the composition, flag the conflict and propose an explicit exception for photographer review instead of silently changing the policy. An already successful composition may need no correction.

Photographer-supplied reference: [The Importance of Straightening the Horizon and Aligning Lines](https://photographylife.com/straightening-the-horizon-and-aligning-lines). The linked article could not be retrieved during this plan update; the policy above records the photographer's instructions and proposed implementation interpretation, not a summary of that article.

### Proposal and review workflow

1. Run `doctor`, discover the Session and source variant, and create a managed clone with `variant_clone`. Preserve the current edit as the comparison baseline; `variant_baseline` creates a default-settings variant and is unsuitable for this composition comparison.
2. Read geometry and inspect the existing framing plus a full-frame context preview when needed. Any temporary uncropping must happen on a managed clone, preserve other edits, and follow the same journal/recovery rules as a proposal.
3. Identify the subject, orientation, alignment references, and composition worth preserving. Choose rotation, then fit the target-ratio crop within the resulting valid image area. Re-evaluate the composition after transformation; a crop chosen before rotation may no longer fit.
4. Apply the absolute geometry proposal with a fresh state precondition. Read back the actual crop and transforms, then render a preview. Check the ratio within documented pixel-rounding tolerance, intended alignment, subject boundaries, distortion, and absence of empty corners. Iterate only from fresh observed state; never repeat an uncertain write.
5. Present the existing edit and proposed result for review. Record the before/after geometry, alignment reference and rationale, target ratio, actual applied values, operation IDs, preview identity, uncertainties, and explicit review outcome. Delete rejected proposal clones. A retained or unchanged clone alone is not acceptance.

### Required shared-core and MCP capabilities

These are proposed interfaces, not tools available today. Keep the CLI and MCP on the same core implementation and schema.

| Capability | Required behavior |
|---|---|
| Geometry reads in `get` and `dump` | Return crop rectangle, aspect ratio, orientation, rotation, and usable image bounds. Distinguish image-space dimensions from exported preview dimensions and report unsupported/unavailable geometry explicitly. |
| `geometry_set` | Apply an absolute crop and rotation only. Preserve existing keystone and lens settings. Accept only managed working references, require a state precondition, validate requested fields and legal bounds, and return actual readback and geometry differences. Omitted settings remain unchanged. Restore the recorded baseline geometry through this same operation. |
| Geometry state and recovery | Introduce an explicitly versioned precondition covering crop and the transforms that affect its interpretation. Journal before/intended/observed geometry and include it in reconciliation. Preserve the existing tonal contract or migrate it explicitly; the current five-field hash cannot detect a changed crop or rotation. |
| Geometry-aware previews | Provide existing-framing and full-frame context views, with a documented coordinate mapping to the native crop space. Verify output respects the intended crop and transforms, and detect geometry changes during rendering. Account for existing transforms when mapping coordinates; flag combinations whose mapping has not been qualified for manual review. |
| Baselines and `diff` | Retain source geometry at cloning and compare geometry alongside the existing supported adjustments. Preserve the five-field readback checks and test that geometry edits do not change unrelated settings or originals. |
| Agent tool scope | Expose geometry writes and necessary clone/preview/recovery operations to the composition agent; exclude tonal mutation tools from its allowed tool set. Composition judgment and review records remain in the caller/example workflow. |

The checked-in [Capture One 16.8.5.30 dictionary](sdef/16.8.5.30.sdef) exposes crop rectangles, rotation, and maximum-crop calculation. Dictionary availability does not establish safe runtime behavior. Confirm crop origin, units, rotation sign, orientation conventions, transform order, aspect-ratio interactions, and valid bounds with exact-build probes before choosing the public coordinate contract. In particular, a maximum-crop query must explicitly avoid applying a change; the dictionary's `apply` parameter defaults to true.

A geometry request is one logical proposal, not an atomic Capture One transaction. Preserve pre-dispatch journaling, partial/unknown outcome handling, restart-based reconciliation, and clone lifetime rules across all geometry setters.

### Implementation sequence and acceptance

1. **Qualify geometry:** retain read/write/readback probes on copied RAWs and disposable managed clones. Cover landscape and portrait orientations, existing crops, positive/negative rotation, aspect-ratio coupling, boundary rejection, and existing perspective/lens corrections. Verify originals, sibling variants, and unrelated edits remain intact.
2. **Ship crop and rotation:** implement the shared geometry contract, preview mapping, baseline/diff and recovery integration, then run offline, CLI/MCP, and extracted-archive tests. Crop and rotation satisfy the first-version scope; keystone support is not an acceptance gate.
3. **Evaluate composition quality:** use photographer-reviewed examples from separate shoots, including cases where no change or an explicit exception is better. Assess alignment, ratio, retained content, natural proportions, and photographer acceptance. Numerical agreement with a crop box alone is not a quality verdict.

Keystone correction may be added later if recurring exceptional cases justify it, with separate runtime qualification. Existing perspective and lens corrections remain unchanged in the first version.

## Later: style learning and the feedback loop

c1 supplies deterministic editing tools; the style-learning workflow is a later experimental consumer of its contract. It lives in `examples/` and a separate `style/` artifact, not in the core. It must not delay the composition milestone above. Begin with explicit composition preferences and reviewed before/after examples; learned lighting regimes, exposure/WB estimation, and automatic preset revision are not prerequisites.

### Principle: preserve intent, not just parameters

A photographer's style is a conditional policy (different treatment per lighting regime) plus a fixed base plus judgment calls. The failure mode of learned styles is averaging the judgment calls away into something generic. The design below treats uniqueness as something to protect explicitly.

### Initial extraction (`learn-style.py`, beginning with curated Sessions)

1. Start with a curated, explicitly reviewed Session dataset. `c1 dump` produces adjustments + verified capture metadata + review/provenance links, one JSONL line per variant. Record field coverage and unavailable values; unsupported adjustments and layers are not assumed absent. Split development and held-out data by shoot before proposing rules; keep related variants together.
2. Code, not the model, computes statistics over the available fields. Estimate stable settings (the **base**) and condition-dependent settings, then correlate candidate clusters with metadata and exemplars to propose **regimes** ("tungsten interior", "daylight portrait", …). Do not assume exposure/WB vary little, or that constant settings necessarily express intent. Separate camera/profile/default effects from creative decisions. Weight recent shoots while recording the weighting policy.
3. Render a few paired baseline/final exemplars per regime. Use a managed variant created through verified native default-settings behavior for the baseline; resetting only c1's supported fields is insufficient. Record build, camera profile, tone curve, custom defaults, and any unmodeled final adjustments. These are default-render/final pairs, not proof of an adjustment-free RAW image. Never reset the photographer's final.
4. Add whole-library analysis only after read-only Catalog access and dataset coverage are tested. Generating catalog baseline pairs requires a separately proven workflow that copies source material and needed rendering context into a scratch Session without modifying the source Catalog. Until then, use curated Session exemplars; Catalog mutation is not an implicit exception.

### The style artifact (`style/`, versioned in git)

- `style-card.md` — **invariants** (things the photographer never does; protected, only the photographer can relax them), **regimes** (classification rule, target values, confidence, evidence count), **judgment calls** (creative exceptions with exemplars; explicitly *not* rules), **open questions** for the photographer.
- `presets/<regime>.json` — base + regime values as versioned c1 adjustment documents with capability requirements. Applied deterministically; the model does not re-derive preset numbers. `.costyle` mirrors are deferred until style support can preserve and validate their semantics.
- `exemplars/<regime>/` — 3–5 baseline/final pairs per regime with supported adjustments, coverage limits, baseline provenance, and review status attached, for few-shot judgment. Held-out evaluation exemplars stay outside the proposal inputs.
- `CHANGELOG.md` — every revision with evidence and rationale.

### Applying on a new shoot (`grade-folder.py`)

The v0.1 example applies an explicit user-supplied preset to working variants, renders previews, and records decisions for review. The later learned pipeline classifies each image into a regime (metadata + preview) → applies a regime preset → proposes per-image adjustments → renders a preview → records the proposal for review. The composition workflow above comes first; this later tonal pipeline reuses its qualified geometry support and explicit review records.

Any numeric exposure/WB estimator must define its measurements and be validated against reviewed examples; metadata and rendered-preview statistics are not automatically a reliable estimator. c1 does not promise RAW histogram access. Record what the estimator actually used.

**Decision record** per image, stored as a sidecar linked to the working UUID and verified source/variant identities: regime and rationale, immutable preset/artifact version, before and actual applied state, operation IDs, per-image inputs and values, confidence, open questions, and explicit review status. Optional future `note`/`tag` commands may mirror a summary into the UI. Provenance remains available without metadata writes.

### Harvesting corrections (`harvest-corrections.py`, after the photographer's review)

`c1 dump` the observed final state and reconcile verified identities with decision records. The photographer may edit the clone, edit the original, or delete the clone. Observed changes are separate from review intent:

- **Accepted as-is** — explicit photographer acceptance, with a linked final matching the observed proposal over the recorded coverage. An unchanged variant alone is not acceptance.
- **Adjusted** — an explicitly reviewed, linked final with changes. Diff the actual applied state against the final and associate supported changed fields with their decision records. Do not claim to explain unsupported edits from a partial diff.
- **Rejected** — explicit photographer rejection. Clone deletion or original edits alone do not establish rejection or its cause.
- **Unreviewed** — no explicit review decision yet, even if the variant is unchanged.
- **Unknown** — identity, final selection, operation outcome, or review history cannot be established. Missing clones may have been cleaned up, moved out of scope, or rejected; ask only when resolving the ambiguity is useful.

The example review record stores the photographer's decision, timestamp, linked final, and optional rationale. Only explicitly reviewed, reliably paired cases contribute acceptance/rejection evidence. Unreviewed and unknown cases are excluded from rule updates. Automatic pairing across restarts remains disabled unless durable identity is verified.

Classification hypotheses, code first then model, using reviewed cases only:

- **Systematic bias** — same direction across many images in a regime → adjust preset/target. Requires a minimum n.
- **Misclassification** — resemblance to another regime's preset suggests investigating the regime rule; similarity alone does not prove the cause.
- **Missing rule** — corrections correlate with a feature the rules don't mention (backlit, mixed light, a lens) → model proposes a new rule with exemplars, subject to held-out evaluation and photographer approval.
- **Possible creative exception** — low frequency or no detected correlation → retain as a judgment-call candidate, without updating rules automatically. Lack of correlation may also reflect insufficient evidence.

### Capturing intent directly

- At review, an optional one-line note per correction ("skin too orange", "wanted the window to blow out") supplies intent that a diff cannot establish. Store it in the sidecar review record; later `c1 note` can mirror/read UI metadata if isolation is proven.
- The agent may ask a capped number of questions per shoot, only about corrections it cannot explain.
- Protect distinctiveness through photographer-approved invariants, named exemplars, and explicit review. Defer a “distance from generic” metric until the reference, feature space, and relationship to photographer judgments are validated. Parameter distance or render distance alone does not measure stylistic quality.

### Revising the artifact (`propose-revision.py`)

- Each shoot yields a **proposed revision**: rule/preset changes with evidence (n, effect size, exemplars) and a plain-language rationale. The photographer approves; nothing changes silently.
- Every rule carries confidence and evidence count; old evidence decays.
- **Replay and held-out evaluation:** compare current and proposed artifacts using managed throwaway variants initialized from the same recorded baseline, never by modifying originals. Replay on development shoots diagnoses regressions but is not evidence of generalization.
- Define “closer” and acceptance thresholds before evaluation: selected field errors with declared scaling, suitable render comparisons under fixed rendering conditions, protected invariants, and photographer judgments. No single parameter or pixel distance serves as a universal quality score.
- Evaluate on separate reviewed shoots excluded from rule construction and exemplar prompts. Keep splits by shoot to reduce leakage from related frames/variants. Once results inform another revision, that set is development evidence; use fresh held-out evidence for the next claim.
- Revisions need the predeclared held-out improvement and regression criteria plus photographer approval. If data or metrics are insufficient, label the revision experimental and collect evidence rather than promoting it automatically. Two shoots can exercise the workflow but do not establish generalization or format stability.

### What this requires of c1

Batched `dump` with coverage information; actual mutation readback; managed baseline creation; provenance and explicit review records in the examples; and verified identity reconciliation. Read-only Catalog inspection is available; broad dataset extraction qualification remains future work. `variants list` can identify missing references but cannot determine rejection. UI notes/tags are optional. Reliable cross-restart identity and a safe scratch-Session workflow gate the corresponding library features rather than the initial CLI release.

## References for implementation checks

- [AppleScriptBridge](https://github.com/emorydunn/AppleScriptBridge): handler execution, descriptor conversion, and Codable support; verify the pinned commit against c1 fixtures.
- [AppleScript control statements](https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/reference/ASLR_control_statements.html): timeout does not cancel the target application's operation; transaction support depends on the application.
- [Capture One AppleScript documentation](https://support.captureone.com/hc/en-us/articles/360002681418-Capture-One-Workflow-Automation-with-AppleScript): scripting entry points and version-specific additions; runtime qualification remains required.
- [Capture One default settings](https://support.captureone.com/hc/en-us/articles/360002589997-Saving-new-default-settings-in-the-Base-Characteristics-panel): camera-specific profile/curve defaults affect new variants and must be recorded for reproducible baselines.
- [aelint documentation](https://github.com/alldritt/aequery#aelint): dynamic probe coverage and its same-value setter test; supplement with explicit changed-value and isolation tests.
