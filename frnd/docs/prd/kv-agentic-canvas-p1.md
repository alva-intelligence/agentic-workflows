---
title: KV Agentic Canvas P1 — Board Structure, Variants and Sizes from Chat
slug: kv-agentic-canvas-p1
parent_feature: kv-agentic-canvas
author: daffa
created: 2026-10-21
status: approved # approved 2026-10-21 (daffa)
services: [api, web, ai-service, collab]
---

# KV Agentic Canvas P1 — Board Structure, Variants and Sizes from Chat

## Overview

P0 and the intent layer let the KV chat agent see the canvas and edit **layers**. It still cannot change the canvas **structure**. When a user asks "generate 3 variants of V2", the agent can only offer one mode-suggestion card. Accepting it renders one image, and in Craft that image replaces V2's tip in place instead of adding boards.

P1 lets the agent change structure from one chat instruction:

- **Free structure** runs directly: duplicate a board (no render), rename, arrange, hide/unhide.
- **Paid structure** goes through a plan card that the user confirms with Go:
  - generate N variant boards (N ≤ 4), each a re-render of a source board with its own direction;
  - add resize sizes to boards.

Every structural write goes through the server (api + collab), lands live in open tabs, is recorded on the P0 run ledger, and can be undone from the run card.

Users: KV Studio users (internal scope, behind `show-kv-generator`), Craft mode.

| Sub-feature | Scope | Status |
|---|---|---|
| kv-agentic-canvas-p0 | Inventory, layer tools, run ledger, undo, run card | Merged 2026-10-19 |
| kv-agentic-canvas-intent | Intent resolver + validator, card answers, intent events | Merged 2026-10-20 |
| **kv-agentic-canvas-p1** (this PRD) | Board structure, N variants, add sizes, plan card, capability registry | Approved 2026-10-21 |
| kv-agentic-canvas-p2 | Pixel edits on existing boards/tiles, upscale, motion, opening MCP | Not started |

Source design: `docs/superpowers/specs/2026-09-29-kv-agentic-canvas-design.md` §6 (Structure, Execute), §7.2, §8. That spec's "P2 — Structure" is this PRD.

## Brainstorming Outcome

P1 makes the KV chat (Craft, flag) change the canvas structure.

- **Free actions run directly:** duplicate, rename, arrange and hide board.
- **Paid actions go through a plan card:** generating N variants (max 4, each a re-render of the source board) and `add_kv_sizes`. The plan card ends the turn and runs only when the user clicks Go.
- **What the card shows:** the agent's proposed direction per variant (editable, can be unticked), a "Copy layers" toggle (default on), and a credit estimate.
- **What Go does:** creates placeholder boards through new collab ops (`add_board`, `hide_board`, `rekey_board_tip`). Parallel renders then fill each board, and progress streams as `tool_progress`.
- **Deck patterns reused:** `deck_agent_plans`, idempotent `plan_step_id`, placeholder-then-fill, `agentRunId` stamping for undo, `recordCredits`, `failIfStale`.
- **From the Studio run-engine spec:** the charge, refund and idempotency rules.
- **Run ledger:** `kv_agent_runs` gains board and job sinks.
- **Board placement and naming** move to the server, with parity fixtures generated from the TS.
- **Composability:** a capability registry. Tables stay per surface (`kv_agent_plans`), `agent_intent_events` stays generic, and cross-surface unification is deferred to `studio-agent-surface`.

### Decisions

- **Scope** → Free structure (duplicate / rename / arrange / hide board) + generate N variants + `add_kv_sizes`.
- **Variant source** → Re-render of the source board: Craft + `base_generation`, aspect taken from the source. Same pipeline as `handleCreateVariant` (`KvGeneratorLayout.tsx` L1840).
- **Variant directions** → The agent proposes one direction per variant. The user can edit or untick each one on the plan card before Go (`DeckPlanCard` pattern).
- **Layers on variants** → "Copy layers" toggle on the plan card, default on.
- **Max variants per run** → 4.
- **Mode** → Craft only. The P0 gate `KvAgentCanvasTurn::forTurn` (craft + chat) is unchanged.
- **Plan table** → Per surface: `kv_agent_plans`, shaped like `deck_agent_plans`, plus `kv_agent_runs.plan_id`. A generic `agent_plans` / `agent_runs` is deferred to `studio-agent-surface` together with the Deck migration.
- **Intent events table** → `agent_intent_events` stays generic (intent PRD FR-16).
  - Rule: execution/undo state is per surface (FK cascade to the subject).
  - Append-only event logs are generic with a `surface` column.
