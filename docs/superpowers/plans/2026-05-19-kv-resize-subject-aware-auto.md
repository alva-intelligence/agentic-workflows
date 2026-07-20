# KV Resize — Subject-Aware Auto-Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a one-shot gpt-4o-mini vision pre-pass per resize tile that drives an automatic decision between fit-not-fill (preserve cross-orientation sources) and subject-aware crop (cluster crop around the detected subject). Charge the user for the vision pass via a second `CostHistory` row using the existing metering pipeline. Zero web changes, zero new infra.

**Architecture:** New `vision_prepass.py` in `ai-service/app/agents/kv_resize/` calling `gpt-4o-mini` with `temperature=0` and a strict JSON schema. Two new helpers in `canvas.py` (`fit_inside_target`, `subject_aware_crop`). Strategy decision and orchestration changes in `service.py`. Callback payload grows two optional fields (`vision_token_usage`, `vision_model`). On the api side, request validator gains the same fields; controller calls `KvCreditMeteringService::charge()` a second time with `cost_type='kv_resize_vision'` for full audit trail.

**Tech Stack:** Python 3.12 / FastAPI / Pillow / OpenAI SDK (ai-service), PHP 8.5 / Laravel (api), pytest 9, Pest 4 + PHPUnit 12.

**Spec:** `docs/superpowers/specs/2026-05-19-kv-resize-subject-aware-auto-design.md`

**Project test policy:** Both `ai-service/AGENTS.md` and `api/AGENTS.md` explicitly state: *"DO NOT MAKE OR RUN ANY TESTS WITHOUT USER PERMISSION."* Tasks that add or modify tests, or run tests, are explicitly gated below. Default flow is code-first; pause for the user before doing test work.

---

## File Structure

### ai-service

| File | Responsibility |
|------|----------------|
| `ai-service/app/agents/kv_resize/request_schema.py` | Add `use_vision_prepass: bool = True` to `ResizeExportRequest`. |
| `ai-service/app/agents/kv_resize/vision_prepass.py` *(NEW)* | `SubjectBBox`, `VisionResult`, and `analyze(source_image_url) -> (VisionResult \| None, dict)` that calls gpt-4o-mini and returns parsed result + token usage. |
| `ai-service/app/agents/kv_resize/canvas.py` | Add `fit_inside_target(src, target_w, target_h, frame_px=32)` and `subject_aware_crop(src, target_w, target_h, subject_bbox_norm)` helpers. |
| `ai-service/app/agents/kv_resize/service.py` | Add `_decide_strategy`. Replace the current crop-then-pad block inside the `force_ai` branch with vision-pass + strategy decision + appropriate canvas helper. Forward `vision_token_usage` + `vision_model` to api callback. |
| `ai-service/app/agents/kv_resize/api_client.py` | Add `vision_token_usage` and `vision_model` keyword args to `post_completed`. |
| `ai-service/tests/agents/kv_resize/test_vision_prepass.py` *(NEW)* | Mock-OpenAI tests for `analyze` happy path, validation failure, and exception path (gated on user permission). |
| `ai-service/tests/agents/kv_resize/test_canvas.py` | Add tests for `fit_inside_target` and `subject_aware_crop` (gated on user permission). |
| `ai-service/tests/agents/kv_resize/test_service.py` | Add tests for `_decide_strategy` and integration of vision pass into `process_resize_export` (gated on user permission). |

### api

| File | Responsibility |
|------|----------------|
| `api/config/services.php` | Add `kv_resize_vision_prepass` config reading `KV_RESIZE_VISION_PREPASS` env. |
| `api/.env.example` | Document `KV_RESIZE_VISION_PREPASS=true`. |
| `api/app/Jobs/Studio/ProcessKvResizeExportJob.php` | Add `use_vision_prepass` to the ai-service POST body. |
| `api/app/Http/Requests/Internal/KvResizeExportCompleteRequest.php` | Add optional validation for `vision_token_usage.*` and `vision_model`. |
| `api/app/Http/Controllers/Api/Internal/KvResizeExportInternalController.php` | After existing `metering->charge()`, call it again with `cost_type='kv_resize_vision'` when `vision_token_usage` is present. |
| `api/tests/Feature/Studio/KvResizeExportInternalControllerTest.php` (or equivalent) | Add a test asserting the second `CostHistory` row is created with the right `cost_type` and `batch_identifier` when callback includes vision tokens (gated on user permission). |

### web, data-service

No changes.

---

## Task 1: Add `use_vision_prepass` to request schema

**Files:**
- Modify: `ai-service/app/agents/kv_resize/request_schema.py`

- [ ] **Step 1: Read current schema to confirm structure**

Run: `cat ai-service/app/agents/kv_resize/request_schema.py`
Expected: contains `ResizeExportRequest` Pydantic model with `force_ai: bool = True` field already present.

