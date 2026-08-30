# KV Resize Unified Canvas — M2c-b2 (Frame Tool: object detection) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the frame tool on the unified Resize canvas — draw a frame, find the objects inside it, pick one or several, prompt the group.

**Architecture:** M2c-b1 landed the frame tool's mechanical half (marquee → clamped box → prompt popover → staged). This slice adds the model-backed half the per-tile editor already has: a post-frame "Find objects / Edit this area" choice, an async detection call, candidate outlines, a text list, group assembly, and prompt retention across unmark/re-pick. All of that chrome is written in FRAME display pixels on the per-tile path, so it reuses b1's projection trick unchanged — a wrapper at `boardViewportRect(board, camera)` with everything inside it camera-free. The one genuinely intricate piece is `pickCandidate`'s box-id derivation, which is extracted to a pure module rather than reimplemented inline.

**Tech Stack:** Next.js, React, TypeScript, Fabric v7, `bun test`.

**Spec:** `frnd/docs/prd/kv-resize-unified-canvas.md` (approved). Completes FR-9.

**Base branch:** `feature/daffa/vc-kv-resize-unified-canvas` — M1 + M2a + M2b + M2c-a + M2c-b1, 64 commits over develop, **pushed 2026-08-30**. `origin/develop` is ~69 commits ahead of the merge base; sync before the PR, not during this slice.

---

## Findings that shaped this plan — read before Task 1

**1. `boxPromptUi.tsx` is still import-only, and that is now proven twice.** `CandidateChips` lives there alongside `BoxPromptPopover`, and like it takes `left`/`top`/`maxLeft`/`maxTop`/`availableHeight` in caller-projected pixels. M2c-a and M2c-b1 both landed with zero Craft blast radius by importing it unchanged; do the same. **If you find yourself needing to EDIT it, STOP and escalate** — `KvFabricCanvas.tsx` imports it and serves Craft in production (PRD risk R-1).

**2. `onDetectRegion` is supplied by `KvResizeResultRow`, not by the host.** `KvResizeResultRow.tsx:369` calls `detectTileObjects(fileId, row.id, region, hint)` directly. `KvResizeCanvas.tsx` has ZERO references to it. So unlike every previous slice, the host wiring here is not "route an existing handler" — it is **new**: `KvResizeCanvas` must import `detectTileObjects` from `@/services/kv/api` and address it by the board's export row id.

**3. The invariant-in-a-forbidden-file pattern has now bitten TWICE.** M1's read-back clamp; M2c-b1's missing tile-status gate (`KvResizeResultRow` renders the editor only for `status === "done"`, which `staleRegionBoxes.ts` states as its premise). Both were missed by every per-task review and caught only by a whole-slice review. **Before wiring detection, re-read what `KvResizeResultRow` gates `onDetectRegion` on** — b1's done-only refusal already covers the gesture, but detection is a MODEL CALL and spending one on a tile that is regenerating would be a second, distinct waste.

**4. Detection is never implicit.** Drawing a frame does not detect. The user gets a two-button pill — "Find objects" (spends a model call) or "Edit this area" (the b1 behaviour). b1 hard-wired the second branch; this slice restores the fork. Every b1 file carries a `b2 seam` comment naming exactly what goes back and where.

---

## Global Constraints

Every task's requirements implicitly include this section.

