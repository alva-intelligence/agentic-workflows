# KV Brand Logo Strict Bake — ai-service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the KV generator bake the brand logo into the output as a strict, deterministic PIL composite (never through gpt-image), driven by an LLM logo-intent classifier and a sticky `{anchor, scale}` spec.

**Architecture:** Replace the B3 logo path (logo URL → image prompt → img-to-img). After the scene is generated and uploaded, ai-service downloads it, alpha-composites the real logo bytes (supplied by api as base64) at the resolved anchor/scale, re-uploads, and swaps the URL. A dedicated small-model classifier decides place/remove/none + anchor + scale; a resolver applies sticky persistence; a `LogoStampStateEvent` tells api what to persist.

**Tech Stack:** Python 3.12, FastAPI, Pydantic v2, Pillow 11.3.0 (already installed), pytest, AsyncOpenAI (gpt-4o-mini classifier, same pattern as `_stream_post_generation_summary`).

**Branch:** `feature/daffa/vc-studio-projects-kv-generator`

**Spec:** `docs/superpowers/specs/2026-06-04-kv-brand-logo-strict-bake-design.md`

**Scope (v1):** `kv_generator` image mode (sketch + craft) and edit mode. The `kv_resize` agent is out of scope for v1 (note as follow-up).

---

## File Structure

- `ai-service/app/agents/kv_generator/request_schema.py` — **modify**: add `Anchor`, `Scale`, `BrandLogoAsset`, `BrandLogoStamp`, `LogoDirective`; add `brand_logo` + `brand_logo_stamp` to `KvStreamRequest`.
- `ai-service/app/agents/kv_generator/logo_stamp.py` — **new**: pure functions `resolve_stamp()` + `stamp_logo()` (PIL). No I/O.
- `ai-service/app/agents/kv_generator/logo_directive.py` — **new**: `classify_logo_directive()` (LLM JSON call).
- `ai-service/app/agents/kv_generator/response_schema.py` — **modify**: add `LogoStampStateEvent`.
- `ai-service/app/agents/kv_generator/context_builder.py` — **modify**: drop the `- Logo URL:` line.
- `ai-service/app/agents/kv_generator/prompts/image_mode.py` — **modify**: strip all logo instructions.
- `ai-service/app/agents/kv_generator/prompts/craft_mode.py` — **modify**: strip the logo carve-out.
- `ai-service/app/agents/kv_generator/service.py` — **modify**: remove B3 wiring; add classifier call, stamp step (download→composite→re-upload), emit event; same stamp step in edit mode.
- `ai-service/app/agents/kv_generator/brand_logo_fetcher.py` — **delete**.
- Tests (new): `tests/agents/kv_generator/test_logo_stamp.py`, `test_logo_directive.py`, `test_service_logo_bake.py`.
- Tests (delete): `tests/agents/kv_generator/test_brand_logo_fetcher.py`.

---

## Task 1: Schema — logo types + request fields

**Files:**
- Modify: `ai-service/app/agents/kv_generator/request_schema.py`
- Test: `ai-service/tests/agents/kv_generator/test_schemas.py`

- [ ] **Step 1: Write the failing schema test**

Append to `ai-service/tests/agents/kv_generator/test_schemas.py`:

```python
from app.agents.kv_generator.request_schema import (
    BrandLogoAsset,
    BrandLogoStamp,
    KvStreamRequest,
    LaunchContext,
    LogoDirective,
)


def test_kv_request_accepts_brand_logo_and_stamp():
    req = KvStreamRequest(
        thread_id="t1",
        studio_file_id="f1",
        mode="image",
        prompt="add logo",
        launch_context=LaunchContext(studio_file_id="f1", brand_id="b1"),
        user_id="u1",
        brand_logo=BrandLogoAsset(data_base64="AAAA", mime_type="image/png"),
        brand_logo_stamp=BrandLogoStamp(anchor="bottom-right", scale="medium"),
    )
    assert req.brand_logo.mime_type == "image/png"
    assert req.brand_logo_stamp.anchor == "bottom-right"


def test_kv_request_logo_fields_optional():
    req = KvStreamRequest(
        thread_id="t1", studio_file_id="f1", prompt="hi",
        launch_context=LaunchContext(studio_file_id="f1", brand_id="b1"),
        user_id="u1",
    )
    assert req.brand_logo is None
    assert req.brand_logo_stamp is None


def test_logo_directive_defaults_to_none_action():
    d = LogoDirective()
    assert d.action == "none"
    assert d.anchor is None and d.scale is None
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/ai-service && source .venv/bin/activate && pytest tests/agents/kv_generator/test_schemas.py::test_kv_request_accepts_brand_logo_and_stamp -v`
Expected: FAIL — `ImportError`/`ValidationError` (`BrandLogoAsset` not defined / extra inputs).

- [ ] **Step 3: Add the types**

In `ai-service/app/agents/kv_generator/request_schema.py`, after the `Attachment` class (line 94), add:

```python
Anchor = Literal[
    "top-left", "top-center", "top-right",
    "mid-left", "center", "mid-right",
    "bottom-left", "bottom-center", "bottom-right",
]
Scale = Literal["small", "medium", "large"]


class BrandLogoAsset(BaseModel):
    """The brand's logo bytes, supplied inline by the API (base64) so
    ai-service can composite it onto the generated image without a URL
    fetch. mime_type mirrors the Attachment allowlist."""

    data_base64: str
    mime_type: Literal["image/png", "image/jpeg", "image/webp", "image/gif"]


class BrandLogoStamp(BaseModel):
    """Where + how big to bake the brand logo. Persisted by the API on
    studio_files.brand_logo_stamp so it sticks across regenerations."""

    anchor: Anchor
    scale: Scale


class LogoDirective(BaseModel):
    """The logo-intent classifier's decision for this turn."""

    action: Literal["place", "remove", "none"] = "none"
    anchor: Optional[Anchor] = None
    scale: Optional[Scale] = None
```

- [ ] **Step 4: Add the request fields**

In `KvStreamRequest` (request_schema.py), after the `attachments` field (line 137), add:

```python
    # Brand logo asset + placement spec for strict server-side bake.
    # The API supplies the logo bytes (when the brand has a logo and the
    # turn produces an image) and the persisted stamp (sticky placement).
    # See docs/superpowers/specs/2026-06-04-kv-brand-logo-strict-bake-design.md
    brand_logo: Optional["BrandLogoAsset"] = None
    brand_logo_stamp: Optional["BrandLogoStamp"] = None
```

- [ ] **Step 5: Run to verify pass**

Run: `cd ai-service && source .venv/bin/activate && pytest tests/agents/kv_generator/test_schemas.py -v`
Expected: PASS (new + pre-existing).

- [ ] **Step 6: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/ai-service
git add app/agents/kv_generator/request_schema.py tests/agents/kv_generator/test_schemas.py
git commit -m "feat(ai): add brand logo asset + stamp + directive schemas for strict bake"
```

---

## Task 2: `logo_stamp.py` — resolver + PIL compositor (pure)

**Files:**
- Create: `ai-service/app/agents/kv_generator/logo_stamp.py`
- Test: `ai-service/tests/agents/kv_generator/test_logo_stamp.py`

- [ ] **Step 1: Write the failing test**

Create `ai-service/tests/agents/kv_generator/test_logo_stamp.py`:

```python
from io import BytesIO

import pytest
from PIL import Image

from app.agents.kv_generator.logo_stamp import resolve_stamp, stamp_logo
from app.agents.kv_generator.request_schema import BrandLogoStamp, LogoDirective


def _png(w: int, h: int, color) -> bytes:
    buf = BytesIO()
    Image.new("RGBA", (w, h), color).save(buf, format="PNG")
    return buf.getvalue()


def test_resolve_place_uses_directive_and_defaults():
    out = resolve_stamp(LogoDirective(action="place"), None)
    assert out == BrandLogoStamp(anchor="bottom-right", scale="medium")
    out2 = resolve_stamp(LogoDirective(action="place", anchor="top-left", scale="large"), None)
    assert out2 == BrandLogoStamp(anchor="top-left", scale="large")


def test_resolve_remove_clears_persisted():
    assert resolve_stamp(LogoDirective(action="remove"),
                         BrandLogoStamp(anchor="top-left", scale="small")) is None


def test_resolve_none_returns_persisted():
    persisted = BrandLogoStamp(anchor="mid-left", scale="small")
    assert resolve_stamp(LogoDirective(action="none"), persisted) == persisted
    assert resolve_stamp(LogoDirective(action="none"), None) is None


def test_stamp_logo_places_logo_bottom_right_within_margin():
    scene = _png(1000, 1000, (255, 255, 255, 255))
    logo = _png(200, 100, (255, 0, 0, 255))  # red
    out = stamp_logo(scene, logo, BrandLogoStamp(anchor="bottom-right", scale="medium"))
    img = Image.open(BytesIO(out)).convert("RGB")
    assert img.size == (1000, 1000)
    # medium = 12% of 1000 = 120px wide; margin = 4% of 1000 = 40px.
    # A pixel just inside the bottom-right logo box should be red.
    px = img.getpixel((1000 - 40 - 10, 1000 - 40 - 10))
    assert px[0] > 200 and px[1] < 60 and px[2] < 60
    # Top-left corner stays white.
    assert img.getpixel((10, 10)) == (255, 255, 255)


def test_stamp_logo_never_upscales_beyond_native():
    scene = _png(1000, 1000, (255, 255, 255, 255))
    logo = _png(50, 50, (0, 0, 255, 255))  # native 50px < 120px medium target
    out = stamp_logo(scene, logo, BrandLogoStamp(anchor="top-left", scale="medium"))
    img = Image.open(BytesIO(out)).convert("RGB")
    # Logo capped at native 50px at margin 40 → pixel (40+45,40+45)=(85,85)
    # is just inside; (40+60,40+60)=(100,100) is outside (white).
    assert img.getpixel((85, 85))[2] > 200
    assert img.getpixel((100, 100)) == (255, 255, 255)
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ai-service && source .venv/bin/activate && pytest tests/agents/kv_generator/test_logo_stamp.py -v`
Expected: FAIL — module `logo_stamp` not found.

- [ ] **Step 3: Create the module**

Create `ai-service/app/agents/kv_generator/logo_stamp.py`:

```python
"""Strict, deterministic brand-logo compositing for the KV generator.

Pure functions only (no I/O) so they are trivially unit-testable. The
logo bytes are pasted onto the generated scene exactly as supplied — no
recolor, no restyle, no regeneration. This is the whole point: a
generative image model can never guarantee an untouched logo, so the
logo never goes through one.
"""

