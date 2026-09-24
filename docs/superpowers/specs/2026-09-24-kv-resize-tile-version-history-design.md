# KV — Resize tile version history

**Status:** draft for review · **Date:** 2026-09-24 · **Owner:** daffa · **Services:** api + web (no ai-service change)
**Branch:** `feature/daffa/vc-kv-craft-resize-strip` in both repos (Daffa, 2026-09-24) — web: the existing branch; api: a new branch of the same name cut from latest `develop`

## Problem

A resize tile's image is overwritten in place, with no way back:

- **Regenerate** sets `image_url = null` at request time, and the completion callback writes the new URL (`KvResizeExportService` ≈247-271, `markDone` ≈328). If the render fails or is cancelled, the tile is left **blank** and the previous image is gone from the product.
- **Region edit** keeps the old URL only until its callback overwrites it; the pre-edit URL survives only inside a chat marker (`KvResizeChatMarkerService`).
- **Separate layers onto a tile** (`KvLayerDecompositionService::commitToResizeExport` ≈343-356) replaces `image_url` with the flattened plate.

The old files still exist in S3 (every render is saved under a fresh uuid key, nothing deletes them); only the database stops pointing at them. Upscales are not version-aware either: after a regenerate the old upscale is still served as "done".

The spec "edits on a resized board become variants" (2026-09-24) protects a tile from its *board* changing; this spec protects a tile from *its own* edits.

## Decisions (Daffa, 2026-09-24)

1. **View + restore.** A tile's versions are listed (thumbnail, action, prompt, time); picking one previews it; "Restore this version" makes it the tile's image again by **appending** a new version (history is never rewritten), exactly like restoring a board generation.
2. **A version is the image only** (+ who/what/when). Restore never touches the tile's layers (`overlays`). Known consequence: restoring a version from before "Separate layers" can show text twice (baked in the image AND as a layer) — the user deletes the layer.
3. **UI:** the tile header's clock icon opens the existing **Version History panel**, scoped to that tile. "Reset to master" moves to `ArrowCounterClockwise`. Also in the tile's right-click menu.
4. **Failure keeps the last good image.** A failed or cancelled regenerate / region edit leaves the tile on its last successful version with the failed state + Retry on top. Failed renders are not versions. Cancel on a tile that already has a version stops the render instead of deleting the tile.

Rejected alternatives: a `versions` JSON column on the export row (every 2.5 s poll grows with history; concurrent callbacks race on one JSON write); rebuilding history from chat markers + S3 (regenerate markers carry no image URL); making tiles `kv_generations` (rejected before in the region-edit spec 2026-08-20 — touches the whole KV surface).

## Data (api)

### New table `kv_resize_export_versions`

| Column | Type | Notes |
|---|---|---|
| `id` | ulid PK | |
| `kv_resize_export_id` | ulid FK → `kv_resize_exports`, cascade on delete | a hard-deleted tile takes its history with it |
| `studio_file_id` | ulid FK → `studio_files`, cascade | workspace scoping in queries |
| `version_number` | unsigned int | 1-based per tile; unique `(kv_resize_export_id, version_number)` |
| `image_url` | string, not null | a version always has an image |
| `kind` | string(24) | `create` · `regenerate` · `region_edit` · `separate` · `restore` |
| `prompt` | text, nullable | regenerate: `additional_prompt`; region edit: the boxes' prompts joined with " · " |
| `model` | string, nullable | the export row's `model` at completion |
| `restored_from_version_id` | ulid, nullable, FK self | set only for `restore` |
| `created_by` | ulid FK → users, nullable, null on delete | |
| `created_at` | timestamp | rows are immutable: no `updated_at`, no soft delete |

### `kv_resize_exports` gains `current_version_id`

Nullable FK to `kv_resize_export_versions` (null on delete). `image_url` stays as the denormalized "current image" so every existing reader — strip, share page, motion, download, upscale — keeps working unchanged. Invariant: `current_version_id` non-null ⇒ `image_url` equals that version's `image_url`.

`KvResizeExportResource` adds `current_version_id` and `version_count` (count of versions; cheap `withCount`).

### Upscales become version-scoped

`kv_resize_export_upscales` gains `kv_resize_export_version_id` (nullable FK, cascade). The unique key moves from `(kv_resize_export_id, target)` to `(kv_resize_export_version_id, target)`. `getOrCreate` looks up by the tile's **current** version; a tile with no version (layer-composed) keeps today's behaviour. Existing upscale rows are backfilled to the tile's backfilled v1.

### Backfill migration

