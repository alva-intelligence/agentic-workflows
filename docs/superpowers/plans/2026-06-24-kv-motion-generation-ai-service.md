# KV Motion Generation — ai-service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an internal ai-service endpoint that animates a finished KV image into a short video by calling the existing `generate_video` tool with the KV image as the first frame, then posts the result back to the api.

**Architecture:** Mirror `app/agents/kv_resize/` exactly — a FastAPI router that dispatches work to `BackgroundTasks`, a `service.py` that builds a prompt from a preset + user text and invokes `app/tools/generate_video.py` (image-to-video), and an `api_client.py` that POSTs a completion callback to the api with an `X-Internal-Token` header. No new video integration — reuse the existing multi-provider tool.

**Tech Stack:** FastAPI, Pydantic, pytest, the existing `generate_video` tool (Veo 3.1 / Kling Omni / Sora).

**Spec:** `docs/superpowers/specs/2026-06-23-kv-motion-generation-design.md`

**Contract (api ↔ ai-service):**

Request — api → `POST {AI_URL}/ai/kv-motion/generate`:
```json
{
  "generation_id": "<kv_motion_generations.id>",
  "source_image_url": "<parent KV generation image_url>",
  "model": "veo-3.1-fast-generate-preview",
  "provider": "google",
  "preset": "subtle_zoom",
  "prompt": "optional user detail or null",
  "duration": 8,
  "ratio": "9:16"
}
```

Callback — ai-service → `POST {API_INTERNAL_URL}/api/v1/internal/kv-motion-generations/completed`:
```json
{
  "generation_id": "...",
  "status": "done",
  "video_url": "https://...mp4",
  "token_usage": { "...": 0 },
  "ai_service_run_id": "<uuid4>",
  "model": "veo-3.1-fast-generate-preview"
}
```

**Working directory for all paths below:** `ai-service/`

---

## File Structure

- Create: `app/agents/kv_motion/__init__.py` — empty package marker
- Create: `app/agents/kv_motion/prompts/__init__.py` — empty package marker
- Create: `app/agents/kv_motion/prompts/presets.py` — preset prompt fragments + `build_motion_prompt()`
- Create: `app/agents/kv_motion/request_schema.py` — `MotionGenerateRequest` Pydantic model
- Create: `app/agents/kv_motion/response_schema.py` — `MotionGenerateAccepted` Pydantic model
- Create: `app/agents/kv_motion/api_client.py` — `post_completed()` callback
- Create: `app/agents/kv_motion/service.py` — `process_motion_generation()` orchestration
- Create: `app/agents/kv_motion/router.py` — FastAPI router (`/ai/kv-motion/generate`)
- Modify: `main.py` — include the new router
- Create: `tests/agents/kv_motion/__init__.py`
- Create: `tests/agents/kv_motion/test_presets.py`
- Create: `tests/agents/kv_motion/test_api_client.py`
- Create: `tests/agents/kv_motion/test_service.py`
- Create: `tests/agents/kv_motion/test_router.py`

---

## Task 1: Preset prompt fragments

**Files:**
- Create: `app/agents/kv_motion/__init__.py`
- Create: `app/agents/kv_motion/prompts/__init__.py`
- Create: `app/agents/kv_motion/prompts/presets.py`
- Test: `tests/agents/kv_motion/__init__.py`, `tests/agents/kv_motion/test_presets.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/agents/kv_motion/test_presets.py
import pytest
from app.agents.kv_motion.prompts.presets import (
    MOTION_PRESETS,
    build_motion_prompt,
)


def test_all_five_presets_exist():
    assert set(MOTION_PRESETS) == {
        "subtle_zoom",
        "parallax",
        "product_spin",
        "camera_pan",
        "cinematic_push_in",
    }


def test_build_uses_preset_fragment():
    out = build_motion_prompt("subtle_zoom", None)
    assert MOTION_PRESETS["subtle_zoom"] in out


def test_build_appends_user_prompt_after_preset():
    out = build_motion_prompt("parallax", "add falling leaves")
    assert out.startswith(MOTION_PRESETS["parallax"])
    assert "add falling leaves" in out


def test_build_with_no_preset_uses_user_prompt_only():
    out = build_motion_prompt(None, "slow push-in")
    assert out == "slow push-in"


def test_build_ignores_blank_user_prompt():
    out = build_motion_prompt("product_spin", "   ")
    assert out == MOTION_PRESETS["product_spin"]


def test_build_unknown_preset_raises():
    with pytest.raises(KeyError):
        build_motion_prompt("nope", None)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pytest tests/agents/kv_motion/test_presets.py -v`
