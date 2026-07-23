# KV Magic Layers — ai-service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Async decomposition pipeline: given an uploaded image URL, detect subjects + text blocks, produce alpha-matted subject cutouts and text rect cutouts, inpaint the holes into a clean background, and POST results (S3 URLs + normalized geometry + usage) back to the Laravel API.

**Architecture:** New module `app/agents/kv_magic_layer/` mirroring `app/agents/kv_resize/` (router → 202 → `BackgroundTasks` → orchestrator → internal callback). Detection is a Lane A Agno agent (`output_schema`); segmentation goes through the sanctioned Replicate chokepoint (`run_with_retry`, Lane X carve-out #2); inpaint reuses `app/tools/outpaint_image.py::outpaint` (Lane X carve-out #1). All stage outputs upload to S3 via `save_bytes_to_file`; the callback carries URLs, never bytes.

**Tech Stack:** FastAPI, Agno 2.6.20 (`VendorChat` + `output_schema`), Replicate (`meta/sam-2` automatic mask generation), OpenAI `gpt-image-2` `/v1/images/edits`, Pillow + numpy + opencv (all already in requirements), pytest.

## Global Constraints

- Branch: `feature/daffa/vc-kv-magic-layers` cut from `origin/development`. Setup: `git fetch origin && git checkout -b feature/daffa/vc-kv-magic-layers origin/development` (run inside `ai-service/`).
- Spec: `docs/superpowers/specs/2026-07-23-kv-magic-layers-design.md` (workspace root repo).
- Layer caps (spec): max **8** subjects (largest first), max **12** total layers, min box area **1%** of frame, merge subject boxes at **≥ 0.70 IoU**, skip subjects covering **> 90%** of frame.
- Agno traps that apply here (from `llm-patterns`): guard `run.status == RunStatus.error`; guard `isinstance(run.content, Schema)`; build the model with `VendorChat` from `app/observability/agno_models.py` (never `OpenAIChat` directly — `$ai_provider` mangling).
- Tracing (from `ai-tracing`): the detection agent carries `post_hooks=tracing_post_hooks(feature="kv_magic_layer")`; Replicate is already captured inside `run_with_retry`; `outpaint` already captures its own usage. The job request must carry `user_id` / `workspace_id` / `user_email` so contextvars attribute the background work (they propagate from the scheduling request into `BackgroundTasks`).
- Callback contract (consumed by the api plan — field names are load-bearing):
  `POST {API_INTERNAL_URL}/api/v1/internal/kv-magic-layer-jobs/completed` with header `X-Internal-Token`, JSON body:
  ```json
  {
    "job_id": "…",
    "status": "done | failed",
    "error_message": "only when failed",
    "background_url": "S3 URL, only when done",
    "layers": [{"kind": "subject|text", "label": "person", "image_url": "S3 URL",
                 "x": 0.1, "y": 0.2, "width": 0.3, "height": 0.4, "z": 1}],
    "ai_service_run_id": "uuid4",
    "usage_entries": [{"stage": "detect|segment|inpaint", "model": "…", "token_usage": {}}]
  }
  ```
  Geometry is normalized `[0,1]` relative to the source image, matching `StudioOverlay` conventions. `error_message: "no_layers_detected"` is the sentinel for the nothing-to-separate case (api treats it as fallback-not-error and does not charge).
- All commits on the feature branch, conventional format `feat(ai): …` / `test(ai): …`.

---

### Task 1: Request/response schemas

**Files:**
- Create: `app/agents/kv_magic_layer/__init__.py` (empty)
- Create: `app/agents/kv_magic_layer/request_schema.py`
- Create: `app/agents/kv_magic_layer/response_schema.py`
- Test: `tests/agents/kv_magic_layer/__init__.py` (empty), `tests/agents/kv_magic_layer/test_request_schema.py`

**Interfaces:**
- Produces: `MagicLayerJobRequest(job_id, source_image_url, user_id?, workspace_id?, user_email?, brand_id?)`, `MagicLayerJobAccepted(job_id, status="accepted")`. Consumed by Tasks 2 and 8.

- [ ] **Step 1: Write the failing test**

```python
# tests/agents/kv_magic_layer/test_request_schema.py
import pytest
from pydantic import ValidationError

from app.agents.kv_magic_layer.request_schema import MagicLayerJobRequest
from app.agents.kv_magic_layer.response_schema import MagicLayerJobAccepted


def test_request_minimal_fields():
    req = MagicLayerJobRequest(job_id="job-1", source_image_url="https://cdn/x.png")
    assert req.job_id == "job-1"
    assert req.user_id is None


def test_request_rejects_missing_source():
    with pytest.raises(ValidationError):
        MagicLayerJobRequest(job_id="job-1")


def test_accepted_defaults_status():
    body = MagicLayerJobAccepted(job_id="job-1").model_dump()
    assert body == {"job_id": "job-1", "status": "accepted"}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/agents/kv_magic_layer/test_request_schema.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'app.agents.kv_magic_layer'`

- [ ] **Step 3: Write the schemas**

```python
# app/agents/kv_magic_layer/request_schema.py
from typing import Optional

from pydantic import BaseModel


class MagicLayerJobRequest(BaseModel):
    job_id: str
    source_image_url: str
    # Identity for PostHog attribution (bind_ai_context reads these from the body).
    user_id: Optional[str] = None
    workspace_id: Optional[str] = None
    user_email: Optional[str] = None
    brand_id: Optional[str] = None
```

```python
# app/agents/kv_magic_layer/response_schema.py
from pydantic import BaseModel


class MagicLayerJobAccepted(BaseModel):
    job_id: str
    status: str = "accepted"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/agents/kv_magic_layer/test_request_schema.py -v`
Expected: 3 PASS

- [ ] **Step 5: Commit**

```bash
git add app/agents/kv_magic_layer tests/agents/kv_magic_layer
git commit -m "feat(ai): kv_magic_layer request/response schemas"
```

---

### Task 2: Router + registration

**Files:**
- Create: `app/agents/kv_magic_layer/router.py`
- Modify: `main.py` (import near line 19–22, `include_router` near line 112–115)
- Test: `tests/agents/kv_magic_layer/test_router.py`

**Interfaces:**
- Consumes: Task 1 schemas; `process_magic_layer_job(req)` from Task 8 (stub it now).
- Produces: `POST /ai/kv-magic-layer/jobs` → 202 `{"job_id", "status": "accepted"}`.

- [ ] **Step 1: Write the failing test**

```python
# tests/agents/kv_magic_layer/test_router.py
from unittest.mock import patch

from fastapi.testclient import TestClient

from main import app

client = TestClient(app)


@patch("app.agents.kv_magic_layer.router.process_magic_layer_job")
def test_jobs_accepts_and_schedules(mock_process):
    resp = client.post(
        "/ai/kv-magic-layer/jobs",
        json={"job_id": "job-1", "source_image_url": "https://cdn/x.png"},
    )
    assert resp.status_code == 202
    assert resp.json() == {"job_id": "job-1", "status": "accepted"}
    mock_process.assert_called_once()


def test_jobs_rejects_missing_source():
    resp = client.post("/ai/kv-magic-layer/jobs", json={"job_id": "job-1"})
    assert resp.status_code == 422
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/agents/kv_magic_layer/test_router.py -v`
Expected: FAIL (`ModuleNotFoundError` for `router`)

- [ ] **Step 3: Write router + stub service + register**

```python
# app/agents/kv_magic_layer/router.py
from fastapi import APIRouter, BackgroundTasks
from fastapi.responses import JSONResponse

from app.agents.kv_magic_layer.request_schema import MagicLayerJobRequest
from app.agents.kv_magic_layer.response_schema import MagicLayerJobAccepted
from app.agents.kv_magic_layer.service import process_magic_layer_job

router = APIRouter(prefix="/ai/kv-magic-layer", tags=["kv-magic-layer"])


@router.post("/jobs", response_model=MagicLayerJobAccepted, status_code=202)
def create_job(req: MagicLayerJobRequest, background: BackgroundTasks):
    background.add_task(process_magic_layer_job, req)
    return JSONResponse(
        status_code=202,
        content=MagicLayerJobAccepted(job_id=req.job_id).model_dump(),
    )
```

```python
# app/agents/kv_magic_layer/service.py  (stub — fully implemented in Task 8)
from app.agents.kv_magic_layer.request_schema import MagicLayerJobRequest


def process_magic_layer_job(req: MagicLayerJobRequest) -> None:
    raise NotImplementedError
```

In `main.py`, next to the other KV routers:

```python
from app.agents.kv_magic_layer.router import router as kv_magic_layer_router
...
app.include_router(kv_magic_layer_router)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/agents/kv_magic_layer/test_router.py -v`
Expected: 2 PASS (the background task is mocked, so the stub never runs)

- [ ] **Step 5: Commit**

```bash
git add app/agents/kv_magic_layer main.py tests/agents/kv_magic_layer/test_router.py
git commit -m "feat(ai): kv-magic-layer jobs route (202 + background task)"
```

---

### Task 3: Detection agent (Lane A) + guardrails

**Files:**
- Create: `app/agents/kv_magic_layer/detection.py`
- Test: `tests/agents/kv_magic_layer/test_detection.py`

**Interfaces:**
- Produces (consumed by Task 8):
  - `class DetectedBox(BaseModel)`: `label: str`, `x, y: float [0,1]`, `w, h: float (0,1]`
  - `class MagicLayerDetection(BaseModel)`: `subjects: list[DetectedBox]`, `text_blocks: list[DetectedBox]`
  - `detect_layers(source_image_url: str) -> tuple[MagicLayerDetection, dict]` — runs the agent, raises `RuntimeError` on run error / unstructured content, returns `(detection, token_usage)` where `token_usage = {"input_text_tokens": int, "output_text_tokens": int}`
  - `apply_guardrails(detection: MagicLayerDetection) -> MagicLayerDetection` — pure function enforcing caps/merges

- [ ] **Step 1: Write the failing tests (guardrails are pure — test them hard)**

```python
# tests/agents/kv_magic_layer/test_detection.py
from unittest.mock import MagicMock, patch

import pytest

from app.agents.kv_magic_layer.detection import (
    DetectedBox,
    MagicLayerDetection,
    apply_guardrails,
    detect_layers,
)


def _box(x=0.1, y=0.1, w=0.2, h=0.2, label="thing"):
    return DetectedBox(label=label, x=x, y=y, w=w, h=h)


def test_guardrails_caps_subjects_at_8_largest_first():
    subjects = [_box(x=0.0, y=0.0, w=0.05 + i * 0.01, h=0.5, label=f"s{i}") for i in range(10)]
    out = apply_guardrails(MagicLayerDetection(subjects=subjects, text_blocks=[]))
    assert len(out.subjects) == 8
    areas = [b.w * b.h for b in out.subjects]
    assert areas == sorted(areas, reverse=True)


def test_guardrails_drops_tiny_and_frame_filling_boxes():
    subjects = [
        _box(w=0.05, h=0.05),          # 0.25% area -> dropped (< 1%)
        _box(x=0.0, y=0.0, w=0.96, h=0.96),  # ~92% area -> dropped (> 90%)
        _box(w=0.3, h=0.3),            # kept
    ]
    out = apply_guardrails(MagicLayerDetection(subjects=subjects, text_blocks=[]))
    assert len(out.subjects) == 1
    assert out.subjects[0].w == pytest.approx(0.3)


def test_guardrails_merges_high_iou_subjects():
    a = _box(x=0.10, y=0.10, w=0.40, h=0.40, label="a")
    b = _box(x=0.12, y=0.12, w=0.40, h=0.40, label="b")  # IoU ~0.85 with a
    out = apply_guardrails(MagicLayerDetection(subjects=[a, b], text_blocks=[]))
    assert len(out.subjects) == 1
    merged = out.subjects[0]
    assert merged.x == pytest.approx(0.10)
    assert merged.x + merged.w == pytest.approx(0.52)


def test_guardrails_merges_touching_text_and_caps_total_layers():
    t1 = _box(x=0.10, y=0.10, w=0.20, h=0.05, label="text")
    t2 = _box(x=0.10, y=0.16, w=0.20, h=0.05, label="text")  # within merge gap of t1
    far = _box(x=0.70, y=0.80, w=0.20, h=0.05, label="text")
    subjects = [_box(x=0.0, y=(0.08 * i), w=0.3, h=0.07, label=f"s{i}") for i in range(8)]
    out = apply_guardrails(
        MagicLayerDetection(subjects=subjects, text_blocks=[t1, t2, far])
    )
    assert len(out.subjects) == 8
    # t1+t2 merged into one; total layers capped at 12 -> at most 4 text blocks survive
    assert len(out.text_blocks) <= 4
    assert any(b.h > 0.10 for b in out.text_blocks)  # the merged block spans both


def test_detect_layers_raises_on_error_run():
    fake_run = MagicMock(status="error_sentinel", content="Connection error.")
    with patch("app.agents.kv_magic_layer.detection.detection_agent") as agent, patch(
        "app.agents.kv_magic_layer.detection.RunStatus"
    ) as rs:
        rs.error = "error_sentinel"
        agent.run.return_value = fake_run
        with pytest.raises(RuntimeError):
            detect_layers("https://cdn/x.png")


def test_detect_layers_raises_on_unstructured_content():
    fake_run = MagicMock(status="completed", content="not a model")
    with patch("app.agents.kv_magic_layer.detection.detection_agent") as agent:
        agent.run.return_value = fake_run
        with pytest.raises(RuntimeError):
            detect_layers("https://cdn/x.png")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest tests/agents/kv_magic_layer/test_detection.py -v`
Expected: FAIL with `ModuleNotFoundError` for `detection`

- [ ] **Step 3: Implement detection.py**

```python
# app/agents/kv_magic_layer/detection.py
"""Lane A detection agent: subjects + text blocks with normalized bboxes."""
from typing import Optional

from agno.agent import Agent
from agno.media import Image as AgnoImage
from agno.run.base import RunStatus
from pydantic import BaseModel, Field

from app.observability.agno_models import VendorChat
from app.observability.agno_tracing import tracing_post_hooks

MAX_SUBJECTS = 8
MAX_LAYERS = 12
MIN_AREA_FRACTION = 0.01
MAX_SUBJECT_AREA_FRACTION = 0.90
MERGE_IOU = 0.70
TEXT_MERGE_GAP = 0.02  # normalized gap within which adjacent text blocks merge


class DetectedBox(BaseModel):
    label: str = Field(max_length=60)
    x: float = Field(ge=0.0, le=1.0)
    y: float = Field(ge=0.0, le=1.0)
    w: float = Field(gt=0.0, le=1.0)
    h: float = Field(gt=0.0, le=1.0)


class MagicLayerDetection(BaseModel):
    subjects: list[DetectedBox] = Field(default_factory=list)
    text_blocks: list[DetectedBox] = Field(default_factory=list)


_SYSTEM_PROMPT = """You analyze a marketing/creative image so it can be decomposed into layers.

Identify:
- subjects: each visually distinct foreground element (person, product, mascot,
  logo mark, prop). One box per element; a logo lockup is ONE subject. Exclude
  the background scene itself.
- text_blocks: each block of rendered text (headline, tagline, CTA, fine print).
  One box per visually contiguous block.

All coordinates are normalized to [0,1] relative to the image: x,y is the top-left
corner, w,h the box size. Boxes must fit the element tightly with a small margin.
If the image is a plain photo with no separable foreground, return empty lists."""

detection_agent = Agent(
    name="kv-magic-layer-detect",
    model=VendorChat(id="gpt-4o-mini", temperature=0),
    instructions=_SYSTEM_PROMPT,
    output_schema=MagicLayerDetection,
    post_hooks=tracing_post_hooks(feature="kv_magic_layer"),
)


def detect_layers(source_image_url: str) -> tuple[MagicLayerDetection, dict]:
    run = detection_agent.run(
        input="Detect the subjects and text blocks in this image.",
        images=[AgnoImage(url=source_image_url)],
    )
    if run.status == RunStatus.error:
        raise RuntimeError(f"magic-layer detection failed: {run.content}")
    if not isinstance(run.content, MagicLayerDetection):
        raise RuntimeError("magic-layer detection returned unstructured content")
    return run.content, _token_usage(run)


def _token_usage(run) -> dict:
    metrics = getattr(run, "metrics", None)
    return {
        "input_text_tokens": int(getattr(metrics, "input_tokens", 0) or 0),
        "output_text_tokens": int(getattr(metrics, "output_tokens", 0) or 0),
    }


# ---------- guardrails (pure) ----------

def _area(b: DetectedBox) -> float:
    return b.w * b.h


def _iou(a: DetectedBox, b: DetectedBox) -> float:
    ix = max(0.0, min(a.x + a.w, b.x + b.w) - max(a.x, b.x))
    iy = max(0.0, min(a.y + a.h, b.y + b.h) - max(a.y, b.y))
    inter = ix * iy
    union = _area(a) + _area(b) - inter
    return inter / union if union > 0 else 0.0


def _union_box(a: DetectedBox, b: DetectedBox) -> DetectedBox:
    x1, y1 = min(a.x, b.x), min(a.y, b.y)
    x2 = max(a.x + a.w, b.x + b.w)
    y2 = max(a.y + a.h, b.y + b.h)
    return DetectedBox(
        label=a.label, x=x1, y=y1, w=min(x2 - x1, 1.0 - x1), h=min(y2 - y1, 1.0 - y1)
    )


def _expanded_intersects(a: DetectedBox, b: DetectedBox, gap: float) -> bool:
    return not (
        a.x + a.w + gap < b.x
        or b.x + b.w + gap < a.x
        or a.y + a.h + gap < b.y
        or b.y + b.h + gap < a.y
    )


def _merge_all(boxes: list[DetectedBox], should_merge) -> list[DetectedBox]:
    merged = list(boxes)
    changed = True
    while changed:
        changed = False
        for i in range(len(merged)):
            for j in range(i + 1, len(merged)):
                if should_merge(merged[i], merged[j]):
                    merged[i] = _union_box(merged[i], merged[j])
                    merged.pop(j)
                    changed = True
                    break
            if changed:
                break
    return merged


def apply_guardrails(detection: MagicLayerDetection) -> MagicLayerDetection:
    subjects = [
        b
        for b in detection.subjects
        if MIN_AREA_FRACTION <= _area(b) <= MAX_SUBJECT_AREA_FRACTION
    ]
    subjects = _merge_all(subjects, lambda a, b: _iou(a, b) >= MERGE_IOU)
    subjects = sorted(subjects, key=_area, reverse=True)[:MAX_SUBJECTS]

    text_blocks = [b for b in detection.text_blocks if _area(b) >= MIN_AREA_FRACTION / 4]
    text_blocks = _merge_all(
        text_blocks, lambda a, b: _expanded_intersects(a, b, TEXT_MERGE_GAP)
    )
    text_blocks = sorted(text_blocks, key=_area, reverse=True)[
        : max(0, MAX_LAYERS - len(subjects))
    ]
    return MagicLayerDetection(subjects=subjects, text_blocks=text_blocks)
```

Note: text blocks use a lower min-area floor (`MIN_AREA_FRACTION / 4`) because fine print is legitimately small.

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/agents/kv_magic_layer/test_detection.py -v`
Expected: 6 PASS

- [ ] **Step 5: Commit**

```bash
git add app/agents/kv_magic_layer/detection.py tests/agents/kv_magic_layer/test_detection.py
git commit -m "feat(ai): magic-layer detection agent with guardrails"
```

---

### Task 4: Mask/geometry utilities (pure math)

**Files:**
- Create: `app/agents/kv_magic_layer/masks.py`
- Test: `tests/agents/kv_magic_layer/test_masks.py`

**Interfaces:**
- Consumes: `DetectedBox` from Task 3.
- Produces (consumed by Task 8):
  - `bbox_to_pixels(box: DetectedBox, width: int, height: int) -> tuple[int, int, int, int]` — `(left, top, right, bottom)`, clamped to image bounds
  - `match_masks_to_boxes(masks: list[np.ndarray], boxes: list[DetectedBox], width: int, height: int) -> dict[int, np.ndarray]` — box index → union bool mask; a mask is assigned to the box containing the largest share of its area, if that share ≥ 0.5
  - `clean_mask(mask: np.ndarray) -> np.ndarray` — bool in, uint8 (0/255) out; morphological close (5×5) then 2px feather via Gaussian blur
  - `cutout_from_mask(image: PIL.Image, mask_u8: np.ndarray, box_px: tuple) -> PIL.Image` — RGBA crop with mask as alpha
  - `rect_cutout(image: PIL.Image, box_px: tuple, pad_px: int = 4) -> tuple[PIL.Image, tuple]` — padded RGBA rect crop + the padded box actually used
  - `union_hole_mask(masks_u8: list[np.ndarray], rect_boxes_px: list[tuple], width: int, height: int, dilate_px: int = 8) -> PIL.Image` — L-mode mask, **white = repaint** (the convention `outpaint()` expects)

- [ ] **Step 1: Write the failing tests**

```python
# tests/agents/kv_magic_layer/test_masks.py
import numpy as np
from PIL import Image

from app.agents.kv_magic_layer.detection import DetectedBox
from app.agents.kv_magic_layer.masks import (
    bbox_to_pixels,
    clean_mask,
    cutout_from_mask,
    match_masks_to_boxes,
    rect_cutout,
    union_hole_mask,
)


def _mask(width, height, box):
    m = np.zeros((height, width), dtype=bool)
    left, top, right, bottom = box
    m[top:bottom, left:right] = True
    return m


def test_bbox_to_pixels_clamps():
    box = DetectedBox(label="s", x=0.5, y=0.5, w=0.6, h=0.6)
    assert bbox_to_pixels(box, 100, 200) == (50, 100, 100, 200)


def test_match_masks_assigns_by_containment():
    boxes = [
        DetectedBox(label="a", x=0.0, y=0.0, w=0.4, h=0.4),
        DetectedBox(label="b", x=0.6, y=0.6, w=0.4, h=0.4),
    ]
    inside_a = _mask(100, 100, (5, 5, 35, 35))
    inside_b = _mask(100, 100, (65, 65, 95, 95))
    straddling = _mask(100, 100, (0, 0, 100, 100))  # <50% in either -> unassigned
    matched = match_masks_to_boxes([inside_a, inside_b, straddling], boxes, 100, 100)
    assert set(matched.keys()) == {0, 1}
    assert matched[0][10, 10] and not matched[0][80, 80]
    assert matched[1][80, 80] and not matched[1][10, 10]


def test_match_masks_unions_multiple_masks_per_box():
    boxes = [DetectedBox(label="a", x=0.0, y=0.0, w=0.5, h=0.5)]
    m1 = _mask(100, 100, (0, 0, 20, 20))
    m2 = _mask(100, 100, (25, 25, 45, 45))
    matched = match_masks_to_boxes([m1, m2], boxes, 100, 100)
    assert matched[0][10, 10] and matched[0][30, 30]


def test_clean_mask_closes_pinholes():
    m = _mask(64, 64, (10, 10, 50, 50))
    m[30, 30] = False  # pinhole
    out = clean_mask(m)
    assert out.dtype == np.uint8
    assert out[30, 30] > 0


def test_cutout_has_transparent_outside():
    img = Image.new("RGB", (100, 100), (200, 30, 30))
    mask = clean_mask(_mask(100, 100, (10, 10, 50, 50)))
    cut = cutout_from_mask(img, mask, (10, 10, 50, 50))
    assert cut.mode == "RGBA"
    assert cut.size == (40, 40)
    assert cut.getpixel((5, 5))[3] > 0


def test_rect_cutout_pads_and_clamps():
    img = Image.new("RGB", (100, 100), (0, 0, 0))
    cut, used = rect_cutout(img, (0, 0, 30, 30), pad_px=4)
    assert used == (0, 0, 34, 34)
    assert cut.size == (34, 34)


def test_union_hole_mask_is_white_on_holes():
    subject = clean_mask(_mask(100, 100, (10, 10, 30, 30)))
    hole = union_hole_mask([subject], [(60, 60, 90, 90)], 100, 100, dilate_px=2)
    assert hole.mode == "L"
    assert hole.getpixel((20, 20)) == 255   # subject hole
    assert hole.getpixel((70, 70)) == 255   # text rect hole
    assert hole.getpixel((50, 50)) == 0     # untouched area
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest tests/agents/kv_magic_layer/test_masks.py -v`
Expected: FAIL with `ModuleNotFoundError` for `masks`

- [ ] **Step 3: Implement masks.py**

```python
# app/agents/kv_magic_layer/masks.py
"""Pure mask/geometry helpers for magic-layer decomposition."""
import cv2
import numpy as np
from PIL import Image

from app.agents.kv_magic_layer.detection import DetectedBox

ASSIGN_CONTAINMENT = 0.5  # share of a mask's area inside a box to claim it


def bbox_to_pixels(box: DetectedBox, width: int, height: int) -> tuple[int, int, int, int]:
    left = max(0, int(round(box.x * width)))
    top = max(0, int(round(box.y * height)))
    right = min(width, int(round((box.x + box.w) * width)))
    bottom = min(height, int(round((box.y + box.h) * height)))
    return left, top, right, bottom


def match_masks_to_boxes(
    masks: list[np.ndarray], boxes: list[DetectedBox], width: int, height: int
) -> dict[int, np.ndarray]:
    matched: dict[int, np.ndarray] = {}
    box_px = [bbox_to_pixels(b, width, height) for b in boxes]
    for mask in masks:
        area = int(mask.sum())
        if area == 0:
            continue
        best_idx, best_share = None, 0.0
        for idx, (left, top, right, bottom) in enumerate(box_px):
            share = int(mask[top:bottom, left:right].sum()) / area
            if share > best_share:
                best_idx, best_share = idx, share
        if best_idx is not None and best_share >= ASSIGN_CONTAINMENT:
            if best_idx in matched:
                matched[best_idx] = matched[best_idx] | mask
            else:
                matched[best_idx] = mask.copy()
    return matched


def clean_mask(mask: np.ndarray) -> np.ndarray:
    u8 = (mask.astype(np.uint8)) * 255
    kernel = np.ones((5, 5), np.uint8)
    closed = cv2.morphologyEx(u8, cv2.MORPH_CLOSE, kernel)
    return cv2.GaussianBlur(closed, (5, 5), sigmaX=1.0)


def cutout_from_mask(
    image: Image.Image, mask_u8: np.ndarray, box_px: tuple[int, int, int, int]
) -> Image.Image:
    left, top, right, bottom = box_px
    rgba = image.convert("RGBA")
    alpha = Image.fromarray(mask_u8, mode="L")
    rgba.putalpha(alpha)
    return rgba.crop((left, top, right, bottom))


def rect_cutout(
    image: Image.Image, box_px: tuple[int, int, int, int], pad_px: int = 4
) -> tuple[Image.Image, tuple[int, int, int, int]]:
    left, top, right, bottom = box_px
    used = (
        max(0, left - pad_px),
        max(0, top - pad_px),
        min(image.width, right + pad_px),
        min(image.height, bottom + pad_px),
    )
    return image.convert("RGBA").crop(used), used


def union_hole_mask(
    masks_u8: list[np.ndarray],
    rect_boxes_px: list[tuple[int, int, int, int]],
    width: int,
    height: int,
    dilate_px: int = 8,
) -> Image.Image:
    hole = np.zeros((height, width), dtype=np.uint8)
    for m in masks_u8:
        hole = np.maximum(hole, (m > 127).astype(np.uint8) * 255)
    for left, top, right, bottom in rect_boxes_px:
        hole[top:bottom, left:right] = 255
    if dilate_px > 0:
        kernel = np.ones((dilate_px * 2 + 1, dilate_px * 2 + 1), np.uint8)
        hole = cv2.dilate(hole, kernel)
    return Image.fromarray(hole, mode="L")
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/agents/kv_magic_layer/test_masks.py -v`
Expected: 7 PASS

- [ ] **Step 5: Commit**

```bash
git add app/agents/kv_magic_layer/masks.py tests/agents/kv_magic_layer/test_masks.py
git commit -m "feat(ai): magic-layer mask matching and hole-mask utilities"
```

---

### Task 5: Segmentation adapter (Replicate SAM-2)

**Files:**
- Create: `app/agents/kv_magic_layer/segmentation.py`
- Modify: `app/utils/config.py` (two new `Settings` fields, next to `STUDIO_KV_UPSCALE_MODEL` around line 74)
- Test: `tests/agents/kv_magic_layer/test_segmentation.py`

**Interfaces:**
- Produces (consumed by Task 8): `segment_image(image: PIL.Image) -> list[np.ndarray]` — list of bool masks at the source image's resolution. Empty list on a model round that yields no masks.
- Tracing: none to add — `run_with_retry` already fires `capture_ai_generation(provider="replicate")` at the chokepoint.

**Model note:** `meta/sam-2` on Replicate is automatic mask generation (input: `image`, `points_per_side`, `pred_iou_thresh`, `stability_score_thresh`; output: `{"combined_mask": url, "individual_masks": [urls]}`). It is an Official model, so a versionless ref works; the env pin exists for swapping to a Public model later (which would 404 without a SHA — known lesson). **At implementation time verify the live schema** with:
`curl -s -H "Authorization: Bearer $REPLICATE_API_TOKEN" https://api.replicate.com/v1/models/meta/sam-2 | python -m json.tool | head -80`
and adjust `input_params` keys if they differ.

- [ ] **Step 1: Write the failing test**

```python
# tests/agents/kv_magic_layer/test_segmentation.py
from unittest.mock import patch

import numpy as np
from PIL import Image

from app.agents.kv_magic_layer.segmentation import _segment_run_ref, segment_image


def _mask_png_bytes(width, height, box):
    arr = np.zeros((height, width), dtype=np.uint8)
    left, top, right, bottom = box
    arr[top:bottom, left:right] = 255
    import io

    buf = io.BytesIO()
    Image.fromarray(arr, mode="L").save(buf, format="PNG")
    return buf.getvalue()


@patch("app.agents.kv_magic_layer.segmentation._download_bytes")
@patch("app.agents.kv_magic_layer.segmentation.replicate_run")
def test_segment_image_returns_source_resolution_bool_masks(mock_run, mock_dl):
    mock_run.return_value = {"individual_masks": ["https://r/1.png", "https://r/2.png"]}
    # model returns masks at half resolution; adapter must upscale to source res
    mock_dl.side_effect = [
        _mask_png_bytes(50, 50, (5, 5, 20, 20)),
        _mask_png_bytes(50, 50, (30, 30, 45, 45)),
    ]
    source = Image.new("RGB", (100, 100))
    masks = segment_image(source)
    assert len(masks) == 2
    assert masks[0].shape == (100, 100)
    assert masks[0].dtype == np.bool_
    assert masks[0][20, 20] and not masks[0][80, 80]


@patch("app.agents.kv_magic_layer.segmentation.replicate_run")
def test_segment_image_empty_on_no_masks(mock_run):
    mock_run.return_value = {"individual_masks": []}
    assert segment_image(Image.new("RGB", (10, 10))) == []


def test_run_ref_appends_version_when_pinned():
    with patch("app.agents.kv_magic_layer.segmentation.settings") as s:
        s.STUDIO_KV_SEGMENT_MODEL = "meta/sam-2"
        s.STUDIO_KV_SEGMENT_MODEL_VERSION = "abc123"
        assert _segment_run_ref() == "meta/sam-2:abc123"
        s.STUDIO_KV_SEGMENT_MODEL_VERSION = ""
        assert _segment_run_ref() == "meta/sam-2"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/agents/kv_magic_layer/test_segmentation.py -v`
Expected: FAIL with `ModuleNotFoundError` for `segmentation`

- [ ] **Step 3: Implement config fields + segmentation.py**

In `app/utils/config.py`, inside `Settings`, next to the upscale model fields:

```python
STUDIO_KV_SEGMENT_MODEL: str = "meta/sam-2"
STUDIO_KV_SEGMENT_MODEL_VERSION: str = ""  # Official model: versionless OK; pin if swapping to a Public model
```

```python
# app/agents/kv_magic_layer/segmentation.py
"""Replicate SAM-2 automatic segmentation adapter (Lane X carve-out #2)."""
import io
import tempfile

import numpy as np
import requests
from PIL import Image

from app.utils.config import settings
from app.utils.replicate_client import run_with_retry as replicate_run

_SEGMENT_MAX_EDGE = 1536  # run the model on a bounded copy; masks upscale to source


def _segment_run_ref() -> str:
    version = settings.STUDIO_KV_SEGMENT_MODEL_VERSION
    if version:
        return f"{settings.STUDIO_KV_SEGMENT_MODEL}:{version}"
    return settings.STUDIO_KV_SEGMENT_MODEL


def _download_bytes(url: str) -> bytes:
    resp = requests.get(url, timeout=60)
    resp.raise_for_status()
    return resp.content


def segment_image(image: Image.Image) -> list[np.ndarray]:
    work = image.copy()
    work.thumbnail((_SEGMENT_MAX_EDGE, _SEGMENT_MAX_EDGE))
    with tempfile.NamedTemporaryFile(suffix=".png") as tmp:
        work.convert("RGB").save(tmp.name, format="PNG")
        with open(tmp.name, "rb") as fh:
            result = replicate_run(
                model_ref=_segment_run_ref(),
                input_params={
                    "image": fh,
                    "points_per_side": 32,
                    "pred_iou_thresh": 0.88,
                    "stability_score_thresh": 0.92,
                },
            )
    mask_urls = list(result.get("individual_masks") or []) if isinstance(result, dict) else []
    masks: list[np.ndarray] = []
    for url in mask_urls:
        mask_img = Image.open(io.BytesIO(_download_bytes(str(url)))).convert("L")
        if mask_img.size != image.size:
            mask_img = mask_img.resize(image.size, Image.NEAREST)
        masks.append(np.asarray(mask_img) > 127)
    return masks
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/agents/kv_magic_layer/test_segmentation.py -v`
Expected: 3 PASS

- [ ] **Step 5: Commit**

```bash
git add app/agents/kv_magic_layer/segmentation.py app/utils/config.py tests/agents/kv_magic_layer/test_segmentation.py
git commit -m "feat(ai): SAM-2 segmentation adapter with env-configured model ref"
```

---

### Task 6: Callback client

**Files:**
- Create: `app/agents/kv_magic_layer/api_client.py`
- Test: `tests/agents/kv_magic_layer/test_api_client.py`

**Interfaces:**
- Produces (consumed by Task 7): `post_completed(*, job_id, status, background_url=None, layers=None, error_message=None, usage_entries=None, ai_service_run_id=None) -> None`. Posts the Global-Constraints callback JSON via `post_internal_callback` (never raises).

- [ ] **Step 1: Write the failing test**

```python
# tests/agents/kv_magic_layer/test_api_client.py
from unittest.mock import patch

from app.agents.kv_magic_layer.api_client import post_completed


@patch("app.agents.kv_magic_layer.api_client.post_internal_callback")
def test_post_completed_done_payload(mock_post):
    layers = [
        {"kind": "subject", "label": "person", "image_url": "https://s3/c.png",
         "x": 0.1, "y": 0.2, "width": 0.3, "height": 0.4, "z": 1}
    ]
    post_completed(
        job_id="job-1",
        status="done",
        background_url="https://s3/bg.png",
        layers=layers,
        usage_entries=[{"stage": "detect", "model": "gpt-4o-mini", "token_usage": {}}],
        ai_service_run_id="run-1",
    )
    url, payload = mock_post.call_args.args[0], mock_post.call_args.args[1]
    assert url.endswith("/api/v1/internal/kv-magic-layer-jobs/completed")
    assert payload["status"] == "done"
    assert payload["background_url"] == "https://s3/bg.png"
    assert payload["layers"] == layers
    assert payload["ai_service_run_id"] == "run-1"
    assert "error_message" not in payload


@patch("app.agents.kv_magic_layer.api_client.post_internal_callback")
def test_post_completed_failed_payload_omits_results(mock_post):
    post_completed(job_id="job-1", status="failed", error_message="no_layers_detected")
    payload = mock_post.call_args.args[1]
    assert payload == {
        "job_id": "job-1",
        "status": "failed",
        "error_message": "no_layers_detected",
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/agents/kv_magic_layer/test_api_client.py -v`
Expected: FAIL with `ModuleNotFoundError` for `api_client`

- [ ] **Step 3: Implement api_client.py**

```python
# app/agents/kv_magic_layer/api_client.py
from typing import Any, Dict, List, Optional

from app.utils.config import settings
from app.utils.internal_callback import post_internal_callback


def post_completed(
    *,
    job_id: str,
    status: str,
    background_url: Optional[str] = None,
    layers: Optional[List[Dict[str, Any]]] = None,
    error_message: Optional[str] = None,
    usage_entries: Optional[List[Dict[str, Any]]] = None,
    ai_service_run_id: Optional[str] = None,
) -> None:
    url = (
        f"{settings.API_INTERNAL_URL.rstrip('/')}"
        "/api/v1/internal/kv-magic-layer-jobs/completed"
    )
    payload: Dict[str, Any] = {"job_id": job_id, "status": status}
    if background_url:
        payload["background_url"] = background_url
    if layers:
        payload["layers"] = layers
    if error_message:
        payload["error_message"] = error_message
    if usage_entries:
        payload["usage_entries"] = usage_entries
    if ai_service_run_id:
        payload["ai_service_run_id"] = ai_service_run_id
    post_internal_callback(url, payload, label="kv_magic_layer")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/agents/kv_magic_layer/test_api_client.py -v`
Expected: 2 PASS

- [ ] **Step 5: Commit**

```bash
git add app/agents/kv_magic_layer/api_client.py tests/agents/kv_magic_layer/test_api_client.py
git commit -m "feat(ai): magic-layer completion callback client"
```

---

### Task 7: Orchestrator

**Files:**
- Modify: `app/agents/kv_magic_layer/service.py` (replace the Task 2 stub)
- Test: `tests/agents/kv_magic_layer/test_service.py`

**Interfaces:**
- Consumes: everything above, plus `save_bytes_to_file` from `app.tools.edit_image` and `outpaint` from `app.tools.outpaint_image`.
- Produces: `process_magic_layer_job(req: MagicLayerJobRequest) -> None` (already wired to the router in Task 2).

**Behavior contract:**
- Success → `post_completed(status="done", background_url=…, layers=[…], usage_entries=[…], ai_service_run_id=…)`.
- Zero subjects AND zero text after guardrails → `post_completed(status="failed", error_message="no_layers_detected")` (sentinel, no exception).
- Any exception → `post_completed(status="failed", error_message=str(exc))`.
- Subjects with no matched SAM mask fall back to `rect_cutout` (still shipped as a layer).
- Inpaint runs on a copy bounded to 2048px long edge (`_INPAINT_MAX_EDGE`); the hole mask is resized alongside. Cutouts always crop the original-resolution source.
- z-order: subjects largest-area-first get `z = 1..n`, text blocks continue `z = n+1..`.

- [ ] **Step 1: Write the failing tests**

```python
# tests/agents/kv_magic_layer/test_service.py
import io
from unittest.mock import MagicMock, patch

from PIL import Image

from app.agents.kv_magic_layer.detection import DetectedBox, MagicLayerDetection
from app.agents.kv_magic_layer.request_schema import MagicLayerJobRequest
from app.agents.kv_magic_layer.service import process_magic_layer_job


def _png_response(width=200, height=100):
    buf = io.BytesIO()
    Image.new("RGB", (width, height), (120, 120, 120)).save(buf, format="PNG")
    return MagicMock(ok=True, status_code=200, content=buf.getvalue())


def _req():
    return MagicLayerJobRequest(job_id="job-1", source_image_url="https://cdn/src.png")


def _detection():
    return MagicLayerDetection(
        subjects=[DetectedBox(label="person", x=0.1, y=0.1, w=0.3, h=0.6)],
        text_blocks=[DetectedBox(label="text", x=0.6, y=0.7, w=0.3, h=0.1)],
    )


@patch("app.agents.kv_magic_layer.service.post_completed")
@patch("app.agents.kv_magic_layer.service.save_bytes_to_file", return_value="https://s3/out.png")
@patch("app.agents.kv_magic_layer.service.outpaint", return_value=(b"BG", "gpt-image-2", {"input_text_tokens": 1}))
@patch("app.agents.kv_magic_layer.service.segment_image", return_value=[])
@patch("app.agents.kv_magic_layer.service.detect_layers")
@patch("app.agents.kv_magic_layer.service.requests.get")
def test_happy_path_posts_done_with_layers(mock_get, mock_detect, mock_seg, mock_outpaint, mock_save, mock_pc):
    mock_get.return_value = _png_response()
    mock_detect.return_value = (_detection(), {"input_text_tokens": 10, "output_text_tokens": 5})
    process_magic_layer_job(_req())

    kwargs = mock_pc.call_args.kwargs
    assert kwargs["status"] == "done"
    assert kwargs["background_url"] == "https://s3/out.png"
    layers = kwargs["layers"]
    assert [l["kind"] for l in layers] == ["subject", "text"]
    assert layers[0]["z"] == 1 and layers[1]["z"] == 2
    for l in layers:
        for key in ("x", "y", "width", "height"):
            assert 0.0 <= l[key] <= 1.0
    stages = {u["stage"] for u in kwargs["usage_entries"]}
    assert stages == {"detect", "segment", "inpaint"}
    assert kwargs["ai_service_run_id"]


@patch("app.agents.kv_magic_layer.service.post_completed")
@patch("app.agents.kv_magic_layer.service.detect_layers")
@patch("app.agents.kv_magic_layer.service.requests.get")
def test_no_layers_posts_sentinel_failure(mock_get, mock_detect, mock_pc):
    mock_get.return_value = _png_response()
    mock_detect.return_value = (MagicLayerDetection(), {})
    process_magic_layer_job(_req())
    kwargs = mock_pc.call_args.kwargs
    assert kwargs["status"] == "failed"
    assert kwargs["error_message"] == "no_layers_detected"


@patch("app.agents.kv_magic_layer.service.post_completed")
@patch("app.agents.kv_magic_layer.service.requests.get", side_effect=RuntimeError("boom"))
def test_exception_posts_failed(mock_get, mock_pc):
    process_magic_layer_job(_req())
    kwargs = mock_pc.call_args.kwargs
    assert kwargs["status"] == "failed"
    assert "boom" in kwargs["error_message"]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest tests/agents/kv_magic_layer/test_service.py -v`
Expected: FAIL (`NotImplementedError` or missing names — the stub has no imports yet)

- [ ] **Step 3: Implement service.py**

```python
# app/agents/kv_magic_layer/service.py
"""Magic-layer decomposition orchestrator (runs in BackgroundTasks)."""
from io import BytesIO
from uuid import uuid4

import requests
from PIL import Image

from app.agents.kv_magic_layer.api_client import post_completed
from app.agents.kv_magic_layer.detection import apply_guardrails, detect_layers
from app.agents.kv_magic_layer.masks import (
    bbox_to_pixels,
    clean_mask,
    cutout_from_mask,
    match_masks_to_boxes,
    rect_cutout,
    union_hole_mask,
)
from app.agents.kv_magic_layer.request_schema import MagicLayerJobRequest
from app.agents.kv_magic_layer.segmentation import _segment_run_ref, segment_image
from app.tools.edit_image import save_bytes_to_file
from app.tools.outpaint_image import outpaint
from app.utils.config import settings
from app.utils.logger import log_error

_INPAINT_MAX_EDGE = 2048
_FILL_PROMPT = (
    "Remove every masked element and reconstruct the background behind it. "
    "Continue surfaces, lighting, texture and gradients seamlessly. "
    "Do not add any new objects, text or logos."
)


def _download(url: str) -> Image.Image:
    resp = requests.get(url, timeout=60)
    resp.raise_for_status()
    return Image.open(BytesIO(resp.content)).convert("RGB")


def _upload_png(image: Image.Image, job_id: str) -> str:
    buf = BytesIO()
    image.save(buf, format="PNG")
    return save_bytes_to_file(
        image_bytes=buf.getvalue(),
        temp_folder_path="./temp",
        destination_path=f"{settings.API_ENV}/kv-magic-layer/{job_id}",
        file_name=f"{uuid4()}.png",
    )


def _norm_geometry(box_px: tuple[int, int, int, int], width: int, height: int) -> dict:
    left, top, right, bottom = box_px
    return {
        "x": left / width,
        "y": top / height,
        "width": (right - left) / width,
        "height": (bottom - top) / height,
    }


def process_magic_layer_job(req: MagicLayerJobRequest) -> None:
    ai_service_run_id = str(uuid4())
    try:
        source = _download(req.source_image_url)
        width, height = source.size

        detection, detect_usage = detect_layers(req.source_image_url)
        detection = apply_guardrails(detection)
        if not detection.subjects and not detection.text_blocks:
            post_completed(
                job_id=req.job_id, status="failed", error_message="no_layers_detected"
            )
            return

        subject_masks: dict[int, "object"] = {}
        if detection.subjects:
            raw_masks = segment_image(source)
            subject_masks = match_masks_to_boxes(
                raw_masks, detection.subjects, width, height
            )

        layers: list[dict] = []
        hole_masks = []
        z = 0
        for idx, box in enumerate(detection.subjects):
            z += 1
            box_px = bbox_to_pixels(box, width, height)
            if idx in subject_masks:
                mask_u8 = clean_mask(subject_masks[idx])
                cut = cutout_from_mask(source, mask_u8, box_px)
                hole_masks.append(mask_u8)
                geometry = _norm_geometry(box_px, width, height)
            else:
                cut, used_px = rect_cutout(source, box_px)
                geometry = _norm_geometry(used_px, width, height)
            layers.append(
                {"kind": "subject", "label": box.label,
                 "image_url": _upload_png(cut, req.job_id), "z": z, **geometry}
            )

        text_rects_px = []
        for box in detection.text_blocks:
            z += 1
            box_px = bbox_to_pixels(box, width, height)
            cut, used_px = rect_cutout(source, box_px)
            text_rects_px.append(used_px)
            layers.append(
                {"kind": "text", "label": box.label,
                 "image_url": _upload_png(cut, req.job_id), "z": z,
                 **_norm_geometry(used_px, width, height)}
            )
        # rect-fallback subjects also need their rect repainted
        rect_subject_px = [
            bbox_to_pixels(detection.subjects[i], width, height)
            for i in range(len(detection.subjects))
            if i not in subject_masks
        ]

        hole = union_hole_mask(
            hole_masks, text_rects_px + rect_subject_px, width, height
        )
        inpaint_canvas = source.copy()
        inpaint_canvas.thumbnail((_INPAINT_MAX_EDGE, _INPAINT_MAX_EDGE))
        if inpaint_canvas.size != source.size:
            hole = hole.resize(inpaint_canvas.size, Image.NEAREST)
        bg_bytes, inpaint_model, inpaint_usage = outpaint(
            inpaint_canvas, hole, _FILL_PROMPT
        )
        background_url = save_bytes_to_file(
            image_bytes=bg_bytes,
            temp_folder_path="./temp",
            destination_path=f"{settings.API_ENV}/kv-magic-layer/{req.job_id}",
            file_name=f"{uuid4()}.png",
        )

        post_completed(
            job_id=req.job_id,
            status="done",
            background_url=background_url,
            layers=layers,
            usage_entries=[
                {"stage": "detect", "model": "gpt-4o-mini", "token_usage": detect_usage},
                {"stage": "segment", "model": _segment_run_ref(), "token_usage": {}},
                {"stage": "inpaint", "model": inpaint_model, "token_usage": inpaint_usage},
            ],
            ai_service_run_id=ai_service_run_id,
        )
    except Exception as exc:  # noqa: BLE001 — background task must always call back
        log_error(f"[kv_magic_layer] job {req.job_id} failed: {exc!r}")
        post_completed(job_id=req.job_id, status="failed", error_message=str(exc))
```

Note: confirm `log_error`'s import path matches what `internal_callback.py` uses (`from app.utils.logger import log_error` — adjust to the actual module if it differs; check `app/utils/internal_callback.py`'s own import).

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/agents/kv_magic_layer/ -v`
Expected: all module tests PASS (router test still passes — stub replaced by real function with same name)

- [ ] **Step 5: Run the full suite**

Run: `pytest tests/ -q`
Expected: no regressions

- [ ] **Step 6: Commit**

```bash
git add app/agents/kv_magic_layer/service.py tests/agents/kv_magic_layer/test_service.py
git commit -m "feat(ai): magic-layer decomposition orchestrator"
```

---

### Task 8: Live smoke check (manual, no CI)

**Files:** none (throwaway script in scratchpad)

- [ ] **Step 1: Verify the SAM-2 schema** (needs `REPLICATE_API_TOKEN` from `.env`):

```bash
curl -s -H "Authorization: Bearer $REPLICATE_API_TOKEN" https://api.replicate.com/v1/models/meta/sam-2 | python -m json.tool | head -80
```
Expected: model exists; input schema contains `image` and mask-generation params; adjust `segmentation.py` `input_params` if keys differ, and re-run Task 5 tests.

- [ ] **Step 2: Run one real decomposition** against a local test image uploaded anywhere public, by starting the service (`source .venv/bin/activate && fastapi dev`) and POSTing:

```bash
curl -s -X POST http://localhost:8000/ai/kv-magic-layer/jobs \
  -H 'Content-Type: application/json' \
  -d '{"job_id": "smoke-1", "source_image_url": "<public test image URL>"}'
```
Expected: 202 immediately; service logs show detect → segment → inpaint; the callback POST will 404 until the api-side endpoint exists (that error is logged, not raised) — the S3 uploads and log lines are the proof for this repo.

- [ ] **Step 3: Check PostHog LLM analytics** shows a `kv_magic_layer` trace (detect generation + replicate span + inpaint capture).

**PR note:** the PR body must include a `## Direct-SDK Justification` section: Replicate segmentation uses the sanctioned `run_with_retry` chokepoint (agno `ReplicateTools` is prompt-only, ctor-pinned); inpaint reuses `app/tools/outpaint_image.py` (agno has no `images.edit` surface). Detection itself is Lane A agno.
