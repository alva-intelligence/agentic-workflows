# KV Resize — Duplicate a custom-size tile — Design Spec

> **Status:** draft
> **Author:** daffa
> **Created:** 2026-09-02
> **Services:** api, web
> **Topic slug:** kv-resize-duplicate-tile

## Overview

Let a user take an existing **custom-size** resize tile and duplicate it, so
two tiles of the same dimensions can live side by side and be edited
independently.

The duplicate is seeded from the source tile's overlay snapshot and crop
window, so it starts as an exact copy of what the user is looking at and
diverges only when they move something. That is the point: it is a variant
of a layout the user already likes, not a second attempt at the same size.

## The reported problem, and why the obvious fix is the wrong one

Reported as: "after creating a custom size 100×200, I can't create 100×200
again."

That is true, and it is enforced at three layers:

1. **web** — `KvResizePanel` passes
   `isAlreadyAdded = selectedIds.has(id) || exportsByPlatformId.get(id)`, so
   `KvCustomSizeRow` answers "100 × 200 is already added."
2. **api** — `KvResizeExportService::createBatch` uses `firstOrCreate` on
   `(parent_generation_id, platform_id)` and returns the existing row.
3. **DB** — `kv_resize_exports_parent_platform_unique` on
   `(parent_generation_id, platform_id)`.

Underneath all three is one design decision: **`platform_id` is derived from
the dimensions** (`custom-{w}x{h}`), so a tile's identity *is* its size.

The obvious fix — relax the guard so the form accepts a duplicate size —
produces something almost useless. Custom sizes are only permitted on
layer-composed parents, and for those the resize is deterministic: the row is
created already `done`, with **no job, no model call, and no credit**
(`KvResizeExportService`), because the tile is projected from layers. Two
tiles added that way are **byte-identical**. There is no seed, no
temperature, nothing to vary. `additional_prompt` is stored but never read on
this path, so it cannot differentiate them either.

So "add the same size again" only makes sense as "give me a clean canvas at
that size", which is not what was being asked for. What was being asked for —
compare variants — is a **duplicate**: copy this tile, then change it.

Duplicate is also the cheaper and tidier feature. Nothing is retyped, the
custom-size form is untouched (its "already added" message stays correct,
because that form is for adding *sizes*), and the api work is one `create`
with two columns copied.

## Non-goals

- **Duplicating preset tiles.** A preset id is validated with
  `in:{registryIds}` and then looked up in the registry; `instagram-post-2`
  fails at both. Generalising means a second identity scheme. Out of scope.
- **Renaming tiles.** The right shape for naming is rename-after-the-fact,
  not a name field at creation time — the user has not seen the result yet
  when they click. Deferred, and cheap to add later: label is synthesised at
  exactly one site per side, so it becomes `name ?? derived` with no
  migration pain.
- **Relaxing the custom-size form's duplicate guard.** It stays.
- **Anything on the AI-generated (non-layer-composed) resize path.**
- **A cap on duplicates per size.** No credit cost, no model call, trivial to
  delete. An arbitrary limit is a rule users hit without understanding.

## Identity and label

The id grammar gains an optional ordinal: `custom-{w}x{h}[-{n}]`, `n >= 2`.

Backward compatible by construction — every existing `custom-100x200` row
still parses, and the **first** tile of a size never carries a suffix.

| Tile | Ordinal | `platform_id` | Label |
|---|---|---|---|
| first | — | `custom-100x200` | `100 × 200` |
| second | 2 | `custom-100x200-2` | `100 × 200 (2)` |
| third | 3 | `custom-100x200-3` | `100 × 200 (3)` |

Both sides keep deriving the id from one shared formula, now taking three
arguments rather than two — there is no new source of truth, the derivation
is just made total:

- web: `customSizeId(width, height, ordinal?)` in `lib/studio/kv/customSize.ts`
- api: `CustomResizeSize::id(int $w, int $h, ?int $ordinal = null)`

`parse()` returns `{width, height, ordinal}`, with `ordinal` defaulting to
`1` for the bare form.

### The regex detail that must not be got wrong

**`-1` must be rejected.** If `custom-100x200-1` parsed, it and
`custom-100x200` would both denote the first tile — two ids meaning one
thing, which is precisely the property `CustomResizeSize`'s docblock claims
to protect ("an id can never mean two things"). Rejecting it also keeps
`id(w, h, 1)` from ever emitting a second spelling of the canonical form.

