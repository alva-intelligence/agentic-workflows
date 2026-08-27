# KV Resize Unified Canvas — M2a (Selection & Shared-Read Parity) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the keyboard/selection layer work correctly on the unified Resize canvas, and close the remaining read-sites that still clamp a deliberately off-frame overlay.

**Architecture:** M1 gave the unified canvas selection, drag and commit routing, and introduced `resizeBoardOverlays.resolveBoardOverlays` as the single resolver for *rendering* and the *commit baseline*. Two other read-sites were never migrated — the clipboard copy path and the align pool — and both still go through `resolveTileOverlays`, whose rescue clamp rewrites any overlay with no visible area. This slice routes them through the same seam, makes the host↔canvas selection contract bidirectional (the `selectedOverlayIds` prop M1 declared but left inert), and routes Cmd+A / Cmd+C / Cmd+V to the unified canvas instead of letting the host's un-gated keyboard effect half-drive it.

**Tech Stack:** Next.js, React, TypeScript, Fabric v7, `bun test`.

**Spec:** `frnd/docs/prd/kv-resize-unified-canvas.md` (approved 2026-08-27). This slice delivers FR-5 (multi-select), the clipboard half of FR-9, and FR-10 (keyboard behaviour preserved).

**Base branch:** `feature/daffa/vc-kv-resize-unified-canvas-m2`, stacked on M1's `feature/daffa/vc-kv-resize-unified-canvas` (PR #541). M1 is **not** on `develop` and has **not** been verified in a browser.

---

## Global Constraints

Every task's requirements implicitly include this section.

- **Test runner is `bun test`, run from `web/`.** NOT `bunx vitest`. Pure `.ts` suites import from `"bun:test"`; component `.tsx` suites import from `"vitest"` (`bun:test` does not export `vi`).
- **Never modify these — they are imported by the production Craft canvas (`KvFabricCanvas.tsx`):** `fabricExport.ts`, `ghostOverlay.ts`, `overlayGeometry.ts`, `overlayMutations.ts`, `overlayAspect.ts`, `overlaySelection.ts`, `overlayAlign.ts`, `overlayClipboard.ts`, `boxPromptUi.tsx`. Import from them freely; edit none. If a task appears to require an edit, STOP and report BLOCKED.
- **Never modify the per-tile path:** `KvTileOverlayEditor.tsx`, `KvResizeTileStage.tsx`, `KvResizeViewport.tsx`, `resizeApron.ts`. It is production and the fallback. Read them for patterns; edit none.
- **Never clamp coordinates.** An overlay may sit fully outside its frame; a normalized value above 1 or below 0 is legitimate and must survive every read and write. This is the milestone's headline feature and it has already been broken once by a *read* path.
- **Board-strict routing.** Master board → Yjs doc (`commitMasterOverlays`); tile board → per-row REST snapshot (`commitTileOverlays(row, …)`). Never cross.
- **`null` (inheriting from master) and `[]` (deliberately emptied) are different states.** Never conflate them.
- **Flag-off behaviour must be byte-identical.** `KV_RESIZE_UNIFIED_CANVAS` is fail-closed; with it off, the per-tile path must behave exactly as before this branch.
- **Resize board layout stays DERIVED, never persisted.** Nothing may read or write `studio_files.metadata.kv_canvas`.
- **No new type errors in files you touch.** The repo has a large pre-existing `tsc` baseline elsewhere — judge only your own files. `eslint` must be clean on touched files.
- **Every new test must be mutation-proven.** Break the implementation deliberately, observe the test fail for the right reason, restore, re-run. Show both outputs in your report. This plan's own test code is a STARTING POINT, not a guarantee — in M1, plan-supplied test code was found weak or vacuous three separate times. Two specific traps to avoid: never place a fixture at the frame centre when the assertion is about geometry (a clamp would not change it), and never pin an input to a stable reference when production allocates a fresh one.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `resizeBoardOverlays.ts` (exists, M1) | The single resolver: master → raw, materialized tile snapshot → verbatim, `null` snapshot → projected | consumed by 1, 2 |
| `resizeSelectionSource.ts` (new) | Pure: given boards + the active board id + project overlays, produce the selectable overlay ids for Cmd+A, scoped to one board | 3 |
| `KvResizeCanvas.tsx` | Host. Clipboard/align read-sites; keyboard routing; passes selection down | 1, 2, 3, 5 |
| `KvResizeUnifiedCanvas.tsx` | Consumes `selectedOverlayIds` to reflect a host-driven selection onto the canvas | 4 |
| `KvResizeUnifiedCanvas.test.tsx` (exists, 12 tests) | Append new `describe` blocks; do not restructure existing ones | 4, 6 |

---

## Task 1: Route the clipboard COPY path through `resolveBoardOverlays`

**Why:** `KvResizeCanvas.tsx`'s copy handler resolves a tile through `resolveTileOverlays`. On the unified canvas an overlay may sit fully outside its frame; `hasVisibleArea` is then false and `clampOverlayToCanvas` rewrites its coordinates **into the copied payload**. The user copies an off-frame layer and pastes a clamped one. This is the same defect class as M1's Critical, at a read-site M1 did not cover.

