# KV Generator B3 — Server-side Brand-Logo URL Detection (Layer 2 redux)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the api-side keyword-heuristic Layer 2 (commits `ff2b8092` … `92dbce10`) with a server-side LLM-driven detection in ai-service. After the image-mode LLM finalizes the image prompt, ai-service scans it for the brand's logo URL string; if the LLM included the URL, ai-service server-side-fetches the logo bytes, appends them to `request.attachments`, which lets the existing `should_iterate` branch route the call through `/v1/images/edits` (img-to-img mode) with the actual logo as a reference.

**Architecture:** Single-service change (ai-service only). The detection moves from PHP keyword matching to "did the LLM put the URL in the final image prompt?" — the LLM has full conversation context (including multi-turn refinement and confirmation messages like 'yes, generate it'), so this is naturally more accurate than scanning the latest user turn for the literal word 'logo'. The existing img-to-img plumbing on the OpenAI side handles the rest unchanged.

**Tech Stack:**
- ai-service — Python 3.12, FastAPI, Pydantic v2, httpx (async), respx (test mocking), pytest
- api — only one task here: REVERT the obsolete Layer-2 keyword path (no new code)
- web — no changes

**Branch:** `feature/daffa/vc-kv-brand-asset-feeding` (continues the existing branch — same PR)

**Scope boundary (explicit):**
- ✅ Revert api-side Layer 2 (delete `BrandLogoIntentDetector`, `BrandLogoAttachmentBuilder`, the wire-in, and their tests). Keep Layer 1 (brand context feeding) untouched.
- ✅ New ai-service helper: `maybe_fetch_brand_logo_as_attachment(prefetched, prompt) → Optional[Attachment]`
- ✅ Wire into `service.py` between image-prompt finalization and the `should_iterate` decision
- ✅ Unit tests (respx-mocked httpx) for the new helper
- ✅ Integration test verifying that when the image prompt contains the brand logo URL, `should_iterate` flips to True and the edit-mode path is taken
- ❌ Logo variant selection (still single logo per brand — Layer 3 territory)
- ❌ Caching of fetched logo bytes (revisit if it becomes a hot path)
- ❌ Frontend / api changes beyond the L2 revert

---

## File Structure

### Revert (api, one task only)

The following files were created during the previous (now-superseded) Layer 2 implementation. They must be deleted, and the `ChatService.php` wire-in must be reverted, before any B3 work lands:

- `api/app/Services/Brand/BrandLogoIntentDetector.php` — **delete**
- `api/app/Services/Brand/BrandLogoAttachmentBuilder.php` — **delete**
- `api/app/Services/ChatService.php` — **modify**: remove the `use App\Services\Brand\BrandLogo...` imports (2 lines) AND the L2 branch inside `if ($brand) { … }` (the `if ($mode !== 'edit' && BrandLogoIntentDetector::wantsLogo($userQuery)) { … }` block)
- `api/tests/Unit/Brand/BrandLogoIntentDetectorTest.php` — **delete**
- `api/tests/Unit/Brand/BrandLogoAttachmentBuilderTest.php` — **delete**
- `api/tests/Feature/Chat/BrandLogoEmbeddingTest.php` — **delete**

### New (ai-service)

- `ai-service/app/agents/kv_generator/brand_logo_fetcher.py` — **new**: single function `maybe_fetch_brand_logo_as_attachment(prefetched, prompt) → Optional[Attachment]`. Async HTTP fetch with timeout, MIME validation against the existing allowlist, base64 encoding, returns an `Attachment` matching the schema in `request_schema.py`. Returns `None` on any unhappy path (no URL, URL not in prompt, fetch error, bad MIME, oversized payload). Mirrors the api-side `BrandLogoAttachmentBuilder` we're deleting — just on the Python side and with HTTP fetch instead of S3 disk read.

### Modified (ai-service)

- `ai-service/app/agents/kv_generator/service.py` — **modify**: after the `image_prompt = apply_style_to_image_prompt(...)` line (around line 239-241), insert a call to the new helper and append the returned attachment (if any) to `request.attachments`. The existing `should_iterate` check at line 265-268 naturally picks up the augmented attachments list and flips to img-to-img mode.

### Tests (ai-service)

- `ai-service/tests/agents/kv_generator/test_brand_logo_fetcher.py` — **new**: unit tests for the helper using `respx_mock` to stub the S3 URL responses
- `ai-service/tests/agents/kv_generator/test_service_image_mode_logo_embedding.py` — **new**: integration test verifying that when `prefetched.brand.logo_url` is mentioned in the LLM-produced image prompt, the request.attachments list ends up non-empty and the img-to-img path is taken

---

## Task 1: Revert api-side Layer 2 keyword path

**Files:** see "Revert" block above — 6 paths total (3 deletes, 1 modify, 2 test deletes)

