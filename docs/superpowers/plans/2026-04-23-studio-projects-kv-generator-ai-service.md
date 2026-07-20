# Studio Projects & KV Generator — AI Service (FastAPI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a new `kv_generator` agent with streaming SSE output that honors Chat vs. Image modes, injects project brief + optional brand knowledge as AI context, orchestrates image generation through the existing `image_generation` service, and calls back to the API when a generation completes.

**Architecture:** New agent module at `app/agents/kv_generator/` with clean separation: `router.py` (FastAPI endpoint) → `service.py` (orchestration) → `context_builder.py` (fetch + build system prompt) + `prompts/` + `api_client.py`. Streaming uses the same pattern as existing streaming endpoints (SSE via StreamingResponse). Mode routing happens in `service.py`.

**Tech Stack:** FastAPI, Pydantic, httpx (for API callbacks), pytest + pytest-asyncio, existing `app/services/image_generation.py`, existing brand knowledge agent output.

**Spec reference:** [docs/superpowers/specs/2026-04-23-studio-projects-kv-generator-design.md](docs/superpowers/specs/2026-04-23-studio-projects-kv-generator-design.md)

**Depends on:** API plan Task 17 (internal project-fetch endpoint) + Task 15 (internal generation-complete callback).

---

## File Structure

```
ai-service/app/agents/kv_generator/
  __init__.py
  request_schema.py        StreamRequest Pydantic model
  response_schema.py       SSE event payload types
  api_client.py            httpx client → GET project, POST generation-complete
  context_builder.py       fetches project + brand knowledge, builds system prompt
  prompts/
    __init__.py
    base.py                shared role / tone
    chat_mode.py           chat-mode-specific system prompt
    image_mode.py          image-mode-specific system prompt
  service.py               main orchestration + mode router
  router.py                FastAPI router: POST /ai/kv-generator/stream
  events.py                SSE event emitter helpers

ai-service/tests/agents/kv_generator/
  __init__.py
  conftest.py
  test_context_builder.py
  test_service_chat_mode.py
  test_service_image_mode.py
  test_router.py
```

Also modify:
- `ai-service/main.py` → include new router
- `ai-service/app/utils/config.py` → add `API_INTERNAL_URL`, `API_INTERNAL_TOKEN`
- `ai-service/.env.example` → document new env vars

---

## Task 1 — Stub the module + schemas

**Files:**
- Create: `ai-service/app/agents/kv_generator/__init__.py`
- Create: `ai-service/app/agents/kv_generator/request_schema.py`
- Create: `ai-service/app/agents/kv_generator/response_schema.py`

- [ ] **Step 1: Write the failing test**

File: `ai-service/tests/agents/kv_generator/test_schemas.py`

```python
from app.agents.kv_generator.request_schema import KvStreamRequest, LaunchContext
from app.agents.kv_generator.response_schema import (
    ThinkingEvent, QuestionCardEvent, GenerationDoneEvent, ModeSuggestionEvent,
)


def test_launch_context_has_expected_fields():
    ctx = LaunchContext(
        project_id="p1",
        studio_file_id="f1",
        use_brand_knowledge=True,
        brand_id="b1",
    )
    assert ctx.project_id == "p1"
    assert ctx.use_brand_knowledge is True


def test_stream_request_minimal_body():
    req = KvStreamRequest(
        thread_id="t1",
        studio_file_id="f1",
        mode="chat",
        prompt="hello",
        launch_context=LaunchContext(
            studio_file_id="f1",
            use_brand_knowledge=False,
            brand_id="b1",
        ),
        chat_history=[],
    )
    assert req.mode == "chat"


def test_events_have_event_field():
    e = ThinkingEvent(chunk="thinking...")
    assert e.event == "thinking"
    assert QuestionCardEvent(label="pick", options=[]).event == "question_card"
    assert ModeSuggestionEvent(from_="chat", to="image", reason="ready").event == "mode_suggestion"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ai-service && pytest tests/agents/kv_generator/test_schemas.py -v`
Expected: FAIL — modules don't exist.

- [ ] **Step 3: Create schemas**

File: `ai-service/app/agents/kv_generator/__init__.py` — empty file.

File: `ai-service/app/agents/kv_generator/request_schema.py`

```python
from typing import List, Literal, Optional, Any, Dict

from pydantic import BaseModel, Field


class LaunchContext(BaseModel):
    project_id: Optional[str] = None
    studio_file_id: str
    use_brand_knowledge: bool = False
    brand_id: str


class ChatMessage(BaseModel):
    role: Literal["user", "assistant", "system"]
    content: str
    metadata: Optional[Dict[str, Any]] = None


class KvStreamRequest(BaseModel):
    thread_id: str
    studio_file_id: str
    mode: Literal["chat", "image"] = "chat"
    prompt: str
    launch_context: LaunchContext
    chat_history: List[ChatMessage] = Field(default_factory=list)
    attached_generation_id: Optional[str] = None
    style_preset_id: Optional[str] = None
    aspect_ratio: Optional[str] = None
    user_id: str
```

File: `ai-service/app/agents/kv_generator/response_schema.py`

