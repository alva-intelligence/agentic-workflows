# KV Resize Unified Canvas — TASK-25 (Inline text editing) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Double-click a text overlay on the unified Resize canvas and edit it in place, with the same auto-fit and empty-removes behaviour the per-tile path has.

**Architecture:** Ports the per-tile path's DOM editor (`OverlayTextEditor`) rather than Craft's native Fabric text editing. It renders in a wrapper positioned at `boardViewportRect(board, camera)` — the same seam the frame tool, the status chrome and the popover already use — and its geometry comes from the board's projected rect instead of the tile's display size.

**Tech Stack:** Next.js, React, TypeScript, Fabric v7, `bun test`.

**Spec:** `frnd/docs/prd/kv-resize-unified-canvas.md` (approved). TASK-25 on the track.

**Base branch:** `feature/daffa/vc-kv-resize-unified-canvas` — M1 through TASK-24, synced with develop, pushed. Runtime items 6–9 are outstanding and do NOT block this slice.

---

## The decision this slice rests on — do not revisit it, do implement it

**There are TWO inline-text-editing systems in this codebase, and they differ in BEHAVIOUR, not just implementation.** Established by reading:

| | Per-tile path (`KvTileOverlayEditor`, the surface this canvas replaces) | Craft (`KvFabricCanvas`) |
|---|---|---|
| Mechanism | DOM `OverlayTextEditor` positioned over the canvas, driven by `editingOverlayId` | fabric's native `Textbox.enterEditing()` / `isEditing`, driven by `editingTextId` |
| Auto-fit width | **Yes**, recomputed on every keystroke (`computeFittedBox` → `applyOverlayFit`) | **None** — `applyOverlayFit` appears nowhere in that file |
| Empty commit | **Removes the overlay** ("no ghost text") | No |
| Persistence | `onLiveChange ?? onChange` so Resize re-fits locally and PATCHes ONCE, on commit | Persists on exit |

**Daffa chose the DOM editor**, for behaviour parity: auto-fit and empty-removes are visible to anyone using Resize today, and dropping them would be a regression the unified canvas is supposed to avoid. TASK-26 can keep both editors behind `canvasMode` — that is what the mode exists for — so this is not work built to be thrown away.

Consequence to write down for TASK-26: after this slice, the merged file will host two text editors selected by mode. Do not silently converge them there without deciding it deliberately.

---

## What to port, and the exact pieces

`KvTileOverlayEditor.tsx` (READ-ONLY) does this:
- **Enter:** `mouse:dblclick` → if the hit object's overlay is `payload.type === "text"`, call `onEditingOverlayIdChange(id)` (`:493-499`).
- **Guard:** `effectiveEditingOverlayId = isActive ? editingOverlayId : null` (`:270`) — an inactive tile never shows an editor even if the host's id points into it. **The unified canvas has boards, not an active tile, so the equivalent is: the editor renders for the board that OWNS the overlay, and only that board.**
- **Render** (`:2307-2388`): find the overlay, bail unless it is text, compute `x/y/w/h` from the overlay's normalized box times the tile's display size, measure with `overlayTextMetrics` against the SAME box the read-only render uses, then render `OverlayTextEditor` with `initial`, `color`, `bbox`, `fontSizePx`, `rotation`.
- **`computeFittedBox(text)`**: `measureTextWidth(text, fontSizePx)` plus `fontSizePx * 0.2` padding, normalized against the frame width, clamped to `[0.02, 1]`, with `x` pulled back so the box stays inside the frame.
- **`onInput`**: live re-fit via `applyOverlayFit`, emitted through `onLiveChange ?? onChange` — **this runs on EVERY keystroke, and on Resize every commit is a PATCH**, which is exactly why the live path is separate from the committed one.
- **`onCommit`**: empty → `removeOverlay` + deselect; otherwise `applyOverlayFit` then `updateOverlayContent`, chained into ONE update, then clear the editing id.
- **`onCancel`**: clear the editing id, change nothing.

`OverlayTextEditor` lives at `./overlays/OverlayTextEditor` and is imported by `KvTileOverlayEditor` and `KvKonvaCanvas`. **`KvFabricCanvas` does NOT import it**, so it is not on the Craft-shared list — but treat it as **import-only** anyway: a second consumer exists, and this milestone has not needed to edit a shared component yet.

---

## Global Constraints

Every task's requirements implicitly include this section.

