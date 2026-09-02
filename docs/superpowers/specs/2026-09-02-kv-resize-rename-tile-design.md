# KV Resize — rename a tile

> **Written:** 2026-09-02, from the handoff at
> `docs/superpowers/specs/2026-09-02-kv-resize-rename-tiles-handoff.md`.
> **Status:** design approved section-by-section by Daffa. Not yet planned,
> not yet implemented, never run in a browser.

## Goal

Let a user give a resize tile a meaningful name, so `100 × 200 (2)` can read
`Hero variant` instead. Naming happens **after** the tile exists — the
duplicate-tile spec deferred rename on exactly that reasoning, and it still
holds: a name is only useful once there is a result to name.

## Branch

Rename gets **its own branch, cut after** Daffa decides what happens to
`feature/daffa/vc-kv-resize-duplicate-tile` (merge locally, open a PR, or
leave it). That branch is merge-ready and unpushed in two repos — `api`
6 commits, `web` 10 — and nothing here may be stacked onto it.

## Corrections to the handoff

The handoff was written from an end-of-session inspection and is wrong or
incomplete in five places. Verified 2026-09-02 against the working tree.

| Handoff | Actual |
|---|---|
| `api/app/Http/Resources/KvResizeExportResource.php:22` | `api/app/Http/Resources/**Studio**/KvResizeExportResource.php:22`. Line and expression exact. |
| "two label paths in web" | **Four client-derived surfaces** in web, plus two api-side label surfaces it never mentions. |
| "the panel already has `ex` in scope, so it is a one-line change" | **False.** `PlatformRow` (`KvResizePanel.tsx:332`) takes `platform: Platform` + callbacks only, renders `{p.label}` at `:391`, and repeats the label in four `aria-label`s (`:407`, `:421`, `:435`, `:449`). `ex` lives one closure above (`:202`, `:309`). Small, but a prop-signature change across five sites. |
| — | **Chat markers.** `KvResizeChatMarkerService::labelsFor()` (`:282`) takes ids only and **freezes the label as literal text** into `user_chat_histories` at write time (`:41`, `:71`, `:109`). Separately, the client **ignores** the `platform_labels` the server already sends and re-derives via `platformById` (`KvChat.tsx:1301`, `:1361`). |
| — | **Zip filenames.** `KvResizeExportController.php:488-495` builds entry names from `platform_id` alone. |
| "most of the time is the edit affordance" | Cheaper than assumed — a reusable inline-rename pattern exists at `LayersPanel.tsx:125-229`. The cost moved to three things the handoff did not scope: duplicate-name validation, the `(copy N)` search, and zip slugification. |

Confirmed as stated: no `name` in `$fillable`/`$casts`; jsonb `metadata` is the
wrong home (it is deliberately not copied on duplicate and holds
render-lifecycle caches); the overlays PATCH at `routes/api.php:4133` is
precedent but must **not** be extended; the share payload ships `platform_id`
and no label (`KvSharePayloadService.php:269-283`), so it is the real scope
multiplier.

### Two structural facts that shaped the design

1. **The ordinal is not a display suffix — it is inside the identity.**
   `platform_id` is literally `custom-100x200-2` (`CustomResizeSize::PATTERN`),
   arbitrated by `unique(parent_generation_id, platform_id)`. A name can only
   *mask* the ordinal in display, never replace it. Row identity stays unique
   regardless of naming, so rejecting duplicate names is a **UX** choice, not a
   data-integrity one.
2. **A name belongs to a row, not to a platform.** `PlatformRow` renders preset
   rows that have **no export yet** — there is nothing to name. So client-side
   derivation via `platformById` cannot be deleted; it is *ranked second*.

## Decisions (Daffa, 2026-09-02)

| # | Decision | Choice |
|---|---|---|
| 1 | Duplicating a named tile | Copy is named `"<source> (copy)"` |
| 2 | Duplicate names | **Reject, 422** |
| 3 | Rename scope | **All tiles**, presets included |
| 4 | Share page | **In scope** |
| 5 | `(copy)` collision | Server searches for a free name: `(copy 2)`, `(copy 3)`… |
| 6 | Name uniqueness scope | Per `parent_generation_id` |
| 7 | Chat markers | **Leave alone** — derived/frozen, historical record |
| 8 | Zip filenames | **Use the name**, slugified |

