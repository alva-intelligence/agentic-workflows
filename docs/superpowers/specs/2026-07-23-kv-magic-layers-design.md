# KV Magic Layers — Design

**Date:** 2026-07-23
**Author:** daffa (with Claude)
**Status:** Approved design, pending implementation plan

## Summary

"Magic Layers" lets a user drop a flat image into the KV canvas and have the engine
decompose it into separately editable layers — like Canva's Magic Grab. The engine
detects subjects and text, lifts each subject as a pixel-faithful transparent cutout,
lifts text blocks as rectangular image cutouts, inpaints the holes to produce a clean
background, and materializes the result as a base board + image overlays on a KV tile.

## Decisions (from brainstorming)

- **Entry point:** the existing KV upload-base flow (`KvUploadBaseBlock`), not a
  standalone tool and not (yet) generated-KV tiles.
- **Layer types:** subject cutouts (alpha-matted), text blocks as **image cutouts**
  (not editable text), inpainted background as the base board.
- **Interaction:** one-shot auto-decompose (single async job). Click-to-grab
  point-prompting is explicitly out of scope.
- **Credits:** metered like kv-resize via the usage callback; charged **only on
  success**. New operation types `kv_magic_layer` (inpaint) and
  `kv_magic_layer_vision` (detect). The Replicate segmentation stage has no
  token usage, so v1 stores it in the job's `usage_entries` for audit without
  charging; flat per-run pricing is a deliberate follow-up.
- **Engine (Approach A):** detect with a vision LLM → segment with SAM2 (Replicate)
  → inpaint with the already-wired `gpt-image-2` `/v1/images/edits` mask path.
  - Rejected: all-in-one Grounded-SAM (less control over "what counts as a subject",
    community-model maintenance risk); generative decomposition via gpt-image-2
    (regenerates pixels instead of lifting them — breaks fidelity).

## Branching

All implementation starts from the latest remote default branch — **not** from any
currently checked-out feature branch:

| Repo | Base | Feature branch |
|------|------|----------------|
| api | `origin/develop` | `feature/daffa/vc-kv-magic-layers` |
| web | `origin/develop` | `feature/daffa/vc-kv-magic-layers` |
| ai-service | `origin/development` | `feature/daffa/vc-kv-magic-layers` |

Each repo: `git fetch origin && git checkout -b feature/daffa/vc-kv-magic-layers origin/<base>`.

## User flow

1. User drops an image in the KV canvas upload-base entry. Next to the existing
   "use as base" action there is a new **"Separate into layers"** action.
2. The image uploads as a KV attachment (existing `uploadKvAttachment`, existing
   `fetchKvUploadLimits` size limits). Web creates a **magic-layer job** via the API.
   A placeholder tile appears with a loading state (reusing the concept-generation
   placeholder-tile pattern).
3. On completion the tile becomes a base board whose image is the inpainted
   background, with each subject as a transparent-PNG image overlay and each text
   block as a rectangular image-cutout overlay, positioned and z-ordered to visually
   reproduce the original image. Everything is immediately editable through the
   existing tile-aware Layers panel — no Layers-panel changes required.
4. On failure, or when nothing separable is found: fall back to importing the
   original flat image as a plain base (user is never blocked), show a toast,
   charge nothing.

## ai-service pipeline

New module `app/agents/kv_magic_layer/`, following the `kv_resize` shape:
`router.py` (`POST /ai/kv-magic-layer/decompose`, returns `202`, schedules
`BackgroundTasks`) → `service.py` orchestrator → callback to Laravel via an
`api_client.py` `post_completed`, forwarding per-model usage.

### Stage 1 — Detect (vision LLM)

`gpt-4o-mini` (temp 0), new prompt following the `vision_prepass.py` pattern.
Returns:

```json
{
  "subjects": [{ "label": "person", "bbox": [x, y, w, h] }],
  "text_blocks": [{ "bbox": [x, y, w, h] }]
}
```

Guardrails applied in code (not left to the model):

- Cap subjects at **8**, largest area first.
- Drop boxes below a min-area threshold (~1% of frame).
- Merge boxes overlapping above ~70% IoU.
- Skip any "subject" covering more than ~90% of the frame.
- Merge adjacent text blocks; total layers (subjects + text) capped at **12**.

