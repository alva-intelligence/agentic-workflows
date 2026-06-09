# KV Resize Prompt-Driven Logo Placement — AI Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a KV-resize `additional_prompt` move/resize the stamped brand logo by parsing a logo directive from the prompt and overlaying it onto the persisted stamp, while stripping the logo instruction out of the image-model guidance so gpt-image-2 never draws a logo.

**Architecture:** Reuse the kv_generator logo helpers (`classify_logo_directive`, `strip_logo_sentences`) inside the resize pipeline. A new `_resolve_logo_placement(req)` returns `(effective_stamp, scene_prompt)`; `process_resize_export` merges `scene_prompt` (not the raw prompt) into the model guidance and stamps with `effective_stamp`. Overlay semantics keep unspecified stamp fields; `remove` is ignored; behavior is byte-identical to today when there is no prompt or no logo.

**Tech Stack:** FastAPI, Python, pytest, OpenAI gpt-4o-mini (logo classifier) + gpt-image-2

---

## Conventions

- **Working dir:** `/Users/alva.e202511001/Desktop/work/frndos-agentic/ai-service`
- **Run tests:** `.venv/bin/python -m pytest <path> -q`
- **Test style (from `tests/agents/kv_resize/test_service.py`):** plain pytest fns; OpenAI/network never hit — `reframe`, `outpaint`, `analyze`, `requests.get`, `save_bytes_to_file`, `post_completed` patched at `app.agents.kv_resize.service.*`. Guidance asserted via `mock_reframe.call_args.args[3]` / `mock_outpaint.call_args.args[2]`.
- The async `classify_logo_directive` is patched with `unittest.mock.AsyncMock` (so `asyncio.run` can await it).

## File structure

- Modify `app/agents/kv_generator/logo_stamp.py` — add `allow_empty` to `strip_logo_sentences`.
- Modify `app/agents/kv_resize/service.py` — imports, `_overlay_stamp`, `_resolve_logo_placement`, wire into `process_resize_export`.
- Create `tests/agents/kv_generator/test_strip_logo_allow_empty.py`.
- Create `tests/agents/kv_resize/test_logo_placement.py`.

---

## Task 1: Add `allow_empty` to `strip_logo_sentences`

**Files:**
- Modify: `app/agents/kv_generator/logo_stamp.py` (signature ~L51, final return ~L80-81)
- Test: `tests/agents/kv_generator/test_strip_logo_allow_empty.py` (Create)

Steps:

- [ ] 1. Write the failing test. Create `tests/agents/kv_generator/test_strip_logo_allow_empty.py`:

```python
from app.agents.kv_generator.logo_stamp import strip_logo_sentences


def test_allow_empty_returns_empty_when_all_logo():
    assert strip_logo_sentences("Move the logo to the top right.", allow_empty=True) == ""


def test_default_keeps_original_when_all_logo():
    # kv_generator relies on never sending an empty prompt — default unchanged.
    out = strip_logo_sentences("Move the logo to the top right.")
    assert out == "Move the logo to the top right."


def test_non_logo_prompt_unchanged_either_way():
    p = "Make the background darker and moodier."
    assert strip_logo_sentences(p, allow_empty=True) == p
    assert strip_logo_sentences(p) == p


def test_mixed_sentences_strip_only_logo_sentence():
    p = "Make the background darker. Put the logo bottom-left."
    assert strip_logo_sentences(p, allow_empty=True) == "Make the background darker."
```

- [ ] 2. Run — expect FAIL (`allow_empty` is not a valid kwarg → TypeError):

```bash
.venv/bin/python -m pytest tests/agents/kv_generator/test_strip_logo_allow_empty.py -q
```

- [ ] 3. Minimal implementation. In `app/agents/kv_generator/logo_stamp.py`, change the signature:

```python
def strip_logo_sentences(
    prompt: str, brand_name: Optional[str] = None, allow_empty: bool = False
) -> str:
```

and replace the final return (currently `result = " ".join(kept).strip()` then `return result or prompt`):

```python
    result = " ".join(kept).strip()
    if allow_empty:
        return result
    return result or prompt
```

- [ ] 4. Run — expect PASS:

```bash
.venv/bin/python -m pytest tests/agents/kv_generator/test_strip_logo_allow_empty.py -q
```

  (The `test_default_keeps_original_when_all_logo` case is the regression guard — `allow_empty=False` still returns the original, so kv_generator's behavior is unchanged.)

- [ ] 5. Commit:

```bash
git add app/agents/kv_generator/logo_stamp.py tests/agents/kv_generator/test_strip_logo_allow_empty.py
git commit -m "feat(ai): add allow_empty to strip_logo_sentences"
```

---

## Task 2: `_overlay_stamp` helper + imports in resize service

**Files:**
- Modify: `app/agents/kv_resize/service.py` (imports ~L28; add helper near the other module-level helpers, after `_merge_additional_prompt`)
- Test: `tests/agents/kv_resize/test_logo_placement.py` (Create)

Steps:

- [ ] 1. Write the failing test. Create `tests/agents/kv_resize/test_logo_placement.py`:

```python
from app.agents.kv_generator.request_schema import BrandLogoStamp, LogoDirective
from app.agents.kv_resize.service import _overlay_stamp


def _stamp(anchor="bottom-right", scale="large"):
    return BrandLogoStamp(anchor=anchor, scale=scale)


def test_overlay_place_anchor_only_keeps_scale():
    out = _overlay_stamp(_stamp(scale="large"),
                         LogoDirective(action="place", anchor="top-right"))
    assert out.anchor == "top-right"
    assert out.scale == "large"


def test_overlay_place_scale_only_keeps_anchor():
    out = _overlay_stamp(_stamp(anchor="bottom-right"),
                         LogoDirective(action="place", scale="small"))
    assert out.anchor == "bottom-right"
    assert out.scale == "small"


def test_overlay_none_returns_persisted():
    base = _stamp()
    assert _overlay_stamp(base, LogoDirective(action="none")) is base


def test_overlay_remove_ignored_returns_persisted():
    base = _stamp()
    assert _overlay_stamp(base, LogoDirective(action="remove")) is base
```

- [ ] 2. Run — expect FAIL (ImportError: `_overlay_stamp`):

```bash
.venv/bin/python -m pytest tests/agents/kv_resize/test_logo_placement.py -q
```

- [ ] 3. Minimal implementation. In `app/agents/kv_resize/service.py`:

Add `import asyncio` near the top stdlib imports. Extend the existing logo_stamp import (L28) and add two more imports:

```python
from app.agents.kv_generator.logo_stamp import stamp_logo, strip_logo_sentences
from app.agents.kv_generator.logo_directive import classify_logo_directive
from app.agents.kv_generator.request_schema import BrandLogoStamp, LogoDirective
```

Add the helper after `_merge_additional_prompt`:

```python
def _overlay_stamp(persisted: BrandLogoStamp, directive: LogoDirective) -> BrandLogoStamp:
    """Adjust the persisted logo stamp from a parsed prompt directive.

    Only `place` adjusts placement, and unspecified fields are KEPT (overlay,
    not reset) — "move it top-right" must not also shrink the logo. `remove` is
    ignored in resize (the brand logo stays mandatory); `none` = no change.
    """
    if directive.action != "place":
        return persisted
    return BrandLogoStamp(
        anchor=directive.anchor or persisted.anchor,
        scale=directive.scale or persisted.scale,
    )
```

- [ ] 4. Run — expect PASS:

```bash
.venv/bin/python -m pytest tests/agents/kv_resize/test_logo_placement.py -q
```

- [ ] 5. Commit:

```bash
git add app/agents/kv_resize/service.py tests/agents/kv_resize/test_logo_placement.py
git commit -m "feat(ai): add _overlay_stamp + logo helper imports to resize service"
```

---

## Task 3: `_resolve_logo_placement` helper

**Files:**
- Modify: `app/agents/kv_resize/service.py` (add helper after `_overlay_stamp`)
- Test: `tests/agents/kv_resize/test_logo_placement.py` (extend)

Steps:

- [ ] 1. Append the failing tests to `tests/agents/kv_resize/test_logo_placement.py` (add imports at the top of the file too):

```python
from unittest.mock import AsyncMock, patch

from app.agents.kv_generator.request_schema import BrandLogoAsset
from app.agents.kv_resize.request_schema import ResizeExportRequest
from app.agents.kv_resize.service import _resolve_logo_placement


def _req(**kw):
    base = dict(
        export_id="x", source_image_url="https://s/in.png",
        target_width=1080, target_height=1080,
    )
    base.update(kw)
    return ResizeExportRequest(**base)


def _logo():
    return BrandLogoAsset(data_base64="eA==", mime_type="image/png")


@patch("app.agents.kv_resize.service.classify_logo_directive", new_callable=AsyncMock)
def test_resolve_moves_logo_and_strips_prompt(mock_classify):
    mock_classify.return_value = LogoDirective(action="place", anchor="top-right")
    req = _req(
        additional_prompt="pindahkan logo ke kanan atas",
        brand_logo=_logo(),
        brand_logo_stamp=BrandLogoStamp(anchor="bottom-right", scale="large"),
    )
    stamp, scene = _resolve_logo_placement(req)
    assert stamp.anchor == "top-right"
    assert stamp.scale == "large"   # kept
    assert scene == ""              # pure-logo prompt stripped to empty


@patch("app.agents.kv_resize.service.classify_logo_directive", new_callable=AsyncMock)
def test_resolve_scene_only_prompt_no_override(mock_classify):
    mock_classify.return_value = LogoDirective(action="none")
    req = _req(
        additional_prompt="make the background darker",
        brand_logo=_logo(),
        brand_logo_stamp=BrandLogoStamp(anchor="bottom-right", scale="medium"),
    )
    stamp, scene = _resolve_logo_placement(req)
    assert stamp.anchor == "bottom-right" and stamp.scale == "medium"
    assert scene == "make the background darker"


def test_resolve_no_prompt_passthrough():
    req = _req(brand_logo=_logo(),
               brand_logo_stamp=BrandLogoStamp(anchor="center", scale="small"))
    stamp, scene = _resolve_logo_placement(req)
    assert stamp.anchor == "center"
    assert scene is None


def test_resolve_no_logo_passthrough():
    req = _req(additional_prompt="make it warmer")
    stamp, scene = _resolve_logo_placement(req)
    assert stamp is None
    assert scene == "make it warmer"


@patch("app.agents.kv_resize.service.classify_logo_directive", new_callable=AsyncMock)
def test_resolve_classify_failure_falls_back_to_none(mock_classify):
    mock_classify.side_effect = RuntimeError("boom")
    req = _req(
        additional_prompt="pindahkan logo ke kanan atas",
        brand_logo=_logo(),
        brand_logo_stamp=BrandLogoStamp(anchor="bottom-right", scale="medium"),
    )
    stamp, scene = _resolve_logo_placement(req)
    assert stamp.anchor == "bottom-right"   # no override on failure
    assert scene == ""                       # still stripped (safe)
```

- [ ] 2. Run — expect FAIL (ImportError: `_resolve_logo_placement`):

```bash
.venv/bin/python -m pytest tests/agents/kv_resize/test_logo_placement.py -q
```

- [ ] 3. Minimal implementation. Add after `_overlay_stamp` in `service.py`:

```python
def _resolve_logo_placement(
    req: ResizeExportRequest,
) -> tuple[Optional[BrandLogoStamp], Optional[str]]:
    """Return (effective_stamp, scene_prompt) for this export.

    When the export carries BOTH an additional_prompt and a brand logo to
    stamp, classify the prompt for a logo directive, overlay it onto the
    persisted stamp, and strip the logo instruction out of the scene prompt so
    the image model never draws a logo. Otherwise passthrough unchanged. The
    classifier never breaks the export (falls back to action=none).
    """
    logo_present = req.brand_logo is not None and req.brand_logo_stamp is not None
    if not req.additional_prompt or not logo_present:
        return req.brand_logo_stamp, req.additional_prompt

    try:
        directive = asyncio.run(
            classify_logo_directive(
                chat_history=[],
                user_prompt=req.additional_prompt,
                logo_available=True,
            )
        )
    except Exception:  # noqa: BLE001 — classifier must never break the export
        directive = LogoDirective(action="none")

    effective_stamp = _overlay_stamp(req.brand_logo_stamp, directive)
    scene_prompt = strip_logo_sentences(req.additional_prompt, allow_empty=True)
    return effective_stamp, scene_prompt
```

> `process_resize_export` runs as a FastAPI sync BackgroundTask (Starlette runs it in a threadpool with no running event loop), so `asyncio.run` is safe here.

- [ ] 4. Run — expect PASS:

```bash
.venv/bin/python -m pytest tests/agents/kv_resize/test_logo_placement.py -q
```

- [ ] 5. Commit:

```bash
git add app/agents/kv_resize/service.py tests/agents/kv_resize/test_logo_placement.py
git commit -m "feat(ai): add _resolve_logo_placement (classify + overlay + strip)"
```

---

## Task 4: Wire `_resolve_logo_placement` into `process_resize_export`

**Files:**
- Modify: `app/agents/kv_resize/service.py` (`process_resize_export` — ~L124, L154, L203, L210, L216)
- Test: `tests/agents/kv_resize/test_logo_placement.py` (extend)

Steps:

- [ ] 1. Append the failing integration test (add the listed imports/helper at the top of the test file if not already present):

```python
from io import BytesIO
from unittest.mock import MagicMock
from PIL import Image

from app.agents.kv_resize.service import process_resize_export
from app.agents.kv_resize.prompts.outpaint import OUTPAINT_GUIDANCE


def _png_bytes(w, h, color=(0, 200, 100)):
    img = Image.new("RGB", (w, h), color)
    buf = BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


@patch("app.agents.kv_resize.service.classify_logo_directive", new_callable=AsyncMock)
@patch("app.agents.kv_resize.service.requests.get")
@patch("app.agents.kv_resize.service.outpaint")
@patch("app.agents.kv_resize.service.stamp_logo")
@patch("app.agents.kv_resize.service.save_bytes_to_file")
@patch("app.agents.kv_resize.service.post_completed")
def test_process_moves_logo_and_keeps_logo_out_of_guidance(
    mock_pc, mock_save, mock_stamp, mock_outpaint, mock_get, mock_classify
):
    mock_get.return_value = MagicMock(ok=True, content=_png_bytes(800, 600), status_code=200)
    mock_outpaint.return_value = (b"OUT", "gpt-image-2", {})
    mock_stamp.return_value = b"STAMPED"
    mock_save.return_value = "https://cdn/out.png"
    mock_classify.return_value = LogoDirective(action="place", anchor="top-right")

    req = ResizeExportRequest(
        export_id="x", source_image_url="https://s/in.png",
        target_width=1080, target_height=1920, use_vision_prepass=False,
        additional_prompt="pindahkan logo ke kanan atas",
        brand_logo=BrandLogoAsset(data_base64="eA==", mime_type="image/png"),
        brand_logo_stamp=BrandLogoStamp(anchor="bottom-right", scale="large"),
    )
    process_resize_export(req)

    stamp_arg = mock_stamp.call_args.args[2]      # stamp_logo(scene, bytes, stamp)
    assert stamp_arg.anchor == "top-right"
    assert stamp_arg.scale == "large"             # scale kept
    guidance = mock_outpaint.call_args.args[2]
    assert "User instructions" not in guidance    # logo instruction not leaked
    assert guidance == OUTPAINT_GUIDANCE
```

- [ ] 2. Run — expect FAIL (stamp still uses persisted `bottom-right`; guidance still contains the raw logo prompt):

```bash
.venv/bin/python -m pytest tests/agents/kv_resize/test_logo_placement.py::test_process_moves_logo_and_keeps_logo_out_of_guidance -q
```

- [ ] 3. Wire it in `process_resize_export`. Immediately after `source = _download(req.source_image_url)` (L124), add:

```python
        effective_stamp, scene_prompt = _resolve_logo_placement(req)
```

Replace the reframe-path merge (L154) `guidance = _merge_additional_prompt(guidance, req.additional_prompt)` with:

```python
            guidance = _merge_additional_prompt(guidance, scene_prompt)
```

Replace the outpaint-path merge (L203) `guidance = _merge_additional_prompt(guidance, req.additional_prompt)` with:

```python
            guidance = _merge_additional_prompt(guidance, scene_prompt)
```

Replace the logo re-bake block guard + stamp arg (L210, L216). Change the `if` from:

```python
        if req.brand_logo is not None and req.brand_logo_stamp is not None:
```

to:

```python
        if req.brand_logo is not None and effective_stamp is not None:
```

and change the `stamp_logo(...)` third argument from `req.brand_logo_stamp,` to:

```python
                    effective_stamp,
```

- [ ] 4. Run — expect PASS:

```bash
.venv/bin/python -m pytest tests/agents/kv_resize/test_logo_placement.py::test_process_moves_logo_and_keeps_logo_out_of_guidance -q
```

- [ ] 5. Commit:

```bash
git add app/agents/kv_resize/service.py tests/agents/kv_resize/test_logo_placement.py
git commit -m "feat(ai): move stamped logo from prompt in resize pipeline"
```

---

## Task 5: Regression — no prompt is legacy; remove is ignored

**Files:**
- Modify: none
- Test: `tests/agents/kv_resize/test_logo_placement.py` (extend)

Steps:

- [ ] 1. Append the regression tests:

```python
@patch("app.agents.kv_resize.service.classify_logo_directive", new_callable=AsyncMock)
@patch("app.agents.kv_resize.service.requests.get")
@patch("app.agents.kv_resize.service.outpaint")
@patch("app.agents.kv_resize.service.stamp_logo")
@patch("app.agents.kv_resize.service.save_bytes_to_file")
@patch("app.agents.kv_resize.service.post_completed")
def test_process_no_prompt_is_legacy(
    mock_pc, mock_save, mock_stamp, mock_outpaint, mock_get, mock_classify
):
    mock_get.return_value = MagicMock(ok=True, content=_png_bytes(800, 600), status_code=200)
    mock_outpaint.return_value = (b"OUT", "gpt-image-2", {})
    mock_stamp.return_value = b"STAMPED"
    mock_save.return_value = "https://cdn/out.png"

    req = ResizeExportRequest(
        export_id="x", source_image_url="https://s/in.png",
        target_width=1080, target_height=1920, use_vision_prepass=False,
        brand_logo=BrandLogoAsset(data_base64="eA==", mime_type="image/png"),
        brand_logo_stamp=BrandLogoStamp(anchor="bottom-right", scale="medium"),
    )
    process_resize_export(req)

    mock_classify.assert_not_called()              # no prompt => no classifier call
    assert mock_outpaint.call_args.args[2] == OUTPAINT_GUIDANCE
    assert mock_stamp.call_args.args[2].anchor == "bottom-right"


@patch("app.agents.kv_resize.service.classify_logo_directive", new_callable=AsyncMock)
@patch("app.agents.kv_resize.service.requests.get")
@patch("app.agents.kv_resize.service.outpaint")
@patch("app.agents.kv_resize.service.stamp_logo")
@patch("app.agents.kv_resize.service.save_bytes_to_file")
@patch("app.agents.kv_resize.service.post_completed")
def test_process_remove_is_ignored(
    mock_pc, mock_save, mock_stamp, mock_outpaint, mock_get, mock_classify
):
    mock_get.return_value = MagicMock(ok=True, content=_png_bytes(800, 600), status_code=200)
    mock_outpaint.return_value = (b"OUT", "gpt-image-2", {})
    mock_stamp.return_value = b"STAMPED"
    mock_save.return_value = "https://cdn/out.png"
    mock_classify.return_value = LogoDirective(action="remove")

    req = ResizeExportRequest(
        export_id="x", source_image_url="https://s/in.png",
        target_width=1080, target_height=1920, use_vision_prepass=False,
        additional_prompt="hapus logo nya",
        brand_logo=BrandLogoAsset(data_base64="eA==", mime_type="image/png"),
        brand_logo_stamp=BrandLogoStamp(anchor="bottom-right", scale="medium"),
    )
    process_resize_export(req)

    mock_stamp.assert_called_once()                # remove ignored: still stamped
    assert mock_stamp.call_args.args[2].anchor == "bottom-right"
```

- [ ] 2. Run — expect PASS:

```bash
.venv/bin/python -m pytest tests/agents/kv_resize/test_logo_placement.py -q -k "no_prompt or remove"
```

- [ ] 3. Run the full resize + kv_generator suites (expect green; confirms iteration-1 resize tests + kv_generator logo tests still pass):

```bash
.venv/bin/python -m pytest tests/agents/kv_resize tests/agents/kv_generator -q
```

- [ ] 4. Commit:

```bash
git add tests/agents/kv_resize/test_logo_placement.py
git commit -m "feat(ai): regression — no-prompt legacy + remove ignored in resize logo"
```

---

## Done criteria

- A `place` prompt moves/resizes the stamped logo via an anchor/scale overlay on the persisted stamp (unspecified fields kept).
- `remove` is ignored; the logo is always stamped (when present on the file).
- The logo instruction never reaches gpt-image-2 (stripped); a scene clause, if present, still does.
- No `additional_prompt` reproduces iteration-1 behavior exactly (no classifier call, legacy guidance, persisted stamp).
- `stamp_logo`, api, and web are unchanged.
- `.venv/bin/python -m pytest tests/agents/kv_resize tests/agents/kv_generator -q` is green.
