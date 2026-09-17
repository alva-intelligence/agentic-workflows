# KV Motion Path Channel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a fifth Build channel, **Path**, that makes a layer follow an editable Catmull-Rom curve — points dragged on the focused tile, a "Path" block on the dock with Duration / Ease / Add new point / Delete — with no api change.

**Architecture:** The curve is stored on the keyframe it leads *into* as `path.points`, each point a **delta from that keyframe's own x/y**, so every existing x/y translator (tile remap, template bake, copy/paste, duplicate) carries the curve for free. The sampler evaluates the curve for x and y together when the pair conditions hold and degrades to today's lerp otherwise. Everything with a number in it is a pure function in `src/lib/video-editor/` with its own test; the Konva and React wiring stays thin.

**Tech Stack:** TypeScript, Next.js 16 / React 19, Konva (lazy-imported, so jsdom tests never touch it), `bun test` (+ Testing Library, `within(document.body)`), PostHog via `safeCapture`.

**Spec:** `docs/superpowers/specs/2026-09-17-kv-motion-path-design.md`

**Branch:** cut `feature/daffa/vc-kv-motion-path` **from `feature/daffa/vc-motion-build-tab`** (it extends `applyBuildChannels`, which only exists there). Work in a worktree: `git -C web worktree add .worktrees/kv-motion-path -b feature/daffa/vc-kv-motion-path feature/daffa/vc-motion-build-tab`, then `bun install` inside it (worktrees need their own `node_modules`; a symlink breaks `next build`). All paths below are relative to `web/`.

## Global Constraints

- **Persisted contract:** `MotionKeyframe.path` is optional and additive; **no `version` bump**. A document without `path` must sample byte-for-byte as before.
- **Invariant:** `path` exists only on a keyframe carrying **both** `x` and `y`. Every writer that removes props goes through `stripProps` (Task 1). No other code path may delete `props.x`/`props.y` directly.
- **Nothing in `src/lib/video-editor/` may import from `components/studio/kv-generator` or `lib/studio/kv`** — `importBoundary.test.ts` fails the suite if it does.
- **Tests:** `bun test <path>`, never `bunx vitest`. Query the DOM with `within(document.body)` (the `body()` helper in existing dock tests), never `screen`. Keep any test file under ~45 KB — split before it grows past. The 3 pre-existing failures in `useTimelineCommands.test.tsx` are not yours.
- **Numeric expectations** in curve tests come from *properties* (endpoints, symmetry, monotonicity, equality with lerp) or from values you computed by running the function once and reading the number — never from mental arithmetic.
- **Copy** (exact strings): channel label `Path`; card subtitle `New`; badge while a layer drag is blocked `Drag the path points to reshape`; popover title `Path`; popover button `Add new point`; destructive item `Delete path`; keyframe label stamp `Path`.
- **Names** (exact): Konva node names `motion-path-curve`, `motion-path-handle`; commit labels `path:<overlayId>:<endMs>:<index>`; analytics event `kv_generator.motion_path_edited`.
- **Commits:** `<type>(<scope>): <description>`, scope `video-editor` for `src/lib/video-editor` + `src/components/video-editor`, `kv-motion` for `src/components/studio/kv-generator/motion`. End every commit message with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`. Do **not** push; Daffa pushes.

---

## File map

| File | Responsibility | Task |
| --- | --- | --- |
| `src/lib/video-editor/timeline.ts` | `MotionPathPoint`, `MotionPath`, `MotionKeyframe.path`, `stripProps` | 1 |
| `src/lib/video-editor/presets.ts` | route 3 strips through `stripProps`; `"path"` channel; `BUILD_EXCLUSIVE_GROUPS`; label `Path` | 1, 5 |
| `src/lib/video-editor/blocks.ts` | `movePropGroup` keeps `path` on the moving half; `trackSegments` treats a curve as motion | 1, 4 |
| `src/lib/video-editor/path.ts` (new) | Catmull-Rom eval, delta↔absolute, insert/remove point | 2 |
| `src/lib/video-editor/sample.ts` | x/y resolved together along the curve when the pair qualifies | 3 |
| `src/lib/video-editor/templates.ts` | `path` round-trips through a template body | 6 |
| `src/lib/video-editor/pathEdit.ts` (new) | `applyPathEdit`: points / endpoint / duration / easing / delete | 7 |
| `src/components/studio/kv-generator/motion/useMotionEditorState.ts` | `activePath`, `setActivePath`, `editPath` | 8 |
| `src/components/video-editor/PathSegmentPopover.tsx` (new) | Duration / Ease / Add new point / Delete path | 9 |
| `src/components/video-editor/BlockTrackRow.tsx` | Build tab exclusivity; click on a `Path` bar opens the popover | 9 |
| `src/components/video-editor/types.ts` | `onEditPath`, `activePath` plumbing | 9 |
| `src/components/video-editor/TimelineDock.tsx` | pass-through | 9 |
| `src/components/studio/kv-generator/motion/onionSkin.ts` | `polyline` field: curved where a Path pair is | 10 |
| `src/components/studio/kv-generator/motion/pathHandles.ts` (new) | handle positions in tile px; handle drop → patch; drag-blocked predicate | 11 |
| `src/components/studio/kv-generator/motion/panHitTest.ts` | a `motion-path-handle` hit blocks panning | 11 |
| `src/components/studio/kv-generator/motion/KvMotionTileStage.tsx` | curve + handles on the focused tile; Transformer detached while a path is active; layer drag guard | 11 |
| `src/components/studio/kv-generator/motion/KvMotionEditor.tsx` | wires activePath / editPath / badge / analytics | 12 |
| `src/lib/analytics/kv-generator-events.ts` | `trackKvMotionPathEdited` | 12 |

---

### Task 1: Data model + `stripProps` invariant

**Files:**
- Modify: `src/lib/video-editor/timeline.ts` (after `MotionKeyframe`, ~line 55)
- Modify: `src/lib/video-editor/presets.ts:296-308` (`stripPresetPropsByIdentity`), `:663-667` (emphasis strip loop), `:1012-1018` (build strip loop)
- Modify: `src/lib/video-editor/blocks.ts:909-917` (`movePropGroup` kept half)
- Test: `src/lib/video-editor/timeline.stripProps.test.ts` (new)
- Test: `src/lib/video-editor/blocks.propGroups.test.ts` (add one case)

**Interfaces:**
- Produces: `type MotionPathPoint = { dx: number; dy: number }`, `type MotionPath = { points: MotionPathPoint[] }`, `MotionKeyframe.path?: MotionPath`, `stripProps(k: MotionKeyframe, props: Iterable<keyof MotionProps>): MotionKeyframe` (pure, returns a new keyframe; drops `path` whenever the result lacks x or y).

- [ ] **Step 1: Write the failing tests**

`src/lib/video-editor/timeline.stripProps.test.ts`:

```ts
import { describe, expect, it } from "bun:test";
import { stripProps, type MotionKeyframe } from "./timeline";
import { applyEmphasisPreset, applyBuildChannels } from "./presets";
import { DEFAULT_TIMELINE } from "./timeline";
import type { MotionProps } from "./timeline";

const kf: MotionKeyframe = {
  t_ms: 500,
  props: { x: 0.4, y: 0.3, scale: 1 },
  easing: "out",
  label: "Path",
  path: { points: [{ dx: -0.05, dy: -0.06 }] },
};

describe("stripProps", () => {
  it("removes the named props and nothing else", () => {
    const out = stripProps(kf, ["scale"]);
    expect(out.props).toEqual({ x: 0.4, y: 0.3 });
    expect(out.path).toEqual(kf.path);
    expect(out.label).toBe("Path");
  });

  it("drops path when x is stripped", () => {
    expect(stripProps(kf, ["x"]).path).toBeUndefined();
  });

  it("drops path when y is stripped", () => {
    expect(stripProps(kf, ["y"]).path).toBeUndefined();
  });

  it("does not mutate its input", () => {
    stripProps(kf, ["x", "y"]);
    expect(kf.props.x).toBe(0.4);
    expect(kf.path).toBeDefined();
  });

  it("drops a path that was already on a keyframe without x (invariant repair)", () => {
    const bad: MotionKeyframe = { ...kf, props: { y: 0.3 } };
    expect(stripProps(bad, ["scale"]).path).toBeUndefined();
  });
});

// Mutation tests: every writer that strips inside a window must lose the
// path with the x/y it removes. If one writer still deletes props by hand,
// its case here fails.
const base = new Map<string, MotionProps>([
  ["ov1", { x: 0.4, y: 0.3, scale: 1, rotation: 0, opacity: 1 }],
]);
const withPath = () => ({
  ...DEFAULT_TIMELINE(),
  tracks: [
    {
      kind: "overlay" as const,
      overlay_id: "ov1",
      keyframes: [
        { t_ms: 1000, props: { x: 0.2, y: 0.3 }, easing: "linear" as const },
        { ...kf, t_ms: 1500 },
      ],
    },
  ],
});

describe("writers route strips through stripProps", () => {
  it("applyEmphasisPreset (shake writes x) drops the path it overwrites", () => {
    const out = applyEmphasisPreset(withPath(), base, "ov1", "shake", 1000)!;
    const end = out.tracks[0].keyframes.find((k) => k.t_ms === 1500);
    expect(end?.path).toBeUndefined();
  });

  it("applyBuildChannels (move writes x) drops the path it overwrites", () => {
    const out = applyBuildChannels(withPath(), base, "ov1", "emphasis", ["move"], 1000)!;
    const end = out.tracks[0].keyframes.find((k) => k.t_ms === 1500);
    expect(end?.path).toBeUndefined();
  });
});
```

Add to `src/lib/video-editor/blocks.propGroups.test.ts`, inside its existing `describe`:

```ts
  it("moving the scale lane keeps the path on the position half it leaves behind", () => {
    const track: MotionTrack = {
      kind: "overlay",
      overlay_id: "ov1",
      keyframes: [
        { t_ms: 0, props: { x: 0.1, y: 0.1, scale: 0.6 }, easing: "linear" },
        {
          t_ms: 500,
          props: { x: 0.3, y: 0.1, scale: 1 },
          easing: "out",
          path: { points: [{ dx: -0.1, dy: -0.05 }] },
        },
      ],
    };
    const timeline: MotionTimeline = { ...DEFAULT_TIMELINE(), tracks: [track] };
    const out = shiftPropGroupKeyframes(timeline, "ov1", "scale", 0, 500, 1000);
    const kept = out.tracks[0].keyframes.find(
      (k) => k.t_ms === 500 && k.props.x !== undefined
    );
    expect(kept?.path).toEqual({ points: [{ dx: -0.1, dy: -0.05 }] });
  });
```

(Use whatever the file already imports for `shiftPropGroupKeyframes` / `MotionTrack` / `MotionTimeline` / `DEFAULT_TIMELINE`; add the missing ones to its import lines.)

- [ ] **Step 2: Run to verify they fail**

Run: `bun test src/lib/video-editor/timeline.stripProps.test.ts src/lib/video-editor/blocks.propGroups.test.ts`
Expected: FAIL — `stripProps` is not exported; the propGroups case fails on `path` being `undefined`.

- [ ] **Step 3: Add the types and the helper**

In `src/lib/video-editor/timeline.ts`, replace the `MotionKeyframe` type with:

```ts
/** One intermediate point of a curve, as a DELTA from the destination
 *  keyframe's own (x, y). Deltas, not absolutes, so that everything that
 *  translates keyframed x/y — the per-tile remap, template bake, copy/paste,
 *  duplicate — carries the curve unchanged without knowing it exists. */
export type MotionPathPoint = { dx: number; dy: number };

export type MotionPath = { points: MotionPathPoint[] };

export type MotionKeyframe = {
  t_ms: number;
  /** Sparse: a keyframe may carry any subset of the five props. */
  props: Partial<MotionProps>;
  /** Easing INTO this keyframe (from the previous keyframe of each prop). */
  easing: MotionEasing;
  /** (existing doc comment for `label` — keep it verbatim) */
  label?: string;
  /** The curve x/y travel INTO this keyframe from the previous x/y keyframe.
   *  Empty `points` = straight line. Only meaningful when this keyframe
   *  carries BOTH x and y — a writer that strips either MUST drop `path`
   *  too, which is what `stripProps` guarantees. Additive and optional:
   *  every document written before this field reads exactly as before. */
  path?: MotionPath;
};

/** Remove `props` from a keyframe, keeping the invariant that `path` exists
 *  only beside both x and y. The ONE way any writer may delete props — a
 *  hand-rolled `delete k.props[p]` can strip x and leave a curve pointing at
 *  nothing. Pure. */
export function stripProps(
  k: MotionKeyframe,
  props: Iterable<keyof MotionProps>
): MotionKeyframe {
  const next: Partial<MotionProps> = { ...k.props };
  for (const p of props) delete next[p];
  const out: MotionKeyframe = { ...k, props: next };
  if (out.path && (next.x === undefined || next.y === undefined)) {
    delete out.path;
  }
  return out;
}
```

- [ ] **Step 4: Route the three `presets.ts` strips through it**

`stripPresetPropsByIdentity` (~line 296): replace the `.map` body with

```ts
    .map((k) => (shouldStrip(k) ? stripProps(k, touched) : k))
```

`applyEmphasisPreset` (~line 663), replace

```ts
  for (const k of track.keyframes) {
    if (k.t_ms < atMs || k.t_ms > endMs) continue;
    for (const p of touched) delete k.props[p];
  }
  track.keyframes = track.keyframes.filter((k) => Object.keys(k.props).length > 0);
```

with

```ts
  track.keyframes = track.keyframes
    .map((k) => (k.t_ms < atMs || k.t_ms > endMs ? k : stripProps(k, touched)))
    .filter((k) => Object.keys(k.props).length > 0);
```

`applyBuildChannels` (~line 1012), replace

```ts
  for (const k of track.keyframes) {
    if (k.t_ms < startMs || k.t_ms > endMs) continue;
    for (const p of touched) delete k.props[p];
  }
  track.keyframes = track.keyframes.filter(
    (k) => Object.keys(k.props).length > 0,
  );
```

with

```ts
  track.keyframes = track.keyframes
    .map((k) =>
      k.t_ms < startMs || k.t_ms > endMs ? k : stripProps(k, touched),
    )
    .filter((k) => Object.keys(k.props).length > 0);
