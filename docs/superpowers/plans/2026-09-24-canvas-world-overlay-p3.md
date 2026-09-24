# Canvas World Overlay — P3 (comment pins + thread popover) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Comment pins (placed, draft) and the open thread / draft popover stay glued to their spot through pan and zoom, and a pan/zoom gesture no longer re-renders `KvGeneratorLayout` every frame.

**Architecture:** The canvas publishes board/tile **world** rects (only when surfaces change) and the active board's world rect instead of per-frame screen rects; `KvCanvas` forwards them plus the camera store to the layout. `CommentPinOverlay` gains an opt-in world mode (binds the `--cam-*` variables on its root, positions pins from world rects); `CommentThreadPopover` gains an opt-in world anchor that repositions itself imperatively from the store (`src/lib/canvas/screenAnchor.ts`). The bottom-nav zoom % reads the store directly. The layout stops receiving `onBoardRectsChange` / `onImageRectChange` / `onZoomScaleChange`.

**Tech Stack:** Next.js 16 / React 19 / TypeScript, Fabric v7, bun test.

**Spec:** `docs/superpowers/specs/2026-09-24-kv-canvas-world-overlay-design.md` (workspace repo) — P3 row, §Approach 4, success criterion "the layout does not re-render per frame". Builds on P1/P2 (`src/lib/canvas/{cameraStore,worldOverlay,cameraCssVars,evalCameraCss}.ts`; `KvFabricCanvas` `onCameraStoreChange`; `KvCanvas` `cameraStore` state).

## Global Constraints

- `web/`, branch `feature/daffa/vc-kv-craft-resize-strip`. Commit per task. **Do not push** unless Daffa asks. Never `git stash`.
- Gates per task: tsc total **≤ 933**; `bunx eslint --fix <touched>` adds no warning; `bun test <explicit files>`; `node ./node_modules/next/dist/bin/next build` exit 0 at the end of Task 5.
- Pure tests only; no RTL/component tests.
- `CommentPinOverlay` and `CommentThreadPopover` are shared (`AnchoredComments`, `CommentVersionModal`): the world mode is **opt-in**; every existing call site keeps working unchanged (screen `partRect` / `at`).
- Pin geometry preserved exactly: badge bottom-left on the anchor point, height `PIN_SIZE` (28) or `PIN_SIZE_RESOLVED` (20), width `pinWidth(participants, resolved)`; popover opens right of the badge (`GAP` 10), flips left when it would overflow, top-aligned to the badge, clamped `EDGE` 8 inside the viewport.
- Pins are `position: fixed` in viewport space; canvas-local world→screen equals viewport space because the canvas box sits at viewport (0,0) (spec §Coordinate space). Keep relying on it.

## Review Focus

- **Anchor whose surface is gone** (board deleted, tile removed): today it falls back to the active board's rect; world mode must fall back to the active board's WORLD rect, and draw nothing when there is none. (Task 1 test on `worldRectForCommentPart`; Task 4 fallback.)
- **Popover flip/clamp while panning:** a pin panned to the right edge must flip the card left, and near the bottom it must clamp — recomputed on every camera event, not only on mount. (Task 1 tests on `placeBesideAnchor`.)
- **Other hosts** (`AnchoredComments`, `CommentVersionModal`) pass screen rects only: they must render exactly as before. (Type check + unchanged code paths; manual smoke of a non-KV comment surface.)
- **Store not yet published / canvas remount:** the layout gets `null` then a store; pins render in world mode only with a store, else not at all (no pins at 0,0). (Task 3 `ready` gating.)
- **Zoom % label:** still updates live during a pinch though the layout no longer re-renders. (Task 4 — the pill subscribes to the store.)

---

### Task 1: Pure geometry — pin world style, popover placement, world part lookup

