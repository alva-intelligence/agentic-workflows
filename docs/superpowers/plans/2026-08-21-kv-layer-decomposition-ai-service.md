# KV Layer Decomposition — ai-service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give api two HTTP endpoints — an async one that decomposes an image into a clean plate plus alpha layers via BytePlus Seedream 5.0 pro, and a synchronous one that flattens a chosen subset of those layers back onto the plate.

**Architecture:** Mirrors `app/agents/kv_resize` exactly. `POST /ai/kv-layer-decompose` returns 202 immediately and runs the work in a FastAPI `BackgroundTask`, which calls the vendor, mirrors every returned image to our own S3, and POSTs the result to an api internal callback. A second endpoint, `POST /ai/kv-layer-decompose/flatten`, is synchronous — it does deterministic PIL compositing with no model call.

**Tech Stack:** FastAPI, Pydantic v2, httpx, Pillow, pytest.

**Spec:** `docs/superpowers/specs/2026-08-21-kv-layer-decomposition-design.md`

## Global Constraints

- Model id is `dola-seedream-5-0-pro-260628`. Endpoint is `{BYTEPLUS_ARK_BASE_URL}/images/generations`.
- Request always sends `size: "auto"`, `layer_decomposition: true`, `response_format: "url"`, `output_format: "png"`, `watermark: false`. Never send `2K`, `1.5K`, or `1K`.
- Auto mode only — **never send a `prompt` field** on a decomposition request.
- **Do NOT use the `Ark` SDK** (`from byteplussdkarkruntime import Ark`) for this. Verified against the installed SDK: its `Image` response model declares only `url`, `b64_json`, `size`, so `z_index`, `bounding_box`, `name` and `description` — the entire point of this feature — are dropped, and `generate()` requires a `prompt`. Use raw `httpx`.
- `bounding_box.normalized` is on a **0–1000** scale. Divide by 1000 exactly once, at the mapping boundary, and never again downstream.
- A layer's PNG file dimensions are **not** its bbox dimensions. Anything that places a layer MUST scale it to `(right - left, bottom - top)` first.
- Vendor URLs expire in 24 hours. No vendor URL may appear in a callback payload — mirror first, then call back.
- The background task must **always** call back, success or failure. A swallowed exception leaves the api row spinning forever.
- Existing config keys `BYTEPLUS_ARK_API_KEY` and `BYTEPLUS_ARK_BASE_URL` already exist in `app/utils/config.py` (lines 130–131) and are already used by `app/tools/generate_image.py`. Reuse them; do not add new credential keys.
- **Every AI call must emit a PostHog `$ai_generation`.** This repo's own `ai-tracing` skill makes it a HIGH, non-negotiable requirement, and its provider-coverage table already lists `byteplus Ark` as Seam 3: a raw HTTP model call the posthog wrappers cannot intercept, captured manually at its single chokepoint with `capture_ai_generation(..., provider="byteplus")` on BOTH the success and the error path. `decompose_image` is that chokepoint.
- **Identity must reach the background task.** `bind_ai_context` seeds identity from the *request* body, and our request body carries only ids. Without `user_id`/`workspace_id` on the job payload every decomposition attributes to a fresh anonymous person. api sends them; ai-service calls `set_ai_context(...)` before the vendor call.
- Test baseline: `tests/agents/chat_agent` and `tests/agents/kv_generator` have ~16 pre-existing failures at HEAD. Run only the new test files plus anything you touch; do not treat that baseline as your regression.

## File Structure

| File | Responsibility |
|---|---|
| `app/agents/kv_layer_decompose/__init__.py` | package marker (empty) |
| `app/agents/kv_layer_decompose/client.py` | the vendor HTTP call; knows nothing about jobs or callbacks |
| `app/agents/kv_layer_decompose/mapping.py` | vendor JSON → our layer dicts; the only place ÷1000 happens |
| `app/agents/kv_layer_decompose/mirror.py` | download a vendor URL, push to our S3, return our URL |
| `app/agents/kv_layer_decompose/flatten.py` | composite selected layers onto a base image |
| `app/agents/kv_layer_decompose/api_client.py` | POST the completion callback to api |
| `app/agents/kv_layer_decompose/request_schema.py` | request bodies for both endpoints |
| `app/agents/kv_layer_decompose/response_schema.py` | 202 accepted body, flatten result body |
| `app/agents/kv_layer_decompose/service.py` | the background orchestrator |
| `app/agents/kv_layer_decompose/router.py` | both routes |
| `app/utils/config.py` | one new setting: the model id |
| `main.py` | register the router |
| `tests/agents/kv_layer_decompose/*` | one test module per source module |

---

### Task 1: Vendor client

**Files:**
- Create: `ai-service/app/agents/kv_layer_decompose/__init__.py` (empty)
- Create: `ai-service/app/agents/kv_layer_decompose/client.py`
- Modify: `ai-service/app/utils/config.py` (add one setting next to the existing `BYTEPLUS_ARK_*` block at lines 130–131)
- Create: `ai-service/tests/agents/kv_layer_decompose/__init__.py` (empty)
- Test: `ai-service/tests/agents/kv_layer_decompose/test_client.py`

**Interfaces:**
- Consumes: `settings.BYTEPLUS_ARK_API_KEY`, `settings.BYTEPLUS_ARK_BASE_URL` (already present).
- Produces: `decompose_image(image_url: str) -> dict` — returns the vendor's parsed JSON body verbatim. Raises `LayerDecomposeError` on any failure. Emits one `$ai_generation` per call, success or failure.

- [ ] **Step 1: Add the model-id setting**

In `app/utils/config.py`, find the existing block:

```python
    # BytePlus
    BYTEPLUS_ARK_API_KEY: str = "321456"
    BYTEPLUS_ARK_BASE_URL: str = "https://ark.ap-southeast.bytepluses.com/api/v3"
```

Append two lines directly under it:

```python
    # Seedream 5.0 pro — the only model with layer_decomposition. Pinned rather
    # than derived: layer decomposition is not a capability of the other
    # Seedream versions, so falling back to them would silently produce a
    # single flat image instead of layers.
    BYTEPLUS_SEEDREAM_LAYER_MODEL: str = "dola-seedream-5-0-pro-260628"
    BYTEPLUS_LAYER_DECOMPOSE_TIMEOUT_SEC: float = 300.0
```

- [ ] **Step 2: Write the failing tests**

Create `tests/agents/kv_layer_decompose/__init__.py` (empty file), then
`tests/agents/kv_layer_decompose/test_client.py`:

