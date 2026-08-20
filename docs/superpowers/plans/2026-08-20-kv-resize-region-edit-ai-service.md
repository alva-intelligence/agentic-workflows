# KV Resize Region Edit — ai-service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Resize pipeline a masked region-edit path so a bounding box drawn on one resize tile repaints only that region of that tile.

**Architecture:** The mask helpers currently private to `kv_generator/service.py` move to a shared module both agents import — a behaviour-preserving extraction. A new `kv_resize_region_edit` agent then downloads the tile's own image, probes its real pixel dimensions, builds a mask matched to them, calls the OpenAI images/edits path, and posts to the resize callback the API already listens on.

**Tech Stack:** FastAPI, Pydantic v2, Pillow, pytest. OpenAI `/images/edits` via `app/tools/edit_image.py`.

**Spec:** `docs/superpowers/specs/2026-08-20-kv-resize-region-edit-design.md`

## Global Constraints

- **Masks are OpenAI-only.** `kv_generator` already fails closed with the message *"Bounding-box edits require an OpenAI image model (masks are only supported there)."* The new path pins an OpenAI model and reuses that exact failure wording.
- **Never send `size` alongside a mask.** `edit_image.py:150` deliberately skips it: OpenAI requires `size` to match the mask's pixel dimensions and the output inherits them. Passing both conflicts.
- **gpt-image-2 accepts explicit pixel sizes only up to 3:1.** Tiles at or past that ratio must fail closed with a clear message, never return a distorted image.
- **Probe dimensions server-side.** Never trust client-reported width/height — `kv_generator` probes with `Image.open(...).size` for the same reason.
- **Extraction must not change Craft.** `kv_generator`'s existing tests are the regression gate; they must pass untouched.
- **Callback contract:** `post_completed` must carry `token_usage`, `ai_service_run_id` **and** `model` together, or the API's metering gate (`if ($aiRunId && ! empty($validated['token_usage']))`) silently skips the cost row.
- **Baseline before starting:** `tests/agents/{chat_agent,kv_generator}` carry 16 known failures at HEAD. Capture the baseline in a HEAD worktree first. "Green" means *no new red*. Never use `git stash`.
- **Dependencies install from `requirements.txt`.** Do not run `uv sync`.

## File Structure

| File | Responsibility |
|---|---|
| `app/agents/shared/region_edit.py` (create) | `BoundingBox`, `build_mask`, `polygon_pixels`, `compose_clear_prompt` — the region/mask primitives, owned by neither agent |
| `app/agents/kv_generator/request_schema.py` (modify) | Re-export `BoundingBox` from the shared module; no behaviour change |
| `app/agents/kv_generator/service.py` (modify) | Delegate `_build_mask` / `_polygon_pixels` / `_compose_clear_prompt` to the shared module |
| `app/agents/kv_resize_region_edit/request_schema.py` (create) | `RegionEditRequest` |
| `app/agents/kv_resize_region_edit/response_schema.py` (create) | `RegionEditAccepted` |
| `app/agents/kv_resize_region_edit/service.py` (create) | `process_region_edit` — download, probe, mask, edit, upload, callback |
| `app/agents/kv_resize_region_edit/router.py` (create) | `POST /ai/kv-resize-region-edit` |
| `main.py` (modify) | Register the router |

`kv_resize_region_edit` is a sibling of `kv_resize` rather than a branch inside `process_resize_export`. That function already carries five strategies and a vision prepass; a masked inpaint shares none of them.

---

### Task 1: Extract the region/mask primitives into a shared module

**Files:**
- Create: `app/agents/shared/__init__.py`
- Create: `app/agents/shared/region_edit.py`
- Modify: `app/agents/kv_generator/request_schema.py` (the `BoundingBox` class, line 52)
- Modify: `app/agents/kv_generator/service.py` (`_build_mask` ~2502, `_polygon_pixels` ~2484, `_compose_clear_prompt` ~2686)
- Test: `tests/agents/shared/test_region_edit.py`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `BoundingBox` (pydantic model, fields `id: str`, `x/y/width/height: float`, `prompt: Optional[str]`, `polygon: Optional[List[List[float]]]`, `rings: Optional[List[List[List[float]]]]`, `label: Optional[str]`) — moved verbatim, field-for-field, from `kv_generator/request_schema.py:52`.
  - `build_mask(boxes: List[BoundingBox], width: int, height: int) -> bytes`
  - `polygon_pixels(polygon: List[List[float]], width: int, height: int) -> List[Tuple[int, int]]`
  - `compose_clear_prompt(boxes: List[BoundingBox]) -> str`

