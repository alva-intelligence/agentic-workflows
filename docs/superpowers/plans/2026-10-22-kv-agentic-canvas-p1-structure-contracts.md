# KV Agentic Canvas P1 — Board Structure — Frozen Contracts (S1–S18)

Date: 2026-10-22. Source: `frnd/docs/prd/kv-agentic-canvas-p1.md` (approved 2026-10-21) plus the design spec §6. These shapes are binding for collab, api, ai-service and web. Changing one requires editing this file first and telling the other services.

Branch in every repo: `feature/daffa/vc-kv-agentic-canvas-p1`. Worktree: `<repo>/.worktrees/kv-agentic-canvas-p1`.

Build order (each repo is testable alone with fakes): collab → api → ai-service → web.

Delivery: two stacked PR rounds per service on the same branch. **Round A** = capability registry + collab board ops + placement ports + free structure tools. **Round B** = plan card + variant execution + size execution (stacked on A, reviewed after A merges).

---

## S1 — Collab board op kinds (collab, Round A) [FR-4]

`POST /internal/kv-files/{fileId}/ops` (existing C1.2) gains new op kinds. The existing `KvOp` union (`set_layer | add_layer | remove_layer`) is extended; each new kind is a handler in an op registry (refactored from inline `writeOp`). All ops run in one `doc.transact(…, SERVER_WRITE_ORIGIN)`. Pre-images are returned in `before`.

New kinds and their payloads:

| Kind | Payload fields | Semantics |
|------|---------------|-----------|
| `add_board` | `board_id`, `x: number`, `y: number`, `name: string \| null`, `version_ids: string[]`, `agent_run_id: string \| null` | Creates a board entry in `boards` Y.Map keyed by `board_id`, with `x`, `y`, `name`, `versionIds`. Does NOT touch overlays. 409 `board_exists` if the key already exists. |
| `rename_board` | `board_id`, `name: string`, `expected?: { name: string \| null }` | Sets the board's `name`. CAS on `expected.name` → 409 `board_changed`. 404 `board_not_found` if absent. |
| `move_board` | `board_id`, `x: number`, `y: number`, `expected?: { x: number, y: number }` | Sets `x`, `y`. CAS on `expected`. 404 `board_not_found`. |
| `hide_board` | `board_id` | Pushes `[board_id, ...versionIds]` into the `removed` Y.Array, as web's `docRemoveBoard` does (amended in Round A — pushing only the tip let web lay older versions back out). Idempotent: no-op if already present. 404 `board_not_found` if the key does not exist in `boards`. |
| `unhide_board` | `board_id` | Removes EVERY occurrence of `board_id` and its `versionIds` from `removed` (amended in Round A — two concurrent hides leave duplicates). Idempotent. 404 `board_not_found`. |
| `rekey_board_tip` | `from: string`, `to: string` | Replaces the board key: deletes `boards[from]` and creates `boards[to]` with the same `x`, `y`, `name` and `versionIds` (with `to` APPENDED to `versionIds` — the chain is oldest→newest, same as web `docRekeyBoardTip`; an empty chain becomes `[from, to]`; amended in Round A). Master moves `from`→`to`. All overlays whose `boardGenerationId == from` are updated to `to` (saved overlays are seeded into the doc first if it has none, and overlay materialisation runs). `applied` = `{kind, board_id: <to>, from}`. 404 `board_not_found` names `from`. 409 `board_exists` names `to`, including `from === to`. |

`before` for board ops:
- `add_board`: `before.boards[board_id] = null`.
- `rename_board` / `move_board`: `before.boards[board_id] = { name, x, y, versionIds }`.
- `hide_board` / `unhide_board`: `before.removed = <array before>`.
- `rekey_board_tip`: `before.boards[from] = <board before>`, `before.boards[to] = null`.

Error codes for board ops follow the same HTTP status convention as layer ops:

| Status | code | extra |
|--------|------|-------|
| 409 | `board_exists` | `board_id` |
| 409 | `board_changed` | `board_id`, `expected`, `current` |
| 404 | `board_not_found` | `board_id` |

