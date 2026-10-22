# KV Agentic Canvas P1 — Round A (api) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Behind the fail-closed flag `kv-agentic-canvas-structure`, the KV agent can duplicate, rename, arrange and hide boards for free, through a capability registry, with every board op ledgered and undoable.

**Architecture:** One `KvCanvasCapability` class per tool, registered in a singleton `KvCanvasCapabilityRegistry`. A generic runner (`KvCanvasStructureService`) validates params against the capability's own `toolSchema()`, takes the per-file write lock, loads the canvas, opens the run, and calls `execute`. Capabilities write board ops through `KvCollabWriter` (S1 kinds) and ledger them with `KvAgentRunRecorder::recordBoardOp`. Undo asks each op's capability for the inverse op(s), then applies them with a generic in-memory S1 interpreter, which is what keeps the reverter capability-agnostic (AC-13).

**Tech Stack:** Laravel 13, PHP 8.5, Pest 4, laravel/mcp, Postgres (scratch test DB).

**Spec:** service PRD `api/.worktrees/kv-agentic-canvas-p1/docs/prd/kv-agentic-canvas-p1.md` (Round A TASK-1..10), contracts `docs/superpowers/plans/2026-10-22-kv-agentic-canvas-p1-structure-contracts.md` (S3–S10, S18), main PRD `frnd/docs/prd/kv-agentic-canvas-p1.md` FR-1..FR-10, FR-23, NFR-1, NFR-6.

Work dir for every task: `api/.worktrees/kv-agentic-canvas-p1`. Branch `feature/daffa/vc-kv-agentic-canvas-p1`. Never push. Never stash.

## Global Constraints

- Flag key `kv-agentic-canvas-structure`. Fail-closed. The parent `kv-agentic-canvas` must also be on. Config `studio.kv_agent_structure_flag` (env `KV_AGENT_STRUCTURE_FLAG`, default `false`) is the switch outside production.
- With the flag off, P0 + intent are byte-identical: no `tools` key in `agent_canvas`, no `hidden_boards` in the inventory, and no change to the ledger for layer ops. (The run view gains an additive, always-present `boards` key: `[]` for P0 runs.)
- Doc budget: a run's `sink: doc` ops (layer + board) never exceed `KvCollabWriter::MAX_OPS_PER_BATCH = 200` (collab `MAX_KV_OPS`). This keeps every write batch and the run's one-batch undo within collab's limit. (Added in the review fix pass.)
- Tool names: `duplicate_kv_board`, `rename_kv_board`, `arrange_kv_boards`, `hide_kv_boards`. Routes `POST v1/mcp/tools/kv/canvas/{fileId}/boards/{duplicate|rename|arrange|hide}`. Middleware: `feature.flag:kv-agentic-canvas,off` + `feature.flag:kv-agentic-canvas-structure,off`.
- Collab board op kinds and payloads are exactly S1: `add_board{board_id,x,y,name,version_ids,agent_run_id}`, `rename_board{board_id,name,expected?{name}}`, `move_board{board_id,x,y,expected?{x,y}}`, `hide_board{board_id}`, `unhide_board{board_id}`, `rekey_board_tip{from,to}`. Board errors: 409 `board_exists`/`board_changed`, 404 `board_not_found`.
- Caps per run (S5): layer 200 (`KvAgentRun::MAX_OPS`), board 20, render jobs 4, resize jobs 20. Over a cap = per-target skip `run_op_cap_reached`, never a 500.
- `duplicate_kv_board`: `count` 1..4, `copy_layers` default `true`, no AI call.
- Ledger op `sink` values: `doc` (layer and board ops), `tile`, `job`. A board op is `{type, sink: doc, capability, target: board_id, target_kind: board, board_id, target_label, layer_id: null, before, after, at}`.
- No `Http::retry()`. Validate request input with `Validator::make($request->all(), …)` and read values with `input()`. Never use `validated()` on nested arrays (`excludeUnvalidatedArrayKeys` is on).
- Tests run against the scratch DB `frnd_kv_p0_test` through `scratchpad/t.sh` (it exports `DB_*` + `TELESCOPE_ENABLED=false` and deletes `bootstrap/cache/config.php`). Pass test paths, never `--filter`. Baseline before any change: AgentCanvas Feature + Unit + `KvCanvasToolsTest` = 227 pass, 3 fail (`UpdateKvLayersToolTest` OAuth "Invalid key supplied": no passport keys in a worktree, so this is environmental).
- Commit per task: `feat(api): …` and the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Run `vendor/bin/pint --dirty --format agent` before each commit.

## Contract deviations (tell the lead)

1. **`KvEditOutcome::resolve` is not "edited since a run".** The TS `editOutcome` (`src/lib/studio/kv/editOutcome.ts`) answers rekey / fork / variant for a Craft edit. It does not say whether a user edited a board. The PHP port keeps that exact meaning, so it passes fixture parity: `resolve(bool $parentIsConcept, int $parentResizeCount, ?bool $variantRedirectEnabled = null): string`. Undo's "edited" test (S9) is a new api-only method, `KvEditOutcome::boardEditedSince(...)`. It counts a board as edited when `resolve(false, resizeCount) === 'variant'` (someone resized it), when its key, name or position moved off what the run wrote, or when it still holds layers after the run's own layer adds are reverted.
2. **`revert(array $op, KvAgentRun $run): array` returns an undo instruction, not an undo result.** The shape is `array{ops: list<S1 op>, only_if_unedited?: bool}`. The reverter applies the inverse S1 ops to an in-memory copy of the live boards, with collab's own CAS rules, and coalesces them into one batch per undo. This is needed because two inverse ops on one board in one collab batch would CAS against stale values (collab validates the whole batch before it writes). The signature is unchanged.
3. **`unhide_board` is ledgered too.** `hide_kv_boards {hidden: false}` writes `unhide_board`. Its undo is `hide_board`. S8's op list is extended with it; this is additive.
4. **`VariantBoards` and `AddSizes` are registered in Round B** (TASK-17/19), not as Round A stubs. Round A registers the four free capabilities.
5. **Fixtures are vendored.** The PHP parity test reads `tests/Fixtures/kv-board-placement/*.json`, copied from `web/fixtures/board-placement/`. This is the `kv-projection` precedent, because the repos are separate. The S18 CI command becomes "copy, then `pest tests/Unit/Studio/AgentCanvas/KvBoardPlacementTest.php`".

