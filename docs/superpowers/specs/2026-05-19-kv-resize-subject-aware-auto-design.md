# KV Generator — Subject-Aware Auto-Pipeline for Resize

**Date:** 2026-05-19
**Status:** Draft
**Builds on:** `2026-05-11-kv-resize-force-ai-design.md` (force-AI baseline)
**Relates to:** `2026-04-28-studio-kv-resize-design.md` (original resize design)

## Summary

The current resize pipeline center-crops the source to match the target aspect, then outpaints any margin. For aspect-ratio changes — especially cross-orientation conversions like 9:16 portrait → 16:9 landscape — this throws away up to **68% of the source pixels** (the top/bottom slabs) and asks gpt-image-2 only to fill thin side margins. The subject (face, product, logo) commonly lives off-center vertically in portraits, so it gets cropped out before the AI ever sees it.

This spec keeps every output tile gpt-image-2-generated (per the force-AI baseline) but makes two upstream decisions smarter, **automatically, with no new UI surface**:

1. **Where to crop** — replace the geometric-center heuristic with a subject-aware center derived from a single cheap vision pre-pass per source.
2. **Whether to crop at all** — when source and target orientations conflict or aspect delta is large, switch from "crop-then-extend-margin" to "fit-then-extend-sides" so the source survives intact and the AI extends the scene laterally instead of inventing the missing 60%.

The vision pre-pass also returns semantic context (content type, visible-text presence, short style hint) which we splice into the outpaint guidance so gpt-image-2's extensions are coherent with the source.

## Goal

When a user picks N platforms and starts a resize, the system should produce output where the original subject is preserved in all N tiles without the user lifting a finger — no preview, no manual crop, no settings — and cost should rise by less than 1% per batch over the current force-AI baseline.

## Non-goals

- **Not adding any user-facing UI gates.** No preview overlay before generation, no per-platform settings, no "are you sure" dialogs. Resize stays one-click.
- **Not switching the generation model.** `gpt-image-2` for the outpaint stays.
- **Not introducing Gemini for vision.** OpenAI infrastructure is already wired in ai-service; reuse it.
- **Not removing the existing `smart_crop` heuristic.** It becomes the fallback when the vision pre-pass fails or returns an invalid result.
- **Not changing the API or web contract.** Endpoints, SSE stream, polling, and DB schema stay identical.
- **Not adding per-tile review or "regenerate this one" UI** (still tracked in `2026-04-07-kv-ai-resize-design.md` as future work).
- **Not introducing a per-tile vision pass.** One vision call per source, shared across all platforms in the batch.

## Decisions

| Question | Decision | Reasoning |
|---|---|---|
| Vision model | `gpt-4o-mini` with structured-output JSON mode | OpenAI client already in `app/services/image_translation.py` and `app/agents/kv_generator/service.py`. Gemini is configured but not used for vision in any current path; sticking with OpenAI keeps the surface area small. |
| When to fit-not-fill vs crop | Cross-orientation, aspect delta > 30%, or `has_visible_text=true` → fit-not-fill. Otherwise subject-aware crop. | Threshold tuned to capture the destructive cases (portrait→landscape and vice versa) while leaving aspect-similar cases on the cheaper crop path. Text-bearing sources always preserved intact. |
| Caching of vision results | **None.** Each per-tile job computes its own vision pass. | Avoids introducing Redis as production infrastructure (currently configured in env but no client utility, not active). Worst-case duplication: N parallel jobs × ~$0.0005 = ~$0.0025 per 5-tile batch. Calls run in parallel with generation queue, so wall-time impact is one extra `analyze()` step per job (~1s) absorbed by the much longer outpaint step. |
| Vision call determinism | `temperature=0` on the gpt-4o-mini call | Without caching, the same source could otherwise return slightly different bboxes / `context_hint`s across parallel jobs, leading to visual inconsistency between tiles in one batch. `temperature=0` makes the response near-deterministic. |
| Vision pass failure handling | Fall back to current `smart_crop` + center pad + outpaint | Zero-regression guarantee — failing vision pass never makes resize worse than today. |
| Credit charging for vision pass | **Charge the user** via a second `CostHistory` row per tile (`cost_type='kv_resize_vision'`, `model='gpt-4o-mini'`). | Vision pass cost flows through the existing metering pipeline → full audit trail in DB (analytics, dispute resolution, margin tracking). User-facing credit increase: +1 credit per tile (~14–17% per batch, ~$0.01 per tile absolute). Markup is high in % terms because of `ceil()` rounding on a sub-$0.001 cost, but absolute amount is trivial and consistent with current per-call billing semantics. |
| Schema additions | One new file `vision_prepass.py` in `kv_resize/`. No new agent directory. | The pre-pass is intimately coupled to resize; lifting it into a standalone agent is premature. |
| Kill switch | `KV_RESIZE_VISION_PREPASS=true` env in api, forwarded as `use_vision_prepass: bool` field on the request | Reversible without a deploy revert if vision pass regresses generation quality or costs spike. |

