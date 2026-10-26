# KV Agentic Canvas P1.1 (Concept Boards) — api Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On a Craft KV canvas the agent can propose, and on Go render, up to 4 NEW boards from scratch (`concept_boards`). The capability reuses the P1 plan card, placeholders, render job, ledger, billing and undo.

**Architecture:** A new plan capability `ConceptBoards`, registered in `KvCanvasCapabilityRegistry`. It shares the placeholder-batch / ledger / dispatch / revert code with `VariantBoards` through a new abstract base `KvRenderedBoardsCapability`. `KvAgentPlanService::transition` learns direction steps of either capability and a concept-only `aspect_ratio` option. `KvVariantRenderer` gains a no-source branch, keyed on the step's capability: no base, no parent, no layer copy, aspect from the plan. The MCP twin `ProposeKvConceptsTool` shares the plans route through `FIXED_ARGS` (D1).

**Tech Stack:** Laravel 13, PHP 8.5, Pest 4, Postgres (scratch `frnd_kv_p0_test`).

**Spec:**
- Service PRD `api/docs/prd/kv-agentic-canvas-p1-1.md` (TASK-0..8).
- Contracts `docs/superpowers/plans/2026-10-23-kv-agentic-canvas-p1-1-concept-contracts.md`: C1, C2, C3, C5, C6, C7, C8, C9, C12.
- These extend the P1 contracts in `docs/superpowers/plans/2026-10-22-kv-agentic-canvas-p1-structure-contracts.md`.

Worktree: `api/.worktrees/kv-agentic-canvas-p1-1`, branch `feature/daffa/vc-kv-agentic-canvas-p1-1`. All paths below are relative to it.

## Global Constraints

- Capability name: `concept_boards` = `KvAgentPlan::CAPABILITY_CONCEPTS`. Tool name: `propose_kv_concepts`. MCP class: `ProposeKvConceptsTool`. Capability class: `ConceptBoards`. Do not rename anything.
- Allowed aspect ratios are exactly `KvVariantRenderer::ASPECT_RATIOS` = `['16:9', '9:16', '1:1']`. The default is `'1:1'`. Do NOT add `4:5`.
- `KvAgentPlanService::MAX_VARIANTS` (4) caps concept steps as well. It is not renamed.
- A direction is at most `KvAgentPlanService::MAX_DIRECTION` (500) characters. There are at most 3 suggestions per direction and at most 3 `extra_directions`, each a `{label ≤ 40, direction}`.
- With the flag off, P1 behaviour is unchanged. The flag is `kv-agentic-canvas-structure` (`studio.kv_agent_structure_flag` in tests). The concept capability is only reachable through flagged routes and flagged turns.
- No migration. `kv_agent_plans.options` gains `aspect_ratio` on concept plans only.
- Tests: scratch Postgres `frnd_kv_p0_test`, `TELESCOPE_ENABLED=false`, test PATHS (not `--filter`). Use the runner `scratchpad/t.sh [paths]`. Baseline: 539 passed, 3 failed. The 3 failures are UpdateKvLayersToolTest OAuth "Invalid key supplied", which is environmental.
- Commits: one per task, `feat(api): KV agentic canvas P1.1 — …`, each ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. No push, no stash, no rebase.
- Run `vendor/bin/pint --dirty --format agent` before each commit.

## Review Focus

1. **An empty canvas.** Concept placeholders start at `(0,0)` and continue at 640, 1280, …. The existing tests always have 2 boards, so Task 3 adds an empty-canvas case.
2. **A Go that edits a concept plan.** A `new_<n>` row on a concept plan becomes a concept step with no `board_id`. Before this change the template was variant-only, so the row was silently dropped. Task 2 covers it.
3. **The aspect ratio on Go.** `plan_action.options.aspect_ratio` passes the `CardAnswer::planActionRules` whitelist (`excludeUnvalidatedArrayKeys` would strip it otherwise). An invalid value is refused with no state change, and `copy_layers` on a concept plan is ignored. Task 2 covers it, including a stream-level case.
4. **A concept render.** It sends `base_generation: null` and `brand_logo_stamp: null`. It persists without `parent_generation_id` or `source_board_id`, and it lands with a rekey only. A plan whose `options.aspect_ratio` is missing or garbled renders `1:1`. Task 4 covers it.
5. **Variant behaviour after the refactor.** `VariantBoards` is unchanged byte for byte at the ledger and collab level, so the full P1 set stays green in Task 3 and Task 6.

