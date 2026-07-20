# Studio Storyboard → Video — Phase 2 (ai-service) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development` — execute each task as an isolated TDD unit (write the failing test, make it pass, commit), dispatching one subagent per task and reviewing its diff before moving on.

**Goal**

Ship the ai-service surface for Phase 2 of the Studio Storyboard tool: a single new **async clip** operation added to the **existing** `app/agents/storyboard/` package (created in Phase 1). Phase 2 clips are essentially KV Motion applied per scene — the operation reuses `app/tools/generate_video.generate_video` verbatim (the KV Motion direct-call path) and the KV Motion motion-preset prompt fragments.

1. `POST /ai/storyboard/scenes/clip` — **202 Accepted + BackgroundTask** that builds a refined motion prompt from the motion preset + motion prompt (reusing `app/agents/kv_motion/prompts/presets.build_motion_prompt`), calls `generate_video` with the approved scene frame as the first frame, then posts a `clip-complete` callback to the api.

Frames (Phase 1), stitch (Phase 3), and all api/web work are **out of scope** for this plan. Do NOT create a new package — add to the existing `app/agents/storyboard/`.

**Architecture**

- The clip op follows the codebase's proven async pattern verbatim (identical to `app/agents/kv_motion/`): the router returns `202` immediately and dispatches a `BackgroundTasks` job; the job runs `generate_video`, then POSTs the result back to the api's internal callback controller with an `X-Internal-Token` header. The DB is the source of truth; the browser polls. Never persist from ai-service.
- `generate_video` is called **direct** (NOT through Agno), exactly as KV Motion does — same argument names, same first-frame-image path.
- The clip op is added **alongside** the Phase 1 ops in the same package: a new `ClipGenerateRequest` in `request_schema.py`, a `ClipGenerateAccepted` in `response_schema.py`, a `process_clip_generation` in `service.py`, a `post_clip_completed` in `api_client.py`, and a `POST /scenes/clip` route in `router.py`.

**Tech Stack**

- FastAPI (`BackgroundTasks`, `JSONResponse`), Pydantic v2 schemas.
- Existing tool reused verbatim: `app.tools.generate_video.generate_video` (the KV Motion direct-call path).
- Existing helper reused verbatim: `app.agents.kv_motion.prompts.presets.build_motion_prompt` (the motion-preset prompt fragments) — imported, not copied.
- `requests` for the internal callback POST; `pytest` + `unittest.mock` for tests (mirrors `tests/agents/kv_motion/`).

## Global Constraints

- **Target branch:** `development` (ai-service default branch). Continue on the Phase 1 storyboard feature branch `feature/<worker>/vc-studio-storyboard-video` (Phase 2 is additive).
- **Reuse `generate_video` verbatim** — pass args through its existing signature (the KV Motion call verbatim):
  - `generate_video(action, refined_prompt, duration, video_ratio, first_frame_image, video_model, video_model_provider, generate_audio, negative_prompt="")` — returns `{"video_url", "token_usage", ...}` or an error dict `{"error_message", ...}`. **No new model integrations**, no edits to `app/tools/*`.
- **Reuse `build_motion_prompt` verbatim** — `from app.agents.kv_motion.prompts.presets import build_motion_prompt`. It combines a preset fragment with optional free-text steering and raises `ValueError` if both are absent. Do NOT re-implement the preset fragments.
- **Callback via `X-Internal-Token`** to `settings.API_INTERNAL_URL`, `timeout=10`, `.raise_for_status()` — copy `app/agents/kv_motion/api_client.py` shape exactly. `token_usage`, `ai_service_run_id`, and `model` must be forwarded so the api can meter `storyboard_clip_generation`.
- **Canonical status vocab (load-bearing across all three Phase-2 plans).** The clip callback `status` is exactly `"ready"` | `"failed"` — **NOT** KV Motion's `"done"`. Success → `status="ready"`; any tool-error dict or exception → `status="failed"` + `error_message`. The job never raises out of the BackgroundTask.
- **Canonical dispatch body (from api).** The router receives `{clip_id, scene_id, storyboard_id, frame_id, source_image_url, duration, ratio, motion_preset, motion_prompt, model, provider, generate_audio, created_by}`. `clip_id` is the idempotency key echoed unchanged in the callback.
- **Canonical callback (ai→api):** `POST /api/v1/internal/storyboard-scene-clips/completed`, header `X-Internal-Token`, body `{clip_id, scene_id, status, video_url?, duration?, model?, provider?, error_message?, token_usage?, ai_service_run_id?}`.
- **DRY / YAGNI / TDD.** No speculative fields. Every task writes the test first. Mirror `tests/agents/kv_motion/`.

