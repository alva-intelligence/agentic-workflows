# KV Ghosted Overflow (Craft + Resize) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a KV overlay is selected or dragged past its frame, render the clipped-off part as a dimmed 25%-opacity ghost — on both the Craft canvas and the Resize tiles — so the user can see and grab what extends outside the frame (Figma/Canva behavior).

**Architecture:** A shared `ghostOverlay.ts` module produces ghost Fabric objects (duplicate of the overlay's object, inverted `clipPath` over the frame, 25% relative opacity, non-evented, tagged `data.ghostFor`). Craft attaches ghosts to its world canvas driven by Fabric selection events. Resize grows the active tile's canvas by an "apron" margin (only while a layer is selected) so there is drawable space outside the frame; all coordinates shift by the apron and every overlay is explicitly clipped to the frame rect while the apron is on.

**Tech Stack:** Next.js 16 / React 19 / TypeScript, Fabric.js v7, bun test (jsdom via bunfig preload).

**Spec:** `docs/superpowers/specs/2026-08-14-kv-ghost-overflow-design.md` (workspace repo).

## Global Constraints

- All code in `web/` on branch `feature/alva/vc-kv-fabric-export` (already checked out; Craft + Resize are both Fabric on this branch — do NOT rebase or switch).
- Tests run with `bun test` from `web/` (NOT `bunx vitest`). There is no type gate in the build; run `bunx tsc --noEmit` and diff error count against the pre-existing baseline (~777 errors) instead of expecting zero.
- Ghost constants (from spec, verbatim): opacity factor **0.25**, apron size **`round(0.15 × max(displayWidth, displayHeight))`**.
- Ghosts must force `globalCompositeOperation: "source-over"` and must NEVER carry `data.elementId` (only `data.ghostFor`).
- Ghost trigger is selection only — no always-on mode, no toggle. Base images are never ghosted.
- No new PostHog event: this feature adds no new user interaction (drag/select already exist and are already instrumented); it changes rendering only. State this in the PR body.
- RTL `screen` is broken under bun in this repo — component tests must use `within(document.body)` or direct canvas inspection via `onCanvasReady`.

---

### Task 1: Shared ghost module `ghostOverlay.ts`

**Files:**
- Create: `web/src/components/studio/kv-generator/ghostOverlay.ts`
- Test: `web/src/components/studio/kv-generator/ghostOverlay.test.ts`

**Interfaces:**
- Consumes: nothing project-specific (only `fabric`).
- Produces (used by Tasks 2 and 3):
  - `GHOST_OPACITY_FACTOR = 0.25`
  - `type FrameRect = { x: number; y: number; width: number; height: number }`
  - `buildFrameClip(frame: FrameRect, inverted?: boolean): fabric.Rect`
  - `applyGhostStyle(obj: fabric.FabricObject, overlayId: string, frame: FrameRect): fabric.FabricObject` — mutates `obj` into a ghost (sync; caller supplies a freshly built duplicate)
  - `ghostFromObject(source: fabric.FabricObject, overlayId: string, frame: FrameRect): Promise<fabric.FabricObject>` — async clone + `applyGhostStyle` (for Craft, where objects are built in many inline branches)
  - `syncGhostTransform(source: fabric.FabricObject, ghost: fabric.FabricObject): void`
  - `isGhost(obj: fabric.FabricObject): boolean`
  - `ghostSourceId(obj: fabric.FabricObject): string | undefined`

- [ ] **Step 1: Write the failing test**

```ts
// web/src/components/studio/kv-generator/ghostOverlay.test.ts
import { describe, expect, test } from "bun:test";
import * as fabric from "fabric";

import {
  GHOST_OPACITY_FACTOR,
  applyGhostStyle,
  buildFrameClip,
  ghostFromObject,
  ghostSourceId,
  isGhost,
  syncGhostTransform,
} from "./ghostOverlay";

const FRAME = { x: 10, y: 20, width: 300, height: 200 };

describe("buildFrameClip", () => {
  test("builds an absolute-positioned top-left rect over the frame", () => {
    const clip = buildFrameClip(FRAME);
    expect(clip.left).toBe(10);
    expect(clip.top).toBe(20);
    expect(clip.width).toBe(300);
    expect(clip.height).toBe(200);
    expect(clip.originX).toBe("left");
    expect(clip.originY).toBe("top");
    expect(clip.absolutePositioned).toBe(true);
    expect(clip.inverted).toBe(false);
  });

  test("inverted flag flips the clip", () => {
    expect(buildFrameClip(FRAME, true).inverted).toBe(true);
  });
});

describe("applyGhostStyle", () => {
  test("dims to 25% of the source opacity, disables interaction, tags ghostFor", () => {
    const obj = new fabric.Rect({ width: 50, height: 50, opacity: 0.8 });
    const ghost = applyGhostStyle(obj, "ov-1", FRAME);
    expect(ghost).toBe(obj); // mutates in place
    expect(ghost.opacity).toBeCloseTo(0.8 * GHOST_OPACITY_FACTOR);
    expect(ghost.selectable).toBe(false);
    expect(ghost.evented).toBe(false);
    expect(ghost.globalCompositeOperation).toBe("source-over");
    expect((ghost.clipPath as fabric.Rect).inverted).toBe(true);
    expect(isGhost(ghost)).toBe(true);
    expect(ghostSourceId(ghost)).toBe("ov-1");
    // A ghost must never look like a real overlay to the doc sync.
    expect(
      (ghost as { data?: { elementId?: string } }).data?.elementId
    ).toBeUndefined();
  });

  test("a blend-mode source does not leak its blend into the ghost", () => {
    const obj = new fabric.Rect({
      width: 10,
      height: 10,
      globalCompositeOperation: "multiply",
    });
    applyGhostStyle(obj, "ov-2", FRAME);
    expect(obj.globalCompositeOperation).toBe("source-over");
  });
});

describe("ghostFromObject", () => {
  test("clones without inheriting elementId, then ghost-styles the clone", async () => {
    const src = new fabric.Rect({
      left: 5,
      top: 6,
      width: 40,
      height: 30,
      opacity: 1,
    });
    (src as { data?: unknown }).data = { elementId: "ov-3" };
    const ghost = await ghostFromObject(src, "ov-3", FRAME);
    expect(ghost).not.toBe(src);
    expect(ghost.left).toBe(5);
    expect(ghost.width).toBe(40);
    expect(isGhost(ghost)).toBe(true);
    expect(ghostSourceId(ghost)).toBe("ov-3");
    expect(
      (ghost as { data?: { elementId?: string } }).data?.elementId
    ).toBeUndefined();
  });
});

describe("syncGhostTransform", () => {
  test("mirrors position, scale and angle", () => {
    const src = new fabric.Rect({ width: 10, height: 10 });
    src.set({ left: 111, top: 222, scaleX: 2, scaleY: 3, angle: 45 });
    const ghost = new fabric.Rect({ width: 10, height: 10 });
    syncGhostTransform(src, ghost);
    expect(ghost.left).toBe(111);
    expect(ghost.top).toBe(222);
    expect(ghost.scaleX).toBe(2);
    expect(ghost.scaleY).toBe(3);
    expect(ghost.angle).toBe(45);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run (from `web/`): `bun test src/components/studio/kv-generator/ghostOverlay.test.ts`
Expected: FAIL — `Cannot find module './ghostOverlay'`.

- [ ] **Step 3: Write the implementation**

```ts
// web/src/components/studio/kv-generator/ghostOverlay.ts
import * as fabric from "fabric";

/** Ghost renders at 25% of the layer's own effective opacity (spec value). */
export const GHOST_OPACITY_FACTOR = 0.25;

export type FrameRect = {
  x: number;
  y: number;
  width: number;
  height: number;
};

/** Identity stamp for ghost objects. Deliberately NOT `elementId` — the Yjs
 *  binding, reconcile passes and any `getObjects()` scan key on `elementId`,
 *  so a ghost can never be mistaken for a real overlay. */
type GhostTagged = fabric.FabricObject & { data?: { ghostFor?: string } };

/**
 * Clip rect over a frame, in the same coordinate space as the objects it
 * clips. `absolutePositioned` so the rect is placed against the canvas, not
 * relative to the clipped object (same reasoning as Craft's
 * `buildOverlayClip`). Fabric v7 defaults to a CENTER origin, so the origin
 * is stated explicitly to keep `frame.x/y` readable as the top-left corner.
 * With `inverted: true` only the part of the object OUTSIDE the frame draws —
 * that inversion is the whole ghost mechanism.
 */
export function buildFrameClip(frame: FrameRect, inverted = false): fabric.Rect {
  return new fabric.Rect({
    originX: "left",
    originY: "top",
    left: frame.x,
    top: frame.y,
    width: frame.width,
    height: frame.height,
    absolutePositioned: true,
    inverted,
  });
}

/**
 * Mutate a freshly built duplicate of an overlay's object into its ghost:
 * inverted frame clip, 25% relative opacity, non-interactive, `source-over`
 * (a blend-mode layer's ghost must not blend with whatever happens to be
 * behind the frame), tagged `ghostFor`.
 */
export function applyGhostStyle(
  obj: fabric.FabricObject,
  overlayId: string,
  frame: FrameRect
): fabric.FabricObject {
  obj.set({
    opacity: (obj.opacity ?? 1) * GHOST_OPACITY_FACTOR,
    selectable: false,
    evented: false,
    globalCompositeOperation: "source-over",
    clipPath: buildFrameClip(frame, true),
  });
  // Overwrite wholesale: a clone may have copied the source's `data` and a
  // ghost carrying `elementId` would be picked up as a real overlay.
  (obj as GhostTagged).data = { ghostFor: overlayId };
  obj.setCoords();
  return obj;
}

/** Async clone + ghost-style — for call sites that only hold the live object
 *  (Craft's reconcile builds objects across many inline branches; cloning the
 *  finished object is simpler than re-running the right branch). */
export async function ghostFromObject(
  source: fabric.FabricObject,
  overlayId: string,
  frame: FrameRect
): Promise<fabric.FabricObject> {
  const clone = await source.clone();
  return applyGhostStyle(clone, overlayId, frame);
}

/** Mirror the live gesture onto the ghost so it tracks every frame of a
 *  drag/scale/rotate, not just the drop. */
export function syncGhostTransform(
  source: fabric.FabricObject,
  ghost: fabric.FabricObject
): void {
  ghost.set({
    left: source.left,
    top: source.top,
    scaleX: source.scaleX,
    scaleY: source.scaleY,
    angle: source.angle,
    skewX: source.skewX,
    skewY: source.skewY,
  });
  ghost.setCoords();
}

export function isGhost(obj: fabric.FabricObject): boolean {
  return typeof (obj as GhostTagged).data?.ghostFor === "string";
}

export function ghostSourceId(obj: fabric.FabricObject): string | undefined {
  return (obj as GhostTagged).data?.ghostFor;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bun test src/components/studio/kv-generator/ghostOverlay.test.ts`
Expected: PASS (all cases).

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/ghostOverlay.ts src/components/studio/kv-generator/ghostOverlay.test.ts
git commit -m "feat(web): shared ghost-overlay module (inverted frame clip, 25% dim)"
```

---

### Task 2: Craft wiring — ghosts on `KvFabricCanvas`

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvFabricCanvas.tsx`
  - imports (top of file)
  - gesture handlers `onMoving` / `onTransforming` (~line 1148 / ~1224)
  - the overlay reconcile effect (~line 1626, after `applyOverlayZOrder`)
  - new refs near `draggingOverlayIdRef`

**Interfaces:**
- Consumes (Task 1): `ghostFromObject(source, overlayId, frame): Promise<fabric.FabricObject>`, `syncGhostTransform(source, ghost)`, `isGhost(obj)`.
- Consumes (existing in file): `overlayHostRect(overlay): WorldRect | null` (WorldRect = `{x, y, width, height}` — structurally identical to `FrameRect`), `overlaysRef`, `draggingOverlayIdRef`, `fabricRef`, `Tagged` type.
- Produces: nothing consumed by later tasks (Resize uses the module directly).

**No component test exists for `KvFabricCanvas`** (it cannot be component-tested — established on PR #425). Verification for this task is: type-check delta, full `bun test` (no regressions), and the manual e2e in Task 5.

- [ ] **Step 1: Add imports and the ghost registry ref**

At the top of `KvFabricCanvas.tsx` add:

```ts
import {
  ghostFromObject,
  isGhost,
  syncGhostTransform,
} from "./ghostOverlay";
```

Near `draggingOverlayIdRef` (the refs cluster around line 985) add:

```ts
// Ghost objects by source overlay id. Ghosts are DERIVED canvas furniture:
// never selected, never synced to the doc, rebuilt from the current Fabric
// selection whenever it changes. See ghostOverlay.ts.
const ghostByIdRef = useRef<Map<string, fabric.FabricObject>>(new Map());
// Monotonic token so a slow async clone from a superseded refresh can't
// resurrect a ghost after the selection moved on.
const ghostRefreshTokenRef = useRef(0);
```

- [ ] **Step 2: Write `refreshGhosts` and hook it to selection events**

Inside the mount effect (the one ending `}, [doc]);` at ~line 1297), after `canvas.on("mouse:up", ...)` and BEFORE `bindingRef.current = bindKvCanvasToYjs(...)`, add:

```ts
    // ── Ghosted overflow ─────────────────────────────────────────────────
    // Rebuild the ghost set from the CURRENT Fabric selection. A ghost is a
    // dimmed duplicate with an inverted frame clip: only the part of the
    // layer OUTSIDE its board draws. Bottom of the stack so a ghost never
    // covers board content (board base images are inserted at index 0, so
    // "back" here means behind everything including neighbouring boards'
    // artwork drawn later — see sendObjectToBack calls).
    const refreshGhosts = () => {
      const token = ++ghostRefreshTokenRef.current;
      // Drop every existing ghost — selection changes are rare (not
      // per-frame), so rebuild-from-scratch is simpler than diffing.
      ghostByIdRef.current.forEach((g) => canvas.remove(g));
      ghostByIdRef.current.clear();

      const active = canvas.getActiveObjects();
      for (const obj of active) {
        const data = (obj as Tagged).data;
        if (!data || !("elementId" in data)) continue;
        const overlay = overlaysRef.current.find(
          (o) => o.id === data.elementId
        );
        if (!overlay) continue;
        // Inline-edited text has its object hidden — no ghost.
        if ((obj as fabric.Textbox).isEditing) continue;
        const host = resolveOverlayHostByIdRef.current(data.elementId);
        if (!host || host.width <= 0 || host.height <= 0) continue;
        void ghostFromObject(obj, data.elementId, host).then((ghost) => {
          if (token !== ghostRefreshTokenRef.current) return; // superseded
          if (!fabricRef.current) return;
          ghostByIdRef.current.set(data.elementId, ghost);
          canvas.add(ghost);
          canvas.sendObjectToBack(ghost);
          canvas.requestRenderAll();
        });
      }
      canvas.requestRenderAll();
    };
    const refreshGhostsRef = ghostRefreshHandleRef;
    refreshGhostsRef.current = refreshGhosts;
    canvas.on("selection:created", refreshGhosts);
    canvas.on("selection:updated", refreshGhosts);
    canvas.on("selection:cleared", refreshGhosts);
    // Re-derive after a committed gesture: the reconcile skipped the dragged
    // object mid-gesture, so the ghost's clip/geometry may be stale.
    canvas.on("object:modified", refreshGhosts);