---

### Task 0: Close the P1 track

**Files:** Modify `docs/tracks/kv-agentic-canvas-p1.track.md`, which is frontmatter and status table only.

- [ ] Set frontmatter `status: completed` and the status-table PR row to `merged (https://github.com/alva-intelligence/frnd-api-php/pull/791)`. Set Implementation to `completed` if it is not already.
- [ ] Commit `docs(api): KV agentic canvas P1.1 — close P1 track (api#791 merged)`.

### Task 1: `CAPABILITY_CONCEPTS` + `ConceptBoards::proposeSteps` + registry (TASK-1 propose part, TASK-2, TASK-6 propose)

**Files:**
- Modify `app/Models/KvAgentPlan.php`: add `CAPABILITY_CONCEPTS = 'concept_boards'`.
- Create `app/Services/Studio/AgentCanvas/Capabilities/ConceptBoards.php`.
- Modify `app/Services/Studio/AgentCanvas/Capabilities/KvCanvasCapabilityRegistry.php`: append `ConceptBoards::class` after `AddSizes::class`.
- Test: `tests/Feature/Studio/AgentCanvas/KvConceptBoardsTest.php` (new).

**Interfaces:**
- Produces:
  - `final class ConceptBoards extends KvPlanCapabilityBase`, with `NAME = KvAgentPlan::CAPABILITY_CONCEPTS` and `DEFAULT_ASPECT = '1:1'`.
  - `proposeSteps(array $params, KvCanvasState $state): array{goal, steps, options}`.
  - Each step is `{id: 'step_<ulid>', capability: 'concept_boards', params: {direction, suggestions}, estimate: KvVariantImageModel::credits($file) + ['seconds' => VariantBoards::SECONDS]}`.
  - `options` is `{aspect_ratio: string, extra_directions: list}`, with no `copy_layers` and no `source_board`.
  - The goal is `"N new idea(s)"`.
  - `toolSchema()` has `directions` (1–4, items `{direction, suggestions ≤3}`), `extra_directions` (≤3) and `aspect_ratio` (enum ASPECT_RATIOS, default 1:1).
- Task 1 leaves `executeSteps` / `revert` as minimal stubs. Task 3 replaces them.

- [ ] **Write failing tests** in `KvConceptBoardsTest.php` (uses `BuildsKvCanvas`, flag on). Each test calls `app(ConceptBoards::class)->proposeSteps($params, $assembler->load($file))`:
  - `it('builds one concept step per direction with no board, an R2 estimate and the aspect option')`:
    - params: 2 directions, one with one suggestion, plus `extra_directions` [1] and `aspect_ratio: '9:16'`.
    - Expect `goal === '2 new ideas'`.
    - Expect each step `capability === 'concept_boards'` and `array_keys(params) === ['direction','suggestions']`.
    - Expect `estimate` to equal `KvVariantImageModel::credits($file) + ['seconds' => 70]`.
    - Expect `options === ['aspect_ratio' => '9:16', 'extra_directions' => [...]]`.
  - `it('defaults the aspect ratio to 1:1')`: no `aspect_ratio` gives `options.aspect_ratio === '1:1'`.
  - `it('refuses invalid concept params with invalid_params')`, as a dataset over each case, all catching `KvCanvasToolException` with `errorCode === 'invalid_params'` and status 422:
    - 5 directions;
    - 4 suggestions;
    - 4 extras;
    - a 501-char direction;
    - a blank direction;
    - `aspect_ratio: '4:5'`.
  - `it('refuses zero directions with nothing_to_propose')`: with `directions: []`, expect errorCode `nothing_to_propose`.
  - `it('is registered as a plan capability')`: `app(KvCanvasCapabilityRegistry::class)->names('plan') === ['variant_boards','add_sizes','concept_boards']`.