**Files:**
- Create: `web/src/components/comments/pinGeometry.ts`
- Create: `web/src/components/comments/pinGeometry.test.ts`
- Modify: `web/src/components/comments/CommentPinOverlay.tsx` (import + re-export the moved helpers)
- Create: `web/src/lib/canvas/screenAnchor.ts`
- Create: `web/src/lib/canvas/screenAnchor.test.ts`
- Modify: `web/src/lib/studio/kv/commentPartRect.ts` (+ `worldRectForCommentPart`)
- Modify: `web/src/lib/studio/kv/commentPartRect.test.ts`

**Interfaces:**
- Produces:
  - `pinGeometry.ts`: `PIN_SIZE`, `PIN_SIZE_RESOLVED`, `PIN_MAX_FACES`, `pinWidth(count, resolved?)`, `pinBadgeRect(x, y, rect, resolved?, count?)` (moved verbatim), plus `type WorldRect = { x: number; y: number; width: number; height: number }`, `pinBadgeWorldAnchor(x: number, y: number, wr: WorldRect, resolved?: boolean, count?: number): { anchorX: number; anchorY: number; width: number; height: number }` (world anchor + px badge size) and `pinBadgeWorldStyle(x, y, wr, resolved?, count?): React.CSSProperties`.
  - `screenAnchor.ts`: `type WorldBadge = { anchorX: number; anchorY: number; width: number; height: number }`; `worldBadgeToScreen(b: WorldBadge, cam: Camera): { left: number; top: number; width: number; height: number }`; `placeBesideAnchor(at, size: { width: number; height: number }, viewport: { width: number; height: number }, opts?: { gap?: number; edge?: number }): { left: number; top: number }`.
  - `commentPartRect.ts`: `worldRectForCommentPart(part: string | null | undefined, rects: Record<string, WorldRect>): WorldRect | null`.
  - `CommentPinOverlay.tsx` keeps exporting `PIN_SIZE`, `PIN_SIZE_RESOLVED`, `PIN_MAX_FACES`, `pinWidth`, `pinBadgeRect` (re-exported) — no importer changes.

- [ ] **Step 1: Failing tests** — `web/src/components/comments/pinGeometry.test.ts`

```ts
import { describe, it, expect } from "bun:test";
import { cameraCssVars } from "@/lib/canvas/worldOverlay";
import { evalCssLength, evalTranslate } from "@/lib/canvas/evalCameraCss";
import {
  PIN_SIZE,
  PIN_SIZE_RESOLVED,
  pinBadgeRect,
  pinBadgeWorldAnchor,
  pinBadgeWorldStyle,
  pinWidth,
} from "./pinGeometry";

const wr = { x: 100, y: 200, width: 512, height: 910 };
const cams = [
  { scale: 1, x: 0, y: 0 },
  { scale: 0.38, x: -412.5, y: 96 },
  { scale: 2.2, x: 900, y: -640 },
];
const toScreen = (c: { scale: number; x: number; y: number }) => ({
  left: wr.x * c.scale + c.x,
  top: wr.y * c.scale + c.y,
  width: wr.width * c.scale,
  height: wr.height * c.scale,
});

describe("pinBadgeWorldStyle — parity with pinBadgeRect", () => {
  for (const c of cams) {
    it(`at scale ${c.scale}`, () => {
      const vars = cameraCssVars(c);
      const old = pinBadgeRect(0.25, 0.6, toScreen(c), false, 3);
      const s = pinBadgeWorldStyle(0.25, 0.6, wr, false, 3);
      const at = evalTranslate(String(s.transform), vars);
      expect(at.x).toBeCloseTo(old.left);
      expect(at.y).toBeCloseTo(old.top);
      expect(s.width).toBe(old.width);
      expect(s.height).toBe(old.height);
    });
  }
  it("resolved pins use the small size", () => {
    const s = pinBadgeWorldStyle(0, 0, wr, true, 5);
    expect(s.width).toBe(PIN_SIZE_RESOLVED);
    expect(s.height).toBe(PIN_SIZE_RESOLVED);
  });
});

describe("pinBadgeWorldAnchor", () => {
  it("anchors the badge's bottom-left on the world point, px size", () => {
    expect(pinBadgeWorldAnchor(0.5, 0.5, wr, false, 1)).toEqual({
      anchorX: 100 + 256,
      anchorY: 200 + 455,
      width: pinWidth(1),
      height: PIN_SIZE,
    });
  });
  it("world style width/height are fixed px (never scaled)", () => {
    const vars = cameraCssVars({ scale: 3, x: 0, y: 0 });
    const s = pinBadgeWorldStyle(0, 0, wr);
    expect(evalCssLength(String(s.width) + "px", vars)).toBe(PIN_SIZE);
  });
});
```

