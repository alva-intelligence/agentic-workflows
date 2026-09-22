# KV Craft Resize Strip — S1 Engine Seam Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task (this project runs inline, no subagents). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `KvFabricCanvas` iterates `KvSurface[]` instead of `KvBoard[]`, so a second producer (Resize tiles, S2) can be drawn by the same canvas; board draggability, board-map attachment and the overlay write sink become per-surface properties; Craft behaves identically.

**Architecture:** Five localised changes inside `KvFabricCanvas.tsx` (no file split): (1) `surfaces` prop merged after the Craft producer, with `boardById` kept for Craft-only chrome; (2) board `selectable` gated on `surface.layout === "doc"`; (3) `ensureBoardMap` already gated — unchanged; (4) overlay tag becomes a union — doc tag `{elementId, elementMap}` handled by the Yjs binding, rest tag `{elementId, restSurfaceId}` handled by a new `bindRestOverlaySink`; the binding's `overlayMetaOf` now requires `elementMap`; (5) tool targeting returns a surface and refuses placement on a non-Craft surface until S3 routes it. Only the Craft producer is live after this slice.

**Tech Stack:** Fabric v7, Yjs, React 19, TypeScript, `bun test`.

**Spec:** `docs/superpowers/specs/2026-09-22-kv-craft-resize-strip-design.md` §Architecture → "The engine seam (slice S1)".

## Global Constraints

