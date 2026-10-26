# KV agent plans render with the picked image model — design

- **Date:** 2026-10-23
- **Author:** daffa (brainstormed with Claude)
- **Slug:** `kv-agent-plan-image-model`
- **Amends:** KV agentic canvas P1 Round B (contract R2/R7, deviation **D2**) and P1.1 (`concept_boards`)
- **Services:** api, ai-service, web (tests + analytics only)
- **Branches:** `feature/daffa/vc-kv-agent-plan-image-model` in api + web (from `develop`) and ai-service (from `development`)

## 00. Amendment 2 (2026-10-24, Daffa: "opsi 2") — supersedes §0, restores D-1…D-4

**Craft follows the composer picker.** The server-side Craft lock in `ChatService` (`if ($canvasMode === 'craft') $imageModel = 'gpt-image-2'`, added 2026-05-07 with no web counterpart, so the Craft picker was silently ignored) is removed. Craft polish, Craft cold-start and agent concept/variant plans all render with the picked model. The round-1 picker design (§3–§7 below) is back.

- **Region/bbox edit stays locked to gpt-image-2**: only OpenAI images/edits accepts a mask. The web picker stays locked in edit mode.
- **Every active image model is allowed in Craft.** Gemini and Seedream have edit paths in ai-service (`edit_image.py`), but Craft's ratio conform is written for gpt-image. Daffa accepted that risk; it gets a manual check on staging.
- **Builder's call — no pick means gpt-image-2:**
  - A Craft turn whose model is absent or inactive renders `gpt-image-2`. Otherwise removing the lock would drop them on the inactive `gpt-image-1` default.
  - A concept/variant plan with no usable pick (MCP, empty picker, inactive pick) also resolves to `gpt-image-2`, before the file-history/registry rule. That rule is what put staging on Gemini.
- **web:** the Craft estimate stops pinning `CRAFT_LOCKED_MODEL` and follows the picker.
- **PRs:** ai-service #389 and web #1109 are reopened, and api #794 is extended.
- Staging's Google quota is exhausted, so a Craft pick of Gemini will 429 there until ops fixes it.

## 0. Amendment (2026-10-24, PR review round 1) — SUPERSEDED by §00

PR review found that **every KV Craft render is locked to `gpt-image-2`**: `ChatService` ("Craft mode is locked to gpt-image-2") and the web estimate (`CRAFT_LOCKED_MODEL`). D-4's premise ("a regular Craft render already uses the picker's model") was wrong. Daffa decided that **concept/variant plans follow the Craft lock**, not the picker:

- `KvVariantImageModel::CRAFT_MODEL = 'gpt-image-2'`. `ConceptBoards` / `VariantBoards` price with it (falling back to the old rule only when it is inactive) and store the resolved model in `options.image_model`. `KvVariantRenderer` renders `options.image_model`, or `CRAFT_MODEL` when none is stored.
- Removed: `StreamChatRequest::pickedImageModel()`, `agent_canvas.image_model`, the propose-body field, the ai-service pass-through, the Go re-price, and the web analytics prop. The ai-service and web PRs are no longer needed.
- External MCP proposals get gpt-image-2 too. `add_sizes` is unchanged.

Sections 3–7 below describe the superseded picker design and are kept for history.

## 1. Why

Seen on staging on 2026-10-23. File `01m5m174t310ah85fh90nkfkf1` held only an uploaded V1 (`kv_generations.model = user_upload`). The user picked **GPT Image 2** in the KV chat composer and asked for "3 ide KV berbeda POV". The P1.1 concept plan card appeared priced at **30–48 credits**, which is Gemini pricing. Go ran, and all 3 renders failed with Google `429 RESOURCE_EXHAUSTED` (`kv_agent_runs.skipped[].detail`, run `01M5M1AX1RZZPJ4Y5PQA1WH6ZQ`).