A batch may mix layer ops and board ops. Validation runs on all before any write.

After a write that includes board ops, collab materialises boards to api via the existing `internal/kv-files/{id}/snapshot` path (board metadata). Overlay materialisation (C2) runs only when layer ops are present.

## S2 — Collab op registry refactor (collab, Round A)

`applyKvOps.ts` is refactored so that each op kind is a handler object `{ validate(doc, op), write(doc, op): before }` registered in a `Map<string, Handler>`. The existing `writeOp` switch is replaced. The HTTP route (`kvHttp.ts`) delegates to the registry. Zod schemas per kind replace the current union.

This makes adding a kind a single-file change (the handler + its zod schema), satisfying FR-1 and AC-13.

## S3 — Feature flag `kv-agentic-canvas-structure` (api, Round A) [NFR-1]

PostHog boolean flag `kv-agentic-canvas-structure`, default off. api: `feature.flag:kv-agentic-canvas-structure,off` middleware on the new tool routes. Fail-closed: absent or erroring = off.

With it off: P0 + intent behaviour is byte-identical. No structure tools are mounted, no plan card appears. The P0 flag `kv-agentic-canvas` remains the parent gate.

## S4 — Capability registry (api + ai-service, Round A) [FR-1, FR-2, AC-13]

### api

`App\Services\Studio\AgentCanvas\Capabilities\KvCanvasCapability` interface:

```php
interface KvCanvasCapability {
    public function name(): string;          // tool name, e.g. 'duplicate_kv_board'
    public function cost(): string;          // 'free' | 'plan'
    public function estimate(array $params, KvCanvasState $state): array;  // {credits_min, credits_max, seconds}
    public function execute(array $params, KvAgentRun $run, KvCanvasState $state): array;  // write result
    public function revert(array $op, KvAgentRun $run): array;  // undo result
    public function cardKind(): ?string;     // web card kind or null
    public function toolSchema(): array;     // JSON Schema for the MCP twin
}
```

`KvCanvasCapabilityRegistry` (singleton): `register(KvCanvasCapability)`, `get(name)`, `all()`, `byKind(cost)`. P1 entries: `DuplicateKvBoard`, `RenameKvBoard`, `ArrangeKvBoards`, `HideKvBoards` (free); `VariantBoards`, `AddSizes` (plan).

Adding a capability = one class implementing the interface + registering it. The validator, plan service, reverter loop and card host read from the registry (AC-13).

### ai-service

`app/tools/kv_canvas_capability.py`: `KvCanvasCapabilityEntry` dataclass (`name`, `cost`, `tool_fn`, `tool_schema`). `KV_CANVAS_CAPABILITIES` registry dict. `make_kv_structure_tools(…)` builds tools from the registry, gated on the flag.

## S5 — Run caps per op class (api, Round A) [FR-3]

`KvAgentRunRecorder` gains per-class caps checked before each write:

| Class | Cap | Counter | Skip reason |
|-------|-----|---------|-------------|
| layer | 200 (existing `MAX_OPS`) | ops with `sink: doc` and layer kinds | `run_op_cap_reached` |
| board | 20 | ops with `sink: doc` and board kinds | `run_op_cap_reached` |
| job (variants) | 4 | ops with `sink: job` and `op: render` | `run_op_cap_reached` |
| job (sizes) | 20 | ops with `sink: job` and `op: resize` | `run_op_cap_reached` |

Exceeding a cap gives a per-target skip, never a 500.

## S6 — Server-side board placement (api, Round A) [FR-6, FR-7, AC-12]

PHP ports of web TS functions, pinned by JSON fixtures generated from the TS (same pattern as `KvTileOverlayProjector`):

| PHP class | Web source | Purpose |
|-----------|-----------|---------|
| `KvBoardPlacement::adjacentFreeCenter` | `boardLayout.ts:adjacentFreeCenter` | Place 1 board next to a source |
| `KvBoardPlacement::nextFreeCenters` | `boardLayout.ts:nextFreeCenters` | Place N boards side by side |
| `KvBoardLabel::deriveVariantName` | `boardLayout.ts:deriveVariantName` | Already ported (P0) |
| `KvVariantOverlays::overlaysForVariant` | `src/lib/studio/kv/overlayMutations.ts` | Copy source layers onto a new board id |
| `KvEditOutcome::resolve` | `editOutcome.ts` | Determine whether a board was user-edited since a run |