## Architecture

```
Web (Next.js)                          — no changes
  ↓ POST /v1/studio/files/{file_id}/resize-exports
API (Laravel)                          — adds use_vision_prepass to payload
  ↓ ProcessKvResizeExportJob → POST {AI}/ai/kv-resize/export
AI Service (FastAPI)                   — new branch in service.py
  ↓
  vision_prepass.analyze(source_url)   — runs per job, no cache
  → returns (VisionResult | None, vision_token_usage dict)
  ↓
  decide_strategy(target, vision_result) → "fit_not_fill" | "subject_aware_crop"
  ↓
  build canvas + mask using chosen strategy
  ↓
  outpaint(canvas, mask, OUTPAINT_GUIDANCE + vision_result.context_hint)
  ↓ POST {API}/api/v1/internal/kv-resize-exports/completed
       payload now also includes vision_token_usage when vision pass ran
API
  → charge() for gpt-image-2 generation (today's behavior, unchanged)
  → charge() for gpt-4o-mini vision pass (new, only if vision_token_usage present)
  → SSE / polling → Web
```

## Changes

### ai-service

#### New: `app/agents/kv_resize/vision_prepass.py`

```python
from typing import Literal
from pydantic import BaseModel, Field

class SubjectBBox(BaseModel):
    x: float = Field(ge=0.0, le=1.0)
    y: float = Field(ge=0.0, le=1.0)
    w: float = Field(gt=0.0, le=1.0)
    h: float = Field(gt=0.0, le=1.0)

class VisionResult(BaseModel):
    subject_bbox: SubjectBBox
    content_type: Literal[
        "portrait_person", "product_shot", "scene",
        "text_heavy", "abstract", "unknown"
    ]
    has_visible_text: bool
    context_hint: str = Field(max_length=240)
```

Single function `analyze(source_image_url: str) -> tuple[VisionResult | None, dict[str, int]]`:

1. Call `gpt-4o-mini` with `temperature=0`, image_url, and a strict structured-output schema (above). System prompt: "You are analyzing a marketing key visual. Return the bounding box of the main subject in normalized [0,1] coordinates, the content type from the enum, whether visible text/logos are present, and a one-sentence `context_hint` describing setting, lighting, mood, and style suitable for guiding an AI extending the image laterally."
2. Capture token usage from the response (`prompt_tokens` and `completion_tokens` on the SDK response) into a dict shaped for the existing api metering: `{"input_text_tokens": int, "input_image_tokens": int, "output_image_tokens": 0, "output_text_tokens": int}`. For a chat model, image tokens are folded into `input_text_tokens` (api's pricing table doesn't separate them for chat models — `LLMHelper` sums input fields when computing chat-model cost).
3. Validate response against `VisionResult`. On `ValidationError` → return `(None, token_usage)`. Tokens may still be charged because the API call did occur.
4. Return `(VisionResult, token_usage)`.

Any exception before the API call returns (network, OpenAI client error) → log and return `(None, {})`. Empty token_usage tells the api side "no vision charge". Caller treats `None` result as "vision unavailable, use legacy path".

No caching layer. Each per-tile job runs its own `analyze()` call. `temperature=0` ensures bbox/`context_hint` are near-identical across parallel jobs from the same source. Worst-case duplication for an N-platform batch is N vision calls × ~$0.0005 = ~$0.0025 underlying cost. If repeat-batch cost becomes a concern later, persisting the result to a JSON column on the source-file row in api's DB is a zero-infra optimization (see Out of scope).

#### Modify: `app/agents/kv_resize/canvas.py`

Add two helpers:

```python
def subject_aware_crop(
    src: Image.Image,
    target_w: int,
    target_h: int,
    subject_bbox_norm: tuple[float, float, float, float],  # x, y, w, h in [0,1]
) -> Image.Image:
    """Crop to target aspect, centered on the subject bbox center instead
    of the geometric center. Subject bbox is intersected with the source;
    the crop window slides to keep as much of the subject visible as
    possible, clamped to image edges."""

def fit_inside_target(
    src: Image.Image,
    target_w: int,
    target_h: int,
    frame_px: int = 32,
) -> tuple[Image.Image, tuple[int, int, int, int]]:
    """Scale src to fit inside (target_w - 2*frame_px, target_h - 2*frame_px)
    preserving aspect, then paste centered on a target-sized transparent
    RGBA canvas. Returns (canvas, paste_box). Used for fit-not-fill mode."""
```