Note the interaction between 1, 2 and 5: auto-naming copies would collide with
the reject rule, and **a duplicate must never fail because of a name**.

Two rules inferred rather than stated, recorded here for correction:
- **Copy naming is flat.** Duplicating `Hero variant (copy)` yields
  `Hero variant (copy 2)`, not `Hero variant (copy) (copy)` — the suffix is
  stripped to find the base. (Matches the preview Daffa selected.)
- **Names are case-sensitive.** `Hero` and `hero` are distinct, which is what a
  plain Postgres `unique` gives. Case-insensitive would need
  `whereRaw('lower(name) = ?')`.

## Approach: row-label-wins, server authoritative

Rejected alternatives:

- **Ship `name` as its own field and compose `name ?? derived` per surface.**
  Re-implements the fallback at four sites. `CustomResizeSize::labelFor`'s own
  docblock says that chain "was written out verbatim at every such site, which
  is one place too many for the fallback to drift" — this walks straight back
  into it.
- **Client-only display store.** Cannot reach the share page, which is in
  scope. `metadata` was already ruled out by the handoff.

Chosen: one authoritative fallback chain in PHP, `platformById` demoted to
"no row exists". It is the only option where a ninth label surface added later
inherits rename for free.

## 1. Data model

```php
// api/database/migrations/2026_09_02_000001_add_name_to_kv_resize_exports_table.php
$table->string('name', 120)->nullable()->after('platform_id');
```

- **Nullable, no default.** `null` means "derive" — that is what makes
  `name ??` work. Diverges from the sibling `kv_motion_projects.name`
  (`->default('Untitled motion')`, `2026_08_02_100000`) on purpose: a default
  would mark every existing tile as named and permanently mask its derived
  label.
- `after('platform_id')`, matching the existing add-column style
  (`2026_06_09_000001_add_additional_prompt_...`).
- **120 chars**, matching the `objects.*.label` cap in
  `UpdateKvResizeExportDetectionsRequest`.
- Add `'name'` to `$fillable` in `api/app/Models/KvResizeExport.php`. No cast.
- **No DB unique index.** Postgres treats multiple `NULL`s as distinct (fine),
  but a unique index would surface a clash as
  `UniqueConstraintViolationException` — a 500 shape — where decision 2 calls
  for a 422. Validation is the right layer, and the `(copy N)` search reads
  existing names anyway.
- **No backfill.** Every existing row is `null` and renders exactly as today.

`KvResizeExportService::duplicate()` lists its fields explicitly
(`:128-146`), so a copy is unnamed unless §2's logic is added.

## 2. Endpoint, validation, and the `(copy N)` rule

Its own route — **do not extend the overlays PATCH**:

```php
// api/routes/api.php, beside the overlays PATCH (~:4133)
Route::patch(
    'files/{file}/resize-exports/{export}/name',
    [KvResizeExportController::class, 'updateName'],
);
```

No `check.credits` — a rename calls no model. Guards copy `regenerate`
verbatim (`:182-188`): workspace `403`, file-ownership `404`. **No custom-id
guard** — decision 3 makes presets renamable, unlike `duplicate`, which stays
custom-only (`:236`).

Validation lives in a new `KvResizeExportRenameRequest` (sibling convention;
the handoff's `excludeUnvalidatedArrayKeys` trap concerns `payload.*` array
rules and does not apply to a flat scalar):

```php
'name' => ['present', 'nullable', 'string', 'max:120'],
```

`present` + `nullable` is deliberate — `null` is a **meaningful value**, the
way a user clears a name and returns to the derived label. `sometimes` would
make an omitted key a silent no-op.

After validation: `trim()`, then `''` → `null`, the same normalization
`regenerate` applies to `additional_prompt` (`:199-200`). **Clearing the field
and submitting blank is the un-rename path** — no separate delete route.

