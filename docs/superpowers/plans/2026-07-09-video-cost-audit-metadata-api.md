# Video Cost-Parameter Audit Trail — api Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist a `video_params` JSON object (billing dimensions + rate snapshot) on every video charge so any charge is explainable via ad-hoc lookup and stays reproducible after rates change.

**Architecture:** A shared `PricingHelper::videoBillingMetadata()` (backed by a new `resolveVideoUnitRate()` extracted from `calculateVideoCost`) builds the object. It's stored on `cost_histories.video_params` (the audit home, both paths) and carried on `user_chat_log_usages.video_params` for the chat path (the batching job copies it onto the ledger row). Motion writes it directly in `chargeVideo`.

**Tech Stack:** Laravel 13, PHP 8.5, PostgreSQL (jsonb), Pest.

## Global Constraints

- Builds on branch `feature/daffa/vc-video-dynamic-pricing` (both video-pricing + the dims already exist there). Confirm you're on it: `git -C api branch --show-current`.
- **Unit tests only, run by direct file path** — `./vendor/bin/pest tests/Unit/...Test.php`, NOT `--filter` (triggers a pre-existing Feature-suite collection error). The Feature suite is blocked on fresh-migrate — do NOT add Feature tests. (See `lesson_api_feature_suite_blocked_softdeletes`.)
- Before any test run, confirm `phpunit.xml` + `tests/Pest.php` DB isolation is intact. (See `lesson_test_db_isolation`.)
- Column name is **`video_params`** on both tables (jsonb, nullable). No backfill. Video-only population.
- `video_params` shape (exact keys): `type`, `pricing_type` (`per_second`|`fixed`), `provider`, `model`, `resolution`, `video_in`, `mode`, `audio`, `duration_seconds`, `unit_rate`, `multiplier`.
- `unit_rate` = the provider's raw per-second rate (or fixed price) BEFORE the multiplier.
- Do NOT touch `kv_motion_generations`. api only.
- Design spec: `docs/superpowers/specs/2026-07-09-video-cost-audit-metadata-design.md`.
- All paths below are under `api/`. Run commands from `/Users/alva.e202511001/Desktop/work/frndos-agentic/api`.

---

### Task 1: `resolveVideoUnitRate` + `videoBillingMetadata` in PricingHelper

**Files:**
- Modify: `app/Helpers/PricingHelper.php` (refactor `calculateVideoCost` at lines 114-141; add two methods)
- Test: `tests/Unit/Helpers/VideoBillingMetadataTest.php` (create)

**Interfaces:**
- Consumes: existing `PricingHelper::normalizeDim`, `videoMultiplier`, `LLMHelper::getVideoPricing`, `LLMHelper::getModelProvider`.
- Produces:
  - `PricingHelper::resolveVideoUnitRate(string $model, array $dims = []): ?float`
  - `PricingHelper::videoBillingMetadata(string $model, int $seconds, array $dims = []): array`

- [ ] **Step 1: Write the failing test**

Create `tests/Unit/Helpers/VideoBillingMetadataTest.php`:

```php
<?php

use App\Helpers\PricingHelper;

it('resolves the tiered per-second rate for Seedance', function () {
    expect(PricingHelper::resolveVideoUnitRate('seedance-2.0', ['resolution' => '1080p', 'video_in' => false]))->toBe(0.45);
    expect(PricingHelper::resolveVideoUnitRate('seedance-2.0', ['resolution' => '1080p', 'video_in' => true]))->toBe(0.55);
});

it('resolves the fixed price for Hunyuan and null for unknown', function () {
    expect(PricingHelper::resolveVideoUnitRate('hunyuan-video'))->toBe(1.80);
    expect(PricingHelper::resolveVideoUnitRate('not-a-real-model'))->toBeNull();
});

it('falls back to the highest tier when a dimension is missing', function () {
    expect(PricingHelper::resolveVideoUnitRate('seedance-2.0'))->toBe(1.25);
});

it('builds full video_params for a tiered per_second charge', function () {
    $meta = PricingHelper::videoBillingMetadata('seedance-2.0', 8, ['resolution' => '1080p', 'video_in' => false]);
    expect($meta['type'])->toBe('video');
    expect($meta['pricing_type'])->toBe('per_second');
    expect($meta['provider'])->toBe('bytedance');
    expect($meta['model'])->toBe('seedance-2.0');
    expect($meta['resolution'])->toBe('1080p');
    expect($meta['video_in'])->toBeFalse();
    expect($meta['mode'])->toBeNull();
    expect($meta['audio'])->toBeFalse();
    expect($meta['duration_seconds'])->toBe(8);
    expect($meta['unit_rate'])->toBe(0.45);
    expect($meta['multiplier'])->toBe(PricingHelper::videoMultiplier());
});

it('marks Hunyuan as fixed pricing', function () {
    $meta = PricingHelper::videoBillingMetadata('hunyuan-video', 8);
    expect($meta['pricing_type'])->toBe('fixed');
    expect($meta['unit_rate'])->toBe(1.80);
});

it('returns [] for an unknown model', function () {
    expect(PricingHelper::videoBillingMetadata('not-a-real-model', 8))->toBe([]);
});

it('reproduces the engine credits from the snapshot (per_second)', function () {
    $dims = ['resolution' => '1080p', 'video_in' => true];
    $meta = PricingHelper::videoBillingMetadata('seedance-2.0', 8, $dims);
    $reproduced = (int) ceil($meta['unit_rate'] * $meta['duration_seconds'] * $meta['multiplier'] / 0.01);

    $engine = PricingHelper::calculateDetailedCostsAndCreditsAgno(
        aggregatedData: [
            'llm' => null, 'image' => null, 'web_search' => null, 'quick_replies' => null,
            'video' => array_merge(['model' => 'seedance-2.0', 'output_video_tokens' => 8], $dims),
        ],
        isImageRequest: false,
        isVideoRequest: true,
    );

    expect($reproduced)->toBe((int) ceil($engine['credits']));
});

it('reproduces the engine credits from the snapshot (fixed, no duration factor)', function () {
    $meta = PricingHelper::videoBillingMetadata('hunyuan-video', 8);
    $reproduced = (int) ceil($meta['unit_rate'] * $meta['multiplier'] / 0.01);

    $engine = PricingHelper::calculateDetailedCostsAndCreditsAgno(
        aggregatedData: [
            'llm' => null, 'image' => null, 'web_search' => null, 'quick_replies' => null,
            'video' => ['model' => 'hunyuan-video', 'output_video_tokens' => 8],
        ],
        isImageRequest: false,
        isVideoRequest: true,
    );

    expect($reproduced)->toBe((int) ceil($engine['credits']));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./vendor/bin/pest tests/Unit/Helpers/VideoBillingMetadataTest.php`
Expected: FAIL — `Call to undefined method ...resolveVideoUnitRate()`.

- [ ] **Step 3: Add `resolveVideoUnitRate` and refactor `calculateVideoCost`**

In `app/Helpers/PricingHelper.php`, replace the whole `calculateVideoCost` method (lines 114-141) with:

```php
    /**
     * Resolve the per-second rate (or fixed price) for a video model + dims.
     * Mirrors calculateVideoCost's tier selection: the fixed price for 'fixed'
     * models; the tiered rate for dimensioned per_second models (conservative
     * fallback_per_second when a dimension is missing); the flat rate for
     * untiered per_second models; null for an unknown/invalid model.
     *
     * @param  array<string,mixed>  $dims  resolution|video_in|mode|audio
     */
    public static function resolveVideoUnitRate(string $model, array $dims = []): ?float
    {
        $pricing = LLMHelper::getVideoPricing($model);
        if (! $pricing) {
            return null;
        }

        if (($pricing['type'] ?? '') === 'fixed') {
            return $pricing['fixed_price'] ?? 0.0;
        }

        if (($pricing['type'] ?? '') !== 'per_second') {
            return null;
        }

        $pricedOn = $pricing['priced_on'] ?? [];
        if (empty($pricedOn)) {
            return $pricing['price_per_second'] ?? 0.0;
        }

        $key = implode('|', array_map(
            fn ($dim) => self::normalizeDim($dim, $dims),
            $pricedOn
        ));

        return $pricing['rates'][$key] ?? ($pricing['fallback_per_second'] ?? 0.0);
    }

    /**
     * Calculate raw (pre-markup) USD cost for a video generation.
     *
     * @param  array<string,mixed>  $dims  resolution|video_in|mode|audio
     */
    public static function calculateVideoCost(string $model, int $outputVideoTokens, array $dims = []): float
    {
        $pricing = LLMHelper::getVideoPricing($model);
        if (! $pricing) {
            return 0.0;
        }

        $rate = self::resolveVideoUnitRate($model, $dims);
        if ($rate === null) {
            return 0.0;
        }

        // Fixed models bill a flat price; per_second models bill rate × seconds.
        if (($pricing['type'] ?? '') === 'fixed') {
            return $rate;
        }

        return $outputVideoTokens * $rate;
    }

    /**
     * Build the video_params audit object for a video charge: the billing
     * dimensions plus a rate snapshot (unit_rate + multiplier + duration) that
     * reproduces the charge even after rate tables change. Returns [] for an
     * unknown model (no metadata to record → the column stays null).
     *
     * @param  array<string,mixed>  $dims  resolution|video_in|mode|audio
     * @return array<string,mixed>
     */
    public static function videoBillingMetadata(string $model, int $seconds, array $dims = []): array
    {
        $pricing = LLMHelper::getVideoPricing($model);
        $rate = self::resolveVideoUnitRate($model, $dims);
        if (! $pricing || $rate === null) {
            return [];
        }

        return [
            'type' => 'video',
            'pricing_type' => $pricing['type'] ?? 'per_second',
            'provider' => LLMHelper::getModelProvider($model),
            'model' => $model,
            'resolution' => $dims['resolution'] ?? null,
            'video_in' => (bool) ($dims['video_in'] ?? false),
            'mode' => $dims['mode'] ?? null,
            'audio' => (bool) ($dims['audio'] ?? false),
            'duration_seconds' => $seconds,
            'unit_rate' => $rate,
            'multiplier' => self::videoMultiplier(),
        ];
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./vendor/bin/pest tests/Unit/Helpers/VideoBillingMetadataTest.php tests/Unit/Services/Studio/KvMotionMeteringPricingTest.php`
Expected: PASS (new file green AND the existing pricing test still green — the `calculateVideoCost` refactor is behavior-preserving).

- [ ] **Step 5: Commit**

```bash
git add app/Helpers/PricingHelper.php tests/Unit/Helpers/VideoBillingMetadataTest.php
git commit -m "feat(api): PricingHelper::videoBillingMetadata + resolveVideoUnitRate for cost audit"
```

---

### Task 2: `video_params` columns + model casts

**Files:**
- Create: `database/migrations/2026_07_09_000100_add_video_params_to_cost_histories_table.php`
- Create: `database/migrations/2026_07_09_000200_add_video_params_to_user_chat_log_usages_table.php`
- Modify: `app/Models/CostHistory.php` (fillable + add `casts()`)
- Modify: `app/Models/UserChatLogUsage.php` (fillable + `casts()`)

**Interfaces:**
- Produces: `cost_histories.video_params` and `user_chat_log_usages.video_params` (jsonb, nullable), both cast to `array` on their models.

- [ ] **Step 1: Create the cost_histories migration**

Create `database/migrations/2026_07_09_000100_add_video_params_to_cost_histories_table.php`:

```php
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('cost_histories', function (Blueprint $table) {
            $table->jsonb('video_params')->nullable()->after('chat_features');
        });
    }

    public function down(): void
    {
        Schema::table('cost_histories', function (Blueprint $table) {
            $table->dropColumn('video_params');
        });
    }
};
```

- [ ] **Step 2: Create the user_chat_log_usages migration**

Create `database/migrations/2026_07_09_000200_add_video_params_to_user_chat_log_usages_table.php`:

```php
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('user_chat_log_usages', function (Blueprint $table) {
            $table->jsonb('video_params')->nullable()->after('video_total_tokens');
        });
    }

    public function down(): void
    {
        Schema::table('user_chat_log_usages', function (Blueprint $table) {
            $table->dropColumn('video_params');
        });
    }
};
```

- [ ] **Step 3: Add fillable + cast on CostHistory**

In `app/Models/CostHistory.php`, add `'video_params',` to the `$fillable` array immediately after `'is_from_extra_credit',` (line 41). Then add a `casts()` method right after the `$fillable` array closes (after line 42):

```php
    protected function casts(): array
    {
        return [
            'video_params' => 'array',
        ];
    }
```

- [ ] **Step 4: Add fillable + cast on UserChatLogUsage**

In `app/Models/UserChatLogUsage.php`:
- Add `'video_params',` to `$fillable` immediately after `'video_total_tokens',` (line 53).
- Add `'video_params' => 'array',` to the array returned by the `casts()` method (after the `'video_total_tokens' => 'integer',` line).

