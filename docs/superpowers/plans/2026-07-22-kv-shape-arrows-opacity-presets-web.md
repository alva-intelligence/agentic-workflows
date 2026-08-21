# KV Shapes — Arrows, Opacity & Presets (WEB) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add whole-shape opacity, an `arrow` shape kind, and `star`/`diamond`/`chevron` preset shapes to the KV generator's existing shape overlays.

**Architecture:** Extend the existing `shape` `StudioOverlay` type. Geometry stays single-sourced in `overlays/shapeGeometry.ts`. Both render engines are updated: **Fabric** (`KvFabricCanvas.tsx`, the live interactive canvas, gated by the fail-open `KV_MULTI_BOARD` flag) and **Konva** (`ShapeKonvaNode.tsx` + `shapeGeometry.ts`, the kill-switch fallback AND the PNG export bake in `renderBoardStage.ts`). The Yjs serializer needs no change — it round-trips the payload opaquely.

**Tech Stack:** Next.js/React, TypeScript, `fabric@^7`, `konva@^10` / `react-konva@^19`, `@phosphor-icons/react`, Zustand, Yjs. Tests: `bun test` (bunfig preloads jest-dom). Build gate: `bun run build` (does NOT type-check via tsc; build is the real gate).

## Global Constraints

- Work directly on `develop` in `web/` — no feature branch (user directive). Pull latest `develop` first.
- Opacity is `0..1` normalized on `ShapePayload`, whole-shape, default `1` (absent = 1). NOT on the base `StudioOverlay` (text/image out of scope).
- Arrow renders on the box mid-line `[0, h/2, w, h/2]`, rotated via overlay `rotation`. It does NOT use the `line`/`ShapeLine` field. Arrowhead config lives in a new `arrow` field.
- `star`/`diamond`/`chevron` add NO new payload fields — fill + stroke + opacity only, no corner radius (consistent with triangle/polygon).
- Arrowhead pointer sizes (`pointer_length`, `pointer_width`) are normalized `0..1` fractions of overlay width, same convention as `stroke.width`.
- Geometry point functions MUST make the shape's point bounding box exactly `[0,w]×[0,h]` (fill the box) — the resize scale math and selection handles depend on it (see `regularPolygonPoints` docblock).
- `KvFabricCanvas.tsx` has no unit tests (needs a real canvas). Its changes are verified by manual e2e (Task 8). Everything else is unit-tested.
- Web tests run with `bun test <path>`. Never `bunx vitest`.

---

### Task 1: Extend shape types

**Files:**
- Modify: `web/src/types/studio.ts:432-455`
- Test: `web/src/types/studio.shape.test.ts`

**Interfaces:**
- Produces: `ShapeKind` gains `"arrow" | "star" | "diamond" | "chevron"`. New `ShapeArrowheads` type. `ShapePayload` gains `opacity?: number` and `arrow?: ShapeArrowheads`.

- [ ] **Step 1: Write the failing test**

Add to `web/src/types/studio.shape.test.ts` (create the block if the file lacks it):

```ts
import { describe, it, expect } from "bun:test";
import type { ShapePayload, ShapeKind } from "@/types/studio";

describe("ShapePayload — arrows/opacity/presets", () => {
  it("accepts arrow kind with arrowheads + opacity", () => {
    const p: ShapePayload = {
      type: "shape",
      kind: "arrow",
      color: "#4B5563",
      opacity: 0.5,
      arrow: { at_start: false, at_end: true, pointer_length: 0.05, pointer_width: 0.05 },
    };
    expect(p.kind).toBe("arrow");
    expect(p.opacity).toBe(0.5);
    expect(p.arrow?.at_end).toBe(true);
  });

  it("accepts star/diamond/chevron kinds", () => {
    const kinds: ShapeKind[] = ["star", "diamond", "chevron"];
    for (const kind of kinds) {
      const p: ShapePayload = { type: "shape", kind, color: "#000000" };
      expect(p.kind).toBe(kind);
    }
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/types/studio.shape.test.ts`
Expected: FAIL — TypeScript rejects `kind: "arrow"` / `opacity` / `arrow` (not in current types).

- [ ] **Step 3: Edit the types**

In `web/src/types/studio.ts`, replace lines 432-455 with:

```ts
export type ShapeKind =
  | "rectangle"
  | "ellipse"
  | "triangle"
  | "polygon"
  | "line"
  | "arrow"
  | "star"
  | "diamond"
  | "chevron";

/** Fixed 2-color gradient — identical shape to the text overlay gradient. */
export type ShapeGradient = { type?: "linear" | "radial"; from: string; to: string; angle: number };

/** Optional shape border. width is normalized (fraction of overlay width). */
export type ShapeStroke = { color: string; width: number };

/** line only — two endpoints, each normalized [0,1] to the board's fit rect
 *  (x against width, y against height). When present this is the source of
 *  truth for the segment at ANY angle; the envelope box is its AABB. Legacy
 *  lines without it fall back to a horizontal segment inside the box. */
export type ShapeLine = { x1: number; y1: number; x2: number; y2: number };

/** arrow only — arrowhead direction + size. pointer_length/pointer_width are
 *  normalized fractions of the overlay width (same convention as stroke.width). */
export type ShapeArrowheads = {
  at_start?: boolean;       // default false
  at_end?: boolean;         // default true
  pointer_length?: number;  // normalized to overlay width
  pointer_width?: number;   // normalized to overlay width
};

export type ShapePayload = {
  type: "shape";
  kind: ShapeKind;
  color: string; // solid fill / gradient base, #RRGGBB
  gradient?: ShapeGradient;
  stroke?: ShapeStroke;
  corner_radius?: number; // rectangle only, 0..1
  sides?: number;         // polygon only, 3..12
  line?: ShapeLine;       // line only — two normalized endpoints (any angle)
  opacity?: number;       // whole-shape, 0..1, default 1 (absent = 1)
  arrow?: ShapeArrowheads; // arrow only
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/types/studio.shape.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web/src/types/studio.ts web/src/types/studio.shape.test.ts
git commit -m "feat(web): extend shape payload with arrow/opacity/preset kinds"
```

---

### Task 2: Geometry + Konva props (shapeGeometry.ts)

**Files:**
- Modify: `web/src/components/studio/kv-generator/overlays/shapeGeometry.ts`
- Test: `web/src/components/studio/kv-generator/overlays/shapeGeometry.test.ts`

**Interfaces:**
- Consumes: `ShapePayload` (Task 1).
- Produces: `starPoints(w,h)`, `diamondPoints(w,h)`, `chevronPoints(w,h)` (flat `number[]`, bbox = `[0,w]×[0,h]`). `KonvaShapeSpec.konva` union gains `"Arrow"`. `shapeKonvaGeometry` handles the 4 new kinds and threads `opacity`.

- [ ] **Step 1: Write the failing tests**

Append to `overlays/shapeGeometry.test.ts`:

```ts
import { starPoints, diamondPoints, chevronPoints } from "./shapeGeometry";

const fillsBox = (pts: number[], w: number, h: number) => {
  const xs = pts.filter((_, i) => i % 2 === 0);
  const ys = pts.filter((_, i) => i % 2 === 1);
  expect(Math.min(...xs)).toBeCloseTo(0, 5);
  expect(Math.max(...xs)).toBeCloseTo(w, 5);
  expect(Math.min(...ys)).toBeCloseTo(0, 5);
  expect(Math.max(...ys)).toBeCloseTo(h, 5);
};

describe("new preset geometry", () => {
  it("starPoints returns 10 vertices (5-point star) and fills the box", () => {
    const pts = starPoints(200, 100);
    expect(pts).toHaveLength(20);
    fillsBox(pts, 200, 100);
  });
  it("diamondPoints returns 4 vertices and fills the box", () => {
    const pts = diamondPoints(120, 80);
    expect(pts).toEqual([60, 0, 120, 40, 60, 80, 0, 40]);
    fillsBox(pts, 120, 80);
  });
  it("chevronPoints returns 6 vertices and fills the box", () => {
    const pts = chevronPoints(100, 100);
    expect(pts).toHaveLength(12);
    fillsBox(pts, 100, 100);
  });
});

describe("opacity + new kinds in shapeKonvaGeometry", () => {
  it("threads opacity into every kind's props", () => {
    expect(shapeKonvaGeometry(shape({ kind: "rectangle", opacity: 0.4 }), 100, 60).props.opacity).toBe(0.4);
    expect(shapeKonvaGeometry(shape({ kind: "line", opacity: 0.4 }), 100, 60).props.opacity).toBe(0.4);
  });
  it("defaults opacity to 1 when absent", () => {
    expect(shapeKonvaGeometry(shape({ kind: "ellipse" }), 100, 60).props.opacity).toBe(1);
  });
  it("maps star/diamond/chevron to closed Line", () => {
    for (const kind of ["star", "diamond", "chevron"] as const) {
      const spec = shapeKonvaGeometry(shape({ kind }), 100, 60);
      expect(spec.konva).toBe("Line");
      expect(spec.props.closed).toBe(true);
    }
  });
  it("maps arrow to Arrow with pointer config", () => {
    const spec = shapeKonvaGeometry(
      shape({ kind: "arrow", arrow: { at_start: true, at_end: true, pointer_length: 0.1, pointer_width: 0.1 } }),
      200, 100,
    );
    expect(spec.konva).toBe("Arrow");
    expect(spec.props.points).toEqual([0, 50, 200, 50]);
    expect(spec.props.pointerAtBeginning).toBe(true);
    expect(spec.props.pointerAtEnding).toBe(true);
    expect(spec.props.pointerLength).toBe(0.1 * 200);
    expect(spec.props.pointerWidth).toBe(0.1 * 200);
  });
  it("arrow defaults: end-only head, no beginning", () => {
    const spec = shapeKonvaGeometry(shape({ kind: "arrow" }), 100, 100);
    expect(spec.props.pointerAtBeginning).toBe(false);
    expect(spec.props.pointerAtEnding).toBe(true);
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd web && bun test src/components/studio/kv-generator/overlays/shapeGeometry.test.ts`
Expected: FAIL — `starPoints`/`diamondPoints`/`chevronPoints` undefined; arrow/opacity not handled.

