# KV Craft Resize Strip — S2 Read-only Strip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task (this project runs inline, no subagents). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Behind `KV_RESIZE_UNIFIED_CANVAS`, the Craft canvas draws every Resize tile of every Craft board as a `layout: "view"` surface in one vertical "Resizes" strip below the Craft boards, with its overlays (non-interactive), a divider, group headers when there is more than one parent, a per-tile header (reset-to-follow when detached, download), the tile status layer (Retry / Cancel), and the platform picker reachable from the Craft bottom nav. Nothing is editable on a tile yet.

**Architecture:** A pure `computeResizeStrip` lays surfaces out under the Craft bounding box from measured board metrics. `useResizeExportsForBoards` fetches exports with `useQueries` using the SAME query keys as `useResizeExports`, so the picker's mutations and the SSE stream update the strip through one cache. `KvCanvas` (which already owns `boards`) builds the surfaces + REST overlays and hands them to `KvFabricCanvas`'s S1 seam. Chrome is DOM in the layout positioned from `boardRects`. The tile board object is not draggable (S1 gate); REST overlays are forced non-interactive by a canvas prop until S3.

**Tech Stack:** TanStack Query v5 `useQueries`, Fabric v7, React 19, `bun test`.

**Spec:** `docs/superpowers/specs/2026-09-22-kv-craft-resize-strip-design.md` §"The strip (slice S2)".

## Global Constraints

- Branch `feature/daffa/vc-kv-craft-resize-strip` in `web/`; commit locally only; never push; never `git stash`.
- `bun test <files>`; `node ./node_modules/next/dist/bin/next build`; tsc gate = 9 errors in `KvFabricCanvas.tsx`, 999 repo-wide (baseline files in the scratchpad).
- **Strip layout is derived, never persisted.** No export id may ever reach `metadata.kv_canvas.artboards` — impossible by construction (S1: no `ensureBoardMap` for `docBoardId: null`), verified by the Postgres query in the spec.
- Never wire `onResetBoardPosition` / `onSetMaster` for a tile surface.
- Fail-CLOSED flag: `useExperimentalFeatureEnabled(MAJOR_FEATURE_FLAGS.KV_RESIZE_UNIFIED_CANVAS) === true`, AND on dev/staging the localStorage opt-in `kv-resize-unified-canvas === "on"` (same rule as `KvResizeCanvas.tsx:~453`).
- Tiles whose export is not `done` show the status layer and NO overlays.
- Only invariant pure tests; no RTL.

---

### Task 1: `computeResizeStrip` — pure layout

**Files:**
- Create: `web/src/components/studio/kv-generator/resizeStrip.ts`
- Test: `web/src/components/studio/kv-generator/resizeStrip.test.ts`

**Interfaces produced:**
```ts
export const STRIP_GAP = 160;   // world px between the Craft bbox bottom and the first tile (divider + header live here)
export const TILE_GAP = 96;     // world px between stacked tiles (room for a ghosted overflow)
export const GROUP_GAP = 64;    // extra world px before a new parent group's header
export type StripGroup = { parent: KvSurface; exports: KvResizeExport[] };
export type ResizeStripLayout = {
  surfaces: KvSurface[];                                   // one per export, in group order then row order
  dividerY: number | null;                                 // world y of the "Resizes" rule; null when no exports
  groups: { parentId: string; label: string; y: number }[];// world y of each group header (rendered only when groups.length > 1)
  byExportId: Record<string, { parentId: string; export: KvResizeExport }>;
};
export function computeResizeStrip(args: {
  craftRects: { x: number; y: number; width: number; height: number }[]; // world rects of the Craft boards (measured aspects)
  groups: StripGroup[];                                    // Craft board order
  boardWorldWidth: number;                                 // KvFabricCanvas's BOARD_WORLD_WIDTH (512) — passed in, not imported
}): ResizeStripLayout;
```
Surface fields: `id: export.id`, `docBoardId: null`, `layout: "view"`, `imageUrl: export.status === "done" ? export.imageUrl : null`, `fallbackAspect: export.width / export.height`, `label: export.name?.trim() || export.platformLabel`, `isActive: false`, `center` = column x (bbox left + boardWorldWidth/2) and running y. Height of a tile = `boardWorldWidth / fallbackAspect`.

- [ ] **Step 1: Failing test**