```

Add the handle ref next to `ghostByIdRef` (Step 1's cluster):

```ts
// Handle so the overlay reconcile effect (a different effect) can trigger a
// ghost rebuild after it restyles/removes objects.
const ghostRefreshHandleRef = useRef<(() => void) | null>(null);
```

And in the mount effect's cleanup (before `canvas.dispose()`):

```ts
      canvas.off("selection:created", refreshGhosts);
      canvas.off("selection:updated", refreshGhosts);
      canvas.off("selection:cleared", refreshGhosts);
      canvas.off("object:modified", refreshGhosts);
      ghostByIdRef.current.clear();
      ghostRefreshHandleRef.current = null;
```

- [ ] **Step 3: Mirror live gestures onto ghosts**

In `onMoving` (~line 1148), right after `setOverlayInteracting(true);` (the overlay branch, after the `elementId` guard), add:

```ts
      // Ghost tracks the drag live. sendObjectToBack each frame is a cheap
      // array splice and also self-heals ordering if a board image (re)loaded
      // (boards insert at index 0, which would land beneath the ghost).
      const movingGhost = ghostByIdRef.current.get(data.elementId);
      if (movingGhost) {
        syncGhostTransform(obj, movingGhost);
        canvas.sendObjectToBack(movingGhost);
      }
