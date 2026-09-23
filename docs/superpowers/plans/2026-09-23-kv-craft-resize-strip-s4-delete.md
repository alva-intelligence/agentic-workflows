# KV Craft Resize Strip — S4 Delete the Resize Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task (inline, no subagents — the layout file is 8.5k lines and every task touches it; a fresh subagent per task re-reads it each time for nothing). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Craft strip becomes the only Resize surface: the Resize tab, the per-tile editor path and the `KV_RESIZE_UNIFIED_CANVAS` flag are removed, and the three things only the old tab still did (tile comment pins, the Safe Zones tile preview, the Standalone Resizer's home) move onto the strip.

**Architecture:** Nothing new is built. Four behaviours the Resize tab owned are re-homed onto seams the strip already publishes — tile screen rects (`onBoardRectsChange` already includes tile surfaces keyed by export id), the active tile (`KvCanvas.activeTileRow`), the picker (`platformPanelNode`) and `canvasMode: "craft"`. Then the tab's mount, its 6.4k-line component closure and the flag are deleted, tsc-driven: delete the closure, let the compiler name every straggler, and fix each straggler by pointing it at the strip's equivalent or deleting it too. `KvKonvaCanvas` stays unless the reviewer who requested the kill switch confirms (Task 10, gated).

**Tech Stack:** Next.js 16 / React 19 / TypeScript, Fabric v7 (`KvFabricCanvas`), TanStack Query v5, Zustand (`useKvResizeStore`), bun test, PostHog (`kv-generator-events.ts`).

**Spec:** `docs/superpowers/specs/2026-09-22-kv-craft-resize-strip-design.md` (§Slices row S4, §Documents to change). PRD: `frnd/docs/prd/kv-resize-unified-canvas.md` — the FR-11/12/13 revision in this branch of the workspace repo (commit "docs(prd): kv-resize-unified-canvas — FR-11..14 revised for the Craft strip") **must be re-signed by fahrizky + Jeff before Task 6 starts**. Tasks 1–5 are additive and safe to land under the flag; Tasks 6–9 are the deletion.

## Global Constraints

- Branch `feature/daffa/vc-kv-craft-resize-strip` in `web/`, pushed to origin after each verified task; **no PR to develop from this plan** (Daffa opens the PR). Never `git stash`. Workspace-repo docs stay local (Daffa pushes).
- Gates after EVERY task: `bunx tsc --noEmit -p tsconfig.json` total **≤ 999** (the baseline; deletion tasks will LOWER it — record the new number in the commit message, never let it rise); `bunx eslint --fix <touched files>` adds no warning; `bun test <explicit files>` (never a directory: `find … -name "*.test.ts" -print0 | xargs -0 bun test`); `node ./node_modules/next/dist/bin/next build` exit 0 at the end of Task 7 and Task 9.
- Test policy of this track: only invariant pure tests; no RTL / component tests for the canvas. Deleted components take their RTL tests with them.
- Konva stays in `package.json` (Motion, `renderBoardStage.ts`). `KvKonvaCanvas` is Task 10 only, and only on the reviewer's written confirmation.
- Copy the strip's existing conventions: tile overlay ids reach the layout as CANVAS ids `<tileId>/<overlayId>` (`src/lib/studio/kv/tileOverlayId.ts`); REST rows never see the prefix.
- The api is untouched: `StudioFileController` keeps accepting `canvas_mode: resize` (old files carry it); the web maps it to `craft` (Task 3).
- Analytics: every event the spec's S4 row says must still fire is listed in Task 9 step 4; run that list before calling S4 done.

---

### Task 0: Entry gate — sign-offs, baselines, the owed DB query

**Files:** none changed in `web/`; `web/docs/tracks/kv-craft-resize-strip.track.md` (session-log entry).

- [ ] **Step 1: Confirm the two sign-offs exist, in writing, before any deletion task.** Paste into the track file's session log: (a) fahrizky + Jeff re-sign-off of the revised PRD (FR-11..14, §UI/UX, M3, AC-9/10 — see the PRD commit named in the header), (b) the KvKonvaCanvas reviewer's answer (keep / delete). Without (a), stop after Task 5. Without (b), skip Task 10.

- [ ] **Step 2: Record the suite + tsc baseline** (this is what "no new failures" is measured against):

```bash
cd web
bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -c "error TS"          # expect 999
find src -name "*.test.ts" -print0 | xargs -0 bun test 2>&1 | grep -E "^ *[0-9]+ (pass|fail)$"
find src/components/studio/kv-generator -name "*.test.tsx" -print0 | xargs -0 bun test 2>&1 | grep -E "^ *[0-9]+ (pass|fail)$"
```

Write the four numbers (tsc, pure pass/fail, component pass/fail) into the track file.

- [ ] **Step 3: Run the owed S2/S3 database query on a file that has strip tiles** (the HUT-RI file `01m0cd21htgn1f6tdfcgp3sztc` qualifies):

```bash
cd api && TELESCOPE_ENABLED=false php artisan tinker --execute='
$f = DB::selectOne("select metadata->\x27kv_canvas\x27 as kc from studio_files where id = ?", ["01m0cd21htgn1f6tdfcgp3sztc"]);
$kc = json_decode($f->kc ?? "{}", true);
$ids = array_keys($kc["artboards"] ?? []);
$exports = array_column(DB::select("select id from kv_resize_exports where studio_file_id = ?", ["01m0cd21htgn1f6tdfcgp3sztc"]), "id");
echo "artboard keys: ", count($ids), " | export ids among them: ", count(array_intersect($ids, $exports)), "\n";'
```

