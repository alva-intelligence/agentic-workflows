# KV Resize Legible Tile Scale Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Small Resize tiles render at an editable size regardless of their ratio to the largest tile, their overlay handles stop covering the box they belong to, and one tile can be zoomed to fill the viewport.

**Architecture:** Three independent changes to the live per-tile Resize surface. (1) A pure display-width policy module that floors the existing shared scale, capped so it never asks for more than a tile's native width. (2) Explicit fabric control sizing on overlay objects so handles sit outside the box. (3) A pure fit-camera helper plus a `fitTile` on the existing pan/zoom viewport, surfaced through a zoom pill. Nothing changes overlay data, the apron model, or the shared canvas layout.

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
  cornerSize: 10,
  /** Larger hit slop for coarse pointers; fabric uses this instead of
   *  `cornerSize` when the gesture comes from touch. */
  touchCornerSize: 20,
  /** Screen px the border/controls stand off the box. */
  padding: 6,
} as const;
```

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
- Produces: `KvResizeFocusApi` gains three members —
  `fitTile: (tileId: string) => number | null` (returns the resulting scale, or null when the tile is not rendered),
  `zoomBy: (factor: number) => number` (returns the resulting scale),
  `resetZoom: () => number` (returns 1).

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

### Task 6: Zoom pill + analytics

**Files:**
- Create: `src/components/studio/kv-generator/KvCanvasZoomPill.tsx`
- Modify: `src/components/studio/kv-generator/KvResizeViewport.tsx` (render the pill)
- Modify: `src/lib/analytics/kv-generator-events.ts`
- Test: `src/components/studio/kv-generator/KvCanvasZoomPill.test.tsx`

**Interfaces:**
- Consumes: `zoomScale`, `fitTile`, `zoomBy`, `resetZoom` from Task 5.
- Produces: `KvCanvasZoomPill` component; `trackKvResizeCanvasZoomChanged(p: KvResizeCanvasZoomChangedProps)` and `KvResizeCanvasZoomInput = "wheel" | "button" | "fit" | "reset"`.

- [ ] **Step 1: Write the failing component test**

Create `src/components/studio/kv-generator/KvCanvasZoomPill.test.tsx`:

```tsx
import { describe, expect, it, mock } from "bun:test";
import { render, within } from "@testing-library/react";
import { KvCanvasZoomPill } from "./KvCanvasZoomPill";

const noop = () => {};

describe("KvCanvasZoomPill", () => {
  it("renders the scale as a rounded percentage", () => {
    render(
      <KvCanvasZoomPill
        scale={1.234}
        onZoomIn={noop}
        onZoomOut={noop}
        onFit={noop}
        onReset={noop}
      />
    );
    expect(within(document.body).getByText("123%")).toBeTruthy();
  });

  it("calls each handler from its own control", () => {
    const onZoomIn = mock(noop);
    const onZoomOut = mock(noop);
    const onFit = mock(noop);
    const onReset = mock(noop);
    render(
      <KvCanvasZoomPill
        scale={1}
        onZoomIn={onZoomIn}
        onZoomOut={onZoomOut}
        onFit={onFit}
        onReset={onReset}
      />
    );
    const body = within(document.body);
    body.getByLabelText("Zoom in").click();
    body.getByLabelText("Zoom out").click();
    body.getByLabelText("Fit active tile to view").click();
    body.getByLabelText("Reset zoom to 100%").click();
    expect(onZoomIn).toHaveBeenCalledTimes(1);
    expect(onZoomOut).toHaveBeenCalledTimes(1);
    expect(onFit).toHaveBeenCalledTimes(1);
    expect(onReset).toHaveBeenCalledTimes(1);
  });
});
```

Use `within(document.body)` rather than the bare `screen` export — `screen` is broken under this repo's bun test setup and a single use of it fails every component test in the run.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/KvCanvasZoomPill.test.tsx`
Expected: FAIL — cannot resolve `./KvCanvasZoomPill`.

- [ ] **Step 3: Create the component**

Create `src/components/studio/kv-generator/KvCanvasZoomPill.tsx`:

```tsx
"use client";

import { ArrowsClockwise, CornersOut, Minus, Plus } from "@phosphor-icons/react";

import { Button } from "@/components/frndos/v2";

export type KvCanvasZoomPillProps = {
  scale: number;
  onZoomIn: () => void;
  onZoomOut: () => void;
  onFit: () => void;
  onReset: () => void;
  className?: string;
};

/**
 * Floating zoom control for a KV canvas viewport.
 *
 * Deliberately a near-twin of `motion/KvMotionCanvasZoomPill` rather than a
 * shared component today: `motion/KvMotionEditor.tsx` has uncommitted work in
 * the tree, and switching it over would collide with that. Consolidating the
 * two is a follow-up once that work lands — not a reason to leave Resize
 * without a control.
 */
export function KvCanvasZoomPill({
  scale,
  onZoomIn,
  onZoomOut,
  onFit,
  onReset,
  className,
}: KvCanvasZoomPillProps) {
  return (
    <div
      className={`frndos-float-panel pointer-events-auto flex items-center gap-1 rounded-full px-1.5 py-1 shadow-lg backdrop-blur-[16px] ${
        className ?? "absolute bottom-3 right-3"
      }`}
      // The pill is a CHILD of the element the viewport spreads its pan
      // handlers onto, so a press here would otherwise bubble to
      // `onPointerDown` and arm a pan — any movement before release then
      // drags the canvas out from under the click. The frndos/v2 Buttons have
      // no pointer handlers of their own, so stop the press here.
      onPointerDown={(e) => e.stopPropagation()}
    >
      <Button variant="icon" size="tiny" aria-label="Zoom out" onClick={onZoomOut}>
        <Minus size={14} />
      </Button>
      <span className="min-w-[3.25rem] text-center font-geist text-textXs text-text-inverse-subtlest">
        <span className="sr-only">Zoom level: </span>
        {Math.round(scale * 100)}%
      </span>
      <Button variant="icon" size="tiny" aria-label="Zoom in" onClick={onZoomIn}>
        <Plus size={14} />
      </Button>
      <Button
        variant="icon"
        size="tiny"
        aria-label="Fit active tile to view"
        onClick={onFit}
      >
        <CornersOut size={14} />
      </Button>
      <Button
        variant="icon"
        size="tiny"
        aria-label="Reset zoom to 100%"
        onClick={onReset}
      >
        <ArrowsClockwise size={14} />
      </Button>
    </div>
  );
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/KvCanvasZoomPill.test.tsx`
Expected: PASS, 2 tests.

- [ ] **Step 5: Add the analytics event**

Append to `src/lib/analytics/kv-generator-events.ts`, in section J alongside the other canvas-control events:

```ts
export type KvResizeCanvasZoomInput = "wheel" | "button" | "fit" | "reset";

export interface KvResizeCanvasZoomChangedProps {
  studio_file_id: string;
  /** "wheel" covers ctrl/meta+wheel and a trackpad pinch — indistinguishable
   *  at the DOM level (a pinch emits `wheel` + `ctrlKey`). "button" is the
   *  pill's +/- controls, "fit" its fit-to-tile control, "reset" its 100%
   *  control. */
  input: KvResizeCanvasZoomInput;
  /** Resulting scale, unrounded. The viewport's range is 0.25-3. */
  scale: number;
  /** The tile a "fit" was taken on; null for every other input. Tells a fit
   *  that framed a small tile from one that framed the master row. */
  tile_id: string | null;
}

/** The Resize viewport's pan/zoom camera. A SEPARATE event from
 *  `motion_canvas_zoom_changed` on purpose: same gesture, different surface,
 *  and merging them would make a spike in one read as a spike in the other.
 *  Fires once per discrete pill click; the wheel path must be debounced at
 *  the call site so a trackpad pinch does not emit per notch. */
export const trackKvResizeCanvasZoomChanged = (
  p: KvResizeCanvasZoomChangedProps
) => safeCapture("kv_generator.resize_canvas_zoom_changed", p);
```

- [ ] **Step 6: Render the pill inside the viewport**

