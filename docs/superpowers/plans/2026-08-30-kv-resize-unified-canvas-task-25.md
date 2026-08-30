# KV Resize Unified Canvas — TASK-25 (Text tool + inline editing) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Place text on the unified Resize canvas and edit it in place, the way Craft does — and close a silent data-loss path the placement tools already have.

**Architecture:** The text tool arms through the M2c-a tool seam and places on a click, exactly like the comment pin. Editing uses **fabric's native `Textbox.enterEditing()`**, matching Craft — not the per-tile path's DOM `OverlayTextEditor`. Editing opens on PLACEMENT, as in Craft; there is no double-click entry on either canvas.

**Tech Stack:** Next.js, React, TypeScript, Fabric v7, `bun test`.

**Spec:** `frnd/docs/prd/kv-resize-unified-canvas.md` (approved). TASK-25 on the track.

**Base branch:** `feature/daffa/vc-kv-resize-unified-canvas` — M1 through TASK-24, synced with develop, pushed. Runtime items 6–9 are outstanding and do not block this slice.

---

## The decisions this slice rests on — established by reading, do not revisit

**1. Native fabric editing, NOT the per-tile DOM editor.** There are two systems in this codebase and they differ in behaviour:

| | Per-tile (`KvTileOverlayEditor`) | Craft (`KvFabricCanvas`) |
|---|---|---|
| Mechanism | DOM `OverlayTextEditor` over the canvas | `Textbox.enterEditing()` / `isEditing` |
| Auto-fit width | Yes, every keystroke (`computeFittedBox` → `applyOverlayFit`) | None — `applyOverlayFit` appears nowhere in that file |
| Empty commit | Removes the overlay | No |
| Persistence | `onLiveChange` so Resize re-fits locally and PATCHes once | Persists on exit |

Daffa chose **Craft's**. Auto-fit only ever changed the BOX WIDTH while typing — `fontSize` is stored explicitly and normalized against board height (`overlayGeometry.ts:90-108`), so the type size never depended on it. Craft, where users spend most of their time, has never auto-fitted. Matching it removes an inconsistency rather than creating one.

**A consequence that is strictly better here:** native editing writes nothing per keystroke — the Textbox edits in place and persists once on exit. On this surface every commit is a PATCH, so the DOM editor needed a separate `onLiveChange` path purely to avoid a network write per character. That whole problem disappears.

**2. Editing opens on PLACEMENT, and there is no double-click.** `setEditingTextId` is set non-null in exactly one place in the layout (`KvGeneratorLayout.tsx:4293`, on placing new text) and cleared by the canvas on exit (`KvFabricCanvas.tsx:2608`). `KvFabricCanvas` has no `mouse:dblclick` at all. Daffa chose full gesture parity.

**3. Therefore the TEXT TOOL must be ported in this slice.** The unified canvas's tool union is `"cursor" | "shape" | "comment" | "frame"` — text was never ported. With no double-click and no text tool, an editor would have zero entry points and this slice would ship something unreachable.

---

## A silent data-loss path this slice also closes

**Shape and comment placement have NO done-only refusal.** Grepped: every `status !== "done"` check in `KvResizeUnifiedCanvas.tsx` (`:1580`, `:2300`) and `KvResizeCanvas.tsx` (`:1923`, `:1983`) belongs to the frame tool or detection. The shape gesture (`~:1563`) and the host's `onPlaceShape` (`~:1891`) refuse only `!board` / `isMaster`.

So a shape can be placed on a tile that is mid-generation: `appendOverlayToTile` → `commitTileOverlays` → PATCH, and then the arriving regenerate replaces the row wholesale and **the shape is silently gone**. This is the same family as the Critical a whole-slice review found in TASK-23 (dragging an overlay on a regenerating tile). That fix made non-done boards non-**selectable**, which closes the drag path — placement does not go through selection, so it was untouched.

The text tool needs this refusal anyway. **Add it to shape and comment at the same time**, at both the gesture and the host, matching how the frame tool already refuses at both layers.

---

## Global Constraints

