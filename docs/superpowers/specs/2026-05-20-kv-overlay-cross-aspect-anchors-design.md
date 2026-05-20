---
title: KV Overlay Cross-Aspect Positioning — Edge Anchor Inference
slug: kv-overlay-cross-aspect-anchors
author: daffa
created: 2026-05-20
status: draft
service: web
---

## Overview

When a user places overlays (logos, CTAs, text) in **craft mode** on a KV file and then enters **resize mode** to export the same image at different aspect ratios, overlays drift away from their intended visual relationship to the canvas. A logo that the user flush-aligned to the bottom-right corner in a portrait 940×1700 craft canvas appears with an awkward gap from the corner when transformed to a 1200×630 landscape tile. A CTA that looked appropriately sized in source grows or shrinks in absolute pixel terms on different targets.

This spec proposes a **frontend-only** enhancement to the overlay aspect-transformation algorithm in [overlayAspect.ts](../../web/src/lib/studio/kv/overlayAspect.ts) that:

1. **Infers edge anchors** from each overlay's source position (proximity-based, threshold = 8% of shortest edge), and preserves edge-distances rather than fractional positions when transforming to a target aspect.
2. **Preserves overlay pixel size** across transforms instead of preserving the overlay's fraction of canvas width.

No schema changes, no API changes, no new UI affordances.

## Problem

### Current behavior

`transformOverlayForAspect(overlay, srcW, srcH, dstW, dstH)` in [overlayAspect.ts:40](../../web/src/lib/studio/kv/overlayAspect.ts:40) implements:

- **Width**: unchanged. `new_w = w`. An overlay at `width=0.10` stays `0.10` regardless of target. Pixel size grows/shrinks with target canvas width.
- **Height**: rescaled by `dstAspect/srcAspect` to preserve the overlay's own pixel aspect.
- **x**: untouched. `new_x = x`.
- **y**: preserved as fractional position in vertical free-space (`alpha = y / (1 - height)`).

### Where this breaks

| User intent | Current behavior |
|---|---|
| "Logo flush to bottom-right corner" | Overlay's right-edge distance and bottom-edge distance change in absolute pixel terms when target aspect changes. The logo drifts inward or outward. |
| "Logo with consistent margin to edge" | Margin = fraction of canvas dimension. Same fraction = different pixel margin on different aspects. Visual padding feels inconsistent. |
| "CTA at the prominence I designed" | Width-fraction stays constant. On wider canvases the CTA grows in pixel size; on narrower canvases it shrinks. Visual weight is unstable. |

The user pain explicitly confirmed during brainstorming:
- Anchor edge/corner lepas
- Margin visual ke edge berubah
- Width/size visual gak proporsional

## Approach

**Edge-anchor inference + pixel-size preservation, runtime-computed, no schema change.**

The transform function classifies each overlay's relationship to the source canvas (left/right/center horizontally; top/bottom/center vertically) by proximity, then re-projects the overlay onto the target canvas while preserving:
- Anchor-relative edge distance (in shortest-edge units) for anchored axes
- Center-fractional position for non-anchored axes
- Absolute pixel width and height of the overlay itself

Inference is **stateless** — derived purely from `(x, y, width, height)`. The same overlay state always classifies the same way on the same source canvas. No anchor field is added to `StudioOverlay`.

## Architecture

### Surface area

A single file changes: [web/src/lib/studio/kv/overlayAspect.ts](../../web/src/lib/studio/kv/overlayAspect.ts).

- `transformOverlayForAspect(overlay, srcW, srcH, dstW, dstH)` — body replaced. Signature unchanged.
- `resolveTileOverlays(tileSnapshot, projectOverlays, srcW, srcH, dstW, dstH)` — unchanged.

Call sites are unaffected because the function signature does not change:
- [KvResizeCanvas.tsx](../../web/src/components/studio/kv-generator/KvResizeCanvas.tsx) uses `resolveTileOverlays` to materialize per-tile overlay lists.
- [KvResizeTileStage.tsx](../../web/src/components/studio/kv-generator/KvResizeTileStage.tsx) mirrors the same denormalization math when rendering Konva shapes.

### Out of scope

