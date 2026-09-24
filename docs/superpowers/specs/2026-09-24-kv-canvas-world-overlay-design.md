# KV canvas world overlay — DOM chrome that moves with the camera, not after it

**Status:** draft for review · **Date:** 2026-09-24 · **Owner:** daffa · **Service:** web
**Branch:** `feature/daffa/vc-kv-craft-resize-strip`

## Problem

While panning or zooming the KV canvas, the board/tile artwork moves smoothly
but the DOM chrome around it — board and tile captions, the tile header icons,
the "Resizes" divider, comment pins — trails behind and "snaps" into place
when the gesture stops (Daffa, 2026-09-24, screenshot at 38% zoom).

Why tiles are fine and chrome is not:

- Boards and tiles are **Fabric pixels**. Every wheel/pinch/hand-drag event
  writes the camera to `cameraRef` and calls `canvas.setViewportTransform`
  synchronously (`kvCameraStore.ts`, `fabric/useCanvasCamera.ts`). No React.
- The chrome is **DOM positioned from React state**. During a gesture the
  camera's React state is committed at most once per animation frame
  (`setCameraLive`), so chrome is ≥1 frame behind. Chrome fed by published
  screen rects is later still: `onBoardRectsChange` fires in a `useEffect`
  after the canvas commit, and its consumers (`KvCanvas` → strip chrome,
  `KvGeneratorLayout` → comment pins) re-render the 8k-line layout on every
  frame of a gesture. The thread popover adds one more effect-driven render.
- Proof the imperative path works: the soft-lock outlines read `cameraRef`
  in a rAF loop and never lag.

## Goal

Every always-on piece of chrome stays glued to its board/tile through pan AND
zoom — the same experience the tiles have — and a gesture no longer
re-renders the layout every frame.

## Approach (chosen: "world layer driven by CSS variables")

Industry pattern for DOM-over-canvas editors (tldraw, Excalidraw): position
chrome in **world** coordinates and let the camera move it through CSS,
written synchronously by the same code that moves the canvas.

1. **Camera store publishes synchronously.** `createKvCameraStore` gains
   `subscribe(listener) → unsubscribe`. `set` and `setLive` call listeners
   right after `applyToFabric`, in the same event — before any React work.
2. **CSS variables on the chrome's root.** A hook
   `useCameraCssVars(elementRef, store)` subscribes and writes, as inline
   custom properties on that element:
   - `--cam-s` (scale), `--cam-x`, `--cam-y` (px),
   - `--cam-cs` = `chromeScale(scale)` (the existing clamp, `chromeScale.ts`),
   - `--cam-cs-ready` = `min(1, scale)` (the ready-chip clamp).
   It writes once on mount so the first paint is correct.
3. **World-positioned elements.** A pure helper turns a world rect/point plus
   chrome offsets into a style object of `calc()` expressions, e.g.
   `left: calc(<wx>px * var(--cam-s) + var(--cam-x))`,
   `top: calc(<wy>px * var(--cam-s) + var(--cam-y) - 22px * var(--cam-cs))`,
   `font-size: calc(14px * var(--cam-cs))`. Elements keep their current
   visual rules (what scales with zoom, what is clamped, what is fixed) — only
   the source of the numbers moves from React state to CSS.
4. **World rects instead of screen rects across boundaries.** Consumers that
   today receive per-frame screen rects (`onBoardRectsChange`) receive
   **world** rects that only change when boards/tiles move, plus access to
   the camera store (`onCameraStoreChange(store)`, like `onZoomApiChange`).
   The screen-rect publication stays only for consumers not migrated yet,
   and is removed once none remain.

Coordinate space: all chrome rects are local to the canvas box, which sits at
viewport (0,0) (the container only narrows from the right — comment dock,
docked chat). The comment layer's `position: fixed` relies on this today and
keeps relying on it.

### Alternatives considered

- **Draw chrome in Fabric** (like tiles): perfect sync, but loses DOM text
  quality, hover/tooltip/focus/a11y, and needs counter-scaling per frame;
  rename inputs, menus and pin popovers would still be DOM. Kept as a
  possible later choice for purely static decorations only.
- **Delta CSS transform during gestures** (translate/scale the existing
  layers by the camera difference until React catches up): smallest change,
  exact for pan, but text/icons visibly scale during zoom and React still
  re-renders every frame. Rejected as a patch, not a pattern.

## Scope and phases

Each phase is independently shippable and smoke-testable.

| Phase | Chrome migrated | Where |
|---|---|---|
| **P1 — mechanism + board chrome** | camera store `subscribe`; `useCameraCssVars`; world-style helper; BoardChrome always-on items: board labels, tile captions, Concept badge, ready-to-share chips, "+" variant button, rationale card | `kvCameraStore.ts`, `fabric/useCanvasCamera.ts`, new `fabric/worldStyle.ts` + hook, `fabric/BoardChrome.tsx`, `KvFabricCanvas.tsx` |
| **P2 — strip chrome** | "Resizes" divider, tile header icon row, tile status layer, tile frame-box layer (positions from `computeResizeStrip`'s world rects) | `KvCanvas.tsx`, `KvResizeStripChrome.tsx` |
| **P3 — comment pins** | `CommentPinOverlay` pins + draft pin, `CommentThreadPopover` anchor; layout reads board **world** rects; per-frame `onBoardRectsChange` removed once unused | `KvGeneratorLayout.tsx`, `components/comments/*`, `lib/studio/kv/commentPartRect.ts`, `KvFabricCanvas.tsx` |
| **P4 — optional, same pattern** | grid background position, ruler ticks, persisted guides, presence cursors | `KvGridOverlay`, `KvRulerOverlay`, `KvGuideLines`, `PresenceCursors` |

**Out of scope:** transient selection/gesture chrome (`ObjectSelectChrome`,
drag guides, drop indicator, angle panel, variant prompt popover, rename
inputs) — they exist while the user is not panning. Context menus stay
screen-anchored (the camera is frozen while board/overlay menus are open).
Known stale spots noted, not fixed here: the tile detect prompt's captured
`centre`, the tile context menu under a pan.

## Invariants

- The React `camera` state stays (transient chrome still reads it); nothing
  in P1–P3 may read `camera` state for an always-on element's position.
- Chrome that is interactive keeps working through the change: caption
  click/double-click-rename, board-label drag (`onLabelPointerDown` already
  reads `cameraRef`), ready-chip toggle, "+" button, tile header icons and
  download dropdown, comment pin click/drag.
- Hit areas move with the visuals (they are the same elements).
- `boardRects` for tile comment pins keeps the `tile.<exportId>` keys and
  `MASTER_ROW_ID` behaviour (`commentPartRect.ts`), now in world space.

## Testing

- Pure, test-first: world-style helper (pan only, zoom at a point, chrome
  offsets scaled by `--cam-cs`, fixed-px offsets not scaled), camera store
  `subscribe` (listeners fire synchronously on `set` and `setLive`, before
  the rAF commit; unsubscribe stops them), world→screen parity (the CSS
  formula equals `worldRectToScreen` for sampled cameras).
- No RTL/component tests for the canvas (track policy).
- Gates per phase: tsc ≤ current total, eslint no new warnings, explicit
  tests, `node next build` at the end of each phase.
- Manual (Daffa) per phase: pan and pinch-zoom fast over boards, tiles and
  pins — chrome stays welded; captions/icons keep their clamped size;
  every interactive item above still works.

## Success criteria

- No visible trailing or snap of captions, tile header icons, divider or
  pins during pan/zoom at any zoom.
- During a pan gesture the layout (`KvGeneratorLayout`) does not re-render
  per frame (after P3).