from __future__ import annotations

from io import BytesIO
from typing import Optional

from PIL import Image

from app.agents.kv_generator.request_schema import (
    Anchor,
    BrandLogoStamp,
    LogoDirective,
)

# Logo width as a fraction of the scene width.
_SCALE_PCT = {"small": 0.08, "medium": 0.12, "large": 0.18}
# Edge inset as a fraction of the scene's shorter side.
_MARGIN_PCT = 0.04


def resolve_stamp(
    directive: LogoDirective,
    persisted: Optional[BrandLogoStamp],
) -> Optional[BrandLogoStamp]:
    """Combine this turn's directive with the persisted (sticky) spec.

    place  → new spec from the directive (defaults bottom-right/medium).
    remove → None (clears persistence).
    none   → keep whatever was persisted (sticky behaviour).
    """
    if directive.action == "remove":
        return None
    if directive.action == "place":
        return BrandLogoStamp(
            anchor=directive.anchor or "bottom-right",
            scale=directive.scale or "medium",
        )
    return persisted


def stamp_logo(
    scene_bytes: bytes,
    logo_bytes: bytes,
    stamp: BrandLogoStamp,
) -> bytes:
    """Alpha-composite the logo onto the scene at the stamp's anchor/scale
    and return PNG bytes. The logo is pasted as-is — width scaled to a %
    of the scene, never upscaled beyond its native resolution."""
    scene = Image.open(BytesIO(scene_bytes)).convert("RGBA")
    logo = Image.open(BytesIO(logo_bytes)).convert("RGBA")

    sw, sh = scene.size
    target_w = int(round(sw * _SCALE_PCT[stamp.scale]))
    target_w = max(1, min(target_w, logo.width))  # never upscale past native
    target_h = max(1, int(round(logo.height * (target_w / logo.width))))
    logo_resized = logo.resize((target_w, target_h), Image.LANCZOS)

    margin = int(round(min(sw, sh) * _MARGIN_PCT))
    x, y = _anchor_xy(stamp.anchor, sw, sh, target_w, target_h, margin)

    scene.alpha_composite(logo_resized, (x, y))
    out = BytesIO()
    scene.convert("RGB").save(out, format="PNG")
    return out.getvalue()


def _anchor_xy(
    anchor: Anchor, sw: int, sh: int, lw: int, lh: int, margin: int
) -> tuple[int, int]:
    if anchor in ("top-left", "mid-left", "bottom-left"):
        x = margin
    elif anchor in ("top-right", "mid-right", "bottom-right"):
        x = sw - lw - margin
    else:
        x = (sw - lw) // 2

    if anchor in ("top-left", "top-center", "top-right"):
        y = margin
    elif anchor in ("bottom-left", "bottom-center", "bottom-right"):
        y = sh - lh - margin
    else:
        y = (sh - lh) // 2

    return max(0, x), max(0, y)
```

- [ ] **Step 4: Run to verify pass**

Run: `cd ai-service && source .venv/bin/activate && pytest tests/agents/kv_generator/test_logo_stamp.py -v`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/ai-service
git add app/agents/kv_generator/logo_stamp.py tests/agents/kv_generator/test_logo_stamp.py
git commit -m "feat(ai): add logo_stamp resolver + PIL compositor (pure)"
```

---

## Task 3: `logo_directive.py` — LLM intent classifier

**Files:**
- Create: `ai-service/app/agents/kv_generator/logo_directive.py`
- Test: `ai-service/tests/agents/kv_generator/test_logo_directive.py`

- [ ] **Step 1: Write the failing test**

Create `ai-service/tests/agents/kv_generator/test_logo_directive.py`:

```python
import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from app.agents.kv_generator.logo_directive import classify_logo_directive
from app.agents.kv_generator.request_schema import ChatMessage


@pytest.mark.asyncio
async def test_returns_none_when_logo_unavailable():
    d = await classify_logo_directive(
        chat_history=[], user_prompt="add the logo", logo_available=False
    )
    assert d.action == "none"


def _mock_openai(content: str):
    """Patch AsyncOpenAI so .chat.completions.create returns `content`."""
    msg = MagicMock()
    msg.content = content
    choice = MagicMock()
    choice.message = msg
    resp = MagicMock()
    resp.choices = [choice]
    client = MagicMock()
    client.chat.completions.create = AsyncMock(return_value=resp)
    return client


@pytest.mark.asyncio
async def test_parses_place_directive():
    payload = json.dumps({"action": "place", "anchor": "top-left", "scale": "large"})
    with patch("app.agents.kv_generator.logo_directive.settings") as s, patch(
        "app.agents.kv_generator.logo_directive.AsyncOpenAI",
        return_value=_mock_openai(payload),
    ):
        s.OPENAI_API_KEY = "sk-test"
        d = await classify_logo_directive(
            chat_history=[ChatMessage(role="user", content="taruh logo kiri atas besar")],
            user_prompt="taruh logo kiri atas besar",
            logo_available=True,
        )
    assert d.action == "place"
    assert d.anchor == "top-left"
    assert d.scale == "large"


@pytest.mark.asyncio
async def test_parses_remove_directive():
    payload = json.dumps({"action": "remove"})
    with patch("app.agents.kv_generator.logo_directive.settings") as s, patch(
        "app.agents.kv_generator.logo_directive.AsyncOpenAI",
        return_value=_mock_openai(payload),
    ):
        s.OPENAI_API_KEY = "sk-test"
        d = await classify_logo_directive(
            chat_history=[], user_prompt="hapus logo", logo_available=True
        )
    assert d.action == "remove"


@pytest.mark.asyncio
async def test_bad_json_falls_back_to_none():
    with patch("app.agents.kv_generator.logo_directive.settings") as s, patch(
        "app.agents.kv_generator.logo_directive.AsyncOpenAI",
        return_value=_mock_openai("not json {"),
    ):
        s.OPENAI_API_KEY = "sk-test"
        d = await classify_logo_directive(
            chat_history=[], user_prompt="whatever", logo_available=True
        )
    assert d.action == "none"
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ai-service && source .venv/bin/activate && pytest tests/agents/kv_generator/test_logo_directive.py -v`
Expected: FAIL — module not found.

- [ ] **Step 3: Create the module**

Create `ai-service/app/agents/kv_generator/logo_directive.py`:

```python
"""LLM logo-intent classifier for the KV generator.

A focused, separate call (gpt-4o-mini, JSON mode) — the same pattern as
`_stream_post_generation_summary`. Kept out of the main prompt-refiner
stream so the refiner stays logo-agnostic and this stays unit-testable.
"""

from __future__ import annotations

import json
from typing import List

from openai import AsyncOpenAI

from app.agents.kv_generator.request_schema import ChatMessage, LogoDirective
from app.utils.config import settings

_SYSTEM = (
    "You classify whether the user wants the BRAND LOGO baked into a key "
    "visual, and where. Reply ONLY with a JSON object: "
    '{"action": "place"|"remove"|"none", "anchor": <anchor|null>, '
    '"scale": <scale|null>}. '
    "anchor ∈ top-left, top-center, top-right, mid-left, center, mid-right, "
    "bottom-left, bottom-center, bottom-right. scale ∈ small, medium, large. "
    "Rules: if the user asks to ADD or MOVE the brand logo, action=place with "
    "the requested corner (map 'kiri atas'→top-left, 'kanan bawah'→"
    "bottom-right, etc.) and size (default anchor bottom-right, default scale "
    "medium when unspecified). If they ask to REMOVE/'hapus'/'tanpa' the logo, "
    "action=remove. Otherwise action=none. Never invent a placement when the "
    "user did not mention the logo this conversation."
)


async def classify_logo_directive(
    *,
    chat_history: List[ChatMessage],
    user_prompt: str,
    logo_available: bool,
) -> LogoDirective:
    """Return the logo directive for this turn. Defaults to `none` on any
    unhappy path (no logo on file, no API key, bad/blocked response)."""
    if not logo_available:
        return LogoDirective(action="none")

    api_key = getattr(settings, "OPENAI_API_KEY", None)
    if not api_key:
        return LogoDirective(action="none")

    convo = "\n".join(f"{m.role}: {m.content}" for m in chat_history[-8:])
    user = (
        f"Conversation so far:\n{convo}\n\n"
        f"Latest user message: {user_prompt}"
    )

    try:
        client = AsyncOpenAI(api_key=api_key)
        resp = await client.chat.completions.create(
            model="gpt-4o-mini",
            messages=[
                {"role": "system", "content": _SYSTEM},
                {"role": "user", "content": user},
            ],
            response_format={"type": "json_object"},
            temperature=0,
        )
        raw = resp.choices[0].message.content or "{}"
        data = json.loads(raw)
        return LogoDirective(
            action=data.get("action", "none"),
            anchor=data.get("anchor") or None,
            scale=data.get("scale") or None,
        )
    except Exception:
        return LogoDirective(action="none")
```

- [ ] **Step 4: Run to verify pass**

