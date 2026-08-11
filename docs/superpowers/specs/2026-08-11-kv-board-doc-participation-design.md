# KV Board-Doc Participation — Design Spec

> **Status:** draft
> **Author:** daffa
> **Created:** 2026-08-11
> **Services:** web only
> **Topic slug:** kv-board-doc-participation
> **Part of:** `2026-08-10-kv-canvas-surface-unification-design.md` — this settles the blocker that spec names, and must land before its step 2b (the layout seam).

## The problem

The Craft canvas attaches a board map in the Yjs doc for every board it draws
(`ensureBoardMap`), and `useKvBoardMaterialization` PATCHes that doc into the
file's persisted `canvas_state.artboards`. The Fabric binding also writes a
board's centre into the doc when it is dragged
(`lib/kv/yjsBinding.ts:210`).

Both behaviours are correct for a Craft board and wrong for a Resize export
tile. Draw a tile through this canvas as-is and two things happen, neither of
them loudly:

1. A **phantom artboard** keyed by the export id is minted and persisted into
   the Craft canvas state.
2. The Resize view's column layout **overwrites the Craft artboard centres**,
   because the binding treats any drawn board's position as doc-owned.

This is the same class of failure as the board-name data loss fixed on
2026-08-10 (`4f99689b`, `0cc89935`): a writer treating a doc as authoritative
in a context where it is not, with a full-replace PATCH behind it.

## What is already true

The distinction this spec formalises is **already practised** — it has just
never been stated, so the canvas has to infer it:

| Surface | Board map in doc | Overlay edits go to | Position owned by |
|---|---|---|---|
| Craft board | yes | doc (`docAddOverlay` etc.) | doc (drag persists) |
| Resize **master row** | yes — it *is* a Craft board | doc, via `handleCommitProjectOverlays` | the view (a fixed row) |
| Resize **export tile** | no | REST, `updateOverlays.mutate({exportId, overlays})` | the view (a fixed row) |

The master row is the row that matters. It is doc-backed for overlays but
view-positioned, so any model with a single "is collaborative" flag is wrong on
that line — and that line ships today.

## Decisions taken

| Decision | Choice | Why |
|---|---|---|
| Export-tile overlays | Stay REST, per export | A resize tile is a derivative that can be regenerated at will, not a shared asset. REST is already its source of truth. Keeps collaboration off a surface never designed for it. |
| Board positions in the Resize view | Owned by the view; boards are not draggable there | Matches Resize today (a scrollable list of results) and makes it impossible for the Resize layout to disturb Craft's artboard centres. |
| Should tiles become collaborative later? | Not designed for | YAGNI. If it is ever wanted it is a product decision with its own spec, not an abstraction carried speculatively. |

## The model

A surface declares two things:

```
docBoardId: string | null   // the doc board key this surface owns, or null
layout: "doc" | "view"      // who decides where it sits
```

**Where overlays go is derived, not declared:** `docBoardId != null` → the doc;
`null` → REST, keyed by the surface's own id. A third field would let the two
drift apart, and there is no case that needs them to.

Filled in for the three surfaces that exist:

| Surface | `docBoardId` | `layout` | Overlays (derived) |
|---|---|---|---|
| Craft board | its generation id | `doc` | doc |
| Resize master row | its generation id | `view` | doc |
| Resize export tile | `null` | `view` | REST per export |

## What changes in code

**`ensureBoardMap` stops guessing.** It is called only when `docBoardId != null`,
and keyed by `docBoardId` rather than by the surface's id. A phantom artboard
becomes impossible *by construction* rather than prevented by a guard that can
leak: an export tile has no `docBoardId`, so it has no board map, so there is
nothing for materialization to persist.

**The binding's position write is gated on `layout === "doc"`.** In the Resize
view boards are additionally not draggable, so there are two independent layers:
nothing can move them, and nothing would be written if it did.

Nothing else about the doc changes. Overlay ops, presence, undo, and the
materialization guard added on 2026-08-10 all stay as they are.

## Testing

Every part of this is testable without a canvas, which is the point — the Fabric
canvas cannot be component-tested (Fabric needs a real 2D context; jsdom has
none), so the rules must live somewhere pure.

- The mapping from a surface source (Craft board / master row / export tile) to
  its `(docBoardId, layout)` pair.
- The derived overlay sink follows `docBoardId`.
- **The guard that matters most:** no export id may ever appear as a key in
  `doc.boards`. This catches exactly the failure class this spec exists to
  prevent, and it is a pure assertion over a doc snapshot.
- A regression case for the position rule: a surface with `layout: "view"`
  produces no board-centre write.

## What this unblocks

With participation stated on the surface rather than inferred from context, the
canvas no longer needs to know which view is using it. That is the precondition
for step 2b (the layout seam — a view supplying its own board positions) and
step 3 (the Resize view itself).

## Out of scope

Making Resize collaborative. Migrating export-tile overlays into the doc.
Changing undo semantics. Touching the Motion editor. Any change to what
`canvas_state` persists.
