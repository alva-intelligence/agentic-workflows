# KV Craft Resize Strip — Design Spec

> **Written:** 2026-09-22 · **Author:** daffa (with Claude) · **Status:** draft, awaiting sign-off (fahrizky, Jeff)
> **Supersedes in part:** PRD `frnd/docs/prd/kv-resize-unified-canvas.md` FR-12 and §UI/UX "Key Screens"; spec `2026-08-10-kv-canvas-surface-unification-design.md` §"The two views" and §"Keeping the list feel".
> **Builds on:** `2026-08-11-kv-board-doc-participation-design.md` (merged as frnd-web #426) and the `KvSurface` model in `web/src/components/studio/kv-generator/kvSurface.ts`.

## Overview

Resize tiles stop being a separate screen. They render as boards **inside the Craft canvas**, in a single vertical strip below the Craft boards under a "Resizes" divider (Figma `KV-Generator` node `73-16650`). The Resize tab disappears; adding sizes is a bottom-nav button that opens the platform picker for the active board.

One engine (`KvFabricCanvas`), one camera, one selection, one pointer path. Everything that works on a Craft board — transform handles, text editing, shape/frame/comment tools, ghost overflow, keyboard shortcuts — works on a tile without being rewritten, because it is the same code drawing the same canvas.

What is deliberately **different** on a tile, and why:

| | Craft board | Resize tile |
|---|---|---|
| Position | doc-owned, persisted, draggable (`layout: "doc"`) | view-derived, never persisted, not draggable (`layout: "view"`) |
| Overlay writes | Y.Doc (collab, presence, materialisation into `kv_canvas`) | REST per export (`docBoardId: null`) |
| Undo | one doc history | per tile |
| Status chrome | none | pending / generating / failed with Retry / Cancel |
| Actions | variant, rename, master, version history | regenerate, upscale, region edit, push-to-all, download |

A tile is not a generation; the model says so explicitly and the canvas never has to infer it.

## Decisions taken

Product (daffa, 2026-09-22):

1. **Single view, no Resize tab.** Replaces the PRD's `canvasMode: "resize"` mode swap. Requires re-sign-off of FR-12.
2. **One global strip** below the bounding box of all Craft boards, tiles **stacked vertically**, grouped per parent board in Craft board order. No master/original tile — the parent Craft board *is* the master.
3. **Entry point** is the existing "Toggle platform picker" bottom-nav button, shown in Craft, opening `KvResizePanel` for the active board. "Send to Resize" on the board context menu activates the board and opens the same picker.
4. **Tile header** carries caption + history + download. Everything else is on the tile context menu. Retry/Cancel stay on the status chrome.

Engineering (daffa, 2026-09-22):

5. **Lineage A wins.** The engine is `KvFabricCanvas` generalised over `KvSurface[]`. The standalone `KvResizeUnifiedCanvas` on `feature/daffa/vc-kv-resize-unified-canvas` (96 commits, PR #541 closed) is **not rebased or merged**. Its canvas-agnostic modules and their tests are harvested; the 3200-line component becomes a behavioural reference. Rationale: folding it into a 7032-line production file yields two selection systems in one ~10k-line file — the outcome approach C exists to avoid.
6. **Seam first, split later.** The refactor changes five assumptions inside `KvFabricCanvas`; it does not split the file. Splitting happens in its own slice after the strip is live and Craft parity has passed once — a refactor without a consumer cannot be verified (the same reason the earlier step 2b was cancelled).
7. **Two overlay sinks chosen by object tag, not by mode.** Overlays on a `rest` surface are built without a Y `elementMap`, so the existing binding ignores them by construction. A second handler commits them to REST.
8. **Grid draws behind boards** (closes open item 8 of the branch-B track). **Tile chrome hides below a projected-width threshold** (closes open item 6, the Cancel-overhang defect).
9. The flag `KV_RESIZE_UNIFIED_CANVAS` (fail-closed) gates S2–S3. S4 is a straight replacement and removes the flag.

Binding decisions inherited unchanged: layout is derived, never persisted (branch-B track #3); per-tile undo (#2); Craft stays single-select (#1).

## Architecture

### The engine seam (slice S1)

`KvFabricCanvas` already builds `surfaceById` from `boards` via `surfaceFromBoard` ([KvFabricCanvas.tsx:1147]). Of its 41 `effectiveBoards` references, only two read `generation.*` (`image_url`, `id`). The seam is five changes:

1. **Input.** `surfaces: KvSurface[]` replaces `boards: KvBoard[]` as what the canvas iterates. The host merges two producers: `craftSurfaces` (from `boards`, unchanged semantics) and `resizeSurfaces` (new). `effectiveBoards` → `effectiveSurfaces`; the two `generation.*` reads become `surface.imageUrl` / `surface.docBoardId`. Board-level DOM chrome that needs a *generation* (context menu, rename, variant, angle — the `effectiveBoards.map` at ~5362 and lookups at ~5641/5754/6526) renders only for surfaces with `docBoardId != null`.
2. **Draggability per surface.** Board `selectable` becomes `tool === "cursor" && surface.layout === "doc"`. The binding already refuses a position write via `canPersistBoardPosition` (#426) — two independent layers.
3. **Board map per surface.** `ensureBoardMap` is already guarded by `shouldAttachBoardMap(surface)` (~1166). No change; a phantom artboard stays impossible by construction.
4. **Two overlay sinks.**
   - *doc* (existing): objects tagged `{elementId, elementMap}`; `bindKvCanvasToYjs.writeOverlayRect` writes the `Y.Map` ([yjsBinding.ts:242]). Unchanged.
   - *rest* (new): overlays of a `rest` surface are built by `renderResizeBoards` tagged `{resizeBoardId, overlayId}` with **no** `elementMap`, so `overlayMetaOf()` returns null and the binding skips them. `bindRestOverlaySink(canvas, opts)` listens to `object:modified` / `object:moving` for that tag, normalises via `normalizedFromWorld` (harvested `resizeWorldGeometry.ts`), and calls `onCommitOverlays(surfaceId, next)`. The host routes to `commitTileOverlays` (REST). `overlaySinkFor()` — currently consumer-less — becomes the single place the choice is made.
5. **Surface-based tool targeting.** Tool handlers (shape/text/comment/frame) resolve their target with `boardAtWorldPoint` + `normalizedPointInBoard` (harvested `resizeToolGesture.ts`) and route placement to the target surface's sink. Placement on a tile whose export is not `done` is refused at the gesture **and** at the host (branch-B invariant #2).

`onSelectBoard` feeds `setViewingGenerationId` and genuinely wants a generation id; a `rest` surface never calls it. Tile activation goes through a new `onSelectSurface(surfaceId)`. `onResetBoardPosition` / `onSetMaster` are never wired for `layout: "view"` surfaces (#426 §"Two ungated paths").

### The strip (slice S2)

**Producer `resizeSurfaces(exportsByParent, craftBbox)`** — pure, tested. For each parent board in Craft order, for each export in row order: `{ id: export.id, docBoardId: null, layout: "view", imageUrl: export.image_url ?? null, fallbackAspect: width/height, label: export.name ?? platformLabel, isActive, center }`. No master surface.

**Column layout** — derived every render, never stored:
- `x` = left edge of `boardsBoundingBox(craftSurfaces)`; tile world width = `BOARD_WORLD_WIDTH` (512), height from aspect.
- `y` starts at `bbox.bottom + STRIP_GAP` (room for divider + first header), then `y += tileHeight + TILE_GAP`. `TILE_GAP` is wide enough that a ghosted overflow does not sit inside the next tile.
- Adding or moving a Craft board changes the bbox and the strip follows. The strip never moves a Craft board.
- `fitAll()` unions the strip into its bounds.

**Chrome is DOM, positioned via `onBoardRectsChange`** (the comment-pin pattern), not canvas objects:
- "Resizes" divider once above the first tile; not rendered when there are no exports.
- Group header (parent board name) **only when more than one parent group exists**.
- Tile header: caption left; history + download right. Hidden when the tile's projected width is below a threshold (fixed at S2 by looking at a real board at the mount-time fit — the branch-B track records ~160px as the boundary case).
- Status chrome pending/generating/failed + Retry/Cancel: `KvBoardStatusLayer` harvested from branch B.
- Right-click → the existing tile context menu (rename, upscale, region edit, push-to-all, duplicate, delete). Non-`done` tiles are not selectable.

**Entry point.** The bottom-nav "Toggle platform picker" ([KvCanvasBottomNav.tsx:236]) is no longer Resize-only. It opens `KvResizePanel` as the right panel for the active board (if the active surface is a tile, its parent). Disabled with a tooltip when no board is active. Adding a size creates a pending tile in the strip and pans it into view.

**Camera.** Craft's free two-axis pan/zoom is kept. The earlier spec's "list feel" constraints (locked horizontal pan) do not apply to a shared view and are withdrawn.

### Editing on tiles (slice S3)

The *rest* sink goes live: selection, drag/scale/rotate, inline text, shape, frame + detection, comment pins on tiles; per-tile undo routed by active surface; multi-select toggled on for `rest` surfaces only. Commit routing uses the harvested `resolveCommitTarget` / `baselineOverlaysFor` (inheriting tiles mint from **projected** coordinates — branch-B invariant #6). The frame box remains clamped (it is an inpaint mask, not an overlay).

## Slices

Each slice is one PR with **one whole-slice review** at the end (not per-task reviews — the branch-B track records six invariant misses that only a whole-slice review caught).

| Slice | Content | Definition of done |
|---|---|---|
| **S0 — Harvest** | Cherry-pick from branch B, with tests: `resizeWorldGeometry`, `resizeToolGesture`, `resizeBoardOverlays`, `resizeCommitRouting`, `resizeSelectionSource`, `KvBoardStatusLayer`, `KvFrameBoxLayer`. No new consumers. Close branch B with a note in its track file. | Module tests green on develop; build clean (`node` build, not `bun run build`); no import from `KvFabricCanvas`. |
| **S1 — Engine seam** | The five changes above. Only the Craft producer is live. | Craft identical — manual regression checklist (positions, captions, drag-persist, text edit, shape, frame, comment, PSD board, undo, two-tab collab). Pure tests: a `rest` surface never triggers `ensureBoardMap`, `writeOverlayRect`, or a position write. |
| **S2 — Strip, read-only** | `resizeSurfaces` producer + column layout + divider + tile header (caption, history, download) + status layer + picker in bottom nav. Tiles and their overlays not selectable. Behind the flag. | **Postgres:** `metadata.kv_canvas.artboards` gains no export-id key after opening a file with resizes; Craft centres unchanged. Pure layout tests: order, spacing, independence from persisted state. Existing Resize PostHog events still fire. |
| **S3 — Editing on tiles** | *rest* sink live; tools on tiles; per-tile undo; `done`-only placement refusal at gesture and host. | **DB:** a tile edit reaches REST and never the doc; a Craft board edit reaches the doc. Branch-B runtime checklist items 1–5 re-run. Ghost overflow visible across board↔tile. |
| **S4 — Delete** | Resize tab, `KvResizeCanvas` row path, `KvResizeViewport`, `KvTileOverlayEditor`, `KvResizeTileStage`, `resizeApron`, `applyMaxQualityScaling`. `KvKonvaCanvas` only after the reviewer who requested the kill switch confirms. Konva stays in `package.json` (Motion). Flag removed. | Build clean; no new suite failures; Resize PostHog events still fire. |

The old Resize tab stays functional through S3.

## Documents to change

- PRD `kv-resize-unified-canvas.md`: FR-12 → "Resize tiles are surfaces in the Craft canvas, single view"; §UI/UX Key Screens rewritten; new FR for the picker entry point. **Re-sign-off required before S2 is enabled for anyone.**
- Spec `2026-08-10-kv-canvas-surface-unification-design.md`: note that "two views" became "one view, participation per surface"; withdraw §"Keeping the list feel".
- `docs/superpowers/HANDOFF-kv-canvas-unification.md`: update state, S0–S4, branch-B status.
- `web/docs/tracks/kv-resize-unified-canvas.track.md`: close-out entry pointing here.

## Testing

`KvFabricCanvas` cannot be component-tested (jsdom has no 2D context). The safety net is therefore:

- **Pure tests** on producer, layout, sink selection, and the harvested modules.
- **Manual verification + database queries per slice**, recorded in the track file. Debt #1 of the handoff; not skippable.
- Suite baseline recorded before S1 via a worktree (never `git stash`); the bar is no new failures. Tests run with `bun test`; build via `node`.
- `frndos-analytics-events` invoked before S2 and S3 are declared done.

The query that proves S2 and S3:

```bash
psql -h 127.0.0.1 -p 5432 -d frnd -tAc \
  "select jsonb_pretty(metadata->'kv_canvas') from studio_files where id='<file-id>';"
```

Any `artboards` key that is an export id rather than a generation id is a failure.

## Risks

1. **Craft regression in S1.** Mitigation: five localised changes; Craft checklist passes before S2 starts.
2. **Tile overlays leaking into the doc.** Mitigation: impossible by construction (no `elementMap`) + pure tests + DB query in S2 and S3.
3. **Invariants nobody re-read** (six misses on branch B). Mitigation: S3 opens by re-reading "Decisions still binding" and the six invariants; the `done` gate lives at gesture and host.
4. **`onSelectBoard` semantics.** A `rest` surface never calls it; decided in S1.
5. **Threshold for hiding tile chrome** cannot be chosen from code. Decided in S2 against a real board.

## Out of scope

Splitting `KvFabricCanvas.tsx` (own slice after S3); Motion; multi-select in Craft; master-row region edit (U1e); duplicate/rename tile (separate specs exist).
