# KV Resize Unified Canvas — M2b (Per-Tile Undo Parity) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make undo on the unified Resize canvas as legible as it is on the per-tile path, and pin the routing that already works so it cannot silently regress.

**Architecture:** M1 deliberately routed the unified canvas's `onCommitOverlays` through the host's existing `commitTileOverlays` / `commitMasterOverlays` rather than reimplementing the write path. A consequence discovered while planning this slice: **per-tile undo already works from the unified canvas** — `commitTileOverlays` calls `history.record(...)` and marks `onEditDomainChange("tile")`, so every unified-canvas tile edit already lands on the correct timeline. TASK-22, which the track file flags as "the highest-risk unknown, most likely to sink the design", is therefore largely already satisfied. What remains is one concrete gap plus regression cover.

**The gap:** the history's `apply` callback ends with `scrollTileIntoView(snapshot.exportId)`, which does `document.querySelector('[data-tile-id="…"]')`. On the unified canvas there are no per-tile DOM elements — tiles are objects inside one canvas. So undoing an edit on an off-screen board restores the data correctly but never moves the camera, producing exactly the failure the code's own comment names: *"an undo on an off-screen tile is invisible otherwise, and reads as 'nothing happened'."*

**Tech Stack:** Next.js, React, TypeScript, Fabric v7, `bun test`.

**Spec:** `frnd/docs/prd/kv-resize-unified-canvas.md` (approved). Delivers FR-6 (per-tile undo preserved).