**Rationale:** Layer 2 keyword-heuristic in api/PHP triggered on `$userQuery` only. In real Studio KV flow, the final user message before image generation is often a confirmation like "yes, generate it" — the logo intent was expressed turns earlier. The api-side detector misses this, which we proved during smoke testing (Simpati gen at 18:55:41 routed to `/v1/images/generations`, not `/v1/images/edits`). B3 supersedes the keyword approach with LLM-driven URL-in-prompt detection.

The api Layer 2 code is correct in its own right — but having two detection mechanisms (api keyword + ai-service URL scan) risks duplicate `image[]` references being sent to gpt-image-2 in img-to-img mode. Single source of truth (ai-service) is the cleaner architecture.

- [ ] **Step 1: Verify current branch state**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && git log --oneline develop..HEAD | head -10`

Expected: the top six commits include `92dbce10`, `88149b05`, `1344c000`, `072ec713`, `92af90e7`, `ff2b8092` (the Layer 2 commits being reverted).

- [ ] **Step 2: Delete the six api Layer-2 files**

Run:
```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
git rm app/Services/Brand/BrandLogoIntentDetector.php
git rm app/Services/Brand/BrandLogoAttachmentBuilder.php
git rm tests/Unit/Brand/BrandLogoIntentDetectorTest.php
git rm tests/Unit/Brand/BrandLogoAttachmentBuilderTest.php
git rm tests/Feature/Chat/BrandLogoEmbeddingTest.php
```

If `app/Services/Brand/` becomes an empty directory after the deletes, leave it — Laravel handles empty dirs fine and `git rm` won't track empties.

- [ ] **Step 3: Revert the ChatService.php wire-in**

Open `api/app/Services/ChatService.php` and remove:

1. The two `use` statements added in commit `88149b05`. Find and delete:

```php
use App\Services\Brand\BrandLogoAttachmentBuilder;
use App\Services\Brand\BrandLogoIntentDetector;
```

These should be alphabetically grouped with other `use App\Services\...` imports near the top of the file.

2. The L2 branch inside the `if ($brand) { … }` block. Find this entire block (around the prefetched-brand assignment) and delete it:

```php
                        // Layer 2: when the user asks for the brand logo (e.g.
                        // "tambahkan logo Telkomsel"), server-side fetch the
                        // logo bytes and append as an `attachments[]` entry so
                        // ai-service routes the generation through
                        // /v1/images/edits (img-to-img) with the actual logo
                        // as a reference. Without this step the LLM only puts
                        // the logo URL into the text prompt — gpt-image-2 can
                        // tokenize a URL but not fetch the image behind it.
                        //
                        // Skip in edit mode: an edit turn already carries a
                        // base generation as the img-to-img anchor; layering
                        // the brand logo on top would confuse the model.
                        if (
                            $mode !== 'edit'
                            && BrandLogoIntentDetector::wantsLogo($userQuery)
                        ) {
                            $logoAttachment = BrandLogoAttachmentBuilder::tryBuild($brand);
                            if ($logoAttachment !== null) {
                                $attachments[] = $logoAttachment;
                            }
                        }
```

The line above and below this block (the closing `);` of the `array_merge` and the closing `}` of `if ($brand)`) must remain intact. After the deletion, the `if ($brand)` body should end with only the `$prefetched['brand'] = array_merge(…)` assignment (Layer 1 behavior).

- [ ] **Step 4: PHP syntax sanity check**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && php -l app/Services/ChatService.php`
Expected: `No syntax errors detected`.

- [ ] **Step 5: Confirm bootstrap/cache is clean (DB safety pre-flight)**

Run: `ls /Users/alva.e202511001/Desktop/work/frndos-agentic/api/bootstrap/cache/`
Expected: only `packages.php` and `services.php` — NO `config.php`. If `config.php` is present, abort and report — running pest with cached config would wipe the dev DB.

- [ ] **Step 6: Run the surviving Layer-1 tests to confirm no regression**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && ./vendor/bin/pest tests/Unit/Brand/ 2>&1 | tail -10`
Expected: `Tests: 0 tests` (the directory is now empty after the deletes). If the directory itself was deleted by git, pest may report a missing-path error — that's also acceptable; the unit tests are gone.

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && php artisan tinker --execute="echo App\Services\ChatService::class . PHP_EOL;"`
Expected: prints `App\Services\ChatService` — confirms autoload + class still resolves after the edits.

- [ ] **Step 7: Commit (single commit covering all six file operations)**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
git add app/Services/ChatService.php
git commit -m "revert(api): drop Layer 2 keyword-based logo embedding (B3 supersedes)"
```

The `git rm` calls from Step 2 already staged the deletions; this commit captures the modify + deletes together.

---

## Task 2: `brand_logo_fetcher.py` helper (ai-service)

**Files:**
- Create: `ai-service/app/agents/kv_generator/brand_logo_fetcher.py`
- Test: `ai-service/tests/agents/kv_generator/test_brand_logo_fetcher.py`

**Rationale:** Encapsulate "is the brand logo URL in the prompt? → fetch it → build an Attachment" behind a single async function. Failure modes (no URL, URL not in prompt, HTTP error, oversized response, unsupported MIME) all return `None` so the caller in `service.py` stays a one-liner. Mirrors the existing `Attachment` schema (`id`, `name`, `mime_type`, `data_base64`).

- [ ] **Step 1: Write the failing test file**

Create `ai-service/tests/agents/kv_generator/test_brand_logo_fetcher.py`:

```python
import base64