## Review Focus

1. **A board id that is an older id in a version chain**, not the tip. Expected: it resolves to the board (as `KvCanvasState::board` does), and ops address the tip key. Pinned in Task 6 (rename by an old chain id).
2. **Two tool calls in one turn race on the same file** (agno runs them in parallel). Expected: the write lock serialises them, and the second sees the first's boards. A placed duplicate never overlaps a board that just landed. Pinned in Task 8 (duplicate twice → distinct centers).
3. **Undo after the user renamed or moved an agent-added board.** Expected: the board is kept and reported `changed_after_run`. Pinned in Task 9.
4. **A collab CAS race mid-write** (`board_changed`). Expected: one re-read and retry, then a per-board skip `board_changed`, never a 500. Pinned in Task 6.
5. **Hiding every visible board.** Expected: the last visible board is skipped with `last_visible_board`, so the canvas never goes empty by agent action. Pinned in Task 6.

---

### Task 1: Flag `kv-agentic-canvas-structure` (TASK-1)

**Files:**
- Create: `app/Support/Studio/KvAgentCanvasStructureFlag.php`
- Modify: `config/studio.php` (after `kv_agent_intent_mode`)
- Test: `tests/Feature/Studio/AgentCanvas/KvAgentCanvasStructureFlagTest.php`

**Interfaces:**
- Produces: `KvAgentCanvasStructureFlag::KEY = 'kv-agentic-canvas-structure'`, `KvAgentCanvasStructureFlag::enabledFor(User $user, string $workspaceId): bool`.

- [ ] **Step 1: Write the failing tests.** The pattern is `KvAgentCanvasIntentFlagTest`. Each test sets the environment with `app()->detectEnvironment(fn () => 'production')` where needed and binds a `FeatureFlagService` mock.
  - `it('is off when the parent kv-agentic-canvas flag is off, whatever the structure flag says')`
  - `it('outside production follows config studio.kv_agent_structure_flag, default false')`: unset config → false, `true` → true.
  - `it('in production asks PostHog for kv-agentic-canvas-structure with default false')`: the mock expects `isEnabledForWorkspace('kv-agentic-canvas-structure', $user, $ws, default: false)`.
  - `it('is off when PostHog throws')`: the mock throws, so the result is false (fail-closed).
- [ ] **Step 2: Run them and confirm they fail** (class not found): `scratchpad/t.sh tests/Feature/Studio/AgentCanvas/KvAgentCanvasStructureFlagTest.php`.
- [ ] **Step 3: Implement.** Order: parent flag → environment branch → try/catch around the PostHog read (`\Throwable` → false). Config: `'kv_agent_structure_flag' => (bool) env('KV_AGENT_STRUCTURE_FLAG', false)`, with a comment like the intent one.
- [ ] **Step 4: Run and confirm they pass.**
- [ ] **Step 5: Commit** `feat(api): KV agentic canvas P1 — kv-agentic-canvas-structure flag`.

### Task 2: Capability registry + schema validator (TASK-2)

**Files:**
- Create: `app/Services/Studio/AgentCanvas/Capabilities/KvCanvasCapability.php` (interface, exactly S4)
- Create: `app/Services/Studio/AgentCanvas/Capabilities/KvCanvasCapabilityRegistry.php`
- Create: `app/Services/Studio/AgentCanvas/Capabilities/KvCapabilityParams.php` (validator over the `toolSchema()` subset)
- Modify: `app/Providers/AppServiceProvider.php` (`singleton(KvCanvasCapabilityRegistry::class)`; capabilities are registered in later tasks via `afterResolving` or in the closure)
- Test: `tests/Unit/Studio/AgentCanvas/KvCanvasCapabilityRegistryTest.php`, `tests/Unit/Studio/AgentCanvas/KvCapabilityParamsTest.php`

**Interfaces:**
- Produces:
  - `interface KvCanvasCapability` with exactly `name(): string`, `cost(): string`, `estimate(array $params, KvCanvasState $state): array`, `execute(array $params, KvAgentRun $run, KvCanvasState $state): array`, `revert(array $op, KvAgentRun $run): array`, `cardKind(): ?string`, `toolSchema(): array`. Constants on the interface: `COST_FREE = 'free'`, `COST_PLAN = 'plan'`. PHPDoc for `revert`: returns `array{ops: list<array<string,mixed>>, only_if_unedited?: bool}` (deviation 2).
  - `KvCanvasCapabilityRegistry`: `register(KvCanvasCapability $c): void` (a duplicate name throws `LogicException`), `get(string $name): ?KvCanvasCapability`, `all(): array<string, KvCanvasCapability>` (in registration order), `byKind(string $cost): list<KvCanvasCapability>`, `names(string $cost): list<string>`.
  - `KvCapabilityParams::validate(array $schema, array $input): array`. It returns the input reduced to the schema's `properties` keys, with `default`s applied. It throws `KvCanvasToolException::unprocessable('invalid_input', <first error>)`. Supported keywords: `type` (object/array/string/integer/number/boolean), `required`, `properties`, `items`, `enum`, `minItems`/`maxItems`, `minLength`/`maxLength` (after `trim`), `minimum`/`maximum`, `default`. Error text: `"{path} …"`, e.g. `"count must be at most 4."`.

