# KV Motion — Build Sub-Segments (many runs of one channel per block) — Design Spec

> **Status:** approved (chat, 2026-09-22) — implement directly after the plan
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
becomes a **separate block**. Both are fixed by giving keyframes two optional
identity markers.

## Decisions (from chat)

| Decision | Choice | Why |
| --- | --- | --- |
| Where the Nth run lands | **Playhead if inside the block and free in that lane; else right after the channel's last run** | Two rules, but the append fallback is what makes "click Add 7 times" work without touching the playhead. |
| What the Nth run animates | **Cumulative from the pose at its start** | Rotate #2 starts where Rotate #1 landed and adds +15° again. No jump at the seam, works in any slot. |
| Identity model | **Two optional keyframe fields, local semantics** (`seg` split marker, `block` bridge marker) | `seg` alone cannot bridge a block; `block` alone cannot split adjacent bars. Neither is a global object — no registry, no ids to keep unique beyond "don't accidentally collide next to yourself". |
| First add of a channel | **Unchanged** — joins over the block's span (2026-09-21 behaviour) | Only the "already here" case is new. |

## 1. Document model — `src/lib/video-editor/timeline.ts`

```ts
export type MotionKeyframe = {
  // ...existing...
  /** Sub-motion identity: every keyframe ONE Build click writes shares it.
   *  Read only by lane clustering (`propGroupSegments`): two consecutive
   *  keyframes of a lane carrying DIFFERENT `seg` values always split into
   *  two bars, even when the property moves continuously across them. One
   *  side undefined (a hand-authored diamond) → the continuity rule decides. */
  seg?: string;
  /** Block identity: consecutive keyframes carrying the SAME `block` never
   *  split into two blocks, even when every property is still across the
   *  gap. Read only by block clustering (`trackSegments`). A block is the
   *  union of its sub-motions, as in thebrief. */
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

Lane level (`propGroupSegments`): after narrowing to the group's props,
`true` when the keyframes at `a` and at `b` both carry a defined `seg` and
they differ; otherwise fall through to the block-level `block` rule, then
continuity. One clustering implementation, as the lane-drag spec requires.

Accepted consequence: a block whose lane was dragged far away still reads as
one block spanning the still gap. A hand-inserted diamond inside that gap
splits it (both halves keep the same `block`; harmless — it is a bridge
marker, not a global id).

## 3. Writer — `src/lib/video-editor/presets.ts`

`addSegmentBuild(timeline, base, overlayId, segStart, segEnd, slot, channels,
atMs, mint?)` gains `atMs` (the playhead). Per channel:

**Channel not yet in the block** → today's behaviour: `writeBuildKeyframes`
over `[segStart, segEnd]`, merged additively. Now also stamped `seg` (one id
per click) and `block` (§3.1).

**Channel already in the block** ("add another"):

1. `lanes = propGroupSegments(track, groupOf(channel))` restricted to the
   block (`startMs ≥ segStart && endMs ≤ segEnd`); `last` = the latest.
2. `W = last.endMs − last.startMs` (uniform repeats), floored at
   `MIN_BLOCK_SPAN_MS`.
3. `start = atMs` when `segStart ≤ atMs ≤ segEnd` and no lane segment of that
   channel has `startMs ≤ atMs ≤ endMs`; else `start = last.endMs + 1`.
4. `end = min(start + W, nextLaneSegStart − 1, timeline.duration_ms)` where
   `nextLaneSegStart` is the first lane segment starting after `start`.
5. If `end − start < EMPHASIS_MIN_WINDOW_MS` → return `null` (the adapter
   shows the existing "not enough room" toast).
6. `pose = sampleTimelinePropsAt(timeline, base, start).get(overlayId)`.
7. Two keyframes, `easing: "linear"` at `start`, `"out"` at `end`, `label` =
   channel label, `seg` = fresh id (one per click), `block` = the block's id,
   no `role`. Values via `BUILD_STEP_WRITERS`:

| Channel | `start` | `end` |
| --- | --- | --- |
| Move | `x: pose.x` | `x: pose.x + SLIDE_OFFSET` |
| Path | `x,y: pose` | `x,y: pose.x + SLIDE_OFFSET, pose.y` + arc `path` (`PATH_ARC_DY`) |
| Rotate | `rotation: pose.rotation` | `+ BUILD_ROTATE_DEG` |
| Scale | `scale: pose.scale` | `× PULSE_SCALE` (the pulse constant) |
| Opacity | `opacity: pose.opacity` | `pose.opacity > base.opacity × BUILD_BLINK_OPACITY` ? `× BUILD_BLINK_OPACITY` : `base.opacity` (a toggle) |

Merged through `mergeBuildKeyframes` over `[start, end]` — it strips only the
written props inside the window, and step 4 guarantees the window holds no
other run of the same channel.

Several channels in one click (Rotate + Scale, both present) each compute
their own window; they share one `seg`.

### 3.1 Block id stamping

`addSegmentBuild` first ensures the block carries a `block` id: if no
keyframe in `[segStart, segEnd]` has one, every keyframe in the span is
stamped with a fresh id (precedent: `stampInRole` — same undo step, written
before the add). New keyframes take that id. `applyBuildChannels` (slot-chip
Build) mints `block` + `seg` at write time so Build blocks carry identity from
birth; preset writers are untouched (they get an id lazily on first add).

## 4. Carrying the ids

| Path | Change |
| --- | --- |
| `movePropGroup` (lane shift/stretch/diamond move) | the moving half is built from scratch today — it must carry `seg` and `block` from the source keyframe (still dropping `label`/`role`) |
| Block ops (`shiftSegmentKeyframes`, `stretchSegmentKeyframes`, `deleteSegmentKeyframes`, `stripProps`, `pathEdit`) | already spread `...k` — nothing to do; a test pins it |
| `templates.ts` | `MotionTemplateKeyframe` gains `seg?`/`block?` (explicit whitelist); `normalizeTrackToTemplate` carries them; `bakeTemplateToTrack` re-mints |
| `motionClip.ts` (`cloneKeyframe` users: `pasteMotionClip`, `placeMotionClipAt`, `pasteSegmentsClip`) | re-mint on paste |
| New helper `remintMotionIds(keyframes, mint?)` in `timeline.ts` | maps every distinct `seg`/`block` value to a fresh one consistently; used by both of the above |

## 5. UI — `BuildChannelPanel` (`MotionSourceTabs.tsx`) + `BlockTrackRow`

- A `present` channel is no longer `disabled`: drawn `active` with
  `disabledReason` replaced by a plain tooltip "Rotate already animates in
  this block — adds another run". Picking it toggles like any card.
- Exclusive partners stay disabled (Move present ⇒ Path unpickable, and vice
  versa) — two writers of x/y in one lane is still wrong.
- Panel note (block surface): "Add what animates — a channel already here gets
  another run at the playhead, or right after its last one."
- `TimelineDockProps.onAddSegmentBuild` and the adapter's `addSegmentBuild`
  pass the playhead through.

## 6. Analytics

`kv_generator.motion_build_applied` gains `nth: number` (1 = first run of that
channel in the block) and `placement: "span" | "playhead" | "append"`.

## Testing

| File | Covers |
| --- | --- |
| `blocks.test.ts` / `blocks.propGroups.test.ts` | `block` bridges a still gap; `seg` splits a continuous lane run; undefined on one side → continuity; block level ignores `seg` |
| `presets.addSegmentBuild.test.ts` | playhead vs append placement; `W` from last run; clamp against next run and duration; `null` under min window; cumulative values per channel; one `seg` per click; block stamping of a preset block; first add unchanged |
| `blocks.propGroupDrag.test.ts` | moving half carries `seg`/`block` |
| `templates.test.ts`, `motionClip.test.ts` | ids carried and re-minted |
| `TimelineDock.buildtab.test.tsx` | present card pickable, partner still disabled, playhead reaches the handler |

## Non-Goals

- Per-run parameters (angle, distance, duration) — defaults, tuned via lanes
- Reordering or merging runs; deleting a run stays the lane-segment delete
- Changing the FIRST add (join over the block span)
- A persisted block/segment object — these are markers on keyframes only