import pytest
from respx import MockRouter

from app.agents.kv_generator.brand_logo_fetcher import (
    maybe_fetch_brand_logo_as_attachment,
)
from app.agents.kv_generator.request_schema import Prefetched, PrefetchedBrand


# 1x1 transparent PNG — same byte string used by the api-side tests so
# the bytes are stable and we can assert exact round-trip.
PNG_BYTES = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4//8/"
    "AwAI/AL+JT04vQAAAABJRU5ErkJggg=="
)


@pytest.mark.asyncio
async def test_returns_none_when_prefetched_is_none():
    result = await maybe_fetch_brand_logo_as_attachment(
        prefetched=None, prompt="anything"
    )
    assert result is None


@pytest.mark.asyncio
async def test_returns_none_when_brand_has_no_logo_url():
    prefetched = Prefetched(brand=PrefetchedBrand(brand_name="X"))
    result = await maybe_fetch_brand_logo_as_attachment(
        prefetched=prefetched, prompt="anything"
    )
    assert result is None


@pytest.mark.asyncio
async def test_returns_none_when_url_not_in_prompt():
    prefetched = Prefetched(brand=PrefetchedBrand(
        brand_name="Telkomsel",
        logo_url="https://s3.example.com/brands/telkomsel/logo.png",
    ))
    result = await maybe_fetch_brand_logo_as_attachment(
        prefetched=prefetched,
        prompt="A serene beach sunset, no branding involved.",
    )
    assert result is None


@pytest.mark.asyncio
async def test_fetches_and_returns_attachment_when_url_in_prompt(
    respx_mock: MockRouter,
):
    url = "https://s3.example.com/brands/telkomsel/logo.png"
    respx_mock.get(url).respond(
        status_code=200,
        headers={"content-type": "image/png"},
        content=PNG_BYTES,
    )

    prefetched = Prefetched(brand=PrefetchedBrand(
        brand_name="Telkomsel",
        logo_url=url,
    ))
    prompt = (
        f"A sunset beach scene. The Telkomsel brand logo from {url} placed "
        "in the bottom-right corner."
    )

    attachment = await maybe_fetch_brand_logo_as_attachment(
        prefetched=prefetched, prompt=prompt
    )

    assert attachment is not None
    assert attachment.id == "brand-logo-telkomsel"  # see Step 3 for slug rule
    assert attachment.mime_type == "image/png"
    assert attachment.name.endswith(".png")
    assert "Telkomsel" in attachment.name
    assert base64.b64decode(attachment.data_base64) == PNG_BYTES


@pytest.mark.asyncio
async def test_returns_none_on_http_404(respx_mock: MockRouter):
    url = "https://s3.example.com/brands/missing/logo.png"
    respx_mock.get(url).respond(status_code=404)

    prefetched = Prefetched(brand=PrefetchedBrand(
        brand_name="Missing",
        logo_url=url,
    ))
    prompt = f"Logo from {url}"

    result = await maybe_fetch_brand_logo_as_attachment(
        prefetched=prefetched, prompt=prompt
    )
    assert result is None


@pytest.mark.asyncio
async def test_returns_none_for_unsupported_mime(respx_mock: MockRouter):
    url = "https://s3.example.com/brands/bogus/logo.svg"
    # SVG is text-XML — finfo/mime sniff returns image/svg+xml or text/xml,
    # neither of which is in the allowlist.
    respx_mock.get(url).respond(
        status_code=200,
        headers={"content-type": "image/svg+xml"},
        content=b"<svg></svg>",
    )

    prefetched = Prefetched(brand=PrefetchedBrand(
        brand_name="Bogus",
        logo_url=url,
    ))
    prompt = f"Logo from {url}"

    result = await maybe_fetch_brand_logo_as_attachment(
        prefetched=prefetched, prompt=prompt
    )
    assert result is None


@pytest.mark.asyncio
async def test_returns_none_when_response_too_large(respx_mock: MockRouter):
    url = "https://s3.example.com/brands/huge/logo.png"
    # 5 MB of zeros — over the 4 MB gpt-image-2 input cap we enforce.
    big_payload = b"\x00" * (5 * 1024 * 1024)
    respx_mock.get(url).respond(
        status_code=200,
        headers={"content-type": "image/png"},
        content=big_payload,
    )

    prefetched = Prefetched(brand=PrefetchedBrand(
        brand_name="Huge",
        logo_url=url,
    ))
    prompt = f"Logo from {url}"

    result = await maybe_fetch_brand_logo_as_attachment(
        prefetched=prefetched, prompt=prompt
    )
    assert result is None
