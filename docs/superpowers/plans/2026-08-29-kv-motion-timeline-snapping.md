# KV Motion — Timeline Snapping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make segment drags in the KV Motion timeline snap to the guides around them — timeline bounds, playhead, drawn ruler gridlines, other layers' block edges, the audio clip, and the preview range — with a visible guide line and an Alt-to-bypass escape hatch.

**Architecture:** A pure `snapEdges` in a new `snap.ts` decides the snapped value; it knows nothing about the DOM. `TimelineDock` — the only component that sees every track — collects the guide list once per render and hands it down. `SegmentBar.handleMove` snaps first, then applies its existing wall clamp, so walls always win. Ruler tick arithmetic is extracted from `TimelineRuler` into `ticks.ts` first, so a snap target can only ever be a gridline the ruler actually paints.

**Tech Stack:** TypeScript, React 19, `bun test`, `@testing-library/react`.

**Spec:** `docs/superpowers/specs/2026-08-29-kv-motion-timeline-upgrades-design.md`

## Global Constraints

- Worktree: `web/.worktrees/kv-motion-timeline-upgrades`, branch `feature/daffa/vc-kv-motion-timeline-upgrades`. All paths are relative to it.
- Tests run with **`bun test`**, never `bunx vitest`.
- No type gate: `next build` sets `ignoreBuildErrors` and `tsc` has a large pre-existing baseline. Don't treat bare `tsc` output as a regression signal.
- `src/lib/video-editor/` must not import from `components/studio/kv-generator` or `lib/studio/kv` — `importBoundary.test.ts` enforces it.
- Snap tolerance is **8 CSS pixels**, converted to ms through the lane width the drag already measures — so the feel is identical at every zoom level. Never hardcode a millisecond tolerance.
- Snapping changes the *value* a drag commits, never the number of commits. No new `push()` calls.
- Scope is the **Slots view's segment drags only** (body, left handle, right handle). Keyframe-diamond drags in the "keyframes" view are untouched.

## File Structure

| File | Responsibility |
|---|---|
| `src/lib/video-editor/ticks.ts` (create) | Ruler tick-step arithmetic, extracted verbatim from `TimelineRuler` |
| `src/lib/video-editor/ticks.test.ts` (create) | Tests for the extracted arithmetic |
| `src/components/video-editor/TimelineRuler.tsx` (modify) | Import `rulerTicks` instead of computing inline |
| `src/lib/video-editor/snap.ts` (create) | `snapEdges` — pure, DOM-free |
| `src/lib/video-editor/snap.test.ts` (create) | `snapEdges` tests |
| `src/components/video-editor/TimelineDock.tsx` (modify) | Collect the guide list; pass it to `BlockTrackRow` |
| `src/components/video-editor/BlockTrackRow.tsx` (modify) | Snap inside the drag; render the guide line; Alt bypass |
| `src/components/video-editor/TimelineDock.test.tsx` (modify) | Drag tests for snapping, Alt, and wall precedence |

---

### Task 1: Extract ruler tick arithmetic into the engine

A snap target is only meaningful if it lands on a gridline the ruler actually draws. That arithmetic is private to `TimelineRuler` today. Extract it verbatim — pure refactor, no behaviour change — so the guide list and the painted gridlines cannot drift apart.

**Files:**
- Create: `src/lib/video-editor/ticks.ts`
- Create: `src/lib/video-editor/ticks.test.ts`
- Modify: `src/components/video-editor/TimelineRuler.tsx`

**Interfaces:**
- Consumes: nothing.
- Produces:

```ts
export const TICK_STEPS_SEC: readonly number[];
export const MIN_LABEL_GAP_PX: number;
export const MIN_MINOR_GAP_PX: number;
export function buildTicks(durationSec: number, stepSec: number): number[];
export function rulerTicks(
  durationMs: number,
  pxPerSecond: number,
): { labelTicksSec: number[]; minorTicksSec: number[] };
```

- [ ] **Step 1: Write the failing test**

