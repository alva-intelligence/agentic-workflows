# KV Resize — Editable Master Row Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user edit overlays on the Resize surface's master (original) row, so a fix made once cascades to every tile that has not been individually customised.

**Architecture:** The master row's overlays *are* the Craft KV's overlays, and the Yjs doc — not the Zustand store — is authoritative. So the master row renders the existing `KvTileOverlayEditor` and its array-shaped `onChange` is translated by a new pure diff module into per-id doc ops (`docAddOverlay` / `docUpdateOverlay` / `docRemoveOverlay`) issued from `KvGeneratorLayout`, which already owns every doc op. The cascade to inheriting tiles needs no new code: `resolveTileOverlays` re-projects any tile whose `row.overlays` is `null` on every render.

**Tech Stack:** Next.js 16, React 19, TypeScript, Konva / react-konva, Yjs, Zustand, TanStack Query, bun (test runner).

**Spec:** `docs/superpowers/specs/2026-08-04-kv-resize-master-editable-design.md`

## Global Constraints

- Tests run with `bun test` from `web/`, NOT `bunx vitest`. Test files are colocated as `*.test.ts` / `*.test.tsx`.
- Component tests under `src/components/studio/kv-generator/` currently fail on a pre-existing `@testing-library`/bun issue (`screen` requires a global document). Do NOT add component tests; put logic in pure modules and unit-test those. Baseline before this work: **398 pass / 121 fail** in that directory — do not increase the failure count.
- `bunx tsc --noEmit -p tsconfig.json` reports many pre-existing errors across unrelated files. Only assert that **files touched by this plan** contribute no new errors.
- Lint: this repo's prettier config disagrees with much committed formatting. Compare each touched file against its baseline (`git show HEAD:<path>` into a temp file, lint both) and do not increase its error count. Never bulk-reformat a file you are editing.
- `docUpdateOverlay` accepts a patch over EXACTLY these fields: `x`, `y`, `width`, `height`, `rotation`, `z`, `board_generation_id`, `payload`. Never emit `id`, `type`, or `updated_at` in a patch.
- Never `git add -A` in the workspace root repo — it sweeps `.pids/`, `.codex/` and the service directories in as gitlinks. Stage explicit paths.
- All web work happens in `web/`, on the current branch. Commit per task.

---

## File Structure

| File | Responsibility |
|---|---|
| `web/src/lib/studio/kv/overlayDiff.ts` | **New.** Pure array→per-id diff. The only new logic. |
| `web/src/lib/studio/kv/overlayDiff.test.ts` | **New.** Unit tests for the above. |
| `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx` | Owns doc ops. Gains `handleCommitProjectOverlays`, passes it down, and gains the undo-domain marker. |
| `web/src/components/studio/kv-generator/KvResizeCanvas.tsx` | Gains `onCommitProjectOverlays` prop, the `MASTER_ROW_ID` sentinel, Push-to-all-tiles, and sets the undo-domain marker on tile commits. |
| `web/src/components/studio/kv-generator/KvResizeOriginalRow.tsx` | Renders the editor instead of the read-only stage when a commit handler is supplied. |
| `web/src/components/studio/kv-generator/KvResizeResultRow.tsx` | Divergence label on the existing Reset button. |
| `web/src/lib/analytics/kv-generator-events.ts` | New typed PostHog event wrappers. |

---

### Task 1: `overlayDiff` — array → per-id doc ops

**Files:**
- Create: `web/src/lib/studio/kv/overlayDiff.ts`
- Test: `web/src/lib/studio/kv/overlayDiff.test.ts`

**Interfaces:**
- Consumes: `StudioOverlay` from `@/types/studio`.
- Produces:
  ```ts
  export type OverlayPatch = Partial<Pick<StudioOverlay,
    "x" | "y" | "width" | "height" | "rotation" | "z" | "board_generation_id" | "payload">>;
  export type OverlayDiff = {
    added: StudioOverlay[];
    updated: { id: string; patch: OverlayPatch }[];
    removed: string[];
  };
  export function diffOverlayArrays(prev: StudioOverlay[], next: StudioOverlay[]): OverlayDiff;
  ```

