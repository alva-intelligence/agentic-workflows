---
title: KV Text Overlay Typography Revamp
slug: text-overlay-typography-revamp
author: daffa
created: 2026-07-15
status: draft
services: [api, web]
---

# KV Text Overlay Typography Revamp — Design

## Overview

Rework how KV **text overlays** behave and how their typography is edited:

1. **Auto-fit box** — the text box hugs the text at its font size instead of being
   a fixed-width box that wraps. This removes the wrap ↔ box-height ↔ font-size
   coupling that has caused resize instability.
2. **Consolidated typography panel** — one panel holds font family, font size, and
   fill; the separate floating color-chip palette is removed.
3. **Gradient fill** — text fill can be a solid color (as today) or a 2-color
   linear gradient (from / to + angle), rendered on canvas and baked into exports.

This builds on the custom-fonts work already on this branch (brand fonts, font
picker, explicit normalized `fontSize`, the font-size input, the resize
scale-reset fix, payload-preservation fixes, and the api `fontFamily`/`fontSize`
persistence whitelist).

## Current State (as-is, post-merge with develop)

- Text overlay = `fabric.Textbox` (Fabric, primary/multi-board) or `Konva.Text`
  (Konva fallback). The Textbox has a **fixed width `w`** and **wraps**; height is
  auto. Konva text uses a fixed `width={pw}`.
- Font size is an explicit, **normalized** `payload.fontSize` (fraction of board
  height), rendered as `fontSize_norm * host.height`; legacy overlays fall back to
  `height * 0.8`.
- Fill is a solid `payload.color` (`#RRGGBB`), edited via a **floating chip
  palette** (`OverlayColorChip`) above the selected text — separate from the Text
  section (font family + size) in the bottom-right properties panel.
- Resize: Fabric corner/side handles → `object:modified` → `onModified` normalizes
  and writes geometry back; a vertical/corner drag (`scaleY`) already maps to
  `fontSize`, horizontal (`scaleX`) to wrap width; the reconcile resets scale to 1.
- Overlays persist to `studio_files.overlays` (JSON) via
  `UpdateStudioFileOverlaysRequest` → `StudioFileController` (`validated()`), and
  to brand presets via `StoreBrandOverlayPresetRequest`. Both now whitelist
  `fontFamily` + `fontSize`. A debounced save hook (`useDebouncedOverlaySave`,
  merged from develop) drives autosave.

## Decisions (locked during brainstorming)

1. **Box model: auto-fit / hug.** The box always fits the text at its font size;
   line breaks only where the user presses Enter. No fixed wrap width.
2. **Fill: solid + 2-color linear gradient** (from, to, angle).
3. **Placement: consolidated.** Fill (solid/gradient) moves into the Text section
   of the properties panel; the floating chip palette is removed.

## Approach

