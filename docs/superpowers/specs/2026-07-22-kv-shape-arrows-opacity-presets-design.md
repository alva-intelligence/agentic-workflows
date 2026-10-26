# KV Canvas Shapes — Arrows, Opacity & New Presets

> **Date:** 2026-07-22
> **Author:** Daffa
> **Status:** draft
> **Services:** web, api
> **Delivery:** directly on `develop` (extends the already-merged KV shape overlay system — no feature branch)

## Overview

The KV generator already supports editable vector shape overlays (`rectangle`, `ellipse`,
`triangle`, `polygon` with 3–12 sides, `line`) as the third `StudioOverlay` type, with solid/
gradient fill, stroke color+width, corner radius (rectangle), layering, and rotation. This change
adds three capabilities requested for richer decorative/diagramming use, all additive to the
existing Konva-based system:

1. **Whole-shape opacity** — a 0–100% transparency control for any shape.
2. **Arrow** — a new shape kind (line + arrowhead) with arrowhead direction and pointer size.
3. **New preset shapes** — `star`, `diamond`, `chevron` (fixed-geometry polygons the existing
   n-gon `polygon` kind cannot express).

### Non-goals (explicitly out of scope)

- AI-generated vector/SVG elements (no ai-service pipeline; greenfield, deferred).
- Connectors / elbow routing / anchor points.
- `parallelogram`, `pentagon`, `hexagon` presets (pentagon/hexagon are already reachable via
  `polygon` `sides=5/6`).
- Per-fill / per-stroke opacity — opacity is whole-shape only.
- Opacity on `text` / `image` overlays — this change scopes opacity to shapes only.

## Prior art / why not reuse the deck shapes

The pitch-deck generator has its own shape system (`DeckShapeKind`: rectangle, ellipse, line,
triangle, diamond, star, pentagon, hexagon, parallelogram, chevron; opacity; shadow; linear
gradient). Its pure geometry/fill modules are portable, but it renders on **Fabric + DOM/SVG**
while KV renders on **Konva**, and it has **no arrows and no AI-vector** capability either. So the
deck code does not unlock the hard parts — this is an in-place extension of KV's own shape system,
borrowing the deck's *ideas* (opacity, star/diamond/chevron geometry) rather than its code.

## Data model (`web/src/types/studio.ts`)

Extend the shape kind union and payload:

```ts
export type ShapeKind =
  | "rectangle" | "ellipse" | "triangle" | "polygon" | "line"
  | "arrow" | "star" | "diamond" | "chevron"; // new

export type ShapeArrowheads = {
  at_start?: boolean;       // default false
  at_end?: boolean;         // default true
  pointer_length?: number;  // normalized to overlay width (like stroke width)
  pointer_width?: number;   // normalized to overlay width
};

export type ShapePayload = {
  type: "shape";
  kind: ShapeKind;
  color: string;
  gradient?: ShapeGradient;
  stroke?: ShapeStroke;
  corner_radius?: number;   // rectangle only (unchanged)
  sides?: number;           // polygon only (unchanged)
  line?: ShapeLine;         // line only (unchanged; arrow does NOT use this)
  opacity?: number;         // NEW — 0..1, whole shape, default 1 (absent = 1)
  arrow?: ShapeArrowheads;  // NEW — arrow kind only
};
```

Decisions:
- **Opacity is shape-scoped** (on `ShapePayload`, not the base `StudioOverlay`). Keeps text/image
  overlays out of scope. Easy to promote to overlay-level later if desired.
- **Arrow mirrors line's v1 render** — a segment across the box mid-line (`[0, h/2, w, h/2]`),
  rotated via the overlay `rotation`, **not** draggable two-point endpoints. The `line`/`ShapeLine`
  field is line-only scaffolding unused by the current line render; arrow does not touch it. Arrow
  carries only its arrowhead config in the new `arrow` field.
- **star/diamond/chevron need no new payload fields** — pure geometry; support fill + stroke +
  opacity like triangle/polygon; **no corner radius** (consistent with existing non-rectangle
  kinds).

## Rendering

Single source of geometry stays in `web/src/components/studio/kv-generator/overlays/shapeGeometry.ts`.

- Add `starPoints()` (5-point star, outer/inner radius), `diamondPoints()` (4-point rhombus),
  `chevronPoints()` (6-point chevron) alongside the existing `trianglePoints` /
  `regularPolygonPoints`. Render as closed Konva `Line`, the same path triangle/polygon use.
- **Arrow** → Konva native `Arrow` node on the box mid-line (`[0, h/2, w, h/2]`) + `arrow` config
  (`pointerLength`, `pointerWidth`, `pointerAtBeginning`, `pointerAtEnding`).
- **Opacity** → `opacity` prop on the node (Konva) / object (Fabric); fades fill + stroke together.

