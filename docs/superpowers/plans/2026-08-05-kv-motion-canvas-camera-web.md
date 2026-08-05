# KV Motion — Pannable, Zoomable Preview Canvas — Implementation Plan (web)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Motion timeline editor's preview a Figma-style camera — pointer-anchored zoom, trackpad pinch, pan, and fit — matching the Craft canvas's gestures.

**Architecture:** The camera is a CSS `transform` on the stage's container, never a mutation of the Konva stage's own scale/position. All camera math lives in one pure module with full test coverage; the editor wires gestures to it. The Konva coordinate space is untouched, so overlay drag math and the export path need no changes at all.

**Tech Stack:** Next.js 16 / React 19 / TypeScript, Konva 10.2.3, `bun test` + `@testing-library/react` in jsdom.

**Spec:** `docs/superpowers/specs/2026-08-05-kv-motion-canvas-camera-design.md`

## Global Constraints

- **Web only.** Do not touch `api/`. Camera state is ephemeral view state — never persisted, never in the snapshot, never sent to the api.
- **Do not modify `KvKonvaCanvas.tsx`.** Craft's camera stays where it is; this feature gets its own module mirroring its semantics.
- **Do not change overlay drag commit math** (`node.x() / targetWidth - ov.width / 2`). The entire design exists to keep it valid.
- **Do not change `exportMotion.ts`.** The exported MP4 must be unaffected by camera state.
- Scale clamp is **0.1 to 5**, matching Craft. Zoom step `SCALE_BY = 1.05`.
- Test runner is `bun test`, never `bunx vitest`.
- **`screen` from @testing-library is broken under bun's jsdom preload** — always query via `within(document.body)`. Getting this wrong fails every component test in the repo.
- **jsdom has no canvas 2D context and no layout.** No test may render a Konva stage or rely on measured geometry.
- **`bun run build` does NOT type-check** — `next.config.js` sets `typescript: { ignoreBuildErrors: true }`. For type signal use `bunx tsc --noEmit` and grep for the files you touched; the repo carries a ~558-error pre-existing baseline, and every file in this plan must contribute zero.
- **Never `git stash`.** To compare a lint baseline, `git show HEAD:<path> > <path>.baseline.tsx` inside the repo, lint it, delete it.
- Commit after every task. Conventional commits, scope `web`.

## File Structure

| File | Responsibility |
|---|---|
| `src/lib/motion/camera.ts` **(new)** | Pure camera math: clamp, pointer-anchored zoom, pan, fit. No React, no DOM. |
| `src/lib/motion/camera.test.ts` **(new)** | Full coverage of the above. |
| `src/lib/motion/konvaPointerContract.test.ts` **(new)** | Pins Konva's CSS-scale pointer compensation, which the whole design rests on. |
| `src/components/studio/kv-generator/motion/useCanvasCamera.ts` **(new)** | React hook: camera state + wheel/touch/drag handlers + fit. Returns state and props to spread. |
| `src/components/studio/kv-generator/motion/useCanvasCamera.test.tsx` **(new)** | Behavioural tests for gesture → camera mapping. |
| `src/components/studio/kv-generator/motion/KvMotionCanvasZoomPill.tsx` **(new)** | Floating −/%/+/fit control for the canvas. |
| `src/components/studio/kv-generator/motion/KvMotionCanvasZoomPill.test.tsx` **(new)** | Renders values, fires callbacks. |
| `src/components/studio/kv-generator/motion/KvMotionEditor.tsx` | Stage built at board size; viewport + transform wrapper; wire the hook and the pill. |

---

### Task 1: Pure camera math

**Files:**
- Create: `src/lib/motion/camera.ts`
- Test: `src/lib/motion/camera.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `type Camera = { scale: number; x: number; y: number }`
  - `MIN_SCALE = 0.1`, `MAX_SCALE = 5`, `SCALE_BY = 1.05`
  - `clampScale(s: number): number`
  - `zoomAt(cam: Camera, pointer: {x,y}, direction: 1 | -1): Camera`
  - `zoomTo(cam: Camera, pointer: {x,y}, nextScale: number): Camera`
  - `panBy(cam: Camera, dx: number, dy: number): Camera`
  - `fitCamera(pane: {width,height}, board: {width,height}): Camera`

- [ ] **Step 1: Write the failing test**

```ts
// src/lib/motion/camera.test.ts
import { describe, it, expect } from "bun:test";

import {
  clampScale,
  fitCamera,
  MAX_SCALE,
  MIN_SCALE,
  panBy,
  zoomAt,
  zoomTo,
  type Camera,
} from "./camera";

const CAM: Camera = { scale: 1, x: 0, y: 0 };