Uniqueness, per decision 6:

```php
Rule::unique('kv_resize_exports', 'name')
    ->where(fn ($q) => $q->where('parent_generation_id', $export->parent_generation_id)
                         ->whereNull('deleted_at'))
    ->ignore($export->id)
```

`whereNull('deleted_at')` matters: the table soft-deletes, so without it a
trashed "Hero" would hold the name forever.

User-facing 422 message: **"That name is already used on this KV."**

### The `(copy N)` search

In `KvResizeExportService::duplicate()`, mirroring the shape of `nextOrdinal()`
beside it (`:168`):

```
source "Hero variant"         → "Hero variant (copy)"
"(copy)" already taken        → "Hero variant (copy 2)", then (copy 3)…
source "Hero variant (copy)"  → base "Hero variant" → "Hero variant (copy 2)"
source unnamed (null)         → copy stays null → derives "100 × 200 (3)"
```

- Flat, never nested (inferred rule, above).
- **The 120-char cap cannot be violated by the suffix**: if
  base + `" (copy N)"` would exceed 120, the base is truncated to fit.
- **It must never throw.** If no free name is found, the copy falls back to
  `null` rather than failing the duplicate — decision 5's constraint.
- Uniqueness here is enforced by the search, not the validator:
  `duplicate()` does not run the FormRequest.
- **Presets never reach this code.** Decision 3 makes a preset tile renamable,
  but `duplicate` remains guarded to custom ids
  (`KvResizeExportController.php:236`), so a renamed preset has no copy path
  and needs no base-name rule.

## 3. Label resolution

One line carries most of the feature:

```php
// api/app/Http/Resources/Studio/KvResizeExportResource.php:22
'platform_label' => $this->name
    ?? $platform['label']
    ?? CustomResizeSize::labelFor($platformId)
    ?? $this->platform_id,
```

**Six surfaces inherit rename with zero edits** — all read `platformLabel`,
mapped from wire `platform_label` at `services/kv/api.ts:796` and
`services/kv/resize-stream.ts:41` (both untouched, so the SSE path renames
live too):

- `web/src/components/studio/kv-generator/KvResizeResultRow.tsx:265`
- `web/src/components/studio/kv-generator/KvResizeCanvas.tsx:2439` (`tileLabel`)
- `web/src/components/studio/kv-generator/resizeBoardLayout.ts:138`
- `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx:3092` and `:3180`
- `web/src/components/studio/kv-generator/KvChat.tsx:2541`

The four client-derived surfaces are **ranked second, not deleted**:

**1. `PlatformRow`** (`KvResizePanel.tsx:332`) — new optional prop:

```tsx
label?: string;   // the server label, when a row exists
// :391  {label ?? p.label}
```

Threaded at both call sites as `ex?.platformLabel` (`:200-221` custom section,
`:309` preset section). The four `aria-label`s (`:407`, `:421`, `:435`, `:449`)
use it too, so screen readers hear the name. **`platformById` stays** — a
preset row with no export has no other label.

**2. Share page.** Add `platform_label` to `KvSharePayloadService.php:271` and
to `PublicKvResizeItem` (`web/src/services/query.ts:5650`). Delete the local
`platformLabel()` helper (`KvShareClient.tsx:24-26`); `:296` (alt) and `:304`
(caption) read `item.platform_label`. This is the only surface needing a server
change beyond the resource — and it **removes** a client mirror.

*Privacy:* `PublicKvController`'s docblock promises the payload exposes "image
URLs, board names, dimensions and aspect only — never workspace, user, thread
ids, or prompts." A tile name is user-authored display text of the same class
as a board name, so it is within that contract. It is nonetheless **newly
published text**: a name typed in a private editor now appears on a public
link. Intended, per decision 4; recorded so it is a choice and not a surprise.

**3. Comment breadcrumbs.** `tilePlatforms` already publishes
`rowId → platformId` (`KvResizeCanvas.tsx:502-514`). Change what it carries to
the server label; `kvCommentAdapter.ts:173-175` then uses the value directly.
The `?? rowId` fallback stays for the legacy pin shape.