Create `src/lib/video-editor/ticks.test.ts`:

```ts
import { describe, expect, it } from "bun:test";
import { buildTicks, rulerTicks } from "./ticks";

describe("buildTicks", () => {
  it("emits every multiple of the step up to and including the duration", () => {
    expect(buildTicks(2, 0.5)).toEqual([0, 0.5, 1, 1.5, 2]);
  });

  it("does not drift on repeated 0.1s steps", () => {
    expect(buildTicks(0.5, 0.1)).toEqual([0, 0.1, 0.2, 0.3, 0.4, 0.5]);
  });

  it("returns nothing for a non-positive duration or step", () => {
    expect(buildTicks(0, 1)).toEqual([]);
    expect(buildTicks(5, 0)).toEqual([]);
  });
});

describe("rulerTicks", () => {
  it("picks the coarsest round step that keeps labels >= 56px apart", () => {
    // 60px/s: 0.1s -> 6px, 0.25s -> 15px, 0.5s -> 30px, 1s -> 60px (first fit).
    const { labelTicksSec } = rulerTicks(3000, 60);
    expect(labelTicksSec).toEqual([0, 1, 2, 3]);
  });

  it("subdivides four ways while minor ticks stay >= 10px apart", () => {
    // 60px/s, label step 1s -> minor step 0.25s -> 15px apart. Rendered.
    const { minorTicksSec } = rulerTicks(1000, 60);
    expect(minorTicksSec).toEqual([0, 0.25, 0.5, 0.75, 1]);
  });

  it("drops minor ticks entirely when they would read as a grey band", () => {
    // 30px/s, label step 2s -> minor step 0.5s -> 15px... still fine, so go
    // tighter: 8px/s, label step 15s -> minor 3.75s -> 30px. Use a scale where
    // the minor gap actually falls under 10px.
    const { minorTicksSec } = rulerTicks(30000, 1);
    expect(minorTicksSec).toEqual([]);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bun test src/lib/video-editor/ticks.test.ts`
Expected: FAIL — cannot resolve `./ticks`

- [ ] **Step 3: Create `ticks.ts` by moving the code out of `TimelineRuler.tsx`**

```ts
/** Ruler tick arithmetic — extracted from `TimelineRuler` so the SNAP guide
 *  list and the gridlines the ruler actually paints are derived from one
 *  place. A snap target that isn't a drawn line is a lie; keeping these in
 *  two files is how that lie would eventually happen. Pure and DOM-free, so
 *  it belongs in the engine rather than beside the component. */

/** Tick intervals (seconds) a viewer reads as round. Ascending — the ruler
 *  takes the first one that fits the current scale. */
export const TICK_STEPS_SEC = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30] as const;
export const MIN_LABEL_GAP_PX = 56;
export const MIN_MINOR_GAP_PX = 10;

/** Every multiple of `stepSec` from 0 up to (and including, when it lands
 *  exactly) `durationSec`. Rounded per index rather than accumulated so 0.1s
 *  steps don't drift on float addition. */
export function buildTicks(durationSec: number, stepSec: number): number[] {
  if (durationSec <= 0 || stepSec <= 0) return [];
  const count = Math.floor(durationSec / stepSec + 1e-6);
  return Array.from({ length: count + 1 }, (_, i) =>
    Number((i * stepSec).toFixed(3)),
  );
}

/** The labelled and minor gridlines (in seconds) for a ruler of `durationMs`
 *  drawn at `pxPerSecond`. Labelled ticks take the coarsest-looking round
 *  interval that still keeps labels at least `MIN_LABEL_GAP_PX` apart,
 *  falling back to the largest step if even that is too tight. Minor ticks
 *  subdivide the labelled ones four ways, but only while they stay far
 *  enough apart to read as texture rather than a grey band. */
export function rulerTicks(
  durationMs: number,
  pxPerSecond: number,
): { labelTicksSec: number[]; minorTicksSec: number[] } {
  const labelStepSec =
    TICK_STEPS_SEC.find((step) => step * pxPerSecond >= MIN_LABEL_GAP_PX) ??
    TICK_STEPS_SEC[TICK_STEPS_SEC.length - 1];
  const durationSec = durationMs / 1000;
  const minorStepSec = labelStepSec / 4;
  return {
    labelTicksSec: buildTicks(durationSec, labelStepSec),
    minorTicksSec:
      minorStepSec * pxPerSecond >= MIN_MINOR_GAP_PX
        ? buildTicks(durationSec, minorStepSec)
        : [],
  };
}
```