- [ ] **Step 1: Write the failing tests**

Create `web/src/lib/studio/kv/overlayDiff.test.ts`:

```ts
import { describe, it, expect } from "bun:test";
import { diffOverlayArrays } from "./overlayDiff";
import type { StudioOverlay } from "@/types/studio";

function ov(id: string, extra: Partial<StudioOverlay> = {}): StudioOverlay {
  return {
    id,
    type: "image",
    x: 0.1,
    y: 0.2,
    width: 0.3,
    height: 0.4,
    rotation: 0,
    z: 0,
    payload: { type: "image", asset_url: "u", mime_type: "image/png" },
    updated_at: "2026-01-01T00:00:00Z",
    ...extra,
  } as StudioOverlay;
}

describe("diffOverlayArrays", () => {
  it("returns three empty lists for identical arrays", () => {
    const a = [ov("a"), ov("b")];
    const d = diffOverlayArrays(a, a);
    expect(d.added).toEqual([]);
    expect(d.updated).toEqual([]);
    expect(d.removed).toEqual([]);
  });

  it("detects an added overlay by id", () => {
    const d = diffOverlayArrays([ov("a")], [ov("a"), ov("b")]);
    expect(d.added.map((o) => o.id)).toEqual(["b"]);
    expect(d.updated).toEqual([]);
    expect(d.removed).toEqual([]);
  });

  it("detects a removed overlay by id", () => {
    const d = diffOverlayArrays([ov("a"), ov("b")], [ov("a")]);
    expect(d.removed).toEqual(["b"]);
    expect(d.added).toEqual([]);
    expect(d.updated).toEqual([]);
  });

  it("emits only the changed fields for a move", () => {
    const d = diffOverlayArrays([ov("a")], [ov("a", { x: 0.5, y: 0.6 })]);
    expect(d.updated).toHaveLength(1);
    expect(d.updated[0].id).toBe("a");
    expect(d.updated[0].patch).toEqual({ x: 0.5, y: 0.6 });
  });

  it("ignores an updated_at-only difference", () => {
    const d = diffOverlayArrays(
      [ov("a")],
      [ov("a", { updated_at: "2026-09-09T00:00:00Z" })]
    );
    expect(d.updated).toEqual([]);
  });

  it("never emits id, type or updated_at in a patch", () => {
    const d = diffOverlayArrays(
      [ov("a")],
      [ov("a", { x: 0.9, updated_at: "2026-09-09T00:00:00Z" })]
    );
    const keys = Object.keys(d.updated[0].patch);
    expect(keys).not.toContain("id");
    expect(keys).not.toContain("type");
    expect(keys).not.toContain("updated_at");
  });

  it("treats a payload change as a whole-payload patch", () => {
    const next = ov("a", {
      payload: { type: "image", asset_url: "v", mime_type: "image/png" },
    } as Partial<StudioOverlay>);
    const d = diffOverlayArrays([ov("a")], [next]);
    expect(d.updated[0].patch.payload).toEqual(next.payload);
    expect(Object.keys(d.updated[0].patch)).toEqual(["payload"]);
  });

  it("produces no ops when only array order changed", () => {
    const d = diffOverlayArrays([ov("a"), ov("b")], [ov("b"), ov("a")]);
    expect(d.added).toEqual([]);
    expect(d.updated).toEqual([]);
    expect(d.removed).toEqual([]);
  });

  it("handles add, update and remove in one diff", () => {
    const d = diffOverlayArrays(
      [ov("a"), ov("b")],
      [ov("a", { rotation: 45 }), ov("c")]
    );
    expect(d.added.map((o) => o.id)).toEqual(["c"]);
    expect(d.updated).toEqual([{ id: "a", patch: { rotation: 45 } }]);
    expect(d.removed).toEqual(["b"]);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd web && bun test src/lib/studio/kv/overlayDiff.test.ts
```

Expected: FAIL — `Cannot find module './overlayDiff'`.

- [ ] **Step 3: Write the implementation**

Create `web/src/lib/studio/kv/overlayDiff.ts`:

```ts
import type { StudioOverlay } from "@/types/studio";

/**
 * Translate a whole-array overlay edit into per-id doc operations.
 *
 * `KvTileOverlayEditor.onChange` hands back the full overlay array, but the
 * Yjs doc API is per-id (`docAddOverlay` / `docUpdateOverlay` /
 * `docRemoveOverlay`). This module is the adapter, kept pure so it can be
 * unit-tested without a canvas or a doc.
 */

/** Exactly the fields `docUpdateOverlay` accepts. Nothing else may be sent. */
export type OverlayPatch = Partial<
  Pick<
    StudioOverlay,
    | "x"
    | "y"
    | "width"
    | "height"
    | "rotation"
    | "z"
    | "board_generation_id"
    | "payload"
  >
>;

export type OverlayDiff = {
  added: StudioOverlay[];
  updated: { id: string; patch: OverlayPatch }[];
  removed: string[];
};

/** Geometry fields compared by value. `payload` is handled separately. */
const SCALAR_FIELDS = [
  "x",
  "y",
  "width",
  "height",
  "rotation",
  "z",
  "board_generation_id",
] as const;

export function diffOverlayArrays(
  prev: StudioOverlay[],
  next: StudioOverlay[]
): OverlayDiff {
  const prevById = new Map(prev.map((o) => [o.id, o]));
  const nextById = new Map(next.map((o) => [o.id, o]));

  const added = next.filter((o) => !prevById.has(o.id));
  const removed = prev.filter((o) => !nextById.has(o.id)).map((o) => o.id);

  const updated: { id: string; patch: OverlayPatch }[] = [];
  for (const after of next) {
    const before = prevById.get(after.id);
    if (!before) continue;
    const patch: OverlayPatch = {};
    for (const f of SCALAR_FIELDS) {
      if (before[f] !== after[f]) {
        // Index through a cast: the union of field types is wider than any
        // single key, which TS can't narrow across a generic loop.
        (patch as Record<string, unknown>)[f] = after[f];
      }
    }
    // Payload is a small tagged union and `docUpdateOverlay` replaces it
    // wholesale, so compare structurally and send all-or-nothing.
    if (JSON.stringify(before.payload) !== JSON.stringify(after.payload)) {
      patch.payload = after.payload;
    }
    // `updated_at` is deliberately never compared — it moves on every commit
    // and would make every no-op gesture look like a change.
    if (Object.keys(patch).length > 0) updated.push({ id: after.id, patch });
  }

  return { added, updated, removed };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd web && bun test src/lib/studio/kv/overlayDiff.test.ts
```

Expected: PASS, 9 tests.

- [ ] **Step 5: Verify types and lint**

```bash
cd web && bunx tsc --noEmit -p tsconfig.json 2>&1 | grep overlayDiff
cd web && bunx eslint src/lib/studio/kv/overlayDiff.ts src/lib/studio/kv/overlayDiff.test.ts
```

Expected: no output from either (new files must be clean). If prettier complains, run `bunx prettier --write` on the two new files only.

- [ ] **Step 6: Commit**

```bash
cd web && git add src/lib/studio/kv/overlayDiff.ts src/lib/studio/kv/overlayDiff.test.ts
git commit -m "feat(web): add overlay array-to-doc-op diff for the Resize master row"
```

---

### Task 2: Layout commit handler — array edits become doc ops

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx`
- Modify: `web/src/components/studio/kv-generator/KvResizeCanvas.tsx`

**Interfaces:**
- Consumes: `diffOverlayArrays`, `OverlayDiff` from Task 1.
- Produces: a new optional prop on `KvResizeCanvas`:
  ```ts
  onCommitProjectOverlays?: (next: StudioOverlay[]) => void;
  ```
  Absent ⇒ the master row stays read-only (Task 3 depends on this).

- [ ] **Step 1: Add the prop to `KvResizeCanvas`**

In `KvResizeCanvas.tsx`, in the `Props` type, next to the other optional callbacks:

```ts
  /** Commit an edit made on the MASTER row. The array is diffed against the
   *  current project overlays by the layout and issued as per-id doc ops.
   *  Omitted (e.g. no collab doc) ⇒ the master row stays read-only. */
  onCommitProjectOverlays?: (next: StudioOverlay[]) => void;