```python
from typing import Any, Dict, List, Literal, Optional

from pydantic import BaseModel, Field


class BaseEvent(BaseModel):
    event: str


class ThinkingEvent(BaseEvent):
    event: Literal["thinking"] = "thinking"
    chunk: str


class MessageEvent(BaseEvent):
    event: Literal["message"] = "message"
    text: str
    chat_message_id: Optional[str] = None


class QuestionCardOption(BaseModel):
    id: str
    label: str
    thumbnail_url: Optional[str] = None


class QuestionCardEvent(BaseEvent):
    event: Literal["question_card"] = "question_card"
    label: str
    options: List[QuestionCardOption]


class ModeSuggestionEvent(BaseEvent):
    event: Literal["mode_suggestion"] = "mode_suggestion"
    from_: Literal["chat", "image"] = Field(alias="from")
    to: Literal["chat", "image"]
    reason: str

    class Config:
        populate_by_name = True


class GeneratingEvent(BaseEvent):
    event: Literal["generating"] = "generating"
    stage: Literal["prompt_expanded", "image_rendering", "finalizing"]
    estimated_ms: Optional[int] = None


class GenerationDoneEvent(BaseEvent):
    event: Literal["generation_done"] = "generation_done"
    generation: Dict[str, Any]  # full KvGenerationResource shape


class GenerationFailedEvent(BaseEvent):
    event: Literal["generation_failed"] = "generation_failed"
    error_code: str
    message: str
    placeholder_id: Optional[str] = None


class DoneEvent(BaseEvent):
    event: Literal["done"] = "done"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ai-service && pytest tests/agents/kv_generator/test_schemas.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ai-service/app/agents/kv_generator/ ai-service/tests/agents/kv_generator/
git commit -m "feat(ai-service): scaffold kv_generator module and schemas"
```

---

## Task 2 — API client (httpx): fetch project, post callback

**Files:**
- Create: `ai-service/app/agents/kv_generator/api_client.py`

- [ ] **Step 1: Write the failing test**

File: `ai-service/tests/agents/kv_generator/test_api_client.py`

```python
import pytest
from respx import MockRouter

from app.agents.kv_generator.api_client import ApiClient


@pytest.mark.asyncio
async def test_fetches_project_with_signed_header(respx_mock: MockRouter):
    route = respx_mock.get("https://api.test/api/internal/studio/projects/p1").respond(
        json={"data": {
            "id": "p1",
            "name": "Camp A",
            "description": "brief",
            "use_brand_knowledge": True,
            "brand_id": "b1",
        }}
    )

    client = ApiClient(base_url="https://api.test", internal_token="tkn")
    project = await client.get_project("p1")

    assert project["name"] == "Camp A"
    assert route.calls[0].request.headers["x-internal-token"] == "tkn"


@pytest.mark.asyncio
async def test_posts_generation_complete(respx_mock: MockRouter):
    route = respx_mock.post(
        "https://api.test/api/internal/kv-generator/generation-complete"
    ).respond(status_code=201, json={"data": {"id": "g1", "version_number": 1}})

    client = ApiClient(base_url="https://api.test", internal_token="tkn")
    gen = await client.post_generation_complete({
        "studio_file_id": "f1",
        "image_url": "https://s/img.png",
        "prompt_snapshot": "p",
        "model": "m",
        "created_by": "u1",
    })

    assert gen["id"] == "g1"
    assert route.called
```

Add `respx` + `pytest-asyncio` to test requirements if not present:

Edit: `ai-service/requirements-dev.txt` (create if missing):

```
pytest
pytest-asyncio
respx
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ai-service && pytest tests/agents/kv_generator/test_api_client.py -v`
Expected: FAIL — ApiClient doesn't exist.

- [ ] **Step 3: Create api_client**

File: `ai-service/app/agents/kv_generator/api_client.py`

```python
from typing import Any, Dict, Optional

import httpx


class ApiClient:
    """Client for the KV generator's internal API calls."""

    def __init__(self, base_url: str, internal_token: str, timeout: float = 10.0):
        self._base_url = base_url.rstrip("/")
        self._headers = {"X-Internal-Token": internal_token}
        self._timeout = timeout

    async def get_project(self, project_id: str) -> Optional[Dict[str, Any]]:
        async with httpx.AsyncClient(timeout=self._timeout, headers=self._headers) as client:
            response = await client.get(
                f"{self._base_url}/api/internal/studio/projects/{project_id}"
            )
            if response.status_code == 404:
                return None
            response.raise_for_status()
            return response.json().get("data")

    async def post_generation_complete(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        async with httpx.AsyncClient(timeout=self._timeout, headers=self._headers) as client:
            response = await client.post(
                f"{self._base_url}/api/internal/kv-generator/generation-complete",
                json=payload,
            )
            response.raise_for_status()
            return response.json().get("data", {})
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ai-service && pytest tests/agents/kv_generator/test_api_client.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ai-service/app/agents/kv_generator/api_client.py \
       ai-service/tests/agents/kv_generator/test_api_client.py \
       ai-service/requirements-dev.txt
git commit -m "feat(ai-service): add KV generator internal API client"
```

---

## Task 3 — Context builder: load project + brand knowledge

**Files:**
- Create: `ai-service/app/agents/kv_generator/context_builder.py`

- [ ] **Step 1: Write the failing test**

File: `ai-service/tests/agents/kv_generator/test_context_builder.py`

