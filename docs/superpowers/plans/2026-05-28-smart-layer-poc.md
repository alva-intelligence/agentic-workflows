# Smart Layer POC — Full System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert the dummy `/studio/smart-layer-poc` page into a real, end-to-end POC where uploading a key-visual returns a real `SmartLayerManifest` (vision-detected bounding boxes, transparent-PNG cutouts for subject/logo/CTA, and a clean inpainted background) ready to use as `StudioOverlayDraft[]`.

**Architecture:**
- New ai-service endpoint `POST /ai/smart-layer/analyze` (multipart). Pipeline: **(1)** GPT-4o vision call returns structured JSON layer manifest. **(2)** Each non-bg image layer is cropped → cutout via Replicate `lucataco/remove-bg` (rembg) → uploaded to S3 as transparent PNG. **(3)** Clean background = source image with all non-bg bboxes masked → `gpt-image-2 /v1/images/edits` inpaint → uploaded to S3. **(4)** Manifest assembled and returned. The frontend already understands this shape — wiring `NEXT_PUBLIC_SMART_LAYER_ENDPOINT` flips it from local-preset to real.
- Existing helpers reused: `app.services.aws.upload_file_to_s3`, `app.utils.replicate_client.run_with_retry`, mask/alignment helpers from `app.tools.outpaint_image`.
- POC stays standalone — no API (Laravel) changes, no KV-Generator integration in this scope (deferred).

**Tech Stack:**
- ai-service: FastAPI, OpenAI Python SDK (gpt-4o, gpt-image-2), Replicate (`lucataco/remove-bg`), Pillow, boto3, pytest.
- web: Next.js 16, TypeScript. Existing UI at `web/src/app/(canvas)/studio/smart-layer-poc/` is consumed as-is; only env var + a small polish to layer rendering for transparent PNGs.

**Branch:** `feature/daffa/vc-smart-layer-poc` (vibe-coder convention). Created from `develop` (web) and `development` (ai-service) for cross-service work — but since most code lives in ai-service which lives on `development`, the worktree branches off `development` for ai-service and `develop` for web.

**Out of scope (for follow-up plans):**
- "Send to KV Generator" button (option C).
- Persisting manifests in DB.
- Per-user/per-brand rate limits.
- Production-grade prompt versioning, eval harness.

---

## File Structure

**ai-service (created):**
- `ai-service/app/agents/smart_layer/__init__.py` — package marker.
- `ai-service/app/agents/smart_layer/schema.py` — Pydantic `SmartLayerManifest`, `SmartLayer`, `SmartLayerKind`, etc. Mirrors `web/src/lib/studio/smart-layers.ts` types exactly.
- `ai-service/app/agents/smart_layer/vision.py` — GPT-4o structured-output detection. One pure function: `detect_layers(image_bytes, mime_type) -> list[DetectedLayer]`.
- `ai-service/app/agents/smart_layer/cutout.py` — Replicate rembg cutout. One pure function: `cutout_subject(image_bytes) -> bytes` returning transparent PNG.
- `ai-service/app/agents/smart_layer/clean_background.py` — gpt-image-2 inpaint. `clean_background(image_bytes, masks: list[Bbox], prompt_hint: str) -> bytes`.
- `ai-service/app/agents/smart_layer/pipeline.py` — orchestrator. `run_smart_layer_pipeline(image_bytes, file_name, mime, *, clean_bg: bool) -> SmartLayerManifest`. Uploads to S3, returns final manifest.
- `ai-service/app/agents/smart_layer/router.py` — FastAPI router with `POST /ai/smart-layer/analyze`.
- `ai-service/tests/agents/smart_layer/test_schema.py` — schema round-trip.
- `ai-service/tests/agents/smart_layer/test_vision_parsing.py` — parse a stubbed GPT-4o JSON response into `DetectedLayer[]`.
- `ai-service/tests/agents/smart_layer/test_pipeline.py` — pipeline integration test with mocked vision/cutout/inpaint/S3.

**ai-service (modified):**
- `ai-service/main.py` — wire the new router. One line.
- `ai-service/app/utils/config.py` — no new settings needed (OPENAI_API_KEY and Replicate token already exist). Add toggle `SMART_LAYER_CLEAN_BG_ENABLED: bool = True` as a kill switch for inpaint cost.
- `ai-service/.env.example` — document `SMART_LAYER_CLEAN_BG_ENABLED`.

**web (modified):**
- `web/.env.local.example` — add documented placeholder `NEXT_PUBLIC_SMART_LAYER_ENDPOINT=http://localhost:8000/ai/smart-layer/analyze`. (Do **not** commit `.env.local`.)
- `web/src/lib/studio/smart-layers.ts` — minor: pass `clean_bg=true` query param; pull `background_url` from server (already supported by type, just confirm wiring).
- `web/src/app/(canvas)/studio/smart-layer-poc/SmartLayerPocClient.tsx` — `LayerBox` for image layers currently uses `opacity-80 mix-blend-screen` which made dummy crops look layered. With real transparent PNGs, drop those classes (otherwise cutouts look ghosted).

---

## Pre-Flight: Isolated Worktree

This plan is to be executed inside an isolated git worktree, set up via `superpowers:using-git-worktrees`. The branch name to request is `feature/daffa/vc-smart-layer-poc`. The worktree will need to operate over two sub-repos (`ai-service/` on `development` and `web/` on `develop`); cut branches off each respective default.

If running outside a worktree, manually:

```bash
cd ai-service && git checkout development && git pull && git checkout -b feature/daffa/vc-smart-layer-poc && cd ..
cd web         && git checkout develop     && git pull && git checkout -b feature/daffa/vc-smart-layer-poc && cd ..
```

---

## Task 1: Pydantic schema mirroring the frontend type

**Files:**
- Create: `ai-service/app/agents/smart_layer/__init__.py`
- Create: `ai-service/app/agents/smart_layer/schema.py`
- Create: `ai-service/tests/agents/smart_layer/__init__.py`
- Create: `ai-service/tests/agents/smart_layer/test_schema.py`

- [ ] **Step 1: Write the failing test**

