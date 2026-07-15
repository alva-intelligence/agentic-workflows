# Tile-aware Layers Panel — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In Craft (multi-board) mode, scope the Layers panel's overlay list to the currently-selected tile, with an empty hint when no tile is selected.

**Architecture:** `viewingGenerationId` is the selected tile. Reuse the existing `shareBoards` memo (craft board layout: `{id, versionIds, name}`) to resolve the selected tile's version chain, filter `overlays` to that chain, and pass the filtered list + `emptyState` + `tileLabel` to the main Craft `KvLayersPanel`. Decouple the panel's existing `emptyState`/`tileLabel` rendering from `tileMode` so presets stay visible.

**Tech Stack:** Next.js 16 / React 19 / TypeScript, Zustand + Yjs, bun test.

## Global Constraints

- Service: **web** only. Work directly in the develop worktree:
  `/Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/develop`.
  Paths written as `web/src/...` map to `<worktree>/src/...`. Commits land on
  `develop` (intended). Do NOT touch the main `web/` checkout.
- No backend, serializer, store, or type changes. Pure client-side filter.
- Only the **main Craft** `KvLayersPanel` mount changes. The Resize tile panel and
  the Konva fallback are untouched.
- An overlay belongs to a tile iff `overlay.board_generation_id != null` AND it is
  in the tile's version chain. Legacy null-bound overlays are excluded (hidden).
- No tile selected (`viewingGenerationId == null`) → `emptyState="no-tile"`, empty
  list. Tile selected, no overlays → `emptyState="no-overlays"`.
- Keep the brand-preset section + "Save" (do NOT set `tileMode`).
- Real gate is `bun run build`. Unit tests run with `bun test`.
- Commit after each task, prefix `feat(web):`.

---

### Task 1: `overlaysForTile` pure filter helper

**Files:**
- Modify: `web/src/lib/studio/kv/overlayMutations.ts` (append export)
- Test: `web/src/lib/studio/kv/overlayMutations.test.ts` (append)

**Interfaces:**
- Produces: `overlaysForTile(overlays: StudioOverlay[], versionIds: Set<string>): StudioOverlay[]`
  — returns overlays whose `board_generation_id` is non-null AND in `versionIds`.

- [ ] **Step 1: Write the failing test**

Append to `web/src/lib/studio/kv/overlayMutations.test.ts`:

```ts
import { overlaysForTile } from "./overlayMutations";
import type { StudioOverlay } from "@/types/studio";

const ov = (id: string, board: string | null): StudioOverlay =>
  ({ id, board_generation_id: board, type: "image",
     payload: { type: "image", asset_url: "u", mime_type: "image/png" } } as unknown as StudioOverlay);

describe("overlaysForTile", () => {
  it("keeps only overlays bound to an id in the version set", () => {
    const overlays = [ov("a", "g1"), ov("b", "g2"), ov("c", "g3")];
    const result = overlaysForTile(overlays, new Set(["g1", "g3"]));
    expect(result.map((o) => o.id)).toEqual(["a", "c"]);
  });

  it("excludes null-bound (legacy) overlays", () => {
    const overlays = [ov("a", null), ov("b", "g1")];
    const result = overlaysForTile(overlays, new Set(["g1"]));
    expect(result.map((o) => o.id)).toEqual(["b"]);
  });

  it("returns empty when no overlay matches the version set", () => {
    const overlays = [ov("a", "g9")];
    expect(overlaysForTile(overlays, new Set(["g1"]))).toEqual([]);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web/.worktrees/develop && bun test src/lib/studio/kv/overlayMutations.test.ts`
Expected: FAIL — `overlaysForTile is not a function`.

- [ ] **Step 3: Write minimal implementation**

Append to `web/src/lib/studio/kv/overlayMutations.ts`:

```ts
/**
 * Overlays belonging to a tile (board), matched by the tile's version chain.
 * Legacy overlays with a null `board_generation_id` are excluded — they bind to
 * no specific tile.
 */
export function overlaysForTile(
  overlays: StudioOverlay[],
  versionIds: Set<string>
): StudioOverlay[] {
  return overlays.filter(
    (o) => o.board_generation_id != null && versionIds.has(o.board_generation_id)
  );
}
```

