---
title: KV Generator — Bounding-Box Edit (Inpainting)
slug: kv-bounding-box-edit
author: daffa
created: 2026-04-23
status: draft
services: [web, api, ai-service]
---

## Overview

Let users iterate on a generated KV by selecting one or more rectangular
regions on the canvas, optionally attaching a per-region prompt, then
sending a global prompt. The AI edits **only** the boxed regions and leaves
everything else intact (inpainting).

## User flow (ref: Figma 5223:*)

1. On a file with at least one generation, user clicks the **marquee tool**
   (`SelectionPlus` icon) in the bottom center pill → canvas enters "select"
   mode. Cursor becomes a crosshair.
2. User drags to draw bounding boxes over the current generation. Each box:
   - Gets a numbered badge (`1`, `2`, …) anchored bottom-center.
   - Has a small inline popover ("Add prompt… / Save") that lets the user
     attach a per-box instruction. The popover can stay empty.
3. Each drawn box surfaces in the chat input as part of an aggregate chip
   `□ N selection`. Clicking the chip opens a modal listing each box with
   its per-box prompt (read-only for v1).
4. User types a **global prompt** ("And change the color") and hits Send.
5. Backend runs an inpainting call over the base image, constrained to the
   union of the boxes. A new version is produced (Version N+1).
6. After the `kv_generation_done` event, **selections are cleared** so the
   next turn starts fresh.

## Data model

### Bounding box (wire format)

```ts
{
  id: string;               // client-generated, stable for this turn only
  // Normalized coords (0–1) relative to the BASE GENERATION's natural
  // dimensions — survives canvas resizes and DPR changes.
  x: number;
  y: number;
  width: number;
  height: number;
  prompt?: string;          // optional per-box instruction
}
```

### Stream request additions

New fields on `POST /v1/threads/{id}/stream` (KV generator branch only):

```json
{
  "mode": "edit",
  "message": "And change the color",
  "base_generation_id": "gen_...",
  "bounding_boxes": [
    { "id": "b1", "x": 0.12, "y": 0.08, "width": 0.35, "height": 0.45,
      "prompt": "make her hair red" }
  ]
}
```

- `mode: "edit"` is a new literal alongside `"chat"` and `"image"`.
- `base_generation_id` tells the backend which version's image to start
  from. Defaults to the thread's latest generation when omitted.
- Global prompt is still `message`. Per-box prompts live inside each box.

## Backend

### API (Laravel)

- `StreamChatRequest`: add `mode = "edit"`, `base_generation_id`, and a
  validated `bounding_boxes` array (each box: `x/y/width/height` floats in
  `[0,1]`, optional `prompt` string).
- `ChatService::streamKvGenerator`: accept the new args and forward them
  to ai-service in the POST body.

### ai-service (FastAPI)

- `request_schema.py::KvStreamRequest`: extend `mode` Literal to include
  `"edit"`; add `base_generation_id: Optional[str]` and `bounding_boxes:
  List[BoundingBox]`.
- `service.py`: add `_run_edit_mode(request, ...)` branch alongside
  `_run_chat_mode` and `_run_image_mode`.
  - Resolves the base image URL (fetch via `api_client` from
    `base_generation_id`, or the thread's latest generation).
  - Builds a global prompt that blends per-box instructions with the
    user's message (e.g. `"Apply these edits: [Box 1] make her hair
    red. [Box 2] swap shirt for denim. Global intent: and change the
    color."`).
  - Generates a mask PNG (see below) and calls a new
    `perform_image_editing_with_mask`.
- `edit_image.py`: extend `edit_image` to accept an optional `mask_path`
  (or `mask_bytes`). When present, include it as the `mask` multipart
  field on the OpenAI `/v1/images/edits` call. Leave existing
  mask-less behaviour unchanged for other callers.

### Mask generation

Server-side in ai-service, using Pillow:

```python
from PIL import Image, ImageDraw

def build_mask(boxes, width, height) -> bytes:
    mask = Image.new("RGBA", (width, height), (0, 0, 0, 255))  # opaque = keep
    draw = ImageDraw.Draw(mask)
    for b in boxes:
        x1 = int(b.x * width)
        y1 = int(b.y * height)
        x2 = int((b.x + b.width) * width)
        y2 = int((b.y + b.height) * height)
        draw.rectangle([x1, y1, x2, y2], fill=(0, 0, 0, 0))  # transparent = edit
    buf = io.BytesIO()
    mask.save(buf, format="PNG")
    return buf.getvalue()
```

OpenAI's `images/edits` treats **transparent pixels as regions to edit** —
so opaque black everywhere except transparent rectangles over the user's
boxes. Must match the source image's pixel dimensions exactly, so we
probe the base image once before building.

## Frontend

### Tool state

In `KvCanvasBottomNav`, the existing `tool` state already flips between
`"cursor"` and `"frame"`. Lift it (or mirror it) to `KvGeneratorLayout`
so `KvCanvas` / `KvKonvaCanvas` can react.

### Canvas drawing (Konva)

In `KvKonvaCanvas` when `tool === "frame"`:

- Disable the image transformer.
- `onMouseDown` on empty stage → start a new box with `{x: pointer.x,
  y: pointer.y}`.
- `onMouseMove` during drag → update the box's `{width, height}`.
- `onMouseUp` → commit the box to state if `width > 10 && height > 10`,
  else discard.
- Existing boxes rendered as dashed blue `<Rect>` with a circular
  numbered badge at the bottom-center.
- Clicking a committed box → selects it (same Transformer as the image
  case, but for the box node), and shows the inline "Add prompt / Save"
  popover anchored to its bottom edge.
- Normalize coords to `[0,1]` against the image's natural size (NOT the
  stage size) on commit.

