# Design — Tile-aware Layers panel (Craft)

- **Date:** 2026-07-15
- **Author:** Daffa (via Claude)
- **Service:** web (`frnd-web`)
- **Branch:** `develop` (implement directly, per owner decision)
- **Status:** approved (design), pending spec review

## Overview

In Craft (multi-board) mode the Layers panel lists **every** overlay across all
tiles in one flat global list. This makes the panel scope the overlay list to the
**currently-selected tile (board)**: select a tile → see only its overlays; when
no tile is selected → show an empty hint. Overlays are already tile-bound at the
data level (`board_generation_id`); this aligns the panel with that model.

## Goals

- The Craft Layers panel shows only overlays bound to the selected tile.
- No tile selected → an empty hint ("Click a tile to view its layers.").
- Show the selected tile's name next to the "Layers" title.
- Keep the brand-preset section + "Save" (do NOT enable `tileMode`).

## Non-Goals

- Grouping all overlays by tile (rejected in favor of filtering).
- Showing legacy `board_generation_id === null` overlays (hidden when filtering).
- Changing the Resize tile panel (already tile-scoped) or the Konva fallback.
- Changing how overlays bind to boards (placement already sets the binding).

## Key Decisions

1. **Filter to the selected tile** (not group, not badge).
2. **Empty + hint when no tile is selected.**
3. **Legacy null-bound overlays are hidden** when filtering.
4. **Selected tile = `viewingGenerationId`** (the pinned board), set by
   `onSelectBoard` / cleared by `onDeselectBoard`.
5. **Reuse the panel's existing `emptyState` + `tileLabel`**, decoupling their
   rendering from `tileMode` so presets stay visible in Craft.

## Current State (as-is)

- **Selection state:** `viewingGenerationId` in `KvGeneratorLayout.tsx`.
  `<KvCanvas onSelectBoard={(id) => setViewingGenerationId(id, {explicitPin:true})}`
  `onDeselectBoard={() => setViewingGenerationId(null)}` (~lines 3118–3122).
- **Overlay→board binding:** `overlay.board_generation_id`; `overlayHostRect`
  (`KvFabricCanvas.tsx`) matches it to a board by `board.id` or
  `board.version_ids.includes(boundId)`. Null → renders on the active board.
- **Panel feed:** the main Craft `KvLayersPanel` mount is passed the global
  `overlays` (`KvGeneratorLayout.tsx` ~line 3374).
- **Panel already has, but gated on `tileMode`:**
  - `tileLabel?: string` — rendered at `KvLayersPanel.tsx:275`
    (`{tileMode && tileLabel && …}`).
  - `emptyState?: "no-tile" | "no-overlays" | null` — rendered at
    `KvLayersPanel.tsx:421–428` (`{tileMode && emptyState === "no-tile" ? …}`),
    copy: "Click a tile to view its layers." / "This tile has no overlays…".
- **Board version chains:** `computeBoardLayout(stream.generations, docCanvasState,
  …)` returns `artboards` keyed by generation id, each with `version_ids` (and a
  `name`). Used across the layout (e.g. lines 430, 619).

## Design

### 1. `KvLayersPanel` — decouple tile empty-state / label from `tileMode`

Backward-compatible change so the Craft panel can use these without enabling
`tileMode` (which would hide presets):

- Line ~275: `{tileMode && tileLabel && (…)}` → `{tileLabel && (…)}`.
- Line ~421–428: drop the `tileMode &&` guard on both `emptyState` branches:
  - `emptyState === "no-tile"` → "Click a tile to view its layers."
  - `emptyState === "no-overlays"` → neutral copy: **"This tile has no
    overlays yet."** (change from the Resize-specific "…Add some in Craft, then
    return here." so it reads correctly in both Craft and Resize).

This is safe: Resize (tileMode=true) still passes `emptyState`/`tileLabel`
(unchanged render); Craft historically passes neither (nothing renders today).

### 2. `KvGeneratorLayout` — derive tile-scoped panel inputs

Add memoized derivations near the overlay wiring:

```ts
// Version-id set of the selected tile (a board owns a version chain). null when
// no tile is selected.
const selectedTileVersionIds = useMemo<Set<string> | null>(() => {
  if (!viewingGenerationId) return null;
  const layout = computeBoardLayout(stream.generations, docCanvasState);
  for (const [genId, ab] of Object.entries(layout.artboards)) {
    const vids = ab.version_ids ?? [genId];
    if (genId === viewingGenerationId || vids.includes(viewingGenerationId)) {
      return new Set(vids);
    }
  }
  return new Set([viewingGenerationId]);
}, [viewingGenerationId, stream.generations, docCanvasState]);

// Overlays bound to the selected tile (legacy null-bound are excluded).
const panelOverlays = useMemo(() => {
  if (!selectedTileVersionIds) return [];
  return overlays.filter(
    (o) => o.board_generation_id != null &&
           selectedTileVersionIds.has(o.board_generation_id),
  );
}, [overlays, selectedTileVersionIds]);

// Empty-state signal for the panel.
const panelEmptyState: "no-tile" | "no-overlays" | null =
  !viewingGenerationId ? "no-tile" : panelOverlays.length === 0 ? "no-overlays" : null;

// Selected tile's display name for the panel title.
const selectedTileLabel = useMemo<string | undefined>(() => {
  if (!viewingGenerationId) return undefined;
  const layout = computeBoardLayout(stream.generations, docCanvasState);
  for (const [genId, ab] of Object.entries(layout.artboards)) {
    const vids = ab.version_ids ?? [genId];
    if (genId === viewingGenerationId || vids.includes(viewingGenerationId)) {
      return ab.name ?? undefined;
    }
  }
  return undefined;
}, [viewingGenerationId, stream.generations, docCanvasState]);
```

(The exact `computeBoardLayout` option argument matches its existing call sites;
if a third options arg is required, pass the same shape used at line ~430. The
two memos that resolve the board may be merged into one that returns
`{ versionIds, name }`.)

### 3. Wire the main Craft `KvLayersPanel` mount

At the mount (~line 3374), change:
- `overlays={overlays}` → `overlays={panelOverlays}`
- add `emptyState={panelEmptyState}`
- add `tileLabel={selectedTileLabel}`

Leave `onReorder` as-is: it calls `reorderOverlays(overlays, fromId, toId)` on the
GLOBAL overlays by id; the fromId/toId from a filtered row are still valid ids, so
reordering within a tile reindexes the global z consistently.

## Data Flow

```
Select a tile on canvas → onSelectBoard(genId) → setViewingGenerationId(genId)
  → selectedTileVersionIds (memo, via computeBoardLayout)
  → panelOverlays = overlays.filter(bound to selected tile)
  → <KvLayersPanel overlays={panelOverlays} emptyState={…} tileLabel={…} />
Deselect (empty canvas click) → viewingGenerationId=null → emptyState="no-tile"
```

## Edge Cases

- **No tile selected:** `panelOverlays = []`, `emptyState = "no-tile"` → hint.
- **Tile selected, no overlays:** `emptyState = "no-overlays"` → "This tile has
  no overlays yet."
- **Legacy null-bound overlays:** excluded from every tile's list (Decision 3).
- **Selected overlay on a different tile:** simply not in the filtered list; its
  highlight only shows when its tile is the viewed one.
- **`viewingGenerationId` auto-pinned (not explicit):** treated as the selected
  tile — the panel shows that tile's overlays. The "no-tile" hint appears only
  when nothing is pinned. (Acceptable; a stricter "explicit-only" variant is a
  possible refinement, not in scope.)
- **Reorder within a tile:** operates on global z by id; consistent.

## Testing

- Unit (bun test): a pure `overlaysForTile(overlays, versionIds)` helper (extract
  the filter) — returns only overlays whose `board_generation_id` ∈ versionIds,
  excludes null-bound. Assert both.
- Component (bun test): `KvLayersPanel` renders the `tileLabel` and the
  `emptyState` hints **without** `tileMode` (guards decoupled); still renders them
  with `tileMode` (Resize regression).
- Manual e2e (Craft, multi-board): select tile A → only A's overlays; select tile
  B → only B's; deselect → "Click a tile to view its layers."; a tile with no
  overlays → "This tile has no overlays yet."; title shows the tile name.
- Gate: `bun run build` passes.

## Files Touched

- `web/src/components/studio/kv-generator/KvLayersPanel.tsx` — decouple
  `tileLabel` + `emptyState` rendering from `tileMode`; neutralize "no-overlays"
  copy.
- `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx` — derive
  `selectedTileVersionIds` / `panelOverlays` / `panelEmptyState` /
  `selectedTileLabel`; wire them into the main Craft `KvLayersPanel` mount.
- (optional) `web/src/lib/studio/kv/overlayMutations.ts` (or a small new module) —
  pure `overlaysForTile` helper + test.

No backend, serializer, store, or type changes. The Resize tile panel and the
Konva fallback are untouched.
