# KV Motion Build Sub-Segments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A block's Build tab can add a channel the block already animates ("Add another Rotate"), producing a new bar in that lane — at the playhead when it is inside the block and free, otherwise right after the channel's last run — with cumulative values.

**Architecture:** Two optional markers on `MotionKeyframe` — `seg` (lane split marker) and `block` (block bridge marker) — consulted by the one clustering implementation in `blocks.ts`. `addSegmentBuild` grows an "Nth run" branch driven by a pure `planSegmentBuild` (window + placement + nth) that the editor also reads for analytics. Every path that copies keyframes re-mints ids through one helper.

**Tech Stack:** TypeScript, React 19, bun test (`bun test <file>` from `web/`; see memory: `screen` is broken — use `within(document.body)`).

**Spec:** `docs/superpowers/specs/2026-09-22-kv-motion-build-sub-segments-design.md`

## Global Constraints

- web only; `MotionTimeline.version` stays `1` — both new fields optional.
- Never merge two keyframes at one `t_ms` for different runs — 1ms clearance (`last.endMs + 1`, `nextStart − 1`).
- Nth-run refusal threshold: `EMPHASIS_MIN_WINDOW_MS` (200) — existing constant in `presets.ts`.
- Constants reused verbatim: `SLIDE_OFFSET` (0.15), `BUILD_ROTATE_DEG` (15), `BUILD_BLINK_OPACITY` (0.4), `PATH_ARC_DY` (−0.06), `MIN_BLOCK_SPAN_MS` (100). New: `BUILD_SCALE_STEP = 1.08` (the pulse multiplier, now named).
- All commands run from `web/`. Run only the named test files — `bun test` on a directory can eat memory (memory note).
- Commit on `develop` as we go (feedback memory: Daffa pushes manually).

---

### Task 1: `seg` / `block` fields + id minting — `timeline.ts`

**Files:**
- Modify: `web/src/lib/video-editor/timeline.ts` (after `path?: MotionPath;` in `MotionKeyframe`, and new exports at the bottom)
- Test: `web/src/lib/video-editor/timeline.remint.test.ts` (new)

**Interfaces:**
- Produces: `MotionKeyframe.seg?: string`, `MotionKeyframe.block?: string`, `mintMotionId(): string`, `remintMotionIds(keyframes: MotionKeyframe[], mint?: () => string): MotionKeyframe[]`.

- [ ] **Step 1: Write the failing test**

```ts
// web/src/lib/video-editor/timeline.remint.test.ts
import { describe, expect, it } from "bun:test";
import type { MotionKeyframe } from "./timeline";
import { mintMotionId, remintMotionIds } from "./timeline";

const kf = (t_ms: number, extra: Partial<MotionKeyframe> = {}): MotionKeyframe => ({
  t_ms,
  props: { rotation: t_ms },
  easing: "linear",
  ...extra,
});

describe("remintMotionIds", () => {
  it("maps every distinct seg/block to a fresh id, consistently", () => {
    let n = 0;
    const mint = () => `m${++n}`;
    const out = remintMotionIds(
      [
        kf(0, { seg: "a", block: "B" }),
        kf(100, { seg: "a", block: "B" }),
        kf(200, { seg: "b", block: "B" }),
        kf(300),
      ],
      mint
    );
    expect(out[0]!.seg).toBe(out[1]!.seg);
    expect(out[0]!.seg).not.toBe("a");
    expect(out[2]!.seg).not.toBe(out[0]!.seg);
    expect(out[0]!.block).toBe(out[2]!.block);
    expect(out[0]!.block).not.toBe("B");
    expect(out[3]!.seg).toBeUndefined();
    expect(out[3]!.block).toBeUndefined();
    // seg and block namespaces never share a minted value
    expect(out[0]!.seg).not.toBe(out[0]!.block);
  });

  it("returns the same array reference when nothing carries an id", () => {
    const input = [kf(0), kf(100)];
    expect(remintMotionIds(input)).toBe(input);
  });

  it("mintMotionId yields short distinct strings", () => {
    const a = mintMotionId();
    const b = mintMotionId();
    expect(a).not.toBe(b);
    expect(a.length).toBeGreaterThanOrEqual(6);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/lib/video-editor/timeline.remint.test.ts`
Expected: FAIL — `remintMotionIds` is not exported.

- [ ] **Step 3: Implement**

In `MotionKeyframe`, after the `path?: MotionPath;` member:

```ts
  /** Sub-motion identity: every keyframe ONE Build click writes shares it.
   *  Read only by lane clustering (`propGroupSegments` in blocks.ts): two
   *  consecutive keyframes of a lane carrying DIFFERENT `seg` values always
   *  split into two bars, even when the property moves continuously across
   *  them — "Rotate ×7 in a row" stays seven bars. One side undefined (a
   *  hand-authored diamond) → the continuity rule decides. A split marker,
   *  not a global id: it only has to differ from its neighbours', which is
   *  why every path that COPIES keyframes re-mints (`remintMotionIds`).
   *  Additive: documents written before this field read exactly as before. */
  seg?: string;
  /** Block identity: consecutive keyframes carrying the SAME `block` never
   *  split into two blocks, even when every property is still across the
   *  gap — a run appended after a block's end (2026-09-22) stays in that
   *  block. Read only by block clustering (`trackSegments`). A bridge
   *  marker, not a global id (see `seg`). Additive. */
  block?: string;
```

At the bottom of the file:

```ts
/** A short opaque id for `MotionKeyframe.seg` / `block`. Only has to differ
 *  from its neighbours' — see the field docs. Writers take a `mint`
 *  parameter defaulting to this so tests can pass a counter. */
export function mintMotionId(): string {
  return crypto.randomUUID().replace(/-/g, "").slice(0, 10);
}

/** Give every distinct `seg` and `block` value a fresh id, consistently
 *  (same old value → same new value), leaving keyframes without ids alone.
 *  The ONE thing every path that copies keyframes onto a track calls —
 *  paste, template bake — so a copy landing next to its source cannot
 *  bridge into it. Returns the same array reference when nothing carries
 *  an id. Pure. */
export function remintMotionIds(
  keyframes: MotionKeyframe[],
  mint: () => string = mintMotionId
): MotionKeyframe[] {
  if (!keyframes.some((k) => k.seg !== undefined || k.block !== undefined)) {
    return keyframes;
  }
  const segs = new Map<string, string>();
  const blocks = new Map<string, string>();
  const fresh = (map: Map<string, string>, old: string) => {
    let v = map.get(old);
    if (v === undefined) {
      v = mint();
      map.set(old, v);
    }
    return v;
  };
  return keyframes.map((k) => ({
    ...k,
    ...(k.seg !== undefined ? { seg: fresh(segs, k.seg) } : {}),
    ...(k.block !== undefined ? { block: fresh(blocks, k.block) } : {}),
  }));
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test src/lib/video-editor/timeline.remint.test.ts`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add src/lib/video-editor/timeline.ts src/lib/video-editor/timeline.remint.test.ts
git commit -m "feat(web): MotionKeyframe seg/block markers + remintMotionIds"
```

---

### Task 2: Clustering honours the markers — `blocks.ts`

**Files:**
- Modify: `web/src/lib/video-editor/blocks.ts:130-195` (`trackSegments`), `:985-1000` (`propGroupSegments`)
- Test: `web/src/lib/video-editor/blocks.markers.test.ts` (new)

**Interfaces:**
- Produces: `trackSegments(track, opts?: { splitBetween?: (a: MotionKeyframe[], b: MotionKeyframe[]) => boolean | undefined })` — `true` forces a boundary, `false` forbids one, `undefined` defers to the continuity rule. Default (block level) = `block` bridge. `propGroupSegments` = `seg` split, then continuity (no block bridging in lanes).

- [ ] **Step 1: Write the failing test**

```ts
// web/src/lib/video-editor/blocks.markers.test.ts
import { describe, expect, it } from "bun:test";
import type { MotionKeyframe, MotionTrack } from "./timeline";
import { propGroupSegments, trackSegments } from "./blocks";

const kf = (
  t_ms: number,
  props: MotionKeyframe["props"],
  extra: Partial<MotionKeyframe> = {}
): MotionKeyframe => ({ t_ms, props, easing: "linear", ...extra });
const track = (keyframes: MotionKeyframe[]): MotionTrack => ({
  kind: "overlay",
  overlay_id: "ov1",
  keyframes,
});

describe("block markers", () => {
  it("a shared `block` bridges a still gap the continuity rule would split", () => {
    // Rotate 0→15 over [0,500], then a 1ms still seam, then 15→30 over [501,1001].
    const t = track([
      kf(0, { rotation: 0 }, { block: "B" }),
      kf(500, { rotation: 15 }, { block: "B" }),
      kf(501, { rotation: 15 }, { block: "B" }),
      kf(1001, { rotation: 30 }, { block: "B" }),
    ]);
    expect(trackSegments(t)).toEqual([{ startMs: 0, endMs: 1001 }]);
  });

  it("different `block` values (or one missing) fall back to continuity", () => {
    const split = track([
      kf(0, { rotation: 0 }, { block: "B" }),
      kf(500, { rotation: 15 }, { block: "B" }),
      kf(501, { rotation: 15 }, { block: "C" }),
      kf(1001, { rotation: 30 }, { block: "C" }),
    ]);
    expect(trackSegments(split)).toEqual([
      { startMs: 0, endMs: 500 },
      { startMs: 501, endMs: 1001 },
    ]);
    const hand = track([
      kf(0, { rotation: 0 }, { block: "B" }),
      kf(500, { rotation: 15 }, { block: "B" }),
      kf(501, { rotation: 15 }),
      kf(1001, { rotation: 30 }, { block: "B" }),
    ]);
    expect(trackSegments(hand)).toEqual([
      { startMs: 0, endMs: 500 },
      { startMs: 501, endMs: 1001 },
    ]);
  });

  it("block level ignores `seg`: a continuous run with two segs is one block", () => {
    const t = track([
      kf(0, { rotation: 0 }, { seg: "a" }),
      kf(500, { rotation: 15 }, { seg: "a" }),
      kf(501, { rotation: 15 }, { seg: "b" }),
      kf(1001, { rotation: 30 }, { seg: "b" }),
    ]);
    // 500→501 is still for rotation → continuity splits; seg is not a bridge.
    expect(trackSegments(t)).toEqual([
      { startMs: 0, endMs: 500 },
      { startMs: 501, endMs: 1001 },
    ]);
  });
});