**Two render engines must both be updated** (resolved during planning): the live interactive canvas
is **Fabric** (`KvFabricCanvas.tsx`, gated by the fail-open `KV_MULTI_BOARD` flag), while **Konva**
(`ShapeKonvaNode.tsx` / `shapeGeometry.ts`) is the kill-switch fallback **and** the PNG export bake
(`renderBoardStage.ts`). So every new kind/field is wired in three places:
  - **Fabric** (`KvFabricCanvas.tsx`) — the live editor. star/diamond/chevron → `fabric.Polygon`;
    **arrow → a custom build (Fabric has no Arrow node): a `fabric.Group` of a shaft `fabric.Line` +
    one/two `fabric.Triangle` heads**, carrying `_shapeMeta.kind = "arrow"` and rebuilt on style
    change (same rebuild-on-change path kind/sides already use); opacity on the object `common`.
  - **Konva** (`shapeGeometry.ts` + `ShapeKonvaNode.tsx` + `bakeShapeNodeConfig`) — fallback +
    export. star/diamond/chevron → closed `Line`; arrow → `Arrow` node; opacity in the shared props.
  - **Yjs serializer** (`web/src/lib/kv/yjsSerializer.ts`) — **no change needed**; payload is
    serialized opaquely via `Object.entries` / `.toJSON()`, so `opacity` / `arrow` round-trip
    automatically.

Note on testability: `shapeGeometry.ts` (pure) and `ShapeKonvaNode`/`ShapeStyleControls` (jsdom) are
unit-tested; `KvFabricCanvas` has no unit tests (needs a real canvas) — its arrow/preset/opacity
changes are verified by manual e2e, called out in the plan.

## UI / controls

- **`ShapePicker.tsx`** — add `arrow`, `star`, `diamond`, `chevron` with Phosphor icons
  (e.g. `ArrowRight`, `Star`, `Diamond`, `CaretRight`). Keep the lean single-popover picker (no
  category tabs, no filled/outline preset gallery — those belong to the decks diagramming surface,
  not KV's decorative use). Apply only **light visual grouping**: a "Basic" cluster
  (rectangle, ellipse, triangle, polygon, star, diamond, chevron) and a "Lines" cluster
  (line, arrow). No tab machinery.
  - *Deferred (not this round):* a Canva-style filled/outline/rounded preset gallery. Cheap to add
    later on top of existing fill/stroke/corner-radius controls if designers ask.
- **`overlays/ShapeStyleControls.tsx`**:
  - **Opacity** slider (0–100%) shown for every shape kind.
  - **Arrowheads** cluster (start toggle, end toggle, pointer size) shown only when
    `kind === "arrow"`.
- **Analytics** (mandatory, `frndos-analytics-events`): extend `trackKvOverlayAdded` /
  `trackKvShapeStyleChanged` to cover the new kinds and the `opacity` / `arrow` properties.

## Backend (`api/`)

- **`app/Http/Requests/Studio/Concerns/HasShapeOverlayPayloadRules.php`** — the load-bearing change
  (the FormRequest strips any un-whitelisted sub-key, so unlisted fields are silently dropped):
  - Add `arrow`, `star`, `diamond`, `chevron` to `Rule::in([...])` for `kind`.
  - Add `opacity` → `nullable|numeric|min:0|max:1`.
  - Add `arrow.at_start` / `arrow.at_end` → `nullable|boolean`.
  - Add `arrow.pointer_length` / `arrow.pointer_width` → `nullable|numeric|min:0|max:1`.
- Check `KvResizeExportController` inline overlay validation — `overlays.*.type in text,image,shape`
  is unaffected (type stays `shape`), but confirm nested shape rules are applied consistently there.
- **No migration** — overlays remain in the existing `studio_files.overlays` and resize-export JSON
  columns.

## Open implementation question (resolve during planning, before the arrow task)

The two explorations disagreed on whether the **live interactive shape edit** path runs on Konva or
on `KvFabricCanvas.tsx`. If Fabric is in the live edit path, the arrow needs a Fabric equivalent
(Fabric has no native Arrow — a group of line + triangle, or a `fabric.Path`), which is extra work
scoped only to arrow. Confirm the exact renderer wiring first and size the arrow task accordingly.
Star/diamond/chevron map to `fabric.Polygon` cleanly regardless.

## Testing

- `web/src/types/studio.shape.test.ts` — new kinds + `opacity` / `arrow` payload shape.
- `overlays/shapeGeometry.test.ts` — `starPoints` / `diamondPoints` / `chevronPoints`.
- `overlays/ShapeKonvaNode.test.tsx` — arrow renders (arrowheads), new kinds render, opacity applied.
- `overlays/ShapeStyleControls.test.tsx` — opacity slider; arrowhead cluster visible only for arrow.
- `api` Unit test — widened `HasShapeOverlayPayloadRules` accepts new kinds/opacity/arrow and still
  rejects out-of-range values.
- Gate is `bun run build` (not tsc) for web; api verified via Unit tests.

## Acceptance criteria

- User can place arrow, star, diamond, chevron from the shape picker on a KV board.
- Arrow supports start/end arrowhead toggles and pointer sizing; renders correctly at any angle.
- Every shape has a working 0–100% opacity control that persists and appears identically in PNG
  export and after a collab (Yjs) round-trip.
- Backend accepts and persists the new fields; out-of-range values are rejected.
- Existing shapes (rectangle/ellipse/triangle/polygon/line) are unaffected.