**4. Chat markers — untouched** (decision 7). They keep deriving via
`platformById` (`KvChat.tsx:1301`, `:1361`), and markers already written keep
their frozen text. A marker is a record of what happened, not a mirror of now.

## 4. Edit affordance

Reuse the inline-rename pattern at `LayersPanel.tsx:125-229` (state +
`commitRename` `:125-129`, `onDoubleClick` `:202`, input swap `:216-229`).
Extract a small component beside `PlatformRow` — **not** promoted to
`@/components/frndos/` while it has one consumer.

- **Double-click the label** → `autoFocus` input, current name pre-filled;
  when unnamed, empty with the derived label as `placeholder` so the user sees
  what they would fall back to.
- **Enter** commits · **Escape** cancels · **blur** commits (LayersPanel's own
  choice — consistency beats cleverness).
- **Blank commit clears the name** and the derived label returns (§2).
- **Unchanged commit fires no request.**
- **Gated on `state === "done"`**, mirroring how `onDuplicate` gates
  (`KvResizePanel.tsx:219-222`). A pending tile has no result to name — the
  same reasoning that deferred rename in the first place.

**One entry point: the panel row.** Double-click is discoverable there because
the label is already a text line in a list. Deliberately **no** second entry
point on the canvas tile: the duplicate feature shipped two entry points and
the `source: "canvas" | "panel"` property that would have validated that choice
was never implemented, so there is no evidence two entry points earn their
cost. Add the canvas one when data says so.

**Cache update.** A rename is a row replace, so it copies `editRegion`'s shape
(`useResizeExports.ts:294-299`) — `setQueryData` mapping the row by id. Unlike
`editRegion` it applies **optimistically before the request, with rollback on
error**: a 422 for a duplicate name is an expected outcome, not an exception,
and the label must not flicker into the new name and back on a normal
rejection. On error the row reverts and a toast carries the server message via
`resizeErrorMessage`, the helper the duplicate failure path already uses
(`:281`).

## 5. Zip filenames

`KvResizeExportController.php:488-495`, per decision 8:

```
"Hero variant"   → hero-variant.png
unnamed custom   → 100x200-2.png                  (unchanged)
unnamed preset   → {platform_id}-{w}x{h}.png      (unchanged)
```

Slugify with the expression already used two lines below for the archive name
(`preg_replace('/[^A-Za-z0-9_-]+/', '-', ...)`, `:500`) — one rule, not a
second dialect. Two guards the current code does not need:

- A name that slugifies to empty (all-emoji, say) falls back to the
  platform-id form.
- **In-archive collisions** get a `-2` suffix: names are unique per
  `parent_generation_id`, but a zip spans the whole file, so two KVs can each
  legitimately hold a "Hero".

## 6. Analytics

Typed wrappers in `web/src/lib/analytics/kv-generator-events.ts` calling
`safeCapture`, following `trackKvResizeTileDuplicated` (`:430`). Success **and**
failure, per the handoff's rule for a mutation's funnel moments:

```
kv_generator.resize_tile_renamed         export_id, platform_id, name_length, cleared
kv_generator.resize_tile_rename_failed   export_id, error_reason, http_status
```

- `name_length` and `cleared`, **never the name itself** — user-authored text
  could carry client identifiers into analytics.
- `cleared: true` marks the blank-submit un-rename, which is how we learn
  whether people revert.
- No hand-passed `user_id`/`workspace_id`/`brand_id` — super properties attach
  those. No raw inline `posthog.capture`.

## 7. Testing

**API** — run with the scratch Postgres from the handoff. `phpunit.xml` pins
sqlite/`:memory:`, which the migrations' `DROP SEQUENCE` rejects:

```
DB_CONNECTION=pgsql DB_DATABASE=frnd_dup_tile_test TELESCOPE_ENABLED=false ./vendor/bin/pest <paths>
```

