# KV Resize Additional Prompt — AI Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional free-text `additional_prompt` to `ResizeExportRequest` that, when present, is merged into the outpaint/reframe/restructure guidance passed to gpt-image-2 so users can steer KV resize/regenerate; when absent, behavior is byte-identical to today.

**Architecture:** A nullable `additional_prompt` field is added to the request schema with a normalizer that treats empty/whitespace-only as `None`. In `service.py`, after each base guidance string is built (and after the existing vision `context_hint` append), a single helper appends `\n\nUser instructions: {additional_prompt}` before the guidance reaches `reframe()` / `outpaint()`. The deterministic `stamp_logo` step is untouched.

**Tech Stack:** FastAPI, Python, pytest, OpenAI gpt-image-2

---

## Conventions

- **Working directory:** `/Users/alva.e202511001/Desktop/work/frndos-agentic/ai-service`
- **Run tests:** `.venv/bin/python -m pytest <path> -q` (from the `ai-service` directory).
- **Test style (verified from `tests/agents/kv_resize/test_service.py`):** plain `pytest` functions, OpenAI/network is never hit — `reframe`, `outpaint`, `analyze`, `requests.get`, `save_bytes_to_file`, and `post_completed` are patched at `app.agents.kv_resize.service.*`. The merged guidance string reaching the model is asserted via `mock_reframe.call_args.args[3]` / `mock_outpaint.call_args.args[2]` (4th / 3rd positional arg respectively).
- **No `pyproject.toml`** in this service — there is no separate lint/format gate; the only gate is pytest.

---

## Task 1: Add `additional_prompt` field + normalizer to `ResizeExportRequest`

**Files:**
- Modify: `app/agents/kv_resize/request_schema.py` (add field after L28; add module-level helper)
- Test: `tests/agents/kv_resize/test_request_schema.py` (Create)

Steps:

- [ ] 1. Write the failing test. Create `tests/agents/kv_resize/test_request_schema.py`:

    ```python
    from app.agents.kv_resize.request_schema import (
        ResizeExportRequest,
        normalize_additional_prompt,
    )


    def _req(**overrides):
        base = dict(
            export_id="01HXYZ",
            source_image_url="https://src.example.com/in.png",
            target_width=1080,
            target_height=1920,
        )
        base.update(overrides)
        return ResizeExportRequest(**base)


    def test_additional_prompt_defaults_to_none():
        assert _req().additional_prompt is None


    def test_additional_prompt_preserved_when_present():
        req = _req(additional_prompt="keep the text at the very bottom")
        assert req.additional_prompt == "keep the text at the very bottom"


    def test_normalize_blank_to_none():
        assert normalize_additional_prompt(None) is None
        assert normalize_additional_prompt("") is None
        assert normalize_additional_prompt("   ") is None
        assert normalize_additional_prompt("\n\t ") is None


    def test_normalize_trims_and_keeps_text():
        assert normalize_additional_prompt("  make it calmer  ") == "make it calmer"
    ```

- [ ] 2. Run it — expect FAIL (ImportError: `normalize_additional_prompt` does not exist):

    ```bash
    .venv/bin/python -m pytest tests/agents/kv_resize/test_request_schema.py -q
    ```

- [ ] 3. Minimal implementation. In `app/agents/kv_resize/request_schema.py`, add the helper above the class and the field inside `ResizeExportRequest` (after the `brand_logo_stamp` line, L28):

    Add after the imports / before `class CropWindow`:

    ```python
    def normalize_additional_prompt(value: Optional[str]) -> Optional[str]:
        """Treat empty/whitespace-only free-text as absent (legacy behavior)."""
        if value is None:
            return None
        stripped = value.strip()
        return stripped or None
    ```

    Add the field to `ResizeExportRequest` (after `brand_logo_stamp`):

    ```python
        brand_logo_stamp: Optional[BrandLogoStamp] = None
        # Optional free-text instructions to steer the resize/regenerate scene
        # (e.g. "keep the text at the bottom"). None => byte-identical legacy
        # behavior. Empty/whitespace is normalized to None in service.py before
        # it is merged into the model guidance. Scene/outpaint-only this
        # iteration — does NOT move the brand logo (stamp_logo is deterministic).
        additional_prompt: Optional[str] = None
    ```

