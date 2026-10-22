# KV Agentic Canvas P1 — Round A (ai-service) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The KV board-aware chat can duplicate, rename, arrange and hide/unhide boards for free through api, and the intent layer recognises every board-level action (incl. the paid `variant` / `add_sizes` intents that Round B will execute).

**Architecture:** A capability registry (`KV_CANVAS_CAPABILITIES`, S4) is the one place a structure capability is declared: its tool factory, its api body schema, and its intent mapping (which actions, board scope, source fallback, how an intent becomes tool args). Tools mount only when api lists them in `agent_canvas.tools` (flag `kv-agentic-canvas-structure`, decided by api). The surface-neutral validator gains one generic board-action rule driven by a `BoardActionSpec` the surface reads from the registry; it never names a capability.

**Tech Stack:** Python 3.11, FastAPI, agno 2.6.20, pydantic v2, httpx + respx, pytest-asyncio.

**Spec:** `ai-service/.worktrees/kv-agentic-canvas-p1/docs/prd/kv-agentic-canvas-p1.md` (TASK-1..7) + contracts S4, S10, S16 in `docs/superpowers/plans/2026-10-22-kv-agentic-canvas-p1-structure-contracts.md`. Main PRD FR-1, FR-8..10, FR-21, FR-25, FR-26, NFR-1, NFR-7, AC-11, AC-13, AC-14.

Worktree: `ai-service/.worktrees/kv-agentic-canvas-p1`, branch `feature/daffa/vc-kv-agentic-canvas-p1`. All paths below are relative to it. Test command prefix: `AGNO_TELEMETRY=false ../../.venv/bin/python -m pytest -p no:cacheprovider` (the worktree needs a copied `.env`; it is gitignored).

## Global Constraints