`smart_crop`, `pad_to_target`, and `build_mask` are unchanged.

Note: `fit_inside_target` is the same shape as the `place_on_target_with_frame` helper described in `2026-05-11-kv-resize-force-ai-design.md` but with a more descriptive name and reused for fit-not-fill mode. If the 2026-05-11 helper has not been landed yet, this spec absorbs that work.

#### Modify: `app/agents/kv_resize/service.py`

Add strategy decision and new branches. Existing `force_ai` flag stays; this work happens inside the `force_ai=True` arm.

```python
from app.agents.kv_resize.vision_prepass import analyze, VisionResult

_ASPECT_DELTA_THRESHOLD = 0.30

def _decide_strategy(
    src_w: int, src_h: int, target_w: int, target_h: int,
    vision: VisionResult | None,
) -> Literal["fit_not_fill", "subject_aware_crop", "legacy_smart_crop"]:
    if vision is None:
        return "legacy_smart_crop"
    if vision.has_visible_text or vision.content_type == "text_heavy":
        return "fit_not_fill"
    src_aspect = src_w / src_h
    tgt_aspect = target_w / target_h
    src_orient = "portrait" if src_aspect < 0.95 else "landscape" if src_aspect > 1.05 else "square"
    tgt_orient = "portrait" if tgt_aspect < 0.95 else "landscape" if tgt_aspect > 1.05 else "square"
    if src_orient != tgt_orient:
        return "fit_not_fill"
    delta = abs(src_aspect - tgt_aspect) / max(src_aspect, tgt_aspect)
    if delta > _ASPECT_DELTA_THRESHOLD:
        return "fit_not_fill"
    return "subject_aware_crop"
```

In `process_resize_export`, inside the `force_ai` branch, replace the current crop-then-pad logic with:

```python
vision, vision_token_usage = (
    analyze(req.source_image_url) if req.use_vision_prepass else (None, {})
)
strategy = _decide_strategy(
    source.size[0], source.size[1],
    req.target_width, req.target_height, vision,
)

if strategy == "fit_not_fill":
    canvas, paste_box = fit_inside_target(
        source, req.target_width, req.target_height, frame_px=32
    )
elif strategy == "subject_aware_crop":
    cropped = subject_aware_crop(
        source, req.target_width, req.target_height,
        (vision.subject_bbox.x, vision.subject_bbox.y,
         vision.subject_bbox.w, vision.subject_bbox.h),
    )
    canvas, paste_box = fit_inside_target(
        cropped, req.target_width, req.target_height, frame_px=32
    )
else:  # legacy_smart_crop
    cropped = smart_crop(source, req.target_width, req.target_height)
    # existing 0.95× shrink + pad_to_target path stays for this branch only
    ...

mask = build_mask(req.target_width, req.target_height, paste_box)
guidance = OUTPAINT_GUIDANCE
if vision and vision.context_hint:
    guidance = f"{OUTPAINT_GUIDANCE}\n\nSource context: {vision.context_hint}"
image_bytes, used_model, token_usage = outpaint(
    canvas, mask, guidance, provider=req.model
)
```

When posting completion to api, include `vision_token_usage` alongside the existing fields (only when it is non-empty):

```python
post_completed(
    export_id=req.export_id,
    status="done",
    image_url=image_url,
    token_usage=token_usage or None,
    ai_service_run_id=ai_service_run_id,
    model=used_model,
    vision_token_usage=vision_token_usage or None,  # NEW
    vision_model="gpt-4o-mini" if vision_token_usage else None,  # NEW
)
```

`api_client.post_completed` and the api's request validator both grow optional `vision_token_usage` and `vision_model` fields.

User-supplied `crop_window` continues to short-circuit the strategy decision entirely (explicit user crop > everything). When `crop_window` is set, vision pass is also skipped — no need to analyze the source if the user already told us where to crop.

#### Modify: `app/agents/kv_resize/request_schema.py`

Add field:
```python
use_vision_prepass: bool = True
```

### api

#### Modify: `config/services.php`

Add:
```php
'kv_resize_vision_prepass' => env('KV_RESIZE_VISION_PREPASS', true),
```

