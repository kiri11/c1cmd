> Current release authority: [docs/RELEASE_VALIDATION.md](docs/RELEASE_VALIDATION.md) records the decision, exact evidence and remaining distribution gates. M0 and milestone counts below are historical. They do not qualify concurrency, same-file reopening, or other builds. [README.md](README.md) defines the user-facing support boundary.

# c1 — an unofficial CLI + MCP interface for Capture One

Goal: let coding agents (Codex, Claude Code, GPT-6 Astra, etc.) read and write Capture One adjustments through a stable, self-describing API, so a photographer's grading pipeline can be automated and reviewed inside Capture One itself — and so the photographer's own style, learned from their library, is preserved and refined shoot over shoot rather than replaced by a generic one.

## 1. Scope

### v0.1 (first public release)

- macOS only, Apple Silicon, **one pinned Capture One build**, selected and recorded in M0. The current build is **16.8.5.30**; its [M0 report](docs/m0_requalification_16.8.5.30.md) is historical feasibility evidence. The current release decision is in [release validation](docs/RELEASE_VALIDATION.md). Editing and preview require one open Session, with sequential calls and no competing operator. Catalog inspection is read-only; Catalog preview and mutations are rejected.
- Primary layer only. No layers/masks, no Color Editor skin-tone, no tethering, no GUI scripting.
- First release proves one complete workflow: `doctor` → `doc info` → `variants list` → `variant clone` → loop(`get` → `set|add` → `preview`) → photographer review → optional `variant delete`. Start with exposure, white balance, and a small set of adjustments verified in M0.
- Machine-readable JSON is available for every operation; human-readable input and output sit on the same contract.
- **Working-variant model, enforced in the core**: agents can mutate only c1-managed working variants through document-bound working references. Editing originals is deferred; a lossy snapshot does not waive this restriction.
- CLI first. MCP is a thin adapter over the same core, shipped once the CLI is stable.

### Out of scope

- Windows. Anything that requires scripting the GUI via System Events.
- Any model/agent logic. c1 is the hands, not the brain. Demo pipelines live in `examples/`.
- Reimplementing export UI. c1 owns a dedicated preview recipe; general export through user recipes is deferred.
- Arbitrary styles, snapshots, metadata notes/tags, whole-catalog learning, and automatic style revision in v0.1. Preserve these as later milestones rather than prerequisites for the first editing workflow.

### Naming

- Binary and repo: `c1`, described as "unofficial". Capture One's trademark stays out of the project name.

## 2. Architecture

```
agent ──▶ c1 (CLI)  /  c1-mcp (stdio MCP adapter)
              │
        CaptureOneCore (Swift library)
              │  FieldSpec registry · Codable structs ⇄ AppleScript records · lock · state hashes
        AppleScriptBridge (emorydunn, 58946d7fd5b38b6a92c13ccb413d30ba1f0e9179; fork if patches needed)
              │  batch-oriented handlers in Handlers.applescript (bundled resource)
        Capture One (running, licensed, GUI up)
```

- One Swift package: core library and CLI first, then a third target for MCP in M3. Dependencies: AppleScriptBridge and swift-argument-parser; the official Swift MCP SDK is added only with the adapter in M3 and kept out of the core.
- All AppleScript lives in one resource file of named handlers. Swift never builds AppleScript source at runtime.
- **Handlers accept batches from day one**: `getAdjustments(ids)`, `applyPatch(ids, patch)`, `getVariants(ids)`. One handler call may still issue many Apple Events. M0 measures actual application calls and latency, comparing loops with `... of every variant` bulk forms, including nested properties. Bound chunk sizes; do not assume batching makes writes atomic or always faster.

## 3. The contract (the actual product)

JSON is canonical; the CLI adds a terse human layer over the same semantics. Version the request/output schema independently of the Capture One build. Keep the initial contract small enough to validate end to end.

### FieldSpec registry

- Central table of every supported field: name, aliases, type, unit, range, readable/writable, supported operations, precision/tolerance, dependencies, and verified reset behavior. Separate capture metadata (for example, shutter speed) from adjustment names (for example, exposure compensation).
- An **exact-build capability matrix** records tested reads, changed-value writes, and resets for each field and document type. Minimum-version annotations are documentation only; they cannot establish support on a new build. Unverified operations are unavailable.
- Drives JSON Schema (`c1 schema`), `key=value` parsing and validation, and `c1 capabilities` (what the *running* Capture One build actually supports).
- Do not generate swift-argument-parser flags from it; parse generic `key=value` arguments instead.