Expected: FAIL — `ModuleNotFoundError: app.agents.kv_motion`

- [ ] **Step 3: Create the package markers and the presets module**

```python
# app/agents/kv_motion/__init__.py
```
```python
# app/agents/kv_motion/prompts/__init__.py
```
```python
# app/agents/kv_motion/prompts/presets.py
from typing import Optional

# A preset is a curated prompt FRAGMENT describing camera/scene motion. It is
# model-agnostic — it only steers refined_prompt, never model capability.
MOTION_PRESETS: dict[str, str] = {
    "subtle_zoom": (
        "Slow cinematic push-in on the main subject. Gentle, steady zoom with "
        "subtle ambient motion. Hold the composition; keep all subjects, text, "
        "and brand elements identical and legible."
    ),
    "parallax": (
        "Subtle multi-plane parallax: foreground and background drift at "
        "slightly different speeds for depth. Smooth, restrained camera glide. "
        "Preserve all subjects, text, and brand elements exactly."
    ),
    "product_spin": (
        "Smooth, slow rotation revealing the product from a gentle angle while "
        "lighting plays across its surface. Keep the product's identity, "
        "proportions, colors, and any on-pack text intact and legible."
    ),
    "camera_pan": (
        "Slow, steady horizontal camera pan across the scene with natural "
        "motion parallax. Keep composition balanced; preserve all subjects, "
        "text, and brand elements exactly."
    ),
    "cinematic_push_in": (
        "Dramatic cinematic push-in with shallow depth of field and soft "
        "ambient light movement. Build focus on the hero subject. Preserve all "
        "subjects, text, and brand elements exactly and keep them legible."
    ),
}


def build_motion_prompt(preset: Optional[str], user_prompt: Optional[str]) -> str:
    """Combine a preset fragment with optional user free-text steering.

    The preset fragment comes first; non-blank user text is appended after it.
    A blank/whitespace-only user prompt is treated as absent. When no preset is
    given, the (non-blank) user prompt is returned verbatim.
    """
    fragment = MOTION_PRESETS[preset] if preset else None
    extra = (user_prompt or "").strip() or None

    if fragment and extra:
        return f"{fragment} {extra}"
    if fragment:
        return fragment
    if extra:
        return extra
    raise ValueError("Either a preset or a non-blank prompt is required")
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pytest tests/agents/kv_motion/test_presets.py -v`
Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
git add app/agents/kv_motion/__init__.py app/agents/kv_motion/prompts tests/agents/kv_motion/__init__.py tests/agents/kv_motion/test_presets.py
git commit -m "feat(ai): kv motion preset prompt fragments"
```

---

## Task 2: Request/response schemas

**Files:**
- Create: `app/agents/kv_motion/request_schema.py`
- Create: `app/agents/kv_motion/response_schema.py`

- [ ] **Step 1: Write the failing test** (append to a new schema test)

```python
# tests/agents/kv_motion/test_schemas.py
import pytest
from pydantic import ValidationError
from app.agents.kv_motion.request_schema import MotionGenerateRequest


def test_valid_request_parses():
    req = MotionGenerateRequest(
        generation_id="01HX",
        source_image_url="https://cdn/x.png",
        model="veo-3.1-fast-generate-preview",
        provider="google",
        preset="subtle_zoom",
        prompt=None,
        duration=8,
        ratio="9:16",
    )
    assert req.duration == 8
    assert req.ratio == "9:16"


def test_rejects_bad_ratio():
    with pytest.raises(ValidationError):
        MotionGenerateRequest(
            generation_id="01HX",
            source_image_url="https://cdn/x.png",
            model="veo-3.1-fast-generate-preview",
            provider="google",
            duration=8,
            ratio="4:5",
        )


def test_rejects_bad_duration():
    with pytest.raises(ValidationError):
        MotionGenerateRequest(
            generation_id="01HX",
            source_image_url="https://cdn/x.png",
            model="veo-3.1-fast-generate-preview",
            provider="google",
            duration=7,
            ratio="16:9",
        )
