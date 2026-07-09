# Video Generation Parameters → PostHog — ai-service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every video generation's PostHog `$ai_generation` event carries its billing dimensions as flat `video_*` properties, for segmentation in AI-observability.

**Architecture:** Replicate models (Seedance/Kling/Hunyuan) are **already** captured at the `run_with_retry` chokepoint — so we enrich that capture with our dims via a new `extra_properties` param (no double-capture; house rule = one chokepoint per provider). The Replicate branches pass `_video_trace_props(...)` into their existing `replicate_run(...)` call. Veo/Sora have their own branch-level captures, which we enrich directly. Dimensions only — no cost.

**Tech Stack:** Python 3.11, PostHog LLM observability (`capture_ai_generation`), pytest.

## Global Constraints

- ai-service only. Run from `/Users/alva.e202511001/Desktop/work/frndos-agentic/ai-service`, venv active: `source .venv/bin/activate`. Tests: `pytest`.
- Branch `feature/daffa/vc-video-dynamic-pricing` (already checked out in `ai-service/`).
- **Never call real providers/PostHog in tests** — patch `replicate_run` / `_get_replicate_client` / `capture_ai_generation` / `upload_file_to_s3` / `builtins.open` as appropriate.
- Properties are flat, `video_`-prefixed: `video_resolution` (str|null), `video_in` (bool), `video_mode` (str|null), `video_audio` (bool), `video_duration_seconds` (int). Null values are dropped downstream by `ph_ai_kwargs`.
- **Do NOT add any new `capture_ai_generation` call in the Replicate branches** — that double-counts (the chokepoint already captures). Enrich the chokepoint instead.
- **Dimensions only — do NOT send `total_cost_usd`.** No pricing logic in ai-service.
- **Line numbers drift** between tasks (each task inserts code) — locate edit points by the quoted surrounding CONTENT, not by line number.
- Success-path captures get props; Veo/Sora error-path captures stay unchanged. (Replicate error captures get props automatically via `extra_properties` forwarding.)
- Design spec: `docs/superpowers/specs/2026-07-09-video-params-posthog-design.md`.

---

### Task 1: `_video_trace_props` helper — ALREADY DONE (commit `ebadfe8`)

The helper `_video_trace_props(resolution=None, video_in=False, mode=None, audio=False, duration=None) -> dict` exists in `app/tools/generate_video.py` (keys: `video_resolution`, `video_in`, `video_mode`, `video_audio`, `video_duration_seconds`), with `tests/tools/test_video_trace_props.py` green. **Do not redo.** Later tasks consume it.

---

### Task 2: `run_with_retry` forwards `extra_properties` to its captures

**Files:**
- Modify: `app/utils/replicate_client.py` (`run_with_retry` signature + its 3 `capture_ai_generation` calls)
- Test: `tests/tools/test_replicate_client_trace.py` (create)

**Interfaces:**
- Produces: `run_with_retry(model_ref, input_params, ..., extra_properties: dict | None = None)` — the extra props are merged into every `capture_ai_generation` it emits (success + both error paths).

- [ ] **Step 1: Write the failing test**

Create `tests/tools/test_replicate_client_trace.py`:

```python
from unittest.mock import MagicMock, patch

from app.utils.replicate_client import run_with_retry


@patch("app.utils.replicate_client.capture_ai_generation")
@patch("app.utils.replicate_client._get_replicate_client")
def test_forwards_extra_properties_on_success(mock_get_client, mock_cap):
    mock_get_client.return_value.run.return_value = "output"
    run_with_retry(
        "owner/model:v1",
        {"prompt": "p"},
        extra_properties={"video_resolution": "1080p", "video_in": True},
    )
    kw = mock_cap.call_args.kwargs
    assert kw["provider"] == "replicate"
    assert kw["video_resolution"] == "1080p"
    assert kw["video_in"] is True


@patch("app.utils.replicate_client.capture_ai_generation")
@patch("app.utils.replicate_client._get_replicate_client")
def test_no_extra_properties_is_safe(mock_get_client, mock_cap):
    mock_get_client.return_value.run.return_value = "output"
    run_with_retry("owner/model:v1", {"prompt": "p"})
    assert mock_cap.called
    assert "video_resolution" not in mock_cap.call_args.kwargs
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/tools/test_replicate_client_trace.py -v`
Expected: FAIL — `run_with_retry()` got an unexpected keyword argument `extra_properties`.