```python
from unittest.mock import AsyncMock

import pytest

from app.agents.kv_generator.context_builder import build_system_prompt
from app.agents.kv_generator.request_schema import LaunchContext


@pytest.mark.asyncio
async def test_system_prompt_without_project_scope():
    api = AsyncMock()
    ctx = LaunchContext(studio_file_id="f1", use_brand_knowledge=False, brand_id="b1")

    prompt = await build_system_prompt(
        mode="chat", launch_context=ctx, api_client=api,
    )

    assert "You are a KV" in prompt
    assert "Project:" not in prompt
    assert "Brand:" not in prompt
    api.get_project.assert_not_called()


@pytest.mark.asyncio
async def test_system_prompt_with_project_and_brand_knowledge():
    api = AsyncMock()
    api.get_project.return_value = {
        "id": "p1",
        "name": "CIMB × XG",
        "description": "Savings campaign for Gen Z",
        "use_brand_knowledge": True,
        "brand_id": "b1",
    }

    # Mock brand knowledge fetch (to be defined — stub returns dict)
    api.get_brand_knowledge = AsyncMock(return_value={
        "dna": "Playful, trustworthy",
        "identity": "Clean type, bold color",
        "tonality": "Warm, confident",
        "brand_name": "CIMB",
    })

    ctx = LaunchContext(
        project_id="p1", studio_file_id="f1",
        use_brand_knowledge=True, brand_id="b1",
    )

    prompt = await build_system_prompt(
        mode="image", launch_context=ctx, api_client=api,
    )

    assert "CIMB × XG" in prompt
    assert "Savings campaign for Gen Z" in prompt
    assert "CIMB" in prompt
    assert "Playful, trustworthy" in prompt
    assert "Current mode: image" in prompt


@pytest.mark.asyncio
async def test_brand_knowledge_skipped_when_toggle_off():
    api = AsyncMock()
    api.get_project.return_value = {
        "id": "p1", "name": "Camp", "description": None,
        "use_brand_knowledge": False, "brand_id": "b1",
    }
    api.get_brand_knowledge = AsyncMock()

    ctx = LaunchContext(
        project_id="p1", studio_file_id="f1",
        use_brand_knowledge=False, brand_id="b1",
    )
    prompt = await build_system_prompt(mode="chat", launch_context=ctx, api_client=api)

    assert "Brand:" not in prompt
    api.get_brand_knowledge.assert_not_called()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ai-service && pytest tests/agents/kv_generator/test_context_builder.py -v`
Expected: FAIL.

- [ ] **Step 3: Create context_builder + extend api_client**

Edit: `ai-service/app/agents/kv_generator/api_client.py` — add `get_brand_knowledge`:

```python
    async def get_brand_knowledge(self, brand_id: str) -> Optional[Dict[str, Any]]:
        """Fetch structured brand knowledge summary (DNA, identity, tonality).
        Returns None if the brand has no knowledge configured."""
        async with httpx.AsyncClient(timeout=self._timeout, headers=self._headers) as client:
            response = await client.get(
                f"{self._base_url}/api/internal/brands/{brand_id}/knowledge-summary"
            )
            if response.status_code == 404:
                return None
            response.raise_for_status()
            return response.json().get("data")
```

Note: this endpoint should already exist per the spec's reference to the existing `brand_knowledge_extraction` agent's output. If it does not, coordinate with API plan owner to add it. For this plan we assume a response shape of `{ dna: str, identity: str, tonality: str, brand_name: str }`.

Create: `ai-service/app/agents/kv_generator/context_builder.py`

```python
from typing import Literal

from app.agents.kv_generator.api_client import ApiClient
from app.agents.kv_generator.request_schema import LaunchContext
from app.agents.kv_generator.prompts import base, chat_mode, image_mode


async def build_system_prompt(
    *,
    mode: Literal["chat", "image"],
    launch_context: LaunchContext,
    api_client: ApiClient,
) -> str:
    """Build the full system prompt including project brief and (optional) brand knowledge."""
    sections: list[str] = [base.BASE_PROMPT]

    if launch_context.project_id:
        project = await api_client.get_project(launch_context.project_id)
        if project:
            sections.append(f'Project: "{project["name"]}"')
            if project.get("description"):
                sections.append(f'Brief: {project["description"]}')

    if launch_context.use_brand_knowledge and launch_context.brand_id:
        brand = await api_client.get_brand_knowledge(launch_context.brand_id)
        if brand:
            sections.append(_format_brand_block(brand))

    sections.append(f"Current mode: {mode}")
    sections.append(chat_mode.GUIDANCE if mode == "chat" else image_mode.GUIDANCE)

    return "\n\n".join(sections)


def _format_brand_block(brand: dict) -> str:
    name = brand.get("brand_name", "")
    dna = brand.get("dna", "")
    identity = brand.get("identity", "")
    tonality = brand.get("tonality", "")
    return (
        f"Brand: {name}\n"
        f"- DNA: {dna}\n"
        f"- Identity: {identity}\n"
        f"- Tonality: {tonality}"
    )
```

Create: `ai-service/app/agents/kv_generator/prompts/__init__.py` — empty.

Create: `ai-service/app/agents/kv_generator/prompts/base.py`

```python
BASE_PROMPT = (
    "You are a KV (key visual) generator. You help the user create brand-safe "
    "campaign visuals. Respect the brief and brand guidance when generating. "
    "Keep responses concise and focused on the visual outcome."
)
```

Create: `ai-service/app/agents/kv_generator/prompts/chat_mode.py`

```python
GUIDANCE = (
    "In chat mode you may refine the brief, ask clarifying questions, and "
    "suggest directions. You do NOT generate images in this mode. "
    "When the user's intent becomes clear and they seem ready to generate "
    "(explicit cues like 'let's go', 'generate it', or enough attributes are "
    "settled like subject, vibe, and aspect), emit a mode_suggestion event "
    "proposing the switch to image mode. You may also emit question_card "
    "events to help the user pick direction."
)
```

