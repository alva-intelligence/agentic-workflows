# Motion Per-Property Lane Drag Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the per-property sub-row bars in the KV Motion timeline draggable — body drag to retime, edge handles to resize — so one layer's Move can run 1s while its Scale runs 0.4s and starts later.

**Architecture:** A lane drag implies splitting a keyframe, because one `MotionKeyframe` carries a sparse subset of several props. Two new pure writers in `blocks.ts` extract the dragged property group into keyframes of its own, duplicating `easing` (which means "curve INTO this keyframe", so both halves keep their real curve) and never merging onto an occupied time. On the UI side, `SegmentBar`'s existing drag machinery is extracted into a pure math module plus a thin hook, then reused by a slim lane bar, so there is exactly one drag implementation.

**Tech Stack:** TypeScript, React 19, Next.js 16, bun test + @testing-library/react.

**Spec:** `docs/superpowers/specs/2026-08-31-motion-prop-lane-drag-design.md`

## Global Constraints

- All work is in `web/`. Run every command from `web/`.
- Tests run with `bun test <path>` — **never** `bunx vitest`. `bunfig.toml` preloads jest-dom.
- `screen` from @testing-library is broken under bun here. Always use `within(document.body)`.
- New test files only. Do **not** add to `blocks.test.ts` (37.9KB) or `TimelineDock.test.tsx` (48.8KB) — both sit near bun 1.3.2's ~51KB transpiler cliff, past which the file dies with a bogus SCSS parse error naming `base.module.scss`.
- `TimelineDock.test.tsx` must not be edited at all. It is the regression net for Task 2 and it cannot grow.
- Lint changed files only: `bunx eslint <paths>`. Several files in `src/components/video-editor/` are already not prettier-clean at HEAD; do not reformat them.
- There is no type gate — `next build` sets `ignoreBuildErrors` and `tsc` has a large pre-existing error baseline. Judge `tsc --noEmit` output by whether YOUR files appear, not by the exit code.
- New props added to `TimelineDockProps` must be **optional**, so existing test harnesses gain no type errors.

---

### Task 1: Pure drag math

Extract the snap-and-clamp arithmetic that currently lives inside `SegmentBar.handleMove` into a pure function, so lane bars can reuse it and so it can be tested without pointer events.

**Files:**
- Create: `web/src/components/video-editor/barDragMath.ts`
- Test: `web/src/components/video-editor/barDragMath.test.ts`

**Interfaces:**
- Consumes: `snapEdges`, `SNAP_TOLERANCE_PX`, `SnapGuide` from `@/lib/video-editor/snap`; `clamp` from `./types`
- Produces:
  ```ts
  export type BarDragKind = "body" | "left" | "right";
  export function resolveBarDrag(input: {
    kind: BarDragKind;
    startMs: number;
    endMs: number;
    deltaMs: number;
    wallMin: number;
    wallMax: number;
    guides: readonly SnapGuide[];
    toleranceMs: number;
  }): { startMs: number; endMs: number; hitMs: number | null };
  ```

- [ ] **Step 1: Write the failing test**

Create `web/src/components/video-editor/barDragMath.test.ts`:

```ts
/** Pure drag arithmetic shared by the block bars and the per-property lane
 *  bars — snapping, wall clamping, and the rule that a wall always beats a
 *  guide. Extracted from SegmentBar so both callers cannot drift apart. */
import { describe, expect, it } from "bun:test";
import type { SnapGuide } from "@/lib/video-editor/snap";
import { resolveBarDrag } from "./barDragMath";

const NO_GUIDES: SnapGuide[] = [];

describe("resolveBarDrag — body", () => {
  it("shifts the whole span and keeps its length", () => {
    const r = resolveBarDrag({
      kind: "body",
      startMs: 1000,
      endMs: 1500,
      deltaMs: 200,
      wallMin: 0,
      wallMax: 5000,
      guides: NO_GUIDES,
      toleranceMs: 0,
    });

    expect(r).toEqual({ startMs: 1200, endMs: 1700, hitMs: null });
  });

  it("clamps against the right wall without shrinking the span", () => {
    const r = resolveBarDrag({
      kind: "body",
      startMs: 4000,
      endMs: 4500,
      deltaMs: 2000,
      wallMin: 0,
      wallMax: 5000,
      guides: NO_GUIDES,
      toleranceMs: 0,
    });

    expect(r.startMs).toBe(4500);
    expect(r.endMs).toBe(5000);
  });

  it("latches onto a guide inside the tolerance", () => {
    const r = resolveBarDrag({
      kind: "body",
      startMs: 1000,
      endMs: 1500,
      deltaMs: 190,
      wallMin: 0,
      wallMax: 5000,
      guides: [{ ms: 1200, kind: "segment" }],
      toleranceMs: 50,
    });

    expect(r.startMs).toBe(1200);
    expect(r.hitMs).toBe(1200);
  });

  it("never snaps to the bar's own edges", () => {
    const r = resolveBarDrag({
      kind: "body",
      startMs: 1000,
      endMs: 1500,
      deltaMs: 5,
      wallMin: 0,
      wallMax: 5000,
      guides: [{ ms: 1000, kind: "segment" }, { ms: 1500, kind: "segment" }],
      toleranceMs: 50,
    });

    expect(r.startMs).toBe(1005);
    expect(r.hitMs).toBeNull();
  });

  it("drops the snap when a wall pulls the bar off the guide", () => {
    // The guide is reachable, but the wall wins — advertising a snap the bar
    // did not land on would be the UI lying about what will commit.
    const r = resolveBarDrag({
      kind: "body",
      startMs: 4600,
      endMs: 4900,
      deltaMs: 120,
      wallMin: 0,
      wallMax: 5000,
      guides: [{ ms: 4720, kind: "segment" }],
      toleranceMs: 50,
    });

    expect(r.startMs).toBe(4700);
    expect(r.endMs).toBe(5000);
    expect(r.hitMs).toBeNull();
  });

  it("passes straight through when the tolerance is zero (alt held)", () => {
    const r = resolveBarDrag({
      kind: "body",
      startMs: 1000,
      endMs: 1500,
      deltaMs: 3,
      wallMin: 0,
      wallMax: 5000,
      guides: [{ ms: 1000, kind: "playhead" }],
      toleranceMs: 0,
    });

    expect(r.startMs).toBe(1003);
    expect(r.hitMs).toBeNull();
  });
});

describe("resolveBarDrag — handles", () => {
  it("moves only the start on a left drag", () => {
    const r = resolveBarDrag({
      kind: "left",
      startMs: 1000,
      endMs: 1500,
      deltaMs: -300,
      wallMin: 0,
      wallMax: 5000,
      guides: NO_GUIDES,
      toleranceMs: 0,
    });

    expect(r).toEqual({ startMs: 700, endMs: 1500, hitMs: null });
  });

  it("never lets the left handle cross the end", () => {
    const r = resolveBarDrag({
      kind: "left",
      startMs: 1000,
      endMs: 1500,
      deltaMs: 900,
      wallMin: 0,
      wallMax: 5000,
      guides: NO_GUIDES,
      toleranceMs: 0,
    });

    expect(r.startMs).toBe(1500);
    expect(r.endMs).toBe(1500);
  });

  it("moves only the end on a right drag", () => {
    const r = resolveBarDrag({
      kind: "right",
      startMs: 1000,
      endMs: 1500,
      deltaMs: 400,
      wallMin: 0,
      wallMax: 5000,
      guides: NO_GUIDES,
      toleranceMs: 0,
    });

    expect(r).toEqual({ startMs: 1000, endMs: 1900, hitMs: null });
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bun test ./src/components/video-editor/barDragMath.test.ts`
Expected: FAIL — cannot resolve `./barDragMath`.