**Files:**
- Modify: `src/components/studio/kv-generator/KvResizeCanvas.tsx` (the `action === "copy"` branch, ~line 508)
- Test: `src/components/studio/kv-generator/resizeBoardOverlays.test.ts` (extend)

**Interfaces:**
- Consumes: `resolveBoardOverlays(board, projectOverlays, sourceWidth, sourceHeight)` from `resizeBoardOverlays.ts`; `findResizeBoard` + `MASTER_BOARD_ID` from `resizeBoardLayout.ts`
- Produces: nothing new

- [ ] **Step 1: Read the current copy branch and the resolver**

Read `KvResizeCanvas.tsx` around the `action === "copy"` branch, and `resizeBoardOverlays.ts` in full. Confirm for yourself that `resolveTileOverlays` applies `clampOverlayToCanvas` to a snapshot overlay with no visible area (`overlayAspect.ts`, the `if (tileSnapshot)` branch).

- [ ] **Step 2: Write the failing test**

In `resizeBoardOverlays.test.ts`, add a test proving the resolver preserves a fully off-frame overlay in a materialized snapshot — and that `resolveTileOverlays` does NOT. Place the fixture well outside the frame (e.g. `x: 1.9`), never at centre.

- [ ] **Step 3: Run it, confirm it fails for the right reason**

Run: `bun test src/components/studio/kv-generator/resizeBoardOverlays.test.ts`

- [ ] **Step 4: Change the copy branch**

When `unifiedCanvasEnabled`, resolve the source overlays through `resolveBoardOverlays` for the active board instead of `resolveTileOverlays`. When the flag is off, leave the existing call untouched — flag-off must not change.

- [ ] **Step 5: Run tests, then mutation-prove**

