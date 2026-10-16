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
cancellation, and attaches `preview`, `thumb` and `contact_sheet` images; it stays long-lived so
compiled AppleScript handlers are reused. Contract version is `4.12.0`; package
version is `0.1.0`. The advisory lock serializes cooperating c1 processes only; it does not
lock the Capture One UI, other automation or delayed Apple Events.
Multi-process workflows are unqualified.

MCP adjustment keys may be flat (`{"workingRef": "...", "ifState": "...",
"exposure": 0.3}`) or grouped under `adjustments`. Mixed forms, duplicate aliases,
unknown fields and wrong types are rejected. `dump.batchSize` is 1–1000; preview
timeout is greater than zero and at most 300 seconds, with 120 as the default.

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

Each process reads `C1_CATALOG_WRITE_PATH` from its own environment, so the CLI
and the MCP server are configured separately. When `writesEnabled` is false,
`doctor` and `doc_info` add `writesDisabledReason`:

| Reason | Meaning |
|---|---|
| `unset` | The variable is unset or empty in this process. |
| `relative-path` | The variable is not an absolute path. |
| `different-catalog` | It resolves to another Catalog, or to another database inside the open package; the write error names the resolved path. |
| `database-path-required` | It names an unpackaged Catalog directory or a package with several databases; name the `.cocatalogdb`. |
| `catalog-build-required` | Catalog writes need Capture One 16.8.5.30. |
| `unsupported-version` | The running build is outside the supported range. |
| `checks-failed` | `doctor` only: another check failed. |
| `save-stalled` | `doctor` only: Capture One has not saved acknowledged writes; see [save stalls](#save-stalls). |

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
`variant baseline` creates a new default-settings variant. Capture One puts a new
clone or baseline into the current album. When that is one of the photographer's
albums, c1 removes it again in the same dispatch and records the album ID as
`removedFromAlbum` in the journal, so the album keeps its members. A Catalog's import
album under Recent Imports keeps the new variant, because deleting through that album
can delete the variant. After an uncertain clone, a candidate clone can remain in the
current album. `variant delete`
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

Without `collection`, the scope is Capture One's current collection, not the whole
document. A named collection need not be current: inventory and `dump` read its
variants through it and leave the current collection unchanged. `isSelected` and
`selected` both use that collection's own selection, which can differ from the
selection shown in the current collection. Adding some variants of a photo to an
album adds every variant the photo has at that moment. A variant created later
joins an album only when Capture One creates it with that album current.

`get`, edits, previews, clones and deletes find a native ID outside the current
collection and leave the current collection unchanged. Capture One resolves an ID
only through a collection that holds it, so a Catalog goes through All Images, whose
ID c1 reads from the Catalog's stored root collection, and a Session goes through its
folder favorites: Capture, Selects, Output and Trash, then the photographer's own.
The current collection is the last route, and the only one when a Catalog's stored ID
cannot be read. A variant that no route holds, such as one in a Session subfolder that
is not a favorite, fails with `variant-not-found` until the photographer makes a
collection holding it current.

Filtering runs before full metadata reads. On 16.8.5.30, native rating predicates
and bulk ID reads select candidates in Sessions and Catalogs; other builds use a
two-stage rating scan (`C1_INVENTORY_STRATEGY=scan` forces it); without a rating
filter the scan skips its separate ratings pass. Summaries are read in sequential
batches of `batchSize` / `--batch-size` (default 32, 1–256). A failed rating read
fails the request. The inventory holds the application lock, rechecks
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

`dump` takes the same `rating`, `minRating`, `ids` and `deadlineSeconds` filters,
in the CLI as `--rating`, `--min-rating`, `--ids` and `--deadline-seconds`:

```sh
c1 dump --collection Album --rating 5
c1 dump --ids 101,102 --collection Album
```

Rating filters apply before adjustments are read. `ids` dumps exactly those
variants through the subset reader above, so a missing or out-of-collection ID
fails with `variant-not-found` and nothing is dumped. With `--read-workflow`,
`rating` and `minRating` filter the cached membership; `ids` and `deadlineSeconds`
read live.

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
86400) applies to inventory and `dump`. Neither interrupts a dispatched Apple
Event; SIGKILL ends the process immediately, and an interrupted write follows
normal recovery.

