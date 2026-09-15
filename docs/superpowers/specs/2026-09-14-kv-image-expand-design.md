# KV Expand Image — Design

**Date:** 2026-09-14
**Author:** daffa (with Claude)
**Status:** approved in chat, awaiting implementation plan
**Services:** web, api, ai-service

## 1. Summary

Add an **"Expand image"** action to image overlays in KV Studio. The user
picks a target aspect ratio (Original / Square 1:1 / Portrait 9:16 /
Landscape 16:9) or drags the expand bounds by hand, positions the original
image anywhere inside the new canvas, and runs an AI outpaint that fills the
new area. The result replaces the overlay in place: the overlay's box grows
so the original pixels stay at exactly the same on-canvas position and size.

Reference: thebrief.ai "Expand image" dialog (preset list on the left, a
drag-frame bounds editor on the right, "Expand image" runs the fill, "Apply
changes" commits).

## 2. Decisions taken during brainstorming

| Question | Decision |
|---|---|
| Which surfaces | All three: Craft canvas right-click (`KvOverlayContextMenu`), Layers-panel row menu (`layerRowMenu`), Resize canvas right-click (`KvResizeOverlayContextMenu`). Full parity with "Remove background". |
| Geometry after apply | Overlay box grows; original pixels keep their on-canvas position and size (geometry + payload patch, not payload-only). |
| Free-text prompt | None in v1. Use the existing `OUTPAINT_GUIDANCE` prompt. |
| Backend shape | New `kv_image_expand` module cloning the background-removal pattern (row + queued job + ai-service 202 + internal callback + metering). Not piggy-backed on `kv_resize`, not synchronous. |
| Fill engine | Existing `app/tools/outpaint_image.py::outpaint()` (gpt-image-2 masked edit) — source pixels preserved, only the mask is painted. |
| Crop | No cropping in v1 — the canvas must always fully contain the source image ("pure expand"). |
| Size cap | `canvas_w`, `canvas_h` ≤ 4096 px, enforced in web, api validation, and ai-service schema. Sources larger than 4096 on either edge cannot be expanded (the modal disables presets + Run with an inline message). |

## 3. Placement contract

One value type flows unchanged from the modal to the api to the ai-service.
All numbers are in **natural pixels of the source image**.

```ts
type KvExpandPlacement = {
  canvas_w: number; // output width
  canvas_h: number; // output height
  image_x: number;  // left edge of the source inside the canvas
  image_y: number;  // top edge of the source inside the canvas
};
```

Invariants (checked at every layer; violations are a 422 at api and
ai-service, and unreachable UI state in web):

```
image_x ≥ 0, image_y ≥ 0
image_x + source_w ≤ canvas_w
image_y + source_h ≤ canvas_h
canvas_w ≤ 4096, canvas_h ≤ 4096
```

The web sends `source_w` / `source_h` (from the loaded image's
`naturalWidth/Height`) alongside the placement so the api can check the
invariant without downloading the image. The ai-service re-checks the
natural size after download and fails the row on a mismatch rather than
producing a silently shifted result.

### 3.1 Presets

Given `(sw, sh)` and a target ratio `r = w/h`:

- Smallest canvas with ratio `r` that contains the source:
  `if sw/sh ≥ r: canvas_w = sw, canvas_h = ceil(sw / r)`
  `else: canvas_h = sh, canvas_w = ceil(sh * r)`
- Source centred: `image_x = floor((canvas_w - sw)/2)`, `image_y = floor((canvas_h - sh)/2)`.
- **Original** = ratio `sw/sh` → canvas equals the source. There is no new
  area, so "Expand image" is disabled until the user drags the frame.
- Presets: Original, Square 1:1, Portrait 9:16, Landscape 16:9.
- Any manual drag switches the active preset to "custom" (no preset
  highlighted).

If a preset would exceed 4096 on an edge, that preset is disabled with a
tooltip ("Exceeds 4096 px").

### 3.2 Manual bounds editor

`ExpandBoundsEditor` — a plain DOM component (`div` + pointer events +
`useState`), **not** Fabric/Konva. It renders the source image inside an
outer frame with 8 handles.

- Dragging a handle outward grows `canvas_w/h`; dragging a left/top handle
  also shifts `image_x/y` so the source stays put on screen.
- The frame cannot shrink below the source on either axis, and cannot grow
  past 4096.
- Dragging the source image moves `image_x/y`, clamped inside the canvas.
- Local undo/redo stack of placements (like the reference dialog's arrows).
- Pure logic lives in `web/src/lib/studio/kv/expandPlacement.ts`:
  `computePresetPlacement`, `clampPlacement`, `applyHandleDrag`,
  `applyImageDrag`, `isExpandable(placement, sw, sh)` — all unit-tested
  without DOM.

## 4. Web

### 4.1 Modal — `KvExpandImageModal`

`web/src/components/studio/kv-generator/KvExpandImageModal.tsx`, built on
`BaseModal` (v1) like `KvRemoveBackgroundModal`.

Layout (matches the reference):
- Left column: intro copy, preset list, primary "Expand image" button,
  credit estimate line ("Estimated cost: ~N credits", same wording as the
  bg-removal modal; N from §4.5).
- Right column: `ExpandBoundsEditor` with undo/redo.
- Footer: Cancel / Apply changes (Apply disabled until a result is ready).

Phase machine, same as bg-removal:

```
idle → running → ready(imageUrl, width, height, modelVersion) | failed(message)
```

- **Run** ("Expand image"): `startImageExpand({fileId, sourceImageUrl,
  sourceW, sourceH, placement})` → poll. While running the editor is
  read-only, presets disabled.
- **ready**: the result image replaces the editor content (frame shown
  read-only so the user can see where the source sat); Apply enabled.
  The user may go back to editing (returns to idle, discards the result).
- **failed**: inline error with the api's message
  (`extractImageExpandErrorMessage`, mirroring bg-removal's helper), Run
  becomes "Try again".
- Closing the modal while running sets `isCancelled` so polling stops; the
  server-side row is left to finish or go stale.

Props:

```ts
type Props = {
  open: boolean;
  fileId: string;
  overlayId: string;
  sourceImageUrl: string;
  source: KvImageExpandSource; // "canvas" | "layers_panel" | "resize_canvas"
  onClose: () => void;
  onApply: (result: { imageUrl: string; mimeType: string;
                      placement: KvExpandPlacement;
                      sourceW: number; sourceH: number }) => void;
};
```

### 4.2 Start / poll — `imageExpand.ts`

`web/src/components/studio/kv-generator/imageExpand.ts`, cloned from
`backgroundRemoval.ts`:

- `startImageExpand(...)` → `{ ok: true, row } | { ok: false, message }`,
  never throws.
- `pollImageExpand(fileId, id, opts)` — `DEFAULT_INTERVAL_MS = 3000`,
  `DEFAULT_MAX_ATTEMPTS = 60` (3-minute window; gpt-image-2 is slower than
  segmentation), `POLL_REQUEST_TIMEOUT_MS = 20_000` per GET via
  `AbortSignal.timeout`, `isCancelled` hook.
- Api client: `createImageExpand` / `getImageExpand` in
  `web/src/services/kv/api.ts`; types in `web/src/types/kv/imageExpand.ts`
  (`KvImageExpand` row: `id, status, image_url, width, height,
  model_version, error_message, placement`).

### 4.3 Apply patch — `buildExpandApplyPatch`

In `expandPlacement.ts`. Overlay geometry is **normalised to the host
board** (`x, y, width, height` are fractions of the board's width/height —
see `KvFabricCanvas`'s `onUpdateOverlay` maths), `rotation` is degrees,
and rotation pivots on the overlay's centre (Fabric centre origin). So the
source-pixel → overlay scale is per-axis, and a rotated centre shift has
to pass through board pixels:

```
buildExpandApplyPatch({ overlay, placement, sourceW, sourceH, imageUrl,
                        mimeType, hostAspect })   // hostAspect = boardW / boardH

sx = overlay.width  / sourceW          // board-fraction per source px, horizontal
sy = overlay.height / sourceH          // board-fraction per source px, vertical
newW = placement.canvas_w * sx
newH = placement.canvas_h * sy
dx   = -placement.image_x * sx         // local, unrotated, normalised
dy   = -placement.image_y * sy

oldCenter = (overlay.x + overlay.width/2, overlay.y + overlay.height/2)
shiftN    = (dx + newW/2 - overlay.width/2, dy + newH/2 - overlay.height/2)
// rotate in board-pixel space: scale x by hostAspect, rotate, scale back
shiftPx   = (shiftN.x * hostAspect, shiftN.y)
rotPx     = R(overlay.rotation°) · shiftPx
shiftRot  = (rotPx.x / hostAspect, rotPx.y)
newCenter = oldCenter + shiftRot
newX = newCenter.x - newW/2
newY = newCenter.y - newH/2

payload = { ...overlay.payload, asset_url: imageUrl, mime_type: mimeType }
return { x: newX, y: newY, width: newW, height: newH, payload }
```

At rotation 0 this reduces to `x += dx, y += dy` and `hostAspect` cancels
out. The payload spreads the **existing** image payload (name / hidden /
locked / opacity / blend survive) and only swaps `asset_url` +
`mime_type` — unlike `buildImageReplacePatch`, which drops those. Geometry
and payload go out as **one** patch so there is no frame where the box has
grown but the old image is still shown.

`hostAspect` sources: Resize master → `sourceSize.w / sourceSize.h`, Resize
tile → `row.width / row.height` (exact); Craft → `measuredBoardDims` of
the active board (exact for rotation 0 on any board, approximate for a
rotated overlay on a non-active board — acceptable, documented in code).

### 4.4 Surfaces

Every entry point is gated by an optional `onExpandImage?: (id) => void`
prop. Absence **is** the flag gate — same convention as
`onRemoveBackground`.

- `KvOverlayContextMenu` — "Expand image" item after "Remove background".
- `KvResizeOverlayContextMenu` — same.
- `layerRowMenu` — same, after "Remove background".
- `KvLayersPanel` / `KvFabricCanvas` / `KvResizeCanvas` thread the prop.

**Craft** (`KvGeneratorLayout`): `expandTarget` state +
`handleRequestExpandImage(id, source)` + `handleApplyExpand(result)`,
mirroring the bg-removal trio. Request guard: `file?.id` present, overlay
is `payload.type === "image"` (the 4096 source cap is enforced inside the
modal once the image reports its natural size). Apply re-resolves the live overlay (deleted /
type changed → toast, no write), then `docUpdateOverlay(kvDoc, id, patch)`
when the doc is up, else `update(id, patch)`.

**Resize** (`KvResizeCanvas`): self-contained duplicate, like its
bg-removal flow — master → `commitMasterOverlays`, tile →
`baseOverlaysFor(row)` + the tile snapshot commit. Tile snapshots are
detached from the master, so an expand on a tile changes only that tile
(consistent with Replace image on Resize).

Natural size of the source: the modal's `<img onLoad>` provides it; the
apply result carries `sourceW/sourceH` so the patch builder never re-reads
the DOM.

### 4.5 Flag, analytics, credits

- `KV_IMAGE_EXPAND: "show-kv-image-expand"` in
  `web/src/lib/featureFlags/constants.ts`. Fail-closed; dev/staging
  always-on; the api reads the same key.
- `web/src/lib/analytics/kv-generator-events.ts`:
  `trackKvImageExpandOpened / Run / Applied / Failed`, all carrying
  `source`, `preset` (`original|square|portrait|landscape|custom`),
  `canvas_w`, `canvas_h`, `source_w`, `source_h`.
- Credit estimate: the same source Resize uses — the `image-models`
  endpoint's `estimated_credits` for `RESIZE_RENDER_MODEL` (gpt-image-2),
  a flat per-run figure. `KvResizePanel`'s private
  `useResizeCreditEstimate(count)` is lifted to
  `web/src/lib/studio/kv/useGptImageCreditEstimate.ts` and used by both
  Resize (`count = selected platforms`) and by the expand modal's parents
  (`count = 1`), which pass the number down as `estimatedCredits` so the
  modal itself stays free of react-query and is testable without a
  `QueryClientProvider`.
  No per-pixel formula: the api charges from the vendor's real token usage,
  and a flat estimate is what the user already sees for the same model on
  Resize. While the query is loading or the model is missing, the line is
  omitted (same as Resize).

## 5. api

Mirrors `KvBackgroundRemoval*` file-for-file.

### 5.1 Data

Migration `create_kv_image_expands_table`:

| column | type |
|---|---|
| id | uuid pk |
| studio_file_id | uuid fk → studio_files, cascade |
| created_by | uuid fk → users |
| source_image_url | text |
| source_w, source_h | integer |
| placement | jsonb (`canvas_w, canvas_h, image_x, image_y`) |
| status | string — `KvImageExpandStatus` enum: pending / generating / done / failed |
| image_url | text nullable |
| width, height | integer nullable |
| model_version | string nullable |
| token_usage | jsonb nullable |
| error_message | text nullable |
| timestamps | |

Model `KvImageExpand`, enum `KvImageExpandStatus`, resource
`KvImageExpandResource` (exposes `id, status, image_url, width, height,
model_version, error_message, placement`).

### 5.2 Routes

Under the existing studio file group, middleware
`feature.flag:show-kv-image-expand,off`:

- `POST files/{fileId}/image-expands` → `KvImageExpandController@store`, 202
- `GET  files/{fileId}/image-expands/{id}` → `@show`

Internal: `POST internal/kv-image-expands/completed` →
`KvImageExpandInternalController@completed`, same auth as the bg-removal
internal route.

### 5.3 Validation — `CreateKvImageExpandRequest`

- `source_image_url`: required url.
- `source_w`, `source_h`: required integer, 1..4096.
- `placement`: required array; `placement.canvas_w`, `placement.canvas_h`
  integer 1..4096; `placement.image_x`, `placement.image_y` integer ≥ 0.
- `withValidator`: `image_x + source_w ≤ canvas_w` and
  `image_y + source_h ≤ canvas_h`, else 422 with a plain message.
- Every `placement.*` key is listed explicitly — `excludeUnvalidatedArrayKeys`
  is on in this repo, so a partial rule set would strip the payload.

### 5.4 Controller / service / job

- `KvImageExpandController::store`: `findOrFail` file, `authorizeAccess`
  (workspace + brand + `ToolPermissionResolver`, copied), rate limit key
  `image-expand-start:{user}` with
  `config('studio.image_expand_rate_limit_per_hour', 30)` → 429 with the
  "try again in Nm" message, then `service->create(...)` → 202 with the
  resource.
- `::show`: `failStale($file)` then `firstOrFail` scoped to the file.
- `KvImageExpandService`: `create`, `dispatchToAi`, `markGenerating`,
  `markDone(row, imageUrl, width, height, modelVersion, tokenUsage)`,
  `markFailed`, `failStale` (`STALE_AFTER_MINUTES = 10`).
- `ProcessKvImageExpandJob`: `tries = 3`, `timeout = 300`, `default`
  queue. `Http::timeout(60)->post("{$aiUrl}/ai/kv-image-expand/run", [...])`
  with `image_expand_id, source_image_url, source_w, source_h, placement,
  user_id, user_email, workspace_id, workspace_name, brand_id, brand_name`.
  **No `Http::retry()`** — it throws and would make the `failed()` check
  dead code, and each retry is a billed vendor run. `catch` → markFailed;
  non-2xx → markFailed. `failed()` never reopens a Done row.

### 5.5 Callback + metering — `KvImageExpandInternalController`

`KvImageExpandCompleteRequest`: `image_expand_id`, `status` in
`done|failed`, `image_url`, `width`, `height`, `model_version`,
`token_usage` (array), `error_message`.

On `done`: `markDone`, then

```php
$this->metering->charge(
    user: $user, workspace: $row->file->workspace,
    costType: 'kv_image_expand', toolName: 'KV Expand Image',
    batchId: "kv_image_expand_{$row->id}",
    model: $validated['model_version'] ?? 'gpt-image-2',
    tokenUsage: $validated['token_usage'] ?? [],
    brandId: $row->file->brand_id,
);
```

Token-based, like resize — gpt-image-2 returns token usage. Empty usage
logs a warning and skips (existing `charge()` behaviour). Idempotent via
`batch_identifier`. On `failed`: `markFailed`.

## 6. ai-service

`app/agents/kv_image_expand/` — `request_schema.py`, `response_schema.py`,
`router.py`, `api_client.py`, `service.py`, cloned from
`kv_background_removal`.

- `ImageExpandRequest` (pydantic): `image_expand_id`, `source_image_url`,
  `source_w`, `source_h` (1..4096), `placement` model with `canvas_w`,
  `canvas_h` (1..4096), `image_x`, `image_y` (≥0), plus a model validator
  for the containment invariant → 422. Context fields
  (`user_id, user_email, workspace_id, workspace_name, brand_id,
  brand_name`) optional, passed through for logging/PostHog like siblings.
- `POST /ai/kv-image-expand/run` → 202, `BackgroundTasks.add_task(process_image_expand, req)`.
- `process_image_expand(req)` — never raises:
  1. `download_to_temp(source_image_url)`, `Image.open`, `convert("RGBA")`.
  2. If `(w, h) != (source_w, source_h)` → callback `failed` with
     "Source image is {w}×{h}, expected {source_w}×{source_h}".
  3. `canvas = Image.new("RGBA", (canvas_w, canvas_h), (0,0,0,0))`,
     `canvas.paste(src, (image_x, image_y), src)`.
  4. `mask = build_mask(canvas_w, canvas_h, (image_x, image_y, image_x+w, image_y+h))`
     from `app/agents/kv_resize/canvas.py` (white = paint, black = preserve).
  5. `image_bytes, model, token_usage = outpaint(canvas, mask, OUTPAINT_GUIDANCE)`
     from `app/tools/outpaint_image.py` / `kv_resize/prompts/outpaint.py`.
  6. `save_bytes_to_file(...)` → `{API_ENV}/kv-image-expands/{id}.png`.
  7. `post_completed(status="done", image_url, width=canvas_w,
     height=canvas_h, model_version=model, token_usage=token_usage)`.
  8. Any exception → `post_completed(status="failed", error_message=str(exc))`;
     a failure of that second post is logged, not raised.
  9. `finally`: unlink the temp file.

`outpaint()` already handles gpt-image-2's multiple-of-16 and minimum
pixel constraints (pads, then crops back), so the output is exactly
`canvas_w × canvas_h`.

## 7. Error handling summary

| Failure | Where caught | User sees |
|---|---|---|
| Source > 4096 on either edge | modal (after the source `<img>` reports its natural size) | inline "This image is too large to expand (max 4096 px)", presets + Run disabled |
| Preset exceeds 4096 | modal | preset disabled + tooltip |
| Flag off | api middleware 404 / web hides entry | nothing |
| Rate limit | api 429 | modal error with "try again in Nm" |
| ai-service unreachable / 5xx | job → markFailed | modal error, Try again |
| Natural size mismatch | ai-service → failed callback | modal error |
| gpt-image-2 persistent error | ai-service → failed callback | modal error |
| Callback never lands | `failStale` on next GET after 10 min | modal error "Timed out…" |
| Layer deleted while running | web apply guard | toast "That layer changed — expand not applied." |

## 8. Testing

Tests derive their expected numbers from the implementer's own
computation and must be mutation-checked (flip a sign, confirm red) before
they count — see `lesson_plan_tests_written_from_reasoning_are_vacuous`.

**web** (`bun test`; keep files < 51 KB; query via `within(document.body)`):
- `expandPlacement.test.ts`: presets on landscape and portrait sources;
  Original returns the source; `isExpandable` false for Original; clamp
  rejects canvas < source and > 4096; left/top handle drag grows the
  canvas **and** shifts `image_x/y`; image drag clamps inside the canvas;
  `buildExpandApplyPatch` at 0°, 90°, 45° with an asymmetric placement —
  assert the source's on-canvas centre and size are unchanged; stretched
  overlay (width/height scales differ).
- `KvExpandImageModal.test.tsx`: preset click updates the frame; Run
  disabled on Original; start failure surfaces the api message; ready →
  Apply calls `onApply` with placement + source size; close while running
  cancels polling.
- `KvOverlayContextMenu.test.tsx`, `KvResizeOverlayContextMenu` tests,
  `layerRowMenu.test.tsx`: item rendered only when `onExpandImage` is given.
- `imageExpand.test.ts`: poll stops on done / failed / cancel / maxAttempts.

**api** (Unit; Feature on a scratch Postgres, invoked by file path):
- Request: canvas 4097 → 422; containment violation → 422; all placement
  keys survive `validated()`.
- Controller: cross-workspace 403; 429 past the hourly limit; 202 + pending row.
- Job: connection exception → failed; 500 → failed; `failed()` leaves a
  Done row alone.
- Internal: done charges exactly once (second callback is a no-op);
  failed stores `error_message`.
- `failStale` flips pending/generating rows older than 10 min.

**ai-service** (pytest; the 16 pre-existing reds are baseline):
- Schema: cap and containment → 422.
- `process_image_expand` with `download_to_temp`, `outpaint`,
  `save_bytes_to_file`, `post_completed` mocked: the canvas passed to
  `outpaint` is `canvas_w × canvas_h`; the mask is 0 exactly on the paste
  box and 255 elsewhere; natural-size mismatch → failed callback;
  `outpaint` raising → failed callback, no exception escapes.

**Manual e2e checklist** (before calling the feature done):
1. Craft canvas right-click → preset 16:9 → run → apply: box grows, source
   pixels don't move.
2. Layers-panel row menu → manual drag left + up → apply.
3. Resize surface on a tile vs on the master: only the chosen one changes.
4. Rotated overlay (≈30°) → apply: source still visually in place.
5. `cost_histories` has exactly one `kv_image_expand_{id}` row per run.
6. Flag off: no menu items, api route 404.

## 9. Out of scope (v1)

- Free-text prompt for the fill.
- Cropping / shrinking the canvas below the source.
- Expanding non-image overlays, or multiple overlays at once.
- Konva (legacy) canvas — only the Fabric editor and Resize canvas get the
  entry point.

---

## 10. Post-launch finding (2026-09-15): gpt-image-2 does not honour the mask

Reported as "staging expands come back with a black background, local was
fine yesterday". Both halves of that premise turned out to be wrong.

### What was ruled out

Staging (`/var/www/frnd/staging/ai-services`) and the local checkout were
both on `b4b2147` — identical code. Ruled out, each with evidence:

| Candidate | Verdict |
|---|---|
| Code drift stg vs local | same commit `b4b2147` |
| Bug in `build_expand_canvas` / `build_mask` | payload rebuilt by hand: canvas alpha 0 in margins / 255 in paste box, mask 255 paint / 0 preserve, RGBA-alpha conversion correct |
| Prompt drift | `EXPAND_GUIDANCE` sha256 `502c5916…`, 557 chars, identical both sides |
| Pillow 11.3.0 (local) vs 12.2.0 (staging) | encoded PNG bytes differ, **decoded pixels identical** (`5903e552…` canvas, `91d03f54…` mask), IHDR identical (1920×1920, depth 8, colortype 6) — compression only |
| Model access | `GET /v1/models/gpt-image-2` → 200 on both keys |
| Transparent margins read as black bars | **disproved** — see the A/B below |
| Pipeline error | staging log clean, row `status=done`, `error_message=null` |

### The measurement

Identical payload every run (source 1080×1920, canvas 1920×1920,
`image_x=420`), so **if the mask were a hard preserve, the output's content
width would be exactly 1080 every time.**

| Env | n | clean | black | content widths produced |
|---|---|---|---|---|
| staging | 9 | 1 | 8 (89%) | 861, 961, 1079, 1090, 1097, 1199, 1311, 1347, 1920 |
| local | 3 | 2 | 1 | 928, 1920, 1920 |
| total | 12 | 3 | **9 (75%)** | 1080 hit once (1079) |

Staging is not deterministically broken — it produced one clean frame in 9.
Local 2/3 vs staging 1/9 is still **not significant** (Fisher one-tailed
p = 0.127), so the differing `OPENAI_API_KEY` projects remain unimplicated.

### Root cause

There are **two distinct failure modes**, and they need separate fixes:

**Mode A — the mask is ignored.** The model regenerates the whole frame and
overwrites part of the paste box itself (content 861, 928, 961 px against a
1080 px source). No margin preparation can prevent this.

**Mode B — the mask is honoured and the fill is black.** Content came back at
1079 px — the paste box preserved essentially exactly — with a 100% black
margin. Here the mask contract worked and the model simply declined to
outpaint, painting the masked region black instead.

Mode B is the one a prompt or parameter change could plausibly address; Mode A
cannot be fixed from our side at all. The clean runs (content 1920) are the
model reading the input as a scene and extending it to fill.

An earlier draft of this section claimed the content width was *never* 1080.
That was wrong — the 1079 px run is Mode B, and it is what splits the
diagnosis in two.

The staging-vs-local split (0/5 vs 2/3) is suggestive but not significant
(Fisher one-tailed p ≈ 0.11). The two environments use different
`OPENAI_API_KEY` projects; that remains an untested candidate for the
*rate*, but it is not the cause of the failure mode.

### Rejected fix

An edge-average margin fill (fill the four margins with the source's edge
colour so the model never sees transparent void) was tried and **rejected**:
100% black on its only run, while the unmodified code came back clean on the
same input in the same session. It also mis-passed the margin width as
`_edge_average`'s `band` argument, averaging 420 px into the source instead
of the outermost 8. Patch kept at `scratchpad/edge-fill-rejected.patch`.

### The defect that is ours

`service.py` posts `status=done` without ever checking that the output still
contains the source. That is why a 100%-black frame reached the user with a
clean log and a null `error_message`. **Spec gap:** §7 has no row for "the
model returned something that does not preserve the paste box."

Proposed (not implemented): after `outpaint`, compare the output's paste-box
region against the source; on divergence retry, and after N retries fail the
row with a message the user can act on. The content-width check used above
(content bbox vs `source_w`) is a cheap sufficient signal.

### Untested next levers, in priority order

**1. `input_fidelity` — TESTED AND DEAD (2026-09-15).** It is indeed never
sent, but it cannot be: gpt-image-2 rejects it outright.

```
400 {"error":{"message":"The model 'gpt-image-2' does not support the
'input_fidelity' parameter.","type":"image_generation_user_error"}}
```

4/4 calls refused. The parameter exists on gpt-image-1, not on gpt-image-2.
**This also retires the same recommendation made for kv_resize's
`ai_restructure` drift on the same date** — that path also hardcodes
gpt-image-2 (`outpaint_image.py`, both `files` builders), so the lever is
unavailable there too. Anyone reaching for it should stop here.

**2. Non-standard output size.** `_gpt_image_2_aligned_dims()` only rounds to
multiples of 16 and enforces the 655,360-pixel minimum — it never constrains
the request to a size gpt-image-2 actually supports. Every run above asked for
`size=1920x1920`; the 2026-09-14 runs also used non-standard sizes (2640×2640,
864×1520). Requesting a supported size and upscaling ourselves may raise the
hit rate.

**3. No strategy/parameter logging.** The staging log shows only the 202; the
request parameters are not logged, so any future regression has to be
reconstructed from the output image. Worth a log line.

These levers are unverified. None should be called a fix until measured the
way §10 measured this one: identical payload, n ≥ 5 per arm, content-width as
the pass/fail signal.

---

## 11. Multi-pass finding (2026-09-15): mask fraction is the governing variable

Prompted by "isn't this the same logic as resize?". It is not — and the
difference is the fix.

### Resize never puts the model in this position

`kv_resize/service.py:_decide_strategy()` picks between five strategies after a
vision prepass. Expand has no strategy selection at all: it always takes the
masked-outpaint path. And resize deliberately routes *away* from that path for
exactly our case (`service.py:152`):

```python
# Text-free source + a big aspect change: let gpt-image-2 recompose the
# whole frame so the subject stays prominent, instead of letterboxing it
# down into a thin band (fit_not_fill) — the "too zoomed out" failure mode.
if orientation(src_aspect) != orientation(tgt_aspect):
    return "ai_reframe"
```

Portrait → square *is* an orientation change. Resize would have chosen
`ai_reframe`; expand cannot, because mask-free recomposition destroys the
source pixels that expand exists to preserve.

Second difference — how much the model is asked to invent:

| Path | Masked fraction |
|---|---|
| resize `fit_inside_target` 1920×1080, `frame_px=32` | 9.1% |
| resize `fit_inside_target` 1080×1080, `frame_px=32` | 11.5% |
| **expand, single jump** | **43.8%** |

### The measurement

Chain `1080 → 1328 → 1632 → 1920` (all multiples of 16, so no padding path),
masks 18.7 / 18.6 / 15.0%, landing at exactly `image_x=420` — identical
geometry to production, so the numbers compare directly with §10.

| Arm | mask/call | n | clean | black |
|---|---|---|---|---|
| multi-pass (3 steps) | 15–19% | 3 | 3 | 0 |
| single jump, interleaved same session | 43.8% | 2 | 0 | 2 |

Per-call across all staging data: mask 44% → 1 clean / 11; mask ~18% →
**9 clean / 9**. Fisher one-tailed **p = 0.00006**. The interleaved controls
stayed black, so this is not OpenAI drifting mid-session.

**Masked fraction is the governing variable.** This is the first lever that
measurably works.

### Re-compositing the source is WRONG — it was tested and it breaks the image

The first multi-pass run pasted the original source back onto each step's
output to neutralise Mode A. Visually that destroys the result: the model
shifts the panel enough that the pasted original lands as a hard rectangle.
Colour discontinuity at the paste boundary:

| Variant | jump at x=420 | jump at x=1500 |
|---|---|---|
| raw multi-pass output | 1.1/255 | 1.1/255 |
| after re-compositing the source | 8.5/255 | 9.0/255 |

The raw chain output is seamless; the composited one shows two mismatched
podiums split by a visible edge. **The `margin_dark` metric cannot see this** —
it passed all three composited finals as "clean". Margin darkness proves the
margin got painted; it says nothing about seams. Any future guard or
experiment needs a boundary-continuity check alongside it.

The mask-fraction conclusion is unaffected: it rests on per-step `margin_dark`
measured on **raw model output before compositing**, over the margin region
only.

### Source preservation: measured, and it fails on both arms

Tested on the Sunlight KV (`studio_file 01m2j7a3zdnvdj1w3e4qnxa5vp`, master
1962×1086, heavy baked text + a face + pack art) expanded to 1962×1962 —
masked fraction 44.6%, the same magnitude as the reported failure. Chain
`1086 → 1328 → 1616 → 1962`, no re-compositing.

| Arm | margin_dark | drift in the source region |
|---|---|---|
| multi-pass (3 steps) | 0.0% | **40.4 / 255** |
| single jump | 0.0% | **31.0 / 255** |

Text stayed legible — "RHAMNO Power" did *not* become "RHAMINO", better than
`ai_restructure` manages. But the source region was **recomposed**: the face
changed, the lime headpiece changed, the plate slid down-left and is clipped,
"Cobain! BUSANYA" moved right and down, the pack shifted. Multi-pass is
*worse* than a single jump here because drift compounds across passes.

Also note: **this source never produced black margins at all**, on either arm,
at 44.6% mask. The mask-fraction result in §11 is established for the podium
KV; it is not proven universal.

### Verdict: this is an architecture problem, not a bug

Three approaches, none satisfying both constraints:

| Approach | Margin filled | Source pixels intact |
|---|---|---|
| single jump (shipped) | no — 75% black | no — drift 31/255 |
| multi-pass | yes — 9/9 | no — drift 40/255 |
| multi-pass + re-composite | yes | yes, but a visible seam (8.5–9.0/255) |

Root cause of the bind: **gpt-image-2's `/v1/images/edits` is not an
inpainting model, it is a regenerator.** The mask steers; it does not lock.
A product contract that reads "the overlay box grows so the original pixels
keep their on-board position" (§3) cannot be built on a primitive that redraws
the frame.

Re-compositing fails for a structural reason, not a tuning one: the model
paints surroundings that match *its own* redrawn centre, and we then swap that
centre for a different one. The surroundings then match nothing.

### The one avenue not yet closed

Take **only the outer band** from the model output, keep the original centre,
and **feather** the boundary so the seam dissolves. Plausible where the shift
is small (podium KV, drift 10–14); likely to fail where it is large (Sunlight,
drift 31–40), because the band itself continues a composition that has moved.

Which points at the same shape resize already has: expand is only safe for
"friendly" sources, and needs a **vision prepass to sort them** — a much larger
scope than this feature was designed with. That is a product decision, not an
implementation detail. Stopping here for team discussion rather than
attempting a fourth approach.

---

## 12. What shipped (2026-09-15)

Two new modules in `ai-service/app/agents/kv_image_expand/`, wired into
`service.py`. 46 tests green (baseline 35).

### `chain.py` — split the jump

`plan_expand_chain()` returns the smallest chain whose every step stays under
`MAX_STEP_MASK_FRACTION = 0.20`, capped at `MAX_STEPS = 4` because each step is
a billed call. The last entry is always the caller's placement exactly — the
board sizes the overlay box from it, so a chain that lands a pixel off would
shift the artwork with nothing to complain about it.

**Steps are spaced geometrically, not linearly.** The masked share of a step is
driven by the ratio between consecutive canvases, so equal ratios give equal
masks. Linear spacing loads the first step most and cost a whole extra step:

| Spacing | Steps | Masks | Calls | Drift, measured e2e |
|---|---|---|---|---|
| linear | 4 | 20.6 / 17.6 / 15.3 / 10.9% | 4 | 15.8/255 |
| geometric | 3 | 17.4 / 17.5 / 17.4% | 3 | **11.7/255** |

Geometric wins on both axes at once and keeps every step inside the 15–19% band
that measured 9/9 clean.

### `guard.py` — stop posting `done` on a dead frame

`margin_looks_dead()` compares the SHARE of margin pixels that are dark
relative to **the source's own edge luminance on that side**.

Three decisions worth keeping:

- **Relative, not absolute.** An absolute threshold rejects legitimately dark
  KVs, and the artwork in the original report is itself near-black along its
  bottom edge. Where the source edge is below `_EDGE_FLOOR` the side is skipped
  rather than guessed at.
- **A share, not a mean.** The real 86%-black output kept a bright ~20px band
  next to the paste box; its margin MEAN stays above the ratio while most of
  the margin is black. A mean-based detector passes that image. There is a test
  for exactly this shape.
- **Not a content-bbox check.** A dark KV has a small bright bbox, so
  bbox-vs-`source_w` false-positives on the artwork this must tolerate.

Validated against the six real staging outputs collected during the
investigation (3 failures, 3 clean): 6/6 correct.

### `service.py` — walk the chain, guard each step

Each step retries once (`MAX_STEP_RETRIES = 1`, worst case 8 calls) and a
persistently dead step raises, which the existing handler turns into a `failed`
callback. A dead frame is never uploaded.

`_merge_usage()` **sums token usage across every step and retry.** Each attempt
is a billed gpt-image-2 call; reporting one would quietly move the cost of a
multi-step expand onto our margin. **Product decision outstanding:** this
charges the user ~3x what a single-call expand charged. Flip `_merge_usage` to
report one call if the business would rather absorb it.

### End-to-end, real API, the reported failing source

| | Before (shipped) | After |
|---|---|---|
| calls | 1 | 3 |
| dark margin | 86–100% (10/11 runs) | **0.0%** |
| guard | none — `done` regardless | passes |
| source drift | 7.5/255 | 11.7/255 |

### Still true after this change

§11's verdict stands: the source region is **not** preserved, and multi-pass
drifts it slightly more than a single jump (11.7 vs 7.5). This change fixes the
black-bars failure and stops silent bad output. It does NOT make expand honour
the §3 contract. That remains a product decision.
