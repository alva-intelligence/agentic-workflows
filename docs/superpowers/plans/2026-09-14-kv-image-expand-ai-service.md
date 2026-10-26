# KV Expand Image — ai-service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `POST /ai/kv-image-expand/run` — download an overlay image, paste it at a user-chosen position on a larger transparent canvas, outpaint the empty margin with gpt-image-2, upload the PNG to S3, and call the api back with the URL + token usage.

**Architecture:** A new `app/agents/kv_image_expand/` package cloned file-for-file from `kv_background_removal` (schema / router / api_client / service). The only new logic is placement: the canvas + mask are built from the request's `placement` instead of centred, then fed to the existing `app.tools.outpaint_image.outpaint` and `app.agents.kv_resize.canvas.build_mask`. Fire-and-forget 202 + internal callback, never raises.

**Tech Stack:** FastAPI, pydantic v2, Pillow, existing `outpaint()` (OpenAI gpt-image-2 `/v1/images/edits`), pytest.

**Spec:** `docs/superpowers/specs/2026-09-14-kv-image-expand-design.md` (workspace root) — §3 placement contract, §6 ai-service, §7 error handling, §8 testing.

## Global Constraints

- All placement numbers are **natural pixels of the source image**.
- Invariants: `image_x ≥ 0`, `image_y ≥ 0`, `image_x + source_w ≤ canvas_w`, `image_y + source_h ≤ canvas_h`, `canvas_w ≤ 4096`, `canvas_h ≤ 4096`. Violations → 422 at the schema.
- Mask convention (from `kv_resize/canvas.py::build_mask`): white (255) = paint, black (0) = preserve.
- Prompt is the existing `OUTPAINT_GUIDANCE` from `app/agents/kv_resize/prompts/outpaint.py`; no free-text prompt in v1.
- Output S3 key: `{settings.API_ENV}/kv-image-expands/{image_expand_id}.png`.
- Callback URL: `{API_INTERNAL_URL}/api/v1/internal/kv-image-expands/completed`, payload keys: `image_expand_id, status, image_url, width, height, model_version, token_usage, error_message`.
- `process_image_expand` **never raises** — every failure becomes a `failed` callback.
- `save_bytes_to_file` returns `None` on upload failure despite its `-> str` annotation (see memory `lesson_s3_helper_returns_none_not_raises`) — treat a falsy return as a failure.
- Tests: `cd ai-service && source .venv/bin/activate && python -m pytest <path> -q`. 16 pre-existing failures exist in `tests/agents/{chat_agent,kv_generator}`; only run the paths named here.
- Work on branch `feature/daffa/vc-kv-image-expand` cut from `development`. Commit per task; do not push.

---

### Task 0: Branch

**Files:** none

- [ ] **Step 1: Create the branch**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/ai-service
git checkout development && git pull --rebase origin development
git checkout -b feature/daffa/vc-kv-image-expand
```

---

### Task 1: Request / response schemas

**Files:**
- Create: `ai-service/app/agents/kv_image_expand/__init__.py` (empty)
- Create: `ai-service/app/agents/kv_image_expand/request_schema.py`
- Create: `ai-service/app/agents/kv_image_expand/response_schema.py`
- Test: `ai-service/tests/agents/kv_image_expand/__init__.py` (empty)
- Test: `ai-service/tests/agents/kv_image_expand/test_request_schema.py`

**Interfaces:**
- Produces: `ImageExpandPlacement(canvas_w:int, canvas_h:int, image_x:int, image_y:int)`, `ImageExpandRequest(image_expand_id:str, source_image_url:str, source_w:int, source_h:int, placement:ImageExpandPlacement, user_id, user_email, workspace_id, workspace_name, brand_id, brand_name: str|None)`, `ImageExpandAccepted(image_expand_id:str, status:str="accepted")`, `MAX_CANVAS_EDGE = 4096`.

- [ ] **Step 1: Write the failing tests**

```python
# ai-service/tests/agents/kv_image_expand/test_request_schema.py
"""Placement contract for KV Expand Image (spec §3).

The schema is the ai-service's only defence against a canvas that does
not contain the source: the api validates the same invariant, but a
direct caller (or a drifted api) must still be refused here."""
import pytest
from pydantic import ValidationError

from app.agents.kv_image_expand.request_schema import (
    MAX_CANVAS_EDGE,
    ImageExpandRequest,
)