## File Structure

```
ai-service/
├── app/agents/storyboard/          # EXISTING package (Phase 1) — ADD to it, do NOT create new
│   ├── request_schema.py           # + ClipGenerateRequest
│   ├── response_schema.py          # + ClipGenerateAccepted
│   ├── api_client.py               # + post_clip_completed()
│   ├── service.py                  # + process_clip_generation()
│   └── router.py                   # + POST /scenes/clip
└── tests/agents/storyboard/        # EXISTING test dir — ADD cases
    ├── test_schemas.py             # + ClipGenerateRequest / ClipGenerateAccepted cases
    ├── test_api_client.py          # + post_clip_completed cases
    ├── test_service.py             # + clip cases (generate_video mocked)
    └── test_router.py              # + POST /scenes/clip 202 + 422 cases
```

No new files, no `main.py` change (the storyboard router is already registered in Phase 1; the new route is added to the existing `router.py`).

---

## Task 1 — Clip request/response schemas

**Files**

- `app/agents/storyboard/request_schema.py` (add `ClipGenerateRequest`)
- `app/agents/storyboard/response_schema.py` (add `ClipGenerateAccepted`)
- `tests/agents/storyboard/test_schemas.py` (add clip cases)

**Interfaces**

Consumes: nothing new (leaf schemas). Produces:

```python
# request_schema.py — append (keep the Phase 1 imports; add Optional/Field if missing)
class ClipGenerateRequest(BaseModel):
    clip_id: str                       # api-side scene_clips row id; echoed in the callback (idempotency key)
    scene_id: str
    storyboard_id: str
    frame_id: str
    source_image_url: str              # the approved scene frame — animated as first_frame_image
    duration: int = 8
    ratio: str = "9:16"
    motion_preset: Optional[str] = None
    motion_prompt: Optional[str] = None
    model: str
    provider: str                      # google | kuaishou | openai | bytedance | …
    generate_audio: bool = True
    created_by: Optional[str] = None

    @model_validator(mode="after")
    def _require_preset_or_prompt(self) -> "ClipGenerateRequest":
        # A clip needs *some* motion steering — mirrors KV Motion's rule so
        # build_motion_prompt never raises inside the background job.
        if not self.motion_preset and not (self.motion_prompt and self.motion_prompt.strip()):
            raise ValueError("Either a motion_preset or a non-blank motion_prompt is required")
        return self
```

```python
# response_schema.py — append
class ClipGenerateAccepted(BaseModel):
    clip_id: str
    status: str = "accepted"
```

**Steps (TDD)**

1. In `tests/agents/storyboard/test_schemas.py` add:
   - a valid `ClipGenerateRequest` (`clip_id="cl1"`, `scene_id="s1"`, `storyboard_id="sb1"`, `frame_id="fr1"`, `source_image_url="https://cdn/frame.png"`, `model="veo-3.1-fast-generate-preview"`, `provider="google"`, `motion_preset="subtle_zoom"`) parses with defaults `duration=8`, `ratio="9:16"`, `generate_audio=True`.
   - a `ClipGenerateRequest` with no `motion_preset` and a blank `motion_prompt="  "` raises `ValidationError` matching `"motion_preset or a non-blank motion_prompt"`.
   - a `ClipGenerateRequest` with `motion_preset=None` and `motion_prompt="drift slowly"` parses.
   - `ClipGenerateAccepted(clip_id="cl1").status == "accepted"`.