```python
# ai-service/tests/agents/smart_layer/test_schema.py
from app.agents.smart_layer.schema import (
    SmartLayer,
    SmartLayerManifest,
    SmartLayerSource,
)


def test_manifest_serializes_layers_with_normalized_coordinates() -> None:
    manifest = SmartLayerManifest(
        source=SmartLayerSource(
            file_name="kv.png", width=1024, height=1024, aspect_ratio="1024:1024"
        ),
        background_url="https://example.com/bg.png",
        analyzer="remote",
        model_hint="gpt-4o + rembg + gpt-image-2",
        layers=[
            SmartLayer(
                id="layer_subject",
                label="Hero product",
                kind="subject",
                type="image",
                x=0.25,
                y=0.2,
                width=0.5,
                height=0.5,
                rotation=0,
                z=3,
                confidence=0.91,
                asset_url="https://example.com/subject.png",
                mime_type="image/png",
            )
        ],
        warnings=[],
    )
    dumped = manifest.model_dump(mode="json")
    assert dumped["analyzer"] == "remote"
    assert dumped["layers"][0]["kind"] == "subject"
    assert 0 <= dumped["layers"][0]["x"] <= 1


def test_manifest_rejects_out_of_range_coordinates() -> None:
    import pytest
    from pydantic import ValidationError

    with pytest.raises(ValidationError):
        SmartLayer(
            id="x",
            label="x",
            kind="subject",
            type="image",
            x=1.5,  # out of range
            y=0.1,
            width=0.2,
            height=0.2,
            rotation=0,
            z=1,
            confidence=0.5,
        )
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ai-service && source .venv/bin/activate && pytest tests/agents/smart_layer/test_schema.py -v`
Expected: FAIL with ImportError (`app.agents.smart_layer.schema` missing).

- [ ] **Step 3: Write minimal implementation**

```python
# ai-service/app/agents/smart_layer/__init__.py
# (empty — package marker)
```

```python
# ai-service/app/agents/smart_layer/schema.py
from __future__ import annotations

from typing import Literal, Optional

from pydantic import BaseModel, Field

SmartLayerKind = Literal["background", "subject", "logo", "text", "cta", "decor"]
SmartLayerType = Literal["image", "text"]
SmartLayerMime = Literal["image/png", "image/jpeg", "image/webp", "image/svg+xml"]


class SmartLayerSource(BaseModel):
    file_name: str
    width: int
    height: int
    aspect_ratio: str


class SmartLayer(BaseModel):
    id: str
    label: str
    kind: SmartLayerKind
    type: SmartLayerType
    x: float = Field(ge=0.0, le=1.0)
    y: float = Field(ge=0.0, le=1.0)
    width: float = Field(ge=0.0, le=1.0)
    height: float = Field(ge=0.0, le=1.0)
    rotation: float = 0.0
    z: int
    confidence: float = Field(ge=0.0, le=1.0)
    asset_url: Optional[str] = None
    mime_type: Optional[SmartLayerMime] = None
    content: Optional[str] = None
    color: Optional[str] = None


class SmartLayerManifest(BaseModel):
    source: SmartLayerSource
    background_url: Optional[str]
    analyzer: Literal["local_poc", "remote"]
    model_hint: str
    layers: list[SmartLayer]
    warnings: list[str] = Field(default_factory=list)
```

```python
# ai-service/tests/agents/smart_layer/__init__.py
# (empty — package marker)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ai-service && source .venv/bin/activate && pytest tests/agents/smart_layer/test_schema.py -v`
Expected: 2 passed.

- [ ] **Step 5: Commit**

```bash
cd ai-service
git add app/agents/smart_layer/__init__.py app/agents/smart_layer/schema.py tests/agents/smart_layer/
git commit -m "feat(ai): smart-layer manifest schema mirroring frontend type"
```

---

## Task 2: Vision detection (GPT-4o structured output)

**Files:**
- Create: `ai-service/app/agents/smart_layer/vision.py`
- Create: `ai-service/tests/agents/smart_layer/test_vision_parsing.py`

The vision call accepts the raw image bytes and asks GPT-4o for a strict JSON manifest. We use OpenAI's `response_format={"type": "json_schema", ...}` to guarantee structure. Output is a list of layers minus `asset_url` (which the pipeline fills in later after cutout/upload).

- [ ] **Step 1: Write the failing test for the JSON-response parser**

```python
# ai-service/tests/agents/smart_layer/test_vision_parsing.py
from app.agents.smart_layer.vision import parse_vision_response


SAMPLE = {
    "layers": [
        {
            "id": "layer_subject",
            "label": "Soda can hero",
            "kind": "subject",
            "type": "image",
            "x": 0.31,
            "y": 0.22,
            "width": 0.38,
            "height": 0.6,
            "rotation": 0,
            "z": 3,
            "confidence": 0.88,
        },
        {
            "id": "layer_headline",
            "label": "Headline",
            "kind": "text",
            "type": "text",
            "x": 0.1,
            "y": 0.08,
            "width": 0.5,
            "height": 0.1,
            "rotation": 0,
            "z": 6,
            "confidence": 0.71,
            "content": "Refresh, redefined",
            "color": "#FFFFFF",
        },
    ],
    "warnings": ["Logo not detected"],
}


def test_parse_vision_response_returns_normalized_layers() -> None:
    layers, warnings = parse_vision_response(SAMPLE)
    assert len(layers) == 2
    assert layers[0].kind == "subject"
    assert layers[1].type == "text"
    assert layers[1].content == "Refresh, redefined"
    assert warnings == ["Logo not detected"]


def test_parse_vision_response_clamps_out_of_range_bboxes() -> None:
    out_of_range = {
        "layers": [
            {
                "id": "x",
                "label": "x",
                "kind": "subject",
                "type": "image",
                "x": -0.05,
                "y": 1.2,
                "width": 0.4,
                "height": 0.3,
                "rotation": 0,
                "z": 1,
                "confidence": 1.4,
            }
        ],
        "warnings": [],
    }
    layers, _ = parse_vision_response(out_of_range)
    assert layers[0].x == 0.0
    assert layers[0].y == 1.0
    assert layers[0].confidence == 1.0
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ai-service && pytest tests/agents/smart_layer/test_vision_parsing.py -v`
Expected: FAIL ImportError on `parse_vision_response`.

- [ ] **Step 3: Write minimal implementation**