```ts
import { describe, it, expect } from "bun:test";
import { computeResizeStrip, STRIP_GAP, TILE_GAP, GROUP_GAP } from "./resizeStrip";
import type { KvSurface } from "./kvSurface";
import type { KvResizeExport } from "@/types/kv/resize";

const parent = (id: string): KvSurface => ({ id, docBoardId: id, layout: "doc", imageUrl: null, fallbackAspect: 1, label: `Board ${id}`, isActive: false, center: { x: 0, y: 0 } });
const exp = (id: string, w: number, h: number, extra: Partial<KvResizeExport> = {}): KvResizeExport => ({
  id, studioFileId: "f", parentGenerationId: "g", platformId: "instagram-post", name: null, platformLabel: "Instagram Post",
  platformGroup: "social-media", width: w, height: h, imageUrl: "https://x/a.png", status: "done", cropWindow: null,
  overlays: null, errorMessage: null, createdAt: "", updatedAt: "", ...extra,
});
const W = 512;

describe("computeResizeStrip", () => {
  it("returns an empty layout with no divider when there are no exports", () => {
    const out = computeResizeStrip({ craftRects: [{ x: 0, y: 0, width: W, height: W }], groups: [{ parent: parent("g1"), exports: [] }], boardWorldWidth: W });
    expect(out.surfaces).toEqual([]); expect(out.dividerY).toBeNull(); expect(out.groups).toEqual([]);
  });
  it("stacks tiles vertically under the Craft bbox, left-aligned, heights from aspect", () => {
    const craft = [{ x: 100, y: 50, width: W, height: 300 }, { x: 800, y: 0, width: W, height: 700 }];
    const out = computeResizeStrip({ craftRects: craft, groups: [{ parent: parent("g1"), exports: [exp("e1", 1080, 1080), exp("e2", 1080, 1920)] }], boardWorldWidth: W });
    const bboxBottom = 700; // max(y + h)
    expect(out.dividerY).toBe(bboxBottom + STRIP_GAP / 2);
    const [s1, s2] = out.surfaces;
    expect(s1.center.x).toBe(100 + W / 2);               // bbox left + half width
    expect(s1.center.y).toBe(bboxBottom + STRIP_GAP + W / 2); // first tile top = bottom + STRIP_GAP; square → h = W
    const s2h = W / (1080 / 1920);
    expect(s2.center.y).toBeCloseTo(bboxBottom + STRIP_GAP + W + TILE_GAP + s2h / 2, 6);
    expect(s1).toMatchObject({ docBoardId: null, layout: "view", isActive: false, label: "Instagram Post", imageUrl: "https://x/a.png" });
  });
  it("never depends on persisted state: same inputs → same centres, and exports keep row order within a group", () => {
    const g = { parent: parent("g1"), exports: [exp("b", 1, 1), exp("a", 1, 1)] };
    const a = computeResizeStrip({ craftRects: [{ x: 0, y: 0, width: W, height: W }], groups: [g], boardWorldWidth: W });
    const b = computeResizeStrip({ craftRects: [{ x: 0, y: 0, width: W, height: W }], groups: [g], boardWorldWidth: W });
    expect(a.surfaces.map((s) => [s.id, s.center])).toEqual(b.surfaces.map((s) => [s.id, s.center]));
    expect(a.surfaces.map((s) => s.id)).toEqual(["b", "a"]);
  });
  it("groups follow Craft board order with a header y per group, and adds GROUP_GAP between groups", () => {
    const out = computeResizeStrip({ craftRects: [{ x: 0, y: 0, width: W, height: W }], groups: [
      { parent: parent("g1"), exports: [exp("e1", 1, 1)] }, { parent: parent("g2"), exports: [exp("e2", 1, 1)] },
    ], boardWorldWidth: W });
    expect(out.groups.map((g) => g.parentId)).toEqual(["g1", "g2"]);
    expect(out.groups[1].y - out.groups[0].y).toBe(W + TILE_GAP + GROUP_GAP);
    expect(out.byExportId.e2.parentId).toBe("g2");
  });
  it("a pending tile has no imageUrl (the status layer draws instead) and a custom name wins over the platform label", () => {
    const out = computeResizeStrip({ craftRects: [{ x: 0, y: 0, width: W, height: W }], groups: [{ parent: parent("g1"), exports: [exp("e1", 1, 1, { status: "pending", name: "Hero banner" })] }], boardWorldWidth: W });
    expect(out.surfaces[0].imageUrl).toBeNull(); expect(out.surfaces[0].label).toBe("Hero banner");
  });
});
```

