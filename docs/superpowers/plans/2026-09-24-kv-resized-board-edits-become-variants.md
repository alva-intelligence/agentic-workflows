# KV — Edits on a Resized Board Become Variants — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a Craft board has resize tiles, any edit that would append a version to it lands as a new variant board (with copied layers) instead, and chat says so before the user sends.

**Architecture:** One pure decision module (`editOutcome.ts`) is consulted at the ONLY version-append site (the completion effect's `docRekeyBoardTip` branch in `KvGeneratorLayout.tsx`) and by the chat/canvas notice. The variant board and its copied layers are written in one Yjs transaction (`docAddVariantBoard`), so one Cmd+Z undoes both. The strip's published rows (`stripExports`) are the single source for "does this board have resizes".

**Tech Stack:** Next.js 16 / React 19 / TypeScript, Yjs, bun test.

**Spec:** `docs/superpowers/specs/2026-09-24-kv-resized-board-edits-become-variants-design.md` (workspace repo)

## Global Constraints

- Work in `web/` on branch `feature/daffa/vc-kv-craft-resize-strip`; commit per task; push to that branch. NO PR to develop. NEVER `git stash`.
- Never `bun test` a directory — pass explicit files (`bun test path/a.test.ts path/b.test.ts`).
- Gate per task: `bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -c "error TS"` ≤ the baseline recorded in Task 1 (tsc may only go down); `bunx eslint --fix <touched files>` with no NEW warnings (`KvGeneratorLayout.tsx` carries 13 old ones); explicit `bun test` files.
- `node ./node_modules/next/dist/bin/next build` at the end of Task 6 (`bun run build` is broken).
- No RTL/component tests for canvas or chat (track policy).
- zsh does not word-split `$VAR` file lists — pass paths explicitly.
- Notice copy, verbatim: `This board has resizes — the result will be added as a new variant.`
- Event name, verbatim: `kv_generator.edit_became_variant`.
- No api / ai-service change.

## Review Focus

1. **Board without resizes** — every edit must still rekey (version chain grows, master follows the tip). Pinned in Task 1 (`editBecomesVariant` false at 0 rows) and checked by reading Task 5's diff: the `"rekey"` arm is the old call, unchanged.
2. **Concept parent with resizes** — must still FORK (concept keeps its key); never become a variant. Pinned in Task 1 (`parentIsConcept` wins).
3. **Older version targeted** (chat base is a chain member, not a board key) — not a version append, so no notice. Pinned in Task 1 (`isBoardTip: false` → false).
4. **Parent layers after redirect** — the parent's overlays must be untouched and the copies must share no id with them; legacy null-bound overlays not copied. Pinned in Task 2 and Task 3.
5. **Undo** — one Cmd+Z removes the variant board AND its copied layers, and leaves the parent intact. Pinned in Task 3.

---

## File Structure

| File | Responsibility |
|---|---|
| `web/src/lib/studio/kv/editOutcome.ts` (new) | Pure: `EditOutcome`, `editOutcome`, `editBecomesVariant`, `boardResizeCount`, `RESIZED_EDIT_NOTICE` |
| `web/src/lib/studio/kv/editOutcome.test.ts` (new) | Tests for the above |
| `web/src/lib/studio/kv/overlayMutations.ts` | + `overlaysForVariant` (pure copy of a board's layers) |
| `web/src/lib/studio/kv/overlaysForVariant.test.ts` (new) | Tests (own file — `overlayMutations.test.ts` is already 24 KB, bun's ~51 KB cliff) |
| `web/src/lib/kv/yjsSerializer.ts` | + `docAddVariantBoard` (board + layers, one transaction) |
| `web/src/lib/kv/docAddVariantBoard.test.ts` (new) | Tests incl. single-step undo |
| `web/src/lib/analytics/kv-generator-events.ts` | + `trackKvEditBecameVariant` |
| `web/src/lib/analytics/kv-generator-events.editBecameVariant.test.ts` (new) | Event name + props |
| `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx` | Redirect in completion effect; `editTargetHasResizes` prop; toasts for Angles / Craft pill |
| `web/src/components/studio/kv-generator/KvChat.tsx` | `editTargetHasResizes` prop → notice line in composer, ModeSuggestion, GenerateBar row, QuestionCard (Craft) |
| `web/docs/tracks/kv-craft-resize-strip.track.md` | Task rows + session log + taxonomy row pending |

---

### Task 1: Pure decision module

**Files:**
- Create: `web/src/lib/studio/kv/editOutcome.ts`
- Test: `web/src/lib/studio/kv/editOutcome.test.ts`

**Interfaces:**
- Produces:
  - `type EditOutcome = "rekey" | "fork" | "variant"`
  - `editOutcome(args: { parentIsConcept: boolean; parentResizeCount: number }): EditOutcome`
  - `editBecomesVariant(args: { isBoardTip: boolean; parentIsConcept: boolean; parentResizeCount: number }): boolean`
  - `boardResizeCount(rows: readonly { parentGenerationId: string }[], tipId: string | null | undefined): number`
  - `RESIZED_EDIT_NOTICE: string`

- [ ] **Step 0: Record the tsc baseline**

Run (in `web/`): `bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -c "error TS"`
Expected: a number ≤ 999. Write it to the ledger as `Baseline tsc: <N>`; every later gate compares against it.

- [ ] **Step 1: Write the failing test**

```ts
import { describe, expect, it } from "bun:test";
import {
  RESIZED_EDIT_NOTICE,
  boardResizeCount,
  editBecomesVariant,
  editOutcome,
} from "./editOutcome";

describe("editOutcome", () => {
  it("forks a concept parent even when it has resizes", () => {
    expect(editOutcome({ parentIsConcept: true, parentResizeCount: 3 })).toBe(
      "fork"
    );
    expect(editOutcome({ parentIsConcept: true, parentResizeCount: 0 })).toBe(
      "fork"
    );
  });

  it("rekeys a craft parent with no resizes", () => {
    expect(editOutcome({ parentIsConcept: false, parentResizeCount: 0 })).toBe(
      "rekey"
    );
  });

  it("makes a variant for a craft parent with at least one resize", () => {
    expect(editOutcome({ parentIsConcept: false, parentResizeCount: 1 })).toBe(
      "variant"
    );
    expect(editOutcome({ parentIsConcept: false, parentResizeCount: 7 })).toBe(
      "variant"
    );
  });
});

describe("editBecomesVariant", () => {
  it("is true only for a craft board tip with resizes", () => {
    expect(
      editBecomesVariant({
        isBoardTip: true,
        parentIsConcept: false,
        parentResizeCount: 2,
      })
    ).toBe(true);
  });

  it("is false when the target is not a board tip (an older version)", () => {
    expect(
      editBecomesVariant({
        isBoardTip: false,
        parentIsConcept: false,
        parentResizeCount: 2,
      })
    ).toBe(false);
  });

  it("is false for a concept tip and for a tip without resizes", () => {
    expect(
      editBecomesVariant({
        isBoardTip: true,
        parentIsConcept: true,
        parentResizeCount: 2,
      })
    ).toBe(false);
    expect(
      editBecomesVariant({
        isBoardTip: true,
        parentIsConcept: false,
        parentResizeCount: 0,
      })
    ).toBe(false);
  });
});

describe("boardResizeCount", () => {
  const rows = [
    { parentGenerationId: "gen_a" },
    { parentGenerationId: "gen_b" },
    { parentGenerationId: "gen_a" },
  ];

  it("counts only the rows under the given tip", () => {
    expect(boardResizeCount(rows, "gen_a")).toBe(2);
    expect(boardResizeCount(rows, "gen_b")).toBe(1);
    expect(boardResizeCount(rows, "gen_c")).toBe(0);
  });

  it("is 0 for no tip or no rows", () => {
    expect(boardResizeCount(rows, null)).toBe(0);
    expect(boardResizeCount(rows, undefined)).toBe(0);
    expect(boardResizeCount([], "gen_a")).toBe(0);
  });
});

describe("RESIZED_EDIT_NOTICE", () => {
  it("is the agreed copy", () => {
    expect(RESIZED_EDIT_NOTICE).toBe(
      "This board has resizes — the result will be added as a new variant."
    );
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/lib/studio/kv/editOutcome.test.ts`
Expected: FAIL — cannot resolve `./editOutcome`.

- [ ] **Step 3: Write minimal implementation**

```ts
/**
 * Version vs. variant for a completed Craft edit (spec 2026-09-24
 * "edits on a resized board become variants").
 *
 * A board's resize tiles hang off its TIP generation. Appending a version
 * (rekey) moves the tip and orphans every tile, so a board that has resizes
 * gets the edit as a NEW variant board instead. A concept parent keeps its
 * key on the fork path anyway, so it never needs the redirect.
 */
export type EditOutcome = "rekey" | "fork" | "variant";

export const RESIZED_EDIT_NOTICE =
  "This board has resizes — the result will be added as a new variant.";

export function editOutcome(args: {
  parentIsConcept: boolean;
  parentResizeCount: number;
}): EditOutcome {
  if (args.parentIsConcept) return "fork";
  return args.parentResizeCount > 0 ? "variant" : "rekey";
}

/** Whether an edit aimed at `target` will land as a variant — for the
 *  pre-send notice. Only a board TIP is ever rekeyed; an older version in a
 *  chain takes the plain-completion path, so it gets no notice. */
export function editBecomesVariant(args: {
  isBoardTip: boolean;
  parentIsConcept: boolean;
  parentResizeCount: number;
}): boolean {
  return (
    args.isBoardTip &&
    editOutcome({
      parentIsConcept: args.parentIsConcept,
      parentResizeCount: args.parentResizeCount,
    }) === "variant"
  );
}

/** Strip rows hanging off `tipId`. Rows not loaded yet count as none — the
 *  strip draws nothing for them either. */
export function boardResizeCount(
  rows: readonly { parentGenerationId: string }[],
  tipId: string | null | undefined
): number {
  if (!tipId) return 0;
  let n = 0;
  for (const r of rows) if (r.parentGenerationId === tipId) n++;
  return n;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test src/lib/studio/kv/editOutcome.test.ts`
Expected: PASS, 9 tests.

- [ ] **Step 5: Gates + commit**

Run: `bunx eslint --fix src/lib/studio/kv/editOutcome.ts src/lib/studio/kv/editOutcome.test.ts` → no warnings. tsc count ≤ baseline.

```bash
git add src/lib/studio/kv/editOutcome.ts src/lib/studio/kv/editOutcome.test.ts
git commit -m "feat(web): editOutcome — resized boards take edits as variants"
```

---

### Task 2: Copy a board's layers for a variant

**Files:**
- Modify: `web/src/lib/studio/kv/overlayMutations.ts` (append after `overlaysForTile`, ≈line 293)
- Test: `web/src/lib/studio/kv/overlaysForVariant.test.ts`

**Interfaces:**
- Consumes: `overlaysForTile(overlays, versionIds)` (existing, same file)
- Produces:
  - `type VariantOverlaySource = Pick<StudioOverlay, "id" | "type" | "x" | "y" | "width" | "height" | "rotation" | "z" | "payload" | "board_generation_id">`
  - `overlaysForVariant(overlays: readonly VariantOverlaySource[], parentChain: ReadonlySet<string>, variantId: string, mintId: () => string): Omit<VariantOverlaySource, "z">[]` — sorted by source z ascending, z omitted (the doc assigns fresh z in that order).

- [ ] **Step 1: Write the failing test**

```ts
import { describe, expect, it } from "bun:test";
import {
  overlaysForVariant,
  type VariantOverlaySource,
} from "./overlayMutations";

function ov(o: Partial<VariantOverlaySource> & { id: string }): VariantOverlaySource {
  return {
    type: "text",
    x: 0.1,
    y: 0.2,
    width: 0.3,
    height: 0.4,
    rotation: 5,
    z: 1,
    board_generation_id: "gen_v1",
    payload: { type: "text", content: "Hello", color: "#ffffff" },
    ...o,
  } as VariantOverlaySource;
}

function minter() {
  let i = 0;
  return () => `tmp_copy_${++i}`;
}

describe("overlaysForVariant", () => {
  const chain = new Set(["gen_v1", "gen_v2"]);

  it("copies only layers bound to the parent's chain, rebound to the variant", () => {
    const out = overlaysForVariant(
      [
        ov({ id: "a", board_generation_id: "gen_v1" }),
        ov({ id: "b", board_generation_id: "gen_v2" }),
        ov({ id: "c", board_generation_id: "gen_other" }),
        ov({ id: "d", board_generation_id: null }),
      ],
      chain,
      "gen_new",
      minter()
    );
    expect(out).toHaveLength(2);
    expect(out.every((o) => o.board_generation_id === "gen_new")).toBe(true);
  });

  it("mints fresh ids — no id is shared with the source", () => {
    const src = [ov({ id: "a" }), ov({ id: "b", z: 2 })];
    const out = overlaysForVariant(src, chain, "gen_new", minter());
    expect(out.map((o) => o.id)).toEqual(["tmp_copy_1", "tmp_copy_2"]);
    const srcIds = new Set(src.map((o) => o.id));
    expect(out.some((o) => srcIds.has(o.id))).toBe(false);
  });

  it("keeps geometry, rotation, type and payload verbatim and drops z", () => {
    const src = ov({
      id: "a",
      type: "image",
      x: 0.5,
      y: 0.6,
      width: 0.25,
      height: 0.125,
      rotation: 33,
      payload: { type: "image", src: "https://cdn.example/logo.png" },
    } as Partial<VariantOverlaySource> & { id: string });
    const [copy] = overlaysForVariant([src], chain, "gen_new", minter());
    expect(copy).toEqual({
      id: "tmp_copy_1",
      type: "image",
      x: 0.5,
      y: 0.6,
      width: 0.25,
      height: 0.125,
      rotation: 33,
      board_generation_id: "gen_new",
      payload: { type: "image", src: "https://cdn.example/logo.png" },
    });
    expect("z" in copy).toBe(false);
  });

  it("orders copies by the source z so the layer stack is preserved", () => {
    const out = overlaysForVariant(
      [ov({ id: "top", z: 9 }), ov({ id: "bottom", z: 1 }), ov({ id: "mid", z: 4 })],
      chain,
      "gen_new",
      minter()
    );
    // Minted in sorted order: bottom → mid → top.
    expect(out.map((o) => o.id)).toEqual(["tmp_copy_1", "tmp_copy_2", "tmp_copy_3"]);
    expect(out.map((o) => o.rotation)).toEqual([5, 5, 5]);
  });

  it("does not mutate the source payload object", () => {
    const src = ov({ id: "a" });
    const [copy] = overlaysForVariant([src], chain, "gen_new", minter());
    expect(copy.payload).not.toBe(src.payload);
    expect(copy.payload).toEqual(src.payload);
  });

  it("returns [] when nothing belongs to the parent", () => {
    expect(overlaysForVariant([], chain, "gen_new", minter())).toEqual([]);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/lib/studio/kv/overlaysForVariant.test.ts`
Expected: FAIL — `overlaysForVariant` is not exported.

- [ ] **Step 3: Write minimal implementation** (append after `overlaysForTile`)

```ts
/** The overlay fields a variant copy carries — the doc's overlay shape. */
export type VariantOverlaySource = Pick<
  StudioOverlay,
  | "id"
  | "type"
  | "x"
  | "y"
  | "width"
  | "height"
  | "rotation"
  | "z"
  | "payload"
  | "board_generation_id"
>;

/**
 * Copies of a board's layers for a new variant board (spec 2026-09-24): the
 * layers `overlaysForTile` would render on the parent, each with a fresh id
 * and bound to `variantId`, so editing one board never moves the other's.
 * Returned bottom→top with `z` omitted — the doc write assigns fresh z in
 * this order, keeping the stack without colliding with the parent's values.
 * Geometry is copied as-is: a craft edit keeps the base's aspect.
 */
export function overlaysForVariant(
  overlays: readonly VariantOverlaySource[],
  parentChain: ReadonlySet<string>,
  variantId: string,
  mintId: () => string
): Omit<VariantOverlaySource, "z">[] {
  return overlaysForTile(overlays as StudioOverlay[], parentChain as Set<string>)
    .slice()
    .sort((a, b) => a.z - b.z)
    .map((o) => ({
      id: mintId(),
      type: o.type,
      x: o.x,
      y: o.y,
      width: o.width,
      height: o.height,
      rotation: o.rotation,
      board_generation_id: variantId,
      payload: structuredClone(o.payload),
    }));
}
```

Note: the "orders copies by source z" test asserts the mint ORDER; if it passes before sorting is added, the test is vacuous — Step 2 must fail first on the missing export, then after Step 3 temporarily delete `.sort(...)`, re-run, and confirm that test fails (mutation check), then restore.

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test src/lib/studio/kv/overlaysForVariant.test.ts src/lib/studio/kv/overlayMutations.test.ts`
Expected: PASS (6 new; `overlayMutations.test.ts` unchanged count).

- [ ] **Step 5: Gates + commit**

eslint on the two files, tsc ≤ baseline.

```bash
git add src/lib/studio/kv/overlayMutations.ts src/lib/studio/kv/overlaysForVariant.test.ts
git commit -m "feat(web): overlaysForVariant — copy a board's layers onto a new variant"
```

---

### Task 3: One-transaction variant write

**Files:**
- Modify: `web/src/lib/kv/yjsSerializer.ts` (after `docAddBoardFromState`, ≈line 355)
- Test: `web/src/lib/kv/docAddVariantBoard.test.ts`

**Interfaces:**
- Consumes: `docAddBoardFromState(doc, next, newBoardId)`, `docAddOverlays(doc, overlays)` (existing); `overlaysForVariant` output shape from Task 2.
- Produces: `docAddVariantBoard(doc: KvYDoc, next: KvCanvasState, newBoardId: string, overlays: readonly (Omit<KvOverlaySeed, "z"> & { z?: number })[]): void`

- [ ] **Step 1: Write the failing test**

```ts
import { describe, expect, it } from "bun:test";
import type { KvCanvasState } from "@/types/studio";
import { CANVAS_SCHEMA_VERSION } from "@/components/studio/kv-generator/boardLayout";
import { createDocUndoHandle } from "./docUndo";
import { createKvDoc } from "./yjsDoc";
import {
  docAddOverlay,
  docAddVariantBoard,
  kvDocToCanvasState,
  kvOverlaysFromDoc,
  seedKvDocFromCanvasState,
  type KvOverlaySeed,
} from "./yjsSerializer";

function baseState(): KvCanvasState {
  return {
    schema_version: CANVAS_SCHEMA_VERSION,
    master_generation_id: "gen_parent",
    artboards: {
      gen_parent: {
        x: 0,
        y: 0,
        name: "Hero",
        version_ids: ["gen_v1", "gen_parent"],
      },
    },
  } as KvCanvasState;
}

function withVariant(): KvCanvasState {
  const s = baseState();
  s.artboards.gen_new = { x: 640, y: 0, name: "Variant 1", version_ids: ["gen_new"] };
  return s;
}

function layer(overrides: Partial<KvOverlaySeed> = {}): KvOverlaySeed {
  return {
    id: "ov_parent",
    type: "text",
    x: 0.1,
    y: 0.2,
    width: 0.3,
    height: 0.4,
    rotation: 0,
    z: 1,
    board_generation_id: "gen_parent",
    payload: { type: "text", content: "Sale", color: "#ffffff" },
    ...overrides,
  };
}

function setup() {
  const doc = createKvDoc();
  seedKvDocFromCanvasState(doc, baseState());
  docAddOverlay(doc, layer());
  return doc;
}

const copy = { ...layer({ id: "tmp_copy_1", board_generation_id: "gen_new" }) };
delete (copy as Partial<KvOverlaySeed>).z;

describe("docAddVariantBoard", () => {
  it("adds the variant board and its copied layers", () => {
    const doc = setup();
    docAddVariantBoard(doc, withVariant(), "gen_new", [copy]);
    const state = kvDocToCanvasState(doc);
    expect(state.artboards.gen_new?.version_ids).toEqual(["gen_new"]);
    expect(state.artboards.gen_new?.name).toBe("Variant 1");
    const ids = kvOverlaysFromDoc(doc).map((o) => o.id).sort();
    expect(ids).toEqual(["ov_parent", "tmp_copy_1"]);
  });

  it("leaves the parent board, its layers and master untouched", () => {
    const doc = setup();
    docAddVariantBoard(doc, withVariant(), "gen_new", [copy]);
    const state = kvDocToCanvasState(doc);
    expect(state.artboards.gen_parent).toEqual(baseState().artboards.gen_parent);
    expect(state.master_generation_id).toBe("gen_parent");
    const parentLayer = kvOverlaysFromDoc(doc).find((o) => o.id === "ov_parent");
    expect(parentLayer?.board_generation_id).toBe("gen_parent");
    expect(parentLayer?.z).toBe(1);
  });

  it("gives the copies z values above every existing layer", () => {
    const doc = setup();
    docAddVariantBoard(doc, withVariant(), "gen_new", [copy]);
    const c = kvOverlaysFromDoc(doc).find((o) => o.id === "tmp_copy_1");
    expect(c!.z).toBeGreaterThan(1);
  });

  it("is ONE undo step: undo removes the board and the copies together", () => {
    const doc = setup();
    const handle = createDocUndoHandle(doc);
    docAddVariantBoard(doc, withVariant(), "gen_new", [copy]);
    handle.undo();
    const state = kvDocToCanvasState(doc);
    expect(state.artboards.gen_new).toBeUndefined();
    expect(kvOverlaysFromDoc(doc).map((o) => o.id)).toEqual(["ov_parent"]);
    expect(handle.canUndo()).toBe(false);
    handle.destroy();
  });

  it("adds the board even with no layers to copy", () => {
    const doc = setup();
    docAddVariantBoard(doc, withVariant(), "gen_new", []);
    expect(kvDocToCanvasState(doc).artboards.gen_new).toBeDefined();
  });
});
```

Before running, check `seedKvDocFromCanvasState`'s real signature in `yjsSerializer.ts` (`grep -n "export function seedKvDocFromCanvasState" -A6`) and adjust the `setup()` call to it; ledger a Ruling if it differs. The undo test needs the seed to happen BEFORE `createDocUndoHandle` (as written) so the seed is not on the undo stack.

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/lib/kv/docAddVariantBoard.test.ts`
Expected: FAIL — `docAddVariantBoard` is not exported.

- [ ] **Step 3: Write minimal implementation** (after `docAddBoardFromState`)

```ts
/**
 * Add a variant board AND its copied layers in ONE transaction (spec
 * 2026-09-24, edits on a resized board): the undo manager groups by
 * transaction, so one Cmd+Z removes the variant with its layers instead of
 * leaving orphaned copies behind. The inner writers' own `transact` calls
 * join this outer one. The parent board is never touched and master is not
 * moved (`next` carries the unchanged master).
 */
export function docAddVariantBoard(
  doc: KvYDoc,
  next: KvCanvasState,
  newBoardId: string,
  overlays: readonly (Omit<KvOverlaySeed, "z"> & { z?: number })[]
): void {
  doc.doc.transact(() => {
    docAddBoardFromState(doc, next, newBoardId);
    docAddOverlays(doc, overlays);
  }, YDOC_ORIGIN_LOCAL);
}
```

`docAddOverlays` is declared later in the file as a `function` declaration, so it is hoisted — no reordering needed.

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test src/lib/kv/docAddVariantBoard.test.ts src/lib/kv/yjsSerializer.test.ts src/lib/kv/docUndo.test.ts`
Expected: PASS (5 new, existing unchanged). Mutation check: temporarily replace the outer `doc.doc.transact(() => {...}, YDOC_ORIGIN_LOCAL)` with the two bare calls and confirm the undo test fails OR passes only because of the UndoManager capture timeout; if it still passes, add `handle` creation with `captureTimeout: 0` is not available through `createDocUndoHandle` — in that case assert instead that exactly ONE `afterTransaction` fires (`let n = 0; doc.doc.on("afterTransaction", () => n++)` before the call, `expect(n).toBe(1)` after) and ledger the Ruling. Restore the transaction.

- [ ] **Step 5: Gates + commit**

```bash
git add src/lib/kv/yjsSerializer.ts src/lib/kv/docAddVariantBoard.test.ts
git commit -m "feat(web): docAddVariantBoard — variant board + copied layers in one undo step"
```

---

### Task 4: Analytics event

**Files:**
- Modify: `web/src/lib/analytics/kv-generator-events.ts` (after `trackKvChatToggled`, ≈line 2160)
- Test: `web/src/lib/analytics/kv-generator-events.editBecameVariant.test.ts`

**Interfaces:**
- Produces: `interface KvEditBecameVariantProps { file_id: string; parent_generation_id: string; generation_id: string; resize_count: number; copied_layer_count: number }`, `trackKvEditBecameVariant(p: KvEditBecameVariantProps): void`

- [ ] **Step 1: Write the failing test** (same prototype-preserving mock as `kv-generator-events.bumpers.test.ts` — a factory returning only `default` breaks other suites)

```ts
import { describe, expect, it, mock } from "bun:test";

const capture = mock(() => {});

const actualPosthog = await import("posthog-js");
const mockedDefault = Object.assign(
  Object.create(Object.getPrototypeOf(actualPosthog.default)),
  actualPosthog.default,
  { capture }
);

mock.module("posthog-js", () => ({
  ...actualPosthog,
  default: mockedDefault,
}));

const { trackKvEditBecameVariant } = await import("./kv-generator-events");

describe("edit_became_variant", () => {
  it("captures the event with its props", () => {
    trackKvEditBecameVariant({
      file_id: "file_1",
      parent_generation_id: "gen_parent",
      generation_id: "gen_new",
      resize_count: 3,
      copied_layer_count: 2,
    });
    expect(capture).toHaveBeenCalledWith(
      "kv_generator.edit_became_variant",
      expect.objectContaining({
        file_id: "file_1",
        parent_generation_id: "gen_parent",
        generation_id: "gen_new",
        resize_count: 3,
        copied_layer_count: 2,
      })
    );
  });
});
```

Before relying on `toHaveBeenCalledWith(name, objectContaining)`, open `kv-generator-events.bumpers.test.ts` and match how IT asserts the captured call (safeCapture may add props); copy that assertion shape.

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/lib/analytics/kv-generator-events.editBecameVariant.test.ts`
Expected: FAIL — `trackKvEditBecameVariant` is not a function.

- [ ] **Step 3: Implement**

```ts
export interface KvEditBecameVariantProps {
  file_id: string;
  /** The board tip the edit targeted — it keeps its version chain. */
  parent_generation_id: string;
  /** The new variant board's generation. */
  generation_id: string;
  /** Resize tiles under the parent that forced the redirect. */
  resize_count: number;
  /** Layers copied from the parent onto the variant. */
  copied_layer_count: number;
}

/** A Craft edit on a board with resizes landed as a new variant board
 *  instead of a new version (spec 2026-09-24). */
export const trackKvEditBecameVariant = (p: KvEditBecameVariantProps) =>
  safeCapture("kv_generator.edit_became_variant", p);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test src/lib/analytics/kv-generator-events.editBecameVariant.test.ts src/lib/analytics/kv-generator-events.bumpers.test.ts`
Expected: PASS both (the bumpers suite proves the mock did not leak).

- [ ] **Step 5: Gates + commit**

```bash
git add src/lib/analytics/kv-generator-events.ts src/lib/analytics/kv-generator-events.editBecameVariant.test.ts
git commit -m "feat(web): kv_generator.edit_became_variant event"
```

---

### Task 5: Redirect at the completion effect

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx`
  - imports (≈line 20-37 yjsSerializer block; add `docAddVariantBoard`)
  - near `stripExports` state (≈2690): add a ref mirror
  - completion effect Branch 2 (≈1941-1966)

**Interfaces:**
- Consumes: `editOutcome`, `boardResizeCount` (Task 1); `overlaysForVariant` (Task 2); `docAddVariantBoard` (Task 3); `trackKvEditBecameVariant` (Task 4); existing `computeBoardLayout`, `adjacentFreeCenter`, `nextFreeCenter`, `canvasStateWithNewVariant`, `deriveVariantName` (boardLayout), `newTileOverlayId` (`@/lib/studio/kv/useTileOverlayEditing`), `kvOverlaysFromDoc`.

No unit test (canvas/effect — track policy); the logic it calls is covered by Tasks 1–3. Verified by tsc/eslint and Daffa's manual run.

- [ ] **Step 1: Ref mirror for strip rows**

The completion effect is declared at ≈1826, BEFORE `stripExports` (≈2690). Declare the ref near the other completion refs (next to `pendingVariantRef`), and sync it right after the `stripExports` state:

```ts
// near pendingVariantRef:
/** Latest strip rows for the completion effect — read through a ref so a
 *  strip refresh never re-runs the effect (spec 2026-09-24). */
const stripExportsRef = useRef<KvResizeExport[]>([]);
```

```ts
// right after: const [stripExports, setStripExports] = useState<KvResizeExport[]>([]);
stripExportsRef.current = stripExports;
```

- [ ] **Step 2: Replace the fork/rekey choice**

Replace the block from `const parentGen = stream.generations.find((g) => g.id === parentId);` through the closing `}` of `else { docRekeyBoardTip(...) }` with:

```ts
    const parentGen = stream.generations.find((g) => g.id === parentId);
    const parentIsConcept = (parentGen?.mode ?? "sketch") !== "craft";
    const parentResizeCount = boardResizeCount(
      stripExportsRef.current,
      parentId
    );
    const outcome = editOutcome({ parentIsConcept, parentResizeCount });
    if (outcome === "fork") {
      const boards = computeBoardLayout(stream.generations, current);
      const nextState = canvasStateWithForkedCraft(
        boards,
        current,
        parentId,
        top.id
      );
      docAddBoardFromState(kvDoc, nextState, top.id);
      // The design landed — the concept preview's job is done. Dropping the id
      // removes the badged sketch from the Craft set; the fork (same center)
      // takes its place, i.e. the concept visibly became the design.
      setPromotedConceptId((prev) => (prev === parentId ? null : prev));
    } else if (outcome === "variant") {
      // The parent has resize tiles, which hang off its TIP: a rekey would
      // orphan every one of them. Land the edit as a NEW variant beside it
      // with a copy of its layers; the parent (tip, chain, master, layers)
      // stays exactly as it was (spec 2026-09-24).
      const boards = computeBoardLayout(stream.generations, current, {
        modeFilter: "craft",
      });
      const parentBoard = boards.find((b) => b.id === parentId);
      const center = parentBoard
        ? adjacentFreeCenter(boards, parentBoard)
        : nextFreeCenter(boards);
      const priorVariants = boards.filter((b) => !b.isMaster).length;
      const nextState = canvasStateWithNewVariant(
        computeBoardLayout(stream.generations, current),
        current,
        top.id,
        center,
        { name: deriveVariantName("", priorVariants + 1) }
      );
      const chain = new Set(
        current.artboards[parentId]?.version_ids?.length
          ? current.artboards[parentId].version_ids
          : [parentId]
      );
      const copies = overlaysForVariant(
        kvOverlaysFromDoc(kvDoc),
        chain,
        top.id,
        newTileOverlayId
      );
      docAddVariantBoard(kvDoc, nextState, top.id, copies);
      trackKvEditBecameVariant({
        file_id: fileId,
        parent_generation_id: parentId,
        generation_id: top.id,
        resize_count: parentResizeCount,
        copied_layer_count: copies.length,
      });
    } else {
      docRekeyBoardTip(kvDoc, parentId, top.id);
    }
    setViewingGenerationId(top.id);
```

Notes for the implementer:
- `canvasStateWithNewVariant` serializes the boards it is given; pass the FULL layout (no mode filter) so no artboard is dropped — the filtered `boards` is only for placement (same split `handleCreateVariant` makes).
- `version_ids` may be typed `string[] | null | undefined`; keep the length-checked fallback (a persisted empty chain must fall back to `[parentId]`, same rule as `docRekeyBoardTip`).
- `fileId` is the layout's file id in scope; if the effect's deps lint asks for it, add `fileId` to the deps array (it is stable per file).
- Imports: `editOutcome, boardResizeCount` from `@/lib/studio/kv/editOutcome`; `overlaysForVariant` from `@/lib/studio/kv/overlayMutations` (merge with an existing import if one exists); `newTileOverlayId` from `@/lib/studio/kv/useTileOverlayEditing`; `docAddVariantBoard` in the yjsSerializer import block; `trackKvEditBecameVariant` in the kv-generator-events import; `deriveVariantName`, `adjacentFreeCenter`, `nextFreeCenter`, `canvasStateWithNewVariant` are already imported (verify with grep; add if not); `KvResizeExport` is already imported for `stripExports`.
- Update the comment above the old block (it says subsequent craft develops rekey) to mention the resized-board exception.

- [ ] **Step 3: Gates**

Run: `bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -c "error TS"` → ≤ baseline.
Run: `bunx eslint --fix src/components/studio/kv-generator/KvGeneratorLayout.tsx` → 13 warnings (no new ones).
Run: `bun test src/lib/studio/kv/editOutcome.test.ts src/lib/studio/kv/overlaysForVariant.test.ts src/lib/kv/docAddVariantBoard.test.ts` → PASS.

- [ ] **Step 4: Commit**

```bash
git add src/components/studio/kv-generator/KvGeneratorLayout.tsx
git commit -m "feat(web): edits on a board with resizes land as a new variant with copied layers"
```

---

### Task 6: The notice — chat and canvas triggers

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvChat.tsx`
  - `KvChat` props type (≈line 120-135) + destructure (≈227-240) + pass-through to `MessagesList` (≈517) and `ChatInputBar` (≈600)
  - `MessagesList` props (≈832-855); QuestionCard site (≈1108-1225); ModeSuggestion site (≈1228-1310); GenerateBar row (≈1564-1596)
  - `ChatInputBar` props (≈2065-2130); composer, right after the "Editing {board}" chip block (≈2731-2770)
- Modify: `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx` — compute the prop at the `<KvChat` site (≈7679); toasts in `handleStartCrafting` (≈4497) and `handleGenerateAngleNow` (≈4521)

**Interfaces:**
- Consumes: `editBecomesVariant`, `boardResizeCount`, `RESIZED_EDIT_NOTICE` (Task 1)
- Produces: `KvChat` prop `editTargetHasResizes?: boolean` (default `false`)

No component test (track policy). Verified by tsc/eslint/build and Daffa's manual run.

- [ ] **Step 1: One notice element in KvChat**

Add near `GenerateBar` (module scope in KvChat.tsx):

```tsx
/** Pre-send notice that this edit will land as a new variant because the
 *  target board has resize tiles (spec 2026-09-24). Same copy everywhere. */
function ResizedEditNotice({ className = "" }: { className?: string }) {
  return (
    <p
      className={`font-geist text-textXsRegular leading-[1.4] tracking-[-0.12px] text-text-inverse-subtle ${className}`}
    >
      {RESIZED_EDIT_NOTICE}
    </p>
  );
}
```

Import `RESIZED_EDIT_NOTICE` from `@/lib/studio/kv/editOutcome`.

- [ ] **Step 2: Thread the prop**

- `KvChat` props type: add
  ```ts
  /** True when a Craft edit sent now will land as a NEW variant because the
   *  target board has resize tiles — shows RESIZED_EDIT_NOTICE before send. */
  editTargetHasResizes?: boolean;
  ```
  Destructure `editTargetHasResizes = false`; pass `editTargetHasResizes={editTargetHasResizes}` to `<MessagesList` and `<ChatInputBar`.
- `MessagesList` and `ChatInputBar`: add `editTargetHasResizes?: boolean` to their prop types and `editTargetHasResizes = false` to their destructures.

- [ ] **Step 3: Render the notice**

- **Composer** (ChatInputBar), directly after the closing `)}` of the "Editing {board}" chip block, before `<div className="px-4 py-3">`:
  ```tsx
  {!isResizeMode && editTargetHasResizes && (
    <ResizedEditNotice className="px-4 pt-2" />
  )}
  ```
  It renders whether or not the chip does — an unpinned Craft edit still targets the latest board.
- **ModeSuggestion**: add prop `notice?: boolean`; inside, after the estimate `<p>`:
  ```tsx
  {isGenerate && notice && <ResizedEditNotice />}
  ```
  At the call site pass `notice={canvasMode === "craft" && editTargetHasResizes}`.
- **GenerateBar row**: after the `<div className="flex flex-wrap items-center gap-2">…</div>` that holds Keep brainstorming + GenerateBar:
  ```tsx
  {canvasMode === "craft" && editTargetHasResizes && <ResizedEditNotice />}
  ```
- **QuestionCard (Craft)**: after `<QuestionCard … />` inside its wrapper div:
  ```tsx
  {canvasMode === "craft" && editTargetHasResizes && (
    <ResizedEditNotice className="pt-2" />
  )}
  ```

- [ ] **Step 4: Compute the prop in the layout**

Above the JSX return (near `editingBoardLabel`, ≈3360):

```ts
// Spec 2026-09-24: warn BEFORE send when a Craft edit on the chat's target
// board will land as a new variant (the board has resize tiles).
const chatEditTargetId = viewedGeneration?.id ?? latestGenerationId ?? null;
const editTargetHasResizes =
  canvasMode === "craft" &&
  editBecomesVariant({
    isBoardTip: Boolean(
      chatEditTargetId && docCanvasState?.artboards?.[chatEditTargetId]
    ),
    parentIsConcept:
      (stream.generations.find((g) => g.id === chatEditTargetId)?.mode ??
        "sketch") !== "craft",
    parentResizeCount: boardResizeCount(stripExports, chatEditTargetId),
  });
```

At `<KvChat`: `editTargetHasResizes={editTargetHasResizes}`.

(Check `latestGenerationId`'s type with grep; if it is `string | undefined`, the `?? null` already normalises it.)

- [ ] **Step 5: Canvas-only triggers — toast**

A small helper inside the layout component, after `stripExportsRef` exists:

```ts
/** Toast the variant notice when a canvas-fired Craft edit (Angles, the
 *  Craft pill) targets a board with resizes — they bypass the chat. */
const noticeIfEditBecomesVariant = useCallback(
  (targetId: string) => {
    const current = kvDocStateNow();
    const becomesVariant = editBecomesVariant({
      isBoardTip: Boolean(current?.artboards?.[targetId]),
      parentIsConcept:
        (stream.generations.find((g) => g.id === targetId)?.mode ??
          "sketch") !== "craft",
      parentResizeCount: boardResizeCount(stripExportsRef.current, targetId),
    });
    if (becomesVariant) setTransientNotice(RESIZED_EDIT_NOTICE);
  },
  [kvDocStateNow, stream.generations]
);
```

Declare it AFTER `setTransientNotice` (≈4060) and BEFORE `handleStartCrafting` (≈4497). Call it:
- in `handleStartCrafting`, right before `void stream.send("", …)`: `noticeIfEditBecomesVariant(latest.id);` and add it to the deps.
- in `handleGenerateAngleNow`, right before `void stream.send("", …)`: `if (canvasMode === "craft") noticeIfEditBecomesVariant(generationId);` and add it to the deps.

- [ ] **Step 6: Gates + build**

Run tsc (≤ baseline); `bunx eslint --fix src/components/studio/kv-generator/KvChat.tsx src/components/studio/kv-generator/KvGeneratorLayout.tsx` (Layout stays at 13, KvChat no new);
Run: `bun test src/lib/studio/kv/editOutcome.test.ts src/lib/studio/kv/overlaysForVariant.test.ts src/lib/kv/docAddVariantBoard.test.ts src/lib/analytics/kv-generator-events.editBecameVariant.test.ts` → PASS;
Run: `node ./node_modules/next/dist/bin/next build > /tmp/…/build.log 2>&1; tail -20` (log in the scratchpad) → build succeeds.

- [ ] **Step 7: Commit**

```bash
git add src/components/studio/kv-generator/KvChat.tsx src/components/studio/kv-generator/KvGeneratorLayout.tsx
git commit -m "feat(web): notice before a Craft edit that will land as a variant (board has resizes)"
```

---

### Task 7: Track file + push

**Files:**
- Modify: `web/docs/tracks/kv-craft-resize-strip.track.md`

- [ ] **Step 1:** Add a task row `- [x] TASK-N: Edits on a resized board become variants (spec 2026-09-24)` and a session-log entry (date 2026-09-24, commits, gates run, event `kv_generator.edit_became_variant` — PostHog taxonomy row pending, same as the other strip events), plus the manual smoke checklist from the spec's Testing section.

- [ ] **Step 2: Commit and push**

```bash
git add docs/tracks/kv-craft-resize-strip.track.md
git commit -m "docs(web): track — resized-board edits become variants"
git push origin feature/daffa/vc-kv-craft-resize-strip
```

Expected: push succeeds; `git status -sb` shows the branch in sync with origin.
