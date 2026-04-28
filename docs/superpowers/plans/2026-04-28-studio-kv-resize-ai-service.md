# KV Generator — Resize Mode (AI Service) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the AI service layer of KV Resize: a new `kv_resize` agent module that downloads the source image, computes an outpaint canvas + mask, runs FLUX Fill Pro (with OpenAI gpt-image-1 mask fallback), uploads the result, and posts back to the API. Spec: [`docs/superpowers/specs/2026-04-28-studio-kv-resize-design.md`](../specs/2026-04-28-studio-kv-resize-design.md).

**Architecture:** New module `app/agents/kv_resize/` with a router (`POST /ai/kv-resize/export`), service (orchestration), `canvas.py` (PIL helpers — smart_crop / pad_to_target / build_mask), and `api_client.py` (callback to API). Outpaint primitives live in `app/tools/outpaint_image.py` — separate file because the existing `edit_image.py` `black-forest-labs` branch passes `prompt + input_image` only and does not pass a `mask`.

**Tech Stack:** FastAPI, Python 3.11, Pillow, Replicate SDK (existing `replicate_client.run_with_retry`), OpenAI SDK (existing). Pytest + pytest-asyncio.

**Branch:** `feature/daffa/vc-studio-projects-kv-generator` (extension of in-flight feature; no new branch).

---

## File Structure

**New files:**
- `ai-service/app/agents/kv_resize/__init__.py`
- `ai-service/app/agents/kv_resize/router.py`
- `ai-service/app/agents/kv_resize/service.py`
- `ai-service/app/agents/kv_resize/canvas.py`
- `ai-service/app/agents/kv_resize/request_schema.py`
- `ai-service/app/agents/kv_resize/response_schema.py`
- `ai-service/app/agents/kv_resize/api_client.py`
- `ai-service/app/agents/kv_resize/prompts/__init__.py`
- `ai-service/app/agents/kv_resize/prompts/outpaint.py`
- `ai-service/app/tools/outpaint_image.py`
- `ai-service/tests/agents/kv_resize/__init__.py`
- `ai-service/tests/agents/kv_resize/test_canvas.py`
- `ai-service/tests/agents/kv_resize/test_service.py`
- `ai-service/tests/agents/kv_resize/test_router.py`

**Modified files:**
- `ai-service/main.py` (or `ai-service/app/main.py`) — register the new router.

---

## Task 1: Outpaint guidance prompt

**Files:**
- Create: `ai-service/app/agents/kv_resize/prompts/__init__.py` (empty)
- Create: `ai-service/app/agents/kv_resize/prompts/outpaint.py`

- [ ] **Step 1: Write the prompt**

```python
# ai-service/app/agents/kv_resize/prompts/outpaint.py
OUTPAINT_GUIDANCE = (
    "Naturally extend the scene to fill the new frame. Preserve all original "
    "pixels exactly — do NOT redraw subjects, brand elements, copy, or text. "
    "Only paint into the masked region; the unmasked region must remain "
    "byte-identical to the source. Match lighting, depth, perspective, and "
    "color of the source at the seam. No new subjects or focal elements."
)
```

- [ ] **Step 2: Commit**

```bash
git add ai-service/app/agents/kv_resize/prompts/
git commit -m "feat(ai): add outpaint guidance prompt"
```

---

## Task 2: Canvas helpers — write failing test

**Files:**
- Create: `ai-service/app/agents/kv_resize/__init__.py` (empty)
- Create: `ai-service/tests/agents/kv_resize/__init__.py` (empty)
- Create: `ai-service/tests/agents/kv_resize/test_canvas.py`

- [ ] **Step 1: Write the failing tests**

