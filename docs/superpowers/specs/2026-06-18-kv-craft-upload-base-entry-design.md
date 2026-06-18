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

3. **Our code pins craft size to three legacy labels.** `OPENAI_SIZE_BY_RATIO`
   ([edit_image.py:76](../../../ai-service/app/tools/edit_image.py)) only maps
   `1:1`/`16:9`/`9:16` — a gpt-image-1 relic. The product runs **gpt-image-2**,
   which accepts **flexible** dimensions (≤ 3:1, /16, edge ≤3840) on edits too
   (verified). Because we don't send an explicit conformed size for an uploaded
   base, craft falls back to `size=auto`, which does **not** preserve the input
   ratio (verified: square in → 3:2 out) — that is why a wide banner came back
   portrait. Only ratios **> 3:1** are a true model limit (HTTP 400).

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

### Custom-size handling — preserve the base ratio

**Core principle: craft output aspect ratio MUST equal the base image's
aspect ratio.** On import the API persists the base's real dimensions; craft
then renders at those dimensions (conformed) so the polish matches what the
user uploaded.

**Model capability (verified empirically, 2026-06-18).** The product uses
**gpt-image-2**, which — unlike gpt-image-1's three fixed sizes — accepts
**flexible output dimensions** on both `generations` and `edits`:

- edge ≤ 3840 px, both edges a multiple of 16
- total pixels in [655 360, 8 294 400]
- long:short aspect ratio ≤ **3:1**

Empirical test: an `images/edits` call with `model=gpt-image-2`,
`size=1536x768` (2:1, not one of the legacy three) returned a 1536×768 image.
A call with `size=auto` did **not** preserve the input ratio (square in →
3:2 out). So the rule is: **send an explicit conformed size; never rely on
`auto`.** (The old `OPENAI_SIZE_BY_RATIO` three-entry map is a gpt-image-1
relic and is the real bottleneck — not the model.)

**Behavior by ratio:**

| Base aspect (long:short) | Craft | Upscale |
|---|---|---|
| ≤ 3:1 (the vast majority — 1:1, 4:3, 3:2, 16:9, 2:1, up to 3:1) | **Works; output ratio = base ratio** (explicit conformed size) | Works |
| > 3:1 (e.g. 3.44:1 banner) | **Gated** — model can't render beyond 3:1; chat warning, Craft disabled on every path (pill + chat Design) | **Works** (ratio-preserving) |

**`craft_supported`** = base ratio within `[1/3, 3]`. Only ratios beyond that
are gated; true preservation of > 3:1 needs outpaint (Phase 2).

**Conform** (base `w×h` → output size string): clamp ratio to `[1/3, 3]`, pick
edges on that ratio targeting ~1.5 MP, round each edge to a multiple of 16,
keep within the pixel/edge bounds. Same ratio in → same ratio out (within /16
quantization).

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

## Phasing

- **This iteration (Phase 1):** ratio preservation for **≤ 3:1** bases — the
  vast majority of uploads. ai-service sends an explicit conformed size; the
  craft output ratio equals the base ratio. `> 3:1` bases are **gated as an
  interim** (blocked on every craft path + warning + upscale/download) so the
  OpenAI 400 never reaches the user.
- **Next iteration (Phase 2):** replace the `> 3:1` gate with **outpaint** —
  craft at 3:1, then extend the canvas to the true ratio via the existing
  `kv_resize` pipeline. This is the chosen long-term behavior for `> 3:1`.

## Implementation

### api (`alva-intelligence/frnd-api-php`, branch target `develop`)

- **`ImportKvGenerationFromUploadRequest`** — accept `width` and `height`
  (required integers, `min:1`, sane `max`). The web measures them from the
  uploaded image before calling import (client-measured + server-validated,
  no new image library).
- **`KvGenerationService::persistImportFromUpload`** — accept `width`/`height`
  and persist into `metadata`, keeping existing keys:
  - `width`, `height` (raw px)
  - `craft_supported` — bool = base ratio within `[1/3, 3]`
- **`KvAspectRatio` helper** — replace the old snap-to-three logic with a
  simple `isSupported(int $w, int $h): bool` (ratio within `[1/3, 3]`). No
  more `"16:9"`-style label snapping; ai-service derives the exact size from
  the base image. (Remove/repoint the `snap()` + its unit test accordingly.)
- **`KvGeneratorFileController::importGenerationFromUpload`** — forward the new
  `width`/`height` to the service.
- No new endpoint — reuse
  `POST /v1/studio/kv-generator/files/{id}/generations/import-from-upload`
  ([api.php:2011](../../../api/routes/api.php)).

### ai-service (`alva-intelligence/frnd-ai-services`, branch target `development`)

- **Conform + explicit size for craft.** In the craft img-to-img path
  ([service.py](../../../ai-service/app/agents/kv_generator/service.py) →
  [edit_image.py](../../../ai-service/app/tools/edit_image.py)), derive the
  output `size` from the **base image's actual pixel dimensions** conformed to
  gpt-image-2's constraints (clamp ratio to `[1/3, 3]`, edges /16, edge ≤3840,
  total px in [655 360, 8 294 400]) and send it **explicitly**. **Never rely on
  `size=auto`** — verified to drift (square in → 3:2 out).
- **Replace `OPENAI_SIZE_BY_RATIO`** (the gpt-image-1 three-entry relic) so the
  size resolver accepts an explicit `"W×H"` pixel string for gpt-image-2; keep
  the three labels as a fallback for legacy/sketch callers.
- Empirically verified (2026-06-18): gpt-image-2 `edits` honors `1536×768`
  (2:1) and `1536×512` (3:1); `2048×592` (3.46:1) returns
  `400 "maximum supported aspect ratio is 3:1"` — hence the `> 3:1` gate.

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
- **Craft gate (> 3:1 only, interim)** — the base is gated when
  `metadata.imported_from_upload` is true and `metadata.craft_supported ===
  false`. This must block **every** craft-image path so the OpenAI 400 never
  fires:
  - `craftStatus` → `disabled` ([KvGeneratorLayout.tsx](../../../web/src/components/studio/kv-generator/KvGeneratorLayout.tsx)) — disables the Start Crafting pill (done) and suppresses the overlay (done).
  - **the chat "Design" send** — block the freeform craft-image send in
    `onSend` when the base is unsupported (the currently-open gap), showing
    the warning instead of sending. Brainstorm/chat stays allowed.
  - proactive chat warning on import of a `> 3:1` base.
- **Upscale stays enabled** regardless of ratio (`useUpscales` has no
  model/ratio guard today — keep it that way).

## Phase 2 (next iteration — the chosen `> 3:1` behavior)

Replace the `> 3:1` gate with **outpaint**: craft at 3:1 (the model's max),
then extend the canvas left/right to the base's true ratio via the existing
`kv_resize` outpaint pipeline — so even a 3.44:1 banner keeps its real ratio.
Bigger build (multi-service, extra credits); tracked as the follow-up to this
spec.

## Resolved decisions

- **Supported range:** craft preserves the base ratio for **≤ 3:1** by sending
  an explicit conformed size to gpt-image-2 (verified). Only `> 3:1` is gated
  (interim) → outpaint in Phase 2. The old snap-to-three / ±25% rule is
  dropped (it was a gpt-image-1 assumption).
- **Never use `size=auto`** for craft — it does not preserve the input ratio
  (verified). Always send an explicit conformed `W×H`.
- **Dimension source:** client-measured `width`/`height`, server-validated.
  No new image library.
- **Upscale on `user_upload`:** `useUpscales` has no model/ratio guard — upscale
  already works on uploaded bases; don't add a guard.
