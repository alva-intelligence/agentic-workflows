# KV Motion Emphasis Presets — Web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Four mid-timeline emphasis presets (pulse/shake/spin/bounce) applied at the playhead via an additive, window-scoped keyframe writer — never destroying entrance/exit keyframes.

**Architecture:** One new pure function in the existing `lib/motion/presets.ts` engine module + an "Emphasis" group in the existing per-layer preset popover menu. No data-model, api, or renderer changes — emphasis output is ordinary sparse keyframes.

**Tech Stack:** TypeScript, `bun test`.

**Spec:** `docs/superpowers/specs/2026-08-02-kv-motion-emphasis-presets-design.md`

## Global Constraints

- Branch: continue on `feature/daffa/vc-kv-motion-timeline-editor` in `web/`.
- `lib/motion` stays KV-import-free (boundary test).
- Test runner `bun test`; build gate `bun run build`; `bunx tsc --noEmit` no NEW errors.
- `EMPHASIS_WINDOW_MS = 600`; minimum compressed window 200ms; whole-ms rounding; immutable writers.
- Commit format `feat(web): …`.

---

### Task 1: `applyEmphasisPreset` engine writer

**Files:**
- Modify: `web/src/lib/motion/presets.ts`
- Test: `web/src/lib/motion/presets.test.ts` (append)

**Interfaces:**
- Consumes: `sampleTimelineAt` from `./sample`, types from `./timeline`.
- Produces:

```ts
export type EmphasisPresetId = "pulse" | "shake" | "spin" | "bounce";
export const EMPHASIS_PRESET_IDS: EmphasisPresetId[];
export const EMPHASIS_WINDOW_MS = 600;
/** Returns null (rejection) when duration_ms - atMs < 200. */
export function applyEmphasisPreset(
  timeline: MotionTimeline,
  base: Map<string, MotionProps>,
  overlayId: string,
  preset: EmphasisPresetId,
  atMs: number,
): MotionTimeline | null;
```