- [ ] **Step 1: Capture the baseline**

```bash
cd ai-service && source .venv/bin/activate
python -m pytest tests/agents -q 2>&1 | tail -5 > /tmp/aisvc-baseline.txt
cat /tmp/aisvc-baseline.txt
```

Record the pass/fail counts. Every later step compares against this file.

- [ ] **Step 2: Write the failing test**

Create `tests/agents/shared/__init__.py` (empty) and `tests/agents/shared/test_region_edit.py`:

```python
import io

from PIL import Image

from app.agents.shared.region_edit import BoundingBox, build_mask


def _mask(boxes, w, h):
    return Image.open(io.BytesIO(build_mask(boxes, width=w, height=h)))


def test_rect_box_punches_a_transparent_hole():
    box = BoundingBox(id="b1", x=0.25, y=0.25, width=0.5, height=0.5)
    mask = _mask([box], 100, 100).convert("RGBA")
    # Centre of the box is editable (alpha 0); a corner outside it is kept.
    assert mask.getpixel((50, 50))[3] == 0
    assert mask.getpixel((2, 2))[3] == 255


def test_mask_matches_requested_non_square_dimensions():
    box = BoundingBox(id="b1", x=0.1, y=0.1, width=0.2, height=0.2)
    assert _mask([box], 1080, 1920).size == (1080, 1920)


def test_polygon_overrides_the_rectangle():
    # A polygon hugging the top-left triangle of the box: the box's
    # bottom-right corner must stay opaque even though the rect covers it.
    box = BoundingBox(
        id="b1", x=0.0, y=0.0, width=1.0, height=1.0,
        polygon=[[0.0, 0.0], [0.4, 0.0], [0.0, 0.4]],
    )
    mask = _mask([box], 100, 100).convert("RGBA")
    assert mask.getpixel((5, 5))[3] == 0
    assert mask.getpixel((95, 95))[3] == 255
```

- [ ] **Step 3: Run it to confirm it fails**

```bash
cd ai-service && source .venv/bin/activate && python -m pytest tests/agents/shared/test_region_edit.py -q
```

Expected: collection error — `ModuleNotFoundError: No module named 'app.agents.shared'`.

- [ ] **Step 4: Move the code**

Create `app/agents/shared/__init__.py` (empty). Create `app/agents/shared/region_edit.py` and move — **verbatim, no rewriting** — the `BoundingBox` class from `kv_generator/request_schema.py` and the three functions from `kv_generator/service.py`, renaming only to drop the leading underscore (`_build_mask` → `build_mask`, `_polygon_pixels` → `polygon_pixels`, `_compose_clear_prompt` → `compose_clear_prompt`). Keep every docstring and comment: they record why polygons and rectangles must land on the same pixel grid.

- [ ] **Step 5: Re-export so Craft's call sites do not move**

In `app/agents/kv_generator/request_schema.py`, replace the `BoundingBox` class body with a re-export:

```python
from app.agents.shared.region_edit import BoundingBox  # noqa: F401
```

In `app/agents/kv_generator/service.py`, replace the three function bodies with thin aliases so every existing call site keeps working:

```python
from app.agents.shared.region_edit import (
    build_mask as _build_mask,
    compose_clear_prompt as _compose_clear_prompt,
    polygon_pixels as _polygon_pixels,
)
```

- [ ] **Step 6: Run the new tests and the Craft regression suite**

```bash
cd ai-service && source .venv/bin/activate
python -m pytest tests/agents/shared -q
python -m pytest tests/agents -q 2>&1 | tail -5
```

Expected: the three new tests PASS, and the full run's failure count is **identical to `/tmp/aisvc-baseline.txt`**. Any new failure means the move was not verbatim — revert and redo, do not patch over it.

- [ ] **Step 7: Commit**

```bash
git add app/agents/shared app/agents/kv_generator/request_schema.py app/agents/kv_generator/service.py tests/agents/shared
git commit -m "refactor(ai): extract region/mask primitives into a shared module"
```