describe("seg markers in lanes", () => {
  it("different `seg` values split a lane run the continuity rule would keep", () => {
    // Rotation moves across every gap — one bar by continuity, two by seg.
    const t = track([
      kf(0, { rotation: 0 }, { seg: "a" }),
      kf(500, { rotation: 15 }, { seg: "a" }),
      kf(501, { rotation: 16 }, { seg: "b" }),
      kf(1001, { rotation: 30 }, { seg: "b" }),
    ]);
    expect(propGroupSegments(t, "rotation")).toEqual([
      { startMs: 0, endMs: 500 },
      { startMs: 501, endMs: 1001 },
    ]);
  });

  it("one side without `seg` defers to continuity", () => {
    const t = track([
      kf(0, { rotation: 0 }, { seg: "a" }),
      kf(500, { rotation: 15 }, { seg: "a" }),
      kf(700, { rotation: 20 }),
    ]);
    expect(propGroupSegments(t, "rotation")).toEqual([{ startMs: 0, endMs: 700 }]);
  });

  it("lanes do not bridge on `block`: a still seam still splits the lane", () => {
    const t = track([
      kf(0, { rotation: 0 }, { block: "B" }),
      kf(500, { rotation: 15 }, { block: "B" }),
      kf(501, { rotation: 15 }, { block: "B" }),
      kf(1001, { rotation: 30 }, { block: "B" }),
    ]);
    expect(propGroupSegments(t, "rotation")).toEqual([
      { startMs: 0, endMs: 500 },
      { startMs: 501, endMs: 1001 },
    ]);
  });

  it("a keyframe shared by two channels is judged per lane", () => {
    const t = track([
      kf(0, { rotation: 0, scale: 1 }, { seg: "a" }),
      kf(500, { rotation: 15, scale: 1.1 }, { seg: "a" }),
      kf(501, { rotation: 16 }, { seg: "b" }),
      kf(1001, { rotation: 30 }, { seg: "b" }),
    ]);
    expect(propGroupSegments(t, "rotation")).toHaveLength(2);
    expect(propGroupSegments(t, "scale")).toEqual([{ startMs: 0, endMs: 500 }]);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/lib/video-editor/blocks.markers.test.ts`
Expected: FAIL on the bridge and seg-split cases (continuity alone).

- [ ] **Step 3: Implement**

In `trackSegments`, change the signature and `isBoundary`:

```ts
/** How the marker rules plug into clustering — see `seg` / `block` on
 *  `MotionKeyframe`. `a` / `b` are the keyframes at the two consecutive
 *  times being judged (several when channels share a time). `true` forces
 *  a boundary, `false` forbids one, `undefined` defers to the continuity
 *  rule. The default is the block-level `block` bridge. */
export type SplitBetween = (
  a: MotionKeyframe[],
  b: MotionKeyframe[]
) => boolean | undefined;

/** Block level: a shared `block` never splits. */
const bridgeOnBlock: SplitBetween = (a, b) => {
  for (const ka of a) {
    if (ka.block === undefined) continue;
    if (b.some((kb) => kb.block === ka.block)) return false;
  }
  return undefined;
};

/** Lane level: differing `seg` (both defined) always splits. */
const splitOnSeg: SplitBetween = (a, b) => {
  for (const ka of a) {
    if (ka.seg === undefined) continue;
    for (const kb of b) {
      if (kb.seg !== undefined && kb.seg !== ka.seg) return true;
    }
  }
  return undefined;
};

export function trackSegments(
  track: MotionTrack,
  opts: { splitBetween?: SplitBetween } = {}
): TrackSegment[] {
  const splitBetween = opts.splitBetween ?? bridgeOnBlock;
  // ...existing body up to isBoundary...
  const byTime = new Map<number, MotionKeyframe[]>();
  for (const k of track.keyframes) {
    const list = byTime.get(k.t_ms);
    if (list) list.push(k);
    else byTime.set(k.t_ms, [k]);
  }

  function isBoundary(a: number, b: number): boolean {
    const verdict = splitBetween(byTime.get(a) ?? [], byTime.get(b) ?? []);
    if (verdict !== undefined) return verdict;
    if (movesAlongPath(a, b)) return false;
    // ...existing continuity loop unchanged...
  }
  // ...rest unchanged...
}
```

Update the `trackSegments` doc comment: add one paragraph — "Two markers short-circuit the rule (`splitBetween`): a shared `block` between consecutive keyframes is never a boundary (block level, the default); lanes pass `splitOnSeg` instead so differing `seg` values always are. Neither changes what is drawn between the diamonds — only where a bar ends."

In `propGroupSegments`, change the last line to:

```ts
  return trackSegments({ ...track, keyframes }, { splitBetween: splitOnSeg });
```

and extend its doc comment: "Lanes split on `seg` (a run per Build click) and do NOT bridge on `block` — a bar spanning a still seam would hide where one run ends and the next begins, which is the whole point of the markers."

- [ ] **Step 4: Run tests**

Run: `bun test src/lib/video-editor/blocks.markers.test.ts src/lib/video-editor/blocks.test.ts src/lib/video-editor/blocks.propGroups.test.ts src/lib/video-editor/blocks.slots.test.ts`
Expected: all PASS (the marker-free fixtures still cluster by continuity).

- [ ] **Step 5: Commit**

```bash
git add src/lib/video-editor/blocks.ts src/lib/video-editor/blocks.markers.test.ts
git commit -m "feat(web): block/lane clustering honours seg + block keyframe markers"
```

---

### Task 3: Lane ops carry the markers — `blocks.ts` `movePropGroup`

**Files:**
- Modify: `web/src/lib/video-editor/blocks.ts:1250-1275` (the `moving.push({...})` in `movePropGroup`)
- Test: append to `web/src/lib/video-editor/blocks.propGroupDrag.test.ts`

- [ ] **Step 1: Write the failing test** (append inside the file's top-level `describe`, or as a new `describe` at the bottom)

```ts
describe("lane drag carries seg/block", () => {
  it("the moving half keeps seg and block, drops label and role", () => {
    const tl: MotionTimeline = {
      version: 1,
      duration_ms: 5000,
      fps: 30,
      tracks: [
        {
          kind: "overlay",
          overlay_id: "ov1",
          keyframes: [
            { t_ms: 1000, props: { rotation: 0, scale: 1 }, easing: "linear", label: "Rotate", role: "in", seg: "s1", block: "b1" },
            { t_ms: 1500, props: { rotation: 15, scale: 1.1 }, easing: "out", label: "Rotate", seg: "s1", block: "b1" },
          ],
        },
      ],
    };
    const next = shiftPropGroupKeyframes(tl, "ov1", "rotation", 1000, 1500, 200);
    const rot = next.tracks[0]!.keyframes.filter((k) => k.props.rotation !== undefined);
    expect(rot.map((k) => k.t_ms)).toEqual([1200, 1700]);
    for (const k of rot) {
      expect(k.seg).toBe("s1");
      expect(k.block).toBe("b1");
      expect(k.label).toBeUndefined();
      expect(k.role).toBeUndefined();
    }
    // the left-behind scale half keeps its ids too (spread), minus label/role
    const scale = next.tracks[0]!.keyframes.filter((k) => k.props.scale !== undefined);
    expect(scale.every((k) => k.seg === "s1" && k.block === "b1")).toBe(true);
  });
});
```

(Import `shiftPropGroupKeyframes` and `MotionTimeline` if the file does not already.)

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/lib/video-editor/blocks.propGroupDrag.test.ts`
Expected: FAIL — moving half has `seg: undefined`.

- [ ] **Step 3: Implement** — in `movePropGroup`'s `moving.push({ ... })`, add after the `path` spread:

```ts
      // Identity travels with the run — a lane drag retimes a sub-motion, it
      // does not author a new one. (Label and role are what a drag revokes.)
      ...(kf.seg !== undefined ? { seg: kf.seg } : {}),
      ...(kf.block !== undefined ? { block: kf.block } : {}),
```

- [ ] **Step 4: Run tests**

Run: `bun test src/lib/video-editor/blocks.propGroupDrag.test.ts src/lib/video-editor/blocks.movePropGroupKeyframe.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lib/video-editor/blocks.ts src/lib/video-editor/blocks.propGroupDrag.test.ts
git commit -m "feat(web): lane drags carry seg/block markers"
```

---

### Task 4: Templates and clips carry + re-mint — `templates.ts`, `motionClip.ts`

**Files:**
- Modify: `web/src/lib/video-editor/templates.ts:33-48` (type), `:86-92` (normalize), `:221-230` (bake)
- Modify: `web/src/lib/video-editor/motionClip.ts:155-168` (`pasteMotionClip` raw branch)
- Test: append to `web/src/lib/video-editor/templates.test.ts` and `web/src/lib/video-editor/motionClip.test.ts`

- [ ] **Step 1: Write the failing tests**

templates.test.ts (new `describe` at the bottom; reuse the file's existing `REST`/base helpers if present, else define `const REST: MotionProps = { x: 0.4, y: 0.3, scale: 1, rotation: 0, opacity: 1 };`):

```ts
describe("seg/block through templates", () => {
  it("normalize carries the markers and bake re-mints them consistently", () => {
    const track: MotionTrack = {
      kind: "overlay",
      overlay_id: "ov1",
      keyframes: [
        { t_ms: 0, props: { rotation: 0 }, easing: "linear", seg: "s1", block: "b1" },
        { t_ms: 500, props: { rotation: 15 }, easing: "out", seg: "s1", block: "b1" },
        { t_ms: 501, props: { rotation: 15 }, easing: "linear", seg: "s2", block: "b1" },
        { t_ms: 1000, props: { rotation: 30 }, easing: "out", seg: "s2", block: "b1" },
      ],
    };
    const body = normalizeTrackToTemplate(track, REST, 5000);
    expect(body.keyframes.map((k) => k.seg)).toEqual(["s1", "s1", "s2", "s2"]);
    expect(body.keyframes.every((k) => k.block === "b1")).toBe(true);

    const baked = bakeTemplateToTrack(body, "ov2", REST, 5000)!;
    const segs = baked.keyframes.map((k) => k.seg!);
    expect(segs[0]).toBe(segs[1]);
    expect(segs[2]).toBe(segs[3]);
    expect(segs[0]).not.toBe(segs[2]);
    expect(segs[0]).not.toBe("s1");
    const blocks = new Set(baked.keyframes.map((k) => k.block));
    expect(blocks.size).toBe(1);
    expect(blocks.has("b1")).toBe(false);
  });

  it("bake drops non-string markers from a hand-edited body", () => {
    const body = normalizeTrackToTemplate(
      { kind: "overlay", overlay_id: "ov1", keyframes: [{ t_ms: 0, props: { rotation: 0 }, easing: "linear" }] },
      REST,
      5000
    );
    (body.keyframes[0] as { seg?: unknown }).seg = 42;
    const baked = bakeTemplateToTrack(body, "ov2", REST, 5000)!;
    expect(baked.keyframes[0]!.seg).toBeUndefined();
  });
});
```

motionClip.test.ts (new `describe` at the bottom; reuse its existing helpers for a clip — look for `captureMotionClip` usage in the file and mirror it):

```ts
describe("seg/block through clips", () => {
  it("pasteMotionClip (as-is) re-mints ids consistently", () => {
    const track: MotionTrack = {
      kind: "overlay",
      overlay_id: "ov1",
      keyframes: [
        { t_ms: 0, props: { rotation: 0 }, easing: "linear", seg: "s1", block: "b1" },
        { t_ms: 500, props: { rotation: 15 }, easing: "out", seg: "s1", block: "b1" },
      ],
    };
    const clip = captureMotionClip(track, REST, 5000);
    const pasted = pasteMotionClip(clip, "ov2", REST, 5000, "as-is")!;
    expect(pasted.keyframes[0]!.seg).toBe(pasted.keyframes[1]!.seg);
    expect(pasted.keyframes[0]!.seg).not.toBe("s1");
    expect(pasted.keyframes[0]!.block).not.toBe("b1");
    expect(pasted.keyframes[0]!.block).toBe(pasted.keyframes[1]!.block);
  });
});
```

(Check the exact `captureMotionClip` signature and `PasteMotionMode` values at the top of `motionClip.ts` and adjust the call — the "follow" mode goes through `bakeTemplateToTrack`, already covered by the template test.)

- [ ] **Step 2: Run to verify they fail**

Run: `bun test src/lib/video-editor/templates.test.ts src/lib/video-editor/motionClip.test.ts`
Expected: FAIL — markers dropped / not re-minted.

- [ ] **Step 3: Implement**

`templates.ts` — add to `MotionTemplateKeyframe` after `path?`:

```ts
  /** `MotionKeyframe.seg` / `block`, carried verbatim and RE-MINTED on bake
   *  (`remintMotionIds`) so a template applied twice on one layer cannot
   *  bridge into itself. Non-string values are dropped on bake. */
  seg?: string;
  block?: string;
```

In `normalizeTrackToTemplate`'s returned object add:

```ts
      ...(k.seg !== undefined ? { seg: k.seg } : {}),
      ...(k.block !== undefined ? { block: k.block } : {}),
```

In `bakeTemplateToTrack`, before `keyframes.push({...})`:

```ts
    const rawSeg = (k as { seg?: unknown }).seg;
    const rawBlock = (k as { block?: unknown }).block;
```

and inside the push:

```ts
      ...(typeof rawSeg === "string" ? { seg: rawSeg } : {}),
      ...(typeof rawBlock === "string" ? { block: rawBlock } : {}),
```

Change the final return to:

```ts
  return {
    kind: "overlay",
    overlay_id: overlayId,
    keyframes: remintMotionIds(keyframes),
  };
```

(import `remintMotionIds` from `./timeline`).

`motionClip.ts` — in `pasteMotionClip`'s raw branch, change the return to:

```ts
  return {
    kind: "overlay",
    overlay_id: overlayId,
    keyframes: remintMotionIds(keyframes),
  };
```

(import `remintMotionIds` from `./timeline`). `placeMotionClipAt` and `pasteSegmentsClip` both go through `pasteMotionClip`, so they inherit it.

- [ ] **Step 4: Run tests**

Run: `bun test src/lib/video-editor/templates.test.ts src/lib/video-editor/motionClip.test.ts src/lib/video-editor/motionClip.segments.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lib/video-editor/templates.ts src/lib/video-editor/motionClip.ts src/lib/video-editor/templates.test.ts src/lib/video-editor/motionClip.test.ts
git commit -m "feat(web): templates and clips carry seg/block, re-minted on bake/paste"
```

---

### Task 5: The writer — `presets.ts`

**Files:**
- Modify: `web/src/lib/video-editor/presets.ts` — `applyBuildChannels` (:1007), `writeBuildKeyframes` (:1055), `mergeBuildKeyframes` (:1094), `addSegmentBuild` (:1152); new `planSegmentBuild`, `BUILD_STEP_WRITERS`, `BUILD_SCALE_STEP`
- Test: `web/src/lib/video-editor/presets.addSegmentBuild.test.ts` (append) + existing `presets.buildChannels.test.ts` must keep passing

**Interfaces:**
- Produces:
  ```ts
  export type SegmentBuildPlacement = "span" | "playhead" | "append";
  export type SegmentBuildPlan = { startMs: number; endMs: number; placement: SegmentBuildPlacement; nth: number };
  export function planSegmentBuild(track: MotionTrack, segStart: number, segEnd: number, channel: BuildChannelId, atMs: number, durationMs: number): SegmentBuildPlan | null;
  export function addSegmentBuild(timeline, base, overlayId, segStart, segEnd, slot, channels, atMs: number, mint?: () => string): MotionTimeline | null;
  // null = a channel had no room; same reference = nothing to do (as today)
  export function applyBuildChannels(..., atMs, mint?: () => string): MotionTimeline | null;
  ```

- [ ] **Step 1: Write the failing tests** (append to `presets.addSegmentBuild.test.ts`; it already has `REST`, `base`, `empty`, `trackFor`, `sorted`)

```ts
import { planSegmentBuild, applyBuildChannels } from "./presets";
import { propGroupSegments } from "./blocks";

const counter = () => {
  let n = 0;
  return () => `id${++n}`;
};

/** A Build-authored emphasis block: Rotate over [2000, 2600]. */
const rotateBlock = () =>
  applyBuildChannels(empty(), base(), "ov1", "emphasis", ["rotate"], 2000, counter())!;

describe("addSegmentBuild — Nth run of a present channel", () => {
  it("first add is unchanged: joins over the span, stamps seg + block", () => {
    const tl = addSegmentBuild(rotateBlock(), base(), "ov1", 2000, 2600, "emphasis", ["scale"], 2100, counter());
    const t = trackFor(tl!);
    expect(propGroupSegments(t, "scale")).toEqual([{ startMs: 2000, endMs: 2600 }]);
    const blocks = new Set(t.keyframes.map((k) => k.block));
    expect(blocks.size).toBe(1);
    expect([...blocks][0]).toBeDefined();
  });

  it("appends after the last run when the playhead is outside the block", () => {
    const tl = addSegmentBuild(rotateBlock(), base(), "ov1", 2000, 2600, "emphasis", ["rotate"], 100, counter())!;
    const t = trackFor(tl);
    expect(propGroupSegments(t, "rotation")).toEqual([
      { startMs: 2000, endMs: 2600 },
      { startMs: 2601, endMs: 3201 },
    ]);
    // one block, spanning both runs
    expect(trackSegments(t)).toEqual([{ startMs: 2000, endMs: 3201 }]);
  });

  it("lands at the playhead when it is inside the block and free in that lane", () => {
    // Block [2000,2600] has Rotate; a first add gives Scale over the span.
    // Then delay the Rotate lane out of the way by giving the block a
    // Move over the span too and asking for another Rotate at 2300 — the
    // Rotate lane already covers 2300, so it must append instead.
    const withScale = addSegmentBuild(rotateBlock(), base(), "ov1", 2000, 2600, "emphasis", ["scale"], 100, counter())!;
    const appended = addSegmentBuild(withScale, base(), "ov1", 2000, 2600, "emphasis", ["rotate"], 2300, counter())!;
    expect(propGroupSegments(trackFor(appended), "rotation")[1]).toEqual({ startMs: 2601, endMs: 3201 });

    // Now Scale's lane [2000,2600] is free after 2600 — but the block is
    // [2000,3201] after the append, so a Scale at playhead 2800 is inside
    // the block AND free in the scale lane → playhead placement.
    const atPlayhead = addSegmentBuild(appended, base(), "ov1", 2000, 3201, "emphasis", ["scale"], 2800, counter())!;
    expect(propGroupSegments(trackFor(atPlayhead), "scale")).toEqual([
      { startMs: 2000, endMs: 2600 },
      { startMs: 2800, endMs: 3400 },
    ]);
  });

  it("clamps the window against the next run in that lane and the clip end", () => {
    const two = addSegmentBuild(rotateBlock(), base(), "ov1", 2000, 2600, "emphasis", ["rotate"], 100, counter())!;
    // Runs at [2000,2600] and [2601,3201]. Playhead 2000 sits inside run 1
    // → append after run 2 → [3202, 3802].
    const three = addSegmentBuild(two, base(), "ov1", 2000, 3201, "emphasis", ["rotate"], 2000, counter())!;
    expect(propGroupSegments(trackFor(three), "rotation")[2]).toEqual({ startMs: 3202, endMs: 3802 });
    // Duration 5000: keep appending until the clip end clamps, then refuses.
    let tl = three;
    let end = 3802;
    for (;;) {
      const next = addSegmentBuild(tl, base(), "ov1", 2000, end, "emphasis", ["rotate"], 0, counter());
      if (next === null) break;
      tl = next;
      const runs = propGroupSegments(trackFor(tl), "rotation");
      end = runs[runs.length - 1]!.endMs;
      expect(end).toBeLessThanOrEqual(5000);
    }
    expect(end).toBeGreaterThan(4800);
  });

  it("values are cumulative from the pose at the run's start", () => {
    const tl = addSegmentBuild(rotateBlock(), base(), "ov1", 2000, 2600, "emphasis", ["rotate"], 100, counter())!;
    const rot = sorted(tl).filter((k) => k.props.rotation !== undefined);
    // Build emphasis Rotate is a spin (+360 back to rest) — so the pose at
    // 2601 is rest (0); the step adds BUILD_ROTATE_DEG.
    const run2 = rot.filter((k) => k.t_ms >= 2601);
    expect(run2.map((k) => k.props.rotation)).toEqual([0, 15]);
    expect(run2.map((k) => k.easing)).toEqual(["linear", "out"]);
    expect(run2.every((k) => k.label === BUILD_CHANNEL_LABELS.rotate)).toBe(true);
    expect(run2.every((k) => k.role === undefined)).toBe(true);
    expect(run2[0]!.seg).toBe(run2[1]!.seg);
    expect(run2[0]!.seg).not.toBe(rot[0]!.seg);
    expect(run2[0]!.block).toBe(rot[0]!.block);
  });

  it("opacity toggles: dim, then back to rest", () => {
    const op = applyBuildChannels(empty(), base(), "ov1", "in", ["opacity"], 0, counter())!;
    const dim = addSegmentBuild(op, base(), "ov1", 0, 500, "in", ["opacity"], 100, counter())!;
    const d = sorted(dim).filter((k) => k.t_ms >= 501);
    expect(d.map((k) => k.props.opacity)).toEqual([1, 0.4]);
    const back = addSegmentBuild(dim, base(), "ov1", 0, 1001, "in", ["opacity"], 100, counter())!;
    const b = sorted(back).filter((k) => k.t_ms >= 1002);
    expect(b.map((k) => k.props.opacity)).toEqual([0.4, 1]);
  });

  it("stamps a preset-authored block with one block id before adding", () => {
    const pulse = applyEmphasisPreset(empty(), base(), "ov1", "pulse", 2000)!;
    expect(trackFor(pulse).keyframes.every((k) => k.block === undefined)).toBe(true);
    const next = addSegmentBuild(pulse, base(), "ov1", 2000, 2600, "emphasis", ["scale"], 100, counter())!;
    const blocks = new Set(trackFor(next).keyframes.map((k) => k.block));
    expect(blocks.size).toBe(1);
    expect(propGroupSegments(trackFor(next), "scale")).toHaveLength(2);
    expect(trackSegments(trackFor(next))).toHaveLength(1);
  });

  it("returns null when the appended run has no room", () => {
    const tl: MotionTimeline = { ...empty(), duration_ms: 2700 };
    const blk = applyBuildChannels(tl, base(), "ov1", "emphasis", ["rotate"], 2000, counter())!;
    expect(addSegmentBuild(blk, base(), "ov1", 2000, 2600, "emphasis", ["rotate"], 0, counter())).toBeNull();
  });
});

describe("planSegmentBuild", () => {
  it("reports span / playhead / append with nth", () => {
    const t = trackFor(rotateBlock());
    expect(planSegmentBuild(t, 2000, 2600, "scale", 100, 5000)).toEqual({ startMs: 2000, endMs: 2600, placement: "span", nth: 1 });
    expect(planSegmentBuild(t, 2000, 2600, "rotate", 100, 5000)).toEqual({ startMs: 2601, endMs: 3201, placement: "append", nth: 2 });
  });
});
```

Also update the two existing calls in this file that pass six arguments — add a seventh `100` (any playhead outside the block) so the "first add" cases keep their behaviour.

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/lib/video-editor/presets.addSegmentBuild.test.ts`
Expected: FAIL (arity / `planSegmentBuild` missing).

- [ ] **Step 3: Implement**

Imports: add `propGroupSegments`, `MIN_BLOCK_SPAN_MS` to the `./blocks` import; add `mintMotionId` to the `./timeline` import; import `type MotionTrack` from `./timeline`.

Constants (next to `BUILD_BLINK_OPACITY`):

```ts
/** The pulse multiplier, named: what an added Scale run grows by. */
export const BUILD_SCALE_STEP = 1.08;
```

Channel → lane:

```ts
const CHANNEL_GROUP: Record<BuildChannelId, PropGroupKey> = {
  path: "position",
  move: "position",
  scale: "scale",
  rotate: "rotation",
  opacity: "opacity",
};
```

Step writers (after `BUILD_EDGE_WRITERS`):

```ts
/** An ADDED run (2026-09-22): starts from the pose the layer is in and steps
 *  it further — cumulative, so runs stacked back to back read as one
 *  staged motion with no jump at the seams. Opacity is the one toggle:
 *  dimmed layers come back to rest, everything else dims. */
const BUILD_STEP_WRITERS: Record<
  Exclude<BuildChannelId, "path">,
  (pose: MotionProps, rest: MotionProps) => { from: Partial<MotionProps>; to: Partial<MotionProps> }
> = {
  move: (p) => ({ from: { x: p.x }, to: { x: p.x + SLIDE_OFFSET } }),
  rotate: (p) => ({
    from: { rotation: p.rotation },
    to: { rotation: p.rotation + BUILD_ROTATE_DEG },
  }),
  scale: (p) => ({ from: { scale: p.scale }, to: { scale: p.scale * BUILD_SCALE_STEP } }),
  opacity: (p, rest) => ({
    from: { opacity: p.opacity },
    to: {
      opacity:
        p.opacity > rest.opacity * BUILD_BLINK_OPACITY
          ? p.opacity * BUILD_BLINK_OPACITY
          : rest.opacity,
    },
  }),
};

function writeStepKeyframes(
  channel: BuildChannelId,
  pose: MotionProps,
  rest: MotionProps,
  startMs: number,
  endMs: number
): MotionKeyframe[] {
  if (channel === "path") {
    return [
      { t_ms: startMs, props: { x: pose.x, y: pose.y }, easing: "linear", label: PATH_LABEL },
      {
        t_ms: endMs,
        props: { x: pose.x + SLIDE_OFFSET, y: pose.y },
        easing: "out",
        label: PATH_LABEL,
        path: { points: [{ dx: -SLIDE_OFFSET / 2, dy: PATH_ARC_DY }] },
      },
    ];
  }
  const label = BUILD_CHANNEL_LABELS[channel];
  const { from, to } = BUILD_STEP_WRITERS[channel](pose, rest);
  return [
    { t_ms: startMs, props: from, easing: "linear", label },
    { t_ms: endMs, props: to, easing: "out", label },
  ];
}
```

Plan:

```ts
export type SegmentBuildPlacement = "span" | "playhead" | "append";
export type SegmentBuildPlan = {
  startMs: number;
  endMs: number;
  placement: SegmentBuildPlacement;
  /** 1 = the block's first run of this channel (the "join over the span"
   *  case); 2+ = an added run. */
  nth: number;
};

/** Where an Add of `channel` on the block `[segStart, segEnd]` lands — the
 *  ONE derivation `addSegmentBuild` writes from and the editor's analytics
 *  read, so the two cannot disagree. `null` when an added run has no room
 *  (`< EMPHASIS_MIN_WINDOW_MS`). Pure.
 *
 *  First run: the block's own span. Nth run: width = the channel's last run
 *  in the block (uniform repeats); start = the playhead when it is inside
 *  the block and no run of this lane covers it, else 1ms after the last
 *  run; end clamped to 1ms before the next run of the lane and to the clip
 *  end. */
export function planSegmentBuild(
  track: MotionTrack,
  segStart: number,
  segEnd: number,
  channel: BuildChannelId,
  atMs: number,
  durationMs: number
): SegmentBuildPlan | null {
  const lane = propGroupSegments(track, CHANNEL_GROUP[channel]).filter(
    (s) => s.startMs >= segStart && s.endMs <= segEnd
  );
  if (lane.length === 0) {
    return { startMs: segStart, endMs: segEnd, placement: "span", nth: 1 };
  }
  const last = lane[lane.length - 1]!;
  const width = Math.max(MIN_BLOCK_SPAN_MS, last.endMs - last.startMs);
  const covered = lane.some((s) => s.startMs <= atMs && atMs <= s.endMs);
  const atPlayhead = segStart <= atMs && atMs <= segEnd && !covered;
  const startMs = atPlayhead ? atMs : last.endMs + 1;
  const nextStart = lane.find((s) => s.startMs > startMs)?.startMs;
  const endMs = Math.min(
    startMs + width,
    nextStart !== undefined ? nextStart - 1 : Infinity,
    durationMs
  );
  if (endMs - startMs < EMPHASIS_MIN_WINDOW_MS) return null;
  return {
    startMs,
    endMs,
    placement: atPlayhead ? "playhead" : "append",
    nth: lane.length + 1,
  };
}
```

`mergeBuildKeyframes`: add parameters `seg: string, block: string` after `slot`, and in the merge loop stamp them — the `existing` branch gets `if (existing.block === undefined) existing.block = block;` (never overwrite a block id; never overwrite an existing `seg` either), the push branch spreads `{ ...w, seg, block, ...(role …) }`. Also sort at the end: `track.keyframes.sort((a, b) => a.t_ms - b.t_ms);` (the appended run lands after existing keyframes; nothing downstream may assume push order — sort makes it explicit).

`applyBuildChannels`: add `mint: () => string = mintMotionId` as the last parameter; the `mergeBuildKeyframes` call passes `mint(), mint()` (seg, block — one each per click).

`addSegmentBuild` — replace the body after the `isRealSegment` guard:

```ts
  const blockId =
    current.keyframes.find(
      (k) => k.t_ms >= segStart && k.t_ms <= segEnd && k.block !== undefined
    )?.block ?? mint();
  // A preset-authored block carries no id yet: stamp it first (precedent:
  // `stampInRole`), same undo step, so the runs added below bridge to it.
  let next: MotionTimeline = {
    ...timeline,
    tracks: timeline.tracks.map((tr) =>
      tr.kind === "overlay" && tr.overlay_id === overlayId
        ? {
            ...tr,
            keyframes: tr.keyframes.map((k) =>
              k.t_ms >= segStart && k.t_ms <= segEnd && k.block === undefined
                ? { ...k, block: blockId }
                : k
            ),
          }
        : tr
    ),
  };
  const seg = mint();
  const rest = base.get(overlayId);
  if (!rest) return timeline;

  for (const channel of channels) {
    const track = next.tracks.find(
      (t) => t.kind === "overlay" && t.overlay_id === overlayId
    )!;
    const plan = planSegmentBuild(track, segStart, segEnd, channel, atMs, timeline.duration_ms);
    if (!plan) return null;
    const pose =
      plan.placement === "span" && slot !== "emphasis"
        ? rest
        : sampleTimelinePropsAt(next, base, plan.startMs).get(overlayId);
    if (!pose) return timeline;
    const written =
      plan.placement === "span"
        ? writeBuildKeyframes(slot, pose, plan.startMs, plan.endMs, [channel])
        : writeStepKeyframes(channel, pose, rest, plan.startMs, plan.endMs);
    next = mergeBuildKeyframes(next, overlayId, plan.placement === "span" ? slot : "emphasis", written, plan.startMs, plan.endMs, seg, blockId);
  }
  return next;
```

Note the block span passed to later channels in one click is still the original `[segStart, segEnd]` — matches the test "Rotate + Scale in one click each plan their own window".

Update `addSegmentBuild`'s signature to `(timeline, base, overlayId, segStart, segEnd, slot, channels, atMs: number, mint: () => string = mintMotionId): MotionTimeline | null` and rewrite its doc comment: "A channel the block already has gets ANOTHER run (2026-09-22) — see `planSegmentBuild` for where — with cumulative values from the pose at its start (`BUILD_STEP_WRITERS`). `null` when an added run has no room; the same reference when nothing was written."

- [ ] **Step 4: Run tests**

Run: `bun test src/lib/video-editor/presets.addSegmentBuild.test.ts src/lib/video-editor/presets.buildChannels.test.ts src/lib/video-editor/presets.test.ts src/lib/video-editor/presets.replaceSegment.test.ts`
Expected: PASS. If `presets.buildChannels.test.ts` compares whole keyframe objects with `toEqual`, the new `seg`/`block` fields will break equality — update those assertions to `toMatchObject`, or pass a counter `mint` and include the ids.

- [ ] **Step 5: Commit**

```bash
git add src/lib/video-editor/presets.ts src/lib/video-editor/presets.addSegmentBuild.test.ts src/lib/video-editor/presets.buildChannels.test.ts
git commit -m "feat(web): addSegmentBuild adds an Nth run of a present channel (planSegmentBuild, step writers, seg/block stamping)"
```

---

### Task 6: UI — present channels pickable, playhead through the props

**Files:**
- Modify: `web/src/components/video-editor/MotionPresetGrid.tsx:22-50` (`hint?: string`), `:180` (`title`)
- Modify: `web/src/components/video-editor/MotionSourceTabs.tsx:200-215` (`BuildChannelPanel` present branch)
- Modify: `web/src/components/video-editor/types.ts:266-272` (`onAddSegmentBuild` gains `atMs`)
- Modify: `web/src/components/video-editor/BlockTrackRow.tsx:456` (SegmentBar prop), `:1093-1113` (note + onAdd), `:2509-2520` (forward `playheadMs`)
- Test: `web/src/components/video-editor/BuildChannelPanel.test.tsx` (append), `web/src/components/video-editor/TimelineDock.buildtab.test.tsx` (adjust the block-menu expectation to receive `atMs`)

- [ ] **Step 1: Write the failing tests**

BuildChannelPanel.test.tsx:

```ts
  it("a present channel is pickable again — dot, subtitle, hint, no disabled", () => {
    const onAdd = renderPanel({ present: ["move"], addLabel: "Add to block" });
    const card = body().getByTestId("x-build-move");
    expect(card).not.toBeDisabled();
    expect(card.getAttribute("title")).toContain("already animates");
    expect(body().getByText("Add another")).toBeTruthy();
    fireEvent.click(card);
    fireEvent.click(body().getByTestId("x-build-add"));
    expect(onAdd).toHaveBeenCalledWith(["move"]);
  });

  it("the exclusive partner of a present channel stays disabled", () => {
    renderPanel({ present: ["move"] });
    expect(body().getByTestId("x-build-path")).toBeDisabled();
  });
```

TimelineDock.buildtab.test.tsx: find the assertion on `onAddSegmentBuild` for the block menu (search `segment-context-build-add`) and extend the expected call with the dock's `playheadMs` as the sixth argument.

- [ ] **Step 2: Run to verify they fail**

Run: `bun test src/components/video-editor/BuildChannelPanel.test.tsx src/components/video-editor/TimelineDock.buildtab.test.tsx`
Expected: FAIL (present card disabled; arity).

- [ ] **Step 3: Implement**

`MotionPresetGrid.tsx` — in `MotionPresetOption` after `disabledReason?`:

```ts
  /** Tooltip for an ENABLED card (a present Build channel explaining what a
   *  second pick does). `disabledReason` wins while disabled. */
  hint?: string;
```

and `title={option.disabled ? option.disabledReason : option.hint}`.

`MotionSourceTabs.tsx` — replace the `present.includes(c.id)` branch:

```ts
          if (present.includes(c.id)) {
            return {
              ...c,
              active: selection.has(c.id),
              subtitle: "Add another",
              hint: `${c.label} already animates in this block — adds another run at the playhead, or right after its last one`,
            };
          }
```

(The partner branch below stays as is.) Update the prop doc: "Channels the target ALREADY animates (a block's Add tab). Pickable — a pick adds another run (2026-09-22) — and marked "Add another"; each one's exclusive partner stays unpickable (Move present ⇒ Path unpickable: both write x/y)."

`types.ts` — `onAddSegmentBuild` gains a sixth parameter `atMs: number` with doc: "the playhead — where an added run of a channel the block already has lands when it is inside the block (see `planSegmentBuild`)".

`BlockTrackRow.tsx`:
- `SegmentBar`'s `onAddSegmentBuild?: (slot: SlotKind, channelIds: string[]) => void` is unchanged — it closes over the playhead at the row.
- The note (`:1097-1101`): present case → ``Add what animates — a channel already here gets another run at the playhead, or right after its last one. Already here: ${…}.``; the empty case unchanged.
- At `:2509-2520` pass `playheadMs` as the sixth argument to `onAddSegmentBuild(track.id, segment.startMs, segment.endMs, slot, channelIds, playheadMs)`.

- [ ] **Step 4: Run tests**

Run: `bun test src/components/video-editor/BuildChannelPanel.test.tsx src/components/video-editor/TimelineDock.buildtab.test.tsx src/components/video-editor/MotionPresetGrid.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/components/video-editor/MotionPresetGrid.tsx src/components/video-editor/MotionSourceTabs.tsx src/components/video-editor/types.ts src/components/video-editor/BlockTrackRow.tsx src/components/video-editor/BuildChannelPanel.test.tsx src/components/video-editor/TimelineDock.buildtab.test.tsx
git commit -m "feat(web): Build tab lets a present channel add another run; playhead flows to onAddSegmentBuild"
```

---

### Task 7: Adapter, editor toast, analytics

**Files:**
- Modify: `web/src/components/studio/kv-generator/motion/useMotionEditorState.ts:1169-1190`
- Modify: `web/src/components/studio/kv-generator/motion/KvMotionEditor.tsx:1451-1478`
- Modify: `web/src/lib/analytics/kv-generator-events.ts:1290-1310` (`KvMotionBuildAppliedProps`)
- Test: `web/src/components/studio/kv-generator/motion/useMotionEditorState.addSegmentBuild.test.ts` (new, only if the directory already has a hook test harness to copy — check `ls src/components/studio/kv-generator/motion/*.test.ts*`; otherwise cover through the pure-function tests of Task 5 and note it in the commit)

- [ ] **Step 1: Implement the adapter**

```ts
  // … `null` from the writer is "no room for the added run" — distinct from
  // the same-reference no-op — so the editor can show the room toast rather
  // than blaming the layer.
  const addSegmentBuild = useCallback(
    (
      trackId: string,
      segStart: number,
      segEnd: number,
      slot: SlotKind,
      channelIds: string[],
      atMs: number
    ): "ok" | "unavailable" | "no_room" => {
      const next = addSegmentBuildKeyframes(
        timeline,
        base,
        trackId,
        segStart,
        segEnd,
        slot,
        channelIds as BuildChannelId[],
        atMs
      );
      if (next === null) return "no_room";
      if (next === timeline) return "unavailable";
      push(next);
      return "ok";
    },
    [timeline, base, push]
  );
```

- [ ] **Step 2: Implement the editor handler**

```ts
  const handleAddSegmentBuild = useCallback(
    (
      trackId: string,
      segStart: number,
      segEnd: number,
      slot: SlotKind,
      channelIds: string[],
      atMs: number
    ) => {
      // Plans are read BEFORE the write (the write changes the lanes).
      const track = state.timeline.tracks.find(
        (t) => t.kind === "overlay" && t.overlay_id === trackId
      );
      const plans = track
        ? channelIds.map((id) =>
            planSegmentBuild(track, segStart, segEnd, id as BuildChannelId, atMs, state.timeline.duration_ms)
          )
        : [];
      const result = state.addSegmentBuild(trackId, segStart, segEnd, slot, channelIds, atMs);
      if (result === "no_room") {
        showToast("Not enough room for that", "Move the playhead earlier or shorten the block's last run.", "error");
        return;
      }
      if (result === "unavailable") {
        showToast("That layer can't be animated right now", "It may be hidden, locked, or no longer on this board.", "error");
        return;
      }
      trackKvMotionBuildApplied({
        project_id: projectId,
        slot,
        channels: channelIds,
        source: "add",
        track_count: 1,
        nth: Math.max(1, ...plans.map((p) => p?.nth ?? 1)),
        placement: plans.find((p) => p && p.placement !== "span")?.placement ?? "span",
      });
    },
    [state, projectId, showToast]
  );
```

(import `planSegmentBuild` from `@/lib/video-editor/presets`; confirm `state.timeline` is exposed by the hook — it is what the dock renders from.)

- [ ] **Step 3: Analytics type** — in `KvMotionBuildAppliedProps` add:

```ts
  /** `source: "add"` only (2026-09-22): which run of the channel this is in
   *  the block (1 = it joined over the span) and where it landed. Whether
   *  people stack runs at all is what decides if the Nth-run path stays. */
  nth?: number;
  placement?: "span" | "playhead" | "append";
```

- [ ] **Step 4: Type-check the touched files and run the neighbouring suites**

Run: `bun test src/components/video-editor/TimelineDock.buildtab.test.tsx src/lib/video-editor/presets.addSegmentBuild.test.ts`
Run: `npx tsc --noEmit -p tsconfig.json 2>&1 | grep -E "video-editor|kv-generator/motion|kv-generator-events" | head` — expect no NEW errors in these paths (tsc has a large baseline elsewhere; only lines naming the touched files matter).

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/motion/useMotionEditorState.ts src/components/studio/kv-generator/motion/KvMotionEditor.tsx src/lib/analytics/kv-generator-events.ts
git commit -m "feat(web): wire Nth-run Build add — no-room toast, nth/placement analytics"
```

---

### Task 8: Live check + spec status

- [ ] **Step 1:** Start `web` (`preview_start` with the launch config, or Daffa's running dev server at :3000), open a KV Motion project, right-click a block → Build → pick a present channel → Add. Expect: a new bar in that lane, one block bar spanning both, no console errors. Repeat 3× with the playhead outside the block: bars stack.
- [ ] **Step 2:** Drag one of the stacked lane bars; delete one; undo. Expect: bars keep their identity, no merge.
- [ ] **Step 3:** Flip the spec's `Status:` to `implemented 2026-09-22` and commit: `git commit -am "docs(spec): KV Motion build sub-segments — implemented"` (from the workspace root).
