# KV Resize Boards (Read-Only) — Step 3a Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render the Resize tab's tiles as boards in the Fabric world canvas — a read-only vertical column, master on top — so the board-doc participation gates PR #426 built are exercised by a real surface for the first time.

**Architecture:** The Fabric canvas gains a `surfaces` prop so a view can supply `KvSurface` values that are not generations, plus a `boardsDraggable` switch. A new `KvResizeBoardView` builds those surfaces from the resize exports (`docBoardId: null`, `layout: "view"`) and the source generation (the master row: `docBoardId` = generation id, `layout: "view"`), positions them with a pure column-layout function, and mounts behind a dev-only URL flag while today's DOM rows stay the default.

**Tech Stack:** Next.js 16 / React 19 client components, Fabric v7, Yjs, TypeScript, `bun test` (bunfig preloads jest-dom).

## Global Constraints

- **Governing spec:** `docs/superpowers/specs/2026-08-10-kv-canvas-surface-unification-design.md`. Participation model: `docs/superpowers/specs/2026-08-11-kv-board-doc-participation-design.md`. Read both before starting.
- **Branch:** `improvement/daffa/vc-kv-resize-boards-readonly`, cut from `develop` (PR #426 merged into develop on 2026-08-12).
- **Test runner is `bun test` from `web/`.** Never `bunx vitest`.
- **There is no type gate in the build.** `bunx tsc --noEmit` is ~566 errors at baseline. Only NEW errors naming files you touched count.
- **The suite has ~122 pre-existing failures** (React Testing Library's `screen` is broken under bun). The bar is "no new failures", not green. Record the baseline in Task 0.
- **Never `git stash`** in this working tree. Compare against the baseline worktree at `.worktrees/web-baseline`.
- `web/` is a nested git repo — run git with cwd inside it.
- **Craft must be untouched.** Every change to `KvFabricCanvas.tsx` in this plan is either additive (a new optional prop) or a mechanical retype whose Craft behaviour is identical. The canvas cannot be component-tested (Fabric needs a real 2D context; jsdom has none), so rules live in pure modules and the canvas only calls them.
- **Read-only means read-only.** 3a wires no chrome, no editing, no actions. In particular: do NOT pass `onResetBoardPosition`, `onSetMaster`, `onBoardMove`, `onPlaceText`, `onPlaceImage`, `onPlaceShape`, `onRemoveBoard`, `onCreateVariant` or `onRenameBoard` to the Resize view's canvas. `docMoveBoard` and `docSetMasterBoard` write the doc with no participation check (named in the participation spec, deliberately left ungated) — not wiring them is the whole protection.

---

## Two findings that change 3a's scope

Both were found reading the code for this plan. Neither is named in either spec. Read them before the tasks.

### Finding 1 — `ensureBoardMap` seeds a position for a `layout: "view"` surface (must fix in 3a)

The participation model gates the **drag** write (`canPersistBoardPosition` → `lib/kv/yjsBinding.ts:228`). Nothing gates the **creation** write.

`boardMapFor` runs for **every rendered surface** at image load and at every reconcile (`KvFabricCanvas.tsx:1233`, `:1252`) — not only on drag. When the key is absent from the doc, `ensureBoardMap` (`KvFabricCanvas.tsx:3977-4009`) **creates** the board map and seeds `x`/`y` from `board.center`.

The Resize **master row** has `docBoardId != null` (so it attaches) and `layout: "view"` (so its centre is a column slot). If the doc has no board map for that generation when the Resize view first renders, opening the Resize tab mints an artboard **at the Resize column coordinates**, and `useKvBoardMaterialization` — mounted at layout level on the shared doc (`KvGeneratorLayout.tsx:480`), full-replace PATCH — persists it.

Reachable today, not hypothetical: `computeBoardLayout` filters boards by mode (`modeFilter: "sketch" | "craft"`), so a *sketch* generation sent to Resize has no craft board map; the seeder only ever seeds the boards Craft computed.

**Fix, in Task 1 + Task 2:** split the two powers. A surface may **attach** to a doc board that already exists; only a `layout: "doc"` surface may **create** one. Attaching is what lets the master row edit the same overlays as its Craft board; creating is what would write a view coordinate into the doc.

### Finding 2 — the column loses today's proportional tile sizing (decision, deferred)

The handoff says `BOARD_WORLD_WIDTH` "is exactly how Resize lays its rows out today". It is not. Today every row is scaled by one shared factor off its **native** size (`KvResizeCanvas.tsx:310-314`): the widest native dimension maps to 752px and everything smaller renders proportionally narrower, so an 800×800 logo tile is visibly smaller than a 1920×1080 tile. `BOARD_WORLD_WIDTH` is a constant 512 for every board, with height from aspect.

So the new column renders every tile at the **same width**. The 3a DoD ("each tile shows its own image at its own aspect ratio") is still met, but the relative-size cue that ships today is lost.

**Decision for 3a: accept uniform width.** Per-surface world width is an engine change (`BOARD_WORLD_WIDTH` is a module constant threaded through `boardWorldRect`, the overlay host rect, the drag guides and the fit-all bbox), it is not needed to prove the gates, and 3a is behind a flag nobody ships. **This is a real difference the flag must not hide forever:** step 3b or 3c has to restore proportional sizing before step 4 deletes the DOM rows, or the change lands as a UX regression on a shipped surface. Task 7 records it in the handoff.

---

## Decision: how the new view is exposed

**A dev-only URL flag: `?resizeCanvas=fabric`, additionally hard-gated on `process.env.NODE_ENV !== "production"`.**

- **Not a PostHog flag.** `useMajorFeatureFlag` is force-ON in dev/staging (see the `frndos-experimental-features` skill) — it only gates in production, so it cannot act as a local toggle, and comparing old vs new side by side is exactly what 3a needs. Registering a flag + Early Access Feature for scaffolding that step 4 deletes is overhead with a cleanup cost.
- **Not localStorage.** Sticky invisible state; a forgotten key turns into "why does my Resize look wrong?" weeks later.
- **Not a straight replacement.** The spec's "no feature flag, straight replacement" (spec line 62) is about the *final* rollout, and it is mitigated there by ordering: the old path dies only once parity is green. A read-only column with no chrome is not parity — replacing today's rows with it would leave Resize unusable until 3c.
- `useSearchParams` from `next/navigation` is already the pattern in this route family (`src/app/(canvas)/brands/[id]/studio/kv-generator/new/page.tsx`).

The flag is deleted in step 4 along with the DOM rows.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `src/components/studio/kv-generator/kvSurface.ts` | Modify | Add `canSeedBoardMap` — the create-vs-attach rule. Stays the one home for participation rules. |
| `src/components/studio/kv-generator/kvSurface.test.ts` | Modify | Cover the new rule and its relationship to `shouldAttachBoardMap`. |
| `src/lib/kv/boardMaps.ts` | Create | `resolveBoardMap(doc, key, seed)` — doc board lookup with creation as an explicit, optional power. Moved out of `KvFabricCanvas.tsx` so it can be tested against a real `Y.Doc` without a canvas. |
| `src/lib/kv/boardMaps.test.ts` | Create | Attach-vs-seed behaviour on a real `Y.Doc`. |
| `src/components/studio/kv-generator/resizeColumnLayout.ts` | Create | Pure column layout: ordered surfaces → centres. |
| `src/components/studio/kv-generator/resizeColumnLayout.test.ts` | Create | Order, spacing, aspect-driven heights, independence from persisted state. |
| `src/components/studio/kv-generator/resizeSurfaces.ts` | Create | `KvResizeExport` / source generation → `KvSurface`. |
| `src/components/studio/kv-generator/resizeSurfaces.test.ts` | Create | The participation pairs, including "no export id is ever a doc board key". |
| `src/components/studio/kv-generator/KvFabricCanvas.tsx` | Modify | Accept `surfaces` + `boardsDraggable`; iterate surfaces rather than boards; route seeding through the new rule. |
| `src/components/studio/kv-generator/KvResizeBoardView.tsx` | Create | The Resize view: builds surfaces, lays them out, mounts the canvas read-only. |
| `src/components/studio/kv-generator/KvResizeBoardView.test.tsx` | Create | Surface construction + ordering at the view level (canvas mocked). |
| `src/components/studio/kv-generator/KvGeneratorLayout.tsx` | Modify | Read the flag; mount `KvResizeBoardView` instead of `KvResizeCanvas` when on. |

---

## Task 0: Record the baseline

**Files:** none (measurement only).

**Interfaces:**
- Consumes: nothing.
- Produces: `/tmp` baseline files every later task's verification step compares against.

- [ ] **Step 1: Cut the branch**

```bash
cd web && git fetch origin --prune && git checkout -b improvement/daffa/vc-kv-resize-boards-readonly origin/develop
```

If `git checkout` complains that `develop` is checked out in another worktree, that is expected — this command creates a NEW branch off `origin/develop` and is unaffected.

- [ ] **Step 2: Record the test baseline**

```bash
cd web && bun test 2>&1 | tail -40 > /tmp/kv3a-test-baseline.txt; tail -12 /tmp/kv3a-test-baseline.txt
```

Expected: a summary line reporting roughly 122 failures. Write the exact pass/fail counts into the file — later steps compare against these numbers, not against zero.

- [ ] **Step 3: Record the type baseline**

```bash
cd web && bunx tsc --noEmit 2>&1 | tee /tmp/kv3a-tsc-baseline.txt | tail -3
```

Expected: ~566 errors. This file is the reference for "no NEW errors naming my files".

- [ ] **Step 4: Confirm the build is clean before you touch anything**

```bash
cd web && bun run build 2>&1 | tail -15
```

Expected: build succeeds. If it does not, stop — you are not on a clean base.

---

## Task 1: The create-vs-attach rule

**Files:**
- Modify: `src/components/studio/kv-generator/kvSurface.ts`
- Test: `src/components/studio/kv-generator/kvSurface.test.ts`

**Interfaces:**
- Consumes: `KvSurface` (already defined in `kvSurface.ts`).
- Produces: `canSeedBoardMap(surface: Pick<KvSurface, "docBoardId" | "layout">): boolean` — used by `KvFabricCanvas`'s `boardMapFor` in Task 5.

- [ ] **Step 1: Write the failing test**

Append to `src/components/studio/kv-generator/kvSurface.test.ts`. The file already defines a `board()` helper and imports from `./kvSurface`; add `canSeedBoardMap` to that existing import list, then append:

```ts
describe("canSeedBoardMap", () => {
  const surface = (over: Partial<KvSurface> = {}): KvSurface => ({
    id: "s1",
    docBoardId: "s1",
    layout: "doc",
    imageUrl: null,
    fallbackAspect: 1,
    label: "",
    isActive: false,
    center: { x: 0, y: 0 },
    ...over,
  });

  it("lets a Craft board create the doc board it owns", () => {
    expect(canSeedBoardMap(surface())).toBe(true);
  });

  it("refuses a view-positioned surface that owns a doc board", () => {
    // The Resize master row: same doc board as its Craft board, but its centre
    // is a column slot. Seeding would write that column slot into the doc.
    expect(
      canSeedBoardMap(surface({ docBoardId: "g1", layout: "view" }))
    ).toBe(false);
  });

  it("refuses a surface that owns no doc board", () => {
    expect(
      canSeedBoardMap(surface({ docBoardId: null, layout: "view" }))
    ).toBe(false);
  });

  it("never permits seeding where attaching is not permitted", () => {
    const cases: KvSurface[] = [
      surface(),
      surface({ docBoardId: "g1", layout: "view" }),
      surface({ docBoardId: null, layout: "view" }),
      surface({ docBoardId: null, layout: "doc" }),
    ];
    for (const s of cases) {
      if (canSeedBoardMap(s)) expect(shouldAttachBoardMap(s)).toBe(true);
    }
  });
});
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd web && bun test src/components/studio/kv-generator/kvSurface.test.ts
```

Expected: FAIL — `canSeedBoardMap` is not exported from `./kvSurface`.

- [ ] **Step 3: Implement the rule**

In `src/components/studio/kv-generator/kvSurface.ts`, directly below `canPersistBoardPosition`:

```ts
/** May this surface CREATE the doc board it participates in?
 *
 *  Attaching and creating are different powers, and only the first is settled
 *  by `shouldAttachBoardMap`. A `layout: "view"` surface's centre is computed
 *  by its view (a Resize column slot), so bringing a doc board into existence
 *  at that centre writes a view coordinate into the document — the same
 *  failure `canPersistBoardPosition` prevents on drag, arriving through the
 *  creation path instead. `boardMapFor` calls this for EVERY rendered surface
 *  on every image load and reconcile, not only on drag, so an ungated create
 *  fires just by opening the tab.
 *
 *  A view-positioned surface may still ATTACH to a board that already exists —
 *  that is how the Resize master row edits the same overlays as its Craft
 *  board. It may only never define where one sits. */
export function canSeedBoardMap(
  surface: Pick<KvSurface, "docBoardId" | "layout">
): boolean {
  return surface.docBoardId != null && surface.layout === "doc";
}
```

- [ ] **Step 4: Run the test again**

```bash
cd web && bun test src/components/studio/kv-generator/kvSurface.test.ts
```

Expected: PASS, all cases.

- [ ] **Step 5: Commit**

```bash
cd web && git add src/components/studio/kv-generator/kvSurface.ts src/components/studio/kv-generator/kvSurface.test.ts && git commit -m "feat(web): separate creating a doc board from attaching to one"
```

---

## Task 2: A doc-board resolver whose create power is optional

**Files:**
- Create: `src/lib/kv/boardMaps.ts`
- Test: `src/lib/kv/boardMaps.test.ts`

**Interfaces:**
- Consumes: `KvYDoc`, `YDOC_ORIGIN_LOCAL` from `@/lib/kv/yjsDoc`.
- Produces:
  - `type BoardMapSeed = { center: { x: number; y: number }; name: string | null; versionIds: string[] }`
  - `resolveBoardMap(doc: KvYDoc, boardKey: string, seed: BoardMapSeed | null): Y.Map<unknown> | null`

  Task 5 replaces `KvFabricCanvas.tsx`'s private `ensureBoardMap` with this.

- [ ] **Step 1: Write the failing test**

Create `src/lib/kv/boardMaps.test.ts`:

```ts
import { describe, expect, it } from "bun:test";
import * as Y from "yjs";

import { createKvDoc } from "./yjsDoc";
import { resolveBoardMap, type BoardMapSeed } from "./boardMaps";

const seed = (over: Partial<BoardMapSeed> = {}): BoardMapSeed => ({
  center: { x: 10, y: 20 },
  name: null,
  versionIds: [],
  ...over,
});

describe("resolveBoardMap", () => {
  it("returns the existing map for a direct key hit and creates nothing", () => {
    const doc = createKvDoc();
    const existing = new Y.Map<unknown>();
    doc.boards.set("b1", existing);

    const got = resolveBoardMap(doc, "b1", seed({ center: { x: 999, y: 999 } }));

    expect(got).toBe(existing);
    expect(doc.boards.size).toBe(1);
    // The seed must be ignored entirely when the board already exists.
    expect(existing.get("x")).toBeUndefined();
  });

  it("resolves through the version chain when the key rekeyed", () => {
    const doc = createKvDoc();
    const map = new Y.Map<unknown>();
    const chain = new Y.Array<string>();
    chain.push(["old", "new"]);
    map.set("versionIds", chain);
    doc.boards.set("new", map);

    expect(resolveBoardMap(doc, "old", null)).toBe(map);
    expect(doc.boards.size).toBe(1);
  });

  it("returns null WITHOUT creating anything when no seed is given", () => {
    const doc = createKvDoc();

    expect(resolveBoardMap(doc, "missing", null)).toBeNull();
    // The assertion that matters: a view-positioned surface cannot mint a board.
    expect(doc.boards.size).toBe(0);
    expect(doc.boards.has("missing")).toBe(false);
  });

  it("creates the board when a seed is given", () => {
    const doc = createKvDoc();

    const map = resolveBoardMap(
      doc,
      "b1",
      seed({ center: { x: 5, y: -7 }, name: "Hero", versionIds: ["v0", "b1"] })
    );

    expect(map).not.toBeNull();
    expect(doc.boards.get("b1")).toBe(map!);
    expect(map!.get("x")).toBe(5);
    expect(map!.get("y")).toBe(-7);
    expect(map!.get("name")).toBe("Hero");
    expect((map!.get("versionIds") as Y.Array<string>).toArray()).toEqual([
      "v0",
      "b1",
    ]);
    expect(map!.get("productionStatus")).toBeNull();
    expect(map!.get("assigneeId")).toBeNull();
  });

  it("seeds the board key as the chain rather than an empty array", () => {
    const doc = createKvDoc();

    const map = resolveBoardMap(doc, "b1", seed({ versionIds: [] }));

    // An empty chain slips through every `?? [boardId]` default downstream and
    // propagates forever — the empty-version_ids corruption the serializers
    // now self-heal.
    expect((map!.get("versionIds") as Y.Array<string>).toArray()).toEqual([
      "b1",
    ]);
  });
});
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd web && bun test src/lib/kv/boardMaps.test.ts
```

Expected: FAIL — cannot resolve module `./boardMaps`.

- [ ] **Step 3: Implement the module**

Create `src/lib/kv/boardMaps.ts`:

```ts
import * as Y from "yjs";

import { YDOC_ORIGIN_LOCAL, type KvYDoc } from "./yjsDoc";

/** What a board map needs to be brought into existence. Deliberately NOT a
 *  `KvSurface`: `name` here is the board's RAW persisted name, whereas a
 *  surface carries a DERIVED `label` ("Master · V2"). Writing a derived label
 *  into the doc's `name` is the board-name data loss of 2026-08-10 (`4f99689b`,
 *  `0cc89935`) arriving through a new door, so the two are kept structurally
 *  unable to be confused. */
export type BoardMapSeed = {
  center: { x: number; y: number };
  name: string | null;
  versionIds: string[];
};

/**
 * The doc board map for `boardKey`, or null.
 *
 * Resolution order: direct key hit, then the board whose `versionIds` chain
 * contains `boardKey` (a rekey that landed in the doc before the caller's props
 * caught up). This mirrors `resolveLiveBoardEntry` in `yjsBinding.ts`.
 *
 * Creation is a SEPARATE, OPTIONAL power. Pass `seed: null` and this function
 * is read-only — it can attach a caller to a board that already exists but can
 * never bring one into existence. That is exactly what a view-positioned
 * surface (a Resize row) is allowed to do: its centre belongs to the view, so
 * seeding a board at it would persist a column coordinate as an artboard
 * centre, which the layout-level materializer would then PATCH into
 * `canvas_state` as a full replace. See `canSeedBoardMap` in `kvSurface.ts`.
 *
 * Lifted out of `KvFabricCanvas.tsx` (where it was the private
 * `ensureBoardMap`) so this rule can be tested against a real `Y.Doc`: the
 * canvas itself cannot be component-tested because Fabric needs a 2D context
 * jsdom does not have.
 */
export function resolveBoardMap(
  doc: KvYDoc,
  boardKey: string,
  seed: BoardMapSeed | null
): Y.Map<unknown> | null {
  const existing = doc.boards.get(boardKey);
  if (existing) return existing;

  let chainHit: Y.Map<unknown> | undefined;
  doc.boards.forEach((m) => {
    if (chainHit) return;
    const ids = (m.get("versionIds") as Y.Array<string> | undefined)?.toArray();
    if (ids?.includes(boardKey)) chainHit = m;
  });
  if (chainHit) return chainHit;

  if (!seed) return null;

  const map = new Y.Map<unknown>();
  doc.doc.transact(() => {
    map.set("x", seed.center.x);
    map.set("y", seed.center.y);
    map.set("name", seed.name);
    // Seed the REAL chain, never an empty array: `[]` slips through every
    // `?? [boardId]` default downstream and propagates forever (the
    // empty-version_ids corruption the serializers now self-heal).
    const versionIds = new Y.Array<string>();
    versionIds.push(seed.versionIds.length ? [...seed.versionIds] : [boardKey]);
    map.set("versionIds", versionIds);
    map.set("productionStatus", null);
    map.set("assigneeId", null);
    doc.boards.set(boardKey, map);
  }, YDOC_ORIGIN_LOCAL);
  return map;
}
```

- [ ] **Step 4: Run the test again**

```bash
cd web && bun test src/lib/kv/boardMaps.test.ts
```

Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
cd web && git add src/lib/kv/boardMaps.ts src/lib/kv/boardMaps.test.ts && git commit -m "feat(web): make creating a KV doc board an explicit power"
```

---

## Task 3: The column layout

**Files:**
- Create: `src/components/studio/kv-generator/resizeColumnLayout.ts`
- Test: `src/components/studio/kv-generator/resizeColumnLayout.test.ts`

**Interfaces:**
- Consumes: `boardWorldRect`, `BoardCenter` from `./boardLayout`.
- Produces:
  - `RESIZE_COLUMN_GAP: number`
  - `type ColumnItem = { id: string; aspect: number }`
  - `resizeColumnCenters(items: ColumnItem[], opts: { boardWidth: number; gap?: number; x?: number; startY?: number }): BoardCenter[]`

  Task 6 calls this with `boardWidth: BOARD_WORLD_WIDTH_PUBLIC` (exported in Task 5).

- [ ] **Step 1: Write the failing test**

Create `src/components/studio/kv-generator/resizeColumnLayout.test.ts`:

```ts
import { describe, expect, it } from "bun:test";

import {
  RESIZE_COLUMN_GAP,
  resizeColumnCenters,
  type ColumnItem,
} from "./resizeColumnLayout";

const W = 512;

describe("resizeColumnCenters", () => {
  it("returns one centre per item, in the given order", () => {
    const items: ColumnItem[] = [
      { id: "a", aspect: 1 },
      { id: "b", aspect: 1 },
      { id: "c", aspect: 1 },
    ];

    const centers = resizeColumnCenters(items, { boardWidth: W });

    expect(centers).toHaveLength(3);
    // Same x for every board — this is a column, not a grid.
    expect(centers.map((c) => c.x)).toEqual([0, 0, 0]);
    // Strictly increasing y, so item order IS visual order.
    expect(centers[0].y).toBeLessThan(centers[1].y);
    expect(centers[1].y).toBeLessThan(centers[2].y);
  });

  it("spaces neighbours by half of each height plus the gap", () => {
    // Square: height = W. Two squares stacked.
    const centers = resizeColumnCenters(
      [
        { id: "a", aspect: 1 },
        { id: "b", aspect: 1 },
      ],
      { boardWidth: W }
    );

    expect(centers[1].y - centers[0].y).toBeCloseTo(W + RESIZE_COLUMN_GAP);
  });

  it("derives each board's height from its own aspect", () => {
    // 9:16 portrait is taller than 16:9 landscape at the same world width, so
    // the gap between their centres must reflect BOTH heights.
    const portrait = W / (9 / 16); // 910.2
    const landscape = W / (16 / 9); // 288
    const centers = resizeColumnCenters(
      [
        { id: "portrait", aspect: 9 / 16 },
        { id: "landscape", aspect: 16 / 9 },
      ],
      { boardWidth: W }
    );

    expect(centers[0].y).toBeCloseTo(portrait / 2);
    expect(centers[1].y - centers[0].y).toBeCloseTo(
      portrait / 2 + RESIZE_COLUMN_GAP + landscape / 2
    );
  });

  it("honours explicit x, startY and gap", () => {
    const centers = resizeColumnCenters([{ id: "a", aspect: 1 }], {
      boardWidth: W,
      x: 40,
      startY: 100,
      gap: 0,
    });

    expect(centers[0]).toEqual({ x: 40, y: 100 + W / 2 });
  });

  it("treats a degenerate aspect as square rather than producing NaN", () => {
    const centers = resizeColumnCenters(
      [
        { id: "a", aspect: 0 },
        { id: "b", aspect: 1 },
      ],
      { boardWidth: W }
    );

    expect(Number.isFinite(centers[0].y)).toBe(true);
    expect(centers[0].y).toBeCloseTo(W / 2);
  });

  it("returns an empty array for no items", () => {
    expect(resizeColumnCenters([], { boardWidth: W })).toEqual([]);
  });

  it("depends on nothing but its arguments", () => {
    // The property that matters: a tile's centre can never be influenced by
    // persisted artboard state, so the Resize column can never drift with — or
    // write to — Craft's layout.
    const items: ColumnItem[] = [
      { id: "a", aspect: 4 / 5 },
      { id: "b", aspect: 1 },
    ];

    expect(resizeColumnCenters(items, { boardWidth: W })).toEqual(
      resizeColumnCenters(items, { boardWidth: W })
    );
  });
});
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd web && bun test src/components/studio/kv-generator/resizeColumnLayout.test.ts
```

Expected: FAIL — cannot resolve module `./resizeColumnLayout`.

- [ ] **Step 3: Implement the layout**

Create `src/components/studio/kv-generator/resizeColumnLayout.ts`:

```ts
import { boardWorldRect, type BoardCenter } from "./boardLayout";

/** Vertical space between two boards in the Resize column, in world units.
 *  Roughly the 16px DOM gap today's rows use, scaled into a world where a board
 *  is 512 wide and a tile renders ~752px on screen. */
export const RESIZE_COLUMN_GAP = 96;

/** The only thing the column needs to know about a surface: its identity (so a
 *  caller can zip the result back onto its own list) and the shape it will
 *  occupy. */
export type ColumnItem = { id: string; aspect: number };

/**
 * Centres for a vertical column of boards: same x, increasing y, each board
 * spaced from the previous by half of each height plus a fixed gap.
 *
 * Pure and total — it reads nothing but its arguments, and that is the point
 * rather than a stylistic preference. The Resize view is `layout: "view"`:
 * its board positions must never be derived from (or able to disturb) the
 * persisted artboard centres the Craft canvas owns. A function that cannot see
 * that state cannot depend on it.
 *
 * Height comes from `boardWorldRect`, the same converter the canvas draws with,
 * so a caller cannot end up computing a layout in one geometry and rendering it
 * in another.
 */
export function resizeColumnCenters(
  items: ColumnItem[],
  opts: {
    /** World width every board occupies — the canvas's `BOARD_WORLD_WIDTH`. */
    boardWidth: number;
    gap?: number;
    x?: number;
    /** World y of the column's top edge. */
    startY?: number;
  }
): BoardCenter[] {
  const gap = opts.gap ?? RESIZE_COLUMN_GAP;
  const x = opts.x ?? 0;
  const origin: BoardCenter = { x: 0, y: 0 };
  let topEdge = opts.startY ?? 0;

  return items.map((item) => {
    const { height } = boardWorldRect(origin, opts.boardWidth, item.aspect);
    const center: BoardCenter = { x, y: topEdge + height / 2 };
    topEdge += height + gap;
    return center;
  });
}
```

- [ ] **Step 4: Run the test again**

```bash
cd web && bun test src/components/studio/kv-generator/resizeColumnLayout.test.ts
```

Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
cd web && git add src/components/studio/kv-generator/resizeColumnLayout.ts src/components/studio/kv-generator/resizeColumnLayout.test.ts && git commit -m "feat(web): add the KV Resize column layout"
```

---

## Task 4: Surfaces from resize exports

**Files:**
- Create: `src/components/studio/kv-generator/resizeSurfaces.ts`
- Test: `src/components/studio/kv-generator/resizeSurfaces.test.ts`

**Interfaces:**
- Consumes: `KvSurface`, `bestEffortAspect` from `./kvSurface`; `BoardCenter` from `./boardLayout`; `KvResizeExport` from `@/types/kv/resize`; `KvGeneration` from `@/types/studio`.
- Produces:
  - `surfaceFromResizeMaster(source: KvGeneration, opts: { center: BoardCenter; isActive: boolean; sourceVersionIds?: string[] | null }): KvSurface`
  - `surfaceFromResizeExport(row: KvResizeExport, opts: { center: BoardCenter; isActive: boolean }): KvSurface`
  - `resizeSurfaceAspect(row: KvResizeExport): number`

- [ ] **Step 1: Write the failing test**

Create `src/components/studio/kv-generator/resizeSurfaces.test.ts`:

```ts
import { describe, expect, it } from "bun:test";

import type { KvResizeExport } from "@/types/kv/resize";
import type { KvGeneration } from "@/types/studio";

import {
  canPersistBoardPosition,
  canSeedBoardMap,
  overlaySinkFor,
  shouldAttachBoardMap,
} from "./kvSurface";
import {
  resizeSurfaceAspect,
  surfaceFromResizeExport,
  surfaceFromResizeMaster,
} from "./resizeSurfaces";

const center = { x: 0, y: 0 };

const source = (over: Partial<KvGeneration> = {}): KvGeneration => ({
  id: "g1",
  studio_file_id: "f1",
  version_number: 1,
  mode: "craft",
  image_url: "https://example.com/source.png",
  thumbnail_url: null,
  prompt_snapshot: "",
  model: "test",
  parent_generation_id: null,
  metadata: { width: 1024, height: 1024 },
  created_at: "2026-08-12T00:00:00Z",
  ...over,
});

const row = (over: Partial<KvResizeExport> = {}): KvResizeExport => ({
  id: "e1",
  studioFileId: "f1",
  parentGenerationId: "g1",
  platformId: "instagram-story",
  platformLabel: "Instagram Story / Reel",
  platformGroup: "social-media",
  width: 1080,
  height: 1920,
  imageUrl: "https://example.com/e1.png",
  status: "done",
  cropWindow: null,
  overlays: null,
  errorMessage: null,
  createdAt: "2026-08-12T00:00:00Z",
  updatedAt: "2026-08-12T00:00:00Z",
  ...over,
});

describe("surfaceFromResizeExport", () => {
  it("owns no doc board, so no export id can become an artboard key", () => {
    const s = surfaceFromResizeExport(row(), { center, isActive: false });

    expect(s.docBoardId).toBeNull();
    expect(shouldAttachBoardMap(s)).toBe(false);
    expect(canSeedBoardMap(s)).toBe(false);
  });

  it("routes its overlay edits to REST, keyed by its own id", () => {
    const s = surfaceFromResizeExport(row(), { center, isActive: false });

    expect(overlaySinkFor(s)).toBe("rest");
    expect(s.id).toBe("e1");
  });

  it("is positioned by the view, so a drag could never persist", () => {
    const s = surfaceFromResizeExport(row(), { center, isActive: false });

    expect(s.layout).toBe("view");
    expect(canPersistBoardPosition(s)).toBe(false);
  });

  it("takes its aspect from the target size and its label from the platform", () => {
    const s = surfaceFromResizeExport(row(), { center, isActive: false });

    expect(s.fallbackAspect).toBeCloseTo(1080 / 1920);
    expect(s.label).toBe("Instagram Story / Reel");
    expect(s.isMaster).toBe(false);
  });

  it("carries a null image while the export is still generating", () => {
    const s = surfaceFromResizeExport(
      row({ status: "generating", imageUrl: null }),
      { center, isActive: false }
    );

    expect(s.imageUrl).toBeNull();
    // Still a real aspect, so the empty slot has the right shape.
    expect(s.fallbackAspect).toBeCloseTo(1080 / 1920);
  });
});

describe("resizeSurfaceAspect", () => {
  it("falls back to square on a degenerate target size", () => {
    expect(resizeSurfaceAspect(row({ width: 0, height: 0 }))).toBe(1);
    expect(resizeSurfaceAspect(row({ height: 0 }))).toBe(1);
  });
});

describe("surfaceFromResizeMaster", () => {
  it("owns the SAME doc board as its Craft board", () => {
    const s = surfaceFromResizeMaster(source(), { center, isActive: true });

    expect(s.docBoardId).toBe("g1");
    expect(shouldAttachBoardMap(s)).toBe(true);
    expect(overlaySinkFor(s)).toBe("doc");
  });

  it("is view-positioned, so it neither seeds nor persists a centre", () => {
    const s = surfaceFromResizeMaster(source(), { center, isActive: true });

    // The pair that is the whole reason the model has two fields: doc-backed
    // for overlays, view-positioned for geometry. Do not collapse it.
    expect(s.layout).toBe("view");
    expect(canSeedBoardMap(s)).toBe(false);
    expect(canPersistBoardPosition(s)).toBe(false);
  });

  it("carries the source's version chain so a rekey still resolves", () => {
    const s = surfaceFromResizeMaster(source(), {
      center,
      isActive: true,
      sourceVersionIds: ["g0", "g1"],
    });

    expect(s.version_ids).toEqual(["g0", "g1"]);
  });

  it("takes its aspect from the generation metadata", () => {
    const s = surfaceFromResizeMaster(
      source({ metadata: { aspect_ratio: "16:9" } }),
      { center, isActive: false }
    );

    expect(s.fallbackAspect).toBeCloseTo(16 / 9);
  });
});
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd web && bun test src/components/studio/kv-generator/resizeSurfaces.test.ts
```

Expected: FAIL — cannot resolve module `./resizeSurfaces`.

- [ ] **Step 3: Implement the producers**

Create `src/components/studio/kv-generator/resizeSurfaces.ts`:

```ts
import type { KvResizeExport } from "@/types/kv/resize";
import type { KvGeneration } from "@/types/studio";

import type { BoardCenter } from "./boardLayout";
import { bestEffortAspect, type KvSurface } from "./kvSurface";

/** A tile's shape comes from the TARGET size it was requested at, not from the
 *  rendered image — the shape has to be right before the image exists (pending
 *  and generating tiles). Degenerate sizes fall back to square rather than
 *  producing Infinity/NaN and a board of infinite height. */
export function resizeSurfaceAspect(row: KvResizeExport): number {
  return row.width > 0 && row.height > 0 ? row.width / row.height : 1;
}

/**
 * The Resize MASTER row.
 *
 * `docBoardId` is the source generation id — the SAME doc board the Craft
 * canvas draws — so an overlay edited here lands exactly where it would in
 * Craft. `layout: "view"` is what stops that shared identity from dragging
 * Craft's artboard centre into the Resize column.
 *
 * That pair is the entire reason the model carries two fields instead of one
 * "is collaborative" flag. Do not collapse it.
 */
export function surfaceFromResizeMaster(
  source: KvGeneration,
  opts: {
    center: BoardCenter;
    isActive: boolean;
    /** The source board's version chain, when the file's canvas state resolves
     *  one. Lets a doc lookup survive a polish rekey, exactly as it does for a
     *  Craft board. */
    sourceVersionIds?: string[] | null;
  }
): KvSurface {
  return {
    id: source.id,
    docBoardId: source.id,
    layout: "view",
    imageUrl: source.image_url ?? null,
    fallbackAspect: bestEffortAspect(source),
    label: "Original",
    isMaster: true,
    isActive: opts.isActive,
    center: opts.center,
    version_ids: opts.sourceVersionIds ?? null,
  };
}

/**
 * A Resize export tile.
 *
 * `docBoardId: null` is load-bearing twice over. It makes an artboard keyed by
 * an export id impossible BY CONSTRUCTION rather than prevented by a guard that
 * can leak — no doc board id, no board map, nothing for the materializer to
 * persist. And it is what routes this surface's overlay edits to REST
 * (`updateOverlays.mutate({ exportId, overlays })`) instead of the shared doc:
 * a tile is a per-platform derivative that can be regenerated at will, not a
 * collaborative asset.
 */
export function surfaceFromResizeExport(
  row: KvResizeExport,
  opts: { center: BoardCenter; isActive: boolean }
): KvSurface {
  return {
    id: row.id,
    docBoardId: null,
    layout: "view",
    imageUrl: row.imageUrl,
    fallbackAspect: resizeSurfaceAspect(row),
    label: row.platformLabel,
    isMaster: false,
    isActive: opts.isActive,
    center: opts.center,
    version_ids: null,
  };
}
```

- [ ] **Step 4: Run the test again**

```bash
cd web && bun test src/components/studio/kv-generator/resizeSurfaces.test.ts
```

Expected: PASS, 11 tests.

- [ ] **Step 5: Commit**

```bash
cd web && git add src/components/studio/kv-generator/resizeSurfaces.ts src/components/studio/kv-generator/resizeSurfaces.test.ts && git commit -m "feat(web): build KV surfaces from resize exports"
```

---

## Task 5: The canvas accepts surfaces and a draggability switch

**Files:**
- Modify: `src/components/studio/kv-generator/KvFabricCanvas.tsx`

**Interfaces:**
- Consumes: `resolveBoardMap` / `BoardMapSeed` (Task 2), `canSeedBoardMap` (Task 1).
- Produces:
  - new props on `KvFabricCanvas`: `surfaces?: KvSurface[]`, `boardsDraggable?: boolean` (default `true`)
  - `export const BOARD_WORLD_WIDTH_PUBLIC: number` — the world width Task 6 lays the column out with.

**This is the riskiest task in the plan.** It edits the canvas people use daily, and it cannot be component-tested. Everything here is either additive or a like-for-like retype: **no Craft behaviour may change.** Make it one commit so it can be reverted whole.

- [ ] **Step 1: Export the world width and import the new rules**

At the top of `KvFabricCanvas.tsx`, beside the existing `const BOARD_WORLD_WIDTH = 512;` (line ~78), add:

```ts
/** The world width above, re-exported for views that must lay boards out in the
 *  same geometry the canvas draws them in (the Resize column). Kept as a
 *  separate name so the internal constant stays a plain module-local. */
export const BOARD_WORLD_WIDTH_PUBLIC = BOARD_WORLD_WIDTH;
```

Extend the existing `./kvSurface` import (line ~19) with `canSeedBoardMap`, and add next to the `@/lib/kv/yjsDoc` import:

```ts
import { resolveBoardMap } from "@/lib/kv/boardMaps";
```

- [ ] **Step 2: Add the two props**

In `type Props` (line ~237), after the `boards?: KvBoard[];` entry:

```ts
  /** Surfaces to draw, when the view builds them itself rather than handing
   *  over generations. Takes precedence over `boards`. This is the seam that
   *  lets a Resize tile — which is not a generation — be drawn by this canvas:
   *  see `resizeSurfaces.ts`. Craft passes `boards` and this stays undefined. */
  surfaces?: KvSurface[];
  /** May the user move boards in this view? False for a view that owns its own
   *  layout (the Resize column), where a drag would fight the layout function.
   *  This is a second, independent layer on top of the participation model: a
   *  `layout: "view"` surface already refuses to PERSIST a centre, and this
   *  stops one from being moved at all. */
  boardsDraggable?: boolean;
```

Add `surfaces`, `boardsDraggable = true` to the destructured parameter list (line ~395 onward).

- [ ] **Step 3: Derive the surface list from either prop**

Replace the `surfaceById` memo (lines 670-674) with:

```ts
  // Craft-only lookup: the fields that belong to a GENERATION rather than to a
  // drawn surface. Only the Craft path can populate it, and only Craft-only
  // branches may read it (the concept-rationale card, and the board-map seed's
  // raw persisted name). A surface-supplying view has no entry here, which is
  // exactly right — it has no generation to speak of.
  const boardById = useMemo(() => {
    const m = new Map<string, KvBoard>();
    for (const b of effectiveBoards) m.set(b.id, b);
    return m;
  }, [effectiveBoards]);

  // What this canvas actually draws. A view may supply surfaces directly
  // (Resize); otherwise they are adapted from the boards prop (Craft).
  const surfaceList: KvSurface[] = useMemo(
    () => surfaces ?? effectiveBoards.map(surfaceFromBoard),
    [surfaces, effectiveBoards]
  );

  const surfaceById = useMemo(() => {
    const m = new Map<string, KvSurface>();
    for (const s of surfaceList) m.set(s.id, s);
    return m;
  }, [surfaceList]);
```

Then retarget the two memos immediately around it:

```ts
  const activeBoard = useMemo(
    () => surfaceList.find((s) => s.isActive) ?? surfaceList[0] ?? null,
    [surfaceList]
  );
```

and

```ts
  const aspectOf = useCallback(
    (b: { id: string }) =>
      boardAspects[b.id] ?? surfaceById.get(b.id)?.fallbackAspect ?? 1,
    [boardAspects, surfaceById]
  );
```

- [ ] **Step 4: Route the board map through the create-vs-attach rule**

Replace `boardMapFor` (lines 679-688) with:

```ts
  // A surface that owns no doc board gets no board map — that is what stops a
  // Resize export tile from minting a phantom artboard into this file's
  // canvas_state. A surface that owns one but is VIEW-positioned may attach to
  // it and never create it: this callback runs for every rendered surface on
  // every image load and reconcile, so an ungated create would fire just from
  // opening the Resize tab and would seed the board at a column slot.
  const boardMapFor = useCallback(
    (s: KvSurface): Y.Map<unknown> | null => {
      if (!shouldAttachBoardMap(s)) return null;
      const key = boardMapKeyFor(s);
      if (key == null) return null;
      // The seed carries the board's RAW persisted name, never `s.label` —
      // that is derived ("Master · V2"), and writing it into the doc's `name`
      // would be the board-name data loss of 2026-08-10 through a new door.
      // No originating board (a surface-supplying view) ⇒ no seed, ever.
      const origin = canSeedBoardMap(s) ? boardById.get(s.id) : undefined;
      return resolveBoardMap(
        doc,
        key,
        origin
          ? {
              center: origin.center,
              name: origin.name,
              versionIds: origin.version_ids ?? [],
            }
          : null
      );
    },
    [boardById, doc]
  );
```

Delete the now-unused private `ensureBoardMap` function (lines ~3977-4009) and its `KvBoard` import usage there.

- [ ] **Step 5: Retype every board iteration onto surfaces**

Mechanical, one site at a time. In each, the element type becomes `KvSurface` and the field reads stay identical (`id`, `center`, `isActive`, `isMaster`, `version_ids` all exist on `KvSurface`):

1. `boardsSig` (line ~1127) — `surfaceList.map(...)`, and **extend the template
   with the image url**:

```ts
  const boardsSig = surfaceList
    .map((s) => `${s.id}:${s.center.x},${s.center.y}:${s.isActive ? 1 : 0}:${s.imageUrl ?? ""}`)
    .join("|");
```

   A Resize tile's `imageUrl` arrives late (a generating export has `null` until
   it finishes), and the effect must re-run when it does. Putting that in the
   SIGNATURE rather than adding `surfaceList` to the dependency array is
   deliberate — see item 2.

2. The boards→Fabric effect (lines ~1130-1266) — `wanted` from `surfaceList`; the rekey-successor lookup `surfaceList.find((s) => s.version_ids?.includes(data.boardId))`; `boardMapFor(succ)` / `boardMapFor(board)` now take the surface directly (drop the `surfaceById.get(...)` hop where the code re-looked it up); `styleBoard(img, s: KvSurface, aspect)`; the final `surfaceList.forEach(...)` with `const src = s.imageUrl` instead of `surfaceById.get(board.id)?.imageUrl`.

   **Do NOT add `surfaceList` to this effect's dependency array.** `boardsSig` is
   a string precisely so that a `boards` array whose identity changed but whose
   content did not cannot re-run this effect. `surfaceList` is an array, so it
   gets a new identity on every such churn — a rename, a master-flag change, a
   doc-sync settling — none of which change `boardsSig`. That matters because
   the effect's cleanup sets `cancelled = true`: for a board whose image is
   still loading, a re-run makes the in-flight `fabric.FabricImage.fromURL`
   discard its COMPLETED image and start over. The churn is heaviest in the
   first seconds of opening a multi-board file, which is exactly the load
   window. `version_ids` is only read inside the `liveDrag` branch, and
   `liveDrag` is already a dependency, so the signature loses nothing.
3. `overlayHostRect` (lines ~712-727) — `surfaceList.find((s) => s.id === boundId || (s.version_ids?.includes(boundId) ?? false))`.
4. `effectiveBoardsRef` (line ~779) — rename to `surfaceListRef`, assign `surfaceList`, and update its two reader sites (line ~968, and the drag-guides handler).
5. `screenRectOf` (line ~3059) — widen the parameter to `KvSurface | KvPendingBoard`; the body already reads only `center` and `id`.
6. The drag-guides bbox (lines ~2238-2251) and `fitAll` (line ~2658) — map over `surfaceList`.
7. The hit-test helpers (lines ~2696, ~2758) and `resolveToolTarget`'s return type (line ~795) — `{ rect: WorldRect; board: KvSurface }`.
8. `toolRef.current.effectiveBoards` (line ~2584) — rename the field to `surfaceList` and update the object literal that builds it.
9. The DOM label layer (line ~3380) — `surfaceList.map((s) => ...)`; `{s.label}` directly instead of `surfaceById.get(board.id)?.label ?? ""`.

Two branches keep reading the Craft-only lookup, because their data lives on the generation and not on the surface:

```tsx
              {/* Concept badge + creative rationale are Craft/Concept-only:
                  they read the GENERATION, which a view-supplied surface does
                  not have. `boardById` is empty for such a view, so both
                  branches simply do not render — no cast, no fake generation. */}
              {boardById.get(s.id)?.isConceptPreview && (
```

and

```tsx
              {showConceptRationale &&
                (() => {
                  const origin = boardById.get(s.id);
                  if (!origin) return null;
                  const rationale = conceptRationale(origin.generation);
                  if (!rationale) return null;
                  const device = creativeDevice(origin.generation);
```

(the `craftingActiveBoard` pulse's `board.isConceptPreview` reads become `boardById.get(s.id)?.isConceptPreview` the same way.)

- [ ] **Step 6: Honour `boardsDraggable` in all three drag paths**

Boards can be moved three ways; two need the switch, and the third is already covered by the participation model.

In `styleBoard` (line ~1191):

```ts
        selectable: boardsDraggable && tool === "cursor",
        evented: boardsDraggable && tool === "cursor",
```

and its cursor:

```ts
        hoverCursor: boardsDraggable && s.isActive ? "grab" : "pointer",
```

In `onLabelPointerDown` (line ~3082) — the label is a second, independent drag handle:

```ts
  const onLabelPointerDown =
    (s: KvSurface) => (e: React.PointerEvent<HTMLButtonElement>) => {
      if (e.button !== 0 || tool !== "cursor" || !boardsDraggable) return;
```

and in the label's className, gate the grab cursor:

```ts
                  boardsDraggable &&
                    tool === "cursor" &&
                    "cursor-grab active:cursor-grabbing",
```

The third path — the Yjs binding's `writeBoardCenter` — is already denied for these surfaces by `canPersistBoardPosition` (`lib/kv/yjsBinding.ts:228`). Leave it alone; two independent layers is the intent.

- [ ] **Step 7: Verify nothing regressed**

```bash
cd web && bun test 2>&1 | tail -12
```

Expected: the same pass/fail counts as `/tmp/kv3a-test-baseline.txt`. Any NEW failure is a regression — fix it before continuing.

```bash
cd web && bunx tsc --noEmit 2>&1 | grep -E "KvFabricCanvas|kvSurface|boardMaps|resizeColumnLayout|resizeSurfaces" | tee /tmp/kv3a-tsc-task5.txt | head -30
```

Expected: no line that is absent from `/tmp/kv3a-tsc-baseline.txt`. Compare, do not eyeball a count.

```bash
cd web && bun run build 2>&1 | tail -15
```

Expected: build succeeds.

- [ ] **Step 8: Commit**

```bash
cd web && git add src/components/studio/kv-generator/KvFabricCanvas.tsx && git commit -m "refactor(web): draw the KV canvas from surfaces rather than boards"
```

---

## Task 6: The read-only Resize board view

**Files:**
- Create: `src/components/studio/kv-generator/KvResizeBoardView.tsx`
- Test: `src/components/studio/kv-generator/KvResizeBoardView.test.tsx`
- Modify: `src/components/studio/kv-generator/KvGeneratorLayout.tsx`

**Interfaces:**
- Consumes: `resizeColumnCenters` (Task 3), `surfaceFromResizeMaster` / `surfaceFromResizeExport` / `resizeSurfaceAspect` (Task 4), `BOARD_WORLD_WIDTH_PUBLIC` + the `surfaces` / `boardsDraggable` props (Task 5), `useResizeExports` from `@/lib/studio/kv/useResizeExports`, `bestEffortAspect` from `./kvSurface`.
- Produces: `buildResizeSurfaces(...)` (exported for the test) and the `KvResizeBoardView` component.

- [ ] **Step 1: Write the failing test**

Create `src/components/studio/kv-generator/KvResizeBoardView.test.tsx`:

```tsx
import { describe, expect, it } from "bun:test";

import type { KvResizeExport } from "@/types/kv/resize";
import type { KvGeneration } from "@/types/studio";

import { buildResizeSurfaces } from "./KvResizeBoardView";

const source: KvGeneration = {
  id: "g1",
  studio_file_id: "f1",
  version_number: 1,
  mode: "craft",
  image_url: "https://example.com/source.png",
  thumbnail_url: null,
  prompt_snapshot: "",
  model: "test",
  parent_generation_id: null,
  metadata: { width: 1024, height: 1024 },
  created_at: "2026-08-12T00:00:00Z",
};

const row = (over: Partial<KvResizeExport>): KvResizeExport => ({
  id: "e1",
  studioFileId: "f1",
  parentGenerationId: "g1",
  platformId: "instagram-post",
  platformLabel: "Instagram Post",
  platformGroup: "social-media",
  width: 1080,
  height: 1080,
  imageUrl: "https://example.com/e1.png",
  status: "done",
  cropWindow: null,
  overlays: null,
  errorMessage: null,
  createdAt: "2026-08-12T00:00:00Z",
  updatedAt: "2026-08-12T00:00:00Z",
  ...over,
});

describe("buildResizeSurfaces", () => {
  const rows = [
    row({ id: "e1", createdAt: "2026-08-12T00:00:01Z" }),
    row({
      id: "e2",
      createdAt: "2026-08-12T00:00:02Z",
      platformLabel: "TikTok Video",
      width: 1080,
      height: 1920,
    }),
  ];

  it("puts the master on top, then the exports in the given order", () => {
    const surfaces = buildResizeSurfaces(source, rows, { activeId: null });

    expect(surfaces.map((s) => s.id)).toEqual(["g1", "e1", "e2"]);
    expect(surfaces[0].isMaster).toBe(true);
  });

  it("lays them out as a column: same x, strictly increasing y", () => {
    const surfaces = buildResizeSurfaces(source, rows, { activeId: null });

    expect(new Set(surfaces.map((s) => s.center.x)).size).toBe(1);
    expect(surfaces[0].center.y).toBeLessThan(surfaces[1].center.y);
    expect(surfaces[1].center.y).toBeLessThan(surfaces[2].center.y);
  });

  it("never gives an export id a doc board", () => {
    // The acceptance test of PR #426, asserted at the producer level: whatever
    // the doc later does, it can only ever be handed these values.
    const surfaces = buildResizeSurfaces(source, rows, { activeId: null });

    for (const s of surfaces.filter((x) => !x.isMaster)) {
      expect(s.docBoardId).toBeNull();
    }
    expect(surfaces.every((s) => s.layout === "view")).toBe(true);
  });

  it("marks the active surface and only that one", () => {
    const surfaces = buildResizeSurfaces(source, rows, { activeId: "e2" });

    expect(surfaces.filter((s) => s.isActive).map((s) => s.id)).toEqual(["e2"]);
  });

  it("falls back to the master when nothing is active", () => {
    const surfaces = buildResizeSurfaces(source, rows, { activeId: null });

    expect(surfaces.filter((s) => s.isActive).map((s) => s.id)).toEqual(["g1"]);
  });

  it("still lays out a tile that has no image yet", () => {
    const surfaces = buildResizeSurfaces(
      source,
      [row({ id: "e9", status: "generating", imageUrl: null })],
      { activeId: null }
    );

    expect(surfaces[1].imageUrl).toBeNull();
    expect(Number.isFinite(surfaces[1].center.y)).toBe(true);
  });

  it("handles a file with no exports at all", () => {
    const surfaces = buildResizeSurfaces(source, [], { activeId: null });

    expect(surfaces.map((s) => s.id)).toEqual(["g1"]);
  });
});
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd web && bun test src/components/studio/kv-generator/KvResizeBoardView.test.tsx
```

Expected: FAIL — cannot resolve module `./KvResizeBoardView`.

- [ ] **Step 3: Implement the view**

Create `src/components/studio/kv-generator/KvResizeBoardView.tsx`:

```tsx
"use client";

import { useEffect, useMemo, useRef, useState } from "react";

import type { KvResizeExport } from "@/types/kv/resize";
import type { KvGeneration } from "@/types/studio";
import type { KvYDoc } from "@/lib/kv/yjsDoc";
import { useResizeExports } from "@/lib/studio/kv/useResizeExports";

import { BOARD_WORLD_WIDTH_PUBLIC, KvFabricCanvas } from "./KvFabricCanvas";
import { bestEffortAspect, type KvSurface } from "./kvSurface";
import { resizeColumnCenters } from "./resizeColumnLayout";
import {
  resizeSurfaceAspect,
  surfaceFromResizeExport,
  surfaceFromResizeMaster,
} from "./resizeSurfaces";

/**
 * Master row + one surface per export, laid out as a vertical column.
 *
 * Exported for its test: the canvas cannot be rendered in jsdom (Fabric needs a
 * real 2D context), so everything this view decides — order, layout, and which
 * participation values each surface carries — is decided here, in a pure
 * function, and the component only hands the result to the canvas.
 */
export function buildResizeSurfaces(
  source: KvGeneration,
  rows: KvResizeExport[],
  opts: { activeId: string | null; sourceVersionIds?: string[] | null }
): KvSurface[] {
  const centers = resizeColumnCenters(
    [
      { id: source.id, aspect: bestEffortAspect(source) },
      ...rows.map((r) => ({ id: r.id, aspect: resizeSurfaceAspect(r) })),
    ],
    { boardWidth: BOARD_WORLD_WIDTH_PUBLIC }
  );

  // Exactly one surface is active — the canvas uses it as the overlay host, so
  // two (or none, with surfaces present) would be a rendering ambiguity. With
  // nothing selected the master hosts, matching Craft's "latest board hosts"
  // fallback.
  const active = opts.activeId ?? source.id;

  return [
    surfaceFromResizeMaster(source, {
      center: centers[0],
      isActive: active === source.id,
      sourceVersionIds: opts.sourceVersionIds ?? null,
    }),
    ...rows.map((row, i) =>
      surfaceFromResizeExport(row, {
        center: centers[i + 1],
        isActive: active === row.id,
      })
    ),
  ];
}

type Props = {
  fileId: string;
  source: KvGeneration;
  sourceVersionIds?: string[] | null;
  kvDoc: KvYDoc | null;
  showRuler?: boolean;
  gridOpacity?: number;
  gridSize?: number;
};

/**
 * Step 3a of the canvas unification: the Resize tab's tiles drawn as boards in
 * the Fabric world, read-only.
 *
 * Deliberately inert. No chrome (platform label, download, regenerate, failed
 * state), no editing, no actions — those are 3b and 3c. What it exists to prove
 * is that a surface with `docBoardId: null` / `layout: "view"` can be handed to
 * the Craft engine without leaving a trace in the file's `canvas_state`.
 *
 * NOT wired, on purpose: `onResetBoardPosition` and `onSetMaster` reach
 * `docMoveBoard` / `docSetMasterBoard`, which write the doc with no
 * participation check. They are safe here by convention, not by construction —
 * do not add them to this call site.
 */
export function KvResizeBoardView({
  fileId,
  source,
  sourceVersionIds,
  kvDoc,
  showRuler = false,
  gridOpacity,
  gridSize,
}: Props) {
  const { exportsByPlatformId } = useResizeExports(fileId, source.id);
  const hostRef = useRef<HTMLDivElement | null>(null);
  const [size, setSize] = useState({ w: 0, h: 0 });
  const [activeId, setActiveId] = useState<string | null>(null);

  useEffect(() => {
    const el = hostRef.current;
    if (!el) return;
    const measure = () => setSize({ w: el.offsetWidth, h: el.offsetHeight });
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // Same ordering the DOM rows use today (`KvResizeCanvas.tsx:248`), so the
  // column reads in the order people already know.
  const rows = useMemo(
    () =>
      Array.from(exportsByPlatformId.values()).sort((a, b) =>
        a.createdAt.localeCompare(b.createdAt)
      ),
    [exportsByPlatformId]
  );

  const surfaces = useMemo(
    () => buildResizeSurfaces(source, rows, { activeId, sourceVersionIds }),
    [source, rows, activeId, sourceVersionIds]
  );

  return (
    <div ref={hostRef} className="relative h-full w-full">
      {size.w > 0 && size.h > 0 && (
        <KvFabricCanvas
          generation={source}
          width={size.w}
          height={size.h}
          surfaces={surfaces}
          boardsDraggable={false}
          kvDoc={kvDoc}
          fileId={fileId}
          canvasMode="resize"
          tool="cursor"
          // Selection only picks the overlay HOST; editing arrives in 3c.
          onSelectBoard={setActiveId}
          onDeselectBoard={() => setActiveId(null)}
          showRuler={showRuler}
          gridOpacity={gridOpacity}
          gridSize={gridSize}
        />
      )}
    </div>
  );
}
```

- [ ] **Step 4: Run the test again**

```bash
cd web && bun test src/components/studio/kv-generator/KvResizeBoardView.test.tsx
```

Expected: PASS, 7 tests.

- [ ] **Step 5: Mount it behind the flag**

In `KvGeneratorLayout.tsx`, add the import beside the existing `KvResizeCanvas` import (line ~120):

```ts
import { KvResizeBoardView } from "./KvResizeBoardView";
```

and, with the other `next/navigation` imports:

```ts
import { useSearchParams } from "next/navigation";
```

Inside the component, near the other view-mode state:

```ts
  // Step 3a scaffolding: draw the Resize tab through the unified Fabric engine
  // instead of the DOM rows. A dev-only URL switch on purpose — a PostHog flag
  // is force-ON in dev (so it could not toggle locally, which is the whole
  // point of comparing the two), and this dies with the DOM rows in step 4.
  const searchParams = useSearchParams();
  const resizeBoardView =
    process.env.NODE_ENV !== "production" &&
    searchParams.get("resizeCanvas") === "fabric";
```

Then wrap the existing mount (line ~4336) so the old path stays the default.

**Do not retype the `<KvResizeCanvas>` element.** Take the element that is
there today — all 18 props, from `fileId` through `onCommitProjectOverlays` —
and move it verbatim into the `:` branch, indented one level deeper. Nothing
about it changes. Dropping or "tidying" a prop here silently breaks the path
that is still the default for everyone.

```tsx
                {resizeBoardView ? (
                  <KvResizeBoardView
                    fileId={fileId}
                    source={viewedGeneration}
                    sourceVersionIds={sourceVersionIds}
                    kvDoc={kvDoc}
                    showRuler={showRuler}
                    gridOpacity={gridOpacity}
                    gridSize={gridSize}
                  />
                ) : (
                  <KvResizeCanvas
                    fileId={fileId}
                    /* …the remaining 17 props exactly as they appear on
                       develop today, moved verbatim, none added or removed… */
                  />
                )}
```

Verify afterwards with `git diff` that the only change to the
`<KvResizeCanvas>` element is its indentation.

- [ ] **Step 6: Verify**

```bash
cd web && bun test 2>&1 | tail -12
```

Expected: baseline counts plus the new passing tests; no new failures.

```bash
cd web && bunx tsc --noEmit 2>&1 | grep -E "KvResizeBoardView|KvGeneratorLayout" | head -20
```

Expected: nothing that is not already in `/tmp/kv3a-tsc-baseline.txt`.

```bash
cd web && bun run build 2>&1 | tail -15
```

Expected: build succeeds. If it fails on `useSearchParams` needing a Suspense boundary, wrap the mount in `<Suspense fallback={null}>` rather than reaching for a different flag mechanism.

- [ ] **Step 7: Commit**

```bash
cd web && git add src/components/studio/kv-generator/KvResizeBoardView.tsx src/components/studio/kv-generator/KvResizeBoardView.test.tsx src/components/studio/kv-generator/KvGeneratorLayout.tsx && git commit -m "feat(web): draw KV resize tiles as boards behind a dev switch"
```

---

## Task 7: Prove the gates in the database

**Files:** none (verification), then `docs/superpowers/HANDOFF-kv-canvas-unification.md` in the workspace repo.

This is the task 3a exists for. **It is a manual run by the author (Daffa) — an agent cannot do it.** Everything above is only evidence that the code is self-consistent; this is the evidence that the participation model holds against a real doc.

- [ ] **Step 1: Start the services**

From the workspace root: `./run-all.sh`. Expect `data-service` to fail (a known unrelated debt, owner kemal/iru). Health-check by process, not by curl:

```bash
lsof -nP -iTCP:3000 -sTCP:LISTEN
```

- [ ] **Step 2: Record Craft's persisted state BEFORE opening Resize**

Open a KV file that has resize exports, note its file id from the URL, then:

```bash
psql -h 127.0.0.1 -p 5432 -d frnd -tAc "select jsonb_pretty(metadata->'kv_canvas') from studio_files where id='<file-id>';" > /tmp/kv3a-before.json && cat /tmp/kv3a-before.json
```

- [ ] **Step 3: Open the new Resize view**

Append `?resizeCanvas=fabric` to the studio URL and switch to the Resize tab. Wait ~5 seconds — the materializer debounces 400ms, so anything it was going to write has been written.

Look at the screen and confirm, by eye:
- every tile appears as a board in one vertical column, master on top, in the same order as the old rows
- each tile shows its own image at its own aspect ratio
- no board can be dragged — neither by its image nor by its caption
- a tile that is still generating leaves a correctly-shaped empty slot

- [ ] **Step 4: The acceptance test**

```bash
psql -h 127.0.0.1 -p 5432 -d frnd -tAc "select jsonb_pretty(metadata->'kv_canvas') from studio_files where id='<file-id>';" > /tmp/kv3a-after.json && diff /tmp/kv3a-before.json /tmp/kv3a-after.json && echo "UNCHANGED — gates hold"
```

**Pass:** the diff is empty. **Fail, and stop:** any new key under `artboards`, especially one that is an export id rather than a generation id; or any change to an existing artboard's `x`/`y` (that would be Finding 1 arriving anyway — check `canSeedBoardMap` is really reached).

Also run it against a file whose Resize source is a **sketch** generation, which has no craft board map — that is the case Finding 1 says would have minted an artboard.

- [ ] **Step 5: Confirm Craft is untouched**

Switch back to Craft on a multi-board KV. This list is longer than the DoD's
because Task 5's retype reached four call sites beyond the nine the plan
enumerated — the rename input, the variant popover, the Delete-key handler and
the live-drag release effect all had to convert too. Every one of them is a
Craft interaction, and none is component-testable. Exercise each:

- board positions and captions render as before
- drag a board by its image; drop it; reload — the position persisted
- drag a board by its **caption** (a second, independent drag path)
- double-click a caption, rename the board, confirm the name sticks after reload
- right-click a board — the context menu opens with its usual actions
- select a board and press Delete
- the "+" create-variant affordance appears on the active board and opens
- on a Concept-mode file, the "Concept" badge and the creative-rationale card
  still render

Then re-run the Postgres query and diff again.

- [ ] **Step 6: Update the handoff**

In `docs/superpowers/HANDOFF-kv-canvas-unification.md` (workspace repo, not `web/`):
- move 3a from "Not started" to shipped, with the branch/PR
- record the manual verification result — this is the first browser verification the project has ever had, so say exactly what was looked at
- add Finding 2 (uniform tile width) to the outstanding-debts list, marked as **must be resolved before step 4 deletes the DOM rows**
- note that debt 3 (`docMoveBoard` / `docSetMasterBoard` ungated) is still open and that 3b/3c must keep not wiring them

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic && git add docs/superpowers/HANDOFF-kv-canvas-unification.md && git commit -m "docs: record step 3a and the two findings that shaped it"
```

---

## Self-review

**Spec coverage.** 3a's DoD, item by item:

| DoD item | Task |
|---|---|
| Resize tab renders every tile as a board in a vertical column, master on top, same order | 3, 6 |
| Each tile shows its own image at its own aspect ratio | 4 (`resizeSurfaceAspect`), 6 |
| `metadata.kv_canvas.artboards` gains no export-id entry — verified in Postgres | 7 step 4 (and asserted at the producer level in Task 4) |
| Craft's artboard centres unchanged after opening/closing Resize | 1, 2 (Finding 1 fix), 7 steps 4-5 |
| Boards cannot be dragged in the Resize view | 5 step 6 (both drag paths), 4 (`canPersistBoardPosition` as the third layer) |
| Pure test covers column layout: order, spacing, no dependence on persisted state | 3 |
| No new test failures vs. the develop baseline; `bun run build` clean | 0, 5 step 7, 6 step 6 |
| Craft untouched — multi-board KV still positions, captions and drag-persists | 5 (retype is like-for-like), 7 step 5 |

Also covered: the pure column-layout function, the `KvSurface` producer, the master row as a Craft board with `layout: "view"`, and the per-view draggability switch — all four "what it needs" bullets.

**Not covered, deliberately:** per-tile chrome and actions (3b), overlay editing and the two sinks (3c), deleting the old surfaces (4), proportional tile width (Finding 2 — named, deferred, and flagged as a step-4 blocker).

**Placeholders:** none. Every code step carries the code; every test step carries the assertions; every verification step carries the command and the expected result.

**Type consistency:** `KvSurface` fields used in Tasks 4-6 (`id`, `docBoardId`, `layout`, `imageUrl`, `fallbackAspect`, `label`, `isMaster`, `isActive`, `center`, `version_ids`) match the definition at `kvSurface.ts:27`. `resizeColumnCenters` is called in Task 6 with the `{ boardWidth }` shape Task 3 defines. `resolveBoardMap(doc, key, seed)`'s three arguments match Task 5's call. `BOARD_WORLD_WIDTH_PUBLIC` is exported in Task 5 step 1 and imported in Task 6. `buildResizeSurfaces(source, rows, opts)` has the same signature in its test and its implementation.