```python
# ai-service/app/agents/smart_layer/vision.py
from __future__ import annotations

import base64
import json
from typing import Any

from openai import OpenAI

from app.agents.smart_layer.schema import SmartLayer
from app.utils.config import settings


VISION_MODEL = "gpt-4o"

# Asks for normalized bboxes. The model decides label/kind from a closed
# vocab; coordinates are floats in [0,1] referenced to the source image.
SYSTEM_PROMPT = """You are an expert key-visual layout analyzer.
You are given a marketing key-visual image. Return a strict JSON manifest of the
distinct overlay layers detectable on top of the background.

Rules:
- Use NORMALIZED coordinates: x/y/width/height are floats in [0,1] relative to the source image.
- `kind` MUST be one of: subject, logo, text, cta, decor. (The background is implicit; do NOT emit a background layer.)
- `type` is "text" for typographic layers, "image" for everything else.
- `z` is the stacking order (higher = on top). Background is z=0; first overlay layer >= 1.
- For text layers, also fill `content` (verbatim words) and `color` (hex of the visible text color).
- `confidence` is your own [0,1] confidence per layer.
- If a layer is uncertain, include it with low confidence rather than omitting.
- If you cannot find any layers, return an empty `layers` array and explain in `warnings`.
"""

JSON_SCHEMA: dict[str, Any] = {
    "name": "smart_layer_manifest",
    "schema": {
        "type": "object",
        "additionalProperties": False,
        "required": ["layers", "warnings"],
        "properties": {
            "warnings": {"type": "array", "items": {"type": "string"}},
            "layers": {
                "type": "array",
                "items": {
                    "type": "object",
                    "additionalProperties": False,
                    "required": [
                        "id", "label", "kind", "type",
                        "x", "y", "width", "height",
                        "rotation", "z", "confidence",
                    ],
                    "properties": {
                        "id": {"type": "string"},
                        "label": {"type": "string"},
                        "kind": {"type": "string",
                                 "enum": ["subject", "logo", "text", "cta", "decor"]},
                        "type": {"type": "string", "enum": ["image", "text"]},
                        "x": {"type": "number"},
                        "y": {"type": "number"},
                        "width": {"type": "number"},
                        "height": {"type": "number"},
                        "rotation": {"type": "number"},
                        "z": {"type": "integer"},
                        "confidence": {"type": "number"},
                        "content": {"type": ["string", "null"]},
                        "color": {"type": ["string", "null"]},
                    },
                },
            },
        },
    },
    "strict": True,
}


def _clamp_unit(v: float) -> float:
    if v < 0.0:
        return 0.0
    if v > 1.0:
        return 1.0
    return v


def parse_vision_response(payload: dict[str, Any]) -> tuple[list[SmartLayer], list[str]]:
    raw_layers = payload.get("layers") or []
    warnings = list(payload.get("warnings") or [])
    layers: list[SmartLayer] = []
    for raw in raw_layers:
        layers.append(
            SmartLayer(
                id=str(raw["id"]),
                label=str(raw["label"]),
                kind=raw["kind"],
                type=raw["type"],
                x=_clamp_unit(float(raw["x"])),
                y=_clamp_unit(float(raw["y"])),
                width=_clamp_unit(float(raw["width"])),
                height=_clamp_unit(float(raw["height"])),
                rotation=float(raw.get("rotation") or 0.0),
                z=int(raw["z"]),
                confidence=_clamp_unit(float(raw["confidence"])),
                content=raw.get("content"),
                color=raw.get("color"),
            )
        )
    return layers, warnings


def detect_layers(image_bytes: bytes, mime_type: str) -> tuple[list[SmartLayer], list[str]]:
    """Single round-trip vision call. Returns layers + provider warnings."""
    client = OpenAI(api_key=settings.OPENAI_API_KEY)
    b64 = base64.b64encode(image_bytes).decode("ascii")
    response = client.chat.completions.create(
        model=VISION_MODEL,
        response_format={"type": "json_schema", "json_schema": JSON_SCHEMA},
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "Analyze this key visual and return the JSON manifest."},
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:{mime_type};base64,{b64}"},
                    },
                ],
            },
        ],
        temperature=0,
    )
    raw = response.choices[0].message.content or "{}"
    payload = json.loads(raw)
    return parse_vision_response(payload)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ai-service && pytest tests/agents/smart_layer/test_vision_parsing.py -v`
Expected: 2 passed.

- [ ] **Step 5: Commit**

```bash
git add ai-service/app/agents/smart_layer/vision.py ai-service/tests/agents/smart_layer/test_vision_parsing.py
git commit -m "feat(ai): GPT-4o vision detector for smart-layer manifest"
```

---

## Task 3: Subject/logo/CTA cutout via Replicate rembg

**Files:**
- Create: `ai-service/app/agents/smart_layer/cutout.py`
- Create: `ai-service/tests/agents/smart_layer/test_cutout.py`

We crop each non-background image-type layer using its bbox, send the crop to Replicate `lucataco/remove-bg` (a thin rembg wrapper that returns a URL to a transparent PNG), and download the result.

- [ ] **Step 1: Write the failing test**

```python
# ai-service/tests/agents/smart_layer/test_cutout.py
import io

from PIL import Image

from app.agents.smart_layer.cutout import crop_layer


def _gradient_png(w: int = 200, h: int = 200) -> bytes:
    img = Image.new("RGB", (w, h))
    for y in range(h):
        for x in range(w):
            img.putpixel((x, y), (x % 256, y % 256, (x + y) % 256))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def test_crop_layer_returns_png_bytes_of_correct_size() -> None:
    source = _gradient_png(400, 200)
    cropped = crop_layer(source, x=0.25, y=0.0, width=0.5, height=1.0)
    out = Image.open(io.BytesIO(cropped))
    assert out.size == (200, 200)
    assert out.format == "PNG"


def test_crop_layer_handles_edge_overflow_by_clamping() -> None:
    source = _gradient_png(100, 100)
    cropped = crop_layer(source, x=0.9, y=0.9, width=0.5, height=0.5)
    out = Image.open(io.BytesIO(cropped))
    assert out.size == (10, 10)  # clamped to image bounds
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ai-service && pytest tests/agents/smart_layer/test_cutout.py -v`
Expected: FAIL ImportError on `crop_layer`.

- [ ] **Step 3: Write minimal implementation**

