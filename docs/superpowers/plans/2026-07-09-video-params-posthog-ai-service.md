# Video Generation Parameters → PostHog — ai-service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every video generation emits a PostHog `$ai_generation` event carrying its billing dimensions as flat `video_*` properties — including the Replicate models (Seedance/Kling/Hunyuan) that emit nothing today.

**Architecture:** A `_video_trace_props()` helper builds the flat property dict. Each branch of `generate_video` passes it via `capture_ai_generation(..., **props)`. The 3 Replicate branches (which have no capture call today) get a new success-path capture + a `start` timer; the existing Veo/Sora captures get the props attached. Dimensions only — no cost.

**Tech Stack:** Python 3.11, PostHog LLM observability (`capture_ai_generation`), pytest.

## Global Constraints

- ai-service only. Run commands from `/Users/alva.e202511001/Desktop/work/frndos-agentic/ai-service`, venv active: `source .venv/bin/activate`. Tests: `pytest`.
- Branch `feature/daffa/vc-video-dynamic-pricing` (already checked out in `ai-service/`).
- **Never call real providers/PostHog in tests** — patch `app.tools.generate_video.replicate_run`, `app.tools.generate_video.upload_file_to_s3`, `app.tools.generate_video.capture_ai_generation`, and `builtins.open`.
- Properties are flat and `video_`-prefixed: `video_resolution` (str|null), `video_in` (bool), `video_mode` (str|null), `video_audio` (bool), `video_duration_seconds` (int). Null values are dropped downstream by `ph_ai_kwargs` — passing `None` is safe.
- **Dimensions only — do NOT send `total_cost_usd`.** No pricing logic in ai-service.
- Only `app/tools/generate_video.py` changes (+ new test files). `capture_ai_generation` and `time` are already imported.
- Success-path captures get props. Error-path captures (`google` line 304, `openai` line 718) are left unchanged (they still fire for error tracking; dims omitted — intentional).
- Design spec: `docs/superpowers/specs/2026-07-09-video-params-posthog-design.md`.

---

### Task 1: `_video_trace_props` helper

**Files:**
- Modify: `app/tools/generate_video.py` (add helper just after `build_video_token_usage`, before `def generate_video(`)
- Test: `tests/tools/test_video_trace_props.py` (create)

**Interfaces:**
- Produces: `_video_trace_props(resolution=None, video_in=False, mode=None, audio=False, duration=None) -> dict` with keys `video_resolution`, `video_in`, `video_mode`, `video_audio`, `video_duration_seconds`.

- [ ] **Step 1: Write the failing test**

Create `tests/tools/test_video_trace_props.py`:

```python
from app.tools.generate_video import _video_trace_props


def test_seedance_shape():
    p = _video_trace_props(resolution="1080p", video_in=True, duration=8)
    assert p == {
        "video_resolution": "1080p",
        "video_in": True,
        "video_mode": None,
        "video_audio": False,
        "video_duration_seconds": 8,
    }


def test_kling_shape_and_bool_coercion():
    p = _video_trace_props(mode="pro", audio=1, duration=8)
    assert p["video_mode"] == "pro"
    assert p["video_audio"] is True
    assert p["video_resolution"] is None


def test_defaults():
    p = _video_trace_props()
    assert p == {
        "video_resolution": None,
        "video_in": False,
        "video_mode": None,
        "video_audio": False,
        "video_duration_seconds": None,
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/tools/test_video_trace_props.py -v`
Expected: FAIL — `ImportError: cannot import name '_video_trace_props'`.

- [ ] **Step 3: Add the helper**

In `app/tools/generate_video.py`, immediately after the `build_video_token_usage` function and before `def generate_video(`, insert:

```python
def _video_trace_props(
    resolution: str | None = None,
    video_in: bool = False,
    mode: str | None = None,
    audio: bool = False,
    duration: int | None = None,
) -> dict:
    """Flat PostHog properties for a video ``$ai_generation`` event. Null values
    are dropped by ``ph_ai_kwargs`` downstream, so absent dims simply don't
    appear on the event."""
    return {
        "video_resolution": resolution,
        "video_in": bool(video_in),
        "video_mode": mode,
        "video_audio": bool(audio),
        "video_duration_seconds": duration,
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/tools/test_video_trace_props.py -v`
Expected: PASS (3 passed).

- [ ] **Step 5: Commit**