- **Test runner is `bun test`, run from `web/`.** NOT `bunx vitest`, and NOT from inside the component directory — `bunfig.toml` sets `root = "src"` and the jsdom preload relative to `web/`, so a run started elsewhere fails with `ReferenceError: document is not defined`. Pure `.ts` suites import from `"bun:test"`; component `.tsx` suites import from `"vitest"`.
- **Never modify these — imported by the production Craft canvas (`KvFabricCanvas.tsx`):** `fabricExport.ts`, `ghostOverlay.ts`, `overlayGeometry.ts`, `overlayMutations.ts`, `overlayAspect.ts`, `overlaySelection.ts`, `overlayAlign.ts`, `overlayClipboard.ts`, **`boxPromptUi.tsx`**, `useTileOverlayHistory.ts`, `focusCamera.ts`, `polygonPoints.ts`, `boxFromCandidate.ts`. Import freely; edit none.
- **Never modify the per-tile path:** `KvTileOverlayEditor.tsx`, `KvResizeTileStage.tsx`, `KvResizeViewport.tsx`, `resizeApron.ts`, `KvResizeResultRow.tsx`, `KvResizeOriginalRow.tsx`. Read them for patterns; edit none. Duplication is the intended cost — `KvTileOverlayEditor.tsx` is deleted wholesale by TASK-27.
- **Detection is a MODEL CALL.** It fires only from an explicit "Find objects" click, never from drawing a frame, never from a re-render, never twice for one click. A test that cannot tell "called once" from "called twice" is not good enough here.
- **Fail-soft, end to end.** The api collapses ai-service failures to `{ objects: [] }`; a transport rejection must leave the hand-drawn rectangle standing, not throw and not blank the frame.
- **Tiles only, done only.** The frame tool refuses the master board and any tile whose `status !== "done"`, at every layer. b1 enforces this at the gesture, the chrome render and the host route; detection must not open a fourth door.
- **Board-strict.** A candidate set, a pick and a prompt all belong to the board their frame was drawn on. Candidate sets are keyed by box id (a uuid), but they must also carry the board id — positioning and commits both need it.
- **Never clamp a frame box** beyond what `marqueeToBox` already does (it is an inpaint mask; see b1). Candidate boxes come from the model in normalized coordinates and are used verbatim by `boxFromCandidate` — do not re-clamp or re-project them.
- **Flag-off behaviour must be byte-identical.** Everything added to `KvResizeCanvas.tsx` goes inside the existing `unifiedCanvasEnabled ?` branch.
- **No new type errors in touched files; eslint clean.** The touched-file tsc baseline is **5 errors**, all pre-existing `as const` readonly-tuple sites in `KvResizeUnifiedCanvas.test.tsx` from M2b. Measure against 5, not 0.
- **Never write a raw control character into source** — use the escape form.
- **Do NOT use `git stash`.** Copy files aside with `cp` and restore with `cp`. This repo has a documented incident where stash/pop corrupted files with conflict markers.
- **Every new test must be MUTATION-PROVEN.** Break the implementation, observe the test fail for the right reason, restore, re-run. Show both outputs.

### Test-infrastructure warning — NINE incidents in this milestone

bun's mock registry is process-global and load order is NOT alphabetical. All of these have happened here: a partial `mock.module("@/lib/featureFlags", …)` broke unrelated suites *and* was load-bearing for two others; a divergent factory for a shared specifier flipped a production flag elsewhere; a suite passed in isolation while blanking another; a test **filename** decided whether it collided; a NEW file mocking `./KvResizeUnifiedCanvas` blanked that component's entire suite.

**Prefer extending a proven-safe suite over creating a file.** `KvResizeUnifiedCanvas.test.tsx`, `KvFrameBoxLayer.test.tsx` and `KvResizeCanvas.unifiedUndoReveal.test.tsx` are all proven safe — b1 added 43 tests across them with zero fallout. A new file is acceptable ONLY if it mocks nothing shared (as `KvFrameBoxLayer.test.tsx` does). **`@/services/kv/api` is now a shared mocked specifier** — `unifiedUndoReveal` mocks it, so adding `detectTileObjects` to that factory means keeping every sibling factory for that specifier shape-identical.

After passing in isolation, run the WHOLE directory and confirm the current verified baseline: **1133 pass / 13 fail / 2 errors**. Diff the fail list line by line, not just the count — b1 caught a process-global flag change that way.

### Fixture discipline — SEVENTEEN incidents

Six survived their first fixture in b1 alone. The recurring traps, all of which apply here:
- **symmetric geometry** — `x == y` or `width == height` lets a transposed implementation pass;
- **1x camera only** — a world-px bug and a screen-px bug are indistinguishable at 100% zoom;
- **single-board fixtures** — cannot tell "the right board" from "the only board";
- **an endpoint where no wrong answer is available** — a drag ending in empty space cannot detect resolve-on-mouseup;
- **a `done` fixture everywhere** — b1's Critical was invisible because every test supplied a done tile;
- **a mutation that is a no-op as written** — proves nothing.

