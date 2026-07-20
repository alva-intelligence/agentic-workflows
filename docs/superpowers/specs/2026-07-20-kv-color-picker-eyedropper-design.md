# KV Canvas — Color Picker + Eyedropper

**Date:** 2026-07-20
**Author:** daffa
**Service:** web
**Status:** approved

## Problem

Color selection on the KV canvas is limited to eight hardcoded preset swatches
(`web/src/components/studio/kv-generator/overlays/OverlayColorChip.tsx`). There is no way to
enter an arbitrary color, no hex input, and no way to sample a color already present in the
key visual. Users who need an on-brand or image-matched color have no path at all.

Two adjacent branches extend the surface this affects:

| Branch | Adds | State |
|---|---|---|
| `feature/daffa/vc-kv-canvas-custom-fonts` | text gradient stops | pushed, PR web#275 open |
| `feature/daffa/vc-kv-canvas-shapes` | shape overlays with `fill` / `stroke` | local worktree, unpushed |

Neither is merged. This work is built on a **new branch off `develop`** as a standalone shared
component, wired only into the existing text-color chip. The shapes and custom-fonts branches
adopt it after they land — which is why the component must not know anything about overlays.

## Goals

- Arbitrary color selection (saturation/value area, hue slider, hex field).
- Eyedropper sampling of any color on screen.
- Keep one-click access to the eight existing presets — no regression for current users.
- Recently-used colors, so one color can be applied across several overlays quickly.
- A component boundary that the shapes and gradient branches can reuse unmodified.

## Non-goals

- **Alpha / opacity.** The overlay payload is a bare `#RRGGBB` string
  (`web/src/types/studio.ts:433-454`). Adding alpha changes the data model across api and
  ai-service. Out of scope.
- **Brand palette colors.** Would need the brand-colors query wired into the canvas. Out of scope.
- **Canvas pixel sampling.** See "Eyedropper" below — deliberately avoided.

## Architecture

### Component boundary

One new shared component at `web/src/components/frndos/v2/ColorPicker.tsx`. Presentational,
with no KV, Konva, or Fabric knowledge:

```
ColorPickerSwatch   { value, onChange, anchor, scale, presets?, visible?, disabled? }
  └─ swatch button — renders the current color
  └─ ColorPickerPopover   (portal → document.body, position: fixed)
       ├─ presets row      (8 colors; prop, defaults to today's PRESETS)
       ├─ recents row      (localStorage, up to 8)
       ├─ <HexColorPicker>  from react-colorful
       └─ hex field + eyedropper button
```

Contract: `value` and `onChange` are `#RRGGBB` strings. Because it knows nothing about
overlays, the shapes branch can drop it onto `fill` and `stroke`, and the custom-fonts branch
onto gradient stops, with no changes to this file.

`OverlayColorChip.tsx` is reduced to a thin KV-specific wrapper that supplies the anchor and
`getColorChipScale(overlayWidthPx)` (`overlays/adaptiveSizing.ts:23`). **Its props stay exactly
as they are today**, so all three mount sites are untouched:

- `KvKonvaCanvas.tsx:1397`
- `KvFabricCanvas.tsx:2493`
- `KvTileOverlayEditor.tsx:405`

### Why a portal

`KvCanvas.tsx:882` is `relative overflow-hidden` — the canvas viewport clips its children, so a
popover anchored inside it is cut off at the canvas edge. The popover therefore renders into a
portal on `document.body` with `position: fixed`.

The anchor is already computed in screen space by `worldRectToScreen`
(`KvKonvaCanvas.tsx:1389`), so a fixed-position portal needs no additional coordinate math. The
popover measures itself on open and flips above the swatch when there is not enough room below
the viewport edge.

### Library

`react-colorful` (~2.8 kB gzip, zero dependencies, React 19 compatible). It provides
`HexColorPicker` and `HexColorInput`, saving roughly 200 lines of pointer-drag and HSV
conversion code plus its accessibility edge cases. This is the first color dependency in
`web/package.json`.