#### Modify: `app/Jobs/Studio/ProcessKvResizeExportJob.php`

Add to the outbound payload:
```php
'use_vision_prepass' => (bool) config('services.ai.kv_resize_vision_prepass'),
```

#### Modify: `app/Http/Requests/Internal/KvResizeExportCompleteRequest.php`

Add validation for two new optional fields on the completion callback:
```php
'vision_token_usage'                       => ['sometimes', 'array'],
'vision_token_usage.input_text_tokens'     => ['sometimes', 'integer', 'min:0'],
'vision_token_usage.input_image_tokens'    => ['sometimes', 'integer', 'min:0'],
'vision_token_usage.output_image_tokens'   => ['sometimes', 'integer', 'min:0'],
'vision_token_usage.output_text_tokens'    => ['sometimes', 'integer', 'min:0'],
'vision_model'                             => ['sometimes', 'string'],
```

#### Modify: `app/Http/Controllers/Api/Internal/KvResizeExportInternalController.php`

After the existing `metering->charge()` call for gpt-image-2, add a second charge for the vision pass when present:

```php
if (
    $validated['status'] === 'done'
    && !empty($validated['vision_token_usage'])
    && !empty($validated['vision_model'])
    && $aiRunId
) {
    $this->metering->charge(
        user: $user,
        workspace: $row->file->workspace,
        costType: 'kv_resize_vision',
        toolName: 'KV Resize Vision Analysis',
        batchId: "kv_resize_vision_{$row->id}_{$aiRunId}",
        model: $validated['vision_model'],
        tokenUsage: $validated['vision_token_usage'],
        brandId: $row->file->brand_id,
    );
}
```

The distinct `batchId` (note the `_vision_` infix) keeps the existing idempotency invariant intact — gen and vision are tracked as two separate `CostHistory` rows for the same export, each independently retry-safe.

#### Verify (no change needed): `app/Helpers/LLMHelper.php`

`gpt-4o-mini` already exists in the `MODELS` map with pricing:
- `input: $0.00015 / 1k tokens`
- `output: $0.0006 / 1k tokens`

It is marked `'is_active' => false`, but per the earlier metering exploration, `LLMHelper::getModelPricing()` does **not** check `is_active` — that flag only affects UI listings. Pricing lookup will work correctly without flipping the flag. Leave `is_active` as `false` to avoid surfacing `gpt-4o-mini` in any model-picker UIs as an unintended side effect.

If a future verification reveals any code path that does filter by `is_active` before pricing, swap to a model in `MODELS` that is already active (e.g., `gpt-4o`) and accept the higher per-call cost.

#### Modify: `.env.example`

Document `KV_RESIZE_VISION_PREPASS=true`.

### web

No changes.

### data-service

No changes.

## Cost & latency

### Underlying OpenAI cost

|   | Force-AI baseline (per `2026-05-11`) | After this spec |
|---|---|---|
| Vision pre-pass cost per call | $0 | ~$0.0005 (gpt-4o-mini, 1080² source, `temperature=0`) |
| Vision pre-pass latency added per job | 0s | +0.8–1.5s before generation starts |
| Per-tile generation cost | $0.04–0.19 | unchanged |
| Per-tile generation quality on cross-orientation | Subject often cropped out | Subject preserved (fit-not-fill) or correctly framed (subject-aware crop) |
| 5-tile batch underlying cost | $0.20–0.95 | $0.20–0.95 + ~$0.0025 ≈ same |
| 5-tile batch wall time (queue-paralleled) | 30–90s | 31–91s |

Without caching, the vision call cost scales linearly with batch size — but at $0.0005/call it remains <1% of total even at very large batches. Wall time is unaffected because jobs run in parallel and the vision call (~1s) is a small fraction of the generation step (~15–45s).

### User-facing credit charge (Option A billing)

Per tile, two `CostHistory` rows are written. Vision pass cost is `ceil()`-rounded to the nearest credit ($0.01) per call.

| Platform tile | Generation credits | Vision credits | Total per tile |
|---|---|---|---|
| 1280×720 YouTube | 5 | +1 | 6 |
| 1080×1080 IG Post | 6 | +1 | 7 |
| 1080×1920 IG Story / TikTok | 9 | +1 | 10 |
| 1200×627 LinkedIn | 4 | +1 | 5 |
| 1200×675 X/Twitter | 5 | +1 | 6 |

Typical 5-platform batch:

| | Today | After |
|---|---|---|
| Total credits | ~34 | ~39 |
| User-facing USD | $0.34 | $0.39 |
| Increase | — | +$0.05 (+~15%) |