`web/src/lib/canvas/screenAnchor.test.ts`

```ts
import { describe, it, expect } from "bun:test";
import { placeBesideAnchor, worldBadgeToScreen } from "./screenAnchor";

describe("worldBadgeToScreen", () => {
  it("projects the anchor, hangs the badge above it, keeps px size", () => {
    expect(
      worldBadgeToScreen(
        { anchorX: 100, anchorY: 50, width: 52, height: 28 },
        { scale: 2, x: 10, y: -5 }
      )
    ).toEqual({ left: 210, top: 95 - 28, width: 52, height: 28 });
  });
});

describe("placeBesideAnchor", () => {
  const vp = { width: 1200, height: 800 };
  const size = { width: 320, height: 300 };
  it("opens right of the badge, top-aligned", () => {
    expect(
      placeBesideAnchor({ left: 100, top: 200, width: 28, height: 28 }, size, vp)
    ).toEqual({ left: 138, top: 200 });
  });
  it("flips left when the card would run off the right edge", () => {
    expect(
      placeBesideAnchor({ left: 1000, top: 200, width: 28, height: 28 }, size, vp)
    ).toEqual({ left: 1000 - 10 - 320, top: 200 });
  });
  it("clamps inside the viewport near the bottom and top", () => {
    expect(
      placeBesideAnchor({ left: 100, top: 700, width: 28, height: 28 }, size, vp)
        .top
    ).toBe(800 - 300 - 8);
    expect(
      placeBesideAnchor({ left: 100, top: -50, width: 28, height: 28 }, size, vp)
        .top
    ).toBe(8);
  });
});
```

Append to `web/src/lib/studio/kv/commentPartRect.test.ts`:

```ts
import { worldRectForCommentPart } from "./commentPartRect";

describe("worldRectForCommentPart", () => {
  const rects = {
    b1: { x: 0, y: 0, width: 512, height: 512 },
    t1: { x: 0, y: 700, width: 512, height: 910 },
  };
  it("resolves board and tile parts from one world map", () => {
    expect(worldRectForCommentPart("board.b1", rects)).toEqual(rects.b1);
    expect(worldRectForCommentPart("tile.t1", rects)).toEqual(rects.t1);
  });
  it("is null for a gone surface or no part", () => {
    expect(worldRectForCommentPart("board.gone", rects)).toBeNull();
    expect(worldRectForCommentPart(null, rects)).toBeNull();
  });
});
```

- [ ] **Step 2: Run → FAIL** — `cd web && bun test src/components/comments/pinGeometry.test.ts src/lib/canvas/screenAnchor.test.ts src/lib/studio/kv/commentPartRect.test.ts` → module / export not found.

- [ ] **Step 3: `pinGeometry.ts`** — move `PIN_SIZE`, `PIN_SIZE_RESOLVED`, `PIN_MAX_FACES`, `PIN_STACK_STEP`, `pinWidth` and `pinBadgeRect` (with their doc comments, VERBATIM) out of `CommentPinOverlay.tsx` into `web/src/components/comments/pinGeometry.ts`, then append:

```ts
import type React from "react";
import { worldTranslate } from "@/lib/canvas/worldOverlay";

/** World rect of the part a pin hangs on (board / tile units). */
export type WorldRect = { x: number; y: number; width: number; height: number };

/**
 * World-mode twin of `pinBadgeRect`: the anchor as a WORLD point, the badge
 * size in fixed px. The badge hangs above the anchor (bottom-left on it), so
 * its top is the projected anchor minus its px height — see worldBadgeToScreen
 * (src/lib/canvas/screenAnchor.ts) for the popover's use of the same numbers.
 */
export function pinBadgeWorldAnchor(
  x: number,
  y: number,
  wr: WorldRect,
  resolved = false,
  participantCount = 1
) {
  return {
    anchorX: wr.x + x * wr.width,
    anchorY: wr.y + y * wr.height,
    width: pinWidth(participantCount, resolved),
    height: resolved ? PIN_SIZE_RESOLVED : PIN_SIZE,
  };
}

/** Style for a badge positioned by the camera CSS variables (world overlay,
 *  docs/adr/0005): anchored at left:0/top:0, moved by a translate. */
export function pinBadgeWorldStyle(
  x: number,
  y: number,
  wr: WorldRect,
  resolved = false,
  participantCount = 1
): React.CSSProperties {
  const b = pinBadgeWorldAnchor(x, y, wr, resolved, participantCount);
  return {
    left: 0,
    top: 0,
    transform: worldTranslate(
      { world: b.anchorX },
      { world: b.anchorY, px: -b.height }
    ),
    width: b.width,
    height: b.height,
  };
}
```

(Put the two imports at the top of the file.) In `CommentPinOverlay.tsx`, delete the moved code and add:

```ts
import {
  PIN_MAX_FACES,
  pinBadgeRect,
  pinWidth,
} from "./pinGeometry";
export {
  PIN_SIZE,
  PIN_SIZE_RESOLVED,
  PIN_MAX_FACES,
  pinWidth,
  pinBadgeRect,
} from "./pinGeometry";
```

(keep only the imports the file still uses — tsc/eslint will tell).

- [ ] **Step 4: `screenAnchor.ts`** — `web/src/lib/canvas/screenAnchor.ts`

```ts
import type { Camera } from "./cameraStore";

/**
 * Screen-overlay anchoring (docs/adr/0005 layer 3): a popover that hangs off
 * a WORLD point recomputes its screen position from the camera store on every
 * camera change, instead of capturing a screen point once. Pure math here;
 * the subscription lives with the popover.
 */
export type WorldBadge = {
  /** World point the badge's bottom-left sits on. */
  anchorX: number;
  anchorY: number;
  /** Badge size in fixed px. */
  width: number;
  height: number;
};

export function worldBadgeToScreen(
  b: WorldBadge,
  cam: Camera
): { left: number; top: number; width: number; height: number } {
  const left = b.anchorX * cam.scale + cam.x;
  const anchorTop = b.anchorY * cam.scale + cam.y;
  return { left, top: anchorTop - b.height, width: b.width, height: b.height };
}

/**
 * Card beside an anchor rect: to its RIGHT (clearing its full width), flipped
 * left when that would overflow, top-aligned and clamped inside the viewport.
 * Extracted from CommentThreadPopover so the world-anchored path uses the
 * same rule.
 */
export function placeBesideAnchor(
  at: { left: number; top: number; width: number; height: number },
  size: { width: number; height: number },
  viewport: { width: number; height: number },
  opts: { gap?: number; edge?: number } = {}
): { left: number; top: number } {
  const gap = opts.gap ?? 10;
  const edge = opts.edge ?? 8;
  const wouldOverflow =
    at.left + at.width + gap + size.width > viewport.width - edge;
  const left = wouldOverflow
    ? Math.max(edge, at.left - gap - size.width)
    : at.left + at.width + gap;
  const top = Math.min(
    Math.max(edge, at.top),
    Math.max(edge, viewport.height - size.height - edge)
  );
  return { left, top };
}
```

