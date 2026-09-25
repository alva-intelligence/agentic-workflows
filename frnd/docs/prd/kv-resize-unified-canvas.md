---
title: KV Resize Unified Canvas — Interaction Layer
slug: kv-resize-unified-canvas
author: daffa
created: 2026-08-27
status: approved # approved 2026-08-27 (fahrizky + Jeff + daffa); REVISED 2026-09-23 for the Craft strip, re-signed 2026-09-23 (fahrizky + Jeff)
revised: 2026-09-23
services: [web]
---

# KV Resize Unified Canvas — Interaction Layer

## Overview

Replatform the KV Studio **Resize** editing surface from one-Fabric-canvas-per-tile
to **one world canvas with tiles as boards** — the architecture Craft already
uses — with **zero change to Resize's product semantics**.

Today every Resize tile is its own `fabric.Canvas`, so the tile's frame edge is
a hard pixel boundary. The "apron" (a permanent 15% drawable margin per tile)
softens this but cannot remove it: overlays stop being visible/reachable past a
fixed distance, and every tile permanently pays `(1.3)² ×` its frame area in
canvas backing store (~32 MB per story tile on retina). Making the reach
"anywhere on screen" in the per-tile model would multiply that per tile and
risks Safari's total-canvas-area ceiling.

The fix is architectural and already **proven**: the read-only unified-canvas
spike (`KvResizeUnifiedCanvas`, merged in frnd-web PR #532 behind the
fail-closed `KV_RESIZE_UNIFIED_CANVAS` flag) renders all tiles as boards in
world space with Craft's exact camera semantics, demonstrates overflow with no
cutoff at 3×/10× frame width, and was visually reviewed and accepted. What is
missing is everything interactive: nothing on it can be selected, dragged, or
committed. This PRD covers that interaction layer, the parity work needed
before the flag can flip, and the cleanup that retires the per-tile path
(~2000 LOC).

**North star:** a user should not notice the replatform happened — except that
overlays can now be dragged anywhere and select/move feels as smooth as Craft.

### Revision 2026-09-23 — the Resize tab becomes a strip in Craft

