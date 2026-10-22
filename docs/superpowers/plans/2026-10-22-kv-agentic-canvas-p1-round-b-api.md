# KV Agentic Canvas P1 — Round B (api) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The KV chat can propose N variant boards (≤4) or new sizes (≤20) on a plan card, and on Go the api lands placeholders, renders and sizes idempotently, reports them on the run card and undoes them.

**Architecture:** A `kv_agent_plans` row (DeckAgentPlan shape) holds steps built by two plan capabilities (`VariantBoards`, `AddSizes`) registered in the Round A registry. A `KvCanvasPlanRunner` owns propose + batch execution; `RenderKvVariantJob` renders one variant through the payload builder extracted from `KvToolController::generate` and lands it with one collab batch (`rekey_board_tip` + copied layers). Job ops live in the run ledger with a mutable `state`; the run stays `running` past the turn until the last item settles or the sweeper fails it.

**Tech Stack:** Laravel 13 / PHP 8.5, Postgres jsonb, Pest, queue `default`, Http fakes (`FakeKvCollab`).

**Spec:** `docs/superpowers/plans/2026-10-22-kv-agentic-canvas-p1-structure-contracts.md` (S9, S11–S15, S17, open issues 8–12, Round B addendum R1–R12 + R9 amendment) and `api/.worktrees/kv-agentic-canvas-p1/docs/prd/kv-agentic-canvas-p1.md` TASK-11..23. Main PRD `frnd/docs/prd/kv-agentic-canvas-p1.md` FR-11..24, NFR-2..7, AC-3..11.

## Global Constraints

- Worktree `api/.worktrees/kv-agentic-canvas-p1`, branch `feature/daffa/vc-kv-agentic-canvas-p1`. No new branch, no rebase, no push, never `git stash`.
- Tests: `scratchpad/t.sh <paths>` (scratch Postgres `frnd_kv_p0_test`, `TELESCOPE_ENABLED=false`, deletes `bootstrap/cache/config.php`). Pass test paths, never `--filter`. Never migrate the dev DB `frnd`.
- Baseline (2026-10-22, HEAD 6b75d5e43): AgentCanvas Feature + Unit + `tests/Unit/Mcp` = 408 pass, 3 fail (`UpdateKvLayersToolTest` OAuth "Invalid key supplied" — no passport keys in a worktree).
- Commit per task: `feat(api): KV agentic canvas P1 Round B — …` ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Flag off (`kv-agentic-canvas-structure`) ⇒ P0/intent/Round A payloads, SSE and results byte-identical.
- Contract names are frozen: `kv_agent_plans`, `kv_agent_runs.plan_id`, `kv_agent_runs.summary`, `propose_kv_variants`, `propose_kv_sizes`, `run_kv_plan_step`, `kv_plan_card`, `agent_item_progress`, capability ids `variant_boards` / `add_sizes`.
- Limits: ≤4 variants, ≤3 suggestions per variant, ≤3 extra directions, direction ≤500 chars, ≤20 sizes, ≤24 step ids per run call, plans expire 15 min after proposal.
- Render job: queue `default`, timeout 300, tries 1, `Cache::lock("kv-variant:{step}")`. Collab HTTP timeout stays ≥15 s (Round A `KvCollabWriter::WRITE_TIMEOUT_SECONDS = 20`).
- `excludeUnvalidatedArrayKeys` is on: every new request key is whitelisted in rules.

## Review Focus

1. **Go pressed twice / turn retried with a new run id** — the second Go must not create boards or charge: idempotency reads the PLAN's run (`plan.run_id`), not just the current run. Test in Task 7.
2. **Render lands after Undo, or after its placeholder was hidden by the user** — generation persisted (billed) but never placed on the canvas. Test in Task 9.
3. **Insufficient credits on Go** — plan stays `proposed` with its original steps (overrides not persisted), turn ends with SSE `insufficient_credits`, ai-service never called. Test in Task 5.
4. **Run with open renders when the turn ends** — run stays `running` but the per-file lock is released (next turn can write), and undo is allowed. Test in Task 10.
5. **Size that already exists / layer-only preset / custom size on an AI parent** — a blocked step, never a 422 for the whole plan; all-blocked → 422 `nothing_to_propose`. Test in Task 3.

