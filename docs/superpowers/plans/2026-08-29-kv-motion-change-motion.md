# KV Motion — Change Motion In Place Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user right-click an animation block in the KV Motion timeline and swap the preset behind it, keeping the block's tuned start/end, in one undo step.

**Architecture:** A new pure engine function `replaceSegmentPreset` in `presets.ts` clears the block's keyframes, calls the target preset's own writer, rescales the result onto the block's existing span, and upserts it. The slot-lane row's existing right-click menu (today: Delete only) grows a "Change motion" section filtered to the block's slot. The callback threads types.ts → TimelineDock → BlockTrackRow, and `useMotionEditorState` wraps the engine call in a single `push()`.

**Tech Stack:** TypeScript, React 19, Next.js 16, `bun test` (bunfig preloads jest-dom), `@testing-library/react`, Base UI `Popover` via `@/components/frndos/v2`, `@phosphor-icons/react`.

**Spec:** `docs/superpowers/specs/2026-08-29-kv-motion-timeline-upgrades-design.md`

## Global Constraints

- Worktree: `web/.worktrees/kv-motion-timeline-upgrades`, branch `feature/daffa/vc-kv-motion-timeline-upgrades` (already created from `origin/develop`). All paths below are relative to that worktree.
- Run `bun install` in the worktree before any `bun run build` — Turbopack rejects a `node_modules` symlink to the parent checkout. Tests do not need it if `node_modules` is already present; if `bun test` fails to resolve imports, run `bun install`.
- Tests run with **`bun test`**, never `bunx vitest`.
- There is **no type gate**: `next build` sets `ignoreBuildErrors` and `tsc` has a large pre-existing error baseline. Do not run a bare `tsc` and treat its output as a regression signal.
- `src/lib/video-editor/` must not import from `components/studio/kv-generator` or `lib/studio/kv` — `importBoundary.test.ts` fails the build if it does.
- `MotionTimeline` is a **persisted** document. This plan adds no field and bumps no `version`.
- Preset display names come from `PRESET_LABELS` in `presets.ts`. Never write a second local copy of that map.
- Every mutation goes through `useMotionEditorState`'s `push()` exactly once, so it is exactly one undo step.

## File Structure

| File | Responsibility |
|---|---|
| `src/lib/video-editor/presets.ts` (modify) | Add `replaceSegmentPreset` + private `upsertKeyframes`, `rescaleKeyframes` helpers |
| `src/lib/video-editor/presets.replaceSegment.test.ts` (create) | Engine tests for the new function, kept out of the already-841-line `presets.test.ts` |
| `src/components/video-editor/types.ts` (modify) | `onReplaceSegment` on `TimelineDockProps` |
| `src/components/video-editor/TimelineDock.tsx` (modify) | Thread `onReplaceSegment` to `BlockTrackRow` |
| `src/components/video-editor/BlockTrackRow.tsx` (modify) | `slotKind` + `onReplaceSegment` on `SegmentBar`; "Change motion" section in the context menu |
| `src/components/video-editor/TimelineDock.test.tsx` (modify) | UI tests for the new menu section |
| `src/components/studio/kv-generator/motion/useMotionEditorState.ts` (modify) | `replaceSegment` command |
| `src/components/studio/kv-generator/motion/KvMotionEditor.tsx` (modify) | Wire `onReplaceSegment={state.replaceSegment}` |

---

### Task 1: Extract the keyframe upsert helper

`applyPreset` ends with an inline "merge into an existing keyframe at the same `t_ms`, else push" loop. `replaceSegmentPreset` needs the identical behaviour. Extract it first, as a pure refactor with no behaviour change, so Task 2 has one copy to call.

**Files:**
- Modify: `src/lib/video-editor/presets.ts`
- Test: `src/lib/video-editor/presets.test.ts` (existing — must stay green, no new tests here)

**Interfaces:**
- Consumes: nothing.
- Produces: `function upsertKeyframes(track: MotionTrack, written: MotionKeyframe[], label: string): void` — module-private, mutates `track.keyframes` in place.

- [ ] **Step 1: Run the existing preset tests to establish a green baseline**

Run: `bun test src/lib/video-editor/presets.test.ts`
Expected: PASS (record the test count — Task 1 must not change it)

- [ ] **Step 2: Add the private helper to `presets.ts`**

