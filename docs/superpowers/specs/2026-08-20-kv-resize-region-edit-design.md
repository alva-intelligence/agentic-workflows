# KV Resize — Region Edit (frame tool parity with Craft)

**Date:** 2026-08-20
**Author:** daffa
**Services:** web, api, ai-service
**Status:** draft

## Problem

Craft has a **frame tool**: drag a marquee over the artwork, type a prompt on
the box, and the render model repaints only that region — pixels outside the
selection survive. Click-to-select refines the box to the object's actual
outline (`polygon`), or to per-glyph contours for text (`rings`), so the mask
hugs the subject instead of a crude rectangle.

Resize has none of it. `KvTileOverlayEditor` documents the gap literally:

> Active canvas tool. Default "cursor" keeps the existing select behavior.
> "image" / "text" repurpose stage clicks as placement callbacks. **"frame" is
> a no-op in Resize.**

So when a resize tile comes back with something wrong in one corner — a face
stretched by the reframe, a logo the outpaint invented — the only remedy is
regenerating the whole tile through `additional_prompt` and hoping. There is no
way to point at the bad region.

This was reported as "bounding box di Resize tidak bisa berjalan". It is not a
bug. The feature was never built on that surface.

## Non-goals

- **The master/original row.** Scope is result tiles only. Master-row editing
  already has its own gated path (`KV_RESIZE_MASTER_EDIT`) and its own
  push-to-all-tiles semantics; mixing region edits into it is a separate
  decision.
- **Persisting boxes.** Boxes are an edit affordance, exactly as in Craft.
  They live in client state and die with the session.
- **Motion.** Untouched.
- **Craft behaviour.** The shared-module extraction below must be
  behaviour-preserving for Craft.

## Why this cannot reuse the Craft pipeline as-is

Craft's region edit is keyed to a **generation** at every layer:

| Layer | Key |
|---|---|
| Detection endpoint | `kv-generator/files/{id}/generations/{generationId}/detect` |
| Detection cache | `kv_generations.metadata.detected_objects` |
| Edit request | `base_generation_id` (validated `exists:kv_generations,id`) |
| Transport | the chat stream (`StreamChatRequest` → `ChatService`) |

A resize tile is a `kv_resize_exports` row. It has `parent_generation_id` and an
`image_url`, but **no generation of its own**. Nothing in the Craft path has a
key to hold onto.

Two alternatives were considered and rejected:

- **Promote tiles to generations.** Generations feed Craft's board canvas,
  version history, Motion and upscale. A resize tile would surface as a Craft
  board. Rejected — the blast radius is the entire KV surface.
- **Route through the chat stream with the tile as base.** `base_generation` is
  a generation object and chat results are written back as generations, so the
  same leak occurs, plus a conversation-turn semantic that does not fit a tile.
  Rejected.

**Chosen: a region edit is a new operation on a resize export**, living entirely
inside the Resize pipeline.

## Architecture

```
web                      api                          ai-service
───                      ───                          ──────────
frame tool on tile
  → boxes[] (per tile)
  → prompt per box
  → "Apply edit"
        │
        └─ POST .../resize-exports/{export}/edit-region
                          │
                          ├─ validate bounding_boxes.*
                          ├─ status := generating
                          └─ dispatch ──────────────→ POST /ai/kv-resize-region-edit
                                                          │
                                                          ├─ download TILE image
                                                          ├─ probe real w×h
                                                          ├─ build mask (shared)
                                                          ├─ OpenAI images/edits
                                                          └─ upload
                          ┌───────────────────────────────┘
                          └─ POST kv-resize-exports/completed (existing callback)
```

The callback is the one Resize already uses, so tile status, the SSE stream and
the UI's `generating → done | failed` handling need no new machinery.

### Component 1 — web: the frame tool

**`KvTileOverlayEditor`** gains `boxes?: KvBoundingBox[]` and
`onBoxesChange?: (next) => void`, mirroring the props `KvFabricCanvas` already
exposes for Craft. `tool === "frame"` stops being a no-op and seeds a
rubber-band marquee on the tile's Konva stage, committing normalized `[0,1]`
coordinates against the tile frame — the same convention `KvBoundingBox` uses
everywhere else.

**`KvResizeCanvas`** owns `boxesByExportId: Record<string, KvBoundingBox[]>`.
Keying by export id is what keeps a box drawn on the Instagram Story tile from
appearing on the LinkedIn tile. State is ephemeral.

**Prompt entry — the same gesture as Craft.** Craft renders an inline prompt
editor on the active box (`activeBoxId` / `promptDraft` inside
`KvFabricCanvas`) and defers sending to the chat composer.

Resize already has that composer. Its guided-regenerate flow arms a tile
(`useKvResizeStore.armedRegenerate`), `KvGeneratorLayout` resolves the armed id
into a `resizeRegenerate` chip carrying `exportId` / `platformLabel` /
dimensions / thumbnail, and Send calls
`regenerateResize.mutate({ exportId, additionalPrompt })`. So no new control is
needed and no new send path: drawing a box **arms that tile**, the box carries
its inline prompt exactly as in Craft, and Send routes to `editRegion` instead
of `regenerate` whenever the armed tile has at least one box. The chip already
tells the user which tile they are about to change.

**Object select.** Clicking inside the tile with the frame tool active runs
detection and offers candidate outlines, as in Craft. Boxes upgraded from a
candidate carry `polygon`, `rings` and `label`.

**Test seam.** jsdom cannot dispatch Konva pointer events, which is why this
file already carries `__testCommitDragEnd` / `__testCommitTransformEnd` props.
Marquee commits follow that established pattern (`__testCommitBoxDraw`) rather
than inventing a new one. Geometry normalization is pure and tested directly.

### Component 2 — api