Re-run the suite. Then temporarily route the unified path back through `resolveTileOverlays` and confirm the new test fails; restore.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "fix(web): copy off-frame overlays without clamping on the unified canvas"
```

---

## Task 2: Route the align pool through `resolveBoardOverlays`

**Why:** the align/distribute panel reads `alignPool` and commits `applyAlignPatches(baseOverlaysFor(activeRow), patches)`. `baseOverlaysFor` resolves a tile the old way, so aligning a selection on a tile that also holds an off-frame sibling will clamp that sibling as collateral — a layer the user never touched moves.

**Files:**
- Modify: `src/components/studio/kv-generator/KvResizeCanvas.tsx` (`alignPool`, `baseOverlaysFor`, and the `onAlignOverlays` commit, ~line 2070)
- Test: `src/components/studio/kv-generator/resizeBoardOverlays.test.ts` (extend)

**Interfaces:**
- Consumes: `resolveBoardOverlays` (Task 1's seam, unchanged)

- [ ] **Step 1: Write the failing test** — an align commit on a tile whose snapshot contains one on-frame and one off-frame overlay must leave the off-frame one's coordinates untouched.
- [ ] **Step 2: Run it, confirm it fails.**
- [ ] **Step 3: Route `baseOverlaysFor` and `alignPool` through `resolveBoardOverlays` when the flag is on.** Flag-off path unchanged.
- [ ] **Step 4: Run tests; mutation-prove by reverting the routing.**
- [ ] **Step 5: Commit** — `fix(web): align no longer clamps untouched off-frame siblings`

---

## Task 3: `resizeSelectionSource.ts` — Cmd+A scoped to one board

**Why:** the host's keyboard effect is NOT flag-gated. With the unified canvas on, Cmd+A writes `selectedIds` derived from `row.overlays ?? projectOverlays`, which round-trips into `ghostOverlayIds` and ghosts every overlay while nothing is actually selected on the canvas. Spec FR-5 requires Cmd+A scoped to the ACTIVE board.

**Files:**
- Create: `src/components/studio/kv-generator/resizeSelectionSource.ts`
- Create: `src/components/studio/kv-generator/resizeSelectionSource.test.ts`

**Interfaces:**
- Consumes: `ResizeBoard`, `findResizeBoard` (`resizeBoardLayout.ts`); `resolveBoardOverlays`; `selectableOverlayIds` (`@/lib/studio/kv/overlaySelection`, import only)
- Produces: `selectableIdsForBoard(boards, activeBoardId, projectOverlays, sourceWidth, sourceHeight): string[]` — the ids Cmd+A should select. Returns `[]` when no board is active or the board resolves to nothing.

- [ ] **Step 1: Write the failing tests** covering: master board returns the project overlays' selectable ids; a materialized tile returns its snapshot's ids (NOT the master's); an inheriting tile returns the projected set's ids; no active board returns `[]`; locked/hidden overlays are excluded (delegate to `selectableOverlayIds`, do not reimplement its rules).
- [ ] **Step 2: Run, confirm failure** (module missing).
- [ ] **Step 3: Implement** — thin composition of `findResizeBoard` + `resolveBoardOverlays` + `selectableOverlayIds`. No new selection rules.
- [ ] **Step 4: Run tests; mutation-prove the tile-vs-master distinction.**
- [ ] **Step 5: Commit** — `feat(web): board-scoped selectable ids for the unified resize canvas`

---

## Task 4: Consume `selectedOverlayIds` — host→canvas selection reflection

**Why:** M1 declared the prop and left it inert, so a selection made anywhere other than the canvas (Cmd+A, the Layers panel) does not appear on the canvas. This is the other half of the bidirectional contract, and Task 3 and Task 5 both depend on it.

**Files:**
- Modify: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.tsx`
- Test: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.test.tsx` (new sibling `describe`)

**Interfaces:**
- Consumes: `selectedOverlayIds?: string[]` (already on the props type)
- Produces: no new exports

- [ ] **Step 1: Write the failing tests** — (a) passing ids selects the matching objects on the canvas; (b) passing `[]` clears the canvas selection; (c) reflecting a host selection does NOT re-fire `onSelectionChange` back to the host (an echo loop).
- [ ] **Step 2: Run, confirm failure.**
- [ ] **Step 3: Implement.** Reflect in an effect keyed on a VALUE signature of the ids, not array identity — M1 was broken twice by identity churn. Guard the echo with the same re-entrancy pattern the file already uses for narrowing and rebuild suppression (`isNarrowingRef` / `isRebuildingRef`), and clear the flag in `finally`. Do NOT rebuild objects to reflect a selection.
- [ ] **Step 4: Run tests; mutation-prove the echo guard** (remove it, observe the loop).
- [ ] **Step 5: Commit** — `feat(web): reflect a host-driven selection onto the unified canvas`

---

## Task 5: Route Cmd+A / Cmd+C / Cmd+V to the unified canvas

**Why:** with Tasks 3 and 4 in place, the host's keyboard effect can drive the unified canvas correctly instead of half-driving it.

**Files:**
- Modify: `src/components/studio/kv-generator/KvResizeCanvas.tsx` (the keyboard effect, ~lines 455–600)

**Interfaces:**
- Consumes: `selectableIdsForBoard` (Task 3); `resolveBoardOverlays`; `buildClipboardPayload`, `canPasteInto`, `pasteOverlays` (`@/lib/studio/kv/overlayClipboard`, import only)

- [ ] **Step 1: Write the failing test** — Cmd+A with the flag on selects only the active board's overlays.
- [ ] **Step 2: Run, confirm failure.**
- [ ] **Step 3: Implement.** When `unifiedCanvasEnabled`: select-all uses `selectableIdsForBoard`; copy builds its payload from `resolveBoardOverlays` and tags the source frame with the board's NATIVE dimensions; paste targets the active board and commits through the same routing M1 built.

  **Paste allowance:** pass `overflowAllowance: { x: Infinity, y: Infinity }`. The unified canvas is a world canvas with no apron and no boundary — the same reason Craft passes `Infinity`. Do NOT carry over the apron-derived allowance; that bound exists only for the per-tile editor.

  Flag-off keeps every existing call path untouched.
- [ ] **Step 4: Run tests; mutation-prove** that flag-off still uses the old path.
- [ ] **Step 5: Commit** — `feat(web): keyboard select-all, copy and paste on the unified canvas`

---

## Task 6: Multi-select semantics — shift-click and marquee

**Why:** fabric already provides marquee and shift-click because M1 set `selection: props.interactive`. What is unpinned is the SPEC behaviour: FR-5 says multi-select stays on Resize, scoped to one board. M1's narrowing enforces the board scope but only the single-survivor path is tested, and the multi-survivor path is the realistic gesture.

**Files:**
- Test only: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.test.tsx` (new sibling `describe`)
- Modify only if a test reveals a real defect: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.tsx`

- [ ] **Step 1: Write the tests** — (a) a marquee/selection with TWO survivors on the primary board plus one foreign member narrows to the two, not to one; (b) the reported ids are exactly those two, in a stable order; (c) a shift-click adding a foreign-board layer leaves the primary selection intact.
- [ ] **Step 2: Run them.** If any fails, that is a real defect in M1's narrowing — fix it and say so prominently in your report. If all pass, the behaviour was correct but unpinned; say that instead of inventing a change.
- [ ] **Step 3: Commit** — `test(web): pin multi-survivor cross-board selection narrowing`

---

## Self-Review Notes

- Tasks 1 and 2 share `resolveBoardOverlays` but touch disjoint regions of `KvResizeCanvas.tsx`; run 1 before 2.
- Task 5 depends on 3 and 4. Task 4 depends on nothing. Suggested order: **1 → 2 → 3 → 4 → 5 → 6**.
- Tasks 4, 5 and 6 all touch `KvResizeUnifiedCanvas.test.tsx`; they must run sequentially, appending sibling `describe` blocks.
- Out of scope for this slice, tracked for later M2 slices: per-tile undo (TASK-22, highest risk), the frame/shape/comment tool port (touches `boxPromptUi.tsx`, a genuine Craft change — see PRD risk R-1), tile status UI, inline text editing, and the staged flag rollout.