2. Run `pytest tests/agents/storyboard/test_schemas.py -q` → **red** (new symbols missing).
3. Add `ClipGenerateRequest` to `request_schema.py` and `ClipGenerateAccepted` to `response_schema.py`.
4. Re-run → **green** (Phase 1 schema cases + the 4 new clip cases pass).

**Commit:** `feat(ai): storyboard clip request/accepted schemas (phase 2)`

---

## Task 2 — Clip callback client (`post_clip_completed`)

**Files**

- `app/agents/storyboard/api_client.py` (add `post_clip_completed`)
- `tests/agents/storyboard/test_api_client.py` (add clip cases)

**Interfaces**

Consumes: `app.utils.config.settings` (`API_INTERNAL_URL`, `API_INTERNAL_TOKEN`) and the existing `_post_internal` helper from Phase 1. Produces:

```python
# api_client.py — append (reuse the Phase 1 _post_internal helper)
def post_clip_completed(
    *,
    clip_id: str,
    scene_id: str,
    status: str,
    video_url: Optional[str] = None,
    duration: Optional[int] = None,
    model: Optional[str] = None,
    provider: Optional[str] = None,
    error_message: Optional[str] = None,
    token_usage: Optional[Dict[str, Any]] = None,
    ai_service_run_id: Optional[str] = None,
) -> None:
    payload: dict = {
        "clip_id": clip_id,
        "scene_id": scene_id,
        "status": status,
    }
    for key, val in (
        ("video_url", video_url),
        ("duration", duration),
        ("model", model),
        ("provider", provider),
        ("error_message", error_message),
        ("ai_service_run_id", ai_service_run_id),
    ):
        if val is not None:
            payload[key] = val
    if token_usage:
        payload["token_usage"] = token_usage
    _post_internal("/api/v1/internal/storyboard-scene-clips/completed", payload)
```

**Steps (TDD)**

1. In `tests/agents/storyboard/test_api_client.py` add (mirroring the Phase 1 cast/frame cases):
   - `@patch("app.agents.storyboard.api_client.requests.post")` returning `MagicMock(status_code=200, raise_for_status=lambda: None)`.
   - `post_clip_completed(clip_id="cl1", scene_id="s1", status="ready", video_url="https://cdn/clip.mp4", duration=8, model="veo-3.1-fast-generate-preview", provider="google", token_usage={"output_video_tokens": 8}, ai_service_run_id="run-1")` → assert url ends with `/api/v1/internal/storyboard-scene-clips/completed`, `json["clip_id"] == "cl1"`, `json["video_url"] == "https://cdn/clip.mp4"`, `json["duration"] == 8`, `json["token_usage"] == {"output_video_tokens": 8}`, `"X-Internal-Token" in headers`.
   - `post_clip_completed(clip_id="cl1", scene_id="s1", status="failed", error_message="boom")` → `json["status"] == "failed"`, `json["error_message"] == "boom"`, `"video_url" not in json`.
2. Run `pytest tests/agents/storyboard/test_api_client.py -q` → **red**.
3. Add `post_clip_completed` to `api_client.py`.
4. Re-run → **green** (Phase 1 cases + the 2 new clip cases pass).

**Commit:** `feat(ai): storyboard clip internal callback client`

---

## Task 3 — Clip background job (`service.process_clip_generation`)

**Files**

- `app/agents/storyboard/service.py` (add `process_clip_generation`)
- `tests/agents/storyboard/test_service.py` (add clip cases)

**Interfaces**

Consumes: `ClipGenerateRequest`, `build_motion_prompt` (from `app.agents.kv_motion.prompts.presets`), `post_clip_completed`, `app.tools.generate_video.generate_video` (aliased `generate_video_fn`). Produces (append to `service.py`):

