# KV Motion — Per-Property Sub-Rows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a layer row in the KV Motion timeline expand into Position / Scale / Rotation / Opacity sub-rows, so a layer carrying several stacked animations becomes legible at a glance.

**Architecture:** A new pure `propGroupSegments` in `blocks.ts` reuses the existing `trackSegments` clustering against a keyframe list narrowed to one property group. `TrackNameCell` grows an optional chevron; `TimelineDock` owns the expanded set as session-only UI state; `BlockTrackRow` returns its row plus one read-only sub-row per non-empty group.

**Tech Stack:** TypeScript, React 19, `bun test`, `@testing-library/react`, `@phosphor-icons/react`.

**Spec:** `docs/superpowers/specs/2026-08-29-kv-motion-timeline-upgrades-design.md`

## Global Constraints

- Worktree: `web/.worktrees/kv-motion-timeline-upgrades`, branch `feature/daffa/vc-kv-motion-timeline-upgrades`. All paths are relative to it.
- Tests run with **`bun test`**, never `bunx vitest`.
- No type gate: `next build` sets `ignoreBuildErrors`, `tsc` has a large pre-existing baseline.
- `src/lib/video-editor/` must not import from `components/studio/kv-generator` or `lib/studio/kv`.
- **Sub-rows are read-only in v1.** No drag, no resize handles, no grab cursor. One `MotionKeyframe` carries several props, so dragging one property's bar means splitting a keyframe in two — a change to how the document is mutated, not a UI addition, and out of scope here.
- Expanded state is **session-only**, like `view` and `loop` — it never enters the `MotionTimeline` document.
- Property group names derive from the existing `PROP_LABEL_GROUPS` in `blocks.ts`. Do not introduce a second grouping table.

## File Structure

| File | Responsibility |
|---|---|
| `src/lib/video-editor/blocks.ts` (modify) | Export `PROP_LABEL_GROUPS`, add `PropGroupKey` + `propGroupSegments` |
| `src/lib/video-editor/blocks.propGroups.test.ts` (create) | Tests for the new helper |
| `src/components/video-editor/TrackNameCell.tsx` (modify) | Optional expand chevron |
| `src/components/video-editor/BlockTrackRow.tsx` (modify) | Render the sub-rows |
| `src/components/video-editor/TimelineDock.tsx` (modify) | Own the expanded-track set |
| `src/components/video-editor/TimelineDock.test.tsx` (modify) | UI tests |

---

### Task 1: `propGroupSegments` engine helper

**Files:**
- Modify: `src/lib/video-editor/blocks.ts`
- Create: `src/lib/video-editor/blocks.propGroups.test.ts`

**Interfaces:**
- Consumes: the existing private `PROP_LABEL_GROUPS` and exported `trackSegments` in the same file.
- Produces:

```ts
export const PROP_LABEL_GROUPS: readonly { keys: readonly (keyof MotionProps)[]; label: string }[];
export type PropGroupKey = (typeof PROP_LABEL_GROUPS)[number]["label"];
export function propGroupSegments(track: MotionTrack, group: PropGroupKey): TrackSegment[];
```

`PropGroupKey` resolves to `"position" | "scale" | "rotation" | "opacity"`.

- [ ] **Step 1: Write the failing tests**

Create `src/lib/video-editor/blocks.propGroups.test.ts`:

```ts
import { describe, expect, it } from "bun:test";
import type { MotionTrack } from "./timeline";
import { propGroupSegments, PROP_LABEL_GROUPS } from "./blocks";

/** A track with an x-only shake early on and a scale-only pulse later — the
 *  two share no property, so each group must see exactly ONE cluster, not
 *  two. */
const mixedTrack: MotionTrack = {
  kind: "overlay",
  overlay_id: "ov1",
  keyframes: [
    { t_ms: 0, props: { x: 0.4 }, easing: "linear" },
    { t_ms: 300, props: { x: 0.5 }, easing: "linear" },
    { t_ms: 600, props: { x: 0.4 }, easing: "out" },
    { t_ms: 2000, props: { scale: 1 }, easing: "linear" },
    { t_ms: 2600, props: { scale: 1.1 }, easing: "out" },
  ],
};

describe("propGroupSegments", () => {
  it("clusters each property group independently", () => {
    expect(propGroupSegments(mixedTrack, "position")).toEqual([
      { startMs: 0, endMs: 600 },
    ]);
    expect(propGroupSegments(mixedTrack, "scale")).toEqual([
      { startMs: 2000, endMs: 2600 },
    ]);
  });

  it("returns nothing for a group with no keyframes", () => {
    expect(propGroupSegments(mixedTrack, "rotation")).toEqual([]);
    expect(propGroupSegments(mixedTrack, "opacity")).toEqual([]);
  });

  it("puts a keyframe carrying two groups' props into BOTH groups", () => {
    const both: MotionTrack = {
      kind: "overlay",
      overlay_id: "ov1",
      keyframes: [
        { t_ms: 0, props: { x: 0.4, scale: 0.6 }, easing: "linear" },
        { t_ms: 500, props: { x: 0.5, scale: 1 }, easing: "out" },
      ],
    };
    expect(propGroupSegments(both, "position")).toEqual([
      { startMs: 0, endMs: 500 },
    ]);
    expect(propGroupSegments(both, "scale")).toEqual([
      { startMs: 0, endMs: 500 },
    ]);
  });

  it("groups x and y together as one 'position' lane", () => {
    const xy: MotionTrack = {
      kind: "overlay",
      overlay_id: "ov1",
      keyframes: [
        { t_ms: 0, props: { x: 0.4 }, easing: "linear" },
        { t_ms: 200, props: { y: 0.3 }, easing: "linear" },
        { t_ms: 400, props: { x: 0.6 }, easing: "out" },
      ],
    };
    expect(propGroupSegments(xy, "position")).toEqual([
      { startMs: 0, endMs: 400 },
    ]);
  });

  it("returns nothing for a track with no keyframes at all", () => {
    expect(
      propGroupSegments(
        { kind: "overlay", overlay_id: "ov1", keyframes: [] },
        "opacity",
      ),
    ).toEqual([]);
  });

  it("exposes the four groups in a fixed display order", () => {
    expect(PROP_LABEL_GROUPS.map((g) => g.label)).toEqual([
      "position",
      "scale",
      "rotation",
      "opacity",
    ]);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bun test src/lib/video-editor/blocks.propGroups.test.ts`
Expected: FAIL — `propGroupSegments` is not exported from `./blocks`

- [ ] **Step 3: Make `PROP_LABEL_GROUPS` exported and literal-typed**

In `blocks.ts`, replace the declaration:

```ts
const PROP_LABEL_GROUPS: readonly {
  keys: readonly (keyof MotionProps)[];
  label: string;
}[] = [
  { keys: ["x", "y"], label: "position" },
  { keys: ["scale"], label: "scale" },
  { keys: ["rotation"], label: "rotation" },
  { keys: ["opacity"], label: "opacity" },
];
```

with:

```ts
/** Friendly names for the 5 animatable props, grouped (x and/or y collapse
 *  to one "position" label) and listed in the FIXED order `segmentPropLabel`
 *  joins them in — position, then scale, then rotation, then opacity.
 *
 *  Exported (2026-08-29) so the per-property sub-row view derives its lanes,
 *  their order, and their names from this one table rather than a second
 *  copy that could drift from what a segment's own label says. `as const
 *  satisfies` rather than a plain annotation: the literal `label` types are
 *  what make `PropGroupKey` below a useful union instead of `string`. */
export const PROP_LABEL_GROUPS = [
  { keys: ["x", "y"], label: "position" },
  { keys: ["scale"], label: "scale" },
  { keys: ["rotation"], label: "rotation" },
  { keys: ["opacity"], label: "opacity" },
] as const satisfies readonly {
  keys: readonly (keyof MotionProps)[];
  label: string;
}[];

/** One lane of the per-property sub-row view — `"position" | "scale" |
 *  "rotation" | "opacity"`, derived from the table above so the two can
 *  never disagree about which groups exist. */
export type PropGroupKey = (typeof PROP_LABEL_GROUPS)[number]["label"];
```