```

- [ ] **Step 2: Run to verify it fails**

Run: `pytest tests/agents/kv_motion/test_schemas.py -v`
Expected: FAIL — module not found

- [ ] **Step 3: Implement the schemas**

```python
# app/agents/kv_motion/request_schema.py
from typing import Literal, Optional
from pydantic import BaseModel


class MotionGenerateRequest(BaseModel):
    generation_id: str
    source_image_url: str
    model: str
    provider: Literal["google", "kuaishou", "openai"]
    preset: Optional[str] = None
    prompt: Optional[str] = None
    duration: Literal[4, 8, 12, 15] = 8
    ratio: Literal["16:9", "9:16", "1:1"] = "9:16"
    negative_prompt: str = ""
```

```python
# app/agents/kv_motion/response_schema.py
from pydantic import BaseModel


class MotionGenerateAccepted(BaseModel):
    generation_id: str
    status: str = "accepted"
```

- [ ] **Step 4: Run to verify it passes**

Run: `pytest tests/agents/kv_motion/test_schemas.py -v`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add app/agents/kv_motion/request_schema.py app/agents/kv_motion/response_schema.py tests/agents/kv_motion/test_schemas.py
git commit -m "feat(ai): kv motion request/response schemas"
```

---

## Task 3: Callback client

**Files:**
- Create: `app/agents/kv_motion/api_client.py`
- Test: `tests/agents/kv_motion/test_api_client.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/agents/kv_motion/test_api_client.py
from unittest.mock import patch, MagicMock
from app.agents.kv_motion import api_client


@patch("app.agents.kv_motion.api_client.requests.post")
def test_post_completed_done_payload(mock_post):
    mock_post.return_value = MagicMock(status_code=200, raise_for_status=lambda: None)
    api_client.post_completed(
        generation_id="01HX",
        status="done",
        video_url="https://cdn/x.mp4",
        token_usage={"output_video_tokens": 10},
        ai_service_run_id="run-1",
        model="veo-3.1-fast-generate-preview",
    )
    url, kwargs = mock_post.call_args[0][0], mock_post.call_args[1]
    assert url.endswith("/api/v1/internal/kv-motion-generations/completed")
    assert kwargs["json"]["generation_id"] == "01HX"
    assert kwargs["json"]["status"] == "done"
    assert kwargs["json"]["video_url"] == "https://cdn/x.mp4"
    assert "X-Internal-Token" in kwargs["headers"]


@patch("app.agents.kv_motion.api_client.requests.post")
def test_post_completed_failed_payload(mock_post):
    mock_post.return_value = MagicMock(status_code=200, raise_for_status=lambda: None)
    api_client.post_completed(
        generation_id="01HX", status="failed", error_message="boom"
    )
    body = mock_post.call_args[1]["json"]
    assert body["status"] == "failed"
    assert body["error_message"] == "boom"
    assert "video_url" not in body
```

- [ ] **Step 2: Run to verify it fails**

Run: `pytest tests/agents/kv_motion/test_api_client.py -v`
Expected: FAIL — module not found

- [ ] **Step 3: Implement the callback client** (mirror `kv_resize/api_client.py`)

```python
# app/agents/kv_motion/api_client.py
from typing import Any, Dict, Optional

import requests

from app.utils.config import settings


def post_completed(
    *,
    generation_id: str,
    status: str,
    video_url: Optional[str] = None,
    error_message: Optional[str] = None,
    token_usage: Optional[Dict[str, Any]] = None,
    ai_service_run_id: Optional[str] = None,
    model: Optional[str] = None,
) -> None:
    """Post final motion status back to the api.

    ``token_usage``, ``ai_service_run_id`` and ``model`` are forwarded so the
    Laravel internal controller can meter credits — all three must be present
    for the cost_history row to be written.
    """
    url = (
        f"{settings.API_INTERNAL_URL.rstrip('/')}"
        "/api/v1/internal/kv-motion-generations/completed"
    )
    payload: dict = {"generation_id": generation_id, "status": status}
    if video_url is not None:
        payload["video_url"] = video_url
    if error_message is not None:
        payload["error_message"] = error_message
    if token_usage:
        payload["token_usage"] = token_usage
    if ai_service_run_id is not None:
        payload["ai_service_run_id"] = ai_service_run_id
    if model is not None:
        payload["model"] = model

    requests.post(
        url,
        json=payload,
        headers={"X-Internal-Token": settings.API_INTERNAL_TOKEN},
        timeout=10,
    ).raise_for_status()
```