- Tool names exactly: `duplicate_kv_board`, `rename_kv_board`, `arrange_kv_boards`, `hide_kv_boards` (free); `propose_kv_variants`, `propose_kv_sizes` (plan, Round B executes). Registry name `KV_CANVAS_CAPABILITIES`; dataclass `KvCanvasCapabilityEntry` with fields `name`, `cost`, `tool_fn`, `tool_schema` (S4) — extra fields allowed, none renamed.
- api routes (S10): `POST mcp/tools/kv/canvas/{fileId}/boards/duplicate` `{board_id, count ≤ 4, names?, copy_layers=true}`; `…/boards/rename` `{board_id, name}`; `…/boards/arrange` `{layout: "grid"|"row"}`; `…/boards/hide` `{board_ids, hidden: bool}`. Every body also carries `user_id`, `workspace_id`, `agent_run_id` (P0 `_ctx`).
- Unhide is `hide_kv_boards` with `hidden: false` (S10 lists one tool; the service PRD's "unhide_kv_boards" is that call, not a fifth tool name).
- New `CanvasIntent.Action` values exactly: `duplicate`, `variant`, `add_sizes`, `rename_board`, `arrange`, `hide_board`, `show_board`. `params` keys: `count`, `directions[]`, `sizes[]`, `names[]` (+ `layout` for arrange).
- Max boards per request = 4 (`MAX_BOARD_COUNT`); over 4 → clamp to 4 and the reply says so.
- Chip labels: "Duplicating Boards", "Renaming Board", "Arranging Boards", "Hiding Boards"; icon `key_visual`.
- Flag off (`agent_canvas.tools` empty/absent) = no structure tool mounted, no structure prompt text, resolver instructions byte-identical, every board action hands off.
- Never `uv sync`; never `git stash`; commit only on the feature branch in this worktree; no push.
- Commits `feat(ai): …` ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Two boards share a label** ("Concept A" twice) and the user names it → `resolve_board` returns None, the validator asks with the which-board card instead of picking one. Test in Task 5.
2. **Flag off** → no structure tool in the agent's tool list, system prompt identical, resolver instructions identical; a "duplicate V7" request hands off. Tests in Tasks 2 and 5.
3. **Which-board card answered**: the P0 card payload lowercases option ids (`board:01m57…`) → the answer maps back to the real (case-preserved) board id. Test in Task 6.
4. **Messy names**: `names` longer than `count`, blank names, whitespace → count grows to the name count (then clamps), blanks dropped. Test in Task 2.
5. **Plan intent at runtime in Round A**: a `variant` decision whose tool is not mounted must hand off before any chip or write. Test in Task 5.

---

### Task 1: Capability registry + mounting (TASK-1)

**Files:**
- Create: `app/tools/kv_canvas_capability.py`
- Modify: `app/tools/kv_canvas_tools.py` (lift `_recorded` out of the factory as module-level `record_tool`)
- Modify: `app/agents/kv_generator/request_schema.py` (`AgentCanvas.tools`)
- Test: `tests/tools/test_kv_canvas_capability.py`, `tests/agents/kv_generator/test_agent_canvas_schema.py`

**Interfaces:**
- Produces:
  - `record_tool(fn, ledger: WriteLedger, turn_closed: Callable[[], str | None] | None) -> Callable` in `kv_canvas_tools.py` — exactly today's `_recorded` behaviour (yield once, turn-closed refusal, `validate_call`, ValidationError → `{"error": "args refused: …"}`, ledger.record, `_wrapped_for_validation`). `make_kv_canvas_tools` uses it.
  - `KvToolContext` (frozen dataclass): `user_id`, `workspace_id`, `run_id`, `file_id: str`; methods `body(extra: dict) -> dict` (adds `user_id`, `workspace_id`, `agent_run_id`) and `async post(path: str, json: dict) -> dict` (`call_api("POST", path, …, timeout=_API_TIMEOUT, label="kv canvas", unwrap_data=True)`), and `file(file_id: str) -> str` (per-call first, then bound).
  - `IntentCall` dataclass: `args: dict[str, Any]`, `note: str = ""`.
  - `KvCanvasCapabilityEntry` (frozen dataclass): `name: str`, `cost: Literal["free","plan"]`, `tool_fn: Callable[[KvToolContext], Callable[..., Awaitable[dict]]] | None`, `tool_schema: dict[str, Any]`, `intent_actions: frozenset[str] = frozenset()`, `scope: Literal["file","one_board","boards"] = "one_board"`, `source_fallback: bool = False`, `build_args: Callable[[str, dict, list[str], Mapping[str, str]], list[IntentCall] | str] | None = None`, `intent_hint: str = ""`.
  - `KV_CANVAS_CAPABILITIES: dict[str, KvCanvasCapabilityEntry]` (empty in this task), `register_capability(entry, registry=None) -> None` (raises `ValueError` on a duplicate name).
  - `MAX_BOARD_COUNT = 4`.
  - `make_kv_structure_tools(user_id, workspace_id, run_id, ledger, *, file_id, mounted: Iterable[str], turn_closed=None, registry=None) -> list[Callable]` — one recorded tool per entry whose `name ∈ mounted` and `tool_fn is not None`, in registry order; `[]` when `mounted` is empty.
  - `KvStreamRequest.agent_canvas.tools: list[str]` (default `[]`, `max_length=32`).

- [ ] **Step 1: Write the failing tests**

`tests/tools/test_kv_canvas_capability.py` — a fake entry in a local registry dict (AC-13):
- `test_nothing_mounts_when_api_lists_no_tools`: `make_kv_structure_tools(..., mounted=[], registry={"fake_tool": entry})` → `[]`.
- `test_a_fake_capability_mounts_from_the_registry_alone`: entry `fake_tool` whose `tool_fn(ctx)` returns `async def fake_tool(action: str = "", board_id: str = "", **kwargs)` posting `ctx.body({"board_id": board_id})` to `f"mcp/tools/kv/canvas/{ctx.file}/boards/fake"` (respx route `https://api.test/api/v1/…`) → the call body has `user_id == "u1"`, `workspace_id == "w1"`, `agent_run_id == RUN`, `board_id == "gen_a"`; `ledger.applied == 1` for an api response `{"data": {"run_id": RUN, "applied": [{"target": "gen_a", "op": "x"}], "skipped": []}}`.
- `test_an_unmounted_or_toolless_entry_is_skipped`: entries `a` (tool), `b` (tool_fn None) with `mounted=["b", "zzz"]` → `[]`; `mounted=["a","b"]` → names `["a"]`.
- `test_turn_closed_refuses_before_api`: `turn_closed=lambda: "closed"` → result `{"error": "closed"}`, no HTTP call, `ledger.attempts == 1`.
- `test_register_refuses_a_duplicate_name`: second `register_capability` with the same name → `ValueError`.

`test_agent_canvas_schema.py`: `test_agent_canvas_tools_default_empty_and_read` → absent → `[]`; `{"tools": ["duplicate_kv_board"]}` → `["duplicate_kv_board"]`.

- [ ] **Step 2: Run them, expect FAIL** — `… tests/tools/test_kv_canvas_capability.py tests/agents/kv_generator/test_agent_canvas_schema.py -q` → ImportError / missing field.

- [ ] **Step 3: Implement** `record_tool` (move, no behaviour change — the existing `tests/tools/test_kv_canvas_tools.py` must stay green), `AgentCanvas.tools`, and `kv_canvas_capability.py` per the Interfaces block.

- [ ] **Step 4: Run** the two new files + `tests/tools/test_kv_canvas_tools.py tests/tools/test_kv_canvas_footnote.py` → PASS.

- [ ] **Step 5: Commit** `feat(ai): KV canvas capability registry + structure tool mounting (P1 TASK-1)`.

---

### Task 2: Free structure tools + stream mounting (TASK-2)

**Files:**
- Create: `app/tools/kv_structure_tools.py` (the four tool factories + api body models)
- Modify: `app/tools/kv_canvas_capability.py` (register the four free entries)
- Modify: `app/agents/kv_generator/canvas_context_prompt.py` (`build_kv_structure_prompt`)
- Modify: `app/agents/kv_generator/service.py` (mount in `_chat_mode_turn`; name sets `KV_CANVAS_WRITE_TOOL_NAMES` and the failed-chip check include structure tools)
- Test: `tests/tools/test_kv_structure_tools.py`, `tests/agents/kv_generator/test_agent_canvas_stream.py`

**Interfaces:**
- Consumes: Task 1 `KvToolContext`, `register_capability`, `MAX_BOARD_COUNT`, `make_kv_structure_tools`.
- Produces:
  - api body models (pydantic, `extra="forbid"`): `DuplicateBoardBody(board_id: str (min 1), count: int (1..4), names: list[str] | None (≤4 items, each 1..120 chars), copy_layers: bool = True)`, `RenameBoardBody(board_id, name: str (1..120))`, `ArrangeBoardsBody(layout: Literal["grid","row"])`, `HideBoardsBody(board_ids: list[str] (1..20), hidden: bool)`. Each entry's `tool_schema = Body.model_json_schema()`.
  - Tools (all `async`, all take `action: str = ""`, `file_id: str = ""`, `**kwargs`; docstrings say: free, immediate, undoable, copy ids from kv_canvas_state):
    - `duplicate_kv_board(action, file_id, board_id: str = "", count: int = 1, names: list[str] | None = None, copy_layers: bool = True)` → POST `…/{fid}/boards/duplicate`.
    - `rename_kv_board(action, file_id, board_id: str = "", name: str = "")` → `…/boards/rename`.
    - `arrange_kv_boards(action, file_id, layout: Literal["grid","row"] = "grid")` → `…/boards/arrange`.
    - `hide_kv_boards(action, file_id, board_ids: list[str] | None = None, hidden: bool = True)` → `…/boards/hide`.
  - `KV_STRUCTURE_FREE_TOOLS = frozenset({...the four})` in `kv_structure_tools.py`.
  - `normalise_duplicate(count: int, names: list[str] | None) -> tuple[int, list[str], int | None]` → (count to send, cleaned names, requested count when clamped else None): strip names, drop blanks, `count = max(count, len(names))`, clamp to `MAX_BOARD_COUNT`, names truncated to the clamped count.
  - A clamped duplicate's result gains `"clamped": {"requested": n, "max": 4}` (only on a non-error result).
  - `build_kv_structure_prompt(tool_names: list[str]) -> str` — `""` for an empty list; else `"\n\n" + guidance` naming only the mounted tools: board ids from kv_canvas_state; free + undoable; count max 4 and say so when a result has `clamped`; hide never deletes (unhide = `hidden: false`); when the user did not say which board and none is active/selected, ask with present_question_card titled "Which board?" one option per board.

- [ ] **Step 1: Write the failing tests** (`tests/tools/test_kv_structure_tools.py`, respx at `https://api.test/api/v1/mcp/tools/kv/canvas`):
- `test_duplicate_posts_the_s10_body`: `duplicate_kv_board(action="x", board_id="gen_f", count=2, names=["Ramadan", "Lebaran"])` → POST `…/file-1/boards/duplicate`, body == `{"board_id": "gen_f", "count": 2, "names": ["Ramadan", "Lebaran"], "copy_layers": True, "user_id": "u1", "workspace_id": "w1", "agent_run_id": RUN}`.
- `test_duplicate_clamps_over_four_and_says_so`: `count=6` → body count 4, result `clamped == {"requested": 6, "max": 4}`.
- `test_normalise_duplicate_names` (Review Focus 4): `(1, [" A ", "", "B", "C"])` → `(3, ["A","B","C"], None)`; `(2, ["a","b","c","d","e"])` → `(4, ["a","b","c","d"], 5)`.
- `test_rename_posts_board_and_name`, `test_arrange_posts_layout` (`layout="row"`), `test_hide_and_unhide_post_hidden_flag` (`hidden=False` → body `hidden: false`).
- `test_missing_board_is_refused_before_api`: `rename_kv_board(board_id="", name="X")` → `{"error": …"args refused"…}` or a `board_id is required` error; no HTTP call; `ledger.errors` non-empty.
- `test_file_id_falls_back_to_bound_file_and_is_required`: bound `file_id=None` and no per-call id → `FILE_ID_REQUIRED_ERROR`.
- `test_registry_lists_the_four_free_tools`: `{n for n, e in KV_CANVAS_CAPABILITIES.items() if e.cost == "free"} == {"duplicate_kv_board","rename_kv_board","arrange_kv_boards","hide_kv_boards"}` and every `tool_schema["properties"]` ⊇ the S10 keys of its route.

Stream (`test_agent_canvas_stream.py`, existing fakes in `_canvas_fixtures.py`; add an optional `tools` kwarg to `canvas_request`):
- `test_structure_tools_mount_only_when_api_lists_them`: capture the agent's tool names (as the existing stream tests do) → with `tools=["duplicate_kv_board","hide_kv_boards"]` they are present; without → `CANVAS_TOOLS | BASE_TOOLS` exactly and the system prompt has no "duplicate_kv_board" (Review Focus 2).

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** the tools (body built through the body model so a bad value is a readable refusal), register the four entries (`cost="free"`, `tool_fn`, `tool_schema`), the prompt section, and the stream mounting: after `make_kv_canvas_tools`, `structure = make_kv_structure_tools(..., mounted=canvas.tools, turn_closed=canvas_gate.turn_closed)`; when non-empty `canvas_tools = [*canvas_tools, *structure]` and `system_prompt += build_kv_structure_prompt([t.__name__ for t in structure])`. Extend `KV_CANVAS_WRITE_TOOL_NAMES` and the failed-chip name check with `KV_STRUCTURE_FREE_TOOLS`.
- [ ] **Step 4: Run** the new files + `tests/agents/kv_generator/test_agent_canvas_*.py tests/tools/test_kv_canvas_tools.py` → PASS.
- [ ] **Step 5: Commit** `feat(ai): free KV board structure tools — duplicate, rename, arrange, hide (P1 TASK-2)`.

---

### Task 3: Chip labels, icons, result shaping (TASK-3)

**Files:**
- Modify: `app/utils/enum/tool_name_enum.py`, `app/utils/kv_canvas_tool_result.py`
- Test: `tests/test_kv_tool_result.py` (or a new `tests/utils/test_kv_canvas_tool_result.py` if the former is unrelated), `tests/tools/test_kv_structure_tools.py`

**Interfaces:**
- Produces: `TOOL_NAME_ENUM` entries `duplicate_kv_board: "Duplicating Boards"`, `rename_kv_board: "Renaming Board"`, `arrange_kv_boards: "Arranging Boards"`, `hide_kv_boards: "Hiding Boards"`; `TOOL_ICONS[...] = "key_visual"` for all four. `KV_CANVAS_BOARD_RESULT_TOOLS` frozenset in `kv_canvas_tool_result.py`, included in `KV_CANVAS_RESULT_TOOLS`; shape `{run_id, applied, skipped}` plus `clamped` when present.

- [ ] **Step 1: Failing tests**: labels/icons exact for the four names; `kv_canvas_tool_result("duplicate_kv_board", {"run_id": "r", "applied": [1], "skipped": [], "clamped": {"requested": 6, "max": 4}, "secret": 1})` == `{"run_id": "r", "applied": [1], "skipped": [], "clamped": {...}}`; without `clamped` the key is absent; a non-dict → None.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** those tests + `tests/tools/test_study_tools.py` → PASS.
- [ ] **Step 5: Commit** `feat(ai): chip labels + result shaping for KV structure tools (P1 TASK-3)`.

---

### Task 4: Ledger board claims + dispatched footnote (TASK-4)

**Files:**
- Modify: `app/tools/kv_canvas_tools.py` (`KvCanvasWriteLedger`)
- Test: `tests/tools/test_kv_canvas_footnote.py`

**Interfaces:**
- Produces in `kv_canvas_tools.py`:
  - `_BOARD_CLAIM` regex (EN + ID): `duplicated|copied|arranged|rearranged|hid|hidden|unhid|unhidden|created|generated|made` and `diduplikasi|digandakan|disalin|diatur|disusun|disembunyikan|ditampilkan|dibuat|dibuatkan`.
  - `_BOARD_SKIP_ACK` regex: `already hidden|already visible|nothing was (duplicated|created)|not (duplicated|renamed|hidden|created)|sudah tersembunyi|tidak (diduplikasi|dibuat|disembunyikan)`.
  - `KvCanvasWriteLedger.progress: dict[str, str]` (item_id → latest state) and `record_progress(event: dict) -> None` (reads `item_id`, `state`; ignores malformed; a `failed` state also appends `"render_failed"` to `skipped` once per item).
  - `pending_items` property: ids whose latest state is `queued` or `generating`.
  - `KV_DISPATCHED_FOOTNOTE = "Note: {n} item(s) were started but have not finished yet — they appear on the canvas when done."`
  - `footnote(answer)`: claims = `claims_write(answer) or _BOARD_CLAIM`; acks = `acknowledges_skip(answer) or _BOARD_SKIP_ACK`; existing two rules unchanged otherwise; then the dispatched rule: `pending_items` non-empty, the answer claims (claims or `_DONE_CLAIM`: `done|finished|ready|complete|completed|selesai|sudah jadi|siap`) and does not acknowledge progress (`_IN_PROGRESS_ACK`: `generating|rendering|in progress|queued|still|sedang|masih|diproses`) → append the dispatched line. Multiple notes join with a space after one leading blank line.

- [ ] **Step 1: Failing tests**:
- `test_board_claim_without_accept_gets_footnote`: ledger recorded `duplicate_kv_board` → `{"error": "request failed (409)"}`; `footnote("I duplicated V7 twice.")` starts with `"\n\nNote: no change to the canvas was accepted"`; Indonesian `"V7 sudah diduplikasi."` likewise.
- `test_board_skip_acknowledged_is_quiet`: applied 1 + skipped 1, answer `"Renamed V7; Variant 5 was already hidden."` → `""`.
- `test_dispatched_not_finished`: `record_progress({"item_id": "s1", "state": "generating"})`, applied 1, answer `"Done — 3 variants generated."` → contains `"1 item(s) were started but have not finished yet"`; then `record_progress({"item_id": "s1", "state": "done"})` → `""`.
- `test_in_progress_acknowledged_is_quiet`: pending item, answer `"3 variants are still rendering."` → `""`.
- `test_failed_progress_counts_as_skipped`: `record_progress({"item_id":"s2","state":"failed"})` twice → `skipped == ["render_failed"]`.
- `test_layer_footnotes_unchanged`: the existing file's cases pass untouched.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `tests/tools/test_kv_canvas_footnote.py tests/tools/test_kv_canvas_tools.py` → PASS.
- [ ] **Step 5: Commit** `feat(ai): KV ledger board claim words + dispatched-not-finished footnote (P1 TASK-4)`.

---

### Task 5: Intent layer — board actions, lookups, registry routing (TASK-5)

**Files:**
- Modify: `app/agents/canvas_intent/schema.py`, `surface.py`, `validator.py`, `resolver.py`
- Modify: `app/agents/kv_generator/canvas_intent_surface.py`, `canvas_intent_turn.py`
- Modify: `app/tools/kv_canvas_capability.py` (intent fields on the four free entries; register plan entries `propose_kv_variants` / `propose_kv_sizes` with `cost="plan"`, `tool_fn=None`)
- Test: `tests/agents/canvas_intent/test_validator.py` (FakeSurface gains the new methods), new `tests/agents/canvas_intent/test_board_actions.py`, `tests/agents/kv_generator/test_canvas_intent_board_surface.py`

**Interfaces:**
- Consumes: Task 1 `IntentCall`, entry intent fields; Task 2 entries.
- Produces:
  - schema: `Action` + the seven values; `BoardActionSpec(BaseModel)`: `scope: Literal["file","one_board","boards"]`, `source_fallback: bool = False`; `ToolCall.note: str = ""`; `Decision.event_view` omits `note` when empty.
  - `IntentSurface` protocol adds: `known_board_ids() -> set[str]`; `resolve_board(ref: str) -> str | None` (an id, or a board label matched case- and whitespace-insensitively; None when unknown or when two boards share the label); `board_action(action: str) -> BoardActionSpec | None`; `fallback_board(selection: list[str]) -> str | None`; `which_board_card(action: str) -> Card | None`; `intent_instructions() -> str`.
  - `sanitize`: every `targets.board_ids` entry goes through `resolve_board` first (labels become ids, then the existing known-id filter).
  - validator rule 1b (after rule 1, before rule 2): `spec = surface.board_action(action)`; if not None → `_decide_board(intent, surface, spec, selection, card_answer)`:
    1. action not in `allowed_actions()` → handoff `"action {a} not writable on {surface}"`.
    2. card answer → `_apply_card_answer` (purpose `targets`).
    3. `boards = sorted(_target_boards(...))`; scope `file` skips 4–6.
    4. no boards and (`spec.source_fallback` or `targets.source in {"selection","active_board"}`) → `surface.fallback_board(list(selection))`.
    5. no boards and exactly one known board → it. Still none → ask with `which_board_card(action)` (Task 6; until then handoff).
    6. scope `one_board` with >1 board → handoff `"{action} takes one board"`.
    7. targets ← `Targets(board_ids=boards, source=…)`, then `build_tool_calls` → write / handoff on ParamError.
  - `KvCanvasIntentSurface(inventory, recent_runs=None, capabilities: Iterable[str] = ())`; `allowed_actions()` = P0 actions ∪ intent actions of entries named in `capabilities`; `board_action` reads ANY registry entry (so unmounted ones hand off via 1); `build_tool_calls` for a board action → `entry.build_args(action, params, board_ids, board_names)` → `ToolCall(tool=entry.name, args=c.args, note=c.note)` per `IntentCall`, or `ParamError`; `intent_instructions()` = `""` when no mounted entry has an `intent_hint`, else a fixed header + the mounted entries' hints (deduplicated, registry order).
  - resolver: `_agent(..., extra_instructions: str = "")` uses `INSTRUCTIONS + extra_instructions`; `resolve_intent` passes `surface.intent_instructions()`. The board hint text also tells the model: a `targets` card option may be `board:<board_id>`; board_ids for board actions are the boards the user named (or a label exactly as shown); params per action — duplicate `{"count", "names"}`, variant `{"count", "directions"}`, add_sizes `{"sizes": ["Instagram Story", {"width":1080,"height":1080}]}`, rename_board `{"names": ["new name"]}`, arrange `{"layout": "grid"|"row"}`, hide_board / show_board `{}`; "this board" / "board ini" = source active_board with empty board_ids.
  - `CanvasIntentTurn` builds the surface with `capabilities=canvas.tools`; `run_live` checks every decided call's tool is mounted BEFORE the first chip (missing → log + return, handoff); each result entry carries `note` and `REPLY_INSTRUCTIONS` gains "say every `note`"; `_plain_reply` appends notes.
  - build_args per entry (labels via `board_names`, e.g. "Duplicating V7"):
    - duplicate (`{"duplicate"}`, scope `boards`, fallback True): one call per board `{action, board_id, count, names?, copy_layers: True}` via `normalise_duplicate`; clamp note `"Asked for {n} copies; the maximum is 4 per request, so 4 were made."`.
    - rename_kv_board (`{"rename_board"}`, `one_board`): `names[0]` stripped non-empty else error `"rename needs the new name"` → `{action, board_id, name}`.
    - arrange_kv_boards (`{"arrange"}`, `file`): `layout` ∈ grid/row (default grid) → `{action, layout}`.
    - hide_kv_boards (`{"hide_board","show_board"}`, `boards`): one call `{action, board_ids, hidden: action == "hide_board"}`.
    - propose_kv_variants (`{"variant"}`, `one_board`, fallback True, plan): `n = count or len(directions) or 1`, clamp 4 with note `"Asked for {n} variants; the maximum is 4."`; `variants = [{"direction": d, "suggestions": []}]` with directions padded by repeating the last one (or `""`) → `{action, board_id, variants, extra_directions: [], copy_layers: True}`.
    - propose_kv_sizes (`{"add_sizes"}`, `boards`, fallback True, plan): `sizes` non-empty, ≤ 20, each a non-empty string or `{width, height}` ints 64..8192 → `{action, board_ids, sizes}`.

- [ ] **Step 1: Failing tests**
`test_board_actions.py` (a fake surface with boards A, B, a registry-free `board_action` map; neutral):
- `test_unmounted_board_action_hands_off` (allowed excludes it).
- `test_file_scope_needs_no_board` (arrange → write, no targets).
- `test_stated_board_writes` / `test_one_board_scope_with_two_boards_hands_off`.
- `test_deictic_source_uses_fallback_board` (source active_board, no ids, fallback → A).
- `test_sole_board_is_used` (one known board, source none, no fallback).
- `test_board_action_skips_layer_rules` (no references needed).
`test_canvas_intent_board_surface.py` (p0 inventory from `evals/golden/kv_canvas/p0.json`):
- `test_resolve_board_by_id_and_label` (`"v7"` → `gen_f`, `"concept a"` → `gen_a`, `"Nope"` → None).
- `test_resolve_board_ambiguous_label_is_none` (two boards named "Concept A"; Review Focus 1) and the validator then asks/hands off, never writes.
- `test_sanitize_maps_labels_to_ids` (`Targets(board_ids=["V7"])` → `["gen_f"]`).
- `test_duplicate_build` (count 2 names → one `duplicate_kv_board` call args as above).
- `test_variant_build_clamps_with_note` (count 6 → 4 variants, note contains "maximum is 4").
- `test_sizes_build_and_reject_empty`.
- `test_flag_off_surface` (Review Focus 2): `capabilities=()` → `intent_instructions() == ""`, `allowed_actions()` has no board action, decide("duplicate", V7) → handoff.
- `test_variant_decision_without_mounted_tool_hands_off_before_any_chip` (Review Focus 5): `run_live` with `capabilities` including `propose_kv_variants` (decision write) but `tools` lacking it → no frames yielded, `out.handled is False`.
- `test_resolver_instructions_unchanged_when_flag_off`: the agent built for a surface with no capabilities has `instructions == INSTRUCTIONS`.
`test_validator.py`: FakeSurface implements the new methods (`resolve_board` = identity on A/B, `board_action` → None); all existing tests stay green.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** per Interfaces.
- [ ] **Step 4: Run** `tests/agents/canvas_intent tests/agents/kv_generator/test_canvas_intent_*.py tests/agents/kv_generator/test_agent_canvas_*.py tests/tools` → PASS.
- [ ] **Step 5: Commit** `feat(ai): intent layer board actions routed through the capability registry (P1 TASK-5)`.

---

### Task 6: Which-board card + count clamp reply (TASK-6)

**Files:**
- Modify: `app/agents/canvas_intent/validator.py` (rule 5 asks), `app/agents/kv_generator/canvas_intent_surface.py`, `app/agents/kv_generator/canvas_intent_turn.py` (`_LEAD_IN` for the board card)
- Test: `tests/agents/kv_generator/test_canvas_intent_board_surface.py`, `tests/agents/canvas_intent/test_board_actions.py`

**Interfaces:**
- Produces:
  - `which_board_card(action)` → `Card(purpose="targets", label="Which board?", options=…)`: one option per board, active first, then inventory order, at most `WHICH_BOARD_MAX = 5`; option `{"id": f"board:{board_id}", "label": board label, "description": "<n sizes>"}` (through `question_card_payload`, so ids are lowercased). None when < 2 boards.
  - `option_targets("board:<id>")` matches board ids case-insensitively → `Targets(board_ids=[real_id], source="stated")`.
  - validator step 5: no board → `_ask_board(surface, action, reason)` (card with ≥ 2 options, else handoff).
  - `CanvasIntentTurn` lead-in for a `targets` card whose label is "Which board?": `("board","id")`: `"Board yang mana?"`, `("board","en")`: `"Which board should I use?"` (chosen by card label so the P0 target card copy is unchanged).
  - Clamp: the note from Task 5 reaches the reply (`REPLY_INSTRUCTIONS`) and `_plain_reply`.

- [ ] **Step 1: Failing tests**
- `test_variant_without_source_asks_which_board` (AC-11): p0 inventory with `active.board_id = None`, no selection, intent variant source none → `Decision(kind="ask")`, `card.purpose == "targets"`, option ids start with `board:` and ≤ 5.
- `test_variant_uses_selection_board_then_active` (FR-26): selected `LF_vso` with active `gen_a` → board `gen_f`; no selection → `gen_a`.
- `test_which_board_answer_maps_lowercased_id_back` (Review Focus 3): `CardAnswer(option_ids=["board:01m57rf3tah915jbbfyqswntbf"], purpose="targets", …)` with a board id stored upper-case in a test inventory → the write targets the real id.
- `test_rename_with_no_board_asks_on_multi_board_file`.
- `test_clamp_note_reaches_plain_reply`: `_plain_reply([{"result": {...applied 1...}, "note": "Asked for 6 copies; the maximum is 4 per request, so 4 were made."}], "en")` ends with that note.
- `test_reply_instructions_carry_notes`: `run_live` with a fake reply agent capturing instructions → the fenced tool_results include the note.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `tests/agents/canvas_intent tests/agents/kv_generator` (compare against baseline) → no new failures.
- [ ] **Step 5: Commit** `feat(ai): which-board card + 4-board clamp for KV board intents (P1 TASK-6)`.

---

### Task 7: Structure golden cases (TASK-7)

**Files:**
- Create: `evals/golden/kv_canvas/structure.json`
- Modify: `evals/surface_runner/kv_canvas.py` (surface `capabilities` from the golden file; `active_board_id: null` honoured; board-tool scoring)
- Test: `tests/evals/test_structure_scoring.py` (offline: scoring + golden-file shape)

**Interfaces:**
- Consumes: Tasks 5–6 surface + decision.
- Produces:
  - golden top-level `"capabilities"`: all six registry names; `inventory_ref: "p0.json"`; `scoring.pass_threshold: "≥90% (NFR-7, AC-14)"`.
  - `expect` for a board write: `{"kind": "intent", "decision": "write", "action": …, "calls": [{"tool": …, "args": {…}}], "note": true?}`; `score_writes` gets a `calls` branch: same number of calls, each expected call matched by tool + every expected arg key (strings compared stripped + casefolded, lists of strings as casefolded lists — sets for `board_ids` / `sizes`, `variants` compared by length via `"variant_count"`), and `note: true` requires a non-empty `note` on some call (decision-level ToolCall; the runner passes `call.note` through).
  - `_case_inventory`: `"active_board_id" in case` (even null) overrides.
  - `KvCanvasEval._run_intent`: `KvCanvasIntentSurface(..., capabilities=self.golden.get("capabilities") or [])`.
  - Cases (p0 inventory boards: gen_a Concept A, gen_b Concept B, gen_c Copy of V1, gen_d Variant 5, gen_e Playful Flat-lay Key Visual, gen_f V7, 01m57… Variant 6):
    S01 "Duplicate V7 twice, name them Ramadan and Lebaran" → duplicate gen_f count 2 names [Ramadan, Lebaran];
    S02 "duplikat board ini" (active gen_b) → duplicate gen_b count 1;
    S03 "Rename Variant 5 to Lebaran Sale" → rename gen_d "Lebaran Sale";
    S04 "rapikan semua board jadi grid" → arrange grid;
    S05 "Hide Copy of V1 and Variant 5" → hide [gen_c, gen_d] hidden true;
    S06 "Show Variant 5 again" → hide [gen_d] hidden false;
    S07 "Generate 3 variants of V7 with different backgrounds" → propose_kv_variants gen_f variant_count 3;
    S08 "Add Instagram Story and Shopee Banner sizes to Concept A" → propose_kv_sizes [gen_a] sizes {instagram story, shopee banner};
    S09 "duplicate Concept B 6 times" → duplicate gen_b count 4 + note;
    S10 "bikin 6 variasi dari V7" → variants gen_f variant_count 4 + note;
    S11 "Generate variants" (active null, no selection) → ask card targets;
    S12 "rename the playful flat-lay board to Hero" → rename gen_e "Hero" (label);
    S13 "arrange the boards in a row" → arrange row;
    S14 "duplicate this" (selected LF_vso, active gen_a) → duplicate gen_f;
    S15 "Hide this board" (active gen_d) → hide [gen_d] hidden true;
    S16 "make the Concept A headline bigger" → write update_kv_layers LA_head on gen_a set rect (regression: layer action not stolen).

- [ ] **Step 1: Failing tests** (offline, no LLM): `score_intent` on hand-built Decisions — pass for the right duplicate call; fail on a wrong board, wrong count, missing note, extra call; the golden file loads, every case id unique, every board id in an `expect` exists in p0 inventory.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** the scoring + golden file.
- [ ] **Step 4: Run** offline tests → PASS. Then live (needs the `.env` internal model tier):
  `AGNO_TELEMETRY=false ../../.venv/bin/python -m evals.surface_runner --golden structure.json --trials 3 --report docs/evals/kv-agentic-canvas-p1-structure.md` → TOTAL ≥ 90%. And the flag-off regression: `--golden intent-seed.json --trials 1` → ≥ 90% (unchanged). If the model tier is unreachable, record that and stop at the offline proof.
- [ ] **Step 5: Commit** `feat(ai): KV structure golden cases + board-tool scoring (P1 TASK-7)` (include the report when produced).

---

### Wrap-up

- [ ] Tick TASK-1..7 in `docs/tracks/kv-agentic-canvas-p1.track.md`, set Implementation `in_progress (Round A done)`, append a `### 2026-10-22 — daffa (frndos-implement)` session-log entry; commit `docs(ai): KV agentic canvas P1 Round A — track`.
- [ ] Full suite vs baseline (`48 failed / 1 collection error` at 8bcab217): no new failures.
- [ ] One superpowers:requesting-code-review pass; fix Critical + Important.

## Contract deviations

None planned. Notes for the lead:
- `unhide_kv_boards` (service PRD) is `hide_kv_boards {hidden: false}`, per S10's single tool name.
- `AgentCanvas.tools` is new on the ai-service side (the service PRD calls it existing); api TASK-10 sends it.
- Hidden boards are not in the C3.2 inventory, so `show_board` can only target a board the user names by an id/label still in the inventory; otherwise it hands off to the agent.
- `variant` / `add_sizes` decisions are built in Round A (golden-scored) but hand off at runtime until Round B mounts `propose_kv_variants` / `propose_kv_sizes`.
