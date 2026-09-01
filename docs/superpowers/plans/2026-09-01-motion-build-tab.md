# Motion "Build" Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user compose a layer's animation by picking which property channels take part — Move, Scale, Rotate, Opacity — from an empty slot's chip menu, instead of picking one canned preset that decides for them.

**Architecture:** Three layers, each shippable on its own. A pure writer in `presets.ts` turns a slot + a set of channels into keyframes, reusing the existing preset constants and emphasis writers so Build output feels like the rest of the editor. A third tab in the shared tab row, offered ONLY on the slot chips, renders the four channels as toggleable preview cards plus one "Add to <Slot>" button. The editor-state hook wires the writer to the dock through one command, exactly as `applySlotPreset` already does.

**Tech Stack:** TypeScript, React 19, Next.js 16, bun test + @testing-library/react.

**Spec:** `docs/superpowers/specs/2026-08-31-motion-build-tab-design.md`

**Depends on:** `docs/superpowers/plans/2026-08-31-motion-prop-lane-drag.md` — shipped and MERGED into `develop` as PR #563, plus a follow-up commit (`59cb90ac8`) addressing seven review findings. That follow-up reformatted several of the files below to prettier and added a `trackKvMotionPropLaneDragged` event; it did not change any API this plan calls. Build writes every selected channel into the SAME window; the per-property lanes from that plan are what pull them apart afterwards. Without them Build produces a composition the user cannot tune.

## Global Constraints

