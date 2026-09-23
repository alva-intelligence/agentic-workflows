# KV Craft Resize Strip — S3b Tile Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task (inline, no subagents). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The remaining Resize affordances work on a tile in the Craft strip: the frame tool (region edit + object detection), image drop / placement (upload), multi-select + Cmd+A / copy scoped to the tile, and the tile actions that lived on the old Resize row — upscale (download dropdown), duplicate, regenerate (arm), push-master-to-all — from the tile header and tile menu.

**Architecture:** Same shape as S3 — the canvas reports the surface; `KvCanvas` routes. Two new canvas seams: (1) `activeSurfaceId` override so a selected tile becomes the ACTIVE surface (its overlays are what Cmd+A / copy / legacy-null overlays resolve against; `activeBoard` stays null so Craft-only chrome is untouched); (2) the frame tool's mouse-up emits `onTileFrameDrawn(surfaceId, normRect, screenCentre)` when the drawn board is not a Craft board, instead of pushing into the doc-scoped `boxes`. Tile frame boxes live where they already live in Resize — `useKvResizeStore.boxesByExportId` — and are rendered by the harvested `KvFrameBoxLayer` in the strip chrome; detection is `detectTileObjects`; the send is the layout's existing armed-regenerate flow (`armRegenerate` + `resolveResizeSend` → `editResizeRegion`), which today only sees the VIEWED board's exports — widened to every strip export.

**Spec:** `docs/superpowers/specs/2026-09-22-kv-craft-resize-strip-design.md`; deferred list in the S3 plan.

## Global Constraints

- Branch `feature/daffa/vc-kv-craft-resize-strip`; local commits only; never push; never `git stash`.
- Gates: tsc 9 in `KvFabricCanvas.tsx` / 999 total; eslint no new warnings; `bun test <files>`; `node ./node_modules/next/dist/bin/next build`.
- Done-only: a frame, a drop, a paste on a non-`done` tile is refused at the host.
- Master region edit stays pulled (branch-B U1e) — a frame on a Craft BOARD keeps today's doc flow; only tiles route to REST.
- Cross-sink moves stay refused. Rename tile is OUT (needs its own UI decision — the caption is canvas-drawn).
- Only invariant pure tests; no RTL.

---

### Task 1: Active tile = active surface (multi-select, Cmd+A, copy on a tile)

**Files:** `KvFabricCanvas.tsx` (prop `activeSurfaceId?: string | null`; `activeSurface` memo), `KvCanvas.tsx` (pass `activeTileId`).