```

In `onTransforming` (~line 1224), after `setOverlayInteracting(true);`, add:

```ts
      const tGhost = ghostByIdRef.current.get(data.elementId);
      if (tGhost) {
        syncGhostTransform(obj, tGhost);
        canvas.sendObjectToBack(tGhost);
      }
```

- [ ] **Step 4: Keep ghosts consistent through the reconcile**

Two touches in the overlay reconcile effect (~line 1626):

a. The stale-object sweep at its top iterates `canvas.getObjects()` and
removes anything whose `elementId` isn't wanted — ghosts have no
`elementId`, so they are already skipped by the `!("elementId" in data)`
guard. Verify this and add `isGhost` to the guard for explicitness:

```ts
    canvas.getObjects().forEach((o) => {
      if (isGhost(o)) return; // ghosts are derived — managed by refreshGhosts
      const data = (o as Tagged).data;
      if (!data || !("elementId" in data)) return;
      if (wanted.has(data.elementId)) existing.set(data.elementId, o);
      else canvas.remove(o);
    });
```

b. At the very end of the effect body (after the existing
`applyOverlayZOrder()` / final `canvas.requestRenderAll()` call), add:

```ts
    // Overlay geometry/styling may have changed under the selection (e.g. a
    // panel edit) — rebuild ghosts from the refreshed objects. No-op when
    // nothing is selected. Skipped mid-drag: the gesture mirrors the ghost
    // itself and object:modified refreshes on drop.
    if (draggingOverlayIdRef.current === null) {
      ghostRefreshHandleRef.current?.();
    }