- [ ] Run `t.sh tests/Feature/Studio/AgentCanvas/KvConceptBoardsTest.php`. Expect FAIL (class missing).
- [ ] **Implement.**
  - Validation reuses `validateParams` with the same rule set as `VariantBoards` under the `directions.*` key, plus `aspect_ratio => ['sometimes','nullable','string', Rule::in(KvVariantRenderer::ASPECT_RATIOS)]`.
  - Zero directions is checked before validation: `directions` is missing or `[]`, so throw `nothing_to_propose`.
  - Pull the shared direction / suggestion rules and the suggestion schema up into the new abstract base (see Task 3). Task 1 may already create the base holding just those static helpers. `VariantBoards` keeps calling them, and its rules stay identical.
- [ ] Run the test file and expect PASS. Run the P1 set and expect 539 + new, 3 failed.
- [ ] Commit `feat(api): KV agentic canvas P1.1 — concept_boards capability + proposal`.

### Task 2: Plan service + Go generalisation, plan view (TASK-3, TASK-4, TASK-6 Go)

**Files:**
- Modify `app/Services/Studio/AgentCanvas/KvAgentPlanService.php` (`transition`).
- Modify `app/Services/Studio/AgentCanvas/KvAgentPlanView.php`.
- Modify `app/Support/Chat/CardAnswer.php` (`planActionRules`): `options` becomes `array:copy_layers,aspect_ratio`, and `options.aspect_ratio` gets `['sometimes','string','max:8']`. The rule stays shape-only; membership is checked in `transition`.
- Modify the docblock in `app/Support/Chat/KvPlanAction.php`.
- Modify the route test `tests/Feature/Studio/AgentCanvas/KvPlanToolRouteTest.php` (concept propose through the route + plan view shape).
- Tests:
  - `tests/Feature/Studio/AgentCanvas/KvAgentPlanServiceTest.php` (add concept cases);
  - `tests/Feature/Studio/AgentCanvas/KvPlanGoTurnTest.php` (one stream case: aspect ratio survives the request whitelist).

**Interfaces:**
- `transition(...)` takes `$options` of shape `array{copy_layers?: bool, aspect_ratio?: string}|null`.
  - On a concept plan, `aspect_ratio` not in `ASPECT_RATIOS` throws `KvCanvasToolException::unprocessable('invalid_params', …)` before `$assertAffordable` and before any save. On a concept plan, `copy_layers` is ignored (not stored).
  - On a non-concept plan, `aspect_ratio` is ignored.
- The direction-step capabilities are `[CAPABILITY_VARIANTS, CAPABILITY_CONCEPTS]`, a private const `DIRECTION_CAPABILITIES`. They are both the `new_` template source and the `MAX_VARIANTS` count. The error message stays `'A plan makes at most 4 variants.'` for variants and reads "ideas" for concepts.
- The plan view for a concept plan is `source_board: null` and `options: {aspect_ratio, extra_directions}`, with no `copy_layers`. Variant and size plans are unchanged.

- [ ] **Write failing tests.**
  - In `KvAgentPlanServiceTest`, add a helper `proposeConcepts(?threadId, n)` with steps of `capability: 'concept_boards'`, params `{direction, suggestions}` and options `{aspect_ratio: '1:1', extra_directions: []}`.
    - `it('turns a new_ row into a concept step with no board on Go')`: Go `['step_1','new_1']` with override `new_1 → 'monas at dusk'`. Expect 2 accepted, the new step `capability === 'concept_boards'`, `params === ['direction' => 'monas at dusk', 'suggestions' => []]`, and an id starting `step_`.
    - `it('caps a concept plan at 4 ideas')`: 3 steps + `new_1` + `new_2`, expect `invalid_plan_action`, with the plan still `proposed`.
    - `it('stores the picked aspect ratio and ignores copy_layers on a concept plan')`: options `['aspect_ratio' => '9:16', 'copy_layers' => false]`. Expect `options.aspect_ratio === '9:16'` and `array_key_exists('copy_layers', options) === false`.
    - `it('refuses an aspect ratio outside the presets without touching the plan or the credit gate')`: `'4:5'`, with a closure that records it was called. Expect `invalid_params`, the closure not called, and the plan still `proposed` with `aspect_ratio` `'1:1'`.
    - `it('ignores aspect_ratio on a variant plan')`: with `proposeVariants()` plus `['aspect_ratio' => '9:16']`, the options get no `aspect_ratio` key.
    - `it('views a concept plan with no source board and the aspect option')`: `KvAgentPlanView::of($plan, 10)`. Expect `source_board === null`, `options === ['aspect_ratio' => '1:1', 'extra_directions' => []]`, and `capability === 'concept_boards'`.
  - In `KvPlanToolRouteTest`, `it('stores a proposed concept plan through the plans route')`:
    - POST `{capability: 'concept_boards', params: {directions: [{direction: 'merah putih'}], aspect_ratio: '16:9'}}`.
    - Expect 200, `data.source_board === null`, `data.options.aspect_ratio === '16:9'`, and `data.steps[0].params === ['direction' => 'merah putih', 'suggestions' => []]`.
    - A POST with `aspect_ratio: '4:5'` gives 422 `invalid_params`.
  - In `KvPlanGoTurnTest`, `it('carries a concept aspect ratio through plan_action.options')`:
    - Re-propose the thread's card plan as a concept plan in the test: overwrite `$this->plan` with a concept proposal on the same thread and card message.
    - Run `planTurn('go', ['plan_id' => …, 'options' => ['aspect_ratio' => '9:16']])`.
    - Expect `plan->fresh()->options['aspect_ratio'] === '9:16'`.