For THIS slice add two more: a candidate fixture with **more than `MAX_CANDIDATES` objects** (the cap and the sort are both silent otherwise), and one with **two distinct labels** (dedup-by-label in search is otherwise untestable).

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `resizeCandidatePick.ts` (new) | Pure: given the current boxes and a picked object, derive the next boxes, the target box id and the group | 1 |
| `resizeCandidatePick.test.ts` (new) | Unit tests for the id derivation and group assembly | 1 |
| `KvResizeUnifiedCanvas.tsx` | Detection state, the "Find objects / Edit this area" pill, the in-flight anchor | 2 |
| `KvFrameBoxLayer.tsx` | Candidate outlines + the b1 seams reinstated (border suppression, the two click guards) | 3 |
| `KvResizeUnifiedCanvas.tsx` | `CandidateChips` + pick / hover / right-click list / free-text search | 4 |
| `KvResizeUnifiedCanvas.tsx` | Group prompt (Enter), the three restored Escape rungs, prompt retention | 5 |
| `KvResizeCanvas.tsx` | Supplies `onDetectRegion` per board via `detectTileObjects` | 6 |
| track file | Session log | 7 |

---

## Task 1: `resizeCandidatePick.ts` — the pick's box-id derivation, extracted and pinned

**Why:** this is the single most intricate piece of logic in the whole frame tool, and it is pure. The per-tile version (`KvTileOverlayEditor.pickCandidate`, lines 819–899) decides between three different target box ids, assembles or toggles a group, mints one `__obj` member per object, and threads a retained prompt — all inline, inside a component, untestable without a canvas. Extracting it means Task 4 is wiring instead of reasoning.

**Files:**
- Create: `src/components/studio/kv-generator/resizeCandidatePick.ts`
- Create: `src/components/studio/kv-generator/resizeCandidatePick.test.ts`

**Interfaces:**
- Consumes: `KvBoundingBox`, `KvDetectedObject` from `@/types/studio`
- Produces:

```ts
export type CandidatePickInput = {
  boxes: KvBoundingBox[];
  object: KvDetectedObject;
  /** The drawn frame's own box id — the candidate set this pick came from. */
  frameBoxId: string;
  /** The box id an in-progress pick is already building into, if any. */
  activePickBoxId: string | null;
  /** Objects already folded into the current selection, in click order. */
  picked: KvDetectedObject[];
  /** Shift-click: toggle membership instead of replacing the selection. */
  additive: boolean;
  /** Prompt retained against this object id from a previous unmark. */
  retainedPrompt: string;
  /** Injected so the result is deterministic — the per-tile version calls
   *  `Date.now()` inline, which makes it untestable. */
  newBoxIdSuffix: string;
};

export type CandidatePickResult = {
  next: KvBoundingBox[];
  /** The box the prompt should open on (unless `additive`). */
  boxId: string;
  /** The new group, in click order. */
  picked: KvDetectedObject[];
  /** True when this click REMOVED an object from the group — the caller must
   *  not fire the "box committed" analytics event for a shrinking group. */
  removed: boolean;
};

export function nextBoxesForPick(input: CandidatePickInput): CandidatePickResult;
```

**The three-way id derivation, copied from the per-tile source — get this exactly right:**
- a box is COMMITTED when it already carries a `prompt`;
- if `activePickBoxId` is set and NOT committed → keep building into it;
- else if `frameBoxId` is not committed → upgrade the drawn rectangle in place;
- else → start a new box, id `` `${frameBoxId}__sel${newBoxIdSuffix}` ``.

Group members are `` `${boxId}__obj${object.id}` `` for every object after the first; the first reuses `boxId`. Existing boxes for this selection (`boxId` and its `__obj` members) are replaced, not appended to. `prompt` is `retained.trim() || undefined` — absent, never `""`.

- [ ] **Step 1: Write the failing tests.** Cover, with objects whose `box` rectangles are asymmetric on every axis:
  - a first pick with no `activePickBoxId` and an uncommitted frame box UPGRADES the frame box in place (result `boxId === frameBoxId`, and the frame's hand-drawn geometry is replaced by the object's);
  - a pick when `activePickBoxId` is set and uncommitted keeps building into that id;
  - a pick when BOTH are committed mints `` `${frameBoxId}__sel<suffix>` `` — assert the exact id, using an injected suffix;
  - an additive pick of a NEW object appends it to the group and mints one `__obj` member per extra object, first member reusing `boxId`;
  - an additive pick of an ALREADY-PICKED object REMOVES it, and `removed` is `true`;
  - a non-additive pick REPLACES the group with the single object, and `removed` is `false`;
  - `retainedPrompt: "  "` stores `undefined`, not `""`;
  - boxes belonging to OTHER selections survive untouched, in order;
  - `polygon`, `rings`, `label` and `objectId` are carried from the object onto every member.