- [ ] **Step 2: Run → FAIL (module missing).** `cd web && bun test src/components/studio/kv-generator/resizeStrip.test.ts`

- [ ] **Step 3: Implement**

```ts
import { boardsBoundingBox } from "./boardLayout";
import type { KvSurface } from "./kvSurface";
import type { KvResizeExport } from "@/types/kv/resize";

/** World px between the Craft bbox bottom and the first tile; the divider
 *  sits halfway, the first tile's header just above the tile. */
export const STRIP_GAP = 160;
/** World px between stacked tiles — wide enough that a ghosted overflow does
 *  not sit inside the next tile. */
export const TILE_GAP = 96;
/** Extra world px before a new parent group's header. */
export const GROUP_GAP = 64;

export type StripGroup = { parent: KvSurface; exports: KvResizeExport[] };
export type ResizeStripLayout = {
  surfaces: KvSurface[];
  dividerY: number | null;
  groups: { parentId: string; label: string; y: number }[];
  byExportId: Record<string, { parentId: string; export: KvResizeExport }>;
};

/**
 * DERIVED layout for the "Resizes" strip — recomputed every render, never
 * stored (branch-B binding decision #3; spec §"The strip"). Tiles stack
 * vertically under the Craft boards' bounding box, left-aligned to it, one
 * column, grouped per parent board in Craft order and in export row order
 * within a group. The Craft boards are never moved by the strip; when they
 * move, the strip follows.
 */
export function computeResizeStrip(args: {
  craftRects: { x: number; y: number; width: number; height: number }[];
  groups: StripGroup[];
  boardWorldWidth: number;
}): ResizeStripLayout {
  const { craftRects, groups, boardWorldWidth: W } = args;
  const total = groups.reduce((n, g) => n + g.exports.length, 0);
  if (total === 0) return { surfaces: [], dividerY: null, groups: [], byExportId: {} };

  const bbox = boardsBoundingBox(craftRects) ?? { x: 0, y: 0, width: W, height: W };
  const left = bbox.x;
  const bottom = bbox.y + bbox.height;
  const cx = left + W / 2;

  const surfaces: KvSurface[] = [];
  const headers: ResizeStripLayout["groups"] = [];
  const byExportId: ResizeStripLayout["byExportId"] = {};
  let y = bottom + STRIP_GAP;
  let first = true;
  for (const g of groups) {
    if (g.exports.length === 0) continue;
    if (!first) y += GROUP_GAP;
    first = false;
    headers.push({ parentId: g.parent.id, label: g.parent.label, y });
    for (const ex of g.exports) {
      const aspect = ex.width > 0 && ex.height > 0 ? ex.width / ex.height : 1;
      const h = W / aspect;
      surfaces.push({
        id: ex.id,
        docBoardId: null,
        layout: "view",
        imageUrl: ex.status === "done" ? ex.imageUrl : null,
        fallbackAspect: aspect,
        label: ex.name?.trim() || ex.platformLabel,
        isActive: false,
        center: { x: cx, y: y + h / 2 },
      });
      byExportId[ex.id] = { parentId: g.parent.id, export: ex };
      y += h + TILE_GAP;
    }
  }
  return { surfaces, dividerY: bottom + STRIP_GAP / 2, groups: headers, byExportId };
}
```

- [ ] **Step 4: Run → PASS; commit**