```python
import httpx
import pytest

from app.agents.kv_layer_decompose.client import (
    LayerDecomposeError,
    build_payload,
    decompose_image,
)


def test_build_payload_pins_auto_and_omits_prompt():
    payload = build_payload("https://example.com/kv.png")
    assert payload["model"] == "dola-seedream-5-0-pro-260628"
    assert payload["image"] == "https://example.com/kv.png"
    assert payload["layer_decomposition"] is True
    assert payload["size"] == "auto"
    assert payload["response_format"] == "url"
    assert payload["output_format"] == "png"
    assert payload["watermark"] is False
    # Auto mode: a prompt would switch the model into directed decomposition.
    assert "prompt" not in payload


def test_decompose_image_returns_parsed_body(monkeypatch):
    captured = {}

    def fake_post(self, url, json=None, headers=None):
        captured["url"] = url
        captured["json"] = json
        captured["headers"] = headers
        return httpx.Response(
            200,
            json={"model": "m", "data": [{"url": "u", "size": "1x1", "z_index": 0}]},
            request=httpx.Request("POST", url),
        )

    monkeypatch.setattr(httpx.Client, "post", fake_post)
    body = decompose_image("https://example.com/kv.png")

    assert body["data"][0]["z_index"] == 0
    assert captured["url"].endswith("/images/generations")
    assert captured["headers"]["Authorization"].startswith("Bearer ")


def test_decompose_image_raises_on_http_error(monkeypatch):
    def fake_post(self, url, json=None, headers=None):
        return httpx.Response(429, text="rate limited", request=httpx.Request("POST", url))

    monkeypatch.setattr(httpx.Client, "post", fake_post)
    with pytest.raises(LayerDecomposeError) as exc:
        decompose_image("https://example.com/kv.png")
    assert "429" in str(exc.value)


def test_decompose_image_raises_on_empty_data(monkeypatch):
    def fake_post(self, url, json=None, headers=None):
        return httpx.Response(200, json={"model": "m", "data": []},
                              request=httpx.Request("POST", url))

    monkeypatch.setattr(httpx.Client, "post", fake_post)
    with pytest.raises(LayerDecomposeError) as exc:
        decompose_image("https://example.com/kv.png")
    assert "no_layers_detected" in str(exc.value)


def test_a_successful_call_is_captured_for_posthog(monkeypatch):
    # byteplus is a Seam 3 provider in this repo's ai-tracing contract: the
    # posthog wrappers cannot intercept a raw HTTP model call, so the single
    # chokepoint must capture it by hand or the spend is invisible.
    captured = []

    def fake_post(self, url, json=None, headers=None):
        return httpx.Response(200, json={"model": "m", "data": [{"url": "u", "size": "1x1", "z_index": 0}]},
                              request=httpx.Request("POST", url))

    monkeypatch.setattr(httpx.Client, "post", fake_post)
    monkeypatch.setattr(client_mod, "capture_ai_generation",
                        lambda **kw: captured.append(kw))

    decompose_image("https://example.com/kv.png")

    assert len(captured) == 1
    assert captured[0]["provider"] == "byteplus"
    assert captured[0]["model"] == "dola-seedream-5-0-pro-260628"
    assert captured[0]["span_name"] == "kv_layer_decompose"
    assert captured[0]["error"] is None


def test_a_failed_call_is_also_captured(monkeypatch):
    # An untraced failure path hides exactly the runs worth investigating.
    captured = []

    def fake_post(self, url, json=None, headers=None):
        return httpx.Response(429, text="rate limited", request=httpx.Request("POST", url))

    monkeypatch.setattr(httpx.Client, "post", fake_post)
    monkeypatch.setattr(client_mod, "capture_ai_generation",
                        lambda **kw: captured.append(kw))

    with pytest.raises(LayerDecomposeError):
        decompose_image("https://example.com/kv.png")

    assert len(captured) == 1
    assert captured[0]["error"] is not None
```

Add this import at the top of the test file so the monkeypatches above resolve:

```python
from app.agents.kv_layer_decompose import client as client_mod
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd ai-service && .venv/bin/python -m pytest tests/agents/kv_layer_decompose/test_client.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.agents.kv_layer_decompose.client'`

- [ ] **Step 4: Write the implementation**

Create `app/agents/kv_layer_decompose/client.py`:

```python
"""Raw BytePlus Seedream 5.0 pro layer-decomposition call.

Deliberately NOT the `Ark` SDK. The installed byteplussdkarkruntime models an
image as {url, b64_json, size} only, so it silently drops z_index,
bounding_box, name and description — every field this feature exists to read —
and its generate() requires a prompt we must not send in auto mode.
"""
import logging
import time
from typing import Any, Dict, Optional

import httpx

from app.observability.ai_clients import capture_ai_generation
from app.utils.config import settings

logger = logging.getLogger(__name__)


class LayerDecomposeError(RuntimeError):
    """Vendor call failed, or returned nothing usable."""


def build_payload(image_url: str) -> Dict[str, Any]:
    return {
        "model": settings.BYTEPLUS_SEEDREAM_LAYER_MODEL,
        "image": image_url,
        "layer_decomposition": True,
        # `auto` returns the plate at the SOURCE image's own dimensions
        # (raising below 1K, capping above 2K), so the new board matches the
        # board it was decomposed from. A pinned tier would not.
        "size": "auto",
        "response_format": "url",
        # Base image only — layers always come back as PNG regardless.
        "output_format": "png",
        "watermark": False,
    }


def decompose_image(image_url: str) -> Dict[str, Any]:
    url = f"{settings.BYTEPLUS_ARK_BASE_URL.rstrip('/')}/images/generations"
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {settings.BYTEPLUS_ARK_API_KEY}",
    }
    model = settings.BYTEPLUS_SEEDREAM_LAYER_MODEL
    start = time.time()

    # This function is the ONE chokepoint for the byteplus provider, per the
    # repo's ai-tracing contract. Capture on every exit — an untraced failure
    # hides the runs most worth looking at. Never pass the image or the layer
    # payload as content: it is user artwork.
    def _capture(error: Optional[BaseException]) -> None:
        capture_ai_generation(
            model=model,
            provider="byteplus",
            span_name="kv_layer_decompose",
            start_time=start,
            error=error,
        )

    try:
        with httpx.Client(timeout=settings.BYTEPLUS_LAYER_DECOMPOSE_TIMEOUT_SEC) as client:
            resp = client.post(url, json=build_payload(image_url), headers=headers)
    except Exception as exc:  # noqa: BLE001 — network class is broad on purpose
        _capture(exc)
        raise LayerDecomposeError(f"layer decomposition request failed: {exc}") from exc

    if resp.status_code >= 400:
        err = LayerDecomposeError(
            f"layer decomposition returned {resp.status_code}: {resp.text[:200]}"
        )
        _capture(err)
        raise err

    body = resp.json()
    if not body.get("data"):
        err = LayerDecomposeError("no_layers_detected")
        _capture(err)
        raise err

    _capture(None)
    return body
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd ai-service && .venv/bin/python -m pytest tests/agents/kv_layer_decompose/test_client.py -v`
Expected: 6 passed

- [ ] **Step 6: Commit**

```bash
git add app/agents/kv_layer_decompose/__init__.py app/agents/kv_layer_decompose/client.py app/utils/config.py tests/agents/kv_layer_decompose/
git commit -m "feat(ai): Seedream layer-decomposition vendor client"
```

---

### Task 2: Response mapping

**Files:**
- Create: `ai-service/app/agents/kv_layer_decompose/mapping.py`
- Create: `ai-service/tests/agents/kv_layer_decompose/fixtures/__init__.py` (empty)
- Create: `ai-service/tests/agents/kv_layer_decompose/fixtures/seedream_response.json`
- Test: `ai-service/tests/agents/kv_layer_decompose/test_mapping.py`