Run: `cd ai-service && source .venv/bin/activate && pytest tests/agents/kv_generator/test_logo_directive.py -v`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/ai-service
git add app/agents/kv_generator/logo_directive.py tests/agents/kv_generator/test_logo_directive.py
git commit -m "feat(ai): add LLM logo-intent classifier (place/remove/none)"
```

---

## Task 4: `LogoStampStateEvent` + drop B3 prompt instructions

**Files:**
- Modify: `ai-service/app/agents/kv_generator/response_schema.py`
- Modify: `ai-service/app/agents/kv_generator/context_builder.py:121-123`
- Modify: `ai-service/app/agents/kv_generator/prompts/image_mode.py`
- Modify: `ai-service/app/agents/kv_generator/prompts/craft_mode.py`
- Test: `ai-service/tests/agents/kv_generator/test_context_builder.py`

- [ ] **Step 1: Add the event class**

In `ai-service/app/agents/kv_generator/response_schema.py`, after `GenerationReadyEvent` (line 88), add:

```python
class LogoStampStateEvent(BaseEvent):
    """The resolved brand-logo placement for this turn. The API persists
    it to studio_files.brand_logo_stamp so the bake sticks across
    regenerations. `stamp` is null when no logo is applied (or removed)."""

    event: Literal["logo_stamp_state"] = "logo_stamp_state"
    stamp: Optional[Dict[str, Any]] = None
```

- [ ] **Step 2: Write the failing context_builder test**

Append to `ai-service/tests/agents/kv_generator/test_context_builder.py`:

```python
@pytest.mark.asyncio
async def test_brand_block_no_longer_renders_logo_url():
    """Strict-bake: the logo URL must NOT appear in the prompt — the logo
    is composited server-side, never described to the image model."""
    api = AsyncMock()
    ctx = LaunchContext(studio_file_id="f1", use_brand_knowledge=True, brand_id="b1")

    from app.agents.kv_generator.request_schema import Prefetched, PrefetchedBrand
    prefetched = Prefetched(brand=PrefetchedBrand(
        brand_name="Telkomsel",
        dna="d", identity="i", tonality="t",
        logo_url="https://s3.example.com/logo.png",
    ))

    prompt = await build_system_prompt(
        mode="image", launch_context=ctx, api_client=api, prefetched=prefetched,
    )
    assert "logo.png" not in prompt
    assert "Logo URL" not in prompt
```

- [ ] **Step 3: Run to verify it fails**

Run: `cd ai-service && source .venv/bin/activate && pytest tests/agents/kv_generator/test_context_builder.py::test_brand_block_no_longer_renders_logo_url -v`
Expected: FAIL — `logo.png` is in the prompt.

- [ ] **Step 4: Drop the Logo URL line in context_builder**

In `ai-service/app/agents/kv_generator/context_builder.py`, delete lines 121-123:

```python
    logo_url = brand.get("logo_url") or ""
    if logo_url:
        lines.append(f"- Logo URL: {logo_url}")
```

- [ ] **Step 5: Strip logo instructions from image_mode.py**

Replace `ai-service/app/agents/kv_generator/prompts/image_mode.py` entirely:

```python
GUIDANCE = (
    "In image mode your response is used as the prompt for an image-generation "
    "model (gpt-image-1). Your reply MUST be a single paragraph that describes "
    "the image to create, synthesising everything relevant from the chat "
    "history (brand, campaign concept, subjects, style, mood, palette, "
    "composition, aspect ratio). Do NOT ask questions, do NOT address the "
    "user, do NOT include meta commentary or headings — just the image prompt "
    "itself. If the user's latest message is just a confirmation like 'yes' "
    "or 'go ahead', build the prompt from the prior turns instead of from "
    "that short message. Keep it concrete, visual, and under 300 words. "
    "Do NOT mention, describe, or place the brand logo — the brand logo is "
    "composited onto the image separately, so never reference it in the prompt."
)
```

- [ ] **Step 6: Strip the logo carve-out from craft_mode.py**

Read `ai-service/app/agents/kv_generator/prompts/craft_mode.py`. Remove any sentence(s) instructing the model to include the brand logo / Logo URL (the "explicit-logo carve-out" referenced in `service.py:275`). Add the same single sentence used above: `"Do NOT mention, describe, or place the brand logo — it is composited separately."` Keep all other craft guidance intact.

- [ ] **Step 7: Run the context_builder + schema suites**

Run: `cd ai-service && source .venv/bin/activate && pytest tests/agents/kv_generator/test_context_builder.py tests/agents/kv_generator/test_schemas.py -v`
Expected: PASS. (Pre-existing Layer-1 tests that asserted the Logo URL line — if any — must be updated/removed in this step; search the test file for `Logo URL` and delete those assertions.)

- [ ] **Step 8: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/ai-service
git add app/agents/kv_generator/response_schema.py app/agents/kv_generator/context_builder.py \
        app/agents/kv_generator/prompts/image_mode.py app/agents/kv_generator/prompts/craft_mode.py \
        tests/agents/kv_generator/test_context_builder.py
git commit -m "feat(ai): add LogoStampStateEvent; strip logo from prompts (strict bake)"
```

---

## Task 5: Remove the B3 fetcher

**Files:**
- Delete: `ai-service/app/agents/kv_generator/brand_logo_fetcher.py`
- Delete: `ai-service/tests/agents/kv_generator/test_brand_logo_fetcher.py`
- Delete: `ai-service/tests/agents/kv_generator/test_service_image_mode_logo_embedding.py` (if present — the B3 integration test)
- Modify: `ai-service/app/agents/kv_generator/service.py:15-16` (import), `:263-286` (wiring)