```

- [ ] **Step 5: Type-check and test**

Run: `bunx tsc --noEmit 2>&1 | tail -3` — error count must not exceed the baseline count measured on HEAD before this task (measure first: `git stash list` is NOT allowed — use `git worktree` if a baseline is needed, or count once before editing).
Run: `bun test src/components/studio/kv-generator/` — same pass/fail counts as before this task.

- [ ] **Step 6: Commit**

```bash
git add src/components/studio/kv-generator/KvFabricCanvas.tsx
git commit -m "feat(web): ghosted overflow for selected overlays on the Craft canvas"
```

---

### Task 3: Resize apron — `KvTileOverlayEditor` + row wrappers

**Files:**
- Create: `web/src/components/studio/kv-generator/resizeApron.ts`
- Test: `web/src/components/studio/kv-generator/resizeApron.test.ts`
- Modify: `web/src/components/studio/kv-generator/KvTileOverlayEditor.tsx`
- Modify: `web/src/components/studio/kv-generator/KvResizeResultRow.tsx` (~line 213 wrapper div)
- Modify: `web/src/components/studio/kv-generator/KvResizeOriginalRow.tsx` (~line 113 wrapper div)

**Interfaces:**
- Consumes (Task 1): `applyGhostStyle(obj, overlayId, frame)`, `buildFrameClip(frame, inverted?)`, `isGhost(obj)`.
- Produces:
  - `apronPx(opts: { isActive: boolean; selectionCount: number; displayWidth: number; displayHeight: number }): number` — `0` when inactive or nothing selected, else `Math.round(0.15 * Math.max(displayWidth, displayHeight))`. Used by the editor AND both row wrappers (single formula, no drift).

- [ ] **Step 1: Write the failing apron test**

```ts
// web/src/components/studio/kv-generator/resizeApron.test.ts
import { describe, expect, test } from "bun:test";
import { apronPx } from "./resizeApron";

