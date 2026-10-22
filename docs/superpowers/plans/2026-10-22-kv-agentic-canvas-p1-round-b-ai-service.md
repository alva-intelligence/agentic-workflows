# KV Agentic Canvas P1 — Round B (ai-service) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The KV chat proposes paid structure work (N variant boards, new sizes) as a plan card, and on Go it starts the accepted steps through api in one call, streaming one progress frame per item.

**Architecture:** `propose_kv_variants` / `propose_kv_sizes` become real registry tools. They claim `plan_pending` on the turn gate before awaiting R1, and the agno wrapper (`stop_after_tool_call` plus a post_hook) ends the turn only when a plan was stored. The stream emits `kv_plan_card` after `message`. A plan `card_answer` turn (Go/Cancel) never reaches the model: a deterministic handler reads `agent_canvas.plan`, calls the recorded `run_kv_plan_step` once (an async generator that yields `agent_item_progress` CustomEvents), and replies "started", never "done". On the intent side, "duplicate + visual change" becomes a variant (R12), and a live plan decision hands off to the agent with the resolved arguments, because only the model writes the suggestions.

**Tech Stack:** Python 3.11, FastAPI, agno 2.8.7, pydantic v2, httpx + respx, pytest-asyncio.

**Spec:** `docs/superpowers/plans/2026-10-22-kv-agentic-canvas-p1-structure-contracts.md` (S12, S15, R1, R4–R6, R9 + amendment, R12); service PRD `ai-service/.worktrees/kv-agentic-canvas-p1/docs/prd/kv-agentic-canvas-p1.md` TASK-8..13.

Worktree: `ai-service/.worktrees/kv-agentic-canvas-p1` at HEAD 942c8284. Paths below are relative to it. Test prefix: `AGNO_TELEMETRY=false ../../.venv/bin/python -m pytest -p no:cacheprovider`. Full-suite baseline at 942c8284: **48 failed / 5730 passed / 8 skipped / 1 collection error** (`tests/repositories/test_brand_repository.py`); the failure list is saved in the session scratchpad.

## Global Constraints