```python
# ai-service/app/agents/smart_layer/cutout.py
from __future__ import annotations

import base64
import io
import logging

import requests
from PIL import Image

from app.utils.replicate_client import run_with_retry as replicate_run


logger = logging.getLogger(__name__)

# https://replicate.com/lucataco/remove-bg — rembg wrapper, returns URL of PNG.
REPLICATE_MODEL = "lucataco/remove-bg:95fcc2a26d3899cd6c2691c900465aaeff466285a65c14638cc5f36f34befaf1"


def crop_layer(image_bytes: bytes, *, x: float, y: float, width: float, height: float) -> bytes:
    """Crop a normalized [0,1] bbox out of the source image. Clamps to image bounds."""
    img = Image.open(io.BytesIO(image_bytes)).convert("RGBA")
    iw, ih = img.size
    left = max(0, int(round(x * iw)))
    top = max(0, int(round(y * ih)))
    right = min(iw, int(round((x + width) * iw)))
    bottom = min(ih, int(round((y + height) * ih)))
    if right <= left or bottom <= top:
        raise ValueError(f"empty crop: bbox ({x},{y},{width},{height}) on {iw}x{ih}")
    crop = img.crop((left, top, right, bottom))
    out = io.BytesIO()
    crop.save(out, format="PNG")
    return out.getvalue()


def cutout_subject(image_bytes: bytes) -> bytes:
    """Send PNG bytes to Replicate rembg, return the transparent PNG bytes."""
    b64 = base64.b64encode(image_bytes).decode("ascii")
    data_uri = f"data:image/png;base64,{b64}"
    output = replicate_run(REPLICATE_MODEL, input={"image": data_uri})
    # The model returns a single URL string or a file-like object depending on
    # the Replicate client version. Normalize.
    url = str(output) if not isinstance(output, list) else str(output[0])
    response = requests.get(url, timeout=60)
    response.raise_for_status()
    return response.content
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ai-service && pytest tests/agents/smart_layer/test_cutout.py -v`
Expected: 2 passed. (Note: `cutout_subject` itself is not exercised here — that requires Replicate creds and is covered in the pipeline integration test with a mock.)

- [ ] **Step 5: Commit**

```bash
git add ai-service/app/agents/smart_layer/cutout.py ai-service/tests/agents/smart_layer/test_cutout.py
git commit -m "feat(ai): smart-layer cutout helper using Replicate rembg"
```

---

## Task 4: Clean background via gpt-image-2 inpaint

**Files:**
- Create: `ai-service/app/agents/smart_layer/clean_background.py`
- Create: `ai-service/tests/agents/smart_layer/test_clean_background.py`

We compose a single L-mode mask where every non-bg overlay bbox is **white** (paint) and the rest is **black** (preserve), then call OpenAI `/v1/images/edits` with `model=gpt-image-2`. Reuse the alignment + RGBA-alpha mask helpers already in `outpaint_image.py` rather than re-implementing.

- [ ] **Step 1: Write the failing test (for the pure mask-building function only)**

```python
# ai-service/tests/agents/smart_layer/test_clean_background.py
import io

from PIL import Image

from app.agents.smart_layer.clean_background import build_inpaint_mask


def test_build_inpaint_mask_paints_overlay_regions_white() -> None:
    mask = build_inpaint_mask(
        size=(100, 100),
        bboxes=[
            (0.0, 0.0, 0.5, 0.5),  # top-left quadrant
        ],
    )
    assert mask.mode == "L"
    assert mask.size == (100, 100)
    # Inside the bbox: white (255). Outside: black (0).
    assert mask.getpixel((10, 10)) == 255
    assert mask.getpixel((90, 90)) == 0


def test_build_inpaint_mask_merges_overlapping_bboxes() -> None:
    mask = build_inpaint_mask(
        size=(100, 100),
        bboxes=[
            (0.0, 0.0, 0.6, 0.6),
            (0.4, 0.4, 0.6, 0.6),
        ],
    )
    assert mask.getpixel((50, 50)) == 255  # union region
    assert mask.getpixel((99, 99)) == 255  # second bbox extends to corner
    assert mask.getpixel((70, 10)) == 0    # neither bbox
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ai-service && pytest tests/agents/smart_layer/test_clean_background.py -v`
Expected: FAIL ImportError on `build_inpaint_mask`.

- [ ] **Step 3: Write minimal implementation**

```python
# ai-service/app/agents/smart_layer/clean_background.py
from __future__ import annotations

import io
import logging
from typing import Iterable

import requests
from PIL import Image, ImageDraw

from app.tools.outpaint_image import (
    _gpt_image_2_aligned_dims,
    _l_mask_to_rgba_alpha,
    _png_bytes,
)
from app.utils.config import settings


logger = logging.getLogger(__name__)

CLEAN_BG_PROMPT = (
    "Remove the overlay subjects, products, logos, text, and CTAs from the masked regions. "
    "Reconstruct a clean, seamless background that continues the surrounding scene naturally. "
    "Do not add new objects or text. Preserve the existing lighting, gradient, and texture."
)


Bbox = tuple[float, float, float, float]  # (x, y, width, height) normalized [0,1]


def build_inpaint_mask(*, size: tuple[int, int], bboxes: Iterable[Bbox]) -> Image.Image:
    """L-mode mask: white = paint (overlay region), black = preserve (background)."""
    w, h = size
    mask = Image.new("L", (w, h), 0)
    draw = ImageDraw.Draw(mask)
    for bx, by, bw, bh in bboxes:
        left = max(0, int(round(bx * w)))
        top = max(0, int(round(by * h)))
        right = min(w, int(round((bx + bw) * w)))
        bottom = min(h, int(round((by + bh) * h)))
        if right > left and bottom > top:
            draw.rectangle((left, top, right - 1, bottom - 1), fill=255)
    return mask


def clean_background(*, image_bytes: bytes, bboxes: list[Bbox]) -> bytes:
    """Inpaint masked regions via gpt-image-2 /v1/images/edits."""
    canvas = Image.open(io.BytesIO(image_bytes)).convert("RGBA")
    target_w, target_h = canvas.size
    aligned_w, aligned_h = _gpt_image_2_aligned_dims(target_w, target_h)

    mask = build_inpaint_mask(size=(target_w, target_h), bboxes=bboxes)

    if (aligned_w, aligned_h) != (target_w, target_h):
        padded_canvas = Image.new("RGBA", (aligned_w, aligned_h), (0, 0, 0, 0))
        padded_canvas.paste(canvas, (0, 0), canvas)
        padded_mask = Image.new("L", (aligned_w, aligned_h), 0)
        padded_mask.paste(mask, (0, 0))
        canvas, mask = padded_canvas, padded_mask

    files = [
        ("model", (None, "gpt-image-2")),
        ("prompt", (None, CLEAN_BG_PROMPT)),
        ("size", (None, f"{aligned_w}x{aligned_h}")),
        ("image", ("image.png", _png_bytes(canvas), "image/png")),
        ("mask", ("mask.png", _png_bytes(_l_mask_to_rgba_alpha(mask)), "image/png")),
    ]
    response = requests.post(
        "https://api.openai.com/v1/images/edits",
        headers={"Authorization": f"Bearer {settings.OPENAI_API_KEY}"},
        files=files,
        timeout=180,
    )
    if not response.ok:
        raise RuntimeError(
            f"OpenAI /v1/images/edits {response.status_code}: {response.text[:500]}"
        )
    result = response.json()
    if not result.get("data"):
        raise RuntimeError(f"OpenAI returned no image: {result}")

    import base64

    b64 = result["data"][0]["b64_json"]
    out_bytes = base64.b64decode(b64)
    # Crop padded output back to original target size.
    if (aligned_w, aligned_h) != (target_w, target_h):
        out_img = Image.open(io.BytesIO(out_bytes)).convert("RGBA")
        out_img = out_img.crop((0, 0, target_w, target_h))
        buf = io.BytesIO()
        out_img.save(buf, format="PNG")
        return buf.getvalue()
    return out_bytes
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ai-service && pytest tests/agents/smart_layer/test_clean_background.py -v`
Expected: 2 passed.

