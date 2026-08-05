# KV Motion — Pannable, Zoomable Preview Canvas — Design Spec

> **Status:** draft
> **Author:** daffa
> **Created:** 2026-08-05
> **Services:** web only
> **Topic slug:** kv-motion-canvas-camera
> **Builds on:** `2026-08-02-kv-motion-timeline-editor-design.md`, `2026-08-05-kv-motion-output-size-design.md`

## Overview

The Motion timeline editor's preview is a fixed, non-interactive rectangle. The
stage is sized to fit the pane and that is all you get: no zoom, no pan, no way
to inspect a small overlay or work at the edges of a tall 9:16 board. The Craft
canvas has had Figma-style pan/zoom for a long time, so the two surfaces feel
unrelated even though both are Konva stages showing the same artwork.

This spec gives the Motion preview a camera: pointer-anchored zoom, trackpad
pinch, pan, and fit — matching Craft's gestures so the muscle memory carries
over.

## Note on process

Daffa approved building this and stepped away, asking for spec → plan →
implementation to run to completion. The decisions that would normally have
been asked one at a time are recorded in **Decisions taken without asking**
below, each with its reasoning, so they can be reversed on review.

## Goals

1. Zoom the Motion preview with the same gestures Craft uses.
2. Pan the preview.
3. Fit-to-pane, on demand and on load.
4. Zero change to overlay drag behaviour or to exported output.

## Non-goals

- Refactoring Craft. Its camera stays where it is (see Decisions).
- A Transformer (resize/rotate handles) on the Motion canvas. Out of scope.
- Any api change. Camera state is ephemeral view state, never persisted.

## 1. The central mechanism: a CSS-transform camera

The camera is a CSS `transform` on the stage's container, **not** a mutation of
the Konva stage's own `scale`/`position`.

```
┌ viewport (fills the preview pane, overflow: hidden) ─────────┐
│   ┌ stage container ─────────┐                               │
│   │  transform: translate(x, y) scale(k)                     │
│   │  transform-origin: 0 0                                   │
│   │  ┌ Konva.Stage — board_width × board_height ─┐           │
│   │  │  overlay nodes, untouched coordinate space │          │
│   │  └────────────────────────────────────────────┘          │
│   └──────────────────────────────────────────────┘           │
└──────────────────────────────────────────────────────────────┘
```

**Why this and not stage.scale()/stage.position().** Overlay drags commit
through `KvMotionEditor.tsx`:

```ts
const x = node.x() / targetWidth - ov.width / 2;
```

That normalization is only valid while the stage's pixel size equals the board's
rendered size. Driving the camera through `stage.scale()`/`stage.position()`
would break that identity and make every drag commit silently wrong coordinates
— plausible-looking at 100% zoom and wrong everywhere else. A CSS transform
leaves the Konva coordinate space completely untouched, so that line, and every
other piece of stage-space math, keeps working unmodified.

**Pointer events survive the transform.** Verified in the installed Konva
(10.2.3, `node_modules/konva/lib/Stage.js:649`):

```js
_getContentPosition() {
  const rect = this.content.getBoundingClientRect();
  return {
    top: rect.top, left: rect.left,
    scaleX: rect.width / this.content.clientWidth || 1,
    scaleY: rect.height / this.content.clientHeight || 1,
  };
}
```

and `_setPointerPosition` divides pointer coordinates by that `scaleX`/`scaleY`.
Konva therefore already compensates for a CSS-scaled container: clicking and
dragging an overlay lands correctly at any zoom level, with no code from us.
**This behaviour is load-bearing for the whole design and must be pinned by a
test** (§6) so a future Konva bump cannot silently break dragging.

## 2. Stage intrinsic size

Today the stage is built at a fit-to-pane size:

```ts
const scale = Math.min(paneSize.width / bw, paneSize.height / bh, 1);
targetWidth  = Math.round(bw * scale);
targetHeight = Math.round(bh * scale);
```

so on a small pane the stage is a ~290×516 raster. Zooming a raster that size
just magnifies its pixels.

The stage is therefore built at the **snapshot's own `board_width` ×
`board_height`** instead, and the camera does the fitting. Two consequences,
both good:

- Zoom shows real detail rather than magnified preview pixels.
- The preview stage and the export stage now have identical dimensions, so the
  preview is literally what gets exported.

Cost is bounded: `videoSafeDims` already caps `board_width`/`board_height` at a
longest edge of 1920, so the stage can never exceed that. `remapSnapshotForRatio`
becomes a strict identity (same aspect *and* same size), which it already
effectively was.

## 3. Camera state and gestures

```ts
type Camera = { scale: number; x: number; y: number };
```

Ephemeral React state in the editor. Never persisted, never in the snapshot,
never sent to the api.