```python
# ai-service/tests/agents/kv_resize/test_canvas.py
from PIL import Image

from app.agents.kv_resize.canvas import (
    smart_crop,
    pad_to_target,
    build_mask,
)


def make_image(w: int, h: int, color=(255, 0, 0)) -> Image.Image:
    return Image.new("RGB", (w, h), color)


def test_smart_crop_when_source_wider_than_target():
    src = make_image(1920, 1080)  # 16:9
    out = smart_crop(src, target_w=1080, target_h=1080)  # → 1:1
    assert out.size == (1080, 1080)


def test_smart_crop_when_source_taller_than_target():
    src = make_image(1080, 1920)  # 9:16
    out = smart_crop(src, target_w=1080, target_h=566)  # → 1.91:1
    assert out.size == (1080, 566)


def test_smart_crop_skips_when_source_smaller_on_both_axes():
    """When source fits inside target on both axes, no crop is needed."""
    src = make_image(800, 600)
    out = smart_crop(src, target_w=1080, target_h=1080)
    # Source already fits inside target → smart_crop returns it unchanged
    assert out.size == (800, 600)


def test_pad_to_target_centers_source_on_transparent_canvas():
    src = make_image(800, 600)
    out, paste_box = pad_to_target(src, target_w=1080, target_h=1080)

    assert out.size == (1080, 1080)
    assert out.mode == "RGBA"
    # Paste box: centered → x=140, y=240, x2=940, y2=840
    assert paste_box == (140, 240, 940, 840)


def test_build_mask_white_on_padding_black_on_source():
    paste_box = (140, 240, 940, 840)
    mask = build_mask(target_w=1080, target_h=1080, paste_box=paste_box)

    assert mask.size == (1080, 1080)
    assert mask.mode == "L"
    # Top-left corner is padding → white (255)
    assert mask.getpixel((0, 0)) == 255
    # Center of paste box → black (0)
    assert mask.getpixel((540, 540)) == 0
    # Just outside the paste box → white (255)
    assert mask.getpixel((139, 540)) == 255


def test_build_mask_uses_openai_convention():
    """OpenAI/FLUX both use: white = paint, black = preserve. Confirm direction."""
    paste_box = (10, 10, 90, 90)
    mask = build_mask(target_w=100, target_h=100, paste_box=paste_box)
    assert mask.getpixel((50, 50)) == 0   # inside paste → preserve
    assert mask.getpixel((5, 5)) == 255    # outside paste → paint
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd ai-service && source .venv/bin/activate && pytest tests/agents/kv_resize/test_canvas.py -v
```

Expected: ImportError — `app.agents.kv_resize.canvas` does not exist.

---

## Task 3: Canvas helpers — implement

**Files:**
- Create: `ai-service/app/agents/kv_resize/canvas.py`

- [ ] **Step 1: Implement the helpers**

```python
# ai-service/app/agents/kv_resize/canvas.py
from PIL import Image


def smart_crop(src: Image.Image, target_w: int, target_h: int) -> Image.Image:
    """Center-crop the source so its aspect ratio matches the target.

    The crop preserves as much of the source area as possible:
      - if source aspect >= target aspect → height-fit, crop horizontally
      - if source aspect <  target aspect → width-fit, crop vertically

    When the source already fits inside the target on both axes (no
    cropping is needed before the outpaint pass), the source is
    returned unchanged. Pad/mask is responsible for placing it.
    """
    sw, sh = src.size
    if sw <= target_w and sh <= target_h:
        return src

    src_aspect = sw / sh
    target_aspect = target_w / target_h

    if src_aspect >= target_aspect:
        new_h = sh
        new_w = round(sh * target_aspect)
        x = (sw - new_w) // 2
        y = 0
    else:
        new_w = sw
        new_h = round(sw / target_aspect)
        x = 0
        y = (sh - new_h) // 2

    cropped = src.crop((x, y, x + new_w, y + new_h))

    # If the crop is larger than the target on both axes, downscale.
    if cropped.size[0] > target_w or cropped.size[1] > target_h:
        cropped = cropped.resize((target_w, target_h), Image.LANCZOS)

    return cropped


def pad_to_target(
    src: Image.Image, target_w: int, target_h: int
) -> tuple[Image.Image, tuple[int, int, int, int]]:
    """Paste the source centered on a transparent target-sized RGBA canvas.

    Returns the canvas + the paste rectangle (x1, y1, x2, y2).
    Caller is expected to have already cropped the source to fit inside
    the target on both axes (via `smart_crop`).
    """
    canvas = Image.new("RGBA", (target_w, target_h), (0, 0, 0, 0))
    sw, sh = src.size
    x = (target_w - sw) // 2
    y = (target_h - sh) // 2
    src_rgba = src.convert("RGBA")
    canvas.paste(src_rgba, (x, y), src_rgba)
    return canvas, (x, y, x + sw, y + sh)


def build_mask(
    target_w: int,
    target_h: int,
    paste_box: tuple[int, int, int, int],
) -> Image.Image:
    """Build the outpaint mask.

    Convention: white (255) = paint here, black (0) = preserve.
    Both FLUX Fill Pro and OpenAI gpt-image-1 mask edits use this
    convention.
    """
    mask = Image.new("L", (target_w, target_h), 255)  # paint everywhere
    x1, y1, x2, y2 = paste_box
    inner = Image.new("L", (x2 - x1, y2 - y1), 0)     # preserve source area
    mask.paste(inner, (x1, y1))
    return mask
```