describe("apronPx", () => {
  test("zero when the tile is not active", () => {
    expect(
      apronPx({ isActive: false, selectionCount: 1, displayWidth: 400, displayHeight: 300 })
    ).toBe(0);
  });
  test("zero when nothing is selected (merely activating a tile must not grow it)", () => {
    expect(
      apronPx({ isActive: true, selectionCount: 0, displayWidth: 400, displayHeight: 300 })
    ).toBe(0);
  });
  test("15% of the longer display edge, rounded", () => {
    expect(
      apronPx({ isActive: true, selectionCount: 1, displayWidth: 400, displayHeight: 300 })
    ).toBe(60); // 0.15 × 400
    expect(
      apronPx({ isActive: true, selectionCount: 2, displayWidth: 300, displayHeight: 401 })
    ).toBe(60); // round(0.15 × 401) = round(60.15)
  });
});
```

- [ ] **Step 2: Run it — expect module-not-found FAIL — then implement**

```ts
// web/src/components/studio/kv-generator/resizeApron.ts
/**
 * The "apron" is extra drawable margin around a Resize tile's frame, so a
 * selected overlay's ghost (ghostOverlay.ts) has somewhere to render. It
 * exists ONLY while the tile is active AND a layer is selected — the exact
 * ghost trigger — so merely clicking a tile never changes its size.
 * Shared by KvTileOverlayEditor (canvas geometry) and the row wrappers
 * (overflow/z-index classes) so the two can't disagree.
 */
export function apronPx(opts: {
  isActive: boolean;
  selectionCount: number;
  displayWidth: number;
  displayHeight: number;
}): number {
  if (!opts.isActive || opts.selectionCount === 0) return 0;
  return Math.round(0.15 * Math.max(opts.displayWidth, opts.displayHeight));
}
```

Run: `bun test src/components/studio/kv-generator/resizeApron.test.ts`
Expected: PASS.

- [ ] **Step 3: Commit the helper**

```bash
git add src/components/studio/kv-generator/resizeApron.ts src/components/studio/kv-generator/resizeApron.test.ts
git commit -m "feat(web): apron size helper for resize ghost overflow"
```

- [ ] **Step 4: Thread the apron through `KvTileOverlayEditor`**

All edits in `KvTileOverlayEditor.tsx`. The invariant: **stored overlay
geometry stays normalized against the FRAME (displayWidth × displayHeight);
the apron is a render-time offset added on build (+a) and removed on
commit/placement (−a).** The two conversions live next to each other below.

4a. Imports:

```ts
import { applyGhostStyle, buildFrameClip, isGhost } from "./ghostOverlay";
import { apronPx } from "./resizeApron";
```

4b. After the `displayHeight` computation (~line 183):

```ts
  // Apron: extra drawable margin so a selected layer's overflow ghost has
  // somewhere to render. Non-zero ONLY while this tile is active and a layer
  // is selected (the ghost trigger). See resizeApron.ts.
  const apron = apronPx({
    isActive,
    selectionCount: effectiveSelectedIds.length,
    displayWidth,
    displayHeight,
  });
  const canvasW = displayWidth + 2 * apron;
  const canvasH = displayHeight + 2 * apron;
```

(If `effectiveSelectedIds` is currently declared after this point, move the
`apron` computation to just after it — it must see the final value.)

4c. Add `apron` to `metricsRef` (both the initial object and the reassignment,
~lines 211–228): `{ aspectW, aspectH, scale, displayWidth, displayHeight,
targetWidth, targetHeight, apron }`.

4d. Canvas mount (~line 249): the mount-once canvas keeps its initial size;
sizing is owned by the resize-in-place effect. Change that effect (~line 344):

```ts
  useEffect(() => {
    if (!canvas) return;
    canvas.setDimensions({ width: canvasW, height: canvasH });
  }, [canvas, canvasW, canvasH]);
```

4e. DOM: the root div (~line 735) keeps its frame-size footprint; wrap the
`<canvas>` in an absolutely-positioned div so Fabric's `.canvas-container`
(which Fabric inserts around the element) rides along:

```tsx
    <div
      data-testid="tile-overlay-editor"
      style={{
        width: displayWidth,
        height: displayHeight,
        position: "relative",
      }}
    >
      {/* The apron div hangs the oversized canvas outside the frame without
          changing the row's layout footprint. KvDragGuides + the inline text
          editor below stay in FRAME coordinates on the root div. */}
      <div
        style={{
          position: "absolute",
          left: -apron,
          top: -apron,
          width: canvasW,
          height: canvasH,
        }}
      >
        <canvas
          ref={canvasElRef}
          style={{ width: canvasW, height: canvasH, display: "block" }}
        />
      </div>
```

(close the new div right after `</canvas>`'s line; the rest of the root's
children — `KvDragGuides`, the text editor IIFE — are unchanged.)

4f. Reconcile signature (~line 528): add `apron` to the `sig` object:
`size: [displayWidth, displayHeight, apron],`.

4g. Reconcile build pass — shift by `+apron` and clip to the frame:

- Base image (~line 553): after `const base = buildBaseImageObject(...)`, add
  `base.set({ left: apron, top: apron });`. Same for the placeholder rect
  (`left: apron, top: apron` instead of `0, 0`).
- Define the frame rect once at the top of the build pass:

```ts
    // Frame rect in CANVAS coordinates. While the apron is on, the canvas
    // edge no longer crops at the frame, so every overlay is clipped to this
    // rect explicitly (visually identical to the apron-off state).
    const frame = { x: apron, y: apron, width: displayWidth, height: displayHeight };