Create: `ai-service/app/agents/kv_generator/prompts/image_mode.py`

```python
GUIDANCE = (
    "In image mode you generate images. If critical attributes are still "
    "ambiguous (style, aspect ratio, primary subject), emit a question_card "
    "first. Otherwise, stream a brief thinking trace, emit a generating event "
    "with stage='prompt_expanded' then stage='image_rendering', then invoke "
    "the image generation pipeline and emit generation_done when the image URL "
    "is persisted."
)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ai-service && pytest tests/agents/kv_generator/test_context_builder.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ai-service/app/agents/kv_generator/context_builder.py \
       ai-service/app/agents/kv_generator/prompts/ \
       ai-service/app/agents/kv_generator/api_client.py \
       ai-service/tests/agents/kv_generator/test_context_builder.py
git commit -m "feat(ai-service): add KV context builder with brief and brand knowledge"
```

---

## Task 4 — SSE event emitter helpers

**Files:**
- Create: `ai-service/app/agents/kv_generator/events.py`

- [ ] **Step 1: Write the failing test**

File: `ai-service/tests/agents/kv_generator/test_events.py`

```python
from app.agents.kv_generator.events import to_sse_line
from app.agents.kv_generator.response_schema import ThinkingEvent, QuestionCardEvent


def test_serializes_thinking_event_as_sse():
    line = to_sse_line(ThinkingEvent(chunk="hi"))
    assert line.startswith("event: thinking\n")
    assert "\ndata: " in line
    assert '"chunk":"hi"' in line
    assert line.endswith("\n\n")


def test_serializes_question_card_event():
    e = QuestionCardEvent(label="pick", options=[])
    line = to_sse_line(e)
    assert line.startswith("event: question_card\n")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ai-service && pytest tests/agents/kv_generator/test_events.py -v`
Expected: FAIL.

- [ ] **Step 3: Create events module**

File: `ai-service/app/agents/kv_generator/events.py`

```python
from app.agents.kv_generator.response_schema import BaseEvent


def to_sse_line(event: BaseEvent) -> str:
    """Serialize a pydantic event as a single SSE frame."""
    data = event.model_dump_json(by_alias=True, exclude={"event"})
    return f"event: {event.event}\ndata: {data}\n\n"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ai-service && pytest tests/agents/kv_generator/test_events.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ai-service/app/agents/kv_generator/events.py \
       ai-service/tests/agents/kv_generator/test_events.py
git commit -m "feat(ai-service): add SSE event serializer for KV generator"
```

---

## Task 5 — Service: chat-mode orchestration

**Files:**
- Create: `ai-service/app/agents/kv_generator/service.py`

- [ ] **Step 1: Write the failing test**

File: `ai-service/tests/agents/kv_generator/test_service_chat_mode.py`

```python
from unittest.mock import AsyncMock

import pytest

from app.agents.kv_generator.request_schema import KvStreamRequest, LaunchContext
from app.agents.kv_generator.service import run_stream


@pytest.mark.asyncio
async def test_chat_mode_emits_thinking_then_message_then_done(monkeypatch):
    api = AsyncMock()
    api.get_project.return_value = {
        "name": "P", "description": "brief",
        "use_brand_knowledge": False, "brand_id": "b1",
    }

    async def fake_llm_stream(system_prompt, history, prompt):
        for chunk in ["Let me ", "think about this"]:
            yield {"kind": "thinking", "chunk": chunk}
        yield {"kind": "message", "text": "How about a bold campaign?"}

    monkeypatch.setattr("app.agents.kv_generator.service._llm_stream", fake_llm_stream)

    req = KvStreamRequest(
        thread_id="t1", studio_file_id="f1", mode="chat",
        prompt="let's brainstorm",
        launch_context=LaunchContext(
            project_id="p1", studio_file_id="f1",
            use_brand_knowledge=False, brand_id="b1"
        ),
        chat_history=[], user_id="u1",
    )

    events = []
    async for line in run_stream(req, api_client=api):
        events.append(line)

    joined = "".join(events)
    assert "event: thinking" in joined
    assert "event: message" in joined
    assert "event: done" in joined
    # No image-mode events in chat mode
    assert "event: generating" not in joined
    assert "event: generation_done" not in joined


@pytest.mark.asyncio
async def test_chat_mode_emits_mode_suggestion_when_llm_proposes(monkeypatch):
    api = AsyncMock()
    api.get_project.return_value = None

    async def fake_llm_stream(system_prompt, history, prompt):
        yield {"kind": "mode_suggestion", "to": "image", "reason": "You sound ready"}

    monkeypatch.setattr("app.agents.kv_generator.service._llm_stream", fake_llm_stream)

    req = KvStreamRequest(
        thread_id="t1", studio_file_id="f1", mode="chat",
        prompt="let's go!",
        launch_context=LaunchContext(
            studio_file_id="f1", use_brand_knowledge=False, brand_id="b1"
        ),
        chat_history=[], user_id="u1",
    )
    events = "".join([line async for line in run_stream(req, api_client=api)])
    assert "event: mode_suggestion" in events
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ai-service && pytest tests/agents/kv_generator/test_service_chat_mode.py -v`
Expected: FAIL.

- [ ] **Step 3: Create service skeleton with chat-mode handling**

File: `ai-service/app/agents/kv_generator/service.py`

