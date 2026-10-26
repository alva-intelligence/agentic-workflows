# KV agent plan image model — api Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `concept_boards` / `variant_boards` plans price, gate, and render with the image model picked in the KV composer, and fall back to today's file-history rule when no model was picked.

**Architecture:** `KvVariantImageModel` gains an optional `$picked` argument that wins when it is an active image model. The picked model enters through two doors. (1) On the proposal turn, `StreamChatRequest` → `agent_canvas.image_model` → ai-service → the internal propose body → the capability, which stores the *resolved* model in `kv_agent_plans.options.image_model`. (2) On the Go turn, `StreamChatRequest` → `KvPlanTurn` → `transition()`, which re-prices the accepted direction steps and stores the effective model. The renderer reads `options.image_model`.

**Tech Stack:** Laravel 13, PHP 8.5, Pest, PostgreSQL.

**Spec:** `docs/superpowers/specs/2026-10-23-kv-agent-plan-image-model-design.md`

**Branch:** `feature/daffa/vc-kv-agent-plan-image-model` in `api/`, from latest `develop`.

## Global Constraints

- "Picked" = the client's raw `image_model`, as sent, before `StreamChatRequest::prepareForValidation()` defaults it to `gpt-image-1`, and only when it is the `value` of a model in `LLMHelper::getImageModels()` (active only). Anything else → `null`.
- An unknown or inactive picked model is **ignored** (fallback). It is never a 422.
- `agent_canvas.image_model` is added only inside the existing `if ($structure)` branch of `KvAgentCanvasTurn::forTurn`, and only when a model was picked. Otherwise the key is absent.
- The internal propose body's `image_model` is honoured only when `$ctx->via === 'internal'` (the same gate as `thread_id`).
- Only `ConceptBoards` and `VariantBoards` use the picked model. `AddSizes` ignores it, and its pricing does not change.
- `options.image_model` is always written by concept/variant `proposeSteps` and by Go: the resolved model, whether picked or fallback.
- A plan with no `options.image_model` (proposed before deploy) must still Go and render, using `KvVariantImageModel::for($file, null)`.
- No migration (`kv_agent_plans.options` is already `jsonb`).
- Run Feature tests with the scratch-Postgres setup from memory `lesson_api_feature_tests_need_scratch_postgres` (pass test *paths*, delete a stale `bootstrap/cache/config.php`). Never point tests at the dev DB.

## Review Focus

1. **The test registry differs from staging's:** in code order, `gpt-image-2` is already the first active image model, so a test that never reorders the registry proves nothing. Task 1 and Task 5 seed a `ModelSetting` override that puts Gemini first and assert that the fallback is Gemini *before* asserting the fix.
2. **`new_<n>` rows on Go** copy a template step's stale estimate. Task 4 asserts that an added row is re-priced too.
3. **The picker changes between proposal and Go,** and the new model is pricier than the balance allows. Task 4 asserts that `insufficient_credits` uses the new `credits_max` and the plan stays `proposed`, unchanged.
4. **A model deactivated between Go and render:** Task 5 asserts that the render falls back instead of failing.
5. **An external MCP caller sends `image_model`:** Task 3 asserts it is ignored.

---

### Task 1: `KvVariantImageModel` honours a picked model

**Files:**
- Modify: `app/Support/Studio/KvVariantImageModel.php`
- Test (create): `tests/Feature/Studio/AgentCanvas/KvVariantImageModelTest.php`

**Interfaces:**
- Produces: `KvVariantImageModel::for(StudioFile $file, ?string $picked = null): array{model: string, provider: string, pricing: array}` and `KvVariantImageModel::credits(StudioFile $file, ?string $picked = null): array{credits_min: int, credits_max: int}`. A picked active model wins; otherwise the existing rule applies unchanged.
- Produces (test helper, put it in `tests/Traits/BuildsKvCanvas.php` so Tasks 3–5 reuse it): `geminiFirstRegistry(): void`. It creates `ModelSetting(['model_value' => 'gemini-3.1-flash-image-preview', 'model_type' => 'image', 'is_enabled' => true, 'sort_order' => 0])`, then `LLMHelper::bustOverridesCache()`.

