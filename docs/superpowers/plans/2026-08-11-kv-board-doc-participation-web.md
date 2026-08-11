# KV Board-Doc Participation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a surface state whether it owns a board in the Yjs doc and who owns its position, so the canvas stops inferring both from context.

**Architecture:** Two fields on `KvSurface` (`docBoardId`, `layout`) plus two pure predicates that read them. The canvas gates `ensureBoardMap` on the first; the Fabric binding gates its board-position write on the second. The rules live in `kvSurface.ts` as pure functions because `ensureBoardMap` is private to a 4,000-line component and cannot be tested where it sits.

**Tech Stack:** TypeScript, React, Fabric.js v7, Yjs, `bun test`.

**Spec:** `docs/superpowers/specs/2026-08-11-kv-board-doc-participation-design.md`

**Depends on:** [frnd-web#425](https://github.com/alva-intelligence/frnd-web/pull/425) — `kvSurface.ts` and `surfaceFromBoard()` come from it. Base this work on that branch, or on `develop` once it merges.

## This plan is inert in production, on purpose

Every surface that exists today is a Craft board: `docBoardId` = its generation id, `layout` = `"doc"`. Nothing yet produces a surface with `docBoardId: null` or `layout: "view"` — the Resize view that will is step 3. So the gates added here change no behavior; the tests are their only consumer until then.

That is what a precondition looks like, and it is the point: the rules land and are proven *before* the surface that would violate them exists. Do not add a Resize producer here to "exercise" them.

## Global Constraints

- Tests run with `bun test` from `web/`. Do **not** use `bunx vitest`.
- Prettier runs through eslint with `trailingComma: "es5"` — a trailing comma after the last function parameter or call argument is an error. Run `bunx eslint` on every file you touch and clear only NEW errors; `KvFabricCanvas.tsx` carries many pre-existing ones, so compare counts before and after.
- The `web/` suite has a large pre-existing failure count (React Testing Library's `screen` is broken under bun) and `bunx tsc --noEmit` is not clean at baseline. **Record the baseline before you start.** The bar is "no new failures", not green.
- `KvFabricCanvas.tsx` cannot be component-tested — Fabric needs a real 2D canvas context and jsdom has none. Its verification is the pure tests, `bunx tsc --noEmit`, and `bun run build`.
- Do not change `StudioOverlay`, `KvGeneration`, or `KvCanvasState` in `web/src/types/studio.ts`.
- Do not touch `KvKonvaCanvas.tsx`, the Resize surfaces, or the Motion editor.
- Comment style in this area is long comments explaining WHY a rule exists. Keep it.

---

### Task 1: Declare participation on the surface

**Files:**
- Modify: `web/src/components/studio/kv-generator/kvSurface.ts`
- Test: `web/src/components/studio/kv-generator/kvSurface.test.ts`

**Interfaces:**
- Consumes: `KvSurface`, `surfaceFromBoard(board: KvBoard): KvSurface` (existing)
- Produces: `KvSurface` gains `docBoardId: string | null` and `layout: "doc" | "view"`

- [ ] **Step 1: Write the failing test**

Append to `kvSurface.test.ts`. The existing `board()` fixture helper in that file builds a `KvBoard`; reuse it rather than writing a new one.

```ts
describe("surfaceFromBoard — doc participation", () => {
  it("owns a doc board keyed by the board id", () => {
    expect(surfaceFromBoard(board({ id: "b7" })).docBoardId).toBe("b7");
  });

  it("lets the doc own a craft board's position", () => {
    // Dragging a craft board persists its centre through the Yjs binding.
    expect(surfaceFromBoard(board({})).layout).toBe("doc");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd web && bun test src/components/studio/kv-generator/kvSurface.test.ts
```

Expected: FAIL — `docBoardId` and `layout` do not exist on the returned object.

- [ ] **Step 3: Add the fields to the type**

In `kvSurface.ts`, inside `KvSurface`, after the `id` field:

```ts
  /** The board key this surface owns in the Yjs doc, or null when it owns
   *  none. A Craft board owns one (its generation id). A Resize export tile
   *  owns none — it is a per-platform derivative, not an artboard, and minting
   *  a board map for it would persist a phantom artboard into the Craft file's
   *  `canvas_state`. Where this surface's OVERLAY edits go is derived from this
   *  field, not declared separately — see `overlaySinkFor`. */
  docBoardId: string | null;
  /** Who decides where this surface sits. `doc` — the Yjs doc owns it, so a
   *  drag persists (Craft). `view` — the view computes it, so nothing is
   *  written back (Resize lays its boards out as a fixed column; writing that
   *  layout to the doc would overwrite Craft's artboard centres). */
  layout: "doc" | "view";
```

- [ ] **Step 4: Set them in the adapter**

In `surfaceFromBoard`, add to the returned object:

```ts
    docBoardId: board.id,
    layout: "doc",
```

Both are unconditional: this adapter only ever produces Craft boards. Resize's producer arrives in step 3 of the project and supplies its own values.

- [ ] **Step 5: Run test to verify it passes**

```bash
cd web && bun test src/components/studio/kv-generator/kvSurface.test.ts
```

Expected: PASS, all previous tests plus the 2 new ones.

- [ ] **Step 6: Lint, type-check, commit**

```bash
cd web && bunx eslint src/components/studio/kv-generator/kvSurface.ts src/components/studio/kv-generator/kvSurface.test.ts && bunx tsc --noEmit
git add web/src/components/studio/kv-generator/kvSurface.ts web/src/components/studio/kv-generator/kvSurface.test.ts
git commit -m "feat(web): let a KV surface state its doc participation"
```

---

### Task 2: The two rules, as pure functions

**Files:**
- Modify: `web/src/components/studio/kv-generator/kvSurface.ts`
- Test: `web/src/components/studio/kv-generator/kvSurface.test.ts`

**Interfaces:**
- Consumes: `KvSurface` with `docBoardId` / `layout` from Task 1
- Produces:
  - `shouldAttachBoardMap(surface: Pick<KvSurface, "docBoardId">): boolean`
  - `boardMapKeyFor(surface: Pick<KvSurface, "docBoardId">): string | null`
  - `overlaySinkFor(surface: Pick<KvSurface, "docBoardId">): "doc" | "rest"`
  - `canPersistBoardPosition(surface: Pick<KvSurface, "layout">): boolean`

- [ ] **Step 1: Write the failing test**

Append to `kvSurface.test.ts`:

```ts
import {
  boardMapKeyFor,
  canPersistBoardPosition,
  overlaySinkFor,
  shouldAttachBoardMap,
} from "./kvSurface";

describe("participation rules", () => {
  const craft = { docBoardId: "b1", layout: "doc" as const };
  const tile = { docBoardId: null, layout: "view" as const };
  const masterRow = { docBoardId: "b1", layout: "view" as const };

  it("attaches a board map only when the surface owns one", () => {
    expect(shouldAttachBoardMap(craft)).toBe(true);
    expect(shouldAttachBoardMap(tile)).toBe(false);
  });

  it("keys the board map by docBoardId, never by the surface id", () => {
    // The surface id and docBoardId are the same value for a craft board
    // today. Keying by docBoardId is what stops a future surface whose id is
    // an export id from minting an artboard under that id.
    expect(boardMapKeyFor(craft)).toBe("b1");
    expect(boardMapKeyFor(tile)).toBeNull();
  });

  it("derives the overlay sink from doc ownership", () => {
    expect(overlaySinkFor(craft)).toBe("doc");
    expect(overlaySinkFor(tile)).toBe("rest");
  });

  it("persists a position only when the doc owns the layout", () => {
    expect(canPersistBoardPosition(craft)).toBe(true);
    expect(canPersistBoardPosition(tile)).toBe(false);
  });

  it("handles the master row: doc-backed overlays, view-owned position", () => {
    // The row that rules out a single "is collaborative" flag. Resize's master
    // row IS a craft board — an overlay edited there lands in the doc — but it
    // sits in a fixed column, so its position must never be written back.
    expect(shouldAttachBoardMap(masterRow)).toBe(true);
    expect(overlaySinkFor(masterRow)).toBe("doc");
    expect(canPersistBoardPosition(masterRow)).toBe(false);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd web && bun test src/components/studio/kv-generator/kvSurface.test.ts
```

Expected: FAIL — none of the four functions are exported.

- [ ] **Step 3: Write the implementation**

Append to `kvSurface.ts`:

```ts
/**
 * The participation rules, kept pure because their real call sites cannot be
 * tested where they live: `ensureBoardMap` is private to `KvFabricCanvas.tsx`
 * (4,000+ lines, and Fabric needs a real 2D context jsdom does not have), and
 * the position write is buried in the Yjs binding's Fabric event handlers.
 */

/** Does this surface own an entry in `doc.boards`? */
export function shouldAttachBoardMap(
  surface: Pick<KvSurface, "docBoardId">
): boolean {
  return surface.docBoardId != null;
}

/** The key to attach that entry under — never the surface's own id. Null when
 *  the surface owns no board. */
export function boardMapKeyFor(
  surface: Pick<KvSurface, "docBoardId">
): string | null {
  return surface.docBoardId;
}

/** Where this surface's overlay edits belong. Derived from doc ownership
 *  rather than declared, so the two cannot drift apart. */
export function overlaySinkFor(
  surface: Pick<KvSurface, "docBoardId">
): "doc" | "rest" {
  return surface.docBoardId != null ? "doc" : "rest";
}

/** May a drag of this surface write its centre back to the doc? */
export function canPersistBoardPosition(
  surface: Pick<KvSurface, "layout">
): boolean {
  return surface.layout === "doc";
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd web && bun test src/components/studio/kv-generator/kvSurface.test.ts
```

Expected: PASS.

- [ ] **Step 5: Lint, type-check, commit**

```bash
cd web && bunx eslint src/components/studio/kv-generator/kvSurface.ts src/components/studio/kv-generator/kvSurface.test.ts && bunx tsc --noEmit
git add web/src/components/studio/kv-generator/kvSurface.ts web/src/components/studio/kv-generator/kvSurface.test.ts
git commit -m "feat(web): pure rules for KV board-doc participation"
```

---

### Task 3: Gate the canvas's board-map attachment

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvFabricCanvas.tsx` — `:1118`, `:1187`, `:1206`, and `ensureBoardMap` at `:3924`
- Test: none possible for this file (see Global Constraints)

**Interfaces:**
- Consumes: `shouldAttachBoardMap`, `boardMapKeyFor` from Task 2; the existing `surfaceById` map (built in this component from `effectiveBoards`)
- Produces: nothing new

`ensureBoardMap(doc, board)` currently takes a `KvBoard` and keys by `board.id`. It becomes surface-driven: it takes the key and the seed values, and the call sites skip it entirely when the surface owns no board.

- [ ] **Step 1: Change the helper's signature**

Replace `ensureBoardMap`'s signature and its first lookup (`:3924-3926`) so it is keyed explicitly:

```ts
function ensureBoardMap(
  doc: KvYDoc,
  boardKey: string,
  board: KvBoard
): Y.Map<unknown> {
  const existing = doc.boards.get(boardKey);
  if (existing) return existing;
```

Leave the rest of the body as it is, except: wherever it used `board.id` as the key for the NEW map, use `boardKey`. It still reads `board.center` / `board.name` / `board.version_ids` for the seed values — those are unchanged.

- [ ] **Step 2: Gate the three call sites**

At `:1118`, `:1187`, and `:1206` the current form is `ensureBoardMap(doc, X)` where `X` is a `KvBoard`. Each becomes a lookup-then-skip. Write a small local helper next to `surfaceById` so the three sites stay readable:

```ts
  // A surface that owns no doc board gets no board map — that is what stops a
  // future Resize export tile from minting a phantom artboard into this file's
  // canvas_state. Craft boards all own one, so this is inert today.
  const boardMapFor = useCallback(
    (b: KvBoard): Y.Map<unknown> | null => {
      const surface = surfaceById.get(b.id);
      if (!surface || !shouldAttachBoardMap(surface)) return null;
      const key = boardMapKeyFor(surface);
      if (key == null) return null;
      return ensureBoardMap(doc, key, b);
    },
    [surfaceById, doc]
  );
```

Then each call site becomes `boardMap: boardMapFor(succ)` / `boardMap: boardMapFor(board)`.

- [ ] **Step 3: Let the tag carry a null board map**

All three sites feed the result into the Fabric object's tag: `data = { boardId, boardMap }`. That tag's type in `web/src/lib/kv/yjsBinding.ts:43` declares `boardMap: Y.Map<unknown>` — non-nullable — so a `null` is a compile error rather than a runtime surprise. Widen it:

```ts
  boardMap: Y.Map<unknown> | null;
```

The binding's write path already tolerates this without further change: `writeBoardCenter` re-resolves the live entry from the doc by id (`resolveLiveBoardEntry(meta.boardId)`) and returns early when there is none, so a surface with no board in the doc simply never writes. The retag comparison just below it (`live.map !== meta.boardMap`) treats `null` as "stale, retag" and is harmless.

Before moving on, grep every read of `.boardMap` and confirm each either re-resolves from the doc or tolerates null:

```bash
cd web && grep -rn "boardMap" src/lib/kv/yjsBinding.ts src/components/studio/kv-generator/KvFabricCanvas.tsx
```

`repositionBoard` and `attachBoardObserver` take their map from `boards.forEach`, not from the tag, so they are unaffected. If you find a read that would dereference a null, report it and stop — do NOT invent a fallback that re-attaches a map, because that would be the phantom artboard coming back through a side door.

- [ ] **Step 4: Verify**

```bash
cd web && bunx tsc --noEmit
```

Expected: no error naming `KvFabricCanvas.tsx`.

```bash
cd web && bunx eslint src/components/studio/kv-generator/KvFabricCanvas.tsx
```

Expected: no NEW error (this file has pre-existing ones; compare counts).

```bash
cd web && bun run build
```

Expected: compiled successfully.

- [ ] **Step 5: Commit**

```bash
git add web/src/components/studio/kv-generator/KvFabricCanvas.tsx
git commit -m "refactor(web): attach a board map only when the surface owns one"
```

---

### Task 4: Gate the binding's position write

**Files:**
- Modify: `web/src/lib/kv/yjsBinding.ts` — the `BindKvOptions` type, and the board-centre write at `:208-212`
- Modify: `web/src/components/studio/kv-generator/KvFabricCanvas.tsx:997` — pass the new option
- Test: none possible (the write lives inside Fabric event handlers)

**Interfaces:**
- Consumes: `canPersistBoardPosition` from Task 2
- Produces: `BindKvOptions` gains `canPersistBoardPosition?: (boardId: string) => boolean`

- [ ] **Step 1: Add the option**

In `BindKvOptions`, add:

```ts
  /** Gate on writing a dragged board's centre back to the doc. Defaults to
   *  allowing it, which is the Craft behaviour. A view that computes its own
   *  layout (Resize lays boards out as a fixed column) passes a predicate that
   *  returns false, so its layout can never overwrite Craft's artboard
   *  centres. */
  canPersistBoardPosition?: (boardId: string) => boolean;
```

- [ ] **Step 2: Gate the write**

At `:208-212`, after `const live = resolveLiveBoardEntry(meta.boardId);` and its null check, before the transact:

```ts
    if (opts.canPersistBoardPosition?.(live.key) === false) return;
```

Use `=== false` rather than `!opts.canPersistBoardPosition?.(...)` — an absent option must mean "allowed", and the negation form would read `undefined` as "denied" and silently stop every Craft drag from persisting.

- [ ] **Step 3: Pass it from the canvas**

At `KvFabricCanvas.tsx:997`, inside the options object passed to `bindKvCanvasToYjs`:

```ts
      canPersistBoardPosition: (boardId) => {
        const surface = surfaceById.get(boardId);
        // Unknown board — leave today's behaviour alone rather than silently
        // dropping a legitimate drag.
        return surface ? canPersistBoardPositionRule(surface) : true;
      },
```

Import the rule under an alias so it does not shadow the option name:

```ts
import { canPersistBoardPosition as canPersistBoardPositionRule } from "./kvSurface";
```

- [ ] **Step 4: Verify**

```bash
cd web && bunx tsc --noEmit
```

Expected: no error naming `yjsBinding.ts` or `KvFabricCanvas.tsx`.

```bash
cd web && bunx eslint src/lib/kv/yjsBinding.ts src/components/studio/kv-generator/KvFabricCanvas.tsx
```

Expected: no NEW error.

```bash
cd web && bun run build
```

Expected: compiled successfully.

- [ ] **Step 5: Commit**

```bash
git add web/src/lib/kv/yjsBinding.ts web/src/components/studio/kv-generator/KvFabricCanvas.tsx
git commit -m "feat(web): let a view keep its board layout out of the doc"
```

---

### Task 5: Confirm nothing moved

**Files:**
- Modify: none expected

- [ ] **Step 1: Run the KV suite**

```bash
cd web && bun test src/components/studio/kv-generator
```

Expected: no NEW failures against the baseline you recorded at the start. Report both numbers.

- [ ] **Step 2: Confirm the rules have no bypass**

```bash
cd web && grep -n "ensureBoardMap" src/components/studio/kv-generator/KvFabricCanvas.tsx
```

Expected: the definition, plus exactly one call — inside `boardMapFor`. Any other direct call is a bypass of the gate; report it rather than fixing it silently.

```bash
cd web && grep -rn "boards.get\|boards.set" src/lib/kv/yjsBinding.ts src/components/studio/kv-generator/KvFabricCanvas.tsx
```

Read every hit and say whether it could attach a board entry outside `boardMapFor`. A bare "looks fine" is a failed step.

- [ ] **Step 3: Build**

```bash
cd web && bun run build
```

Expected: clean.

- [ ] **Step 4: Report the tree**

```bash
git status
```

Expected: clean.

## Manual verification (human owns this)

Craft must be unchanged, because every surface it draws is `layout: "doc"` with a `docBoardId`. Confirm: dragging a board still persists its position across a reload, board captions and the master flag survive a reload (the area of the 2026-08-10 data-loss fixes), and a two-browser session still syncs board moves.

## What this unblocks

Step 2b — the layout seam, where a view supplies its own board positions — now has somewhere to put the answer. Step 3 builds the Resize view on the same engine, producing the first surfaces with `docBoardId: null` and `layout: "view"`, which is when these gates stop being inert.