`KvBoardPlacement` and `KvVariantOverlays` are new. `KvBoardLabel` exists from P0.

web exports a TS fixture script (`scripts/exportBoardPlacementFixtures.ts`) that writes JSON files consumed by the PHP tests. CI runs the TS export and the PHP test in sequence so a divergence fails the build.

## S7 — `KvCollabWriter` board ops (api, Round A) [FR-4]

The existing `KvCollabWriter` (HTTP client for collab) gains methods for the S1 board op kinds: `addBoard`, `renameBoard`, `moveBoard`, `hideBoard`, `unhideBoard`, `rekeyBoardTip`. Each builds the correct `ops[]` payload for `POST /internal/kv-files/{id}/ops`. Same token, timeout (≥15 s), 2 MB cap, error mapping.

## S8 — Ledger board/job sinks (api, Round A) [FR-23]

`kv_agent_runs.ops` entries gain two new sink values beyond the existing `doc` and `tile`:

- `sink: doc, op: add_board | rename_board | move_board | hide_board | rekey_board_tip` — board ops in the collab doc.
- `sink: job, op: render | resize, job_id: string` — dispatched render/resize jobs.

No column change; `ops` is already jsonb. `KvAgentRunRecorder::recordBoardOp` and `recordJobOp` append to the array.

## S9 — Structural undo (api, Round A for board ops; Round B for job ops) [FR-23]

`KvAgentRunReverter` gains board and job undo, newest first through the capability registry's `revert(op)`:

| Op | Undo |
|----|------|
| `add_board` (user has not edited since) | `hide_board` (restorable, not deleted). "Edited" = `KvEditOutcome::boardEditedSince` (api-only; see open issue 9), not `resolve`. |
| `add_board` (user edited) | Kept, reported as `changed_after_run`. |
| `rename_board` / `move_board` | Restored by CAS (`expected` = current, set = `before`). |
| `hide_board` | `unhide_board`. |
| `render` (queued or running) | Cancel placeholder: `hide_board` on the placeholder, and any late result is not placed (the render land step checks `run.status`). |
| `render` (done) | `hide_board` on the generated board. |
| `resize` (queued or running) | Cancel via `KvResizeExportService::cancel` (existing). |
| `resize` (done) | Remove via `KvResizeExportService::deleteExport` (existing). |

Credits already spent are not refunded. The undo confirmation text says so.

## S10 — Free structure tool routes (api, Round A) [FR-8, FR-9, FR-10]

| Route | Tool name (MCP twin) | Capability | Description |
|-------|---------------------|-----------|-------------|
| `POST v1/mcp/tools/kv/canvas/{fileId}/boards/duplicate` | `duplicate_kv_board` | `DuplicateKvBoard` | FR-8: `{board_id, count ≤ 4, names?, copy_layers=true}`. Uses `duplicateGeneration` (no AI). Each copy: `add_board` + `add_layer` per copied layer. |
| `POST v1/mcp/tools/kv/canvas/{fileId}/boards/rename` | `rename_kv_board` | `RenameKvBoard` | FR-9: `{board_id, name}`. |
| `POST v1/mcp/tools/kv/canvas/{fileId}/boards/arrange` | `arrange_kv_boards` | `ArrangeKvBoards` | FR-9: `{layout: "grid" \| "row"}`. Deterministic from S6 placement. |
| `POST v1/mcp/tools/kv/canvas/{fileId}/boards/hide` | `hide_kv_boards` | `HideKvBoards` | FR-9: `{board_ids, hidden: bool}`. hide or unhide. |

Middleware: `ResolveToolContext` + `feature.flag:kv-agentic-canvas` + `feature.flag:kv-agentic-canvas-structure`. MCP twins in `FrndosServer`. `mcp:verify-mirror` passes.