- **Composability** → A capability registry per service. Each entry has: tool schema + MCP twin, `cost: free|plan`, estimate, execute, revert, card kind. Plus:
  - generic plan step `{capability, params, estimate}`;
  - collab op handler registry;
  - server-side board placement with TS-generated parity fixtures;
  - intent `Action` / `IntentSurface` extended;
  - generic progress event relayed as `tool_progress`;
  - web card registry;
  - op caps per class (layer / board / job).

## User Stories

- As a KV user, I want to type "generate 3 variants of V2 with different background colours" and get 3 new boards next to V2, so I can explore without clicking through the render flow 3 times.
- As a KV user, before any credits are spent, I want to see each variant's direction, untick or edit some, choose whether layers are copied, and see the estimated cost, so I am never charged for something I didn't approve.
- As a KV user, I want to see each board appear as a placeholder at once and fill in as it renders, so I know what is happening and where.
- As a KV user, I want "duplicate V2 twice and name them Ramadan and Lebaran" to just happen, because it costs nothing.
- As a KV user, I want "add Instagram Story and 1:1 sizes to V2 and V3" to show what it will cost and run on Go.
- As a KV user, I want one Undo on the run card to remove the boards the AI added (unless I already edited them) and cancel sizes that have not started.
- As a collaborator with the file open, I want the new boards to appear live.
- As the team, I want a new capability (upscale, motion, pixel edit in P2) to be one registry entry, not changes across every layer of the stack.

## Requirements

### Functional Requirements

**Capability registry (composability)**

- **FR-1:** Each structural capability is one registry entry per service. P1 entries:
  - `duplicate_board`, `rename_board`, `arrange_boards`, `hide_boards` (free);
  - `variant_boards`, `add_sizes` (plan).

  Each entry declares the tool name + schema (with its MCP twin), `cost` (`free` | `plan`), `estimate(params)`, `execute(params, run)`, `revert(op)`, and the web card kind. Adding a capability must not change the validator, the plan service, the ledger, the reverter loop or the card host.
- **FR-2:** `cost` decides execution: `free` runs as soon as the call is valid; `plan` can only be proposed. Nothing in the prompt decides whether credits move.
- **FR-3:** Run caps per op class: layer ops (existing `MAX_OPS = 200`), board ops (≤ 20 per run), job ops (≤ 4 variants + ≤ 20 sizes per run). Exceeding a cap gives a per-target skip `run_op_cap_reached`, never a 500.

**Collab board ops**

- **FR-4:** `POST /internal/kv-files/{id}/ops` accepts these new op kinds:
  - `add_board {board_id, x, y, name, version_ids, agent_run_id}`
  - `rename_board {board_id, name, expected?}`
  - `move_board {board_id, x, y, expected?}`
  - `hide_board {board_id}` / `unhide_board {board_id}`, which use the existing `removed` Y.Array
  - `rekey_board_tip {from, to}`

  Every kind is a handler in an op registry next to the layer kinds. The same atomic `doc.transact(…, SERVER_WRITE_ORIGIN)` runs and the same CAS rule applies. Pre-images are returned for the ledger.
- **FR-5:** After a board write, collab materialises boards to api (the existing canvas-state snapshot path), so REST readers see agent boards even when no browser has the file open.

**Server-side board placement**

- **FR-6:** The api owns placement and naming for agent-created boards. It uses PHP ports of:
  - `adjacentFreeCenter` / `nextFreeCenters` and `deriveVariantName` (`boardLayout.ts`);
  - `overlaysForVariant` (`overlayMutations.ts`);
  - `editOutcome` (`editOutcome.ts`).

  JSON fixtures generated from the TS functions are checked by a PHP test, as `KvTileOverlayProjector` does in P0. A port that diverges fails CI.
- **FR-7:** N new boards are placed side by side next to their source board (the `nextFreeCenters` behaviour) and do not overlap existing boards.

**Free structure tools**