---

### Task 2: `RegionEditRequest` schema

**Files:**
- Create: `app/agents/kv_resize_region_edit/__init__.py`
- Create: `app/agents/kv_resize_region_edit/request_schema.py`
- Create: `app/agents/kv_resize_region_edit/response_schema.py`
- Test: `tests/agents/kv_resize_region_edit/test_request_schema.py`

**Interfaces:**
- Consumes: `BoundingBox` from Task 1.
- Produces:
  - `RegionEditRequest` with fields `export_id: str`, `source_image_url: str`, `target_width: int` (gt=0), `target_height: int` (gt=0), `bounding_boxes: List[BoundingBox]` (min_length=1).
  - `RegionEditAccepted` with field `export_id: str`.
  - `MAX_ASPECT_RATIO: float = 3.0` — the gpt-image-2 ceiling, exported for the service and its tests.

- [ ] **Step 1: Write the failing test**

Create `tests/agents/kv_resize_region_edit/__init__.py` (empty) and `test_request_schema.py`:

```python
import pytest
from pydantic import ValidationError

from app.agents.kv_resize_region_edit.request_schema import RegionEditRequest


def _payload(**over):
    base = {
        "export_id": "exp-1",
        "source_image_url": "https://example.test/tile.png",
        "target_width": 1080,
        "target_height": 1920,
        "bounding_boxes": [
            {"id": "b1", "x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2}
        ],
    }
    base.update(over)
    return base


def test_accepts_a_minimal_payload():
    req = RegionEditRequest(**_payload())
    assert req.bounding_boxes[0].id == "b1"


def test_rejects_an_empty_box_list():
    with pytest.raises(ValidationError):
        RegionEditRequest(**_payload(bounding_boxes=[]))


def test_rejects_non_positive_dimensions():
    with pytest.raises(ValidationError):
        RegionEditRequest(**_payload(target_width=0))
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
cd ai-service && source .venv/bin/activate && python -m pytest tests/agents/kv_resize_region_edit/test_request_schema.py -q
```

Expected: `ModuleNotFoundError: No module named 'app.agents.kv_resize_region_edit'`.

- [ ] **Step 3: Implement**

`app/agents/kv_resize_region_edit/__init__.py` — empty.

`app/agents/kv_resize_region_edit/request_schema.py`:

```python
from typing import List

from pydantic import BaseModel, Field

from app.agents.shared.region_edit import BoundingBox

# gpt-image-2 accepts an explicit "WxH" pixel size only up to 3:1. Past that
# the provider cannot honour the tile's dimensions, so the service fails
# closed rather than returning a distorted tile.
MAX_ASPECT_RATIO: float = 3.0


class RegionEditRequest(BaseModel):
    export_id: str
    source_image_url: str
    target_width: int = Field(gt=0)
    target_height: int = Field(gt=0)
    bounding_boxes: List[BoundingBox] = Field(min_length=1)
```

`app/agents/kv_resize_region_edit/response_schema.py`:

```python
from pydantic import BaseModel


class RegionEditAccepted(BaseModel):
    export_id: str
```

- [ ] **Step 4: Run the tests**

```bash
cd ai-service && source .venv/bin/activate && python -m pytest tests/agents/kv_resize_region_edit -q
```

Expected: 3 passed.

- [ ] **Step 5: Commit**

```bash
git add app/agents/kv_resize_region_edit tests/agents/kv_resize_region_edit
git commit -m "feat(ai): region-edit request/response schemas for resize tiles"
```

---

### Task 3: The aspect-ratio guard

**Files:**
- Create: `app/agents/kv_resize_region_edit/service.py`
- Test: `tests/agents/kv_resize_region_edit/test_service.py`

**Interfaces:**
- Consumes: `RegionEditRequest`, `MAX_ASPECT_RATIO` (Task 2).
- Produces: `aspect_ratio_error(width: int, height: int) -> Optional[str]` — returns a user-facing message when the tile is at or past 3:1, else `None`.

Built as its own task because it is the one behaviour the spec flags as unverified, and it must be provable without a network call.

- [ ] **Step 1: Write the failing test**

Append to `tests/agents/kv_resize_region_edit/test_service.py`:

```python
from app.agents.kv_resize_region_edit.service import aspect_ratio_error


def test_ordinary_tile_ratios_pass():
    assert aspect_ratio_error(1080, 1920) is None   # Story, 0.5625:1
    assert aspect_ratio_error(1080, 1080) is None   # square
    assert aspect_ratio_error(1250, 463) is None    # FB video cover, 2.7:1


def test_three_to_one_and_beyond_is_refused():
    # x-header is exactly 3:1 — the documented ceiling, so it is refused.
    assert aspect_ratio_error(1500, 500) is not None
    assert aspect_ratio_error(500, 1500) is not None
    assert "3:1" in aspect_ratio_error(1500, 500)
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
cd ai-service && source .venv/bin/activate && python -m pytest tests/agents/kv_resize_region_edit/test_service.py -q
```

Expected: `ImportError: cannot import name 'aspect_ratio_error'`.

- [ ] **Step 3: Implement**

```python
from typing import Optional

from app.agents.kv_resize_region_edit.request_schema import MAX_ASPECT_RATIO


def aspect_ratio_error(width: int, height: int) -> Optional[str]:
    """Refuse tiles the image model cannot render at their own dimensions.

    gpt-image-2 honours an explicit pixel size only up to 3:1. Past that it
    returns something else, and silently resampling a distorted result back
    onto the tile is worse than saying no.
    """
    longer, shorter = max(width, height), min(width, height)
    if shorter <= 0 or longer / shorter >= MAX_ASPECT_RATIO:
        return (
            "Region edits are unavailable for this size: the image model "
            "supports up to 3:1, and this tile is wider than that."
        )
    return None
```

- [ ] **Step 4: Run the tests**

```bash
cd ai-service && source .venv/bin/activate && python -m pytest tests/agents/kv_resize_region_edit -q
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add app/agents/kv_resize_region_edit/service.py tests/agents/kv_resize_region_edit/test_service.py
git commit -m "feat(ai): refuse region edits past the 3:1 model ceiling"
```

---

### Task 4: `process_region_edit` — download, probe, mask, edit, callback

**Files:**
- Modify: `app/agents/kv_resize_region_edit/service.py`
- Test: `tests/agents/kv_resize_region_edit/test_service.py`

**Interfaces:**
- Consumes: `build_mask`, `compose_clear_prompt` (Task 1); `RegionEditRequest` (Task 2); `aspect_ratio_error` (Task 3); `post_completed` from `app.agents.kv_resize.api_client`; `save_bytes_to_file` from `app.tools.edit_image`.
- Produces: `process_region_edit(req: RegionEditRequest) -> None`.

- [ ] **Step 1: Write the failing test**

Append to `tests/agents/kv_resize_region_edit/test_service.py`:

```python
import io
from unittest.mock import patch

from PIL import Image

from app.agents.kv_resize_region_edit import service as svc
from app.agents.kv_resize_region_edit.request_schema import RegionEditRequest


def _req(**over):
    base = {
        "export_id": "exp-1",
        "source_image_url": "https://example.test/tile.png",
        "target_width": 1080,
        "target_height": 1920,
        "bounding_boxes": [
            {"id": "b1", "x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2,
             "prompt": "remove the smudge"}
        ],
    }
    base.update(over)
    return RegionEditRequest(**base)


def _png(w, h):
    buf = io.BytesIO()
    Image.new("RGB", (w, h), "white").save(buf, format="PNG")
    return buf.getvalue()


def test_mask_is_built_at_the_probed_size_not_the_requested_one():
    """The tile row may disagree with the stored pixels; the mask must follow
    the pixels, or OpenAI rejects the pair."""
    seen = {}

    def fake_build_mask(boxes, width, height):
        seen["size"] = (width, height)
        return _png(width, height)

    with patch.object(svc, "_download_bytes", return_value=_png(900, 1600)), \
         patch.object(svc, "build_mask", side_effect=fake_build_mask), \
         patch.object(svc, "perform_image_editing",
                      return_value={"image_url": "https://cdn.test/out.png"}), \
         patch.object(svc, "post_completed") as done:
        svc.process_region_edit(_req())

    assert seen["size"] == (900, 1600)
    assert done.call_args.kwargs["status"] == "done"


def test_aspect_guard_fails_the_export_without_calling_the_model():
    with patch.object(svc, "_download_bytes") as dl, \
         patch.object(svc, "perform_image_editing") as edit, \
         patch.object(svc, "post_completed") as done:
        svc.process_region_edit(_req(target_width=1500, target_height=500))

    dl.assert_not_called()
    edit.assert_not_called()
    assert done.call_args.kwargs["status"] == "failed"
    assert "3:1" in done.call_args.kwargs["error_message"]


def test_a_failure_reports_failed_rather_than_raising():
    with patch.object(svc, "_download_bytes", side_effect=RuntimeError("boom")), \
         patch.object(svc, "post_completed") as done:
        svc.process_region_edit(_req())

    assert done.call_args.kwargs["status"] == "failed"
    assert "boom" in done.call_args.kwargs["error_message"]
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
cd ai-service && source .venv/bin/activate && python -m pytest tests/agents/kv_resize_region_edit/test_service.py -q
```