- [ ] **Step 3: Implement geometry + props**

In `overlays/shapeGeometry.ts`:

(a) Refactor the bbox-remap out of `regularPolygonPoints` into a shared helper (behavior-preserving), and add the three new point functions. Replace lines 19-43 with:

```ts
/** Remap raw unit-ish vertex arrays so their bounding box fills [0,w]×[0,h]. */
function remapToBox(xs: number[], ys: number[], w: number, h: number): number[] {
  const minX = Math.min(...xs);
  const maxX = Math.max(...xs);
  const minY = Math.min(...ys);
  const maxY = Math.max(...ys);
  const spanX = maxX - minX || 1;
  const spanY = maxY - minY || 1;
  const pts: number[] = [];
  for (let i = 0; i < xs.length; i++) {
    pts.push(((xs[i] - minX) / spanX) * w, ((ys[i] - minY) / spanY) * h);
  }
  return pts;
}

export function regularPolygonPoints(sides: number, w: number, h: number): number[] {
  const n = Math.max(3, Math.round(sides));
  const xs: number[] = [];
  const ys: number[] = [];
  for (let i = 0; i < n; i++) {
    const a = -Math.PI / 2 + (i * 2 * Math.PI) / n; // start at top
    xs.push(Math.cos(a));
    ys.push(Math.sin(a));
  }
  return remapToBox(xs, ys, w, h);
}

export function trianglePoints(w: number, h: number): number[] {
  return regularPolygonPoints(3, w, h);
}

/** 5-point star; alternating outer (r=1) / inner (r=0.5) radii, first point up. */
export function starPoints(w: number, h: number, points = 5, innerRatio = 0.5): number[] {
  const n = Math.max(3, Math.round(points));
  const xs: number[] = [];
  const ys: number[] = [];
  for (let i = 0; i < n * 2; i++) {
    const r = i % 2 === 0 ? 1 : innerRatio;
    const a = -Math.PI / 2 + (i * Math.PI) / n; // half a wedge per vertex
    xs.push(Math.cos(a) * r);
    ys.push(Math.sin(a) * r);
  }
  return remapToBox(xs, ys, w, h);
}

/** 4-point rhombus that exactly fills the box. */
export function diamondPoints(w: number, h: number): number[] {
  return [w / 2, 0, w, h / 2, w / 2, h, 0, h / 2];
}

/** 6-point right-pointing chevron/arrow-block that fills the box. */
export function chevronPoints(w: number, h: number): number[] {
  const tip = 0.6;   // x where the right point's base begins
  const notch = 0.4; // x depth of the left notch
  return [0, 0, w * tip, 0, w, h / 2, w * tip, h, 0, h, w * notch, h / 2];
}
```

(b) Add `"Arrow"` to the spec union (line 55-58):

```ts
export type KonvaShapeSpec = {
  konva: "Rect" | "Ellipse" | "Line" | "Arrow";
  props: Record<string, unknown>;
};
```

(c) Thread opacity + add the new cases in `shapeKonvaGeometry`. Replace the body from `const common = ...` (line 73) through the end of the switch (line 101) with:

```ts
  const common = { ...fill, ...stroke, opacity: payload.opacity ?? 1, strokeScaleEnabled: false };
  switch (payload.kind) {
    case "ellipse":
      return { konva: "Ellipse", props: { radiusX: w / 2, radiusY: h / 2, ...common } };
    case "triangle":
      return { konva: "Line", props: { points: trianglePoints(w, h), closed: true, ...common } };
    case "polygon":
      return {
        konva: "Line",
        props: { points: regularPolygonPoints(payload.sides ?? 6, w, h), closed: true, ...common },
      };
    case "star":
      return { konva: "Line", props: { points: starPoints(w, h), closed: true, ...common } };
    case "diamond":
      return { konva: "Line", props: { points: diamondPoints(w, h), closed: true, ...common } };
    case "chevron":
      return { konva: "Line", props: { points: chevronPoints(w, h), closed: true, ...common } };
    case "line":
      // Line has no fill; it is a stroked segment across the box mid-line.
      return {
        konva: "Line",
        props: {
          points: [0, h / 2, w, h / 2],
          stroke: payload.stroke?.color ?? payload.color,
          strokeWidth: (payload.stroke?.width ?? 0.008) * w,
          opacity: payload.opacity ?? 1,
          strokeScaleEnabled: false,
        },
      };
    case "arrow": {
      // Stroked segment across the box mid-line + arrowhead(s). Konva.Arrow
      // fills the head with `fill` and strokes the shaft with `stroke`; use the
      // same color for both so the head matches the shaft.
      const a = payload.arrow ?? {};
      const color = payload.stroke?.color ?? payload.color;
      return {
        konva: "Arrow",
        props: {
          points: [0, h / 2, w, h / 2],
          stroke: color,
          fill: color,
          strokeWidth: (payload.stroke?.width ?? 0.01) * w,
          pointerAtBeginning: a.at_start ?? false,
          pointerAtEnding: a.at_end ?? true,
          pointerLength: (a.pointer_length ?? 0.05) * w,
          pointerWidth: (a.pointer_width ?? 0.05) * w,
          opacity: payload.opacity ?? 1,
          strokeScaleEnabled: false,
        },
      };
    }
    case "rectangle":
    default:
      return {
        konva: "Rect",
        props: { width: w, height: h, cornerRadius: (payload.corner_radius ?? 0) * Math.min(w, h), ...common },
      };
  }
```

