# KV Motion — canvas transform (scale/rotate handles, onion-skin, auto-preview) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Motion canvas a complete animation tool: corner/rotate handles that auto-keyframe `scale`/`rotation`, onion-skin ghosts + a motion path for the selected layer, and a once-through auto-preview with a keyframe badge/HUD after every canvas transform.

**Architecture:** All derivation is pure and unit-tested (`onionSkin.ts`, `transformerStyle.ts`, `panHitTest.ts`, `poseToNode` in `applyTimeline.ts`, `previewOnce` in `useMotionEditorState`). `KvMotionTileStage` stays a dumb painter: it mounts one `Konva.Transformer` in place of the dashed selection outline, paints ghosts/path from an `onion` prop, and renders a DOM badge; `KvMotionEditor` wires camera scale, the focused tile's remapped timeline, the pan guard, the playback loop and analytics. The persisted timeline document, sampler, `writeAutoKeyframes`, Inspector and export are untouched.

**Tech Stack:** Next.js 16 / React 19 / TypeScript, Konva (imperative, lazy-imported), `bun test` (jsdom; NOT vitest), PostHog via `src/lib/analytics/kv-generator-events.ts`.

**Spec:** `docs/superpowers/specs/2026-09-14-kv-motion-canvas-transform-design.md`

**Worktree:** create via `superpowers:using-git-worktrees` at execution time — `web/` repo, branch `feature/daffa/vc-kv-motion-canvas-transform` from `develop`, under `web/.worktrees/kv-motion-canvas-transform`. Run `bun install` inside the worktree before any build (Turbopack rejects a symlinked `node_modules`).

## Global Constraints

- Web only. Every path below is relative to `web/`.
- Tests run with `bun test <file>` — never `bunx vitest`. Never run `bun test` on a whole directory (memory blow-up). Never `git stash`.
- `MotionProps.scale` stays ONE uniform number; Transformer must never produce `scaleX ≠ scaleY` (corner anchors only, `keepRatio: true`, `centeredScaling: true`).
- `previewOnce` is session-only UI state: never persisted, never read by export.
- Transformer, ghosts, path and badge exist ONLY on the focused tile; ghosts/path/badge are hidden while `playing`.
- Analytics: no raw `posthog.capture`; typed wrapper in `kv-generator-events.ts`; event name `kv_generator.motion_overlay_transformed`.
- Commit format `<type>(web): <description>`, ending with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

---

## File map

| File | Responsibility |
|---|---|
| Create `src/components/studio/kv-generator/motion/onionSkin.ts` | Pure: `onionSkinFor`, `onionNeighbors`, `badgeLabel`, `autoPreviewRange` |
| Create `…/motion/onionSkin.test.ts` | Tests for the above |
| Modify `…/motion/applyTimeline.ts` | Extract `poseToNode` + `poseCenter`; `applyTimeline` calls `poseToNode` |
| Create `…/motion/applyTimeline.pose.test.ts` | Tests for `poseToNode`/`poseCenter` with a fake node |
| Create `…/motion/transformerStyle.ts` + `.test.ts` | Pure: camera-scale-compensated Transformer numbers |
| Create `…/motion/panHitTest.ts` + `.test.ts` | Pure: `isPanBlockingHit` |
| Modify `…/motion/useMotionEditorState.ts` | `previewOnce`, `playOnce`, `clearPreviewOnce`, `seekByUser`; `onOverlayTransformed` arms the preview and returns whether it did |
| Create `…/motion/useMotionEditorState.previewOnce.test.ts` | Tests for the above |
| Modify `src/lib/analytics/kv-generator-events.ts` | `trackKvMotionOverlayTransformed` |
| Create `src/lib/analytics/kv-generator-events.motionTransform.test.ts` | Wrapper test |
| Modify `…/motion/KvMotionTileStage.tsx` | Transformer replaces outline; `cameraScale`/`onion`/`badge`/`playing`/`playheadMs` props; onion paint; badge + HUD; `input` on commits |
| Modify `…/motion/KvMotionEditor.tsx` | Wire everything; pan guard; playback loop; analytics |

---

### Task 1: `onionSkin.ts` — pure derivations

**Files:**
- Create: `src/components/studio/kv-generator/motion/onionSkin.ts`
- Test: `src/components/studio/kv-generator/motion/onionSkin.test.ts`

**Interfaces:**
- Consumes: `sampleTimelineAt` from `@/lib/video-editor/sample`; `MotionProps`, `MotionTimeline`, `MotionTrack` from `@/lib/video-editor/timeline`.
- Produces:
  ```ts
  export type OnionPose = { tMs: number; props: MotionProps };
  export type OnionSkin = { keyframes: OnionPose[]; path: OnionPose[] };
  export function onionSkinFor(timeline: MotionTimeline, base: Map<string, MotionProps>, trackId: string): OnionSkin | null;
  export function onionNeighbors(skin: OnionSkin, playheadMs: number): { prev: OnionPose | null; next: OnionPose | null };
  export type BadgeKind = "base" | "on" | "between";
  export function badgeLabel(playheadMs: number, track: MotionTrack | null): { text: string; kind: BadgeKind };
  export const MIN_AUTO_PREVIEW_SPAN_MS = 100;
  export function autoPreviewRange(track: MotionTrack | null, playheadMs: number): { fromMs: number; toMs: number } | null;
  ```

- [ ] **Step 1: Write the failing tests**

```ts
// src/components/studio/kv-generator/motion/onionSkin.test.ts
import { describe, expect, it } from "bun:test";

import type { MotionProps, MotionTimeline, MotionTrack } from "@/lib/video-editor/timeline";

import {
  autoPreviewRange,
  badgeLabel,
  onionNeighbors,
  onionSkinFor,
} from "./onionSkin";

const rest: MotionProps = { x: 0.1, y: 0.2, scale: 1, rotation: 0, opacity: 1 };
const base = new Map<string, MotionProps>([["ov1", rest]]);

function tl(tracks: MotionTrack[]): MotionTimeline {
  return { version: 1, duration_ms: 5000, fps: 30, tracks };
}

const track: MotionTrack = {
  kind: "overlay",
  overlay_id: "ov1",
  keyframes: [
    { t_ms: 0, props: { x: 0.1 }, easing: "linear" },
    { t_ms: 1000, props: { opacity: 0.5 }, easing: "linear" },
    { t_ms: 2000, props: { x: 0.5, y: 0.6 }, easing: "linear" },
  ],
};

describe("onionSkinFor", () => {
  it("returns null when the track is missing or has < 2 keyframes", () => {
    expect(onionSkinFor(tl([]), base, "ov1")).toBeNull();
    const one: MotionTrack = { ...track, keyframes: [track.keyframes[0]] };
    expect(onionSkinFor(tl([one]), base, "ov1")).toBeNull();
  });

  it("returns null for an overlay absent from base", () => {
    expect(onionSkinFor(tl([track]), new Map(), "ov1")).toBeNull();
  });

  it("samples every distinct keyframe time, ascending, through the sampler", () => {
    const skin = onionSkinFor(tl([track]), base, "ov1")!;
    expect(skin.keyframes.map((k) => k.tMs)).toEqual([0, 1000, 2000]);
    // at 1000 x is halfway between 0.1 and 0.5 (linear), opacity is 0.5
    expect(skin.keyframes[1].props.x).toBeCloseTo(0.3);
    expect(skin.keyframes[1].props.opacity).toBe(0.5);
  });

  it("path only includes keyframes carrying x or y", () => {
    const skin = onionSkinFor(tl([track]), base, "ov1")!;
    expect(skin.path.map((k) => k.tMs)).toEqual([0, 2000]);
    expect(skin.path[1].props).toMatchObject({ x: 0.5, y: 0.6 });
  });
});

describe("onionNeighbors", () => {
  const skin = onionSkinFor(tl([track]), base, "ov1")!;
  it("picks the nearest keyframe strictly before / after the playhead", () => {
    const n = onionNeighbors(skin, 1500);
    expect(n.prev?.tMs).toBe(1000);
    expect(n.next?.tMs).toBe(2000);
  });
  it("on a keyframe, that keyframe is neither prev nor next", () => {
    const n = onionNeighbors(skin, 1000);
    expect(n.prev?.tMs).toBe(0);
    expect(n.next?.tMs).toBe(2000);
  });
  it("null at the ends", () => {
    expect(onionNeighbors(skin, 0).prev).toBeNull();
    expect(onionNeighbors(skin, 2000).next).toBeNull();
  });
});

describe("badgeLabel", () => {
  it("t=0 is the base pose", () => {
    expect(badgeLabel(0, track)).toEqual({ text: "Base pose", kind: "base" });
  });
  it("on a keyframe of the track", () => {
    expect(badgeLabel(2000, track)).toEqual({ text: "⏺ Keyframe 2.0s", kind: "on" });
  });
  it("between keyframes, and with no track at all", () => {
    expect(badgeLabel(1500, track)).toEqual({ text: "Keyframe @ 1.5s", kind: "between" });
    expect(badgeLabel(1500, null)).toEqual({ text: "Keyframe @ 1.5s", kind: "between" });
  });
});

describe("autoPreviewRange", () => {
  it("null at t=0", () => {
    expect(autoPreviewRange(track, 0)).toBeNull();
  });
  it("from the previous keyframe on the track to the playhead", () => {
    expect(autoPreviewRange(track, 1500)).toEqual({ fromMs: 1000, toMs: 1500 });
  });
  it("from 0 when no keyframe precedes the playhead (or no track)", () => {
    expect(autoPreviewRange(null, 800)).toEqual({ fromMs: 0, toMs: 800 });
  });
  it("ignores the keyframe AT the playhead — the one just written", () => {
    expect(autoPreviewRange(track, 2000)).toEqual({ fromMs: 1000, toMs: 2000 });
  });
  it("null when the span is under 100 ms", () => {
    expect(autoPreviewRange(track, 1050)).toBeNull();
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bun test src/components/studio/kv-generator/motion/onionSkin.test.ts`
Expected: FAIL — cannot resolve `./onionSkin`.