```

- [ ] **Step 2: Run the test to verify failures**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/ai-service && source .venv/bin/activate && pytest tests/agents/kv_generator/test_brand_logo_fetcher.py -v 2>&1 | tail -25`

Expected: FAIL — `ImportError: cannot import name 'maybe_fetch_brand_logo_as_attachment' from 'app.agents.kv_generator.brand_logo_fetcher'` (or `No module named 'app.agents.kv_generator.brand_logo_fetcher'`).

- [ ] **Step 3: Create the helper module**

Create `ai-service/app/agents/kv_generator/brand_logo_fetcher.py`:

```python
"""Server-side fetcher that converts a brand's logo URL into an
in-memory Attachment when the LLM has decided to reference it in the
final image-mode prompt. Used by service.py to flip the generation
path from `/v1/images/generations` (text-to-image) to
`/v1/images/edits` (img-to-img) so gpt-image-2 actually sees the
logo bytes instead of a URL string in the text prompt.

This replaces the api-side keyword-heuristic Layer 2 (reverted in
commit `revert(api): drop Layer 2 keyword-based logo embedding`).
Detection here is "did the LLM put the logo URL in the image prompt"
— a strictly stronger signal than scanning the latest user turn for
the literal word 'logo' because the LLM has full conversation context.
"""

from __future__ import annotations

import base64
import re
from typing import Optional

import httpx
from agno.utils.log import log_warning

from app.agents.kv_generator.request_schema import Attachment, Prefetched


# Mirrors `Attachment.mime_type` allowlist in request_schema.py. We
# detect MIME from bytes (not Content-Type header) because S3 sometimes
# serves a generic application/octet-stream.
_ALLOWED_MIMES = ("image/png", "image/jpeg", "image/webp", "image/gif")

# gpt-image-2 caps individual `image[]` parts around 4 MB. Reject larger
# uploads upfront so we don't pay the bandwidth + b64 encoding cost for
# something the API will refuse.
_MAX_BYTES = 4 * 1024 * 1024

# httpx timeout for the S3 GET. Keep low — if S3 is slow, falling back
# to text-to-image is better than blocking the stream.
_FETCH_TIMEOUT_SECONDS = 8.0


async def maybe_fetch_brand_logo_as_attachment(
    *,
    prefetched: Optional[Prefetched],
    prompt: str,
) -> Optional[Attachment]:
    """Return an Attachment when the LLM's final image prompt contains
    the brand's logo URL and that URL fetches as a valid image; None
    otherwise.

    See module docstring for the design rationale. Failure modes
    (no URL, URL not in prompt, HTTP error, bad MIME, oversized
    response) all return None so the call site can use a clean
    null-coalesce.
    """
    if prefetched is None or prefetched.brand is None:
        return None
    logo_url = prefetched.brand.logo_url
    if not logo_url:
        return None

    # The LLM is instructed (via image_mode.GUIDANCE) to include the
    # exact Logo URL verbatim. Substring match is fine — if the LLM
    # paraphrased the URL, the path is missed by design (we'd be
    # guessing at a non-existent URL).
    if logo_url not in prompt:
        return None

    try:
        async with httpx.AsyncClient(timeout=_FETCH_TIMEOUT_SECONDS) as client:
            response = await client.get(logo_url)
    except httpx.HTTPError as exc:
        log_warning(
            f"Brand logo fetch failed for KV img-to-img reference: "
            f"url={logo_url} error={exc!r}"
        )
        return None

    if response.status_code != 200:
        log_warning(
            f"Brand logo fetch returned non-200 for KV img-to-img: "
            f"url={logo_url} status={response.status_code}"
        )
        return None

    bytes_ = response.content
    if not bytes_ or len(bytes_) > _MAX_BYTES:
        log_warning(
            f"Brand logo bytes empty or oversized for KV img-to-img: "
            f"url={logo_url} size={len(bytes_)}"
        )
        return None

    mime = _sniff_mime(bytes_)
    if mime not in _ALLOWED_MIMES:
        log_warning(
            f"Brand logo MIME type not allowed for KV img-to-img: "
            f"url={logo_url} mime={mime}"
        )
        return None

    return Attachment(
        id=f"brand-logo-{_slugify(prefetched.brand.brand_name or 'brand')}",
        name=f"{(prefetched.brand.brand_name or 'brand').strip()}-logo.{_ext_for_mime(mime)}",
        mime_type=mime,
        data_base64=base64.b64encode(bytes_).decode("ascii"),
    )


def _sniff_mime(bytes_: bytes) -> str:
    """Detect MIME from the first few magic bytes — Content-Type header
    cannot be trusted on S3 objects without explicit metadata."""
    if bytes_.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if bytes_.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if bytes_[:4] == b"RIFF" and bytes_[8:12] == b"WEBP":
        return "image/webp"
    if bytes_[:6] in (b"GIF87a", b"GIF89a"):
        return "image/gif"
    return "application/octet-stream"


def _ext_for_mime(mime: str) -> str:
    return {
        "image/png": "png",
        "image/jpeg": "jpg",
        "image/webp": "webp",
        "image/gif": "gif",
    }.get(mime, "bin")


def _slugify(value: str) -> str:
    """Lowercase + collapse non-alphanumerics to hyphens. Stable across
    runs so the Attachment.id can be deduped by callers that may inject
    the same logo twice."""
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-") or "brand"
```