(If `StudioOverlay` isn't already imported in this file, it is — `buildImageReplacePatch` uses it. Reuse the existing import.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web/.worktrees/develop && bun test src/lib/studio/kv/overlayMutations.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/develop
git add src/lib/studio/kv/overlayMutations.ts src/lib/studio/kv/overlayMutations.test.ts
git commit -m "feat(web): add overlaysForTile filter helper"
```

---

### Task 2: Decouple `KvLayersPanel` empty-state / tile label from `tileMode`

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvLayersPanel.tsx`

**Interfaces:**
- No prop changes. Behavior: `emptyState` and `tileLabel` render whenever
  provided, regardless of `tileMode`.

- [ ] **Step 1: Decouple the tile label**

Find (~line 275):

```tsx
                {tileMode && tileLabel && (
                  <p className="font-geist text-textXsMedium font-medium leading-[1.4] text-text-inverse-subtlest">
                    {tileLabel}
                  </p>
                )}
```

Change the guard to drop `tileMode &&`:

```tsx
                {tileLabel && (
                  <p className="font-geist text-textXsMedium font-medium leading-[1.4] text-text-inverse-subtlest">
                    {tileLabel}
                  </p>
                )}
```

- [ ] **Step 2: Decouple the empty-state branches + neutralize copy**

Find (~lines 421–428):

```tsx
      {tileMode && emptyState === "no-tile" ? (
        <p className="m-4 font-geist text-textSm leading-[1.4] text-text-inverse-subtlest">
          Click a tile to view its layers.
        </p>
      ) : tileMode && emptyState === "no-overlays" ? (
        <p className="m-4 font-geist text-textSm leading-[1.4] text-text-inverse-subtlest">
          This tile has no overlays. Add some in Craft, then return here.
        </p>
      ) : sorted.length === 0 ? (
```

Replace with (drop `tileMode &&`; neutralize the no-overlays copy):

```tsx
      {emptyState === "no-tile" ? (
        <p className="m-4 font-geist text-textSm leading-[1.4] text-text-inverse-subtlest">
          Click a tile to view its layers.
        </p>
      ) : emptyState === "no-overlays" ? (
        <p className="m-4 font-geist text-textSm leading-[1.4] text-text-inverse-subtlest">
          This tile has no overlays yet.
        </p>
      ) : sorted.length === 0 ? (
```

- [ ] **Step 3: Type-check**

Run: `cd web/.worktrees/develop && bun run build`
Expected: PASS. Behavior unchanged where callers don't pass `emptyState`/`tileLabel`
(Craft today); Resize (tileMode=true, passes them) still renders them.

- [ ] **Step 4: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/develop
git add src/components/studio/kv-generator/KvLayersPanel.tsx
git commit -m "feat(web): render Layers empty-state/tile label without tileMode gate"
```

---

### Task 3: Wire tile-scoped overlays into the Craft `KvLayersPanel`

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx`

**Interfaces:**
- Consumes: `overlaysForTile` (Task 1); existing `shareBoards` memo
  (`{ id, name, versionIds }[]`), `viewingGenerationId`, `overlays`.

- [ ] **Step 1: Import the helper**

Add `overlaysForTile` to the existing import from `@/lib/studio/kv/overlayMutations`
in `KvGeneratorLayout.tsx` (the file already imports `reorderOverlays` — add to
that list).

- [ ] **Step 2: Derive the tile-scoped panel inputs**

Add these memos where `overlays` is already in scope (after
`const overlays = useKvOverlaysStore((s) => s.overlays);`, ~line 1381). `shareBoards`
(~line 429) is already defined above this point:

```tsx
  // Tile-aware Layers panel (Craft): resolve the selected tile from the same
  // craft board layout `shareBoards` already computes. `shareBoards[i].id` is a
  // board's tip generation id and `.versionIds` its full version chain; an
  // overlay belongs to the tile when its board_generation_id is in that chain.
  const selectedTileBoard = useMemo(() => {
    if (!viewingGenerationId) return null;
    return (
      shareBoards.find(
        (b) =>
          b.id === viewingGenerationId ||
          b.versionIds.includes(viewingGenerationId)
      ) ?? null
    );
  }, [shareBoards, viewingGenerationId]);

  const panelOverlays = useMemo(() => {
    if (!selectedTileBoard) return [];
    return overlaysForTile(overlays, new Set(selectedTileBoard.versionIds));
  }, [overlays, selectedTileBoard]);

  const panelEmptyState: "no-tile" | "no-overlays" | null = !viewingGenerationId
    ? "no-tile"
    : panelOverlays.length === 0
      ? "no-overlays"
      : null;

  const selectedTileLabel = selectedTileBoard?.name;
```

- [ ] **Step 3: Wire the memos into the main Craft `KvLayersPanel` mount**

At the main mount (the one gated by `canvasMode !== "resize"`, ~line 3374), change
`overlays={overlays}` to `overlays={panelOverlays}` and add the two new props:

```tsx
          <KvLayersPanel
            open={layersOpen && !versionHistoryOpen && canvasMode !== "resize"}
            overlays={panelOverlays}
            emptyState={panelEmptyState}
            tileLabel={selectedTileLabel}
            selectedId={selectedOverlayId}
            onSelect={setSelected}
```

Leave `onReorder` unchanged — it calls `reorderOverlays(overlays, …)` on the GLOBAL
`overlays` by id, which is still correct. Do NOT change the Resize/tile mount or the
`overlays={overlays}` passed to `<KvCanvas>` (~line 3158) — only the `<KvLayersPanel>`
mount's `overlays` prop changes.

- [ ] **Step 4: Type-check**

Run: `cd web/.worktrees/develop && bun run build`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/develop
git add src/components/studio/kv-generator/KvGeneratorLayout.tsx
git commit -m "feat(web): scope Craft Layers panel to the selected tile"
```

---

### Task 4: Manual verification (browser)

**Files:** none.

- [ ] **Step 1: Ensure the develop-worktree dev server is running**

The dev server should be up on http://localhost:3000 serving the develop worktree.
If not: `cd web/.worktrees/develop && bun dev`.

- [ ] **Step 2: Exercise the flow (Craft, multi-board)**

1. Hard-reload the KV Generator page.
2. With **no tile selected** → the Layers panel shows "Click a tile to view its
   layers." (and no overlay rows).
3. **Select tile A** (click its board) → the panel lists only A's overlays and the
   title shows A's tile name.
4. **Select tile B** → the panel swaps to B's overlays (or "This tile has no
   overlays yet." if B has none).
5. **Deselect** (click empty canvas) → back to "Click a tile to view its layers."

- [ ] **Step 3: Confirm no console/runtime errors**

Use `read_console_messages` (errors only). Take a screenshot of the panel showing a
tile's scoped overlays as proof.

---

## Self-Review

**Spec coverage:**
- Filter overlays to selected tile → Task 1 (`overlaysForTile`) + Task 3 (`panelOverlays`). ✓
- Empty hint when no tile selected → Task 2 (decouple) + Task 3 (`panelEmptyState="no-tile"`). ✓
- Tile name in title → Task 2 (decouple `tileLabel`) + Task 3 (`selectedTileLabel`). ✓
- Keep presets (no `tileMode`) → Task 2 decouples rendering instead of enabling tileMode. ✓
- Legacy null-bound overlays hidden → Task 1 helper excludes them. ✓
- Craft-only; Resize + Konva untouched → Task 3 changes only the Craft `KvLayersPanel` mount. ✓
- Selected tile = `viewingGenerationId`; version-chain match → Task 3 via `shareBoards`. ✓

**Placeholder scan:** No TBD/TODO; all code is concrete. ✓

**Type consistency:** `overlaysForTile(overlays, Set<string>)` (Task 1) is called with
`new Set(selectedTileBoard.versionIds)` (Task 3). `shareBoards` item shape
`{ id, name, versionIds }` matches the memo at KvGeneratorLayout.tsx:429. `emptyState`
values `"no-tile" | "no-overlays" | null` and `tileLabel?: string` match the panel's
existing prop types. ✓