- [ ] **Step 3: Implement**

```ts
// src/components/studio/kv-generator/motion/onionSkin.ts
import { sampleTimelineAt } from "@/lib/video-editor/sample";
import type {
  MotionProps,
  MotionTimeline,
  MotionTrack,
} from "@/lib/video-editor/timeline";

/** One sampled pose of the selected track at one keyframe time. */
export type OnionPose = { tMs: number; props: MotionProps };

/** Everything the focused tile needs to paint onion-skin ghosts and the
 *  motion path for ONE track — playhead-independent on purpose, so the
 *  editor memoises it on (timeline, track) and the stage decides per playhead
 *  which two poses to ghost (`onionNeighbors`) without re-sampling.
 *  `keyframes`: the pose at every distinct keyframe time, ascending.
 *  `path`: the subset whose keyframe carries `x` or `y` — the dots of the
 *  motion path. */
export type OnionSkin = { keyframes: OnionPose[]; path: OnionPose[] };

function findTrack(timeline: MotionTimeline, trackId: string) {
  return timeline.tracks.find(
    (t) => t.kind === "overlay" && t.overlay_id === trackId
  );
}

/** `null` when there is nothing to ghost: unknown track/overlay, or fewer
 *  than two keyframe times (one keyframe has no "other" pose to show). Pass
 *  the TILE's remapped timeline + base so poses land in that tile's space. */
export function onionSkinFor(
  timeline: MotionTimeline,
  base: Map<string, MotionProps>,
  trackId: string
): OnionSkin | null {
  const track = findTrack(timeline, trackId);
  if (!track || !base.has(trackId)) return null;
  const times = Array.from(new Set(track.keyframes.map((k) => k.t_ms))).sort(
    (a, b) => a - b
  );
  if (times.length < 2) return null;
  const poseAt = (tMs: number): OnionPose => ({
    tMs,
    props: sampleTimelineAt(timeline, base, tMs).get(trackId)!,
  });
  const keyframes = times.map(poseAt);
  const pathTimes = new Set(
    track.keyframes
      .filter((k) => k.props.x !== undefined || k.props.y !== undefined)
      .map((k) => k.t_ms)
  );
  const path = keyframes.filter((k) => pathTimes.has(k.tMs));
  return { keyframes, path };
}

/** Nearest keyframe pose strictly before / strictly after the playhead. */
export function onionNeighbors(
  skin: OnionSkin,
  playheadMs: number
): { prev: OnionPose | null; next: OnionPose | null } {
  let prev: OnionPose | null = null;
  let next: OnionPose | null = null;
  for (const k of skin.keyframes) {
    if (k.tMs < playheadMs) prev = k;
    else if (k.tMs > playheadMs) {
      next = k;
      break;
    }
  }
  return { prev, next };
}

export type BadgeKind = "base" | "on" | "between";

function formatSeconds(ms: number): string {
  return `${(ms / 1000).toFixed(1)}s`;
}

/** The focused tile's badge: what the NEXT canvas transform will do. */
export function badgeLabel(
  playheadMs: number,
  track: MotionTrack | null
): { text: string; kind: BadgeKind } {
  if (playheadMs <= 0) return { text: "Base pose", kind: "base" };
  const on = track?.keyframes.some((k) => k.t_ms === playheadMs) ?? false;
  return on
    ? { text: `⏺ Keyframe ${formatSeconds(playheadMs)}`, kind: "on" }
    : { text: `Keyframe @ ${formatSeconds(playheadMs)}`, kind: "between" };
}

/** Below this the once-through preview after a transform shows nothing
 *  worth watching, so it is skipped. */
export const MIN_AUTO_PREVIEW_SPAN_MS = 100;

/** The window the editor plays once after a canvas transform at t>0: from
 *  the track's nearest keyframe BEFORE the playhead (0 when none) up to the
 *  playhead. `null` at t=0 (a base-pose edit animates nothing) or when the
 *  window is too short to read. Call it on the timeline AFTER the write —
 *  the keyframe at the playhead itself is excluded by the strict `<`. */
export function autoPreviewRange(
  track: MotionTrack | null,
  playheadMs: number
): { fromMs: number; toMs: number } | null {
  if (playheadMs <= 0) return null;
  let fromMs = 0;
  for (const k of track?.keyframes ?? []) {
    if (k.t_ms < playheadMs && k.t_ms > fromMs) fromMs = k.t_ms;
  }
  if (playheadMs - fromMs < MIN_AUTO_PREVIEW_SPAN_MS) return null;
  return { fromMs, toMs: playheadMs };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bun test src/components/studio/kv-generator/motion/onionSkin.test.ts`
Expected: PASS (15 tests).

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/motion/onionSkin.ts src/components/studio/kv-generator/motion/onionSkin.test.ts
git commit -m "feat(web): pure onion-skin, badge and auto-preview derivations for KV Motion

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Extract `poseToNode` / `poseCenter` from `applyTimeline`

**Files:**
- Modify: `src/components/studio/kv-generator/motion/applyTimeline.ts`
- Test: `src/components/studio/kv-generator/motion/applyTimeline.pose.test.ts` (new; the existing `applyTimeline.test.ts` keeps covering `applyTimeline` end-to-end)

**Interfaces:**
- Produces:
  ```ts
  export type PoseNodeLike = { x(v: number): unknown; y(v: number): unknown; scaleX(v: number): unknown; scaleY(v: number): unknown; rotation(v: number): unknown; opacity(v: number): unknown };
  export function poseCenter(ov: StudioOverlay, p: MotionProps, targetWidth: number, targetHeight: number): { x: number; y: number };
  export function poseToNode(node: PoseNodeLike, ov: StudioOverlay, p: MotionProps, targetWidth: number, targetHeight: number): void;
  ```

- [ ] **Step 1: Write the failing test**

```ts
// src/components/studio/kv-generator/motion/applyTimeline.pose.test.ts
import { describe, expect, it } from "bun:test";

import type { MotionProps } from "@/lib/video-editor/timeline";
import type { StudioOverlay } from "@/types/studio";

import { poseCenter, poseToNode } from "./applyTimeline";

const ov: StudioOverlay = {
  id: "o1",
  studio_file_id: "f",
  type: "text",
  x: 0.1,
  y: 0.2,
  width: 0.4,
  height: 0.2,
  rotation: 0,
  z: 1,
  payload: { type: "text", content: "Hi", color: "#000" },
  created_at: "t",
  updated_at: "t",
};

function fakeNode() {
  const set: Record<string, number> = {};
  const setter = (k: string) => (v: number) => {
    set[k] = v;
  };
  return {
    set,
    x: setter("x"),
    y: setter("y"),
    scaleX: setter("scaleX"),
    scaleY: setter("scaleY"),
    rotation: setter("rotation"),
    opacity: setter("opacity"),
  };
}

describe("poseCenter", () => {
  it("is the overlay box centre in target pixels", () => {
    const p: MotionProps = { x: 0.1, y: 0.2, scale: 1, rotation: 0, opacity: 1 };
    expect(poseCenter(ov, p, 1000, 500)).toEqual({ x: 300, y: 150 });
  });
});

describe("poseToNode", () => {
  it("sets centre position, uniform scale, rotation and clamped opacity", () => {
    const node = fakeNode();
    const p: MotionProps = { x: 0.5, y: 0.5, scale: 1.5, rotation: 30, opacity: 1.7 };
    poseToNode(node, ov, p, 1000, 500);
    expect(node.set).toEqual({
      x: 700,
      y: 300,
      scaleX: 1.5,
      scaleY: 1.5,
      rotation: 30,
      opacity: 1,
    });
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/components/studio/kv-generator/motion/applyTimeline.pose.test.ts`
Expected: FAIL — `poseCenter`/`poseToNode` are not exported.

- [ ] **Step 3: Implement — replace the `applyTimeline` body with the helpers**