No change needed to `bakeShapeNodeConfig` centering — only `ellipse` is centered; arrow/star/diamond/chevron fill from top-left like triangle/polygon, so their `offsetX/Y = w/2, h/2` is correct.

- [ ] **Step 4: Run to verify pass**

Run: `cd web && bun test src/components/studio/kv-generator/overlays/shapeGeometry.test.ts`
Expected: PASS (including the pre-existing `regularPolygonPoints`/`trianglePoints` tests — the refactor is behavior-preserving).

- [ ] **Step 5: Commit**

```bash
git add web/src/components/studio/kv-generator/overlays/shapeGeometry.ts web/src/components/studio/kv-generator/overlays/shapeGeometry.test.ts
git commit -m "feat(web): shape geometry for arrow/star/diamond/chevron + opacity"
```

---

### Task 3: Konva render node (ShapeKonvaNode.tsx)

**Files:**
- Modify: `web/src/components/studio/kv-generator/overlays/ShapeKonvaNode.tsx`
- Test: `web/src/components/studio/kv-generator/overlays/ShapeKonvaNode.test.tsx`

**Interfaces:**
- Consumes: `shapeKonvaGeometry` (Task 2, now emits `"Arrow"`).
- Produces: `ShapeKonvaNode` renders all 9 kinds (adds `Arrow`).

- [ ] **Step 1: Write the failing test**

Append to `overlays/ShapeKonvaNode.test.tsx` (mirror the existing render assertions in that file — reuse its existing render harness/imports):

```ts
describe("ShapeKonvaNode — new kinds", () => {
  for (const kind of ["arrow", "star", "diamond", "chevron"] as const) {
    it(`renders ${kind} without throwing`, () => {
      // Uses the same render helper the existing tests in this file use.
      expect(() =>
        renderShape({ type: "shape", kind, color: "#123456" }, 100, 60),
      ).not.toThrow();
    });
  }
});
```

If the existing file doesn't expose a `renderShape` helper, follow the exact render pattern already used by the other tests in `ShapeKonvaNode.test.tsx` (they render inside a react-konva `Stage`/`Layer`) — do NOT invent a new harness.

- [ ] **Step 2: Run to verify failure**

Run: `cd web && bun test src/components/studio/kv-generator/overlays/ShapeKonvaNode.test.tsx`
Expected: FAIL — `arrow` maps to `"Arrow"`, which is not in `KONVA_COMPONENT`, so the lookup is undefined and render throws.

- [ ] **Step 3: Add the Arrow component**

Replace lines 2 and 9-13 of `ShapeKonvaNode.tsx`:

```ts
import { Rect, Ellipse, Line, Arrow } from "react-konva";
```

```ts
const KONVA_COMPONENT: Record<"Rect" | "Ellipse" | "Line" | "Arrow", AnyKonvaComp> = {
  Rect: Rect as unknown as AnyKonvaComp,
  Ellipse: Ellipse as unknown as AnyKonvaComp,
  Line: Line as unknown as AnyKonvaComp,
  Arrow: Arrow as unknown as AnyKonvaComp,
};
```

(The `localPos` centering stays as-is — only `ellipse` is centered; arrow/star/diamond/chevron render from their top-left local origin.)

- [ ] **Step 4: Run to verify pass**

Run: `cd web && bun test src/components/studio/kv-generator/overlays/ShapeKonvaNode.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web/src/components/studio/kv-generator/overlays/ShapeKonvaNode.tsx web/src/components/studio/kv-generator/overlays/ShapeKonvaNode.test.tsx
git commit -m "feat(web): render arrow/star/diamond/chevron shape nodes on Konva"
```

---

### Task 4: Fabric renderer (KvFabricCanvas.tsx) — the live canvas

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvFabricCanvas.tsx` (shape reconcile ~1292-1420; add a module-level arrow helper)

**Interfaces:**
- Consumes: `starPoints`/`diamondPoints`/`chevronPoints` (Task 2), `strokePropsFor`, `applyShapeFill`, `pointPairs` (existing imports in this file).
- Produces: Fabric objects for the 4 new kinds + opacity applied on all shapes.

> No unit test — `KvFabricCanvas` needs a real canvas. Verified in Task 8 manual e2e. Keep changes minimal and mirror the existing Polygon/Line branches exactly.

- [ ] **Step 1: Import the new geometry helpers**

Ensure the file's import from `./overlays/shapeGeometry` includes `starPoints, diamondPoints, chevronPoints` (it already imports `trianglePoints, regularPolygonPoints, strokePropsFor`). Add the three names to that import.

- [ ] **Step 2: Add a module-level arrow builder**

Near the other module-level helpers (top of the file, outside the component), add:

```ts
/** Arrow = stroked shaft on the box mid-line + V-heads. Built in local box
 *  space [0..w, 0..h]; the enclosing fabric.Group's originX/Y=center + left/top
 *  position it exactly like the Polygon branch. Fabric has no native Arrow. */
