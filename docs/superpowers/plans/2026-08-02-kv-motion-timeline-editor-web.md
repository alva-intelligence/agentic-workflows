# KV Motion Timeline Editor — Web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Full-page timeline editor that animates a KV board's overlays (x/y/scale/rotation/opacity keyframes) over a frozen base and exports MP4 client-side via Mediabunny — replacing the I2V Motion tab.

**Architecture:** Three layers with a one-way import rule. `lib/motion/` = pure engine (timeline types, sampling, encode loop, audio mix — no DOM imports from KV). `components/motion-editor/` = domain-free editor shell (dock, tracks, playhead, transport, undo). `components/studio/kv-generator/motion/` = KV adapter (snapshot, stage building via the refactored `buildBoardStage`, persistence). Preview and export share ONE stage builder — no 5th overlay renderer.

**Tech Stack:** Next.js 16 / React 19 / TypeScript, Konva 10, Mediabunny (+`@mediabunny/aac-encoder`), TanStack Query v5, `bun test`.

**Spec:** `docs/superpowers/specs/2026-08-02-kv-motion-timeline-editor-design.md`
**Depends on:** the api plan's endpoints (`motion-projects` CRUD + exports). Land api first — web without api only fails at project creation.

## Global Constraints

- Branch: `feature/daffa/vc-kv-motion-timeline-editor` off latest `origin/develop` in `web/`.
- Test runner is **`bun test`** (bunfig preloads jest-dom) — NEVER `bunx vitest`. Build gate is **`bun run build`** (it does not type-check; run `bunx tsc --noEmit` for types). RTL `screen` is broken under bun — use `within(document.body)`.
- Worktrees need their own `bun install` before building.
- **Import rule:** files under `src/lib/motion/` and `src/components/motion-editor/` MUST NOT import from `@/components/studio/kv-generator` or `@/lib/studio/kv` (enforced by the Task 1 boundary test).
- Animatable props are exactly `x, y, scale, rotation, opacity`. `x/y/width/height` stay normalized-to-board ([0,1]-ish) per the existing overlay convention.
- Konva tests read the **live node** (`layer.findOne(...)`), not the DOM.
- Old I2V surfaces (`KvMotionPanel`, `useKvMotion`, `KvMotionViewport`) are NOT deleted — only unmounted from the Motion tab (frozen behind the old flag).
- Timeline document is `version: 1`; the api stores it opaquely.
- Commit format: `feat(web): …` / `test(web): …` / `refactor(web): …`.

---

### Task 1: Deps, timeline types, import-boundary test

**Files:**
- Modify: `web/package.json` (via `bun add`)
- Create: `web/src/lib/motion/timeline.ts`
- Test: `web/src/lib/motion/importBoundary.test.ts`

**Interfaces:**
- Produces (consumed by every later task):

```ts
export type MotionEasing = "linear" | "in" | "out" | "in-out";
export type MotionProps = { x: number; y: number; scale: number; rotation: number; opacity: number };
export type MotionKeyframe = { t_ms: number; props: Partial<MotionProps>; easing: MotionEasing };
export type MotionTrack = { kind: "overlay"; overlay_id: string; keyframes: MotionKeyframe[] };
export type MotionAudio = { start_ms: number; trim_in_ms: number; trim_out_ms: number; volume: number; fade_in_ms: number; fade_out_ms: number };
export type MotionTimeline = { version: 1; duration_ms: number; fps: number; tracks: MotionTrack[]; audio?: MotionAudio };
```

- [ ] **Step 1: Install deps**

```bash
cd web && bun add mediabunny @mediabunny/aac-encoder
```

Expected: both appear in `package.json` dependencies.

- [ ] **Step 2: Write `timeline.ts`**

```ts
/** Motion timeline document — the persisted contract (api stores it opaquely).
 *  `tracks` is a discriminated union on `kind`: v1 ships only "overlay";
 *  a future "clip" kind (video-as-layer) is reserved, NOT implemented. */
export type MotionEasing = "linear" | "in" | "out" | "in-out";

/** The five animatable properties. x/y are the overlay box's normalized
 *  top-left (same convention as StudioOverlay); scale multiplies the box;
 *  rotation is degrees; opacity 0–1. */
export type MotionProps = {
  x: number;
  y: number;
  scale: number;
  rotation: number;
  opacity: number;
};

export type MotionKeyframe = {
  t_ms: number;
  /** Sparse: a keyframe may carry any subset of the five props. */
  props: Partial<MotionProps>;
  /** Easing INTO this keyframe (from the previous keyframe of each prop). */
  easing: MotionEasing;
};

export type MotionTrack = {
  kind: "overlay";
  overlay_id: string;
  keyframes: MotionKeyframe[];
};

export type MotionAudio = {
  start_ms: number;
  trim_in_ms: number;
  trim_out_ms: number;
  volume: number;
  fade_in_ms: number;
  fade_out_ms: number;
};

export type MotionTimeline = {
  version: 1;
  duration_ms: number;
  fps: number;
  tracks: MotionTrack[];
  audio?: MotionAudio;
};

export const DEFAULT_TIMELINE = (durationMs = 5000, fps = 30): MotionTimeline => ({
  version: 1,
  duration_ms: durationMs,
  fps,
  tracks: [],
});
```

- [ ] **Step 3: Write the import-boundary test**

```ts
import { describe, expect, it } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const FORBIDDEN = ["components/studio/kv-generator", "lib/studio/kv"];
const ROOTS = ["src/lib/motion", "src/components/motion-editor"];

function walk(dir: string): string[] {
  let out: string[] = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) out = out.concat(walk(p));
    else if (/\.(ts|tsx)$/.test(name) && !name.endsWith(".test.ts") && !name.endsWith(".test.tsx"))
      out.push(p);
  }
  return out;
}

describe("motion engine/shell import boundary", () => {
  it("never imports KV domain modules", () => {
    for (const root of ROOTS) {
      let files: string[] = [];
      try {
        files = walk(join(process.cwd(), root));
      } catch {
        continue; // root not created yet — fine while tasks land
      }
      for (const file of files) {
        const src = readFileSync(file, "utf8");
        for (const bad of FORBIDDEN) {
          expect(src.includes(bad), `${file} imports ${bad}`).toBe(false);
        }
      }
    }
  });
});
```

- [ ] **Step 4: Run tests + types**

Run: `cd web && bun test src/lib/motion/ && bunx tsc --noEmit`
Expected: boundary test PASS; tsc clean.

- [ ] **Step 5: Commit**

```bash
git add package.json bun.lock src/lib/motion/timeline.ts src/lib/motion/importBoundary.test.ts
git commit -m "feat(web): motion timeline types, mediabunny deps, import-boundary test"
```

---

### Task 2: `sampleTimelineAt` + easing (pure engine core)

**Files:**
- Create: `web/src/lib/motion/sample.ts`
- Test: `web/src/lib/motion/sample.test.ts`

**Interfaces:**
- Consumes: types from Task 1.
- Produces:

```ts
export function sampleTimelineAt(
  timeline: MotionTimeline,
  base: Map<string, MotionProps>,   // overlay_id → resting pose (from snapshot)
  tMs: number,
): Map<string, MotionProps>;
export const EASINGS: Record<MotionEasing, (t: number) => number>;
```

- [ ] **Step 1: Write failing tests**

```ts
import { describe, expect, it } from "bun:test";
import type { MotionProps, MotionTimeline } from "./timeline";
import { EASINGS, sampleTimelineAt } from "./sample";

const BASE: MotionProps = { x: 0.1, y: 0.2, scale: 1, rotation: 0, opacity: 1 };
const base = () => new Map([["ov1", { ...BASE }]]);
const tl = (keyframes: MotionTimeline["tracks"][0]["keyframes"]): MotionTimeline => ({
  version: 1,
  duration_ms: 5000,
  fps: 30,
  tracks: [{ kind: "overlay", overlay_id: "ov1", keyframes }],
});

describe("sampleTimelineAt", () => {
  it("returns base pose when a track has no keyframes", () => {
    const out = sampleTimelineAt(tl([]), base(), 1000);
    expect(out.get("ov1")).toEqual(BASE);
  });

  it("returns base for overlays with no track at all", () => {
    const out = sampleTimelineAt(
      { version: 1, duration_ms: 5000, fps: 30, tracks: [] },
      base(),
      1000,
    );
    expect(out.get("ov1")).toEqual(BASE);
  });

  it("interpolates linearly between two keyframes of one prop", () => {
    const out = sampleTimelineAt(
      tl([
        { t_ms: 0, props: { opacity: 0 }, easing: "linear" },
        { t_ms: 1000, props: { opacity: 1 }, easing: "linear" },
      ]),
      base(),
      500,
    );
    expect(out.get("ov1")!.opacity).toBeCloseTo(0.5);
    // untouched props stay at base
    expect(out.get("ov1")!.x).toBeCloseTo(0.1);
  });

  it("clamps before the first and after the last keyframe", () => {
    const kf = [
      { t_ms: 1000, props: { x: 0.5 }, easing: "linear" as const },
      { t_ms: 2000, props: { x: 0.9 }, easing: "linear" as const },
    ];
    expect(sampleTimelineAt(tl(kf), base(), 0).get("ov1")!.x).toBeCloseTo(0.5);
    expect(sampleTimelineAt(tl(kf), base(), 3000).get("ov1")!.x).toBeCloseTo(0.9);
  });

  it("treats sparse props independently (opacity kf does not pin x)", () => {
    const out = sampleTimelineAt(
      tl([
        { t_ms: 0, props: { x: 0.0 }, easing: "linear" },
        { t_ms: 1000, props: { x: 1.0 }, easing: "linear" },
        { t_ms: 500, props: { opacity: 0.5 }, easing: "linear" },
      ]),
      base(),
      500,
    );
    expect(out.get("ov1")!.x).toBeCloseTo(0.5); // opacity kf at 500 is invisible to x
    expect(out.get("ov1")!.opacity).toBeCloseTo(0.5);
  });

  it("applies easing INTO the destination keyframe", () => {
    const out = sampleTimelineAt(
      tl([
        { t_ms: 0, props: { opacity: 0 }, easing: "linear" },
        { t_ms: 1000, props: { opacity: 1 }, easing: "in" },
      ]),
      base(),
      500,
    );
    expect(out.get("ov1")!.opacity).toBeCloseTo(EASINGS.in(0.5)); // 0.25
  });

  it("keyframes are sorted by t_ms regardless of array order", () => {
    const out = sampleTimelineAt(
      tl([
        { t_ms: 1000, props: { opacity: 1 }, easing: "linear" },
        { t_ms: 0, props: { opacity: 0 }, easing: "linear" },
      ]),
      base(),
      250,
    );
    expect(out.get("ov1")!.opacity).toBeCloseTo(0.25);
  });
});

describe("EASINGS", () => {
  it("are 0 at 0 and 1 at 1", () => {
    for (const fn of Object.values(EASINGS)) {
      expect(fn(0)).toBeCloseTo(0);
      expect(fn(1)).toBeCloseTo(1);
    }
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd web && bun test src/lib/motion/sample.test.ts`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `sample.ts`**