Pass explicit paths, never `--filter`. **Never** `DB_DATABASE=frnd` — that is
the live dev database and `RefreshDatabase` would wipe it.

- New `tests/Feature/Studio/KvResizeExportRenameTest.php`, modeled on
  `KvResizeExportDuplicateTest.php`: rename a custom tile; rename a **preset**
  tile; clear a name; 422 on a duplicate within a parent; **allowed** same name
  under a different parent; 403 cross-workspace; 404 wrong file; a
  soft-deleted row does not block a name; the 120-char boundary.
- `tests/Unit/Resources/KvResizeExportResourceTest.php` — add the
  `name ?? …` precedence case.
- Service test for the `(copy N)` search: base case; `(copy)` taken;
  duplicating a copy stays flat; unnamed source stays `null`; over-length
  truncation.

**Web** — always explicit file paths. `bun test` on a directory has consumed
tens of gigabytes here. Test files import from `"vitest"`; that is correct.

- `KvResizePanel.test.tsx` — server label wins when a row exists; `p.label`
  when it does not; aria-labels carry the name.
- Rename flow — Enter commits; Escape cancels; blank clears; unchanged fires
  nothing; 422 rolls the optimistic update back and toasts.
- `web/src/app/share/[token]/KvShareClient.test.tsx` — **must run alone**
  (`@tremor/react`'s bundled `@headlessui/react` patches
  `HTMLElement.prototype.focus` at import time). Assert the payload label
  renders, and check the reported test count matches what the file holds.

**Build:** `node ./node_modules/next/dist/bin/next build`. `bun run build` is
broken for unrelated reasons (it dies loading Next's compiled server runtime,
which Bun's own message calls a Bun bug).

**Types:** there is no type gate (`ignoreBuildErrors`) and `tsc` has an
~810-error baseline. Diff error sets by `file:line` against a baseline, never
by total. Known pre-existing and unrelated: `KvShareClient.tsx:228` and `:230`
(`TS2339`), `KvGeneratorLayout.tsx:6681` (`TS2322`). Also one pre-existing
failing test in `KvResizeResultRow.test.tsx`, which queries
`/reset overlays to project default/i` while the real aria-label is
`"Not following master — reset to follow"` — a stale expectation from an older
rename, not this work.

## 8. Runtime checklist — owed, not optional

Nothing in the duplicate feature has ever been clicked in a browser, and this
feature will start in the same state. Before calling rename done:

- [ ] Rename a custom tile from the panel; label updates on the tile, the
      canvas and the board layout
- [ ] Clear the name; the derived `100 × 200 (2)` returns
- [ ] Rename a **preset** tile
- [ ] Duplicate a named tile; the copy reads `… (copy)`
- [ ] Duplicate it again; the copy reads `… (copy 2)`
- [ ] Trigger the 422: two tiles, same name, same KV — toast shows, label
      reverts, no flicker
- [ ] Open a share link; the renamed tile shows its name
- [ ] Download the zip; the entry is `hero-variant.png`
- [ ] Confirm both PostHog events fire, success and failure

## 9. Estimate

**~1.5 days**, matching the handoff's figure for "with the share page" — but
redistributed. The edit affordance is cheaper than it assumed (the LayersPanel
pattern is reusable); three things it did not scope are now in: duplicate-name
validation, the `(copy N)` free-name search, and zip slugification with
in-archive collision handling.

## 10. Still owed to Daffa, not code

Carried forward from the duplicate session, plus this feature's share:

- Lark wiki taxonomy rows for `kv_generator.resize_tile_duplicated`,
  `kv_generator.resize_tile_duplicate_failed`,
  `kv_generator.resize_tile_renamed` and
  `kv_generator.resize_tile_rename_failed` — those exact strings.
- PostHog event descriptions, tags and `verified` after the first production
  fire.
- Consider a `source: "canvas" | "panel"` property on the duplicate events.
  Daffa chose two entry points over a one-entry-point recommendation; that
  property is the data that would confirm or refute it. Deliberately not
  implemented — and the reason rename ships with one entry point.