- [ ] **Step 2: Run tests**

```bash
cd ai-service && source .venv/bin/activate && pytest tests/agents/kv_resize/test_canvas.py -v
```

Expected: 6 tests pass.

- [ ] **Step 3: Commit**

```bash
git add ai-service/app/agents/kv_resize/canvas.py \
        ai-service/app/agents/kv_resize/__init__.py \
        ai-service/tests/agents/kv_resize/__init__.py \
        ai-service/tests/agents/kv_resize/test_canvas.py
git commit -m "feat(ai): add canvas helpers for outpaint resize"
```

---

## Task 4: Outpaint helper — implement (FLUX Fill Pro + OpenAI fallback)

**Files:**
- Create: `ai-service/app/tools/outpaint_image.py`

- [ ] **Step 1: Write the helper**

```python
# ai-service/app/tools/outpaint_image.py
"""Outpaint primitives for the KV Resize feature.

FLUX Fill Pro is the default. On 5xx / rate-limit / timeout, fall back
to OpenAI gpt-image-1's `/v1/images/edits` with the same image+mask
shape (already proven by the KV bounding-box edit feature).
"""

from io import BytesIO
from typing import Literal

import requests
from PIL import Image

from app.utils.config import settings
from app.utils.replicate_client import (
    ReplicateRateLimitError,
    run_with_retry as replicate_run,
)


def _png_bytes(img: Image.Image) -> bytes:
    buf = BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def outpaint_with_flux_fill(
    canvas: Image.Image,
    mask: Image.Image,
    prompt: str,
) -> bytes:
    """Call FLUX Fill Pro via Replicate. Returns PNG bytes.

    Raises ReplicateRateLimitError on rate limits — caller handles
    fallback.
    """
    canvas_bytes = _png_bytes(canvas)
    mask_bytes = _png_bytes(mask)

    output = replicate_run(
        model_ref="black-forest-labs/flux-fill-pro",
        input_params={
            "image": ("image.png", canvas_bytes, "image/png"),
            "mask": ("mask.png", mask_bytes, "image/png"),
            "prompt": prompt,
            "output_format": "png",
        },
    )
    return output.read()


def outpaint_with_openai_mask(
    canvas: Image.Image,
    mask: Image.Image,
    prompt: str,
) -> bytes:
    """Fallback: OpenAI gpt-image-1 `/v1/images/edits` with mask.

    Same image+mask convention (transparent in the mask = paint).
    """
    import base64

    canvas_bytes = _png_bytes(canvas)
    mask_bytes = _png_bytes(mask)

    files = [
        ("model", (None, "gpt-image-1")),
        ("prompt", (None, prompt)),
        ("quality", (None, "high")),
        ("image[]", ("image.png", canvas_bytes, "image/png")),
        ("mask", ("mask.png", mask_bytes, "image/png")),
    ]
    response = requests.post(
        "https://api.openai.com/v1/images/edits",
        headers={"Authorization": f"Bearer {settings.OPENAI_API_KEY}"},
        files=files,
        timeout=180,
    )
    response.raise_for_status()
    result = response.json()
    if not result.get("data"):
        raise RuntimeError(f"OpenAI returned no image: {result}")
    return base64.b64decode(result["data"][0]["b64_json"])


def outpaint(
    canvas: Image.Image,
    mask: Image.Image,
    prompt: str,
) -> tuple[bytes, Literal["flux-fill-pro", "gpt-image-1"]]:
    """Run FLUX Fill Pro; on rate-limit or 5xx, fall back to OpenAI."""
    try:
        return outpaint_with_flux_fill(canvas, mask, prompt), "flux-fill-pro"
    except ReplicateRateLimitError:
        return outpaint_with_openai_mask(canvas, mask, prompt), "gpt-image-1"
    except Exception as exc:  # noqa: BLE001
        msg = str(exc).lower()
        if "503" in msg or "unavailable" in msg or "timeout" in msg:
            return outpaint_with_openai_mask(canvas, mask, prompt), "gpt-image-1"
        raise
```