- [ ] **Step 5: `worldRectForCommentPart`** — append to `web/src/lib/studio/kv/commentPartRect.ts`:

```ts
/** World-space twin of `rectForCommentPart` (world overlay, docs/adr/0005):
 *  the same `board.<id>` / `tile.<exportId>` keys, over world rects that only
 *  change when surfaces move — not on every pan/zoom. */
export function worldRectForCommentPart<
  R extends { x: number; y: number; width: number; height: number },
>(part: string | null | undefined, rects: Record<string, R>): R | null {
  if (!part) return null;
  const id = part.startsWith("board.")
    ? part.slice("board.".length)
    : part.startsWith("tile.")
      ? part.slice("tile.".length)
      : null;
  return id ? (rects[id] ?? null) : null;
}
```

- [ ] **Step 6: Run → PASS** — same command as Step 2, plus `bun test src/components/comments/*.test.ts` files that exist for the overlay (list them with `ls src/components/comments/*.test.ts*` and pass them explicitly).

- [ ] **Step 7: Gates + commit** — tsc ≤ 933; eslint --fix on the seven files; `git commit -m "feat(web): pin world geometry, popover placement and world part lookup (world overlay P3)"`.

---

### Task 2: The canvas publishes world rects; `KvCanvas` forwards them and the store

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvFabricCanvas.tsx`
- Modify: `web/src/components/studio/kv-generator/KvCanvas.tsx`

**Interfaces:**
- Produces: `KvFabricCanvas` props `onBoardWorldRectsChange?: (rects: Record<string, WorldRect>) => void` (every effective surface — boards AND strip tiles — keyed by surface id) and `onActiveWorldRectChange?: (rect: WorldRect | null) => void` (the active host); `KvCanvas` props `onBoardWorldRectsChange`, `onActiveWorldRectChange`, `onCameraStoreChange?: (store: CameraStore | null) => void` (forwarded up, alongside its own `cameraStore` state).

- [ ] **Step 1: Publish in `KvFabricCanvas`.** Add the two props (next to `onBoardRectsChange`) and, next to the existing publishing effect that calls `onBoardRectsChange` (~line 1142–1188), a SEPARATE effect keyed on surfaces, not camera:

```ts
  // World rects of every surface and of the active host — for world-overlay
  // consumers (comment pins, docs/adr/0005). Keyed on the surfaces, NOT the
  // camera: they change when boards/tiles move, never on pan/zoom.
  useEffect(() => {
    if (onBoardWorldRectsChange) {
      const out: Record<string, WorldRect> = {};
      for (const s of effectiveSurfaces) {
        const r = boardWorldRect(
          liveDrag && liveDrag.id === s.id ? liveDrag.center : s.center,
          BOARD_WORLD_WIDTH,
          aspectOf(s)
        );
        out[s.id] = r;
      }
      onBoardWorldRectsChange(out);
    }
    onActiveWorldRectChange?.(activeHostRect);
  }, [
    effectiveSurfaces,
    aspectOf,
    liveDrag,
    activeHostRect,
    onBoardWorldRectsChange,
    onActiveWorldRectChange,
  ]);
```

(`WorldRect` is already exported by `./kvSurface`.)

- [ ] **Step 2: Forward in `KvCanvas`.** Add the three props to the outer `KvCanvas` props type and destructuring; thread `onBoardWorldRectsChange` / `onActiveWorldRectChange` through `CanvasStageFrame` → `canvasProps` exactly like `onBoardRectsChange` is threaded. For the store, replace `onCameraStoreChange={setCameraStore}` with a stable handler:

```ts
  const handleCameraStoreChange = useCallback(
    (store: CameraStore | null) => {
      setCameraStore(store);
      onCameraStoreChange?.(store);
    },
    [onCameraStoreChange]
  );