Replace everything from `const clamp01` to the end of `applyTimeline.ts` with:

```ts
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

/** The subset of `Konva.Node` a pose write touches — typed structurally so
 *  the math is testable with a plain object (Konva won't paint in jsdom). */
export type PoseNodeLike = {
  x(v: number): unknown;
  y(v: number): unknown;
  scaleX(v: number): unknown;
  scaleY(v: number): unknown;
  rotation(v: number): unknown;
  opacity(v: number): unknown;
};

/** Where a pose puts the overlay's visual CENTRE, in target pixels. Nodes
 *  are center-offset by `buildBoardStage`, so this is also the node's x/y. */
export function poseCenter(
  ov: StudioOverlay,
  p: MotionProps,
  targetWidth: number,
  targetHeight: number
): { x: number; y: number } {
  return {
    x: (p.x + ov.width / 2) * targetWidth,
    y: (p.y + ov.height / 2) * targetHeight,
  };
}

/** Push ONE pose onto ONE node. The single place the pose→node math lives:
 *  `applyTimeline` (live playback), the onion-skin ghosts and anything else
 *  that positions a node from `MotionProps` must call this, so they cannot
 *  drift from each other. Position/scale pivot on the visual center and text
 *  width is NEVER touched (wrap computed once at build). */
export function poseToNode(
  node: PoseNodeLike,
  ov: StudioOverlay,
  p: MotionProps,
  targetWidth: number,
  targetHeight: number
): void {
  const c = poseCenter(ov, p, targetWidth, targetHeight);
  node.x(c.x);
  node.y(c.y);
  node.scaleX(p.scale);
  node.scaleY(p.scale);
  node.rotation(p.rotation);
  node.opacity(clamp01(p.opacity));
}

/** Push sampled values onto live Konva nodes. Caller batchDraws. */
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
    poseToNode(node, ov, p, args.targetWidth, args.targetHeight);
  }
}
```

- [ ] **Step 4: Run both applyTimeline test files**

Run: `bun test src/components/studio/kv-generator/motion/applyTimeline.pose.test.ts src/components/studio/kv-generator/motion/applyTimeline.test.ts`
Expected: PASS — the existing end-to-end tests are unchanged and still green.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/motion/applyTimeline.ts src/components/studio/kv-generator/motion/applyTimeline.pose.test.ts
git commit -m "refactor(web): extract poseToNode/poseCenter from applyTimeline

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: `transformerStyle.ts` and `panHitTest.ts`

**Files:**
- Create: `src/components/studio/kv-generator/motion/transformerStyle.ts`, `…/transformerStyle.test.ts`
- Create: `src/components/studio/kv-generator/motion/panHitTest.ts`, `…/panHitTest.test.ts`

**Interfaces:**
- Produces:
  ```ts
  export function transformerStyleForScale(cameraScale: number): { anchorSize: number; borderStrokeWidth: number; anchorStrokeWidth: number; rotateAnchorOffset: number };
  export function inverseCameraScale(cameraScale: number): number; // 1 / clamp(scale, 0.05, 20)
  export type HitNodeLike = { getParent(): HitNodeLike | null; getClassName(): string; draggable(): boolean };
  export function isPanBlockingHit(hit: HitNodeLike | null, overlayNodes: ReadonlySet<HitNodeLike>): boolean;
  ```

- [ ] **Step 1: Write the failing tests**

```ts
// src/components/studio/kv-generator/motion/transformerStyle.test.ts
import { describe, expect, it } from "bun:test";

import { inverseCameraScale, transformerStyleForScale } from "./transformerStyle";

describe("transformerStyleForScale", () => {
  it("at scale 1 returns the base sizes", () => {
    expect(transformerStyleForScale(1)).toEqual({
      anchorSize: 10,
      borderStrokeWidth: 1.5,
      anchorStrokeWidth: 1.5,
      rotateAnchorOffset: 28,
    });
  });
  it("inverse-scales so on-screen size stays constant when zoomed out", () => {
    const s = transformerStyleForScale(0.25);
    expect(s.anchorSize).toBe(40);
    expect(s.rotateAnchorOffset).toBe(112);
  });
  it("shrinks in stage px when zoomed in", () => {
    expect(transformerStyleForScale(2).anchorSize).toBe(5);
  });
  it("clamps degenerate scales instead of producing Infinity/NaN", () => {
    expect(inverseCameraScale(0)).toBe(20);
    expect(inverseCameraScale(Number.NaN)).toBe(1);
    expect(inverseCameraScale(1000)).toBe(0.05);
  });
});
```

```ts
// src/components/studio/kv-generator/motion/panHitTest.test.ts
import { describe, expect, it } from "bun:test";

import { isPanBlockingHit, type HitNodeLike } from "./panHitTest";

function node(
  className: string,
  parent: HitNodeLike | null = null,
  draggable = false
): HitNodeLike {
  return {
    getClassName: () => className,
    getParent: () => parent,
    draggable: () => draggable,
  };
}

describe("isPanBlockingHit", () => {
  const layer = node("Layer");
  const group = node("Group", layer);

  it("no hit (base image / empty) → pans", () => {
    expect(isPanBlockingHit(null, new Set())).toBe(false);
    expect(isPanBlockingHit(node("Image", group), new Set())).toBe(false);
  });

  it("a draggable overlay node blocks the pan; a locked one does not", () => {
    const free = node("Text", group, true);
    const locked = node("Text", group, false);
    expect(isPanBlockingHit(free, new Set([free]))).toBe(true);
    expect(isPanBlockingHit(locked, new Set([locked]))).toBe(false);
  });

  it("a child of an overlay group resolves to its overlay", () => {
    const overlay = node("Group", group, true);
    const run = node("Text", overlay);
    expect(isPanBlockingHit(run, new Set([overlay]))).toBe(true);
  });

  it("a Transformer anchor (any descendant of a Transformer) blocks the pan", () => {
    const tr = node("Transformer", layer);
    const anchor = node("Rect", tr);
    expect(isPanBlockingHit(anchor, new Set())).toBe(true);
    expect(isPanBlockingHit(tr, new Set())).toBe(true);
  });
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `bun test src/components/studio/kv-generator/motion/transformerStyle.test.ts src/components/studio/kv-generator/motion/panHitTest.test.ts`
Expected: FAIL — modules not found.

- [ ] **Step 3: Implement both modules**

```ts
// src/components/studio/kv-generator/motion/transformerStyle.ts
/** The Transformer's handle sizes at camera scale 1, in stage px. */
const BASE = {
  anchorSize: 10,
  borderStrokeWidth: 1.5,
  anchorStrokeWidth: 1.5,
  rotateAnchorOffset: 28,
} as const;

/** `useCanvasCamera` ranges 0.1–5; the wider clamp only guards against a
 *  0/NaN scale during the first layout pass. */
export function inverseCameraScale(cameraScale: number): number {
  if (!Number.isFinite(cameraScale)) return 1;
  return 1 / Math.min(20, Math.max(0.05, cameraScale));
}

/** Every tile stage sits inside a CSS-scaled camera layer, so a 10 px anchor
 *  drawn in stage px renders at 10 × cameraScale on screen — ~3.5 px at a
 *  typical fit. Dividing by the scale keeps the handles the same size on
 *  screen at every zoom, which is the only size that matters for grabbing. */
export function transformerStyleForScale(cameraScale: number) {
  const k = inverseCameraScale(cameraScale);
  return {
    anchorSize: BASE.anchorSize * k,
    borderStrokeWidth: BASE.borderStrokeWidth * k,
    anchorStrokeWidth: BASE.anchorStrokeWidth * k,
    rotateAnchorOffset: BASE.rotateAnchorOffset * k,
  };
}
```

```ts
// src/components/studio/kv-generator/motion/panHitTest.ts
/** The slice of `Konva.Node` the pan guard reads — structural so it can be
 *  tested with plain objects. */
export type HitNodeLike = {
  getParent(): HitNodeLike | null;
  getClassName(): string;
  draggable(): boolean;
};

/** Should a press that hit `hit` on the focused tile be swallowed by the
 *  stage (drag / transform) rather than start a camera pan?
 *
 *  Walks up from the hit: a Transformer (its anchors are children of it)
 *  always blocks — the press is the start of a scale/rotate; an overlay node
 *  blocks iff it is draggable (a locked layer is inert, so panning through
 *  it is fine); anything else (base image, nothing) pans. */
