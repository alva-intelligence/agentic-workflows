# KV agent plan image model — ai-service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Forward the turn's picked image model from `agent_canvas.image_model` to api in the `propose_kv_*` callback body, so the plan card is priced for that model.

**Architecture:** A pure pass-through. `AgentCanvas` gets an optional `image_model`, `make_kv_structure_tools` puts it on `KvToolContext`, and `_propose` adds it to the plan-route body when it is set. ai-service never validates or interprets it; api does.

**Tech Stack:** FastAPI, Pydantic v2, pytest.

**Spec:** `docs/superpowers/specs/2026-10-23-kv-agent-plan-image-model-design.md` (§4.3 step 2)

**Branch:** `feature/daffa/vc-kv-agent-plan-image-model` in `ai-service/`, from latest `development`.

## Global Constraints

- `image_model` is sent **only** on the plan-proposal POST (`mcp/tools/kv/canvas/{fid}/plans`), and only when the context has a non-empty value. `KvToolContext.body()` stays exactly as it is for every other call.
- `AgentCanvas.image_model` is optional (`None` by default). A payload without it parses exactly as today.
- Install and run from `requirements.txt` with the service's own venv. Never `uv sync`. Compare test results against the HEAD baseline (16 known reds in `tests/agents/{chat_agent,kv_generator}`), using a HEAD worktree and never `git stash`.

## Review Focus

1. **`agent_canvas.image_model` is `null` or `""`:** nothing is sent (Task 1 test).
2. **`propose_kv_sizes` shares `_propose`:** it forwards the model too, by design; api ignores it (Task 1 test pins the forwarding so nobody "fixes" it into a divergence).
3. **A non-propose canvas write** (e.g. `run_kv_plan_step`) must not gain the field (Task 1 test).

---

### Task 1: Pass the picked model through to the propose callback

**Files:**
- Modify: `app/agents/kv_generator/request_schema.py` (`AgentCanvas`: `image_model: Optional[str] = None`)
- Modify: `app/tools/kv_canvas_capability.py` (`KvToolContext.image_model: str = ""`; the `make_kv_structure_tools(..., image_model: str | None = None)` keyword)
- Modify: `app/tools/kv_plan_tools.py` (`_propose`: `extra["image_model"] = ctx.image_model` when it is truthy)
- Modify: `app/agents/kv_generator/service.py` (~L466: pass `image_model=canvas.image_model`)
- Test: `tests/agents/kv_generator/test_agent_canvas_schema.py`, `tests/tools/test_kv_plan_tools.py`

**Interfaces:**
- Consumes (from api): `agent_canvas.image_model?: string`
- Produces (to api): the plan-proposal body `image_model?: string`

- [ ] **Step 1: Write the failing tests**
  - Schema: `AgentCanvas.model_validate({...minimal, "image_model": "gpt-image-2"}).image_model == "gpt-image-2"`, and without the key it is `None`.
  - Tools (the existing `respx_mock` + `_body(route)` pattern in `test_kv_plan_tools.py`; extend the `_tools(...)` helper with an `image_model=None` kwarg forwarded to `make_kv_structure_tools`; existing exact-body assertions must stay green unchanged):
    - `test_propose_concepts_forwards_image_model`: a context built with `image_model="gpt-image-2"` → the captured plans-POST body has `image_model == "gpt-image-2"`.
    - `test_propose_sizes_forwards_image_model`: the same for `propose_kv_sizes`.
    - `test_propose_omits_image_model_when_unset`: `image_model` of `None` and `""` (parametrised) → `"image_model" not in body`.
    - `test_run_plan_step_body_has_no_image_model`: a context with `image_model="gpt-image-2"` → the `plans/steps/run` body has no `image_model`.

- [ ] **Step 2: Run, expect FAIL**

Run: `source .venv/bin/activate && pytest tests/agents/kv_generator/test_agent_canvas_schema.py tests/tools/test_kv_plan_tools.py -q`

- [ ] **Step 3: Implement** the four modifications above.

- [ ] **Step 4: Run, expect PASS.** Then run `tests/tools tests/agents/kv_generator -q` and diff the failures against the HEAD baseline: no new reds.

- [ ] **Step 5: Commit** — `feat(ai): forward the picked image model on KV plan proposals`

---

### Task 2: Docs

**Files:**
- Modify: `docs/prd/kv-agentic-canvas-p1-1.md`: a one-paragraph "Image model (amendment 2026-10-23)" note: `agent_canvas.image_model` is forwarded on proposals, with a link to the spec.
- Modify: `docs/tracks/kv-agentic-canvas-p1-1.track.md`: a session-log entry.

- [ ] **Step 1: Write the doc edits**
- [ ] **Step 2: Commit** — `docs(ai): note agent_canvas.image_model pass-through`
