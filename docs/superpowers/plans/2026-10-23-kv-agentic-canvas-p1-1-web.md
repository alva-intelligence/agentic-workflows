# KV Agentic Canvas P1.1 — Web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On a Craft canvas, a `concept_boards` plan ("3 new ideas") renders as an editable plan card with an aspect picker, and its parallel placeholders show in the picked aspect — on an empty canvas too.

**Architecture:** `KvPlanCard` gains a `ConceptPlan` branch that shares the variant rows (extracted into one `DirectionRows` part, parametrised by noun) and adds a `SegmentedTabs` aspect picker in place of Copy layers. Placeholders link a run to its concept plan by plan step id (progress `item_id` / run item `plan_step_id`) or `plan.runId`, and take the plan's `options.aspectRatio`; the card writes the picked ratio into the cached plan on Go so placeholders are right before the plan is re-read. The empty-canvas fan-out grid becomes its own component that respects `agent` / `failed`.

**Tech Stack:** Next.js 16, React 19, TypeScript, TanStack Query v5, Base UI v2 components, bun test + Testing Library.

**Spec:** `web/.worktrees/kv-agentic-canvas-p1-1/docs/prd/kv-agentic-canvas-p1-1.md` (service PRD, TASK-0..6) and `docs/superpowers/plans/2026-10-23-kv-agentic-canvas-p1-1-concept-contracts.md` (C3, C5, C7, C10.1, C11, C12). Where they disagree, the contracts win (the service PRD's "4 presets" / "type expands to 4:5" are stale: C5 resolved to 3 presets).

## Global Constraints

- Worktree `web/.worktrees/kv-agentic-canvas-p1-1`, branch `feature/daffa/vc-kv-agentic-canvas-p1-1`. No push, PR, rebase, stash or new branch.
- Capability name `concept_boards`; tool name `propose_kv_concepts`; chip label `Proposing Concepts` (C12). Do not rename.
- Aspect presets are exactly `KvArtboardRatio` = `"16:9" | "9:16" | "1:1"`; default `"1:1"`. No type change (C5).
- Go sends `plan_action.options.aspect_ratio` for a concept plan and never `copy_layers` (C11).
- Max 4 ideas (`MAX_VARIANTS`); "Max 4 ideas" at the cap.
- Same flag as P1: the plan card sits behind the `structure` gate, placeholders behind `kvAgenticCanvasEnabled && kvAgenticStructureEnabled && craft`. With those off, P1 behaviour is unchanged.
- Tests: `bun test <file paths>` only. `within(document.body)`, never `screen`. No `mock.module`. Each test file < 45 KB.
- No new dark hex; tokens / existing `white/[..]` films and v2 components only.
- Commits: `feat(web): KV agentic canvas P1.1 — …` + `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Picked 9:16, pressed Go** — placeholders must draw 9:16 at once, not the proposed 1:1 or the master's aspect while the plan is still cached as `proposed`. Test in Task 5 (card writes the cache; hook reads it).
2. **Empty canvas** — the fan-out grid branch has never drawn agent placeholders: it must show no "✕ Cancel" and must show the failed state. Test in Task 6.
3. **Closed concept card** (executed / expired / superseded) — shows the rows it ran with (incl. promoted added rows) and the plan's ratio, read-only. `closedVariantRows` currently drops non-variant steps. Test in Task 3.
4. **Garbled `aspect_ratio`** (`"4:5"`, missing) from the api — mapper yields `null`, card defaults 1:1, placeholders 1:1. Test in Task 1 + Task 5.
5. **Clarifying card in Craft** with purpose `clarify_intent` — must be a plain answer, never the paid "Transform this into…" render. Test in Task 7.

---

### Task 0: P1 track → completed (TASK-0)

**Files:** Modify `docs/tracks/kv-agentic-canvas-p1.track.md` (frontmatter `status: completed`; status table PR row `merged (https://github.com/alva-intelligence/frnd-web/pull/1104)`, Implementation `completed`; session-log line).

- [ ] Edit, then commit `docs(web): KV agentic canvas P1 — track completed, web#1104 merged`.

### Task 1: Types, plan mapper, plan_action wire (TASK-2, TASK-4)

**Files:**
- Modify `src/types/kv/agentPlan.ts`, `src/services/kv/api.ts` (`toPlanStep`, `toKvAgentPlan`, `WireKvAgentPlan`), `src/hooks/useKvStream.ts` (plan_action body), `src/components/studio/kv-generator/artboardRatios.ts`.
- Test `src/services/kv/agentPlan.api.test.ts`, `src/hooks/useKvStream.planCard.test.ts`, `src/components/studio/kv-generator/artboardRatios.test.ts` (new).

**Interfaces — Produces:**
- `KvAgentPlanCapability = "variant_boards" | "add_sizes" | "concept_boards"`.
- `KvConceptStepParams { direction: string; suggestions: KvDirectionSuggestion[] }`; `KvAgentPlanStep` gains `{ id; capability: "concept_boards"; params: KvConceptStepParams; estimate; done }`.
- `KvAgentPlan.options.aspectRatio: KvArtboardRatio | null` (null on variant/size plans and on a garbled value).
- `KvPlanAction.options?: { copyLayers?: boolean; aspectRatio?: KvArtboardRatio }`.
- `isArtboardRatio(v: unknown): v is KvArtboardRatio`; `ratioAspect(r: KvArtboardRatio): number` (w/h from `ARTBOARD_DIMENSIONS`).

- [ ] **Step 1: failing tests**
  - `artboardRatios.test.ts`: `isArtboardRatio("9:16") === true`, `isArtboardRatio("4:5") === false`, `isArtboardRatio(null) === false`; `ratioAspect("16:9")` ≈ `1920/1080`, `ratioAspect("1:1") === 1`.
  - `agentPlan.api.test.ts` `it("maps a concept plan: no source board, aspect option, direction steps")`: wire `{capability:"concept_boards", source_board:null, steps:[{id:"step_c1", capability:"concept_boards", params:{direction:"Merah putih", suggestions:[{label:"Flag",direction:"Flag waves"}]}, …}], options:{aspect_ratio:"9:16", extra_directions:[…]}}` → `sourceBoard === null`, `steps[0]` equals `{capability:"concept_boards", params:{direction:"Merah putih", suggestions:[{label:"Flag",direction:"Flag waves"}]}}` (matchObject), `options.aspectRatio === "9:16"`, `options.extraDirections` length 1.
  - same file `it("drops an aspect ratio outside the presets")`: `aspect_ratio: "4:5"` → `options.aspectRatio === null`; the variant wire fixture → `options.aspectRatio === null`.
  - `useKvStream.planCard.test.ts` `it("sends a concept Go with aspect_ratio and no copy_layers")`: `planAction: { planId, acceptedSteps:["step_1"], stepOverrides:{}, options:{ aspectRatio:"9:16" } }` → `body.plan_action.options` toEqual `{ aspect_ratio: "9:16" }`. Existing variant case keeps `{ copy_layers: false }`.
- [ ] **Step 2:** `bun test src/components/studio/kv-generator/artboardRatios.test.ts src/services/kv/agentPlan.api.test.ts src/hooks/useKvStream.planCard.test.ts` → FAIL.
- [ ] **Step 3: implement.** Mapper: a `concept_boards` wire step maps to the concept member (direction string or "", `toSuggestions`). `aspectRatio: isArtboardRatio(w.options?.aspect_ratio) ? … : null`. Wire `options` type gains `aspect_ratio?: string | null`. Stream body: `options` built from the defined keys only (`copy_layers` when `copyLayers !== undefined`, `aspect_ratio` when `aspectRatio !== undefined`).
- [ ] **Step 4:** same command → PASS; also `bun test src/components/studio/kv-generator/KvPlanCard.test.tsx src/lib/studio/kv/kvAgentPlan.test.ts` stays green.
- [ ] **Step 5: commit** `feat(web): KV agentic canvas P1.1 — concept plan types, mapper and aspect_ratio on Go`.

### Task 2: Pure concept-plan decisions

**Files:** Modify `src/lib/studio/kv/kvAgentPlan.ts`; test `src/lib/studio/kv/kvAgentPlan.test.ts`.

**Interfaces — Produces:**
- `DEFAULT_CONCEPT_ASPECT: KvArtboardRatio = "1:1"`.
- `planAspectRatio(plan: Pick<KvAgentPlan,"options">): KvArtboardRatio` → `options.aspectRatio ?? "1:1"`.
- `initialVariantRows(plan)` also builds rows from `concept_boards` steps.
- `conceptPlanAction(planId: string, rows: KvVariantRowDraft[], aspectRatio: KvArtboardRatio): KvPlanAction` — same accepted/overrides as `variantPlanAction`, `options: { aspectRatio }`.
- `closedDirectionRows(plan): KvVariantRowDraft[]` — moved from `KvPlanCard.tsx` (`closedVariantRows`), accepting `variant_boards` and `concept_boards` steps.

- [ ] **Step 1: failing tests** — `planAspectRatio` (null → "1:1", "16:9" → "16:9"); `initialVariantRows` on a 2-step concept plan → 2 rows with the directions; `conceptPlanAction("p", rows, "9:16")` with one edited, one unticked, one added row → `{planId:"p", acceptedSteps:[edited, added], stepOverrides:{edited:{direction}, new_1:{direction}}, options:{aspectRatio:"9:16"}}` and no `copyLayers` key; `closedDirectionRows` on an executed concept plan with `acceptedSteps:["step_c1","new_1"]`, `stepOverrides:{new_1:{direction:"Batik"}}` → directions `["<step_c1 direction>", "Batik"]`.
- [ ] **Step 2:** `bun test src/lib/studio/kv/kvAgentPlan.test.ts` → FAIL.
- [ ] **Step 3:** implement; `variantPlanAction` and `conceptPlanAction` share one private `rowsAction(planId, rows)`.
- [ ] **Step 4:** same command → PASS.
- [ ] **Step 5:** commit with Task 3 (the card is the only consumer).

### Task 3: `KvPlanCard` concept branch + plan analytics (TASK-1, TASK-6 part)

**Files:**
- Modify `src/components/studio/kv-generator/KvPlanCard.tsx`, `src/lib/analytics/kv-agent-events.ts`.
- Test `src/components/studio/kv-generator/KvPlanCard.concept.test.tsx` (new; own fixtures, same PointerEvent shim and posthog spy as `KvPlanCard.test.tsx`).

**Interfaces:**
- Consumes Task 1–2 names.
- Produces in `kv-agent-events.ts`: `KvAgentPlanCapabilityProp` adds `"concept_boards"`; `trackKvAgentPlanConfirmed` props gain `aspect_ratio: KvArtboardRatio | null` (variant + size pass `null`, concept passes the pick; concept passes `copy_layers: null`).
- Card: `PlanBody` routes `capability === "concept_boards"` to `ConceptPlan`. `VariantPlan` and `ConceptPlan` share `DirectionRows({ rows, shown, open, locked, noun, setRow })` — `noun` is `"variant"` or `"idea"`, used as "Keep {noun} n", "{Noun} n", "Direction for {noun} n", "Suggestions for {noun} n", placeholder "Describe this {noun}, or pick a suggestion below". Variant copy must render byte-identical to today.
- `ConceptPlan` copy: title `"{n} new idea(s)"` (`plural(shown.length,"new idea","new ideas")`), subtitle `"New boards from scratch · {ratio}"`, add button "Add idea" / "Max 4 ideas" (title "Up to 4 ideas per run"), aspect row label "Aspect ratio" with v2 `SegmentedTabs size="small"` (`aria-label="Aspect ratio"`, items from `ARTBOARD_RATIOS`, all items disabled when closed or locked; closed shows `planAspectRatio(plan)`), footer `"Tick at least one idea"` / `"{n} × render {estimate}"`, same notes. No Copy layers row, no source board.

- [ ] **Step 1: failing tests** (`KvPlanCard.concept.test.tsx`):
  - `it("renders N new ideas with an aspect picker defaulting to the plan's ratio and no Copy layers")`: plan `aspectRatio:"9:16"`, 3 steps → `findByText("3 new ideas")`; `getByRole("group",{name:"Aspect ratio"})`; button "9:16" `aria-pressed="true"`; buttons "16:9","1:1" exist; `queryByLabelText("Copy layers") === null`; `getByLabelText("Direction for idea 1")`; `/3 × render ≈/`.
  - `it("defaults the picker to 1:1 when the plan has no ratio")`: `aspectRatio:null` → "1:1" pressed.
  - `it("Go sends the picked aspect_ratio and fires plan_confirmed with capability concept_boards")`: click "16:9", untick idea 3, click Go → `onSubmit` called with `["go",{planId, acceptedSteps:["step_c1","step_c2"], stepOverrides:{}, options:{aspectRatio:"16:9"}}]`; `plan_confirmed` props match `{capability:"concept_boards", accepted_count:2, aspect_ratio:"16:9", copy_layers:null}`.
  - `it("Add idea prefills from extra_directions and stops at Max 4 ideas")`.
  - `it("plan_shown and plan_cancelled carry capability concept_boards")`.
  - `it("a closed concept plan shows what it ran with and the ratio, read-only")`: `status:"executed"`, `acceptedSteps:["step_c1","new_1"]`, `stepOverrides:{new_1:{direction:"Batik pattern"}}`, `aspectRatio:"9:16"` → texts present, "Done" pill, "9:16" button disabled, no Go button, no textbox.
- [ ] **Step 2:** `bun test src/components/studio/kv-generator/KvPlanCard.concept.test.tsx` → FAIL.
- [ ] **Step 3:** implement (extract `DirectionRows`, add `ConceptPlan`, analytics type changes, pass `aspect_ratio: null` from the variant and size `go`).
- [ ] **Step 4:** `bun test src/components/studio/kv-generator/KvPlanCard.concept.test.tsx src/components/studio/kv-generator/KvPlanCard.test.tsx src/components/studio/kv-generator/KvChat.planCard.test.tsx src/lib/studio/kv/kvAgentPlan.test.ts` → PASS.
- [ ] **Step 5: commit** `feat(web): KV agentic canvas P1.1 — concept plan card (N new ideas, aspect picker)`.

### Task 4: `concept_done` / `concept_failed` (TASK-6 rest)

**Files:** Modify `src/lib/analytics/kv-agent-events.ts`, `src/components/studio/kv-generator/KvAgentRunCard.tsx`; test `src/components/studio/kv-generator/KvAgentRunCard.items.test.tsx`.

**Interfaces — Produces:** `trackKvAgentConceptDone(props: {file_id; run_id; plan_step_id; credits: number | null})` → `kv_agent.concept_done`; `trackKvAgentConceptFailed(props: {…; reason: string})` → `kv_agent.concept_failed`. A board item with `sourceBoardId === null` is a concept (C7: concept items carry no `source_board_id`; every variant item does since P1 R8); it fires the concept event instead of the variant one, once per `run:step` (same Set).

- [ ] **Step 1: failing test** `it("a landed and a failed concept item fire concept_done / concept_failed, not the variant events")`: live run, items `{planStepId:"step_c1", sourceBoardId:null, state:"done", credits:4}`, `{planStepId:"step_c2", sourceBoardId:null, state:"failed"}` → one `kv_agent.concept_done` `{plan_step_id:"step_c1", credits:4}`, one `kv_agent.concept_failed` `{plan_step_id:"step_c2", reason:"render_failed"}`, zero `kv_agent.variant_*`.
- [ ] **Step 2:** `bun test src/components/studio/kv-generator/KvAgentRunCard.items.test.tsx` → FAIL. **Step 3:** implement. **Step 4:** same file + `KvAgentRunCard.test.tsx` → PASS.
- [ ] **Step 5: commit** `feat(web): KV agentic canvas P1.1 — concept_done / concept_failed events`.

### Task 5: Concept placeholders take the plan's aspect (TASK-3)

**Files:**
- Modify `src/lib/studio/kv/kvAgentPlaceholders.ts`, `src/hooks/useKvAgentPlaceholderBoards.ts`, `src/components/studio/kv-generator/KvGeneratorLayout.tsx` (pass `planIds`), `src/components/studio/kv-generator/KvPlanCard.tsx` (cache write on Go).
- Test `src/lib/studio/kv/kvAgentPlaceholders.test.ts`, `src/hooks/useKvAgentPlaceholderBoards.test.tsx`, `src/components/studio/kv-generator/KvPlanCard.concept.test.tsx`.

**Interfaces — Produces:**
- `conceptAspectByRun({ plans, runs, progress }: { plans: KvAgentPlan[]; runs: KvAgentRun[]; progress: KvAgentItemProgressMap }): Record<string, number>` — for each `concept_boards` plan, `ratioAspect(planAspectRatio(plan))` is assigned to `plan.runId`, to every run view with an item whose `planStepId` is a plan step id, and to every progress run with an `itemId` that is a plan step id.
- `placeholderItemsFrom(runs, progress, aspectByRun: Record<string, number> = {})`; `KvAgentPlaceholderItem` gains `aspect: number | null`.
- `agentPlaceholderBoards`: an item with `aspect !== null` draws `baseId: ""` (no board's measured aspect can override it), `aspect: item.aspect`, default name `"Idea"`; others unchanged.
- Hook gains `planIds?: string[]` (default `[]`) and `api.getPlan?` (default `getKvAgentPlan`); plans read under `kvAgentPlanQueryKey(fileId, planId)` (the card's key), `retry:false`, no interval of its own.
- Layout: `agentPlanIds` = the last 3 distinct `m.metadata?.planCard?.planId` in `stream.messages`.
- Card `PlanBody.submit`: on `go` with `action.options?.aspectRatio`, `queryClient.setQueryData(queryKey, old => old && { ...old, options: { ...old.options, aspectRatio } })` before `onSubmit` (the `finally` invalidate still re-reads the server value).

- [ ] **Step 1: failing tests**
  - `kvAgentPlaceholders.test.ts`: `conceptAspectByRun` links by `runId`, by run item step id and by progress step id; a variant plan contributes nothing. `agentPlaceholderBoards` with `generations: []` (empty canvas) and an item `{aspect: 9/16, sourceBoardId:null}` → `{baseId:"", aspect:9/16, name:<artboard name>}`; with `fallbackBaseId:"gen_v2"` still `baseId:""`.
  - hook test `it("draws a concept placeholder in its plan's aspect on an empty canvas")`: doc `{artboards:{ph_c1:{x:0,y:0,name:"Merah putih"}}}`, `generations: []`, `planIds:["01JCPLAN"]`, progress `{"01JRUN":{step_c1:{…boardId:"ph_c1", state:"queued"}}}`, run view items empty, `getPlan` → concept plan with `steps[0].id="step_c1"`, `aspectRatio:"16:9"` → result `[{baseId:"", aspect: 1920/1080, center:{x:0,y:0}}]`, and the plan sits under `kvAgentPlanQueryKey("f1","01JCPLAN")`.
  - `KvPlanCard.concept.test.tsx` `it("Go writes the picked ratio into the cached plan")`: pick "9:16", Go (onSubmit left pending) → `client.getQueryData(kvAgentPlanQueryKey("f1", id)).options.aspectRatio === "9:16"`.
- [ ] **Step 2:** `bun test src/lib/studio/kv/kvAgentPlaceholders.test.ts src/hooks/useKvAgentPlaceholderBoards.test.tsx src/components/studio/kv-generator/KvPlanCard.concept.test.tsx` → FAIL.
- [ ] **Step 3:** implement; wire the layout.
- [ ] **Step 4:** same command + `KvPlanCard.test.tsx` → PASS.
- [ ] **Step 5: commit** `feat(web): KV agentic canvas P1.1 — concept placeholders in the plan's aspect`.

### Task 6: Agent placeholders on an empty canvas

**Files:** Create `src/components/studio/kv-generator/KvPendingBoardsGrid.tsx` (the `isEmpty && pendingBoards.length > 0` grid moved out of `KvCanvas.tsx` verbatim, plus agent handling); modify `KvCanvas.tsx` to render it; test `src/components/studio/kv-generator/KvPendingBoardsGrid.test.tsx` (new).

**Interfaces — Produces:** `KvPendingBoardsGrid({ pendingBoards: KvPendingBoard[]; onCancelPendingBoard?: (pb: KvPendingBoard) => void })`. Key `pb.key ?? fanout:<x>,<y>`; `data-testid="kv-agent-placeholder"` on agent tiles; Cancel only when `!pb.agent`; `pb.failed` shows "Couldn't render · removing" (same copy as `BoardChrome`); else "Generating…".

- [ ] **Step 1: failing tests** — agent tile: name shown, "Generating…", no "Cancel …" button even with `onCancelPendingBoard`; failed agent tile: "Couldn't render · removing"; a non-agent tile keeps "Cancel <name>" and calls the handler; `aspectRatio` style equals `pb.aspect`.
- [ ] **Step 2:** `bun test src/components/studio/kv-generator/KvPendingBoardsGrid.test.tsx` → FAIL. **Step 3:** implement + swap in `KvCanvas`. **Step 4:** → PASS.
- [ ] **Step 5: commit** `feat(web): KV agentic canvas P1.1 — agent placeholders on an empty Craft canvas`.

### Task 7: Chip label + clarifying card as a plain answer (TASK-5, C10.1)

**Files:** Modify `src/lib/studio/kv/kvAgentToolResult.ts`, `src/hooks/useKvStream.ts` (`KvQuestionCardPurpose` gains `"clarify_intent"`), `src/lib/analytics/agent-intent-events.ts` (purpose type), `src/components/studio/kv-generator/KvChat.tsx`; create `src/lib/studio/kv/kvQuestionCardPurpose.ts`; test `src/lib/studio/kv/kvAgentToolResult.test.ts`, `src/lib/studio/kv/kvQuestionCardPurpose.test.ts` (new).

**Interfaces — Produces:** `isPlainAnswerPurpose(p: string | null | undefined): boolean` — true for `targets`, `layer`, `clarify_intent`. `KvChat`'s `onGenerateSelected` gate uses it instead of the two inline comparisons. `KIND_BY_CHIP` gains `"Proposing Concepts": "plan"`, `propose_kv_concepts: "plan"`.

- [ ] **Step 1: failing tests** — `kvAgentToolKind("Proposing Concepts") === "plan"`, `kvAgentToolKind("propose_kv_concepts") === "plan"`; `isPlainAnswerPurpose` true for the three, false for `"direction"`, `null`, `undefined`.
- [ ] **Step 2:** `bun test src/lib/studio/kv/kvAgentToolResult.test.ts src/lib/studio/kv/kvQuestionCardPurpose.test.ts` → FAIL. **Step 3:** implement. **Step 4:** → PASS.
- [ ] **Step 5: commit** `feat(web): KV agentic canvas P1.1 — Proposing Concepts chip, clarify card answers plainly`.

### Task 8: Verify, track, review

- [ ] Run every test file touched above in one `bun test <paths>` call → all PASS.
- [ ] `node_modules/.bin/tsc --noEmit -p .` → error count and the set of files with errors vs the HEAD baseline (`80c02b206`); no new errors in touched files.
- [ ] Track `docs/tracks/kv-agentic-canvas-p1-1.track.md`: tasks ticked, Implementation `completed`, session log (commits, tests, tsc, deviations, asks for api/ai-service). Commit `docs(web): KV agentic canvas P1.1 — track`.
- [ ] One superpowers:requesting-code-review pass over `80c02b206..HEAD`; fix Critical/Important; re-run the tests.
