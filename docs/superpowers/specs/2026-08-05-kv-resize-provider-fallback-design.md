# KV Resize — Gemini fallback when OpenAI credit is exhausted

**Date:** 2026-08-05
**Author:** daffa
**Services:** ai-service (only)
**Status:** approved

## Problem

KV Resize exports fail when the OpenAI organization balance hits zero:

```
WARNING app.agents.kv_resize.vision_prepass: vision_prepass: API call failed for
data-url(len=44379): Error code: 429 - {'error': {'message': 'You have no credits
remaining...', 'type': 'insufficient_quota', 'code': 'credit_balance_exhausted'}}
```

Topping the account up is not currently an option for the team, so the pipeline
needs to degrade to a provider we still have budget on rather than fail.

The prepass warning is the visible symptom, but it is not the failure. KV Resize
calls OpenAI **twice**:

| Step | Call | Behavior on quota error |
|------|------|------------------------|
| Vision prepass | `gpt-4o-mini` chat completions, `vision_prepass.analyze` | Degrades silently — returns `None`, strategy falls back to `legacy_smart_crop` |
| Image edit | `gpt-image-2` `POST /v1/images/edits`, `outpaint_image.outpaint` / `reframe` | Raises — export row marked `failed` |

`credit_balance_exhausted` is org-wide, so both fail together. A fallback wired
only into the prepass would quiet the log and change nothing for the user. Both
call sites must fail over.

## Scope

ai-service only. Both KV Resize OpenAI call sites gain a Gemini fallback.

Explicitly **not** in scope: a service-wide OpenAI fallback for chat, KV
generate, or craft. Those are separate call sites with different provider
mappings; this spec keeps the blast radius to KV Resize.

No api or web changes. Gemini image models are already priced in the api
registry (`LLMHelper.php`), so metering keeps working as long as ai-service
reports the model it actually used.

## Design

### 1. Failure classifier

New `app/utils/provider_errors.py`:

```python
def is_openai_quota_error(status: int | None, body: str) -> bool
```

Returns True for the errors OpenAI credit will never resolve on its own:

- `429` with `insufficient_quota` or `credit_balance_exhausted`
- `401` with `invalid_api_key`

Returns False for `429 rate_limit_exceeded`, 5xx, and gateway timeouts (520,
524) — those clear on retry and keep today's backoff behavior.

Pure function over `(status, body)` so it is unit-testable without a network
call, and usable from both the SDK path (prepass, which sees an exception) and
the raw-`requests` path (image edit, which sees a `Response`).

### 2. Vision prepass fallback

`app/agents/kv_resize/vision_prepass.py`:

- `gpt-4o-mini` stays primary, unchanged.
- On a quota error, retry once against `gemini-3.5-flash` through google-genai,
  using `response_mime_type="application/json"` plus the existing
  `_RESPONSE_SCHEMA`. The `VisionResult` contract out is identical, so
  `_decide_strategy` needs no changes.
- Map Gemini `usage_metadata` (`prompt_token_count` / `candidates_token_count`)
  into the existing `token_usage` shape.
- `analyze()` returns a third value: the model actually used.

`service.py:287` currently hardcodes `vision_model="gpt-4o-mini"`. It must
forward the returned model instead, or fallback runs will be priced against the
wrong model.

Non-quota failures (validation errors, malformed JSON, network) keep today's
behavior — return `None` and let the strategy degrade. Those would fail the same
way on Gemini.

### 3. Image edit fallback

`app/tools/outpaint_image.py` is already dispatcher-shaped: `outpaint()` and
`reframe()` are thin wrappers over `outpaint_with_openai_mask()` and
`reframe_with_openai()`. The fallback mirrors `app/tools/upscale_image.py`'s
primary→fallback dispatch.

