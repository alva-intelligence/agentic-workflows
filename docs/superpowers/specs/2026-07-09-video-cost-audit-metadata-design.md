# Video Cost-Parameter Audit Trail — Design

> **Status:** design (approved in brainstorming 2026-07-09)
> **Author:** daffa
> **Type:** cost-audit / observability schema addition
> **Services:** api only
> **Depends on:** dimension-aware video pricing (`2026-07-06-video-dynamic-pricing-design.md`)

## Overview

Video charges currently record *how much* (`cost_histories.amount` / `system_credit`)
but not *why* — the billing dimensions (resolution, video_in, mode, audio) that
selected the tier, and the rate that was applied, are computed, used to price, then
discarded. This makes a past charge impossible to explain, especially after a rate
table or the `VIDEO_CREDIT_MULTIPLIER` changes.

This design persists, per video charge, a **`video_params` JSON object** capturing the
dimensions plus a **rate snapshot**, so any charge is explainable by ad-hoc lookup and
stays reproducible forever.

**Primary use:** ad-hoc debugging / audit ("why did this charge cost N credits?") — not
recurring BI. This is why a flexible `jsonb` blob is preferred over typed columns.

## Problem

Two independent paths produce video charges, both landing in `cost_histories`:

- **Chat video:** `user_chat_log_usages` (per response) → `ProcessChatLogBatchingJob`
  (batched) → `cost_histories`.
- **KV Motion:** `kv_motion_generations` → `KvCreditMeteringService::chargeVideo()` →
  `cost_histories`.

The dimensions flow through `ChatHelper::aggregateUsageDataAgno` (chat) and the motion
callback, but are never stored. `cost_histories` — where the *actual charged* credits
live — has no dimension or rate data. `user_chat_log_usages` holds only
`video_model` + token counts (and a pre-batch cost *estimate*, not the final charge).

## Decisions (locked in brainstorming)

- **Storage:** `jsonb` blob (ad-hoc audit, future-proof, no rewrite when fields change).
- **Naming:** the column is `video_params` on **both** tables (explicit, consistent).
- **Scope:** `cost_histories` (audit home) + `user_chat_log_usages` (chat carrier) only.
  `kv_motion_generations` is **not** touched — motion audit is fully covered by
  `cost_histories.video_params`, and that table already stores model/duration/ratio/
  generate_audio.
- **Fields:** dimensions + rate snapshot (see shape below). Not `credits`/`amount` —
  those are already columns; `video_params` holds the *inputs*.
- **Backfill:** none. `video_params` is null for pre-existing rows (their dims were
  never captured and rates have since changed — not reconstructable).
- **Services:** api only. ai-service already reports the dimensions in `token_usage`.

## `video_params` shape

```json
{
  "type": "video",
  "pricing_type": "per_second",
  "provider": "bytedance",
  "model": "seedance-2.0",
  "resolution": "1080p",
  "video_in": false,
  "mode": null,
  "audio": false,
  "duration_seconds": 8,
  "unit_rate": 0.45,
  "multiplier": 1.1
}
```

- **Dimensions** (`resolution`, `video_in`, `mode`, `audio`) — which tier was selected.
- **`pricing_type`** (`per_second` | `fixed`) — tells the auditor how to reproduce the
  charge, since the two shapes bill differently.
- **Rate snapshot** (`unit_rate`, `duration_seconds`, `multiplier`) — makes the charge
  reproducible:
  - `per_second`: `unit_rate × duration_seconds × multiplier ÷ 0.01 = system_credit`.
    `unit_rate` is the resolved per-second rate for the selected tier.
  - `fixed`: `unit_rate × multiplier ÷ 0.01 = system_credit` (duration is *not* a
    factor). `unit_rate` is the model's fixed price; `duration_seconds` is retained as
    informational (the clip length), not a cost driver.
  Raw provider USD is derivable (`unit_rate × duration_seconds` for per_second, or
  `unit_rate` for fixed) — no separate field (YAGNI; add later without a migration if
  margin dashboards appear).
- **Context** (`provider`, `model`, `type`) — self-contained; `cost_histories` has no
  model column, so this makes the row standalone.

## Schema changes

Two nullable columns, no backfill:

```php
// migration 1: cost_histories
$table->jsonb('video_params')->nullable()->after('chat_features');

// migration 2: user_chat_log_usages
$table->jsonb('video_params')->nullable()->after('video_total_tokens');
```

Cast both to `array` on their Eloquent models (`CostHistory`, `UserChatLogUsage`).

## Shared builder (DRY rate logic)

