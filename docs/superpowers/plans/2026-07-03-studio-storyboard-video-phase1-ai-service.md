# Studio Storyboard → Video — Phase 1 (ai-service) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development` — execute each task as an isolated TDD unit (write the failing test, make it pass, commit), dispatching one subagent per task and reviewing its diff before moving on.

**Goal**

Ship the ai-service surface for Phase 1 of the Studio Storyboard tool: a new `app/agents/storyboard/` package exposing three HTTP operations that mirror the KV Motion / KV generator plumbing verbatim — no new model integrations.

1. `POST /ai/storyboard/decompose` — synchronous **SSE stream** that turns a brief + brand context into an editable DRAFT (ordered scenes + proposed cast + per-scene cast tags). Persists nothing. Reuses the KV NDJSON SSE transport and the Agno/Gemini chat setup.
2. `POST /ai/storyboard/cast/generate` — **202 Accepted + BackgroundTask** that calls `generate_image` (text-to-image, no refs) to produce a candidate cast reference, uploads it, and posts a `cast-complete` callback to the api.
3. `POST /ai/storyboard/scenes/frame` — **202 Accepted + BackgroundTask** that calls `edit_image` (multi-reference img-to-img) feeding the tagged cast reference images + scene description, bakes the brand logo server-side the KV way, and posts a scene-frame completed callback.

Clips (pipeline 4), stitch (pipeline 5), and all api/web work are **out of scope** for this plan.

**Architecture**

- The **render steps** (cast generate, scene frame) follow the codebase's proven async pattern: router returns `202` immediately and dispatches a `BackgroundTasks` job; the job runs the real tool, then POSTs the result back to the api's internal callback controller with an `X-Internal-Token` header. The DB is the source of truth; the browser polls. This is exactly what `app/agents/kv_motion/` does.
- The **decompose step** is the deliberate exception: a single fast LLM turn with no heavy result to store, so it is a synchronous **NDJSON stream** (reusing `to_sse_line` + `StreamingResponse`, the KV generator transport) that yields the draft as it is produced and persists nothing. The web layer confirms → creates rows via normal api CRUD.
- Structure mirrors `kv_motion` 1:1: `request_schema.py`, `response_schema.py`, `service.py`, `router.py`, `api_client.py`, `prompts/presets.py`. Decompose adds a `decompose_service.py` + `decompose_schema.py` + `events.py` (NDJSON serializer) so the streaming path stays isolated from the two background-job paths.

**Tech Stack**

- FastAPI (routers, `BackgroundTasks`, `StreamingResponse`), Pydantic v2 schemas.
- Agno `Agent` + `get_model_config(model_provider="google", model="gemini-3.5-flash", …)` with `output_schema=` for structured decompose output (mirrors `app/agents/customer_persona/service.py`).
- Existing tools reused verbatim: `app.tools.generate_image.generate_image`, `app.tools.edit_image.edit_image`, (`app.tools.generate_video.generate_video` is reserved for Phase 2, not touched here).
- Existing helpers reused: `app.services.aws.upload_file_to_s3`, `app.agents.kv_generator.logo_stamp` (`resolve_stamp`/`stamp_logo`/`strip_logo_sentences`) for the server-side logo bake, `app.agents.kv_generator.request_schema.BrandLogoStamp` (for `brand_logo.stamp`).
- `requests` for the internal callback POST; `pytest` + `unittest.mock` for tests (mirrors `tests/agents/kv_motion/`).

## Global Constraints

- **Target branch:** `development` (ai-service default branch). Branch name `feature/<worker>/vc-studio-storyboard-video` off latest `development`.
- **Reuse `generate_image` / `edit_image` verbatim** — pass args through their existing signatures (below). **No new model integrations**, no edits to `app/tools/*`.
  - `generate_image(action, refined_prompt, image_quality="medium", **kwargs)` — kwargs used: `image_model_provider`, `image_model`, `user_id`, `temp_folder_path`, `aspect_ratio`. Returns `{"image_url", "token_usage", ...}` or an error dict `{"error_message", ...}`.
  - `edit_image(action, refined_prompt, image_context, image_quality="medium", **kwargs)` — multi-reference is passed via `kwargs["images"]` (list of source URLs, downloaded by the tool) **and/or** `kwargs["extra_local_paths"]` (pre-saved local files, appended as extra `image[]` parts). kwargs used: `image_model_provider`, `image_model`, `user_id`, `temp_folder_path`, `aspect_ratio`, `extra_local_paths`. Returns `{"image_url", "token_usage", ...}` or `{"error_message", ...}`.
- **Callback via `X-Internal-Token`** to `settings.API_INTERNAL_URL`, `timeout=10`, `.raise_for_status()` — copy `app/agents/kv_motion/api_client.py` exactly. `token_usage`, `ai_service_run_id`, and `model` must all be forwarded so the api can meter credits (`storyboard_cast_generation` / `storyboard_frame_generation`).
- **Async job → 202 → callback** for both render ops; **SSE** for decompose. Never persist from ai-service.
- **Logo bake is NOT gated on brand-knowledge** (decoupled — per the KV lesson in `project_kv_logo_bake_decoupled_brand_knowledge.md`): the frame op bakes `brand_logo` bytes whenever a stamp is present, independent of any brand-knowledge flag.
- **Callbacks idempotent on `generation_id`** — ai-service always sends the id the api gave it; idempotency is enforced api-side.
- **Failure contract:** any tool error dict (`error_message` present, or no image) OR any raised exception → a `status="failed"` callback with `error_message`. The job never raises out of the BackgroundTask.
- **DRY / YAGNI / TDD.** No speculative fields. Every task writes the test first.