### Mutation semantics

```
c1 set   <working-ref> --if-state <hash> exposure=0.3 kelvin=5400  # absolute
c1 add   <working-ref> --if-state <hash> exposure=-0.2 kelvin=+150 # delta
c1 reset <working-ref> --if-state <hash> exposure wb              # later, verified fields only
```

- JSON forms: `{"set": {...}}`, `{"add": {...}}`, and later `{"reset": [...]}`. Combined requests apply in that order. Reject duplicate aliases within an operation and unsupported operations; calculate and validate final numeric targets before dispatch. Field dependency order comes from verified FieldSpec rules.
- Absent field = untouched. No `--replace`. `reset` becomes available only for fields with verified default semantics; it does not mean a full default render.
- Every adjustment mutation reads and validates current state first, then reads actual state after applying. Success returns `{operationId, before, after, diff, stateHash}` based on readback, not on requested values. Field-specific precision rules account for Capture One rounding; mismatches are reported rather than silently treated as success.
- `--dry-run` performs validation and returns a predicted diff without mutation. It does not reserve state or promise identical execution later. Operations whose effects cannot be predicted, such as a future arbitrary style, must say so explicitly.
- Input forms: inline JSON, `-` (stdin), `@file.json` (adjustment documents), `key=value` args. Future nested structures (curves, Color Editor corrections) are JSON-only and remain gated by scope and capability.

### Partial failure, retries, and recovery

- Patches and batches are **non-atomic** unless a specific application operation is proven otherwise. Prevalidate the whole request before the first write, then report each variant's outcome and any known partial field changes. Do not imply rollback of unsupported state.
- Outcomes distinguish `succeeded`, `failed`, `not-attempted`, and `outcome-unknown`. A failed operation may have known partial effects; an unknown outcome means application state cannot yet be established. Stop further writes on uncertainty and reconcile before continuing.
- Persist an operation journal before dispatch: operation ID, working/source identity, preconditions, before state, intended targets, and preview output location where applicable. `operation status <id>` reports recorded status and may append reconciliation observations after the old app process ends. Restart alone does not clear unresolved entries, and reconciliation does not establish historical success.
- An AppleScript timeout stops waiting, **not necessarily the application's operation**. Never blindly retry `add`, clone, delete, style, or export after a timeout or lost reply. End the old app process and explicitly reconcile observations before further writes; historical outcomes can remain unknown even after the write block is cleared. A journal is not an exactly-once guarantee.
- Retry reads within a bound. After `state-changed`, read fresh state and calculate a new proposal. Never automatically retry an uncertain dispatched mutation: restart-based reconciliation records observations, not proof of non-execution. Resume with a new managed clone.

### Document pinning and optimistic concurrency

- `doc info` returns persistent document identity and a separate open-document token tied to the running application instance and verified document instance. Define and test token generation in M0; do not use a mutable database content hash as persistent identity.
- Every write is document-bound. `variant clone` requires a document-bound source reference and state precondition; subsequent writes require a working reference carrying the binding. `--doc` may assert the same binding, but omission never means “whatever is frontmost.” Fail with `document-changed` on a mismatched context; never retarget implicitly.
- `get` returns `stateHash` over canonical supported adjustment values, including unavailable-field markers and schema version. Adjustment writes require `--if-state` (or its JSON equivalent); batches carry one precondition per variant. Check under the application lock, resolve explicit document/variant objects, and minimize the interval before writes.
- Hashes cover only modeled state. The lock coordinates c1 processes, not UI actions or unrelated scripts. These checks detect many conflicts but do **not** provide an atomic compare-and-set guarantee against photographer edits. Readback reports observed results; unresolved interference stops the workflow.

### Output