- [ ] **Step 2: Run them, confirm they fail** (module missing).
- [ ] **Step 3: Implement**, transcribing the per-tile logic. Do not "improve" the id rules.
- [ ] **Step 4: Run tests; mutation-prove.** At minimum: reverse the committed/uncommitted test; always mint a new `__sel` box; make the first member an `__obj` too; drop the `|| undefined` on the prompt; make an additive re-pick append instead of remove; drop `polygon`/`rings` from the members. Each must break a NAMED test. **If a mutant survives, the fixture is too weak — fix the fixture, never the mutant.**
- [ ] **Step 5: Commit** — `feat(web): pure candidate-pick box derivation for the unified resize canvas`

---

## Task 2: Detection — the post-frame choice, the call, the in-flight anchor

**Why:** detection is a model call, so it is never implicit. The user draws a frame and gets a two-button pill; only "Find objects" spends the call.

**Files:**
- Modify: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.tsx`
- Test: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.test.tsx` (new sibling `describe`, appended — never restructure existing blocks)

**Interfaces:**
- Consumes: `candidatesForRegion`, `polygonArea` from `@/lib/studio/kv/polygonPoints` (import only)
- Produces:

```ts
  /** Detect objects inside a region of ONE board. Omitted ⇒ object-select is
   *  off and the frame tool stays a plain rectangle (b1 behaviour). */
  onDetectRegion?: (
    boardId: string,
    region: { x: number; y: number; width: number; height: number },
    hint?: string
  ) => Promise<KvDetectedObject[]>;
```

Internal state, mirroring the per-tile editor: `detectPrompt` (`{ boardId, boxId, region } | null`), `detectAnchors` (in-flight, one per box), `candidateSets` (`{ boardId, boxId, region, objects, empty }[]`), `focusedBoxId`. **`boardId` on every record** is the addition over the per-tile shapes — that editor is per-tile, so it never needed one. Cap: `MAX_CANDIDATES = 12`, matching Craft.

- [ ] **Step 1: Reinstate the b1 seam.** In the frame tool's `mouse:up`, replace the unconditional `onActiveBoxIdChangeRef.current?.(box.id)` with the per-tile fork: when `onDetectRegion` is wired, set `detectPrompt` instead; otherwise keep the b1 behaviour. The b1 comment marking this line is the seam — update it rather than leaving it claiming detection does not exist.
- [ ] **Step 2: Write the failing tests.** Cover:
  - drawing a frame with `onDetectRegion` wired shows the pill and does NOT call `onDetectRegion` (the "never implicit" rule);
  - clicking "Find objects" calls `onDetectRegion` EXACTLY once, with that board's id and the drawn region;
  - clicking "Edit this area" calls it NOT AT ALL and opens the prompt on the drawn box;
  - a resolved detection stores the candidates sorted smallest-polygon-first and capped at 12 — use a fixture with **15** objects of differing polygon area, and assert both the order and the length;
  - a resolved detection with ZERO objects opens the text list rather than showing nothing;
  - a REJECTED detection drops the candidate set and leaves the drawn box standing (fail-soft);
  - the in-flight anchor renders while the promise is pending and disappears after it settles;
  - with `onDetectRegion` absent the pill never appears and the b1 straight-to-prompt behaviour is unchanged.
- [ ] **Step 3: Run them, confirm they fail.**
- [ ] **Step 4: Implement.** Position the pill and the anchor with `boardViewportRect(board, camera)` plus the region's frame offset, exactly as the popover does. Keep the per-tile clamps (`Math.min(Math.max(left, 120), …)`) — they exist because an absolutely positioned pill near a frame's right edge wraps its labels.
- [ ] **Step 5: Run tests; mutation-prove.** At minimum: detect on frame commit (never implicit); call twice per click; drop the sort; drop the cap; swallow the rejection instead of dropping the set; leave the anchor up after settle.
- [ ] **Step 6: Commit** — `feat(web): detect objects inside a frame on the unified resize canvas`

---

## Task 3: Candidate outlines, and the two b1 seams they close

**Why:** the outlines ARE the affordance — the user picks by clicking a shape, not a list. The list is the fallback.

**Files:**
- Modify: `src/components/studio/kv-generator/KvFrameBoxLayer.tsx`
- Test: `src/components/studio/kv-generator/KvFrameBoxLayer.test.tsx`