- [ ] Run the three files and expect FAIL (template variant-only, view copy_layers, whitelist strips aspect).
- [ ] Implement as specified in Interfaces.
- [ ] Run the three files and expect PASS. Run the P1 set and expect green except the baseline 3.
- [ ] Commit `feat(api): KV agentic canvas P1.1 — concept plans on Go (new_ rows, aspect_ratio) + plan view`.

### Task 3: Shared rendered-boards base + `ConceptBoards::executeSteps` placement + undo (TASK-1 execute/revert, C6 1–4, C8)

**Files:**
- Create `app/Services/Studio/AgentCanvas/Capabilities/KvRenderedBoardsCapability.php` (abstract, extends `KvPlanCapabilityBase`).
- Modify `VariantBoards.php` (extend the base; keep `final`, its constants and its public API).
- Modify `ConceptBoards.php`.
- Tests:
  - `tests/Feature/Studio/AgentCanvas/KvConceptBoardsTest.php` (execution cases);
  - `tests/Feature/Studio/AgentCanvas/UndoKvJobOpsTest.php` (one concept undo case).

**Interfaces:**
- `abstract class KvRenderedBoardsCapability extends KvPlanCapabilityBase`:
  - constructor `(KvCollabWriter $collab, KvAgentRunRecorder $recorder)`;
  - `protected function room(KvAgentRun $run): int` (the existing `min(...)` of three);
  - `protected function placeAndQueue(KvAgentRun $run, KvCanvasState $state, array $placements, array $skipped): array{applied, skipped}`, where `$placements` is `list<array{step: array, center: array{x: float, y: float}, source_board_id: ?string}>`;
  - `revert()` (moved verbatim from `VariantBoards`);
  - static `directionRules(string $prefix)`, `suggestionSchema()`.
  - `placeAndQueue` builds the add_board/render ops exactly as `VariantBoards` does today. It adds `source_board_id` to the add_board `after` and to the render job op ONLY when it is non-null. It runs the collab batch, maps failures and records, then dispatches `RenderKvVariantJob`.
- `ConceptBoards::executeSteps`:
  - skip `run_op_cap_reached` past `room()`;
  - centres = `KvBoardPlacement::nextFreeCenters(visible board centres, count($runnable))`;
  - then `placeAndQueue` with `source_board_id: null`.