- TTY-aware: compact JSON when stdout is a pipe, table / `key: value` when a terminal; `--format` overrides. `diff` renders as three columns.
- JSON distinguishes fields omitted by projection from fields requested but unavailable. Unavailable fields carry a reason (`unsupported`, `not-applicable`, `missing`, or `read-failed`); legitimate nulls remain explicit. `--full` requests every registered field without disguising failed reads as absent values.
- Logs/progress on stderr only. Stable error codes include `app-not-running`, `no-document`, `permission-denied`, `variant-not-found`, `unmanaged-variant`, `identity-ambiguous`, `unsupported-version`, `unsupported-field`, `invalid-request`, `capture-one-busy`, `document-changed`, `state-changed`, `readback-mismatch`, `partial-failure`, `outcome-unknown`, `timeout`, and `script-error` (raw AppleScript error attached). Document exit-code mapping; partial or unknown results exit nonzero and include structured outcomes.

### Verbs and release scope

- **v0.1 / M1 (Completed):** `doctor` · `version` · `capabilities` · `schema` · `doc info` · `variants list [--selected|--collection]` · `variant clone|delete` · `get` · `set` · `add` · `preview` · `operation status`. Mutation responses already include diffs; proven on single-session scope.
- **M2 (Completed — CLI Full-Featured & Core Capabilities):** verified `reset` · standalone `diff` (single-ref against baseline or two-ref) · `dump` (bulk adjustments + metadata streaming JSONL / JSON / human) · managed default-settings baseline creation (`variant baseline` via native New Variant) · read-only Catalog detection and strict fail-closed mutation guards. 146 unit assertions passing + 19/19 live integration tests passing.
- **M3 (Full-Featured MCP Server `c1-mcp`):** stdio MCP adapter exposing the full suite of tools (`doctor`, `doc_info`, `variants_list`, `variant_clone`, `variant_delete`, `variant_baseline`, `get`, `set`, `add`, `reset`, `diff`, `dump`, `preview`) with image content blocks and JSON schemas.
- **M5, on demand:** `note` · `style list|apply` · `tag` · `export --recipe` · `snapshot save|restore`, plus broader adjustments. All variant mutations retain working-reference enforcement.

`get`, and later `dump`, include verified capture metadata alongside adjustments. Camera, lens, ISO, shutter speed, as-shot WB, and capture time are read-only in c1. Rating and color tag are initially read-only; any later write support requires separate variant-isolation tests and capability entries.

## 4. Tricky details and decisions

### Working-variant model (primary safety mechanism)

- `variant clone` creates a copy through Capture One's native machinery and returns a **working reference backed by a provenance record**: c1 working UUID, source identity, clone identity, document binding, creation operation, and baseline state. The UUID identifies the record; it is not evidence that a current variant is the same object.
- The core rejects writes to arbitrary native handles, originals, or unresolved working references. This applies equally to future style, note, tag, snapshot restore, and delete operations. CLI and MCP cannot bypass it.
- Review uses Capture One's native side-by-side compare. Record provenance in c1 sidecars first; a visible metadata marker or tag is optional future functionality after isolation is proven. Removing an unwanted proposal means deleting only its managed clone, once pending mutations are resolved.
- **Historical M0 checks (sampled results retained in the M0 report):** verify clone preservation of modeled and unmodeled adjustments (including existing layers), immediate unique addressing, and variant-only deletion with the source file and siblings intact. Test selection changes and the Edit All Selected Variants setting. If clone alone is insufficient, copy/apply is a fallback to investigate, not an assumed equivalent.
- Later styles must pass separate isolation tests; clone isolation does not automatically prove safety for styles that affect metadata or shared application state. Original edits remain outside scope. Future snapshots are explicitly lossy exports/restores of supported fields on working variants only.

### Identity

- Resolve the app via `NSWorkspace` by bundle identifier and running process, not a versioned display name. Pin the actual running bundle/build and reject ambiguous application instances.
- **Current binding:** canonical database path, file identity (device/inode/creation time), Capture One PID/launch time, and managed clone parent-image path. Replacement and app restart invalidate working references. The recovery suite exercises app restart; deterministic tests exercise file replacement. Do not infer live qualification of arbitrary replacement/copy scenarios.
- **Known unsupported boundary:** same-file close/reopen within one app launch is not reliably observable. Keep the Session open throughout a workflow. A sidecar token does not make this boundary detectable.
- **Read/source reference:** native variant ID resolved in the sole open document. It permits reads/cloning, never original adjustment/deletion.
- **Working reference:** validated against c1 provenance. No rebinding across restart or replacement; create a fresh clone after explicit recovery. Neither path/index nor adjustment similarity authorizes adoption.
- Persistent pairing across restarts, moved/copied databases, and scratch-Session workflows remain future work. Historical native-ID persistence is evidence for observations, not authorization to reuse working references.