- [ ] **Step 1: Append failing tests** (same fixture style as the file's existing tests — `baseN`/`tl` helpers):

```ts
describe("applyEmphasisPreset", () => {
  it("pulse writes scale keyframes anchored on the SAMPLED value", () => {
    // track already sliding: x 0→0.5 over 0..1000; scale untouched (sampled scale = 1)
    const withSlide = writeAutoKeyframes(empty(), base(), "ov1", 1000, { x: 0.5 });
    const out = applyEmphasisPreset(withSlide, base(), "ov1", "pulse", 2000)!;
    const kfs = out.tracks[0].keyframes.filter((k) => k.props.scale !== undefined);
    const ts = kfs.map((k) => k.t_ms).sort((a, b) => a - b);
    expect(ts).toEqual([2000, 2300, 2600]);
    expect(kfs.find((k) => k.t_ms === 2300)!.props.scale).toBeCloseTo(1.08);
    expect(kfs.find((k) => k.t_ms === 2600)!.props.scale).toBeCloseTo(1);
  });

  it("does NOT touch keyframes outside the window (entrance survives)", () => {
    const withSlide = writeAutoKeyframes(empty(), base(), "ov1", 800, { x: 0.5 });
    const before = structuredClone(withSlide);
    const out = applyEmphasisPreset(withSlide, base(), "ov1", "pulse", 2000)!;
    const xKfs = out.tracks[0].keyframes.filter((k) => k.props.x !== undefined);
    expect(xKfs).toEqual(before.tracks[0].keyframes.filter((k) => k.props.x !== undefined));
  });

  it("re-apply at the same spot is deterministic (no duplicates)", () => {
    const once = applyEmphasisPreset(empty(), base(), "ov1", "pulse", 1000)!;
    const twice = applyEmphasisPreset(once, base(), "ov1", "pulse", 1000)!;
    expect(twice.tracks[0].keyframes.length).toBe(once.tracks[0].keyframes.length);
  });

  it("only strips the touched props inside the window", () => {
    // hand-authored opacity kf INSIDE the window must survive a pulse (scale-only)
    const withOpacity = writeAutoKeyframes(empty(), base(), "ov1", 1200, { opacity: 0.5 });
    const out = applyEmphasisPreset(withOpacity, base(), "ov1", "pulse", 1000)!;
    expect(out.tracks[0].keyframes.some((k) => k.t_ms === 1200 && k.props.opacity === 0.5)).toBe(true);
  });

  it("compresses the window at the end of the timeline", () => {
    // duration 5000, apply at 4700 → 300ms of room → offsets scaled by 0.5
    const out = applyEmphasisPreset(empty(), base(), "ov1", "pulse", 4700)!;
    const ts = out.tracks[0].keyframes.map((k) => k.t_ms).sort((a, b) => a - b);
    expect(ts).toEqual([4700, 4850, 5000]);
  });

  it("rejects with null when less than 200ms of room", () => {
    expect(applyEmphasisPreset(empty(), base(), "ov1", "pulse", 4900)).toBeNull();
  });

  it("spin adds a full rotation ending back-relative (+360)", () => {
    const out = applyEmphasisPreset(empty(), base(), "ov1", "spin", 0)!;
    const rot = out.tracks[0].keyframes.filter((k) => k.props.rotation !== undefined);
    expect(rot.find((k) => k.t_ms === 600)!.props.rotation).toBeCloseTo(360);
  });

  it("shake writes 4 alternating x swings and restores the sampled x", () => {
    const out = applyEmphasisPreset(empty(), base(), "ov1", "shake", 0)!;
    const xs = out.tracks[0].keyframes.filter((k) => k.props.x !== undefined).sort((a, b) => a.t_ms - b.t_ms);
    expect(xs.length).toBe(6); // anchor + 4 swings + restore
    expect(xs[0].props.x).toBeCloseTo(0.1); // base fixture x
    expect(xs[1].props.x).toBeCloseTo(0.1 + 0.008);
    expect(xs[2].props.x).toBeCloseTo(0.1 - 0.008);
    expect(xs.at(-1)!.props.x).toBeCloseTo(0.1);
  });

  it("does not mutate the input", () => {
    const input = empty();
    applyEmphasisPreset(input, base(), "ov1", "pulse", 1000);
    expect(input.tracks).toHaveLength(0);
  });
});
```

- [ ] **Step 2: Run to verify failure** — `bun test src/lib/motion/presets.test.ts` → new describe FAILS, existing tests PASS.

- [ ] **Step 3: Implement.** Writer table keyed by preset returning `(sampled: MotionProps, offsets: number[]) => MotionKeyframe[]` where offsets are the window-relative times `[0 … EMPHASIS_WINDOW_MS]` pre-scaled by the compression factor:

```ts
const EMPHASIS_MIN_WINDOW_MS = 200;

const EMPHASIS_WRITERS: Record<
  EmphasisPresetId,
  (s: MotionProps, t: (frac: number) => number) => MotionKeyframe[]
> = {
  pulse: (s, t) => [
    { t_ms: t(0), props: { scale: s.scale }, easing: "out" },
    { t_ms: t(0.5), props: { scale: s.scale * 1.08 }, easing: "out" },
    { t_ms: t(1), props: { scale: s.scale }, easing: "in-out" },
  ],
  spin: (s, t) => [
    { t_ms: t(0), props: { rotation: s.rotation }, easing: "linear" },
    { t_ms: t(1), props: { rotation: s.rotation + 360 }, easing: "in-out" },
  ],
  shake: (s, t) => [
    { t_ms: t(0), props: { x: s.x }, easing: "linear" },
    { t_ms: t(0.2), props: { x: s.x + 0.008 }, easing: "linear" },
    { t_ms: t(0.4), props: { x: s.x - 0.008 }, easing: "linear" },
    { t_ms: t(0.6), props: { x: s.x + 0.008 }, easing: "linear" },
    { t_ms: t(0.8), props: { x: s.x - 0.008 }, easing: "linear" },
    { t_ms: t(1), props: { x: s.x }, easing: "out" },
  ],
  bounce: (s, t) => [
    { t_ms: t(0), props: { y: s.y }, easing: "in" },
    { t_ms: t(1 / 3), props: { y: s.y + 0.02 }, easing: "in" },
    { t_ms: t(2 / 3), props: { y: s.y - 0.012 }, easing: "out" },
    { t_ms: t(1), props: { y: s.y }, easing: "out" },
  ],
};

export function applyEmphasisPreset(
  timeline: MotionTimeline,
  base: Map<string, MotionProps>,
  overlayId: string,
  preset: EmphasisPresetId,
  atMs: number,
): MotionTimeline | null {
  const room = timeline.duration_ms - atMs;
  if (room < EMPHASIS_MIN_WINDOW_MS) return null;
  const windowMs = Math.min(EMPHASIS_WINDOW_MS, room);
  const t = (frac: number) => Math.round(atMs + frac * windowMs);

  const sampled = sampleTimelineAt(timeline, base, atMs).get(overlayId);
  if (!sampled) return null;

  const written = EMPHASIS_WRITERS[preset](sampled, t);
  const touched = new Set(written.flatMap((k) => Object.keys(k.props)));
  const endMs = atMs + windowMs;

  // Deep-copy, strip touched props inside [atMs, endMs], insert, prune empties.
  const tracks = timeline.tracks.map((tr) => ({ ...tr, keyframes: tr.keyframes.map((k) => ({ ...k, props: { ...k.props } })) }));
  let track = tracks.find((tr) => tr.kind === "overlay" && tr.overlay_id === overlayId);
  if (!track) {
    track = { kind: "overlay", overlay_id: overlayId, keyframes: [] };
    tracks.push(track);
  }
  for (const k of track.keyframes) {
    if (k.t_ms < atMs || k.t_ms > endMs) continue;
    for (const p of touched) delete (k.props as Record<string, unknown>)[p];
  }
  track.keyframes = track.keyframes.filter((k) => Object.keys(k.props).length > 0);
  for (const w of written) {
    const existing = track.keyframes.find((k) => k.t_ms === w.t_ms);
    if (existing) existing.props = { ...existing.props, ...w.props };
    else track.keyframes.push(w);
  }
  return { ...timeline, tracks };
}
```

- [ ] **Step 4: Run to verify pass** — `bun test src/lib/motion/presets.test.ts` (all, old + new) and `bun test src/lib/motion/` (boundary incl.).

- [ ] **Step 5: Commit** — `feat(web): additive window-scoped emphasis preset writer`

---

### Task 2: Emphasis group in the per-layer preset menu

**Files:**
- Modify: `web/src/components/studio/kv-generator/motion/KvMotionEditor.tsx` (TrackPresetMenu + handler)
- Modify: `web/src/components/studio/kv-generator/motion/useMotionEditorState.ts` (handler)
- Test: `web/src/components/studio/kv-generator/motion/useMotionEditorState.test.ts` (append)

**Interfaces:**
- Consumes: `applyEmphasisPreset`, `EMPHASIS_PRESET_IDS`, `EMPHASIS_WINDOW_MS` (Task 1).
- Produces: `useMotionEditorState` gains `applyEmphasis(overlayId: string, preset: EmphasisPresetId): boolean` — returns false on rejection (null from the writer); on success `push(next)` (no label, one undo step).

- [ ] **Step 1: Append failing hook tests** — `applyEmphasis` at playhead 2000 adds scale keyframes to the track and returns true; near the end (`seek(4900)`) returns false and leaves the timeline unchanged.

- [ ] **Step 2: Implement the hook handler** (reads `playheadMs` internally, calls the writer with the memoized `base`).

- [ ] **Step 3: Extend `TrackPresetMenu`** — after the existing Entrance/Exit items: divider (`border-t border-border-default my-1`), group label "Emphasis" (`text-textXsMedium text-text-inverse-subtlest px-2 py-1`), one item per emphasis preset (labels: Pulse, Shake, Spin, Bounce) following the exact item markup already in the menu. Items disabled (`disabled` + reduced opacity + `title="Not enough room before the end"`) when `duration_ms - playheadMs < 200`. On click: `applyEmphasis(trackId, id)` + close menu.

- [ ] **Step 4: Run gates** — `bun test src/lib/motion/ src/components/studio/kv-generator/motion/ src/components/motion-editor/` green; `bunx tsc --noEmit` no new errors; `bun run build` green.

- [ ] **Step 5: Commit** — `feat(web): emphasis preset group in layer menu`

---

## Self-review checklist

1. Spec coverage: 4 presets ✓ window-scoped strip ✓ sampled base ✓ clamp+reject ✓ menu group + disabled ✓ non-goals untouched.
2. `applyPreset` (entrance/exit) behavior unchanged — its existing tests still pass.
3. Boundary test green.