export function isPanBlockingHit(
  hit: HitNodeLike | null,
  overlayNodes: ReadonlySet<HitNodeLike>
): boolean {
  let n: HitNodeLike | null = hit;
  while (n) {
    if (n.getClassName() === "Transformer") return true;
    if (overlayNodes.has(n)) return n.draggable();
    n = n.getParent();
  }
  return false;
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `bun test src/components/studio/kv-generator/motion/transformerStyle.test.ts src/components/studio/kv-generator/motion/panHitTest.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/motion/transformerStyle.ts src/components/studio/kv-generator/motion/transformerStyle.test.ts src/components/studio/kv-generator/motion/panHitTest.ts src/components/studio/kv-generator/motion/panHitTest.test.ts
git commit -m "feat(web): camera-compensated transformer style + pan hit predicate for KV Motion

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: `previewOnce` in `useMotionEditorState`

**Files:**
- Modify: `src/components/studio/kv-generator/motion/useMotionEditorState.ts` (around lines 389–468 for state/seek/togglePlay/selectKeyframe; ~647–656 for `onOverlayTransformed`; the `return {…}` block at ~1056)
- Test: `src/components/studio/kv-generator/motion/useMotionEditorState.previewOnce.test.ts` (new file — the main test file is 21 KB; keep new topics in their own file per the existing split)

**Interfaces:**
- Consumes: `autoPreviewRange` from `./onionSkin` (Task 1).
- Produces on the hook's return value:
  ```ts
  previewOnce: { fromMs: number; toMs: number } | null;
  playOnce: (fromMs: number, toMs: number) => void;   // sets previewOnce, seeks to fromMs, playing = true
  clearPreviewOnce: () => void;
  seekByUser: (tMs: number) => void;                  // clearPreviewOnce + seek
  onOverlayTransformed: (overlayId: string, changed: Partial<MotionProps>) => boolean; // true iff a preview was armed
  ```
  `togglePlay` and `selectKeyframe` also clear `previewOnce`. `seek` is unchanged.

- [ ] **Step 1: Write the failing tests**

```ts
// src/components/studio/kv-generator/motion/useMotionEditorState.previewOnce.test.ts
import { createElement, type ReactNode } from "react";
import { describe, expect, it } from "bun:test";
import { act, renderHook } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { KvMotionProject } from "@/types/kv/motionProject";
import type { StudioOverlay } from "@/types/studio";

import { useMotionEditorState } from "./useMotionEditorState";

const ov1: StudioOverlay = {
  id: "ov1",
  studio_file_id: "f1",
  type: "text",
  x: 0.1,
  y: 0.2,
  width: 0.3,
  height: 0.1,
  rotation: 0,
  z: 0,
  payload: { type: "text", content: "Headline", color: "#000000" },
  created_at: "t",
  updated_at: "t",
};

const qcWrapper = ({ children }: { children: ReactNode }) =>
  createElement(
    QueryClientProvider,
    { client: new QueryClient({ defaultOptions: { queries: { retry: false } } }) },
    children
  );

function makeProject(): KvMotionProject {
  return {
    id: "p1",
    studioFileId: "f1",
    boardGenerationId: "g1",
    name: "Test",
    audioUrl: null,
    durationMs: 5000,
    fps: 30,
    createdAt: "",
    updatedAt: "",
    snapshot: {
      base_image_url: "https://x/y.png",
      board_width: 1080,
      board_height: 1080,
      overlays: [ov1],
    },
    timeline: { version: 1, duration_ms: 5000, fps: 30, tracks: [] },
  };
}

function setup() {
  return renderHook(() => useMotionEditorState(makeProject(), { autosave: false }), {
    wrapper: qcWrapper,
  });
}

describe("useMotionEditorState — previewOnce", () => {
  it("starts null and playOnce arms it, seeks to fromMs and starts playing", () => {
    const { result } = setup();
    expect(result.current.previewOnce).toBeNull();
    act(() => result.current.playOnce(1000, 2500));
    expect(result.current.previewOnce).toEqual({ fromMs: 1000, toMs: 2500 });
    expect(result.current.playheadMs).toBe(1000);
    expect(result.current.playing).toBe(true);
  });

  it("clearPreviewOnce drops it without touching playing", () => {
    const { result } = setup();
    act(() => result.current.playOnce(0, 1000));
    act(() => result.current.clearPreviewOnce());
    expect(result.current.previewOnce).toBeNull();
    expect(result.current.playing).toBe(true);
  });

  it("seekByUser clears it; plain seek (the playback loop's) does not", () => {
    const { result } = setup();
    act(() => result.current.playOnce(0, 1000));
    act(() => result.current.seek(500));
    expect(result.current.previewOnce).not.toBeNull();
    act(() => result.current.seekByUser(700));
    expect(result.current.previewOnce).toBeNull();
    expect(result.current.playheadMs).toBe(700);
  });

  it("togglePlay and selectKeyframe clear it", () => {
    const { result } = setup();
    act(() => result.current.playOnce(0, 1000));
    act(() => result.current.togglePlay());
    expect(result.current.previewOnce).toBeNull();
    expect(result.current.playing).toBe(false);
    act(() => result.current.playOnce(0, 1000));
    act(() => result.current.selectKeyframe("ov1", 0));
    expect(result.current.previewOnce).toBeNull();
  });
});

describe("useMotionEditorState — onOverlayTransformed arms the auto-preview", () => {
  it("at t>0 with no earlier keyframe: previews 0 → playhead and returns true", () => {
    const { result } = setup();
    act(() => result.current.seek(2000));
    let armed = false;
    act(() => {
      armed = result.current.onOverlayTransformed("ov1", { scale: 1.5 });
    });
    expect(armed).toBe(true);
    expect(result.current.previewOnce).toEqual({ fromMs: 0, toMs: 2000 });
    expect(result.current.playing).toBe(true);
    expect(result.current.playheadMs).toBe(0);
    // the write itself happened: anchor at 0 + keyframe at 2000
    const kfs = result.current.timeline.tracks[0].keyframes.map((k) => k.t_ms).sort();
    expect(kfs).toEqual([0, 2000]);
  });

  it("previews from the nearest earlier keyframe", () => {
    const { result } = setup();
    act(() => result.current.seek(1000));
    act(() => result.current.onOverlayTransformed("ov1", { x: 0.3 }));
    act(() => result.current.togglePlay()); // stop the first preview
    act(() => result.current.seek(3000));
    act(() => result.current.onOverlayTransformed("ov1", { x: 0.6 }));
    expect(result.current.previewOnce).toEqual({ fromMs: 1000, toMs: 3000 });
  });

  it("at t=0 writes the base pose and arms nothing", () => {
    const { result } = setup();
    let armed = true;
    act(() => {
      armed = result.current.onOverlayTransformed("ov1", { x: 0.5 });
    });
    expect(armed).toBe(false);
    expect(result.current.previewOnce).toBeNull();
    expect(result.current.playing).toBe(false);
  });

  it("never arms while already playing", () => {
    const { result } = setup();
    act(() => result.current.seek(2000));
    act(() => result.current.togglePlay());
    let armed = true;
    act(() => {
      armed = result.current.onOverlayTransformed("ov1", { rotation: 45 });
    });
    expect(armed).toBe(false);
    expect(result.current.previewOnce).toBeNull();
  });

  it("never arms for a span under 100 ms", () => {
    const { result } = setup();
    act(() => result.current.seek(50));
    let armed = true;
    act(() => {
      armed = result.current.onOverlayTransformed("ov1", { x: 0.5 });
    });
    expect(armed).toBe(false);
    expect(result.current.previewOnce).toBeNull();
  });

  it("still returns false and writes nothing for an overlay absent from the snapshot", () => {
    const { result } = setup();
    act(() => result.current.seek(2000));
    let armed = true;
    act(() => {
      armed = result.current.onOverlayTransformed("ghost", { x: 0.5 });
    });
    expect(armed).toBe(false);
    expect(result.current.timeline.tracks).toHaveLength(0);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/components/studio/kv-generator/motion/useMotionEditorState.previewOnce.test.ts`
Expected: FAIL — `playOnce is not a function`.

- [ ] **Step 3: Implement**

In `useMotionEditorState.ts`:

(a) Add the import next to the other `./` imports:
```ts
import { autoPreviewRange } from "./onionSkin";
```

(b) Directly after the `previewRange` clamp `useEffect` (ends with `}, [timeline.duration_ms]);`), add:
```ts
  // Once-through auto-preview after a canvas transform at t>0 (design spec
  // 2026-09-14 §3): the playback loop treats this as its bounds — ABOVE
  // `previewRange` — with no wrap regardless of `loop`, and clears it when it
  // reaches `toMs`. Session-only UI state like `previewRange`: never
  // persisted, never read by export. Kept separate from `previewRange` so the
  // ruler's accent band doesn't flash and the user's loop toggle can't turn a
  // one-shot preview into an endless cycle.
  const [previewOnce, setPreviewOnce] = useState<{
    fromMs: number;
    toMs: number;
  } | null>(null);
  const clearPreviewOnce = useCallback(() => setPreviewOnce(null), []);
```

(c) Replace the `seek` / `togglePlay` pair with:
```ts
  const seek = useCallback(
    (tMs: number) => {
      setPlayheadMs(clamp(tMs, 0, timeline.duration_ms));
    },
    [timeline.duration_ms]
  );

  // The playback loop's per-tick `seek` must NOT cancel an auto-preview, but
  // any seek the USER makes (dock scrub, transport, keyboard) must — so the
  // user-facing surfaces get this wrapper and `seek` keeps its contract.
  const seekByUser = useCallback(
    (tMs: number) => {
      setPreviewOnce(null);
      seek(tMs);
    },
    [seek]
  );

  const playOnce = useCallback(
    (fromMs: number, toMs: number) => {
      setPreviewOnce({ fromMs, toMs });
      seek(fromMs);
      setPlaying(true);
    },
    [seek]
  );

  const togglePlay = useCallback(() => {
    setPreviewOnce(null);
    setPlaying((p) => !p);
  }, []);
```

(d) In `selectKeyframe`, add `setPreviewOnce(null);` as the first line of the callback body (a diamond click is a user seek).

(e) Replace `onOverlayTransformed` with:
```ts
  const onOverlayTransformed = useCallback(
    (overlayId: string, changed: Partial<MotionProps>): boolean => {
      if (!base.has(overlayId)) return false; // not in the snapshot — ignore
      const next = writeAutoKeyframes(
        timeline,
        base,
        overlayId,
        playheadMs,
        changed
      );
      push(next, `drag:${overlayId}:${playheadMs}`);
      // Play the move back once so a drag at t>0 immediately reads as
      // motion. Skipped at t=0 (base pose — nothing to show), while already
      // playing (don't hijack the transport), and for a blink-short span.
      if (playing) return false;
      const track =
        next.tracks.find(
          (t) => t.kind === "overlay" && t.overlay_id === overlayId
        ) ?? null;
      const range = autoPreviewRange(track, playheadMs);
      if (!range) return false;
      playOnce(range.fromMs, range.toMs);
      return true;
    },
    [base, timeline, playheadMs, playing, push, playOnce]
  );
```

(f) Add to the returned object, after `setPreviewRange,`:
```ts
    previewOnce,
    playOnce,
    clearPreviewOnce,
    seekByUser,
```

- [ ] **Step 4: Run the new test file AND the existing state suites**

Run: `bun test src/components/studio/kv-generator/motion/useMotionEditorState.previewOnce.test.ts src/components/studio/kv-generator/motion/useMotionEditorState.test.ts src/components/studio/kv-generator/motion/useMotionEditorState.propGroup.test.ts src/components/studio/kv-generator/motion/useMotionEditorState.layers.test.tsx`
Expected: all PASS. (The existing "drag at t>0 creates anchor + keyframe and one undo step reverts both" test still holds — `playOnce` doesn't touch the undo stack.)

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/motion/useMotionEditorState.ts src/components/studio/kv-generator/motion/useMotionEditorState.previewOnce.test.ts
git commit -m "feat(web): once-through auto-preview state after a KV Motion canvas transform

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Analytics wrapper `trackKvMotionOverlayTransformed`

**Files:**
- Modify: `src/lib/analytics/kv-generator-events.ts` (append right after `trackKvMotionCanvasZoomChanged`, ~line 1261)
- Test: `src/lib/analytics/kv-generator-events.motionTransform.test.ts`

**Interfaces:**
- Produces:
  ```ts
  export type KvMotionOverlayTransformInput = "drag" | "scale" | "rotate";
  export interface KvMotionOverlayTransformedProps { project_id: string; input: KvMotionOverlayTransformInput; at_t0: boolean; auto_preview: boolean }
  export const trackKvMotionOverlayTransformed: (p: KvMotionOverlayTransformedProps) => void; // "kv_generator.motion_overlay_transformed"
  ```

- [ ] **Step 1: Write the failing test** (copy the posthog mock verbatim from `layerDecomposition.events.test.ts` — a partial `mock.module` breaks other suites)

```ts
// src/lib/analytics/kv-generator-events.motionTransform.test.ts
import { describe, expect, it, mock } from "bun:test";

const capture = mock(() => {});

// Same prototype-preserving clone as layerDecomposition.events.test.ts —
// `mock.module` is process-global, and a factory returning only `default`
// would delete `isFeatureEnabled` for every other suite in the run.
const actualPosthog = await import("posthog-js");
const mockedDefault = Object.assign(
  Object.create(Object.getPrototypeOf(actualPosthog.default)),
  actualPosthog.default,
  { capture }
);

mock.module("posthog-js", () => ({
  ...actualPosthog,
  default: mockedDefault,
}));

const { trackKvMotionOverlayTransformed } = await import("./kv-generator-events");

describe("trackKvMotionOverlayTransformed", () => {
  it("captures the dot-namespaced event with input, t0 flag and preview flag", () => {
    trackKvMotionOverlayTransformed({
      project_id: "p1",
      input: "rotate",
      at_t0: false,
      auto_preview: true,
    });
    expect(capture).toHaveBeenCalledWith(
      "kv_generator.motion_overlay_transformed",
      expect.objectContaining({
        project_id: "p1",
        input: "rotate",
        at_t0: false,
        auto_preview: true,
      })
    );
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/lib/analytics/kv-generator-events.motionTransform.test.ts`
Expected: FAIL — `trackKvMotionOverlayTransformed is not a function`.

- [ ] **Step 3: Implement** — insert after the `trackKvMotionCanvasZoomChanged` export:

```ts
export type KvMotionOverlayTransformInput = "drag" | "scale" | "rotate";

export interface KvMotionOverlayTransformedProps {
  project_id: string;
  /** Which canvas gesture wrote the keyframe: a position drag, a corner
   *  (uniform scale) handle, or the rotate handle. Decided by the stage from
   *  which Konva listener fired, not by inspecting the keyframe. */
  input: KvMotionOverlayTransformInput;
  /** Playhead at 0 — the gesture edited the base pose, not an animation. */
  at_t0: boolean;
  /** Whether the editor played the resulting segment back once (it does at
   *  t>0 when not already playing and the span is ≥ 100 ms). */
  auto_preview: boolean;
}

/** A canvas-authored keyframe on the Motion editor (design spec
 *  `2026-09-14-kv-motion-canvas-transform-design.md`). Fires once per
 *  committed gesture (`dragend` / `transformend`) — never per move event. */
export const trackKvMotionOverlayTransformed = (
  p: KvMotionOverlayTransformedProps
) => safeCapture("kv_generator.motion_overlay_transformed", p);
```

- [ ] **Step 4: Run to verify it passes**

Run: `bun test src/lib/analytics/kv-generator-events.motionTransform.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lib/analytics/kv-generator-events.ts src/lib/analytics/kv-generator-events.motionTransform.test.ts
git commit -m "feat(web): analytics wrapper for KV Motion canvas-authored keyframes

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: `KvMotionTileStage` — Transformer replaces the selection outline

**Files:**
- Modify: `src/components/studio/kv-generator/motion/KvMotionTileStage.tsx`

**Interfaces:**
- Consumes: `transformerStyleForScale` (Task 3).
- Produces (props; new ones optional so the editor compiles until Task 9 wires them):
  ```ts
  onOverlayTransformed: (overlayId: string, changed: OverlayTransform, input: "drag" | "scale" | "rotate") => void;
  cameraScale?: number; // default 1
  ```
  Exported type `OverlayTransformInput = "drag" | "scale" | "rotate"`.

No unit test — Konva geometry does not run in jsdom; Task 10 verifies in the browser. Type-check the file after the edit with `bunx tsc --noEmit -p tsconfig.json 2>&1 | grep KvMotionTileStage` (the repo has a ~777-error baseline; only lines naming this file matter).

- [ ] **Step 1: Props and refs**

In the `Props` type:
- change `onOverlayTransformed` to `(overlayId: string, changed: OverlayTransform, input: OverlayTransformInput) => void;`
- add after `selectedOverlayId`:
```ts
  /** The camera layer's CSS scale — the Transformer's handles are drawn in
   *  stage px, so they are inverse-scaled by this to stay a constant size on
   *  screen (see `transformerStyleForScale`). */
  cameraScale?: number;
```
Above `type OverlayTransform`, add:
```ts
export type OverlayTransformInput = "drag" | "scale" | "rotate";
```
Add the import: `import { transformerStyleForScale } from "./transformerStyle";`

In the component signature add `cameraScale = 1,`. Replace the `outlineRef` declaration with:
```ts
  /** The live Transformer on the selected overlay, or null while nothing is
   *  selected on this (focused) tile. It draws the selection border itself,
   *  so there is no separate outline node any more. */
  const transformerRef = useRef<Konva.Transformer | null>(null);
  const cameraScaleRef = useRef(cameraScale);
```
and add `cameraScaleRef.current = cameraScale;` inside the existing `useLayoutEffect` that syncs refs.

- [ ] **Step 2: Rewrite the node listeners in the build effect**

Replace the whole `for (const ov of overlays) { … }` block inside `build()` with:

```ts
      for (const ov of overlays) {
        if (ov.payload.hidden === true) continue;
        const node = result.nodeById.get(ov.id);
        if (!node) continue;
        node.draggable(focusedRef.current && ov.payload.locked !== true);
        node.on("click tap", () => {
          // Selection is a focused-tile capability (spec §6): clicking an
          // overlay on an UNFOCUSED tile only focuses the tile itself, and
          // the container click below handles that.
          if (focusedRef.current) selectTrackRef.current(ov.id);
        });
        node.on("dragend", () => {
          if (!focusedRef.current) return;
          const x = node.x() / tile.width - ov.width / 2;
          const y = node.y() / tile.height - ov.height / 2;
          onOverlayTransformedRef.current(ov.id, { x, y }, "drag");
        });
        // The Transformer (mounted by the selection effect below) fires
        // these. `centeredScaling` + `keepRatio` keep the node's centre and
        // scaleX === scaleY, so the commit is just the two scalars — x/y are
        // untouched by a scale or rotate, exactly like an Inspector edit.
        let startPose = { rotation: 0, scale: 1 };
        node.on("transformstart", () => {
          startPose = { rotation: node.rotation(), scale: node.scaleX() };
        });
        node.on("transformend", () => {
          if (!focusedRef.current) return;
          const rotation = node.rotation();
          const scale = node.scaleX();
          const input: OverlayTransformInput =
            rotation !== startPose.rotation && scale === startPose.scale
              ? "rotate"
              : "scale";
          onOverlayTransformedRef.current(ov.id, { scale, rotation }, input);
        });
      }
```

- [ ] **Step 3: Replace the selection-outline effect and `syncSelectionOutline` with the Transformer**

Delete the `// ── Selection outline ──` effect and the `syncSelectionOutline` function. In their place:

```ts
  // ── Selection: one Transformer on the selected overlay ──
  // Rail, timeline and canvas click all funnel to `selectedOverlayId`, so the
  // handles follow all three. Poster tiles get nothing: the handles mark the
  // surface being edited, and only the focused tile is. The Transformer
  // tracks the node's own attr changes, so playback/scrub (`applyTimeline`)
  // and a drag keep the border glued to the node with no extra wiring.
  useEffect(() => {
    const handle = builtRef.current;
    if (!handle) return;
    void syncTransformer(handle.stage, handle.nodeById);
  }, [readyTick, selectedOverlayId, focused, overlays]);

  // Camera zoom changes only restyle the handles — never re-attach.
  useEffect(() => {
    const tr = transformerRef.current;
    if (!tr) return;
    tr.setAttrs(transformerStyleForScale(cameraScale));
    tr.forceUpdate();
    tr.getLayer()?.batchDraw();
  }, [cameraScale]);

  /** Attach / detach the Transformer for the current selection. Split out
   *  because it needs the runtime Konva, which this module loads lazily to
   *  stay importable in jsdom tests. */
  async function syncTransformer(
    stage: Konva.Stage,
    nodeById: Map<string, Konva.Node>
  ) {
    const KonvaRuntime = (await import("konva")).default;
    const layer = stage.getLayers()[0];
    const selected = focusedRef.current ? selectedOverlayIdRef.current : null;
    const ov = selected ? overlays.find((o) => o.id === selected) : undefined;
    const node = selected ? nodeById.get(selected) : undefined;

    if (!node || !ov || ov.payload.hidden === true) {
      if (transformerRef.current) {
        transformerRef.current.destroy();
        transformerRef.current = null;
        layer.batchDraw();
      }
      return;
    }

    let tr = transformerRef.current;
    if (!tr) {
      tr = new KonvaRuntime.Transformer({
        name: "motion-transformer",
        // Corners only: `MotionProps.scale` is ONE uniform number, and a side
        // anchor would write scaleX ≠ scaleY that the document cannot hold.
        enabledAnchors: [
          "top-left",
          "top-right",
          "bottom-left",
          "bottom-right",
        ],
        keepRatio: true,
        // Scale about the node's (offset) centre so x/y never move during a
        // scale — the pose model is "centre + uniform scale", the same thing
        // an Inspector edit produces.
        centeredScaling: true,
        rotateEnabled: true,
        rotationSnaps: [0, 90, 180, 270],
        rotationSnapTolerance: 5,
        borderStroke: "rgba(255,255,255,0.95)",
        borderDash: [6, 4],
        anchorStroke: "rgba(0,0,0,0.55)",
        anchorFill: "#ffffff",
        anchorCornerRadius: 2,
        ignoreStroke: true,
        ...transformerStyleForScale(cameraScaleRef.current),
      });
      // On the LAYER, not the clipped overlay group, so handles that hang
      // past the frame edge still draw.
      layer.add(tr);
      transformerRef.current = tr;
    }
    // A locked layer keeps the selection border but loses every handle —
    // the same "visible but inert" rule `draggable(false)` applies.
    const locked = ov.payload.locked === true;
    tr.resizeEnabled(!locked);
    tr.rotateEnabled(!locked);
    tr.nodes([node]);
    tr.moveToTop();
    layer.batchDraw();
  }
```

Also delete the now-unused `outlineRef` and the `dragmove` outline-glue listener (removed in Step 2). Remove the `Konva.Group`/`Rect` references that only served the outline.

- [ ] **Step 4: Type-check the file**

Run: `bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -E 'KvMotionTileStage|KvMotionEditor' || echo "clean"`
Expected: `clean` — the editor still compiles because `cameraScale` is optional and `handleOverlayTransformed`'s two-arg callback is assignable to the three-arg prop type.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/motion/KvMotionTileStage.tsx
git commit -m "feat(web): mount a scale/rotate Transformer on the focused KV Motion tile

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: `KvMotionTileStage` — onion-skin ghosts + motion path

**Files:**
- Modify: `src/components/studio/kv-generator/motion/KvMotionTileStage.tsx`

**Interfaces:**
- Consumes: `OnionSkin`, `onionNeighbors` (Task 1); `poseToNode`, `poseCenter` (Task 2); `inverseCameraScale` (Task 3).
- Produces (props, optional):
  ```ts
  onion?: OnionSkin | null;   // default null — the focused tile's selected track, remapped to this tile
  playing?: boolean;          // default false — ghosts/path hidden during playback
  playheadMs?: number;        // default 0 — picks prev/next and the filled path dot
  ```

- [ ] **Step 1: Props, imports, ref**

Imports:
```ts
import { poseCenter, poseToNode } from "./applyTimeline";
import { onionNeighbors, type OnionSkin } from "./onionSkin";
import { inverseCameraScale, transformerStyleForScale } from "./transformerStyle";
```
Props (after `cameraScale`):
```ts
  /** Onion-skin data for the selected track on THIS tile (already remapped
   *  to its aspect), or null. Only the focused tile ever receives one. */
  onion?: OnionSkin | null;
  /** Ghosts and the path are hidden while playing — the moving picture must
   *  look exactly like the export. */
  playing?: boolean;
  /** Which two keyframes to ghost (nearest before / after) and which path
   *  dot is "current". */
  playheadMs?: number;
```
Defaults in the signature: `onion = null, playing = false, playheadMs = 0,`.

Refs, next to `transformerRef`:
```ts
  /** Every Konva node the onion-skin effect added (ghost clones, path line,
   *  dots) — destroyed wholesale before each repaint. */
  const onionNodesRef = useRef<Konva.Node[]>([]);
  /** Repaint key of the last onion-skin paint; scrubbing between the same
   *  two keyframes must not re-clone the node every frame. */
  const onionKeyRef = useRef<string | null>(null);
```

- [ ] **Step 2: The paint effect** — add after the camera-restyle effect from Task 6:

```ts
  // ── Onion-skin ghosts + motion path ──
  // Paint-only nodes (listening:false) above the artwork: a translucent clone
  // of the selected overlay at its previous and next keyframe pose, and a
  // dashed polyline through every position keyframe. Cleared on any tile
  // that is unfocused, playing, or has nothing selected.
  useEffect(() => {
    const handle = builtRef.current;
    if (!handle) return;
    const layer = handle.stage.getLayers()[0];
    const clear = () => {
      if (onionNodesRef.current.length === 0) return;
      for (const n of onionNodesRef.current) n.destroy();
      onionNodesRef.current = [];
      onionKeyRef.current = null;
      layer.batchDraw();
    };
    const ov = selectedOverlayId
      ? overlays.find((o) => o.id === selectedOverlayId)
      : undefined;
    const node = selectedOverlayId
      ? handle.nodeById.get(selectedOverlayId)
      : undefined;
    if (!focused || playing || !onion || !ov || !node) {
      clear();
      return;
    }
    const { prev, next } = onionNeighbors(onion, playheadMs);
    const onKeyframe = onion.path.some((k) => k.tMs === playheadMs);
    const key = [
      ov.id,
      prev?.tMs ?? "-",
      next?.tMs ?? "-",
      onKeyframe ? playheadMs : "-",
      cameraScale,
    ].join("|");
    if (key === onionKeyRef.current) return;
    clear();
    onionKeyRef.current = key;
    void paintOnion(layer, node, ov, onion, prev, next);
  }, [
    readyTick,
    focused,
    playing,
    onion,
    playheadMs,
    selectedOverlayId,
    overlays,
    cameraScale,
    tile.width,
    tile.height,
  ]);

  async function paintOnion(
    layer: Konva.Layer,
    node: Konva.Node,
    ov: StudioOverlay,
    skin: OnionSkin,
    prev: { tMs: number; props: MotionProps } | null,
    next: { tMs: number; props: MotionProps } | null
  ) {
    const KonvaRuntime = (await import("konva")).default;
    const k = inverseCameraScale(cameraScaleRef.current);
    const added: Konva.Node[] = [];

    // Ghosts. The destination (next) reads a touch stronger than where the
    // layer came from (prev). Cloned from the live node so text runs, fonts
    // and images match exactly; positioned through the SAME math playback
    // uses, so a ghost is precisely where the layer will be.
    for (const [pose, opacity] of [
      [prev, 0.3],
      [next, 0.45],
    ] as const) {
      if (!pose) continue;
      const ghost = node.clone({ listening: false, name: "motion-onion" });
      poseToNode(ghost, ov, pose.props, tile.width, tile.height);
      ghost.opacity(opacity * ghost.opacity());
      layer.add(ghost);
      added.push(ghost);
    }

    // Motion path through every position keyframe.
    if (skin.path.length >= 2) {
      const pts = skin.path.flatMap((p) => {
        const c = poseCenter(ov, p.props, tile.width, tile.height);
        return [c.x, c.y];
      });
      const line = new KonvaRuntime.Line({
        name: "motion-onion",
        points: pts,
        stroke: "rgba(255,255,255,0.85)",
        strokeWidth: 1.5 * k,
        dash: [6 * k, 4 * k],
        shadowColor: "rgba(0,0,0,0.6)",
        shadowBlur: 2 * k,
        listening: false,
      });
      layer.add(line);
      added.push(line);
      for (const p of skin.path) {
        const c = poseCenter(ov, p.props, tile.width, tile.height);
        const dot = new KonvaRuntime.Circle({
          name: "motion-onion",
          x: c.x,
          y: c.y,
          radius: 4 * k,
          fill: p.tMs === playheadMs ? "#ffffff" : "rgba(0,0,0,0.55)",
          stroke: "rgba(255,255,255,0.95)",
          strokeWidth: 1.5 * k,
          listening: false,
        });
        layer.add(dot);
        added.push(dot);
      }
    }

    onionNodesRef.current = added;
    // Handles stay above ghosts and path.
    transformerRef.current?.moveToTop();
    layer.batchDraw();
  }
```
Add `import type { MotionProps } from "@/lib/video-editor/timeline";` if not already imported (it is — keep the existing one).

- [ ] **Step 3: Type-check**

Run: `bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -E 'KvMotionTileStage' || echo "clean"`
Expected: `clean`. If `node.clone` is typed as returning `Node` and `poseToNode` wants `PoseNodeLike`, it is structurally satisfied (Konva setters accept a number and return `this`).

- [ ] **Step 4: Commit**

```bash
git add src/components/studio/kv-generator/motion/KvMotionTileStage.tsx
git commit -m "feat(web): onion-skin ghosts and motion path on the focused KV Motion tile

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: `KvMotionTileStage` — badge + live HUD

**Files:**
- Modify: `src/components/studio/kv-generator/motion/KvMotionTileStage.tsx`

**Interfaces:**
- Consumes: `BadgeKind` (Task 1).
- Produces (prop, optional): `badge?: { text: string; kind: BadgeKind } | null` (default null).

- [ ] **Step 1: Prop + ref**

Import `type BadgeKind` from `./onionSkin` (extend the existing import). Props:
```ts
  /** The keyframe badge for the focused tile — what the next transform will
   *  write ("Base pose" / "⏺ Keyframe 2.4s" / "Keyframe @ 2.4s"). null hides
   *  it. Only the focused tile receives one. */
  badge?: { text: string; kind: BadgeKind } | null;
```
Default `badge = null`. Ref next to the others:
```ts
  /** The live-value span inside the badge. Written imperatively during a
   *  drag/transform (no React state per pointer move) and hidden again on
   *  commit; React owns the sibling state-text span and never touches this
   *  one, so the two can't fight. */
  const hudRef = useRef<HTMLSpanElement>(null);
```

- [ ] **Step 2: Live HUD listeners in the build effect** — inside the `for (const ov of overlays)` loop from Task 6, after `node.draggable(...)`, add:

```ts
        const hud = (text: string | null) => {
          const el = hudRef.current;
          if (!el) return;
          el.hidden = text === null;
          el.textContent = text ?? "";
        };
        let dragStart = { x: 0, y: 0 };
        node.on("dragstart", () => {
          dragStart = { x: node.x(), y: node.y() };
        });
        node.on("dragmove", () => {
          if (!focusedRef.current) return;
          const dx = Math.round(node.x() - dragStart.x);
          const dy = Math.round(node.y() - dragStart.y);
          const sign = (n: number) => (n >= 0 ? `+${n}` : `${n}`);
          hud(`x ${sign(dx)} · y ${sign(dy)}`);
        });
        node.on("transform", () => {
          if (!focusedRef.current) return;
          const rotating =
            transformerRef.current?.getActiveAnchor() === "rotater";
          hud(
            rotating
              ? `${Math.round(node.rotation())}°`
              : `${node.scaleX().toFixed(2)}×`
          );
        });
        node.on("dragend transformend", () => hud(null));
```
(Keep the existing `dragend` / `transformend` commit listeners from Task 6 — Konva runs every handler registered for an event.)

- [ ] **Step 3: Render the badge** — inside the outer wrapper `<div data-tile-key=…>`, after the stage container `<div ref={containerRef} …/>`, add:

```tsx
      {focused && badge && !playing && (
        <div
          data-motion-badge={badge.kind}
          className={cn(
            "pointer-events-none absolute flex items-center gap-1.5 rounded-full px-2 py-0.5 font-geist text-textXs",
            badge.kind === "between"
              ? "bg-black/55 text-white/70"
              : "bg-black/75 text-white"
          )}
          style={{
            top: 8 * inverseCameraScale(cameraScale),
            left: 8 * inverseCameraScale(cameraScale),
            transform: `scale(${inverseCameraScale(cameraScale)})`,
            transformOrigin: "top left",
            whiteSpace: "nowrap",
          }}
        >
          <span>{badge.text}</span>
          <span ref={hudRef} hidden className="tabular-nums text-emerald-300" />
        </div>
      )}
```
Add `import { cn } from "@/lib/utils";` (check the path other motion files use for `cn` — `KvMotionEditor.tsx` imports it; copy that import line).

- [ ] **Step 4: Type-check**

Run: `bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -E 'KvMotionTileStage' || echo "clean"`
Expected: `clean`.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/motion/KvMotionTileStage.tsx
git commit -m "feat(web): keyframe badge and live transform HUD on the focused KV Motion tile

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 9: `KvMotionEditor` — wire everything

**Files:**
- Modify: `src/components/studio/kv-generator/motion/KvMotionEditor.tsx` — `handleSeek` (~723), `handleOverlayTransformed` (~1001), `shouldStartPan` (~1033), playback loop (~1150–1210), tile mount (~1643)

**Interfaces:**
- Consumes: `isPanBlockingHit` (Task 3); `onionSkinFor`, `badgeLabel` (Task 1); `trackKvMotionOverlayTransformed` (Task 5); `state.previewOnce / clearPreviewOnce / seekByUser` (Task 4); stage props `cameraScale / onion / playing / playheadMs / badge` and `OverlayTransformInput` (Tasks 6–8).

- [ ] **Step 1: Imports**

```ts
import { isPanBlockingHit } from "./panHitTest";
import { badgeLabel, onionSkinFor } from "./onionSkin";
import type { OverlayTransformInput } from "./KvMotionTileStage";
```
and add `trackKvMotionOverlayTransformed` to the existing `@/lib/analytics/kv-generator-events` import.

- [ ] **Step 2: User seek clears the auto-preview** — in `handleSeek`, replace `state.seek(tMs);` with `state.seekByUser(tMs);`. Grep for any other user-driven `state.seek(` outside the playback loop effect (keyboard handlers, transport) and switch those to `state.seekByUser` too; the three calls INSIDE the playback `useEffect` stay `state.seek`.

- [ ] **Step 3: Commit handler with analytics** — replace `handleOverlayTransformed`:

```ts
  // Drag/transform commits. Reads `stateRef.current` so a drag that ends
  // after the playhead moved still writes its keyframe at the RIGHT playhead
  // — same escape hatch as the old inline handlers. `at_t0` is read BEFORE
  // the write: `playOnce` seeks the playhead as part of arming the preview.
  const handleOverlayTransformed = useCallback(
    (
      overlayId: string,
      changed: { x?: number; y?: number; scale?: number; rotation?: number },
      input: OverlayTransformInput
    ) => {
      const atT0 = stateRef.current.playheadMs === 0;
      const previewed = stateRef.current.onOverlayTransformed(
        overlayId,
        changed
      );
      trackKvMotionOverlayTransformed({
        project_id: project.id,
        input,
        at_t0: atT0,
        auto_preview: previewed,
      });
    },
    [project.id]
  );
```

- [ ] **Step 4: Pan guard** — in `shouldStartPan`, replace from `const hit = h.stage.getIntersection(pos);` to the `return true;` that closes the ancestor walk with:

```ts
        const hit = h.stage.getIntersection(pos);
        const overlayNodes = new Set<Konva.Node>(h.nodeById.values());
        // Transformer anchors and draggable overlays own the press; the base
        // image, a locked overlay, or empty canvas hand it to the camera.
        return !isPanBlockingHit(hit, overlayNodes);
```

- [ ] **Step 5: Playback loop honours `previewOnce`** — in the playback `useEffect`, replace the bounds block:

```ts
    const durationMs = state.timeline.duration_ms;
    const once = state.previewOnce;
    const range = state.previewRange;
    // A once-through auto-preview outranks the user's preview range and
    // never wraps — it is one look at one segment, then stop.
    const loop = state.loop && !once;
    const boundStart = once ? once.fromMs : range ? range.startMs : 0;
    const boundEnd = once ? once.toMs : range ? range.endMs : durationMs;
```
and in the `else` branch of the end-of-range check (the one that calls `state.setPlaying(false)`), add `if (once) state.clearPreviewOnce();` before `return;`. Add `state.previewOnce` to the effect's dependency array (the array under the `eslint-disable` comment).

- [ ] **Step 6: Derive onion + badge for the focused tile** — after `sampledByKey`:

```ts
  // Onion-skin + badge inputs for the FOCUSED tile only. `onionSkinFor` is
  // keyed on (that tile's remapped timeline, selected track) — playhead is
  // deliberately not an input, the stage picks prev/next itself — so a
  // scrub never re-samples every keyframe.
  const selectedTrackId = state.selectedKeyframe?.trackId ?? null;
  const focusedTileTimeline = useMemo(
    () => tileTimelines.find((d) => d.tile.key === focusedTileKey) ?? null,
    [tileTimelines, focusedTileKey]
  );
  const onion = useMemo(
    () =>
      focusedTileTimeline && selectedTrackId
        ? onionSkinFor(
            focusedTileTimeline.timeline,
            focusedTileTimeline.base,
            selectedTrackId
          )
        : null,
    [focusedTileTimeline, selectedTrackId]
  );
  const badge = useMemo(() => {
    if (!selectedTrackId) return null;
    const track =
      state.timeline.tracks.find(
        (t) => t.kind === "overlay" && t.overlay_id === selectedTrackId
      ) ?? null;
    return badgeLabel(state.playheadMs, track);
  }, [selectedTrackId, state.timeline, state.playheadMs]);
```
`focusedTileKey` is declared below `sampledByKey` today — move this block to just after the `focusedTileKey` `useState`/`useEffect` pair so it is in scope.

- [ ] **Step 7: Pass the props at the tile mount**

```tsx
            <KvMotionTileStage
              key={d.tile.key}
              tile={d.tile}
              placement={placementByKey.get(d.tile.key)!}
              focused={d.tile.key === focusedTileKey}
              onFocus={() => setFocusedTileKey(d.tile.key)}
              overlays={d.overlays}
              sampled={sampledByKey.get(d.tile.key)!}
              throttled={state.playing && d.tile.key !== focusedTileKey}
              budget={posterBudget}
              onOverlayTransformed={handleOverlayTransformed}
              selectTrack={state.selectTrack}
              selectedOverlayId={state.selectedKeyframe?.trackId ?? null}
              cameraScale={camera.camera.scale}
              onion={d.tile.key === focusedTileKey ? onion : null}
              badge={d.tile.key === focusedTileKey ? badge : null}
              playing={state.playing}
              playheadMs={state.playheadMs}
              onReady={(handle) => registerTileStage(d.tile.key, handle)}
              onBuildError={handleTileBuildError}
            />
```

- [ ] **Step 8: Type-check + run the editor-adjacent suites**

Run: `bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -E 'motion/' || echo "clean"`
Expected: `clean`.

Run: `bun test src/components/studio/kv-generator/motion/useCanvasCamera.test.tsx src/components/studio/kv-generator/motion/KvMotionCanvasZoomPill.test.tsx src/components/studio/kv-generator/motion/motionTileDerived.test.ts`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add src/components/studio/kv-generator/motion/KvMotionEditor.tsx
git commit -m "feat(web): wire canvas transform handles, onion-skin, auto-preview and analytics into KV Motion

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 10: Manual verification in the browser + wrap-up

**Files:**
- Modify: `docs/superpowers/specs/2026-09-14-kv-motion-canvas-transform-design.md` (workspace repo — status line only)

Prerequisites: services up (`./run-all.sh --status` from the workspace root; web on :3000 from the worktree needs its own `bun dev` — stop the develop one first or the port collides). Open a KV file → Motion → a project with ≥ 1 text and ≥ 1 image overlay.

- [ ] **Step 1: Handles + keyframes**
  1. Select a layer, seek to 2.0s, drag a corner outward → layer grows about its centre; timeline shows scale keyframes at 0 and 2.0s; badge reads `⏺ Keyframe 2.0s`; one ⌘Z removes both.
  2. Rotate handle → rotation lane keyframes; near 90° it snaps.
  3. At t=0 drag a corner → single keyframe at 0, badge `Base pose`, nothing plays.
  4. Locked layer → dashed border, no anchors. Hidden layer → nothing.

- [ ] **Step 2: Auto-preview**
  1. After the corner drag at 2.0s the segment 0→2.0s plays once and stops at 2.0s. With loop ON it still stops.
  2. Press space mid-preview → transport takes over normally (loop toggle respected again).
  3. Scrub the ruler mid-preview → preview cancels.

- [ ] **Step 3: Onion-skin**
  1. With ≥ 2 keyframes, at 1.0s: a faint ghost at the previous pose, a stronger one at the next, a dashed path with dots. Scrub between the two → no flicker (DevTools: no new `motion-onion` nodes per frame — `stage.find('.motion-onion').length` stable).
  2. Press play → ghosts/path vanish; pause → back.
  3. Click another tile → ghosts/handles move to it; the previous tile is clean.

- [ ] **Step 4: Camera + pan**
  1. Fit-to-view (small tiles) → anchors still ~10 px on screen; zoom in → not oversized.
  2. Press on an anchor → never pans. Press on the base image → pans. Press on a locked layer → pans.

- [ ] **Step 5: HUD** — dragging shows `x +24 · y −8`; corner shows `1.25×`; rotate shows `37°`; all disappear on release.

- [ ] **Step 6: Export** — export an MP4 after a scale/rotate keyframe; the clip matches the preview, no ghosts/handles/badge in the frame.

- [ ] **Step 7: PostHog** — Live Events (project FRnD_OS / 389744) show `kv_generator.motion_overlay_transformed` once per gesture with `input`, `at_t0`, `auto_preview`, plus base context. Add the taxonomy row to https://fcn.sg.larksuite.com/wiki/DMbKwqbzQiWrXSkha5zl1wFvgod (Daffa).

- [ ] **Step 8: Wrap up** — in the workspace repo set the spec's `**Status:**` to `implemented 2026-09-14 (manual e2e passed)` (or record what failed); commit `docs(spec): record KV Motion canvas transform outcome`. Then `superpowers:finishing-a-development-branch` for the `web/` branch.

---

## Self-review

**Spec coverage:** §1 Transformer → Tasks 3, 6, 9 (pan guard, camera scale, centeredScaling, locked/hidden). §2 onion-skin → Tasks 1, 2, 7, 9 (remapped per-tile timeline, rebuild key, hidden while playing). §3 auto-preview → Tasks 1, 4, 9; badge/HUD → Tasks 1, 8, 9. §4 analytics → Tasks 5, 9. Undo unchanged (Task 4 pushes exactly once). Testing list → Tasks 1–5 unit, Task 10 manual.

**Deviation from spec, deliberate:** the spec sketched `onionSkinFor(…, playheadMs)` returning `prev/next/path`; the plan splits it into a playhead-independent `onionSkinFor` + `onionNeighbors` so the editor's memo doesn't re-sample on every scrub — the spec's own "rebuild key" requirement, moved to where it is enforceable.

**Type consistency:** `OverlayTransformInput` (Task 6) = `KvMotionOverlayTransformInput` (Task 5) = `"drag" | "scale" | "rotate"`. `onOverlayTransformed` returns `boolean` (Task 4) and is read as `previewed` (Task 9). `PoseNodeLike` (Task 2) is satisfied by `Konva.Node` and the cloned ghost (Task 7). `HitNodeLike` (Task 3) is satisfied by `Konva.Node` (`getParent/getClassName/draggable` all exist).
