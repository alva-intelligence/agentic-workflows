# Motion Per-Property Lane Drag — Design Spec

> **Status:** draft
> **Author:** daffa
> **Created:** 2026-08-31
> **Services:** web only (api, ai-service untouched)
> **Topic slug:** motion-prop-lane-drag
> **Companion:** `2026-08-31-motion-build-tab-design.md` (depends on this one)

## Overview

Make the per-property sub-row bars in the KV Motion timeline **draggable** —
body drag to retime, edge handles to change duration — so a layer's Move can
run for 1s while its Scale runs 0.4s and starts later.

Today those lanes exist but are read-only by design. `PropSubRow`
(`BlockTrackRow.tsx`) states the reason: one `MotionKeyframe` carries a sparse
subset of several props, so dragging one property's bar means **splitting a
keyframe in two** — a change to how the document is mutated, not a UI
addition. That split is what this spec defines.

Motivation is parity with thebrief.ai's "Build" model, where each animated
property is its own timeline row with independent timing. We keep our keyframe
document and derive lanes from it (see Non-Goals); only the mutation rules and
the lane renderer are new.

## Background: why a drag is a split

A track's keyframes are sparse. A single keyframe at 500ms may carry
`{ scale: 1.2, opacity: 1 }`. The `scale` lane and the `opacity` lane both
draw a bar covering that keyframe, because `propGroupSegments` filters the
track per prop group and re-runs `trackSegments` on the filtered list.

Dragging the **scale** bar +200ms must produce: `scale: 1.2` at 700ms,
`opacity: 1` still at 500ms. There is no way to express that by retiming the
existing keyframe — it has to be split.

## Decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Gate drag on preset-authored blocks? | **No gate** | `label` is documented as purely descriptive and is deliberately not invalidated by edits. Making it a permission gate turns a cosmetic field load-bearing: a hand-edited block still reads "Fade in" and would stay locked forever. Preset output is already editable through four other paths (block shift, block stretch, canvas drag + auto-key, "Change motion"). |
| Preset name after a lane drag | **Touched keyframes lose `label`** | `segmentLabel` trusts the earliest keyframe in a segment. A lane bar spans its whole segment, so the earliest keyframe of that group is touched in practice and the block falls back to honest property naming (`position · opacity`). |
| Lane actions | **Shift + stretch** | Matches what block bars already offer, and is what "Scale is too short" actually needs. Per-channel delete is deferred (Non-Goals). |
| Colliding times | **Clamp, never merge** | Merging two props into one keyframe forces them to share one `easing`, silently changing one property's curve. |
| Document model | **Unchanged** | Per-property tracks in the persisted document would break every stored motion project and template, plus sampler, presets, blocks and export. Not worth it for a timing affordance. |

## Architecture

### 1. Mutation layer — `src/lib/video-editor/blocks.ts`

Two new pure functions, signatures mirroring the existing segment writers so
UI wiring stays symmetric:

```ts
export function shiftPropGroupKeyframes(
  timeline: MotionTimeline,
  overlayId: string,
  group: PropGroupKey,
  segStartMs: number,
  segEndMs: number,
  deltaMs: number,
): MotionTimeline;

export function stretchPropGroupKeyframes(
  timeline: MotionTimeline,
  overlayId: string,
  group: PropGroupKey,
  segStartMs: number,
  segEndMs: number,
  newStartMs: number,
  newEndMs: number,
): MotionTimeline;
```

Both share one internal implementation that takes a `retime: (tMs) => number`
mapping; shift passes `t => t + delta`, stretch passes the linear rescale.

**Algorithm**

1. Resolve `group` to its keys via `PROP_LABEL_GROUPS`. `position` means x
   **and** y move together — the lane already shown today.
2. Find the lane's segments via `propGroupSegments(track, group)`. The
   `[segStartMs, segEndMs]` pair must match one exactly, else return the
   timeline unchanged — the same guard `shiftSegmentKeyframes` uses.
3. Compute each affected keyframe's target time through `retime`, then apply
   the clamps below to the segment as a whole (never per keyframe, or the
   segment would deform).
4. **Extract.** For every keyframe whose time is inside the lane segment and
   that carries at least one of the group's keys:
   - if it carries **other** props too: delete the group's keys from it, and
     append a new keyframe at the target time carrying only those keys, with
     the **same `easing`** and **no `label`**;
   - if it carries **only** the group's keys: retime it in place and clear its
     `label`;
   - if a keyframe ends up with zero props after extraction, drop it.
5. Sort the resulting keyframes by `t_ms` before returning.

Easing duplication is lossless: `easing` means "curve INTO this keyframe", so
giving both halves of a split the original value preserves each property's own
incoming curve.

**Clamps** (all have precedent in this file):

| Clamp | Rule |
| --- | --- |
| Walls | target span stays inside `[0, timeline.duration_ms]` |
| Lane neighbours | 1ms clearance against the previous/next segment **of the same lane** |
| Occupied times | 1ms clearance against **any** keyframe time already on the track |
| Minimum span | stretch floors at `MIN_BLOCK_SPAN_MS` |

The third clamp is what makes "never merge" true rather than aspirational.

### 2. Drag mechanics — `src/components/video-editor/useBarDrag.ts` (new)

