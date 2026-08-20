# KV Motion — Multi-Tile Canvas — Implementation Plan (web)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user choose several output sizes at the Motion entry point, see every size as a tile on one pannable canvas, author one animation across all tiles, and export one MP4 per tile.

**Architecture:** `resolveMotionTiles` / `buildMultiTileSnapshot` (pure, tested) own the data model. `KvMotionSizePicker` becomes multi-select. `KvMotionProjectsPanel` creates one project with N tiles. `KvMotionEditor` renders one `KvMotionTileStage` per tile in a horizontal world layout with a focus/poster playback model. `useCanvasCamera` learns a world bbox. `KvMotionExportDialog` renders N rows sequentially. No api change: `snapshot`/`timeline` stay opaque JSON (verified: `MaxJsonBytes`-only validation, no nested key rules).

**Tech Stack:** Next.js 16 / React 19 / TypeScript, TanStack Query v5, Konva (react-konva stages), Mediabunny/WebCodecs (existing encode path), `bun test` + `@testing-library/react` in jsdom.

**Spec:** `docs/superpowers/specs/2026-08-20-kv-motion-multi-tile-design.md`

## Global Constraints

- **Web only.** Do not touch `api/`. `snapshot` is opaque JSON there — verified: `StoreKvMotionProjectRequest` validates it as `['required','array', new MaxJsonBytes]` with no nested key rules, and `KvMotionProjectController::store` writes `$v['snapshot']` wholesale.
- **Test runner is `bun test`, never `bunx vitest`.** `bunfig.toml` preloads jest-dom.
- **`screen` is broken under bun's jsdom preload.** Always query via `within(document.body)`. Using `screen` causes every component test in the repo to fail, not just yours.
- **jsdom has no canvas 2D context.** No test may render a Konva stage or read pixels. Stage rendering stays behind DI seams exercised only with stubs.
- **Encoder ceiling:** longest edge ≤ `1920`, both axes even, minimum edge `16` — `videoSafeDims` already enforces this; every tile's `width`/`height` comes through it.
- **Snapshot byte budget:** `MaxJsonBytes::DEFAULT_MAX_BYTES = 524288` (512 KB). Never persist projected overlays — `tiles[].overlays` stays `null` in this phase.
- **Never `git stash`** to compare lint baselines. Use `git show HEAD:<path> > <path>.baseline.tsx` inside the repo, lint it, then delete.
- Commit after every task. Conventional commits, scope `web`.

## File Structure