- [ ] 4. Run it — expect PASS:

    ```bash
    .venv/bin/python -m pytest tests/agents/kv_resize/test_request_schema.py -q
    ```

- [ ] 5. Commit:

    ```bash
    git add app/agents/kv_resize/request_schema.py tests/agents/kv_resize/test_request_schema.py
    git commit -m "feat(ai): add optional additional_prompt to ResizeExportRequest"
    ```

---

## Task 2: Add guidance-merge helper in `service.py`

**Files:**
- Modify: `app/agents/kv_resize/service.py` (add import of `normalize_additional_prompt`; add `_merge_additional_prompt` helper near the module-level constants ~L51-52)
- Test: `tests/agents/kv_resize/test_merge_prompt.py` (Create)

Steps:

- [ ] 1. Write the failing test. Create `tests/agents/kv_resize/test_merge_prompt.py`:

    ```python
    from app.agents.kv_resize.service import _merge_additional_prompt


    def test_none_returns_base_unchanged():
        base = "Naturally extend the scene."
        assert _merge_additional_prompt(base, None) == base


    def test_blank_returns_base_unchanged():
        base = "Naturally extend the scene."
        assert _merge_additional_prompt(base, "   ") == base


    def test_appends_user_instructions_block():
        base = "Naturally extend the scene."
        merged = _merge_additional_prompt(base, "make the background calmer")
        assert merged == (
            "Naturally extend the scene."
            "\n\nUser instructions: make the background calmer"
        )


    def test_trims_user_text():
        merged = _merge_additional_prompt("BASE", "  keep text low  ")
        assert merged == "BASE\n\nUser instructions: keep text low"
    ```

- [ ] 2. Run it — expect FAIL (ImportError: `_merge_additional_prompt`):

    ```bash
    .venv/bin/python -m pytest tests/agents/kv_resize/test_merge_prompt.py -q
    ```

- [ ] 3. Minimal implementation. In `app/agents/kv_resize/service.py`:

    Extend the request_schema import (L41):

    ```python
    from app.agents.kv_resize.request_schema import (
        ResizeExportRequest,
        normalize_additional_prompt,
    )
    ```

    Add the helper after the `_ASPECT_DELTA_THRESHOLD` constant (after L52, before `_decide_strategy`):

    ```python
    def _merge_additional_prompt(base: str, additional_prompt: Optional[str]) -> str:
        """Append user free-text steering to the base guidance.

        Returns the base unchanged when there is no usable text, so the
        no-prompt path is byte-identical to legacy behavior. The user clause is
        appended LAST (after any vision context_hint already baked into base).
        """
        normalized = normalize_additional_prompt(additional_prompt)
        if not normalized:
            return base
        return f"{base}\n\nUser instructions: {normalized}"
    ```

- [ ] 4. Run it — expect PASS:

    ```bash
    .venv/bin/python -m pytest tests/agents/kv_resize/test_merge_prompt.py -q
    ```

- [ ] 5. Commit:

    ```bash
    git add app/agents/kv_resize/service.py tests/agents/kv_resize/test_merge_prompt.py
    git commit -m "feat(ai): add _merge_additional_prompt guidance helper"
    ```

---

## Task 3: Merge `additional_prompt` into the reframe path

**Files:**
- Modify: `app/agents/kv_resize/service.py` (the `ai_reframe` / `ai_restructure` branch, ~L124-141)
- Test: `tests/agents/kv_resize/test_service.py` (add test)

Steps:

- [ ] 1. Write the failing test. Append to `tests/agents/kv_resize/test_service.py`:

    ```python
    @patch("app.agents.kv_resize.service.requests.get")
    @patch("app.agents.kv_resize.service.analyze")
    @patch("app.agents.kv_resize.service.reframe")
    @patch("app.agents.kv_resize.service.outpaint")
    @patch("app.agents.kv_resize.service.save_bytes_to_file")
    @patch("app.agents.kv_resize.service.post_completed")
    def test_additional_prompt_merged_into_reframe_guidance(
        mock_pc, mock_save, mock_outpaint, mock_reframe, mock_analyze, mock_get
    ):
        """Text-free reframe path appends the user instructions AFTER the vision
        context hint."""
        mock_get.return_value = MagicMock(
            ok=True, content=_png_bytes(1672, 941), status_code=200
        )
        mock_analyze.return_value = (_vision(has_text=False), {})
        mock_reframe.return_value = (b"REFRAMED", "gpt-image-2", {})
        mock_save.return_value = "https://cdn.example.com/reframed.png"

        req = ResizeExportRequest(
            export_id="01HXYZ",
            source_image_url="https://src.example.com/in.png",
            target_width=1080,
            target_height=1920,
            additional_prompt="make the background calmer",
        )

        process_resize_export(req)

        guidance = mock_reframe.call_args.args[3]
        # vision context hint still present, user clause appended last.
        assert "Source context: airport terminal, warm backlight" in guidance
        assert guidance.endswith("\n\nUser instructions: make the background calmer")
    ```

- [ ] 2. Run it — expect FAIL (the user clause is absent; `endswith` fails):

    ```bash
    .venv/bin/python -m pytest tests/agents/kv_resize/test_service.py::test_additional_prompt_merged_into_reframe_guidance -q
    ```

- [ ] 3. Minimal implementation. In `service.py`, in the `if strategy in ("ai_reframe", "ai_restructure"):` block, wrap the guidance just before the `reframe(...)` call. Change L138-140 from:

    ```python
            image_bytes, used_model, token_usage = reframe(
                source, req.target_width, req.target_height, guidance
            )
    ```

    to:

    ```python
            guidance = _merge_additional_prompt(guidance, req.additional_prompt)
            image_bytes, used_model, token_usage = reframe(
                source, req.target_width, req.target_height, guidance
            )
    ```

    (This covers BOTH `ai_reframe` and `ai_restructure` since both assign `guidance` above this line — Task 4 verifies restructure explicitly.)

- [ ] 4. Run it — expect PASS:

    ```bash
    .venv/bin/python -m pytest tests/agents/kv_resize/test_service.py::test_additional_prompt_merged_into_reframe_guidance -q
    ```

- [ ] 5. Commit:

    ```bash
    git add app/agents/kv_resize/service.py tests/agents/kv_resize/test_service.py
    git commit -m "feat(ai): merge additional_prompt into reframe guidance"
    ```

---

## Task 4: Verify `additional_prompt` merge on the restructure path

**Files:**
- Modify: none (covered by the Task 3 edit — both reframe and restructure share the `guidance` variable)
- Test: `tests/agents/kv_resize/test_service.py` (add test)

Steps:

- [ ] 1. Write the failing-then-passing test. Append to `tests/agents/kv_resize/test_service.py`:

    ```python
    @patch("app.agents.kv_resize.service.requests.get")
    @patch("app.agents.kv_resize.service.analyze")
    @patch("app.agents.kv_resize.service.reframe")
    @patch("app.agents.kv_resize.service.outpaint")
    @patch("app.agents.kv_resize.service.save_bytes_to_file")
    @patch("app.agents.kv_resize.service.post_completed")
    def test_additional_prompt_merged_into_restructure_guidance(
        mock_pc, mock_save, mock_outpaint, mock_reframe, mock_analyze, mock_get
    ):
        """restructure path keeps the OCR copy AND appends user instructions."""
        mock_get.return_value = MagicMock(
            ok=True, content=_png_bytes(1672, 941), status_code=200
        )
        mock_analyze.return_value = (_vision(has_text=True), {})
        mock_reframe.return_value = (b"RESTRUCTURED", "gpt-image-2", {})
        mock_save.return_value = "https://cdn.example.com/restructured.png"

        req = ResizeExportRequest(
            export_id="01HXYZ",
            source_image_url="https://src.example.com/in.png",
            target_width=1080,
            target_height=1920,
            restructure_enabled=True,
            additional_prompt="keep the headline at the very bottom",
        )

        process_resize_export(req)

        guidance = mock_reframe.call_args.args[3]
        assert "Introducing Garuda Your Way" in guidance  # OCR copy preserved
        assert guidance.endswith(
            "\n\nUser instructions: keep the headline at the very bottom"
        )
    ```