```ts
import type { MotionEasing, MotionProps, MotionTimeline } from "./timeline";

export const EASINGS: Record<MotionEasing, (t: number) => number> = {
  linear: (t) => t,
  in: (t) => t * t,
  out: (t) => t * (2 - t),
  "in-out": (t) => (t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2) ** 2 / 2),
};

const PROPS: (keyof MotionProps)[] = ["x", "y", "scale", "rotation", "opacity"];

/** Pure: resolve every overlay's five props at time t. No canvas, no DOM.
 *  Per-property interpolation over that property's own keyframes (sparse),
 *  easing applied INTO the destination keyframe, clamped at both ends,
 *  falling back to the base (snapshot) pose when a property has no keyframes. */
export function sampleTimelineAt(
  timeline: MotionTimeline,
  base: Map<string, MotionProps>,
  tMs: number,
): Map<string, MotionProps> {
  const byId = new Map(timeline.tracks.map((tr) => [tr.overlay_id, tr]));
  const out = new Map<string, MotionProps>();

  for (const [id, rest] of base) {
    const track = byId.get(id);
    if (!track || track.keyframes.length === 0) {
      out.set(id, { ...rest });
      continue;
    }
    const sorted = [...track.keyframes].sort((a, b) => a.t_ms - b.t_ms);
    const resolved = { ...rest };

    for (const prop of PROPS) {
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
    out.set(id, resolved);
  }
  return out;
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd web && bun test src/lib/motion/sample.test.ts`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add src/lib/motion/sample.ts src/lib/motion/sample.test.ts
git commit -m "feat(web): pure timeline sampler with per-prop sparse keyframes + easing"
```

---

### Task 3: Auto-keyframe helper (pure)

**Files:**
- Create: `web/src/lib/motion/autokey.ts`
- Test: `web/src/lib/motion/autokey.test.ts`

**Interfaces:**
- Consumes: `sampleTimelineAt`, types.
- Produces:

```ts
export function writeAutoKeyframes(
  timeline: MotionTimeline,
  base: Map<string, MotionProps>,
  overlayId: string,
  tMs: number,
  changed: Partial<MotionProps>,
): MotionTimeline; // immutable — returns a new document
```

Rules (from spec): at `tMs === 0` write/merge a keyframe at 0 (base-pose editing). At `tMs > 0`: for each changed prop lacking ANY keyframe, first write an anchor at t=0 carrying the pre-change value, then write the keyframe at `tMs`. Existing keyframe exactly at `tMs` merges props. Default easing `"out"`.

- [ ] **Step 1: Write failing tests**

```ts
import { describe, expect, it } from "bun:test";
import type { MotionProps, MotionTimeline } from "./timeline";
import { writeAutoKeyframes } from "./autokey";

const BASE: MotionProps = { x: 0.1, y: 0.2, scale: 1, rotation: 0, opacity: 1 };
const base = () => new Map([["ov1", { ...BASE }]]);
const empty = (): MotionTimeline => ({ version: 1, duration_ms: 5000, fps: 30, tracks: [] });