### Records

- Handlers return records with **user-defined keys**, never `properties of adjustments` (app-defined keys decode as four-char codes).
- `missing value` ⇄ `nil` handled explicitly in the codec; verify AppleScriptBridge does this for nested records, patch the fork if not.
- Nested objects (white balance, crop, color corrections) are their own records/structs. The current dictionary returns crop batches as N four-element lists in the tested fixtures, not the old report's flattened 4N form. Validate shape; keep geometry unavailable until qualified.

### Units and ranges

- Confirm units for every field against the dictionary and UI (EV, kelvin/tint, crop pixels vs. normalized, rotation sign). They live in the FieldSpec and surface in `schema`.
- Initial candidate fields are exposure, contrast, saturation, temperature (`kelvin` alias), and tint. Recorded endpoint pairs are [-4, 4], [-50, 50], [-100, 100], [800, 14000], and [-50, 50], respectively; tested above-maximum writes fail with -50. Temperature/tint must be read together after either write. Provisional comparison tolerances are 1e-5 for exposure/contrast/saturation, 0.01 K for temperature, and 0.0001 for tint; qualify canonical hashing separately because tiny WB values also changed after reopen. Current adjustment WB is not as-shot metadata.
- Validate ranges and the result of deltas in Swift before sending. Record coupled fields and ordering requirements; do not expose crop/rotation until those interactions are tested.
- Resetting selected supported fields does not remove unsupported settings or layers. A default-render baseline requires separately verified native New Variant/reset behavior and records the application build, camera profile, tone curve, custom defaults, and processing context. “Default” must not silently mean “all numeric fields are zero.”

### Preview / export

- `c1-preview` is a reserved recipe name. c1 configures an existing recipe with this name and may leave it in the Session; users must not use it for their own exports. Other recipes and callbacks are not intentionally configured. Recipe state can be shared by Capture One, so no competing exports or document switching are supported.
- The exact-build handler sets JPEG/quality 80, `sRGB Color Space Profile`, 1500px long edge, explicit root location followed by `custom location`, and per-operation subfolder/name. The current implementation does not read back every recipe property before dispatch; qualified fixture exports and explicit routing establish the narrow tested behavior, not a general recipe API guarantee.
- **Accepted v0.1 completion mechanism:** each invocation owns a fresh `c1-previews/<operationId>` directory, explicitly processes one native variant with the reserved recipe, and requires repeated stable size, JPEG end marker and ImageIO complete decode. A final five-field state hash must match the pre-export hash. CLI returns operation/native-variant identity, output path, dimensions and pixel hash; MCP adds JPEG image content.
- Under the sole-document, sole-operator, sequential restriction, the unique directory associates output with the request. The returned Capture One job ID is not independently reconciled by production polling. This is not qualification for competing exports, arbitrary output histories, or a complete render fingerprint. Queue disappearance, old files and output history remain insufficient.
- **Callbacks are outside v0.1.** The M0 callback experiments and their crash/coexistence gates are historical alternatives, not missing components of the chosen polling implementation. Any future callback integration needs durable ownership, crash recovery and preservation of intervening user changes before qualification.
- A timeout or lost reply keeps the operation unresolved even if an output subsequently appears. Restart plus explicit `operation status` records observations and clears the block; it does not certify historical export success. No automatic retry, adoption or deletion occurs.
- No preview cache. The five-field hash excludes layers, crop, curves and other render settings. Catalog preview is rejected because preview changes recipe/output state.

### Concurrency and robustness

