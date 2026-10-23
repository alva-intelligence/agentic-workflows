---
title: KV Agentic Canvas P1.1 — Concept Boards from Chat
slug: kv-agentic-canvas-p1-1
parent_feature: kv-agentic-canvas-p1
author: daffa
created: 2026-10-23
status: approved
services: [api, web, ai-service]
---

# KV Agentic Canvas P1.1 — Concept Boards from Chat

## Overview

P1 gave the KV chat agent the ability to create N variant boards by re-rendering a source board. It cannot create boards from scratch. When a user on an empty Craft canvas says "generate 3 different ideas themed Indonesian independence day", the agent falls through to `suggest_mode_switch`, which renders one cold-start image. The user wanted three distinct concepts; they got one.

P1.1 adds a `concept_boards` capability: the agent proposes up to 4 genuinely different creative directions in one call, shows them on the existing P1 plan card with an aspect-ratio picker, and on Go places N placeholders that render in parallel as Craft cold-start KVs (no source board, no `base_generation`, no `parent_generation_id`). Each direction is a distinct concept angle on the user's brief, not a small variation.

The intent resolver gains a new action that separates "N new ideas from scratch" from "N variants of V2" (R12 stays: "duplicate + change" = variant). On a non-empty canvas where no board is named, a clarifying card asks "from scratch, or variants of <active board>?"

Scope: Craft only. Concept-mode (sketch) support is explicitly out of scope and is the next follow-up.

Users: KV Studio users (internal scope, behind `show-kv-generator`), Craft mode.

| Sub-feature | Scope | Status |
|---|---|---|
| kv-agentic-canvas-p0 | Inventory, layer tools, run ledger, undo, run card | Merged 2026-10-19 |
| kv-agentic-canvas-intent | Intent resolver + validator, card answers, intent events | Merged 2026-10-20 |
| kv-agentic-canvas-p1 | Board structure, N variants, add sizes, plan card, capability registry | Merged 2026-10-22 |
| **kv-agentic-canvas-p1-1** (this PRD) | Concept boards from scratch via plan card | Draft |
| kv-agentic-canvas-p2 | Pixel edits on existing boards, upscale, motion, opening MCP | Not started |

Source: P1 PRD `frnd/docs/prd/kv-agentic-canvas-p1.md`, frozen contracts `docs/superpowers/plans/2026-10-22-kv-agentic-canvas-p1-structure-contracts.md` (S4, S11-S15, R1-R12).

## Brainstorming Outcome

P1.1 adds the `concept_boards` capability to the existing P1 framework. The agent proposes N distinct ideas from scratch (one `propose_kv_concepts` call), shown on the P1 plan card with an aspect-ratio picker and no "Copy layers" toggle. Go places placeholders and renders them in parallel as Craft cold-start KVs.

### Decisions

- **Aspect ratio for new ideas (no source board)** -> Picker on the plan card; default = the ratio the user named ("IG story" -> 9:16), else 4:5.
- **Non-empty canvas + "generate 3 new ideas" with no board named** -> Clarifying card: "From scratch, or variants of <active board>?"
- **Wireframe** -> No new wireframe. Reuse the P1 plan card look (`web/src/wireframes/kv-agent-structure-cards/`). Deviation from the wireframe gate recorded here.
- **Branch strategy** -> P1 already merged (2026-10-22). Branch `feature/daffa/vc-kv-agentic-canvas-p1-1` from latest `develop`/`development`.

## User Stories

- As a KV user on an empty canvas, I want to type "generate 3 different ideas themed Indonesian independence day" and get 3 new boards with distinct creative concepts, so I can explore multiple directions from one instruction instead of running the render flow 3 times.
- As a KV user, before any credits are spent, I want to see each idea's direction, suggestion chips I can click to switch angles, an aspect-ratio picker, and the estimated cost, so I control exactly what gets rendered and in what format.
- As a KV user on a canvas that already has boards, I want the agent to ask whether I mean new ideas from scratch or variants of my active board, so it does the right thing without guessing.
- As a KV user, I want each concept board to appear as a placeholder and fill in as it renders, just like variants do, so I know what is happening.
- As a KV user, I want Undo on the run card to hide the concept boards the AI added (unless I edited them) and cancel renders that have not started, the same way variant undo works.
- As a collaborator with the file open, I want the new concept boards to appear live.