```python
from typing import AsyncIterator, Dict, Any

from app.agents.kv_generator.api_client import ApiClient
from app.agents.kv_generator.context_builder import build_system_prompt
from app.agents.kv_generator.events import to_sse_line
from app.agents.kv_generator.request_schema import KvStreamRequest
from app.agents.kv_generator.response_schema import (
    DoneEvent,
    MessageEvent,
    ModeSuggestionEvent,
    QuestionCardEvent,
    ThinkingEvent,
)


async def run_stream(
    request: KvStreamRequest,
    api_client: ApiClient,
) -> AsyncIterator[str]:
    """Main orchestration. Yields SSE frames."""
    system_prompt = await build_system_prompt(
        mode=request.mode,
        launch_context=request.launch_context,
        api_client=api_client,
    )

    if request.mode == "chat":
        async for line in _run_chat_mode(request, system_prompt):
            yield line
    else:
        async for line in _run_image_mode(request, system_prompt, api_client):
            yield line

    yield to_sse_line(DoneEvent())


async def _run_chat_mode(request: KvStreamRequest, system_prompt: str) -> AsyncIterator[str]:
    async for chunk in _llm_stream(system_prompt, request.chat_history, request.prompt):
        kind = chunk.get("kind")
        if kind == "thinking":
            yield to_sse_line(ThinkingEvent(chunk=chunk["chunk"]))
        elif kind == "message":
            yield to_sse_line(MessageEvent(text=chunk["text"]))
        elif kind == "question_card":
            yield to_sse_line(QuestionCardEvent(
                label=chunk["label"],
                options=chunk["options"],
            ))
        elif kind == "mode_suggestion":
            yield to_sse_line(ModeSuggestionEvent(
                **{"from": "chat"},
                to=chunk["to"],
                reason=chunk["reason"],
            ))


async def _run_image_mode(
    request: KvStreamRequest,
    system_prompt: str,
    api_client: ApiClient,
) -> AsyncIterator[str]:
    # Implemented in Task 6
    raise NotImplementedError


async def _llm_stream(system_prompt: str, history, prompt: str):
    """LLM streaming adapter. Integrated with the existing chat LLM backend in Task 7."""
    if False:
        yield {}  # generator signature
    raise NotImplementedError("Wired up in Task 7")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ai-service && pytest tests/agents/kv_generator/test_service_chat_mode.py -v`
Expected: PASS (the tests monkeypatch `_llm_stream`).

- [ ] **Step 5: Commit**

```bash
git add ai-service/app/agents/kv_generator/service.py \
       ai-service/tests/agents/kv_generator/test_service_chat_mode.py
git commit -m "feat(ai-service): add KV generator chat-mode orchestration"
```

---

## Task 6 — Service: image-mode orchestration + callback

**Files:**
- Modify: `ai-service/app/agents/kv_generator/service.py`

- [ ] **Step 1: Write the failing test**

File: `ai-service/tests/agents/kv_generator/test_service_image_mode.py`

```python
from unittest.mock import AsyncMock

import pytest

from app.agents.kv_generator.request_schema import KvStreamRequest, LaunchContext
from app.agents.kv_generator.service import run_stream


@pytest.mark.asyncio
async def test_image_mode_happy_path(monkeypatch):
    api = AsyncMock()
    api.get_project.return_value = {
        "name": "P", "description": "brief",
        "use_brand_knowledge": False, "brand_id": "b1",
    }
    api.post_generation_complete.return_value = {
        "id": "g1", "studio_file_id": "f1", "version_number": 1,
        "image_url": "https://s/img.png", "prompt_snapshot": "p",
        "model": "m", "metadata": {},
        "created_at": "2026-04-23T00:00:00Z",
    }

    async def fake_llm_stream(system_prompt, history, prompt):
        yield {"kind": "thinking", "chunk": "plan"}

    async def fake_render(prompt, ref_image_url=None, params=None):
        return {
            "image_url": "https://s/img.png",
            "thumbnail_url": "https://s/thumb.png",
            "prompt_snapshot": "expanded",
            "model": "gemini-2.5-nano-banana",
            "ai_service_run_id": "run-1",
        }

    monkeypatch.setattr("app.agents.kv_generator.service._llm_stream", fake_llm_stream)
    monkeypatch.setattr("app.agents.kv_generator.service._render_image", fake_render)
    monkeypatch.setattr("app.agents.kv_generator.service._needs_question_card", lambda h, p: False)

    req = KvStreamRequest(
        thread_id="t1", studio_file_id="f1", mode="image",
        prompt="Bold KV please",
        launch_context=LaunchContext(
            project_id="p1", studio_file_id="f1",
            use_brand_knowledge=False, brand_id="b1"
        ),
        chat_history=[], user_id="u1",
    )
    events = "".join([line async for line in run_stream(req, api_client=api)])

    assert "event: thinking" in events
    assert "event: generating" in events
    assert "event: generation_done" in events
    assert "event: done" in events
    api.post_generation_complete.assert_called_once()


@pytest.mark.asyncio
async def test_image_mode_emits_question_card_when_ambiguous(monkeypatch):
    api = AsyncMock()
    api.get_project.return_value = None

    monkeypatch.setattr(
        "app.agents.kv_generator.service._needs_question_card",
        lambda h, p: {"label": "Pick aspect", "options": [
            {"id": "16:9", "label": "16:9"}, {"id": "1:1", "label": "Square"}
        ]},
    )

    async def fake_llm_stream(system_prompt, history, prompt):
        if False:
            yield

    monkeypatch.setattr("app.agents.kv_generator.service._llm_stream", fake_llm_stream)

    req = KvStreamRequest(
        thread_id="t1", studio_file_id="f1", mode="image",
        prompt="Make something",
        launch_context=LaunchContext(
            studio_file_id="f1", use_brand_knowledge=False, brand_id="b1"
        ),
        chat_history=[], user_id="u1",
    )
    events = "".join([line async for line in run_stream(req, api_client=api)])
    assert "event: question_card" in events
    # Should NOT generate when question card is emitted
    assert "event: generation_done" not in events


@pytest.mark.asyncio
async def test_image_mode_generation_failed_is_emitted(monkeypatch):
    api = AsyncMock()
    api.get_project.return_value = None

    async def fake_llm_stream(system_prompt, history, prompt):
        if False: yield

    async def fake_render(*args, **kwargs):
        raise RuntimeError("model down")

    monkeypatch.setattr("app.agents.kv_generator.service._llm_stream", fake_llm_stream)
    monkeypatch.setattr("app.agents.kv_generator.service._render_image", fake_render)
    monkeypatch.setattr("app.agents.kv_generator.service._needs_question_card", lambda h, p: False)

    req = KvStreamRequest(
        thread_id="t1", studio_file_id="f1", mode="image",
        prompt="x",
        launch_context=LaunchContext(
            studio_file_id="f1", use_brand_knowledge=False, brand_id="b1"
        ),
        chat_history=[], user_id="u1",
    )
    events = "".join([line async for line in run_stream(req, api_client=api)])
    assert "event: generation_failed" in events
    assert "event: generation_done" not in events
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ai-service && pytest tests/agents/kv_generator/test_service_image_mode.py -v`
Expected: FAIL — image-mode path not implemented.

