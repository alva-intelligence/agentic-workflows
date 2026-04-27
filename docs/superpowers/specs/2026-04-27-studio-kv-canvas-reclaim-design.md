---
title: KV Generator — Full-Viewport Canvas + Floating Chat
slug: studio-kv-canvas-reclaim
author: daffa
created: 2026-04-27
status: draft
services: [web]
---

## Overview

Make the KV Generator canvas fill the entire viewport between the top and bottom nav. Move the chat panel from a docked 444px right column to a fixed floating panel anchored bottom-right. Make the overlay chrome (Transformer handles, rotation arm, color chip) scale with the overlay's pixel size so it doesn't dwarf small elements. Bump the default text overlay from postage-stamp to headline-sized so the first text users place is actually usable.

This is a layout + polish pass that builds on the in-progress `studio-kv-overlays` feature. No backend changes, no data model changes — purely frontend layout, defaults, and chrome adaptation.

## Why

Today's canvas caps at `min(100%, 900px)` × `min(70vh, 720px)` (`KvCanvas.tsx:235-242`), and the chat takes a fixed 444px column on the right (`KvGeneratorLayout.tsx:336`). On a 9:16 portrait — the dominant aspect — that means the bg image displays at ~405×720 in the viewport. A default text overlay (`width: 0.1, height: 0.05`) is then ~40×36px CSS pixels. The Transformer handles (10px), Konva's default rotation arm (~50px), and the color chip pill (~280px wide) don't scale with the overlay, so the overlay element gets buried under its own UI.

Switching to text/image tools doesn't shrink the chat either, so editing always happens in a constrained canvas.

Industry pattern: editor tools (Canva, Figma, Adobe Express, Photoshop Web) fill the canvas to the full work area and dock or float side panels. The KV Generator crossed into editor territory the moment overlays shipped — the docked-chat layout is now working against the feature.

## Layout

### Before

```
┌─ top nav (full width) ─────────────────────────────────────┐
├──────────────────────────────────────┬─────────────────────┤
│                                      │                     │
│    Canvas (capped 900×720)           │   Chat (444px)      │
│    lots of dead space on wide        │   docked            │
│    aspects                           │                     │
│                                      │                     │
├──────────────────────────────────────┴─────────────────────┤
└─ bottom nav (with chat toggle pill) ───────────────────────┘
```

### After

```
┌─ top nav (full width) ─────────────────────────────────────┐
├────────────────────────────────────────────────────────────┤
│                                                            │
│    Canvas (full work area, no caps)                        │
│                                       ┌────────────────┐   │
│                                       │                │   │
│                                       │  Chat 420px    │   │
│                                       │  fixed         │   │
│                                       │  bottom-right  │   │
│                                       │                │   │
│                                       └────────────────┘   │
├────────────────────────────────────────────────────────────┤
└─ bottom nav (with chat toggle pill) ───────────────────────┘
```

## Sizing math (1440×900 viewport)

Available work area after navs ≈ 1392 × 756 (24px side gutters, ~64px top, ~80px bottom).

| Aspect | Today | After |
|---|---|---|
| 9:16 (portrait) | 405 × 720 | **425 × 756** |
| 1:1 (square) | 720 × 720 | **756 × 756** |
| 3:4 | 540 × 720 | **567 × 756** |
| 4:3 | 900 × 675 | **1008 × 756** |
| 16:9 (landscape) | 900 × 506 | **1344 × 756** |

The win is largest for landscape and square aspects. For 9:16 the gain is modest — viewport height is the binding constraint regardless of layout — but the overall feel improves because the chat no longer eats horizontal space the canvas could use.

## Changes

### 1. Floating chat panel

`KvGeneratorLayout.tsx` — chat container moves from a flex child to a fixed-position element:

```tsx
<div
  className="fixed z-30"
  style={{
    right: 24,
    bottom: 96,                                          // ~80px bottom nav + 16px gap
    width: 420,
    maxHeight: "calc(100vh - 64px - 80px - 32px)",       // top nav + bottom nav + 32px breathing room
    pointerEvents: chatOpen ? "auto" : "none",
  }}
  aria-hidden={!chatOpen}
>
  <div
    className={[
      "h-full origin-bottom-right transition-[transform,opacity] duration-300 ease-out",
      chatOpen ? "scale-100 opacity-100" : "scale-0 opacity-0",
    ].join(" ")}
  >
    <KvChat ... />
  </div>
</div>
```

The middle row simplifies — the 444px-wide flex column wrapping the chat goes away entirely:

```tsx
<div className="flex min-h-0 flex-1 overflow-hidden">
  <div className="flex min-h-0 flex-1 items-center justify-center overflow-hidden px-6">
    <KvCanvas ... />
  </div>
</div>
```

The existing `origin-bottom-right` scale-from-pill animation keeps working — fixed positioning doesn't affect it.

### 2. Canvas removes caps

`KvCanvas.tsx:227-243` — the `KonvaStageFrame` wrapper replaces:

```tsx
maxWidth: "min(100%, 900px)",
maxHeight: "min(70vh, 720px)",
width: aspect >= 1 ? "min(100%, 900px)" : undefined,
height: aspect < 1 ? "min(70vh, 720px)" : undefined,
```

with:

```tsx
maxWidth: "100%",
maxHeight: "100%",
width: aspect >= 1 ? "100%" : undefined,
height: aspect < 1 ? "100%" : undefined,
```

The flex parent's `flex-1` already constrains the available area. The `aspectRatio` style keeps the bg image's correct shape inside that area.

The "Version X / Apr 27" label that lives below the canvas (`KvCanvas.tsx:267-274`) stays. To preserve canvas height for the label, the wrapping flex column already gives the canvas all available height via `flex-1`; the label is a sibling at fixed height. No `calc()` needed.

### 3. Bigger default text overlay

`KvGeneratorLayout.tsx:173-191` — `handlePlaceText` defaults change:

```tsx
add({
  type: "text",
  x: Math.max(0, nx - 0.2),       // was nx - 0.05
  y: Math.max(0, ny - 0.04),      // was ny - 0.025
  width: 0.4,                     // was 0.1
  height: 0.08,                   // was 0.05
  rotation: 0,
  payload: { type: "text", content: "", color: "#FFFFFF" },
});
```

Result: a default text overlay is ~40% of canvas width × 8% tall — sized for a headline. With `fontSize = boxHeightPx * 0.8`, on a 756-tall canvas that's ~48px font in a ~302px-wide box. Comfortable headline starter that matches what users actually want.

### 4. Adaptive Transformer chrome

`KvKonvaCanvas.tsx` — the `OverlayNode` Transformer uses Konva defaults today (`anchorSize: undefined` → 10, `rotateAnchorOffset: undefined` → ~50). Make both scale with the overlay's pixel size:

```ts
const handleSize = Math.max(6, Math.min(12, Math.min(pw, ph) * 0.15));
const rotationOffset = Math.max(18, Math.min(32, Math.min(pw, ph) * 0.4));

<Transformer
  ref={trRef}
  rotateEnabled
  anchorSize={handleSize}
  rotateAnchorOffset={rotationOffset}
  enabledAnchors={[ ... existing ... ]}
  keepRatio={overlay.type === "text"}
/>
```

This keeps the chrome from dwarfing tiny overlays but caps it large enough to grab on tall/wide ones.

### 5. Adaptive color chip

`OverlayColorChip.tsx` — accept an `overlayWidthPx` prop, CSS-scale the chip pill so it never gets wider than the overlay it decorates:

```tsx
const chipScale = Math.max(0.7, Math.min(1, overlayWidthPx / 280));
<div
  style={{
    position: "absolute",
    left: anchor.x,
    top: anchor.y,
    transform: `scale(${chipScale})`,
    transformOrigin: "top left",
    ...
  }}
>
```

For rotation: v1 keeps the simple non-rotation-aware anchor (`px, py + ph + 8`). When the user starts dragging or rotating, hide the chip; show it again on `onTransformEnd` / `onDragEnd`. Defer rotation-aware anchor math to a follow-up — it's not blocking and the simple version stays glued to the overlay during normal use.