### Chat input chip

In `KvChat`, when `boxes.length > 0` show a chip above the textarea:

```
□ 2 selection
```

Click → opens `SelectionSummaryModal` listing each box with its
per-box prompt (read-only, delete button per row is a v2 nice-to-have).

### Send

On send, when `boxes.length > 0` we send `mode: "edit"` with the boxes
array in the body. After `kv_generation_done` fires, clear local
`boxes` state.

### Model lock (provider must be OpenAI)

Only OpenAI's `images/edits` endpoint supports a mask parameter in our
stack — Nano Banana / Flux / Seedream don't have a compatible mask API.
When `mode === "edit"` is in play, enforce three layers of defense:

1. **Frontend UX** — when `boxes.length > 0`, `ModelButton` filters the
   dropdown to OpenAI-provider image models only. If the currently
   selected model isn't OpenAI, auto-switch to the first OpenAI image
   model and surface a short inline hint.
2. **API validation** — `StreamChatRequest` rejects `mode === "edit"`
   with a non-OpenAI `image_model` via the `withValidator` hook, with a
   clear error code the frontend can render.
3. **ai-service guard** — `_run_edit_mode` validates
   `request.image_model_provider === "openai"` before calling
   `edit_image` and yields a `kv_generation_failed` event with
   `error_code: "provider_unsupported"` otherwise.

The three layers exist because: (a) UX prevents the error in normal use,
(b) API catches direct API consumers and stale frontends, (c) ai-service
is the final belt-and-braces guard.

### Per-box prompt composition

OpenAI's `/v1/images/edits` accepts a **single text prompt** — there's no
per-region prompt API. Three possible shapes:

| Option | Calls | Latency | Notes |
|---|---|---|---|
| **A. Merged prompt + union mask** ✅ v1 | 1 | 1× | Simple, predictable, cheap |
| B. One call per box, composited | N | N× | Per-box specificity but visible seams |
| C. Structured prompt with region descriptions | 1 | 1× | Unreliable region mapping |

**v1 ships with option A.** ai-service merges prompts like:

```
[Region 1 — top-left, 35%×45%]: make her hair red.
[Region 2 — center]: swap shirt for denim.
Additional intent: and change the color.
```

Region labels ("top-left", "center") are derived from the box centroid:
divide the image into a 3×3 grid and pick the grid cell the centroid
falls in. This gives the model a coarse spatial hint without inventing
pseudo-coordinates it may misread.

If later feedback shows per-region specificity matters, we add a
"Precise edits" toggle that fans out to option B.

### Base image passing

API pre-resolves the base generation and includes it in the ai-service
payload (matches the existing `prefetched` pattern — avoids
`artisan serve` deadlocks):

```json
"base_generation": {
  "id": "gen_...",
  "image_url": "https://.../generated_image_...png",
  "natural_width": 1024,
  "natural_height": 1024
}
```

ai-service uses `image_url` directly for the edit call and
`natural_width/height` to size the mask pixel-matched to the source.
No callback, no probing.

### Out of scope for v1

- Reference file attachment (separate feature).
- Editing a per-box prompt after it's saved.
- Resizing / repositioning committed boxes (boxes are immutable once
  drawn; user can delete + redraw).
- Non-rectangular selection shapes (lasso, brush).

## Phasing

1. **Spec sign-off** (this doc).
2. **Web: marquee tool + box drawing** — local state only, Send still
   uses `mode: "image"`. Verifiable visually.
3. **Backend: `mode: "edit"` wire-up** — API validation, ai-service
   schema, mask generation, `edit_image` mask support. Stub the actual
   OpenAI call behind an env flag so we can test without burning
   credits.
4. **Web: chat input chip + send payload** — flip to `mode: "edit"` when
   boxes exist; wire the SelectionSummaryModal.
5. **End-to-end smoke** — draw box(es), send, confirm Version N+1 only
   changed the boxed region, confirm selections clear post-success.
6. **Polish** — empty/error states, cursor styling, badge z-ordering
   with multiple overlapping boxes.