```

and pass `onCameraStoreChange={handleCameraStoreChange}`.

- [ ] **Step 3: Gates + commit** — tsc ≤ 933; eslint no new warnings; `git commit -m "feat(web): canvas publishes surface world rects + camera store up to the layout (world overlay P3)"`.

---

### Task 3: Opt-in world mode in `CommentPinOverlay` and `CommentThreadPopover`

**Files:**
- Modify: `web/src/components/comments/CommentPinOverlay.tsx`
- Modify: `web/src/components/comments/CommentThreadPopover.tsx`

**Interfaces:**
- Consumes: Task 1 geometry; P1 `useCameraCssVars`, `CameraStore`.
- Produces:
  - `PinOverlayItem.partRect` becomes optional; new optional `partWorldRect?: WorldRect`. `draft` / `preview` accept `partWorldRect` too. New prop `cameraStore?: CameraStore | null`.
  - `CommentThreadPopoverProps.at` becomes optional; new optional `atWorld?: WorldBadge` + `cameraStore?: CameraStore | null`. Exactly one of `at` / (`atWorld` + `cameraStore`) is used.

- [ ] **Step 1: Pin overlay.** In `CommentPinOverlay.tsx`:
  - `PinOverlayItem`: `partRect?: {…}` (optional) and `partWorldRect?: WorldRect`; same two fields on the `draft` and `preview` prop shapes.
  - Props: `cameraStore?: CameraStore | null`.
  - Body: `const rootRef = useRef<HTMLDivElement | null>(null); useCameraCssVars(rootRef, cameraStore ?? null);` and put `ref={rootRef}` on the root `div` (always rendered already).
  - A single style chooser used for items, draft and preview:

```ts
function badgeStyle(
  p: { x: number; y: number; partRect?: ScreenRectLike; partWorldRect?: WorldRect },
  worldReady: boolean,
  resolved = false,
  participantCount = 1
): React.CSSProperties | null {
  if (p.partWorldRect) {
    // World mode: moved by the camera variables on the root — only once a
    // store has bound them, or the badge would sit at the origin.
    return worldReady
      ? pinBadgeWorldStyle(p.x, p.y, p.partWorldRect, resolved, participantCount)
      : null;
  }
  if (p.partRect) {
    return positionStyle(p.x, p.y, p.partRect, resolved, participantCount);
  }
  return null;
}
```

  with `type ScreenRectLike = { left: number; top: number; width: number; height: number }` and `const worldReady = !!cameraStore;`. Render an item / draft / preview only when `badgeStyle(...)` is non-null, and use it as `style`.

- [ ] **Step 2: Popover.** In `CommentThreadPopover.tsx`:
  - Props: `at?: {…}`, `atWorld?: WorldBadge`, `cameraStore?: CameraStore | null`.
  - Replace the flip/clamp body of the existing `useLayoutEffect` with `placeBesideAnchor(at, { width: WIDTH, height }, { width: window.innerWidth, height: window.innerHeight }, { gap: GAP, edge: EDGE })` (same numbers), guarded by `if (!at) return;`.
  - Add the world path — imperative, no React state per camera event:

```ts
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el || !atWorld || !cameraStore) return;
    const place = () => {
      const screen = worldBadgeToScreen(atWorld, cameraStore.get());
      const p = placeBesideAnchor(
        screen,
        { width: WIDTH, height: el.offsetHeight },
        { width: window.innerWidth, height: window.innerHeight },
        { gap: GAP, edge: EDGE }
      );
      el.style.left = `${p.left}px`;
      el.style.top = `${p.top}px`;
    };
    place();
    return cameraStore.subscribe(place);
  }, [
    atWorld?.anchorX,
    atWorld?.anchorY,
    atWorld?.width,
    atWorld?.height,
    cameraStore,
    thread?.replies.length,
  ]);