- [ ] **Step 5: Run the migrations and verify columns + syntax**

Run:
```bash
php -l database/migrations/2026_07_09_000100_add_video_params_to_cost_histories_table.php
php -l database/migrations/2026_07_09_000200_add_video_params_to_user_chat_log_usages_table.php
php artisan migrate --no-interaction
php artisan tinker --execute="echo Schema::hasColumn('cost_histories','video_params')?'cost_histories OK\n':'MISSING\n'; echo Schema::hasColumn('user_chat_log_usages','video_params')?'user_chat_log_usages OK\n':'MISSING\n';"
```
Expected: no syntax errors; migrations run; both echo `OK`. (Both columns are additive + nullable — safe on the dev DB, no data change.)

- [ ] **Step 6: Commit**

```bash
git add database/migrations/2026_07_09_000100_add_video_params_to_cost_histories_table.php database/migrations/2026_07_09_000200_add_video_params_to_user_chat_log_usages_table.php app/Models/CostHistory.php app/Models/UserChatLogUsage.php
git commit -m "feat(api): add video_params jsonb column to cost_histories + user_chat_log_usages"
```

---

### Task 3: Chat carrier — store `video_params` on the usage row

**Files:**
- Modify: `app/Helpers/ChatHelper.php` (`buildTokenUsageRecordAgno` video block, lines 306-312)
- Test: `tests/Unit/Helpers/ChatHelperVideoDimsTest.php` (add a case — this pure file exists from the pricing work)

**Interfaces:**
- Consumes: `PricingHelper::videoBillingMetadata` (Task 1). `PricingHelper` is already imported in `ChatHelper`.
- Produces: `buildTokenUsageRecordAgno` returns a `$recordData` array whose `video_params` key holds the metadata object (or is absent when not a video request).

- [ ] **Step 1: Write the failing test**

Add to `tests/Unit/Helpers/ChatHelperVideoDimsTest.php`:

```php
it('stores video_params metadata in the usage record for a video request', function () {
    $agg = ChatHelper::aggregateUsageDataAgno([[
        'type' => 'Video Generation',
        'model' => 'seedance-2.0',
        'output_video_tokens' => 8,
        'resolution' => '1080p',
        'video_in' => false,
        'mode' => null,
        'audio' => false,
    ]]);

    $record = ChatHelper::buildTokenUsageRecordAgno($agg, 'u1', 'w1', 't1', 1, 2);

    expect($record['video_params']['type'])->toBe('video');
    expect($record['video_params']['model'])->toBe('seedance-2.0');
    expect($record['video_params']['resolution'])->toBe('1080p');
    expect($record['video_params']['unit_rate'])->toBe(0.45);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./vendor/bin/pest tests/Unit/Helpers/ChatHelperVideoDimsTest.php`
Expected: FAIL — `Undefined array key "video_params"`.

- [ ] **Step 3: Store video_params in buildTokenUsageRecordAgno**

In `app/Helpers/ChatHelper.php`, replace the video block (lines 306-312):

```php
        // Add Video Generation data if present
        if ($aggregatedData['video'] ?? null) {
            $recordData['video_model'] = $aggregatedData['video']['model'];
            $recordData['video_input_tokens'] = $aggregatedData['video']['input_text_tokens'] + $aggregatedData['video']['input_image_tokens'];
            $recordData['video_output_tokens'] = $aggregatedData['video']['output_video_tokens'];
            $recordData['video_total_tokens'] = $aggregatedData['video']['total_tokens'];
        }
```

with:

```php
        // Add Video Generation data if present
        if ($aggregatedData['video'] ?? null) {
            $recordData['video_model'] = $aggregatedData['video']['model'];
            $recordData['video_input_tokens'] = $aggregatedData['video']['input_text_tokens'] + $aggregatedData['video']['input_image_tokens'];
            $recordData['video_output_tokens'] = $aggregatedData['video']['output_video_tokens'];
            $recordData['video_total_tokens'] = $aggregatedData['video']['total_tokens'];
            $recordData['video_params'] = PricingHelper::videoBillingMetadata(
                $aggregatedData['video']['model'],
                $aggregatedData['video']['output_video_tokens'],
                [
                    'resolution' => $aggregatedData['video']['resolution'] ?? null,
                    'video_in' => $aggregatedData['video']['video_in'] ?? false,
                    'mode' => $aggregatedData['video']['mode'] ?? null,
                    'audio' => $aggregatedData['video']['audio'] ?? false,
                ]
            ) ?: null;
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./vendor/bin/pest tests/Unit/Helpers/ChatHelperVideoDimsTest.php`
Expected: PASS (existing cases + the new one).