- Flag off (no `agent_canvas`, or `tools` without the new names and no `plan`) → the P0 / intent / Round A turn is byte-identical.
- Tool names are frozen: `propose_kv_variants`, `propose_kv_sizes`, `run_kv_plan_step`. Capabilities: `variant_boards`, `add_sizes`.
- R1: `POST mcp/tools/kv/canvas/{fileId}/plans` `{capability, params, thread_id}` + `user_id, workspace_id, agent_run_id`. Limits: ≤4 variants, ≤3 suggestions per variant, ≤3 extra_directions, direction ≤500 chars, ≤20 sizes.
- R4: the NDJSON frame is `{event: "kv_plan_card", plan_id, card_id}`, and `card_id` is a ULID minted here.
- R6: `POST mcp/tools/kv/canvas/plans/steps/run` `{plan_step_ids}` (≤24), one call per turn, idempotent.
- R9 amendment: the progress event carries `item_id`, `item_kind` (`board`|`size`), `state`, `board_id`, `agent_run_id`; CustomEvent `kind = "agent_item_progress"`; `__str__` is `""`.
- Chip labels: "Proposing Variants", "Proposing Sizes", "Running Plan Step"; icon `key_visual`.
- `add_sizes` with no board named always asks (Round A rule unchanged).
- Install deps only from requirements.txt; never `uv sync`. Never `git stash`. One commit per task, `feat(ai): KV agentic canvas P1 Round B — …` + `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. A layer or board write gathered in the same completion as a proposal must refuse, never land before Go → Task 2 test `test_a_write_gathered_with_a_proposal_refuses`.
2. A refused proposal (422 from api, bad args) must let the model retry instead of ending the turn on an error → Task 2 `test_a_refused_proposal_releases_the_turn` + Task 4 `test_a_refused_proposal_does_not_end_the_turn`.
3. Go pressed twice (or the model calling the step tool twice) must not start renders twice → Task 3 `test_run_is_idempotent_within_the_turn`.
4. A Go on an expired, superseded or already-executed plan must start nothing and must say so → Task 5 parametrized `test_non_accepted_go_starts_nothing`.
5. A turn that proposed a plan must not get the empty-turn text retry, the concept-card synthesis or a "no change accepted" footnote → Task 4 `test_a_stored_plan_ends_the_turn_as_the_card`.

---

### Task 1: Turn plumbing — plan on the request, plan gate, tool context

**Files:**
- Modify: `app/agents/kv_generator/request_schema.py` (AgentCanvas), `app/agents/canvas_intent/schema.py` (CardAnswer), `app/agents/kv_generator/tools.py` (QuestionCardGate), `app/tools/kv_canvas_capability.py`
- Test: `tests/agents/kv_generator/test_agent_canvas_schema.py`, `tests/tools/test_kv_canvas_capability.py`

**Interfaces:**
- Produces: `AgentCanvasPlan(plan_id: str, status: str, accepted_steps: list[str] (None→[]), capability: str|None)`; `AgentCanvas.plan: AgentCanvasPlan | None = None`; `CardAnswer.purpose` gains `"plan"`.
- `PLAN_PENDING_ERROR: str` in `kv_canvas_capability`; `QuestionCardGate.plan_pending: bool`, `.stored_plan: dict | None` (`{plan_id, clamped?}`), and `turn_closed()` returns PLAN_PENDING_ERROR first.
- `KvTurnGate` Protocol (`plan_pending`, `stored_plan`, `turn_closed()`); `KvToolContext` gains `thread_id: str = ""`, `gate: KvTurnGate | None`, `plan_step_ids: tuple[str, ...] = ()`.
- `make_kv_structure_tools(..., gate=None, thread_id="", plan_step_ids=())`: with no gate, a private `_TurnGate` whose `turn_closed` also defers to `turn_closed`.
- `KV_STRUCTURE_TOOL_NAMES: frozenset[str]` = every registry name (built after the P1 entry imports).

- [ ] Step 1: tests: `AgentCanvas(plan={"plan_id": "p", "status": "accepted", "accepted_steps": None})` → `accepted_steps == []`; `CardAnswer(purpose="plan", …)` validates; `QuestionCardGate().turn_closed()` is None, and after `plan_pending = True` it equals `PLAN_PENDING_ERROR`.
- [ ] Step 2: run → FAIL. Step 3: implement. Step 4: run the two files + `tests/agents/kv_generator tests/agents/canvas_intent tests/tools/test_kv_*` → no new failures.
- [ ] Step 5: commit `… — plan on the turn, plan gate, tool context`.

### Task 2: `propose_kv_variants` / `propose_kv_sizes` (TASK-8, TASK-9)

**Files:**
- Modify: `app/tools/kv_plan_tools.py`
- Test: `tests/tools/test_kv_plan_tools.py` (new)

**Interfaces:**
- Consumes: Task 1 `KvToolContext.gate/thread_id`, `PLAN_PENDING_ERROR`.
- Produces: `make_variants_tool(ctx)`, `make_sizes_tool(ctx)` registered as the entries' `tool_fn`; `PLAN_PROPOSAL_TOOLS = frozenset({VARIANTS_TOOL, SIZES_TOOL})`; `plan_card_tool(fn, gate) -> agno Function` (`stop_after_tool_call=True, show_result=False, post_hook` sets `fc.function.stop_after_tool_call = bool(gate.plan_pending)`, `__name__` kept).
- `make_kv_structure_tools` mounts proposal tools through `_proposal_guard(fn, gate)` (`sleep(0)` → `gate.turn_closed()` → pydantic validation → the tool), NOT `record_tool`: a proposal is not a canvas write (no ledger attempt).
- Tool body: clamp `variants` to 4 (`clamped: {requested, max: 4}` on the result and in `gate.stored_plan`); claim `gate.plan_pending = True` immediately before `await ctx.post`; on `error`, release it; on success, set `gate.stored_plan = {"plan_id": result["id"], **clamped}`. A result with no `id` counts as a refusal.

- [ ] Step 1: tests (respx on `{API}/{FILE}/plans`):
  - `test_variants_posts_the_r1_body`: body == `{"capability": "variant_boards", "params": {"board_id": "gen_f", "variants": [...], "extra_directions": [...], "copy_layers": True}, "thread_id": "t1", **CTX}`; `gate.stored_plan == {"plan_id": "01JPLAN…"}`.
  - `test_sizes_posts_the_r1_body`: `{"capability": "add_sizes", "params": {"board_ids": [...], "sizes": ["Instagram Story", {"width": 1080, "height": 1080}]}, …}`.
  - `test_six_variants_clamp_to_four`: 4 variants sent; result and stored_plan carry `clamped == {"requested": 6, "max": 4}`.
  - `test_a_refused_proposal_releases_the_turn`: api 422 → `error` in result, `gate.plan_pending is False`, `stored_plan is None`.
  - `test_four_suggestions_are_refused_before_api`: `{error: "args refused: …"}`, no request.
  - `test_a_write_gathered_with_a_proposal_refuses`: `asyncio.gather(rename(...), propose(...))` → rename returns `{error: PLAN_PENDING_ERROR}`, no rename request.
  - `test_a_second_proposal_is_refused`, `test_a_pending_question_card_refuses_the_proposal`.
  - `test_plan_card_tool_stops_only_on_a_stored_plan`: post_hook flips `stop_after_tool_call` False when `plan_pending` is False.
- [ ] Step 2: FAIL → Step 3: implement → Step 4: PASS + Round A tool tests.
- [ ] Step 5: commit `… — propose_kv_variants and propose_kv_sizes`.

### Task 3: `run_kv_plan_step` + `agent_item_progress` (TASK-10, TASK-12)

**Files:**
- Create: `app/tools/kv_plan_events.py` (`KvAgentItemProgress`)
- Modify: `app/tools/kv_plan_tools.py`, `app/tools/kv_canvas_tools.py` (`record_tool` forwards async generators), `KvCanvasWriteLedger` (`plan_runs` cache)
- Test: `tests/tools/test_kv_plan_tools.py`, `tests/tools/test_kv_canvas_footnote.py`

**Interfaces:**
- `@dataclass(kw_only=True) class KvAgentItemProgress(CustomEvent)`: `kind = "agent_item_progress"`, `item_id`, `item_kind`, `state`, `board_id: str | None`, `agent_run_id`; `__str__ → ""`.
- `RUN_PLAN_STEP_TOOL = "run_kv_plan_step"`, registered with `cost="plan"` and no intent actions. Signature `run_kv_plan_step(action="", plan_step_ids: list[str] | None = None, **kw)`. It sends `ctx.plan_step_ids` (or, when ids are given, those that are accepted; with no bound set, the given ones) and returns either a dict (refusal or cached) or an async generator: one progress event per `applied` item (`state = item.state or "queued"`), then the result dict.
- `record_tool`: when the awaited result is an async generator, it returns a forwarding generator. That generator yields CustomEvents, calls `ledger.record_progress({"item_id", "state"})` for each progress event, records the final dict, and yields it.
- `KvCanvasWriteLedger.plan_runs: dict[tuple[str, ...], dict]`: the same id set in one turn returns the cached result, with no POST and no events.

- [ ] Step 1: tests:
  - `test_run_posts_every_accepted_step_once`: body `{"plan_step_ids": ["step_1", "step_2"], **CTX}` to `{API}/plans/steps/run`; events == two `KvAgentItemProgress(state="queued", item_kind="board")`; final dict last; `ledger.applied == 2`; `ledger.pending_items == ["step_1", "step_2"]`.
  - `test_run_is_idempotent_within_the_turn`: a second call → one request in total, the same result, no events.
  - `test_run_with_no_accepted_steps_refuses`; `test_run_api_error_is_recorded_not_raised`.
  - `test_progress_event_wire_shape`: `to_dict()` has `kind`, `item_id`, `item_kind`, `state`, `board_id`, `agent_run_id`; `str(e) == ""`.
  - footnote: a reply "Done! all 3 variants are ready" after queued progress → `KV_DISPATCHED_FOOTNOTE`.
- [ ] Step 2–4 TDD cycle. Step 5: commit `… — run_kv_plan_step and agent_item_progress`.

### Task 4: KV stream — the proposal turn (TASK-11, R4)

**Files:**
- Modify: `app/agents/kv_generator/service.py`, `app/agents/kv_generator/response_schema.py` (`KvPlanCardEvent`, `AgentItemProgressFrame`), `app/agents/kv_generator/canvas_context_prompt.py`, `app/utils/enum/tool_name_enum.py`, `app/utils/kv_canvas_tool_result.py`
- Test: `tests/agents/kv_generator/test_agent_canvas_plan_loop.py` (new, ScriptedModel)

**Interfaces:**
- `KvPlanCardEvent(event="kv_plan_card", plan_id, card_id=new_ulid())`.
- `_chat_mode_turn` passes `gate=canvas_gate, thread_id, plan_step_ids` to `make_kv_structure_tools`. `_agno_chat_stream` swaps proposal tools for `plan_card_tool(t, canvas_gate)` when it builds the agent's tool list.
- ToolCallCompleted of a proposal tool with `canvas_gate.stored_plan` set: completed chip (shaped `{plan_id, status, estimate}`), then `shim_tool_called = True` (post-tool prose dropped, no empty retry). With no prose before it, a lead-in is synthesized: "Here's the plan — check it and press Go." With `clamped`, a note follows: "You asked for {n} variants; the maximum is 4 per request, so the plan has 4." A refused proposal is a failed chip and the turn continues.
- The CustomEvent `agent_item_progress` on the agent path → an `AgentItemProgressFrame` line with `tool_call_id`.
- After the stream, `_chat_mode_turn` yields `KvPlanCardEvent(plan_id=…)` when `canvas_gate.stored_plan`, before `kv_agent_run`. The sniff sets `card_seen` on `"kv_plan_card"`.
- `KV_CANVAS_WRITE_TOOL_NAMES` and the failed-chip set use `KV_STRUCTURE_TOOL_NAMES`.
- Prompt: `_STRUCTURE_TOOL_LINES` for the 3 tools, plus a `_PLAN_HEADER` (paid; one call with directions, suggestions ≤3, extra_directions ≤3; say max 4; sizes always ask which board; duplicate + visual change = variant; after the call nothing is generated until Go; never say it was generated).
- TOOL_NAME_ENUM / TOOL_ICONS entries.

- [ ] Step 1: tests:
  - `test_a_stored_plan_ends_the_turn_as_the_card`: script `[prose+tool_call propose_kv_variants, prose_turn("SHOULD NOT APPEAR")]` → frames: chip started/completed "Proposing Variants", `message` text has no "SHOULD NOT APPEAR", then `kv_plan_card {plan_id}` with a 26-char card_id, then `done`; no `kv_agent_run`, no `question_card`, no footnote.
  - `test_a_refused_proposal_does_not_end_the_turn`: api 422 then the model replies → failed chip, no `kv_plan_card`, the second prose turn is present.
  - `test_clamped_plan_says_the_maximum`; `test_proposal_without_prose_gets_a_lead_in`.
  - `test_flag_off_mounts_no_plan_tools` (tools list without the names → no proposal tool, prompt unchanged).
- [ ] Step 2–4 TDD. Step 5: commit `… — plan card turn on the KV stream`.

### Task 5: Go / Cancel turn (R5, R6, R9)

**Files:**
- Create: `app/agents/kv_generator/canvas_plan_turn.py`
- Modify: `app/agents/kv_generator/service.py` (`_chat_mode_turn`: before the intent layer)
- Test: `tests/agents/kv_generator/test_canvas_plan_turn.py`

**Interfaces:**
- `is_plan_answer(request) -> bool`: canvas present and `card_answer.purpose == "plan"`.
- `async def run_plan_turn(request, tools_by_name, ledger) -> AsyncIterator[str]`. Go means `"go" in option_ids`.
  - **accepted**, with `run_kv_plan_step` mounted: chip started (`tool_call_id="plan_go"`) → iterate the recorded tool → an `AgentItemProgressFrame` per event (with `tool_call_id`) → chip completed or failed → reply → `KvAgentRunEvent` iff `ledger.has_run_writes`.
  - **Not accepted, or no plan:** a single reply line chosen by status. No tool call is made.
- Reply copy (EN / ID by `_indonesian(answered request)`, from chat_history's last user message):
  - started: "Started {n} variant board(s)|size(s) — they appear on the canvas as each one finishes." / "Mulai membuat {n} board varian|ukuran — hasilnya muncul di canvas begitu masing-masing selesai."
  - skipped tail: " {k} could not start ({reasons})." / " {k} tidak bisa dimulai ({reasons})."
  - nothing started: "Nothing was started ({reasons})." / "Tidak ada yang dimulai ({reasons})."
  - cancelled: "Cancelled — nothing was generated and no credits were used." / "Dibatalkan — tidak ada yang dibuat dan tidak ada kredit terpakai."
  - expired: "That plan expired before Go, so nothing was started. Ask again for a fresh plan." / "Rencana itu sudah kedaluwarsa sebelum Go, jadi tidak ada yang dimulai. Minta lagi untuk rencana baru."
  - superseded: "That plan was replaced by a newer one, so nothing was started — use the latest plan card." / "Rencana itu sudah diganti yang lebih baru, jadi tidak ada yang dimulai — pakai kartu rencana terbaru."
  - executed: "That plan has already started — its items are on the canvas or still rendering." / "Rencana itu sudah berjalan — hasilnya sudah di canvas atau masih diproses."
  - other: "That plan isn't confirmed, so nothing was started." / "Rencana itu belum dikonfirmasi, jadi tidak ada yang dimulai."

- [ ] Step 1: tests (through `run_stream`, respx):
  - `test_go_runs_every_accepted_step_once_and_says_started`: frame order chip → 2 CustomEvent frames (`kind`, `item_id`, `item_kind`, `state="queued"`, `agent_run_id`, `tool_call_id="plan_go"`) → completed chip → message (contains "Started 2", not "done") → `kv_agent_run` → done; one R6 request; no model built (the agent factory is never called).
  - `test_cancel_answers_without_any_call`.
  - `test_non_accepted_go_starts_nothing[expired|superseded|executed|proposed]`: no request, the status's line.
  - `test_indonesian_request_gets_indonesian_copy`.
  - `test_partial_skip_is_reported`.
- [ ] Step 2–4 TDD. Step 5: commit `… — Go and Cancel turns`.

### Task 6: Intent — R12 and the live plan handoff

**Files:**
- Modify: `app/agents/canvas_intent/validator.py` (duplicate with a change → variant), `app/tools/kv_plan_tools.py` + `app/tools/kv_structure_tools.py` (hints), `app/agents/kv_generator/canvas_intent_turn.py` (`LiveOutcome.plan_hint`), `app/agents/kv_generator/service.py` (append the hint), `evals/golden/kv_canvas/structure.json`, `evals/surface_runner/kv_canvas.py` (`direction_has`)
- Test: `tests/agents/canvas_intent/test_board_actions.py`, `tests/agents/kv_generator/test_canvas_intent_board_surface.py`

**Interfaces:**
- `decide`: before rule 1b, an intent `duplicate` whose `params.directions` holds text becomes `variant`. This applies only when `variant` is allowed on the surface; `count` is kept.
- `run_live`: a write decision whose calls are all `cost == "plan"` → `out.plan_hint = "\n\n" + fence("resolved_plan", json of [{tool, args, note}])` and return unhandled (no chip, no call).
- Scoring: `direction_has: str` → every variant's direction contains it (casefold).
- Golden: S23 "copy V7 but make it night" → variant gen_f, 1, direction_has "night"; S24 "Duplikat V7 dan ganti background jadi pantai" → variant gen_f, 1, "pantai"; S25 "Make 2 copies of Concept A with a red background" → variant gen_a, 2, "red"; S26 "duplikat Concept B 2 kali" → duplicate gen_b count 2; S27 "Add Instagram Story to Concept A and V7" → propose_kv_sizes board_ids {gen_a, gen_f}.

- [ ] Step 1: tests: `test_duplicate_with_a_direction_is_a_variant`, `test_plain_duplicate_stays_duplicate`, `test_duplicate_with_direction_stays_duplicate_when_variant_not_mounted`; `test_live_plan_decision_hands_off_with_the_resolved_args` (no tool called, `plan_hint` names `propose_kv_variants` and `gen_f`).
- [ ] Step 2–4 TDD; then live: `--golden structure.json --trials 3` ≥90%, and `intent-seed.json` flag off unchanged.
- [ ] Step 5: commit `… — duplicate + change is a variant, live plan handoff`.

### Task 7: Plan-flow golden (TASK-13)

**Files:**
- Create: `evals/golden/kv_canvas/plan.json`, `docs/evals/kv-agentic-canvas-p1-plan.md`
- Modify: `evals/surface_runner/kv_canvas.py` (kind `plan`: agent_canvas.tools = golden capabilities; respx `…/{file}/plans` recorded and answered with a plan view; `score_plan`)

**Interfaces:**
- `expect {kind: "plan", capability, args (same matcher), suggestions?: true, card: true}`. PASS = exactly one plans call (no other writes) with that capability and args; every variant has 1–3 suggestions when `suggestions`; ≤3 extra_directions; one `kv_plan_card` frame; the reply does not claim the renders are done.
- Cases: P01 "Generate 3 variants of V7 with different backgrounds" (gen_f, 3, suggestions); P02 "bikin 2 variasi Concept A: versi malam dan versi pantai" (gen_a, 2); P03 "Add Instagram Story and 1:1 sizes to Concept A and V7" (add_sizes, {gen_a, gen_f}); P04 "Generate 6 variants of V7" (4, reply mentions 4); P05 "copy V7 but make it night" (variant gen_f 1).
- Go / expired / superseded are deterministic (no model) → pinned by Task 5 unit tests, not golden.

- [ ] Step 1: runner unit test `test_score_plan_*` (offline). Step 2: live `--golden plan.json --trials 3` with intent_mode off and live → ≥90%. Step 3: report. Step 4: commit `… — plan-flow golden`.

### Task 8: Verification, track, review

- [ ] Full suite with `-rfE --continue-on-collection-errors`; diff the FAILED set against the baseline → no new failures.
- [ ] Track: tick TASK-8..13, add a session log (commits, counts, golden, contract deviations).
- [ ] One superpowers:requesting-code-review pass on `942c8284..HEAD`; fix Critical/Important; re-run the suite; commit.

## Contract deviations (anticipated)

- R4 frame order: `kv_plan_card` comes after `message` (the `kv_agent_run` slot) so api can stamp the saved row.
- Go/Cancel turns are answered without a model call; `run_kv_plan_step` is mounted and called by the turn handler (one call, all accepted steps).
- A live intent plan decision hands off to the agent with the resolved arguments (the intent layer cannot write suggestions).
