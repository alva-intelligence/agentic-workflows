# KV Agentic Canvas P1.1 — ai-service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On a KV Craft canvas, "generate 3 different ideas themed Indonesian independence day" proposes N (≤4) distinct NEW boards from scratch on the P1 plan card, through a new `propose_kv_concepts` tool and a `concept_boards` intent action.

**Architecture:** `propose_kv_concepts` mirrors `propose_kv_variants` (same `proposal_guard`, `_propose`, `plan_card_tool`, R4 frame) with no `board_id` and an `aspect_ratio`. One registry entry (`scope="file"`) makes it mountable, intent-routable and plan-gated. The validator gains a concept rule: on a canvas with boards and no board named, it asks a "New ideas or variants?" card (purpose `targets`, options `new_ideas` / `board:<active>`); the answer routes deterministically. A live concept decision hands off to the agent with a `resolved_plan` hint, as P1 variants do (only the model writes directions and suggestions).

**Tech Stack:** Python 3.11, agno 2.6.20, pydantic v2, pytest + pytest-asyncio + respx.

**Spec:** `frnd/docs/prd/kv-agentic-canvas-p1-1.md`; contracts `docs/superpowers/plans/2026-10-23-kv-agentic-canvas-p1-1-concept-contracts.md` (C1, C4, C10, C12); service PRD `ai-service/docs/prd/kv-agentic-canvas-p1-1.md` (TASK-0..6). Worktree `ai-service/.worktrees/kv-agentic-canvas-p1-1`, branch `feature/daffa/vc-kv-agentic-canvas-p1-1`, HEAD ce5c51d7.

## Global Constraints

- Names are frozen: tool `propose_kv_concepts`, capability `concept_boards`, `CONCEPTS_TOOL`, `PLAN_PROPOSAL_TOOLS`, label `"Proposing Concepts"`.
- api body (C2): `{capability: "concept_boards", params: {directions[{direction, suggestions[{label, direction}] ≤3}] ≤4, extra_directions[{label, direction}] ≤3, aspect_ratio}}`, plus `thread_id` and the turn context (`user_id`, `workspace_id`, `agent_run_id`). No `board_id`, no `copy_layers`.
- Allowed `aspect_ratio`: exactly `16:9`, `9:16`, `1:1`; default `1:1` (C5, open issue 1 → b).
- >4 directions: cut to 4, `clamped: {requested, max: 4}`, the reply says the maximum is 4.
- `plan_pending` claimed before the await; every other write that turn refuses (P1 FR-11).
- Flag off (tool not in `agent_canvas.tools`): resolver prompt, decisions and the P1 golden are unchanged.
- Never `git stash`, never `uv sync`, never touch `.workflow-state.json`, no push / PR / rebase. Commit messages `feat(ai): KV agentic canvas P1.1 — …` + `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Test baseline at HEAD: 48 failed + 1 collection error (`tests/repositories/test_brand_repository.py`); run with `--continue-on-collection-errors` and compare failure sets.

## Review Focus

1. A card answer whose option is `new_ideas` while the resolver returned `variant` (or no count) → still a concept proposal, never a variant of a guessed board. Pinned in Task 4.
2. An empty canvas where the resolver says `variant` ("3 variants about Ramadan") → concept, not a which-board card that cannot be built. Pinned in Task 4.
3. The model writes the same direction N times → sent back once per turn (FR-2 "genuinely distinct"), second identical call proposed as is. Pinned in Task 2.
4. `aspect_ratio` written as `"9x16"`, `" 16 : 9 "` or `"4:5"` → first two normalised, `4:5` refused with the allowed list. Pinned in Task 2.
5. Go on a concept plan → the reply names idea boards, not "variant boards". Pinned in Task 3.

## Contract deviations (decided here, reported to the lead)

- D1: Label + icon go in `app/utils/enum/tool_name_enum.py` (`TOOL_NAME_ENUM` / `TOOL_ICONS`) next to `propose_kv_variants`, not in `_tool_name_slug`'s local map in `service.py`: that map only holds generic tools and falls through to `TOOL_NAME_ENUM`, and `TOOL_ICONS` only exists there. Icon `key_visual` (no lightbulb icon exists).
- D2: The clarifying card reuses purpose `targets` (C10.1 allows it); option ids `new_ideas` and `board:<board_id>`; title `New ideas or variants?`. No api / web change needed.
- D3: `aspect_ratio` defaults to `"1:1"` in the tool signature (C4 lists it as required); the api body always carries it.

---

### Task 1: Close the P1 track (TASK-0)

**Files:** Modify `docs/tracks/kv-agentic-canvas-p1.track.md` (frontmatter + status table).

- [ ] Set `status: completed`; PR row `merged` with `https://github.com/alva-intelligence/frnd-ai-services/pull/385`; Implementation `completed`.
- [ ] Commit `docs(ai): KV agentic canvas P1.1 — close the P1 track (PR #385 merged)`.