**Interfaces:**
- Consumes: the dict returned by `decompose_image()` (Task 1).
- Produces:
  - `split_response(body: dict) -> tuple[dict, list[dict]]` — returns `(base_entry, layer_entries)` sorted by `z_index`, base being the `z_index == 0` entry.
  - `to_layer(entry: dict) -> dict` — one vendor layer entry → `{"index", "name", "description", "z", "x", "y", "width", "height", "vendor_url"}` with geometry normalized to 0..1.
  - `pixel_count(entry: dict) -> int` — parses `"1536x1024"` → `1572864`. api needs these for per-image billing tiers.

- [ ] **Step 1: Create the fixture**

Create `tests/agents/kv_layer_decompose/fixtures/__init__.py` as an empty file, then
`tests/agents/kv_layer_decompose/fixtures/seedream_response.json`. This is a real
captured response with the vendor's signed URLs replaced; keep the numbers exactly
as written — the geometry assertions below depend on them.

```json
{
  "model": "dola-seedream-5-0-pro-260628",
  "created": 1787306053,
  "usage": {
    "input_images": 1,
    "generated_images": 8,
    "output_tokens": 34772,
    "total_tokens": 34772
  },
  "data": [
    {
      "url": "https://vendor.example/base.png",
      "size": "1536x1024",
      "output_format": "png",
      "z_index": 0
    },
    {
      "url": "https://vendor.example/layer_03.png",
      "size": "720x232",
      "output_format": "png",
      "z_index": 3,
      "bounding_box": {
        "absolute": [1287, 170, 1480, 232],
        "normalized": [838, 166, 963, 226]
      },
      "name": "frndGlow Wall Logo",
      "description": "Purple 'frndGlow' text logo printed on the right side of the light wall, no other elements included."
    },
    {
      "url": "https://vendor.example/layer_01.png",
      "size": "766x982",
      "output_format": "png",
      "z_index": 1,
      "bounding_box": {
        "absolute": [0, 0, 721, 924],
        "normalized": [0, 0, 469, 901]
      },
      "name": "Window and Desk Background",
      "description": "Bright floor-to-ceiling window with blurred city skyline view, and the smooth white desk surface, no foreground objects included."
    },
    {
      "url": "https://vendor.example/layer_07.png",
      "size": "386x877",
      "output_format": "png",
      "z_index": 7,
      "bounding_box": {
        "absolute": [522, 452, 650, 745],
        "normalized": [340, 441, 423, 727]
      },
      "name": "frndGlow Sunscreen Tube",
      "description": "Light purple frndGlow daily sunscreen product tube held by the woman, including all printed text on the tube surface, no other attached objects."
    }
  ]
}
```

Note the entries are deliberately out of `z_index` order — the vendor does not
guarantee ordering and `split_response` must sort.

- [ ] **Step 2: Write the failing tests**

Create `tests/agents/kv_layer_decompose/test_mapping.py`:

```python
import json
import pathlib

import pytest

from app.agents.kv_layer_decompose.mapping import (
    pixel_count,
    split_response,
    to_layer,
)

FIXTURE = pathlib.Path(__file__).parent / "fixtures" / "seedream_response.json"


@pytest.fixture
def body():
    return json.loads(FIXTURE.read_text())


def test_split_response_separates_base_and_sorts_layers(body):
    base, layers = split_response(body)
    assert base["z_index"] == 0
    assert base["size"] == "1536x1024"
    # Fixture order is 0, 3, 1, 7 — output must be ascending.
    assert [l["z_index"] for l in layers] == [1, 3, 7]


def test_split_response_rejects_a_body_with_no_base():
    with pytest.raises(ValueError):
        split_response({"data": [{"url": "u", "size": "1x1", "z_index": 1}]})


def test_to_layer_divides_normalized_by_1000(body):
    _, layers = split_response(body)
    tube = next(l for l in layers if l["z_index"] == 7)
    out = to_layer(tube)
    # [340, 441, 423, 727] / 1000 -> x, y, then width/height as differences.
    assert out["x"] == pytest.approx(0.340)
    assert out["y"] == pytest.approx(0.441)
    assert out["width"] == pytest.approx(0.083)
    assert out["height"] == pytest.approx(0.286)


def test_to_layer_carries_identity_and_z(body):
    _, layers = split_response(body)
    out = to_layer(layers[0])
    assert out["index"] == 1
    assert out["z"] == 1
    assert out["name"] == "Window and Desk Background"
    assert out["description"].startswith("Bright floor-to-ceiling window")
    assert out["vendor_url"] == "https://vendor.example/layer_01.png"


def test_to_layer_survives_a_layer_with_no_name_or_description():
    out = to_layer({
        "url": "u", "size": "10x10", "z_index": 2,
        "bounding_box": {"absolute": [0, 0, 5, 5], "normalized": [0, 0, 500, 500]},
    })
    assert out["name"] == "Layer 2"
    assert out["description"] == ""


def test_to_layer_rejects_a_layer_with_no_bounding_box():
    with pytest.raises(ValueError):
        to_layer({"url": "u", "size": "10x10", "z_index": 2})


def test_pixel_count_parses_the_size_string():
    assert pixel_count({"size": "1536x1024"}) == 1572864
    assert pixel_count({"size": "386x877"}) == 338522


def test_pixel_count_returns_zero_on_a_malformed_size():
    assert pixel_count({"size": "banana"}) == 0
    assert pixel_count({}) == 0
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd ai-service && .venv/bin/python -m pytest tests/agents/kv_layer_decompose/test_mapping.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.agents.kv_layer_decompose.mapping'`

- [ ] **Step 4: Write the implementation**

Create `app/agents/kv_layer_decompose/mapping.py`:

```python
"""Vendor response -> our layer shape.

The ONLY place `bounding_box.normalized` is divided by 1000. It is a 0-1000
integer scale in the vendor payload and a 0..1 fraction everywhere in our
stack, and doing the conversion twice is a silent 1000x geometry bug.
"""
from typing import Any, Dict, List, Tuple

# The vendor's normalized coordinates are integers on a 0-1000 axis.
NORMALIZED_SCALE = 1000.0


def split_response(body: Dict[str, Any]) -> Tuple[Dict[str, Any], List[Dict[str, Any]]]:
    """Return (base_entry, layers_sorted_by_z). The vendor does not promise
    ordering, so sort rather than trusting array position."""
    entries = list(body.get("data") or [])
    base = next((e for e in entries if e.get("z_index") == 0), None)
    if base is None:
        raise ValueError("response has no base image (no entry with z_index 0)")
    layers = sorted(
        (e for e in entries if e.get("z_index", 0) != 0),
        key=lambda e: e.get("z_index", 0),
    )
    return base, layers


def to_layer(entry: Dict[str, Any]) -> Dict[str, Any]:
    box = (entry.get("bounding_box") or {}).get("normalized")
    if not box or len(box) != 4:
        raise ValueError(f"layer z={entry.get('z_index')} has no normalized bounding box")
    left, top, right, bottom = (v / NORMALIZED_SCALE for v in box)
    z = int(entry.get("z_index", 0))
    return {
        "index": z,
        "z": z,
        "name": entry.get("name") or f"Layer {z}",
        "description": entry.get("description") or "",
        "x": left,
        "y": top,
        "width": right - left,
        "height": bottom - top,
        "vendor_url": entry.get("url"),
    }


def pixel_count(entry: Dict[str, Any]) -> int:
    """Width x height from the vendor's "WxH" string. api bills each returned
    image on its own pixel tier, so it needs this per entry. Returns 0 rather
    than raising on a malformed value — a missing count must not fail a
    decomposition that otherwise succeeded."""
    size = entry.get("size")
    if not isinstance(size, str) or "x" not in size:
        return 0
    w, _, h = size.partition("x")
    try:
        return int(w) * int(h)
    except ValueError:
        return 0
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd ai-service && .venv/bin/python -m pytest tests/agents/kv_layer_decompose/test_mapping.py -v`
Expected: 8 passed

