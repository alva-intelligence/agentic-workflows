# KV Resize Unified Canvas — M1 (Core Editing) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the read-only unified Resize canvas editable — select, drag, scale and rotate overlays in world space, committing frame-normalized geometry to the right backend per board (master → Yjs doc, tile → REST snapshot).

**Architecture:** The spike (`KvResizeUnifiedCanvas` + `renderResizeBoards`) already draws every resize frame as a board on one `fabric.Canvas` with a `viewportTransform` camera. M1 turns overlay objects interactive, adds a pure world↔frame geometry seam so a gesture's result can be converted back into normalized overlay coords, and routes the commit by `board.row` (null ⇒ master). Everything stays behind the existing fail-closed `KV_RESIZE_UNIFIED_CANVAS` flag; the per-tile path is untouched and remains the production surface.

**Tech Stack:** Next.js 16 / React 19 / TypeScript, Fabric.js v7, bun test (`bun test`, jest-dom preloaded via bunfig), Zustand + TanStack Query v5 (existing, not extended here).

**Spec:** `frnd/docs/prd/kv-resize-unified-canvas.md` (status: approved 2026-08-27)

## Global Constraints

- **Branch:** `feature/daffa/vc-kv-resize-unified-canvas` (already created from the branch carrying the as-is paste commits). Never commit to `develop`.
- **Flag:** all M1 behavior sits behind `MAJOR_FEATURE_FLAGS.KV_RESIZE_UNIFIED_CANVAS`, fail-CLOSED, plus the dev opt-in `localStorage["kv-resize-unified-canvas"] === "on"`. Flag off ⇒ zero behavior change.
- **api is untouched.** No new/modified endpoints. If a task appears to need one, STOP and escalate — that is a scope change requiring re-sign-off.
- **Layout is derived, never persisted** (NFR-3). Nothing in M1 may write resize board positions anywhere, and especially not into `studio_files.metadata.kv_canvas`.
- **No fifth renderer** (NFR-5). Object construction goes through the existing `fabricExport.ts` builders via `renderResizeBoards.ts`. Do not write new overlay-drawing code.
- **Canvas geometry is camera-only** (NFR-2). The canvas element's width/height must never change in response to selection, activation or a gesture. Only `props.width/height` (the viewport) and `viewportTransform` may change it.
- **Test runner is `bun test`, NOT vitest.** See [[lesson-web-test-runner-bun-test]]. There is no type gate in CI; compare `tsc` against a baseline worktree, never assume clean.
- **Never `git stash`** to compare baselines — use a worktree at HEAD.

---

## File Structure

| File | Responsibility | Status |
|---|---|---|
| `web/src/components/studio/kv-generator/resizeWorldGeometry.ts` | **NEW.** Pure world↔frame conversion: given a board rect and a fabric object's absolute transform, produce normalized overlay coords, and vice versa. The testable heart of M1. | Task 1 |
| `web/src/components/studio/kv-generator/resizeWorldGeometry.test.ts` | **NEW.** Unit tests for the above (no jsdom, no canvas). | Task 1 |
| `web/src/components/studio/kv-generator/renderResizeBoards.ts` | Modify: stop hard-coding `selectable:false, evented:false`; take an `interactive` flag and make overlay objects (only) selectable. Frame/base/ghost stay inert. | Task 2 |
| `web/src/components/studio/kv-generator/resizeCommitRouting.ts` | **NEW.** Pure: given boards + a board id + the next overlay array, decide which commit target applies (`{kind:"master"}` \| `{kind:"tile", row}`) and compute the next array for that board. | Task 4 |
| `web/src/components/studio/kv-generator/resizeCommitRouting.test.ts` | **NEW.** Unit tests for routing + array assembly. | Task 4 |
| `web/src/components/studio/kv-generator/KvResizeUnifiedCanvas.tsx` | Modify: enable selection, add selection state + `object:modified` handler, separate pan (space/middle/empty-canvas) from drag-object, emit `onCommitOverlays`. | Tasks 3, 5, 6 |
| `web/src/components/studio/kv-generator/KvResizeCanvas.tsx` | Modify: pass real commit callbacks + selection wiring into the unified canvas instead of read-only props. | Task 7 |

M1 deliberately adds two small pure modules rather than growing the component: the component is where fabric/React lifecycle bugs hide, and everything a reviewer needs to check about *correctness of geometry and routing* should be unit-testable without a canvas.

---

### Task 1: World↔frame geometry seam

The per-tile editor converts by subtracting a constant apron (`KvTileOverlayEditor.tsx:587-633`). On the unified canvas the offset is the board's world rect instead, and a grouped (multi-selected) object needs its absolute matrix decomposed — the exact bug class that once collapsed a Cmd+A drag into one corner.

**Files:**
- Create: `web/src/components/studio/kv-generator/resizeWorldGeometry.ts`
- Test: `web/src/components/studio/kv-generator/resizeWorldGeometry.test.ts`

**Interfaces:**
- Consumes: `overlayNormFromRect` from `./overlayGeometry` — verified signature: `(rect: {centerX:number;centerY:number;width:number;height:number}, board: BoardBox) => {x:number;y:number;width:number;height:number}` where `BoardBox` is `{x?:number;y?:number;width:number;height:number}`; `resizeBoardRect`, `ResizeBoard` from `./resizeBoardLayout`.
- Produces:
  - `type WorldTransform = { centerX: number; centerY: number; width: number; height: number; angle: number }`
  - `absoluteTransformOf(obj: fabric.FabricObject): WorldTransform`
  - `normalizedFromWorld(t: WorldTransform, board: ResizeBoard): { x: number; y: number; width: number; height: number; rotation: number }`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect } from "bun:test";
import {
  normalizedFromWorld,
  type WorldTransform,
} from "./resizeWorldGeometry";
import type { ResizeBoard } from "./resizeBoardLayout";

function board(over: Partial<ResizeBoard> = {}): ResizeBoard {
  return {
    id: "b1",
    center: { x: 1000, y: 0 },
    nativeWidth: 1080,
    nativeHeight: 1920,
    width: 640,
    height: 1137.7777777777778, // 640 / (1080/1920)
    imageUrl: null,
    label: "Story",
    isMaster: false,
    row: null,
    ...over,
  } as ResizeBoard;
}