### Task 2: `propose_kv_concepts` tool + registry + labels (TASK-1/2/3, C1, C4, C12)

**Files:**
- Modify: `app/tools/kv_plan_tools.py`, `app/utils/enum/tool_name_enum.py`, `app/utils/kv_canvas_tool_result.py`
- Test: `tests/tools/test_kv_plan_tools.py`, `tests/tools/test_kv_canvas_capability.py`

**Interfaces:**
- Produces: `CONCEPTS_TOOL = "propose_kv_concepts"`; `PLAN_PROPOSAL_TOOLS = frozenset({VARIANTS_TOOL, SIZES_TOOL, CONCEPTS_TOOL})`; `ASPECT_RATIOS = ("16:9", "9:16", "1:1")`; `DEFAULT_ASPECT_RATIO = "1:1"`; `normalize_aspect(value: Any) -> str | None`; `ConceptPlanParams(directions: list[VariantStep] 1..4, extra_directions ≤3, aspect_ratio: Literal[...])`; `make_concepts_tool(ctx) -> propose_kv_concepts(action="", file_id="", directions: list[VariantInput] | None = None, extra_directions=None, aspect_ratio: str = "1:1", **kwargs)`; `_concept_args(action, params, boards, labels) -> list[IntentCall]` (args `{action, directions[{direction, suggestions: []}], extra_directions: [], aspect_ratio}`, note `"Asked for {n} ideas; the maximum is 4 per request, so the plan has 4."` when n > 4); registry entry `name=CONCEPTS_TOOL, cost="plan", ends_turn=True, intent_actions={"concept_boards"}, scope="file"`, with `intent_hint`.

- [ ] **Step 1: failing tests** in `test_kv_plan_tools.py`:
  - `test_concepts_posts_the_c2_body`: two directions + one extra + `aspect_ratio="9:16"` → body `{"capability": "concept_boards", "params": {"directions": [...], "extra_directions": [SUGGESTION], "aspect_ratio": "9:16"}, "thread_id": "t1", **CTX}`; no `board_id` key; gate `stored_plan == {"plan_id": PLAN}`.
  - `test_six_concepts_clamp_to_four`: 6 distinct directions → 4 sent, `out["clamped"] == {"requested": 6, "max": 4}`.
  - `test_concept_aspect_ratio_defaults_and_normalises`: omitted → `"1:1"`; `"9x16"` → `"9:16"`; `" 16 : 9 "` → `"16:9"`.
  - `test_an_unknown_aspect_ratio_is_refused_before_api`: `"4:5"` → `error` naming `16:9, 9:16, 1:1`, route not called, `gate.plan_pending is False`.
  - `test_a_concept_without_suggestions_is_sent_back_once` and `test_identical_concept_directions_are_sent_back_once` (casefold + whitespace-normalised equality): first call `error`, nothing posted; the same call again is proposed.
  - `test_a_write_gathered_with_a_concept_proposal_refuses`: concepts + `rename_kv_board` in one `asyncio.gather` → the write gets `PLAN_PENDING_ERROR`.
  - `test_concept_intent_args_clamp_with_note`: `_concept_args("concept_boards", {"count": 6, "brief": "Ramadan", "aspect_ratio": "9x16"}, [], {})` → 4 rows of `{"direction": "Ramadan", "suggestions": []}`, `aspect_ratio "9:16"`, note contains `"maximum is 4"`; unknown ratio → `"1:1"`.
  - In `test_kv_canvas_capability.py`: `test_concepts_entry_is_a_plan_proposal` — entry cost `plan`, `ends_turn`, scope `file`, `"concept_boards"` in `intent_actions`, `CONCEPTS_TOOL in PLAN_PROPOSAL_TOOLS`, `TOOL_NAME_ENUM[CONCEPTS_TOOL] == "Proposing Concepts"`, `TOOL_ICONS[CONCEPTS_TOOL] == "key_visual"`, `kv_canvas_tool_result(CONCEPTS_TOOL, {"id": "p", "status": "proposed", "steps": [{}, {}]})["steps"] == 2`.