```

Destructure it alongside the other props in the component signature.

- [ ] **Step 2: Implement the handler in `KvGeneratorLayout`**

Add the import near the other `@/lib/studio/kv` imports:

```ts
import { diffOverlayArrays } from "@/lib/studio/kv/overlayDiff";
```

Define the handler near `replaceImageOverlay` (which already shows the
`kvDoc ? docUpdateOverlay : update` fallback pattern):

```ts
  // Master-row edits on the Resize surface. The editor hands back a whole
  // array; the doc API is per-id, so diff and issue ops. Ordered
  // remove → update → add so an id reused within one gesture can't collide.
  const handleCommitProjectOverlays = useCallback(
    (next: StudioOverlay[]) => {
      if (!kvDoc) return;
      const prev = useKvOverlaysStore.getState().overlays;
      const diff = diffOverlayArrays(prev, next);
      diff.removed.forEach((id) => docRemoveOverlay(kvDoc, id));
      diff.updated.forEach(({ id, patch }) =>
        docUpdateOverlay(kvDoc, id, patch)
      );
      diff.added.forEach((o) =>
        docAddOverlay(kvDoc, {
          id: o.id,
          x: o.x,
          y: o.y,
          width: o.width,
          height: o.height,
          rotation: o.rotation,
          z: o.z,
          board_generation_id: o.board_generation_id ?? null,
          payload: o.payload,
        })
      );
    },
    [kvDoc]
  );
```

**Important:** read `prev` from `useKvOverlaysStore.getState()` inside the
callback, not from a render-scoped variable — a stale `prev` would produce
patches computed against pre-edit state, which is exactly the class of bug
that caused the group-drag regression on this surface.

- [ ] **Step 3: Pass it to `KvResizeCanvas`**

At the `<KvResizeCanvas … />` call site, add:

```tsx
              onCommitProjectOverlays={
                kvDoc ? handleCommitProjectOverlays : undefined
              }
```

- [ ] **Step 4: Verify types and the existing suite**

```bash
cd web && bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -E 'KvGeneratorLayout|KvResizeCanvas'
cd web && bun test src/lib/studio/
```

Expected: no new type errors on those two files; 244+ pass / 0 fail.

- [ ] **Step 5: Verify lint against baseline**

```bash
cd web
for f in src/components/studio/kv-generator/KvGeneratorLayout.tsx src/components/studio/kv-generator/KvResizeCanvas.tsx; do
  cur=$(bunx eslint "$f" 2>&1 | grep -cE ' error | warning ')
  git show HEAD:"$f" > /tmp/base.tsx; base=$(bunx eslint /tmp/base.tsx 2>&1 | grep -cE ' error | warning ')
  echo "$f now=$cur head=$base"
done
```

Expected: `now` ≤ `head` for both.

- [ ] **Step 6: Commit**

```bash
cd web && git add src/components/studio/kv-generator/KvGeneratorLayout.tsx src/components/studio/kv-generator/KvResizeCanvas.tsx
git commit -m "feat(web): route Resize master-row edits into the Yjs doc"
```

---

### Task 3: Make the master row editable

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvResizeOriginalRow.tsx`
- Modify: `web/src/components/studio/kv-generator/KvResizeCanvas.tsx`

**Interfaces:**
- Consumes: `onCommitProjectOverlays` from Task 2.
- Produces: `export const MASTER_ROW_ID = "__master__";` exported from `KvResizeCanvas.tsx`, used by Task 4 and Task 6.

- [ ] **Step 1: Add editing props to `KvResizeOriginalRow`**

In its `Props` type:

```ts
  /** Commit an overlay edit made on this row. Omitted ⇒ read-only (the
   *  historical behaviour), and the row renders the static stage. */
  onCommitOverlays?: (next: StudioOverlay[]) => void;
  /** Shared Resize selection — same semantics as the result rows. */
  selectedId?: string | null;
  selectedIds?: string[];
  onSelect?: (id: string | null) => void;
  onSelectMany?: (ids: string[]) => void;
  /** True when this row owns the current selection. */
  isActive?: boolean;
  onActivate?: () => void;
  tool?: CanvasTool;
```