## File Structure

```
ai-service/
├── app/agents/storyboard/
│   ├── __init__.py                 # empty package marker (mirrors kv_motion/__init__.py)
│   ├── request_schema.py           # CastGenerateRequest, SceneFrameRequest, DecomposeRequest, shared BrandContext
│   ├── response_schema.py          # CastGenerateAccepted, SceneFrameAccepted (202 bodies)
│   ├── decompose_schema.py         # DraftScene, DraftCastMember, StoryboardDraft (LLM output_schema)
│   ├── events.py                   # to_sse_line(): NDJSON serializer for decompose stream frames
│   ├── prompts/
│   │   ├── __init__.py
│   │   └── presets.py              # DECOMPOSE_SYSTEM_PROMPT, build_decompose_user_prompt(), build_cast_prompt(), build_frame_prompt()
│   ├── api_client.py               # post_cast_completed(), post_frame_completed() (X-Internal-Token)
│   ├── decompose_service.py        # run_decompose_stream(): Agno/Gemini structured stream (SSE)
│   ├── service.py                  # process_cast_generation(), process_frame_generation() (background jobs)
│   └── router.py                   # /ai/storyboard/{decompose,cast/generate,scenes/frame}
└── tests/agents/storyboard/
    ├── __init__.py
    ├── test_schemas.py             # request + accepted schema validation
    ├── test_decompose_schema.py    # StoryboardDraft / DraftScene / DraftCastMember validation
    ├── test_presets.py             # prompt builders
    ├── test_api_client.py          # callback payload shape + header
    ├── test_decompose_service.py   # run_decompose_stream emits scene/cast/done frames (Agno mocked)
    ├── test_service.py             # cast + frame jobs call the right tool and post the right callback
    └── test_router.py              # 202 dispatch + decompose stream wiring + 422 validation
```

Plus one line added to `ai-service/main.py` (router registration).

---

## Task 1 — Package skeleton + request/response/draft schemas + presets

**Files**

- `app/agents/storyboard/__init__.py` (empty)
- `app/agents/storyboard/prompts/__init__.py` (empty)
- `app/agents/storyboard/request_schema.py`
- `app/agents/storyboard/response_schema.py`
- `app/agents/storyboard/decompose_schema.py`
- `app/agents/storyboard/prompts/presets.py`
- `tests/agents/storyboard/__init__.py` (empty)
- `tests/agents/storyboard/test_schemas.py`
- `tests/agents/storyboard/test_decompose_schema.py`
- `tests/agents/storyboard/test_presets.py`

**Interfaces**

Consumes: nothing (leaf schemas). Reuses `app.agents.kv_generator.request_schema.BrandLogoStamp` for the frame op's `brand_logo.stamp`.

Produces:

```python
# request_schema.py
from typing import List, Literal, Optional
from pydantic import BaseModel, Field, model_validator
from app.agents.kv_generator.request_schema import BrandLogoStamp


class BrandContext(BaseModel):
    """Brand fields the api pre-resolves and forwards so ai-service never
    calls back mid-request. All optional — a brandless storyboard still works."""
    brand_name: Optional[str] = None
    dna: Optional[str] = None
    tonality: Optional[str] = None
    visual_dos: List[str] = Field(default_factory=list)
    visual_donts: List[str] = Field(default_factory=list)


class DecomposeRequest(BaseModel):
    brief: str = Field(min_length=1, max_length=5000)
    brand_context: Optional[BrandContext] = None
    ratio: Optional[str] = None            # default aspect ratio hint for the draft
    scene_count_hint: Optional[int] = Field(default=None, ge=1, le=12)
    user_id: str


class CastGenerateRequest(BaseModel):
    generation_id: str                     # api-side row id; echoed in the callback (idempotency key)
    cast_member_id: str
    description: str = Field(min_length=1, max_length=2000)
    kind: Literal["character", "product", "setting", "prop"] = "character"
    brand_context: Optional[BrandContext] = None
    ratio: str = "1:1"                      # cast portraits default square
    model: str = "gpt-image-2"
    provider: str = "openai"
    user_id: str


class SceneFrameBrandLogo(BaseModel):
    """Brand logo the api pre-resolves for the frame op. `stamp` carries the
    placement/size the KV `stamp_logo` helper consumes; when absent the logo
    is not baked."""
    logo_url: str
    stamp: Optional[BrandLogoStamp] = None


class SceneFrameRequest(BaseModel):
    generation_id: str                     # api-side scene_frames row id; echoed in callback
    scene_id: str
    frame_id: str
    description: str = Field(min_length=1, max_length=4000)     # scene beat/action text
    camera_notes: Optional[str] = None
    cast_references: List[str] = Field(default_factory=list)   # locked reference image URLs (flat string[])
    cast_refs_used: List[str] = Field(default_factory=list)    # cast_member_ids, echoed for provenance
    brand_context: Optional[BrandContext] = None
    ratio: str = "16:9"
    model: str = "gpt-image-2"
    provider: str = "openai"
    brand_logo: Optional[SceneFrameBrandLogo] = None   # {logo_url, stamp?} — baked server-side when present
    user_id: str

    @model_validator(mode="after")
    def _require_scene_or_refs(self) -> "SceneFrameRequest":
        # A frame needs *something* to render from. edit_image with an empty
        # image[] + prompt is a text-to-image fallback we explicitly disallow
        # here — the consistency step REQUIRES at least one reference.
        if not self.cast_references:
            raise ValueError("At least one cast_references URL is required for a scene frame")
        return self
```

