# KV Motion Segment Multi-Select Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user ⌘/⇧-click several bars (block bars and Scale/Rotation/Opacity/Position lane bars) on ONE layer of the Motion dock, then copy them to another layer at the same times, delete them, or drag them together — each as one undo step.

**Architecture:** A segment is a derived span, so the selection is a list of `{trackId, group, startMs, endMs}` refs re-resolved against `trackSegments`/`propGroupSegments` after every document change. The clipboard grows a `"segments"` scope (clip v2) whose items keep absolute source times and only their group's props; paste is per-item `placeMotionClipAt` + the already prop-aware `mergeKeyframesIntoTrack`. Bulk delete/shift reduce the existing per-segment writers in `blocks.ts` into one `push()`.

**Tech Stack:** Next.js 16 / React 19 / TypeScript, Zustand clip store, `bun test` (jsdom + jest-dom preloaded via bunfig; `screen` is broken — use `within(document.body)`), ESLint + Prettier.

**Spec:** `docs/superpowers/specs/2026-09-21-kv-motion-segment-multi-select-design.md`

## Global Constraints

- Web only. Branch `feature/daffa/vc-kv-motion-segment-multi-select` from `develop` in `web/`.
- Every bulk action = exactly one `push()`; a refused/empty bulk pushes nothing.
- One `trackId` per selection; segment selection and layer multi-select (`selectedTrackIds`) are mutually exclusive.
- Paste of a `"segments"` clip lands at **source times**; the playhead is ignored; slot/block menus hide Paste for that scope.
- `MOTION_CLIP_VERSION` becomes `2`; `version: 1` clips with scope `"track"`/`"segment"` must still paste.
- Copy/labels: "Paste N segments", "Copy N segments", "Delete N segments", lane single-bar items "Copy Scale" / "Delete Scale" (capitalised group label); dock hint "⌘-click bars to select several".
- Run tests with `bun test <file>` (never a directory — memory: a directory run eats 26 GB). Keep every test file under ~40 KB.
- Commit after every task with `feat(web): …` / `test(web): …`, trailer `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- Analytics events are part of done (memory `feedback_web_features_need_posthog_events`).

---

## File map

| File | Responsibility |
| --- | --- |
| `web/src/lib/video-editor/segmentSelection.ts` (new) | `SegmentRef` + pure helpers: `sameRef`, `laneSegments`, `pruneSegmentRefs`, `rangeSegmentRefs`, `keyframesOfRef`, `selectionShiftBounds`, `shiftSegmentRefs`, `deleteSegmentRefs` |
| `web/src/lib/video-editor/blocks.ts` | + `deletePropGroupKeyframes` |
| `web/src/lib/video-editor/motionClip.ts` | clip v2: `MotionClipSegment`, scope `"segments"`, `captureSegmentsClip`, `pasteSegmentsClip`, v1 acceptance |
| `web/src/components/studio/kv-generator/motion/useMotionEditorState.ts` | `selectedSegments`, `selectSegment`, prune effect, `copySegments`, `deleteSegments`, `shiftSegments`, `pasteMotionInto` `"segments"` branch |
| `web/src/lib/analytics/kv-generator-events.ts` | scope/count fields + two new events |
| `web/src/components/video-editor/BlockTrackRow.tsx` | `selectedSegments`/`onSelectSegment`/`onShiftSelection`/`selectionShiftWalls` props; SegmentBar click-with-mode, segment-selected visual, N-segments menu, live fan-out to selected bars |
| `web/src/components/video-editor/PropSegmentBar.tsx` | click-with-mode, `segmentSelected`, `overrideSpan`, context menu |
| `web/src/components/video-editor/TimelineDock.tsx` | pass-through props + hint |
| `web/src/components/studio/kv-generator/motion/TrackPresetMenu.tsx`, `MotionPanelHeader.tsx` | "Paste N segments" label |
| `web/src/components/studio/kv-generator/motion/motionClipboardKeys.ts` | `copySegments` dep |
| `web/src/components/studio/kv-generator/motion/KvMotionEditor.tsx` | wiring, toasts, keyboard, analytics |

All paths below are relative to `web/`.

---

### Task 1: `segmentSelection.ts` — refs, lane lookup, prune, range, keyframesOfRef

**Files:**
- Create: `src/lib/video-editor/segmentSelection.ts`
- Test: `src/lib/video-editor/segmentSelection.test.ts`

**Interfaces:**
- Consumes: `trackSegments`, `propGroupSegments`, `PROP_LABEL_GROUPS`, `PropGroupKey`, `TrackSegment` from `./blocks`; `MotionTimeline`, `MotionTrack`, `MotionKeyframe`, `MotionProps` from `./timeline`.
- Produces:
  ```ts
  export type SegmentRef = { trackId: string; group: PropGroupKey | null; startMs: number; endMs: number };
  export function sameRef(a: SegmentRef, b: SegmentRef): boolean;
  export function findOverlayTrack(timeline: MotionTimeline, trackId: string): MotionTrack | undefined;
  export function laneSegments(timeline: MotionTimeline, trackId: string, group: PropGroupKey | null): TrackSegment[];
  export function pruneSegmentRefs(timeline: MotionTimeline, refs: SegmentRef[]): SegmentRef[];
  export function rangeSegmentRefs(timeline: MotionTimeline, anchor: SegmentRef, ref: SegmentRef): SegmentRef[];
  export function keyframesOfRef(track: MotionTrack, ref: SegmentRef): MotionKeyframe[];
  ```

- [ ] **Step 1: Write the failing tests**

```ts
// src/lib/video-editor/segmentSelection.test.ts
import { describe, expect, it } from "bun:test";
import type { MotionTimeline, MotionTrack } from "./timeline";
import {
  keyframesOfRef,
  laneSegments,
  pruneSegmentRefs,
  rangeSegmentRefs,
  sameRef,
  type SegmentRef,
} from "./segmentSelection";

// Two scale pulses (0–400, 1000–1400) and one opacity fade (2000–2400).
// Scale pulse #1 and the fade share nothing; the 1000ms keyframe carries
// BOTH scale and opacity so that a lane narrowing has something to drop.
const track: MotionTrack = {
  kind: "overlay",
  overlay_id: "ov1",
  keyframes: [
    { t_ms: 0, props: { scale: 1 }, easing: "linear" },
    { t_ms: 200, props: { scale: 1.2 }, easing: "out" },
    { t_ms: 400, props: { scale: 1 }, easing: "out" },
    { t_ms: 1000, props: { scale: 1, opacity: 1 }, easing: "linear" },
    { t_ms: 1200, props: { scale: 1.2 }, easing: "out" },
    { t_ms: 1400, props: { scale: 1 }, easing: "out" },
    { t_ms: 2000, props: { opacity: 1 }, easing: "linear" },
    { t_ms: 2400, props: { opacity: 0 }, easing: "out" },
  ],
};
const timeline: MotionTimeline = {
  version: 1,
  duration_ms: 5000,
  fps: 30,
  tracks: [track],
};
const ref = (
  startMs: number,
  endMs: number,
  group: SegmentRef["group"] = "scale"
): SegmentRef => ({ trackId: "ov1", group, startMs, endMs });

describe("laneSegments", () => {
  it("returns the scale lane's two pulses and the opacity lane's fade", () => {
    expect(laneSegments(timeline, "ov1", "scale")).toEqual([
      { startMs: 0, endMs: 400 },
      { startMs: 1000, endMs: 1400 },
    ]);
    expect(laneSegments(timeline, "ov1", "opacity")).toEqual([
      { startMs: 1000, endMs: 1000 },
      { startMs: 2000, endMs: 2400 },
    ]);
  });
  it("group null = the block bars", () => {
    expect(laneSegments(timeline, "ov1", null).length).toBeGreaterThan(0);
  });
  it("is empty for an unknown track", () => {
    expect(laneSegments(timeline, "nope", "scale")).toEqual([]);
  });
});

describe("pruneSegmentRefs", () => {
  it("keeps refs whose span still exists and drops the rest, preserving order", () => {
    const refs = [ref(1000, 1400), ref(0, 400), ref(0, 401)];
    expect(pruneSegmentRefs(timeline, refs)).toEqual([
      ref(1000, 1400),
      ref(0, 400),
    ]);
  });
  it("returns the SAME array when nothing was dropped", () => {
    const refs = [ref(0, 400)];
    expect(pruneSegmentRefs(timeline, refs)).toBe(refs);
  });
});

describe("rangeSegmentRefs", () => {
  it("returns every segment between anchor and ref in the same lane, in time order", () => {
    expect(rangeSegmentRefs(timeline, ref(1000, 1400), ref(0, 400))).toEqual([
      ref(0, 400),
      ref(1000, 1400),
    ]);
  });
  it("degrades to [ref] when the anchor is in another lane", () => {
    expect(
      rangeSegmentRefs(timeline, ref(2000, 2400, "opacity"), ref(0, 400))
    ).toEqual([ref(0, 400)]);
  });
});

describe("keyframesOfRef", () => {
  it("narrows a lane ref to its group's props and drops keyframes left empty", () => {
    expect(keyframesOfRef(track, ref(1000, 1400))).toEqual([
      { t_ms: 1000, props: { scale: 1 }, easing: "linear" },
      { t_ms: 1200, props: { scale: 1.2 }, easing: "out" },
      { t_ms: 1400, props: { scale: 1 }, easing: "out" },
    ]);
    expect(keyframesOfRef(track, ref(2000, 2400))).toEqual([]);
  });
  it("keeps every prop for a block ref", () => {
    expect(keyframesOfRef(track, ref(1000, 1400, null))[0]).toEqual({
      t_ms: 1000,
      props: { scale: 1, opacity: 1 },
      easing: "linear",
    });
  });
});

