# KV Craft — Upload-Base Entry Point + Custom-Size Handling (Phase 1) — Design

**Date:** 2026-06-18
**Author:** Daffa
**Status:** draft (ready for plan)
**Services:** web, api (ai-service: no change in Phase 1)

## Problem

Two related gaps in the KV Generator Craft flow:

1. **No first-class entry point to upload a base image.** A user can only
   seed a Craft base by *attaching* an image in the chat composer and
   sending — the web then promotes that attachment to a base generation
   (`promoteAttachmentToBase.ts`, triggered from `KvChat.onSend`). There is
   no canvas-level "upload an image to start from it" affordance. The empty
   canvas only offers the artboard ratio picker
   ([KvCanvas.tsx:186](../../../web/src/components/studio/kv-generator/KvCanvas.tsx), `KvArtboardPicker`).

2. **Uploaded bases are blind to their own size.** `persistImportFromUpload`
   ([KvGenerationService.php:105](../../../api/app/Services/Studio/KvGenerationService.php))
   stores `mime_type`, `size` (bytes), and `original_filename` — but **not**
   the image's pixel dimensions or aspect ratio. So a Craft polish over an
   uploaded base has no `aspect_ratio` to pin.

3. **The image model only supports three aspect ratios.** gpt-image accepts
   `1:1` (1024²), `16:9` (1536×1024 ≈ 3:2), `9:16` (1024×1536 ≈ 2:3) and
   nothing else ([edit_image.py:76](../../../ai-service/app/tools/edit_image.py)).
   An extreme upload (e.g. a 3.4:1 banner) cannot be reproduced by a Craft
   polish — it would silently collapse toward a square.

## Goal

Make "upload an image as the Craft base" a first-class canvas action, and
handle the aspect-ratio mismatch honestly without dead-ending extreme-ratio
uploads. Purely additive to the existing Craft pipeline.

## Behavior

### Entry point — empty-state, vertical (Option A)

When a fresh KV file has no generations, the empty canvas shows, stacked
vertically:

- **Top:** the existing artboard ratio picker (`16:9 / 9:16 / 1:1`) — "start
  from scratch".