```python
# response_schema.py
from pydantic import BaseModel


class CastGenerateAccepted(BaseModel):
    generation_id: str
    status: str = "accepted"


class SceneFrameAccepted(BaseModel):
    generation_id: str
    status: str = "accepted"
```

```python
# decompose_schema.py — Gemini output_schema (no free-form dicts; additionalProperties rejected)
from typing import List
from pydantic import BaseModel, Field


class DraftCastMember(BaseModel):
    ref_key: str = Field(description="Stable slug used to tag scenes, e.g. 'maya' or 'the-sneaker'")
    name: str
    kind: str = Field(description="One of: character, product, setting, prop")
    description: str = Field(description="Text a downstream image model uses to render the reference")


class DraftScene(BaseModel):
    position: int = Field(ge=1)
    description: str
    camera_notes: str
    duration: int = Field(ge=1, le=15, description="Suggested clip length in seconds")
    cast_ref_keys: List[str] = Field(default_factory=list, description="ref_keys of cast appearing in this scene")


class StoryboardDraft(BaseModel):
    scenes: List[DraftScene]
    cast: List[DraftCastMember]
```

```python
# prompts/presets.py
from typing import Optional
from app.agents.storyboard.request_schema import BrandContext

DECOMPOSE_SYSTEM_PROMPT = (
    "You are a creative director decomposing a campaign brief into a short "
    "storyboard. Produce an ordered list of scenes and a cast of recurring "
    "subjects (characters, products, settings, props). Each scene has a vivid "
    "visual description, camera/motion notes, a suggested clip duration in "
    "seconds, and the ref_keys of the cast members that appear in it. Reuse the "
    "same ref_key whenever the same subject recurs so it can be kept visually "
    "consistent. Keep it concise and on-brand. Return ONLY the structured object."
)


def build_decompose_user_prompt(
    brief: str,
    brand: Optional[BrandContext],
    ratio: Optional[str],
    scene_count_hint: Optional[int],
) -> str:
    parts = [f"Brief:\n{brief.strip()}"]
    if brand and brand.brand_name:
        parts.append(f"Brand: {brand.brand_name}")
    if brand and brand.dna:
        parts.append(f"Brand DNA: {brand.dna}")
    if brand and brand.tonality:
        parts.append(f"Tone: {brand.tonality}")
    if brand and brand.visual_dos:
        parts.append("Visual do's: " + "; ".join(brand.visual_dos))
    if brand and brand.visual_donts:
        parts.append("Visual don'ts: " + "; ".join(brand.visual_donts))
    if ratio:
        parts.append(f"Target aspect ratio: {ratio}")
    if scene_count_hint:
        parts.append(f"Aim for about {scene_count_hint} scenes.")
    return "\n".join(parts)


def _brand_suffix(brand: Optional[BrandContext]) -> str:
    if not brand:
        return ""
    bits = []
    if brand.brand_name:
        bits.append(f"Brand: {brand.brand_name}.")
    if brand.tonality:
        bits.append(f"Tone: {brand.tonality}.")
    if brand.visual_dos:
        bits.append("Prefer: " + "; ".join(brand.visual_dos) + ".")
    if brand.visual_donts:
        bits.append("Avoid: " + "; ".join(brand.visual_donts) + ".")
    return (" " + " ".join(bits)) if bits else ""


def build_cast_prompt(description: str, kind: str, brand: Optional[BrandContext]) -> str:
    """Text-to-image prompt for a locked cast reference (portrait/hero shot)."""
    lead = {
        "character": "A clean, well-lit character reference portrait of",
        "product": "A clean studio hero shot of the product:",
        "setting": "A clean establishing reference shot of the setting:",
        "prop": "A clean studio reference shot of the prop:",
    }.get(kind, "A clean reference image of")
    return f"{lead} {description.strip()}. Neutral background, sharp focus, no text or logos.{_brand_suffix(brand)}"


def build_frame_prompt(
    description: str, camera_notes: Optional[str], brand: Optional[BrandContext]
) -> str:
    """Multi-reference edit prompt: compose the scene featuring the referenced
    cast subjects. The cast reference images ride in via image[] — this text
    instructs the model to preserve those subjects while building the scene."""
    parts = [
        "Compose a single on-brand key-visual frame for this scene, featuring "
        "the subject(s) shown in the provided reference image(s). Preserve each "
        "referenced subject's identity, proportions, and colors exactly while "
        "placing them in the described scene.",
        f"Scene: {description.strip()}",
    ]
    if camera_notes and camera_notes.strip():
        parts.append(f"Camera/composition: {camera_notes.strip()}")
    return " ".join(parts) + _brand_suffix(brand)
```

**Steps (TDD)**