- **Test runner is `bun test`, run from `web/`.** NOT `bunx vitest`, NOT from inside the component directory (`bunfig.toml` sets `root = "src"` and the jsdom preload relative to `web/`).
- **Never modify these — imported by production Craft (`KvFabricCanvas.tsx`):** `fabricExport.ts`, `ghostOverlay.ts`, `overlayGeometry.ts`, `overlayMutations.ts`, `overlayAspect.ts`, `overlaySelection.ts`, `overlayAlign.ts`, `overlayClipboard.ts`, `boxPromptUi.tsx`, `useTileOverlayHistory.ts`, `focusCamera.ts`, `polygonPoints.ts`, `boxFromCandidate.ts`, `KvRulerOverlay.tsx`, `rulerUtils.ts`. Import freely; edit none. **`KvFabricCanvas.tsx` itself is READ-ONLY** — read its editing effect as the template, change nothing in it.
- **Never modify the per-tile path:** `KvTileOverlayEditor.tsx`, `KvResizeTileStage.tsx`, `KvResizeViewport.tsx`, `resizeApron.ts`, `KvResizeResultRow.tsx`, `KvResizeOriginalRow.tsx`.
- **Do NOT port auto-fit.** No `applyOverlayFit` on this path. That is the decision, not an omission.
- **Board-strict.** Overlay ids are NOT unique across boards — an inheriting tile preserves the master's ids, which has already caused a bug here. Resolve the board from the fabric object's `data.resizeBoardId`, never from the overlay id alone.
- **Flag-off behaviour must be byte-identical.**
- **No new type errors in touched files; eslint clean.** Touched-file tsc baseline is **5**.
- **Do NOT use `git stash`** — copy aside with `cp`. Documented incident: stash/pop corrupted files with conflict markers. Do not leave stale copies in the shared scratchpad.
- **Every new test must be MUTATION-PROVEN.** Break it, watch the NAMED test fail, restore, re-run. Show both. A survivor means the fixture is too weak — fix the fixture, never the mutant. Report every first-fixture survivor and what it exposed, and separately any that survives BY CONSTRUCTION.

### Test infrastructure — TEN incidents

Extend a proven-safe suite; do not create a file. `KvResizeUnifiedCanvas.test.tsx`, `KvFrameBoxLayer.test.tsx`, `KvBoardStatusLayer.test.tsx`, `KvResizeCanvas.unifiedUndoReveal.test.tsx` are proven safe. Append sibling `describe` blocks; never restructure existing ones. Baseline **1260 pass / 13 fail / 2 errors**, FAIL LIST diffed line by line. Known flake: `KvTileDownloadDropdown > disables the trigger when the tile is not done`.

### Fixture discipline

- **A `done`-status tile everywhere** hid a Critical once and is the direct ancestor of the data-loss path above. Fixtures here must include a non-done tile.
- **Single-board fixtures** cannot tell "the right board" from "the only board", and overlay ids repeat across boards.
- **1x-camera-only** hides every projection error; assert at a scale that is not 1 with x and y translations that differ.
- A mutation that is a no-op as written proves nothing.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `KvResizeUnifiedCanvas.tsx` | Text tool arms + places; done-only refusal added to shape/comment/text | 1 |
| `KvResizeUnifiedCanvas.tsx` | Native `enterEditing` on `editingOverlayId`; persist on exit | 2 |
| `KvResizeCanvas.tsx` | Routes `onPlaceText`; passes the editing id; done-only refusals at the host | 3 |
| track file | Session log | 4 |

---

## Task 1: The text tool, and the missing refusal

**Files:** modify `KvResizeUnifiedCanvas.tsx`; test in `KvResizeUnifiedCanvas.test.tsx` (append a sibling `describe`).

**The comment pin is your template** — same gesture (a click, not a drag), same board resolution, same board-strict callback. Read that block before writing anything.

**Produces:**
```ts
  /** A text overlay placed by a CLICK, in that board's frame-normalized
   *  coordinates. Same shape as `onPlaceComment`. */
  onPlaceText?: (boardId: string, point: { x: number; y: number }) => void;
```
and `"text"` added to the `tool` union, armable only when `onPlaceText` is present — the affordance-lie gate every other tool here carries.

- [ ] **Step 1: Read the per-tile text placement** — the `mouse:down` branch in `KvTileOverlayEditor` that handles `tool === "image" | "text" | "comment"` (places on an EMPTY press only, on that path) and `KvResizeCanvas.handleTilePlaceText`.
- [ ] **Step 2: Write the failing tests.** Cover: a click on a tile reports that board's id and the normalized point; a click in the gap reports nothing; `tool="cursor"` reports nothing; no handler ⇒ the tool does not arm; **a click on a non-done tile reports nothing**; a click on the MASTER board DOES report (the master has no status and text on the master is legitimate — unlike the frame tool, which is tiles-only for a different reason); and the same three refusals now hold for the SHAPE and COMMENT tools, which is the data-loss fix.
- [ ] **Step 3: Run them, confirm they fail.**
- [ ] **Step 4: Implement.** Add the done-only refusal to all three placement gestures. Write a comment at each saying it exists because placement does not go through selection, so TASK-23's non-selectable gate does not cover it.
- [ ] **Step 5: Run tests; mutation-prove.** At minimum: drop the text arming gate; drop the done-only refusal from each of the three tools independently; place on the wrong board; report raw scene coordinates instead of normalized.
- [ ] **Step 6: Commit** — `feat(web): place text on the unified resize canvas, and refuse placement on a busy tile`

---

## Task 2: Native inline editing

**Files:** modify `KvResizeUnifiedCanvas.tsx`; test in `KvResizeUnifiedCanvas.test.tsx`.

**The template is `KvFabricCanvas.tsx:2590-2632`** — READ-ONLY. It finds the object by `data.elementId`, `setActiveObject`, `enterEditing()`, `selectAll()`, and on exit clears the request and persists content + fill onto the overlay, spreading the previous payload so `fontFamily`/`fontSize` survive.