```

- In the overlay loop, after `const { width: w, height: h, centerX: cx, centerY: cy } = overlayRect(ov, board);` change every builder call to use
  `cx + apron` / `cy + apron` (text: `buildTextObject(ov.payload, ov, cx + apron, cy + apron, displayWidth, displayHeight)`; shape:
  `buildShapeObject(ov.payload, cx + apron, cy + apron, w, h, ov.rotation)`;
  image: `buildImageObjectFromElement(el, ov.payload, cx + apron, cy + apron, w, h, ov.rotation)`).
- After `obj.set({ selectable, evented: selectable, noScaleCache: true });`
  (~line 644), add:

```ts
      if (apron > 0) {
        // Canvas edge no longer crops at the frame — clip explicitly.
        obj.set({ clipPath: buildFrameClip(frame) });
        if (effectiveSelectedIds.includes(ov.id)) {
          // Ghost: duplicate built through the SAME builder, dimmed, with the
          // INVERTED frame clip — only the overflow renders. Built sync here
          // (unlike Craft's async clone) because the builder is at hand.
          const ghostSrc =
            ov.payload.type === "text"
              ? buildTextObject(ov.payload, ov, cx + apron, cy + apron, displayWidth, displayHeight)
              : ov.payload.type === "shape"
                ? buildShapeObject(ov.payload, cx + apron, cy + apron, w, h, ov.rotation)
                : buildImageObjectFromElement(
                    overlayImages.get(ov.id)!,
                    ov.payload as Extract<StudioOverlay["payload"], { type: "image" }>,
                    cx + apron,
                    cy + apron,
                    w,
                    h,
                    ov.rotation
                  );
          ghostSrc.set({ originX: "center", originY: "center" });
          const ghost = applyGhostStyle(ghostSrc, ov.id, frame);
          ghostMapRef.current.set(ov.id, ghost);
          c.add(ghost);
          c.sendObjectToBack(ghost);
        }
      }
```

  For the image branch this code runs inside the `else` where `el` is already
  known non-null, so reuse `el` directly instead of `overlayImages.get(ov.id)!`
  — structure the final code so each type branch passes its built ghost
  source, rather than the ternary above, if that reads cleaner. The ternary is
  the *content*; layout is the implementer's choice.
- At the start of the rebuild (`c.clear();` ~line 549) add
  `ghostMapRef.current.clear();` and declare the ref near `nodeMapRef`
  (~line 231):

```ts
  // Ghost objects by overlay id — rebuilt wholesale each reconcile pass.
  const ghostMapRef = useRef<Map<string, fabric.FabricObject>>(new Map());
```

4h. Live gesture mirroring — in the mount effect's `object:moving` handler
(~line 269) and the `object:scaling` / `object:rotating` handlers, mirror to
the ghost. `object:moving` becomes:

```ts
    next.on("object:moving", (e) => {
      const obj = e.target as fabric.FabricObject;
      if (obj instanceof fabric.ActiveSelection) return; // group drag: no guides
      const id = tagOf(obj);
      if (!id) return;
      mirrorGhost(obj, id);
      if (selectionRef.current.length <= 1) emitDragGuides(obj, id);
    });
```

with, above the mount effect:

```ts
  // Ghost tracks the live gesture (drag/scale/rotate) every frame.
  const mirrorGhost = useCallback((obj: fabric.FabricObject, id: string) => {
    const ghost = ghostMapRef.current.get(id);
    if (!ghost) return;
    syncGhostTransform(obj, ghost);
  }, []);
```

(import `syncGhostTransform` in 4a) and in the scaling/rotating handlers:

```ts
    next.on("object:scaling", (e) => {
      lastGestureRef.current = "transform";
      const obj = e.target as fabric.FabricObject;
      const id = tagOf(obj);
      if (id) mirrorGhost(obj, id);
    });
```

(same shape for `object:rotating`).

4i. Commit math — in `commitModified` (~line 403) read the apron and subtract
it (the exact inverse of 4g's `+apron`):

```ts
    const { displayWidth, displayHeight, apron } = metricsRef.current;
    ...
      const centerX = obj.left - apron;
      const centerY = obj.top - apron;
```

4j. Drag guides — in `emitDragGuides` (~line 358) pull `apron` from
`metricsRef.current` and convert the live object back to frame coordinates
(guides render on the frame-sized root div):

```ts
          overlay: {
            cx: obj.left - apron,
            cy: obj.top - apron,
            w: obj.width * (obj.scaleX ?? 1),
            h: obj.height * (obj.scaleY ?? 1),
            rotationDeg: obj.angle ?? 0,
          },
```

4k. Placement clicks — in the `mouse:down` handler (~line 310):

```ts
      const pt = next.getScenePoint(e.e);
      const { width, height } = displaySizeRef.current;
      const { apron } = metricsRef.current;
      const nx = Math.max(0, Math.min(1, (pt.x - apron) / width));
      const ny = Math.max(0, Math.min(1, (pt.y - apron) / height));