1. Write `tests/agents/storyboard/test_schemas.py` — assert: a valid `CastGenerateRequest` parses with defaults (`model="gpt-image-2"`, `provider="openai"`, `ratio="1:1"`); a valid `SceneFrameRequest` with one `cast_references` URL parses; `SceneFrameRequest` with empty `cast_references` raises `ValidationError` matching `"At least one cast_references"`; `DecomposeRequest` rejects an empty `brief`; `CastGenerateAccepted().status == "accepted"`.
2. Write `tests/agents/storyboard/test_decompose_schema.py` — a `StoryboardDraft` with 2 scenes (positions 1,2) + 1 cast member parses; a `DraftScene` with `duration=0` raises; `cast_ref_keys` defaults to `[]`.
3. Write `tests/agents/storyboard/test_presets.py` — `build_cast_prompt("Maya, 20s athlete", "character", None)` contains `"character reference portrait"` and `"Maya"` and `"no text or logos"`; `build_frame_prompt("runner crests a hill", "wide low-angle", None)` contains `"reference image"` and `"runner crests a hill"` and `"wide low-angle"`; `build_decompose_user_prompt` with a `BrandContext(brand_name="Nike")` contains `"Nike"`.
4. Run `pytest tests/agents/storyboard/test_schemas.py tests/agents/storyboard/test_decompose_schema.py tests/agents/storyboard/test_presets.py -q` → **red** (modules missing).
5. Create the empty `__init__.py` files, `request_schema.py`, `response_schema.py`, `decompose_schema.py`, `prompts/presets.py` with the code above.
6. Re-run the same command → **green** (expected: `3 files ... N passed`).

**Commit:** `feat(ai): storyboard schemas + prompt presets (phase 1)`

---

## Task 2 — Internal callback client (`api_client.py`)

**Files**

- `app/agents/storyboard/api_client.py`
- `tests/agents/storyboard/test_api_client.py`

**Interfaces**

Consumes: `app.utils.config.settings` (`API_INTERNAL_URL`, `API_INTERNAL_TOKEN`).

Produces (copied from `kv_motion/api_client.py`, split into two typed functions):

```python
from typing import Any, Dict, List, Optional
import requests
from app.utils.config import settings


def _post_internal(path: str, payload: dict) -> None:
    url = f"{settings.API_INTERNAL_URL.rstrip('/')}{path}"
    requests.post(
        url,
        json=payload,
        headers={"X-Internal-Token": settings.API_INTERNAL_TOKEN},
        timeout=10,
    ).raise_for_status()


def post_cast_completed(
    *,
    generation_id: str,
    cast_member_id: str,
    status: str,
    reference_image_url: Optional[str] = None,
    error_message: Optional[str] = None,
    token_usage: Optional[Dict[str, Any]] = None,
    ai_service_run_id: Optional[str] = None,
    model: Optional[str] = None,
) -> None:
    payload: dict = {
        "generation_id": generation_id,
        "cast_member_id": cast_member_id,
        "status": status,
    }
    if reference_image_url is not None:
        payload["reference_image_url"] = reference_image_url
    if error_message is not None:
        payload["error_message"] = error_message
    if token_usage:
        payload["token_usage"] = token_usage
    if ai_service_run_id is not None:
        payload["ai_service_run_id"] = ai_service_run_id
    if model is not None:
        payload["model"] = model
    _post_internal("/api/v1/internal/storyboard-cast-generations/completed", payload)


def post_frame_completed(
    *,
    generation_id: str,
    scene_id: str,
    frame_id: str,
    status: str,
    image_url: Optional[str] = None,
    source_image_url: Optional[str] = None,
    thumbnail_url: Optional[str] = None,
    prompt_snapshot: Optional[str] = None,
    model: Optional[str] = None,
    cast_refs_used: Optional[List[str]] = None,
    error_message: Optional[str] = None,
    token_usage: Optional[Dict[str, Any]] = None,
    ai_service_run_id: Optional[str] = None,
) -> None:
    payload: dict = {
        "generation_id": generation_id,
        "scene_id": scene_id,
        "frame_id": frame_id,
        "status": status,
    }
    for key, val in (
        ("image_url", image_url),
        ("source_image_url", source_image_url),
        ("thumbnail_url", thumbnail_url),
        ("prompt_snapshot", prompt_snapshot),
        ("model", model),
        ("error_message", error_message),
        ("ai_service_run_id", ai_service_run_id),
    ):
        if val is not None:
            payload[key] = val
    if cast_refs_used:
        payload["cast_refs_used"] = cast_refs_used
    if token_usage:
        payload["token_usage"] = token_usage
    _post_internal("/api/v1/internal/storyboard-scene-frames/completed", payload)
```

**Steps (TDD)**

1. Write `tests/agents/storyboard/test_api_client.py` mirroring `kv_motion/test_api_client.py`:
   - `@patch("app.agents.storyboard.api_client.requests.post")` returning `MagicMock(status_code=200, raise_for_status=lambda: None)`.
   - `post_cast_completed(generation_id="c1", cast_member_id="cm1", status="ready", reference_image_url="https://cdn/cast.png", token_usage={"output_image_tokens": 5}, ai_service_run_id="run-1", model="gpt-image-2")` → assert url ends with `/api/v1/internal/storyboard-cast-generations/completed`, `json["reference_image_url"] == "https://cdn/cast.png"`, `"X-Internal-Token" in headers`.
   - `post_cast_completed(generation_id="c1", cast_member_id="cm1", status="failed", error_message="boom")` → `json["status"] == "failed"`, `json["error_message"] == "boom"`, `"reference_image_url" not in json`.
   - `post_frame_completed(generation_id="f1", scene_id="s1", frame_id="fr1", status="ready", image_url="https://cdn/f.png", source_image_url="https://cdn/src.png", cast_refs_used=["cm1","cm2"], model="gpt-image-2", token_usage={"output_image_tokens": 9}, ai_service_run_id="run-2")` → url ends with `/api/v1/internal/storyboard-scene-frames/completed`, `json["cast_refs_used"] == ["cm1", "cm2"]`, `json["source_image_url"] == "https://cdn/src.png"`.
