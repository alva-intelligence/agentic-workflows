# Studio Run Engine P1 — ai-service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two background endpoints for Studio node runs — Text generator and brief reading — that return structured results to api by callback, with every failure reported as a code.

**Architecture:** `app/agents/studio_run/` router (`prefix="/ai/studio/runs"`), modelled on `app/agents/projects/artifact_generate.py` `/generate`: `verify_internal`, 202 + `BackgroundTask`, one-shot Agno `Agent(output_schema=…)`, callback to api with the per-run nonce. Document text comes from a helper extracted out of `brief_decoder` so both share one parser path.

**Tech Stack:** FastAPI, Agno, pydantic v2, httpx, pytest.

**Spec:** `docs/superpowers/specs/2026-10-21-studio-run-engine-p1-design.md`. **Contracts:** `docs/superpowers/plans/2026-10-21-studio-run-engine-p1-contracts.md` (C4, C5 binding).

## Global Constraints

- Repo `ai-service/`, branch `feature/daffa/vc-studio-canvas`. Never push. Commits `feat(ai): …` + `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Tests: `source .venv/bin/activate && pytest tests/<paths> -q`. Never `uv sync` (installs come from `requirements.txt`). 16 failures in `tests/agents/{chat_agent,kv_generator}` pre-date this work — do not chase them; compare against a HEAD baseline if in doubt (never `git stash`).
- Reuse, don't add an integration: `app.agents._agent_defaults.Agent`; model via `internal_model("workhorse")` (any `VendorChat` must pass `**OPENAI_PLATFORM_ENUM[provider]`); check `RunStatus.error` after every run.
- Every `agent.arun` is wrapped in `asyncio.wait_for(…, timeout=STUDIO_RUN_LLM_TIMEOUT_SECONDS)` (new config, default 90).
- Tracing: `set_ai_context(user_id, user_email, workspace_id, workspace_name, brand_id, brand_name)` then `tracing_post_hooks(feature="studio_text_generator" | "studio_brief_read", properties={"run_id": …, "preset": …})`.
- Callback URL must pass `same_origin(callback_url, API_INTERNAL_URL)`; otherwise the run is dropped and logged (no request sent).
- Callback `detail` is internal (logged by api only), truncated to 500 chars; never include API keys or full prompts.

## Review Focus

1. A provider that hangs → `timeout` callback within `STUDIO_RUN_LLM_TIMEOUT_SECONDS + 5 s`, not a 10-minute stall.
2. The model returns 5 items when 6 were asked → api still gets exactly 6 or a `generation_failed`, never a short list presented as success. (Decision: one retry with a corrective message, then `generation_failed`.)
3. A scanned PDF with no text layer → `unreadable_document`, not an empty brief.
4. The callback POST itself fails (api down) → retried 3× with backoff, then logged; never raises out of the background task.
5. Brand knowledge absent → prompt contains no invented brand facts (the `_brand_hint` guard), not a crash.

---

### Task 1: Shared document text helper (extract, no behaviour change)

**Files:** Create `app/agents/shared/document_text.py`. Modify `app/agents/projects/brief_decoder/service.py` (`_fetch_brief_text` calls the helper). Test `tests/agents/shared/test_document_text.py`.

**Interfaces:** `@dataclass DocumentText(text: str, pages: int | None)`; `async def read_document_text(url: str, file_name: str) -> DocumentText` — pdf → `parse_pdf` + `_with_page_markers` (moved here, same behaviour), docx → python-docx paragraphs (`pages=None`), pptx → `parse_pptx`; unknown extension → pdf attempt (as today).

- [ ] **Step 1: Failing tests:** `_with_page_markers` cases moved/added (two pages → `--- Page 1 ---`/`--- Page 2 ---`; length mismatch → text unchanged); `read_document_text` with `parse_pdf` monkeypatched returns markers + `pages == 2`; docx fixture bytes served by `httpx.MockTransport`/respx returns paragraph text.
- [ ] **Step 2: Run, expect FAIL** (module missing).
- [ ] **Step 3: Implement; switch brief_decoder to it.**
- [ ] **Step 4: Run new tests + `tests/agents/projects` (brief decoder) — PASS.**
- [ ] **Step 5: Commit** `refactor(ai): share document text reading with studio runs`.

### Task 2: Text generator endpoint

**Files:** Create `app/agents/studio_run/__init__.py`, `schemas.py`, `router.py`, `text_generate.py`, `callback.py`. Modify `main.py` (`app.include_router(studio_run_router)`), `app/utils/config.py` (`STUDIO_RUN_LLM_TIMEOUT_SECONDS`). Test `tests/agents/studio_run/test_text_generate.py`.

**Interfaces:**
- `schemas.py`: `TextGenerateRequest` (C4, `model_config = ConfigDict(extra="forbid")`; `preset: Literal["none","directions","taglines","captions"]`, `output: Literal["text","list"]`, `count: conint(ge=1, le=10)`, `context: list[ContextItem]` min 1, `brand: BrandBlock | None`); `RunAccepted(run_id, status="accepted")`; per-preset output models: `DirectionItem(title, rationale, prompt)`, `TaglineItem(tagline)`, `CaptionItem(format, caption)`, `FreeText(text)`; `PRESET_SCHEMAS: dict[str, type[BaseModel]]` (list wrappers `items: list[...]`).
- Mapping to C5 `text_list` items `{title, body, prompt}`: directions → `{title, body: rationale, prompt}`; taglines → `{title: tagline, body: "", prompt: ""}`; captions → `{title: format, body: caption, prompt: ""}`; none/text → one item `{title: "", body: text, prompt: ""}`.
- `callback.py`: `async def post_result(callback_url: str, nonce: str, body: dict) -> None` — headers `X-Internal-Token`, `X-Studio-Run-Nonce`; 3 attempts, backoff 1/3/9 s; swallows + logs final failure.
- `text_generate.py`: `async def run_text_generate(req: TextGenerateRequest) -> None` — builds instructions (preset role, the brief/context blocks labelled, brand block or `_brand_hint`-style guard, "exactly {count}"), runs the agent with timeout; wrong count → one corrective re-run; `asyncio.TimeoutError` → `failed/timeout`; `RunStatus.error` or validation error → `failed/generation_failed`; success → `succeeded` with `{kind:"text_list", items}`.
- `router.py`: `POST /ai/studio/runs/text-generate` → `verify_internal(x_internal_token)`; bad callback origin → 422 `{detail:"callback_url not allowed"}`; else `background.add_task(run_text_generate, req)`; 202 `RunAccepted`.

- [ ] **Step 1: Failing tests** (stub Agent class as in `tests/test_artifact_generate.py`; capture `post_result` calls): 202 + background scheduled; missing token → 401/403 as `verify_internal` does; extra field → 422; directions count 6 → callback `succeeded` with 6 mapped items; stub returns 5 then 6 → one retry, success; 5 twice → `failed/generation_failed`; stub sleeps past a patched 0.05 s timeout → `failed/timeout`; `RunStatus.error` → `failed/generation_failed` and `detail` ≤ 500 chars; brand null → instructions contain the no-invention guard; `post_result` failing 3× → no exception escapes.
- [ ] **Step 2: Run, expect FAIL.** **Step 3: Implement.** **Step 4: PASS.**
- [ ] **Step 5: Commit** `feat(ai): studio text generator run endpoint`.

### Task 3: Brief reading endpoint

**Files:** Create `app/agents/studio_run/brief_read.py`; modify `schemas.py`, `router.py`. Test `tests/agents/studio_run/test_brief_read.py`.

**Interfaces:**
- `BriefReadRequest` (C4, `extra="forbid"`; `source.kind: Literal["pdf","docx","text"]`, `source.origin: Literal["upload","lark","typed"]`; url required for pdf/docx, text required for text).
- `StudioBriefFields` output model: `fields: list[BriefFieldOut(key, label, value, page: int | None)]` with the keys of the prototype field set (`campaign, product, audience, funnel, …` — copy the exact key/label list from `web/src/lib/node-studio/fixtures/brief.ts` `BRIEF_FIXTURE_FIELDS` as the schema's allowed keys; missing in the brief → `value: ""`), `formats: list[str]`.
- `async def run_brief_read(req) -> None`: text from `read_document_text` (pdf/docx) or `req.source.text`; stripped text < 20 chars → `failed/unreadable_document`; fetch/parse error → `failed/unreadable_document`; field extraction agent (timeout + `RunStatus.error` rules as Task 2) → `succeeded` `{kind:"brief", file_name, pages, text, fields, formats}`.
- Route `POST /ai/studio/runs/brief-read` (same guards as Task 2).

- [ ] **Step 1: Failing tests:** pdf with patched `read_document_text` → `succeeded` with page-cited fields and `pages`; empty text → `unreadable_document`; parse raises → `unreadable_document` (detail logged); typed text → fields with `page: null`; unknown field key from the model → dropped; timeout → `timeout`.
- [ ] **Step 2: FAIL. Step 3: Implement. Step 4: PASS** (plus Task 1/2 tests).
- [ ] **Step 5: Commit** `feat(ai): studio brief reading run endpoint`; append a session-log entry to `docs/tracks/` if this repo has a studio-canvas track, and add P1 tasks to `docs/prd/studio-canvas.md`.