- [ ] **Step 2: Commit**

```bash
git add ai-service/app/tools/outpaint_image.py
git commit -m "feat(ai): add outpaint helper with FLUX Fill Pro and OpenAI fallback"
```

---

## Task 5: Request and response schemas

**Files:**
- Create: `ai-service/app/agents/kv_resize/request_schema.py`
- Create: `ai-service/app/agents/kv_resize/response_schema.py`

- [ ] **Step 1: Write the request schema**

```python
# ai-service/app/agents/kv_resize/request_schema.py
from typing import Optional

from pydantic import BaseModel, Field


class CropWindow(BaseModel):
    x: int = Field(ge=0)
    y: int = Field(ge=0)
    w: int = Field(gt=0)
    h: int = Field(gt=0)


class ResizeExportRequest(BaseModel):
    export_id: str
    source_image_url: str
    target_width: int = Field(gt=0)
    target_height: int = Field(gt=0)
    crop_window: Optional[CropWindow] = None
```

- [ ] **Step 2: Write the response schema**

```python
# ai-service/app/agents/kv_resize/response_schema.py
from pydantic import BaseModel


class ResizeExportAccepted(BaseModel):
    export_id: str
    status: str = "accepted"
```

- [ ] **Step 3: Commit**

```bash
git add ai-service/app/agents/kv_resize/request_schema.py \
        ai-service/app/agents/kv_resize/response_schema.py
git commit -m "feat(ai): add resize export request/response schemas"
```

---

## Task 6: API client (callback to Laravel)

**Files:**
- Create: `ai-service/app/agents/kv_resize/api_client.py`

- [ ] **Step 1: Write the client**

```python
# ai-service/app/agents/kv_resize/api_client.py
import requests

from app.utils.config import settings


def post_completed(
    *,
    export_id: str,
    status: str,
    image_url: str | None = None,
    error_message: str | None = None,
) -> None:
    """Post final status back to the API."""
    url = f"{settings.API_SERVICE_URL.rstrip('/')}/api/v1/internal/kv-resize-exports/completed"
    payload = {"export_id": export_id, "status": status}
    if image_url is not None:
        payload["image_url"] = image_url
    if error_message is not None:
        payload["error_message"] = error_message

    requests.post(url, json=payload, timeout=10).raise_for_status()
```

If `settings.API_SERVICE_URL` is not in `app/utils/config.py`, add it:

```python
API_SERVICE_URL: str = Field(default="http://localhost:9191")
```

- [ ] **Step 2: Commit**

```bash
git add ai-service/app/agents/kv_resize/api_client.py ai-service/app/utils/config.py
git commit -m "feat(ai): add resize export api callback client"
```

---

## Task 7: Service — write failing test

**Files:**
- Create: `ai-service/tests/agents/kv_resize/test_service.py`

- [ ] **Step 1: Write the failing tests**