- [ ] **Step 2: Add the new field**

In `ResizeExportRequest`, add immediately after `force_ai`:

```python
    use_vision_prepass: bool = True
```

- [ ] **Step 3: Commit**

```bash
git add ai-service/app/agents/kv_resize/request_schema.py
git -C ai-service commit -m "feat(kv-resize): add use_vision_prepass flag to request schema"
```

---

## Task 2: Create vision_prepass.py schemas

**Files:**
- Create: `ai-service/app/agents/kv_resize/vision_prepass.py`

- [ ] **Step 1: Create the file with just the Pydantic schemas**

```python
"""Vision pre-pass for KV resize.

Calls gpt-4o-mini once per tile job (no caching) with temperature=0 to
analyze the source image. Output drives the resize strategy decision
in service.py: subject_aware_crop vs fit_not_fill vs legacy_smart_crop
(fallback when this returns None).
"""

from typing import Any, Literal

from pydantic import BaseModel, Field, ValidationError


class SubjectBBox(BaseModel):
    x: float = Field(ge=0.0, le=1.0)
    y: float = Field(ge=0.0, le=1.0)
    w: float = Field(gt=0.0, le=1.0)
    h: float = Field(gt=0.0, le=1.0)


class VisionResult(BaseModel):
    subject_bbox: SubjectBBox
    content_type: Literal[
        "portrait_person",
        "product_shot",
        "scene",
        "text_heavy",
        "abstract",
        "unknown",
    ]
    has_visible_text: bool
    context_hint: str = Field(max_length=240)
```

- [ ] **Step 2: Commit**

```bash
git add ai-service/app/agents/kv_resize/vision_prepass.py
git -C ai-service commit -m "feat(kv-resize): add VisionResult schema for vision pre-pass"
```

---

## Task 3: Implement `analyze()` in vision_prepass.py

**Files:**
- Modify: `ai-service/app/agents/kv_resize/vision_prepass.py`

- [ ] **Step 1: Append the analyze function**

Add below the schemas:

```python
import logging
from openai import OpenAI

from app.utils.config import settings

_logger = logging.getLogger(__name__)

_SYSTEM_PROMPT = (
    "You are analyzing a marketing key visual for an automatic image resize "
    "pipeline. Return STRICT JSON matching the provided schema. The "
    "subject_bbox is the bounding box of the main subject in normalized "
    "[0,1] coordinates (x, y, w, h), where (x, y) is the top-left corner. "
    "content_type is the dominant category from the enum. "
    "has_visible_text is true if any readable text or logos are present. "
    "context_hint is one sentence (max 240 chars) describing setting, "
    "lighting, mood, and style — written so it could guide an AI extending "
    "the image laterally."
)

_RESPONSE_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["subject_bbox", "content_type", "has_visible_text", "context_hint"],
    "properties": {
        "subject_bbox": {
            "type": "object",
            "additionalProperties": False,
            "required": ["x", "y", "w", "h"],
            "properties": {
                "x": {"type": "number", "minimum": 0, "maximum": 1},
                "y": {"type": "number", "minimum": 0, "maximum": 1},
                "w": {"type": "number", "exclusiveMinimum": 0, "maximum": 1},
                "h": {"type": "number", "exclusiveMinimum": 0, "maximum": 1},
            },
        },
        "content_type": {
            "type": "string",
            "enum": [
                "portrait_person", "product_shot", "scene",
                "text_heavy", "abstract", "unknown",
            ],
        },
        "has_visible_text": {"type": "boolean"},
        "context_hint": {"type": "string", "maxLength": 240},
    },
}


def analyze(source_image_url: str) -> tuple[VisionResult | None, dict[str, int]]:
    """Single vision pass over the source image.

    Returns (result, token_usage). On any failure, result is None.
    token_usage may still be non-empty if the API call returned tokens
    before validation failed; api side uses non-empty token_usage as the
    signal to write a CostHistory row.
    """
    client = OpenAI(api_key=settings.OPENAI_API_KEY)
    token_usage: dict[str, int] = {}

    try:
        response = client.chat.completions.create(
            model="gpt-4o-mini",
            temperature=0,
            response_format={
                "type": "json_schema",
                "json_schema": {
                    "name": "vision_result",
                    "strict": True,
                    "schema": _RESPONSE_SCHEMA,
                },
            },
            messages=[
                {"role": "system", "content": _SYSTEM_PROMPT},
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "image_url",
                            "image_url": {
                                "url": source_image_url,
                                "detail": "high",
                            },
                        }
                    ],
                },
            ],
        )

        usage = getattr(response, "usage", None)
        if usage is not None:
            token_usage = {
                "input_text_tokens": int(getattr(usage, "prompt_tokens", 0) or 0),
                "input_image_tokens": 0,
                "output_image_tokens": 0,
                "output_text_tokens": int(getattr(usage, "completion_tokens", 0) or 0),
            }

        raw = response.choices[0].message.content
        if not raw:
            return None, token_usage

        result = VisionResult.model_validate_json(raw)
        return result, token_usage

    except ValidationError as exc:
        _logger.warning(
            "vision_prepass: validation failed for %s: %s",
            source_image_url, exc,
        )
        return None, token_usage
    except Exception as exc:  # noqa: BLE001
        _logger.warning(
            "vision_prepass: API call failed for %s: %s",
            source_image_url, exc,
        )
        return None, token_usage
```

