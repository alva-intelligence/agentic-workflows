# Canvas World Overlay — P2 (Resize strip chrome) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The always-on Resize strip chrome — the "Resizes" divider, each tile's header icon row, and the pending/generating status layer — stays glued to the tiles through pan and zoom, moved by the camera CSS variables built in P1.

**Architecture:** `KvFabricCanvas` publishes its camera store upward (`onCameraStoreChange`, like `onZoomApiChange`); `KvCanvas` keeps it and hands it to `KvResizeStripChrome`, which binds the `--cam-*` variables on its own root and positions its always-on elements from WORLD rects (strip layout + measured tile aspects) through pure style builders. Transient frame-tool chrome keeps its React screen rects.

**Tech Stack:** Next.js 16 / React 19 / TypeScript, Fabric v7, bun test.

**Spec:** `docs/superpowers/specs/2026-09-24-kv-canvas-world-overlay-design.md` (workspace repo). Builds on P1 (`docs/superpowers/plans/2026-09-24-canvas-world-overlay-p1.md`): `src/lib/canvas/{cameraStore,worldOverlay,cameraCssVars}.ts`, ADR `web/docs/adr/0005-canvas-layering.md`.

## Global Constraints

- Work in `web/` on `feature/daffa/vc-kv-craft-resize-strip`. Commit per task. **Do not push** unless Daffa asks. Never `git stash`.
- Gates after every task: tsc total **≤ 933** (`bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -c "error TS"`); `bunx eslint --fix <touched files>` adds no warning; `bun test <explicit files>`. `node ./node_modules/next/dist/bin/next build` exit 0 at the end of Task 4.
- Pure tests only; no RTL/component tests for the canvas.
- Visual rules preserved exactly (current code, `KvResizeStripChrome.tsx`): divider row at the strip's world `dividerY` minus **8px**, spanning world `dividerX … dividerX + dividerWidth`, label text `12px`/`16px` × chrome scale; tile header row spans the tile's width, **24px × chrome scale** above the tile, icons packed right, inner row `scale(chromeScale)` from the top right; status layer covers the full tile rect; buttons hidden below **120px** of projected tile width.
- New always-on chrome must not read React camera state for its POSITION (ADR 0005). React zoom may still drive show/hide thresholds and a child's internal pixel sizing.
- **Ruling (deviation from the spec's P2 row):** the tile frame-box layer, the "Find objects / Edit this area" prompt and the tile box prompt popover stay on React screen rects. They are transient frame-tool chrome whose internals need pixel sizes (`KvFrameBoxLayer`'s `displayWidth/Height`), the same class as `ObjectSelectChrome`, which the spec puts out of scope.

## Review Focus

- **Tile aspect:** the chrome must use the canvas's MEASURED tile aspect (`boardMetrics[id].aspect`), falling back to the surface's `fallbackAspect` — the same aspect the canvas draws with — or the header row drifts off a tile whose image differs from its export dims. (Task 1 test: `tileWorldRect` uses the given aspect; Task 3 passes `aspectOf`.)
- **Store appears after first render / strip fills later:** `KvCanvas` receives the store in an effect, and the strip can be empty at first. The chrome's ROOT must always be mounted so the binding (once per element + store) reaches it; children render only when a store and a non-empty strip exist. (Task 3 Steps 1–2.)
- **Canvas remount / doc switch:** a new store must replace the old one and the chrome rebind; the Fabric side publishes `null` on unmount. (Task 2 effect cleanup.)
- **Zoom threshold crossing:** buttons appear/disappear at 120px projected width using React zoom — may lag one frame at the threshold only; positions never lag. (Manual.)
- **Empty strip:** no surfaces or `dividerY === null` → render nothing. (Task 1 test.)

---

### Task 1: Pure strip-chrome style builders + shared CSS evaluator

**Files:**
- Create: `web/src/lib/canvas/evalCameraCss.ts` (test helper, pure)
- Modify: `web/src/lib/canvas/worldOverlay.test.ts` (use the shared evaluator)
- Create: `web/src/components/studio/kv-generator/stripChromeStyles.ts`
- Create: `web/src/components/studio/kv-generator/stripChromeStyles.test.ts`

