# KV Resize Unified Canvas — M2c-b1 (Frame Tool: marquee, chrome, prompt) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the unified Resize canvas a working frame tool — draw a region, name it, stage it — without object detection, which is M2c-b2.

**Architecture:** The frame tool ("region edit") on the per-tile path is ~700 lines in `KvTileOverlayEditor.tsx`: a marquee gesture, committed-box chrome, an automatic object-detection pass with candidate chips and grouping, a prompt popover, and a keyboard ladder. This slice ports the half that does not involve detection. The gesture becomes world→board like every other tool on this surface (`resizeToolGesture.ts`), and the chrome — which is written entirely in FRAME display pixels — is extracted **verbatim** into a standalone component that the unified canvas renders once per board inside a wrapper positioned at that board's viewport rect. That wrapper is the only new coordinate math; the chrome itself never learns the canvas has a camera.

**Tech Stack:** Next.js, React, TypeScript, Fabric v7, `bun test`.

**Spec:** `frnd/docs/prd/kv-resize-unified-canvas.md` (approved). Delivers the frame-tool half of FR-9.

**Base branch:** `feature/daffa/vc-kv-resize-unified-canvas` — one branch carrying M1 + M2a + M2b + M2c-a (56 commits over develop, UNPUSHED). **No browser pass has been done on any of them.**

---

## Findings that shaped this plan — read before Task 1

Four things were established by reading the code, and each one contradicts something a reader would otherwise assume.

**1. `boxPromptUi.tsx` needs NO modification, and the M2c-a plan was wrong about that.** That plan split the frame tool into its own slice because it "is the one piece that touches `boxPromptUi.tsx`" — imported by `KvFabricCanvas.tsx`, which serves Craft in production (PRD risk R-1). But `boxPromptUi.tsx`'s own module doc says: "Everything here is pure DOM and coordinate-system agnostic: callers hand in already-projected screen/frame coordinates." `CandidateChips` and `BoxPromptPopover` both take `left`/`top`/`maxLeft`/`maxTop` in caller-projected pixels. The frame tool IMPORTS it; it does not change it. **This slice's Craft blast radius is therefore zero, the same as M2c-a's.** If you find yourself needing to edit `boxPromptUi.tsx`, STOP and escalate — that reopens R-1 and needs review against Craft's own frame-tool flow.

**2. Here, clamping is CORRECT.** This milestone's blanket "never clamp coordinates" rule is about OVERLAYS, whose whole point is that they may hang outside a frame. A frame-tool box is not an overlay — it is an **inpaint mask** on that tile's image, and a mask outside the image means nothing. `marqueeToBox` in `tileMarquee.ts` already clamps to 0..1, and this slice reuses it unchanged for exactly that reason. Do not "fix" the clamp. Do not apply `resizeToolGesture`'s no-clamp reasoning here.

**3. The frame tool is TILES ONLY, and must stay that way.** `KvResizeOriginalRow` passes none of `boxes`/`onBoxesChange`/`activeBoxId`/`onDetectRegion` — verified by grep, zero matches. That is deliberate: master region edit shipped and was pulled the same day, because it creates a NEW generation while the Resize grid lists tiles by `parent_generation_id = <viewed generation>`, so every tile vanished from the screen. See the track file's "Open trap — master-row region edit (U1e, still pulled)". **A frame drawn on the master board must be impossible in this slice.** Re-enabling it requires the propagation decision first, which is not this plan's business.

**4. Object detection IS live on tiles — it is just not wired from `KvResizeCanvas`.** `KvResizeResultRow.tsx:369` supplies `onDetectRegion` itself, calling `detectTileObjects(fileId, row.id, region, hint)`. A grep of `KvResizeCanvas.tsx` alone returns nothing and is misleading. Detection, candidate chips, `__obj` group ids, hover preview and free-text search are all **out of scope for b1** and land in b2. Everything b1 builds must leave room for them rather than assuming they do not exist — see each task's "b2 seam" note.

---

## Global Constraints

Every task's requirements implicitly include this section.