describe("normalizedFromWorld", () => {
  it("maps a world transform back into frame-normalized coords", () => {
    const b = board();
    // Board rect: x = 1000 - 320 = 680, y = -568.888..., w = 640, h = 1137.77...
    // Put a 64x64 object at the board's exact centre.
    const t: WorldTransform = {
      centerX: 1000,
      centerY: 0,
      width: 64,
      height: 64,
      angle: 0,
    };
    const n = normalizedFromWorld(t, b);
    expect(n.width).toBeCloseTo(64 / 640, 6);
    expect(n.height).toBeCloseTo(64 / 1137.7777777777778, 6);
    // Centre of the frame, minus half the object's own normalized size.
    expect(n.x).toBeCloseTo(0.5 - 64 / 640 / 2, 6);
    expect(n.y).toBeCloseTo(0.5 - 64 / 1137.7777777777778 / 2, 6);
    expect(n.rotation).toBe(0);
  });

  it("allows coordinates outside the frame — overflow is legal now", () => {
    const b = board();
    // Parked well to the right of the board's right edge (x = 1320).
    const t: WorldTransform = {
      centerX: 1600,
      centerY: 0,
      width: 64,
      height: 64,
      angle: 0,
    };
    const n = normalizedFromWorld(t, b);
    expect(n.x).toBeGreaterThan(1);
  });

  it("carries rotation through unchanged", () => {
    const n = normalizedFromWorld(
      { centerX: 1000, centerY: 0, width: 64, height: 64, angle: 37 },
      board()
    );
    expect(n.rotation).toBe(37);
  });

  it("returns zero-size safely for a degenerate board", () => {
    const n = normalizedFromWorld(
      { centerX: 0, centerY: 0, width: 10, height: 10, angle: 0 },
      board({ width: 0, height: 0 })
    );
    expect(Number.isFinite(n.x)).toBe(true);
    expect(Number.isFinite(n.width)).toBe(true);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/resizeWorldGeometry.test.ts`
Expected: FAIL — cannot resolve module `./resizeWorldGeometry`.

- [ ] **Step 3: Write the implementation**

```ts
import * as fabric from "fabric";

import { overlayNormFromRect } from "./overlayGeometry";
import { resizeBoardRect, type ResizeBoard } from "./resizeBoardLayout";

/**
 * World↔frame conversion for the unified Resize canvas.
 *
 * On the per-tile path the frame IS the canvas, so converting a gesture back
 * into stored coordinates meant subtracting a constant apron. Here a frame is
 * an object inside a much larger shared canvas, so the offset is the board's
 * own world rect — and unlike the apron it differs per board, which is exactly
 * why this lives in a pure module with tests rather than inline in the
 * component.
 *
 * Nothing here clamps. Overflow is legal on this surface (PRD FR-4): a layer
 * may sit fully outside its frame and still be dragged back, so a coordinate
 * greater than 1 or less than 0 is a valid result, not an error to correct.
 */

export type WorldTransform = {
  centerX: number;
  centerY: number;
  width: number;
  height: number;
  angle: number;
};

/**
 * A fabric object's ABSOLUTE world transform.
 *
 * The `obj.group` branch is load-bearing: fabric rewrites a grouped object's
 * `left`/`top` to be relative to the group's centre, so reading them raw
 * during a multi-select drag commits every member at near-zero coordinates —
 * the bug that once collapsed a whole Cmd+A selection into one corner of a
 * tile. `calcTransformMatrix()` composes the member transform with the
 * group's; `qrDecompose` hands back the absolute centre, scale and angle.
 *
 * Raw `width * scaleX` is used rather than `getScaledWidth()`, which adds a
 * phantom `strokeWidth` padding (fabric defaults it to 1 even with no stroke)
 * and would drift the committed size by half a pixel on every commit.
 */
export function absoluteTransformOf(obj: fabric.FabricObject): WorldTransform {
  if (obj.group) {
    const abs = fabric.util.qrDecompose(obj.calcTransformMatrix());
    return {
      centerX: abs.translateX,
      centerY: abs.translateY,
      width: obj.width * abs.scaleX,
      height: obj.height * abs.scaleY,
      angle: abs.angle,
    };
  }
  return {
    centerX: obj.left ?? 0,
    centerY: obj.top ?? 0,
    width: obj.width * (obj.scaleX ?? 1),
    height: obj.height * (obj.scaleY ?? 1),
    angle: obj.angle ?? 0,
  };
}

/** Convert a world transform into the overlay's frame-normalized geometry —
 *  the exact inverse of the shift `renderResizeBoards` applies when it draws
 *  (`cx = rect.x + geom.centerX`). */
export function normalizedFromWorld(
  t: WorldTransform,
  board: ResizeBoard
): { x: number; y: number; width: number; height: number; rotation: number } {
  const rect = resizeBoardRect(board);
  if (!(rect.width > 0) || !(rect.height > 0)) {
    return { x: 0, y: 0, width: 0, height: 0, rotation: t.angle };
  }
  const norm = overlayNormFromRect(
    {
      centerX: t.centerX - rect.x,
      centerY: t.centerY - rect.y,
      width: t.width,
      height: t.height,
    },
    { width: rect.width, height: rect.height }
  );
  return { ...norm, rotation: t.angle };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/resizeWorldGeometry.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/resizeWorldGeometry.ts src/components/studio/kv-generator/resizeWorldGeometry.test.ts
git commit -m "feat(web): world-to-frame geometry seam for the unified resize canvas"
```

---

### Task 2: Make overlay objects interactive in the renderer

`buildResizeBoardObjects` currently forces `selectable:false, evented:false` on **everything**. Overlays must become interactive while frames, base images and ghosts stay inert — a ghost that could be grabbed would let the user drag a decoration instead of the layer.

**Files:**
- Modify: `web/src/components/studio/kv-generator/renderResizeBoards.ts` (the `tag()` helper, `buildResizeBoardObjects` args, `syncResizeBoards` args)
- Test: `web/src/components/studio/kv-generator/renderResizeBoards.test.ts` (existing file — add cases)

**Interfaces:**
- Consumes: nothing new.
- Produces: `buildResizeBoardObjects(args: { board; content; ghostFor?; isActive?; interactive?: boolean })` — when `interactive` is true, overlay objects get `selectable:true, evented:true` and keep `data.elementId`; everything else stays inert. `syncResizeBoards` gains the same optional `interactive` per entry. Default `false` preserves today's read-only behavior.

- [ ] **Step 1: Write the failing test**

Append to `renderResizeBoards.test.ts`. It uses that file's EXISTING fixtures — `boardsOf(...rows)`, `emptyContent(overlays)`, `ov(id, type, box)`, `withPayload(base, extra)` — do not invent new ones. Note `boardsOf()` returns the master board first, and this suite's `master` is 1000×1000. The test file uses `test(...)`, not `it(...)`.

```ts
describe("interactive mode", () => {
  test("leaves everything inert by default", () => {
    const [b] = boardsOf();
    const objs = buildResizeBoardObjects({
      board: b,
      content: emptyContent([ov("a", "shape")]),
    });
    expect(objs.every((o) => o.selectable === false)).toBe(true);
    expect(objs.every((o) => o.evented === false)).toBe(true);
  });

  test("makes ONLY overlay objects selectable when interactive", () => {
    const [b] = boardsOf();
    const objs = buildResizeBoardObjects({
      board: b,
      content: emptyContent([ov("a", "shape")]),
      interactive: true,
    });
    const overlay = objs.find(
      (o) => (o as { data?: { elementId?: string } }).data?.elementId === "a"
    )!;
    expect(overlay.selectable).toBe(true);
    expect(overlay.evented).toBe(true);
    // The frame is not a grab target — dragging it would move a board.
    const others = objs.filter((o) => o !== overlay);
    expect(others.every((o) => o.evented === false)).toBe(true);
  });

  test("never makes a ghost interactive", () => {
    const [b] = boardsOf();
    const objs = buildResizeBoardObjects({
      board: b,
      // Box pushed past the right edge so the ghost has something to draw.
      content: emptyContent([ov("a", "shape", { x: 0.8, width: 0.5 })]),
      ghostFor: ["a"],
      interactive: true,
    });
    const ghost = objs.find(
      (o) => (o as { data?: { ghostFor?: string } }).data?.ghostFor === "a"
    )!;
    expect(ghost.evented).toBe(false);
  });

  test("keeps a locked overlay inert even when interactive", () => {
    const [b] = boardsOf();
    const objs = buildResizeBoardObjects({
      board: b,
      content: emptyContent([withPayload(ov("a", "shape"), { locked: true })]),
      interactive: true,
    });
    const overlay = objs.find(
      (o) => (o as { data?: { elementId?: string } }).data?.elementId === "a"
    )!;
    expect(overlay.selectable).toBe(false);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/renderResizeBoards.test.ts`
Expected: FAIL — `interactive` is not honored; overlay `selectable` is `false`.

- [ ] **Step 3: Implement**

In `renderResizeBoards.ts`, replace the `tag` helper and thread the flag:

```ts
export function buildResizeBoardObjects(args: {
  board: ResizeBoard;
  content: ResizeBoardContent;
  ghostFor?: string[];
  isActive?: boolean;
  /** Overlay objects accept pointer events and can be selected. Frames, base
   *  images and ghosts stay inert regardless: a frame is not a drag target
   *  (it would move a board), and a grabbable ghost would let the user drag a
   *  decoration instead of the layer it decorates. */
  interactive?: boolean;
}): fabric.FabricObject[] {
  // ...existing body...

  const tag = (
    obj: fabric.FabricObject,
    elementId?: string,
    opts?: { selectable?: boolean }
  ) => {
    (obj as ResizeTagged).data = { resizeBoardId: board.id, elementId };
    const selectable = opts?.selectable === true;
    obj.set({ selectable, evented: selectable });
    obj.setCoords();
    return obj;
  };
```

At the overlay push site, pass selectability (locked layers stay inert, matching the per-tile editor and `selectableOverlayIds`):

```ts
    if (!obj) continue;
    obj.set({ clipPath: frameClip() });
    overlayObjects.push(
      tag(obj, ov.id, {
        selectable: args.interactive === true && ov.payload.locked !== true,
      })
    );
```

Leave the frame, base image and ghost `tag(...)` calls with no `opts` so they default to inert. Then widen `syncResizeBoards`'s entry type with `interactive?: boolean` and forward it in the `buildResizeBoardObjects(entry)` call (it already spreads the whole entry, so only the type needs widening — verify).

- [ ] **Step 4: Run tests**

Run: `cd web && bun test src/components/studio/kv-generator/renderResizeBoards.test.ts`
Expected: PASS — all previous cases plus the 4 new ones.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/renderResizeBoards.ts src/components/studio/kv-generator/renderResizeBoards.test.ts
git commit -m "feat(web): opt-in interactive overlays in the resize board renderer"
```

---

### Task 3: Selection on the unified canvas

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvResizeUnifiedCanvas.tsx`
- Test: `web/src/components/studio/kv-generator/KvResizeUnifiedCanvas.test.tsx` (create if absent)

**Interfaces:**
- Consumes: `resizeBoardIdOf` from `./renderResizeBoards`; `interactive` from Task 2.
- Produces: new props on `KvResizeUnifiedCanvas`:
  - `interactive?: boolean`
  - `selectedOverlayIds?: string[]`
  - `onSelectionChange?: (ids: string[], boardId: string | null) => void`

- [ ] **Step 1: Write the failing test**

```tsx
// Component (.tsx) suites in this directory import from "vitest" and are RUN
// by `bun test` — match the sibling KvTileOverlayEditor.test.tsx exactly.
// `bun:test` is for the pure .ts suites (Tasks 1, 2, 4) and does NOT export
// `vi`. If you ever need RTL queries here, use `within(document.body)` and
// never the bare `screen` export — see [[lesson-web-rtl-screen-broken-under-bun]].
import { describe, it, expect, vi } from "vitest";
import { render } from "@testing-library/react";
import * as fabric from "fabric";

import type { StudioOverlay } from "@/types/studio";
import { KvResizeUnifiedCanvas } from "./KvResizeUnifiedCanvas";

describe("KvResizeUnifiedCanvas — selection", () => {
  it("reports the overlay id and its board when an object is selected", async () => {
    const onSelectionChange = vi.fn();
    let canvas: fabric.Canvas | undefined;
    render(
      <KvResizeUnifiedCanvas
        width={800}
        height={600}
        sourceWidth={1000}
        sourceHeight={1000}
        sourceImageUrl={null}
        exports={[]}
        projectOverlays={[]}
        interactive
        onSelectionChange={onSelectionChange}
        onCanvasReady={(c) => {
          canvas = c;
        }}
      />
    );
    const obj = new fabric.Rect({ width: 10, height: 10 });
    (obj as { data?: object }).data = {
      resizeBoardId: "__master__",
      elementId: "ov1",
    };
    canvas!.add(obj);
    canvas!.setActiveObject(obj);
    canvas!.fire("selection:created", { selected: [obj] });
    expect(onSelectionChange).toHaveBeenCalledWith(["ov1"], "__master__");
  });

  it("reports an empty selection on clear", async () => {
    const onSelectionChange = vi.fn();
    let canvas: fabric.Canvas | undefined;
    render(
      <KvResizeUnifiedCanvas
        width={800}
        height={600}
        sourceWidth={1000}
        sourceHeight={1000}
        sourceImageUrl={null}
        exports={[]}
        projectOverlays={[]}
        interactive
        onSelectionChange={onSelectionChange}
        onCanvasReady={(c) => {
          canvas = c;
        }}
      />
    );
    canvas!.fire("selection:cleared", {});
    expect(onSelectionChange).toHaveBeenCalledWith([], null);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/KvResizeUnifiedCanvas.test.tsx`
Expected: FAIL — `onSelectionChange` never called (prop does not exist).

- [ ] **Step 3: Implement**

Add to the props type:

```tsx
  /** Turn the canvas into an editing surface. Off = the original read-only
   *  spike behavior, unchanged. */
  interactive?: boolean;
  /** Overlay ids the host considers selected (layers panel, Cmd+A, …). */
  selectedOverlayIds?: string[];
  /** Fires with the overlay ids now selected and the board they belong to.
   *  A selection can only ever span ONE board — mixing boards would make the
   *  commit ambiguous — so the board is reported alongside. */
  onSelectionChange?: (ids: string[], boardId: string | null) => void;
```

Change the canvas construction so `selection` follows the mode:

```tsx
      selection: props.interactive === true,
```

Pass `interactive` through the draw effect (each entry gains `interactive: props.interactive === true`, and the effect's dep array gains `props.interactive`).

Add a selection effect:

```tsx
  // Selection → host. Fabric fires created/updated/cleared separately; all
  // three collapse to "here is the current selection".
  const onSelectionChangeRef = useRef(props.onSelectionChange);
  onSelectionChangeRef.current = props.onSelectionChange;
  useEffect(() => {
    if (!canvas) return;
    const report = () => {
      const objs = canvas.getActiveObjects();
      const ids: string[] = [];
      let boardId: string | null = null;
      for (const o of objs) {
        const d = (o as { data?: { elementId?: string } }).data;
        if (!d?.elementId) continue;
        ids.push(d.elementId);
        boardId = boardId ?? resizeBoardIdOf(o) ?? null;
      }
      onSelectionChangeRef.current?.(ids, ids.length > 0 ? boardId : null);
    };
    canvas.on("selection:created", report);
    canvas.on("selection:updated", report);
    canvas.on("selection:cleared", report);
    return () => {
      canvas.off("selection:created", report);
      canvas.off("selection:updated", report);
      canvas.off("selection:cleared", report);
    };
  }, [canvas]);
```

Import `resizeBoardIdOf` from `./renderResizeBoards`.

- [ ] **Step 4: Run tests**

Run: `cd web && bun test src/components/studio/kv-generator/KvResizeUnifiedCanvas.test.tsx`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/KvResizeUnifiedCanvas.tsx src/components/studio/kv-generator/KvResizeUnifiedCanvas.test.tsx
git commit -m "feat(web): selection on the unified resize canvas"
```

---

### Task 4: Commit routing (pure)

**Files:**
- Create: `web/src/components/studio/kv-generator/resizeCommitRouting.ts`
- Test: `web/src/components/studio/kv-generator/resizeCommitRouting.test.ts`

**Interfaces:**
- Consumes: `ResizeBoard`, `findResizeBoard` from `./resizeBoardLayout`; `resolveTileOverlays` from `@/lib/studio/kv/overlayAspect`; `StudioOverlay` from `@/types/studio`; `KvResizeExport` from `@/types/kv/resize`.
- Produces:
  - `type ResizeCommitTarget = { kind: "master" } | { kind: "tile"; row: KvResizeExport }`
  - `resolveCommitTarget(boards: ResizeBoard[], boardId: string | null): ResizeCommitTarget | null`
  - `baselineOverlaysFor(board: ResizeBoard, projectOverlays: StudioOverlay[], sourceWidth: number, sourceHeight: number): StudioOverlay[]`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect } from "bun:test";
import {
  resolveCommitTarget,
  baselineOverlaysFor,
} from "./resizeCommitRouting";
import { MASTER_BOARD_ID, computeResizeBoards } from "./resizeBoardLayout";
import type { KvResizeExport } from "@/types/kv/resize";
import type { StudioOverlay } from "@/types/studio";

const row = (id: string, overlays: StudioOverlay[] | null): KvResizeExport =>
  ({
    id,
    width: 1080,
    height: 1920,
    imageUrl: "https://example.com/t.png",
    platformLabel: "Story",
    overlays,
  }) as unknown as KvResizeExport;

const ov = (id: string, over: Partial<StudioOverlay> = {}): StudioOverlay =>
  ({
    id,
    studio_file_id: "f1",
    type: "shape",
    x: 0.1,
    y: 0.1,
    width: 0.2,
    height: 0.2,
    rotation: 0,
    z: 0,
    payload: { type: "shape", kind: "rectangle", color: "#f00" },
    updated_at: "x",
    ...over,
  }) as StudioOverlay;

const boardsOf = (rows: KvResizeExport[]) =>
  computeResizeBoards({
    master: { width: 1672, height: 941, imageUrl: null },
    exports: rows,
  });

describe("resolveCommitTarget", () => {
  it("routes the master board to the doc", () => {
    const t = resolveCommitTarget(boardsOf([]), MASTER_BOARD_ID);
    expect(t).toEqual({ kind: "master" });
  });

  it("routes a tile board to its own row", () => {
    const r = row("t1", null);
    const t = resolveCommitTarget(boardsOf([r]), "t1");
    expect(t?.kind).toBe("tile");
    expect(t && t.kind === "tile" && t.row.id).toBe("t1");
  });

  it("returns null for an unknown or absent board", () => {
    expect(resolveCommitTarget(boardsOf([]), "nope")).toBeNull();
    expect(resolveCommitTarget(boardsOf([]), null)).toBeNull();
  });
});

describe("baselineOverlaysFor", () => {
  it("uses the project overlays for the master", () => {
    const project = [ov("a")];
    const boards = boardsOf([]);
    const master = boards.find((b) => b.isMaster)!;
    expect(baselineOverlaysFor(master, project, 1672, 941)).toBe(project);
  });

  it("uses a tile's own snapshot when it has one", () => {
    const snap = [ov("s1")];
    const boards = boardsOf([row("t1", snap)]);
    const tile = boards.find((b) => b.id === "t1")!;
    const out = baselineOverlaysFor(tile, [ov("a")], 1672, 941);
    expect(out.map((o) => o.id)).toEqual(["s1"]);
  });

  it("resolves an inheriting tile through resolveTileOverlays, not raw project coords", () => {
    // The tile has NO snapshot, so it renders the project overlays projected
    // into ITS frame. Committing raw project coords here would move every
    // inherited layer the moment one of them is nudged.
    const boards = boardsOf([row("t1", null)]);
    const tile = boards.find((b) => b.id === "t1")!;
    const project = [ov("a", { x: 0.5, y: 0.5, width: 0.4, height: 0.4 })];
    const out = baselineOverlaysFor(tile, project, 1672, 941);
    expect(out).toHaveLength(1);
    // Aspect differs (1672x941 vs 1080x1920), so geometry MUST be re-expressed.
    expect(out[0].width).not.toBeCloseTo(0.4, 4);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/resizeCommitRouting.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

```ts
import { resolveTileOverlays } from "@/lib/studio/kv/overlayAspect";
import type { KvResizeExport } from "@/types/kv/resize";
import type { StudioOverlay } from "@/types/studio";

import { findResizeBoard, type ResizeBoard } from "./resizeBoardLayout";

/**
 * Which backend a board's edit belongs to, and what its pre-edit overlay set
 * is — the two questions every commit on the unified canvas has to answer.
 *
 * Kept pure and separate from the canvas because getting either wrong is
 * silent and expensive: a master edit written to a tile row would strand the
 * change on one tile, and a tile edit written to the doc would leak onto every
 * board (`board_generation_id` semantics, see overlaysForResizeSource).
 */

export type ResizeCommitTarget =
  | { kind: "master" }
  | { kind: "tile"; row: KvResizeExport };

/** Master board ⇒ the Yjs doc; any other board ⇒ that row's REST snapshot.
 *  Null when the board is unknown, so a caller cannot commit into nothing. */
export function resolveCommitTarget(
  boards: ResizeBoard[],
  boardId: string | null
): ResizeCommitTarget | null {
  const board = findResizeBoard(boards, boardId);
  if (!board) return null;
  if (board.isMaster) return { kind: "master" };
  return board.row ? { kind: "tile", row: board.row } : null;
}

/**
 * The overlay array an edit on this board must be applied ON TOP OF.
 *
 * For an INHERITING tile (`row.overlays === null`) this is deliberately the
 * RESOLVED set, not the raw project overlays: the tile renders overlays
 * already projected into its own frame, so committing raw project coordinates
 * would silently re-place every inherited layer the first time one of them is
 * touched. This mirrors what the per-tile paste path already does.
 */
export function baselineOverlaysFor(
  board: ResizeBoard,
  projectOverlays: StudioOverlay[],
  sourceWidth: number,
  sourceHeight: number
): StudioOverlay[] {
  if (board.isMaster) return projectOverlays;
  return resolveTileOverlays(
    board.row?.overlays ?? null,
    projectOverlays,
    sourceWidth,
    sourceHeight,
    board.nativeWidth,
    board.nativeHeight
  );
}
```

- [ ] **Step 4: Run tests**

Run: `cd web && bun test src/components/studio/kv-generator/resizeCommitRouting.test.ts`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/resizeCommitRouting.ts src/components/studio/kv-generator/resizeCommitRouting.test.ts
git commit -m "feat(web): commit routing + baseline resolution for unified resize boards"
```

---

### Task 5: Pan must not fight object drag

Today's pan handler treats **any** `mouse:down` as a pan (safe when nothing is selectable). With interactive overlays that would pan the camera while dragging a layer.

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvResizeUnifiedCanvas.tsx` (the drag-to-pan effect)
- Test: `web/src/components/studio/kv-generator/KvResizeUnifiedCanvas.test.tsx`

**Interfaces:**
- Consumes: `interactive` prop (Task 3).
- Produces: no new exports.

- [ ] **Step 1: Write the failing test**

```tsx
  it("does not pan when the gesture started on an object", async () => {
    let canvas: fabric.Canvas | undefined;
    const { container } = render(
      <KvResizeUnifiedCanvas
        width={800}
        height={600}
        sourceWidth={1000}
        sourceHeight={1000}
        sourceImageUrl={null}
        exports={[]}
        projectOverlays={[]}
        interactive
        onCanvasReady={(c) => {
          canvas = c;
        }}
      />
    );
    const before = canvas!.viewportTransform.slice();
    const obj = new fabric.Rect({ width: 10, height: 10 });
    canvas!.add(obj);
    // A drag that begins ON a target is an object drag, never a pan.
    canvas!.fire("mouse:down", {
      e: { clientX: 10, clientY: 10 } as MouseEvent,
      target: obj,
    });
    canvas!.fire("mouse:move", {
      e: { clientX: 90, clientY: 90 } as MouseEvent,
    });
    canvas!.fire("mouse:up", { e: {} as MouseEvent });
    expect(canvas!.viewportTransform.slice()).toEqual(before);
    expect(container).toBeTruthy();
  });

  it("still pans when the gesture started on empty canvas", async () => {
    let canvas: fabric.Canvas | undefined;
    render(
      <KvResizeUnifiedCanvas
        width={800}
        height={600}
        sourceWidth={1000}
        sourceHeight={1000}
        sourceImageUrl={null}
        exports={[]}
        projectOverlays={[]}
        interactive
        onCanvasReady={(c) => {
          canvas = c;
        }}
      />
    );
    const beforeX = canvas!.viewportTransform[4];
    canvas!.fire("mouse:down", {
      e: { clientX: 10, clientY: 10 } as MouseEvent,
      target: undefined,
    });
    canvas!.fire("mouse:move", {
      e: { clientX: 60, clientY: 10 } as MouseEvent,
    });
    canvas!.fire("mouse:up", { e: {} as MouseEvent });
    await new Promise((r) => setTimeout(r, 0));
    expect(canvas!.viewportTransform[4]).not.toBe(beforeX);
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/KvResizeUnifiedCanvas.test.tsx`
Expected: FAIL on the first case — the camera pans even though the gesture began on an object.

- [ ] **Step 3: Implement**

Replace the pan effect's `down` handler:

```tsx
    const down = (opt: { e: MouseEvent | TouchEvent; target?: unknown }) => {
      // A gesture that starts ON an object belongs to that object. Panning
      // here too would drag the layer and the camera at once, which reads as
      // the layer moving at double speed. In read-only mode nothing is a
      // target, so this is a no-op there and the spike's behavior is intact.
      if (opt.target) return;
      const e = opt.e as MouseEvent;
      panning = { x: e.clientX, y: e.clientY };
      canvas.setCursor("grabbing");
    };
```

- [ ] **Step 4: Run tests**

Run: `cd web && bun test src/components/studio/kv-generator/KvResizeUnifiedCanvas.test.tsx`
Expected: PASS (4 tests total in the file).

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/KvResizeUnifiedCanvas.tsx src/components/studio/kv-generator/KvResizeUnifiedCanvas.test.tsx
git commit -m "fix(web): a drag that starts on an object no longer pans the camera"
```

---

### Task 6: Emit commits on `object:modified`

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvResizeUnifiedCanvas.tsx`
- Test: `web/src/components/studio/kv-generator/KvResizeUnifiedCanvas.test.tsx`

**Interfaces:**
- Consumes: `absoluteTransformOf`, `normalizedFromWorld` (Task 1); `findResizeBoard` from `./resizeBoardLayout`; `applyOverlayTransform` from `@/lib/studio/kv/overlayMutations` — verified signature: `(overlays: StudioOverlay[], id: string, width: number, height: number, rotation: number, x?: number, y?: number) => StudioOverlay[]`, returns the input array unchanged when `id` is absent.
- Produces: new prop `onCommitOverlays?: (boardId: string, next: StudioOverlay[]) => void`, and a required-when-interactive prop `baselineOverlaysFor?: (boardId: string) => StudioOverlay[]` supplied by the host (Task 7 wires it to `resizeCommitRouting.baselineOverlaysFor`).

- [ ] **Step 1: Write the failing test**

```tsx
  it("commits frame-normalized geometry for the board the object belongs to", async () => {
    const onCommitOverlays = vi.fn();
    let canvas: fabric.Canvas | undefined;
    const baseline = [
      {
        id: "ov1",
        studio_file_id: "f1",
        type: "shape",
        x: 0.1,
        y: 0.1,
        width: 0.2,
        height: 0.2,
        rotation: 0,
        z: 0,
        payload: { type: "shape", kind: "rectangle", color: "#f00" },
        updated_at: "x",
      },
    ] as unknown as StudioOverlay[];
    render(
      <KvResizeUnifiedCanvas
        width={800}
        height={600}
        sourceWidth={1000}
        sourceHeight={1000}
        sourceImageUrl={null}
        exports={[]}
        projectOverlays={baseline}
        interactive
        baselineOverlaysFor={() => baseline}
        onCommitOverlays={onCommitOverlays}
        onCanvasReady={(c) => {
          canvas = c;
        }}
      />
    );
    // Master board is centred at (0,0), 640 wide; its rect starts at -320.
    const obj = new fabric.Rect({
      width: 64,
      height: 64,
      left: 0,
      top: 0,
      originX: "center",
      originY: "center",
    });
    (obj as { data?: object }).data = {
      resizeBoardId: "__master__",
      elementId: "ov1",
    };
    canvas!.add(obj);
    canvas!.fire("object:modified", { target: obj });

    expect(onCommitOverlays).toHaveBeenCalledTimes(1);
    const [boardId, next] = onCommitOverlays.mock.calls[0];
    expect(boardId).toBe("__master__");
    const moved = next.find((o: StudioOverlay) => o.id === "ov1")!;
    // Object sits at the board's centre ⇒ normalized centre 0.5.
    expect(moved.x + moved.width / 2).toBeCloseTo(0.5, 4);
  });

  it("ignores a modified object that carries no overlay id", async () => {
    const onCommitOverlays = vi.fn();
    let canvas: fabric.Canvas | undefined;
    render(
      <KvResizeUnifiedCanvas
        width={800}
        height={600}
        sourceWidth={1000}
        sourceHeight={1000}
        sourceImageUrl={null}
        exports={[]}
        projectOverlays={[]}
        interactive
        baselineOverlaysFor={() => []}
        onCommitOverlays={onCommitOverlays}
        onCanvasReady={(c) => {
          canvas = c;
        }}
      />
    );
    canvas!.fire("object:modified", {
      target: new fabric.Rect({ width: 5, height: 5 }),
    });
    expect(onCommitOverlays).not.toHaveBeenCalled();
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/KvResizeUnifiedCanvas.test.tsx`
Expected: FAIL — `onCommitOverlays` never called.

- [ ] **Step 3: Implement**

Add the props:

```tsx
  /** Pre-edit overlay array for a board — the set an edit is applied on top
   *  of. Supplied by the host because resolving it needs the project overlays
   *  and the source aspect (see resizeCommitRouting.baselineOverlaysFor).
   *  Required in practice whenever `interactive` is set. */
  baselineOverlaysFor?: (boardId: string) => StudioOverlay[];
  /** Fires once per finished gesture with the board and its next overlay
   *  array. The host owns persistence and undo. */
  onCommitOverlays?: (boardId: string, next: StudioOverlay[]) => void;
```

Add the commit effect (reading callbacks through refs so the handler registers once and never drops a gesture mid-render — the same rule the Craft canvas follows):

```tsx
  const commitRef = useRef({
    baselineOverlaysFor: props.baselineOverlaysFor,
    onCommitOverlays: props.onCommitOverlays,
  });
  commitRef.current = {
    baselineOverlaysFor: props.baselineOverlaysFor,
    onCommitOverlays: props.onCommitOverlays,
  };
  const boardsRef = useRef(boards);
  boardsRef.current = boards;

  useEffect(() => {
    if (!canvas) return;
    const onModified = (opt: { target?: fabric.FabricObject }) => {
      const { baselineOverlaysFor, onCommitOverlays } = commitRef.current;
      if (!onCommitOverlays || !baselineOverlaysFor) return;
      // A multi-object gesture fires once with the ActiveSelection as target;
      // commit every member so a group drag is one write, not N.
      const target = opt.target;
      if (!target) return;
      const objs =
        target instanceof fabric.ActiveSelection
          ? target.getObjects()
          : [target];

      let boardId: string | null = null;
      let next: StudioOverlay[] | null = null;
      for (const obj of objs) {
        const d = (obj as { data?: { elementId?: string } }).data;
        const id = d?.elementId;
        if (!id) continue;
        const objBoardId = resizeBoardIdOf(obj) ?? null;
        if (!objBoardId) continue;
        // A selection cannot span boards (see onSelectionChange); the first
        // board wins and foreign members are skipped rather than written to
        // the wrong backend.
        boardId = boardId ?? objBoardId;
        if (objBoardId !== boardId) continue;
        const board = findResizeBoard(boardsRef.current, boardId);
        if (!board) continue;
        next = next ?? baselineOverlaysFor(boardId);
        const norm = normalizedFromWorld(absoluteTransformOf(obj), board);
        next = applyOverlayTransform(
          next,
          id,
          norm.width,
          norm.height,
          norm.rotation,
          norm.x,
          norm.y
        );
      }
      if (boardId && next) onCommitOverlays(boardId, next);
    };
    canvas.on("object:modified", onModified);
    return () => {
      canvas.off("object:modified", onModified);
    };
  }, [canvas]);
```

Imports for this task:

```tsx
import { applyOverlayTransform } from "@/lib/studio/kv/overlayMutations";
import type { StudioOverlay } from "@/types/studio";
import { findResizeBoard } from "./resizeBoardLayout";
import {
  absoluteTransformOf,
  normalizedFromWorld,
} from "./resizeWorldGeometry";
```

- [ ] **Step 4: Run tests**

Run: `cd web && bun test src/components/studio/kv-generator/KvResizeUnifiedCanvas.test.tsx`
Expected: PASS (6 tests total).

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/KvResizeUnifiedCanvas.tsx src/components/studio/kv-generator/KvResizeUnifiedCanvas.test.tsx
git commit -m "feat(web): commit overlay transforms from the unified resize canvas"
```

---

### Task 7: Wire the host — real commits behind the flag

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvResizeCanvas.tsx:1515-1530` (the `unifiedCanvasEnabled` branch)

**Interfaces:**
- Consumes: everything from Tasks 3–6; existing `commitTileOverlays(row, next)`, `commitMasterOverlays(next)`, `projectOverlays`, `sourceSize`, `setActiveTileId`, `setSelectedIds`.
- Produces: nothing new exported.

- [ ] **Step 1: Wire the props**

Replace the read-only mount with:

```tsx
          <KvResizeUnifiedCanvas
            width={viewportSize.w}
            height={viewportSize.h}
            sourceWidth={sourceSize.w}
            sourceHeight={sourceSize.h}
            sourceImageUrl={source.image_url}
            exports={exports}
            projectOverlays={projectOverlays}
            activeBoardId={activeTileId}
            ghostOverlayIds={selectedIds}
            interactive
            selectedOverlayIds={selectedIds}
            onSelectionChange={(ids, boardId) => {
              setSelectedIds(ids);
              // The board a selection lands on becomes the active tile, so the
              // layers panel and every keyboard path (Cmd+A/C/V, Delete) stay
              // pointed at what the user is actually editing.
              if (boardId) {
                // MASTER_BOARD_ID and MASTER_ROW_ID are both "__master__"
                // today, so this maps identity — written out anyway so the
                // two namespaces stay independently changeable.
                setActiveTileId(
                  boardId === MASTER_BOARD_ID ? MASTER_ROW_ID : boardId
                );
              }
            }}
            baselineOverlaysFor={(boardId) => {
              const board = findResizeBoard(unifiedBoards, boardId);
              if (!board) return [];
              return baselineOverlaysFor(
                board,
                projectOverlays,
                sourceSize.w,
                sourceSize.h
              );
            }}
            onCommitOverlays={(boardId, next) => {
              const target = resolveCommitTarget(unifiedBoards, boardId);
              if (!target) return;
              if (target.kind === "master") commitMasterOverlays(next);
              else commitTileOverlays(target.row, next);
            }}
          />
```

`unifiedBoards` must be the SAME array the canvas computes. Add it above the return, memoized identically to the canvas's own `computeResizeBoards` call:

```tsx
  // Boards for the unified canvas, computed here too so commit routing
  // resolves against the same layout the canvas rendered. Cheap and pure
  // (resizeBoardLayout is deterministic), and far safer than passing the
  // canvas's internal array back out.
  const unifiedBoards = useMemo(
    () =>
      computeResizeBoards({
        master: {
          width: sourceSize.w,
          height: sourceSize.h,
          imageUrl: source.image_url,
        },
        exports,
      }),
    [sourceSize.w, sourceSize.h, source.image_url, exports]
  );
```

Add imports: `computeResizeBoards`, `findResizeBoard`, `MASTER_BOARD_ID` from `./resizeBoardLayout`; `resolveCommitTarget`, `baselineOverlaysFor` from `./resizeCommitRouting`.

- [ ] **Step 2: Verify the flag still fails closed**

Run: `cd web && bun test src/components/studio/kv-generator/KvResizeCanvas` (whichever suites exist for it)
Expected: unchanged results — the branch only runs when `unifiedCanvasEnabled` is true, which is false in tests.

- [ ] **Step 3: Full-suite regression check against a baseline**

```bash
cd web
git worktree add /tmp/m1-baseline HEAD~7   # the commit before Task 1
cd /tmp/m1-baseline && bun install --silent
bun test src/lib/studio/kv src/components/studio/kv-generator 2>&1 | grep "^(fail)" | sort > /tmp/fails_baseline.txt
cd - && bun test src/lib/studio/kv src/components/studio/kv-generator 2>&1 | grep "^(fail)" | sort > /tmp/fails_now.txt
diff /tmp/fails_baseline.txt /tmp/fails_now.txt
```

Expected: identical (only pre-existing failures). Then `git worktree remove /tmp/m1-baseline --force`.

- [ ] **Step 4: Manual verification in the browser**

1. Ensure the dev server runs (`./run-all.sh --status`; do NOT start servers with Bash).
2. In the browser console on the Resize screen: `localStorage.setItem("kv-resize-unified-canvas","on")`, then reload. (The PostHog flag must also be on for this user.)
3. Confirm: click an overlay → handles appear; drag it → it moves and the camera does NOT pan; drag it fully outside its frame → it stays visible and draggable; release → the change persists after a reload.
4. Confirm routing in the DB — a tile edit writes only that row:
   `psql -h 127.0.0.1 -p 5432 -d frnd -c "select id, jsonb_array_length(overlays::jsonb) from kv_resize_exports where studio_file_id='<id>' and deleted_at is null;"`
5. Confirm `metadata.kv_canvas` is unchanged before/after (NFR-3):
   `psql -h 127.0.0.1 -p 5432 -d frnd -t -A -c "select md5(metadata::text) from studio_files where id='<id>';"`

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/KvResizeCanvas.tsx
git commit -m "feat(web): wire real commits into the unified resize canvas behind the flag"
```

---

### Task 8: Fix the pre-existing `overlaySig` bug in `useResizeBoardContent`

Found while planning: `useResizeBoardContent.ts` declares `overlaySig` via `useMemo` **inside a `for` loop inside another `useMemo`**, then references it from a `useEffect` dep array where it is out of scope. It is a real `tsc` error (`TS2304: Cannot find name 'overlaySig'`) and a Rules-of-Hooks violation. It does not crash today only because the flag is off. M1 turns this component into the editing surface, so it must be fixed first.

**Files:**
- Modify: `web/src/components/studio/kv-generator/useResizeBoardContent.ts:55-96,143-150`

- [ ] **Step 1: Confirm the error exists**

Run: `cd web && bunx tsc --noEmit -p tsconfig.json 2>&1 | grep useResizeBoardContent`
Expected: `error TS2304: Cannot find name 'overlaySig'.`

- [ ] **Step 2: Implement**

Hoist `overlaySig` to its own top-level `useMemo`, sibling to `urlSig`, and delete the nested one:

```ts
  // Value-identity of the overlays the published map carries — geometry,
  // stacking and payload — so overlay-only edits re-run the loader (image
  // elements are cached by URL, so the cost is a map rebuild, not a refetch).
  // MUST be a top-level hook: it was previously declared inside the urlSig
  // loop, which is a Rules-of-Hooks violation AND left the name undefined at
  // the effect below.
  const overlaySig = useMemo(
    () =>
      boards
        .map((b) =>
          [
            b.id,
            ...(overlaysByBoard.get(b.id) ?? []).map((o) =>
              [
                o.id,
                o.x,
                o.y,
                o.width,
                o.height,
                o.rotation,
                o.z,
                JSON.stringify(o.payload),
              ].join(":")
            ),
          ].join("|")
        )
        .join("\n"),
    [boards, overlaysByBoard]
  );

  const urlSig = useMemo(() => {
    const parts: string[] = [];
    for (const b of boards) {
      parts.push(`base:${b.id}:${b.imageUrl ?? ""}`);
      for (const o of overlaysByBoard.get(b.id) ?? []) {
        if (o.payload.type !== "image") continue;
        parts.push(
          `ov:${b.id}:${o.id}:${(o.payload as { asset_url: string }).asset_url}`
        );
      }
    }
    return parts.join(",");
  }, [boards, overlaysByBoard]);
```

- [ ] **Step 3: Verify the error is gone and no new ones appeared**

Run: `cd web && bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -E "useResizeBoardContent|KvResizeUnifiedCanvas|resizeWorldGeometry|resizeCommitRouting|renderResizeBoards"`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add src/components/studio/kv-generator/useResizeBoardContent.ts
git commit -m "fix(web): hoist overlaySig out of a nested useMemo in useResizeBoardContent"
```

> **Execution note:** run Task 8 FIRST if the executor prefers a clean `tsc` throughout. It is listed last only because it was discovered during planning; it has no dependency on Tasks 1–7.

---

## Definition of Done (M1)

- [ ] Overlays on the unified canvas can be selected, dragged, scaled and rotated (flag on).
- [ ] Every gesture commits frame-normalized geometry to the correct backend (master → doc, tile → that row).
- [ ] A layer can be parked fully outside its frame, stays visible, and can be dragged back — no clamp anywhere in the commit path.
- [ ] Dragging an object never pans the camera; the canvas element never changes size during a gesture.
- [ ] `metadata.kv_canvas` is byte-identical before and after a unified-canvas editing session.
- [ ] With the flag off, behavior is bit-for-bit what it is today.
- [ ] Test suite shows no new failures against a HEAD-worktree baseline; `tsc` clean on all touched files.

**Explicitly NOT in M1** (deferred to M2, per the PRD): multi-select semantics per `canvasMode`, per-tile undo routing, tile status UI, inline text editing, and the tool-layer port (frame/shape/comment/clipboard/align). M1 makes single- and group-drag *work*; M2 makes the surface *complete enough to flip the flag*.
