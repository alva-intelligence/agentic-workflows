---
title: KV Resize — Legible Tile Scale + Per-Tile Zoom
slug: kv-resize-legible-tile-scale
author: daffa
created: 2026-09-07
status: draft
services: [web]
---

## Overview

On the Resize surface every tile renders at one shared proportional scale,
keyed off the widest native dimension in the set. When a target size is much
smaller than the largest tile, its on-screen render collapses proportionally:
it reads as low-fidelity, its overlays become too small to select, and the
selection handles end up occluding the very box they belong to.

This spec adds a **floor** to that scale, fixes handle occlusion at its
actual cause, and makes the viewport's already-existing zoom discoverable as
a per-tile action.

The load-bearing constraint is that **large tiles must not change at all**.
That constraint is what selects the design: a floor can only ever raise a
tile, so tiles already above the floor are untouched by construction — not
by care.

## Current behaviour (as-built)

### The shared scale

`web/src/components/studio/kv-generator/KvResizeCanvas.tsx:680`

```ts
const MAX_TILE_DISPLAY_WIDTH = 752;
const maxNativeWidth = Math.max(sourceSize.w, ...exports.map((r) => r.width), 1);
const displayScale = MAX_TILE_DISPLAY_WIDTH / maxNativeWidth;
const displayWidthFor = (nativeWidth: number) =>
  Math.round(nativeWidth * displayScale);
```

`displayWidthFor` has exactly two call sites — the master row
(`KvResizeCanvas.tsx:2219`) and each result row
(`KvResizeCanvas.tsx:2334`). Nothing else in the surface reads
`displayScale`.

### Why the blast radius is small

`displayWidth` is **already a free variable**: it differs per tile today.
Everything downstream normalizes against it rather than assuming a value.

- Overlays are stored normalized `0..1` against the frame and multiplied
  back at render: `w: o.width * displayWidth`
  (`KvTileOverlayEditor.tsx:712`).
- Pointer input divides back out:
  `nx = (pt.x - apron) / displayWidth` (`KvTileOverlayEditor.tsx:527`).
- The apron is derived, not fixed: `apronPxForOverlays({ displayWidth,
  displayHeight, overlays })` (`resizeApron.ts:171`).
- The fabric canvas is created at `displayWidth`/`displayHeight` with
  coordinates in CSS px (`KvTileOverlayEditor.tsx:433`).

Changing the **value** of `displayWidth` therefore requires no change to
overlay data, no migration, and no re-projection. Changing its *meaning*
would; this spec does not.

### Resolution is already handled

`applyMaxQualityScaling(next, targetWidth, canvasW)`
(`KvTileOverlayEditor.tsx:460`) raises the fabric backing store to
`min(3, max(dpr, native / canvasW))`. A tile displayed small already gets a
backing store up to 3× its CSS size, so it stays crisp under the viewport's
CSS zoom. Small tiles are **not** a resolution problem — they are an
apparent-size problem. No change needed here.

### Handles are never configured

There is no `cornerSize`, `touchCornerSize`, or `borderScaleFactor` anywhere
in `kv-generator/`. Overlay controls use fabric defaults, which are a fixed
size in screen px and do **not** shrink with the tile.

The real failure is occlusion, not size: on a tile rendered ~200px wide, an
overlay occupying 20% of the frame is ~40px, and four default-sized handles
sitting on its corners cover most of it. Enlarging handles would make this
worse. (The exact default corner size is fabric's, not ours — measure it
before picking a replacement value rather than trusting a remembered
number.)

### Zoom already exists

`KvResizeViewport.tsx` is a full pan + zoom viewport:

- `ctrl` / `meta` + wheel zooms around the cursor; plain wheel pans.
- `MIN_SCALE = 0.25`, `MAX_SCALE = 3`, `ZOOM_STEP = 1.05`.
- The transform is a CSS `translate3d(...) scale(...)` mutated directly on
  the inner div through a ref, never through React.
- It publishes a focus API with `centerTile(tileId, at)`.