- [ ] **Step 1: Write the failing tests.**
  - Registry: `it('registers, gets, lists by cost and refuses a duplicate name')`, using two anonymous capabilities (one free, one plan): `names('free') === ['fake_free']`, `get('nope') === null`, and a second `register` of `fake_free` throws.
  - Params: `it('applies defaults and drops keys the schema does not name')`. With schema `{board_id: string required, count: integer 1..4, copy_layers: boolean default true}` and input `['board_id' => 'g1', 'count' => 2, 'user_id' => 'x']`, the result is `['board_id' => 'g1', 'count' => 2, 'copy_layers' => true]`.
  - Params: `it('refuses the first violation as 422 invalid_input', …)->with([...])`. Cases: missing required, `count: 5` (maximum), `count: "2"` (type integer; numeric strings are refused), `layout: "circle"` (enum), `board_ids: []` (minItems 1), an item of the wrong type, `name: "   "` (minLength 1 after trim). Each asserts `$e->status === 422 && $e->errorCode === 'invalid_input'`.
- [ ] **Step 2: Run and confirm failure.** `scratchpad/t.sh tests/Unit/Studio/AgentCanvas/KvCanvasCapabilityRegistryTest.php tests/Unit/Studio/AgentCanvas/KvCapabilityParamsTest.php`
- [ ] **Step 3: Implement** the interface, the registry, the validator and the singleton binding.
- [ ] **Step 4: Run and confirm pass.**
- [ ] **Step 5: Commit** `feat(api): KV agentic canvas P1 — capability registry`.

### Task 3: Run caps per op class (TASK-3)

**Files:**
- Modify: `app/Models/KvAgentRun.php` (constants), `app/Services/Studio/AgentCanvas/KvAgentRunRecorder.php`
- Test: `tests/Feature/Studio/AgentCanvas/KvAgentRunRecorderTest.php` (extend)

**Interfaces:**
- Produces: `KvAgentRun::MAX_BOARD_OPS = 20`, `MAX_RENDER_JOBS = 4`, `MAX_RESIZE_JOBS = 20`. `KvAgentRunRecorder::CLASS_LAYER|CLASS_BOARD|CLASS_RENDER|CLASS_RESIZE` (`'layer'|'board'|'render'|'resize'`). `KvAgentRunRecorder::BOARD_OP_TYPES = ['add_board','rename_board','move_board','hide_board','unhide_board','rekey_board_tip']`. `static opClass(array $op): string`. `remainingFor(KvAgentRun $run, string $class): int`. `remainingOps($run)` becomes `remainingFor($run, CLASS_LAYER)`.

- [ ] **Step 1: Write the failing tests.**
  - `it('classifies ops: board kinds on doc are board, job render/resize are render/resize, everything else is layer')`. Cases: `set_layer/doc → layer`, `detach_size/tile → layer`, `add_board/doc → board`, `render/job → render`, `resize/job → resize`.
  - `it('counts each cap only against its own class')`. Seed a run's `ops` with 199 layer ops + 20 board ops + 4 render ops. Then `remainingFor(layer) === 1`, `remainingFor(board) === 0`, `remainingFor(render) === 0`, `remainingFor(resize) === 20`, and `remainingOps()` stays 1, which proves board ops do not eat the P0 layer budget.
- [ ] **Step 2: Run and confirm failure.**
- [ ] **Step 3: Implement.** Count over `$run->fresh()?->ops`, as `remainingOps` does today.
- [ ] **Step 4: Run** the recorder test + `KvCanvasEditServiceTest.php` (P0 cap behaviour unchanged).
- [ ] **Step 5: Commit** `feat(api): KV agentic canvas P1 — run caps per op class`.

### Task 4: `KvCollabWriter` board ops (TASK-5)

**Files:**
- Create: `app/Exceptions/Studio/KvBoardChangedException.php` (`public readonly string $boardId, public readonly string $errorCode = 'board_changed'`; also used for `board_exists`), `app/Exceptions/Studio/KvBoardNotFoundException.php` (`public readonly string $boardId`)
- Modify: `app/Services/Studio/AgentCanvas/KvCollabWriter.php`
- Modify: `tests/Support/FakeKvCollab.php` (apply S1 board kinds with S1 semantics + `before.boards` / `before.removed`; helpers `board(string $id): ?array`, `editBoard(string $id, callable)`, `isHidden(string $id): bool`)
- Test: `tests/Feature/Studio/AgentCanvas/KvCollabWriterTest.php` (extend)

**Interfaces:**
- Produces:
  - Static op builders, used by the capabilities to mix kinds in one batch: `KvCollabWriter::addBoardOp(string $boardId, float $x, float $y, ?string $name, list<string> $versionIds, ?string $agentRunId): array`, `renameBoardOp(string $boardId, string $name, ?array $expected = null)`, `moveBoardOp(string $boardId, float $x, float $y, ?array $expected = null)`, `hideBoardOp(string $boardId)`, `unhideBoardOp(string $boardId)`, `rekeyBoardTipOp(string $from, string $to)`. Each returns `['kind' => …] + payload`. `expected` is omitted when null.
  - Methods (S7), each one op through `applyOps`: `addBoard(StudioFile $file, ?string $runId, string $boardId, float $x, float $y, ?string $name, array $versionIds)`, `renameBoard(StudioFile $file, ?string $runId, string $boardId, string $name, ?array $expected = null)`, `moveBoard(StudioFile $file, ?string $runId, string $boardId, float $x, float $y, ?array $expected = null)`, `hideBoard(StudioFile $file, ?string $runId, string $boardId)`, `unhideBoard(…)`, `rekeyBoardTip(StudioFile $file, ?string $runId, string $from, string $to)`. `addBoard` stamps `agent_run_id = $runId`.
  - `applyOps` result gains `before_boards: array<string, ?array>` (from `before.boards`) and `before_removed: ?list<string>` (from `before.removed`). `before` (layers) is unchanged.
  - Error mapping: 409 `board_changed`|`board_exists` → `KvBoardChangedException`; 404 `board_not_found` → `KvBoardNotFoundException`.