```

  - The root `style` becomes `style={at ? { left: placement.left, top: placement.top, width: WIDTH } : { width: WIDTH }}` so the world path owns `left/top`.

- [ ] **Step 3: Gates + commit** — tsc ≤ 933 (the other hosts still type-check: they pass `partRect` / `at`); eslint; `bun test src/components/comments/pinGeometry.test.ts src/lib/canvas/screenAnchor.test.ts`; `git commit -m "feat(web): opt-in world mode for comment pins and the thread popover (world overlay P3)"`.

---

### Task 4: Layout switches to world rects; the per-frame streams stop

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx`
- Modify: `web/src/components/studio/kv-generator/KvCanvasBottomNav.tsx` (zoom % from the store)

**Interfaces:**
- Consumes: Task 1 `worldRectForCommentPart`, `pinBadgeWorldAnchor`; Task 2 props; Task 3 world props.
- Produces: `KvCanvasBottomNav` `zoom.cameraStore?: CameraStore | null` (the % reads it; `zoom.scale` stays as the fallback for hosts without a store).

- [ ] **Step 1: State.** In the layout replace the `boardRects` and `commentPartRect` state with:

```ts
  // World rects of every canvas surface (boards AND strip tiles) and of the
  // active board — republished only when surfaces move, never on pan/zoom.
  // Pins and the thread popover project them through the camera store
  // (world overlay, docs/adr/0005), so a gesture no longer re-renders this
  // component every frame.
  const [boardWorldRects, setBoardWorldRects] = useState<
    Record<string, { x: number; y: number; width: number; height: number }>
  >({});
  const [activeWorldRect, setActiveWorldRect] = useState<{
    x: number; y: number; width: number; height: number;
  } | null>(null);
  const [canvasCameraStore, setCanvasCameraStore] =
    useState<CameraStore | null>(null);
```

  Keep `setCommentPartRect(null)`'s intent in the canvas-mode effect by calling `setActiveWorldRect(null)`.

- [ ] **Step 2: Consumers.**
  - `visibleCommentThreads`: `boardRects[...]` → `boardWorldRects[...]` (both existence checks) and the deps.
  - `rectForThread` → `worldRectForThread`: `worldRectForCommentPart(commentPartOf(thread.parent.anchor), boardWorldRects) ?? activeWorldRect`.
  - `pinItems`: push `{ thread, x, y, partWorldRect }`.
  - `openThreadRect` → `openThreadWorldRect = openThread ? worldRectForThread(openThread) : null`.
  - `draftRect` → `draftWorldRect = worldRectForCommentPart(draftPart, boardWorldRects) ?? activeWorldRect`.
  - `<CommentPinOverlay>`: add `cameraStore={canvasCameraStore}`; `preview` / `draft` pass `partWorldRect: draftWorldRect`.
  - Draft popover: condition `commentDraft && draftWorldRect`; replace `at={pinBadgeRect(commentDraft.x, commentDraft.y, draftRect)}` with `atWorld={pinBadgeWorldAnchor(commentDraft.x, commentDraft.y, draftWorldRect)}` + `cameraStore={canvasCameraStore}`.
  - Open-thread popover: condition `openThread && openThreadWorldRect && !commentDraft`; `atWorld={pinBadgeWorldAnchor(ax, ay, openThreadWorldRect, resolved, threadParticipants(openThread).length)}` + `cameraStore={canvasCameraStore}`.
  - Any remaining `pinBadgeRect` import that is now unused is removed by eslint.