- [ ] **Step 5: Commit**

```bash
git add app/Helpers/ChatHelper.php tests/Unit/Helpers/ChatHelperVideoDimsTest.php
git commit -m "feat(api): carry video_params on user_chat_log_usages via buildTokenUsageRecordAgno"
```

---

### Task 4: Write `video_params` onto the cost_histories ledger (both paths)

**Files:**
- Modify: `app/Jobs/ProcessChatLogBatchingJob.php` (`createCostHistoryForBatch`, the `CostHistory::create` call)
- Modify: `app/Services/Studio/KvCreditMeteringService.php` (`chargeVideo`, the `CostHistory::create` call)

**Interfaces:**
- Consumes: `user_chat_log_usages.video_params` (Task 3), `cost_histories.video_params` (Task 2), `PricingHelper::videoBillingMetadata` (Task 1), `chargeVideo`'s `array $dims` param (from the pricing work).

**Note on testing:** these two edits write to `cost_histories` (DB), which the blocked Feature suite can't exercise. The *value's* correctness is fully proven by Task 1's pure tests and Task 3's carrier test; these are mechanical field additions to existing `CostHistory::create` calls whose surrounding logic is unchanged. Verify by reading the diff + a runtime e2e (generate a video, inspect the `cost_histories.video_params` row).

- [ ] **Step 1: Copy video_params from the batch's video log (chat path)**

In `app/Jobs/ProcessChatLogBatchingJob.php`, inside `createCostHistoryForBatch`, immediately before the `$costHistory = CostHistory::create([` line, add:

```php
            // Video charges are dedicated (1:1) batches; carry the audit params
            // from the batch's video log onto the ledger row. Null for non-video.
            $videoParams = $batch->chatLogUsages()
                ->whereNotNull('video_params')
                ->first()?->video_params;
```

Then add this line inside the `CostHistory::create([...])` array, immediately after `'chat_batch_log_count' => $logCount,`:

```php
                'video_params' => $videoParams,
```

- [ ] **Step 2: Write video_params directly in chargeVideo (motion path)**

In `app/Services/Studio/KvCreditMeteringService.php`, inside `chargeVideo`'s `CostHistory::create([...])` array, add this line immediately after `'chat_features' => 'KV Generator',`:

```php
                    'video_params' => PricingHelper::videoBillingMetadata($model, $durationSeconds, $dims) ?: null,
```

- [ ] **Step 3: Syntax check**

Run:
```bash
php -l app/Jobs/ProcessChatLogBatchingJob.php
php -l app/Services/Studio/KvCreditMeteringService.php
```
Expected: no syntax errors in either.

- [ ] **Step 4: Regression — pricing + metadata suites still green**

Run: `./vendor/bin/pest tests/Unit/Helpers/VideoBillingMetadataTest.php tests/Unit/Helpers/ChatHelperVideoDimsTest.php tests/Unit/Services/Studio/KvMotionMeteringPricingTest.php`
Expected: PASS (no behavior changed in the pricing path).

- [ ] **Step 5: Commit**

```bash
git add app/Jobs/ProcessChatLogBatchingJob.php app/Services/Studio/KvCreditMeteringService.php
git commit -m "feat(api): persist video_params on cost_histories for chat + motion charges"
```

---

## Self-Review Notes

- **Spec coverage:** `video_params` columns (Task 2), shared builder + resolver (Task 1), chat carrier (Task 3), ledger write for both paths (Task 4), no `kv_motion_generations` / no backfill / api-only (constraints). ✓
- **Type consistency:** `videoBillingMetadata(string, int, array): array` and `resolveVideoUnitRate(string, array): ?float` are defined in Task 1 and consumed identically in Tasks 3 & 4. The `video_params` key names match the spec shape and the model casts (`array`). ✓
- **Testability honesty:** Tasks 1 & 3 are pure-unit-tested; Task 4's DB writes are mechanical and rely on Task 1's value correctness + a runtime e2e (called out explicitly, not hidden). ✓
- **No placeholders:** every step has concrete code and exact commands. ✓