The percentage increase looks large because `ceil()` rounds a sub-cent cost up to a full credit. In absolute terms the user pays an extra ~$0.01 per tile / ~$0.05 per typical batch. Margin per vision charge is ~$0.0095 (1 credit revenue – $0.0005 underlying cost) — vision pass is **net margin-positive** for the platform.

The vision-pass charge is fully visible in the user's CostHistory with `cost_type='kv_resize_vision'`, separate from generation, so it can be explained or refunded independently if support cases arise.

## Failure modes

| Failure | Behavior |
|---|---|
| Vision API timeout or 5xx | `analyze()` returns `None` → `_decide_strategy` returns `legacy_smart_crop` → today's exact behavior runs. No tile fails because of vision. |
| Vision returns invalid JSON / bbox out of range | Pydantic `ValidationError` → `analyze()` returns `None` → legacy path. Same outcome as a 5xx. |
| Source image fails to download in the vision pass | `analyze()` returns `None` → legacy path. The same source then fails to download in the main resize step too, surfacing the real error. |
| `use_vision_prepass=false` from api | Vision pass skipped entirely; strategy collapses to `legacy_smart_crop` (today's force-AI behavior verbatim). |
| Vision call adds latency on slow OpenAI response | Each job's `analyze()` is capped by the OpenAI SDK default timeout (60s). On consistent slowness, set `use_vision_prepass=false` per-environment to bypass. |

No new failure mode introduced; vision failure degrades gracefully to current behavior.

## Rollout

1. **Deploy ai-service** with vision pre-pass code. With api still sending no `use_vision_prepass` field, the default `True` in the schema kicks in — but only after step 2 is also deployed. To stage the rollout, set the schema default to `False` initially and flip it after step 2 lands.
2. **Deploy api** with `KV_RESIZE_VISION_PREPASS=true` (default) and the payload forwarding the flag.
3. **Smoke test on staging:**
   - 1080×1920 portrait → 1080×1080 square (was: top/bottom slabs lost). Confirm subject preserved.
   - 1080×1920 portrait → 1280×720 landscape (was: 68% of source discarded). Confirm fit-not-fill kicks in; subject is intact in the center; AI extends scene to the sides.
   - 1920×1080 landscape → 1080×1080 square (same-orientation, moderate delta). Confirm subject-aware crop centers on subject if off-center.
   - 1080×1080 square → 640×640 square (low delta). Confirm subject-aware crop runs (cheap, equivalent to today's smart_crop unless subject is off-center).
   - Image with visible logo text → any aspect change. Confirm fit-not-fill kicks in.
4. **Cost & billing check:** after 24h of staging traffic:
   - OpenAI dashboard usage delta for `gpt-4o-mini`: should match the count of `CostHistory` rows with `cost_type='kv_resize_vision'` (×~$0.0005 each).
   - `CostHistory` rows: every successful resize should produce exactly 2 rows (one `kv_resize_export`, one `kv_resize_vision`) sharing the same export_id in their `batch_identifier`.
   - Latency p50 delta < 1.5s.
5. **Rollback paths (any of the below, no code revert):**
   - Per-batch: webhook caller passes `use_vision_prepass: false`.
   - Per-environment: `KV_RESIZE_VISION_PREPASS=false` in api `.env`, restart queue worker. Vision pass stops running and stops being billed; existing tiles in flight finish under the old policy.
   - Vision-specific outage: leave `KV_RESIZE_VISION_PREPASS=true`; pipeline auto-degrades on failure via the `analyze() returns None` path. No vision charge is created when token_usage is empty.

## Out of scope (future work)

- **Persisting vision results to api's DB** so repeat resize batches on the same source skip the vision call. Zero-infra (reuses Postgres). Worth doing once we measure how often the same source gets resized more than once. With Option A billing, this would also imply not double-billing for the cached pass — that policy needs a deliberate decision when this work is picked up.
- **Batch-level vision-pass aggregation** — charge once per resize batch instead of once per tile (would lower user-facing increase from +5 to +1 credit per batch, but requires shared state across job runs).
- Subject-aware crop with multi-subject detection (current vision result returns one bbox).
- Replacing the 30% aspect-delta threshold with a learned classifier.
- Per-platform frame-px tuning (square may want a thinner frame than 16:9 landscape).
- Dual-strategy generation per platform with VLM arbiter ("D" option from the brainstorm).
- Sharing one OpenAI vision call across multiple sources in a project (cross-source batching).
- Surfacing the vision result to the user (e.g. "subject detected: face, top-left") in the UI.