```python
# ai-service/tests/agents/kv_resize/test_service.py
from io import BytesIO
from unittest.mock import MagicMock, patch

import pytest
from PIL import Image

from app.agents.kv_resize.service import process_resize_export
from app.agents.kv_resize.request_schema import ResizeExportRequest


def _png_bytes(w: int, h: int, color=(0, 200, 100)) -> bytes:
    img = Image.new("RGB", (w, h), color)
    buf = BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


@patch("app.agents.kv_resize.service.requests.get")
@patch("app.agents.kv_resize.service.outpaint")
@patch("app.agents.kv_resize.service.save_bytes_to_file")
@patch("app.agents.kv_resize.service.post_completed")
def test_happy_path_calls_outpaint_and_callback(
    mock_post_completed, mock_save, mock_outpaint, mock_get
):
    # Source image is 800x600, target 1080x1920 → smart_crop returns it
    # unchanged; pad+mask + outpaint produces the result.
    mock_get.return_value = MagicMock(
        ok=True, content=_png_bytes(800, 600), status_code=200
    )
    mock_outpaint.return_value = (b"FAKE_PNG_BYTES", "flux-fill-pro")
    mock_save.return_value = "https://cdn.example.com/out.png"

    req = ResizeExportRequest(
        export_id="01HXYZ",
        source_image_url="https://src.example.com/in.png",
        target_width=1080,
        target_height=1920,
        crop_window=None,
    )

    process_resize_export(req)

    mock_outpaint.assert_called_once()
    mock_save.assert_called_once()
    mock_post_completed.assert_called_once()
    call = mock_post_completed.call_args
    assert call.kwargs["status"] == "done"
    assert call.kwargs["image_url"] == "https://cdn.example.com/out.png"


@patch("app.agents.kv_resize.service.requests.get")
@patch("app.agents.kv_resize.service.outpaint")
@patch("app.agents.kv_resize.service.save_bytes_to_file")
@patch("app.agents.kv_resize.service.post_completed")
def test_skips_outpaint_when_source_covers_target(
    mock_post_completed, mock_save, mock_outpaint, mock_get
):
    # Source 1920x1080 covers target 820x360 on both axes (after crop).
    mock_get.return_value = MagicMock(
        ok=True, content=_png_bytes(1920, 1080), status_code=200
    )
    mock_save.return_value = "https://cdn.example.com/cropped.png"

    req = ResizeExportRequest(
        export_id="01HXYZ",
        source_image_url="https://src.example.com/in.png",
        target_width=820,
        target_height=360,
    )

    process_resize_export(req)

    mock_outpaint.assert_not_called()
    mock_save.assert_called_once()
    assert mock_post_completed.call_args.kwargs["status"] == "done"


@patch("app.agents.kv_resize.service.requests.get")
@patch("app.agents.kv_resize.service.outpaint", side_effect=RuntimeError("flux down"))
@patch("app.agents.kv_resize.service.post_completed")
def test_marks_failed_on_outpaint_error(
    mock_post_completed, mock_outpaint, mock_get
):
    mock_get.return_value = MagicMock(
        ok=True, content=_png_bytes(800, 600), status_code=200
    )
    req = ResizeExportRequest(
        export_id="01HXYZ",
        source_image_url="https://src.example.com/in.png",
        target_width=1080,
        target_height=1920,
    )

    process_resize_export(req)

    assert mock_post_completed.call_args.kwargs["status"] == "failed"
    assert "flux down" in mock_post_completed.call_args.kwargs["error_message"]
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd ai-service && source .venv/bin/activate && pytest tests/agents/kv_resize/test_service.py -v
```

Expected: ImportError on `process_resize_export`.

---

## Task 8: Service — implement

**Files:**
- Create: `ai-service/app/agents/kv_resize/service.py`

- [ ] **Step 1: Implement the service**

