# KV Motion — multi-select segments (blocks + lane bars): copy, paste, delete, drag together

**Date:** 2026-09-21
**Author:** Daffa (with Claude)
**Status:** approved in chat, not implemented
**Services:** web only
**Branch:** `feature/daffa/vc-kv-motion-segment-multi-select`, from `develop`
**Source:** Daffa, 21 Sep 2026 — "Pop 6X: aku mau select 3 Scale dan paste ke line lain" (thebrief.ai parity). Companion to `2026-09-20-kv-motion-multi-select-apply-design.md` (layer multi-select) and `2026-08-31-motion-prop-lane-drag-design.md` (lane bars are draggable; a lane edit is a keyframe split).

---

## Problem

Selection in the Motion dock is one of two things: a set of **layers** (`selectedTrackIds`, from the 09-20 spec) or one **keyframe** (`selectedKeyframe`). A **segment** — a block bar on a track row, or a property bar on a Scale / Rotation / Opacity / Position lane — cannot be selected at all: clicking one selects its track, right-clicking one opens a menu for that one bar.

The motion clipboard (`motionClip.ts`) holds one clip with two scopes: `"track"` (a layer's whole animation) and `"segment"` (one block, all props in its span, re-based to 0). So today:

- one lane bar (just the Scale of a pulse) cannot be copied — a block copy takes every prop in the span;
- three non-contiguous pulses cannot be copied together — the clip is one contiguous block;
- nothing acts on more than one bar at a time (no bulk delete, no drag-together).

## Decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Selection unit | **A bar as drawn** — a block bar (`group: null`, every prop in its span) or a lane bar (one `PropGroupKey`). | The user selects what they can see. A lane bar is "just the Scale"; a block bar is "the whole pulse". |
| Identity | A segment is a **derived span**, not an entity: `{ trackId, group, startMs, endMs }`. After every document change the selection is re-resolved against the current `trackSegments` / `propGroupSegments` and stale refs are dropped. | Segments have no ids and every writer touches a segment's first keyframe (label/role loss — 08-31 spec), so any hash-derived id would churn. `selectedKeyframe` already lives as a bare `{ trackId, tMs }` — same pattern. |
| One layer per selection | All refs share one `trackId`. ⌘-click on another layer's bar **replaces** the selection. | Closes the ask; cross-layer would need collision rules for two segments writing the same prop. |
| Exclusive with layer multi-select | Filling `selectedSegments` clears `selectedTrackIds` to the one track, and vice-versa. `selectedKeyframe.trackId` is always the segments' `trackId`. | One highlighted thing at a time in the rail, the dock, the Inspector and the Transformer. |
| Gestures | Plain click = replace (and `selectTrackAtStart`, as today). **⌘/Ctrl-click = toggle.** **⇧-click = range within the same lane** (same `trackId` + `group`); ⇧ across lanes degrades to toggle. No marquee. | `modeFromEvent` already exists for layers. Marquee would need a free-area drag that the lane doesn't have. |
| Paste timing | **Same times as the source.** A segments clip stores absolute times and pastes them absolutely; the playhead is ignored. | The ask is "layer B pulses when layer A does". |
| Paste modes | `follow` / `exact` stay, as the two existing menu items. | Same meaning as today: re-based on the target's rest pose vs verbatim values. |
| Paste entry points | ✨ menu, rail-row right-click, dock-row right-click, `MotionPanelHeader` "Paste motion", ⇧⌘V. Label becomes **"Paste N segments"** while the clipboard holds a segments clip. Empty-slot and block menus **hide** Paste for a segments clip. | Those two targets mean "put it HERE"; a same-time paste would ignore where the user clicked. |
| Bulk actions in v1 | Copy, Paste, **Delete** (Backspace/Delete + menu), **Drag together** (body drag on a selected bar shifts every selected bar). | Daffa's pick. Change-motion-together is out. |
| Undo | One `push()` per bulk action; a refused or empty bulk pushes nothing. | Same rule as every bulk writer since 09-20. |
| Clip format | `MOTION_CLIP_VERSION` → **2**, new `scope: "segments"` with a `segments[]` payload. v1 clips (`version: 1`) still read through the old paths. | The clipboard is in-memory (a store) but survives across projects in one session; readers must not choke on the previous shape. |

## Design

### 1. Types — `src/lib/video-editor/segmentSelection.ts` (new, pure)

```ts
export type SegmentRef = {
  trackId: string;
  /** null = the block bar (every prop in the span); else one lane. */
  group: PropGroupKey | null;
  startMs: number;
  endMs: number;
};

export function sameRef(a: SegmentRef, b: SegmentRef): boolean;
/** The segments a lane currently draws — `trackSegments` for `group: null`,
 *  `propGroupSegments` otherwise. Single source of truth for range-select
 *  and for pruning. */
export function laneSegments(timeline, trackId, group): TrackSegment[];
/** Drop refs whose span no longer exists in the current derivation. Keeps
 *  order. Pure. */
export function pruneSegmentRefs(timeline, refs: SegmentRef[]): SegmentRef[];
/** Refs for every segment in `ref`'s lane between `anchor` and `ref`,
 *  inclusive, in time order. `anchor` in a different lane → `[ref]`. */
export function rangeSegmentRefs(timeline, anchor: SegmentRef, ref: SegmentRef): SegmentRef[];
/** The keyframes a ref owns: every keyframe in `[startMs, endMs]`, narrowed
 *  to the group's props (all props for a block). Keyframes left with no
 *  props are dropped. */
export function keyframesOfRef(track: MotionTrack, ref: SegmentRef): MotionKeyframe[];
```

`laneSegments` reuses `propGroupSegments` for lanes and `trackSegments` for blocks — no third clustering rule.

### 2. State — `useMotionEditorState.ts`

- `selectedSegments: SegmentRef[]` — sorted by `startMs`; invariant: one `trackId`; non-empty ⇒ `selectedKeyframe?.trackId === selectedSegments[0].trackId` and `selectedTrackIds.length === 1`.
- `selectSegment(ref, mode: SelectMode = "replace")`:
  - `replace` → `[ref]`, then the existing `selectTrackAtStart(ref.trackId)` behaviour (primary + playhead), which also collapses `selectedTrackIds`.
  - `toggle` → different `trackId` ⇒ behaves as `replace`; else add/remove `ref` (by `sameRef`). Removing the last ref leaves the track selected (single-select state, as before the gesture).
  - `range` → `rangeSegmentRefs(timeline, lastPicked, ref)` unioned in; `lastPicked` is a ref (not state) kept in a `useRef`. No anchor ⇒ `replace`.
  - Locked / hidden tracks: ignored (same eligibility gate as layers).
- `clearSelection` (existing; Esc and canvas click) also empties `selectedSegments`. `selectKeyframe` (diamond / tick click), `selectTrack` from the rail, and a plain click on any bar empty it too.
- **Re-resolve:** a `useEffect` on `timeline` runs `pruneSegmentRefs` and writes back only when something was dropped (reference-stable otherwise). Covers undo/redo and every writer without each one remembering to.
- Bulk writers (all: refs must be the current selection; each returns a count and pushes once when > 0):
  - `copySegments(source)` → `captureSegmentsClip` (§3) into the clip store; `false` when the selection owns no keyframes.
  - `deleteSegments()` → reduce `deleteSegmentKeyframes` (block) / `deletePropGroupKeyframes` (lane, new in `blocks.ts`: strip the group's props from keyframes in the span, drop keyframes left empty). Selection empties after the push (pruning does it).
  - `shiftSegments(deltaMs)` → clamp `deltaMs` to the tightest bound across all refs (each ref's own walls from `shiftSegmentKeyframes` / `shiftPropGroupKeyframes`'s clamp rules, computed against neighbours **outside** the selection), then reduce the per-ref shift with the clamped delta in **descending** `startMs` order for a positive delta and ascending for a negative one, so a ref never collides with a sibling that hasn't moved yet. Selection is rewritten to the shifted spans (delta known) rather than pruned.
- `pasteMotionInto` (pure, existing dispatcher) gains the `"segments"` branch (§3). `pasteMotion` / `pasteMotionToTracks` need no change beyond the analytics fields.

### 3. Clipboard — `motionClip.ts`

```ts
export const MOTION_CLIP_VERSION = 2;

export type MotionClipSegment = {
  group: PropGroupKey | null;
  startMs: number;            // source time, absolute
  endMs: number;
  keyframes: MotionKeyframe[]; // absolute times, only the group's props
  body: MotionTemplateBody;    // rest-relative encoding of the same keyframes,
                               // re-based to startMs for `normalizeTrackToTemplate`
};

export type MotionClip =
  | { version: 2; scope: "track" | "segment"; body; keyframes; source_duration_ms }   // unchanged payload
  | { version: 2; scope: "segments"; segments: MotionClipSegment[]; source_duration_ms };
```

- `captureSegmentsClip(track, base, durationMs, refs)`: per ref `keyframesOfRef`; then **dedupe across refs** by `(t_ms, prop)` — a block ref and a lane ref inside it own the same Scale keyframe once. `null` when nothing was owned.
- A single lane bar copied from its own menu is a one-item segments clip — the "copy just the Scale" case falls out of the same path.
- `pasteSegmentsClip(clip, overlayId, targetBase, durationMs, mode): MotionKeyframe[] | null`: for each segment, `startMs >= durationMs` ⇒ skipped; otherwise the segment is baked as a one-block clip into `room = durationMs − startMs` via the existing `placeMotionClipAt` (so a segment that would overrun compresses, exactly like a block paste near the end) and its keyframes are shifted back to `startMs`. Concatenated result; `null` when every segment was skipped.
- `pasteMotionInto` `"segments"` branch: `mergeKeyframesIntoTrack(timeline, overlayId, written, window)` **per segment** with `window = { startMs, endMs }` of that segment — merge is already prop-aware (it clears only the props it writes, only in the window), which is what makes a Scale-only paste leave the target's Opacity alone. One timeline in, one out.
- Readers: `pasteMotionClip` / `placeMotionClipAt` accept `version === 1 || version === 2` for the two old scopes; the `"segments"` scope is v2-only.
- Store: `useKvMotionClipStore` unchanged (it holds whatever `MotionClip` is).

### 4. Gestures & visuals — `BlockTrackRow.tsx`, `PropSegmentBar.tsx`

- `SegmentBar.handleBodyClick` and a new `PropSegmentBar` body click both call `onSelectSegment(ref, modeFromEvent(e))`; the plain-click path keeps calling `onSelectTrack` (via the hook's `replace` branch). A Path bar still opens its popover on plain click.
- Both bars get `selected: boolean` and render `data-selected="true"` + `ring-1 ring-inset ring-white/70`; a selected lane bar also steps its fill from `bg-white/[0.12]` to `bg-white/[0.2]` so a selection is readable at the lane's smaller size. Tick states are untouched.
- **Drag together:** a body drag on a **selected** bar reports `onLiveShift(delta)` as today; `BlockTrackRow` already fans a block's live delta into `overrideSpan` on sibling block bars — extend the fan-out to every selected ref on the row (block bars via the existing `overrideSpan`; `PropSegmentBar` gains the same `overrideSpan` prop). On commit the bar calls `onShiftSelection(deltaMs)` instead of `onShiftSegment` when it is selected. A drag on an **unselected** bar first replaces the selection with that bar (so "drag = drag this") — no change in feel for single bars.
- Locked track: selection ignored, bars inert as today.
- Dock `PanelHeader` hint: "⌘-click bars to select several" (rail already says "Shift / ⌘-click for multiple").

### 5. Menus & keyboard

- **Segment context menu** (`SegmentBar` and, new, `PropSegmentBar`): when the right-clicked bar is part of a selection of N > 1 → items **Copy N segments**, **Delete N segments**; Change motion / Save as template / Paste hidden. When N ≤ 1 → today's menu, plus (new) on a lane bar: **Copy Scale**, **Delete Scale** (a one-item segments clip / lane delete). Right-click on a bar outside the selection replaces the selection with it first (Figma rule, same as 09-20).
- **Keyboard** (window handler in `KvMotionEditor.tsx`, guarded by `isTypingTarget` / dialog like Esc is):
  - `Backspace` / `Delete` with `selectedSegments.length > 0` → `deleteSegments()`.
  - ⇧⌘C with `selectedSegments.length > 0` → `copySegments("keyboard")` instead of the whole-track copy; `makeMotionClipboardKeyHandler` gets a `copySegments` dep and asks it first.
  - ⇧⌘V unchanged (pastes whatever clip is held onto the primary / selection).
  - Esc: existing `clearSelection` now also covers segments (state §2).
- **Paste labels**: `MotionPanelHeader` and `TrackPresetMenu` read the clip's scope from the store and show "Paste 3 segments" (count) for `"segments"`; slot placeholders and block menus render no Paste items for that scope.

### 6. Analytics — `kv-generator-events.ts`

- `motion_clip_copied` / `motion_clip_pasted`: `scope` gains `"segments"`; new optional `segment_count: number`, `groups: string[]` (`"block"` for a block ref). `placement` for a segments paste is `"source_time"`.
- New `kv_generator.motion_segments_deleted { project_id, count, groups }` and `kv_generator.motion_segments_shifted { project_id, count, delta_ms }`.
- Per `feedback_web_features_need_posthog_events`: the taxonomy row is part of done.

### 7. Testing

- **Pure** (`segmentSelection.test.ts`, `motionClip.segments.test.ts`, `blocks.deletePropGroup.test.ts`): `pruneSegmentRefs` drops a moved span and keeps an intact one; `rangeSegmentRefs` within a lane and across lanes; `keyframesOfRef` narrows props and drops empties; `captureSegmentsClip` dedupes a block+lane overlap; `pasteSegmentsClip` keeps source times, skips a segment past the end, compresses one that overruns; the `"segments"` merge leaves the target's other props untouched; `deletePropGroupKeyframes` keeps the other group's values on a shared keyframe.
- **Hook** (`useMotionEditorState.segments.test.tsx`): `selectSegment` replace/toggle/range and the exclusivity with `selectedTrackIds`; selection survives a playhead move and is pruned after undo; `deleteSegments` and `shiftSegments` are one push each; `shiftSegments` clamps to the tightest ref; `copySegments` with nothing owned returns `false` and leaves the store alone.
- **RTL** (`BlockTrackRow.segmentSelect.test.tsx`, `PropSegmentBar.select.test.tsx`, `TrackPresetMenu.pasteSegments.test.tsx`): ⌘-click / ⇧-click on both bar kinds call `onSelectSegment` with the right mode; `data-selected` renders; the N-segments menu items appear and single-bar items hide; a live shift on one selected bar moves the other selected bar's `overrideSpan` (mutation check: dropping the fan-out must fail this test); Paste label reads the count; slot/block menus hide Paste for a segments clip.
- Every new test file stays well under the ~51 KB bun cliff; `screen` is broken under bun — use `within(document.body)`.

## Non-goals (v1)

Cross-layer selection; marquee; "Change motion" on a selection; paste-at-playhead for a segments clip; canvas-side selection of segments; stretch-together (edge drag on a selection stretches only the dragged bar and collapses the selection to it).

> **2026-09-21 follow-up — stretch/shift-together across a LAYER multi-select** (not this spec's segment selection): with ≥2 layers selected, dragging one layer's block bar also carries its *twins* — the identical-span block on every other selected layer (the multi-apply shape). Edge drag rescales all onto the same span, body drag shifts all, the In bar's body drag shifts every twin's whole track; walls = tightest twin, so the set never drifts. A nudged span is not a twin. Implemented web-only on `feature/daffa/vc-kv-motion-stretch-together` (`src/lib/video-editor/layerTwins.ts`, `useMotionEditorState.layerTwins`, dock-owned `TwinDraft`). Also fixed there: the trailing `click` after a group body drag used to collapse the selection (affected this spec's drag-together too).
