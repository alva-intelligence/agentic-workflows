# KV Resize Unified Canvas — TASK-23 (Tile status UI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a tile's `pending` / `generating` / `failed` state legible and actionable on the unified Resize canvas, as it already is on the per-tile path.

**Architecture:** Reuses the seam M2c-b1 established for the frame tool: a DOM wrapper per board positioned at `resizeFrameGesture.boardViewportRect(board, camera)`, with everything inside it written in FRAME display pixels and knowing nothing about the camera. The status chrome becomes a standalone camera-free component, the canvas renders one per non-done tile board, and the host routes the two actions to the `retryExport` / `cancelExport` it already owns.

**Tech Stack:** Next.js, React, TypeScript, Fabric v7, `bun test`.

**Spec:** `frnd/docs/prd/kv-resize-unified-canvas.md` (approved). TASK-23 on the track.

**Base branch:** `feature/daffa/vc-kv-resize-unified-canvas` — M1 through M2c-b2, TASK-9 complete, **synced with develop and pushed 2026-08-30**. The runtime checklist has PASSED (daffa, 2026-08-30), so this is the first slice in the milestone building on verified ground.

---

## What is actually missing — established by reading, not assumed

**On the unified canvas today, a `pending`, `generating` and `failed` tile all look identical:** an empty frame rect filled with `FRAME_EMPTY_FILL` (`renderResizeBoards.ts:239-250`, whose comment calls it "the visual placeholder for a tile whose render has not arrived, so an empty board is still a legible slot rather than nothing at all"). There is no spinner, no error text, no Cancel and no Retry. A user cannot tell a tile that is still working from one that failed an hour ago, and cannot act on either.

**On the per-tile path (`KvResizeResultRow.tsx`, READ-ONLY) there are three states:**
- `pending` / `generating` (`:235`, `:293`) — a pulsing skeleton in the tile slot, and a **Cancel** button in the ROW HEADER;
- `failed` (`:376-410`) — a red-bordered panel carrying `friendlyResizeError(row.errorMessage)` with **Retry** and **Cancel** buttons, sized by the tile (`errorFontSize` / `errorPadding` / `errorGap`);
- `done` (`:299`) — the editor.

**The host already owns both actions:** `retryExport(row.id)` and `cancelExport(row)` (`KvResizeCanvas.tsx:2118-2119`), currently wired only inside the per-tile branch.

**A canvas has no row header.** That is the one structural difference: the per-tile Cancel lives in a header this surface does not have, so it has to live on the board. Say so in the code rather than letting the next reader think the placement drifted by accident.

---

## Global Constraints

Every task's requirements implicitly include this section.

- **Test runner is `bun test`, run from `web/`.** NOT `bunx vitest`, and NOT from inside the component directory — `bunfig.toml` sets `root = "src"` and the jsdom preload relative to `web/`, so a run started elsewhere fails with `ReferenceError: document is not defined`.
- **Never modify these — imported by the production Craft canvas (`KvFabricCanvas.tsx`):** `fabricExport.ts`, `ghostOverlay.ts`, `overlayGeometry.ts`, `overlayMutations.ts`, `overlayAspect.ts`, `overlaySelection.ts`, `overlayAlign.ts`, `overlayClipboard.ts`, `boxPromptUi.tsx`, `useTileOverlayHistory.ts`, `focusCamera.ts`, `polygonPoints.ts`, `boxFromCandidate.ts`. Import freely; edit none.
- **Never modify the per-tile path:** `KvTileOverlayEditor.tsx`, `KvResizeTileStage.tsx`, `KvResizeViewport.tsx`, `resizeApron.ts`, `KvResizeResultRow.tsx`, `KvResizeOriginalRow.tsx`.
- **`resizeError.ts` is import-only** — shared with the per-tile path. `friendlyResizeError` must not be reimplemented or "improved"; the two surfaces must word an error identically.
- **The MASTER board has no status.** `board.row` is `null` for it (`resizeBoardLayout.ts:64`), so it can never carry status chrome. Master region edit is separately and deliberately pulled — do not add a fourth door.
- **Board-strict.** A retry or cancel acts on the board its chrome belongs to and no other, routed through `resolveCommitTarget` like every other host action in this file.
- **Flag-off behaviour must be byte-identical.** Everything added to `KvResizeCanvas.tsx` goes inside the existing `unifiedCanvasEnabled ?` branch.
- **No new type errors in touched files; eslint clean.** The touched-file tsc baseline is **5** (pre-existing `as const` readonly-tuple sites in `KvResizeUnifiedCanvas.test.tsx`). Measure against 5.
- **Do NOT use `git stash`** — copy files aside with `cp` and restore with `cp`. Documented incident: stash/pop corrupted files with conflict markers.
- **Every new test must be MUTATION-PROVEN.** Break the implementation, watch the named test fail, restore, re-run. Show both outputs. A surviving mutant means the fixture is too weak — fix the fixture, never the mutant.