- [ ] **Step 3: Write the implementation**

Create `web/src/components/video-editor/barDragMath.ts`:

```ts
import { snapEdges, type SnapGuide } from "@/lib/video-editor/snap";
import { clamp } from "./types";

/** Which part of a bar a gesture grabbed. */
export type BarDragKind = "body" | "left" | "right";

/** Where a bar drag lands: snapping applied, then walls, then an honest
 *  answer about whether the result is actually ON the guide.
 *
 *  Pure and DOM-free — the caller converts pointer pixels into `deltaMs`
 *  against the lane's measured width. Lifted verbatim out of `SegmentBar`
 *  (2026-08-31) so the per-property lane bars share ONE implementation of
 *  this arithmetic rather than growing a second one that drifts.
 *
 *  A bar never snaps to its own edges — a guide sitting exactly on
 *  `startMs`/`endMs` is dropped before matching, or every bar would stick to
 *  where it already is. */
export function resolveBarDrag({
  kind,
  startMs,
  endMs,
  deltaMs,
  wallMin,
  wallMax,
  guides,
  toleranceMs,
}: {
  kind: BarDragKind;
  startMs: number;
  endMs: number;
  deltaMs: number;
  wallMin: number;
  wallMax: number;
  guides: readonly SnapGuide[];
  toleranceMs: number;
}): { startMs: number; endMs: number; hitMs: number | null } {
  const own = guides.filter((g) => g.ms !== startMs && g.ms !== endMs);

  let nextStart: number;
  let nextEnd: number;
  let hit: number | null;

  if (kind === "body") {
    const span = endMs - startMs;
    const rawStart = Math.round(startMs + deltaMs);
    const snapped = snapEdges(
      rawStart,
      rawStart + span,
      "body",
      own,
      toleranceMs
    );
    hit = snapped.hitMs;
    nextStart = clamp(snapped.startMs, wallMin, Math.max(wallMin, wallMax - span));
    nextEnd = nextStart + span;
  } else if (kind === "left") {
    const snapped = snapEdges(
      Math.round(startMs + deltaMs),
      endMs,
      "left",
      own,
      toleranceMs
    );
    hit = snapped.hitMs;
    nextStart = clamp(snapped.startMs, wallMin, endMs);
    nextEnd = endMs;
  } else {
    const snapped = snapEdges(
      startMs,
      Math.round(endMs + deltaMs),
      "right",
      own,
      toleranceMs
    );
    hit = snapped.hitMs;
    nextStart = startMs;
    nextEnd = clamp(snapped.endMs, startMs, wallMax);
  }

  // Walls always win. If the clamp moved the bar off the guide there is no
  // snap to advertise — a guide line under a bar that did not land on it
  // would be the UI lying about what will commit.
  return {
    startMs: nextStart,
    endMs: nextEnd,
    hitMs: hit !== null && (nextStart === hit || nextEnd === hit) ? hit : null,
  };
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bun test ./src/components/video-editor/barDragMath.test.ts`
Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add src/components/video-editor/barDragMath.ts src/components/video-editor/barDragMath.test.ts
git commit -m "refactor(video-editor): extract bar drag arithmetic into a pure module"
```

---

### Task 2: `useBarDrag` hook, and `SegmentBar` refactored onto it

Behaviour-preserving. This is the only task where a regression can hide, which is why it ships alone: the existing drag suites are the net.

**Files:**
- Create: `web/src/components/video-editor/useBarDrag.ts`
- Modify: `web/src/components/video-editor/BlockTrackRow.tsx` (`SegmentBar`: delete `handleMove`/`handleUp`/`beginDrag` and the `drag`/`draft`/`snapHit` state, call the hook instead)

**Interfaces:**
- Consumes: `resolveBarDrag`, `BarDragKind` from Task 1
- Produces:
  ```ts
  export function useBarDrag(input: {
    startMs: number;
    endMs: number;
    durationMs: number;
    wallMin: number;
    wallMax: number;
    laneRef: RefObject<HTMLDivElement | null>;
    snapGuides: readonly SnapGuide[];
    locked: boolean;
    onShift: (fromStartMs: number, fromEndMs: number, deltaMs: number) => void;
    onStretch: (
      fromStartMs: number, fromEndMs: number,
      newStartMs: number, newEndMs: number,
    ) => void;
  }): {
    draft: { startMs: number; endMs: number } | null;
    snapHit: number | null;
    beginDrag: (kind: BarDragKind) => (e: React.PointerEvent<HTMLDivElement>) => void;
    handleMove: (e: React.PointerEvent<HTMLDivElement>) => void;
    handleUp: () => void;
  };
  ```

- [ ] **Step 1: Write the implementation**

TDD note: this hook's own test is Step 3; the *behavioural* test for it already exists as `TimelineDock.test.tsx` + `.snap.` + `.trackstretch.`, which drive it through `SegmentBar`. Write the hook, refactor onto it, and treat those suites as the failing-then-passing gate.

Create `web/src/components/video-editor/useBarDrag.ts`:

```ts
"use client";

import { useRef, useState } from "react";
import type { PointerEvent as ReactPointerEvent, RefObject } from "react";
import { SNAP_TOLERANCE_PX, type SnapGuide } from "@/lib/video-editor/snap";
import { resolveBarDrag, type BarDragKind } from "./barDragMath";

type DragState = {
  kind: BarDragKind;
  startX: number;
  startMs: number;
  endMs: number;
};

/** One bar's drag gesture: pointer capture, a local draft span for the live
 *  visual, and EXACTLY ONE commit on pointerup.
 *
 *  Shared by the block bars (`SegmentBar`) and the per-property lane bars
 *  (`PropSegmentBar`). Everything view-shaped — label, handles, tooltip,
 *  menu — stays in the components; this owns only the gesture.
 *
 *  One commit per gesture (not per move) is load-bearing: it is what makes a
 *  drag ONE undo step rather than a burst of them. */
