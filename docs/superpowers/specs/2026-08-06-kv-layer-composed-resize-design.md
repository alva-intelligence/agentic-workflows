# KV Studio — Layer-composed KVs (PSD import) must not be resized as flat images

**Date:** 2026-08-06
**Author:** daffa
**Services:** web, api, ai-service
**Status:** approved

## Problem

A KV imported from PSD (or produced by Magic Layers) stores its artwork as
overlay layers, not as pixels in the generation's `image_url`. Every feature
outside the browser canvas reads `image_url` and therefore sees a blank canvas.

Observed on studio file `01kzar3cmrs33p5mwfxgwq7k3v`:

| Fact | Value |
|---|---|
| Generation `01kzar5pbemja1d6r9wxx5vrzn` | `model: user_upload`, `image_url` = `WF - V SAFE AREA.png` |
| That file | 1080×1920 RGBA, 48 KB, visually blank (a safe-area guide) |
| `studio_files.overlays` | 15 `type: image` overlays — `BG`, `HEADLINE`, `LOGO SIMPATI`, … |
| Export `01kzar8xgj0014fr6cevz7pqst` | `tiktok-video`, 1080×1920, `status: done`, `model: gpt-image-2` |
| Export `01kzar8xgv35mewab48xc40dp1` | `youtube-thumbnail`, 1280×720, `status: done`, `model: gpt-image-2` |

Both export PNGs were downloaded from S3 and are blank: the TikTok tile is a
white field with a thin painted border, the YouTube tile an empty studio
backdrop. Neither carries any KV content. Both rows report success with no
error, so nothing surfaces the failure.

The canvas looks correct because the browser composites base + overlays live.
The stored artifact never does.

### Root cause

`ProcessKvResizeExportJob.php:54` sends only the base generation image:

```php
'source_image_url' => $row->parentGeneration->source_image_url
    ?: $row->parentGeneration->image_url,
```

There is no compositing step, and the export row's `overlays` column is `NULL`
(it is written only by the post-generation PATCH at
`KvResizeExportController.php:183`). ai-service outpaints a blank canvas and
returns a blank result.

The routing inside ai-service explains the shape of each blank tile. The TikTok
tile matched orientation with zero aspect delta, so it took a crop-then-outpaint
path through `fit_inside_target(..., frame_px=32)` (`canvas.py:78`), which
shrinks the source and lets the model paint the reserved ring. The YouTube tile
flipped orientation, routing to mask-free `ai_reframe`, so the model invented an
empty scene.

### Blast radius

The same field is read by five other consumers, all of which only know how to
fetch a URL:

| Call site | Consequence for a layer-composed KV |
|---|---|
| `KvResizeExportController.php:315` | ZIP download zips blank bytes |
| `GenerateKvMotionJob.php:41` | Motion animates a blank canvas |
| `ProcessKvGenerationUpscaleJob.php:43` | Upscale of the master upscales blank |
| `ProcessKvResizeExportUpscaleJob.php:44` | Upscale of a tile upscales blank |
| `ThreadController.php:752` | Chat/Craft sends a blank image to the model, so AI edits operate on nothing |

`KvGeneratorFileController.php:444` and `:495` copy `image_url` when duplicating
a generation, propagating the blank base to new versions.

Resize is where it was noticed; it is not where it is confined.

## Decisions

| Question | Decision | Reasoning |
|---|---|---|
| How does resize handle a layer-composed KV? | Deterministic layer re-layout, no AI call | The artwork is already vector-like data. Re-positioning is exact, instant, free, and keeps text crisp — an image model can only approximate it. |
| What happens to the background on aspect change? | Scale to cover, crop the overflow | Matches artboard resize in Figma/Canva. Predictable and requires no generation. |
| Do layers stay editable on a resized tile? | Yes | Tiles already support their own overlay snapshot; per-size tweaks are the point of importing layers. |
| How is a layer-composed KV identified? | `layer_composed: true` on generation metadata at import, with a fallback heuristic for existing rows | Explicit provenance beats guessing. The heuristic exists only to rescue KVs already in the database. |
| Where do flat pixels come from? | Assembled on demand, never stored as a derivative | Layers are edited after import in practice, so any stored copy goes stale. A stale copy reproduces exactly today's bug: the stored file silently disagrees with what the user sees. |
| Where does the compositor live? | ai-service | `stamp_logo` (`service.py:261`) already composites a positioned image onto a KV in production. PIL and `save_bytes_to_file` are there, and every AI job already calls ai-service. |