- [ ] **Write failing tests.**
  - In `KvConceptBoardsTest`, add a helper `acceptedConceptPlan(array $directions, ?array $accept = null, string $aspect = '1:1')` (propose → service propose → transition go) and reuse `runVariantSteps`-style POST `plans/steps/run`.
    - `it('places concept placeholders after the right-most visible board and queues one render each')`:
      - The fixture has A at 0 and B at 1200, so expect x `[1840.0, 2480.0, 3120.0]`, y 0.
      - Expect one collab batch, names `KvBoardLabel::deriveVariantName(direction, n)`, and `applied` states `queued`.
      - Expect ledger ops `capability === 'concept_boards'` with `placeholder: true`, and `array_key_exists('source_board_id', $ledger[1]) === false` for the render op and for `$ledger[0]['after']`.
      - Expect `RenderKvVariantJob` pushed 3 times.
    - `it('starts at the origin on an empty canvas')`:
      - Set the fake collab document `boards` to `[]` (and `removed` to `[]`).
      - Expect x `[0.0, 640.0]`, y `[0.0, 0.0]`.
    - `it('ignores hidden boards when placing')`: hide B (`removed[] = B`), then expect the first x to be `640.0`.
    - `it('adds no second placeholder when Go runs again')`: same as the variant test.
  - In `UndoKvJobOpsTest`, `it('hides untouched concept boards and keeps an edited one')`:
    - Extend `undoPlan()` to resolve the class by capability through the registry.
    - Run 2 concepts, render the first (land), edit nothing, and Undo via the existing reverter call used in that file.
    - Expect both placeholder/landed boards `isHidden`, and credits unchanged by Undo.
    - The "edited one is kept" half reuses the file's existing edit helper if one exists. If not, assert only the untouched path, and note that the kept-path is shared code covered by the variant case.
- [ ] Run and expect FAIL.
- [ ] Implement the base, move the shared code out of `VariantBoards` (its placement loop stays: `adjacentFreeCenter` chain, `target_not_found`), and implement `ConceptBoards::executeSteps`.
- [ ] Run the new tests plus `KvVariantExecutionTest`, `RenderKvVariantJobTest`, `UndoKvJobOpsTest`, `KvPr791ReviewFixesTest` and `KvRoundBReviewFixesTest`. Expect PASS. Then run the full P1 set.
- [ ] Commit `feat(api): KV agentic canvas P1.1 — concept placeholders, placement and undo (shared rendered-boards base)`.

### Task 4: `KvVariantRenderer` no-source branch (TASK-5, C6 renderer, C7)

**Files:**
- Modify `app/Services/Studio/AgentCanvas/KvVariantRenderer.php`.
- Test: `tests/Feature/Studio/AgentCanvas/RenderKvConceptJobTest.php` (new, same `beforeEach` as `RenderKvVariantJobTest`, which fakes `/complete`).

**Interfaces:**
- `renderLocked` computes `$isConcept = ($step['capability'] ?? null) === KvAgentPlan::CAPABILITY_CONCEPTS`.
  - Concept: no source lookup; base `null`; aspect `self::conceptAspect($plan)`, which returns `options.aspect_ratio` if it is in `ASPECT_RATIOS`, else `'1:1'`; no `parent_generation_id`; metadata `{agent_run_id, plan_step_id, direction}`; `land(..., copyLayers: false)`.
  - Variant: byte-identical to today, including the `source === null` fail.
  - The fail message for a missing file / user / workspace / thread on a concept step reads `'The board\'s file is gone.'`.

- [ ] **Write failing tests** in `RenderKvConceptJobTest`:
  - `it('renders a concept from scratch in the plan aspect and lands it with a rekey only')`:
    - Go a 1-concept plan with `aspect_ratio: '9:16'`, run the steps, then `renderVariant($step)`.
    - Expect the ai call `base_generation === null`, `brand_logo_stamp === null`, `aspect_ratio === '9:16'`, `prompt === direction`, `canvas_mode === 'craft'`.
    - Expect the generation `parent_generation_id === null`, metadata to match `{agent_run_id, plan_step_id, direction}`, and `array_key_exists('source_board_id', metadata) === false`.
    - Expect the land batch ops kinds `['rekey_board_tip']`, render op `state: done`, and the add_board op rekeyed onto the generation.
  - `it('renders 1:1 when the plan aspect is missing or not a preset')`: `forceFill(options.aspect_ratio = '4:5')` on the accepted plan before render, and expect the ai call `aspect_ratio === '1:1'`.
  - `it('hides the concept placeholder and reports render_failed when ai-service fails')`.
  - `it('reports a concept run item with no source board')`:
    - After landing, `KvAgentRunView` items (use the function the run route uses; check the `KvAgentRunItemsTest` helper).
    - Expect the item to match `{kind: 'board', state: 'done', board_id: gen id, source_board_id: null}`, with credits > 0 after settle.