- **FR-8:** `duplicate_kv_board {file_id?, board_id, count ≤ 4, names?, copy_layers=true, targets}` uses `duplicateGeneration` (no AI call). Each copy then gets `add_board`, and `add_layer` for its copied layers (fresh ULIDs). The run card lists every new board.
- **FR-9:** `rename_kv_board`, `arrange_kv_boards` (grid or row, deterministic layout from FR-6), and `hide_kv_boards` / `unhide_kv_boards` write through collab. Hiding never deletes a generation.
- **FR-10:** Unstated targets follow P0 FR-18 and intent FR-3: when the user did not say which board, the validator asks with the target card. No write happens in that turn.

**Plan card (paid structure)**

- **FR-11:** `propose_kv_variants {file_id?, board_id, variants[{direction, suggestions[{label, direction}] ≤ 3}], extra_directions[{label, direction}] ≤ 3, copy_layers}` and `propose_kv_sizes {file_id?, board_ids, sizes[preset | {width, height}]}` store a `kv_agent_plans` row and end the turn. They use `stop_after_tool_call` + post-hook, and `plan_pending` is claimed before the await (the `propose_deck_plan` pattern). Every other write in that turn is refused. The agent writes the suggestions in the same call (no second model call); they are grounded in the source board and the brand, distinct from the variant's own direction, and fenced like other user-editable text.
- **FR-12:** The plan stores each step as `{id, capability, params, estimate}`. Go lands exactly the stored params: same source board, same directions, same `copy_layers`, same sizes. A newer plan on the same thread supersedes a pending one.
- **FR-13:** The plan card shows:
  - one row per step: variant direction, editable before Go, and a checkbox;
  - under each direction, the step's suggestion chips (short label, full direction on hover). A chip prefills the direction field; clicking the active chip restores the agent's original direction. Typing over a prefilled direction is allowed;
  - "Add variant" while the plan has fewer than 4 variants: adds a row prefilled with the next unused `extra_directions` entry, whose chips are the remaining extras. At 4 it reads "Max 4 variants";
  - the "Copy layers" toggle for variant plans (default on);
  - per size: preset, dimensions and whether it is layer projection or AI resize;
  - the total estimate (credits + time) for the ticked rows, and the balance;
  - Go / Cancel.

  Edited directions, added rows and the copy-layers value are sent on Go as `accepted_steps` + `step_overrides` (added rows as new steps). The api validates the overrides against the stored step shape (direction ≤ 500 chars, ≤ 4 steps in total) and re-estimates before dispatch.
- **FR-14:** Go and Cancel are a new user turn carrying `{plan_id, plan_action, accepted_steps, step_overrides}`, using the `card_answer` channel (surface `kv_canvas`, purpose `plan`). The api transitions the plan before it builds the ai-service payload (`DeckAgentPlanService::transition` pattern).
- **FR-15:** The execution tool `run_kv_plan_step {plan_step_id}` is only mounted on a Go turn and only accepts steps of an accepted plan. A repeated `plan_step_id` returns the prior result without writing again. The in-app agent never gets a tool that spends credits without an accepted plan. For MCP, the client's own user approves `run_kv_plan_step`.
- **FR-16:** Plans expire after 15 min in `proposed`. Go on an expired, superseded, cancelled or executed plan writes nothing, and the card shows why.

**Variant execution**

- **FR-17:** On Go for a variant plan, the api:
  1. reserves the run and checks `assertAffordable` against the plan estimate for the accepted steps;
  2. writes one `add_board` placeholder per accepted variant (status `generating`, stamped `agentRunId`);
  3. dispatches one render job per variant (the `KvToolController::generate` queued pattern: `/ai/kv-generator/complete` → `persistCompletion`, Craft, `base_generation` = source board tip, aspect = source).

  Each render runs and fails on its own.
- **FR-18:** When a render lands, the api writes `rekey_board_tip {placeholder → generation}`. When `copy_layers` is on, it also copies the source's layers onto the new board (FR-6 `overlaysForVariant`). A failed render removes its placeholder and appears in `skipped` with reason `render_failed`. The other variants are unaffected.
- **FR-19:** Each variant gets the next `deriveVariantName` (or the name the user gave). Its board metadata records `source_board_id` and `direction`.

**Size execution**

- **FR-20:** On Go for a size plan, the api calls `KvResizeExportService::createBatch` per board with the accepted sizes, under the existing rules:
  - custom sizes and layer-only presets only on layer-composed parents;
  - 20 sizes per call;
  - existing pricing: `kv_resize_overlay_only` per size for layer-composed parents, token metering for AI parents.

  Sizes the parent cannot take appear in `skipped` with the validation reason, never as a 422 for the whole plan.

**Progress, run card, undo**