- [ ] **Step 6: Commit**

```bash
git add app/agents/kv_layer_decompose/mapping.py tests/agents/kv_layer_decompose/
git commit -m "feat(ai): map Seedream layer response to normalized geometry"
```

---

### Task 3: S3 mirroring

**Files:**
- Create: `ai-service/app/agents/kv_layer_decompose/mirror.py`
- Test: `ai-service/tests/agents/kv_layer_decompose/test_mirror.py`

**Interfaces:**
- Consumes: `app.tools.edit_image.save_bytes_to_file(image_bytes, temp_folder_path, destination_path, file_name) -> str` and `settings.API_ENV`.
- Produces: `mirror_url(vendor_url: str, job_id: str, file_name: str) -> str` — downloads and re-uploads, returning our own URL. Raises `MirrorError` on failure.

- [ ] **Step 1: Write the failing tests**

Create `tests/agents/kv_layer_decompose/test_mirror.py`:

```python
import httpx
import pytest

from app.agents.kv_layer_decompose import mirror as mirror_mod
from app.agents.kv_layer_decompose.mirror import MirrorError, mirror_url


def test_mirror_url_downloads_then_uploads(monkeypatch):
    seen = {}

    def fake_get(self, url):
        seen["download"] = url
        return httpx.Response(200, content=b"PNGBYTES", request=httpx.Request("GET", url))

    def fake_save(image_bytes, temp_folder_path, destination_path, file_name):
        seen["bytes"] = image_bytes
        seen["destination"] = destination_path
        seen["file_name"] = file_name
        return "https://our-s3/mirrored.png"

    monkeypatch.setattr(httpx.Client, "get", fake_get)
    monkeypatch.setattr(mirror_mod, "save_bytes_to_file", fake_save)

    out = mirror_url("https://vendor.example/layer_01.png", "job123", "layer_01.png")

    assert out == "https://our-s3/mirrored.png"
    assert seen["download"] == "https://vendor.example/layer_01.png"
    assert seen["bytes"] == b"PNGBYTES"
    assert seen["file_name"] == "layer_01.png"
    assert "kv-layer-decompose/job123" in seen["destination"]


def test_mirror_url_raises_when_the_download_fails(monkeypatch):
    def fake_get(self, url):
        return httpx.Response(404, text="gone", request=httpx.Request("GET", url))

    monkeypatch.setattr(httpx.Client, "get", fake_get)
    with pytest.raises(MirrorError):
        mirror_url("https://vendor.example/layer_01.png", "job123", "layer_01.png")


def test_mirror_url_raises_when_the_upload_fails(monkeypatch):
    def fake_get(self, url):
        return httpx.Response(200, content=b"X", request=httpx.Request("GET", url))

    def boom(**kwargs):
        raise RuntimeError("s3 down")

    monkeypatch.setattr(httpx.Client, "get", fake_get)
    monkeypatch.setattr(mirror_mod, "save_bytes_to_file", lambda *a, **k: boom())

    with pytest.raises(MirrorError):
        mirror_url("https://vendor.example/layer_01.png", "job123", "layer_01.png")
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ai-service && .venv/bin/python -m pytest tests/agents/kv_layer_decompose/test_mirror.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.agents.kv_layer_decompose.mirror'`

- [ ] **Step 3: Write the implementation**

Create `app/agents/kv_layer_decompose/mirror.py`:

```python
"""Copy vendor images onto our own storage.

Vendor URLs are signed and expire after 24 hours. Persisting one would give
the api a link that works in testing and is dead by the next day, so every
image is mirrored BEFORE the completion callback fires and only our URLs
ever leave this service.
"""
import logging

import httpx

from app.tools.edit_image import save_bytes_to_file
from app.utils.config import settings

logger = logging.getLogger(__name__)

_DOWNLOAD_TIMEOUT_SEC = 120.0


class MirrorError(RuntimeError):
    """Could not copy a vendor image onto our storage."""


def mirror_url(vendor_url: str, job_id: str, file_name: str) -> str:
    try:
        with httpx.Client(timeout=_DOWNLOAD_TIMEOUT_SEC) as client:
            resp = client.get(vendor_url)
    except Exception as exc:  # noqa: BLE001
        raise MirrorError(f"download failed for {file_name}: {exc}") from exc

    if resp.status_code >= 400:
        raise MirrorError(f"download for {file_name} returned {resp.status_code}")

    try:
        return save_bytes_to_file(
            image_bytes=resp.content,
            temp_folder_path="./temp",
            destination_path=f"{settings.API_ENV}/kv-layer-decompose/{job_id}",
            file_name=file_name,
        )
    except Exception as exc:  # noqa: BLE001
        raise MirrorError(f"upload failed for {file_name}: {exc}") from exc
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ai-service && .venv/bin/python -m pytest tests/agents/kv_layer_decompose/test_mirror.py -v`
Expected: 3 passed

- [ ] **Step 5: Commit**

```bash
git add app/agents/kv_layer_decompose/mirror.py tests/agents/kv_layer_decompose/test_mirror.py
git commit -m "feat(ai): mirror Seedream layer output to our storage"
```

---

### Task 4: Completion callback client

**Files:**
- Create: `ai-service/app/agents/kv_layer_decompose/api_client.py`
- Test: `ai-service/tests/agents/kv_layer_decompose/test_api_client.py`

**Interfaces:**
- Consumes: `app.utils.internal_callback.post_internal_callback(url, payload, label)` and `settings.API_INTERNAL_URL`.
- Produces: `post_completed(*, decomposition_id, status, base_image_url=None, layers=None, image_pixel_counts=None, error_message=None, ai_service_run_id=None, model=None) -> None`.

The api's internal controller is `KvLayerDecompositionInternalController::completed`
at `POST /api/v1/internal/kv-layer-decompositions/completed`. It gates credit
metering on `ai_service_run_id` AND a non-empty `image_pixel_counts`, so a
successful call must send both or the run is never billed.

- [ ] **Step 1: Write the failing tests**

Create `tests/agents/kv_layer_decompose/test_api_client.py`:

```python
from app.agents.kv_layer_decompose import api_client as mod
from app.agents.kv_layer_decompose.api_client import post_completed


def test_post_completed_done_payload(monkeypatch):
    sent = {}
    monkeypatch.setattr(
        mod, "post_internal_callback",
        lambda url, payload, label=None: sent.update(url=url, payload=payload, label=label),
    )

    post_completed(
        decomposition_id="d1",
        status="done",
        base_image_url="https://our-s3/base.png",
        layers=[{"index": 1, "z": 1, "name": "n", "description": "",
                 "x": 0.1, "y": 0.2, "width": 0.3, "height": 0.4,
                 "image_url": "https://our-s3/l1.png"}],
        image_pixel_counts=[1572864, 752212],
        ai_service_run_id="run-1",
        model="dola-seedream-5-0-pro-260628",
    )

    assert sent["url"].endswith("/api/v1/internal/kv-layer-decompositions/completed")
    p = sent["payload"]
    assert p["decomposition_id"] == "d1"
    assert p["status"] == "done"
    assert p["base_image_url"] == "https://our-s3/base.png"
    assert p["layers"][0]["image_url"] == "https://our-s3/l1.png"
    assert p["image_pixel_counts"] == [1572864, 752212]
    assert p["ai_service_run_id"] == "run-1"
    assert "error_message" not in p


def test_post_completed_failed_payload_omits_result_fields(monkeypatch):
    sent = {}
    monkeypatch.setattr(
        mod, "post_internal_callback",
        lambda url, payload, label=None: sent.update(payload=payload),
    )

    post_completed(decomposition_id="d1", status="failed", error_message="no_layers_detected")

    p = sent["payload"]
    assert p == {"decomposition_id": "d1", "status": "failed",
                 "error_message": "no_layers_detected"}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ai-service && .venv/bin/python -m pytest tests/agents/kv_layer_decompose/test_api_client.py -v`
Expected: FAIL — `ModuleNotFoundError`

- [ ] **Step 3: Write the implementation**

Create `app/agents/kv_layer_decompose/api_client.py`:

```python
from typing import Any, Dict, List, Optional

from app.utils.config import settings
from app.utils.internal_callback import post_internal_callback


def post_completed(
    *,
    decomposition_id: str,
    status: str,
    base_image_url: Optional[str] = None,
    layers: Optional[List[Dict[str, Any]]] = None,
    image_pixel_counts: Optional[List[int]] = None,
    error_message: Optional[str] = None,
    ai_service_run_id: Optional[str] = None,
    model: Optional[str] = None,
) -> None:
    """Post the final status back to api.

    `image_pixel_counts` carries one entry per returned image (base first).
    BytePlus bills layer decomposition PER IMAGE on a per-image pixel tier, not
    per token, so this — not a token count — is what
    KvCreditMeteringService::chargeLayerDecomposition() prices. api gates
    metering on `ai_service_run_id` AND a non-empty `image_pixel_counts`; omit
    either and the run completes unbilled.
    """
    url = (
        f"{settings.API_INTERNAL_URL.rstrip('/')}"
        "/api/v1/internal/kv-layer-decompositions/completed"
    )
    payload: Dict[str, Any] = {"decomposition_id": decomposition_id, "status": status}
    if base_image_url is not None:
        payload["base_image_url"] = base_image_url
    if layers:
        payload["layers"] = layers
    if image_pixel_counts:
        payload["image_pixel_counts"] = image_pixel_counts
    if error_message is not None:
        payload["error_message"] = error_message
    if ai_service_run_id is not None:
        payload["ai_service_run_id"] = ai_service_run_id
    if model is not None:
        payload["model"] = model

    post_internal_callback(url, payload, label="kv_layer_decompose")
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ai-service && .venv/bin/python -m pytest tests/agents/kv_layer_decompose/test_api_client.py -v`
Expected: 2 passed

- [ ] **Step 5: Commit**

```bash
git add app/agents/kv_layer_decompose/api_client.py tests/agents/kv_layer_decompose/test_api_client.py
git commit -m "feat(ai): layer-decomposition completion callback client"
```

---

### Task 5: Orchestrator, schemas, and the async route

**Files:**
- Create: `ai-service/app/agents/kv_layer_decompose/request_schema.py`
- Create: `ai-service/app/agents/kv_layer_decompose/response_schema.py`
- Create: `ai-service/app/agents/kv_layer_decompose/service.py`
- Create: `ai-service/app/agents/kv_layer_decompose/router.py`
- Modify: `ai-service/main.py` (import + `include_router`, alongside the other `kv_*` routers at lines 17–22 and ~110)
- Test: `ai-service/tests/agents/kv_layer_decompose/test_service.py`
- Test: `ai-service/tests/agents/kv_layer_decompose/test_router.py`

**Interfaces:**
- Consumes: `decompose_image` (T1), `split_response`/`to_layer`/`pixel_count` (T2), `mirror_url` (T3), `post_completed` (T4).
- Produces:
  - `LayerDecomposeJobRequest{decomposition_id: str, source_image_url: str}`
  - `LayerDecomposeAccepted{decomposition_id: str, status: str = "accepted"}`
  - `process_layer_decompose_job(req: LayerDecomposeJobRequest) -> None`
  - route `POST /ai/kv-layer-decompose` → 202

- [ ] **Step 1: Write the schemas**

Create `app/agents/kv_layer_decompose/request_schema.py`:

```python
from typing import Optional

from pydantic import BaseModel


class LayerDecomposeJobRequest(BaseModel):
    decomposition_id: str
    source_image_url: str
    # Identity for PostHog attribution. `bind_ai_context` seeds these from the
    # REQUEST body, and the vendor call happens later in a BackgroundTask — so
    # without them every decomposition lands on a fresh anonymous person and
    # the spend cannot be traced to a user, workspace, or brand.
    user_id: Optional[str] = None
    user_email: Optional[str] = None
    workspace_id: Optional[str] = None
    workspace_name: Optional[str] = None
    brand_id: Optional[str] = None
    brand_name: Optional[str] = None
```

Create `app/agents/kv_layer_decompose/response_schema.py`:

```python
from pydantic import BaseModel


class LayerDecomposeAccepted(BaseModel):
    decomposition_id: str
    status: str = "accepted"
```

- [ ] **Step 2: Write the failing service tests**

Create `tests/agents/kv_layer_decompose/test_service.py`:

```python
import json
import pathlib

from app.agents.kv_layer_decompose import service as svc
from app.agents.kv_layer_decompose.client import LayerDecomposeError
from app.agents.kv_layer_decompose.request_schema import LayerDecomposeJobRequest

FIXTURE = pathlib.Path(__file__).parent / "fixtures" / "seedream_response.json"


def _req():
    return LayerDecomposeJobRequest(
        decomposition_id="d1", source_image_url="https://example.com/kv.png"
    )


def _patch_happy(monkeypatch, calls):
    body = json.loads(FIXTURE.read_text())
    monkeypatch.setattr(svc, "decompose_image", lambda url: body)
    monkeypatch.setattr(
        svc, "mirror_url",
        lambda vendor_url, job_id, file_name: f"https://our-s3/{job_id}/{file_name}",
    )
    monkeypatch.setattr(svc, "post_completed", lambda **kw: calls.append(kw))


def test_identity_is_seeded_before_the_vendor_call(monkeypatch):
    # Without this the $ai_generation from decompose_image attributes to an
    # anonymous person: bind_ai_context only sees the request body, and the
    # vendor call runs later in a BackgroundTask.
    seen = {}
    monkeypatch.setattr(svc, "set_ai_context", lambda **kw: seen.update(kw))
    monkeypatch.setattr(svc, "decompose_image", lambda url: json.loads(FIXTURE.read_text()))
    monkeypatch.setattr(svc, "mirror_url", lambda **kw: "https://our-s3/x.png")
    monkeypatch.setattr(svc, "post_completed", lambda **kw: None)

    svc.process_layer_decompose_job(LayerDecomposeJobRequest(
        decomposition_id="d1", source_image_url="https://example.com/kv.png",
        user_id="u1", workspace_id="w1", workspace_name="Acme",
    ))

    assert seen["user_id"] == "u1"
    assert seen["workspace_id"] == "w1"
    assert seen["workspace_name"] == "Acme"


def test_successful_job_posts_done_with_mirrored_urls(monkeypatch):
    calls = []
    _patch_happy(monkeypatch, calls)

    svc.process_layer_decompose_job(_req())

    assert len(calls) == 1
    kw = calls[0]
    assert kw["status"] == "done"
    assert kw["decomposition_id"] == "d1"
    assert kw["base_image_url"] == "https://our-s3/d1/base.png"
    assert [l["z"] for l in kw["layers"]] == [1, 3, 7]
    # No vendor URL may survive into the callback.
    assert all("vendor.example" not in l["image_url"] for l in kw["layers"])
    assert all("vendor_url" not in l for l in kw["layers"])
    assert kw["model"] == "dola-seedream-5-0-pro-260628"
    assert kw["ai_service_run_id"]


def test_pixel_counts_are_base_first_then_layers_in_z_order(monkeypatch):
    calls = []
    _patch_happy(monkeypatch, calls)

    svc.process_layer_decompose_job(_req())

    # base 1536x1024, then z=1 766x982, z=3 720x232, z=7 386x877
    assert calls[0]["image_pixel_counts"] == [1572864, 752212, 167040, 338522]


def test_layer_file_names_are_stable_and_padded(monkeypatch):
    calls = []
    _patch_happy(monkeypatch, calls)

    svc.process_layer_decompose_job(_req())

    urls = [l["image_url"] for l in calls[0]["layers"]]
    assert urls[0].endswith("/layer_01.png")
    assert urls[2].endswith("/layer_07.png")


def test_vendor_failure_posts_failed(monkeypatch):
    calls = []
    monkeypatch.setattr(
        svc, "decompose_image",
        lambda url: (_ for _ in ()).throw(LayerDecomposeError("no_layers_detected")),
    )
    monkeypatch.setattr(svc, "post_completed", lambda **kw: calls.append(kw))

    svc.process_layer_decompose_job(_req())

    assert calls[0]["status"] == "failed"
    assert calls[0]["error_message"] == "no_layers_detected"


def test_mirror_failure_fails_the_whole_job(monkeypatch):
    calls = []
    body = json.loads(FIXTURE.read_text())
    monkeypatch.setattr(svc, "decompose_image", lambda url: body)
    monkeypatch.setattr(
        svc, "mirror_url",
        lambda **kw: (_ for _ in ()).throw(RuntimeError("s3 down")),
    )
    monkeypatch.setattr(svc, "post_completed", lambda **kw: calls.append(kw))

    svc.process_layer_decompose_job(_req())

    assert calls[0]["status"] == "failed"
    # A partial result must never be persisted.
    assert "layers" not in calls[0] or not calls[0].get("layers")


def test_an_unexpected_error_still_calls_back(monkeypatch):
    calls = []
    monkeypatch.setattr(
        svc, "decompose_image", lambda url: (_ for _ in ()).throw(ValueError("boom"))
    )
    monkeypatch.setattr(svc, "post_completed", lambda **kw: calls.append(kw))

    svc.process_layer_decompose_job(_req())

    assert len(calls) == 1
    assert calls[0]["status"] == "failed"
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd ai-service && .venv/bin/python -m pytest tests/agents/kv_layer_decompose/test_service.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.agents.kv_layer_decompose.service'`

- [ ] **Step 4: Write the orchestrator**

Create `app/agents/kv_layer_decompose/service.py`:

```python
"""Layer-decomposition orchestrator (runs in BackgroundTasks)."""
import logging
from uuid import uuid4

from app.agents.kv_layer_decompose.api_client import post_completed
from app.agents.kv_layer_decompose.client import decompose_image
from app.agents.kv_layer_decompose.mapping import pixel_count, split_response, to_layer
from app.agents.kv_layer_decompose.mirror import mirror_url
from app.agents.kv_layer_decompose.request_schema import LayerDecomposeJobRequest
from app.observability.context import set_ai_context
from app.utils.config import settings

logger = logging.getLogger(__name__)


def process_layer_decompose_job(req: LayerDecomposeJobRequest) -> None:
    ai_service_run_id = str(uuid4())
    job_id = req.decomposition_id

    # Re-seed identity inside the background task. Contextvars do propagate
    # from the scheduling request, but that request's body is the only source
    # and this is where the values become available — setting them explicitly
    # is what makes the $ai_generation attribute to a real person and the
    # workspace group instead of an anonymous trace id.
    set_ai_context(
        user_id=req.user_id,
        user_email=req.user_email,
        workspace_id=req.workspace_id,
        workspace_name=req.workspace_name,
        brand_id=req.brand_id,
        brand_name=req.brand_name,
    )

    try:
        body = decompose_image(req.source_image_url)
        base_entry, layer_entries = split_response(body)

        # Mirror everything BEFORE reporting anything. Vendor URLs die in 24h,
        # and a half-mirrored result is worse than a clean failure: the user
        # would get a board with some layers silently missing.
        base_image_url = mirror_url(base_entry["url"], job_id, "base.png")

        layers = []
        pixel_counts = [pixel_count(base_entry)]
        for entry in layer_entries:
            layer = to_layer(entry)
            vendor_url = layer.pop("vendor_url")
            layer["image_url"] = mirror_url(
                vendor_url, job_id, f"layer_{layer['z']:02d}.png"
            )
            layers.append(layer)
            pixel_counts.append(pixel_count(entry))

        post_completed(
            decomposition_id=job_id,
            status="done",
            base_image_url=base_image_url,
            layers=layers,
            image_pixel_counts=pixel_counts,
            ai_service_run_id=ai_service_run_id,
            model=settings.BYTEPLUS_SEEDREAM_LAYER_MODEL,
        )
    except Exception as exc:  # noqa: BLE001 — the callback must always fire
        logger.error("[kv_layer_decompose] job %s failed: %r", job_id, exc)
        post_completed(
            decomposition_id=job_id, status="failed", error_message=str(exc)[:500]
        )
```