- [ ] **Step 4: Add `propGroupSegments`**

Append to `blocks.ts`:

```ts
/** The segments a track's keyframes form when only ONE property group is
 *  considered — the per-property sub-row view's lane data.
 *
 *  Implemented by narrowing the track's keyframes to just that group's props
 *  (dropping any keyframe left with none) and handing the result to
 *  `trackSegments`, so clustering here is the SAME motion-continuity rule
 *  the parent row uses, applied to a smaller set. Deliberately not a second
 *  clustering implementation: a sub-row that split its bars on a different
 *  rule than the row above it would be actively misleading.
 *
 *  A keyframe carrying props from two groups appears in BOTH groups' lanes —
 *  correct, since that instant genuinely is a keyframe of both. Pure; never
 *  mutates `track`. `[]` for a group with no keyframes. */
export function propGroupSegments(
  track: MotionTrack,
  group: PropGroupKey,
): TrackSegment[] {
  const keys =
    PROP_LABEL_GROUPS.find((g) => g.label === group)?.keys ?? [];
  const keyframes = track.keyframes
    .map((k) => {
      const props: Partial<MotionProps> = {};
      for (const key of keys) {
        if (k.props[key] !== undefined) props[key] = k.props[key];
      }
      return { ...k, props };
    })
    .filter((k) => Object.keys(k.props).length > 0);
  return trackSegments({ ...track, keyframes });
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bun test src/lib/video-editor/`
Expected: PASS — including the existing `blocks.test.ts` (the `PROP_LABEL_GROUPS` retype must not change `segmentPropLabel`'s behaviour)

- [ ] **Step 6: Commit**

```bash
git add src/lib/video-editor/blocks.ts src/lib/video-editor/blocks.propGroups.test.ts
git commit -m "feat(web): propGroupSegments — per-property segment clustering"
```

---

### Task 2: Expand chevron on the track name cell

**Files:**
- Modify: `src/components/video-editor/TrackNameCell.tsx`

**Interfaces:**
- Consumes: nothing.
- Produces: three optional props on `TrackNameCellProps` — `expandable?: boolean`, `expanded?: boolean`, `onToggleExpanded?: (trackId: string) => void` — and `data-testid="track-expand-<trackId>"` on the button.

Optional so `TrackRow` (the keyframes view) keeps its current rail untouched: only `BlockTrackRow` passes them.

- [ ] **Step 1: Add the props**

In `TrackNameCellProps`:

```ts
  /** Slots view only: whether this track has anything to expand INTO (i.e.
   *  it has at least one keyframe). When false the chevron's space is still
   *  reserved, so names across rows stay aligned whether or not a given row
   *  is expandable. */
  expandable?: boolean;
  expanded?: boolean;
  onToggleExpanded?: (trackId: string) => void;
```

Destructure all three in the signature.

- [ ] **Step 2: Render the chevron**

Add `CaretRight` to the phosphor import. Insert directly before the `<Icon ... />` element:

```tsx
        {onToggleExpanded &&
          (expandable ? (
            <button
              type="button"
              data-testid={`track-expand-${track.id}`}
              aria-label={
                expanded ? "Collapse properties" : "Expand properties"
              }
              aria-expanded={expanded}
              onClick={() => onToggleExpanded(track.id)}
              className="flex size-4 shrink-0 items-center justify-center rounded text-icon-inverse-subtlest outline-none transition-colors hover:text-text-inverse focus-visible:ring-2 focus-visible:ring-white/40"
            >
              <CaretRight
                size={10}
                weight="bold"
                className={cn(
                  "transition-transform duration-150",
                  expanded && "rotate-90",
                )}
              />
            </button>
          ) : (
            // A track with no keyframes has nothing to expand into, but its
            // NAME must still line up with the expandable rows above and
            // below it — so the chevron's space is held, not collapsed.
            <span aria-hidden className="size-4 shrink-0" />
          ))}
```

- [ ] **Step 3: Verify the existing rail tests still pass**

Run: `bun test src/components/video-editor/`
Expected: PASS — no caller passes `onToggleExpanded` yet, so nothing renders and nothing changes

- [ ] **Step 4: Commit**

```bash
git add src/components/video-editor/TrackNameCell.tsx
git commit -m "feat(web): optional expand chevron on the timeline track name cell"
```

---

### Task 3: Render the sub-rows

**Files:**
- Modify: `src/components/video-editor/BlockTrackRow.tsx`
- Modify: `src/components/video-editor/TimelineDock.tsx`
- Modify: `src/components/video-editor/TimelineDock.test.tsx`

**Interfaces:**
- Consumes: `propGroupSegments`, `PROP_LABEL_GROUPS`, `PropGroupKey` (Task 1); the chevron props (Task 2).
- Produces: `expanded: boolean` and `onToggleExpanded: (trackId: string) => void` on `BlockTrackRowProps`; `data-testid="prop-row-<trackId>-<group>"` per sub-row and `data-testid="prop-bar-<trackId>-<group>-<index>"` per bar.

- [ ] **Step 1: Write the failing tests**

Append to `src/components/video-editor/TimelineDock.test.tsx`:

```ts
  it("expanding a track renders one sub-row per property group that has keyframes", () => {
    // labeledTwoClusterTl: opacity [0,1000] and scale [2000,3000] — so two
    // sub-rows, and none for position or rotation.
    renderDock({ view: "slots", timeline: labeledTwoClusterTl() });
    const body = within(document.body);

    fireEvent.click(body.getByTestId("track-expand-ov1"));

    expect(body.getByTestId("prop-row-ov1-opacity")).toBeInTheDocument();
    expect(body.getByTestId("prop-row-ov1-scale")).toBeInTheDocument();
    expect(body.queryByTestId("prop-row-ov1-position")).not.toBeInTheDocument();
    expect(body.queryByTestId("prop-row-ov1-rotation")).not.toBeInTheDocument();
  });

  it("collapsing a track removes its sub-rows again", () => {
    renderDock({ view: "slots", timeline: labeledTwoClusterTl() });
    const body = within(document.body);
    const chevron = body.getByTestId("track-expand-ov1");

    fireEvent.click(chevron);
    expect(body.getByTestId("prop-row-ov1-scale")).toBeInTheDocument();

    fireEvent.click(chevron);
    expect(body.queryByTestId("prop-row-ov1-scale")).not.toBeInTheDocument();
  });

  it("sub-row bars are read-only — no resize handles, marked aria-disabled", () => {
    renderDock({ view: "slots", timeline: labeledTwoClusterTl() });
    const body = within(document.body);

    fireEvent.click(body.getByTestId("track-expand-ov1"));

    const bar = body.getByTestId("prop-bar-ov1-scale-0");
    expect(bar).toHaveAttribute("aria-disabled", "true");
    expect(
      body.queryByTestId("block-handle-right-ov1-scale-0"),
    ).not.toBeInTheDocument();
  });

  it("a track with no keyframes offers no expand chevron", () => {
    renderDock({
      view: "slots",
      timeline: { ...DEFAULT_TIMELINE(), tracks: [] },
    });
    expect(
      within(document.body).queryByTestId("track-expand-ov1"),
    ).not.toBeInTheDocument();
  });

  it("the keyframes view has no expand chevron at all", () => {
    renderDock({ view: "keyframes", timeline: labeledTwoClusterTl() });
    expect(
      within(document.body).queryByTestId("track-expand-ov1"),
    ).not.toBeInTheDocument();
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bun test src/components/video-editor/TimelineDock.test.tsx`
Expected: FAIL — no `track-expand-ov1` element in the document

- [ ] **Step 3: Own the expanded set in `TimelineDock`**

Add next to the existing dock-local `scale` state:

```ts
  // Which tracks are expanded into their per-property sub-rows. Dock-local
  // and session-only, exactly like `scale` above and for the same reason:
  // expanding a row changes nothing about the timeline document, playback,
  // or the export, so nothing outside this component needs to know about it.
  const [expandedTracks, setExpandedTracks] = useState<ReadonlySet<string>>(
    () => new Set(),
  );
  const toggleExpanded = useCallback((trackId: string) => {
    setExpandedTracks((prev) => {
      const next = new Set(prev);
      if (next.has(trackId)) next.delete(trackId);
      else next.add(trackId);
      return next;
    });
  }, []);
```

Add `useCallback` to the React import if it is not already there. Pass to `<BlockTrackRow ... />`:

```tsx
                expanded={expandedTracks.has(track.id)}
                onToggleExpanded={toggleExpanded}
```

- [ ] **Step 4: Accept the props and render sub-rows in `BlockTrackRow`**

Add to the imports:

```ts
import {
  assignSegmentsToSlots,
  propGroupSegments,
  PROP_LABEL_GROUPS,
  segmentLabel,
  segmentPropLabel,
  slotPlaceholderRegion,
  trackSegments,
  type PropGroupKey,
  type SlotKind,
  type TrackSegment,
} from "@/lib/video-editor/blocks";
import { clamp, LANE_WIDTH_VAR, RAIL_WIDTH_CLASS, type TrackDescriptor } from "./types";
```

Add to `BlockTrackRowProps`:

```ts
  /** Whether this row is expanded into its per-property sub-rows. Session-
   *  only UI state owned by `TimelineDock` — never part of the timeline
   *  document. */
  expanded: boolean;
  onToggleExpanded: (trackId: string) => void;
```

Add the sub-row component above `BlockTrackRow`:

```tsx
/** One read-only per-property lane under an expanded track row — the bars a
 *  single property group's keyframes form (`propGroupSegments`).
 *
 *  READ-ONLY BY DESIGN, not by omission: one `MotionKeyframe` carries a
 *  sparse subset of SEVERAL props, so dragging one property's bar would mean
 *  SPLITTING a keyframe in two (the dragged props move to a new keyframe at
 *  the new time, the rest stay behind). That is a change to how the document
 *  is mutated, not a UI addition, and it is the kind of change that corrupts
 *  timelines quietly. This view ships the reading tool; making the bars
 *  draggable is a self-contained follow-up.
 *
 *  So the bars carry no drag affordance whatsoever — no handles, no grab
 *  cursor, `aria-disabled` where a `SegmentBar` would be a button. */
function PropSubRow({
  trackId,
  group,
  segments,
  durationMs,
  dimmed,
}: {
  trackId: string;
  group: PropGroupKey;
  segments: TrackSegment[];
  durationMs: number;
  /** Mirrors the parent row's locked/hidden lane dim. */
  dimmed: boolean;
}) {
  const label = group.charAt(0).toUpperCase() + group.slice(1);
  return (
    <div
      data-testid={`prop-row-${trackId}-${group}`}
      className="flex h-7 items-stretch"
    >
      <div
        className={cn(RAIL_WIDTH_CLASS, "bg-app-panel sticky left-0 z-30 shrink-0")}
      >
        {/* pl-9 lines the sub-row name up under the parent's NAME (chevron +
         *  type icon + gap), so the indent reads as containment rather than
         *  as an unrelated row that happens to be narrower. */}
        <div className="flex h-full items-center pl-9 pr-1.5">
          <span className="truncate text-textXsMedium text-text-inverse-subtlest">
            {label}
          </span>
        </div>
      </div>
      <div
        style={{ width: `var(${LANE_WIDTH_VAR})` }}
        className={cn("relative shrink-0 px-1", dimmed && "opacity-50")}
      >
        {segments.map((segment, index) => {
          const leftPct = durationMs > 0 ? (segment.startMs / durationMs) * 100 : 0;
          const widthPct =
            durationMs > 0 ? ((segment.endMs - segment.startMs) / durationMs) * 100 : 0;
          return (
            <div
              key={`${segment.startMs}-${segment.endMs}`}
              data-testid={`prop-bar-${trackId}-${group}-${index}`}
              aria-disabled="true"
              title={`${label} — ${fmtSeconds(segment.endMs - segment.startMs)}`}
              style={{
                left: `${leftPct}%`,
                width: `max(${MIN_VISUAL_WIDTH_PX}px, ${widthPct}%)`,
              }}
              className="absolute top-1/2 h-2.5 -translate-y-1/2 rounded-sm bg-white/20"
            />
          );
        })}
      </div>
    </div>
  );
}
```

- [ ] **Step 5: Wire the chevron and emit the sub-rows**

Inside `BlockTrackRow`, destructure `expanded` and `onToggleExpanded`, then compute:

```ts
  const expandable = keyframes.length > 0;
  const subRows = expanded
    ? PROP_LABEL_GROUPS.map((g) => ({
        group: g.label,
        segments: propGroupSegments(trackShape, g.label),
      })).filter((r) => r.segments.length > 0)
    : [];
```

Pass the chevron props to `TrackNameCell`:

```tsx
      <TrackNameCell
        track={track}
        selected={selected}
        expandable={expandable}
        expanded={expanded}
        onToggleExpanded={onToggleExpanded}
        onToggleLocked={onToggleLocked}
        onToggleHidden={onToggleHidden}
      />
```

Finally, wrap the component's return in a fragment so the sub-rows are siblings of the row (not nested inside its `h-9` box): keep the existing `<div data-testid={`track-row-${track.id}`} ...>...</div>` exactly as it is, wrap it in `<>...</>`, and add after it:

```tsx
      {subRows.map((r) => (
        <PropSubRow
          key={r.group}
          trackId={track.id}
          group={r.group}
          segments={r.segments}
          durationMs={durationMs}
          dimmed={locked || Boolean(track.hidden)}
        />
      ))}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bun test src/components/video-editor/TimelineDock.test.tsx`
Expected: PASS, including every pre-existing row test

- [ ] **Step 7: Run the full timeline suite**

Run: `bun test src/components/video-editor/ src/lib/video-editor/`
Expected: PASS

- [ ] **Step 8: Build**

Run: `bun run build`
Expected: build succeeds

- [ ] **Step 9: Commit**

```bash
git add src/components/video-editor/BlockTrackRow.tsx src/components/video-editor/TimelineDock.tsx src/components/video-editor/TimelineDock.test.tsx
git commit -m "feat(web): expand a timeline layer into per-property sub-rows"
```

---

## Manual verification

1. Open a KV motion project, **Slots** view, on a layer carrying both an entrance and an emphasis.
2. Click the chevron on that layer's name — sub-rows appear for exactly the properties it animates.
3. The sub-row bars sit at the same times as the parent row's blocks, and stay aligned when you zoom.
4. Try to drag a sub-row bar: nothing moves, and no resize handle appears on hover.
5. Collapse it again — the sub-rows disappear and the row height returns to normal.
6. A layer with no keyframes shows no chevron, and its name still lines up with the rows around it.
7. Switch to the **Keyframes** view: no chevrons anywhere.

## Before calling this done

Invoke the `frndos-analytics-events` agent over the changed web files.