- [ ] `activeSurface = (activeSurfaceId && surfaceById.get(activeSurfaceId)) ?? effectiveSurfaces.find(isActive) ?? effectiveSurfaces[0] ?? null`. Everything downstream (`activeHostRect`, the keyboard handler's `board` pick, `overlaysForBoard(allOverlays, tile.id, …)`) then scopes to the tile; `activeBoard` (Craft-only chrome) becomes null while a tile is active — intended.
- [ ] Keyboard paste: the canvas calls `onPasteOverlays(pasted)`; `KvCanvas.routePasteOverlays` already places on `activeTileRow` (S3). Copy: `buildClipboardPayload` from the tile's overlays needs the tile's frame size — `boardNaturalWidthsRef[tile.id]` is 0 (no natural width reported for tiles). Report tile metrics: in the board sync effect, `reportAspect(s.id, aspect, img.width)` already runs for every surface incl. tiles — verify; if `naturalWidth` is 0 for tiles, fall back to `export.width` via a new `surface.nativeWidth?` field set by `computeResizeStrip`.
- [ ] Shift-click multi-select across tile overlays already forms an ActiveSelection (same objects). Guard: an ActiveSelection mixing a doc overlay and a REST overlay must not be draggable as one — on `selection:created/updated`, if the active objects span two sinks, `discardActiveObject()` and re-select the last one. (Two sinks in one transform = two commit paths from one gesture.)
- [ ] KvCanvas: `activeSurfaceId={activeTileId}` through `KonvaStageFrame`.
- [ ] tsc; commit.

### Task 2: Frame tool on a tile → `boxesByExportId`, detection, arm

**Files:** `KvFabricCanvas.tsx` (frame mouse-up branch), `KvCanvas.tsx`, `KvResizeStripChrome.tsx`, `useKvResizeStore` (no change), layout (`armedExport`).

- [ ] Canvas prop `onTileFrameDrawn?: (surfaceId: string, box: { x: number; y: number; width: number; height: number }, screenCentre: { x: number; y: number }) => void`. In the frame mouse-up, BEFORE `if (!st.onBoxesChange) return;`: `if (boardId && !boardByIdRef.current.has(boardId)) { st.onTileFrameDrawn?.(boardId, norm, centre); return; }` (compute `centre` as the detect-prompt code does). Mirror in `toolRef`.
- [ ] `KvCanvas`: `handleTileFrameDrawn(surfaceId, box, centre)`: `row = editing.isTile(surfaceId)`; refuse unless `row.status === "done"`; `id = crypto.randomUUID()`; `setBoxesForExport(row.id, [...boxesForExport(boxesByExportId, row.id), { id, ...box }])`; `setActiveTileId(row.id)`; `if (armedRegenerate !== row.id) armRegenerate(row.id)` (drawing a box IS the intent — branch-B rule); if `objectSelectEnabled` → open a tile detect prompt `{ row, boxId: id, region: box, centre }`.
- [ ] Detection: `detectTileObjects(fileId, row.id, region, hint)` → candidates state per tile `{ boxId, region, objects }`; picking uses the harvested `nextBoxesForPick(...)` (read its signature in `resizeCandidatePick.ts` and the branch-B host's `onPickCandidate` at `git show origin/feature/daffa/vc-kv-resize-unified-canvas:src/components/studio/kv-generator/KvResizeCanvas.tsx` ~2040–2075 for the exact call) → `setBoxesForExport`.
- [ ] Chrome: per tile render `<KvFrameBoxLayer boxes={boxesForExport(byExport, row.id)} displayWidth/Height={rect} interactive={tool === "frame"} onBoxClick onUnmark draft={null} candidates picked hoveredCandidate onHoverCandidate onPickCandidate detectPromptBoxId />` inside a wrapper at the tile's rect; the detect prompt popover reuses `BoxPromptPopover` (`boxPromptUi.tsx` — coordinate-agnostic, takes screen px) with "Find objects" → detection, "Edit this area" → `setActiveBoxId`.
- [ ] Layout: `armedExport` (~3443) searches `exportsByPlatformId` of the VIEWED board only. Widen: `KvCanvas` publishes `onStripExportsChange(rows: KvResizeExport[])` (all strip exports); layout keeps `stripExports` state and `armedExport = viewed match ?? stripExports.find(id)`. The existing send flow (`resolveResizeSend` → `editResizeRegion.mutate` / `regenerateResize.mutate`) uses the viewed board's mutations, whose invalidation key is the viewed parent — for another parent, after `.mutate` also `qc.invalidateQueries(resizeExportsQueryKey(fileId, armedExport.parentGenerationId))`. Add that one line next to each `.mutate` in the armed flow.
- [ ] Stale boxes: mirror `staleRegionBoxes.ts` — when a strip export leaves `done` or disappears, `clearBoxesForExport(id)` (effect in KvCanvas over strip exports).
- [ ] tsc; commit.

### Task 3: Image drop / placement on a tile

**Files:** `src/lib/studio/kv/tileImageOverlay.ts` (new: `buildTileImageOverlay({ fileId, file, place: { nx, ny, frameAspect }, nudgeIndex })` — `uploadStudioOverlayAsset` + `probeImageAspect` moved here from `KvResizeCanvas.tsx:3103`, width 0.3, height = 0.3 × naturalAspect × frameAspect, same as `buildImageOverlay`), `KvCanvas.tsx` (`routePlaceImage` / `routeDropImageOnBoard` → tile: upload then `editing.place(row, [overlay])`; multi-file nudged by 0.02), `KvResizeCanvas.tsx` (call the shared helper).

- [ ] Failures: `Sentry.captureException` per file; nothing placed → no commit.
- [ ] tsc; tests untouched; commit.

### Task 4: Tile actions in the header and menu

**Files:** `KvResizeStripChrome.tsx`, `KvCanvas.tsx`, `useResizeTileActions.ts`, `KvResizeTileContextMenu.tsx` (optional items).

- [ ] Header: replace the bare download icon with `KvTileDownloadDropdown` (`fileId`, `fileName`, `tile`, `onDownloadNative`, `craftBlocked = isCraftBlocked(parentBoard.generation)`) — gives 1.5× / 2× upscale for free. `fileName` from a new `KvCanvas` prop `fileName` (layout passes `file?.name ?? "kv"`).
- [ ] `useResizeTileActions`: add `duplicate(row)` → `duplicateResizeExport(fileId, row.id)` + invalidate; `regenerate(row, prompt?)` → `regenerateResizeExport` + invalidate; `armRegenerate(row)` → store `armRegenerate(row.id)`; `pushMasterToAll(parentId, rows)` → for every row with `overlays !== null`: `updateResizeExportOverlays(fileId, row.id, null)` then invalidate (the old flow's semantics: drop snapshots, re-derive from master; confirm dialog "N tile(s) have their own adjustments…" reused via `BaseModal`).
- [ ] `KvResizeTileContextMenu`: add optional callbacks `onDuplicate?`, `onArmRegenerate?`, `onPushMasterToAll?` (absent ⇒ hidden, its existing pattern) and render the items; `KvCanvas` wires them from the tile menu state.
- [ ] tsc; commit.

### Task 5: Gates + track

- [ ] All S0–S3b test files in one run; build exit 0.
- [ ] Track file: S3b done (local); manual S3b checklist — frame on a tile → box drawn, arm chip names the tile, Find objects returns outlines, Edit this area → chat send → region edit lands (Postgres `kv_resize_exports.image_url` changes; `kv_canvas` untouched); frame on a Craft board unchanged; drop an image on a tile → uploaded overlay appears and persists; shift-click two tile overlays → move together; Cmd+A on a tile selects only its overlays; a mixed board+tile selection is refused; header dropdown offers 1.5×/2×; menu: duplicate makes a sibling tile, arm ⟳ names the tile in the composer, push-to-all clears detached snapshots after confirm.

---

## Self-review

- Deferred list from S3 covered: frame/region edit/detection (T2), image drop/place (T3), multi-select + Cmd+A (T1), upscale/duplicate/regenerate/push-to-all (T4). Still out, said so: rename tile, cross-sink moves, S4.
- Invariants: done-only (T2, T3), master region edit pulled (T2 routes tiles only), boxes cleared when a tile leaves done (T2), two sinks never in one ActiveSelection (T1).
