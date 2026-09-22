# KV Craft Resize Strip — S3 Tile Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task (this project runs inline, no subagents). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Overlays on a `done` Resize tile in the Craft strip are editable with the Craft tools — select, drag/scale/rotate, inline text, shape, comment pin, paste, delete — persisted per tile through REST, never the doc; per-tile undo; the Layers and Transform panels follow a selected tile; right-click on a tile opens the existing tile menu.

**Architecture:** `KvCanvas` becomes the **router**: it already knows every strip export (`strip.byExportId`) and every REST overlay id, so it wraps the canvas callbacks (`onUpdateOverlay`, `onRemoveOverlay`, `onPlaceText/Shape/Image/Comment`, `onDropImageOnBoard`, `onPasteOverlays`) and sends a tile-bound call to a REST commit (optimistic on the picker's query key, with per-tile history) and everything else on to the layout unchanged. The canvas itself learns nothing about REST beyond what S1 gave it, and two S1 pieces are corrected: overlay lookups use `allOverlays` (so a tile overlay normalises against its OWN tile, not the active board), and `bindRestOverlaySink` is removed — the canvas's drag-end `onUpdateOverlay` already carries the full patch (geometry + text font patch + clamp semantics).

**Tech Stack:** Fabric v7, TanStack Query v5 (optimistic `setQueryData`), React 19, `bun test`.

**Spec:** `docs/superpowers/specs/2026-09-22-kv-craft-resize-strip-design.md` §"Editing on tiles (slice S3)".

## Global Constraints

- Branch `feature/daffa/vc-kv-craft-resize-strip`; commit locally only; never push; never `git stash`.
- tsc gate: 9 errors in `KvFabricCanvas.tsx`, 999 repo-wide. Tests `bun test <files>`; build `node ./node_modules/next/dist/bin/next build`.
- **A tile edit reaches REST and never the doc.** `docUpdateOverlay` on an unknown id is a silent no-op — that is exactly the failure to fear: a tile edit that "does nothing". Every tile-bound id MUST be intercepted in `KvCanvas` before it reaches the layout.
- **Placement / paste / delete on a tile whose export is not `done` is refused** at the host (branch-B invariant #2). The canvas never receives REST overlays for a non-done tile (S2 already filters), so the gate here is on NEW overlays.
- **Inheriting tiles mint from PROJECTED coordinates** (branch-B invariant #6): the base list for a new overlay on a tile with `overlays === null` is `resolveTileOverlays(null, parentOverlays, srcW, srcH, w, h)`, never the raw parent list.
- Cross-sink moves (dragging an overlay from a board onto a tile or back) stay REFUSED in S3 (the S1 guard in the drag-end rebind stays).
- Craft stays single-select; multi-select on tiles, the frame tool / region edit on tiles, upscale, duplicate / rename / push-to-all in Craft are **S3b**, not this plan.
- Only invariant pure tests; no RTL.

---

### Task 1: Canvas — lookups over `allOverlays`, REST overlays interactive, S1 sink removed

**Files:**
- Modify: `KvFabricCanvas.tsx` — `resolveOverlayHostById` (~1361), `overlaysRef.current = overlays` (~1403), `overlays.find` at ~3365 and ~4174, the placement refusals from S1 (comment / text-image / frame-shape / drop), the `bindRestOverlaySink` binding + import + `onCommitRestOverlay` prop + cbRef entries.
- Delete: `restOverlaySink.ts`, `restOverlaySink.test.ts` (S1 module superseded — see Architecture). Keep `yjsBinding.overlayMetaOf`'s `elementMap` guard and its test; that is still what keeps the doc sink off REST objects.
- `RestOverlayTag` moves into `KvFabricCanvas.tsx` (it was only exported from the deleted module).

- [ ] **Step 1: `allOverlays` everywhere an overlay is looked up by id**

`overlaysRef.current = allOverlays;` (rename the ref's seed too). `resolveOverlayHostById`: `allOverlays.find(...)`, deps `[allOverlays, overlayHostRect, activeHostRect]`. ~3365 (`overlays.find((o) => o.id === id)`) and ~4174 (`(overlays ?? []).find`) → `allOverlays`. The text-edit-exit handler already reads `overlaysRef`, so it follows.

- [ ] **Step 2: Remove the S1 placement refusals** — the three `if (!boardByIdRef.current.has(target.surface.id)) return;` blocks (comment, text/image, frame/shape) and the two in the drop handlers (drag-over highlight + drop). Keep: the angle tool's Craft-only guard, and the rebind guard in the drag-end handler (`hitTarget && boardByIdRef.current.has(...)`). The canvas now reports `surface.id` for a tile exactly as it does a generation id; the host decides.

- [ ] **Step 3: Remove the REST sink** — delete the `bindRestOverlaySink(...)`/`disposeRestSink()` lines, the import, the `onCommitRestOverlay` prop (type + destructure + both cbRef entries), and the two files. Define locally: `type RestOverlayTag = { elementId: string; restSurfaceId: string };`.

- [ ] **Step 4: tsc 9/999; eslint 0 errors; commit**

```bash
cd web && bunx eslint --fix src/components/studio/kv-generator/KvFabricCanvas.tsx >/dev/null; bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -c "error TS"; git rm -q src/components/studio/kv-generator/restOverlaySink.ts src/components/studio/kv-generator/restOverlaySink.test.ts; git add src/components/studio/kv-generator/KvFabricCanvas.tsx && git commit -q -m "refactor(web): KvFabricCanvas looks overlays up in allOverlays and reports tile placements; the S1 REST sink is removed

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 2: `useTileOverlayEditing` — the REST commit path, pure where it can be

**Files:**
- Create: `web/src/lib/studio/kv/tileOverlayEdits.ts` (pure) + `tileOverlayEdits.test.ts`
- Create: `web/src/lib/studio/kv/useTileOverlayEditing.ts` (hook)

**Interfaces produced (pure):**
```ts
export function applyOverlayPatch(list: StudioOverlay[], id: string, patch: Partial<StudioOverlay>): StudioOverlay[]; // returns the SAME array when id is absent or nothing changed
export function appendWithNextZ(list: StudioOverlay[], drafts: StudioOverlay[]): StudioOverlay[];                     // z = max+1, +2, …
export function newTileTextOverlay(args: { fileId: string; nx: number; ny: number; id: string; now: string }): StudioOverlay; // same numbers as KvResizeCanvas.handleTilePlaceText
export function newTileShapeOverlay(args: { fileId: string; kind: ShapeKind; rect: {x,y,width,height}; rotation: number; id: string; now: string }): StudioOverlay; // payload = defaultShapePayload(kind)
```
**Hook:**
```ts
export function useTileOverlayEditing(args: {
  fileId: string | null;
  strip: ResizeStripLayout | null;
  restOverlays: Record<string, StudioOverlay[]> | undefined;   // S2's resolved lists (the CURRENT rendered list per tile)
}): {
  tileOfOverlay: (overlayId: string) => KvResizeExport | null;
  isTile: (surfaceId: string) => KvResizeExport | null;
  commit: (row: KvResizeExport, next: StudioOverlay[]) => void;   // records history, optimistic setQueryData on resizeExportsQueryKey(fileId, row.parentGenerationId), updateResizeExportOverlays, rollback on error
  updateOverlay: (overlayId: string, patch: Partial<StudioOverlay>) => boolean; // false when not a tile overlay
  removeOverlay: (overlayId: string) => boolean;
  place: (row: KvResizeExport, drafts: StudioOverlay[]) => string[];           // refuses (returns []) unless row.status === "done"
  history: TileOverlayHistory;                                                   // useTileOverlayHistory({ apply: commitWithoutRecording, currentOf })
}
```
`commit` mirrors `useResizeExports.updateOverlays`: `qc.setQueryData(key, prev => prev.map(r => r.id===row.id ? {...r, overlays: next} : r))`, then `updateResizeExportOverlays(fileId, row.id, next)`, `onSuccess` write the returned row, `onError` restore. `history.record({ exportId: row.id, overlays: row.overlays })` BEFORE the optimistic write (the baseline is the row's snapshot, possibly `null` for an inheriting tile — restoring `null` re-inherits, which is correct).

- [ ] **Step 1: Failing tests for the pure module** (identity on absent id; z assignment; text/shape defaults equal to `KvResizeCanvas.handleTilePlaceText` numbers `x = clamp(nx-0.2, 0, 0.6)`, `y = clamp(ny-0.04, 0, 0.92)`, `0.4×0.08`).
- [ ] **Step 2: Implement pure module; tests PASS; commit.**
- [ ] **Step 3: Implement the hook (no test — TanStack wiring); tsc clean; commit.**

### Task 3: `KvCanvas` routes tile-bound callbacks to REST

**Files:**
- Modify: `KvCanvas.tsx` — wrap the callbacks it forwards to `KonvaStageFrame` → `KvFabricCanvas`; pass `restOverlaysInteractive={true}`; new props `onPlaceTileComment?: (exportId: string, nx: number, ny: number) => void` and `onTileEditContextChange?: (ctx: TileEditContext | null) => void`.

**Interfaces produced:**
```ts
export type TileEditContext = {
  row: KvResizeExport;
  overlays: StudioOverlay[];                 // current rendered list for this tile
  update: (id: string, patch: Partial<StudioOverlay>) => void;
  remove: (id: string) => void;
  reorder: (fromId: string, toId: string) => void;    // reuse the same reorder rule the store uses (`reorderOverlays` if exported; else move fromId to toId's index and renumber z)
  toggleHidden: (id: string) => void;                // toggleOverlayHidden from overlayMutations
  toggleLocked: (id: string) => void;
  rename: (id: string, name: string) => void;        // payload.name
  undo: () => void; redo: () => void; canUndo: boolean; canRedo: boolean;
};
```

- [ ] **Step 1: Wrappers** (each: tile → REST via `useTileOverlayEditing`, else forward):
  - `onUpdateOverlay(id, patch)` → `editing.updateOverlay(id, patch) || onUpdateOverlay?.(id, patch)`
  - `onRemoveOverlay(id)` → same shape
  - `onPlaceText(nx, ny, boardId)` → `const row = editing.isTile(boardId)`; if row: `place(row, [newTileTextOverlay(...)])` then `onEditTextOverlay?.(newId)` (enter editing, like the layout does with `setEditingTextId`); else forward
  - `onPlaceShape(kind, rect, boardId, rotation)` → tile: `place(row, [newTileShapeOverlay(...)])`, return the id; else forward
  - `onPlaceImage` / `onDropImageOnBoard` → tile: refuse for S3 (image upload to a tile needs the upload pipeline — S3b); log nothing, return
  - `onPlaceComment(nx, ny, boardId)` → tile: `onPlaceTileComment?.(row.id, nx, ny)` (the layout already has `handleTilePlaceComment` for row ids); else forward
  - `onPasteOverlays(...)` → if the active surface is a tile: `place(row, drafts re-idd)`; else forward. Read the layout's `handlePasteOverlays` signature first and mirror its argument shape.
- [ ] **Step 2: Active tile tracking** — `onSelectOverlay(id)` / `onSelectOverlays(ids)`: forward to the layout (store) AND set `activeTileRow = editing.tileOfOverlay(first id)`; `onSelectSurface(id)` (S1 prop) → `activeTileRow = isTile(id)`; `onDeselectBoard` → null. Publish `TileEditContext` via `onTileEditContextChange` whenever `activeTileRow` / its overlays / history flags change.
- [ ] **Step 3: `restOverlaysInteractive={true}`; tsc; commit.**

### Task 4: Layout — panels follow a selected tile; Cmd+Z routes to the tile

**Files:**
- Modify: `KvGeneratorLayout.tsx` — `const [tileEditCtx, setTileEditCtx] = useState<TileEditContext | null>(null)` next to `resizeStripActive`; pass `onTileEditContextChange={setTileEditCtx}` and `onPlaceTileComment={handleTilePlaceComment}` (read its real signature at its definition) to `<KvCanvas>`.
  - `panelOverlays`: `tileEditCtx ? tileEditCtx.overlays : (existing)`; `selectedTileLabel`: `tileEditCtx ? (tileEditCtx.row.name ?? tileEditCtx.row.platformLabel) : (existing)`.
  - `KvLayersPanel` handlers `onRemove / onReorder / onToggleVisibility / onToggleLock / onRename / onUndo / canUndo`: branch on `tileEditCtx` first.
  - Transform panel `onUpdateOverlay`: `tileEditCtx ? tileEditCtx.update(id, patch) : docUpdateOverlay(...)`; `baseOverlayForTransform` looks in `tileEditCtx.overlays` first.
  - Cmd+Z dispatch (search `resizeEditDomainRef.current === "master"` ~2457 for the router): when `canvasMode === "craft" && tileEditCtx` → `tileEditCtx.undo()` / `redo()` instead of the doc undo.
- [ ] **Step 1: Wire; tsc equal to baseline (layout 1/1); eslint adds no warnings; commit.**

### Task 5: Tile context menu in Craft

**Files:**
- Modify: `KvFabricCanvas.tsx` — right-click handler: where S1 returns early for a non-Craft hit, call new prop `onSurfaceContextMenu?.(hit.id, pointer.x, pointer.y)`.
- Modify: `KvCanvas.tsx` — state `{ row, x, y } | null`; render `<KvResizeTileContextMenu row x y onClose />` (its existing props only — `readyToShare`/`onToggleReadyToShare`/`onDecomposeLayers` optional and omitted in S3).
- [ ] **Step 1: Wire; tsc; commit.**

### Task 6: Gates, track, close-out notes

- [ ] **Step 1: Tests** — all S0–S3 test files in one run (S1 list minus `restOverlaySink.test.ts`, plus `resizeStrip.test.ts`, `tileOverlayEdits.test.ts`); `0 fail`.
- [ ] **Step 2: Build** exit 0.
- [ ] **Step 3: Track file** — S3 done (local); the S3 manual checklist:
  - flag ON, a done tile: click an overlay → selected, Layers panel lists THIS tile's overlays with the tile's label; drag / scale / rotate → persists after reload; **DB:** `select overlays from kv_resize_exports where id='<export>'` changed, and `metadata->'kv_canvas'` of the file did NOT
  - text tool on a tile → new text overlay enters editing; type; exit → persisted to the tile
  - shape tool on a tile → shape persisted; Delete removes; Cmd+Z undoes the last tile edit only (a board edit is untouched)
  - inheriting tile (no snapshot): first edit materialises a snapshot whose inherited layers did NOT jump (invariant #6)
  - pending/generating tile: overlays not drawn; text/shape tool on it does nothing
  - drag an overlay from a board onto a tile → it snaps back / stays on its board (refused)
  - right-click a tile → tile menu opens
  - edit a Craft board overlay → still reaches the doc and the second tab
  - flag OFF → Craft identical to the S1 checklist
- [ ] **Step 4: Close branch B** — append a close-out entry to `web/docs/tracks/kv-resize-unified-canvas.track.md` ON THIS BRANCH (copy the file from `origin/feature/daffa/vc-kv-resize-unified-canvas` first if absent on develop) pointing to the spec and this branch. Do NOT check out branch B.
- [ ] **Step 5: Commit.**

---

## Self-review

- Spec §S3: rest sink live (T1/T3 — through `onUpdateOverlay`, not the deleted sink; recorded as a correction), tools on tiles (T3: text, shape, comment, paste, delete; image/drop deferred to S3b and said so), per-tile undo (T2 `history`, T4 Cmd+Z routing), `done`-only refusal at host (T2 `place`), invariant #6 (T2 `commit` baseline + S2's `resolveTileOverlays` lists as the base), frame box clamped — N/A (frame tool is S3b). Layers/Transform on tiles (T4). Tile menu (T5, existing component only).
- Types: `TileEditContext` T3→T4; `useTileOverlayEditing` T2→T3; `RestOverlayTag` now local to the canvas (T1).
- Deferred to S3b, explicitly: multi-select on tiles, frame tool + region edit + detection on tiles, image placement/drop/upload on tiles, upscale / duplicate / rename / push-to-all in Craft, cross-sink moves, Resize-tab removal (S4).