Expected: `export ids among them: 0`. Any other number is a failure of S2/S3's core invariant — fix before continuing.

- [ ] **Step 4: Commit the track entry** — `git commit -m "docs(web): S4 entry gate — sign-offs recorded, baselines, kv_canvas query clean"`.

---

### Task 1: Tile comment pins render in the strip

Today pins on `tile.<exportId>` parts are drawn only in Resize mode, from DOM-measured `tileRects`. The strip already publishes every tile's screen rect through the same `onBoardRectsChange` channel as boards (`KvCanvas.handleBoardRectsChange` forwards the engine's rects, keyed by surface id = export id). So one pure helper resolves a part to a rect from `boardRects`, for both `board.` and `tile.` parts, and the layout's three resize-only branches collapse.

**Files:**
- Create: `web/src/lib/studio/kv/commentPartRect.ts`
- Test: `web/src/lib/studio/kv/commentPartRect.test.ts`
- Modify: `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx` — `rectForThread` (anchor: `const rectForThread = useCallback(`), `draftRect` (anchor: `const draftRect = (() => {`), `visibleCommentThreads` (anchor: `if (canvasMode === "resize") {` inside it), `scopedCommentPart` (anchor: `if (canvasMode !== "resize") return commentContext.part;`).

**Interfaces:**
- Produces: `rectForCommentPart(part: string | null | undefined, rects: Record<string, ScreenRect>): ScreenRect | null` where `ScreenRect = { left: number; top: number; width: number; height: number }`; `isTilePart(part)`, `tileIdOfPart(part)`.

- [ ] **Step 1: Write the failing test**

```ts
// web/src/lib/studio/kv/commentPartRect.test.ts
import { describe, it, expect } from "bun:test";
import { rectForCommentPart, isTilePart, tileIdOfPart } from "./commentPartRect";

const rects = {
  "01BOARD": { left: 10, top: 20, width: 300, height: 400 },
  "01EXPORT": { left: 500, top: 20, width: 200, height: 355 },
};

describe("rectForCommentPart", () => {
  it("resolves a board part and a tile part from the same rect map", () => {
    expect(rectForCommentPart("board.01BOARD", rects)).toEqual(rects["01BOARD"]);
    expect(rectForCommentPart("tile.01EXPORT", rects)).toEqual(rects["01EXPORT"]);
  });
  it("returns null for an unknown id, a non-part, or no part", () => {
    expect(rectForCommentPart("tile.GONE", rects)).toBeNull();
    expect(rectForCommentPart("motion.abc", rects)).toBeNull();
    expect(rectForCommentPart(null, rects)).toBeNull();
  });
  it("classifies tile parts", () => {
    expect(isTilePart("tile.01EXPORT")).toBe(true);
    expect(isTilePart("board.01BOARD")).toBe(false);
    expect(tileIdOfPart("tile.01EXPORT")).toBe("01EXPORT");
    expect(tileIdOfPart("board.01BOARD")).toBeNull();
  });
});
```

- [ ] **Step 2: Run it** — `bun test src/lib/studio/kv/commentPartRect.test.ts` → FAIL (module not found).

- [ ] **Step 3: Implement**

```ts
// web/src/lib/studio/kv/commentPartRect.ts
/**
 * Screen rect a comment pin hangs off, resolved from the ONE rect map the
 * canvas publishes for every surface it draws — Craft boards (`board.<id>`)
 * and strip tiles (`tile.<exportId>`) alike. Before the strip, tile pins
 * needed DOM-measured rects from the Resize tab; that path is gone.
 */
export type ScreenRect = { left: number; top: number; width: number; height: number };

export function isTilePart(part: string | null | undefined): boolean {
  return typeof part === "string" && part.startsWith("tile.");
}

export function tileIdOfPart(part: string | null | undefined): string | null {
  return isTilePart(part) ? (part as string).slice("tile.".length) : null;
}

export function rectForCommentPart(
  part: string | null | undefined,
  rects: Record<string, ScreenRect>
): ScreenRect | null {
  if (!part) return null;
  const id = part.startsWith("board.")
    ? part.slice("board.".length)
    : part.startsWith("tile.")
      ? part.slice("tile.".length)
      : null;
  return id ? (rects[id] ?? null) : null;
}
```

- [ ] **Step 4: Run it** → PASS.

- [ ] **Step 5: Layout — `rectForThread`.** Replace the body (currently: resize branch reading `tileRects`, then the `board.` branch, then `return commentPartRect;`) with:

```ts
  const rectForThread = useCallback(
    (thread: CommentThreadModel) =>
      rectForCommentPart(anchorPart(thread.parent.anchor), boardRects) ??
      commentPartRect,
    [commentPartRect, boardRects]
  );
```

`boardRects` already holds tile rects while the strip is live (the canvas publishes every surface). Import `rectForCommentPart, isTilePart, tileIdOfPart` from `@/lib/studio/kv/commentPartRect`.

- [ ] **Step 6: Layout — `draftRect`.** Replace the resize branch (`if (canvasMode === "resize") { return commentTileId ? (tileRects[commentTileId] ?? null) : null; }`) and the `board.` branch with one line before the existing fallback:

```ts
    const fromPart = rectForCommentPart(draftPart, boardRects);
    if (fromPart) return fromPart;
```

Keep whatever fallback follows (`commentPartRect ?? null`).

- [ ] **Step 7: Layout — `visibleCommentThreads`.** Delete the `if (canvasMode === "resize") { … }` block. In the remaining filter, replace

```ts
      const part = anchorPart(anchor);
      if (!part?.startsWith("board.")) return false;
      const boardId = part.slice("board.".length);
      if (!boardRects[boardId]) return false; // Board not on screen.
```

with

```ts
      const part = anchorPart(anchor);
      // A tile pin is scoped to its tile: shown whenever that tile is on screen.
      // Tile snapshots carry no version chain, so version scoping applies to
      // board pins only (the tile's parent version is what the anchor stored).
      if (isTilePart(part)) return !!boardRects[tileIdOfPart(part) as string];
      if (!part?.startsWith("board.")) return false;
      const boardId = part.slice("board.".length);
      if (!boardRects[boardId]) return false; // Board not on screen.
```

Remove `canvasMode` and `sourceVersionIds` from that memo's deps if nothing else in it reads them (eslint will say).

- [ ] **Step 8: Layout — `scopedCommentPart`.** Replace

```ts
    if (canvasMode !== "resize") return commentContext.part;
    return commentTileId ? tilePart(commentTileId) : null;
```

with

```ts
    return commentTileId ? tilePart(commentTileId) : commentContext.part;
```

(`commentTileId` is set by `handlePlaceTileComment`, which the strip already calls through `onPlaceTileComment`; it is cleared with `setCommentTileId(null)` on mode change — keep that effect, and ALSO clear it in `handlePlaceComment` (the board variant, anchor `const handlePlaceComment = useCallback(`) with `setCommentTileId(null);` as its first statement so a board pin after a tile pin does not stay tile-scoped.)

- [ ] **Step 9: Delete the DOM tile-rect machinery**: the `tileRects` state (`const [tileRects, setTileRects] = useState<`), `resizeTileIds`, `resizeTileKey`, and the `requestAnimationFrame` measuring effect (`useEffect(() => { if (canvasMode !== "resize" || resizeTileKey === "") return;` … `cancelAnimationFrame`). `setTilePlatforms` / `tilePlatforms` (rowId → platformId "published by the Resize surface") — replace its source: in `KvCanvas` the strip already knows every export; publish `onStripExportsChange` (exists) and in the layout derive `tilePlatforms` with `useMemo(() => Object.fromEntries(stripExports.map((r) => [r.id, r.platformId])), [stripExports])`. Delete the `setTilePlatforms` state.

- [ ] **Step 10: Gate.** `bunx tsc --noEmit -p tsconfig.json` (≤ 999; unused-variable errors here are the compiler telling you what else to delete), eslint on the layout (no NEW warnings — the layout has 13 pre-existing `exhaustive-deps` warnings; compare counts), `bun test src/lib/studio/kv/commentPartRect.test.ts`.

- [ ] **Step 11: Commit** — `feat(web): strip tiles render and receive comment pins from the canvas rect map`. Push.

Manual check for the track file: open a file with tiles, comment tool, click a tile → pin lands on the tile and survives pan/zoom; a pre-existing tile thread from the old Resize tab shows on its tile.

---

### Task 2: Safe Zones preview follows the active strip tile

The Safe Zones manager previews `resizeActiveTileImageUrl` in Resize mode (`activeBoardImageUrl={canvasMode === "resize" ? resizeActiveTileImageUrl : …}`), fed by `KvResizeCanvas.onActiveTileChange(tileId, imageUrl)`, which also sets `lastGuideBoardIdRef` so guides apply to the tile. The strip knows its active tile (`activeTileRow` in `KvCanvas`).

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvCanvas.tsx` — new prop `onActiveTileChange?: (tileId: string | null, imageUrl: string | null) => void;` next to `onStripExportsChange`; effect publishing it.
- Modify: `KvGeneratorLayout.tsx` — pass the prop to `<KvCanvas …>` (anchor: `onStripExportsChange={setStripExports}`); simplify the two consumers.

**Interfaces:**
- Produces: `onActiveTileChange(tileId, imageUrl)` — `imageUrl` is the tile row's `imageUrl` (null for a layer-composed tile; the panel falls back to the board thumbnail exactly as today when it is null).

- [ ] **Step 1: KvCanvas prop + publish.** Add to the props type (beside `onStripExportsChange`):

```ts
  /** The strip's active tile (or null) with its rendered image, for chrome
   *  that previews "the thing being edited" — the Safe Zones manager. */
  onActiveTileChange?: (tileId: string | null, imageUrl: string | null) => void;
```

Destructure it, and after the `activeTileRow` definition add:

```ts
  useEffect(() => {
    onActiveTileChange?.(activeTileRow?.id ?? null, activeTileRow?.imageUrl ?? null);
  }, [activeTileRow?.id, activeTileRow?.imageUrl, onActiveTileChange]);
```

- [ ] **Step 2: Layout.** Pass `onActiveTileChange={(tileId, imageUrl) => { if (tileId) lastGuideBoardIdRef.current = tileId; setResizeActiveTileImageUrl(imageUrl); }}` on `<KvCanvas …>`. Change the Safe Zones consumer to

```tsx
          activeBoardImageUrl={
            resizeActiveTileImageUrl ??
            displayedGen?.thumbnail_url ??
            displayedGen?.image_url ??
            null
          }