- [ ] **Step 1: Write the failing tests** (`uses(BuildsKvCanvas::class)`, `setUpKvCanvas()` in `beforeEach`, and turn the file's generations into a single `user_upload` row: `KvGeneration::where('studio_file_id', $file->id)->update(['model' => 'user_upload'])`):
  - `it('falls back to the first active model on an upload-only file')`: after `geminiFirstRegistry()`, `for($file)['model']` is `'gemini-3.1-flash-image-preview'`. This is the guard that makes the next test meaningful.
  - `it('uses the picked model over the fallback')`: after `geminiFirstRegistry()`, `for($file, 'gpt-image-2')` is `['model' => 'gpt-image-2', 'provider' => 'openai', ...]` and `credits($file, 'gpt-image-2')` equals `['credits_min' => LLMHelper::estimateImageCredits(LLMHelper::getModelPricing('gpt-image-2')), 'credits_max' => (int) ceil(min × 1.6)]`. Also assert that this differs from `credits($file)`.
  - `it('ignores an inactive or unknown picked model')` with a dataset `['gpt-image-1', 'nope-model', '']`: the result equals `for($file)`.
  - `it('uses the picked model over the file history')`: set the newest generation's model to `'gpt-image-2'`, and `for($file, 'seedream-5-lite')['model']` is `'seedream-5-lite'`.

- [ ] **Step 2: Run, expect FAIL** (`for()` takes one argument / the picked model is ignored)

Run: `php artisan test tests/Feature/Studio/AgentCanvas/KvVariantImageModelTest.php`

- [ ] **Step 3: Implement.** Check `$active[$picked]` before the generation loop. Update the class docblock: D2 is retired; the picked model comes first.

- [ ] **Step 4: Run, expect PASS.** Also run `KvConceptBoardsTest.php` and `KvPlanCapabilitiesTest.php` (unchanged callers must stay green).

- [ ] **Step 5: Commit** — `feat(api): KvVariantImageModel prefers the picked image model`

---

### Task 2: The picked model reaches `agent_canvas.image_model`

**Files:**
- Modify: `app/Http/Requests/StreamChatRequest.php` (capture the raw value in `prepareForValidation()` before the default; add the accessor)
- Modify: `app/Http/Controllers/Api/Chat/ThreadController.php` (the KV branch near the `streamKvGenerator(...)` call, ~L1067)
- Modify: `app/Services/ChatService.php` (`streamKvGenerator`: new trailing param, forwarded to `forTurn`)
- Modify: `app/Services/Studio/AgentCanvas/KvAgentCanvasTurn.php` (`forTurn`: new trailing param)
- Test: `tests/Feature/Studio/AgentCanvas/KvAgentCanvasStreamTest.php` (add cases; it already captures the ai-service payload)

**Interfaces:**
- Produces: `StreamChatRequest::pickedImageModel(): ?string`
- Produces: `ChatService::streamKvGenerator(..., ?KvAgentPlan $kvPlan = null, ?string $pickedImageModel = null)`
- Produces: `KvAgentCanvasTurn::forTurn(..., ?KvAgentPlan $plan = null, ?string $pickedImageModel = null): ?array`. It sets `$canvas['image_model']` only inside `if ($structure)` and only when non-null.

- [ ] **Step 1: Write the failing tests** (structure flag on, a Craft chat turn on the KV thread, the captured ai-service body):
  - `it('forwards the picked image model in agent_canvas')`: post with `'image_model' => 'gpt-image-2'` → `$seen['agent_canvas']['image_model'] === 'gpt-image-2'`, and the top-level `$seen['image_model']` is still `'gpt-image-2'`.
  - `it('leaves agent_canvas.image_model out when none was sent')`: no `image_model` in the post → `array_key_exists('image_model', $seen['agent_canvas'])` is false, and the top-level `image_model` is still the `gpt-image-1` default (unchanged behaviour).
  - `it('leaves it out for an inactive model')`: post `'image_model' => 'gpt-image-1'` (it exists but `is_active => false`) → the key is absent.
  - `it('leaves it out when the structure flag is off')`: `config(['studio.kv_agent_structure_flag' => false])` + `'image_model' => 'gpt-image-2'` → the key is absent.

- [ ] **Step 2: Run, expect FAIL** — `php artisan test tests/Feature/Studio/AgentCanvas/KvAgentCanvasStreamTest.php`

- [ ] **Step 3: Implement.** Store the raw client value in a private property in `prepareForValidation()` before `$data['image_model'] = 'gpt-image-1'`. The accessor returns it only if it is a key of the active `getImageModels()` values. Pass `$streamRequest->pickedImageModel()` from `ThreadController` as a named argument.

- [ ] **Step 4: Run, expect PASS** — the same file plus `KvAgentCanvasTurnTest.php` and `KvAgentCanvasStructureFlagTest.php`

- [ ] **Step 5: Commit** — `feat(api): send the picked image model to ai-service in agent_canvas`

---

### Task 3: Proposals store and price the picked model

**Files:**
- Modify: `app/Http/Controllers/Api/ModelContextProtocol/KvCanvasPlanToolController.php` (`proposePlan`)
- Modify: `app/Services/Studio/AgentCanvas/KvCanvasPlanRunner.php` (`propose`)
- Modify: `app/Services/Studio/AgentCanvas/Capabilities/KvPlanCapability.php` (`proposeSteps` signature)
- Modify: `app/Services/Studio/AgentCanvas/Capabilities/ConceptBoards.php`, `VariantBoards.php` (resolve + price + `options.image_model`), `AddSizes.php` (accept the parameter and ignore it)
- Test: `tests/Feature/Studio/AgentCanvas/KvPlanToolRouteTest.php` (route cases), `KvConceptBoardsTest.php` + `KvPlanCapabilitiesTest.php` (update the exact `options` assertions to include `image_model`)

**Interfaces:**
- Consumes: `KvVariantImageModel::for/credits(StudioFile, ?string)` (Task 1), `geminiFirstRegistry()` (Task 1)
- Produces: `KvPlanCapability::proposeSteps(array $params, KvCanvasState $state, ?string $imageModel = null): array`. The concept/variant result has `options.image_model: string` (resolved).
- Produces: `KvCanvasPlanRunner::propose(StudioFile $file, ToolContext $ctx, string $capability, array $params, ?string $threadId, ?string $imageModel = null): array`

- [ ] **Step 1: Write the failing tests**
  - Route, `it('stores and prices the picked model on an internal concept proposal')`, the staging case: `geminiFirstRegistry()` + an upload-only file + an internal propose with `capability: concept_boards, image_model: gpt-image-2` → the stored plan has `options.image_model === 'gpt-image-2'` and every `steps[*].estimate === KvVariantImageModel::credits($file, 'gpt-image-2') + ['seconds' => 70]`.
  - Route, same for `variant_boards`.
  - Route, `it('stores the fallback model when none is sent')`: `options.image_model === KvVariantImageModel::for($file)['model']`.
  - Route, `it('ignores image_model from an external MCP caller')`: via `user` with `image_model: gpt-image-2` and `geminiFirstRegistry()` → `options.image_model` is Gemini.
  - Route, `it('ignores an inactive picked model')`: `image_model: gpt-image-1` → fallback.
  - Route, `it('does not change add_sizes pricing when image_model is sent')`: the sizes plan's estimate with `image_model: seedream-5-lite` equals the estimate without it.
  - Update the existing `toBe([...options...])` assertions in `KvConceptBoardsTest` / `KvPlanCapabilitiesTest` to include `'image_model' => KvVariantImageModel::for($this->file)['model']`.

- [ ] **Step 2: Run, expect FAIL** — the three test paths

- [ ] **Step 3: Implement.** Resolve the model once per proposal in the two direction capabilities (a shared helper on `KvRenderedBoardsCapability` is fine). Price each step with it and add `image_model` to `options`. `AddSizes` gets the new parameter and does nothing with it.

- [ ] **Step 4: Run, expect PASS** — the three paths plus `KvPlanCardStreamTest.php` and `KvCapabilityRegistryContractTest.php`

- [ ] **Step 5: Commit** — `feat(api): plan proposals store and price the picked image model`

---

### Task 4: Go re-prices with the Go turn's picked model

**Files:**
- Modify: `app/Services/Studio/AgentCanvas/KvPlanTurn.php` (`resolve` gains the picked model; forwards it to `transition`)
- Modify: `app/Services/Studio/AgentCanvas/KvAgentPlanService.php` (`transition`)
- Modify: `app/Http/Controllers/Api/Chat/ThreadController.php` (~L1061: pass `$streamRequest->pickedImageModel()`)
- Test: `tests/Feature/Studio/AgentCanvas/KvAgentPlanServiceTest.php`, `KvPlanGoTurnTest.php`

**Interfaces:**
- Consumes: Task 1, Task 2's `pickedImageModel()`
- Produces: `KvPlanTurn::resolve(UserThread, User, Workspace, CardAnswer, ?KvPlanAction, ?string $pickedImageModel = null): array`
- Produces: `KvAgentPlanService::transition(KvAgentPlan, string $action, ?array $acceptedSteps, ?array $stepOverrides, ?array $options = null, ?Closure $assertAffordable = null, ?string $imageModel = null): KvAgentPlan`

Rule (spec §4.5), for `go` on a concept/variant plan: the effective model is `KvVariantImageModel::for($plan->file, $imageModel ?? $plan->options['image_model'] ?? null)['model']`. Re-price every kept direction step, `new_<n>` clones included, as `KvVariantImageModel::credits($file, $effective) + ['seconds' => (int) ($step['estimate']['seconds'] ?? 0)]`, **before** `estimateSteps()` / `$assertAffordable`. Save `options.image_model = $effective`. `add_sizes` and `cancel` are untouched.

- [ ] **Step 1: Write the failing tests**
  - Service, `it('re-prices accepted and added steps with the Go model')`: propose a variant plan with `image_model: gpt-image-2`, then Go with `imageModel: 'seedream-5-lite'`, a `new_1` override, and one step unticked → every accepted step (including the clone) is priced at `credits($file, 'seedream-5-lite')`, `estimate` is their sum, and `options.image_model === 'seedream-5-lite'`.
  - Service, `it('keeps the plan model when Go names none')`: `options.image_model` and the estimates are unchanged.
  - Service, `it('gates Go on the re-priced credits_max')`: a closure that records `$creditsMax` is called with the new-model sum; a throwing closure leaves the plan `proposed` with its original `steps`/`estimate`/`options`.
  - Service, `it('goes on a plan with no options.image_model')`: a plan created without the key → accepted, `options.image_model === KvVariantImageModel::for($file)['model']`.
  - Stream, `KvPlanGoTurnTest`, `it('applies the picked image model on Go')`: `planTurn('go', goAction())` posted with `'image_model' => 'seedream-5-lite'` (extend `planTurn` with an optional extra-body argument) → `$this->plan->fresh()->options['image_model'] === 'seedream-5-lite'`.

- [ ] **Step 2: Run, expect FAIL** — the two paths

- [ ] **Step 3: Implement** per the rule above.

- [ ] **Step 4: Run, expect PASS** — the two paths plus `KvRoundBReviewFixesTest.php` and `KvPr791ReviewFixesTest.php`

- [ ] **Step 5: Commit** — `feat(api): Go re-prices a plan with the picked image model`

---

### Task 5: The renderer uses the plan's model

**Files:**
- Modify: `app/Services/Studio/AgentCanvas/KvVariantRenderer.php` (~L126)
- Test: `tests/Feature/Studio/AgentCanvas/RenderKvConceptJobTest.php`, `RenderKvVariantJobTest.php`

**Interfaces:**
- Consumes: `KvVariantImageModel::for(StudioFile, ?string)` and `options.image_model` from Tasks 3–4.

- [ ] **Step 1: Write the failing tests**
  - Concept, `it('renders an upload-only file with the picked model, not the first registry model')`, the staging regression: `geminiFirstRegistry()`, the file's generations set to `user_upload`, then `goConcepts` building with `proposeSteps(..., $state, 'gpt-image-2')` (extend `goConcepts` with an optional model argument) → `renderConcept($step)` → `$this->aiCalls[0]['image_model'] === 'gpt-image-2'` and `$this->aiCalls[0]['image_model_provider'] === 'openai'`.
  - Variant, the same assertion with a picked `seedream-5-lite` on a board whose generation is `gpt-image-2`.
  - Concept, `it('falls back when the plan model was deactivated before render')`: Go with `gpt-image-2`, then `ModelSetting(['model_value' => 'gpt-image-2', 'is_enabled' => false])` + `bustOverridesCache()` → the payload's `image_model === KvVariantImageModel::for($file)['model']`, and the step does not fail.
  - Concept, `it('renders a plan with no options.image_model using the fallback')`.

- [ ] **Step 2: Run, expect FAIL** — the two paths

- [ ] **Step 3: Implement:** `KvVariantImageModel::for($file, $plan?->options['image_model'] ?? null)`.

- [ ] **Step 4: Run, expect PASS.** Then run the whole `tests/Feature/Studio/AgentCanvas` directory, plus `vendor/bin/pint --test` on the changed files.

- [ ] **Step 5: Commit** — `fix(api): agent plan renders use the plan's image model`

---

### Task 6: Docs

**Files:**
- Modify: `docs/prd/kv-agentic-canvas-p1-1.md`: add a short "Image model (amendment 2026-10-23)" section summarising spec §5 and linking the spec.
- Modify: `docs/tracks/kv-agentic-canvas-p1.track.md`: mark D2 retired, with a pointer to the spec. Also `docs/tracks/kv-agentic-canvas-p1-1.track.md`: add a session-log entry for this work.

- [ ] **Step 1: Write the doc edits**
- [ ] **Step 2: Commit** — `docs(api): retire contract deviation D2 — plans use the picked image model`