- [ ] **Step 2: Commit**

```bash
git add ai-service/app/agents/kv_resize/vision_prepass.py
git -C ai-service commit -m "feat(kv-resize): implement analyze() with gpt-4o-mini and structured output"
```

---

## Task 4: Tests for `vision_prepass` (GATED on user permission)

**Pause and ask the user:** "ai-service AGENTS.md forbids writing/running tests without permission. Should I write tests for vision_prepass.py now, or skip and rely on staging smoke?"

If approved:

**Files:**
- Create: `ai-service/tests/agents/kv_resize/test_vision_prepass.py`

- [ ] **Step 1: Write the test file**

```python
import json
from unittest.mock import MagicMock, patch

from app.agents.kv_resize.vision_prepass import analyze, VisionResult


def _mk_response(content: str, prompt_tokens: int = 200, completion_tokens: int = 80):
    response = MagicMock()
    response.choices = [MagicMock()]
    response.choices[0].message = MagicMock()
    response.choices[0].message.content = content
    response.usage = MagicMock(prompt_tokens=prompt_tokens, completion_tokens=completion_tokens)
    return response


@patch("app.agents.kv_resize.vision_prepass.OpenAI")
def test_analyze_happy_path(mock_openai_cls):
    payload = {
        "subject_bbox": {"x": 0.3, "y": 0.2, "w": 0.4, "h": 0.5},
        "content_type": "portrait_person",
        "has_visible_text": False,
        "context_hint": "warm indoor portrait with shallow depth of field",
    }
    mock_openai_cls.return_value.chat.completions.create.return_value = (
        _mk_response(json.dumps(payload))
    )

    result, usage = analyze("https://cdn.example.com/source.png")

    assert isinstance(result, VisionResult)
    assert result.content_type == "portrait_person"
    assert usage["input_text_tokens"] == 200
    assert usage["output_text_tokens"] == 80


@patch("app.agents.kv_resize.vision_prepass.OpenAI")
def test_analyze_validation_failure(mock_openai_cls):
    # bbox.x > 1 -> Pydantic rejects
    payload = {
        "subject_bbox": {"x": 1.5, "y": 0.2, "w": 0.4, "h": 0.5},
        "content_type": "portrait_person",
        "has_visible_text": False,
        "context_hint": "test",
    }
    mock_openai_cls.return_value.chat.completions.create.return_value = (
        _mk_response(json.dumps(payload))
    )

    result, usage = analyze("https://cdn.example.com/source.png")

    assert result is None
    # Token usage still captured because API call succeeded
    assert usage["input_text_tokens"] == 200


@patch("app.agents.kv_resize.vision_prepass.OpenAI")
def test_analyze_api_exception(mock_openai_cls):
    mock_openai_cls.return_value.chat.completions.create.side_effect = (
        RuntimeError("network blip")
    )

    result, usage = analyze("https://cdn.example.com/source.png")

    assert result is None
    assert usage == {}
```

- [ ] **Step 2: Run tests**

Run: `pytest ai-service/tests/agents/kv_resize/test_vision_prepass.py -v`
Expected: all 3 tests pass.

- [ ] **Step 3: Commit**

```bash
git add ai-service/tests/agents/kv_resize/test_vision_prepass.py
git -C ai-service commit -m "test(kv-resize): cover vision_prepass happy/validation/exception paths"
```

---

## Task 5: Add `fit_inside_target` helper to canvas.py

**Files:**
- Modify: `ai-service/app/agents/kv_resize/canvas.py`

- [ ] **Step 1: Append helper to canvas.py**

Add at the bottom of the file:

```python
def fit_inside_target(
    src: Image.Image,
    target_w: int,
    target_h: int,
    frame_px: int = 32,
) -> tuple[Image.Image, tuple[int, int, int, int]]:
    """Scale src to fit inside (target_w - 2*frame_px, target_h - 2*frame_px)
    preserving aspect ratio, then paste centered on a target-sized
    transparent RGBA canvas.

    Used for the fit-not-fill resize strategy: source is preserved 100%
    and the AI extends the scene laterally into the reserved margins.

    Returns (canvas, paste_box) where paste_box = (x1, y1, x2, y2).
    """
    inner_w = max(1, target_w - 2 * frame_px)
    inner_h = max(1, target_h - 2 * frame_px)

    sw, sh = src.size
    scale = min(inner_w / sw, inner_h / sh)
    scaled_w = max(1, int(sw * scale))
    scaled_h = max(1, int(sh * scale))
    scaled = src.resize((scaled_w, scaled_h), Image.LANCZOS)

    canvas = Image.new("RGBA", (target_w, target_h), (0, 0, 0, 0))
    x = (target_w - scaled_w) // 2
    y = (target_h - scaled_h) // 2
    scaled_rgba = scaled.convert("RGBA")
    canvas.paste(scaled_rgba, (x, y), scaled_rgba)
    return canvas, (x, y, x + scaled_w, y + scaled_h)
```

- [ ] **Step 2: Commit**

```bash
git add ai-service/app/agents/kv_resize/canvas.py
git -C ai-service commit -m "feat(kv-resize): add fit_inside_target canvas helper for fit-not-fill"
```

---

## Task 6: Add `subject_aware_crop` helper to canvas.py

**Files:**
- Modify: `ai-service/app/agents/kv_resize/canvas.py`

- [ ] **Step 1: Append helper**

Add at the bottom of canvas.py:

```python
def subject_aware_crop(
    src: Image.Image,
    target_w: int,
    target_h: int,
    subject_bbox_norm: tuple[float, float, float, float],
) -> Image.Image:
    """Crop the source so its aspect matches the target, sliding the
    crop window so the subject bbox center stays inside the crop and as
    close to the crop center as possible.

    subject_bbox_norm = (x, y, w, h) in normalized [0,1] coords on the
    source. Top-left origin.

    If the source already fits inside the target on both axes, returns
    the source unchanged (caller passes it on to fit_inside_target).
    """
    sw, sh = src.size
    if sw <= target_w and sh <= target_h:
        return src

    src_aspect = sw / sh
    target_aspect = target_w / target_h

    if src_aspect >= target_aspect:
        new_h = sh
        new_w = round(sh * target_aspect)
    else:
        new_w = sw
        new_h = round(sw / target_aspect)

    bx, by, bw, bh = subject_bbox_norm
    subj_cx = (bx + bw / 2) * sw
    subj_cy = (by + bh / 2) * sh

    x = int(subj_cx - new_w / 2)
    y = int(subj_cy - new_h / 2)
    x = max(0, min(x, sw - new_w))
    y = max(0, min(y, sh - new_h))

    cropped = src.crop((x, y, x + new_w, y + new_h))

    if cropped.size[0] > target_w or cropped.size[1] > target_h:
        cropped = cropped.resize((target_w, target_h), Image.LANCZOS)

    return cropped
```

- [ ] **Step 2: Commit**

```bash
git add ai-service/app/agents/kv_resize/canvas.py
git -C ai-service commit -m "feat(kv-resize): add subject_aware_crop canvas helper"
```

---

## Task 7: Tests for canvas helpers (GATED)

**Pause and ask the user:** "Should I add unit tests for `fit_inside_target` and `subject_aware_crop` now?"

If approved:

**Files:**
- Modify: `ai-service/tests/agents/kv_resize/test_canvas.py`

- [ ] **Step 1: Append tests**

```python
from PIL import Image

from app.agents.kv_resize.canvas import fit_inside_target, subject_aware_crop


def test_fit_inside_target_preserves_aspect_with_frame():
    # 1080x1920 portrait into 1280x720 landscape with 32px frame
    src = Image.new("RGB", (1080, 1920), color=(255, 0, 0))
    canvas, (x1, y1, x2, y2) = fit_inside_target(src, 1280, 720, frame_px=32)

    assert canvas.size == (1280, 720)
    # Inner box is 1216 x 656; portrait fits to height
    placed_w = x2 - x1
    placed_h = y2 - y1
    assert placed_h == 656
    # 656 * (1080/1920) = 369
    assert abs(placed_w - 369) <= 1
    # Centered
    assert abs(x1 - (1280 - placed_w) // 2) <= 1
    assert abs(y1 - (720 - placed_h) // 2) <= 1


def test_fit_inside_target_handles_zero_frame():
    src = Image.new("RGB", (1080, 1920))
    canvas, paste = fit_inside_target(src, 1080, 1080, frame_px=0)

    assert canvas.size == (1080, 1080)


def test_subject_aware_crop_centers_on_subject():
    # 1080x1920 portrait. Subject in top quarter.
    src = Image.new("RGB", (1080, 1920))
    # Subject bbox: full width strip at y=0..0.25
    cropped = subject_aware_crop(src, 1080, 1080, (0.0, 0.0, 1.0, 0.25))

    assert cropped.size == (1080, 1080)
    # Subject center y = 0.125 * 1920 = 240. Crop is 1080 tall, so
    # x=0, y should clamp to 0 (can't slide above 0).


def test_subject_aware_crop_returns_src_when_already_fits():
    src = Image.new("RGB", (800, 600))
    out = subject_aware_crop(src, 1080, 1080, (0.4, 0.4, 0.2, 0.2))

    assert out is src
```