Insert directly above `export function applyPreset`:

```ts
/** Insert `written` into `track`, merging `props` into an existing keyframe
 *  at an identical `t_ms` rather than adding a duplicate, and stamping
 *  `label` (timeline.ts) on every keyframe it touches. Mutates `track` — both
 *  callers work on a deep copy they just made, never on the caller's own
 *  timeline.
 *
 *  Deliberately NOT used by `applyEmphasisPreset`: that function's own upsert
 *  loop does not carry `easing` over onto a merged keyframe, and changing
 *  that is a behaviour change this refactor has no business making. The two
 *  loops therefore differ by exactly one line, on purpose. */
function upsertKeyframes(
  track: MotionTrack,
  written: MotionKeyframe[],
  label: string,
): void {
  for (const nk of written) {
    const existing = track.keyframes.find((k) => k.t_ms === nk.t_ms);
    if (existing) {
      existing.props = { ...existing.props, ...nk.props };
      existing.easing = nk.easing;
      existing.label = label;
    } else {
      track.keyframes.push({ ...nk, props: { ...nk.props }, label });
    }
  }
}
```

- [ ] **Step 3: Replace `applyPreset`'s inline loop with a call to it**

In `applyPreset`, delete this block:

```ts
  for (const nk of newKeyframes) {
    const existing = track.keyframes.find((k) => k.t_ms === nk.t_ms);
    if (existing) {
      existing.props = { ...existing.props, ...nk.props };
      existing.easing = nk.easing;
      existing.label = label;
    } else {
      track.keyframes.push({ ...nk, props: { ...nk.props }, label });
    }
  }
```

and put this in its place:

```ts
  upsertKeyframes(track, newKeyframes, label);
```

- [ ] **Step 4: Run the tests — same count, still green**

Run: `bun test src/lib/video-editor/presets.test.ts`
Expected: PASS, with the same number of tests as Step 1

- [ ] **Step 5: Commit**

```bash
git add src/lib/video-editor/presets.ts
git commit -m "refactor(web): extract upsertKeyframes from applyPreset"
```

---

### Task 2: `replaceSegmentPreset` engine function

**Files:**
- Modify: `src/lib/video-editor/presets.ts`
- Create: `src/lib/video-editor/presets.replaceSegment.test.ts`

**Interfaces:**
- Consumes: `upsertKeyframes` (Task 1); existing exports `PRESET_WRITERS`, `EMPHASIS_WRITERS`, `EXIT_PRESETS`, `EMPHASIS_PRESET_IDS`, `PRESET_LABELS`; `deleteSegmentKeyframes` and `trackSegments` from `./blocks`; `sampleTimelineAt` from `./sample`.
- Produces:

```ts
export function replaceSegmentPreset(
  timeline: MotionTimeline,
  base: Map<string, MotionProps>,
  overlayId: string,
  segStart: number,
  segEnd: number,
  preset: MotionPresetId | EmphasisPresetId,
): MotionTimeline
```

Returns the same `timeline` reference (a no-op) when the track is missing, `[segStart, segEnd]` is not one of the track's current segments, `segStart >= segEnd`, or the pose cannot be resolved.

- [ ] **Step 1: Write the failing tests**

Create `src/lib/video-editor/presets.replaceSegment.test.ts`:

```ts
import { describe, expect, it } from "bun:test";
import type { MotionProps, MotionTimeline } from "./timeline";
import {
  applyEmphasisPreset,
  applyPreset,
  PRESET_LABELS,
  replaceSegmentPreset,
} from "./presets";
import { stretchSegmentKeyframes, trackSegments } from "./blocks";

const BASE: MotionProps = { x: 0.4, y: 0.3, scale: 1, rotation: 0, opacity: 1 };
const base = () => new Map<string, MotionProps>([["ov1", { ...BASE }]]);
const empty = (durationMs = 5000): MotionTimeline => ({
  version: 1,
  duration_ms: durationMs,
  fps: 30,
  tracks: [],
});

function trackFor(timeline: MotionTimeline, overlayId: string) {
  const t = timeline.tracks.find(
    (x) => x.kind === "overlay" && x.overlay_id === overlayId,
  );
  if (!t) throw new Error(`no track for ${overlayId}`);
  return t;
}

describe("replaceSegmentPreset", () => {
  it("keeps the block's tuned span when the preset changes", () => {
    const faded = applyPreset(empty(), base(), "ov1", "fade-in", 0);
    // The user drags the right handle: [0, 500] -> [0, 1200].
    const stretched = stretchSegmentKeyframes(faded, "ov1", 0, 500, 0, 1200);

    const next = replaceSegmentPreset(stretched, base(), "ov1", 0, 1200, "pop-in");

    expect(trackSegments(trackFor(next, "ov1"))).toEqual([
      { startMs: 0, endMs: 1200 },
    ]);
  });

  it("stamps the NEW preset's label on every keyframe it writes", () => {
    const faded = applyPreset(empty(), base(), "ov1", "fade-in", 0);
    const next = replaceSegmentPreset(faded, base(), "ov1", 0, 500, "pop-in");

    const labels = trackFor(next, "ov1").keyframes.map((k) => k.label);
    expect(labels).toEqual([PRESET_LABELS["pop-in"], PRESET_LABELS["pop-in"]]);
  });

  it("leaves a neighbouring emphasis segment completely untouched", () => {
    const withEntrance = applyPreset(empty(), base(), "ov1", "fade-in", 0);
    const withPulse = applyEmphasisPreset(
      withEntrance,
      base(),
      "ov1",
      "pulse",
      2000,
    )!;
    const before = trackFor(withPulse, "ov1")
      .keyframes.filter((k) => k.t_ms >= 2000)
      .sort((a, b) => a.t_ms - b.t_ms);

    const next = replaceSegmentPreset(
      withPulse,
      base(),
      "ov1",
      0,
      500,
      "slide-in-left",
    );

    const after = trackFor(next, "ov1")
      .keyframes.filter((k) => k.t_ms >= 2000)
      .sort((a, b) => a.t_ms - b.t_ms);
    expect(after).toEqual(before);
  });

  it("is a no-op (same reference) for a stale [start, end] pair", () => {
    const faded = applyPreset(empty(), base(), "ov1", "fade-in", 0);
    expect(replaceSegmentPreset(faded, base(), "ov1", 0, 499, "pop-in")).toBe(
      faded,
    );
  });

  it("is a no-op (same reference) for a still point", () => {
    const still: MotionTimeline = {
      ...empty(),
      tracks: [
        {
          kind: "overlay",
          overlay_id: "ov1",
          keyframes: [{ t_ms: 1000, props: { scale: 1 }, easing: "linear" }],
        },
      ],
    };
    expect(replaceSegmentPreset(still, base(), "ov1", 1000, 1000, "pulse")).toBe(
      still,
    );
  });

  it("is a no-op (same reference) when the track does not exist", () => {
    const t = empty();
    expect(replaceSegmentPreset(t, base(), "ov9", 0, 500, "pop-in")).toBe(t);
  });

  it("writes an emphasis preset across the whole existing span", () => {
    // applyEmphasisPreset's default window is 600ms -> [2000, 2600].
    const withPulse = applyEmphasisPreset(empty(), base(), "ov1", "pulse", 2000)!;

    const next = replaceSegmentPreset(
      withPulse,
      base(),
      "ov1",
      2000,
      2600,
      "shake",
    );

    expect(trackSegments(trackFor(next, "ov1"))).toEqual([
      { startMs: 2000, endMs: 2600 },
    ]);
    expect(
      trackFor(next, "ov1").keyframes.every(
        (k) => k.label === PRESET_LABELS.shake,
      ),
    ).toBe(true);
  });

  it("anchors an exit preset's last keyframe at the block's end", () => {
    const withExit = applyPreset(empty(), base(), "ov1", "fade-out", 5000);

    const next = replaceSegmentPreset(
      withExit,
      base(),
      "ov1",
      4500,
      5000,
      "slide-out-right",
    );

    const times = trackFor(next, "ov1")
      .keyframes.map((k) => k.t_ms)
      .sort((a, b) => a - b);
    expect(times[0]).toBe(4500);
    expect(times[times.length - 1]).toBe(5000);
  });

  it("animates an emphasis replacement around the SAMPLED pose, not the rest pose", () => {
    // A hand-authored y keyframe leaves the layer at y=0.9 well before the
    // emphasis block, so "sampled" (0.9) and "rest" (BASE.y = 0.3) differ.
    const handAuthored: MotionTimeline = {
      ...empty(),
      tracks: [
        {
          kind: "overlay",
          overlay_id: "ov1",
          keyframes: [{ t_ms: 1500, props: { y: 0.9 }, easing: "linear" }],
        },
      ],
    };
    const withPulse = applyEmphasisPreset(
      handAuthored,
      base(),
      "ov1",
      "pulse",
      3000,
    )!;

    const next = replaceSegmentPreset(
      withPulse,
      base(),
      "ov1",
      3000,
      3600,
      "bounce",
    );

    const first = trackFor(next, "ov1").keyframes.find((k) => k.t_ms === 3000);
    expect(first?.props.y).toBe(0.9);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bun test src/lib/video-editor/presets.replaceSegment.test.ts`