- [ ] **Step 3: Implement image mode**

Edit: `ai-service/app/agents/kv_generator/service.py` — replace the `_run_image_mode` stub and add helpers:

```python
from typing import Any, Dict, Optional

from app.agents.kv_generator.response_schema import (
    GeneratingEvent,
    GenerationDoneEvent,
    GenerationFailedEvent,
)


async def _run_image_mode(
    request: KvStreamRequest,
    system_prompt: str,
    api_client: ApiClient,
) -> AsyncIterator[str]:
    # 1. Optional clarifying question
    question = _needs_question_card(request.chat_history, request.prompt)
    if question:
        yield to_sse_line(QuestionCardEvent(
            label=question["label"],
            options=question["options"],
        ))
        return

    # 2. Brief thinking trace
    async for chunk in _llm_stream(system_prompt, request.chat_history, request.prompt):
        if chunk.get("kind") == "thinking":
            yield to_sse_line(ThinkingEvent(chunk=chunk["chunk"]))

    # 3. Generate
    yield to_sse_line(GeneratingEvent(stage="prompt_expanded"))
    yield to_sse_line(GeneratingEvent(stage="image_rendering", estimated_ms=15000))

    try:
        render = await _render_image(
            prompt=request.prompt,
            ref_image_url=None,  # may be resolved from attached_generation_id in a later iteration
            params={
                "aspect_ratio": request.aspect_ratio,
                "style_preset_id": request.style_preset_id,
            },
        )
    except Exception as e:  # noqa: BLE001
        yield to_sse_line(GenerationFailedEvent(
            error_code="render_failed",
            message=str(e),
            placeholder_id=None,
        ))
        return

    yield to_sse_line(GeneratingEvent(stage="finalizing"))

    # 4. Persist via API callback
    generation = await api_client.post_generation_complete({
        "studio_file_id": request.studio_file_id,
        "image_url": render["image_url"],
        "thumbnail_url": render.get("thumbnail_url"),
        "prompt_snapshot": render["prompt_snapshot"],
        "model": render["model"],
        "ai_service_run_id": render.get("ai_service_run_id"),
        "metadata": {
            "aspect_ratio": request.aspect_ratio,
            "style_preset_id": request.style_preset_id,
        },
        "parent_generation_id": request.attached_generation_id,
        "created_by": request.user_id,
    })

    yield to_sse_line(GenerationDoneEvent(generation=generation))


def _needs_question_card(chat_history, prompt) -> Optional[Dict[str, Any]]:
    """Decide whether to ask the user for clarifying attributes before generating.
    Integrated with LLM in Task 7 — default heuristic: ask if <2 user messages."""
    return None


async def _render_image(prompt: str, ref_image_url: Optional[str], params: Dict[str, Any]):
    """Thin wrapper around existing image_generation service. Wired up in Task 7."""
    raise NotImplementedError("Wired up in Task 7")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ai-service && pytest tests/agents/kv_generator/test_service_image_mode.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ai-service/app/agents/kv_generator/service.py \
       ai-service/tests/agents/kv_generator/test_service_image_mode.py
git commit -m "feat(ai-service): add KV generator image-mode orchestration with callback"
```

---

## Task 7 — Wire up real LLM stream + image rendering

**Files:**
- Modify: `ai-service/app/agents/kv_generator/service.py`

This task connects the stubbed `_llm_stream` + `_render_image` + `_needs_question_card` to real providers using the same patterns as `chat_agent` and `image_generation`.

- [ ] **Step 1: Write the failing integration test**

File: `ai-service/tests/agents/kv_generator/test_service_integration.py`