## Non-goals

- **Not changing behaviour for normal AI-generated KVs.** They keep the current
  AI resize path untouched.
- **Not adding a same-size no-op guard.** A separate defect (see Related below).
- **Not re-rendering text with AI.** Text layers are re-positioned, never
  regenerated.
- **Not migrating existing KVs.** The fallback heuristic covers them at read
  time.

## Design

### 1. Marking layer-composed KVs

PSD import and Magic Layers set `layer_composed: true` in the generation's
`metadata` JSON at creation.

For generations created before this change, a fallback classifies a KV as
layer-composed when it has at least one overlay **and** its base image is
effectively blank. "Effectively blank" is decided by downsampling the base and
testing whether its pixel variance falls below a threshold; the result is
memoised on the generation metadata the first time it is computed so the probe
runs once per generation, not once per request.

The classifier is a single function used by both the resize router and the
compositor, so the two can never disagree about what a KV is.

### 2. Resize without AI

When the parent generation is layer-composed, `ProcessKvResizeExportJob` does
not call ai-service. The export row is completed directly with:

- `overlays` — `NULL`
- `image_url` — `NULL` (assembled on demand; see §3)
- `model` — `null`, and no credit charge

Layer projection reuses what already ships:

- **Background layers** scale to cover the target and crop the overflow.
- **All other layers** go through `transformOverlayForAspect`
  (`overlayAspect.ts:56`), the same group-aware projection the canvas uses today.

A layer counts as background when it is the lowest in `z` order *and* covers the
full source canvas. If no layer satisfies both, no cover-scaling happens and
every layer is projected normally — a KV with no true background is a valid
input, not an error.

**Projection is not persisted, and not computed on the server.** The layout
logic lives in web TypeScript, while the resize job runs in PHP — so the job
must not attempt to produce a projected layer set. It does not need to:
`resolveTileOverlays` (`overlayAspect.ts:441`) already projects the master's
overlays onto a tile at render time whenever that tile has no snapshot of its
own. A tile created with `overlays = NULL` therefore renders correctly with no
server-side projection code at all.

A snapshot is written only when the user actually edits layers on that tile,
through the PATCH endpoint that already exists
(`KvResizeExportController.php:183`). From then on `resolveTileOverlays` prefers
the snapshot, so the user's per-tile edits survive. Storing a projection
up-front would be worse than useless: it would freeze the layout and stop the
tile re-projecting if the master changes.

The existing same-aspect fast path (`overlayAspect.ts:466`) keeps an
identical-size resize pixel-exact.

Credit gating: the `check.credits:1` middleware on the route stays, but no
charge is written for a layer-composed resize, because no model runs.

### 3. On-demand compositor

A new ai-service endpoint accepts a base image URL, an ordered layer list (asset
URL, normalised `x`/`y`/`width`/`height`, `rotation`, `opacity`, blend mode) and
target dimensions, and returns a single PNG uploaded to S3.

This is `stamp_logo` generalised from one layer to many: same normalised
coordinate model, same PIL paste with alpha. Layers are fetched concurrently and
composited in `z` order.

Scope limit: the compositor handles `type: image` layers, which is what PSD
import produces. `text` and `shape` overlays are out of scope for this spec — if
a tile carries one, the compositor reports it rather than silently dropping it,
and the caller falls back to the browser-rendered download path.