### Test-infrastructure warning — TEN incidents in this milestone

bun's mock registry is process-global and load order is NOT alphabetical. **Prefer extending a proven-safe suite over creating a file.** `KvResizeUnifiedCanvas.test.tsx`, `KvFrameBoxLayer.test.tsx` and `KvResizeCanvas.unifiedUndoReveal.test.tsx` are all proven safe. A new file is acceptable ONLY if it mocks nothing shared — `KvFrameBoxLayer.test.tsx` is the precedent: it renders one presentational component and imports no flags, no services, and not `./KvResizeUnifiedCanvas`.

If you touch `@/services/kv/api`'s factory, remember there are now **six** `KvResizeCanvas.*` suites registering it and they must stay shape-identical.

Baseline to confirm: **1205 pass / 13 fail / 2 errors**, and diff the FAIL LIST line by line, not just the count. Known flake: `KvTileDownloadDropdown > disables the trigger when the tile is not done` sometimes reports as a named fail and sometimes folds into the error count, at HEAD too.

### Fixture discipline — the traps that have actually bitten here

Symmetric geometry (x==y or w==h lets a transposed implementation pass); 1x-camera-only (a world-px and a screen-px bug are indistinguishable at 100%); single-board fixtures (cannot tell "the right board" from "the only board"); **a `done`-status tile everywhere** — that one is the direct ancestor of this task, and this slice's fixtures must cover all four statuses; a mutation that is a no-op as written.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `KvBoardStatusLayer.tsx` (new) | The status chrome in FRAME display px — camera-free | 1 |
| `KvBoardStatusLayer.test.tsx` (new) | Component tests | 1 |
| `KvResizeUnifiedCanvas.tsx` | Renders one status layer per non-done tile board | 2 |
| `KvResizeCanvas.tsx` | Routes retry / cancel to `retryExport` / `cancelExport` | 3 |
| track file | Session log | 4 |

---

## Task 1: `KvBoardStatusLayer` — the chrome, in frame coordinates

**Why:** the per-tile status affordances are plain DOM sized by the tile. Extracted as a camera-free component, the canvas renders one per board inside a positioned wrapper and does no chrome math — exactly how `KvFrameBoxLayer` already works.

**Files:**
- Create: `src/components/studio/kv-generator/KvBoardStatusLayer.tsx`
- Create: `src/components/studio/kv-generator/KvBoardStatusLayer.test.tsx`

This new test file is acceptable under the test-infra rule because it mocks NOTHING.

**Interfaces:**
- Consumes: `friendlyResizeError` from `@/lib/studio/kv/resizeError` (import only); `KvResizeExport` from `@/types/kv/resize`
- Produces:

```ts
export function KvBoardStatusLayer(props: {
  status: KvResizeExport["status"];
  errorMessage: string | null;
  /** Frame size in DISPLAY px — the wrapper's own size. Drives the type
   *  scale, so a small tile does not get text sized for a large one. */
  displayWidth: number;
  displayHeight: number;
  onRetry: () => void;
  onCancel: () => void;
}): JSX.Element | null;
```