- **FR-21:** Execution tools emit one generic progress event, `agent_item_progress {run_id, item_id, kind: board|size, state: queued|generating|done|failed, board_id?}`. It is relayed as SSE `tool_progress` (not persisted; `ChatService` byte cap). Renders that outlive the turn update the run card through its existing poll (`agentRunRefetchInterval`). The ledger reports them as "dispatched, not finished" (a new `KvCanvasWriteLedger` footnote rule).
- **FR-22:** The run card gains board and size rows: placeholder → rendering → done / failed, plus a thumbnail when done. Clicking a row focuses the board. Actual credits are shown once settled (`recordCredits` pattern). The canvas shows no agent badge: the run card is the only marker of agent-created boards. The `agent_run_id` stamp stays in board/generation metadata for undo.
- **FR-23:** The ledger records board ops (`sink: doc`, `op: add_board | rename_board | move_board | hide_board | rekey_board_tip`) and job ops (`sink: job`, `op: render | resize`, `job_id`). Undo, newest first:
  - an added board that the user has not edited since → `hide_board` (restorable, not deleted);
  - an edited board → kept and reported as `changed_after_run`;
  - rename/move → restored by CAS;
  - a queued or running job → cancelled (existing resize cancel; for renders, the placeholder is hidden and the late result is not placed);
  - a finished size → removed through the existing resize delete.

  Credits already spent are not refunded; the undo confirmation says so.
- **FR-24:** A run whose turn died or which stayed `running` past 15 min is closed by the sweeper (P0 `KvAgentRunRecorder` stale sweep). Placeholders that never got a render are removed, and a plan with nothing landed reopens to `proposed` (`DeckAgentRunService::fail` pattern).

**Intent layer**

- **FR-25:** `CanvasIntent.Action` gains `duplicate`, `variant`, `add_sizes`, `rename_board`, `arrange`, `hide_board`, `show_board`. `params` carries `count`, `directions[]`, `sizes[]`, `names[]`. `IntentSurface` gains board-level lookups (`known_board_ids`, a board-name resolver), and `build_tool_calls` routes each action through the capability registry. Board references resolve from the labels shown under boards (P0 FR-32).
- **FR-26:** When a variant request has no source board, the selection or active board is used if there is one; otherwise the validator asks with a which-board card. A `count` over 4 is clamped to 4, and the agent says so.
  - *Decided 2026-10-22 (daffa):* the duplicate limit is **per user message**, at most 4 copies in total across all named boards. "Duplicate A, B, C 4×" creates 4 boards, not 12, and the agent states the clamp once. ai-service clamps across the turn's calls; api enforces it per run (`duplicate_cap_reached` skip).
  - *Decided 2026-10-22 (daffa):* `add_sizes` with no named board **always asks** with the which-board card. It never falls back to the selected or active board, because it is a paid plan. The variant/duplicate fallback above is unchanged.

**Web**

- **FR-27:** A KV card registry maps `card_kind → component` (run card, plan card, question card). The P1 plan card and run-card rows are registered there, not wired by hand in `KvChat`.
- **FR-28:** Web hydrates placeholders from the live doc (agent boards are ordinary boards with a `generating` status), so a reload during a render shows the placeholder.
- **FR-29:** PostHog events: `kv_agent.plan_shown`, `kv_agent.plan_confirmed` (steps accepted / edited, `copy_layers`), `kv_agent.plan_cancelled`, `kv_agent.plan_expired`, `kv_agent.variant_done` / `variant_failed`.

### Non-Functional Requirements

- **NFR-1 (flag, fail-closed):** New flag `kv-agentic-canvas-structure` (off). With it off, P0 + intent behaviour is byte-identical. Free and paid structure tools are both behind it.
- **NFR-2 (credits):** No credit moves before Go. Before dispatch, the api gates on `assertAffordable(estimate of accepted steps)`. Billing stays with the existing services: `persistCompletion` (`KV_IMAGE_GENERATION`, `kv_gen_{id}` batch id) and resize pricing. Dispatch carries an idempotency key per `plan_step_id`, so a retried Go never charges twice.
- **NFR-3 (consistency):** Board writes are atomic per collab batch. A render that lands after undo is not placed. No partially applied batch within one sink (P0 NFR-3).
- **NFR-4 (latency):** Placeholders appear in open tabs ≤ 3 s after Go. A variant render's p95 is unchanged from today's single render (~66 s), and the N renders run in parallel.
- **NFR-5 (security):** Tool routes use `ResolveToolContext` and re-check file access (BOLA). `step_overrides` are validated against the stored step (direction ≤ 500 chars, no new keys). Directions are user-editable prompt text and are fenced like layer text (P0 FR-4).
- **NFR-6 (MCP parity):** Every new tool route has a `FrndosServer` twin. `php artisan mcp:verify-mirror` passes.
- **NFR-7 (quality gate):** The P0 eval stays 66/66 and the intent cases stay ≥ 90%. New golden cases (structure: duplicate / variant / sizes / unstated source / count > 4 / board named by label) score ≥ 90% on the default model.