- No changes to `StudioOverlay` type or DB schema.
- No changes to `useKvOverlaysStore`.
- No new UI (no snap zones, no anchor toggles, no inferred-anchor indicators in the layers panel).
- No changes to tile snapshot logic. `row.overlays` (per-tile snapshots already in tile-frame coords) continue to render as-is.
- No rotation-pivot fix. Rotated overlays still incur a small pivot offset on aspect change — confirmed during brainstorming as not a top pain point.
- No safe-area concept.
- No per-tile divergence/sync UX (e.g., "push project overlays back to all tiles").

## Algorithm

### Step 1 — Compute new pixel-preserved dimensions

```
new_w = w * (srcW / dstW)
new_h = h * (srcH / dstH)
```

Justification: preserves absolute pixel size (`w * srcW` and `h * srcH`) by design. Overlay's pixel aspect is preserved automatically as a consequence.

No clamping. If `new_w > 1` or `new_h > 1` (overlay does not fit the target), values are returned as-is so the user can correct visually in the tile editor. Consistent with current overflow policy.

### Step 2 — Compute edge distances in shortest-edge units

```
shortest_src = min(srcW, srcH)

left_dist   = (x       * srcW) / shortest_src
right_dist  = ((1-x-w) * srcW) / shortest_src
top_dist    = (y       * srcH) / shortest_src
bottom_dist = ((1-y-h) * srcH) / shortest_src
```

All distances are in **shortest-edge units** so threshold comparisons are geometrically meaningful regardless of source aspect.

### Step 3 — Classify horizontal anchor

Threshold `T = 0.08` (8% of shortest edge). A distance is only considered as an anchor candidate when it's non-negative — a negative distance means the overlay overflows that edge, and we don't want to anchor to an edge the overlay is past.

```
left_valid  = left_dist  >= 0 AND left_dist  < T
right_valid = right_dist >= 0 AND right_dist < T

if left_valid AND (NOT right_valid OR left_dist <= right_dist) → anchor_h = 'left',   keep = left_dist
elif right_valid                                               → anchor_h = 'right',  keep = right_dist
else                                                           → anchor_h = 'center', keep = center_frac_x = x + w/2
```

Tie-break at equality favors `'left'`. The `<` comparison on threshold and `<=` on tie-breaking are intentional for deterministic boundary behavior.

### Step 4 — Classify vertical anchor (analogous)

```
top_valid    = top_dist    >= 0 AND top_dist    < T
bottom_valid = bottom_dist >= 0 AND bottom_dist < T

if top_valid AND (NOT bottom_valid OR top_dist <= bottom_dist) → anchor_v = 'top',    keep = top_dist
elif bottom_valid                                              → anchor_v = 'bottom', keep = bottom_dist
else                                                           → anchor_v = 'center', keep = center_frac_y = y + h/2
```

### Step 5 — Project onto target

```
shortest_dst = min(dstW, dstH)

// Horizontal
case 'left':   new_x = (left_dist  * shortest_dst) / dstW
case 'right':  new_x = 1 - new_w - (right_dist * shortest_dst) / dstW
case 'center': new_x = center_frac_x - new_w / 2

// Vertical
case 'top':    new_y = (top_dist  * shortest_dst) / dstH
case 'bottom': new_y = 1 - new_h - (bottom_dist * shortest_dst) / dstH
case 'center': new_y = center_frac_y - new_h / 2
```

### Step 6 — Return updated overlay

```
return { ...overlay, x: new_x, y: new_y, width: new_w, height: new_h }
```

`rotation`, `z`, `payload`, `id`, and all other fields are left untouched.

### No-op guard

Preserve current early returns:

```
if srcW <= 0 or srcH <= 0 or dstW <= 0 or dstH <= 0 → return overlay
if abs(srcAspect - dstAspect) < 1e-6 → return overlay
```

When aspects match — even at different resolutions (e.g. 1024² → 2048²) — the transform no-ops and returns the input overlay reference. The overlay's pixel dimensions naturally scale with the canvas because `width` and `height` are canvas-normalized. Matches user expectation that "same aspect → no transform needed." This also matches the existing `is a no-op when source and target aspect are equal` test case.

## Edge cases

