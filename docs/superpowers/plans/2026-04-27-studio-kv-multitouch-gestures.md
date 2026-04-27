# KV Multi-touch Pinch + Two-Finger Pan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Figma-style two-finger pinch-zoom and two-finger pan to the KV Generator canvas, working in every tool, on touchscreens. Mac trackpad pinch already works via the existing wheel handler — verify in the manual pass. Spec: [`docs/superpowers/specs/2026-04-27-studio-kv-multitouch-gestures-design.md`](../specs/2026-04-27-studio-kv-multitouch-gestures-design.md).

**Architecture:** Pure frontend, web service only. Extract the gesture math (distance, midpoint, pinch transform) into a tiny pure module so it can be unit-tested in isolation, then wire native touch handlers into `KvKonvaCanvas.tsx`. Multi-touch detection short-circuits the existing single-touch handlers when ≥2 fingers are down. State for an in-progress gesture lives in a ref (high-frequency, no React re-render needed).

**Tech Stack:** Next.js 16, React 19, TypeScript, react-konva, Bun test runner. Gesture math is plain TS — no library.

---

## File Structure

**New:**
- `web/src/components/studio/kv-generator/gestureMath.ts` — pure helpers (`distance`, `midpointInContainer`, `computePinchTransform`)
- `web/src/components/studio/kv-generator/gestureMath.test.ts` — unit tests

**Modify:**
- `web/src/components/studio/kv-generator/KvKonvaCanvas.tsx` — add `gestureRef`, three pinch handlers, wire into existing touch entry points

The spec said "no new helper modules" — this plan deliberately deviates by ~30 lines into a `gestureMath.ts` so the pivot-point math can be unit-tested. Without that extraction, the only verification path is manual on a touchscreen, which is fine for the integration but leaves the math itself untested.