- Serialize c1 application access with a **cross-process application-wide advisory lock**, shared across cooperating c1 processes, not scoped to a document. Different documents can share recipes, callbacks, and other application state. Wait within a bound, then return `capture-one-busy`.
- Hold the lock through precondition checks, dispatch, readback, and any shared-state cleanup; preview ownership extends through completion or recorded uncertainty. On process death the lock releases, but the application may still be working. Subsequent invocations inspect unresolved journal entries and reconcile before further writes. The lock does not control UI actions or third-party scripts.
- Apple Event timeout is distinct from the preview polling timeout (default 30 seconds, caller range greater than zero through 300). The current handler uses AppleScript's event timeout, not a configurable 60-second c1 deadline. Historical one-second M0 probes demonstrated delayed writes. Current packaged-binary fault qualification and its limits are recorded in release validation; timeout never means cancellation.
- Compile the handler script once per process. `c1-mcp` amortizes it; no daemon for the CLI.

### Permissions and signing

- `c1 doctor` checks Automation permission, exact build, open document, lock, and unresolved recovery state. M0 tests consent from the terminal and intended local-agent launch paths; do not assume identical TCC behavior for every launcher or rebuild.
- Current archives are ad-hoc signed and are not notarized. The original Developer ID/notarization requirement has not been fulfilled; it remains an explicit binary-distribution decision/gate in release validation, not an implemented feature. Validate first-use Automation consent through Terminal and an intended MCP client. Homebrew is deferred.

### Version gating

- Snapshot `sdef` from the resolved application bundle per supported build under `sdef/`, with version/build provenance. Diff on each candidate Capture One update and retain the derived capability report.
- The compatibility check permits unverified 16.4+ through 16.x with a warning; older/future-major builds require `C1_ALLOW_UNTESTED_BUILD=1`. Qualified support is only 16.8.5.30. `allChecksPassed` does not itself establish exact-build qualification; inspect `exactBuildMatched`. Stricter write gating is a separate recommended change, not implemented here.
- Pin `aelint` to `a56f5d0be22c6bc21957e5c1d0355809a2c477a5`. Run full-dictionary static validation and bounded `--dynamic` tests against a retained command-free, read-only SDEF subset, with explicit changed-value probes for supported fields. Unrestricted dynamic command probing is excluded: the tool can invoke commands such as `silently quit`. Label reduced coverage clearly; its score does not describe the full dictionary. Keep reports with M0 findings. Its setter probe writes the existing value back, which is useful but does not validate changed values, coupled fields, reset behavior, or isolation. Add explicit change → readback → restore tests for every exposed field.

### Testing

- Unit tests in CI cover codec/null round-trips, FieldSpec/schema generation, patch composition, exact-build gating, working-reference enforcement, canonical state hashing, operation outcome transitions, and recovery decisions.
- Integration tests need a running Capture One with a disposable fixture Session of your own CR3s (no third-party sample RAWs). `python3 Tests/integration_test.py` and `python3 Tests/mcp_test.py`, sequential and local only. Use `Tests/release_integration_test.py` for extracted archives and `Tests/recovery_integration_test.py` for real fault qualification. Keep M0 probes as a repeatable harness rather than discarding them.
- Verify originals, sibling variants, source files, unmodeled adjustments/layers, and user recipe/callback settings remain intact. Exercise cross-process contention across documents, selection changes, stale references, app restart, mid-batch failures, lost replies, and c1 termination during rendering. A green schema/unit suite alone cannot qualify a Capture One build.

### Agent ergonomics

- `AGENTS.md` / `CLAUDE.md`: `doctor` → `doc info` → `variants list` → `get` → `variant clone` with source binding/precondition → loop(`get` → `add|set` `--if-state` → `preview`) → photographer review. Explain working-reference lifetimes and `operation status`; stop on unresolved operations rather than trying another mutation.
- First `examples/grade-folder.py` uses an explicit preset and sidecar decision records on a small Session. Later examples add learned regimes, `learn-style.py`, `harvest-corrections.py`, and `propose-revision.py` — see §5. Notes/tags are optional future UI conveniences, not required provenance storage.

### Legal / community

- MIT. No Capture One code, binaries, sample files, or logos in the repo. Trademark disclaimer in README.
- Sign up on Capture One's developer portal; post on their forum and reach out to existing script authors (Emory Dunn, AlexOnRaw) once v0.1 is usable.

## 5. Style learning and the feedback loop

c1 is the hands; this section is a later experimental consumer of its contract. It lives in `examples/` and a separate `style/` artifact, not in the core. It must not delay the first safe editing-and-preview workflow or the thin MCP adapter.

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