function arrowChildren(sp: ShapePayload, w: number, h: number): fabric.Line[] {
  const color = sp.stroke?.color ?? sp.color;
  const strokeWidth = (sp.stroke?.width ?? 0.01) * w;
  const pl = (sp.arrow?.pointer_length ?? 0.05) * w;
  const pw = (sp.arrow?.pointer_width ?? 0.05) * w;
  const my = h / 2;
  const opt = { stroke: color, strokeWidth, strokeUniform: true, selectable: false, evented: false };
  const lines: fabric.Line[] = [new fabric.Line([0, my, w, my], { ...opt })];
  if (sp.arrow?.at_end ?? true) {
    lines.push(new fabric.Line([w, my, w - pl, my - pw / 2], { ...opt }));
    lines.push(new fabric.Line([w, my, w - pl, my + pw / 2], { ...opt }));
  }
  if (sp.arrow?.at_start) {
    lines.push(new fabric.Line([0, my, pl, my - pw / 2], { ...opt }));
    lines.push(new fabric.Line([0, my, pl, my + pw / 2], { ...opt }));
  }
  return lines;
}

function buildFabricArrow(sp: ShapePayload, w: number, h: number, common: Record<string, unknown>): fabric.Group {
  return new fabric.Group(arrowChildren(sp, w, h), { ...common });
}
```

If `ShapePayload` / `fabric` aren't already imported in this file, add them (they are — the file already uses `fabric.*` and shape types).

- [ ] **Step 3: Handle new kinds in the BUILD branch**

In the `switch (sp.kind)` at lines 1376-1410, add cases for the presets and arrow (place the preset cases next to `triangle`/`polygon`, and `arrow` before `rectangle`/default):

```ts
            case "star":
              obj = new fabric.Polygon(pointPairs(starPoints(w, h)), { ...common });
              break;
            case "diamond":
              obj = new fabric.Polygon(pointPairs(diamondPoints(w, h)), { ...common });
              break;
            case "chevron":
              obj = new fabric.Polygon(pointPairs(chevronPoints(w, h)), { ...common });
              break;
            case "arrow":
              obj = buildFabricArrow(sp, w, h, common);
              break;
```

Then extend the fill line (1411) so arrow/line skip fill (arrow is stroke-only):

```ts
          if (sp.kind !== "line" && sp.kind !== "arrow") applyShapeFill(obj, sp, w, h);
```

- [ ] **Step 4: Apply opacity in the BUILD `common`**

In the `common` object built at 1366-1374, add `opacity`:

```ts
          const common = {
            left,
            top,
            angle: overlay.rotation,
            originX: "center" as const,
            originY: "center" as const,
            strokeUniform: true,
            opacity: sp.opacity ?? 1,
            ...strokeProps,
          };
```

- [ ] **Step 5: Handle new kinds + opacity in the REUSE branch**

In the reuse branch (1301-1359):

(a) Extend the `fabric.Polygon` points ternary (1321-1330) to pick the right geometry per kind:

```ts
          } else if (found instanceof fabric.Group) {
            // arrow: rebuild its child lines for the new box, in place (keeps
            // selection). Group bbox recomputes from children.
            found.remove(...found.getObjects());
            found.add(...arrowChildren(sp, w, h));
          } else if (found instanceof fabric.Polygon) {
            const pts =
              sp.kind === "triangle" ? trianglePoints(w, h)
              : sp.kind === "star" ? starPoints(w, h)
              : sp.kind === "diamond" ? diamondPoints(w, h)
              : sp.kind === "chevron" ? chevronPoints(w, h)
              : regularPolygonPoints(sp.sides ?? 6, w, h);
            found.set({ points: pointPairs(pts) });
            dim(found);
          }
```

(Insert the `fabric.Group` branch BEFORE the `fabric.Polygon` branch, since a Group is not a Polygon. Keep the existing Ellipse/Rect/Line branches above it unchanged.)

(b) Extend the stroke/fill application (1331-1343) so arrow is treated stroke-only like line, and opacity is applied to every reused shape. Replace that block with:

```ts
          if (sp.kind === "line") {
            found.set({
              stroke: sp.stroke?.color ?? sp.color,
              strokeWidth: (sp.stroke?.width ?? 0.008) * w,
            });
          } else if (sp.kind === "arrow") {
            // stroke color/width live on the group's child lines (rebuilt above)
          } else {
            const strokeProps = strokePropsFor(sp, w, h);
            found.set({
              stroke: strokeProps.stroke,
              strokeWidth: strokeProps.strokeWidth ?? 0,
            });
            applyShapeFill(found, sp, w, h);
          }
          found.set({ opacity: sp.opacity ?? 1 });