**Route** (alongside the existing resize-export routes):

```
POST v1/studio/files/{file}/resize-exports/{export}/edit-region
```

**Body:** `bounding_boxes[]`, reusing `StreamChatRequest`'s rules verbatim —
`id` ≤ 64 chars; `x`/`y`/`width`/`height` numeric in `[0,1]`; `prompt` ≤ 2000;
`polygon` ≤ `KvObjectDetectService::MAX_POLYGON_POINTS` (60) pairs; `rings` ≤
`MAX_TEXT_RINGS` (120) rings each shaped like a polygon; `label` ≤ 120. At
least one box is required, matching edit mode's existing guard.

The rules are **extracted into a shared rule provider** consumed by both
`StreamChatRequest` and the new request class, so the two cannot drift — the
120-char `label` cap in particular is already load-bearing for the region header
ai-service composes.

**Detection for tiles.** `kv_resize_exports` has no `metadata` column, so add
one (`json`, nullable) and cache detected objects at
`metadata.detected_objects`, mirroring `kv_generations.metadata.detected_objects`.
Two routes parallel to the generation ones:

```
POST  v1/studio/kv-generator/files/{id}/resize-exports/{export}/detect
PATCH v1/studio/kv-generator/files/{id}/resize-exports/{export}/detections
```

`detect` stays behind `check.credits` exactly as the generation route does.

The two prefixes are deliberate, not an oversight: `edit-region` sits under
`v1/studio/files/{file}/resize-exports/...` with the rest of the resize-export
CRUD, while detection sits under `v1/studio/kv-generator/files/{id}/...`
alongside the generation detect routes it mirrors. Both prefixes already address
resize exports today — tile upscales live under the `kv-generator` one.

**Guards.** Reject unless the export's status is `done` and it has an
`image_url` — a pending, generating or failed tile has nothing to edit.

### Component 3 — ai-service

**Extraction first, behaviour unchanged.** `BoundingBox` (today in
`kv_generator/request_schema.py`) plus `_build_mask`, `_polygon_pixels` and
`_compose_clear_prompt` (today private in `kv_generator/service.py`) move to a
shared module — `app/agents/shared/region_edit.py` — re-exported from their
current homes so Craft's call sites and its existing tests are untouched. This
direction is already idiomatic here: `kv_resize/request_schema.py` imports
`BrandLogoAsset` and `BrandLogoStamp` from `kv_generator.request_schema`.

**New endpoint** `POST /ai/kv-resize-region-edit`, following `kv_resize`'s
structure (`router.py` dispatching a background task in
`service.py`). It downloads the **tile's own** image, probes its true pixel
dimensions server-side rather than trusting the client, builds a mask matched to
those dimensions, calls the OpenAI images/edits path, uploads, and posts to the
existing `kv-resize-exports/completed` callback.

**Model constraint.** Masks are only supported by OpenAI image models —
`kv_generator` already fails closed on this with *"Bounding-box edits require an
OpenAI image model"*. The region-edit path therefore pins an OpenAI model
regardless of what the tile's original resize used (outpaint / gpt-image-2), and
surfaces the same explicit failure if one is unavailable.

## Behaviour on regenerate

A subsequent tile regenerate rebuilds the tile from its source and **discards
the region edit**. Boxes are ephemeral, so nothing is silently lost from a saved
document — but the rendered pixels do disappear. The regenerate control warns
when the tile carries a region edit that has landed.

## Testing

| Layer | What | How |
|---|---|---|
| web | marquee → normalized box; per-tile box isolation; "Apply edit" only when a box has a prompt | `bun test` (bunfig preloads jest-dom); Konva commits via the `__testCommit*` prop seam |
| api | validation parity with `StreamChatRequest`; status/`image_url` guards; dispatch + callback | Feature tests — require a scratch Postgres (SQLite cannot run these migrations) |
| ai-service | extraction is behaviour-preserving; mask matches probed tile dimensions; non-OpenAI model fails closed | pytest against the shared module + the new service |

Baselines must be captured before any change: web and ai-service both carry
known pre-existing failures, so "green" means *no new red*, measured against a
worktree at HEAD — never via `git stash`.

## Risks

1. **Aspect ratios beyond 3:1.** The masked path does *not* send OpenAI a
   `size`: `edit_image` skips it deliberately because "for the inpainting flow
   OpenAI requires `size` to match the mask's pixel dimensions, and the output
   already inherits them". Since the mask is built pixel-matched to the tile's
   probed dimensions, a 1080×1920 tile returns 1080×1920 — no resampling.

   The real boundary is elsewhere: gpt-image-2 accepts explicit pixel sizes only
   "flexible up to 3:1". The `x-header` preset (1500×500) sits exactly at that
   limit and every custom size is unbounded. Implementation must confirm the
   behaviour at and past 3:1 and fail closed with a clear message rather than
   returning a distorted tile. This is a bounded verification task, not a
   gate on the whole design.
2. **Detection cost on tiles.** Craft caches per generation; a file with twelve
   tiles has twelve independent caches, so the same artwork may be detected
   repeatedly. Mitigated by the cache column, not eliminated.
3. **Throwaway UI.** `feature/alva/vc-kv-fabric-export` plans to delete
   `KvTileOverlayEditor` (TASK-27) and move Resize onto the unified Fabric
   canvas, where Craft's marquee already exists. Building the frame tool in
   Konva now is a **deliberate, accepted** cost: the feature ships sooner, and
   the UI is rewritten when the unified canvas lands. The api and ai-service
   work is unaffected by that migration.
4. **Validation drift.** Two request classes sharing one rule set is the
   mitigation; if the shared provider is bypassed, the surfaces diverge silently.

## Open questions

None blocking. Risk 1 is a bounded verification task owned by implementation,
not an unresolved design decision.
