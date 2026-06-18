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

**Tolerance = ±10%.** Convert each ratio to a decimal (`width / height`):
supported targets are `1:1` = 1.0, `3:2` = 1.5, `2:3` = 0.67. The uploaded
aspect snaps to the nearest target when the relative difference is ≤ 10%;
otherwise it is treated as extreme (Craft gated). Examples: 1.6 → 3:2 (~7%,
snaps, Craft works); 3.44 banner → nearest 3:2 is ~129% off (extreme, Craft
gated). When within tolerance, the canvas snaps to that supported ratio for
the Craft output.

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

- **`KvGenerationService::persistImportFromUpload`** — probe the uploaded
  image (`getimagesize` on the S3 object or accept client-reported
  dimensions validated server-side) and persist `width`, `height`, and a
  derived `aspect_ratio` string into `metadata`. Keep existing keys.
- **Import request/controller** — accept optional `width` / `height` in the
  payload (validated), or resolve them server-side; do not trust unbounded
  client values.
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
- **Ratio detection + Craft gate** — derive the uploaded base's supported
  ratio (or "unsupported") from the persisted dimensions. When unsupported,
  disable the Craft action (Start Crafting pill + craft Design send) and
  emit the proactive chat warning.
- **Upscale stays enabled** regardless of ratio.

### ai-service

None for Phase 1.

## Phase 2 (noted, out of scope here)

Support Craft at arbitrary aspect ratios by routing extreme-ratio bases
through the existing `kv_resize` outpaint/reframe pipeline (polish at the
nearest supported ratio, then outpaint back to the true banner aspect).
Bigger build + more credits — deferred until there is demand.

## Open Questions

1. **Upscale on `user_upload` generations** — verify the upscale start path
   (keyed on `kv_generation_id`) has no guard that rejects rows with
   `model = 'user_upload'`. If it does, relax it.
2. **Dimension source** — probe server-side from the S3 object (robust,
   one fetch) vs. accept client-measured dimensions (cheaper, must be
   validated). Lean server-side unless it adds meaningful latency.