```bash
cd web && bun test src/components/studio/kv-generator/resizeStrip.test.ts && git add src/components/studio/kv-generator/resizeStrip.ts src/components/studio/kv-generator/resizeStrip.test.ts && git commit -q -m "feat(web): computeResizeStrip — derived vertical layout for Resize tiles under the Craft boards

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 2: `useResizeExportsForBoards` — one cache with the picker

**Files:**
- Create: `web/src/lib/studio/kv/useResizeExportsForBoards.ts`

**Interfaces:**
- Consumes: `resizeExportsQueryKey(fileId, parentId)` and `listResizeExports(fileId, parentId)` (both exist; the hook `useResizeExports` uses exactly these, and `connectResizeStream` writes into the same keys).
- Produces: `export function useResizeExportsForBoards(fileId: string | null, parentIds: string[], enabled: boolean): Record<string, KvResizeExport[]>` — keyed by parent id; a parent with no data yet maps to `[]`.

- [ ] **Step 1: Implement (no test — a `useQueries` wrapper with no logic of its own; the key equality is asserted by importing the same function)**

```ts
import { useMemo } from "react";
import { useQueries } from "@tanstack/react-query";
import { listResizeExports } from "@/services/kv/api";
import type { KvResizeExport } from "@/types/kv/resize";
import { resizeExportsQueryKey } from "./useResizeExports";

/** Exports for MANY parent boards at once — the Craft "Resizes" strip. Uses
 *  the exact keys `useResizeExports` subscribes with, so the picker's
 *  mutations and the SSE stream (`connectResizeStream`) refresh the strip
 *  through the same cache entries; nothing here is a second source of truth.
 *  Polls while any row of a parent is pending/generating, like the hook. */