`SegmentBar` already owns a complete drag implementation: pointer capture, a
local draft span for the live visual, neighbour/wall clamping, snap latching,
and exactly one commit per gesture on pointerup. Lanes need the same mechanics
and none of its chrome (label, tooltip, still-point diamond, context menu,
selection tint).

Extract the mechanics into a hook:

```ts
useBarDrag({
  span, durationMs, laneRef, snapGuides, clamps, onShift, onStretch,
}): { draft, snapHit, handlers: { onPointerDown, onPointerMove, onPointerUp } }
```

`SegmentBar` is refactored onto it with **no behaviour change**; the new
`PropSegmentBar` renders a slim bar on top of it.

The alternative — adding a "lane mode" to `SegmentBar` — grows
`BlockTrackRow.tsx` (already ~52KB, the largest file in the directory) and
risks the main bar. Writing a second drag implementation for lanes guarantees
drift; this repo has already paid that bill once with `PRESET_LABELS`, which
had three copies before being consolidated.

### 3. Lane renderer — `src/components/video-editor/PropSegmentBar.tsx` (new)

Slim bar for the h-7 sub-row: draggable body, two edge handles, no label, no
menu. Clicking the body selects the layer, exactly as a block click does.

`PropSubRow` (in `BlockTrackRow.tsx`) drops `aria-disabled` and renders
`PropSegmentBar` when the drag callbacks are present.

### 4. Plumbing

New optional props, following the `savedMotions` / `onFocusTrack` precedent —
when a host omits them the lanes stay read-only, and no test harness gains a
type error:

```ts
// TimelineDockProps → BlockTrackRowProps → PropSubRow
onShiftPropGroup?: (
  trackId: string, group: PropGroupKey,
  segStartMs: number, segEndMs: number, deltaMs: number,
) => void;
onStretchPropGroup?: (
  trackId: string, group: PropGroupKey,
  segStartMs: number, segEndMs: number,
  newStartMs: number, newEndMs: number,
) => void;
```

`useMotionEditorState` gains `shiftPropGroup` / `stretchPropGroup`, each
calling the writer through `push()` — one undo step per gesture, no label,
matching how segment drags already behave.

Snapping stays on: lanes consume the same `snapGuides` the dock already
collects across tracks, so Scale can latch to the edge of Move or to the
playhead.

## Data Flow

```
pointerdown on lane bar
  → useBarDrag: capture, draft span
pointermove
  → draft updated, clamped, snap latched (visual only)
pointerup
  → onShiftPropGroup(trackId, group, segStart, segEnd, deltaMs)
    → useMotionEditorState.shiftPropGroup
      → shiftPropGroupKeyframes(...) → push() → autosave
        → propGroupSegments re-derives lanes, trackSegments re-derives blocks
```

Because blocks are derived, a lane drag can legitimately **split or merge the
parent block** — pull Scale far enough away from Move and one bar becomes two.
That is the model working as documented (`trackSegments` splits where every
prop is still across a gap), not a bug.

## Error Handling

- Mismatched segment (stale UI, concurrent edit): writers return the timeline
  unchanged. No toast — the bar simply snaps back.
- Locked or hidden tracks: lanes render read-only, same as their block bars.
- A drag whose clamped delta rounds to 0: no `push()`, so no empty undo step.

## Testing

| File | Covers |
| --- | --- |
| `blocks.propGroupDrag.test.ts` (new) | extraction with mixed-prop keyframes, easing duplicated on both halves, emptied keyframes dropped, three clamps, stretch rescale + `MIN_BLOCK_SPAN_MS`, label cleared on touched keyframes, no-op on segment mismatch |
| `useBarDrag.test.ts` (new) | one commit per gesture, draft during move, snap latch, no commit on zero delta |
| `TimelineDock.proplanes.test.tsx` (new) | expanded row renders draggable lanes, commit args correct, read-only when callbacks omitted |
| `TimelineDock.test.tsx`, `.snap.`, `.trackstretch.` (existing) | regression net for the `SegmentBar` refactor — must stay green untouched |

New test files rather than additions to `blocks.test.ts` (37.9KB) and
`TimelineDock.test.tsx` (48.8KB): both sit near bun 1.3.2's ~51KB transpiler
cliff, past which a file dies with a bogus SCSS parse error.

## Rollout

1. **Extract `useBarDrag`; refactor `SegmentBar` onto it.** Zero behaviour
   change, zero visual change. Shipping this alone isolates the only step where
   a regression can hide.
2. **Writers + `PropSegmentBar` + plumbing.** Lanes become draggable.

## Non-Goals

- Per-channel delete from a lane (right-click → Delete)
- Per-property `easing` — the model keeps easing per keyframe
- Blur, Path, Resize — new props in `MotionProps`, renderer and exporter
- Restructuring the document into per-property tracks
- A single "Remove animation" action per layer

## Risks

- **The `SegmentBar` refactor** is the one place regressions can hide. Mitigated
  by making it its own step with existing drag tests as the net.
- **The occupied-time clamp may feel sticky** on tracks dense with keyframes.
  If it bites, the fix is a finer clearance — not allowing merges, which would
  reintroduce silent easing changes.
- **Blocks splitting under the user** after a big lane drag is correct but may
  read as surprising. Watch for it in manual testing before adding any
  countermeasure.