2. Run `pytest tests/agents/storyboard/test_api_client.py -q` → **red**.
3. Create `api_client.py` with the code above.
4. Re-run → **green** (expected: `4 passed`).

**Commit:** `feat(ai): storyboard internal callback client (cast + frame completed)`

---

## Task 3 — Decompose SSE stream (`events.py` + `decompose_service.py`)

**Files**

- `app/agents/storyboard/events.py`
- `app/agents/storyboard/decompose_service.py`
- `tests/agents/storyboard/test_decompose_service.py`

**Interfaces**

Consumes: `DecomposeRequest`, `StoryboardDraft` (Task 1), `app.agents.utils.get_model_config`, `agno.agent.Agent`.

Produces:

```python
# events.py — NDJSON serializer (identical shape to kv_generator/events.py)
import json


def to_sse_line(payload: dict) -> str:
    """Serialize one decompose frame as an NDJSON line."""
    return json.dumps(payload) + "\n"
```

```python
# decompose_service.py
from typing import AsyncIterator
from uuid import uuid4

from agno.agent import Agent
from agno.utils.log import log_error

from app.agents.storyboard.decompose_schema import StoryboardDraft
from app.agents.storyboard.events import to_sse_line
from app.agents.storyboard.prompts.presets import (
    DECOMPOSE_SYSTEM_PROMPT,
    build_decompose_user_prompt,
)
from app.agents.storyboard.request_schema import DecomposeRequest
from app.agents.utils import get_model_config

_DECOMPOSE_PROVIDER = "google"
_DECOMPOSE_MODEL = "gemini-3.5-flash"


async def run_decompose_stream(req: DecomposeRequest) -> AsyncIterator[str]:
    """Stream an editable storyboard draft. Persists nothing.

    Reuses the Agno/Gemini setup KV chat uses (`get_model_config`) with a
    structured `output_schema`, then fans the parsed draft out as NDJSON
    frames the web layer renders into the editable board:

        {"event": "draft_started"}
        {"event": "cast", "cast": {...}}          # one per proposed cast member
        {"event": "scene", "scene": {...}}        # one per ordered scene
        {"event": "done"}
        {"event": "error", "message": "..."}      # on failure
    """
    yield to_sse_line({"event": "draft_started"})
    try:
        _reasoning, model_config = get_model_config(
            model_provider=_DECOMPOSE_PROVIDER,
            model=_DECOMPOSE_MODEL,
            user_id=req.user_id,
        )
        agent = Agent(
            model=model_config,
            instructions=DECOMPOSE_SYSTEM_PROMPT,
            output_schema=StoryboardDraft,
            markdown=False,
        )
        user_prompt = build_decompose_user_prompt(
            brief=req.brief,
            brand=req.brand_context,
            ratio=req.ratio,
            scene_count_hint=req.scene_count_hint,
        )
        response = await agent.arun(user_prompt, user_id=req.user_id)
        draft = response.content
        if not isinstance(draft, StoryboardDraft):
            raise ValueError(
                f"decompose agent returned {type(draft).__name__}, expected StoryboardDraft"
            )
        # Cast first so the web layer can resolve scene cast_ref_keys as scenes arrive.
        for member in draft.cast:
            yield to_sse_line({"event": "cast", "cast": member.model_dump()})
        for scene in sorted(draft.scenes, key=lambda s: s.position):
            yield to_sse_line({"event": "scene", "scene": scene.model_dump()})
        yield to_sse_line({"event": "done"})
    except Exception as exc:  # noqa: BLE001 — stream a terminal error frame, never 500 mid-stream
        log_error(f"[storyboard] decompose failed: {exc}")
        yield to_sse_line({"event": "error", "message": str(exc)})
```

**Steps (TDD)**

1. Write `tests/agents/storyboard/test_decompose_service.py`:
   - Build a fake Agno response: `class _Resp: content = StoryboardDraft(scenes=[DraftScene(position=2, description="B", camera_notes="pan", duration=5, cast_ref_keys=["maya"]), DraftScene(position=1, description="A", camera_notes="push", duration=4, cast_ref_keys=["maya"])], cast=[DraftCastMember(ref_key="maya", name="Maya", kind="character", description="20s athlete")])`.
   - Patch `get_model_config` to return `("r", object())` and patch `app.agents.storyboard.decompose_service.Agent` with a `MagicMock` whose instance `.arun` is an `AsyncMock` returning `_Resp()`.
   - `frames = [line async for line in run_decompose_stream(DecomposeRequest(brief="launch our shoe", user_id="u1"))]`.
   - Assert first frame is `draft_started`; exactly one `cast` frame with `cast.ref_key == "maya"`; two `scene` frames **ordered by position** (first scene event has `scene.position == 1`); last frame is `done`.
   - Add a failure test: make `.arun` raise `RuntimeError("boom")`; assert the frames end with an `error` frame whose `message` contains `"boom"` and that no `done` frame is emitted.
   - Mark both `@pytest.mark.asyncio`.