The v0.1 example applies an explicit user-supplied preset to working variants, renders previews, and records decisions for review. The later learned pipeline classifies each image into a regime (metadata + preview) → applies a regime preset → proposes per-image adjustments → renders a preview → records the proposal for review. Crop waits for verified geometry support.

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

## 6. Milestones

**Current Status (2026-09-07):**
- **M0 — Feasibility spike: COMPLETED.** Requalified on 16.8.5.30 / macOS 26.4.1 / M1 Pro under single-session scope. Core write safety, RAW byte-for-byte preservation (`be59cd...`), working clone isolation, 5-field mutations/deltas, boundary rejection, dedicated preview export, and safe variant deletion verified in [single_session_safety.json](docs/m0/16.8.5.30/single_session_safety.json).
- **M1 — Safe editing + preview / v0.1: COMPLETED.**
  - Implemented `CaptureOneCore` Swift library and `c1` CLI executable.
  - FieldSpec registry for 5 verified fields (`exposure`, `contrast`, `saturation`, `temperature`, `tint`), 8 read-only metadata fields, and coupled WB handling.
  - Working-variant safety model enforced in the core: mutations to unmanaged native IDs or originals are rejected with `unmanaged-variant`. Provenance stored in `<SessionDir>/.c1/provenance.json`.
  - Document-bound execution, advisory flock locking, and pre-dispatch operation journaling in `<SessionDir>/.c1/journal.jsonl`.
  - Precondition checks (`--if-state`) using canonical 64-char hex SHA-256 state hashing with tolerance-aware precision rounding.
  - Bundled pre-compiled `Handlers.applescript` using non-reserved user-defined record keys (`usrf`).
  - Dedicated `c1-preview` recipe export with ImageIO verification and pixel SHA-256.
  - Implemented 12 CLI commands: `doctor`, `version`, `capabilities`, `schema`, `doc info`, `variants list`, `variant clone`, `variant delete`, `get`, `set`, `add`, `preview`, `operation status`.
  - 66/66 automated unit test assertions passing (`swift run CaptureOneCoreTests`).
  - 14/14 automated end-to-end integration steps passing on live Session with real Canon EOS R CR3 file, confirming zero corruption of RAW file (byte-for-byte identical SHA-256), original variant invariance, and clean clone deletion.
  - `examples/grade-folder.py` grading workflow with daylight preset and decision sidecars.
- **Roadmap Sequence Update:** Swapped M2 and M3 to make the CLI fully featured first before building the stdio MCP adapter.

---

### Milestone Roadmap

**M0 — Feasibility spike (Completed).** Discover blockers and retain repeatable probes. See [m0_requalification_16.8.5.30.md](docs/m0_requalification_16.8.5.30.md).

**M1 — Safe editing + preview / v0.1 (Completed).** Core library, working-variant enforcement, 12 core CLI commands, dedicated preview export, and integration harness.

**M2 — CLI Full-Featured & Core Capabilities (Completed).**
Make the CLI interface comprehensive before introducing the MCP adapter layer:
- **`reset`**: Implemented verified field resets on working variants in `Handlers.applescript` and `SessionController.swift` (`c1 reset <working-ref> --if-state <hash> [fields...]`).
- **`diff`**: Added standalone diff comparison command (`c1 diff <ref1> [ref2]`) to compare variants or compare working variant against baseline.
- **`dump`**: Batched export of variants, adjustments, and metadata as JSONL (`c1 dump [--collection <name>] [--format jsonl]`).
- **Catalog read-only detection and guards**: Added detection for open Catalogs, allowing read-only inspection, listing, `get` and `dump`, while rejecting `preview`, `clone`, `baseline`, `delete`, `set`, `add` and `reset`.
- **Managed default-baseline creation**: Added command for creating a managed default-settings baseline variant (`c1 variant baseline <source-ref>`).
- **Unit and fixture tests**: Extended test suite covering reset, diff, dump, and Catalog read-only guards (146/146 unit test assertions passing).