describe("writeAutoKeyframes", () => {
  it("at t=0 writes a single keyframe at 0 (base pose edit)", () => {
    const out = writeAutoKeyframes(empty(), base(), "ov1", 0, { x: 0.4 });
    const kfs = out.tracks[0].keyframes;
    expect(kfs).toHaveLength(1);
    expect(kfs[0]).toMatchObject({ t_ms: 0, props: { x: 0.4 } });
  });

  it("at t>0 with no prior keyframes writes anchor at 0 + keyframe at t", () => {
    const out = writeAutoKeyframes(empty(), base(), "ov1", 800, { x: 0.6 });
    const kfs = [...out.tracks[0].keyframes].sort((a, b) => a.t_ms - b.t_ms);
    expect(kfs).toHaveLength(2);
    expect(kfs[0]).toMatchObject({ t_ms: 0, props: { x: 0.1 } }); // anchor = old value
    expect(kfs[1]).toMatchObject({ t_ms: 800, props: { x: 0.6 } });
  });

  it("does not re-anchor a prop that already has keyframes", () => {
    const first = writeAutoKeyframes(empty(), base(), "ov1", 800, { x: 0.6 });
    const second = writeAutoKeyframes(first, base(), "ov1", 1600, { x: 0.9 });
    const kfs = [...second.tracks[0].keyframes].sort((a, b) => a.t_ms - b.t_ms);
    expect(kfs).toHaveLength(3); // 0, 800, 1600 — no duplicate anchor
  });

  it("merges into an existing keyframe at the same t", () => {
    const first = writeAutoKeyframes(empty(), base(), "ov1", 800, { x: 0.6 });
    const second = writeAutoKeyframes(first, base(), "ov1", 800, { opacity: 0.3 });
    const at800 = second.tracks[0].keyframes.filter((k) => k.t_ms === 800);
    expect(at800).toHaveLength(1);
    expect(at800[0].props).toMatchObject({ x: 0.6, opacity: 0.3 });
    // opacity gained its own anchor at 0 with the OLD opacity
    const at0 = second.tracks[0].keyframes.find((k) => k.t_ms === 0)!;
    expect(at0.props.opacity).toBe(1);
  });

  it("does not mutate the input document", () => {
    const input = empty();
    writeAutoKeyframes(input, base(), "ov1", 800, { x: 0.6 });
    expect(input.tracks).toHaveLength(0);
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd web && bun test src/lib/motion/autokey.test.ts`
Expected: FAIL.

- [ ] **Step 3: Implement `autokey.ts`**

```ts
import type { MotionProps, MotionTimeline, MotionTrack } from "./timeline";

const PROPS: (keyof MotionProps)[] = ["x", "y", "scale", "rotation", "opacity"];

/** Auto-keyframe write (spec §Keyframing rules). Immutable. */
export function writeAutoKeyframes(
  timeline: MotionTimeline,
  base: Map<string, MotionProps>,
  overlayId: string,
  tMs: number,
  changed: Partial<MotionProps>,
): MotionTimeline {
  const tracks = timeline.tracks.map((t) => ({ ...t, keyframes: t.keyframes.map((k) => ({ ...k, props: { ...k.props } })) }));
  let track: MotionTrack | undefined = tracks.find(
    (t) => t.kind === "overlay" && t.overlay_id === overlayId,
  );
  if (!track) {
    track = { kind: "overlay", overlay_id: overlayId, keyframes: [] };
    tracks.push(track);
  }

  const upsert = (at: number, props: Partial<MotionProps>) => {
    const existing = track!.keyframes.find((k) => k.t_ms === at);
    if (existing) existing.props = { ...existing.props, ...props };
    else track!.keyframes.push({ t_ms: at, props: { ...props }, easing: "out" });
  };

  if (tMs > 0) {
    // Anchor each newly-animated prop at t=0 with its PRE-change value so the
    // drag immediately reads as motion (spec: lone keyframe at 0.8s looks broken).
    const rest = base.get(overlayId);
    const anchor: Partial<MotionProps> = {};
    for (const prop of PROPS) {
      if (changed[prop] === undefined) continue;
      const hasAny = track.keyframes.some((k) => k.props[prop] !== undefined);
      if (!hasAny && rest) anchor[prop] = rest[prop];
    }
    if (Object.keys(anchor).length > 0) upsert(0, anchor);
  }
  upsert(tMs, changed);

  return { ...timeline, tracks };
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd web && bun test src/lib/motion/autokey.test.ts`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add src/lib/motion/autokey.ts src/lib/motion/autokey.test.ts
git commit -m "feat(web): auto-keyframe writer with t=0 anchor rule"
```

---

### Task 4: Refactor `renderBoardStage` → `buildBoardStage` (nodeById + optional container)

**Files:**
- Modify: `web/src/components/studio/kv-generator/renderBoardStage.ts`
- Test: extend `web/src/components/studio/kv-generator/renderBoardStage.test.ts`

**Interfaces:**
- Consumes: nothing new.
- Produces:

```ts
export async function buildBoardStage(args: {
  baseImageUrl: string;
  overlays: StudioOverlay[];
  targetWidth: number;
  targetHeight: number;
  /** When given, the stage mounts visible in this element (editor preview).
   *  When absent, behaves exactly like the old hidden/offscreen stage. */
  container?: HTMLDivElement;
}): Promise<{ stage: Konva.Stage; nodeById: Map<string, Konva.Node> }>;

// Back-compat wrapper — signature and behavior unchanged for existing callers:
export async function renderHiddenStage(args: { baseImageUrl; overlays; targetWidth; targetHeight }): Promise<Konva.Stage>;
```

`nodeById` maps `overlay.id` → the Konva node added for it (Text / Image / shape Ctor instance). Hidden overlays get no node (unchanged skip). The refactor is mechanical: the existing body becomes `buildBoardStage`; the `container` creation branches on the new arg (own fixed-offscreen div only when absent — and only then does `stage.destroy` remove it); each `overlayGroup.add(node)` also does `nodeById.set(ov.id, node)`.

- [ ] **Step 1: Add failing tests to the existing test file**

Follow the existing test file's setup style (jsdom + Konva import pattern already in `renderBoardStage.test.ts` — reuse its mocks/fixtures for base image loading). Add:

```ts
it("buildBoardStage returns a node handle for every visible overlay", async () => {
  const { stage, nodeById } = await buildBoardStage({
    baseImageUrl: FIXTURE_BASE_URL, // reuse the file's existing base-image fixture
    overlays: [textOverlay({ id: "t1" }), textOverlay({ id: "t2", payload: { hidden: true } })],
    targetWidth: 200,
    targetHeight: 200,
  });
  try {
    expect(nodeById.has("t1")).toBe(true);
    expect(nodeById.has("t2")).toBe(false); // hidden → skipped, unchanged
  } finally {
    stage.destroy();
  }
});

it("renderHiddenStage wrapper still returns a bare stage (back-compat)", async () => {
  const stage = await renderHiddenStage({
    baseImageUrl: FIXTURE_BASE_URL,
    overlays: [textOverlay({ id: "t1" })],
    targetWidth: 200,
    targetHeight: 200,
  });
  try {
    expect(typeof stage.toCanvas).toBe("function");
    // node configs identical to buildBoardStage: same child count on the layer
    expect(stage.getLayers()[0].getChildren().length).toBeGreaterThan(0);
  } finally {
    stage.destroy();
  }
});
```

(`textOverlay(...)` = whatever overlay factory/fixture the existing tests use; reuse it verbatim — do not invent a parallel fixture.)

- [ ] **Step 2: Run to verify failure**

Run: `cd web && bun test src/components/studio/kv-generator/renderBoardStage.test.ts`
Expected: new tests FAIL (`buildBoardStage` not exported); old tests PASS.

- [ ] **Step 3: Refactor**

- Rename the current `renderHiddenStage` body to `buildBoardStage` with the new signature.
- Container branch at the top:

```ts
const ownContainer = !args.container;
const container = args.container ?? document.createElement("div");
if (ownContainer) {
  container.style.position = "fixed";
  container.style.left = "-99999px";
  container.style.top = "-99999px";
  document.body.appendChild(container);
}
```

- In the destroy patch, only `container.remove()` when `ownContainer`.
- Thread `const nodeById = new Map<string, Konva.Node>();` and set it beside every `overlayGroup.add(...)` (`nodeById.set(ov.id, textNode)` etc.).
- Return `{ stage, nodeById }`.
- New 4-line wrapper keeps the old export:

```ts
export async function renderHiddenStage(args: {
  baseImageUrl: string;
  overlays: StudioOverlay[];
  targetWidth: number;
  targetHeight: number;
}) {
  const { stage } = await buildBoardStage(args);
  return stage;
}
```

- [ ] **Step 4: Run the FULL existing test file + grep callers**

Run: `cd web && bun test src/components/studio/kv-generator/renderBoardStage.test.ts && grep -rn "renderHiddenStage" src --include="*.ts*"`
Expected: all tests PASS; every existing caller still resolves (wrapper).

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/renderBoardStage.ts src/components/studio/kv-generator/renderBoardStage.test.ts
git commit -m "refactor(web): buildBoardStage returns node handles + optional visible container"
```

---

### Task 5: `applyTimeline` (KV adapter glue) with live-node tests

**Files:**
- Create: `web/src/components/studio/kv-generator/motion/applyTimeline.ts`
- Test: `web/src/components/studio/kv-generator/motion/applyTimeline.test.ts`

**Interfaces:**
- Consumes: `buildBoardStage` (Task 4), `sampleTimelineAt` (Task 2), `MotionProps`.
- Produces:

```ts
export function baseProps(overlays: StudioOverlay[]): Map<string, MotionProps>;
export function applyTimeline(args: {
  nodeById: Map<string, Konva.Node>;
  overlays: StudioOverlay[];          // snapshot — provides box dims for center math
  sampled: Map<string, MotionProps>;  // from sampleTimelineAt
  targetWidth: number;
  targetHeight: number;
}): void;                              // sets nodes + caller batchDraws
```

`baseProps`: `{ x: ov.x, y: ov.y, scale: 1, rotation: ov.rotation, opacity: ov.payload.opacity ?? 1 }` per visible overlay.
`applyTimeline` per overlay: center `cx = (p.x + ov.width / 2) * W`, `cy = (p.y + ov.height / 2) * H`; sets `node.x(cx) .y(cy) .scaleX(p.scale) .scaleY(p.scale) .rotation(p.rotation) .opacity(baseOpacity * clamp01(p.opacity) / baseOpacity → just clamp01(p.opacity))`. Nodes are already center-offset by Task 4's builder, so position+scale pivot correctly without touching width/height (no per-frame re-wrap — spec requirement).

- [ ] **Step 1: Write failing tests (live Konva nodes — NOT DOM assertions)**

```ts
import { describe, expect, it } from "bun:test";
import { buildBoardStage } from "../renderBoardStage";
import { sampleTimelineAt } from "@/lib/motion/sample";
import type { MotionTimeline } from "@/lib/motion/timeline";
import { applyTimeline, baseProps } from "./applyTimeline";

// reuse the overlay fixture from renderBoardStage.test.ts (import or copy the factory)

const tl = (opacityAt: [number, number][]): MotionTimeline => ({
  version: 1,
  duration_ms: 2000,
  fps: 30,
  tracks: [
    {
      kind: "overlay",
      overlay_id: "t1",
      keyframes: opacityAt.map(([t_ms, opacity]) => ({ t_ms, props: { opacity }, easing: "linear" as const })),
    },
  ],
});

it("drives live node opacity through time", async () => {
  const overlays = [textOverlay({ id: "t1" })];
  const { stage, nodeById } = await buildBoardStage({
    baseImageUrl: FIXTURE_BASE_URL,
    overlays,
    targetWidth: 200,
    targetHeight: 200,
  });
  try {
    const timeline = tl([[0, 0], [1000, 1]]);
    const base = baseProps(overlays);

    applyTimeline({ nodeById, overlays, sampled: sampleTimelineAt(timeline, base, 0), targetWidth: 200, targetHeight: 200 });
    expect(nodeById.get("t1")!.opacity()).toBeCloseTo(0);

    applyTimeline({ nodeById, overlays, sampled: sampleTimelineAt(timeline, base, 500), targetWidth: 200, targetHeight: 200 });
    expect(nodeById.get("t1")!.opacity()).toBeCloseTo(0.5);
  } finally {
    stage.destroy();
  }
});

it("scale animates via scaleX/scaleY, never width (no re-wrap)", async () => {
  const overlays = [textOverlay({ id: "t1" })];
  const { stage, nodeById } = await buildBoardStage({
    baseImageUrl: FIXTURE_BASE_URL,
    overlays,
    targetWidth: 200,
    targetHeight: 200,
  });
  try {
    const node = nodeById.get("t1")!;
    const widthBefore = node.width();
    const timeline: MotionTimeline = {
      version: 1, duration_ms: 2000, fps: 30,
      tracks: [{ kind: "overlay", overlay_id: "t1", keyframes: [
        { t_ms: 0, props: { scale: 1 }, easing: "linear" },
        { t_ms: 1000, props: { scale: 2 }, easing: "linear" },
      ] }],
    };
    applyTimeline({ nodeById, overlays, sampled: sampleTimelineAt(timeline, baseProps(overlays), 1000), targetWidth: 200, targetHeight: 200 });
    expect(node.scaleX()).toBeCloseTo(2);
    expect(node.width()).toBe(widthBefore); // width untouched — no text re-wrap
  } finally {
    stage.destroy();
  }
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd web && bun test src/components/studio/kv-generator/motion/applyTimeline.test.ts`
Expected: FAIL.

- [ ] **Step 3: Implement**

```ts
import type Konva from "konva";
import type { MotionProps } from "@/lib/motion/timeline";
import type { StudioOverlay } from "@/types/studio";

const clamp01 = (v: number) => Math.min(1, Math.max(0, v));

/** Resting pose per overlay, straight from the snapshot. */
export function baseProps(overlays: StudioOverlay[]): Map<string, MotionProps> {
  const out = new Map<string, MotionProps>();
  for (const ov of overlays) {
    if (ov.payload.hidden === true) continue;
    out.set(ov.id, {
      x: ov.x,
      y: ov.y,
      scale: 1,
      rotation: ov.rotation,
      opacity: ov.payload.opacity ?? 1,
    });
  }
  return out;
}

/** Push sampled values onto live Konva nodes. Nodes are center-offset by
 *  buildBoardStage, so position/scale pivot on the visual center and text
 *  width is NEVER touched (wrap computed once at build). Caller batchDraws. */
export function applyTimeline(args: {
  nodeById: Map<string, Konva.Node>;
  overlays: StudioOverlay[];
  sampled: Map<string, MotionProps>;
  targetWidth: number;
  targetHeight: number;
}): void {
  const dims = new Map(args.overlays.map((o) => [o.id, o]));
  for (const [id, p] of args.sampled) {
    const node = args.nodeById.get(id);
    const ov = dims.get(id);
    if (!node || !ov) continue;
    node.x((p.x + ov.width / 2) * args.targetWidth);
    node.y((p.y + ov.height / 2) * args.targetHeight);
    node.scaleX(p.scale);
    node.scaleY(p.scale);
    node.rotation(p.rotation);
    node.opacity(clamp01(p.opacity));
  }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd web && bun test src/components/studio/kv-generator/motion/applyTimeline.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/motion/applyTimeline.ts src/components/studio/kv-generator/motion/applyTimeline.test.ts
git commit -m "feat(web): applyTimeline drives live stage nodes from sampled props"
```

---

### Task 6: Encode loop (`lib/motion/encode.ts`) + audio mix (`lib/motion/audio.ts`)

**Files:**
- Create: `web/src/lib/motion/encode.ts`
- Create: `web/src/lib/motion/audio.ts`
- Test: `web/src/lib/motion/encode.test.ts`

**Interfaces:**
- Consumes: Mediabunny (`Output`, `Mp4OutputFormat`, `BufferTarget`, `CanvasSource`, `AudioBufferSource`, `canEncode`, `QUALITY_HIGH`), `@mediabunny/aac-encoder` (`registerAacEncoder` — verify the exact export name against the package README at implementation time; if it differs, adapt the one import line, nothing else changes).
- Produces:

```ts
// encode.ts
export async function canExportMp4(): Promise<boolean>;   // canEncode("avc") && aac-or-fallback
export async function encodeTimelineToMp4(opts: {
  canvas: HTMLCanvasElement;                 // the export stage's canvas
  width: number; height: number;
  fps: number; durationMs: number;
  drawFrame: (tMs: number) => void | Promise<void>;
  audioBuffer?: AudioBuffer | null;
  signal?: AbortSignal;
  onProgress?: (frac: number) => void;
  /** DI seam for tests — defaults to the real mediabunny classes. */
  deps?: Partial<EncodeDeps>;
}): Promise<Blob>;

// audio.ts
export async function renderAudioMix(opts: {
  source: AudioBuffer;                        // decoded upload
  audio: MotionAudio;                         // trim/volume/fade from the timeline
  durationMs: number;
}): Promise<AudioBuffer>;                     // OfflineAudioContext render, final
```

- [ ] **Step 1: Write failing tests for the frame loop (mocked deps)**

```ts
import { describe, expect, it } from "bun:test";
import { encodeTimelineToMp4 } from "./encode";

function mockDeps() {
  const added: Array<[number, number]> = [];
  const calls: string[] = [];
  return {
    added,
    calls,
    deps: {
      Output: class {
        constructor(_: unknown) {}
        addVideoTrack() { calls.push("addVideoTrack"); }
        addAudioTrack() { calls.push("addAudioTrack"); }
        async start() { calls.push("start"); }
        async finalize() { calls.push("finalize"); }
      },
      Mp4OutputFormat: class {},
      BufferTarget: class { buffer = new ArrayBuffer(8); },
      CanvasSource: class {
        constructor(_c: unknown, _o: unknown) {}
        async add(t: number, d: number) { added.push([t, d]); }
        close() {}
      },
      AudioBufferSource: class {
        constructor(_: unknown) {}
        async add() { calls.push("audio.add"); }
        close() {}
      },
    },
  };
}

describe("encodeTimelineToMp4", () => {
  it("steps exactly durationMs/1000*fps frames with exact timestamps", async () => {
    const m = mockDeps();
    const drawn: number[] = [];
    const blob = await encodeTimelineToMp4({
      canvas: document.createElement("canvas"),
      width: 100, height: 100, fps: 10, durationMs: 1000,
      drawFrame: (t) => { drawn.push(t); },
      deps: m.deps as never,
    });
    expect(blob).toBeInstanceOf(Blob);
    expect(m.added).toHaveLength(10);
    expect(m.added[0]).toEqual([0, 0.1]);
    expect(m.added[3][0]).toBeCloseTo(0.3);
    expect(drawn[3]).toBeCloseTo(300); // drawFrame gets ms
    expect(m.calls).toContain("start");
    expect(m.calls.at(-1)).toBe("finalize");
  });

  it("aborts cleanly mid-render", async () => {
    const m = mockDeps();
    const ctrl = new AbortController();
    await expect(
      encodeTimelineToMp4({
        canvas: document.createElement("canvas"),
        width: 100, height: 100, fps: 10, durationMs: 1000,
        drawFrame: (t) => { if (t >= 300) ctrl.abort(); },
        signal: ctrl.signal,
        deps: m.deps as never,
      }),
    ).rejects.toThrow(/aborted/i);
    expect(m.added.length).toBeLessThan(10);
    expect(m.calls).not.toContain("finalize");
  });

  it("adds an audio track only when a buffer is provided", async () => {
    const m = mockDeps();
    await encodeTimelineToMp4({
      canvas: document.createElement("canvas"),
      width: 100, height: 100, fps: 10, durationMs: 200,
      drawFrame: () => {},
      audioBuffer: { duration: 0.2 } as AudioBuffer,
      deps: m.deps as never,
    });
    expect(m.calls).toContain("addAudioTrack");
    expect(m.calls).toContain("audio.add");
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd web && bun test src/lib/motion/encode.test.ts`
Expected: FAIL.

- [ ] **Step 3: Implement `encode.ts`**

```ts
import {
  AudioBufferSource,
  BufferTarget,
  CanvasSource,
  Mp4OutputFormat,
  Output,
  QUALITY_HIGH,
  canEncode,
} from "mediabunny";
import { registerAacEncoder } from "@mediabunny/aac-encoder";

let aacRegistered = false;
function ensureAac() {
  if (!aacRegistered) {
    registerAacEncoder();
    aacRegistered = true;
  }
}

export type EncodeDeps = {
  Output: typeof Output;
  Mp4OutputFormat: typeof Mp4OutputFormat;
  BufferTarget: typeof BufferTarget;
  CanvasSource: typeof CanvasSource;
  AudioBufferSource: typeof AudioBufferSource;
};

/** Gate the Export button up front — never fail mid-render on codec support. */
export async function canExportMp4(): Promise<boolean> {
  ensureAac();
  return canEncode("avc");
}

/** Deterministic, non-realtime frame loop: the canvas is drawn at exact
 *  timestamps and pushed with explicit (t, duration) — frame-exact no matter
 *  how slow the machine renders. */
export async function encodeTimelineToMp4(opts: {
  canvas: HTMLCanvasElement;
  width: number;
  height: number;
  fps: number;
  durationMs: number;
  drawFrame: (tMs: number) => void | Promise<void>;
  audioBuffer?: AudioBuffer | null;
  signal?: AbortSignal;
  onProgress?: (frac: number) => void;
  deps?: Partial<EncodeDeps>;
}): Promise<Blob> {
  const D: EncodeDeps = {
    Output, Mp4OutputFormat, BufferTarget, CanvasSource, AudioBufferSource,
    ...opts.deps,
  };
  if (!opts.deps) ensureAac();

  const target = new D.BufferTarget();
  const output = new D.Output({ format: new D.Mp4OutputFormat(), target });

  const videoSource = new D.CanvasSource(opts.canvas, {
    codec: "avc",
    quality: QUALITY_HIGH,
  });
  output.addVideoTrack(videoSource);

  let audioSource: InstanceType<EncodeDeps["AudioBufferSource"]> | null = null;
  if (opts.audioBuffer) {
    audioSource = new D.AudioBufferSource({ codec: "aac" });
    output.addAudioTrack(audioSource);
  }

  await output.start();

  const frameCount = Math.round((opts.durationMs / 1000) * opts.fps);
  const frameDur = 1 / opts.fps;
  for (let i = 0; i < frameCount; i++) {
    if (opts.signal?.aborted) throw new Error("Export aborted");
    const tMs = (i / opts.fps) * 1000;
    await opts.drawFrame(tMs);
    await videoSource.add(i * frameDur, frameDur);
    opts.onProgress?.((i + 1) / frameCount);
  }

  if (audioSource && opts.audioBuffer) {
    await audioSource.add(opts.audioBuffer);
  }

  await output.finalize();
  return new Blob([target.buffer!], { type: "video/mp4" });
}
```

NOTE for implementer: `QUALITY_HIGH`, option-object shapes, and `registerAacEncoder` must be verified against the installed mediabunny version (context7 / https://mediabunny.dev/guide/writing-media-files) — the loop/DI structure above is the contract; adapt constructor option names only.

- [ ] **Step 4: Implement `audio.ts`**

```ts
import type { MotionAudio } from "./timeline";

/** Bake trim/volume/fade into one final AudioBuffer offline (deterministic).
 *  Mediabunny's AudioBufferSource has no timestamps — buffers concatenate from
 *  0 — so the mix must be final BEFORE encoding: we render silence up to
 *  start_ms, then the trimmed/faded clip, into a buffer exactly durationMs long. */
export async function renderAudioMix(opts: {
  source: AudioBuffer;
  audio: MotionAudio;
  durationMs: number;
}): Promise<AudioBuffer> {
  const { source, audio, durationMs } = opts;
  const sampleRate = source.sampleRate;
  const ctx = new OfflineAudioContext(
    Math.min(2, source.numberOfChannels),
    Math.max(1, Math.ceil((durationMs / 1000) * sampleRate)),
    sampleRate,
  );

  const node = ctx.createBufferSource();
  node.buffer = source;

  const gain = ctx.createGain();
  const startS = audio.start_ms / 1000;
  const trimInS = audio.trim_in_ms / 1000;
  const clipLenS = Math.max(
    0,
    Math.min(
      (audio.trim_out_ms - audio.trim_in_ms) / 1000,
      durationMs / 1000 - startS,
    ),
  );
  const v = Math.min(1, Math.max(0, audio.volume));
  const fadeInS = Math.min(audio.fade_in_ms / 1000, clipLenS);
  const fadeOutS = Math.min(audio.fade_out_ms / 1000, clipLenS);

  gain.gain.setValueAtTime(fadeInS > 0 ? 0 : v, startS);
  if (fadeInS > 0) gain.gain.linearRampToValueAtTime(v, startS + fadeInS);
  if (fadeOutS > 0) {
    gain.gain.setValueAtTime(v, startS + clipLenS - fadeOutS);
    gain.gain.linearRampToValueAtTime(0, startS + clipLenS);
  }

  node.connect(gain).connect(ctx.destination);
  node.start(startS, trimInS, clipLenS);

  return ctx.startRendering();
}
```

(`OfflineAudioContext` doesn't exist in bun's jsdom — `audio.ts` gets no unit test; it's exercised in the browser verification of Task 12. Keep it logic-thin for that reason.)

- [ ] **Step 5: Run tests + types**

Run: `cd web && bun test src/lib/motion/ && bunx tsc --noEmit`
Expected: encode tests PASS; boundary test still PASS (mediabunny is allowed — only KV imports are forbidden).

- [ ] **Step 6: Commit**

```bash
git add src/lib/motion/encode.ts src/lib/motion/audio.ts src/lib/motion/encode.test.ts
git commit -m "feat(web): mediabunny mp4 encode loop + offline audio mix"
```

---

### Task 7: API client (`services/kv/motionProjects.ts`)

**Files:**
- Create: `web/src/services/kv/motionProjects.ts`
- Create: `web/src/types/kv/motionProject.ts`

**Interfaces:**
- Consumes: api plan's endpoints; `MotionTimeline` type.
- Produces (used by Tasks 9–13):

```ts
// types/kv/motionProject.ts
export type KvMotionSnapshot = { base_image_url: string; board_width: number; board_height: number; overlays: StudioOverlay[] };
export type KvMotionProjectSummary = { id; studioFileId; boardGenerationId; name; audioUrl; durationMs; fps; createdAt; updatedAt };
export type KvMotionProject = KvMotionProjectSummary & { snapshot: KvMotionSnapshot; timeline: MotionTimeline };
export type KvMotionExportRow = { id; ratio; url; width; height; durationMs; createdAt };

// services/kv/motionProjects.ts
export async function listMotionProjects(fileId: string): Promise<KvMotionProjectSummary[]>;
export async function createMotionProject(fileId: string, body: { boardGenerationId: string; name?: string; snapshot: KvMotionSnapshot; timeline: MotionTimeline }): Promise<KvMotionProject>;
export async function getMotionProject(fileId: string, projectId: string): Promise<KvMotionProject>;
export async function patchMotionProject(fileId: string, projectId: string, body: Partial<{ name: string; snapshot: KvMotionSnapshot; timeline: MotionTimeline; audio_url: string | null }>): Promise<KvMotionProject>;
export async function deleteMotionProject(fileId: string, projectId: string): Promise<void>;
export async function listMotionExports(fileId: string, projectId: string): Promise<KvMotionExportRow[]>;
export async function createMotionExport(fileId: string, projectId: string, body: { ratio: string; url: string; width: number; height: number; durationMs: number }): Promise<KvMotionExportRow>;
```

- [ ] **Step 1: Write the types file** — copy the shape above verbatim into `types/kv/motionProject.ts` with full property types (all ids/urls/names `string`, all `*Ms`/`width`/`height`/`fps` `number`), importing `StudioOverlay` from `@/types/studio` and `MotionTimeline` from `@/lib/motion/timeline`.

- [ ] **Step 2: Write the service** — open `web/src/services/kv/api.ts:1-30` and copy its `axiosInstance` + `unwrap` import lines exactly. Implement each function against `v1/studio/files/${fileId}/motion-projects…` with snake_case wire mapping (mirror `listMotions`/`createMotion` in that same file as the style reference — wire type + `toX()` mapper per row). PATCH body passes `timeline`/`snapshot`/`audio_url` through untranslated; only row fields are case-mapped.

- [ ] **Step 3: Verify types compile**

Run: `cd web && bunx tsc --noEmit`
Expected: clean. (No unit test — thin axios mappers; covered by editor integration.)

- [ ] **Step 4: Commit**

```bash
git add src/types/kv/motionProject.ts src/services/kv/motionProjects.ts
git commit -m "feat(web): motion project api client + wire types"
```

---

### Task 8: Editor document state + undo (`useTimelineCommands`)

**Files:**
- Create: `web/src/components/motion-editor/useTimelineCommands.ts`
- Test: `web/src/components/motion-editor/useTimelineCommands.test.ts`

**Interfaces:**
- Consumes: `MotionTimeline`, `writeAutoKeyframes` is NOT imported here (domain-free shell) — commands take pre-built next documents.
- Produces:

```ts
export type TimelineCommandApi = {
  timeline: MotionTimeline;
  /** Replace the document (one undo step). label groups rapid same-label pushes. */
  push: (next: MotionTimeline, label?: string) => void;
  undo: () => void;
  redo: () => void;
  canUndo: boolean;
  canRedo: boolean;
};
export function useTimelineCommands(initial: MotionTimeline): TimelineCommandApi;
```

- [ ] **Step 1: Write failing tests** (renderHook from `@testing-library/react`; remember `within(document.body)` is irrelevant here — no DOM):

```ts
import { describe, expect, it } from "bun:test";
import { act, renderHook } from "@testing-library/react";
import { DEFAULT_TIMELINE } from "@/lib/motion/timeline";
import { useTimelineCommands } from "./useTimelineCommands";

describe("useTimelineCommands", () => {
  it("push → undo → redo round-trips", () => {
    const { result } = renderHook(() => useTimelineCommands(DEFAULT_TIMELINE()));
    const doc2 = { ...DEFAULT_TIMELINE(), duration_ms: 8000 };

    act(() => result.current.push(doc2));
    expect(result.current.timeline.duration_ms).toBe(8000);
    expect(result.current.canUndo).toBe(true);

    act(() => result.current.undo());
    expect(result.current.timeline.duration_ms).toBe(5000);

    act(() => result.current.redo());
    expect(result.current.timeline.duration_ms).toBe(8000);
  });

  it("pushing after undo clears the redo stack", () => {
    const { result } = renderHook(() => useTimelineCommands(DEFAULT_TIMELINE()));
    act(() => result.current.push({ ...DEFAULT_TIMELINE(), duration_ms: 8000 }));
    act(() => result.current.undo());
    act(() => result.current.push({ ...DEFAULT_TIMELINE(), duration_ms: 9000 }));
    expect(result.current.canRedo).toBe(false);
  });

  it("rapid pushes with the same label collapse into one undo step", () => {
    const { result } = renderHook(() => useTimelineCommands(DEFAULT_TIMELINE()));
    act(() => result.current.push({ ...DEFAULT_TIMELINE(), duration_ms: 6000 }, "drag:ov1"));
    act(() => result.current.push({ ...DEFAULT_TIMELINE(), duration_ms: 7000 }, "drag:ov1"));
    act(() => result.current.undo());
    expect(result.current.timeline.duration_ms).toBe(5000); // one step back to start
  });
});
```

- [ ] **Step 2: Run to verify failure, then implement**

```ts
import { useCallback, useRef, useState } from "react";
import type { MotionTimeline } from "@/lib/motion/timeline";

export type TimelineCommandApi = {
  timeline: MotionTimeline;
  push: (next: MotionTimeline, label?: string) => void;
  undo: () => void;
  redo: () => void;
  canUndo: boolean;
  canRedo: boolean;
};

/** Document-level undo: each push snapshots the whole timeline (small JSON).
 *  Same-label consecutive pushes collapse (a drag emits many intermediate
 *  documents but should undo in ONE step — spec: undo is one step per action). */
export function useTimelineCommands(initial: MotionTimeline): TimelineCommandApi {
  const [timeline, setTimeline] = useState(initial);
  const past = useRef<MotionTimeline[]>([]);
  const future = useRef<MotionTimeline[]>([]);
  const lastLabel = useRef<string | undefined>(undefined);

  const push = useCallback((next: MotionTimeline, label?: string) => {
    setTimeline((prev) => {
      const collapse = label !== undefined && label === lastLabel.current;
      if (!collapse) past.current.push(prev);
      lastLabel.current = label;
      future.current = [];
      return next;
    });
  }, []);

  const undo = useCallback(() => {
    setTimeline((prev) => {
      const last = past.current.pop();
      if (!last) return prev;
      future.current.push(prev);
      lastLabel.current = undefined;
      return last;
    });
  }, []);

  const redo = useCallback(() => {
    setTimeline((prev) => {
      const next = future.current.pop();
      if (!next) return prev;
      past.current.push(prev);
      lastLabel.current = undefined;
      return next;
    });
  }, []);

  return {
    timeline,
    push,
    undo,
    redo,
    canUndo: past.current.length > 0,
    canRedo: future.current.length > 0,
  };
}
```

- [ ] **Step 3: Run to verify pass**

Run: `cd web && bun test src/components/motion-editor/useTimelineCommands.test.ts`
Expected: PASS (3 tests).

- [ ] **Step 4: Commit**

```bash
git add src/components/motion-editor/useTimelineCommands.ts src/components/motion-editor/useTimelineCommands.test.ts
git commit -m "feat(web): timeline document undo/redo with drag collapsing"
```

---

### Task 9: Editor shell components (dock, tracks, playhead, transport, inspector)

**Files:**
- Create: `web/src/components/motion-editor/Transport.tsx`
- Create: `web/src/components/motion-editor/TimelineRuler.tsx`
- Create: `web/src/components/motion-editor/TrackRow.tsx`
- Create: `web/src/components/motion-editor/TimelineDock.tsx`
- Create: `web/src/components/motion-editor/InspectorPanel.tsx`
- Test: `web/src/components/motion-editor/TimelineDock.test.tsx`

**Interfaces:**
- Consumes: `MotionTimeline`, `MotionKeyframe`, `TimelineCommandApi` (props only — no KV imports, no fetching).
- Produces (all controlled/presentational; the adapter page owns state):

```ts
export type TrackDescriptor = { id: string; name: string; icon: "text" | "image" | "shape" | "locked"; locked?: boolean };

// TimelineDock props
type TimelineDockProps = {
  timeline: MotionTimeline;
  tracks: TrackDescriptor[];              // display order = layers panel order
  playheadMs: number;
  playing: boolean;
  selectedKeyframe: { trackId: string; tMs: number } | null;
  onSeek: (tMs: number) => void;
  onTogglePlay: () => void;
  onSelectKeyframe: (trackId: string, tMs: number) => void;
  onMoveKeyframe: (trackId: string, fromTMs: number, toTMs: number) => void;
  onDeleteKeyframe: (trackId: string, tMs: number) => void;
  onInsertKeyframe: (trackId: string, tMs: number) => void;   // dbl-click
  onDurationChange: (durationMs: number) => void;
  audioSlot?: React.ReactNode;            // Task 12 mounts the audio row here
};

// InspectorPanel props
type InspectorPanelProps = {
  sampled: MotionProps | null;            // values at playhead for selected track
  keyframeAtPlayhead: MotionKeyframe | null;
  onEditKeyframe: (props: Partial<MotionProps>, easing?: MotionEasing) => void;
  onMakeKeyframe: () => void;             // "make keyframe here" when between
};
```

- [ ] **Step 1: Write failing interaction tests for the dock**

```tsx
import { describe, expect, it, mock } from "bun:test";
import { fireEvent, render, within } from "@testing-library/react";
import { DEFAULT_TIMELINE } from "@/lib/motion/timeline";
import { TimelineDock } from "./TimelineDock";

const tl = () => ({
  ...DEFAULT_TIMELINE(),
  tracks: [{
    kind: "overlay" as const,
    overlay_id: "ov1",
    keyframes: [
      { t_ms: 0, props: { opacity: 0 }, easing: "linear" as const },
      { t_ms: 1000, props: { opacity: 1 }, easing: "out" as const },
    ],
  }],
});
const TRACKS = [{ id: "ov1", name: "Headline", icon: "text" as const }];

function renderDock(overrides = {}) {
  const handlers = {
    onSeek: mock(), onTogglePlay: mock(), onSelectKeyframe: mock(),
    onMoveKeyframe: mock(), onDeleteKeyframe: mock(), onInsertKeyframe: mock(),
    onDurationChange: mock(),
  };
  render(
    <TimelineDock
      timeline={tl()} tracks={TRACKS} playheadMs={0} playing={false}
      selectedKeyframe={null} {...handlers} {...overrides}
    />,
  );
  return handlers;
}

describe("TimelineDock", () => {
  it("renders one row per track with its keyframe diamonds", () => {
    renderDock();
    const body = within(document.body);
    expect(body.getByText("Headline")).toBeInTheDocument();
    expect(body.getAllByTestId("kf-diamond")).toHaveLength(2);
  });

  it("clicking a diamond selects it", () => {
    const h = renderDock();
    fireEvent.click(within(document.body).getAllByTestId("kf-diamond")[1]);
    expect(h.onSelectKeyframe).toHaveBeenCalledWith("ov1", 1000);
  });

  it("Delete key removes the selected keyframe", () => {
    const h = renderDock({ selectedKeyframe: { trackId: "ov1", tMs: 1000 } });
    fireEvent.keyDown(within(document.body).getByTestId("timeline-dock"), { key: "Delete" });
    expect(h.onDeleteKeyframe).toHaveBeenCalledWith("ov1", 1000);
  });

  it("double-clicking a row inserts a keyframe at that time", () => {
    const h = renderDock();
    const row = within(document.body).getByTestId("track-lane-ov1");
    // lane is 500px wide in the test layout; dblclick at half = duration/2
    Object.defineProperty(row, "getBoundingClientRect", {
      value: () => ({ left: 0, width: 500, top: 0, height: 20, right: 500, bottom: 20 }),
    });
    fireEvent.dblClick(row, { clientX: 250 });
    expect(h.onInsertKeyframe).toHaveBeenCalledWith("ov1", 2500);
  });
});
```

- [ ] **Step 2: Run to verify failure, then implement the five components.**

Implementation notes (each file stays < 200 lines; Tailwind, frndos `Button`/`Input` where a control fits):

- `Transport.tsx`: play/pause button (`Space` handled by the dock's keydown), loop toggle, `mm:ss.cc / mm:ss.cc` mono text, fps label, duration `Input` (numeric, 1000–30000 ms; commits on blur/Enter via `onDurationChange`).
- `TimelineRuler.tsx`: absolute-positioned second ticks (`0s…Ns` from `duration_ms`), click/drag anywhere seeks: `onSeek(clamp(frac * duration_ms))` from `(clientX - rect.left) / rect.width`.
- `TrackRow.tsx`: name cell (fixed 8rem) + flex lane (`data-testid="track-lane-<id>"`). Diamonds (`data-testid="kf-diamond"`) absolutely positioned at `left: ${(k.t_ms / duration_ms) * 100}%`, rotated square (`rotate-45`), accent fill when selected. Pointer-drag on a diamond converts Δx → Δt and fires `onMoveKeyframe` on pointerup (one call — undo = one step). `onDoubleClick` on the lane → `onInsertKeyframe` (time from click fraction, rounded to whole ms). Locked tracks render dimmed with a lock icon and no lane handlers.
- `TimelineDock.tsx` (`data-testid="timeline-dock"`, `tabIndex={0}`): keydown handles `Space` → `onTogglePlay` (preventDefault) and `Delete`/`Backspace` → `onDeleteKeyframe(selected)`. Layout: Transport bar on top; below it the ruler row (name-cell spacer + ruler) and one `TrackRow` per `tracks` entry (SAME order — mirrors the layers rail); playhead as an absolute accent line at `left: calc(8rem + frac * (100% - 8rem))` spanning all rows; `audioSlot` rendered last after a divider.
- `InspectorPanel.tsx`: five labeled numeric `Input`s (x/y/scale/rotation/opacity, `step=0.01`, rotation `step=1`) + easing `<select>` (linear/in/out/in-out). Enabled + wired to `onEditKeyframe` when `keyframeAtPlayhead` non-null; otherwise disabled showing `sampled` values with a "Make keyframe here" `Button` firing `onMakeKeyframe`.

- [ ] **Step 3: Run to verify pass**

Run: `cd web && bun test src/components/motion-editor/`
Expected: dock tests + undo tests + boundary test PASS.

- [ ] **Step 4: Commit**

```bash
git add src/components/motion-editor/
git commit -m "feat(web): motion editor shell — dock, tracks, ruler, transport, inspector"
```

---

### Task 10: KV adapter page — route, snapshot, preview loop, autosave

**Files:**
- Create: `web/src/app/(canvas)/brands/[id]/studio/kv-generator/[file_id]/motion/[projectId]/page.tsx`
- Create: `web/src/components/studio/kv-generator/motion/KvMotionEditor.tsx`
- Create: `web/src/components/studio/kv-generator/motion/useMotionEditorState.ts`
- Test: `web/src/components/studio/kv-generator/motion/useMotionEditorState.test.ts`

**Interfaces:**
- Consumes: everything from Tasks 2–9.
- Produces: the working editor page. `useMotionEditorState(project)` composes: `useTimelineCommands(project.timeline)` + playhead/playing state + selection + derived `base = baseProps(project.snapshot.overlays)` + handlers that call `writeAutoKeyframes` and hand documents to `push` + debounced (1.5s) `patchMotionProject` autosave with retry/backoff banner state (`saveState: "saved" | "saving" | "error"`).

- [ ] **Step 1: Write failing tests for the state hook** (the composition logic — not the page):

```ts
import { describe, expect, it } from "bun:test";
import { act, renderHook } from "@testing-library/react";
import { useMotionEditorState } from "./useMotionEditorState";

const project = {
  id: "p1", studioFileId: "f1", boardGenerationId: "g1", name: "Test",
  audioUrl: null, durationMs: 5000, fps: 30, createdAt: "", updatedAt: "",
  snapshot: {
    base_image_url: "https://x/y.png", board_width: 1080, board_height: 1080,
    overlays: [/* one text overlay fixture with id "ov1", x:0.1 y:0.2 w:0.3 h:0.1 rotation:0 */],
  },
  timeline: { version: 1 as const, duration_ms: 5000, fps: 30, tracks: [] },
};

describe("useMotionEditorState", () => {
  it("drag at t=0 edits the base keyframe, no anchor", () => {
    const { result } = renderHook(() => useMotionEditorState(project, { autosave: false }));
    act(() => result.current.onOverlayTransformed("ov1", { x: 0.5 }));
    const kfs = result.current.timeline.tracks[0].keyframes;
    expect(kfs).toHaveLength(1);
    expect(kfs[0].t_ms).toBe(0);
  });

  it("drag at t>0 creates anchor + keyframe and one undo step reverts both", () => {
    const { result } = renderHook(() => useMotionEditorState(project, { autosave: false }));
    act(() => result.current.seek(800));
    act(() => result.current.onOverlayTransformed("ov1", { x: 0.5 }));
    expect(result.current.timeline.tracks[0].keyframes).toHaveLength(2);
    act(() => result.current.undo());
    expect(result.current.timeline.tracks).toHaveLength(0);
  });

  it("editingInTime is true only when playhead > 0", () => {
    const { result } = renderHook(() => useMotionEditorState(project, { autosave: false }));
    expect(result.current.editingInTime).toBe(false);
    act(() => result.current.seek(100));
    expect(result.current.editingInTime).toBe(true);
  });
});
```

- [ ] **Step 2: Run to verify failure, then implement `useMotionEditorState.ts`.**

Composition (≈120 lines): `useTimelineCommands` + `useState` for `playheadMs`/`playing`/`selectedKeyframe` + `useMemo` base map + handlers:

```ts
onOverlayTransformed(id, changed) {
  push(writeAutoKeyframes(timeline, base, id, playheadMs, changed), `drag:${id}:${playheadMs}`);
}
seek(t) { setPlayheadMs(clamp(t, 0, timeline.duration_ms)); }
editingInTime = playheadMs > 0;
sampled = useMemo(() => sampleTimelineAt(timeline, base, playheadMs), [timeline, base, playheadMs]);
```

plus keyframe ops (`moveKeyframe`, `deleteKeyframe`, `insertKeyframe` = `writeAutoKeyframes` with sampled values, `editKeyframe`, `setDuration` with clamp-confirm callback) — each an immutable rewrite handed to `push`. Autosave: `useEffect` on `timeline` → debounce 1.5s → `patchMotionProject(fileId, id, { timeline })` guarded by `opts.autosave !== false`; failures set `saveState: "error"` and retry ×3 with 2^n backoff.

- [ ] **Step 3: Implement `KvMotionEditor.tsx` + `page.tsx`.**

`KvMotionEditor` (client component) wires it together:
- TanStack Query: `getMotionProject(fileId, projectId)`; loading skeleton; error state with back link.
- Preview: `useEffect` builds `buildBoardStage({ container: previewRef.current, baseImageUrl: snapshot.base_image_url, overlays: snapshot.overlays, targetWidth, targetHeight })` sized to fit the center pane at the active ratio chip (default = snapshot's own ratio); stores `nodeById`; cleanup destroys the stage. Each render of `sampled` fires `applyTimeline` + `batchDraw`.
- Playback: `useEffect` on `playing` — `requestAnimationFrame` loop advancing `playheadMs` from a start timestamp, loop or stop at `duration_ms`.
- Canvas drag: Konva `dragend`/`transformend` listeners per node (attach once over `nodeById`; skip locked) → convert absolute node position back to normalized `{x, y}` (inverse of `applyTimeline`'s center math: `x = node.x()/W - ov.width/2`), scale from `node.scaleX()`, rotation from `node.rotation()` → `onOverlayTransformed(id, changed)`. Only overlays draggable; base image node listens to nothing.
- `editingInTime` → accent border on the preview wrapper + accent playhead (spec's "editing inside time" signal).
- Layout: left rail (track list from snapshot overlays, z-sorted, icons per payload type, base row locked at bottom), center stage, right `InspectorPanel`, bottom `TimelineDock` (tracks in the SAME z-sorted order), top bar (back link, name, ratio chips placeholder until Task 13, Export button placeholder, save indicator from `saveState`).
- `Cmd+Z`/`Shift+Cmd+Z` at the page level → `undo`/`redo`.
- **Resync from KV** (top-bar overflow menu item): confirm dialog warning "Tracks for overlays deleted in KV will be removed; keyframes for surviving overlays are kept." On confirm: fetch the board's CURRENT overlays (same source Task 11's create uses), build a new snapshot, drop timeline tracks whose `overlay_id` no longer exists (pure helper `pruneTimelineToOverlays(timeline, overlayIds)` in `useMotionEditorState.ts` — add a unit test: track for a surviving id stays, track for a removed id is dropped), `push` the pruned timeline, PATCH `{ snapshot, timeline }`, rebuild the preview stage.

`page.tsx` mirrors the existing `[file_id]/page.tsx` pattern (thin server component passing params to the client component).

- [ ] **Step 4: Run tests + build, then verify in the browser**

Run: `cd web && bun test src/components/studio/kv-generator/motion/ && bun run build`
Then: start the dev server via the Browser pane (launch config `web`), open an existing KV file, create a project via the console if the Task 11 entry isn't wired yet:
`fetch('/api/... motion-projects', …)` — or defer full click-through to Task 11 and verify here that the route renders with a seeded project id. Screenshot the editor showing: stage with overlays, dock rows matching the rail, playhead scrub moving overlays.
Expected: no console errors; scrubbing visibly interpolates.

- [ ] **Step 5: Commit**

```bash
git add "src/app/(canvas)/brands/[id]/studio/kv-generator/[file_id]/motion/" src/components/studio/kv-generator/motion/
git commit -m "feat(web): KV motion editor page — snapshot preview, auto-keyframe, autosave"
```

---

### Task 11: Entry point — Motion tab replacement + flag swap

**Files:**
- Modify: `web/src/lib/featureFlags/constants.ts`
- Create: `web/src/components/studio/kv-generator/motion/KvMotionProjectsPanel.tsx`
- Modify: `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx` (Motion-mode branch)
- Modify: `web/src/components/studio/kv-generator/KvCanvasTopNav.tsx` (flag prop source)
- Test: `web/src/components/studio/kv-generator/motion/KvMotionProjectsPanel.test.tsx`

**Interfaces:**
- Consumes: `listMotionProjects`, `createMotionProject`, `deleteMotionProject` (Task 7); `DEFAULT_TIMELINE` (Task 1); router push.
- Produces: Motion tab now renders `KvMotionProjectsPanel` (list + "New motion" → creates project with snapshot from the ACTIVE board's overlays + base image → `router.push` to the editor route). Old `KvMotionPanel`/`useKvMotion` wiring in `KvGeneratorLayout` is removed from render (imports deleted from the layout ONLY — files stay).

- [ ] **Step 1: Add the new flag constant**

```ts
KV_MOTION_EDITOR: "show-kv-motion-editor",
```

(keep `KV_MOTION: "show-kv-motion"` — the frozen I2V gate; do not delete.)

- [ ] **Step 2: Write failing panel tests**

```tsx
// KvMotionProjectsPanel.test.tsx — mock services/kv/motionProjects with bun's mock.module,
// render inside a QueryClientProvider, assert:
// 1. lists project names returned by listMotionProjects
// 2. "New motion" calls createMotionProject with a snapshot containing the
//    active board's overlays and base_image_url, then router.push to
//    /brands/<id>/studio/kv-generator/<fileId>/motion/<newId>
// 3. delete button calls deleteMotionProject
// Use within(document.body); mock next/navigation useRouter/useParams as the
// neighboring KvMotionPanel.test.tsx already does — copy its mock block.
```

Write the three tests concretely following `KvMotionPanel.test.tsx`'s existing mock structure (same providers, same router mock — it is the direct predecessor of this panel).

- [ ] **Step 3: Implement the panel**

Props: `{ fileId: string; brandId: string; activeGenerationId: string | null; activeBoard: { imageUrl: string; width: number; height: number; overlays: StudioOverlay[] } | null }`. Renders the project list (name, updated-at, delete) + "New motion" `Button` (disabled with tooltip when `activeBoard === null`). Create handler:

```ts
const project = await createMotionProject(fileId, {
  boardGenerationId: activeGenerationId!,
  snapshot: {
    base_image_url: activeBoard.imageUrl,
    board_width: activeBoard.width,
    board_height: activeBoard.height,
    overlays: activeBoard.overlays,
  },
  timeline: DEFAULT_TIMELINE(),
});
router.push(`/brands/${brandId}/studio/kv-generator/${fileId}/motion/${project.id}`);
```

- [ ] **Step 4: Swap the Motion-mode branch in `KvGeneratorLayout.tsx`**

In the Motion mode section (`── Motion mode ──` around line 1973): replace the `KvMotionPanel` + `KvMotionViewport` render with `KvMotionProjectsPanel`, passing the active board's data (the layout already resolves the pinned/active generation and its overlays for Resize — reuse the same variables). Remove the now-unused `useKvMotion`/`KvMotionPanel`/`KvMotionViewport`/video-model imports from the LAYOUT ONLY. Gate the tab on `KV_MOTION_EDITOR` where `KvCanvasTopNav`'s show-motion prop is computed (grep `KV_MOTION` usage at the layout level and switch the constant).

- [ ] **Step 5: Run tests + build + browser click-through**

Run: `cd web && bun test src/components/studio/kv-generator/ && bun run build`
Browser: enable `show-kv-motion-editor` for your dev workspace in PostHog (manual), open a KV file → Motion tab → New motion → editor opens → author a 2-keyframe fade → reload → timeline persisted. Screenshot for the PR.
Expected: full loop works; old I2V panel unreachable.

- [ ] **Step 6: Commit**

```bash
git add src/lib/featureFlags/constants.ts src/components/studio/kv-generator/motion/KvMotionProjectsPanel.tsx src/components/studio/kv-generator/motion/KvMotionProjectsPanel.test.tsx src/components/studio/kv-generator/KvGeneratorLayout.tsx src/components/studio/kv-generator/KvCanvasTopNav.tsx
git commit -m "feat(web): motion tab lists timeline projects; I2V panel unmounted behind frozen flag"
```

---

### Task 12: Presets, stagger, audio row

**Files:**
- Create: `web/src/lib/motion/presets.ts`
- Test: `web/src/lib/motion/presets.test.ts`
- Create: `web/src/components/studio/kv-generator/motion/KvMotionAudioRow.tsx`
- Modify: `web/src/components/studio/kv-generator/motion/KvMotionEditor.tsx` (preset dropdown per rail row, Stagger button, mount audio row via `audioSlot`)

**Interfaces:**
- Consumes: `writeAutoKeyframes` NOT used here — presets write keyframes directly; `renderAudioMix` is used at export (Task 13), not here.
- Produces:

```ts
export type MotionPresetId = "fade-in" | "slide-in-left" | "slide-in-right" | "slide-in-up" | "slide-in-down" | "pop-in" | "fade-out" | "slide-out-left" | "slide-out-right";
export function applyPreset(
  timeline: MotionTimeline,
  base: Map<string, MotionProps>,
  overlayId: string,
  preset: MotionPresetId,
  atMs: number,          // insert time (entrance starts here / exit ends at duration)
): MotionTimeline;
export function applyStagger(
  timeline: MotionTimeline,
  base: Map<string, MotionProps>,
  orderedOverlayIds: string[],   // z-order from the rail
  preset: MotionPresetId,
  stepMs?: number,               // default 150
): MotionTimeline;
```

Preset semantics — plain keyframes, no preset state (spec): e.g. `fade-in` at `atMs` = `{t: atMs, opacity: 0, easing: "linear"}` + `{t: atMs + 500, opacity: base.opacity, easing: "out"}`; `slide-in-left` also writes `x: base.x - 0.15 → base.x`; `pop-in` writes `scale: 0.6 → 1` + the fade pair. Replaces any existing keyframes for the props it touches on that track (deterministic re-apply).

- [ ] **Step 1: Write failing preset tests** — fade-in writes the opacity pair; slide-in-left writes x + opacity; stagger offsets each overlay's start by `i * stepMs` in the given order; re-applying a preset does not duplicate keyframes (same t_ms count). Concrete assertions in the style of Task 3's tests.

- [ ] **Step 2: Implement `presets.ts`** (~90 lines: a `PRESET_WRITERS: Record<MotionPresetId, (base: MotionProps, atMs: number) => MotionKeyframe[]>` table + `applyPreset` = remove-then-insert those keyframes immutably + `applyStagger` = fold `applyPreset` over ids with `atMs = i * stepMs`).

- [ ] **Step 3: Run to verify pass, wire the UI** — rail rows get a small preset `<select>` (value resets to placeholder after applying, since presets leave no state), toolbar gets a Stagger `Button` + preset select. Both call `push(applyPreset(...), undefined)` (each application = one undo step).

- [ ] **Step 4: Implement `KvMotionAudioRow.tsx`** — mounted into `TimelineDock`'s `audioSlot`. Empty state: upload button → POST to the overlay-assets route (copy the upload call from wherever the layers panel uploads overlay images — grep `overlay-assets` in `services/`), decode locally (`AudioContext.decodeAudioData`) to reject undecodable files at upload (spec) and to draw peaks once (canvas, 2px bars). Sets `timeline.audio` defaults `{ start_ms: 0, trim_in_ms: 0, trim_out_ms: min(bufferMs, duration_ms), volume: 1, fade_in_ms: 0, fade_out_ms: 0 }` + PATCHes `audio_url`. Filled state: clip body drag → `start_ms`; edge handles → trims; popover (frndos `BaseModal` or inline popover per existing kv patterns) → volume slider + fade inputs; remove button → clears `timeline.audio` + PATCH `audio_url: null`. Each mutation = one `push`.

- [ ] **Step 5: Tests + build + browser verify** (upload an mp3, see waveform, scrub-play hears audio via the preview `<audio>` element seeked in `KvMotionEditor`).

Run: `cd web && bun test src/lib/motion/ src/components/studio/kv-generator/motion/ && bun run build`

- [ ] **Step 6: Commit**

```bash
git add src/lib/motion/presets.ts src/lib/motion/presets.test.ts src/components/studio/kv-generator/motion/KvMotionAudioRow.tsx src/components/studio/kv-generator/motion/KvMotionEditor.tsx
git commit -m "feat(web): motion presets + stagger + audio track row"
```

---

### Task 13: Ratio chips + export dialog (multi-ratio render → upload → exports list)

**Files:**
- Create: `web/src/components/studio/kv-generator/motion/KvMotionExportDialog.tsx`
- Create: `web/src/components/studio/kv-generator/motion/exportMotion.ts`
- Test: `web/src/components/studio/kv-generator/motion/exportMotion.test.ts`
- Modify: `web/src/components/studio/kv-generator/motion/KvMotionEditor.tsx` (ratio chips live-swap preview; Export opens dialog)

**Interfaces:**
- Consumes: `buildBoardStage`, `applyTimeline`, `sampleTimelineAt`, `encodeTimelineToMp4`, `renderAudioMix`, `transformOverlayForAspect` (from `@/lib/studio/kv/overlayAspect` — adapter layer, allowed), `createMotionExport`, overlay-asset upload.
- Produces:

```ts
export const MOTION_RATIOS = [
  { id: "1:1", w: 1080, h: 1080 },
  { id: "9:16", w: 1080, h: 1920 },
  { id: "16:9", w: 1920, h: 1080 },
] as const;
export function remapSnapshotForRatio(snapshot: KvMotionSnapshot, targetW: number, targetH: number): StudioOverlay[]; // maps transformOverlayForAspect over overlays
export async function exportMotionRatio(opts: {
  snapshot: KvMotionSnapshot; timeline: MotionTimeline;
  ratio: { id: string; w: number; h: number };
  audioBuffer?: AudioBuffer | null;
  signal?: AbortSignal; onProgress?: (frac: number) => void;
}): Promise<Blob>;
```

`exportMotionRatio`: preload check (`document.fonts.ready` + probe every overlay image URL, throwing `MotionAssetError(layerName)` on failure — spec: name the layer), then `buildBoardStage` (detached, native ratio size, remapped overlays), then `encodeTimelineToMp4` with `drawFrame = (t) => { applyTimeline({...sampled at t...}); layer.draw(); }` and `canvas = stage.getLayers()[0].getCanvas()._canvas`, finally `stage.destroy()` in a `finally`.

- [ ] **Step 1: Write failing tests for `remapSnapshotForRatio` + the `MotionAssetError` preload path** (mock `loadImage` to reject for one overlay; expect the error to carry that overlay's display name; expect same-aspect remap to be identity — `transformOverlayForAspect` no-ops within 1e-6).

- [ ] **Step 2: Implement `exportMotion.ts`** per the interface block above (≈100 lines; sequential, no parallelism).

- [ ] **Step 3: Implement `KvMotionExportDialog.tsx`** — frndos `BaseModal`: checkbox per `MOTION_RATIOS` entry (default: the snapshot's own ratio checked), per-ratio progress bar + status (`waiting / rendering x% / uploading / done / failed`), Cancel (aborts the shared `AbortController`). Flow per checked ratio, sequential: decode+`renderAudioMix` once (if `timeline.audio`), `exportMotionRatio` → upload blob as `motion-${ratio.id}.mp4` via overlay-assets → `createMotionExport` → row appears in an "Exports" list inside the dialog (from `listMotionExports`, with download links). Upload failure keeps the blob and shows Retry + "Download locally" (`URL.createObjectURL`) — spec: render time is never lost. `beforeunload` guard while any ratio is in-flight. Export button in the top bar disabled with a tooltip when `await canExportMp4()` is false (checked once on editor mount).

- [ ] **Step 4: Wire ratio chips** in `KvMotionEditor` — chip click rebuilds the preview stage with `remapSnapshotForRatio` dims (timeline untouched — spec: read-only per ratio).

- [ ] **Step 5: Tests + build + full browser verify**

Run: `cd web && bun test src/components/studio/kv-generator/motion/ && bunx tsc --noEmit && bun run build`
Browser: author fade+slide on 2 layers + audio → Export 1:1 + 9:16 → both MP4s download/play (check: overlays animate, audio fades, text crisp) → exports listed after reload.
Expected: preview and exported MP4 visually identical per ratio.

- [ ] **Step 6: Commit**

```bash
git add src/components/studio/kv-generator/motion/KvMotionExportDialog.tsx src/components/studio/kv-generator/motion/exportMotion.ts src/components/studio/kv-generator/motion/exportMotion.test.ts src/components/studio/kv-generator/motion/KvMotionEditor.tsx
git commit -m "feat(web): multi-ratio client-side mp4 export with upload + export history"
```

---

## Self-review checklist (run after all tasks)

1. Spec coverage: engine purity (T1–3, T6), one-stage rule (T4–5), editor + auto-keyframe (T8–10), entry/flag swap (T11), presets/stagger/audio (T12), ratios/export/error handling (T13). Non-goals untouched: no Ken Burns, no styling keyframes, no Worker.
2. `bun test` full suite green (pre-existing RTL-screen failures aside per baseline); `bunx tsc --noEmit` clean; `bun run build` green.
3. Boundary test green — proves the reuse contract mechanically.
4. Grep `renderHiddenStage` callers unchanged; `git diff develop --stat` shows zero edits to `KvMotionPanel.tsx`, `useKvMotion.ts`, `KvMotionViewport.tsx` (unmounted, not modified).
5. Rollout note for the PR body: enable `show-kv-motion-editor`, disable `show-kv-motion` in PostHog (manual, both envs), land AFTER the api PR.