- [ ] **Step 2:** run `.venv/bin/python -m pytest tests/tools/test_kv_plan_tools.py tests/tools/test_kv_canvas_capability.py -q` → new tests FAIL (ImportError on `CONCEPTS_TOOL`).
- [ ] **Step 3: implement.** Docstring tells the model: NEW boards from scratch, each direction a genuinely different concept angle (scene / story / visual idea, not a small variation), 2-3 suggestions per row, ≤3 extra_directions, `aspect_ratio` from the user's words (Instagram/IG story, reels, TikTok, portrait → `9:16`; landscape, YouTube, banner → `16:9`; square, feed post or unsaid → `1:1`), max 4 (say so). The once-per-turn nudge covers both missing suggestions and duplicate directions (one shared `turn["nudged"]`).
- [ ] **Step 4:** same command → PASS.
- [ ] **Step 5:** commit `feat(ai): KV agentic canvas P1.1 — propose_kv_concepts plan tool (C4)`.

### Task 3: Stream, agent prompt, card purpose and Go copy

**Files:**
- Modify: `app/agents/kv_generator/service.py` (`PLAN_CLAMP_NOTE` per tool), `app/agents/kv_generator/canvas_context_prompt.py` (`_PLAN_TOOL_LINES`), `app/agents/kv_generator/tools.py` (`SCRATCH_CARD_TITLE = "New ideas or variants?"`, `canvas_card_purpose`), `app/agents/kv_generator/canvas_plan_turn.py` (`_COPY[...]["ideas"]`)
- Test: `tests/agents/kv_generator/test_agent_canvas_plan_loop.py`, `tests/agents/kv_generator/test_canvas_plan_turn.py`, plus the existing prompt / card-purpose test files.