## Service Breakdown

### Collab (`collab/`)

- Op registry: refactor `applyKvOps.ts` / `kvHttp.ts` so that each kind is one handler + zod schema.
- New kinds: `add_board`, `rename_board`, `move_board`, `hide_board`, `unhide_board`, `rekey_board_tip`, with pre-images and CAS.
- Board materialisation after a write.
- Tests: per-kind, atomicity across board + layer ops, CAS 409, doc not open.

### API (`api/`)

- Migrations: `kv_agent_plans`; `kv_agent_runs.plan_id`.
- `KvAgentPlanService`: propose / supersede / estimate / transition / markExecuted / expire / `acceptedPlanForStep`.
- Capability registry: `KvCanvasCapability` interface + entries (duplicate, rename, arrange, hide, variant_boards, add_sizes).
- Ports with TS fixtures: `KvBoardPlacement` (placement + naming) and `KvVariantOverlays` (`overlaysForVariant`).
- `KvCollabWriter` board ops; ledger board/job sinks; `KvAgentRunReverter` structural undo.
- Variant render job (extracted from the `KvToolController::generate` closure into a reusable job) + land step (`rekey_board_tip` + layer copy); resize dispatch through `createBatch`.
- Tool routes `v1/mcp/tools/kv/canvas/{fileId}/boards/*`, `…/plans`, `…/plans/steps/run` + MCP twins.
- Thread stream: plan Go/Cancel through `card_answer` purpose `plan`; plan transition before the payload; mount the execution tool on Go turns only.
- Run view: board/size rows, credits.
- Flag `kv-agentic-canvas-structure`.

### Frontend (`web/`)

- KV card registry; `KvPlanCard` (editable directions, checkboxes, copy-layers toggle, estimate, Go/Cancel, expired/superseded states).
- `KvAgentRunCard`: board/size rows with progress, thumbnails, focus, credits.
- `tool_progress` reducer for `agent_item_progress`; placeholder rendering for `generating` boards from the doc.
- TS fixture export script for the FR-6 ports.
- PostHog events (FR-29).

### AI Service (`ai-service/`)

- Capability-driven tools: `duplicate_kv_board`, `rename_kv_board`, `arrange_kv_boards`, `hide_kv_boards` / `unhide_kv_boards`, `propose_kv_variants`, `propose_kv_sizes`, `run_kv_plan_step`. Labels go through `TOOL_NAME_ENUM` / `TOOL_ICONS`.
- Plan gating: `stop_after_tool_call` + post-hook; `plan_pending` claimed before await; writes refused after a proposal; the execution tool is mounted only on a Go turn.
- `agent_item_progress` CustomEvent (`__str__` returns ''); `KvCanvasWriteLedger` claim words for boards/variants and a "dispatched, not finished" footnote rule.
- Intent: new actions + params, `IntentSurface` board lookups, a which-board card, `build_tool_calls` through the registry.
- Eval: structure golden cases in `evals/golden/kv_canvas/`.

### Data Service (`data-service/`)

No changes.

## UI/UX

### Key Screens

All in the existing KV chat panel and canvas. New states:

1. **Plan card: variants.**
   - Header "3 variants of V2".
   - One row per variant: an editable direction text field and a checkbox.
   - "Copy layers" toggle.
   - Estimate line ("≈ N credits · about 70 s"), balance, Go / Cancel.
2. **Plan card: sizes.**
   - Rows per board → sizes, each with its dimensions and method (layer / AI).
   - Estimate, Go / Cancel.