- [ ] **Step 4: Point `TimelineRuler.tsx` at it**

Delete the local `TICK_STEPS_SEC`, `MIN_LABEL_GAP_PX`, `MIN_MINOR_GAP_PX` and `buildTicks` declarations. Add the import:

```ts
import { rulerTicks } from "@/lib/video-editor/ticks";
```

Replace the `labelStepSec` / `labelTicks` / `minorStepSec` / `minorTicks` block (with its comments) with:

```ts
  const durationSec = durationMs / 1000;
  const { labelTicksSec: labelTicks, minorTicksSec: minorTicks } = rulerTicks(
    durationMs,
    pxPerSecond,
  );
```

`durationSec` stays — the render still uses it to position each tick.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bun test src/lib/video-editor/ticks.test.ts src/components/video-editor/`
Expected: PASS — the ruler's existing tests are the proof the refactor changed nothing

- [ ] **Step 6: Commit**

```bash
git add src/lib/video-editor/ticks.ts src/lib/video-editor/ticks.test.ts src/components/video-editor/TimelineRuler.tsx
git commit -m "refactor(web): extract ruler tick arithmetic into video-editor/ticks"
```

---

### Task 2: `snapEdges` engine function

**Files:**
- Create: `src/lib/video-editor/snap.ts`
- Create: `src/lib/video-editor/snap.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces:

```ts
export type SnapGuideKind =
  | "bound" | "playhead" | "preview" | "segment" | "audio" | "tick";
export type SnapGuide = { ms: number; kind: SnapGuideKind };
export type SnapMode = "body" | "left" | "right";
export type SnapResult = { startMs: number; endMs: number; hitMs: number | null };
export const SNAP_TOLERANCE_PX = 8;
export function snapEdges(
  startMs: number,
  endMs: number,
  mode: SnapMode,
  guides: readonly SnapGuide[],
  toleranceMs: number,
): SnapResult;
```

- [ ] **Step 1: Write the failing tests**

Create `src/lib/video-editor/snap.test.ts`:

```ts
import { describe, expect, it } from "bun:test";
import { snapEdges, type SnapGuide } from "./snap";

const g = (...ms: number[]): SnapGuide[] =>
  ms.map((v) => ({ ms: v, kind: "segment" as const }));

describe("snapEdges", () => {
  it("passes through with no guides", () => {
    expect(snapEdges(100, 600, "body", [], 50)).toEqual({
      startMs: 100,
      endMs: 600,
      hitMs: null,
    });
  });

  it("passes through with a zero or negative tolerance", () => {
    expect(snapEdges(100, 600, "body", g(105), 0)).toEqual({
      startMs: 100,
      endMs: 600,
      hitMs: null,
    });
  });

  it("ignores guides outside the tolerance", () => {
    expect(snapEdges(100, 600, "left", g(200), 50).hitMs).toBeNull();
  });

  it("body mode moves BOTH edges and preserves the span", () => {
    // start 100 is 10ms from the guide at 90.
    const r = snapEdges(100, 600, "body", g(90), 50);
    expect(r).toEqual({ startMs: 90, endMs: 590, hitMs: 90 });
  });

  it("body mode can snap on the TRAILING edge", () => {
    // end 600 is 5ms from 605; start 100 has nothing within tolerance.
    const r = snapEdges(100, 600, "body", g(605), 20);
    expect(r).toEqual({ startMs: 105, endMs: 605, hitMs: 605 });
  });

  it("left mode moves only the start", () => {
    expect(snapEdges(100, 600, "left", g(90), 50)).toEqual({
      startMs: 90,
      endMs: 600,
      hitMs: 90,
    });
  });

  it("right mode moves only the end", () => {
    expect(snapEdges(100, 600, "right", g(620), 50)).toEqual({
      startMs: 100,
      endMs: 620,
      hitMs: 620,
    });
  });

  it("picks the NEAREST of several competing guides", () => {
    const r = snapEdges(100, 600, "left", g(80, 95, 130), 50);
    expect(r.hitMs).toBe(95);
  });

  it("breaks an exact tie toward the lower guide, regardless of input order", () => {
    // start 100: guides at 90 and 110 are both 10ms away.
    expect(snapEdges(100, 600, "left", g(110, 90), 50).hitMs).toBe(90);
    expect(snapEdges(100, 600, "left", g(90, 110), 50).hitMs).toBe(90);
  });

  it("never returns a non-finite value", () => {
    const r = snapEdges(0, 0, "body", g(0), 8);
    expect(Number.isFinite(r.startMs)).toBe(true);
    expect(Number.isFinite(r.endMs)).toBe(true);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bun test src/lib/video-editor/snap.test.ts`