Add `studioFileId: string` to `KvResizeViewport`'s props (pass `fileId` from `KvResizeCanvas`, which already has it in scope — the viewport has no way to know it otherwise), then render the pill as a **sibling of the transformed inner div, not a child of it** — inside, the pill would be zoomed along with the tiles.

Place it immediately after the inner div's closing tag, still inside the `overflow-hidden` container:

```tsx
      <KvCanvasZoomPill
        scale={zoomScale}
        onZoomIn={() => {
          const scale = zoomBy(1.25);
          trackKvResizeCanvasZoomChanged({
            studio_file_id: studioFileId,
            input: "button",
            scale,
            tile_id: null,
          });
        }}
        onZoomOut={() => {
          const scale = zoomBy(1 / 1.25);
          trackKvResizeCanvasZoomChanged({
            studio_file_id: studioFileId,
            input: "button",
            scale,
            tile_id: null,
          });
        }}
        onFit={() => {
          if (!activeTileId) return;
          const scale = fitTile(activeTileId);
          if (scale === null) return;
          trackKvResizeCanvasZoomChanged({
            studio_file_id: studioFileId,
            input: "fit",
            scale,
            tile_id: activeTileId,
          });
        }}
        onReset={() => {
          const scale = resetZoom();
          trackKvResizeCanvasZoomChanged({
            studio_file_id: studioFileId,
            input: "reset",
            scale,
            tile_id: null,
          });
        }}
      />
```

`onFit` returns early with no event when no tile is active or the tile is not rendered — a fit that did not happen must not appear in the funnel as one that did.

Add the import:

```ts
import { trackKvResizeCanvasZoomChanged } from "@/lib/analytics/kv-generator-events";
import { KvCanvasZoomPill } from "./KvCanvasZoomPill";
```

Leave the wheel path un-instrumented in this task: it needs debouncing to avoid one event per notch, and shipping it undebounced would flood the funnel. Add it in a follow-up with a settle timer, mirroring `useCanvasCamera`'s `ZOOM_SETTLE_MS`.

Leave the wheel path un-instrumented in this task: it needs debouncing to avoid one event per notch, and shipping it undebounced would flood the funnel. Add it in a follow-up with a settle timer, mirroring `useCanvasCamera`'s `ZOOM_SETTLE_MS`.

- [ ] **Step 7: Run tests and build**

```bash
cd web
bun test src/components/studio/kv-generator/KvCanvasZoomPill.test.tsx src/components/studio/kv-generator/resizeTileScale.test.ts src/components/studio/kv-generator/focusCamera.test.ts
node node_modules/next/dist/bin/next build
```

- [ ] **Step 8: Runtime check (manual)**

1. The pill reads 100% on load and does not move or scale while panning.
2. `+` / `−` change the percentage and zoom about the viewport centre.
3. Fit with a small tile active frames that tile with a visible surround; the percentage matches what the pill reports.
4. Fit on the master row frames the master row.
5. Reset returns to 100% without moving the pan.
6. A press on the pill never drags the canvas.
7. `ctrl`/`cmd`+wheel still zooms and the pill's percentage tracks it.
8. In PostHog, `kv_generator.resize_canvas_zoom_changed` arrives once per click with the right `input` and a `tile_id` only for fit.

- [ ] **Step 9: Commit**

```bash
git add web/src/components/studio/kv-generator/KvCanvasZoomPill.tsx web/src/components/studio/kv-generator/KvCanvasZoomPill.test.tsx web/src/components/studio/kv-generator/KvResizeViewport.tsx web/src/components/studio/kv-generator/KvResizeCanvas.tsx web/src/lib/analytics/kv-generator-events.ts
git commit -m "feat(web): surface Resize canvas zoom with a fit-to-tile pill"
```

---

## Follow-ups (not in this plan)

- Debounced analytics for the wheel/pinch zoom path.
- Consolidate `KvCanvasZoomPill` and `motion/KvMotionCanvasZoomPill` once the uncommitted Motion editor work lands.
- Retune `MIN_TILE_DISPLAY_WIDTH`, and decide the spec's open question 2 (one-axis vs two-axis floor) after seeing Task 2 on screen.
- Re-check apron overhang on a floored tile holding layers outside the frame (spec open question 3).