Cause: `KvVariantImageModel::for($file)` never sees the picker. It takes the newest generation's model if that model is active, and otherwise `reset(LLMHelper::getImageModels())`. On staging, the first active image model is `gemini-3.1-flash-image-preview` because a DB `sort_order` override puts it there. In code order (`LLMHelper::MODELS`), `gpt-image-2` comes first. `user_upload` is not an active image model, so an upload-only file always lands on Gemini. This shortcut was recorded as deviation D2 ("the thread stores no `image_model`").

The picker's value is already sent. `useKvStream.ts` puts `image_model: selectedImageModel || undefined` at the top level of **every** KV stream request (the proposal turn and the Go turn), and `StreamChatRequest` validates it. The plan path just never reads it.

The Google quota itself is a separate ops issue and is out of scope.

## 2. Goal

A `concept_boards` or `variant_boards` plan created from the KV chat renders with the image model the person picked in the composer. The credit estimate on the card, the affordability check on Go, and the actual render all use **the same model**.

**Success:** on an upload-only file with GPT Image 2 picked, a concept plan's card is priced for gpt-image-2, Go passes the credit check at gpt-image-2 prices, and every render's payload to ai-service names `gpt-image-2`.

### Non-goals

- `add_sizes` AI-resize steps. Their estimate keeps calling `KvVariantImageModel::credits($file)` with no picked model, and their render goes through the resize pipeline, which picks its own model. Making resize honour the picker is a separate change.
- Showing the model name on the plan card. This would make the "picker changed after the card appeared" case visible, but it is UI scope and is a possible follow-up.
- Letting external MCP clients pass a model on `propose_kv_*` / the plan route. Their behaviour does not change (§4.4).
- The Google 429 quota.

### Anti-goals (a failure even if it "works")

- The card shows one price and Go charges or gates on another for the same model.
- A request that never named a model (MCP, or a web client whose picker was still empty) silently starts rendering on `gpt-image-1` because of `StreamChatRequest`'s default. Absent must keep today's fallback.
- A plan proposed before this ships fails or changes model when its Go arrives after the deploy.

## 3. Decisions (made by Daffa, 2026-10-23)

| # | Question | Decision |
|---|---|---|
| D-1 | Which field carries the model | **The existing top-level `image_model`** on the stream request. No new `plan_action.options.image_model`, and the web send code does not change. |
| D-2 | The picker changes after the card appears, then Go | **Go's current picker wins.** Go re-prices the accepted steps with that model, the credit check uses the new `credits_max`, and the render follows it. The card's on-screen estimate can be out of date in this one case. That is accepted. |
| D-3 | How the proposal (card estimate) learns the model | **ai-service forwards it.** api adds the turn's picked model to the `agent_canvas` block; ai-service carries it on `KvToolContext` and sends it in the `propose_kv_*` callback body; api validates and stores it. |
| D-4 | Variant plans, where the web's picker auto-fills with gpt-image-2 (or the last pick in localStorage) as soon as the model list loads, so it is almost always sent | **The picker always wins, for variants too.** This matches a regular Craft render, which already uses the picker's model. A file made entirely in Seedream gets gpt-image-2 variants unless the person switches the picker. On web, the file-history rule now applies only when the picker is empty. |

## 4. The change

### 4.1 One resolution rule (api, `KvVariantImageModel`)

`KvVariantImageModel::for(StudioFile $file, ?string $picked = null)` and `credits(StudioFile $file, ?string $picked = null)`:

1. If `$picked` is the `value` of an **active** image model (`LLMHelper::getImageModels()`), use it.
2. Otherwise, do what happens today: the newest of the file's last 20 generations whose model is active, else `reset(active)`, else the hard `gpt-image-1` default.

An unknown or inactive `$picked` is **ignored** (it falls through to step 2). It is never an error. Existing callers that pass no `$picked` (`AddSizes`) behave exactly as before.

### 4.2 "Picked" means the client actually sent it (api, `StreamChatRequest`)

`prepareForValidation()` fills a missing `image_model` with `gpt-image-1`, so after that, "sent nothing" and "picked gpt-image-1" look the same. Add an accessor (named by the builder, e.g. `pickedImageModel(): ?string`). It returns the client's raw `image_model` **as sent**, before the default, and only when that value is an active image model. Otherwise it returns `null`. Nothing else that reads `image_model` changes; the KV render payload keeps its default.