- [ ] **Step 1: Delete the B3 files**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/ai-service
git rm app/agents/kv_generator/brand_logo_fetcher.py
git rm tests/agents/kv_generator/test_brand_logo_fetcher.py
git rm tests/agents/kv_generator/test_service_image_mode_logo_embedding.py 2>/dev/null || true
```

- [ ] **Step 2: Remove the import in service.py**

In `ai-service/app/agents/kv_generator/service.py`, delete the import at lines 14-16:

```python
from app.agents.kv_generator.brand_logo_fetcher import (
    maybe_fetch_brand_logo_as_attachment,
)
```

- [ ] **Step 3: Remove the B3 wiring block in `_run_image_mode`**

In `service.py`, delete the entire block at lines 263-286 (the comment starting `# B3:` through the `request.attachments.append(logo_attachment)` block):

```python
    # B3: if the LLM included the brand's logo URL ...
    ...
    if request.canvas_mode in ("sketch", "craft"):
        logo_attachment = await maybe_fetch_brand_logo_as_attachment(
            prefetched=request.prefetched,
            prompt=image_prompt,
        )
        if logo_attachment is not None and not any(
            a.id == logo_attachment.id for a in request.attachments
        ):
            request.attachments.append(logo_attachment)
```

After deletion, `apply_style_to_image_prompt(...)` (ends ~line 261) is immediately followed by the `# 3. Generate` comment + the two `GeneratingEvent` yields.

- [ ] **Step 4: PHP-free syntax/import check**

Run: `cd ai-service && source .venv/bin/activate && python -c "import app.agents.kv_generator.service"`
Expected: no ImportError. (If it errors on `maybe_fetch_brand_logo_as_attachment` still referenced, you missed a usage — grep `grep -rn maybe_fetch_brand_logo app/`.)

- [ ] **Step 5: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/ai-service
git add -A app/agents/kv_generator/service.py
git commit -m "chore(ai): remove B3 brand-logo fetcher + img-to-img wiring"
```

---

## Task 6: Wire classifier + stamp into `service.py`

**Files:**
- Modify: `ai-service/app/agents/kv_generator/service.py`
- Test: `ai-service/tests/agents/kv_generator/test_service_logo_bake.py` (Task 7)

- [ ] **Step 1: Add imports**

In `service.py`, add to the existing `from app.agents.kv_generator.*` import group (near lines 17-26):

```python
from app.agents.kv_generator.logo_directive import classify_logo_directive
from app.agents.kv_generator.logo_stamp import resolve_stamp, stamp_logo
```

Add `LogoStampStateEvent` to the `from app.agents.kv_generator.response_schema import (...)` list (line 27-38).

Add to the AWS import area (near `from app.tools.edit_image import edit_image as edit_image_fn`, line 45):

```python
from app.services.aws import upload_file_to_s3
from agno.utils.log import log_warning
```

Confirm `base64`, `os`, `tempfile`, `uuid` are already imported at the top of `service.py` (they are used by `_save_attachments_to_disk`). If `log_warning` import path differs, mirror whatever logging helper the file already uses.

- [ ] **Step 2: Add the stamp helper near the other module helpers**

In `service.py`, add this function next to `_download_image` (around line 1235):

```python
def _maybe_stamp_logo_url(
    image_url: str,
    request: KvStreamRequest,
    stamp,  # Optional[BrandLogoStamp]
) -> str:
    """Bake the brand logo onto an already-uploaded generation image and
    return the new URL. No-op (returns the original URL) when there's no
    active stamp or no logo bytes. Failures are swallowed — a missing
    logo must never break the generation."""
    if stamp is None or request.brand_logo is None:
        return image_url
    try:
        scene_bytes = _download_image(image_url)
        final_bytes = stamp_logo(
            scene_bytes,
            base64.b64decode(request.brand_logo.data_base64),
            stamp,
        )
        tmp_dir = tempfile.mkdtemp(prefix="kv_logo_stamp_")
        file_name = f"{uuid.uuid4().hex}.png"
        file_path = os.path.join(tmp_dir, file_name)
        with open(file_path, "wb") as f:
            f.write(final_bytes)
        new_url = upload_file_to_s3(
            source_path=file_path,
            destination_path=f"kv-generations/{request.studio_file_id}/{file_name}",
            file_permission="public",
            content_type="image/png",
        )
        return new_url or image_url
    except Exception as e:  # noqa: BLE001 — degrade gracefully
        log_warning(f"KV logo stamp failed; returning unstamped image: {e!r}")
        return image_url
```

- [ ] **Step 3: Classify + resolve the stamp in `_run_image_mode`**

In `_run_image_mode`, immediately after `image_prompt = apply_style_to_image_prompt(...)` (the block that ended where the deleted B3 code was, ~line 261), insert:

```python
    # Strict brand-logo bake: classify whether the user wants the logo
    # placed/moved/removed this turn, then resolve against the persisted
    # sticky stamp. The logo is NEVER part of the image prompt — it is
    # composited onto the finished render below.
    logo_directive = await classify_logo_directive(
        chat_history=request.chat_history,
        user_prompt=request.prompt,
        logo_available=request.brand_logo is not None,
    )
    resolved_stamp = resolve_stamp(logo_directive, request.brand_logo_stamp)