The ordinal group is therefore `(?:[2-9]|[1-9]\d+)` — **not** `[2-9]\d*`,
which would wrongly reject `-10`.

```
web: /^custom-([1-9]\d*)x([1-9]\d*)(?:-([2-9]|[1-9]\d+))?$/
api: '/^custom-([1-9]\d*)x([1-9]\d*)(?:-([2-9]|[1-9]\d+))?\z/'
```

Anchored, and leading zeros stay rejected on every group.

### Label synthesis

One site per side, as today:

- web `platformById()` in `lib/studio/kv/resizePlatforms.ts`
- api `CustomResizeSize::label()` / `labelFor()`

`n == 1` renders `100 × 200`. The overwhelmingly common case is one tile per
size, and burdening it with a meaningless `(1)` is worse than the asymmetry.

## Ordinal allocation — server side

The server allocates. This reverses an earlier decision made under the
"relax the Add form" framing, where the client had to allocate because the id
must stay stable from Add-time until the user later clicks Resize (the
`crop_windows` map is keyed by it). **Duplicate has no such gap** — one click
is one request and the row exists immediately, so there is no provisional id
parked in the panel and no crop window to remap. Server allocation is then
strictly better: no cross-tab race at all.

Algorithm (deliberately **not** wrapped in a transaction — in PostgreSQL a
unique violation aborts the enclosing transaction, which would poison the retry
below; a single insert needs no atomicity beyond its own):

1. Load `platform_id` for live rows matching `parent_generation_id` **and**
   the source's `width` and `height`. Those are real columns, so this needs
   no `LIKE` over strings, and a preset that happens to share the dimensions
   is discarded by `parse()` returning null.
2. Take the highest ordinal (bare form counts as 1); the new one is
   `max + 1`.
3. Insert. The unique index stays the final arbiter: on a unique violation
   (two clicks in flight), recompute and retry, bounded to 3 attempts.

Two properties worth stating because they are load-bearing:

- **Existing tiles are never renumbered.** A visible number never changes
  meaning under the user. Reusing a number freed by a deletion is fine — at
  any instant the visible numbers are unique and stable.
- **This is only safe because DELETE is a hard delete.**
  `KvResizeExportController` calls `forceDelete()`. Under soft deletes,
  `max + 1` would collide with a tombstoned row through the unique index, and
  the allocator would need to consider deleted rows too.

## api surface

```
POST v1/studio/files/{file}/resize-exports/{export}/duplicate  ->  201
```

Returns a `KvResizeExportResource`.

Guards, in order:

| Condition | Response |
|---|---|
| file not in caller's workspace | 404 in practice — see below |
| export does not belong to this file | 404 |
| source `platform_id` is not a custom id | 422 (presets are out of scope) |
| parent is not `isLayerComposed()` | 422 (defence in depth, mirrors `createBatch`) |

The first row wants to be a 403, and the controller does carry
`abort_unless($file->workspace_id === …, 403)` to match its siblings. But
`StudioFile` has a `HasWorkspaceScope` global scope, so a file outside the
caller's workspace is already invisible to `findOrFail` and the request 404s
before that line is reached. The neighbouring `KvResizeExportControllerTest`
documents the same 404 for the same scenario. The security property is intact
either way, and 404 is the better answer — it does not confirm the file
exists. The `403` guard stays as defence in depth for the paths where the
scope does not apply.

The fourth guard is **implied by the third today** — a custom id can only
have been created on a layer-composed parent, and a generation's
layer-composed status never changes afterwards. It is kept anyway, for the
reason `createBatch` already documents about itself: the service is a
reusable seam, and a custom size reaching an AI-generated parent would
dispatch an outpaint job at an arbitrary size and bill credits for something
the layer path gives away free. Cheap assertion, expensive failure.

The new row:

- `status: done`, `image_url: null` — pixels are assembled on demand, exactly
  as `createBatch` does for a layer-composed parent.
- **copied:** `overlays`, `crop_window`, `additional_prompt`. The prompt is
  inert on this path (nothing reads it without a model call), but it is part
  of the source row's user-visible state, and skipping it would be an
  asymmetry with no reason behind it.