- [ ] **Step 5: Run the service tests to verify they pass**

Run: `cd ai-service && .venv/bin/python -m pytest tests/agents/kv_layer_decompose/test_service.py -v`
Expected: 7 passed

- [ ] **Step 6: Write the failing router test**

Create `tests/agents/kv_layer_decompose/test_router.py`:

```python
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.agents.kv_layer_decompose import router as router_mod


def test_post_returns_202_and_queues_the_job(monkeypatch):
    queued = []
    monkeypatch.setattr(
        router_mod, "process_layer_decompose_job", lambda req: queued.append(req)
    )

    app = FastAPI()
    app.include_router(router_mod.router)
    client = TestClient(app)

    resp = client.post(
        "/ai/kv-layer-decompose",
        json={"decomposition_id": "d1", "source_image_url": "https://example.com/kv.png"},
    )

    assert resp.status_code == 202
    assert resp.json() == {"decomposition_id": "d1", "status": "accepted"}
    assert len(queued) == 1
    assert queued[0].decomposition_id == "d1"


def test_post_rejects_a_body_with_no_source_image():
    app = FastAPI()
    app.include_router(router_mod.router)
    client = TestClient(app)

    resp = client.post("/ai/kv-layer-decompose", json={"decomposition_id": "d1"})

    assert resp.status_code == 422
```

- [ ] **Step 7: Run it to verify it fails**

Run: `cd ai-service && .venv/bin/python -m pytest tests/agents/kv_layer_decompose/test_router.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.agents.kv_layer_decompose.router'`

- [ ] **Step 8: Write the router**

Create `app/agents/kv_layer_decompose/router.py`:

```python
from fastapi import APIRouter, BackgroundTasks
from fastapi.responses import JSONResponse

from app.agents.kv_layer_decompose.request_schema import LayerDecomposeJobRequest
from app.agents.kv_layer_decompose.response_schema import LayerDecomposeAccepted
from app.agents.kv_layer_decompose.service import process_layer_decompose_job

router = APIRouter(prefix="/ai/kv-layer-decompose", tags=["kv-layer-decompose"])


@router.post("", response_model=LayerDecomposeAccepted, status_code=202)
def decompose(req: LayerDecomposeJobRequest, background: BackgroundTasks):
    background.add_task(process_layer_decompose_job, req)
    return JSONResponse(
        status_code=202,
        content=LayerDecomposeAccepted(decomposition_id=req.decomposition_id).model_dump(),
    )
```

- [ ] **Step 9: Register the router in main.py**

In `main.py`, add the import beside the other KV routers (near line 21):

```python
from app.agents.kv_layer_decompose.router import router as kv_layer_decompose_router
```

and the registration beside the other `app.include_router(kv_*)` calls (near line 111):

```python
app.include_router(kv_layer_decompose_router)
```

- [ ] **Step 10: Run the router tests and confirm the app boots**

Run: `cd ai-service && .venv/bin/python -m pytest tests/agents/kv_layer_decompose/ -v`
Expected: all pass

Run: `cd ai-service && .venv/bin/python -c "import main; print([r.path for r in main.app.routes if 'layer-decompose' in r.path])"`
Expected: `['/ai/kv-layer-decompose']`

- [ ] **Step 11: Commit**

```bash
git add app/agents/kv_layer_decompose/ main.py tests/agents/kv_layer_decompose/
git commit -m "feat(ai): kv-layer-decompose job route + orchestrator"
```

---

### Task 6: Synchronous flatten endpoint

At commit time the user has selected a subset of layers. The layers they did
NOT select must be composited back onto the clean plate, or the new board loses
those elements entirely — pick only the tube and the woman vanishes. This is a
deterministic composite with no model call, so it is synchronous.

**Files:**
- Create: `ai-service/app/agents/kv_layer_decompose/flatten.py`
- Modify: `ai-service/app/agents/kv_layer_decompose/request_schema.py` (append)
- Modify: `ai-service/app/agents/kv_layer_decompose/response_schema.py` (append)
- Modify: `ai-service/app/agents/kv_layer_decompose/router.py` (append route)
- Test: `ai-service/tests/agents/kv_layer_decompose/test_flatten.py`

**Interfaces:**
- Consumes: `mirror_url`'s sibling helper — this task adds its own downloader; `save_bytes_to_file`.
- Produces:
  - `FlattenRequest{decomposition_id: str, base_image_url: str, layers: list[FlattenLayer]}` where `FlattenLayer{z: int, image_url: str, x: float, y: float, width: float, height: float}` — **only the layers to bake in** are sent; api filters before calling.
  - `FlattenResult{image_url: str}`
  - `composite_layers(base: PIL.Image, layers: list[dict]) -> PIL.Image`
  - route `POST /ai/kv-layer-decompose/flatten` → 200

- [ ] **Step 1: Write the failing tests**

Create `tests/agents/kv_layer_decompose/test_flatten.py`:

```python
from PIL import Image

from app.agents.kv_layer_decompose.flatten import composite_layers


def _solid(w, h, color):
    return Image.new("RGBA", (w, h), color)


def test_layer_is_scaled_to_its_bbox_not_pasted_at_file_size():
    # The vendor returns layer PNGs LARGER than their bounding box — a 386x877
    # file for a 128x293 box. Pasting at file size puts pixels in the wrong
    # place, so the composite must resize first.
    base = _solid(100, 100, (0, 0, 0, 255))
    layer_img = _solid(80, 80, (255, 0, 0, 255))

    out = composite_layers(base, [{
        "z": 1, "x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2,
        "image": layer_img,
    }])

    # Box is (10,10)-(30,30). Inside is red, just outside stays black.
    assert out.getpixel((20, 20))[:3] == (255, 0, 0)
    assert out.getpixel((5, 5))[:3] == (0, 0, 0)
    assert out.getpixel((35, 35))[:3] == (0, 0, 0)


def test_layers_composite_in_ascending_z_order():
    base = _solid(50, 50, (0, 0, 0, 255))
    lower = _solid(10, 10, (255, 0, 0, 255))
    upper = _solid(10, 10, (0, 255, 0, 255))

    # Deliberately supplied out of order — the function must sort.
    out = composite_layers(base, [
        {"z": 2, "x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0, "image": upper},
        {"z": 1, "x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0, "image": lower},
    ])

    assert out.getpixel((25, 25))[:3] == (0, 255, 0)


def test_alpha_is_respected_rather_than_replaced():
    base = _solid(20, 20, (0, 0, 255, 255))
    transparent = _solid(10, 10, (255, 0, 0, 0))

    out = composite_layers(base, [
        {"z": 1, "x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0, "image": transparent},
    ])

    assert out.getpixel((10, 10))[:3] == (0, 0, 255)


def test_an_empty_layer_list_returns_the_base_unchanged():
    base = _solid(10, 10, (7, 8, 9, 255))
    out = composite_layers(base, [])
    assert out.getpixel((5, 5))[:3] == (7, 8, 9)


def test_a_zero_width_box_is_skipped_rather_than_crashing():
    base = _solid(10, 10, (0, 0, 0, 255))
    layer_img = _solid(5, 5, (255, 255, 255, 255))

    out = composite_layers(base, [
        {"z": 1, "x": 0.5, "y": 0.5, "width": 0.0, "height": 0.2, "image": layer_img},
    ])

    assert out.getpixel((5, 5))[:3] == (0, 0, 0)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ai-service && .venv/bin/python -m pytest tests/agents/kv_layer_decompose/test_flatten.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.agents.kv_layer_decompose.flatten'`

