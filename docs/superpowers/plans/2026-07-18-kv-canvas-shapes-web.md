# KV Canvas Shape Overlays — Web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let designers add editable parametric vector shapes (rectangle, ellipse, triangle, polygon, line) to the KV canvas via drag-to-draw, with solid or 2-color linear/radial gradient fill and an optional stroke — implemented as a third `StudioOverlay` type reusing the existing text-overlay fill infrastructure.

**Architecture:** Shapes ride the existing `StudioOverlay` envelope (normalized geometry, `board_generation_id`, z-order, persistence). Fill reuses the text overlay's `color` + `gradient` model and its resolvers (`resolveTextFill.ts`), which we first refactor to expose a type-agnostic gradient core. Shapes render on both surfaces via shared mapping helpers: Fabric (interactive editor, drag-to-draw + transform) and Konva (resize tiles + PNG export flatten). A new `ShapeStyleControls` editor mirrors `TextTypographyControls`, slotted into the parent panels next to the shared geometry `KvTransformPanel`.

**Tech Stack:** Next.js 16, React 19, TypeScript, Fabric.js, react-konva/Konva, Zustand, `bun test` (jest-dom preloaded via bunfig).

## Global Constraints

- Work in worktree: `/Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/kv-canvas-shapes` (branch `feature/daffa/vc-kv-canvas-shapes`, based on `origin/develop`).
- Run tests with `bun test` (NOT `bunx vitest`). The real gate is `bun run build` (tsc), run it before the final commit.
- Colors: 6-digit hex `#RRGGBB` only (matches `ColorField` + API validation).
- Gradient model is fixed 2-color: `{ type?: "linear" | "radial"; from: string; to: string; angle: number }` — identical to the text overlay. No multi-stop, no per-stop opacity (v1).
- Overlay geometry is normalized [0,1] to the board's fit rect; overlays use `originX/originY: "center"` on both canvases. The 30-overlay cap is unchanged.
- Shape kinds: `rectangle | ellipse | triangle | polygon | line`. Polygon `sides` default 6, range 3–12. `corner_radius` 0–1 (rectangle). `stroke.width` normalized (fraction of overlay width); absent stroke = no border.
- The two-field discrimination (`overlay.type` AND `overlay.payload.type`) means every switch/guard needs a `shape` branch in BOTH spots.
- Analytics: every new interaction needs a PostHog event via the typed wrappers (`trackKvOverlayAdded`, `trackKvOverlayTransformed`, plus a new `trackKvShapeAdded`/reuse) — see the `frndos-analytics-events` skill.

**Interactive-surface note (confirm at Task 6):** The craft canvas renders BOTH `KvKonvaCanvas` and `KvFabricCanvas`. Fabric is the interactive editor (selection/transform/live-drag); Konva also renders overlays and owns resize-tile + export flatten. This plan implements **drag-to-draw on Fabric** and **shape render on both** (Konva keeps a click-to-place fallback for parity). Early in Task 6, verify which surface receives pointer interaction on the craft canvas and place the drag-to-draw there.

---

### Task 1: Shape payload types

**Files:**
- Modify: `src/types/studio.ts` (StudioOverlay ~433-468, BrandOverlayPreset ~507-533)
- Test: `src/types/studio.shape.test.ts`

**Interfaces:**
- Produces: `ShapeKind`, `ShapeGradient`, `ShapeStroke`, `ShapePayload` exported types; `StudioOverlay.type` includes `"shape"`; `StudioOverlay.payload` union includes the shape member; `BrandOverlayPreset.overlays[].type`/`payload` likewise.

- [ ] **Step 1: Write the failing test**

Create `src/types/studio.shape.test.ts` (mirrors `studio.gradient.test.ts`):

```ts
import { describe, it, expect } from "bun:test";
import type { StudioOverlay } from "@/types/studio";

describe("shape payload", () => {
  it("accepts a solid rectangle", () => {
    const p: StudioOverlay["payload"] = {
      type: "shape",
      kind: "rectangle",
      color: "#ff0000",
      corner_radius: 0.2,
    };
    expect(p.type === "shape" && p.kind).toBe("rectangle");
  });

  it("accepts a polygon with gradient + stroke", () => {
    const p: StudioOverlay["payload"] = {
      type: "shape",
      kind: "polygon",
      color: "#00ff00",
      sides: 6,
      gradient: { type: "linear", from: "#ff0000", to: "#0000ff", angle: 90 },
      stroke: { color: "#000000", width: 0.01 },
    };
    expect(p.type === "shape" && p.sides).toBe(6);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/types/studio.shape.test.ts`
Expected: FAIL — type error, `"shape"` not assignable to payload union.

- [ ] **Step 3: Add the types**

In `src/types/studio.ts`, above `StudioOverlay`, add the shared shape types:

```ts
export type ShapeKind = "rectangle" | "ellipse" | "triangle" | "polygon" | "line";

/** Fixed 2-color gradient — identical shape to the text overlay gradient. */
export type ShapeGradient = { type?: "linear" | "radial"; from: string; to: string; angle: number };

/** Optional shape border. width is normalized (fraction of overlay width). */
export type ShapeStroke = { color: string; width: number };

export type ShapePayload = {
  type: "shape";
  kind: ShapeKind;
  color: string; // solid fill / gradient base, #RRGGBB
  gradient?: ShapeGradient;
  stroke?: ShapeStroke;
  corner_radius?: number; // rectangle only, 0..1
  sides?: number;         // polygon only, 3..12
};
```

Then:
1. `StudioOverlay.type` (line ~436): `type: "text" | "image" | "shape";`
2. Add `| ShapePayload` to the `StudioOverlay.payload` union (after the image member, line ~465).
3. `BrandOverlayPreset.overlays[].type` (line ~512): `type: "text" | "image" | "shape";`
4. Add `| ShapePayload` to the `BrandOverlayPreset.overlays[].payload` union (line ~530).

