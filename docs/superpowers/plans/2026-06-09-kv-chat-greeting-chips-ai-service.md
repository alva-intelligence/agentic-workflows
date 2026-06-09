# KV Chat Greeting Chips — AI Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `POST /ai/kv-chat/suggestion` endpoint that returns one short, brand-aware, LLM-generated chat-prompt suggestion (`{ "suggestion": str | null }`) for the KV chat empty state, never raising on any failure.

**Architecture:** A new focused module `app/agents/kv_chat/suggestion.py` exposes `async def generate_chat_suggestion(...)` that mirrors `classify_logo_directive` exactly — a single gpt-4o-mini JSON-mode `AsyncOpenAI` call at `temperature=0` with a safe fallback to `None` on every unhappy path (no API key, exception, empty/blocked/invalid content). A new `app/agents/kv_chat/router.py` exposes `POST /ai/kv-chat/suggestion`, wired into `main.py` alongside the other KV routers, that builds the generator's context from the request body and returns `{ "suggestion": ... }`.

**Tech Stack:** FastAPI, Python, pytest, OpenAI gpt-4o-mini

---

## Task 1 — Request schema + `generate_chat_suggestion` generator module

**Files:**
- Create: `ai-service/app/agents/kv_chat/__init__.py` (empty package marker)
- Create: `ai-service/app/agents/kv_chat/request_schema.py` (pydantic request model)
- Create: `ai-service/app/agents/kv_chat/suggestion.py` (`generate_chat_suggestion`)
- Create: `ai-service/tests/agents/kv_chat/__init__.py` (empty package marker)
- Test: `ai-service/tests/agents/kv_chat/test_suggestion.py`

Patch target for the OpenAI client in tests: **`app.agents.kv_chat.suggestion.AsyncOpenAI`** and **`app.agents.kv_chat.suggestion.settings`** (mirrors the `logo_directive` test exactly).

- [ ] **1.1 — Write the failing test.** Create `ai-service/tests/agents/kv_chat/__init__.py` (empty) and `ai-service/tests/agents/kv_chat/test_suggestion.py`:

```python
import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from app.agents.kv_chat.suggestion import generate_chat_suggestion


def _mock_openai(content):
    """Patch AsyncOpenAI so .chat.completions.create returns `content`."""
    msg = MagicMock()
    msg.content = content
    choice = MagicMock()
    choice.message = msg
    resp = MagicMock()
    resp.choices = [choice]
    client = MagicMock()
    client.chat.completions.create = AsyncMock(return_value=resp)
    return client


@pytest.mark.asyncio
async def test_returns_suggestion_string_from_valid_json():
    payload = json.dumps({"suggestion": "Design a Ramadan campaign for Acme"})
    with patch("app.agents.kv_chat.suggestion.settings") as s, patch(
        "app.agents.kv_chat.suggestion.AsyncOpenAI",
        return_value=_mock_openai(payload),
    ):
        s.OPENAI_API_KEY = "sk-test"
        out = await generate_chat_suggestion(
            brand_name="Acme",
            title="Ramadan KV",
            recent_prompts=["festive poster", "warm tones"],
        )
    assert out == "Design a Ramadan campaign for Acme"


@pytest.mark.asyncio
async def test_strips_surrounding_quotes():
    payload = json.dumps({"suggestion": '"Brainstorm a launch teaser"'})
    with patch("app.agents.kv_chat.suggestion.settings") as s, patch(
        "app.agents.kv_chat.suggestion.AsyncOpenAI",
        return_value=_mock_openai(payload),
    ):
        s.OPENAI_API_KEY = "sk-test"
        out = await generate_chat_suggestion(
            brand_name=None, title=None, recent_prompts=[]
        )
    assert out == "Brainstorm a launch teaser"


@pytest.mark.asyncio
async def test_generates_with_empty_context():
    payload = json.dumps({"suggestion": "Brainstorm a key visual concept"})
    with patch("app.agents.kv_chat.suggestion.settings") as s, patch(
        "app.agents.kv_chat.suggestion.AsyncOpenAI",
        return_value=_mock_openai(payload),
    ):
        s.OPENAI_API_KEY = "sk-test"
        out = await generate_chat_suggestion(
            brand_name=None, title=None, recent_prompts=[]
        )
    assert out == "Brainstorm a key visual concept"


@pytest.mark.asyncio
async def test_returns_none_when_no_api_key():
    with patch("app.agents.kv_chat.suggestion.settings") as s:
        s.OPENAI_API_KEY = None
        out = await generate_chat_suggestion(
            brand_name="Acme", title="KV", recent_prompts=[]
        )
    assert out is None


@pytest.mark.asyncio
async def test_returns_none_on_exception():
    with patch("app.agents.kv_chat.suggestion.settings") as s, patch(
        "app.agents.kv_chat.suggestion.AsyncOpenAI"
    ) as client_cls:
        s.OPENAI_API_KEY = "sk-test"
        client = MagicMock()
        client.chat.completions.create = AsyncMock(side_effect=RuntimeError("boom"))
        client_cls.return_value = client
        out = await generate_chat_suggestion(
            brand_name="Acme", title="KV", recent_prompts=[]
        )
    assert out is None


@pytest.mark.asyncio
async def test_returns_none_on_bad_json():
    with patch("app.agents.kv_chat.suggestion.settings") as s, patch(
        "app.agents.kv_chat.suggestion.AsyncOpenAI",
        return_value=_mock_openai("not json {"),
    ):
        s.OPENAI_API_KEY = "sk-test"
        out = await generate_chat_suggestion(
            brand_name="Acme", title="KV", recent_prompts=[]
        )
    assert out is None


@pytest.mark.asyncio
async def test_returns_none_on_empty_suggestion():
    payload = json.dumps({"suggestion": "   "})
    with patch("app.agents.kv_chat.suggestion.settings") as s, patch(
        "app.agents.kv_chat.suggestion.AsyncOpenAI",
        return_value=_mock_openai(payload),
    ):
        s.OPENAI_API_KEY = "sk-test"
        out = await generate_chat_suggestion(
            brand_name="Acme", title="KV", recent_prompts=[]
        )
    assert out is None


@pytest.mark.asyncio
async def test_returns_none_on_blocked_content():
    with patch("app.agents.kv_chat.suggestion.settings") as s, patch(
        "app.agents.kv_chat.suggestion.AsyncOpenAI",
        return_value=_mock_openai(None),
    ):
        s.OPENAI_API_KEY = "sk-test"
        out = await generate_chat_suggestion(
            brand_name="Acme", title="KV", recent_prompts=[]
        )
    assert out is None
```

- [ ] **1.2 — Run the test, expect FAIL** (module does not exist yet — `ModuleNotFoundError: app.agents.kv_chat.suggestion`):

```
.venv/bin/python -m pytest tests/agents/kv_chat/test_suggestion.py -q
```

- [ ] **1.3 — Minimal implementation.** Create `ai-service/app/agents/kv_chat/__init__.py` (empty file). Create `ai-service/app/agents/kv_chat/request_schema.py`:

```python
from typing import List, Optional

from pydantic import BaseModel, Field


class ChatSuggestionRequest(BaseModel):
    brand_name: Optional[str] = None
    title: Optional[str] = None
    recent_prompts: List[str] = Field(default_factory=list)


class ChatSuggestionResponse(BaseModel):
    suggestion: Optional[str] = None
```

Create `ai-service/app/agents/kv_chat/suggestion.py`:

```python
"""LLM chat-prompt suggestion generator for the KV chat empty state.

A focused, separate call (gpt-4o-mini, JSON mode) — the same pattern as
`classify_logo_directive`. Produces ONE short, actionable chat prompt a
designer could send to start working on a Key Visual. Returns `None` on any
unhappy path (no API key, blocked/empty/invalid response, exception). Never
raises.
"""

from __future__ import annotations

import json
from typing import List, Optional

from openai import AsyncOpenAI

from app.utils.config import settings

_SYSTEM = (
    "You write ONE short, actionable chat prompt a designer could send to "
    "start working on a Key Visual (KV). Use the provided project context "
    "(brand, title, recent prompts) when present. Rules: imperative voice, "
    "brand-aware when a brand is given, no surrounding quotes, at most ~8 "
    "words. If context is sparse, write a sensible generic KV brainstorming "
    'prompt. Reply ONLY with a JSON object: {"suggestion": "<text>"}.'
)


def _build_user_message(
    *,
    brand_name: Optional[str],
    title: Optional[str],
    recent_prompts: List[str],
) -> str:
    lines: list[str] = []
    if brand_name:
        lines.append(f"Brand: {brand_name}")
    if title:
        lines.append(f"Key Visual title: {title}")
    prompts = [p for p in (recent_prompts or []) if p and p.strip()]
    if prompts:
        joined = "; ".join(prompts[:3])
        lines.append(f"Recent prompts: {joined}")
    if not lines:
        return "No project context yet. Suggest a generic KV brainstorming prompt."
    return "Project context:\n" + "\n".join(lines)


async def generate_chat_suggestion(
    *,
    brand_name: Optional[str],
    title: Optional[str],
    recent_prompts: List[str],
) -> Optional[str]:
    """Return one short suggestion prompt, or `None` on any unhappy path."""
    api_key = getattr(settings, "OPENAI_API_KEY", None)
    if not api_key:
        return None

    user = _build_user_message(
        brand_name=brand_name, title=title, recent_prompts=recent_prompts
    )

    try:
        client = AsyncOpenAI(api_key=api_key)
        resp = await client.chat.completions.create(
            model="gpt-4o-mini",
            messages=[
                {"role": "system", "content": _SYSTEM},
                {"role": "user", "content": user},
            ],
            response_format={"type": "json_object"},
            temperature=0,
        )
        raw = resp.choices[0].message.content or "{}"
        data = json.loads(raw)
        suggestion = (data.get("suggestion") or "").strip().strip('"').strip()
        return suggestion or None
    except Exception:
        return None
```

- [ ] **1.4 — Run the test, expect PASS:**

```
.venv/bin/python -m pytest tests/agents/kv_chat/test_suggestion.py -q
```

- [ ] **1.5 — Commit:**

```
git add ai-service/app/agents/kv_chat/__init__.py ai-service/app/agents/kv_chat/request_schema.py ai-service/app/agents/kv_chat/suggestion.py ai-service/tests/agents/kv_chat/__init__.py ai-service/tests/agents/kv_chat/test_suggestion.py
git commit -m "feat(ai): add kv-chat suggestion generator (gpt-4o-mini, safe fallback)"
```

---

## Task 2 — `POST /ai/kv-chat/suggestion` endpoint + router registration

**Files:**
- Create: `ai-service/app/agents/kv_chat/router.py` (FastAPI router)
- Modify: `ai-service/main.py` (import + `include_router`)
- Test: `ai-service/tests/agents/kv_chat/test_router.py`

Patch target for the generator in endpoint tests: **`app.agents.kv_chat.router.generate_chat_suggestion`** (patch the name as imported into the router module, mirroring `test_router.py` in `kv_resize`).

- [ ] **2.1 — Write the failing test.** Create `ai-service/tests/agents/kv_chat/test_router.py`:

```python
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

from main import app


client = TestClient(app)


@patch(
    "app.agents.kv_chat.router.generate_chat_suggestion",
    new=AsyncMock(return_value="Design a Ramadan campaign for Acme"),
)
def test_suggestion_endpoint_happy_path():
    resp = client.post(
        "/ai/kv-chat/suggestion",
        json={
            "brand_name": "Acme",
            "title": "Ramadan KV",
            "recent_prompts": ["festive poster"],
        },
    )
    assert resp.status_code == 200
    assert resp.json() == {"suggestion": "Design a Ramadan campaign for Acme"}


@patch(
    "app.agents.kv_chat.router.generate_chat_suggestion",
    new=AsyncMock(return_value=None),
)
def test_suggestion_endpoint_null_path():
    resp = client.post(
        "/ai/kv-chat/suggestion",
        json={"brand_name": None, "title": None, "recent_prompts": []},
    )
    assert resp.status_code == 200
    assert resp.json() == {"suggestion": None}


def test_suggestion_endpoint_accepts_minimal_body():
    with patch(
        "app.agents.kv_chat.router.generate_chat_suggestion",
        new=AsyncMock(return_value="Brainstorm a key visual concept"),
    ):
        resp = client.post("/ai/kv-chat/suggestion", json={})
    assert resp.status_code == 200
    assert resp.json() == {"suggestion": "Brainstorm a key visual concept"}
```

- [ ] **2.2 — Run the test, expect FAIL** (route not registered yet → 404; `test_suggestion_endpoint_happy_path` patch target import may also error until the router module exists):

```
.venv/bin/python -m pytest tests/agents/kv_chat/test_router.py -q
```

- [ ] **2.3 — Minimal implementation.** Create `ai-service/app/agents/kv_chat/router.py`:

```python
from fastapi import APIRouter

from app.agents.kv_chat.request_schema import (
    ChatSuggestionRequest,
    ChatSuggestionResponse,
)
from app.agents.kv_chat.suggestion import generate_chat_suggestion


router = APIRouter(prefix="/ai/kv-chat", tags=["kv-chat"])


@router.post("/suggestion", response_model=ChatSuggestionResponse)
async def suggestion(payload: ChatSuggestionRequest) -> ChatSuggestionResponse:
    """Return one short, context-aware chat-prompt suggestion for the KV chat
    empty state. Never errors — returns `{"suggestion": null}` on any failure."""
    text = await generate_chat_suggestion(
        brand_name=payload.brand_name,
        title=payload.title,
        recent_prompts=payload.recent_prompts,
    )
    return ChatSuggestionResponse(suggestion=text)
```

Then register it in `ai-service/main.py`. Add the import next to the other KV router imports:

```python
from app.agents.kv_chat.router import router as kv_chat_router
```

And add the mount next to the other KV `include_router` calls:

```python
app.include_router(kv_chat_router)
```

- [ ] **2.4 — Run the test, expect PASS:**

```
.venv/bin/python -m pytest tests/agents/kv_chat/test_router.py -q
```

- [ ] **2.5 — Run the full kv_chat suite to confirm no regressions:**

```
.venv/bin/python -m pytest tests/agents/kv_chat -q
```

- [ ] **2.6 — Commit:**

```
git add ai-service/app/agents/kv_chat/router.py ai-service/main.py ai-service/tests/agents/kv_chat/test_router.py
git commit -m "feat(ai): add POST /ai/kv-chat/suggestion endpoint"
```

---

## Verification

- [ ] `.venv/bin/python -m pytest tests/agents/kv_chat -q` is green.
- [ ] `POST /ai/kv-chat/suggestion` with `{ "brand_name": "Acme", "title": "Ramadan KV", "recent_prompts": ["festive poster"] }` returns `{ "suggestion": "<string>" }`.
- [ ] With `OPENAI_API_KEY` unset (or the generator raising), the endpoint still returns `200` with `{ "suggestion": null }` — never a 5xx.
- [ ] Request keys are snake_case (`brand_name`, `title`, `recent_prompts`); response is exactly `{ "suggestion": <string|null> }` — matches the shared contract the api layer calls.
