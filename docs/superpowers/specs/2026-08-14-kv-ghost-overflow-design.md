# KV Ghosted Overflow — Craft + Resize

> **Date:** 2026-08-14
> **Status:** approved (design), not implemented
> **Service:** web only
> **Branch context:** `feature/alva/vc-kv-fabric-export` — Craft and Resize both
> render through Fabric now (fase 1–2c of the single-engine work), which is what
> unparks this feature. Supersedes the "Follow-on" sketch in
> `2026-08-10-kv-canvas-surface-unification-design.md` with a concrete design.

## Problem

When an overlay extends past its frame, both surfaces hard-crop it and the
user loses all sense of where the image actually is:

- **Craft** (`KvFabricCanvas.tsx`): every overlay object gets
  `clipPath: buildOverlayClip(overlay)` — an absolute-positioned rect over its
  host board. The part outside the board simply isn't drawn.
- **Resize** (`KvTileOverlayEditor.tsx`): each tile is a `fabric.Canvas` element
  sized exactly to the tile. Nothing is clipped in Fabric — the **canvas
  element's own edge** does the cropping. There is no drawable area outside the
  frame at all.

Wanted (Figma/Canva behavior): while a layer is selected or being dragged, the
part of it falling outside the frame renders as a dimmed "ghost", so the user
can see what they're moving.

## Decisions (settled with Daffa, 2026-08-14)

1. **Trigger:** ghost appears only for the selected / dragging layer(s). No
   always-on mode, no toggle.
2. **Interaction:** the layer can be dragged from its ghost region (like
   Figma). Not display-only.
3. **Scope:** all overlay types — image, text, shape. Base images are not
   ghosted (they are fit to the frame and not draggable on these surfaces).

## Design

### 1. Shared ghost mechanism

New small module (sibling of `fabricExport.ts`, e.g. `ghostOverlay.ts`):

- A ghost is a **duplicate of the overlay's Fabric object** with:
  - `clipPath`: the same host-frame rect the real object is clipped to, but
    with `inverted: true` — only the part **outside** the frame draws.
  - `opacity`: 25% of the layer's own effective opacity.
  - `evented: false, selectable: false` — purely visual, never hit-tested,
    never part of a selection.
  - `globalCompositeOperation` forced back to `source-over` — a blend-mode
    layer's ghost must not blend with whatever happens to be behind the frame.
  - Tag: `data.ghostFor = overlay.id`. No `data.elementId`, so the Yjs binding
    and any `getObjects()` scan can never mistake it for a real overlay.
    (Export is safe by construction anyway — the flatten path builds from
    overlay *data*, not from live canvas objects — the tag is the second
    fence.)
- Ghosts are inserted at the **bottom of the object stack**. On Craft that is
  below every board's base image, so a ghost never draws over a neighbouring
  board's content; the visible part of the ghost is only ever over the world
  background. On Resize the same rule applies within the tile's canvas.

**Drag-from-ghost costs nothing:** Fabric hit-testing ignores `clipPath`, so
the *real* object is already grabbable outside the frame today — invisibly.
The ghost just makes that region visible. No event plumbing needed.

### 2. Craft wiring (`KvFabricCanvas.tsx`)

- **Lifecycle:** ghosts are derived from the current selection. Selection
  change → create ghosts for newly selected overlays, remove ghosts whose
  overlay left the selection. The reconcile pass also rebuilds a ghost when
  its source overlay's payload/geometry changed (same inputs that restyle the
  real object).
- **Live drag:** on `object:moving` / `object:scaling` / `object:rotating`,
  mirror `left/top/scaleX/scaleY/angle` from the real object to its ghost and
  `setCoords()`, so the ghost tracks every frame of the gesture — not just the
  drop.
- The ghost's inverted clip uses the same live host rect `buildOverlayClip`
  uses (including a board mid-drag via `liveDrag`), so board drags keep the
  ghost's window correct.
- **Inline text edit:** an overlay being inline-edited gets no ghost (its real
  object is hidden during editing; the DOM editor replaces it).
- **Multi-select:** every overlay in the selection gets its own ghost.

### 3. Resize wiring (`KvTileOverlayEditor.tsx`) — the apron

The tile canvas needs room outside the frame to draw into. That room is the
**apron**.

- **Trigger:** apron exists only while the tile `isActive` **and** at least
  one overlay is selected on it — exactly the ghost trigger. Merely clicking
  a tile does not grow anything, so there's no visual jump on activation.
- **Size:** `a = round(0.15 × max(displayWidth, displayHeight))`.
- **Geometry when apron is on:**
  - Canvas element becomes `(W + 2a) × (H + 2a)`; it is absolutely positioned
    at `top/left: -a` inside the row wrapper so the row's **layout footprint
    is unchanged** — the tile column does not reflow.
  - Every build coordinate shifts by `+a`; `commitModified`, drag-guide math,
    and placement clicks (`onPlaceImage` / `onPlaceText`) convert back with
    `-a`. The two conversions are an inverse pair and live next to each other
    (same discipline as `overlayRect` / `overlayNormFromRect`).
  - The apron offset joins the reconcile signature, so toggling it rebuilds
    once at selection boundaries — never per-frame.
  - `applyMaxQualityScaling` keeps capping the backing store; the apron canvas
    is ~1.7× the pixels of the plain one and only ever exists on one tile at a
    time.
- **Clipping responsibilities move:** with the canvas edge no longer cropping,
  every **non-selected** overlay gets an explicit `clipPath` rect over the
  frame (visually identical to today), and each **selected** overlay gets the
  shared ghost treatment from §1. The base image keeps its frame-exact
  geometry.
- **Row wrapper:** while the apron is on, the wrapper drops `overflow-hidden`
  and raises its `z-index` above sibling rows. The active ring (`ring-2`)
  stays on the frame-sized wrapper, so the frame boundary stays clearly marked
  and the ghost visibly crosses it. Accepted cosmetic trade-off: the tile's
  rounded corners are square while the apron is on (the ring already marks the
  active state).
- `KvResizeOriginalRow` (master row) gets the same treatment through the same
  editor component. `KvResizeTileStage` (static preview) is untouched — it
  never has a selection.

### 4. Edge cases

- Clicking empty apron space deselects (Fabric background click) → apron
  collapses → the *next* click lands on whatever neighbouring row was behind
  it. Accepted.
- A layer extending past the apron is still cropped at the apron's edge. The
  apron is a porthole, not infinite canvas — accepted bound.
- Escape / switching tiles clears selection → ghost and apron go away
  together.

### 5. Testing

- **Unit** (`ghostOverlay.test.ts`, apron math tests):
  - ghost has `inverted` clip, 25% relative opacity, `ghostFor` tag, is not
    evented/selectable, forces `source-over`;
  - apron coordinate round-trip: build(+a) then commit(−a) reproduces the
    input normalized geometry exactly.
- **Component** (existing `onCanvasReady` hook pattern):
  - select an overlay → exactly one ghost object exists, at the bottom of the
    stack; deselect → it's gone;
  - a drag commit from an aproned canvas produces the same normalized overlay
    geometry as the same drag without an apron.
- **Manual e2e** (Daffa, browser): drag an overlay past the frame on Craft and
  on a Resize tile; ghost tracks live; download still matches the preview.

## Out of scope

- Motion editor surfaces.
- Always-on overflow visualization or a toggle.
- Ghosting the base image.