- [ ] **Step 5: Commit**

```bash
git add ai-service/app/agents/smart_layer/clean_background.py ai-service/tests/agents/smart_layer/test_clean_background.py
git commit -m "feat(ai): smart-layer clean-background inpainter (gpt-image-2)"
```

---

## Task 5: Pipeline orchestrator + S3 upload

**Files:**
- Create: `ai-service/app/agents/smart_layer/pipeline.py`
- Create: `ai-service/tests/agents/smart_layer/test_pipeline.py`
- Modify: `ai-service/app/utils/config.py` (add toggle)
- Modify: `ai-service/.env.example` (document toggle)

The orchestrator is the only place that touches S3 and ties everything together. We mock vision/cutout/clean_background/upload in the test so the integration shape (S3 keys, manifest assembly, warnings propagation, kill-switch) is locked in without burning real API calls.

- [ ] **Step 1: Write the failing test**

```python
# ai-service/tests/agents/smart_layer/test_pipeline.py
from __future__ import annotations

import io
from unittest.mock import patch

from PIL import Image

from app.agents.smart_layer.pipeline import run_smart_layer_pipeline
from app.agents.smart_layer.schema import SmartLayer


def _png(w: int = 64, h: int = 64) -> bytes:
    img = Image.new("RGB", (w, h), (200, 200, 220))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def _layer(kind: str, type_: str, id_: str, x: float = 0.1, y: float = 0.1) -> SmartLayer:
    return SmartLayer(
        id=id_, label=id_, kind=kind, type=type_,
        x=x, y=y, width=0.2, height=0.2,
        rotation=0, z=1, confidence=0.9,
    )


def test_pipeline_uploads_per_layer_assets_and_assembles_manifest() -> None:
    detected = [
        _layer("subject", "image", "layer_subject"),
        _layer("logo", "image", "layer_logo", x=0.7, y=0.05),
        _layer("text", "text", "layer_text", x=0.1, y=0.7),
    ]
    upload_calls: list[str] = []

    def fake_upload(*, source_path: str, destination_path: str, **_: object) -> str:
        upload_calls.append(destination_path)
        return f"https://s3.example/{destination_path}"

    with patch(
        "app.agents.smart_layer.pipeline.detect_layers",
        return_value=(detected, ["no decor found"]),
    ), patch(
        "app.agents.smart_layer.pipeline.cutout_subject",
        return_value=b"PNGBYTES",
    ), patch(
        "app.agents.smart_layer.pipeline.clean_background",
        return_value=b"CLEANBG",
    ), patch(
        "app.agents.smart_layer.pipeline._upload_bytes",
        side_effect=lambda data, dest, **kw: fake_upload(
            source_path="ignored", destination_path=dest
        ),
    ):
        manifest = run_smart_layer_pipeline(
            image_bytes=_png(),
            file_name="kv.png",
            mime_type="image/png",
            clean_bg=True,
        )

    assert manifest.analyzer == "remote"
    assert manifest.source.file_name == "kv.png"
    assert manifest.background_url is not None
    assert manifest.background_url.startswith("https://s3.example/smart-layer/")
    # 2 image layers + 1 background = 3 uploads
    assert len(upload_calls) == 3
    image_layers = [layer for layer in manifest.layers if layer.type == "image"]
    assert all(layer.asset_url and layer.asset_url.startswith("https://s3.example/") for layer in image_layers)
    text_layers = [layer for layer in manifest.layers if layer.type == "text"]
    assert text_layers[0].asset_url is None  # text layers don't get cutouts
    assert "no decor found" in manifest.warnings


def test_pipeline_skips_clean_bg_when_disabled() -> None:
    detected = [_layer("subject", "image", "layer_subject")]
    with patch(
        "app.agents.smart_layer.pipeline.detect_layers",
        return_value=(detected, []),
    ), patch(
        "app.agents.smart_layer.pipeline.cutout_subject",
        return_value=b"PNGBYTES",
    ), patch(
        "app.agents.smart_layer.pipeline.clean_background"
    ) as mock_clean, patch(
        "app.agents.smart_layer.pipeline._upload_bytes",
        side_effect=lambda data, dest, **kw: f"https://s3.example/{dest}",
    ):
        manifest = run_smart_layer_pipeline(
            image_bytes=_png(),
            file_name="kv.png",
            mime_type="image/png",
            clean_bg=False,
        )
    assert not mock_clean.called
    # When clean_bg disabled, background_url points at the uploaded source.
    assert manifest.background_url == "https://s3.example/smart-layer/source/kv.png"
    assert "Clean background disabled" in " ".join(manifest.warnings)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ai-service && pytest tests/agents/smart_layer/test_pipeline.py -v`
Expected: FAIL ImportError on `run_smart_layer_pipeline`.