```

(c) The reuse guard uses `_shapeMeta.kind === sp.kind`, so switching to/from `arrow` (Group) vs a Polygon kind forces a rebuild (kind differs) — correct, since the object class changes.

- [ ] **Step 6: Type-check via build**

Run: `cd web && bun run build`
Expected: build succeeds (exit 0). Fix any TS errors surfaced (e.g. `fabric.Group` typing) before proceeding.

- [ ] **Step 7: Commit**

```bash
git add web/src/components/studio/kv-generator/KvFabricCanvas.tsx
git commit -m "feat(web): render arrow/star/diamond/chevron + opacity on Fabric canvas"
```

---

### Task 5: Shape picker (ShapePicker.tsx)

**Files:**
- Modify: `web/src/components/studio/kv-generator/ShapePicker.tsx`
- Test: `web/src/components/studio/kv-generator/ShapePicker.test.tsx`

**Interfaces:**
- Produces: picker lists all 9 kinds, grouped Basic vs Lines with a divider.

- [ ] **Step 1: Write the failing test**

Append to `ShapePicker.test.tsx` (mirror its existing render/click pattern):

```ts
describe("ShapePicker — new kinds", () => {
  for (const label of ["Arrow", "Star", "Diamond", "Chevron"]) {
    it(`offers ${label} and fires onPick`, () => {
      const onPick = mock(() => {});
      const onClose = mock(() => {});
      render(<ShapePicker open onPick={onPick} onClose={onClose} />);
      fireEvent.click(screen.getByRole("button", { name: label }));
      expect(onPick).toHaveBeenCalledTimes(1);
    });
  }
});
```

Use the same imports the existing tests in the file use (`bun:test`, `@testing-library/react`).

- [ ] **Step 2: Run to verify failure**

Run: `cd web && bun test src/components/studio/kv-generator/ShapePicker.test.tsx`
Expected: FAIL — no Arrow/Star/Diamond/Chevron buttons.

- [ ] **Step 3: Add kinds + light grouping**

Replace lines 4-19 and the render body (43-57) of `ShapePicker.tsx`:

```tsx
import {
  ArrowRight,
  CaretRight,
  Circle,
  Diamond,
  LineSegment,
  Pentagon,
  Square,
  Star,
  Triangle,
} from "@phosphor-icons/react";
import type { ShapeKind } from "@/types/studio";

type PickerEntry = { kind: ShapeKind; label: string; icon: React.ReactNode };

const BASIC: PickerEntry[] = [
  { kind: "rectangle", label: "Rectangle", icon: <Square size={20} /> },
  { kind: "ellipse", label: "Ellipse", icon: <Circle size={20} /> },
  { kind: "triangle", label: "Triangle", icon: <Triangle size={20} /> },
  { kind: "polygon", label: "Polygon", icon: <Pentagon size={20} /> },
  { kind: "star", label: "Star", icon: <Star size={20} /> },
  { kind: "diamond", label: "Diamond", icon: <Diamond size={20} /> },
  { kind: "chevron", label: "Chevron", icon: <CaretRight size={20} /> },
];

const LINES: PickerEntry[] = [
  { kind: "line", label: "Line", icon: <LineSegment size={20} /> },
  { kind: "arrow", label: "Arrow", icon: <ArrowRight size={20} /> },
];
```

Then in the render, replace the single `{KINDS.map(...)}` block with a small helper + two groups separated by a divider:

```tsx
  const renderEntry = ({ kind, label, icon }: PickerEntry) => (
    <button
      key={kind}
      type="button"
      aria-label={label}
      title={label}
      onClick={() => {
        onPick(kind);
        onClose();
      }}
      className="flex h-9 w-9 items-center justify-center rounded-xl text-text-inverse transition-colors duration-200 hover:bg-white/10 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-white/40"
    >
      {icon}
    </button>
  );

  return (
    <div
      role="menu"
      className="absolute bottom-full left-1/2 z-20 mb-2 flex -translate-x-1/2 items-center gap-1 rounded-2xl border border-[rgba(255,255,255,0.05)] bg-neutral-900/90 p-1.5 shadow-[0_16px_24px_0_rgba(0,0,0,0.8)] backdrop-blur-[16px]"
    >
      {BASIC.map(renderEntry)}
      <div className="mx-0.5 h-6 w-px bg-white/10" aria-hidden />
      {LINES.map(renderEntry)}
    </div>
  );
```

- [ ] **Step 4: Run to verify pass**

Run: `cd web && bun test src/components/studio/kv-generator/ShapePicker.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web/src/components/studio/kv-generator/ShapePicker.tsx web/src/components/studio/kv-generator/ShapePicker.test.tsx
git commit -m "feat(web): add arrow/star/diamond/chevron to shape picker with grouping"
```

---

### Task 6: Style controls + analytics (ShapeStyleControls.tsx, kv-generator-events.ts)

**Files:**
- Modify: `web/src/lib/analytics/kv-generator-events.ts:461-465` (extend `KvShapeStyleProperty`)
- Modify: `web/src/components/studio/kv-generator/overlays/ShapeStyleControls.tsx`
- Test: `web/src/components/studio/kv-generator/overlays/ShapeStyleControls.test.tsx`

**Interfaces:**
- Consumes: `trackKvShapeStyleChanged` (existing).
- Produces: an Opacity slider (all kinds) emitting `onPatch({ opacity })`; an Arrowheads cluster (arrow only) emitting `onPatch({ arrow })`; fill hidden for `arrow` as well as `line`.

- [ ] **Step 1: Write the failing tests**

Append to `overlays/ShapeStyleControls.test.tsx`:

```ts
it("opacity slider patches normalized opacity", () => {
  const onPatch = mock(() => {});
  render(<ShapeStyleControls payload={base} onPatch={onPatch} />);
  const slider = screen.getByRole("slider", { name: "Opacity" });
  fireEvent.change(slider, { target: { value: "40" } });
  expect(onPatch).toHaveBeenCalledWith(expect.objectContaining({ opacity: 0.4 }));
});