**Interfaces:** new optional props — `candidates: { region; objects; empty } | null`, `picked: KvDetectedObject[]`, `hoveredCandidate: KvDetectedObject | null`, `onHoverCandidate`, `onPickCandidate(object, additive)`, `onOpenList()`.

- [ ] **Step 1: Reinstate BOTH b1 seams**, which are marked in the file:
  - the dashed border is suppressed while that box's candidates are on screen (a rect over the outlines read as a stray blue box in Craft);
  - the box click handler bails when that box has a pending `detectPrompt` OR live candidates. **This one is load-bearing**: without it a stray click in a gap between outlines silently throws away a detection.
- [ ] **Step 2: Write the failing tests.** Cover: an object with `rings` draws a `<path>` with `fillRule="evenodd"` and one without draws a `<polygon>`; hovering lifts one outline and dims the rest; an already-picked object draws no outline; a right-click inside the region calls `onOpenList`; a plain click on an outline picks non-additively and a shift-click picks additively; a box with live candidates draws NO dashed border; and clicking such a box does NOT call `onBoxClick`.
- [ ] **Step 3: Run them, confirm they fail.**
- [ ] **Step 4: Implement**, transcribing the per-tile SVG block (`KvTileOverlayEditor.tsx:2001-2100`) — `ringsToSvgPath` for text, `polygonToPoints`/`toSvgPoints` otherwise, the same fills and strokes.
- [ ] **Step 5: Run tests; mutation-prove** each seam and the rings/polygon fork.
- [ ] **Step 6: Commit** — `feat(web): draw candidate outlines on the unified resize canvas`

---

## Task 4: `CandidateChips` — the list, the picks, the search

**Files:**
- Modify: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.tsx`
- Test: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.test.tsx`

**Interfaces:** consumes `CandidateChips` from `./boxPromptUi` (**import only — editing it reopens R-1**) and `nextBoxesForPick` from Task 1.

- [ ] **Step 1: Read the per-tile wiring** (`KvTileOverlayEditor.tsx:2222-2250`) — note `selectedIds`, `availableHeight`, and that the list renders only while `candidates && listOpen && !activeBoxId`.
- [ ] **Step 2: Write the failing tests.** Cover: picking from the list commits `nextBoxesForPick`'s array to the **frame's own board**; hovering a chip drives the outline highlight; a free-text search calls `onDetectRegion` with the hint and appends results **deduped by label** (fixture: two labels, one overlapping); a search returning nothing leaves the list unchanged; the list closes on dismiss; and picking while a prompt is open is impossible (the list is not rendered).
- [ ] **Step 3: Run them, confirm they fail.**
- [ ] **Step 4: Implement.** Position with `boardViewportRect` + the region offset, keeping the per-tile `maxLeft`/`maxTop`/`availableHeight` clamps.
- [ ] **Step 5: Run tests; mutation-prove** the dedup, the hint pass-through, and the board the pick commits to (needs a multi-board fixture).
- [ ] **Step 6: Commit** — `feat(web): pick detected objects from the candidate list on the unified resize canvas`

---

## Task 5: Group prompt, prompt retention, and the restored Escape rungs