## Requirements

### Functional Requirements

**Capability registry**

- **FR-1:** A new `concept_boards` capability is added to the P1 capability registry (`KvCanvasCapabilityRegistry::CAPABILITIES` in api, `KV_CANVAS_CAPABILITIES` in ai-service). It is a plan capability (`cost: plan`). The variant, size, free-structure and all other capabilities are unchanged.

**Proposal tool**

- **FR-2:** `propose_kv_concepts {file_id?, directions[{direction, suggestions[{label, direction}] <= 3}] <= 4, extra_directions[{label, direction}] <= 3}` is a new ai-service tool that proposes N distinct creative directions from scratch (no `board_id` parameter). Each direction must be a genuinely different concept angle on the user's brief, not a small variation. A count above 4 is clamped to 4 and the agent says so in the response text.
- **FR-3:** The agent writes all N directions plus suggestion chips and extra directions in ONE call. Suggestions are grounded in the user's brief and brand, distinct from the direction itself, and fenced like other user-editable text (P1 FR-11).
- **FR-4:** `propose_kv_concepts` stores a `kv_agent_plans` row through the existing `KvAgentPlanService::propose` and ends the turn (`stop_after_tool_call` + post-hook). `plan_pending` is claimed before the await (the `propose_deck_plan` pattern). Every other write in that turn is refused (P1 FR-11).

**Plan card**

- **FR-5:** The plan card gains a `concept_boards` branch. It shows:
  - Title "N new ideas".
  - One row per direction: editable direction text field, suggestion chips below, checkbox.
  - "Add idea" button while the plan has fewer than 4 directions; adds a row prefilled from the next unused `extra_directions` entry. At 4 it reads "Max 4 ideas".
  - An **aspect-ratio picker**, one for all ideas. Default = the ratio the user named in their message (e.g. "IG story" -> 9:16), else 4:5. The picker lists the same presets as the KV generate flow.
  - **No** "Copy layers" toggle (there is no source board).
  - Credit estimate (min-max range) vs balance, Go / Cancel.
  - Terminal states: accepted, cancelled, superseded, expired (identical to P1 variant plan card).
- **FR-6:** On Go, `accepted_steps`, `step_overrides` (edited directions, added rows), and the chosen `aspect_ratio` are sent as `plan_action` through the existing `card_answer` channel (surface `kv_canvas`, purpose `plan`). The `aspect_ratio` is sent in `plan_action.options.aspect_ratio`. The api validates: direction <= 500 chars, <= 4 steps total, `aspect_ratio` must be a valid ratio string.

**Plan service generalisation**

- **FR-7:** `KvAgentPlanService` is generalised so it is not variant-specific:
  - The plan row's `options` jsonb gains `aspect_ratio` for concept plans.
  - `proposeSteps` and `estimateSteps` route through the capability registry (`KvPlanCapability::proposeSteps`).
  - `MAX_VARIANTS` (4) is renamed or aliased to `MAX_PLAN_STEPS` (still 4) and applies to both variants and concepts.
  - The `new_` step template (`new_0`, `new_1` etc. for rows added on Go) works for concept steps with the same shape validation.

**Execution**

- **FR-8:** On Go for a concept plan, the api:
  1. Reserves the run and calls `assertAffordable(estimate.credits_max of accepted steps)`.
  2. Computes placement centres with `KvBoardPlacement::nextFreeCenters`: on an empty canvas the first board is at (0,0); on a non-empty canvas the row starts after the last visible board.
  3. Writes one `add_board` placeholder per accepted direction (board metadata: `status: "generating"`, stamped `agent_run_id`). Placeholders use the chosen `aspect_ratio` for their visual dimensions.
  4. Dispatches one render job per direction through the existing `RenderKvVariantJob` path, but with the **no-source branch** (FR-9).