```python
# ai-service/app/agents/kv_resize/service.py
"""KV Resize export orchestration.

Pipeline:
  1. download source image
  2. smart_crop  →  paste-able source within target dims
  3. if cropped source covers the target on both axes → upload cropped, done.
  4. else: pad_to_target + build_mask → outpaint → upload.
  5. post_completed callback to API.
"""

from io import BytesIO
from uuid import uuid4

import requests
from PIL import Image

from app.agents.kv_resize.api_client import post_completed
from app.agents.kv_resize.canvas import (
    build_mask,
    pad_to_target,
    smart_crop,
)
from app.agents.kv_resize.prompts.outpaint import OUTPAINT_GUIDANCE
from app.agents.kv_resize.request_schema import ResizeExportRequest
from app.tools.edit_image import save_bytes_to_file
from app.tools.outpaint_image import outpaint
from app.utils.config import settings


def process_resize_export(req: ResizeExportRequest) -> None:
    try:
        source = _download(req.source_image_url)

        if req.crop_window is not None:
            cw = req.crop_window
            cropped = source.crop((cw.x, cw.y, cw.x + cw.w, cw.y + cw.h))
            cropped = _resize_to_fit(cropped, req.target_width, req.target_height)
        else:
            cropped = smart_crop(source, req.target_width, req.target_height)

        if (
            cropped.size[0] >= req.target_width
            and cropped.size[1] >= req.target_height
        ):
            # Source covers target on both axes after crop → no outpaint
            cropped = cropped.resize(
                (req.target_width, req.target_height), Image.LANCZOS
            )
            image_bytes = _png_bytes(cropped.convert("RGB"))
        else:
            canvas, paste_box = pad_to_target(
                cropped, req.target_width, req.target_height
            )
            mask = build_mask(req.target_width, req.target_height, paste_box)
            image_bytes, _model = outpaint(canvas, mask, OUTPAINT_GUIDANCE)

        image_url = save_bytes_to_file(
            image_bytes=image_bytes,
            temp_folder_path="./temp",
            destination_path=f"{settings.API_ENV}/kv-resize-exports/{req.export_id}",
            file_name=f"{uuid4()}.png",
        )

        post_completed(
            export_id=req.export_id,
            status="done",
            image_url=image_url,
        )
    except Exception as exc:  # noqa: BLE001
        post_completed(
            export_id=req.export_id,
            status="failed",
            error_message=str(exc),
        )


def _download(url: str) -> Image.Image:
    resp = requests.get(url, timeout=60)
    resp.raise_for_status()
    return Image.open(BytesIO(resp.content)).convert("RGB")


def _resize_to_fit(img: Image.Image, target_w: int, target_h: int) -> Image.Image:
    if img.size[0] <= target_w and img.size[1] <= target_h:
        return img
    return img.resize((target_w, target_h), Image.LANCZOS)


def _png_bytes(img: Image.Image) -> bytes:
    buf = BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()
```

- [ ] **Step 2: Run tests**

```bash
cd ai-service && source .venv/bin/activate && pytest tests/agents/kv_resize/test_service.py -v
```

Expected: 3 tests pass.

- [ ] **Step 3: Commit**

```bash
git add ai-service/app/agents/kv_resize/service.py \
        ai-service/tests/agents/kv_resize/test_service.py
git commit -m "feat(ai): add resize export service with skip-outpaint optimization"
```

---

## Task 9: Router — write failing test

**Files:**
- Create: `ai-service/tests/agents/kv_resize/test_router.py`

- [ ] **Step 1: Write the failing test**

```python
# ai-service/tests/agents/kv_resize/test_router.py
from unittest.mock import patch

from fastapi.testclient import TestClient

from app.main import app  # adjust path if main app is elsewhere


client = TestClient(app)


@patch("app.agents.kv_resize.router.process_resize_export")
def test_export_endpoint_returns_202_and_dispatches(mock_process):
    payload = {
        "export_id": "01HXYZ",
        "source_image_url": "https://src.example.com/in.png",
        "target_width": 1080,
        "target_height": 1920,
        "crop_window": None,
    }
    resp = client.post("/ai/kv-resize/export", json=payload)
    assert resp.status_code == 202
    assert resp.json() == {"export_id": "01HXYZ", "status": "accepted"}
    mock_process.assert_called_once()


def test_export_endpoint_rejects_invalid_dims():
    payload = {
        "export_id": "01HXYZ",
        "source_image_url": "https://src.example.com/in.png",
        "target_width": 0,
        "target_height": 1920,
    }
    resp = client.post("/ai/kv-resize/export", json=payload)
    assert resp.status_code == 422
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ai-service && source .venv/bin/activate && pytest tests/agents/kv_resize/test_router.py -v
```

