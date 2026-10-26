# KV Resize Fidelity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make KV resize stop repainting pixels it was never asked to change — an honest mask, a real subject box, and a model that is told to leave the product's own artwork alone.

**Architecture:** Three independent changes in `ai-service` (mask geometry, vision output shape, prompt constraints) plus one cross-repo change that turns the hardcoded image model into configuration and registers its pricing in `api` so a switched model cannot bill zero credits.

**Tech Stack:** Python 3.11 / FastAPI / Pillow / pytest (ai-service); PHP 8.5 / Laravel / Pest (api).

**Spec:** `docs/superpowers/specs/2026-09-15-kv-resize-fidelity-design.md`

## Global Constraints

- **`api/` and `ai-service/` are each their own git repository**, not folders of one repo. Run every `git add` / `git commit` from *inside* the service directory, and strip the leading `api/` or `ai-service/` from the paths shown in the commit blocks — those paths are written workspace-relative for readability. `ai-service` is on branch `development`, `api` on `develop`. Commit locally only; never push.
- The default image model stays `gpt-image-2`. Flipping it to `gpt-image-2.5-sunburst` is an ops step gated on Task 6 landing, never a code default in this plan.
- `app/tools/outpaint_image.py` is shared with KV Expand Image. No change may alter Expand's behaviour when `KV_RESIZE_IMAGE_MODEL` is unset.
- Mask convention is fixed: L-mode, white (255) = paint, black (0) = preserve.
- ai-service has a known-red baseline in `tests/agents/chat_agent` and `tests/agents/kv_generator`. Run targeted paths, never the whole suite, and never judge these tasks by those files.
- api Feature tests need a scratch Postgres and are out of scope here. Every api test in this plan is a Unit test.
- Pricing rates for `gpt-image-2.5-sunburst` are a **blocking human input** (OpenAI's published price list). Do not invent them.

---

### Task 1: Reserve outpaint margin only where the frame actually grows

Today `fit_inside_target` shrinks the source to fit inside a 32px frame on **all four** sides. For 1962×1086 → 1080×1920 the horizontal axis already matches, so a 32px strip on the left and right is handed to the model to repaint for no reason. The letterbox band created by the aspect change is already a perfectly good mask.

**Files:**
- Modify: `ai-service/app/agents/kv_resize/canvas.py:78-104`
- Test: `ai-service/tests/agents/kv_resize/test_canvas.py`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `fit_inside_target(src: Image.Image, target_w: int, target_h: int, frame_px: int = 32) -> tuple[Image.Image, tuple[int, int, int, int]]` — signature unchanged; only the geometry changes. Task 2 relies on it returning a paste box equal to the full canvas when no extension is needed.

- [ ] **Step 1: Write the failing tests**

Append to `ai-service/tests/agents/kv_resize/test_canvas.py`:

```python
from app.agents.kv_resize.canvas import fit_inside_target


def test_fit_inside_target_does_not_inset_the_axis_that_already_fits():
    """1962x1086 -> 1080x1920 grows vertically only. The horizontal axis is
    already correct, so the paste box must span the full width: any inset
    there is a strip of correct pixels handed to the model to repaint."""
    src = make_image(1962, 1086)
    canvas, paste_box = fit_inside_target(src, target_w=1080, target_h=1920)

    x1, y1, x2, y2 = paste_box
    assert canvas.size == (1080, 1920)
    assert (x1, x2) == (0, 1080)
    assert y1 > 0 and y2 < 1920


def test_fit_inside_target_does_not_inset_when_growing_horizontally():
    """1080x1920 -> 1080x566 grows horizontally only (the source must shrink
    to 318x566); the vertical axis fills exactly."""
    src = make_image(1080, 1920)
    canvas, paste_box = fit_inside_target(src, target_w=1080, target_h=566)

    x1, y1, x2, y2 = paste_box
    assert canvas.size == (1080, 566)
    assert (y1, y2) == (0, 566)
    assert x1 > 0 and x2 < 1080


def test_fit_inside_target_reserves_a_frame_when_aspects_match():
    """Equal aspects leave no natural band, so there would be no mask at all.
    Only here does the 32px frame get reserved."""
    src = make_image(2000, 2000)
    canvas, paste_box = fit_inside_target(src, target_w=1080, target_h=1080)

    assert paste_box == (32, 32, 1048, 1048)


def test_fit_inside_target_band_is_at_least_the_frame_width():
    """A near-match aspect must not produce a 1px band — that is a degenerate
    mask. Fall back to the reserved frame instead."""
    src = make_image(1080, 1078)
    canvas, paste_box = fit_inside_target(src, target_w=1080, target_h=1080)

    x1, y1, x2, y2 = paste_box
    assert x1 >= 32 and y1 >= 32
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ai-service && .venv/bin/python -m pytest tests/agents/kv_resize/test_canvas.py -v`
Expected: the four new tests FAIL. The first two fail on the inset (`x1` is 32, not 0), the last two are expected to pass already — confirm which actually fail before writing code, and keep them as regression cover either way.

- [ ] **Step 3: Rewrite `fit_inside_target`**

Replace the body in `ai-service/app/agents/kv_resize/canvas.py`:

```python
def fit_inside_target(
    src: Image.Image,
    target_w: int,
    target_h: int,
    frame_px: int = 32,
) -> tuple[Image.Image, tuple[int, int, int, int]]:
    """Scale src to fit inside the target preserving aspect ratio, then paste
    it centred on a target-sized transparent RGBA canvas.

    The letterbox band left by the aspect change IS the outpaint region, so no
    margin is reserved on an axis that already fills the frame. The previous
    behaviour reserved `frame_px` on all four sides, which handed the model a
    strip to repaint on an axis whose pixels were already correct — that is how
    a resize that should only have grown vertically came back with its left and
    right edges redrawn.

    A frame is reserved only when the natural band would be thinner than
    `frame_px` on both axes (source and target aspects effectively match), since
    an empty or hairline mask is not a usable edit region.

    Returns (canvas, paste_box) where paste_box = (x1, y1, x2, y2).
    """
    sw, sh = src.size

    # round(), not int(): the binding axis must land EXACTLY on the target.
    # Truncation lands on 1919 instead of 1920 often enough to matter (2057
    # hits in a sweep of 4 targets over 300..4000 sources), and a 1px shortfall
    # is a 1px strip of correct pixels handed to the model — the very thing
    # this function exists to stop. min() guards the rounding from overshooting.
    scale = min(target_w / sw, target_h / sh)
    scaled_w = min(target_w, max(1, round(sw * scale)))
    scaled_h = min(target_h, max(1, round(sh * scale)))

    if (target_w - scaled_w) < frame_px and (target_h - scaled_h) < frame_px:
        inner_w = max(1, target_w - 2 * frame_px)
        inner_h = max(1, target_h - 2 * frame_px)
        scale = min(inner_w / sw, inner_h / sh)
        scaled_w = min(inner_w, max(1, round(sw * scale)))
        scaled_h = min(inner_h, max(1, round(sh * scale)))

    scaled = src.resize((scaled_w, scaled_h), Image.LANCZOS)

    canvas = Image.new("RGBA", (target_w, target_h), (0, 0, 0, 0))
    x = (target_w - scaled_w) // 2
    y = (target_h - scaled_h) // 2
    scaled_rgba = scaled.convert("RGBA")
    canvas.paste(scaled_rgba, (x, y), scaled_rgba)
    return canvas, (x, y, x + scaled_w, y + scaled_h)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ai-service && .venv/bin/python -m pytest tests/agents/kv_resize/ -v`
Expected: all PASS. If `test_service.py` fails, it is asserting the old geometry — read the assertion, confirm it was pinning the inset, and update it in this commit.

- [ ] **Step 5: Commit**

```bash
git add ai-service/app/agents/kv_resize/canvas.py ai-service/tests/agents/kv_resize/test_canvas.py
git commit -m "fix(ai): reserve resize outpaint margin only on the axis that grows

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: A resize with nothing to extend must not damage the master

`_INNER_SHRINK_RATIO` shrinks the cropped source to 95% of the target so the mask is never empty. The comment says the quiet part out loud: it exists "so the API call has genuine work to do … instead of being a 'preserve everything' no-op call that would still bill tokens". That degrades the master to justify billing. A no-op resize should skip the model and bill nothing.

**Files:**
- Modify: `ai-service/app/agents/kv_resize/canvas.py` (add `mask_is_empty`)
- Modify: `ai-service/app/agents/kv_resize/service.py:53-58` (delete `_INNER_SHRINK_RATIO`), `:230-247` (skip the call)
- Test: `ai-service/tests/agents/kv_resize/test_canvas.py`, `ai-service/tests/agents/kv_resize/test_service.py`

**Interfaces:**
- Consumes: `fit_inside_target` from Task 1.
- Produces: `mask_is_empty(mask: Image.Image) -> bool` in `canvas.py` — True when no pixel is marked paint.

- [ ] **Step 1: Write the failing tests**

Append to `ai-service/tests/agents/kv_resize/test_canvas.py`:

```python
from app.agents.kv_resize.canvas import mask_is_empty


def test_mask_is_empty_when_paste_box_covers_the_whole_canvas():
    mask = build_mask(target_w=100, target_h=100, paste_box=(0, 0, 100, 100))
    assert mask_is_empty(mask) is True


def test_mask_is_not_empty_when_a_band_remains():
    mask = build_mask(target_w=100, target_h=100, paste_box=(0, 10, 100, 90))
    assert mask_is_empty(mask) is False
```

Append to `ai-service/tests/agents/kv_resize/test_service.py`:

```python
@patch("app.agents.kv_resize.service.requests.get")
@patch("app.agents.kv_resize.service.analyze")
@patch("app.agents.kv_resize.service.reframe")
@patch("app.agents.kv_resize.service.outpaint")
@patch("app.agents.kv_resize.service.save_bytes_to_file")
@patch("app.agents.kv_resize.service.post_completed")
def test_exact_aspect_match_does_not_call_the_model(
    mock_pc, mock_save, mock_outpaint, mock_reframe, mock_analyze, mock_get
):
    """A source already at the target aspect has nothing to outpaint. It must
    be returned untouched rather than shrunk to 95% to manufacture a mask."""
    mock_get.return_value = MagicMock(
        ok=True, content=_png_bytes(2160, 2160), status_code=200
    )
    mock_analyze.return_value = (None, {})
    mock_save.return_value = "https://cdn.example.com/out.png"

    req = ResizeExportRequest(
        export_id="01HXYZ",
        source_image_url="https://src.example.com/in.png",
        target_width=1080,
        target_height=1080,
        use_vision_prepass=False,
    )

    process_resize_export(req)

    mock_outpaint.assert_not_called()
    mock_reframe.assert_not_called()
    assert mock_pc.call_args.kwargs["status"] == "done"
    assert mock_pc.call_args.kwargs["token_usage"] is None
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ai-service && .venv/bin/python -m pytest tests/agents/kv_resize/test_canvas.py tests/agents/kv_resize/test_service.py -v`
Expected: FAIL — `mask_is_empty` does not exist; the service test fails because `outpaint` IS called.

- [ ] **Step 3: Add `mask_is_empty` to `canvas.py`**

```python
def mask_is_empty(mask: Image.Image) -> bool:
    """True when the mask marks nothing to paint.

    `build_mask` starts white (paint) and pastes black (preserve) over the
    source area, so a paste box covering the whole canvas leaves a mask with no
    white pixel at all — there is nothing for the model to do.
    """
    return mask.getextrema()[1] == 0
```

- [ ] **Step 4: Remove the shrink and skip the no-op call in `service.py`**

Delete the `_INNER_SHRINK_RATIO` constant and its comment block, and delete this branch from the `legacy_smart_crop` arm:

```python
                if (
                    pre.size[0] >= req.target_width
                    and pre.size[1] >= req.target_height
                ):
                    inner_w = max(1, int(req.target_width * _INNER_SHRINK_RATIO))
                    inner_h = max(1, int(req.target_height * _INNER_SHRINK_RATIO))
                    pre = pre.resize((inner_w, inner_h), Image.LANCZOS)
```

Add `mask_is_empty` to the `canvas` import, then replace the outpaint call site:

```python
            mask = build_mask(req.target_width, req.target_height, paste_box)

            if mask_is_empty(mask):
                # Nothing to extend: the prepared canvas already is the answer.
                # Returning it untouched is both the honest result and free —
                # the old code shrank the source so the edit call had something
                # to do, which damaged the master purely to keep billing
                # consistent.
                buf = BytesIO()
                canvas.convert("RGB").save(buf, format="PNG")
                image_bytes = buf.getvalue()
            else:
                guidance = OUTPAINT_GUIDANCE
                if vision is not None and vision.context_hint:
                    guidance = f"{OUTPAINT_GUIDANCE}\n\nSource context: {vision.context_hint}"
                guidance = _merge_additional_prompt(guidance, scene_prompt)
                image_bytes, used_model, token_usage = outpaint(canvas, mask, guidance)
                ai_service_run_id = str(uuid4())
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd ai-service && .venv/bin/python -m pytest tests/agents/kv_resize/ -v`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add ai-service/app/agents/kv_resize/canvas.py ai-service/app/agents/kv_resize/service.py ai-service/tests/agents/kv_resize/
git commit -m "fix(ai): stop shrinking the master to manufacture a billable resize

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Separate the product's own copy from campaign copy in the vision pass

The OCR prompt asks for every readable text block and sweeps up copy printed on the packaging (`"RHAMNO POWER"`, `"Cairan Pencuci Piring"`). `build_restructure_prompt` then demands all of it back verbatim, which forces the model to redraw the pack. It also reproduced our own OCR error — the prepass reads `"RHAMINO power"` on that image every time.

**Files:**
- Modify: `ai-service/app/agents/kv_resize/vision_prepass.py:24-46` (model), `:50-76` (system prompt), `:78-115` (schema)
- Test: Create `ai-service/tests/agents/kv_resize/test_vision_prepass.py`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `VisionResult` gains `product_text: list[str]` (defaults `[]`) and `subject_bbox_confidence: float` (defaults `0.0`). `text_content` keeps its meaning minus product-surface copy. Tasks 4 and 5 consume both new fields.

- [ ] **Step 1: Write the failing test**

Create `ai-service/tests/agents/kv_resize/test_vision_prepass.py`:

```python
from app.agents.kv_resize.vision_prepass import (
    VisionResult,
    SubjectBBox,
    _RESPONSE_SCHEMA,
    _SYSTEM_PROMPT,
)


def test_vision_result_carries_product_text_separately():
    r = VisionResult(
        subject_bbox=SubjectBBox(x=0.1, y=0.1, w=0.5, h=0.5),
        content_type="product_shot",
        has_visible_text=True,
        context_hint="green studio backdrop",
        text_content=["Cobain!", "BUSANYA"],
        product_text=["RHAMNO power", "Cairan Pencuci Piring"],
        subject_bbox_confidence=0.9,
    )
    assert r.product_text == ["RHAMNO power", "Cairan Pencuci Piring"]
    assert "RHAMNO power" not in r.text_content


def test_vision_result_defaults_keep_older_payloads_valid():
    r = VisionResult(
        subject_bbox=SubjectBBox(x=0.1, y=0.1, w=0.5, h=0.5),
        content_type="scene",
        has_visible_text=False,
        context_hint="",
    )
    assert r.product_text == []
    assert r.subject_bbox_confidence == 0.0


def test_response_schema_requires_the_new_fields():
    assert "product_text" in _RESPONSE_SCHEMA["properties"]
    assert "subject_bbox_confidence" in _RESPONSE_SCHEMA["properties"]
    assert "product_text" in _RESPONSE_SCHEMA["required"]
    assert "subject_bbox_confidence" in _RESPONSE_SCHEMA["required"]


def test_system_prompt_tells_the_model_to_split_product_copy():
    assert "product_text" in _SYSTEM_PROMPT
    assert "packaging" in _SYSTEM_PROMPT


def test_system_prompt_forbids_a_guessed_subject_box():
    assert "subject_bbox_confidence" in _SYSTEM_PROMPT
    assert "do not guess" in _SYSTEM_PROMPT.lower()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ai-service && .venv/bin/python -m pytest tests/agents/kv_resize/test_vision_prepass.py -v`
Expected: FAIL — `product_text` is not a field on `VisionResult`.

- [ ] **Step 3: Add the fields, schema entries and prompt clauses**

In `VisionResult`, after `text_content`:

```python
    # Copy printed ON the product itself — packaging, label, bottle, box.
    # Held separately and deliberately NOT fed back to the image model: asking
    # it to re-render pack copy forces it to redraw the packaging, which is how
    # the product's proportions and artwork drift. It also reproduced our own
    # OCR error verbatim ("RHAMINO power" for "RHAMNO power").
    product_text: list[str] = Field(default_factory=list)
    # How sure the model is that subject_bbox is a measured box rather than a
    # fallback. Defaulted to 0.0 so older cached results read as "unknown" and
    # the caller falls back instead of trusting a stub.
    subject_bbox_confidence: float = Field(default=0.0, ge=0.0, le=1.0)
```

In `_SYSTEM_PROMPT`, replace the `text_content` sentence and append:

```python
    "text_content is an array of the CAMPAIGN copy — headlines, sub-headlines, "
    "taglines, prices, button/option labels, URLs, and call-to-action copy — "
    "transcribed VERBATIM (exact wording, spelling, capitalization, "
    "punctuation), in natural reading order (top to bottom). Do NOT include "
    "the brand logo graphic. Return an empty array if there is none. "
    "product_text is a SEPARATE array for copy printed on the product itself — "
    "its packaging, label, bottle, box, or wrapper. Every string belongs to "
    "exactly one of the two arrays, never both. "
    "subject_bbox_confidence is how certain you are that subject_bbox is a "
    "measured bounding box: report a low value and do not guess a centred "
    "default box when the subject is unclear."
```

In `_RESPONSE_SCHEMA`, add to `required`: `"product_text"`, `"subject_bbox_confidence"`; and to `properties`:

```python
        "product_text": {
            "type": "array",
            "items": {"type": "string"},
        },
        "subject_bbox_confidence": {
            "type": "number", "minimum": 0, "maximum": 1,
        },
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd ai-service && .venv/bin/python -m pytest tests/agents/kv_resize/ -v`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add ai-service/app/agents/kv_resize/vision_prepass.py ai-service/tests/agents/kv_resize/test_vision_prepass.py
git commit -m "feat(ai): split product-surface copy and bbox confidence out of the resize vision pass

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Tell the model to leave the product, the props and the flat art alone

The only prohibition today is `"Do not add or remove subjects or focal elements"`. Props are not subjects, so bubbles, limes, plate stacks, palm trees and a whole tropical island all got added. On a flat-design KV the newer model turned a solid purple panel into a photographic scene.

**Files:**
- Modify: `ai-service/app/agents/kv_resize/prompts/restructure.py`
- Modify: `ai-service/app/agents/kv_resize/prompts/reframe.py`
- Test: `ai-service/tests/agents/kv_resize/test_restructure_prompt.py`

**Interfaces:**
- Consumes: `VisionResult.product_text` from Task 3 (only to prove it is *not* embedded).
- Produces: `build_restructure_prompt(text_blocks: list[str], context_hint: str = "") -> str` — signature unchanged.

- [ ] **Step 1: Write the failing tests**

Append to `ai-service/tests/agents/kv_resize/test_restructure_prompt.py`:

```python
def test_forbids_inventing_props():
    prompt = build_restructure_prompt(["Cobain!"], context_hint="green studio")
    lowered = prompt.lower()
    assert "do not add" in lowered
    assert "props" in lowered
    assert "scenery" in lowered


def test_forbids_redrawing_the_product_artwork():
    prompt = build_restructure_prompt(["Cobain!"])
    lowered = prompt.lower()
    assert "packaging" in lowered
    assert "do not redraw" in lowered


def test_keeps_flat_graphic_areas_flat():
    prompt = build_restructure_prompt(["Cobain!"])
    lowered = prompt.lower()
    assert "flat" in lowered
    assert "photographic" in lowered


def test_product_copy_is_never_embedded():
    """Only campaign copy is passed in. Pack copy must never reach the prompt —
    demanding it back verbatim is what forces the packaging to be redrawn."""
    prompt = build_restructure_prompt(["Cobain!", "BUSANYA"])
    assert "RHAMNO" not in prompt
    assert "Cairan Pencuci Piring" not in prompt
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ai-service && .venv/bin/python -m pytest tests/agents/kv_resize/test_restructure_prompt.py -v`
Expected: the first three FAIL (the clauses do not exist); the fourth passes already and stays as regression cover.

- [ ] **Step 3: Add the clauses**

In `ai-service/app/agents/kv_resize/prompts/restructure.py`, define a shared constant above `build_restructure_prompt` and append it to the returned string:

```python
# Prohibitions that "do not add or remove subjects or focal elements" does not
# cover. Measured failures this exists to stop: invented stacks of plates and
# flying fruit on a 1:1 resize; an invented tropical island with palm trees and
# grass on a 9:16; a flat purple graphic panel with halftone dots turned into a
# photographic scene.
PRESERVATION_RULES = (
    "Do not add any props, produce, dishware, bubbles, foliage, scenery, or "
    "background objects that are not already present in the source — the scene "
    "may only be extended, never populated. "
    "Do not redraw, restyle, re-letter, or re-proportion the product, its "
    "packaging, label, or any artwork printed on it: reproduce the product "
    "exactly as it appears in the source, at its original proportions. "
    "Keep flat graphic areas flat — solid colour panels, halftone patterns and "
    "vector shapes must stay flat graphics and must not become photographic. "
    "Do not shift the colour palette: match the source's hues and saturation."
)
```

Then in the return, insert `f"{PRESERVATION_RULES} "` immediately before the final "Match the source's lighting direction…" sentence.

Apply the same constant in `reframe.py` by importing it and appending it to `REFRAME_GUIDANCE`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ai-service && .venv/bin/python -m pytest tests/agents/kv_resize/ -v`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add ai-service/app/agents/kv_resize/prompts/ ai-service/tests/agents/kv_resize/test_restructure_prompt.py
git commit -m "feat(ai): forbid invented props, redrawn packaging and photo-realised flat art in resize

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Do not trust a guessed subject box

`subject_bbox` came back as ~`0.2/0.2/0.6/0.6` on every sample tested, so `subject_aware_crop` is a centre crop wearing a costume. With Task 3's confidence field, a low-confidence box should route to the legacy path instead of pretending.

**Files:**
- Modify: `ai-service/app/agents/kv_resize/service.py:120-170`
- Test: `ai-service/tests/agents/kv_resize/test_service.py`

**Interfaces:**
- Consumes: `VisionResult.subject_bbox_confidence` from Task 3.
- Produces: module constant `_MIN_BBOX_CONFIDENCE: float = 0.5` in `service.py`.

- [ ] **Step 1: Write the failing test**

Append to `ai-service/tests/agents/kv_resize/test_service.py`:

```python
from app.agents.kv_resize.service import _decide_strategy, _MIN_BBOX_CONFIDENCE


def _vision_conf(conf: float) -> VisionResult:
    return VisionResult(
        subject_bbox=SubjectBBox(x=0.2, y=0.2, w=0.6, h=0.6),
        content_type="product_shot",
        has_visible_text=False,
        context_hint="studio",
        text_content=[],
        subject_bbox_confidence=conf,
    )


def test_low_confidence_bbox_falls_back_to_legacy_crop():
    """A stub box (the observed 0.2/0.2/0.6/0.6 default) must not be sold as a
    subject-aware crop."""
    strat = _decide_strategy(
        1200, 1000, 1080, 1000, _vision_conf(0.1), restructure_enabled=False
    )
    assert strat == "legacy_smart_crop"


def test_confident_bbox_still_uses_subject_aware_crop():
    strat = _decide_strategy(
        1200, 1000, 1080, 1000, _vision_conf(0.9), restructure_enabled=False
    )
    assert strat == "subject_aware_crop"


def test_min_bbox_confidence_is_a_named_threshold():
    assert 0.0 < _MIN_BBOX_CONFIDENCE < 1.0
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ai-service && .venv/bin/python -m pytest tests/agents/kv_resize/test_service.py -v`
Expected: FAIL — `_MIN_BBOX_CONFIDENCE` does not exist. Note the aspect inputs above are chosen to land on the `subject_aware_crop` branch (same orientation, delta under `_ASPECT_DELTA_THRESHOLD`); if the branch does not match, print the returned strategy and adjust the dimensions rather than the assertion.

- [ ] **Step 3: Add the threshold and the guard**

Next to `_ASPECT_DELTA_THRESHOLD` in `service.py`:

```python
# Below this, subject_bbox is treated as absent. The vision pass returns a
# centred ~0.2/0.2/0.6/0.6 box when it has not really located anything, and a
# crop built on that is a centre crop claiming to be subject-aware.
_MIN_BBOX_CONFIDENCE = 0.5
```

At the end of `_decide_strategy`, replace `return "subject_aware_crop"` with:

```python
    if vision.subject_bbox_confidence < _MIN_BBOX_CONFIDENCE:
        return "legacy_smart_crop"
    return "subject_aware_crop"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd ai-service && .venv/bin/python -m pytest tests/agents/kv_resize/ -v`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add ai-service/app/agents/kv_resize/service.py ai-service/tests/agents/kv_resize/test_service.py
git commit -m "fix(ai): fall back to legacy crop when the resize subject box is a guess

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Register `gpt-image-2.5-sunburst` pricing before anything can select it

`getModelPricing()` returns null for an unknown model and `calculateImageCostAgno` then returns `0.0`. Switching the resize model without a registry entry bills every resize at zero credits. `tests/Unit/Helpers/KvResizeFallbackPricingTest.php` already asserts `costs > 0.0` for every model the pipeline can report — adding the new model to its list is the whole test.

**BLOCKING INPUT:** the four rate values must be copied from OpenAI's published price list by a human. Do not proceed with invented numbers; if they are not available, stop and report.

**Files:**
- Modify: `api/tests/Unit/Helpers/KvResizeFallbackPricingTest.php:12-18`
- Modify: `api/app/Helpers/LLMHelper.php:1194-1214` (add an entry after `gpt-image-2`)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: registry key `gpt-image-2.5-sunburst` resolving to a pricing array with `input_text`, `input_image`, `output_image`, `output_text`. Task 7 reports this exact string as the model name.

- [ ] **Step 1: Add the model to the existing guard's list**

In `api/tests/Unit/Helpers/KvResizeFallbackPricingTest.php`:

```php
$kvResizeModels = [
    'gpt-image-2',
    'gpt-image-2.5-sunburst',
    'gpt-4o-mini',
    'gemini-3-pro-image-preview',
    'gemini-3.5-flash',
];
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd api && ./vendor/bin/pest tests/Unit/Helpers/KvResizeFallbackPricingTest.php`
Expected: FAIL for the `gpt-image-2.5-sunburst` case — `getModelPricing` returns null, so `expect($pricing)->toBeArray()` fails.

- [ ] **Step 3: Add the registry entry**

In `api/app/Helpers/LLMHelper.php`, immediately after the `'gpt-image-2' => [...]` block. Replace each `0.000` with the published rate — these placeholders must not be committed:

```php
        'gpt-image-2.5-sunburst' => [
            'name' => 'GPT Image 2.5 Sunburst',
            'value' => 'gpt-image-2.5-sunburst',
            'model_type' => 'gpt-image-2.5-sunburst',
            'type' => 'image',
            'description' => 'OpenAI image model used by KV Resize; holds the source palette and product proportions far better than gpt-image-2',
            'model_provider' => 'openai',
            'features' => [
                'is_image_generation' => true,
                'is_image_editing' => true,
                'is_web_search' => false,
                'is_file_summarization' => false,
            ],
            'is_active' => true,
            'pricing' => [
                'input_text' => 0.000,
                'input_image' => 0.000,
                'output_image' => 0.000,
                'output_text' => 0.0,
            ],
        ],
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd api && ./vendor/bin/pest tests/Unit/Helpers/KvResizeFallbackPricingTest.php`
Expected: PASS for all five models. A zero rate makes `costs > 0.0` fail, so the test itself refuses placeholder pricing.

- [ ] **Step 5: Commit**

```bash
git add api/app/Helpers/LLMHelper.php api/tests/Unit/Helpers/KvResizeFallbackPricingTest.php
git commit -m "feat(api): register gpt-image-2.5-sunburst pricing so KV resize cannot bill zero

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Make the resize image model configuration, and report the model actually used

`outpaint_image.py` hardcodes `"gpt-image-2"` in five places, including the usage dict the api meters from. It is shared with KV Expand Image, so the resize model must be a parameter with the current value as its default.

**Files:**
- Modify: `ai-service/app/utils/config.py` (add `KV_RESIZE_IMAGE_MODEL`)
- Modify: `ai-service/app/tools/outpaint_image.py:104-120` (`_image_token_usage`), `:122-182` (`outpaint_with_openai_mask`), `:184-215` (`reframe_with_openai`), `:218-246` (`outpaint`, `reframe`)
- Test: Create `ai-service/tests/tools/test_outpaint_image_model.py`

**Interfaces:**
- Consumes: the registry key from Task 6.
- Produces: `outpaint(canvas, mask, prompt, model: str | None = None)` and `reframe(source, target_w, target_h, prompt, model: str | None = None)`, both returning `(bytes, str, dict)` where the `str` is the model actually used. `_image_token_usage(result: dict, model: str) -> Dict[str, Any]`.

- [ ] **Step 1: Write the failing test**

Create `ai-service/tests/tools/test_outpaint_image_model.py`:

```python
from unittest.mock import patch

from PIL import Image

from app.tools.outpaint_image import outpaint, reframe, _image_token_usage


def _ok_result():
    return {"data": [{"b64_json": ""}], "usage": {
        "input_tokens_details": {"text_tokens": 3, "image_tokens": 5},
        "output_tokens": 7,
    }}


def test_token_usage_reports_the_model_it_was_given():
    usage = _image_token_usage(_ok_result(), "gpt-image-2.5-sunburst")
    assert usage["model"] == "gpt-image-2.5-sunburst"


@patch("app.tools.outpaint_image._call_openai_edits")
def test_reframe_defaults_to_the_configured_model(mock_call):
    mock_call.return_value = _ok_result()
    src = Image.new("RGB", (64, 64), (0, 0, 0))

    _, used_model, usage = reframe(src, 1024, 1024, "prompt")

    sent = dict((f[0], f[1][1]) for f in mock_call.call_args.args[0])
    assert sent["model"] == used_model
    assert usage["model"] == used_model


@patch("app.tools.outpaint_image._call_openai_edits")
def test_reframe_honours_an_explicit_model(mock_call):
    mock_call.return_value = _ok_result()
    src = Image.new("RGB", (64, 64), (0, 0, 0))

    _, used_model, usage = reframe(src, 1024, 1024, "prompt", model="gpt-image-2.5-sunburst")

    sent = dict((f[0], f[1][1]) for f in mock_call.call_args.args[0])
    assert sent["model"] == "gpt-image-2.5-sunburst"
    assert used_model == "gpt-image-2.5-sunburst"
    assert usage["model"] == "gpt-image-2.5-sunburst"


@patch("app.tools.outpaint_image._call_openai_edits")
def test_outpaint_honours_an_explicit_model(mock_call):
    mock_call.return_value = _ok_result()
    canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    mask = Image.new("L", (1024, 1024), 255)

    _, used_model, usage = outpaint(canvas, mask, "prompt", model="gpt-image-2.5-sunburst")

    assert used_model == "gpt-image-2.5-sunburst"
    assert usage["model"] == "gpt-image-2.5-sunburst"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ai-service && .venv/bin/python -m pytest tests/tools/test_outpaint_image_model.py -v`
Expected: FAIL — `_image_token_usage` takes one argument, and `outpaint`/`reframe` take no `model`.

- [ ] **Step 3: Add the setting**

In `ai-service/app/utils/config.py`, next to the other KV settings:

```python
    # Image model for the KV Resize edit calls (outpaint + reframe). Held here
    # rather than as a literal in app/tools/outpaint_image.py because that
    # module is shared with KV Expand Image, which must not follow resize's
    # choice. Any value set here MUST also exist in the api's LLMHelper
    # registry: getModelPricing() returns null for an unknown model and the
    # resize then bills zero credits.
    KV_RESIZE_IMAGE_MODEL: str = "gpt-image-2"
```

- [ ] **Step 4: Thread the model through `outpaint_image.py`**

- `_image_token_usage(result: dict, model: str)` — replace the hardcoded `"model": "gpt-image-2"` with `"model": model`.
- `outpaint_with_openai_mask(canvas, mask, prompt, model: str)` and `reframe_with_openai(source, target_w, target_h, prompt, model: str)` — take the model, use it in the `("model", (None, model))` tuple, and pass it to `_image_token_usage`.
- Public wrappers resolve the default:

```python
def outpaint(
    canvas: Image.Image,
    mask: Image.Image,
    prompt: str,
    model: Optional[str] = None,
) -> tuple[bytes, str, Dict[str, Any]]:
    resolved = model or settings.KV_RESIZE_IMAGE_MODEL
    image_bytes, token_usage = outpaint_with_openai_mask(canvas, mask, prompt, resolved)
    return image_bytes, resolved, token_usage


def reframe(
    source: Image.Image,
    target_w: int,
    target_h: int,
    prompt: str,
    model: Optional[str] = None,
) -> tuple[bytes, str, Dict[str, Any]]:
    resolved = model or settings.KV_RESIZE_IMAGE_MODEL
    image_bytes, token_usage = reframe_with_openai(source, target_w, target_h, prompt, resolved)
    return image_bytes, resolved, token_usage
```

Add `Optional` to the `typing` import.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd ai-service && .venv/bin/python -m pytest tests/tools/test_outpaint_image_model.py tests/agents/kv_resize/ tests/agents/kv_image_expand/ -v`
Expected: all PASS. KV Expand must be green without modification — that is the proof the shared module still behaves for its other caller.

- [ ] **Step 6: Commit**

```bash
git add ai-service/app/utils/config.py ai-service/app/tools/outpaint_image.py ai-service/tests/tools/test_outpaint_image_model.py
git commit -m "feat(ai): make the KV resize image model configurable and report the model actually used

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Rollout

The code default stays `gpt-image-2`. After Task 6 is deployed to the target environment, set `KV_RESIZE_IMAGE_MODEL=gpt-image-2.5-sunburst` there and re-run a known export. Verify in the DB that the new `kv_resize_exports.model` is `gpt-image-2.5-sunburst` **and** that a non-zero cost row was written — a zero means the registry entry did not deploy, and the switch must be reverted immediately.

## Verification against the original complaint

Re-run the bake-off probe on studio file `01m2j7a3zdnvdj1w3e4qnxa5vp` (1962×1086 → 1080×1080 and 1080×1920) and confirm:

1. **No new elements** — the mask path no longer repaints the left/right strips (Task 1). On the restructure path this remains a prompt-strength improvement only (Task 4), not a guarantee; the composite path in the spec's §4 is what would make it one.
2. **Colours** — measured dSat/dVal against the master should stay within the sunburst figures in the spec's §2.1.
3. **Product proportions** — pack copy must no longer appear in the restructure prompt (Task 3), and the packaging clause must be present (Task 4).