Building this in the standalone `KvResizeUnifiedCanvas` (96 commits, frnd-web
PR #541, closed) produced a second 3200-line selection system next to the
7000-line `KvFabricCanvas`. The direction changed on 2026-09-22 (spec
`docs/superpowers/specs/2026-09-22-kv-craft-resize-strip-design.md`): the
Craft canvas engine is generalised over *surfaces* (Craft boards + Resize
tiles), and the tiles render as a **"Resizes" strip below the Craft boards, in
the same view** — one engine, one camera, one selection, no Resize tab and no
`canvasMode: "resize"`. Everything under **Core editing** and **Parity** holds
unchanged in that model and has shipped behind the flag (S0–S3b). What this
revision changes is **where** Resize lives (FR-11..15, §UI/UX, M3) and how the
per-tile path is retired (AC-9..11). Product decisions were taken by daffa
2026-09-22/23 and are recorded in the spec's "Decisions taken".

Background documents:
- Track: `web/docs/tracks/kv-resize-unified-canvas.track.md` (current state;
  full history at git `2d4ba735d` in frnd-web)
- Spike code: `web/src/components/studio/kv-generator/KvResizeUnifiedCanvas.tsx`,
  `renderResizeBoards.ts`, `resizeBoardLayout.ts`, `useResizeBoardContent.ts`

## User Stories

- As a **marketer editing resize tiles**, I want to drag an overlay freely —
  including parking it outside the frame while I rearrange — so that
  composing a tile feels like a real canvas tool, not a cropped box.
- As a **marketer**, I want a paste from a wider tile to land exactly as
  copied, hanging off the frame if it must, and still be visible and
  grabbable, so nothing I paste ever "disappears".
- As a **marketer**, I want select/drag/resize on Resize to feel identical to
  Craft (no roughness, no jumps), so switching between the two surfaces has no
  friction.
- As a **marketer**, I want everything I can do today — multi-select, align,
  Cmd+A/C/V, undo per tile, region edit, shapes, text editing, comment pins,
  tile download — to keep working exactly as it does now.
- As a **web maintainer**, I want ONE canvas engine and one renderer for
  Resize, so fixes land once instead of drifting across surfaces.

## Requirements

### Functional Requirements

**Core editing (world space)**

- **FR-1:** Overlays are selectable on the unified canvas, with hit-testing
  routed per board (`data.resizeBoardId`); clicking a board's overlay
  activates that board (drives the layers panel, same as tile-click today).
- **FR-2:** Drag / scale / rotate work on selected overlays and commit
  **frame-normalized** coordinates (normalized against the owning board's
  frame, not world units).
- **FR-3:** Commits route by board: master board → Yjs doc
  (`commitMasterOverlays`); tile board → per-row REST snapshot
  (`commitTileOverlays(row, …)`), preserving today's inherit-vs-snapshot
  semantics (a first edit on an inheriting tile materializes its snapshot,
  exactly as now).
- **FR-4:** An overlay may sit anywhere in world space. The board frame clips
  the *artwork* render (never bleeding onto a neighbour board — proven by the
  spike's ghost tests), while the spill renders as the existing dimmed ghost.
  There is no reachability boundary; Resize's paste `overflowAllowance`
  becomes `Infinity`, matching Craft.

**Parity (blockers for the flag flip)**

- **FR-5 (revised 2026-09-23):** Multi-select is scoped per **surface**, not
  per mode: shift-click / Cmd+A among ONE tile's overlays works on the strip;
  Craft boards stay single-select; a selection may never span a tile and a
  board (two commit sinks in one gesture) — the canvas collapses such a
  selection to the last object.
- **FR-6:** Per-tile undo/redo is preserved: each tile (and the master) keeps
  its own history stack, routed by the active board
  (`useTileOverlayHistory` semantics carried over).
- **FR-7:** Tile status states (`pending` / `generating` / `failed` / `done`)
  render on the unified canvas — these currently live in the row components
  that this project retires.
- **FR-8:** Inline text editing works (DOM `OverlayTextEditor` positioned over
  the world-space text overlay, world→screen transformed).
- **FR-9:** The existing Resize tool layer is ported to the unified surface
  with unchanged behavior: **frame tool** with full Craft-parity flow
  (candidates, pill, popover, group assembly), **shape tool** (drag gesture),
  **comment pins** (anchored to the frame rect), **overlay clipboard**
  (as-is paste per `pasteOverlays`), **align/distribute**, and per-tile
  **download / upscale / regenerate** entry points.
- **FR-10:** Keyboard behavior is preserved: Cmd+A/C/V scoping, Delete,
  Escape ladder, and typing-field guards.

**Rollout & cleanup (revised 2026-09-23)**

- **FR-11:** The strip ships behind `KV_RESIZE_UNIFIED_CANVAS` (fail-closed;
  on dev/staging additionally the `localStorage` opt-in
  `kv-resize-unified-canvas = "on"`) until the S1–S3b checklists pass; the
  Resize tab stays functional meanwhile and is HIDDEN whenever the strip is
  live for a file, so a user never sees two Resize surfaces.
- **FR-12:** Resize tiles are **surfaces in the Craft canvas** — one column per
  parent board, left-aligned under it, stacked vertically, every column
  starting from one shared baseline below the bounding box of all Craft
  boards, under a single "Resizes" divider. No master tile: the Craft board
  *is* the master. There is no `canvasMode: "resize"`; tiles inherit Craft's
  camera, tools and selection. Tile positions are derived from the layout, never
  persisted (NFR-3 unchanged).
- **FR-13:** After the checklists pass and this PRD is re-signed, the Resize
  tab and the per-tile path are deleted: `KvResizeCanvas` and its row
  components, `KvResizeViewport`, `KvTileOverlayEditor`, `KvResizeTileStage`,
  `resizeApron`, the read-only spike `KvResizeUnifiedCanvas`, and the flag
  itself. `applyMaxQualityScaling` is kept where the strip's download still
  needs it. `KvKonvaCanvas` is deleted only when the reviewer who requested the
  kill switch confirms; Konva stays in `package.json` for Motion.
- **FR-14 (new):** The Craft entry point to Resize is the **Resize** button in
  the bottom-nav tool cluster (Phosphor `Resize`, Figma KV-Generator 73-16650),
  which toggles the platform picker for the pinned board; the board context
  menu's "Send to Resize" pins that board and opens the same picker. Adding a
  size pans the camera to the new tile; the picker starts closed in Craft.
- **FR-15 (new):** Three behaviours only the Resize tab provided move to the
  strip before it is deleted: comment pins on tiles (drawn from the canvas's
  own tile rects), the Safe Zones manager previewing the active tile, and the
  Standalone Resizer (`/studio/resizer/[file_id]`) opening on the Craft strip
  with the picker open and the mode switch hidden. A file whose persisted
  `canvas_mode` is `resize` opens in Craft.

### Non-Functional Requirements

- **NFR-1 (memory):** Canvas backing store is one viewport-sized canvas
  regardless of tile count (vs ~32 MB per story tile today). No per-tile
  backing stores remain after cleanup.
- **NFR-2 (smoothness):** Selecting never resizes any canvas element or moves
  the scene origin mid-gesture (the failure the apron work fixed must not
  regress in the new model — canvas geometry is camera-only).
- **NFR-3 (layout is derived):** Resize board positions in world space are
  computed (`resizeBoardLayout.ts`, deterministic) and **never persisted** —
  in particular they must never enter `metadata.kv_canvas`, the desktop
  interop schema.
- **NFR-4 (export fidelity):** Downloads are unchanged — the export path
  already builds its own native-resolution `StaticCanvas` per tile and crops
  at the frame; overlays hanging outside the frame are cropped in exports.
- **NFR-5 (no fifth renderer):** Object construction reuses the shared
  `fabricExport.ts` builders and `renderResizeBoards.ts`; no new
  overlay-rendering code path may be introduced.

## Service Breakdown

### Frontend (`web/`)

All of it. Interaction layer on `KvResizeUnifiedCanvas` (or directly as a
`KvFabricCanvas` mode — see Open Questions), commit routing, undo routing,
tool-layer port, status UI, flag rollout, then the per-tile deletion.

### API (`api/`)

**No changes.** The existing endpoints (`kv_resize_exports` CRUD, overlay
snapshot writes, master doc writes via collab) are consumed as-is. Any change
discovered to be needed is a scope escalation requiring sign-off.

### AI Service / Data Service

Untouched.

## UI/UX

### Key Screens

**Revised 2026-09-23.** No Resize screen. In **KV Studio → Craft**, tiles
appear as a "Resizes" strip under the Craft boards: one column per parent
board (left-aligned under it, tiles stacked vertically), all columns starting
from a shared baseline below the lowest Craft board, one divider across the
boards' bounding box, no group headers (the column's position names the
parent), no master tile. Each tile carries a caption (click activates,
double-click renames, name capped in length), a header with reset-to-follow
and a download dropdown (with upscale), and the status chrome for
pending/generating/failed. Everything else (regenerate, duplicate, push master
to all tiles, ready-to-share, separate layers) is on the tile's right-click
menu. Craft's tools apply to tiles: frame → detect → regenerate the TILE
(never a board variant), text/shape/image placement, drop, paste. The chat's
"Editing …" chip names the armed tile. The mode switch keeps Motion only.

Interaction details fixed by parity (not open for redesign): tile click
activates + opens the Layers panel; Escape ladder; a selected overlay's
overflow shows as the dimmed ghost; the frame clips artwork, never selection
handles; cursor follows the tool inside a tile.

### Wireframe References

None — no new UI surface. The merged read-only spike behind
`KV_RESIZE_UNIFIED_CANVAS` + `localStorage kv-resize-unified-canvas = "on"`
**is** the visual reference, reviewed and accepted 2026-08-18.

## Data Model

No new tables. No modified tables. Guardrail (NFR-3): no resize layout data
may be added to `studio_files.metadata` (`kv_canvas`) or anywhere else.

## API Endpoints

No new or modified endpoints.

## Milestones

Restructured from the track's TASK-18–27 (ruler+grid deliberately cut — Resize
never had it; it is an enhancement, not parity, and can be its own later
feature):