Expected: `AttributeError: module ... has no attribute 'process_region_edit'`.

- [ ] **Step 3: Implement**

Add to `app/agents/kv_resize_region_edit/service.py`:

```python
import io
import tempfile
from typing import Any, Dict, Optional
from uuid import uuid4

import requests
from PIL import Image

from app.agents.kv_resize.api_client import post_completed
from app.agents.kv_resize_region_edit.request_schema import RegionEditRequest
from app.agents.shared.region_edit import build_mask, compose_clear_prompt
from app.services.image_editing import EditImageDto, perform_image_editing
from app.tools.edit_image import save_bytes_to_file
from app.utils.config import settings

# Masks are only supported by OpenAI's images/edits endpoint. Pinned here
# rather than inherited from the tile's original resize, which may have run
# on the outpaint path with a different provider.
_EDIT_PROVIDER = "openai"
_EDIT_MODEL = "gpt-image-2"


def _download_bytes(url: str) -> bytes:
    resp = requests.get(url, timeout=60)
    resp.raise_for_status()
    return resp.content


def process_region_edit(req: RegionEditRequest) -> None:
    token_usage: Dict[str, Any] = {}
    ai_service_run_id: Optional[str] = None

    guard = aspect_ratio_error(req.target_width, req.target_height)
    if guard:
        post_completed(export_id=req.export_id, status="failed", error_message=guard)
        return

    try:
        source_bytes = _download_bytes(req.source_image_url)
        with Image.open(io.BytesIO(source_bytes)) as im:
            src_w, src_h = im.size

        # Match the mask to the PIXELS, not to the row's width/height. OpenAI
        # rejects a mask whose dimensions differ from the image it edits.
        mask_bytes = build_mask(req.bounding_boxes, width=src_w, height=src_h)

        tmp_dir = tempfile.mkdtemp(prefix="kv_resize_region_")
        dto = EditImageDto(
            action="edit",
            refined_prompt=compose_clear_prompt(req.bounding_boxes),
            image_context="",
            image_model_provider=_EDIT_PROVIDER,
            image_model=_EDIT_MODEL,
            images=[req.source_image_url],
            temp_folder_path=tmp_dir,
            # No aspect_ratio: edit_image skips `size` whenever a mask is
            # present, and the output inherits the mask's dimensions.
        )
        result = perform_image_editing(dto, mask_bytes=mask_bytes)
        ai_service_run_id = str(uuid4())
        token_usage = result.get("token_usage") or {}

        image_bytes = _download_bytes(result["image_url"])
        image_url = save_bytes_to_file(
            image_bytes=image_bytes,
            temp_folder_path=tmp_dir,
            destination_path=f"{settings.API_ENV}/kv-resize-exports/{req.export_id}",
            file_name=f"{uuid4()}.png",
        )

        post_completed(
            export_id=req.export_id,
            status="done",
            image_url=image_url,
            token_usage=token_usage or None,
            ai_service_run_id=ai_service_run_id,
            model=_EDIT_MODEL,
        )
    except Exception as exc:  # noqa: BLE001
        post_completed(
            export_id=req.export_id,
            status="failed",
            error_message=str(exc),
        )
```

- [ ] **Step 4: Thread `mask_bytes` through `perform_image_editing`**

`perform_image_editing` currently takes only the DTO. `edit_image` already reads `mask_bytes` from `**kwargs` (see `edit_image.py:145-152`). Widen the wrapper in `app/services/image_editing.py`:

```python
def perform_image_editing(args: EditImageDto, **kwargs):
    result = edit_image(**args.model_dump(), **kwargs)

    return result
```

This is additive — every existing call site passes no kwargs and is unaffected.

- [ ] **Step 5: Run the tests**

```bash
cd ai-service && source .venv/bin/activate && python -m pytest tests/agents/kv_resize_region_edit -q
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add app/agents/kv_resize_region_edit/service.py app/services/image_editing.py tests/agents/kv_resize_region_edit/test_service.py
git commit -m "feat(ai): region-edit pipeline for resize tiles"
```

---

### Task 5: Router + registration

**Files:**
- Create: `app/agents/kv_resize_region_edit/router.py`
- Modify: `main.py`
- Test: `tests/agents/kv_resize_region_edit/test_router.py`

**Interfaces:**
- Consumes: `process_region_edit` (Task 4), `RegionEditRequest` / `RegionEditAccepted` (Task 2).
- Produces: `POST /ai/kv-resize-region-edit/edit` → `202` with `{"export_id": ...}`.

- [ ] **Step 1: Write the failing test**

Model it on the existing `tests/agents/kv_resize/test_router.py`. Create `tests/agents/kv_resize_region_edit/test_router.py`:

```python
from unittest.mock import patch

from fastapi.testclient import TestClient

from main import app

client = TestClient(app)

PAYLOAD = {
    "export_id": "exp-1",
    "source_image_url": "https://example.test/tile.png",
    "target_width": 1080,
    "target_height": 1920,
    "bounding_boxes": [
        {"id": "b1", "x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2}
    ],
}


def test_accepts_and_schedules_the_edit():
    with patch("app.agents.kv_resize_region_edit.router.process_region_edit") as job:
        res = client.post("/ai/kv-resize-region-edit/edit", json=PAYLOAD)

    assert res.status_code == 202
    assert res.json()["export_id"] == "exp-1"
    job.assert_called_once()


def test_rejects_an_empty_box_list():
    bad = {**PAYLOAD, "bounding_boxes": []}
    assert client.post("/ai/kv-resize-region-edit/edit", json=bad).status_code == 422
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
cd ai-service && source .venv/bin/activate && python -m pytest tests/agents/kv_resize_region_edit/test_router.py -q
```

Expected: 404 on both, because the route is not registered.

- [ ] **Step 3: Implement**

`app/agents/kv_resize_region_edit/router.py`:

```python
from fastapi import APIRouter, BackgroundTasks
from fastapi.responses import JSONResponse

from app.agents.kv_resize_region_edit.request_schema import RegionEditRequest
from app.agents.kv_resize_region_edit.response_schema import RegionEditAccepted
from app.agents.kv_resize_region_edit.service import process_region_edit

router = APIRouter(prefix="/ai/kv-resize-region-edit", tags=["kv-resize-region-edit"])


@router.post("/edit", response_model=RegionEditAccepted, status_code=202)
def edit(req: RegionEditRequest, background: BackgroundTasks):
    background.add_task(process_region_edit, req)
    return JSONResponse(
        status_code=202,
        content=RegionEditAccepted(export_id=req.export_id).model_dump(),
    )
```

Register it in `main.py` next to the existing `kv_resize` router, following whatever import/include style that file already uses.

- [ ] **Step 4: Run the tests**

```bash
cd ai-service && source .venv/bin/activate && python -m pytest tests/agents/kv_resize_region_edit -q
```

Expected: all pass.

- [ ] **Step 5: Full-suite regression check**

```bash
cd ai-service && source .venv/bin/activate && python -m pytest tests/agents -q 2>&1 | tail -5
```

Expected: failure count identical to `/tmp/aisvc-baseline.txt`, pass count higher.

- [ ] **Step 6: Commit**

```bash
git add app/agents/kv_resize_region_edit/router.py main.py tests/agents/kv_resize_region_edit/test_router.py
git commit -m "feat(ai): mount the resize region-edit route"
```

---

## Done when

- `POST /ai/kv-resize-region-edit/edit` returns 202 and schedules the job.
- The mask is built at the probed pixel size, so a 1080×1920 tile returns 1080×1920.
- A tile at or past 3:1 fails closed with a message naming the limit, and never reaches the model.
- Craft's `kv_generator` suite shows no new failures against the recorded baseline.