export function useResizeExportsForBoards(
  fileId: string | null,
  parentIds: string[],
  enabled: boolean
): Record<string, KvResizeExport[]> {
  const results = useQueries({
    queries: parentIds.map((parentId) => ({
      queryKey: resizeExportsQueryKey(fileId ?? "", parentId),
      queryFn: () => listResizeExports(fileId ?? "", parentId),
      enabled: enabled && Boolean(fileId),
      refetchInterval: (q: { state: { data?: KvResizeExport[] } }) =>
        q.state.data?.some((r) => r.status === "pending" || r.status === "generating") ? 2500 : false,
    })),
  });
  return useMemo(() => {
    const out: Record<string, KvResizeExport[]> = {};
    parentIds.forEach((id, i) => { out[id] = results[i]?.data ?? []; });
    return out;
    // results is a new array each render; its data identities are stable.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [parentIds.join("|"), ...results.map((r) => r.data)]);
}
```
Check `useResizeExports.ts:105` for the exact `refetchInterval` shape and mirror it (the type of `q` there is the authoritative one).

- [ ] **Step 2: tsc names the new file with zero errors; commit**

```bash
cd web && bunx tsc --noEmit -p tsconfig.json 2>&1 | grep useResizeExportsForBoards; git add src/lib/studio/kv/useResizeExportsForBoards.ts && git commit -q -m "feat(web): useResizeExportsForBoards — exports for every Craft board through the picker's own query keys

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 3: `KvFabricCanvas` — report board metrics; hold REST overlays inert

**Files:**
- Modify: `KvFabricCanvas.tsx` — props; a metrics-report effect next to the board-rects effect; a post-pass at the end of the overlay reconcile (right after `applyOverlayZOrder();`).

**Interfaces produced:**
```ts
  /** Measured board metrics (natural aspect + natural width) per surface id, as
   *  the images load. The host needs them to lay out DERIVED surfaces (the
   *  Resize strip) under the real Craft boards instead of metadata guesses. */
  onBoardMetricsChange?: (m: Record<string, { aspect: number; naturalWidth: number }>) => void;
  /** S2: REST overlays are drawn but not interactive. S3 flips this on. */
  restOverlaysInteractive?: boolean;
```

- [ ] **Step 1: Metrics effect** — after the `onBoardRectsChange` effect:

```ts
  useEffect(() => {
    if (!onBoardMetricsChange) return;
    const out: Record<string, { aspect: number; naturalWidth: number }> = {};
    for (const id of Object.keys(boardAspects)) {
      out[id] = { aspect: boardAspects[id], naturalWidth: boardNaturalWidths[id] ?? 0 };
    }
    onBoardMetricsChange(out);
  }, [boardAspects, boardNaturalWidths, onBoardMetricsChange]);
```

- [ ] **Step 2: Inert post-pass** — in the overlay reconcile, immediately after `applyOverlayZOrder();`:

```ts
    // S2: REST overlays render but cannot be selected or hit until S3 wires
    // their tools. Done here, after every per-type branch has set
    // selectable/evented for the cursor tool, so it wins regardless of type.
    if (!restOverlaysInteractive) {
      for (const o of canvas.getObjects()) {
        const d = (o as Tagged).data;
        if (d && "restSurfaceId" in d) o.set({ selectable: false, evented: false });
      }
    }
```
Add `restOverlaysInteractive` to the effect's deps. Destructure both props (default `restOverlaysInteractive = false`).

- [ ] **Step 3: tsc 9/999; eslint 0 errors; commit**

```bash
cd web && bunx eslint --fix src/components/studio/kv-generator/KvFabricCanvas.tsx >/dev/null; bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -c "KvFabricCanvas.tsx"; git add src/components/studio/kv-generator/KvFabricCanvas.tsx && git commit -q -m "feat(web): KvFabricCanvas reports measured board metrics and holds REST overlays inert until S3

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 4: `KvCanvas` builds the strip and feeds the seam

**Files:**
- Modify: `KvCanvas.tsx` — Props (~57-381), the Fabric branch (~1319+), imports.

**Interfaces:**
- Consumes: `computeResizeStrip` (T1), `useResizeExportsForBoards` (T2), `resolveTileOverlays` from `@/lib/studio/kv/overlayAspect`, `overlaysForResizeSource` from `@/lib/studio/kv/overlayMutations`, `surfaceFromBoard` + `boardWorldRect` (exist), `useExperimentalFeatureEnabled` + `MAJOR_FEATURE_FLAGS` (already imported at lines 22-23), `isDevelopmentOrStaging` from `@/lib/utils`.
- Produces props on `KvCanvas`:
```ts
  /** File id — the strip's export queries are keyed by it. */
  fileId?: string | null;
  /** Fires with the derived strip whenever it changes, so the layout can
   *  draw the DOM chrome (divider, headers, actions) from `boardRects`. */
  onResizeStripChange?: (strip: import("./resizeStrip").ResizeStripLayout | null) => void;
```
(`overlays` — the file-wide doc overlays — is already a prop.)

- [ ] **Step 1: Flag gate (mirror `KvResizeCanvas.tsx:~440-460`)**

```ts
  const unifiedFlagOn =
    useExperimentalFeatureEnabled(MAJOR_FEATURE_FLAGS.KV_RESIZE_UNIFIED_CANVAS) === true;
  const [unifiedDevOptIn, setUnifiedDevOptIn] = useState(false);
  useEffect(() => {
    try { setUnifiedDevOptIn(window.localStorage.getItem("kv-resize-unified-canvas") === "on"); }
    catch { setUnifiedDevOptIn(false); }
  }, []);
  // Fail-CLOSED, and on dev/staging (where the PostHog flag is forced on) the
  // localStorage opt-in alone decides — same rule as KvResizeCanvas.
  const stripEnabled =
    multiBoard && unifiedFlagOn && (!isDevelopmentOrStaging() || unifiedDevOptIn);
```

- [ ] **Step 2: Metrics state + exports + strip**

```ts
  const [boardMetrics, setBoardMetrics] = useState<Record<string, { aspect: number; naturalWidth: number }>>({});
  const parentIds = useMemo(() => (stripEnabled ? boards.map((b) => b.id) : []), [stripEnabled, boards]);
  const exportsByParent = useResizeExportsForBoards(fileId ?? null, parentIds, stripEnabled);

  const strip = useMemo(() => {
    if (!stripEnabled) return null;
    const craftSurfaces = boards.map(surfaceFromBoard);
    const craftRects = craftSurfaces.map((s) =>
      boardWorldRect(s.center, 512, boardMetrics[s.id]?.aspect ?? s.fallbackAspect)
    );
    return computeResizeStrip({
      craftRects,
      groups: craftSurfaces.map((parent) => ({ parent, exports: exportsByParent[parent.id] ?? [] })),
      boardWorldWidth: 512,
    });
  }, [stripEnabled, boards, boardMetrics, exportsByParent]);
  useEffect(() => { onResizeStripChange?.(strip); }, [strip, onResizeStripChange]);
```
`512` is `BOARD_WORLD_WIDTH`, private to `KvFabricCanvas`. Export it from `KvFabricCanvas.tsx` (`export const BOARD_WORLD_WIDTH = 512;`) and import it here rather than repeating the literal.

- [ ] **Step 3: REST overlays per tile (done tiles only)**

```ts
  const restOverlays = useMemo(() => {
    if (!strip) return undefined;
    const out: Record<string, StudioOverlay[]> = {};
    for (const s of strip.surfaces) {
      const entry = strip.byExportId[s.id];
      if (!entry || entry.export.status !== "done") continue;
      const parent = boards.find((b) => b.id === entry.parentId);
      if (!parent) continue;
      const m = boardMetrics[parent.id];
      if (!m || m.naturalWidth <= 0) continue; // source size unknown yet → draw the base only this frame
      const srcW = m.naturalWidth;
      const srcH = m.naturalWidth / m.aspect;
      const projectOverlays = overlaysForResizeSource(overlays ?? [], parent.id, parent.version_ids ?? null);
      out[s.id] = resolveTileOverlays(entry.export.overlays, projectOverlays, srcW, srcH, entry.export.width, entry.export.height);
    }
    return out;
  }, [strip, boards, boardMetrics, overlays]);
```

- [ ] **Step 4: Pass to `KvFabricCanvas` in the Fabric branch**

```tsx
              surfaces={strip?.surfaces}
              restOverlays={restOverlays}
              restOverlaysInteractive={false}
              onBoardMetricsChange={setBoardMetrics}
```
`multiBoardEnabled`-only: the Konva fallback branch gets nothing.

- [ ] **Step 5: tsc (KvCanvas 0 new; 999 total); commit**

```bash
cd web && bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -c "error TS"; git add src/components/studio/kv-generator/KvCanvas.tsx src/components/studio/kv-generator/KvFabricCanvas.tsx && git commit -q -m "feat(web): KvCanvas derives the Resize strip and feeds it to the canvas as view surfaces (flag-gated)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 5: `KvResizeStripChrome` — divider, headers, tile actions, status

**Files:**
- Create: `web/src/components/studio/kv-generator/KvResizeStripChrome.tsx`
- Create: `web/src/lib/studio/kv/useResizeTileActions.ts`

**Interfaces:**
- `useResizeTileActions(fileId)` → `{ retry(exportId, parentId), cancel(exportId, parentId), download(row, projectOverlays, srcW, srcH) }` calling `regenerateResizeExport`, `deleteResizeExport`/the cancel service used by `useResizeExports.cancel` (read `useResizeExports.ts:~380-430` and call the SAME service), then `qc.invalidateQueries({ queryKey: resizeExportsQueryKey(fileId, parentId) })`. `download` = `buildBoardStaticCanvas` + `flattenStaticCanvasToBlob` + `triggerBrowserDownload(blob, \`${row.platformId}.png\`)` exactly as `KvResizeCanvas.downloadOne` (`:1826-1862`) — move that flatten helper into `src/lib/studio/kv/flattenTile.ts` as `export async function flattenTileToBlob(args)` and make `KvResizeCanvas` call the shared one (no second copy).
- `KvResizeStripChrome` props:
```ts
{
  strip: ResizeStripLayout;
  boardRects: Record<string, { left: number; top: number; width: number; height: number }>; // screen rects from the canvas
  camera: { scale: number; x: number; y: number };   // to place the divider/headers: screenY = worldY * scale + y
  onRetry(exportId: string): void; onCancel(exportId: string): void;
  onDownload(exportId: string): void; onResetToFollow(exportId: string): void; // reset only when export.overlays !== null
  minChromeWidthPx?: number; // default 120 — below this projected tile width, hide the header actions AND the status buttons (closes branch-B open item 6)
}
```
Renders, absolutely positioned inside the canvas box (`pointer-events-none` wrapper; buttons `pointer-events-auto`):
  - divider: a 1px rule across the strip column at `dividerY` with the word "Resizes" centred (matches the mockup).
  - group header (parent label) at each `groups[i].y - 28`, only when `groups.length > 1`.
  - per tile (rect from `boardRects[export.id]`): right-aligned icon row at `top - 22`: `ArrowCounterClockwise` (title "Not following master — reset to follow", only when `export.overlays !== null`) and `DownloadSimple`; both hidden below `minChromeWidthPx`.
  - `KvBoardStatusLayer` for `status !== "done"` inside a wrapper sized to the rect (it returns null for `done`).
  The caption itself is already drawn by the canvas (S1's caption-only branch) — do NOT draw it twice.

- [ ] **Step 1: Write `useResizeTileActions` + move the flatten helper; tsc clean; commit**
- [ ] **Step 2: Write `KvResizeStripChrome`; tsc clean; commit**

### Task 6: Layout — mount the chrome, the picker in Craft, the nav button

**Files:**
- Modify: `KvGeneratorLayout.tsx` — `<KvCanvas …>` at ~7424 (add `fileId={fileId}`, `onResizeStripChange={setResizeStrip}`); render `<KvResizeStripChrome>` next to the comment-pin layer that already consumes `boardRects` (~2958); hoist the `KvResizePanel` JSX (`:7305-7392`) into `const platformPanelNode = (…)` and render it in the Craft branch too when `resizeStrip` is non-null; pass `platformPanelOpen`/`onTogglePlatformPanel` to the bottom nav in Craft (already passed at ~8370 — verify it is not gated by mode).
- Modify: `KvCanvasBottomNav.tsx:230` — `{(isResize || (isCraft && stripEnabled)) && onTogglePlatformPanel && (` where `stripEnabled?: boolean` is a new prop the layout passes (`resizeStrip !== null`).
- `camera` for the chrome: the layout already receives `onZoomScaleChange`; it needs `x/y` too — the canvas's `onBoardRectsChange` is enough for tiles, so pass `dividerY`/group `y` through screen space instead: extend T1's layout with nothing; in the chrome compute divider/header screen y from the FIRST tile's `boardRects` entry (`rect.top - (STRIP_GAP/2) * scale`) using `zoomScale` from the layout's existing `onZoomScaleChange` state. No new camera plumbing.
- Picker target = `viewedGeneration` (already what `useResizeExports(fileId, viewedGeneration?.id)` uses). Adding a size creates a pending tile under that board; pan-into-view is S3.

- [ ] **Step 1: Wire; tsc equal to baseline; eslint 0 errors; commit**

### Task 7: Gates, analytics, track

- [ ] **Step 1: Tests** — all S0–S2 test files in one `bun test` run (list from the S1 plan + `resizeStrip.test.ts`); `0 fail`.
- [ ] **Step 2: Build** — `node ./node_modules/next/dist/bin/next build` exit 0.
- [ ] **Step 3: Analytics** — invoke the `frndos-analytics-events` skill for the strip (new surface: strip rendered with N tiles; header actions). Existing resize events still fire through the same mutations.
- [ ] **Step 4: Track file** — status S2 done (local), add the S2 manual checklist:
  - flag ON via `localStorage.setItem("kv-resize-unified-canvas","on")` + reload; open a KV file with resizes → strip below boards, divider, tiles at their aspects, overlays drawn, pending tile shows status layer, Retry/Cancel work, download produces the flattened PNG, reset-to-follow appears only on a detached tile
  - two boards with resizes → two group headers; one board → no group header
  - Platform button visible in the Craft bottom nav; opens the picker for the active board; adding a size shows a pending tile
  - move a Craft board → strip follows; tiles cannot be dragged; tile overlays cannot be selected
  - **Postgres:** `select jsonb_pretty(metadata->'kv_canvas') from studio_files where id='<file>'` before/after — no export-id key in `artboards`, Craft centres unchanged
  - flag OFF → Craft identical to S1
- [ ] **Step 5: Commit**

---

## Self-review

- Spec §S2: producer (T1/T4), column layout derived (T1), divider + group header only when >1 (T5), tile header reset+download (T5 — the spec's "history" icon IS today's reset-to-follow `ArrowCounterClockwise`, shown only when detached; recorded as the interpretation), status layer (T5), hide chrome below a width threshold (T5 `minChromeWidthPx`, default 120 — Daffa adjusts against a real board), picker in Craft bottom nav for the active board (T6), grid behind (already: the canvas draws boards over the grid), fitAll unions the strip (S1: `boardRects` iterates `effectiveSurfaces` — holds), Craft free camera (unchanged), tab Resize stays (unchanged).
- Types: `ResizeStripLayout` shared T1→T4→T5→T6; `onBoardMetricsChange` T3→T4; `restOverlaysInteractive` T3→T4; `BOARD_WORLD_WIDTH` exported T4.
- Never wired for tiles: `onResetBoardPosition`, `onSetMaster` (T4 passes only `surfaces`/`restOverlays`).
- Open: `useQueries` per board vs one file-wide query — chosen per-board for cache unity with the picker + SSE stream (documented in T2).