| File | Responsibility |
|---|---|
| `src/types/kv/motionProject.ts` | Add `KvMotionTile`; `KvMotionSnapshot.tiles?: KvMotionTile[]` (optional). `target` stays. |
| `src/components/studio/kv-generator/motion/motionSnapshot.ts` | `buildMultiTileSnapshot` (new, plural) + `resolveMotionTiles` (new). `buildMotionSnapshot`/`resolveMotionTarget` untouched. |
| `src/components/studio/kv-generator/motion/tileLayout.ts` **(new)** | Pure world-space tile layout: bbox union, gutters, bottom alignment. |
| `src/components/studio/kv-generator/motion/KvMotionTileStage.tsx` **(new)** | One interactive stage per tile (fork of `KvResizeTileStage` rendering path + the editor's live-node wiring). |
| `src/components/studio/kv-generator/motion/KvMotionSizePicker.tsx` | Radio group → checkbox group; `onConfirm(options[])`; 8-tile cap. |
| `src/components/studio/kv-generator/motion/KvMotionProjectsPanel.tsx` | Create from N options; analytics gains `tile_count` + `platform_ids`. |
| `src/components/studio/kv-generator/motion/useCanvasCamera.ts` | `board` accepts a world bbox; `shouldStartPan` becomes multi-stage. |
| `src/components/studio/kv-generator/motion/KvMotionEditor.tsx` | N stages, focus model, poster throttle, per-tile `applyTimeline`. |
| `src/components/studio/kv-generator/motion/KvMotionExportDialog.tsx` | N rows, sequential renders, per-tile retained blobs. |
| `src/lib/analytics/kv-generator-events.ts` | `KvMotionProjectCreatedProps` gains `tile_count` + `platform_ids`; singular fields = first tile. |

---

### Task 1: `KvMotionTile` type + `resolveMotionTiles`

**Files:**
- Modify: `src/types/kv/motionProject.ts`
- Modify: `src/components/studio/kv-generator/motion/motionSnapshot.ts`
- Test: `src/components/studio/kv-generator/motion/motionSnapshot.test.ts` (extend)

**Interfaces:**
- Consumes: `PlatformId` (from `@/types/kv/resize`), `StudioOverlay`, `MotionTimeline`, existing `resolveMotionTarget`.
- Produces: `KvMotionTile`, `resolveMotionTiles(snapshot): KvMotionTile[]`.

- [ ] **Step 1: Write the failing tests** (extend `motionSnapshot.test.ts`)

```ts
import { resolveMotionTiles } from "./motionSnapshot";

describe("resolveMotionTiles", () => {
  it("returns a tiles project's tiles verbatim", () => {
    const tiles = [tile("a"), tile("b")];
    expect(resolveMotionTiles(snap({ tiles }))).toEqual(tiles);
  });

  it("synthesizes one tile from a target project", () => {
    const s = snap({
      target: { platform_id: "instagram-post", label: "Instagram Post", source: "resize" },
      board_width: 1080, board_height: 1080,
      base_image_url: "https://x/tile.png",
    });
    const out = resolveMotionTiles(s);
    expect(out).toHaveLength(1);
    expect(out[0].platform_id).toBe("instagram-post");
    expect(out[0].source).toBe("resize");
    expect(out[0].base_image_url).toBe("https://x/tile.png");
    expect(out[0].width).toBe(1080);
    expect(out[0].height).toBe(1080);
    expect(out[0].overlays).toBeNull();
    expect(out[0].timeline).toBeNull();
  });

  it("synthesizes one tile from a pre-picker project (no target)", () => {
    const s = snap({ base_image_url: "https://x/base.png" }); // 1080×566
    const out = resolveMotionTiles(s);
    expect(out).toHaveLength(1);
    expect(out[0].source).toBe("native");
    expect(out[0].platform_id).toBe("native");
  });

  it("never returns an empty array", () => {
    expect(resolveMotionTiles(snap({ tiles: [] }))).toHaveLength(1);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/motion/motionSnapshot.test.ts`
Expected: FAIL — `resolveMotionTiles` is not a function.

- [ ] **Step 3: Implement**

Add to `src/types/kv/motionProject.ts`:

```ts
/** One output size inside a multi-tile motion project. */
export type KvMotionTile = {
  key: string;
  platform_id: PlatformId | "native";
  label: string;
  source: "resize" | "master" | "native";
  base_image_url: string;
  width: number;
  height: number;
  /** Phase 2. Always `null` for now; `null` = follow the master. */
  overlays: StudioOverlay[] | null;
  /** Phase 3. Always `null` for now; `null` = follow the master timeline. */
  timeline: MotionTimeline | null;
};
```

Add `tiles?: KvMotionTile[];` to `KvMotionSnapshot` (keep `target?`).

In `motionSnapshot.ts`:

```ts
export function resolveMotionTiles(snapshot: KvMotionSnapshot): KvMotionTile[] {
  if (snapshot.tiles?.length) return snapshot.tiles;
  const t = resolveMotionTarget(snapshot);
  return [{
    key: t.id,
    platform_id: snapshot.target?.platform_id ?? "native",
    label: t.label,
    source: snapshot.target?.source ?? "native",
    base_image_url: snapshot.base_image_url,
    width: t.w,
    height: t.h,
    overlays: null,
    timeline: null,
  }];
}
```

- [ ] **Step 4: Run test to verify it passes**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web/src/types/kv/motionProject.ts web/src/components/studio/kv-generator/motion/motionSnapshot.ts web/src/components/studio/kv-generator/motion/motionSnapshot.test.ts
git commit -m "feat(web): add KvMotionTile + resolveMotionTiles — multi-size motion projects"
```

---

### Task 2: `buildMultiTileSnapshot`

**Files:**
- Modify: `src/components/studio/kv-generator/motion/motionSnapshot.ts`
- Test: `src/components/studio/kv-generator/motion/motionSnapshot.test.ts` (extend)

**Interfaces:**
- Consumes: `MotionSizeOption` (from `motionSizeOptions.ts`), `videoSafeDims` (implicitly via option.video).
- Produces: `buildMultiTileSnapshot({ options, nativeImageUrl, nativeWidth, nativeHeight, nativeOverlays }): KvMotionSnapshot`.

- [ ] **Step 1: Write the failing tests**

```ts
describe("buildMultiTileSnapshot", () => {
  const native = { nativeImageUrl: "https://x/master.png", nativeWidth: 1080, nativeHeight: 1080, nativeOverlays: [ov("o1")] };

  it("writes master fields from the board, never from a tile", () => {
    const s = buildMultiTileSnapshot({
      options: [option("a", "resize", "https://x/tile-a.png"), option("b", "master", "https://x/master.png")],
      ...native,
    });
    expect(s.base_image_url).toBe("https://x/master.png");
    expect(s.board_width).toBe(1080);
    expect(s.board_height).toBe(1080);
    expect(s.overlays).toEqual([ov("o1")]);
    expect(s.target).toBeUndefined();
  });

  it("maps options to tile descriptors with null override fields", () => {
    const s = buildMultiTileSnapshot({ options: [option("a", "resize", "https://x/tile-a.png")], ...native });
    expect(s.tiles).toHaveLength(1);
    expect(s.tiles![0]).toMatchObject({
      key: "a", platform_id: "a", source: "resize",
      base_image_url: "https://x/tile-a.png", overlays: null, timeline: null,
    });
    expect(s.tiles![0].width).toBe(1080);
    expect(s.tiles![0].height).toBe(1080);
  });

  it("keeps option order", () => {
    const s = buildMultiTileSnapshot({ options: [option("b"), option("a")], ...native });
    expect(s.tiles!.map((t) => t.key)).toEqual(["b", "a"]);
  });

  it("stays under the 512KB MaxJsonBytes budget for 8 tiles × 20 overlays", () => {
    const overlays = Array.from({ length: 20 }, (_, i) => ov(`o${i}`));
    const opts = Array.from({ length: 8 }, (_, i) => option(`p${i}`, "master", "https://x/m.png"));
    const s = buildMultiTileSnapshot({ options: opts, nativeImageUrl: "https://x/m.png", nativeWidth: 1080, nativeHeight: 1920, nativeOverlays: overlays });
    expect(JSON.stringify(s).length).toBeLessThan(524288);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

- [ ] **Step 3: Implement**

```ts
export function buildMultiTileSnapshot(args: {
  options: MotionSizeOption[];
  nativeImageUrl: string;
  nativeWidth: number;
  nativeHeight: number;
  nativeOverlays: StudioOverlay[];
}): KvMotionSnapshot {
  const { options, nativeImageUrl, nativeWidth, nativeHeight, nativeOverlays } = args;
  return {
    base_image_url: nativeImageUrl,
    board_width: nativeWidth,
    board_height: nativeHeight,
    overlays: nativeOverlays,
    tiles: options.map((o) => ({
      key: o.key,
      platform_id: o.platformId,
      label: o.label,
      source: o.source,
      base_image_url: o.baseImageUrl,
      width: o.video.w,
      height: o.video.h,
      overlays: null,
      timeline: null,
    })),
    // no `target` — multi-tile projects resolve via `tiles`
  };
}
```

- [ ] **Step 4: Run to verify it passes**

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(web): add buildMultiTileSnapshot — frozen multi-tile motion snapshots"
```

---

### Task 3: `tileLayout` — pure world-space layout

**Files:**
- Create: `src/components/studio/kv-generator/motion/tileLayout.ts`
- Test: `src/components/studio/kv-generator/motion/tileLayout.test.ts`

**Interfaces:**
- Consumes: nothing but dims.
- Produces:
  - `TILE_GUTTER = 80`
  - `layoutTiles(tiles: { width: number; height: number }[]): TilePlacement[]` where `TilePlacement = { index, x, y, width, height }` — bottom-aligned row, gutter between, x from left.
  - `worldBBox(placements): { width, height }` — union including one gutter at each end.

- [ ] **Step 1: Write the failing test**

```ts
describe("layoutTiles", () => {
  it("lays out a row bottom-aligned with gutters", () => {
    const p = layoutTiles([{ width: 1080, height: 1080 }, { width: 1080, height: 1920 }]);
    expect(p[0].x).toBe(80);
    expect(p[1].x).toBe(80 + 1080 + 80);
    expect(p[1].y).toBe(1080 - 1920); // bottom-aligned
    expect(worldBBox(p).width).toBe(80 + 1080 + 80 + 1080 + 80);
    expect(worldBBox(p).height).toBe(1920);
  });

  it("single tile equals its own dims plus gutters", () => {
    const p = layoutTiles([{ width: 1080, height: 1080 }]);
    expect(p[0].x).toBe(80);
    expect(worldBBox(p).height).toBe(1080);
  });

  it("handles an empty list", () => {
    expect(worldBBox(layoutTiles([]))).toEqual({ width: 0, height: 0 });
  });
});
```

- [ ] **Step 2: Run to verify it fails**

- [ ] **Step 3: Implement**

```ts
export const TILE_GUTTER = 80;

export type TilePlacement = { index: number; x: number; y: number; width: number; height: number };

export function layoutTiles(tiles: { width: number; height: number }[]): TilePlacement[] {
  let x = TILE_GUTTER;
  const maxH = Math.max(0, ...tiles.map((t) => t.height));
  return tiles.map((t, index) => {
    const p = { index, x, y: maxH - t.height, width: t.width, height: t.height };
    x += t.width + TILE_GUTTER;
    return p;
  });
}

export function worldBBox(placements: TilePlacement[]): { width: number; height: number } {
  if (placements.length === 0) return { width: 0, height: 0 };
  const maxX = Math.max(...placements.map((p) => p.x + p.width));
  const maxY = Math.max(...placements.map((p) => p.y + p.height));
  return { width: maxX + TILE_GUTTER, height: maxY };
}
```

- [ ] **Step 4: Run to verify it passes**

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(web): add tileLayout — world-space multi-tile layout math"
```

---

### Task 4: Picker → checkbox group + multi-select

**Files:**
- Modify: `src/components/studio/kv-generator/motion/KvMotionSizePicker.tsx`
- Test: `src/components/studio/kv-generator/motion/KvMotionSizePicker.test.tsx` (extend/rework)

**Interfaces:**
- `onConfirm: (options: MotionSizeOption[]) => void` (was single option).
- `MAX_TILES = 8` exported from the same file.

**Behaviour:**
- `role="group"` + `aria-label="Video sizes"` on the list; each row `role="checkbox"`, `aria-checked`.
- Roving `tabIndex`: Arrow/Home/End move the highlight only; **Space toggles** the checked row. Click does both.
- `checkedKeys: Set<string>` initialised with `native`; `highlightedKey: string` initialised `native`.
- Confirm disabled when `checkedKeys.size === 0`; footer label `Create motion · N size(s)`.
- Rows past `MAX_TILES` checked → remaining unchecked rows get `aria-disabled` + inline reason.
- Preview shows the **highlighted** row; `blocked` applies to any **checked** resize-source row whose preview failed.

- [ ] **Step 1: Write the failing tests**

```ts
it("toggles with Space without moving the highlight", () => { /* … */ });
it("moves the highlight with Arrow without toggling", () => { /* … */ });
it("confirm disabled at 0 checked", () => { /* … */ });
it("caps at 8; past the cap unchecked rows are aria-disabled", () => { /* … */ });
it("onConfirm receives options in group order", () => { /* … */ });
```

- [ ] **Step 2: Run to verify they fail**

- [ ] **Step 3: Implement.** Replace the radio-group state with `checkedKeys` + `highlightedKey`. Keep the keyboard handler, but split its effects: Arrow keys update `highlightedKey` (and focus the row); Space toggles the focused row's membership in `checkedKeys`. Keep the preview cache, the `blocked` computation (now over the checked set), and the group-order guarantee by deriving confirm payload from `allOptions.filter(o => checkedKeys.has(o.key))`.

- [ ] **Step 4: Run to verify they pass** — includes the existing picker tests (they assert the old radio API; rework them to the new roles).

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(web): multi-select Motion size picker with 8-tile cap"
```

---

### Task 5: Panel create from N options + analytics

**Files:**
- Modify: `src/components/studio/kv-generator/motion/KvMotionProjectsPanel.tsx`
- Modify: `src/lib/analytics/kv-generator-events.ts`

**Interfaces:**
- `createMutation.mutationFn: (options: MotionSizeOption[]) => …` calling `buildMultiTileSnapshot`.
- `KvMotionProjectCreatedProps` gains `tile_count: number` and `platform_ids: string[]`; `platform_id`/`base_source` keep meaning "first tile".

- [ ] **Step 1: Implement**

```ts
const createMutation = useMutation({
  mutationFn: async (options: MotionSizeOption[]) => {
    if (!activeBoard || !activeGenerationId) throw new Error("No board to animate yet.");
    return createProjectFn(fileId, {
      boardGenerationId: activeGenerationId,
      snapshot: buildMultiTileSnapshot({
        options,
        nativeImageUrl: activeBoard.imageUrl,
        nativeWidth: activeBoard.width,
        nativeHeight: activeBoard.height,
        nativeOverlays: activeBoard.overlays,
      }),
      timeline: DEFAULT_TIMELINE(),
    });
  },
  onSuccess: (project, options) => {
    const first = options[0];
    trackKvMotionProjectCreated({
      file_id: fileId,
      board_generation_id: project.boardGenerationId,
      overlay_count: activeBoard?.overlays.length ?? 0,
      platform_id: first.platformId,
      base_source: first.source,
      tile_count: options.length,
      platform_ids: options.map((o) => o.platformId),
    });
    // …unchanged
  },
});
```

- [ ] **Step 2: Update `KvMotionProjectCreatedProps`** (add the two fields, comment that singular = first tile).

- [ ] **Step 3: Update panel tests** to pass an options array and assert the analytics payload.

- [ ] **Step 4: Commit**

```bash
git commit -am "feat(web): create multi-tile motion projects from the size picker"
```

---

### Task 6: `useCanvasCamera` — world bbox + multi-stage hit-test

**Files:**
- Modify: `src/components/studio/kv-generator/motion/useCanvasCamera.ts`
- Test: `src/components/studio/kv-generator/motion/useCanvasCamera.test.tsx` (extend)

**Interfaces:**
- `board` accepts `{ width, height }` (unchanged, world bbox passed in).
- `shouldStartPan` contract stays `(e) => boolean`; the **caller** now resolves which stage the pointer is over (the hook stays Konva-free by design).
- **No refactor of the hook body needed for the bbox itself** — `fitCamera`, `zoomAt`, `panBy` all already operate on arbitrary rectangles. The change is (a) callers pass the bbox, (b) the refit effect's deps become `board.width`/`board.height` of the bbox (already true), (c) the caller's `shouldStartPan` becomes multi-stage.

- [ ] **Step 1: Write the failing tests** (pure camera maths over a bbox: fit centres the union; zoom anchors correctly; the existing tests keep passing untouched).

- [ ] **Step 2: Implement** — extend `useCanvasCamera.test.tsx` with a bbox-fit case. The hook body itself only needs its doc comment updated; the real work lands in Task 7's `shouldStartPan`.

- [ ] **Step 3: Commit**

```bash
git commit -am "test(web): cover camera fit over a world bbox"
```

---

### Task 7: `KvMotionTileStage` + editor multi-stage

**Files:**
- Create: `src/components/studio/kv-generator/motion/KvMotionTileStage.tsx`
- Modify: `src/components/studio/kv-generator/motion/KvMotionEditor.tsx`

**Interfaces:**
- `KvMotionTileStage({ tile, placement, focused, onFocus, base, sampled, onOverlayTransformed, selectTrack })` — renders one `Konva.Stage` at `tile.width × tile.height`, positioned absolutely at `placement.x/y` inside the camera layer, wires the editor's live-node handlers when `focused`.

**Editor changes:**
- `resolveMotionTiles(project.snapshot)` instead of `resolveMotionTarget`.
- `placements = layoutTiles(tiles)`; `bbox = worldBBox(placements)`; camera board = bbox.
- Per-tile `previewOverlays = remapSnapshotForRatio(snapshot, tile.width, tile.height)` and `previewTimeline = remapTimelineForRatio(...)` (already the pattern; now memoised per tile).
- **Focus model:** `focusedTileKey` state (default first tile). Clicking a tile focuses it (and does NOT start a drag). Ring on the focused tile.
- **`shouldStartPan`:** resolve which tile container the pointer is in (clamp pointer to each container's rect), hit-test that tile's stage with the existing per-stage conversion, return `true` for gutters/labels/outside. Uses a registry of `{ containerRef, stage }` per tile.
- **Poster throttle:** a shared rAF budget. During playback, unfocused tiles' `applyTimeline` + `batchDraw` runs at ≤ ~10 fps; the focused tile runs every frame. On playhead settle (pause/scrub-end/edit), all tiles update immediately.

- [ ] **Step 1: Implement `KvMotionTileStage`** — fork the render path from `KvResizeTileStage` (single-layer stage, base image + overlay nodes) and add the live-node wiring from `KvMotionEditor`'s current build effect (draggable, click→selectTrack, dragend→onOverlayTransformed). Props carry the pose + handlers so the component stays dumb.

- [ ] **Step 2: Rework the editor's stage effect** — from one `buildBoardStage` call to N `KvMotionTileStage`s. The existing effect's cleanup pattern (destroy on deps change) becomes per-tile; `setStage`/`setNodeById` become a per-tile registry keyed by `tile.key`.

- [ ] **Step 3: Playback** — the current `applyTimeline` + `batchDraw` effect becomes per-tile with the throttle. Keep the playhead/audio logic untouched.

- [ ] **Step 4: Focus UX** — click-to-focus, ring styling, drags only on the focused tile (guard `onOverlayTransformed` + `node.draggable` by `focused`).

- [ ] **Step 5: Run the existing editor tests** — they assert single-stage behaviour; update the fixtures to the multi-tile shape (a 1-tile project resolves through `resolveMotionTiles` identically to today).

- [ ] **Step 6: Commit**

```bash
git commit -am "feat(web): multi-tile canvas with focus/poster playback model"
```

---

### Task 8: Export dialog — N rows, sequential

**Files:**
- Modify: `src/components/studio/kv-generator/motion/KvMotionExportDialog.tsx`
- Test: `src/components/studio/kv-generator/motion/KvMotionExportDialog.test.tsx` (extend; if none exists, create — the dialog has heavy DI seams already: `exportRatioFn`, `uploadAssetFn`, `createExportFn`, `listExportsFn`).

**Behaviour:**
- `RatioState` becomes `Map<tileKey, RatioState>`; `target` → `resolveMotionTiles(snapshot)`.
- Renders strictly sequential (one shared `AbortController`); Cancel skips the rest.
- Per-tile retained blobs: a failed upload on tile k keeps `blob` for that tile only; Retry/download act per tile. `exportRatioFn` call count proves no re-render on Retry.
- Audio decoded+mixed once before the loop, passed to every tile.
- Footer: one row per tile with status/progress/Retry/Download.

- [ ] **Step 1: Write the failing tests**

```ts
it("renders N rows, one per tile", () => { /* … */ });
it("renders sequentially — call order on a stubbed exportRatioFn", () => { /* … */ });
it("a mid-run render failure does not abort the remaining tiles", () => { /* … */ });
it("Cancel aborts the in-flight render and skips the rest", () => { /* … */ });
it("Retry re-uploads without re-rendering (exportRatioFn call count unchanged)", () => { /* … */ });
```

- [ ] **Step 2: Implement** — map the existing single-row logic over `resolveMotionTiles(snapshot)`, keeping `uploadAndRecord`/`handleRetryUpload` per-tile. The existing "internally still iterates a ratios array" machinery is the skeleton.

- [ ] **Step 3: Run to verify they pass** (plus the existing dialog tests, updated for the row-per-tile shape).

- [ ] **Step 4: Commit**

```bash
git commit -am "feat(web): export one MP4 per motion tile, sequentially"
```

---

### Task 9: Analytics types + wiring complete

**Files:**
- Modify: `src/lib/analytics/kv-generator-events.ts`

- [ ] **Step 1: Implement** — add `tile_count: number` and `platform_ids: string[]` to `KvMotionProjectCreatedProps` with a doc comment that `platform_id`/`base_source` describe the first tile (keeps existing dashboards reading a value).

- [ ] **Step 2: Run the full motion test suite**

```bash
cd web && bun test src/components/studio/kv-generator/motion/ src/lib/video-editor/
```

Expected: all green, including the untouched `useCanvasCamera`, `motionSnapshot`, and picker suites.

- [ ] **Step 3: Commit**

```bash
git commit -am "feat(web): multi-tile motion analytics"
```

---

### Task 10: Final verification

- [ ] **Step 1: Full web test suite**

```bash
cd web && bun test
```

- [ ] **Step 2: Typecheck**

```bash
cd web && bunx tsc --noEmit
```

- [ ] **Step 3: Lint the touched files** (baseline-compare only what you changed; never `git stash`).

- [ ] **Step 4: Manual smoke** (dev server, real browser — jsdom cannot cover this):
  - Create a motion project with 3 sizes (native + 2 resizes) → canvas shows 3 tiles bottom-aligned, gutters visible.
  - Pan/zoom across the world bbox; zoom pill works.
  - Play: focused tile animates at full rate, others track at reduced rate; pause settles all.
  - Click an unfocused tile → focuses; drag an overlay → lands correctly at any zoom.
  - Export: 3 rows render sequentially; each uploads; `kv_motion_exports` gains 3 rows.
  - Open an OLD single-size project → renders as one tile, exports identically to before.
  - DevTools: confirm no snapshot PATCH exceeds 512 KB.

- [ ] **Step 5: Manual regression** — Resize surface untouched: run a resize, verify tiles/layout/crop all behave as before.