- **Test runner is `bun test`, run from `web/`.** NOT `bunx vitest`, and NOT from inside the component directory — `bunfig.toml` sets `root = "src"` and the jsdom preload, so a run started elsewhere fails with `ReferenceError: document is not defined`. Pure `.ts` suites import from `"bun:test"`; component `.tsx` suites import from `"vitest"`.
- **Never modify these — imported by the production Craft canvas (`KvFabricCanvas.tsx`):** `fabricExport.ts`, `ghostOverlay.ts`, `overlayGeometry.ts`, `overlayMutations.ts`, `overlayAspect.ts`, `overlaySelection.ts`, `overlayAlign.ts`, `overlayClipboard.ts`, **`boxPromptUi.tsx`**, `useTileOverlayHistory.ts`, `focusCamera.ts`. Import freely; edit none.
- **Never modify the per-tile path:** `KvTileOverlayEditor.tsx`, `KvResizeTileStage.tsx`, `KvResizeViewport.tsx`, `resizeApron.ts`, `KvResizeResultRow.tsx`, `KvResizeOriginalRow.tsx`. Read them for patterns; edit none. Duplication is the intended cost — `KvTileOverlayEditor.tsx` is deleted wholesale by TASK-27, and `objectIdOfBox` is ALREADY duplicated between it and `KvFabricCanvas.tsx`, so this is the established precedent for this exact tool.
- **`tileMarquee.ts` may be imported but not modified.** It is shared with the per-tile path.
- **Board-strict routing.** A box drawn on a board belongs to that board and no other, and the board is resolved ONCE on pointer-down. This is the same rule M2c-a's shape tool follows, and the same mutant killed it there: resolving the board on pointer-UP passes any test whose drag ends in empty space.
- **The master board can never carry a frame box** (finding 3).
- **Flag-off behaviour must be byte-identical.** Every line added to `KvResizeCanvas.tsx` goes inside the existing `unifiedCanvasEnabled ?` branch.
- **No new type errors in touched files; eslint clean.** The touched-file tsc baseline is currently **5 errors**, all pre-existing `as const` readonly-tuple sites in `KvResizeUnifiedCanvas.test.tsx` from M2b. Measure against 5, not 0.
- **Never write a raw control character into source** — use the escape form.
- **Do NOT use `git stash`** for baseline comparison. Copy files aside with `cp` and restore with `cp`. This repo has a documented incident where stash/pop corrupted files with conflict markers.
- **Every new test must be MUTATION-PROVEN.** Break the implementation, observe the test fail for the right reason, restore, re-run. Show both outputs.

### Test-infrastructure warning — NINE incidents in this milestone

bun's mock registry is process-global and load order is NOT alphabetical. Every one of these has actually happened here:
- A partial `mock.module("@/lib/featureFlags", …)` broke unrelated suites, and was simultaneously *load-bearing* for two others that had no flag control of their own.
- A divergent factory for a shared specifier flipped a production feature flag for unrelated suites.
- A suite passed in isolation while silently blanking another suite's tests.
- A test **filename** determined whether it collided.
- A NEW test file mocking `./KvResizeUnifiedCanvas` shifted load order and blanked `KvResizeUnifiedCanvas.test.tsx` entirely.

