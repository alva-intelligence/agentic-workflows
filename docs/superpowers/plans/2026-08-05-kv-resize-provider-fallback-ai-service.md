# KV Resize Gemini Fallback — Implementation Plan (ai-service)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep KV Resize exports working when the OpenAI credit balance is exhausted, by failing both of its OpenAI calls over to Gemini.

**Architecture:** A shared classifier tells "billing/auth failure, will never clear" apart from "transient, retry works". Both KV Resize OpenAI call sites — the `gpt-4o-mini` vision prepass and the `gpt-image-2` image edit — catch the former and retry once against Gemini. Gemini accepts no inpainting mask, so `outpaint`'s byte-identical preservation contract is re-created locally: the model fills the whole frame, then the original source region is pasted back over the result. Dispatch mirrors the existing primary→fallback pattern in `app/tools/upscale_image.py`.

**Tech Stack:** Python 3, pytest 9.0.3, google-genai 1.56.0, openai 2.33.0, Pillow 12.2.0, pydantic-settings.

**Spec:** `docs/superpowers/specs/2026-08-05-kv-resize-provider-fallback-design.md`

## Global Constraints

- **ai-service only.** No api or web changes in this plan. The Gemini models are already priced in the api registry.
- **Model strings must match the api pricing registry exactly** — `gemini-3-pro-image-preview` and `gemini-3.5-flash` (`api/app/Helpers/LLMHelper.php`). A mismatch makes `getModelPricing` return null, costs compute to zero, and exports silently become free.
- **Fall back only on quota/auth errors.** `429 rate_limit_exceeded`, 5xx, and gateway timeouts (520/524) keep today's retry-and-recover behavior.
- **If Gemini also fails, re-raise the ORIGINAL OpenAI exception** so the failed export reports the real cause.
- **No live API calls in tests.** Mock `genai.Client` and `requests.post`; build fixtures as small in-memory PIL images.
- **Setting name is `KV_RESIZE_AI_PROVIDER`** with vocab `auto` (default) / `openai` / `gemini`. It governs BOTH KV Resize OpenAI calls. (The spec's section 4 called this `KV_RESIZE_IMAGE_PROVIDER`; Task 8 amends the spec — one knob, one credit balance.)
- **Run tests from `ai-service/` with the venv active:** `source .venv/bin/activate`. Never `uv sync` — this service installs from `requirements.txt`.
- **Pre-existing test baseline:** ~16 failures already exist at HEAD in `tests/agents/chat_agent/` and `tests/agents/kv_generator/`. They are unrelated to this work. Do not try to fix them; do not count them as regressions.

## File Structure

| File | Responsibility |
|------|----------------|
| `app/utils/provider_errors.py` (create) | Classify OpenAI failures; define the typed `OpenAIQuotaExhausted` exception. No provider logic. |
| `app/tools/gemini_outpaint.py` (create) | Gemini image primitives for KV Resize: aspect selection, mask-region derivation, the re-paste, telemetry. Knows nothing about OpenAI. |
| `app/tools/outpaint_image.py` (modify) | Unchanged OpenAI primitives + the new primary→fallback dispatch in `outpaint()` / `reframe()`. |
| `app/agents/kv_resize/vision_prepass.py` (modify) | Same `VisionResult` contract, now with an OpenAI→Gemini path and a third return value naming the model used. |
| `app/agents/kv_resize/service.py` (modify) | Unpack the 3-tuple; report the real vision model to metering. |
| `app/utils/config.py`, `.env.example` (modify) | The `KV_RESIZE_AI_PROVIDER` switch. |

Import direction is one-way: `outpaint_image` → `gemini_outpaint` → `provider_errors`. `gemini_outpaint` must NOT import from `outpaint_image` (circular).

---

### Task 1: Foundations — quota classifier and provider switch

**Files:**
- Create: `app/utils/provider_errors.py`
- Modify: `app/utils/config.py` (add setting after the OpenAI block, ~line 29)
- Modify: `.env.example`
- Test: `tests/utils/test_provider_errors.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `OpenAIQuotaExhausted(RuntimeError)`; `is_openai_quota_error(status: int | None, body: str) -> bool`; `settings.KV_RESIZE_AI_PROVIDER: str`.

- [ ] **Step 1: Write the failing test**

Create `tests/utils/test_provider_errors.py`:

```python
import pytest

from app.utils.provider_errors import OpenAIQuotaExhausted, is_openai_quota_error


@pytest.mark.parametrize(
    "status,body,expected",
    [
        # The live failure: 429 + insufficient_quota / credit_balance_exhausted.
        (429, "{'type': 'insufficient_quota', 'code': 'credit_balance_exhausted'}", True),
        # A plain rate limit clears on retry — must NOT trigger a fallback.
        (429, "{'type': 'requests', 'code': 'rate_limit_exceeded'}", False),
        # Bad/revoked key never fixes itself either.
        (401, "{'code': 'invalid_api_key'}", True),
        (429, "billing_hard_limit_reached", True),
        # Server-side errors are transient regardless of body text.
        (500, "insufficient_quota", False),
        (520, "<html>gateway</html>", False),
        # SDK exceptions may not expose a status code; classify on the body.
        (None, "Error code: 429 - {'type': 'insufficient_quota'}", True),
        (None, "connection reset by peer", False),
        # Empty/None bodies must not explode.
        (429, "", False),
    ],
)
def test_quota_classification(status, body, expected):
    assert is_openai_quota_error(status, body) is expected


def test_quota_exception_is_runtime_error():
    assert issubclass(OpenAIQuotaExhausted, RuntimeError)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `source .venv/bin/activate && python -m pytest tests/utils/test_provider_errors.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.utils.provider_errors'`

- [ ] **Step 3: Write minimal implementation**

Create `app/utils/provider_errors.py`:

```python
"""Provider-failure classification shared by KV Resize's OpenAI call sites.

Separates failures a retry can clear (rate limits, 5xx, gateway timeouts) from
failures that never clear on their own — an exhausted credit balance or a bad
key. Only the latter should trigger a provider fallback. Retrying them also
burns backoff for nothing: outpaint_image lists 429 in _TRANSIENT_STATUS, so
before this every quota error slept 2s + 4s + 8s before failing anyway.
"""

from typing import Optional


class OpenAIQuotaExhausted(RuntimeError):
    """OpenAI rejected the call for billing/auth reasons, not load.

    Carries the original status + body text in its message so a caller that
    re-raises it (Gemini fallback also failed) still reports the real cause.
    """


# Substrings OpenAI returns for "your account cannot make this call", as
# opposed to "you are going too fast". Matched case-insensitively against the
# response body / exception text.
_QUOTA_MARKERS = (
    "insufficient_quota",
    "credit_balance_exhausted",
    "billing_hard_limit_reached",
    "invalid_api_key",
)

# Statuses that can carry a quota/auth rejection. `None` is accepted because
# SDK exceptions do not always surface a status code, in which case the body
# text is the only signal available.
_QUOTA_STATUSES = (401, 429, None)


def is_openai_quota_error(status: Optional[int], body: str) -> bool:
    """True when this failure will not clear on retry and a fallback is warranted."""
    if status not in _QUOTA_STATUSES:
        return False
    return any(marker in str(body or "").lower() for marker in _QUOTA_MARKERS)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `source .venv/bin/activate && python -m pytest tests/utils/test_provider_errors.py -v`
Expected: PASS (10 passed)

- [ ] **Step 5: Add the provider switch**

In `app/utils/config.py`, directly after the `# OpenAI` block (`OPENAI_API_KEY`, ~line 29), add:

```python
    # KV Resize provider selection. "auto" runs OpenAI first and falls back to
    # Gemini on quota/auth errors; "openai" disables the fallback entirely;
    # "gemini" skips OpenAI so no round-trip is wasted while credits are out.
    # Governs BOTH KV Resize OpenAI calls (vision prepass + image edit).
    KV_RESIZE_AI_PROVIDER: str = "auto"
```

In `.env.example`, after the `OPENAI_API_KEY=` line, add:

```
# auto (default) | openai | gemini — see app/utils/config.py
KV_RESIZE_AI_PROVIDER=auto
```

- [ ] **Step 6: Verify the setting loads**

Run: `source .venv/bin/activate && python -c "from app.utils.config import settings; print(settings.KV_RESIZE_AI_PROVIDER)"`
Expected: `auto`

- [ ] **Step 7: Commit**

```bash
git add app/utils/provider_errors.py tests/utils/test_provider_errors.py app/utils/config.py .env.example
git commit -m "feat(kv-resize): classify OpenAI quota failures and add the provider switch"
```

---

### Task 2: Nearest supported Gemini aspect ratio

**Files:**
- Create: `app/tools/gemini_outpaint.py`
- Test: `tests/tools/test_gemini_outpaint.py`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `GEMINI_IMAGE_MODEL: str` (`"gemini-3-pro-image-preview"`); `_nearest_gemini_aspect(width: int, height: int) -> str`.

**Why this exists:** Gemini image models return one of a fixed set of aspect ratios, not arbitrary W×H. We pin the closest supported ratio, then resize to the exact target ourselves.

- [ ] **Step 1: Write the failing test**

Create `tests/tools/test_gemini_outpaint.py`:

```python
from app.tools.gemini_outpaint import GEMINI_IMAGE_MODEL, _nearest_gemini_aspect


def test_model_matches_api_pricing_registry():
    """Must match the value in api LLMHelper.php exactly — a mismatch makes
    getModelPricing return null and the export silently becomes free."""
    assert GEMINI_IMAGE_MODEL == "gemini-3-pro-image-preview"


def test_exact_ratios_map_to_themselves():
    assert _nearest_gemini_aspect(1080, 1080) == "1:1"
    assert _nearest_gemini_aspect(1920, 1080) == "16:9"
    assert _nearest_gemini_aspect(1080, 1920) == "9:16"
    assert _nearest_gemini_aspect(1080, 1350) == "4:5"


def test_odd_ratios_snap_to_the_closest_supported():
    # Instagram landscape 1.91:1 sits between 16:9 (1.78) and 21:9 (2.33).
    assert _nearest_gemini_aspect(1910, 1000) == "16:9"
    # A near-square banner snaps to 1:1, not to 4:3.
    assert _nearest_gemini_aspect(1000, 1010) == "1:1"


def test_extreme_wide_snaps_to_widest_supported():
    assert _nearest_gemini_aspect(3000, 1000) == "21:9"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `source .venv/bin/activate && python -m pytest tests/tools/test_gemini_outpaint.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.tools.gemini_outpaint'`

- [ ] **Step 3: Write minimal implementation**

Create `app/tools/gemini_outpaint.py`:

```python
"""Gemini fallback primitives for KV Resize.

Used when the OpenAI credit balance is exhausted (see
``app/utils/provider_errors.py``). Gemini accepts no inpainting mask, so
``outpaint_with_gemini`` re-creates ``outpaint``'s "source pixels survive
byte-identical" contract locally: the model fills the whole frame, then the
original source region is pasted back over the result.

Imports one way only: ``outpaint_image`` imports this module, never the
reverse — hence the local ``_png_bytes`` instead of reusing that module's.
"""

import logging
from typing import Optional

logger = logging.getLogger(__name__)

# Must match the api pricing registry value (api/app/Helpers/LLMHelper.php).
GEMINI_IMAGE_MODEL = "gemini-3-pro-image-preview"

# Aspect ratios Gemini's image models accept via image_config. Ordered widest
# tolerance first is irrelevant — selection is by numeric distance below.
_SUPPORTED_ASPECTS = (
    "1:1", "2:3", "3:2", "3:4", "4:3", "4:5", "5:4", "9:16", "16:9", "21:9",
)


def _nearest_gemini_aspect(width: int, height: int) -> str:
    """The supported aspect label numerically closest to width/height."""
    target = width / height

    def distance(label: str) -> float:
        w, h = label.split(":")
        return abs(int(w) / int(h) - target)

    return min(_SUPPORTED_ASPECTS, key=distance)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `source .venv/bin/activate && python -m pytest tests/tools/test_gemini_outpaint.py -v`
Expected: PASS (5 passed)

- [ ] **Step 5: Commit**

```bash
git add app/tools/gemini_outpaint.py tests/tools/test_gemini_outpaint.py
git commit -m "feat(kv-resize): pick the nearest Gemini-supported aspect ratio"
```

---

### Task 3: `reframe_with_gemini` — mask-free recomposition

**Files:**
- Modify: `app/tools/gemini_outpaint.py`
- Test: `tests/tools/test_gemini_outpaint.py`

**Interfaces:**
- Consumes: `GEMINI_IMAGE_MODEL`, `_nearest_gemini_aspect` (Task 2).
- Produces: `reframe_with_gemini(source: Image.Image, target_w: int, target_h: int, prompt: str) -> tuple[bytes, Dict[str, Any]]` — returns `(png_bytes, token_usage)`, matching `reframe_with_openai`'s shape. Also produces the private `_generate(prompt, image, aspect) -> tuple[bytes, Dict[str, Any]]` used by Task 4.

- [ ] **Step 1: Write the failing test**

Append to `tests/tools/test_gemini_outpaint.py`:

```python
from io import BytesIO
from unittest.mock import MagicMock, patch

from PIL import Image

from app.tools.gemini_outpaint import reframe_with_gemini


def _png_bytes_of(w: int, h: int, color=(0, 200, 100)) -> bytes:
    buf = BytesIO()
    Image.new("RGB", (w, h), color).save(buf, format="PNG")
    return buf.getvalue()


def _gemini_response(w: int, h: int, prompt_tokens=11, output_tokens=1290):
    """Mimic google-genai's response shape: candidates -> content -> parts,
    with the image on part.inline_data.data."""
    part = MagicMock()
    part.text = None
    part.inline_data.data = _png_bytes_of(w, h)
    candidate = MagicMock()
    candidate.finish_reason = None
    candidate.content.parts = [part]
    response = MagicMock()
    response.prompt_feedback = None
    response.candidates = [candidate]
    response.usage_metadata.prompt_token_count = prompt_tokens
    response.usage_metadata.candidates_token_count = output_tokens
    return response


@patch("app.tools.gemini_outpaint.capture_ai_generation")
@patch("app.tools.gemini_outpaint.genai.Client")
def test_reframe_returns_exact_target_dimensions(mock_client, _mock_capture):
    """Gemini returns a fixed aspect, so we must resize to the exact target."""
    mock_client.return_value.models.generate_content.return_value = _gemini_response(1024, 1024)

    out_bytes, _usage = reframe_with_gemini(
        Image.new("RGB", (1000, 1000), (255, 0, 0)), 1920, 1080, "fill it"
    )

    assert Image.open(BytesIO(out_bytes)).size == (1920, 1080)


@patch("app.tools.gemini_outpaint.capture_ai_generation")
@patch("app.tools.gemini_outpaint.genai.Client")
def test_reframe_pins_nearest_aspect_and_model(mock_client, _mock_capture):
    mock_client.return_value.models.generate_content.return_value = _gemini_response(1024, 1024)

    reframe_with_gemini(Image.new("RGB", (1000, 1000)), 1920, 1080, "fill it")

    kwargs = mock_client.return_value.models.generate_content.call_args.kwargs
    assert kwargs["model"] == "gemini-3-pro-image-preview"
    assert kwargs["config"].image_config.aspect_ratio == "16:9"


@patch("app.tools.gemini_outpaint.capture_ai_generation")
@patch("app.tools.gemini_outpaint.genai.Client")
def test_reframe_token_usage_matches_metering_shape(mock_client, _mock_capture):
    """Same dict shape outpaint_image emits, so api metering ingests it unchanged."""
    mock_client.return_value.models.generate_content.return_value = _gemini_response(
        1024, 1024, prompt_tokens=11, output_tokens=1290
    )

    _out, usage = reframe_with_gemini(Image.new("RGB", (1000, 1000)), 1920, 1080, "p")

    assert usage == {
        "type": "Image Generation",
        "model": "gemini-3-pro-image-preview",
        "input_text_tokens": 11,
        "input_image_tokens": 0,
        "output_image_tokens": 1290,
    }


@patch("app.tools.gemini_outpaint.capture_ai_generation")
@patch("app.tools.gemini_outpaint.genai.Client")
def test_reframe_raises_when_gemini_returns_no_candidates(mock_client, _mock_capture):
    """A safety block returns candidates=[] — must raise, not return junk."""
    response = MagicMock()
    response.prompt_feedback = None
    response.candidates = []
    mock_client.return_value.models.generate_content.return_value = response

    with pytest.raises(RuntimeError, match="no image"):
        reframe_with_gemini(Image.new("RGB", (1000, 1000)), 1920, 1080, "p")


@patch("app.tools.gemini_outpaint.capture_ai_generation")
@patch("app.tools.gemini_outpaint.genai.Client")
def test_reframe_reports_telemetry_as_gemini(mock_client, mock_capture):
    mock_client.return_value.models.generate_content.return_value = _gemini_response(1024, 1024)

    reframe_with_gemini(Image.new("RGB", (1000, 1000)), 1920, 1080, "p")

    assert mock_capture.call_args.kwargs["provider"] == "gemini"
    assert mock_capture.call_args.kwargs["model"] == "gemini-3-pro-image-preview"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `source .venv/bin/activate && python -m pytest tests/tools/test_gemini_outpaint.py -v`
Expected: FAIL — `ImportError: cannot import name 'reframe_with_gemini'`

- [ ] **Step 3: Write minimal implementation**

Replace the import block at the top of `app/tools/gemini_outpaint.py` with:

```python
import logging
import time
from io import BytesIO
from typing import Any, Dict, Optional

from google import genai
from google.genai import types as genai_types
from PIL import Image, ImageOps

from app.observability.ai_clients import capture_ai_generation
from app.utils.config import settings
```

Then append to the module:

```python
def _png_bytes(img: Image.Image) -> bytes:
    """Local copy — importing outpaint_image here would be circular."""
    buf = BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def _generate(
    prompt: str,
    image: Image.Image,
    aspect: str,
) -> tuple[bytes, Dict[str, Any]]:
    """One Gemini image call. Returns (raw_png_bytes, token_usage).

    Raises RuntimeError when Gemini returns no image — an empty candidate list
    (safety block) or a response carrying only text parts.
    """
    client = genai.Client(api_key=settings.GEMINI_API_KEY)
    start = time.time()
    response = client.models.generate_content(
        model=GEMINI_IMAGE_MODEL,
        contents=[prompt, image],
        config=genai_types.GenerateContentConfig(
            image_config=genai_types.ImageConfig(aspect_ratio=aspect),
        ),
    )
    capture_ai_generation(
        model=GEMINI_IMAGE_MODEL,
        provider="gemini",
        span_name="kv_resize_fallback",
        start_time=start,
    )

    image_bytes: Optional[bytes] = None
    if response.candidates and response.candidates[0].content:
        for part in response.candidates[0].content.parts or []:
            if part.inline_data is not None:
                image_bytes = part.inline_data.data
                break
    if not image_bytes:
        raise RuntimeError(
            f"Gemini returned no image for the KV resize fallback: {response!r}"[:500]
        )

    usage = getattr(response, "usage_metadata", None)
    token_usage = {
        "type": "Image Generation",
        "model": GEMINI_IMAGE_MODEL,
        "input_text_tokens": int(getattr(usage, "prompt_token_count", 0) or 0),
        "input_image_tokens": 0,
        "output_image_tokens": int(getattr(usage, "candidates_token_count", 0) or 0),
    }
    return image_bytes, token_usage


def reframe_with_gemini(
    source: Image.Image,
    target_w: int,
    target_h: int,
    prompt: str,
) -> tuple[bytes, Dict[str, Any]]:
    """Mask-free recomposition into a new aspect ratio — the Gemini twin of
    ``outpaint_image.reframe_with_openai``. Returns (png_bytes, token_usage).
    """
    raw, token_usage = _generate(
        prompt, source.convert("RGB"), _nearest_gemini_aspect(target_w, target_h)
    )
    out = Image.open(BytesIO(raw)).convert("RGB")
    if out.size != (target_w, target_h):
        out = out.resize((target_w, target_h), Image.LANCZOS)
    return _png_bytes(out), token_usage
```

Add `import pytest` to the top of the test file if it is not already there.

- [ ] **Step 4: Run tests to verify they pass**

Run: `source .venv/bin/activate && python -m pytest tests/tools/test_gemini_outpaint.py -v`
Expected: PASS (10 passed)

- [ ] **Step 5: Commit**

```bash
git add app/tools/gemini_outpaint.py tests/tools/test_gemini_outpaint.py
git commit -m "feat(kv-resize): add the Gemini reframe fallback primitive"
```

---

### Task 4: `outpaint_with_gemini` — mask semantics without a mask

**Files:**
- Modify: `app/tools/gemini_outpaint.py`
- Test: `tests/tools/test_gemini_outpaint.py`

**Interfaces:**
- Consumes: `_generate`, `_nearest_gemini_aspect`, `_png_bytes` (Tasks 2–3).
- Produces: `_preserve_box(mask: Image.Image) -> Optional[tuple[int, int, int, int]]`; `outpaint_with_gemini(canvas: Image.Image, mask: Image.Image, prompt: str) -> tuple[bytes, Dict[str, Any]]`.

**Why the re-paste:** `build_mask` (`app/agents/kv_resize/canvas.py:60`) paints white (255) everywhere and black (0) over `paste_box`. Inverting makes the preserved region the only non-zero pixels, so `getbbox()` returns exactly `paste_box` — which is why `outpaint()`'s signature does not need to change to carry it.

- [ ] **Step 1: Write the failing test**

Append to `tests/tools/test_gemini_outpaint.py`:

```python
from app.agents.kv_resize.canvas import build_mask
from app.tools.gemini_outpaint import _preserve_box, outpaint_with_gemini


def test_preserve_box_recovers_the_paste_box_that_built_the_mask():
    paste_box = (120, 60, 900, 500)
    assert _preserve_box(build_mask(1280, 720, paste_box)) == paste_box


def test_preserve_box_is_none_when_everything_is_paintable():
    assert _preserve_box(Image.new("L", (100, 100), 255)) is None


@patch("app.tools.gemini_outpaint.capture_ai_generation")
@patch("app.tools.gemini_outpaint.genai.Client")
def test_outpaint_preserves_the_source_region_byte_identically(mock_client, _mock_capture):
    """The whole point of the mask contract: pixels inside paste_box must come
    back untouched, even though Gemini regenerated the entire frame."""
    mock_client.return_value.models.generate_content.return_value = _gemini_response(
        1280, 720, prompt_tokens=5, output_tokens=100
    )
    paste_box = (100, 50, 500, 400)
    canvas = Image.new("RGB", (1280, 720), (10, 20, 30))
    # Distinctive block inside the preserved region.
    canvas.paste(Image.new("RGB", (400, 350), (200, 100, 50)), (100, 50))
    mask = build_mask(1280, 720, paste_box)

    out_bytes, _usage = outpaint_with_gemini(canvas, mask, "extend the scene")

    out = Image.open(BytesIO(out_bytes)).convert("RGB")
    assert out.size == (1280, 720)
    assert out.crop(paste_box).tobytes() == canvas.crop(paste_box).tobytes()


@patch("app.tools.gemini_outpaint.capture_ai_generation")
@patch("app.tools.gemini_outpaint.genai.Client")
def test_outpaint_keeps_the_generated_margins(mock_client, _mock_capture):
    """Outside paste_box we must keep Gemini's fill, not the padded canvas."""
    mock_client.return_value.models.generate_content.return_value = _gemini_response(
        1280, 720, prompt_tokens=5, output_tokens=100
    )
    canvas = Image.new("RGB", (1280, 720), (10, 20, 30))
    mask = build_mask(1280, 720, (100, 50, 500, 400))

    out_bytes, _usage = outpaint_with_gemini(canvas, mask, "extend the scene")

    out = Image.open(BytesIO(out_bytes)).convert("RGB")
    # _gemini_response fills with (0, 200, 100); the canvas margin is (10,20,30).
    assert out.getpixel((1200, 700)) == (0, 200, 100)


@patch("app.tools.gemini_outpaint.capture_ai_generation")
@patch("app.tools.gemini_outpaint.genai.Client")
def test_outpaint_uses_the_canvas_aspect(mock_client, _mock_capture):
    mock_client.return_value.models.generate_content.return_value = _gemini_response(1280, 720)

    outpaint_with_gemini(
        Image.new("RGB", (1080, 1350)), build_mask(1080, 1350, (10, 10, 200, 200)), "p"
    )

    kwargs = mock_client.return_value.models.generate_content.call_args.kwargs
    assert kwargs["config"].image_config.aspect_ratio == "4:5"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `source .venv/bin/activate && python -m pytest tests/tools/test_gemini_outpaint.py -v`
Expected: FAIL — `ImportError: cannot import name '_preserve_box'`

- [ ] **Step 3: Write minimal implementation**

Append to `app/tools/gemini_outpaint.py`:

```python
def _preserve_box(mask: Image.Image) -> Optional[tuple[int, int, int, int]]:
    """The region ``build_mask`` marked preserve, as (x1, y1, x2, y2).

    build_mask paints white (255) = paint everywhere and black (0) = preserve
    over paste_box (app/agents/kv_resize/canvas.py). Inverting makes the
    preserved region the only non-zero pixels, so getbbox() returns exactly
    paste_box. Returns None for an all-white mask (paint everything).
    """
    return ImageOps.invert(mask.convert("L")).getbbox()


def outpaint_with_gemini(
    canvas: Image.Image,
    mask: Image.Image,
    prompt: str,
) -> tuple[bytes, Dict[str, Any]]:
    """Mask-based outpaint via a model that has no mask input.

    Gemini fills the whole frame, then the original source region is pasted
    back over the result — reproducing the guarantee gpt-image-2's alpha mask
    gave us: pixels inside paste_box are byte-identical to the input canvas.
    The seam where Gemini's fill meets that region will be less clean than
    native masked inpainting; that is the accepted cost of the fallback.

    Returns (png_bytes, token_usage), matching outpaint_with_openai_mask.
    """
    target_w, target_h = canvas.size
    source = canvas.convert("RGB")

    raw, token_usage = _generate(
        prompt, source, _nearest_gemini_aspect(target_w, target_h)
    )
    out = Image.open(BytesIO(raw)).convert("RGB")
    if out.size != (target_w, target_h):
        out = out.resize((target_w, target_h), Image.LANCZOS)

    box = _preserve_box(mask)
    if box is not None:
        out.paste(source.crop(box), (box[0], box[1]))
    else:
        logger.warning(
            "KV resize Gemini outpaint: mask preserves nothing; returning the "
            "generated frame as-is"
        )
    return _png_bytes(out), token_usage
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `source .venv/bin/activate && python -m pytest tests/tools/test_gemini_outpaint.py -v`
Expected: PASS (15 passed)

- [ ] **Step 5: Commit**

```bash
git add app/tools/gemini_outpaint.py tests/tools/test_gemini_outpaint.py
git commit -m "feat(kv-resize): reproduce mask preservation in the Gemini outpaint path"
```

---

### Task 5: Dispatch — fail over instead of retrying quota errors

**Files:**
- Modify: `app/tools/outpaint_image.py` (`_call_openai_edits` ~line 75, `outpaint` ~line 218, `reframe` ~line 234)
- Test: `tests/tools/test_outpaint_image.py`

**Interfaces:**
- Consumes: `OpenAIQuotaExhausted`, `is_openai_quota_error` (Task 1); `outpaint_with_gemini`, `reframe_with_gemini`, `GEMINI_IMAGE_MODEL` (Tasks 3–4); `settings.KV_RESIZE_AI_PROVIDER` (Task 1).
- Produces: unchanged public signatures — `outpaint(canvas, mask, prompt) -> tuple[bytes, str, Dict[str, Any]]` and `reframe(source, target_w, target_h, prompt) -> tuple[bytes, str, Dict[str, Any]]`, where the middle value is now the model actually used.

- [ ] **Step 1: Write the failing test**

Append to `tests/tools/test_outpaint_image.py`:

```python
import pytest

from app.utils.provider_errors import OpenAIQuotaExhausted


def _quota_response():
    return MagicMock(
        ok=False,
        status_code=429,
        text=(
            "{'error': {'message': 'You have no credits remaining.', "
            "'type': 'insufficient_quota', 'code': 'credit_balance_exhausted'}}"
        ),
    )


@patch("app.tools.outpaint_image.time.sleep")
@patch("app.tools.outpaint_image.requests.post")
def test_quota_error_fails_over_immediately_without_retrying(mock_post, mock_sleep):
    """429 is in _TRANSIENT_STATUS, but a quota error never clears — retrying
    it just burned 2s+4s+8s of backoff before failing anyway."""
    mock_post.return_value = _quota_response()

    with pytest.raises(OpenAIQuotaExhausted):
        outpaint_with_openai_mask(_make_canvas(1280, 720), _make_mask(1280, 720), "p")

    assert mock_post.call_count == 1
    mock_sleep.assert_not_called()


@patch("app.tools.outpaint_image.time.sleep")
@patch("app.tools.outpaint_image.requests.post")
def test_plain_rate_limit_still_retries(mock_post, _mock_sleep):
    """A non-quota 429 must keep today's retry behavior."""
    mock_post.return_value = MagicMock(
        ok=False, status_code=429, text="{'code': 'rate_limit_exceeded'}"
    )

    with pytest.raises(RuntimeError):
        outpaint_with_openai_mask(_make_canvas(1280, 720), _make_mask(1280, 720), "p")

    assert mock_post.call_count == 4  # initial + _MAX_RETRIES


@patch("app.tools.outpaint_image.outpaint_with_gemini")
@patch("app.tools.outpaint_image.outpaint_with_openai_mask")
def test_outpaint_falls_back_to_gemini_on_quota(mock_openai, mock_gemini):
    mock_openai.side_effect = OpenAIQuotaExhausted("429 insufficient_quota")
    mock_gemini.return_value = (b"png", {"model": "gemini-3-pro-image-preview"})

    image_bytes, model, usage = outpaint(_make_canvas(64, 64), _make_mask(64, 64), "p")

    assert image_bytes == b"png"
    assert model == "gemini-3-pro-image-preview"
    assert usage["model"] == "gemini-3-pro-image-preview"


@patch("app.tools.outpaint_image.reframe_with_gemini")
@patch("app.tools.outpaint_image.reframe_with_openai")
def test_reframe_falls_back_to_gemini_on_quota(mock_openai, mock_gemini):
    mock_openai.side_effect = OpenAIQuotaExhausted("429 insufficient_quota")
    mock_gemini.return_value = (b"png", {})

    _bytes, model, _usage = reframe(_make_canvas(64, 64), 1920, 1080, "p")

    assert model == "gemini-3-pro-image-preview"


@patch("app.tools.outpaint_image.outpaint_with_gemini")
@patch("app.tools.outpaint_image.outpaint_with_openai_mask")
def test_original_openai_error_is_reraised_when_gemini_also_fails(mock_openai, mock_gemini):
    """The export's failure message must name the real cause (no credits),
    not a downstream Gemini error."""
    mock_openai.side_effect = OpenAIQuotaExhausted("429 credit_balance_exhausted")
    mock_gemini.side_effect = RuntimeError("Gemini returned no image")

    with pytest.raises(OpenAIQuotaExhausted, match="credit_balance_exhausted"):
        outpaint(_make_canvas(64, 64), _make_mask(64, 64), "p")


@patch("app.tools.outpaint_image.settings")
@patch("app.tools.outpaint_image.outpaint_with_gemini")
@patch("app.tools.outpaint_image.outpaint_with_openai_mask")
def test_provider_openai_disables_the_fallback(mock_openai, mock_gemini, mock_settings):
    mock_settings.KV_RESIZE_AI_PROVIDER = "openai"
    mock_openai.side_effect = OpenAIQuotaExhausted("429 insufficient_quota")

    with pytest.raises(OpenAIQuotaExhausted):
        outpaint(_make_canvas(64, 64), _make_mask(64, 64), "p")

    mock_gemini.assert_not_called()


@patch("app.tools.outpaint_image.settings")
@patch("app.tools.outpaint_image.outpaint_with_gemini")
@patch("app.tools.outpaint_image.outpaint_with_openai_mask")
def test_provider_gemini_skips_openai_entirely(mock_openai, mock_gemini, mock_settings):
    mock_settings.KV_RESIZE_AI_PROVIDER = "gemini"
    mock_gemini.return_value = (b"png", {})

    _bytes, model, _usage = outpaint(_make_canvas(64, 64), _make_mask(64, 64), "p")

    assert model == "gemini-3-pro-image-preview"
    mock_openai.assert_not_called()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `source .venv/bin/activate && python -m pytest tests/tools/test_outpaint_image.py -v`
Expected: FAIL — `ImportError: cannot import name 'outpaint_with_gemini' from 'app.tools.outpaint_image'` and the quota tests failing on retry count.

- [ ] **Step 3: Add the imports**

In `app/tools/outpaint_image.py`, after `from app.utils.config import settings`:

```python
from app.tools.gemini_outpaint import (
    GEMINI_IMAGE_MODEL,
    outpaint_with_gemini,
    reframe_with_gemini,
)
from app.utils.provider_errors import OpenAIQuotaExhausted, is_openai_quota_error
```

- [ ] **Step 4: Classify before retrying**

In `_call_openai_edits`, inside the retry loop, immediately after the `requests.post(...)` assignment and BEFORE the `if response.ok or ...` break check, insert:

```python
        # Quota/auth rejections never clear — fail over now instead of
        # sleeping through the backoff ladder. Guarded on `not response.ok`
        # so a success response's body is never read.
        if not response.ok and is_openai_quota_error(response.status_code, response.text):
            raise OpenAIQuotaExhausted(
                f"OpenAI /v1/images/edits {response.status_code}: {response.text[:500]}"
            )
```

- [ ] **Step 5: Replace the dispatchers**

Replace the bodies of `outpaint` and `reframe` (keeping their docstrings, extended as shown):

```python
def outpaint(
    canvas: Image.Image,
    mask: Image.Image,
    prompt: str,
) -> tuple[bytes, str, Dict[str, Any]]:
    """Outpaint the masked region, gpt-image-2 primary with a Gemini fallback.

    Returns ``(image_bytes, model, token_usage)``. ``model`` names the provider
    that actually served the call, so api metering prices the right one.

    Falls back only on OpenAIQuotaExhausted (billing/auth). If Gemini also
    fails, the original OpenAI error is re-raised so the failed export reports
    the real cause.
    """
    if settings.KV_RESIZE_AI_PROVIDER == "gemini":
        image_bytes, token_usage = outpaint_with_gemini(canvas, mask, prompt)
        return image_bytes, GEMINI_IMAGE_MODEL, token_usage

    try:
        image_bytes, token_usage = outpaint_with_openai_mask(canvas, mask, prompt)
        return image_bytes, "gpt-image-2", token_usage
    except OpenAIQuotaExhausted as exc:
        if settings.KV_RESIZE_AI_PROVIDER == "openai":
            raise
        logger.warning(
            "KV resize outpaint: OpenAI quota exhausted (%s); falling back to %s",
            exc, GEMINI_IMAGE_MODEL,
        )
        try:
            image_bytes, token_usage = outpaint_with_gemini(canvas, mask, prompt)
        except Exception as fallback_exc:  # noqa: BLE001
            logger.error(
                "KV resize outpaint: Gemini fallback also failed (%r); "
                "re-raising the original OpenAI error", fallback_exc,
            )
            raise exc from fallback_exc
        return image_bytes, GEMINI_IMAGE_MODEL, token_usage


def reframe(
    source: Image.Image,
    target_w: int,
    target_h: int,
    prompt: str,
) -> tuple[bytes, str, Dict[str, Any]]:
    """Mask-free recomposition, gpt-image-2 primary with a Gemini fallback.

    Returns ``(image_bytes, model, token_usage)``. Same fallback rules as
    ``outpaint``.
    """
    if settings.KV_RESIZE_AI_PROVIDER == "gemini":
        image_bytes, token_usage = reframe_with_gemini(source, target_w, target_h, prompt)
        return image_bytes, GEMINI_IMAGE_MODEL, token_usage

    try:
        image_bytes, token_usage = reframe_with_openai(source, target_w, target_h, prompt)
        return image_bytes, "gpt-image-2", token_usage
    except OpenAIQuotaExhausted as exc:
        if settings.KV_RESIZE_AI_PROVIDER == "openai":
            raise
        logger.warning(
            "KV resize reframe: OpenAI quota exhausted (%s); falling back to %s",
            exc, GEMINI_IMAGE_MODEL,
        )
        try:
            image_bytes, token_usage = reframe_with_gemini(
                source, target_w, target_h, prompt
            )
        except Exception as fallback_exc:  # noqa: BLE001
            logger.error(
                "KV resize reframe: Gemini fallback also failed (%r); "
                "re-raising the original OpenAI error", fallback_exc,
            )
            raise exc from fallback_exc
        return image_bytes, GEMINI_IMAGE_MODEL, token_usage
```

Also update the module docstring's first line to note the Gemini fallback.

- [ ] **Step 6: Run tests to verify they pass**

Run: `source .venv/bin/activate && python -m pytest tests/tools/test_outpaint_image.py tests/tools/test_gemini_outpaint.py -v`
Expected: PASS — all pre-existing `test_outpaint_image.py` tests still green plus the 7 new ones.

- [ ] **Step 7: Commit**

```bash
git add app/tools/outpaint_image.py tests/tools/test_outpaint_image.py
git commit -m "feat(kv-resize): fail the image edit over to Gemini on OpenAI quota errors"
```

---

### Task 6: Vision prepass fallback

**Files:**
- Modify: `app/agents/kv_resize/vision_prepass.py`
- Test: `tests/agents/kv_resize/test_vision_prepass.py` (create)

**Interfaces:**
- Consumes: `OpenAIQuotaExhausted`, `is_openai_quota_error` (Task 1); `settings.KV_RESIZE_AI_PROVIDER`.
- Produces: `analyze(source_image_url: str) -> tuple[VisionResult | None, dict[str, int], str | None]` — **arity changed from 2 to 3**; the third value is the model used (`"gpt-4o-mini"`, `GEMINI_VISION_MODEL`, or `None` on failure). Also produces `GEMINI_VISION_MODEL: str` (`"gemini-3.5-flash"`).

- [ ] **Step 1: Write the failing test**

Create `tests/agents/kv_resize/test_vision_prepass.py`:

```python
import json
from unittest.mock import MagicMock, patch

import pytest

from app.agents.kv_resize.vision_prepass import (
    GEMINI_VISION_MODEL,
    VisionResult,
    analyze,
)
from app.utils.provider_errors import OpenAIQuotaExhausted

_VALID_PAYLOAD = json.dumps({
    "subject_bbox": {"x": 0.3, "y": 0.2, "w": 0.4, "h": 0.5},
    "content_type": "portrait_person",
    "has_visible_text": False,
    "context_hint": "studio portrait, soft key light",
    "text_content": [],
})


def test_vision_model_matches_api_pricing_registry():
    assert GEMINI_VISION_MODEL == "gemini-3.5-flash"


def _openai_response(payload: str, prompt_tokens=100, completion_tokens=40):
    response = MagicMock()
    response.choices = [MagicMock(message=MagicMock(content=payload))]
    response.usage.prompt_tokens = prompt_tokens
    response.usage.completion_tokens = completion_tokens
    return response


def _gemini_response(payload: str, prompt_tokens=90, candidates_tokens=30):
    response = MagicMock()
    response.text = payload
    response.usage_metadata.prompt_token_count = prompt_tokens
    response.usage_metadata.candidates_token_count = candidates_tokens
    return response


@patch("app.agents.kv_resize.vision_prepass.openai_client")
def test_openai_success_reports_gpt_4o_mini(mock_client):
    mock_client.return_value.chat.completions.create.return_value = _openai_response(
        _VALID_PAYLOAD
    )

    result, usage, model = analyze("data:image/png;base64,AAAA")

    assert isinstance(result, VisionResult)
    assert model == "gpt-4o-mini"
    assert usage["input_text_tokens"] == 100


@patch("app.agents.kv_resize.vision_prepass.genai.Client")
@patch("app.agents.kv_resize.vision_prepass.openai_client")
def test_quota_error_falls_back_to_gemini(mock_openai, mock_genai):
    mock_openai.return_value.chat.completions.create.side_effect = Exception(
        "Error code: 429 - {'type': 'insufficient_quota', "
        "'code': 'credit_balance_exhausted'}"
    )
    mock_genai.return_value.models.generate_content.return_value = _gemini_response(
        _VALID_PAYLOAD
    )

    result, usage, model = analyze("data:image/png;base64,AAAA")

    assert isinstance(result, VisionResult)
    assert result.content_type == "portrait_person"
    assert model == GEMINI_VISION_MODEL
    assert usage["input_text_tokens"] == 90
    assert usage["output_text_tokens"] == 30


@patch("app.agents.kv_resize.vision_prepass.genai.Client")
@patch("app.agents.kv_resize.vision_prepass.openai_client")
def test_non_quota_failure_does_not_call_gemini(mock_openai, mock_genai):
    """Today's degrade-to-legacy_smart_crop behavior must survive: a timeout or
    a malformed response would fail the same way on Gemini."""
    mock_openai.return_value.chat.completions.create.side_effect = Exception(
        "Connection timed out"
    )

    result, _usage, model = analyze("data:image/png;base64,AAAA")

    assert result is None
    assert model is None
    mock_genai.assert_not_called()


@patch("app.agents.kv_resize.vision_prepass.genai.Client")
@patch("app.agents.kv_resize.vision_prepass.openai_client")
def test_validation_failure_does_not_call_gemini(mock_openai, mock_genai):
    mock_openai.return_value.chat.completions.create.return_value = _openai_response(
        '{"subject_bbox": {"x": 5.0, "y": 0.2, "w": 0.4, "h": 0.5}}'
    )

    result, _usage, model = analyze("data:image/png;base64,AAAA")

    assert result is None
    assert model is None
    mock_genai.assert_not_called()


@patch("app.agents.kv_resize.vision_prepass.genai.Client")
@patch("app.agents.kv_resize.vision_prepass.openai_client")
def test_gemini_failure_degrades_instead_of_raising(mock_openai, mock_genai):
    """analyze() must never raise — the caller treats None as 'use the legacy
    strategy', and the image step still has its own fallback."""
    mock_openai.return_value.chat.completions.create.side_effect = Exception(
        "Error code: 429 - {'code': 'credit_balance_exhausted'}"
    )
    mock_genai.return_value.models.generate_content.side_effect = Exception("Gemini down")

    result, _usage, model = analyze("data:image/png;base64,AAAA")

    assert result is None
    assert model is None


@patch("app.agents.kv_resize.vision_prepass.genai.Client")
@patch("app.agents.kv_resize.vision_prepass.openai_client")
@patch("app.agents.kv_resize.vision_prepass.settings")
def test_provider_gemini_skips_openai(mock_settings, mock_openai, mock_genai):
    mock_settings.KV_RESIZE_AI_PROVIDER = "gemini"
    mock_genai.return_value.models.generate_content.return_value = _gemini_response(
        _VALID_PAYLOAD
    )

    _result, _usage, model = analyze("data:image/png;base64,AAAA")

    assert model == GEMINI_VISION_MODEL
    mock_openai.assert_not_called()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `source .venv/bin/activate && python -m pytest tests/agents/kv_resize/test_vision_prepass.py -v`
Expected: FAIL — `ImportError: cannot import name 'GEMINI_VISION_MODEL'`

- [ ] **Step 3: Write the implementation**

In `app/agents/kv_resize/vision_prepass.py`, extend the imports:

```python
import base64
import logging
from io import BytesIO
from typing import Any, Literal, Optional

import requests
from google import genai
from google.genai import types as genai_types
from PIL import Image
from pydantic import BaseModel, Field, ValidationError

from app.observability.ai_clients import (
    capture_ai_generation,
    openai_client,
    ph_ai_kwargs,
)
from app.utils.config import settings
from app.utils.provider_errors import OpenAIQuotaExhausted, is_openai_quota_error
```

Add the model constant next to `_logger`:

```python
# Must match the api pricing registry value (api/app/Helpers/LLMHelper.php).
GEMINI_VISION_MODEL = "gemini-3.5-flash"
```

Rename the existing `analyze` to `_analyze_with_openai`, keeping its body, and make these three changes inside it:

1. Return `(result, token_usage, "gpt-4o-mini")` on success.
2. Return `(None, token_usage, None)` at both existing early-return/except points.
3. In the final `except Exception` handler, re-raise quota errors instead of swallowing them:

```python
    except Exception as exc:  # noqa: BLE001
        if is_openai_quota_error(getattr(exc, "status_code", None), str(exc)):
            raise OpenAIQuotaExhausted(str(exc)) from exc
        _logger.warning(
            "vision_prepass: API call failed for data-url(len=%d): %s",
            len(source_image_url), exc,
        )
        return None, token_usage, None
```

Then append the Gemini path and the new dispatcher:

```python
def _load_image(source_image_url: str) -> Image.Image:
    """Decode the data: URL the service passes (or fetch an http(s) one)."""
    if source_image_url.startswith("data:"):
        _header, _, encoded = source_image_url.partition(",")
        return Image.open(BytesIO(base64.b64decode(encoded))).convert("RGB")
    response = requests.get(source_image_url, timeout=60)
    response.raise_for_status()
    return Image.open(BytesIO(response.content)).convert("RGB")


def _analyze_with_gemini(
    source_image_url: str,
) -> tuple[VisionResult | None, dict[str, int], str | None]:
    """Same contract as _analyze_with_openai, served by Gemini.

    Structured output comes from response_schema=VisionResult (google-genai
    accepts a pydantic model directly); the result is still validated our side
    so the caller's contract is identical either way.
    """
    client = genai.Client(api_key=settings.GEMINI_API_KEY)
    response = client.models.generate_content(
        model=GEMINI_VISION_MODEL,
        contents=[_SYSTEM_PROMPT, _load_image(source_image_url)],
        config=genai_types.GenerateContentConfig(
            temperature=0,
            response_mime_type="application/json",
            response_schema=VisionResult,
        ),
    )
    capture_ai_generation(
        model=GEMINI_VISION_MODEL,
        provider="gemini",
        span_name="kv_resize_vision_prepass_fallback",
    )

    usage = getattr(response, "usage_metadata", None)
    token_usage = {
        "input_text_tokens": int(getattr(usage, "prompt_token_count", 0) or 0),
        "input_image_tokens": 0,
        "output_image_tokens": 0,
        "output_text_tokens": int(getattr(usage, "candidates_token_count", 0) or 0),
    }
    raw = getattr(response, "text", None)
    if not raw:
        return None, token_usage, None
    return VisionResult.model_validate_json(raw), token_usage, GEMINI_VISION_MODEL


def analyze(
    source_image_url: str,
) -> tuple[VisionResult | None, dict[str, int], str | None]:
    """Single vision pass over the source image, gpt-4o-mini with a Gemini
    fallback on OpenAI quota/auth errors.

    `source_image_url` should be a `data:` URL of the ALREADY-downloaded
    source (see `service._to_data_url`), not the original remote URL — the
    service already fetched the image once for PIL processing, and handing
    OpenAI the same remote URL made it re-fetch our S3 object over the
    network a second time, independently. That extra hop was flaky (S3
    region / presigned-URL timing), and OpenAI's fetch failing here degraded
    every affected export to `legacy_smart_crop` (FRND-CHAT-SERVICE-7J). A
    plain http(s) URL still works if a caller passes one.

    Returns (result, token_usage, model). On any failure, result and model are
    None and the caller degrades to `legacy_smart_crop` — this function never
    raises. token_usage may still be non-empty if the API call returned tokens
    before validation failed; api side uses non-empty token_usage as the
    signal to write a CostHistory row, and `model` tells it what to price.
    """
    if settings.KV_RESIZE_AI_PROVIDER == "gemini":
        try:
            return _analyze_with_gemini(source_image_url)
        except Exception as exc:  # noqa: BLE001
            _logger.warning("vision_prepass: Gemini call failed: %r", exc)
            return None, {}, None

    try:
        return _analyze_with_openai(source_image_url)
    except OpenAIQuotaExhausted as exc:
        if settings.KV_RESIZE_AI_PROVIDER == "openai":
            _logger.warning("vision_prepass: OpenAI quota exhausted (%s)", exc)
            return None, {}, None
        _logger.warning(
            "vision_prepass: OpenAI quota exhausted (%s); falling back to %s",
            exc, GEMINI_VISION_MODEL,
        )
        try:
            return _analyze_with_gemini(source_image_url)
        except Exception as fallback_exc:  # noqa: BLE001
            _logger.warning(
                "vision_prepass: Gemini fallback also failed: %r", fallback_exc
            )
            return None, {}, None
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `source .venv/bin/activate && python -m pytest tests/agents/kv_resize/test_vision_prepass.py -v`
Expected: PASS (7 passed)

- [ ] **Step 5: Commit**

```bash
git add app/agents/kv_resize/vision_prepass.py tests/agents/kv_resize/test_vision_prepass.py
git commit -m "feat(kv-resize): fail the vision prepass over to Gemini on OpenAI quota errors"
```

---

### Task 7: Wire the real vision model through to metering

**Files:**
- Modify: `app/agents/kv_resize/service.py` (`process_resize_export` ~lines 168–290)
- Test: `tests/agents/kv_resize/test_service.py` (6 existing `mock_analyze.return_value` sites + 1 new test)

**Interfaces:**
- Consumes: the 3-tuple `analyze` from Task 6.
- Produces: `post_completed(..., vision_model=<model actually used>)`.

**Why:** `service.py:287` hardcodes `vision_model="gpt-4o-mini"`. Left as-is, a Gemini prepass would be priced as an OpenAI call.

- [ ] **Step 1: Update the existing mocks (they break on arity)**

In `tests/agents/kv_resize/test_service.py`, all six `mock_analyze.return_value`
lines become 3-tuples. Exact replacements:

| Line | Becomes |
|------|---------|
| 48 | `mock_analyze.return_value = (_vision(has_text=False), {"input_text_tokens": 1}, "gpt-4o-mini")` |
| 80 | `mock_analyze.return_value = (_vision(has_text=True), {}, "gpt-4o-mini")` |
| 113 | `mock_analyze.return_value = (_vision(has_text=True), {}, "gpt-4o-mini")` |
| 237 | `mock_analyze.return_value = (_vision(has_text=False), {}, "gpt-4o-mini")` |
| 270 | `mock_analyze.return_value = (_vision(has_text=True), {}, "gpt-4o-mini")` |
| 364 | `mock_analyze.return_value = (_vision(has_text=False), {}, "gpt-4o-mini")` |

Line numbers are from HEAD before this task's edits; if they have shifted, match
on the `mock_analyze.return_value` text instead.

- [ ] **Step 2: Add the new test**

Append to `tests/agents/kv_resize/test_service.py`:

```python
@patch("app.agents.kv_resize.service.requests.get")
@patch("app.agents.kv_resize.service.analyze")
@patch("app.agents.kv_resize.service.reframe")
@patch("app.agents.kv_resize.service.outpaint")
@patch("app.agents.kv_resize.service.save_bytes_to_file")
@patch("app.agents.kv_resize.service.post_completed")
def test_fallback_vision_model_is_reported_to_metering(
    mock_pc, mock_save, mock_outpaint, mock_reframe, mock_analyze, mock_get
):
    """A Gemini prepass must not be priced as gpt-4o-mini."""
    mock_get.return_value = MagicMock(
        ok=True, content=_png_bytes(1000, 1000), status_code=200
    )
    mock_analyze.return_value = (
        _vision(has_text=False), {"input_text_tokens": 90}, "gemini-3.5-flash",
    )
    mock_reframe.return_value = (b"png", "gemini-3-pro-image-preview", {})
    mock_outpaint.return_value = (b"png", "gemini-3-pro-image-preview", {})
    mock_save.return_value = "https://s3/out.png"

    process_resize_export(
        ResizeExportRequest(
            export_id="01HXYZ",
            source_image_url="https://src.example.com/in.png",
            target_width=1920,
            target_height=1080,
        )
    )

    assert mock_pc.call_args.kwargs["vision_model"] == "gemini-3.5-flash"
    assert mock_pc.call_args.kwargs["model"] == "gemini-3-pro-image-preview"
```

A square 1000×1000 source into a 1920×1080 target is an orientation flip, so
`_decide_strategy` routes to `ai_reframe` and `mock_reframe` serves the call —
`mock_outpaint` is set only so the test does not depend on that routing.
`ResizeExportRequest` needs exactly these four fields (`request_schema.py:23`);
everything else defaults.

- [ ] **Step 3: Run tests to verify they fail**

Run: `source .venv/bin/activate && python -m pytest tests/agents/kv_resize/test_service.py -v`
Expected: FAIL — the new test asserts `vision_model == "gemini-3.5-flash"` but gets `"gpt-4o-mini"`.

- [ ] **Step 4: Write the implementation**

In `process_resize_export`, add to the initial declarations (next to `vision_token_usage`):

```python
    vision_model: Optional[str] = None
```

Change the `analyze` call:

```python
        if req.use_vision_prepass and req.crop_window is None:
            vision, vision_token_usage, vision_model = analyze(_to_data_url(source))
```

Change the `post_completed` argument at the end of the success path:

```python
            vision_model=vision_model if vision_token_usage else None,
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `source .venv/bin/activate && python -m pytest tests/agents/kv_resize/ -v`
Expected: PASS — the whole `kv_resize` suite, including all previously-green tests.

- [ ] **Step 6: Commit**

```bash
git add app/agents/kv_resize/service.py tests/agents/kv_resize/test_service.py
git commit -m "feat(kv-resize): report the vision model that actually served the prepass"
```

---

### Task 8: Regression sweep and spec amendment

**Files:**
- Modify: `docs/superpowers/specs/2026-08-05-kv-resize-provider-fallback-design.md`

- [ ] **Step 1: Run every suite this change touches**

Run: `source .venv/bin/activate && python -m pytest tests/tools/ tests/utils/ tests/agents/kv_resize/ -v`
Expected: PASS — all green. These directories have no pre-existing failures.

- [ ] **Step 2: Confirm no regression outside the change**

Run: `source .venv/bin/activate && python -m pytest tests/ -q 2>&1 | tail -20`
Expected: the only failures are the ~16 pre-existing ones in `tests/agents/chat_agent/` and `tests/agents/kv_generator/`. Confirm each failure name appears in the HEAD baseline before this branch. If a failure appears anywhere else, it is a regression from this work — fix it before continuing.

- [ ] **Step 3: Confirm the import graph has no cycle**

Run: `source .venv/bin/activate && python -c "import app.tools.outpaint_image, app.agents.kv_resize.service; print('ok')"`
Expected: `ok`

- [ ] **Step 4: Amend the spec's config section**

In the spec, replace the `KV_RESIZE_IMAGE_PROVIDER` heading and table intro in section 4 with `KV_RESIZE_AI_PROVIDER`, and state that the one switch governs both KV Resize OpenAI calls (image edit and vision prepass) — one credit balance, one knob.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-08-05-kv-resize-provider-fallback-design.md
git commit -m "docs(spec): rename the KV Resize provider switch to KV_RESIZE_AI_PROVIDER"
```

---

## Manual verification (after the plan is implemented)

These cannot be covered by unit tests and are Daffa's to run:

1. **Live Gemini aspect behavior.** Set `KV_RESIZE_AI_PROVIDER=gemini`, run one export at 1920×1080 and one at 1080×1350, and confirm the output dimensions are exact and the framing is not distorted. This is the spec's flagged unknown: `gemini-3-pro-image-preview` returns from a fixed ratio set, and `image_config.aspect_ratio` behavior is asserted here from in-repo usage in `app/tools/generate_image.py`, not from a live call with this model.
2. **Seam quality.** Compare a fallback outpaint against a gpt-image-2 one on the same source. The preserved region is guaranteed identical; the judgment call is whether the boundary is acceptable to ship during an outage.
3. **Metering.** After one fallback export, confirm a `CostHistory` row exists with the Gemini model and a non-zero credit amount. A zero amount means the model string missed the api registry.
4. **PostHog.** Confirm `$ai_generation` events land with `$ai_provider = "gemini"` and `$ai_span_name = "kv_resize_fallback"`.