Expected: FAIL — route not registered.

---

## Task 10: Router — implement and register

**Files:**
- Create: `ai-service/app/agents/kv_resize/router.py`
- Modify: `ai-service/app/main.py` (or wherever routers are included)

- [ ] **Step 1: Write the router**

```python
# ai-service/app/agents/kv_resize/router.py
from fastapi import APIRouter, BackgroundTasks
from fastapi.responses import JSONResponse

from app.agents.kv_resize.request_schema import ResizeExportRequest
from app.agents.kv_resize.response_schema import ResizeExportAccepted
from app.agents.kv_resize.service import process_resize_export

router = APIRouter(prefix="/ai/kv-resize", tags=["kv-resize"])


@router.post("/export", response_model=ResizeExportAccepted, status_code=202)
def export(req: ResizeExportRequest, background: BackgroundTasks):
    background.add_task(process_resize_export, req)
    return JSONResponse(
        status_code=202,
        content=ResizeExportAccepted(export_id=req.export_id).model_dump(),
    )
```

- [ ] **Step 2: Register the router in main.py**

Find the existing `include_router(...)` block. Add:

```python
from app.agents.kv_resize.router import router as kv_resize_router

app.include_router(kv_resize_router)
```

- [ ] **Step 3: Run tests**

```bash
cd ai-service && source .venv/bin/activate && pytest tests/agents/kv_resize/test_router.py -v
```

Expected: 2 tests pass.

- [ ] **Step 4: Commit**

```bash
git add ai-service/app/agents/kv_resize/router.py \
        ai-service/app/main.py \
        ai-service/tests/agents/kv_resize/test_router.py
git commit -m "feat(ai): register /ai/kv-resize/export router"
```

---

## Task 11: Final verification

- [ ] **Step 1: Run the full kv_resize test suite**

```bash
cd ai-service && source .venv/bin/activate && pytest tests/agents/kv_resize/ -v
```

Expected: 11 tests pass (6 canvas + 3 service + 2 router).

- [ ] **Step 2: Run a smoke test against a live source URL** (optional, requires Replicate key)

```bash
cd ai-service && source .venv/bin/activate && python -c "
from app.agents.kv_resize.request_schema import ResizeExportRequest
from app.agents.kv_resize.service import process_resize_export
process_resize_export(ResizeExportRequest(
    export_id='smoke-test',
    source_image_url='https://upload.wikimedia.org/wikipedia/commons/thumb/3/3a/Cat03.jpg/640px-Cat03.jpg',
    target_width=1080,
    target_height=1920,
))
"
```

Expect a callback POST attempt to the API. (If Laravel isn't running locally, the callback errors but the outpaint pipeline runs.)

- [ ] **Step 3: Self-check**

- All canvas helpers handle the four ratio quadrants (source >, =, < target on each axis).
- Outpaint fallback path is wired (try/except on Replicate errors → OpenAI).
- The service skips outpaint when the cropped source covers the target.
- The router is registered in `main.py`.
- The callback URL is correct (`/api/v1/internal/kv-resize-exports/completed`).

---

## Self-review

- ✅ Spec § Image-gen pipeline → Tasks 3 (canvas), 4 (outpaint helper), 8 (service orchestration)
- ✅ Spec § Outpaint prompt → Task 1
- ✅ Spec § AI service request shape → Task 5
- ✅ Spec § "skip outpaint when source covers target" → Task 8 + test in Task 7
- ✅ Spec § FLUX → OpenAI fallback → Task 4
- ✅ Spec § Internal callback → Task 6
- ✅ Spec § Router → Task 10
- ✅ No placeholders; every step has full code
- ✅ Function names consistent: `smart_crop`, `pad_to_target`, `build_mask`, `outpaint`, `process_resize_export`, `post_completed`