- [ ] **Step 1: Write the failing tests.**
  - `it('builds each S1 board op exactly', …)->with(...)`: one case per method, asserting the posted body `ops[0]` equals the S1 payload, e.g. `['kind' => 'add_board', 'board_id' => 'gen_new', 'x' => 640.0, 'y' => 0.0, 'name' => 'Ramadan', 'version_ids' => ['gen_new'], 'agent_run_id' => $run]` and `['kind' => 'rename_board', 'board_id' => 'g1', 'name' => 'B', 'expected' => ['name' => 'A']]`.
  - `it('returns board pre-images')`: the response `before: {boards: {g1: {name: 'A', x: 0, y: 0, versionIds: ['g1']}}, removed: []}` → `before_boards`, `before_removed`.
  - Extend the refusal dataset: `board_changed 409`, `board_exists 409` → `KvBoardChangedException`; `board_not_found 404` → `KvBoardNotFoundException`; the existing "route not deployed" bare 404 still → `KvCollabUnavailableException`.
  - `it('the fake applies board ops with collab semantics')`: add then rename with a stale `expected` → 409 `board_changed`; hide twice → `removed` holds the id once; unhide an absent key → 404.
- [ ] **Step 2: Run and confirm failure.**
- [ ] **Step 3: Implement** the builders, methods, mapping and fake.
- [ ] **Step 4: Run** `KvCollabWriterTest.php` + `KvCanvasEditServiceTest.php` (the fake still serves layer ops).
- [ ] **Step 5: Commit** `feat(api): KV agentic canvas P1 — collab writer board ops`.

### Task 5: Ledger board / job sinks (TASK-6)

**Files:**
- Modify: `app/Services/Studio/AgentCanvas/KvAgentRunRecorder.php`, `app/Models/KvAgentRun.php` (doc comment: sinks `doc|tile|job`, board op types), `app/Services/Studio/AgentCanvas/KvAgentRunView.php`
- Test: `tests/Feature/Studio/AgentCanvas/KvAgentRunRecorderTest.php`, `tests/Feature/Studio/AgentCanvas/KvAgentRunModelTest.php` (extend)

**Interfaces:**
- Produces:
  - `KvAgentRunRecorder::boardOp(string $type, string $boardId, string $label, ?array $before, ?array $after, string $capability): array`. It is static and returns the ledger row (without `at`). An unknown `$type` → `InvalidArgumentException`.
  - `KvAgentRunRecorder::jobOp(string $type, string $jobId, string $boardId, string $label, string $capability): array` (`type` ∈ `render|resize`; row `{type, sink: job, capability, job_id, target: board_id, target_kind: board, board_id, target_label, layer_id: null, before: null, after: null}`).
  - `recordBoardOp(KvAgentRun $run, array $row): void` and `recordJobOp(KvAgentRun $run, array $row): void` append through `record()`.
  - `KvAgentRunView::of()` gains the additive key `boards: list<{op, board_id, name, source_board_id: ?string}>` (board ops in ledger order). Board and job ops are excluded from `applied` / `headline` / `summary()`, so layer runs render exactly as before.

- [ ] **Step 1: Write the failing tests.**
  - `it('ledgers a board op and a job op beside layer ops, in order')`: after `recordBoardOp` + `recordJobOp`, `$run->ops[0]` has `sink: doc, type: add_board, capability: duplicate_kv_board, target_kind: board, layer_id: null, at` set, and `$run->ops[1]` has `sink: job, type: render, job_id`.
  - `it('refuses an unknown board op type')`.
  - Run view: `it('lists board ops under boards and keeps them out of applied and the headline')`: a run with one `add_board` + one `add_layer` on the new board → `boards === [['op' => 'add_board', 'board_id' => 'gen_new', 'name' => 'Ramadan', 'source_board_id' => $boardA]]`, `applied` has the one layer op, and `headline.change === 'added'`.
- [ ] **Step 2: Run and confirm failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the recorder, model and `KvAgentRunRoutesTest.php` tests (run view unchanged for P0 runs).
- [ ] **Step 5: Commit** `feat(api): KV agentic canvas P1 — ledger board and job sinks`.

### Task 6: Runner, free structure routes + MCP twins, rename / arrange / hide (TASK-8)

