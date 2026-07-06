# Video Dynamic Pricing — ai-service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `generate_video` report the billing dimensions the API needs to price video accurately, and fix the Kling `output_video_tokens = 1` bug that blocks per-second pricing.

**Architecture:** Add one pure helper `build_video_token_usage()` that assembles the `token_usage` dict including the new dimension keys (`resolution`, `video_in`, `mode`, `audio`). Refactor the Seedance and Kling branches of `generate_video` to use it. Only Replicate-routed Seedance/Kling change; Veo/Sora/Hunyuan branches are untouched. The API side (separate plan) consumes these keys.

**Tech Stack:** Python 3.11, pytest, Replicate SDK (mocked in tests).

## Global Constraints

- Run all commands from `ai-service/` with the venv active: `source .venv/bin/activate`.
- Tests live under `ai-service/tests/`; run with `pytest`.
- **Never call real providers in tests** — patch `app.tools.generate_video.replicate_run`, `app.tools.generate_video.upload_file_to_s3`, and `builtins.open`.
- Only the Seedance (`bytedance`) and Kling (`kuaishou`) branches change. Do **not** touch the `google` (Veo), `openai` (Sora), or `tencent` (Hunyuan) branches.
- Design spec: `docs/superpowers/specs/2026-07-06-video-dynamic-pricing-design.md`.
- Branch: `feature/daffa/vc-video-dynamic-pricing` (already checked out in `ai-service/`).

---

### Task 1: `build_video_token_usage` helper

**Files:**
- Modify: `app/tools/generate_video.py` (add helper above `def generate_video(` at line 39)
- Test: `tests/tools/test_video_token_usage.py` (create)

**Interfaces:**
- Produces: `build_video_token_usage(model: str, output_video_tokens: int, *, resolution: str | None = None, video_in: bool = False, mode: str | None = None, audio: bool = False) -> dict` — always returns the four dimension keys (defaulting to `None`/`False`) plus the existing base fields.

- [ ] **Step 1: Write the failing test**

Create `tests/tools/test_video_token_usage.py`:

```python
from app.tools.generate_video import build_video_token_usage


def test_base_fields_present():
    tu = build_video_token_usage("seedance-2.0", 8)
    assert tu["type"] == "Video Generation"
    assert tu["model"] == "seedance-2.0"
    assert tu["output_video_tokens"] == 8
    assert tu["input_text_tokens"] == 0
    assert tu["input_image_tokens"] == 0


def test_dimension_defaults():
    tu = build_video_token_usage("veo-3.1-fast-generate-preview", 8)
    assert tu["resolution"] is None
    assert tu["video_in"] is False
    assert tu["mode"] is None
    assert tu["audio"] is False


def test_seedance_dimensions():
    tu = build_video_token_usage("seedance-2.0", 8, resolution="1080p", video_in=True)
    assert tu["resolution"] == "1080p"
    assert tu["video_in"] is True


def test_kling_dimensions():
    tu = build_video_token_usage("kling-v3-video", 8, mode="pro", audio=True)
    assert tu["mode"] == "pro"
    assert tu["audio"] is True
    assert tu["output_video_tokens"] == 8  # duration, not the old fixed 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/tools/test_video_token_usage.py -v`
Expected: FAIL with `ImportError: cannot import name 'build_video_token_usage'`

- [ ] **Step 3: Add the helper**

In `app/tools/generate_video.py`, immediately before `def generate_video(` (line 39), insert:

```python
def build_video_token_usage(
    model: str,
    output_video_tokens: int,
    *,
    resolution: str | None = None,
    video_in: bool = False,
    mode: str | None = None,
    audio: bool = False,
) -> dict:
    """Assemble the video token_usage dict the API meters credits from.

    The four dimension keys (resolution, video_in, mode, audio) let the API
    resolve per-model tiered pricing. Flat/fixed models simply pass none of
    them and the API ignores the null/false defaults.
    """
    return {
        "type": "Video Generation",
        "model": model,
        "input_text_tokens": 0,
        "input_image_tokens": 0,
        "output_video_tokens": output_video_tokens,
        "resolution": resolution,
        "video_in": bool(video_in),
        "mode": mode,
        "audio": bool(audio),
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/tools/test_video_token_usage.py -v`
Expected: PASS (4 passed)