Therefore: **prefer extending an existing proven-safe suite over creating a new file.** `KvResizeUnifiedCanvas.test.tsx` and `KvResizeCanvas.unifiedUndoReveal.test.tsx` are both proven safe — M2c-a added twenty-one tests across the two of them with no fallout. A brand-new `.tsx` file that mocks nothing shared (Task 2's, which renders one presentational component and imports no flags) is acceptable; a new file that mocks `./KvResizeUnifiedCanvas`, `@/lib/featureFlags`, `posthog-js/react`, or `@/services/kv/api` is not. After passing in isolation, run the WHOLE directory and confirm the current verified baseline: **1083 pass / 13 fail / 2 errors**.

### Fixture discipline — ELEVEN incidents

Five of these were caught in M2c-a alone, by mutation testing, after the tests were already green:
- an axis-aligned fixture with `x == y` and `width == height`, which a transposed implementation passed clean;
- a no-clamp fixture that only pushed `x + width` past 1 while every INDIVIDUAL value stayed inside 0..1 — exactly what a per-value clamp operates on, so a clamped mutant passed;
- a board-strict fixture whose drag ended in EMPTY space, where resolving the board on pointer-up falls back to the right answer anyway;
- every canvas test pinned at 1x zoom, where a world-px gate and a screen-px gate are indistinguishable;
- and one mutation that was a no-op as written, so it proved nothing.

Choose fixtures that CAN expose what you claim to pin: **multi-board** where board identity matters, **asymmetric on every axis** where geometry matters, **non-1x camera** where screen-vs-world matters, and an endpoint where a WRONG answer is actually available.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `resizeFrameGesture.ts` (new) | Pure: a world-space drag on a board → a clamped `KvBoundingBox`; and a board's world rect → its viewport-pixel rect | 1 |
| `resizeFrameGesture.test.ts` (new) | Unit tests for both | 1 |
| `KvFrameBoxLayer.tsx` (new) | The committed-box chrome + live draft, in FRAME display pixels — camera-free, extracted from `KvTileOverlayEditor`'s render | 2 |
| `KvFrameBoxLayer.test.tsx` (new) | Component tests for the chrome | 2 |
| `KvResizeUnifiedCanvas.tsx` | Arms the frame tool through the M2c-a seam; marquee drag; per-board `KvFrameBoxLayer`; emits `onBoxesChange` | 3 |
| `KvResizeUnifiedCanvas.tsx` | `BoxPromptPopover` + save/delete + the Escape ladder | 4 |
| `KvResizeCanvas.tsx` | Feeds per-board boxes and routes `onBoxesChange`, tiles only | 5 |

---

## Task 1: `resizeFrameGesture.ts` — world drag → box, and board → viewport rect

**Why:** the frame tool needs two mappings nothing else provides. The first turns a drag into a mask box; the second is how every later task positions frame-coordinate chrome on a canvas that has a camera. Both are pure, so both are testable without a canvas.

**Files:**
- Create: `src/components/studio/kv-generator/resizeFrameGesture.ts`
- Create: `src/components/studio/kv-generator/resizeFrameGesture.test.ts`

**Interfaces:**
- Consumes: `ResizeBoard`, `resizeBoardRect` from `resizeBoardLayout.ts`; `marqueeToBox`, `MIN_BOX_PX`, type `MarqueeDraft` from `tileMarquee.ts` (import only, never modify); `KvBoundingBox` from `@/types/studio`
- Produces:
  - `frameBoxFromWorldDrag(input: { board: ResizeBoard; start: WorldPoint; end: WorldPoint; screenScale: number; id: string }): KvBoundingBox | null`
  - `boardViewportRect(board: ResizeBoard, camera: { scale: number; x: number; y: number }): { left: number; top: number; width: number; height: number }`
  - re-export nothing; `WorldPoint` is imported from `./resizeToolGesture`

**The delegation that makes this small.** `marqueeToBox(draft, displayWidth, displayHeight, id)` normalizes by DIVIDING the drag by the display size, and gates on `MIN_BOX_PX` in whatever units it was handed. So if you hand it the drag expressed in the board's **on-screen** pixels and the board's **on-screen** size, you get both correct behaviours at once for free: the 8px gate is measured in real pointer travel (the same screen-px reasoning `shapeRectFromDrag` documents), and the normalized result is identical at any zoom because a ratio is scale-invariant. Do NOT hand it world px — the gate would then be impossible to clear zoomed out and trivial zoomed in. Do NOT reimplement the clamp or the gate; delegate.

- [ ] **Step 1: Write the failing tests.**

```ts
import { describe, expect, test } from "bun:test";

import type { ResizeBoard } from "./resizeBoardLayout";
import { boardViewportRect, frameBoxFromWorldDrag } from "./resizeFrameGesture";

/** NON-SQUARE and offset from the world origin on BOTH axes, so an
 *  implementation that forgot the board origin, or divided both axes by the
 *  same extent, cannot pass. */
function makeBoard(overrides: Partial<ResizeBoard> = {}): ResizeBoard {
  return {
    id: "b1",
    center: { x: 1000, y: 500 },
    nativeWidth: 800,
    nativeHeight: 400,
    width: 800,
    height: 400,
    imageUrl: null,
    label: "b1",
    isMaster: false,
    row: null,
    ...overrides,
  } as ResizeBoard;
}

// Frame rect is x 600..1400, y 300..700.
const board = makeBoard();

describe("frameBoxFromWorldDrag", () => {
  test("a drag becomes the normalized box it swept", () => {
    // Every component DIFFERENT: x 0.125, y 0.75, w 0.5, h 0.125 — a
    // transposed implementation cannot pass.
    const box = frameBoxFromWorldDrag({
      board,
      start: { x: 700, y: 600 },
      end: { x: 1100, y: 650 },
      screenScale: 1,
      id: "box-1",
    });
    expect(box).not.toBeNull();
    expect(box!.id).toBe("box-1");
    expect(box!.x).toBeCloseTo(0.125, 10);
    expect(box!.y).toBeCloseTo(0.75, 10);
    expect(box!.width).toBeCloseTo(0.5, 10);
    expect(box!.height).toBeCloseTo(0.125, 10);
  });

  test("a drag made bottom-right → top-left yields the same box", () => {
    const forward = frameBoxFromWorldDrag({
      board,
      start: { x: 700, y: 600 },
      end: { x: 1100, y: 650 },
      screenScale: 1,
      id: "b",
    });
    const backward = frameBoxFromWorldDrag({
      board,
      start: { x: 1100, y: 650 },
      end: { x: 700, y: 600 },
      screenScale: 1,
      id: "b",
    });
    expect(backward).toEqual(forward);
  });

  test("a box IS clamped to the frame — it is an inpaint mask, not an overlay", () => {
    // Starts left of and above the frame, ends right of and below it. Each
    // INDIVIDUAL value must land inside 0..1: a fixture that only pushed
    // x+width past 1 cannot detect a per-value clamp (M2c-a incident).
    const box = frameBoxFromWorldDrag({
      board,
      start: { x: 400, y: 100 },
      end: { x: 1500, y: 900 },
      screenScale: 1,
      id: "b",
    });
    expect(box!.x).toBeCloseTo(0, 10);
    expect(box!.y).toBeCloseTo(0, 10);
    expect(box!.width).toBeCloseTo(1, 10);
    expect(box!.height).toBeCloseTo(1, 10);
  });

  test("a drag under the 8px screen gate yields null", () => {
    expect(
      frameBoxFromWorldDrag({
        board,
        start: { x: 1000, y: 500 },
        end: { x: 1005, y: 505 },
        screenScale: 1,
        id: "b",
      })
    ).toBeNull();
  });

  test("the gate is SCREEN px: the same world drag passes zoomed in and fails zoomed out", () => {
    const drag = { board, start: { x: 1000, y: 500 }, end: { x: 1005, y: 505 }, id: "b" };
    // 5 world px is 5 screen px at 1x — under the gate…
    expect(frameBoxFromWorldDrag({ ...drag, screenScale: 1 })).toBeNull();
    // …and 20 screen px at 4x, over it.
    expect(frameBoxFromWorldDrag({ ...drag, screenScale: 4 })).not.toBeNull();
  });

  test("the gate is per-AXIS: a thin drag is rejected even when it is long", () => {
    // marqueeToBox gates BOTH axes (unlike the shape tool's max(w,h)).
    expect(
      frameBoxFromWorldDrag({
        board,
        start: { x: 700, y: 500 },
        end: { x: 1100, y: 503 },
        screenScale: 1,
        id: "b",
      })
    ).toBeNull();
  });

  test("a degenerate board yields null rather than NaN", () => {
    expect(
      frameBoxFromWorldDrag({
        board: makeBoard({ width: 0, height: 0 }),
        start: { x: -50, y: -50 },
        end: { x: 50, y: 50 },
        screenScale: 1,
        id: "b",
      })
    ).toBeNull();
  });
});

describe("boardViewportRect", () => {
  test("projects a board's world rect through the camera", () => {
    const r = boardViewportRect(board, { scale: 0.5, x: 100, y: 20 });
    // world x 600 → 600*0.5 + 100 = 400 ; y 300 → 300*0.5 + 20 = 170
    expect(r.left).toBeCloseTo(400, 10);
    expect(r.top).toBeCloseTo(170, 10);
    expect(r.width).toBeCloseTo(400, 10);
    expect(r.height).toBeCloseTo(200, 10);
  });

  test("is identity-shaped at scale 1 with no translation", () => {
    const r = boardViewportRect(board, { scale: 1, x: 0, y: 0 });
    expect(r).toEqual({ left: 600, top: 300, width: 800, height: 400 });
  });
});
```

- [ ] **Step 2: Run them, confirm they fail** (module missing).

Run: `bun test src/components/studio/kv-generator/resizeFrameGesture.test.ts`
Expected: `SyntaxError: Export named 'frameBoxFromWorldDrag' not found`

- [ ] **Step 3: Implement.**

```ts
import type { KvBoundingBox } from "@/types/studio";

import { resizeBoardRect, type ResizeBoard } from "./resizeBoardLayout";
import type { WorldPoint } from "./resizeToolGesture";
import { marqueeToBox } from "./tileMarquee";

/**
 * A frame-tool drag in world space → the clamped, frame-normalized
 * `KvBoundingBox` it swept on `board`, or `null` when the drag never cleared
 * the minimum-size gate.
 *
 * CLAMPED, unlike everything else on this surface, and deliberately so: a
 * frame box is an INPAINT MASK on the board's image, not an overlay. A mask
 * outside the image means nothing, so `marqueeToBox`'s clamp is correct here.
 * Do not "fix" it by reasoning from `resizeToolGesture`'s no-clamp rule —
 * that rule is about overlays.
 *
 * Delegates wholesale to `marqueeToBox`, the same function the per-tile path
 * uses, by expressing the drag in the board's ON-SCREEN pixels: the gate is
 * then measured in real pointer travel, and the normalized result is
 * identical at any zoom because a ratio is scale-invariant. Handing it WORLD
 * px instead would make the gate impossible to clear zoomed out and trivial
 * zoomed in.
 */
export function frameBoxFromWorldDrag(input: {
  board: ResizeBoard;
  start: WorldPoint;
  end: WorldPoint;
  /** Camera scale — world px × this = screen px. */
  screenScale: number;
  id: string;
}): KvBoundingBox | null {
  const { board, start, end, screenScale, id } = input;
  const rect = resizeBoardRect(board);
  if (rect.width <= 0 || rect.height <= 0) return null;
  return marqueeToBox(
    {
      startX: (start.x - rect.x) * screenScale,
      startY: (start.y - rect.y) * screenScale,
      x: (end.x - rect.x) * screenScale,
      y: (end.y - rect.y) * screenScale,
    },
    rect.width * screenScale,
    rect.height * screenScale,
    id
  );
}

/**
 * A board's world rect projected into VIEWPORT (canvas-element) pixels.
 *
 * This is the whole of the coordinate math the frame-tool chrome needs: a
 * wrapper positioned at this rect turns every frame-relative pixel inside it
 * into the right place on screen, so `KvFrameBoxLayer` can stay camera-free
 * and reuse the per-tile chrome's coordinates verbatim.
 */
export function boardViewportRect(
  board: ResizeBoard,
  camera: { scale: number; x: number; y: number }
): { left: number; top: number; width: number; height: number } {
  const rect = resizeBoardRect(board);
  return {
    left: rect.x * camera.scale + camera.x,
    top: rect.y * camera.scale + camera.y,
    width: rect.width * camera.scale,
    height: rect.height * camera.scale,
  };
}
```

- [ ] **Step 4: Run tests; confirm they pass.**

- [ ] **Step 5: Mutation-prove.** Run each of these, confirm the named test fails, then restore. Copy the file aside with `cp` first — never `git stash`.
  1. Pass world px instead of screen px (drop every `* screenScale`) → "the gate is SCREEN px" must fail.
  2. Transpose the axes in the draft (`startX: start.y - rect.y`, …) → "a drag becomes the normalized box it swept" must fail.
  3. Drop the board origin (`startX: start.x * screenScale`) → the same test must fail.
  4. Remove the degenerate guard → "a degenerate board yields null" must fail.
  5. In `boardViewportRect`, add the translation before scaling (`(rect.x + camera.x) * camera.scale`) → "projects a board's world rect through the camera" must fail.

  If any mutant SURVIVES, the fixture is too weak — fix the fixture, do not weaken the mutant. Record what survived and why in the commit message.

- [ ] **Step 6: Commit** — `feat(web): pure frame-box geometry for the unified resize canvas`

**b2 seam:** nothing here changes for detection. `boardViewportRect` is what b2 will use to position `CandidateChips`.

---

## Task 2: `KvFrameBoxLayer` — the committed-box chrome, in frame coordinates

**Why:** the per-tile editor's box chrome is ~130 lines of JSX written entirely in FRAME display pixels — dashed rectangles, polygon outlines, label pills with an Unmark button, numbered markers. None of it knows about a camera. Extracting it as a standalone component means the unified canvas renders one per board inside a positioned wrapper and does no chrome math at all.

**Files:**
- Create: `src/components/studio/kv-generator/KvFrameBoxLayer.tsx`
- Create: `src/components/studio/kv-generator/KvFrameBoxLayer.test.tsx`

This new test file is acceptable under the test-infra rule because it mocks **nothing**: it renders one presentational component and imports no feature flags, no services, and not `./KvResizeUnifiedCanvas`.

**Interfaces:**
- Consumes: `KvBoundingBox`, `KvDetectedObject` from `@/types/studio`; `polygonToPoints`, `toSvgPoints` from `@/lib/studio/kv/polygonPoints` (import only — do not reimplement); `X` from `@phosphor-icons/react`
- Produces:

```ts
export function KvFrameBoxLayer(props: {
  boxes: KvBoundingBox[];
  /** Frame size in DISPLAY px — the wrapper's own size. */
  displayWidth: number;
  displayHeight: number;
  /** False ⇒ chrome renders but swallows no pointer events (a board that is
   *  not the drag target, or the tool disarmed). */
  interactive: boolean;
  onBoxClick: (boxId: string) => void;
  onUnmark: (boxId: string) => void;
  /** Live marquee, in the same frame display px. Null when not dragging. */
  draft: { startX: number; startY: number; x: number; y: number } | null;
}): JSX.Element | null;
```

- [ ] **Step 1: Read the source you are extracting.** `KvTileOverlayEditor.tsx` lines 1795–1975 — the `data-testid="tile-frame-layer"` div, the `boxes.map(...)` body, and the live-draft block that follows it. Copy the JSX and its comments; change only what the interface above requires.

- [ ] **Step 2: Write the failing tests.** Cover, with `within(document.body)` and never the bare `screen` export (see `[[lesson-web-rtl-screen-broken-under-bun]]`):
  - a hand-drawn box (no `polygon`, no `label`) renders one `data-testid="region-box"` positioned at `x * displayWidth` / `y * displayHeight` with the dashed border — use a NON-SQUARE frame (e.g. 800×400) and a box whose x, y, width and height are all different, so a transposed projection cannot pass;
  - a box WITH a `polygon` renders an SVG `<polygon>` and NO dashed border;
  - a box with a `label` renders the pill and an `Unmark <label>` button, and clicking it calls `onUnmark` with that box's id and NOT `onBoxClick`;
  - the numbered marker counts PARENTS only: given boxes `["a", "a__obj1", "b"]`, the markers read 1 and 2, and `a__obj1` renders none;
  - clicking a box calls `onBoxClick` with its id;
  - with `interactive: false`, clicking a box calls nothing;
  - the live draft renders a dashed preview at the drag rect and disappears when `draft` is null;
  - `boxes: []` and `draft: null` renders nothing at all.

- [ ] **Step 3: Run them, confirm they fail** (module missing).

- [ ] **Step 4: Implement**, pasting the JSX from Step 1 and rewiring the three callbacks. Two deliberate simplifications versus the source, both because detection is b2 — write BOTH as comments in the file so the next reader does not think they were forgotten:
  - the source suppresses a box's dashed border when `candidates?.boxId === box.id`; there are no candidate sets in b1, so the border depends only on `polygon`;
  - the source's click handler bails when `detectPromptRef.current?.boxId === box.id` or `candidatesRef.current?.boxId === box.id`; neither exists in b1, so the click always opens the prompt. **b2 must restore both guards** — without them a stray click in a gap between object outlines silently throws away a detection.

- [ ] **Step 5: Run tests; mutation-prove.** At minimum: transpose `left`/`top`; count ALL boxes for the marker instead of parents only; make `interactive` unconditionally true; drop the `polygon` branch. Each must break a named test.

- [ ] **Step 6: Commit** — `feat(web): extract the frame-tool box chrome as a camera-free layer`

**b2 seam:** this component gains `candidateBoxId?: string | null` and the two click guards; nothing else about it changes.

---

## Task 3: The frame tool on the unified canvas

**Why:** this is where the gesture, the chrome and the camera meet. The tool arms through the seam M2c-a already built, the drag runs in world space and resolves its board once, and each board's chrome renders inside a wrapper positioned by `boardViewportRect`.

**Files:**
- Modify: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.tsx`
- Test: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.test.tsx` (new sibling `describe`, appended — never restructure existing blocks)

**Interfaces:**
- Consumes: `frameBoxFromWorldDrag`, `boardViewportRect` (Task 1); `KvFrameBoxLayer` (Task 2); `boardAtWorldPoint` from `resizeToolGesture.ts`
- Produces:

```ts
  /** Boxes per board id. A board absent from this map has none. The master
   *  board is never a key — see the frame tool's tiles-only rule. */
  frameBoxes?: Record<string, KvBoundingBox[]>;
  /** The full next array for ONE board. Mirrors the per-tile editor's
   *  `onBoxesChange`, with the board id prepended for board-strict routing —
   *  the same shape `onPlaceShape` uses. */
  onBoxesChange?: (boardId: string, next: KvBoundingBox[]) => void;
  activeBoxId?: string | null;
  onActiveBoxIdChange?: (id: string | null) => void;
```

- [ ] **Step 1: Extend the arming gate.** In `effectiveTool`, add `"frame"` alongside `"shape"` and `"comment"`, armable only when `onBoxesChange` is present — the same affordance-lie gate the other two carry, and the same reason. **Delete the stale comment** on the `tool` prop that says `"frame"` is deliberately treated as `"cursor"` because it belongs to a later slice; that is no longer true and would mislead the next reader. Widen the prop union to include `"frame"`.

- [ ] **Step 2: Write the failing tests.** Append a `describe("KvResizeUnifiedCanvas — frame tool", …)`. Reuse M2c-a's proven harness from the shape-placement block: `pinCamera` (`setViewportTransform([1, 0, 0, 1, 320, 320])`), the `drag` helper firing `mouse:down`/`move`/`up` each in its own `act`, and `exportRow` for a real tile board. Cover:
  - a drag on a TILE board calls `onBoxesChange` once with that board's id and an array whose new box has the swept normalized geometry — asymmetric on every axis;
  - the array is the FULL next array: given `frameBoxes: { "tile-1": [existing] }`, the call carries `[existing, newBox]` in that order;
  - a drag that starts on a tile and ends **over the master board** still commits to the tile (board-strict — the endpoint must be somewhere a wrong answer is available, not empty space);
  - a drag under the gate calls nothing;
  - a press in the gap between boards calls nothing;
  - a drag on the MASTER board calls nothing at all — the tiles-only rule, pinned at the canvas as well as the host;
  - the camera does not pan during a frame drag (the armed-tool guard, same one the shape tool needed);
  - with `tool="cursor"` a drag calls nothing;
  - without `onBoxesChange` the canvas does not arm (`skipTargetFind === false`, `selection === true`);
  - committed boxes render: with `frameBoxes: { "tile-1": [box] }` a `region-box` appears, and at 0.5x zoom its wrapper is positioned at `boardViewportRect`'s answer — **run this one at a non-1x scale**, or it cannot tell a projected wrapper from an unprojected one.

- [ ] **Step 3: Run them, confirm they fail.**

- [ ] **Step 4: Implement.** Follow the shape tool's structure in the same file — it is the closest working example and was reviewed:
  - a `frameDragRef` holding `{ board, scene, viewport }`, resolved on `mouse:down` via `boardAtWorldPoint`, refusing `board.isMaster`;
  - `mouse:move` updating a `frameDraft` React state in viewport px for the live preview;
  - `mouse:up` calling `frameBoxFromWorldDrag(...)` with `screenScale: canvas.getZoom()` and, on a non-null box, `onBoxesChange(board.id, [...(frameBoxes?.[board.id] ?? []), box])` followed by `onActiveBoxIdChange?.(box.id)` — the per-tile fallback branch, since detection does not exist in b1;
  - the effect cleanup clearing both the ref and the draft, so a tool disarmed mid-drag leaves nothing stale;
  - **the armed-tool pan guard already covers this** — `armedToolRef.current !== "cursor"` returns early — but confirm it, because without it `skipTargetFind` makes `opt.target` permanently undefined and every frame drag would pan instead of draw;
  - rendering, for each board with boxes (or the board being dragged), a wrapper div at `boardViewportRect(board, camera)` containing `<KvFrameBoxLayer …/>`, with the draft converted into that board's frame px.

- [ ] **Step 5: Run tests; mutation-prove.** At minimum: resolve the board on `mouse:up`; drop the `isMaster` refusal; replace the full next array with `[box]` alone; drop the pan guard; pass `screenScale: 1`; skip the `boardViewportRect` projection and position the wrapper at the raw world rect.

- [ ] **Step 6: Commit** — `feat(web): draw frame-tool regions on the unified resize canvas`

**b2 seam:** `mouse:up` gains the `onDetectRegion` branch — set a `detectPrompt` instead of opening the prompt directly.

---

## Task 4: The prompt popover and the Escape ladder

**Why:** a drawn frame is useless until it carries a prompt. This is the popover, its save/delete semantics, and the keyboard ladder that steps back out of them.

**Files:**
- Modify: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.tsx`
- Test: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.test.tsx` (new sibling `describe`)

**Interfaces:**
- Consumes: `BoxPromptPopover` from `./boxPromptUi` — **import only; editing it reopens PRD risk R-1** (finding 1)
- Produces: no new props; drives `onBoxesChange` and `onActiveBoxIdChange` from Task 3

- [ ] **Step 1: Read the per-tile semantics** — `savePrompt` (`KvTileOverlayEditor.tsx:983`), `deleteBox` (`:1025`), and the keyboard effect (`:1287`). Note three things that are easy to miss:
  - `savePrompt` trims and caps at `REGION_BOX_PROMPT_MAX = 2000` (the value lives in `resizeSendTarget.ts:12`; the per-tile copy is module-private, so declare your own const with a comment pointing at both, exactly as `MIN_SHAPE_DRAG_SCREEN_PX` does). The cap exists because edit-region has no onError toast to explain a 422.
  - An empty prompt saves as `undefined`, not `""`.
  - `savePrompt` applies to the box AND its `__obj` group members. **In b1 there are no group members**, so the group set is always a single id — but write the group logic anyway rather than a single-box shortcut, and say why in a comment: b2 introduces the members, and a shortcut here would be a silent behaviour change to find later.

- [ ] **Step 2: Write the failing tests.** Cover:
  - with `activeBoxId` set, the popover renders (`data-testid="box-prompt-input"`), pre-filled with that box's existing prompt;
  - typing and pressing Enter calls `onBoxesChange` with that board's id and the box carrying the trimmed text, and calls `onActiveBoxIdChange(null)`;
  - saving an all-whitespace prompt stores `undefined`, not `""`;
  - a prompt longer than 2000 characters is cut to 2000;
  - Delete on the popover removes that box from the array and clears the active id;
  - Escape with a marquee in flight cancels the drag and leaves `boxes` untouched;
  - Escape with an active box closes the popover WITHOUT writing (`onBoxesChange` not called) — the ladder steps back, it never destroys;
  - Escape while focus is in the popover input does not run the ladder (the `typing` guard) — the input handles its own Escape.

- [ ] **Step 3: Run them, confirm they fail.**

- [ ] **Step 4: Implement.** The popover is CONTROLLED: `activeBoxId` is host-owned, `promptDraft` is local and re-seeded by an effect on `activeBoxId`, exactly as the per-tile editor does. Position it with `boardViewportRect` plus the box's frame offset, and pass `maxLeft` as `width - 320` so it cannot run off the canvas. The b1 ladder is a SUBSET of the per-tile one — abort drag → close active box → clear selection — because `listOpen`, `candidates` and `detectPrompt` do not exist yet; write the remaining rungs as a comment listing what b2 reinserts and where.

- [ ] **Step 5: Run tests; mutation-prove.** At minimum: drop the trim; store `""` instead of `undefined`; drop the 2000 cap; make Escape call `onBoxesChange`; drop the `typing` guard.

- [ ] **Step 6: Commit** — `feat(web): prompt and dismiss frame-tool regions on the unified resize canvas`

**b2 seam:** the ladder regains `listOpen`, `revertToCandidates` and `discardCandidateArea`; `cancelLabel`/`objectLabel`/`groupCount` on the popover start carrying real values.

---

## Task 5: Host wiring

**Why:** the host already owns the box store, the region-edit kill switch and the tile-arming side effects; this connects them, tiles only.

**Files:**
- Modify: `src/components/studio/kv-generator/KvResizeCanvas.tsx`
- Test: `src/components/studio/kv-generator/KvResizeCanvas.unifiedUndoReveal.test.tsx` (proven-safe harness — extend the existing `./KvResizeUnifiedCanvas` mock with new buttons, exactly as M2c-a Task 5 did; do NOT create a new file)

- [ ] **Step 1: Feed `frameBoxes`.** Build `Record<boardId, KvBoundingBox[]>` from the existing `boxesByExportId`, gated on `regionEditEnabled` (the `KV_RESIZE_REGION_EDIT` kill switch, fail-closed — see `KvResizeCanvas.tsx:333`). **Key it by EXPORT ID only.** The master board id (`"__master__"`) must never appear as a key: finding 3, and the U1e trap.

- [ ] **Step 2: Route `onBoxesChange`** through `resolveCommitTarget(unifiedBoards, boardId)`, exactly as `onPlaceShape` does. A `"master"` target returns early — it must never write. A tile target runs the SAME side effects the per-tile row does (`KvResizeCanvas.tsx:2032`): `setBoxesForExport(row.id, next)`, then `setActiveTileId(row.id)`, then `armRegenerate(row.id)` when it is not already armed. Reuse; do not reimplement. Pass `activeBoxId`/`setActiveBoxId` through, both gated on `regionEditEnabled`.

- [ ] **Step 3: Pass `tool` through unchanged.** It is already forwarded to the canvas; `"frame"` now reaches a real implementation instead of falling back to `"cursor"`.

- [ ] **Step 4: Write the host tests.** In the proven-safe harness, add mock buttons that call `onBoxesChange("row1", […])` and `onBoxesChange("__master__", […])` directly — board id supplied, not derived from a gesture, since the geometry is Task 3's job. Assert:
  - a box on a tile reaches `setBoxesForExport` for that row and arms regenerate for it;
  - a box on the master writes NOTHING;
  - with `regionEditEnabled` false, `onBoxesChange` is not passed at all (the kill switch holds on this surface too — the fail-closed contract the per-tile path relies on).

- [ ] **Step 5: Run tests; mutation-prove; confirm flag-off is byte-identical.** At minimum: route master writes to the tile path; drop the `regionEditEnabled` gate; drop `armRegenerate`.

- [ ] **Step 6: Commit** — `feat(web): wire the frame tool into the unified resize canvas host`

---

## Task 6: Track file

- [ ] **Step 1: Add the M2c-b1 session-log entry** to `web/docs/tracks/kv-resize-unified-canvas.track.md`, following the M2c-a entry's shape: what landed, what diverged from this plan and why, which mutants survived their first fixture, the verification numbers, and what b2 still owes.

- [ ] **Step 2: Correct the R-1 note.** The track and the M2c-a plan both say the frame tool is the piece that touches `boxPromptUi.tsx`. Finding 1 disproves that. Record the correction so the next reader does not re-derive it, and keep the "if you ever need to EDIT it, escalate" rule.

- [ ] **Step 3: Commit** — `docs(web): record M2c-b1 on the unified-canvas track`

---

## Self-Review Notes

- Order: **1 → 2 → 3 → 4 → 5 → 6.** Task 3 consumes 1 and 2; Task 4 consumes 3; Task 5 consumes 3 and 4.
- Tasks 3 and 4 both touch `KvResizeUnifiedCanvas.tsx` and its test file — run them sequentially, appending sibling `describe` blocks.
- **Out of scope, deliberately (all of it b2):** `onDetectRegion` and the automatic detection pass, `CandidateChips`, candidate hover preview, free-text candidate search, `__obj` group ids and group prompts, `boxFromCandidate`, `objectIdOfBox` prompt retention across unmark/re-pick, the `Enter`-finishes-a-group key, and the `trackKvSelectionStaged`/`trackKvSelectionDiscarded` analytics that only fire from those paths. `trackKvResizeRegionBoxCommitted` (from `@/lib/analytics/kv-generator-events`) DOES belong to b1 — it fires on a committed marquee, with `method: "marquee"` and the post-commit `box_count`.
- **Also out of scope and NOT to be fixed here** (carried from earlier slices): `onRemove`/`onReorder` committing source-frame coordinates into a tile snapshot (pre-existing, equally live flag-off); `downloadOne`/`downloadAll` calling `resolveTileOverlays` directly; master-row region edit (needs the propagation decision first); tile status UI; inline text editing; the staged flag rollout.
- **The risk this plan does not address.** Six slices will now sit on this branch with **zero browser verification**. Nothing here changes that, and no amount of unit testing substitutes for it. The single highest-value check remains, and takes about a minute: flag on, drag an overlay fully outside a TILE frame, release, confirm it stays put as a dimmed ghost rather than snapping back. If that fails, M1's read-back clamp fix is wrong and everything above it is built on sand. The frame tool adds a second one-minute check: draw a region on a tile, confirm the dashed box lands where the pointer swept at a zoom level other than 100%.