3. **Plan card: terminal states.** Accepted (Go pressed), cancelled, superseded by a newer plan, expired.
4. **Canvas placeholders.** N ghost boards next to the source with a "Generating…" state. They fill when the render lands and disappear with a failed note.
5. **Run card: structure rows.** Boards added (thumbnail, name, ✓ / ⚠ failed), sizes added, renamed / moved / hidden boards, credits used, Undo run (the confirmation mentions that credits are not refunded).
6. **Which-board card.** Shown when a variant or duplicate request has no source board.

A wireframe is needed for screens 1–5: a new `kv-agent-structure-cards` wireframe extending the P0 `kv-agent-cards` (frnd-web #1022).

## Data Model

### New Tables

`kv_agent_plans` (shape follows `deck_agent_plans`):

| column | type |
|---|---|
| `id` | ULID PK |
| `studio_file_id` | FK `studio_files`, cascade |
| `thread_id` | FK `user_threads`, null on delete |
| `run_id` | string(26) nullable (the run that executed it) |
| `user_id` | FK `users`, cascade |
| `goal` | text |
| `steps` | jsonb `[{id, capability, params, estimate}]` |
| `estimate` | jsonb `{credits_min, credits_max, seconds}` |
| `status` | `proposed` \| `accepted` \| `cancelled` \| `superseded` \| `expired` \| `executed` |
| `accepted_steps` | jsonb nullable |
| `step_overrides` | jsonb nullable |
| `superseded_by` | ULID nullable |
| `expires_at` | timestamp |
| timestamps | |

Indexes: (`studio_file_id`, `status`), `thread_id`.

### Modified Tables

- `kv_agent_runs`:
  - add `plan_id` (FK `kv_agent_plans`, null on delete) and `summary` jsonb nullable (credits, counts);
  - `ops` entries gain `sink: job` and board op types (no column change).
- `kv_generations.metadata`: `source_board_id`, `direction`, `agent_run_id` on agent variants (no column change).
- User chat message rows: `card_answer` with purpose `plan` (no column change).

## API Endpoints

| Method | Endpoint | Description | Service |
|--------|----------|-------------|---------|
| POST | `/internal/kv-files/{id}/ops` (modified) | Board op kinds | collab |
| POST | `v1/mcp/tools/kv/canvas/{fileId}/boards/duplicate` | `duplicate_kv_board` | api |
| POST | `v1/mcp/tools/kv/canvas/{fileId}/boards/rename` | `rename_kv_board` | api |
| POST | `v1/mcp/tools/kv/canvas/{fileId}/boards/arrange` | `arrange_kv_boards` | api |
| POST | `v1/mcp/tools/kv/canvas/{fileId}/boards/hide` | `hide_kv_boards` / `unhide_kv_boards` (`hidden: bool`) | api |
| POST | `v1/mcp/tools/kv/canvas/{fileId}/plans` | `propose_kv_variants` / `propose_kv_sizes` (capability in body) | api |
| POST | `v1/mcp/tools/kv/canvas/plans/steps/run` | `run_kv_plan_step` | api |
| GET | `v1/studio/files/{file}/agent/plans/{plan}` | Plan view for the card | api |
| GET | `v1/studio/files/{file}/agent/runs/{run}` (modified) | Board/size rows, credits | api |
| POST | `v1/studio/files/{file}/agent/runs/{run}/undo` (modified) | Structural undo | api |
| POST | `v1/threads/{id}/stream` (modified) | `card_answer` purpose `plan` | api |
| POST | `/ai/kv-generator/stream` (modified) | Plan context, structure tools, `agent_item_progress` | ai-service |

## Existing System Reconciliation

- **Deck is the template.** These are mirrored for KV, not shared yet:
  - `deck_agent_plans` / `DeckAgentPlanService`;
  - `propose_deck_plan` gating;
  - `plan_step_id` idempotency (`DeckToolController` L1563-1621);
  - `deck_compose_fanout.py` placeholders;
  - `stampSlides` / `undoAgentRun.ts`;
  - `recordCredits`, `failIfStale`, `DeckPlanCard`, `DeckChatActionsContext`.
- **Board placement is web-only today.** Boards are written by the browser (`docAddVariantBoard`, `useKvBoardMaterialization`). P1 adds a server writer for agent boards only. Manual flows (`handleCreateVariant`, Concept "Generate N") stay on the web path. Both use the same placement rules through FR-6 parity.
- **One image per stream.** `KvStreamRequest` has no count. Variants are N independent queued renders (the `KvToolController::generate` pattern), not a batch endpoint. The comment in `kvFanout.ts` about concurrent runs racing on chat history does not apply, because `/complete` gets `chat_history: []`.
- **Billing.** Image renders are metered on `persistCompletion` (not pre-charged), so a failed render costs nothing, and the plan gate is `assertAffordable` on the estimate. The Studio run-engine rule "charge up front, refund on failure" is not adopted for renders, because metering already gives the same outcome without a refund path. The estimate comes from `LLMHelper::estimateImageCredits` (image-models row) on the server.
- **Tables stay per surface** (`kv_agent_plans`, `kv_agent_runs`), and `agent_intent_events` stays generic. Unification goes to `studio-agent-surface`.
- **Studio run engine** (spec 2026-10-21) is not built and is keyed on Studio nodes. KV does not depend on it.

## Assumptions and Clarifications

- Branches are cut from the latest `develop` / `development` / `main` (P0 and intent are merged), as `feature/daffa/vc-kv-agentic-canvas-p1` in api, web, ai-service and collab.
- Delivery inside the feature: round A = registry + collab board ops + placement ports + free structure tools; round B = plan card + variants + sizes. Each round is one PR per service on the same branch, or one PR per service with round A reviewed first (decided at splitting).
- Variant renders use the file's default image model (same as `handleCreateVariant`). Picking a model in the plan card is out of scope.
- Concept mode and pixel edits on existing boards are out of scope (P2).

## Acceptance Criteria

- [ ] AC-1: Flag off → no structure tools are mounted, no plan card appears, and P0 eval 66/66 + intent cases are unchanged.
- [ ] AC-2: "Duplicate V2 twice, name them Ramadan and Lebaran" creates 2 boards next to V2 with those names and copied layers, live in a second tab, with no credits spent. Undo hides both.
- [ ] AC-3: "Generate 3 variants of V2 with different background colours" shows a plan card with 3 directions, "Copy layers" on and an estimate. No board and no credit is used before Go.
- [ ] AC-4: Untick variant 2, edit variant 3's direction, Go → exactly 2 placeholders appear next to V2 within 3 s; each fills with its render; variant 3 used the edited direction; layers were copied.
- [ ] AC-5: One of the renders fails → its placeholder is removed, the run card shows it as failed in plain words, the other variant lands, and only the landed render is billed.
- [ ] AC-6: Pressing Go twice (or retrying the turn) creates no extra boards and charges nothing twice.
- [ ] AC-7: A new instruction while a plan is pending supersedes it; Go on the old card does nothing and the card says so. A plan older than 15 min shows expired.
- [ ] AC-8: "Add Instagram Story and 1:1 to V2 and V3" shows a size plan with the method and price per size. Go creates the sizes. A size that V3 cannot take (layer-only preset on an AI parent) is listed as skipped with the reason.
- [ ] AC-9: Undo after AC-4: untouched variant boards are hidden, a variant the user edited is kept and reported, the undo dialog says credits are not refunded, and a second undo → `already_undone`.
- [ ] AC-10: Undo while a render is still running → its placeholder is hidden and the late result does not appear on the canvas.
- [ ] AC-11: "Generate 6 variants" → the plan has 4 and the agent says the max is 4. "Generate variants" with no selection on a multi-board file → which-board card, no plan.
- [ ] AC-12: PHP placement/naming/overlay ports pass the TS-generated fixtures.
- [ ] AC-13: Adding a throwaway capability in a test (fake registry entry) needs no change to the validator, the plan service, the reverter loop or the card host.
- [ ] AC-14: `mcp:verify-mirror` passes. The new structure golden cases score ≥ 90% on the default model.
- [ ] AC-15: With the file open nowhere, an agent duplicate is visible in REST canvas-state and in the next browser open.

## Open Questions

- [x] Q-1: Estimate source for variants → a min–max range (`{credits_min, credits_max}`, same shape as the deck estimate), derived from the file's default image model pricing × accepted variants, because renders are token-metered (daffa, 2026-10-21).
- [x] Q-2: Canvas badge for agent boards → none. The run card is the only marker; the `agent_run_id` stamp stays in metadata for undo (daffa, 2026-10-21).
- [x] Q-3: Caps per run → 20 board ops, 4 variants + 20 sizes. Revisit when MCP opens in P2 (daffa, 2026-10-21).
- [x] Q-4: Delivery → two stacked PRs per service: round A (registry, collab board ops, placement ports, free structure tools), then round B (plan card, variants, sizes) stacked on A (daffa, 2026-10-21).
