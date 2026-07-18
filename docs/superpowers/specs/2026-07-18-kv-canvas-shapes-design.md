---
title: KV Canvas — Editable Shape Overlays
slug: kv-canvas-shapes
author: daffa
created: 2026-07-18
status: draft
services: [web, api]
branch: feature/daffa/vc-kv-canvas-shapes
---

# KV Canvas — Editable Shape Overlays

## Overview

Designers can add simple parametric vector shapes — rectangle/square, ellipse/circle,
triangle, regular polygon (N-gon), and line — directly onto the KV canvas. Each shape is a
real, editable vector element (not a rasterized image): it can be moved, resized, rotated,
restyled, layered, and re-edited at any time. Shapes support solid fills and gradient fills
(linear + radial) plus an optional stroke.

Shapes are implemented as a **third overlay type** on the existing `StudioOverlay` system,
so board-anchoring, transform, layering, persistence, and export flatten all reuse the
current infrastructure rather than a parallel subsystem.

## Goals

- Add rectangle, ellipse, triangle, polygon, and line as editable vector overlays.
- Solid fill, linear gradient (with angle), and radial gradient — each with 2+ color stops
  and per-stop opacity.
- Optional stroke (border): toggle, color, width.
- Drag-to-draw placement from a toolbar shape picker.
- Full parity between the interactive (Fabric) and export (Konva) render surfaces.
- Shapes participate in saved Brand Overlay Presets.

## Non-Goals (v1)

- Vertex / pen-tool path editing (dragging individual anchor points, add/remove vertices).
- Star primitive (can ride the polygon control later).
- Freehand / brush drawing.
- Shape shadows, blur, or per-shape blend modes.

## Architecture

### Overlay envelope (reused, unchanged)

Shapes reuse the existing `StudioOverlay` envelope. Geometry stays on the envelope exactly
like `text` and `image`:

- Normalized `x`, `y`, `width`, `height` against the bg image fit-rect ([0,1], drag past
  edges allowed via the existing `between:-5,5` range).
- `rotation`, `z`.
- `board_generation_id` binding (shape moves with its board; matches board version chain).

Only the discriminant and payload are new. The 30-overlay cap is unchanged.

### Data model

```ts
type ShapeKind = "rectangle" | "ellipse" | "triangle" | "polygon" | "line";

type GradientStop = {
  offset: number; // 0..1
  color: string;  // #RRGGBB
  opacity: number; // 0..1
};

type ShapeFill =
  | { mode: "solid";  color: string; opacity: number }
  | { mode: "linear"; angle: number; stops: GradientStop[] } // angle in degrees
  | { mode: "radial"; stops: GradientStop[] };

type ShapeStroke = {
  enabled: boolean;
  color: string; // #RRGGBB
  width: number; // normalized: fraction of overlay width
};

// StudioOverlay.type gains "shape".
// StudioOverlay.payload union gains:
type ShapePayload = {
  type: "shape";
  kind: ShapeKind;
  fill: ShapeFill;
  stroke: ShapeStroke;
  corner_radius?: number; // rectangle only, 0..1 (fraction of min(w,h))
  sides?: number;         // polygon only, integer >= 3
};
```

Notes:

- **Stroke width is stored normalized** (fraction of overlay width) and multiplied by the
  render scale at draw time, with `strokeUniform` (Fabric) so it does not distort under
  non-uniform resize, and an equivalent scale on Konva. This keeps stroke thickness stable
  between the display canvas and the native-resolution PNG export.
- **`line`** uses `stroke` as its visible color/thickness; `fill` is ignored for lines. The
  editing UI hides fill controls when `kind === "line"` and forces `stroke.enabled = true`.
- Colors remain 6-digit hex (`#RRGGBB`) to match existing overlay color validation; opacity
  is a separate `0..1` field on solids and per gradient stop.

### Rendering — Fabric (edit) + Konva (export parity)

Both engines expose native primitives, so no custom path geometry is required:

| Kind      | Fabric              | Konva                       |
|-----------|---------------------|-----------------------------|
| rectangle | `Rect` (rx/ry)      | `Rect` (cornerRadius)       |
| ellipse   | `Ellipse`           | `Ellipse`                   |
| triangle  | `Triangle`          | `RegularPolygon(sides: 3)`  |
| polygon   | `Polygon` (regular N-gon points) | `RegularPolygon(sides: n)` |
| line      | `Line`              | `Line`                      |

Fill maps to `fabric.Gradient` / Konva `fillLinearGradient*` and `fillRadialGradient*`.

Because export flattens the **Konva** stage to PNG at native resolution, the shape must
render identically on both surfaces. A single shared mapping module is the seam that keeps
them in sync:

- `shapeToFabric(payload, geometry, scale)` → Fabric object props.
- `shapeToKonva(payload, geometry, scale)` → Konva node props.

Both derive from the same `ShapePayload`; gradient-stop and stroke conversion live in shared
helpers so a change to fill semantics updates both engines at once.