| Case | Behavior |
|---|---|
| Overlay at exact center of source | `center_frac_x = 0.5`, `center_frac_y = 0.5` → centered on target. |
| Overlay corner-anchored (within T on both axes) | Both axes anchored → corner-locked. |
| Overlay at exact threshold (`left_dist == T`) | `<` operator excludes boundary → classified as `center`. Deterministic. |
| Overlay larger than target canvas | `new_w > 1` or `new_h > 1` returned as-is. No clamp. |
| Source has zero-or-negative dimension | Existing guard returns overlay unchanged. |
| Overlay overflows the source canvas (`h > 1` or `w > 1`) | `bottom_dist` (or `right_dist`) is negative. `>= 0` guard rejects negative distances as anchor candidates. The opposite edge (if within threshold) still wins; otherwise falls back to center. Prevents the negative-distance bug where overflow overlays land off-canvas. |
| Same-aspect transform (any resolution) | Early-returned unchanged. Overlay's pixel size scales naturally with canvas. |
| Rotated overlay | Algorithm acts on `(x, y, width, height)` only. Rotation untouched. Konva renders rotation around top-left, so rotated overlays incur a small pivot offset on aspect change — same as current. Out of scope to fix here. |

## Backwards compatibility

- **Tile snapshots** (`row.overlays`) are already in tile-frame coords and bypass the transform via `resolveTileOverlays`. Unaffected. User effort preserved.
- **Project overlays without tile snapshots** render via the new algorithm on every load. Visual positions WILL change for files already in the database. This is intentional — the change is a correctness improvement. Worth flagging in the PR description so FE team is aware.
- **`StudioOverlay` schema unchanged** — no DB migration, no API contract change.
- **No feature flag**. The transform is a pure function. Reversion is a git revert if needed.

## Testing

### Unit tests — [web/src/lib/studio/kv/overlayAspect.test.ts](../../web/src/lib/studio/kv/overlayAspect.test.ts)

Add or update:

1. **Bottom-right anchor preserved** — portrait 940×1700 → landscape 1200×630, overlay near bottom-right corner: assert anchor stays at corner (right-distance + bottom-distance in pixel terms match source).
2. **Top-left anchor preserved** — analogous corner case in the opposite corner.
3. **Centered overlay** — overlay far from all edges: assert `center_frac_x` and `center_frac_y` of source equal those of target.
4. **Mixed: top-anchored + horizontally-centered** — overlay nempel top edge but center horizontally. Top distance preserved; horizontal center fraction preserved.
5. **Threshold boundary** — overlay at exactly `T = 0.08` of shortest edge: assert classified as `center` (boundary excluded by `<` comparison). Lock down determinism.
6. **Pixel size preservation** — `width=0.1` at `srcW=1080` (= 108px); assert `new_w * dstW ≈ 108` across a matrix of target sizes.
7. **Same-aspect early return** — `transformOverlayForAspect(ov, 940, 1700, 1880, 3400)` returns same object reference. Same-aspect, any resolution = no-op (preserves the existing test expectation).
8. **Overflow** — overlay where `w * srcW > dstW`: assert `new_w > 1` returned without clamping.
9. **Existing alpha-preserve test cases** — current tests that lock in `(alpha, width-fraction-stable)` behavior will fail. Update expected values to reflect the new algorithm. Do not delete tests; restate intent.

### Integration verification

- `bun test src/lib/studio/kv/overlayAspect.test.ts` passes.
- Run full `web` test suite: confirm `KvKonvaCanvas.overlays.test.tsx` and other downstream tests still pass. Update any that depended on previous transform behavior.
- Manual smoke test: open a KV file with corner-anchored overlays, switch craft → resize across platforms with different aspect ratios (e.g., 1080×1920 → 1200×630 → 1080×1080). Visually confirm overlay stays at corner; pixel size remains consistent.

## Acceptance criteria

- [ ] `transformOverlayForAspect` body replaced; signature and call sites unchanged.
- [ ] All overlay-position test cases above pass.
- [ ] Existing test cases updated (not deleted) to reflect new algorithm.
- [ ] No changes to `StudioOverlay` type, `useKvOverlaysStore`, or any DB schema.
- [ ] Manual cross-aspect smoke test confirms corner-anchored overlays stay corner-anchored.
- [ ] Threshold value `T = 0.08` extracted as a named constant in the same file (allows future tuning without hunting magic numbers).

## Open questions

None — all design decisions resolved during brainstorming.

## Future work (deliberately deferred)

- Explicit anchor metadata on `StudioOverlay` with UI snap zones (was "Approach B" in brainstorming). Defer until user feedback indicates the inference heuristic mis-classifies too often.
- Rotation-pivot correction.
- Per-tile divergence / sync UX ("push project overlays to all tiles" / "use this tile as new project default").
- Safe-area-based positioning (was "Approach C" in brainstorming).