Returns `null` for `done` — a finished tile has no status chrome at all.

- [ ] **Step 1: Read the source you are porting.** `KvResizeResultRow.tsx` lines 235-250 (the header Cancel), 293-298 (the pulse skeleton) and 375-410 (the error panel, including how `errorFontSize`, `errorPadding` and `errorGap` are derived from the tile size). Copy the styling and the wording; change only what the interface above requires.

- [ ] **Step 2: Write the failing tests.** Use `within(document.body)` and never the bare `screen` export (see `[[lesson-web-rtl-screen-broken-under-bun]]`). Use a NON-SQUARE frame so a transposed size cannot pass. Cover:
  - `status: "done"` renders NOTHING (`container.firstChild` is null) — not "no buttons", nothing at all, so it cannot sit over a finished tile swallowing events;
  - `pending` and `generating` both render the working state and a **Cancel**, and NO Retry — retrying something that is still running is the wrong affordance;
  - `failed` renders `friendlyResizeError(errorMessage)`'s text, a **Retry** and a **Cancel**;
  - a `failed` tile with a `null` errorMessage still renders whatever `friendlyResizeError(null)` returns rather than an empty panel;
  - clicking Retry calls `onRetry` and NOT `onCancel`, and clicking Cancel calls `onCancel` and NOT `onRetry`;
  - the error text scales with the frame: assert a **smaller** font size on a 200px-wide frame than on an 800px one (the per-tile path derives it from the tile, and a canvas can show both at once, which the per-tile path never could).

- [ ] **Step 3: Run them, confirm they fail** (module missing).
- [ ] **Step 4: Implement.**
- [ ] **Step 5: Run tests; mutation-prove.** At minimum: render for `done`; show Retry on `generating`; swap the two callbacks; drop the `friendlyResizeError` call and print the raw message; make the type scale constant. Each must break a NAMED test.
- [ ] **Step 6: Commit** — `feat(web): extract the tile status chrome as a camera-free layer`

---

## Task 2: Render one status layer per non-done tile board

**Files:**
- Modify: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.tsx`
- Test: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.test.tsx` (new sibling `describe`, appended — never restructure existing blocks)

**Interfaces:**
- Consumes: `boardViewportRect` from `resizeFrameGesture.ts`; `KvBoardStatusLayer` (Task 1)
- Produces:

```ts
  /** Retry / cancel a tile's render, by board id. Omitted ⇒ the status chrome
   *  renders read-only (state, no actions). */
  onRetryTile?: (boardId: string) => void;
  onCancelTile?: (boardId: string) => void;
```

- [ ] **Step 1: Study the existing per-board wrapper.** The frame-tool chrome already maps over `boards`, skips master and non-done boards, and positions a wrapper at `boardViewportRect(board, camera)`. **This layer is the mirror image of that one** — it renders for exactly the boards the frame layer skips. Write that relationship as a comment; a future reader who changes one gate must change the other.

