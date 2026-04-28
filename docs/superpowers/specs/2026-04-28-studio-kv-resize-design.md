---
title: KV Generator — Resize Mode
slug: studio-kv-resize
author: daffa
created: 2026-04-28
status: draft
services: [web, api, ai-service]
parent: studio-projects-kv-generator
figma:
  resized: https://www.figma.com/design/2C03HNjvUiOAZvEbP2fnr9/Studio?node-id=5326-3659
---

## Overview

Wire up the third canvas tab (`Resize`) in the KV Generator as a **batch multi-aspect-ratio export** tool. The user picks one or more channels (Instagram Post, TikTok Video, Facebook Cover, A4 Portrait, etc.) from a left-rail platform picker, hits the bottom CTA, and gets one render per platform stacked on the canvas. Outputs are **exports** of the latest generation, not new entries on the version timeline. Resize is a silent batch job — no chat involvement.

Resize uses an **outpaint** pipeline (transparent-padded canvas + mask) so brand elements, copy, and subjects from the source remain pixel-identical in every export. Only the new framing area is generated. Default model is **FLUX Fill Pro** (`black-forest-labs/flux-fill-pro` via Replicate); fallback is OpenAI `gpt-image-1` with mask, reusing the inpaint plumbing already proven by KV bounding-box edits.

This is an in-implementation extension of `studio-projects-kv-generator`. No new feature branch — work continues on `feature/daffa/vc-studio-projects-kv-generator`.

## Why

The Resize tab is dead UI today (`KvCanvasTopNav` already renders `Sketch | Craft | Resize`). After a brand-aligned KV is generated and polished, users still have to manually re-prompt to get IG-ready, TikTok-ready, and print-ready variants. That re-prompting drifts the design — the same KV ends up looking different on every channel. Resize fixes this by holding the source pixel-identical and only inventing the new framing area.

The `Resized` Figma frame (`5326:3659`) shows the activation surface: left rail with grouped Platform checkboxes (Social Media expanded, Print collapsed), bottom CTA, vertically stacked results on the canvas (`Original • 800 × 472 px` on top, then `Facebook Cover • 820 × 360 px`, then `TikTok Video • 1080 × 1920 px`).

User intent for Resize is "give me deliverables for these channels — don't change the design." A constrained outpaint pipeline matches that intent literally.

## User flow