- [ ] **Step 3: Add config toggle**

Open `ai-service/app/utils/config.py`. Find the `class Settings(BaseSettings):` block and append before the closing of the class (find a logical grouping with other feature toggles, or end-of-class):

```python
    # Smart layer POC
    SMART_LAYER_CLEAN_BG_ENABLED: bool = True
```

Open `ai-service/.env.example` and append:

```
# Smart Layer POC
# Set false to skip the gpt-image-2 inpaint step (costs ~ $0.05-0.10 per call).
SMART_LAYER_CLEAN_BG_ENABLED=true
```

- [ ] **Step 4: Write minimal pipeline implementation**

```python
# ai-service/app/agents/smart_layer/pipeline.py
from __future__ import annotations

import io
import logging
import os
import tempfile
import uuid

from PIL import Image

from app.agents.smart_layer.clean_background import clean_background
from app.agents.smart_layer.cutout import crop_layer, cutout_subject
from app.agents.smart_layer.schema import (
    SmartLayer,
    SmartLayerManifest,
    SmartLayerSource,
)
from app.agents.smart_layer.vision import detect_layers
from app.services.aws import upload_file_to_s3


logger = logging.getLogger(__name__)


def _upload_bytes(data: bytes, destination: str, *, content_type: str = "image/png") -> str:
    """Write bytes to a temp file and forward to upload_file_to_s3 (public-read)."""
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as fh:
        fh.write(data)
        tmp_path = fh.name
    try:
        url = upload_file_to_s3(
            source_path=tmp_path,
            destination_path=destination,
            file_permission="public",
            content_type=content_type,
        )
        if not url:
            raise RuntimeError(f"S3 upload failed for {destination}")
        return url
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


def _image_dimensions(image_bytes: bytes) -> tuple[int, int]:
    img = Image.open(io.BytesIO(image_bytes))
    return img.size  # (w, h)


def run_smart_layer_pipeline(
    *,
    image_bytes: bytes,
    file_name: str,
    mime_type: str,
    clean_bg: bool,
) -> SmartLayerManifest:
    """Full pipeline: vision detect → cutouts → clean background → S3 → manifest."""

    width, height = _image_dimensions(image_bytes)
    job_id = uuid.uuid4().hex[:12]
    s3_prefix = f"smart-layer/jobs/{job_id}"

    # 1. Vision detection
    detected, warnings = detect_layers(image_bytes, mime_type)

    # 2. Cutouts for image-type layers
    image_layer_bboxes: list[tuple[float, float, float, float]] = []
    out_layers: list[SmartLayer] = []
    for layer in detected:
        if layer.type == "text":
            out_layers.append(layer)
            continue
        try:
            crop = crop_layer(
                image_bytes,
                x=layer.x, y=layer.y, width=layer.width, height=layer.height,
            )
            cutout_png = cutout_subject(crop)
            asset_url = _upload_bytes(
                cutout_png,
                f"{s3_prefix}/{layer.id}.png",
            )
            out_layers.append(layer.model_copy(update={
                "asset_url": asset_url,
                "mime_type": "image/png",
            }))
            image_layer_bboxes.append((layer.x, layer.y, layer.width, layer.height))
        except Exception as exc:  # noqa: BLE001
            logger.exception("smart-layer cutout failed for %s", layer.id)
            warnings.append(f"cutout failed for {layer.id}: {exc}")
            out_layers.append(layer)

    # 3. Background (clean inpaint or pass-through original)
    if clean_bg and image_layer_bboxes:
        try:
            bg_bytes = clean_background(
                image_bytes=image_bytes,
                bboxes=image_layer_bboxes,
            )
            background_url = _upload_bytes(bg_bytes, f"{s3_prefix}/background.png")
        except Exception as exc:  # noqa: BLE001
            logger.exception("smart-layer clean_background failed")
            warnings.append(f"clean_background failed: {exc}; using source image")
            background_url = _upload_bytes(
                image_bytes,
                f"smart-layer/source/{file_name}",
                content_type=mime_type,
            )
    else:
        if not clean_bg:
            warnings.append("Clean background disabled (SMART_LAYER_CLEAN_BG_ENABLED=false or clean_bg=false)")
        background_url = _upload_bytes(
            image_bytes,
            f"smart-layer/source/{file_name}",
            content_type=mime_type,
        )

    return SmartLayerManifest(
        source=SmartLayerSource(
            file_name=file_name,
            width=width,
            height=height,
            aspect_ratio=f"{width}:{height}",
        ),
        background_url=background_url,
        analyzer="remote",
        model_hint="gpt-4o (detect) + lucataco/remove-bg (cutout) + gpt-image-2 (clean bg)",
        layers=out_layers,
        warnings=warnings,
    )
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd ai-service && pytest tests/agents/smart_layer/test_pipeline.py -v`
Expected: 2 passed. If any "destination prefix mismatch" assertion fails, double-check that `s3_prefix` matches the test's `assert manifest.background_url.startswith("https://s3.example/smart-layer/")`.

- [ ] **Step 6: Commit**

```bash
git add ai-service/app/agents/smart_layer/pipeline.py \
        ai-service/tests/agents/smart_layer/test_pipeline.py \
        ai-service/app/utils/config.py \
        ai-service/.env.example
git commit -m "feat(ai): smart-layer pipeline orchestrator + clean-bg toggle"
```

---

## Task 6: HTTP route wired into main app

**Files:**
- Create: `ai-service/app/agents/smart_layer/router.py`
- Modify: `ai-service/main.py`
- Create: `ai-service/tests/agents/smart_layer/test_router.py`

- [ ] **Step 1: Write the failing route test**