it("hides fill controls for arrow kind and shows arrowhead toggles", () => {
  const onPatch = mock(() => {});
  const arrowPayload: ShapePayload = { type: "shape", kind: "arrow", color: "#0000ff" };
  render(<ShapeStyleControls payload={arrowPayload} onPatch={onPatch} />);
  expect(screen.queryByRole("button", { name: "Solid" })).toBeNull();
  expect(screen.getByRole("checkbox", { name: "Arrowhead at end" })).toBeInTheDocument();
  expect(screen.getByRole("checkbox", { name: "Arrowhead at start" })).toBeInTheDocument();
});

it("toggling arrowhead-at-start patches the arrow config", () => {
  const onPatch = mock(() => {});
  const arrowPayload: ShapePayload = { type: "shape", kind: "arrow", color: "#0000ff" };
  render(<ShapeStyleControls payload={arrowPayload} onPatch={onPatch} />);
  fireEvent.click(screen.getByRole("checkbox", { name: "Arrowhead at start" }));
  expect(onPatch).toHaveBeenCalledWith(
    expect.objectContaining({ arrow: expect.objectContaining({ at_start: true }) }),
  );
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd web && bun test src/components/studio/kv-generator/overlays/ShapeStyleControls.test.tsx`
Expected: FAIL — no Opacity slider / Arrowhead checkboxes; fill still shown for arrow.

- [ ] **Step 3: Extend the analytics property union**

In `web/src/lib/analytics/kv-generator-events.ts`, extend `KvShapeStyleProperty` (lines 461-465):

```ts
export type KvShapeStyleProperty =
  | "fill"
  | "stroke"
  | "sides"
  | "corner_radius"
  | "opacity"
  | "arrow";
```

- [ ] **Step 4: Update the style controls**

In `ShapeStyleControls.tsx`:

(a) Change the fill guard (line 26) to hide fill for arrow too:

```ts
  const isLine = payload.kind === "line";
  const isArrow = payload.kind === "arrow";
  const hideFill = isLine || isArrow;
  const stroke = payload.stroke;
  const DEFAULT_ARROW = { at_start: false, at_end: true, pointer_length: 0.05, pointer_width: 0.05 };
```

Update the fill block condition (line 35) from `{!isLine && (` to `{!hideFill && (`.

(b) Add the Arrowheads cluster — insert right after the Stroke block (after line 107, before the `polygon` block). It exposes start/end toggles and a single size control driving both pointer dimensions:

```tsx
      {isArrow && (
        <div className="mt-2 flex flex-col gap-2">
          <span className="font-geist text-textXs text-text-inverse-subtlest">Arrowheads</span>
          <label className="flex items-center justify-between">
            <span className="font-geist text-textXs text-text-inverse-subtlest">Arrowhead at start</span>
            <input
              type="checkbox"
              aria-label="Arrowhead at start"
              checked={payload.arrow?.at_start ?? false}
              onChange={(e) => {
                onPatch({ arrow: { ...DEFAULT_ARROW, ...payload.arrow, at_start: e.target.checked } });
                trackKvShapeStyleChanged({ property: "arrow" });
              }}
              className="h-4 w-4 rounded border-white/20 bg-white/5 accent-white/80"
            />
          </label>
          <label className="flex items-center justify-between">
            <span className="font-geist text-textXs text-text-inverse-subtlest">Arrowhead at end</span>
            <input
              type="checkbox"
              aria-label="Arrowhead at end"
              checked={payload.arrow?.at_end ?? true}
              onChange={(e) => {
                onPatch({ arrow: { ...DEFAULT_ARROW, ...payload.arrow, at_end: e.target.checked } });
                trackKvShapeStyleChanged({ property: "arrow" });
              }}
              className="h-4 w-4 rounded border-white/20 bg-white/5 accent-white/80"
            />
          </label>
          <div className="flex items-center gap-2">
            <span className="w-20 shrink-0 font-geist text-textXs text-text-inverse-subtlest">Head size</span>
            <input
              type="number"
              aria-label="Arrowhead size"
              min={0}
              max={0.3}
              step={0.01}
              value={payload.arrow?.pointer_length ?? 0.05}
              onChange={(e) => {
                const next = Math.max(0, Math.min(0.3, Number(e.target.value) || 0));
                onPatch({ arrow: { ...DEFAULT_ARROW, ...payload.arrow, pointer_length: next, pointer_width: next } });
              }}
              onBlur={() => trackKvShapeStyleChanged({ property: "arrow" })}
              className="w-full rounded-md border border-white/10 bg-white/5 px-2 py-1 font-geist text-textXs text-text-inverse outline-none focus:border-white/20"
            />
          </div>
        </div>
      )}
```

(c) Add the Opacity slider — insert just before the closing `</div>` of the panel (after the `rectangle` corner-radius block, line 158), shown for every kind:

```tsx
      <div className="mt-2 flex items-center gap-2">
        <span className="w-20 shrink-0 font-geist text-textXs text-text-inverse-subtlest">Opacity</span>
        <input
          type="range"
          aria-label="Opacity"
          min={0}
          max={100}
          step={1}
          value={Math.round((payload.opacity ?? 1) * 100)}
          onChange={(e) => onPatch({ opacity: Number(e.target.value) / 100 })}
          onMouseUp={() => trackKvShapeStyleChanged({ property: "opacity" })}
          className="w-full accent-white/80"
        />
        <span className="w-8 shrink-0 text-right font-geist text-textXs text-text-inverse-subtlest">
          {Math.round((payload.opacity ?? 1) * 100)}
        </span>
      </div>
```

- [ ] **Step 5: Run to verify pass**

Run: `cd web && bun test src/components/studio/kv-generator/overlays/ShapeStyleControls.test.tsx`
Expected: PASS. (The existing "hides fill controls for line kind" test still passes — `hideFill` covers line.)

- [ ] **Step 6: Commit**

```bash
git add web/src/components/studio/kv-generator/overlays/ShapeStyleControls.tsx web/src/lib/analytics/kv-generator-events.ts web/src/components/studio/kv-generator/overlays/ShapeStyleControls.test.tsx
git commit -m "feat(web): opacity slider + arrowhead controls in shape style panel"
```

---

### Task 7: Place-shape defaults (KvGeneratorLayout.tsx)

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx:2828-2836` (the `payload` in `handlePlaceShape`)

**Interfaces:**
- Consumes: `ShapePayload` (Task 1).
- Produces: sensible defaults when placing an `arrow` (stroke + end arrowhead).

- [ ] **Step 1: Update the default payload**

In `handlePlaceShape`, extend the payload spread so arrow gets a stroke (its color/width source) and a default end arrowhead. Replace the `const payload: ShapePayload = { ... }` literal with:

```ts
    const payload: ShapePayload = {
      type: "shape",
      kind,
      color: "#4B5563", // sensible default fill (brand-neutral gray)
      ...(kind === "polygon" ? { sides: 6 } : {}),
      ...(kind === "line" ? { stroke: { color: "#4B5563", width: 0.008 } } : {}),
      ...(kind === "arrow"
        ? {
            stroke: { color: "#4B5563", width: 0.01 },
            arrow: { at_start: false, at_end: true, pointer_length: 0.05, pointer_width: 0.05 },
          }
        : {}),
    };
```

- [ ] **Step 2: Build to verify**

Run: `cd web && bun run build`
Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
git add web/src/components/studio/kv-generator/KvGeneratorLayout.tsx
git commit -m "feat(web): default stroke + end arrowhead when placing an arrow"
```

---

### Task 8: Full build + manual e2e verification

**Files:** none (verification only).

- [ ] **Step 1: Full unit suite for shapes + build gate**

```bash
cd web
bun test src/components/studio/kv-generator/overlays src/components/studio/kv-generator/ShapePicker.test.tsx src/types/studio.shape.test.ts
bun run build
```
Expected: all shape tests pass; build exits 0.

- [ ] **Step 2: Manual e2e in the KV generator (Fabric path — not unit-tested)**

Start the app (`bun dev`) and open a KV file's Craft canvas. Verify:
- Picker shows Basic group (rectangle, ellipse, triangle, polygon, star, diamond, chevron) + divider + Lines group (line, arrow).
- Place each new kind: star, diamond, chevron render filled and fill the dragged box; arrow renders with an end arrowhead.
- Select an arrow → style panel shows Arrowheads (start/end toggles + head size), NO fill section; toggling start adds a second head; head size changes visibly; stroke color/width changes the arrow color/thickness.
- Opacity slider present for every kind; dragging it fades the shape (fill + stroke together).
- Resize, rotate, and move each new kind — geometry stays correct (no exponential grow, no drift); arrow keeps selection across resize.
- Reload the page → all shapes + opacity + arrowheads persist (Yjs + API round-trip).
- Download / export the board → the PNG matches the canvas for every new kind, opacity, and arrowheads (this exercises the Konva bake path).
- Toggle `KV_MULTI_BOARD` off (kill-switch) if feasible → Konva fallback renders the same shapes.

- [ ] **Step 3: Record results**

Note any Fabric geometry/positioning fixes needed (arrow group coords, resize behavior) and iterate on Task 4 until the manual checks pass. Commit fixes with `fix(web): ...`.

## Self-Review Notes (author)

- Spec coverage: opacity (T2/T4/T6, api T? separate plan), arrow (T1-T7), star/diamond/chevron (T1-T7), picker grouping (T5), analytics (T6), Yjs no-op (documented), export bake (T2/T3 shared geometry + Konva Arrow). ✅
- Type consistency: `ShapeArrowheads` fields (`at_start/at_end/pointer_length/pointer_width`), `KonvaShapeSpec.konva` union incl. `"Arrow"`, `KvShapeStyleProperty` incl. `"opacity"|"arrow"` — consistent across tasks. ✅
- Fabric is the untested risk surface — flagged, with manual e2e in T8. ✅
