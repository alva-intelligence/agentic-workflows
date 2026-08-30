# KV Resize Unified Canvas — TASK-24 (Ruler + grid) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the unified Resize canvas the ruler bars and background grid the per-tile viewport already has.

**Architecture:** Almost entirely reuse. The ruler is a standalone, camera-parameterised component that Craft already drives from a `{scale, x, y}` camera identical in shape to ours — so it is imported unchanged and handed our camera. The grid is a CSS background whose only Resize-specific piece (an opacity-parameterised gradient) is module-private in a forbidden file and must be duplicated.

**Tech Stack:** Next.js, React, TypeScript, Fabric v7, `bun test`.

**Spec:** `frnd/docs/prd/kv-resize-unified-canvas.md` (approved). TASK-24 on the track.

**Base branch:** `feature/daffa/vc-kv-resize-unified-canvas` — M1 through TASK-23, synced with develop, pushed. The runtime checklist passed 2026-08-30 (items 6 and 7 from TASK-23 still owe a real generation).

---

## What already exists — established by reading, so nobody re-derives it

**`KvRulerOverlay.tsx` is already exactly what we need, and must NOT be edited.** It takes `showRuler`, `stageScale`, `stagePosition`, `viewportWidth`, `viewportHeight`, `gridSize` — a camera as props, no viewport coupling. **`KvFabricCanvas.tsx` (production Craft) imports it** and drives it at `:5806` with `stageScale={camera.scale}` / `stagePosition={{x: camera.x, y: camera.y}}` / `width` / `height`. That is the same camera shape the unified canvas holds. **This is the `boxPromptUi` story again: import it, hand it the camera, change nothing.** If you find yourself needing to edit it, STOP and escalate — that is a Craft change.

**Craft has NO background grid.** Zero occurrences of `backgroundImage` in `KvFabricCanvas.tsx`. The grid is a Resize-only affordance, so there is no Craft precedent to copy for it.

**The grid, on the per-tile path** (`KvResizeViewport.tsx:243-257`, READ-ONLY):
- gated on the SAME `showRuler` flag as the ruler — one toggle drives both;
- `backgroundImage: makeGridBgImage((gridOpacity / 100).toFixed(2))` — two 1px linear-gradients. **`makeGridBgImage` is module-private in that forbidden file**, so it has to be duplicated here. Precedent in this milestone: `MIN_SHAPE_DRAG_SCREEN_PX` in `resizeFrameGesture.ts`, duplicated with a comment pointing at its twin;
- `backgroundSize`: `max(step * scale, 1)` px square, where `step = gridSize ?? pickGridStep(scale)`;
- `backgroundPosition` is set IMPERATIVELY on a ref inside the viewport's `applyTransform`, because that component drives its transform outside React. **The unified canvas holds its camera in React state, so `backgroundPosition` is a plain style value here — simpler, and deliberately not a copy of the imperative version.**

**`pickGridStep` and `pickTickStep` live in `rulerUtils.ts`** and are importable.

**`GRID_BACKGROUND_IMAGE` in `rulerUtils.ts` is a DEAD EXPORT** — zero consumers repo-wide (grepped). Do not adopt it just because it looks like the right constant: it hardcodes `0.12` alpha and this feature is opacity-parameterised. Leave it alone; removing dead code is not this task.

**The host already has all three props** — `showRuler`, `gridOpacity`, `gridSize` (`KvResizeCanvas.tsx:143-145`, defaulted at `:223-225`), passed to `KvResizeViewport` at `:2047-2049`. They only need passing to the unified canvas too.

**One thing genuinely new: the zoom range.** `KvResizeViewport` clamps scale to **0.25–3**; the unified canvas clamps to **0.05–5**. So the ruler and the grid step will be exercised across a range they never have been. `pickTickStep` falls back to `500` below `0.02` and `pickGridStep` to `500` below `0.05`, so the extremes are handled — but they are handled by a fallback nobody has looked at on this surface, and that deserves a test at both ends rather than an assumption.

---

## Global Constraints

Every task's requirements implicitly include this section.