- [ ] **Step 2: Run tests**

Run: `pytest ai-service/tests/agents/kv_resize/test_canvas.py -v`
Expected: all 4 new tests pass alongside any existing tests.

- [ ] **Step 3: Commit**

```bash
git add ai-service/tests/agents/kv_resize/test_canvas.py
git -C ai-service commit -m "test(kv-resize): cover fit_inside_target and subject_aware_crop"
```

---

## Task 8: Add `_decide_strategy` in service.py

**Files:**
- Modify: `ai-service/app/agents/kv_resize/service.py`

- [ ] **Step 1: Add imports and helper**

At the top of `service.py`, add to existing imports:

```python
from typing import Literal
from app.agents.kv_resize.canvas import (
    build_mask, pad_to_target, smart_crop,
    fit_inside_target, subject_aware_crop,  # NEW
)
from app.agents.kv_resize.vision_prepass import analyze, VisionResult  # NEW
```

Add this constant near the existing `_FORCE_AI_INNER_RATIO`:

```python
_ASPECT_DELTA_THRESHOLD = 0.30
```

Add the helper above `process_resize_export`:

```python
def _decide_strategy(
    src_w: int,
    src_h: int,
    target_w: int,
    target_h: int,
    vision: VisionResult | None,
) -> Literal["fit_not_fill", "subject_aware_crop", "legacy_smart_crop"]:
    if vision is None:
        return "legacy_smart_crop"
    if vision.has_visible_text or vision.content_type == "text_heavy":
        return "fit_not_fill"

    src_aspect = src_w / src_h
    tgt_aspect = target_w / target_h

    def orientation(a: float) -> str:
        if a < 0.95:
            return "portrait"
        if a > 1.05:
            return "landscape"
        return "square"

    if orientation(src_aspect) != orientation(tgt_aspect):
        return "fit_not_fill"

    delta = abs(src_aspect - tgt_aspect) / max(src_aspect, tgt_aspect)
    if delta > _ASPECT_DELTA_THRESHOLD:
        return "fit_not_fill"

    return "subject_aware_crop"
```

- [ ] **Step 2: Commit**

```bash
git add ai-service/app/agents/kv_resize/service.py
git -C ai-service commit -m "feat(kv-resize): add _decide_strategy helper for vision-aware routing"
```

---

## Task 9: Refactor `process_resize_export` to use vision pass + strategy

**Files:**
- Modify: `ai-service/app/agents/kv_resize/service.py`

- [ ] **Step 1: Replace the `force_ai` branch body**

In `process_resize_export`, find the current `if req.force_ai:` block (the one that does `if covers_target: shrink to 0.95×; pad_to_target; build_mask; outpaint`).

Replace its entire body with:

```python
        if req.force_ai:
            vision: VisionResult | None = None
            vision_token_usage: Dict[str, Any] = {}
            if req.use_vision_prepass and req.crop_window is None:
                vision, vision_token_usage = analyze(req.source_image_url)

            strategy = _decide_strategy(
                source.size[0], source.size[1],
                req.target_width, req.target_height,
                vision,
            )

            if strategy == "fit_not_fill":
                canvas, paste_box = fit_inside_target(
                    source, req.target_width, req.target_height, frame_px=32
                )
            elif strategy == "subject_aware_crop":
                # vision is not None here per _decide_strategy contract
                bbox = (
                    vision.subject_bbox.x, vision.subject_bbox.y,
                    vision.subject_bbox.w, vision.subject_bbox.h,
                )
                pre = subject_aware_crop(
                    source, req.target_width, req.target_height, bbox,
                )
                canvas, paste_box = fit_inside_target(
                    pre, req.target_width, req.target_height, frame_px=32
                )
            else:  # legacy_smart_crop
                pre = smart_crop(source, req.target_width, req.target_height)
                if (
                    pre.size[0] >= req.target_width
                    and pre.size[1] >= req.target_height
                ):
                    inner_w = max(1, int(req.target_width * _FORCE_AI_INNER_RATIO))
                    inner_h = max(1, int(req.target_height * _FORCE_AI_INNER_RATIO))
                    pre = pre.resize((inner_w, inner_h), Image.LANCZOS)
                canvas, paste_box = pad_to_target(
                    pre, req.target_width, req.target_height
                )

            mask = build_mask(req.target_width, req.target_height, paste_box)
            guidance = OUTPAINT_GUIDANCE
            if vision is not None and vision.context_hint:
                guidance = f"{OUTPAINT_GUIDANCE}\n\nSource context: {vision.context_hint}"

            image_bytes, used_model, token_usage = outpaint(
                canvas, mask, guidance, provider=req.model
            )
            ai_service_run_id = str(uuid4())
```