Expected: FAIL — cannot resolve `./snap`

- [ ] **Step 3: Implement `snap.ts`**

```ts
/** Timeline drag snapping — pure, DOM-free, and deliberately ignorant of
 *  where the guides came from. The caller (TimelineDock) decides what counts
 *  as a guide; this only answers "given these, where does the drag land". */

export type SnapGuideKind =
  /** 0 and `duration_ms`. */
  | "bound"
  | "playhead"
  /** A preview-range bracket. */
  | "preview"
  /** Another block's edge, on this track or any other. */
  | "segment"
  /** The audio clip's start or end. */
  | "audio"
  /** A gridline the ruler actually paints (see `ticks.ts`). */
  | "tick";

export type SnapGuide = { ms: number; kind: SnapGuideKind };

export type SnapMode = "body" | "left" | "right";

export type SnapResult = {
  startMs: number;
  endMs: number;
  /** The guide the drag latched onto, or `null` when nothing was in range.
   *  The UI draws its guide line here. */
  hitMs: number | null;
};

/** Snap tolerance in CSS pixels. Pixels, not milliseconds, so the drag feels
 *  identical at every zoom level — the caller converts it through the lane
 *  width it has already measured. */
export const SNAP_TOLERANCE_PX = 8;

/** Move a dragged span onto the nearest guide within `toleranceMs`.
 *
 *  - `"body"` — both edges are candidates; the globally nearest wins and BOTH
 *    edges move by that delta, so the span is preserved.
 *  - `"left"` / `"right"` — only that edge is a candidate, and only it moves.
 *
 *  Ties break toward the LOWER guide, so the result never depends on the
 *  order the caller happened to collect its guides in. A non-positive
 *  tolerance or an empty guide list passes straight through. Total: never
 *  throws, never returns a non-finite number. */
export function snapEdges(
  startMs: number,
  endMs: number,
  mode: SnapMode,
  guides: readonly SnapGuide[],
  toleranceMs: number,
): SnapResult {
  if (toleranceMs <= 0 || guides.length === 0) {
    return { startMs, endMs, hitMs: null };
  }

  let hitMs: number | null = null;
  let delta = 0;
  let bestDist = Infinity;

  function consider(edge: number): void {
    for (const guide of guides) {
      const dist = Math.abs(guide.ms - edge);
      if (dist > toleranceMs) continue;
      if (dist < bestDist || (dist === bestDist && hitMs !== null && guide.ms < hitMs)) {
        bestDist = dist;
        hitMs = guide.ms;
        delta = guide.ms - edge;
      }
    }
  }

  if (mode === "body") {
    consider(startMs);
    consider(endMs);
  } else if (mode === "left") {
    consider(startMs);
  } else {
    consider(endMs);
  }

  if (hitMs === null) return { startMs, endMs, hitMs: null };
  if (mode === "body") {
    return { startMs: startMs + delta, endMs: endMs + delta, hitMs };
  }
  if (mode === "left") return { startMs: startMs + delta, endMs, hitMs };
  return { startMs, endMs: endMs + delta, hitMs };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bun test src/lib/video-editor/snap.test.ts`
