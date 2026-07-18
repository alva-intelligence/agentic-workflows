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
- Multi-stop gradients (3+ colors) and per-stop opacity — shapes reuse the existing 2-color
  (from/to) text-overlay gradient model; a richer gradient model would apply to text and
  shapes together in a later pass.

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

**Reuse decision (updated after codebase mapping):** `develop` already ships a complete
solid + linear/radial gradient fill system for **text** overlays — the payload carries
`color` plus an optional `gradient: { type?: "linear" | "radial"; from: string; to: string;
angle: number }`, with shared resolvers (`konvaTextFill`, `applyTextFill`, `hasTextGradient`,
`gradientLineCoords` in `overlays/resolveTextFill.ts`), a reusable hex picker (`ColorField`),
a fill editor (`TextTypographyControls`), and a validation trait
(`HasTextOverlayPayloadRules`). Shapes **mirror this exact fill model** rather than inventing
a second one. This means a **fixed 2-color gradient** (from/to), hex-only colors, and no
per-stop opacity in v1 — a deliberate DRY trade documented in Non-Goals.

```ts
type ShapeKind = "rectangle" | "ellipse" | "triangle" | "polygon" | "line";

// Mirrors the text payload's fill fields exactly (color + optional gradient),
// so shapes reuse resolveTextFill.ts / ColorField / the validation trait.
type ShapeStroke = {
  color: string;  // #RRGGBB
  width: number;  // normalized: fraction of overlay width; 0 or absent = no stroke
};

// StudioOverlay.type gains "shape".
// StudioOverlay.payload union gains:
type ShapePayload = {
  type: "shape";
  kind: ShapeKind;
  color: string; // solid fill (and gradient base), #RRGGBB
  gradient?: { type?: "linear" | "radial"; from: string; to: string; angle: number };
  stroke?: ShapeStroke;
  corner_radius?: number; // rectangle only, 0..1 (fraction of min(w,h))
  sides?: number;         // polygon only, integer >= 3 (default 6)
};
```

Notes:

- **Fill** resolves the same way as text: if `gradient` is present it renders the
  linear/radial gradient; otherwise the solid `color`. The existing `konvaTextFill` /
  `applyTextFill` resolvers are generalized to accept `{ color, gradient }` so both text and
  shapes share one fill path.
- **Stroke width is stored normalized** (fraction of overlay width) and multiplied by the
  render scale at draw time, with `strokeUniform` (Fabric) so it does not distort under
  non-uniform resize, and an equivalent scale on Konva. This keeps stroke thickness stable
  between the display canvas and the native-resolution PNG export. `stroke` omitted (or
  `width === 0`) = no border.
- **`line`** has no interior: it renders as a stroked segment using `stroke` (falling back to
  `color` at a default width if `stroke` is absent). The editing UI hides fill controls and
  shows only stroke controls when `kind === "line"`.
- Colors remain 6-digit hex (`#RRGGBB`) to match existing overlay color validation.

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

The per-type editor branch lives in the **parent** components (`KvGeneratorLayout.tsx` and
`KvResizeCanvas.tsx`), which already stack a text-only `TextTypographyControls` above the
shared geometry `KvTransformPanel`. A new `ShapeStyleControls` slots in the same way, gated on
`payload.type === "shape"`, mirroring `TextTypographyControls`:

- **Fill**: Solid / Gradient segmented toggle → for Gradient, a Linear / Radial sub-toggle,
  `From` / `To` `ColorField`s, and an **Angle** input (linear only); for Solid, one
  `ColorField`. This is the same control cluster `TextTypographyControls` renders, so it is
  factored into a shared fill-editor and reused.
- **Stroke**: enable toggle → color (`ColorField`) + width input. Off = no `stroke`.
- **Kind-specific**: corner-radius input (rectangle), sides stepper 3–12 (polygon).
- For `kind === "line"`, fill controls are hidden; only stroke controls show.

`KvTransformPanel` (geometry) is type-agnostic and reused as-is; only its
`trackKvOverlayTransformed` `overlay_type` cast widens to include `"shape"`.

The Layers panel (`KvLayersPanel`) lists shape overlays alongside text/image using the
existing layer-row pattern (select, reorder, delete). Its `LayerIcon` and `labelForOverlay`
gain a `shape` branch (per-kind icon + `"Shape"` / kind label). There is no per-layer
visibility toggle in the current panel and none is added.

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
  existing overlay contract. **Critical:** the request layer's `validated()` strips any
  payload sub-key without an explicit rule, so every shape field (`kind`, `color`,
  `gradient.*`, `stroke.*`, `corner_radius`, `sides`) MUST be whitelisted or it is silently
  dropped on save.
- Fill resolution: `gradient` present → gradient render; absent → solid `color` (identical to
  the text fill path). No empty-stops case exists in the 2-color model.
- Degenerate marquee (near-zero drag) is discarded (no overlay created) with a minimum size
  threshold.
- Stroke width scaling uses `strokeUniform` so thickness stays visually correct after
  non-uniform resize and at export scale.
- Legacy overlays (`text`/`image`) and presets remain valid — the shape additions are purely
  additive union members.

## Testing

Web (`bun test` — bunfig preloads jest-dom; do NOT use `bunx vitest`):

- Shape geometry helpers: regular-polygon point generation for a given `sides`; triangle
  points; fill resolution (solid vs gradient) via the shared resolver for shapes.
- `shapeToFabric` / `shapeToKonva` mapping for each kind × solid + linear + radial fill +
  stroke on/off.
- Line renders as a stroked segment (no fill); polygon respects `sides`; rectangle respects
  `corner_radius`.
- Drag-to-draw: marquee → normalized overlay geometry; degenerate drag discarded.
- `ShapeStyleControls`: solid/gradient toggle drives `onPatch`; stroke toggle adds/removes
  `stroke`; sides/corner-radius inputs patch payload (mirror `KvTransformPanel.test.tsx`
  render + `objectContaining` assertion style).

API (Pest **Unit**, no DB — mirror `tests/Unit/Requests/OverlayGradientValidationTest.php`,
NOT a Feature test; the Feature suite fails on fresh migrate):

- `UpdateStudioFileOverlaysRequest` accepts valid shape payloads (each kind, solid + gradient
  fill, with/without stroke) and asserts `validated()` **preserves** all shape payload keys.
- Rejects invalid payloads: bad `kind`, bad hex `color`, out-of-range `corner_radius` /
  `sides`, malformed `stroke`, out-of-range gradient `angle`.
- `StoreBrandOverlayPresetRequest` accepts a preset containing a shape overlay.

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
