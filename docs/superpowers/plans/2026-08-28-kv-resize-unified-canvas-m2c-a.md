# KV Resize Unified Canvas — M2c-a (Shape Tool + Comment Pins) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the unified Resize canvas a tool layer, and port the two tools that carry no Craft risk — shape placement and comment pins.

**Architecture:** The unified canvas (`KvResizeUnifiedCanvas`) can select, drag/scale/rotate, commit, reflect a host selection, and reveal a board. It has no concept of a *tool*. The per-tile editor (`KvTileOverlayEditor`, 2419 lines) does: it branches on a `tool` prop for `"frame" | "shape" | "image" | "text" | "comment"` and renders a DOM gesture layer over its canvas. This slice introduces the tool seam on the unified canvas and ports the two cheapest, lowest-risk tools through it.

**Why this split.** M2c as a whole is the largest remaining slice, and its frame tool is the one piece that touches `boxPromptUi.tsx` — imported by `KvFabricCanvas.tsx`, which serves Craft in production (PRD risk R-1). Measured reference counts in `KvTileOverlayEditor.tsx`: frame tool **110**, comment pins **9**, shape tool via `ShapeDraftPreview`/`defaultShapePayload` (neither imported by `KvFabricCanvas`). Splitting on that line means this slice can land with zero Craft blast radius, and the frame tool gets its own slice with its own review attention.

**Tech Stack:** Next.js, React, TypeScript, Fabric v7, `bun test`.

**Spec:** `frnd/docs/prd/kv-resize-unified-canvas.md` (approved). Delivers the shape-tool and comment-pin halves of FR-9.

**Base branch:** `feature/daffa/vc-kv-resize-unified-canvas` — one branch carrying M1 + M2a + M2b. **No browser pass has been done on any of them.**

---

## Global Constraints

Every task's requirements implicitly include this section.

- **Test runner is `bun test`, run from `web/`.** NOT `bunx vitest`. Pure `.ts` suites import from `"bun:test"`; component `.tsx` suites import from `"vitest"`.
- **Never modify these — imported by the production Craft canvas (`KvFabricCanvas.tsx`):** `fabricExport.ts`, `ghostOverlay.ts`, `overlayGeometry.ts`, `overlayMutations.ts`, `overlayAspect.ts`, `overlaySelection.ts`, `overlayAlign.ts`, `overlayClipboard.ts`, `boxPromptUi.tsx`, `useTileOverlayHistory.ts`, `focusCamera.ts`. Import freely; edit none. **`boxPromptUi.tsx` in particular is out of scope for this entire slice** — it belongs to M2c-b.
- **Never modify the per-tile path:** `KvTileOverlayEditor.tsx`, `KvResizeTileStage.tsx`, `KvResizeViewport.tsx`, `resizeApron.ts`. Read them for patterns; edit none.
- **Never clamp coordinates.** Off-frame is intended and must survive every read and write.
- **Board-strict routing.** Master board → Yjs doc; tile board → per-row REST snapshot. A shape placed on a board commits to that board's backend and no other.
- **`null` (inheriting) and `[]` (deliberately emptied) are different states.** Never conflate.
- **Flag-off behaviour must be byte-identical.**
- **No new type errors in touched files; eslint clean.**
- **Never write a raw control character into source** — use the escape form.
- **Do NOT use `git stash`** for baseline comparison. Copy files aside with `cp` and restore with `cp`. This repo has a documented incident where stash/pop corrupted files with conflict markers.
- **Every new test must be MUTATION-PROVEN.** Break the implementation, observe the test fail for the right reason, restore, re-run. Show both outputs.

### Test-infrastructure warning — EIGHT incidents in this milestone

bun's mock registry is process-global and load order is NOT alphabetical. Every one of these has actually happened here:
- A partial `mock.module("@/lib/featureFlags", …)` broke unrelated suites, and was simultaneously *load-bearing* for two others that had no flag control of their own.
- A divergent factory for a shared specifier flipped a production feature flag for unrelated suites.
- A suite passed in isolation while silently blanking another suite's tests.
- A test **filename** determined whether it collided.
- A NEW test file mocking `./KvResizeUnifiedCanvas` shifted load order and blanked `KvResizeUnifiedCanvas.test.tsx` entirely.

Therefore: **prefer extending an existing proven-safe suite over creating a new file.** `KvResizeUnifiedCanvas.test.tsx` and `KvResizeCanvas.unifiedUndoReveal.test.tsx` are both proven safe. Keep any factory for a shared specifier SHAPE-IDENTICAL to its siblings. After passing in isolation, run the WHOLE directory and confirm the current verified baseline: **1031 pass / 13 fail / 2 errors / 0 skip**.

### Fixture discipline — SIX incidents