- [ ] **Step 4: Run to verify it passes**

Run: `pytest tests/agents/kv_motion/test_api_client.py -v`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add app/agents/kv_motion/api_client.py tests/agents/kv_motion/test_api_client.py
git commit -m "feat(ai): kv motion completion callback client"
```

---

## Task 4: Orchestration service

**Files:**
- Create: `app/agents/kv_motion/service.py`
- Test: `tests/agents/kv_motion/test_service.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/agents/kv_motion/test_service.py
from unittest.mock import patch
from app.agents.kv_motion.request_schema import MotionGenerateRequest
from app.agents.kv_motion.service import process_motion_generation


def _req(**over):
    base = dict(
        generation_id="01HX",
        source_image_url="https://cdn/x.png",
        model="veo-3.1-fast-generate-preview",
        provider="google",
        preset="subtle_zoom",
        prompt=None,
        duration=8,
        ratio="9:16",
    )
    base.update(over)
    return MotionGenerateRequest(**base)


@patch("app.agents.kv_motion.service.post_completed")
@patch("app.agents.kv_motion.service.generate_video")
def test_success_calls_generate_video_with_first_frame_and_posts_done(
    mock_gen, mock_pc
):
    mock_gen.return_value = {
        "video_url": "https://cdn/x.mp4",
        "token_usage": {"output_video_tokens": 5},
    }
    process_motion_generation(_req())

    kwargs = mock_gen.call_args.kwargs
    assert kwargs["first_frame_image"] == "https://cdn/x.png"
    assert kwargs["duration"] == "8"
    assert kwargs["video_ratio"] == "9:16"
    assert kwargs["video_model"] == "veo-3.1-fast-generate-preview"
    assert kwargs["video_model_provider"] == "google"
    assert "push-in" in kwargs["refined_prompt"]

    assert mock_pc.call_args.kwargs["status"] == "done"
    assert mock_pc.call_args.kwargs["video_url"] == "https://cdn/x.mp4"
    assert mock_pc.call_args.kwargs["model"] == "veo-3.1-fast-generate-preview"


@patch("app.agents.kv_motion.service.post_completed")
@patch("app.agents.kv_motion.service.generate_video")
def test_tool_error_dict_posts_failed(mock_gen, mock_pc):
    mock_gen.return_value = {"error_message": "provider down"}
    process_motion_generation(_req())
    assert mock_pc.call_args.kwargs["status"] == "failed"
    assert "provider down" in mock_pc.call_args.kwargs["error_message"]


@patch("app.agents.kv_motion.service.post_completed")
@patch("app.agents.kv_motion.service.generate_video", side_effect=RuntimeError("boom"))
def test_exception_posts_failed(mock_gen, mock_pc):
    process_motion_generation(_req())
    assert mock_pc.call_args.kwargs["status"] == "failed"
    assert "boom" in mock_pc.call_args.kwargs["error_message"]
```

- [ ] **Step 2: Run to verify it fails**

Run: `pytest tests/agents/kv_motion/test_service.py -v`
Expected: FAIL — module not found

- [ ] **Step 3: Implement the service**

```python
# app/agents/kv_motion/service.py
from uuid import uuid4

from app.agents.kv_motion.api_client import post_completed
from app.agents.kv_motion.prompts.presets import build_motion_prompt
from app.agents.kv_motion.request_schema import MotionGenerateRequest
from app.tools.generate_video import generate_video


def process_motion_generation(req: MotionGenerateRequest) -> None:
    """Animate a finished KV image into a short video and post the result back.

    The KV image is the first frame; preset + prompt steer the motion. Any
    failure (tool error dict or exception) results in a ``failed`` callback.
    """
    ai_service_run_id = str(uuid4())
    try:
        refined_prompt = build_motion_prompt(req.preset, req.prompt)

        result = generate_video(
            action="Animate an approved key visual into a short clip",
            refined_prompt=refined_prompt,
            duration=str(req.duration),
            video_ratio=req.ratio,
            first_frame_image=req.source_image_url,
            negative_prompt=req.negative_prompt,
            video_model=req.model,
            video_model_provider=req.provider,
        )

        error_message = result.get("error_message")
        video_url = result.get("video_url")
        if error_message or not video_url:
            post_completed(
                generation_id=req.generation_id,
                status="failed",
                error_message=error_message or "No video_url returned",
            )
            return

        post_completed(
            generation_id=req.generation_id,
            status="done",
            video_url=video_url,
            token_usage=result.get("token_usage") or None,
            ai_service_run_id=ai_service_run_id,
            model=req.model,
        )
    except Exception as exc:  # noqa: BLE001 — any failure must report back
        post_completed(
            generation_id=req.generation_id,
            status="failed",
            error_message=str(exc),
        )