Unstated targets (FR-10): when the user didn't name a board, the intent validator asks with the target card (existing `purpose: "targets"` question card). No write in that turn.

## S11 — `kv_agent_plans` table + `KvAgentPlanService` (api, Round B) [FR-11, FR-12, FR-14, FR-16]

### Migration

`kv_agent_plans` (shape follows `deck_agent_plans`, 2026_09_17_100300):

| column | type |
|--------|------|
| `id` | ULID PK |
| `studio_file_id` | FK `studio_files`, cascade |
| `thread_id` | FK `user_threads`, null on delete |
| `run_id` | string(26) nullable |
| `user_id` | FK `users`, cascade |
| `goal` | text |
| `steps` | jsonb `[{id, capability, params, estimate}]` |
| `estimate` | jsonb `{credits_min, credits_max, seconds}` |
| `status` | `proposed` / `accepted` / `cancelled` / `superseded` / `expired` / `executed` |
| `accepted_steps` | jsonb nullable |
| `step_overrides` | jsonb nullable |
| `superseded_by` | ULID nullable |
| `expires_at` | timestamp |
| timestamps | |

Indexes: (`studio_file_id`, `status`), `thread_id`.

`kv_agent_runs` gains `plan_id` (FK `kv_agent_plans`, null on delete) and `summary` (jsonb nullable).

### `KvAgentPlanService`

Methods (mirror `DeckAgentPlanService`):

- `propose(file, thread, user, goal, steps): KvAgentPlan` — creates with status `proposed`, expires_at = now + 15 min. Supersedes any pending plan on the same thread.
- `supersedeExisting(thread)` — sets pending → `superseded`.
- `estimateSteps(steps): {credits_min, credits_max, seconds}` — per step through the capability registry.
- `transition(plan, action, acceptedSteps, stepOverrides): KvAgentPlan` — validates shape (direction ≤ 500 chars, ≤ 4 steps total), re-estimates, sets status. `action = "go"` → `accepted`; `"cancel"` → `cancelled`.
- `markExecuted(plan, run)`.
- `acceptedPlanForStep(planStepId): ?KvAgentPlan` — returns the plan if it is `accepted` and has that step.

Expired plans: a `proposed` plan older than `expires_at` is treated as expired on read (status check) and lazily updated. Go on an expired/superseded/cancelled/executed plan writes nothing.

## S12 — Plan card (api + ai-service + web, Round B) [FR-11, FR-13, FR-14, FR-15]

### Proposal flow (ai-service → api)

`propose_kv_variants` and `propose_kv_sizes` tools (ai-service) call `POST v1/mcp/tools/kv/canvas/{fileId}/plans`:

```jsonc
// propose_kv_variants
{ "capability": "variant_boards",
  "params": {
    "board_id": "gen_…",
    "variants": [{ "direction": "…", "suggestions": [{"label": "…", "direction": "…"}] }],
    "extra_directions": [{"label": "…", "direction": "…"}],
    "copy_layers": true
  }
}

// propose_kv_sizes
{ "capability": "add_sizes",
  "params": {
    "board_ids": ["gen_…"],
    "sizes": ["Instagram Story", {"width": 1080, "height": 1080}]
  }
}
```

api builds steps from params, estimates via S4 registry, calls `KvAgentPlanService::propose`, returns the plan view. `stop_after_tool_call` + post-hook ends the turn. `plan_pending` is claimed before the await (the `propose_deck_plan` pattern). Every other write in that turn is refused.

`variants[].suggestions`: ≤ 3 per variant. `extra_directions`: ≤ 3. Both are grounded in the source board and the brand, distinct from the variant's own direction, fenced like other user-editable text.

### Go / Cancel flow (web → api → ai-service)

`card_answer` on `POST v1/threads/{id}/stream`, surface `kv_canvas`, purpose `plan`:

```jsonc
{ "card_answer": {
    "card_id": "01J…",
    "option_ids": ["go"],      // or ["cancel"]
    "purpose": "plan",
    "surface": "kv_canvas"
  },
  "plan_action": {
    "plan_id": "01J…",
    "accepted_steps": ["step_01J…", "step_01J…"],
    "step_overrides": { "step_01J…": { "direction": "edited direction" } }
  }
}
```