Expected: PASS (10 tests)

- [ ] **Step 5: Commit**

```bash
git add src/lib/video-editor/snap.ts src/lib/video-editor/snap.test.ts
git commit -m "feat(web): snapEdges — pure timeline drag snapping"
```

---

### Task 3: Collect the guide list in `TimelineDock`

**Files:**
- Modify: `src/components/video-editor/TimelineDock.tsx`
- Modify: `src/components/video-editor/BlockTrackRow.tsx` (prop only — the drag itself lands in Task 4)

**Interfaces:**
- Consumes: `SnapGuide` and `rulerTicks` from Tasks 1–2; `trackSegments` from `@/lib/video-editor/blocks`.
- Produces: `snapGuides: readonly SnapGuide[]` on `BlockTrackRowProps`, and `excludeSegment` filtering inside `SegmentBar` (Task 4 consumes it).

- [ ] **Step 1: Add the guide `useMemo` to `TimelineDock`**

Add the imports:

```ts
import { trackSegments } from "@/lib/video-editor/blocks";
import { rulerTicks } from "@/lib/video-editor/ticks";
import type { SnapGuide } from "@/lib/video-editor/snap";
```

Insert directly after the existing `keyframesByTrack` `useMemo`:

```ts
  // Every guide a segment drag may latch onto. Built HERE because this is the
  // only component that sees all of it at once: every track's segments, the
  // duration, the playhead, the preview range, and the audio clip (which
  // reaches the dock as an opaque `audioSlot` node, but whose times live on
  // the timeline document this component already holds).
  //
  // Deduped by ms with a fixed kind priority, so a guide that is BOTH a
  // gridline and a block edge renders as one line with one stable style
  // rather than two stacked on the same pixel.
  const snapGuides = useMemo<SnapGuide[]>(() => {
    const priority: Record<SnapGuide["kind"], number> = {
      bound: 0,
      playhead: 1,
      preview: 2,
      segment: 3,
      audio: 4,
      tick: 5,
    };
    const byMs = new Map<number, SnapGuide>();
    const add = (ms: number, kind: SnapGuide["kind"]) => {
      if (!Number.isFinite(ms) || ms < 0 || ms > timeline.duration_ms) return;
      const rounded = Math.round(ms);
      const existing = byMs.get(rounded);
      if (existing && priority[existing.kind] <= priority[kind]) return;
      byMs.set(rounded, { ms: rounded, kind });
    };

    add(0, "bound");
    add(timeline.duration_ms, "bound");
    add(playheadMs, "playhead");
    if (previewRange) {
      add(previewRange.startMs, "preview");
      add(previewRange.endMs, "preview");
    }
    for (const track of timeline.tracks) {
      if (track.kind !== "overlay") continue;
      for (const seg of trackSegments(track)) {
        add(seg.startMs, "segment");
        add(seg.endMs, "segment");
      }
    }
    if (timeline.audio) {
      const { start_ms, trim_in_ms, trim_out_ms } = timeline.audio;
      add(start_ms, "audio");
      add(start_ms + (trim_out_ms - trim_in_ms), "audio");
    }
    const { labelTicksSec, minorTicksSec } = rulerTicks(
      timeline.duration_ms,
      pxPerSecond,
    );
    for (const sec of [...labelTicksSec, ...minorTicksSec]) {
      add(sec * 1000, "tick");
    }

    return [...byMs.values()].sort((a, b) => a.ms - b.ms);
  }, [timeline, playheadMs, previewRange, pxPerSecond]);
```

- [ ] **Step 2: Pass it to `BlockTrackRow`**