**Base branch:** `feature/daffa/vc-kv-resize-unified-canvas-m2` (M2a), itself stacked on M1 (PR #541). **Neither has had a browser pass.**

---

## Global Constraints

Every task's requirements implicitly include this section.

- **Test runner is `bun test`, run from `web/`.** NOT `bunx vitest`. Pure `.ts` suites import from `"bun:test"`; component `.tsx` suites import from `"vitest"`.
- **Never modify these — imported by the production Craft canvas (`KvFabricCanvas.tsx`):** `fabricExport.ts`, `ghostOverlay.ts`, `overlayGeometry.ts`, `overlayMutations.ts`, `overlayAspect.ts`, `overlaySelection.ts`, `overlayAlign.ts`, `overlayClipboard.ts`, `boxPromptUi.tsx`, `useTileOverlayHistory.ts`. Import freely; edit none. If a task appears to require an edit, STOP and report BLOCKED.
- **Never modify the per-tile path:** `KvTileOverlayEditor.tsx`, `KvResizeTileStage.tsx`, `KvResizeViewport.tsx`, `resizeApron.ts`.
- **Never clamp coordinates.** Off-frame is intended and must survive every read and write.
- **Board-strict routing.** Master board → Yjs doc; tile board → per-row REST snapshot.
- **`null` (inheriting) and `[]` (deliberately emptied) are different states.** The undo history round-trips `null` deliberately — see `TileOverlaySnapshot`'s doc.
- **Flag-off behaviour must be byte-identical.**
- **Resize board layout stays DERIVED, never persisted.** Nothing may touch `studio_files.metadata.kv_canvas`.
- **No new type errors in touched files; eslint clean.**
- **Never write a raw control character into source** — use the escape form. A previous slice committed a raw NUL byte by accident.
- **Every new test must be MUTATION-PROVEN.** Break the implementation, observe the test fail for the right reason, restore, re-run. Show both outputs.
- **Fixture discipline.** FOUR times in this milestone a test's fixture excluded the failing path (a fixture at frame centre defeating a clamp assertion; a pinned stable array removing the production churn source; single-board fixtures hiding a cross-board id collision; a test placed in a resolver module while the change lived in the host). Choose fixtures that CAN expose the behaviour you claim to pin — here that means boards genuinely off-screen, and more than one board.
- **Test-mock hazard.** bun's mock registry is PROCESS-GLOBAL and first-registration-wins. This milestone hit five leakage incidents, one where a test FILENAME determined collision and one that silently blanked another suite while passing in isolation. Mock as little as possible, keep factories shape-identical to sibling suites for the same specifier, and after passing in isolation run the WHOLE directory and confirm the failure set matches baseline (13 failures, 2 errors, none in resize-board or unified-canvas suites).

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `resizeBoardCamera.ts` (new) | Pure: given a board rect, the viewport size and the current camera, decide whether the board needs revealing and return the camera that reveals it | 1 |
| `KvResizeUnifiedCanvas.tsx` | Publishes an imperative camera API to its host, following Craft's `onZoomApiChange` precedent | 2 |
| `KvResizeCanvas.tsx` | Uses that API in the history `apply` callback when the flag is on; keeps `scrollTileIntoView` when off | 3 |
| `KvResizeUnifiedCanvas.test.tsx` | Append sibling `describe` blocks; do not restructure existing ones | 2, 4 |

---

## Task 1: `resizeBoardCamera.ts` — pure reveal math

**Why:** the camera decision must be testable without a canvas, and it must mirror `scrollTileIntoView`'s semantics: move ONLY when the target is not already comfortably visible, so an undo on a board already on screen does not yank the view.

**Files:**
- Create: `src/components/studio/kv-generator/resizeBoardCamera.ts`
- Create: `src/components/studio/kv-generator/resizeBoardCamera.test.ts`

**Interfaces:**
- Consumes: `ResizeBoard` and `resizeBoardRect` from `resizeBoardLayout.ts`
- Produces: `cameraToRevealBoard(board, viewport, camera): Camera | null` — returns `null` when the board is already comfortably visible (caller does nothing), otherwise the camera that centres it. `Camera` is `{ scale: number; x: number; y: number }`, matching `KvResizeUnifiedCanvas`'s own type. Scale is NOT changed — revealing must never zoom, only pan.

- [ ] **Step 1: Write the failing tests.** Cover: a board fully on screen returns `null`; a board entirely off to the right returns a camera that centres it; a board partially off the bottom returns a camera; the returned camera preserves `scale` exactly; a degenerate viewport (zero width or height) returns `null` rather than producing `NaN`. Use a NON-square board and an off-centre camera so a transposed axis or a dropped `scale` cannot pass.
- [ ] **Step 2: Run them, confirm they fail** (module missing).
- [ ] **Step 3: Implement.** World→screen is `screen = world * scale + camera.{x,y}`, matching the component's `setViewportTransform([scale, 0, 0, scale, x, y])`. Centre by solving for the camera that puts the board's world centre at the viewport centre.
- [ ] **Step 4: Run tests; mutation-prove** by transposing the x/y axes and by dropping the already-visible early return.
- [ ] **Step 5: Commit** — `feat(web): pure camera math to reveal a resize board`

---

## Task 2: Publish a camera API from the unified canvas

**Why:** the host owns undo; the canvas owns the camera. Craft already solved this shape — `KvFabricCanvas` publishes an imperative `KvZoomApi` via `onZoomApiChange`. Follow it rather than inventing a prop protocol.

**Files:**
- Modify: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.tsx`
- Test: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.test.tsx` (new sibling `describe`)

**Interfaces:**
- Consumes: `cameraToRevealBoard` (Task 1); the component's existing `camera` state and `boards`
- Produces: prop `onCameraApiChange?: (api: { revealBoard: (boardId: string) => void } | null) => void`. Publishes on mount, publishes `null` on unmount — the same lifecycle `onZoomApiChange` uses, so leaving the surface cannot leave the host holding a dead handle.

- [ ] **Step 1: Read `KvFabricCanvas`'s `onZoomApiChange` effect** and follow its lifecycle exactly (publish through a ref so the registration does not churn on every camera change).
- [ ] **Step 2: Write the failing tests** — calling `revealBoard` with an off-screen board's id changes `canvas.viewportTransform`'s translation; calling it with an already-visible board does not; calling it with an unknown id is a no-op and does not throw; unmount publishes `null`.
- [ ] **Step 3: Run them, confirm they fail.**
- [ ] **Step 4: Implement.** Do NOT re-register the API on every camera change — read the latest camera through a ref, as the file already does elsewhere. Do NOT alter zoom.
- [ ] **Step 5: Run tests; mutation-prove** by removing the already-visible short-circuit.
- [ ] **Step 6: Commit** — `feat(web): expose a reveal-board camera API from the unified resize canvas`

---

## Task 3: Use the camera API in the undo path

**Why:** closes the actual gap — an undo on an off-screen board currently restores data with no visual indication.

**Files:**
- Modify: `src/components/studio/kv-generator/KvResizeCanvas.tsx` (the `useTileOverlayHistory` `apply` callback, and the JSX that renders `KvResizeUnifiedCanvas`)

**Interfaces:**
- Consumes: the camera API from Task 2

- [ ] **Step 1: Wire `onCameraApiChange`** into the unified-canvas JSX, storing the handle in a ref.
- [ ] **Step 2: In the `apply` callback,** when `unifiedCanvasEnabled`, call `revealBoard(snapshot.exportId)`; when off, keep `scrollTileIntoView(snapshot.exportId)` EXACTLY as-is. Note `snapshot.exportId` is a row id and the camera API takes a board id — they are the same string today (`MASTER_ROW_ID === MASTER_BOARD_ID === "__master__"`, and a tile board's id IS its row id), but say so in a comment, because the file's own comment elsewhere warns the two namespaces are "independently changeable".
- [ ] **Step 3: Write a host-level test** — flag on, an undo whose snapshot names an off-screen board calls `revealBoard` with that id. Model it on `KvResizeCanvas.unifiedCopy.test.tsx`'s harness, which is proven safe against the mock hazard.
- [ ] **Step 4: Run tests; mutation-prove** by reverting the wiring.
- [ ] **Step 5: Commit** — `fix(web): reveal the board an undo restored on the unified canvas`

---

## Task 4: Pin the undo routing that already works

**Why:** per-tile undo from the unified canvas works only because M1 routed commits through the host's existing functions. Nothing pins that. A future refactor that gives the unified canvas its own commit path would silently lose undo — and this is the single behaviour the spec calls out as the highest-risk unknown.

**Files:**
- Test only: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.test.tsx` or a host-level sibling, whichever can actually observe the behaviour
- Modify only if a test reveals a real defect — and say so prominently

- [ ] **Step 1: Write tests** proving: a commit originating from the unified canvas on a TILE board records an undo entry and marks the edit domain `"tile"`; undoing it restores the previous overlays for that tile and no other; a tile whose snapshot was `null` round-trips back to `null`, never to `[]`.
- [ ] **Step 2: Run them.** If any fails, that is a real defect — fix it and flag it loudly. If all pass, the behaviour was correct but unpinned; say that plainly rather than inventing a change.
- [ ] **Step 3: Mutation-prove** by removing the `history.record` call from `commitTileOverlays` and confirming the tests catch it. Restore.
- [ ] **Step 4: Commit** — `test(web): pin per-tile undo from the unified resize canvas`

---

## Task 5: Investigate master-edit undo routing — REPORT, DO NOT FIX

**Why:** `commitMasterOverlays` delegates to `onCommitProjectOverlays` and does NOT call `onEditDomainChange`. Nobody in `KvResizeCanvas.tsx` ever marks the domain `"master"`. So after a master-board edit, Cmd+Z may route to whichever timeline was last marked — likely the tile one.

**This task makes NO claim that this is broken.** Twice in this milestone a plan asserted a defect that did not reproduce, and the honest outcome both times was an implementer proving the premise wrong. Establish the facts first.

**Files:**
- No production changes expected. Read-only investigation plus a report.

- [ ] **Step 1: Trace it.** Where does the edit domain start, who else sets it, and what does the layout's Cmd+Z dispatcher do with it? Read `onEditDomainChange`'s consumer in the layout.
- [ ] **Step 2: Determine whether a master edit followed by Cmd+Z actually mis-routes.** Write a temporary probe test if that is the cheapest way to answer it — you may delete it afterwards, but say so.
- [ ] **Step 3: Report the answer.** If it mis-routes, note that it is PRE-EXISTING and equally live with the flag OFF, so it belongs to its own change on the per-tile path — do NOT fix it here. If it routes correctly, say why, so nobody re-investigates.
- [ ] **Step 4: Commit** only if you added a lasting test — otherwise report with no commit.

---

## Self-Review Notes

- Order: **1 → 2 → 3 → 4 → 5**. Task 2 consumes Task 1; Task 3 consumes Task 2. Tasks 4 and 5 are independent of 1–3 and could run any time, but run last so the earlier diffs stay small.
- Tasks 2, 3 and 4 may all touch `KvResizeUnifiedCanvas.test.tsx` — run them sequentially, appending sibling `describe` blocks.
- Out of scope, tracked for later slices: the tool port (frame/shape/comment — touches `boxPromptUi.tsx`, a genuine Craft change, PRD risk R-1), tile status UI, inline text editing, and the staged flag rollout.