- All work is in `web/`. Run every command from `web/`.
- Tests run with `bun test <path>` — **never** `bunx vitest`. `bunfig.toml` preloads jest-dom.
- `screen` from @testing-library is broken in this project. Always use `within(document.body)`.
- jsdom here has no `PointerEvent`. Sibling drag tests carry a `PointerEventPolyfill` shim; copy that pattern if a test needs pointer events (this plan's tests need only clicks).
- New test files only. Do **not** add to `presets.test.ts` (44.1KB), `blocks.test.ts` (37.9KB) or `TimelineDock.test.tsx` (48.8KB) — all three sit at or near bun 1.3.2's ~51KB transpiler cliff, past which a file dies with a bogus SCSS parse error naming `base.module.scss`.
- New props on `TimelineDockProps` MUST be optional, so existing harnesses gain no type error and a host that omits them simply gets no Build tab.
- Lint changed files only: `bunx eslint <paths>`. **Verified on 2026-09-01, after PR #563's review fixes reformatted them:** `blocks.ts`, `useMotionEditorState.ts`, `BlockTrackRow.tsx`, `KvMotionEditor.tsx` and `MotionSourceTabs.tsx` are now prettier-**clean**, so keep them that way — `bunx eslint --fix` on those is safe and expected. `presets.ts` is still NOT clean (it has a pre-existing baseline): do not reformat it and never run a blanket `--fix` over it. Re-check with `bunx prettier --check <file>` rather than trusting this line if you find it disagrees.
- No type gate: `next build` sets `ignoreBuildErrors` and `tsc --noEmit` has a ~1080-line pre-existing baseline. Judge `tsc` only by whether YOUR files appear. `KvMotionEditor.tsx` has one baseline `useAuth()` error — not yours.
- Stage with explicit paths — never `git add -A` or `git add .`. A task in the previous plan swept an unrelated feature into its commit that way.
- **Assertion strength is the known weak spot of this feature area.** Five assertions across the previous plan were caught passing under the very regression they existed to catch. Assert whole arrays and `(time, value)` pairs, never aggregates like `Math.max` or a bare "mock was called".

---

### Task 1: Channel writers and `applyBuildChannels`

**Files:**
- Modify: `web/src/lib/video-editor/presets.ts`
- Test: `web/src/lib/video-editor/presets.buildChannels.test.ts`

**Interfaces:**
- Consumes (all already in `presets.ts`, same module — no new exports needed to reach them): `ENTRANCE_MS`, `SLIDE_OFFSET`, `POP_FROM_SCALE`, `EMPHASIS_WINDOW_MS`, `EMPHASIS_MIN_WINDOW_MS`, `EMPHASIS_WRITERS`, `sampleTimelineAt`, `SlotKind`
- Produces:
  ```ts
  export type BuildChannelId = "move" | "scale" | "rotate" | "opacity";
  export const BUILD_CHANNEL_IDS: BuildChannelId[];
  export const BUILD_CHANNEL_LABELS: Record<BuildChannelId, string>;
  export const BUILD_ROTATE_DEG = 15;
  export const BUILD_BLINK_OPACITY = 0.4;
  export function applyBuildChannels(
    timeline: MotionTimeline,
    base: Map<string, MotionProps>,
    overlayId: string,
    slot: SlotKind,
    channels: BuildChannelId[],
    atMs: number,
  ): MotionTimeline | null;
  export function buildChannelPreviewKeyframes(
    channel: BuildChannelId,
    slot: SlotKind,
  ): MotionKeyframe[];
  ```

- [ ] **Step 1: Write the failing test**

Create `web/src/lib/video-editor/presets.buildChannels.test.ts`:

```ts
/** Build composes an animation from property channels instead of one canned
 *  preset. The interesting properties: every selected channel lands in the
 *  SAME window (the lanes pull them apart later), channels sharing a time
 *  merge into one keyframe, and the write is ADDITIVE — it strips only the
 *  props it writes, inside the window only. */
import { describe, expect, it } from "bun:test";
import { DEFAULT_TIMELINE, type MotionProps, type MotionTimeline } from "./timeline";
import {
  applyBuildChannels,
  buildChannelPreviewKeyframes,
  BUILD_BLINK_OPACITY,
  BUILD_CHANNEL_IDS,
  BUILD_ROTATE_DEG,
} from "./presets";

const REST: MotionProps = { x: 0.5, y: 0.5, scale: 1, rotation: 0, opacity: 1 };
const base = () => new Map([["ov1", REST]]);

const kfs = (tl: MotionTimeline) =>
  [...(tl.tracks[0]?.keyframes ?? [])].sort((a, b) => a.t_ms - b.t_ms);

describe("applyBuildChannels — entrance", () => {
  it("writes one channel across the entrance window", () => {
    const out = applyBuildChannels(
      DEFAULT_TIMELINE(),
      base(),
      "ov1",
      "in",
      ["opacity"],
      0
    );

    expect(kfs(out!).map((k) => [k.t_ms, k.props.opacity])).toEqual([
      [0, 0],
      [500, 1],
    ]);
  });

  it("merges two channels that share a time into ONE keyframe", () => {
    const out = applyBuildChannels(
      DEFAULT_TIMELINE(),
      base(),
      "ov1",
      "in",
      ["scale", "opacity"],
      0
    );

    // Both channels write at 0 and 500, so the track holds two keyframes
    // carrying two props each — not four keyframes.
    expect(kfs(out!)).toHaveLength(2);
    expect(kfs(out!)[0].props).toEqual({ scale: 0.6, opacity: 0 });
    expect(kfs(out!)[1].props).toEqual({ scale: 1, opacity: 1 });
  });

  it("slides in from the left and lands on the rest pose", () => {
    const out = applyBuildChannels(
      DEFAULT_TIMELINE(),
      base(),
      "ov1",
      "in",
      ["move"],
      0
    );

    expect(kfs(out!).map((k) => [k.t_ms, k.props.x])).toEqual([
      [0, 0.35],
      [500, 0.5],
    ]);
  });

  it("rotates in from an offset of BUILD_ROTATE_DEG", () => {
    const out = applyBuildChannels(
      DEFAULT_TIMELINE(),
      base(),
      "ov1",
      "in",
      ["rotate"],
      0
    );

    expect(kfs(out!).map((k) => [k.t_ms, k.props.rotation])).toEqual([
      [0, -BUILD_ROTATE_DEG],
      [500, 0],
    ]);
  });

  it("writes nothing for an empty channel list", () => {
    const tl = DEFAULT_TIMELINE();

    expect(applyBuildChannels(tl, base(), "ov1", "in", [], 0)).toBe(tl);
  });
});

describe("applyBuildChannels — exit", () => {
  it("mirrors the entrance at the end of the timeline", () => {
    const out = applyBuildChannels(
      DEFAULT_TIMELINE(),
      base(),
      "ov1",
      "out",
      ["opacity"],
      0
    );

    expect(kfs(out!).map((k) => [k.t_ms, k.props.opacity])).toEqual([
      [4500, 1],
      [5000, 0],
    ]);
  });
});

describe("applyBuildChannels — emphasis", () => {
  it("returns to the rest pose, using the shared emphasis window", () => {
    const out = applyBuildChannels(
      DEFAULT_TIMELINE(),
      base(),
      "ov1",
      "emphasis",
      ["scale"],
      1000
    );

    // Reuses the pulse writer: rest → 1.08× → rest across 600ms.
    expect(kfs(out!).map((k) => [k.t_ms, k.props.scale])).toEqual([
      [1000, 1],
      [1300, 1.08],
      [1600, 1],
    ]);
  });

  it("blinks opacity down and back — the one emphasis with no preset", () => {
    const out = applyBuildChannels(
      DEFAULT_TIMELINE(),
      base(),
      "ov1",
      "emphasis",
      ["opacity"],
      1000
    );

    expect(kfs(out!).map((k) => [k.t_ms, k.props.opacity])).toEqual([
      [1000, 1],
      [1300, BUILD_BLINK_OPACITY],
      [1600, 1],
    ]);
  });

  it("refuses when there is not enough room before the end", () => {
    const out = applyBuildChannels(
      DEFAULT_TIMELINE(),
      base(),
      "ov1",
      "emphasis",
      ["scale"],
      4900
    );

    expect(out).toBeNull();
  });

  it("reads the pose it starts from at atMs, not the rest pose", () => {
    // An entrance already leaves the layer at scale 1 by 500ms, and a hand
    // edit pushes it to 2 at 800ms. An emphasis at 1000 must start from 2.
    const tl: MotionTimeline = {
      ...DEFAULT_TIMELINE(),
      tracks: [
        {
          kind: "overlay",
          overlay_id: "ov1",
          keyframes: [
            { t_ms: 800, props: { scale: 2 }, easing: "out" },
          ],
        },
      ],
    };

    const out = applyBuildChannels(tl, base(), "ov1", "emphasis", ["scale"], 1000);
    const scale = kfs(out!)
      .filter((k) => k.props.scale !== undefined)
      .map((k) => [k.t_ms, k.props.scale]);

    expect(scale).toEqual([
      [800, 2],
      [1000, 2],
      [1300, 2.16],
      [1600, 2],
    ]);
  });
});

describe("applyBuildChannels — additivity", () => {
  it("strips only the props it writes, and only inside the window", () => {
    const tl: MotionTimeline = {
      ...DEFAULT_TIMELINE(),
      tracks: [
        {
          kind: "overlay",
          overlay_id: "ov1",
          keyframes: [
            // Inside the entrance window, a hand-authored rotation that Build
            // is not touching — it must survive.
            { t_ms: 200, props: { rotation: 30 }, easing: "linear" },
            // Outside the window, an opacity keyframe Build must not touch
            // even though opacity IS one of its channels.
            { t_ms: 2000, props: { opacity: 0.5 }, easing: "linear" },
          ],
        },
      ],
    };

    const out = applyBuildChannels(tl, base(), "ov1", "in", ["opacity"], 0);

    expect(kfs(out!).find((k) => k.t_ms === 200)?.props).toEqual({ rotation: 30 });
    expect(kfs(out!).find((k) => k.t_ms === 2000)?.props).toEqual({ opacity: 0.5 });
  });

  it("leaves no label, so the bar names itself by property", () => {
    const out = applyBuildChannels(
      DEFAULT_TIMELINE(),
      base(),
      "ov1",
      "in",
      ["scale", "opacity"],
      0
    );

    expect(kfs(out!).every((k) => k.label === undefined)).toBe(true);
  });
});

describe("buildChannelPreviewKeyframes", () => {
  it("gives every channel a non-empty, non-static preview", () => {
    for (const channel of BUILD_CHANNEL_IDS) {
      const kf = buildChannelPreviewKeyframes(channel, "in");
      expect(kf.length).toBeGreaterThan(1);
      // A preview whose values never change would render a still card and
      // tell the user nothing about what the channel does.
      const props = kf.flatMap((k) => Object.entries(k.props));
      const distinct = new Set(props.map(([k, v]) => `${k}:${v}`));
      expect(distinct.size).toBeGreaterThan(1);
    }
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bun test ./src/lib/video-editor/presets.buildChannels.test.ts`
Expected: FAIL — `applyBuildChannels` is not exported from `presets.ts`.

- [ ] **Step 3: Write the implementation**

Append to `web/src/lib/video-editor/presets.ts`:

```ts
/** The property channels a Build composes from. One channel writes ONE
 *  property group, which is exactly what presets cannot do: `slide-in-left`
 *  is x AND opacity, `pop-in` is scale AND opacity, and there is no way to
 *  ask a preset for "scale and rotate, nothing else".
 *
 *  Blur, Path and Resize are deliberately absent — they are not in
 *  `MotionProps`, so they would need the renderer and the exporter too. */
export type BuildChannelId = "move" | "scale" | "rotate" | "opacity";

export const BUILD_CHANNEL_IDS: BuildChannelId[] = [
  "move",
  "scale",
  "rotate",
  "opacity",
];

export const BUILD_CHANNEL_LABELS: Record<BuildChannelId, string> = {
  move: "Move",
  scale: "Scale",
  rotate: "Rotate",
  opacity: "Opacity",
};

/** Two magnitudes with no preset precedent to borrow: no entrance or exit
 *  preset rotates, and nothing blinks opacity. Expect to tune both after the
 *  first real pass — they are the only invented numbers in this feature. */
export const BUILD_ROTATE_DEG = 15;
export const BUILD_BLINK_OPACITY = 0.4;

/** An entrance channel: start offset from the rest pose, land ON it. Exit is
 *  the same pair reversed, which is why one table serves both. */
const BUILD_EDGE_WRITERS: Record<
  BuildChannelId,
  (base: MotionProps) => { from: Partial<MotionProps>; to: Partial<MotionProps> }
> = {
  move: (b) => ({ from: { x: b.x - SLIDE_OFFSET }, to: { x: b.x } }),
  scale: (b) => ({ from: { scale: POP_FROM_SCALE }, to: { scale: b.scale } }),
  rotate: (b) => ({
    from: { rotation: b.rotation - BUILD_ROTATE_DEG },
    to: { rotation: b.rotation },
  }),
  opacity: (b) => ({ from: { opacity: 0 }, to: { opacity: b.opacity } }),
};

/** Emphasis channels return to where they started. Three of the four ARE an
 *  existing emphasis preset's writer — reused rather than re-derived, so a
 *  Build emphasis and the equivalent preset cannot drift. Opacity has no
 *  preset, so it gets the blink defined here. */
function buildEmphasisKeyframes(
  channel: BuildChannelId,
  pose: MotionProps,
  t: (frac: number) => number,
): MotionKeyframe[] {
  if (channel === "move") return EMPHASIS_WRITERS.shake(pose, t);
  if (channel === "scale") return EMPHASIS_WRITERS.pulse(pose, t);
  if (channel === "rotate") return EMPHASIS_WRITERS.spin(pose, t);
  return [
    { t_ms: t(0), props: { opacity: pose.opacity }, easing: "out" },
    {
      t_ms: t(0.5),
      props: { opacity: pose.opacity * BUILD_BLINK_OPACITY },
      easing: "out",
    },
    { t_ms: t(1), props: { opacity: pose.opacity }, easing: "in-out" },
  ];
}

/** Write the selected channels into the slot's window as plain keyframes.
 *
 *  Every channel lands in the SAME window on purpose: Build's job is to say
 *  WHICH properties animate, and the per-property lanes
 *  (`shiftPropGroupKeyframes` in blocks.ts) are how their timings are pulled
 *  apart afterwards. Encoding per-channel timing here would duplicate that.
 *
 *  Windows match what a preset from the same chip would use — entrance at the
 *  start, exit at the end, emphasis at the playhead — so there is no second
 *  timing rule to learn. `null` when an emphasis has no room, the same
 *  refusal `applyEmphasisPreset` gives, so the caller's existing toast covers
 *  it. Returns `timeline` unchanged for an empty channel list.
 *
 *  ADDITIVE, exactly like `applyEmphasisPreset`: only the props being written
 *  are stripped, and only inside the window, so hand-authored keyframes on
 *  other properties (or on these properties elsewhere in the clip) survive.
 *
 *  No `label` is stamped. A Build has no preset name to claim, and the bar
 *  falling back to its property list (`position · scale`) says more than
 *  "Build" would. */
export function applyBuildChannels(
  timeline: MotionTimeline,
  base: Map<string, MotionProps>,
  overlayId: string,
  slot: SlotKind,
  channels: BuildChannelId[],
  atMs: number,
): MotionTimeline | null {
  if (channels.length === 0) return timeline;

  let startMs: number;
  let endMs: number;
  if (slot === "in") {
    startMs = 0;
    endMs = ENTRANCE_MS;
  } else if (slot === "out") {
    startMs = Math.max(0, timeline.duration_ms - ENTRANCE_MS);
    endMs = timeline.duration_ms;
  } else {
    const room = timeline.duration_ms - atMs;
    if (room < EMPHASIS_MIN_WINDOW_MS) return null;
    startMs = atMs;
    endMs = atMs + Math.min(EMPHASIS_WINDOW_MS, room);
  }

  // Emphasis reads the pose the layer is ACTUALLY in at that moment (an
  // entrance may already have moved it); the edges read the rest pose, which
  // is what they animate to or from.
  const pose =
    slot === "emphasis"
      ? sampleTimelineAt(timeline, base, atMs).get(overlayId)
      : base.get(overlayId);
  if (!pose) return null;

  const written: MotionKeyframe[] = [];
  for (const channel of channels) {
    if (slot === "emphasis") {
      const t = (frac: number) =>
        Math.round(startMs + frac * (endMs - startMs));
      written.push(...buildEmphasisKeyframes(channel, pose, t));
      continue;
    }
    const { from, to } = BUILD_EDGE_WRITERS[channel](pose);
    const [first, second] = slot === "in" ? [from, to] : [to, from];
    written.push(
      { t_ms: startMs, props: first, easing: "linear" },
      { t_ms: endMs, props: second, easing: "out" },
    );
  }

  const touched = Array.from(
    new Set(written.flatMap((k) => Object.keys(k.props))),
  ) as (keyof MotionProps)[];

  const tracks = timeline.tracks.map((tr) => ({
    ...tr,
    keyframes: tr.keyframes.map((k) => ({ ...k, props: { ...k.props } })),
  }));
  let track = tracks.find(
    (tr) => tr.kind === "overlay" && tr.overlay_id === overlayId,
  );
  if (!track) {
    track = { kind: "overlay", overlay_id: overlayId, keyframes: [] };
    tracks.push(track);
  }
  for (const k of track.keyframes) {
    if (k.t_ms < startMs || k.t_ms > endMs) continue;
    for (const p of touched) delete k.props[p];
  }
  track.keyframes = track.keyframes.filter(
    (k) => Object.keys(k.props).length > 0,
  );
  for (const w of written) {
    const existing = track.keyframes.find((k) => k.t_ms === w.t_ms);
    if (existing) existing.props = { ...existing.props, ...w.props };
    else track.keyframes.push({ ...w });
  }
  return { ...timeline, tracks };
}

/** One channel's default motion, as keyframes a preview card can loop. Built
 *  against `PREVIEW_REST`-style neutral values rather than a real layer's
 *  pose, because the card shows a MOTION, not a layout — same reasoning as
 *  `previewKeyframes` for presets. */
export function buildChannelPreviewKeyframes(
  channel: BuildChannelId,
  slot: SlotKind,
): MotionKeyframe[] {
  const neutral: MotionProps = { x: 0.5, y: 0.5, scale: 1, rotation: 0, opacity: 1 };
  const previewTimeline: MotionTimeline = {
    ...DEFAULT_TIMELINE(),
    tracks: [],
  };
  const out = applyBuildChannels(
    previewTimeline,
    new Map([["preview", neutral]]),
    "preview",
    slot,
    [channel],
    0,
  );
  const written = out?.tracks[0]?.keyframes ?? [];
  const first = Math.min(...written.map((k) => k.t_ms));
  return written
    .map((k) => ({ ...k, t_ms: k.t_ms - first }))
    .sort((a, b) => a.t_ms - b.t_ms);
}
```

Add `DEFAULT_TIMELINE` to the existing `./timeline` import at the top of `presets.ts` if it is not already imported.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bun test ./src/lib/video-editor/presets.buildChannels.test.ts`
Expected: PASS, 13 tests. If the emphasis-pose test's expected `2.16` is off, read `EMPHASIS_WRITERS.pulse` and use ITS multiplier rather than editing the writer.

- [ ] **Step 5: Run the module for regressions**

Run: `bun test ./src/lib/video-editor`
Expected: PASS — baseline is 280 before this task.

- [ ] **Step 6: Commit**

```bash
git add src/lib/video-editor/presets.ts src/lib/video-editor/presets.buildChannels.test.ts
git commit -m "feat(video-editor): compose keyframes from property channels"
```

---

### Task 2: The Build tab in the slot menu

**Files:**
- Modify: `web/src/components/video-editor/MotionSourceTabs.tsx`
- Modify: `web/src/components/video-editor/BlockTrackRow.tsx` (`SlotPlaceholder`)
- Modify: `web/src/components/video-editor/types.ts`
- Modify: `web/src/components/video-editor/TimelineDock.tsx`
- Test: `web/src/components/video-editor/TimelineDock.buildtab.test.tsx`

**Interfaces:**
- Consumes: `MotionPresetGrid`, `MotionPresetOption` (unchanged — see the deviation note), `SlotKind`
- Produces:
  ```ts
  // MotionSourceTabs.tsx
  export type PresetTab = "default" | "build" | "saved";
  // MotionSourceTabRow gains: tabs?: PresetTab[]  (default ["default", "saved"])

  // TimelineDockProps → BlockTrackRowProps → SlotPlaceholder
  buildChannels?: MotionPresetOption[];
  onApplyBuild?: (
    trackId: string, kind: SlotKind, channelIds: string[], atMs: number,
  ) => void;
  ```

**Deviation from the spec, deliberate:** the spec asked for a multi-select mode on `MotionPresetGrid`. It does not need one — the grid already takes `active` per option and reports picks through `onPick`, so the Build panel passes `active: selected.has(id)` and treats a pick as a toggle. No change to a component three other surfaces share.

- [ ] **Step 1: Write the failing test**

Create `web/src/components/video-editor/TimelineDock.buildtab.test.tsx`:

```tsx
/** The Build tab: pick which property channels animate, then write them all
 *  in one action. Offered ONLY on the empty-slot chips, because a channel
 *  needs a time window and the chip is the one surface where the window is
 *  explicit. `screen` is broken under bun here — use within(document.body). */
import { describe, expect, it, mock } from "bun:test";
import { fireEvent, render, within } from "@testing-library/react";
import { DEFAULT_TIMELINE } from "@/lib/video-editor/timeline";
import { TimelineDock } from "./TimelineDock";

const body = () => within(document.body);

const TRACKS = [{ id: "ov1", name: "Headline", icon: "text" as const }];

/** One entrance block, so the Emphasis and Out slots are empty and render
 *  their chips. */
const tl = () => ({
  ...DEFAULT_TIMELINE(),
  tracks: [
    {
      kind: "overlay" as const,
      overlay_id: "ov1",
      keyframes: [
        { t_ms: 0, props: { opacity: 0 }, easing: "linear" as const },
        { t_ms: 500, props: { opacity: 1 }, easing: "out" as const },
      ],
    },
  ],
});

const CHANNELS = [
  {
    id: "move",
    label: "Move",
    keyframes: [
      { t_ms: 0, props: { x: 0.35 }, easing: "linear" as const },
      { t_ms: 500, props: { x: 0.5 }, easing: "out" as const },
    ],
    spanMs: 500,
  },
  {
    id: "scale",
    label: "Scale",
    keyframes: [
      { t_ms: 0, props: { scale: 0.6 }, easing: "linear" as const },
      { t_ms: 500, props: { scale: 1 }, easing: "out" as const },
    ],
    spanMs: 500,
  },
];

function baseHandlers() {
  return {
    onSeek: mock(), onTogglePlay: mock(), onSelectKeyframe: mock(),
    onMoveKeyframe: mock(), onDeleteKeyframe: mock(), onInsertKeyframe: mock(),
    onDurationChange: mock(), onToggleLoop: mock(), onViewChange: mock(),
    onShiftSegment: mock(), onStretchSegment: mock(), onStretchTrack: mock(),
    onSelectTrack: mock(), onPreviewRangeChange: mock(), onDeleteSegment: mock(),
    onReplaceSegment: mock(), onApplySlotPreset: mock(),
    onToggleTrackLocked: mock(), onToggleTrackHidden: mock(), onZoomChange: mock(),
    onApplyBuild: mock(),
  };
}

function renderDock(overrides: Record<string, unknown> = {}) {
  const handlers = baseHandlers();
  render(
    <TimelineDock
      tracks={TRACKS}
      timeline={tl()}
      playheadMs={1000}
      playing={false}
      selectedKeyframe={null}
      loop={false}
      view="slots"
      previewRange={null}
      buildChannels={CHANNELS}
      {...handlers}
      {...overrides}
    />
  );
  return handlers;
}

describe("Build tab", () => {
  it("writes every selected channel in one commit, with the slot and playhead", () => {
    const h = renderDock();

    fireEvent.click(body().getByTestId("slot-placeholder-ov1-emphasis"));
    fireEvent.click(body().getByTestId("slot-emphasis-tab-build"));

    // Nothing selected yet, so there is nothing to add.
    expect(body().getByTestId("slot-emphasis-build-add")).toBeDisabled();

    fireEvent.click(body().getByTestId("slot-emphasis-build-move"));
    fireEvent.click(body().getByTestId("slot-emphasis-build-scale"));
    fireEvent.click(body().getByTestId("slot-emphasis-build-add"));

    expect(h.onApplyBuild).toHaveBeenCalledTimes(1);
    expect(h.onApplyBuild).toHaveBeenCalledWith(
      "ov1",
      "emphasis",
      ["move", "scale"],
      1000
    );
    // Building is not applying a preset.
    expect(h.onApplySlotPreset).not.toHaveBeenCalled();
  });

  it("toggles a channel back off", () => {
    const h = renderDock();

    fireEvent.click(body().getByTestId("slot-placeholder-ov1-out"));
    fireEvent.click(body().getByTestId("slot-out-tab-build"));
    fireEvent.click(body().getByTestId("slot-out-build-move"));
    fireEvent.click(body().getByTestId("slot-out-build-scale"));
    fireEvent.click(body().getByTestId("slot-out-build-move"));
    fireEvent.click(body().getByTestId("slot-out-build-add"));

    expect(h.onApplyBuild).toHaveBeenCalledWith("ov1", "out", ["scale"], 1000);
  });

  it("names its button after the slot it will write into", () => {
    renderDock();

    fireEvent.click(body().getByTestId("slot-placeholder-ov1-out"));
    fireEvent.click(body().getByTestId("slot-out-tab-build"));

    expect(body().getByTestId("slot-out-build-add")).toHaveTextContent(/out/i);
  });

  it("forgets the selection when the menu closes", () => {
    renderDock();

    fireEvent.click(body().getByTestId("slot-placeholder-ov1-emphasis"));
    fireEvent.click(body().getByTestId("slot-emphasis-tab-build"));
    fireEvent.click(body().getByTestId("slot-emphasis-build-move"));
    fireEvent.keyDown(document.body, { key: "Escape" });

    fireEvent.click(body().getByTestId("slot-placeholder-ov1-emphasis"));
    // Reopening lands on Default, and Build starts empty rather than carrying
    // a selection the user made for a menu they dismissed.
    fireEvent.click(body().getByTestId("slot-emphasis-tab-build"));
    expect(body().getByTestId("slot-emphasis-build-add")).toBeDisabled();
  });

  it("offers no Build tab where the host provides no channels", () => {
    renderDock({ buildChannels: undefined });

    fireEvent.click(body().getByTestId("slot-placeholder-ov1-emphasis"));

    expect(body().queryByTestId("slot-emphasis-tab-build")).toBeNull();
    // The other tabs are unaffected.
    expect(body().getByTestId("slot-emphasis-tab-default")).toBeInTheDocument();
  });

  it("keeps Build off the segment right-click menu, which has no window", () => {
    renderDock();

    fireEvent.contextMenu(body().getByTestId("block-bar-ov1-0"));

    expect(body().queryByTestId("segment-context-tab-build")).toBeNull();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bun test ./src/components/video-editor/TimelineDock.buildtab.test.tsx`
Expected: FAIL — `slot-emphasis-tab-build` not found.

- [ ] **Step 3: Widen the tab row**

In `MotionSourceTabs.tsx`:

```ts
export type PresetTab = "default" | "build" | "saved";

const TAB_LABELS: Record<PresetTab, string> = {
  default: "Default",
  build: "Build",
  saved: "Saved",
};

/** Which tabs this surface offers, in order. Build is opt-in per surface, not
 *  global: a channel needs a time window to be written into, and only the
 *  empty-slot chips have one. The layer rail's ✨ and a segment's right-click
 *  menu leave it out. */
const DEFAULT_TABS: PresetTab[] = ["default", "saved"];
```

`MotionSourceTabRow` gains `tabs = DEFAULT_TABS` as a prop and maps over it, reading its label from `TAB_LABELS`.

- [ ] **Step 4: Render the Build panel in `SlotPlaceholder`**

In `BlockTrackRow.tsx`, inside `SlotPlaceholder`:

```tsx
  const [buildSelection, setBuildSelection] = useState<ReadonlySet<string>>(
    () => new Set()
  );
```

Reset it wherever `setTab("default")` already runs on close, so a dismissed menu does not keep a selection the user made for it.

Pass the tab list to the row, and render the panel:

```tsx
            <MotionSourceTabRow
              tab={tab}
              onChange={setTab}
              testIdPrefix={`slot-${kind}`}
              tabs={
                buildChannels === undefined
                  ? ["default", "saved"]
                  : ["default", "build", "saved"]
              }
            />
```

```tsx
            {tab === "build" && buildChannels !== undefined && (
              <div
                role="tabpanel"
                id={`slot-${kind}-tabpanel-build`}
                aria-labelledby={`slot-${kind}-tab-build`}
              >
                <p className="px-2 pb-1 text-textXsMedium text-text-inverse-subtlest">
                  Pick what animates. They start together — pull them apart in
                  the layer&apos;s property lanes.
                </p>
                {/* The grid already models a per-card `active` flag and reports
                 *  picks through `onPick`; a Build pick is a TOGGLE rather than
                 *  an apply, which is entirely the caller's reading of it. No
                 *  multi-select mode was needed in a component three other
                 *  surfaces share. */}
                <MotionPresetGrid
                  ariaLabel={`Build ${SLOT_LABELS[kind]} motion`}
                  testIdPrefix={`slot-${kind}-build`}
                  options={buildChannels.map((c) => ({
                    ...c,
                    active: buildSelection.has(c.id),
                  }))}
                  onPick={(id) =>
                    setBuildSelection((prev) => {
                      const next = new Set(prev);
                      if (next.has(id)) next.delete(id);
                      else next.add(id);
                      return next;
                    })
                  }
                />
                <button
                  type="button"
                  data-testid={`slot-${kind}-build-add`}
                  disabled={buildSelection.size === 0}
                  onClick={() => {
                    // Order follows the host's channel list, not click order:
                    // two users picking the same pair should produce the same
                    // document.
                    const ids = buildChannels
                      .map((c) => c.id)
                      .filter((id) => buildSelection.has(id));
                    onApplyBuild?.(ids, resolveAtMs());
                    setOpen(false);
                    setTab("default");
                    setBuildSelection(new Set());
                  }}
                  className={cn(
                    "mt-1 flex w-full items-center justify-center gap-1.5 rounded-lg border border-white/20 bg-white/[0.08] p-2 text-textXsMedium text-text-inverse outline-none transition-all duration-200 ease-out hover:bg-white/[0.14] focus-visible:ring-2 focus-visible:ring-white/40",
                    buildSelection.size === 0 &&
                      "cursor-not-allowed opacity-50 hover:bg-white/[0.08]"
                  )}
                >
                  Add to {SLOT_LABELS[kind]}
                </button>
              </div>
            )}
```

`SlotPlaceholderProps` gains `buildChannels?: MotionPresetOption[]` and `onApplyBuild?: (channelIds: string[], atMs: number) => void`; `BlockTrackRow` binds the track id and slot kind when it renders the placeholder, exactly as it already does for `onApplySavedMotion`.

- [ ] **Step 5: Plumb the dock**

In `types.ts`, after `savedMotions`:

```ts
  /** The property channels a Build offers, as ready-built preview cards —
   *  the host owns what a "channel" means and what its default motion looks
   *  like. Omit and no Build tab is rendered anywhere.
   *
   *  Offered on the empty-slot chips only: a channel needs a time window to
   *  be written into, and the chip is the one surface where that window is
   *  explicit. */
  buildChannels?: MotionPresetOption[];
  /** Write `channelIds` into `kind`'s window on `trackId`. `atMs` is the
   *  playhead, consulted for "emphasis" only — the same contract
   *  `onApplySlotPreset` has. */
  onApplyBuild?: (
    trackId: string,
    kind: SlotKind,
    channelIds: string[],
    atMs: number,
  ) => void;
```

Destructure both in `TimelineDock` and forward them to `BlockTrackRow`.

- [ ] **Step 6: Run the tests**

Run: `bun test ./src/components/video-editor/TimelineDock.buildtab.test.tsx`
Expected: PASS, 6 tests.

Run: `bun test ./src/components/video-editor ./src/components/studio/kv-generator/motion`
Expected: PASS. Baseline before this task is 377. `TimelineDock.savedmotions.test.tsx` and `TimelineDock.test.tsx` both assert on the slot menu — if either goes red, the tab list changed a surface that should not have gained Build, and the fix is the `tabs` prop, never those files.

- [ ] **Step 7: Commit**

```bash
git add src/components/video-editor/MotionSourceTabs.tsx src/components/video-editor/BlockTrackRow.tsx src/components/video-editor/types.ts src/components/video-editor/TimelineDock.tsx src/components/video-editor/TimelineDock.buildtab.test.tsx
git commit -m "feat(video-editor): a Build tab on the empty-slot chips"
```

---

### Task 3: Editor state, KV wiring and analytics

**Files:**
- Modify: `web/src/components/studio/kv-generator/motion/useMotionEditorState.ts`
- Modify: `web/src/components/studio/kv-generator/motion/KvMotionEditor.tsx`
- Modify: `web/src/lib/analytics/kv-generator-events.ts`
- Test: `web/src/components/studio/kv-generator/motion/useMotionEditorState.build.test.ts`

**Interfaces:**
- Consumes: `applyBuildChannels`, `BUILD_CHANNEL_IDS`, `BUILD_CHANNEL_LABELS`, `buildChannelPreviewKeyframes` (Task 1); the dock props from Task 2
- Produces: `state.applyBuild(trackId, kind, channelIds, atMs): boolean` — `false` when an emphasis has no room, so the caller can toast; `trackKvMotionBuildApplied`

- [ ] **Step 1: Write the failing test**

Create `web/src/components/studio/kv-generator/motion/useMotionEditorState.build.test.ts`. Read `useMotionEditorState.propGroup.test.ts` first and copy its harness verbatim (the `qcWrapper` + `renderHook` + `makeProject()` idiom); write these cases in that idiom:

```ts
it("pushes one undo step for the whole composition", () => {
  // act:  result.current.applyBuild("ov1", "in", ["scale", "opacity"], 0)
  // assert: returns true; scale AND opacity keyframes exist at 0 and 500;
  //         canUndo flips false -> true; ONE undo restores the exact prior
  //         timeline object (toBe, not toEqual).
});

it("refuses an emphasis with no room and pushes nothing", () => {
  // arrange: playhead at duration - 100
  // act:  applyBuild("ov1", "emphasis", ["scale"], 4900)
  // assert: returns false; canUndo unchanged; timeline is the same object
  //         (toBe) — a refusal must not cost an undo step.
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bun test ./src/components/studio/kv-generator/motion/useMotionEditorState.build.test.ts`
Expected: FAIL — `applyBuild` is not a function.

- [ ] **Step 3: Add the command**

In `useMotionEditorState.ts`, beside `applySlotPreset`:

```ts
  // Mirrors `applySlotPreset`'s boolean contract: `false` means the writer
  // refused (an emphasis with no room), which the caller surfaces as the same
  // toast it already shows for a refused emphasis preset. One undo step for
  // the whole composition — the user made one decision, not four.
  const applyBuild = useCallback(
    (
      trackId: string,
      kind: SlotKind,
      channelIds: string[],
      atMs: number,
    ): boolean => {
      const next = applyBuildChannels(
        timeline,
        base,
        trackId,
        kind,
        channelIds as BuildChannelId[],
        atMs,
      );
      if (!next || next === timeline) return false;
      push(next);
      return true;
    },
    [timeline, base, push],
  );
```

Export it from the hook's return object.

- [ ] **Step 4: Wire the editor**

In `KvMotionEditor.tsx`:

```tsx
  // Built once per render of the editor, not per slot chip: every chip offers
  // the same four channels, and the cards are pure previews.
  const buildChannels = useMemo(
    () =>
      BUILD_CHANNEL_IDS.map((id) => {
        const keyframes = buildChannelPreviewKeyframes(id, "in");
        return {
          id,
          label: BUILD_CHANNEL_LABELS[id],
          keyframes,
          spanMs: Math.max(1, ...keyframes.map((k) => k.t_ms)),
        };
      }),
    []
  );
```

On `<TimelineDock>`:

```tsx
          buildChannels={buildChannels}
          onApplyBuild={(trackId, kind, channelIds, atMs) => {
            if (!state.applyBuild(trackId, kind, channelIds, atMs)) {
              showToast(
                "Not enough room for that",
                "Move the playhead earlier and try again.",
                "error"
              );
              return;
            }
            trackKvMotionBuildApplied({
              project_id: projectId,
              slot: kind,
              channels: channelIds,
            });
          }}
```

- [ ] **Step 5: Add the event**

In `kv-generator-events.ts`, beside the other motion events:

```ts
/** A Build's composition, not just that one happened. WHICH channels people
 *  combine is the question that decides whether the tab earns its place: if
 *  the answer is overwhelmingly single-channel, Build is a slower way to pick
 *  a preset and should be reconsidered rather than extended. */
export const trackKvMotionBuildApplied = (p: {
  project_id: string;
  slot: "in" | "emphasis" | "out";
  channels: string[];
}) => safeCapture("kv_generator.motion_build_applied", p);
```

- [ ] **Step 6: Run the tests, lint and typecheck**

Run: `bun test ./src/components/video-editor ./src/components/studio/kv-generator/motion`
Expected: PASS, 377 + this plan's new tests.

Run: `bunx eslint` on every file you touched, and `bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -E "presets|MotionSourceTabs|BlockTrackRow|TimelineDock|useMotionEditorState|KvMotionEditor"`
Expected: no new errors naming your files.

- [ ] **Step 7: Manual verification**

Services running (`./run-all.sh --status`, web on :3000). In a motion project:

1. On a layer with an empty Emphasis slot, click `+ Emphasis` → the menu shows `Default | Build | Saved`.
2. Build tab → four cards, each animating its own channel. Pick Scale and Rotate → "Add to Emphasis" enables.
3. Click it → both channels appear, and the block's bar reads `scale · rotation` (no preset name, because Build stamps none).
4. Expand the row → two lanes. **Drag Scale's lane later** — this is the payoff: Build said what animates, the lanes say when.
5. Cmd+Z → the whole composition disappears in ONE undo.
6. Park the playhead ~100ms before the end, `+ Emphasis` → Build → Add → the "Not enough room" toast, and nothing is written.
7. The ✨ menu and a segment's right-click menu still show only `Default | Saved`.

- [ ] **Step 8: Commit**

```bash
git add src/components/studio/kv-generator/motion/useMotionEditorState.ts src/components/studio/kv-generator/motion/KvMotionEditor.tsx src/lib/analytics/kv-generator-events.ts src/components/studio/kv-generator/motion/useMotionEditorState.build.test.ts
git commit -m "feat(kv-motion): wire the Build tab to the editor"
```

---

## Self-Review Notes

- **Spec coverage:** channel writers + windows + additivity + no-label → Task 1; the tab, the cards, the button, the per-surface gating → Task 2; the state command, the KV wiring, the analytics event → Task 3. The spec's testing table maps onto `presets.buildChannels.test.ts` and `TimelineDock.buildtab.test.tsx`.
- **Deviation from the spec (1):** no multi-select mode is added to `MotionPresetGrid`. It already carries `active` per option and reports picks through `onPick`, so the Build panel reads a pick as a toggle. Touching a component three other surfaces share, to add a mode only one needs, is the kind of change this codebase has paid for before.
- **Deviation from the spec (2):** `PresetTab` gains `"build"` for every surface, but the tab is offered per surface through a new `tabs` prop defaulting to `["default", "saved"]`. The spec implied the slot menu would simply render a third tab; without the opt-in list, the ✨ and segment menus would grow a Build tab they cannot honour.
- **Addition the spec did not name:** `buildChannelPreviewKeyframes`, because the spec's UI section assumes preview cards but nothing existed to generate their keyframes.
- **Channel-order determinism:** the committed `channelIds` follow the host's channel list rather than click order, so the same pair of picks always writes the same document.
- **Not covered here:** Blur, Path and Resize channels (they need new props in `MotionProps`, the renderer and the exporter); parameter fields (direction, distance, duration); and Build on an occupied slot, which cannot arise because chips render only for empty slots.