Add to the `<BlockTrackRow ... />` call:

```tsx
                snapGuides={snapGuides}
```

- [ ] **Step 3: Accept it in `BlockTrackRow`**

Add to `BlockTrackRowProps`:

```ts
  /** Every guide a drag on this row may snap to, collected by `TimelineDock`
   *  across ALL tracks. A `SegmentBar` filters out its OWN two edges before
   *  using it — a block must not snap to itself. */
  snapGuides: readonly SnapGuide[];
```

Add the import `import type { SnapGuide } from "@/lib/video-editor/snap";`, destructure `snapGuides` in the component signature, and pass `snapGuides={snapGuides}` down to each `<SegmentBar ... />` (declaring `snapGuides: readonly SnapGuide[]` on `SegmentBarProps` and destructuring it there too).

- [ ] **Step 4: Verify nothing regressed**

Run: `bun test src/components/video-editor/`
Expected: PASS — no behaviour has changed yet; this step only proves the prop threads cleanly

- [ ] **Step 5: Commit**

```bash
git add src/components/video-editor/TimelineDock.tsx src/components/video-editor/BlockTrackRow.tsx
git commit -m "feat(web): collect timeline snap guides in TimelineDock"
```

---

### Task 4: Snap the drag, draw the guide line, honour Alt

**Files:**
- Modify: `src/components/video-editor/BlockTrackRow.tsx`
- Modify: `src/components/video-editor/TimelineDock.test.tsx`

**Interfaces:**
- Consumes: `snapEdges`, `SNAP_TOLERANCE_PX` (Task 2); `snapGuides` (Task 3).
- Produces: `data-testid="snap-guide-<trackId>"` on the guide line element.

- [ ] **Step 1: Write the failing tests**

Append to `src/components/video-editor/TimelineDock.test.tsx`. `stubLaneRect(500)` makes the 500px lane represent the default 5000ms timeline, so **1px = 10ms** and the 8px tolerance is **80ms**.

First add a two-**track** fixture next to the existing ones. This matters: a same-track neighbour's edge can never actually be reached, because `stretchSegmentKeyframes` enforces 1ms clearance and `SegmentBar` clamps the live drag to the same wall. Cross-lane alignment — one layer's block starting where another layer's ends — is both the case that works and the case worth having.

```ts
// Two TRACKS (not two clusters on one track): ov1 has a single [0,1000]
// block with no neighbour of its own, ov2 has one at [2000,3000]. Dragging
// ov1's right handle toward 2000 is the cross-lane snap this feature exists
// for — and, unlike a same-track neighbour, 2000 is actually reachable,
// since ov1's own wall is the timeline end.
const twoTrackTl = () => ({
  ...DEFAULT_TIMELINE(),
  tracks: [
    {
      kind: "overlay" as const,
      overlay_id: "ov1",
      keyframes: [
        { t_ms: 0, props: { opacity: 0 }, easing: "linear" as const },
        { t_ms: 1000, props: { opacity: 1 }, easing: "out" as const },
      ],
    },
    {
      kind: "overlay" as const,
      overlay_id: "ov2",
      keyframes: [
        { t_ms: 2000, props: { scale: 1 }, easing: "linear" as const },
        { t_ms: 3000, props: { scale: 1.1 }, easing: "out" as const },
      ],
    },
  ],
});

const TWO_TRACKS = [
  { id: "ov1", name: "Headline", icon: "text" as const },
  { id: "ov2", name: "Logo", icon: "image" as const },
];
```

Then the tests:

```ts
  it("a right-handle drag snaps to ANOTHER track's block edge and shows a guide line", () => {
    // Drag ov1's right handle from 1000 to 1950 (+95px) — 50ms from ov2's
    // start at 2000, inside the 80ms tolerance.
    const h = renderDock({
      view: "slots",
      timeline: twoTrackTl(),
      tracks: TWO_TRACKS,
    });
    stubLaneRect(500);
    act(() => flushResizeObservers());
    const body = within(document.body);
    const handle = body.getByTestId("block-handle-right-ov1-0");

    fireEvent.pointerDown(handle, { clientX: 0, pointerId: 1 });
    fireEvent.pointerMove(handle, { clientX: 95, pointerId: 1 });
    expect(body.getByTestId("snap-guide-ov1")).toBeInTheDocument();

    fireEvent.pointerUp(handle, { pointerId: 1 });
    expect(h.onStretchSegment).toHaveBeenCalledWith("ov1", 0, 1000, 0, 2000);
    expect(body.queryByTestId("snap-guide-ov1")).not.toBeInTheDocument();
  });

  it("holding Alt during the drag commits the raw value, with no guide line", () => {
    const h = renderDock({
      view: "slots",
      timeline: twoTrackTl(),
      tracks: TWO_TRACKS,
    });
    stubLaneRect(500);
    act(() => flushResizeObservers());
    const body = within(document.body);
    const handle = body.getByTestId("block-handle-right-ov1-0");

    fireEvent.pointerDown(handle, { clientX: 0, pointerId: 1 });
    fireEvent.pointerMove(handle, { clientX: 95, pointerId: 1, altKey: true });
    expect(body.queryByTestId("snap-guide-ov1")).not.toBeInTheDocument();

    fireEvent.pointerUp(handle, { pointerId: 1 });
    expect(h.onStretchSegment).toHaveBeenCalledWith("ov1", 0, 1000, 0, 1950);
  });

  it("a same-track neighbour's wall beats the snap guide sitting on it", () => {
    // labeledTwoClusterTl puts BOTH blocks on ov1: [0,1000] and [2000,3000].
    // The guide at 2000 is in range of a +95px drag, but ov1's own wall is
    // nextSegment.startMs - 1 = 1999 — so the wall wins, the committed value
    // is 1999, and no guide line is drawn for a snap that didn't happen.
    const h = renderDock({ view: "slots", timeline: labeledTwoClusterTl() });
    stubLaneRect(500);
    act(() => flushResizeObservers());
    const body = within(document.body);
    const handle = body.getByTestId("block-handle-right-ov1-0");

    fireEvent.pointerDown(handle, { clientX: 0, pointerId: 1 });
    fireEvent.pointerMove(handle, { clientX: 95, pointerId: 1 });
    expect(body.queryByTestId("snap-guide-ov1")).not.toBeInTheDocument();

    fireEvent.pointerUp(handle, { pointerId: 1 });
    expect(h.onStretchSegment).toHaveBeenCalledWith("ov1", 0, 1000, 0, 1999);
  });
```

No harness change is needed for `snapGuides` — `TimelineDock` computes it internally (Task 3) rather than taking it as a prop.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bun test src/components/video-editor/TimelineDock.test.tsx`
Expected: FAIL — no `snap-guide-ov1` element, and the stretch commits the raw 1950

- [ ] **Step 3: Snap inside `handleMove`**

Add the import to `BlockTrackRow.tsx`:

```ts
import { snapEdges, SNAP_TOLERANCE_PX, type SnapGuide } from "@/lib/video-editor/snap";
```

Add a `snapHit` state next to the existing `draft` state in `SegmentBar`:

```ts
  // The guide the live drag is currently latched onto, or null. Purely
  // visual — the snapped VALUE already lives in `draft`.
  const [snapHit, setSnapHit] = useState<number | null>(null);
