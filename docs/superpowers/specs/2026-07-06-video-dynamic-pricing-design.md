# Dimension-Aware Video Pricing — Design

> **Status:** design (approved in brainstorming 2026-07-06)
> **Author:** daffa
> **Type:** pricing/credit-metering refactor
> **Services:** api, ai-service (no web)

## Overview

Video credit deduction currently charges a **single flat `$/second` per model**
(`LLMHelper::MODELS[...]['pricing']`), regardless of the parameters that actually
drive the provider's cost. This over- and under-charges because real providers price
video on **per-model dimensions** — Seedance on `resolution × video_in`, Kling on
`mode × audio` — not one rate.

This design replaces the flat rate with a **dimension-aware resolver**: each model
declares which dimensions it prices on (`priced_on`) and a `rates` table keyed on those
dimensions. ai-service reports the dimensions it already computes; the API resolver looks
them up. A dedicated, **env-configurable** `VIDEO_CREDIT_MULTIPLIER` (default `1.5`)
replaces the flat `1.1×` markup for video only.

Pricing is **decoupled from routing**: the resolver only sees `(model, duration, dims)`,
so Replicate-routed models and direct-SDK models (Veo, Sora) use the identical schema and
code path. The dimension machinery exists only for the Replicate models where the real
mispricing lives; SDK models stay flat.

**Scope guards:** no web changes; no backfill of historical `CostHistory` rows (new
generations only); Veo/Sora routing stays direct-SDK (only their pricing config is
touched, and it stays flat).

## Problem: what's mispriced today

Current registry rates vs. real provider tiers (per second of output):

| Model | Registry (flat) | Real range | Problem |
|---|---|---|---|
| seedance-2.0 | $1.25/s | $0.08–$1.25 (res × video_in) | flat = the 4k-video_in worst case → typical 1080p over-charged ~2.8× |
| seedance-2.0-fast | $0.17/s | $0.07–$0.17 (res × video_in) | mid-tier flat |
| kling-v3-video | $0.40/s + `output_video_tokens=1` | $0.168–$0.336 (mode × audio) | duration ignored **and** flat rate wrong |
| kling-v3-omni-video | $0.80/s + `output_video_tokens=1` | $0.168–$0.28 (mode × audio) | duration ignored; ~3–4× over-charge |
| sora-2 / sora-2-pro | $0.10 / $0.30 | 720p-locked in code | correct today (Sora only outputs 720p) |
| veo-3.1 / -fast | $0.40 / $0.15 | flat, audio bundled | correct |
| hunyuan-video | $1.80 fixed | compute-metered (~$0.64/run, varies) | not deterministic; `is_active:false` |

Two of these are outright bugs: Seedance's flat rate is the worst-case tier, and Kling
reports `output_video_tokens = 1` (a fixed unit) while Replicate bills Kling **per second
of output** — so today an 8s and a 4s Kling clip cost the same.

## Rate tables (source of truth)

USD per second of output video. Keep each in sync with the cited pricing page.

### Replicate — dimensioned