- [ ] **Step 5: Commit**

```bash
git add app/tools/generate_video.py tests/tools/test_video_token_usage.py
git commit -m "feat(ai): add build_video_token_usage helper with billing dimensions"
```

---

### Task 2: Seedance branch reports `resolution` + `video_in`

**Files:**
- Modify: `app/tools/generate_video.py` (Seedance `token_usage`, currently lines 583-589)
- Test: `tests/tools/test_generate_video_seedance_billing.py` (create)

**Interfaces:**
- Consumes: `build_video_token_usage` (Task 1).
- Local vars available in the `bytedance` branch: `video_model`, `length` (clamped duration), `seedance_resolution`, `input` (dict; `"reference_videos" in input` ⇔ a reference video was passed ⇔ the `video_in` tier).

- [ ] **Step 1: Write the failing test**

Create `tests/tools/test_generate_video_seedance_billing.py`:

```python
from unittest.mock import MagicMock, mock_open, patch

from app.tools.generate_video import generate_video


def _run_seedance(resolution="1080p", reference_videos=None):
    replicate_out = MagicMock()
    replicate_out.read.return_value = b"fakebytes"
    with patch("app.tools.generate_video.replicate_run", return_value=replicate_out), \
         patch("app.tools.generate_video.upload_file_to_s3", return_value="https://cdn/x.mp4"), \
         patch("builtins.open", mock_open()):
        return generate_video(
            action="a",
            refined_prompt="p",
            duration="8",
            video_ratio="9:16",
            video_model="seedance-2.0",
            video_model_provider="bytedance",
            resolution=resolution,
            reference_videos=reference_videos or [],
        )


def test_seedance_reports_resolution_and_duration():
    tu = _run_seedance(resolution="1080p")["token_usage"]
    assert tu["resolution"] == "1080p"
    assert tu["output_video_tokens"] == 8
    assert tu["video_in"] is False


def test_seedance_video_in_when_reference_video_present():
    tu = _run_seedance(reference_videos=["https://cdn/ref.mp4"])["token_usage"]
    assert tu["video_in"] is True
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/tools/test_generate_video_seedance_billing.py -v`
Expected: FAIL — `token_usage` has no `resolution` key (KeyError) / `video_in` missing.

- [ ] **Step 3: Replace the Seedance `token_usage` block**

In `app/tools/generate_video.py`, replace the `bytedance` branch block at lines 583-589:

```python
        token_usage = {
            "type": "Video Generation",
            "model": video_model,
            "input_text_tokens": 0,
            "input_image_tokens": 0,
            "output_video_tokens": length,
        }
```

with:

```python
        token_usage = build_video_token_usage(
            video_model,
            length,
            resolution=seedance_resolution,
            video_in="reference_videos" in input,
        )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/tools/test_generate_video_seedance_billing.py -v`
Expected: PASS (2 passed)

- [ ] **Step 5: Commit**

```bash
git add app/tools/generate_video.py tests/tools/test_generate_video_seedance_billing.py
git commit -m "feat(ai): seedance token_usage reports resolution + video_in for tiered pricing"
```

---

### Task 3: Kling branch — fix duration bug + report `mode` + `audio`

**Files:**
- Modify: `app/tools/generate_video.py` (Kling `token_usage`, currently lines 461-467)
- Test: `tests/tools/test_generate_video_kling_billing.py` (create)