### Placement UX — drag-to-draw

- `CanvasTool` union gains shape tool state(s); a **Shape** button in the canvas toolbar opens
  a small picker listing the 5 kinds.
- Pick a kind → the cursor enters draw mode → **press-drag** on the canvas draws a marquee →
  on release, a shape overlay is created at that geometry, auto-selected, with a sensible
  default fill (solid) and stroke off.
- `Esc` or right-click cancels an in-progress draw and returns to the cursor tool.
- The drag-draw interaction layer is added to the Fabric (interactive) canvas only; Konva
  stays render/export-only.
- Polygon defaults to `sides: 6`; rectangle defaults to `corner_radius: 0`.

### Editing controls — Transform / Layers panels

When a shape overlay is selected, the Transform panel shows a shape section:

- **Fill mode** selector: solid / linear / radial.
- **Color-stop editor**: add/remove stops, per-stop color + opacity. Solid shows a single
  color + opacity.
- **Linear angle** slider (0–360°), shown only for linear mode.
- **Stroke**: enable toggle, color, width.
- **Kind-specific**: corner-radius slider (rectangle), sides stepper 3–12 (polygon).

The Layers panel lists shape overlays with a per-kind icon, alongside text/image entries,
using the existing layer-row pattern (select, reorder, visibility, delete).

### Persistence + API

- **`UpdateStudioFileOverlaysRequest`** (`api`): add `shape` to the `type` and `payload.type`
  `Rule::in` sets; validate `kind` (enum), `fill.mode` (enum) + stops (hex + `0..1` offset/
  opacity), `stroke` (bool/hex/numeric), `corner_radius` (`0..1`, rectangle), `sides`
  (integer ≥ 3, polygon). No S3/host checks apply to shapes (no asset URL).
- **`BrandOverlayPreset`** payload union (`web` type) + **`StoreBrandOverlayPresetRequest`**
  (`api`): widen the accepted payload to include `shape`, so branded shape kits are reusable.
- Persistence path itself (PATCH overlays on the studio file, `studio_files.overlays` JSON
  column) is unchanged — it already stores the whole overlay array verbatim.

## Data Flow

1. User picks a shape kind and drag-draws on the Fabric canvas.
2. Layout creates a `StudioOverlay` with `type: "shape"` + `ShapePayload`, normalized
   geometry, and `board_generation_id` of the active board.
3. Overlay array is PATCHed to the API (`UpdateStudioFileOverlaysRequest`) and stored in
   `studio_files.overlays`.
4. Fabric renders it live via `shapeToFabric`; Konva renders the same via `shapeToKonva`.
5. On export, the Konva stage (bg + all overlays incl. shapes) flattens to PNG at native
   resolution.
6. Optionally, the user saves the current overlay set (incl. shapes) as a Brand Overlay
   Preset; re-stamped on load.

## Error Handling / Edge Cases

- Invalid payloads are rejected by request validation (422) before persistence, matching the
  existing overlay contract.
- Gradient with `< 2` stops falls back to solid rendering of the first stop; a shape with an
  empty `stops` array is invalid (validation requires ≥ 2 for gradient modes).
- Degenerate marquee (near-zero drag) is discarded (no overlay created) with a minimum size
  threshold.
- Stroke width scaling uses `strokeUniform` so thickness stays visually correct after
  non-uniform resize and at export scale.
- Legacy overlays (`text`/`image`) and presets remain valid — the shape additions are purely
  additive union members.

## Testing

Web (`bun test`):

- `ShapePayload` round-trip serialize/deserialize.
- `shapeToFabric` / `shapeToKonva` mapping for each kind × each fill mode (solid/linear/
  radial) + stroke on/off.
- Line ignores fill; polygon respects `sides`; rectangle respects `corner_radius`.
- Drag-to-draw: marquee → overlay geometry; degenerate drag discarded.

API (Pest Unit):

- `UpdateStudioFileOverlaysRequest` accepts valid shape payloads (each kind + fill mode) and
  rejects invalid ones (bad enum, missing stops, out-of-range corner_radius/sides, bad hex).
- `StoreBrandOverlayPresetRequest` accepts a preset containing shapes.

## Service Breakdown

- **web** — types (`StudioOverlay` union, `CanvasTool`, `BrandOverlayPreset`), shared
  `shapeToFabric`/`shapeToKonva` mapping, Fabric render + drag-draw, Konva render, toolbar
  shape picker, Transform/Layers panel shape controls, gradient/stroke editor, tests.
- **api** — `UpdateStudioFileOverlaysRequest` + `StoreBrandOverlayPresetRequest` validation
  for the shape payload, Unit tests.

## Open Questions

None outstanding — edit model (parametric), shape set (rect/ellipse/triangle/polygon/line),
fill (solid + linear + radial + stroke), placement (drag-to-draw), and preset inclusion were
all resolved during brainstorming.