2. Run `pytest tests/agents/storyboard/test_decompose_service.py -q` → **red**.
3. Create `events.py` and `decompose_service.py`.
4. Re-run → **green** (expected: `2 passed`).

**Commit:** `feat(ai): storyboard decompose SSE stream (brief -> editable draft)`

---

## Task 4 — Cast generate background job (`service.process_cast_generation`)

**Files**

- `app/agents/storyboard/service.py` (create; `process_cast_generation` first)
- `tests/agents/storyboard/test_service.py` (cast cases first)

**Interfaces**

Consumes: `CastGenerateRequest`, `build_cast_prompt`, `post_cast_completed`, `app.tools.generate_image.generate_image`.

Produces:

```python
from uuid import uuid4

from app.agents.storyboard.api_client import post_cast_completed, post_frame_completed
from app.agents.storyboard.prompts.presets import build_cast_prompt, build_frame_prompt
from app.agents.storyboard.request_schema import CastGenerateRequest, SceneFrameRequest
from app.tools.generate_image import generate_image


def process_cast_generation(req: CastGenerateRequest) -> None:
    """Generate-and-lock a cast reference via TEXT-TO-IMAGE (no refs), upload,
    and post the result back. Any failure results in a ``failed`` callback."""
    ai_service_run_id = str(uuid4())
    try:
        prompt = build_cast_prompt(req.description, req.kind, req.brand_context)
        result = generate_image(
            action="Generate a locked cast reference image for a storyboard",
            refined_prompt=prompt,
            image_quality="medium",
            image_model=req.model,
            image_model_provider=req.provider,
            user_id=req.user_id,
            aspect_ratio=req.ratio,
        )
        error_message = result.get("error_message")
        image_url = result.get("image_url")
        if error_message or not image_url:
            post_cast_completed(
                generation_id=req.generation_id,
                cast_member_id=req.cast_member_id,
                status="failed",
                error_message=error_message or "No image_url returned",
            )
            return
        post_cast_completed(
            generation_id=req.generation_id,
            cast_member_id=req.cast_member_id,
            status="ready",
            reference_image_url=image_url,
            token_usage=result.get("token_usage") or None,
            ai_service_run_id=ai_service_run_id,
            model=req.model,
        )
    except Exception as exc:  # noqa: BLE001 — any failure must report back
        post_cast_completed(
            generation_id=req.generation_id,
            cast_member_id=req.cast_member_id,
            status="failed",
            error_message=str(exc),
        )
```

**Steps (TDD)**

1. In `tests/agents/storyboard/test_service.py` add cast cases (mirroring `kv_motion/test_service.py`):
   - `_cast_req(**over)` helper building a valid `CastGenerateRequest` (`generation_id="c1"`, `cast_member_id="cm1"`, `description="Maya, 20s athlete"`, `kind="character"`, `user_id="u1"`).
   - `@patch("app.agents.storyboard.service.post_cast_completed")` + `@patch("app.agents.storyboard.service.generate_image")` returning `{"image_url": "https://cdn/cast.png", "token_usage": {"output_image_tokens": 5}}` → assert `generate_image` called with `image_model="gpt-image-2"`, `image_model_provider="openai"`, `aspect_ratio="1:1"`, and the refined_prompt contains `"Maya"`; assert `post_cast_completed` called with `status="ready"`, `reference_image_url="https://cdn/cast.png"`, `model="gpt-image-2"`.
   - error-dict case: `generate_image` returns `{"error_message": "provider down"}` → `post_cast_completed` `status="failed"`, error contains `"provider down"`.
   - exception case: `generate_image` `side_effect=RuntimeError("boom")` → `status="failed"`, error contains `"boom"`.
2. Run `pytest tests/agents/storyboard/test_service.py -q -k cast` → **red**.
3. Create `service.py` with `process_cast_generation` (and the shared imports; `process_frame_generation` is added in Task 5).
4. Re-run `-k cast` → **green** (expected: `3 passed`).

**Commit:** `feat(ai): storyboard cast generate job (text-to-image + callback)`

---

## Task 5 — Scene frame background job (`service.process_frame_generation`)

**Files**

- `app/agents/storyboard/service.py` (add `process_frame_generation`)
- `tests/agents/storyboard/test_service.py` (frame cases)

**Interfaces**

Consumes: `SceneFrameRequest`, `build_frame_prompt`, `post_frame_completed`, `app.tools.edit_image.edit_image` (aliased `edit_image_fn`), and the KV logo-bake helpers (`resolve_stamp` is api-side; here the api already sends the resolved `brand_logo` = `{logo_url, stamp?}`, so we bake directly with `stamp_logo`). Reuses `app.services.aws.upload_file_to_s3` + `strip_logo_sentences` from `app.agents.kv_generator`.

Produces (append to `service.py`):

