# KV Canvas Surface Unification — Design Spec

> **Status:** draft
> **Author:** daffa
> **Created:** 2026-08-10
> **Services:** web only
> **Topic slug:** kv-canvas-surface-unification
> **Prompted by:** a request for ghosted (dimmed) preview of overlay content that
> falls outside the tile frame. That feature was parked — it is cheap on Craft
> and expensive on Resize *only because* the two surfaces are built differently.
> Unifying them makes it a one-place change. See "Follow-on" at the end.

## Overview

KV renders the same thing — a board with a base image and a stack of overlays —
through **three separate live display implementations**, plus one shared
offscreen flatten. Every drawing rule has to be restated in each one, and each
restatement is a chance for the preview to stop matching the download.

| Surface | Engine | Shape | How content gets cropped |
|---|---|---|---|
| Craft multi-board | Fabric | one world canvas, pan/zoom | `clipPath` per object |
| Craft fallback | Konva | one world canvas, pan/zoom | `clipFunc` per Group |
| Resize | Konva | N stages stacked as DOM rows | raster edge — no clip at all |
| Download / Motion export | Konva | offscreen, one board | `clipFunc` (already shared) |

The flatten path is already unified: Resize downloads, Craft downloads, and
Motion export all go through `renderBoardStage.ts`
(`renderHiddenStage` / `buildBoardStage`). Only the **live display** is
triplicated.

This spec unifies the live display onto **one engine with two views**: Craft
and Resize render through the same world-canvas component, differing only in
which boards they are given and how those boards are laid out.

### Why now

Two costs are already being paid:

1. **Rule drift.** Each renderer carries comments instructing the reader to keep
   it in sync with the other three: base and overlays must share one Konva Layer
   or every blend mode silently degrades to normal; rotation must pivot the
   visual center; overlay height normalizes against canvas height, not the box;
   `payload.hidden` must skip rendering. This has already produced shipped bugs
   where a styling property was added to some renderers but not all, and the
   preview stopped matching the export.
2. **Master-vs-tile branching.** Because the Resize master row and result rows
   are different kinds of object in code, nearly every handler in
   `KvResizeCanvas.tsx` is written twice —
   `if (isMasterActive) { commitMasterOverlays(…) } else { commitTileOverlays(…) }`
   — for lock, replace-image, place, select, and the rest. To the user both are
   just "an image I can edit".

## Decisions taken

| Decision | Choice | Why |
|---|---|---|
| Shape | One engine, two views | Kills the duplicate renderer without changing how Resize reads to the user. Craft and Resize stay separate tabs. |
| Engine | Fabric | The Craft canvas carries Yjs collaboration, presence, multi-select, and PSD import. Porting that to Konva is not realistic; porting Resize's tile editor to Fabric is. |
| Flatten path | Unchanged (Konva, offscreen) | Already shared by all three surfaces. Nothing to gain from touching it. |
| Motion editor | Out of scope | Its interaction model is a timeline with keyframes and playback; "a board in a world" may not be the right shape for it. Revisit once the engine is proven. |
| Rollout | Straight replacement, no feature flag | Explicit call by the author. Mitigated by ordering: the old path is deleted only after parity tests are green (see Work order). |
| Konva fallback (`KvKonvaCanvas`) | Deleted | Keeping it means still maintaining a second world, which is the thing being removed. **Open item:** this fallback exists as a kill switch requested in review when multi-board landed (`KvCanvas.tsx` ~line 404). Confirm with that reviewer before the PR opens. |

## Architecture

### The engine

`KvFabricCanvas` is generalized into a single world-canvas engine. It owns:

- the Fabric canvas, pan/zoom, and the world coordinate system
- board rendering (frame, base image, label)
- overlay rendering, selection, transform, snap guides
- the clip rule (overlays crop to their own board's bounds)
- Yjs document binding, presence, and multi-select

It does **not** own: which boards exist, where they sit, or what chrome each
board carries. Those come from the view.

### The two views

A view supplies a board set and a layout strategy.

- **Craft view** — boards resolved from persisted artboard centers, falling back
  to auto-tiling in a row (today's `boardLayout.ts` behavior, unchanged).
- **Resize view** — boards laid out as a single vertical column: the master
  board on top, one board per export below it, in the current row order.

### Board model

`KvBoard` today is welded to `KvGeneration` (`boardLayout.ts:21`): it carries a
generation, a version chain, and a master flag. A Resize tile is not a
generation — it is a per-platform export with its own target size and its own
async lifecycle. The model generalizes to a rendered surface:

```
id            board key
size          target width/height in board units
baseImageUrl  string | null   (null = layer-composed board, e.g. PSD import)
overlayScope  which overlays this board hosts
status        "ready" | "pending" | "failed"
label         caption text
isMaster      boolean
actions       what chrome this board offers (see below)
```

Craft boards are always `ready` and derive size from the rendered image. Resize
tiles take status and size from their export row. **The master row becomes an
ordinary board with `isMaster: true`** — this is what removes the
master-vs-tile branching described above; there is one commit path, and the
board's own scope decides where the write lands.

### Per-board chrome stays DOM

Platform label, download dropdown, regenerate toggle, the loading skeleton, and
the failed-state card with Retry/Discard are **not** redrawn as canvas objects.
They stay React components, positioned over the canvas via `worldPointToScreen`
so they follow pan and zoom. Craft already does exactly this for
`BoxPromptPopover` (`KvKonvaCanvas.tsx:1367`).

This matters for accessibility and for keeping the existing PostHog event
wiring intact — the buttons stay buttons.

### Keeping the list feel

The Resize view constrains the world so it still reads as a scrollable list of
results:

- vertical scroll maps to vertical pan
- horizontal pan is locked
- zoom stays on the existing zoom pill
- clicking a board activates it (opens the Layers/properties panels on it),
  matching today's behavior

Craft's view keeps free two-axis pan and zoom.

## The blocker nobody had named — found reviewing step 2a

Every board the Craft canvas draws gets a Y.Doc board map attached to it
(`ensureBoardMap`), and `useKvBoardMaterialization` observes that map and
PATCHes it into the file's persisted `canvas_state.artboards`. Feeding a Resize
export tile through the same canvas would therefore mint a **phantom artboard
keyed by the export id and persist it into the Craft canvas state**.

This is not a typing problem, and `KvSurface` does nothing about it. Before a
Resize tile can be drawn by this canvas, **board-doc participation has to become
an explicit property of the surface** rather than something the canvas infers
from context.

**Settled 2026-08-11** — see `2026-08-11-kv-board-doc-participation-design.md`.
A surface declares `docBoardId` (the doc board key it owns, or null) and
`layout` (`doc` or `view`); where its overlays go is derived from the first.
Note the decision is per-surface, not per-view: the Resize **master row** is
doc-backed for overlays but view-positioned, which rules out any single
"is collaborative" flag. That spec also names a second hazard this section
missed — the binding writes a dragged board's centre into the doc, so a Resize
column layout would have overwritten Craft's artboard centres.

Related, smaller, and on the same list: `isConceptPreview` lives on `KvBoard`
rather than the surface, roughly eight helper signatures inside the canvas are
still typed `KvBoard` (mechanical retypes — `ensureBoardMap` for instance reads
only `id`/`center`/`name`/`version_ids`, all of which the surface carries), and
`onSelectBoard` feeds `setViewingGenerationId`, which genuinely wants a
*generation* id. That last one is the single place where `board.id ===
generation.id` is load-bearing on a consumer's semantics rather than on an
internal comparison, so it needs a real decision, not a rename.

## What gets deleted

- `KvResizeTileStage.tsx`
- `KvTileOverlayEditor.tsx`
- the Konva half of `KvResizeResultRow.tsx` (the chrome survives)
- `KvKonvaCanvas.tsx` and its fallback branch in `KvCanvas.tsx` (pending the
  open item above)
- three copies of the drawing rules: clip, single-Layer-for-blend, rotation
  pivot, height normalization, hidden-layer skip

Roughly 1,900 lines of duplicated display code.

## The real risk: display ↔ export parity

Every existing renderer carries a comment saying its geometry must match
`renderHiddenStage` exactly, because the display *is* the promise the download
has to keep. A coordinate shift that is invisible on screen shows up as a
wrong-looking downloaded file — the worst kind of bug to catch late.

Mitigation: **geometry moves out of the renderers into a pure module** that both
the display path and the flatten path consume, and that module is where the
tests live. Fabric is effectively un-assertable in jsdom (no canvas context), so
testing the renderer directly is not an option — the pure module is the seam
that makes this testable at all.

**Found while planning step 1:** the five renderers already disagree. Text
overlays with no explicit `payload.fontSize` (created before custom fonts
landed) render at the full box height in `renderBoardStage`,
`KvResizeTileStage`, and `KvTileOverlayEditor`, but at `0.8 ×` box height in
`KvFabricCanvas:1537` and `KvKonvaCanvas:1876` — so legacy text draws ~20%
small on both Craft canvases and then exports bigger. Resolution: full box
height wins, because downloads are artifacts already in the wild. The two Craft
canvases change. This is exactly the failure mode this spec exists to end.

Parity cases that must be covered:

- a rotated overlay (pivot must be the visual center)
- an overlay larger than its board (crop behavior)
- text with auto-fit / explicit `fontSize` and multi-line wrap
- a board with no base image (PSD / layer-composed)
- a hidden (`payload.hidden`) layer
- a board whose target aspect differs from the source (the Resize case)

## Work order

Each step is reviewable on its own, and the old path survives until the last one.

1. **Extract** the overlay geometry into a pure module and switch all five
   renderers onto it, so the formula exists once. Inert apart from one agreed
   fix (see below). Plan: `docs/superpowers/plans/2026-08-10-kv-canvas-geometry-extraction-web.md`.
2. **Generalize** the board model and `KvFabricCanvas` into the engine plus a
   layout strategy, and move Craft onto it. The board model belongs here rather
   than in step 1 because generalizing it only pays off once an engine consumes
   it. Craft must behave identically; this is the step where regressions would
   hit the surface people use most.
3. **Build** the Resize view on the same engine, with per-board chrome
   positioned in world space.
4. **Delete** the old Resize stages and the Konva fallback.

## Testing

- **Unit (`bun test`)** — the pure geometry module, including every parity case
  listed above. This is the primary safety net.
- **Component** — the Resize layout strategy: board order, column placement,
  master on top, status-driven chrome.
- **Analytics** — assert the existing Resize PostHog events still fire (arm
  regenerate, download one/all, overlay edits). Handlers moving between
  components is a common way these disappear silently.
- **Manual e2e** (author): new resize, regenerate, cancel, failed-state retry
  and discard, download one and all, editing overlays on both the master board
  and a result board, and a PSD board with no base image.

Note on the test runner: `web/` uses `bun test` (bunfig preloads jest-dom), not
`bunx vitest`, and the real gate is `bun run build`.

## Follow-on

Once the display is one engine, the feature that prompted this becomes a small,
single-place change: **ghosted overflow** — when a layer is selected or being
dragged, the part of it falling outside its board renders at 25% of the layer's
opacity, beneath all boards, so the user can see where the image actually
extends. On the current architecture this is half a day on Craft and a stage-
padding rewrite on Resize; on the unified engine it is one inverted clip.

Design already agreed for that follow-on: ghost appears only for the selected or
dragging layer; drawn beneath board content so it never pollutes a neighbouring
board; ghost objects are tagged so they can never be mistaken for overlays by
the document sync or the export path.