def _req(**overrides):
    base = dict(
        image_expand_id="01EXPAND",
        source_image_url="https://s3.test/src.png",
        source_w=400,
        source_h=300,
        placement=dict(canvas_w=640, canvas_h=360, image_x=120, image_y=30),
    )
    base.update(overrides)
    return base


def test_accepts_a_contained_placement():
    req = ImageExpandRequest(**_req())
    assert req.placement.canvas_w == 640
    assert req.placement.image_x == 120


def test_cap_is_4096():
    assert MAX_CANVAS_EDGE == 4096


@pytest.mark.parametrize(
    "placement",
    [
        dict(canvas_w=4097, canvas_h=360, image_x=0, image_y=0),
        dict(canvas_w=640, canvas_h=4097, image_x=0, image_y=0),
    ],
)
def test_rejects_canvas_over_cap(placement):
    with pytest.raises(ValidationError):
        ImageExpandRequest(**_req(placement=placement))


@pytest.mark.parametrize(
    "placement",
    [
        # image_x + source_w (400) > canvas_w
        dict(canvas_w=640, canvas_h=360, image_x=241, image_y=0),
        # image_y + source_h (300) > canvas_h
        dict(canvas_w=640, canvas_h=360, image_x=0, image_y=61),
        # negative offsets
        dict(canvas_w=640, canvas_h=360, image_x=-1, image_y=0),
        dict(canvas_w=640, canvas_h=360, image_x=0, image_y=-1),
        # canvas smaller than the source on one axis
        dict(canvas_w=399, canvas_h=360, image_x=0, image_y=0),
    ],
)
def test_rejects_placement_that_does_not_contain_source(placement):
    with pytest.raises(ValidationError):
        ImageExpandRequest(**_req(placement=placement))


def test_source_dims_must_be_positive_and_within_cap():
    with pytest.raises(ValidationError):
        ImageExpandRequest(**_req(source_w=0))
    with pytest.raises(ValidationError):
        ImageExpandRequest(
            **_req(
                source_w=4097,
                placement=dict(canvas_w=4097, canvas_h=300, image_x=0, image_y=0),
            )
        )


def test_context_fields_are_optional():
    req = ImageExpandRequest(**_req())
    assert req.user_id is None
    assert req.brand_name is None
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ai-service && source .venv/bin/activate && python -m pytest tests/agents/kv_image_expand/test_request_schema.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'app.agents.kv_image_expand'`

- [ ] **Step 3: Write the schemas**

```python
# ai-service/app/agents/kv_image_expand/__init__.py
```
(empty file)

```python
# ai-service/app/agents/kv_image_expand/request_schema.py
"""Wire contract for KV Expand Image (spec §3).

Every number is in natural pixels of the SOURCE image. The api validates
the same invariants; they are repeated here because this service is the
one that actually spends money on the call, so it must not trust a
drifted or bypassed caller."""
from pydantic import BaseModel, Field, model_validator

# gpt-image-2 output cap we are willing to bill for. Mirrors the api's
# CreateKvImageExpandRequest rule and web's clampPlacement.
MAX_CANVAS_EDGE = 4096


class ImageExpandPlacement(BaseModel):
    canvas_w: int = Field(ge=1, le=MAX_CANVAS_EDGE)
    canvas_h: int = Field(ge=1, le=MAX_CANVAS_EDGE)
    image_x: int = Field(ge=0)
    image_y: int = Field(ge=0)


class ImageExpandRequest(BaseModel):
    image_expand_id: str
    source_image_url: str
    source_w: int = Field(ge=1, le=MAX_CANVAS_EDGE)
    source_h: int = Field(ge=1, le=MAX_CANVAS_EDGE)
    placement: ImageExpandPlacement

    # Identity context, forwarded for logging / PostHog like sibling KV jobs.
    user_id: str | None = None
    user_email: str | None = None
    workspace_id: str | None = None
    workspace_name: str | None = None
    brand_id: str | None = None
    brand_name: str | None = None

    @model_validator(mode="after")
    def _canvas_contains_source(self) -> "ImageExpandRequest":
        p = self.placement
        if p.image_x + self.source_w > p.canvas_w:
            raise ValueError(
                "placement: image_x + source_w must be <= canvas_w "
                f"({p.image_x} + {self.source_w} > {p.canvas_w})"
            )
        if p.image_y + self.source_h > p.canvas_h:
            raise ValueError(
                "placement: image_y + source_h must be <= canvas_h "
                f"({p.image_y} + {self.source_h} > {p.canvas_h})"
            )
        return self