- **Divider:** "atau".
- **Bottom:** an **Upload image jadi base** block (upload icon + "drag & drop
  atau browse · rasio canvas ikut gambar").

Uploading promotes the image to **Version 1** (the base) immediately, via the
existing upload + import path — no chat message, no send action. The canvas
adopts the uploaded image's aspect ratio for display.

The existing chat-attachment promotion path stays as-is (it is not the
primary entry point but remains a valid fallback).

### Custom-size handling

On import, the API probes the image and persists its real dimensions +
aspect ratio. The uploaded base is **always** displayed at its true ratio
(it is just an image).

The aspect-ratio constraint only bites the **Craft polish** (img-to-img must
request a supported output size). So:

| Uploaded aspect | Craft | Upscale |
|---|---|---|
| Within tolerance of `1:1` / `3:2` / `2:3` | Works normally; canvas adopts that ratio | Works |
| Outside (extreme, e.g. 3.4:1) | **Gated** — chat warning "rasio X belum didukung untuk Craft", Craft action disabled | **Works** (ratio-preserving) |

**The model only outputs three sizes** (`edit_image.py` `OPENAI_SIZE_BY_RATIO`):
`1:1` → 1024² (decimal 1.0), `16:9` → 1536×1024 (decimal **1.5**, i.e. 3:2),
`9:16` → 1024×1536 (decimal **0.67**, i.e. 2:3). The `16:9` / `9:16` labels are
the canonical artboard labels but render at 3:2 / 2:3.

**Snap rule = nearest target, gate beyond 25%.** Convert the upload to a
decimal (`width / height`). Snap to the nearest of the three target decimals
{1.0, 1.5, 0.67} and use that target's label. Treat the upload as **extreme**
(Craft gated) only when even the nearest target is off by **more than 25%**
(relative). This lets common ratios through (4:3 ≈ 1.33, 3:2 = 1.5, 16:9 ≈ 1.78,
5:4) — they snap to a supported label and Craft works — while genuinely extreme
uploads gate. Examples: 1.78 → snaps to `16:9` (~19% off, supported); 1.33 →
snaps to `16:9` (~11% off, supported); 3.44 banner → nearest is 1.5 at ~129% off
→ **extreme, Craft gated**.

The snap decision is computed **once, server-side at import** (see api below)
and persisted as two metadata fields the web reads directly — `aspect_ratio`
(the supported label, set only when supported) and `craft_supported` (bool).

**Why upscale stays open:** upscale
([upscale_image.py](../../../ai-service/app/tools/upscale_image.py), surfaced
via `KvDownloadDropdown` in the top-nav) raises resolution without reframing,
so it is aspect-agnostic. An extreme-ratio banner is therefore never a dead
end — the user can still produce and download a hi-res version of it.

**Warning timing:** proactive — the chat surfaces the "not supported for
Craft" notice as soon as an extreme-ratio upload finishes, so the disabled
Craft action is explained before the user reaches for it.

## What does NOT change

| Scenario | Behavior |
|---|---|
| Sketch (any) | unchanged |
| Craft + existing AI base | unchanged (strict polish / freeform edit) |
| Chat-attachment → base promotion | unchanged (still valid) |
| Craft over a supported-ratio uploaded base | works like a normal polish |
| Upscale / download | unchanged; works on uploaded bases too |
| ai-service | no changes in Phase 1 — the ratio gate lives in web/api |

## Implementation

### api (`alva-intelligence/frnd-api-php`, branch target `develop`)

- **`ImportKvGenerationFromUploadRequest`** — accept `width` and `height`
  (required integers, `min:1`, sane `max`). The web measures them from the
  uploaded image before calling import (resolves Open Question on dimension
  source: client-measured + server-validated, no new image library).
- **`KvGenerationService::persistImportFromUpload`** — accept `width`/`height`
  in the payload; compute the snap decision (nearest of {1.0, 1.5, 0.67},
  gate beyond 25%) and persist into `metadata`, keeping existing keys:
  - `width`, `height` (raw px)
  - `aspect_ratio` — the supported label (`"1:1"`/`"16:9"`/`"9:16"`), set
    **only when supported**; omitted when extreme
  - `craft_supported` — bool
  The snap math lives in a small pure helper (e.g. `KvAspectRatio::snap(int
  $w, int $h): ?string`) so it is unit-testable in isolation.
- **`KvGeneratorFileController::importGenerationFromUpload`** — extract the new
  `width`/`height` from `$request->validated(...)` and pass them to the service.
- **No controller change for Craft sizing** — the existing craft backfill at
  [ThreadController.php:575](../../../api/app/Http/Controllers/Api/Chat/ThreadController.php)
  already reads `data_get($baseGen->metadata, 'aspect_ratio')`, so a supported
  uploaded base sizes Craft correctly with zero further work.
- No new endpoint — reuse
  `POST /v1/studio/kv-generator/files/{id}/generations/import-from-upload`
  ([api.php:2011](../../../api/routes/api.php)).

### web (`alva-intelligence/frnd-web`, branch target `develop`)

- **Empty-state canvas** — add the vertical upload block beneath
  `KvArtboardPicker` in the `isEmpty` branch of `KvCanvas.tsx`. New small
  component (e.g. `KvUploadBaseBlock.tsx`) owning the file input + drag-drop;
  it calls the existing `uploadAttachment.ts` → `import-from-upload` →
  returns the new generation id, which becomes the active base.
- **Reuse, don't reinvent** — the upload→S3→register-as-generation chain
  already exists (`uploadAttachment.ts`, `promoteAttachmentToBase.ts`).
  Extract/share the "register as base" step so the canvas entry point and
  the chat-promotion path use one helper.
- **Measure dimensions before import** — in the new upload block, load the
  picked file into an `Image`/`createImageBitmap` to read `naturalWidth`/
  `naturalHeight`, then pass them to `importKvGenerationFromUpload`
  (extend its body type + `promoteAttachmentToBase`).
- **Craft gate** — the base is extreme when `metadata.imported_from_upload`
  is true and `metadata.craft_supported === false`. Feed that into the
  `craftStatus` computation ([KvGeneratorLayout.tsx:699](../../../web/src/components/studio/kv-generator/KvGeneratorLayout.tsx))
  so the Start Crafting pill / craft Design send disable, and emit the
  proactive chat warning.
- **Upscale stays enabled** regardless of ratio (`useUpscales` has no
  model/ratio guard today — keep it that way).

### ai-service

None for Phase 1.

## Phase 2 (noted, out of scope here)

Support Craft at arbitrary aspect ratios by routing extreme-ratio bases
through the existing `kv_resize` outpaint/reframe pipeline (polish at the
nearest supported ratio, then outpaint back to the true banner aspect).
Bigger build + more credits — deferred until there is demand.

## Resolved decisions

- **Snap rule:** nearest of {1.0, 1.5, 0.67}; gate Craft only when off by
  > 25% (relative).
- **Dimension source:** client-measured `width`/`height`, server-validated.
  No new image library (composer has no Intervention/Image; `getimagesize`
  on remote URLs is avoided).
- **Upscale on `user_upload`:** `useUpscales` has no model/ratio guard today,
  so upscale already works on uploaded bases — no change needed, just don't
  add a guard.
