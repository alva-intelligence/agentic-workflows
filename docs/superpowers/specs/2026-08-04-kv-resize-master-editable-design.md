---
title: KV Resize — editable master row
slug: kv-resize-master-editable
author: daffa
created: 2026-08-04
status: draft
services: [web]
---

# KV Resize — editable master row

## Problem

The Resize surface shows the source KV as a read-only "original" row above the
generated tiles. Every tile is editable; the master is not. When an overlay sits
wrong across every size, the only fix is to reposition it once per tile.

The ask: edit the master once and have the tiles follow.

## Current state

| | renders | overlays from | writes to |
|---|---|---|---|
| Master (`KvResizeOriginalRow`) | `KvResizeTileStage` (read-only) | `useKvOverlaysStore` → Craft Yjs doc | nothing |
| Result tiles (`KvResizeResultRow`) | `KvTileOverlayEditor` | `row.overlays` snapshot, else projected from master | per-tile REST snapshot |

Two facts discovered during design shape everything below:

1. **The cascade already exists.** `KvResizeResultRow` calls
   `resolveTileOverlays(row.overlays, projectOverlays, …)` every render, and
   `projectOverlays` is reactive from the store. A tile with no snapshot
   re-projects the moment the master changes. No new propagation code.
2. **The doc is authoritative, not the store.** `doc.overlays.observeDeep` →
   `projectFromDoc` feeds the store (`KvGeneratorLayout.tsx:616`), and a
   debounced autosave persists to the backend (line 2166). Writing to the store
   directly would be reverted on the next doc observation. Master edits must go
   through `docUpdateOverlay` / `docAddOverlay` / `docRemoveOverlay`.

`KvResizeCanvas` is already rendered inside `KvGeneratorLayout` (line 116), so
the doc handle and its ops are in scope without restructuring.

## Decisions

- **The master IS the Craft KV.** Editing it changes the Craft board, and
  broadcasts to collaborators on the doc. Rejected: a Resize-local override
  layer — it would add a third overlay state between doc and tile snapshot, and
  doc↔snapshot divergence is already the source of this surface's worst bugs.
- **Full parity with the tiles.** The master gets the same editor: move,
  transform, multi-select, add text/image/shape, delete, restyle.
- **Hand-tuned tiles are never silently overwritten.** A tile with its own
  snapshot keeps it and stops following the master. A separate explicit
  **Push to all tiles** action re-inherits every tile when that is what the
  user wants.

## Design

### Data flow

```
master edit → onChange(next[])
  → diffOverlayArrays(projectOverlays, next)
  → per-id doc ops (docAdd / docUpdate / docRemove)
  → Yjs doc  [authoritative]
  → observeDeep → projectFromDoc → store
  → projectOverlays changes → inheriting tiles re-project
  → debounced autosave → studio_files.overlays
```

### New module: `src/lib/studio/kv/overlayDiff.ts`

`KvTileOverlayEditor.onChange` returns a whole array; the doc API is per-id.
This pure adapter bridges them, and is the only genuinely new logic.

```ts
type OverlayDiff = {
  added: StudioOverlay[];
  updated: { id: string; patch: Partial<StudioOverlay> }[];
  removed: string[];
};

diffOverlayArrays(prev: StudioOverlay[], next: StudioOverlay[]): OverlayDiff
```

Rules:

- Membership by `id`. Present in `next` only ⇒ added; in `prev` only ⇒ removed.
- For overlays in both, `patch` carries only fields whose value changed, so a
  drag writes `{x, y}` and not the whole overlay. This keeps doc updates small
  and avoids clobbering fields a collaborator changed concurrently.
- `updated_at` alone never counts as a change (it moves on every commit).
- Equal arrays ⇒ all three lists empty, so a no-op gesture issues no doc ops.

### Layout wiring

`KvGeneratorLayout` passes `KvResizeCanvas` one new prop, mirroring the handlers
it already gives the Craft canvas:

```ts
onCommitProjectOverlays?: (next: StudioOverlay[]) => void
```

Its implementation diffs against the current `projectOverlays` and issues the
matching doc ops. All doc knowledge stays in the layout; `KvResizeCanvas`
remains doc-agnostic. When `kvDoc` is absent the handler is omitted and the
master stays read-only — the same no-doc fallback the rest of the surface uses.

### Master row

`KvResizeOriginalRow` swaps `KvResizeTileStage` for `KvTileOverlayEditor`, with
`overlays={projectOverlays}` and `onChange={onCommitProjectOverlays}`. Drag,
transform, multi-select, Cmd+A, delete and the style panels are inherited
unchanged. The row falls back to the read-only stage when no commit handler is
supplied.

### Selection

`activeTileId` indexes into `exports`; the master is not a member. A
`MASTER_ROW_ID = "__master__"` sentinel makes the master selectable as the
active row, so the existing selection state, Layers-panel binding and Transform
panel work without modification. `activeRowOverlays` resolves to
`projectOverlays` when the sentinel is active.

Selection remains scoped to one row — the editor already drops ids absent from
its own `overlays` array, which covers the master the same way it covers tiles.

### Push to all tiles

A button on the master row header. Sets every tile's `overlays` to `null`,
which is N× the existing per-tile Reset — each tile then re-derives through
aspect projection.

Deliberately **not** a verbatim coordinate copy: re-inheriting sends each tile
back through `resolveTileOverlays`, so a 1080×1920 story gets a layout suited to
its shape instead of the master's landscape coordinates.

Requires confirmation, since it discards every per-tile edit. Disabled when no
tile has a snapshot.

### Divergence marker

A tile with a snapshot no longer follows the master. Its existing Reset button
gains a label making that explicit ("Not following master — reset to follow"),
so the mixed population is visible rather than silent.

## What comes free

Undo (doc undo already covers overlays — "boards AND overlays are both
doc-authoritative", `KvGeneratorLayout.tsx:662`), persistence via the existing
debounced autosave, live collaborator broadcast, and the cascade to inheriting
tiles.

## Testing

Unit tests for `overlayDiff.ts`:

- added / removed / updated detected by id
- `patch` contains only changed fields; a move yields `{x, y}` only
- `updated_at`-only differences produce no update
- identical arrays produce three empty lists
- reordering without value changes produces no ops

Component coverage stays thin — every component test under
`src/components/studio/kv-generator/` currently fails on a pre-existing
`@testing-library`/bun issue unrelated to this work.

Manual verification: move an overlay on the master and confirm every
un-edited tile follows; confirm a hand-edited tile does not; confirm Cmd+Z
undoes the master edit; open Craft and confirm the overlay moved there too;
run Push to all tiles and confirm every tile re-derives.

## Risks

- **Delete cascades.** Deleting on the master removes the overlay from the Craft
  KV and from every inheriting tile at once. It looks identical to deleting on a
  tile but is far broader. Accepted as a consequence of full parity, and it
  takes **no extra confirmation**: the deletion is a doc op, so Cmd+Z restores
  it along with every tile that re-derived. Push to all tiles *does* confirm,
  because clearing snapshots discards per-tile work that undo does not recover.
- **Two homes for authoring.** Adding text on the master and adding it in Craft
  are now the same operation in two places, and can drift.
- **Editing mid-generation.** Tiles already generating were derived from the old
  master. Behaviour is untraced; implementation should confirm an in-flight tile
  is not left in a mixed state.
- **Concurrent edits.** Field-level patches reduce, but do not eliminate, the
  chance of stomping a collaborator editing the same overlay in Craft.

## Out of scope

- A Resize-local override layer for the master.
- Reconciling the two authoring homes.
- Propagating master edits into tiles that already have snapshots, other than
  via the explicit Push to all tiles action.
