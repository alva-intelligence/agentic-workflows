# KV Overlay Board Clipping — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An overlay never renders outside the board it belongs to — on the Craft canvas, in the tile editor, and in the downloaded file alike.

**Architecture:** Konva already clips overlays to the fitted board rect. Fabric (the main Craft canvas) and `renderBoardStage` (the export path) do not. This plan brings both in line, so all three surfaces agree.

**Tech Stack:** Next.js 16, React 19, TypeScript, Fabric.js v6, Konva, Bun (test runner).

## Global Constraints

- **Tests run with `bun test`, NOT `bunx vitest`.** Files under `src/lib` import from `"vitest"`; files under `src/components` import from `"bun:test"` and must use `within(document.body)`, **never `screen`** — RTL's `screen` singleton is broken under this repo's bun setup and is the single cause of the ~129 pre-existing failures in `src/components/studio`. Don't chase those.
- **The real build gate is `bun run build`.**
- **Clipping is VISUAL ONLY.** Overlay geometry must not change. The server accepts `x`/`y` from `-5..5` and sizes up to `5`, PSD import deliberately preserves layers that bleed past the artboard, and a user must still be able to drag a clipped layer back into view. Never clamp or rewrite stored coordinates.
- **The camera is a `setViewportTransform`** (`KvFabricCanvas.tsx:1010`), so Fabric objects hold world coordinates and pan/zoom is applied by the transform. A clip rect expressed in the same world space as the object's `left`/`top` therefore follows the camera for free — do NOT add per-frame camera syncing.
- **Branch:** `feature/daffa/vc-kv-overlay-board-clipping`, already created and **branched off `feature/daffa/vc-kv-psd-import-fidelity`** — NOT off `develop`.

  This work depends on two things that live on the PSD branch and have not merged to `develop` yet:
  1. `renderBoardStage` renders base + overlays on a **single Konva Layer**. On `develop` they are still two Layers. Task 2's "do not restructure the layers" instruction only makes sense against the merged version.
  2. Task 1 keys the seven overlay-assignment sites off `globalCompositeOperation: resolveBlendMode(...)`, which only exists on the PSD branch.

  Consequence: this branch's PR must merge **after** the PSD import PR, or be folded into it.

---

### Task 1: Clip overlays to their board on the Fabric canvas

**Files:**
- Modify: `src/components/studio/kv-generator/KvFabricCanvas.tsx`

**Interfaces:**
- Consumes: `overlayHostRect(overlay): WorldRect | null` (already exists, `:676`) — the world rect of the board an overlay is bound to, resolved through the board's version chain so a polish rekey doesn't orphan it.
- Produces: every overlay object carries a `clipPath` matching its host board's rect.

Today an overlay dragged past the board edge keeps rendering over the surrounding canvas. Konva already crops this (`KvKonvaCanvas.tsx:1304`); Fabric does not.

- [ ] **Step 1: Establish the baseline**

```bash
cd web && bun run build && bun test src/components/studio
```

Record both results. The component suite's failures are pre-existing (see Global Constraints) — capture the exact failing test *names*, not just the count, so you can prove you added none.

- [ ] **Step 2: Add a clip-path helper**

In `KvFabricCanvas.tsx`, near the other overlay helpers, add:

```ts
  // Clip an overlay to the board it belongs to. Fabric applies the camera via
  // setViewportTransform, so a rect built in the SAME world space as the
  // object's left/top follows pan and zoom without any per-frame syncing.
  //
  // absolutePositioned: the rect is placed against the canvas, not relative to
  // the object it clips — otherwise it would ride along with the overlay and
  // clip nothing. Purely visual: stored geometry is untouched, so a layer
  // dragged off-board can still be dragged back.
  const buildOverlayClip = useCallback(
    (overlay: StudioOverlay): fabric.Rect | undefined => {
      const host = overlayHostRect(overlay);
      if (!host) return undefined;
      return new fabric.Rect({
        left: host.x,
        top: host.y,
        width: host.width,
        height: host.height,
        absolutePositioned: true,
      });
    },
    [overlayHostRect]
  );
```

- [ ] **Step 3: Apply it wherever an overlay object is created or updated**

Set `clipPath: buildOverlayClip(overlay)` alongside the existing `globalCompositeOperation: resolveBlendMode(overlay.payload)` at **every** site — there are seven, and missing one produces an intermittent bug where clipping is correct until the object is reused:

- text reuse (`found.set`) and text creation (`new fabric.Textbox`)
- image reuse-same-src, image reuse-src-changed, and image creation (inside `fromURL(...).then`)
- shape reuse, and the shared `common` config every shape-creation branch spreads

Grep for `globalCompositeOperation: resolveBlendMode` and add the clip at each hit — that assignment already marks exactly the right set of sites.