- **Test runner is `bun test`, run from `web/`.** NOT `bunx vitest`, and NOT from inside the component directory — `bunfig.toml` sets `root = "src"` and the jsdom preload relative to `web/`.
- **Never modify these — imported by production Craft (`KvFabricCanvas.tsx`):** `fabricExport.ts`, `ghostOverlay.ts`, `overlayGeometry.ts`, `overlayMutations.ts`, `overlayAspect.ts`, `overlaySelection.ts`, `overlayAlign.ts`, `overlayClipboard.ts`, `boxPromptUi.tsx`, `useTileOverlayHistory.ts`, `focusCamera.ts`, `polygonPoints.ts`, `boxFromCandidate.ts`, `KvRulerOverlay.tsx`, `rulerUtils.ts`. Import freely; edit none. **Add `overlays/OverlayTextEditor.tsx` to that list for this slice.**
- **Never modify the per-tile path:** `KvTileOverlayEditor.tsx`, `KvResizeTileStage.tsx`, `KvResizeViewport.tsx`, `resizeApron.ts`, `KvResizeResultRow.tsx`, `KvResizeOriginalRow.tsx`.
- **Board-strict.** The editor belongs to the board that owns the overlay. An overlay id is NOT unique across boards — an inheriting tile preserves the master's ids, which has already caused a bug in this milestone. Resolve the board explicitly; never assume the first match.
- **A non-done tile must not become editable.** Three refusals already defend that, and TASK-23 added a fourth by making non-done boards non-interactive, which means a double-click cannot select their overlays. Do not weaken any of them, and do not add a path that reaches the editor for a non-done board.
- **Flag-off behaviour must be byte-identical.**
- **No new type errors in touched files; eslint clean.** Touched-file tsc baseline is **5**.
- **Do NOT use `git stash`** — copy aside with `cp`. Documented incident: stash/pop corrupted files with conflict markers. Do not leave stale copies in the shared scratchpad.
- **Every new test must be MUTATION-PROVEN.** Break it, watch the NAMED test fail, restore, re-run. Show both. A survivor means the fixture is too weak — fix the fixture, never the mutant. Report every first-fixture survivor and what it exposed, and separately any that survives BY CONSTRUCTION.

### Test-infrastructure warning — TEN incidents

Extend a proven-safe suite; do not create a file. `KvResizeUnifiedCanvas.test.tsx`, `KvFrameBoxLayer.test.tsx`, `KvBoardStatusLayer.test.tsx` and `KvResizeCanvas.unifiedUndoReveal.test.tsx` are proven safe. Append sibling `describe` blocks; never restructure existing ones. Baseline: **1260 pass / 13 fail / 2 errors**, FAIL LIST diffed line by line. Known flake: `KvTileDownloadDropdown > disables the trigger when the tile is not done`.

### Fixture discipline

The traps that have actually bitten here, and the two that apply hardest to this slice:
- **1x-camera-only.** The editor's bbox is a pure camera function. At scale 1 with zero translation a projected bbox and an unprojected one are identical. Assert at a scale that is not 1 and a translation whose x and y DIFFER.
- **Single-board fixtures.** They cannot tell "the board that owns this overlay" from "the only board", and overlay ids repeat across boards here.
- Also: symmetric geometry hides a transpose; a `done`-status tile everywhere hid a Critical once; a mutation that is a no-op proves nothing; and twice an assertion's observable did not exist, so it passed vacuously.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `resizeTextEditGeometry.ts` (new) | Pure: overlay + board + camera → the editor's viewport bbox and font size; and the fitted box for a given string | 1 |
| `resizeTextEditGeometry.test.ts` (new) | Unit tests | 1 |
| `KvResizeUnifiedCanvas.tsx` | Double-click to enter; renders `OverlayTextEditor`; live re-fit, commit, cancel | 2 |
| `KvResizeCanvas.tsx` | Passes `editingOverlayId` / `onEditingOverlayIdChange` and routes the three writes | 3 |
| track file | Session log | 4 |

---

## Task 1: `resizeTextEditGeometry.ts` — the pure half

**Why:** the per-tile version computes the bbox, the metrics and the fitted box inline inside a 2400-line component, so none of it is testable without a canvas. Extracted, Task 2 becomes wiring. This is the same move `resizeCandidatePick.ts` made for the pick derivation, and that paid off.