Expected: FAIL — `replaceSegmentPreset` is not exported from `./presets`

- [ ] **Step 3: Implement `replaceSegmentPreset`**

In `presets.ts`, add `deleteSegmentKeyframes` to the existing `./blocks` import (which currently imports only `trackSegments`):

```ts
import { deleteSegmentKeyframes, trackSegments } from "./blocks";
```

Then append to the end of the file:

```ts
/** Linearly rescale a freshly written keyframe pair/cluster from its own
 *  natural span onto `[newStartMs, newEndMs]`. A single-point cluster
 *  (nothing to scale a ratio against) collapses onto `newStartMs`. Pure. */
function rescaleKeyframes(
  keyframes: MotionKeyframe[],
  newStartMs: number,
  newEndMs: number,
): MotionKeyframe[] {
  const times = keyframes.map((k) => k.t_ms);
  const oldStart = Math.min(...times);
  const oldSpan = Math.max(...times) - oldStart;
  if (oldSpan <= 0) return keyframes.map((k) => ({ ...k, t_ms: newStartMs }));
  const newSpan = newEndMs - newStartMs;
  return keyframes.map((k) => ({
    ...k,
    t_ms: Math.round(newStartMs + ((k.t_ms - oldStart) / oldSpan) * newSpan),
  }));
}

/** Swap the preset behind ONE existing block — the segment spanning
 *  `[segStart, segEnd]`, per `trackSegments` — for a different one, KEEPING
 *  that block's current span. This is the Slots-view context menu's "Change
 *  motion": the alternative (delete, then re-apply from the ✨ menu) costs
 *  two undo steps, re-anchors the block at the playhead, and throws away a
 *  duration the user tuned by dragging the handles.
 *
 *  Immutable; returns the SAME `timeline` reference (a no-op) when the track
 *  is missing, when `[segStart, segEnd]` doesn't exactly match one of the
 *  track's CURRENT segments (the same staleness guard
 *  `deleteSegmentKeyframes`/`shiftSegmentKeyframes` use — a context menu
 *  opened before an intervening edit must not rewrite the wrong keyframes),
 *  when the span is a still point (`segStart >= segEnd` — nothing to
 *  preserve, and no ratio to rescale against), or when the pose can't be
 *  resolved (overlay absent from the snapshot).
 *
 *  WHY THE WRITERS ARE CALLED DIRECTLY instead of composing the existing
 *  public helpers: the obvious `deleteSegmentKeyframes` -> `applyPreset` ->
 *  `stretchSegmentKeyframes` chain has a real failure mode.
 *  `stretchSegmentKeyframes` RE-DERIVES segments and needs an exact
 *  `[start, end]` match; the pair `applyPreset` just wrote can MERGE with an
 *  adjacent cluster (`trackSegments` clusters by motion continuity, not by
 *  time gaps), and the merged bounds then match nothing the caller can
 *  predict — the stretch silently no-ops and the block snaps back to the
 *  preset's default 500ms. Writing the preset's own output and rescaling it
 *  BEFORE insertion never re-derives anything and never touches a keyframe
 *  outside `[segStart, segEnd]`.
 *
 *  The strip logic inside `applyPreset`/`applyEmphasisPreset` isn't needed
 *  here either: the span is emptied first, so there is nothing stale left to
 *  strip. `applyEmphasisPreset`'s `EMPHASIS_MIN_WINDOW_MS` room check is
 *  likewise not applied — that guard exists because emphasis is normally
 *  anchored at the PLAYHEAD and needs room before the end; here the span is
 *  fixed, already inside the timeline, and known-valid.
 *
 *  KNOWN LIMITATION (accepted): if the rescaled window's boundary lands
 *  exactly on a keyframe owned by a NEIGHBOURING segment, `upsertKeyframes`
 *  merges into it and overwrites the props this preset touches at that one
 *  instant. Neighbours keep the 1ms clearance the shift/stretch primitives
 *  enforce, so this needs an exact collision to bite — the same accepted
 *  blast radius as `applyEmphasisPreset`'s window-scoped strip. */
export function replaceSegmentPreset(
  timeline: MotionTimeline,
  base: Map<string, MotionProps>,
  overlayId: string,
  segStart: number,
  segEnd: number,
  preset: MotionPresetId | EmphasisPresetId,
): MotionTimeline {
  if (segStart >= segEnd) return timeline;

  const current = timeline.tracks.find(
    (t) => t.kind === "overlay" && t.overlay_id === overlayId,
  );
  if (!current) return timeline;
  const isRealSegment = trackSegments(current).some(
    (s) => s.startMs === segStart && s.endMs === segEnd,
  );
  if (!isRealSegment) return timeline;

  // 1. Empty the span. `deleteSegmentKeyframes` drops the track entirely if
  //    nothing is left on it — the track is re-created below in that case.
  const cleared = deleteSegmentKeyframes(timeline, overlayId, segStart, segEnd);

  // 2. Resolve the pose the writer animates around: entrance/exit presets
  //    animate around the overlay's REST pose (matching `applyPreset`);
  //    emphasis presets animate around the pose the layer is actually in at
  //    that moment (matching `applyEmphasisPreset`), sampled AFTER the clear
  //    so the segment being replaced can't contribute to its own input.
  const isEmphasis = (EMPHASIS_PRESET_IDS as string[]).includes(preset);
  const pose = isEmphasis
    ? sampleTimelineAt(cleared, base, segStart).get(overlayId)
    : base.get(overlayId);
  if (!pose) return timeline;

  // 3. Write. EMPHASIS_WRITERS are parameterised by a time mapper, so they
  //    can be written straight onto the target span with no rescale at all.
  //    PRESET_WRITERS take a fixed anchor and produce their own ENTRANCE_MS
  //    span, so their output is rescaled onto the target span afterwards.
  const isExit = EXIT_PRESETS.has(preset as MotionPresetId);
  const written = isEmphasis
    ? EMPHASIS_WRITERS[preset as EmphasisPresetId](pose, (frac) =>
        Math.round(segStart + frac * (segEnd - segStart)),
      )
    : rescaleKeyframes(
        PRESET_WRITERS[preset as MotionPresetId](pose, isExit ? segEnd : segStart),
        segStart,
        segEnd,
      );

  const tracks: MotionTrack[] = cleared.tracks.map((t) => ({
    ...t,
    keyframes: t.keyframes.map((k) => ({ ...k, props: { ...k.props } })),
  }));
  let track = tracks.find(
    (t) => t.kind === "overlay" && t.overlay_id === overlayId,
  );
  if (!track) {
    track = { kind: "overlay", overlay_id: overlayId, keyframes: [] };
    tracks.push(track);
  }
  upsertKeyframes(track, written, PRESET_LABELS[preset]);

  return { ...cleared, tracks };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bun test src/lib/video-editor/presets.replaceSegment.test.ts`