- [ ] **Step 3: Add the param and forward it**

In `app/utils/replicate_client.py`, add a parameter to `run_with_retry`'s signature — immediately after `exponential_base: float = DEFAULT_EXPONENTIAL_BASE,` and before the closing `) -> Any:`:

```python
    extra_properties: dict[str, Any] | None = None,
```

Then, in **all three** `capture_ai_generation(...)` calls inside `run_with_retry` (the success call with `span_name="replicate_run"`, the non-rate-limit error call with `error=e`, and the exhausted-retries call with `error=last_error`), add this line as the last kwarg before the closing `)`:

```python
                **(extra_properties or {}),
```

(Match each call's existing indentation.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/tools/test_replicate_client_trace.py -v`
Expected: PASS (2 passed).

- [ ] **Step 5: Commit**

```bash
git add app/utils/replicate_client.py tests/tools/test_replicate_client_trace.py
git commit -m "feat(ai): run_with_retry forwards extra_properties to its \$ai_generation captures"
```

---

### Task 3: Replicate branches pass `_video_trace_props` into `replicate_run`

**Files:**
- Modify: `app/tools/generate_video.py` (`tencent`, `kuaishou`, `bytedance` branches — their `replicate_run(...)` call)
- Test: `tests/tools/test_generate_video_posthog.py` (create)

**Interfaces:**
- Consumes: `_video_trace_props` (Task 1); the `extra_properties` param on `replicate_run` (Task 2 — `replicate_run` is `run_with_retry` imported as `replicate_run`).
- Locals at each `replicate_run` call: tencent → `duration`; kuaishou → `mode`, `input`, `length`; bytedance → `seedance_resolution`, `input`, `length`.

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
    with patch("app.tools.generate_video.replicate_run", return_value=out) as mock_run, \
         patch("app.tools.generate_video.upload_file_to_s3", return_value="https://cdn/x.mp4"), \
         patch("builtins.open", mock_open()):
        generate_video(**base)
    return mock_run


def test_seedance_passes_dims_to_replicate_run():
    mock_run = _run("bytedance", "seedance-2.0")
    props = mock_run.call_args.kwargs["extra_properties"]
    assert props["video_resolution"] == "1080p"
    assert props["video_in"] is False
    assert props["video_duration_seconds"] == 8


def test_kling_passes_mode_audio_to_replicate_run():
    mock_run = _run("kuaishou", "kling-v3-video", generate_audio=True)
    props = mock_run.call_args.kwargs["extra_properties"]
    assert props["video_mode"] == "pro"      # 1080p -> pro
    assert props["video_audio"] is True
    assert props["video_duration_seconds"] == 8


def test_hunyuan_passes_duration_to_replicate_run():
    mock_run = _run("tencent", "hunyuan-video")
    props = mock_run.call_args.kwargs["extra_properties"]
    assert props["video_duration_seconds"] == 8
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/tools/test_generate_video_posthog.py -v`
Expected: FAIL — `KeyError: 'extra_properties'` (the branches don't pass it yet).

- [ ] **Step 3: tencent (Hunyuan) — pass extra_properties**

In `app/tools/generate_video.py`, in the `tencent` branch, the `replicate_run(...)` call is:

```python
            output = replicate_run(
                model_ref="tencent/hunyuan-video:8283f26be7ce5dc0119324b4752cbfd3970b3ef1b923c4d3c35eb6546518747a",
                input_params=input,
            )
```

Add the `extra_properties` kwarg:

```python
            output = replicate_run(
                model_ref="tencent/hunyuan-video:8283f26be7ce5dc0119324b4752cbfd3970b3ef1b923c4d3c35eb6546518747a",
                input_params=input,
                extra_properties=_video_trace_props(duration=int(duration)),
            )
```

- [ ] **Step 4: kuaishou (Kling) — pass extra_properties**

In the `kuaishou` branch, the call is `replicate_run(model_ref="kwaivgi/" + video_model, input_params=input,)`. Add:

```python
            output = replicate_run(
                model_ref="kwaivgi/" + video_model,
                input_params=input,
                extra_properties=_video_trace_props(
                    mode=mode,
                    audio=bool(input.get("generate_audio")),
                    duration=length,
                ),
            )
```

- [ ] **Step 5: bytedance (Seedance) — pass extra_properties**

In the `bytedance` branch, the call is `replicate_run(model_ref=f"bytedance/{video_model}", input_params=input,)`. Add:

```python
            output = replicate_run(
                model_ref=f"bytedance/{video_model}",
                input_params=input,
                extra_properties=_video_trace_props(
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
git commit -m "feat(ai): Replicate video branches send dimension props to the chokepoint capture"
```

---

### Task 4: Attach props to the Veo + Sora branch captures

**Files:**
- Modify: `app/tools/generate_video.py` (`google` success capture; `openai` success capture — reorder so `sora_resolution` precedes the capture)

**Interfaces:**
- Consumes: `_video_trace_props` (Task 1). `resolution`/`duration` (google) and `size`/`duration` (openai) already in scope.

**Note on testing:** the Veo (`genai`) and Sora (`openai`) SDK call-chains are disproportionately complex to mock. These are one-line prop additions to existing, working `capture_ai_generation` calls — verify by reading the diff + `py_compile`. No new automated test (consistent with how Veo/Sora were handled in the pricing work).

- [ ] **Step 1: Add props to the Veo (google) success capture**

In the `google` branch, the SUCCESS capture (the one WITHOUT `error=`, immediately before `token_usage = build_video_token_usage(video_model, int(duration), resolution=resolution)`) currently reads:

```python
            capture_ai_generation(
                model=video_model,
                provider="google",
                span_name="generate_video",
                start_time=start,
            )
```

Add the props kwarg:

```python
            capture_ai_generation(
                model=video_model,
                provider="google",
                span_name="generate_video",
                start_time=start,
                **_video_trace_props(resolution=resolution, duration=int(duration)),
            )
```

Leave the `except GeminiServerError` capture (the one with `error=e`) unchanged.

- [ ] **Step 2: Reorder + add props to the Sora (openai) success capture**

In the `openai` branch's `if operation.status == "completed":` block, the current order is: capture → `sora_resolution` comment+computation → `token_usage`. Replace that whole block with `sora_resolution` computed FIRST, then the capture with props, then `token_usage`:

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

Leave the `except openai.APIStatusError` capture unchanged.

- [ ] **Step 3: Syntax check**

Run: `python3 -m py_compile app/tools/generate_video.py`
Expected: OK.

- [ ] **Step 4: Regression — all posthog + billing tests pass**

Run: `pytest tests/tools/test_video_trace_props.py tests/tools/test_replicate_client_trace.py tests/tools/test_generate_video_posthog.py tests/tools/test_generate_video_kling_billing.py tests/tools/test_generate_video_seedance_billing.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/tools/generate_video.py
git commit -m "feat(ai): attach dimension props to Veo + Sora \$ai_generation captures"
```

---

## Self-Review Notes

- **Spec coverage:** helper (Task 1 done); chokepoint `extra_properties` (Task 2); Replicate branches thread props (Task 3); Veo/Sora props (Task 4); no double-capture / dims-only / ai-service-only (constraints). ✓
- **Type consistency:** `_video_trace_props(...)` (Task 1) → passed as `extra_properties=` into `replicate_run` (Task 3, forwarded by Task 2's param) and spread into the Veo/Sora captures (Task 4). The dim expressions match those branches' existing `token_usage` calls. ✓
- **Testability honesty:** Tasks 1-3 fully unit-tested (helper pure; chokepoint forwarding; branch threading via the replicate mock). Task 4's SDK-chain props are mechanical + read/py_compile-verified (called out). ✓
- **No double-capture:** the Replicate branches add NO capture — they only pass `extra_properties` into the existing `replicate_run`. Verified against the tracing house rule. ✓
