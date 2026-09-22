# KV Motion — Build Sub-Segments (many runs of one channel per block) — Design Spec

> **Status:** implemented 2026-09-22 (web develop 947e1bb30…88da3c25c, unpushed; live check by Daffa pending)
> **Author:** daffa
> **Created:** 2026-09-22
> **Services:** web only (api stores the timeline opaquely; no schema change)
> **Topic slug:** kv-motion-build-sub-segments
> **Builds on:** `2026-08-31-motion-build-tab-design.md`, `2026-08-31-motion-prop-lane-drag-design.md`, the block-menu Build tab (2026-09-21)

## Overview

Let a block's Build tab add a channel that the block **already animates** —
"Add another Rotate" — so one block can hold Rotate ×N in its Rotate lane,
each run its own bar, the way thebrief.ai's "Build yours" block stacks seven
Rotates in a row.

Today `addSegmentBuild` rewrites a present channel in place ("never doubled")
and `BuildChannelPanel` greys it out. That was a UX call, not a data limit: the
document is flat sparse keyframes and the lane view already draws N bars per
property when the keyframes cluster into N runs.

What actually blocks the thebrief behaviour is that clustering is
**continuity-based**: two runs of one property that butt against each other
read as one continuous motion → one long bar with many diamonds. And a run
appended after a block's end, with nothing else moving across the 1ms seam,
becomes a **separate block**. The second is fixed by one optional identity
marker (`block`); the first turns out not to need one — see §2.

## Decisions (from chat)

| Decision | Choice | Why |
| --- | --- | --- |
| Where the Nth run lands | **Playhead if inside the block and PAST the lane's last run; else right after the channel's last run** — never before an existing run | Two rules, but the append fallback is what makes "click Add 7 times" work without touching the playhead. Inserting ahead of a later run was tried live (2026-09-22) and merged into it: the new run ends at +step while the later one still starts at its old value, so the seam keeps moving and continuity draws one bar. Rewriting the later runs (rebase) was rejected — an add must never mutate what is already there. |
| What the Nth run animates | **The channel's EMPHASIS motion from the pose at its start** (spin / pulse / shake / blink / path loop), whatever slot the block is | Revised live 2026-09-22: the first design (cumulative +15° after a 360° spin) read as "no rotation". A further run on a channel is by nature an emphasis — it goes and comes back — which is also what keeps the seam still and the bars apart, and lets runs stack without moving the layout. The first run already did the entering/leaving. |
| Identity model | **One optional keyframe field, local semantics** — `block` bridge marker. (`seg` was designed, built and then REMOVED during implementation: a per-keyframe id cannot survive the span-join merge, where one keyframe serves two channels, and cumulative runs make it unnecessary — see §2.) | Not a global object — no registry, no ids to keep unique beyond "don't accidentally collide next to yourself". |
| First add of a channel | **Unchanged** — joins over the block's span (2026-09-21 behaviour) | Only the "already here" case is new. |

## 1. Document model — `src/lib/video-editor/timeline.ts`

```ts
export type MotionKeyframe = {
  // ...existing...
  /** Block identity: consecutive keyframes carrying the SAME `block` never
   *  split into two blocks, even when every property is still across the
   *  gap. Read only by block clustering (`trackSegments`) — lanes never
   *  bridge. A block is the union of its sub-motions, as in thebrief. */
  block?: string;
};
```

Additive and optional, exactly like `role`/`path` — every stored project and
template reads as before; no `version` bump.

Ids are opaque strings minted by `mintMotionId()` (`crypto.randomUUID()`
sliced short; tests pass a counter via an optional `mint` parameter on the
writers). They only need to differ from their neighbours' — a copy of a block
pasted elsewhere on the same track must not bridge into its source, which is
why every path that COPIES keyframes re-mints (see §4).

## 2. Clustering — `src/lib/video-editor/blocks.ts`

`trackSegments(track, opts?)` gains an internal option
`splitBetween?: (a: MotionKeyframe[], b: MotionKeyframe[]) => boolean | undefined`
consulted in `isBoundary(a, b)` BEFORE the continuity rule (`a`/`b` are the
keyframes at those two times — several when channels share a time):

- `true` → boundary; `false` → not a boundary; `undefined` → continuity rule.

Block level (default, no option): `false` when any keyframe at `a` and any at
`b` share a defined `block`; otherwise `undefined`.

Lane level (`propGroupSegments`): no marker — continuity only. Lanes
deliberately do NOT bridge on `block` (a lane bar spanning a still seam
would hide where one run ends and the next begins), and they need no split
marker either: an added run starts at exactly the value the previous run
ended on (§3), so the 1ms seam between two runs is still and continuity
splits them by itself. One clustering implementation, as the lane-drag spec
requires.

Accepted consequence: a block whose lane was dragged far away still reads as
one block spanning the still gap. A hand-inserted diamond inside that gap
splits it (both halves keep the same `block`; harmless — it is a bridge
marker, not a global id).

## 3. Writer — `src/lib/video-editor/presets.ts`

`addSegmentBuild(timeline, base, overlayId, segStart, segEnd, slot, channels,
atMs, mint?)` gains `atMs` (the playhead). Per channel:

**Channel not yet in the block** → today's behaviour: `writeBuildKeyframes`
over `[segStart, segEnd]`, merged additively. Now also stamped `block` (§3.1).

**Channel already in the block** ("add another"):

1. `lanes = propGroupSegments(track, groupOf(channel))` restricted to the
   block (`startMs ≥ segStart && endMs ≤ segEnd`); `last` = the latest.