```python
# service.py — append (add imports at the top import block; do NOT duplicate uuid4)
from app.agents.kv_motion.prompts.presets import build_motion_prompt
from app.agents.storyboard.api_client import post_clip_completed
from app.agents.storyboard.request_schema import ClipGenerateRequest
from app.tools.generate_video import generate_video as generate_video_fn


def process_clip_generation(req: ClipGenerateRequest) -> None:
    """Animate an approved scene frame into a short clip and post the result back.

    KV Motion applied per scene: the scene frame is the first frame; the motion
    preset + prompt steer the motion via the SAME build_motion_prompt fragments.
    generate_video is the KV Motion direct-call path verbatim. Any failure (tool
    error dict or exception) results in a ``failed`` callback.
    """
    ai_service_run_id = str(uuid4())
    try:
        refined_prompt = build_motion_prompt(req.motion_preset, req.motion_prompt)

        result = generate_video_fn(
            action="Animate an approved storyboard scene frame into a short clip",
            refined_prompt=refined_prompt,
            duration=str(req.duration),
            video_ratio=req.ratio,
            first_frame_image=req.source_image_url,
            video_model=req.model,
            video_model_provider=req.provider,
            generate_audio=req.generate_audio,
        )

        error_message = result.get("error_message")
        video_url = result.get("video_url")
        if error_message or not video_url:
            post_clip_completed(
                clip_id=req.clip_id,
                scene_id=req.scene_id,
                status="failed",
                error_message=error_message or "No video_url returned",
            )
            return

        post_clip_completed(
            clip_id=req.clip_id,
            scene_id=req.scene_id,
            status="ready",
            video_url=video_url,
            duration=req.duration,
            model=req.model,
            provider=req.provider,
            token_usage=result.get("token_usage") or None,
            ai_service_run_id=ai_service_run_id,
        )
    except Exception as exc:  # noqa: BLE001 — any failure must report back
        post_clip_completed(
            clip_id=req.clip_id,
            scene_id=req.scene_id,
            status="failed",
            error_message=str(exc),
        )
```

**Steps (TDD)**

1. In `tests/agents/storyboard/test_service.py` add clip cases (mirroring `kv_motion/test_service.py`):
   - `_clip_req(**over)` helper building a valid `ClipGenerateRequest` (`clip_id="cl1"`, `scene_id="s1"`, `storyboard_id="sb1"`, `frame_id="fr1"`, `source_image_url="https://cdn/frame.png"`, `model="veo-3.1-fast-generate-preview"`, `provider="google"`, `motion_preset="subtle_zoom"`, `motion_prompt="gentle push in"`, `duration=8`, `ratio="9:16"`, `generate_audio=False`).
   - happy path: `@patch("app.agents.storyboard.service.post_clip_completed")` + `@patch("app.agents.storyboard.service.generate_video_fn")` returning `{"video_url": "https://cdn/clip.mp4", "token_usage": {"output_video_tokens": 8}}` → assert `generate_video_fn` called with `duration="8"` (string), `video_ratio="9:16"`, `first_frame_image="https://cdn/frame.png"`, `video_model="veo-3.1-fast-generate-preview"`, `video_model_provider="google"`, `generate_audio=False`, and `refined_prompt` contains the preset fragment text (`"push-in"` / from `MOTION_PRESETS["subtle_zoom"]`) AND `"gentle push in"`; assert `post_clip_completed` called with `status="ready"`, `video_url="https://cdn/clip.mp4"`, `duration=8`, `model="veo-3.1-fast-generate-preview"`, `provider="google"`, `token_usage={"output_video_tokens": 8}`.
   - error-dict case: `generate_video_fn` returns `{"error_message": "provider down"}` → `post_clip_completed` `status="failed"`, error contains `"provider down"`, `"video_url" not in payload`.
   - exception case: `generate_video_fn` `side_effect=RuntimeError("boom")` → `status="failed"`, error contains `"boom"`.
   - prompt-only case: `_clip_req(motion_preset=None, motion_prompt="drift slowly")` → `refined_prompt == "drift slowly"` passed to `generate_video_fn`, callback `status="ready"`.
