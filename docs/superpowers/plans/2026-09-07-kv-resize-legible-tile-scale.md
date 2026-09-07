# KV Resize Legible Tile Scale Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Small Resize tiles render at an editable size regardless of their ratio to the largest tile, their overlay handles stop covering the box they belong to, and one tile can be zoomed to fill the viewport.

**Architecture:** Three independent changes to the live per-tile Resize surface. (1) A pure display-width policy module that floors the existing shared scale, capped so it never asks for more than a tile's native width. (2) Explicit fabric control sizing on overlay objects so handles sit outside the box. (3) A pure fit-camera helper plus a `fitTile` on the existing pan/zoom viewport, surfaced by joining the bottom nav's **existing** shared zoom pill — no new pill, no new analytics event. Nothing changes overlay data, the apron model, or the shared canvas layout.

**Tech Stack:** Next.js 16 / React 19 / TypeScript, fabric v7, `bun test` + @testing-library/react, PostHog via `safeCapture`.

**Spec:** `docs/superpowers/specs/2026-09-07-kv-resize-legible-tile-scale-design.md`

## Global Constraints

- Tests run with `bun test` (bunfig preloads jest-dom). NOT `bunx vitest`. There is no type gate — `next build` sets `ignoreBuildErrors` and `tsc` has a large pre-existing error baseline.
- Build with `node`, not `bun run build` — the bun build path is broken in this repo.
- Do **not** touch these files; they carry uncommitted work in the tree: `src/components/studio/kv-generator/KvLayersPanel.tsx`, `src/components/studio/kv-generator/motion/KvMotionEditor.tsx`, `src/components/video-editor/BlockTrackRow.tsx`, `src/components/video-editor/TimelineDock.tsx`, `src/components/video-editor/TrackRow.tsx`.
- No new hardcoded dark hex values (`bg-[rgba(26,26,26,…)]` etc.) — use surface tokens and the existing `frndos-float-panel` class so the aurora theme sweep reaches new UI.
- `MIN_TILE_DISPLAY_WIDTH = 420` is provisional. It must exist as exactly one exported constant so it can be retuned in one edit.
- Work on the current branch. **Do not push.** Commit locally only.
- All paths below are relative to `web/`.

### Known baseline red — do not chase it

Measured on a clean worktree of `origin/develop` at `acfd85fbf`, before any
change in this plan:

| Suite | Result |
|---|---|
| `KvTileOverlayEditor.test.tsx` | 39 pass, 0 fail |
| `KvTileOverlayEditor.boxes.test.tsx` | 16 pass, 0 fail |
| `KvTileOverlayEditor.shape.test.tsx` | 7 pass, 0 fail |
| `KvTileOverlayEditor.analytics.test.tsx` | 6 pass, 0 fail |
| `KvResizeResultRow.test.tsx` | 19 pass, **1 fail** |
| `resizeBoardLayout.test.ts` | 13 pass, 0 fail |
| `focusCamera.test.ts` | 19 pass, 0 fail |

The one failure is `KvResizeResultRow — inline editor > shows the Reset
button when row.overlays is a snapshot, and fires onResetOverlays on click`,
which fails on an unwrapped `act(...)` state update from
`KvTileOverlayEditor`. It fails when run alone too, so it is not
cross-suite mock contamination. **It is pre-existing and out of scope.**

Where a step below says a suite should PASS, it means "no NEW failures
against this table". Do not fix this test as a side effect of another task —
if a task appears to need it fixed, stop and report instead.

`focusCamera.test.ts` already exists with 19 tests, so Task 4 appends to it
rather than creating it.

---

### Task 1: Tile display-width policy (pure module)

**Files:**
- Create: `src/components/studio/kv-generator/resizeTileScale.ts`
- Test: `src/components/studio/kv-generator/resizeTileScale.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces: `MAX_TILE_DISPLAY_WIDTH: number`, `MIN_TILE_DISPLAY_WIDTH: number`, `maxNativeTileWidth(widths: readonly number[]): number`, `tileDisplayWidth(args: { nativeWidth: number; maxNativeWidth: number; minDisplayWidth?: number }): number`.

- [ ] **Step 1: Write the failing test**

Create `src/components/studio/kv-generator/resizeTileScale.test.ts`:

```ts
import { describe, expect, test } from "bun:test";
import {
  MAX_TILE_DISPLAY_WIDTH,
  MIN_TILE_DISPLAY_WIDTH,
  maxNativeTileWidth,
  tileDisplayWidth,
} from "./resizeTileScale";

describe("maxNativeTileWidth", () => {
  test("returns the widest entry", () => {
    expect(maxNativeTileWidth([1080, 2400, 640])).toBe(2400);
  });

  test("floors at 1 so the scale can never divide by zero", () => {
    expect(maxNativeTileWidth([])).toBe(1);
    expect(maxNativeTileWidth([0, -5, NaN])).toBe(1);
  });
});