---

### Task 1: `kv_agent_plans` + `kv_agent_runs.plan_id/summary` (TASK-11)

**Files:**
- Create: `database/migrations/2026_10_24_100000_create_kv_agent_plans_table.php`, `database/migrations/2026_10_24_100100_add_plan_id_and_summary_to_kv_agent_runs.php`, `app/Models/KvAgentPlan.php`
- Modify: `app/Models/KvAgentRun.php` (fillable + casts `plan_id`, `summary`)
- Test: `tests/Feature/Studio/AgentCanvas/KvAgentPlanModelTest.php`

**Interfaces — Produces:**
- `KvAgentPlan` (HasUlids, table `kv_agent_plans`), consts `STATUS_PROPOSED|ACCEPTED|CANCELLED|SUPERSEDED|EXPIRED|EXECUTED`, `CAPABILITY_VARIANTS = 'variant_boards'`, `CAPABILITY_SIZES = 'add_sizes'`; casts `steps`, `estimate`, `options`, `accepted_steps`, `step_overrides` → array, `expires_at` → datetime. Columns per S11 + `capability string(32)` + `options jsonb nullable` (R1).
- `step(string $id): ?array`, `stepAccepted(string $id): bool` (accepted_steps contains it), `isExpiredNow(): bool` (proposed && expires_at past).
- `KvAgentRun::plan(): BelongsTo`.

- [ ] Step 1: test — creates a plan, reads back casts; deleting the plan nulls `kv_agent_runs.plan_id`; deleting the file cascades the plan.
- [ ] Step 2: run → FAIL (no table).
- [ ] Step 3: migrations + model. Indexes (`studio_file_id`,`status`), `thread_id`.
- [ ] Step 4: run → PASS. Step 5: commit.

### Task 2: `KvAgentPlanService` + `KvAgentPlanView` (TASK-12)

**Files:**
- Create: `app/Services/Studio/AgentCanvas/KvAgentPlanService.php`, `app/Services/Studio/AgentCanvas/KvAgentPlanView.php`
- Test: `tests/Feature/Studio/AgentCanvas/KvAgentPlanServiceTest.php`