- **FR-9:** `KvVariantRenderer` gains a no-source branch. When the step has no `source_board_id` (concept boards):
  - `base_generation` is `null` (the `KvGeneratePayloadBuilder::build` method already accepts `null`).
  - `parent_generation_id` is NOT set on the persisted generation.
  - `aspect_ratio` comes from the plan's `options.aspect_ratio` instead of the source board.
  - No layer copy runs (there is no source).
  - Brand knowledge is honoured as today (the file's `use_brand_knowledge` preference via `KvGeneratePayloadBuilder`).
  - Logo compositing follows the existing cold-start path: `brand_logo_stamp` is `null` when `baseGeneration` is `null` (line 62-64 of `KvGeneratePayloadBuilder`), so the logo is composited separately by ai-service as its COLD_START_GUIDANCE says.
  - The existing failure path (hide placeholder, report `render_failed`) is unchanged.
- **FR-10:** Each landed generation rekeys its placeholder via `rekey_board_tip` (P1 R7). A failed render hides the placeholder and is not billed. Each concept board gets `deriveVariantName(direction)` as its name.

**Billing and estimates**

- **FR-11:** Estimate per concept step: same as variant steps (R2). `credits_min = LLMHelper::estimateImageCredits(pricing of the file's craft image model)`, `credits_max = ceil(min * 1.6)`, `seconds = 70`. Each render is billed on `persistCompletion` (the only charge). A failed render costs nothing. `assertAffordable` gates on the estimate sum of accepted steps.

**Intent and resolver**

- **FR-12:** `CanvasIntent.Action` gains `concept_boards`. The resolver maps:
  - "generate 3 different ideas about X" / "buat 3 ide berbeda tentang X" -> `concept_boards` with `count` and brief.
  - "generate 3 variants of V2" / "buat 3 varian dari V2" -> `variant` (unchanged, R12).
  - "duplicate V2 and change the background" -> `variant` (unchanged, R12).
  - On an **empty canvas**, "generate N ideas ..." always resolves to `concept_boards`.
  - On a **non-empty canvas with no board named**, the validator shows a clarifying card: "From scratch, or variants of <active board>?" The answer routes to `concept_boards` or `variant_boards`.
  - On a **non-empty canvas with a board named**, it is `variant` (the named board is the source).
- **FR-13:** Golden cases for the new action in EN + ID (>= 3 cases each), scoring >= 90% on the default model. Cases cover: empty canvas, non-empty with no board named (clarifying card), explicit "from scratch", count > 4 (clamp), and the boundary with R12 variant ("copy V2 but change X" stays variant).

**MCP parity**

- **FR-14:** The new `propose_kv_concepts` tool route has an MCP twin via `FrndosTool::FIXED_ARGS` (the D1 precedent from `ProposeKvVariantsTool` and `ProposeKvSizesTool`). The twin fills `capability: "concept_boards"` on the shared plans route. `php artisan mcp:verify-mirror` passes.

**Progress, run card, undo**

- **FR-15:** Concept boards reuse the P1 run view items (`kind: "board"`, states `queued -> generating -> done / failed`), the `agent_item_progress` CustomEvent, and the `agentRunRefetchInterval` poll. No new event shapes.
- **FR-16:** Undo for concept boards is identical to variant undo (S9 / R11): an untouched concept board is hidden; an edited one is kept and reported as `changed_after_run`; a queued/running render is cancelled (placeholder hidden, late result not placed); credits already spent are not refunded.

**Flags**

- **FR-17:** Reuse the existing `kv-agentic-canvas-structure` flag (no new flag) plus the parent `kv-agentic-canvas`. With `kv-agentic-canvas-structure` off, `propose_kv_concepts` is not mounted and no concept plan card appears.

**P1 track file bookkeeping**

- **FR-18:** P1's per-repo track files (`api/docs/tracks/kv-agentic-canvas-p1.track.md` etc.) still say `status: in_progress`. The first P1.1 commit in each repo marks them `status: completed` (no direct develop commits, as the P1 notes say).

### Non-Functional Requirements

- **NFR-1 (flag, fail-closed):** `kv-agentic-canvas-structure` (existing, off by default). With it off, the `concept_boards` capability is not registered and is byte-identical to P1 behaviour.
- **NFR-2 (credits):** No credit moves before Go. `assertAffordable(estimate.credits_max of accepted steps)` before dispatch. Billing via `persistCompletion` per landed render. Idempotency key per `plan_step_id` (R6 pattern).
- **NFR-3 (consistency):** Board writes are atomic per collab batch. A render that lands after undo is not placed. (P1 NFR-3 unchanged.)
- **NFR-4 (latency):** Placeholders appear in open tabs <= 3 s after Go (same as P1 NFR-4). N renders run in parallel; p95 per render unchanged (~66 s).
- **NFR-5 (security):** Tool routes use `ResolveToolContext` and re-check file access (BOLA). Directions are user-editable prompt text fenced like layer text. (P1 NFR-5 unchanged.)
- **NFR-6 (MCP parity):** `mcp:verify-mirror` passes with the new twin.
- **NFR-7 (quality gate):** P0 eval stays 66/66, intent cases stay >= 90%. New concept-boards golden cases (EN + ID) score >= 90% on the default model.

## Service Breakdown

### API (`api/`)

P1 is merged (api#791, commit 9ff48111b). Code references are on latest `develop`.

- **ConceptBoards capability class** at `App\Services\Studio\AgentCanvas\Capabilities\ConceptBoards`, implementing `KvPlanCapability` (like `VariantBoards`). Registers in `KvCanvasCapabilityRegistry::CAPABILITIES`.
  - `proposeSteps`: no `board_id`; validates directions (<=4, <=3 suggestions, <=3 extra, direction <=500 chars); builds steps with `capability: "concept_boards"`.
  - `estimate`: delegates to `LLMHelper::estimateImageCredits` per step (same as `VariantBoards`).
  - `execute`: computes centres via `KvBoardPlacement::nextFreeCenters` (visible boards only), writes `add_board` placeholders, dispatches `RenderKvVariantJob` per step with `source_board_id: null`.
  - `revert`: identical to `VariantBoards::revert`.
- **KvAgentPlanService generalisation**: `options` gains `aspect_ratio`; plan transition validates `aspect_ratio` when capability is `concept_boards`.
- **KvVariantRenderer no-source branch** (line ~109-116 of `KvVariantRenderer.php`): when `source_board_id` is null, skip the source-board lookup, pass `baseGeneration: null` and `aspectRatio: plan.options.aspect_ratio` to `KvGeneratePayloadBuilder::build`, and skip `parent_generation_id` and layer copy on land.
- **KvAgentCanvasTurn**: add `'propose_kv_concepts'` to `PROPOSAL_TOOLS` (line 37).
- **MCP twin**: `ProposeKvConceptsTool` with `FIXED_ARGS = ['capability' => KvAgentPlan::CAPABILITY_CONCEPTS]` on the shared `KvCanvasPlanToolController` route.
- **KvAgentPlan** model: add `CAPABILITY_CONCEPTS = 'concept_boards'` constant.
- **P1 track file**: first commit marks `api/docs/tracks/kv-agentic-canvas-p1.track.md` as `status: completed`.

### Frontend (`web/`)

P1 is merged (web#1104, commit d15673878). Code references are on latest `develop`.

- **KvPlanCard**: add a `concept_boards` branch. Differences from `variant_boards`:
  - Title: "N new ideas" (not "N variants of <board>").
  - No source board display; no "Copy layers" toggle.
  - An aspect-ratio picker (dropdown/radio, same presets as the KV generate flow) stored in local state and sent as `plan_action.options.aspect_ratio` on Go.
  - Chip labels say "idea" / "ide" instead of "variant" / "varian".
  - "Add idea" instead of "Add variant".
- **Placeholder rendering**: on an empty canvas, placeholders use the plan's `aspect_ratio` for their visual dimensions, not a source board's aspect. The run view already carries `board_id`; the plan view carries `options.aspect_ratio`.
- **PostHog events**: extend `kv_agent.plan_shown`, `kv_agent.plan_confirmed` with `capability: "concept_boards"`. Add `kv_agent.concept_done` / `concept_failed` (mirroring `variant_done` / `variant_failed`).
- **P1 track file**: first commit marks `web/docs/tracks/kv-agentic-canvas-p1.track.md` as `status: completed`.

### AI Service (`ai-service/`)

P1 is merged (ai#385, commit e31243d7e). Code references are on latest `development`.

- **`propose_kv_concepts` tool** in `app/tools/kv_plan_tools.py`: mirrors `propose_kv_variants` but with no `board_id` parameter. Uses the R4 plan card frame (`kv_plan_card` event) and `stop_after_tool_call`. Add to `PLAN_PROPOSAL_TOOLS` frozenset.
- **Resolver action**: `CanvasIntent.Action` gains `"concept_boards"`. The resolver maps "generate N ideas / concepts / ide from scratch" to it. Clarifying-card rule: on a non-empty canvas with no board named, show a card asking "From scratch, or variants of <active board>?" The answer routes to `concept_boards` or `variant_boards`.
- **Go turn and `run_kv_plan_step`**: the existing execution path works for concept steps because the api's `ConceptBoards::execute` handles the no-source branch. The ai-service `run_kv_plan_step` tool calls the api route that already dispatches through the capability registry.
- **TOOL_NAME_ENUM / TOOL_ICONS**: add `propose_kv_concepts` with an appropriate icon (lightbulb or similar, matching the "new ideas" metaphor).
- **Eval**: >= 3 EN + >= 3 ID golden cases in `evals/golden/kv_canvas/` for `concept_boards`: empty canvas, non-empty with no board (clarifying card), count > 4 (clamp), boundary with R12 ("copy V2 but change background" stays variant).
- **P1 track file**: first commit marks `ai-service/docs/tracks/kv-agentic-canvas-p1.track.md` as `status: completed`.

### Collab (`collab/`)

No changes. The existing P1 board ops (`add_board`, `rekey_board_tip`, `hide_board`) are sufficient for concept boards. Collab is unaware of whether a board is a variant or a concept.

### Data Service (`data-service/`)

No changes.

## UI/UX

### Key Screens

All in the existing KV chat panel and canvas. New states beyond P1:

1. **Plan card: concept boards.**
   - Header "3 new ideas" (not "3 variants of V2").
   - One row per direction: editable text field, suggestion chips below, checkbox.
   - "Add idea" button (up to 4; at 4: "Max 4 ideas").
   - Aspect-ratio picker (dropdown or inline radio group): presets matching the KV generate flow (e.g. 4:5, 1:1, 9:16, 16:9). Default = ratio from the user's message, else 4:5.
   - No "Copy layers" toggle.
   - Estimate line ("~N credits, about 70 s"), balance, Go / Cancel.
   - Terminal states identical to P1 variant plan card.

2. **Clarifying card (non-empty canvas, no board named).**
   - "Do you want new ideas from scratch, or variants of <active board name>?"
   - Two options: "New ideas" / "Variants of <board>".
   - Choosing routes to `concept_boards` or `variant_boards` respectively, with the same directions.

3. **Canvas placeholders.** N ghost boards in a row from (0,0) on an empty canvas, or after the last visible board. Each shows "Generating..." and uses the chosen aspect ratio for its frame. Fills on render land; disappears with a failed note.

4. **Run card: concept rows.** Identical to P1 variant rows: placeholder -> rendering -> done / failed, thumbnail, focus, credits, Undo.

**Wireframe deviation:** No new wireframe is created for this feature. The user decided to reuse the P1 plan card wireframe (`web/src/wireframes/kv-agent-structure-cards/`) with the changes described above. This is an explicit deviation from the wireframe gate in the workflow rules.

## Data Model

### New Tables

None. `kv_agent_plans` and `kv_agent_runs` from P1 are reused as-is.

### Modified Tables

- `kv_agent_plans.options` (jsonb, no schema migration): gains `aspect_ratio: string` for concept plans. Variant plans continue to use `copy_layers` and `extra_directions`.
- `kv_generations.metadata` (jsonb, no column change): concept generations have `agent_run_id`, `plan_step_id`, `direction` but NO `source_board_id` and NO `parent_generation_id`.

## API Endpoints

| Method | Endpoint | Description | Service |
|--------|----------|-------------|---------|
| POST | `v1/mcp/tools/kv/canvas/{fileId}/plans` (existing) | `propose_kv_concepts` via `FIXED_ARGS {capability: "concept_boards"}` | api |
| POST | `v1/mcp/tools/kv/canvas/plans/steps/run` (existing) | `run_kv_plan_step` for concept steps (unchanged) | api |
| GET | `v1/studio/files/{file}/agent/plans/{plan}` (existing) | Plan view gains `options.aspect_ratio` for concept plans | api |
| POST | `/ai/kv-generator/stream` (existing) | Resolver gains `concept_boards` action and clarifying-card rule | ai-service |
| POST | `/ai/kv-generator/complete` (existing) | Cold-start render (no base) called by `RenderKvVariantJob` no-source branch | ai-service |

No new endpoints. All existing endpoints are extended, not replaced.

## Existing System Reconciliation

- **`KvVariantRenderer` requires a source board today.** Line 112-113 of `KvVariantRenderer.php` fails with "The source board or its file is gone" when `$source` is null. Line 147 hardcodes `$ready['parent_generation_id'] = $source->id`. The no-source branch (FR-9) must bypass both of these.
- **`KvGeneratePayloadBuilder::build` already accepts `null` baseGeneration.** Line 30: `?array $baseGeneration`. When null, `base_generation` is null in the payload and `brand_logo_stamp` is null (line 62-64). This is the existing cold-start path. No change needed in the builder.
- **`VariantBoards::proposeSteps` requires `board_id` via `boardOrFail`.** Line 97 of `VariantBoards.php`. The new `ConceptBoards` class does not call `boardOrFail` and has no `board_id` parameter.
- **`KvAgentPlanService` has variant-specific assumptions.** `MAX_VARIANTS` constant, `new_` row templates that assume `board_id` in step params. These need generalisation per FR-7.
- **`PROPOSAL_TOOLS` in `KvAgentCanvasTurn` is a fixed array** at line 37: `['propose_kv_variants', 'propose_kv_sizes']`. It must gain `'propose_kv_concepts'`.
- **`PLAN_PROPOSAL_TOOLS` in ai-service `kv_plan_tools.py`** is a frozenset at line 43: `{VARIANTS_TOOL, SIZES_TOOL}`. It must gain the concepts tool name.
- **MCP twins follow the D1 deviation pattern.** `ProposeKvVariantsTool` (line 10) uses `FIXED_ARGS = ['capability' => KvAgentPlan::CAPABILITY_VARIANTS]` to fill the capability on the shared plans route. The concepts twin does the same with `CAPABILITY_CONCEPTS`.
- **`KvPlanCard` in web branches on capability name.** The existing card handles `variant_boards` and `add_sizes`. The `concept_boards` branch must omit source-board display, omit "Copy layers", add the aspect-ratio picker, and use "idea" labels.
- **Placeholder rendering on empty canvas.** P1 R10 falls back to the source board's aspect for placeholder frames. Concept boards have no source, so the placeholder must read `options.aspect_ratio` from the plan view (R3).
- **P1 track files say in_progress.** The P1 notes (`.workflow-state.json` line 508) say "mark completed in the first P1.1 commit per repo". FR-18 captures this.
- **Concept-mode (sketch) scope boundary.** These locations gate Craft-only behaviour that concept-mode would need to relax:
  - `KvAgentCanvasTurn::forTurn` (line 53): `if ($canvasMode !== 'craft' || $mode !== 'chat')` return null.
  - `KvGeneratePayloadBuilder::build` (line 39): hardcodes `'canvas_mode' => 'craft'`.
  - Web: agent placeholders only render when `canvasMode === 'craft'`.
  - Concept mode's `handleExploreDirectionsConcurrent` (`kvFanout.ts`) is card-driven and sketch-only; it does not go through the plan card.

## Acceptance Criteria

- [ ] AC-1: Flag off -> `propose_kv_concepts` is not mounted, no concept plan card appears, and P1 behaviour is byte-identical. P0 eval 66/66 + intent cases unchanged.
- [ ] AC-2: On an empty Craft canvas, "generate 3 different ideas themed Indonesian independence day" shows a plan card with 3 directions, suggestion chips, an aspect-ratio picker defaulting to 4:5, no "Copy layers" toggle, and a credit estimate. No board and no credit is used before Go.
- [ ] AC-3: Edit direction 2, add a 4th idea via "Add idea", change the aspect to 9:16, Go -> exactly 4 placeholders appear in a row starting at (0,0) within 3 s; each fills with its render in the chosen aspect; direction 2 used the edited text.
- [ ] AC-4: One render fails -> its placeholder is removed, the run card shows it as failed in plain words, the other concepts land, and only landed renders are billed.
- [ ] AC-5: Pressing Go twice (or retrying the turn) creates no extra boards and charges nothing twice (idempotency key per plan_step_id).
- [ ] AC-6: A new instruction while a concept plan is pending supersedes it; Go on the old card does nothing and the card says so. A plan older than 15 min shows expired.
- [ ] AC-7: "Generate 6 ideas" -> the plan has 4 and the agent says the max is 4.
- [ ] AC-8: On a canvas with boards, "generate 3 new ideas" with no board named -> a clarifying card asks "From scratch, or variants of <active board>?" Choosing "New ideas" -> concept plan card. Choosing "Variants" -> variant plan card with the active board as source.
- [ ] AC-9: On a canvas with boards, "generate 3 new ideas from scratch" (explicit) -> concept plan card directly, no clarifying card.
- [ ] AC-10: On a canvas with boards, "generate 3 variants of V2" -> variant plan card (not concept). "Copy V2 and change the background to sunset" -> variant (R12 boundary unchanged).
- [ ] AC-11: Undo after AC-3: untouched concept boards are hidden, a concept board the user edited is kept and reported as `changed_after_run`, the undo dialog says credits are not refunded, and a second undo -> `already_undone`.
- [ ] AC-12: Undo while a render is still running -> its placeholder is hidden and the late result does not appear on the canvas.
- [ ] AC-13: `mcp:verify-mirror` passes with the new `propose_kv_concepts` twin.
- [ ] AC-14: New concept-boards golden cases (EN + ID) score >= 90% on the default model.
- [ ] AC-15: With the file open in a second tab, concept placeholders and landed boards appear live via collab.
- [ ] AC-16: "Generate 3 IG story ideas about Ramadan" -> the plan card defaults the aspect-ratio picker to 9:16 and renders in that ratio.

## Open Questions

- [x] Q-1: Aspect ratio for new ideas -> Picker on the plan card; default from user's words, else 4:5. (daffa, 2026-10-23)
- [x] Q-2: Non-empty canvas + no board named -> Clarifying card: "From scratch, or variants of <active board>?" (daffa, 2026-10-23)
- [x] Q-3: Wireframe -> No wireframe (reuse P1 plan card look; deviation recorded). (daffa, 2026-10-23)
- [x] Q-4: Branch strategy -> P1 merged; branch from latest develop/development. (daffa, 2026-10-23)