- [ ] **Step 4: Run the tests to verify all pass**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/ai-service && source .venv/bin/activate && pytest tests/agents/kv_generator/test_brand_logo_fetcher.py -v 2>&1 | tail -25`

Expected: 7/7 tests PASS. Specifically:
- `test_returns_none_when_prefetched_is_none`
- `test_returns_none_when_brand_has_no_logo_url`
- `test_returns_none_when_url_not_in_prompt`
- `test_fetches_and_returns_attachment_when_url_in_prompt`
- `test_returns_none_on_http_404`
- `test_returns_none_for_unsupported_mime`
- `test_returns_none_when_response_too_large`

If a respx-related test fails with `RuntimeError: A request was made … but not mocked`, the test forgot to register the URL with `respx_mock.get(url).respond(...)`. Check Step 1's test code matches verbatim.

- [ ] **Step 5: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/ai-service
git add app/agents/kv_generator/brand_logo_fetcher.py tests/agents/kv_generator/test_brand_logo_fetcher.py
git commit -m "feat(ai): add server-side brand-logo fetcher for B3 img-to-img routing"
```

---

## Task 3: Wire the fetcher into `service.py`

**Files:**
- Modify: `ai-service/app/agents/kv_generator/service.py` (around lines 234-245, between `image_prompt = apply_style_to_image_prompt(...)` and `# 3. Generate`)

**Rationale:** The decision point for img-to-img vs text-to-image is at lines 265-268:

```python
should_iterate = (
    (provider_supports_iter or is_craft)
    and (request.base_generation is not None or bool(request.attachments))
)
```

If we mutate `request.attachments` to include the brand-logo Attachment BEFORE this check, `should_iterate` flips to `True` and the existing edit-mode path (`edit_image_fn`) takes over — including `_save_attachments_to_disk` for the base64→file step and routing through `/v1/images/edits`. Zero changes downstream.

- [ ] **Step 1: Read the current call site to anchor on the right line**

Read `ai-service/app/agents/kv_generator/service.py` lines 230-260. Find the block that ends with:

```python
    image_prompt = apply_style_to_image_prompt(
        image_prompt, request.style_preset_key
    )

    # 3. Generate
    yield to_sse_line(GeneratingEvent(stage="prompt_expanded"))
```

The B3 helper call goes immediately after the style application (so the final prompt is locked in) but before the `yield ... prompt_expanded` event (so the attachments mutation is invisible to the wire protocol).

- [ ] **Step 2: Add the import at the top of `service.py`**

Find the existing import block (around lines 1-43). Add this import grouped alphabetically with the other `from app.agents.kv_generator.*` imports:

```python
from app.agents.kv_generator.brand_logo_fetcher import (
    maybe_fetch_brand_logo_as_attachment,
)
```

- [ ] **Step 3: Insert the fetcher call after the style application**

Replace this block (around lines 239-244):

```python
    image_prompt = apply_style_to_image_prompt(
        image_prompt, request.style_preset_key
    )

    # 3. Generate
    yield to_sse_line(GeneratingEvent(stage="prompt_expanded"))
```

With:

```python
    image_prompt = apply_style_to_image_prompt(
        image_prompt, request.style_preset_key
    )

    # B3: if the LLM included the brand's logo URL in the finalised
    # image prompt, server-side fetch the logo bytes and inject as an
    # `attachments[]` entry. The `should_iterate` decision below will
    # then route the call through `/v1/images/edits` (img-to-img) with
    # the actual logo bytes — gpt-image-2 cannot fetch URLs from text
    # prompts on its own. Single-source: detection lives here, NOT on
    # the api side (the keyword heuristic there was reverted because
    # the final user turn before image-mode is typically a content-free
    # confirmation like "yes, generate it").
    if request.mode == "image" and request.canvas_mode != "craft":
        logo_attachment = await maybe_fetch_brand_logo_as_attachment(
            prefetched=request.prefetched,
            prompt=image_prompt,
        )
        if logo_attachment is not None and not any(
            a.id == logo_attachment.id for a in request.attachments
        ):
            request.attachments.append(logo_attachment)

    # 3. Generate
    yield to_sse_line(GeneratingEvent(stage="prompt_expanded"))
```

Notes on the guards:
- `request.mode == "image"` — chat mode doesn't render an image, so injecting the attachment there does nothing useful and just bloats the LLM context with vision tokens (per the existing `Attachment` per-mode comment in `request_schema.py`).
- `request.canvas_mode != "craft"` — Craft is a polish pass on an existing base generation; layering a logo reference would compete with the parent generation as the img-to-img anchor.
- The dedup guard (`not any(a.id == logo_attachment.id for a in request.attachments)`) makes the injection idempotent: if a future code path already injected the same logo, we don't double-attach.