- [ ] Run and expect FAIL (currently "The source board or its file is gone.").
- [ ] Implement.
- [ ] Run the new file plus `RenderKvVariantJobTest` and expect PASS.
- [ ] Commit `feat(api): KV agentic canvas P1.1 — no-source render branch for concept boards`.

### Task 5: `PROPOSAL_TOOLS` + MCP twin (TASK-7, TASK-8, C9, C12)

**Files:**
- Modify `app/Services/Studio/AgentCanvas/KvAgentCanvasTurn.php:37` and append `'propose_kv_concepts'`.
- Create `app/Mcp/Tools/ProposeKvConceptsTool.php`, with `FIXED_ARGS = ['capability' => KvAgentPlan::CAPABILITY_CONCEPTS]` and name `propose_kv_concepts`. Its `paramsDescription()` describes `{directions, extra_directions?, aspect_ratio?}`.
- Modify `app/Mcp/Servers/FrndosServer.php` and register it after `ProposeKvSizesTool`.
- Modify the docblocks of `KvCanvasPlanToolController` and `RunKvPlanStepTool`. The description changes "propose_kv_variants / propose_kv_sizes" to include concepts.
- Tests:
  - `tests/Unit/Mcp/KvCanvasToolsTest.php` (twin registered, name);
  - `tests/Feature/Studio/AgentCanvas/KvPlanToolRouteTest.php` (FIXED_ARGS + twin call through `proposePlan` with `capability: 'concept_boards'`);
  - update the tool-list expectations in `KvAgentCanvasTurnTest.php:57`, `KvAgentCanvasStreamTest.php:269` and `KvPlanGoTurnTest.php:141` to end with `'propose_kv_concepts'`.

- [ ] Update and add the tests, then run them. Expect FAIL.
- [ ] Implement.
- [ ] Run the tests and expect PASS. Run `php artisan mcp:verify-mirror` and expect OK with one more twin (97 → 98).
- [ ] Commit `feat(api): KV agentic canvas P1.1 — propose_kv_concepts on the turn + MCP twin`.

### Task 6: Track, full run, review

- [ ] Full P1 set via `t.sh`: expect `539 + new` passed and the 3 baseline failures.
- [ ] Update `docs/tracks/kv-agentic-canvas-p1-1.track.md`:
  - ticks;
  - Implementation `completed`;
  - a session log entry with the commits, test counts vs baseline, DB, and deviations.
- [ ] Tick the service PRD TASK boxes.
- [ ] Commit `docs(api): KV agentic canvas P1.1 — track`.
- [ ] Run superpowers:requesting-code-review once. Fix the Critical and Important findings with TDD, one commit, then re-run the set.

## Deviations already known (report to lead)

- **D-1: a missing `aspect_ratio` on propose defaults to `1:1`.** C2 calls it "required", but TASK-6 and the lead brief say "default 1:1". An invalid value is still 422 `invalid_params`. ai-service always sends it (C4), so nothing changes for siblings.
- **D-2: the run item's `source_board_id` is present and `null`.** C7 says "no `source_board_id` in the item". The key stays present with a `null` value, the same as size items today. R8's item shape is fixed.
- **D-3: the renderer branches on the step's capability, not on `op.source_board_id === null`.** A variant op that somehow lacks a source still fails as in P1.
- **D-4: `CardAnswer::planActionRules` needed `options.aspect_ratio` whitelisted.** The contracts did not name this seam. Without it, `excludeUnvalidatedArrayKeys` strips the ratio on Go.
- **D-5: the estimate uses `KvVariantImageModel::credits`**, as `VariantBoards` does. That is the R2 formula. The PRD's mention of "LLMHelper::estimateImageCredits" is stale.
- **D-6: a missing `directions` key is 422 `invalid_params`.** Only `directions: []` returns `nothing_to_propose`, which matches C2's "zero directions". This was ruled at the final review.
- **Ruling (Task 3/4): the landed-concept undo case lives in `RenderKvConceptJobTest`.** Task 3's undo test covers a queued concept run.