MCP clients enforce their own request timeout. When it expires, the client cancels
and the server sends no response, so the agent gets neither a result nor a hint.
A `deadlineSeconds` below that timeout returns a clear `deadline-exceeded` error
instead. The CLI has no request timeout. On a Catalog, `catalog_variants` /
`c1 catalog variants` reads stored membership in seconds; revalidate its
candidates with `ids` on `variants_list` or `dump`. Inventory `deadline-exceeded`
and `request-cancelled` errors on a Catalog name that route in `recoveryAction`.

## Previews

`preview` exports into a unique `c1-previews/<operationId>` folder beneath the
Session's `Output` or a supplied directory, and waits for a stable, decodable
JPEG for up to `timeout` / `--timeout` seconds: more than zero, at most 300,
default 120. Exports in long batches have landed about 90 seconds after dispatch,
so the default leaves margin over that. `edit_apply` and `recipe_verify` take the
same value as `previewTimeout`. A timeout leaves the preview `outcome-unknown`
until [late preview resolution](#late-preview-resolution) or a restart.
MCP returns the JPEG as image content after the JSON result. With
`inlineImage: false`, it returns only the JSON text, and `previewPath` still names
the exported JPEG. The option is MCP only and defaults to true. The CLI never
inlines the image.
Metadata includes the native variant ID and state tokens, which are checked across
rendering. Tokens do not cover every layer, curve or render setting, so preview
caching by token is unsupported. Preview counts as a mutating tool.

`size` / `--size` sets the JPEG's long edge in pixels: 400, 800, 1200 or 1500, with
1500 as the default. `edit_apply` and `recipe_verify` take the same values as
`previewSize`. Any other value fails with `invalid-request` before anything is
journaled or sent to Capture One. The result and the journal entry record the
requested size, and the readback rejects an export whose decoded long edge differs
from it. `capabilities.previewRecipe` lists the sizes, the default and each size's
recipe.

Each size exports through its own reserved recipe, JPEG quality 80 in sRGB:
`c1-preview` for 1500 px and `c1-preview-<size>` for the others, such as
`c1-preview-800`. c1 creates a recipe the first time its size is used and
reconfigures it before every export, so do not use these recipes for your own
exports. Capture One renders from the RAW at every size, so a smaller size makes a
smaller file but may not save much export time.

## Embedded camera previews

`c1 thumb <ref>` / `thumb` returns the JPEG the camera embedded in the variant's
original, for fast visual triage of many photos without a Capture One export. It
reads the original with [exiftool](https://exiftool.org), installed separately as
for [`exif`](geometry.md#camera-level), and takes the largest decodable
`JpgFromRaw` or `PreviewImage`. On Canon CR3 files that is the full-size
`JpgFromRaw`. The pixels are turned to the original's EXIF orientation
(`exifOrientation`, 1 when unrecorded), and `maxSize` / `--max-size` fits the long
edge within that many pixels without enlarging. The result names the file in
`thumbPath` with its `width` and `height`; MCP also attaches the image.

The result is the camera's rendering: it shows no Capture One adjustments, crop,
rotation or orientation change, and it states so in `cameraRendering` and
`limitation`. It is a triage aid and never review evidence for an edit or a recipe
([invariant 8](../../AGENT_GUIDE.md#safety-invariants)); review edits with
`preview`. Use it to sort and pick photos, or to see what a crop placement keeps
of the full frame before preparing an edit.

`thumb` only reads the original. It writes no journal entry, needs no write opt-in,
returns no state tokens and is available in the composition profile. The JPEG is
written to `~/Library/Caches/c1/thumbs`, outside the document, so a read-only
Catalog stays untouched. Each original and `maxSize` has one file, named after
the original, which the next call replaces; macOS may purge the folder at any time.

## Contact sheets

```sh
c1 contact-sheet --min-rating 3                 # page 1: 20 photos in rows near 220 px
c1 contact-sheet --min-rating 3 --page 2
c1 contact-sheet --collection "Day 1" --selected --per-page 12 --row-height 300
c1 contact-sheet --ids 101,102,140
```

`contact_sheet` tiles Capture One's own cached thumbnails for a scope of variants
into one JPEG per call. Each tile shows the photo as Capture One renders it now,
with the photographer's adjustments and a verified crop, so an agent can triage
many photos in a few calls. The scope takes the filters of `dump`: `ids` (1–512
known IDs, revalidated live), or `collection`, `selected`, and `rating` or
`minRating`. Without a filter, the scope is the current collection. Tiles follow
Capture One's order. MCP takes the same arguments in camelCase, such as `perPage`.

`page` selects a page, 1 by default, and `perPage` (1–48, default 20) sets how many
photos it holds. Call again with `nextPage` until the result has none. A page past
the end fails with `invalid-request`. An empty scope returns `total` 0 and no
`sheet`. Each call lists a scope without `ids` again, so for a large scope, list it
once with `variants_list` and page through its IDs with `ids`.

The sheet is at most 1536 px wide, below the edge at which clients downscale an
image. A page whose rows do not fill that width narrows to its widest row, but not
below 480 px. Photos keep their own aspect ratio, after any applied crop, in justified rows near
`rowHeight` (120–450 px, default 220):

- A row takes photos at `rowHeight` until the next one would overflow the width.
  It then either takes that photo and becomes lower, or leaves it for the next row
  and becomes taller, whichever lands closer to `rowHeight`. Either way the row
  fills the width exactly. A row grows to at most 1.5 × `rowHeight`; a row capped
  there is left-aligned.
- The last row keeps `rowHeight` and is left-aligned.
- A missing or unreadable tile takes a 3:2 placeholder.
- A page taller than 2400 px gets lower rows, or the same rows scaled down
  uniformly with a narrower sheet, whichever shows more photo.

Small crops are enlarged to their row. Under each image, a 16 px label strip of the
image's width shows `id · ★rating · name` with the live rating, truncated with an
ellipsis.

The result lists every tile's `id`, `name`, `rating`, `status` and `cell`, the
image's rectangle in sheet pixels from the top left; its label is directly below.
A shown tile also reports `cachedSize`, the cached pixels it shows after the crop,
which is the real detail behind an enlarged tile:

```json
{"id": "101", "name": "TK7A7231.CR3", "rating": 3, "status": "shown",
 "cell": {"x": 4, "y": 28, "width": 302, "height": 202},
 "cachedSize": {"width": 219, "height": 146},
 "cacheModifiedAt": "2026-10-15T12:00:00Z", "crop": {"status": "applied"}}
```

`status` is one of these values:

- `shown`, with `cachedSize`, the thumbnail's `cacheModifiedAt` and its `crop`.
- `missing`, with `reason` `not-cached` when Capture One has no thumbnail for the
  variant, or `not-stored` when the variant is not yet in the saved database.
- `unreadable`, with a `reason` such as `undecodable` or `orientation-tag`.

A missing or unreadable tile is a gray placeholder labeled NO CACHE, NOT SAVED or
UNREADABLE. c1 never replaces it with an export and never guesses which file to
show; use `thumb` or `preview` for those IDs.

The cached pixels are uncropped. c1 applies the crop that Capture One stores with
the thumbnail only when its format is verified, and `crop.status` is `applied`,
`full-frame` or `not-applied`. A `not-applied` tile shows the full frame with an
amber UNCROPPED badge. Its `crop.reason` is `absent`, `format-version-2` (written by
older builds) or `unsupported-format`, and `crop.userComment` keeps the stored
value. `counts` totals the statuses and the uncropped tiles.

A thumbnail is at most 450 px on the long edge before the crop, and it can lag an
edit that Capture One has not processed yet. Two cases were observed on 16.8.5.30:

- **Unsaved new variants.** A variant that Capture One has not yet saved to a
  Session's database is `missing` with `not-stored`, NOT SAVED on the sheet. This
  happened for a newly created Session and for a new clone, and lasted 25–35 s in
  tests. Call again after Capture One's next save.
- **Stale thumbnail after orientation.** Setting orientation through c1 on a
  variant that already had a crop and rotation did not refresh its cached
  thumbnail. The tile still showed the old orientation after 60–90 s, and the next
  tonal edit refreshed it. A tile can therefore lag a c1 geometry edit.

A sheet is a triage aid and never review evidence for an edit or a recipe
([invariant 8](../../AGENT_GUIDE.md#safety-invariants)); review edits with
`preview`. The result's `limitation` says so.

`contact_sheet` only reads. It sends no write, writes no journal entry, needs no
write opt-in, returns no state tokens and is available in the composition profile.
It finds each thumbnail from stored identity and never lists the cache folder. In a
Catalog, the variant's database ID names the file. In a Session, c1 reads each
variant's UUID from the open `.cosessiondb` without SQLite locks. A stored file name
that differs from the live original fails the call with `identity-ambiguous`, and a
document change during the call fails it with `document-changed`. Neither writes a
sheet. The tool requires Capture One 16.8.5.30 exactly, because the cache layout
is qualified only on that build; `C1_ALLOW_UNTESTED_BUILD` does not enable it.

The sheet is written to `~/Library/Caches/c1/contact-sheets`, outside the document,
as `<document>-<hash>-p<page>.jpg`. The same document, scope, `perPage`,
`rowHeight` and page replace their own file, and c1 keeps the 50 newest sheets.
MCP attaches the sheet as image content. With `inlineImage: false`, it returns only
the JSON, and `sheet.path` still names the JPEG.

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
`operation_status` reports whether the operation is resolved. A timeout does not
cancel the Apple Event, so Capture One can still apply the write after the error.
Status resolves the operation only when the event has ended, and sets `resolution`
to say how. A reconciliation records observed adjustments, geometry, metadata,
native state or candidate clone IDs and ends the write block.

`probe-barrier` applies on the qualified build (16.8.5.30) to covered writes.
Capture One handles scripting Apple Events one at a time, so when it answers the
status call's own event, it has finished the uncertain one. Status reconciles at
once, with no restart. Editing references stay valid; read `get` again for fresh
tokens before the next write.

`late-preview` applies to a timed-out preview whose JPEG has landed; see
[late-preview resolution](#late-preview-resolution).

`restart` applies to every other case. Restart Capture One, reopen the same
database and run status again. A restart ends every Apple Event of the previous
process. Old references are then invalid, so prepare a fresh one.

| Write | Resolution without a restart |
|---|---|
| `set`, `add`, `reset`, `metadata_set`, `geometry_set`, `geometry_restore`, `native_set`, `variant_clone`, `variant_baseline`, `variant_delete` | Probe barrier |
| `native_action` with `layer.create`, `layer.delete`, `mask.people`, `mask.clear`, `mask.invert`, `mask.fill`, `mask.rasterize`, `mask.copy`, `color.create`, `color.delete`, `dehaze.pick`, `dehaze.recalculate`, `lens.reset`, `luma.clear` or `style.apply` | Probe barrier |
| `native_action` with `mask.feather` or `mask.refine` | None. They change nothing Capture One exposes to scripting, so the barrier cannot be qualified for them. |
| `preview` | Late preview only. Capture One exports on a background queue that the barrier does not cover. |
| A [save-stalled](#save-stalls) write | None. The write finished but is unsaved, which only a restart reveals. |
| Any write on another build | None |

A recipe's child writes follow the row of their own kind. If the status call
itself times out, it records nothing and the write stays blocked until a restart.

`doctor` reports `unresolvedOperationsCount` only after reading the journal; an
absent count means unknown and `diagnosticError` explains why.

Journals, provenance and baselines live in the document's `.c1` folder (for a
Catalog, inside the package). A missing identity record, replaced database or
corrupt journal requires manual inspection.

### Save stalls

Capture One acknowledges a write live and saves the database about once a minute.
It can also stop saving: acknowledged writes then never reach the database, even
after the document closes, and the document reopens without them. c1 checks for
this before every write and in `doctor`.

A process that holds a SQLite read lock on the database while Capture One saves
causes this. Capture One then drops that save and every later change to the
document. On Capture One 16.8.5.30 a read held across the save stalled it every
time, and a reader polling twice a second stalled it in one run of six. c1's stored
reads take no locks. While Capture One has the database open, do not open it with
other SQLite tools, such as the `sqlite3` shell, a database browser, or a script,
unless they read with `immutable=1`.

A write is unsaved when it succeeded, or was reconciled behind the probe barrier, in
the running Capture One process, changed something (every write except `preview`
and writes whose readback or reconciliation shows no change),
and the database file has not been modified since its dispatch. Once the oldest
unsaved write is 5 minutes old, c1 appends an `outcome-unknown` snapshot with
`saveStalledAt` for every unsaved write, so writes are blocked as after any
uncertain outcome. The block stays even if Capture One saves later. `doctor` then
reports `writesDisabledReason: save-stalled` and `saveStall` with the
`operationIds`, the oldest write's age in `oldestAgeSeconds`, and
`databaseModifiedAt`, when the database was last written.

To recover, restart Capture One, reopen the same document and run
`operation_status` for each ID in `saveStall.operationIds`. Reconciliation records
the observed state. Compare it with the journaled values and reapply what is
missing as new writes with fresh references and tokens; never repeat the original
command. Detection needs the Capture One process that acknowledged the writes, so
after a batch run `doctor` at least 5 minutes after the last write, before handing
back or quitting Capture One.

### Late preview resolution

An export changes no settings, so `operation_status` can confirm a timed-out
`preview` without a restart, although the probe barrier does not cover exports.
Every condition must hold:

- The operation is a `preview` with status `outcome-unknown`, and Capture One is
  still the process that started it.
- The open document's database identity matches the journal.
- The journaled `c1-previews/<operationId>` folder holds exactly one JPEG, and it
  is complete, stable and decodable.
- Its long edge equals the journaled `previewSize`, and its aspect matches the
  journaled crop ratio within the readback tolerance.
- A fresh read of the journaled native variant returns the same parent image,
  `preconditionStateHash` and `preconditionGeometryStateHash`.

Status then appends a snapshot with `status: succeeded`,
`resolution: late-preview` and `previewOutputPath` naming the JPEG, and the write
block lifts.
No restart happened, so references stay valid. A failed check appends nothing and
leaves the operation unresolved; ask again after the JPEG lands, or restart and
reconcile. After a restart, normal reconciliation records `reconciled` with
`resolution: restart`, even for a complete JPEG. Journal entries written before contract 4.9.0
lack `preconditionGeometryStateHash` and always need the restart.

A saved compound report never changes after the fact. When the preview step of
`edit_apply` or `recipe_verify` resolves late, `edit_status` still reports
`outcome-unknown` and lists the resolved child in `childOperations`. The steps
before the preview completed, `observe` never ran, and a verification stays
`verified: false`. Read fresh tokens before the next write.

## Tool profiles

`C1_TOOL_PROFILE=composition` (older alias `C1_MCP_PROFILE`) hides and rejects
`set`, `add`, `reset`, `variant_baseline`, `metadata_set`, native mutations and
recipe capture/register/verify/apply. Preparation, geometry, inspection
(including `exif`, `thumb` and `contact_sheet`), cloning, clone deletion, preview and recovery
remain. An unknown value, or two names that disagree, rejects every request.

## Error codes

| Code | Meaning |
|---|---|
| `app-not-running` | Launch Capture One. |
| `no-document` | Open a Session or Catalog. |
| `unsupported-version` | Build outside 16.4–16.x; `C1_ALLOW_UNTESTED_BUILD=1` overrides compatibility only. `contact_sheet` requires 16.8.5.30 exactly. |
| `identity-ambiguous` | An ID or stored record cannot identify exactly one variant, image or file, such as a contact sheet's stored file name that differs from the live original. Nothing was changed. |
| `unmanaged-variant` | Write without an editing reference, or deletion of an existing variant. |
| `variant-not-found` | An ID does not resolve through any route; known-ID lists report `missingIds` and `outOfScopeIds`. |
| `state-changed` | A token is stale; read again and reconcile. |
| `document-changed` | Document count, identity or application lifetime changed. |
| `readback-mismatch` | Capture One returned values outside tolerance. |
| `outcome-unknown` | The write may have happened; follow recovery. |
| `partial-failure` | Readback differs from the intended write; writes are blocked as for `outcome-unknown`. |
| `request-cancelled` | Stopped at a safe boundary; a compound report lists completed steps. Never resume it automatically. |
| `deadline-exceeded` | Inventory passed its deadline at a boundary. |
| `no-people-detected` | A people mask found nobody and readback confirmed no change; the operation failed and blocks nothing. |
| `dependency-missing` | An optional local tool, such as exiftool for `exif` and `thumb`, is not installed or cannot start. Nothing was changed. |
| `capture-one-busy` | The advisory lock timed out; check for hung processes. |
| `permission-denied` | Automation permission was denied (-1743). Allow the host app under **Privacy & Security → Automation**. An unanswered consent dialog does not give this code; it blocks until `timeout`. |
| `timeout` | An Apple Event got no answer in time (-1712). macOS may be waiting for the photographer to answer the Automation consent dialog, which can be hidden behind other windows. Capture One may also show a modal dialog or be busy. After a write, follow [recovery](#recovery-commands); never repeat the write. |