Six times a fixture excluded the failing path: an object at frame centre defeating a clamp assertion; a pinned stable array removing the production churn source; single-board fixtures hiding a cross-board id collision; a test placed in a resolver module while the change lived in the host. Choose fixtures that CAN expose what you claim to pin — multi-board where board identity matters, off-frame coordinates where clamping matters.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `resizeToolGesture.ts` (new) | Pure: map a pointer gesture in world space to the board it landed on plus that board's frame-normalized coordinates | 1 |
| `KvResizeUnifiedCanvas.tsx` | Accepts a `tool` prop; suppresses selection while a placement tool is armed; emits gesture callbacks | 2 |
| `KvResizeUnifiedCanvas.tsx` + `ShapeDraftPreview` | Shape drag: live preview, then a committed shape overlay | 3 |
| `KvResizeUnifiedCanvas.tsx` | Comment pin: click places a pin anchored to the board's frame rect | 4 |
| `KvResizeCanvas.tsx` | Passes `tool` down and routes the two placement callbacks to existing commit paths | 5 |

---

## Task 1: `resizeToolGesture.ts` — world pointer → (board, normalized point)

**Why:** every tool needs the same answer: which board did this gesture land on, and where inside that board's frame, in the 0..1 coordinates overlays are stored in. Keeping it pure makes it testable without a canvas and stops each tool re-deriving it.

**Files:**
- Create: `src/components/studio/kv-generator/resizeToolGesture.ts`
- Create: `src/components/studio/kv-generator/resizeToolGesture.test.ts`

**Interfaces:**
- Consumes: `ResizeBoard`, `resizeBoardRect` from `resizeBoardLayout.ts`
- Produces:
  - `boardAtWorldPoint(boards, point): ResizeBoard | null` — the board whose frame rect contains the point; `null` when the point is in empty space between boards. When rects overlap (they should not, but the layout is derived), the FIRST match in array order wins — document that.
  - `normalizedPointInBoard(board, point): { x: number; y: number }` — the point expressed in the board's frame-normalized coordinates. **Does not clamp**: a point outside the frame yields a value below 0 or above 1, which is legitimate on this surface.

- [ ] **Step 1: Write the failing tests.** Cover: a point inside a board returns that board; a point in the gap between two boards returns `null`; normalization of a point at the frame's top-left returns `{0,0}` and bottom-right returns `{1,1}`; a point OUTSIDE the frame yields a value outside 0..1 (this is the no-clamp guard); a degenerate board (zero width or height) does not produce `NaN`. Use a NON-SQUARE board and boards at different world x positions so a transposed axis cannot pass.
- [ ] **Step 2: Run them, confirm they fail** (module missing).
- [ ] **Step 3: Implement.** World rect comes from `resizeBoardRect(board)`; normalization is `(point - rect.origin) / rect.size` per axis.
- [ ] **Step 4: Run tests; mutation-prove** by transposing the axes and by adding a clamp — both must break a test.
- [ ] **Step 5: Commit** — `feat(web): pure world-pointer to board-normalized mapping for resize tools`

---

## Task 2: The tool seam on the unified canvas

**Why:** with a placement tool armed, a pointer press must NOT start a selection or a marquee — it must arm the tool. The per-tile editor solves this with `skipTargetFind` while its tool is armed; follow that, not a new invention.

**Files:**
- Modify: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.tsx`
- Test: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.test.tsx` (new sibling `describe`)

**Interfaces:**
- Produces: prop `tool?: "cursor" | "shape" | "comment"`. Anything else (including `"frame"`, which is M2c-b) behaves as `"cursor"` for now — say so in a comment so the next reader does not think frame is unimplemented by accident.

- [ ] **Step 1: Read how `KvTileOverlayEditor` arms its tools** (`skipTargetFind`, the `tool === "shape"` branches) and mirror the mechanism.
- [ ] **Step 2: Write the failing tests** — with `tool="shape"`, a pointer press on an overlay does NOT select it and does NOT start a marquee; with `tool="cursor"` (or absent), selection behaves exactly as it does today.
- [ ] **Step 3: Run them, confirm they fail.**
- [ ] **Step 4: Implement.** Do NOT disturb the existing re-entrancy guards (`isNarrowingRef`, `isRebuildingRef`, `isReflectingSelectionRef`), the structural-rebuild vs chrome effect split, `boardsSignature`, or the pan-vs-drag guard.
- [ ] **Step 5: Run tests; mutation-prove** by removing the arm check.
- [ ] **Step 6: Commit** — `feat(web): tool seam on the unified resize canvas`

---

## Task 3: Shape placement