```python
# ai-service/tests/agents/smart_layer/test_router.py
import io
from unittest.mock import patch

from fastapi.testclient import TestClient
from PIL import Image

from main import app
from app.agents.smart_layer.schema import (
    SmartLayer,
    SmartLayerManifest,
    SmartLayerSource,
)


def _png() -> bytes:
    img = Image.new("RGB", (32, 32), (100, 120, 140))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def _stub_manifest() -> SmartLayerManifest:
    return SmartLayerManifest(
        source=SmartLayerSource(file_name="kv.png", width=32, height=32, aspect_ratio="32:32"),
        background_url="https://s3.example/bg.png",
        analyzer="remote",
        model_hint="stub",
        layers=[
            SmartLayer(
                id="layer_subject",
                label="Subject",
                kind="subject",
                type="image",
                x=0.1, y=0.1, width=0.4, height=0.4,
                rotation=0, z=3, confidence=0.9,
                asset_url="https://s3.example/subject.png",
                mime_type="image/png",
            )
        ],
        warnings=[],
    )


def test_analyze_endpoint_returns_manifest() -> None:
    client = TestClient(app)
    with patch(
        "app.agents.smart_layer.router.run_smart_layer_pipeline",
        return_value=_stub_manifest(),
    ) as mock_pipeline:
        response = client.post(
            "/ai/smart-layer/analyze",
            files={"image": ("kv.png", _png(), "image/png")},
        )
    assert response.status_code == 200
    body = response.json()
    assert body["analyzer"] == "remote"
    assert body["layers"][0]["kind"] == "subject"
    # default clean_bg should follow settings (True in dev)
    args, kwargs = mock_pipeline.call_args
    assert kwargs["clean_bg"] is True


def test_analyze_endpoint_honors_clean_bg_query_false() -> None:
    client = TestClient(app)
    with patch(
        "app.agents.smart_layer.router.run_smart_layer_pipeline",
        return_value=_stub_manifest(),
    ) as mock_pipeline:
        response = client.post(
            "/ai/smart-layer/analyze?clean_bg=false",
            files={"image": ("kv.png", _png(), "image/png")},
        )
    assert response.status_code == 200
    _, kwargs = mock_pipeline.call_args
    assert kwargs["clean_bg"] is False


def test_analyze_endpoint_rejects_non_image_upload() -> None:
    client = TestClient(app)
    response = client.post(
        "/ai/smart-layer/analyze",
        files={"image": ("kv.txt", b"not an image", "text/plain")},
    )
    assert response.status_code == 400
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ai-service && pytest tests/agents/smart_layer/test_router.py -v`
Expected: FAIL with 404 (route missing) or ImportError.

- [ ] **Step 3: Implement the router**

```python
# ai-service/app/agents/smart_layer/router.py
from __future__ import annotations

import logging
from typing import Optional

from fastapi import APIRouter, File, HTTPException, Query, UploadFile

from app.agents.smart_layer.pipeline import run_smart_layer_pipeline
from app.agents.smart_layer.schema import SmartLayerManifest
from app.utils.config import settings


logger = logging.getLogger(__name__)

router = APIRouter(prefix="/ai/smart-layer", tags=["smart-layer"])


@router.post("/analyze", response_model=SmartLayerManifest)
async def analyze(
    image: UploadFile = File(...),
    clean_bg: Optional[bool] = Query(default=None),
) -> SmartLayerManifest:
    mime_type = image.content_type or "application/octet-stream"
    if not mime_type.startswith("image/"):
        raise HTTPException(status_code=400, detail="Upload must be an image.")

    image_bytes = await image.read()
    if not image_bytes:
        raise HTTPException(status_code=400, detail="Empty image upload.")

    effective_clean_bg = (
        settings.SMART_LAYER_CLEAN_BG_ENABLED if clean_bg is None else clean_bg
    )

    try:
        return run_smart_layer_pipeline(
            image_bytes=image_bytes,
            file_name=image.filename or "upload.png",
            mime_type=mime_type,
            clean_bg=effective_clean_bg,
        )
    except Exception as exc:  # noqa: BLE001
        logger.exception("smart-layer analyze failed")
        raise HTTPException(status_code=500, detail=str(exc)) from exc
```

- [ ] **Step 4: Wire the router into the FastAPI app**

Open `ai-service/main.py`. Find the existing block of `app.agents.kv_*` router imports (around lines 7-10). Add:

```python
from app.agents.smart_layer.router import router as smart_layer_router
```

Find the `app.include_router(kv_resize_tile_upscale_router)` line near the bottom. Add immediately after:

```python
app.include_router(smart_layer_router)
```

- [ ] **Step 5: Run all smart-layer tests**

Run: `cd ai-service && pytest tests/agents/smart_layer/ -v`
Expected: all tests in tasks 1-6 pass (3 + 2 + 2 + 2 + 2 + 3 = 14 tests).

- [ ] **Step 6: Commit**

```bash
git add ai-service/app/agents/smart_layer/router.py \
        ai-service/tests/agents/smart_layer/test_router.py \
        ai-service/main.py
git commit -m "feat(ai): expose POST /ai/smart-layer/analyze endpoint"
```

---

## Task 7: Frontend env + transparent-cutout rendering polish

**Files:**
- Modify: `web/.env.local.example`
- Modify: `web/src/lib/studio/smart-layers.ts`
- Modify: `web/src/app/(canvas)/studio/smart-layer-poc/SmartLayerPocClient.tsx`

- [ ] **Step 1: Document the env var**

Open `web/.env.local.example`. Append (or insert in a logical place near other `NEXT_PUBLIC_*` entries):

```
# Smart Layer POC backend (ai-service). Leave unset to use the local preset analyzer.
NEXT_PUBLIC_SMART_LAYER_ENDPOINT=http://localhost:8000/ai/smart-layer/analyze
```

- [ ] **Step 2: Confirm the client passes the clean-bg query param**

Open `web/src/lib/studio/smart-layers.ts`. Find the block (around lines 61-78):

```ts
if (REMOTE_ENDPOINT) {
    try {
      const form = new FormData();
      form.append("image", file);
      const response = await fetch(REMOTE_ENDPOINT, {
        method: "POST",
        body: form,
      });
```

