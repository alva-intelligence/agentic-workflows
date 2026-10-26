# KV Motion Emphasis Presets — Design Spec

> **Status:** draft
> **Author:** daffa
> **Created:** 2026-08-02
> **Services:** web only
> **Topic slug:** kv-motion-emphasis-presets
> **Parent:** `2026-08-02-kv-motion-timeline-editor-design.md`

## Overview

Add four **emphasis presets** to the KV Motion timeline editor — mid-timeline
attention animations (as opposed to the existing entrance/exit presets):

| Preset | Keyframes written (over 600ms from insert point) |
|---|---|
| **Pulse** | scale: sampled → sampled×1.08 (300ms, out) → sampled (600ms, in-out) |
| **Shake** | x: sampled, then ±0.008 alternating at 120ms intervals (4 swings), back to sampled at 600ms |
| **Spin** | rotation: sampled → sampled+360 (600ms, in-out) |
| **Bounce** | y: sampled → sampled+0.02 (200ms, in) → sampled−0.012 (400ms, out) → sampled (600ms, out) |

Applied **at the playhead position** on the selected/targeted layer via a new
"Emphasis" section in the existing per-layer preset menu. Stagger toolbar is
unchanged (entrance/exit only).

## Core design decision: additive, window-scoped writer

The existing `applyPreset` is deliberately destructive track-wide (strips ALL
x/y/scale/opacity keyframes on the track) — correct for entrance/exit,
**wrong** for emphasis: a pulse at 2s must not erase the slide-in at 0s.

New pure function in `web/src/lib/motion/presets.ts`:

```ts
export type EmphasisPresetId = "pulse" | "shake" | "spin" | "bounce";
export const EMPHASIS_WINDOW_MS = 600;
export function applyEmphasisPreset(
  timeline: MotionTimeline,
  base: Map<string, MotionProps>,
  overlayId: string,
  preset: EmphasisPresetId,
  atMs: number,
): MotionTimeline;
```

Semantics:
- **Window-scoped strip:** removes keyframes only inside
  `[atMs, atMs + EMPHASIS_WINDOW_MS]` and only for the props the preset
  touches; everything outside the window (and other props inside it) is
  untouched. Re-applying at the same spot is deterministic (no duplicates).
- **Sampled base:** the anchor values come from
  `sampleTimelineAt(timeline, base, atMs)` — a pulse on a layer that is
  mid-slide animates relative to its sampled state, not its resting pose,
  so motion stays smooth.
- **Continuity guard:** writes an anchor keyframe carrying the sampled value
  at `atMs` and restores it at `atMs + 600` (each preset's table above already
  ends on the sampled value), so interpolation into and out of the window is
  seamless.
- **Clamp:** if `atMs + 600 > duration_ms`, the window is compressed to fit
  (scale the internal offsets linearly, minimum 200ms; if less than 200ms of
  room, insertion is rejected and the menu item is disabled with a tooltip).
- Immutable; whole-ms rounding; one undo step (`push`, no label).

## UI

- Per-layer preset menu (`TrackPresetMenu` popover in `KvMotionEditor`) gains a
  second group labeled **Emphasis** under the existing Entrance/Exit items
  (divider + `text-textXsMedium text-text-inverse-subtlest` group label,
  matching the menu's existing styles).
- Selecting one calls `applyEmphasisPreset(..., playheadMs)` on that layer and
  resets the menu (stateless, like existing presets).
- Disabled state (with tooltip "Not enough room before the end") when
  `duration_ms - playheadMs < 200`.

## Non-goals

- Emphasis in the Stagger toolbar.
- Looping/repeating emphasis (a pulse that repeats every second).
- Custom emphasis duration/intensity controls.

## Testing

Pure unit tests in `presets.test.ts` style: window-scoped strip (keyframes
outside window survive; entrance pair at 0 survives a pulse at 2000ms);
sampled-base anchoring (pulse mid-slide anchors on the interpolated value);
deterministic re-apply; end-of-timeline clamp + rejection; immutability;
per-preset keyframe shapes (pulse scale peak 1.08×sampled at +300ms, spin +360,
shake swing count, bounce y offsets).

## Deferred (decisions locked, spec'd later)

Captured from the same brainstorm so they aren't lost:

- **Motion assistant chat (feature 2):** iterative via KV chat infra
  (Agno, `app.tools.*`) per house rule; floating chat panel bottom-left in the
  motion editor mirroring KvChat; the Agno tool RETURNS MotionTimeline JSON in
  the chat response (never writes the DB) and web auto-applies it via `push()`
  as one undo step with an Applied + Undo chip card; each turn sends the
  CURRENT timeline as context.
- **Timeline templates (feature 3):** `brand_motion_templates` mirroring
  `brand_overlay_presets` (brand-scoped, jsonb); tracks stored as patterns with
  x/y keyframes as DELTAS from resting pose; auto-mapping on apply by overlay
  type then z-order, leftovers static; one undo step.