**M3 — Full-Featured MCP Server `c1-mcp` (Completed).**
Built a thin, robust stdio MCP adapter over the complete core library:
- Added official Swift MCP SDK dependency (`modelcontextprotocol/swift-sdk` v0.12.1) to `Package.swift`.
- Created `Sources/c1-mcp/` executable target running over stdio with `@MainActor` dispatching for Apple Events.
- Exposed the full suite of 16 tools (`doctor`, `doc_info`, `capabilities`, `schema`, `variants_list`, `variant_clone`, `variant_delete`, `variant_baseline`, `get`, `set`, `add`, `reset`, `diff`, `dump`, `preview`, `operation_status`).
- Added dual text (JSON metadata) + image (`image/jpeg` base64 payload) content blocks for `preview`.
- Maintained strict working-variant safety guards and Catalog fail-closed mutation barriers over MCP.
- Implemented comprehensive automated test suite (`Tests/mcp_test.py`) passing 10/10 test steps against live Capture One.

**M4 — Experimental style loop.** Add `learn-style.py`, the versioned `style/` artifact, explicit review records, `harvest-corrections.py`, and `propose-revision.py`. Start with curated reviewed Sessions and separate development/held-out shoots. Require declared evaluation criteria and photographer approval. Exercise the full loop on real shoots before considering format stability; two shoots alone are insufficient evidence of generalization.

**M5 — Breadth (only with demand).** Independently qualify arbitrary styles, metadata notes/tags, general recipe export, lossy snapshots on working variants, geometry, layers/masks, Color Editor corrections, additional builds, and Homebrew distribution. Preview caching requires measured need and reliable invalidation. Catalog mutations or editing originals require a separate design review; they are not automatic extensions of this safety model.

## 7. Historical feasibility questions and future evidence

### M0 questions (historical; current disposition in release validation)

- Are new clone IDs immediately unique and addressable without relying on selection? Can deletion ever affect the source file or other variants?
- What identifies a document instance, and how are stale references rejected after closing, reopening, switching, or replacing a document?
- Do native IDs survive restart/reorder? If not, can a persistent marker be stored without changing originals, siblings, or shared metadata? If neither works, explicitly select the limited reference lifetime.
- Which initial fields accept meaningful changed values and report the applied result accurately? Does any operation affect other fields or variants?
- What remains executing after a timeout or c1 crash, and what evidence can safely reconcile it? Can an unresolved operation prevent subsequent conflicting writes?
- Can polling reliably associate a completed output with the requested job/variant? If callbacks are required, can c1 recover shared settings after a crash without overwriting newer user changes?
- Do nested records and missing values round-trip through the pinned bridge? What batch sizes and deadlines keep the initial workflow responsive?

### Later feature gates

- Does native default-baseline creation preserve the intended camera/default context while removing unsupported final edits? Can Catalog exemplars be reproduced in a scratch Session without changing the Catalog?
- Which metadata fields are available for each document/source type, and how does chunked `dump` behave over a 10k-image Catalog with offline sources?
- Does crop depend on rotation/orientation order? Which other fields are coupled?
- Is a writable UI text field variant-local, and what happens during metadata sync/export? Can notes/tags be added without compromising original preservation?
- Can style application, copy/apply, and general export avoid changes to shared state or siblings? A successful adjustment setter does not qualify these operations.
- Which evaluation measures agree with photographer judgments, and how much independent reviewed evidence is needed before a revision or artifact format is promoted?

## 8. References for implementation checks

- [AppleScriptBridge](https://github.com/emorydunn/AppleScriptBridge): handler execution, descriptor conversion, and Codable support; verify the pinned commit against c1 fixtures.
- [AppleScript control statements](https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/reference/ASLR_control_statements.html): timeout does not cancel the target application's operation; transaction support depends on the application.
- [Capture One AppleScript documentation](https://support.captureone.com/hc/en-us/articles/360002681418-Capture-One-Workflow-Automation-with-AppleScript): scripting entry points and version-specific additions; runtime qualification remains required.
- [Capture One default settings](https://support.captureone.com/hc/en-us/articles/360002589997-Saving-new-default-settings-in-the-Base-Characteristics-panel): camera-specific profile/curve defaults affect new variants and must be recorded for reproducible baselines.
- [aelint documentation](https://github.com/alldritt/aequery#aelint): dynamic probe coverage and its same-value setter test; supplement with explicit changed-value and isolation tests.
