# KV Upscale Fidelity — ai-service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the upscaler that rewrites people's faces, and move from ×-multipliers to 2K/4K resolution targets.

**Architecture:** `clarity-upscaler` is a Stable Diffusion img2img pipeline — 18 denoising steps against an SD checkpoint — so redrawing the image is what it does. It is replaced by `clarity-pro-upscaler` at `creativity=-10`, measured 4.5× more faithful. Because pro's `scale_factor` is an enum of 2/4/8/16, the service picks the smallest value that overshoots the requested target and then downscales to the exact long edge in code.

**Tech Stack:** Python 3.11, FastAPI, Pillow, Replicate, pytest.

## Global Constraints

- **Model:** `philz1337x/clarity-pro-upscaler`, version pinned to `8e33eb474936d75d3ceaa787f3e66f5ba16f35db0853a7697a4ca4e5fc14b6cd`. It is a **community** model — a versionless ref resolves via the official-model endpoint and 404s.
- **`creativity=-10`.** Measured: `-10` scores 2.72, `-5` scores 3.30, `0` scores 4.61 against a Lanczos structural baseline. More negative is strictly better here.
- **Only four inputs exist on pro:** `image`, `scale_factor`, `creativity`, `output_format`. Sending `prompt`, `resemblance`, `dynamic`, `tiling_width`, `tiling_height`, or `sd_model` is an error — they belong to the old model.
- **`scale_factor` is an enum: `[2, 4, 8, 16]`.** Not a float, not arbitrary.
- **Targets are long-edge:** `2k` = 2048, `4k` = 4096. Aspect always preserved.
- **`face_enhance` must stay `False`** on the Real-ESRGAN fallback — GFPGAN alters faces, which is the entire bug being fixed.
- **64 MP is a hard ceiling** on pro output.
- Baseline: `tests/agents/kv_generator` carries 13 pre-existing failures unrelated to this work. Compare against a HEAD worktree, never `git stash`.

## Spec

`docs/superpowers/specs/2026-08-07-kv-upscale-fidelity-and-resolution-targets-design.md`

## File Structure

| File | Responsibility |
|---|---|
| `app/utils/config.py` | Model ref + pinned version settings. |
| `app/tools/upscale_image.py` | Target→scale_factor maths, engine calls, exact-target downscale. |
| `app/agents/kv_upscale/request_schema.py` | `factor` → `target`. |
| `app/agents/kv_upscale/service.py` | Pass target; report billable megapixels. |
| `app/agents/kv_upscale/api_client.py` | Send `target` + `billable_megapixels`. |
| `app/agents/kv_resize_tile_upscale/*` | Same three changes, tile flow. |
| `tests/tools/test_upscale_targets.py` | Selection maths, guard, downscale. |

---

### Task 1: Target → scale_factor selection

Pure maths, no network. This is the load-bearing logic and gets tested hardest.

**Files:**
- Modify: `app/tools/upscale_image.py`
- Test: `tests/tools/test_upscale_targets.py`

**Interfaces:**
- Produces:
  - `TARGET_LONG_EDGE: dict[str, int]` — `{"2k": 2048, "4k": 4096}`
  - `SCALE_FACTORS: tuple[int, ...]` — `(2, 4, 8, 16)`
  - `MAX_OUTPUT_MEGAPIXELS: float` — `64.0`
  - `select_scale_factor(src_w: int, src_h: int, target: str) -> int | None` — `None` means no upscale needed.
  - `plan_upscale(src_w: int, src_h: int, target: str) -> UpscalePlan`

- [ ] **Step 1: Write the failing test**

Create `tests/tools/test_upscale_targets.py`:

```python
"""Target-to-scale_factor selection for clarity-pro.

pro's scale_factor is an enum [2,4,8,16], so we pick the smallest value that
reaches the requested long edge and downscale to the exact target afterwards.
"""
import pytest

from app.tools.upscale_image import (
    MAX_OUTPUT_MEGAPIXELS,
    plan_upscale,
    select_scale_factor,
)


@pytest.mark.parametrize(
    "src_w,src_h,target,expected",
    [
        # Real staging KV sizes, all land on the same factor.
        (1088, 1376, "2k", 2),
        (1254, 1254, "2k", 2),
        (1024, 1536, "2k", 2),
        (1536, 1024, "2k", 2),
        (1088, 1376, "4k", 4),
        (1254, 1254, "4k", 4),
        (1504, 992, "4k", 4),
        # A large source needs less magnification for the same target.
        (2400, 3000, "4k", 2),
    ],
)
def test_picks_the_smallest_sufficient_factor(src_w, src_h, target, expected):
    assert select_scale_factor(src_w, src_h, target) == expected


@pytest.mark.parametrize(
    "src_w,src_h,target",
    [
        (2048, 1200, "2k"),   # exactly meets it
        (4096, 2000, "4k"),
        (3000, 2000, "2k"),   # already exceeds it
    ],
)
def test_returns_none_when_no_upscale_is_needed(src_w, src_h, target):
    # Nothing a model can add to pixels that already exist. Skip the spend.
    assert select_scale_factor(src_w, src_h, target) is None


def test_orientation_does_not_change_the_factor():
    # Long edge is long edge; a rotated KV must cost the same.
    assert select_scale_factor(1024, 1536, "4k") == select_scale_factor(1536, 1024, "4k")


def test_guards_the_64mp_ceiling():
    # 2047px square -> 4K forces sf=4 -> 8188^2 ~= 67MP, over the cap.
    plan = plan_upscale(2047, 2047, "4k")

    assert plan.scale_factor == 4
    assert plan.prescale_to is not None, "source must be pre-downscaled to fit the cap"
    pw, ph = plan.prescale_to
    assert (pw * plan.scale_factor) * (ph * plan.scale_factor) / 1_000_000 <= MAX_OUTPUT_MEGAPIXELS
    # And it must still reach the target after magnification.
    assert max(pw, ph) * plan.scale_factor >= 4096


def test_plan_reports_the_exact_delivered_size():
    plan = plan_upscale(1024, 1536, "4k")

    assert plan.final_size == (2731, 4096)  # long edge exact, aspect preserved


def test_plan_reports_billable_megapixels_from_model_output_not_delivery():
    # Replicate bills what it produced, not what we hand back after downscaling.
    plan = plan_upscale(1024, 1536, "4k")

    assert plan.billable_megapixels == pytest.approx(
        (1024 * 4) * (1536 * 4) / 1_000_000, rel=1e-3
    )
    assert plan.billable_megapixels > (plan.final_size[0] * plan.final_size[1]) / 1_000_000
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python -m pytest tests/tools/test_upscale_targets.py -q`
Expected: FAIL — `ImportError: cannot import name 'plan_upscale'`

- [ ] **Step 3: Implement selection and planning**

Add to `app/tools/upscale_image.py`:

```python
from dataclasses import dataclass

# User-facing targets, measured on the LONG edge so portrait, square, and
# landscape KVs all land on a predictable number.
TARGET_LONG_EDGE: dict[str, int] = {"2k": 2048, "4k": 4096}

# clarity-pro's scale_factor is an enum, not a free float.
SCALE_FACTORS: tuple[int, ...] = (2, 4, 8, 16)

# Hard ceiling on pro's output.
MAX_OUTPUT_MEGAPIXELS: float = 64.0


@dataclass(frozen=True)
class UpscalePlan:
    """Everything the caller needs to run and bill one upscale."""

    target: str
    # None when the source already meets the target — no model run, no spend.
    scale_factor: int | None
    # Set only when the projected output would breach the 64 MP ceiling; the
    # source is resized to this first. Harmless, since we downscale to the
    # target afterwards anyway.
    prescale_to: tuple[int, int] | None
    # Exact delivered dimensions, long edge on target, aspect preserved.
    final_size: tuple[int, int]
    # Megapixels the MODEL produces. This is what Replicate bills, and it is
    # larger than the delivered image whenever we downscale.
    billable_megapixels: float


def select_scale_factor(src_w: int, src_h: int, target: str) -> int | None:
    """Smallest enum factor whose result reaches the target long edge.

    Returns None when the source already meets it — no model improves on
    pixels that are already there.
    """
    want = TARGET_LONG_EDGE[target]
    long_edge = max(src_w, src_h)
    if long_edge >= want:
        return None
    for sf in SCALE_FACTORS:
        if long_edge * sf >= want:
            return sf
    return SCALE_FACTORS[-1]


def _fit_long_edge(src_w: int, src_h: int, long_edge: int) -> tuple[int, int]:
    """Scale (w, h) so its long edge equals `long_edge`, aspect preserved."""
    if src_w >= src_h:
        return long_edge, max(1, round(src_h * long_edge / src_w))
    return max(1, round(src_w * long_edge / src_h)), long_edge


def plan_upscale(src_w: int, src_h: int, target: str) -> UpscalePlan:
    want = TARGET_LONG_EDGE[target]
    sf = select_scale_factor(src_w, src_h, target)
    final_size = _fit_long_edge(src_w, src_h, want)

    if sf is None:
        return UpscalePlan(target, None, None, final_size, 0.0)

    prescale_to: tuple[int, int] | None = None
    eff_w, eff_h = src_w, src_h

    projected_mp = (src_w * sf) * (src_h * sf) / 1_000_000
    if projected_mp > MAX_OUTPUT_MEGAPIXELS:
        # Shrink the source until source x sf fits the cap. The result is
        # still >= the target, because sf was chosen to overshoot it.
        max_src_px = (MAX_OUTPUT_MEGAPIXELS * 1_000_000) / (sf * sf)
        shrink = (max_src_px / (src_w * src_h)) ** 0.5
        eff_w = max(1, int(src_w * shrink))
        eff_h = max(1, int(src_h * shrink))
        prescale_to = (eff_w, eff_h)

    return UpscalePlan(
        target=target,
        scale_factor=sf,
        prescale_to=prescale_to,
        final_size=final_size,
        billable_megapixels=(eff_w * sf) * (eff_h * sf) / 1_000_000,
    )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python -m pytest tests/tools/test_upscale_targets.py -q`
Expected: PASS, 14 tests.

- [ ] **Step 5: Commit**

```bash
git add app/tools/upscale_image.py tests/tools/test_upscale_targets.py
git commit -m "feat(ai): add target-to-scale_factor planning for clarity-pro upscales"
```

---

### Task 2: Swap the engine

**Files:**
- Modify: `app/utils/config.py`
- Modify: `app/tools/upscale_image.py`

**Interfaces:**
- Consumes: `plan_upscale()` from Task 1.
- Produces: `upscale(source_path: str, target: str) -> tuple[bytes, str, float]` — PNG bytes, model_version, billable megapixels.

- [ ] **Step 1: Replace the model settings**

In `app/utils/config.py`, replace the `STUDIO_KV_UPSCALE_MODEL` / `..._MODEL_VERSION` block:

```python
    # KV Upscale (Replicate)
    # Primary upscaler. clarity-upscaler was replaced 2026-08-07: it is a
    # Stable Diffusion img2img pipeline (sd_model checkpoint, 18 denoising
    # steps) and rewrote subjects' faces at any runnable creativity value.
    # See docs/superpowers/specs/2026-08-07-kv-upscale-fidelity-*.md.
    # Fallback (Real-ESRGAN) is hard-coded in app/tools/upscale_image.py.
    STUDIO_KV_UPSCALE_MODEL: str = "clarity-pro-upscaler"
    # Pinned version SHA. clarity-pro-upscaler is a *community* (not
    # "Official") Replicate model, so a versionless ref resolves via the
    # official-model endpoint and 404s. Bump when the author republishes.
    STUDIO_KV_UPSCALE_MODEL_VERSION: str = (
        "8e33eb474936d75d3ceaa787f3e66f5ba16f35db0853a7697a4ca4e5fc14b6cd"
    )
    # Fidelity dial, -10..10. Negative is stricter. Measured against a
    # Lanczos structural baseline on real KVs: -10 -> 2.72, -5 -> 3.30,
    # 0 -> 4.61, and the old engine -> 12.12. Do not raise without re-running
    # the bake-off in the spec.
    STUDIO_KV_UPSCALE_CREATIVITY: int = -10
```