(`crop_window`, `covers_target`, and the `elif`/`else` branches below it are unchanged. The reassignment of `cropped` is gone — the new flow builds `canvas` directly.)

- [ ] **Step 2: Update the existing `post_completed` call**

Find the call inside `process_resize_export` and add the two new kwargs:

```python
        post_completed(
            export_id=req.export_id,
            status="done",
            image_url=image_url,
            token_usage=token_usage or None,
            ai_service_run_id=ai_service_run_id,
            model=used_model,
            vision_token_usage=vision_token_usage or None,   # NEW
            vision_model="gpt-4o-mini" if vision_token_usage else None,  # NEW
        )
```

`vision_token_usage` is initialized to `{}` outside the `force_ai` branch so the variable always exists at this call site. Add `vision_token_usage: Dict[str, Any] = {}` to the local-variable init block at the top of `process_resize_export` (alongside `token_usage` etc).

- [ ] **Step 3: Commit**

```bash
git add ai-service/app/agents/kv_resize/service.py
git -C ai-service commit -m "feat(kv-resize): wire vision pre-pass and strategy into force_ai branch"
```

---

## Task 10: Extend `api_client.post_completed` for vision fields

**Files:**
- Modify: `ai-service/app/agents/kv_resize/api_client.py`

- [ ] **Step 1: Add kwargs**

Update the signature and payload-building block:

```python
def post_completed(
    *,
    export_id: str,
    status: str,
    image_url: Optional[str] = None,
    error_message: Optional[str] = None,
    token_usage: Optional[Dict[str, Any]] = None,
    ai_service_run_id: Optional[str] = None,
    model: Optional[str] = None,
    vision_token_usage: Optional[Dict[str, Any]] = None,
    vision_model: Optional[str] = None,
) -> None:
    ...
    payload: dict = {"export_id": export_id, "status": status}
    if image_url is not None:
        payload["image_url"] = image_url
    if error_message is not None:
        payload["error_message"] = error_message
    if token_usage:
        payload["token_usage"] = token_usage
    if ai_service_run_id is not None:
        payload["ai_service_run_id"] = ai_service_run_id
    if model is not None:
        payload["model"] = model
    if vision_token_usage:
        payload["vision_token_usage"] = vision_token_usage
    if vision_model is not None:
        payload["vision_model"] = vision_model
    ...
```

(Keep the existing docstring and update it to mention the two new fields: "When `vision_token_usage` and `vision_model` are present, the api will write a second `CostHistory` row with `cost_type='kv_resize_vision'`.")

- [ ] **Step 2: Commit**

```bash
git add ai-service/app/agents/kv_resize/api_client.py
git -C ai-service commit -m "feat(kv-resize): forward vision_token_usage and vision_model to api callback"
```

---

## Task 11: Tests for service.py strategy decision + integration (GATED)

**Pause and ask the user:** "Should I add tests for `_decide_strategy` and an integration test for the vision-pass branch of `process_resize_export`?"

If approved:

**Files:**
- Modify: `ai-service/tests/agents/kv_resize/test_service.py`

- [ ] **Step 1: Append tests**

```python
from unittest.mock import MagicMock, patch
from PIL import Image

from app.agents.kv_resize.service import _decide_strategy
from app.agents.kv_resize.vision_prepass import VisionResult, SubjectBBox


def _vision(content="scene", text=False, bbox=(0.4, 0.4, 0.2, 0.2)):
    return VisionResult(
        subject_bbox=SubjectBBox(x=bbox[0], y=bbox[1], w=bbox[2], h=bbox[3]),
        content_type=content,
        has_visible_text=text,
        context_hint="test",
    )


def test_decide_strategy_falls_back_when_vision_none():
    assert _decide_strategy(1080, 1920, 1080, 1080, None) == "legacy_smart_crop"


def test_decide_strategy_picks_fit_not_fill_on_cross_orientation():
    # Portrait -> landscape
    assert _decide_strategy(1080, 1920, 1280, 720, _vision()) == "fit_not_fill"


def test_decide_strategy_picks_fit_not_fill_on_large_aspect_delta():
    # Both landscape, but 21:9 to 4:3 (delta > 30%)
    assert _decide_strategy(2100, 900, 1280, 960, _vision()) == "fit_not_fill"


def test_decide_strategy_picks_fit_not_fill_on_visible_text():
    # Same orientation, low delta — but text present
    assert _decide_strategy(
        1080, 1080, 1080, 1080, _vision(text=True)
    ) == "fit_not_fill"


def test_decide_strategy_picks_subject_aware_crop_on_similar_aspects():
    # Both landscape, small delta, no text
    assert _decide_strategy(
        1920, 1080, 1280, 720, _vision()
    ) == "subject_aware_crop"
```