Add the matching entries to the destructured parameter list.

- [ ] **Step 2: Render the editor when editable**

Replace the `<KvResizeTileStage … />` usage with a conditional. Keep the
static stage for the read-only path so nothing regresses when there is no doc:

```tsx
        {onCommitOverlays ? (
          <KvTileOverlayEditor
            overlays={projectOverlays}
            selectedId={selectedId ?? null}
            selectedIds={selectedIds}
            onChange={onCommitOverlays}
            onSelect={(id) => onSelect?.(id)}
            onSelectMany={(ids) => onSelectMany?.(ids)}
            baseImageUrl={imageUrl}
            targetWidth={width}
            targetHeight={height}
            displayWidth={displayWidth}
            isActive={isActive ?? false}
            tool={tool ?? "cursor"}
          />
        ) : (
          <KvResizeTileStage
            /* …existing props unchanged… */
          />
        )}
```

Add the import: `import { KvTileOverlayEditor } from "./KvTileOverlayEditor";`

- [ ] **Step 3: Wire the row up in `KvResizeCanvas`**

Above the component, export the sentinel:

```ts
/** `activeTileId` indexes into `exports`; the master row is not a member, so
 *  it identifies itself with this sentinel. */
export const MASTER_ROW_ID = "__master__";
```

At the `<KvResizeOriginalRow … />` call site add:

```tsx
            onCommitOverlays={onCommitProjectOverlays}
            selectedId={selectedId}
            selectedIds={selectedIds}
            onSelect={setSelectedId}
            onSelectMany={setSelectedIds}
            isActive={activeTileId === MASTER_ROW_ID}
            onActivate={() => {
              setActiveTileId(MASTER_ROW_ID);
              onRequestLayersOpen();
            }}
            tool={tool}
```

- [ ] **Step 4: Verify**

```bash
cd web && bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -E 'KvResizeOriginalRow|KvResizeCanvas'
cd web && bun test src/components/studio/kv-generator/ 2>&1 | tail -4
```

Expected: no new type errors; failure count still **121** (the pre-existing RTL baseline), pass count ≥ 398.

- [ ] **Step 5: Commit**

```bash
cd web && git add src/components/studio/kv-generator/KvResizeOriginalRow.tsx src/components/studio/kv-generator/KvResizeCanvas.tsx
git commit -m "feat(web): render the editable overlay editor on the Resize master row"
```

---

### Task 4: Bind the Layers and Transform panels to the master

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvResizeCanvas.tsx`

**Interfaces:**
- Consumes: `MASTER_ROW_ID` from Task 3.
- Produces: no new exports. `activeRowOverlays` now resolves to `projectOverlays` when the master is active.

- [ ] **Step 1: Resolve the active row's overlays through the sentinel**

`activeRow` currently comes from `exports.find(...)`, which never matches the
sentinel. Introduce a master-aware derivation:

```ts
  const isMasterActive = activeTileId === MASTER_ROW_ID;
  const activeRowOverlays = isMasterActive
    ? projectOverlays
    : activeRow
      ? (activeRow.overlays ?? projectOverlays)
      : [];
```

Leave `activeRow` itself as-is; it stays `null` for the master, which is
correct — the master has no `KvResizeExport` row.

- [ ] **Step 2: Route the layers panel's mutations for the master**

The panel's `onRemove` / `onReorder` / hidden / locked handlers currently
early-return on `if (!activeRow) return;`. Each must fall through to the
project-overlay commit when the master is active. For `onRemove`:

```ts
          onRemove={(id) => {
            if (isMasterActive) {
              onCommitProjectOverlays?.(
                removeOverlay(activeRowOverlays, id)
              );
              if (selectedId === id) setSelectedId(null);
              return;
            }
            if (!activeRow) return;
            /* …existing tile path unchanged… */
          }}