- [ ] **Step 2: Rewrite the primary call**

In `app/tools/upscale_image.py`, replace `CLARITY_UPSCALER_REF`, `_CLARITY_SD_MODEL`, and `upscale_with_clarity` with:

```python
CLARITY_PRO_REF = "philz1337x/clarity-pro-upscaler"
REAL_ESRGAN_REF = "nightmareai/real-esrgan"


def _pro_run_ref() -> str:
    version = settings.STUDIO_KV_UPSCALE_MODEL_VERSION
    if version:
        return f"{CLARITY_PRO_REF}:{version}"
    return CLARITY_PRO_REF


def upscale_with_pro(source_path: str, scale_factor: int) -> tuple[bytes, str]:
    """Run clarity-pro-upscaler and return (bytes, model_version).

    Only four inputs exist on this model. Do NOT reintroduce prompt,
    resemblance, dynamic, tiling_*, or sd_model — those belonged to
    clarity-upscaler and this model rejects them.
    """
    with open(source_path, "rb") as fh:
        output = replicate_run(
            model_ref=_pro_run_ref(),
            input_params={
                "image": fh,
                "scale_factor": scale_factor,
                "creativity": settings.STUDIO_KV_UPSCALE_CREATIVITY,
                "output_format": "png",
            },
        )
    if not output:
        raise Exception("No image data received from clarity-pro upscaler")
    # pro returns a single file; the old model returned a list. Handle both
    # so a model swap never trips this line again.
    first = output[0] if isinstance(output, list) else output
    return first.read(), CLARITY_PRO_REF
```

- [ ] **Step 3: Delete the old model entirely**

Remove every remaining reference to `philz1337x/clarity-upscaler`, `_CLARITY_SD_MODEL`, and the `creativity=0.3` / `resemblance` / `dynamic` / `tiling_*` parameters.

Run: `grep -rn "clarity-upscaler\|resemblance\|sd_model\|tiling_width" app/`
Expected: no output. No configuration of that model can meet the fidelity requirement, so leaving a path to it is a trap.

- [ ] **Step 4: Rewrite `upscale()` around the plan**

```python
def upscale(source_path: str, target: str) -> tuple[bytes, str, float]:
    """Upscale to a resolution target. Returns (png_bytes, model_version,
    billable_megapixels).

    `billable_megapixels` is what the MODEL produced — Replicate bills that,
    not the downscaled image we hand back.
    """
    with Image.open(source_path) as im:
        src_w, src_h = im.size
        plan = plan_upscale(src_w, src_h, target)

        # Source already meets the target: pure resample, no spend.
        if plan.scale_factor is None:
            return _to_png(im.resize(plan.final_size, Image.LANCZOS)), "lanczos", 0.0

        run_path = source_path
        if plan.prescale_to is not None:
            run_path = _write_temp_png(im.resize(plan.prescale_to, Image.LANCZOS))

    try:
        raw, model_version = upscale_with_pro(run_path, plan.scale_factor)
    except ReplicateRateLimitError:
        raw, model_version = _run_esrgan_to_target(run_path, plan)
    except Exception as exc:  # noqa: BLE001
        if _is_recoverable_via_fallback(exc):
            raw, model_version = _run_esrgan_to_target(run_path, plan)
        else:
            raise

    # Land the exact pixel spec. Runs on BOTH engines — rounding on an
    # arbitrary ratio can land a pixel off, and both must agree.
    with Image.open(io.BytesIO(raw)) as out:
        final = _to_png(out.resize(plan.final_size, Image.LANCZOS))

    return final, model_version, plan.billable_megapixels


def _run_esrgan_to_target(source_path: str, plan: UpscalePlan) -> tuple[bytes, str]:
    """Fallback. Real-ESRGAN takes an arbitrary `scale`, so it gets the exact
    ratio rather than an enum value.

    face_enhance stays False — GFPGAN alters faces, which is the whole bug.
    """
    with Image.open(source_path) as im:
        ratio = max(plan.final_size) / max(im.size)
    with open(source_path, "rb") as fh:
        output = replicate_run(
            model_ref=REAL_ESRGAN_REF,
            input_params={"image": fh, "scale": ratio, "face_enhance": False},
        )
    if not output:
        raise Exception("No image data received from Real-ESRGAN")
    return output.read(), REAL_ESRGAN_REF
```