Gestures on the viewport element, mirroring `KvKonvaCanvas.handleWheel`:

| Input | Behaviour |
|---|---|
| `wheel` + `ctrlKey`/`metaKey` | Zoom anchored at the pointer. Covers Mac trackpad pinch (which emits `wheel` + `ctrlKey`) and Cmd+wheel anywhere. |
| plain `wheel` | Pan by `deltaX`/`deltaY`, content moving with the gesture. |
| two-finger touch | Pinch to zoom + pan, anchored at the midpoint. |
| drag on empty viewport | Pan. Must not fire when the drag starts on an overlay node — that is an overlay drag. |
| `Fit` control | Fit the board to the pane and centre it. |

Scale clamped to **0.1–5**, the same bounds Craft uses.

Pointer-anchored zoom keeps the point under the cursor fixed:

```
mousePointTo = (pointer - cameraOffset) / oldScale
newOffset    = pointer - mousePointTo * newScale
```

## 4. Fit

`fit(pane, board)` returns the camera that centres the board in the pane at
`min(pane.w/board.w, pane.h/board.h)` — **without** today's `Math.min(…, 1)`
ceiling, so a small board fills a large pane instead of sitting at 1:1 in the
middle of it.

Fit runs on mount, when the project's board dimensions change, and when the user
hits the Fit control. It does **not** re-run on every pane resize: silently
resetting a user's zoom because a panel toggled would be hostile.

## 5. Controls and their placement

The transport bar already shows a zoom percentage and a `Fit` button — those
belong to the **timeline**, not the canvas. A second, identical-looking pair on
the same screen would be genuinely confusing.

The canvas controls therefore live **on the canvas**, floating at the bottom-right
of the preview viewport: `−` / percentage / `+` / fit-icon, in the same floating
pill styling the rest of the studio uses. Physical separation plus a different
shape is what distinguishes them; the timeline's controls are not touched.

## 6. Testing

jsdom has no layout and no canvas 2D context, so the split is:

**Pure, fully tested** — `src/lib/motion/camera.ts`:
- `clampScale`, `zoomAt(camera, pointer, direction)`, `panBy(camera, dx, dy)`,
  `fitCamera(pane, board)`.
- Cases: pointer-anchored zoom keeps the anchor point stationary; clamping at
  both bounds; fit centres and scales correctly for portrait, landscape and
  square boards on both portrait and landscape panes; fit upscales a small board.

**Behavioural** — the gesture handler maps events to camera calls: `ctrl+wheel`
→ `zoomAt`, plain wheel → `panBy`, and a drag beginning on an overlay node does
NOT pan.

**The Konva contract test.** A test asserting `_getContentPosition` divides by
`rect.width / content.clientWidth` — the guarantee §1 depends on. jsdom returns
a zeroed `getBoundingClientRect`, so this pins the *formula* by stubbing
`content` with known `getBoundingClientRect`/`clientWidth` values and asserting
the returned `scaleX`. If a Konva upgrade changes that formula, this fails
loudly instead of dragging quietly breaking at non-1 zoom.

No e2e. Manual verification: pinch-zoom on a trackpad, drag an overlay at 3×
zoom and confirm it lands where dropped, Fit, then export and confirm the MP4 is
unchanged.

## 7. What must not change

- Overlay drag commit math (`node.x() / targetWidth …`) — untouched, by design.
- `exportMotionRatio` — builds its own detached stage; no camera state can reach
  it. The exported MP4 must be byte-identical whatever the camera is doing.
- The timeline's own zoom/Fit controls.
- `KvKonvaCanvas` — not modified by this work.

## Decisions taken without asking

1. **CSS-transform camera, not stage scale/position.** Keeps the drag
   normalization valid and removes the single biggest risk in the feature.
2. **Do not extract Craft's camera into a shared hook.** Craft's implementation
   is entangled with `KvKonvaCanvas`'s own state, selection, marquee and
   multi-board layout. Extracting it would put the studio's most-used canvas at
   risk to serve a Motion feature. Motion gets its own small camera module that
   *mirrors Craft's semantics* (same gestures, same 0.1–5 clamp, same
   pointer-anchored formula). Converging the two later is a follow-up, and the
   pure module written here is the natural thing to converge on.
3. **Stage built at board size, not fit size** (§2) — otherwise zooming
   magnifies preview pixels and the feature is pointless.
4. **Canvas controls on the canvas, not in the transport** (§5) — avoids two
   identical zoom controls on one screen.
5. **Fit does not re-run on pane resize** (§4) — resetting a user's zoom when a
   panel toggles would be hostile.
6. **Camera state is ephemeral** — not persisted per project. Zoom is a viewing
   posture, not a property of the work; persisting it means reopening a project
   in a state you have to undo.

## Open questions

None. Every decision above is recorded rather than deferred.