export function useBarDrag({
  startMs,
  endMs,
  durationMs,
  wallMin,
  wallMax,
  laneRef,
  snapGuides,
  locked,
  onShift,
  onStretch,
}: {
  startMs: number;
  endMs: number;
  durationMs: number;
  wallMin: number;
  wallMax: number;
  laneRef: RefObject<HTMLDivElement | null>;
  snapGuides: readonly SnapGuide[];
  locked: boolean;
  onShift: (fromStartMs: number, fromEndMs: number, deltaMs: number) => void;
  onStretch: (
    fromStartMs: number,
    fromEndMs: number,
    newStartMs: number,
    newEndMs: number
  ) => void;
}) {
  const drag = useRef<DragState | null>(null);
  const [draft, setDraft] = useState<{ startMs: number; endMs: number } | null>(
    null
  );
  // The guide the live drag is latched onto, or null. Purely visual — the
  // snapped VALUE already lives in `draft`.
  const [snapHit, setSnapHit] = useState<number | null>(null);

  function beginDrag(kind: BarDragKind) {
    return (e: ReactPointerEvent<HTMLDivElement>) => {
      if (locked) return;
      e.stopPropagation();
      e.currentTarget.setPointerCapture(e.pointerId);
      drag.current = { kind, startX: e.clientX, startMs, endMs };
      setDraft({ startMs, endMs });
    };
  }

  function handleMove(e: ReactPointerEvent<HTMLDivElement>) {
    const d = drag.current;
    if (!d || !laneRef.current) return;
    const rect = laneRef.current.getBoundingClientRect();
    const deltaMs =
      rect.width > 0 ? ((e.clientX - d.startX) / rect.width) * durationMs : 0;

    // Alt bypasses snapping, read live off each move event so it can be
    // pressed and released mid-drag. Tolerance converts from pixels through
    // the lane's own measured width, so it feels the same at every zoom.
    const toleranceMs =
      e.altKey || rect.width <= 0
        ? 0
        : (SNAP_TOLERANCE_PX / rect.width) * durationMs;

    const next = resolveBarDrag({
      kind: d.kind,
      startMs: d.startMs,
      endMs: d.endMs,
      deltaMs,
      wallMin,
      wallMax,
      guides: snapGuides,
      toleranceMs,
    });

    setDraft({ startMs: next.startMs, endMs: next.endMs });
    setSnapHit(next.hitMs);
  }

  function handleUp() {
    const d = drag.current;
    drag.current = null;
    const finalDraft = draft;
    setDraft(null);
    setSnapHit(null);
    if (!d || !finalDraft) return;

    if (d.kind === "body") {
      const deltaMs = finalDraft.startMs - d.startMs;
      if (deltaMs !== 0) onShift(d.startMs, d.endMs, deltaMs);
    } else if (
      finalDraft.startMs !== d.startMs ||
      finalDraft.endMs !== d.endMs
    ) {
      onStretch(d.startMs, d.endMs, finalDraft.startMs, finalDraft.endMs);
    }
  }

  return { draft, snapHit, beginDrag, handleMove, handleUp };
}
```

- [ ] **Step 2: Refactor `SegmentBar` onto the hook**

In `BlockTrackRow.tsx`, inside `SegmentBar`:

1. Delete the `drag` ref, the `draft` and `snapHit` state, and the `beginDrag`, `handleMove`, `handleUp` functions (currently around lines 282–430).
2. Keep `wallMin` / `wallMax` exactly as they are.
3. Insert, after `wallMax` is computed:

```tsx
  const { draft, snapHit, beginDrag, handleMove, handleUp } = useBarDrag({
    startMs: segment.startMs,
    endMs: segment.endMs,
    durationMs,
    wallMin,
    wallMax,
    laneRef,
    snapGuides,
    locked,
    onShift: (fromStart, fromEnd, deltaMs) =>
      onShiftSegment(trackId, fromStart, fromEnd, deltaMs),
    onStretch: (fromStart, fromEnd, newStart, newEnd) =>
      onStretchSegment(trackId, fromStart, fromEnd, newStart, newEnd),
  });
```

4. Add the import: `import { useBarDrag } from "./useBarDrag";`
5. Leave every JSX usage of `draft`, `snapHit`, `beginDrag`, `handleMove`, `handleUp` untouched — the names are identical on purpose, so the render body needs no edits.
6. Remove the now-unused local `DragState` type and `DragKind` import if nothing else in the file uses them (`grep -n "DragState\|DragKind" BlockTrackRow.tsx`).

- [ ] **Step 3: Write the hook's own test**

Create `web/src/components/video-editor/useBarDrag.test.tsx`:

```tsx
/** The gesture contract: one commit per drag, a live draft while moving, and
 *  nothing committed when the bar lands where it started. Driven through a
 *  tiny harness because the hook needs a real lane element to measure. */
import { describe, expect, it, mock } from "bun:test";
import { useRef } from "react";
import { fireEvent, render, within } from "@testing-library/react";
import { useBarDrag } from "./useBarDrag";

const body = () => within(document.body);

function Harness({
  onShift,
  onStretch,
}: {
  onShift: (a: number, b: number, c: number) => void;
  onStretch: (a: number, b: number, c: number, d: number) => void;
}) {
  const laneRef = useRef<HTMLDivElement>(null);
  const drag = useBarDrag({
    startMs: 1000,
    endMs: 1500,
    durationMs: 5000,
    wallMin: 0,
    wallMax: 5000,
    laneRef,
    snapGuides: [],
    locked: false,
    onShift,
    onStretch,
  });

  return (
    <div ref={laneRef} data-testid="lane">
      <div
        data-testid="bar"
        onPointerDown={drag.beginDrag("body")}
        onPointerMove={drag.handleMove}
        onPointerUp={drag.handleUp}
      >
        {drag.draft ? `${drag.draft.startMs}-${drag.draft.endMs}` : "idle"}
      </div>
    </div>
  );
}

/** jsdom reports 0×0 for everything, so the lane's width — which the hook
 *  divides by to turn pixels into ms — has to be stubbed. 500px over a 5000ms
 *  timeline means 1px = 10ms. */
function stubLaneWidth() {
  const lane = body().getByTestId("lane");
  lane.getBoundingClientRect = () =>
    ({ width: 500, height: 20, top: 0, left: 0, right: 500, bottom: 20, x: 0, y: 0, toJSON: () => ({}) }) as DOMRect;
}