```bash
git add app/tools/generate_video.py tests/tools/test_video_trace_props.py
git commit -m "feat(ai): _video_trace_props helper for PostHog video generation props"
```

---

### Task 2: Emit capture + props from the Replicate branches (the gap fix)

**Files:**
- Modify: `app/tools/generate_video.py` (`tencent`, `kuaishou`, `bytedance` branches)
- Test: `tests/tools/test_generate_video_posthog.py` (create)

**Interfaces:**
- Consumes: `_video_trace_props` (Task 1); `capture_ai_generation` (already imported).
- Locals available: tencent → `resolution`, `duration` (no `length`); kuaishou → `video_model`, `length`, `mode`, `input`; bytedance → `video_model`, `length`, `seedance_resolution`, `input`.

- [ ] **Step 1: Write the failing test**

Create `tests/tools/test_generate_video_posthog.py`:

```python
from unittest.mock import MagicMock, mock_open, patch

from app.tools.generate_video import generate_video


def _run(provider, model, **over):
    out = MagicMock()
    out.read.return_value = b"bytes"
    base = dict(
        action="a", refined_prompt="p", duration="8", video_ratio="16:9",
        video_model=model, video_model_provider=provider, resolution="1080p",
    )
    base.update(over)
    with patch("app.tools.generate_video.replicate_run", return_value=out), \
         patch("app.tools.generate_video.upload_file_to_s3", return_value="https://cdn/x.mp4"), \
         patch("app.tools.generate_video.capture_ai_generation") as mock_cap, \
         patch("builtins.open", mock_open()):
        generate_video(**base)
    return mock_cap


def test_seedance_emits_generation_with_dims():
    cap = _run("bytedance", "seedance-2.0")
    assert cap.called
    kw = cap.call_args.kwargs
    assert kw["provider"] == "bytedance"
    assert kw["video_resolution"] == "1080p"
    assert kw["video_in"] is False
    assert kw["video_duration_seconds"] == 8


def test_kling_emits_generation_with_mode_audio():
    cap = _run("kuaishou", "kling-v3-video", generate_audio=True)
    assert cap.called
    kw = cap.call_args.kwargs
    assert kw["provider"] == "kuaishou"
    assert kw["video_mode"] == "pro"      # resolution 1080p -> pro
    assert kw["video_audio"] is True
    assert kw["video_duration_seconds"] == 8


def test_hunyuan_emits_generation():
    cap = _run("tencent", "hunyuan-video")
    assert cap.called
    kw = cap.call_args.kwargs
    assert kw["provider"] == "tencent"
    assert kw["video_duration_seconds"] == 8
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/tools/test_generate_video_posthog.py -v`
Expected: FAIL — `capture_ai_generation` not called in the Replicate branches (`cap.called` is False).

- [ ] **Step 3: tencent (Hunyuan) — add start timer + capture**

In `app/tools/generate_video.py`, in the `elif video_model_provider == "tencent":` branch: add a `start` timer as the FIRST line of the branch (right after the `elif ...:` line, before the `if video_ratio ...` block):

```python
    elif video_model_provider == "tencent":
        start = time.time()
```

Then, immediately after that branch's `token_usage = { ... "output_video_tokens": 1, }` dict, add:

```python
        capture_ai_generation(
            model=video_model,
            provider="tencent",
            span_name="generate_video",
            start_time=start,
            **_video_trace_props(duration=int(duration)),
        )
```

- [ ] **Step 4: kuaishou (Kling) — add start timer + capture**

In the `elif video_model_provider == "kuaishou":` branch: add `start = time.time()` as the first line of the branch. Then, immediately after that branch's `token_usage = build_video_token_usage(video_model, length, mode=mode, audio=bool(input.get("generate_audio")))`, add:

```python
        capture_ai_generation(
            model=video_model,
            provider="kuaishou",
            span_name="generate_video",
            start_time=start,
            **_video_trace_props(
                mode=mode,
                audio=bool(input.get("generate_audio")),
                duration=length,
            ),
        )
```

- [ ] **Step 5: bytedance (Seedance) — add start timer + capture**

In the `elif video_model_provider == "bytedance":` branch: add `start = time.time()` as the first line of the branch. Then, immediately after that branch's `token_usage = build_video_token_usage(video_model, length, resolution=seedance_resolution, video_in="reference_videos" in input)`, add:

```python
        capture_ai_generation(
            model=video_model,
            provider="bytedance",
            span_name="generate_video",
            start_time=start,
            **_video_trace_props(
                resolution=seedance_resolution,
                video_in="reference_videos" in input,
                duration=length,
            ),
        )
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `pytest tests/tools/test_generate_video_posthog.py -v`
Expected: PASS (3 passed).

- [ ] **Step 7: Commit**

```bash
git add app/tools/generate_video.py tests/tools/test_generate_video_posthog.py
git commit -m "feat(ai): Replicate video branches emit \$ai_generation with dimension props"
```

---

### Task 3: Attach props to the existing Veo + Sora captures

**Files:**
- Modify: `app/tools/generate_video.py` (`google` success capture ~291-296; `openai` success capture ~694-713 — reorder so `sora_resolution` is computed before the capture)

**Interfaces:**
- Consumes: `_video_trace_props` (Task 1). `resolution`/`duration` (google) and `size`/`duration` (openai) already in scope.

**Note on testing:** the Veo (`genai`) and Sora (`openai`) SDK call-chains are disproportionately complex to mock (not covered by the replicate-based test harness). These are one-line prop additions to existing, working `capture_ai_generation` calls — verify by reading the diff + `py_compile`. No new automated test (consistent with how Veo/Sora were handled in the pricing work).

- [ ] **Step 1: Add props to the Veo (google) success capture**

In `app/tools/generate_video.py`, the `google` branch's SUCCESS capture (currently lines 291-296) — add the props kwarg:

```python
            capture_ai_generation(
                model=video_model,
                provider="google",
                span_name="generate_video",
                start_time=start,
                **_video_trace_props(resolution=resolution, duration=int(duration)),
            )
```

Leave the `except GeminiServerError` error capture (line 304) unchanged.

- [ ] **Step 2: Reorder + add props to the Sora (openai) success capture**

In the `openai` branch's `if operation.status == "completed":` block, the current order is: capture (694-699) → `sora_resolution` comment+computation (701-708) → `token_usage` (709-713). Replace that whole block (lines 694-713) with `sora_resolution` computed FIRST, then the capture with props, then `token_usage`:

```python
                # Sora size is 720p-locked today; report the resolution so
                # sora-2-pro bills its 720p tier. Higher-res tiers activate
                # automatically if `size` is ever unlocked to 1024p/1080p.
                sora_resolution = (
                    "1080p" if "1080" in size
                    else "1024p" if "1024" in size
                    else "720p"
                )

                capture_ai_generation(
                    model=video_model,
                    provider="openai",
                    span_name="generate_video",
                    start_time=start,
                    **_video_trace_props(resolution=sora_resolution, duration=int(duration)),
                )

                token_usage = build_video_token_usage(
                    video_model,
                    int(duration),
                    resolution=sora_resolution,
                )
```

Leave the `except openai.APIStatusError` error capture (line 718) unchanged.

- [ ] **Step 3: Syntax check**

Run: `python3 -m py_compile app/tools/generate_video.py`
Expected: OK (valid python).

- [ ] **Step 4: Regression — the Replicate + billing tests still pass**

Run: `pytest tests/tools/test_generate_video_posthog.py tests/tools/test_video_trace_props.py tests/tools/test_generate_video_kling_billing.py tests/tools/test_generate_video_seedance_billing.py -v`
Expected: PASS (no behavior changed in those paths).

- [ ] **Step 5: Commit**

```bash
git add app/tools/generate_video.py
git commit -m "feat(ai): attach dimension props to Veo + Sora \$ai_generation captures"
```

---

## Self-Review Notes

- **Spec coverage:** helper (Task 1); Replicate branches emit + props, fixing the absence (Task 2); Veo/Sora props (Task 3); dims-only/no-cost, generation-level, ai-service-only (constraints). ✓
- **Type consistency:** `_video_trace_props(...)` signature + the 5 `video_*` keys are defined in Task 1 and used identically in Tasks 2 & 3; the dim expressions (`seedance_resolution`, `"reference_videos" in input`, `mode`, `bool(input.get("generate_audio"))`) match the same expressions those branches already use for `token_usage`. ✓
- **Testability honesty:** Task 1 pure-tested; Task 2 fully tested via the replicate mock harness (the high-value gap fix); Task 3's SDK-chain props are mechanical + read/py_compile-verified (called out, not hidden). ✓
- **No placeholders:** every step has concrete code + exact commands. ✓