| Milestone | Contents | Track tasks |
|---|---|---|
| **M1 — Core editing** | selection, drag/scale/rotate, commit routing, overflow with no boundary | 18, 20, 21 |
| **M2 — Parity + rollout** | multi-select, per-tile undo, tile status, inline text, tool-layer port (frame/shape/comment/clipboard/align), flag flip after verification | 19, 22, 23, 25, + tool port (previously unlisted) |
| **M3 — Cleanup (revised)** | strip slices S0–S3b + S4-lite shipped behind the flag (2026-09-22/23); **S4**: re-home tile comment pins, Safe Zones preview and the Standalone Resizer onto the strip, then delete the Resize tab, the per-tile path and the flag — plan `docs/superpowers/plans/2026-09-23-kv-craft-resize-strip-s4-delete.md` | 26, 27 |

M2's tool-layer port is called out explicitly because it was the hidden scope
of the original task list: frame tool, shape tool, comment pins and as-is
paste were all recently (re)built against the per-tile editor and must survive
the move.

## Risks

- **R-1 (M2 touches Craft's code — planned, not a surprise).** M1 is
  resize-only: verified 2026-08-27 that `KvFabricCanvas` imports **none** of
  the files M1 modifies (`renderResizeBoards`, `resizeBoardLayout`,
  `useResizeBoardContent`, `KvResizeUnifiedCanvas`, `KvResizeCanvas`,
  `resizeApron`). M2 is different: porting the frame tool means touching
  `boxPromptUi.tsx`, which **both** canvases import today (`CandidateChips`,
  `BoxPromptPopover` — extracted precisely so the two surfaces could not
  drift). A change there reaches Craft in production.
  *Mitigation:* treat any edit to a shared module as a Craft change — review
  it against both surfaces and verify Craft's own frame-tool flow before
  merging, rather than only the resize one.

- **R-2 (shared-module drift).** M1 must only ever CALL the shared modules
  (`fabricExport`, `ghostOverlay`, `overlayGeometry`, `overlayMutations` —
  used by 8–9 files each), never modify them. This is why M1 adds
  `resizeWorldGeometry.ts` as a wrapper around `overlayNormFromRect` instead
  of widening it. The failure mode has bitten this codebase before: a styling
  prop added to some overlay renderers but not all makes preview ≠ export.

- **R-3 (per-tile undo, M2).** No Craft equivalent exists; OQ-1 resolved to
  carry the per-board stacks as-is, but this remains the design most likely
  to need rework.

- **R-4 (deleting ~2000 LOC written weeks earlier).** `KvTileOverlayEditor`
  and its tool ports become a stepping stone. Intentional — but it should be
  a conscious call at M3, not a surprise, and includes work authored by
  fahrizky (comment pins).

## Acceptance Criteria

- [ ] AC-1: With the flag on, every editing action available today on the
  per-tile path works on the unified canvas (checklist: select, shift-click
  multi-select, marquee, Cmd+A/C/V, drag/scale/rotate, align/distribute,
  delete, undo/redo per tile, text edit, frame tool full flow, shape tool,
  comment pin, download/upscale/regenerate, region-edit send).
- [ ] AC-2: An overlay dragged or pasted fully outside a frame remains
  visible (dimmed ghost) and directly draggable — at any distance.
- [ ] AC-3: Artwork never renders across a neighbouring board's frame.
- [ ] AC-4: Editing a tile writes only that tile's row snapshot; editing the
  master writes only the doc — verified against the DB, including the
  first-edit materialization case.
- [ ] AC-5: Undo on tile A never affects tile B or the master, and vice
  versa.
- [ ] AC-6: A downloaded tile PNG is pixel-identical in framing to today's
  export for the same state (overflow cropped at the frame).
- [ ] AC-7: No canvas element changes size during any pointer gesture.
- [ ] AC-8: `metadata.kv_canvas` byte-identical before/after any Resize
  session (layout never persisted).
- [ ] AC-9 (revised): With the flag off, Craft is byte-for-byte the Craft of
  develop (the S1 regression checklist in
  `web/docs/tracks/kv-craft-resize-strip.track.md`) and the Resize tab behaves
  exactly as before — until S4 removes both the flag and the tab.
- [ ] AC-10 (revised): After S4, the deleted-file list is gone from the
  bundle, `KV_RESIZE_UNIFIED_CANVAS` no longer exists in code or PostHog, the
  kv-generator suites show no NEW failures against the S4 entry baseline, and
  `node next build` is clean.
- [ ] AC-11 (new): After S4 — a comment pin placed on a tile survives pan/zoom
  and a reload; the Safe Zones manager previews the active tile; the
  Standalone Resizer opens on the strip with the picker open and no mode
  switch; a file last saved in the Resize tab opens in Craft; every Resize
  PostHog event still fires from the strip (`resize_requested`,
  `resize_strip_toggled`, `resize_tile_overlays_edited`, `resize_tile_renamed`,
  `resize_cancelled`, `resize_tile_duplicated`, `master_pushed_to_tiles`,
  `resize_region_box_committed`, `ready_to_share_toggled` phase `resize`).

## Out of Scope

- **Motion** — heading to a standalone tool (decided 2026-08-27); it keeps
  Konva, which therefore stays in `package.json` past M3.
- **Ruler + grid on Resize** — enhancement, not parity; separate feature.
- **Master-row region edit re-enable (U1e)** — blocked on the
  generation-propagation decision (new generation empties the
  generation-scoped tile grid); pre-exists for Craft edits and is not made
  worse or better by this work.
- Any change to resize *generation* (pipelines, models, credits).
- **(2026-09-23)** A strip-level bulk ZIP download: the tab's
  `KvResizeDownloadDropdown` goes with the tab; per-tile download and the ZIP
  endpoint remain, a Craft entry point for the ZIP is its own small feature.
- **(2026-09-23)** Regenerating a layer-composed (PSD) tile with the model:
  the api refuses it; the strip greys the action out with the reason.

## Open Questions — RESOLVED 2026-08-27

All three resolved at sign-off with the recommended options:

- **OQ-1 (undo):** Carry the per-board stacks (`useTileOverlayHistory`
  semantics) as-is; redesign only if M2 verification finds a hole.
- **OQ-2 (build target):** Standalone `KvResizeUnifiedCanvas` first; merge
  into `KvFabricCanvas` at M3 — don't destabilize a 5900-line production file
  to iterate.
- **OQ-3 (rollout):** Staged via PostHog (internal → all), per
  `frndos-feature-flags` conventions.

## Sign-off

**APPROVED 2026-08-27** — fahrizky + daffa (web owners), Jeff. Relayed by
daffa in-session. Scope guardrails accepted as written (api untouched;
ruler+grid cut; Motion standalone; U1e stays disabled).

**RE-SIGNED 2026-09-23 (revision 2026-09-23)** — required before S4 (deletion)
starts; S0–S3b are additive and stay behind the flag regardless. Changes to
approve: FR-5, FR-11..15, §UI/UX Key Screens, M3, AC-9..11, Out of Scope.
Reviewers: fahrizky (web owner), Jeff; the KvKonvaCanvas reviewer answers
separately whether the Konva fallback may go (FR-13).

- [x] fahrizky — date: 2026-09-23 (relayed by daffa in-session)
- [x] Jeff — date: 2026-09-23 (relayed by daffa in-session)
- [x] KvKonvaCanvas — **delete**, date: 2026-09-23. The decision was handed back
  to daffa, who chose delete on this evidence: the `show-kv-multi-board` kill
  switch is not defined in PostHog (FRnD_OS 389744, FRnD_V1.0 127788), so
  posthog-js returns `undefined` and the fail-open gate always picks Fabric —
  the Konva path is unreachable in production; and after S4 the fallback would
  drop Resize, boards, comments and collab entirely, so it is no longer a
  usable rollback (a revert + redeploy is). Konva stays for Motion.