```python
import os
import tempfile
from typing import Optional

import requests
from agno.utils.log import log_warning

from app.agents.kv_generator.logo_stamp import stamp_logo, strip_logo_sentences
from app.services.aws import upload_file_to_s3
from app.tools.edit_image import edit_image as edit_image_fn
from app.utils.config import settings


def _download(url: str) -> bytes:
    resp = requests.get(url, timeout=30)
    resp.raise_for_status()
    return resp.content


def _bake_logo(image_url: str, req: SceneFrameRequest) -> str:
    """Composite the brand logo onto the finished frame the KV way. NOT gated
    on brand-knowledge (decoupled per the KV logo-bake lesson). No-op when no
    logo / no stamp is present. Failures degrade to the unstamped image."""
    if req.brand_logo is None or req.brand_logo.stamp is None:
        return image_url
    try:
        scene_bytes = _download(image_url)
        logo_bytes = _download(req.brand_logo.logo_url)
        final_bytes = stamp_logo(
            scene_bytes,
            logo_bytes,
            req.brand_logo.stamp,
        )
        with tempfile.TemporaryDirectory(prefix="storyboard_logo_") as tmp_dir:
            file_name = f"{uuid4().hex}.png"
            file_path = os.path.join(tmp_dir, file_name)
            with open(file_path, "wb") as f:
                f.write(final_bytes)
            new_url = upload_file_to_s3(
                source_path=file_path,
                destination_path=f"{settings.API_ENV}/storyboard-frames/{req.scene_id}/{file_name}",
                file_permission="public",
                content_type="image/png",
            )
        return new_url or image_url
    except Exception as exc:  # noqa: BLE001 — a missing logo must never fail the frame
        log_warning(f"[storyboard] logo bake failed; returning unstamped frame: {exc!r}")
        return image_url


def process_frame_generation(req: SceneFrameRequest) -> None:
    """Render a cast-conditioned scene frame via the edit_image MULTI-REFERENCE
    path, bake the brand logo, and post the result back."""
    ai_service_run_id = str(uuid4())
    try:
        # Strip any leaked logo instruction — the logo is composited below, never drawn.
        brand_name = req.brand_context.brand_name if req.brand_context else None
        prompt = strip_logo_sentences(
            build_frame_prompt(req.description, req.camera_notes, req.brand_context),
            brand_name=brand_name,
        )
        tmp_dir = tempfile.mkdtemp(prefix="storyboard_frame_")
        # Cast references feed the consistency step. First ref is the primary
        # image[] subject; the rest ride as additional references — exactly how
        # the KV generator conditions a craft render on base + N attachments.
        result = edit_image_fn(
            action="Compose a cast-conditioned storyboard scene frame",
            refined_prompt=prompt,
            image_context="",
            image_quality="medium",
            image_model=req.model,
            image_model_provider=req.provider,
            images=req.cast_references,        # downloaded by edit_image, appended to image[]
            user_id=req.user_id,
            temp_folder_path=tmp_dir,
            aspect_ratio=req.ratio,
        )
        error_message = result.get("error_message")
        image_url = result.get("image_url")
        if error_message or not image_url:
            post_frame_completed(
                generation_id=req.generation_id,
                scene_id=req.scene_id,
                frame_id=req.frame_id,
                status="failed",
                error_message=error_message or "No image_url returned",
            )
            return
        # Keep the logo-free render as source_image_url so future iterations
        # reuse it as the img-to-img base (the model never sees a baked logo).
        source_image_url = image_url
        stamped_url = _bake_logo(image_url, req)
        post_frame_completed(
            generation_id=req.generation_id,
            scene_id=req.scene_id,
            frame_id=req.frame_id,
            status="ready",
            image_url=stamped_url,
            source_image_url=source_image_url,
            thumbnail_url=stamped_url,
            prompt_snapshot=prompt,
            model=req.model,
            cast_refs_used=req.cast_refs_used,
            token_usage=result.get("token_usage") or None,
            ai_service_run_id=ai_service_run_id,
        )
    except Exception as exc:  # noqa: BLE001
        post_frame_completed(
            generation_id=req.generation_id,
            scene_id=req.scene_id,
            frame_id=req.frame_id,
            status="failed",
            error_message=str(exc),
        )
```

