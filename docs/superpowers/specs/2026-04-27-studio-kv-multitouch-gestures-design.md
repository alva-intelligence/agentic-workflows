---
title: KV Generator — Multi-touch Pinch + Two-Finger Pan
slug: studio-kv-multitouch-gestures
author: daffa
created: 2026-04-27
status: draft
services: [web]
---

## Overview

Add Figma-style multi-touch gestures to the KV Generator canvas: two-finger pinch to zoom and two-finger pan to translate the stage. Gestures must work in every canvas tool (cursor / frame / text / image), so a user editing text on iPad can still pinch-zoom without first switching tools. No rotation gesture (we already have the Transformer rotate handle); no three-finger swipe; no change to existing mouse-wheel or single-touch behavior.

This is a frontend-only patch in `KvKonvaCanvas.tsx`. No data model changes, no backend changes.

## Why

Today the canvas pans single-finger via Konva's `Stage.draggable` and zooms via mouse wheel. On a touchscreen, two fingers do nothing — users can't zoom into a small region of the bg image or pan with the standard pinch-out + two-finger-drag they expect from Figma, Canva, and any modern design tool.

On Mac trackpads, pinch arrives as a `wheel` event with `ctrlKey: true`, so the existing wheel handler already covers that path implicitly. The gap is touchscreens (iPad, Surface, Android tablet) — that's what this spec addresses.

## Scope

**In:**
- Two-finger pinch → zoom anchored at the midpoint between the two fingers
- Two-finger pan → translate the stage by the midpoint delta
- Combined pinch + pan in a single gesture (you naturally pinch and slide at the same time)
- Works in every tool, not just cursor
- Mac trackpad pinch verified to still work via existing wheel handler

**Out (deliberately):**
- Two-finger rotate — Transformer already exposes a rotation handle on selected overlays
- Three-finger swipe — no undo/redo system to bind it to
- Pan-by-trackpad-scroll (the Figma "scroll wheel = pan" semantic) — would change today's wheel-zoom behavior; separate decision if requested later
- Native gesture events (`gesturestart`/`gesturechange`/`gestureend`) — Safari-only, redundant with our touch handling

## Trackpad pinch (Mac) — already covered

Two-finger pinch on a MacBook trackpad fires `wheel` events with `ctrlKey: true` and a delta proportional to the pinch velocity. Our existing `handleWheel`:

```ts
const direction = e.evt.deltaY > 0 ? -1 : 1;
const newScale = direction > 0 ? oldScale * SCALE_BY : oldScale / SCALE_BY;
```

…zooms the stage anchored at the cursor position regardless of `ctrlKey`. So Mac trackpad pinch already works as zoom. Only tweak this spec might add: a slightly larger `SCALE_BY` factor when `ctrlKey === true` so the zoom feels responsive to deliberate pinch gestures (the OS already integrates velocity, so a single tick should produce a more visible scale change). This is a one-liner; defer if it feels fine in testing.

## Touchscreen pinch + two-finger pan

### Gesture state

Track in refs (not React state — high-frequency updates during a gesture):

```ts
type GestureState = {
  startDistance: number;            // CSS px between the two touch points at gesture start
  startMidpointStage: {             // midpoint location relative to the Konva stage container
    x: number;
    y: number;
  };
  startScale: number;               // stageScale at gesture start
  startStagePos: { x: number; y: number };  // stagePosition at gesture start
};
const gestureRef = useRef<GestureState | null>(null);
```

### Helpers

```ts
function distance(a: Touch, b: Touch): number {
  const dx = a.clientX - b.clientX;
  const dy = a.clientY - b.clientY;
  return Math.sqrt(dx * dx + dy * dy);
}

function midpoint(a: Touch, b: Touch, containerRect: DOMRect): { x: number; y: number } {
  // Return midpoint in stage container coords (CSS px relative to stage's top-left).
  return {
    x: (a.clientX + b.clientX) / 2 - containerRect.left,
    y: (a.clientY + b.clientY) / 2 - containerRect.top,
  };
}
```

The Stage container's `getBoundingClientRect()` is read once at gesture start (not every move) — the canvas doesn't move while the user is gesturing.

### Handlers

These extend the existing `handleStageMouseDown` / `Move` / `Up` (which already accept `MouseEvent | TouchEvent`). The touch-specific multi-finger paths short-circuit the existing single-touch logic when ≥2 fingers are detected.