```

Apply the same `isMasterActive` branch to `onReorder`, the hidden toggle and
the locked toggle, each calling `onCommitProjectOverlays?.(next)` with the
array the existing shared overlay command already produces.

- [ ] **Step 3: Keep the empty state honest**

```ts
  const layersEmptyState: "no-tile" | "no-overlays" | null =
    !activeRow && !isMasterActive
      ? "no-tile"
      : activeRowOverlays.length === 0
        ? "no-overlays"
        : null;
```

- [ ] **Step 4: Route the Transform panel's commits**

Its `onUpdateOverlay` currently early-returns on `if (!activeRow) return;`. Add:

```ts
              onUpdateOverlay={(id, patch) => {
                if (isMasterActive) {
                  onCommitProjectOverlays?.(
                    activeRowOverlays.map((o) =>
                      o.id === id ? { ...o, ...patch } : o
                    )
                  );
                  return;
                }
                if (!activeRow) return;
                /* …existing tile path unchanged… */
              }}
```

- [ ] **Step 5: Verify**

```bash
cd web && bunx tsc --noEmit -p tsconfig.json 2>&1 | grep KvResizeCanvas
cd web && bun test src/components/studio/kv-generator/ 2>&1 | tail -4
```

Expected: no new type errors; 121 failures, unchanged.

- [ ] **Step 6: Commit**

```bash
cd web && git add src/components/studio/kv-generator/KvResizeCanvas.tsx
git commit -m "feat(web): bind the Layers and Transform panels to the Resize master row"
```

---

### Task 5: Undo routing by last-edited domain

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx`
- Modify: `web/src/components/studio/kv-generator/KvResizeCanvas.tsx`

**Interfaces:**
- Consumes: `handleCommitProjectOverlays` (Task 2).
- Produces: a new optional prop on `KvResizeCanvas`:
  ```ts
  onEditDomainChange?: (domain: "master" | "tile") => void;
  ```

**Why:** Cmd+Z on the Resize tab dispatches to `resizeUndoApiRef` (per-tile REST history). A master edit lands on the doc timeline, so without this the keystroke would silently revert the user's last *tile* action instead. Routing everything to the doc is not an option — tile snapshots are REST state the doc undo manager cannot revert.

- [ ] **Step 1: Add the domain ref and route on it**

In `KvGeneratorLayout.tsx`, beside `resizeUndoApiRef`:

```ts
  // Which storage backend the last Resize edit touched. Cmd+Z on this tab has
  // to pick between the doc timeline (master edits) and the per-tile REST
  // history (tile edits) — they cannot share one timeline.
  const resizeEditDomainRef = useRef<"master" | "tile">("tile");
  const handleResizeEditDomainChange = useCallback(
    (domain: "master" | "tile") => {
      resizeEditDomainRef.current = domain;
    },
    []
  );
```

Change the dispatch (currently around line 1784):

```ts
      const api =
        canvasModeRef.current === "resize"
          ? resizeEditDomainRef.current === "master"
            ? docUndoApiRef.current
            : resizeUndoApiRef.current
          : docUndoApiRef.current;
```

- [ ] **Step 2: Mark the domain at both commit sites**

In `handleCommitProjectOverlays` (Task 2), as the first statement after the
`if (!kvDoc) return;` guard:

```ts
      resizeEditDomainRef.current = "master";
```

Pass the setter down at the `<KvResizeCanvas … />` call site:

```tsx
              onEditDomainChange={handleResizeEditDomainChange}
```

- [ ] **Step 3: Mark tile commits**

In `KvResizeCanvas.tsx`, add the prop to `Props`:

```ts
  /** Reports which storage backend the last edit touched, so the layout can
   *  route Cmd+Z to the doc timeline or the per-tile history. */
  onEditDomainChange?: (domain: "master" | "tile") => void;
```

and as the first statement inside `commitTileOverlays`:

```ts
    onEditDomainChange?.("tile");
```

**Set the marker where the edit is COMMITTED, never inferred from selection** — a gesture and the selection can disagree (a drag that ends after the selection changed), and inferring would route the wrong way.

- [ ] **Step 4: Verify**

```bash
cd web && bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -E 'KvGeneratorLayout|KvResizeCanvas'
cd web && bun test src/lib/studio/
```

Expected: no new type errors; all pass.