/** Where a board-space point currently lands in viewport space. */
function project(cam: Camera, px: number, py: number) {
  return { x: px * cam.scale + cam.x, y: py * cam.scale + cam.y };
}

describe("clampScale", () => {
  it("clamps to the Craft-matching bounds", () => {
    expect(clampScale(0.05)).toBe(MIN_SCALE);
    expect(clampScale(99)).toBe(MAX_SCALE);
    expect(clampScale(1.5)).toBe(1.5);
  });
});

describe("zoomAt", () => {
  it("keeps the point under the pointer stationary when zooming in", () => {
    const pointer = { x: 300, y: 200 };
    // Board-space point currently under the pointer.
    const before = (pointer.x - CAM.x) / CAM.scale;
    const next = zoomAt(CAM, pointer, 1);
    expect(next.scale).toBeGreaterThan(CAM.scale);
    expect(project(next, before, 0).x).toBeCloseTo(pointer.x, 6);
  });

  it("keeps the point under the pointer stationary when zooming out", () => {
    const cam: Camera = { scale: 2, x: -120, y: -80 };
    const pointer = { x: 410, y: 260 };
    const bx = (pointer.x - cam.x) / cam.scale;
    const by = (pointer.y - cam.y) / cam.scale;
    const next = zoomAt(cam, pointer, -1);
    expect(next.scale).toBeLessThan(cam.scale);
    const p = project(next, bx, by);
    expect(p.x).toBeCloseTo(pointer.x, 6);
    expect(p.y).toBeCloseTo(pointer.y, 6);
  });

  it("does not move the camera once clamped at the maximum", () => {
    const cam: Camera = { scale: MAX_SCALE, x: 10, y: 20 };
    expect(zoomAt(cam, { x: 100, y: 100 }, 1)).toEqual(cam);
  });

  it("does not move the camera once clamped at the minimum", () => {
    const cam: Camera = { scale: MIN_SCALE, x: 10, y: 20 };
    expect(zoomAt(cam, { x: 100, y: 100 }, -1)).toEqual(cam);
  });
});

describe("zoomTo", () => {
  it("anchors an absolute scale change at the pointer", () => {
    const cam: Camera = { scale: 1, x: 0, y: 0 };
    const pointer = { x: 250, y: 250 };
    const next = zoomTo(cam, pointer, 2.5);
    expect(next.scale).toBe(2.5);
    expect(project(next, 250, 250).x).toBeCloseTo(250, 6);
  });

  it("clamps the requested scale", () => {
    expect(zoomTo(CAM, { x: 0, y: 0 }, 500).scale).toBe(MAX_SCALE);
    expect(zoomTo(CAM, { x: 0, y: 0 }, 0).scale).toBe(MIN_SCALE);
  });
});

describe("panBy", () => {
  it("translates without touching scale", () => {
    expect(panBy({ scale: 2, x: 10, y: 20 }, 5, -7)).toEqual({
      scale: 2,
      x: 15,
      y: 13,
    });
  });
});