**Files:**
- Create: `app/Services/Studio/AgentCanvas/KvCanvasStructureService.php` (the runner)
- Create: `app/Services/Studio/AgentCanvas/Capabilities/KvBoardCapability.php` (abstract base: board lookup + one-retry batch helper + free `estimate`/`cardKind`)
- Create: `app/Services/Studio/AgentCanvas/Capabilities/RenameKvBoard.php`, `ArrangeKvBoards.php`, `HideKvBoards.php`
- Create: `app/Http/Controllers/Api/ModelContextProtocol/KvCanvasStructureToolController.php` (extends `KvCanvasToolController`)
- Create: `app/Mcp/Tools/RenameKvBoardTool.php`, `ArrangeKvBoardsTool.php`, `HideKvBoardsTool.php`, `DuplicateKvBoardTool.php` (the duplicate twin + route land here; its capability lands in Task 8, and until then the route answers 404 `unknown_capability`)
- Modify: `app/Services/Studio/AgentCanvas/KvCanvasState.php` + `KvCanvasContextAssembler::load` (boards carry `x`, `y`, `version_ids`; new `hiddenBoards` list, same shape; constructor param defaults to `[]`), `KvCanvasToolController::withFile` (an overridable `protected function flagEnabled(ToolContext $ctx): bool`), `routes/api.php`, `app/Mcp/Servers/FrndosServer.php`, `AppServiceProvider` (register the three capabilities)
- Test: `tests/Feature/Studio/AgentCanvas/KvBoardStructureToolsTest.php`, `tests/Unit/Mcp/KvCanvasToolsTest.php` (extend)

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces:
  - `KvCanvasStructureService::run(StudioFile $file, ToolContext $ctx, ?string $runId, string $capability, array $params): array`. Unknown name → `KvCanvasToolException` 404 `unknown_capability`. `cost() !== 'free'` → 422 `plan_required`. Params go through `KvCapabilityParams::validate($cap->toolSchema(), $params)` before any lock. Then `KvCanvasWriteLock::run` → `assembler->load` → `recorder->ensureRun` → `$cap->execute($params, $run, $state)`, merged under `['run_id' => $run->id]`.
  - Write result (all four tools): `{run_id, applied: list<{target: board_id, op, board_id, name?}>, skipped: list<{target, layer_id: null, reason, detail?}>, detached_sizes: []}`, + `boards` for duplicate.
  - `KvBoardCapability::applyBatch(KvAgentRun $run, KvCanvasState $state, Closure(KvCanvasState): array{ops: list<array>, ledger: list<array>, applied: list<array>, skipped: list<array>} $plan): array{applied, skipped}`. It plans, `applyOps`, and on `KvBoardChangedException|KvBoardNotFoundException|KvLayerChangedException` reloads once and re-plans. The second failure → each planned target is skipped `board_changed`. `KvCollabUnavailableException` → skip `collab_unavailable`. `KvCollabRejectedException` → skip `invalid_payload` + detail. It ledgers through `recorder->record` only after `applyOps` succeeds. It also skips the planned ops over `remainingFor(board)` (and `remainingFor(layer)` for layer rows) with `run_op_cap_reached`.
  - `rename_kv_board` schema `{board_id: string required, name: string required minLength 1 maxLength 80}`. Op: `rename_board {board_id: tip key, name: trim(name), expected: {name: current or null}}`. Ledger before/after `{name}`. Board not found → skip `target_not_found`.
  - `arrange_kv_boards` schema `{layout: enum [grid,row] required}`. Algorithm (api-owned, deterministic, from `KvBoardPlacement::ARTBOARD_STEP = 640`, `BOARD_WORLD_WIDTH = 512`; the Task 7 constants live there, so in this task they are private consts on `ArrangeKvBoards`, swapped in Task 7): the origin is the first visible board's center (doc order). `row`: board *i* at `(origin.x + i·640, origin.y)`. `grid`: `cols = ceil(sqrt(n))`, column *c* at `origin.x + c·640`. Row *r*'s y advances by `prevRowMaxH/2 + 128 + rowMaxH/2`, where a board's world height is `512 / aspect` (aspect = width/height from `boardDims`, else 1). One `move_board {x, y, expected: {x, y}}` per board whose center changes. Ledger before/after `{x, y}`.
  - `hide_kv_boards` schema `{board_ids: array of string minItems 1 maxItems 30 required, hidden: boolean required}`. `hidden: true`: visible board → `hide_board`; already hidden → skip `already_hidden`; the last visible board → skip `last_visible_board`. `hidden: false`: hidden board → `unhide_board`; visible → skip `already_visible`. Unknown → `target_not_found`. Ledger op `hide_board`/`unhide_board`, before/after `{hidden: bool}`.
  - Every capability's `toolSchema()` is the same JSON Schema its MCP twin advertises (minus `workspace_id`, `file_id`, `agent_run_id`).
  - Routes, inside a `feature.flag:kv-agentic-canvas-structure,off` group nested in the existing `kv-agentic-canvas` group: `boards/duplicate → duplicateBoards`, `boards/rename → renameBoard`, `boards/arrange → arrangeBoards`, `boards/hide → hideBoards`. Each method is `return $this->withFile($request, $fileId, fn ($file, $ctx) => $structure->run($file, $ctx, $this->runIdFrom($request, $ctx), <NAME>, $request->all()), KvCanvasFileAccess::WRITE);`. `flagEnabled` = parent && `KvAgentCanvasStructureFlag::enabledFor`.
  - Twins: `requiresSubscription = true`, `routeParamMap = ['file_id' => 'fileId']`, names as above. Descriptions follow FR-8/FR-9 (free, undoable, hiding never deletes).