2. Run `pytest tests/agents/storyboard/test_service.py -q -k clip` → **red**.
3. Add `process_clip_generation` + imports to `service.py`.
4. Re-run `-k clip` → **green** (expected: `4 passed`); then run the full file to confirm Phase 1 cast/frame cases still pass.

**Commit:** `feat(ai): storyboard clip job (generate_video direct-call + callback)`

---

## Task 4 — Clip router endpoint

**Files**

- `app/agents/storyboard/router.py` (add `POST /scenes/clip`)
- `tests/agents/storyboard/test_router.py` (add clip cases)

**Interfaces**

Consumes: `ClipGenerateRequest`, `ClipGenerateAccepted`, `process_clip_generation`. Produces (append to the existing `router.py`):

```python
# router.py — extend the existing imports
from app.agents.storyboard.request_schema import (
    CastGenerateRequest,
    ClipGenerateRequest,
    DecomposeRequest,
    SceneFrameRequest,
)
from app.agents.storyboard.response_schema import (
    CastGenerateAccepted,
    ClipGenerateAccepted,
    SceneFrameAccepted,
)
from app.agents.storyboard.service import (
    process_cast_generation,
    process_clip_generation,
    process_frame_generation,
)

# ...append the new route to the existing router:
@router.post("/scenes/clip", response_model=ClipGenerateAccepted, status_code=202)
def scene_clip(req: ClipGenerateRequest, background: BackgroundTasks):
    background.add_task(process_clip_generation, req)
    return JSONResponse(
        status_code=202,
        content=ClipGenerateAccepted(clip_id=req.clip_id).model_dump(),
    )
```

**Steps (TDD)**

1. In `tests/agents/storyboard/test_router.py` add (mirror the Phase 1 frame case + KV Motion `test_router.py`):
   - `@patch("app.agents.storyboard.router.process_clip_generation")` → POST `/ai/storyboard/scenes/clip` with a valid body (`clip_id="cl1"`, `scene_id="s1"`, `storyboard_id="sb1"`, `frame_id="fr1"`, `source_image_url="https://cdn/frame.png"`, `model="veo-3.1-fast-generate-preview"`, `provider="google"`, `motion_preset="subtle_zoom"`, `duration=8`, `ratio="9:16"`, `generate_audio=True`) → `status_code == 202`, `json() == {"clip_id": "cl1", "status": "accepted"}`, `mock.assert_called_once()`.
   - validation: POST `/ai/storyboard/scenes/clip` with no `motion_preset` and blank `motion_prompt` → `422`.
2. Run `pytest tests/agents/storyboard/test_router.py -q` → **red**.
3. Add the `/scenes/clip` route + extend the imports in `router.py`.
4. Re-run → **green** (Phase 1 router cases + the 2 new clip cases pass).
5. Full-package gate: `pytest tests/agents/storyboard/ -q` → all Phase 1 + Phase 2 cases pass.

**Commit:** `feat(ai): register storyboard clip route (POST /scenes/clip, 202)`

---

## Self-review checklist (run before opening the PR)

- [ ] `pytest tests/agents/storyboard/ -q` all green (Phase 1 + Phase 2).
- [ ] No import from `app.tools.*` was modified — `generate_video` called through its existing signature only (the KV Motion call verbatim).
- [ ] `build_motion_prompt` is **imported** from `app.agents.kv_motion.prompts.presets`, not re-implemented.
- [ ] The clip job has three exit paths (success `ready` callback, tool-error `failed` callback, exception `failed` callback) and never raises out of the BackgroundTask.
- [ ] Callback status vocab is `"ready"` / `"failed"` (NOT `"done"`); `clip_id` echoed unchanged; `token_usage`/`ai_service_run_id`/`model`/`provider`/`duration` forwarded so the api can meter `storyboard_clip_generation`.
- [ ] Callback URL is `/api/v1/internal/storyboard-scene-clips/completed` with `X-Internal-Token` + `settings.API_INTERNAL_URL`, `timeout=10`, `raise_for_status()`.
- [ ] Placeholder scan: no `TODO`, no `...`, no `pass`-only bodies, no stub URLs left in shipped code.