For every non-deleted export with `image_url` not null: insert version 1 (`kind = create`, `created_by` = row's `created_by`, `created_at` = row's `updated_at`, `model` = row's `model`) and set `current_version_id`. Tiles in flight or failed with a null image get no version (they get v1 when their render succeeds). History before this migration is not recoverable (the S3 files exist but nothing records which belonged to which render).

## Flows (api)

All version writes happen inside a DB transaction that locks the export row (`lockForUpdate`), so `version_number = max + 1` cannot collide under concurrent callbacks.

- **Append on success** — `markDone(row, imageUrl)` appends a version and moves `current_version_id` + `image_url` to it. `kind` is decided from the row:
  - `metadata.pending_region_edit` → `region_edit` (prompt from `metadata.pending_region_edit_prompt`, which `editRegion` now stores alongside the flag);
  - else the tile already has ≥1 version → `regenerate` (prompt = `additional_prompt`);
  - else → `create`.
- **Regenerate** no longer nulls `image_url`: it sets status pending, clears `error_message`, stores `additional_prompt`, and keeps the current image.
- **Failure** (`markFailed`, the stale-export watchdog) keeps `image_url` / `current_version_id` as they are.
- **Cancel** — new `POST /studio/files/{file}/resize-exports/{export}/cancel`:
  - tile with a current version → status `done`, `error_message` null, pending-region-edit keys cleared; image unchanged. A late callback is ignored because the internal callback only acts on pending/generating rows (`KvResizeExportInternalController` ≈32-34) — covered by a test.
  - tile with no version (first render) → hard delete, as the DELETE route does today.
  - DELETE stays "remove tile" and is unchanged.
- **Separate layers onto a tile** — `commitToResizeExport` appends a `separate` version for the flattened plate (plus its existing `overlays` write).
- **Restore** — `POST /studio/files/{file}/resize-exports/{export}/versions/{version}/restore`: 409 when the tile is pending/generating; 404 when the version is not this tile's; otherwise append `kind = restore` with the source's `image_url`, `restored_from_version_id` = source, and make it current. Free (no credits, no AI call).
- **List** — `GET /studio/files/{file}/resize-exports/{export}/versions` → newest first, `{id, version_number, image_url, kind, prompt, model, restored_from_version_number, created_by_name, created_at}`. Not paginated (tiles have tens of versions at most); capped at 100 newest.
- Authorization: the same workspace check the other resize-export routes use.
- Credits: unchanged — charged on the completion callback as today; restore and cancel are free.

## Web

### Types and data

- `KvResizeExport` gains `currentVersionId: string | null` and `versionCount: number`.
- `KvResizeExportVersion` type + `useResizeExportVersions(fileId, exportId, enabled)` (react-query key `["kv-resize-export-versions", fileId, exportId]`), refetched whenever the row's `currentVersionId` changes (the existing 2.5 s poll / SSE already brings the row).
- `useResizeExports` gains `restoreVersion(exportId, versionId)` and `cancel` switches to the new cancel endpoint (`remove` keeps DELETE).

### Tile rendering

- `computeResizeStrip` draws `imageUrl` whenever it is present, not only when `status === "done"`; the status layer dims the image while rendering and shows the failed chip + Retry on a failed tile that still has an image. `blank` stays "done with no image" (layer-composed).
- A preview override: while the history panel previews version *v* of tile *t*, the strip draws *v*'s image on *t* only (no other tile or board changes); closing the panel or restoring clears it.

### Header, menu, panel

- Tile header: `ClockCounterClockwise` = **"Version history"**, shown on every tile with an image (hidden on layer-composed tiles); **"Reset to master"** = `ArrowCounterClockwise`, shown only on detached tiles (today's condition).
- Tile context menu: **"Version history"** item.
- `KvVersionHistoryPanel` becomes generic: `items: { id; thumbnailUrl; title; detail?: string; time; isCurrent }[]`, plus `title`, `emptyText`, `restoreDisabledReason?`. Board history maps generations to items (visual behaviour unchanged); tile history maps versions:
  - title "Version N"; detail = action label ("Created", "Regenerated", "Region edit", "Separated layers", "Restored from vN") + prompt when present;
  - header "Version History · {tile label}".
- One panel at a time: layout state `versionHistoryTarget: { kind: "board" } | { kind: "tile"; exportId } | null` replaces the boolean. Opening a tile's history closes the board's and vice versa; everything that reads `versionHistoryOpen` reads `versionHistoryTarget !== null`.
- Restore disabled while the tile renders, with the reason shown under the button.

### Analytics

- `kv_generator.resize_tile_versions_opened` — `{ export_id, version_count, source: "header" | "menu" }`.
- `kv_generator.resize_tile_version_restored` — `{ export_id, from_version_number, new_version_number, restored_kind }`.
- Taxonomy rows added with the other strip events.

## Invariants

- A tile's image is never lost by an edit: success appends, failure/cancel keep the last version.
- Versions are immutable; restore appends.
- `image_url` on the export row always equals the current version's image when one exists.
- Restore never changes `overlays`, name, crop window or ready-to-share marks.
- An upscale is always of the tile's current image.
- Layer-composed tiles (no image) have no versions and no history icon.

## Testing

- **api (Pest, Feature, scratch Postgres — see lesson on api Feature tests):** callback appends v1 `create` / v2 `regenerate` / region edit with prompt; regenerate request keeps `image_url`; failure keeps image + version; cancel on versioned tile → done + image kept, and a late callback after cancel is ignored; cancel on first render deletes; restore appends `restore` with `restored_from_version_id` and moves current; restore 409 while pending, 404 for another tile's version; list order + fields; separate-layers commit appends `separate`; upscale after regenerate creates a new upscale row (old one not returned); backfill migration creates v1 only for tiles with an image; concurrent version numbers stay unique (two appends in sequence under the lock).
- **web (bun test, pure):** version → panel item mapping (labels, "Restored from vN", prompt detail, current flag); `computeResizeStrip` draws the image for pending/failed rows and applies the preview override to one tile only; `versionHistoryTarget` open/close rules as a pure reducer. No RTL/component tests for canvas (track policy).
- **Manual (Daffa):** regenerate a tile twice → history shows v1–v3 with prompts; preview v1 on the tile; restore → v4 "Restored from v1", tile image is v1's; regenerate then cancel → tile keeps its image; force a failure → image stays with Retry; upscale after a regenerate → new upscale of the new image; board Version History still works and closes when a tile's opens.

## Out of scope

- Deleting individual versions; comparing versions side by side; downloading an old version without restoring (decided: view + restore only).
- Versioning tile layers (`overlays`) — they keep their client-side undo.
- Recovering pre-feature history from chat markers.