Two additions to `App\Helpers\PricingHelper`, so neither write path re-implements tier
resolution:

- **`resolveVideoUnitRate(string $model, array $dims): ?float`** — extracted from the
  existing `calculateVideoCost` (which becomes `resolveVideoUnitRate($model,$dims) ×
  $seconds`, or the fixed price). Returns the resolved per-second rate, the fixed price
  for `fixed` models, or `null` for unknown models.
- **`videoBillingMetadata(string $model, int $seconds, array $dims): array`** — assembles
  the `video_params` object using `resolveVideoUnitRate`, `videoMultiplier()`, the model's
  provider (`LLMHelper::getModelProvider($model)` / registry `model_provider`), and the
  model's `pricing.type` (→ `pricing_type` field). Returns `[]` for an unknown model
  (no metadata to record → column stays null).

`calculateVideoCost` is refactored to call `resolveVideoUnitRate` — no behavior change,
same numbers, verified by the existing `KvMotionMeteringPricingTest`.

## Data flow

**Chat path**
1. `ChatHelper::aggregateUsageDataAgno` already captures the four dims into
   `aggregatedData['video']` (from the pricing work).
2. `buildTokenUsageRecordAgno` calls
   `PricingHelper::videoBillingMetadata($model, $outputVideoTokens, $dims)` and stores the
   result on `user_chat_log_usages.video_params` (null when not a video request).
3. `ProcessChatLogBatchingJob`, when it writes the (dedicated, 1:1 for video ≥1 credit)
   `cost_histories` row, copies `video_params` from the `UserChatLogUsage` onto
   `cost_histories.video_params`.

**Motion path**
1. `KvMotionGenerationInternalController::completed` already builds `$dims` from the
   callback `token_usage`.
2. `KvCreditMeteringService::chargeVideo` calls `videoBillingMetadata($model,
   $durationSeconds, $dims)` and passes the result into the `CostHistory::create([...])`
   `video_params` field.

Non-video charges leave `video_params` null.

## Testing

Unit tests only (Feature suite is blocked on fresh-migrate — see
`lesson_api_feature_suite_blocked_softdeletes`), pure where possible:

- **`videoBillingMetadata`** — one case per pricing shape:
  - tiered (Seedance 1080p default → `unit_rate 0.45`, dims correct)
  - tiered with variant (Seedance 1080p video_in → `0.55`)
  - mode×audio (Kling omni pro+audio → `0.28`)
  - flat (sora-2 → `0.10`, no dims)
  - fixed (hunyuan → fixed price, `duration_seconds` present)
  - missing dim → conservative fallback rate
  - unknown model → `[]`
- **Reproducibility identity** — assert the metadata reproduces the engine's credits
  (guards builder ↔ resolver drift):
  - `per_second`: `ceil(unit_rate × duration × multiplier ÷ 0.01)` equals the credits
    `calculateDetailedCostsAndCreditsAgno` returns.
  - `fixed` (hunyuan): `ceil(unit_rate × multiplier ÷ 0.01)` equals it (no duration).
- **`resolveVideoUnitRate`** — returns the exact tier rate / fixed price / fallback /
  null, mirroring `calculateVideoCost`'s selection.

## Files touched (api only)

- `database/migrations/*_add_video_params_to_cost_histories_table.php` (new)
- `database/migrations/*_add_video_params_to_user_chat_log_usages_table.php` (new)
- `app/Models/CostHistory.php` — `video_params` → `array` cast
- `app/Models/UserChatLogUsage.php` — `video_params` → `array` cast
- `app/Helpers/PricingHelper.php` — `resolveVideoUnitRate`, `videoBillingMetadata`,
  refactor `calculateVideoCost`
- `app/Helpers/ChatHelper.php` — store `video_params` in `buildTokenUsageRecordAgno`
- `app/Jobs/ProcessChatLogBatchingJob.php` — copy `video_params` onto the video
  `cost_histories` row
- `app/Services/Studio/KvCreditMeteringService.php` — pass `video_params` into
  `chargeVideo`'s `CostHistory::create`
- `tests/Unit/...` — builder + resolver tests

## Out of scope (YAGNI)

- No `kv_motion_generations` columns (covered by `cost_histories.video_params`).
- No backfill of historical rows.
- No web/UI surface to display `video_params` (raw DB/audit only for now).
- No typed columns / BI aggregation support (revisit if dashboards are needed — the
  jsonb is queryable via `video_params->>'resolution'` in the meantime).
- No raw-provider-USD field (derivable from `unit_rate × duration_seconds`).