No backend changes. No data model changes. No new components. No tests for the integration (Konva + jsdom can't simulate multi-touch reliably — verified manually).

---

## Task 1: Gesture math helpers (TDD)

Pure functions for pinch math, testable without DOM or Konva.

**Files:**
- Create: `web/src/components/studio/kv-generator/gestureMath.ts`
- Create: `web/src/components/studio/kv-generator/gestureMath.test.ts`

- [ ] **Step 1: Write the failing tests**

Create `web/src/components/studio/kv-generator/gestureMath.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import {
  distance,
  midpointInContainer,
  computePinchTransform,
} from "./gestureMath";

describe("distance", () => {
  it("returns 0 for identical points", () => {
    expect(distance({ clientX: 5, clientY: 5 }, { clientX: 5, clientY: 5 })).toBe(0);
  });
  it("computes 3-4-5 triangle hypotenuse", () => {
    expect(distance({ clientX: 0, clientY: 0 }, { clientX: 3, clientY: 4 })).toBe(5);
  });
});

describe("midpointInContainer", () => {
  it("averages two points and offsets by container rect", () => {
    const mid = midpointInContainer(
      { clientX: 100, clientY: 200 },
      { clientX: 300, clientY: 400 },
      { left: 50, top: 100 },
    );
    expect(mid).toEqual({ x: 150, y: 200 });
  });
});

describe("computePinchTransform", () => {
  it("scales by ratio of current/start distance", () => {
    const out = computePinchTransform(
      {
        distance: 100,
        midpoint: { x: 200, y: 300 },
        scale: 1,
        stagePos: { x: 0, y: 0 },
      },
      { distance: 150, midpoint: { x: 200, y: 300 } },
    );
    expect(out.scale).toBeCloseTo(1.5);
  });

  it("keeps the pivot point under the midpoint when fingers move", () => {
    // From the spec's worked example.
    const out = computePinchTransform(
      {
        distance: 100,
        midpoint: { x: 200, y: 300 },
        scale: 1,
        stagePos: { x: 0, y: 0 },
      },
      { distance: 150, midpoint: { x: 210, y: 305 } },
    );
    // Stage point originally at (200, 300) should land at the new midpoint.
    const pointToScreenX = out.stagePos.x + 200 * out.scale;
    const pointToScreenY = out.stagePos.y + 300 * out.scale;
    expect(pointToScreenX).toBeCloseTo(210);
    expect(pointToScreenY).toBeCloseTo(305);
  });

  it("clamps to the upper scale bound", () => {
    const out = computePinchTransform(
      {
        distance: 100,
        midpoint: { x: 0, y: 0 },
        scale: 1,
        stagePos: { x: 0, y: 0 },
      },
      { distance: 10000, midpoint: { x: 0, y: 0 } },
      { min: 0.1, max: 5 },
    );
    expect(out.scale).toBe(5);
  });

  it("clamps to the lower scale bound", () => {
    const out = computePinchTransform(
      {
        distance: 1000,
        midpoint: { x: 0, y: 0 },
        scale: 1,
        stagePos: { x: 0, y: 0 },
      },
      { distance: 10, midpoint: { x: 0, y: 0 } },
      { min: 0.1, max: 5 },
    );
    expect(out.scale).toBe(0.1);
  });
});
```

- [ ] **Step 2: Run tests — expect FAIL ("module not found")**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web && bun test src/components/studio/kv-generator/gestureMath.test.ts
```

Expected: FAIL — `gestureMath` module doesn't exist yet.

- [ ] **Step 3: Implement the helpers**

Create `web/src/components/studio/kv-generator/gestureMath.ts`:

```ts
/**
 * Pure helpers for two-finger pinch + pan gestures on a Konva stage.
 * Used by KvKonvaCanvas to compute the new stage scale + position from
 * the start state of a gesture and the current touch positions.
 *
 * Inputs use `clientX`/`clientY` so the helpers are agnostic to the
 * concrete TouchEvent / PointerEvent types (browsers vs jsdom).
 */

type ClientPoint = { clientX: number; clientY: number };

/** Euclidean distance between two client-coords points. */
export function distance(a: ClientPoint, b: ClientPoint): number {
  const dx = a.clientX - b.clientX;
  const dy = a.clientY - b.clientY;
  return Math.sqrt(dx * dx + dy * dy);
}

/** Midpoint of two client-coords points, expressed in the stage
 *  container's local coords (CSS px relative to the container's
 *  top-left). The container rect is read once at gesture start. */
export function midpointInContainer(
  a: ClientPoint,
  b: ClientPoint,
  containerRect: { left: number; top: number },
): { x: number; y: number } {
  return {
    x: (a.clientX + b.clientX) / 2 - containerRect.left,
    y: (a.clientY + b.clientY) / 2 - containerRect.top,
  };
}

/** Compute the new stage transform for an in-progress pinch gesture.
 *  Holds the canvas-coords point that was under the start midpoint
 *  fixed at the current midpoint, and scales by the ratio of current
 *  to start distance. Clamps scale to the [min, max] range. */
export function computePinchTransform(
  start: {
    distance: number;
    midpoint: { x: number; y: number };
    scale: number;
    stagePos: { x: number; y: number };
  },
  current: {
    distance: number;
    midpoint: { x: number; y: number };
  },
  scaleClamp: { min: number; max: number } = { min: 0.1, max: 5 },
): { scale: number; stagePos: { x: number; y: number } } {
  const ratio = current.distance / start.distance;
  const newScale = Math.max(
    scaleClamp.min,
    Math.min(scaleClamp.max, start.scale * ratio),
  );
  const pointTo = {
    x: (start.midpoint.x - start.stagePos.x) / start.scale,
    y: (start.midpoint.y - start.stagePos.y) / start.scale,
  };
  return {
    scale: newScale,
    stagePos: {
      x: current.midpoint.x - pointTo.x * newScale,
      y: current.midpoint.y - pointTo.y * newScale,
    },
  };
}
```

- [ ] **Step 4: Run tests — expect PASS**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web && bun test src/components/studio/kv-generator/gestureMath.test.ts
```

Expected: all 6 tests pass.

- [ ] **Step 5: Type check**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web && bun run tsc --noEmit
```

Expected: no NEW errors in either new file. (Pre-existing errors in unrelated files like `brands/`, `wireframes/` are fine.)

- [ ] **Step 6: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web
git add src/components/studio/kv-generator/gestureMath.ts src/components/studio/kv-generator/gestureMath.test.ts
git commit -m "feat(web): add pure gesture math helpers for pinch + pan"
```

---

## Task 2: Wire pinch + two-finger pan into KvKonvaCanvas

Add the `gestureRef` and three handler functions; extend the existing touch entry points to short-circuit when ≥2 fingers are detected.

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvKonvaCanvas.tsx`

- [ ] **Step 1: Import the gesture helpers and add the gesture ref**

In `web/src/components/studio/kv-generator/KvKonvaCanvas.tsx`, near the top imports (with other relative imports), add:

```ts
import {
  distance,
  midpointInContainer,
  computePinchTransform,
} from "./gestureMath";
```

Inside the `KvKonvaCanvas` function body, alongside the existing `useState` / `useRef` declarations (the block that includes `htmlImage`, `loadError`, `selected`, `stageScale`, `stagePosition`, `draft`, `isDrawingRef`, `activeBoxId`, `promptDraft`), add:

```ts
const gestureRef = useRef<{
  startDistance: number;
  startMidpointStage: { x: number; y: number };
  startScale: number;
  startStagePos: { x: number; y: number };
} | null>(null);
```

- [ ] **Step 2: Add the three pinch handlers**

Still inside `KvKonvaCanvas`, after the existing `handleWheel` function and before `handleStageMouseDown`, add three helper functions:

```ts
// Returns true if the event was consumed as a multi-touch gesture
// start (caller should skip its own logic).
const handleTouchPinchStart = (
  e: Konva.KonvaEventObject<TouchEvent>,
): boolean => {
  const touches = e.evt.touches;
  if (touches.length < 2) return false;
  const stage = stageRef.current;
  if (!stage) return false;
  const containerRect = stage.container().getBoundingClientRect();
  gestureRef.current = {
    startDistance: distance(touches[0], touches[1]),
    startMidpointStage: midpointInContainer(touches[0], touches[1], containerRect),
    startScale: stage.scaleX(),
    startStagePos: { x: stage.x(), y: stage.y() },
  };
  // Cancel any in-progress single-finger drag (Konva's stage.draggable
  // begins panning on the first touch — we override when a 2nd finger
  // lands).
  if (stage.isDragging()) stage.stopDrag();
  // Cancel any frame-marquee draft that might have started on touch 1.
  isDrawingRef.current = false;
  setDraft(null);
  e.evt.preventDefault();
  return true;
};

const handleTouchPinchMove = (
  e: Konva.KonvaEventObject<TouchEvent>,
): boolean => {
  const g = gestureRef.current;
  const touches = e.evt.touches;
  if (!g || touches.length < 2) return false;
  const stage = stageRef.current;
  if (!stage) return false;
  const containerRect = stage.container().getBoundingClientRect();
  const currentDist = distance(touches[0], touches[1]);
  const currentMid = midpointInContainer(touches[0], touches[1], containerRect);
  const next = computePinchTransform(
    {
      distance: g.startDistance,
      midpoint: g.startMidpointStage,
      scale: g.startScale,
      stagePos: g.startStagePos,
    },
    { distance: currentDist, midpoint: currentMid },
  );
  setStageScale(next.scale);
  setStagePosition(next.stagePos);
  e.evt.preventDefault();
  return true;
};

const handleTouchPinchEnd = (
  e: Konva.KonvaEventObject<TouchEvent>,
): boolean => {
  if (gestureRef.current && e.evt.touches.length < 2) {
    gestureRef.current = null;
    return true;
  }
  return false;
};
```

- [ ] **Step 3: Wire pinch handlers into the existing touch entry points**

The Stage's `onTouchStart`/`onTouchMove`/`onTouchEnd` are currently bound to `handleStageMouseDown`/`Move`/`Up`. Update each of those three functions to call the corresponding pinch handler first, and short-circuit if the pinch handler consumed the event.

Find `handleStageMouseDown` (the function that begins around line 264). At the very top of its body — before any of its existing logic — add:

```ts
// Multi-touch gesture? Short-circuit single-touch paths.
if ((e.evt as TouchEvent).touches?.length >= 2) {
  if (handleTouchPinchStart(e as Konva.KonvaEventObject<TouchEvent>)) return;
}
```

Find `handleStageMouseMove` (begins around line 295). Add at the top:

```ts
if ((e.evt as TouchEvent).touches?.length >= 2 || gestureRef.current) {
  if (handleTouchPinchMove(e as Konva.KonvaEventObject<TouchEvent>)) return;
}
```

Find `handleStageMouseUp` (begins around line 307). Add at the top:

```ts
if (gestureRef.current) {
  if (handleTouchPinchEnd(e as Konva.KonvaEventObject<TouchEvent>)) return;
}
```

`handleStageMouseMove` and `handleStageMouseUp` currently take a parameterless signature for some calls (look at the existing function header — `handleStageMouseMove` has no parameter, `handleStageMouseUp` has no parameter). They need to accept the event so we can read `e.evt.touches`. Update their signatures to:

```ts
const handleStageMouseMove = (
  e: Konva.KonvaEventObject<MouseEvent | TouchEvent>,
) => { ... };

const handleStageMouseUp = (
  e: Konva.KonvaEventObject<MouseEvent | TouchEvent>,
) => { ... };
```

The Konva Stage already passes events to all three handlers — adding a parameter won't break the existing wiring.

- [ ] **Step 4: Type check**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web && bun run tsc --noEmit
```

Expected: no NEW errors in `KvKonvaCanvas.tsx`. If TypeScript complains about reading `e.evt.touches` (which doesn't exist on `MouseEvent`), the cast `(e.evt as TouchEvent).touches?.length` plus the optional-chaining `?.` should silence it. If you see other errors in this file, stop and report.

- [ ] **Step 5: Run all kv-generator + gestureMath tests**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web && bun test src/components/studio/kv-generator/
```

Expected: all previously-passing tests still pass, plus the 6 new `gestureMath` tests. The pre-existing Konva jsdom failure in `KvKonvaCanvas.overlays.test.tsx` will continue to fail (it's not introduced by this task).

- [ ] **Step 6: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web
git add src/components/studio/kv-generator/KvKonvaCanvas.tsx
git commit -m "feat(web): add multi-touch pinch + two-finger pan to KV canvas"
```

---

## Task 3: Manual verification

Konva + jsdom can't simulate multi-touch reliably, so this task is manual.

**Files:** none.

- [ ] **Step 1: Start (or refresh) the dev server**

The user already runs `bun dev` for the web service. If it's not running:

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web && bun dev
```

Visit a KV file URL in a browser:
`http://localhost:3000/studio/kv-generator/<file-id>`

- [ ] **Step 2: Verify Mac trackpad pinch still works (regression check)**

On a MacBook trackpad, pinch out (spread two fingers) over the canvas. The bg image should zoom in, anchored at the cursor position. Pinch in: zooms out. This goes through the existing `handleWheel` (the OS sends `wheel + ctrlKey`); it should be unaffected by Task 2's changes.

If it feels sluggish (one pinch barely changes scale), the spec notes a one-line tweak: in `handleWheel`, multiply `SCALE_BY` for `ctrlKey` cases. Defer if it feels fine.

- [ ] **Step 3: Verify mouse wheel zoom still works (regression check)**

On a desktop with a real mouse (or by sending `wheel` events from devtools), scroll the wheel over the canvas. Zoom should still work as before, anchored at the cursor.

- [ ] **Step 4: Verify single-touch behavior unchanged (regression check)**

On a touchscreen (or browser devtools mobile-mode with a single touch):
- Tap an overlay → selects it
- Drag an overlay → moves it
- Drag empty canvas in cursor mode → pans the stage
- Frame tool + drag → draws marquee

None of these should differ from before Task 2.

- [ ] **Step 5: Verify two-finger pinch zoom on touchscreen**

On an iPad / touchscreen:
- Place two fingers on the canvas
- Spread them apart (pinch out) → bg image zooms in, anchored at the midpoint between fingers
- Pinch them together → zooms out
- Maximum zoom caps at 5×, minimum at 0.1×

- [ ] **Step 6: Verify two-finger pan on touchscreen**

On a touchscreen:
- Place two fingers on the canvas without changing their distance
- Drag both fingers in the same direction → stage translates by the midpoint delta

- [ ] **Step 7: Verify combined pinch + pan**

On a touchscreen:
- Pinch out while also dragging both fingers across the canvas
- Should zoom in AND pan simultaneously, smoothly

- [ ] **Step 8: Verify gestures work in non-cursor tools**

On a touchscreen, switch to the Frame tool, Text tool, and Image tool in turn. In each:
- Two-finger pinch → still zooms
- Two-finger pan → still pans
- Single-touch → still does the tool's job (drag-marquee for frame, click-to-place for text/image)

- [ ] **Step 9: Verify the lift-to-single-touch handoff**

On a touchscreen:
- Place two fingers, start pinching
- Lift one finger
- The remaining finger should NOT cause the canvas to rubber-band or jump — the gesture should end cleanly, and the next interaction starts fresh

- [ ] **Step 10: Verify the second-finger-cancels-drag edge**

On a touchscreen, in cursor mode:
- Start a single-finger drag-pan on empty canvas
- While dragging, place a second finger
- The single-finger drag should cancel; pinch+pan begins. Confirm no visual jump or stuck state.

If any step fails, stop and report which one + what was observed.

---

## Final Verification

- [ ] **Step 1: Full TypeScript check**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web && bun run tsc --noEmit
```

Expected: no errors introduced by this branch. (Pre-existing errors elsewhere are unchanged.)

- [ ] **Step 2: Full kv-generator test run**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web && bun test src/components/studio/kv-generator/ src/store/kv/
```

Expected: all previously-passing tests still pass, plus the 6 new `gestureMath` tests. The pre-existing Konva jsdom failure in `KvKonvaCanvas.overlays.test.tsx` continues to fail (inherited, unrelated).

- [ ] **Step 3: Lint**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web && bun run lint
```

Expected: no NEW lint errors.

- [ ] **Step 4: Walk through spec acceptance criteria**

Review against `docs/superpowers/specs/2026-04-27-studio-kv-multitouch-gestures-design.md` Acceptance Criteria 1-10. The Task 3 manual steps map 1:1; ensure each criterion has been confirmed.

If any criterion fails, return to Task 2 and fix.

---

## Out of scope (do NOT implement here)

- Two-finger rotate gesture (Transformer rotate handle covers this)
- Three-finger swipe (no undo/redo system)
- Trackpad scroll = pan (would change current wheel-zoom semantics)
- Native `gesturestart` / `gesturechange` / `gestureend` events (Safari-only, redundant)
- Inertial pan after release
- Pointer Events API for Apple Pencil distinction

These are listed in the spec's Future Work and will land as separate plans if/when prioritized.