```

Replace the body of `handleMove` with:

```ts
  function handleMove(e: React.PointerEvent<HTMLDivElement>) {
    const d = drag.current;
    if (!d || !laneRef.current) return;
    const rect = laneRef.current.getBoundingClientRect();
    const deltaMs = rect.width > 0 ? ((e.clientX - d.startX) / rect.width) * durationMs : 0;

    // Alt bypasses snapping, read live off each move event so it can be
    // pressed and released mid-drag. Tolerance is converted from pixels
    // through the lane's own measured width, so it feels the same at every
    // zoom level.
    const toleranceMs =
      e.altKey || rect.width <= 0
        ? 0
        : (SNAP_TOLERANCE_PX / rect.width) * durationMs;
    // A block must never snap to its own edges.
    const guides = snapGuides.filter(
      (g) => g.ms !== d.startMs && g.ms !== d.endMs,
    );

    let nextStart: number;
    let nextEnd: number;
    let hit: number | null;

    if (d.kind === "body") {
      const span = d.endMs - d.startMs;
      const rawStart = Math.round(d.startMs + deltaMs);
      const snapped = snapEdges(rawStart, rawStart + span, "body", guides, toleranceMs);
      hit = snapped.hitMs;
      nextStart = clamp(snapped.startMs, wallMin, Math.max(wallMin, wallMax - span));
      nextEnd = nextStart + span;
    } else if (d.kind === "left") {
      const snapped = snapEdges(
        Math.round(d.startMs + deltaMs),
        d.endMs,
        "left",
        guides,
        toleranceMs,
      );
      hit = snapped.hitMs;
      nextStart = clamp(snapped.startMs, wallMin, d.endMs);
      nextEnd = d.endMs;
    } else {
      const snapped = snapEdges(
        d.startMs,
        Math.round(d.endMs + deltaMs),
        "right",
        guides,
        toleranceMs,
      );
      hit = snapped.hitMs;
      nextStart = d.startMs;
      nextEnd = clamp(snapped.endMs, d.startMs, wallMax);
    }

    // Walls always win. If the clamp moved the drag off the guide, there is
    // no snap to advertise — showing a line the block isn't actually on
    // would be the UI lying about what will commit.
    setDraft({ startMs: nextStart, endMs: nextEnd });
    setSnapHit(hit !== null && (nextStart === hit || nextEnd === hit) ? hit : null);
  }
```

- [ ] **Step 4: Clear the guide when the drag ends or is cancelled**

Add `setSnapHit(null);` next to the existing `setDraft(null);` in **both** `handleUp` and the drag-cancelling branch of `handleContextMenu`.

- [ ] **Step 5: Render the guide line**

In `SegmentBar`, directly above the `contextMenu` declaration:

```tsx
  // Drawn full-height across the lane at the latched guide, so the drag shows
  // WHAT it is aligning to, not just that it stopped moving. Mounted only
  // while a snap is live; `pointer-events-none` so it can never intercept the
  // drag that is drawing it.
  const snapGuideLine = snapHit !== null && durationMs > 0 && (
    <div
      data-testid={`snap-guide-${trackId}`}
      aria-hidden
      style={{ left: `${(snapHit / durationMs) * 100}%` }}
      className="pointer-events-none absolute inset-y-0 z-30 w-px -translate-x-1/2 bg-white/70"
    />
  );
```

Render `{snapGuideLine}` alongside `{contextMenu}` in **both** return branches (the still-point marker and the bar), so a body drag on either shows it.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bun test src/components/video-editor/TimelineDock.test.tsx`
Expected: PASS, including the pre-existing drag tests

- [ ] **Step 7: Run the full timeline suite**

Run: `bun test src/components/video-editor/ src/lib/video-editor/`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add src/components/video-editor/BlockTrackRow.tsx src/components/video-editor/TimelineDock.test.tsx
git commit -m "feat(web): snap segment drags to timeline guides, Alt to bypass"
```

---

## Manual verification

1. Open a KV motion project with two or more animated layers, in the **Slots** view.
2. Drag one layer's block near another layer's block edge — it latches, and a white vertical line marks what it latched to.
3. Drag near a second gridline on the ruler — it latches there too, at every zoom level (check at Fit and at 400%).
4. Drag near the playhead — it latches.
5. Hold **Alt** mid-drag — the line disappears and the block moves freely; release and it latches again.
6. Drag a block hard into its neighbour — it stops at the wall, with no guide line, and does not overlap.
7. With audio loaded, drag near the audio clip's start — it latches.

## Before calling this done

Invoke the `frndos-analytics-events` agent over the changed web files.