## Interaction

- The floating pill collapses from eight swatches to **one** swatch showing the current color.
- Clicking the swatch opens the popover. Presets and recents are one click each and apply
  **live**, through the same `onChange` path used today.
- Dragging the saturation area fires `onChange` continuously, so the overlay updates live on
  canvas. Throughput is comparable to repeated preset clicks; the existing debounce on the
  overlay-save path absorbs it. No new save behavior is introduced.
- The popover closes on outside click, `Escape`, or the start of a canvas pan/zoom.
- The popover hides while `isInteracting` is true, matching the chip's current behavior during
  drag and transform.
- A color is committed to recents **on close**, not per drag frame, so a drag through many
  intermediate colors adds a single entry.

## Eyedropper

Uses the native `EyeDropper` API. The button renders only when supported:

```ts
const supported = typeof window !== "undefined" && "EyeDropper" in window;
```

Supported in Chrome, Edge, and Arc; absent in Safari and Firefox, where the button simply does
not appear. On click the popover hides (so it cannot sample itself), `new EyeDropper().open()`
is awaited, `result.sRGBHex` is applied, and the popover reopens. A user cancel rejects with
`AbortError` and is swallowed silently.

**Why not canvas sampling.** KV board images are loaded from S3 *without* `crossOrigin`, on
purpose — S3 does not send CORS headers (see the comments at `KvResizeTileStage.tsx:29` and
`KvTileOverlayEditor.tsx:95`). This taints the canvas, so `getImageData` and `toDataURL` on a
stage containing a board image throw `SecurityError`. The native API samples the composited
screen rather than our canvas, so the taint never comes into play. A canvas-sampling fallback
for Safari and Firefox would first require fixing CORS at the S3/CloudFront layer or proxying
images through a Next route; that is a separate piece of work.

## Recents

- `localStorage` key: `frnd.kv.recentColors`
- Capped at 8 entries, most-recent-first, de-duplicated case-insensitively.
- Read lazily on the first popover open, not at module load, to avoid an SSR hydration
  mismatch.
- Corrupt or absent JSON yields an empty array. Reads and writes never throw — `localStorage`
  access is wrapped, since it can throw in private-browsing modes.

## Blast radius

| File | Change |
|---|---|
| `web/src/components/frndos/v2/ColorPicker.tsx` | new |
| `web/src/components/frndos/v2/index.ts` | export the new component |
| `web/src/lib/studio/kv/recentColors.ts` | new — pure recents reducer + storage wrapper |
| `web/src/components/studio/kv-generator/overlays/OverlayColorChip.tsx` | rewritten as a wrapper; props unchanged |
| `web/package.json` | add `react-colorful` |

`KvKonvaCanvas.tsx`, `KvFabricCanvas.tsx`, and `KvTileOverlayEditor.tsx` are **not** modified.

## Testing

Unit tests via `bun test` (bunfig preloads jest-dom) on the pure logic:

- hex normalization and validation — casing, missing `#`, 3-digit shorthand, invalid input
- recents reducer — cap at 8, case-insensitive dedupe, most-recent-first ordering, tolerance of
  corrupt JSON and of a throwing `localStorage`
- popover flip placement — below by default, above when the viewport bottom is too close

Component tests:

- eyedropper button is absent when `window.EyeDropper` is undefined
- eyedropper success path applies `sRGBHex` via a stubbed `EyeDropper`
- eyedropper `AbortError` leaves the value unchanged and reopens the popover

The real build gate is `bun run build` (the web build does not type-check on its own, so type
errors must be caught deliberately). Manual e2e on the KV canvas is required before the PR:
select a text overlay, open the picker, verify live preview while dragging, verify presets and
recents apply, verify the eyedropper samples correctly, and verify the popover is not clipped
when the overlay sits near the canvas edge.

## Open questions

None.