- Work inside `web/` on `feature/daffa/vc-kv-craft-resize-strip` (S0 already committed). Commit locally only; never push; never `git stash`.
- Tests: `bun test <explicit files>`; build: `node ./node_modules/next/dist/bin/next build`.
- `KvFabricCanvas` cannot be component-tested (jsdom has no 2D context). Its gate is: **no new tsc errors naming it** (baseline recorded per task), build clean, and the manual Craft checklist written to the track file for Daffa.
- A `rest` surface must NEVER reach `ensureBoardMap`, `writeOverlayRect`, or a board-position write. `shouldAttachBoardMap` / `canPersistBoardPosition` / `overlaySinkFor` in `kvSurface.ts` are the only places those decisions live.
- Never wire `onResetBoardPosition` / `onSetMaster` for a `layout: "view"` surface (#426 §"Two ungated paths").
- Only invariant pure tests; no RTL/component tests.

---

### Task 1: Binding ignores overlays that own no `elementMap`

**Files:**
- Modify: `web/src/lib/kv/yjsBinding.ts:47-50` (type) and `:138-141` (`overlayMetaOf`)
- Test: `web/src/lib/kv/yjsBinding.metaOf.test.ts` (new)

**Interfaces:**
- Produces: `export function overlayMetaOf(obj: fabric.Object): FabricOverlayMeta | null` — returns the meta only when `elementId` AND a truthy `elementMap` are present. Task 5 relies on this: a rest-tagged object passes through the binding untouched.

- [ ] **Step 1: Write the failing test**

```ts
// web/src/lib/kv/yjsBinding.metaOf.test.ts
import { describe, it, expect } from "bun:test";
import * as Y from "yjs";
import { overlayMetaOf } from "./yjsBinding";

const obj = (data: unknown) => ({ data }) as unknown as import("fabric").Object;

describe("overlayMetaOf — the doc sink only claims doc-backed overlays", () => {
  it("returns the meta for a doc overlay (elementId + elementMap)", () => {
    const elementMap = new Y.Map<unknown>();
    expect(overlayMetaOf(obj({ elementId: "o1", elementMap }))).toEqual({ elementId: "o1", elementMap });
  });
  it("returns null for a REST overlay (elementId + restSurfaceId, no elementMap)", () => {
    expect(overlayMetaOf(obj({ elementId: "o1", restSurfaceId: "exp_1" }))).toBeNull();
  });
  it("returns null for a board tag and for untagged objects", () => {
    expect(overlayMetaOf(obj({ boardId: "b1", boardMap: null }))).toBeNull();
    expect(overlayMetaOf(obj(undefined))).toBeNull();
  });
});
```

- [ ] **Step 2: Run it — expect FAIL (`overlayMetaOf` is not exported)**

```bash
cd web && bun test src/lib/kv/yjsBinding.metaOf.test.ts 2>&1 | tail -5
```

- [ ] **Step 3: Export and tighten `overlayMetaOf`**

In `yjsBinding.ts` replace lines 138–141:
```ts
/** The doc sink claims an overlay only when it OWNS a Y map. An overlay tagged
 *  `{elementId, restSurfaceId}` (a Resize tile overlay — see
 *  `restOverlaySink.ts`) carries no `elementMap`, so it is invisible here by
 *  construction: nothing this binding does can write it into the doc. */
export function overlayMetaOf(obj: fabric.Object): FabricOverlayMeta | null {
  const data = (obj as TaggedOverlay).data as
    | (Partial<FabricOverlayMeta> & Record<string, unknown>)
    | undefined;
  return data && "elementId" in data && data.elementMap ? (data as FabricOverlayMeta) : null;
}
```

- [ ] **Step 4: Run — expect PASS; then run the existing binding suite for no regression**

```bash
cd web && bun test src/lib/kv/yjsBinding.metaOf.test.ts src/lib/kv/yjsBinding.test.ts 2>&1 | tail -5
```
Expected: `0 fail`.

- [ ] **Step 5: Commit**

```bash
cd web && git add src/lib/kv/yjsBinding.ts src/lib/kv/yjsBinding.metaOf.test.ts && git commit -q -m "fix(web): the Yjs overlay sink claims only overlays that own an elementMap

A REST-sunk overlay (Resize tile, S1 of the Craft Resize strip) keeps
elementId so the canvas's selection/ghost/z-order paths treat it as an
overlay, but carries no elementMap — the doc binding must skip it by
construction rather than crash in writeOverlayRect.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 2: `restOverlaySink` — the second overlay sink, pure

**Files:**
- Create: `web/src/components/studio/kv-generator/restOverlaySink.ts`
- Test: `web/src/components/studio/kv-generator/restOverlaySink.test.ts`

**Interfaces:**
- Consumes: `overlayNormFromRect` from `./overlayGeometry` (exists; signature `(rect: {x,y,width,height}, host: {x,y,width,height}) → {x,y,width,height}` normalized to the host — read the file's JSDoc once before use and adapt the argument shape if it differs).
- Produces:
```ts
export type RestOverlayTag = { elementId: string; restSurfaceId: string };
export function restOverlayMetaOf(obj: { data?: unknown }): RestOverlayTag | null;
export type RestCommit = { surfaceId: string; overlayId: string; rect: { x: number; y: number; width: number; height: number; rotation: number } };
export function bindRestOverlaySink(
  canvas: { on(ev: string, h: (e: { target?: unknown }) => void): void; off(ev: string, h: (e: { target?: unknown }) => void): void },
  opts: { resolveHostRect: (surfaceId: string) => { x: number; y: number; width: number; height: number } | null; onCommit: (c: RestCommit) => void }
): () => void; // dispose
```
Listens to `object:modified` only (no streaming — REST commits are whole snapshots; S3 decides debounce).

- [ ] **Step 1: Write the failing test**

```ts
// restOverlaySink.test.ts
import { describe, it, expect } from "bun:test";
import { bindRestOverlaySink, restOverlayMetaOf } from "./restOverlaySink";

type H = (e: { target?: unknown }) => void;
function fakeCanvas() {
  const handlers = new Map<string, Set<H>>();
  return {
    on(ev: string, h: H) { (handlers.get(ev) ?? handlers.set(ev, new Set()).get(ev)!).add(h); },
    off(ev: string, h: H) { handlers.get(ev)?.delete(h); },
    fire(ev: string, e: { target?: unknown }) { handlers.get(ev)?.forEach((h) => h(e)); },
    count: () => [...handlers.values()].reduce((n, s) => n + s.size, 0),
  };
}
// origin center, like the canvas's overlay objects: left/top ARE the centre.
const obj = (data: unknown, geo: { left: number; top: number; width: number; height: number; scaleX?: number; scaleY?: number; angle?: number }) =>
  ({ data, scaleX: 1, scaleY: 1, angle: 0, ...geo });

describe("restOverlayMetaOf", () => {
  it("claims only {elementId, restSurfaceId}", () => {
    expect(restOverlayMetaOf({ data: { elementId: "o", restSurfaceId: "s" } })).toEqual({ elementId: "o", restSurfaceId: "s" });
    expect(restOverlayMetaOf({ data: { elementId: "o", elementMap: {} } })).toBeNull();
    expect(restOverlayMetaOf({ data: { boardId: "b" } })).toBeNull();
    expect(restOverlayMetaOf({})).toBeNull();
  });
});

describe("bindRestOverlaySink", () => {
  it("normalises a modified REST overlay against its surface host and commits", () => {
    const c = fakeCanvas();
    const commits: unknown[] = [];
    bindRestOverlaySink(c, {
      resolveHostRect: (id) => (id === "exp_1" ? { x: 100, y: 200, width: 400, height: 200 } : null),
      onCommit: (x) => commits.push(x),
    });
    // 200×100 object centred at (300, 300) inside host (100,200,400,200)
    c.fire("object:modified", { target: obj({ elementId: "o1", restSurfaceId: "exp_1" }, { left: 300, top: 300, width: 200, height: 100, angle: 15 }) });
    expect(commits).toEqual([{ surfaceId: "exp_1", overlayId: "o1", rect: { x: 0.25, y: 0.25, width: 0.5, height: 0.5, rotation: 15 } }]);
  });
  it("ignores doc overlays and boards, and objects whose host is unknown", () => {
    const c = fakeCanvas();
    const commits: unknown[] = [];
    bindRestOverlaySink(c, { resolveHostRect: () => null, onCommit: (x) => commits.push(x) });
    c.fire("object:modified", { target: obj({ elementId: "o", elementMap: {} }, { left: 0, top: 0, width: 1, height: 1 }) });
    c.fire("object:modified", { target: obj({ boardId: "b", boardMap: null }, { left: 0, top: 0, width: 1, height: 1 }) });
    c.fire("object:modified", { target: obj({ elementId: "o", restSurfaceId: "gone" }, { left: 0, top: 0, width: 1, height: 1 }) });
    expect(commits).toEqual([]);
  });
  it("dispose detaches every handler", () => {
    const c = fakeCanvas();
    const dispose = bindRestOverlaySink(c, { resolveHostRect: () => null, onCommit: () => {} });
    expect(c.count()).toBeGreaterThan(0);
    dispose();
    expect(c.count()).toBe(0);
  });
});
```

- [ ] **Step 2: Run — expect FAIL (module missing)**

```bash
cd web && bun test src/components/studio/kv-generator/restOverlaySink.test.ts 2>&1 | tail -4
```

- [ ] **Step 3: Implement**

```ts
// restOverlaySink.ts
/**
 * The SECOND overlay sink. The Yjs binding (`bindKvCanvasToYjs`) writes doc
 * overlays — objects tagged `{elementId, elementMap}`. This one commits
 * REST-backed overlays — objects tagged `{elementId, restSurfaceId}` — by
 * calling back with a normalised rect the host persists per surface
 * (Resize tile → `commitTileOverlays`). Which sink an overlay uses is decided
 * ONCE, at tag time, from `overlaySinkFor(surface)` in `kvSurface.ts`.
 *
 * Kept free of fabric imports so it is testable with a fake emitter.
 */
export type RestOverlayTag = { elementId: string; restSurfaceId: string };

export type RestCommit = {
  surfaceId: string;
  overlayId: string;
  rect: { x: number; y: number; width: number; height: number; rotation: number };
};

type Geo = { left?: number; top?: number; width?: number; height?: number; scaleX?: number; scaleY?: number; angle?: number };
type Emitter = {
  on(ev: string, h: (e: { target?: unknown }) => void): void;
  off(ev: string, h: (e: { target?: unknown }) => void): void;
};

export function restOverlayMetaOf(obj: { data?: unknown }): RestOverlayTag | null {
  const d = obj.data as Partial<RestOverlayTag> | undefined;
  return d && typeof d.elementId === "string" && typeof d.restSurfaceId === "string"
    ? { elementId: d.elementId, restSurfaceId: d.restSurfaceId }
    : null;
}

export function bindRestOverlaySink(
  canvas: Emitter,
  opts: {
    resolveHostRect: (surfaceId: string) => { x: number; y: number; width: number; height: number } | null;
    onCommit: (c: RestCommit) => void;
  }
): () => void {
  const onModified = (e: { target?: unknown }) => {
    const target = e.target as (Geo & { data?: unknown }) | undefined;
    if (!target) return;
    const meta = restOverlayMetaOf(target);
    if (!meta) return;
    const host = opts.resolveHostRect(meta.restSurfaceId);
    if (!host || host.width <= 0 || host.height <= 0) return;
    // Overlay objects use origin "center": left/top ARE the centre.
    const w = (target.width ?? 0) * (target.scaleX ?? 1);
    const h = (target.height ?? 0) * (target.scaleY ?? 1);
    const left = (target.left ?? 0) - w / 2;
    const top = (target.top ?? 0) - h / 2;
    opts.onCommit({
      surfaceId: meta.restSurfaceId,
      overlayId: meta.elementId,
      rect: {
        x: (left - host.x) / host.width,
        y: (top - host.y) / host.height,
        width: w / host.width,
        height: h / host.height,
        rotation: target.angle ?? 0,
      },
    });
  };
  canvas.on("object:modified", onModified);
  return () => canvas.off("object:modified", onModified);
}
```
(The normalisation is the same formula as `writeOverlayRect` in `yjsBinding.ts:242-262`, deliberately restated here rather than imported: that function is private to the binding and transacts on the doc.)

- [ ] **Step 4: Run — expect PASS**

```bash
cd web && bun test src/components/studio/kv-generator/restOverlaySink.test.ts 2>&1 | tail -4
```

- [ ] **Step 5: Commit**

```bash
cd web && git add src/components/studio/kv-generator/restOverlaySink.ts src/components/studio/kv-generator/restOverlaySink.test.ts && git commit -q -m "feat(web): restOverlaySink — the REST-backed overlay sink for surfaces that own no doc board

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 3: `KvFabricCanvas` iterates surfaces

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvFabricCanvas.tsx` — props (~318-560), `effectiveBoards` block (1115-1150), `boardMapFor`/`aspectOf`/`activeHostRect`/`overlayHostRect` (1152-1235), board-rects effect (1919-1936), board sync effect (1955-2093), `boardRects` (3143-3155), `resolveToolTarget` (4109-4127), `screenRectOf` (5006-5019), `onLabelPointerDown` (5028-5044), chrome map (5362-5420+), `.generation.id` (4501), `.generation.image_url` (6542), `isConceptPreview` (~5406).
- Modify: `web/src/components/studio/kv-generator/kvSurface.ts` — add `mergeSurfaces`.
- Test: `web/src/components/studio/kv-generator/kvSurface.merge.test.ts` (new)

**Interfaces:**
- Consumes: `KvSurface`, `surfaceFromBoard`, `shouldAttachBoardMap`, `boardMapKeyFor`, `canPersistBoardPosition`, `findSurfaceForLiveBoardId` from `./kvSurface` (all exist).
- Produces:
  - `kvSurface.ts`: `export function mergeSurfaces(craft: KvSurface[], extra: KvSurface[] | undefined): KvSurface[]` — craft first, then extra; an extra whose `id` collides with a craft id is dropped (Craft owns the id space).
  - `KvFabricCanvas` new prop: `surfaces?: KvSurface[]` — additional surfaces appended after the Craft producer (S2 passes the Resize tiles here).
  - Internal: `effectiveSurfaces: KvSurface[]`, `boardById: Map<string, KvBoard>`, `activeSurface: KvSurface | null`, `aspectOf(s: Pick<KvSurface, "id" | "fallbackAspect">)`.

- [ ] **Step 1: Record this file's tsc baseline**

```bash
cd web && bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -c "KvFabricCanvas.tsx" | tee /private/tmp/claude-501/-Users-alva-e202511001-Desktop-work-frndos-agentic/1680fa68-8110-48ef-be28-006eba99254f/scratchpad/tsc-fabric-baseline.txt
```

- [ ] **Step 2: Write the failing `mergeSurfaces` test**

```ts
// kvSurface.merge.test.ts
import { describe, it, expect } from "bun:test";
import { mergeSurfaces, type KvSurface } from "./kvSurface";

const s = (id: string, layout: KvSurface["layout"] = "doc"): KvSurface => ({
  id, docBoardId: layout === "doc" ? id : null, layout, imageUrl: null, fallbackAspect: 1, label: id, isActive: false, center: { x: 0, y: 0 },
});

describe("mergeSurfaces", () => {
  it("keeps Craft first and appends extra producers", () => {
    expect(mergeSurfaces([s("g1"), s("g2")], [s("e1", "view")]).map((x) => x.id)).toEqual(["g1", "g2", "e1"]);
  });
  it("drops an extra surface whose id collides with a Craft board — Craft owns the id space", () => {
    expect(mergeSurfaces([s("g1")], [s("g1", "view"), s("e1", "view")]).map((x) => x.id)).toEqual(["g1", "e1"]);
  });
  it("returns the craft array itself when there is nothing extra (referential stability for memo deps)", () => {
    const craft = [s("g1")];
    expect(mergeSurfaces(craft, undefined)).toBe(craft);
    expect(mergeSurfaces(craft, [])).toBe(craft);
  });
});
```

- [ ] **Step 3: Run — FAIL; implement in `kvSurface.ts` (append at end)**

```ts
/** Craft surfaces first, then every extra producer (Resize tiles in S2). An
 *  extra surface whose id collides with a Craft board is dropped — Craft owns
 *  the id space, and a tile can never legitimately share a generation id.
 *  Returns `craft` itself when nothing is added so memo deps stay stable. */
export function mergeSurfaces(craft: KvSurface[], extra: KvSurface[] | undefined): KvSurface[] {
  if (!extra || extra.length === 0) return craft;
  const taken = new Set(craft.map((s) => s.id));
  const added = extra.filter((s) => !taken.has(s.id));
  return added.length === 0 ? craft : [...craft, ...added];
}
```
Run: `cd web && bun test src/components/studio/kv-generator/kvSurface.merge.test.ts src/components/studio/kv-generator/kvSurface.test.ts 2>&1 | tail -4` → `0 fail`.

- [ ] **Step 4: Add the prop and the surface set (edit 1115-1150)**

Add to `Props` (after `pendingBoards?: KvPendingBoard[];` at ~331):
```ts
  /** Additional surfaces drawn by this canvas AFTER the Craft boards — the
   *  Resize tiles in S2. They are not generations: `docBoardId: null`,
   *  `layout: "view"`, overlays committed through `onCommitRestOverlay`.
   *  Merged by `mergeSurfaces`; a Craft id always wins. */
  surfaces?: KvSurface[];
```
Destructure `surfaces` with the other props (~651-700). Then replace the block that starts `const activeBoard = useMemo(` and the `surfaceById` memo with:
```ts
  /** Craft boards by id — the ONLY place generation-specific chrome (context
   *  menu, rename, variant, angle preview, concept badge) may look a board up.
   *  A surface with no entry here is not a Craft board and gets none of it. */
  const boardById = useMemo(() => {
    const m = new Map<string, KvBoard>();
    for (const b of effectiveBoards) m.set(b.id, b);
    return m;
  }, [effectiveBoards]);

  const craftSurfaces = useMemo(
    () => effectiveBoards.map(surfaceFromBoard),
    [effectiveBoards]
  );
  const effectiveSurfaces = useMemo(
    () => mergeSurfaces(craftSurfaces, surfaces),
    [craftSurfaces, surfaces]
  );
  const surfaceById = useMemo(() => {
    const m = new Map<string, KvSurface>();
    for (const s of effectiveSurfaces) m.set(s.id, s);
    return m;
  }, [effectiveSurfaces]);

  const activeSurface = useMemo(
    () => effectiveSurfaces.find((s) => s.isActive) ?? effectiveSurfaces[0] ?? null,
    [effectiveSurfaces]
  );
  /** The active CRAFT board, for callers that genuinely need a generation.
   *  Null when the active surface is not a Craft board (a tile, from S3). */
  const activeBoard = useMemo(
    () => (activeSurface ? boardById.get(activeSurface.id) ?? null : null),
    [activeSurface, boardById]
  );
```
Keep the existing `onActiveBoardChange` effect but key it on `activeSurface`: `if (activeSurface) onActiveBoardChange?.(activeSurface.id);`. Import `mergeSurfaces` from `./kvSurface`.

- [ ] **Step 5: Retype the geometry helpers (1152-1235)**

```ts
  const boardMapFor = useCallback(
    (s: Pick<KvSurface, "id">): Y.Map<unknown> | null => {
      if (!docSeeded) return null;
      const surface = surfaceById.get(s.id);
      if (!surface || !shouldAttachBoardMap(surface)) return null;
      const key = boardMapKeyFor(surface);
      if (key == null) return null;
      const board = boardById.get(s.id);
      if (!board) return null; // not a Craft board → owns no doc board map
      return ensureBoardMap(doc, key, board);
    },
    [surfaceById, boardById, doc, docSeeded]
  );

  const aspectOf = useCallback(
    (s: Pick<KvSurface, "id" | "fallbackAspect">) =>
      boardAspects[s.id] ?? s.fallbackAspect ?? 1,
    [boardAspects]
  );

  const activeHostRect = useMemo<WorldRect | null>(() => {
    if (!activeSurface) return null;
    return boardWorldRect(activeSurface.center, BOARD_WORLD_WIDTH, aspectOf(activeSurface));
  }, [activeSurface, aspectOf]);
```
In `overlayHostRect` (1216-1233) replace `effectiveBoards.find(` with `effectiveSurfaces.find(` (fields `id`, `version_ids`, `center` all exist on `KvSurface`). In the angle-activation effect (1241-1270) replace `effectiveBoards.find((b) => b.id === pinnedGenerationId)` with `boardById.get(pinnedGenerationId)` — the angle tool is Craft-only and needs a generation.

- [ ] **Step 6: Retype the render paths**

Board-rects effect (1919-1936): `for (const board of effectiveSurfaces)` (rename loop var to `s`). Deps: swap `effectiveBoards` → `effectiveSurfaces`.

Board sync effect (1955-2093): `boardsSig` and the effect body iterate `effectiveSurfaces`; `styleBoard(img, s: KvSurface, aspect)`; inside it:
```ts
        selectable: tool === "cursor" && s.layout === "doc",
        evented: tool === "cursor" && s.layout === "doc",
        hoverCursor: s.layout !== "doc" ? "default" : s.isActive ? "grab" : "pointer",
```
`src` becomes `s.imageUrl`; `boardMapFor(s)` (signature now takes a surface). The `succ` lookup uses `effectiveSurfaces.find((x) => x.version_ids?.includes(...))`.

`boardRects` (3143-3155): `effectiveSurfaces.map((s) => boardWorldRect(s.center, BOARD_WORLD_WIDTH, aspectOf(s)))`.

`resolveToolTarget` (4109-4127): return type `{ rect: WorldRect; surface: KvSurface } | null`, iterate `st.effectiveSurfaces`; `toolRef` carries `effectiveSurfaces` (replace `effectiveBoards` in both the ref shape ~4082-4108 and every `st.effectiveBoards` reader: 3692, 3743-3744, 4501). Every consumer reading `target.board` reads `target.surface` (`.id`, `.isActive` exist).

At 4501: `boardById.get(boardId)?.generation.id ?? boardId` (read through a `boardByIdRef` mirrored like `surfaceByIdRef` at 1371).

`screenRectOf` (5006): parameter type `Pick<KvSurface, "id" | "center"> | KvPendingBoard` — `KvPendingBoard` has no `id`, so the existing `"id" in b` guard still holds.

- [ ] **Step 7: Chrome map (5362+) and Craft-only lookups**

```tsx
        {effectiveSurfaces.map((s) => {
          const board = boardById.get(s.id) ?? null; // null → not a Craft board
          const sr = screenRectOf(s, aspectOf(s));
          const boardLabel = s.label;
```
- Label button: `onPointerDown={board ? onLabelPointerDown(board) : undefined}`, `onDoubleClick={board && onRenameBoard ? ... : undefined}`, the `cursor-grab` class only when `board && tool === "cursor"`; `onClick` → `if (!s.isActive) selectSurface(s.id)` (Task 4 defines `selectSurface`).
- Concept badge: `board?.isConceptPreview`.
- Every later `effectiveBoards.find((b) => b.id === renamingBoardId | variantBaseId | angleBoardId)` (5641, 5754, 6526) → `boardById.get(...)`; 6542 `previewImageUrl={board.generation.image_url}` stays (it is reached only through `boardById`).
- Board context-menu open (right-click, effect ~3965) must resolve `boardById.get(id)` and **return early when undefined** — a non-Craft surface gets no board menu in S1 (S2 adds the tile menu).

- [ ] **Step 8: tsc — zero new errors in the file**

```bash
cd web && bunx tsc --noEmit -p tsconfig.json 2>&1 | grep "KvFabricCanvas.tsx" | grep -v -f <(git show origin/develop:src/components/studio/kv-generator/KvFabricCanvas.tsx >/dev/null; echo "__none__") | wc -l; cat /private/tmp/claude-501/-Users-alva-e202511001-Desktop-work-frndos-agentic/1680fa68-8110-48ef-be28-006eba99254f/scratchpad/tsc-fabric-baseline.txt
```
Expected: the two numbers are equal. If the new count is higher, read each new error and fix — do not suppress with `as`.

- [ ] **Step 9: Also confirm no other file broke (KvCanvas passes `boards`, unchanged)**

```bash
cd web && bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -c "error TS"; cat /private/tmp/claude-501/-Users-alva-e202511001-Desktop-work-frndos-agentic/1680fa68-8110-48ef-be28-006eba99254f/scratchpad/tsc-baseline.txt
```
Expected: equal.

- [ ] **Step 10: Commit**

```bash
cd web && git add src/components/studio/kv-generator/KvFabricCanvas.tsx src/components/studio/kv-generator/kvSurface.ts src/components/studio/kv-generator/kvSurface.merge.test.ts && git commit -q -m "refactor(web): KvFabricCanvas draws KvSurface[], not KvBoard[]

surfaces prop (extra producers, merged after Craft), boardById for the
Craft-only chrome, aspectOf/boardWorldRect/resolveToolTarget/screenRectOf
retyped to the surface. Board drag is gated on layout === \"doc\". Only the
Craft producer is live; Craft behaviour is unchanged.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 4: Selection routing + placement refusal on non-Craft surfaces

**Files:**
- Modify: `KvFabricCanvas.tsx` — props (add `onSelectSurface`), binding `onBoardSelected` (~1808), tool handlers at 4251/4272/4299/4324, label click (5409), board menu (5720), the tool `mouse:up` placement branches (~4217-4520).

**Interfaces:**
- Produces prop: `onSelectSurface?: (surfaceId: string) => void` — fired for a surface that is NOT a Craft board. `onSelectBoard(generationId)` keeps its generation semantics (spec risk 4).
- Internal helper:
```ts
  const selectSurface = useCallback((id: string) => {
    if (boardById.has(id)) onSelectBoard?.(id);
    else onSelectSurface?.(id);
  }, [boardById, onSelectBoard, onSelectSurface]);
```
Mirror it in `cbRef`/`toolRef` so stable handlers can call it.

- [ ] **Step 1: Route every board-select call through `selectSurface`**

Binding: `onBoardSelected: (id) => { if (id) cbRef.current.selectSurface(id); ... }`. Tool handlers 4272/4299/4324: `if (!target.surface.isActive) st.selectSurface(target.surface.id);`. Label click 5409 and menu 5720: `selectSurface(...)`.

- [ ] **Step 2: Refuse placement on a non-Craft surface (S3 replaces this with routing)**

At the top of each placement branch in the tool `mouse:up` handler (text / image / shape / comment / frame-box creation — each begins by calling `resolveToolTargetRef.current(wx, wy)`), add immediately after the target is resolved:
```ts
      // S1: placement is doc-only. A surface with no Craft board (a Resize
      // tile) has no doc sink for a new overlay yet — S3 routes it to REST.
      if (!boardByIdRef.current.has(target.surface.id)) return;
```

- [ ] **Step 3: tsc equal to baseline; commit**

```bash
cd web && bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -c "KvFabricCanvas.tsx"; cat /private/tmp/claude-501/-Users-alva-e202511001-Desktop-work-frndos-agentic/1680fa68-8110-48ef-be28-006eba99254f/scratchpad/tsc-fabric-baseline.txt
cd web && git add src/components/studio/kv-generator/KvFabricCanvas.tsx && git commit -q -m "feat(web): KvFabricCanvas routes selection by surface kind and refuses placement on non-Craft surfaces

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 5: Rest overlays through the canvas's overlay pipeline (inert until S3)

**Files:**
- Modify: `KvFabricCanvas.tsx` — `OverlayTag` (300), props, overlay effect (2236-2420), Fabric lifecycle effect (1807-1876) for the sink binding.

**Interfaces:**
- Consumes: `bindRestOverlaySink`, `RestOverlayTag` from `./restOverlaySink` (Task 2).
- Produces props:
```ts
  /** Overlays hosted by non-Craft surfaces, keyed by surface id. Built by the
   *  same overlay pipeline as doc overlays but tagged for the REST sink. */
  restOverlays?: Record<string, StudioOverlay[]>;
  /** A REST overlay finished a transform. The host persists the surface's
   *  overlay list (Resize: `commitTileOverlays`). */
  onCommitRestOverlay?: (c: { surfaceId: string; overlayId: string; rect: { x: number; y: number; width: number; height: number; rotation: number } }) => void;
```

- [ ] **Step 1: Tag union**

```ts
type DocOverlayTag = { elementId: string; elementMap: Y.Map<unknown> };
type OverlayTag = DocOverlayTag | RestOverlayTag;
```
Where the canvas reads `data.elementMap` (search `.elementMap` — the `add()` tagging at ~2358 and any text handlers), narrow with `"elementMap" in data`.

- [ ] **Step 2: Build rest overlays in the overlay effect**

Right after `const sorted = [...overlays].sort(...)` (~2364), extend the pipeline:
```ts
    // REST-hosted overlays (Resize tiles). Same objects, same styling, same
    // selection — only the tag differs, and the tag picks the sink.
    const restEntries: { surfaceId: string; overlay: StudioOverlay }[] = [];
    for (const [surfaceId, list] of Object.entries(restOverlays ?? {})) {
      for (const overlay of list) restEntries.push({ surfaceId, overlay });
    }
```
- `wanted` (2237) must include rest overlay ids so existing rest objects are reused, not removed.
- For each rest entry: `host = surfaceById.get(surfaceId)` → `boardWorldRect(host.center, BOARD_WORLD_WIDTH, aspectOf(host))`; build the object exactly as the doc path does (same `buildTextObject`/`buildShapeObject`/image branches and `add(obj, overlay)`), but tag `(obj as Tagged).data = { elementId: overlay.id, restSurfaceId: surfaceId };` instead of the `ensureOverlayMap` line. Factor the per-type object construction into a local `buildOverlayObject(overlay, rect)` closure if it is not already one, so the two paths share it — do NOT copy the body.
- Add `restOverlays` to the effect deps and to `overlaysRef`-style refs only if a handler reads it.

- [ ] **Step 3: Bind the REST sink beside the Yjs binding (1807)**

```ts
    const disposeRestSink = bindRestOverlaySink(canvas, {
      resolveHostRect: (surfaceId) => {
        const s = surfaceByIdRef.current.get(surfaceId);
        if (!s) return null;
        return boardWorldRect(s.center, BOARD_WORLD_WIDTH, aspectOfRef.current(s));
      },
      onCommit: (c) => cbRef.current.onCommitRestOverlay?.(c),
    });
```
(Add `aspectOfRef` mirroring `aspectOf` like the other `*Ref` mirrors; add `onCommitRestOverlay` to `cbRef`.) Call `disposeRestSink()` in the cleanup before `bindingRef.current?.dispose()`.

- [ ] **Step 4: tsc equal to baseline; commit**

```bash
cd web && bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -c "KvFabricCanvas.tsx"; cat /private/tmp/claude-501/-Users-alva-e202511001-Desktop-work-frndos-agentic/1680fa68-8110-48ef-be28-006eba99254f/scratchpad/tsc-fabric-baseline.txt
cd web && git add src/components/studio/kv-generator/KvFabricCanvas.tsx && git commit -q -m "feat(web): KvFabricCanvas hosts REST-sunk overlays through the same overlay pipeline

restOverlays/onCommitRestOverlay props, DocOverlayTag | RestOverlayTag, the
REST sink bound beside the Yjs binding. No host passes them yet — inert.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 6: Build gate + track file with the manual Craft checklist

**Files:**
- Create: `web/docs/tracks/kv-craft-resize-strip.track.md`

- [ ] **Step 1: Build**

```bash
cd web && node ./node_modules/next/dist/bin/next build 2>&1 | tail -4
```
Expected: exit 0.

- [ ] **Step 2: Run every test file touched or added in S0–S1 in one go (excluding the two RTL files, run separately)**

```bash
cd web && K=src/components/studio/kv-generator && bun test src/lib/kv/yjsBinding.metaOf.test.ts src/lib/kv/yjsBinding.test.ts $K/restOverlaySink.test.ts $K/kvSurface.merge.test.ts $K/kvSurface.test.ts $K/resizeWorldGeometry.test.ts $K/resizeToolGesture.test.ts $K/resizeBoardOverlays.test.ts $K/resizeCommitRouting.test.ts $K/resizeSelectionSource.test.ts $K/resizeBoardCamera.test.ts $K/resizeCandidatePick.test.ts $K/resizeFrameGesture.test.ts 2>&1 | tail -4
```
Expected: `0 fail`.

- [ ] **Step 3: Write the track file**

```markdown
---
prd: kv-resize-unified-canvas
parent_prd: docs/prd/kv-resize-unified-canvas.md
service: web
branch: feature/daffa/vc-kv-craft-resize-strip
pr_url: null
status: in_progress
---

# kv-craft-resize-strip — Web Track

Spec: `docs/superpowers/specs/2026-09-22-kv-craft-resize-strip-design.md` (workspace repo).

## Status

| Item | Status |
|------|--------|
| S0 harvest | done (local) |
| S1 engine seam | done (local) — **manual Craft checklist OWED** |
| S2 strip read-only | not_started |
| S3 editing on tiles | not_started |
| S4 delete | not_started |

## Manual Craft regression checklist (run after S1, before trusting S2)

Open a multi-board KV file on this branch with `KV_RESIZE_UNIFIED_CANVAS` OFF.
- [ ] Boards render at their persisted positions, captions correct, master badge correct
- [ ] Drag a board → position persists after reload (Postgres `metadata->'kv_canvas'->'artboards'` changes)
- [ ] Drag by label works; double-click label renames
- [ ] Select / move / scale / rotate an overlay; reload → persisted
- [ ] Inline text edit; shape tool; frame tool + object detection; comment pin
- [ ] Right-click board → context menu opens; Send to Resize still opens the old Resize tab
- [ ] Cmd+Z undoes a board move and an overlay move
- [ ] PSD (layer-composed) board renders transparent behind its overlays
- [ ] Second tab: presence cursor + live overlay move visible
- [ ] Zoom-to-fit, ruler, grid unchanged

## Session Log

### 2026-09-22 — daffa (with Claude, autonomous)
- S0: harvested 10 modules + tests from vc-kv-resize-unified-canvas (no consumers).
- S1: surfaces prop / boardById / per-surface drag gate / DocOverlayTag|RestOverlayTag / restOverlaySink bound; binding overlayMetaOf requires elementMap (tested). tsc equal to baseline; build clean.
- Next: S2 plan written against the landed S1 code.
```

- [ ] **Step 4: Commit**

```bash
cd web && git add docs/tracks/kv-craft-resize-strip.track.md && git commit -q -m "docs(web): track file for kv-craft-resize-strip with the S1 manual Craft checklist

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Self-review

- Spec §S1 change 1 (surfaces input) → Task 3; change 2 (drag gate) → Task 3 Step 6; change 3 (board map) → unchanged, asserted in Task 3 Step 5; change 4 (two sinks) → Tasks 1, 2, 5; change 5 (surface tool targeting + `done` refusal) → Task 3 Step 6 + Task 4 Step 2 (S1 refuses ALL non-Craft placement; the `done` gate is S3's when tiles become placeable). `onSelectSurface` → Task 4. Never wiring `onResetBoardPosition`/`onSetMaster` for view surfaces → holds trivially in S1 (no view surface exists yet); S2 must re-assert.
- Type consistency: `aspectOf(Pick<KvSurface,"id"|"fallbackAspect">)`, `boardMapFor(Pick<KvSurface,"id">)`, `resolveToolTarget → {rect, surface}`, `selectSurface(id)`, `RestOverlayTag` shared between Task 2 and Task 5, `mergeSurfaces(craft, extra)`.
- Known limitation stated, not hidden: the canvas has no automated test; Task 6 hands the checklist to Daffa.