describe("useBarDrag", () => {
  it("commits one shift per gesture and shows a draft while dragging", () => {
    const onShift = mock(() => {});
    const onStretch = mock(() => {});
    render(<Harness onShift={onShift} onStretch={onStretch} />);
    stubLaneWidth();

    const bar = body().getByTestId("bar");
    bar.setPointerCapture = () => {};

    fireEvent.pointerDown(bar, { clientX: 100, pointerId: 1 });
    fireEvent.pointerMove(bar, { clientX: 120, pointerId: 1 });
    expect(bar).toHaveTextContent("1200-1700");
    fireEvent.pointerMove(bar, { clientX: 130, pointerId: 1 });
    fireEvent.pointerUp(bar, { pointerId: 1 });

    expect(onShift).toHaveBeenCalledTimes(1);
    expect(onShift).toHaveBeenCalledWith(1000, 1500, 300);
    expect(onStretch).not.toHaveBeenCalled();
    expect(bar).toHaveTextContent("idle");
  });

  it("commits nothing when the bar ends where it started", () => {
    const onShift = mock(() => {});
    const onStretch = mock(() => {});
    render(<Harness onShift={onShift} onStretch={onStretch} />);
    stubLaneWidth();

    const bar = body().getByTestId("bar");
    bar.setPointerCapture = () => {};

    fireEvent.pointerDown(bar, { clientX: 100, pointerId: 1 });
    fireEvent.pointerMove(bar, { clientX: 100, pointerId: 1 });
    fireEvent.pointerUp(bar, { pointerId: 1 });

    expect(onShift).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 4: Run the hook test and the whole regression net**

Run: `bun test ./src/components/video-editor ./src/components/studio/kv-generator/motion`
Expected: PASS, everything green. The baseline before this task is 353 passing tests across 31 files; this task adds 2. If `TimelineDock.test.tsx`, `TimelineDock.snap.test.tsx` or `TimelineDock.trackstretch.test.tsx` go red, the extraction changed behaviour — fix the hook, do not touch those files.

- [ ] **Step 5: Lint and typecheck**

Run: `bunx eslint src/components/video-editor/useBarDrag.ts src/components/video-editor/useBarDrag.test.tsx src/components/video-editor/BlockTrackRow.tsx`
Run: `bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -E "useBarDrag|BlockTrackRow|barDragMath"`
Expected: no errors naming these files (jest-dom matcher errors in `.test.tsx` files are the project-wide baseline and are fine).

- [ ] **Step 6: Commit**

```bash
git add src/components/video-editor/useBarDrag.ts src/components/video-editor/useBarDrag.test.tsx src/components/video-editor/BlockTrackRow.tsx
git commit -m "refactor(video-editor): move SegmentBar's drag gesture into a shared hook"
```

---

### Task 3: `shiftPropGroupKeyframes`

**Files:**
- Modify: `web/src/lib/video-editor/blocks.ts`
- Test: `web/src/lib/video-editor/blocks.propGroupDrag.test.ts`

**Interfaces:**
- Consumes: `PROP_LABEL_GROUPS`, `PropGroupKey`, `propGroupSegments`, `findOverlayTrack`, `clampNum` (all already in `blocks.ts`)
- Produces:
  ```ts
  export function shiftPropGroupKeyframes(
    timeline: MotionTimeline,
    overlayId: string,
    group: PropGroupKey,
    segStartMs: number,
    segEndMs: number,
    deltaMs: number,
  ): MotionTimeline;
  ```

- [ ] **Step 1: Write the failing test**

Create `web/src/lib/video-editor/blocks.propGroupDrag.test.ts`:

```ts
/** Dragging ONE property group's lane bar. The interesting case is a keyframe
 *  carrying several props: the dragged group has to leave, the rest has to
 *  stay exactly where it was. */
import { describe, expect, it } from "bun:test";
import { DEFAULT_TIMELINE, type MotionTimeline } from "./timeline";
import { shiftPropGroupKeyframes } from "./blocks";

/** One keyframe at 500 carrying scale AND opacity, one at 1000 carrying only
 *  scale. The scale lane therefore spans [500, 1000]. */
const mixed = (): MotionTimeline => ({
  ...DEFAULT_TIMELINE(),
  tracks: [
    {
      kind: "overlay",
      overlay_id: "ov1",
      keyframes: [
        {
          t_ms: 500,
          props: { scale: 0.6, opacity: 0 },
          easing: "linear",
          label: "Pop in",
        },
        { t_ms: 1000, props: { scale: 1 }, easing: "out", label: "Pop in" },
      ],
    },
  ],
});

const kfs = (tl: MotionTimeline) =>
  [...tl.tracks[0].keyframes].sort((a, b) => a.t_ms - b.t_ms);

describe("shiftPropGroupKeyframes", () => {
  it("splits a mixed keyframe, leaving the other props behind", () => {
    const out = shiftPropGroupKeyframes(mixed(), "ov1", "scale", 500, 1000, 200);

    expect(kfs(out)).toEqual([
      { t_ms: 500, props: { opacity: 0 }, easing: "linear" },
      { t_ms: 700, props: { scale: 0.6 }, easing: "linear" },
      { t_ms: 1200, props: { scale: 1 }, easing: "out" },
    ]);
  });

  it("gives both halves of a split the original easing", () => {
    const out = shiftPropGroupKeyframes(mixed(), "ov1", "scale", 500, 1000, 200);
    const left = kfs(out).find((k) => k.t_ms === 500);
    const right = kfs(out).find((k) => k.t_ms === 700);

    // easing means "curve INTO this keyframe", so duplicating it preserves
    // each property's own incoming curve — nothing is lost by the split.
    expect(left?.easing).toBe("linear");
    expect(right?.easing).toBe("linear");
  });

  it("clears the preset label on every keyframe it touches", () => {
    const out = shiftPropGroupKeyframes(mixed(), "ov1", "scale", 500, 1000, 200);

    expect(kfs(out).every((k) => k.label === undefined)).toBe(true);
  });

  it("drops a keyframe left empty by the extraction", () => {
    const only: MotionTimeline = {
      ...DEFAULT_TIMELINE(),
      tracks: [
        {
          kind: "overlay",
          overlay_id: "ov1",
          keyframes: [
            { t_ms: 500, props: { scale: 0.6 }, easing: "linear" },
            { t_ms: 1000, props: { scale: 1 }, easing: "out" },
          ],
        },
      ],
    };

    const out = shiftPropGroupKeyframes(only, "ov1", "scale", 500, 1000, 200);

    expect(kfs(out).map((k) => k.t_ms)).toEqual([700, 1200]);
  });

  it("moves x and y together for the position group", () => {
    const tl: MotionTimeline = {
      ...DEFAULT_TIMELINE(),
      tracks: [
        {
          kind: "overlay",
          overlay_id: "ov1",
          keyframes: [
            { t_ms: 0, props: { x: 0.1, y: 0.2, opacity: 0 }, easing: "linear" },
            { t_ms: 500, props: { x: 0.3, y: 0.4 }, easing: "out" },
          ],
        },
      ],
    };

    const out = shiftPropGroupKeyframes(tl, "ov1", "position", 0, 500, 100);

    expect(kfs(out)).toEqual([
      { t_ms: 0, props: { opacity: 0 }, easing: "linear" },
      { t_ms: 100, props: { x: 0.1, y: 0.2 }, easing: "linear" },
      { t_ms: 600, props: { x: 0.3, y: 0.4 }, easing: "out" },
    ]);
  });

  it("never lands on an occupied time — it steps 1ms past instead", () => {
    // opacity already owns 700. Merging scale into it would force the two
    // props to share one easing and silently change one of their curves.
    const tl: MotionTimeline = {
      ...DEFAULT_TIMELINE(),
      tracks: [
        {
          kind: "overlay",
          overlay_id: "ov1",
          keyframes: [
            { t_ms: 500, props: { scale: 0.6 }, easing: "linear" },
            { t_ms: 700, props: { opacity: 1 }, easing: "in-out" },
            { t_ms: 1000, props: { scale: 1 }, easing: "out" },
          ],
        },
      ],
    };

    const out = shiftPropGroupKeyframes(tl, "ov1", "scale", 500, 1000, 200);
    const scaleTimes = kfs(out)
      .filter((k) => k.props.scale !== undefined)
      .map((k) => k.t_ms);

    expect(scaleTimes).toEqual([701, 1200]);
    expect(kfs(out).find((k) => k.t_ms === 700)?.props).toEqual({ opacity: 1 });
  });

  it("clamps against the timeline walls", () => {
    const out = shiftPropGroupKeyframes(mixed(), "ov1", "scale", 500, 1000, 9000);
    const scaleTimes = kfs(out)
      .filter((k) => k.props.scale !== undefined)
      .map((k) => k.t_ms);

    expect(Math.max(...scaleTimes)).toBe(5000);
  });

  it("is a no-op when the segment does not match a lane segment", () => {
    const tl = mixed();
    const out = shiftPropGroupKeyframes(tl, "ov1", "scale", 400, 900, 200);

    expect(out).toBe(tl);
  });

  it("is a no-op for an unknown overlay", () => {
    const tl = mixed();

    expect(shiftPropGroupKeyframes(tl, "nope", "scale", 500, 1000, 200)).toBe(tl);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bun test ./src/lib/video-editor/blocks.propGroupDrag.test.ts`
Expected: FAIL — `shiftPropGroupKeyframes` is not exported from `blocks.ts`.

- [ ] **Step 3: Write the implementation**

Append to `web/src/lib/video-editor/blocks.ts`:

```ts
/** Move ONE property group's keyframes within a lane segment, leaving every
 *  other property exactly where it was.
 *
 *  A lane drag is a SPLIT, not a retime: a keyframe at 500ms carrying
 *  `{ scale, opacity }` cannot follow the scale lane without abandoning
 *  opacity. So the group's values are extracted into a keyframe of their own
 *  at the target time, and whatever else the original carried stays behind.
 *
 *  Three rules the tests pin down:
 *  - `easing` is DUPLICATED onto both halves. It means "curve into this
 *    keyframe", so each property keeps its own real incoming curve; nothing
 *    about the animation changes except the timing that was dragged.
 *  - Every keyframe this touches loses its `label`. The block is no longer
 *    the preset that wrote it, and `segmentLabel` reads the earliest
 *    keyframe — which a lane bar, spanning its whole segment, always touches.
 *  - A moved keyframe NEVER lands on a time that another keyframe still
 *    occupies; it steps 1ms past instead. Merging would force two properties
 *    to share one `easing` and silently rewrite one of their curves. The 1ms
 *    deformation is imperceptible; a changed curve is not. */
export function shiftPropGroupKeyframes(
  timeline: MotionTimeline,
  overlayId: string,
  group: PropGroupKey,
  segStartMs: number,
  segEndMs: number,
  deltaMs: number,
): MotionTimeline {
  return movePropGroup(timeline, overlayId, group, segStartMs, segEndMs, (t) =>
    t + deltaMs,
  );
}

/** Shared core behind `shiftPropGroupKeyframes` and (Task 4)
 *  `stretchPropGroupKeyframes`: `retime` maps each in-range keyframe's time
 *  onto its target, everything else is the split, the clamps and the label
 *  rule described above. */
function movePropGroup(
  timeline: MotionTimeline,
  overlayId: string,
  group: PropGroupKey,
  segStartMs: number,
  segEndMs: number,
  retime: (tMs: number) => number,
): MotionTimeline {
  const track = findOverlayTrack(timeline, overlayId);
  if (!track) return timeline;

  const keys = PROP_LABEL_GROUPS.find((g) => g.label === group)?.keys;
  if (!keys) return timeline;

  const laneSegments = propGroupSegments(track, group);
  const index = laneSegments.findIndex(
    (s) => s.startMs === segStartMs && s.endMs === segEndMs,
  );
  if (index === -1) return timeline;

  const prev = laneSegments[index - 1];
  const next = laneSegments[index + 1];
  const wallMin = prev ? prev.endMs + 1 : 0;
  const wallMax = next ? next.startMs - 1 : timeline.duration_ms;

  const kept: MotionKeyframe[] = [];
  const moving: MotionKeyframe[] = [];

  for (const kf of track.keyframes) {
    const inRange = kf.t_ms >= segStartMs && kf.t_ms <= segEndMs;
    const groupProps: Partial<MotionProps> = {};
    if (inRange) {
      for (const key of keys) {
        if (kf.props[key] !== undefined) groupProps[key] = kf.props[key];
      }
    }
    if (Object.keys(groupProps).length === 0) {
      kept.push({ ...kf, props: { ...kf.props } });
      continue;
    }

    const rest: Partial<MotionProps> = { ...kf.props };
    for (const key of keys) delete rest[key];
    // Touched: the leftover half loses the preset name too, or the block
    // would keep claiming to be a preset it no longer is.
    if (Object.keys(rest).length > 0) {
      kept.push({ t_ms: kf.t_ms, props: rest, easing: kf.easing });
    }
    moving.push({
      t_ms: clampNum(Math.round(retime(kf.t_ms)), wallMin, wallMax),
      props: groupProps,
      easing: kf.easing,
    });
  }

  const occupied = new Set(kept.map((k) => k.t_ms));
  const placed: MotionKeyframe[] = moving.map((kf) => {
    let t = kf.t_ms;
    while (occupied.has(t) && t < wallMax) t += 1;
    while (occupied.has(t) && t > wallMin) t -= 1;
    occupied.add(t);
    return { ...kf, t_ms: t };
  });

  const keyframes = [...kept, ...placed].sort((a, b) => a.t_ms - b.t_ms);
  return {
    ...timeline,
    tracks: timeline.tracks.map((t) =>
      t.kind === "overlay" && t.overlay_id === overlayId ? { ...t, keyframes } : t,
    ),
  };
}
```

Add `MotionKeyframe` and `MotionProps` to the existing type import at the top of `blocks.ts` if they are not already there (they are — check line 1-6 before editing).

- [ ] **Step 4: Run the test to verify it passes**

Run: `bun test ./src/lib/video-editor/blocks.propGroupDrag.test.ts`
Expected: PASS, 9 tests.

- [ ] **Step 5: Run the existing blocks suite for regressions**

Run: `bun test ./src/lib/video-editor`
Expected: PASS — nothing else in this module changed, so any red here means the new code broke a shared helper.

- [ ] **Step 6: Commit**

```bash
git add src/lib/video-editor/blocks.ts src/lib/video-editor/blocks.propGroupDrag.test.ts
git commit -m "feat(video-editor): shift one property group's keyframes within a lane"
```

---

### Task 4: `stretchPropGroupKeyframes`

**Files:**
- Modify: `web/src/lib/video-editor/blocks.ts`
- Test: `web/src/lib/video-editor/blocks.propGroupDrag.test.ts` (append a describe block)

**Interfaces:**
- Consumes: `movePropGroup` from Task 3, `MIN_BLOCK_SPAN_MS`
- Produces:
  ```ts
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

- [ ] **Step 1: Write the failing test**

Append to `web/src/lib/video-editor/blocks.propGroupDrag.test.ts`:

```ts
describe("stretchPropGroupKeyframes", () => {
  it("rescales the group's keyframes onto the new span", () => {
    const tl: MotionTimeline = {
      ...DEFAULT_TIMELINE(),
      tracks: [
        {
          kind: "overlay",
          overlay_id: "ov1",
          keyframes: [
            { t_ms: 0, props: { scale: 0.6 }, easing: "linear" },
            { t_ms: 250, props: { scale: 1.2 }, easing: "out" },
            { t_ms: 500, props: { scale: 1 }, easing: "out" },
          ],
        },
      ],
    };

    const out = stretchPropGroupKeyframes(tl, "ov1", "scale", 0, 500, 0, 1000);

    expect(kfs(out).map((k) => k.t_ms)).toEqual([0, 500, 1000]);
  });

  it("leaves other properties alone while the group is rescaled", () => {
    const tl: MotionTimeline = {
      ...DEFAULT_TIMELINE(),
      tracks: [
        {
          kind: "overlay",
          overlay_id: "ov1",
          keyframes: [
            { t_ms: 0, props: { scale: 0.6, opacity: 0 }, easing: "linear" },
            { t_ms: 500, props: { scale: 1, opacity: 1 }, easing: "out" },
          ],
        },
      ],
    };

    const out = stretchPropGroupKeyframes(tl, "ov1", "scale", 0, 500, 0, 1000);
    const opacityTimes = kfs(out)
      .filter((k) => k.props.opacity !== undefined)
      .map((k) => k.t_ms);

    expect(opacityTimes).toEqual([0, 500]);
  });

  it("floors the span at MIN_BLOCK_SPAN_MS", () => {
    const tl: MotionTimeline = {
      ...DEFAULT_TIMELINE(),
      tracks: [
        {
          kind: "overlay",
          overlay_id: "ov1",
          keyframes: [
            { t_ms: 0, props: { scale: 0.6 }, easing: "linear" },
            { t_ms: 500, props: { scale: 1 }, easing: "out" },
          ],
        },
      ],
    };

    const out = stretchPropGroupKeyframes(tl, "ov1", "scale", 0, 500, 0, 10);
    const times = kfs(out).map((k) => k.t_ms);

    expect(times[times.length - 1] - times[0]).toBe(MIN_BLOCK_SPAN_MS);
  });

  it("is a no-op when the segment does not match", () => {
    const tl = mixed();

    expect(stretchPropGroupKeyframes(tl, "ov1", "scale", 0, 400, 0, 900)).toBe(tl);
  });
});
```

Extend the file's imports to `import { MIN_BLOCK_SPAN_MS, shiftPropGroupKeyframes, stretchPropGroupKeyframes } from "./blocks";`

- [ ] **Step 2: Run the test to verify it fails**

Run: `bun test ./src/lib/video-editor/blocks.propGroupDrag.test.ts`
Expected: FAIL — `stretchPropGroupKeyframes` is not exported.

- [ ] **Step 3: Write the implementation**

Append to `web/src/lib/video-editor/blocks.ts`:

```ts
/** Resize ONE property group's lane bar: linearly rescale that group's
 *  keyframes from `[segStartMs, segEndMs]` onto `[newStartMs, newEndMs]`,
 *  splitting mixed keyframes exactly as `shiftPropGroupKeyframes` does.
 *
 *  A single-point lane segment has no ratio to rescale against, so it shifts
 *  to the requested start instead — mirroring `stretchKeyframesInRange`'s own
 *  fallback for the same degenerate case. */
export function stretchPropGroupKeyframes(
  timeline: MotionTimeline,
  overlayId: string,
  group: PropGroupKey,
  segStartMs: number,
  segEndMs: number,
  newStartMs: number,
  newEndMs: number,
): MotionTimeline {
  const oldSpan = segEndMs - segStartMs;
  if (oldSpan === 0) {
    return movePropGroup(timeline, overlayId, group, segStartMs, segEndMs, () =>
      newStartMs,
    );
  }

  let start = newStartMs;
  let end = newEndMs;
  if (end - start < MIN_BLOCK_SPAN_MS) end = start + MIN_BLOCK_SPAN_MS;
  const newSpan = end - start;

  return movePropGroup(
    timeline,
    overlayId,
    group,
    segStartMs,
    segEndMs,
    (t) => start + ((t - segStartMs) / oldSpan) * newSpan,
  );
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bun test ./src/lib/video-editor/blocks.propGroupDrag.test.ts`
Expected: PASS, 13 tests.

- [ ] **Step 5: Commit**

```bash
git add src/lib/video-editor/blocks.ts src/lib/video-editor/blocks.propGroupDrag.test.ts
git commit -m "feat(video-editor): stretch one property group's keyframes within a lane"
```

---

### Task 5: `PropSegmentBar` and the lane UI

**Files:**
- Create: `web/src/components/video-editor/PropSegmentBar.tsx`
- Modify: `web/src/components/video-editor/types.ts` (two optional props on `TimelineDockProps`)
- Modify: `web/src/components/video-editor/TimelineDock.tsx` (forward them)
- Modify: `web/src/components/video-editor/BlockTrackRow.tsx` (`BlockTrackRowProps` + `PropSubRow`)
- Test: `web/src/components/video-editor/TimelineDock.proplanes.test.tsx`

**Interfaces:**
- Consumes: `useBarDrag` (Task 2), `PropGroupKey` from `@/lib/video-editor/blocks`
- Produces (identical names in all three files):
  ```ts
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

- [ ] **Step 1: Write the failing test**

Create `web/src/components/video-editor/TimelineDock.proplanes.test.tsx`:

```tsx
/** Per-property lanes, once expanded, are draggable: the bar commits through
 *  onShiftPropGroup / onStretchPropGroup rather than the block-level
 *  callbacks. `screen` is broken under bun here — use within(document.body). */
import { describe, expect, it, mock } from "bun:test";
import { fireEvent, render, within } from "@testing-library/react";
import { DEFAULT_TIMELINE } from "@/lib/video-editor/timeline";
import { TimelineDock } from "./TimelineDock";

const body = () => within(document.body);

const TRACKS = [{ id: "ov1", name: "Headline", icon: "text" as const }];

/** scale and opacity on the same two keyframes, so both lanes exist and the
 *  scale lane's bar covers keyframes that also carry opacity. */
const tl = () => ({
  ...DEFAULT_TIMELINE(),
  tracks: [
    {
      kind: "overlay" as const,
      overlay_id: "ov1",
      keyframes: [
        { t_ms: 0, props: { scale: 0.6, opacity: 0 }, easing: "linear" as const },
        { t_ms: 500, props: { scale: 1, opacity: 1 }, easing: "out" as const },
      ],
    },
  ],
});

function baseHandlers() {
  return {
    onSeek: mock(), onTogglePlay: mock(), onSelectKeyframe: mock(),
    onMoveKeyframe: mock(), onDeleteKeyframe: mock(), onInsertKeyframe: mock(),
    onDurationChange: mock(), onToggleLoop: mock(), onViewChange: mock(),
    onShiftSegment: mock(), onStretchSegment: mock(), onStretchTrack: mock(),
    onSelectTrack: mock(), onPreviewRangeChange: mock(), onDeleteSegment: mock(),
    onReplaceSegment: mock(), onApplySlotPreset: mock(),
    onToggleTrackLocked: mock(), onToggleTrackHidden: mock(), onZoomChange: mock(),
    onShiftPropGroup: mock(), onStretchPropGroup: mock(),
  };
}

function renderDock(overrides: Record<string, unknown> = {}) {
  const handlers = baseHandlers();
  render(
    <TimelineDock
      tracks={TRACKS}
      timeline={tl()}
      playheadMs={0}
      playing={false}
      selectedKeyframe={null}
      loop={false}
      view="slots"
      previewRange={null}
      {...handlers}
      {...overrides}
    />
  );
  fireEvent.click(body().getByTestId("track-expand-ov1"));
  return handlers;
}

describe("per-property lanes", () => {
  it("renders a draggable bar per lane once the row is expanded", () => {
    renderDock();

    expect(body().getByTestId("prop-bar-ov1-scale-0")).toBeInTheDocument();
    expect(body().getByTestId("prop-bar-ov1-opacity-0")).toBeInTheDocument();
  });

  it("commits a lane drag through onShiftPropGroup, not the block callbacks", () => {
    const h = renderDock();

    const bar = body().getByTestId("prop-bar-ov1-scale-0");
    bar.setPointerCapture = () => {};
    const lane = body().getByTestId("prop-lane-ov1-scale");
    lane.getBoundingClientRect = () =>
      ({ width: 500, height: 20, top: 0, left: 0, right: 500, bottom: 20, x: 0, y: 0, toJSON: () => ({}) }) as DOMRect;

    fireEvent.pointerDown(bar, { clientX: 0, pointerId: 1 });
    fireEvent.pointerMove(bar, { clientX: 20, pointerId: 1 });
    fireEvent.pointerUp(bar, { pointerId: 1 });

    expect(h.onShiftPropGroup).toHaveBeenCalledTimes(1);
    expect(h.onShiftPropGroup).toHaveBeenCalledWith("ov1", "scale", 0, 500, 200);
    expect(h.onShiftSegment).not.toHaveBeenCalled();
  });

  it("stays read-only when the host provides no lane callbacks", () => {
    renderDock({ onShiftPropGroup: undefined, onStretchPropGroup: undefined });

    const bar = body().getByTestId("prop-bar-ov1-scale-0");
    expect(bar).toHaveAttribute("aria-disabled", "true");
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bun test ./src/components/video-editor/TimelineDock.proplanes.test.tsx`
Expected: FAIL — `prop-bar-ov1-scale-0` not found (today's lanes render non-interactive bars with different testids).

- [ ] **Step 3: Create `PropSegmentBar`**

Create `web/src/components/video-editor/PropSegmentBar.tsx`:

```tsx
"use client";

import type { RefObject } from "react";
import type { PropGroupKey, TrackSegment } from "@/lib/video-editor/blocks";
import type { SnapGuide } from "@/lib/video-editor/snap";
import { cn } from "@/lib/utils";
import { useBarDrag } from "./useBarDrag";

/** One property group's bar inside an expanded row's sub-lane.
 *
 *  Deliberately thinner than `SegmentBar`: no label, no tooltip, no context
 *  menu, no still-point diamond. A sub-lane is a detail view of a block that
 *  is already on screen above it — repeating that block's chrome four times
 *  would bury the timing information the lane exists to show.
 *
 *  Read-only when the host passes no callbacks (`onShift`/`onStretch`
 *  undefined), which is how a dock with no lane wiring keeps today's
 *  behaviour. */
export function PropSegmentBar({
  trackId,
  group,
  index,
  segment,
  prevSegment,
  nextSegment,
  durationMs,
  laneRef,
  snapGuides,
  locked,
  onShift,
  onStretch,
  onSelectTrack,
}: {
  trackId: string;
  group: PropGroupKey;
  index: number;
  segment: TrackSegment;
  prevSegment: TrackSegment | null;
  nextSegment: TrackSegment | null;
  durationMs: number;
  laneRef: RefObject<HTMLDivElement | null>;
  snapGuides: readonly SnapGuide[];
  locked: boolean;
  onShift?: (deltaMs: number) => void;
  onStretch?: (newStartMs: number, newEndMs: number) => void;
  onSelectTrack: () => void;
}) {
  const interactive = !locked && Boolean(onShift && onStretch);
  const wallMin = prevSegment ? prevSegment.endMs + 1 : 0;
  const wallMax = nextSegment ? nextSegment.startMs - 1 : durationMs;

  const drag = useBarDrag({
    startMs: segment.startMs,
    endMs: segment.endMs,
    durationMs,
    wallMin,
    wallMax,
    laneRef,
    snapGuides,
    locked: !interactive,
    onShift: (_s, _e, deltaMs) => onShift?.(deltaMs),
    onStretch: (_s, _e, newStart, newEnd) => onStretch?.(newStart, newEnd),
  });

  const start = drag.draft?.startMs ?? segment.startMs;
  const end = drag.draft?.endMs ?? segment.endMs;
  const leftPct = durationMs > 0 ? (start / durationMs) * 100 : 0;
  const widthPct = durationMs > 0 ? ((end - start) / durationMs) * 100 : 0;

  return (
    <div
      data-testid={`prop-bar-${trackId}-${group}-${index}`}
      aria-disabled={interactive ? undefined : true}
      style={{ left: `${leftPct}%`, width: `${widthPct}%` }}
      className={cn(
        "absolute top-1/2 flex h-3 min-w-[8px] -translate-y-1/2 items-center rounded-[3px] border border-white/20 bg-white/[0.14]",
        interactive
          ? "cursor-grab active:cursor-grabbing hover:bg-white/20"
          : "cursor-default"
      )}
      onClick={onSelectTrack}
      onPointerDown={drag.beginDrag("body")}
      onPointerMove={drag.handleMove}
      onPointerUp={drag.handleUp}
    >
      {interactive && (
        <>
          <span
            data-testid={`prop-handle-left-${trackId}-${group}-${index}`}
            aria-hidden
            className="absolute -left-0.5 h-full w-1 cursor-ew-resize rounded-l bg-white/40"
            onPointerDown={drag.beginDrag("left")}
            onPointerMove={drag.handleMove}
            onPointerUp={drag.handleUp}
          />
          <span
            data-testid={`prop-handle-right-${trackId}-${group}-${index}`}
            aria-hidden
            className="absolute -right-0.5 h-full w-1 cursor-ew-resize rounded-r bg-white/40"
            onPointerDown={drag.beginDrag("right")}
            onPointerMove={drag.handleMove}
            onPointerUp={drag.handleUp}
          />
        </>
      )}
    </div>
  );
}
```

- [ ] **Step 4: Wire `PropSubRow`**

In `BlockTrackRow.tsx`:

1. Add to `BlockTrackRowProps` (after `onApplySavedMotion`):

```ts
  /** Drag a per-property lane bar. Optional — omit both and the lanes stay
   *  read-only, which is what a host with no lane wiring gets. See
   *  `TimelineDockProps.onShiftPropGroup`. */
  onShiftPropGroup?: (
    trackId: string,
    group: PropGroupKey,
    segStartMs: number,
    segEndMs: number,
    deltaMs: number,
  ) => void;
  onStretchPropGroup?: (
    trackId: string,
    group: PropGroupKey,
    segStartMs: number,
    segEndMs: number,
    newStartMs: number,
    newEndMs: number,
  ) => void;
```

2. Destructure both in `BlockTrackRow`.
3. Give `PropSubRow` its own lane ref and the new props, replacing its read-only bar markup with `PropSegmentBar`:

```tsx
function PropSubRow({
  trackId, group, segments, durationMs, dimmed,
  snapGuides, locked, onShiftPropGroup, onStretchPropGroup, onSelectTrack,
}: {
  trackId: string;
  group: PropGroupKey;
  segments: TrackSegment[];
  durationMs: number;
  dimmed: boolean;
  snapGuides: readonly SnapGuide[];
  locked: boolean;
  onShiftPropGroup?: BlockTrackRowProps["onShiftPropGroup"];
  onStretchPropGroup?: BlockTrackRowProps["onStretchPropGroup"];
  onSelectTrack: (trackId: string) => void;
}) {
  const laneRef = useRef<HTMLDivElement>(null);
  // ... existing rail cell unchanged ...
  <div
    ref={laneRef}
    data-testid={`prop-lane-${trackId}-${group}`}
    style={{ width: `var(${LANE_WIDTH_VAR})` }}
    className={cn("relative shrink-0 px-1", dimmed && "opacity-50")}
  >
    {segments.map((segment, index) => (
      <PropSegmentBar
        key={`${segment.startMs}-${segment.endMs}`}
        trackId={trackId}
        group={group}
        index={index}
        segment={segment}
        prevSegment={segments[index - 1] ?? null}
        nextSegment={segments[index + 1] ?? null}
        durationMs={durationMs}
        laneRef={laneRef}
        snapGuides={snapGuides}
        locked={locked}
        onShift={
          onShiftPropGroup &&
          ((deltaMs) =>
            onShiftPropGroup(trackId, group, segment.startMs, segment.endMs, deltaMs))
        }
        onStretch={
          onStretchPropGroup &&
          ((newStart, newEnd) =>
            onStretchPropGroup(
              trackId, group, segment.startMs, segment.endMs, newStart, newEnd,
            ))
        }
        onSelectTrack={() => onSelectTrack(trackId)}
      />
    ))}
  </div>
```

4. Pass the new props (plus `snapGuides`, `locked`, `onSelectTrack`) where `BlockTrackRow` renders `PropSubRow`.

- [ ] **Step 5: Wire the dock**

In `types.ts`, add to `TimelineDockProps` right after `onApplySavedMotion`, importing `PropGroupKey` from `@/lib/video-editor/blocks` alongside the existing `SlotKind` import:

```ts
  /** Drag a per-property lane bar in an expanded row. Optional: a host that
   *  omits these keeps the lanes read-only, exactly as they were before
   *  2026-08-31. Moving one group's bar SPLITS any keyframe that also carried
   *  other props — see `shiftPropGroupKeyframes`. */
  onShiftPropGroup?: (
    trackId: string,
    group: PropGroupKey,
    segStartMs: number,
    segEndMs: number,
    deltaMs: number,
  ) => void;
  onStretchPropGroup?: (
    trackId: string,
    group: PropGroupKey,
    segStartMs: number,
    segEndMs: number,
    newStartMs: number,
    newEndMs: number,
  ) => void;
```

In `TimelineDock.tsx`, destructure both and forward them to `<BlockTrackRow>`.

- [ ] **Step 6: Run the test to verify it passes**

Run: `bun test ./src/components/video-editor/TimelineDock.proplanes.test.tsx`
Expected: PASS, 3 tests.

- [ ] **Step 7: Run the full dock suite**

Run: `bun test ./src/components/video-editor`
Expected: PASS. `TimelineDock.subrows.test.tsx` covers the read-only lane view — if it goes red, the markup change broke an assertion it makes about the old bars; update **that** file (it is 12.6KB, well under the cliff), never `TimelineDock.test.tsx`.

- [ ] **Step 8: Commit**

```bash
git add src/components/video-editor/PropSegmentBar.tsx src/components/video-editor/BlockTrackRow.tsx src/components/video-editor/TimelineDock.tsx src/components/video-editor/types.ts src/components/video-editor/TimelineDock.proplanes.test.tsx
git commit -m "feat(video-editor): draggable per-property lane bars"
```

---

### Task 6: Editor state and KV wiring

**Files:**
- Modify: `web/src/components/studio/kv-generator/motion/useMotionEditorState.ts`
- Modify: `web/src/components/studio/kv-generator/motion/KvMotionEditor.tsx`
- Test: `web/src/components/studio/kv-generator/motion/useMotionEditorState.propGroup.test.ts`

**Interfaces:**
- Consumes: `shiftPropGroupKeyframes`, `stretchPropGroupKeyframes` (Tasks 3–4); the dock props from Task 5
- Produces: `state.shiftPropGroup`, `state.stretchPropGroup` with the same argument order as the dock callbacks

- [ ] **Step 1: Write the failing test**

Create `web/src/components/studio/kv-generator/motion/useMotionEditorState.propGroup.test.ts`. Model it on the existing `useMotionEditorState.test.ts` (read it first for the harness it uses to build a hook with a base pose map), and assert:

```ts
it("pushes one undo step per lane drag", () => {
  // arrange: a track with { scale, opacity } at 0 and 500
  // act: result.current.shiftPropGroup("ov1", "scale", 0, 500, 200)
  // assert: scale keyframes moved, opacity untouched, and a single undo
  //         returns the timeline to its exact previous value
});

it("does not push when the writer returns the timeline unchanged", () => {
  // act: shiftPropGroup with a segment that matches no lane segment
  // assert: undo depth unchanged
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bun test ./src/components/studio/kv-generator/motion/useMotionEditorState.propGroup.test.ts`
Expected: FAIL — `shiftPropGroup` is not a function.

- [ ] **Step 3: Add the two callbacks**

In `useMotionEditorState.ts`, beside `shiftSegment` / `stretchSegment`:

```ts
  // One undo step per gesture, no label — same rationale as the segment
  // drags above: each fires once on pointerup, so there is no burst of
  // intermediate calls to collapse, and a shared label would wrongly merge
  // two deliberate drags into one undo step.
  const shiftPropGroup = useCallback(
    (
      trackId: string,
      group: PropGroupKey,
      segStartMs: number,
      segEndMs: number,
      deltaMs: number,
    ) => {
      const next = shiftPropGroupKeyframes(
        timeline, trackId, group, segStartMs, segEndMs, deltaMs,
      );
      if (next !== timeline) push(next);
    },
    [timeline, push],
  );

  const stretchPropGroup = useCallback(
    (
      trackId: string,
      group: PropGroupKey,
      segStartMs: number,
      segEndMs: number,
      newStartMs: number,
      newEndMs: number,
    ) => {
      const next = stretchPropGroupKeyframes(
        timeline, trackId, group, segStartMs, segEndMs, newStartMs, newEndMs,
      );
      if (next !== timeline) push(next);
    },
    [timeline, push],
  );
```

Export both from the hook's return object.

- [ ] **Step 4: Wire the editor**

In `KvMotionEditor.tsx`, on `<TimelineDock>`:

```tsx
          onShiftPropGroup={state.shiftPropGroup}
          onStretchPropGroup={state.stretchPropGroup}
```

- [ ] **Step 5: Run the tests**

Run: `bun test ./src/components/video-editor ./src/components/studio/kv-generator/motion`
Expected: PASS, everything green.

- [ ] **Step 6: Lint and typecheck the changed files**

Run: `bunx eslint src/components/studio/kv-generator/motion/useMotionEditorState.ts src/components/studio/kv-generator/motion/KvMotionEditor.tsx src/components/video-editor/PropSegmentBar.tsx`
Run: `bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -E "PropSegmentBar|useMotionEditorState|KvMotionEditor|blocks\.ts"`
Expected: no new errors naming these files. `KvMotionEditor.tsx` has one pre-existing `useAuth()` error — that one is baseline.

- [ ] **Step 7: Manual verification**

Services must be running (`./run-all.sh --status`; web on :3000). Open a motion project, expand a layer with a preset applied (chevron on its row):

1. Drag the **scale** lane bar right → only scale moves; the opacity lane stays put.
2. The block bar above renames itself from e.g. "Pop in" to "scale · opacity".
3. Drag far enough and the block above **splits into two bars** — expected: blocks are derived from where motion actually happens.
4. Drag a lane handle → the bar resizes; playback shows that property easing over the new span.
5. Cmd+Z restores the previous state in ONE undo.
6. Lock the layer → lane bars stop responding.

- [ ] **Step 8: Commit**

```bash
git add src/components/studio/kv-generator/motion/useMotionEditorState.ts src/components/studio/kv-generator/motion/KvMotionEditor.tsx src/components/studio/kv-generator/motion/useMotionEditorState.propGroup.test.ts
git commit -m "feat(kv-motion): wire per-property lane drags into the editor"
```

---

## Self-Review Notes

- **Spec coverage:** mutation layer → Tasks 3–4; `useBarDrag` extraction → Tasks 1–2; `PropSegmentBar` + plumbing → Task 5; state hook + wiring → Task 6; testing table → the test files named in each task; rollout step 1 = Tasks 1–2, step 2 = Tasks 3–6.
- **Deviation from the spec:** the spec described one `useBarDrag` module. The plan splits it into `barDragMath.ts` (pure, unit-tested) plus `useBarDrag.ts` (pointer plumbing), because the snap-and-clamp rules are the part worth testing and they do not need a DOM.
- **Occupied-time rule made concrete:** the spec said "1ms clearance"; the implementation steps that single keyframe 1ms past the collision rather than clamping the whole gesture. The deformation is bounded at 1ms and only happens on an exact collision.
- **Not covered here:** per-channel delete, Blur/Path/Resize, and the Build tab — the last of these has its own spec and gets its own plan after this one lands.