```

and delete the effect `useEffect(() => { if (canvasMode !== "resize") setResizeActiveTileImageUrl(null); }, [canvasMode]);` — the canvas now publishes null itself when no tile is active.

- [ ] **Step 3: Gate + commit** — `feat(web): Safe Zones previews the active strip tile`. Push.

---

### Task 3: A persisted `canvas_mode: "resize"` opens Craft

Files saved while the Resize tab existed carry `metadata.canvas_mode = "resize"`; after S4 that mode has no surface. The api keeps accepting the value (`in:sketch,craft,resize,motion`); the web maps it on read and never writes it again.

**Files:**
- Create: `web/src/lib/studio/kv/seedCanvasMode.ts` + `seedCanvasMode.test.ts`
- Modify: `KvGeneratorLayout.tsx` — the seed effect (anchor: `const seed = persistedCanvasMode ?? latestGenerationModeForSeed;`), the `canvasMode` state type, `handleCanvasModeChange` (`keepsExplicitPinForOutput` line), the `useEffect` that redirects `resizeStripActive && canvasMode === "resize"` (delete — Task 6 removes `resizeStripActive`; the mapper makes it unreachable).
- Modify: `web/src/services/kv/api.ts` `patchStudioFileCanvasMode` parameter type → `"sketch" | "craft" | "motion"` (return type keeps `"resize"` — the server may still echo it for old files).
- Modify: `web/src/types/studio.ts:277` — leave `canvas_mode?: "sketch" | "craft" | "resize" | null` (it is the SERVER's shape; old files carry it).

- [ ] **Step 1: Test**

```ts
// web/src/lib/studio/kv/seedCanvasMode.test.ts
import { describe, it, expect } from "bun:test";
import { seedCanvasMode } from "./seedCanvasMode";

describe("seedCanvasMode", () => {
  it("passes the three live modes through", () => {
    expect(seedCanvasMode("sketch")).toBe("sketch");
    expect(seedCanvasMode("craft")).toBe("craft");
    expect(seedCanvasMode("motion")).toBe("motion");
  });
  it("maps the retired resize tab to craft (the strip lives there)", () => {
    expect(seedCanvasMode("resize")).toBe("craft");
  });
  it("ignores anything else", () => {
    expect(seedCanvasMode(null)).toBeNull();
    expect(seedCanvasMode(undefined)).toBeNull();
    expect(seedCanvasMode("banana")).toBeNull();
  });
});
```

- [ ] **Step 2: Run → FAIL. Implement:**

```ts
// web/src/lib/studio/kv/seedCanvasMode.ts
export type LiveCanvasMode = "sketch" | "craft" | "motion";

/** Where a file opens. `resize` is the retired Resize tab: its tiles now live
 *  in the Craft canvas (the "Resizes" strip), so a file last saved there
 *  opens in Craft. Unknown values seed nothing (caller keeps its default). */