Callers assemble at the moment they need pixels and do not persist the result as
the canonical `image_url`:

- ZIP download composites each layer-composed tile before zipping
- Motion, Upscale (master and tile), and Chat/Craft composite before dispatching
- Non-layer-composed KVs skip the compositor entirely and read `image_url`

## Phasing

**Phase 1 — §1 and §2.** Fixes the reported bug. Self-contained: the canvas
already draws layers live, so a tile with no `image_url` renders correctly.

**Phase 2 — §3 plus ZIP download.** Restores file delivery.

**Phase 3 — Motion, Upscale, Chat/Craft.** Closes the silent failures.

Between Phase 1 and Phase 2, ZIP download for a layer-composed KV returns fewer
files or none, because `downloadZip` filters on `whereNotNull('image_url')`.
Today those files are blank, so no correct output is lost — but the failure mode
changes from "blank file" to "missing file", and that is a deliberate,
temporary trade rather than an oversight.

## Testing

Unit, no network:

1. Classifier — explicit `layer_composed` flag wins; blank-base-plus-overlays
   heuristic returns true; artwork base with overlays returns false.
2. Background cover projection — a full-canvas background on a 1080×1920 →
   1280×720 change fills the target and crops symmetrically.
3. Identical dimensions — projection returns the layer set unchanged.
4. No background layer present — every layer projects normally, no crash.
5. Resize job — a layer-composed parent dispatches no ai-service call and
   writes no credit charge.
6. Compositor — layers land at their normalised positions in `z` order; a
   `text` or `shape` layer is reported rather than dropped.

Manual: import the PSD used in the bug report, resize to TikTok and YouTube
Thumbnail, confirm both tiles show real artwork, then move a layer on one tile
and confirm the master is unaffected.

## Risks and limits

**Assembly cost.** The largest file in the database carries 63 overlays, so a
worst-case composite means 63 S3 fetches. Concurrency helps, but ZIP over many
tiles is the case to watch.

**More than one full-canvas layer.** The reported KV has four layers wider than
the canvas — a background plus subject and scene elements. Only the lowest-`z`
one is cover-scaled; the rest are projected normally, which may reposition a
full-bleed subject differently from the backdrop behind it. Worth eyeballing on
the real file before deciding whether cover-scaling should extend to every
full-canvas layer.

**Blank-base heuristic.** A KV whose base is legitimately near-uniform (a solid
colour backdrop) could be misclassified as layer-composed and routed away from
AI resize. Memoising the probe bounds the cost, but the false-positive shape
should be checked against real data before Phase 1 ships.

**Edit-frequency evidence is thin.** All 14 overlay-bearing files in the dev
database were updated more than two minutes after creation, which motivated
rejecting a stored derivative. `updated_at` moves for reasons other than layer
edits, and 14 rows is a small sample; the conclusion is directionally supported,
not proven.

## Related defects (out of scope, tracked separately)

**No same-size short-circuit.** A 1080×1920 → 1080×1920 AI resize is not a
no-op. `_INNER_SHRINK_RATIO = 0.95` (`service.py:54`) deliberately shrinks a
source that already covers the target so the outpaint mask is non-empty, with
the stated motivation that "every resize goes through the AI so credit metering
fires consistently" (`service.py:13`). Normal AI KVs therefore lose ~5% scale
and gain a repainted border on an identical-size resize. Changing it needs a
metering decision, not just a code change.

**`KV_RESIZE_RESTRUCTURE` is on locally.** `api/.env:242` sets it `true` while
`config/services.php:307` and `.env.example` default it `false`. It routes
text-bearing KVs to mask-free regeneration whose prompt orders the model to
"Reposition and rescale each text element", which re-typesets copy. Unrelated to
the blank-tile bug, but it will distort normal AI resizes on this machine.

**Duplicate platform dimensions.** `instagram-story` and `tiktok-video` are both
1080×1920 in `config/studio.php` with no deduplication, so selecting both
renders and bills twice for identical output.
