# KV Board Surface Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Break the Craft canvas's dependency on `KvBoard.generation`, so a rendered surface can be something other than a KV generation — the prerequisite for Resize tiles becoming boards.

**Architecture:** A new pure module `kvSurface.ts` defines `KvSurface` — what the canvas actually needs to draw a board — plus `surfaceFromBoard()`, which derives one from today's `KvBoard`. `KvFabricCanvas` stops reading `board.generation` and reads the surface instead. Craft behavior is unchanged; the point is the seam.

**Tech Stack:** TypeScript, React, Fabric.js v7, `bun test`.

**Spec:** `docs/superpowers/specs/2026-08-10-kv-canvas-surface-unification-design.md` (this is the first half of its step 2)

**Depends on:** `docs/superpowers/plans/2026-08-10-kv-canvas-geometry-extraction-web.md` (step 1, merged — `overlayGeometry.ts` exists)

## Global Constraints

- Tests run with `bun test` from `web/`. Do **not** use `bunx vitest`.
- Prettier runs through eslint with `trailingComma: "es5"` — a trailing comma after the last function parameter or call argument is an error. Run `bunx eslint` on every file you touch and clear only NEW errors; these files carry many pre-existing ones.
- The `web/` suite has ~126 pre-existing failures (React Testing Library's `screen` is broken under bun) and `bunx tsc --noEmit` is not clean at baseline. The bar is "no new failures", not green. Only new tsc errors naming your touched files matter.
- Do not change `StudioOverlay` or `KvGeneration` in `web/src/types/studio.ts`.
- **This plan must not change Craft behavior at all.** Every board must render, label, select, and lay out exactly as before. There is no agreed behavior change in this plan — if you find yourself changing what the user sees, stop and report.
- `KvFabricCanvas.tsx` is the canvas users work in daily and cannot be component-tested (Fabric needs a real 2D context; jsdom has none). Its verification is the pure tests, `bunx tsc --noEmit`, `bun run build`, and a manual check the human owns.
- Leave `KvKonvaCanvas.tsx` alone. It carries its own copy of `bestEffortAspect`, but it is scheduled for deletion in step 4 — do not migrate it, and do not delete its copy.

## Why this seam is small

`KvFabricCanvas` is 4,187 lines but touches `board.generation` in only four distinct ways:

| What it needs | Where |
|---|---|
| `image_url` — the base image to draw | `KvFabricCanvas.tsx:1111`, `:1153` |
| `metadata` → aspect ratio | `:658`, via `bestEffortAspect` at `:3909` |
| `id` — for the select-board callback | `:2758`, `:2784`, `:3358`, `:3431` |
| `version_number` + `prompt_snapshot` → caption | `boardLabel` at `:3939`, called at `:3361` |

A Resize tile has all four (its export image, its target size, its row id, its platform name) — it just is not a `KvGeneration`. That is the whole problem this plan removes.

---

### Task 1: The surface type and aspect resolution

**Files:**
- Create: `web/src/components/studio/kv-generator/kvSurface.ts`
- Test: `web/src/components/studio/kv-generator/kvSurface.test.ts`

**Interfaces:**
- Consumes: `KvGeneration` from `@/types/studio`; `BoardCenter` from `./boardLayout`
- Produces:
  - `type KvSurface = { id, imageUrl, fallbackAspect, label, isMaster, isActive, center, version_ids? }`
  - `bestEffortAspect(generation: KvGeneration): number`

- [ ] **Step 1: Write the failing test**

Create `web/src/components/studio/kv-generator/kvSurface.test.ts`:

```ts
import { describe, expect, it } from "bun:test";

import { bestEffortAspect } from "./kvSurface";

const gen = (metadata: unknown) =>
  ({
    id: "g1",
    studio_file_id: "f",
    version_number: 1,
    image_url: "https://example.com/x.png",
    thumbnail_url: null,
    prompt_snapshot: "",
    model: "test",
    parent_generation_id: null,
    metadata,
    created_at: "2026-08-10T00:00:00Z",
  }) as unknown as Parameters<typeof bestEffortAspect>[0];

describe("bestEffortAspect", () => {
  it("parses an aspect_ratio string", () => {
    expect(bestEffortAspect(gen({ aspect_ratio: "9:16" }))).toBeCloseTo(9 / 16);
  });

  it("falls back to width/height when there is no aspect_ratio", () => {
    expect(bestEffortAspect(gen({ width: 1080, height: 1920 }))).toBeCloseTo(
      1080 / 1920
    );
  });

  it("ignores a malformed aspect_ratio and uses width/height", () => {
    expect(
      bestEffortAspect(gen({ aspect_ratio: "portrait", width: 2, height: 1 }))
    ).toBe(2);
  });

  it("returns 1 when metadata carries nothing usable", () => {
    expect(bestEffortAspect(gen(null))).toBe(1);
    expect(bestEffortAspect(gen({}))).toBe(1);
    expect(bestEffortAspect(gen({ width: 0, height: 0 }))).toBe(1);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd web && bun test src/components/studio/kv-generator/kvSurface.test.ts
```

Expected: FAIL — cannot resolve module `./kvSurface`.

- [ ] **Step 3: Write the module**

Create `web/src/components/studio/kv-generator/kvSurface.ts`. Move `bestEffortAspect` here from `KvFabricCanvas.tsx:3909-3922` **verbatim** — do not rewrite it, and bring its behavior exactly as-is:

```ts
import type { KvGeneration } from "@/types/studio";

import type { BoardCenter } from "./boardLayout";

/**
 * What the canvas actually needs in order to draw a board.
 *
 * `KvBoard` is welded to `KvGeneration` — it carries a generation, a version
 * chain, and a master flag. That is why a Resize tile cannot be a board today:
 * a tile is a per-platform export with its own target size and its own async
 * lifecycle, not a generation. It nevertheless has everything on this type.
 *
 * Keeping this deliberately small is the point. If you are about to add a field
 * here, check first whether the canvas really needs it to DRAW, or whether it
 * belongs to whoever supplies the surfaces.
 */
export type KvSurface = {
  /** Surface key. For a Craft board this is the tip generation id. */
  id: string;
  /** Base image. Null for a layer-composed board (PSD import) — the overlays
   *  ARE the picture, and the surface renders transparent behind them. */
  imageUrl: string | null;
  /** Width/height ratio to use until the real image has loaded and been
   *  measured. The canvas keeps its own measured-aspect override on top. */
  fallbackAspect: number;
  /** Caption drawn under the surface, already resolved — the canvas does not
   *  know how a label is derived. */
  label: string;
  isMaster: boolean;
  isActive: boolean;
  center: BoardCenter;
  /** In-place polish history, so an overlay can find its surface by matching
   *  `board_generation_id` against the chain after a rekey. */
  version_ids?: string[] | null;
};

/** Aspect from the generation's metadata, before the real image is measured.
 *  Moved verbatim from KvFabricCanvas so a surface can be built without the
 *  canvas. */
export function bestEffortAspect(generation: KvGeneration): number {
  const meta = generation.metadata;
  if (meta && typeof meta === "object") {
    const raw = (meta as Record<string, unknown>).aspect_ratio;
    if (typeof raw === "string") {
      const m = raw.match(/^(\d+)\s*:\s*(\d+)$/);
      if (m && Number(m[1]) && Number(m[2])) return Number(m[1]) / Number(m[2]);
    }
    const w = Number((meta as Record<string, unknown>).width);
    const h = Number((meta as Record<string, unknown>).height);
    if (w > 0 && h > 0) return w / h;
  }
  return 1;
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd web && bun test src/components/studio/kv-generator/kvSurface.test.ts
```

Expected: PASS, 4 tests.

- [ ] **Step 5: Lint, type-check, commit**

```bash
cd web && bunx eslint src/components/studio/kv-generator/kvSurface.ts src/components/studio/kv-generator/kvSurface.test.ts && bunx tsc --noEmit
git add web/src/components/studio/kv-generator/kvSurface.ts web/src/components/studio/kv-generator/kvSurface.test.ts
git commit -m "feat(web): add a board-agnostic KV surface type"
```

---

### Task 2: Derive a surface from today's board

**Files:**
- Modify: `web/src/components/studio/kv-generator/kvSurface.ts`
- Test: `web/src/components/studio/kv-generator/kvSurface.test.ts`

**Interfaces:**
- Consumes: `KvBoard` from `./boardLayout`; `bestEffortAspect` from Task 1
- Produces: `surfaceFromBoard(board: KvBoard): KvSurface`

The label logic currently lives in `KvFabricCanvas.tsx` as `boardLabel` (`:3939-3947`) with its `isRefusal` helper (`:3928-3933`) and an import of `deriveVariantName`. Move all three into `kvSurface.ts` — including moving the `deriveVariantName` import statement — and keep their comments, which explain why a refusal snapshot must not become a caption.

- [ ] **Step 1: Write the failing test**

Append to `web/src/components/studio/kv-generator/kvSurface.test.ts`:

```ts
import { surfaceFromBoard } from "./kvSurface";

const board = (over: Record<string, unknown>) =>
  ({
    id: "b1",
    generation: gen({ width: 1080, height: 1920 }),
    center: { x: 0, y: 0 },
    name: null,
    isMaster: false,
    isActive: false,
    ...over,
  }) as unknown as Parameters<typeof surfaceFromBoard>[0];

describe("surfaceFromBoard", () => {
  it("prefers the persisted board name", () => {
    expect(surfaceFromBoard(board({ name: "  Hero  " })).label).toBe("Hero");
  });

  it("prefixes the master board", () => {
    expect(surfaceFromBoard(board({ name: "Hero", isMaster: true })).label).toBe(
      "Master · Hero"
    );
  });

  it("falls back to V{n} when the prompt snapshot is a refusal", () => {
    const g = gen({ width: 1, height: 1 });
    (g as { prompt_snapshot: string }).prompt_snapshot =
      "I'm sorry, I can't help with that";
    (g as { version_number: number }).version_number = 3;
    expect(surfaceFromBoard(board({ generation: g })).label).toBe("V3");
  });

  it("falls back to V{n} when the prompt snapshot is empty", () => {
    const g = gen({ width: 1, height: 1 });
    (g as { version_number: number }).version_number = 7;
    expect(surfaceFromBoard(board({ generation: g })).label).toBe("V7");
  });

  it("carries the image url and the metadata aspect through", () => {
    const s = surfaceFromBoard(board({}));
    expect(s.imageUrl).toBe("https://example.com/x.png");
    expect(s.fallbackAspect).toBeCloseTo(1080 / 1920);
  });

  it("passes the id, flags, centre and version chain straight through", () => {
    const s = surfaceFromBoard(
      board({
        id: "b9",
        isActive: true,
        center: { x: 640, y: -20 },
        version_ids: ["g1", "g2"],
      })
    );
    expect(s.id).toBe("b9");
    expect(s.isActive).toBe(true);
    expect(s.center).toEqual({ x: 640, y: -20 });
    expect(s.version_ids).toEqual(["g1", "g2"]);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd web && bun test src/components/studio/kv-generator/kvSurface.test.ts
```

Expected: FAIL — `surfaceFromBoard` is not exported.

- [ ] **Step 3: Write the implementation**

Move `isRefusal` and `boardLabel` out of `KvFabricCanvas.tsx` into `kvSurface.ts` verbatim, along with the `deriveVariantName` import they depend on (copy that import statement across; do not guess its path — read it from `KvFabricCanvas.tsx`). Keep both doc comments — they explain why a refusal snapshot must never become a caption:

```ts
function isRefusal(text: string): boolean {
  return /^\s*(i'?m\s+(unable|sorry|not able)|i\s+(cannot|can'?t|am\s+unable)|sorry[,\s]|unfortunately|as an ai)/i.test(
    text
  );
}

function boardLabel(board: KvBoard): string {
  const named = board.name?.trim();
  const prompt = board.generation.prompt_snapshot?.trim() ?? "";
  const base =
    named ||
    (prompt && !isRefusal(prompt)
      ? deriveVariantName(prompt, board.generation.version_number)
      : `V${board.generation.version_number}`);
  return board.isMaster ? `Master · ${base}` : base;
}
```

Then append the adapter:

```ts
/** Adapter for today's only surface producer. When the Resize view lands it
 *  builds `KvSurface` values of its own, and the canvas will not be able to
 *  tell the difference — which is the entire point of this type. */
export function surfaceFromBoard(board: KvBoard): KvSurface {
  return {
    id: board.id,
    imageUrl: board.generation.image_url ?? null,
    fallbackAspect: bestEffortAspect(board.generation),
    label: boardLabel(board),
    isMaster: board.isMaster,
    isActive: board.isActive,
    center: board.center,
    version_ids: board.version_ids ?? null,
  };
}
```

Add `KvBoard` to the existing type import from `./boardLayout`.

- [ ] **Step 4: Run test to verify it passes**

```bash
cd web && bun test src/components/studio/kv-generator/kvSurface.test.ts
```

Expected: PASS, 10 tests.

- [ ] **Step 5: Lint, type-check, commit**

```bash
cd web && bunx eslint src/components/studio/kv-generator/kvSurface.ts src/components/studio/kv-generator/kvSurface.test.ts && bunx tsc --noEmit
git add web/src/components/studio/kv-generator/kvSurface.ts web/src/components/studio/kv-generator/kvSurface.test.ts
git commit -m "feat(web): derive a KV surface from a board"
```

---

### Task 3: Make the Craft canvas read surfaces, not generations

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvFabricCanvas.tsx` — `:658`, `:1111`, `:1153`, `:2758`, `:2784`, `:3358`, `:3361`, `:3431`, and the deletion of `:3909-3922` and `:3928-3947`
- Test: none possible for this file (see Global Constraints)

**Interfaces:**
- Consumes: `KvSurface`, `surfaceFromBoard`, `bestEffortAspect` from Tasks 1–2
- Produces: nothing new

Build a surface per board once, keyed by board id, and read from it at each site. Do NOT change how boards are resolved, laid out, or persisted — `computeBoardLayout`, `boardWorldRect`, and every `canvasState*` helper in `boardLayout.ts` stay exactly as they are. This task changes only where the canvas gets those four facts from.

- [ ] **Step 1: Add the surface map**

Near the existing `activeBoard` memo (around `:652`), derive surfaces from `effectiveBoards`:

```ts
  // One surface per board — what the canvas needs to DRAW, decoupled from the
  // fact that today's boards happen to be generations. Resize tiles will supply
  // their own surfaces without becoming generations.
  const surfaceById = useMemo(() => {
    const m = new Map<string, KvSurface>();
    for (const b of effectiveBoards) m.set(b.id, surfaceFromBoard(b));
    return m;
  }, [effectiveBoards]);
```

- [ ] **Step 2: Read aspect from the surface**

Replace the `aspectOf` callback at `:657-660`:

```ts
  const aspectOf = useCallback(
    (b: KvBoard) =>
      boardAspects[b.id] ?? surfaceById.get(b.id)?.fallbackAspect ?? 1,
    [boardAspects, surfaceById]
  );
```

The measured-aspect override (`boardAspects`) keeps priority exactly as before; only the fallback moved.

- [ ] **Step 3: Read the base image from the surface**

At `:1111` replace `const src = succ.generation.image_url;` with:

```ts
          const src = surfaceById.get(succ.id)?.imageUrl ?? null;
```

At `:1153` replace `const src = board.generation.image_url;` with:

```ts
      const src = surfaceById.get(board.id)?.imageUrl ?? null;
```

Both call sites already guard on a falsy `src`, so a null surface image behaves exactly as a missing `image_url` does today.

- [ ] **Step 4: Use the board key for selection**

At `:2758`, `:2784`, `:3358`, and `:3431`, replace `board.generation.id` (and `target.board.generation.id`) with the board's own `id` — `board.id` / `target.board.id`.

These are the same value today: `KvBoard.id` is documented as "Board key = tip generation id" (`boardLayout.ts:22-23`). Reading `board.id` says what the code means — the surface's key — instead of reaching through a generation that a Resize tile will not have. If you find a site where the two are NOT the same value, stop and report it rather than changing it.

- [ ] **Step 5: Read the label from the surface**

At `:3361` replace `{boardLabel(board)}` with:

```tsx
                {surfaceById.get(board.id)?.label ?? ""}
```

Then delete `boardLabel` (`:3939-3947`), `isRefusal` (`:3928-3933`), `bestEffortAspect` (`:3909-3922`), and the now-unused `deriveVariantName` import from this file — they live in `kvSurface.ts` now. Import `KvSurface` and `surfaceFromBoard` instead.

- [ ] **Step 6: Verify**

```bash
cd web && bunx tsc --noEmit
```

Expected: no error naming `KvFabricCanvas.tsx`. Then:

```bash
cd web && bunx eslint src/components/studio/kv-generator/KvFabricCanvas.tsx
```

Expected: no NEW error (this file has pre-existing ones).

```bash
cd web && bun run build
```

Expected: compiled successfully.

```bash
cd web && grep -n "\.generation\." src/components/studio/kv-generator/KvFabricCanvas.tsx
```

Expected: the only remaining hits read the `generation` PROP (the file's own single-generation prop), never a `board.generation`. Read each hit and say so in your report — a bare "no hits" is not a check.

- [ ] **Step 7: Commit**

```bash
git add web/src/components/studio/kv-generator/KvFabricCanvas.tsx
git commit -m "refactor(web): draw craft boards from surfaces, not generations"
```

---

### Task 4: Confirm nothing moved

**Files:**
- Modify: none expected

- [ ] **Step 1: Run the KV suite**

```bash
cd web && bun test src/components/studio/kv-generator
```

Expected: no NEW failures against the baseline recorded at the start of this plan. Record both numbers in your report.

- [ ] **Step 2: Confirm the seam is real**

```bash
cd web && grep -rn "board.generation\|\.generation\.image_url\|bestEffortAspect" src/components/studio/kv-generator --include="*.tsx" --include="*.ts" | grep -v KvKonvaCanvas | grep -v kvSurface
```

Expected: no hits outside `kvSurface.ts` (and `KvKonvaCanvas.tsx`, which is deliberately excluded — it is deleted in step 4 of the spec). Classify every hit you do find rather than assuming.

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

Fabric cannot be component-tested, so a person has to look. On the Craft canvas, confirm nothing changed: every board renders with its own image, boards keep their captions (including the `Master · ` prefix and prompt-distilled variant names), clicking a board still selects it, a board whose image has not loaded yet still reserves the right shape, and a PSD/layer-composed board with no base image still renders its overlays.

## What comes next

This is the first half of the spec's step 2. With the canvas reading surfaces, the second half extracts the layout seam — the canvas currently derives every board's position from persisted artboard centers, and a view needs to be able to supply positions instead (a vertical column, for Resize). That gets its own plan, written against the `KvSurface` this one establishes.