- **Test runner is `bun test`, run from `web/`.** NOT `bunx vitest`, and NOT from inside the component directory — `bunfig.toml` sets `root = "src"` and the jsdom preload relative to `web/`, so a run started elsewhere fails with `ReferenceError: document is not defined`.
- **Never modify these — imported by the production Craft canvas (`KvFabricCanvas.tsx`):** `fabricExport.ts`, `ghostOverlay.ts`, `overlayGeometry.ts`, `overlayMutations.ts`, `overlayAspect.ts`, `overlaySelection.ts`, `overlayAlign.ts`, `overlayClipboard.ts`, `boxPromptUi.tsx`, `useTileOverlayHistory.ts`, `focusCamera.ts`, `polygonPoints.ts`, `boxFromCandidate.ts`, **`KvRulerOverlay.tsx`**, **`rulerUtils.ts`**. Import freely; edit none.
- **Never modify the per-tile path:** `KvTileOverlayEditor.tsx`, `KvResizeTileStage.tsx`, `KvResizeViewport.tsx`, `resizeApron.ts`, `KvResizeResultRow.tsx`, `KvResizeOriginalRow.tsx`.
- **Flag-off behaviour must be byte-identical.** Everything added to `KvResizeCanvas.tsx` goes inside the existing `unifiedCanvasEnabled ?` branch.
- **No new type errors in touched files; eslint clean.** The touched-file tsc baseline is **5** (pre-existing `as const` readonly-tuple sites in `KvResizeUnifiedCanvas.test.tsx`).
- **Do NOT use `git stash`** — copy files aside with `cp` and restore with `cp`. Documented incident: stash/pop corrupted files with conflict markers. Do not leave stale copies in the shared scratchpad.
- **Every new test must be MUTATION-PROVEN.** Break the implementation, watch the NAMED test fail, restore, re-run. Show both outputs. A surviving mutant means the fixture is too weak — fix the fixture, never the mutant. Report every mutant that survived its first fixture and what it exposed, and separately any that survives BY CONSTRUCTION (a provable no-op).

### Test-infrastructure warning — TEN incidents in this milestone

bun's mock registry is process-global and load order is NOT alphabetical. **Extend a proven-safe suite rather than creating a file** — `KvResizeUnifiedCanvas.test.tsx`, `KvFrameBoxLayer.test.tsx`, `KvBoardStatusLayer.test.tsx` and `KvResizeCanvas.unifiedUndoReveal.test.tsx` are all proven safe. Append sibling `describe` blocks; never restructure existing ones.

Baseline to confirm: **1243 pass / 13 fail / 2 errors**, with the FAIL LIST diffed line by line, not just the count. Known flake: `KvTileDownloadDropdown > disables the trigger when the tile is not done` moves between a named fail and the error count, at HEAD too.

### Fixture discipline — what has actually bitten here

**1x-camera-only** is the trap that applies hardest to this task: a ruler and a grid are pure camera functions, and at scale 1 with zero translation almost every wrong implementation looks right. Every geometry assertion must run at a scale that is not 1 AND a translation that is not 0. Others that have bitten: symmetric geometry (`x==y` or `w==h` hides a transpose); single-board fixtures; a mutation that is a no-op as written; and — twice — an assertion whose observable did not exist, so it passed vacuously.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `KvResizeUnifiedCanvas.tsx` | Renders the grid background and the ruler, both driven by the camera | 1 |
| `KvResizeCanvas.tsx` | Passes `showRuler` / `gridOpacity` / `gridSize` through | 2 |
| track file | Session log | 3 |

---

## Task 1: Grid and ruler on the canvas

**Files:**
- Modify: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.tsx`
- Test: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.test.tsx` (new sibling `describe`, appended)

**Interfaces:**
- Consumes: `KvRulerOverlay` from `./KvRulerOverlay` and `pickGridStep` from `./rulerUtils` — **both import-only**
- Produces:

```ts
  /** Show the ruler bars AND the background grid. One toggle drives both, as
   *  on the per-tile path. */
  showRuler?: boolean;
  /** Grid line alpha, 0-100. Defaults to 13, matching KvResizeViewport. */
  gridOpacity?: number;
  /** Fixed grid step in image px. Omitted ⇒ derived from the camera scale by
   *  `pickGridStep`. Also aligns the ruler's ticks when set. */
  gridSize?: number;
```

- [ ] **Step 1: Read both sources.** `KvResizeViewport.tsx:243-257` (the grid div, and note the imperative `backgroundPosition` you are deliberately NOT copying) and `KvFabricCanvas.tsx:5805-5813` (Craft driving the ruler from its camera — your template for the ruler half).

- [ ] **Step 2: Write the failing tests.** Every geometric assertion runs at a camera that is **neither scale 1 nor translation 0**; say so in a comment. Cover:
  - with `showRuler` false (and omitted) neither the grid nor the ruler renders;
  - with `showRuler` true both render;
  - the grid's `backgroundSize` is `max(step * scale, 1)` px square, with `step` from `pickGridStep(scale)` — assert against a scale where `pickGridStep` returns something other than its fallback, and separately at a scale below `0.05` where it returns `500`, since the unified canvas can reach zooms the per-tile viewport never could;
  - an explicit `gridSize` overrides `pickGridStep` — pick a value `pickGridStep` would never return at that scale, or the test cannot tell them apart;
  - `gridOpacity` reaches the gradient (assert the alpha in `backgroundImage`), and defaults to 13 when omitted;
  - `backgroundPosition` follows the camera translation, asserted at a non-zero `x` AND a different non-zero `y` — equal values would hide a transpose;
  - the ruler receives the canvas's own camera: assert through rendered ruler output rather than by spying on props, and at a scale/translation combination where a wrong camera would visibly differ;
  - the grid sits BEHIND the boards and swallows no events (`pointer-events-none`) — a full-bleed `inset-0` layer over the canvas would otherwise kill selection and panning outright.