- [ ] **Step 5: Commit**

```bash
cd web && git add src/components/studio/kv-generator/KvGeneratorLayout.tsx src/components/studio/kv-generator/KvResizeCanvas.tsx
git commit -m "fix(web): route Resize Cmd+Z by whichever domain was last edited"
```

---

### Task 6: Push to all tiles + divergence marker

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvResizeCanvas.tsx`
- Modify: `web/src/components/studio/kv-generator/KvResizeResultRow.tsx`

**Interfaces:**
- Consumes: `MASTER_ROW_ID` (Task 3), `resetTileOverlays` (existing in `KvResizeCanvas`).
- Produces: no new exports.

- [ ] **Step 1: Add the action in `KvResizeCanvas`**

```ts
  // Re-inherit every customised tile. Deliberately NOT a verbatim coordinate
  // copy: clearing the snapshot sends each tile back through
  // resolveTileOverlays, so a 1080×1920 story gets a layout suited to its
  // shape instead of the master's landscape coordinates.
  const tilesWithSnapshot = exports.filter((r) => r.overlays !== null);
  const pushMasterToAllTiles = useCallback(() => {
    tilesWithSnapshot.forEach((row) => {
      history.record({ exportId: row.id, overlays: row.overlays });
      updateOverlays.mutate({ exportId: row.id, overlays: null });
    });
    setSelectedIds([]);
  }, [tilesWithSnapshot, history, updateOverlays]);
```

- [ ] **Step 2: Render the button with a confirm**

There is **no** confirm dialog in `KvResizeCanvas.tsx` today — model it on
`web/src/components/studio/kv-generator/DeleteFileDialog.tsx`, which is this
directory's destructive-confirm precedent (read it before writing this step).
Hold the open state locally:

```ts
const [pushConfirmOpen, setPushConfirmOpen] = useState(false);
```

Render the button on the master row header, disabled when
`tilesWithSnapshot.length === 0`, opening the dialog rather than acting
directly. Copy:

> **Push master to all tiles?**
> `N` tile(s) have their own adjustments. They'll be discarded and re-derived from the master. This can't be undone.

Confirm label: `Push to all tiles`. Cancel label: `Cancel`.

**This one confirms** — clearing snapshots discards per-tile work that undo
does not recover. Deleting on the master does NOT confirm, because that is a
doc op and Cmd+Z restores it (see Task 5).

- [ ] **Step 3: Label the divergence in `KvResizeResultRow`**

The Reset button already renders only when `hasSnapshot`. Change its
`aria-label` and `title` from `"Reset overlays to project default"` to:

```
"Not following master — reset to follow"
```

so the mixed population of following/diverged tiles is visible rather than
silent.

- [ ] **Step 4: Verify**

```bash
cd web && bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -E 'KvResizeCanvas|KvResizeResultRow'
cd web && bun test src/components/studio/kv-generator/ 2>&1 | tail -4
```

Expected: no new type errors; 121 failures, unchanged.

- [ ] **Step 5: Commit**

```bash
cd web && git add src/components/studio/kv-generator/KvResizeCanvas.tsx src/components/studio/kv-generator/KvResizeResultRow.tsx
git commit -m "feat(web): push master to all tiles, and mark diverged tiles"
```

---

### Task 7: PostHog events

> Not in the spec — required by the project convention that every user-facing
> web feature ships with PostHog events.

**Files:**
- Modify: `web/src/lib/analytics/kv-generator-events.ts`
- Modify: `web/src/components/studio/kv-generator/KvResizeCanvas.tsx`

**Interfaces:**
- Consumes: the existing typed-wrapper pattern in `kv-generator-events.ts` (see `trackKvOverlayTransformed` for the house style).
- Produces:
  ```ts
  export interface KvMasterOverlayEditedProps {
    op: "add" | "update" | "remove";
    count: number;
  }
  export const trackKvMasterOverlayEdited:
    (p: KvMasterOverlayEditedProps) => void;

  export interface KvMasterPushedToTilesProps { tile_count: number }
  export const trackKvMasterPushedToTiles:
    (p: KvMasterPushedToTilesProps) => void;
  ```

- [ ] **Step 1: Read the conventions**

Invoke the `frndos-analytics-events` skill and follow it — snake_case names,
typed wrappers, automatic base context, fire-timing guards. Do not hand-roll
`posthog.capture` calls.

- [ ] **Step 2: Add the wrappers**

House style in this file is an exported `Props` interface plus a `const` arrow
delegating to `safeCapture`, with a **dotted** event name (`kv_generator.*`) —
see `trackKvOverlayTransformed` at line 543. Match it exactly:

```ts
/** An overlay edit committed on the Resize MASTER row. Unlike a tile edit this
 *  mutates the Craft KV itself and cascades to every inheriting tile, so it is
 *  tracked separately. `count` is the number of overlays in that diff category
 *  — a group drag of three reports one event with count 3. */