- [ ] **Step 3: Write the implementation**

Create `app/agents/kv_layer_decompose/flatten.py`:

```python
"""Bake layers back into the clean plate.

Used at commit time for the layers the user did NOT select: without this the
new board silently loses every element they left unchecked.
"""
import logging
from io import BytesIO
from typing import Any, Dict, List
from uuid import uuid4

import httpx
from PIL import Image

from app.tools.edit_image import save_bytes_to_file
from app.utils.config import settings

logger = logging.getLogger(__name__)

_DOWNLOAD_TIMEOUT_SEC = 120.0


def composite_layers(base: Image.Image, layers: List[Dict[str, Any]]) -> Image.Image:
    """Alpha-composite `layers` onto a copy of `base`, ascending by z.

    Geometry is normalized 0..1 against the base. Each layer's PNG is resized
    to its box first: the vendor returns files LARGER than their bounding box
    (a 386x877 file for a 128x293 box), so pasting at native size misplaces
    every pixel.
    """
    canvas = base.convert("RGBA").copy()
    cw, ch = canvas.size

    for layer in sorted(layers, key=lambda l: l.get("z", 0)):
        left = int(round(layer["x"] * cw))
        top = int(round(layer["y"] * ch))
        width = int(round(layer["width"] * cw))
        height = int(round(layer["height"] * ch))
        if width <= 0 or height <= 0:
            logger.warning("[kv_layer_decompose] skipping z=%s: empty box", layer.get("z"))
            continue
        img = layer["image"].convert("RGBA").resize((width, height), Image.LANCZOS)
        canvas.alpha_composite(img, (left, top))

    return canvas


def _download_image(url: str) -> Image.Image:
    with httpx.Client(timeout=_DOWNLOAD_TIMEOUT_SEC) as client:
        resp = client.get(url)
    resp.raise_for_status()
    return Image.open(BytesIO(resp.content))


def flatten_to_url(decomposition_id: str, base_image_url: str,
                   layers: List[Dict[str, Any]]) -> str:
    base = _download_image(base_image_url)
    hydrated = [{**l, "image": _download_image(l["image_url"])} for l in layers]
    composed = composite_layers(base, hydrated)

    buf = BytesIO()
    composed.convert("RGB").save(buf, format="PNG")
    return save_bytes_to_file(
        image_bytes=buf.getvalue(),
        temp_folder_path="./temp",
        destination_path=f"{settings.API_ENV}/kv-layer-decompose/{decomposition_id}",
        file_name=f"flattened_{uuid4()}.png",
    )
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ai-service && .venv/bin/python -m pytest tests/agents/kv_layer_decompose/test_flatten.py -v`
Expected: 5 passed

- [ ] **Step 5: Add the schemas and the route**

Append to `app/agents/kv_layer_decompose/request_schema.py`:

```python
from typing import List


class FlattenLayer(BaseModel):
    z: int
    image_url: str
    x: float
    y: float
    width: float
    height: float


class FlattenRequest(BaseModel):
    decomposition_id: str
    base_image_url: str
    # ONLY the layers to bake in. api sends the ones the user did NOT select;
    # sending all of them would duplicate the selected layers into the plate.
    layers: List[FlattenLayer] = []
```

Append to `app/agents/kv_layer_decompose/response_schema.py`:

```python
class FlattenResult(BaseModel):
    image_url: str
```

Append to `app/agents/kv_layer_decompose/router.py` (and extend its imports):

```python
@router.post("/flatten", response_model=FlattenResult)
def flatten(req: FlattenRequest):
    url = flatten_to_url(
        req.decomposition_id,
        req.base_image_url,
        [l.model_dump() for l in req.layers],
    )
    return FlattenResult(image_url=url)
```

Update the import lines at the top of `router.py`:

```python
from app.agents.kv_layer_decompose.flatten import flatten_to_url
from app.agents.kv_layer_decompose.request_schema import (
    FlattenRequest,
    LayerDecomposeJobRequest,
)
from app.agents.kv_layer_decompose.response_schema import (
    FlattenResult,
    LayerDecomposeAccepted,
)
```

- [ ] **Step 6: Add a route test**

Append to `tests/agents/kv_layer_decompose/test_router.py`:

```python
def test_flatten_returns_the_composited_url(monkeypatch):
    monkeypatch.setattr(
        router_mod, "flatten_to_url",
        lambda did, base, layers: f"https://our-s3/{did}/flat.png",
    )

    app = FastAPI()
    app.include_router(router_mod.router)
    client = TestClient(app)

    resp = client.post("/ai/kv-layer-decompose/flatten", json={
        "decomposition_id": "d1",
        "base_image_url": "https://our-s3/base.png",
        "layers": [{"z": 1, "image_url": "https://our-s3/l1.png",
                    "x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2}],
    })

    assert resp.status_code == 200
    assert resp.json() == {"image_url": "https://our-s3/d1/flat.png"}


def test_flatten_accepts_an_empty_layer_list(monkeypatch):
    seen = {}
    monkeypatch.setattr(
        router_mod, "flatten_to_url",
        lambda did, base, layers: seen.setdefault("layers", layers) or "https://our-s3/f.png",
    )

    app = FastAPI()
    app.include_router(router_mod.router)
    client = TestClient(app)

    resp = client.post("/ai/kv-layer-decompose/flatten", json={
        "decomposition_id": "d1", "base_image_url": "https://our-s3/base.png",
    })

    assert resp.status_code == 200
    assert seen["layers"] == []
```

- [ ] **Step 7: Run the full module suite**

Run: `cd ai-service && .venv/bin/python -m pytest tests/agents/kv_layer_decompose/ -v`
Expected: all pass (25 tests)

- [ ] **Step 8: Commit**

```bash
git add app/agents/kv_layer_decompose/ tests/agents/kv_layer_decompose/
git commit -m "feat(ai): synchronous flatten endpoint for layer commit"
```

---

## Manual verification (once a team BytePlus key exists)

The unit tests never touch the vendor. Before calling this done, run one real
decomposition end to end:

```bash
cd ai-service && BYTEPLUS_ARK_API_KEY=<real key> .venv/bin/python -c "
from app.agents.kv_layer_decompose.client import decompose_image
from app.agents.kv_layer_decompose.mapping import split_response, to_layer
body = decompose_image('https://<a real KV url>.png')
base, layers = split_response(body)
print('base', base['size'], 'layers', len(layers))
for l in layers: print(to_layer(l)['name'], to_layer(l)['x'], to_layer(l)['width'])
"
```

Expect ~110 s, a base at the source's own dimensions, and plausible names. If
this returns a single image with no `z_index`, the model id is wrong — no other
Seedream version supports layer decomposition.