**Files:**
- Create: `src/components/studio/kv-generator/resizeTextEditGeometry.ts`
- Create: `src/components/studio/kv-generator/resizeTextEditGeometry.test.ts`

**Interfaces:**
- Consumes: `overlayTextMetrics` and `measureTextWidth` from wherever `KvTileOverlayEditor` imports them (find the imports; do not reimplement); `resizeBoardRect` / `ResizeBoard`; `StudioOverlay`
- Produces:

```ts
/** The editor's box in FRAME display px, plus the font size to render at.
 *  Frame px, not viewport px: the caller positions a wrapper at the board's
 *  viewport rect and this sits inside it, exactly like every other piece of
 *  board chrome in this milestone. */
export function textEditorBox(input: {
  overlay: StudioOverlay;
  /** The board's rect in the units the editor will be positioned in. */
  frameWidth: number;
  frameHeight: number;
}): { x: number; y: number; w: number; h: number; fontSizePx: number } | null;

/** The auto-fitted normalized box for `text`, mirroring the per-tile
 *  `computeFittedBox`. Returns the new `x` and `width` only — y and height
 *  are untouched, as on the per-tile path. */
export function fittedTextBox(input: {
  overlay: StudioOverlay;
  text: string;
  fontSizePx: number;
  frameWidth: number;
}): { x: number; width: number };
```

`textEditorBox` returns `null` for a non-text overlay — the caller must not have to re-check.

- [ ] **Step 1: Read the source.** `KvTileOverlayEditor.tsx:2307-2345` — the bbox derivation, the `overlayTextMetrics` call (note it measures against the SAME box the read-only render uses, and why), and `computeFittedBox` including the `0.2` padding factor, the `[0.02, 1]` clamp and the `x` pull-back.

- [ ] **Step 2: Write the failing tests.** Use a NON-SQUARE frame and an overlay whose x, y, width and height are all DIFFERENT, so a transpose cannot pass. Cover:
  - the bbox is the overlay's normalized box times the frame size, on both axes;
  - a non-text overlay returns `null`;
  - `fittedTextBox` widens as the text grows and narrows as it shrinks;
  - the width is clamped at a minimum of `0.02` for an empty string and at `1` for a very long one;
  - `x` is pulled back so `x + width <= 1` when the fitted width would overflow the frame, and is otherwise left alone;
  - a zero-width frame produces no `NaN` or `Infinity`.

- [ ] **Step 3: Run them, confirm they fail** (module missing).
- [ ] **Step 4: Implement**, transcribing the per-tile arithmetic. Do not "improve" the padding factor or the clamps.
- [ ] **Step 5: Run tests; mutation-prove.** At minimum: transpose the axes; drop the padding; drop each clamp; drop the `x` pull-back; return a bbox for a non-text overlay.
- [ ] **Step 6: Commit** — `feat(web): pure text-editor geometry for the unified resize canvas`

---

## Task 2: The editor on the canvas

**Files:**
- Modify: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.tsx`
- Test: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.test.tsx` (new sibling `describe`)

**Interfaces:**
- Consumes: `OverlayTextEditor` (**import only**); Task 1's two functions; `applyOverlayFit`, `updateOverlayContent`, `removeOverlay` from `overlayMutations` (**import only — Craft-shared**)
- Produces:

```ts
  editingOverlayId?: string | null;
  onEditingOverlayIdChange?: (id: string | null) => void;
  /** Live, uncommitted overlay changes for ONE board — fired on every
   *  keystroke by the auto-fit. Separate from `onCommitOverlays` because on
   *  this surface a commit is a PATCH, and re-fitting per character would
   *  PATCH per character. Omitted ⇒ falls back to the committing path. */
  onLiveOverlays?: (boardId: string, next: StudioOverlay[]) => void;
```

- [ ] **Step 1: Add the double-click entry.** A `mouse:dblclick` handler that resolves the hit object's overlay and calls `onEditingOverlayIdChange` only when it is text — mirroring `KvTileOverlayEditor.tsx:493-499`. **Resolve the BOARD from the object's `data.resizeBoardId`, not from the overlay id**, because ids repeat across boards.

