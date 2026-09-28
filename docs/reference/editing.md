# Editing reference

Commands for tonal, rating and color-tag edits, variant selection, progress,
previews and recovery. The rules they enforce are the
[safety invariants](../../AGENT_GUIDE.md#safety-invariants); the order of calls is the
[canonical workflow](../../AGENT_GUIDE.md#canonical-editing-workflow).

## Contract

`c1 schema` and the MCP `schema` tool return one contract: request schemas,
response schemas and the error envelope. Every CLI command except `version` maps
its flags to the tool's arguments object and enters the same core dispatcher as
MCP, so both transports accept and reject identically. The MCP server registers
tools from the contract, forwards arguments unchanged, reports progress and
cancellation, and attaches preview images; it stays long-lived so compiled
AppleScript handlers are reused. Contract version is `3.4.0`; package version is
`0.1.0`. The advisory lock serializes cooperating c1 processes only; it does not
lock the Capture One UI, other automation or delayed Apple Events.
Multi-process workflows are unqualified.

MCP adjustment keys may be flat (`{"workingRef": "...", "ifState": "...",
"exposure": 0.3}`) or grouped under `adjustments`. Mixed forms, duplicate aliases,
unknown fields and wrong types are rejected. `dump.batchSize` is 1–1000; preview
timeout is greater than zero and at most 300 seconds.

## Catalog editing

`C1_CATALOG_WRITE_PATH` accepts a `.cocatalog` package holding exactly one
`.cocatalogdb`, or the exact `.cocatalogdb` inside it; with several databases,
name the database. Unpackaged Catalog directories must name the exact
`.cocatalogdb`. Write authorization must resolve to the database Capture One has
open; other Catalogs stay read-only and read-only inspection needs no variable.
Originals must be referenced, online and outside the Catalog; Catalog-stored
originals are blocked. Catalog journals and provenance live in
`Main.cocatalog/.c1`, and previews in `Main.cocatalog.c1-output/c1-previews/`.
If the Catalog has no usable default output location, preview sets it to that
folder. Catalog fault recovery is unqualified.

## Tonal adjustments

`set`, `add` and `reset` take `ifState` from `get.stateHash` and support only:

| Field | Aliases | Range |
|---|---|---|
| `exposure` | `exp` | −4 to 4 EV |
| `contrast` | — | −50 to 50 |
| `saturation` | `sat` | −100 to 100 |
| `temperature` | `kelvin`, `temp` | 800 to 14000 K |
| `tint` | — | −50 to 50 |

Values must be finite. Writes touch requested fields only; white balance is written
and checked as a temperature/tint pair, so inspect both after a change. The handler
checks the five-field state again immediately before its setters. Property writes
are sequential, not atomic: a later failure can leave an earlier field applied.

`reset` restores exposure/contrast/saturation defaults and baseline white balance;
it is not an undo. `diff <ref>` compares with the saved baseline and
`diff <ref1> <ref2>` compares two variants. `dump` exports batched JSONL.
`variant baseline` creates a new default-settings variant. `variant delete`
removes only agent-created clones, requires their source variant to remain, and
never deletes an image's last variant.

## Ratings and color tags

`c1 metadata set` / `metadata_set` takes `ifMetadataState` from
`get.metadataStateHash`. `rating` is an integer 0–5 and `colorTag` a native
integer 0–7; 0 clears either. Omitted fields, tonal values and geometry are
preserved. Writes require Capture One 16.8.5.30.

```sh
c1 get <working-ref>
c1 metadata set <working-ref> --if-metadata-state <metadataStateHash> --rating 5 --color-tag 4
```

`dryRun` reports the proposed values; its token is the current one. Responses
contain `before`, `after`, `diff` and the new token. New references and clones
keep `baselineMetadata`, and `diff` adds `metadataBefore`, `metadataAfter` and
`metadataDiff`. Tonal `reset` leaves ratings and tags unchanged. Other metadata is
read-only.

## Selecting variants

```sh
c1 variants list --rating 5                 # exactly 5 stars
c1 variants list --min-rating 4             # 4 or 5 stars
c1 variants list --rating 0                 # unrated
c1 variants list --collection Capture --selected --rating 5
```

MCP `variants_list` takes `rating` or `minRating` (not both), plus `collection` and
`selected`. Filters leave Capture One's UI selection unchanged, and no match
returns an empty list. Results are variants: several edits of one photo, including
managed clones (`isManagedWorkingClone`), can appear.

Filtering runs before full metadata reads. On 16.8.5.30 Sessions, native rating
predicates and bulk ID reads select candidates; Catalogs and other builds use a
two-stage rating scan (`C1_INVENTORY_STRATEGY=scan` forces it). Summaries are read
in sequential batches of `batchSize` / `--batch-size` (default 32, 1–256). A failed
rating read fails the request. The inventory holds the application lock, rechecks
the document token between batches and compares scope membership before
returning; it is not an atomic snapshot.

For a known subset, pass up to 512 unique native IDs:

```sh
c1 variants list --ids 101,102,103 --rating 5 --fields summary
c1 variants list --ids 101,102 --parent-path /photos/Capture/photo.CR3
```

This path bypasses the browsing cache and returns `id`, `rating` and
`parentImagePath` by default; `fields: "summary"` adds name, selection and color
tag. `parentPath` is an exact file path, not a folder prefix. A missing or
out-of-collection ID fails the request with `variant-not-found`, listing
`missingIds` and `outOfScopeIds`; rating, path and selection nonmatches are
omitted. The reader revalidates every row and the document identity before
returning; drift returns no partial result. `--ids`, `--fields` and
`--parent-path` are unavailable with `--database`.

## Progress, status and cancellation

```sh
c1 variants list --rating 5 --progress human
c1 variants list --rating 5 --deadline-seconds 120 --progress json
c1 request status req-<UUID> --format json
```

Every command and tool call gets a request ID, separate from operation IDs and
never a write authorization. Status snapshots record elapsed time, phase,
strategy, completed counters and any outstanding handler. `pass` 1 reads
candidates and pass 2 revalidates them; first-pass matches are
`unconfirmedMatches`, and `matchesFound` counts only revalidated matches. For
`native-filter`, candidate totals are the IDs the predicate returned, not
Capture One's internal scan. A five-second heartbeat shows the service is alive,
not that photos were processed; there is no percentage or ETA. Requests are
marked slow after 10 seconds (`C1_SLOW_REQUEST_SECONDS`). `handlerCalls` counts
script invocations, not the Apple Events inside them. MCP callers with
`_meta.progressToken` receive progress notifications for observed work.

Progress goes to stderr (`--progress human|json|quiet` or `C1_PROGRESS`). Error
envelopes add `requestId`, `phase` and `elapsedMs`; a failed request's status keeps
`errorCode`, `errorMessage`, `missingIds` and `outOfScopeIds`. Snapshots live in
`~/Library/Caches/c1/requests` (`C1_REQUEST_DIR` overrides; `off` disables).
`request_status` / `c1 request status` reads them without the lock or an Apple
Event. `C1_DIAGNOSTICS=1` keeps per-request JSONL events; paths and names are
omitted and document identity is hashed.

Ctrl-C or SIGTERM on the CLI, like MCP cancellation, stops at the next safe
boundary. Inventory and `dump` stop between Apple Events and return nothing
partial. Compound edits stop between steps and return a `failed` report with code
`request-cancelled`. Other commands finish normally. Repeated signals do not force
an exit, and `request status` shows `cancelRequested`. `deadlineSeconds` (up to
86400) applies to inventory. Neither interrupts a dispatched Apple Event; SIGKILL
ends the process immediately, and an interrupted write follows normal recovery.

## Previews

`preview` exports into a unique `c1-previews/<operationId>` folder beneath the
Session's `Output` or a supplied directory, and waits for a stable, decodable
JPEG. MCP returns the image plus JSON metadata; other tools return JSON text.
Metadata includes the native variant ID and state tokens, which are checked across
rendering. Tokens do not cover every layer, curve or render setting, so preview
caching by token is unsupported. c1 configures the reserved `c1-preview` recipe;
do not use it for your own exports. Preview counts as a mutating tool.

## Compact results

`set`, `add`, `reset`, `metadata_set`, `geometry_set`, `geometry_restore`,
`native_set`, `native_action`, `preview` and the five recipe tools return compact
results by default: operation, compound, reference or recipe IDs, changed fields,
new tokens, coverage and unavailable fields, status, preview path and
`evidencePath`. That JSON file under the document's `.c1/results` holds the
complete result: before/after values, native snapshots, geometry and the full
compound report. `--full` / `full: true` returns it inline. A result whose evidence
file cannot be written is returned in full. The schema's `compactResponses`
describes compact shapes; `responses` describes complete ones.

## Recovery commands

Errors after dispatch carry `operationId`. `c1 operation status <operationId>` /
`operation_status` reports whether the operation is resolved. While the original
Capture One process runs, it stays unresolved: a timeout does not cancel the Apple
Event. After a restart and reopening the same database, status reconciliation
records observed adjustments or candidate clone IDs and ends the write block.
`doctor` reports `unresolvedOperationsCount` only after reading the journal; an
absent count means unknown and `diagnosticError` explains why.

Journals, provenance and baselines live in the document's `.c1` folder (for a
Catalog, inside the package). A missing identity record, replaced database or
corrupt journal requires manual inspection.

## Tool profiles

`C1_TOOL_PROFILE=composition` (older alias `C1_MCP_PROFILE`) hides and rejects
`set`, `add`, `reset`, `variant_baseline`, `metadata_set`, native mutations and
recipe capture/register/verify/apply. Preparation, geometry, inspection, cloning,
clone deletion, preview and recovery remain. An unknown value, or two names that
disagree, rejects every request.

## Error codes

| Code | Meaning |
|---|---|
| `app-not-running` | Launch Capture One. |
| `no-document` | Open a Session or Catalog. |
| `unsupported-version` | Build outside 16.4–16.x; `C1_ALLOW_UNTESTED_BUILD=1` overrides compatibility only. |
| `unmanaged-variant` | Write without an editing reference, or deletion of an existing variant. |
| `variant-not-found` | An ID does not resolve; known-ID lists report `missingIds` and `outOfScopeIds`. |
| `state-changed` | A token is stale; read again and reconcile. |
| `document-changed` | Document count, identity or application lifetime changed. |
| `readback-mismatch` | Capture One returned values outside tolerance. |
| `outcome-unknown` | The write may have happened; follow recovery. |
| `partial-failure` | Readback differs from the intended write; writes are blocked as for `outcome-unknown`. |
| `request-cancelled` | Stopped at a safe boundary; a compound report lists completed steps. Never resume it automatically. |
| `deadline-exceeded` | Inventory passed its deadline at a boundary. |
| `no-people-detected` | A people mask found nobody and readback confirmed no change; the operation failed and blocks nothing. |
| `capture-one-busy` | The advisory lock timed out; check for hung processes. |
| `permission-denied` | Allow the host app under **Privacy & Security → Automation**. |