**Interfaces:**
- Produces: `PLAN_CLAMP_NOTES: dict[str, str]` keyed by proposal tool (variants text byte-identical to today's `PLAN_CLAMP_NOTE`; concepts `"\n\nYou asked for {requested} ideas; the maximum is {max} per request, so the plan has {max}."`); the stream picks by the stored proposal's tool name. `SCRATCH_CARD_TITLE` (consumed by Task 4).

- [ ] **Step 1: failing tests:**
  - `test_clamped_concept_plan_says_the_maximum_in_ideas` (mirror `test_clamped_plan_says_the_maximum`, tool `propose_kv_concepts`) → reply has `"6 ideas"` and `"maximum is 4"`.
  - `test_concepts_prompt_line_only_when_mounted`: `build_kv_structure_prompt(["propose_kv_concepts"])` contains `propose_kv_concepts`, `SCRATCH_CARD_TITLE`, `new_ideas`, `board:`; `build_kv_structure_prompt(["propose_kv_variants", "propose_kv_sizes"])` is byte-identical to its value at HEAD (pin by asserting `"propose_kv_concepts" not in` and the variants line unchanged).
  - `test_scratch_card_is_a_targets_card`: `canvas_card_purpose(SCRATCH_CARD_TITLE, [{"label": "New ideas"}, {"label": "Variants of V7"}], [], ["V7"]) == "targets"`.
  - `test_go_on_a_concept_plan_names_idea_boards` (EN and ID): plan capability `concept_boards`, 3 applied → `"Started 3 idea boards"` / `"3 board ide"`.
- [ ] **Step 2:** run those files → new tests FAIL.
- [ ] **Step 3: implement.** The prompt line (mounted only): new ideas from scratch go to `propose_kv_concepts`, never `suggest_mode_switch`, on an empty canvas always; on a canvas with boards when the user named no board and did not say from scratch, write one short sentence then `present_question_card` titled `New ideas or variants?` with options `{"id": "new_ideas", "label": "New ideas", ...}` and `{"id": "board:<active board_id>", "label": "Variants of <active board name>", ...}`; "New ideas" → this tool with the earlier request; "Variants of …" → `propose_kv_variants` of that board; ideas for a named board are variants. `canvas_card_purpose`: the scratch title → `targets`.
- [ ] **Step 4:** run → PASS.
- [ ] **Step 5:** commit `feat(ai): KV agentic canvas P1.1 — concept plan on the stream, agent prompt, Go copy`.

### Task 4: Intent — `concept_boards` action, routing and the clarifying card (TASK-4/5, C10)

**Files:**
- Modify: `app/agents/canvas_intent/schema.py` (Action + `Card.subject: str = ""`), `app/agents/canvas_intent/validator.py`, `app/agents/canvas_intent/surface.py` (protocol `scratch_or_variant_card`), `app/agents/kv_generator/canvas_intent_surface.py`, `app/agents/kv_generator/canvas_intent_turn.py` (`lead_in`, `plan_hint`)
- Test: create `tests/agents/kv_generator/test_canvas_intent_concepts.py`

**Interfaces:**
- Consumes: `CONCEPTS_TOOL`, `_concept_args` (Task 2), `SCRATCH_CARD_TITLE` (Task 3).
- Produces: `validator.CONCEPT_ACTION = "concept_boards"`, `validator.SCRATCH_OPTION_ID = "new_ideas"`; `IntentSurface.scratch_or_variant_card() -> Card | None` (KV: purpose `targets`, label `SCRATCH_CARD_TITLE`, options `new_ideas` then `board:<active or first board>` labelled `Variants of <name>`, `subject=<name>`).

Routing (in `decide`, after the R12 rewrite, only when `concept_boards` is allowed):
1. card answer (purpose `targets`) picked `new_ideas` and action ∈ {concept_boards, variant} → concept_boards, `from_scratch=True`, targets cleared.
2. action `variant` and the surface knows no board → concept_boards.
3. action `concept_boards` with a named board (`targets.board_ids`) or a `board:` card pick, and `variant` allowed → variant (`count` kept, `directions` = params directions or `[brief]`), then the board rule.
4. action `concept_boards`: boards exist, not `from_scratch`, `variant` allowed → ask with `scratch_or_variant_card()` (handoff if None); else build calls → `write`.

- [ ] **Step 1: failing tests** (fixtures as in `test_canvas_intent_board_surface.py`, `ALL` = every registered capability, `EMPTY = {"boards": [], "active": {}}`):
  - `test_empty_canvas_concepts_write_the_proposal`: `concept_boards` count 3 brief "Hari Kemerdekaan" → write `propose_kv_concepts`, 3 rows, `aspect_ratio "1:1"`.
  - `test_empty_canvas_variant_becomes_concepts`.
  - `test_concepts_with_boards_and_no_board_named_ask_scratch_or_variant`: ask, card purpose `targets`, label `SCRATCH_CARD_TITLE`, option ids `["new_ideas", "board:gen_f"]` (active gen_f), `subject == "V7"`.
  - `test_explicit_from_scratch_skips_the_card`.
  - `test_concepts_naming_a_board_are_a_variant`: board_ids `["V7"]` → write `propose_kv_variants` board gen_f, count kept.
  - `test_new_ideas_answer_routes_to_concepts` (resolver said `variant`, answer `new_ideas`) and `test_variants_answer_routes_to_the_picked_board` (answer `board:gen_f`, action concept_boards → `propose_kv_variants` gen_f).
  - `test_concept_count_over_four_clamps_with_note`.
  - `test_concepts_not_mounted_hand_off_and_change_nothing`: capabilities without the concept tool → concept_boards handoff; empty-canvas `variant` unchanged (asks/handoffs as at HEAD); no `concept_boards` text in `intent_instructions()`.
  - `test_r12_copy_with_change_stays_variant_with_concepts_mounted`.
  - `test_scratch_card_lead_in_names_the_board`: EN `"Do you want new ideas from scratch, or variants of V7?"`, ID `"Mau ide baru dari nol, atau varian dari V7?"`.
  - `test_live_concept_decision_hands_off_with_a_concepts_hint`: `plan_hint` mentions `propose_kv_concepts`, `aspect_ratio`, "genuinely different"; the variants hint text is unchanged.
- [ ] **Step 2:** run the new file → FAIL.
- [ ] **Step 3: implement** (resolver hint on the registry entry: concept_boards = N new, different ideas/concepts/ide/konsep from scratch, not from an existing board; params `{"count", "brief", "aspect_ratio" (rules as Task 2), "from_scratch": true only for from scratch / dari nol / dari awal / brand new}`; no board_ids; ideas that name a board are `variant`; on the "New ideas or variants?" card, `new_ideas` = concept_boards with `from_scratch` true and `board:<id>` = variant of that board, count and brief from `card_asked_about`).
- [ ] **Step 4:** run the new file + `tests/agents/kv_generator/test_canvas_intent_board_surface.py tests/agents/canvas_intent` → PASS.
- [ ] **Step 5:** commit `feat(ai): KV agentic canvas P1.1 — concept_boards intent + "new ideas or variants?" card (C10)`.

### Task 5: Golden cases + live eval (TASK-6, FR-13)

**Files:**
- Create: `evals/golden/kv_canvas/concept.json`
- Modify: `evals/surface_runner/kv_canvas.py` (plans handler counts `directions`; `_args_match` key `concept_count` = len(directions); `score_plan` suggestions over `variants or directions`, `distinct: true` = pairwise-different directions; `score_intent` ask checks `card_title` when given)
- Test: `tests/evals/test_structure_scoring.py`
- Report: `docs/evals/kv-agentic-canvas-p1-1-concepts.md`

- [ ] **Step 1: failing scoring tests**: `concept_count` match/mismatch, `distinct` fails on two equal directions, `card_title` mismatch fails.
- [ ] **Step 2:** run → FAIL; **Step 3:** implement; **Step 4:** run → PASS.
- [ ] **Step 5: golden file** — capabilities = P1's six + `propose_kv_concepts`, inventory `p0.json`; ≥3 EN + ≥3 ID covering: empty canvas (intent + plan), non-empty no board → ask `targets` `New ideas or variants?` (intent + plan-level `ask`), explicit from scratch (EN + ID), count > 4 clamp with note / reply has "4", R12 copy-with-change → variant (EN + ID), "3 variants of V7" → variant, "ide baru dari V7" → variant, card answers `new_ideas` → concepts and `board:gen_f` → variant gen_f, IG story → `9:16`, YouTube → `16:9`.
- [ ] **Step 6: live run** (worktree `.env` models), `--trials 3`, intent-mode `off` and `live`; plus P1 regression `structure.json` and `plan.json`. Bar ≥90% on concept.json. Write the report.
- [ ] **Step 7:** commit `test(ai): KV agentic canvas P1.1 — concept_boards golden cases + scoring`.

### Task 6: Track + full suite

- [ ] Full suite with `--continue-on-collection-errors`; failure set must equal the HEAD baseline (48 + 1 collection error).
- [ ] Update `docs/tracks/kv-agentic-canvas-p1-1.track.md`: tasks checked, Implementation `completed`, session log (commits, test diff, golden, deviations D1–D3). Commit `docs(ai): KV agentic canvas P1.1 — track`.
- [ ] One `superpowers:requesting-code-review` pass; fix Critical / Important test-first; re-run the suite; append the review to the track.