- [ ] **Step 1: Write the failing tests** (Feature, `BuildsKvCanvas` + `config(['studio.kv_agent_structure_flag' => true])`; fake extended in Task 4).
  - `it('renames a board by an old chain id, ledgered and undoable data')`: POST `boards/rename {board_id: K::OLD_A, name: ' Lebaran '}` → 200, `fake->board($boardA)['name'] === 'Lebaran'`, the batch op has `expected: {name: 'Concept A'}`, and the run's ops[0] has `type: rename_board`, `capability: rename_kv_board`, `before: {name: 'Concept A'}`, `after: {name: 'Lebaran'}`.
  - `it('retries once on board_changed, then skips the board')`: `fake->refusals = [[409, board_changed], [409, board_changed]]` → 200 with `skipped[0].reason === 'board_changed'` and no ledger op.
  - `it('arranges boards in a row and a grid, deterministically')`: three boards (add a C at (5000, 900) to the doc) → `row`: centers `(0,0)`, `(640,0)`, `(1280,0)`. A second call with the same layout writes nothing (`applied === []`, no `/ops`). Grid with 4 boards (A 1080×1350 → world h 640, B 1080×1080 → h 512, C and D 1080×1920 → h 910.2̅) → `cols = 2`. Row 1 is A at (0, 0) and B at (640, 0). Row 2 is C at (0, 320 + 128 + 455.1̅) and D at (640, same y). Assert to 1e-6.
  - `it('hides and unhides boards, never the last visible one')`: hide `[B]` → `removed === [B]`, ledger `hide_board`. Hide `[A]` (last visible) → skip `last_visible_board`. Unhide `[B]` → removed empty, ledger `unhide_board`. Unhide `[A]` → skip `already_visible`.
  - `it('skips board ops past the per-run board cap')`: seed the run with 20 board ops → rename skipped `run_op_cap_reached`, no `/ops`.
  - `it('404s every structure route while kv-agentic-canvas-structure is off')`: config false → each of the 4 routes → 404, and no `/ops` sent.
  - `it('refuses invalid input as 422 invalid_input before opening a run')`: `arrange {layout: 'circle'}` → 422, `KvAgentRun::count() === 0`.
  - `it('refuses a plan capability through the free runner')`: a fake `cost() = 'plan'` capability registered in the test → `run()` throws 422 `plan_required`.
  - Unit `KvCanvasToolsTest`: `it('registers the four structure twins on KvCanvasStructureToolController', …)->with([...])` (name, METHOD, required = `['workspace_id','file_id', …schema required]`); `it('puts the structure routes behind both fail-closed flags')` (`gatherMiddleware()` contains both); the existing `mcp:verify-mirror` test stays green.
- [ ] **Step 2: Run and confirm failure.** `scratchpad/t.sh tests/Feature/Studio/AgentCanvas/KvBoardStructureToolsTest.php tests/Unit/Mcp/KvCanvasToolsTest.php`
- [ ] **Step 3: Implement** in this order: state/assembler fields, writer → base → runner → the three capabilities → controller → routes → twins → provider registration.
- [ ] **Step 4: Run** the new tests + all of `tests/Feature/Studio/AgentCanvas tests/Unit/Studio/AgentCanvas tests/Unit/Mcp/KvCanvasToolsTest.php` (regression against the baseline), and `php -d memory_limit=1G artisan mcp:verify-mirror` → exit 0.
- [ ] **Step 5: Commit** `feat(api): KV agentic canvas P1 — free structure tool routes + MCP twins`.

### Task 7: Board placement ports (TASK-4) — after the web fixtures land

**Gate:** check `web/.worktrees/kv-agentic-canvas-p1` for committed `fixtures/board-placement/*.json`. If they are not there, message the lead and do Task 10 first. If they are still missing after Task 10, implement the ports against hand-built cases transcribed from the TS source, commit the parity test as soon as the fixtures exist, and report the parity status as pending.

**Files:**
- Create: `app/Support/Studio/KvBoardPlacement.php`, `app/Support/Studio/KvVariantOverlays.php`, `app/Support/Studio/KvEditOutcome.php`
- Create: `tests/Fixtures/kv-board-placement/*.json` (copied verbatim from web, with a `README` line naming the web commit)
- Modify: `ArrangeKvBoards` (use `KvBoardPlacement::ARTBOARD_STEP` / `BOARD_WORLD_WIDTH`)
- Test: `tests/Unit/Studio/AgentCanvas/KvBoardPlacementTest.php` (fixture-driven: placement, `deriveVariantName`, `overlaysForVariant`, `editOutcome`) + `tests/Unit/Studio/AgentCanvas/KvEditOutcomeTest.php` (`boardEditedSince`, api-only)

**Interfaces:**
- Produces:
  - `KvBoardPlacement::ARTBOARD_STEP = 640`, `BOARD_WORLD_WIDTH = 512`. `nextFreeCenter(list<array{x: float, y: float}> $centers): array{x: float, y: float}`. `adjacentFreeCenter(list<array{x,y}> $centers, array{x,y} $parent): array{x,y}`. `nextFreeCenters(list<array{x,y}> $centers, int $n): list<array{x,y}>`. These are exact ports: the occupancy test is `|dx| < STEP/2 && |dy| < STEP/2`, the loop runs `i = 1..count+1`, and the fallback is `nextFreeCenter`; `reduce` keeps the first max x on ties.
  - `KvVariantOverlays::overlaysForVariant(list<array> $rows, list<string> $parentChain, string $variantId, Closure(): string $mintId): list<array>`. Exact port: keep the rows bound into the chain, stable-sort by `z`, map to `{id: mint(), type, x, y, width, height, rotation, board_generation_id: variantId, payload: deep copy}` with no `z`. Rows are the flat `KvLayerShape::toRow` shape.
  - `KvEditOutcome::REKEY|FORK|VARIANT`. `resolve(bool $parentIsConcept, int $parentResizeCount, ?bool $variantRedirectEnabled = null): string`. `boardEditedSince(array $added, ?array $live, int $layersLeftAfterUndo, int $resizeCount): bool`. `$added` and `$live` are `{key, name, x, y}`; `$live === null` means the key is gone (rekeyed or absent), which counts as edited. Edited ⇔ live null ∨ key ≠ added key ∨ name ≠ ∨ x/y ≠ (±1e-6) ∨ `layersLeftAfterUndo > 0` ∨ `resolve(false, $resizeCount) === VARIANT`.

- [ ] **Step 1: Write the failing tests.** Read every case in the fixtures and compare exactly (centers to 1e-9, names `toBe`, overlays `toEqual` with the minted id sequence the fixture recorded). Add the guard `it('the placement fixtures move boards, so parity is not vacuous')` (at least one expected center ≠ the parent center). In `KvEditOutcomeTest`, one dataset row per edited condition, plus the unedited case → false.
- [ ] **Step 2: Run and confirm failure.**
- [ ] **Step 3: Implement** the three classes. Swap in the `ArrangeKvBoards` constants.
- [ ] **Step 4: Run** the new tests + `KvBoardStructureToolsTest.php`.
- [ ] **Step 5: Commit** `feat(api): KV agentic canvas P1 — board placement ports pinned by TS fixtures`.