```

Add `stripProps` to the `./timeline` import at the top of `presets.ts`. Search the file for any remaining `delete k.props` / `delete props[` — there must be none.

- [ ] **Step 5: Keep `path` on the kept half in `movePropGroup`**

`src/lib/video-editor/blocks.ts` ~line 909, replace

```ts
    const rest: Partial<MotionProps> = { ...kf.props };
    for (const key of keys) delete rest[key];
    // Touched: the leftover half loses the preset name too, or the block
    // would keep claiming to be a preset it no longer is.
    if (Object.keys(rest).length > 0) {
      kept.push({ t_ms: kf.t_ms, props: rest, easing: kf.easing });
    }
    moving.push({
```

with

```ts
    // `stripProps` also drops `path` if the position lane is what moves;
    // the moving half below re-attaches it in that case. Touched: the
    // leftover half loses the preset name too, or the block would keep
    // claiming to be a preset it no longer is.
    const { label: _dropped, ...stripped } = stripProps(kf, keys);
    void _dropped;
    if (Object.keys(stripped.props).length > 0) kept.push(stripped);
    // The position lane carries x AND y together (`PROP_LABEL_GROUPS`), so
    // a curve — geometry, not a preset stamp — travels with it.
    const carriesPath = group === "position" && kf.path !== undefined;
    moving.push({
      ...(carriesPath ? { path: kf.path } : {}),
```

(The object literal that follows already has `t_ms`, `props: groupProps`, `easing` — leave those lines as they are.) Add `stripProps` to the `./timeline` import.

- [ ] **Step 6: Run the tests**

Run: `bun test src/lib/video-editor/timeline.stripProps.test.ts src/lib/video-editor/blocks.propGroups.test.ts src/lib/video-editor/presets.test.ts src/lib/video-editor/presets.buildChannels.test.ts src/lib/video-editor/blocks.test.ts`
Expected: all PASS (existing preset/block tests prove the strips are behaviour-preserving).

- [ ] **Step 7: Commit**

```bash
git add src/lib/video-editor/timeline.ts src/lib/video-editor/presets.ts src/lib/video-editor/blocks.ts src/lib/video-editor/timeline.stripProps.test.ts src/lib/video-editor/blocks.propGroups.test.ts
git commit -m "feat(video-editor): MotionKeyframe.path + stripProps invariant

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Curve math — `path.ts`

**Files:**
- Create: `src/lib/video-editor/path.ts`
- Test: `src/lib/video-editor/path.test.ts`

**Interfaces:**
- Produces:
  - `type Pt = { x: number; y: number }`
  - `absolutePoints(dest: Pt, points: MotionPathPoint[]): Pt[]`
  - `toDeltas(dest: Pt, abs: Pt[]): MotionPathPoint[]`
  - `evalPath(start: Pt, end: Pt, points: MotionPathPoint[], u: number): Pt` — `u ∈ [0,1]` already eased
  - `samplePath(start: Pt, end: Pt, points: MotionPathPoint[], n = 32): Pt[]` — `n+1` samples, first = start, last = end
  - `insertMidpoint(start: Pt, end: Pt, points: MotionPathPoint[]): MotionPathPoint[]`
  - `removePoint(points: MotionPathPoint[], i: number): MotionPathPoint[]`

- [ ] **Step 1: Write the failing tests**

```ts
import { describe, expect, it } from "bun:test";
import {
  absolutePoints,
  evalPath,
  insertMidpoint,
  removePoint,
  samplePath,
  toDeltas,
} from "./path";

const S = { x: 0.1, y: 0.5 };
const E = { x: 0.7, y: 0.5 };

describe("delta <-> absolute", () => {
  it("round-trips", () => {
    const deltas = [{ dx: -0.3, dy: -0.2 }, { dx: -0.1, dy: 0.1 }];
    expect(toDeltas(E, absolutePoints(E, deltas))).toEqual(deltas);
  });
  it("absolute = dest + delta", () => {
    expect(absolutePoints(E, [{ dx: -0.3, dy: -0.2 }])).toEqual([
      { x: 0.7 - 0.3, y: 0.5 - 0.2 },
    ]);
  });
});

describe("evalPath", () => {
  it("hits the endpoints exactly", () => {
    const pts = [{ dx: -0.3, dy: -0.2 }];
    expect(evalPath(S, E, pts, 0)).toEqual(S);
    expect(evalPath(S, E, pts, 1)).toEqual(E);
  });

  it("with no points is exactly lerp", () => {
    for (const u of [0, 0.25, 0.5, 0.75, 1]) {
      expect(evalPath(S, E, [], u)).toEqual({
        x: S.x + (E.x - S.x) * u,
        y: S.y + (E.y - S.y) * u,
      });
    }
  });

  it("passes THROUGH a midpoint at the segment boundary", () => {
    // One point at the chord's centre, lifted: u=0.5 is the boundary between
    // the two segments, so the curve is AT the point there.
    const mid = { x: 0.4, y: 0.3 };
    const pts = toDeltas(E, [mid]);
    const p = evalPath(S, E, pts, 0.5);
    expect(p.x).toBeCloseTo(mid.x, 10);
    expect(p.y).toBeCloseTo(mid.y, 10);
  });

  it("is symmetric for a symmetric arc", () => {
    const pts = toDeltas(E, [{ x: 0.4, y: 0.3 }]);
    const a = evalPath(S, E, pts, 0.25);
    const b = evalPath(S, E, pts, 0.75);
    expect(a.y).toBeCloseTo(b.y, 10);
    expect(a.x - S.x).toBeCloseTo(E.x - b.x, 10);
  });

  it("bulges toward the lifted point (not a straight line)", () => {
    const pts = toDeltas(E, [{ x: 0.4, y: 0.3 }]);
    expect(evalPath(S, E, pts, 0.25).y).toBeLessThan(0.5);
  });

  it("stays finite with two points on top of each other (centripetal)", () => {
    const pts = toDeltas(E, [{ x: 0.4, y: 0.3 }, { x: 0.4, y: 0.3 }]);
    for (let i = 0; i <= 20; i++) {
      const p = evalPath(S, E, pts, i / 20);
      expect(Number.isFinite(p.x)).toBe(true);
      expect(Number.isFinite(p.y)).toBe(true);
    }
  });

  it("clamps u outside [0,1]", () => {
    const pts = toDeltas(E, [{ x: 0.4, y: 0.3 }]);
    expect(evalPath(S, E, pts, -1)).toEqual(S);
    expect(evalPath(S, E, pts, 2)).toEqual(E);
  });
});

describe("samplePath", () => {
  it("returns n+1 samples from start to end", () => {
    const out = samplePath(S, E, toDeltas(E, [{ x: 0.4, y: 0.3 }]), 8);
    expect(out).toHaveLength(9);
    expect(out[0]).toEqual(S);
    expect(out[8]).toEqual(E);
  });
});

describe("insertMidpoint", () => {
  it("with no points inserts the chord midpoint", () => {
    const out = insertMidpoint(S, E, []);
    expect(absolutePoints(E, out)).toEqual([{ x: 0.4, y: 0.5 }]);
  });
  it("splits the LONGEST sub-segment", () => {
    // start(0.1) -> p(0.2) -> end(0.7): the second gap is longest.
    const pts = toDeltas(E, [{ x: 0.2, y: 0.5 }]);
    const out = absolutePoints(E, insertMidpoint(S, E, pts));
    expect(out).toEqual([
      { x: 0.2, y: 0.5 },
      { x: (0.2 + 0.7) / 2, y: 0.5 },
    ]);
  });
});

describe("removePoint", () => {
  it("removes by index without mutating", () => {
    const pts = [{ dx: 1, dy: 1 }, { dx: 2, dy: 2 }];
    expect(removePoint(pts, 0)).toEqual([{ dx: 2, dy: 2 }]);
    expect(pts).toHaveLength(2);
  });
  it("ignores an out-of-range index", () => {
    const pts = [{ dx: 1, dy: 1 }];
    expect(removePoint(pts, 5)).toEqual(pts);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/lib/video-editor/path.test.ts`
Expected: FAIL — cannot resolve `./path`.

- [ ] **Step 3: Implement**

```ts
import type { MotionPathPoint } from "./timeline";

export type Pt = { x: number; y: number };

/** Intermediate points as absolute positions — `dest + delta`. */
export function absolutePoints(dest: Pt, points: MotionPathPoint[]): Pt[] {
  return points.map((p) => ({ x: dest.x + p.dx, y: dest.y + p.dy }));
}

export function toDeltas(dest: Pt, abs: Pt[]): MotionPathPoint[] {
  return abs.map((p) => ({ dx: p.x - dest.x, dy: p.y - dest.y }));
}

function lerp(a: Pt, b: Pt, t: number): Pt {
  return { x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t };
}

/** Centripetal Catmull-Rom (α = 0.5) through p1→p2, with p0/p3 as the
 *  neighbouring control points. Centripetal — not uniform — so two points
 *  close together cannot produce a cusp or a loop. Endpoints are doubled by
 *  the caller (`evalPath`) to give the first and last segment a tangent.
 *  Barry–Goldman recursive form. */
function catmullRom(p0: Pt, p1: Pt, p2: Pt, p3: Pt, t: number): Pt {
  const knot = (a: Pt, b: Pt, prev: number) =>
    prev + Math.sqrt(Math.hypot(b.x - a.x, b.y - a.y)) || prev + 1e-6;
  const t0 = 0;
  const t1 = knot(p0, p1, t0);
  const t2 = knot(p1, p2, t1);
  const t3 = knot(p2, p3, t2);
  const tt = t1 + (t2 - t1) * t;
  const mix = (a: Pt, b: Pt, ta: number, tb: number): Pt => {
    const w = tb === ta ? 0 : (tt - ta) / (tb - ta);
    return lerp(a, b, w);
  };
  const a1 = mix(p0, p1, t0, t1);
  const a2 = mix(p1, p2, t1, t2);
  const a3 = mix(p2, p3, t2, t3);
  const b1 = mix(a1, a2, t0, t2);
  const b2 = mix(a2, a3, t1, t3);
  return mix(b1, b2, t1, t2);
}

/** Position at eased fraction `u` along start → …points → end. Uniform
 *  parametrisation across sub-segments: `u` picks the segment, the remainder
 *  is that segment's local t. Zero points = plain lerp, bit-for-bit. */
export function evalPath(
  start: Pt,
  end: Pt,
  points: MotionPathPoint[],
  u: number
): Pt {
  const c = Math.min(1, Math.max(0, u));
  if (points.length === 0) return lerp(start, end, c);
  const ctrl = [start, ...absolutePoints(end, points), end];
  const n = ctrl.length - 1;
  if (c >= 1) return { ...end };
  if (c <= 0) return { ...start };
  const scaled = c * n;
  const i = Math.min(n - 1, Math.floor(scaled));
  const t = scaled - i;
  const p0 = ctrl[Math.max(0, i - 1)];
  const p1 = ctrl[i];
  const p2 = ctrl[i + 1];
  const p3 = ctrl[Math.min(n, i + 2)];
  return catmullRom(p0, p1, p2, p3, t);
}

/** `n + 1` samples, first exactly `start`, last exactly `end`. */
export function samplePath(
  start: Pt,
  end: Pt,
  points: MotionPathPoint[],
  n = 32
): Pt[] {
  const out: Pt[] = [];
  for (let i = 0; i <= n; i++) out.push(evalPath(start, end, points, i / n));
  return out;
}

/** A new point at the midpoint of the LONGEST straight gap between
 *  consecutive control points — where there is the most room to shape. */
export function insertMidpoint(
  start: Pt,
  end: Pt,
  points: MotionPathPoint[]
): MotionPathPoint[] {
  const ctrl = [start, ...absolutePoints(end, points), end];
  let best = 0;
  let bestLen = -1;
  for (let i = 0; i < ctrl.length - 1; i++) {
    const len = Math.hypot(ctrl[i + 1].x - ctrl[i].x, ctrl[i + 1].y - ctrl[i].y);
    if (len > bestLen) {
      bestLen = len;
      best = i;
    }
  }
  const mid = lerp(ctrl[best], ctrl[best + 1], 0.5);
  const abs = absolutePoints(end, points);
  abs.splice(best, 0, mid);
  return toDeltas(end, abs);
}

export function removePoint(
  points: MotionPathPoint[],
  i: number
): MotionPathPoint[] {
  if (i < 0 || i >= points.length) return points;
  return points.filter((_, j) => j !== i);
}
```

- [ ] **Step 4: Run the tests**

Run: `bun test src/lib/video-editor/path.test.ts`
Expected: PASS. If "passes THROUGH a midpoint" fails by a rounding hair, loosen only that assertion to `toBeCloseTo(…, 6)` — the segment boundary lands exactly on the control point by construction, so anything worse than 1e-6 is a real bug.

- [ ] **Step 5: Commit**

```bash
git add src/lib/video-editor/path.ts src/lib/video-editor/path.test.ts
git commit -m "feat(video-editor): centripetal Catmull-Rom path math

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Sampler follows the curve

**Files:**
- Modify: `src/lib/video-editor/sample.ts`
- Test: `src/lib/video-editor/sample.path.test.ts` (new)

**Interfaces:**
- Consumes: `evalPath` (Task 2), `MotionKeyframe.path` (Task 1).
- `sampleTimelineAt` signature unchanged.

- [ ] **Step 1: Write the failing tests**

```ts
import { describe, expect, it } from "bun:test";
import { evalPath } from "./path";
import { EASINGS, sampleTimelineAt } from "./sample";
import { DEFAULT_TIMELINE } from "./timeline";
import type { MotionKeyframe, MotionProps, MotionTimeline } from "./timeline";

const rest: MotionProps = { x: 0.1, y: 0.5, scale: 1, rotation: 0, opacity: 1 };
const base = new Map([["ov1", rest]]);
const pts = [{ dx: -0.3, dy: -0.2 }];

function tl(keyframes: MotionKeyframe[]): MotionTimeline {
  return {
    ...DEFAULT_TIMELINE(),
    tracks: [{ kind: "overlay", overlay_id: "ov1", keyframes }],
  };
}
const start: MotionKeyframe = { t_ms: 0, props: { x: 0.1, y: 0.5 }, easing: "linear" };
const end: MotionKeyframe = {
  t_ms: 1000,
  props: { x: 0.7, y: 0.5 },
  easing: "out",
  path: { points: pts },
};

describe("sampleTimelineAt with a path", () => {
  it("resolves x and y together along the eased curve", () => {
    const got = sampleTimelineAt(tl([start, end]), base, 250).get("ov1")!;
    const want = evalPath({ x: 0.1, y: 0.5 }, { x: 0.7, y: 0.5 }, pts, EASINGS.out(0.25));
    expect(got.x).toBeCloseTo(want.x, 12);
    expect(got.y).toBeCloseTo(want.y, 12);
  });

  it("leaves the other props on their own lerp", () => {
    const s = { ...start, props: { ...start.props, opacity: 0 } };
    const e = { ...end, props: { ...end.props, opacity: 1 } };
    const got = sampleTimelineAt(tl([s, e]), base, 500).get("ov1")!;
    expect(got.opacity).toBeCloseTo(EASINGS.out(0.5), 12);
  });

  it("degrades to lerp when the previous keyframe lacks y", () => {
    const s = { ...start, props: { x: 0.1 } };
    const got = sampleTimelineAt(tl([s, end]), base, 500).get("ov1")!;
    expect(got.x).toBeCloseTo(0.1 + 0.6 * EASINGS.out(0.5), 12);
    expect(got.y).toBe(0.5); // rest y: no y keyframe before → first y keyframe clamps
  });

  it("degrades to lerp when a y-only keyframe sits between the pair", () => {
    const mid: MotionKeyframe = { t_ms: 500, props: { y: 0.4 }, easing: "linear" };
    const got = sampleTimelineAt(tl([start, mid, end]), base, 250).get("ov1")!;
    expect(got.x).toBeCloseTo(0.1 + 0.6 * EASINGS.out(0.25), 12);
    expect(got.y).toBeCloseTo(0.5 + (0.4 - 0.5) * 0.5, 12);
  });

  it("ignores a path on a keyframe that has no x", () => {
    const e = { ...end, props: { y: 0.5 } };
    const got = sampleTimelineAt(tl([start, e]), base, 500).get("ov1")!;
    expect(got.x).toBe(0.1);
  });

  it("with empty points equals the no-path document exactly", () => {
    const a = sampleTimelineAt(tl([start, { ...end, path: { points: [] } }]), base, 333).get("ov1")!;
    const b = sampleTimelineAt(tl([start, { ...end, path: undefined }]), base, 333).get("ov1")!;
    expect(a).toEqual(b);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/lib/video-editor/sample.path.test.ts`
Expected: FAIL on the first test (x/y come back lerped).

- [ ] **Step 3: Implement**

Replace the body of the `for (const prop of PROPS)` loop in `sampleTimelineAt` with a version that handles the pair once:

```ts
    const xy = pathPair(sorted, tMs);
    for (const prop of PROPS) {
      if (xy && (prop === "x" || prop === "y")) {
        resolved[prop] = xy[prop];
        continue;
      }
      const kfs = sorted.filter((k) => k.props[prop] !== undefined);
      if (kfs.length === 0) continue;
      if (tMs <= kfs[0].t_ms) {
        resolved[prop] = kfs[0].props[prop]!;
        continue;
      }
      const last = kfs[kfs.length - 1];
      if (tMs >= last.t_ms) {
        resolved[prop] = last.props[prop]!;
        continue;
      }
      // find surrounding pair
      let i = 0;
      while (kfs[i + 1].t_ms < tMs) i++;
      const a = kfs[i];
      const b = kfs[i + 1];
      const span = b.t_ms - a.t_ms;
      const frac = span === 0 ? 1 : (tMs - a.t_ms) / span;
      const eased = EASINGS[b.easing](frac);
      resolved[prop] = a.props[prop]! + (b.props[prop]! - a.props[prop]!) * eased;
    }
```

and add above `sampleTimelineAt`:

```ts
import { evalPath } from "./path";

function hasXY(k: MotionKeyframe): boolean {
  return k.props.x !== undefined && k.props.y !== undefined;
}

/** The (x, y) at `tMs` when it falls strictly inside a segment whose
 *  destination keyframe carries a non-empty `path`, and the segment is the
 *  same one for BOTH props: `a` and `b` each carry x and y, and no keyframe
 *  between them carries either. Otherwise `null`, and the caller lerps each
 *  prop on its own exactly as before — a curve only has a meaning when x
 *  and y share a segment. */
function pathPair(
  sorted: MotionKeyframe[],
  tMs: number
): { x: number; y: number } | null {
  let a: MotionKeyframe | null = null;
  let b: MotionKeyframe | null = null;
  for (const k of sorted) {
    const touchesXY = k.props.x !== undefined || k.props.y !== undefined;
    if (!touchesXY) continue;
    if (k.t_ms < tMs) a = k;
    else if (k.t_ms > tMs) {
      b = k;
      break;
    } else return null; // exactly on a keyframe: its own value wins
  }
  if (!a || !b || !b.path || b.path.points.length === 0) return null;
  if (!hasXY(a) || !hasXY(b)) return null;
  const frac = (tMs - a.t_ms) / (b.t_ms - a.t_ms);
  return evalPath(
    { x: a.props.x!, y: a.props.y! },
    { x: b.props.x!, y: b.props.y! },
    b.path.points,
    EASINGS[b.easing](frac)
  );
}
```

Add `MotionKeyframe` to the type import at the top.

- [ ] **Step 4: Run the tests**

Run: `bun test src/lib/video-editor/sample.path.test.ts src/lib/video-editor/sample.test.ts src/lib/video-editor/presets.preview.test.ts`
Expected: PASS — the "with empty points equals" case is the byte-for-byte guarantee for old documents.

- [ ] **Step 5: Commit**

```bash
git add src/lib/video-editor/sample.ts src/lib/video-editor/sample.path.test.ts
git commit -m "feat(video-editor): sampler follows a keyframe's path for x/y together

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: A curve counts as motion in `trackSegments`

Without this, an emphasis Path (start pose == end pose) is "still" across its gap, splits into two zero-span still points, and never gets a bar.

**Files:**
- Modify: `src/lib/video-editor/blocks.ts:128-160` (`trackSegments`)
- Test: `src/lib/video-editor/blocks.test.ts` (add cases)

- [ ] **Step 1: Write the failing tests**

Append inside the existing `describe("trackSegments"…)` (or add a new `describe` if none exists by that name):

```ts
  it("a path INTO a keyframe is motion even when the poses match (emphasis loop)", () => {
    const track: MotionTrack = {
      kind: "overlay",
      overlay_id: "ov1",
      keyframes: [
        { t_ms: 1000, props: { x: 0.3, y: 0.3 }, easing: "linear" },
        {
          t_ms: 1600,
          props: { x: 0.3, y: 0.3 },
          easing: "out",
          path: { points: [{ dx: 0.05, dy: -0.05 }, { dx: -0.05, dy: -0.05 }] },
        },
      ],
    };
    expect(trackSegments(track)).toEqual([{ startMs: 1000, endMs: 1600 }]);
  });

  it("a path spans an unrelated keyframe sitting inside it", () => {
    const track: MotionTrack = {
      kind: "overlay",
      overlay_id: "ov1",
      keyframes: [
        { t_ms: 1000, props: { x: 0.3, y: 0.3, scale: 1 }, easing: "linear" },
        { t_ms: 1300, props: { scale: 1 }, easing: "linear" },
        {
          t_ms: 1600,
          props: { x: 0.3, y: 0.3 },
          easing: "out",
          path: { points: [{ dx: 0.05, dy: -0.05 }] },
        },
      ],
    };
    expect(trackSegments(track)).toEqual([{ startMs: 1000, endMs: 1600 }]);
  });

  it("an EMPTY path is not motion", () => {
    const track: MotionTrack = {
      kind: "overlay",
      overlay_id: "ov1",
      keyframes: [
        { t_ms: 1000, props: { x: 0.3, y: 0.3 }, easing: "linear" },
        { t_ms: 1600, props: { x: 0.3, y: 0.3 }, easing: "out", path: { points: [] } },
      ],
    };
    expect(trackSegments(track)).toEqual([
      { startMs: 1000, endMs: 1000 },
      { startMs: 1600, endMs: 1600 },
    ]);
  });
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/lib/video-editor/blocks.test.ts -t "path"`
Expected: first two FAIL (two still points), third passes already.

- [ ] **Step 3: Implement**

In `trackSegments`, after `const timelines = …`, add:

```ts
  // A curve INTO keyframe `b` is motion across every gap between the
  // previous x/y keyframe and `b`, even when the two poses are identical (an
  // emphasis loop leaves and returns to the same spot). Without this a loop
  // reads as two still points and never gets a bar.
  const xyTimes = track.keyframes
    .filter((k) => k.props.x !== undefined && k.props.y !== undefined)
    .map((k) => k.t_ms)
    .sort((a, b) => a - b);
  const pathEnds = track.keyframes
    .filter(
      (k) =>
        k.path !== undefined &&
        k.path.points.length > 0 &&
        k.props.x !== undefined &&
        k.props.y !== undefined
    )
    .map((k) => k.t_ms)
    .sort((a, b) => a - b);
  function movesAlongPath(a: number, b: number): boolean {
    for (const endT of pathEnds) {
      if (endT < b) continue;
      let prevXY: number | undefined;
      for (const t of xyTimes) if (t < endT) prevXY = t;
      return prevXY !== undefined && prevXY <= a;
    }
    return false;
  }
```

and make `isBoundary` start with `if (movesAlongPath(a, b)) return false;`.

- [ ] **Step 4: Run the tests**

Run: `bun test src/lib/video-editor/blocks.test.ts src/lib/video-editor/blocks.propGroups.test.ts src/lib/video-editor/blocks.propGroupDrag.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lib/video-editor/blocks.ts src/lib/video-editor/blocks.test.ts
git commit -m "feat(video-editor): trackSegments treats a keyframe's path as motion

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: The `"path"` Build channel

**Files:**
- Modify: `src/lib/video-editor/presets.ts` (`BuildChannelId` block ~line 860; `applyBuildChannels` write loop ~line 990)
- Test: `src/lib/video-editor/presets.buildChannels.test.ts` (add cases; if it passes 40 KB, put the new cases in `presets.buildPath.test.ts` instead)

**Interfaces:**
- Produces: `BuildChannelId` includes `"path"`; `BUILD_CHANNEL_IDS = ["path","move","rotate","scale","opacity"]`; `BUILD_CHANNEL_LABELS.path = "Path"`; `BUILD_EXCLUSIVE_GROUPS: readonly (readonly BuildChannelId[])[] = [["path","move"]]`; `PATH_LABEL = "Path"`; `PATH_ARC_DY = -0.06`; `PATH_LOOP_D = 0.05`.
- `applyBuildChannels` accepts `"path"` in `channels`.

- [ ] **Step 1: Write the failing tests**

```ts
import { describe, expect, it } from "bun:test";
import {
  applyBuildChannels,
  BUILD_CHANNEL_IDS,
  BUILD_EXCLUSIVE_GROUPS,
  buildChannelPreviewKeyframes,
  PATH_ARC_DY,
  PATH_LABEL,
  PATH_LOOP_D,
  SLIDE_OFFSET,
} from "./presets";
import { DEFAULT_TIMELINE } from "./timeline";
import type { MotionProps } from "./timeline";

const rest: MotionProps = { x: 0.4, y: 0.3, scale: 1, rotation: 0, opacity: 1 };
const base = new Map([["ov1", rest]]);
const empty = () => ({ ...DEFAULT_TIMELINE(), tracks: [] });
const kfs = (tl: ReturnType<typeof empty> | null) =>
  [...(tl?.tracks[0]?.keyframes ?? [])].sort((a, b) => a.t_ms - b.t_ms);

describe("path channel", () => {
  it("is listed first and is exclusive with move", () => {
    expect(BUILD_CHANNEL_IDS[0]).toBe("path");
    expect(BUILD_EXCLUSIVE_GROUPS).toEqual([["path", "move"]]);
  });

  it("in: arcs from the left offset onto the rest pose", () => {
    const [a, b] = kfs(applyBuildChannels(empty(), base, "ov1", "in", ["path"], 0));
    expect(a).toEqual({
      t_ms: 0,
      props: { x: rest.x - SLIDE_OFFSET, y: rest.y },
      easing: "linear",
      label: PATH_LABEL,
    });
    expect(b.t_ms).toBe(500);
    expect(b.props).toEqual({ x: rest.x, y: rest.y });
    expect(b.easing).toBe("out");
    expect(b.label).toBe(PATH_LABEL);
    expect(b.path).toEqual({ points: [{ dx: -SLIDE_OFFSET / 2, dy: PATH_ARC_DY }] });
  });

  it("out: mirrors in", () => {
    const [a, b] = kfs(applyBuildChannels(empty(), base, "ov1", "out", ["path"], 5000));
    expect(a.t_ms).toBe(4500);
    expect(a.props).toEqual({ x: rest.x, y: rest.y });
    expect(b.props).toEqual({ x: rest.x + SLIDE_OFFSET, y: rest.y });
    expect(b.path).toEqual({ points: [{ dx: -SLIDE_OFFSET / 2, dy: PATH_ARC_DY }] });
  });

  it("emphasis: loops out and back from the sampled pose", () => {
    const [a, b] = kfs(applyBuildChannels(empty(), base, "ov1", "emphasis", ["path"], 2000));
    expect(a.t_ms).toBe(2000);
    expect(b.t_ms).toBe(2600);
    expect(a.props).toEqual({ x: rest.x, y: rest.y });
    expect(b.props).toEqual({ x: rest.x, y: rest.y });
    expect(b.path).toEqual({
      points: [
        { dx: PATH_LOOP_D, dy: -PATH_LOOP_D },
        { dx: -PATH_LOOP_D, dy: -PATH_LOOP_D },
      ],
    });
  });

  it("path + scale share keyframes; the path rides the x/y keyframe", () => {
    const [a, b] = kfs(applyBuildChannels(empty(), base, "ov1", "in", ["path", "scale"], 0));
    expect(Object.keys(a.props).sort()).toEqual(["scale", "x", "y"]);
    expect(b.path).toBeDefined();
  });

  it("preview keyframes carry the path so the card curves", () => {
    const [, b] = buildChannelPreviewKeyframes("path", "in");
    expect(b.path?.points).toHaveLength(1);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/lib/video-editor/presets.buildChannels.test.ts`
Expected: FAIL — `PATH_LABEL` etc. not exported; `"path"` not a `BuildChannelId`.

- [ ] **Step 3: Implement**

Export `SLIDE_OFFSET` if it is still `const` (change `const SLIDE_OFFSET = 0.15;` to `export const …`). Replace the `BuildChannelId` block:

```ts
export type BuildChannelId = "path" | "move" | "scale" | "rotate" | "opacity";

/** Menu order. Path first (the one channel with its own canvas handles, and
 *  the newest), then the transforms in the order every mainstream motion
 *  tool lists them, then the one non-transform. */
export const BUILD_CHANNEL_IDS: BuildChannelId[] = [
  "path",
  "move",
  "rotate",
  "scale",
  "opacity",
];

export const BUILD_CHANNEL_LABELS: Record<BuildChannelId, string> = {
  path: "Path",
  move: "Move",
  scale: "Scale",
  rotate: "Rotate",
  opacity: "Opacity",
};

/** Channels that cannot be picked together in ONE Build: both members of a
 *  group write the same props (Path and Move both own x/y), and two writers
 *  of one prop in one action is a bug, not a composition. Toggling one on
 *  deselects its group-mates (see `SlotPlaceholder`). */
export const BUILD_EXCLUSIVE_GROUPS: readonly (readonly BuildChannelId[])[] = [
  ["path", "move"],
];

/** The label stamped on both keyframes a Path writes — what the dock bar
 *  shows, and what opens the Path popover on click. Not a preset family:
 *  `presetFamilyForLabel` returns null for it on purpose. */
export const PATH_LABEL = "Path";
/** Default shapes, the only invented numbers here: an edge path bows this
 *  far above its chord; an emphasis path loops this far out and up. */
export const PATH_ARC_DY = -0.06;
export const PATH_LOOP_D = 0.05;
```

`BUILD_EDGE_WRITERS` is `Record<BuildChannelId, …>` — add a `path` entry so the type stays total (it is never reached; the loop below handles path before it):

```ts
  path: (b) => ({ from: { x: b.x - SLIDE_OFFSET, y: b.y }, to: { x: b.x, y: b.y } }),
```

In `applyBuildChannels`'s `for (const channel of channels)` loop, add **before** the `if (slot === "emphasis")` branch:

```ts
    if (channel === "path") {
      written.push(...buildPathKeyframes(slot, pose, startMs, endMs));
      continue;
    }
```

and add this function above `applyBuildChannels`:

```ts
/** The Path channel's default keyframes. Deltas are from the END keyframe
 *  (see `MotionKeyframe.path`). Edge paths bow above the chord; an emphasis
 *  path leaves the current pose, loops up and comes back. */
function buildPathKeyframes(
  slot: SlotKind,
  pose: MotionProps,
  startMs: number,
  endMs: number,
): MotionKeyframe[] {
  if (slot === "emphasis") {
    return [
      { t_ms: startMs, props: { x: pose.x, y: pose.y }, easing: "linear", label: PATH_LABEL },
      {
        t_ms: endMs,
        props: { x: pose.x, y: pose.y },
        easing: "out",
        label: PATH_LABEL,
        path: {
          points: [
            { dx: PATH_LOOP_D, dy: -PATH_LOOP_D },
            { dx: -PATH_LOOP_D, dy: -PATH_LOOP_D },
          ],
        },
      },
    ];
  }
  const off = { x: slot === "in" ? pose.x - SLIDE_OFFSET : pose.x + SLIDE_OFFSET, y: pose.y };
  const restXY = { x: pose.x, y: pose.y };
  const [first, second] = slot === "in" ? [off, restXY] : [restXY, off];
  return [
    { t_ms: startMs, props: first, easing: "linear", label: PATH_LABEL },
    {
      t_ms: endMs,
      props: second,
      easing: "out",
      label: PATH_LABEL,
      path: { points: [{ dx: -SLIDE_OFFSET / 2, dy: PATH_ARC_DY }] },
    },
  ];
}
```

The merge step at the end of `applyBuildChannels` merges `existing.props = { ...existing.props, ...w.props }` — extend it so `label` and `path` also land:

```ts
    if (existing) {
      existing.props = { ...existing.props, ...w.props };
      if (w.label !== undefined) existing.label = w.label;
      if (w.path !== undefined) existing.path = w.path;
    } else track.keyframes.push({ ...w });
```

- [ ] **Step 4: Run the tests**

Run: `bun test src/lib/video-editor/presets.buildChannels.test.ts src/lib/video-editor/presets.test.ts src/components/video-editor/TimelineDock.buildtab.test.tsx src/components/studio/kv-generator/motion/useMotionEditorState.build.test.ts`
Expected: PASS. (The dock test clicks `slot-emphasis-build-move` + `-scale` and expects `["move","scale"]` in list order — still true.)

- [ ] **Step 5: Commit**

```bash
git add src/lib/video-editor/presets.ts src/lib/video-editor/presets.buildChannels.test.ts
git commit -m "feat(video-editor): Path build channel with per-slot default curves

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: `path` survives every carrier

`cloneTrackForOverlay` (copy/paste, duplicate) and `remapTimelineForRatio` (tiles) spread the keyframe, so they only need a test. `normalizeTrackToTemplate` / `bakeTemplateToTrack` rebuild keyframe objects and **drop** it — fix.

**Files:**
- Modify: `src/lib/video-editor/templates.ts` (`MotionTemplateKeyframe`, both mappers)
- Test: `src/lib/video-editor/templates.test.ts`, `src/lib/video-editor/cloneTrackForOverlay.test.ts`, `src/components/studio/kv-generator/motion/exportMotion.test.ts` (one case each)

- [ ] **Step 1: Write the failing tests**

`templates.test.ts` — add inside the file's top-level describe (reuse its existing `base`/track fixtures if any; otherwise these are self-contained):

```ts
  it("a keyframe's path round-trips through normalize → bake unchanged", () => {
    const base: MotionProps = { x: 0.2, y: 0.2, scale: 1, rotation: 0, opacity: 1 };
    const track: MotionTrack = {
      kind: "overlay",
      overlay_id: "ov1",
      keyframes: [
        { t_ms: 0, props: { x: 0.05, y: 0.2 }, easing: "linear", label: "Path" },
        {
          t_ms: 500,
          props: { x: 0.2, y: 0.2 },
          easing: "out",
          label: "Path",
          path: { points: [{ dx: -0.075, dy: -0.06 }] },
        },
      ],
    };
    const body = normalizeTrackToTemplate(track, base, 5000);
    expect(body.keyframes[1].path).toEqual({ points: [{ dx: -0.075, dy: -0.06 }] });
    const target: MotionProps = { x: 0.6, y: 0.7, scale: 1, rotation: 0, opacity: 1 };
    const baked = bakeTemplateToTrack(body, "ov2", target, 5000)!;
    expect(baked.keyframes[1].path).toEqual({ points: [{ dx: -0.075, dy: -0.06 }] });
    expect(baked.keyframes[1].props).toEqual({ x: 0.6, y: 0.7 });
  });

  it("bake rejects a non-finite path delta", () => {
    const body = {
      version: 1,
      source_duration_ms: 5000,
      absolute_props: [],
      keyframes: [
        { t_ms: 0, props: { x: 0, y: 0 }, easing: "linear" as const },
        {
          t_ms: 500,
          props: { x: 0, y: 0 },
          easing: "out" as const,
          path: { points: [{ dx: Number.NaN, dy: 0 }] },
        },
      ],
    };
    expect(bakeTemplateToTrack(body, "ov", { x: 0, y: 0, scale: 1, rotation: 0, opacity: 1 }, 5000)).toBeNull();
  });
```

`cloneTrackForOverlay.test.ts`:

```ts
  it("keeps a keyframe's path (deltas are offset-invariant)", () => {
    const timeline: MotionTimeline = {
      ...DEFAULT_TIMELINE(),
      tracks: [
        {
          kind: "overlay",
          overlay_id: "a",
          keyframes: [
            { t_ms: 0, props: { x: 0, y: 0 }, easing: "linear" },
            { t_ms: 500, props: { x: 0.2, y: 0 }, easing: "out", path: { points: [{ dx: -0.1, dy: -0.05 }] } },
          ],
        },
      ],
    };
    const out = cloneTrackForOverlay(timeline, "a", "b", { x: 0.3, y: 0.3 })!;
    expect(out.keyframes[1].props).toEqual({ x: 0.5, y: 0.3 });
    expect(out.keyframes[1].path).toEqual({ points: [{ dx: -0.1, dy: -0.05 }] });
  });
```

`exportMotion.test.ts`, inside `describe("remapTimelineForRatio")`, modelled on its first case:

```ts
  it("keeps a keyframe's path while delta-shifting its x/y", () => {
    const ov = makeOverlay({ x: 0.02, y: 0.02, width: 0.2, height: 0.1 });
    const snapshot = makeSnapshot([ov]);
    const remappedOverlays = remapSnapshotForRatio(snapshot, 1080, 1920);
    const timeline: MotionTimeline = {
      version: 1,
      duration_ms: 500,
      fps: 30,
      tracks: [
        {
          kind: "overlay",
          overlay_id: ov.id,
          keyframes: [
            { t_ms: 0, props: { x: ov.x - 0.15, y: ov.y }, easing: "linear" },
            { t_ms: 500, props: { x: ov.x, y: ov.y }, easing: "out", path: { points: [{ dx: -0.075, dy: -0.06 }] } },
          ],
        },
      ],
    };
    const out = remapTimelineForRatio(timeline, snapshot.overlays, remappedOverlays);
    expect(out.tracks[0].keyframes[1].path).toEqual({ points: [{ dx: -0.075, dy: -0.06 }] });
    expect(out.tracks[0].keyframes[1].props.x).toBeCloseTo(remappedOverlays[0].x, 10);
  });
```

- [ ] **Step 2: Run to verify**

Run: `bun test src/lib/video-editor/templates.test.ts src/lib/video-editor/cloneTrackForOverlay.test.ts src/components/studio/kv-generator/motion/exportMotion.test.ts`
Expected: the two template cases FAIL; clone and remap cases PASS already (they are regression guards).

- [ ] **Step 3: Implement the template passthrough**

`MotionTemplateKeyframe` gains `path?: MotionPath;` (import the type). In `normalizeTrackToTemplate`'s returned object add `...(k.path !== undefined ? { path: k.path } : {}),` beside the `label` spread. In `bakeTemplateToTrack`, before `keyframes.push`, add:

```ts
    let path: MotionPath | undefined;
    if (k.path !== undefined) {
      if (!Array.isArray(k.path.points)) return null;
      for (const p of k.path.points) {
        if (!Number.isFinite(p?.dx) || !Number.isFinite(p?.dy)) return null;
      }
      path = { points: k.path.points.map((p) => ({ dx: p.dx, dy: p.dy })) };
    }
```

and add `...(path !== undefined ? { path } : {}),` to the pushed object.

- [ ] **Step 4: Run the tests**

Run: the same three files. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lib/video-editor/templates.ts src/lib/video-editor/templates.test.ts src/lib/video-editor/cloneTrackForOverlay.test.ts src/components/studio/kv-generator/motion/exportMotion.test.ts
git commit -m "feat(video-editor): path survives templates; guard clone + tile remap

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: `applyPathEdit` — every popover/handle write as one pure function

**Files:**
- Create: `src/lib/video-editor/pathEdit.ts`
- Test: `src/lib/video-editor/pathEdit.test.ts`

**Interfaces:**
- Produces:

```ts
export type PathPatch =
  | { kind: "points"; points: MotionPathPoint[] }
  | { kind: "endpoint"; which: "start" | "end"; x: number; y: number }
  | { kind: "duration"; durationMs: number }
  | { kind: "easing"; easing: MotionEasing }
  | { kind: "delete" };

/** The segment a Path popover/handle set operates on: the keyframe carrying
 *  the path (`endMs`) and the x/y keyframe before it (`startMs`). */
export type PathRef = { trackId: string; endMs: number };

export function findPathSegment(timeline, ref): { start: MotionKeyframe; end: MotionKeyframe } | null;
export function applyPathEdit(timeline: MotionTimeline, ref: PathRef, patch: PathPatch): MotionTimeline;
```

- [ ] **Step 1: Write the failing tests**

```ts
import { describe, expect, it } from "bun:test";
import { applyPathEdit, findPathSegment } from "./pathEdit";
import { DEFAULT_TIMELINE } from "./timeline";
import type { MotionKeyframe, MotionTimeline } from "./timeline";

const start: MotionKeyframe = { t_ms: 0, props: { x: 0.1, y: 0.5, scale: 0.6 }, easing: "linear", label: "Path" };
const end: MotionKeyframe = {
  t_ms: 500,
  props: { x: 0.7, y: 0.5, scale: 1 },
  easing: "out",
  label: "Path",
  path: { points: [{ dx: -0.3, dy: -0.2 }] },
};
const later: MotionKeyframe = { t_ms: 2000, props: { opacity: 0.5 }, easing: "linear" };
const tl = (): MotionTimeline => ({
  ...DEFAULT_TIMELINE(),
  tracks: [{ kind: "overlay", overlay_id: "ov1", keyframes: [start, end, later] }],
});
const ref = { trackId: "ov1", endMs: 500 };
const at = (t: MotionTimeline, ms: number) => t.tracks[0].keyframes.find((k) => k.t_ms === ms)!;

describe("findPathSegment", () => {
  it("returns the path keyframe and the x/y keyframe before it", () => {
    const seg = findPathSegment(tl(), ref)!;
    expect(seg.start.t_ms).toBe(0);
    expect(seg.end.t_ms).toBe(500);
  });
  it("null when the keyframe has no path or no predecessor", () => {
    expect(findPathSegment(tl(), { trackId: "ov1", endMs: 2000 })).toBeNull();
    const noPrev = { ...tl(), tracks: [{ ...tl().tracks[0], keyframes: [end] }] };
    expect(findPathSegment(noPrev, ref)).toBeNull();
  });
});

describe("applyPathEdit", () => {
  it("points: replaces the deltas only", () => {
    const out = applyPathEdit(tl(), ref, { kind: "points", points: [{ dx: 0, dy: -0.1 }] });
    expect(at(out, 500).path).toEqual({ points: [{ dx: 0, dy: -0.1 }] });
    expect(at(out, 500).props).toEqual(end.props);
  });

  it("endpoint end: moves x/y, leaves deltas (whole curve translates)", () => {
    const out = applyPathEdit(tl(), ref, { kind: "endpoint", which: "end", x: 0.8, y: 0.6 });
    expect(at(out, 500).props).toEqual({ x: 0.8, y: 0.6, scale: 1 });
    expect(at(out, 500).path).toEqual(end.path);
  });

  it("endpoint start: moves the start keyframe's x/y", () => {
    const out = applyPathEdit(tl(), ref, { kind: "endpoint", which: "start", x: 0, y: 0 });
    expect(at(out, 0).props).toEqual({ x: 0, y: 0, scale: 0.6 });
  });

  it("duration: rescales the segment from its start, clamped by the neighbour", () => {
    const out = applyPathEdit(tl(), ref, { kind: "duration", durationMs: 1000 });
    expect(at(out, 1000).path).toEqual(end.path);
    expect(out.tracks[0].keyframes.some((k) => k.t_ms === 500)).toBe(false);
    // Cannot cross the keyframe at 2000 (1ms clearance).
    const capped = applyPathEdit(tl(), ref, { kind: "duration", durationMs: 5000 });
    expect(Math.max(...capped.tracks[0].keyframes.map((k) => k.t_ms).filter((t) => t < 2000))).toBe(1999);
  });

  it("easing: writes the END keyframe's easing", () => {
    const out = applyPathEdit(tl(), ref, { kind: "easing", easing: "in-out" });
    expect(at(out, 500).easing).toBe("in-out");
    expect(at(out, 0).easing).toBe("linear");
  });

  it("delete: strips x/y (and so the path) from both keyframes, keeping other props", () => {
    const out = applyPathEdit(tl(), ref, { kind: "delete" });
    expect(at(out, 0).props).toEqual({ scale: 0.6 });
    expect(at(out, 500).props).toEqual({ scale: 1 });
    expect(at(out, 500).path).toBeUndefined();
    expect(at(out, 500).label).toBeUndefined();
  });

  it("delete drops a keyframe left with no props", () => {
    const only = { ...tl(), tracks: [{ ...tl().tracks[0], keyframes: [
      { t_ms: 0, props: { x: 0.1, y: 0.5 }, easing: "linear" as const },
      { ...end, props: { x: 0.7, y: 0.5 } },
    ] }] };
    const out = applyPathEdit(only, ref, { kind: "delete" });
    expect(out.tracks[0].keyframes).toEqual([]);
  });

  it("returns the same timeline for an unknown ref", () => {
    const t = tl();
    expect(applyPathEdit(t, { trackId: "nope", endMs: 500 }, { kind: "easing", easing: "in" })).toBe(t);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/lib/video-editor/pathEdit.test.ts`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement**

```ts
import { stretchSegmentKeyframes, trackSegments } from "./blocks";
import { stripProps } from "./timeline";
import type {
  MotionEasing,
  MotionKeyframe,
  MotionPathPoint,
  MotionTimeline,
  MotionTrack,
} from "./timeline";

export type PathPatch =
  | { kind: "points"; points: MotionPathPoint[] }
  | { kind: "endpoint"; which: "start" | "end"; x: number; y: number }
  | { kind: "duration"; durationMs: number }
  | { kind: "easing"; easing: MotionEasing }
  | { kind: "delete" };

/** Which path: the track and the keyframe that CARRIES it. Its start is
 *  derived (the previous x/y keyframe), never stored — the same rule the
 *  sampler uses, so the popover and the playback agree on what the curve is. */
export type PathRef = { trackId: string; endMs: number };

function findTrack(timeline: MotionTimeline, trackId: string): MotionTrack | undefined {
  return timeline.tracks.find((t) => t.kind === "overlay" && t.overlay_id === trackId);
}

const hasXY = (k: MotionKeyframe) => k.props.x !== undefined && k.props.y !== undefined;

export function findPathSegment(
  timeline: MotionTimeline,
  ref: PathRef
): { start: MotionKeyframe; end: MotionKeyframe } | null {
  const track = findTrack(timeline, ref.trackId);
  if (!track) return null;
  const end = track.keyframes.find((k) => k.t_ms === ref.endMs);
  if (!end || !end.path || !hasXY(end)) return null;
  let start: MotionKeyframe | null = null;
  for (const k of track.keyframes) {
    if (k.t_ms < ref.endMs && hasXY(k) && (!start || k.t_ms > start.t_ms)) start = k;
  }
  return start ? { start, end } : null;
}

function mapTrack(
  timeline: MotionTimeline,
  trackId: string,
  fn: (keyframes: MotionKeyframe[]) => MotionKeyframe[]
): MotionTimeline {
  return {
    ...timeline,
    tracks: timeline.tracks.map((t) =>
      t.kind === "overlay" && t.overlay_id === trackId ? { ...t, keyframes: fn(t.keyframes) } : t
    ),
  };
}

/** One edit to one path, as the popover and the canvas handles express it.
 *  Immutable; the untouched timeline comes back for a ref that no longer
 *  resolves (the popover may outlive an undo). */
export function applyPathEdit(
  timeline: MotionTimeline,
  ref: PathRef,
  patch: PathPatch
): MotionTimeline {
  const seg = findPathSegment(timeline, ref);
  if (!seg) return timeline;
  const { start, end } = seg;

  switch (patch.kind) {
    case "points":
      return mapTrack(timeline, ref.trackId, (kfs) =>
        kfs.map((k) => (k === end ? { ...k, path: { points: patch.points } } : k))
      );
    case "endpoint": {
      const target = patch.which === "start" ? start : end;
      return mapTrack(timeline, ref.trackId, (kfs) =>
        kfs.map((k) =>
          k === target ? { ...k, props: { ...k.props, x: patch.x, y: patch.y } } : k
        )
      );
    }
    case "easing":
      return mapTrack(timeline, ref.trackId, (kfs) =>
        kfs.map((k) => (k === end ? { ...k, easing: patch.easing } : k))
      );
    case "duration": {
      // The bar's own segment (per `trackSegments`) is what the stretch op
      // understands — it clamps against the neighbours exactly as an edge
      // drag does, so the popover cannot push a path through the next block.
      const track = findTrack(timeline, ref.trackId)!;
      const seg2 = trackSegments(track).find(
        (s) => s.startMs <= start.t_ms && s.endMs >= end.t_ms
      );
      if (!seg2) return timeline;
      const newEnd = seg2.startMs + Math.max(1, Math.round(patch.durationMs));
      return stretchSegmentKeyframes(
        timeline, ref.trackId, seg2.startMs, seg2.endMs, seg2.startMs, newEnd
      );
    }
    case "delete":
      return mapTrack(timeline, ref.trackId, (kfs) =>
        kfs
          .map((k) => {
            if (k !== start && k !== end) return k;
            const { label: _l, ...rest } = stripProps(k, ["x", "y"]);
            void _l;
            return rest;
          })
          .filter((k) => Object.keys(k.props).length > 0)
      );
  }
}
```

If `blocks.ts` does not export `stretchSegmentKeyframes` under that exact name, use the name it exports (Task 7 verified `export function stretchSegmentKeyframes(timeline, overlayId, segStart, segEnd, newStartMs, newEndMs)` at `blocks.ts:616`).

- [ ] **Step 4: Run the tests**

Run: `bun test src/lib/video-editor/pathEdit.test.ts src/lib/video-editor/importBoundary.test.ts`
Expected: PASS. If the "duration" clamp assertion disagrees with `stretchSegmentKeyframes`'s clearance rule, read `blocks.ts:616-660` and align the expected value with **its** rule (1 ms clearance is what its doc says) — do not weaken the test to `toBeLessThan`.

- [ ] **Step 5: Commit**

```bash
git add src/lib/video-editor/pathEdit.ts src/lib/video-editor/pathEdit.test.ts
git commit -m "feat(video-editor): applyPathEdit — points, endpoints, duration, easing, delete

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: Editor state — `activePath` + `editPath`

**Files:**
- Modify: `src/components/studio/kv-generator/motion/useMotionEditorState.ts` (beside `applyBuild`, ~line 857; the returned object ~line 1200)
- Test: `src/components/studio/kv-generator/motion/useMotionEditorState.path.test.ts` (new; copy the fixture/wrapper block from `useMotionEditorState.build.test.ts` lines 1-60 verbatim)

**Interfaces:**
- Produces on the hook's return: `activePath: PathRef | null`, `setActivePath(ref: PathRef | null): void`, `editPath(ref: PathRef, patch: PathPatch, coalesce?: string): void`. `editPath` pushes through `push(next, coalesce)` (one undo step; a drag passes a label so its moves collapse). When a `duration` patch moves the end keyframe, `activePath.endMs` follows it.

- [ ] **Step 1: Write the failing test**

```ts
// (fixture + qcWrapper + makeProject copied from useMotionEditorState.build.test.ts;
//  makeProject's timeline must contain:)
//    tracks: [{ kind: "overlay", overlay_id: "ov1", keyframes: [
//      { t_ms: 0, props: { x: 0.1, y: 0.2 }, easing: "linear", label: "Path" },
//      { t_ms: 500, props: { x: 0.4, y: 0.2 }, easing: "out", label: "Path",
//        path: { points: [{ dx: -0.15, dy: -0.06 }] } },
//    ] }]

describe("editPath", () => {
  it("applies a patch as one undo step and tracks the end keyframe on duration change", () => {
    const { result } = renderHook(
      () => useMotionEditorState({ project: makeProject(), autosave: false }),
      { wrapper: qcWrapper }
    );
    act(() => result.current.setActivePath({ trackId: "ov1", endMs: 500 }));
    act(() => result.current.editPath({ trackId: "ov1", endMs: 500 }, { kind: "duration", durationMs: 800 }));
    expect(result.current.activePath).toEqual({ trackId: "ov1", endMs: 800 });
    const end = result.current.timeline.tracks[0].keyframes.find((k) => k.t_ms === 800);
    expect(end?.path).toEqual({ points: [{ dx: -0.15, dy: -0.06 }] });

    act(() => result.current.undo());
    expect(result.current.timeline.tracks[0].keyframes.some((k) => k.t_ms === 500)).toBe(true);
  });

  it("coalesces successive point drags under one label", () => {
    const { result } = renderHook(
      () => useMotionEditorState({ project: makeProject(), autosave: false }),
      { wrapper: qcWrapper }
    );
    const ref = { trackId: "ov1", endMs: 500 };
    act(() => result.current.editPath(ref, { kind: "points", points: [{ dx: 0, dy: -0.1 }] }, "path:ov1:500:1"));
    act(() => result.current.editPath(ref, { kind: "points", points: [{ dx: 0, dy: -0.2 }] }, "path:ov1:500:1"));
    act(() => result.current.undo());
    const end = result.current.timeline.tracks[0].keyframes.find((k) => k.t_ms === 500);
    expect(end?.path).toEqual({ points: [{ dx: -0.15, dy: -0.06 }] });
  });

  it("clears activePath on delete", () => {
    const { result } = renderHook(
      () => useMotionEditorState({ project: makeProject(), autosave: false }),
      { wrapper: qcWrapper }
    );
    const ref = { trackId: "ov1", endMs: 500 };
    act(() => result.current.setActivePath(ref));
    act(() => result.current.editPath(ref, { kind: "delete" }));
    expect(result.current.activePath).toBeNull();
  });
});
```

Check how the existing build test calls `useMotionEditorState` (its exact options object) and mirror it.

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/components/studio/kv-generator/motion/useMotionEditorState.path.test.ts`
Expected: FAIL — `setActivePath` is not a function.

- [ ] **Step 3: Implement**

Beside `applyBuild`:

```ts
  // The path whose handles are on the canvas and whose popover is open.
  // Cleared when the popover closes, the layer changes, or the path is
  // deleted. `endMs` identifies the carrying keyframe; a duration edit
  // moves that keyframe, so the ref follows it (below).
  const [activePath, setActivePath] = useState<PathRef | null>(null);

  const editPath = useCallback(
    (ref: PathRef, patch: PathPatch, coalesce?: string) => {
      const next = applyPathEdit(timeline, ref, patch);
      if (next === timeline) return;
      push(next, coalesce);
      if (patch.kind === "delete") {
        setActivePath((cur) =>
          cur && cur.trackId === ref.trackId && cur.endMs === ref.endMs ? null : cur
        );
      } else if (patch.kind === "duration") {
        const track = next.tracks.find(
          (t) => t.kind === "overlay" && t.overlay_id === ref.trackId
        );
        const moved = track?.keyframes.find((k) => k.path !== undefined && k.t_ms !== ref.endMs && k.label === PATH_LABEL);
        const stillThere = track?.keyframes.some((k) => k.t_ms === ref.endMs && k.path !== undefined);
        if (!stillThere && moved) {
          setActivePath((cur) =>
            cur && cur.trackId === ref.trackId && cur.endMs === ref.endMs
              ? { trackId: ref.trackId, endMs: moved.t_ms }
              : cur
          );
        }
      }
    },
    [timeline, push]
  );
```

Imports: `applyPathEdit`, `type PathPatch`, `type PathRef` from `@/lib/video-editor/pathEdit`; `PATH_LABEL` from `@/lib/video-editor/presets`. Add `activePath, setActivePath, editPath` to the returned object. Also clear it where the selected track changes: find `setSelectedKeyframe` calls that switch `trackId` (e.g. `selectTrack`) — simplest is a `useEffect` keyed on `selectedKeyframe?.trackId` that sets `activePath` to `null` when the track differs from `activePath.trackId`.

- [ ] **Step 4: Run the tests**

Run: `bun test src/components/studio/kv-generator/motion/useMotionEditorState.path.test.ts src/components/studio/kv-generator/motion/useMotionEditorState.build.test.ts src/components/studio/kv-generator/motion/useMotionEditorState.test.ts`
Expected: PASS. If the duration case's "moved" lookup is ambiguous because the track has a second Path, narrow it: the moved keyframe is the one whose `t_ms` equals `seg.startMs + durationMs` — compute that via `findPathSegment(timeline, ref)` before the push and use it instead of the label scan.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/motion/useMotionEditorState.ts src/components/studio/kv-generator/motion/useMotionEditorState.path.test.ts
git commit -m "feat(kv-motion): activePath + editPath in the editor state

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 9: Dock — Build exclusivity + the Path popover

**Files:**
- Create: `src/components/video-editor/PathSegmentPopover.tsx`
- Modify: `src/components/video-editor/BlockTrackRow.tsx` (`SlotPlaceholder` toggle ~line 933; `SegmentBar` `handleBodyClick` ~line 351 and its `contextMenu` sibling; `SegmentBarProps`; `BlockTrackRowProps`)
- Modify: `src/components/video-editor/types.ts` (`TimelineDockProps`, after `onApplyBuild`)
- Modify: `src/components/video-editor/TimelineDock.tsx` (pass-through to `BlockTrackRow`)
- Test: `src/components/video-editor/TimelineDock.pathpopover.test.tsx` (new; copy `renderDock`/`body` helpers from `TimelineDock.buildtab.test.tsx` lines 1-95)
- Test: `src/components/video-editor/TimelineDock.buildtab.test.tsx` (one exclusivity case)

**Interfaces:**
- `TimelineDockProps` gains:

```ts
  /** The path whose popover is open, or null. Owned by the host (it also
   *  drives the canvas handles), so the dock only reports opens/closes. */
  activePath?: PathRef | null;
  onSetActivePath?: (ref: PathRef | null) => void;
  /** One edit to the active path — see `applyPathEdit`. */
  onEditPath?: (ref: PathRef, patch: PathPatch) => void;
```

- `PathSegmentPopover` props: `{ ref: PathRef; durationMs: number; easing: MotionEasing; anchor: { x: number; y: number }; onEdit: (patch: PathPatch) => void; onClose: () => void; testIdPrefix: string }`.
- Test ids: `path-popover`, `path-popover-duration` (input, seconds), `path-popover-ease` (button opening the easing menu; items `path-popover-ease-<value>`), `path-popover-add-point`, `path-popover-delete`.

- [ ] **Step 1: Write the failing tests**

`TimelineDock.buildtab.test.tsx` — add:

```ts
  it("picking Path deselects Move and vice versa (exclusive group)", () => {
    const h = renderDock();
    fireEvent.click(body().getByTestId("slot-placeholder-ov1-in"));
    fireEvent.click(body().getByTestId("slot-in-tab-build"));
    fireEvent.click(body().getByTestId("slot-in-build-move"));
    fireEvent.click(body().getByTestId("slot-in-build-scale"));
    fireEvent.click(body().getByTestId("slot-in-build-path"));
    fireEvent.click(body().getByTestId("slot-in-build-add"));
    expect(h.onApplyBuild).toHaveBeenCalledWith("ov1", "in", ["path", "scale"], 0);
  });
```

(`renderDock` builds `buildChannels` from a fixed list — make sure that list includes `{ id: "path", label: "Path", … }` first; if it hard-codes four ids, add path.)

`TimelineDock.pathpopover.test.tsx`:

```ts
// helpers copied from TimelineDock.buildtab.test.tsx, with renderDock's
// timeline replaced by:
//   tracks: [{ kind: "overlay", overlay_id: "ov1", keyframes: [
//     { t_ms: 0, props: { x: 0.1, y: 0.2 }, easing: "linear", label: "Path" },
//     { t_ms: 500, props: { x: 0.4, y: 0.2 }, easing: "out", label: "Path",
//       path: { points: [{ dx: -0.15, dy: -0.06 }] } },
//   ] }]
// and renderDock accepting overrides for activePath / onSetActivePath / onEditPath.

describe("Path popover", () => {
  it("left-click on a Path bar reports the path as active; right-click still opens the segment menu", () => {
    const h = renderDock();
    fireEvent.click(body().getByTestId("segment-bar-ov1-0"));
    expect(h.onSetActivePath).toHaveBeenCalledWith({ trackId: "ov1", endMs: 500 });
    fireEvent.contextMenu(body().getByTestId("segment-bar-ov1-0"), { clientX: 10, clientY: 10 });
    expect(body().getByTestId("segment-context-anchor")).toBeTruthy();
  });

  it("renders the popover for the active path and routes each control to onEditPath", () => {
    const h = renderDock({ activePath: { trackId: "ov1", endMs: 500 } });
    const ref = { trackId: "ov1", endMs: 500 };
    expect(body().getByTestId("path-popover")).toBeTruthy();

    const duration = body().getByTestId("path-popover-duration") as HTMLInputElement;
    expect(duration.value).toBe("0.5");
    fireEvent.change(duration, { target: { value: "1.2" } });
    fireEvent.blur(duration);
    expect(h.onEditPath).toHaveBeenLastCalledWith(ref, { kind: "duration", durationMs: 1200 });

    fireEvent.click(body().getByTestId("path-popover-ease"));
    fireEvent.click(body().getByTestId("path-popover-ease-in-out"));
    expect(h.onEditPath).toHaveBeenLastCalledWith(ref, { kind: "easing", easing: "in-out" });

    fireEvent.click(body().getByTestId("path-popover-add-point"));
    const call = h.onEditPath.mock.calls.at(-1)!;
    expect(call[1].kind).toBe("points");
    expect(call[1].points).toHaveLength(2);

    fireEvent.click(body().getByTestId("path-popover-delete"));
    expect(h.onEditPath).toHaveBeenLastCalledWith(ref, { kind: "delete" });
  });

  it("does not open for a bar without a path", () => {
    const h = renderDock({ timelineOverride: /* same track but end keyframe without `path` and without label */ undefined });
    // Build the plain track inline if renderDock has no override; the point:
    fireEvent.click(body().getByTestId("segment-bar-ov1-0"));
    expect(h.onSetActivePath).not.toHaveBeenCalled();
  });
});
```

Check the segment bar's real `data-testid` in `BlockTrackRow.tsx` (search `data-testid={\`segment-`) and use that exact pattern; the dock's other tests already click it.

- [ ] **Step 2: Run to verify they fail**

Run: `bun test src/components/video-editor/TimelineDock.pathpopover.test.tsx src/components/video-editor/TimelineDock.buildtab.test.tsx`
Expected: FAIL — no `onSetActivePath`, no popover, `["move","path","scale"]`-ish for the exclusivity case.

- [ ] **Step 3: Exclusivity in `SlotPlaceholder`**

Replace the `onPick` toggle in the Build tabpanel:

```ts
                  onPick={(id) =>
                    setBuildSelection((prev) => {
                      const next = new Set(prev);
                      if (next.has(id)) {
                        next.delete(id);
                        return next;
                      }
                      // Both members of an exclusive group write the same
                      // props; turning one on turns its group-mates off.
                      for (const group of BUILD_EXCLUSIVE_GROUPS) {
                        if (!group.includes(id as never)) continue;
                        for (const other of group) next.delete(other);
                      }
                      next.add(id);
                      return next;
                    })
                  }
```

Import `BUILD_EXCLUSIVE_GROUPS` from `@/lib/video-editor/presets` (the file already imports preset ids from there).

- [ ] **Step 4: The popover component**

`src/components/video-editor/PathSegmentPopover.tsx`:

```tsx
"use client";

import { useEffect, useState } from "react";
import { CaretDown, Check, Plus, Trash } from "@phosphor-icons/react";
import { Input } from "@/components/frndos";
import { Button, Popover } from "@/components/frndos/v2";
import { cn } from "@/lib/utils";
import { EASING_OPTIONS } from "@/lib/video-editor/timeline";
import type { MotionEasing, MotionPathPoint } from "@/lib/video-editor/timeline";
import type { PathPatch, PathRef } from "@/lib/video-editor/pathEdit";
import { insertMidpoint } from "@/lib/video-editor/path";

type Props = {
  pathRef: PathRef;
  /** The segment as the engine sees it: needed to compute "Add new point"
   *  (the midpoint of the longest gap) without a second copy of the curve. */
  start: { x: number; y: number };
  end: { x: number; y: number };
  points: MotionPathPoint[];
  durationMs: number;
  easing: MotionEasing;
  /** Viewport point to anchor at — the click on the bar. Same virtual-anchor
   *  trick `SegmentBar`'s context menu uses. */
  anchor: { x: number; y: number };
  onEdit: (patch: PathPatch) => void;
  onClose: () => void;
};

/** The controls for one Path block: Duration, Ease, Add new point, Delete.
 *  The points themselves are shaped on the canvas (handles), never here. */
export function PathSegmentPopover({
  pathRef,
  start,
  end,
  points,
  durationMs,
  easing,
  anchor,
  onEdit,
  onClose,
}: Props) {
  void pathRef;
  const [draft, setDraft] = useState((durationMs / 1000).toFixed(1));
  useEffect(() => setDraft((durationMs / 1000).toFixed(1)), [durationMs]);
  const [easeOpen, setEaseOpen] = useState(false);

  const commitDuration = () => {
    const s = Number.parseFloat(draft);
    if (!Number.isFinite(s) || s <= 0) {
      setDraft((durationMs / 1000).toFixed(1));
      return;
    }
    const ms = Math.round(s * 1000);
    if (ms !== durationMs) onEdit({ kind: "duration", durationMs: ms });
  };

  return (
    <Popover
      key={`${anchor.x}-${anchor.y}`}
      open
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
    >
      <Popover.Trigger asChild>
        <button
          type="button"
          aria-hidden
          tabIndex={-1}
          style={{ position: "fixed", left: anchor.x, top: anchor.y, width: 1, height: 1, padding: 0, border: 0, background: "transparent", pointerEvents: "none" }}
        />
      </Popover.Trigger>
      <Popover.Content
        data-testid="path-popover"
        className="w-64 rounded-xl border border-white/10 bg-[var(--surface-inverse)] p-3 text-text-inverse shadow-xl"
      >
        <div className="mb-2 flex items-center justify-between">
          <span className="text-textSmMedium">Path</span>
          <button
            type="button"
            data-testid="path-popover-delete"
            aria-label="Delete path"
            onClick={() => onEdit({ kind: "delete" })}
            className="rounded-md p-1 text-text-inverse-subtlest hover:bg-white/[0.08] hover:text-text-inverse"
          >
            <Trash size={14} />
          </button>
        </div>
        <p className="mb-3 text-textXs text-text-inverse-subtlest">
          Drag the points on the canvas to shape the path.
        </p>
        <Input
          label="Duration (s)"
          size="compact"
          classNameInput="!text-textXs"
          data-testid="path-popover-duration"
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onBlur={commitDuration}
          onKeyDown={(e) => {
            if (e.key === "Enter") (e.target as HTMLInputElement).blur();
          }}
        />
        <div className="mt-2">
          <span className="text-textXsMedium text-text-inverse-subtlest">Ease</span>
          <Popover open={easeOpen} onOpenChange={setEaseOpen}>
            <Popover.Trigger asChild>
              <button
                type="button"
                data-testid="path-popover-ease"
                className="mt-1 flex w-full items-center justify-between rounded-lg border border-white/15 bg-white/[0.06] px-2 py-1.5 text-textXs"
              >
                {EASING_OPTIONS.find((o) => o.value === easing)?.label ?? easing}
                <CaretDown size={12} />
              </button>
            </Popover.Trigger>
            <Popover.Content className="rounded-lg border border-white/10 bg-[var(--surface-inverse)] p-1">
              {EASING_OPTIONS.map((o) => (
                <button
                  key={o.value}
                  type="button"
                  role="menuitem"
                  data-testid={`path-popover-ease-${o.value}`}
                  onClick={() => {
                    setEaseOpen(false);
                    if (o.value !== easing) onEdit({ kind: "easing", easing: o.value });
                  }}
                  className={cn(
                    "flex w-full items-center justify-between rounded-md px-2 py-1 text-textXs hover:bg-white/[0.08]",
                    o.value === easing && "text-text-inverse"
                  )}
                >
                  {o.label}
                  {o.value === easing && <Check size={12} />}
                </button>
              ))}
            </Popover.Content>
          </Popover>
        </div>
        <Button
          data-testid="path-popover-add-point"
          className="mt-3 w-full"
          onClick={() =>
            onEdit({ kind: "points", points: insertMidpoint(start, end, points) })
          }
        >
          <Plus size={14} /> Add new point
        </Button>
      </Popover.Content>
    </Popover>
  );
}
```

Match the `Input` / `Button` / `Popover` prop names to what `InspectorPanel.tsx` and `SegmentBar`'s menu actually use (open those two files; `Input` takes `label`, `size`, `classNameInput` per `InspectorPanel`). If `Input` does not forward `data-testid`, wrap it and put the test id on a `<div>` and query `within(...).getByRole("textbox")` in the test instead.

- [ ] **Step 5: Open it from a `Path` bar**

`BlockTrackRow.tsx`:

1. `BlockTrackRowProps` and `SegmentBarProps` gain `activePath?: PathRef | null; onSetActivePath?: (ref: PathRef | null) => void; onEditPath?: (ref: PathRef, patch: PathPatch) => void;` and `SegmentBar` additionally needs the track's keyframes: it already receives `label` — pass `pathEnd?: { endMs: number; start: {x,y}; end: {x,y}; points: MotionPathPoint[]; easing: MotionEasing; durationMs: number } | null`, computed by the parent for a segment whose earliest keyframe's `label === PATH_LABEL` (use `findPathSegment` from `pathEdit` with `endMs` = the segment's last keyframe carrying `path`).
2. In `handleBodyClick`, after `onSelectTrack(trackId)`: `if (pathEnd && onSetActivePath) { setPathAnchor({ x: e.clientX, y: e.clientY }); onSetActivePath({ trackId, endMs: pathEnd.endMs }); }` with `const [pathAnchor, setPathAnchor] = useState<{x:number;y:number}|null>(null)`.
3. Render, as a sibling of `contextMenu`:

```tsx
  const pathPopover =
    pathEnd &&
    activePath &&
    activePath.trackId === trackId &&
    activePath.endMs === pathEnd.endMs &&
    pathAnchor &&
    onEditPath ? (
      <PathSegmentPopover
        pathRef={activePath}
        start={pathEnd.start}
        end={pathEnd.end}
        points={pathEnd.points}
        durationMs={pathEnd.durationMs}
        easing={pathEnd.easing}
        anchor={pathAnchor}
        onEdit={(patch) => onEditPath(activePath, patch)}
        onClose={() => onSetActivePath?.(null)}
      />
    ) : null;
```

and include `{pathPopover}` wherever `{contextMenu}` is rendered (both the bar and still-point branches).

4. `TimelineDock.tsx`: destructure `activePath`, `onSetActivePath`, `onEditPath` from props and pass them to every `BlockTrackRow`. `types.ts`: add the three props (doc comments from **Interfaces** above); import `PathRef`, `PathPatch` types.

- [ ] **Step 6: Run the tests**

Run: `bun test src/components/video-editor/TimelineDock.pathpopover.test.tsx src/components/video-editor/TimelineDock.buildtab.test.tsx src/components/video-editor/TimelineDock.test.tsx src/components/video-editor/TimelineDock.slotmenu.test.tsx`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/components/video-editor/PathSegmentPopover.tsx src/components/video-editor/BlockTrackRow.tsx src/components/video-editor/TimelineDock.tsx src/components/video-editor/types.ts src/components/video-editor/TimelineDock.pathpopover.test.tsx src/components/video-editor/TimelineDock.buildtab.test.tsx
git commit -m "feat(video-editor): Path popover on the dock bar; Path/Move exclusive in Build

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 10: Onion-skin draws the curve

**Files:**
- Modify: `src/components/studio/kv-generator/motion/onionSkin.ts` (`OnionSkin`, `onionSkinFor`)
- Modify: `src/components/studio/kv-generator/motion/KvMotionTileStage.tsx` (`paintOnion`, the `Line` block ~line 570)
- Test: `src/components/studio/kv-generator/motion/onionSkin.test.ts` (add)

**Interfaces:**
- `OnionSkin` gains `polyline: { x: number; y: number }[]` — normalized top-left coordinates (same space as `props.x/y`), the motion path to draw: straight between plain x/y keyframes, `samplePath(…, 24)` between a Path pair. Empty when `path.length < 2`.

- [ ] **Step 1: Write the failing test**

```ts
  it("polyline curves between a path pair and is straight elsewhere", () => {
    const timeline: MotionTimeline = {
      ...DEFAULT_TIMELINE(),
      tracks: [{
        kind: "overlay", overlay_id: "ov1", keyframes: [
          { t_ms: 0, props: { x: 0.1, y: 0.5 }, easing: "linear" },
          { t_ms: 500, props: { x: 0.7, y: 0.5 }, easing: "out", path: { points: [{ dx: -0.3, dy: -0.2 }] } },
          { t_ms: 1000, props: { x: 0.7, y: 0.9 }, easing: "linear" },
        ],
      }],
    };
    const base = new Map([["ov1", { x: 0.1, y: 0.5, scale: 1, rotation: 0, opacity: 1 }]]);
    const skin = onionSkinFor(timeline, base, "ov1")!;
    // 25 samples for the curve (0..500) + the straight end point (1000).
    expect(skin.polyline).toHaveLength(26);
    expect(skin.polyline[0]).toEqual({ x: 0.1, y: 0.5 });
    expect(skin.polyline[24]).toEqual({ x: 0.7, y: 0.5 });
    expect(skin.polyline[25]).toEqual({ x: 0.7, y: 0.9 });
    expect(skin.polyline[12].y).toBeLessThan(0.5);
  });
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/components/studio/kv-generator/motion/onionSkin.test.ts`
Expected: FAIL — `polyline` undefined.

- [ ] **Step 3: Implement**

In `onionSkin.ts`, `OnionSkin` becomes `{ keyframes: OnionPose[]; path: OnionPose[]; polyline: { x: number; y: number }[] }`. In `onionSkinFor`, after `const path = …`:

```ts
  // The line to draw: the x/y keyframes in order, with a sampled curve in
  // place of the straight run wherever the destination carries a path.
  const xyKfs = track.keyframes
    .filter((k) => k.props.x !== undefined && k.props.y !== undefined)
    .sort((a, b) => a.t_ms - b.t_ms);
  const polyline: { x: number; y: number }[] = [];
  for (let i = 0; i < xyKfs.length; i++) {
    const k = xyKfs[i];
    const pt = { x: k.props.x!, y: k.props.y! };
    const prev = i > 0 ? xyKfs[i - 1] : null;
    if (prev && k.path && k.path.points.length > 0) {
      const curve = samplePath({ x: prev.props.x!, y: prev.props.y! }, pt, k.path.points, 24);
      polyline.push(...curve.slice(polyline.length === 0 ? 0 : 1));
    } else if (polyline.length === 0 || prev) {
      polyline.push(pt);
    }
  }
  return { keyframes, path, polyline: path.length >= 2 ? polyline : [] };
```

Import `samplePath` from `@/lib/video-editor/path`.

In `KvMotionTileStage.tsx` `paintOnion`, replace the `pts` computation so the Line follows `skin.polyline` (dots stay on `skin.path`):

```ts
      const pts = skin.polyline.flatMap((p) => {
        const c = poseCenter(ov, { ...skin.path[0].props, x: p.x, y: p.y }, tile.width, tile.height);
        return [c.x, c.y];
      });
```

- [ ] **Step 4: Run the tests**

Run: `bun test src/components/studio/kv-generator/motion/onionSkin.test.ts src/lib/video-editor/importBoundary.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/motion/onionSkin.ts src/components/studio/kv-generator/motion/onionSkin.test.ts src/components/studio/kv-generator/motion/KvMotionTileStage.tsx
git commit -m "feat(kv-motion): onion-skin path curves through a Path segment

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 11: Canvas handles + the layer-drag guard

The Konva part cannot run in jsdom; everything with a number in it lives in `pathHandles.ts` and is tested there. The stage wiring follows the Transformer's existing pattern exactly.

**Files:**
- Create: `src/components/studio/kv-generator/motion/pathHandles.ts`
- Test: `src/components/studio/kv-generator/motion/pathHandles.test.ts`
- Modify: `src/components/studio/kv-generator/motion/panHitTest.ts` (+ its test)
- Modify: `src/components/studio/kv-generator/motion/KvMotionTileStage.tsx`

**Interfaces:**
- Produces (`pathHandles.ts`):

```ts
export type ActivePathGeometry = {
  overlayId: string;
  endMs: number;
  /** Tile-space normalized top-left coords (already remapped for this tile). */
  start: { x: number; y: number };
  end: { x: number; y: number };
  points: MotionPathPoint[];
};
/** Handle centres in tile PIXELS: index 0 = start, 1..n = points, n+1 = end. */
export function handleCenters(g: ActivePathGeometry, ov: StudioOverlay, tileW: number, tileH: number): { x: number; y: number }[];
/** Inverse: a dropped handle centre (tile px) back to a normalized top-left pose. */
export function centerToPose(c: { x: number; y: number }, ov: StudioOverlay, tileW: number, tileH: number): { x: number; y: number };
/** The patch a handle drop produces. Endpoints move the keyframe; a middle
 *  handle rewrites the deltas (from the END — the start may also have moved). */
export function patchForHandleDrop(g: ActivePathGeometry, index: number, pose: { x: number; y: number }): PathPatch;
/** True when a layer drag at `playheadMs` would land inside a Path segment
 *  on `track` (strictly between the previous x/y keyframe and a path
 *  keyframe) — then the node is not draggable. */
export function layerDragBlocked(track: MotionTrack | null, playheadMs: number): boolean;
```

- `HitNodeLike` gains `name(): string`; `isPanBlockingHit` returns `true` for a node named `motion-path-handle`.
- `KvMotionTileStage` props gain `activePath?: ActivePathGeometry | null` and `onPathHandleDrop?: (index: number, pose: { x: number; y: number }, coalesce: string) => void`.

- [ ] **Step 1: Write the failing tests**

`pathHandles.test.ts`:

```ts
import { describe, expect, it } from "bun:test";
import type { StudioOverlay } from "@/types/studio";
import type { MotionTrack } from "@/lib/video-editor/timeline";
import { centerToPose, handleCenters, layerDragBlocked, patchForHandleDrop } from "./pathHandles";

const ov = { id: "ov1", width: 0.2, height: 0.1 } as StudioOverlay;
const g = {
  overlayId: "ov1",
  endMs: 500,
  start: { x: 0.1, y: 0.5 },
  end: { x: 0.7, y: 0.5 },
  points: [{ dx: -0.3, dy: -0.2 }],
};

describe("handleCenters", () => {
  it("start, points, end — centred like poseCenter", () => {
    const c = handleCenters(g, ov, 1000, 1000);
    expect(c).toEqual([
      { x: (0.1 + 0.1) * 1000, y: (0.5 + 0.05) * 1000 },
      { x: (0.4 + 0.1) * 1000, y: (0.3 + 0.05) * 1000 },
      { x: (0.7 + 0.1) * 1000, y: (0.5 + 0.05) * 1000 },
    ]);
  });
  it("centerToPose inverts handleCenters", () => {
    const [c] = handleCenters(g, ov, 1080, 1920);
    const p = centerToPose(c, ov, 1080, 1920);
    expect(p.x).toBeCloseTo(0.1, 12);
    expect(p.y).toBeCloseTo(0.5, 12);
  });
});

describe("patchForHandleDrop", () => {
  it("index 0 moves the start keyframe", () => {
    expect(patchForHandleDrop(g, 0, { x: 0, y: 0 })).toEqual({ kind: "endpoint", which: "start", x: 0, y: 0 });
  });
  it("last index moves the end keyframe", () => {
    expect(patchForHandleDrop(g, 2, { x: 1, y: 1 })).toEqual({ kind: "endpoint", which: "end", x: 1, y: 1 });
  });
  it("a middle index rewrites that delta from the end", () => {
    expect(patchForHandleDrop(g, 1, { x: 0.5, y: 0.2 })).toEqual({
      kind: "points",
      points: [{ dx: 0.5 - 0.7, dy: 0.2 - 0.5 }],
    });
  });
});

describe("layerDragBlocked", () => {
  const track: MotionTrack = {
    kind: "overlay", overlay_id: "ov1", keyframes: [
      { t_ms: 0, props: { x: 0.1, y: 0.5 }, easing: "linear" },
      { t_ms: 500, props: { x: 0.7, y: 0.5 }, easing: "out", path: { points: [{ dx: -0.3, dy: -0.2 }] } },
      { t_ms: 1000, props: { x: 0.7, y: 0.9 }, easing: "linear" },
    ],
  };
  it("blocks strictly inside the path window", () => {
    expect(layerDragBlocked(track, 250)).toBe(true);
  });
  it("does not block on the window's keyframes, outside it, or without a track", () => {
    expect(layerDragBlocked(track, 0)).toBe(false);
    expect(layerDragBlocked(track, 500)).toBe(false);
    expect(layerDragBlocked(track, 750)).toBe(false);
    expect(layerDragBlocked(null, 250)).toBe(false);
  });
});
```

`panHitTest.test.ts` — add:

```ts
  it("a path handle blocks the pan", () => {
    const handle = { getParent: () => null, getClassName: () => "Circle", draggable: () => true, name: () => "motion-path-handle" };
    expect(isPanBlockingHit(handle, new Set())).toBe(true);
  });
```

(and add `name: () => ""` to the file's existing fake nodes so they satisfy the widened type).

- [ ] **Step 2: Run to verify they fail**

Run: `bun test src/components/studio/kv-generator/motion/pathHandles.test.ts src/components/studio/kv-generator/motion/panHitTest.test.ts`
Expected: FAIL.

- [ ] **Step 3: Implement the pure helpers**

`pathHandles.ts`:

```ts
import { absolutePoints, toDeltas } from "@/lib/video-editor/path";
import type { PathPatch } from "@/lib/video-editor/pathEdit";
import type { MotionPathPoint, MotionTrack } from "@/lib/video-editor/timeline";
import type { StudioOverlay } from "@/types/studio";

export type ActivePathGeometry = {
  overlayId: string;
  endMs: number;
  start: { x: number; y: number };
  end: { x: number; y: number };
  points: MotionPathPoint[];
};

/** Same centre convention as `poseCenter` (applyTimeline.ts): the node's
 *  x/y is the overlay's visual centre, `(pose + size/2) * tile`. Kept as a
 *  local formula rather than importing `poseCenter` because that needs a
 *  full `MotionProps`, and a handle has only a position. */
function toCenter(p: { x: number; y: number }, ov: StudioOverlay, w: number, h: number) {
  return { x: (p.x + ov.width / 2) * w, y: (p.y + ov.height / 2) * h };
}

export function handleCenters(g: ActivePathGeometry, ov: StudioOverlay, tileW: number, tileH: number) {
  return [g.start, ...absolutePoints(g.end, g.points), g.end].map((p) => toCenter(p, ov, tileW, tileH));
}

export function centerToPose(c: { x: number; y: number }, ov: StudioOverlay, tileW: number, tileH: number) {
  return { x: c.x / tileW - ov.width / 2, y: c.y / tileH - ov.height / 2 };
}

export function patchForHandleDrop(g: ActivePathGeometry, index: number, pose: { x: number; y: number }): PathPatch {
  const last = g.points.length + 1;
  if (index <= 0) return { kind: "endpoint", which: "start", x: pose.x, y: pose.y };
  if (index >= last) return { kind: "endpoint", which: "end", x: pose.x, y: pose.y };
  const abs = absolutePoints(g.end, g.points);
  abs[index - 1] = pose;
  return { kind: "points", points: toDeltas(g.end, abs) };
}

/** Inside `(prevXY, pathEnd)` a layer drag would write an x/y keyframe that
 *  cuts the curve in two — so the node is made non-draggable there and the
 *  badge says to drag the points instead. On either keyframe, or anywhere
 *  else, dragging is the ordinary auto-keyframe it always was. */
export function layerDragBlocked(track: MotionTrack | null, playheadMs: number): boolean {
  if (!track) return false;
  const xy = track.keyframes
    .filter((k) => k.props.x !== undefined && k.props.y !== undefined)
    .sort((a, b) => a.t_ms - b.t_ms);
  for (let i = 1; i < xy.length; i++) {
    const end = xy[i];
    if (!end.path || end.path.points.length === 0) continue;
    if (playheadMs > xy[i - 1].t_ms && playheadMs < end.t_ms) return true;
  }
  return false;
}
```

`panHitTest.ts`: add `name(): string;` to `HitNodeLike`; in the loop, before the Transformer check: `if (n.name() === "motion-path-handle") return true;`.

- [ ] **Step 4: Run the tests**

Run: the two test files. Expected: PASS.

- [ ] **Step 5: Wire the stage** (no unit test — verified in Task 12's manual pass)

`KvMotionTileStage.tsx`:

1. Props: `activePath?: ActivePathGeometry | null; onPathHandleDrop?: (index: number, pose: { x: number; y: number }, coalesce: string) => void; layerDragBlockedId?: string | null;` (the overlay whose node must not be draggable right now, or null). Add refs mirroring the `onOverlayTransformedRef` pattern for `onPathHandleDrop`.
2. Draggable flag: wherever the code sets `node.draggable(focused && ov.payload.locked !== true)` (build ~line 258 and the `[focused]` effect ~line 420), make it `node.draggable(focused && ov.payload.locked !== true && ov.id !== layerDragBlockedId)`, and add `layerDragBlockedId` to that effect's deps.
3. Transformer: in `syncTransformer`, treat `activePath?.overlayId === selected` like `hidden` — destroy/skip the Transformer while a path on that overlay is active (Risks §2 of the spec). Add `activePath?.overlayId` to the selection effect's deps.
4. Handles effect — a new `useEffect` keyed on `[activePath, focused, playing, overlays, cameraScale]`, modelled on the onion effect:

```ts
  const pathNodesRef = useRef<Konva.Node[]>([]);
  useEffect(() => {
    const handle = builtRef.current;
    for (const n of pathNodesRef.current) n.destroy();
    pathNodesRef.current = [];
    const layer = handle?.stage?.getLayers()[0];
    if (!handle?.stage || !layer || !focused || playing || !activePath) {
      layer?.batchDraw();
      return;
    }
    const ov = overlays.find((o) => o.id === activePath.overlayId);
    if (!ov) return;
    let cancelled = false;
    void (async () => {
      const KonvaRuntime = (await import("konva")).default;
      if (cancelled || builtRef.current?.stage !== handle.stage) return;
      const k = inverseCameraScale(cameraScaleRef.current);
      const centers = handleCenters(activePath, ov, tile.width, tile.height);
      // Pose -> tile px, the same centre convention as `handleCenters`.
      const toPx = (p: { x: number; y: number }) => [
        (p.x + ov.width / 2) * tile.width,
        (p.y + ov.height / 2) * tile.height,
      ];
      const curvePts = samplePath(activePath.start, activePath.end, activePath.points, 32).flatMap(toPx);
      const curve = new KonvaRuntime.Line({
        name: "motion-path-curve",
        points: curvePts,
        stroke: "#ffffff",
        strokeWidth: 2 * k,
        shadowColor: "rgba(0,0,0,0.6)",
        shadowBlur: 2 * k,
        listening: false,
      });
      layer.add(curve);
      const added: Konva.Node[] = [curve];
      const last = centers.length - 1;
      centers.forEach((c, index) => {
        const isEndpoint = index === 0 || index === last;
        const dot = new KonvaRuntime.Circle({
          name: "motion-path-handle",
          x: c.x,
          y: c.y,
          radius: 6 * k,
          fill: isEndpoint ? "rgba(0,0,0,0.6)" : "#ffffff",
          stroke: "#ffffff",
          strokeWidth: 2 * k,
          draggable: true,
        });
        dot.on("dragmove", () => {
          // Live redraw: rebuild the curve through the dragged handle.
          const live = centers.map((cc, i) => (i === index ? { x: dot.x(), y: dot.y() } : cc));
          const poses = live.map((cc) => centerToPose(cc, ov, tile.width, tile.height));
          const s = poses[0], e = poses[last];
          const mids = poses.slice(1, last);
          curve.points(samplePath(s, e, toDeltas(e, mids), 32).flatMap(toPx));
          layer.batchDraw();
        });
        dot.on("dragend", () => {
          const pose = centerToPose({ x: dot.x(), y: dot.y() }, ov, tile.width, tile.height);
          onPathHandleDropRef.current?.(index, pose, `path:${ov.id}:${activePath.endMs}:${index}`);
        });
        dot.on("click", (e) => { e.cancelBubble = true; selectedHandleRef.current = index; });
        layer.add(dot);
        added.push(dot);
      });
      pathNodesRef.current = added;
      layer.batchDraw();
    })();
    return () => { cancelled = true; };
  }, [activePath, focused, playing, overlays, tile.width, tile.height, cameraScale]);
```

5. Zoom restyle: in the existing `[cameraScale]` effect that restyles onion nodes, also restyle `motion-path-curve` (strokeWidth `2*k`, shadowBlur `2*k`) and `motion-path-handle` (radius `6*k`, strokeWidth `2*k`) nodes from `pathNodesRef`.
6. Point deletion: a third prop `onPathPointRemove?: (pointIndex: number) => void` (index into `points`, i.e. handle index − 1). Add `const selectedHandleRef = useRef<number | null>(null)` (set by the handle `click` above, reset to `null` whenever the handles effect re-runs) and, in the handles effect, a `window` `keydown` listener removed in its cleanup:

```ts
      const onKey = (e: KeyboardEvent) => {
        if (e.key !== "Delete" && e.key !== "Backspace") return;
        const h = selectedHandleRef.current;
        if (h === null || h <= 0 || h >= last) return; // endpoints are keyframes, not points
        e.preventDefault();
        onPathPointRemoveRef.current?.(h - 1);
      };
      window.addEventListener("keydown", onKey);
      pathKeyCleanupRef.current = () => window.removeEventListener("keydown", onKey);
```

   with `pathKeyCleanupRef.current?.()` called at the top of the effect and in its cleanup, and an `onPathPointRemoveRef` mirroring the other callback refs.
7. Teardown: reset `pathNodesRef.current = []` in the block that resets `onionNodesRef` (~line 361).

Imports: `handleCenters`, `centerToPose`, `type ActivePathGeometry` from `./pathHandles`; `samplePath`, `toDeltas` from `@/lib/video-editor/path`.

- [ ] **Step 6: Typecheck the touched files**

Run: `bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -E "KvMotionTileStage|pathHandles|panHitTest" || echo "no new errors in touched files"`
Expected: no lines (the repo has a ~777-error baseline elsewhere; only the grep'd files matter).

- [ ] **Step 7: Commit**

```bash
git add src/components/studio/kv-generator/motion/pathHandles.ts src/components/studio/kv-generator/motion/pathHandles.test.ts src/components/studio/kv-generator/motion/panHitTest.ts src/components/studio/kv-generator/motion/panHitTest.test.ts src/components/studio/kv-generator/motion/KvMotionTileStage.tsx
git commit -m "feat(kv-motion): path handles on the focused tile; layer drag blocked inside a path

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 12: Editor wiring, analytics, manual verification

**Files:**
- Modify: `src/components/studio/kv-generator/motion/KvMotionEditor.tsx` (build cards ~line 445; onion/badge block ~line 1004; the `<KvMotionTileStage>` render; the `<TimelineDock>` render ~line 1907)
- Modify: `src/lib/analytics/kv-generator-events.ts` (after `trackKvMotionBuildApplied`, ~line 1150)
- Test: `src/lib/analytics/kv-generator-events.motionTransform.test.ts` (one case, same shape as the file's existing ones)

**Interfaces:**
- Produces: `trackKvMotionPathEdited(p: { project_id: string; action: "drag_point" | "drag_endpoint" | "add_point" | "remove_point" | "duration" | "ease" | "delete" })` → `kv_generator.motion_path_edited`.

- [ ] **Step 1: Analytics event (test first)**

Add to the analytics test file, mirroring its existing `safeCapture` spy pattern:

```ts
  it("motion_path_edited carries project_id + action", () => {
    trackKvMotionPathEdited({ project_id: "p1", action: "add_point" });
    expect(captureSpy).toHaveBeenLastCalledWith("kv_generator.motion_path_edited", { project_id: "p1", action: "add_point" });
  });
```

Then in `kv-generator-events.ts`:

```ts
export type KvMotionPathAction =
  | "drag_point" | "drag_endpoint" | "add_point" | "remove_point"
  | "duration" | "ease" | "delete";

export interface KvMotionPathEditedProps {
  project_id: string;
  action: KvMotionPathAction;
}

/** Whether people SHAPE a path after adding one is the question that decides
 *  whether the canvas handles were worth building: a Path that is only ever
 *  added with its default curve is a preset wearing a costume. */
export const trackKvMotionPathEdited = (p: KvMotionPathEditedProps) =>
  safeCapture("kv_generator.motion_path_edited", p);
```

Run: `bun test src/lib/analytics/kv-generator-events.motionTransform.test.ts` → PASS.

- [ ] **Step 2: Build card subtitle**

In the `buildChannels` memo, add `...(id === "path" ? { subtitle: "New" } : {})` to each card object.

- [ ] **Step 3: Active path in tile space**

After the `onion` memo:

```ts
  // The active path projected onto the FOCUSED tile: deltas are aspect-
  // invariant, so only the two endpoints come from the tile's remapped
  // timeline (the same one the sampler and onion-skin read).
  const activePathGeometry = useMemo<ActivePathGeometry | null>(() => {
    const ref = state.activePath;
    if (!ref || !focusedTileTimeline) return null;
    const seg = findPathSegment(focusedTileTimeline.timeline, ref);
    if (!seg) return null;
    return {
      overlayId: ref.trackId,
      endMs: ref.endMs,
      start: { x: seg.start.props.x!, y: seg.start.props.y! },
      end: { x: seg.end.props.x!, y: seg.end.props.y! },
      points: seg.end.path!.points,
    };
  }, [state.activePath, focusedTileTimeline]);

  // A handle drop arrives in TILE space; the master timeline wants master
  // space. The remap is a pure delta-shift of x/y (remapTimelineForRatio),
  // so master = tile − (tileOverlay − masterOverlay). Middle points are
  // deltas and need no conversion, but `patchForHandleDrop` computes them
  // against the tile's end pose, which is what the tile geometry holds — so
  // convert the POSE first, then build the patch against master geometry.
  const handlePathHandleDrop = useCallback(
    (index: number, tilePose: { x: number; y: number }, coalesce: string) => {
      const ref = stateRef.current.activePath;
      if (!ref) return;
      const tileOv = focusedTileOverlays.find((o) => o.id === ref.trackId);
      const masterOv = overlays.find((o) => o.id === ref.trackId);
      if (!tileOv || !masterOv) return;
      const pose = { x: tilePose.x - (tileOv.x - masterOv.x), y: tilePose.y - (tileOv.y - masterOv.y) };
      const seg = findPathSegment(stateRef.current.timeline, ref);
      if (!seg) return;
      const master: ActivePathGeometry = {
        overlayId: ref.trackId, endMs: ref.endMs,
        start: { x: seg.start.props.x!, y: seg.start.props.y! },
        end: { x: seg.end.props.x!, y: seg.end.props.y! },
        points: seg.end.path!.points,
      };
      const patch = patchForHandleDrop(master, index, pose);
      stateRef.current.editPath(ref, patch, coalesce);
      trackKvMotionPathEdited({
        project_id: project.id,
        action: patch.kind === "endpoint" ? "drag_endpoint" : "drag_point",
      });
    },
    [project.id, overlays, focusedTileOverlays]
  );
```

Find what the editor calls the focused tile's projected overlays (the value it passes as `overlays` to the focused `<KvMotionTileStage>`) and use that name for `focusedTileOverlays`; `overlays` is the master snapshot's list the editor already holds. Confirm `stateRef.current` exposes `activePath`, `editPath`, `timeline` (it is the whole hook result).

- [ ] **Step 4: Badge + drag guard**

Extend the `badge` memo: after computing `track`, `if (layerDragBlocked(track, state.playheadMs)) return { text: "Drag the path points to reshape", kind: "between" as const };`. Pass to the focused stage: `activePath={activePathGeometry}`, `onPathHandleDrop={handlePathHandleDrop}`, `onPathPointRemove={(i) => { const ref = state.activePath; if (!ref) return; const seg = findPathSegment(state.timeline, ref); if (!seg) return; state.editPath(ref, { kind: "points", points: removePoint(seg.end.path!.points, i) }); trackKvMotionPathEdited({ project_id: project.id, action: "remove_point" }); }}`, `layerDragBlockedId={selectedTrackId && layerDragBlocked(selectedTrack, state.playheadMs) ? selectedTrackId : null}` (compute `selectedTrack` once beside the badge memo).

- [ ] **Step 5: Dock wiring**

On `<TimelineDock>`: `activePath={state.activePath}`, `onSetActivePath={state.setActivePath}`, and

```tsx
          onEditPath={(ref, patch) => {
            state.editPath(ref, patch);
            trackKvMotionPathEdited({
              project_id: projectId,
              action:
                patch.kind === "points" ? "add_point"
                : patch.kind === "duration" ? "duration"
                : patch.kind === "easing" ? "ease"
                : patch.kind === "delete" ? "delete"
                : "drag_endpoint",
            });
          }}
```

(The popover only ever sends `points` for "Add new point"; drags come through the stage path above, so `points` here means `add_point`.)

Imports: `findPathSegment` from `@/lib/video-editor/pathEdit`; `removePoint` from `@/lib/video-editor/path`; `layerDragBlocked`, `patchForHandleDrop`, `type ActivePathGeometry` from `./pathHandles`; `trackKvMotionPathEdited` from `@/lib/analytics/kv-generator-events`.

- [ ] **Step 6: Full suite + typecheck of touched files**

Run: `bun test src/lib/video-editor src/components/video-editor src/components/studio/kv-generator/motion src/lib/analytics`
Expected: everything passes except the 3 pre-existing `useTimelineCommands` cases.

Run: `bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -E "video-editor/(path|pathEdit|sample|blocks|presets|templates|timeline)\.ts|PathSegmentPopover|BlockTrackRow|TimelineDock\.tsx|types\.ts|kv-generator/motion/(KvMotionEditor|KvMotionTileStage|useMotionEditorState|onionSkin|pathHandles|panHitTest)" || echo clean`
Expected: `clean`.

- [ ] **Step 7: Commit**

```bash
git add src/components/studio/kv-generator/motion/KvMotionEditor.tsx src/lib/analytics/kv-generator-events.ts src/lib/analytics/kv-generator-events.motionTransform.test.ts
git commit -m "feat(kv-motion): wire Path — handles, popover, badge, analytics

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

- [ ] **Step 8: Manual verification** (dev server from this worktree; add a `wt-kv-motion-path` entry to the workspace-root `.claude/launch.json` shaped like `wt-build-tab`, then `preview_start`)

Walk through, on a KV file with at least one text layer, in Motion:

1. Empty `+ In` chip → **Build** → cards read Path (New) · Move · Rotate · Scale · Opacity. Pick Move then Path → Move deselects. Pick Scale too → **Add to In** → one bar labelled **Path** at 0–0.5 s; scrubbing shows the layer arcing in from the left (curved, not straight), scale popping.
2. Click the Path bar → popover: Duration `0.5`, Ease `Ease out`, **Add new point**, trash. Canvas: white curve with 3 handles (hollow endpoints, solid middle); Transformer gone from that layer.
3. Drag the middle handle → curve follows live → release → ⌘Z undoes in one step; onion-skin path is the same curve.
4. **Add new point** → 4 handles; click one middle handle, press Delete → 3 handles.
5. Duration `1.2` + Enter → bar ends at 1.2 s, curve unchanged; Ease `Ease in-out` → motion timing changes.
6. Scrub to 0.25 s, try to drag the layer → it does not move; badge reads **Drag the path points to reshape**. Corner scale handle is not there (path active) — close the popover (Esc) → Transformer returns, layer still not draggable at 0.25 s, badge unchanged; at 0.6 s the layer drags normally.
7. Empty `+ Emphasis` at 2 s → Build → Path → loop bar 2.0–2.6 s, visible as one bar (not two still points).
8. Multi-tile: add a 9:16 tile; the curve and handles land on the right spot on the focused 9:16; playback on both tiles curves.
9. Export MP4 → the motion in the file curves.
10. Right-click the Path bar → the old segment menu (Change motion / Delete) still opens.

Record any deviation as a follow-up in the spec's Risks section (a `docs(spec)` commit), not as a silent change.

---

## Self-review

- **Spec coverage:** §1 data model + invariant → Task 1; §2 curve math → Task 2; §3 sampler → Task 3; §4 channel, exclusivity, label, preview → Task 5 (+ Task 9 UI); §5 popover controls → Tasks 7, 9; §6 canvas handles, Transformer detach, pan guard, drag guard, badge, onion → Tasks 10, 11, 12; §7 carriers → Task 6 (templates needed a fix the spec assumed away — corrected here); Testing table → each task; Analytics → Task 12. Task 4 (`trackSegments`) is not in the spec — it surfaced while reading `blocks.ts` (an emphasis loop would never get a bar); the spec's Risks section should note it after implementation.
- **Placeholders:** none; every code step has the code. The one intentionally open lookup ("find what the editor calls the focused tile's overlays") names the exact thing to find.
- **Type consistency:** `PathRef {trackId,endMs}`, `PathPatch` (5 kinds), `ActivePathGeometry`, `MotionPathPoint {dx,dy}`, `stripProps(k, props)`, `editPath(ref, patch, coalesce?)`, `onPathHandleDrop(index, pose, coalesce)` are used with the same names and shapes in every task that touches them.