- [ ] **Step 4: Verify the build and tests**

```bash
cd web && bun run build && bun test src/components/studio
```

Expected: build succeeds; failing test *names* identical to Step 1.

- [ ] **Step 5: Verify visually — this is the real gate**

There is no automated coverage for Fabric rendering (Fabric's image pipeline can't run under jsdom). Start the dev server, open a KV with overlays, and confirm:

1. Dragging an overlay past the board edge crops it at the edge instead of spilling onto the canvas.
2. The crop stays aligned with the board while panning AND zooming — this is what proves the viewportTransform assumption.
3. Dragging the *board* moves the crop with it.
4. The clipped overlay can still be dragged back into view (geometry wasn't clamped).
5. An overlay bound to a different board is unaffected.

Record what you observed for each.

- [ ] **Step 6: Commit**

```bash
cd web && git add src/components/studio/kv-generator/KvFabricCanvas.tsx
git commit -m "feat(web): clip overlays to their board on the Craft canvas"
```

---

### Task 2: Clip overlays in the export path

**Files:**
- Modify: `src/components/studio/kv-generator/renderBoardStage.ts`

**Interfaces:**
- Consumes: the fitted board rect this module already computes to position overlays.
- Produces: exported PNGs crop overlays at the board edge, matching both canvases.

`renderBoardStage` builds its own Konva stage for the Craft "Original + overlays" download and the Resize export, and it has **no clipping at all**. So an overlay bleeding past the board is cropped in the tile editor and *not* cropped in the download. `KvKonvaCanvas.tsx:1298-1300` even documents its clip as "matching what a downloaded flatten would look like" — a claim that is currently false. This task makes it true.

- [ ] **Step 1: Add the clip to the overlay layer**

`renderBoardStage` renders the base and overlays into a stage. Wrap the overlay nodes in a `Konva.Group` carrying a `clipFunc` over the same fitted rect used to position them, mirroring `KvKonvaCanvas.tsx:1304`:

```ts
  ctx.rect(fit.x, fit.y, fit.width, fit.height);
```

**Do not restructure the layers.** Base and overlays were deliberately merged onto a single Konva Layer so blend modes composite — splitting them again would silently break every blend mode in the export. Add the Group *inside* the existing layer.

- [ ] **Step 2: Verify the build and tests**

```bash
cd web && bun run build && bun test src/components/studio
```

Expected: build succeeds; failing test names unchanged. `renderBoardStage.test.ts` exists — if it asserts layer structure, update it to expect the new Group, and confirm base + overlays still resolve to the same Layer (that assertion guards the blend-mode fix).

- [ ] **Step 3: Verify visually**

Place an overlay so it bleeds past the board edge, then download. The exported PNG must crop it exactly like the canvas does. Also download a board with a **Multiply** overlay and confirm the blend still composites — this is the regression risk of touching this file.

- [ ] **Step 4: Commit**

```bash
cd web && git add src/components/studio/kv-generator/renderBoardStage.ts
git commit -m "feat(web): crop overlays at the board edge on export"
```

---

### Task 3: Confirm the three surfaces agree

**Files:**
- Possibly modify: `src/components/studio/kv-generator/KvKonvaCanvas.tsx` (only if its rect differs)

- [ ] **Step 1: Compare the rects**

Read how each of the three computes the rect it clips to:
- `KvKonvaCanvas.tsx:1304` — `fit`
- `renderBoardStage.ts` — the fitted rect from Task 2
- `KvFabricCanvas.tsx` — `overlayHostRect(overlay)` from Task 1

Confirm all three describe the same region of the board. Report your comparison explicitly. If they differ, say how and propose the fix rather than silently changing one.

- [ ] **Step 2: Verify the same overlay crops identically on all three surfaces**

Using one KV with a deliberately bleeding overlay, check the Craft canvas, the Resize tile preview, and the downloaded PNG. Any surface that crops differently is a bug — report it.

- [ ] **Step 3: Commit if anything changed**

```bash
cd web && git add -A src/components/studio/kv-generator
git commit -m "fix(web): align board clip rect across canvas, tile editor and export"
```

---

## Done criteria

- An overlay dragged past its board edge is cropped on the Craft canvas, in the tile editor, and in the downloaded PNG.
- The crop tracks the board through pan, zoom and board drag.
- Stored geometry is unchanged — a clipped overlay can be dragged back into view.
- Blend modes still composite in the export (the regression risk of touching `renderBoardStage`).
- `bun run build` green; no new test failures.

## Not in this plan

- Constraining drag so overlays *cannot* leave the board — off-canvas positioning is deliberate and server-supported.
- Clipping in `KvTileOverlayEditor` — it renders a single tile and already scopes to it.