What is missing is **discoverability and fit**, not capability: there is no
zoom pill, no zoom-level readout, no reset, and no "fit this tile". The
helpers in `focusCamera.ts` (`panRectIntoView`, `centerRectInView`)
deliberately preserve scale (`scale: camera.scale`), so zoom-to-fit does not
exist yet. `KvResizeViewport` does not consume `focusCamera` at all — it
measures the element and moves the transform by the screen-space delta.

## Goals

From the original brief, unchanged:

1. Small tiles render at a legible, editable scale regardless of their ratio
   to the largest tile in the set — explicitly **not** strictly proportional
   to native pixel width.
2. Overlay handles stay a usable click target on small tiles.
3. The user can zoom into an individual tile to edit precisely.
4. No regression to large / original-size tile rendering or to the shared
   canvas layout.

Goal 1 grants the trade-off that strict proportionality is expendable. Goal 4
constrains *which* tiles may move. Together they select a floor over a curve.

## Design

### 1. Scale policy — floor, capped at native

Keep the shared scale exactly as it is. Add a floor and a native ceiling:

```ts
displayWidthFor(w) =
  Math.min(
    Math.max(Math.round(w * sharedScale), MIN_TILE_DISPLAY_WIDTH),
    w
  );
```

Three behaviours fall out, and each maps to a goal:

- **Above the floor → untouched.** Any tile whose current render is already
  `>= MIN_TILE_DISPLAY_WIDTH` is bit-identical to today. This is goal 4, and
  it is a property of the expression rather than a thing to verify per tile.
- **Below the floor → raised to the floor.** Every such tile lands on the
  same display width whatever its ratio to the largest tile. This is goal 1.
  Height still follows each tile's own aspect, so aspect is never distorted.
- **Smaller than the floor natively → capped at 100%.** A tile whose native
  width is below the floor stops at its native width. Rendering 300 native px
  into a 420px box would upscale 1.4× and present fidelity we do not have.
  1:1 is the most honest maximum for those tiles; the rest is zoom's job.

The 752 ceiling needs no separate clause. Because
`sharedScale = 752 / maxNativeWidth` and every `w <= maxNativeWidth`, the
product `w * sharedScale` is already `<= 752`, and the floor sits below it.
One expression, one new constant, no special-case branches.

**New module.** Extract the policy into
`web/src/components/studio/kv-generator/resizeTileScale.ts` as pure
functions, following the sibling pattern of `resizeApron.ts` and
`blankBaseDimensions` in `makeBlankBase.ts`. Pure so it is unit-testable
without a canvas — jsdom implements neither `getContext("2d")` nor
`toBlob`.

**Master row.** `displayWidthFor(sourceSize.w)` keeps working unchanged. When
the source is the widest thing in the set it still maps to 752; when the
source is narrower than the floor it clamps to its native width like any
other tile.

### 2. Handle occlusion

Configure overlay controls explicitly in `KvTileOverlayEditor.tsx`:

- Set `cornerSize` (and `touchCornerSize` for pointer/touch) to a deliberate
  value instead of inheriting fabric's default.
- Set control `padding` so handles sit **outside** the overlay's bounding
  box rather than on its corners, leaving the box interior a clean drag and
  select target even on a small overlay.

This is independent of the scale change and can land on its own.

### 3. Per-tile zoom

- Add `fitTile(tileId)` to the viewport's focus API: measure the tile
  element, then set the transform's scale so the tile fills the viewport
  (clamped to `MIN_SCALE`/`MAX_SCALE`) and centre it. This is the piece
  `focusCamera.ts` currently refuses to do, so the fit helper belongs there
  alongside `centerRectInView`.
- Add a zoom pill to Resize mirroring the existing
  `motion/KvMotionCanvasZoomPill.tsx`: current level, zoom in/out, reset to
  100%, and fit-active-tile.
- Expose fit from the tile row's own affordances so it is reachable without
  knowing the wheel modifier.

Two needs, two mechanisms: the resting scale is for **seeing and navigating**
every tile at once, zoom-to-fit is for **precision work** on one. The present
surface has a single knob serving the first need only, which is why precise
editing on a small tile feels impossible.

## Deliberately unchanged