describe("sameRef", () => {
  it("compares all four fields", () => {
    expect(sameRef(ref(0, 400), ref(0, 400))).toBe(true);
    expect(sameRef(ref(0, 400), ref(0, 400, null))).toBe(false);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd web && bun test src/lib/video-editor/segmentSelection.test.ts`
Expected: FAIL — `Cannot find module "./segmentSelection"`.

- [ ] **Step 3: Implement**

```ts
// src/lib/video-editor/segmentSelection.ts
import {
  PROP_LABEL_GROUPS,
  propGroupSegments,
  trackSegments,
  type PropGroupKey,
  type TrackSegment,
} from "./blocks";
import type {
  MotionKeyframe,
  MotionProps,
  MotionTimeline,
  MotionTrack,
} from "./timeline";

/** One selected bar of the Motion dock. A segment is a DERIVED span (see
 *  `trackSegments` / `propGroupSegments`), not an entity, so this is its
 *  identity: the track, which lane (`null` = the block bar, every prop in
 *  the span) and the exact span the lane currently draws. A ref that no
 *  longer matches a drawn segment is stale — `pruneSegmentRefs`. */
export type SegmentRef = {
  trackId: string;
  group: PropGroupKey | null;
  startMs: number;
  endMs: number;
};

export function sameRef(a: SegmentRef, b: SegmentRef): boolean {
  return (
    a.trackId === b.trackId &&
    a.group === b.group &&
    a.startMs === b.startMs &&
    a.endMs === b.endMs
  );
}

export function findOverlayTrack(
  timeline: MotionTimeline,
  trackId: string
): MotionTrack | undefined {
  return timeline.tracks.find(
    (t) => t.kind === "overlay" && t.overlay_id === trackId
  );
}

/** The segments one lane currently draws — the block row for `null`, else
 *  that property group's lane. The one source of truth for range-select and
 *  for pruning, so neither can drift from what the dock renders. */
export function laneSegments(
  timeline: MotionTimeline,
  trackId: string,
  group: PropGroupKey | null
): TrackSegment[] {
  const track = findOverlayTrack(timeline, trackId);
  if (!track) return [];
  return group === null
    ? trackSegments(track)
    : propGroupSegments(track, group);
}

function refExists(timeline: MotionTimeline, ref: SegmentRef): boolean {
  return laneSegments(timeline, ref.trackId, ref.group).some(
    (s) => s.startMs === ref.startMs && s.endMs === ref.endMs
  );
}

/** Drop refs whose span is no longer drawn. Returns the input array itself
 *  when nothing was dropped, so a `setState` with the result is a no-op
 *  render-wise. */
export function pruneSegmentRefs(
  timeline: MotionTimeline,
  refs: SegmentRef[]
): SegmentRef[] {
  const kept = refs.filter((r) => refExists(timeline, r));
  return kept.length === refs.length ? refs : kept;
}

/** Every segment in `ref`'s lane between `anchor` and `ref` inclusive, in
 *  time order. An anchor in another lane (or track) has no "between", so
 *  the range collapses to `[ref]`. */
export function rangeSegmentRefs(
  timeline: MotionTimeline,
  anchor: SegmentRef,
  ref: SegmentRef
): SegmentRef[] {
  if (anchor.trackId !== ref.trackId || anchor.group !== ref.group) {
    return [ref];
  }
  const lo = Math.min(anchor.startMs, ref.startMs);
  const hi = Math.max(anchor.startMs, ref.startMs);
  return laneSegments(timeline, ref.trackId, ref.group)
    .filter((s) => s.startMs >= lo && s.startMs <= hi)
    .map((s) => ({
      trackId: ref.trackId,
      group: ref.group,
      startMs: s.startMs,
      endMs: s.endMs,
    }));
}

/** The keyframes a ref OWNS: every keyframe inside its span, narrowed to
 *  its group's props (all props for a block ref). Keyframes left with no
 *  props are dropped — the same narrowing `propGroupSegments` draws the
 *  lane from. Deep-copies props; never mutates `track`. */
export function keyframesOfRef(
  track: MotionTrack,
  ref: SegmentRef
): MotionKeyframe[] {
  const keys: readonly (keyof MotionProps)[] =
    ref.group === null
      ? (["x", "y", "scale", "rotation", "opacity"] as const)
      : (PROP_LABEL_GROUPS.find((g) => g.label === ref.group)?.keys ?? []);
  return track.keyframes
    .filter((k) => k.t_ms >= ref.startMs && k.t_ms <= ref.endMs)
    .map((k) => {
      const props: Partial<MotionProps> = {};
      for (const key of keys) {
        if (k.props[key] !== undefined) props[key] = k.props[key];
      }
      return { ...k, props };
    })
    .filter((k) => Object.keys(k.props).length > 0);
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd web && bun test src/lib/video-editor/segmentSelection.test.ts`
Expected: all pass. If `laneSegments(…, "opacity")` differs from the expected `[{1000,1000},{2000,2400}]`, print the actual value and fix the TEST's expectation only if `propGroupSegments` genuinely clusters differently — never change `laneSegments` to special-case it.

- [ ] **Step 5: Lint and commit**

```bash
cd web && bunx eslint src/lib/video-editor/segmentSelection.ts src/lib/video-editor/segmentSelection.test.ts --fix
git add src/lib/video-editor/segmentSelection.ts src/lib/video-editor/segmentSelection.test.ts
git commit -m "feat(web): KV Motion — SegmentRef + lane/prune/range/keyframesOfRef helpers

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: `deletePropGroupKeyframes` in `blocks.ts`

**Files:**
- Modify: `src/lib/video-editor/blocks.ts` (append after `deleteSegmentKeyframes`, ~line 935)
- Test: `src/lib/video-editor/blocks.deletePropGroup.test.ts`

**Interfaces:**
- Produces: `export function deletePropGroupKeyframes(timeline: MotionTimeline, overlayId: string, group: PropGroupKey, segStartMs: number, segEndMs: number): MotionTimeline`

- [ ] **Step 1: Failing test**

```ts
// src/lib/video-editor/blocks.deletePropGroup.test.ts
import { describe, expect, it } from "bun:test";
import type { MotionTimeline } from "./timeline";
import { deletePropGroupKeyframes, propGroupSegments } from "./blocks";

const timeline: MotionTimeline = {
  version: 1,
  duration_ms: 5000,
  fps: 30,
  tracks: [
    {
      kind: "overlay",
      overlay_id: "ov1",
      keyframes: [
        { t_ms: 1000, props: { scale: 1, opacity: 1 }, easing: "linear" },
        { t_ms: 1200, props: { scale: 1.2 }, easing: "out" },
        { t_ms: 1400, props: { scale: 1 }, easing: "out" },
        { t_ms: 2000, props: { opacity: 0 }, easing: "out" },
      ],
    },
  ],
};

describe("deletePropGroupKeyframes", () => {
  it("strips only the group's props in the span and keeps the other group's value on a shared keyframe", () => {
    const next = deletePropGroupKeyframes(timeline, "ov1", "scale", 1000, 1400);
    const kfs = next.tracks[0]!.keyframes;
    expect(kfs).toEqual([
      { t_ms: 1000, props: { opacity: 1 }, easing: "linear" },
      { t_ms: 2000, props: { opacity: 0 }, easing: "out" },
    ]);
    expect(propGroupSegments(next.tracks[0]!, "scale")).toEqual([]);
  });

  it("is a no-op (same reference) when the span is not a current lane segment", () => {
    expect(deletePropGroupKeyframes(timeline, "ov1", "scale", 1000, 1401)).toBe(timeline);
  });

  it("drops the track when nothing is left", () => {
    const only = { ...timeline, tracks: [{ ...timeline.tracks[0]!, keyframes: timeline.tracks[0]!.keyframes.slice(1, 3) }] };
    const next = deletePropGroupKeyframes(only, "ov1", "scale", 1200, 1400);
    expect(next.tracks).toEqual([]);
  });
});
```

- [ ] **Step 2: Run — expect FAIL** (`deletePropGroupKeyframes is not exported`).

Run: `cd web && bun test src/lib/video-editor/blocks.deletePropGroup.test.ts`

- [ ] **Step 3: Implement** (append to `blocks.ts`)

```ts
/** Delete ONE property group's lane segment: strip that group's props from
 *  every keyframe in `[segStartMs, segEndMs]`, drop keyframes left with no
 *  props, drop the track when it has none. Other groups' values on a shared
 *  keyframe survive — the lane-level twin of `deleteSegmentKeyframes`. Same
 *  stale-span guard: a no-op unless the span is a CURRENT lane segment. */
export function deletePropGroupKeyframes(
  timeline: MotionTimeline,
  overlayId: string,
  group: PropGroupKey,
  segStartMs: number,
  segEndMs: number
): MotionTimeline {
  const track = findOverlayTrack(timeline, overlayId);
  if (!track) return timeline;
  const isReal = propGroupSegments(track, group).some(
    (s) => s.startMs === segStartMs && s.endMs === segEndMs
  );
  if (!isReal) return timeline;
  const keys = PROP_LABEL_GROUPS.find((g) => g.label === group)?.keys ?? [];

  const tracks = timeline.tracks.flatMap((t) => {
    if (t.kind !== "overlay" || t.overlay_id !== overlayId) return [t];
    const keyframes = t.keyframes
      .map((k) => {
        if (k.t_ms < segStartMs || k.t_ms > segEndMs) return k;
        const props: Partial<MotionProps> = { ...k.props };
        for (const key of keys) delete props[key];
        return { ...k, props };
      })
      .filter((k) => Object.keys(k.props).length > 0);
    return keyframes.length === 0 ? [] : [{ ...t, keyframes }];
  });
  return { ...timeline, tracks };
}
```
`findOverlayTrack` already exists in `blocks.ts` (used by `shiftSegmentKeyframes`); `MotionProps` is imported there already — verify with `grep -n "MotionProps" src/lib/video-editor/blocks.ts | head -1` and add the type import if missing.

- [ ] **Step 4: Run — expect PASS.** Also run `bun test src/lib/video-editor/blocks.test.ts` to confirm nothing else moved.

- [ ] **Step 5: Commit**

```bash
git add src/lib/video-editor/blocks.ts src/lib/video-editor/blocks.deletePropGroup.test.ts
git commit -m "feat(web): KV Motion — deletePropGroupKeyframes (lane-scoped delete)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Bulk shift/delete over refs in `segmentSelection.ts`

**Files:**
- Modify: `src/lib/video-editor/segmentSelection.ts`
- Test: `src/lib/video-editor/segmentSelection.bulk.test.ts`

**Interfaces:**
- Consumes: `shiftSegmentKeyframes`, `shiftPropGroupKeyframes`, `deleteSegmentKeyframes`, `deletePropGroupKeyframes` (Task 2) from `./blocks`.
- Produces:
  ```ts
  export function selectionShiftBounds(timeline, refs: SegmentRef[]): { minDelta: number; maxDelta: number } | null;
  export function shiftSegmentRefs(timeline, refs: SegmentRef[], deltaMs: number): { timeline: MotionTimeline; refs: SegmentRef[]; delta: number };
  export function deleteSegmentRefs(timeline, refs: SegmentRef[]): MotionTimeline;
  ```

- [ ] **Step 1: Failing tests**

```ts
// src/lib/video-editor/segmentSelection.bulk.test.ts
import { describe, expect, it } from "bun:test";
import type { MotionTimeline } from "./timeline";
import {
  deleteSegmentRefs,
  laneSegments,
  selectionShiftBounds,
  shiftSegmentRefs,
  type SegmentRef,
} from "./segmentSelection";

// Three scale pulses on one lane: 0–400, 1000–1400, 2000–2400. Duration 3000.
const timeline: MotionTimeline = {
  version: 1,
  duration_ms: 3000,
  fps: 30,
  tracks: [
    {
      kind: "overlay",
      overlay_id: "ov1",
      keyframes: [0, 1000, 2000].flatMap((s) => [
        { t_ms: s, props: { scale: 1 }, easing: "linear" as const },
        { t_ms: s + 200, props: { scale: 1.2 }, easing: "out" as const },
        { t_ms: s + 400, props: { scale: 1 }, easing: "out" as const },
      ]),
    },
  ],
};
const r = (startMs: number, endMs: number): SegmentRef => ({
  trackId: "ov1",
  group: "scale",
  startMs,
  endMs,
});

describe("selectionShiftBounds", () => {
  it("walls against the nearest segment OUTSIDE the selection and the clip edges", () => {
    // #1 and #2 selected: left wall 0 (edge), right wall #3.start − 1 = 1999.
    expect(selectionShiftBounds(timeline, [r(0, 400), r(1000, 1400)])).toEqual({
      minDelta: 0,
      maxDelta: 1999 - 1400,
    });
    // #1 and #3 selected: #2 (unselected) walls both — #1 may move right by
    // 599 (to 999), #3 may move left by 599 (to 1401): min(-599) max(599).
    expect(selectionShiftBounds(timeline, [r(0, 400), r(2000, 2400)])).toEqual({
      minDelta: -599,
      maxDelta: 599,
    });
  });
  it("is null for an empty selection", () => {
    expect(selectionShiftBounds(timeline, [])).toBeNull();
  });
});

describe("shiftSegmentRefs", () => {
  it("moves every ref by the clamped delta and returns the new refs", () => {
    const out = shiftSegmentRefs(timeline, [r(0, 400), r(1000, 1400)], 10_000);
    expect(out.delta).toBe(599);
    expect(out.refs).toEqual([r(599, 999), r(1599, 1999)]);
    expect(laneSegments(out.timeline, "ov1", "scale")).toEqual([
      { startMs: 599, endMs: 999 },
      { startMs: 1599, endMs: 1999 },
      { startMs: 2000, endMs: 2400 },
    ]);
  });
  it("moves adjacent selected refs left without one blocking the other", () => {
    const out = shiftSegmentRefs(timeline, [r(1000, 1400), r(2000, 2400)], -10_000);
    expect(out.delta).toBe(-599);
    expect(laneSegments(out.timeline, "ov1", "scale")).toEqual([
      { startMs: 0, endMs: 400 },
      { startMs: 401, endMs: 801 },
      { startMs: 1401, endMs: 1801 },
    ]);
  });
  it("returns the same timeline for delta 0", () => {
    const out = shiftSegmentRefs(timeline, [r(0, 400)], 0);
    expect(out.timeline).toBe(timeline);
  });
});

describe("deleteSegmentRefs", () => {
  it("removes every ref's keyframes in one pass", () => {
    const next = deleteSegmentRefs(timeline, [r(0, 400), r(2000, 2400)]);
    expect(laneSegments(next, "ov1", "scale")).toEqual([{ startMs: 1000, endMs: 1400 }]);
  });
  it("handles block refs too", () => {
    const next = deleteSegmentRefs(timeline, [
      { trackId: "ov1", group: null, startMs: 1000, endMs: 1400 },
    ]);
    expect(laneSegments(next, "ov1", null).map((s) => s.startMs)).toEqual([0, 2000]);
  });
});
```

- [ ] **Step 2: Run — expect FAIL** (missing exports).

- [ ] **Step 3: Implement** (append to `segmentSelection.ts`; add the imports from `./blocks`: `deletePropGroupKeyframes`, `deleteSegmentKeyframes`, `shiftPropGroupKeyframes`, `shiftSegmentKeyframes`)

```ts
/** How far the whole selection may move: each ref is walled by its nearest
 *  lane neighbour that is NOT itself selected (±1 ms clearance, the same rule
 *  `shiftSegmentKeyframes` / `shiftPropGroupKeyframes` use) or the clip
 *  edges; the selection's bound is the tightest of them. `null` when empty. */
export function selectionShiftBounds(
  timeline: MotionTimeline,
  refs: SegmentRef[]
): { minDelta: number; maxDelta: number } | null {
  if (refs.length === 0) return null;
  let minDelta = -Infinity;
  let maxDelta = Infinity;
  for (const ref of refs) {
    const lane = laneSegments(timeline, ref.trackId, ref.group);
    const i = lane.findIndex(
      (s) => s.startMs === ref.startMs && s.endMs === ref.endMs
    );
    if (i === -1) continue;
    const selectedInLane = (s: TrackSegment) =>
      refs.some(
        (o) =>
          o.trackId === ref.trackId &&
          o.group === ref.group &&
          o.startMs === s.startMs &&
          o.endMs === s.endMs
      );
    let prev: TrackSegment | undefined;
    for (let j = i - 1; j >= 0; j--) {
      if (!selectedInLane(lane[j]!)) { prev = lane[j]; break; }
    }
    let next: TrackSegment | undefined;
    for (let j = i + 1; j < lane.length; j++) {
      if (!selectedInLane(lane[j]!)) { next = lane[j]; break; }
    }
    const wallMin = prev ? prev.endMs + 1 : 0;
    const wallMax = next ? next.startMs - 1 : timeline.duration_ms;
    minDelta = Math.max(minDelta, wallMin - ref.startMs);
    maxDelta = Math.min(maxDelta, wallMax - ref.endMs);
  }
  if (!Number.isFinite(minDelta) || !Number.isFinite(maxDelta)) return null;
  return { minDelta, maxDelta };
}

/** Shift every ref by `deltaMs` clamped to `selectionShiftBounds`. Applied
 *  furthest-first in the direction of travel (descending start for a
 *  positive delta, ascending for a negative one) so a ref never bumps into
 *  a sibling that hasn't moved yet — the per-ref writers clamp against
 *  immediate neighbours. Returns the shifted refs so the caller can keep
 *  the selection on the moved bars. */
export function shiftSegmentRefs(
  timeline: MotionTimeline,
  refs: SegmentRef[],
  deltaMs: number
): { timeline: MotionTimeline; refs: SegmentRef[]; delta: number } {
  const bounds = selectionShiftBounds(timeline, refs);
  if (!bounds) return { timeline, refs, delta: 0 };
  const delta = Math.round(
    Math.min(bounds.maxDelta, Math.max(bounds.minDelta, deltaMs))
  );
  if (delta === 0) return { timeline, refs, delta: 0 };
  const ordered = [...refs].sort((a, b) =>
    delta > 0 ? b.startMs - a.startMs : a.startMs - b.startMs
  );
  let tl = timeline;
  for (const ref of ordered) {
    tl =
      ref.group === null
        ? shiftSegmentKeyframes(tl, ref.trackId, ref.startMs, ref.endMs, delta)
        : shiftPropGroupKeyframes(
            tl,
            ref.trackId,
            ref.group,
            ref.startMs,
            ref.endMs,
            delta
          );
  }
  const moved = refs.map((r) => ({
    ...r,
    startMs: r.startMs + delta,
    endMs: r.endMs + delta,
  }));
  return { timeline: tl, refs: moved, delta };
}

/** Delete every ref's keyframes. Later refs first so an earlier delete never
 *  reshapes a later ref's span before it is looked up. */
export function deleteSegmentRefs(
  timeline: MotionTimeline,
  refs: SegmentRef[]
): MotionTimeline {
  const ordered = [...refs].sort((a, b) => b.startMs - a.startMs);
  let tl = timeline;
  for (const ref of ordered) {
    tl =
      ref.group === null
        ? deleteSegmentKeyframes(tl, ref.trackId, ref.startMs, ref.endMs)
        : deletePropGroupKeyframes(
            tl,
            ref.trackId,
            ref.group,
            ref.startMs,
            ref.endMs
          );
  }
  return tl;
}
```

- [ ] **Step 4: Run — expect PASS.** If the "adjacent left" case lands on `401` vs `400`: the lane writers' 1 ms collision step is real behaviour; assert what the writer produces after confirming by reading `movePropGroup` — do not loosen to `toBeGreaterThan`.

- [ ] **Step 5: Lint + commit**

```bash
cd web && bunx eslint src/lib/video-editor/segmentSelection.ts src/lib/video-editor/segmentSelection.bulk.test.ts --fix
git add src/lib/video-editor/segmentSelection.ts src/lib/video-editor/segmentSelection.bulk.test.ts
git commit -m "feat(web): KV Motion — bulk shift/delete over segment refs, tightest-wall clamp

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Clip v2 — `"segments"` scope in `motionClip.ts`

**Files:**
- Modify: `src/lib/video-editor/motionClip.ts`
- Test: `src/lib/video-editor/motionClip.segments.test.ts`

**Interfaces:**
- Produces:
  ```ts
  export const MOTION_CLIP_VERSION = 2;
  export type MotionClipSegment = { group: PropGroupKey | null; startMs: number; endMs: number; keyframes: MotionKeyframe[]; body: MotionTemplateBody };
  export type MotionClip =
    | { version: 1 | 2; scope: "track" | "segment"; body: MotionTemplateBody; keyframes: MotionKeyframe[]; source_duration_ms: number }
    | { version: 2; scope: "segments"; segments: MotionClipSegment[]; source_duration_ms: number };
  export function captureSegmentsClip(track: MotionTrack, base: MotionProps, sourceDurationMs: number, refs: SegmentRef[]): MotionClip | null;
  export function pasteSegmentsClip(clip: MotionClip, overlayId: string, targetBase: MotionProps, durationMs: number, mode: PasteMotionMode): { segment: MotionClipSegment; keyframes: MotionKeyframe[] }[] | null;
  ```
  `captureMotionClip` keeps writing `version: MOTION_CLIP_VERSION` (now 2). `pasteMotionClip` accepts `version === 1 || version === 2` and returns `null` for `scope: "segments"` (callers use `pasteSegmentsClip`).

- [ ] **Step 1: Failing tests**

```ts
// src/lib/video-editor/motionClip.segments.test.ts
import { describe, expect, it } from "bun:test";
import type { MotionProps, MotionTrack } from "./timeline";
import type { SegmentRef } from "./segmentSelection";
import {
  captureMotionClip,
  captureSegmentsClip,
  MOTION_CLIP_VERSION,
  pasteMotionClip,
  pasteSegmentsClip,
} from "./motionClip";

const base: MotionProps = { x: 0.1, y: 0.2, scale: 1, rotation: 0, opacity: 1 };
const track: MotionTrack = {
  kind: "overlay",
  overlay_id: "ov1",
  keyframes: [
    { t_ms: 1000, props: { scale: 1, opacity: 1 }, easing: "linear" },
    { t_ms: 1200, props: { scale: 1.2 }, easing: "out" },
    { t_ms: 1400, props: { scale: 1 }, easing: "out" },
    { t_ms: 3000, props: { scale: 1 }, easing: "linear" },
    { t_ms: 3200, props: { scale: 1.3 }, easing: "out" },
    { t_ms: 3400, props: { scale: 1 }, easing: "out" },
  ],
};
const scaleRef = (s: number, e: number): SegmentRef => ({ trackId: "ov1", group: "scale", startMs: s, endMs: e });

describe("captureSegmentsClip", () => {
  it("keeps absolute source times and only the group's props", () => {
    const clip = captureSegmentsClip(track, base, 5000, [scaleRef(1000, 1400), scaleRef(3000, 3400)]);
    expect(clip?.scope).toBe("segments");
    if (clip?.scope !== "segments") throw new Error("scope");
    expect(clip.version).toBe(2);
    expect(clip.segments.map((s) => s.startMs)).toEqual([1000, 3000]);
    expect(clip.segments[0]!.keyframes).toEqual([
      { t_ms: 1000, props: { scale: 1 }, easing: "linear" },
      { t_ms: 1200, props: { scale: 1.2 }, easing: "out" },
      { t_ms: 1400, props: { scale: 1 }, easing: "out" },
    ]);
  });
  it("dedupes a keyframe owned by both a block ref and a lane ref inside it", () => {
    const clip = captureSegmentsClip(track, base, 5000, [
      { trackId: "ov1", group: null, startMs: 1000, endMs: 1400 },
      scaleRef(1000, 1400),
    ]);
    if (clip?.scope !== "segments") throw new Error("scope");
    const all = clip.segments.flatMap((s) => s.keyframes);
    const scaleAt1000 = all.filter((k) => k.t_ms === 1000 && k.props.scale !== undefined);
    expect(scaleAt1000).toHaveLength(1);
    // the block ref still owns opacity at 1000
    expect(all.some((k) => k.t_ms === 1000 && k.props.opacity === 1)).toBe(true);
  });
  it("is null when the refs own nothing", () => {
    expect(captureSegmentsClip(track, base, 5000, [{ trackId: "ov1", group: "opacity", startMs: 3000, endMs: 3400 }])).toBeNull();
  });
});

describe("pasteSegmentsClip", () => {
  const clip = captureSegmentsClip(track, base, 5000, [scaleRef(1000, 1400), scaleRef(3000, 3400)])!;
  it("lands every segment at its source time (exact)", () => {
    const out = pasteSegmentsClip(clip, "ov2", base, 5000, "exact")!;
    expect(out.map((o) => o.keyframes.map((k) => k.t_ms))).toEqual([[1000, 1200, 1400], [3000, 3200, 3400]]);
    expect(out[1]!.keyframes[1]!.props.scale).toBe(1.3);
  });
  it("follow re-bakes against the target rest pose", () => {
    const bigger: MotionProps = { ...base, scale: 2 };
    const out = pasteSegmentsClip(clip, "ov2", bigger, 5000, "follow")!;
    expect(out[0]!.keyframes[1]!.props.scale).toBeCloseTo(2.4, 5);
  });
  it("skips a segment that starts at/after the target end and compresses one that overruns", () => {
    const out = pasteSegmentsClip(clip, "ov2", base, 3200, "exact")!;
    expect(out).toHaveLength(2);
    const last = out[1]!.keyframes.map((k) => k.t_ms);
    expect(Math.max(...last)).toBeLessThanOrEqual(3200);
    expect(pasteSegmentsClip(clip, "ov2", base, 1000, "exact")).toBeNull();
  });
});

describe("clip versions", () => {
  it("still pastes a v1 track clip", () => {
    const v1 = { ...captureMotionClip(track, base, 5000)!, version: 1 as const };
    expect(pasteMotionClip(v1, "ov2", base, 5000, "exact")).not.toBeNull();
  });
  it("captureMotionClip stamps the current version", () => {
    expect(captureMotionClip(track, base, 5000)!.version).toBe(MOTION_CLIP_VERSION);
    expect(MOTION_CLIP_VERSION).toBe(2);
  });
  it("pasteMotionClip refuses a segments clip", () => {
    const clip = captureSegmentsClip(track, base, 5000, [scaleRef(1000, 1400)])!;
    expect(pasteMotionClip(clip, "ov2", base, 5000, "exact")).toBeNull();
  });
});
```

- [ ] **Step 2: Run — expect FAIL** (missing exports / version 1).

- [ ] **Step 3: Implement** in `motionClip.ts`

Replace the version constant and `MotionClip` type:

```ts
import type { PropGroupKey } from "./blocks";
import { keyframesOfRef, type SegmentRef } from "./segmentSelection";

/** v2 (2026-09-21) adds `scope: "segments"`. v1 clips (whole track / one
 *  block) are still read by the two old paste paths — the store is
 *  in-memory but outlives a project switch within a session. */
export const MOTION_CLIP_VERSION = 2;

type LegacyScopedClip = {
  version: 1 | 2;
  scope: "track" | "segment";
  body: MotionTemplateBody;
  keyframes: MotionKeyframe[];
  source_duration_ms: number;
};

/** One selected bar, captured. `keyframes` keep their SOURCE times and only
 *  the group's props (every prop for a block, `group: null`); `body` is the
 *  same keyframes re-based to `startMs` so `bakeTemplateToTrack` can bake
 *  a "follow" paste against the target's rest pose. */
export type MotionClipSegment = {
  group: PropGroupKey | null;
  startMs: number;
  endMs: number;
  keyframes: MotionKeyframe[];
  body: MotionTemplateBody;
};

export type MotionClip =
  | LegacyScopedClip
  | {
      version: 2;
      scope: "segments";
      segments: MotionClipSegment[];
      source_duration_ms: number;
    };
```

Update `captureMotionClip`'s two return objects to `version: MOTION_CLIP_VERSION` (they already are — the constant changed). In `pasteMotionClip` replace the first guard:

```ts
  if (clip.scope === "segments") return null;
  if (clip.version !== 1 && clip.version !== 2) return null;
```

Append:

```ts
/** Snapshot the selected bars of ONE track as a segments clip. Keyframes a
 *  block ref and a lane ref both own (the block contains the lane) are kept
 *  once per `(t_ms, prop)` — first ref wins. `null` when nothing is owned. */
export function captureSegmentsClip(
  track: MotionTrack,
  base: MotionProps,
  sourceDurationMs: number,
  refs: SegmentRef[]
): MotionClip | null {
  const seen = new Set<string>();
  const segments: MotionClipSegment[] = [];
  for (const ref of [...refs].sort((a, b) => a.startMs - b.startMs)) {
    const owned: MotionKeyframe[] = [];
    for (const k of keyframesOfRef(track, ref)) {
      const props: Partial<MotionProps> = {};
      for (const [key, v] of Object.entries(k.props) as [keyof MotionProps, number][]) {
        const id = `${k.t_ms}:${key}`;
        if (seen.has(id)) continue;
        seen.add(id);
        props[key] = v;
      }
      if (Object.keys(props).length > 0) owned.push(cloneKeyframe({ ...k, props }));
    }
    if (owned.length === 0) continue;
    const span = Math.max(1, ref.endMs - ref.startMs);
    const rebased: MotionTrack = {
      ...track,
      keyframes: owned.map((k) => ({ ...k, t_ms: k.t_ms - ref.startMs })),
    };
    segments.push({
      group: ref.group,
      startMs: ref.startMs,
      endMs: ref.endMs,
      keyframes: owned,
      body: normalizeTrackToTemplate(rebased, base, span),
    });
  }
  if (segments.length === 0) return null;
  return {
    version: 2,
    scope: "segments",
    segments,
    source_duration_ms: sourceDurationMs,
  };
}

/** Bake a segments clip for `overlayId` at the SOURCE times. Each segment
 *  is placed as its own one-block clip into the room after its start (so a
 *  segment near the target's end compresses like a block paste would); a
 *  segment starting at or past the end is skipped. `null` when every
 *  segment was skipped or the clip is unreadable. The caller merges each
 *  result under its own window (see `pasteMotionInto`). */
export function pasteSegmentsClip(
  clip: MotionClip,
  overlayId: string,
  targetBase: MotionProps,
  durationMs: number,
  mode: PasteMotionMode
): { segment: MotionClipSegment; keyframes: MotionKeyframe[] }[] | null {
  if (clip.scope !== "segments" || clip.version !== 2) return null;
  const out: { segment: MotionClipSegment; keyframes: MotionKeyframe[] }[] = [];
  for (const segment of clip.segments) {
    if (segment.startMs >= durationMs) continue;
    const one: MotionClip = {
      version: 2,
      scope: "segment",
      body: segment.body,
      keyframes: segment.keyframes.map((k) => ({ ...cloneKeyframe(k), t_ms: k.t_ms - segment.startMs })),
      source_duration_ms: Math.max(1, segment.endMs - segment.startMs),
    };
    const placed = placeMotionClipAt(one, overlayId, targetBase, durationMs, segment.startMs, mode);
    if (!placed) continue;
    out.push({ segment, keyframes: placed });
  }
  return out.length === 0 ? null : out;
}
```

- [ ] **Step 4: Run — expect PASS.** Then run the existing `bun test src/lib/video-editor/motionClip.test.ts` — any test asserting `version: 1` on a captured clip must be updated to `MOTION_CLIP_VERSION` (that is the one legitimate test edit here).

- [ ] **Step 5: Type-check the callers.** `cd web && bunx tsc --noEmit -p . 2>&1 | grep -E "motionClip|useMotionEditorState|KvMotionEditor|BlockTrackRow|TrackPresetMenu" ` — every new error must be a `clip.body`/`clip.keyframes` access on the union; narrow with `if (clip.scope === "segments")` at each site (Task 5 adds the real branch in `pasteMotionInto`; for now any other site just early-returns `null`/`false`). Baseline tsc has ~777 unrelated errors — only look at these files.

- [ ] **Step 6: Lint + commit**

```bash
git add src/lib/video-editor/motionClip.ts src/lib/video-editor/motionClip.segments.test.ts src/lib/video-editor/motionClip.test.ts
git commit -m "feat(web): KV Motion — motion clip v2 with a segments scope (absolute times, group-scoped props)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: `pasteMotionInto` learns `"segments"`; analytics types

**Files:**
- Modify: `src/components/studio/kv-generator/motion/useMotionEditorState.ts:142-196` (`pasteMotionInto`)
- Modify: `src/lib/analytics/kv-generator-events.ts:1028-1070`
- Test: `src/components/studio/kv-generator/motion/useMotionEditorState.pasteSegments.test.ts`

**Interfaces:**
- Consumes: `pasteSegmentsClip` (Task 4), `mergeKeyframesIntoTrack` from `@/lib/video-editor/presets`.
- Produces: `pasteMotionInto` returns a merged timeline for a segments clip; analytics `scope: "track" | "segment" | "segments"`, `placement` gains `"source_time"`, new optional `segment_count?: number`, `groups?: string[]` on both clip events; new `trackKvMotionSegmentsDeleted({ project_id, count, groups })` and `trackKvMotionSegmentsShifted({ project_id, count, delta_ms })`.

- [ ] **Step 1: Failing test**

```ts
// src/components/studio/kv-generator/motion/useMotionEditorState.pasteSegments.test.ts
import { describe, expect, it } from "bun:test";
import type { MotionProps, MotionTimeline } from "@/lib/video-editor/timeline";
import { captureSegmentsClip } from "@/lib/video-editor/motionClip";
import { pasteMotionInto } from "./useMotionEditorState";

const rest: MotionProps = { x: 0.1, y: 0.2, scale: 1, rotation: 0, opacity: 1 };
const source: MotionTimeline = {
  version: 1, duration_ms: 5000, fps: 30,
  tracks: [{ kind: "overlay", overlay_id: "a", keyframes: [
    { t_ms: 1000, props: { scale: 1 }, easing: "linear" },
    { t_ms: 1200, props: { scale: 1.2 }, easing: "out" },
    { t_ms: 1400, props: { scale: 1 }, easing: "out" },
  ] }],
};
// Target "b" already has an opacity fade across the same window — it must survive.
const target: MotionTimeline = {
  version: 1, duration_ms: 5000, fps: 30,
  tracks: [{ kind: "overlay", overlay_id: "b", keyframes: [
    { t_ms: 900, props: { opacity: 1 }, easing: "linear" },
    { t_ms: 1500, props: { opacity: 0 }, easing: "out" },
    { t_ms: 1200, props: { opacity: 0.5, scale: 3 }, easing: "linear" },
  ] }],
};
const base = new Map([["a", rest], ["b", rest]]);

describe("pasteMotionInto — segments clip", () => {
  it("merges each segment under its own window, touching only its props, at source times", () => {
    const clip = captureSegmentsClip(source.tracks[0]!, rest, 5000, [
      { trackId: "a", group: "scale", startMs: 1000, endMs: 1400 },
    ])!;
    const next = pasteMotionInto(target, base, "b", clip, "exact", 4000)!;
    const kfs = next.tracks.find((t) => t.kind === "overlay" && t.overlay_id === "b")!.keyframes;
    const at = (t: number) => kfs.find((k) => k.t_ms === t)!;
    expect(at(1000).props.scale).toBe(1);
    expect(at(1200).props.scale).toBe(1.2);      // pasted scale replaced the old scale:3
    expect(at(1200).props.opacity).toBe(0.5);    // opacity in the window survived
    expect(at(900).props.opacity).toBe(1);
    expect(at(1500).props.opacity).toBe(0);
    // playhead 4000 was ignored
    expect(kfs.some((k) => k.t_ms >= 4000)).toBe(false);
  });
  it("returns null when every segment is past the target end", () => {
    const clip = captureSegmentsClip(source.tracks[0]!, rest, 5000, [
      { trackId: "a", group: "scale", startMs: 1000, endMs: 1400 },
    ])!;
    const short = { ...target, duration_ms: 800 };
    expect(pasteMotionInto(short, base, "b", clip, "exact", 0)).toBeNull();
  });
});
```

- [ ] **Step 2: Run — expect FAIL** (`pasteMotionInto` returns something that ignores the scope, or a type error).

- [ ] **Step 3: Implement** — insert at the top of `pasteMotionInto`, right after the `restPose` guard:

```ts
  if (clip.scope === "segments") {
    const placed = pasteSegmentsClip(
      clip,
      trackId,
      restPose,
      timeline.duration_ms,
      mode
    );
    if (!placed) return null;
    let tl = timeline;
    for (const { segment, keyframes } of placed) {
      tl = mergeKeyframesIntoTrack(tl, trackId, keyframes, {
        startMs: segment.startMs,
        endMs: Math.min(segment.endMs, timeline.duration_ms),
      });
    }
    return tl;
  }
```
Import `pasteSegmentsClip` from `@/lib/video-editor/motionClip`. The existing `"segment"` branch and the whole-track fallthrough stay as they are; the fallthrough's `pasteMotionClip` call is now safe because segments returned above.

Analytics (`kv-generator-events.ts`): in `KvMotionClipCopiedProps` and `KvMotionClipPastedProps` change `scope: "track" | "segment"` → `scope: "track" | "segment" | "segments"`, add
```ts
  /** Segments clips only: how many bars, and which lanes ("block" for a
   *  block bar) — the shape of what a multi-select actually copies. */
  segment_count?: number;
  groups?: string[];
```
and in `KvMotionClipPastedProps.placement` add `| "source_time"` with the comment `/** "source_time": a segments clip, landed at the times it was copied from. */`. Append:

```ts
export interface KvMotionSegmentsDeletedProps {
  project_id: string;
  count: number;
  groups: string[];
}
/** Backspace / "Delete N segments" on a multi-selection of bars. */
export const trackKvMotionSegmentsDeleted = (p: KvMotionSegmentsDeletedProps) =>
  safeCapture("kv_generator.motion_segments_deleted", p);

export interface KvMotionSegmentsShiftedProps {
  project_id: string;
  count: number;
  delta_ms: number;
}
/** A body drag on a selected bar moved the whole selection. */
export const trackKvMotionSegmentsShifted = (p: KvMotionSegmentsShiftedProps) =>
  safeCapture("kv_generator.motion_segments_shifted", p);
```

- [ ] **Step 4: Run — expect PASS.** Also `bun test src/components/studio/kv-generator/motion/useMotionEditorState.copyPasteMotion.test.tsx src/components/studio/kv-generator/motion/useMotionEditorState.pasteInto.test.tsx`.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/motion/useMotionEditorState.ts src/components/studio/kv-generator/motion/useMotionEditorState.pasteSegments.test.ts src/lib/analytics/kv-generator-events.ts
git commit -m "feat(web): KV Motion — paste a segments clip at source times, prop-aware per window; analytics shapes

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Hook state — `selectedSegments`, `selectSegment`, pruning, exclusivity

**Files:**
- Modify: `src/components/studio/kv-generator/motion/useMotionEditorState.ts` (near `selectTrack` ~line 778, `clearSelection` ~848, `selectKeyframe` ~755, `selectTrackAtStart` ~1097, return block ~1900)
- Test: `src/components/studio/kv-generator/motion/useMotionEditorState.segments.test.tsx`

**Interfaces:**
- Consumes: `SegmentRef`, `sameRef`, `pruneSegmentRefs`, `rangeSegmentRefs` from `@/lib/video-editor/segmentSelection`; `SelectMode` from `@/components/video-editor/selectionMode`.
- Produces on the hook's return: `selectedSegments: SegmentRef[]`, `selectSegment(ref: SegmentRef, mode?: SelectMode): void`.

- [ ] **Step 1: Failing tests**

```tsx
// src/components/studio/kv-generator/motion/useMotionEditorState.segments.test.tsx
/** Segment selection: replace/toggle/range, one track only, exclusive with
 *  the layer multi-select, pruned when the span disappears. Fixture copied
 *  from useMotionEditorState.bulk.test.tsx. */
import { createElement, type ReactNode } from "react";
import { describe, expect, it } from "bun:test";
import { act, renderHook } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { KvMotionProject } from "@/types/kv/motionProject";
import type { StudioOverlay } from "@/types/studio";
import type { SegmentRef } from "@/lib/video-editor/segmentSelection";
import { useMotionEditorState } from "./useMotionEditorState";

function overlay(id: string, z: number): StudioOverlay {
  return { id, studio_file_id: "f1", type: "text", x: 0.1, y: 0.2, width: 0.3, height: 0.1, rotation: 0, z,
    payload: { type: "text", content: id, color: "#000000" }, created_at: "t", updated_at: "t" };
}
const qcWrapper = ({ children }: { children: ReactNode }) =>
  createElement(QueryClientProvider, { client: new QueryClient({ defaultOptions: { queries: { retry: false } } }) }, children);

// "top" carries three scale pulses; "mid" one.
const pulse = (s: number) => [
  { t_ms: s, props: { scale: 1 }, easing: "linear" as const },
  { t_ms: s + 200, props: { scale: 1.2 }, easing: "out" as const },
  { t_ms: s + 400, props: { scale: 1 }, easing: "out" as const },
];
function makeProject(): KvMotionProject {
  return { id: "p1", studioFileId: "f1", boardGenerationId: "g1", name: "Test", audioUrl: null, durationMs: 5000, fps: 30, createdAt: "", updatedAt: "",
    snapshot: { base_image_url: "https://x/y.png", board_width: 1080, board_height: 1080, overlays: [overlay("top", 2), overlay("mid", 1), overlay("low", 0)] },
    timeline: { version: 1, duration_ms: 5000, fps: 30, tracks: [
      { kind: "overlay", overlay_id: "top", keyframes: [...pulse(0), ...pulse(1000), ...pulse(2000)] },
      { kind: "overlay", overlay_id: "mid", keyframes: pulse(500) },
    ] } };
}
const ref = (trackId: string, startMs: number, group: SegmentRef["group"] = "scale"): SegmentRef =>
  ({ trackId, group, startMs, endMs: startMs + 400 });
const setup = () => renderHook(() => useMotionEditorState(makeProject(), { autosave: false }), { wrapper: qcWrapper });

describe("selectSegment", () => {
  it("replace selects one ref and makes its track the primary", () => {
    const { result } = setup();
    act(() => result.current.selectSegment(ref("top", 1000)));
    expect(result.current.selectedSegments).toEqual([ref("top", 1000)]);
    expect(result.current.selectedKeyframe?.trackId).toBe("top");
    expect(result.current.selectedTrackIds).toEqual(["top"]);
  });
  it("toggle adds and removes within one track, sorted by start", () => {
    const { result } = setup();
    act(() => result.current.selectSegment(ref("top", 2000)));
    act(() => result.current.selectSegment(ref("top", 0), "toggle"));
    expect(result.current.selectedSegments).toEqual([ref("top", 0), ref("top", 2000)]);
    act(() => result.current.selectSegment(ref("top", 2000), "toggle"));
    expect(result.current.selectedSegments).toEqual([ref("top", 0)]);
  });
  it("toggle on another track replaces", () => {
    const { result } = setup();
    act(() => result.current.selectSegment(ref("top", 0)));
    act(() => result.current.selectSegment(ref("mid", 500), "toggle"));
    expect(result.current.selectedSegments).toEqual([ref("mid", 500)]);
    expect(result.current.selectedKeyframe?.trackId).toBe("mid");
  });
  it("range fills the lane between the last pick and the clicked bar", () => {
    const { result } = setup();
    act(() => result.current.selectSegment(ref("top", 0)));
    act(() => result.current.selectSegment(ref("top", 2000), "range"));
    expect(result.current.selectedSegments.map((r) => r.startMs)).toEqual([0, 1000, 2000]);
  });
  it("is exclusive with the layer multi-select, both ways", () => {
    const { result } = setup();
    act(() => result.current.selectTrack("top"));
    act(() => result.current.selectTrack("mid", "toggle"));
    expect(result.current.selectedTrackIds).toHaveLength(2);
    act(() => result.current.selectSegment(ref("top", 0)));
    expect(result.current.selectedTrackIds).toEqual(["top"]);
    act(() => result.current.selectTrack("mid", "toggle"));
    expect(result.current.selectedSegments).toEqual([]);
  });
  it("clearSelection and selectKeyframe empty it", () => {
    const { result } = setup();
    act(() => result.current.selectSegment(ref("top", 0)));
    act(() => result.current.clearSelection());
    expect(result.current.selectedSegments).toEqual([]);
    act(() => result.current.selectSegment(ref("top", 0)));
    act(() => result.current.selectKeyframe("top", 200));
    expect(result.current.selectedSegments).toEqual([]);
  });
  it("survives a playhead move and is pruned when the span disappears", () => {
    const { result } = setup();
    act(() => result.current.selectSegment(ref("top", 1000)));
    act(() => result.current.seek(3000));
    expect(result.current.selectedSegments).toHaveLength(1);
    act(() => result.current.deleteSegment("top", 1000, 1400));
    expect(result.current.selectedSegments).toEqual([]);
  });
});
```

- [ ] **Step 2: Run — expect FAIL** (`selectSegment is not a function`).

- [ ] **Step 3: Implement**

Add state next to `selectedTrackIds`:

```ts
  // Selected BARS (block or lane) on one track — spec 2026-09-21. Derived
  // spans, so `pruneSegmentRefs` re-resolves them after every document
  // change (the effect below). Non-empty ⇒ exactly one selected track, and
  // it is the primary.
  const [selectedSegments, setSelectedSegments] = useState<SegmentRef[]>([]);
  const lastSegmentPick = useRef<SegmentRef | null>(null);
```

Prune effect (after the `timeline` state is declared):

```ts
  useEffect(() => {
    setSelectedSegments((cur) =>
      cur.length === 0 ? cur : pruneSegmentRefs(timeline, cur)
    );
  }, [timeline]);
```

`selectSegment` (place after `selectTrackAtStart` so it can call it):

```ts
  const selectSegment = useCallback(
    (ref: SegmentRef, mode: SelectMode = "replace") => {
      const overlay = snapshot.overlays.find((o) => o.id === ref.trackId);
      if (!overlay || overlay.payload.locked || overlay.payload.hidden) return;
      const sameTrack = selectedSegments[0]?.trackId === ref.trackId;
      if (
        mode === "replace" ||
        !sameTrack ||
        (selectedSegments.length === 0 && mode === "range")
      ) {
        selectTrackAtStart(ref.trackId);
        setSelectedSegments([ref]);
        lastSegmentPick.current = ref;
        return;
      }
      if (mode === "toggle") {
        setSelectedSegments((cur) => {
          const without = cur.filter((r) => !sameRef(r, ref));
          const next = without.length === cur.length ? [...cur, ref] : without;
          return next.sort((a, b) => a.startMs - b.startMs);
        });
        lastSegmentPick.current = ref;
        return;
      }
      // range
      const anchor = lastSegmentPick.current ?? selectedSegments[0]!;
      const span = rangeSegmentRefs(timeline, anchor, ref);
      setSelectedSegments((cur) => {
        const merged = [...cur];
        for (const r of span) if (!merged.some((m) => sameRef(m, r))) merged.push(r);
        return merged.sort((a, b) => a.startMs - b.startMs);
      });
      lastSegmentPick.current = ref;
    },
    [snapshot.overlays, selectedSegments, selectTrackAtStart, timeline]
  );
```
Check how the existing eligibility gate reads locked/hidden (`multiSelectOrder`'s derivation around line 600) and use the SAME predicate rather than `overlay.payload.locked` if that is not where the flags live — grep `hidden` in the hook to find it.

Exclusivity: in `selectTrack` (the rail's) and `selectKeyframe` and `clearSelection`, add `setSelectedSegments([])` (in `selectTrack` only when the mode/branch changes the selection to something other than the segments' own single track — simplest: always clear; the `selectSegment` "replace" branch calls `selectTrackAtStart`, which is a different function, so it does not re-clear). Verify `selectTrackAtStart` does NOT clear (it is what `selectSegment` calls). Export `selectedSegments` and `selectSegment` from the return object.

- [ ] **Step 4: Run — expect PASS.** Then run `bun test src/components/studio/kv-generator/motion/useMotionEditorState.selection.test.tsx src/components/studio/kv-generator/motion/useMotionEditorState.bulk.test.tsx` — must stay green.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/motion/useMotionEditorState.ts src/components/studio/kv-generator/motion/useMotionEditorState.segments.test.tsx
git commit -m "feat(web): KV Motion — selectedSegments state: replace/toggle/range, one track, pruned on change

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Hook bulk writers — `copySegments`, `deleteSegments`, `shiftSegments`

**Files:**
- Modify: `src/components/studio/kv-generator/motion/useMotionEditorState.ts`
- Test: append to `useMotionEditorState.segments.test.tsx` (still < 40 KB) — or a new `useMotionEditorState.segments.bulk.test.tsx` if the first file passes 25 KB.

**Interfaces:**
- Consumes: `captureSegmentsClip` (Task 4), `deleteSegmentRefs`, `shiftSegmentRefs`, `selectionShiftBounds` (Task 3), `useKvMotionClipStore`.
- Produces: `copySegments(source: "menu" | "keyboard"): boolean`, `deleteSegments(): number`, `shiftSegments(deltaMs: number): number` (returns the applied delta), `selectionShiftWalls: { minDelta: number; maxDelta: number } | null` (memo).

- [ ] **Step 1: Failing tests**

```tsx
describe("segment bulk writers", () => {
  it("copySegments puts a segments clip in the store and reports false with nothing selected", () => {
    const { result } = setup();
    expect(result.current.copySegments("menu")).toBe(false);
    act(() => result.current.selectSegment(ref("top", 0)));
    act(() => result.current.selectSegment(ref("top", 2000), "toggle"));
    let ok = false;
    act(() => { ok = result.current.copySegments("menu"); });
    expect(ok).toBe(true);
    const clip = useKvMotionClipStore.getState().clip;
    expect(clip?.scope).toBe("segments");
    if (clip?.scope === "segments") expect(clip.segments.map((s) => s.startMs)).toEqual([0, 2000]);
  });
  it("deleteSegments removes every selected bar as one undo step and empties the selection", () => {
    const { result } = setup();
    act(() => result.current.selectSegment(ref("top", 0)));
    act(() => result.current.selectSegment(ref("top", 2000), "toggle"));
    let n = 0;
    act(() => { n = result.current.deleteSegments(); });
    expect(n).toBe(2);
    const kfs = result.current.timeline.tracks.find((t) => t.kind === "overlay" && t.overlay_id === "top")!.keyframes;
    expect(kfs.map((k) => k.t_ms)).toEqual([1000, 1200, 1400]);
    expect(result.current.selectedSegments).toEqual([]);
    act(() => result.current.undo());
    expect(result.current.canUndo).toBe(false);
  });
  it("shiftSegments moves the selection by the clamped delta, keeps it selected, one push", () => {
    const { result } = setup();
    act(() => result.current.selectSegment(ref("top", 0)));
    act(() => result.current.selectSegment(ref("top", 1000), "toggle"));
    expect(result.current.selectionShiftWalls).toEqual({ minDelta: 0, maxDelta: 599 });
    let d = 0;
    act(() => { d = result.current.shiftSegments(10_000); });
    expect(d).toBe(599);
    expect(result.current.selectedSegments.map((r) => r.startMs)).toEqual([599, 1599]);
    act(() => result.current.undo());
    expect(result.current.canUndo).toBe(false);
  });
});
```
Add `import { useKvMotionClipStore } from "@/store/kv/useKvMotionClipStore";` to the test.

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement** (next to `copyMotion`):

```ts
  const selectionShiftWalls = useMemo(
    () => selectionShiftBounds(timeline, selectedSegments),
    [timeline, selectedSegments]
  );

  const copySegments = useCallback(
    (source: "menu" | "keyboard"): boolean => {
      if (selectedSegments.length === 0) return false;
      const trackId = selectedSegments[0]!.trackId;
      const track = timeline.tracks.find((t) => t.kind === "overlay" && t.overlay_id === trackId);
      const restPose = base.get(trackId);
      if (!track || !restPose) return false;
      const clip = captureSegmentsClip(track, restPose, timeline.duration_ms, selectedSegments);
      if (!clip || clip.scope !== "segments") return false;
      motionClipCopy(clip, project.id);
      const overlay = snapshot.overlays.find((o) => o.id === trackId);
      trackKvMotionClipCopied({
        project_id: project.id,
        overlay_type: overlay ? overlayTypeOf(overlay) : "shape",
        source,
        scope: "segments",
        segment_count: clip.segments.length,
        groups: clip.segments.map((s) => s.group ?? "block"),
      });
      return true;
    },
    [selectedSegments, timeline, base, motionClipCopy, project.id, snapshot.overlays]
  );

  const deleteSegments = useCallback((): number => {
    if (selectedSegments.length === 0) return 0;
    const next = deleteSegmentRefs(timeline, selectedSegments);
    if (next === timeline) return 0;
    push(next);
    return selectedSegments.length;
  }, [selectedSegments, timeline, push]);

  const shiftSegments = useCallback(
    (deltaMs: number): number => {
      if (selectedSegments.length === 0) return 0;
      const out = shiftSegmentRefs(timeline, selectedSegments, deltaMs);
      if (out.delta === 0) return 0;
      push(out.timeline);
      setSelectedSegments(out.refs);
      return out.delta;
    },
    [selectedSegments, timeline, push]
  );
```
Export all four. The prune effect (Task 6) will run after `push` and keep `out.refs` because they exist in the new timeline; if it drops them (lane writers stepped 1 ms), replace `setSelectedSegments(out.refs)` with a re-lookup: for each moved ref, find the lane segment whose `startMs` is within 1 ms and use that — write that as a helper `snapRefsToLane(timeline, refs)` in `segmentSelection.ts` with a test, only if the test in Step 4 shows the drop.

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/motion/useMotionEditorState.ts src/components/studio/kv-generator/motion/useMotionEditorState.segments.test.tsx src/lib/video-editor/segmentSelection.ts src/lib/video-editor/segmentSelection.test.ts
git commit -m "feat(web): KV Motion — copy/delete/shift the segment selection, one push each

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: Bars take ⌘/⇧-click and show a segment-selected state

**Files:**
- Modify: `src/components/video-editor/BlockTrackRow.tsx` (`BlockTrackRowProps` ~line 80–200; `SegmentBar` props ~286–400 and `handleBodyClick` ~588; bar `className` ~957; `PropSubRow` ~1373; the `SegmentBar`/`PropSegmentBar` render sites ~1439 and ~1990)
- Modify: `src/components/video-editor/PropSegmentBar.tsx` (props, `onClick` ~121, `className` ~116)
- Modify: `src/components/video-editor/TimelineDock.tsx` (`TimelineDockProps` + pass-through at ~715)
- Test: `src/components/video-editor/BlockTrackRow.segmentSelect.test.tsx`, `src/components/video-editor/PropSegmentBar.select.test.tsx`

**Interfaces:**
- Consumes: `SegmentRef`, `sameRef`; `modeFromEvent` from `./selectionMode`.
- Produces: `TimelineDockProps` / `BlockTrackRowProps` gain `selectedSegments?: SegmentRef[]` and `onSelectSegment?: (ref: SegmentRef, mode: SelectMode) => void`. `SegmentBar` gains `segmentSelected: boolean`, `onSelectSegment?: (mode: SelectMode) => void`. `PropSegmentBar` gains `segmentSelected: boolean`, `onSelectSegment?: (mode: SelectMode) => void`.

- [ ] **Step 1: Failing tests**

Look at `src/components/video-editor/BlockTrackRow.test.tsx` (or the nearest `BlockTrackRow.*.test.tsx`) for the existing `renderRow` fixture and copy its `track`/`keyframes` setup; then:

```tsx
// src/components/video-editor/BlockTrackRow.segmentSelect.test.tsx
import { describe, expect, it, mock } from "bun:test";
import { fireEvent, render, within } from "@testing-library/react";
import { BlockTrackRow } from "./BlockTrackRow";
// …copy the minimal props fixture from the existing BlockTrackRow test; the
// track must have TWO emphasis segments (e.g. pulses at 1000 and 2000) and
// be expanded (`expanded: true`) so the scale lane renders.

const body = () => within(document.body);

describe("segment selection on bars", () => {
  it("⌘-click on a block bar reports toggle; plain click reports replace", () => {
    const onSelectSegment = mock(() => {});
    renderRow({ onSelectSegment });
    fireEvent.click(body().getByTestId("block-bar-ov1-0"), { metaKey: true });
    expect(onSelectSegment).toHaveBeenLastCalledWith(
      { trackId: "ov1", group: null, startMs: 1000, endMs: 1400 }, "toggle");
    fireEvent.click(body().getByTestId("block-bar-ov1-1"));
    expect(onSelectSegment).toHaveBeenLastCalledWith(
      { trackId: "ov1", group: null, startMs: 2000, endMs: 2400 }, "replace");
  });
  it("⇧-click on a lane bar reports range with the lane's group", () => {
    const onSelectSegment = mock(() => {});
    renderRow({ onSelectSegment, expanded: true });
    fireEvent.click(body().getByTestId("prop-bar-ov1-scale-1"), { shiftKey: true });
    expect(onSelectSegment).toHaveBeenLastCalledWith(
      { trackId: "ov1", group: "scale", startMs: 2000, endMs: 2400 }, "range");
  });
  it("marks selected bars with data-selected", () => {
    renderRow({ expanded: true, selectedSegments: [
      { trackId: "ov1", group: null, startMs: 1000, endMs: 1400 },
      { trackId: "ov1", group: "scale", startMs: 2000, endMs: 2400 },
    ] });
    expect(body().getByTestId("block-bar-ov1-0")).toHaveAttribute("data-selected", "true");
    expect(body().getByTestId("block-bar-ov1-1")).not.toHaveAttribute("data-selected", "true");
    expect(body().getByTestId("prop-bar-ov1-scale-1")).toHaveAttribute("data-selected", "true");
    expect(body().getByTestId("prop-bar-ov1-scale-0")).not.toHaveAttribute("data-selected", "true");
  });
});
```

- [ ] **Step 2: Run — expect FAIL** (`onSelectSegment` never called / no `data-selected`).

- [ ] **Step 3: Implement**

`BlockTrackRowProps` (and `TimelineDockProps`, passed straight through):
```ts
  /** The bars selected on this row (spec 2026-09-21) — matched by span. */
  selectedSegments?: SegmentRef[];
  onSelectSegment?: (ref: SegmentRef, mode: SelectMode) => void;
```

`SegmentBar` props: `segmentSelected: boolean; onSelectSegment?: (mode: SelectMode) => void;`. In `handleBodyClick`, replace `onSelectTrack(trackId);` with:
```ts
    if (onSelectSegment) onSelectSegment(modeFromEvent(e));
    else onSelectTrack(trackId);
```
(the hook's `replace` branch calls `selectTrackAtStart`, so the plain-click behaviour is preserved.) On the bar `<div>` add `data-selected={segmentSelected ? "true" : undefined}` and to `className` add `segmentSelected && "ring-2 ring-inset ring-white"` after the `selected` ternary — on a near-white selected-track bar the inset white ring reads as a thicker rim, and on a grey bar as a clear outline; keep both so the state survives either track state.

`PropSegmentBar`: props `segmentSelected: boolean; onSelectSegment?: (mode: SelectMode) => void;`. `onClick`:
```ts
      onClick={(e) => {
        if (locked) return;
        if (onSelectSegment) onSelectSegment(modeFromEvent(e));
        else onSelectTrack();
      }}
```
`data-selected` + className `segmentSelected && "border-white/70 bg-white/[0.24] ring-1 ring-inset ring-white/70"`.

Render sites in `BlockTrackRow`: compute `const isSelected = (group: PropGroupKey | null, s: TrackSegment) => selectedSegments?.some((r) => r.trackId === track.id && r.group === group && r.startMs === s.startMs && r.endMs === s.endMs) ?? false;` and pass `segmentSelected={isSelected(null, segment)}` / `onSelectSegment={onSelectSegment && ((mode) => onSelectSegment({ trackId: track.id, group: null, startMs: segment.startMs, endMs: segment.endMs }, mode))}` to `SegmentBar`; thread `selectedSegments`/`onSelectSegment` into `PropSubRow` and from there `segmentSelected={isSelected(group, segment)}` / `onSelectSegment={… group …}` to `PropSegmentBar`.

- [ ] **Step 4: Run — expect PASS.** Also `bun test src/components/video-editor/BlockTrackRow.test.tsx src/components/video-editor/PropSegmentBar.test.tsx` (whichever exist) — green.

- [ ] **Step 5: Lint + commit**

```bash
git add src/components/video-editor/BlockTrackRow.tsx src/components/video-editor/PropSegmentBar.tsx src/components/video-editor/TimelineDock.tsx src/components/video-editor/BlockTrackRow.segmentSelect.test.tsx
git commit -m "feat(web): KV Motion — ⌘/⇧-click bars select segments; data-selected ring on block + lane bars

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 9: Drag a selected bar → the selection moves together

**Files:**
- Modify: `src/components/video-editor/BlockTrackRow.tsx` (`SegmentBar` `useBarDrag` options ~531–548; the `overrideSpan` expression at ~2017; `PropSubRow`)
- Modify: `src/components/video-editor/PropSegmentBar.tsx` (add `overrideSpan`, `onLiveShift`, `bodyWallMin/Max`, `onShiftSelection`)
- Modify: `src/components/video-editor/TimelineDock.tsx` (pass-through)
- Test: `src/components/video-editor/BlockTrackRow.dragTogether.test.tsx`

**Interfaces:**
- Consumes: `useBarDrag`'s `bodyWallMin`/`bodyWallMax`/`onShift`.
- Produces: `BlockTrackRowProps`/`TimelineDockProps` gain `selectionShiftWalls?: { minDelta: number; maxDelta: number } | null` and `onShiftSelection?: (deltaMs: number) => void`. Row-local state `selectionDraft: number | null` (live delta while a selected bar is dragged).

- [ ] **Step 1: Failing test**

```tsx
// src/components/video-editor/BlockTrackRow.dragTogether.test.tsx
// Reuse the fixture from BlockTrackRow.segmentSelect.test.tsx. Look at how
// BlockTrackRow.drag.test.tsx (or the nearest existing drag test) fires
// pointerdown/pointermove/pointerup with a mocked laneRef width — copy that
// helper verbatim (it sets getBoundingClientRect on the lane).
it("dragging one selected bar moves the other selected bar live and commits via onShiftSelection", () => {
  const onShiftSelection = mock(() => {});
  const onShiftSegment = mock(() => {});
  renderRow({
    selectedSegments: [
      { trackId: "ov1", group: null, startMs: 1000, endMs: 1400 },
      { trackId: "ov1", group: null, startMs: 2000, endMs: 2400 },
    ],
    selectionShiftWalls: { minDelta: -1000, maxDelta: 2000 },
    onShiftSelection,
    onShiftSegment,
  });
  const a = body().getByTestId("block-bar-ov1-0");
  const b = body().getByTestId("block-bar-ov1-1");
  const beforeLeft = b.style.left;
  dragBy(a, +200 /* ms via the lane px→ms helper */);
  // live: b followed
  expect(b.style.left).not.toBe(beforeLeft);
  // commit: selection writer, not the single-segment one
  expect(onShiftSelection).toHaveBeenCalledTimes(1);
  expect(onShiftSegment).not.toHaveBeenCalled();
});
```
Assert the live follow on `b` **before** pointerup (split `dragBy` into `pressAndMove` + `release` if the helper does both).

- [ ] **Step 2: Run — expect FAIL** (`b` does not move; `onShiftSegment` called).

- [ ] **Step 3: Implement**

In `BlockTrackRow`: `const [selectionDraft, setSelectionDraft] = useState<number | null>(null);` and a `const selectionCount = selectedSegments?.filter((r) => r.trackId === track.id).length ?? 0;`. Define `const dragsSelection = (group, segment) => selectionCount > 1 && isSelected(group, segment) && Boolean(onShiftSelection);`.

`SegmentBar` new props: `dragsSelection: boolean; selectionWalls: {minDelta;maxDelta} | null; onShiftSelection?: (deltaMs: number) => void; onSelectionLiveShift?: (delta: number | null) => void;`. In its `useBarDrag` call:
```ts
      bodyWallMin: dragsSelection && selectionWalls
        ? segment.startMs + selectionWalls.minDelta
        : bodyWallMin,
      bodyWallMax: dragsSelection && selectionWalls
        ? segment.endMs + selectionWalls.maxDelta
        : bodyWallMax,
      onShift: (fromStart, fromEnd, deltaMs) =>
        dragsSelection && onShiftSelection
          ? onShiftSelection(deltaMs)
          : shiftsTrack && onShiftTrack
            ? onShiftTrack(trackId, deltaMs)
            : onShiftSegment(trackId, fromStart, fromEnd, deltaMs),
```
and mirror the existing `liveShift` effect for `onSelectionLiveShift` (report `draft.startMs - segment.startMs` only while `dragsSelection`). The In bar keeps whole-track behaviour when `shiftsTrack` — put that branch FIRST so `dragsSelection` never overrides it (an In drag already moves everything).

`overrideSpan` at the `SegmentBar` render site: add a third case — `selectionDraft !== null && isSelected(null, segment) ? { startMs: segment.startMs + selectionDraft, endMs: segment.endMs + selectionDraft } : …existing…`. Pass `dragsSelection={dragsSelection(null, segment)}`, `selectionWalls={selectionShiftWalls ?? null}`, `onShiftSelection`, `onSelectionLiveShift={setSelectionDraft}`.

`PropSegmentBar`: add `overrideSpan: {startMs;endMs} | null`, `dragsSelection`, `selectionWalls`, `onShiftSelection`, `onSelectionLiveShift` with the same `useBarDrag` overrides; `start`/`end` become `drag.draft?.startMs ?? overrideSpan?.startMs ?? segment.startMs` (same for end). `PropSubRow` passes `overrideSpan` from `selectionDraft` for selected lane bars and the other four props.

- [ ] **Step 4: Run — expect PASS.** Mutation check: temporarily remove the `selectionDraft` case from the block `overrideSpan` expression → the test must fail on the live-follow assertion; restore.

- [ ] **Step 5: Lint + commit**

```bash
git add src/components/video-editor/BlockTrackRow.tsx src/components/video-editor/PropSegmentBar.tsx src/components/video-editor/TimelineDock.tsx src/components/video-editor/BlockTrackRow.dragTogether.test.tsx
git commit -m "feat(web): KV Motion — drag a selected bar moves the whole selection (live follow + one commit)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 10: Menus — N-segments items, lane-bar context menu, paste labels, hidden paste

**Files:**
- Modify: `src/components/video-editor/BlockTrackRow.tsx` (segment menu ~730–880; `SlotPlaceholder` `MotionPanelHeader` ~1240)
- Modify: `src/components/video-editor/PropSegmentBar.tsx` (new context menu)
- Modify: `src/components/video-editor/MotionPanelHeader.tsx` (no API change — callers pass the label)
- Modify: `src/components/studio/kv-generator/motion/TrackPresetMenu.tsx:312`
- Test: `src/components/video-editor/BlockTrackRow.segmentMenu.test.tsx`, `src/components/video-editor/PropSegmentBar.menu.test.tsx`, `src/components/studio/kv-generator/motion/TrackPresetMenu.pasteSegments.test.tsx`

**Interfaces:**
- Produces: `BlockTrackRowProps`/`TimelineDockProps` gain `onCopySelection?: () => void`, `onDeleteSelection?: () => void`, `onCopyLaneSegment?: (trackId, group: PropGroupKey, startMs, endMs) => void`, `onDeleteLaneSegment?: (trackId, group, startMs, endMs) => void`, `clipSegmentCount?: number` (0 = clipboard is not a segments clip). `TrackPresetMenu` gains `pasteSegmentCount?: number`.
- Labels: helper `export function pasteMotionLabel(base: string, segmentCount: number): string` in `motionClip.ts` → `segmentCount > 0 ? \`Paste ${segmentCount} segment${segmentCount === 1 ? "" : "s"}\` : base`. Group label helper `export function groupLabel(group: PropGroupKey): string` in `segmentSelection.ts` → capitalised (`"scale"` → `"Scale"`, `"position"` → `"Position"`).

- [ ] **Step 1: Failing tests**

```tsx
// BlockTrackRow.segmentMenu.test.tsx
it("right-click on a bar inside a 2-bar selection shows Copy/Delete N and hides Change motion", () => {
  const onCopySelection = mock(() => {});
  renderRow({ selectedSegments: [refA, refB], onCopySelection, onDeleteSelection: mock(() => {}) });
  fireEvent.contextMenu(body().getByTestId("block-bar-ov1-0"), { clientX: 10, clientY: 10 });
  expect(body().getByRole("menuitem", { name: "Copy 2 segments" })).toBeInTheDocument();
  expect(body().getByRole("menuitem", { name: "Delete 2 segments" })).toBeInTheDocument();
  expect(body().queryByText("Change motion")).toBeNull();
  fireEvent.click(body().getByRole("menuitem", { name: "Copy 2 segments" }));
  expect(onCopySelection).toHaveBeenCalledTimes(1);
});
it("right-click on a bar OUTSIDE the selection first replaces the selection with it", () => {
  const onSelectSegment = mock(() => {});
  renderRow({ selectedSegments: [refA, refB], onSelectSegment });
  fireEvent.contextMenu(body().getByTestId("block-bar-ov1-2"), { clientX: 10, clientY: 10 });
  expect(onSelectSegment).toHaveBeenCalledWith(refC, "replace");
});
it("hides Paste on a block menu and a slot placeholder while the clipboard holds segments", () => {
  renderRow({ clipSegmentCount: 3, canPasteMotion: true, onPasteSegmentMotion: mock(() => {}), onPasteSlotMotion: mock(() => {}) });
  fireEvent.contextMenu(body().getByTestId("block-bar-ov1-0"), { clientX: 10, clientY: 10 });
  expect(body().queryByText(/Paste motion/)).toBeNull();
});

// PropSegmentBar.menu.test.tsx
it("single lane bar right-click offers Copy Scale / Delete Scale", () => {
  const onCopyLaneSegment = mock(() => {});
  renderRow({ expanded: true, onCopyLaneSegment, onDeleteLaneSegment: mock(() => {}) });
  fireEvent.contextMenu(body().getByTestId("prop-bar-ov1-scale-0"), { clientX: 10, clientY: 10 });
  fireEvent.click(body().getByRole("menuitem", { name: "Copy Scale" }));
  expect(onCopyLaneSegment).toHaveBeenCalledWith("ov1", "scale", 1000, 1400);
});

// TrackPresetMenu.pasteSegments.test.tsx (fixture from TrackPresetMenu.test.tsx)
it("labels Paste with the segment count", () => {
  renderMenu({ pasteSegmentCount: 3 });
  expect(body().getByText("Paste 3 segments")).toBeInTheDocument();
});
```
`refA/refB/refC` = block refs for the three pulses in the fixture.

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement**

- `SegmentBar` gets `selectionCount: number`, `onCopySelection?`, `onDeleteSelection?`. In `handleContextMenu`, before `onOpenMenu`: `if (!segmentSelected && onSelectSegment) onSelectSegment("replace");`. In the menu body: when `selectionCount > 1 && segmentSelected` render ONLY
  ```tsx
  <div role="menu" aria-label="Selection actions">
    <button type="button" role="menuitem" onClick={() => { onCopySelection?.(); onCloseMenu(); }} className={MENU_ITEM_CLASS}><CopySimple className="size-4" />Copy {selectionCount} segments</button>
    <button type="button" role="menuitem" onClick={() => { onDeleteSelection?.(); onCloseMenu(); }} className={MENU_ITEM_DANGER_CLASS}><Trash className="size-4" />Delete {selectionCount} segments</button>
  </div>
  ```
  (copy the exact className strings from the existing "Delete" item at ~line 850 into two local constants); otherwise the existing menu. In the existing menu, wrap the `MotionPanelHeader` paste with `canPaste={Boolean(canPasteMotion) && clipSegmentCount === 0}` **and** hide the header entirely when `clipSegmentCount > 0 && !onCopySegmentMotion` — simplest faithful rule: pass `onPaste` only when `clipSegmentCount === 0`; `MotionPanelHeader` already renders no paste items when `canPaste` is false? Check: if it renders disabled items instead, add an `hidePaste?: boolean` prop to `MotionPanelHeader` that skips the paste rows, and use it here and in `SlotPlaceholder`.
- `PropSegmentBar`: a `Popover` context menu identical in structure to `SegmentBar`'s (anchor button at the click point, `key={x-y}`), items: when `selectionCount > 1 && segmentSelected` → Copy/Delete N (same handlers); else `Copy {groupLabel(group)}` → `onCopyLaneSegment(...)`, `Delete {groupLabel(group)}` → `onDeleteLaneSegment(...)`. `PropSubRow` wires them with `trackId`, `group`, span.
- `TrackPresetMenu`: `pasteLabel={pasteMotionLabel("Paste motion", pasteSegmentCount ?? 0)}`.
- `SlotPlaceholder`: render its `MotionPanelHeader` only when `clipSegmentCount === 0`.

- [ ] **Step 4: Run — expect PASS**, plus the existing `BlockTrackRow.contextmenu`/`slot` tests.

- [ ] **Step 5: Lint + commit**

```bash
git add src/components/video-editor src/components/studio/kv-generator/motion/TrackPresetMenu.tsx src/lib/video-editor/motionClip.ts src/lib/video-editor/segmentSelection.ts
git commit -m "feat(web): KV Motion — N-segments menu, lane bar Copy/Delete <Group>, Paste N segments label, paste hidden on slot/block for segments clips

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 11: Keyboard — Backspace/Delete, ⇧⌘C prefers the selection

**Files:**
- Modify: `src/components/studio/kv-generator/motion/motionClipboardKeys.ts`
- Modify: `src/components/studio/kv-generator/motion/KvMotionEditor.tsx:1968-2045`
- Test: `src/components/studio/kv-generator/motion/motionClipboardKeys.test.ts` (append), `src/components/studio/kv-generator/motion/motionSegmentKeys.test.ts` (new)

**Interfaces:**
- `makeMotionClipboardKeyHandler` deps gain `copySegments?: () => boolean` — tried before `copyMotion` on `"copy-motion"`.
- New pure `export function makeSegmentKeyHandler(deps: { hasSelection: () => boolean; deleteSegments: () => number }): (e: KeyboardEvent) => void` in `motionSegmentKeys.ts`: on `Backspace`/`Delete`, not `isTypingTarget`, not inside `[role="dialog"]`, with a selection → `deleteSegments()` and `preventDefault()`.

- [ ] **Step 1: Failing tests**

```ts
// motionSegmentKeys.test.ts
import { describe, expect, it, mock } from "bun:test";
import { makeSegmentKeyHandler } from "./motionSegmentKeys";
const ev = (key: string, target: EventTarget | null = document.body) =>
  Object.assign(new KeyboardEvent("keydown", { key, cancelable: true }), { __t: target });
// build the event with `Object.defineProperty(e, "target", { value: target })`
it("Backspace deletes the selection and claims the key", () => {
  const deleteSegments = mock(() => 2);
  const h = makeSegmentKeyHandler({ hasSelection: () => true, deleteSegments });
  const e = ev("Backspace"); h(e);
  expect(deleteSegments).toHaveBeenCalledTimes(1);
  expect(e.defaultPrevented).toBe(true);
});
it("does nothing without a selection or inside an input", () => {
  const deleteSegments = mock(() => 0);
  makeSegmentKeyHandler({ hasSelection: () => false, deleteSegments })(ev("Delete"));
  const input = document.createElement("input");
  makeSegmentKeyHandler({ hasSelection: () => true, deleteSegments })(ev("Delete", input));
  expect(deleteSegments).not.toHaveBeenCalled();
});

// motionClipboardKeys.test.ts (append)
it("Shift+Cmd+C copies the segment selection first, falling back to the track", () => {
  const copySegments = mock(() => true);
  const copyMotion = mock(() => true);
  const h = makeMotionClipboardKeyHandler({ selectedTrackId: () => "ov1", copyLayer: () => false, pasteLayer: () => false, copyMotion, pasteMotion: () => false, copySegments });
  h(new KeyboardEvent("keydown", { key: "c", metaKey: true, shiftKey: true, cancelable: true }));
  expect(copySegments).toHaveBeenCalledTimes(1);
  expect(copyMotion).not.toHaveBeenCalled();
});
```
Check the existing test's event construction (it may use a helper) and reuse it.

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement**

`motionClipboardKeys.ts`: add `copySegments?: () => boolean` to deps; in the handled branch:
```ts
        : shortcut === "copy-motion"
          ? (deps.copySegments?.() ?? false) || deps.copyMotion(trackId)
```
`motionSegmentKeys.ts`:
```ts
import { isTypingTarget } from "@/lib/studio/kv/keyboardGuards";
export function makeSegmentKeyHandler(deps: { hasSelection: () => boolean; deleteSegments: () => number }) {
  return function onSegmentKey(e: KeyboardEvent): void {
    if (e.key !== "Backspace" && e.key !== "Delete") return;
    if (isTypingTarget(e.target)) return;
    const t = e.target as HTMLElement | null;
    if (t?.closest?.('[role="dialog"]')) return;
    if (!deps.hasSelection()) return;
    if (deps.deleteSegments() > 0) e.preventDefault();
  };
}
```
`KvMotionEditor.tsx`: add `copySegments: () => state.copySegments("keyboard")` to the clipboard handler deps (and `state.copySegments` to its dependency list); build `segmentKeyHandler = useMemo(() => makeSegmentKeyHandler({ hasSelection: () => state.selectedSegments.length > 0, deleteSegments: () => { const n = state.deleteSegments(); if (n > 0) trackKvMotionSegmentsDeleted({ project_id: projectId, count: n, groups: state.selectedSegments.map((r) => r.group ?? "block") }); return n; } }), [state.selectedSegments, state.deleteSegments, projectId])` and call it inside `onKeyDown` before `clipboardKeyHandler(e)`. Esc: the existing branch checks `state.selectedTrackIds.length > 0`; change the condition to `state.selectedTrackIds.length > 0 || state.selectedSegments.length > 0` (and add to the effect deps).

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/motion/motionClipboardKeys.ts src/components/studio/kv-generator/motion/motionClipboardKeys.test.ts src/components/studio/kv-generator/motion/motionSegmentKeys.ts src/components/studio/kv-generator/motion/motionSegmentKeys.test.ts src/components/studio/kv-generator/motion/KvMotionEditor.tsx
git commit -m "feat(web): KV Motion — Backspace deletes the segment selection; Shift+Cmd+C copies it

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 12: Editor wiring — dock props, toasts, analytics, hint

**Files:**
- Modify: `src/components/studio/kv-generator/motion/KvMotionEditor.tsx` (the `<TimelineDock …>` props block ~2700–2860; `trackPresetMenuProps` ~2170; `pasteMotionTo`)
- Modify: `src/components/video-editor/TimelineDock.tsx` (hint text in its `PanelHeader`)
- Modify: `src/components/studio/kv-generator/motion/useMotionEditorState.ts` (`pasteMotion`/`pasteMotionToTracks` analytics: `placement: "source_time"`, `segment_count`, `groups` for a segments clip)

- [ ] **Step 1: Wire** (no new unit test — every piece is covered above; this task is verified by the RTL tests staying green plus the manual checklist in Task 13)

`<TimelineDock>` gets:
```tsx
          selectedSegments={state.selectedSegments}
          onSelectSegment={state.selectSegment}
          selectionShiftWalls={state.selectionShiftWalls}
          onShiftSelection={(deltaMs) => {
            const d = state.shiftSegments(deltaMs);
            if (d !== 0)
              trackKvMotionSegmentsShifted({ project_id: projectId, count: state.selectedSegments.length, delta_ms: d });
          }}
          onCopySelection={() => {
            if (!state.copySegments("menu"))
              showToast("Nothing to copy", "The selected bars carry no keyframes.", "error");
          }}
          onDeleteSelection={() => {
            const groups = state.selectedSegments.map((r) => r.group ?? "block");
            const n = state.deleteSegments();
            if (n > 0) trackKvMotionSegmentsDeleted({ project_id: projectId, count: n, groups });
          }}
          onCopyLaneSegment={(trackId, group, startMs, endMs) => {
            state.selectSegment({ trackId, group, startMs, endMs });
            // selectSegment is async state; copy from the explicit ref instead:
            if (!state.copySegmentRefs([{ trackId, group, startMs, endMs }], "menu"))
              showToast("Nothing to copy", "That bar carries no keyframes.", "error");
          }}
          onDeleteLaneSegment={(trackId, group, startMs, endMs) =>
            state.deleteSegmentRefsNow([{ trackId, group, startMs, endMs }])}
          clipSegmentCount={clipSegmentCount}
```
This needs two small hook additions (add with a test each in `useMotionEditorState.segments.test.tsx`): `copySegmentRefs(refs, source): boolean` — the body of `copySegments` parameterised by `refs` (make `copySegments` call it with `selectedSegments`); `deleteSegmentRefsNow(refs): number` — the body of `deleteSegments` parameterised (make `deleteSegments` call it). `clipSegmentCount` = `useKvMotionClipStore((s) => s.clip?.scope === "segments" ? s.clip.segments.length : 0)` in the editor; pass `pasteSegmentCount={clipSegmentCount}` in `trackPresetMenuProps`.

Analytics in `pasteMotion` / `pasteMotionToTracks`: when `clip.scope === "segments"` set `placement: "source_time"`, `segment_count: clip.segments.length`, `groups: clip.segments.map((s) => s.group ?? "block")`.

Dock hint: in `TimelineDock`'s header (grep `PanelHeader` / `hint=` in `TimelineDock.tsx`), set `hint="⌘-click bars to select several"`; if the dock has no `PanelHeader`, add the hint as a `title` on the dock's rail header cell instead — do not invent a new header.

- [ ] **Step 2: Run the full related suite**

```bash
cd web && bun test \
  src/lib/video-editor/segmentSelection.test.ts src/lib/video-editor/segmentSelection.bulk.test.ts \
  src/lib/video-editor/blocks.deletePropGroup.test.ts src/lib/video-editor/blocks.test.ts \
  src/lib/video-editor/motionClip.test.ts src/lib/video-editor/motionClip.segments.test.ts \
  src/components/studio/kv-generator/motion/useMotionEditorState.segments.test.tsx \
  src/components/studio/kv-generator/motion/useMotionEditorState.pasteSegments.test.ts \
  src/components/studio/kv-generator/motion/useMotionEditorState.copyPasteMotion.test.tsx \
  src/components/studio/kv-generator/motion/useMotionEditorState.bulk.test.tsx \
  src/components/studio/kv-generator/motion/useMotionEditorState.selection.test.tsx \
  src/components/studio/kv-generator/motion/motionClipboardKeys.test.ts \
  src/components/studio/kv-generator/motion/motionSegmentKeys.test.ts \
  src/components/studio/kv-generator/motion/TrackPresetMenu.test.tsx \
  src/components/studio/kv-generator/motion/TrackPresetMenu.pasteSegments.test.tsx \
  src/components/video-editor/BlockTrackRow.segmentSelect.test.tsx \
  src/components/video-editor/BlockTrackRow.dragTogether.test.tsx \
  src/components/video-editor/BlockTrackRow.segmentMenu.test.tsx \
  src/components/video-editor/PropSegmentBar.menu.test.tsx
```
Plus every existing `BlockTrackRow.*.test.tsx` and `PropSegmentBar*.test.tsx` (list with `ls src/components/video-editor/*.test.tsx`).

- [ ] **Step 3: Lint every touched file** — `bunx eslint <files> --fix`; `bunx prettier --write` the new files.

- [ ] **Step 4: Commit**

```bash
git add -A src
git commit -m "feat(web): KV Motion — wire segment multi-select into the editor: dock props, lane copy/delete, toasts, analytics, hint

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 13: Live verification + PR

- [ ] **Step 1: Run the app** (api-workers / web / ai-service via `preview_start`; api-queue after web so the queue does not take port 3000). Open a Motion project with a layer that has ≥ 3 emphasis pulses (apply Pulse three times at different playheads if needed).
- [ ] **Step 2: Checklist**
  - ⌘-click two block bars → both ringed; rail shows only that layer selected.
  - Expand the layer; ⇧-click Scale #1 then Scale #3 → three lane bars ringed.
  - Right-click a ringed bar → "Copy 3 segments"; right-click a layer B row → "Paste 3 segments" → bars appear on B at the SAME times; B's existing opacity keyframes in that window survive.
  - ⇧⌘C / ⇧⌘V does the same onto the primary layer.
  - Backspace removes the 3; ⌘Z brings all back in one step.
  - Drag one ringed bar → the others follow live; release → all moved; ⌘Z restores all in one step; dragging into an unselected neighbour stops 1 ms short.
  - Right-click a single lane bar → "Copy Scale" / "Delete Scale".
  - Empty-slot chip and a block's right-click show no Paste while a segments clip is held.
  - Esc / plain click / canvas click clears the ring.
  - Locked or hidden layer: bars ignore ⌘-click.
- [ ] **Step 3: Push + PR**

```bash
git push -u origin feature/daffa/vc-kv-motion-segment-multi-select
gh pr create --base develop --title "feat(web): KV Motion — multi-select segments: copy at source time, delete, drag together" --body "…spec link, file table, test plan (the checklist above), 🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```
- [ ] **Step 4: Memory note** — update `project_kv_motion_rail_build_tab.md`'s sibling: write `project_kv_motion_segment_multi_select.md` (PR number, what is/isn't verified) and one index line in `MEMORY.md`.