**Stop retrying quota errors.** `_TRANSIENT_STATUS` includes 429, so
`_call_openai_edits` currently burns 2s + 4s + 8s of backoff on an error that
will never clear. Classify the body before sleeping; on a quota match raise a
typed `OpenAIQuotaExhausted` immediately.

**The mask problem.** Gemini accepts no mask, but `outpaint`'s contract is that
source pixels survive byte-identical. Re-create that guarantee locally:

1. Send Gemini the already-padded canvas plus the fill guidance.
2. Resize the result to the exact target dimensions.
3. Re-paste the original source region over the output.

The paste region is derived from the mask rather than threaded through the
signature. `build_mask` paints white (255) everywhere and black (0) over
`paste_box` (`canvas.py:60`), so `ImageOps.invert(mask).getbbox()` returns
exactly `paste_box`. `outpaint()`'s signature stays unchanged and the preserved
region provably matches what the alpha mask protected.

`reframe` and `ai_restructure` are mask-free by design — those swap the provider
only, with no re-paste.

**Model:** `gemini-3-pro-image-preview`, chosen over flash for its stronger text
re-rendering, which the `ai_restructure` strategy depends on.

**If Gemini also fails,** re-raise the *original* OpenAI exception so the failed
export still reports the real cause (credit exhaustion) rather than a misleading
downstream Gemini error.

### 4. Configuration

`KV_RESIZE_IMAGE_PROVIDER` in `app/utils/config.py`:

| Value | Behavior |
|-------|----------|
| `auto` (default) | OpenAI first, Gemini on quota/auth errors |
| `openai` | OpenAI only — today's behavior, no fallback |
| `gemini` | Skip OpenAI entirely |

`gemini` is the manual switch to flip while the balance is out, avoiding a
wasted OpenAI round-trip per export.

### 5. Metering and observability

- Fallback runs report `gemini-3-pro-image-preview` / `gemini-3.5-flash` as the
  model, with Gemini's `usage_metadata` mapped into the existing token-usage
  shape. Both models exist in the api pricing registry
  (`LLMHelper.php:1106` onward), so `KvCreditMeteringService::charge` prices them
  with no api change. Reporting a model name absent from that registry makes
  `getModelPricing` return null and exports silently become free — the model
  string must match the registry value exactly.
- A WARNING log naming the trigger error and the provider being switched to.
- `capture_ai_generation(provider="gemini", span_name="kv_resize_*_fallback")`
  so PostHog cost attribution survives the switch.

No change to the `post_completed` payload shape, the export row, or the UI. The
user sees a working export; the degradation is visible to the team only.

## Testing

Unit tests, no network:

1. Classifier truth table — quota 429 vs. plain rate-limit 429 vs. 5xx vs. 401.
2. Prepass falls back on a quota error, and does **not** fall back on a
   `ValidationError`.
3. `invert(mask).getbbox()` equals the `paste_box` that built the mask.
4. Re-paste leaves the preserved region byte-identical to the source canvas.
5. Fallback output is exactly the target dimensions for both outpaint and
   reframe.
6. The real model string reaches `post_completed` for both the image and vision
   fields.

Fixtures are small PIL images built in-test; the Gemini client is mocked. No
live API call in CI.

## Risks and limits

**Seam quality.** The re-paste guarantees the source region is untouched, but
Gemini's fill will not blend at the boundary as cleanly as gpt-image-2's native
masked inpainting. Fallback exports will be visibly a notch worse. This is the
intended trade — a rougher export beats a failed one — but it is a real quality
drop, not a transparent swap.

**Aspect control.** `gemini-3-pro-image-preview` returns from a fixed set of
aspect ratios rather than arbitrary W×H. The plan is to pin
`image_config.aspect_ratio` to the nearest supported ratio and resize/crop to the
exact target, but the precise behavior must be verified against the live API
during implementation rather than assumed.

**Cost per export changes.** While the fallback is active, users are charged at
Gemini pro-image rates instead of gpt-image-2 rates. Worth watching if an outage
runs long.