### Stage 2 — Segment (SAM2 on Replicate)

- SAM2 box-prompted with each subject bbox → per-subject alpha mask.
- Model configured via env: `STUDIO_KV_SEGMENT_MODEL` + `STUDIO_KV_SEGMENT_MODEL_VERSION`
  (version SHA pinned — Replicate Public models 404 without a pin).
- Mask cleanup: morphological close + slight feather.
- The model may run on a downscaled copy for cost/latency; masks are upscaled and
  applied at **original resolution**, so cutouts are pixel-faithful crops of the
  user's actual image (RGBA PNG, cropped to bbox).
- Text blocks skip matting entirely: padded rectangular crops (RGBA).

### Stage 3 — Fill (existing gpt-image-2 inpaint)

- Union of dilated subject masks + text rects → one transparent-alpha mask.
- One `gpt-image-2` `/v1/images/edits` call (same code family as bounding-box edit
  and outpaint) with a "remove these elements and fill the background naturally"
  prompt → clean background image.

### Stage 4 — Callback

`post_completed` to Laravel with:

- background image,
- cutout PNGs, each with normalized geometry `{x, y, width, height, z}` in `[0,1]`
  (matching `StudioOverlay` conventions) and a `kind` (`subject` | `text`),
- per-model usage (gpt-4o-mini tokens, Replicate prediction cost, gpt-image-2 usage)
  for credit metering.

Asset transport uses the same mechanism kv-resize uses to hand result images to the
API; the exact transport (multipart vs. storage URL) is verified during planning.

## API (Laravel)

- `POST studio/kv-generator/files/{file}/magic-layer-jobs` — behind
  `feature.flag:show-kv-generator`. Validates the attachment, creates a job row,
  calls ai-service, returns the job.
- `GET studio/kv-generator/files/{file}/magic-layer-jobs/{job}` — polling endpoint.
- **Internal callback** (same auth pattern as the kv-resize callback):
  1. Persists the inpainted background as a base generation via the same service
     path as `importGenerationFromUpload`.
  2. Writes the image overlays (bound to the new `board_generation_id`, normalized
     geometry, z-ordered) into `studio_files.overlays`.
  3. Marks the job `completed` and charges credits through the existing
     usage-metering path (`kv_magic_layer` operation type).

New table `studio_magic_layer_jobs`:
`id, studio_file_id, attachment reference, status (pending|processing|completed|failed),
error, usage/credits fields, timestamps`.

## Web

- `KvUploadBaseBlock` / `KvGeneratorLayout`: new "Separate into layers" action →
  upload attachment → create job → placeholder tile with loading state → poll job.
- On completion: inject the new board into the Yjs doc (same mechanism as
  `promoteAttachmentToBase`) and let overlays flow through the existing overlay
  sync — including the REST-recovery path from the overlay-hardening work, so an
  unreachable Hocuspocus does not lose layers.
- On failure: toast + automatic plain-base fallback (import original image as base).

## Edge cases

- **Zero subjects and zero text** → failure-with-fallback ("couldn't find layers to
  separate"), no charge.
- **Text-heavy images** → adjacent text blocks merged; hard cap of 12 total layers.
- **Very large uploads** → models run downscaled; all outputs re-projected to
  original resolution.
- **Subject fills the frame** → skipped as a subject (it *is* the background).

## Testing

- **ai-service:** unit tests for bbox/mask math, geometry normalization, and layer
  caps; orchestrator test with mocked model clients (no live model calls in CI).
- **api:** unit tests (not Feature — known fresh-migrate suite issue) for job
  lifecycle, callback persistence, and credit charging.
- **web:** `bun test` for new flow logic; `bun run build` as the type gate; manual
  e2e for the full drop → layers experience.

## Out of scope

- Click-to-grab / point-prompted segmentation (possible phase 2; the job API takes
  a full image and returns a full decomposition, so a point-prompt variant can be
  added as a sibling endpoint later).
- Editable text layers (OCR → real text overlays with font matching).
- Decomposing already-generated KV tiles.