**Interfaces:**
- Consumes: `build_video_token_usage` (Task 1).
- Local vars in the `kuaishou` branch: `video_model`, `length` (clamped duration), `mode` (`"standard"`/`"pro"`, set at branch top from resolution), `input` dict (`input["generate_audio"]` is the final audio flag actually sent to Replicate — forced `False` for omni with a reference video).

- [ ] **Step 1: Write the failing test**

Create `tests/tools/test_generate_video_kling_billing.py`:

```python
from unittest.mock import MagicMock, mock_open, patch

from app.tools.generate_video import generate_video


def _run_kling(resolution="1080p", generate_audio=True, model="kling-v3-video"):
    replicate_out = MagicMock()
    replicate_out.read.return_value = b"fakebytes"
    with patch("app.tools.generate_video.replicate_run", return_value=replicate_out), \
         patch("app.tools.generate_video.upload_file_to_s3", return_value="https://cdn/x.mp4"), \
         patch("builtins.open", mock_open()):
        return generate_video(
            action="a",
            refined_prompt="p",
            duration="8",
            video_ratio="9:16",
            video_model=model,
            video_model_provider="kuaishou",
            resolution=resolution,
            generate_audio=generate_audio,
        )


def test_kling_reports_duration_not_fixed_one():
    # Regression guard: was hardcoded output_video_tokens=1, breaking per-second pricing.
    tu = _run_kling()["token_usage"]
    assert tu["output_video_tokens"] == 8


def test_kling_pro_mode_from_1080p():
    tu = _run_kling(resolution="1080p")["token_usage"]
    assert tu["mode"] == "pro"


def test_kling_standard_mode_below_1080p():
    tu = _run_kling(resolution="720p")["token_usage"]
    assert tu["mode"] == "standard"


def test_kling_audio_flag():
    assert _run_kling(generate_audio=True)["token_usage"]["audio"] is True
    assert _run_kling(generate_audio=False)["token_usage"]["audio"] is False
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/tools/test_generate_video_kling_billing.py -v`
Expected: FAIL — `output_video_tokens` is `1` (not `8`); `mode`/`audio` keys missing.

- [ ] **Step 3: Replace the Kling `token_usage` block**

In `app/tools/generate_video.py`, replace the `kuaishou` branch block at lines 461-467:

```python
        token_usage = {
            "type": "Video Generation",
            "model": video_model,
            "input_text_tokens": 0,
            "input_image_tokens": 0,
            "output_video_tokens": 1,
        }
```

with:

```python
        token_usage = build_video_token_usage(
            video_model,
            length,
            mode=mode,
            audio=bool(input.get("generate_audio")),
        )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/tools/test_generate_video_kling_billing.py -v`
Expected: PASS (4 passed)

- [ ] **Step 5: Commit**

```bash
git add app/tools/generate_video.py tests/tools/test_generate_video_kling_billing.py
git commit -m "fix(ai): kling reports per-second duration + mode/audio (was fixed output_video_tokens=1)"
```

---

### Task 4: Full suite regression check

**Files:** none (verification only)

- [ ] **Step 1: Run the video + kv_motion tests**

Run: `pytest tests/tools/ tests/agents/kv_motion/ -v`
Expected: PASS. The existing `tests/agents/kv_motion/test_service.py` still passes unchanged (its mocked `token_usage` only asserts a subset). If any Veo/Sora/Hunyuan behavior regressed, stop and investigate — those branches must be byte-identical.

- [ ] **Step 2: Commit (only if a fixture needed updating)**

```bash
git add -A
git commit -m "test(ai): regression pass for video billing dimensions"
```

## Self-Review Notes

- Spec coverage: Seedance `resolution`+`video_in` (Task 2), Kling `mode`+`audio`+duration fix (Task 3), Veo/Sora/Hunyuan untouched (constraint), helper is DRY (Task 1). ✓
- The API plan consumes exactly these four keys: `resolution`, `video_in`, `mode`, `audio`, plus `output_video_tokens`. Key names must match the API's `normalizeDim` mapping.