Add `_to_png(im) -> bytes` and `_write_temp_png(im) -> str` helpers beside these.

- [ ] **Step 5: Run the tool tests**

Run: `python -m pytest tests/tools/ -q`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/utils/config.py app/tools/upscale_image.py
git commit -m "feat(ai): replace clarity-upscaler with clarity-pro at creativity=-10"
```

---

### Task 3: Thread `target` through both agents

**Files:**
- Modify: `app/agents/kv_upscale/request_schema.py`, `service.py`, `api_client.py`
- Modify: `app/agents/kv_resize_tile_upscale/request_schema.py`, `service.py`, `api_client.py`

**Interfaces:**
- Consumes: `upscale(source_path, target) -> (bytes, model_version, billable_megapixels)` from Task 2.
- Produces: `post_completed(..., target: str, billable_megapixels: float)` — the api plan consumes both.

- [ ] **Step 1: Swap the request field**

In both `request_schema.py` files, replace:

```python
    factor: float = Field(gt=1.0, le=4.0)
```

with:

```python
    target: Literal["2k", "4k"]
```

- [ ] **Step 2: Update both services**

In each `service.py`, change the `upscale()` call to unpack three values and
pass `req.target`, and change the filename from `{upscale_id}-{factor}x.png`
to `{upscale_id}-{target}.png`:

```python
        image_bytes, model_version, billable_megapixels = upscale(
            source_path=source_path,
            target=req.target,
        )
        ...
        file_name = f"{req.upscale_id}-{req.target}.png"
```

Then pass both new values into `post_completed(...)`, and replace `factor`
with `target` in every `extra={...}` log payload in the file.

- [ ] **Step 3: Extend both api clients**

In each `api_client.py`, add the two fields to the payload:

```python
    payload["target"] = target
    # What the MODEL produced, which is what Replicate bills. The api cannot
    # derive this from width/height once we downscale to the target.
    payload["billable_megapixels"] = billable_megapixels
```

- [ ] **Step 4: Verify no `factor` remains in either agent**

Run: `grep -rn "factor" app/agents/kv_upscale/ app/agents/kv_resize_tile_upscale/`
Expected: no output.

- [ ] **Step 5: Run the agent tests**

Run: `python -m pytest tests/agents/ -q`
Expected: same 13 pre-existing failures as HEAD, nothing new. Verify against a
HEAD worktree — never `git stash`.

- [ ] **Step 6: Commit**

```bash
git add app/agents/kv_upscale/ app/agents/kv_resize_tile_upscale/
git commit -m "feat(ai): accept 2k/4k targets and report billable megapixels"
```

---

### Task 4: Verify fidelity against the spec's baseline

**Files:** none — verification only.

Fidelity cannot be unit-tested. The spec's measurement table is the regression
baseline, and this task re-establishes it against the real implementation.

- [ ] **Step 1: Upscale a KV containing a face, at 2K**

Use any KV with a person in it. Save the result.

- [ ] **Step 2: Compare the face region against the source**

Crop the same normalised region from the source (Lanczos-resized to the output
size) and from the result, then compute mean absolute difference.

Expected: **~3 or below**. The old engine scored 12.12 on one face and 17.77 on
five. Anything above ~6 means `creativity` is not reaching the model — check it
is `-10` and that no stale parameter is being sent.

- [ ] **Step 3: Confirm rendered text survives**

Check any small text in the KV is still legible and spelled correctly. The old
engine turned `MENDUKUNG GENERASI PENUH POTENSI` into
`MENCUKUNG STNERASI PENCH POTENSI`. Garbled copy is a release blocker.

- [ ] **Step 4: Repeat at 4K**

Expected: ~4 or below, and dimensions exactly 4096 on the long edge.

- [ ] **Step 5: Commit nothing**

If fidelity regresses, fix it in Task 2 rather than accepting a worse number.