`QuestionCardPayload::PURPOSES` gains `'plan'`. `CardAnswer` validates `plan_action` when purpose is `plan`.

api transitions the plan before building the ai-service payload (`DeckAgentPlanService::transition` pattern). On a Go turn, the execution tool `run_kv_plan_step` is mounted. On Cancel, nothing is mounted.

### Plan view (api → web)

`GET v1/studio/files/{file}/agent/plans/{plan}`:

```jsonc
{ "id": "01J…", "status": "proposed", "goal": "3 variants of V2",
  "steps": [{ "id": "step_…", "capability": "variant_boards",
              "params": { "direction": "…", "suggestions": [...], "board_id": "…" },
              "estimate": { "credits_min": 3, "credits_max": 5, "seconds": 70 } }],
  "estimate": { "credits_min": 9, "credits_max": 15, "seconds": 70 },
  "copy_layers": true,
  "expires_at": "…", "created_at": "…" }
```

### Execution tool (ai-service, Round B) [FR-15]

`run_kv_plan_step {plan_step_id}`: mounted only on a Go turn. Calls `POST v1/mcp/tools/kv/canvas/plans/steps/run`. api checks `acceptedPlanForStep(plan_step_id)`, executes via the capability registry, marks the step done. Idempotent: a repeated `plan_step_id` returns the prior result without writing again.

## S13 — Variant execution (api, Round B) [FR-17, FR-18, FR-19]

On Go for a variant plan, the api:

1. Reserves the run, `assertAffordable(estimate of accepted steps)`.
2. Writes one `add_board` placeholder per accepted variant (board metadata: `status: "generating"`, stamped `agent_run_id`). Placement via S6 `nextFreeCenters`.
3. Dispatches one render job per variant: the `KvToolController::generate` queued pattern (`/ai/kv-generator/complete` → `persistCompletion`). Craft, `base_generation` = source board tip, aspect = source. Each uses an idempotency key per `plan_step_id`.

When a render lands:
- `rekey_board_tip {placeholder → generation}`.
- If `copy_layers` on: `overlaysForVariant` (S6) copies source layers onto the new board.
- Failed render: hide placeholder, report `skipped` with `render_failed`. Others unaffected.

