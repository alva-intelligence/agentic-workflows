# Canvas World Overlay — P1 (foundation + board chrome) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Board/tile captions and the other always-on board chrome stay glued to their boards through pan and zoom, moved by camera CSS variables written in the same event that moves the Fabric canvas — built as a shared foundation in `src/lib/canvas/`.

**Architecture:** A surface-agnostic camera store (`src/lib/canvas/cameraStore.ts`) gains a synchronous `subscribe`. A framework-free binder writes `--cam-*` CSS variables onto an overlay element on every camera change; pure helpers turn world coordinates into `calc()` / `transform: translate()` strings that read those variables. KV Craft's `BoardChrome` switches from screen rects computed from React camera state to world rects styled by the helpers.

**Tech Stack:** Next.js 16 / React 19 / TypeScript, Fabric v7, bun test (`bun:test`), Tailwind.

**Spec:** `docs/superpowers/specs/2026-09-24-kv-canvas-world-overlay-design.md` (workspace repo). P2 (strip chrome) and P3 (comment pins) get their own plans after this lands; they consume the interfaces produced here.

## Global Constraints

- Work in `web/` on branch `feature/daffa/vc-kv-craft-resize-strip`. Commit per task. **Do not push** unless Daffa asks. Never `git stash`.
- Gates after every task: `bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -c "error TS"` must stay **≤ 933**; `bunx eslint --fix <touched files>` adds no warning; `bun test <explicit files>` (never a directory; for many files use `find … -print0 | xargs -0 bun test`). `node ./node_modules/next/dist/bin/next build` exit 0 at the end of Task 5.
- Test policy: pure/framework-free tests only; no RTL/component tests for the canvas.
- CSS variable names (spec §Approach 2): `--cam-s`, `--cam-x`, `--cam-y`, `--cam-cs`, plus the ≤1 clamp used by the ready chips, named **`--cam-s-max1`** here (the spec's `--cam-cs-ready`, renamed because the foundation is surface-agnostic).
- Chrome keeps its current visual rules exactly: captions `14px`/`18px` × `chromeScale`, `-22px × chromeScale` above the board, tile caption width `max(W·s − 64·cs, 64px)`, board label width `max(W·s, 64px)`, Concept badge `+8px,+8px`, ready chips bottom-right at `(x+W, y−4px | y−24px)` scaled by `min(1, s)`, "+" button at `(x+W+10px, y+H/2−18px)`, rationale card at `(x, y+H+12px)` width `W·s`, crafting overlay and pending placeholders = full board rect.
- `chromeScale` lives in KV (`src/components/studio/kv-generator/chromeScale.ts`) and is passed to the foundation as an option — the foundation never imports KV.

## Review Focus

- **First paint before any gesture:** the variables must be written when the layer binds, or every label renders at (0,0) until the user touches the canvas. (Task 3 test: bind writes immediately.)
- **Doc/mode switch recreates the canvas/store:** the binder must unsubscribe from the old store and bind the new one; an old store must not keep writing. (Task 3 test: unsubscribe stops writes.)
- **Zoom below 60 %:** captions shrink to the same clamp as today via `--cam-cs`. (Task 2 parity test at scale 0.3.)
- **Board dragged by its label:** chrome follows the live drag position (`liveDrag.center`), not the persisted center. (Task 4 keeps `liveDrag` in `worldRectOf`; manual check.)
- **Rename input after a pan:** `BoardNameInput` is still positioned from React camera state (transient, out of scope); at rest it must line up with the caption it replaces. (Manual check in Task 5.)

---

### Task 1: Surface-agnostic camera store with a synchronous `subscribe`

**Files:**
- Create: `web/src/lib/canvas/cameraStore.ts`
- Create: `web/src/lib/canvas/cameraStore.test.ts`
- Modify: `web/src/components/studio/kv-generator/kvCameraStore.ts` (becomes a thin wrapper)

**Interfaces:**
- Produces: `type Camera = { scale: number; x: number; y: number }`; `type CameraListener = (cam: Camera) => void`; `interface CameraStore { set; setLive; get(): Camera; subscribe(l: CameraListener): () => void; dispose(): void }`; `createCameraStore({ cameraRef, applyToEngine, commit, raf?, caf? }): CameraStore`.
- KV keeps `createKvCameraStore({ cameraRef, applyToFabric, commit, raf?, caf? })` and `type KvCameraStore = CameraStore` so `kvCameraStore.test.ts` and `fabric/useCanvasCamera.ts` keep compiling unchanged.

- [ ] **Step 1: Write the failing test** — `web/src/lib/canvas/cameraStore.test.ts`

```ts
import { describe, it, expect } from "bun:test";
import { createCameraStore, type Camera } from "./cameraStore";

function harness() {
  const cameraRef = { current: { scale: 1, x: 0, y: 0 } as Camera };
  const applied: Camera[] = [];
  const committed: Camera[] = [];
  let frame: FrameRequestCallback | null = null;
  const store = createCameraStore({
    cameraRef,
    applyToEngine: (c) => applied.push(c),
    commit: (c) => committed.push(c),
    raf: (cb) => {
      frame = cb;
      return 1;
    },
    caf: () => {
      frame = null;
    },
  });
  return {
    store,
    cameraRef,
    applied,
    committed,
    flush: () => {
      const f = frame;
      frame = null;
      f?.(0);
    },
  };
}

describe("createCameraStore — subscribe", () => {
  it("notifies listeners synchronously on setLive, before the frame commit", () => {
    const h = harness();
    const seen: Camera[] = [];
    h.store.subscribe((c) => seen.push(c));
    h.store.setLive({ scale: 2, x: 10, y: 20 });
    expect(seen).toEqual([{ scale: 2, x: 10, y: 20 }]);
    expect(h.applied).toHaveLength(1);
    expect(h.committed).toHaveLength(0); // React still waits for the frame
    h.flush();
    expect(h.committed).toEqual([{ scale: 2, x: 10, y: 20 }]);
  });

  it("notifies on set too, and resolves updater functions against the ref", () => {
    const h = harness();
    const seen: Camera[] = [];
    h.store.subscribe((c) => seen.push(c));
    h.store.set((c) => ({ ...c, x: c.x + 5 }));
    expect(seen).toEqual([{ scale: 1, x: 5, y: 0 }]);
    expect(h.store.get()).toEqual({ scale: 1, x: 5, y: 0 });
  });

  it("stops notifying after unsubscribe", () => {
    const h = harness();
    const seen: Camera[] = [];
    const off = h.store.subscribe((c) => seen.push(c));
    off();
    h.store.setLive({ scale: 3, x: 0, y: 0 });
    expect(seen).toEqual([]);
  });

  it("get() is the ref, never a stale React value", () => {
    const h = harness();
    h.store.setLive({ scale: 4, x: 1, y: 1 });
    expect(h.store.get()).toEqual({ scale: 4, x: 1, y: 1 });
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd web && bun test src/lib/canvas/cameraStore.test.ts`
Expected: FAIL — `Cannot find module './cameraStore'`.

- [ ] **Step 3: Implement** — `web/src/lib/canvas/cameraStore.ts`

```ts
/**
 * Surface-agnostic camera store for canvas editors (KV Craft first; the
 * runner board, decks and Motion can adopt it). The REF is the source of
 * truth; the engine (Fabric, Konva, a CSS transform…) follows it
 * synchronously; subscribers (the world overlay's CSS variables) follow it
 * synchronously too; React state follows at once (`set`) or once per
 * animation frame (`setLive`).
 *
 * Why subscribers are synchronous: DOM chrome positioned from React state
 * trails the canvas by at least a frame during a gesture (docs/adr/0005).
 * Listeners run in the same event as `applyToEngine`, so chrome driven by
 * them moves with the pixels.
 *
 * Framework-free so it can be tested with a fake rAF.
 */
export type Camera = { scale: number; x: number; y: number };
export type CameraListener = (cam: Camera) => void;

export interface CameraStore {
  /** Programmatic moves (fit, focus, mode switch): commit React at once. */
  set: (next: Camera | ((cam: Camera) => Camera)) => void;
  /** Gesture moves (wheel, pinch, hand drag): commit React once per frame. */
  setLive: (next: Camera | ((cam: Camera) => Camera)) => void;
  /** The current camera — always the ref, never a stale React value. */
  get: () => Camera;
  /** Called synchronously on every set/setLive; returns unsubscribe. */
  subscribe: (listener: CameraListener) => () => void;
  /** Cancel a pending frame commit and drop listeners (unmount). */
  dispose: () => void;
}

export function createCameraStore({
  cameraRef,
  applyToEngine,
  commit,
  raf = requestAnimationFrame,
  caf = cancelAnimationFrame,
}: {
  cameraRef: { current: Camera };
  applyToEngine: (cam: Camera) => void;
  commit: (cam: Camera) => void;
  raf?: (cb: FrameRequestCallback) => number;
  caf?: (handle: number) => void;
}): CameraStore {
  let pendingFrame: number | null = null;
  const listeners = new Set<CameraListener>();

  const resolve = (next: Camera | ((cam: Camera) => Camera)) => {
    const resolved =
      typeof next === "function" ? next(cameraRef.current) : next;
    cameraRef.current = resolved;
    applyToEngine(resolved);
    listeners.forEach((l) => l(resolved));
    return resolved;
  };
  const cancelPending = () => {
    if (pendingFrame == null) return;
    caf(pendingFrame);
    pendingFrame = null;
  };

  return {
    set: (next) => {
      const resolved = resolve(next);
      // A synchronous commit supersedes any frame still queued.
      cancelPending();
      commit(resolved);
    },
    setLive: (next) => {
      resolve(next);
      if (pendingFrame != null) return;
      pendingFrame = raf(() => {
        pendingFrame = null;
        // Read the ref at fire time: every event since scheduling has
        // already folded into it, so one commit carries them all.
        commit(cameraRef.current);
      });
    },
    get: () => cameraRef.current,
    subscribe: (listener) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    dispose: () => {
      cancelPending();
      listeners.clear();
    },
  };
}
```

- [ ] **Step 4: Make the KV store a thin wrapper** — replace the body of `web/src/components/studio/kv-generator/kvCameraStore.ts` with:

```ts
import type { MutableRefObject } from "react";
import {
  createCameraStore,
  type CameraStore,
} from "@/lib/canvas/cameraStore";
import type { KvCamera } from "./kvCamera";

/**
 * The KV canvas's camera store — the shared `src/lib/canvas/cameraStore.ts`
 * with Fabric as its engine. Kept under its old name so existing imports and
 * `kvCameraStore.test.ts` stay untouched; see the shared module for the
 * two-lane (`set` / `setLive`) rationale and `subscribe`.
 */
export type KvCameraStore = CameraStore;

export function createKvCameraStore({
  cameraRef,
  applyToFabric,
  commit,
  raf,
  caf,
}: {
  cameraRef: MutableRefObject<KvCamera>;
  applyToFabric: (cam: KvCamera) => void;
  commit: (cam: KvCamera) => void;
  raf?: (cb: FrameRequestCallback) => number;
  caf?: (handle: number) => void;
}): KvCameraStore {
  return createCameraStore({
    cameraRef,
    applyToEngine: applyToFabric,
    commit,
    raf,
    caf,
  });
}
```

- [ ] **Step 5: Run both store tests**

Run: `cd web && bun test src/lib/canvas/cameraStore.test.ts src/components/studio/kv-generator/kvCameraStore.test.ts`
Expected: PASS (4 new + the existing KV store tests).

- [ ] **Step 6: Gates + commit**

```bash
cd web
bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -c "error TS"   # ≤ 933
bunx eslint --fix src/lib/canvas/cameraStore.ts src/lib/canvas/cameraStore.test.ts src/components/studio/kv-generator/kvCameraStore.ts
git add src/lib/canvas/cameraStore.ts src/lib/canvas/cameraStore.test.ts src/components/studio/kv-generator/kvCameraStore.ts
git commit -m "feat(web): shared canvas camera store with a synchronous subscribe (world overlay P1)"
```

---

### Task 2: Pure world-overlay helpers (CSS variables + `calc()` / `translate()` strings)

**Files:**
- Create: `web/src/lib/canvas/worldOverlay.ts`
- Create: `web/src/lib/canvas/worldOverlay.test.ts`

**Interfaces:**
- Consumes: `Camera` from Task 1.
- Produces:
  - `CAMERA_CSS_VAR = { scale: "--cam-s", x: "--cam-x", y: "--cam-y", chrome: "--cam-cs", scaleMax1: "--cam-s-max1" } as const`
  - `cameraCssVars(cam: Camera, opts?: { chromeScale?: (scale: number) => number }): Record<string, string>`
  - `type Len = { world?: number; px?: number; chrome?: number }` — a length = `world·s + px + chrome·cs`
  - `lenCss(l: Len): string` — a SIZE (no camera translation)
  - `coordCss(axis: "x" | "y", l: Len): string` — a SCREEN COORDINATE (`world·s + cam-axis + px + chrome·cs`)
  - `worldTranslate(x: Len, y: Len): string` — `translate(<coordCss x>, <coordCss y>)`
  - `maxCss(a: string, b: string): string` — `max(a, b)`

- [ ] **Step 1: Write the failing test** — `web/src/lib/canvas/worldOverlay.test.ts`

```ts
import { describe, it, expect } from "bun:test";
import {
  cameraCssVars,
  coordCss,
  lenCss,
  maxCss,
  worldTranslate,
} from "./worldOverlay";
import { worldRectToScreen } from "@/components/studio/kv-generator/gestureMath";
import { chromeScale } from "@/components/studio/kv-generator/chromeScale";
import type { Camera } from "./cameraStore";

/** Test-only evaluator for the tiny calc grammar the helpers emit. */
function evalCss(expr: string, vars: Record<string, string>): number {
  const js = expr
    .replace(/var\((--[\w-]+)\)/g, (_, n: string) => {
      const v = vars[n];
      if (v === undefined) throw new Error(`unset ${n}`);
      return `(${parseFloat(v)})`;
    })
    .replace(/calc\(/g, "(")
    .replace(/max\(/g, "Math.max(")
    .replace(/(-?\d*\.?\d+)px/g, "$1");
  return new Function(`return (${js});`)() as number;
}

const cams: Camera[] = [
  { scale: 1, x: 0, y: 0 },
  { scale: 0.38, x: -412.5, y: 96 },
  { scale: 2.5, x: 1200, y: -800 },
];

describe("cameraCssVars", () => {
  it("writes scale, translation (px), chrome clamp and the ≤1 clamp", () => {
    expect(
      cameraCssVars({ scale: 0.3, x: 10, y: -5 }, { chromeScale })
    ).toEqual({
      "--cam-s": "0.3",
      "--cam-x": "10px",
      "--cam-y": "-5px",
      "--cam-cs": String(chromeScale(0.3)),
      "--cam-s-max1": "0.3",
    });
    expect(cameraCssVars({ scale: 2, x: 0, y: 0 })["--cam-cs"]).toBe("1");
    expect(cameraCssVars({ scale: 2, x: 0, y: 0 })["--cam-s-max1"]).toBe("1");
  });
});

describe("coordCss / lenCss — parity with worldRectToScreen", () => {
  const rect = { x: 120, y: -40, width: 512, height: 910 };
  for (const cam of cams) {
    it(`matches at scale ${cam.scale}`, () => {
      const vars = cameraCssVars(cam, { chromeScale });
      const screen = worldRectToScreen(rect, {
        scale: cam.scale,
        pos: { x: cam.x, y: cam.y },
      });
      expect(evalCss(coordCss("x", { world: rect.x }), vars)).toBeCloseTo(
        screen.x
      );
      expect(evalCss(coordCss("y", { world: rect.y }), vars)).toBeCloseTo(
        screen.y
      );
      expect(evalCss(lenCss({ world: rect.width }), vars)).toBeCloseTo(
        screen.width
      );
    });
  }
});

describe("chrome offsets", () => {
  it("caption top = y·s + cam-y − 22·cs, clamped below 60% zoom", () => {
    const cam = { scale: 0.3, x: 0, y: 50 };
    const vars = cameraCssVars(cam, { chromeScale });
    const top = evalCss(coordCss("y", { world: 100, chrome: -22 }), vars);
    expect(top).toBeCloseTo(100 * 0.3 + 50 - 22 * chromeScale(0.3));
  });
  it("fixed px offsets are not scaled", () => {
    const vars = cameraCssVars({ scale: 3, x: 0, y: 0 }, { chromeScale });
    expect(evalCss(coordCss("x", { world: 10, px: 8 }), vars)).toBeCloseTo(38);
  });
  it("max() keeps the 64px floor on a tiny tile caption", () => {
    const vars = cameraCssVars({ scale: 0.1, x: 0, y: 0 }, { chromeScale });
    const w = evalCss(
      maxCss(lenCss({ world: 512, chrome: -64 }), "64px"),
      vars
    );
    expect(w).toBe(64);
  });
  it("worldTranslate wraps both coordinates", () => {
    expect(worldTranslate({ world: 1 }, { world: 2 })).toBe(
      `translate(${coordCss("x", { world: 1 })}, ${coordCss("y", { world: 2 })})`
    );
  });
  it("omits zero terms and never emits an empty calc", () => {
    expect(lenCss({})).toBe("0px");
    expect(lenCss({ px: 12 })).toBe("12px");
    expect(lenCss({ world: 2 })).toBe("calc(2px * var(--cam-s))");
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd web && bun test src/lib/canvas/worldOverlay.test.ts`
Expected: FAIL — `Cannot find module './worldOverlay'`.

- [ ] **Step 3: Implement** — `web/src/lib/canvas/worldOverlay.ts`

```ts
import type { Camera } from "./cameraStore";

/**
 * World overlay (docs/adr/0005 layer 2): DOM chrome positioned in WORLD
 * coordinates and moved by camera CSS variables, which `bindCameraCssVars`
 * writes in the same event that moves the canvas. These helpers emit the
 * `calc()` / `translate()` strings that read those variables — pure, so the
 * formula can be tested against the canvas's own world→screen math.
 *
 * A length is `world · scale + px + chrome · chromeScale`:
 * - `world`  follows the zoom (a board edge, a board width),
 * - `px`     is a fixed screen offset (a badge inset),
 * - `chrome` follows the surface's clamped chrome scale (caption offsets).
 */
export const CAMERA_CSS_VAR = {
  scale: "--cam-s",
  x: "--cam-x",
  y: "--cam-y",
  chrome: "--cam-cs",
  scaleMax1: "--cam-s-max1",
} as const;

export type Len = { world?: number; px?: number; chrome?: number };

export function cameraCssVars(
  cam: Camera,
  opts: { chromeScale?: (scale: number) => number } = {}
): Record<string, string> {
  const chrome = opts.chromeScale ? opts.chromeScale(cam.scale) : 1;
  return {
    [CAMERA_CSS_VAR.scale]: String(cam.scale),
    [CAMERA_CSS_VAR.x]: `${cam.x}px`,
    [CAMERA_CSS_VAR.y]: `${cam.y}px`,
    [CAMERA_CSS_VAR.chrome]: String(chrome),
    [CAMERA_CSS_VAR.scaleMax1]: String(Math.min(1, cam.scale)),
  };
}

function terms(l: Len, extraVar?: string): string[] {
  const out: string[] = [];
  if (l.world) out.push(`${l.world}px * var(${CAMERA_CSS_VAR.scale})`);
  if (extraVar) out.push(`var(${extraVar})`);
  if (l.px) out.push(`${l.px}px`);
  if (l.chrome) out.push(`${l.chrome}px * var(${CAMERA_CSS_VAR.chrome})`);
  return out;
}

function join(parts: string[]): string {
  if (parts.length === 0) return "0px";
  if (parts.length === 1 && !parts[0].includes("var(")) return parts[0];
  return `calc(${parts.join(" + ")})`;
}

/** A SIZE on screen (width, height, font-size): no camera translation. */
export function lenCss(l: Len): string {
  return join(terms(l));
}

/** A screen COORDINATE along one axis: adds the camera translation. */
export function coordCss(axis: "x" | "y", l: Len): string {
  return join(terms(l, axis === "x" ? CAMERA_CSS_VAR.x : CAMERA_CSS_VAR.y));
}

/** Position an element anchored at `left: 0; top: 0` — compositor-only. */
export function worldTranslate(x: Len, y: Len): string {
  return `translate(${coordCss("x", x)}, ${coordCss("y", y)})`;
}

export function maxCss(a: string, b: string): string {
  return `max(${a}, ${b})`;
}
```

- [ ] **Step 4: Run the tests**

Run: `cd web && bun test src/lib/canvas/worldOverlay.test.ts`
Expected: PASS (all). If `lenCss({ world: 2 })` differs only in whitespace, fix the implementation, not the test.

- [ ] **Step 5: Gates + commit**

```bash
cd web
bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -c "error TS"   # ≤ 933
bunx eslint --fix src/lib/canvas/worldOverlay.ts src/lib/canvas/worldOverlay.test.ts
git add src/lib/canvas/worldOverlay.ts src/lib/canvas/worldOverlay.test.ts
git commit -m "feat(web): world-overlay CSS helpers — camera variables + calc/translate (world overlay P1)"
```

---

### Task 3: Bind the variables to an element; wire KV's overlay layer

**Files:**
- Create: `web/src/lib/canvas/cameraCssVars.ts` (framework-free binder + React hook)
- Create: `web/src/lib/canvas/cameraCssVars.test.ts`
- Modify: `web/src/components/studio/kv-generator/fabric/useCanvasCamera.ts` (return the store)
- Modify: `web/src/components/studio/kv-generator/KvFabricCanvas.tsx` (ref + hook on the DOM overlay layer)

**Interfaces:**
- Consumes: `CameraStore` (Task 1), `cameraCssVars` (Task 2).
- Produces: `bindCameraCssVars(el: { style: { setProperty(name: string, value: string): void } }, store: Pick<CameraStore, "get" | "subscribe">, opts?: { chromeScale?: (s: number) => number }): () => void`; `useCameraCssVars(ref: React.RefObject<HTMLElement | null>, store: CameraStore | null, opts?: { chromeScale?: (s: number) => number }): void`; `useCanvasCamera` now also returns `cameraStore: KvCameraStore`.

- [ ] **Step 1: Write the failing test** — `web/src/lib/canvas/cameraCssVars.test.ts`

```ts
import { describe, it, expect } from "bun:test";
import { bindCameraCssVars } from "./cameraCssVars";
import { createCameraStore, type Camera } from "./cameraStore";

function fakeEl() {
  const props: Record<string, string> = {};
  return {
    props,
    style: {
      setProperty: (n: string, v: string) => {
        props[n] = v;
      },
    },
  };
}
function store(initial: Camera) {
  return createCameraStore({
    cameraRef: { current: initial },
    applyToEngine: () => {},
    commit: () => {},
    raf: () => 1,
    caf: () => {},
  });
}

describe("bindCameraCssVars", () => {
  it("writes the current camera immediately on bind (first paint)", () => {
    const el = fakeEl();
    bindCameraCssVars(el, store({ scale: 0.5, x: 3, y: 4 }));
    expect(el.props["--cam-s"]).toBe("0.5");
    expect(el.props["--cam-x"]).toBe("3px");
    expect(el.props["--cam-y"]).toBe("4px");
  });
  it("rewrites synchronously on every live camera move", () => {
    const el = fakeEl();
    const s = store({ scale: 1, x: 0, y: 0 });
    bindCameraCssVars(el, s);
    s.setLive({ scale: 1, x: 250, y: -10 });
    expect(el.props["--cam-x"]).toBe("250px");
    expect(el.props["--cam-y"]).toBe("-10px");
  });
  it("passes the surface's chrome clamp through", () => {
    const el = fakeEl();
    bindCameraCssVars(el, store({ scale: 0.3, x: 0, y: 0 }), {
      chromeScale: () => 0.6,
    });
    expect(el.props["--cam-cs"]).toBe("0.6");
  });
  it("stops writing after unbind (doc / mode switch)", () => {
    const el = fakeEl();
    const s = store({ scale: 1, x: 0, y: 0 });
    const unbind = bindCameraCssVars(el, s);
    unbind();
    s.setLive({ scale: 1, x: 999, y: 0 });
    expect(el.props["--cam-x"]).toBe("0px");
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd web && bun test src/lib/canvas/cameraCssVars.test.ts`
Expected: FAIL — `Cannot find module './cameraCssVars'`.

- [ ] **Step 3: Implement** — `web/src/lib/canvas/cameraCssVars.ts`

```ts
import { useLayoutEffect } from "react";
import type { CameraStore } from "./cameraStore";
import { cameraCssVars } from "./worldOverlay";

type StyleTarget = {
  style: { setProperty: (name: string, value: string) => void };
};
type Opts = { chromeScale?: (scale: number) => number };

/**
 * Write the camera CSS variables onto `el` now and on every camera change —
 * synchronously, in the same event that moves the canvas — so world-overlay
 * chrome (worldOverlay.ts) never waits on a React render. Returns unbind.
 */
export function bindCameraCssVars(
  el: StyleTarget,
  store: Pick<CameraStore, "get" | "subscribe">,
  opts: Opts = {}
): () => void {
  const write = () => {
    const vars = cameraCssVars(store.get(), opts);
    for (const [name, value] of Object.entries(vars)) {
      el.style.setProperty(name, value);
    }
  };
  write();
  return store.subscribe(write);
}

/** React binding: (re)binds when the element or the store changes. The
 *  layout effect runs before paint, so the first frame is positioned. */
export function useCameraCssVars(
  ref: React.RefObject<HTMLElement | null>,
  store: CameraStore | null,
  opts: Opts = {}
): void {
  const { chromeScale } = opts;
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el || !store) return;
    return bindCameraCssVars(el, store, { chromeScale });
  }, [ref, store, chromeScale]);
}
```

- [ ] **Step 4: Run the tests**

Run: `cd web && bun test src/lib/canvas/cameraCssVars.test.ts`
Expected: PASS (4).

- [ ] **Step 5: Return the store from `useCanvasCamera`** — in `web/src/components/studio/kv-generator/fabric/useCanvasCamera.ts`, change the last line

```ts
  return { camera, setCamera, setCameraLive, cameraRef };
```

to

```ts
  return { camera, setCamera, setCameraLive, cameraRef, cameraStore };
```

- [ ] **Step 6: Bind the overlay layer** — in `web/src/components/studio/kv-generator/KvFabricCanvas.tsx`:

(a) destructure the store (the existing line ~557):

```ts
  const { camera, setCamera, setCameraLive, cameraRef, cameraStore } =
    useCanvasCamera({
```

(b) add, next to the other refs near the top of the component body:

```ts
  // World overlay (docs/adr/0005): the DOM chrome layer carries the camera
  // as CSS variables, rewritten in the same event that moves Fabric.
  const worldLayerRef = useRef<HTMLDivElement | null>(null);
  useCameraCssVars(worldLayerRef, cameraStore, { chromeScale });
```

with imports `import { useCameraCssVars } from "@/lib/canvas/cameraCssVars";` and `import { chromeScale } from "./chromeScale";` (skip the second if already imported).

(c) put the ref on the DOM overlay layer that wraps `<BoardChrome>` (the `div` right after the comment `{/* DOM overlay layer — board labels, the "+" affordance, and live`):

```tsx
      <div
        ref={worldLayerRef}
        className="pointer-events-none absolute inset-0 overflow-hidden"
      >
```

- [ ] **Step 7: Gates + commit**

```bash
cd web
bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -c "error TS"   # ≤ 933
bunx eslint --fix src/lib/canvas/cameraCssVars.ts src/lib/canvas/cameraCssVars.test.ts src/components/studio/kv-generator/fabric/useCanvasCamera.ts src/components/studio/kv-generator/KvFabricCanvas.tsx
bun test src/lib/canvas/cameraStore.test.ts src/lib/canvas/worldOverlay.test.ts src/lib/canvas/cameraCssVars.test.ts src/components/studio/kv-generator/kvCameraStore.test.ts
git add src/lib/canvas/cameraCssVars.ts src/lib/canvas/cameraCssVars.test.ts src/components/studio/kv-generator/fabric/useCanvasCamera.ts src/components/studio/kv-generator/KvFabricCanvas.tsx
git commit -m "feat(web): bind camera CSS variables to KV's DOM overlay layer (world overlay P1)"
```

Expected: tsc unchanged, eslint no new warning (KvFabricCanvas keeps its single pre-existing `selectedOverlayId` warning), tests PASS. Nothing visible changes yet — no element reads the variables.

---

### Task 4: `BoardChrome` in world coordinates

**Files:**
- Modify: `web/src/components/studio/kv-generator/fabric/BoardChrome.tsx`
- Modify: `web/src/components/studio/kv-generator/KvFabricCanvas.tsx` (pass `worldRectOf`, drop `screenRectOf` + `camera` from `<BoardChrome>`)

**Interfaces:**
- Consumes: `lenCss`, `coordCss`, `worldTranslate`, `maxCss`, `CAMERA_CSS_VAR` (Task 2); the variables are present on the ancestor layer (Task 3).
- Produces: `BoardChromeProps.worldRectOf: (b: Pick<KvSurface, "id" | "center"> | KvPendingBoard, aspect: number) => { x: number; y: number; width: number; height: number }` replaces `screenRectOf` and `camera`.

- [ ] **Step 1: Add `worldRectOf` in `KvFabricCanvas.tsx`**, right above `const screenRectOf = (` (keep `screenRectOf`; transient chrome still uses it):

```ts
  // WORLD rect of a surface / pending slot — what the world overlay
  // (BoardChrome) positions from; the camera is applied by CSS variables.
  // Follows a live board drag like screenRectOf does.
  const worldRectOf = (
    b: Pick<KvSurface, "id" | "center"> | KvPendingBoard,
    aspect: number
  ) =>
    boardWorldRect(
      liveDrag && "id" in b && liveDrag.id === b.id ? liveDrag.center : b.center,
      BOARD_WORLD_WIDTH,
      aspect
    );
```

and in the `<BoardChrome …>` element replace `screenRectOf={screenRectOf}` with `worldRectOf={worldRectOf}` and delete the `camera={camera}` line.

- [ ] **Step 2: Update the props and helpers at the top of `BoardChrome.tsx`**

Replace the `ScreenRect` type, the `screenRectOf` / `camera` props and the `Camera` import with:

```ts
import {
  CAMERA_CSS_VAR,
  coordCss,
  lenCss,
  maxCss,
  worldTranslate,
} from "@/lib/canvas/worldOverlay";

/** World rect of a surface / pending slot (board units, not screen px). */
type WorldRect = { x: number; y: number; width: number; height: number };
```

```ts
  worldRectOf: (
    b: Pick<KvSurface, "id" | "center"> | KvPendingBoard,
    aspect: number
  ) => WorldRect;
```

(remove `camera: Camera;` from the props type and `screenRectOf, camera,` from the destructuring; add `worldRectOf,`). Delete the `import { chromeScale } from "../chromeScale";` import — the clamp now arrives as `--cam-cs`.

Add below the imports:

```ts
/** Anchor for every world-positioned element: the transform does the rest. */
const AT_ORIGIN = { left: 0, top: 0 } as const;
const CAPTION_TEXT = {
  fontSize: lenCss({ chrome: 14 }),
  lineHeight: lenCss({ chrome: 18 }),
};
```

- [ ] **Step 3: Rewrite the per-surface projections.** In the `effectiveSurfaces.map` body replace

```ts
        const sr = screenRectOf(surface, aspectOf(surface));
        const boardLabel = surface.label;
        // Captions shrink with the zoom (clamped) so they never outgrow the
        // board they name — see chromeScale.ts.
        const cs = chromeScale(camera.scale);
        const captionStyle = {
          fontSize: `${14 * cs}px`,
          lineHeight: `${18 * cs}px`,
        };
```

with

```ts
        const wr = worldRectOf(surface, aspectOf(surface));
        const boardLabel = surface.label;
        // Captions shrink with the zoom (clamped, `--cam-cs`) so they never
        // outgrow the board they name — see chromeScale.ts. Position is a
        // world-space translate driven by the camera variables.
        const captionAt = worldTranslate(
          { world: wr.x },
          { world: wr.y, chrome: -22 }
        );
```

- [ ] **Step 4: Tile caption** — its `style` becomes

```tsx
              style={{
                ...AT_ORIGIN,
                transform: captionAt,
                // Leave the tile header's icons (history + download, the
                // strip's DOM layer) their own room at the right.
                width: maxCss(lenCss({ world: wr.width, chrome: -64 }), "64px"),
                color: "#ffffff",
                ...CAPTION_TEXT,
              }}
```

- [ ] **Step 5: Board label** — its `style` becomes

```tsx
              style={{
                ...AT_ORIGIN,
                transform: captionAt,
                ...CAPTION_TEXT,
                width: maxCss(lenCss({ world: wr.width }), "64px"),
                color:
                  board.id === pinnedGenerationId
                    ? BOARD_FRAME_ACTIVE
                    : "rgba(255,255,255,0.6)",
              }}
```

- [ ] **Step 6: Ready-chip row.** Replace

```ts
        const readyChipTop = readyChipNeedsOwnRow(boardLabel, BOARD_WORLD_WIDTH)
          ? sr.y - 24
          : sr.y - 4;
```

with

```ts
        // Bottom-right corner of the chip sits at the board's top-right,
        // 4px above it (level with the name) or 24px (its own row).
        const readyChipAt = `${worldTranslate(
          { world: wr.x + wr.width },
          {
            world: wr.y,
            px: readyChipNeedsOwnRow(boardLabel, BOARD_WORLD_WIDTH) ? -24 : -4,
          }
        )} translate(-100%, -100%) scale(var(${CAMERA_CSS_VAR.scaleMax1}))`;
```

and in BOTH ready-chip buttons replace the four lines `left: sr.x + sr.width,` / `top: readyChipTop,` / `transformOrigin: "100% 100%",` / ``transform: `translate(-100%, -100%) scale(${Math.min(1, camera.scale)})`,`` with

```tsx
                    ...AT_ORIGIN,
                    transformOrigin: "100% 100%",
                    transform: readyChipAt,
```

(keep the long explanatory comment above the first one; update its `sr.y - 4 / sr.y - 24` wording to "4px / 24px above the board").

- [ ] **Step 7: Concept badge, crafting overlay, "+" button, rationale card**

Concept badge style:

```tsx
                style={{
                  ...AT_ORIGIN,
                  transform: worldTranslate(
                    { world: wr.x, px: 8 },
                    { world: wr.y, px: 8 }
                  ),
                  background: "rgba(124,92,255,0.85)",
                  boxShadow: "0 1px 6px rgba(0,0,0,0.35)",
                }}
```

Crafting overlay: replace `left: sr.x, top: sr.y, width: sr.width, height: sr.height,` with

```tsx
                  ...AT_ORIGIN,
                  transform: worldTranslate({ world: wr.x }, { world: wr.y }),
                  width: lenCss({ world: wr.width }),
                  height: lenCss({ world: wr.height }),
```

"+" button style:

```tsx
                style={{
                  ...AT_ORIGIN,
                  transform: worldTranslate(
                    { world: wr.x + wr.width, px: 10 },
                    { world: wr.y + wr.height / 2, px: -18 }
                  ),
                }}
```

Rationale card style:

```tsx
                    style={{
                      ...AT_ORIGIN,
                      transform: worldTranslate(
                        { world: wr.x },
                        { world: wr.y + wr.height, px: 12 }
                      ),
                      width: lenCss({ world: wr.width }),
                    }}
```

- [ ] **Step 8: Pending placeholders** — replace `const sr = screenRectOf(pb, aspect);` with `const wr = worldRectOf(pb, aspect);` and its outer style with

```tsx
            style={{
              ...AT_ORIGIN,
              transform: worldTranslate({ world: wr.x }, { world: wr.y }),
              width: lenCss({ world: wr.width }),
              height: lenCss({ world: wr.height }),
            }}
```

- [ ] **Step 9: Update the component docblock** — the sentence "Everything tracks pan/zoom through `screenRectOf`, which projects with the shared camera." becomes "Everything is positioned in WORLD coordinates (`worldRectOf`) and moved by the camera CSS variables the parent layer carries (src/lib/canvas/worldOverlay.ts, docs/adr/0005), so it moves in the same event as the canvas instead of a render later."

- [ ] **Step 10: Verify nothing still reads screen rects or camera state in BoardChrome**

Run: `cd web && grep -n "screenRectOf\|camera\.\|sr\.\|chromeScale(" src/components/studio/kv-generator/fabric/BoardChrome.tsx`
Expected: no matches except inside `BoardNameInput` (below `export function BoardNameInput`), which is out of scope.

- [ ] **Step 11: Gates + commit**

```bash
cd web
bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -c "error TS"   # ≤ 933
bunx eslint --fix src/components/studio/kv-generator/fabric/BoardChrome.tsx src/components/studio/kv-generator/KvFabricCanvas.tsx
find src/lib/canvas -name "*.test.ts" -print0 | xargs -0 bun test
git add src/components/studio/kv-generator/fabric/BoardChrome.tsx src/components/studio/kv-generator/KvFabricCanvas.tsx
git commit -m "feat(web): board chrome rides the camera CSS variables — no trailing labels on pan/zoom (world overlay P1)"
```

---

### Task 5: ADR 0005, build, documents

**Files:**
- Create: `web/docs/adr/0005-canvas-layering.md`
- Modify: `web/docs/adr/README.md` (index line)
- Modify: `web/docs/tracks/kv-craft-resize-strip.track.md` (session-log entry)

- [ ] **Step 1: Write the ADR** — `web/docs/adr/0005-canvas-layering.md`

```markdown
# 0005 — Canvas layering: engine pixels, world overlay, screen overlay

- **Status:** Accepted
- **Date:** 2026-09-24

## Context

More features are being built on canvases (KV Craft, Motion, the runner
board, decks). DOM chrome over the KV Fabric canvas — captions, tile header
icons, the Resizes divider, comment pins — was positioned from React state
that commits at most once per animation frame, and some of it from screen
rects published in an effect after that. During pan/zoom the chrome trailed
the canvas pixels and snapped into place when the gesture stopped; the
layout re-rendered every frame of a gesture.

## Decision

Every canvas surface is built from four layers:

1. **Content** — the engine's pixels (Fabric, Konva, WebGL). Moved by the
   camera directly.
2. **World overlay** — DOM chrome attached to content (labels, badges,
   header icons, pins). Positioned in WORLD coordinates with the helpers in
   `src/lib/canvas/worldOverlay.ts`, moved by the camera CSS variables that
   `bindCameraCssVars` / `useCameraCssVars` (`src/lib/canvas/cameraCssVars.ts`)
   write in the same event as the engine. Never positioned from React camera
   state.
3. **Screen overlay** — menus, popovers, toolbars. Anchored to a world point
   through the camera store (`subscribe`), not by capturing a screen point
   once.
4. **Interaction** — one tool/pointer system per surface.

High-frequency view state (camera, drag, hover) lives in stores with a
synchronous `subscribe` (`src/lib/canvas/cameraStore.ts`), outside React
state. Documents stay in world units; screen coordinates exist only at the
edges.

## Consequences

- Chrome moves with the pixels at any zoom; gestures stop re-rendering React
  trees for positioning.
- Positions in DevTools read as `calc()` / `translate()` expressions rather
  than pixel numbers.
- Transient chrome (selection, drag guides, prompt popovers) may still read
  React camera state until migrated; new chrome must not.
- Each surface passes its own chrome rules (e.g. KV's `chromeScale`) as
  options — the foundation shares the math, not the numbers (same stance as
  `src/lib/canvas/viewport.ts`).
- Engine unification (Konva vs Fabric) and adopting a canvas SDK are separate
  decisions, not covered here.
```

- [ ] **Step 2: Index line** — append to the `## Index` list in `web/docs/adr/README.md`:

```markdown
- [0005 — Canvas layering: engine pixels, world overlay, screen overlay](./0005-canvas-layering.md)
```

- [ ] **Step 3: Build**

Run: `cd web && node ./node_modules/next/dist/bin/next build`
Expected: exit 0.

- [ ] **Step 4: Track entry** — append to `web/docs/tracks/kv-craft-resize-strip.track.md`:

```markdown
### 2026-09-24 — daffa (with Claude) — world overlay P1 (foundation + board chrome)
- Spec `docs/superpowers/specs/2026-09-24-kv-canvas-world-overlay-design.md`, plan
  `docs/superpowers/plans/2026-09-24-canvas-world-overlay-p1.md` (workspace repo); ADR `docs/adr/0005`.
- `src/lib/canvas/{cameraStore,worldOverlay,cameraCssVars}.ts`: shared camera store with a synchronous
  `subscribe`, camera CSS variables, world→CSS helpers. KV's store is a thin wrapper.
- BoardChrome (board labels, tile captions, Concept badge, ready chips, "+", rationale card, crafting
  overlay, pending placeholders) positioned in world coords, moved by `--cam-*` — no trailing on pan/zoom.
- Manual (Daffa): pan + pinch fast over boards and tiles — captions/chips/"+" stay welded; caption
  click, double-click rename, label drag, ready-chip toggle, "+" all work; rename input lines up with
  its caption after a pan. Still trailing until P2/P3: tile header icons, Resizes divider, comment pins.
```

- [ ] **Step 5: Commit**

```bash
cd web
git add docs/adr/0005-canvas-layering.md docs/adr/README.md docs/tracks/kv-craft-resize-strip.track.md
git commit -m "docs(web): ADR 0005 canvas layering + world overlay P1 track entry"
```

---

## Self-review against the spec

- Spec §Approach 1 (store + `subscribe`) → Task 1. §2 (CSS variables, written on mount) → Tasks 2–3. §3 (world-positioned elements, `transform: translate`, clamped chrome via `--cam-cs`) → Tasks 2 and 4. §4 (world rects across boundaries, `onCameraStoreChange`) → P2/P3 plans (no cross-component consumer in P1; BoardChrome is inside KvFabricCanvas).
- §Shared module: `cameraStore.ts` (Task 1), `worldOverlay.ts` (Task 2), `useCameraCssVars` (Task 3, in `cameraCssVars.ts` alongside the framework-free binder so the binder is testable without React), `screenAnchor.ts` → P3 plan, as the spec says.
- §ADR → Task 5. §P1 row: foundation + BoardChrome items → Tasks 1–4; the crafting overlay and pending placeholders are included because they are rendered by the same component with the same rect (keeping one projection per component).
- §Invariants: React `camera` state untouched (Task 3 only adds); label drag keeps `cameraRef` (unchanged); `BoardNameInput` stays on `screenRectOf` (Review Focus).
- Deviation, recorded here: the ≤1 clamp variable is named `--cam-s-max1` instead of the spec's `--cam-cs-ready` (surface-agnostic naming).