- [ ] **Step 3: Run them, confirm they fail.**

- [ ] **Step 4: Implement.** Duplicate the opacity-parameterised gradient helper with a comment naming `KvResizeViewport`'s `makeGridBgImage` as its twin and saying why it is duplicated (module-private in a file this milestone must not edit). `backgroundPosition` is a plain style value here — the per-tile version is imperative only because that component drives its transform outside React.

- [ ] **Step 5: Run tests; mutation-prove.** At minimum: render the grid when `showRuler` is false; drop the `gridSize` override; hardcode the opacity; drop the `* scale` from `backgroundSize`; drop the `max(…, 1)` floor; feed the ruler a fixed camera instead of ours; transpose the `backgroundPosition` axes; make the grid hit-testable.

- [ ] **Step 6: Commit** — `feat(web): draw the ruler and grid on the unified resize canvas`

---

## Task 2: Host wiring

**Files:**
- Modify: `src/components/studio/kv-generator/KvResizeCanvas.tsx`
- Test: `src/components/studio/kv-generator/KvResizeCanvas.unifiedUndoReveal.test.tsx` (proven-safe harness — extend the existing mock; do NOT create a file)

- [ ] **Step 1: Pass `showRuler`, `gridOpacity` and `gridSize`** to `KvResizeUnifiedCanvas`, inside the existing `unifiedCanvasEnabled ?` branch. They are already props on the host with defaults; do not re-default them differently.

- [ ] **Step 2: Decide and state whether these are flag-gated.** They are pure display affordances with no backend and no destructive action. Compare with TASK-23's retry/cancel decision (deliberately ungated, because gating lifecycle actions would make this surface worse than the one it replaces) and with the region-edit props (gated, because they ARE the region-edit surface). Say why in the code.

- [ ] **Step 3: Write the host test** — assert the three values reach the canvas mock. Extend the existing `./KvResizeUnifiedCanvas` mock to surface them.

- [ ] **Step 4: Run tests; mutation-prove; confirm flag-off is byte-identical.**

- [ ] **Step 5: Commit** — `feat(web): pass the ruler and grid settings into the unified resize canvas`

---

## Task 3: Track file

- [ ] **Step 1: Add the session-log entry** in the shape the recent entries use: what landed, what diverged and why, which mutants survived their first fixture and what each exposed, and the verification numbers. Tick TASK-24.
- [ ] **Step 2: Add the runtime item** — the ruler and grid are pure visual affordances that no jsdom test can judge. Add: *turn the ruler on and confirm the ticks line up with the boards at 100%, then zoom to both extremes (0.05× and 5×) and confirm the ruler stays legible and the grid does not disappear or turn into a solid fill.* That range is wider than the per-tile viewport ever allowed, so it is genuinely unexercised.
- [ ] **Step 3: Commit** — `docs(web): record TASK-24 on the unified-canvas track`

---

## Self-Review Notes

- Order: **1 → 2 → 3.** Task 2 consumes 1.
- This is a SMALL slice by design — most of it is reuse. If it starts growing, that is a signal something was misread, not that the task was bigger than it looked.
- **The one real unknown is the zoom range**, not the drawing. Both step-pickers have untested fallbacks below the per-tile viewport's old floor, and the unified canvas goes five times lower. Test both ends.
- Out of scope: TASK-25 (inline text editing), TASK-26/27 (the merge into `KvFabricCanvas` and the ~2000-LOC deletion), and removing the dead `GRID_BACKGROUND_IMAGE` export.
- Still open and NOT to be fixed here: the fixed-size working-state Cancel button overhanging at low zoom (TASK-23, runtime item 6 picks the threshold); the `KV_RESIZE_REGION_EDIT` OFF direction being unprovable from the host harness; the four unreachable-by-construction gaps from M2c-b2; the latent `discardCandidateArea` bug in production Craft.
- **A note for whoever does TASK-26.** Craft already renders `KvRulerOverlay` from its own camera, and after this task so does the unified canvas — with the same props, from the same shape of state. That is one less thing to reconcile when the two canvases merge, and worth remembering rather than rediscovering.