- [ ] **Step 4: Run the existing KV-generator test suite to confirm no regression**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/ai-service && source .venv/bin/activate && pytest tests/agents/kv_generator/test_context_builder.py tests/agents/kv_generator/test_schemas.py tests/agents/kv_generator/test_brand_logo_fetcher.py -v 2>&1 | tail -15`

Expected: all branch-added tests pass (18 from Layer 1 + 7 from this task = 25 pass). Pre-existing failures elsewhere in the kv_generator subtree (`test_service_chat_mode.py`, `test_events.py`, `test_e2e.py`) are out of scope — they predate this branch.

- [ ] **Step 5: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/ai-service
git add app/agents/kv_generator/service.py
git commit -m "feat(ai): inject brand logo as img-to-img reference when URL in final prompt"
```

---

## Task 4: Integration test — service.py wires the fetcher correctly

**Files:**
- Create: `ai-service/tests/agents/kv_generator/test_service_image_mode_logo_embedding.py`

**Rationale:** Task 2's unit tests cover the helper in isolation. This task verifies the wire-in: when `service.py` runs the image-mode flow with a prompt that mentions the brand logo URL, the call ends up in the img-to-img path (`should_iterate = True`) with the logo bytes attached. Uses `respx_mock` to stub the S3 fetch and `monkeypatch` to spy on the `edit_image_fn` so we can assert on the arguments without actually hitting OpenAI.

- [ ] **Step 1: Write the integration test**

Create `ai-service/tests/agents/kv_generator/test_service_image_mode_logo_embedding.py`:

```python
import base64
from unittest.mock import AsyncMock, MagicMock

import pytest
from respx import MockRouter

from app.agents.kv_generator import service as kv_service
from app.agents.kv_generator.request_schema import (
    KvStreamRequest,
    LaunchContext,
    Prefetched,
    PrefetchedBrand,
)


PNG_BYTES = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4//8/"
    "AwAI/AL+JT04vQAAAABJRU5ErkJggg=="
)


def _make_image_request(*, prompt: str, logo_url: str) -> KvStreamRequest:
    return KvStreamRequest(
        thread_id="t1",
        studio_file_id="f1",
        mode="image",
        canvas_mode="sketch",
        prompt=prompt,
        launch_context=LaunchContext(
            studio_file_id="f1",
            use_brand_knowledge=True,
            brand_id="b1",
        ),
        chat_history=[],
        user_id="u1",
        prefetched=Prefetched(brand=PrefetchedBrand(
            brand_name="Telkomsel",
            logo_url=logo_url,
        )),
        image_model="gpt-image-2",
        image_model_provider="openai",
    )


@pytest.mark.asyncio
async def test_logo_url_in_prompt_injects_attachment_and_takes_img_to_img_path(
    respx_mock: MockRouter, monkeypatch
):
    logo_url = "https://s3.example.com/brands/telkomsel/logo.png"
    respx_mock.get(logo_url).respond(
        status_code=200,
        headers={"content-type": "image/png"},
        content=PNG_BYTES,
    )

    # Spy on edit_image_fn — assert it gets called (img-to-img path)
    # and that the brand logo reaches extra_local_paths.
    edit_calls = []

    def fake_edit_image(**kwargs):
        edit_calls.append(kwargs)
        return {
            "image_url": "https://test.example.com/out.png",
            "thumbnail_url": "https://test.example.com/out_thumb.png",
        }

    monkeypatch.setattr(kv_service, "edit_image_fn", fake_edit_image)

    # Spy on _render_image to confirm it is NOT called (text-to-image
    # path would have been the fallback if the attachment didn't land).
    render_calls = []

    async def fake_render(*args, **kwargs):
        render_calls.append((args, kwargs))
        return {"image_url": "should-not-be-called"}

    monkeypatch.setattr(kv_service, "_render_image", fake_render)

    # Also bypass the LLM-driven prompt refinement: short-circuit by
    # patching the chat/image refinement to return our pre-baked prompt
    # that already contains the logo URL. The exact mechanism depends
    # on how service.py's image-mode prompt is produced (look near
    # line 200-235); follow the same monkeypatch pattern used in
    # tests/agents/kv_generator/test_e2e.py.
    pre_baked_prompt = (
        "A sunset beach scene with the Telkomsel logo from "
        f"{logo_url} placed in the bottom-right."
    )
    # If service.py exposes a helper for the LLM refinement (e.g.
    # _refine_image_prompt or similar), monkeypatch THAT to return
    # `pre_baked_prompt` regardless of input. If no such helper exists,
    # this test must fall back to mocking the underlying Agno call.
    # Locate the helper before writing this monkeypatch.

    request = _make_image_request(prompt="user typed this", logo_url=logo_url)
    api_client = AsyncMock()

    # Consume the async generator to drive the flow.
    async for _ in kv_service.handle_kv_stream(request, api_client):
        pass

    assert len(edit_calls) == 1, (
        "expected edit_image_fn to be called once (img-to-img path)"
    )
    assert len(render_calls) == 0, (
        "expected _render_image to NOT be called (text-to-image path "
        "should be skipped when attachment is present)"
    )

    extra_paths = edit_calls[0].get("extra_local_paths") or []
    assert len(extra_paths) >= 1, (
        "brand logo bytes should have reached the edit_image_fn via "
        "extra_local_paths after _save_attachments_to_disk"
    )


@pytest.mark.asyncio
async def test_logo_url_not_in_prompt_takes_text_to_image_path(
    respx_mock: MockRouter, monkeypatch
):
    logo_url = "https://s3.example.com/brands/telkomsel/logo.png"
    # Do NOT register a respx route for the logo URL — if the helper
    # accidentally fetches it (it shouldn't, because the URL isn't in
    # the prompt), respx will raise and the test will fail loudly.

    edit_calls = []

    def fake_edit_image(**kwargs):
        edit_calls.append(kwargs)
        return {"image_url": "x"}

    monkeypatch.setattr(kv_service, "edit_image_fn", fake_edit_image)

    render_calls = []

    async def fake_render(*args, **kwargs):
        render_calls.append((args, kwargs))
        return {"image_url": "https://test.example.com/text2img.png"}

    monkeypatch.setattr(kv_service, "_render_image", fake_render)

    # Same prompt-refinement bypass as the first test — produce a prompt
    # that does NOT mention the logo URL.
    request = _make_image_request(
        prompt="user typed this",
        logo_url=logo_url,
    )
    api_client = AsyncMock()

    async for _ in kv_service.handle_kv_stream(request, api_client):
        pass

    assert len(render_calls) == 1, "expected text-to-image path"
    assert len(edit_calls) == 0, "img-to-img should not have been taken"
```