1. User has at least one Sketch- or Craft-generated KV on the canvas.
2. User clicks **Resize** in the TopNav segmented control.
3. The left rail (Layers panel) is replaced by `KvResizePanel`. Source is the **latest** generation (no source picker in v1). Canvas swaps to `KvResizeCanvas` — the latest image renders on top labeled `Original • {w} × {h} px` with a Download icon. No skeletons yet.
4. The Platform picker shows two collapsible groups: `Social Media` (expanded) and `Print` (collapsed). Each row is a checkbox + label + dimensions subtitle. Bottom CTA shows `Resize · 0 selected` (disabled).
5. User checks N platforms. CTA enables and updates: `Resize · N selected`.
6. User clicks the CTA. The web posts `POST /api/studio/files/{file}/resize-exports` with `parent_generation_id` and `platform_ids: [...]`. API returns 202 + N rows in `pending`. Web optimistically inserts N skeleton rows below `Original` on the canvas, each labeled with platform name + target dimensions.
7. Each pending row gets dispatched to a job, which calls the AI service. Status flows `pending → generating → done | failed` and is delivered to the web over SSE.
8. As each export completes, its skeleton swaps to the rendered image. Each non-Original row has two icon buttons: **Download** + **Adjust crop & regenerate**.
9. Clicking Adjust crop opens `KvResizeCropModal` with a draggable crop rectangle (locked to the platform's target ratio) over the source image. Saving regenerates that row in place (UPSERT on `(parent_generation_id, platform_id)`).
10. Switching `canvasMode` back to Sketch returns to the normal canvas. Exports persist (visible only when Resize tab is active for the current source).

If no generation exists when the user enters Resize, `KvResizePanel` shows the disabled empty state (`Generate a KV first to enable Resize`) and the CTA stays disabled.

## Layout — Resized state (`5326:3659`)

```
┌─ TopNav (88px) ────────────────────────────────────────────┐
│  [Untitled / project subtitle]   ● Brand                   │
│            [ Sketch | Craft | ▣ Resize ]    [↓ Download]   │
├──────────────────────┬─────────────────────────────────────┤
│  KvResizePanel       │ Canvas (vertical scroll)            │
│  (left rail, 232w)   │ ┌────────────────────────────────┐  │
│                      │ │ Original • 800 × 472 px   [↓] │  │
│  Platform            │ │ ┌────────────────────────────┐ │  │
│  ▾ Social Media      │ │ │   <source image>           │ │  │
│  [✓] IG Post         │ │ └────────────────────────────┘ │  │
│      1080×1080       │ └────────────────────────────────┘  │
│  [✓] IG Story/Reel   │ ┌────────────────────────────────┐  │
│      1080×1920       │ │ Facebook Cover • 820×360  [↓][⤶]│ │
│  [ ] IG Landscape    │ │ ┌────────────────────────────┐ │  │
│      1080×566        │ │ │   <outpainted image>       │ │  │
│  [✓] FB Post         │ │ └────────────────────────────┘ │  │
│      1200×630        │ └────────────────────────────────┘  │
│  [✓] FB Cover        │ ┌────────────────────────────────┐  │
│      820×360         │ │ TikTok Video • 1080×1920  [↓][⤶]│ │
│  [✓] TikTok Video    │ │ ┌──────────┐                   │ │
│      1080×1920       │ │ │ <vert>   │                   │ │
│  ...                 │ │ └──────────┘                   │ │
│  ▸ Print             │ └────────────────────────────────┘  │
│                      │                                     │
│  [   Resize · N   ]  │                                     │
└──────────────────────┴─────────────────────────────────────┘
BottomNav — chat toggle pill only (tools hidden in Resize)
```

`[↓]` = Download. `[⤶]` = Adjust crop & regenerate. Original shows only `[↓]`. Floating chat panel (per `studio-kv-canvas-reclaim`) stays anchored bottom-right, unchanged.

## Image-gen pipeline

For every selected platform, the AI service runs:

1. **Download source** — fetch the latest generation's `image_url` to a temp dir.
2. **Crop the source** — if the user didn't supply `crop_window`, run **auto center-crop** so the source fits inside the target on both axes while preserving as much area as possible. Concretely:
   - If source aspect ≥ target aspect: scale source so its **height** equals target height; crop horizontally to target width.
   - If source aspect < target aspect: scale source so its **width** equals target width; crop vertically to target height.
   - The cropped piece is the largest rectangle of the source that fits the target ratio.
   - For ratios where the source covers the full target on both axes, no outpaint is needed — return the cropped source directly (skip steps 3–5).
3. **Pad to target** — paste the cropped source onto a transparent RGBA canvas at target dimensions, centered. Compute the paste rectangle.
4. **Build mask** — same dimensions as the target. White (255) over transparent regions (paint here); black (0) over the pasted source (preserve).
5. **Outpaint** — call FLUX Fill Pro via Replicate with `{ image: padded_canvas, mask, prompt: OUTPAINT_GUIDANCE }`. On 5xx / rate-limit, retry per existing `replicate_run` semantics; if still failing, fall back to OpenAI `/v1/images/edits` with the same `image` + `mask` and the canned prompt.
6. **Upload** — write the result PNG to S3 via existing `save_bytes_to_file` helper.
7. **Callback** — `POST /api/internal/kv-resize-exports/completed` with `{ export_id, image_url, status: 'done' }` (or `'failed'` + `error_message`). API marks the row, persists `image_url`, fans out the SSE update.

**Outpaint prompt (canned, no user prompt in v1):**
> "Naturally extend the scene to fill the new frame. Preserve all original pixels exactly — do NOT redraw subjects, brand elements, copy, or text. Only paint into the masked region; the unmasked region must remain byte-identical to the source. Match lighting, depth, perspective, and color of the source at the seam. No new subjects or focal elements."

**When source ≤ target on both axes** (e.g., source 1080×1080, target 1080×1920), no crop is needed — just pad + outpaint.

**When source > target on both axes** (e.g., source 1920×1080, target 820×360), no outpaint is needed — auto center-crop yields the full target. The row goes straight to `done` with the cropped source uploaded to S3 (no model call).

## Platform registry

Defined as a single source of truth in `api/config/studio.php` and mirrored to the web (TS) and AI service (Python). Mirroring is a one-time copy at build/deploy; runtime fetch is unnecessary for v1 (the registry is small and stable).

```
social-media:
  instagram-post       1080 × 1080  (1:1)
  instagram-story      1080 × 1920  (9:16)
  instagram-landscape  1080 × 566   (1.91:1)
  facebook-post        1200 × 630
  facebook-cover       820  × 360
  tiktok-video         1080 × 1920  (9:16)
  youtube-thumbnail    1280 × 720   (16:9)
  linkedin-post        1200 × 627
  twitter-post         1200 × 675

print:
  a4-portrait          1240 × 1754  (half-DPI preview)
  a4-landscape         1754 × 1240  (half-DPI preview)
  square-poster        1200 × 1200
```

Print rows render with a small "Preview quality" tooltip — full-DPI export is v2.

## Data model

### New table: `kv_resize_exports`

```
kv_resize_exports
  id                    ulid pk
  studio_file_id        foreignUlid -> studio_files (cascadeOnDelete)
  parent_generation_id  foreignUlid -> kv_generations (cascadeOnDelete)
  created_by            foreignUlid -> users (cascadeOnDelete)
  platform_id           string(64)        -- 'instagram-post' | 'tiktok-video' | ...
  width                 unsignedInteger
  height                unsignedInteger
  image_url             string nullable   -- null until status='done'
  status                string(16) default 'pending'    -- pending|generating|done|failed
  crop_window           jsonb nullable    -- {x,y,w,h} on source; null = auto center-crop
  error_message         text nullable
  created_at, updated_at
  deleted_at            -- softDeletes()

  UNIQUE (parent_generation_id, platform_id) name=kv_resize_exports_parent_platform_unique
  INDEX  (studio_file_id, parent_generation_id, created_at) name=kv_resize_exports_file_parent_idx
```

**Soft-delete nuance:** `softDeletes()` protects against direct user-initiated removal of an export ("Remove this export" gesture, future). It does *not* protect against cascade — when a `kv_generations` row is hard-deleted, its exports cascade-deleted (hard). This is intentional — exports are valid only against a specific source.

**Migration file:** `api/database/migrations/2026_04_28_120000_create_kv_resize_exports_table.php`. No change to `kv_generations` (the `mode='resize'` enum value added by Craft stays unused — Resize lives in its own table).

### Relations

```
studio_projects 1───N studio_files 1───N kv_generations 1───N kv_resize_exports
                                       │                    │
                                       └─ self FK           └─ N→1 studio_files
                                          parent_generation    (denormalized for query speed)
```

Cascade summary:

| From | To | On delete |
|---|---|---|
| `studio_files` | `kv_resize_exports` | cascade (hard) |
| `kv_generations` | `kv_resize_exports` | cascade (hard, bypasses soft delete) |
| `users` | `kv_resize_exports.created_by` | cascade |

### `KvResizeExportResource` shape

```ts
{
  id: string;
  studio_file_id: string;
  parent_generation_id: string;
  platform_id: string;          // 'instagram-post'
  platform_label: string;       // 'Instagram Post' (joined from registry)
  platform_group: string;       // 'social-media' | 'print'
  width: number;
  height: number;
  image_url: string | null;
  status: 'pending' | 'generating' | 'done' | 'failed';
  crop_window: { x: number; y: number; w: number; h: number } | null;
  error_message: string | null;
  created_at: string;
  updated_at: string;
}
```

## API contract

### Public endpoints (under `/api/studio/files/{file}`)

| Method | Path | Body | Returns |
|---|---|---|---|
| GET    | `/resize-exports` | — | `KvResizeExportResource[]` for the latest generation of `{file}` |
| POST   | `/resize-exports` | `{ parent_generation_id, platform_ids: [], crop_windows?: { [platform_id]: {x,y,w,h} } }` | 202 + `KvResizeExportResource[]` newly created (or returned if already existed) |
| POST   | `/resize-exports/{export}/regenerate` | `{ crop_window?: {x,y,w,h} }` | 202 + the updated `KvResizeExportResource` (status reset to `pending`) |
| DELETE | `/resize-exports/{export}` | — | 204; soft-deletes the row |
| GET    | `/resize-exports/stream` | — | SSE; emits `export.updated` events with the row resource. Closes when no `pending`/`generating` rows remain. |

**Validation** on POST:
- `parent_generation_id` must belong to `studio_file_id` and be the latest generation. (If a newer generation exists, the request is rejected with 409 — the client should re-fetch.)
- `platform_ids[]` must be non-empty and every id must exist in the registry.
- Existing `(parent_generation_id, platform_id)` rows are returned as-is (idempotent), not duplicated.

**Auth:** standard sanctum + workspace membership check via `studio_files`.

### Internal endpoint

| Method | Path | Body | Returns |
|---|---|---|---|
| POST | `/api/internal/kv-resize-exports/completed` | `{ export_id, status: 'done'|'failed', image_url?, error_message? }` | 200 |

Called by the AI service when an outpaint job finishes. API persists `image_url` + `status`, fans out `export.updated` over the SSE channel.

## API service

### Files touched

```
api/database/migrations/
  2026_04_28_120000_create_kv_resize_exports_table.php                          NEW

api/app/Models/
  KvResizeExport.php                                                            NEW
    - softDeletes, ulid PK, fillable, $casts (crop_window json)
    - belongsTo: studioFile, parentGeneration, creator

api/app/Http/Resources/Studio/
  KvResizeExportResource.php                                                    NEW
    - shape per §Data model

api/app/Http/Controllers/Api/Studio/
  KvResizeExportController.php                                                  NEW
    - index / store / regenerate / destroy / stream

api/app/Http/Controllers/Api/Internal/
  KvResizeExportInternalController.php                                          NEW
    - completed()

api/routes/api.php                                                              MODIFIED
  + Route::prefix('studio/files/{file}')->group(...) — 5 routes
  + Route::prefix('internal')->group(...) — 1 route

api/app/Services/Studio/
  KvResizeExportService.php                                                     NEW
    - createBatch(StudioFile, parentGen, platformIds[], cropWindowMap?)
    - regenerate(KvResizeExport, cropWindow?)
    - markGenerating / markDone / markFailed
    - dispatchToAi(KvResizeExport)

api/app/Jobs/Studio/
  ProcessKvResizeExportJob.php                                                  NEW
    - handle(): POST AI service /ai/kv-resize/export

api/config/
  studio.php                                                                    MODIFIED
    + 'resize_platforms' => [ ...registry... ]
```

### Tests

```
api/tests/Feature/Studio/
  KvResizeExportControllerTest.php                                              NEW
  KvResizeExportInternalCallbackTest.php                                        NEW

api/tests/Unit/Services/Studio/
  KvResizeExportServiceTest.php                                                 NEW
```

## AI service

### Files touched

```
ai-service/app/agents/kv_resize/                                                NEW (whole dir)
  __init__.py                                                                   NEW
  router.py                                                                     NEW    POST /ai/kv-resize/export
  service.py                                                                    NEW    orchestrate: download -> crop -> pad+mask -> outpaint -> upload -> callback
  canvas.py                                                                     NEW    PIL helpers: smart_crop, pad_to_target, build_mask
  request_schema.py                                                             NEW    ResizeExportRequest, CropWindow
  response_schema.py                                                            NEW    ResizeExportResponse
  api_client.py                                                                 NEW    POST internal callback
  prompts/
    outpaint.py                                                                 NEW    OUTPAINT_GUIDANCE constant

ai-service/app/tools/
  outpaint_image.py                                                             NEW
    - outpaint_with_flux_fill(source_path, mask_path, prompt) -> bytes
    - outpaint_with_openai_mask(source_path, mask_path, prompt) -> bytes        (fallback)

ai-service/main.py                                                              MODIFIED
  + include_router(kv_resize.router)
```

The existing `edit_image.py` `black-forest-labs` branch passes `prompt + input_image` (Kontext-style edit) — it does NOT pass `mask`. FLUX Fill Pro requires `image + mask`. Hence the new `outpaint_image.py` helper rather than reusing the existing branch — keeps semantics clean.

### Request / response

```
POST /ai/kv-resize/export
{
  export_id: str,                    # ULID, used for callback
  source_image_url: str,
  target_width: int,
  target_height: int,
  crop_window: { x, y, w, h } | null # null = auto center-crop
}
202 Accepted (job dispatched async; result delivered via callback)
```

### Tests

```
ai-service/tests/agents/kv_resize/
  test_canvas.py                                                                NEW    smart_crop, pad_to_target, build_mask
  test_service.py                                                               NEW    happy path + fallback path
  test_router.py                                                                NEW
```

## Web

### Files touched

```
web/src/types/kv/
  resize.ts                                                                     NEW
    - PlatformId, PlatformGroup, Platform
    - PLATFORMS: readonly Platform[] (mirror of api/config/studio.php)
    - CropWindow, KvResizeExport types

web/src/services/kv/
  api.ts                                                                        MODIFIED
    + listResizeExports, createResizeExports, regenerateResizeExport, deleteResizeExport
  resize-stream.ts                                                              NEW
    + connectResizeStream(fileId): EventSource client with reconnect

web/src/store/kv/
  useKvResizeStore.ts                                                           NEW
    - selectedPlatformIds: Set<PlatformId>
    - exportsByPlatformId: Map<PlatformId, KvResizeExport>
    - applyServerEvent(export): merges by id

web/src/components/studio/kv-generator/
  KvResizePanel.tsx                                                             NEW    left-rail platform picker
  KvResizeCanvas.tsx                                                            NEW    vertically stacked Original + result rows
  KvResizeOriginalRow.tsx                                                       NEW    title · dims · source img · [Download]
  KvResizeResultRow.tsx                                                         NEW    title · dims · skeleton/img · [Download][Adjust crop]
  KvResizeCropModal.tsx                                                         NEW    draggable crop rectangle, ratio-locked
  KvResizeEmptyState.tsx                                                        NEW    "Generate a KV first to enable Resize"

  KvGeneratorLayout.tsx                                                         MODIFIED
    + branch on canvasMode==='resize' to render KvResizePanel + KvResizeCanvas
  KvCanvasBottomNav.tsx                                                         MODIFIED
    + hide tools cluster when canvasMode==='resize' (mirror of Craft)

web/src/lib/studio/kv/
  useResizeExports.ts                                                           NEW    list query + mutations + SSE wiring
  resizePlatforms.ts                                                            NEW    re-export PLATFORMS grouped helpers
  cropMath.ts                                                                   NEW
    + centerCropWindow(srcW, srcH, targetW, targetH): CropWindow
    + fitInsideTarget(srcW, srcH, targetW, targetH): { paste, pad }
```

### Tests

```
web/src/components/studio/kv-generator/
  KvResizePanel.test.tsx                                                        NEW
  KvResizeResultRow.test.tsx                                                    NEW
  KvResizeCropModal.test.tsx                                                    NEW

web/src/lib/studio/kv/
  cropMath.test.ts                                                              NEW
  useResizeExports.test.ts                                                      NEW

web/src/services/kv/
  resize-stream.test.ts                                                         NEW
```

## Edge cases

| Case | Behavior |
|---|---|
| User enters Resize with no generations | Panel renders empty state; CTA disabled |
| Source generation deleted while exports exist | Cascade-delete (hard); UI hydrates fresh on next mount |
| User generates a new Sketch/Craft version while Resize tab is open | Web detects new latest via existing generation stream; resets view to new Original (zero exports). Old exports are still in DB but not shown. |
| Single platform fails | Row shows Failed state + Retry button; other rows unaffected. Retry calls `POST /resize-exports/{export}/regenerate` with the existing crop_window. |
| User unchecks a platform after exports exist | Existing export stays; checkbox is "selected for next batch" only. Re-checking triggers no-op (idempotent POST returns existing row). |
| User re-clicks Resize CTA with same selection | Idempotent — no new rows; nothing happens. |
| User re-clicks Resize CTA with mixed selection (some new, some existing) | Only new platforms get pending rows; existing untouched. |
| Network drop during SSE | Reconnect with `Last-Event-ID`; UI hydrates from `GET /resize-exports`. |
| Source has aspect identical to target (e.g., 1:1 → 1:1 copy) | Skip outpaint; copy source verbatim to S3, mark `done`. |
| Source covers target on both axes (e.g., 1920×1080 → 820×360) | Skip outpaint; auto center-crop and upload, mark `done`. |
| Custom `crop_window` outside source bounds | API rejects with 422. |
| Print sizes (half-DPI) | Tooltip on print row: "Preview quality — full-resolution export coming soon". |
| FLUX rate-limited and OpenAI also unavailable | Mark `failed` with `error_message`; user retries later. |

## Acceptance criteria

1. Switching `canvasMode` to `resize` swaps the layers panel for `KvResizePanel` and the canvas for `KvResizeCanvas`. Original row shows the latest generation labeled `Original • {w} × {h} px`. No skeletons appear yet.
2. With no generations, the panel renders the empty state and the CTA is disabled.
3. Selecting one or more platforms enables the CTA and updates its label to `Resize · N selected`.
4. Clicking the CTA inserts N pending rows below Original on the canvas, each with a skeleton and the correct platform name + target dimensions label.
5. As each platform completes, its skeleton swaps to the rendered image. The unmasked region of the rendered image is byte-identical to the corresponding region of the source (verifiable by pixel diff on overlap).
6. Each non-Original row exposes Download and Adjust-crop-and-regenerate icon buttons. The Original row exposes Download only.
7. Adjust-crop opens `KvResizeCropModal` with a draggable rectangle locked to the platform's target aspect ratio. Saving regenerates that single row in place; row id is unchanged (UPSERT on `(parent_generation_id, platform_id)`).
8. The version-history panel and version-card list do **not** include resize exports — Resize never appears on the version timeline.
9. The chat thread is not modified by Resize actions (no chat bubbles, no chat history entries).
10. Switching to Sketch and back to Resize within the same session preserves prior exports for the current source.
11. A new Sketch/Craft generation hides the prior source's exports and resets to an empty state for the new source. Old exports remain in DB but are unreachable from the UI.
12. A row in `failed` state shows a Retry button; clicking it re-fires the AI call.
13. SSE channel closes once no `pending`/`generating` rows remain; reconnect resumes from the last seen event.
14. Canvas tools (cursor / frame / text / image) are hidden in Resize mode; chat toggle pill stays.
15. Auto-cropped exports (when source covers the target on both axes) complete in `<2s` end-to-end since no model call is made.

## Migration

```
2026_04_28_120000_create_kv_resize_exports_table
```

Reversible: `DROP TABLE kv_resize_exports`. No backfill — table starts empty.

## Analytics

New `studio_activities.action` values:
- `kv_resize_started` — metadata: `{ parent_generation_id, platform_ids: [...] }`
- `kv_resize_export_completed` — metadata: `{ export_id, parent_generation_id, platform_id }`
- `kv_resize_export_failed` — metadata: `{ export_id, parent_generation_id, platform_id, error_code }`
- `kv_resize_export_regenerated` — metadata: `{ export_id, crop_window_changed: bool }`

## Testing

- **API**: feature tests for the 5 public endpoints (auth, validation, idempotency, ratio mismatch); feature test for the internal callback persisting `image_url` + `status`; unit tests for `KvResizeExportService.createBatch` (idempotency, registry validation) and `regenerate` (UPSERT semantics).
- **AI service**: unit tests for `canvas.smart_crop` (all six aspect-class combinations: source >, =, < target on each axis), `pad_to_target`, `build_mask` (correct white/black regions); service flow test for FLUX-success and FLUX-fail-OpenAI-success; router test for the public endpoint contract.
- **Web**: component tests for the three Resize components (panel, result row, crop modal); unit tests for `cropMath` (center-crop math, fit-inside math); SSE client reconnect test; Playwright happy path — generate a Sketch KV → switch to Resize → check 3 platforms → click CTA → verify 3 skeletons → wait for completion → verify 3 rendered images with correct dims.

## Out of scope (v1)

- Source version picker (always latest).
- Print full-DPI rendering (half-DPI preview only).
- Subject-detection-based smart crop (auto = center crop).
- Custom platforms ("My Spotify Canvas 1080×1080").
- Bulk download (zip of all exports) — single-image download only.
- Background upscale pass.
- Resize re-rendering on source overlay changes (overlays are rendered client-side; resize uses the server-side `image_url` only — overlays appear in the Original row but not in resized outputs in v1).
- Custom outpaint prompts ("polish the extension warmer").

## Trade-offs accepted

- **Center-crop can cut subjects on off-center compositions.** Mitigation: per-result Adjust-crop escape hatch.
- **FLUX Fill Pro is paid + has rate limits.** Mitigation: gpt-image-1 mask-edit fallback already in stack.
- **Half-DPI print is a half-measure.** Acceptable for v1 because the channels picker is the user-facing innovation; full-DPI is a backend upscale pass that doesn't change the UX.
- **Exports vanish on new source generation.** Acceptable because exports are tied to a specific source — if the source changes, exports are out of date anyway.
- **Overlays not re-rendered.** Resize works on the server-side image, not the canvas with overlays applied. This is acceptable for v1 because most KVs are designed with overlays as a layout aid; for shipping, users can either flatten overlays or live with overlay-less exports.
- **Soft delete only protects direct deletion.** Cascade from `kv_generations` is hard. Acceptable because exports without a source are meaningless.
- **No `Last-Event-ID` support on the SSE stream.** Reconnect strategy is "re-fetch via `GET /resize-exports`, then re-subscribe to stream." Acceptable because exports are idempotent and the full state is always available via the list endpoint.
- **No server-side crop_window bounds validation.** Spec edge case "crop_window outside source bounds -> 422" is enforced client-side (the crop modal clamps). Out-of-bounds crops would 4xx at the AI service when PIL tries to crop, which surfaces as `status='failed'` with the error. v2 may store source w/h on `kv_generations` to enable server-side validation.

## Future work

- Source version picker (drop-down on the Original row).
- Print full-DPI export with an upscale pass (Topaz, FLUX upscale, or `clarity-upscaler`).
- Subject-detection-based smart crop using a lightweight keypoint model.
- Custom platform definitions per workspace.
- Bulk download (zip of all exports for the current source).
- Re-render with overlays composited (server-side layout flatten before outpaint).
- Per-platform style hints (e.g., "TikTok variants should bias bolder text legibility").
- Treat Resize outputs as Studio-Files-equivalent objects so they can be edited in their own canvas later.
