# KV Motion: cap the timeline dock so it stops eating the canvas

**Date:** 2026-08-10
**Surface:** `web/` only
**Status:** approved

## The problem

`KvMotionEditor`'s root is `flex h-screen flex-col`. It lays out three things: a
fixed top nav, a body (`flex min-h-0 flex-1`) holding the Layers rail, the
canvas and the Properties inspector, and the timeline dock below it.

The dock has no height constraint. Its height is purely a function of the
track count — one `h-9` (36px) row per overlay, plus the transport bar, the
ruler and the audio row. A KV with 14 overlays produces a dock around 640px
tall. On a 1080px viewport that leaves the body roughly 330px, and on a laptop
it leaves almost nothing: the canvas and both floating panels get clipped down
to a sliver while the dock occupies the screen.

This reads to the user as "the timeline is covering the canvas". It is not an
overlay problem — nothing is stacked on top of anything. The dock is simply
taking every pixel it asks for, and the flex body, being the only shrinkable
sibling, absorbs the whole cost.

## The fix

Bound the dock and let its lanes scroll vertically inside that bound.

### 1. Cap the dock at 40vh

The dock wrapper in `KvMotionEditor` becomes a shrink-proof flex column capped
at `max-h-[40vh]`, and `TimelineDock`'s own root gets `min-h-0 overflow-hidden`
so the card actually stops at the cap instead of spilling past it.

`max-height` rather than `height` matters: a two-track dock still hugs its
content exactly as it does today. The cap only engages once the track list
would otherwise push past 40% of the viewport.

40vh was chosen over a fixed pixel budget or a fixed row count because it
scales with the display. On a 1080p screen it is ~430px — transport, ruler and
roughly nine track rows. On a laptop it degrades proportionally instead of
leaving a dock that is either too tall to be usable or too short to be worth
showing.

### 2. Scroll the lanes vertically

`TimelineDock`'s scroll container is currently `overflow-x-auto`. It becomes
`overflow-auto` on both axes and `min-h-0 flex-1`, so it takes whatever height
is left inside the capped card and scrolls the rest.

Everything on the time axis — ruler, lanes, playhead and the audio row — stays
inside that one scroll container. That is the invariant the dock was built
around: they all size themselves from a single lane-width variable, so sharing
one scrollport is what keeps them from ever drifting apart horizontally. The
fix does not touch it.

### 3. Pin the ruler and the audio row

Two things must stay visible while the tracks scroll under them: the second
labels, without which a lane position means nothing, and the audio row, which
would otherwise be reachable only by scrolling to the bottom.

The ruler row gets `sticky top-0 z-30` with an opaque panel background; the
audio slot gets `sticky bottom-0 z-30` with the same. Sticky positioning
applies only on the Y axis here, so both still scroll horizontally in lockstep
with the lanes — the time alignment survives.

`TrackNameCell`'s existing `sticky left-0` keeps working: a sticky-left child
inside a sticky-top row is a supported nesting, and neither introduces an
overflow clip of its own.

The playhead stays `absolute inset-y-0` inside the tracks container, so it
spans the full content height and scrolls vertically with the lanes. That is
correct — the line belongs to the lanes, not to the viewport.

## What deliberately does not change

**Camera fit.** `useCanvasCamera` fits once on the first real pane measurement
and never re-fits on later pane resizes, so a user's zoom and pan are never
clobbered by a layout change. Because the cap is pure CSS, that first
measurement is already of the correctly-sized pane, and the opening fit is
right without any change to the camera.

**The Layers rail.** It keeps its own independent scroll. The rail and the
dock's lanes are separate regions of the screen, not side-by-side rows, so
there is nothing to synchronise.

**Popovers inside rows.** `BlockTrackRow`'s context menu anchors at fixed
viewport coordinates, which already escapes the scroll container's clip today.
Adding `overflow-hidden` to the dock root changes nothing for it.

**No new state.** No collapse toggle, no draggable divider, no persisted split,
no new PostHog event — the fix introduces no new user action to instrument.

## Testing

`TimelineDock.test.tsx` covers the dock structurally. jsdom performs no layout,
so height itself cannot be asserted there; the tests assert the structure that
produces it:

- the scroll container scrolls on both axes and can shrink (`min-h-0`)
- the ruler row carries `sticky top-0`
- the audio slot carries `sticky bottom-0`
- the dock root can shrink below its content height

The 40vh cap lives in `KvMotionEditor` and is verified by reading the rendered
wrapper's class list.

Actual behaviour under a long track list — that the canvas keeps ~60% of the
viewport and the lanes scroll under a pinned ruler — must be confirmed manually
in the browser.