`StudioOverlayDraft` needs no edit — it derives from `StudioOverlay` via `Omit`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test src/types/studio.shape.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/kv-canvas-shapes
git add src/types/studio.ts src/types/studio.shape.test.ts
git commit -m "feat(web): add shape overlay payload types"
```

---

### Task 2: Type-agnostic gradient fill core (refactor resolveTextFill)

**Files:**
- Modify: `src/components/studio/kv-generator/overlays/resolveTextFill.ts`
- Test: `src/components/studio/kv-generator/overlays/resolveTextFill.test.ts` (add cases; file exists)

**Interfaces:**
- Produces:
  - `hasGradient(g: ShapeGradient | undefined | null): g is ShapeGradient` — hex/angle validity guard, no overlay-type coupling.
  - `konvaFill(color: string, gradient: ShapeGradient | undefined | null, w: number, h: number)` — returns the same union `konvaTextFill` returns today (solid | linear | radial Konva props).
  - `fabricGradientSpec(color, gradient, w, h)` — returns the same fabric spec union or `null`.
  - Existing `konvaTextFill(payload, w, h)` / `hasTextGradient` / the old `fabricGradientSpec(payload, w, h)` keep their signatures by delegating to the new core (text callers unchanged).

- [ ] **Step 1: Write the failing test**

Append to `resolveTextFill.test.ts`:

```ts
import { hasGradient, konvaFill } from "./resolveTextFill";

