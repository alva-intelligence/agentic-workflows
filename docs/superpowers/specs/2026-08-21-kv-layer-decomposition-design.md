# KV Layer Decomposition (Seedream 5.0 pro) — Design Spec

> **Status:** draft
> **Author:** daffa
> **Created:** 2026-08-21
> **Services:** api, ai-service, web
> **Topic slug:** kv-layer-decomposition
> **Relation to Magic Layers:** built fresh. `feature/daffa/vc-kv-magic-layers`
> (gpt-4o-mini detect → SAM-2 → inpaint) is parked and is NOT a dependency,
> NOT reused, and NOT modified by this work.

## Overview

Let a user take one KV board — or an image they just uploaded as a base — and
have it decomposed into a clean-plate background plus independently editable
layers, using BytePlus ModelArk **Seedream 5.0 pro** (`layer_decomposition`).

The user reviews the returned layers in a panel, picks the ones they want, and
commits them to the canvas as a **new board**: the clean plate becomes the
board image and each selected layer becomes an image `StudioOverlay` positioned
from the model's bounding box.

### Why this model

One API call replaces a three-model chain, and it returns things a
segmentation pipeline cannot:

- The base image is a genuine **clean plate** — every object removed and the
  area behind it reconstructed, per-object rather than through one union mask.
- Occluded geometry is **completed**. Verified on a live run: the sunscreen
  tube came back whole with the holding hand erased, and the model layer came
  back with the tube gone and her fingers redrawn as an empty hand. Layers are
  therefore movable without leaving holes.
- Each layer carries `name` and `description`, which become the Layers-panel
  label with no extra vision call.

### What it is not

This is **generative matting, not segmentation**. The base and every layer are
re-rendered pixels, not crops of the input. That is why the feature never
mutates an approved board (see *Commit*), and why it is wrong for a
fidelity-critical path such as PSD import.

## Verified behaviour

Live run 2026-08-21 against `dola-seedream-5-0-pro-260628`, one frndGlow KV
(1536×1024 PNG), auto mode, no prompt. 8 objects returned, ~110 s,
`usage.output_tokens` 34772. Restacking all 7 layers onto the base using
`bounding_box.absolute` reproduced the input exactly.

| z | layer PNG | `absolute` | `normalized` | name |
|---|---|---|---|---|
| 0 | 1536×1024 | — | — | base image (clean plate) |
| 1 | 766×982 | `[0, 0, 721, 924]` | `[0, 0, 469, 901]` | Window and Desk Background |
| 2 | 622×921 | `[1248, 690, 1473, 1024]` | `[813, 674, 958, 999]` | Purple Office Chair Backrest |
| 3 | 720×232 | `[1287, 170, 1480, 232]` | `[838, 166, 963, 226]` | frndGlow Wall Logo |
| 4 | 794×904 | `[11, 742, 232, 994]` | `[7, 725, 150, 970]` | Purple Vase with Lavender |
| 5 | 880×625 | `[0, 227, 244, 401]` | `[0, 222, 158, 391]` | Purple Desk Lamp |
| 6 | 849×964 | `[496, 60, 1345, 1024]` | `[323, 59, 875, 999]` | Woman Applying Skincare |
| 7 | 386×877 | `[522, 452, 650, 745]` | `[340, 441, 423, 727]` | frndGlow Sunscreen Tube |

Three facts that will cause bugs if missed:

1. **The layer PNG is not the size of its bbox.** Layer 7 is a 386×877 file for
   a 128×293 box. Every consumer MUST scale to `(right-left, bottom-top)`
   before placing. The docs do not mention this.
2. **`bounding_box.normalized` is on a 0–1000 scale**, not 0–1. Divide by 1000
   to reach the `StudioOverlay` convention.
3. **`output_format` controls the base image only.** Layers are always PNG.
   Omit it and the base defaults to JPEG.

## Cost

Layer decomposition is billed at half the single-image rate. Input image is
free (first image). Each returned image is billed separately on its own pixel
tier. Images not output due to moderation are not billed.

| | ≤ 2.61M px | > 2.61M px |
|---|---|---|
| Single image generation | $0.045 | $0.09 |
| Layer decomposition | **$0.0225** | $0.045 |

Measured: the frndGlow run (8 images) cost **$0.18**. A 13-image run cost
$0.315. Unbounded worst case at 2K is $0.765.

**Decision: pin `size: "1.5K"`.** Never send `auto` or `2K`. Every 1.5K aspect
ratio lands under 2.61M px (largest is 1:1 at 1536×1536 = 2.36M), so every
output is guaranteed the cheap tier and cost becomes
`$0.0225 × (1 + layer count)`, capped at $0.3825 for the maximum 16 layers.
With `auto`, a 2K input echoes its own dimensions and jumps tiers. The docs
also state 1.5K costs the same as 1K with better quality, so 1K is never right.

## Scope

### In scope (v1)

- Auto mode only — no prompt, no `<bbox>`. This is the only mode proven to work.
- Two entry points: the tile toolbar of a KV board on the Craft canvas, and
  `KvUploadBaseBlock` after an upload.
- Review panel; user selects layers; commit produces a new board.
- Credit metering on success.

### Out of scope (v1)

- Natural-language and `<bbox>` decomposition control.
- Resize canvas tiles as an entry point.
- Editing a single layer by feeding it back to Seedream.
- Re-decomposing an already decomposed board.

## Architecture

The vendor call lives in **ai-service**, following `KvResizeExport` exactly.
Rationale: when auto mode proves too coarse and we add prompt or bbox control,
that work necessarily lands in ai-service; putting the call in api now only
buys a move later.