**Interfaces:**
- Consumes (P1): `lenCss`, `worldTranslate`, `cameraCssVars`, `CAMERA_CSS_VAR` from `@/lib/canvas/worldOverlay`.
- Produces:
  - `evalCssLength(expr: string, vars: Record<string, string>): number`; `evalTranslate(transform: string, vars: Record<string, string>): { x: number; y: number }` (reads the FIRST `translate(a, b)`).
  - `type WorldRect = { x: number; y: number; width: number; height: number }`
  - `tileWorldRect(center: { x: number; y: number }, width: number, aspect: number): WorldRect`
  - `stripDividerStyle(strip: Pick<ResizeStripLayout, "dividerX" | "dividerY" | "dividerWidth">): React.CSSProperties | null`
  - `STRIP_DIVIDER_TEXT_STYLE: React.CSSProperties`
  - `tileHeaderRowStyle(wr: WorldRect): React.CSSProperties`
  - `TILE_HEADER_INNER_STYLE: React.CSSProperties`
  - `tileBoxStyle(wr: WorldRect): React.CSSProperties`

- [ ] **Step 1: Shared evaluator** — `web/src/lib/canvas/evalCameraCss.ts`

```ts
/**
 * Evaluate the camera-variable CSS the world-overlay helpers emit, for tests
 * and debugging: `var(--cam-*)` is substituted, `calc(`/`max(`/`px` are made
 * JavaScript. Only the grammar `worldOverlay.ts` produces is supported.
 */
export function evalCssLength(
  expr: string,
  vars: Record<string, string>
): number {
  const js = expr
    .replace(/var\((--[\w-]+)\)/g, (_, n: string) => {
      const v = vars[n];
      if (v === undefined) throw new Error(`unset ${n}`);
      return `(${parseFloat(v)})`;
    })
    .replace(/calc\(/g, "(")
    .replace(/max\(/g, "Math.max(")
    .replace(/(-?\d*\.?\d+(?:e[-+]?\d+)?)px/g, "$1");
  return new Function(`return (${js});`)() as number;
}

/** The two arguments of the FIRST `translate(a, b)` in a transform list. */
export function evalTranslate(
  transform: string,
  vars: Record<string, string>
): { x: number; y: number } {
  const start = transform.indexOf("translate(");
  if (start < 0) throw new Error("no translate()");
  let depth = 0;
  let comma = -1;
  let end = -1;
  for (let i = start + "translate(".length; i < transform.length; i++) {
    const ch = transform[i];
    if (ch === "(") depth++;
    else if (ch === ")") {
      if (depth === 0) {
        end = i;
        break;
      }
      depth--;
    } else if (ch === "," && depth === 0 && comma < 0) comma = i;
  }
  if (comma < 0 || end < 0) throw new Error("malformed translate()");
  const a = transform.slice(start + "translate(".length, comma).trim();
  const b = transform.slice(comma + 1, end).trim();
  return { x: evalCssLength(a, vars), y: evalCssLength(b, vars) };
}
```

- [ ] **Step 2: Point the P1 test at it** — in `web/src/lib/canvas/worldOverlay.test.ts` delete the local `function evalCss(...) { ... }` and add `import { evalCssLength as evalCss } from "./evalCameraCss";`. Run: `cd web && bun test src/lib/canvas/worldOverlay.test.ts` → PASS (9).

- [ ] **Step 3: Write the failing test** — `web/src/components/studio/kv-generator/stripChromeStyles.test.ts`

```ts
import { describe, it, expect } from "bun:test";
import { cameraCssVars, lenCss } from "@/lib/canvas/worldOverlay";
import { evalCssLength, evalTranslate } from "@/lib/canvas/evalCameraCss";
import { chromeScale } from "./chromeScale";
import { worldRectToScreen } from "./gestureMath";
import {
  stripDividerStyle,
  tileBoxStyle,
  tileHeaderRowStyle,
  tileWorldRect,
} from "./stripChromeStyles";

const cams = [
  { scale: 1, x: 0, y: 0 },
  { scale: 0.38, x: -412.5, y: 96 },
  { scale: 2.2, x: 900, y: -640 },
];
const screenOf = (
  r: { x: number; y: number; width: number; height: number },
  c: { scale: number; x: number; y: number }
) => worldRectToScreen(r, { scale: c.scale, pos: { x: c.x, y: c.y } });

describe("tileWorldRect", () => {
  it("centres a W-wide tile of the given aspect on its centre", () => {
    expect(tileWorldRect({ x: 256, y: 1000 }, 512, 0.5625)).toEqual({
      x: 0,
      y: 1000 - 512 / 0.5625 / 2,
      width: 512,
      height: 512 / 0.5625,
    });
  });
  it("falls back to square on a non-positive aspect", () => {
    expect(tileWorldRect({ x: 0, y: 0 }, 100, 0).height).toBe(100);
  });
});

describe("stripDividerStyle", () => {
  it("is null for an empty strip", () => {
    expect(
      stripDividerStyle({ dividerX: 0, dividerY: null, dividerWidth: 10 })
    ).toBeNull();
  });
  for (const c of cams) {
    it(`matches the old screen math at scale ${c.scale}`, () => {
      const vars = cameraCssVars(c, { chromeScale });
      const s = stripDividerStyle({
        dividerX: -300,
        dividerY: 1400,
        dividerWidth: 2048,
      })!;
      const at = evalTranslate(String(s.transform), vars);
      expect(at.x).toBeCloseTo(-300 * c.scale + c.x);
      expect(at.y).toBeCloseTo(1400 * c.scale + c.y - 8);
      expect(evalCssLength(String(s.width), vars)).toBeCloseTo(2048 * c.scale);
    });
  }
});

describe("tile chrome", () => {
  const wr = tileWorldRect({ x: 256, y: 2200 }, 512, 9 / 16);
  for (const c of cams) {
    it(`header row + box match the old screen math at scale ${c.scale}`, () => {
      const vars = cameraCssVars(c, { chromeScale });
      const rect = screenOf(wr, c);
      const cs = chromeScale(c.scale);
      const row = tileHeaderRowStyle(wr);
      const rowAt = evalTranslate(String(row.transform), vars);
      expect(rowAt.x).toBeCloseTo(rect.x);
      expect(rowAt.y).toBeCloseTo(rect.y - 24 * cs);
      expect(evalCssLength(String(row.width), vars)).toBeCloseTo(rect.width);
      const box = tileBoxStyle(wr);
      const boxAt = evalTranslate(String(box.transform), vars);
      expect(boxAt.x).toBeCloseTo(rect.x);
      expect(boxAt.y).toBeCloseTo(rect.y);
      expect(evalCssLength(String(box.width), vars)).toBeCloseTo(rect.width);
      expect(evalCssLength(String(box.height), vars)).toBeCloseTo(rect.height);
    });
  }
  it("header text follows the chrome clamp", () => {
    expect(lenCss({ chrome: 12 })).toBe("calc(12px * var(--cam-cs))");
  });
});
```

- [ ] **Step 4: Run it to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/stripChromeStyles.test.ts`
Expected: FAIL — `Cannot find module './stripChromeStyles'`.

- [ ] **Step 5: Implement** — `web/src/components/studio/kv-generator/stripChromeStyles.ts`

```ts
import type React from "react";
import {
  CAMERA_CSS_VAR,
  lenCss,
  worldTranslate,
} from "@/lib/canvas/worldOverlay";
import type { ResizeStripLayout } from "./resizeStrip";

/**
 * World-overlay styles for the Resize strip's always-on chrome (docs/adr/0005).
 * Every element is anchored at `left: 0; top: 0` and moved by a translate that
 * reads the camera CSS variables on the chrome's root — so it moves in the
 * same event as the canvas. The numbers are the strip's own layout rules
 * (see KvResizeStripChrome), only expressed in world units.
 */
export type WorldRect = { x: number; y: number; width: number; height: number };

const AT_ORIGIN = { left: 0, top: 0 } as const;

/** A tile's world rect: `width` wide, centred on `center`, at `aspect`. */
export function tileWorldRect(
  center: { x: number; y: number },
  width: number,
  aspect: number
): WorldRect {
  const height = width / (aspect > 0 ? aspect : 1);
  return {
    x: center.x - width / 2,
    y: center.y - height / 2,
    width,
    height,
  };
}

/** The "Resizes" rule: 8px above the strip's world `dividerY`, spanning the
 *  Craft boards' bbox. Null for an empty strip. */
export function stripDividerStyle(
  strip: Pick<ResizeStripLayout, "dividerX" | "dividerY" | "dividerWidth">
): React.CSSProperties | null {
  if (strip.dividerY === null) return null;
  return {
    ...AT_ORIGIN,
    transform: worldTranslate(
      { world: strip.dividerX },
      { world: strip.dividerY, px: -8 }
    ),
    width: lenCss({ world: strip.dividerWidth }),
  };
}

export const STRIP_DIVIDER_TEXT_STYLE: React.CSSProperties = {
  fontSize: lenCss({ chrome: 12 }),
  lineHeight: lenCss({ chrome: 16 }),
};

/** The icon row above a tile: its full width, 24px × chrome scale above it. */
export function tileHeaderRowStyle(wr: WorldRect): React.CSSProperties {
  return {
    ...AT_ORIGIN,
    transform: worldTranslate({ world: wr.x }, { world: wr.y, chrome: -24 }),
    width: lenCss({ world: wr.width }),
  };
}

/** The icons themselves shrink with the chrome clamp, from the top right. */
export const TILE_HEADER_INNER_STYLE: React.CSSProperties = {
  transform: `scale(var(${CAMERA_CSS_VAR.chrome}))`,
  transformOrigin: "top right",
};

/** A layer covering the whole tile (status). */
export function tileBoxStyle(wr: WorldRect): React.CSSProperties {
  return {
    ...AT_ORIGIN,
    transform: worldTranslate({ world: wr.x }, { world: wr.y }),
    width: lenCss({ world: wr.width }),
    height: lenCss({ world: wr.height }),
  };
}
```

- [ ] **Step 6: Run the tests**

Run: `cd web && bun test src/components/studio/kv-generator/stripChromeStyles.test.ts src/lib/canvas/worldOverlay.test.ts`
Expected: PASS.

- [ ] **Step 7: Gates + commit**

```bash
cd web
bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -c "error TS"   # ≤ 933
bunx eslint --fix src/lib/canvas/evalCameraCss.ts src/lib/canvas/worldOverlay.test.ts src/components/studio/kv-generator/stripChromeStyles.ts src/components/studio/kv-generator/stripChromeStyles.test.ts
git add src/lib/canvas/evalCameraCss.ts src/lib/canvas/worldOverlay.test.ts src/components/studio/kv-generator/stripChromeStyles.ts src/components/studio/kv-generator/stripChromeStyles.test.ts
git commit -m "feat(web): world-overlay styles for the Resize strip chrome + shared CSS evaluator (world overlay P2)"
```

---

### Task 2: Publish the camera store from the canvas to `KvCanvas`

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvFabricCanvas.tsx`
- Modify: `web/src/components/studio/kv-generator/KvCanvas.tsx`

**Interfaces:**
- Consumes (P1): `useCanvasCamera` returns `cameraStore`; `type CameraStore` from `@/lib/canvas/cameraStore`.
- Produces: `KvFabricCanvas` prop `onCameraStoreChange?: (store: CameraStore | null) => void`; `KvCanvas` local state `cameraStore: CameraStore | null` (consumed by Task 3).

- [ ] **Step 1: `KvFabricCanvas` prop + effect.** In the props type, next to `onZoomApiChange?: (api: KvZoomApi | null) => void;` add

```ts
  /** The camera store (src/lib/canvas/cameraStore.ts), for world-overlay
   *  chrome rendered OUTSIDE this component (the Resize strip). `null` on
   *  unmount. */
  onCameraStoreChange?: (store: CameraStore | null) => void;
```

destructure `onCameraStoreChange,` next to `onZoomApiChange,`, import `import type { CameraStore } from "@/lib/canvas/cameraStore";`, and add after the `useCameraCssVars(worldLayerRef, …)` line:

```ts
  useEffect(() => {
    onCameraStoreChange?.(cameraStore);
    return () => onCameraStoreChange?.(null);
  }, [cameraStore, onCameraStoreChange]);
```

- [ ] **Step 2: `KvCanvas` threads it.** `KvCanvas.tsx` has two components: the outer `KvCanvas` and the inner `CanvasStageFrame` that mounts `KvFabricCanvas` through a `canvasProps` object (the same path `onZoomApiChange` takes: outer destructure ~line 503, pass-through ~1733, inner prop type ~2035, inner destructure ~1935, `canvasProps` ~2313).

(a) Outer `KvCanvas`, next to the `stripRects` / `stripZoom` state (~line 746):

```ts
  // The canvas's camera store — the strip chrome binds its world-overlay
  // CSS variables to it (docs/adr/0005).
  const [cameraStore, setCameraStore] = useState<CameraStore | null>(null);
```

(b) Pass it down where `onZoomApiChange={onZoomApiChange}` is passed to `<CanvasStageFrame …>`: add `onCameraStoreChange={setCameraStore}`.

(c) `CanvasStageFrame` props type: next to `onZoomApiChange?: (api: KvZoomApi | null) => void;` add `onCameraStoreChange?: (store: CameraStore | null) => void;`; destructure it next to `onZoomApiChange,`; add `onCameraStoreChange,` to `canvasProps` next to `onZoomApiChange,`.

(d) `import type { CameraStore } from "@/lib/canvas/cameraStore";` at the top of `KvCanvas.tsx`.

- [ ] **Step 3: Gates + commit**

```bash
cd web
bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -c "error TS"   # ≤ 933
bunx eslint --fix src/components/studio/kv-generator/KvFabricCanvas.tsx src/components/studio/kv-generator/KvCanvas.tsx
git add src/components/studio/kv-generator/KvFabricCanvas.tsx src/components/studio/kv-generator/KvCanvas.tsx
git commit -m "feat(web): KvFabricCanvas publishes its camera store to KvCanvas (world overlay P2)"
```

Expected: tsc unchanged; eslint no new warnings (KvCanvas keeps its 2 pre-existing, KvFabricCanvas its 1). `cameraStore` is unused until Task 3 — if eslint flags the state as unused, keep it (Task 3 consumes it) by committing Tasks 2 and 3 together instead, and record that in the ledger.

---

### Task 3: `KvResizeStripChrome` in world coordinates

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvResizeStripChrome.tsx`
- Modify: `web/src/components/studio/kv-generator/KvCanvas.tsx` (pass `cameraStore`, `aspectOf`)

**Interfaces:**
- Consumes: Task 1 builders; Task 2 `cameraStore`; P1 `useCameraCssVars`; KV `chromeScale`, `BOARD_WORLD_WIDTH` (`./kvSurface`).
- Produces: `KvResizeStripChrome` props gain `cameraStore: CameraStore | null` and `aspectOf: (surfaceId: string) => number | undefined`; `boardRects` stays (transient frame chrome only).

- [ ] **Step 1: Props, binding, early return.** In `KvResizeStripChrome.tsx`:

```ts
import { useRef } from "react";
import type { CameraStore } from "@/lib/canvas/cameraStore";
import { useCameraCssVars } from "@/lib/canvas/cameraCssVars";
import {
  STRIP_DIVIDER_TEXT_STYLE,
  TILE_HEADER_INNER_STYLE,
  stripDividerStyle,
  tileBoxStyle,
  tileHeaderRowStyle,
  tileWorldRect,
} from "./stripChromeStyles";
```

Add to the props type:

```ts
  /** The canvas camera store — the chrome binds its CSS variables to it
   *  (world overlay, docs/adr/0005). Null until the canvas publishes it. */
  cameraStore: CameraStore | null;
  /** MEASURED tile aspect (the one the canvas draws with), or undefined to
   *  fall back to the export's own aspect. */
  aspectOf: (surfaceId: string) => number | undefined;
```

destructure `cameraStore, aspectOf,`. Replace the block from `const first = strip.surfaces[0];` through `const dividerWidth = strip.dividerWidth * zoomScale;` with:

```ts
  const rootRef = useRef<HTMLDivElement | null>(null);
  useCameraCssVars(rootRef, cameraStore, { chromeScale });
  const divider = stripDividerStyle(strip);
  // No store yet → no camera variables → nothing could be placed right.
  // The ROOT still renders (see Step 2): the binding runs once per
  // (element, store) pair, so an element that only mounts later — strip
  // empty at first, filled after — would never receive the variables.
  const ready = !!cameraStore && !!divider && strip.surfaces.length > 0;
```

There is no early `return null` any more.

- [ ] **Step 2: Root + divider.** The root `div` becomes `<div ref={rootRef} className="pointer-events-none absolute inset-0 z-20 font-geist">` and is ALWAYS rendered; wrap everything inside it in `{ready && divider && (<> … </>)}` (the divider and the `strip.surfaces.map(…)`). The divider:

```tsx
      <div className="absolute flex items-center gap-3" style={divider}>
        <div className="h-px flex-1 bg-white/15" />
        <span
          className="text-textXsMedium text-white/50"
          style={STRIP_DIVIDER_TEXT_STYLE}
        >
          Resizes
        </span>
        <div className="h-px flex-1 bg-white/15" />
      </div>
```

- [ ] **Step 3: Per-tile world rect.** In `strip.surfaces.map((s) => {`, replace

```ts
        const rect = boardRects[s.id];
        const entry = strip.byExportId[s.id];
        if (!rect || !entry) return null;
        const row = entry.export;
        const showButtons = rect.width >= minChromeWidthPx;
```

with

```ts
        const entry = strip.byExportId[s.id];
        if (!entry) return null;
        const row = entry.export;
        const wr = tileWorldRect(
          s.center,
          strip.columnWidth,
          aspectOf(s.id) ?? s.fallbackAspect
        );
        // Show/hide by projected width uses React zoom (a threshold, not a
        // position — it may flip a frame late, never drift).
        const projectedWidth = wr.width * zoomScale;
        const showButtons = projectedWidth >= minChromeWidthPx;
        // Transient frame-tool chrome still uses the canvas's screen rect.
        const rect = boardRects[s.id];
```

- [ ] **Step 4: Header row.** The outer header `div` style becomes `style={tileHeaderRowStyle(wr)}` (keep `className="pointer-events-none absolute flex justify-end"`); the inner row `style` becomes `style={TILE_HEADER_INNER_STYLE}`.

- [ ] **Step 5: Transient frame chrome keeps screen rects.** Guard the three transient blocks on `rect`: change `{frame && row.status === "done" && (() => {` to `{frame && rect && row.status === "done" && (() => {`; change `{frame?.detectPrompt?.exportId === row.id && (` to `{rect && frame?.detectPrompt?.exportId === row.id && (`; change `{frame?.promptBox?.exportId === row.id &&` to `{rect && frame?.promptBox?.exportId === row.id &&`. Their bodies are unchanged.

- [ ] **Step 6: Status layer.** Its wrapper `style` becomes `style={tileBoxStyle(wr)}` and its sizing props `displayWidth={projectedWidth}` `displayHeight={wr.height * zoomScale}`.

- [ ] **Step 7: Docblock.** Replace the paragraph starting "Positioned from the canvas's published screen rects" with: "Always-on chrome (divider, header icons, status layer) is positioned in WORLD coordinates and moved by the camera CSS variables bound on this component's root (docs/adr/0005), so it moves with the canvas. The transient frame-tool chrome (boxes, detect prompt, box prompt) still uses the canvas's published screen rects (`boardRects`)."

- [ ] **Step 8: Wire in `KvCanvas`.** At `<KvResizeStripChrome` (~line 1378) add

```tsx
      cameraStore={cameraStore}
      aspectOf={(id) => boardMetrics[id]?.aspect}
```

(`boardMetrics` is the existing measured-metrics state in `KvCanvas`.)

- [ ] **Step 9: Verify no always-on element reads screen rects**

Run: `cd web && grep -n "rect\.left\|rect\.top\|rect\.width\|rect\.height\|zoomScale" src/components/studio/kv-generator/KvResizeStripChrome.tsx`
Expected: only inside the three transient blocks (`KvFrameBoxLayer`, detect prompt, `BoxPromptPopover`) and the `projectedWidth` / status `displayHeight` lines.

- [ ] **Step 10: Gates + commit**

```bash
cd web
bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -c "error TS"   # ≤ 933
bunx eslint --fix src/components/studio/kv-generator/KvResizeStripChrome.tsx src/components/studio/kv-generator/KvCanvas.tsx
bun test src/components/studio/kv-generator/stripChromeStyles.test.ts src/lib/canvas/worldOverlay.test.ts src/lib/canvas/cameraCssVars.test.ts
git add src/components/studio/kv-generator/KvResizeStripChrome.tsx src/components/studio/kv-generator/KvCanvas.tsx
git commit -m "feat(web): Resize strip divider, tile header icons and status ride the camera variables (world overlay P2)"
```

---

### Task 4: Build + documents

**Files:**
- Modify: `web/docs/tracks/kv-craft-resize-strip.track.md`

- [ ] **Step 1: Build**

Run: `cd web && node ./node_modules/next/dist/bin/next build`
Expected: exit 0.

- [ ] **Step 2: Track entry** — append:

```markdown
### 2026-09-24 — daffa (with Claude) — world overlay P2 (Resize strip chrome)
- Plan `docs/superpowers/plans/2026-09-24-canvas-world-overlay-p2.md` (workspace repo).
- KvFabricCanvas publishes its camera store (`onCameraStoreChange`); KvResizeStripChrome binds the `--cam-*`
  variables on its root and positions the divider, tile header icons and status layer from WORLD rects
  (`stripChromeStyles.ts`, measured tile aspect) — they move with the canvas.
- Ruling: tile frame boxes, "Find objects / Edit this area" and the tile box prompt stay on screen rects
  (transient frame-tool chrome, pixel-sized internals).
- Manual (Daffa): pan + pinch fast over the strip — divider and header icons stay welded; download dropdown,
  history/reset, Retry/Cancel on a generating tile all work; below ~120px tile width the icons hide.
  Still trailing until P3: comment pins.
```

- [ ] **Step 3: Commit**

```bash
cd web
git add docs/tracks/kv-craft-resize-strip.track.md
git commit -m "docs(web): world overlay P2 track entry"
```

---

## Self-review against the spec

- Spec P2 row: divider → Tasks 1+3; tile header icon row → Tasks 1+3; tile status layer → Tasks 1+3; tile frame-box layer → **ruled out** (Global Constraints ruling) with the reason. Spec §Approach 4 (camera store across boundaries, `onCameraStoreChange`) → Task 2. World rects instead of screen rects for the always-on chrome → Task 3 (strip layout + measured aspect; `boardRects` kept only for transient chrome, removed in P3 when no consumer remains).
- P1 interfaces used as produced: `useCameraCssVars(ref, store, { chromeScale })`, `lenCss`, `worldTranslate`, `CAMERA_CSS_VAR.chrome`.
- Types: `WorldRect` defined in `stripChromeStyles.ts` (Task 1) and used by Task 3; `CameraStore` from `@/lib/canvas/cameraStore` in Tasks 2–3; `aspectOf` returns `number | undefined` and Task 3 falls back to `s.fallbackAspect` (a `KvSurface` field).