```

(`displaySizeRef` stays the FRAME size — verify it is still assigned
`{ width: displayWidth, height: displayHeight }`, not the canvas size.)

4l. Selection-apply effect (~line 663): no coordinate change needed (it works
on object references), but it must never `setActiveObject` a ghost — it maps
ids through `nodeMapRef`, which never contains ghosts, so it is already safe.
Leave as is.

- [ ] **Step 5: Update the row wrappers**

`KvResizeResultRow.tsx` (~line 208): compute once above the `return`:

```ts
  const apronOn =
    isActive &&
    apronPx({
      isActive,
      selectionCount: selectedIds?.length ? selectedIds.length : selectedId ? 1 : 0,
      displayWidth,
      displayHeight: tileDisplayHeight,
    }) > 0;
```

(import `apronPx`). Then change the done-state wrapper's className:

```tsx
          className={[
            "kv-unveil w-full transition-shadow duration-150",
            // While the apron is on, the oversized canvas must escape the
            // wrapper and win the stacking contest against sibling rows.
            // Rounded corners are given up while it's on (accepted in spec);
            // the active ring still marks the frame edge.
            apronOn
              ? "relative z-10 overflow-visible rounded-md"
              : "overflow-hidden rounded-md",
            isActive ? "ring-2 ring-text-inverse/60" : "ring-1 ring-transparent",
          ].join(" ")}
```

`KvResizeOriginalRow.tsx` (~line 113): same computation (its display height is
`displayWidth * (height / width)` — reuse whatever local variable exists, or
compute inline) and change `className="w-full overflow-hidden rounded-md"` to
the same conditional pair (without `kv-unveil`).

- [ ] **Step 6: Type-check + existing editor tests**

Run: `bun test src/components/studio/kv-generator/KvTileOverlayEditor.test.tsx src/components/studio/kv-generator/KvResizeResultRow.test.tsx src/components/studio/kv-generator/KvResizeOriginalRow.test.tsx`
Expected: same pass/fail counts as on HEAD before this task (existing tests
render with no selection ⇒ apron 0 ⇒ geometry identical; any failure here
means the apron leaked into the unselected path — fix before proceeding).
Run: `bunx tsc --noEmit 2>&1 | tail -3` — no new errors vs baseline.

- [ ] **Step 7: Commit**

```bash
git add src/components/studio/kv-generator/KvTileOverlayEditor.tsx src/components/studio/kv-generator/KvResizeResultRow.tsx src/components/studio/kv-generator/KvResizeOriginalRow.tsx
git commit -m "feat(web): resize tile apron + ghosted overflow for selected layers"
```

---

### Task 4: Component tests — ghost lifecycle + apron round-trip

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvTileOverlayEditor.test.tsx` (append a new `describe`)

**Interfaces:**
- Consumes: `onCanvasReady` test hook (existing), `isGhost` / `ghostSourceId` (Task 1), `apronPx` (Task 3).

Follow the file's existing patterns exactly (how it renders the editor, its
overlay fixtures, `within(document.body)` instead of `screen`). The new cases:

- [ ] **Step 1: Write the tests**

```tsx
describe("ghosted overflow (apron)", () => {
  // Fixture: one image overlay hanging 30% past the right edge.
  const overflowing: StudioOverlay = {
    ...baseOverlayFixture, // reuse the file's existing overlay factory
    id: "ov-overflow",
    x: 0.8,
    y: 0.1,
    width: 0.5,
    height: 0.3,
  };

  test("no selection → frame-sized canvas, no ghost objects", async () => {
    let canvas: fabric.Canvas | null = null;
    render(
      <KvTileOverlayEditor
        {...defaultProps} // the file's existing prop bundle
        overlays={[overflowing]}
        selectedId={null}
        isActive
        displayWidth={400}
        onCanvasReady={(c) => (canvas = c)}
      />
    );
    await waitFor(() => expect(canvas).not.toBeNull());
    expect(canvas!.getWidth()).toBe(400);
    expect(canvas!.getObjects().filter(isGhost)).toHaveLength(0);
  });

  test("selecting the overlay grows the canvas by the apron and adds ONE bottom-stack ghost", async () => {
    let canvas: fabric.Canvas | null = null;
    const displayWidth = 400;
    const displayHeight = 400; // square fixture tile
    render(
      <KvTileOverlayEditor
        {...defaultProps}
        overlays={[overflowing]}
        selectedId="ov-overflow"
        isActive
        displayWidth={displayWidth}
        onCanvasReady={(c) => (canvas = c)}
      />
    );
    const apron = apronPx({
      isActive: true,
      selectionCount: 1,
      displayWidth,
      displayHeight,
    });
    await waitFor(() => {
      expect(canvas!.getWidth()).toBe(displayWidth + 2 * apron);
    });
    await waitFor(() => {
      const ghosts = canvas!.getObjects().filter(isGhost);
      expect(ghosts).toHaveLength(1);
      expect(ghostSourceId(ghosts[0])).toBe("ov-overflow");
      // Bottom of the stack — index 0, beneath the base image.
      expect(canvas!.getObjects()[0]).toBe(ghosts[0]);
      // Inverted frame clip + non-interactive.
      expect((ghosts[0].clipPath as fabric.Rect).inverted).toBe(true);
      expect(ghosts[0].evented).toBe(false);
    });
    // The REAL object is clipped to the frame and sits at frame coords + apron.
    const real = canvas!
      .getObjects()
      .find((o) => (o as { data?: { elementId?: string } }).data?.elementId === "ov-overflow")!;
    expect((real.clipPath as fabric.Rect).inverted).toBe(false);
    // overlayRect centerX = (0.8 + 0.5/2) × 400 = 420 → +apron in canvas coords.
    expect(real.left).toBeCloseTo(420 + apron);
  });

  test("apron commit round-trip: a committed drag reproduces frame-normalized coords", async () => {
    // Drive commitModified through the canvas: move the real object by one
    // apron-width and fire object:modified; the committed x must equal the
    // same drag on an apron-less canvas (i.e. the +a/−a pair cancels).
    let canvas: fabric.Canvas | null = null;
    const onChange = jest.fn(); // or the file's mock/capture convention
    render(
      <KvTileOverlayEditor
        {...defaultProps}
        overlays={[overflowing]}
        selectedId="ov-overflow"
        isActive
        displayWidth={400}
        onChange={onChange}
        onCanvasReady={(c) => (canvas = c)}
      />
    );
    await waitFor(() => {
      expect(canvas!.getObjects().some((o) => !isGhost(o) && (o as { data?: { elementId?: string } }).data?.elementId === "ov-overflow")).toBe(true);
    });
    const real = canvas!
      .getObjects()
      .find((o) => (o as { data?: { elementId?: string } }).data?.elementId === "ov-overflow")!;
    real.set({ left: real.left + 40, top: real.top }); // drag 40px right
    canvas!.fire("object:modified", { target: real });
    await waitFor(() => expect(onChange).toHaveBeenCalled());
    const next = onChange.mock.calls.at(-1)![0] as StudioOverlay[];
    const moved = next.find((o) => o.id === "ov-overflow")!;
    // 40px on a 400px frame = +0.1 normalized, regardless of the apron.
    expect(moved.x).toBeCloseTo(0.8 + 0.1, 5);
  });
});
```