```

```python
# ai-service/app/agents/kv_image_expand/response_schema.py
from pydantic import BaseModel


class ImageExpandAccepted(BaseModel):
    image_expand_id: str
    status: str = "accepted"
```

```python
# ai-service/tests/agents/kv_image_expand/__init__.py
```
(empty file)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ai-service && source .venv/bin/activate && python -m pytest tests/agents/kv_image_expand/test_request_schema.py -q`
Expected: all PASS

- [ ] **Step 5: Mutation check** — temporarily change `>` to `>=` in `_canvas_contains_source`'s first branch; `test_accepts_a_contained_placement` must still pass but change `image_x=120` to `image_x=240` in `_req` and confirm it now FAILS with the mutation and PASSES without. Revert the mutation.

- [ ] **Step 6: Commit**

```bash
git add app/agents/kv_image_expand tests/agents/kv_image_expand
git commit -m "feat(ai): kv image expand request/response schemas

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Callback client

**Files:**
- Create: `ai-service/app/agents/kv_image_expand/api_client.py`
- Test: `ai-service/tests/agents/kv_image_expand/test_api_client.py`

**Interfaces:**
- Consumes: `app.utils.internal_callback.post_internal_callback(url, payload, label=...)`, `settings.API_INTERNAL_URL`.
- Produces: `post_completed(*, image_expand_id, status, image_url=None, width=None, height=None, model_version=None, token_usage=None, error_message=None) -> None`.

- [ ] **Step 1: Write the failing test**

```python
# ai-service/tests/agents/kv_image_expand/test_api_client.py
from unittest.mock import patch

from app.agents.kv_image_expand.api_client import post_completed


@patch("app.agents.kv_image_expand.api_client.post_internal_callback")
@patch("app.agents.kv_image_expand.api_client.settings")
def test_done_payload_carries_token_usage_and_dims(mock_settings, mock_post):
    mock_settings.API_INTERNAL_URL = "http://api.test/"

    usage = {
        "type": "Image Generation",
        "model": "gpt-image-2",
        "input_text_tokens": 10,
        "input_image_tokens": 200,
        "output_image_tokens": 1290,
    }
    post_completed(
        image_expand_id="01EXPAND",
        status="done",
        image_url="https://cdn.test/out.png",
        width=640,
        height=360,
        model_version="gpt-image-2",
        token_usage=usage,
    )

    url, payload = mock_post.call_args.args[:2]
    assert url == "http://api.test/api/v1/internal/kv-image-expands/completed"
    assert payload == {
        "image_expand_id": "01EXPAND",
        "status": "done",
        "image_url": "https://cdn.test/out.png",
        "width": 640,
        "height": 360,
        "model_version": "gpt-image-2",
        "token_usage": usage,
    }
    assert mock_post.call_args.kwargs["label"] == "kv_image_expand"