export function seedCanvasMode(
  seed: string | null | undefined
): LiveCanvasMode | null {
  switch (seed) {
    case "sketch":
    case "craft":
    case "motion":
      return seed;
    case "resize":
      return "craft";
    default:
      return null;
  }
}
```

- [ ] **Step 3: Run → PASS.**

- [ ] **Step 4: Layout.** Replace the seed effect's `if (seed === "craft" || seed === "resize" || seed === "sketch" || seed === "motion") { setCanvasMode(seed); }` with `const mode = seedCanvasMode(seed); if (mode) setCanvasMode(mode);`. Change `useState<"sketch" | "craft" | "resize" | "motion">(standaloneResizer ? "resize" : "sketch")` to `useState<LiveCanvasMode>(standaloneResizer ? "craft" : "sketch")` (the Standalone Resizer's home is Task 4; this line is its first half) and `canvasModeRef`'s type likewise. In `handleCanvasModeChange`, `(next === "resize" || next === "motion") && pinIsExplicitRef.current` → `next === "motion" && pinIsExplicitRef.current`. Delete the redirect effect (`if (resizeStripActive && canvasMode === "resize") handleCanvasModeChange("craft", …)`).

- [ ] **Step 5: Follow the compiler.** `bunx tsc --noEmit -p tsconfig.json` now lists every comparison `canvasMode === "resize"` / `!== "resize"` as a type error (the union no longer contains it). Resolve each as follows — this list is the layout's complete set at the time of writing (line numbers drift; anchors don't):
  - `canvasMode === "resize" || canvasMode === "motion"` (style-key reset effect) → `canvasMode === "craft" || canvasMode === "motion"` stays as is with `"resize"` removed.
  - `overlayPanelsAvailable = canvasMode !== "resize" && canvasMode !== "motion"` → `canvasMode !== "motion"`.
  - `chatVisibleBoxes`: replace `if (canvasMode === "resize") { … }` with `if (armedRegenerate && strip tile)`: `if (armedRegenerate && stripExports.some((r) => r.id === armedRegenerate)) { return boxesForExport(boxesByExportId, armedRegenerate).filter((b) => !b.id.includes("__obj")); }` (the strip's armed tile owns the composer's regions, exactly as the tab's did).
  - `onRemoveBox` / `onClearBoxes` (`if (canvasMode === "resize") { if (!armedRegenerate) return; … }`) → same condition as above: `if (armedRegenerate && stripExports.some((r) => r.id === armedRegenerate))`.
  - `stripArmed = canvasMode === "craft" && resizeStripActive; if (canvasMode !== "resize" && !stripArmed) return null;` → `if (canvasMode !== "craft") return null;` (Task 6 deletes `resizeStripActive`; do the simplification now).
  - `useEffect(() => { if (canvasMode !== "resize") return; setLayersOpen(false); setSelected(null); }, …)` → delete.
  - `overlayEditingPanelsVisible = propertiesPanelVisible || (canvasMode === "resize" && layersOpen)` → `propertiesPanelVisible`.
  - `trackKvSafeZonesPanelOpened({ surface: canvasMode === "resize" ? "resize" : "craft" })` and `trackKvSafeZonePresetApplied({ …, surface: … })` → `surface: "craft"`.
  - `resizeDocUndoRef` effect (`if (!kvDoc || canvasMode !== "resize") return;`), `resizeUndoApiRef`, `handleResizeUndoApiChange`, `resizeEditDomainRef`, `handleResizeEditDomainChange`, and the Cmd+Z branch `canvasModeRef.current === "resize" ? resizeEditDomainRef.current === "master" ? … : …` → delete all of them; the Cmd+Z router keeps its existing `tileCtx` branch (strip tiles) and the doc branch. Also delete `resizeEditDomainRef.current = "master";` inside `handleCommitProjectOverlays`.
  - `KvCanvasTopNav`'s `resizeEnabled={!resizeStripActive}` → remove the prop here now (Task 6 removes it from the nav).
  The `canvasMode === "resize" ? (<KvResizeCanvas …/>) : …` mount is Task 7's — leave it compiling by casting nothing; if tsc rejects the comparison, change the branch condition to `false ? (` temporarily is NOT acceptable — instead delete the whole `: canvasMode === "resize" ? ( … )` JSX branch now (its props reference handlers deleted above anyway). Keep the `KvResizeCanvas` import until Task 7 only if something else still uses `MASTER_ROW_ID`: move `MASTER_ROW_ID` to `web/src/lib/studio/kv/commentPartRect.ts` as `export const MASTER_ROW_ID = "master";` **after reading its current value in `KvResizeCanvas.tsx`** (`grep -n "export const MASTER_ROW_ID" KvResizeCanvas.tsx`) — keep the value byte-identical, it is baked into stored comment anchors.

- [ ] **Step 6: Gate + commit** — `feat(web): retired canvas_mode "resize" opens Craft; layout drops its resize-mode branches`. Push.

---

### Task 4: The Standalone Resizer lives on the Craft strip

`/studio/resizer/[file_id]` mounts `KvGeneratorLayout` with `standaloneResizer`, pinned to `canvasMode: "resize"`, mode switch hidden, upload-first dropzone until a source exists. After S4 its home is Craft with the strip: one board (the upload) plus its tiles, picker open by default, mode switch still hidden.

**Files:**
- Modify: `KvGeneratorLayout.tsx` — initial mode (done in Task 3 step 4), the picker default, the `standaloneResizer ? (<KvUploadBaseBlock …/>) : (` branch (anchor: `) : standaloneResizer ? (`), `showModeSwitch={!standaloneResizer}` (keep), `refusePsdOutsideCraft` copy (keep).
- Test: `web/src/lib/studio/kv/backTarget.test.ts` exists — unchanged behaviour, run it.

- [ ] **Step 1: Picker default.** The strip-in-Craft rule "picker starts closed" (the `stripWasActiveRef` effect) is wrong for the Resizer, whose whole purpose is the picker. Replace that effect with a single initial value: `const [platformPanelOpen, setPlatformPanelOpen] = useState(standaloneResizer);` (anchor: `const [platformPanelOpen, setPlatformPanelOpen] = useState(true);`) and delete the `stripWasActiveRef` effect.

- [ ] **Step 2: Upload-first branch.** Keep the `standaloneResizer ? (<KvUploadBaseBlock …/>)` branch as the no-source state — it already renders inside the Craft branch's `viewedGeneration ? … : …` ternary? **Verify:** read 30 lines above the anchor. If the dropzone branch is reachable only from the deleted Resize-mode JSX, re-attach it: in the Craft branch, where `KvCanvas` mounts, wrap as `{standaloneResizer && !viewedGeneration ? (<div className="absolute inset-0 flex items-center justify-center p-8">…same KvUploadBaseBlock…</div>) : (<KvCanvas …/>)}`. Copy the existing `KvUploadBaseBlock` props verbatim (`onUpload={handleUploadBase}`, `onUploadPsd={handleDropPsdOnCanvas}`, `busy={uploadingBase}`, no `onDecomposeUpload`).

- [ ] **Step 3: Resizer semantics on the Craft chrome.** With `standaloneResizer`: hide the Craft-only affordances that make no sense on a finished upload — the "+" variant button and the chat's Craft edit flow are already gated by `onCreateVariant` / `craftBlocked` (an upload is `imported_from_upload`); verify by opening a resizer file after Task 7 and listing anything that offers to regenerate the board. Fix each by passing `undefined` for that callback when `standaloneResizer` (pattern already used for `onDecomposeUpload`). Record what you found in the track file — this is a checklist, not a code list, because the Resizer never rendered the Craft chrome before.

- [ ] **Step 4: Gate + `bun test src/lib/studio/kv/backTarget.test.ts` + commit** — `feat(web): Standalone Resizer opens on the Craft strip with the picker open`. Push.

---

### Task 5: The picker is always available in Craft (flag removed from the read path)

The flag currently gates whether the strip exists at all (`KvCanvas.stripEnabled = multiBoard && unifiedFlagOn && (!isDevelopmentOrStaging() || unifiedDevOptIn)`), and the layout mirrors it as `resizeStripActive`. S4 makes the strip unconditional. This task removes the gate everywhere it is READ; Task 7 deletes the constant.

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvCanvas.tsx` — `stripEnabled`, `unifiedFlagOn`, `unifiedDevOptIn`, `onResizeStripEnabledChange` (prop + effect).
- Modify: `KvCanvasBottomNav.tsx` — prop `stripEnabled` (three reads: `activeId`, `onChange`, the Resize button gate).
- Modify: `KvCanvasTopNav.tsx` — prop `resizeEnabled`, `RESIZE_TAB`, the `...(resizeEnabled ? [RESIZE_TAB] : [])` spread, the `CanvasMode` type (`"resize"` out), the `canvasMode !== "resize" && canvasMode !== "motion"` gate on the upscale download → `canvasMode !== "motion"`.
- Modify: `KvGeneratorLayout.tsx` — `resizeStripActive` state + every read (`stripEnabled={canvasMode === "craft" && resizeStripActive}`, `{canvasMode === "craft" && resizeStripActive && platformPanelNode}`, `onResizeStripEnabledChange`, the send-to-mode branch `if (mode === "resize" && resizeStripActive)`).

- [ ] **Step 1: KvCanvas.** `const stripEnabled = multiBoard;` — delete `unifiedFlagOn`, `unifiedDevOptIn` and their effect, the `useExperimentalFeatureEnabled` import if now unused, and the `onResizeStripEnabledChange` prop + the effect that calls it. Keep `multiBoard` as the gate: a single-board legacy file has no strip (unchanged behaviour).

- [ ] **Step 2: Bottom nav.** Remove the `stripEnabled` prop; the three reads become `isCraft && platformPanelOpen`, `isCraft && platformPanelOpen`, `isCraft && onTogglePlatformPanel`.

- [ ] **Step 3: Top nav.** Delete `RESIZE_TAB`, the `resizeEnabled` prop and its spread; `CanvasMode = "sketch" | "craft" | "motion"`; the mode switch keeps `MOTION_TAB` only (`PopPresence show={showModeSwitch && canvasMode !== "sketch"}` stays: Motion is still a tab).

- [ ] **Step 4: Layout.** Delete `resizeStripActive`/`setResizeStripActive` and `onResizeStripEnabledChange={setResizeStripActive}`; `stripEnabled` prop removed from `<KvCanvasBottomNav>`; `{canvasMode === "craft" && platformPanelNode}`; in the send-to-mode handler `if (mode === "resize" && resizeStripActive)` → `if (mode === "resize")` (the `onSendToMode` type still offers `"resize"` — it now means "pin + open picker", which is what the board menu's "Send to Resize" item does; keep the label, it is the PRD's FR-14 entry point).

- [ ] **Step 5: Gate + commit** — `feat(web): the Resize strip is unconditional in Craft; Resize tab removed from the mode switch`. Push.

Manual check: with `localStorage kv-resize-unified-canvas` REMOVED, a multi-board file shows the strip and the Resize button; the mode switch shows Motion only.

---

### Task 6: Move `MASTER_ROW_ID` and the last shared helpers out of the doomed files

Before deleting, relocate the two things kept files import from doomed files (found by the closure script in Task 7 step 1 — re-run it; at the time of writing):

- `MASTER_ROW_ID` (layout ← `KvResizeCanvas.tsx`) — moved in Task 3 step 5 if not already; verify with `grep -rn "MASTER_ROW_ID" src --include=*.ts --include=*.tsx | grep -v KvResizeCanvas`.
- `applyMaxQualityScaling` — `fabricExport.ts` (kept) names it. Locate the definition: `grep -rn "export function applyMaxQualityScaling\|export const applyMaxQualityScaling" src`. If it lives in a doomed file (`resizeApron.ts` / `tileFidelity.ts`), move the function verbatim (with its doc comment and any pure test that covers it) to `web/src/lib/studio/kv/maxQualityScaling.ts`, update `fabricExport.ts`'s import, and run `bun test src/components/studio/kv-generator/fabricExport.test.ts src/components/studio/kv-generator/fabricExport.runs.test.ts`.

- [ ] **Step 1: Do the two relocations above; tsc; commit** — `refactor(web): relocate MASTER_ROW_ID and applyMaxQualityScaling ahead of the Resize tab deletion`. Push.

---

### Task 7: Delete the Resize tab and the per-tile path

**Files:** everything the closure script lists (at the time of writing, 19 modules / 8 906 lines — recompute, do not trust the list), their tests, the flag constant, the two `localStorage` opt-ins.

- [ ] **Step 1: Compute the closure** (save as `/tmp/s4-closure.py`, run from `web/`):

```python
import re,glob,os
K="src/components/studio/kv-generator/"
roots=[K+r for r in ["KvResizeCanvas.tsx","KvTileOverlayEditor.tsx","KvResizeResultRow.tsx","KvResizeOriginalRow.tsx","KvResizeUnifiedCanvas.tsx"] if os.path.exists(K+r)]
def imports_of(path):
    s=open(path).read(); out=[]
    for m in re.finditer(r'from "(\./[^"]+|\.\./[^"]+|@/[^"]+)"', s):
        spec=m.group(1); p="src/"+spec[2:] if spec.startswith("@/") else os.path.normpath(os.path.join(os.path.dirname(path), spec))
        for c in [p+".ts",p+".tsx",p+"/index.ts",p+"/index.tsx"]:
            if os.path.isfile(c): out.append(c); break
    return out
srcs=[f for f in glob.glob("src/**/*.ts*", recursive=True) if ".test." not in f]
importers={}
for f in srcs:
    for d in imports_of(f): importers.setdefault(d,set()).add(f)
dead=set(roots); frontier=list(dead)
while frontier:
    f=frontier.pop()
    for d in imports_of(f):
        if d in dead or not (d.startswith(K) or d.startswith("src/lib/studio/kv/") or d.startswith("src/store/kv/")): continue
        if importers.get(d,set()) <= dead: dead.add(d); frontier.append(d)
for f in sorted(dead): print(f, sum(1 for _ in open(f)))
print("--- still imported from outside:")
for r in roots: print(r, sorted(importers.get(r,set())-dead))
```

Expected after Tasks 1–6: "still imported from outside" is empty for every root. If the layout still imports `KvResizeCanvas`, a Task 3/6 step was skipped — go back.

- [ ] **Step 2: Delete the closure and its tests.** `git rm` every listed module. Then delete the test files whose subject is gone: `KvResizeCanvas.*.test.tsx`, `KvTileOverlayEditor*.test.tsx`, `KvResizeOriginalRow.test.tsx`, `KvResizeResultRow.test.tsx`, `KvResizeTileStage.test.tsx`, `KvResizeViewport.test.tsx` (once `KvResizeViewport.tsx` is in the closure — it is imported by the layout for `KvResizeFocusApi` today; delete that import and re-run step 1), plus any `*.test.ts` whose import target no longer exists (`bun test` reports "Cannot find module" — that is the list).

- [ ] **Step 3: Delete the flag.** `MAJOR_FEATURE_FLAGS.KV_RESIZE_UNIFIED_CANVAS` and its comment in `src/lib/featureFlags/constants.ts`; grep `kv-resize-unified-canvas` and `kv-resize-unified-spike` — both localStorage keys go with `KvCanvas` (Task 5) and `KvResizeCanvas` (this task); nothing else may reference them.

- [ ] **Step 4: Follow the compiler.** `bunx tsc --noEmit -p tsconfig.json > /tmp/tsc.txt; grep -c "error TS" /tmp/tsc.txt` — the total must be **below** 999 (deleted files carried some of the baseline's errors). Every remaining NEW error is a straggler; fix by pointing at the strip's equivalent or deleting the dead code (typical: `handleResizeFocusApiChange`, `resizeFocusApiRef`, `masterEditEnabled`, `sourceVersionIds` if only the tab read it — check `KvShareClient`/motion first, `tilePlatforms` if Task 1 missed it).

- [ ] **Step 5: Prune `useKvResizeStore`.** For each field of the store (`selectedPlatformIds`, `togglePlatform`, `clearSelection`, `resizePrompt`, `armedRegenerate`, `armRegenerate`, `disarmRegenerate`, `toggleRegenerate`, `boxesByExportId`, `setBoxesForExport`, `clearBoxesForExport`, `sendBoxesForExport`, `unmarkRegionEdited`, `activeBoxId`, `setActiveBoxId`, `regionEditedExportIds`): `grep -rn "\b<field>\b" src --include=*.ts --include=*.tsx | grep -v useKvResizeStore.ts | grep -v ".test."`. A field with zero readers outside the store is deleted with its test cases. Do NOT delete a field read by `resizeSendTarget.ts`, `useResizeExports.ts`, `KvCanvas.tsx` or the layout.

- [ ] **Step 6: Analytics stragglers.** `src/lib/studio/kv/useResizeTileUpscales.ts` sends `canvas_mode: "resize"` → `"craft"` (the download dropdown now lives in the strip). Leave `KvCanvasMode` in `kv-generator-events.ts` and `KvSharePhase`/`KvGenerationMode` in the types alone — `"resize"` remains a valid PHASE (share links, generation mode, ready-to-share) even though it is no longer a canvas mode.

- [ ] **Step 7: Gates.** tsc (record the new total in the commit body), `bunx eslint --fix` on every touched file (no new warnings; the layout count must not rise above its Task 0 number), the full pure suite and the kv-generator component suite via `find … -print0 | xargs -0 bun test` (compare with Task 0: no NEW failures, fewer files), then `node ./node_modules/next/dist/bin/next build` exit 0.

- [ ] **Step 8: Commit** — `feat(web): delete the Resize tab and the per-tile editor path (S4)` with the deleted-file list and line count in the body. Push.

---

### Task 8: Documents

**Files:** `web/docs/tracks/kv-craft-resize-strip.track.md`, `web/docs/tracks/kv-resize-unified-canvas.track.md`, workspace repo `docs/superpowers/HANDOFF-kv-canvas-unification.md`, `docs/superpowers/specs/2026-08-10-kv-canvas-surface-unification-design.md`, and the PRD (already revised in this branch — flip its status once the sign-off lands).

- [ ] **Step 1: Track (strip).** Status table: S4 → `done (<commit>)`; add the S4 session-log entry with the deleted-file list, the tsc before/after numbers, and the three re-homed behaviours (tile pins, Safe Zones preview, Standalone Resizer). Fold the "STILL OWED" checklist into a final "S4 acceptance" list (the PRD's AC-10 wording).
- [ ] **Step 2: Track (unified canvas).** Close-out line: "M3 delivered by the strip (S4), not by a `canvasMode:"resize"` merge — see the revised PRD FR-12".
- [ ] **Step 3: Handoff.** In `HANDOFF-kv-canvas-unification.md` replace the "S3b … and S4 … are not started" sentence with the S4 state and the tech-debt pointer (overflow hit-test).
- [ ] **Step 4: Spec 2026-08-10.** Append the note the strip spec asks for: "two views" became "one view, participation per surface"; withdraw §"Keeping the list feel".
- [ ] **Step 5: PRD.** Change `status: review` → `approved` and fill the re-sign-off line only when fahrizky + Jeff have signed.
- [ ] **Step 6: Commit** (web repo pushed; workspace repo local).

---

### Task 9: Whole-slice review + PostHog verification

- [ ] **Step 1: Whole-slice review** (the track records six invariant misses that only a whole-slice review caught). Dispatch `superpowers:code-reviewer` on `git diff <Task 0 commit>..HEAD` with the spec and this plan; fix every finding graded must-fix before Step 2.
- [ ] **Step 2: Runtime checklist** (Daffa, recorded in the track file): open a multi-board file — strip visible, picker via the Resize button and via "Send to Resize"; a stored-`resize` file opens in Craft; the Standalone Resizer opens with the picker and no mode switch; comment pin on a tile; Safe Zones manager previews the active tile; the Motion size picker still lists resize tiles; the share page still shows the `resize` phase.
- [ ] **Step 3: PostHog Live Events** (project `FRnD_OS` / 389744) while doing Step 2 — each of these must appear: `kv_generator.resize_requested`, `resize_succeeded`/`resize_failed` (one of), `resize_strip_toggled`, `resize_tile_overlays_edited`, `resize_tile_renamed`, `resize_cancelled`, `resize_tile_duplicated` (source `craft_strip`), `master_pushed_to_tiles`, `resize_region_box_committed`, `ready_to_share_toggled` (phase `resize`). Then archive the `show-kv-resize-unified-canvas` flag definition in PostHog and add the taxonomy-doc rows still owed from the strip hardening commit.
- [ ] **Step 4: Track file:** S4 acceptance list ticked; `status: completed` on the strip track only when Daffa's PR to develop is merged.

---

### Task 10 (GATED): Delete `KvKonvaCanvas`

**Only with the reviewer's written "delete" from Task 0 step 1.** `KvKonvaCanvas.tsx` (2 604 lines) is the legacy fallback engine `KvCanvas` still mounts by flag; Motion and `renderBoardStage.ts` use Konva directly and are NOT affected.

- [ ] **Step 1:** In `KvCanvas.tsx` remove the `KvKonvaCanvas` dynamic import and the fallback branch (`<KvKonvaCanvas …>`); the `KvZoomApi` type it imports from `./KvKonvaCanvas` moves to `web/src/components/studio/kv-generator/kvCanvasApis.ts` (verbatim) with every other importer updated (`grep -rn 'from "./KvKonvaCanvas"' src`).
- [ ] **Step 2:** Re-run the Task 7 closure script with `roots=["KvKonvaCanvas.tsx"]`; delete the closure and its tests; Konva itself stays.
- [ ] **Step 3:** Gates as Task 7 step 7; commit `feat(web): delete the Konva fallback canvas (S4, reviewer-approved)`; push.

---

## Self-review against the spec

- Spec S4 row: Resize tab ✔ (Tasks 5, 7), `KvResizeCanvas` row path ✔ (7), `KvResizeViewport` ✔ (7 step 2), `KvTileOverlayEditor` ✔ (7), `KvResizeTileStage` ✔ (closure), `resizeApron` ✔ (closure), `applyMaxQualityScaling` — relocated not deleted (Task 6), because `fabricExport.ts`, which the strip's download uses, still calls it; noted. `KvKonvaCanvas` only after confirmation ✔ (Task 10). Konva stays ✔. Flag removed ✔ (5, 7). Build clean ✔ (7). No new suite failures ✔ (0, 7). Resize PostHog events still fire ✔ (9).
- Spec §Documents to change: PRD ✔ (revised in-branch; sign-off is Task 0/8), surface-unification spec ✔ (8), handoff ✔ (8), unified-canvas track ✔ (8).
- Behaviours only the tab had, found during inventory and covered: tile comment pins (Task 1), Safe Zones tile preview (Task 2), persisted `resize` mode (Task 3), Standalone Resizer (Task 4). Not carried over on purpose: the tab's "master edit domain" undo switch (the strip's Cmd+Z already routes by active tile), the bulk ZIP download dropdown (`KvResizeDownloadDropdown`, only reachable from the tab — the per-tile download and the ZIP endpoint remain; a strip-level ZIP entry point is a separate small feature, note it in the PRD's Out of Scope).
- Types used consistently: `ScreenRect` (Task 1) matches the layout's existing rect shape; `LiveCanvasMode` (Task 3) is the state type used by Tasks 4–5; `onActiveTileChange(tileId, imageUrl)` (Task 2) is the only new canvas prop.