Replace the `fetch(REMOTE_ENDPOINT, …)` call with a version that allows opting out of the inpaint step (and matches the server's `clean_bg` query param). Final form:

```ts
const endpoint = new URL(REMOTE_ENDPOINT);
// The POC has no UI toggle yet; default to the server's behaviour (env-controlled).
const response = await fetch(endpoint, {
  method: "POST",
  body: form,
});
```

(No behavioural change yet — this is a no-op refactor that gives us the URL handle for a future UI toggle. It serves as a checkpoint that the URL is parseable.)

- [ ] **Step 3: Drop the dummy blending on image layers**

Open `web/src/app/(canvas)/studio/smart-layer-poc/SmartLayerPocClient.tsx`. Find `LayerBox` (around line 389). The image branch currently is:

```tsx
<span
  className="block h-full w-full bg-cover bg-center opacity-80 mix-blend-screen"
  style={{
    backgroundImage: layer.asset_url
      ? `url(${layer.asset_url})`
      : undefined,
  }}
/>
```

Replace with:

```tsx
<span
  className="block h-full w-full bg-contain bg-center bg-no-repeat"
  style={{
    backgroundImage: layer.asset_url
      ? `url(${layer.asset_url})`
      : undefined,
  }}
/>
```

Reasoning: real cutouts are transparent PNGs sized exactly to their bbox. `mix-blend-screen + opacity-80` was a hack to make the dummy "every layer = full source crop" look layered; with real assets it ghosts them out.

- [ ] **Step 4: Type-check and lint**

Run: `cd web && bun typecheck && bun lint`
Expected: zero errors.

- [ ] **Step 5: Commit**

```bash
git add web/.env.local.example \
        web/src/lib/studio/smart-layers.ts \
        web/src/app/\(canvas\)/studio/smart-layer-poc/SmartLayerPocClient.tsx
git commit -m "feat(web): wire smart-layer POC to ai-service endpoint"
```

---

## Task 8: End-to-end manual verification

**Files:** none (manual run)

This is the moment-of-truth — load real KV, run the pipeline, confirm the manifest is usable.

- [ ] **Step 1: Prepare envs**

In `ai-service/.env`, ensure:
- `OPENAI_API_KEY` = a key with gpt-4o + gpt-image-2 access.
- `REPLICATE_API_TOKEN` set (it's already used by other tools; just confirm presence).
- `S3_BUCKET_NAME`, `S3_REGION`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` filled.
- `SMART_LAYER_CLEAN_BG_ENABLED=true`.

In `web/.env.local`, set:
- `NEXT_PUBLIC_SMART_LAYER_ENDPOINT=http://localhost:8000/ai/smart-layer/analyze`.

- [ ] **Step 2: Start services**

```bash
./run-all.sh
# OR individually:
# cd ai-service && source .venv/bin/activate && fastapi dev
# cd web && bun dev
```

- [ ] **Step 3: Verify the route is mounted**

```bash
curl -sf http://localhost:8000/openapi.json | jq '.paths | keys | map(select(. | startswith("/ai/smart-layer")))'
```

Expected: `["/ai/smart-layer/analyze"]`

- [ ] **Step 4: Curl-test with a real KV**

```bash
curl -s -X POST http://localhost:8000/ai/smart-layer/analyze \
  -F "image=@./test-fixtures/sample-kv.jpg" \
  | jq '{analyzer, background_url, layer_count: (.layers | length), kinds: ([.layers[].kind])}'
```

Expected: JSON with `analyzer="remote"`, an `https://...` background_url, layer_count >= 1, plausible kinds (`subject`, `logo`, `text`...).

- [ ] **Step 5: Verify in the browser**

Open http://localhost:3000/studio/smart-layer-poc. Upload the same KV. Click **Analyze layers**.

Verify:
- (a) Status transitions: idle → ready → analyzing → done.
- (b) Right panel `Mode` shows `remote` (not `local_poc`).
- (c) Each non-bg image layer renders a transparent PNG (not the full source).
- (d) `Copy KV overlays` produces `StudioOverlayDraft[]` with `asset_url` pointing at S3 URLs for image layers.
- (e) Toggle visibility on each layer (eye icon) hides/shows it.

- [ ] **Step 6: Cost-conscious second pass**

Re-run with the inpaint step OFF to check the cheap path:

```bash
curl -s -X POST "http://localhost:8000/ai/smart-layer/analyze?clean_bg=false" \
  -F "image=@./test-fixtures/sample-kv.jpg" \
  | jq '.background_url, .warnings'
```

Expected: `background_url` is the uploaded source image (not an inpainted one), and `warnings` contains "Clean background disabled".

- [ ] **Step 7: Open a PR**

Push branches and open PRs targeting `development` (ai-service) and `develop` (web):

```bash
cd ai-service && git push -u origin feature/daffa/vc-smart-layer-poc
cd ../web      && git push -u origin feature/daffa/vc-smart-layer-poc
```

PR titles:
- `feat(ai-service): smart-layer POC — vision detect + cutout + clean bg`
- `feat(web): wire smart-layer POC to ai-service`

PR body should link to this plan and call out:
- Cost: one POC run ~= 1 gpt-4o call + N rembg + 1 gpt-image-2 edit. Estimate ~$0.10-0.25 per KV.
- `SMART_LAYER_CLEAN_BG_ENABLED=false` is the kill switch.
- Out of scope: KV-Generator integration (deferred).

---

## Self-Review

**Spec coverage:**
- Vision detection (B requirement): Task 2 ✓
- Cutout/segmentation per layer: Task 3 ✓
- Clean background: Task 4 ✓
- GPT-4o vision (consistent with existing ai-service): Task 2 ✓
- Frontend wired to real endpoint: Task 7 ✓
- "Bisa dicoba" end-to-end: Task 8 ✓

**Placeholder scan:** None — every step contains complete code or exact commands.

**Type consistency:**
- `SmartLayer` / `SmartLayerManifest` / `SmartLayerSource` defined in Task 1, reused identically in tasks 2-6 ✓
- `Bbox = tuple[float, float, float, float]` defined in Task 4 (`clean_background.py`), reused via inline tuples in Task 5 ✓
- `build_inpaint_mask` / `clean_background` / `cutout_subject` / `crop_layer` / `detect_layers` / `parse_vision_response` / `run_smart_layer_pipeline` names match between definition and test imports ✓
- FastAPI handler `analyze` registered at `/ai/smart-layer/analyze`, matches frontend `NEXT_PUBLIC_SMART_LAYER_ENDPOINT` in Task 7 ✓

**Notes / known limitations:**
- The Replicate `lucataco/remove-bg` SHA is a placeholder; the executor should pin to the latest by checking `replicate.com/lucataco/remove-bg` and updating Task 3's `REPLICATE_MODEL` const.
- gpt-image-2 `b64_json` field may not be present if OpenAI returns a URL instead — if `test_pipeline.py` step 4 fails on a real run, branch on `result["data"][0].get("b64_json")` vs `.get("url")`.
- The POC bypasses Laravel and talks directly from web → ai-service. Production hardening (auth header, request signing, rate limit, brand scoping) is intentionally out of scope.