### Task 8: `duplicate_kv_board` (TASK-9)

**Files:**
- Create: `app/Services/Studio/KvGenerationDuplicator.php` (the body of `KvGeneratorFileController::duplicateGeneration`'s transaction)
- Create: `app/Services/Studio/AgentCanvas/Capabilities/DuplicateKvBoard.php`
- Modify: `KvGeneratorFileController::duplicateGeneration` (calls the duplicator, same response), `AppServiceProvider` (register)
- Test: `tests/Feature/Studio/AgentCanvas/KvDuplicateBoardToolTest.php`, plus the existing duplicate-generation REST test (find it with `grep -rln duplicateGeneration tests` and run it unchanged)

**Interfaces:**
- Consumes: Task 7 `KvBoardPlacement::adjacentFreeCenter`, `KvVariantOverlays::overlaysForVariant`. Task 6 `KvBoardCapability::applyBatch`.
- Produces:
  - `KvGenerationDuplicator::duplicate(StudioFile $file, KvGeneration $source, User $by, ?string $mode = null, array $metadata = []): KvGeneration`. Under the file row lock: next `version_number`, `parent_generation_id = source`, metadata `source->metadata + $metadata`, and the file `last_edited_*` set.
  - `duplicate_kv_board` schema `{board_id: string required, count: integer 1..4 default 1, names: array of string (maxLength 80) maxItems 4, copy_layers: boolean default true}`.
  - Execute: resolve the source (missing → skip `target_not_found`, nothing created). `n = min(count, remainingFor(board))`; the rest are skipped `run_op_cap_reached`. For copy *i*: duplicate the generation (metadata `{agent_run_id, source_board_id}`). The center is `adjacentFreeCenter(all visible + hidden + already-placed centers, source)`. The name is `trim(names[i])` if given, else `"{sourceLabel} copy"` for i = 0 and `"{sourceLabel} copy {i+1}"` after, cut to 32 characters with `…` like `KvBoardLabel`. Op `add_board {board_id: gen.id, x, y, name, version_ids: [gen.id], agent_run_id: run}`. With `copy_layers`, `overlaysForVariant(state->layers, source chain, gen.id, ULID)` gets z = `maxZ + 1 + k` and is sent as `add_layer` ops, subject to `remainingFor(layer)` and `StudioOverlayNormalizer::MAX_OVERLAYS` (over the limit → that copy's layers are skipped `too_many_layers`, and the board still lands). Everything goes in one collab batch.
  - Ledger: `add_board` board op (`after {x, y, name, version_ids, source_board_id}`) + one `add_layer` doc op per copied layer (target = the new board, `target_kind: board`, `board_id`, `target_label` = the new name, before null, after row).
  - Result: `boards: list<{board_id, name, source_board_id, x, y, layers: int}>`, plus `applied` / `skipped`.

- [ ] **Step 1: Write the failing tests.**
  - `it('duplicates a board twice next to its source, named, with copied layers')`: `{board_id: A, count: 2, names: ['Ramadan', 'Lebaran']}` → two new `KvGeneration` rows (`parent_generation_id = A`, version 3 and 4, metadata `agent_run_id`). B sits at (1200, 0). The slot (640, 0) is free (`|1200 − 640| = 560 ≥ 320`), so the first copy goes there. The slot (1280, 0) is occupied by B (`|1280 − 1200| = 80 < 320`), so the second copy goes to (1920, 0). Assert those exact centers. Names are `Ramadan` / `Lebaran`. Each new board has 2 layers (HEADLINE + LOGO copies, fresh ids, bound to the new id, z after maxZ). B's layer is not copied. There is exactly ONE `/ops` request, and the run's ledger holds 2 `add_board` + 4 `add_layer`.
  - `it('copies no layers when copy_layers is false and derives names when none are given')` → `"Concept A copy"`, `"Concept A copy 2"`.
  - `it('places a second duplicate call next to the first call\'s boards')`: two sequential calls, and the centers are all distinct.
  - `it('makes no generation and no write for an unknown board')`: skip `target_not_found`, `KvGeneration::count()` unchanged, 0 `/ops`.
  - `it('skips copies past the board cap')`: seed 19 board ops; `count: 3` → 1 board, 2 skipped `run_op_cap_reached`.
  - `it('keeps the REST duplicate endpoint answering as before')`: run the existing test file.
- [ ] **Step 2: Run and confirm failure.**
- [ ] **Step 3: Implement** the duplicator (refactor the controller onto it first and run its test), then the capability and its registration.
- [ ] **Step 4: Run** the new + REST + structure tests.
- [ ] **Step 5: Commit** `feat(api): KV agentic canvas P1 — duplicate_kv_board`.

### Task 9: Structural undo for board ops (TASK-7)

**Files:**
- Modify: `app/Services/Studio/AgentCanvas/KvAgentRunReverter.php`. In `revertDoc`, layer ops are processed as today. Board ops then go through the registry and an in-memory S1 interpreter, coalesced into the same collab batch.
- Modify: `RenameKvBoard`, `ArrangeKvBoards`, `HideKvBoards`, `DuplicateKvBoard` → `revert()`
- Test: `tests/Feature/Studio/AgentCanvas/UndoKvBoardOpsTest.php`, `tests/Feature/Studio/AgentCanvas/KvCapabilityRegistryContractTest.php` (AC-13)

**Interfaces:**
- Consumes: `KvEditOutcome::boardEditedSince` (Task 7), the registry (Task 2), board exceptions (Task 4).
- Produces:
  - `revert()` per capability: rename → `[renameBoardOp(board, before.name ?? '', expected: {name: after.name})]`. move → `[moveBoardOp(board, before.x, before.y, expected: after)]`. hide → `[unhideBoardOp]`. unhide → `[hideBoardOp]`. add_board → `['ops' => [hideBoardOp(board)], 'only_if_unedited' => true]`.
  - The reverter's board pass: work on `$boards` (live `boards` + `removed`), newest board op first. If `capability` is missing or unknown → skip `not_undoable`. Each inverse op is checked against the working copy with S1 rules: a key that is gone → `board_not_found`; an `expected` mismatch → `changed_after_run`. For `only_if_unedited`, it calls `boardEditedSince($op.after + key, working board, layers still bound to the board's chain in the post-layer-undo `$work`, live resize count of tiles whose `parent_generation_id` is in the chain)`; edited → `changed_after_run`. Applied ops mutate the working copy. Coalesced batch ops come after the layer ops: per board, `rename_board` (expected = live name) if the name changed, `move_board` (expected = live x/y) if moved, `hide_board`/`unhide_board` if visibility flipped. `KvBoardChangedException|KvBoardNotFoundException` → re-read and re-decide (same `DOC_ATTEMPTS` loop). Skips are `{target: board_id, layer_id: null, reason}`.
  - Order guarantee: a duplicated board whose copied layer the user edited keeps that layer (layer pass: `changed_after_run`), so `layersLeftAfterUndo > 0` keeps the board too.

- [ ] **Step 1: Write the failing tests.**
  - `it('undoes a duplicate: removes the copied layers and hides the boards, deleting nothing')`: duplicate → undo via `POST v1/studio/files/{file}/agent/runs/{run}/undo` (or the reverter) → the copied layers are gone, both new ids are in `removed`, the `KvGeneration` rows still exist, and status is `undone`.
  - `it('keeps a duplicated board the user changed', …)->with(['renamed', 'moved', 'edited a copied layer', 'resized'])` → board not hidden, skip `{target: id, reason: changed_after_run}`.
  - `it('restores a rename and a move by CAS, and skips them if the user changed the board since')`.
  - `it('coalesces two renames of one board in one run into one restoring op')`: rename A→X then X→Y in the same run → undo sends one `rename_board {name: 'Concept A', expected: {name: 'Y'}}`.
  - `it('reverses hide with unhide and unhide with hide')`.
  - `it('re-reads and re-decides when collab answers board_changed')`: `refusals = [[409, board_changed]]`, and the user renamed between the reads → `changed_after_run`, and the rest reverted.
  - AC-13 `KvCapabilityRegistryContractTest`: `it('runs and undoes a throwaway capability with no change to the runner, validator, ledger or reverter')`. An anonymous `KvCanvasCapability` named `recolor_kv_board_fake` is registered in the test. Its `toolSchema` is `{board_id: string required, name: string required}`, `execute` writes `rename_board` through `KvBoardCapability::applyBatch`, and `revert` returns the inverse rename. Run it via `KvCanvasStructureService::run`, then `KvAgentRunReverter::undo` → the name is restored. Bad params → 422 from the generic validator.
- [ ] **Step 2: Run and confirm failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the new tests + `UndoKvAgentRunTest.php` + `KvAgentRunFastUndoTest.php` + `KvAgentRunRoutesTest.php` (P0 undo unchanged).
- [ ] **Step 5: Commit** `feat(api): KV agentic canvas P1 — structural undo for board ops`.

### Task 10: Chat-turn structure tool mounting (TASK-10)

**Files:**
- Modify: `app/Services/Studio/AgentCanvas/KvAgentCanvasTurn.php` (inject `KvCanvasCapabilityRegistry`)
- Test: `tests/Feature/Studio/AgentCanvas/KvAgentCanvasTurnTest.php` (extend), `tests/Feature/Studio/AgentCanvas/KvAgentCanvasStreamTest.php` (extend: the payload to ai-service)

**Interfaces:**
- Produces: when `KvAgentCanvasStructureFlag::enabledFor` is on, `canvas.tools = $registry->names('free')` (registration order: `duplicate_kv_board, rename_kv_board, arrange_kv_boards, hide_kv_boards`). When it is off, there is no `tools` key at all. ai-service reads `agent_canvas.tools` (its TASK-1).

- [ ] **Step 1: Write the failing tests.**
  - `it('lists the free structure tools on the turn when the structure flag is on')` → `$turn['canvas']['tools'] === ['duplicate_kv_board', 'rename_kv_board', 'arrange_kv_boards', 'hide_kv_boards']`.
  - `it('sends no tools key when the structure flag is off')` → `array_key_exists('tools', $turn['canvas']) === false`.
  - Stream: the ai-service request body's `agent_canvas.tools` matches, on and off.
- [ ] **Step 2: Run and confirm failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the turn + stream tests.
- [ ] **Step 5: Commit** `feat(api): KV agentic canvas P1 — mount structure tools on the chat turn`.

### Task 11: Track + review

- [ ] Tick TASK-1..10 in `docs/tracks/kv-agentic-canvas-p1.track.md`. Set Implementation to `in_progress` (Round A done, Round B pending). Append the session log `### 2026-10-22 — daffa (executing-plans, Round A api)` with the commits, tests run and DB, and deviations 1–5. Commit `docs(api): KV agentic canvas P1 — Round A track`.
- [ ] One `superpowers:requesting-code-review` pass over `b2367ef10..HEAD`. Fix the Critical and Important findings (one commit each, `fix(api): …`). Re-run the full AgentCanvas + Mcp test set and `mcp:verify-mirror`.