**Box model — switch Fabric `Textbox` → `fabric.IText`.** `IText` auto-sizes to its
content (grows horizontally, respects explicit `\n`, no forced wrap) and supports
the same inline editing. This makes the box hug the text natively. `Konva.Text`
hugs when no fixed `width` is set. Stored `width`/`height` become **derived** display
values (the rendered text's bounding box, written back on modify) — they no longer
drive font size, so the feedback loop is structurally gone.

**Resize.** Show **corner handles only** (uniform scale) on text; a corner drag
scales the explicit `fontSize` (the box follows). Side handles are hidden (there is
no independent wrap width to set). Font size is also editable via the Size input.

**Fill.** Add an optional `gradient` to the text payload alongside `color`. When
present it renders a linear gradient; when absent, the solid `color` renders as
today. A single `resolveTextFill` helper produces the per-canvas fill (Fabric
`Gradient` vs Konva `fillLinearGradient*`) from the payload + the object's bbox.

**Rejected alternatives:**
- *Keep Textbox, force no-wrap by widening* — hacky; IText is the right primitive.
- *Multi-stop / radial gradient* — deferred; 2-stop linear covers the ask with less
  UI and fewer rendering edge cases. The payload shape leaves room to extend later.
- *Discriminated `fill` union replacing `color`* — churns every existing read of
  `color` and breaks back-compat; additive `gradient?` is safer.

## Architecture

### Data model (web types — `src/types/studio.ts`)

Text payload (and the `BrandOverlayPreset` text payload) gains an optional
`gradient`:

```ts
{
  type: "text";
  content: string;
  color: string;            // solid fill; also the fallback when gradient absent
  fontFamily?: string;
  fontSize?: number;        // normalized fraction of host height (already added)
  gradient?: {
    from: string;           // #RRGGBB
    to: string;             // #RRGGBB
    angle: number;          // degrees, 0 = left→right, 90 = top→bottom
  };
}
```

### Fill resolution (web — new `overlays/resolveTextFill.ts`)

- `hasGradient(payload)` — true when `payload.gradient` is set with valid stops.
- `konvaGradientProps(gradient, width, height)` → `{ fillLinearGradientStartPoint,
  fillLinearGradientEndPoint, fillLinearGradientColorStops }`, with start/end
  derived from `angle` across the `width×height` box (unit vector `(cos θ, sin θ)`
  projected onto the box, origin at box center or top-left per the node's origin).
- `fabricGradient(gradient, width, height)` → `new fabric.Gradient({ type:
  "linear", gradientUnits: "pixels", coords: {x1,y1,x2,y2 from angle+box},
  colorStops: [{offset:0,color:from},{offset:1,color:to}] })`.
- Solid path: return `payload.color` (Konva `fill`, Fabric `fill`).

### Rendering

- **Fabric (`KvFabricCanvas`)**: create/update text as `fabric.IText` (was
  `Textbox`); `instanceof fabric.IText` in the reconcile. Set `fill` to either the
  solid color or `fabricGradient(...)` sized to the object. Show only corner
  controls (`setControlsVisibility({ ml:false, mr:false, mt:false, mb:false })`);
  keep rotate. The existing font-sync effect and the `scaleY→fontSize` writeback
  carry over. Gradients are recomputed when the box size or gradient changes (fold
  a gradient signature into the existing font/geometry sync).
- **Konva (`KvKonvaCanvas`)**: overlay content `Text` — drop the fixed `width` so
  it hugs; apply `konvaGradientProps` when gradient present, else `fill={color}`.
- **Resize / export stages** (`KvResizeCanvas`, `KvResizeTileStage`,
  `KvTileOverlayEditor`): same fill resolution + explicit `fontSize` (already
  wired) so the exported PNG matches the editor.

### Typography panel (web — `KvGeneratorLayout` Text section)

The Text section becomes the full typography config, shown for a selected text
overlay:
- **Font family** — existing `KvTextFontToolbar` dropdown (built-in + brand fonts + upload).
- **Size** — existing px number input.
- **Fill** — a **Solid | Gradient** segmented toggle:
  - *Solid*: one color field (preset swatches + hex input) → writes `payload.color`,
    clears `gradient`.
  - *Gradient*: two color fields (From / To) + an angle input (0–360, default 90) →
    writes `payload.gradient`; `color` is kept as the From value for fallback.
- A small reusable **ColorField** (swatch button → popover with the existing preset
  palette + a hex input) backs both the solid control and each gradient stop.

The floating `OverlayColorChip` palette and its wiring (`handleChangeTextColor`
trigger) are removed; color now flows only through the panel. `handleChangeTextColor`
stays as the mutation used by the panel (already fixed to preserve the full payload).

### Persistence (api)

Whitelist `gradient` on both overlay requests so `validated()` preserves it:
- `UpdateStudioFileOverlaysRequest` and `StoreBrandOverlayPresetRequest`:
  - `overlays.*.payload.gradient` → `['nullable', 'array']`
  - `overlays.*.payload.gradient.from` → `['required_with:...gradient', 'regex:/^#[0-9A-Fa-f]{6}$/']`
  - `overlays.*.payload.gradient.to` → same regex
  - `overlays.*.payload.gradient.angle` → `['required_with:...gradient', 'numeric', 'between:0,360']`

No migration — overlays are a JSON column.

## Data Flow

1. User selects a text overlay → typography panel shows family / size / fill.
2. Editing fill: Solid picks a color (`payload.color`, clears `gradient`); Gradient
   sets `payload.gradient` (from/to/angle). Mutation goes through the same
   `docUpdateOverlay` path, preserving `content`, `fontFamily`, `fontSize`.
3. The Fabric/Konva reconcile applies the fill (solid or gradient) to the IText /
   Text node; auto-fit keeps the box hugging the text at its font size.
4. Autosave (`useDebouncedOverlaySave` → PATCH) persists the full payload incl.
   `gradient`; api `validated()` keeps it.
5. Reopen / export: fill + size + family survive; gradient bakes into the flatten.

## Error Handling / Back-compat

- Legacy overlays (no `gradient`) render solid `color`, exactly as before.
- Invalid/partial gradient (missing stop) → fall back to solid `color`.
- `angle` normalized into [0,360); missing → default 90.
- Auto-fit: an empty text has a minimum box so it stays selectable/editable.
- Switching an overlay from gradient back to Solid clears `payload.gradient`.

## Testing

- **web unit:** `resolveTextFill` (angle→coords for Konva + Fabric; solid vs
  gradient selection; invalid-gradient fallback); payload mutations
  (set-gradient / clear-gradient preserve content+font+size); the ColorField
  hex/preset behavior.
- **web build:** `bun run build` green (IText switch touches the canvas).
- **api unit:** request-validation tests — gradient accepted with valid stops,
  rejected on bad hex / out-of-range angle; `validated()` includes `gradient`.
- **manual e2e:** auto-fit hug + corner-scale resize (no runaway), solid color,
  gradient (angle changes), reload persistence, resize→download bake — on the
  Fabric multi-board canvas and the Konva fallback.

## Non-Goals (this phase)

- Multi-stop or radial gradients; per-character styling; text stroke/shadow.
- Font weight / style / alignment controls (future typography additions).
- Rich-text (mixed styles within one overlay).
- Any ai-service change.

## Services Touched

- **web:** `types/studio.ts`, `overlays/resolveTextFill.ts` (new), `KvFabricCanvas`
  (Textbox→IText + gradient + corner-only controls), `KvKonvaCanvas` (hug +
  gradient), `KvResizeCanvas` / `KvResizeTileStage` / `KvTileOverlayEditor`
  (gradient), `KvGeneratorLayout` (typography panel: fill/gradient controls, remove
  floating chips), a new `ColorField` control.
- **api:** `UpdateStudioFileOverlaysRequest`, `StoreBrandOverlayPresetRequest`
  (whitelist `gradient`).
- **ai-service:** none.