```
web   POST /api/studio/files/{file}/layer-decompositions
api   → row status=pending → dispatch ProcessKvLayerDecompositionJob
job   → POST {ai}/ai/kv-layer-decompose {decomposition_id, source_image_url}
ai    → 202 immediately, then BackgroundTask:
          BytePlus layer_decomposition (size=1.5K, watermark=false)
          → download base + N layers
          → mirror to S3 {env}/kv-layer-decompose/{id}/
          → POST {api}/internal/kv-layer-decompositions/{id}/complete
api   → persist base + layers, charge credits (only when status=done)
web   → poll GET .../layer-decompositions/{id}
```

Vendor URLs expire after 24 hours and MUST NOT reach the database. Mirroring
happens before the callback; if mirroring fails, the job fails.

## Data model (api)

New table `kv_layer_decompositions`, ULID + `SoftDeletes`, mirroring
`KvResizeExport`.

| column | notes |
|---|---|
| `id` | ULID |
| `studio_file_id` | owner |
| `source_generation_id` | nullable — the upload-base entry point has no generation yet |
| `created_by` | user |
| `status` | `KvLayerDecompositionStatus`: pending \| generating \| done \| failed |
| `error_message` | nullable |
| `source_image_url` | input image |
| `base_image_url` | clean plate, already mirrored to our S3 |
| `layers` | JSON array (below) |
| `ai_service_run_id` | audit trail, as in resize |
| `model` | vendor model id |
| timestamps, `deleted_at` | |

`layers` entry shape — geometry **normalized 0..1**, converted from
`bounding_box.normalized / 1000` at write time so no consumer repeats it:

```json
{
  "index": 7,
  "name": "frndGlow Sunscreen Tube",
  "description": "Light purple frndGlow daily sunscreen product tube …",
  "image_url": "https://our-s3/…/layer_07.png",
  "z": 7,
  "x": 0.340, "y": 0.441, "width": 0.083, "height": 0.286
}
```

Also add `CostHistoryType::KV_LAYER_DECOMPOSITION`.

### Credit metering

`KvCreditMeteringService::charge()` routes through `PricingHelper`, which
prices images **per 1000 tokens**. Seedream bills **per image**. Feeding
`output_tokens` (34772 on the sample run) into the token formula would produce
a wrong number.

Add a per-image pricing path for `dola-seedream-5-0-pro-260628`:
`images_billed × tier_rate`, where `tier_rate` is chosen per image from its own
`size`. Because v1 pins 1.5K, every image is $0.0225 in practice, but the tier
check must still be implemented — the vendor bills per layer and a future
prompt/bbox mode could return larger layers.

## Commit

Separate endpoint: `POST .../layer-decompositions/{id}/commit` with
`{ layer_indexes: [...] }`.

Layers the user did **not** select must be flattened back onto the clean plate,
or the new board silently loses elements — pick only the tube and the woman
disappears. Flattening is a deterministic composite (scale each unselected
layer to its bbox, alpha-composite in `z` order), placed in **ai-service** as a
synchronous endpoint: no model call, sub-second, and the restack maths is
already proven correct on the Python side. api has no image pipeline.

api then:

1. creates a new `KvGeneration` (a new board on the canvas) with `image_url`
   set to the flattened plate;
2. creates one `StudioOverlay` per selected layer, `type: "image"`, geometry
   straight from the stored normalized bbox, `z` in ascending order,
   `board_generation_id` pointing at the new board.

**The new board is NOT marked `layer_composed`.** In this codebase that flag
means `image_url` is a blank placeholder and all pixels live in overlays, and
`blocksImageGeneration()` refuses upscale and image chat turns on such boards.
A decomposed board has a real clean plate with real pixels, so it is an
ordinary image board that happens to carry image overlays — a shape KV already
supports. None of the layer-composed downstream breakage applies.

## Web

**Entry points.** An action in the KV board tile toolbar (alongside Resize and
Upscale), and an offer in `KvUploadBaseBlock` after an upload completes.

**Review panel.** Right-hand panel listing the base plus every layer, each with
a thumbnail, its `name`, its `description`, and a checkbox defaulting to
checked. Primary action "Add to canvas" calls the commit endpoint.

**Polling.** Follows the existing job-polling pattern, but the window must
cover ~110 s of generation plus mirroring — size it to roughly 225 s rather
than reusing the 180 s default.

**Analytics.** PostHog events ship with the feature, not after it.

## Error handling

| case | behaviour |
|---|---|
| Zero layers returned | `failed` / `no_layers_detected`, not charged |
| Vendor 429 (the 17-IPM up-front debit) | retry with backoff in ai-service |
| Mirroring fails | job fails; no partial row |
| Job throws | `failed` with the message; background task must always call back |
| Input outside limits | reject at request time — png/jpeg only, ≥512×512, ≤30 MB, ratio within [1/16, 16] |

Rate limit: each request debits **17 IPM** up front out of 500/min, refunded
after generation, capping practical throughput near 29 concurrent jobs/min
across all tenants.

## Testing

- **ai-service** — fixture built from the real captured `response.json`. Cover
  the ÷1000 normalization, the scale-to-bbox rule, S3 mirroring, and the
  synchronous flatten endpoint.
- **api** — Feature tests for create, callback, and commit. Requires a scratch
  Postgres; SQLite cannot run these migrations.
- **web** — `bun test` for the review panel, the polling loop, and the
  layer→overlay conversion.

## Rollout

Gated on `config('services.ai.kv_layer_decompose_enabled')`, following the
existing KV toggle convention (`services.ai.kv_resize_vision_prepass`). Both
entry points hide when it is off, and the create endpoint rejects. This keeps
the vendor dependency switchable without a deploy.

## Dependency

The BytePlus ModelArk account and API key are **not provisioned** for any
environment. The runs recorded in this spec used a personal key. Nothing here
can ship until a team key exists for the `ap-southeast` region.