export interface KvMasterOverlayEditedProps {
  op: "add" | "update" | "remove";
  count: number;
}

export const trackKvMasterOverlayEdited = (p: KvMasterOverlayEditedProps) =>
  safeCapture("kv_generator.master_overlay_edited", p);

/** Every customised tile discarded its snapshot and re-derived from the
 *  master. Destructive and explicit — worth knowing how often it is reached
 *  for. */
export interface KvMasterPushedToTilesProps {
  tile_count: number;
}

export const trackKvMasterPushedToTiles = (p: KvMasterPushedToTilesProps) =>
  safeCapture("kv_generator.master_pushed_to_tiles", p);
```

- [ ] **Step 3: Fire them**

- `trackKvMasterOverlayEdited` — inside `handleCommitProjectOverlays`, after
  the doc ops succeed, once per NON-EMPTY diff category:

  ```ts
      if (diff.removed.length)
        trackKvMasterOverlayEdited({ op: "remove", count: diff.removed.length });
      if (diff.updated.length)
        trackKvMasterOverlayEdited({ op: "update", count: diff.updated.length });
      if (diff.added.length)
        trackKvMasterOverlayEdited({ op: "add", count: diff.added.length });
  ```

  Guarding on length keeps a no-op gesture from emitting three empty events.
- `trackKvMasterPushedToTiles` — in `pushMasterToAllTiles`, with
  `tile_count: tilesWithSnapshot.length`, after the confirm is accepted.

- [ ] **Step 4: Verify**

```bash
cd web && bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -E 'kv-generator-events|KvResizeCanvas|KvGeneratorLayout'
cd web && bun test src/lib/
```

Expected: no new type errors; all pass.

- [ ] **Step 5: Commit**

```bash
cd web && git add src/lib/analytics/kv-generator-events.ts src/components/studio/kv-generator/KvResizeCanvas.tsx src/components/studio/kv-generator/KvGeneratorLayout.tsx
git commit -m "feat(web): track master-row overlay edits and push-to-all-tiles"
```

---

## Manual Verification

Unit tests cover the diff. Everything else is Konva event ordering, Yjs
propagation and react-konva reconciliation, none of which is reachable from
`bun test` in this repo. Run these by hand on a KV with at least three resize
tiles:

- [ ] Move an overlay on the master → every tile **without** its own edits follows.
- [ ] Hand-edit one tile, then move the master → that tile does **not** follow, and its Reset button reads "Not following master".
- [ ] Cmd+Z right after a master edit → undoes the **master** edit, not the previous tile edit.
- [ ] Edit a tile, then Cmd+Z → undoes the **tile** edit, not the master.
- [ ] Open the Craft tab → the overlay moved there too.
- [ ] Delete an overlay on the master → it disappears from Craft and every inheriting tile; Cmd+Z restores all of them.
- [ ] Push to all tiles → confirm dialog states the tile count; on accept every tile re-derives (portrait tiles get a portrait-appropriate layout, not the master's landscape coordinates).
- [ ] With a second browser session in the same KV, move an overlay on the master → it moves live in the other session.
- [ ] Reload → every change persisted.

## Out of Scope

- A Resize-local override layer for the master.
- Reconciling the two authoring homes (master vs Craft).
- Propagating master edits into snapshotted tiles other than via Push to all tiles.
- Marquee selection.