Each variant gets `deriveVariantName` (or the user's name). Board metadata records `source_board_id` and `direction`.

## S14 — Size execution (api, Round B) [FR-20]

On Go for a size plan, the api calls `KvResizeExportService::createBatch` per board with the accepted sizes:
- Custom sizes and layer-only presets only on layer-composed parents.
- 20 sizes per call.
- Existing pricing: `kv_resize_overlay_only` for layer-composed parents, token metering for AI parents.

Sizes the parent cannot take appear in `skipped` with the validation reason, never a 422 for the whole plan.

## S15 — Progress and run card (api + web, Round B) [FR-21, FR-22]

### Progress event (ai-service → api → web)

Execution tools emit `agent_item_progress`:

```jsonc
{ "event": "tool_progress",
  "run_id": "01J…", "item_id": "step_…",
  "kind": "board" | "size",
  "state": "queued" | "generating" | "done" | "failed",
  "board_id": "gen_…" }
```

Relayed as SSE `tool_progress`. Not persisted. `ChatService` byte cap applies. Renders that outlive the turn update the run card through `agentRunRefetchInterval` (existing poll).

### Run card (web)

Board/size rows: placeholder → rendering → done / failed, thumbnail when done. Clicking a row focuses the board. Actual credits shown once settled (`recordCredits` pattern). No agent badge on the canvas. The `agent_run_id` stamp in board/generation metadata is for undo only.

### Undo confirmation

Says "Credits already spent are not refunded." (added in Round B; P0 run card omits this line).

## S16 — Intent layer extensions (ai-service, Round A) [FR-25, FR-26]

`CanvasIntent.Action` gains:

```python
Action = Literal[
    # existing
    "resize", "move", "rotate", "hide", "show", "restack", "text", "style",
    "add", "remove", "undo", "pixel_edit", "brainstorm", "other",
    # P1 new
    "duplicate", "variant", "add_sizes", "rename_board", "arrange", "hide_board", "show_board",
]
```

`params` carries `count`, `directions[]`, `sizes[]`, `names[]` as needed per action.

`IntentSurface` gains board-level lookups: `known_board_ids` (from inventory), a board-name resolver (maps board labels to ids), and `build_tool_calls` routes each action through the capability registry (S4 ai-service side).

When a variant request has no source board: selection or active board is used; otherwise the validator asks with a which-board card. `count > 4` → clamped to 4 and the agent says so.

## S17 — Web card registry + plan card (web, Round A registry; Round B plan card) [FR-27, FR-28, FR-29]

### Card registry (Round A)

`KvCardRegistry`: maps `card_kind → React component`. P0 entries: `run_card` → `KvAgentRunCard`, `question_card` → existing `QuestionCard`. P1 adds `plan_card` → `KvPlanCard` in Round B. The card host in `KvChat` reads the registry instead of hardcoding.

### Plan card component (Round B)

`KvPlanCard` (wireframe: `kv-agent-structure-cards/?state=plan`):
- One row per variant step: editable direction text field, suggestion chips below, checkbox.
- "Add variant" button (up to 4; at 4: "Max 4 variants"). Prefills from `extra_directions`.
- "Copy layers" toggle (default on).
- Per-size row: preset, dimensions, method (layer / AI).
- Total estimate (credits min–max + time), balance, Go / Cancel.
- Terminal states: accepted (Go pressed, wireframe `?state=generating`/`done`), cancelled, superseded, expired.

`step_overrides` sent on Go: edited directions, added rows as new steps, copy-layers value.

### PostHog events (Round B)

`kv_agent.plan_shown`, `kv_agent.plan_confirmed` (steps accepted/edited, copy_layers), `kv_agent.plan_cancelled`, `kv_agent.plan_expired`, `kv_agent.variant_done` / `variant_failed`.

## S18 — Placement port fixture export (web, Round A) [FR-6, AC-12]

`web/scripts/exportBoardPlacementFixtures.ts`: imports `adjacentFreeCenter`, `nextFreeCenters`, `deriveVariantName`, `overlaysForVariant`, `editOutcome` from the TS source, runs them on fixture inputs, writes JSON to `web/fixtures/board-placement/`. The api PHP tests read these same files.

CI step: `bun run scripts/exportBoardPlacementFixtures.ts && php artisan test --filter=KvBoardPlacementTest` (or equivalent).

---

## Shared names

| Name | Kind | Service | Round |
|------|------|---------|-------|
| `kv-agentic-canvas-structure` | PostHog flag | api (gate), web (card rendering) | A |
| `KvCanvasCapability` | Interface | api | A |
| `KV_CANVAS_CAPABILITIES` | Registry dict | ai-service | A |
| `kv_agent_plans` | DB table | api | B |
| `kv_agent_runs.plan_id` | Column | api | B |
| `kv_agent_runs.summary` | Column | api | B |
| `duplicate_kv_board` | Tool name | api, ai-service | A |
| `rename_kv_board` | Tool name | api, ai-service | A |
| `arrange_kv_boards` | Tool name | api, ai-service | A |
| `hide_kv_boards` | Tool name | api, ai-service | A |
| `propose_kv_variants` | Tool name | ai-service → api | B |
| `propose_kv_sizes` | Tool name | ai-service → api | B |
| `run_kv_plan_step` | Tool name | ai-service → api | B |
| `card_answer` purpose `plan` | Protocol | web → api → ai-service | B |
| `agent_item_progress` | SSE event | ai-service → api → web | B |
| `add_board`, `rename_board`, `move_board`, `hide_board`, `unhide_board`, `rekey_board_tip` | Collab op kinds | collab, api | A |
| `KvBoardPlacement` | PHP class | api | A |
| `KvVariantOverlays` | PHP class | api | A |
| `KvEditOutcome` | PHP class | api | A |
| `KvPlanCard` | React component | web | B |
| `kv_agent.plan_shown` / `plan_confirmed` / `plan_cancelled` / `plan_expired` / `variant_done` / `variant_failed` | PostHog events | web | B |

## Open issues / contract deviations

1. **`overlaysForVariant` location in web.** The PRD says it is in `boardLayout.ts`, but the code has it in `src/lib/studio/kv/overlayMutations.ts` (tested in `overlayMutations.test.ts`); `editOutcome` is in `src/lib/studio/kv/editOutcome.ts`. The PHP port should reference the actual file, not the PRD's location.

2. **`editOutcome` location in web.** Similarly in `src/lib/studio/kv/editOutcome.ts`, not `boardLayout.ts`. The PRD's FR-6 reference to `editOutcome.ts` is correct; it just does not live inside `boardLayout.ts` as FR-6 says parenthetically.

3. **`QuestionCardPayload::PURPOSES` is in `App\Support\KvChat\QuestionCardPayload`**, not `App\Support\Chat\QuestionCardPayload`. Adding `'plan'` must go to the correct class.

4. **Existing `CanvasIntent.Action` does not have board-level actions.** Current values are layer-focused (`resize`, `move`, `rotate`, `hide`, `show`, `restack`, `text`, `style`, `add`, `remove`, `undo`, `pixel_edit`, `brainstorm`, `other`). The new actions (`duplicate`, `variant`, `add_sizes`, `rename_board`, `arrange`, `hide_board`, `show_board`) are additive and should not conflict.

5. **`KvAgentRun` model has no `plan_id` or `summary` columns today.** The migration must add both. The model's `$fillable` must be updated.

6. **Collab `boards` Y.Map key naming.** The PRD says `add_board` takes `board_id` as the key. In the current doc model, the key IS the tip generation id. For placeholder boards (which get rekeyed later), the `board_id` will be a temporary ULID that is later replaced by `rekey_board_tip`. This is consistent with the existing pattern.

7. **`kv_agent_runs.ops` currently only records `doc` and `tile` sinks.** Adding `job` sink is purely a jsonb content change, no schema migration needed.

8. **Round A collab amendments (2026-10-22, collab 8ed5736..26e9a2a).** S1 was amended in place for `hide_board`, `unhide_board` and `rekey_board_tip`. Additional facts:
   - The response gains `materialization: {overlays, boards}` (`null` = that one did not run). `materialized` is true only when every materialisation that ran succeeded. The worst case is about 10s, so callers must use a timeout of 15s or more.
   - Board names are stored as `trim() || null`. `agent_run_id` is optional and only logged.
   - In `before`, the first touch of an id within a batch wins: `add_board X` + `rename_board X` → `before.boards[X] = null`. `before.removed` appears only when the batch hides or unhides; undo uses `unhide_board`, not a wholesale array restore.
   - A `board_changed` 409 returns `current` as `{name}` (rename) or `{x, y}` (move); `move_board.expected` needs both.
   - Known gap: board ops on a file whose doc has no boards (never opened since live collab) return 404. Callers should report them as skipped.
9. **`KvEditOutcome` split (api Round A).** `KvEditOutcome::resolve` ports TS `editOutcome` exactly (rekey/fork/variant), so it passes fixture parity. S9's "user has not edited since" uses a new api-only `KvEditOutcome::boardEditedSince`, not `resolve`.
10. **`deriveVariantName` truncates on code points** (web d9f0a177c fixed the UTF-16 split of astral emoji). This matches P0's `KvBoardLabel` (`mb_substr`).
11. **Decisions 2026-10-22 (daffa, after Round A).** (a) The duplicate limit of 4 counts per user message / run, in total across boards: ai-service clamps across the turn's `duplicate_kv_board` calls, and api enforces it per `run_id` from the ledger's duplicate `add_board` ops, skipping the excess with `duplicate_cap_reached`. The per-call `count` max of 4 stays. (b) `add_sizes` with no named board always shows the which-board card; it has no selected/active fallback (S16). (c) Hidden boards reach the agent only through `get_kv_canvas.hidden_boards` (api, flag on); the intent fast path hands "show X" to the agent when X is hidden. Round B may add `hidden_boards` to the intent inventory.