Adapt fixture/prop names to the file's actual helpers — the assertions above
are the contract; the scaffolding must match the existing file. If the file
has no image-overlay fixture that loads in jsdom, use a **shape** overlay
instead (shapes build synchronously with no image load) — the ghost path is
type-agnostic by design.

- [ ] **Step 2: Run the new tests**

Run: `bun test src/components/studio/kv-generator/KvTileOverlayEditor.test.tsx`
Expected: new describe PASSES; pre-existing cases unchanged.

- [ ] **Step 3: Commit**

```bash
git add src/components/studio/kv-generator/KvTileOverlayEditor.test.tsx
git commit -m "test(web): ghost lifecycle + apron round-trip on the resize tile editor"
```

---

### Task 5: Full verification + manual e2e

- [ ] **Step 1: Full unit-test sweep**

Run (from `web/`): `bun test src/components/studio/kv-generator/`
Expected: pass/fail counts equal to HEAD-before-this-work plus the new
passing tests (the repo has a known baseline of RTL-`screen` failures — only
the DELTA matters; record both numbers in the final report).

- [ ] **Step 2: Build**

Run: `bun run build`
Expected: completes (build ignores type errors by config; this checks
bundling/imports).

- [ ] **Step 3: Manual e2e (requires Daffa's browser + running services)**

With `bun dev` (or the running dev server) on a KV file that has overlays:

1. **Craft:** select an overlay, drag it partially off its board → the
   outside part renders dimmed (≈25%) and live-tracks the drag; drop, undo,
   re-drag from the ghost region (grab OUTSIDE the board) → drag works.
2. **Craft multi-board:** drag an overlay from board A toward board B → the
   ghost never draws OVER board B's artwork (it disappears beneath it).
3. **Craft blend-mode layer:** give a layer multiply/screen blend, select it
   → ghost renders normally dimmed (no blend against the backdrop).
4. **Resize:** activate a tile, select an overlay → tile shows ghost overflow
   without the row column shifting; drag from the ghost region works; drag
   guides + distance badges still measure against the FRAME edge, not the
   apron edge.
5. **Resize deselect:** click empty apron → selection clears, apron
   collapses; verify the next click lands where expected.
6. **Download:** download the tile and a Craft board → ghost never appears in
   the exported file.

Expected: all six pass. Fix and re-run on any failure (systematic-debugging
skill on anything non-obvious).

- [ ] **Step 4: Final commit if fixes were needed; report**

Report includes: test delta numbers, build result, e2e checklist outcomes.

---

## Self-review notes (already applied)

- Spec coverage: §1 module → Task 1; §2 Craft → Task 2; §3 apron → Task 3;
  §4 edge cases → covered by Task 3 (deselect/collapse) + Task 5 e2e;
  §5 testing → Tasks 1, 3, 4, 5. Out-of-scope items have no tasks (correct).
- The spec's "ghosts inserted at the bottom of the stack" meets Craft's
  board-image `insertAt(0, …)`: a board image (re)loading after ghost
  creation lands BENEATH the ghost until the next gesture frame or selection
  change re-sends the ghost to back (`sendObjectToBack` in the gesture
  mirrors). Rare, self-healing — accepted; noted in Task 2 Step 3's comment.
- Type consistency: `FrameRect` is structurally identical to Craft's
  `WorldRect` (`{x, y, width, height}`) — `overlayHostRect` results pass
  directly. `apronPx` signature identical at all three call sites.