- [ ] **Step 2: Write the failing tests.** Reuse the harness pattern from the frame-tool blocks (`pinCamera`, `exportRow`, `computeResizeBoards`). Cover:
  - a `generating` tile renders a status layer; a `done` tile renders none;
  - with THREE tiles — one `done`, one `generating`, one `failed` — exactly two status layers render, on the right two boards (a fixture where every tile shares a status cannot tell a per-board decision from a global one);
  - the MASTER board never renders one, even though its `row` is null;
  - the wrapper is positioned by `boardViewportRect` — **assert this at a camera scale other than 1**, using the same over-determined two-board technique the frame chrome test uses (derive the scale from one wrapper's width, the translation from its left, then require the second wrapper to land where that pair puts it). At 1x a projected and an unprojected wrapper are indistinguishable, and that gap has already let a mutant survive twice in this milestone;
  - Retry and Cancel reach `onRetryTile` / `onCancelTile` with THAT board's id;
  - the actions work regardless of the armed tool — unlike the frame chrome, which is tool-gated. On the per-tile path Cancel lives in the row header and is always available; a canvas has no header, so the affordance must not become tool-dependent by accident.

- [ ] **Step 3: Run them, confirm they fail.**
- [ ] **Step 4: Implement.**
- [ ] **Step 5: Run tests; mutation-prove.** At minimum: render for done boards too; render for the master; skip the projection; route both actions to the first board; gate the actions on `effectiveTool === "frame"`.
- [ ] **Step 6: Commit** — `feat(web): show tile status on the unified resize canvas`

---

## Task 3: Host wiring

**Files:**
- Modify: `src/components/studio/kv-generator/KvResizeCanvas.tsx`
- Test: `src/components/studio/kv-generator/KvResizeCanvas.unifiedUndoReveal.test.tsx` (proven-safe harness — extend the existing `./KvResizeUnifiedCanvas` mock with buttons, exactly as the M2c slices did; do NOT create a file)

- [ ] **Step 1: Route both actions** through `resolveCommitTarget(unifiedBoards, boardId)`, as every other host action in that file does, into the existing `retryExport(row.id)` and `cancelExport(row)`. A `master` target must return early — it has no export row to retry or cancel. Reuse; do not reimplement.

- [ ] **Step 2: Write the host tests.** Add mock buttons that call `onRetryTile("row1")` / `onCancelTile("row1")` and `onRetryTile("__master__")` directly — the geometry is Task 2's job. Assert: a retry on a tile calls `retryExport` with that row id; a cancel calls `cancelExport` with that row; a master target calls neither.

- [ ] **Step 3: Run tests; mutation-prove; confirm flag-off is byte-identical.**
- [ ] **Step 4: Commit** — `feat(web): wire tile retry and cancel into the unified resize canvas host`

---

## Task 4: Track file

- [ ] **Step 1: Add the session-log entry** in the shape the M2c entries use: what landed, what diverged from this plan and why, which mutants survived their first fixture and what each exposed, and the verification numbers. Tick TASK-23 in the task list.
- [ ] **Step 2: Add a runtime item to the regression checklist** — the checklist Daffa passed on 2026-08-30 covers no status state at all, because none existed. Add: *with a tile mid-generation, confirm the canvas shows it as working and offers Cancel; force a failure and confirm the message and Retry appear on that board.*
- [ ] **Step 3: Commit** — `docs(web): record TASK-23 on the unified-canvas track`

---

## Self-Review Notes

- Order: **1 → 2 → 3 → 4.** Task 2 consumes 1; Task 3 consumes 2.
- **The invariant this task is closest to, and must not break.** `KvResizeResultRow` renders the editor only for `status === "done"`, and `staleRegionBoxes.ts` states that as its PREMISE — which is why `clearBoxesForExport` may also un-mark `regionEditedExportIds`. That premise has already produced one Critical in this milestone. This task ADDS chrome for non-done tiles; it must not add any path that lets a non-done tile be *edited*. The frame chrome, the frame gesture and the host route all already refuse non-done boards — leave all three refusals exactly as they are, and do not "unify" them with this layer's inverse gate.
- Out of scope: TASK-24 (ruler + grid), TASK-25 (inline text editing), TASK-26/27 (the merge into `KvFabricCanvas` and the ~2000-LOC deletion).
- Still open and NOT to be fixed here: the `KV_RESIZE_REGION_EDIT` kill switch's OFF direction is unprovable from the host harness; the four unreachable-by-construction gaps documented in M2c-b2; the latent `discardCandidateArea` bug in production Craft (filed separately, do-not-touch file).
- **Runtime.** The milestone's checklist passed on 2026-08-30, so this slice starts from verified ground — but that checklist predates every status state, since none were rendered. Task 4 Step 2 adds the two checks that close that gap; they need a real generation to exercise and cannot be faked in jsdom.