Expected: PASS (9 tests)

- [ ] **Step 5: Run the whole engine suite for regressions**

Run: `bun test src/lib/video-editor/`
Expected: PASS — in particular `importBoundary.test.ts` and the existing `presets.test.ts`

- [ ] **Step 6: Commit**

```bash
git add src/lib/video-editor/presets.ts src/lib/video-editor/presets.replaceSegment.test.ts
git commit -m "feat(web): replaceSegmentPreset — swap a block's preset, keep its span"
```

---

### Task 3: "Change motion" in the segment context menu

**Files:**
- Modify: `src/components/video-editor/types.ts`
- Modify: `src/components/video-editor/TimelineDock.tsx`
- Modify: `src/components/video-editor/BlockTrackRow.tsx`
- Modify: `src/components/video-editor/TimelineDock.test.tsx`

**Interfaces:**
- Consumes: `replaceSegmentPreset` (Task 2) indirectly — this task only threads a callback; the engine call lands in Task 4.
- Produces: `onReplaceSegment: (trackId: string, segStart: number, segEnd: number, presetId: string) => void` on `TimelineDockProps`, and `data-testid="segment-context-replace-<presetId>"` on each option button.

**Design note (deviation from the spec's wording):** the spec drew this as a nested submenu (`Change motion ▸`). It ships as a **flat section inside the same popover** instead — a `Change motion` header, the slot's presets, a divider, then Delete. Base UI nested popovers add focus-management complexity for no user gain, and a flat section is one click instead of two. `SlotPlaceholder` already renders six preset options in a single popover, so the length is proven acceptable.

- [ ] **Step 1: Write the failing tests**

Append to `describe(...)` in `src/components/video-editor/TimelineDock.test.tsx`, right after the existing `"right-clicking a segment opens a context menu; choosing Delete..."` test:

```ts
  it("the segment context menu offers the IN slot's entrance presets, and picking one fires onReplaceSegment with the block's bounds", () => {
    // tl()'s single segment is [0, 250] and starts at 0 -> the "in" slot.
    const h = renderDock({ view: "slots" });
    const body = within(document.body);

    fireEvent.contextMenu(body.getByTestId("block-bar-ov1-0"));

    // An entrance preset is offered; an emphasis one is not.
    expect(body.getByTestId("segment-context-replace-pop-in")).toHaveTextContent(
      "Pop in",
    );
    expect(
      body.queryByTestId("segment-context-replace-pulse"),
    ).not.toBeInTheDocument();

    fireEvent.click(body.getByTestId("segment-context-replace-pop-in"));
    expect(h.onReplaceSegment).toHaveBeenCalledWith("ov1", 0, 250, "pop-in");
    expect(body.queryByRole("menu")).not.toBeInTheDocument();
  });

  it("a still point's context menu offers no Change motion options at all", () => {
    // twoClusterTl()'s second cluster is the zero-span [2000, 2000] marker.
    renderDock({ view: "slots", timeline: twoClusterTl() });
    const body = within(document.body);

    fireEvent.contextMenu(body.getByTestId("block-bar-ov1-1"));

    expect(body.getByTestId("segment-context-delete")).toBeInTheDocument();
    expect(
      body.queryByTestId("segment-context-replace-pop-in"),
    ).not.toBeInTheDocument();
  });
```

Add `onReplaceSegment: mock(),` to `baseHandlers()` (alphabetically it sits fine next to `onDeleteSegment`).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bun test src/components/video-editor/TimelineDock.test.tsx`
Expected: FAIL — no `segment-context-replace-pop-in` testid in the document

- [ ] **Step 3: Add the prop to `types.ts`**

In `TimelineDockProps`, directly after the `onDeleteSegment` declaration:

```ts
  /** Slots view: right-click a segment → "Change motion" → swap the preset
   *  behind it for another from the SAME slot, keeping the block's current
   *  [start, end] span. `presetId` is already filtered to the segment's own
   *  slot kind (entrance ids for "in", exit ids for "out", emphasis ids for
   *  "emphasis"), exactly as `onApplySlotPreset`'s is. */
  onReplaceSegment: (
    trackId: string,
    segStart: number,
    segEnd: number,
    presetId: string,
  ) => void;
```

- [ ] **Step 4: Thread it through `TimelineDock.tsx`**

Add `onReplaceSegment,` to the destructured props (next to `onDeleteSegment,` on line ~67) and `onReplaceSegment={onReplaceSegment}` to the `<BlockTrackRow ... />` call (next to `onDeleteSegment={onDeleteSegment}` on line ~276).

- [ ] **Step 5: Add the props to `BlockTrackRow`'s two prop types**

In `BlockTrackRowProps`, after `onDeleteSegment`:

```ts
  /** Right-click a segment → "Change motion" → pick a preset. See
   *  `TimelineDockProps.onReplaceSegment`. */
  onReplaceSegment: (
    trackId: string,
    segStart: number,
    segEnd: number,
    presetId: string,
  ) => void;
```

In `SegmentBarProps`, add both:

```ts
  /** Which authoring slot this segment was bucketed onto
   *  (`assignSegmentsToSlots`) — decides which preset family the "Change
   *  motion" section offers. Passed down rather than re-derived so the bar
   *  and the lane can never disagree about which slot it is in. */
  slotKind: SlotKind;
  onReplaceSegment: (
    trackId: string,
    segStart: number,
    segEnd: number,
    presetId: string,
  ) => void;
```

Destructure `slotKind` and `onReplaceSegment` in both function signatures.

- [ ] **Step 6: Build the option list inside `SegmentBar`**

Add the `Check` icon to the existing phosphor import:

```ts
import { Check, Plus } from "@phosphor-icons/react";
```

Then, directly above `const contextMenu = menuAnchor && (`:

```ts
  // "Change motion" options, filtered to this segment's own slot — the same
  // family split `SlotPlaceholder` uses for an EMPTY slot, so a block offers
  // exactly the presets that could have created it. A still point has no span
  // to preserve and so offers none (Delete-only menu, as before).
  const replaceOptions = isStill
    ? []
    : (slotKind === "in"
        ? ENTRANCE_PRESET_IDS
        : slotKind === "out"
          ? EXIT_PRESET_IDS
          : EMPHASIS_PRESET_IDS
      ).map((id) => ({
        id: id as string,
        label: PRESET_LABELS[id],
        // `label` is `segmentLabel`'s output — the preset name stamped on the
        // segment's earliest keyframe, or a property list when it was
        // hand-authored. A hand-authored segment therefore matches nothing
        // and simply shows no check, which is correct.
        active: label === PRESET_LABELS[id],
      }));
```

- [ ] **Step 7: Render the section in the context menu**

Replace the contents of the `<div role="menu" aria-label="Segment actions">` — keep the existing Delete button exactly as it is, and put this above it:

```tsx
          {replaceOptions.length > 0 && (
            <>
              <div className="px-2 py-1 text-textXsMedium text-text-inverse-subtlest">
                Change motion
              </div>
              {replaceOptions.map((opt) => (
                <button
                  key={opt.id}
                  type="button"
                  role="menuitem"
                  data-testid={`segment-context-replace-${opt.id}`}
                  onClick={() => {
                    onReplaceSegment(
                      trackId,
                      segment.startMs,
                      segment.endMs,
                      opt.id,
                    );
                    onCloseMenu();
                  }}
                  className="flex w-full items-center gap-2 rounded-lg p-2 text-left text-textSm text-text-inverse outline-none transition-all duration-200 ease-out hover:bg-white/5 focus-visible:ring-2 focus-visible:ring-white/40"
                >
                  <span className="truncate">{opt.label}</span>
                  {opt.active && (
                    <Check aria-hidden className="ml-auto size-3.5 shrink-0" />
                  )}
                </button>
              ))}
              <div className="my-1 border-t border-border-default" />
            </>
          )}
```

Widen the popover so the longest label ("Slide in right") fits: change `<Popover.Content side="bottom" align="start" className="w-36">` to `className="w-52"` (matching `SlotPlaceholder`'s own preset popover).

- [ ] **Step 8: Pass the two new props at the `SegmentBar` call site**

In `BlockTrackRow`'s `SLOT_ORDER.flatMap(...)`, add to the `<SegmentBar ... />` props (the `kind` variable is already in scope from the flatMap):

```tsx
                  slotKind={kind}
                  onReplaceSegment={onReplaceSegment}
```

- [ ] **Step 9: Run the tests to verify they pass**

Run: `bun test src/components/video-editor/TimelineDock.test.tsx`
Expected: PASS, including the pre-existing menu tests

- [ ] **Step 10: Commit**

```bash
git add src/components/video-editor/types.ts src/components/video-editor/TimelineDock.tsx src/components/video-editor/BlockTrackRow.tsx src/components/video-editor/TimelineDock.test.tsx
git commit -m "feat(web): Change motion section in the segment context menu"
```

---

### Task 4: Wire the command into the KV motion editor

**Files:**
- Modify: `src/components/studio/kv-generator/motion/useMotionEditorState.ts`
- Modify: `src/components/studio/kv-generator/motion/KvMotionEditor.tsx`
- Test: `src/components/studio/kv-generator/motion/useMotionEditorState.test.ts`

**Interfaces:**
- Consumes: `replaceSegmentPreset` (Task 2), `onReplaceSegment` (Task 3).
- Produces: `state.replaceSegment(trackId, segStart, segEnd, presetId)` on the hook's return value.

- [ ] **Step 1: Write the failing test**

Append to `describe("useMotionEditorState", ...)` in `src/components/studio/kv-generator/motion/useMotionEditorState.test.ts`, next to the existing `shiftSegment` / `stretchSegment` tests it mirrors:

```ts
  it("replaceSegment swaps the block's preset in ONE undo step, keeping its span", () => {
    const project = makeProject();
    const { result } = renderHook(
      () => useMotionEditorState(project, { autosave: false }),
      {
        wrapper: qcWrapper,
      }
    );
    // Anchor at t=0 (x=0.1, ov1's base) + an x edit at t=200 — one
    // hand-authored segment [0, 200], same setup as the shiftSegment test.
    act(() => result.current.seek(200));
    act(() => result.current.onOverlayTransformed("ov1", { x: 0.5 }));
    // Drag the right handle out to 1200 — the tuned span the swap must keep.
    act(() => result.current.stretchSegment("ov1", 0, 200, 0, 1200));
    expect(
      result.current.timeline.tracks[0].keyframes.map((k) => k.t_ms)
    ).toEqual([0, 1200]);

    act(() => result.current.replaceSegment("ov1", 0, 1200, "pop-in"));

    const after = result.current.timeline.tracks[0].keyframes;
    expect(after.map((k) => k.t_ms)).toEqual([0, 1200]);
    expect(after.every((k) => k.label === "Pop in")).toBe(true);

    // ONE undo, not two: the clear + write + rescale must land as a single
    // push(). After it, the hand-authored (unlabeled) keyframes are back.
    act(() => result.current.undo());
    expect(
      result.current.timeline.tracks[0].keyframes.every(
        (k) => k.label === undefined
      )
    ).toBe(true);
  });
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bun test src/components/studio/kv-generator/motion/useMotionEditorState.test.ts`
Expected: FAIL — `result.current.replaceSegment is not a function`

- [ ] **Step 3: Add the command to the hook**

Add `replaceSegmentPreset` to the existing `@/lib/video-editor/presets` import, then insert directly below `deleteSegment`:

```ts
  // Slots-view segment context menu "Change motion" — swap the preset behind
  // one block while keeping its span. One deliberate click, not a drag/edit
  // burst, so no coalescing label: same rationale as deleteSegment above.
  const replaceSegment = useCallback(
    (trackId: string, segStart: number, segEnd: number, presetId: string) => {
      push(
        replaceSegmentPreset(
          timeline,
          base,
          trackId,
          segStart,
          segEnd,
          presetId as MotionPresetId | EmphasisPresetId,
        ),
      );
    },
    [timeline, base, push],
  );
```

Add `replaceSegment,` to the object the hook returns, next to `deleteSegment,`.

- [ ] **Step 4: Wire it in `KvMotionEditor.tsx`**

Next to `onDeleteSegment={state.deleteSegment}` (line ~1472):

```tsx
              onReplaceSegment={state.replaceSegment}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bun test src/components/studio/kv-generator/motion/ src/components/video-editor/`
Expected: PASS

- [ ] **Step 6: Build to confirm nothing is structurally broken**

Run: `bun run build`
Expected: build succeeds (remember: it does **not** type-check)

- [ ] **Step 7: Commit**

```bash
git add src/components/studio/kv-generator/motion/useMotionEditorState.ts src/components/studio/kv-generator/motion/useMotionEditorState.test.ts src/components/studio/kv-generator/motion/KvMotionEditor.tsx
git commit -m "feat(web): wire Change motion into the KV motion editor"
```

---

## Manual verification

1. Open a KV motion project with at least one animated layer, in the **Slots** view.
2. Drag a block's right handle to lengthen it. Note the length.
3. Right-click the block → **Change motion** → pick a different preset.
4. The block keeps the length from step 2, its label reads the new preset's name, and the canvas preview plays the new motion.
5. One `Cmd+Z` restores the previous preset — not two.
6. Right-click a still-point diamond: only **Delete** is offered.
7. Right-click a block in the **Out** slot: only exit presets are offered; in **Emphasis**, only emphasis presets.

## Before calling this done

Invoke the `frndos-analytics-events` agent over the changed web files — PostHog events are part of the feature, not an afterthought.