- **not copied:** `metadata`. It holds caches and markers bound to one
  render's lifecycle; carrying over a pending region-edit marker is the very
  bug the comment in `regenerate()` warns about ("THIS render's completion
  would post a 'region edit applied' marker for an edit it just threw away").
  Starting empty is the safe default.

Logic lives in `KvResizeExportService::duplicate(KvResizeExport $source)`,
alongside `createBatch` and `regenerate`.

**No chat marker is written.** `store` and `regenerate` write one because
both are generation events. A duplicate is not: no model call, no credit,
no new pixels. Adding one means a new marker kind plus rendering in `KvChat`,
which the value here does not pay for.

## web surface

`duplicateResizeExport(fileId, exportId)` in `services/kv/api.ts`, followed by
a refetch of the exports list. The SSE stream at `resize-exports/stream` will
also announce the row, but the refetch avoids waiting on it.

No write to `selectedIds` is needed. `customSizeIds()` folds in
`exportsByPlatformId` ungated by `eligible`, so the new tile appears as a
panel row as soon as its export exists.

Two entry points, following the precedent that Cancel already lives on both
surfaces:

- **Canvas** — a Copy icon button in the `KvResizeResultRow` action cluster,
  beside Regenerate / Download / reset-to-follow-master. This is the primary
  one: the user is looking at the tile they want to copy.
- **Panel** — a hover icon beside the existing `X` on `PlatformRow`, for
  **custom rows in state `done` only**. `onDuplicate?` threads down from
  `KvResizePanel`; preset rows must never receive it.

After a successful duplicate, scroll the canvas to the new tile via the
existing `onScrollToPlatform` seam. Without it the only feedback is a row
appearing somewhere off-screen, which for an operation whose result is
initially identical to its source reads as "nothing happened".

Two PostHog events ship with the feature, per the convention that a mutation's
funnel moments come in success and failure:
`kv_generator.resize_tile_duplicated` and
`kv_generator.resize_tile_duplicate_failed`. Those exact strings are the ones to
use in the taxonomy doc — the `kv_generator.` prefix matches every sibling event
in the module.

### Targeted fixes in code this work touches

- `CustomResizeSize`'s docblock states that the unique index "supplies dedup
  for free". Dedup-by-size is exactly what this change ends, so the comment
  becomes actively misleading and must be rewritten.
- `KvShareClient` inspects ids with `startsWith("custom-")` and labels every
  custom tile `"Custom"`. Suffix-safe, but two duplicates would read
  identically on a share page. Switch it to the shared parser so it renders
  `100 × 200 (2)`.
- ZIP entry names are `{platform_id}-{w}x{h}.png`, already redundant for
  custom ids (`custom-100x200-100x200.png`) and worse with a suffix
  (`custom-100x200-2-100x200.png`). **For custom ids only**, name them
  `{w}x{h}[-{n}].png` → `100x200-2.png`. Preset entries are untouched, so no
  existing preset filename changes.

## Testing

**api**

- Unit, `CustomResizeSize`: `-1`, `-0`, `-01` rejected; `-10` accepted;
  `id()`/`parse()` round-trip across ordinals; `label()`/`labelFor()`.
- Feature, the endpoint: ordinal allocation including the case where a
  middle number was deleted; all four guards; `overlays` and `crop_window`
  copied while `metadata` is not; the duplicate is `done` with a null
  `image_url` and dispatches no job.
- Feature tests need a scratch Postgres — SQLite cannot run this repo's
  migrations (`DROP SEQUENCE`). Pass test paths rather than `--filter`.

**web**

- `customSize.test.ts` for the extended grammar, mirroring the api unit cases.
- Panel: the Duplicate icon appears on a custom row in state `done`, and
  never on a preset row.
- Label rendering with an ordinal.
- Run per file with `bun test`, not per directory.

## Risks

- **The grammar change is the only cross-cutting risk**, and it is contained:
  each side has exactly one parser, and the sole other id reader
  (`KvShareClient`) never parses dimensions.
- Duplicating a tile that is still following master yields two tiles that
  both follow master and are identical until one is edited. That is correct
  behaviour, not a bug, but it is why the scroll-to-new-tile step above is
  part of the feature rather than a nicety: the result looks like its source.