@patch("app.agents.kv_image_expand.api_client.post_internal_callback")
@patch("app.agents.kv_image_expand.api_client.settings")
def test_failed_payload_omits_result_keys(mock_settings, mock_post):
    mock_settings.API_INTERNAL_URL = "http://api.test"

    post_completed(image_expand_id="01EXPAND", status="failed", error_message="boom")

    _, payload = mock_post.call_args.args[:2]
    assert payload == {
        "image_expand_id": "01EXPAND",
        "status": "failed",
        "error_message": "boom",
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ai-service && source .venv/bin/activate && python -m pytest tests/agents/kv_image_expand/test_api_client.py -q`
Expected: FAIL with `ImportError: cannot import name 'post_completed'` (or module not found)

- [ ] **Step 3: Write the client**

```python
# ai-service/app/agents/kv_image_expand/api_client.py
from typing import Any, Dict

from app.utils.config import settings
from app.utils.internal_callback import post_internal_callback


def post_completed(
    *,
    image_expand_id: str,
    status: str,
    image_url: str | None = None,
    width: int | None = None,
    height: int | None = None,
    model_version: str | None = None,
    token_usage: Dict[str, Any] | None = None,
    error_message: str | None = None,
) -> None:
    """Post final expand status back to the API.

    Mirrors `app.agents.kv_background_removal.api_client.post_completed`,
    plus ``token_usage`` — the api meters this feature from gpt-image-2's
    real usage (KvCreditMeteringService::charge), not from megapixels.
    """
    url = (
        f"{settings.API_INTERNAL_URL.rstrip('/')}"
        f"/api/v1/internal/kv-image-expands/completed"
    )
    payload: dict = {"image_expand_id": image_expand_id, "status": status}
    if image_url is not None:
        payload["image_url"] = image_url
    if width is not None:
        payload["width"] = width
    if height is not None:
        payload["height"] = height
    if model_version is not None:
        payload["model_version"] = model_version
    if token_usage is not None:
        payload["token_usage"] = token_usage
    if error_message is not None:
        payload["error_message"] = error_message

    post_internal_callback(url, payload, label="kv_image_expand")
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd ai-service && source .venv/bin/activate && python -m pytest tests/agents/kv_image_expand/test_api_client.py -q`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/agents/kv_image_expand/api_client.py tests/agents/kv_image_expand/test_api_client.py
git commit -m "feat(ai): kv image expand completion callback client

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Canvas + mask builder (pure)

**Files:**
- Create: `ai-service/app/agents/kv_image_expand/canvas.py`
- Test: `ai-service/tests/agents/kv_image_expand/test_canvas.py`

**Interfaces:**
- Consumes: `app.agents.kv_resize.canvas.build_mask(target_w, target_h, paste_box) -> Image (L)`.
- Produces: `build_expand_canvas(src: Image.Image, placement: ImageExpandPlacement) -> tuple[Image.Image, Image.Image]` returning `(canvas RGBA canvas_w×canvas_h, mask L)`.

- [ ] **Step 1: Write the failing test**

```python
# ai-service/tests/agents/kv_image_expand/test_canvas.py
from PIL import Image

from app.agents.kv_image_expand.canvas import build_expand_canvas
from app.agents.kv_image_expand.request_schema import ImageExpandPlacement


def test_canvas_is_target_size_with_source_pasted_at_offset():
    src = Image.new("RGB", (40, 30), (255, 0, 0))
    placement = ImageExpandPlacement(canvas_w=100, canvas_h=60, image_x=10, image_y=20)

    canvas, mask = build_expand_canvas(src, placement)

    assert canvas.size == (100, 60)
    assert canvas.mode == "RGBA"
    # Inside the paste box: opaque source pixel.
    assert canvas.getpixel((10, 20)) == (255, 0, 0, 255)
    assert canvas.getpixel((49, 49)) == (255, 0, 0, 255)
    # Just outside the paste box on each side: transparent.
    assert canvas.getpixel((9, 20))[3] == 0
    assert canvas.getpixel((50, 20))[3] == 0
    assert canvas.getpixel((10, 19))[3] == 0
    assert canvas.getpixel((10, 50))[3] == 0


def test_mask_preserves_exactly_the_paste_box():
    src = Image.new("RGB", (40, 30), (0, 255, 0))
    placement = ImageExpandPlacement(canvas_w=100, canvas_h=60, image_x=10, image_y=20)

    _, mask = build_expand_canvas(src, placement)

    assert mask.size == (100, 60)
    assert mask.mode == "L"
    # black (0) = preserve inside the box …
    assert mask.getpixel((10, 20)) == 0
    assert mask.getpixel((49, 49)) == 0
    # … white (255) = paint everywhere else, including the 1-px ring around it.
    assert mask.getpixel((9, 20)) == 255
    assert mask.getpixel((50, 20)) == 255
    assert mask.getpixel((10, 19)) == 255
    assert mask.getpixel((10, 50)) == 255
    assert mask.getpixel((0, 0)) == 255
    assert mask.getpixel((99, 59)) == 255


def test_rgba_source_alpha_is_kept():
    src = Image.new("RGBA", (4, 4), (0, 0, 255, 128))
    placement = ImageExpandPlacement(canvas_w=8, canvas_h=8, image_x=2, image_y=2)

    canvas, _ = build_expand_canvas(src, placement)

    assert canvas.getpixel((2, 2)) == (0, 0, 255, 128)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ai-service && source .venv/bin/activate && python -m pytest tests/agents/kv_image_expand/test_canvas.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'app.agents.kv_image_expand.canvas'`

- [ ] **Step 3: Write the builder**

```python
# ai-service/app/agents/kv_image_expand/canvas.py
"""Canvas + mask for one expand run.

The only thing that differs from kv_resize's ``pad_to_target`` is that the
paste position comes from the user (``placement``) instead of being
centred. The mask reuses kv_resize's convention so the same ``outpaint``
call consumes it: white = paint, black = preserve."""
from PIL import Image

from app.agents.kv_image_expand.request_schema import ImageExpandPlacement
from app.agents.kv_resize.canvas import build_mask


def build_expand_canvas(
    src: Image.Image, placement: ImageExpandPlacement
) -> tuple[Image.Image, Image.Image]:
    """Return ``(canvas, mask)``: a transparent RGBA canvas of
    ``canvas_w × canvas_h`` with ``src`` pasted at ``(image_x, image_y)``,
    and the L-mode outpaint mask preserving exactly that paste box."""
    src_rgba = src if src.mode == "RGBA" else src.convert("RGBA")
    sw, sh = src_rgba.size
    canvas = Image.new(
        "RGBA", (placement.canvas_w, placement.canvas_h), (0, 0, 0, 0)
    )
    # alpha_composite, not paste(mask=): paste blends the source's alpha with
    # the transparent destination (alpha 128 → ~64), alpha_composite copies it.
    canvas.alpha_composite(src_rgba, (placement.image_x, placement.image_y))
    paste_box = (
        placement.image_x,
        placement.image_y,
        placement.image_x + sw,
        placement.image_y + sh,
    )
    mask = build_mask(placement.canvas_w, placement.canvas_h, paste_box)
    return canvas, mask
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd ai-service && source .venv/bin/activate && python -m pytest tests/agents/kv_image_expand/test_canvas.py -q`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/agents/kv_image_expand/canvas.py tests/agents/kv_image_expand/test_canvas.py
git commit -m "feat(ai): kv image expand canvas + mask builder

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Pipeline service

**Files:**
- Create: `ai-service/app/agents/kv_image_expand/service.py`
- Test: `ai-service/tests/agents/kv_image_expand/test_service.py`

**Interfaces:**
- Consumes: `download_to_temp(url) -> str`, `build_expand_canvas`, `outpaint(canvas, mask, prompt) -> (bytes, model:str, token_usage:dict)`, `OUTPAINT_GUIDANCE`, `save_bytes_to_file(image_bytes=, temp_folder_path=, destination_path=, file_name=) -> str|None`, `post_completed`.
- Produces: `process_image_expand(req: ImageExpandRequest) -> None`.

- [ ] **Step 1: Write the failing tests**

```python
# ai-service/tests/agents/kv_image_expand/test_service.py
"""process_image_expand runs as a BackgroundTask: it must ALWAYS end in a
callback and NEVER raise. Every vendor/network call is mocked; what is
asserted is what reaches outpaint() and what reaches the api."""
from io import BytesIO
from unittest.mock import patch

from PIL import Image

from app.agents.kv_image_expand.request_schema import ImageExpandRequest
from app.agents.kv_image_expand.service import process_image_expand

MOD = "app.agents.kv_image_expand.service"


def _png(tmp_path, size=(40, 30)):
    p = tmp_path / "src.png"
    Image.new("RGB", size, (255, 0, 0)).save(p, format="PNG")
    return str(p)


def _req(**overrides):
    base = dict(
        image_expand_id="01EXPAND",
        source_image_url="https://s3.test/src.png",
        source_w=40,
        source_h=30,
        placement=dict(canvas_w=100, canvas_h=60, image_x=10, image_y=20),
    )
    base.update(overrides)
    return ImageExpandRequest(**base)


USAGE = {"type": "Image Generation", "model": "gpt-image-2",
         "input_text_tokens": 1, "input_image_tokens": 2, "output_image_tokens": 3}


@patch(f"{MOD}.post_completed")
@patch(f"{MOD}.save_bytes_to_file", return_value="https://cdn.test/out.png")
@patch(f"{MOD}.outpaint", return_value=(b"PNGBYTES", "gpt-image-2", USAGE))
@patch(f"{MOD}.download_to_temp")
def test_happy_path_outpaints_placed_canvas_and_reports_done(
    mock_dl, mock_outpaint, mock_save, mock_post, tmp_path
):
    mock_dl.return_value = _png(tmp_path)

    process_image_expand(_req())

    canvas, mask, prompt = mock_outpaint.call_args.args
    assert canvas.size == (100, 60)
    assert mask.size == (100, 60)
    assert mask.getpixel((10, 20)) == 0      # preserve the source
    assert mask.getpixel((9, 20)) == 255     # paint the margin
    assert "extend the scene" in prompt.lower()

    assert mock_save.call_args.kwargs["image_bytes"] == b"PNGBYTES"
    assert mock_save.call_args.kwargs["destination_path"].endswith("/kv-image-expands")
    assert mock_save.call_args.kwargs["file_name"] == "01EXPAND.png"

    mock_post.assert_called_once_with(
        image_expand_id="01EXPAND",
        status="done",
        image_url="https://cdn.test/out.png",
        width=100,
        height=60,
        model_version="gpt-image-2",
        token_usage=USAGE,
    )


@patch(f"{MOD}.post_completed")
@patch(f"{MOD}.outpaint")
@patch(f"{MOD}.download_to_temp")
def test_natural_size_mismatch_fails_without_calling_vendor(
    mock_dl, mock_outpaint, mock_post, tmp_path
):
    mock_dl.return_value = _png(tmp_path, size=(41, 30))

    process_image_expand(_req())

    mock_outpaint.assert_not_called()
    kwargs = mock_post.call_args.kwargs
    assert kwargs["status"] == "failed"
    assert "41" in kwargs["error_message"] and "40" in kwargs["error_message"]


@patch(f"{MOD}.post_completed")
@patch(f"{MOD}.outpaint", side_effect=RuntimeError("gpt-image-2 520"))
@patch(f"{MOD}.download_to_temp")
def test_vendor_error_becomes_failed_callback_not_exception(
    mock_dl, mock_outpaint, mock_post, tmp_path
):
    mock_dl.return_value = _png(tmp_path)

    process_image_expand(_req())  # must not raise

    mock_post.assert_called_once()
    assert mock_post.call_args.kwargs["status"] == "failed"
    assert "520" in mock_post.call_args.kwargs["error_message"]


@patch(f"{MOD}.post_completed")
@patch(f"{MOD}.save_bytes_to_file", return_value=None)
@patch(f"{MOD}.outpaint", return_value=(b"PNGBYTES", "gpt-image-2", USAGE))
@patch(f"{MOD}.download_to_temp")
def test_upload_returning_none_is_a_failure(
    mock_dl, mock_outpaint, mock_save, mock_post, tmp_path
):
    mock_dl.return_value = _png(tmp_path)

    process_image_expand(_req())

    assert mock_post.call_args.kwargs["status"] == "failed"
    assert "upload" in mock_post.call_args.kwargs["error_message"].lower()


@patch(f"{MOD}.post_completed", side_effect=[RuntimeError("api down"), None])
@patch(f"{MOD}.download_to_temp", side_effect=RuntimeError("404"))
def test_failed_callback_failing_is_swallowed(mock_dl, mock_post):
    process_image_expand(_req())  # must not raise even when the callback dies
    assert mock_post.call_count == 1


@patch(f"{MOD}.post_completed")
@patch(f"{MOD}.outpaint", side_effect=RuntimeError("x"))
@patch(f"{MOD}.download_to_temp")
def test_temp_file_is_removed(mock_dl, mock_outpaint, mock_post, tmp_path):
    path = _png(tmp_path)
    mock_dl.return_value = path

    process_image_expand(_req())

    import os
    assert not os.path.exists(path)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ai-service && source .venv/bin/activate && python -m pytest tests/agents/kv_image_expand/test_service.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'app.agents.kv_image_expand.service'`

- [ ] **Step 3: Write the service**

```python
# ai-service/app/agents/kv_image_expand/service.py
"""KV Expand Image orchestration.

Pipeline (mirrors ``app/agents/kv_background_removal/service.py``):
  1. Download the source overlay image to a temp file.
  2. Verify its natural size matches what the web measured — the placement
     is expressed in those pixels, so a mismatch would silently shift the
     source inside the canvas.
  3. Build the placed canvas + mask (``canvas.build_expand_canvas``).
  4. ``outpaint`` the mask with gpt-image-2 (``app.tools.outpaint_image``).
  5. Upload the PNG to S3 at ``{API_ENV}/kv-image-expands/{id}.png``.
  6. POST the result (+ token usage, which the api meters) back to
     ``/api/v1/internal/kv-image-expands/completed``.

On any error, post a ``failed`` callback. Never raise — this runs as a
FastAPI BackgroundTask and an unhandled exception would leave the api row
stuck in ``pending`` until its watchdog fires.
"""

import logging
import os

from PIL import Image

from app.agents.kv_image_expand.api_client import post_completed
from app.agents.kv_image_expand.canvas import build_expand_canvas
from app.agents.kv_image_expand.request_schema import ImageExpandRequest
from app.agents.kv_resize.prompts.outpaint import OUTPAINT_GUIDANCE
from app.tools.download import download_to_temp
from app.tools.edit_image import save_bytes_to_file
from app.tools.outpaint_image import outpaint
from app.utils.config import settings

logger = logging.getLogger(__name__)


def process_image_expand(req: ImageExpandRequest) -> None:
    """Run the full expand pipeline. Does not raise -- always callbacks."""
    source_path: str | None = None
    try:
        source_path = download_to_temp(req.source_image_url)

        with Image.open(source_path) as opened:
            src = opened.convert("RGBA")
        w, h = src.size
        if (w, h) != (req.source_w, req.source_h):
            raise ValueError(
                f"Source image is {w}x{h}, expected {req.source_w}x{req.source_h}"
            )

        canvas, mask = build_expand_canvas(src, req.placement)
        image_bytes, model, token_usage = outpaint(canvas, mask, OUTPAINT_GUIDANCE)

        image_url = save_bytes_to_file(
            image_bytes=image_bytes,
            temp_folder_path="./temp",
            destination_path=f"{settings.API_ENV}/kv-image-expands",
            file_name=f"{req.image_expand_id}.png",
        )
        # save_bytes_to_file returns None (not an exception) when the S3
        # upload fails, despite its `-> str` annotation.
        if not image_url:
            raise RuntimeError("Upload of the expanded image failed")

        post_completed(
            image_expand_id=req.image_expand_id,
            status="done",
            image_url=image_url,
            width=req.placement.canvas_w,
            height=req.placement.canvas_h,
            model_version=model,
            token_usage=token_usage,
        )
    except Exception as exc:  # noqa: BLE001
        logger.exception(
            "kv_image_expand.process_image_expand failed",
            extra={"image_expand_id": req.image_expand_id},
        )
        try:
            post_completed(
                image_expand_id=req.image_expand_id,
                status="failed",
                error_message=str(exc),
            )
        except Exception:  # noqa: BLE001
            logger.exception(
                "kv_image_expand.post_completed (failed) also failed",
                extra={"image_expand_id": req.image_expand_id},
            )
    finally:
        if source_path and os.path.exists(source_path):
            try:
                os.unlink(source_path)
            except OSError:
                pass
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ai-service && source .venv/bin/activate && python -m pytest tests/agents/kv_image_expand/test_service.py -q`
Expected: all PASS

- [ ] **Step 5: Mutation check** — swap `width=req.placement.canvas_w` for `width=w` in the done callback; `test_happy_path…` must FAIL (100 vs 40). Revert.

- [ ] **Step 6: Commit**

```bash
git add app/agents/kv_image_expand/service.py tests/agents/kv_image_expand/test_service.py
git commit -m "feat(ai): kv image expand pipeline (place → outpaint → upload → callback)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Router + app registration

**Files:**
- Create: `ai-service/app/agents/kv_image_expand/router.py`
- Modify: `ai-service/main.py` (import next to line 24, `include_router` next to line 151)
- Test: `ai-service/tests/agents/kv_image_expand/test_router.py`

**Interfaces:**
- Produces: `POST /ai/kv-image-expand/run` → 202 `{image_expand_id, status:"accepted"}`; 422 on schema violation.

- [ ] **Step 1: Write the failing test**

```python
# ai-service/tests/agents/kv_image_expand/test_router.py
from unittest.mock import patch

import pytest

pytestmark = pytest.mark.anyio


def _body(**placement_overrides):
    placement = dict(canvas_w=640, canvas_h=360, image_x=120, image_y=30)
    placement.update(placement_overrides)
    return dict(
        image_expand_id="01EXPAND",
        source_image_url="https://s3.test/src.png",
        source_w=400,
        source_h=300,
        placement=placement,
    )


@patch("app.agents.kv_image_expand.router.process_image_expand")
async def test_run_returns_202_and_schedules_the_pipeline(mock_process, async_client):
    resp = await async_client.post("/ai/kv-image-expand/run", json=_body())

    assert resp.status_code == 202
    assert resp.json() == {"image_expand_id": "01EXPAND", "status": "accepted"}
    # BackgroundTasks run after the response inside the ASGI transport, so
    # by the time the client returns the task has executed.
    assert mock_process.call_count == 1
    assert mock_process.call_args.args[0].image_expand_id == "01EXPAND"


@patch("app.agents.kv_image_expand.router.process_image_expand")
async def test_run_rejects_uncontained_placement_with_422(mock_process, async_client):
    resp = await async_client.post(
        "/ai/kv-image-expand/run", json=_body(image_x=241)
    )

    assert resp.status_code == 422
    mock_process.assert_not_called()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ai-service && source .venv/bin/activate && python -m pytest tests/agents/kv_image_expand/test_router.py -q`
Expected: FAIL — `ModuleNotFoundError` for `app.agents.kv_image_expand.router` (patch target), or 404 once the module exists but isn't registered.

- [ ] **Step 3: Write the router and register it**

```python
# ai-service/app/agents/kv_image_expand/router.py
from fastapi import APIRouter, BackgroundTasks
from fastapi.responses import JSONResponse

from app.agents.kv_image_expand.request_schema import ImageExpandRequest
from app.agents.kv_image_expand.response_schema import ImageExpandAccepted
from app.agents.kv_image_expand.service import process_image_expand

router = APIRouter(prefix="/ai/kv-image-expand", tags=["kv-image-expand"])


@router.post("/run", response_model=ImageExpandAccepted, status_code=202)
def run(req: ImageExpandRequest, background: BackgroundTasks):
    """Dispatch a kv-image-expand job.

    The actual work runs in a FastAPI BackgroundTask. The result is
    delivered via a callback to the API at
    ``/api/v1/internal/kv-image-expands/completed``.
    """
    background.add_task(process_image_expand, req)
    return JSONResponse(
        status_code=202,
        content=ImageExpandAccepted(image_expand_id=req.image_expand_id).model_dump(),
    )
```

In `ai-service/main.py`, directly after the line
`from app.agents.kv_background_removal.router import router as kv_background_removal_router`
add:

```python
from app.agents.kv_image_expand.router import router as kv_image_expand_router
```

and directly after `app.include_router(kv_background_removal_router)` add:

```python
app.include_router(kv_image_expand_router)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd ai-service && source .venv/bin/activate && python -m pytest tests/agents/kv_image_expand -q`
Expected: all tests in the package PASS

If `test_run_returns_202…` fails on `mock_process.call_count == 1` because the ASGI transport does not run background tasks, change the assertion to assert on the 202 body only and add a separate synchronous test that calls `run(req, BackgroundTasks())` directly and asserts `background.tasks[0].func is process_image_expand`.

- [ ] **Step 5: Smoke the route through the real app object**

Run: `cd ai-service && source .venv/bin/activate && python -c "from main import app; print([r.path for r in app.routes if 'image-expand' in r.path])"`
Expected: `['/ai/kv-image-expand/run']`

- [ ] **Step 6: Commit**

```bash
git add app/agents/kv_image_expand/router.py main.py tests/agents/kv_image_expand/test_router.py
git commit -m "feat(ai): register POST /ai/kv-image-expand/run

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Full package run + lint

**Files:** none new.

- [ ] **Step 1: Run the whole new package**

Run: `cd ai-service && source .venv/bin/activate && python -m pytest tests/agents/kv_image_expand -q`
Expected: all PASS

- [ ] **Step 2: Run the resize canvas tests to prove nothing shared regressed**

Run: `cd ai-service && source .venv/bin/activate && python -m pytest tests/agents/kv_resize -q`
Expected: same result as before this branch (compare against `git stash`-free baseline: `git worktree add /tmp/ai-base development && cd /tmp/ai-base && python -m pytest tests/agents/kv_resize -q`, then `git worktree remove /tmp/ai-base`). Never `git stash`.

- [ ] **Step 3: Lint**

Run: `cd ai-service && source .venv/bin/activate && ruff check app/agents/kv_image_expand tests/agents/kv_image_expand` (if `ruff` is not installed, `python -m pyflakes` on the same paths; if neither exists, skip and say so).
Expected: clean

- [ ] **Step 4: Report** — list the commits on the branch (`git log --oneline development..HEAD`) and the pytest summary line. Do not push.