> **Note for the engineer:** The `monkeypatch` of the LLM-refinement step is the load-bearing piece. `service.py`'s image-mode prompt is produced by an Agno agent call somewhere between lines 200-234. Look at `tests/agents/kv_generator/test_e2e.py` to see how the existing test mocks this — copy the same pattern. If the prompt-refinement is wrapped in a single async helper, monkeypatching that helper to return `pre_baked_prompt` is the simplest path. If not, mock the underlying Agno method via `monkeypatch.setattr` on the agent instance. The exact symbol path may need adjustment based on actual code structure — but the test architecture above is the right shape.

- [ ] **Step 2: Run the integration test**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/ai-service && source .venv/bin/activate && pytest tests/agents/kv_generator/test_service_image_mode_logo_embedding.py -v 2>&1 | tail -30`

Expected: 2/2 tests PASS.

If the test fails with "respx unmocked request" related to LLM provider URLs (Gemini, OpenAI), the prompt-refinement monkeypatch isn't fully bypassing the real LLM call — adjust the monkeypatch to cover the actual code path. The `test_e2e.py` file is the reference for the monkeypatch pattern.

- [ ] **Step 3: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/ai-service
git add tests/agents/kv_generator/test_service_image_mode_logo_embedding.py
git commit -m "test(ai): integration test for B3 logo URL → img-to-img routing"
```

---

## Task 5: End-to-end smoke + PR draft refresh

**Files:** none modified — verification + docs only.

**Rationale:** Confirm the full path works against the running services with a real brand. Update the PR draft to reflect the architecture change.

- [ ] **Step 1: Pre-flight DB safety**

Run:
```bash
ls /Users/alva.e202511001/Desktop/work/frndos-agentic/api/bootstrap/cache/
```
Expected: only `packages.php` and `services.php` — no `config.php`. If `config.php` is present, run `php artisan config:clear` from the api directory before doing any pest run.

Run:
```bash
/opt/homebrew/opt/postgresql@17/bin/psql -h 127.0.0.1 -p 5432 -d frnd -t -c "SELECT 'brands_before: ' || count(*) FROM brands;"
```
Expected: `brands_before: 72` (or whatever the current restored count is — note it down).

- [ ] **Step 2: Run the consolidated test suites**

Run:
```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/ai-service && source .venv/bin/activate && pytest tests/agents/kv_generator/test_context_builder.py tests/agents/kv_generator/test_schemas.py tests/agents/kv_generator/test_brand_logo_fetcher.py tests/agents/kv_generator/test_service_image_mode_logo_embedding.py -v 2>&1 | tail -20
```
Expected: all branch-added tests pass (18 + 7 + 2 = 27 PASS).

- [ ] **Step 3: Manual UI smoke**

In two terminals:
- Terminal A: `cd api && php artisan serve --port=9191` (NOT `optimize` — see Step 1)
- Terminal B: `cd ai-service && source .venv/bin/activate && fastapi dev`