- Overlay data, normalization, and re-projection between frames.
- `sharedScale` itself, and `MAX_TILE_DISPLAY_WIDTH = 752`.
- The apron model, the fabric backing-store multiplier, retina handling.
- The vertical-list layout and its `max-w-[900px]` container.
- Every tile already rendering at or above the floor.

## Rejected alternatives

**A compressed curve (sqrt / log).** Mapping
`752 * (w / maxW) ** 0.5` makes small tiles bigger, but it moves **every**
tile including the largest, which violates goal 4 directly. It also
compresses the size relationship between mid-size tiles, which the floor
leaves intact above the threshold. Rejected on goal 4.

**A per-tile zoom multiplier stored per tile.** Maximum flexibility, but it
introduces a second coordinate concept per tile when the viewport already
owns a zoom, and per-tile scale state is exactly the kind of addition that
has previously caused the four overlay renderers to drift out of agreement.
Rejected as duplicated machinery.

**Enlarging the handles.** Treats the symptom backwards: handles do not
shrink, and making them bigger increases the occlusion that is the actual
complaint.

## Open questions

1. **`MIN_TILE_DISPLAY_WIDTH` value.** ~420px is the working figure. This
   needs to be judged on screen against a real platform set, not chosen from
   a table.
2. **One-axis or two-axis floor.** Text size is normalized against board
   **height** (`overlayGeometry.ts:104`,
   `fontSizePx = payload.fontSize * board.height`, floored at 1px), so a
   floor on width alone leaves short-landscape tiles with small text — a
   420×220 tile still renders `0.03` body text at 6.6px. A two-axis floor
   (`max(sharedScale, MIN_W / w, MIN_H / h)` under the same native and 752
   ceilings) fixes that but moves more tiles. Decide by looking at both.
3. **Apron growth.** A floored tile's apron grows in absolute px with
   `displayWidth`. The apron already hangs outside the frame and already
   required `relative z-20` on row headers and the action bar to stop it
   swallowing clicks (`KvResizeCanvas.tsx:2190`). Raising small tiles makes
   that overhang larger in absolute terms, so the overlap needs re-checking
   on a tile with layers outside the frame.

## Testing

Unit (pure, `bun test`):

- A tile above the floor returns exactly `round(w * sharedScale)`.
- A tile below the floor returns `MIN_TILE_DISPLAY_WIDTH`.
- A tile whose native width is below the floor returns its native width.
- The result never exceeds 752 for any `w <= maxNativeWidth`.
- Monotonicity: a wider native tile never returns a narrower display width.

Runtime checks (no automated coverage, do by hand):

- A set spanning a large spread renders the large tile identically before and
  after — compare screenshots, not impressions.
- An overlay on a floored tile can be selected, dragged, and resized without
  hitting a neighbour.
- A tile with an overlay hanging outside the frame does not have its apron
  cover the row header or the action bar.
- Fit, reset, and wheel-zoom agree on the reported zoom level.

Run web tests with `bun test` (bunfig preloads jest-dom), and build with
`node` — `bun run build` is broken in this repo.

## Analytics

Per the `frndos-analytics-events` skill, a web feature is not done without
events. At minimum: tile fit invoked (with the source affordance — pill vs
row), zoom reset, and zoom level reached. Naming and payloads to follow that
skill.

## Out of scope

- **Source-to-tile scale coupling.** `maxNativeWidth` includes
  `sourceSize.w`, and PSD-imported base boards are created at the PSD's own
  size capped at `MAX_BASE_DIM = 4096` (`makeBlankBase.ts:43`). An identical
  target set therefore renders up to ~2.7× smaller behind a PSD source than
  behind a typical AI-generated one. Real, separate, and deliberately not
  addressed here — recorded so it is not rediscovered from scratch.
- **Unified-canvas signposting.** The surface has two implementations behind
  `KV_RESIZE_UNIFIED_CANVAS` plus a dev-only localStorage opt-in
  (`KvResizeCanvas.tsx:2159`); the read-only spike is easy to mistake for the
  live path. Parked at the owner's request.
- The unified canvas itself. This spec targets the live per-tile surface.