**seedance-2.0** — `priced_on: [resolution, video_in]`
(sync: https://replicate.com/bytedance/seedance-2.0)

| resolution | video_in | default |
|---|---|---|
| 480p | 0.10 | 0.08 |
| 720p | 0.22 | 0.18 |
| 1080p | 0.55 | 0.45 |
| 4k | 1.25 | 1.00 |

**seedance-2.0-fast** — `priced_on: [resolution, video_in]` (480/720 only)
(sync: https://replicate.com/bytedance/seedance-2.0-fast)

| resolution | video_in | default |
|---|---|---|
| 480p | 0.08 | 0.07 |
| 720p | 0.17 | 0.15 |

**kling-v3-video** — `priced_on: [mode, audio]`
(sync: https://replicate.com/kwaivgi/kling-v3-video)

| mode | default | audio |
|---|---|---|
| standard | 0.168 | 0.252 |
| pro | 0.224 | 0.336 |
| 4k | 0.42 | 0.42 |

**kling-v3-omni-video** — `priced_on: [mode, audio]`
(sync: https://replicate.com/kwaivgi/kling-v3-omni-video)

| mode | default | audio |
|---|---|---|
| standard | 0.168 | 0.224 |
| pro | 0.224 | 0.28 |
| 4k | 0.42 | 0.42 |

### Direct SDK — flat

- **veo-3.1** flat 0.40 · **veo-3.1-fast** flat 0.15 (audio bundled) — `priced_on: []`
- **sora-2** flat 0.10 · **sora-2-pro** flat 0.30 (720p-locked) — `priced_on: []`
- **hunyuan-video** — `type: fixed`, deferred (compute-metered, inactive)

## Pricing schema (`LLMHelper::MODELS[...]['pricing']`)

```php
'pricing' => [
    'type'                => 'per_second',        // 'per_second' | 'fixed'
    'priced_on'           => ['resolution', 'video_in'],  // [] = flat
    'price_per_second'    => 0.40,                 // used only when priced_on == []
    'rates'               => [                      // used when priced_on non-empty
        '480p|video_in' => 0.10, '480p|default' => 0.08,
        '720p|video_in' => 0.22, '720p|default' => 0.18,
        '1080p|video_in'=> 0.55, '1080p|default'=> 0.45,
        '4k|video_in'   => 1.25, '4k|default'   => 1.00,
    ],
    'fallback_per_second' => 1.25,                 // = highest tier (conservative)
    // keep in sync with https://replicate.com/bytedance/seedance-2.0
],
```

- `rates` keys are the model's `priced_on` dimensions joined by `|`, in `priced_on` order.
- `fallback_per_second` is the **highest** rate for that model, so a missing/unknown
  dimension over-charges slightly rather than under-charges.
- `fixed` models keep `'fixed_price' => 1.80`.

## Resolver (`PricingHelper`)

```php
public static function calculateVideoCost(string $model, int $seconds, array $dims = []): float
{
    $p = LLMHelper::getVideoPricing($model);
    if (! $p) return 0.0;
    if (($p['type'] ?? '') === 'fixed') return $p['fixed_price'] ?? 0.0;
    if (empty($p['priced_on'])) return $seconds * ($p['price_per_second'] ?? 0.0);

    $key  = implode('|', array_map(
        fn ($d) => self::normalizeDim($d, $dims),   // dim => key-token
        $p['priced_on']
    ));
    $rate = $p['rates'][$key] ?? ($p['fallback_per_second'] ?? 0.0);
    return $seconds * $rate;
}
```

**Dimension → key-token normalization** (`normalizeDim`):

| dimension | token |
|---|---|
| `resolution` | `"480p"`/`"720p"`/`"1024p"`/`"1080p"`/`"4k"` (default `"720p"` if absent) |
| `video_in` | `"video_in"` if truthy else `"default"` |
| `mode` | `"standard"`/`"pro"`/`"4k"` (default `"standard"`) |
| `audio` | `"audio"` if truthy else `"default"` |

**Backward-compatible:** callers passing no `$dims` still work — tiered models resolve to
`fallback_per_second`, so nothing crashes and nothing under-charges.

## Markup: env-configurable `VIDEO_CREDIT_MULTIPLIER`

- New config key `config('credits.video_multiplier')` → `env('VIDEO_CREDIT_MULTIPLIER', 1.5)`.
- Applies to **video only**, replacing the flat `1.1×` in
  `PricingHelper::calculateDetailedCostsAndCreditsAgno()` for the video branch.
  LLM/image costs keep `PricingHelper::MULTIPLIER` (1.1).
- Credits conversion unchanged: `credits = costs ÷ 0.01`.
- Formula: `credits = duration × rate(dims) × VIDEO_CREDIT_MULTIPLIER ÷ 0.01`.

**Impact at default 1.5× (8-second examples):**

| Example | Real cost | Today | New @1.5× | Δ |
|---|---|---|---|---|
| Seedance 1080p default (typical) | $3.60 | 1,100 cr | 540 cr | ↓ |
| Seedance 4k video_in (worst) | $10.00 | 1,100 cr | 1,500 cr | ↑ |
| Kling omni pro+audio | $2.24 | 88 cr | 336 cr | ↑↑ |
| Kling v3-video standard no-audio | $1.34 | 88 cr | 202 cr | ↑ |

> **Open decision (confirm before deploy):** `1.5` is the written default. Because
> accuracy makes typical Seedance charges drop and Kling charges rise (Kling was
> duration-insensitive due to the `output_video_tokens=1` bug), the final multiplier is a
> product/pricing-policy call. It is one env var to change — no redeploy of rate tables.

## ai-service changes (Replicate branches only)

Add the dimensions each model prices on to the returned `token_usage`. All values are
**already computed** in `generate_video.py`:

```python
token_usage = {
    "type": "Video Generation",
    "model": video_model,
    "input_text_tokens": 0,
    "input_image_tokens": 0,
    "output_video_tokens": length,      # duration in seconds
    # NEW — billing dimensions (send what applies; harmless extras ignored downstream)
    "resolution": seedance_resolution,  # "480p".."4k"
    "video_in": bool(reference_videos), # seedance video_in tier
    "mode": mode,                       # kling "standard"/"pro"
    "audio": input.get("generate_audio", False),
}
```

- **Seedance branch** ([bytedance]): add `resolution` (`seedance_resolution`) and
  `video_in` (`bool(reference_videos)`). Already sends `output_video_tokens = length`.
- **Kling branch** ([kuaishou]): **required fix** — change
  `output_video_tokens` from `1` → `length` (duration). Add `mode` (the computed `mode`
  var) and `audio` (final `input["generate_audio"]`). For omni with a reference video,
  `generate_audio` is forced `False`, so it correctly resolves to the `default`
  (no-audio) tier.
- **Veo / Sora branches: no change.** They price flat.

## API aggregation — thread dims to the resolver

Both metering paths must carry the four dims from `token_usage` into
`calculateVideoCost($model, $seconds, $dims)`:

- **AskFRND chat:** `ChatHelper::aggregateUsageDataAgno()` captures `resolution`,
  `video_in`, `mode`, `audio` into `aggregatedData['video']`;
  `calculateDetailedCostsAndCreditsAgno()` passes them to the resolver and applies
  `VIDEO_CREDIT_MULTIPLIER`.
- **KV Motion:** the internal completion callback reads the dims from `token_usage`;
  `KvCreditMeteringService::chargeVideo()` gains the dims and forwards them. Since KV
  Motion validates `resolution` at request time, it falls back to the stored request
  value if ai-service omits it.

## Testing

Unit tests only (the api Feature suite is blocked on fresh-migrate per
`lesson_api_feature_suite_blocked_softdeletes`):

- **Resolver** — each shape: `fixed`; flat (`priced_on == []`); `resolution × video_in`
  (Seedance); `mode × audio` (Kling); missing-dim → conservative `fallback_per_second`.
- **Worked examples** (at 1.5×): Seedance 8s 1080p `default` = 540 cr, 4k `video_in` =
  1,500 cr; Kling omni 8s pro+audio = 336 cr.
- **Env multiplier** — resolver/aggregation honor `config('credits.video_multiplier')`.
- **ai-service** — `token_usage` carries the dims per branch; **Kling reports
  `output_video_tokens = length`** (regression guard for the `=1` bug).

## Forward-looking notes (out of scope now, YAGNI)

- **Higher-res Veo/Sora:** if Veo offers 4k or Sora unlocks 1024/1080 output, flip that
  model's `priced_on` to `[resolution]` and add its tier table — the resolver already
  supports it and both branches already have `resolution`/`size` in scope.
- **Hunyuan revival:** it is compute-metered (`predict_time × hardware`), not
  per-output-second, so it cannot be priced deterministically. If reactivated, it needs
  actual-cost readback from the Replicate prediction, not a tier table.
- **Pre-flight estimate:** the tiered calc is deterministic pre-render, so a projected-
  credits estimate is a trivial follow-up. Deferred.

## Files touched

**ai-service**
- `app/tools/generate_video.py` — Seedance & Kling `token_usage` dims; Kling
  `output_video_tokens` fix.

**api**
- `app/Helpers/LLMHelper.php` — per-model `pricing` schema (`priced_on`, `rates`,
  `fallback_per_second`).
- `app/Helpers/PricingHelper.php` — `calculateVideoCost(dims)`, `normalizeDim`,
  `VIDEO_CREDIT_MULTIPLIER` in the video branch of
  `calculateDetailedCostsAndCreditsAgno()`.
- `config/credits.php` — `video_multiplier` env binding.
- `app/Helpers/ChatHelper.php` — capture dims in `aggregateUsageDataAgno()`.
- `app/Services/Studio/KvCreditMeteringService.php` + KV Motion internal callback
  controller — forward dims to the resolver.
- Unit tests under `tests/Unit`.