- [ ] **Step 2: Write the failing tests.** Cover:
  - double-clicking a TEXT overlay reports its id; double-clicking a shape or image reports nothing;
  - with `editingOverlayId` set, the editor renders, seeded with the overlay's content and colour;
  - it renders inside the wrapper for the board that OWNS the overlay — use a two-board fixture where BOTH boards carry an overlay with the SAME id, and assert the editor lands on the right one. That is the M2a hazard, and a single-board fixture cannot see it;
  - the editor's bbox is PROJECTED: assert at a camera scale that is not 1 and a translation whose x and y differ;
  - typing fires the LIVE path, not the committing one — assert `onLiveOverlays` fired and `onCommitOverlays` did not;
  - committing non-empty text applies the fit AND the content in ONE call to the committing path;
  - committing an EMPTY string removes the overlay and clears the selection;
  - cancel clears the editing id and writes nothing at all;
  - a non-done board's overlay cannot be double-clicked into editing (TASK-23 made those boards non-interactive — confirm the property holds rather than assuming it).

- [ ] **Step 3: Run them, confirm they fail.**
- [ ] **Step 4: Implement.**
- [ ] **Step 5: Run tests; mutation-prove.** At minimum: enter editing for a non-text overlay; render the editor on the wrong board; skip the projection; route the live path to the commit path; drop the fit from the commit; make an empty commit keep the overlay; make cancel write.
- [ ] **Step 6: Commit** — `feat(web): edit text overlays in place on the unified resize canvas`

---

## Task 3: Host wiring

**Files:**
- Modify: `src/components/studio/kv-generator/KvResizeCanvas.tsx`
- Test: `src/components/studio/kv-generator/KvResizeCanvas.unifiedUndoReveal.test.tsx` (proven-safe harness; extend the mock, do NOT create a file)

- [ ] **Step 1: Pass `editingOverlayId` and `onEditingOverlayIdChange`.** The host already owns both (`editingOverlayId` / `setEditingOverlayId`, used by the per-tile rows) — reuse them, do not add parallel state.

- [ ] **Step 2: Route `onLiveOverlays`** through `resolveCommitTarget`, to whatever the host uses for an uncommitted, cache-only overlay update. `useResizeExports` has an apply-to-cache-only path documented as "no request — used for in-progress edits that a commit will follow"; find it and use it rather than inventing one. A master target and a non-done tile must both be refused, as every other host route in this file is.

- [ ] **Step 3: Decide and state flag-gating.** Compare with TASK-23's retry/cancel (ungated: lifecycle) and the region-edit props (gated: they ARE the region-edit surface). Text editing is neither — say which it resembles and why in the code.

- [ ] **Step 4: Write the host tests** — the two ids reach the canvas; a live update on a tile hits the cache-only path and NOT the PATCH; a master and a non-done target are refused.

- [ ] **Step 5: Run tests; mutation-prove; confirm flag-off is byte-identical.**
- [ ] **Step 6: Commit** — `feat(web): wire inline text editing into the unified resize canvas host`

---

## Task 4: Track file

- [ ] **Step 1: Session-log entry** in the shape the recent ones use — what landed, what diverged and why, first-fixture survivors and what each exposed, verification numbers. Tick TASK-25.
- [ ] **Step 2: Record the TASK-26 consequence explicitly** — the merged file will host TWO text editors selected by `canvasMode`, and converging them is a deliberate decision for that slice, not a tidy-up.
- [ ] **Step 3: Add the runtime item** — *double-click a text overlay on a tile, type, and confirm the box re-fits as you type and the text lands where the editor showed it; commit an empty string and confirm the overlay is removed.* Auto-fit is a per-keystroke visual behaviour no jsdom test can judge.
- [ ] **Step 4: Commit** — `docs(web): record TASK-25 on the unified-canvas track`

---

## Self-Review Notes

- Order: **1 → 2 → 3 → 4.** Task 2 consumes 1; Task 3 consumes 2.
- **The live-vs-committed split is the thing most likely to be got wrong**, and it is not cosmetic: on this surface every commit is a PATCH, so routing the per-keystroke re-fit through the committing path would issue one network write per character. If the host wiring for the live path turns out not to exist, say so and stop rather than falling back to the commit path silently.
- **Board resolution is the second.** Overlay ids repeat across boards; resolve from the object's `data.resizeBoardId`.
- Out of scope: TASK-26/27, and converging the two text editors.
- Still open and NOT to be fixed here: runtime items 6–9 (the fixed-size Cancel overhang, the grid behind-vs-over verdict, the 1px grid at 0.05×, the status states); the `KV_RESIZE_REGION_EDIT` OFF direction; the four unreachable-by-construction gaps from M2c-b2; the latent `discardCandidateArea` bug in production Craft.