- [ ] **Step 3: Stop the per-frame streams.** On `<KvCanvas …>` (~lines 7400–7462): remove `onZoomScaleChange={handleZoomScaleChange}`, `onImageRectChange={setCommentPartRect}`, `onBoardRectsChange={setBoardRects}`; add `onBoardWorldRectsChange={setBoardWorldRects}`, `onActiveWorldRectChange={setActiveWorldRect}`, `onCameraStoreChange={setCanvasCameraStore}`. Delete the now-unused `zoomScale` state and `handleZoomScaleChange`. (KvCanvas keeps its OWN local `stripRects`/`stripZoom` from the canvas for the strip's transient chrome — untouched.)

- [ ] **Step 4: Zoom % from the store.** In `KvCanvasBottomNav.tsx` add `cameraStore?: CameraStore | null` to the `zoom` prop type, pass it to `ZoomPill`, and inside `ZoomPill`:

```ts
  // Live from the camera store when there is one (a pinch re-renders only
  // this pill, not the layout); the prop is the fallback.
  const liveScale = useSyncExternalStore(
    (cb) => (cameraStore ? cameraStore.subscribe(cb) : () => {}),
    () => (cameraStore ? cameraStore.get().scale : scale),
    () => scale
  );
```

  and render `{Math.round(liveScale * 100)}%`. In the layout's bottom-nav `zoom={{ … }}` replace `scale: zoomScale,` with `scale: 1, cameraStore: canvasCameraStore,`.

- [ ] **Step 5: Verify the streams are gone**

Run: `cd web && grep -n "onBoardRectsChange\|onImageRectChange\|onZoomScaleChange\|boardRects\b\|commentPartRect\b\|zoomScale" src/components/studio/kv-generator/KvGeneratorLayout.tsx`
Expected: no matches except the `commentPartRect` IMPORT path (`@/lib/studio/kv/commentPartRect`).

- [ ] **Step 6: Gates + commit** — tsc ≤ 933; eslint (layout stays at its 13 baseline warnings; bottom nav 0 new); `bun test` the Task 1 files + `src/components/studio/kv-generator/KvCanvasBottomNav.test.tsx`; `git commit -m "feat(web): comment pins + thread popover ride the camera; layout stops re-rendering per gesture frame (world overlay P3)"`.

---

### Task 5: Build + documents

- [ ] **Step 1:** `cd web && node ./node_modules/next/dist/bin/next build` → exit 0.
- [ ] **Step 2:** Append to `web/docs/tracks/kv-craft-resize-strip.track.md`:

```markdown
### 2026-09-24 — daffa (with Claude) — world overlay P3 (comment pins + thread popover)
- Plan `docs/superpowers/plans/2026-09-24-canvas-world-overlay-p3.md` (workspace repo).
- Canvas publishes surface WORLD rects + active world rect (only when surfaces move) and its camera store;
  the layout no longer receives per-frame `onBoardRectsChange` / `onImageRectChange` / `onZoomScaleChange`.
- CommentPinOverlay / CommentThreadPopover: opt-in world mode (other hosts unchanged); pins moved by `--cam-*`,
  the popover repositions imperatively from the store (`src/lib/canvas/screenAnchor.ts`, flip/clamp kept).
- Bottom-nav zoom % reads the store (`useSyncExternalStore`) — only the pill re-renders during a pinch.
- Manual (Daffa): pan/pinch with pins on boards and tiles and an open thread — all stay welded; the card flips
  at the right edge and clamps at the bottom; placing a pin, replying, resolving still work; zoom % live.
  React DevTools Profiler: KvGeneratorLayout does not commit per frame while panning.
```

- [ ] **Step 3:** `git commit -m "docs(web): world overlay P3 track entry"`.

---

## Self-review against the spec

- P3 row: pins + draft pin → Tasks 1, 3, 4; `CommentThreadPopover` anchor via `screenAnchor.ts` → Tasks 1, 3, 4; layout reads board world rects → Tasks 2, 4; per-frame `onBoardRectsChange` removed from the layout → Task 4 (KvCanvas keeps its own screen rects for the strip's transient chrome, the only remaining consumer, as the spec allows: "removed once unused" applies to the layout path).
- Success criterion "layout does not re-render per frame": the three per-frame streams into the layout (board rects, image rect, zoom scale) all stop in Task 4.
- Types: `WorldRect` (pinGeometry) is structurally identical to `kvSurface`'s; `WorldBadge` (screenAnchor) is what `pinBadgeWorldAnchor` returns; `CameraStore` from `@/lib/canvas/cameraStore` everywhere.