### 4.3 Proposal turn: api → ai-service → api

1. **api, `KvAgentCanvasTurn::forTurn`:** when the turn has a picked model (4.2) **and** the structure flag is on (`KvAgentCanvasStructureFlag`, the same `if ($structure)` branch that adds `tools`), set `agent_canvas.image_model = <value>`. Otherwise leave the key **out**, so P0 and intent-only canvas payloads stay byte-identical. *(Builder-check call: gated like `tools`.)*
2. **ai-service:** `AgentCanvas.image_model: str | None = None`. `make_kv_structure_tools(..., image_model=canvas.image_model)` sets `KvToolContext.image_model`. `_propose` adds `"image_model": ctx.image_model` to the callback body **only when set**. `_propose` is shared, so `propose_kv_sizes` sends it too. The api ignores it for sizes (step 4). Other canvas calls (`ctx.body()` for writes and `run_kv_plan_step`) do not carry it.
3. **api, `KvCanvasPlanToolController@proposePlan`:** read `image_model` from the body **only when `$ctx->via === 'internal'`**, the same gate `thread_id` uses. Pass it to `KvCanvasPlanRunner::propose`, which hands it to the capability. The builder decides how: a new argument or a field on the state.
4. **api, `ConceptBoards` / `VariantBoards::proposeSteps`** (only these two; `AddSizes` explicitly ignores the picked model, and its pricing does not change): resolve the model once with `KvVariantImageModel::for($file, $picked)`. Price each step with that model. Store the **resolved** model, whether picked or fallback, as `options.image_model`. From then on the plan names its model, and file history that changes before Go cannot move it.

### 4.4 Old clients, MCP, plans in flight

- **External MCP** (`via !== 'internal'`): any `image_model` in the body is ignored. The capability resolves the fallback as it does today and stores it in `options.image_model`. The behaviour is the same as now, just recorded.
- **Web turn with no `image_model`** (empty picker): there is no `agent_canvas.image_model`, so ai-service sends none, and the fallback applies.
- **Plan proposed before deploy, Go after:** `options.image_model` is missing. Go and the renderer fall back to `KvVariantImageModel::for($file, null)`, which is today's behaviour.

### 4.5 Go turn (api, `KvPlanTurn` → `KvAgentPlanService::transition`)

1. `ThreadController` passes the request's picked model (4.2) into `KvPlanTurn::resolve`, which forwards it to `transition()`.
2. In `transition()`, for a `go` on a concept or variant plan, the **effective model** is the Go turn's picked model if there is one, else `options.image_model`, else `for($file, null)`.
3. **Re-price every accepted direction step** (always, not only when the model changed — it is deterministic and cheap), including steps cloned from `new_<n>` rows, with `KvVariantImageModel::credits($file, $effective) + ['seconds' => <capability SECONDS>]`. Only then run `estimateSteps()` and the `$assertAffordable` check. The order matters: a refusal still leaves the plan untouched.
4. Save `options.image_model = $effective` along with the rest of the accepted state.
5. A cancel ignores the model.

`add_sizes` plans keep their stored estimates; D-2 does not apply to them (non-goal).

### 4.6 Render (api, `KvVariantRenderer`)

`$model = KvVariantImageModel::for($file, $plan?->options['image_model'] ?? null)`. Because `for()` re-checks that the model is active, a model deactivated between Go and render degrades to the fallback instead of failing.

### 4.7 web

- **No change to the wire format.** Tests pin the behaviour this design relies on:
  - The Go request (`card_answer.purpose = 'plan'` + `plan_action`) carries top-level `image_model` = the composer's current `selectedImageModel`.
  - The proposal turn (an ordinary Craft chat turn) carries it too.
  - With an empty picker, `image_model` is absent, not `""`.