```ts
function handleTouchPinchStart(e: Konva.KonvaEventObject<TouchEvent>) {
  const touches = e.evt.touches;
  if (touches.length < 2) return false;
  const stage = stageRef.current;
  if (!stage) return false;
  const containerRect = stage.container().getBoundingClientRect();
  gestureRef.current = {
    startDistance: distance(touches[0], touches[1]),
    startMidpointStage: midpoint(touches[0], touches[1], containerRect),
    startScale: stage.scaleX(),
    startStagePos: { x: stage.x(), y: stage.y() },
  };
  // Cancel any single-finger drag that was about to happen.
  isDrawingRef.current = false;
  setDraft(null);
  e.evt.preventDefault();
  return true; // signal "handled — caller skips other behavior"
}

function handleTouchPinchMove(e: Konva.KonvaEventObject<TouchEvent>) {
  const g = gestureRef.current;
  const touches = e.evt.touches;
  if (!g || touches.length < 2) return false;
  const stage = stageRef.current;
  if (!stage) return false;
  const containerRect = stage.container().getBoundingClientRect();

  const currentDist = distance(touches[0], touches[1]);
  const currentMid = midpoint(touches[0], touches[1], containerRect);

  const ratio = currentDist / g.startDistance;
  const newScale = Math.max(0.1, Math.min(5, g.startScale * ratio));

  // The canvas-coords point the user is pinching around stays fixed at currentMid.
  const pointTo = {
    x: (g.startMidpointStage.x - g.startStagePos.x) / g.startScale,
    y: (g.startMidpointStage.y - g.startStagePos.y) / g.startScale,
  };
  const newPos = {
    x: currentMid.x - pointTo.x * newScale,
    y: currentMid.y - pointTo.y * newScale,
  };

  setStageScale(newScale);
  setStagePosition(newPos);
  e.evt.preventDefault();
  return true;
}

function handleTouchPinchEnd(e: Konva.KonvaEventObject<TouchEvent>) {
  if (e.evt.touches.length < 2 && gestureRef.current) {
    gestureRef.current = null;
    return true; // remainder of the gesture is single-touch from here
  }
  return false;
}
```

### Wiring into existing handlers

In each existing handler (`handleStageMouseDown` / `Move` / `Up`), call the pinch variant first; if it returns `true`, return early. Mouse paths and single-touch paths are unaffected.

### Stage draggable conflict

`Stage.draggable={tool === "cursor"}` enables Konva's built-in single-finger drag-pan. When a 2nd finger lands, we call `e.evt.preventDefault()` AND clear `gestureRef`. Konva's drag is driven by mouse-down / first-touch internally — adding a 2nd finger doesn't auto-cancel it, so we also need to call `stage.stopDrag()` if the stage is currently mid-drag:

```ts
if (stage.isDragging()) stage.stopDrag();
```

This goes inside `handleTouchPinchStart` after the `gestureRef.current = {...}` assignment.

### Pivot point math — sanity check

Worked example. User starts pinch with two fingers 100px apart at midpoint (200, 300). Stage was at scale 1, position (0, 0).

After 1 frame they spread fingers to 150px apart at midpoint (210, 305):

- `ratio = 150 / 100 = 1.5`
- `newScale = 1.0 × 1.5 = 1.5`
- `pointTo = (200, 300)` (in canvas coords, since startScale=1, startStagePos=0,0)
- `newPos = (210 - 200×1.5, 305 - 300×1.5) = (-90, -145)`

So the canvas point that was at (200, 300) on screen is now at `0 + 200×1.5 + (-90) = 210` in screen X, and `0 + 300×1.5 + (-145) = 305` in screen Y — exactly the new midpoint. Pivot held; pinch + pan combined correctly. ✓

## Files touched

- `web/src/components/studio/kv-generator/KvKonvaCanvas.tsx` — add `gestureRef`, three pinch helpers, wire into existing touch entry points

No new files, no new components, no new helper modules. No backend, no migration, no test fixtures (multi-touch can't be reliably simulated in jsdom).

## Acceptance criteria

1. On a touchscreen, two-finger pinch out on the canvas zooms in; pinch in zooms out. The point under the midpoint of the two fingers stays put under the midpoint while the gesture continues.
2. On a touchscreen, two-finger drag (without pinching) pans the stage by the midpoint delta.
3. Pinch + pan combined in a single gesture work simultaneously without jumpiness.
4. Pinch zoom is clamped to the same `[0.1, 5]` scale range the wheel handler uses.
5. The gestures work in cursor, frame, text, and image tools — placing the text or frame tool does not disable two-finger zoom/pan.
6. Single-finger touch behavior is unchanged: tap selects, drag-on-empty pans (cursor mode), drag-on-overlay moves the overlay.
7. On Mac trackpad, two-finger pinch zoom continues to work via the existing wheel handler. (Verify; tweak `SCALE_BY` only if it feels sluggish.)
8. On desktop mouse, wheel zoom continues to work unchanged.
9. When the user lifts one of two fingers mid-gesture, the gesture ends cleanly and the remaining finger is treated as a fresh single-touch (no rubber-band).
10. When a 2nd finger lands during an in-progress single-finger drag, the drag is cancelled (`stage.stopDrag()`) and the pinch gesture begins.

## Future work — known directions

- **Trackpad scroll = pan** (Figma semantic). Would change `handleWheel` to pan on plain wheel and zoom only on `ctrlKey || metaKey`. Cleaner to defer — touches the existing desktop UX and warrants its own discussion.
- **Two-finger rotate** for selected overlays. Trivial to add: track angle between the two touch points alongside distance/midpoint, apply delta as `overlay.rotation`. Skipped in v1 because the Transformer rotate handle already covers this on touch.
- **Inertial pan** (decelerate after release). Pure visual polish; defer.
- **Native iPad / Pencil gesture support** via Pointer Events API (`PointerEvent` with `pointerType: "pen"`). Would let us treat Pencil distinctly from finger; not needed for v1.