**Files:**
- Modify: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.tsx`
- Test: `src/components/studio/kv-generator/KvResizeUnifiedCanvas.test.tsx`

- [ ] **Step 1: Read the per-tile semantics** — `openGroupPrompt` (`:902`), `revertToCandidates` (`:914`), `discardCandidateArea` (`:953`), and the keyboard effect (`:1287`). b1's ladder is `abort drag → close active box`; the full ladder is **abort drag → close list → revert to candidates → close active box → discard area**. The b1 comment names the three rungs to reinsert and where.
- [ ] **Step 2: Write the failing tests.** Cover: Enter with a group assembled and no active box opens the group prompt; saving a prompt applies it to the box AND its `__obj` members (b1 wrote the group logic for exactly this moment — it should need no change, and a test must now prove it); Escape with the list open closes only the list; Escape with an active box that HAS candidates reverts to the outlines instead of closing; Escape with candidates but no active box discards the whole area, removing the frame and its members; Delete discards the pending area outright; and a prompt typed, unmarked, then re-picked is RESTORED (retention by object id, not box id).
- [ ] **Step 3: Run them, confirm they fail.**
- [ ] **Step 4: Implement.** Keep the `typing` guard — the popover input handles its own Enter/Escape.
- [ ] **Step 5: Run tests; mutation-prove** each rung independently (delete one rung at a time; each must break exactly one named test), plus retention keyed by box id instead of object id.
- [ ] **Step 6: Commit** — `feat(web): group prompts and the full escape ladder on the unified resize canvas`

---

## Task 6: Host wiring — supply `onDetectRegion`

**Why:** unlike every previous slice this handler does not exist on the host yet (finding 2).

**Files:**
- Modify: `src/components/studio/kv-generator/KvResizeCanvas.tsx`
- Test: `src/components/studio/kv-generator/KvResizeCanvas.unifiedUndoReveal.test.tsx` (proven-safe harness — extend the existing mock, do NOT create a file)

- [ ] **Step 1: Import `detectTileObjects`** from `@/services/kv/api` and pass `onDetectRegion` gated on `regionEditEnabled`, resolving the board through `resolveCommitTarget`. A master target and a non-done tile must both **reject or resolve empty without calling the api** — detection is a model call, and finding 3 is why this is stated explicitly.
- [ ] **Step 2: Add `detectTileObjects` to the suite's `@/services/kv/api` mock factory.** That specifier is process-global and mocked by several suites: keep every factory for it **shape-identical**, and after the change run the WHOLE directory and diff the fail list, not just the count.
- [ ] **Step 3: Write the host tests.** A detection routed at a tile calls `detectTileObjects(fileId, rowId, region, hint)`; routed at the master it calls nothing; routed at a non-done tile it calls nothing.
- [ ] **Step 4: Run tests; mutation-prove; confirm flag-off is byte-identical.**
- [ ] **Step 5: Commit** — `feat(web): wire object detection into the unified resize canvas host`

---

## Task 7: Track file

- [ ] **Step 1: Add the M2c-b2 session-log entry** to `web/docs/tracks/kv-resize-unified-canvas.track.md`, following the M2c-b1 entry's shape: what landed, what diverged from this plan and why, which mutants survived their first fixture and what each exposed, the verification numbers, and what TASK-9 still owes (nothing, if this slice completes it — say so explicitly and update the task list).
- [ ] **Step 2: Record the runtime debt.** Seven slices will sit on this branch with no browser pass. Add the detection-specific checks to the manual list: draw a frame and confirm nothing is detected until "Find objects" is clicked; confirm a failed detection leaves the rectangle standing.
- [ ] **Step 3: Commit** — `docs(web): record M2c-b2 on the unified-canvas track`

---

## Self-Review Notes

- Order: **1 → 2 → 3 → 4 → 5 → 6 → 7.** Task 4 consumes 1 and 2; Task 3 is independent of 4 but consumes 2's state; Task 5 consumes 3 and 4; Task 6 consumes 2.
- Tasks 2, 4 and 5 all touch `KvResizeUnifiedCanvas.tsx` and its test file — run them sequentially, appending sibling `describe` blocks, never restructuring existing ones.
- **Analytics belongs to this slice:** `trackKvSelectionStaged` and `trackKvSelectionDiscarded` fire only from the detection paths, and `trackKvResizeRegionBoxCommitted` gains its `method: "object_select"` variant. b1 moved that event to the HOST so it can never describe a write the host refused — keep it there and extend it rather than firing a second copy from the canvas.
- **Out of scope, deliberately:** tile status UI (TASK-23), ruler + grid (TASK-24), inline text editing (TASK-25), the merge into `KvFabricCanvas` (TASK-26), the ~2000-LOC deletion (TASK-27), master-row region edit (needs the propagation decision first), and the staged flag rollout.
- **Still open and NOT to be fixed here:** `onRemove`/`onReorder` committing source-frame coordinates into a tile snapshot (pre-existing, equally live flag-off); `downloadOne`/`downloadAll` calling `resolveTileOverlays` directly; the `KV_RESIZE_REGION_EDIT` kill switch's OFF direction being untested on the unified path (b1 documented why the host harness cannot reach it).
- **The risk this plan does not address.** Seven slices, zero browser passes. Nothing here changes that, and this slice makes it worse in one specific way: detection spends **money** per click, and no unit test can tell you whether the pill appears where the user expects, whether the outlines land on the right pixels, or whether a real model response has the shape the fixtures assume. The one-minute checks from b1 still stand; this slice adds a first-real-response check that only a browser can do.