- **PostHog:** add `image_model: string | null` to `kv_agent.plan_confirmed`. The value is the picker at Go time for `concept_boards` and `variant_boards`. It is `null` for `add_sizes` (that render ignores the picker, and counting it would skew the per-model comparison) and `null` when the picker is empty. Add it in `web/src/lib/analytics/kv-agent-events.ts`, and update the taxonomy entry if the module keeps one. Then render success and failure per model can be compared. No new event.

## 5. Contract changes (record in the P1 / P1.1 contract docs)

- **D2 is retired.** The variant/concept image model is the person's picked model when the turn sent one, else today's file-history/registry fallback. It is stored per plan in `kv_agent_plans.options.image_model`.
- `agent_canvas.image_model?: string`: new, optional, set only when the client picked one.
- Internal plan-proposal body `image_model?: string`: new, optional, honoured only for `via = internal`.
- No migration (`options` is already `jsonb`). `KvAgentPlanView` does not need to expose the model.

## 6. Tests

**api** (Feature tests; see the scratch-Postgres lesson for running them):
1. **The staging case:** reproduce staging's registry order first. Seed an image-model `sort_order` override that puts `gemini-3.1-flash-image-preview` first, clear the overrides cache, and assert that `reset(getImageModels())` is Gemini, so the test proves something; in code order, the fallback would already be `gpt-image-2`. Then take a file whose only generation is `model = user_upload` and propose a concept plan internally with `image_model = gpt-image-2`. Assert `options.image_model = gpt-image-2`, the step estimates equal `KvVariantImageModel::credits($file, 'gpt-image-2')`, and, after Go plus the render job with `Http::fake`, the payload posted to `/ai/kv-generator/complete` names `gpt-image-2`, not registry[0].
2. The same for a variant plan, plus one with a picked non-default model (e.g. `seedream-5-lite`) on a file whose history is `gpt-image-2`, to show that the picker beats file history (D-4).
3. A proposal with no `image_model` stores the fallback model (current tests stay green).
4. A proposal with an inactive or unknown `image_model` falls back with no error. Via `user` (MCP), the body's `image_model` is ignored.
5. Go with a different picked model re-prices the steps (both proposed and `new_<n>`), the affordability check sees the new `credits_max`, and `options.image_model` updates. Go with no picked model keeps the plan's model.
6. A plan with no `options.image_model` (from before deploy) still goes and renders with the fallback.
7. `StreamChatRequest` picked-model accessor: absent → null, active → value, inactive → null.
8. `KvAgentCanvasTurn`: `agent_canvas.image_model` is present only when a model was picked.

**ai-service:** `AgentCanvas` parses with and without `image_model`; `_propose` sends `image_model` only when the context has one; `ctx.body()` for other calls is unchanged.

**web** (`bun test`): the Go payload and the proposal-turn payload carry top-level `image_model` from the picker, and leave it out when the picker is empty; `trackKvAgentPlanConfirmed` receives the picker for concept/variant Go and `null` for sizes.

**api, sizes:** a `propose_kv_sizes` body that carries `image_model` prices exactly as it would without it.

## 7. Rollout and verification

1. Build on the three feature branches, with tests green per repo (web: `bun test`; api: unit + targeted Feature paths; ai-service: pytest against its known-red baseline).
2. **Ship order:** api first, because it accepts and ignores both new optional fields; then ai-service; then web (analytics only). Any order is safe, since every new field is optional and ignored when absent.
3. **Manual staging check:** on an upload-only KV file, pick GPT Image 2 and ask for 3 new ideas. The card estimate matches gpt-image-2 pricing, and after Go, `kv_agent_plans.options.image_model = gpt-image-2` and the new `kv_generations.model = gpt-image-2`. Check with read-only `ssh frnd-stg`. Getting the branches onto staging (the `staging` branch) needs Daffa's go-ahead.

## 8. Left to the builder

- Names and signatures: the picked-model accessor on `StreamChatRequest`, and how the picked model travels runner → capability (an argument or `KvCanvasState`).
- Where the step re-price lives (`KvAgentPlanService` or a capability hook), as long as it happens before the affordability check and covers `new_<n>` clones.
- Whether `VariantBoards`/`ConceptBoards` share a helper for "resolve the model + price the steps".