- [ ] 2. Run it — expect PASS immediately (Task 3 already wraps the shared `guidance`). This test pins the contract so a future refactor can't drop restructure coverage:

    ```bash
    .venv/bin/python -m pytest tests/agents/kv_resize/test_service.py::test_additional_prompt_merged_into_restructure_guidance -q
    ```

    > If this FAILS, the Task 3 edit was placed wrong (e.g. only inside the `else` reframe branch). The merge line must sit after the `if/else` that assigns `guidance`, immediately before `reframe(...)`.

- [ ] 3. No implementation change needed.

- [ ] 4. (Re)run to confirm PASS — same command as step 2.

- [ ] 5. Commit:

    ```bash
    git add tests/agents/kv_resize/test_service.py
    git commit -m "feat(ai): cover additional_prompt merge on restructure path"
    ```

---

## Task 5: Merge `additional_prompt` into the outpaint path

**Files:**
- Modify: `app/agents/kv_resize/service.py` (the outpaint branch, ~L182-186)
- Test: `tests/agents/kv_resize/test_service.py` (add test)

Steps:

- [ ] 1. Write the failing test. Append to `tests/agents/kv_resize/test_service.py`:

    ```python
    @patch("app.agents.kv_resize.service.requests.get")
    @patch("app.agents.kv_resize.service.outpaint")
    @patch("app.agents.kv_resize.service.save_bytes_to_file")
    @patch("app.agents.kv_resize.service.post_completed")
    def test_additional_prompt_merged_into_outpaint_guidance(
        mock_pc, mock_save, mock_outpaint, mock_get
    ):
        """Outpaint path (vision off -> legacy_smart_crop) appends user text."""
        mock_get.return_value = MagicMock(
            ok=True, content=_png_bytes(800, 600), status_code=200
        )
        mock_outpaint.return_value = (b"OUTPAINTED", "gpt-image-2", {})
        mock_save.return_value = "https://cdn.example.com/out.png"

        req = ResizeExportRequest(
            export_id="01HXYZ",
            source_image_url="https://src.example.com/in.png",
            target_width=1080,
            target_height=1920,
            use_vision_prepass=False,
            additional_prompt="warmer lighting please",
        )

        process_resize_export(req)

        # outpaint(canvas, mask, prompt) -> prompt is the 3rd positional arg.
        guidance = mock_outpaint.call_args.args[2]
        assert guidance.endswith("\n\nUser instructions: warmer lighting please")
    ```

- [ ] 2. Run it — expect FAIL (no user clause in outpaint guidance):

    ```bash
    .venv/bin/python -m pytest tests/agents/kv_resize/test_service.py::test_additional_prompt_merged_into_outpaint_guidance -q
    ```

- [ ] 3. Minimal implementation. In `service.py`, in the `else` (outpaint) branch, change L182-186 from:

    ```python
            mask = build_mask(req.target_width, req.target_height, paste_box)
            guidance = OUTPAINT_GUIDANCE
            if vision is not None and vision.context_hint:
                guidance = f"{OUTPAINT_GUIDANCE}\n\nSource context: {vision.context_hint}"
            image_bytes, used_model, token_usage = outpaint(canvas, mask, guidance)
    ```

    to:

    ```python
            mask = build_mask(req.target_width, req.target_height, paste_box)
            guidance = OUTPAINT_GUIDANCE
            if vision is not None and vision.context_hint:
                guidance = f"{OUTPAINT_GUIDANCE}\n\nSource context: {vision.context_hint}"
            guidance = _merge_additional_prompt(guidance, req.additional_prompt)
            image_bytes, used_model, token_usage = outpaint(canvas, mask, guidance)
    ```

- [ ] 4. Run it — expect PASS:

    ```bash
    .venv/bin/python -m pytest tests/agents/kv_resize/test_service.py::test_additional_prompt_merged_into_outpaint_guidance -q
    ```

- [ ] 5. Commit:

    ```bash
    git add app/agents/kv_resize/service.py tests/agents/kv_resize/test_service.py
    git commit -m "feat(ai): merge additional_prompt into outpaint guidance"
    ```

---

## Task 6: Regression — `additional_prompt=None` reproduces legacy guidance exactly

**Files:**
- Modify: none
- Test: `tests/agents/kv_resize/test_service.py` (add tests)

Steps:

- [ ] 1. Write the regression tests. Append to `tests/agents/kv_resize/test_service.py`:

    ```python
    from app.agents.kv_resize.prompts.outpaint import OUTPAINT_GUIDANCE
    from app.agents.kv_resize.prompts.reframe import REFRAME_GUIDANCE


    @patch("app.agents.kv_resize.service.requests.get")
    @patch("app.agents.kv_resize.service.outpaint")
    @patch("app.agents.kv_resize.service.save_bytes_to_file")
    @patch("app.agents.kv_resize.service.post_completed")
    def test_no_additional_prompt_outpaint_guidance_is_legacy(
        mock_pc, mock_save, mock_outpaint, mock_get
    ):
        """vision off + no prompt -> outpaint guidance is byte-identical to the
        legacy constant (no trailing User instructions block)."""
        mock_get.return_value = MagicMock(
            ok=True, content=_png_bytes(800, 600), status_code=200
        )
        mock_outpaint.return_value = (b"OUTPAINTED", "gpt-image-2", {})
        mock_save.return_value = "https://cdn.example.com/out.png"

        req = ResizeExportRequest(
            export_id="01HXYZ",
            source_image_url="https://src.example.com/in.png",
            target_width=1080,
            target_height=1920,
            use_vision_prepass=False,
        )

        process_resize_export(req)

        assert mock_outpaint.call_args.args[2] == OUTPAINT_GUIDANCE


    @patch("app.agents.kv_resize.service.requests.get")
    @patch("app.agents.kv_resize.service.analyze")
    @patch("app.agents.kv_resize.service.reframe")
    @patch("app.agents.kv_resize.service.outpaint")
    @patch("app.agents.kv_resize.service.save_bytes_to_file")
    @patch("app.agents.kv_resize.service.post_completed")
    def test_blank_additional_prompt_reframe_guidance_is_legacy(
        mock_pc, mock_save, mock_outpaint, mock_reframe, mock_analyze, mock_get
    ):
        """Whitespace-only prompt is normalized to None -> reframe guidance is
        the legacy REFRAME_GUIDANCE (+ context hint) with no user clause."""
        mock_get.return_value = MagicMock(
            ok=True, content=_png_bytes(1672, 941), status_code=200
        )
        mock_analyze.return_value = (_vision(has_text=False), {})
        mock_reframe.return_value = (b"REFRAMED", "gpt-image-2", {})
        mock_save.return_value = "https://cdn.example.com/reframed.png"

        req = ResizeExportRequest(
            export_id="01HXYZ",
            source_image_url="https://src.example.com/in.png",
            target_width=1080,
            target_height=1920,
            additional_prompt="   ",
        )

        process_resize_export(req)

        guidance = mock_reframe.call_args.args[3]
        assert guidance == (
            f"{REFRAME_GUIDANCE}\n\nSource context: airport terminal, warm backlight"
        )
        assert "User instructions" not in guidance
    ```

- [ ] 2. Run it — expect PASS (the helper short-circuits on `None`/blank):

    ```bash
    .venv/bin/python -m pytest tests/agents/kv_resize/test_service.py -q -k legacy
    ```

- [ ] 3. No implementation change needed.

- [ ] 4. Run the full kv_resize suite — expect PASS (confirms no legacy test regressed, incl. `test_restructure_flag_routes_text_ad_to_reframe` which asserts OCR copy is still present):

    ```bash
    .venv/bin/python -m pytest tests/agents/kv_resize -q
    ```

- [ ] 5. Commit:

    ```bash
    git add tests/agents/kv_resize/test_service.py
    git commit -m "feat(ai): regression — null additional_prompt keeps legacy guidance"
    ```

---

## Done criteria

- `ResizeExportRequest.additional_prompt: Optional[str] = None` exists; empty/whitespace normalizes to `None`.
- On all three model paths (reframe, restructure, outpaint), a non-empty `additional_prompt` appends `\n\nUser instructions: {text}` AFTER any vision `Source context:` hint, immediately before the model call.
- `additional_prompt=None` (or blank) yields guidance byte-identical to today.
- `stamp_logo` is untouched (no edits to the logo re-bake block, L189-202).
- `.venv/bin/python -m pytest tests/agents/kv_resize -q` is green.