**Why:** in Craft and on the per-tile path a shape is placed by a DRAG, not a click, and the drag's angle drives directional shapes (line/arrow). The gate is Craft's `max(w,h) >= 12px`, not the frame tool's per-axis rule.

**Files:**
- Modify: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.tsx`
- Test: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.test.tsx` (new sibling `describe`)

**Interfaces:**
- Consumes: `boardAtWorldPoint`, `normalizedPointInBoard` (Task 1); `defaultShapePayload` from `overlays/shapeGeometry.ts` (import only); `ShapeDraftPreview` for the live preview
- Produces: prop `onPlaceShape?: (boardId: string, overlay: StudioOverlay) => void`

- [ ] **Step 1: Read the per-tile shape path** (`tool === "shape"` branches in `KvTileOverlayEditor`, plus `ShapeDraftPreview` and `defaultShapePayload`) and match its semantics — including the 12px gate and the directional-angle handling.
- [ ] **Step 2: Write the failing tests** — a drag on a board yields one `onPlaceShape` call with that board's id and an overlay whose normalized geometry matches the drag rect; a drag under the 12px gate yields NO call; a drag that STARTS on one board and ENDS past its frame still commits to the starting board (this is the board-strict routing guard, and it needs a genuinely multi-board fixture).
- [ ] **Step 3: Run them, confirm they fail.**
- [ ] **Step 4: Implement.**
- [ ] **Step 5: Run tests; mutation-prove** the 12px gate and the starting-board rule.
- [ ] **Step 6: Commit** — `feat(web): place shapes on the unified resize canvas`

---

## Task 4: Comment pins

**Why:** the smallest tool (9 references in the per-tile editor). Pins anchor to the FRAME rect, not the apron — on the unified canvas there is no apron, so they anchor to the board rect.

**Files:**
- Modify: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.tsx`
- Test: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.test.tsx` (new sibling `describe`)

**Interfaces:**
- Produces: prop `onPlaceComment?: (boardId: string, point: { x: number; y: number }) => void` — the point in frame-normalized coordinates.

- [ ] **Step 1: Read the per-tile comment path** (`onPlaceComment`, `commentTileId`, `data-comment-tile`) and match its semantics.
- [ ] **Step 2: Write the failing tests** — with `tool="comment"`, a click on a board calls `onPlaceComment` with that board's id and the normalized point; a click in the gap between boards calls nothing; a click does not create or select an overlay.
- [ ] **Step 3: Run them, confirm they fail.**
- [ ] **Step 4: Implement.**
- [ ] **Step 5: Run tests; mutation-prove** the empty-space case.
- [ ] **Step 6: Commit** — `feat(web): place comment pins on the unified resize canvas`

---

## Task 5: Host wiring

**Why:** the host already owns the tool state and the commit paths; this connects them.

**Files:**
- Modify: `src/components/studio/kv-generator/KvResizeCanvas.tsx`

- [ ] **Step 1: Pass the existing `tool` prop through** to `KvResizeUnifiedCanvas` when the flag is on.
- [ ] **Step 2: Route `onPlaceShape`** to the same append-and-commit path the per-tile editor uses (`appendOverlayToTile` for a tile, the master equivalent for the master board), through `resolveCommitTarget` so routing stays board-strict. Reuse; do not reimplement.
- [ ] **Step 3: Route `onPlaceComment`** to the host's existing comment handler.
- [ ] **Step 4: Write a host-level test** in `KvResizeCanvas.unifiedUndoReveal.test.tsx` (proven-safe harness): flag on, a shape placed on a TILE board commits through the tile REST path and not the doc.
- [ ] **Step 5: Run tests; mutation-prove; confirm flag-off is byte-identical.**
- [ ] **Step 6: Commit** — `feat(web): wire shape and comment tools into the unified resize canvas`

---

## Self-Review Notes

- Order: **1 → 2 → 3 → 4 → 5**. Task 2 consumes Task 1; Tasks 3 and 4 consume Task 2; Task 5 consumes 3 and 4.
- Tasks 2, 3 and 4 all touch `KvResizeUnifiedCanvas.tsx` and its test file — run them sequentially, appending sibling `describe` blocks, never restructuring existing ones.
- Out of scope, deliberately: the **frame tool** (M2c-b — it is the piece that touches `boxPromptUi.tsx`, shared with Craft production, PRD risk R-1), tile status UI, inline text editing, and the staged flag rollout.
- Also still open from earlier slices and NOT to be fixed here: `onRemove`/`onReorder` committing source-frame coordinates into a tile snapshot (pre-existing, equally live flag-off); `downloadOne`/`downloadAll` calling `resolveTileOverlays` directly (a pre-staged clamp that will bite when the download button is ported); the second partial mock of `@/services/kv/api` in `KvTextFontToolbar.test.tsx`.