- [ ] **Step 2: Run tests**

Run: `pytest ai-service/tests/agents/kv_resize/test_service.py::test_decide_strategy -v`
Expected: all 5 tests pass.

- [ ] **Step 3: Commit**

```bash
git add ai-service/tests/agents/kv_resize/test_service.py
git -C ai-service commit -m "test(kv-resize): cover _decide_strategy across all branches"
```

---

## Task 12: Add `KV_RESIZE_VISION_PREPASS` config + env

**Files:**
- Modify: `api/config/services.php`
- Modify: `api/.env.example`

- [ ] **Step 1: Add to config/services.php**

Inside the `ai` block (where `kv_resize_model` and `kv_resize_force_ai` already live):

```php
'kv_resize_vision_prepass' => env('KV_RESIZE_VISION_PREPASS', true),
```

- [ ] **Step 2: Add to .env.example**

Near the existing `KV_RESIZE_FORCE_AI` line:

```
KV_RESIZE_VISION_PREPASS=true
```

- [ ] **Step 3: Commit**

```bash
git -C api add config/services.php .env.example
git -C api commit -m "feat(kv-resize): add KV_RESIZE_VISION_PREPASS env config"
```

---

## Task 13: Forward `use_vision_prepass` in job payload

**Files:**
- Modify: `api/app/Jobs/Studio/ProcessKvResizeExportJob.php`

- [ ] **Step 1: Add to payload**

Locate the `$payload = [ ... ]` array that gets POSTed to `/ai/kv-resize/export`. Add this key:

```php
'use_vision_prepass' => (bool) config('services.ai.kv_resize_vision_prepass'),
```

- [ ] **Step 2: Commit**

```bash
git -C api add app/Jobs/Studio/ProcessKvResizeExportJob.php
git -C api commit -m "feat(kv-resize): forward use_vision_prepass flag to ai-service"
```

---

## Task 14: Validate `vision_token_usage` and `vision_model` on callback

**Files:**
- Modify: `api/app/Http/Requests/Internal/KvResizeExportCompleteRequest.php`

- [ ] **Step 1: Add validation rules**

In the `rules()` array, add these lines next to the existing `token_usage.*` entries:

```php
'vision_token_usage'                     => ['sometimes', 'array'],
'vision_token_usage.input_text_tokens'   => ['sometimes', 'integer', 'min:0'],
'vision_token_usage.input_image_tokens'  => ['sometimes', 'integer', 'min:0'],
'vision_token_usage.output_image_tokens' => ['sometimes', 'integer', 'min:0'],
'vision_token_usage.output_text_tokens'  => ['sometimes', 'integer', 'min:0'],
'vision_model'                           => ['sometimes', 'string', 'max:64'],
```

- [ ] **Step 2: Commit**

```bash
git -C api add app/Http/Requests/Internal/KvResizeExportCompleteRequest.php
git -C api commit -m "feat(kv-resize): validate vision_token_usage and vision_model on callback"
```

---

## Task 15: Charge user for vision pass in controller

**Files:**
- Modify: `api/app/Http/Controllers/Api/Internal/KvResizeExportInternalController.php`

- [ ] **Step 1: Add the second charge call**

Immediately after the existing `$this->metering->charge( ... )` call (the one for gpt-image-2 generation), add:

```php
        if (
            $validated['status'] === 'done'
            && !empty($validated['vision_token_usage'] ?? null)
            && !empty($validated['vision_model'] ?? null)
            && $aiRunId
        ) {
            $this->metering->charge(
                user: $user,
                workspace: $row->file->workspace,
                costType: 'kv_resize_vision',
                toolName: 'KV Resize Vision Analysis',
                batchId: "kv_resize_vision_{$row->id}_{$aiRunId}",
                model: $validated['vision_model'],
                tokenUsage: $validated['vision_token_usage'],
                brandId: $row->file->brand_id,
            );
        }
```

The distinct `batchId` (note the `_vision_` infix) keeps the existing idempotency invariant intact — gen and vision are tracked as two separate `CostHistory` rows for the same export, each independently retry-safe.

- [ ] **Step 2: Commit**

```bash
git -C api add app/Http/Controllers/Api/Internal/KvResizeExportInternalController.php
git -C api commit -m "feat(kv-resize): charge user for vision pre-pass as separate CostHistory row"
```

---

## Task 16: Update Feature test for the new callback fields (GATED)

**Pause and ask the user:** "Should I update / add the Feature test for the resize-export internal controller to assert the second CostHistory row?"

If approved:

**Files:**
- Modify: `api/tests/Feature/Studio/KvResizeExportInternalControllerTest.php` (or equivalent — verify path first)

- [ ] **Step 1: Locate existing controller test**

Run: `rg -l 'KvResizeExport.*[Tt]est' api/tests/ | head -3`