describe("generic gradient core", () => {
  it("hasGradient validates hex + finite angle", () => {
    expect(hasGradient({ from: "#ff0000", to: "#0000ff", angle: 90 })).toBe(true);
    expect(hasGradient({ from: "red", to: "#0000ff", angle: 90 })).toBe(false);
    expect(hasGradient(undefined)).toBe(false);
  });

  it("konvaFill returns a solid fill when no gradient", () => {
    expect(konvaFill("#123456", undefined, 100, 50)).toEqual({ fill: "#123456" });
  });

  it("konvaFill returns linear gradient props", () => {
    const out = konvaFill("#000000", { type: "linear", from: "#ff0000", to: "#0000ff", angle: 0 }, 100, 50) as Record<string, unknown>;
    expect(out.fillLinearGradientColorStops).toEqual([0, "#ff0000", 1, "#0000ff"]);
  });

  it("konvaFill returns radial gradient props", () => {
    const out = konvaFill("#000000", { type: "radial", from: "#ff0000", to: "#0000ff", angle: 0 }, 100, 50) as Record<string, unknown>;
    expect(out.fillRadialGradientColorStops).toEqual([0, "#ff0000", 1, "#0000ff"]);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/components/studio/kv-generator/overlays/resolveTextFill.test.ts`
Expected: FAIL — `hasGradient` / `konvaFill` not exported.

- [ ] **Step 3: Refactor resolveTextFill.ts**

Extract the generic core; keep the text wrappers. Add at top (using `ShapeGradient` from types as the gradient shape — it matches `TextGradient`):

```ts
import type { ShapeGradient } from "@/types/studio";

export function hasGradient(g: ShapeGradient | undefined | null): g is ShapeGradient {
  if (!g) return false;
  return (
    typeof g.from === "string" && /^#[0-9A-Fa-f]{6}$/.test(g.from) &&
    typeof g.to === "string" && /^#[0-9A-Fa-f]{6}$/.test(g.to) &&
    Number.isFinite(g.angle)
  );
}

export function konvaFill(color: string, gradient: ShapeGradient | undefined | null, w: number, h: number) {
  if (!hasGradient(gradient)) return { fill: color };
  const { from, to, angle, type } = gradient;
  if (type === "radial") {
    const center = { x: w / 2, y: h / 2 };
    return {
      fillRadialGradientStartPoint: center,
      fillRadialGradientStartRadius: 0,
      fillRadialGradientEndPoint: center,
      fillRadialGradientEndRadius: radialEndRadius(w, h),
      fillRadialGradientColorStops: [0, from, 1, to],
    };
  }
  const c = gradientLineCoords(angle, w, h);
  return {
    fillLinearGradientStartPoint: { x: c.x1, y: c.y1 },
    fillLinearGradientEndPoint: { x: c.x2, y: c.y2 },
    fillLinearGradientColorStops: [0, from, 1, to],
  };
}

export function fabricGradientSpec(color: string, gradient: ShapeGradient | undefined | null, w: number, h: number) {
  if (!hasGradient(gradient)) return null;
  const { from, to, angle, type } = gradient;
  const colorStops = [{ offset: 0, color: from }, { offset: 1, color: to }];
  if (type === "radial") {
    const r = radialEndRadius(w, h);
    return { type: "radial" as const, coords: { x1: w / 2, y1: h / 2, r1: 0, x2: w / 2, y2: h / 2, r2: r }, colorStops };
  }
  const c = gradientLineCoords(angle, w, h);
  return { type: "linear" as const, coords: { x1: c.x1, y1: c.y1, x2: c.x2, y2: c.y2 }, colorStops };
}
```

Then rewrite the existing text wrappers to delegate (preserving their exported signatures so callers in `KvKonvaCanvas.tsx:1766` and `KvFabricCanvas.tsx` are unchanged):

```ts
export function konvaTextFill(payload: StudioOverlay["payload"], w: number, h: number) {
  const color = payload.type === "text" ? payload.color : "#ffffff";
  const gradient = payload.type === "text" ? payload.gradient : undefined;
  return konvaFill(color, gradient, w, h);
}
```
Rename the OLD `fabricGradientSpec(payload, w, h)` to keep its call site working: if callers pass a payload, add a thin `fabricTextGradientSpec(payload, w, h)` that calls the new `fabricGradientSpec(payload.color, payload.gradient, w, h)`, and update the Fabric call sites (`KvFabricCanvas.tsx:1108,1122` region) to the renamed wrapper. Keep `hasTextGradient` as-is (it still gates text-specific code) or redefine it as `payload.type === "text" && hasGradient(payload.gradient)`.

- [ ] **Step 4: Run to verify it passes**

Run: `bun test src/components/studio/kv-generator/overlays/resolveTextFill.test.ts`
Expected: PASS (new + existing cases).

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/overlays/resolveTextFill.ts src/components/studio/kv-generator/overlays/resolveTextFill.test.ts
git commit -m "refactor(web): extract type-agnostic gradient fill core"
```

---

### Task 3: Shape geometry + fill mapping helpers

**Files:**
- Create: `src/components/studio/kv-generator/overlays/shapeGeometry.ts`
- Test: `src/components/studio/kv-generator/overlays/shapeGeometry.test.ts`

**Interfaces:**
- Consumes: `ShapePayload`, `ShapeKind` (Task 1); `konvaFill`, `fabricGradientSpec` (Task 2).
- Produces:
  - `regularPolygonPoints(sides: number, w: number, h: number): number[]` — flat `[x0,y0,x1,y1,…]`, centered in a `w×h` box, first vertex pointing up. `sides` clamped to ≥3.
  - `trianglePoints(w: number, h: number): number[]` — equilateral-ish triangle in the box (equiv. `regularPolygonPoints(3, w, h)`).
  - `MIN_SHAPE_NORM = 0.01` — minimum normalized width/height for a drawn shape (degenerate-drag threshold).
  - `strokePropsFor(payload: ShapePayload, w: number, h: number): { stroke?: string; strokeWidth?: number }` — resolves normalized stroke width to pixels (`payload.stroke.width * w`), omitted when no stroke.
  - `konvaShapeFill(payload: ShapePayload, w: number, h: number)` — delegates to `konvaFill(payload.color, payload.gradient, w, h)`.

- [ ] **Step 1: Write the failing test**

Create `shapeGeometry.test.ts`:

```ts
import { describe, it, expect } from "bun:test";
import { regularPolygonPoints, trianglePoints, strokePropsFor, konvaShapeFill, MIN_SHAPE_NORM } from "./shapeGeometry";
import type { ShapePayload } from "@/types/studio";

describe("regularPolygonPoints", () => {
  it("returns 2*sides coords", () => {
    expect(regularPolygonPoints(6, 100, 100)).toHaveLength(12);
  });
  it("clamps sides below 3 up to 3", () => {
    expect(regularPolygonPoints(2, 100, 100)).toHaveLength(6);
  });
  it("stays within the box bounds", () => {
    const pts = regularPolygonPoints(5, 100, 60);
    for (let i = 0; i < pts.length; i += 2) {
      expect(pts[i]).toBeGreaterThanOrEqual(0);
      expect(pts[i]).toBeLessThanOrEqual(100);
      expect(pts[i + 1]).toBeGreaterThanOrEqual(0);
      expect(pts[i + 1]).toBeLessThanOrEqual(60);
    }
  });
});

describe("trianglePoints", () => {
  it("returns 3 vertices", () => {
    expect(trianglePoints(80, 80)).toHaveLength(6);
  });
});

describe("strokePropsFor", () => {
  const base: ShapePayload = { type: "shape", kind: "rectangle", color: "#ff0000" };
  it("omits stroke when absent", () => {
    expect(strokePropsFor(base, 200, 100)).toEqual({});
  });
  it("scales normalized width to px", () => {
    expect(strokePropsFor({ ...base, stroke: { color: "#000000", width: 0.02 } }, 200, 100))
      .toEqual({ stroke: "#000000", strokeWidth: 4 });
  });
});

describe("konvaShapeFill", () => {
  it("solid fill from color", () => {
    const p: ShapePayload = { type: "shape", kind: "ellipse", color: "#abcdef" };
    expect(konvaShapeFill(p, 100, 100)).toEqual({ fill: "#abcdef" });
  });
});

describe("MIN_SHAPE_NORM", () => {
  it("is a small positive threshold", () => {
    expect(MIN_SHAPE_NORM).toBeGreaterThan(0);
    expect(MIN_SHAPE_NORM).toBeLessThan(0.1);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/components/studio/kv-generator/overlays/shapeGeometry.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement shapeGeometry.ts**

```ts
import type { ShapePayload } from "@/types/studio";
import { konvaFill } from "./resolveTextFill";

export const MIN_SHAPE_NORM = 0.01;

/** Flat [x0,y0,…] for a regular n-gon centered in a w×h box, first vertex up. */
export function regularPolygonPoints(sides: number, w: number, h: number): number[] {
  const n = Math.max(3, Math.round(sides));
  const cx = w / 2;
  const cy = h / 2;
  const rx = w / 2;
  const ry = h / 2;
  const pts: number[] = [];
  for (let i = 0; i < n; i++) {
    const a = -Math.PI / 2 + (i * 2 * Math.PI) / n; // start at top
    pts.push(cx + rx * Math.cos(a), cy + ry * Math.sin(a));
  }
  return pts;
}

export function trianglePoints(w: number, h: number): number[] {
  return regularPolygonPoints(3, w, h);
}

export function strokePropsFor(payload: ShapePayload, w: number, _h: number): { stroke?: string; strokeWidth?: number } {
  const s = payload.stroke;
  if (!s || !s.width || s.width <= 0) return {};
  return { stroke: s.color, strokeWidth: s.width * w };
}

export function konvaShapeFill(payload: ShapePayload, w: number, h: number) {
  return konvaFill(payload.color, payload.gradient, w, h);
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bun test src/components/studio/kv-generator/overlays/shapeGeometry.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/overlays/shapeGeometry.ts src/components/studio/kv-generator/overlays/shapeGeometry.test.ts
git commit -m "feat(web): shape geometry + fill mapping helpers"
```

---

### Task 4: CanvasTool + analytics support for shapes

**Files:**
- Modify: `src/components/studio/kv-generator/KvGeneratorLayout.tsx` (CanvasTool line ~148)
- Modify: the analytics tracker module that defines `trackKvOverlayAdded` / `trackKvOverlayTransformed` (find via `grep -rn "trackKvOverlayAdded" src/lib`)
- Test: the tracker's test file if one exists; otherwise none (type-gated).

**Interfaces:**
- Produces: `CanvasTool` includes `"shape"`; `trackKvOverlayAdded` / `trackKvOverlayTransformed` `overlay_type` unions include `"shape"`.

- [ ] **Step 1: Locate the tracker**

Run: `grep -rn "overlay_type" src/lib`
Identify the `trackKvOverlayAdded({ overlay_type })` and `trackKvOverlayTransformed({ overlay_type })` definitions and their `overlay_type` string-literal unions.

- [ ] **Step 2: Widen the unions**

In the tracker module, change both `overlay_type: "text" | "image"` unions to `"text" | "image" | "shape"`. Follow the `frndos-analytics-events` skill conventions (snake_case props, typed wrapper).

- [ ] **Step 3: Extend CanvasTool**

In `KvGeneratorLayout.tsx:148`:
```ts
type CanvasTool = "cursor" | "hand" | "frame" | "text" | "image" | "shape";
```

- [ ] **Step 4: Verify build (type-level gate)**

Run: `bun run build` (or `bunx tsc --noEmit` if faster) — expect the `overlay_type` cast at `KvTransformPanel.tsx:206` (`as "text" | "image"`) to now be flaggable; widen it to `as "text" | "image" | "shape"` in the same step.
Expected: no new type errors from these changes.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(web): add shape to CanvasTool + overlay analytics unions"
```

---

### Task 5: Toolbar shape picker

**Files:**
- Modify: the canvas toolbar component that receives `tool` / `onToolChange` (rendered from `KvGeneratorLayout.tsx:3197-3198`; identify via that JSX — likely `KvCanvasBottomNav.tsx` or `KvCanvasTopNav.tsx`)
- Create: `src/components/studio/kv-generator/ShapePicker.tsx`
- Test: `src/components/studio/kv-generator/ShapePicker.test.tsx`

**Interfaces:**
- Produces: `ShapePicker` — a popover listing the 5 shape kinds; `onPick(kind: ShapeKind)` sets the pending shape kind and switches the tool to `"shape"`.

- [ ] **Step 1: Write the failing test**

Create `ShapePicker.test.tsx`:

```tsx
import { describe, it, expect, vi } from "bun:test";
import { render, screen, fireEvent } from "@testing-library/react";
import { ShapePicker } from "./ShapePicker";

describe("ShapePicker", () => {
  it("renders the five kinds and reports a pick", () => {
    const onPick = vi.fn();
    render(<ShapePicker open onPick={onPick} onClose={() => {}} />);
    for (const label of ["Rectangle", "Ellipse", "Triangle", "Polygon", "Line"]) {
      expect(screen.getByRole("button", { name: label })).toBeInTheDocument();
    }
    fireEvent.click(screen.getByRole("button", { name: "Triangle" }));
    expect(onPick).toHaveBeenCalledWith("triangle");
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/components/studio/kv-generator/ShapePicker.test.tsx`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement ShapePicker.tsx**

Build a small popover (follow existing toolbar dropdown pattern in the identified toolbar; use frndos v2 components per the `frndos-components-v2` skill). Each entry is a `<button>` with an accessible name and a kind icon.

```tsx
"use client";
import type { ShapeKind } from "@/types/studio";

const KINDS: { kind: ShapeKind; label: string }[] = [
  { kind: "rectangle", label: "Rectangle" },
  { kind: "ellipse", label: "Ellipse" },
  { kind: "triangle", label: "Triangle" },
  { kind: "polygon", label: "Polygon" },
  { kind: "line", label: "Line" },
];

export function ShapePicker({ open, onPick, onClose }: { open: boolean; onPick: (k: ShapeKind) => void; onClose: () => void }) {
  if (!open) return null;
  return (
    <div role="menu" className="/* match existing toolbar popover classes */">
      {KINDS.map(({ kind, label }) => (
        <button key={kind} type="button" aria-label={label} onClick={() => { onPick(kind); onClose(); }}>
          {label}
        </button>
      ))}
    </div>
  );
}
```

- [ ] **Step 4: Wire the picker into the toolbar**

In the toolbar component, add a **Shape** button (next to the text/image tool buttons) that toggles `ShapePicker`. On `onPick(kind)`: store the chosen kind (lift a `pendingShapeKind` state into `KvGeneratorLayout` — pass a `onSelectShapeKind` prop down) and call `onToolChange("shape")`. Mirror how the text/image tool buttons set the tool.

- [ ] **Step 5: Run to verify it passes + build**

Run: `bun test src/components/studio/kv-generator/ShapePicker.test.tsx`
Expected: PASS.
Run: `bun run build`
Expected: no type errors.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(web): shape picker in canvas toolbar"
```

---

### Task 6: Shape placement handler + drag-to-draw state

**Files:**
- Modify: `src/components/studio/kv-generator/KvGeneratorLayout.tsx` (add `pendingShapeKind` state near line ~1439; add `handlePlaceShape` near `handlePlaceText` ~2686; pass `onPlaceShape` + `shapeKind` to canvases at ~3308 (Konva) and ~3662 (Fabric))
- Test: none directly (integration; covered by canvas render tests in Tasks 7–8 and manual verify)

**Interfaces:**
- Consumes: `addOverlay(draft): string` (~2662), `ShapeKind`, `MIN_SHAPE_NORM` (Task 3).
- Produces: `handlePlaceShape(kind: ShapeKind, rect: { x: number; y: number; width: number; height: number }, boardGenerationId?: string | null): string | null` — builds a shape `StudioOverlay` from a drawn (normalized) rect, selects it, resets tool to `"cursor"`, fires analytics. Returns the new id or `null` if the rect is degenerate.

- [ ] **Step 1: Confirm the interactive surface**

Inspect the craft canvas at runtime (or read the render tree at `KvGeneratorLayout.tsx:3300-3670`) to confirm Fabric receives pointer events for selection/drag. Place drag-to-draw on that surface (Task 8 assumes Fabric). Note the finding in the commit message.

- [ ] **Step 2: Add pendingShapeKind state**

Near `const [canvasTool, setCanvasTool] = useState<CanvasTool>("cursor")` (~1439):
```ts
const [pendingShapeKind, setPendingShapeKind] = useState<ShapeKind>("rectangle");
```
Pass `setPendingShapeKind` to the toolbar's `onSelectShapeKind` (Task 5), and pass `pendingShapeKind` to the interactive canvas so it knows which shape to draw.

- [ ] **Step 3: Add handlePlaceShape**

Mirror `handlePlaceText` (2686-2717). The rect comes pre-normalized from the drag-to-draw layer (Task 8):

```ts
const handlePlaceShape = useCallback(
  (
    kind: ShapeKind,
    rect: { x: number; y: number; width: number; height: number },
    boardGenerationId?: string | null,
  ): string | null => {
    if (rect.width < MIN_SHAPE_NORM || rect.height < MIN_SHAPE_NORM) return null; // degenerate
    const payload: ShapePayload = {
      type: "shape",
      kind,
      color: "#4B5563", // sensible default fill (brand-neutral gray)
      ...(kind === "polygon" ? { sides: 6 } : {}),
      ...(kind === "line" ? { stroke: { color: "#4B5563", width: 0.008 } } : {}),
    };
    const newId = addOverlay({
      type: "shape",
      x: rect.x,
      y: rect.y,
      width: rect.width,
      height: rect.height,
      rotation: 0,
      board_generation_id: boardGenerationId ?? null,
      payload,
    });
    trackKvOverlayAdded({ overlay_type: "shape" });
    setCanvasTool("cursor");
    return newId;
  },
  [addOverlay],
);
```

- [ ] **Step 4: Pass onPlaceShape to the canvases**

At the Fabric render (~3662) pass `onPlaceShape={handlePlaceShape}` and `shapeKind={pendingShapeKind}`. At the Konva render (~3308) pass `onPlaceShape={handlePlaceShape}` too (used by Konva's click-to-place fallback in Task 7).

- [ ] **Step 5: Build**

Run: `bun run build`
Expected: no type errors (canvas prop types are extended in Tasks 7–8; if build runs before those, temporarily type the new props as optional there first).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(web): shape placement handler + pending shape kind"
```

---

### Task 7: Konva shape render + export parity

**Files:**
- Modify: `src/components/studio/kv-generator/KvKonvaCanvas.tsx` (render ternary ~1747-1781; `handleStageClick` ~903-928; cursor gate ~896-901; props for `onPlaceShape`/`shapeKind`; `Transformer keepRatio` ~1799)
- Test: `src/components/studio/kv-generator/KvKonvaCanvas.overlays.test.tsx` (add a shape case; file exists)

**Interfaces:**
- Consumes: `regularPolygonPoints`, `trianglePoints`, `strokePropsFor`, `konvaShapeFill` (Task 3).

- [ ] **Step 1: Write the failing test**

In `KvKonvaCanvas.overlays.test.tsx`, add a case rendering a shape overlay and asserting a Konva shape node appears (mirror the existing text/image overlay test setup and its query approach). Example assertion shape:

```tsx
it("renders a rectangle shape overlay", () => {
  const shape: StudioOverlay = {
    id: "s1", studio_file_id: "f1", type: "shape",
    x: 0.1, y: 0.1, width: 0.3, height: 0.2, rotation: 0, z: 0,
    payload: { type: "shape", kind: "rectangle", color: "#ff0000" },
    created_at: "t", updated_at: "t",
  };
  // render KvKonvaCanvas with [shape] and assert the shape node is present
  // (follow the file's existing render harness + konva node query)
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/components/studio/kv-generator/KvKonvaCanvas.overlays.test.tsx`
Expected: FAIL — shape renders as neither Text nor Image (or type error on the new payload).

- [ ] **Step 3: Add the shape branch to the render ternary**

At the render switch (~1747), the current `overlay.type === "text" ? <Text/> : <OverlayKonvaImage/>` binary becomes a three-way. Extract a shape node using the geometry helpers and the de-normalized `pw`/`ph` (from ~1673-1676):

```tsx
import { Rect, Ellipse, Line } from "react-konva";
import { regularPolygonPoints, trianglePoints, strokePropsFor, konvaShapeFill } from "./overlays/shapeGeometry";

// inside the render switch, when overlay.type === "shape" && overlay.payload.type === "shape":
const sp = overlay.payload;
const fill = konvaShapeFill(sp, pw, ph);
const strokeProps = strokePropsFor(sp, pw, ph);
switch (sp.kind) {
  case "rectangle":
    return <Rect width={pw} height={ph} cornerRadius={(sp.corner_radius ?? 0) * Math.min(pw, ph)} {...fill} {...strokeProps} strokeScaleEnabled={false} />;
  case "ellipse":
    return <Ellipse x={pw / 2} y={ph / 2} radiusX={pw / 2} radiusY={ph / 2} {...fill} {...strokeProps} strokeScaleEnabled={false} />;
  case "triangle":
    return <Line points={trianglePoints(pw, ph)} closed {...fill} {...strokeProps} strokeScaleEnabled={false} />;
  case "polygon":
    return <Line points={regularPolygonPoints(sp.sides ?? 6, pw, ph)} closed {...fill} {...strokeProps} strokeScaleEnabled={false} />;
  case "line":
    return <Line points={[0, ph / 2, pw, ph / 2]} stroke={sp.stroke?.color ?? sp.color} strokeWidth={(sp.stroke?.width ?? 0.008) * pw} strokeScaleEnabled={false} />;
}
```
(Keep the existing text branch first; add the shape branch before the image fallback, guarded on `overlay.type === "shape"`.)

- [ ] **Step 4: Extend click-to-place + cursor gate**

At `handleStageClick` (~905) guard, add `shape`: `if (tool !== "text" && tool !== "image" && tool !== "shape") return;` and dispatch `else if (tool === "shape") onPlaceShape?.(shapeKind, { x: nx - dW/2, y: ny - dH/2, width: dW, height: dH })` using a default size (`dW=0.2, dH=0.15`). At the cursor gate (~896-901) treat `shape` like `frame` (`cursor-crosshair`). Add `onPlaceShape?` and `shapeKind?` to the component props.

- [ ] **Step 5: Transformer keepRatio**

At `Transformer` (~1799), set `keepRatio={aspectLocked || overlay.type === "text"}` — shapes are already excluded (free resize). No change needed unless shapes should lock; leave as-is.

- [ ] **Step 6: Run to verify it passes + build**

Run: `bun test src/components/studio/kv-generator/KvKonvaCanvas.overlays.test.tsx`
Expected: PASS.
Run: `bun run build`
Expected: no type errors.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(web): render shape overlays on Konva (+ export parity)"
```

---

### Task 8: Fabric shape render + drag-to-draw + transform writeback

**Files:**
- Modify: `src/components/studio/kv-generator/KvFabricCanvas.tsx` (type switch ~1079-1209; `overlaysSig` ~959; cursor gate ~1427-1446; marquee precedent ~376-400; `onModified` writeback ~566-657; props for `onPlaceShape`/`shapeKind`)
- Test: none new (Fabric is canvas-heavy / hard to unit test; rely on `KvFabricCanvas` existing tests + Task 11 manual verify). If `KvFabricCanvas.test.tsx` has a render harness, add a smoke case that a shape overlay does not throw.

**Interfaces:**
- Consumes: `regularPolygonPoints`, `trianglePoints`, `strokePropsFor` (Task 3); `fabricGradientSpec` (Task 2); `handlePlaceShape` via `onPlaceShape` prop; `shapeKind` prop.

- [ ] **Step 1: Add the shape build branch to the reconcile type switch**

In the new-object branch (~1079-1209), after the text and image branches, add `else if (overlay.type === "shape" && overlay.payload.type === "shape")`. Use the shared geometry math already computed (`w`, `h`, `left`, `top` from ~1064-1069) and build the fabric primitive at `{ left, top, angle: overlay.rotation, originX: "center", originY: "center" }`:

```ts
import { regularPolygonPoints, trianglePoints, strokePropsFor } from "./overlays/shapeGeometry";
import { fabricGradientSpec } from "./overlays/resolveTextFill";

const sp = overlay.payload; // ShapePayload
const strokeProps = strokePropsFor(sp, w, h); // { stroke?, strokeWidth? }
const common = { left, top, angle: overlay.rotation, originX: "center", originY: "center", strokeUniform: true, ...strokeProps } as const;

let obj: fabric.Object;
switch (sp.kind) {
  case "rectangle":
    obj = new fabric.Rect({ ...common, width: w, height: h, rx: (sp.corner_radius ?? 0) * Math.min(w, h), ry: (sp.corner_radius ?? 0) * Math.min(w, h) });
    break;
  case "ellipse":
    obj = new fabric.Ellipse({ ...common, rx: w / 2, ry: h / 2 });
    break;
  case "triangle":
    obj = new fabric.Polygon(pointPairs(trianglePoints(w, h)), { ...common });
    break;
  case "polygon":
    obj = new fabric.Polygon(pointPairs(regularPolygonPoints(sp.sides ?? 6, w, h)), { ...common });
    break;
  case "line":
    obj = new fabric.Line([left - w / 2, top, left + w / 2, top], { ...common, stroke: sp.stroke?.color ?? sp.color, strokeWidth: (sp.stroke?.width ?? 0.008) * w });
    break;
}
// fill: solid or gradient (skip for line)
if (sp.kind !== "line") {
  const spec = fabricGradientSpec(sp.color, sp.gradient, w, h);
  obj.set("fill", spec ? new fabric.Gradient({ ...spec, gradientUnits: "pixels" }) : sp.color);
}
```
Add a local helper `pointPairs(flat: number[]) => { x, y }[]` (converts the flat `[x,y,…]` from `shapeGeometry` to fabric's `{x,y}[]`). Set `data.elementId = overlay.id` like text/image so writeback + selection work.

- [ ] **Step 2: Extend overlaysSig**

`overlaysSig` (~959) currently hashes only `payload.asset_url` (image) and `payload.fontSize` (text). Add shape fields so edits re-render: include `payload.kind`, `payload.color`, `payload.gradient` (stringified), `payload.stroke` (stringified), `payload.corner_radius`, `payload.sides` when `overlay.type === "shape"`.

- [ ] **Step 3: Extend cursor gate**

At the tool cursor gate (~1427-1446), treat `shape` like `frame` (`"crosshair"`), and disable native selection (`canvas.selection = tool === "cursor" && …`) while the shape tool is active — mirror the `text`/`image`/`frame` handling.

- [ ] **Step 4: Add drag-to-draw marquee for the shape tool**

Reuse the frame-tool marquee precedent (~376-400: `draftRef`, `isDrawingRef`, `toolRectRef` pinned at mousedown). When `tool === "shape"`: on mousedown pin the start point + board host rect; on mousemove update a live preview rect; on mouseup compute the normalized rect against the board host (`{ x, y, width, height }` in [0,1], top-left) and call `cbRef.current.onPlaceShape?.(shapeKind, rect, boardId)`. Discard if below `MIN_SHAPE_NORM` (handlePlaceShape already guards). Cancel on `Escape`. Keep the preview visual consistent with the frame marquee.

- [ ] **Step 5: Transform writeback**

The existing `onModified` (~566-657) base branch already writes back normalized `x/y/width/height/rotation` for center-origin objects — shapes need no font fold (`textFontPatch` is text-only and skipped). Confirm shapes hit the base writeback path (no shape-specific patch required). For fabric primitives that scale via `scaleX/scaleY` (Ellipse/Polygon/Rect), `getScaledWidth()/getScaledHeight()` already yield the correct size, so the existing normalization at ~648-653 applies unchanged.

- [ ] **Step 6: Props**

Add `onPlaceShape?: (kind: ShapeKind, rect: { x: number; y: number; width: number; height: number }, boardGenerationId?: string | null) => void` and `shapeKind?: ShapeKind` to `KvFabricCanvas` props; thread `shapeKind` through the same ref pattern used for `tool` so the mouse handlers read the current value.

- [ ] **Step 7: Build + manual smoke**

Run: `bun run build`
Expected: no type errors.
Then start the dev server (Task 11) and drag-draw each kind; confirm it appears, is selectable, resizes, and rotates.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(web): render + drag-to-draw shapes on Fabric canvas"
```

---

### Task 9: Shape style editor (fill + stroke + kind controls)

**Files:**
- Create: `src/components/studio/kv-generator/overlays/ShapeStyleControls.tsx`
- Create (optional refactor): `src/components/studio/kv-generator/overlays/FillControls.tsx` (shared solid/gradient cluster extracted from `TextTypographyControls`)
- Modify: `src/components/studio/kv-generator/KvGeneratorLayout.tsx` (~3596 editor branch) and `src/components/studio/kv-generator/KvResizeCanvas.tsx` (~504 editor branch)
- Test: `src/components/studio/kv-generator/overlays/ShapeStyleControls.test.tsx`

**Interfaces:**
- Consumes: `ShapePayload`, `ShapeGradient`, `ShapeStroke`; `ColorField` (`{value,onChange,label}`).
- Produces: `ShapeStyleControls` — props `{ payload: ShapePayload; onPatch: (partial: Partial<ShapePayload>) => void }`.

- [ ] **Step 1: Write the failing test**

Create `ShapeStyleControls.test.tsx` (mirror `KvTransformPanel.test.tsx` style — render + query by role, assert `onPatch` with `objectContaining`):

```tsx
import { describe, it, expect, vi } from "bun:test";
import { render, screen, fireEvent } from "@testing-library/react";
import { ShapeStyleControls } from "./ShapeStyleControls";
import type { ShapePayload } from "@/types/studio";

const base: ShapePayload = { type: "shape", kind: "polygon", color: "#ff0000", sides: 6 };

describe("ShapeStyleControls", () => {
  it("toggling gradient patches a gradient onto the payload", () => {
    const onPatch = vi.fn();
    render(<ShapeStyleControls payload={base} onPatch={onPatch} />);
    fireEvent.click(screen.getByRole("button", { name: "Gradient" }));
    expect(onPatch).toHaveBeenCalledWith(expect.objectContaining({ gradient: expect.objectContaining({ from: expect.any(String), to: expect.any(String) }) }));
  });

  it("changing sides patches the payload", () => {
    const onPatch = vi.fn();
    render(<ShapeStyleControls payload={base} onPatch={onPatch} />);
    const sides = screen.getByRole("spinbutton", { name: "Sides" });
    fireEvent.change(sides, { target: { value: "8" } });
    fireEvent.blur(sides);
    expect(onPatch).toHaveBeenCalledWith(expect.objectContaining({ sides: 8 }));
  });

  it("enabling stroke adds a stroke object", () => {
    const onPatch = vi.fn();
    render(<ShapeStyleControls payload={base} onPatch={onPatch} />);
    fireEvent.click(screen.getByRole("checkbox", { name: "Stroke" }));
    expect(onPatch).toHaveBeenCalledWith(expect.objectContaining({ stroke: expect.objectContaining({ color: expect.any(String), width: expect.any(Number) }) }));
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/components/studio/kv-generator/overlays/ShapeStyleControls.test.tsx`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement ShapeStyleControls.tsx**

Mirror `TextTypographyControls.tsx` (read it for the exact Solid/Gradient + Linear/Radial + `ColorField` + Angle layout and reuse the same markup). Fill cluster: Solid/Gradient toggle; Gradient → Linear/Radial sub-toggle + `From`/`To` `ColorField`s + Angle input (linear only); Solid → one `ColorField` bound to `payload.color`. Stroke: a checkbox that, when enabled, patches `stroke: { color: "#000000", width: 0.01 }` and renders a `ColorField` + width input; when disabled, patches `stroke: undefined`. Kind-specific: for `polygon`, a `Sides` number input (`role="spinbutton"`, min 3 max 12); for `rectangle`, a `Corner radius` input (0–1). For `line`, hide fill; show only stroke. Every change calls `onPatch(partial)`. Fire `trackKvShapeStyleChanged` (add to the analytics tracker, or reuse `trackKvTextFillChanged` pattern) per the analytics skill.

- [ ] **Step 4: Wire into the parent editor branches**

In `KvGeneratorLayout.tsx` (~3596, where `sel.payload.type !== "text"` currently returns null for the text section), add a sibling branch: when `sel?.payload.type === "shape"`, render `<ShapeStyleControls payload={sel.payload} onPatch={(partial) => onUpdateOverlay(sel.id, { payload: { ...sel.payload, ...partial } })} />` above the shared `KvTransformPanel`. Do the same at `KvResizeCanvas.tsx` (~504). Use the existing `onUpdateOverlay` / doc-update path already wired for text payload edits.

- [ ] **Step 5: Run to verify it passes + build**

Run: `bun test src/components/studio/kv-generator/overlays/ShapeStyleControls.test.tsx`
Expected: PASS.
Run: `bun run build`
Expected: no type errors.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(web): shape style editor (fill, stroke, kind controls)"
```

---

### Task 10: Layers panel shape icon + label

**Files:**
- Modify: `src/components/studio/kv-generator/KvLayersPanel.tsx` (`LayerIcon` ~512-545; `labelForOverlay` ~547-555)
- Test: `src/components/studio/kv-generator/KvLayersPanel.test.tsx` (add a shape-row case)

**Interfaces:**
- Consumes: `ShapePayload`, `ShapeKind`.

- [ ] **Step 1: Write the failing test**

Add to `KvLayersPanel.test.tsx` a case with a shape overlay in `overlays` and assert the row shows a shape label (e.g. `"Rectangle"` or `"Shape"`). Follow the file's existing render harness (module-level `overlay` fixture pattern) and its mixed assertion style (`toBeInTheDocument` is available where jest-dom is loaded).

```tsx
it("labels a shape overlay by kind", () => {
  const shape: StudioOverlay = {
    id: "sh1", studio_file_id: "f1", type: "shape",
    x: 0.1, y: 0.1, width: 0.2, height: 0.2, rotation: 0, z: 1,
    payload: { type: "shape", kind: "rectangle", color: "#ff0000" },
    created_at: "t", updated_at: "t",
  };
  // render KvLayersPanel with overlays={[shape]} and assert "Rectangle" appears
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/components/studio/kv-generator/KvLayersPanel.test.tsx`
Expected: FAIL — shape falls through to the text default (`"Text overlay"` label / `TextT` icon).

- [ ] **Step 3: Add shape branches**

In `LayerIcon` (~512), before the text default, add: `if (overlay.type === "shape") return <ShapeIcon kind={overlay.payload.type === "shape" ? overlay.payload.kind : "rectangle"} size={16} />;` — pick a lucide/existing icon per kind (Square/Circle/Triangle/Pentagon/Minus), or one generic `Shapes` icon if per-kind icons are overkill. In `labelForOverlay` (~547), add: `if (o.payload.type === "shape") return o.payload.kind.charAt(0).toUpperCase() + o.payload.kind.slice(1);` (→ "Rectangle", "Ellipse", …).

- [ ] **Step 4: Run to verify it passes + build**

Run: `bun test src/components/studio/kv-generator/KvLayersPanel.test.tsx`
Expected: PASS.
Run: `bun run build`
Expected: no type errors.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(web): shape icon + label in layers panel"
```

---

### Task 11: Full build, test sweep, and manual verify

**Files:** none (verification)

- [ ] **Step 1: Full test sweep**

Run: `bun test src/components/studio/kv-generator src/types`
Expected: PASS (all new + existing KV tests).

- [ ] **Step 2: Build gate**

Run: `bun run build`
Expected: succeeds, no type errors.

- [ ] **Step 3: Manual verify via preview**

Start the dev server (`bun dev`) and open the KV generator on a file with a generated board. For EACH kind (rectangle, ellipse, triangle, polygon, line):
- Pick it from the shape toolbar, drag-draw on the canvas → shape appears at the drawn size, selected.
- Resize + rotate via handles; confirm it persists (reload → still there).
- In the style panel: switch solid → linear → radial; change from/to colors + angle; toggle stroke; for polygon change sides; for rectangle change corner radius. Confirm live update.
- Confirm the shape shows in the Layers panel with the right label, and reorder/select/delete work.
- Export/download the KV (Konva flatten) → shape is baked into the PNG at native resolution (parity check).

- [ ] **Step 4: Confirm API round-trip**

With the API worktree running, confirm a placed shape survives a PATCH → reload (persisted in `studio_files.overlays`) and that saving + applying a Brand Overlay Preset containing a shape works.

- [ ] **Step 5: Final commit (if any verify fixes)**

```bash
git add -A && git commit -m "fix(web): shape overlay verify fixes" || echo "nothing to commit"
```

---

## Self-Review

**Spec coverage:**
- Shape set (rect/ellipse/triangle/polygon/line) — Tasks 3, 7, 8.
- Solid + linear/radial gradient fill (reused text model) — Tasks 2, 9; render Tasks 7, 8.
- Optional stroke — Tasks 3, 7, 8, 9.
- Drag-to-draw placement — Tasks 6, 8 (Fabric), with Konva click-to-place fallback (Task 7).
- Editable vector (move/resize/rotate/restyle) — geometry reuses `KvTransformPanel` (unchanged); style via Task 9.
- Third overlay type on existing envelope + persistence — Task 1 types; API plan handles validation.
- Presets include shapes — API plan (preset request) + types (Task 1 `BrandOverlayPreset`).
- Export parity (Konva flatten) — Task 7 (automatic once shape nodes render).
- Layers panel — Task 10.
- Analytics — Tasks 4, 6, 9.
- Testing (bun test, jest-dom) — Tasks 1, 2, 3, 5, 7, 9, 10.

**Placeholder scan:** New pure modules (types, `resolveTextFill` core, `shapeGeometry`, `ShapePicker`, `ShapeStyleControls`) and all test code are complete. Edits into the three large canvas/layout files (`KvGeneratorLayout` 153KB, `KvFabricCanvas` 110KB, `KvKonvaCanvas` 82KB) are specified as exact-location + representative-code edits with explicit interface contracts — the executing agent reads the surrounding code (per the maps in the spec's linked investigation) rather than blind-pasting into files this size. The one runtime unknown (which craft surface is interactive) is an explicit early verification step in Task 6, not a placeholder.

**Type consistency:** `ShapePayload` fields (`kind`, `color`, `gradient`, `stroke`, `corner_radius`, `sides`) and enums match the API plan's validation trait and the spec exactly. `handlePlaceShape` / `onPlaceShape` signatures are identical in Tasks 6, 7, 8. `konvaFill`/`fabricGradientSpec` new signatures (Task 2) match their consumers in `shapeGeometry` (Task 3) and the Fabric branch (Task 8). Polygon `sides` default 6 / range 3–12 and `corner_radius` 0–1 are consistent across Tasks 6, 8, 9 and the API plan.

**Cross-plan dependency:** The web PATCH will 422 until the API plan's Tasks 1–2 land (shape payload whitelisted). Land API Tasks 1–3 before web Task 11's round-trip verify.