```

- [ ] **Step 4: Apply the stamp to the render before persistence**

In `_run_image_mode`, after the `try/except` that sets `render` (i.e. right after `yield to_sse_line(GeneratingEvent(stage="finalizing"))` at ~line 393), insert:

```python
    # Bake the logo onto the uploaded render (download → composite →
    # re-upload). No-op when no stamp is active.
    stamped_url = _maybe_stamp_logo_url(render["image_url"], request, resolved_stamp)
    render["image_url"] = stamped_url
    render["thumbnail_url"] = stamped_url
```

- [ ] **Step 5: Emit `LogoStampStateEvent` after `GenerationReadyEvent`**

In `_run_image_mode`, immediately after the `yield to_sse_line(GenerationReadyEvent(payload={...}))` block (ends ~line 431), insert:

```python
    # Tell the API what to persist on studio_files.brand_logo_stamp so the
    # placement sticks across regenerations (or clears on remove).
    yield to_sse_line(LogoStampStateEvent(
        stamp=resolved_stamp.model_dump() if resolved_stamp else None,
    ))
```

- [ ] **Step 6: Re-apply the persisted stamp in `_run_edit_mode`**

In `_run_edit_mode`, the success path sets `image_url` (line 1190) and builds `GenerationReadyEvent` (1205-1223). Edit mode has no fresh directive — re-apply the persisted stamp so an inpaint never disturbs the brand lockup. Right after `yield to_sse_line(GeneratingEvent(stage="finalizing"))` (line 1202), insert:

```python
    # Strict bake: re-apply the persisted logo stamp on top of the edit
    # (no fresh directive in edit mode — the placement is sticky).
    if request.brand_logo_stamp is not None:
        image_url = _maybe_stamp_logo_url(image_url, request, request.brand_logo_stamp)
```

Then in the `GenerationReadyEvent` payload (lines 1209-1210), the existing
`"image_url": image_url` and `"thumbnail_url": result.get("thumbnail_url") or image_url` —
change the thumbnail line to reuse the stamped url:

```python
                "image_url": image_url,
                "thumbnail_url": image_url,
```

- [ ] **Step 7: Import-load check**

Run: `cd ai-service && source .venv/bin/activate && python -c "import app.agents.kv_generator.service"`
Expected: no error.

- [ ] **Step 8: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/ai-service
git add app/agents/kv_generator/service.py
git commit -m "feat(ai): bake brand logo onto render via classifier + sticky stamp"
```

---

## Task 7: Integration test for the bake wire-in

**Files:**
- Create: `ai-service/tests/agents/kv_generator/test_service_logo_bake.py`

- [ ] **Step 1: Write the integration test**

Create `ai-service/tests/agents/kv_generator/test_service_logo_bake.py`:

```python
import base64
from io import BytesIO
from unittest.mock import AsyncMock, patch

import pytest
from PIL import Image

from app.agents.kv_generator import service as kv_service
from app.agents.kv_generator.request_schema import (
    BrandLogoAsset,
    BrandLogoStamp,
    KvStreamRequest,
    LaunchContext,
    LogoDirective,
)


def _png_b64(w, h, color) -> str:
    buf = BytesIO()
    Image.new("RGBA", (w, h), color).save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode("ascii")


def _png_bytes(w, h, color) -> bytes:
    buf = BytesIO()
    Image.new("RGBA", (w, h), color).save(buf, format="PNG")
    return buf.getvalue()


def _request(**over) -> KvStreamRequest:
    base = dict(
        thread_id="t1", studio_file_id="f1", mode="image", canvas_mode="sketch",
        prompt="tambahkan logo kanan bawah",
        launch_context=LaunchContext(studio_file_id="f1", brand_id="b1"),
        user_id="u1",
        brand_logo=BrandLogoAsset(data_base64=_png_b64(200, 100, (255, 0, 0, 255)),
                                  mime_type="image/png"),
    )
    base.update(over)
    return KvStreamRequest(**base)


@pytest.mark.asyncio
async def test_place_directive_bakes_logo_and_emits_state(monkeypatch):
    req = _request()

    # refiner → returns a logo-free prompt
    async def fake_llm_stream(*a, **k):
        yield {"kind": "message", "text": "a serene beach at sunset"}
    monkeypatch.setattr(kv_service, "_llm_stream", fake_llm_stream)

    # classifier → place bottom-right
    async def fake_classify(**k):
        return LogoDirective(action="place", anchor="bottom-right", scale="medium")
    monkeypatch.setattr(kv_service, "classify_logo_directive", fake_classify)

    # image tool → returns an uploaded white scene URL
    monkeypatch.setattr(kv_service, "_render_image", AsyncMock(return_value={
        "image_url": "https://s3.example.com/scene.png",
        "prompt_snapshot": "x", "model": "gpt-image-1",
        "thumbnail_url": "https://s3.example.com/scene.png",
        "ai_service_run_id": "r1", "token_usage": {},
    }))
    # download → white scene bytes
    monkeypatch.setattr(kv_service, "_download_image",
                        lambda url: _png_bytes(1000, 1000, (255, 255, 255, 255)))
    # capture the bytes that get uploaded
    captured = {}

    def fake_upload(*, source_path, destination_path, file_permission, content_type=None):
        with open(source_path, "rb") as f:
            captured["bytes"] = f.read()
        return "https://s3.example.com/stamped.png"
    monkeypatch.setattr(kv_service, "upload_file_to_s3", fake_upload)
    # skip the post-gen summary LLM call
    async def fake_summary(*a, **k):
        if False:
            yield ""
    monkeypatch.setattr(kv_service, "_stream_post_generation_summary", fake_summary)

    frames = []
    async for f in kv_service._run_image_mode(req, "sys", AsyncMock()):
        frames.append(f)

    blob = "".join(frames)
    assert '"event": "logo_stamp_state"' in blob or '"event":"logo_stamp_state"' in blob
    assert "stamped.png" in blob  # GenerationReadyEvent carries the stamped URL
    # The uploaded image has a red logo bottom-right.
    img = Image.open(BytesIO(captured["bytes"])).convert("RGB")
    assert img.getpixel((1000 - 40 - 10, 1000 - 40 - 10))[0] > 200


@pytest.mark.asyncio
async def test_no_logo_asset_skips_bake(monkeypatch):
    req = _request(brand_logo=None)

    async def fake_llm_stream(*a, **k):
        yield {"kind": "message", "text": "a beach"}
    monkeypatch.setattr(kv_service, "_llm_stream", fake_llm_stream)

    async def fake_classify(**k):
        return LogoDirective(action="none")
    monkeypatch.setattr(kv_service, "classify_logo_directive", fake_classify)

    monkeypatch.setattr(kv_service, "_render_image", AsyncMock(return_value={
        "image_url": "https://s3.example.com/scene.png",
        "prompt_snapshot": "x", "model": "gpt-image-1",
        "thumbnail_url": "https://s3.example.com/scene.png",
        "ai_service_run_id": "r1", "token_usage": {},
    }))
    called = {"download": False, "upload": False}
    monkeypatch.setattr(kv_service, "_download_image",
                        lambda url: called.__setitem__("download", True) or b"")
    monkeypatch.setattr(kv_service, "upload_file_to_s3",
                        lambda **k: called.__setitem__("upload", True) or "x")
    async def fake_summary(*a, **k):
        if False:
            yield ""
    monkeypatch.setattr(kv_service, "_stream_post_generation_summary", fake_summary)

    frames = []
    async for f in kv_service._run_image_mode(req, "sys", AsyncMock()):
        frames.append(f)

    blob = "".join(frames)
    assert "scene.png" in blob          # original URL kept
    assert called["download"] is False  # no bake attempted
    assert called["upload"] is False
    # state event still emitted with null stamp
    assert "logo_stamp_state" in blob
```

> **Note for the engineer:** if `_run_image_mode`'s signature differs from `(request, system_prompt, api_client)`, match the actual call from `run_stream` (service.py:109+). The monkeypatch targets (`_llm_stream`, `classify_logo_directive`, `_render_image`, `_download_image`, `upload_file_to_s3`, `_stream_post_generation_summary`) must be the names as imported into the `service` module namespace.

- [ ] **Step 2: Run the integration test**

Run: `cd ai-service && source .venv/bin/activate && pytest tests/agents/kv_generator/test_service_logo_bake.py -v`
Expected: 2/2 PASS.

- [ ] **Step 3: Run the whole kv_generator suite**

Run: `cd ai-service && source .venv/bin/activate && pytest tests/agents/kv_generator/ -v 2>&1 | tail -30`
Expected: all logo + schema + context_builder tests PASS. Pre-existing unrelated failures (`test_service_chat_mode.py`, `test_e2e.py`) are out of scope — call them out separately if present.

- [ ] **Step 4: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/ai-service
git add tests/agents/kv_generator/test_service_logo_bake.py
git commit -m "test(ai): integration test for strict logo bake wire-in"
```

---

## Self-review checklist

- ✅ **Spec coverage:** schema (T1), compositor+resolver (T2), classifier (T3), event+prompt-strip (T4), B3 removal (T5), service wire-in incl. edit mode (T6), integration test (T7).
- ✅ **No placeholders:** all code shown verbatim; the only "read existing" pointers (craft_mode.py wording in T4.6, signature check in T7) are load-bearing references to real files.
- ✅ **Type consistency:** `BrandLogoStamp{anchor,scale}`, `LogoDirective{action,anchor,scale}`, `resolve_stamp(LogoDirective, Optional[BrandLogoStamp]) -> Optional[BrandLogoStamp]`, `stamp_logo(bytes,bytes,BrandLogoStamp)->bytes`, `_maybe_stamp_logo_url(str, KvStreamRequest, Optional[BrandLogoStamp])->str` — consistent across tasks.
- ✅ **TDD:** T1, T2, T3, T4, T7 start with failing tests; T5/T6 are structural, verified by T7.
- ✅ **Frequent commits:** one per task.
- ✅ **YAGNI:** no resize support, no bg removal, no logo variants.