```python
import pytest

from app.agents.kv_generator.service import _render_image


@pytest.mark.asyncio
async def test_render_image_delegates_to_image_generation(monkeypatch):
    called = {}

    async def fake_perform(args):
        called["args"] = args
        return {"image_url": "https://s/ok.png", "thumbnail_url": None}

    monkeypatch.setattr(
        "app.agents.kv_generator.service.perform_image_generation",
        fake_perform,
    )

    result = await _render_image(
        prompt="Bold KV",
        ref_image_url=None,
        params={"aspect_ratio": "1:1", "style_preset_id": None},
    )
    assert result["image_url"] == "https://s/ok.png"
    assert "prompt_snapshot" in result
    assert "model" in result
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ai-service && pytest tests/agents/kv_generator/test_service_integration.py -v`
Expected: FAIL.

- [ ] **Step 3: Implement real adapters**

Edit: `ai-service/app/agents/kv_generator/service.py` — replace stubs:

```python
import uuid

from app.services.image_generation import GenerateImageDto, perform_image_generation


async def _render_image(prompt: str, ref_image_url, params):
    dto = GenerateImageDto(
        action="generate",
        refined_prompt=prompt,
        image_quality="medium",
        image_model_provider="openai",
        image_model="gpt-image-1",
        user_id=str(uuid.uuid4()),
    )
    result = await perform_image_generation(dto)

    image_url = result.get("image_url") or result.get("url")
    if not image_url:
        raise RuntimeError("image_generation returned no URL")

    return {
        "image_url": image_url,
        "thumbnail_url": result.get("thumbnail_url"),
        "prompt_snapshot": prompt,
        "model": dto.image_model,
        "ai_service_run_id": str(uuid.uuid4()),
    }
```

For `_llm_stream`, plug into the same model-call pattern used by `chat_agent` (via agno / OpenAI client). If streaming adapter differs, yield structured chunks with `kind` key as the tests expect. Keep the adapter minimal — a single-turn call with the given `system_prompt`, `history`, and `prompt`, streaming text out as `{"kind": "thinking", "chunk": ...}` for intermediate text and final `{"kind": "message", "text": ...}`.

For `_needs_question_card`, start with a simple heuristic:
```python
def _needs_question_card(chat_history, prompt) -> Optional[Dict[str, Any]]:
    # MVP: if it's the first user turn and the prompt is <30 chars, ask for aspect.
    user_turns = sum(1 for m in chat_history if m.role == "user")
    if user_turns == 0 and len(prompt) < 30:
        return {
            "label": "Pick an aspect ratio",
            "options": [
                {"id": "1:1", "label": "Square (1:1)"},
                {"id": "16:9", "label": "Wide (16:9)"},
                {"id": "9:16", "label": "Vertical (9:16)"},
            ],
        }
    return None
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ai-service && pytest tests/agents/kv_generator/test_service_integration.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ai-service/app/agents/kv_generator/service.py \
       ai-service/tests/agents/kv_generator/test_service_integration.py
git commit -m "feat(ai-service): wire LLM stream + image_generation adapter for KV"
```

---

## Task 8 — Router + main.py integration

**Files:**
- Create: `ai-service/app/agents/kv_generator/router.py`
- Modify: `ai-service/main.py`
- Modify: `ai-service/app/utils/config.py`

- [ ] **Step 1: Write the failing test**

File: `ai-service/tests/agents/kv_generator/test_router.py`

```python
from fastapi.testclient import TestClient

from main import app


def test_router_registered_and_accepts_kv_stream_request(monkeypatch):
    # Monkeypatch run_stream to yield a single done event
    async def fake_run(request, api_client):
        yield "event: done\ndata: {}\n\n"

    monkeypatch.setattr(
        "app.agents.kv_generator.router.run_stream", fake_run,
    )

    client = TestClient(app)

    response = client.post(
        "/ai/kv-generator/stream",
        json={
            "thread_id": "t1",
            "studio_file_id": "f1",
            "mode": "chat",
            "prompt": "hi",
            "launch_context": {
                "studio_file_id": "f1",
                "use_brand_knowledge": False,
                "brand_id": "b1",
            },
            "chat_history": [],
            "user_id": "u1",
        },
    )
    assert response.status_code == 200
    assert "event: done" in response.text
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ai-service && pytest tests/agents/kv_generator/test_router.py -v`
Expected: FAIL — router not registered.

- [ ] **Step 3: Create router + wire into main**

Edit: `ai-service/app/utils/config.py` — ensure `API_INTERNAL_URL` and `API_INTERNAL_TOKEN` are read from env:

```python
import os

API_INTERNAL_URL = os.getenv("API_INTERNAL_URL", "http://localhost:9191")
API_INTERNAL_TOKEN = os.getenv("API_INTERNAL_TOKEN", "")
```

(Adapt to the existing config pattern in this file — merge rather than replace.)

File: `ai-service/app/agents/kv_generator/router.py`

```python
from fastapi import APIRouter
from fastapi.responses import StreamingResponse

from app.agents.kv_generator.api_client import ApiClient
from app.agents.kv_generator.request_schema import KvStreamRequest
from app.agents.kv_generator.service import run_stream
from app.utils.config import API_INTERNAL_TOKEN, API_INTERNAL_URL


router = APIRouter(prefix="/ai/kv-generator", tags=["kv-generator"])


@router.post("/stream")
async def stream(payload: KvStreamRequest):
    api_client = ApiClient(base_url=API_INTERNAL_URL, internal_token=API_INTERNAL_TOKEN)

    async def generator():
        async for line in run_stream(payload, api_client=api_client):
            yield line

    return StreamingResponse(generator(), media_type="text/event-stream")
```