Move the `import os/tempfile/requests` + `from uuid import uuid4` to the top of `service.py` (single import block; don't duplicate the Task-4 `uuid4` import).

**Steps (TDD)**

1. Add frame cases to `tests/agents/storyboard/test_service.py`:
   - `_frame_req(**over)` building a valid `SceneFrameRequest` (`generation_id="f1"`, `scene_id="s1"`, `frame_id="fr1"`, `description="runner crests a hill at dawn"`, `camera_notes="wide low-angle"`, `cast_references=["https://cdn/maya.png"]`, `cast_refs_used=["cm1"]`, `user_id="u1"`).
   - happy path: `@patch("app.agents.storyboard.service.post_frame_completed")`, `@patch("app.agents.storyboard.service._bake_logo", side_effect=lambda url, req: url)`, `@patch("app.agents.storyboard.service.edit_image_fn")` returning `{"image_url": "https://cdn/frame.png", "token_usage": {"output_image_tokens": 9}}` → assert `edit_image_fn` called with `images=["https://cdn/maya.png"]`, `image_model="gpt-image-2"`, `image_model_provider="openai"`, `aspect_ratio="16:9"`, and refined_prompt contains `"runner crests a hill"` and `"reference image"`; assert `post_frame_completed` called with `status="ready"`, `image_url="https://cdn/frame.png"`, `source_image_url="https://cdn/frame.png"`, `cast_refs_used=["cm1"]`, `model="gpt-image-2"`.
   - logo bake wiring: patch `_bake_logo` to `return "https://cdn/frame-logo.png"` → assert callback `image_url == "https://cdn/frame-logo.png"` while `source_image_url == "https://cdn/frame.png"`.
   - error-dict case: `edit_image_fn` returns `{"error_message": "provider down"}` → `status="failed"`, error contains `"provider down"` (and `_bake_logo` NOT called — patch it as a `MagicMock` and assert `not called`).
   - exception case: `edit_image_fn` `side_effect=RuntimeError("boom")` → `status="failed"`, error contains `"boom"`.
2. Run `pytest tests/agents/storyboard/test_service.py -q -k frame` → **red**.
3. Add `process_frame_generation` + helpers to `service.py`.
4. Re-run full file: `pytest tests/agents/storyboard/test_service.py -q` → **green** (expected: cast 3 + frame 4 = `7 passed`).

**Commit:** `feat(ai): storyboard scene frame job (multi-ref edit_image + logo bake + callback)`

---

## Task 6 — Router + app registration

**Files**

- `app/agents/storyboard/router.py`
- `ai-service/main.py` (register the router — 2 lines)
- `tests/agents/storyboard/test_router.py`

**Interfaces**

Consumes: the three request schemas, the two accepted schemas, `run_decompose_stream`, `process_cast_generation`, `process_frame_generation`.

Produces:

```python
# router.py
from fastapi import APIRouter, BackgroundTasks
from fastapi.responses import JSONResponse, StreamingResponse

from app.agents.storyboard.decompose_service import run_decompose_stream
from app.agents.storyboard.request_schema import (
    CastGenerateRequest,
    DecomposeRequest,
    SceneFrameRequest,
)
from app.agents.storyboard.response_schema import (
    CastGenerateAccepted,
    SceneFrameAccepted,
)
from app.agents.storyboard.service import (
    process_cast_generation,
    process_frame_generation,
)

router = APIRouter(prefix="/ai/storyboard", tags=["storyboard"])


@router.post("/decompose")
async def decompose(req: DecomposeRequest):
    async def generator():
        async for line in run_decompose_stream(req):
            yield line

    return StreamingResponse(generator(), media_type="application/x-ndjson")


@router.post("/cast/generate", response_model=CastGenerateAccepted, status_code=202)
def cast_generate(req: CastGenerateRequest, background: BackgroundTasks):
    background.add_task(process_cast_generation, req)
    return JSONResponse(
        status_code=202,
        content=CastGenerateAccepted(generation_id=req.generation_id).model_dump(),
    )


@router.post("/scenes/frame", response_model=SceneFrameAccepted, status_code=202)
def scene_frame(req: SceneFrameRequest, background: BackgroundTasks):
    background.add_task(process_frame_generation, req)
    return JSONResponse(
        status_code=202,
        content=SceneFrameAccepted(generation_id=req.generation_id).model_dump(),
    )
```

`main.py` changes (mirror the `kv_motion_router` lines):

```python
# with the other kv imports near the top:
from app.agents.storyboard.router import router as storyboard_router
# ...with the other include_router calls:
app.include_router(storyboard_router)
```

**Steps (TDD)**

1. Write `tests/agents/storyboard/test_router.py` (mirror `kv_motion/test_router.py` + a decompose stream case):
   - `from fastapi.testclient import TestClient; from main import app; client = TestClient(app)`.
   - `@patch("app.agents.storyboard.router.process_cast_generation")` → POST `/ai/storyboard/cast/generate` with a valid body → `status_code == 202`, `json() == {"generation_id": "c1", "status": "accepted"}`, `mock.assert_called_once()`.
   - `@patch("app.agents.storyboard.router.process_frame_generation")` → POST `/ai/storyboard/scenes/frame` with a valid body (one `cast_references` URL) → `202` + `{"generation_id": "f1", "status": "accepted"}`, called once.
   - validation: POST `/ai/storyboard/scenes/frame` with empty `cast_references` → `422`.
   - decompose stream: `@patch("app.agents.storyboard.router.run_decompose_stream")` with an async-generator stub yielding `'{"event": "draft_started"}\n'` and `'{"event": "done"}\n'` → POST `/ai/storyboard/decompose` → `200`, response text contains `"draft_started"` and `"done"`.
2. Run `pytest tests/agents/storyboard/test_router.py -q` → **red**.
3. Create `router.py`; add the two lines to `main.py`.
4. Re-run → **green** (expected: `4 passed`).
5. Full-package gate: `pytest tests/agents/storyboard/ -q` → expected `X passed` across all files (schemas 5 + decompose_schema 3 + presets 3 + api_client 4 + decompose_service 2 + service 7 + router 4 ≈ `28 passed`, adjust to actual assertion count).

**Commit:** `feat(ai): register storyboard router (decompose SSE + cast/frame 202 endpoints)`

---

## Self-review checklist (run before opening the PR)

- [ ] `pytest tests/agents/storyboard/ -q` all green.
- [ ] No import from `app.tools.*` was modified — `generate_image` / `edit_image` called through their existing signatures only.
- [ ] Every background job has three exit paths (success callback, tool-error `failed` callback, exception `failed` callback) and never raises out of the BackgroundTask.
- [ ] `decompose` persists nothing and returns a `StreamingResponse` (no callback, no `202`).
- [ ] Callback client uses `X-Internal-Token` + `settings.API_INTERNAL_URL`, `timeout=10`, `raise_for_status()`.
- [ ] Logo bake runs whenever a stamp + logo bytes are present, independent of any brand-knowledge flag.
- [ ] Type consistency: `generation_id` echoed unchanged in every callback; `ratio`/`model`/`provider` defaults match the cross-service contract (`gpt-image-2` / `openai`).
- [ ] Placeholder scan: no `TODO`, no `...`, no `pass`-only bodies, no stub URLs left in shipped code.
```