```

> NOTE: `generate_video` accepts `video_model` / `video_model_provider` via
> `**kwargs` (see `app/tools/generate_video.py` signature). If a quick grep of
> that file shows different kwarg names for provider/model selection, use the
> exact names found there — do not invent new ones.

- [ ] **Step 4: Run to verify it passes**

Run: `pytest tests/agents/kv_motion/test_service.py -v`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add app/agents/kv_motion/service.py tests/agents/kv_motion/test_service.py
git commit -m "feat(ai): kv motion orchestration via generate_video first frame"
```

---

## Task 5: Router + registration

**Files:**
- Create: `app/agents/kv_motion/router.py`
- Modify: `main.py` (add the import + `include_router`)
- Test: `tests/agents/kv_motion/test_router.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/agents/kv_motion/test_router.py
from unittest.mock import patch
from fastapi.testclient import TestClient
from main import app

client = TestClient(app)


@patch("app.agents.kv_motion.router.process_motion_generation")
def test_generate_returns_202_and_dispatches(mock_process):
    payload = {
        "generation_id": "01HX",
        "source_image_url": "https://cdn/x.png",
        "model": "veo-3.1-fast-generate-preview",
        "provider": "google",
        "preset": "subtle_zoom",
        "prompt": None,
        "duration": 8,
        "ratio": "9:16",
    }
    resp = client.post("/ai/kv-motion/generate", json=payload)
    assert resp.status_code == 202
    assert resp.json() == {"generation_id": "01HX", "status": "accepted"}
    mock_process.assert_called_once()
```

- [ ] **Step 2: Run to verify it fails**

Run: `pytest tests/agents/kv_motion/test_router.py -v`
Expected: FAIL — route 404 / import error

- [ ] **Step 3: Implement the router** (mirror `kv_resize/router.py`)

```python
# app/agents/kv_motion/router.py
from fastapi import APIRouter, BackgroundTasks
from fastapi.responses import JSONResponse

from app.agents.kv_motion.request_schema import MotionGenerateRequest
from app.agents.kv_motion.response_schema import MotionGenerateAccepted
from app.agents.kv_motion.service import process_motion_generation

router = APIRouter(prefix="/ai/kv-motion", tags=["kv-motion"])


@router.post("/generate", response_model=MotionGenerateAccepted, status_code=202)
def generate(req: MotionGenerateRequest, background: BackgroundTasks):
    background.add_task(process_motion_generation, req)
    return JSONResponse(
        status_code=202,
        content=MotionGenerateAccepted(generation_id=req.generation_id).model_dump(),
    )
```

- [ ] **Step 4: Register the router in `main.py`**

Find the existing block (around `main.py:10-14, 83`) that imports and includes `kv_resize_router`. Add alongside it:

```python
# near the other agent router imports
from app.agents.kv_motion.router import router as kv_motion_router
```
```python
# near the other app.include_router(...) calls
app.include_router(kv_motion_router)
```

- [ ] **Step 5: Run to verify it passes**

Run: `pytest tests/agents/kv_motion/test_router.py -v`
Expected: PASS (1 test)

- [ ] **Step 6: Run the full motion suite**

Run: `pytest tests/agents/kv_motion/ -v`
Expected: PASS (all)

- [ ] **Step 7: Commit**

```bash
git add app/agents/kv_motion/router.py main.py tests/agents/kv_motion/test_router.py
git commit -m "feat(ai): expose POST /ai/kv-motion/generate"
```

---

## Self-Review Checklist (run after all tasks)

- [ ] `pytest tests/agents/kv_motion/ -v` all green.
- [ ] `generate_video` is called with the exact kwarg names that exist in `app/tools/generate_video.py` (verify `video_model` / `video_model_provider` vs whatever the tool actually reads from kwargs).
- [ ] Callback URL path matches the api route added in the api plan: `/api/v1/internal/kv-motion-generations/completed`.
- [ ] `settings.API_INTERNAL_URL` and `settings.API_INTERNAL_TOKEN` exist (they are already used by `kv_resize`).