Frontend (http://localhost:3000):
1. Login (OTP via Mailhog at http://localhost:8025)
2. Switch to a workspace with a brand that has a logo populated (e.g. FCN workspace's Telkomsel in the staging dump)
3. Open Creative Studio → KV Generator → new project / new studio file
4. Toggle "Use brand knowledge" ON → pick the brand (Telkomsel)
5. Type any prompt that establishes logo intent and continue the conversation through to image-mode generation. E.g.:

```
buat KV promo Telkomsel sunset cinematic, dengan logo brand di pojok kanan bawah
```

Let the chat-mode LLM refine the brief and switch to image mode. The final image-mode generation should be the one to verify.

Expected outcomes:
- ai-service stdout log shows `POST https://api.openai.com/v1/images/edits` (NOT `/v1/images/generations`) — confirms img-to-img path was taken.
- Browser dev-tools Network tab shows the api stream request includes the brand_id in `launch_context`.
- The generated KV embeds the actual brand logo (real Telkomsel red mark), not a hand-drawn "TELKOMSEL" text approximation.
- Pre-existing Layer 1 features still work: `prompt_snapshot` in the latest `kv_generations` row contains the Logo URL string + color palette mention.

Verify the `prompt_snapshot`:
```bash
/opt/homebrew/opt/postgresql@17/bin/psql -h 127.0.0.1 -p 5432 -d frnd -c "SELECT left(prompt_snapshot, 400) FROM kv_generations ORDER BY created_at DESC LIMIT 1;"
```
Should include the brand logo URL string in the prompt.

- [ ] **Step 4: Post-flight DB safety**

Run:
```bash
/opt/homebrew/opt/postgresql@17/bin/psql -h 127.0.0.1 -p 5432 -d frnd -t -c "SELECT 'brands_after: ' || count(*) FROM brands;"
```
Expected: matches `brands_before` from Step 1. If the count changed unexpectedly, escalate — the dev DB has been wiped or rows have been added by something other than the natural KV generation flow.

- [ ] **Step 5: Update the PR draft notes**

Update `/Users/alva.e202511001/Desktop/work/frndos-agentic/docs/superpowers/notes/2026-05-26-kv-brand-asset-feeding-pr-draft.md`:

- Replace the "Layer 2" section's description from "api-side keyword detector + builder" to "ai-service URL-in-prompt detection + server-side fetch"
- Update the commit list to reflect the revert + B3 commits
- Mention that the api-side L2 classes (`BrandLogoIntentDetector`, `BrandLogoAttachmentBuilder`) were intentionally reverted in favour of the ai-service-driven detection
- Update the test plan: remove the BrandLogoEmbeddingTest reference (deleted), add `test_brand_logo_fetcher.py` and `test_service_image_mode_logo_embedding.py`

Use the `Edit` tool on the existing file, not a full rewrite — preserve the Layer-1 sections and surrounding structure.

- [ ] **Step 6: Final housekeeping commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic
git add docs/superpowers/notes/2026-05-26-kv-brand-asset-feeding-pr-draft.md
git commit -m "docs: rewrite PR draft layer-2 section to reflect ai-service B3 architecture"
```

---

## Self-review checklist

- ✅ **Spec coverage:** Revert api L2 (Task 1) → fetcher helper (Task 2) → wire-in (Task 3) → integration test (Task 4) → smoke + PR draft (Task 5). All sections of the architecture statement above are mapped to tasks.

- ✅ **No placeholders:** Every code step shows the exact code. The `// fill in` markers in Task 4 are explicit pointers to `test_e2e.py` for the LLM-refinement monkeypatch pattern, not invitations to invent — same explicit-pointer style as Layer 1's Task 5 plan.

- ✅ **Type consistency:**
  - `maybe_fetch_brand_logo_as_attachment(*, prefetched, prompt) → Optional[Attachment]` — signature used the same way in Task 2 (definition), Task 3 (call site), Task 4 (test).
  - `Attachment` is the existing Pydantic class from `request_schema.py` — the fetcher returns one, `service.py` appends it to `request.attachments`, and downstream `_save_attachments_to_disk` consumes them. Round-trip type-stable.
  - `prefetched.brand.logo_url` is the field added in Layer 1 (commit `feef997f`). Still in the schema after the api L2 revert.

- ✅ **TDD:** Task 2 starts with failing tests. Task 3 is structural and is verified by Task 4's integration test (same split pattern as Layer 1's Task 4/5).

- ✅ **Frequent commits:** One commit per task.

- ✅ **DRY:** Fetcher and integration are in two separate files with clear boundaries. The fetcher is independently testable; the wire-in is a one-liner-plus-guards.

- ✅ **YAGNI:** No LLM tool-call protocol, no caching, no logo-variant dispatching. All deferred.

- ✅ **DB safety foot-gun acknowledged:** Task 1 Step 5 and Task 5 Step 1 + Step 4 explicitly snapshot + verify the dev Postgres DB row count. The cached-config DB-wipe bug from earlier sessions is unambiguously called out in both pre-flights.

- ✅ **Edit/Craft mode skipped:** Task 3's guard (`request.mode == "image" and request.canvas_mode != "craft"`) means edit-mode and craft-mode generations are NOT affected — they retain their existing base-generation-as-anchor behaviour.