**Interfaces — Produces:**
- `propose(StudioFile $file, ?string $threadId, User $user, string $capability, string $goal, array $steps, array $options): KvAgentPlan` — `expires_at = now()+15min`, supersedes pending plans on the thread (`superseded_by`).
- `supersedeExisting(?string $threadId, ?string $exceptId = null): int`
- `estimateSteps(array $steps): array{credits_min:int,credits_max:int,seconds:int}` — sums credits of non-blocked steps, `seconds` = max.
- `fresh(KvAgentPlan $plan): KvAgentPlan` — lazy expire (proposed past `expires_at` → `expired`, saved).
- `transition(KvAgentPlan $plan, string $action, ?array $acceptedSteps, ?array $stepOverrides, ?array $options = null, ?Closure $assertAffordable = null): KvAgentPlan` — non-proposed (after `fresh`) returned untouched. `go`: drops unknown and blocked step ids; overrides `{direction}` only, ≤500 chars, keys must be a stored step id or `new_<n>` (new rows clone the first variant step's `board_id`, `suggestions: []`, fresh `step_<ulid>` id, re-estimated); total variant steps ≤4; `options.copy_layers` overrides the stored option; `$assertAffordable(int $creditsMax)` runs BEFORE anything is saved (throws → plan unchanged). `cancel` → `cancelled`.
  Throws `KvCanvasToolException` 422 `invalid_plan_action` for a bad override.
- `markExecuted(KvAgentPlan $plan, ?string $runId): void`, `reopen(KvAgentPlan $plan): void` (accepted → proposed, accepted_steps/run_id null; FR-24).
- `acceptedPlanForStep(string $stepId): ?KvAgentPlan` — `whereJsonContains('steps', [['id' => $stepId]])`, status accepted.
- `KvAgentPlanView::of(KvAgentPlan $plan, ?int $balance): array` — R3 shape; `done` per step from the plan's run ledger (job op state `done`); `source_board` from `options.source_board`, which the view strips from `options`.

- [ ] Step 1: tests — propose sets expiry and supersedes the thread's pending plan (`superseded_by`); a plan 16 min old reads `expired` and is saved so; Go with one unticked step + an edited direction + `new_1` → accepted, 2 kept steps with edited direction, re-estimated; override of 501 chars → 422; 5th variant via `new_*` → 422; Go on cancelled/superseded/expired/executed is a no-op; `$assertAffordable` throwing leaves status `proposed` and steps unchanged; `acceptedPlanForStep` finds only accepted plans.
- [ ] Step 2: FAIL. Step 3: implement. Step 4: PASS. Step 5: commit.

### Task 3: Plan capabilities `VariantBoards` + `AddSizes` — steps and estimates (R1, R2)

**Files:**
- Create: `app/Services/Studio/AgentCanvas/Capabilities/KvPlanCapability.php` (interface extends `KvCanvasCapability`), `.../VariantBoards.php`, `.../AddSizes.php`, `app/Support/Studio/KvResizeSizeResolver.php`, `app/Support/Studio/KvVariantImageModel.php`
- Modify: `KvCanvasCapabilityRegistry::CAPABILITIES` (append both)
- Test: `tests/Feature/Studio/AgentCanvas/KvPlanCapabilitiesTest.php`, `tests/Unit/Studio/AgentCanvas/KvResizeSizeResolverTest.php`

**Interfaces — Produces:**
- `KvPlanCapability::proposeSteps(array $params, KvCanvasState $state): array{goal: string, steps: list<array>, options: array}` (throws 404 `board_not_found`, 422 `invalid_params` / `nothing_to_propose`); `executeSteps(KvAgentPlan $plan, list<array> $steps, KvAgentRun $run, KvCanvasState $state): array{applied: list, skipped: list}` (Tasks 7–8). `execute()` throws `plan_required`; `cost()` = `plan`; `cardKind()` = `plan_card`.
- Variant step: `{id: "step_<ulid>", capability: "variant_boards", params: {board_id, direction, suggestions[]}, estimate}`; `options = {copy_layers, extra_directions, source_board: {board_id, name}}`. Goal: `"<n> variants of <label>"`.
- Size step: `{id, capability: "add_sizes", params: {board_id, board_name, size: <preset id>|{width,height}, label, width, height, method: layers|ai, blocked_reason: ?string}, estimate}` (board_name/label/width/height additive to R1 — the card's "preset, dimensions" row). Blocked reasons: `layer_only_size`, `custom_size_needs_layers`, `size_exists`, `unknown_size`. Blocked steps estimate 0.
- `KvResizeSizeResolver::resolve(string|array $size): ?array{platform_id, label, width, height, custom: bool, layer_only: bool}` — preset id; preset label case-insensitively (also each ` / ` part); `"WxH"`/`"W×H"`; `"a:b"` → first non-layer-only preset with that exact ratio; `{width,height}` equal to a non-layer-only preset's dims → that preset, else custom (bounds `CustomResizeSize::MIN/MAX_DIMENSION`).
- `KvVariantImageModel::for(StudioFile $file): array{model: string, provider: string, pricing: array}` — newest file generation whose `model` is an active registry image model, else the registry's first image model (contract deviation D2: the thread stores no `image_model`).
- Estimates (R2): variant `min = LLMHelper::estimateImageCredits(pricing)`, `max = ceil(min*1.6)`, 70 s; size `layers` = `CreditPrice::credits(KEY_RESIZE_OVERLAY_ONLY)` both, 5 s; `ai` = image estimate / ×1.6, 45 s.

- [ ] Step 1: tests — 3 variants of board A → 3 steps with the directions, source_board A, options copy_layers true; 5 variants / 4 suggestions / 4 extras / 501-char direction → 422 `invalid_params`; unknown board → 404 `board_not_found`; sizes ["Instagram Story", {1080,1080}, "mobile-banner", {500,300}] on an AI parent (board B) → story `ai`, 1080² → instagram-post `ai`, mobile-banner blocked `layer_only_size`, 500×300 blocked `custom_size_needs_layers`; a size B already has → `size_exists`; all blocked → 422 `nothing_to_propose`; >20 sizes → 422; estimates per R2 (plan estimate sums credits, seconds = max). Resolver unit cases incl. "1:1", "1080x1080", label part "Instagram Story", unknown.
- [ ] Step 2: FAIL. Step 3: implement. Step 4: PASS (and the AC-13 contract test still green). Step 5: commit.

### Task 4: Plan tool route + MCP twins (R1, TASK-13, TASK-23)

**Files:**
- Create: `app/Http/Controllers/Api/ModelContextProtocol/KvCanvasPlanToolController.php` (extends `KvCanvasStructureToolController`), `app/Services/Studio/AgentCanvas/KvCanvasPlanRunner.php`, `app/Mcp/Tools/ProposeKvVariantsTool.php`, `app/Mcp/Tools/ProposeKvSizesTool.php`
- Modify: `routes/api.php` (structure group: `POST kv/canvas/{fileId}/plans` → `proposePlan`), `app/Mcp/Servers/FrndosServer.php`, `app/Mcp/Tools/FrndosTool.php` (`public const FIXED_ARGS = []`, merged into the gateway's route params), `app/Console/Commands/McpVerifyMirror.php` (several tools may wrap one target only when each declares a distinct non-empty `FIXED_ARGS`)
- Test: `tests/Feature/Studio/AgentCanvas/KvPlanToolRouteTest.php`, `tests/Unit/Mcp/KvCanvasToolsTest.php`

**Interfaces — Produces:**
- `KvCanvasPlanRunner::propose(StudioFile $file, ToolContext $ctx, string $capability, array $params, ?string $threadId): array` (plan view). `thread_id` is kept only when it is the file's thread or one of `metadata.kv_threads`; else null.
- `KvCanvasPlanToolController::proposePlan(Request $request, string $fileId, KvCanvasPlanRunner $runner, ?string $capability = null)` — body `{capability, params, thread_id}`; the twin passes `capability` via `FIXED_ARGS`; the twins take `params` (object) + `file_id` + `workspace_id`, mirroring the route body.
- Response `{data: <plan view>}`; 422 `invalid_params` / `nothing_to_propose`, 404 `board_not_found`; 404 when either flag is off. Contract deviation D1: `mcp:verify-mirror` gains the `FIXED_ARGS` rule so two twins can share the one R1 route.

- [ ] Step 1: tests — POST variants → 200, plan row `proposed`, view shape (R3 keys); `thread_id` of a foreign thread is dropped; structure flag off → 404; MCP twins' `FIXED_ARGS` fill `capability`; `mcp:verify-mirror` exits 0 (`$this->artisan('mcp:verify-mirror')->assertSuccessful()`).
- [ ] Step 2: FAIL. Step 3: implement. Step 4: PASS. Step 5: commit.

### Task 5: Plan view route (R3, TASK-14)

**Files:**
- Create: `app/Http/Controllers/Api/Studio/KvAgentPlanController.php`
- Modify: `routes/api.php` (`GET studio/files/{fileId}/agent/plans/{planId}` under `feature.flag:kv-agentic-canvas,off` + `feature.flag:kv-agentic-canvas-structure,off`)
- Test: `tests/Feature/Studio/AgentCanvas/KvAgentPlanRouteTest.php`

**Interfaces:** `show(Request, string $fileId, string $planId, KvAgentPlanService $plans, CreditService $credits): JsonResponse` → `{message: 'OK', data: view}` with `balance = CreditService::effectiveAvailableCredits(user, workspace)`; 404 for another file's plan or with the structure flag off (re-checked via `KvAgentCanvasStructureFlag`).

- [ ] Steps: test (shape, expired-on-read, balance, foreign file 404, flag off 404) → FAIL → implement → PASS → commit.

### Task 6: Go / Cancel on the stream (R5, TASK-15)

**Files:**
- Create: `app/Support/Chat/KvPlanAction.php`
- Modify: `app/Support/KvChat/QuestionCardPayload.php` (`PURPOSES` + `'plan'`), `app/Support/Chat/CardAnswer.php` (`planActionRules()`), `app/Http/Requests/StreamChatRequest.php` (rules + `planAction(): ?KvPlanAction`), `app/Http/Controllers/Api/Chat/ThreadController.php` (pass it), `app/Services/ChatService.php::streamKvGenerator` (`?KvPlanAction $planAction = null`), `app/Services/Studio/AgentCanvas/KvAgentCanvasTurn.php` (`forTurn(..., ?KvAgentPlan $plan = null)`)
- Create: `app/Services/Studio/AgentCanvas/KvPlanTurn.php` — `resolve(UserThread $thread, StudioFile $file, User $user, Workspace $workspace, CardAnswer $answer, ?KvPlanAction $action): array{plan: ?KvAgentPlan, error: ?array{code, message}}`
- Test: `tests/Feature/Studio/AgentCanvas/KvPlanGoTurnTest.php`

**Interfaces:**
- `plan_action` rules: `array:plan_id,accepted_steps,step_overrides,options`; `plan_id` string ≤26; `accepted_steps` array ≤24 of string ≤64; `step_overrides` array ≤8, `step_overrides.*` `array:direction`, `.direction` string ≤500; `options` `array:copy_layers`, `options.copy_layers` boolean. `required` when `card_answer.purpose == plan` and option `go`.
- `KvPlanTurn::resolve`: card must be a `kv_plan_card` on the thread naming `plan_action.plan_id` (or, on Cancel without `plan_action`, the card's own plan) → else error `invalid_plan_action`; `go` → `transition(..., assertAffordable: KvFixedPriceChargeService::assertAffordable)`; `KvInsufficientCreditsException` → error `insufficient_credits`.
- On error: `emitStreamError(message, ['code' => <code>])` and the turn ends before ai-service is called.
- `agent_canvas.plan = {plan_id, status, accepted_steps, capability}` only on a plan turn; `agent_canvas.tools` (structure flag on) = free tools + `propose_kv_variants`, `propose_kv_sizes`; when `plan.status == accepted` it is free tools + `run_kv_plan_step` (no propose tools). Flag off → no `tools`, no `plan`.

- [ ] Step 1: tests (stream harness of `KvAgentCanvasStreamTest`) — Go → plan accepted, payload `agent_canvas.plan.status == accepted`, tools contain `run_kv_plan_step`; Cancel → cancelled, no `run_kv_plan_step`; Go on expired → payload status `expired`, no run tool; card_id not on thread → SSE error `invalid_plan_action`, ai not called; unaffordable → SSE error `insufficient_credits`, plan still `proposed` with original steps, ai not called; non-plan structure turn → tools have the two propose names; flag off → payload has no `tools`/`plan` (existing tests).
- [ ] Step 2: FAIL. Step 3: implement. Step 4: PASS + `CardAnswerTest`, `KvAgentCanvasTurnTest`, `KvAgentCanvasStreamTest` green. Step 5: commit.

### Task 7: `kv_plan_card` + `tool_progress` relay (R4, R9)

**Files:**
- Modify: `app/Services/ChatService.php::streamKvGenerator` (cases `kv_plan_card`, `CustomEvent`, `tool_progress`; extract `relayToolProgress(array $parsed): void` shared with the chat path), `app/Http/Controllers/Api/Studio/KvGeneratorFileController.php` (hydrate)
- Test: `tests/Feature/Studio/AgentCanvas/KvPlanCardStreamTest.php`

**Interfaces:**
- NDJSON `{event: "kv_plan_card", plan_id, card_id}` → SSE `{type: "kv_plan_card", plan_id, card_id}`; persisted on the assistant row as `message.kv_plan_card = {plan_id, card_id}` (stamped on the row if it exists, else when it is created, else an empty-content assistant row is created at `done`). Plan must belong to the thread's file, card_id ≤26 chars, else dropped with a warning.
- NDJSON `CustomEvent` or `tool_progress` with `tool_call_id` + `kind` → SSE `{type: "tool_progress", tool_call_id, event: kind, data}` minus `CUSTOM_EVENT_ENVELOPE_KEYS`, 16 KiB cap — same as the chat path.
- Hydrate: chat history item gains `kv_plan_card: {plan_id, card_id}`; such a row is kept even with empty text.

- [ ] Steps: tests (relay + persist + hydrate; progress relay strips `run_id`/`kind`, keeps `item_id`, `item_kind`, `state`, `board_id`, `agent_run_id`) → FAIL → implement → PASS → commit.

### Task 8: Shared generate payload builder (R7 prep)

**Files:**
- Create: `app/Services/Studio/KvGeneratePayloadBuilder.php`
- Modify: `app/Http/Controllers/Api/ModelContextProtocol/KvToolController.php` (use it)
- Test: existing `KvToolController` generate tests stay green; `tests/Unit/Studio/KvGeneratePayloadBuilderTest.php` for `readyPayload`.

**Interfaces — Produces:**
- `build(StudioFile $file, User $user, Workspace $workspace, string $prompt, ?array $baseGeneration, string $aspectRatio, string $imageModel, string $imageModelProvider): array` — exactly today's payload (`mode: image`, `canvas_mode: craft`, `chat_history: []`, brand context, logo stamp from the base).
- `static readyPayload(array $events): array{ready: ?array, failure: ?string}` — the `generation_ready` / `generation_failed` scan.

- [ ] Steps: unit test for `readyPayload` → FAIL → extract → run `tests/Feature/**/KvTool*` + new test → PASS → commit (`refactor`-flavoured message still `feat(api): … Round B — share the KV generate payload builder`).

### Task 9: Execution route, idempotency, size execution (R6, TASK-16, TASK-19)

**Files:**
- Modify: `KvCanvasPlanRunner` (`runSteps`), `KvCanvasPlanToolController::runPlanSteps(Request, KvCanvasPlanRunner)`, `routes/api.php` (`POST kv/canvas/plans/steps/run`), `AddSizes::executeSteps`, `KvAgentRunRecorder` (`patchOps`, job op `state`), `FrndosServer`
- Create: `app/Mcp/Tools/RunKvPlanStepTool.php`
- Test: `tests/Feature/Studio/AgentCanvas/KvPlanStepsRunTest.php`

**Interfaces:**
- `runSteps(ToolContext $ctx, list<string> $stepIds, ?string $runId): array{run_id, applied: list<{plan_step_id, kind, board_id, size_id?, state}>, skipped: list<{plan_step_id, reason, detail?}>}`. One plan per call (steps of another plan → skipped `plan_not_accepted`). Internal calls need an `accepted` plan; an MCP user call (`ctx->via == user`) on a `proposed` thread-less plan accepts exactly the named steps first (FR-15 "the client's own user approves"), after `assertAffordable`. Under the file write lock: `ensureRun`, set `run.plan_id` / `plan.run_id`; steps already ledgered in `plan.run_id`'s run → their prior result, no write.
- `KvAgentRunRecorder::patchOps(KvAgentRun $run, string $planStepId, string $type, array $patch): void` — atomic jsonb rewrite of the matching op(s).
- Job op shape: `jobOp(...) + {plan_step_id, state: queued|generating|done|failed, size_id?, generation_id?, image_url?, credits?}`.
- Sizes: `createBatch(file, tip generation, platformIds, [], user id)` per board; ledger `sink: job, op: resize, job_id: <export id>, size_id, board_id, plan_step_id, state` (state from the export row). Existing row not recently created → skipped `size_exists`; `KvInsufficientCreditsException` → skipped `insufficient_credits`; `InvalidArgumentException` → skipped `invalid_size`; run cap (S5 resize 20) → `run_op_cap_reached`.

- [ ] Step 1: tests — accepted size plan: 2 steps → 2 export rows, ledger job ops, response applied `state: done` (layered) / `queued` (AI); repeat call → same applied, no new rows; repeat with a NEW run id → prior result from the plan's run; unaccepted plan → skipped `plan_not_accepted`; blocked/unticked step → `plan_not_accepted`; 25 ids → 422; MCP user call on a proposed plan accepts and runs; `mcp:verify-mirror` OK.
- [ ] Step 2: FAIL. Step 3: implement. Step 4: PASS. Step 5: commit.

### Task 10: Variant execution — placeholders + dispatch (R6, TASK-17)

**Files:**
- Modify: `VariantBoards::executeSteps`
- Create: `app/Jobs/Studio/RenderKvVariantJob.php` (dispatch only here; `handle` lands in Task 11)
- Test: `tests/Feature/Studio/AgentCanvas/KvVariantExecutionTest.php`

**Interfaces:**
- Centres: `KvBoardPlacement::nextFreeCenters(visible centres, n)`. Placeholder id: `(string) Str::ulid()`. Name: `KvBoardLabel::deriveVariantName(direction, next version number + i)`. One collab batch of `add_board` ops (`agent_run_id` stamped).
- Ledger per step: `boardOp('add_board', ph, name, null, {x, y, name, version_ids: [ph], source_board_id, direction}, 'variant_boards') + {placeholder: true, plan_step_id}` and `jobOp('render', ph, ph, name, 'variant_boards') + {plan_step_id, state: queued}`.
- `RenderKvVariantJob::__construct(string $runId, string $planStepId)`; `$queue = 'default'`, `$timeout = 300`, `$tries = 1`. Dispatched per step after the batch lands.
- Collab refusal/outage → every step skipped (`collab_unavailable` / `board_changed`), nothing dispatched. Render cap (S5, 4) → `run_op_cap_reached`.

- [ ] Step 1: tests (`Queue::fake()`) — 2 accepted of 3 steps → exactly 2 placeholders in one batch beside the visible boards, named from the directions, 2 jobs pushed with the step ids, applied `kind: board, state: queued`; collab down → no job, skipped; repeat → no new placeholder.
- [ ] Step 2: FAIL. Step 3: implement. Step 4: PASS. Step 5: commit.

### Task 11: Render land step + failure (R7, TASK-18)

**Files:**
- Modify: `RenderKvVariantJob` (`handle`, `failed`)
- Create: `app/Services/Studio/AgentCanvas/KvAgentJobSettler.php`
- Test: `tests/Feature/Studio/AgentCanvas/RenderKvVariantJobTest.php`

**Interfaces:**
- Job: lock `kv-variant:{step}` (skip when held); op state must be `queued` → `generating`; payload = `KvGeneratePayloadBuilder::build(file, user, workspace, direction, {id: source tip, image_url: source_image_url ?: image_url}, source aspect, model)`; POST `/ai/kv-generator/complete` (timeout 240, no retry); ready → `ready + {mode: craft, parent_generation_id: source tip, metadata + {agent_run_id, plan_step_id, source_board_id, direction}}` → `persistCompletion`.
- Land under `KvCanvasWriteLock`: run `undone` or placeholder hidden/absent in the live doc → op `state: done, generation_id, placed: false`, stop. Else ONE batch: `rekeyBoardTipOp(ph, gen)` + `add_layer` per `KvVariantOverlays::overlaysForVariant(source layers, source chain, gen)` when `options.copy_layers`; ledger: patch the add_board op (`board_id`/`target` → gen, `after.version_ids` → `[ph, gen]`, `placeholder: false`, `generation_id`), append the add_layer ops, patch the render op `state: done, generation_id, image_url`.
- Failure (HTTP error, no ready, persist error, `failed()`): `hideBoardOp(ph)` (best effort), op `state: failed`, skipped `{target: ph, reason: render_failed, plan_step_id}`.
- `KvAgentJobSettler::afterItem(KvAgentRun $run): void` — recompute `summary.credits`; when `summary.turn_done` and no open item → `completed` + `markExecuted(plan)`.
- `KvAgentJobSettler::credits(KvAgentRun $run): int` — `CostHistory.system_credit` summed over `kv_gen_<generation_id>` and `kv_resize_overlay_<size_id>` / `kv_resize_<size_id>_%` / `kv_resize_vision_<size_id>_%`.

- [ ] Step 1: tests (`Http::fake` ai-service + `FakeKvCollab`) — success: generation persisted with parent = source tip and the metadata, one batch `rekey_board_tip` + copied layers, ledger patched, board keyed by gen with chain `[ph, gen]`; copy_layers false → rekey only; ai 500 → placeholder hidden, state failed, skipped `render_failed`, no generation; run undone before land → generation exists, no collab write; placeholder hidden by the user → not placed; second handle for the same step → no second call.
- [ ] Step 2: FAIL. Step 3: implement. Step 4: PASS. Step 5: commit.

### Task 12: Run lifecycle + run view items (R8, TASK-21)

**Files:**
- Modify: `KvAgentRunRecorder::settle/fail/settleIfIdle`, `KvAgentRunView::of`, `ChatService` (`done` → settle; failure branches → fail with plan reopen)
- Test: `tests/Feature/Studio/AgentCanvas/KvAgentRunItemsTest.php`

**Interfaces:**
- `settle($runId)`: open items → stays `running`, `summary.turn_done = true`, file lock released; else `completed` + `markExecuted`. `fail($runId)`: plan with nothing landed → `reopen` (FR-24), else executed.
- Run view gains `items: [{plan_step_id, kind: board|size, board_id, size_id, name, state, generation_id, image_url, credits}]` (variant: ledger state; size: `kv_resize_exports.status` → queued(pending)/generating/done/failed) and `summary: {credits}`; both absent for a run with no job ops (P0 view unchanged).

- [ ] Steps: tests (settle with a queued render keeps running + lock free + a second run can write; last render lands → completed, plan executed, `summary.credits`; size item state from the export row; P0 run view has no `items`) → FAIL → implement → PASS → commit.

### Task 13: Structural undo for jobs (R11, TASK-20)

**Files:**
- Modify: `KvAgentRunReverter` (job sink pass; allow undo of a `running` run whose `summary.turn_done`), `VariantBoards::revert`, `AddSizes::revert`
- Test: `tests/Feature/Studio/AgentCanvas/UndoKvJobOpsTest.php`

**Interfaces:**
- Render, landed: the patched add_board op hides the generation board unless edited (`changed_after_run`). Render open: add_board op still keyed by the placeholder → hidden; run → `undone`, so the land step does not place.
- Resize open → `KvResizeExportService::cancel`; done → `forceDelete` (the REST destroy path) unless edited since (`overlays !== null` or more than one version) → `changed_after_run`.
- Undo result gains `credits_spent` (int) when the run has job ops; absent otherwise.

- [ ] Steps: tests (AC-9 untouched variant hidden, moved one kept; AC-10 undo while queued hides placeholder and a later land does not place; resize done deleted / open cancelled; `credits_spent`; second undo `already_undone`) → FAIL → implement → PASS → commit.

### Task 14: Sweeper (FR-24, TASK-22)

**Files:**
- Create: `app/Console/Commands/SweepKvAgentRuns.php` (`kv-agent:sweep-runs`)
- Modify: `routes/console.php` (every five minutes), `KvAgentRunRecorder::settleIfIdle` (app run idle 900 s with open items → `KvAgentJobSettler::failOpenItems`: hide placeholders, items `failed`, then failed + plan reopen when nothing landed)
- Test: `tests/Feature/Studio/AgentCanvas/KvAgentRunSweepTest.php`

- [ ] Steps: test (stale run with a queued render → placeholder hidden, item failed, run failed, plan back to `proposed`; fresh run untouched) → FAIL → implement → PASS → commit.

### Task 15: Close-out (TASK-23, track, review)

- [ ] Full suite: AgentCanvas Feature + Unit + `tests/Unit/Mcp` + touched KvTool tests; record counts vs 408/3.
- [ ] `php artisan mcp:verify-mirror` (worktree, no config cache) → OK.
- [ ] Track: tick TASK-11..23, session log (commits, counts, deviations). Commit.
- [ ] superpowers:requesting-code-review on the Round B diff; fix Critical/Important; re-run suite.
- [ ] Shared notes file `api-round-b-notes.md` for ai-service + web.

## Contract deviations (expected)

- D1 — `mcp:verify-mirror` allows several twins on one route only via distinct `FIXED_ARGS` (R1 "two twins on the one route").
- D2 — variant image model = newest file generation's registry image model, else registry default (no thread-level `image_model` is stored).
- D3 — size step params add `board_name`, `label`, `width`, `height`; blocked reason `unknown_size` added.
- D4 — `credits_spent` only on runs with job ops (P0 undo result unchanged).