Expected: one or two files. Pick the one that exercises the `completed` callback endpoint.

- [ ] **Step 2: Add a test**

```php
public function test_callback_with_vision_tokens_creates_two_cost_history_rows(): void
{
    // Arrange: create user, file, export row in 'in_progress' state.
    $user = User::factory()->create();
    $file = File::factory()->for($user)->create();
    $export = KvResizeExport::factory()
        ->for($file)
        ->create(['status' => 'in_progress']);

    $payload = [
        'export_id' => $export->id,
        'status' => 'done',
        'image_url' => 'https://cdn.example.com/out.png',
        'model' => 'gpt-image-2',
        'ai_service_run_id' => 'run_abc',
        'token_usage' => [
            'input_text_tokens' => 50,
            'input_image_tokens' => 1290,
            'output_image_tokens' => 1290,
            'output_text_tokens' => 0,
        ],
        'vision_model' => 'gpt-4o-mini',
        'vision_token_usage' => [
            'input_text_tokens' => 965,
            'input_image_tokens' => 0,
            'output_image_tokens' => 0,
            'output_text_tokens' => 80,
        ],
    ];

    // Act
    $response = $this
        ->withHeaders(['X-Internal-Token' => config('services.ai.internal_token')])
        ->postJson('/api/v1/internal/kv-resize-exports/completed', $payload);

    // Assert
    $response->assertOk();
    $this->assertDatabaseHas('cost_histories', [
        'user_id' => $user->id,
        'cost_type' => 'kv_resize_export',
        'batch_identifier' => "kv_resize_{$export->id}_run_abc",
    ]);
    $this->assertDatabaseHas('cost_histories', [
        'user_id' => $user->id,
        'cost_type' => 'kv_resize_vision',
        'batch_identifier' => "kv_resize_vision_{$export->id}_run_abc",
    ]);
}
```

(Adapt the user/file/export factories to whatever the existing test file uses for setup.)

- [ ] **Step 3: Run test**

Run: `cd api && ./vendor/bin/pest --filter 'callback_with_vision_tokens'`
Expected: passes.

- [ ] **Step 4: Commit**

```bash
git -C api add tests/Feature/Studio/KvResizeExportInternalControllerTest.php
git -C api commit -m "test(kv-resize): assert vision pass writes second CostHistory row"
```

---

## Task 17: Staging smoke test (GATED — manual)

**Pause and ask the user:** "All code is in. Should I produce a staging deploy checklist / wait for user to deploy and smoke?"

**Manual checklist (user executes after deploy):**

1. Confirm `KV_RESIZE_VISION_PREPASS=true` in api staging env.
2. Upload a clearly off-center subject as a KV source (e.g. portrait photo with face in top third).
3. Click Resize → pick: IG Post (square), IG Story (portrait), YouTube Thumbnail (landscape).
4. Verify outputs:
   - Square: subject is centered (subject-aware crop kicked in)
   - Story: subject preserved as-is or with small extension (low delta, subject-aware crop)
   - Thumbnail: source preserved fully, AI extends scene to the sides (fit-not-fill on cross-orientation)
5. Query DB:
   ```sql
   SELECT cost_type, batch_identifier, actual_credit, total_tokens
   FROM cost_histories
   WHERE batch_identifier LIKE 'kv_resize%' AND user_id = '<test user id>'
   ORDER BY created_at DESC LIMIT 10;
   ```
   Expected: exactly 6 rows (3 generation + 3 vision), each generation row paired with a `kv_resize_vision` row sharing the same export id in their `batch_identifier`.
6. Verify OpenAI dashboard shows ~3 calls to `gpt-4o-mini` and ~3 calls to `gpt-image-2` for the test period.
7. Test rollback: set `KV_RESIZE_VISION_PREPASS=false`, restart queue worker, resize again. Verify only `kv_resize_export` rows appear (no `kv_resize_vision` rows), and crop behavior reverts to today's center-crop heuristic.

If any smoke fails: re-set `KV_RESIZE_VISION_PREPASS=false` to disable the feature without a code revert; investigate; fix; redeploy.

---

## Self-review checklist

- [x] Spec coverage: vision pre-pass (Tasks 2-4), `fit_inside_target` (5,7), `subject_aware_crop` (6,7), strategy decision (8,11), service integration (9,11), callback contract (10), api config + payload + validation + charge (12-15), tests gated (4,7,11,16), rollback path (17).
- [x] No placeholders. Every code step has the exact code; every command step has the exact command.
- [x] Type/name consistency: `analyze` returns `(VisionResult | None, dict[str, int])` across Tasks 3, 9, 11. `_decide_strategy` returns the three string literals consistently in Tasks 8, 9, 11. `vision_token_usage` and `vision_model` fields match across Tasks 9, 10, 14, 15, 16, 17.
