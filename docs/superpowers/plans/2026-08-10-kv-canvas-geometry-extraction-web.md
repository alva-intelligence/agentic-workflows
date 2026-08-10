# KV Canvas Geometry Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the overlay geometry math out of KV's five renderers into one pure, tested module that all of them consume — so preview and download can no longer drift apart.

**Architecture:** A new pure module `overlayGeometry.ts` owns the normalized→pixel conversion (position, size, rotation pivot, text metrics) and its inverse. Every renderer — the offscreen flatten, both Resize surfaces, and both Craft canvases — is switched to call it. No renderer keeps its own copy of the formula. This is step 1 of the surface unification spec; it is deliberately inert except for one agreed behavior fix.

**Tech Stack:** TypeScript, React, Konva / react-konva, Fabric.js v7, `bun test`.

**Spec:** `docs/superpowers/specs/2026-08-10-kv-canvas-surface-unification-design.md`

## Global Constraints

- Tests run with `bun test` from `web/` (bunfig preloads jest-dom). Do **not** use `bunx vitest`.
- The real gate is `bun run build` — `bun run build` does not type-check on its own, so also run `bunx tsc --noEmit` before the final commit of each task.
- Test files are colocated next to the module they test (`foo.ts` → `foo.test.ts`).
- Downloaded output must be byte-identical before and after this plan, with the single exception recorded in Task 6/7 (legacy text fallback on the two Craft canvases).
- Follow the surrounding comment style: these files carry long explanatory comments stating *why* a rule exists. Preserve those comments when you move the code they describe — move the comment with it.
- Do not change any overlay's persisted shape (`StudioOverlay`). This plan touches rendering only.

## Agreed behavior change (one, deliberate)

Text overlays with no explicit `payload.fontSize` (created before custom fonts landed) currently render at **two different sizes**:

| Renderer | Current fallback |
|---|---|
| `renderBoardStage.ts` (every download) | full box height |
| `KvResizeTileStage.tsx` | full box height |
| `KvTileOverlayEditor.tsx` | full box height |
| `KvFabricCanvas.tsx:1537` (Craft) | `0.8 ×` box height |
| `KvKonvaCanvas.tsx:1876` (Craft fallback) | `0.8 ×` box height |

**Decision: full box height wins**, because downloads are artifacts that already exist in the wild and must not change. The visible consequence is that legacy text on the two Craft canvases gets ~25% larger, matching what those files already download as. This is called out in Tasks 6 and 7.

---

### Task 1: Pure overlay rect geometry

**Files:**
- Create: `web/src/components/studio/kv-generator/overlayGeometry.ts`
- Test: `web/src/components/studio/kv-generator/overlayGeometry.test.ts`

**Interfaces:**
- Consumes: `StudioOverlay` from `@/types/studio`
- Produces:
  - `type BoardBox = { x?: number; y?: number; width: number; height: number }`
  - `type OverlayRect = { x: number; y: number; width: number; height: number; centerX: number; centerY: number; rotation: number }`
  - `overlayRect(ov: OverlayGeom, board: BoardBox): OverlayRect`
  - `overlayNormFromRect(rect: {centerX, centerY, width, height}, board: BoardBox): {x, y, width, height}`
  - `type OverlayGeom = Pick<StudioOverlay, "x" | "y" | "width" | "height" | "rotation">`

- [ ] **Step 1: Write the failing test**

Create `web/src/components/studio/kv-generator/overlayGeometry.test.ts`:

```ts
import { describe, expect, it } from "bun:test";

import { overlayNormFromRect, overlayRect } from "./overlayGeometry";

const ov = { x: 0.25, y: 0.5, width: 0.5, height: 0.25, rotation: 0 };

describe("overlayRect", () => {
  it("denormalizes against board width and height", () => {
    const r = overlayRect(ov, { width: 1000, height: 2000 });
    expect(r.x).toBe(250);
    expect(r.y).toBe(1000);
    expect(r.width).toBe(500);
    expect(r.height).toBe(500);
  });

  it("puts the rotation pivot at the visual center", () => {
    const r = overlayRect(ov, { width: 1000, height: 2000 });
    expect(r.centerX).toBe(500);
    expect(r.centerY).toBe(1250);
  });

  it("offsets by the board origin when the board is placed in a world", () => {
    const r = overlayRect(ov, { x: 100, y: -50, width: 1000, height: 2000 });
    expect(r.x).toBe(350);
    expect(r.y).toBe(950);
    expect(r.centerX).toBe(600);
    expect(r.centerY).toBe(1200);
  });

  it("carries rotation through untouched", () => {
    const r = overlayRect({ ...ov, rotation: 42 }, { width: 100, height: 100 });
    expect(r.rotation).toBe(42);
  });
});

describe("overlayNormFromRect", () => {
  it("round-trips overlayRect exactly", () => {
    const board = { x: 100, y: -50, width: 1000, height: 2000 };
    const r = overlayRect(ov, board);
    expect(overlayNormFromRect(r, board)).toEqual({
      x: ov.x,
      y: ov.y,
      width: ov.width,
      height: ov.height,
    });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd web && bun test src/components/studio/kv-generator/overlayGeometry.test.ts
```

Expected: FAIL — cannot resolve module `./overlayGeometry`.

- [ ] **Step 3: Write minimal implementation**

Create `web/src/components/studio/kv-generator/overlayGeometry.ts`:

```ts
import type { StudioOverlay } from "@/types/studio";

/**
 * THE single source of truth for turning an overlay's normalized geometry into
 * pixels, shared by every KV render path: the offscreen flatten
 * (renderBoardStage), both Resize surfaces, and both Craft canvases.
 *
 * This module exists because that formula used to be written out five times.
 * The display IS the promise the download has to keep — when one copy drifted,
 * the preview silently stopped matching the exported file. Add rules here, not
 * in a renderer.
 */

/** The board an overlay is hosted by, in whatever pixel space the caller is
 *  drawing in (native pixels for export, scaled display pixels for a preview,
 *  world units for the multi-board canvas). `x`/`y` are the board's top-left in
 *  that space — omit them when the board IS the origin (the export stage). */
export type BoardBox = {
  x?: number;
  y?: number;
  width: number;
  height: number;
};

/** Just the geometry fields — so callers can pass a draft/live-drag object that
 *  isn't a full persisted overlay. */
export type OverlayGeom = Pick<
  StudioOverlay,
  "x" | "y" | "width" | "height" | "rotation"
>;

export type OverlayRect = {
  /** Top-left corner in the caller's pixel space. */
  x: number;
  y: number;
  width: number;
  height: number;
  /** Visual center — the rotation pivot. Konva nodes take this as x/y with
   *  offsetX/Y = width/2, height/2; Fabric objects take it as left/top because
   *  Fabric v7 defaults to a center origin. */
  centerX: number;
  centerY: number;
  /** Degrees, passed through unchanged. */
  rotation: number;
};

export function overlayRect(ov: OverlayGeom, board: BoardBox): OverlayRect {
  const x = (board.x ?? 0) + ov.x * board.width;
  const y = (board.y ?? 0) + ov.y * board.height;
  const width = ov.width * board.width;
  const height = ov.height * board.height;
  return {
    x,
    y,
    width,
    height,
    centerX: x + width / 2,
    centerY: y + height / 2,
    rotation: ov.rotation,
  };
}

/** Inverse of `overlayRect` — what a drag/transform commit writes back. Kept
 *  next to the forward transform on purpose: when these two disagree, an
 *  overlay drifts a little on every drag. */
export function overlayNormFromRect(
  rect: { centerX: number; centerY: number; width: number; height: number },
  board: BoardBox,
): { x: number; y: number; width: number; height: number } {
  return {
    x: (rect.centerX - rect.width / 2 - (board.x ?? 0)) / board.width,
    y: (rect.centerY - rect.height / 2 - (board.y ?? 0)) / board.height,
    width: rect.width / board.width,
    height: rect.height / board.height,
  };
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd web && bun test src/components/studio/kv-generator/overlayGeometry.test.ts
```

Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add web/src/components/studio/kv-generator/overlayGeometry.ts web/src/components/studio/kv-generator/overlayGeometry.test.ts
git commit -m "feat(web): add one pure module for KV overlay rect geometry"
```

---

### Task 2: Pure text metrics

**Files:**
- Modify: `web/src/components/studio/kv-generator/overlayGeometry.ts`
- Test: `web/src/components/studio/kv-generator/overlayGeometry.test.ts`

**Interfaces:**
- Consumes: `overlayRect`, `BoardBox` from Task 1
- Produces:
  - `type OverlayTextMetrics = { fontSizePx: number; boxWidth: number; letterSpacingPx: number; lineHeight: number; align: "left" | "center" | "right" | "justify" }`
  - `overlayTextMetrics(ov: OverlayGeom & { payload: TextPayload }, board: BoardBox): OverlayTextMetrics`

- [ ] **Step 1: Write the failing test**

Append to `web/src/components/studio/kv-generator/overlayGeometry.test.ts`:

```ts
import { overlayTextMetrics } from "./overlayGeometry";