### 6. Files touched

- `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx` — floating chat container, default text size
- `web/src/components/studio/kv-generator/KvCanvas.tsx` — drop caps
- `web/src/components/studio/kv-generator/KvKonvaCanvas.tsx` — adaptive Transformer, chip-hide-during-transform
- `web/src/components/studio/kv-generator/overlays/OverlayColorChip.tsx` — adaptive scale prop
- No backend changes.

## What stays the same

- Overlay data model, backend endpoints, validation
- Default-open chat (user picked option 3a — no auto-collapse on tool change)
- Existing chat toggle pill in `KvCanvasBottomNav`
- KvChat internals — message rendering, input, file attachments, mode dropdown
- Frame tool, bounding box flow, version sidebar
- Konva stage zoom/pan in cursor mode (wheel zoom, drag pan)

## Out of scope (v1)

- Draggable / resizable chat panel — fixed bottom-right is enough for v1
- Backdrop blur / glass effect on chat — keep solid `#222`
- Auto-collapse chat when entering text/image/frame tool — user picked manual control
- Mobile / small-viewport layout — desktop only, matches existing studio behavior
- Rotation-aware color chip anchor — deferred; chip simply hides during rotate/drag
- Multi-line auto-wrap text overlays — separate feature
- Box auto-grow as user types — separate feature

## Trade-offs accepted

- **Chat occludes a ~420 × 600 region of bottom-right canvas while open.** Users who want to place/edit overlays in that region collapse chat first via the existing pill. Industry-standard pattern (Canva, Photoshop, Figma comments all work this way).
- **9:16 portrait gains very little canvas area** versus an alternative "docked chat with bigger caps" layout — viewport height is always the constraint. Accepted because the floating layout is simpler, consistent across aspects, and gives big wins on landscape/square.
- **No auto-collapse on tool change.** Predictable but means users have to click the pill themselves when they want max canvas. Documented; revisit if it bites.

## Acceptance criteria

1. With chat open (default), the canvas fills 100% of the area between top nav and bottom nav, minus the standard 24px side gutters.
2. The chat appears as a 420px-wide floating panel anchored to the bottom-right corner of the work area, ~24px from the right viewport edge and ~96px above the bottom nav.
3. Toggling the chat pill in `KvCanvasBottomNav` collapses/expands the floating chat with the existing scale-from-bottom-right animation.
4. Closing the chat does NOT change the canvas size — canvas is full-bleed regardless of chat state.
5. On 9:16 portrait, the bg image displays at viewport-height-bound size (~756px tall on a 900px-tall viewport) with no horizontal caps.
6. On 16:9 landscape, the bg image displays at the full available width with height derived from aspect.
7. Clicking the canvas with the text tool drops a default overlay of ~40% × 8% of canvas size, sized for a headline (~48px font on a 756-tall canvas).
8. Selected overlay's Transformer handle size scales between 6 and 12px, and its rotation arm distance scales between 18 and 32px, both based on the overlay's pixel dimensions.
9. The color chip CSS-scales between 0.7× and 1.0× based on the selected overlay's pixel width, capped so it never appears wider than the overlay itself.
10. The color chip hides during overlay drag/transform and reappears on `onDragEnd`/`onTransformEnd`.
11. The "Version X / Apr 27" label remains visible directly below the canvas image, horizontally centered.

## Future work — known directions

- Auto-collapse chat on tool change (`text`/`image`/`frame`) with a "user pinned" override flag — tiny addition once we see whether users want it.
- Draggable chat panel — keep last-position in localStorage; works fine with `position: fixed`.
- Frosted-glass chat backdrop — one CSS line (`backdrop-filter: blur(16px)` + translucent bg) once we want it.
- Rotation-aware color chip anchor — compute the rotated bbox bottom-edge midpoint and snap there.
- Box-grows-with-text for text overlays — measure rendered text width on commit, expand `width` to fit, keep `height` as user set it. Pairs well with the bigger default size.