describe("fitCamera", () => {
  it("fits a portrait board into a landscape pane and centres it", () => {
    const cam = fitCamera({ width: 800, height: 400 }, { width: 1080, height: 1920 });
    expect(cam.scale).toBeCloseTo(400 / 1920, 6);
    // Centred horizontally, flush vertically (height is the binding axis).
    expect(cam.x).toBeCloseTo((800 - 1080 * cam.scale) / 2, 6);
    expect(cam.y).toBeCloseTo(0, 6);
  });

  it("fits a landscape board into a portrait pane and centres it", () => {
    const cam = fitCamera({ width: 400, height: 800 }, { width: 1920, height: 1080 });
    expect(cam.scale).toBeCloseTo(400 / 1920, 6);
    expect(cam.y).toBeCloseTo((800 - 1080 * cam.scale) / 2, 6);
    expect(cam.x).toBeCloseTo(0, 6);
  });

  it("UPSCALES a small board to fill the pane", () => {
    // The old preview capped at 1x, leaving a small board marooned at 1:1.
    const cam = fitCamera({ width: 800, height: 800 }, { width: 200, height: 200 });
    expect(cam.scale).toBeCloseTo(4, 6);
  });

  it("respects the scale clamp when fitting something enormous", () => {
    const cam = fitCamera({ width: 10, height: 10 }, { width: 1920, height: 1920 });
    expect(cam.scale).toBe(MIN_SCALE);
  });

  it("returns a usable camera for a degenerate pane", () => {
    const cam = fitCamera({ width: 0, height: 0 }, { width: 1080, height: 1920 });
    expect(Number.isFinite(cam.scale)).toBe(true);
    expect(Number.isFinite(cam.x)).toBe(true);
    expect(Number.isFinite(cam.y)).toBe(true);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/lib/motion/camera.test.ts`
Expected: FAIL — `Cannot find module './camera'`

- [ ] **Step 3: Write minimal implementation**

```ts
// src/lib/motion/camera.ts

/** Viewport camera over a fixed-size board. Applied as a CSS transform:
 *  `translate(x, y) scale(scale)` with `transform-origin: 0 0`, so a
 *  board-space point p maps to viewport space as `p * scale + offset`.
 *
 *  Deliberately NOT applied to the Konva stage's own scale/position: overlay
 *  drags normalize against the stage's pixel size, and moving the stage would
 *  make every drag commit wrong coordinates. See the design spec §1. */
export type Camera = { scale: number; x: number; y: number };

/** Same bounds and step the Craft canvas uses (KvKonvaCanvas.handleWheel), so
 *  zooming feels identical across the two surfaces. */
export const MIN_SCALE = 0.1;
export const MAX_SCALE = 5;
export const SCALE_BY = 1.05;

export function clampScale(scale: number): number {
  if (!Number.isFinite(scale)) return 1;
  return Math.max(MIN_SCALE, Math.min(MAX_SCALE, scale));
}

/**
 * Zoom to an absolute scale, keeping whatever board-space point currently sits
 * under `pointer` pinned to that same viewport position.
 *
 *   boardPoint = (pointer - offset) / oldScale
 *   newOffset  = pointer - boardPoint * newScale
 */
export function zoomTo(
  cam: Camera,
  pointer: { x: number; y: number },
  nextScale: number
): Camera {
  const scale = clampScale(nextScale);
  if (scale === cam.scale) return cam;
  const bx = (pointer.x - cam.x) / cam.scale;
  const by = (pointer.y - cam.y) / cam.scale;
  return {
    scale,
    x: pointer.x - bx * scale,
    y: pointer.y - by * scale,
  };
}

/** One notch of pointer-anchored zoom. `direction` 1 = in, -1 = out. */
export function zoomAt(
  cam: Camera,
  pointer: { x: number; y: number },
  direction: 1 | -1
): Camera {
  return zoomTo(
    cam,
    pointer,
    direction > 0 ? cam.scale * SCALE_BY : cam.scale / SCALE_BY
  );
}

export function panBy(cam: Camera, dx: number, dy: number): Camera {
  return { scale: cam.scale, x: cam.x + dx, y: cam.y + dy };
}

/**
 * Centre the board in the pane at the largest scale that fits.
 *
 * Unlike the pre-camera preview — which capped at 1x and left a small board
 * marooned at 1:1 in the middle of a large pane — this upscales freely.
 */
export function fitCamera(
  pane: { width: number; height: number },
  board: { width: number; height: number }
): Camera {
  const bw = board.width > 0 ? board.width : 1;
  const bh = board.height > 0 ? board.height : 1;
  const pw = pane.width > 0 ? pane.width : 0;
  const ph = pane.height > 0 ? pane.height : 0;
  const scale = clampScale(Math.min(pw / bw, ph / bh));
  return {
    scale,
    x: (pw - bw * scale) / 2,
    y: (ph - bh * scale) / 2,
  };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/lib/motion/camera.test.ts`
Expected: PASS — 13 tests

- [ ] **Step 5: Commit**

```bash
git add web/src/lib/motion/camera.ts web/src/lib/motion/camera.test.ts
git commit -m "feat(web): add pure camera math for the Motion preview"
```

---

### Task 2: Pin Konva's CSS-scale pointer compensation

**Files:**
- Create: `src/lib/motion/konvaPointerContract.test.ts`

**Interfaces:**
- Consumes: `konva` (the installed package).
- Produces: no source module — this task is a regression pin only.

**Why this exists:** the entire design depends on Konva dividing pointer coordinates by the container's CSS scale. Verified in Konva 10.2.3 at `node_modules/konva/lib/Stage.js:649`. If a version bump changes that, overlay dragging breaks *only at non-1 zoom* — the quietest possible failure. This test makes it loud.

- [ ] **Step 1: Write the test**

```ts
// src/lib/motion/konvaPointerContract.test.ts
import { describe, it, expect } from "bun:test";
import Konva from "konva";

/**
 * The Motion preview camera is a CSS transform on the stage's container
 * (design spec §1). That only works because Konva converts client coordinates
 * into stage space by dividing out the container's CSS scale:
 *
 *   scaleX = rect.width / content.clientWidth
 *
 * If a Konva upgrade drops or changes that, overlay dragging silently breaks
 * at any zoom other than 1. This pins the contract rather than the version.
 */
describe("Konva pointer/CSS-scale contract", () => {
  it("divides client coordinates by the container's CSS scale", () => {
    const stage = new Konva.Stage({ width: 100, height: 100 });
    // jsdom gives a zeroed getBoundingClientRect, so stand in a container
    // whose rect is 2x its layout size — exactly what `scale(2)` produces.
    (stage as unknown as { content: unknown }).content = {
      getBoundingClientRect: () => ({ top: 10, left: 20, width: 200, height: 200 }),
      clientWidth: 100,
      clientHeight: 100,
    };

    const pos = (
      stage as unknown as {
        _getContentPosition: () => {
          top: number;
          left: number;
          scaleX: number;
          scaleY: number;
        };
      }
    )._getContentPosition();

    expect(pos.scaleX).toBe(2);
    expect(pos.scaleY).toBe(2);
    expect(pos.left).toBe(20);
    expect(pos.top).toBe(10);

    stage.destroy();
  });
});
```

- [ ] **Step 2: Run it**

Run: `cd web && bun test src/lib/motion/konvaPointerContract.test.ts`
Expected: PASS — 1 test. If it FAILS, stop and report: the design's core assumption does not hold in this Konva version.

- [ ] **Step 3: Commit**

```bash
git add web/src/lib/motion/konvaPointerContract.test.ts
git commit -m "test(web): pin Konva's CSS-scale pointer compensation"
```

---

### Task 3: `useCanvasCamera` hook

**Files:**
- Create: `src/components/studio/kv-generator/motion/useCanvasCamera.ts`
- Test: `src/components/studio/kv-generator/motion/useCanvasCamera.test.tsx`

**Interfaces:**
- Consumes: `Camera`, `zoomAt`, `zoomTo`, `panBy`, `fitCamera`, `SCALE_BY` from `@/lib/motion/camera` (Task 1).
- Produces:

```ts
export type UseCanvasCameraArgs = {
  pane: { width: number; height: number };
  board: { width: number; height: number };
};
export type UseCanvasCameraResult = {
  camera: Camera;
  transform: string;              // "translate(Xpx, Ypx) scale(K)"
  fit: () => void;
  zoomIn: () => void;
  zoomOut: () => void;
  /** Spread onto the viewport element. */
  handlers: {
    onWheel: (e: React.WheelEvent) => void;
    onPointerDown: (e: React.PointerEvent) => void;
    onPointerMove: (e: React.PointerEvent) => void;
    onPointerUp: (e: React.PointerEvent) => void;
  };
};
export function useCanvasCamera(args: UseCanvasCameraArgs): UseCanvasCameraResult;
```

**Behaviour the implementer must get right:**
- `onWheel` with `ctrlKey || metaKey` → `zoomAt` anchored at the pointer's position *relative to the viewport element* (`e.clientX - rect.left`), and `preventDefault()` so the browser does not page-zoom.
- `onWheel` without those modifiers → `panBy(-deltaX, -deltaY)`, so content moves with the gesture.
- `onPointerDown` starts a pan **only** when `e.target === e.currentTarget` — i.e. the press landed on the empty viewport, not on the Konva canvas holding the overlays. A press on an overlay must fall through to Konva's own drag.
- `zoomIn`/`zoomOut` anchor at the pane's centre, not at 0,0.
- `fit()` recomputes from the current `pane`/`board`.
- Fit automatically on mount and whenever `board.width`/`board.height` change — but **not** on pane resize (spec §4: silently resetting a user's zoom when a panel toggles is hostile).

- [ ] **Step 1: Write the failing test**

```tsx
// src/components/studio/kv-generator/motion/useCanvasCamera.test.tsx
import { describe, it, expect } from "bun:test";
import { renderHook, act } from "@testing-library/react";

import { MAX_SCALE } from "@/lib/motion/camera";

import { useCanvasCamera } from "./useCanvasCamera";

const PANE = { width: 800, height: 400 };
const BOARD = { width: 1080, height: 1920 };

function wheelEvent(over: Partial<WheelEvent> & { ctrlKey?: boolean }) {
  return {
    ctrlKey: false,
    metaKey: false,
    deltaX: 0,
    deltaY: 0,
    clientX: 400,
    clientY: 200,
    preventDefault: () => {},
    currentTarget: {
      getBoundingClientRect: () => ({ left: 0, top: 0, width: 800, height: 400 }),
    },
    ...over,
  } as unknown as React.WheelEvent;
}

describe("useCanvasCamera", () => {
  it("fits on mount", () => {
    const { result } = renderHook(() => useCanvasCamera({ pane: PANE, board: BOARD }));
    expect(result.current.camera.scale).toBeCloseTo(400 / 1920, 6);
  });

  it("ctrl+wheel zooms, plain wheel pans", () => {
    const { result } = renderHook(() => useCanvasCamera({ pane: PANE, board: BOARD }));
    const fitted = result.current.camera;

    act(() => result.current.handlers.onWheel(wheelEvent({ ctrlKey: true, deltaY: -100 })));
    const zoomed = result.current.camera;
    expect(zoomed.scale).toBeGreaterThan(fitted.scale);

    act(() => result.current.handlers.onWheel(wheelEvent({ deltaX: 30, deltaY: 20 })));
    expect(result.current.camera.scale).toBe(zoomed.scale);
    expect(result.current.camera.x).toBeCloseTo(zoomed.x - 30, 6);
    expect(result.current.camera.y).toBeCloseTo(zoomed.y - 20, 6);
  });

  it("exposes a CSS transform string matching the camera", () => {
    const { result } = renderHook(() => useCanvasCamera({ pane: PANE, board: BOARD }));
    const c = result.current.camera;
    expect(result.current.transform).toBe(
      `translate(${c.x}px, ${c.y}px) scale(${c.scale})`
    );
  });

  it("zoomIn/zoomOut anchor at the pane centre", () => {
    const { result } = renderHook(() => useCanvasCamera({ pane: PANE, board: BOARD }));
    const before = result.current.camera;
    const cx = (PANE.width / 2 - before.x) / before.scale;
    act(() => result.current.zoomIn());
    const after = result.current.camera;
    expect(cx * after.scale + after.x).toBeCloseTo(PANE.width / 2, 6);
  });

  it("fit() restores the fitted camera after zooming", () => {
    const { result } = renderHook(() => useCanvasCamera({ pane: PANE, board: BOARD }));
    const fitted = { ...result.current.camera };
    act(() => result.current.zoomIn());
    expect(result.current.camera.scale).not.toBeCloseTo(fitted.scale, 6);
    act(() => result.current.fit());
    expect(result.current.camera.scale).toBeCloseTo(fitted.scale, 6);
    expect(result.current.camera.x).toBeCloseTo(fitted.x, 6);
  });

  it("does NOT refit when only the pane changes", () => {
    const { result, rerender } = renderHook(
      ({ pane }) => useCanvasCamera({ pane, board: BOARD }),
      { initialProps: { pane: PANE } }
    );
    act(() => result.current.zoomIn());
    const zoomed = { ...result.current.camera };
    rerender({ pane: { width: 600, height: 300 } });
    expect(result.current.camera).toEqual(zoomed);
  });

  it("refits when the board changes", () => {
    const { result, rerender } = renderHook(
      ({ board }) => useCanvasCamera({ pane: PANE, board }),
      { initialProps: { board: BOARD } }
    );
    act(() => result.current.zoomIn());
    rerender({ board: { width: 1920, height: 1080 } });
    expect(result.current.camera.scale).toBeCloseTo(
      Math.min(800 / 1920, 400 / 1080),
      6
    );
  });

  it("clamps at the maximum scale", () => {
    const { result } = renderHook(() => useCanvasCamera({ pane: PANE, board: BOARD }));
    for (let i = 0; i < 400; i++) act(() => result.current.zoomIn());
    expect(result.current.camera.scale).toBe(MAX_SCALE);
  });

  it("pans on a drag that starts on the empty viewport", () => {
    const { result } = renderHook(() => useCanvasCamera({ pane: PANE, board: BOARD }));
    const start = { ...result.current.camera };
    const el = {} as EventTarget;
    const down = {
      target: el,
      currentTarget: el,
      clientX: 100,
      clientY: 100,
      pointerId: 1,
      button: 0,
      preventDefault: () => {},
      currentTargetSetPointerCapture: undefined,
    } as unknown as React.PointerEvent;
    act(() => result.current.handlers.onPointerDown(down));
    act(() =>
      result.current.handlers.onPointerMove({
        clientX: 140,
        clientY: 130,
        pointerId: 1,
      } as unknown as React.PointerEvent)
    );
    expect(result.current.camera.x).toBeCloseTo(start.x + 40, 6);
    expect(result.current.camera.y).toBeCloseTo(start.y + 30, 6);
  });

  it("does NOT pan when the drag starts on the stage (an overlay drag)", () => {
    const { result } = renderHook(() => useCanvasCamera({ pane: PANE, board: BOARD }));
    const start = { ...result.current.camera };
    const down = {
      target: {} as EventTarget,       // a child, not the viewport itself
      currentTarget: {} as EventTarget,
      clientX: 100,
      clientY: 100,
      pointerId: 1,
      button: 0,
      preventDefault: () => {},
    } as unknown as React.PointerEvent;
    act(() => result.current.handlers.onPointerDown(down));
    act(() =>
      result.current.handlers.onPointerMove({
        clientX: 200,
        clientY: 200,
        pointerId: 1,
      } as unknown as React.PointerEvent)
    );
    expect(result.current.camera).toEqual(start);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/motion/useCanvasCamera.test.tsx`
Expected: FAIL — `Cannot find module './useCanvasCamera'`

- [ ] **Step 3: Write the implementation**

```ts
// src/components/studio/kv-generator/motion/useCanvasCamera.ts
"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import {
  fitCamera,
  panBy,
  zoomAt,
  type Camera,
} from "@/lib/motion/camera";

export type UseCanvasCameraArgs = {
  pane: { width: number; height: number };
  board: { width: number; height: number };
};

export type UseCanvasCameraResult = {
  camera: Camera;
  transform: string;
  fit: () => void;
  zoomIn: () => void;
  zoomOut: () => void;
  handlers: {
    onWheel: (e: React.WheelEvent) => void;
    onPointerDown: (e: React.PointerEvent) => void;
    onPointerMove: (e: React.PointerEvent) => void;
    onPointerUp: (e: React.PointerEvent) => void;
  };
};

/**
 * Camera for the Motion preview viewport. Mirrors the Craft canvas's gestures
 * (`KvKonvaCanvas.handleWheel`) — ctrl/meta+wheel zooms at the pointer, which
 * is what a Mac trackpad pinch emits; plain wheel pans — but drives a CSS
 * transform rather than the Konva stage, so the stage's coordinate space (and
 * therefore overlay drag math) is untouched. See the design spec §1.
 */
export function useCanvasCamera({
  pane,
  board,
}: UseCanvasCameraArgs): UseCanvasCameraResult {
  const [camera, setCamera] = useState<Camera>(() => fitCamera(pane, board));

  // Latest pane/board without making the fit effect depend on pane: refitting
  // on every pane resize would throw away the user's zoom whenever a panel
  // toggled (design spec §4).
  const paneRef = useRef(pane);
  paneRef.current = pane;
  const boardRef = useRef(board);
  boardRef.current = board;

  const fit = useCallback(() => {
    setCamera(fitCamera(paneRef.current, boardRef.current));
  }, []);

  // Refit on mount and whenever the BOARD changes — a different board is a
  // different subject, so the previous viewing posture no longer applies.
  useEffect(() => {
    setCamera(fitCamera(paneRef.current, { width: board.width, height: board.height }));
  }, [board.width, board.height]);

  const zoomAtCentre = useCallback((direction: 1 | -1) => {
    const p = paneRef.current;
    const centre = { x: p.width / 2, y: p.height / 2 };
    setCamera((cam) => zoomAt(cam, centre, direction));
  }, []);

  const zoomIn = useCallback(() => zoomAtCentre(1), [zoomAtCentre]);
  const zoomOut = useCallback(() => zoomAtCentre(-1), [zoomAtCentre]);

  const onWheel = useCallback((e: React.WheelEvent) => {
    e.preventDefault();
    if (e.ctrlKey || e.metaKey) {
      const rect = e.currentTarget.getBoundingClientRect();
      const pointer = { x: e.clientX - rect.left, y: e.clientY - rect.top };
      const direction = e.deltaY > 0 ? -1 : 1;
      setCamera((cam) => zoomAt(cam, pointer, direction));
      return;
    }
    setCamera((cam) => panBy(cam, -e.deltaX, -e.deltaY));
  }, []);

  // Pan drag. Only starts when the press lands on the viewport ITSELF — a
  // press on the stage below belongs to Konva's own overlay dragging.
  const panFrom = useRef<{ x: number; y: number } | null>(null);

  const onPointerDown = useCallback((e: React.PointerEvent) => {
    if (e.target !== e.currentTarget) return;
    panFrom.current = { x: e.clientX, y: e.clientY };
  }, []);

  const onPointerMove = useCallback((e: React.PointerEvent) => {
    const from = panFrom.current;
    if (!from) return;
    const dx = e.clientX - from.x;
    const dy = e.clientY - from.y;
    panFrom.current = { x: e.clientX, y: e.clientY };
    setCamera((cam) => panBy(cam, dx, dy));
  }, []);

  const onPointerUp = useCallback(() => {
    panFrom.current = null;
  }, []);

  const transform = `translate(${camera.x}px, ${camera.y}px) scale(${camera.scale})`;

  const handlers = useMemo(
    () => ({ onWheel, onPointerDown, onPointerMove, onPointerUp }),
    [onWheel, onPointerDown, onPointerMove, onPointerUp]
  );

  return { camera, transform, fit, zoomIn, zoomOut, handlers };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/motion/useCanvasCamera.test.tsx`
Expected: PASS — 10 tests

- [ ] **Step 5: Commit**

```bash
git add web/src/components/studio/kv-generator/motion/useCanvasCamera.ts web/src/components/studio/kv-generator/motion/useCanvasCamera.test.tsx
git commit -m "feat(web): add the Motion preview camera hook"
```

---

### Task 4: Canvas zoom pill

**Files:**
- Create: `src/components/studio/kv-generator/motion/KvMotionCanvasZoomPill.tsx`
- Test: `src/components/studio/kv-generator/motion/KvMotionCanvasZoomPill.test.tsx`

**Interfaces:**
- Consumes: `Button` from `@/components/frndos/v2`; phosphor icons (`Minus`, `Plus`, `CornersOut`) from `@phosphor-icons/react`.
- Produces:

```ts
export type KvMotionCanvasZoomPillProps = {
  scale: number;
  onZoomIn: () => void;
  onZoomOut: () => void;
  onFit: () => void;
};
export function KvMotionCanvasZoomPill(p: KvMotionCanvasZoomPillProps): JSX.Element;
```

**Placement note for the implementer:** this control renders floating at the bottom-right INSIDE the preview viewport. It is deliberately not in the transport bar — the transport already has a zoom percentage and a Fit button belonging to the *timeline*, and two identical-looking controls on one screen would be confusing (spec §5). Use the same `frndos-float-panel` pill styling the studio's other floating controls use.

- [ ] **Step 1: Write the failing test**

```tsx
// src/components/studio/kv-generator/motion/KvMotionCanvasZoomPill.test.tsx
import { describe, it, expect, mock } from "bun:test";
import { fireEvent, render, within } from "@testing-library/react";

import { KvMotionCanvasZoomPill } from "./KvMotionCanvasZoomPill";

// `screen` binds to a stale document under bun's jsdom preload.
function setup(scale = 1) {
  const onZoomIn = mock(() => {});
  const onZoomOut = mock(() => {});
  const onFit = mock(() => {});
  render(
    <KvMotionCanvasZoomPill
      scale={scale}
      onZoomIn={onZoomIn}
      onZoomOut={onZoomOut}
      onFit={onFit}
    />
  );
  return { onZoomIn, onZoomOut, onFit, body: within(document.body) };
}

describe("KvMotionCanvasZoomPill", () => {
  it("renders the scale as a rounded percentage", () => {
    const { body } = setup(0.2083);
    expect(body.getByText("21%")).toBeTruthy();
  });

  it("renders 100% at scale 1", () => {
    const { body } = setup(1);
    expect(body.getByText("100%")).toBeTruthy();
  });

  it("fires each callback", () => {
    const { onZoomIn, onZoomOut, onFit, body } = setup();
    fireEvent.click(body.getByLabelText("Zoom in"));
    fireEvent.click(body.getByLabelText("Zoom out"));
    fireEvent.click(body.getByLabelText("Fit to view"));
    expect(onZoomIn).toHaveBeenCalledTimes(1);
    expect(onZoomOut).toHaveBeenCalledTimes(1);
    expect(onFit).toHaveBeenCalledTimes(1);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/motion/KvMotionCanvasZoomPill.test.tsx`
Expected: FAIL — `Cannot find module './KvMotionCanvasZoomPill'`

- [ ] **Step 3: Write the implementation**

```tsx
// src/components/studio/kv-generator/motion/KvMotionCanvasZoomPill.tsx
"use client";

import { CornersOut, Minus, Plus } from "@phosphor-icons/react";

import { Button } from "@/components/frndos/v2";

export type KvMotionCanvasZoomPillProps = {
  scale: number;
  onZoomIn: () => void;
  onZoomOut: () => void;
  onFit: () => void;
};

/**
 * Floating zoom control for the Motion preview canvas.
 *
 * Lives INSIDE the preview viewport (bottom-right), not in the transport bar:
 * the transport already carries a zoom percentage and a Fit button for the
 * TIMELINE, and two identical-looking controls on one screen read as the same
 * thing. Physical separation is what distinguishes them.
 */
export function KvMotionCanvasZoomPill({
  scale,
  onZoomIn,
  onZoomOut,
  onFit,
}: KvMotionCanvasZoomPillProps) {
  return (
    <div className="frndos-float-panel pointer-events-auto absolute bottom-3 right-3 flex items-center gap-1 rounded-full px-1.5 py-1 shadow-lg backdrop-blur-[16px]">
      <Button variant="icon" size="tiny" aria-label="Zoom out" onClick={onZoomOut}>
        <Minus size={14} />
      </Button>
      <span className="min-w-[3.25rem] text-center font-geist text-textXs text-text-inverse-subtlest">
        {Math.round(scale * 100)}%
      </span>
      <Button variant="icon" size="tiny" aria-label="Zoom in" onClick={onZoomIn}>
        <Plus size={14} />
      </Button>
      <Button variant="icon" size="tiny" aria-label="Fit to view" onClick={onFit}>
        <CornersOut size={14} />
      </Button>
    </div>
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/motion/KvMotionCanvasZoomPill.test.tsx`
Expected: PASS — 3 tests

- [ ] **Step 5: Commit**

```bash
git add web/src/components/studio/kv-generator/motion/KvMotionCanvasZoomPill.tsx web/src/components/studio/kv-generator/motion/KvMotionCanvasZoomPill.test.tsx
git commit -m "feat(web): add the Motion canvas zoom pill"
```

---

### Task 5: Wire the camera into `KvMotionEditor`

**Files:**
- Modify: `src/components/studio/kv-generator/motion/KvMotionEditor.tsx`

**Interfaces:**
- Consumes: `useCanvasCamera` (Task 3), `KvMotionCanvasZoomPill` (Task 4).
- Produces: nothing new.

**The three changes, in order:**

**(a) Build the stage at board size.** Replace the fit-to-pane `targetWidth`/`targetHeight` memo with the snapshot's own board dimensions:

```ts
// The stage is built at the board's OWN pixels and the camera does the
// fitting, so zooming reveals real detail instead of magnifying preview
// pixels — and the preview stage now has the exact dimensions the export
// stage uses. `videoSafeDims` already caps board dims at a 1920 longest
// edge, so this cannot blow up.
const targetWidth = activeRatio.w;
const targetHeight = activeRatio.h;
```

Keep the names `targetWidth`/`targetHeight` — the drag-commit math and `remapSnapshotForRatio` both read them, and both stay correct (the stage's pixel size still equals the board's rendered size, which is the identity the whole design preserves).

**(b) Wrap the stage in a camera viewport.** Replace the current preview markup:

```tsx
<div className="flex flex-1 items-center justify-center overflow-hidden p-6">
  <div ref={previewRef} data-testid="motion-preview-wrapper" className="flex h-full w-full items-center justify-center rounded-xl">
    <div ref={stageContainerRef} style={{ width: targetWidth, height: targetHeight }} />
  </div>
</div>
```

with:

```tsx
<div className="flex flex-1 items-center justify-center overflow-hidden p-6">
  <div
    ref={previewRef}
    data-testid="motion-preview-wrapper"
    className="relative h-full w-full overflow-hidden rounded-xl"
    {...camera.handlers}
  >
    <div
      data-testid="motion-camera-layer"
      style={{
        width: targetWidth,
        height: targetHeight,
        transform: camera.transform,
        transformOrigin: "0 0",
        position: "absolute",
        top: 0,
        left: 0,
      }}
    >
      <div ref={stageContainerRef} />
    </div>
    <KvMotionCanvasZoomPill
      scale={camera.camera.scale}
      onZoomIn={camera.zoomIn}
      onZoomOut={camera.zoomOut}
      onFit={camera.fit}
    />
  </div>
</div>
```

Note the wrapper loses `flex items-center justify-center` — centring is now the camera's job (`fitCamera` centres), and leaving flex centring on would fight the transform.

**(c) Call the hook**, next to the existing `paneSize` state:

```ts
const camera = useCanvasCamera({
  pane: paneSize,
  board: { width: targetWidth, height: targetHeight },
});
```

- [ ] **Step 1: Make the three changes above**

Read the file first — line numbers in this plan will have drifted.

- [ ] **Step 2: Verify the suites still pass**

Run: `cd web && bun test src/components/studio/kv-generator/motion/ src/components/motion-editor/ src/lib/motion/`
Expected: PASS. If an existing test asserted on the old preview-wrapper markup, update it to the new structure and say so explicitly in your report.

- [ ] **Step 3: Type check**

Run: `cd web && bunx tsc --noEmit 2>&1 | grep -E 'KvMotionEditor|useCanvasCamera|KvMotionCanvasZoomPill|lib/motion/camera'`
Expected: no output.

- [ ] **Step 4: Build**

Run: `cd web && bun run build`
Expected: exit 0. (This is NOT a type gate — `ignoreBuildErrors` is set — but it catches broken imports.)

- [ ] **Step 5: Commit**

```bash
git add web/src/components/studio/kv-generator/motion/KvMotionEditor.tsx
git commit -m "feat(web): make the Motion preview canvas pannable and zoomable"
```

---

## Final verification

- [ ] `cd web && bun test src/lib/motion/ src/components/studio/kv-generator/motion/ src/components/motion-editor/` — all green.
- [ ] `cd web && bunx tsc --noEmit` — zero errors attributable to any file in this plan (grep for them; the repo baseline is ~558 unrelated errors).
- [ ] `cd web && bunx eslint <touched files>` — compare against a `git show HEAD:<path>` baseline copy, never `git stash`.
- [ ] Manual: trackpad-pinch the preview and confirm it zooms at the cursor; plain two-finger scroll pans; drag an overlay at 3× zoom and confirm it lands where dropped and the timeline records the right position; Fit re-centres; export and confirm the MP4 is unchanged by any camera state.