const textOv = (payload: Record<string, unknown>) => ({
  x: 0.1,
  y: 0.1,
  width: 0.5,
  height: 0.2,
  rotation: 0,
  payload: { type: "text" as const, content: "hi", color: "#fff", ...payload },
});

describe("overlayTextMetrics", () => {
  it("scales an explicit fontSize by board height", () => {
    const m = overlayTextMetrics(textOv({ fontSize: 0.05 }), {
      width: 1000,
      height: 2000,
    });
    expect(m.fontSizePx).toBe(100);
  });

  it("falls back to the FULL box height when fontSize is absent", () => {
    // Legacy overlays. Both Craft canvases used to use 0.8 * box height here,
    // which made them disagree with every download. Full height wins.
    const m = overlayTextMetrics(textOv({}), { width: 1000, height: 2000 });
    expect(m.fontSizePx).toBe(400);
  });

  it("never returns a font size below 1px", () => {
    const m = overlayTextMetrics(textOv({ fontSize: 0 }), {
      width: 10,
      height: 10,
    });
    expect(m.fontSizePx).toBe(1);
  });

  it("scales letter spacing by board height, like fontSize", () => {
    const m = overlayTextMetrics(textOv({ letterSpacing: 0.01 }), {
      width: 1000,
      height: 2000,
    });
    expect(m.letterSpacingPx).toBe(20);
  });

  it("wraps to the box width, clamped to at least 1px", () => {
    const m = overlayTextMetrics(textOv({}), { width: 1000, height: 2000 });
    expect(m.boxWidth).toBe(500);
    const zero = overlayTextMetrics({ ...textOv({}), width: 0 }, {
      width: 1000,
      height: 2000,
    });
    expect(zero.boxWidth).toBe(1);
  });

  it("defaults align to center and lineHeight to 1", () => {
    const m = overlayTextMetrics(textOv({}), { width: 100, height: 100 });
    expect(m.align).toBe("center");
    expect(m.lineHeight).toBe(1);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd web && bun test src/components/studio/kv-generator/overlayGeometry.test.ts
```

Expected: FAIL — `overlayTextMetrics` is not exported.

- [ ] **Step 3: Write minimal implementation**

Append to `web/src/components/studio/kv-generator/overlayGeometry.ts`:

```ts
type TextPayload = Extract<StudioOverlay["payload"], { type: "text" }>;

export type OverlayTextMetrics = {
  fontSizePx: number;
  /** Wrap width. Text reflows to this; height derives from the line count, so
   *  it is intentionally not part of this type. */
  boxWidth: number;
  letterSpacingPx: number;
  lineHeight: number;
  align: "left" | "center" | "right" | "justify";
};

export function overlayTextMetrics(
  ov: OverlayGeom & { payload: TextPayload },
  board: BoardBox,
): OverlayTextMetrics {
  const rect = overlayRect(ov, board);
  // `fontSize` is stored NORMALIZED against the host board's height — the same
  // convention as x/y/width/height — so it survives a move to a board of a
  // different size and matches on export.
  //
  // Legacy overlays predate that field. They fall back to the FULL box height,
  // which is what every download has always produced. The two Craft canvases
  // used 0.8 * box height instead, so legacy text drew ~20% small on canvas and
  // then exported bigger. Downloads are artifacts already in the wild, so the
  // canvases were the ones that had to move.
  const fontSizePx = Math.max(
    1,
    ov.payload.fontSize != null
      ? ov.payload.fontSize * board.height
      : rect.height,
  );
  return {
    fontSizePx,
    boxWidth: Math.max(1, rect.width),
    letterSpacingPx: (ov.payload.letterSpacing ?? 0) * board.height,
    lineHeight: ov.payload.lineHeight ?? 1,
    align: ov.payload.textAlign ?? "center",
  };
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd web && bun test src/components/studio/kv-generator/overlayGeometry.test.ts
```

Expected: PASS, 11 tests.

- [ ] **Step 5: Type-check and commit**

```bash
cd web && bunx tsc --noEmit
git add web/src/components/studio/kv-generator/overlayGeometry.ts web/src/components/studio/kv-generator/overlayGeometry.test.ts
git commit -m "feat(web): add pure text metrics to KV overlay geometry"
```

---

### Task 3: Switch the export path (`renderBoardStage.ts`)

This is the canonical renderer — every download goes through it. Its output must not change at all.

**Files:**
- Modify: `web/src/components/studio/kv-generator/renderBoardStage.ts:104-199`
- Test: `web/src/components/studio/kv-generator/renderBoardStage.test.ts` (existing, must stay green)

**Interfaces:**
- Consumes: `overlayRect`, `overlayTextMetrics` from Tasks 1–2
- Produces: nothing new — same exported functions, same output

- [ ] **Step 1: Record the current behavior as a baseline**

```bash
cd web && bun test src/components/studio/kv-generator/renderBoardStage.test.ts
```

Expected: PASS. Note the test count — it must be identical after the change.

- [ ] **Step 2: Add the import**

In `renderBoardStage.ts`, alongside the existing local imports:

```ts
import { overlayRect, overlayTextMetrics } from "./overlayGeometry";
```

- [ ] **Step 3: Replace the per-overlay geometry block**

Replace lines 107–114 (the `ox`/`oy`/`ow`/`oh`/`cx`/`cy` block, including its comment) with:

```ts
    const rect = overlayRect(ov, { width: targetWidth, height: targetHeight });
    const { width: ow, height: oh, centerX: cx, centerY: cy } = rect;
```

Keep the existing comment about rotating around the visual center by moving it
onto this block — it explains why `cx`/`cy` exist.

- [ ] **Step 4: Replace the text metrics block**

Replace the `fontSizePx`, `boxW`, and `norm2px` derivations in the
`ov.payload.type === "text"` branch with:

```ts
      const metrics = overlayTextMetrics(
        { ...ov, payload: ov.payload },
        { width: targetWidth, height: targetHeight },
      );
      const fontSizePx = metrics.fontSizePx;
      const boxW = metrics.boxWidth;
```

Then in the `new Konva.Text({...})` config, replace:
- `align: ov.payload.textAlign ?? "center"` → `align: metrics.align`
- `lineHeight: ov.payload.lineHeight ?? 1` → `lineHeight: metrics.lineHeight`
- `letterSpacing: (ov.payload.letterSpacing ?? 0) * norm2px` → `letterSpacing: metrics.letterSpacingPx`

Leave `konvaTextFill(ov.payload, boxW, fontSizePx)` exactly as it is.

- [ ] **Step 5: Run the export tests**

```bash
cd web && bun test src/components/studio/kv-generator/renderBoardStage.test.ts
```

Expected: PASS, same count as Step 1. Any change here means the export output moved — stop and diff the numbers rather than adjusting the test.

- [ ] **Step 6: Type-check and commit**

```bash
cd web && bunx tsc --noEmit
git add web/src/components/studio/kv-generator/renderBoardStage.ts
git commit -m "refactor(web): render exports through the shared overlay geometry"
```

---

### Task 4: Switch the Resize tile preview (`KvResizeTileStage.tsx`)

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvResizeTileStage.tsx:101-130`
- Test: `web/src/components/studio/kv-generator/KvResizeTileStage.test.ts` (existing, must stay green)

**Interfaces:**
- Consumes: `overlayRect`, `overlayTextMetrics`
- Produces: nothing new

- [ ] **Step 1: Run the existing test as a baseline**

```bash
cd web && bun test src/components/studio/kv-generator/KvResizeTileStage.test.ts
```

Expected: PASS. Note the count.

- [ ] **Step 2: Replace the geometry block**

This stage draws at `aspectW * scale` × `aspectH * scale`, so that is its board
box. Replace the `x`/`y`/`w`/`h`/`cx`/`cy` derivations with:

```ts
            const board = {
              width: aspectW * scale,
              height: aspectH * scale,
            };
            const { width: w, height: h, centerX: cx, centerY: cy } =
              overlayRect(ov, board);
```

Keep the existing comment explaining that height denormalizes against canvas
height and must match the export — move it above this block.

- [ ] **Step 3: Replace the text metrics**

Replace the `fontSizePx` ternary and the `norm2px` derivation with:

```ts
              const metrics = overlayTextMetrics(
                { ...ov, payload: ov.payload },
                board,
              );
```

Then use `metrics.fontSizePx`, `metrics.boxWidth`, `metrics.letterSpacingPx`,
`metrics.lineHeight`, and `metrics.align` at their existing call sites.

- [ ] **Step 4: Run the test**

```bash
cd web && bun test src/components/studio/kv-generator/KvResizeTileStage.test.ts
```

Expected: PASS, same count as Step 1.

- [ ] **Step 5: Type-check and commit**

```bash
cd web && bunx tsc --noEmit
git add web/src/components/studio/kv-generator/KvResizeTileStage.tsx
git commit -m "refactor(web): render resize tile previews through shared geometry"
```

---

### Task 5: Switch the Resize tile editor (`KvTileOverlayEditor.tsx`)

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvTileOverlayEditor.tsx:560-575` and the drag/transform commit
- Test: `web/src/components/studio/kv-generator/KvTileOverlayEditor.test.tsx` (existing, must stay green)

**Interfaces:**
- Consumes: `overlayRect`, `overlayTextMetrics`, `overlayNormFromRect`
- Produces: nothing new

- [ ] **Step 1: Run the existing test as a baseline**

```bash
cd web && bun test src/components/studio/kv-generator/KvTileOverlayEditor.test.tsx
```

Expected: PASS. Note the count.

- [ ] **Step 2: Replace the forward geometry**

Same substitution as Task 4, with this editor's board box:

```ts
              const board = { width: displayWidth, height: displayHeight };
              const { width: w, height: h, centerX: cx, centerY: cy } =
                overlayRect(ov, board);
```

- [ ] **Step 3: Replace the text metrics**

```ts
                const metrics = overlayTextMetrics(
                  { ...ov, payload: ov.payload },
                  board,
                );
```

Use `metrics.fontSizePx`, `metrics.boxWidth`, `metrics.letterSpacingPx`,
`metrics.lineHeight`, and `metrics.align` at their existing call sites.

- [ ] **Step 4: Replace the commit-back math with the inverse**

At lines 711–719 the transform handler converts the node's center back to a
normalized top-left by hand. Replace:

```ts
                // Convert center back to top-left for storage.
                return applyOverlayTransform(
                  acc,
                  id,
                  newW / displayWidth,
                  newH / displayHeight,
                  newR,
                  (centerX - newW / 2) / displayWidth,
                  (centerY - newH / 2) / displayHeight,
                );
```

with:

```ts
                // Center back to normalized top-left — the exact inverse of
                // the overlayRect() the node was drawn from.
                const norm = overlayNormFromRect(
                  { centerX, centerY, width: newW, height: newH },
                  { width: displayWidth, height: displayHeight },
                );
                return applyOverlayTransform(
                  acc,
                  id,
                  norm.width,
                  norm.height,
                  newR,
                  norm.x,
                  norm.y,
                );
```

Leave the snap-guide math at lines 332–345 alone — those compute guide
positions, not stored geometry.

- [ ] **Step 5: Run the test**

```bash
cd web && bun test src/components/studio/kv-generator/KvTileOverlayEditor.test.tsx
```

Expected: PASS, same count as Step 1.

- [ ] **Step 6: Type-check and commit**

```bash
cd web && bunx tsc --noEmit
git add web/src/components/studio/kv-generator/KvTileOverlayEditor.tsx
git commit -m "refactor(web): render the resize tile editor through shared geometry"
```

---

### Task 6: Switch the Craft Konva fallback (`KvKonvaCanvas.tsx`) — includes the agreed font fix

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvKonvaCanvas.tsx:1399-1400`, `:1776-1780`, `:1841-1846`, `:1876`
- Test: `web/src/components/studio/kv-generator/KvKonvaCanvas.overlays.test.tsx`

**Interfaces:**
- Consumes: `overlayRect`, `overlayTextMetrics`, `overlayNormFromRect`
- Produces: nothing new

- [ ] **Step 1: Write the failing test for the font fallback**

This file already declares an identical `CanvasBackedFakeImage` class inline
inside two separate tests (the plain `FakeImage` stub gets the component past
its loading spinner, but Konva's real draw pass rejects it as a `drawImage`
source). Lift that class to module scope next to `FakeImage`, delete the two
inline copies, and have all three tests use the shared one.

Then append this test. It asserts the fallback **relatively** — a legacy text
overlay must draw at the same size as one whose explicit `fontSize` equals its
box height — so it does not depend on knowing the computed `fit` rect:

```tsx
  it("draws legacy text (no fontSize) at full box height, matching export", async () => {
    // Legacy overlays predate `payload.fontSize`. Every download renders them
    // at the full box height; this canvas used to render them at 0.8x, so the
    // same KV looked smaller on screen than in its own downloaded file.
    // Asserting against an EXPLICIT fontSize equal to the box height pins the
    // fallback to the export's rule without hardcoding the fit geometry.
    g.Image = CanvasBackedFakeImage;
    if (g.window) g.window.Image = CanvasBackedFakeImage;

    const legacy: StudioOverlay = {
      ...overlay,
      id: "t-legacy",
      height: 0.2,
      payload: { type: "text", content: "legacy", color: "#FFFFFF" },
    };
    const explicit: StudioOverlay = {
      ...legacy,
      id: "t-explicit",
      // fontSize is normalized against board height — 0.2 == the box height.
      payload: { ...legacy.payload, fontSize: 0.2 },
    };

    const fontSizeOf = async (ov: StudioOverlay) => {
      const view = render(
        <KvKonvaCanvas
          generation={generation}
          width={400}
          height={300}
          overlays={[ov]}
          tool="cursor"
          selectable={false}
        />
      );
      let size = 0;
      await waitFor(() => {
        const stage = Konva.stages[Konva.stages.length - 1];
        const text = stage?.find("Text")[0] as Konva.Text | undefined;
        expect(text).toBeTruthy();
        size = text!.fontSize();
      });
      view.unmount();
      return size;
    };

    expect(await fontSizeOf(legacy)).toBe(await fontSizeOf(explicit));
  });
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd web && bun test src/components/studio/kv-generator/KvKonvaCanvas.overlays.test.tsx
```

Expected: FAIL — receives 160, expects 200.

- [ ] **Step 3: Replace the geometry and the font fallback**

At lines 1399–1400 and 1777–1778, replace the `pw`/`ph` derivations with:

```ts
    const rect = overlayRect(overlay, fit);
    const pw = rect.width;
    const ph = rect.height;
```

`fit` already carries `x`, `y`, `width`, `height`, so it satisfies `BoardBox`
directly.

At line 1876, replace the `ph * 0.8` font fallback with the shared metrics:

```ts
        const metrics = overlayTextMetrics({ ...overlay, payload: overlay.payload }, fit);
```

and use `metrics.fontSizePx` where the old expression was.

At lines 1843–1844, replace the commit-back arithmetic with:

```ts
      const next = overlayNormFromRect(
        { centerX: node.x(), centerY: node.y(), width: newPw, height: newPh },
        fit,
      );
```

using the `newPw` / `newPh` the handler already computes at 1808–1809.

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd web && bun test src/components/studio/kv-generator/KvKonvaCanvas.overlays.test.tsx
```

Expected: PASS.

- [ ] **Step 5: Type-check and commit**

```bash
cd web && bunx tsc --noEmit
git add web/src/components/studio/kv-generator/KvKonvaCanvas.tsx web/src/components/studio/kv-generator/KvKonvaCanvas.overlays.test.tsx
git commit -m "fix(web): legacy KV text now matches its download on the Konva canvas"
```

---

### Task 7: Switch the Craft Fabric canvas (`KvFabricCanvas.tsx`) — includes the agreed font fix

Fabric v7 defaults objects to a **center** origin, which is why the existing
code adds `w / 2` to `left`/`top`. That is exactly `OverlayRect.centerX/centerY`,
so the substitution is direct.

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvFabricCanvas.tsx:1499-1504`, `:1535-1538`
- Test: none (Fabric needs a real canvas context; jsdom has none). Covered by Tasks 1–2 plus manual verification.

**Interfaces:**
- Consumes: `overlayRect`, `overlayTextMetrics`
- Produces: nothing new

- [ ] **Step 1: Replace the geometry block**

Replace lines 1499–1504 with:

```ts
      // Fabric v7 objects default to a CENTER origin, so left/top take the
      // overlay's visual center — which is also the rotation pivot.
      const rect = overlayRect(overlay, host);
      const w = rect.width;
      const h = rect.height;
      const left = rect.centerX;
      const top = rect.centerY;
```

`host` already carries `x`, `y`, `width`, `height`, so it satisfies `BoardBox`.

- [ ] **Step 2: Replace the font fallback**

Replace lines 1535–1538 with:

```ts
        const metrics = overlayTextMetrics(
          { ...overlay, payload: overlay.payload },
          host,
        );
        const fontPx = metrics.fontSizePx;
```

This is the behavior change: legacy text (no `fontSize`) grows from `0.8 ×` box
height to the full box height, matching what these files already download as.

- [ ] **Step 3: Build and type-check**

```bash
cd web && bunx tsc --noEmit && bun run build
```

Expected: both clean.

- [ ] **Step 4: Verify by hand**

With the dev server running, open a KV in Craft and confirm:
- overlays sit exactly where they did before (compare against a screenshot taken before this task)
- dragging, resizing, and rotating an overlay still lands it in the same place
- a KV containing **legacy** text (no explicit font size) now shows that text at the size its download produces — open the download side by side to confirm they match

- [ ] **Step 5: Commit**

```bash
git add web/src/components/studio/kv-generator/KvFabricCanvas.tsx
git commit -m "fix(web): legacy KV text now matches its download on the craft canvas"
```

---

### Task 8: Full-suite check and cleanup

**Files:**
- Modify: none expected

- [ ] **Step 1: Run the KV test suite**

```bash
cd web && bun test src/components/studio/kv-generator
```

Expected: PASS. Compare against the pre-plan baseline — see the note on known
unrelated failures below before treating anything as a regression.

- [ ] **Step 2: Confirm no renderer kept a private copy of the formula**

```bash
cd web && grep -rn "\* fit.width\|\* fit.height\|\* host.width\|\* host.height\|\* targetWidth\|\* targetHeight\|\* aspectW\|\* aspectH" src/components/studio/kv-generator --include="*.ts" --include="*.tsx" | grep -v overlayGeometry
```

Expected: no hits that compute an overlay's position or size. Board-sizing and
image-fitting hits are fine — read each one rather than assuming.

- [ ] **Step 3: Build**

```bash
cd web && bun run build
```

Expected: clean.

- [ ] **Step 4: Commit any stragglers**

```bash
git status
```

Expected: clean tree. If not, commit what remains with a descriptive message.

## Baseline note for whoever runs the suite

Some failures in `web/` are pre-existing and unrelated to this plan (React
Testing Library's `screen` is broken under bun — affected suites use
`within(document.body)` instead). **Record the failing set before starting**, so
a pre-existing red is not mistaken for a regression introduced here:

```bash
cd web && bun test src/components/studio/kv-generator 2>&1 | tail -30
```

## What this plan does not do

This is step 1 of four in the spec. It does not merge any surface — after this
plan there are still three live renderers, they just no longer each own a copy
of the math. The remaining steps get their own plans, written once this module
exists so they can be specified against its real API:

- **Step 2** — generalize `KvFabricCanvas` into an engine plus a layout strategy; move Craft onto it with identical behavior.
- **Step 3** — build the Resize view on that engine, with per-board chrome positioned in world space via `worldPointToScreen`.
- **Step 4** — delete `KvResizeTileStage`, `KvTileOverlayEditor`, the Konva half of `KvResizeResultRow`, and `KvKonvaCanvas`.