Edit: `ai-service/main.py` — include the router:

```python
from app.agents.kv_generator.router import router as kv_generator_router

app.include_router(kv_generator_router)
```

(Match the existing include pattern for other agents.)

Edit: `ai-service/.env.example` — add:

```
API_INTERNAL_URL=http://localhost:9191
API_INTERNAL_TOKEN=
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ai-service && pytest tests/agents/kv_generator/test_router.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ai-service/app/agents/kv_generator/router.py ai-service/main.py \
       ai-service/app/utils/config.py ai-service/.env.example \
       ai-service/tests/agents/kv_generator/test_router.py
git commit -m "feat(ai-service): register kv-generator streaming router"
```

---

## Task 9 — Full agent E2E (with mocked API + image gen)

**Files:**
- Create: `ai-service/tests/agents/kv_generator/test_e2e.py`

- [ ] **Step 1: Write the e2e test**

File: `ai-service/tests/agents/kv_generator/test_e2e.py`

```python
import pytest
from fastapi.testclient import TestClient
from respx import MockRouter

from main import app


@pytest.mark.asyncio
async def test_happy_path_image_mode(respx_mock: MockRouter, monkeypatch):
    # Mock API internal calls
    respx_mock.get("http://localhost:9191/api/internal/studio/projects/p1").respond(
        json={"data": {
            "id": "p1", "name": "Camp", "description": "brief",
            "use_brand_knowledge": False, "brand_id": "b1",
        }}
    )
    respx_mock.post(
        "http://localhost:9191/api/internal/kv-generator/generation-complete"
    ).respond(status_code=201, json={"data": {
        "id": "g1", "studio_file_id": "f1", "version_number": 1,
        "image_url": "https://s/img.png",
    }})

    # Mock image generation
    async def fake_perform(args):
        return {"image_url": "https://s/img.png", "thumbnail_url": None}

    monkeypatch.setattr(
        "app.agents.kv_generator.service.perform_image_generation", fake_perform,
    )

    # Mock LLM
    async def fake_llm(system_prompt, history, prompt):
        yield {"kind": "thinking", "chunk": "ok"}

    monkeypatch.setattr(
        "app.agents.kv_generator.service._llm_stream", fake_llm,
    )
    monkeypatch.setattr(
        "app.agents.kv_generator.service._needs_question_card",
        lambda h, p: None,
    )

    client = TestClient(app)

    response = client.post(
        "/ai/kv-generator/stream",
        json={
            "thread_id": "t1",
            "studio_file_id": "f1",
            "mode": "image",
            "prompt": "Create a bold KV for our Gen Z savings campaign with upbeat energy.",
            "launch_context": {
                "project_id": "p1",
                "studio_file_id": "f1",
                "use_brand_knowledge": False,
                "brand_id": "b1",
            },
            "chat_history": [],
            "user_id": "u1",
            "aspect_ratio": "1:1",
        },
    )

    assert response.status_code == 200
    text = response.text
    assert "event: thinking" in text
    assert "event: generating" in text
    assert "event: generation_done" in text
    assert "event: done" in text
```

- [ ] **Step 2: Run test to verify it passes** (all pieces should now exist)

Run: `cd ai-service && pytest tests/agents/kv_generator/test_e2e.py -v`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add ai-service/tests/agents/kv_generator/test_e2e.py
git commit -m "test(ai-service): add e2e test for KV generator image mode"
```

---

## Final Verification

- [ ] **Run the full ai-service test suite**

```bash
cd ai-service && pytest
```

Expected: all tests pass.

- [ ] **Boot the service and hit the endpoint manually**

```bash
cd ai-service && source .venv/bin/activate && fastapi dev
# in another shell:
curl -N -X POST http://localhost:8000/ai/kv-generator/stream \
  -H 'Content-Type: application/json' \
  -d '{"thread_id":"t1","studio_file_id":"f1","mode":"chat","prompt":"hi",
       "launch_context":{"studio_file_id":"f1","use_brand_knowledge":false,"brand_id":"b1"},
       "chat_history":[],"user_id":"u1"}'
```

Expected: stream with `thinking` / `message` / `done` events (assuming API internal endpoint is reachable; otherwise just `done` after a skipped project fetch).

---

## Self-Review Checklist

- Agent module structure: ✓ (Task 1)
- API client with signing: ✓ (Task 2)
- Context builder (project + brand): ✓ (Task 3)
- SSE event serializer: ✓ (Task 4)
- Chat mode orchestration: ✓ (Task 5)
- Image mode orchestration + callback: ✓ (Task 6)
- LLM + image_generation wiring: ✓ (Task 7)
- Router registration: ✓ (Task 8)
- E2E test: ✓ (Task 9)

**Out of scope for this plan (in other plans):**
- API internal endpoints for project + generation-complete → see `-api.md` plan, Tasks 15 and 17
- Web SSE consumption + UI → see `-web.md` plan
- Brand knowledge summary endpoint — assumed to exist or must be added as an API-plan follow-up

**Open items requiring stakeholder input (not blocking):**
- Real LLM model choice for `_llm_stream` (reuse `chat_agent` defaults vs. custom)
- Question card heuristic refinement (beyond the MVP fallback)
- Style preset effect on prompt (deferred to web/UI plan)