2. `W = last.endMs − last.startMs` (uniform repeats), floored at
   `MIN_BLOCK_SPAN_MS`.
3. `start = atMs` when `last.endMs < atMs ≤ segEnd`; else
   `start = last.endMs + 1`. (Never before an existing run — see Decisions.)
4. `end = min(start + W, timeline.duration_ms)`.
5. If `end − start < EMPHASIS_MIN_WINDOW_MS` → return `null` (the adapter
   shows the existing "not enough room" toast).
6. `pose = sampleTimelinePropsAt(timeline, base, start).get(overlayId)`.
7. The channel's emphasis writer over `[start, end]` from `pose`
   (`writeRepeatKeyframes` = `writeBuildKeyframes("emphasis", …)`): Rotate =
   spin (+360 at `end − 1`, hold back at the start angle at `end`), Scale =
   pulse ×1.08, Move = shake ±0.008, Opacity = blink ×`BUILD_BLINK_OPACITY`,
   Path = loop. `label` = channel label, `block` = the block's id, no `role`.

Merged through `mergeBuildKeyframes` over `[start, end]` — it strips only the
written props inside the window, and step 3 guarantees the window holds no
other run of the same channel.

**Spin holds back (2026-09-22):** the spin emphasis writer now lands +360 at
1ms before its end and holds at the start angle on the last keyframe — a
360° jump nobody sees. Before, a spin left the layer at 360 numerically, so a
spin already sitting later (0 → 360) had rotation unwind 360 → 0 across the
seam: a visible reverse spin, and one fused bar. Applies to every spin
writer (preset and Build).

Several channels in one click (Rotate + Scale, both present) each compute
their own window.

### 3.1 Block id stamping

`addSegmentBuild` first ensures the block carries a `block` id: if no
keyframe in `[segStart, segEnd]` has one, every keyframe in the span is
stamped with a fresh id (precedent: `stampInRole` — same undo step, written
before the add). New keyframes take that id. `applyBuildChannels` (slot-chip
Build) mints `block` at write time so Build blocks carry identity from
birth; preset writers are untouched (they get an id lazily on first add).
`planSegmentBuild(track, segStart, segEnd, channel, atMs, durationMs)` is the
exported pure derivation of steps 1–5 (`{ startMs, endMs, placement, nth }`),
shared with the editor's analytics.

## 4. Carrying the ids

| Path | Change |
| --- | --- |
| `movePropGroup` (lane shift/stretch/diamond move) | the moving half is built from scratch today — it must carry `block` from the source keyframe (still dropping `label`/`role`) |
| Block ops (`shiftSegmentKeyframes`, `stretchSegmentKeyframes`, `deleteSegmentKeyframes`, `stripProps`, `pathEdit`) | already spread `...k` — nothing to do; a test pins it |
| `templates.ts` | `MotionTemplateKeyframe` gains `block?` (explicit whitelist); `normalizeTrackToTemplate` carries it; `bakeTemplateToTrack` re-mints |
| `motionClip.ts` (`cloneKeyframe` users: `pasteMotionClip`, `placeMotionClipAt`, `pasteSegmentsClip`) | re-mint on paste |
| New helper `remintMotionIds(keyframes, mint?)` in `timeline.ts` | maps every distinct `block` value to a fresh one consistently; used by both of the above |

## 5. UI — `BuildChannelPanel` (`MotionSourceTabs.tsx`) + `BlockTrackRow`

- A `present` channel is no longer `disabled`: subtitle "Add another", a
  plain tooltip (`hint`) "Rotate already animates in this block — adds
  another run at the playhead, or right after its last one". Picking it
  toggles like any card (`active` = selected).
- Exclusive partners stay disabled (Move present ⇒ Path unpickable, and vice
  versa) — two writers of x/y in one lane is still wrong.
- Panel note (block surface): "Add what animates — a channel already here gets
  another run at the playhead, or right after its last one."
- `TimelineDockProps.onAddSegmentBuild` and the adapter's `addSegmentBuild`
  pass the playhead through; the adapter returns `"ok" | "unavailable" |
  "no_room"` so the editor can show the room toast for a refused run.

## 6. Analytics

`kv_generator.motion_build_applied` gains `nth: number` (1 = first run of that
channel in the block) and `placement: "span" | "playhead" | "append"`.

## Testing

| File | Covers |
| --- | --- |
| `blocks.markers.test.ts` | `block` bridges a still gap; differing/missing `block` → continuity; lanes never bridge |
| `presets.addSegmentBuild.test.ts` | playhead vs append placement; `W` from last run; clamp against duration; `null` under min window; cumulative values per channel; block stamping of a preset block; first add unchanged; `planSegmentBuild` |
| `blocks.propGroupDrag.test.ts` | moving half carries `block` |
| `templates.test.ts`, `motionClip.test.ts` | ids carried and re-minted |
| `BuildChannelPanel.test.tsx`, `TimelineDock.segmentReplace.test.tsx`, `useMotionEditorState.build.test.ts` | present card pickable, partner still disabled, playhead reaches the handler, tri-state adapter result |

## Non-Goals

- Per-run parameters (angle, distance, duration) — defaults, tuned via lanes
- Reordering or merging runs; deleting a run stays the lane-segment delete
- Inserting a run BEFORE an existing run of the same lane — needs explicit
  per-property run identity (a model change), not value rebasing
- Changing the FIRST add (join over the block span)
- A persisted block/segment object — this is a marker on keyframes only
- A split marker for lanes: if a user hand-edits a run's values so the seam
  moves again, the two bars merge — the honest derived picture, same as every
  other bar in this editor