describe("tileDisplayWidth", () => {
  const SET_MAX = 2400;

  test("the widest tile still maps to the canvas width", () => {
    expect(
      tileDisplayWidth({ nativeWidth: 2400, maxNativeWidth: SET_MAX })
    ).toBe(MAX_TILE_DISPLAY_WIDTH);
  });

  test("a tile already above the floor is byte-identical to the old policy", () => {
    const old = Math.round(1920 * (MAX_TILE_DISPLAY_WIDTH / SET_MAX));
    expect(old).toBeGreaterThan(MIN_TILE_DISPLAY_WIDTH);
    expect(
      tileDisplayWidth({ nativeWidth: 1920, maxNativeWidth: SET_MAX })
    ).toBe(old);
  });

  test("a tile below the floor is raised to the floor", () => {
    expect(
      tileDisplayWidth({ nativeWidth: 1080, maxNativeWidth: SET_MAX })
    ).toBe(MIN_TILE_DISPLAY_WIDTH);
    expect(
      tileDisplayWidth({ nativeWidth: 640, maxNativeWidth: SET_MAX })
    ).toBe(MIN_TILE_DISPLAY_WIDTH);
  });

  test("two tiles below the floor land on the same width whatever their ratio", () => {
    expect(tileDisplayWidth({ nativeWidth: 1080, maxNativeWidth: SET_MAX })).toBe(
      tileDisplayWidth({ nativeWidth: 640, maxNativeWidth: SET_MAX })
    );
  });

  test("a tile narrower than the floor stops at 100% native", () => {
    expect(
      tileDisplayWidth({ nativeWidth: 300, maxNativeWidth: SET_MAX })
    ).toBe(300);
  });

  test("a set whose widest tile is under the canvas width is unchanged", () => {
    expect(tileDisplayWidth({ nativeWidth: 300, maxNativeWidth: 300 })).toBe(
      MAX_TILE_DISPLAY_WIDTH
    );
  });

  test("never exceeds the canvas width", () => {
    for (const w of [1, 300, 640, 1080, 1200, 1920, 2400]) {
      expect(
        tileDisplayWidth({ nativeWidth: w, maxNativeWidth: SET_MAX })
      ).toBeLessThanOrEqual(MAX_TILE_DISPLAY_WIDTH);
    }
  });

  test("is monotonic in native width", () => {
    const widths = [300, 640, 1080, 1200, 1920, 2400];
    const rendered = widths.map((w) =>
      tileDisplayWidth({ nativeWidth: w, maxNativeWidth: SET_MAX })
    );
    for (let i = 1; i < rendered.length; i++) {
      expect(rendered[i]).toBeGreaterThanOrEqual(rendered[i - 1]);
    }
  });

  test("an override floor is honoured", () => {
    expect(
      tileDisplayWidth({
        nativeWidth: 1080,
        maxNativeWidth: SET_MAX,
        minDisplayWidth: 600,
      })
    ).toBe(600);
  });

  test("returns 0 for a tile with no width", () => {
    expect(tileDisplayWidth({ nativeWidth: 0, maxNativeWidth: SET_MAX })).toBe(0);
    expect(tileDisplayWidth({ nativeWidth: NaN, maxNativeWidth: SET_MAX })).toBe(0);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/resizeTileScale.test.ts`
Expected: FAIL — cannot resolve module `./resizeTileScale`.

- [ ] **Step 3: Write the implementation**

Create `src/components/studio/kv-generator/resizeTileScale.ts`:

```ts
/**
 * Display-width policy for Resize tiles.
 *
 * The base is unchanged from what this surface has always done: one shared
 * scale maps the widest native width in the set to the canvas content width,
 * and everything smaller renders proportionally narrower.
 *
 * What is added is a FLOOR, because strictly proportional collapses a small
 * target next to a large one until its overlays cannot be selected. Two
 * ceilings bound the floor:
 *
 *  - The floor never asks for more than the tile's own native width. A 300px
 *    tile shown at 420px would be a 1.4x upscale, presenting fidelity we do
 *    not have. 1:1 is the honest maximum for those tiles; zoom covers the
 *    rest.
 *  - The native cap sits INSIDE the floor, not around the whole expression.
 *    Written as `min(max(proportional, MIN), nativeWidth)` a set whose widest
 *    tile is itself under the canvas width would SHRINK that widest tile
 *    (every tile 300px native: 752 -> 300). Because the result here is a
 *    `max` whose first argument is the old policy's own value, the policy can
 *    only ever raise a tile and never lower one — which is what makes "large
 *    tiles do not change" a property of the arithmetic rather than something
 *    to re-verify per set.
 */

/** Canvas content width every tile is measured against. */
export const MAX_TILE_DISPLAY_WIDTH = 752;

/**
 * Smallest width a tile is rendered at before the native cap applies.
 *
 * PROVISIONAL — chosen to keep a square tile's body text legible and to keep
 * overlay handles off the box they belong to. Retune here and nowhere else.
 */
export const MIN_TILE_DISPLAY_WIDTH = 420;

/**
 * Widest native width in a set, floored at 1 so it is always a safe divisor.
 * Non-finite and non-positive entries are ignored rather than poisoning the
 * result, which a bare `Math.max(...)` over API data would not guarantee.
 */
export function maxNativeTileWidth(widths: readonly number[]): number {
  let max = 1;
  for (const w of widths) {
    if (Number.isFinite(w) && w > max) max = w;
  }
  return max;
}

/** On-screen CSS width for one tile. See the module header for why the two
 *  ceilings are nested the way they are. */
export function tileDisplayWidth(args: {
  nativeWidth: number;
  maxNativeWidth: number;
  minDisplayWidth?: number;
}): number {
  const {
    nativeWidth,
    maxNativeWidth,
    minDisplayWidth = MIN_TILE_DISPLAY_WIDTH,
  } = args;

  if (!Number.isFinite(nativeWidth) || nativeWidth <= 0) return 0;

  const denom =
    Number.isFinite(maxNativeWidth) && maxNativeWidth > 0 ? maxNativeWidth : 1;
  const proportional = Math.round(
    nativeWidth * (MAX_TILE_DISPLAY_WIDTH / denom)
  );

  return Math.max(proportional, Math.min(minDisplayWidth, nativeWidth));
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/resizeTileScale.test.ts`
Expected: PASS, 12 tests.

- [ ] **Step 5: Commit**

```bash
git add web/src/components/studio/kv-generator/resizeTileScale.ts web/src/components/studio/kv-generator/resizeTileScale.test.ts
git commit -m "feat(web): floor the KV Resize tile display-width policy"
```

---

### Task 2: Wire the policy into KvResizeCanvas

**Files:**
- Modify: `src/components/studio/kv-generator/KvResizeCanvas.tsx:680-692`

**Interfaces:**
- Consumes: `maxNativeTileWidth`, `tileDisplayWidth` from Task 1.
- Produces: no new exports. `displayWidthFor(nativeWidth: number): number` keeps its existing signature and both existing call sites (`:2219` master row, `:2334` result row) are untouched.

- [ ] **Step 1: Read the current block**

Run: `cd web && sed -n '678,694p' src/components/studio/kv-generator/KvResizeCanvas.tsx`

Confirm it matches:

```ts
  // Render tiles proportionally to their real relative sizes: scale the
  // original + every result tile by one shared factor so the widest native
  // dimension across them all maps to the canvas content width (752px), and
  // everything smaller renders proportionally narrower.
  const MAX_TILE_DISPLAY_WIDTH = 752;
  const maxNativeWidth = Math.max(
    sourceSize.w,
    ...exports.map((r) => r.width),
    1
  );
  const displayScale = MAX_TILE_DISPLAY_WIDTH / maxNativeWidth;
  const displayWidthFor = (nativeWidth: number) =>
    Math.round(nativeWidth * displayScale);
```

If it does not match, stop and report — the line numbers have moved and the rest of this task's assumptions need re-checking.

- [ ] **Step 2: Replace the block**

```ts
  // Tiles render proportionally to their real relative sizes, FLOORED so a
  // small target next to a large one stays editable. The policy (and why its
  // two ceilings nest the way they do) lives in resizeTileScale.ts — keep it
  // there rather than inlining it here, so it stays unit-testable without a
  // canvas and so the floor constant has exactly one home.
  const maxNativeWidth = maxNativeTileWidth([
    sourceSize.w,
    ...exports.map((r) => r.width),
  ]);
  const displayWidthFor = (nativeWidth: number) =>
    tileDisplayWidth({ nativeWidth, maxNativeWidth });
```

- [ ] **Step 3: Add the import**

Add to the import block alongside the other local `./` imports in the same file (near the existing `import { apronPxForOverlays } …` style entries):

```ts
import {
  maxNativeTileWidth,
  tileDisplayWidth,
} from "./resizeTileScale";
```

- [ ] **Step 4: Verify no other consumer read the removed locals**

Run: `cd web && grep -rn "displayScale\|MAX_TILE_DISPLAY_WIDTH" src/components/studio/kv-generator/KvResizeCanvas.tsx`
Expected: no hits (both locals are gone; the constant now lives in `resizeTileScale.ts`).

- [ ] **Step 5: Run the resize test files and the build**

```bash
cd web
bun test src/components/studio/kv-generator/resizeTileScale.test.ts src/components/studio/kv-generator/KvResizeResultRow.test.tsx src/components/studio/kv-generator/resizeBoardLayout.test.ts
node node_modules/next/dist/bin/next build
```

Expected: tests PASS, build succeeds.

- [ ] **Step 6: Runtime check (manual, cannot be automated)**

Open a KV file with a Resize set that spans a wide range — at least one tile at or near the widest native width, one mid-size tile, and one tile whose native width is under 420px.

Verify, and record a screenshot for each:
1. The widest tile is pixel-identical to before the change.
2. Mid-size tiles all render at the same width as each other.
3. The sub-420px tile renders at its native width, not stretched past it.
4. The page still lays out inside its `max-w-[900px]` column with no horizontal scroll.
5. On a floored tile holding a layer that hangs OUTSIDE the frame, the apron
   does not cover the row header or the "Push to all tiles" / download bar.
   The apron scales with `displayWidth`, so raising a small tile grows its
   overhang in absolute px — and that overhang already needed
   `relative z-20` on those two elements to stop it swallowing clicks
   (`KvResizeCanvas.tsx:2190`). Click both while such a tile is above them.

If check 5 fails, stop and report rather than widening the z-index sweep —
that is the spec's open question 3 and it needs a decision, not a patch.

- [ ] **Step 7: Commit**

```bash
git add web/src/components/studio/kv-generator/KvResizeCanvas.tsx
git commit -m "feat(web): use the floored tile-scale policy on the Resize canvas"
```

---

### Task 3: Push overlay handles off the box

**Files:**
- Create: `src/components/studio/kv-generator/overlayControlStyle.ts`
- Modify: `src/components/studio/kv-generator/KvTileOverlayEditor.tsx:1854`
- Test: `src/components/studio/kv-generator/KvTileOverlayEditor.test.tsx`

**Interfaces:**
- Consumes: nothing from earlier tasks — this is independent of the scale change and can ship alone.
- Produces: `OVERLAY_CONTROL: { cornerSize: number; touchCornerSize: number; padding: number }`.

- [ ] **Step 1: Measure the current default before choosing a replacement**

Run: `cd web && node -e "const f=require('fabric');const o=new f.Rect({width:10,height:10});console.log({cornerSize:o.cornerSize,touchCornerSize:o.touchCornerSize,padding:o.padding})"`

Record the printed values in the commit message. Do not carry a remembered number into the constants — the point of this task is that the size becomes deliberate, and that starts with knowing what it currently is.

- [ ] **Step 2: Write the failing test**

Append to `src/components/studio/kv-generator/KvTileOverlayEditor.test.tsx`, inside the existing `describe("KvTileOverlayEditor — render", …)` block, and add `OVERLAY_CONTROL` to the file's imports from `./overlayControlStyle`:

```ts
  it("gives overlay controls a deliberate size and pushes them off the box", async () => {
    const { canvas } = await mountEditor({ overlays: [ov("s", "shape")] });
    const rect = canvas.getObjects().find((o) => o instanceof fabric.Rect) as
      | fabric.Rect
      | undefined;
    expect(rect).toBeTruthy();
    expect(rect!.cornerSize).toBe(OVERLAY_CONTROL.cornerSize);
    expect(rect!.touchCornerSize).toBe(OVERLAY_CONTROL.touchCornerSize);
    // Non-zero padding is the whole point: at padding 0 the corner handles
    // sit ON a small overlay's own corners and cover the box they belong to.
    expect(rect!.padding).toBe(OVERLAY_CONTROL.padding);
    expect(OVERLAY_CONTROL.padding).toBeGreaterThan(0);
  });
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/KvTileOverlayEditor.test.tsx`
Expected: FAIL — cannot resolve `./overlayControlStyle`.

- [ ] **Step 4: Create the constants module**

Create `src/components/studio/kv-generator/overlayControlStyle.ts`:

```ts
/**
 * Fabric control geometry for an editable overlay on a Resize tile.
 *
 * Until this existed nothing in kv-generator set `cornerSize`,
 * `touchCornerSize` or `borderScaleFactor` anywhere, so controls used
 * fabric's defaults. Those defaults do NOT shrink with the tile — they are a
 * fixed size in screen px — so the failure on a small tile was never handle
 * SIZE. It was occlusion: on a tile rendered ~200px wide an overlay taking
 * 20% of the frame is ~40px, and four corner handles sitting on its corners
 * cover most of it. Enlarging the handles makes that worse, which is why the
 * load-bearing field here is `padding`, not `cornerSize`.
 *
 * `padding` moves the border and the controls OUTWARD from the object's
 * bounding box, leaving the box interior a clean drag/select target. It does
 * not touch `width`, `scaleX`, `left` or `top`, which is what keeps
 * KvTileOverlayEditor's commit math (raw `width * scaleX`, minus the apron)
 * unaffected — see the drag/transform commit tests guarding exactly that.
 */
export const OVERLAY_CONTROL = {
  /** Fabric's own measured default, pinned rather than inherited.
   *  Deliberately NOT shrunk: the goal this task serves is that handles stay
   *  a USABLE click target on a small tile, and with `padding` below they no
   *  longer sit on the box, so there is no crowding left to solve by making
   *  them smaller. On a 40x40 overlay the padded box is 52x52 and four 13px
   *  handles leave a 39px gap — they cannot collide. Pinning the value guards
   *  against a future fabric default drifting under us. */
  cornerSize: 13,
  /** Fabric's measured default, pinned for the same reason. This one is an
   *  INVISIBLE hit-box used instead of `cornerSize` when the gesture comes
   *  from touch, so shrinking it could only ever cost touch area and buy
   *  nothing back. */
  touchCornerSize: 24,
  /** Screen px the border/controls stand off the box. The ONLY field here
   *  that departs from fabric's default (0), and the one doing the work. */
  padding: 6,
} as const;
```

Measure fabric's defaults in Step 1 and confirm they are still `cornerSize: 13`, `touchCornerSize: 24`, `padding: 0`. If a measurement disagrees with the numbers above, the measurement wins for the two pinned fields — report the discrepancy rather than silently keeping these.

- [ ] **Step 5: Apply it where every built object gets its common config**

In `src/components/studio/kv-generator/KvTileOverlayEditor.tsx`, add the import:

```ts
import { OVERLAY_CONTROL } from "./overlayControlStyle";
```

Then extend the single existing `obj.set` that already configures every built object (currently at `:1854`):

```ts
        obj.set({
          selectable,
          evented: selectable,
          noScaleCache: true,
          cornerSize: OVERLAY_CONTROL.cornerSize,
          touchCornerSize: OVERLAY_CONTROL.touchCornerSize,
          padding: OVERLAY_CONTROL.padding,
        });
```

Set it here and **not** in `fabricExport.ts`'s `buildTextObject` / `buildShapeObject` / `buildImageObjectFromElement`: those builders are shared with the export renderers, which draw no controls, and adding editor-only concerns there is how the four overlay renderers drift apart.

- [ ] **Step 6: Run the test to verify it passes, plus the commit-geometry guards**

```bash
cd web
bun test src/components/studio/kv-generator/KvTileOverlayEditor.test.tsx
```

Expected: PASS, including the pre-existing `commits a drag end via onChange with normalized x/y` and `commits a transform end via onChange with normalized w/h/rotation`. Those two are the regression guard for this task — if either moves, `padding` is leaking into committed geometry and the value must not ship.

Then the sibling suites, which mount the same editor:

```bash
bun test src/components/studio/kv-generator/KvTileOverlayEditor.boxes.test.tsx src/components/studio/kv-generator/KvTileOverlayEditor.shape.test.tsx src/components/studio/kv-generator/KvTileOverlayEditor.analytics.test.tsx
```

- [ ] **Step 7: Runtime check (manual)**

On a tile rendered small, select an overlay occupying roughly a fifth of the frame. Verify the four corner handles sit outside its edges, the interior is draggable without grabbing a handle, and a resize drag lands where released.

- [ ] **Step 8: Commit**

```bash
git add web/src/components/studio/kv-generator/overlayControlStyle.ts web/src/components/studio/kv-generator/KvTileOverlayEditor.tsx web/src/components/studio/kv-generator/KvTileOverlayEditor.test.tsx
git commit -m "fix(web): stand Resize overlay controls off the box they belong to"
```

---

### Task 4: Fit-camera helper (pure)

**Files:**
- Modify: `src/components/studio/kv-generator/focusCamera.ts`
- Test: `src/components/studio/kv-generator/focusCamera.test.ts` (create if absent; if present, append the new describe block)

**Interfaces:**
- Consumes: existing `FocusCamera` and `FocusRect` types from the same module.
- Produces: `fitRectInView(args: { rect: FocusRect; viewport: { width: number; height: number }; margin?: number; minScale?: number; maxScale?: number }): FocusCamera | null`.

- [ ] **Step 1: Check whether a test file already exists**

Run: `cd web && ls src/components/studio/kv-generator/focusCamera.test.ts`

If it exists, append the block below to it and keep its existing imports. If not, create it with the imports shown.

- [ ] **Step 2: Write the failing test**

```ts
import { describe, expect, test } from "bun:test";
import { fitRectInView } from "./focusCamera";

describe("fitRectInView", () => {
  const viewport = { width: 1000, height: 800 };

  test("scales a rect to fill the viewport minus the margin and centres it", () => {
    const cam = fitRectInView({
      rect: { x: 0, y: 0, width: 500, height: 400 },
      viewport,
      margin: 0.9,
    });
    expect(cam).not.toBeNull();
    // min(1000*0.9/500, 800*0.9/400) = min(1.8, 1.8) = 1.8
    expect(cam!.scale).toBeCloseTo(1.8, 5);
    // Centred: 1000/2 - (0 + 250) * 1.8 = 500 - 450 = 50
    expect(cam!.x).toBeCloseTo(50, 5);
    expect(cam!.y).toBeCloseTo(40, 5);
  });

  test("fits on the tighter axis, so a tall rect is bound by height", () => {
    const cam = fitRectInView({
      rect: { x: 0, y: 0, width: 400, height: 1600 },
      viewport,
      margin: 1,
    });
    // min(1000/400, 800/1600) = min(2.5, 0.5) = 0.5
    expect(cam!.scale).toBeCloseTo(0.5, 5);
  });

  test("respects the rect's own offset when centring", () => {
    const cam = fitRectInView({
      rect: { x: 200, y: 100, width: 500, height: 400 },
      viewport,
      margin: 0.9,
    });
    // 1000/2 - (200 + 250) * 1.8 = 500 - 810 = -310
    expect(cam!.x).toBeCloseTo(-310, 5);
  });

  test("clamps to the caller's scale bounds", () => {
    const tiny = fitRectInView({
      rect: { x: 0, y: 0, width: 10, height: 10 },
      viewport,
      margin: 1,
      maxScale: 3,
    });
    expect(tiny!.scale).toBe(3);

    const huge = fitRectInView({
      rect: { x: 0, y: 0, width: 100000, height: 100000 },
      viewport,
      margin: 1,
      minScale: 0.25,
    });
    expect(huge!.scale).toBe(0.25);
  });

  test("still centres the rect at a clamped scale", () => {
    const cam = fitRectInView({
      rect: { x: 0, y: 0, width: 10, height: 10 },
      viewport,
      margin: 1,
      maxScale: 3,
    });
    // 1000/2 - 5 * 3 = 485
    expect(cam!.x).toBeCloseTo(485, 5);
    expect(cam!.y).toBeCloseTo(385, 5);
  });

  test("returns null for a viewport or rect with no area", () => {
    const r = { x: 0, y: 0, width: 500, height: 400 };
    expect(fitRectInView({ rect: r, viewport: { width: 0, height: 800 } })).toBeNull();
    expect(fitRectInView({ rect: { ...r, width: 0 }, viewport })).toBeNull();
    expect(
      fitRectInView({ rect: { ...r, x: NaN }, viewport })
    ).toBeNull();
  });
});
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/focusCamera.test.ts`
Expected: FAIL — `fitRectInView` is not exported.

- [ ] **Step 4: Add the implementation**

Append to `src/components/studio/kv-generator/focusCamera.ts`:

```ts
/**
 * The camera that makes `rect` FILL the viewport.
 *
 * The third member of this family, and the only one that spends the reader's
 * zoom. `panRectIntoView` moves only when the target is off screen and
 * `centerRectInView` always centres — both preserve `camera.scale` on purpose,
 * because a zoom the reader chose is not ours to overwrite. Fit is the case
 * where changing the zoom IS the request ("show me this tile"), so it takes no
 * incoming camera at all: the result is derived entirely from the rect and the
 * viewport.
 *
 * `margin` is the fraction of the viewport the rect should occupy (0.9 leaves
 * a 10% surround). The fit is taken on the TIGHTER axis so the whole rect
 * lands inside, and the rect stays centred even when the scale is clamped —
 * clamping without re-centring is how a fit ends up framing empty space.
 */
export function fitRectInView({
  rect,
  viewport,
  margin = 0.9,
  minScale = 0,
  maxScale = Number.POSITIVE_INFINITY,
}: {
  rect: FocusRect;
  viewport: { width: number; height: number };
  margin?: number;
  minScale?: number;
  maxScale?: number;
}): FocusCamera | null {
  const { width: vw, height: vh } = viewport;
  if (vw <= 0 || vh <= 0) return null;
  if (!(rect.width > 0) || !(rect.height > 0)) return null;
  if (!Number.isFinite(rect.x) || !Number.isFinite(rect.y)) return null;

  const raw = Math.min((vw * margin) / rect.width, (vh * margin) / rect.height);
  const scale = Math.min(Math.max(raw, minScale), maxScale);

  return {
    scale,
    x: vw / 2 - (rect.x + rect.width / 2) * scale,
    y: vh / 2 - (rect.y + rect.height / 2) * scale,
  };
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/focusCamera.test.ts`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add web/src/components/studio/kv-generator/focusCamera.ts web/src/components/studio/kv-generator/focusCamera.test.ts
git commit -m "feat(web): add fitRectInView to the KV focus camera helpers"
```

---

### Task 5: fitTile + zoom controls on the Resize viewport

**Files:**
- Modify: `src/components/studio/kv-generator/KvResizeViewport.tsx` (type at `:55`, `centerTile` neighbourhood at `:221`, focus-api publish just below it)

**Interfaces:**
- Consumes: `fitRectInView` from Task 4.
- Produces: `KvResizeFocusApi` gains two members —
  `fitTile: (tileId: string) => number | null` (returns the resulting scale, or null when the tile is not rendered),
  `zoomBy: (factor: number) => number` (returns the resulting scale).
  Plus a new `onZoomScaleChange?: (scale: number) => void` prop on
  `KvResizeViewport`, so the live scale is reported UPWARD rather than held in
  local state.

> **Amended after Task 5's review.** Two changes from what this task
> originally said, both because the review found the surrounding codebase
> already solves this:
>
> 1. **There is no `resetZoom`.** The shared bottom-nav `ZoomPill` this
>    feature now reuses has four controls — out / % / in / fit — and no reset.
>    A reset with no consumer is dead code, and the original contract for it
>    ("back to 1:1 at the current pan") was itself defective: keeping `x`/`y`
>    while setting `scale: 1` pins the layout origin rather than anything
>    visible, which strands the viewport on blank space once you have fitted a
>    tile far down the list. Deleting it dissolves the defect. Adding a fifth
>    control to a pill other canvases share is a separate decision.
> 2. **The live scale is a prop callback, not local state.** `KvGeneratorLayout`
>    already owns a `zoomScale` state and already accepts `onZoomScaleChange`
>    from the Konva canvas; the pill reads it from there. Local state in
>    `KvResizeViewport` cannot reach a nav mounted three levels above it.

- [ ] **Step 1: Extend the published type**

Replace the type at `:55`:

```ts
export type KvResizeFocusApi = {
  /** Centre a tile, or a normalized point inside it. Returns false when the
   *  tile is not rendered (never generated, or filtered out). */
  centerTile: (tileId: string, at?: { x: number; y: number }) => boolean;
  /** Zoom the viewport so one tile fills it, then centre it. Returns the
   *  resulting scale, or null when the tile is not rendered. */
  fitTile: (tileId: string) => number | null;
  /** Multiply the current zoom, clamped to the viewport's own bounds.
   *  Returns the resulting scale. */
  zoomBy: (factor: number) => number;
  /** Back to 1:1 at the current pan. Returns 1. */
  resetZoom: () => number;
};
```

- [ ] **Step 2: Add the three callbacks next to `centerTile`**

`centerTile` measures in screen space because tiles are DOM-flow fabric stages with no shared world model. `fitTile` must therefore convert the measured rect back into layout space before handing it to the pure helper — the same `(screen - translate) / scale` inverse the ruler's `activeBoardRect` tick already uses in this file.

```ts
  /**
   * Zoom so ONE tile fills the viewport.
   *
   * Measured, not looked up, for the same reason `centerTile` is: there is no
   * world-coordinate model to query. The measured rect carries the CURRENT
   * zoom, so it is divided back out to layout space first — handing a
   * screen-space rect to `fitRectInView` would compound the existing scale
   * into the new one and overshoot on every second click.
   */
  const fitTile = useCallback(
    (tileId: string): number | null => {
      const container = containerRef.current;
      const el = document.querySelector<HTMLElement>(
        `[data-comment-tile="${CSS.escape(tileId)}"]`
      );
      if (!container || !el) return null;

      const containerRect = container.getBoundingClientRect();
      const elRect = el.getBoundingClientRect();
      if (containerRect.width <= 0 || containerRect.height <= 0) return null;

      const { x: camX, y: camY, scale } = tRef.current;
      if (!(scale > 0)) return null;

      const next = fitRectInView({
        rect: {
          x: (elRect.left - containerRect.left - camX) / scale,
          y: (elRect.top - containerRect.top - camY) / scale,
          width: elRect.width / scale,
          height: elRect.height / scale,
        },
        viewport: {
          width: containerRect.width,
          height: containerRect.height,
        },
        minScale: MIN_SCALE,
        maxScale: MAX_SCALE,
      });
      if (!next) return null;

      tRef.current = next;
      scheduleApply();
      return next.scale;
    },
    [scheduleApply]
  );

  /** Discrete zoom around the viewport CENTRE — the pill has no cursor
   *  position to anchor to, unlike the wheel handler. */
  const zoomBy = useCallback(
    (factor: number): number => {
      const container = containerRef.current;
      const oldScale = tRef.current.scale;
      const newScale = clamp(oldScale * factor, MIN_SCALE, MAX_SCALE);
      if (newScale === oldScale || !container) return oldScale;

      const rect = container.getBoundingClientRect();
      const cx = rect.width / 2;
      const cy = rect.height / 2;
      const wx = (cx - tRef.current.x) / oldScale;
      const wy = (cy - tRef.current.y) / oldScale;

      tRef.current = {
        scale: newScale,
        x: cx - wx * newScale,
        y: cy - wy * newScale,
      };
      scheduleApply();
      return newScale;
    },
    [scheduleApply]
  );

  const resetZoom = useCallback((): number => {
    tRef.current = { ...tRef.current, scale: 1 };
    scheduleApply();
    return 1;
  }, [scheduleApply]);
```

- [ ] **Step 3: Add the import and publish the new members**

Add `fitRectInView` to the existing import from `./focusCamera` if the file already imports from it; otherwise add:

```ts
import { fitRectInView } from "./focusCamera";
```

Then include the three new callbacks wherever the existing focus API object is built and passed to `onFocusApiChange`, and add them to that effect's dependency array alongside `centerTile`.

- [ ] **Step 4: Expose the live scale for the pill**

The pill needs a rendered value, and `tRef` deliberately never goes through React. `rulerT` state already mirrors the transform per RAF frame but only while `showRuler` is true, so it cannot be reused. Add a dedicated low-churn mirror updated inside `applyTransform`, guarded so it only re-renders when the scale actually changes:

```ts
  const [zoomScale, setZoomScale] = useState(1);
```

Inside `applyTransform`, after the `el.style.transform = …` line:

```ts
    setZoomScale((prev) => (Math.abs(prev - scale) < 0.0005 ? prev : scale));
```

Panning therefore triggers no re-render at all, and zooming triggers one per changed scale rather than one per frame.

- [ ] **Step 5: Update the KvResizeCanvas focus-api wrapper**

`KvResizeCanvas`'s `handleViewportFocusApi` (`:2151` region) currently wraps only `centerTile`. Forward the new members through unchanged — the surface's own half of "go to that tile" (making it active) applies to `fitTile` too:

```ts
  const handleViewportFocusApi = useCallback(
    (api: KvResizeFocusApi | null) => {
      onFocusApiChange?.(
        api
          ? {
              centerTile: (tileId, at) => {
                const moved = api.centerTile(tileId, at);
                if (moved) setActiveTileId(tileId);
                return moved;
              },
              fitTile: (tileId) => {
                const scale = api.fitTile(tileId);
                if (scale !== null) setActiveTileId(tileId);
                return scale;
              },
              zoomBy: api.zoomBy,
              resetZoom: api.resetZoom,
            }
          : null
      );
    },
    [onFocusApiChange]
  );
```

- [ ] **Step 6: Verify nothing else implements the widened type**

Run: `cd web && grep -rn "KvResizeFocusApi" src/ | grep -v ".test."`
Expected: only `KvResizeViewport.tsx` (definition + publish), `KvResizeCanvas.tsx` (wrapper), and `KvGeneratorLayout.tsx` (consumer). Every one of those must still compile — if `KvGeneratorLayout.tsx` constructs an object of this type anywhere rather than only consuming one, it needs the new members too.

- [ ] **Step 7: Run tests and build**

```bash
cd web
bun test src/components/studio/kv-generator/focusCamera.test.ts
node node_modules/next/dist/bin/next build
```

Expected: PASS and a successful build.

- [ ] **Step 8: Commit**

```bash
git add web/src/components/studio/kv-generator/KvResizeViewport.tsx web/src/components/studio/kv-generator/KvResizeCanvas.tsx
git commit -m "feat(web): add fitTile and discrete zoom to the Resize viewport"
```

---

### Task 6: Light up the existing zoom pill for Resize

> **This task was rewritten after Task 5's review.** It originally created a
> new `KvCanvasZoomPill` component and a new `resize_canvas_zoom_changed`
> analytics event. Both were duplicates of infrastructure that already
> exists, and the original approach also put the live scale in a component
> the pill cannot read from:
>
> - `KvCanvasBottomNav` already renders `ZoomPill` — out / % / in / fit —
>   driven by `zoom={{ available, scale, onZoomIn, onZoomOut, onFit }}`, and
>   the nav is already resize-aware (`platformPanelOpen` is documented as
>   "Replaces the layers pill in resize mode").
> - `ZoomPill` already fires `trackKvCanvasZoom({ action, canvas_mode })`,
>   and `KvCanvasMode` already includes `"resize"`. No new event is needed,
>   and a new one would split the funnel across canvases.
> - `KvGeneratorLayout` already owns the state and the handlers
>   (`zoomApiRef`, `zoomScale`, `zoomAvailable` at `:2095`,
>   `handleZoomApiChange` at `:2096`, `handleZoomScaleChange` at `:2100`),
>   and already threads `zoom={{…}}` to the nav at `:7833`. It is wired to
>   the Konva canvas only; `KvResizeCanvas` accepts neither prop, which is
>   the entire reason the pill is invisible on the Resize tab.
>
> Motion's separate `KvMotionCanvasZoomPill` is not a counter-precedent: its
> own comment says it exists because the transport bar already carries a
> competing zoom control. Resize has none.

**Files:**
- Modify: `src/components/studio/kv-generator/KvResizeViewport.tsx`
- Modify: `src/components/studio/kv-generator/KvResizeCanvas.tsx`
- Modify: `src/components/studio/kv-generator/KvGeneratorLayout.tsx`

**Interfaces:**
- Consumes from Task 5: `fitTile: (tileId: string) => number | null` and
  `zoomBy: (factor: number) => number` on `KvResizeFocusApi`.
- Consumes existing: `KvZoomApi` from `./KvKonvaCanvas` —
  `{ zoomIn: () => void; zoomOut: () => void; fitAll: () => void }`.
- Produces: no new exports, no new component, no new analytics event.

- [ ] **Step 1: Report the live scale upward instead of holding it**

In `KvResizeViewport.tsx`, delete the local `zoomScale` state Task 5 added
and delete the `eslint-disable-next-line` that existed only because it had no
consumer. Replace both with a prop:

```ts
  /** Reports the live camera scale. Held in a ref and called from
   *  `applyTransform` under an epsilon guard, so panning reports nothing and
   *  a zoom reports once per changed scale. A PROP rather than local state
   *  because the readout lives in `KvCanvasBottomNav`, mounted as a floating
   *  sibling three levels above this component — React state does not travel
   *  sideways. `KvGeneratorLayout` already owns exactly this state for the
   *  Konva canvas; this joins that contract rather than starting a new one. */
  onZoomScaleChange?: (scale: number) => void;
```

Hold it in a ref so its identity can never churn `applyTransform`:

```ts
  const onZoomScaleChangeRef = useRef(onZoomScaleChange);
  onZoomScaleChangeRef.current = onZoomScaleChange;
  const lastReportedScaleRef = useRef(1);
```

Then, inside `applyTransform`, where the deleted `setZoomScale` call was:

```ts
    if (Math.abs(lastReportedScaleRef.current - scale) >= 0.0005) {
      lastReportedScaleRef.current = scale;
      onZoomScaleChangeRef.current?.(scale);
    }
```

The epsilon guard moves from React's bail-out to an explicit ref compare —
same effect, and now with zero renders in this component for either pan or
zoom.

- [ ] **Step 2: Register a `KvZoomApi` from `KvResizeCanvas`**

`KvResizeCanvas` already wraps the viewport's focus API in
`handleViewportFocusApi`. Stash the wrapped api in a ref there, and publish a
`KvZoomApi` built from it. Add two props:

```ts
  onZoomApiChange?: (api: KvZoomApi | null) => void;
  onZoomScaleChange?: (scale: number) => void;
```

```ts
  const resizeFocusApiRef = useRef<KvResizeFocusApi | null>(null);
```

Inside `handleViewportFocusApi`, alongside the existing `onFocusApiChange`
call:

```ts
      resizeFocusApiRef.current = api;
      onZoomApiChange?.(
        api
          ? {
              zoomIn: () => void api.zoomBy(1.25),
              zoomOut: () => void api.zoomBy(1 / 1.25),
              // `fitAll` is the shared pill's name for its fourth control. On
              // the Konva canvas that means every board; on a Resize tile list
              // the useful meaning is the tile you are working on, which is
              // what this whole feature exists to make editable. No active
              // tile is a no-op rather than a guess.
              fitAll: () => {
                const id = activeTileIdRef.current;
                if (id) void api.fitTile(id);
              },
            }
          : null
      );
```

`activeTileId` must be read through a ref here, not captured: this callback
is registered once and `activeTileId` changes on every tile click. Add
`const activeTileIdRef = useRef(activeTileId); activeTileIdRef.current = activeTileId;`
next to the existing state.

Forward the scale straight through to the viewport:
`onZoomScaleChange={onZoomScaleChange}`.

- [ ] **Step 3: Wire it in `KvGeneratorLayout`**

Pass the two handlers the layout already has to `<KvResizeCanvas>` (around
`:6792`), exactly as they are already passed to the Konva canvas:

```tsx
              onZoomApiChange={handleZoomApiChange}
              onZoomScaleChange={handleZoomScaleChange}
```

`handleZoomApiChange` does `setZoomAvailable(!!api)`, so the pill becomes
visible on the Resize tab the moment the viewport registers, with no change
to `KvCanvasBottomNav` or `ZoomPill` at all.

**One hazard to check, not assume.** Both canvases register into the same
`zoomApiRef`. If the outgoing canvas's cleanup runs AFTER the incoming
canvas registers when switching modes, it will publish `null` last and blank
a live API. Switch Resize → Craft → Resize and confirm the pill keeps
working in both. If it does not, report it rather than papering over it with
a mode check — the ordering is the bug, and where it gets fixed is a
decision.

- [ ] **Step 4: Collapse the import an earlier task left multi-line**

Prettier would fold this, and it is the one new formatting violation this
plan introduced (the file carries ~271 lines of pre-existing prettier drift
which is NOT yours to touch):

```ts
import { maxNativeTileWidth, tileDisplayWidth } from "./resizeTileScale";
```

- [ ] **Step 5: Run tests and build**

```bash
cd web
bun test src/components/studio/kv-generator/resizeTileScale.test.ts src/components/studio/kv-generator/focusCamera.test.ts
bun test src/components/studio/kv-generator/KvResizeResultRow.test.tsx
node node_modules/next/dist/bin/next build
```

Expected: `resizeTileScale` 12 pass, `focusCamera` 25 pass,
`KvResizeResultRow` 19 pass / 1 fail (the documented baseline red, unchanged),
build succeeds.

- [ ] **Step 6: Runtime check (manual, cannot be automated)**

1. On the Resize tab the zoom pill is visible in the bottom nav, aligned with
   the other pills, and reads 100% on load.
2. `−` / `+` change the percentage and zoom about the viewport centre.
3. Fit with a tile active frames that tile with a visible surround.
4. Fit with the master row active frames the master row.
5. Fit with nothing active does nothing — it must not jump or blank.
6. Panning does not change the percentage readout.
7. `ctrl`/`cmd`+wheel still zooms and the readout tracks it.
8. Switch Resize → Craft → Resize: the pill works in both, and never goes
   dead (this is the Step 3 hazard).
9. PostHog receives `kv_generator.canvas_zoom` with `canvas_mode: "resize"`
   and the right `action` for each of the three controls.

- [ ] **Step 7: Commit**

```bash
git add web/src/components/studio/kv-generator/KvResizeViewport.tsx web/src/components/studio/kv-generator/KvResizeCanvas.tsx web/src/components/studio/kv-generator/KvGeneratorLayout.tsx
git commit -m "feat(web): light up the shared zoom pill on the Resize canvas"
```

---

## Follow-ups (not in this plan)

- Debounced analytics for the wheel/pinch zoom path.
- Consolidate `KvCanvasZoomPill` and `motion/KvMotionCanvasZoomPill` once the uncommitted Motion editor work lands.
- Retune `MIN_TILE_DISPLAY_WIDTH`, and decide the spec's open question 2 (one-axis vs two-axis floor) after seeing Task 2 on screen.
- Re-check apron overhang on a floored tile holding layers outside the frame (spec open question 3).