**Produces:**
```ts
  editingOverlayId?: string | null;
  onEditingOverlayIdChange?: (id: string | null) => void;
```

- [ ] **Step 1: Read the template**, and note the payload-spread comment: a bare `{type, content, color}` rewrite drops the typography. That bug is already documented there; do not reintroduce it.
- [ ] **Step 2: Write the failing tests.** Cover:
  - with `editingOverlayId` set to a TEXT overlay's id, that fabric object enters editing (`isEditing` true) and is the active object;
  - a non-text overlay id enters nothing;
  - an id that matches nothing enters nothing and does not throw;
  - **the object on the OWNING board enters editing, not a same-id object on another board** — the fixture must be two boards carrying the same overlay id;
  - exiting persists content through the board's commit path, with `fontFamily`/`fontSize` preserved from the previous payload;
  - exiting clears the editing id exactly once;
  - **nothing is written per keystroke** — assert the commit path is untouched while `isEditing` is true.
- [ ] **Step 3: Run them, confirm they fail.**
- [ ] **Step 4: Implement.** Persist through the board's existing commit route, not a new one.
- [ ] **Step 5: Run tests; mutation-prove.** At minimum: enter editing for a non-text overlay; pick the first same-id object regardless of board; drop the payload spread; never clear the editing id; write on every keystroke.
- [ ] **Step 6: Commit** — `feat(web): edit text overlays natively on the unified resize canvas`

---

## Task 3: Host wiring

**Files:** modify `KvResizeCanvas.tsx`; test in `KvResizeCanvas.unifiedUndoReveal.test.tsx` (extend the existing mock; do NOT create a file).

- [ ] **Step 1: Route `onPlaceText`** through `resolveCommitTarget` into the host's existing `handleTilePlaceText` / `handleMasterPlaceText`. Reuse; do not reimplement. Those already open the editor on placement (`setEditingOverlayId(id)`), which is the Craft gesture — verify that rather than adding a second trigger.
- [ ] **Step 2: Pass `editingOverlayId` / `onEditingOverlayIdChange`**, reusing the host's existing state (the per-tile rows already use it). Do not add parallel state.
- [ ] **Step 3: Add the done-only refusal** to the host's `onPlaceShape`, `onPlaceComment` and the new `onPlaceText`, matching how `onBoxesChange` and `onDetectRegion` already refuse at `:1923` / `:1983`. Defence in depth, same as the frame tool has at both layers.
- [ ] **Step 4: Decide and state flag-gating.** Compare with TASK-23's retry/cancel (ungated: lifecycle), TASK-24's display props (ungated: pure display) and the region-edit props (gated: they ARE that surface). Say which text placement resembles and why, in the code.
- [ ] **Step 5: Write the host tests** — placement on a tile mints through `handleTilePlaceText`; on the master through the master path; on a non-done tile writes nothing; the editing id reaches the canvas.
- [ ] **Step 6: Run tests; mutation-prove; confirm flag-off is byte-identical.**
- [ ] **Step 7: Commit** — `feat(web): wire the text tool and inline editing into the unified resize canvas host`

---

## Task 4: Track file

- [ ] **Step 1: Session-log entry** — what landed, what diverged and why, first-fixture survivors and what each exposed, verification numbers. Tick TASK-25.
- [ ] **Step 2: Record the two decisions** so TASK-26 does not re-litigate them: native editing (no auto-fit, no double-click, full Craft parity), and the text tool ported here rather than left for the merge.
- [ ] **Step 3: Record the data-loss fix** — shape and comment placement had no done-only refusal, the same family as TASK-23's Critical, closed here at both layers.
- [ ] **Step 4: Add the runtime item** — *place text on a tile and confirm the editor opens immediately and you can type; click away and confirm the text persists with its font intact; place a shape on a tile that is mid-generation and confirm you cannot.*
- [ ] **Step 5: Commit** — `docs(web): record TASK-25 on the unified-canvas track`

---

## Self-Review Notes

- Order: **1 → 2 → 3 → 4.** Task 2 consumes 1's tool only loosely (editing can be tested by setting the id directly); Task 3 consumes both.
- **The thing most likely to be got wrong** is the payload spread on exit: dropping it silently strips `fontFamily` and `fontSize` from every edited overlay, and the read-only render then falls back to box height (`overlayGeometry.ts:97-107`), so the text visibly changes size. Craft's own comment documents this; the test must assert typography survives, not just content.
- **Second: board resolution.** Same-id overlays on two boards is the fixture that catches it; a single-board fixture cannot.
- Out of scope: TASK-26/27; the image tool (`"image"` is still normalized to `"cursor"` and remains unported — note it in the track so the merge knows).
- Still open, NOT fixed here: runtime items 6–9; the `KV_RESIZE_REGION_EDIT` OFF direction; the four unreachable-by-construction gaps from M2c-b2; the latent `discardCandidateArea` bug in production Craft.
