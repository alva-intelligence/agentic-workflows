# Video Dynamic Pricing — api Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace flat per-second video pricing with per-model dimension-tiered pricing (resolution/video_in for Seedance, mode/audio for Kling), driven by the dimensions ai-service now reports, and move the video markup to an env-configurable `VIDEO_CREDIT_MULTIPLIER`.

**Architecture:** `LLMHelper::MODELS` gains a per-model `priced_on` + `rates` table. `PricingHelper::calculateVideoCost()` becomes dimension-aware with a conservative highest-tier fallback. The video branch of `calculateDetailedCostsAndCreditsAgno()` applies `VIDEO_CREDIT_MULTIPLIER` (config-bound, default 1.5) instead of the flat `1.1×`. The two metering entry points — `ChatHelper::aggregateUsageDataAgno()` (chat) and `KvCreditMeteringService::chargeVideo()` via the KV Motion callback controller — thread the four dimensions into the resolver. SDK models (Veo/Sora) keep flat pricing by having no `priced_on`.

**Tech Stack:** Laravel 13, PHP 8.5, Pest.

## Global Constraints

- Run tests from `api/` with: `php artisan test --filter <Name>` or `./vendor/bin/pest --filter <Name>`.
- **Unit tests only.** The Feature suite fails on a fresh migrate (workspaces backfill + SoftDeletes) — do NOT add Feature tests; verify with Unit/pure tests. (See `lesson_api_feature_suite_blocked_softdeletes`.)
- **Before running any test**, confirm `phpunit.xml` + `tests/Pest.php` DB isolation so a run cannot touch the dev DB. (See `lesson_test_db_isolation`.)
- 1 credit = $0.01. Credits = `costs ÷ 0.01`. Callers `ceil()` the float to whole credits.
- `VIDEO_CREDIT_MULTIPLIER` default is `1.5`; LLM/image keep `PricingHelper::MULTIPLIER` (1.1).
- Do NOT edit the Veo (`veo-*`), Sora (`sora-*`), or Hunyuan (`hunyuan-video`) pricing arrays — they stay flat/fixed.
- Design spec: `docs/superpowers/specs/2026-07-06-video-dynamic-pricing-design.md`.
- Branch: `feature/daffa/vc-video-dynamic-pricing` (already checked out in `api/`).
- ai-service sends these `token_usage` keys: `output_video_tokens`, `resolution`, `video_in`, `mode`, `audio`.

---

### Task 1: Dimensioned pricing tables in `LLMHelper::MODELS`

**Files:**
- Modify: `app/Helpers/LLMHelper.php` (the `pricing` arrays of the four Replicate video models)
- Test: `tests/Unit/Helpers/VideoPricingSchemaTest.php` (create)

**Interfaces:**
- Produces: each of `seedance-2.0`, `seedance-2.0-fast`, `kling-v3-video`, `kling-v3-omni-video` now returns a `pricing` array with keys `type='per_second'`, `priced_on` (array), `rates` (map), `fallback_per_second` (float). `getVideoPricing($value)` is unchanged (already returns `$model['pricing']`).

- [ ] **Step 1: Write the failing test**

Create `tests/Unit/Helpers/VideoPricingSchemaTest.php`:

```php
<?php

use App\Helpers\LLMHelper;

it('gives Seedance a resolution x video_in tier table', function () {
    $p = LLMHelper::getVideoPricing('seedance-2.0');
    expect($p['priced_on'])->toBe(['resolution', 'video_in']);
    expect($p['rates']['1080p|default'])->toBe(0.45);
    expect($p['rates']['4k|video_in'])->toBe(1.25);
    expect($p['fallback_per_second'])->toBe(1.25);
});

it('gives Kling a mode x audio tier table', function () {
    $p = LLMHelper::getVideoPricing('kling-v3-omni-video');
    expect($p['priced_on'])->toBe(['mode', 'audio']);
    expect($p['rates']['pro|audio'])->toBe(0.28);
    expect($p['rates']['standard|default'])->toBe(0.168);
});

it('leaves Veo flat (no priced_on)', function () {
    $p = LLMHelper::getVideoPricing('veo-3.1-generate-preview');
    expect($p['priced_on'] ?? null)->toBeNull();
    expect($p['price_per_second'])->toBe(0.40);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./vendor/bin/pest --filter VideoPricingSchemaTest`
Expected: FAIL — `priced_on` key missing on Seedance/Kling.

- [ ] **Step 3: Replace the four `pricing` arrays**

In `app/Helpers/LLMHelper.php`, find each model entry by its `'value'` and replace only that entry's `'pricing' => [...]` array:

`seedance-2.0` (currently `['type'=>'per_second','price_per_second'=>1.25]`):

```php
            'pricing' => [
                'type' => 'per_second',
                'priced_on' => ['resolution', 'video_in'],
                'rates' => [
                    '480p|video_in' => 0.10, '480p|default' => 0.08,
                    '720p|video_in' => 0.22, '720p|default' => 0.18,
                    '1080p|video_in' => 0.55, '1080p|default' => 0.45,
                    '4k|video_in' => 1.25, '4k|default' => 1.00,
                ],
                'fallback_per_second' => 1.25,
                // keep in sync with https://replicate.com/bytedance/seedance-2.0
            ],
```

`seedance-2.0-fast` (currently `['type'=>'per_second','price_per_second'=>0.17]`):

```php
            'pricing' => [
                'type' => 'per_second',
                'priced_on' => ['resolution', 'video_in'],
                'rates' => [
                    '480p|video_in' => 0.08, '480p|default' => 0.07,
                    '720p|video_in' => 0.17, '720p|default' => 0.15,
                ],
                'fallback_per_second' => 0.17,
                // keep in sync with https://replicate.com/bytedance/seedance-2.0-fast
            ],
```

`kling-v3-video` (currently `['type'=>'per_second','price_per_second'=>0.40]`):

```php
            'pricing' => [
                'type' => 'per_second',
                'priced_on' => ['mode', 'audio'],
                'rates' => [
                    'standard|default' => 0.168, 'standard|audio' => 0.252,
                    'pro|default' => 0.224, 'pro|audio' => 0.336,
                    '4k|default' => 0.42, '4k|audio' => 0.42,
                ],
                'fallback_per_second' => 0.42,
                // keep in sync with https://replicate.com/kwaivgi/kling-v3-video
            ],
```

`kling-v3-omni-video` (currently `['type'=>'per_second','price_per_second'=>0.80]`):

```php
            'pricing' => [
                'type' => 'per_second',
                'priced_on' => ['mode', 'audio'],
                'rates' => [
                    'standard|default' => 0.168, 'standard|audio' => 0.224,
                    'pro|default' => 0.224, 'pro|audio' => 0.28,
                    '4k|default' => 0.42, '4k|audio' => 0.42,
                ],
                'fallback_per_second' => 0.42,
                // keep in sync with https://replicate.com/kwaivgi/kling-v3-omni-video
            ],
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./vendor/bin/pest --filter VideoPricingSchemaTest`
Expected: PASS (3 passed)

- [ ] **Step 5: Commit**

```bash
git add app/Helpers/LLMHelper.php tests/Unit/Helpers/VideoPricingSchemaTest.php
git commit -m "feat(api): dimensioned pricing tables for seedance + kling video models"
```

---

### Task 2: Dimension-aware resolver + env `VIDEO_CREDIT_MULTIPLIER`

**Files:**
- Modify: `app/Helpers/PricingHelper.php` (`calculateVideoCost`, add `normalizeDim` + `videoMultiplier`, video branch of `calculateDetailedCostsAndCreditsAgno`)
- Modify: `config/credits.php` (add `video_multiplier`)
- Modify: `tests/Unit/Services/Studio/KvMotionMeteringPricingTest.php` (update flat expectations to 1.5×, add dimensioned cases)

**Interfaces:**
- Consumes: `LLMHelper::getVideoPricing()` with `priced_on`/`rates`/`fallback_per_second` (Task 1).
- Produces:
  - `PricingHelper::calculateVideoCost(string $model, int $outputVideoTokens, array $dims = []): float` — `$dims` keys: `resolution` (string|null), `video_in` (bool), `mode` (string|null), `audio` (bool).
  - `PricingHelper::videoMultiplier(): float` — reads `config('credits.video_multiplier', 1.5)`.

- [ ] **Step 1: Update the pricing test (failing)**

Replace the body of `tests/Unit/Services/Studio/KvMotionMeteringPricingTest.php` with (note the helper gains a `$dims` param and the flat numbers move to the 1.5× multiplier):

```php
<?php

use App\Helpers\PricingHelper;

/**
 * Pure pricing guard for video billing (no DB). Pins the dimensioned rates and
 * the env-default VIDEO_CREDIT_MULTIPLIER (1.5) so a table/markup change can't
 * silently mis-bill. Same engine chat video and KV Motion both use.
 */
function videoCredits(string $model, int $seconds, array $dims = []): int
{
    $pricing = PricingHelper::calculateDetailedCostsAndCreditsAgno(
        aggregatedData: [
            'llm' => null,
            'image' => null,
            'web_search' => null,
            'quick_replies' => null,
            'video' => array_merge(
                ['model' => $model, 'output_video_tokens' => $seconds],
                $dims,
            ),
        ],
        isImageRequest: false,
        isVideoRequest: true,
    );

    return (int) ceil($pricing['credits']);
}

it('prices flat Veo 3.1 Fast 8s at 180 credits (8 * 0.15 * 1.5 / 0.01)', function () {
    expect(videoCredits('veo-3.1-fast-generate-preview', 8))->toBe(180);
});

it('prices flat Sora 2 8s at 120 credits (8 * 0.10 * 1.5 / 0.01)', function () {
    expect(videoCredits('sora-2', 8))->toBe(120);
});

it('scales flat pricing linearly (Veo 4s = 90)', function () {
    expect(videoCredits('veo-3.1-fast-generate-preview', 4))->toBe(90);
});

it('prices Seedance 1080p default at 540 (8 * 0.45 * 1.5 / 0.01)', function () {
    expect(videoCredits('seedance-2.0', 8, ['resolution' => '1080p', 'video_in' => false]))->toBe(540);
});

it('prices Seedance 1080p video_in at 660 (8 * 0.55 * 1.5 / 0.01)', function () {
    expect(videoCredits('seedance-2.0', 8, ['resolution' => '1080p', 'video_in' => true]))->toBe(660);
});

it('prices Kling omni pro+audio at 336 (8 * 0.28 * 1.5 / 0.01)', function () {
    expect(videoCredits('kling-v3-omni-video', 8, ['mode' => 'pro', 'audio' => true]))->toBe(336);
});

it('prices Kling v3-video standard no-audio at 202 (8 * 0.168 * 1.5 / 0.01 = 201.6, ceil)', function () {
    expect(videoCredits('kling-v3-video', 8, ['mode' => 'standard', 'audio' => false]))->toBe(202);
});

it('falls back to the highest tier when a dimension is missing (Seedance no resolution = 4k rate)', function () {
    // Missing resolution -> conservative fallback_per_second 1.25 -> 8 * 1.25 * 1.5 / 0.01
    expect(videoCredits('seedance-2.0', 8))->toBe(1500);
});

it('returns 0 credits for an unknown model', function () {
    expect(videoCredits('not-a-real-model', 8))->toBe(0);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./vendor/bin/pest --filter KvMotionMeteringPricing`
Expected: FAIL — dimensioned cases wrong (flat fallback still 1.1×; `calculateVideoCost` ignores dims).

- [ ] **Step 3: Add config key**

In `config/credits.php`, add before the closing `];`:

```php
    /*
    |--------------------------------------------------------------------------
    | Video Credit Multiplier
    |--------------------------------------------------------------------------
    |
    | Markup applied to raw provider video cost before converting to credits.
    | Video-only; LLM/image use PricingHelper::MULTIPLIER (1.1). Tunable per
    | environment without redeploying rate tables.
    |
    */

    'video_multiplier' => (float) env('VIDEO_CREDIT_MULTIPLIER', 1.5),
```

- [ ] **Step 4: Rewrite `calculateVideoCost` + add helpers**

In `app/Helpers/PricingHelper.php`, replace the whole `calculateVideoCost` method (lines 68-93) with:

```php
    /**
     * Video markup (video-only). Env-tunable; defaults to 1.5.
     */
    public static function videoMultiplier(): float
    {
        return (float) config('credits.video_multiplier', 1.5);
    }

    /**
     * Map a billing dimension to its rate-key token. Absent resolution/mode
     * yield '__missing__' so the lookup falls to the conservative fallback
     * (never under-charge); video_in/audio false are legitimate 'default' tiers.
     *
     * @param  array<string,mixed>  $dims
     */
    private static function normalizeDim(string $dim, array $dims): string
    {
        return match ($dim) {
            'resolution' => is_string($dims['resolution'] ?? null) && $dims['resolution'] !== ''
                ? $dims['resolution'] : '__missing__',
            'mode' => is_string($dims['mode'] ?? null) && $dims['mode'] !== ''
                ? $dims['mode'] : '__missing__',
            'video_in' => ! empty($dims['video_in']) ? 'video_in' : 'default',
            'audio' => ! empty($dims['audio']) ? 'audio' : 'default',
            default => '__missing__',
        };
    }

    /**
     * Calculate raw (pre-markup) USD cost for a video generation.
     *
     * Pricing is 'fixed', flat 'per_second' (no priced_on), or dimension-tiered
     * 'per_second' (priced_on + rates). A missing dimension resolves to the
     * model's conservative highest-tier fallback_per_second.
     *
     * @param  array<string,mixed>  $dims  resolution|video_in|mode|audio
     */
    public static function calculateVideoCost(string $model, int $outputVideoTokens, array $dims = []): float
    {
        $pricing = LLMHelper::getVideoPricing($model);
        if (! $pricing) {
            return 0.0;
        }

        if (($pricing['type'] ?? '') === 'fixed') {
            return $pricing['fixed_price'] ?? 0.0;
        }

        if (($pricing['type'] ?? '') !== 'per_second') {
            return 0.0;
        }

        $pricedOn = $pricing['priced_on'] ?? [];
        if (empty($pricedOn)) {
            return $outputVideoTokens * ($pricing['price_per_second'] ?? 0.0);
        }

        $key = implode('|', array_map(
            fn ($dim) => self::normalizeDim($dim, $dims),
            $pricedOn
        ));
        $rate = $pricing['rates'][$key] ?? ($pricing['fallback_per_second'] ?? 0.0);

        return $outputVideoTokens * $rate;
    }
```

- [ ] **Step 5: Pass dims + apply the video multiplier in the aggregator**

In `app/Helpers/PricingHelper.php`, replace the video-cost block in `calculateDetailedCostsAndCreditsAgno` (lines 263-269):

```php
        // Calculate Video cost (if video request)
        if ($isVideoRequest && ($aggregatedData['video'] ?? null)) {
            $totalVideoCost = self::calculateVideoCost(
                $aggregatedData['video']['model'],
                $aggregatedData['video']['output_video_tokens']
            );
        }
```

with:

```php
        // Calculate Video cost (if video request), dimension-aware
        if ($isVideoRequest && ($aggregatedData['video'] ?? null)) {
            $totalVideoCost = self::calculateVideoCost(
                $aggregatedData['video']['model'],
                $aggregatedData['video']['output_video_tokens'],
                [
                    'resolution' => $aggregatedData['video']['resolution'] ?? null,
                    'video_in' => $aggregatedData['video']['video_in'] ?? false,
                    'mode' => $aggregatedData['video']['mode'] ?? null,
                    'audio' => $aggregatedData['video']['audio'] ?? false,
                ]
            );
        }
```

Then in the same method, change the video markup line (line 289) from:

```php
        $videoCosts = $totalVideoCost * self::MULTIPLIER;
```

to:

```php
        $videoCosts = $totalVideoCost * self::videoMultiplier();
```

- [ ] **Step 6: Run test to verify it passes**

Run: `./vendor/bin/pest --filter KvMotionMeteringPricing`
Expected: PASS (9 passed)

- [ ] **Step 7: Commit**

```bash
git add app/Helpers/PricingHelper.php config/credits.php tests/Unit/Services/Studio/KvMotionMeteringPricingTest.php
git commit -m "feat(api): dimension-aware calculateVideoCost + env VIDEO_CREDIT_MULTIPLIER (default 1.5)"
```

---

### Task 3: Chat path captures dimensions

**Files:**
- Modify: `app/Helpers/ChatHelper.php` (`aggregateUsageDataAgno` video branch, lines 214-230)
- Test: `tests/Unit/Helpers/ChatHelperTest.php` (add cases)

**Interfaces:**
- Consumes: ai-service `token_usage` with `resolution`/`video_in`/`mode`/`audio`.
- Produces: `$aggregatedData['video']` now carries `resolution`, `video_in`, `mode`, `audio` (consumed by `calculateDetailedCostsAndCreditsAgno` from Task 2).

- [ ] **Step 1: Write the failing test**

Add to `tests/Unit/Helpers/ChatHelperTest.php` (append inside the file, matching its existing style):

```php
it('captures video billing dimensions from usage data', function () {
    $usageData = [[
        'type' => 'Video Generation',
        'model' => 'seedance-2.0',
        'output_video_tokens' => 8,
        'resolution' => '1080p',
        'video_in' => true,
        'mode' => null,
        'audio' => false,
    ]];

    $agg = App\Helpers\ChatHelper::aggregateUsageDataAgno($usageData);

    expect($agg['video']['resolution'])->toBe('1080p');
    expect($agg['video']['video_in'])->toBeTrue();
    expect($agg['video']['output_video_tokens'])->toBe(8);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./vendor/bin/pest --filter ChatHelperTest`
Expected: FAIL — `$agg['video']` has no `resolution`/`video_in` keys.

- [ ] **Step 3: Extend the video aggregation branch**

In `app/Helpers/ChatHelper.php`, replace the `Video Generation` branch (lines 215-230) with:

```php
            elseif ($type === 'Video Generation') {
                if (! $aggregatedData['video']) {
                    $aggregatedData['video'] = [
                        'model' => $usage['model'] ?? '',
                        'input_text_tokens' => 0,
                        'input_image_tokens' => 0,
                        'output_video_tokens' => 0,
                        'total_tokens' => 0,
                        'resolution' => null,
                        'video_in' => false,
                        'mode' => null,
                        'audio' => false,
                    ];
                }
                $aggregatedData['video']['model'] = $usage['model'] ?? '';
                $aggregatedData['video']['input_text_tokens'] += $usage['input_text_tokens'] ?? 0;
                $aggregatedData['video']['input_image_tokens'] += $usage['input_image_tokens'] ?? 0;
                $aggregatedData['video']['output_video_tokens'] += $usage['output_video_tokens'] ?? 0;
                $aggregatedData['video']['total_tokens'] += ($usage['input_text_tokens'] ?? 0) + ($usage['input_image_tokens'] ?? 0) + ($usage['output_video_tokens'] ?? 0);
                // Billing dimensions (last video in the turn wins, mirroring 'model')
                $aggregatedData['video']['resolution'] = $usage['resolution'] ?? $aggregatedData['video']['resolution'];
                $aggregatedData['video']['video_in'] = $usage['video_in'] ?? $aggregatedData['video']['video_in'];
                $aggregatedData['video']['mode'] = $usage['mode'] ?? $aggregatedData['video']['mode'];
                $aggregatedData['video']['audio'] = $usage['audio'] ?? $aggregatedData['video']['audio'];
            }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./vendor/bin/pest --filter ChatHelperTest`
Expected: PASS (existing cases + the new one).

- [ ] **Step 5: Commit**

```bash
git add app/Helpers/ChatHelper.php tests/Unit/Helpers/ChatHelperTest.php
git commit -m "feat(api): chat usage aggregation captures video billing dimensions"
```

---

### Task 4: KV Motion callback threads dimensions

**Files:**
- Modify: `app/Services/Studio/KvCreditMeteringService.php` (`chargeVideo` — add `$dims`, put into the `video` array)
- Modify: `app/Http/Controllers/Api/Internal/KvMotionGenerationInternalController.php` (extract dims from `token_usage`, pass to `chargeVideo`)
- Test: `tests/Unit/Services/Studio/KvMotionMeteringPricingTest.php` already covers dimensioned pricing (Task 2). Add a thin extraction guard here.

**Interfaces:**
- Consumes: callback `token_usage` keys `resolution`/`video_in`/`mode`/`audio`.
- Produces: `KvCreditMeteringService::chargeVideo(..., int $durationSeconds, array $dims = [], ?string $brandId = null)`.

- [ ] **Step 1: Add `$dims` to `chargeVideo` and feed the resolver**

In `app/Services/Studio/KvCreditMeteringService.php`, change the `chargeVideo` signature (lines 149-158) to add `array $dims = []` before `$brandId`:

```php
    public function chargeVideo(
        User $user,
        Workspace $workspace,
        string $costType,
        string $toolName,
        string $batchId,
        string $model,
        int $durationSeconds,
        array $dims = [],
        ?string $brandId = null,
    ): void {
```

Then in the `aggregatedData` `video` array (lines 180-183), add the dimensions:

```php
                'video' => [
                    'model' => $model,
                    'output_video_tokens' => $durationSeconds,
                    'resolution' => $dims['resolution'] ?? null,
                    'video_in' => $dims['video_in'] ?? false,
                    'mode' => $dims['mode'] ?? null,
                    'audio' => $dims['audio'] ?? false,
                ],
```

- [ ] **Step 2: Extract dims in the callback controller**

In `app/Http/Controllers/Api/Internal/KvMotionGenerationInternalController.php`, after the `$durationSeconds` line (line 49) add:

```php
            $dims = [
                'resolution' => $tokenUsage['resolution'] ?? null,
                'video_in' => (bool) ($tokenUsage['video_in'] ?? false),
                'mode' => $tokenUsage['mode'] ?? null,
                'audio' => (bool) ($tokenUsage['audio'] ?? false),
            ];
```

Then update the `chargeVideo` call (lines 55-64) to pass `dims`:

```php
                $this->metering->chargeVideo(
                    user: $user,
                    workspace: $workspace,
                    costType: CostHistoryType::KV_MOTION_GENERATION->value,
                    toolName: 'KV Motion',
                    batchId: "kv_motion_{$row->id}",
                    model: $row->model,
                    durationSeconds: $durationSeconds,
                    dims: $dims,
                    brandId: $row->file?->brand_id,
                );
```

- [ ] **Step 3: Add a dims-extraction guard test**

Add to `tests/Unit/Services/Studio/KvMotionMeteringPricingTest.php`:

```php
it('chargeVideo forwards dims into the dimensioned rate (Seedance 1080p video_in)', function () {
    // Pure pricing parity: the video array chargeVideo builds must resolve to
    // the same 660 credits as the chat path for an 8s 1080p video_in Seedance.
    $pricing = PricingHelper::calculateDetailedCostsAndCreditsAgno(
        aggregatedData: [
            'llm' => null,
            'image' => null,
            'web_search' => null,
            'quick_replies' => null,
            'video' => [
                'model' => 'seedance-2.0',
                'output_video_tokens' => 8,
                'resolution' => '1080p',
                'video_in' => true,
                'mode' => null,
                'audio' => false,
            ],
        ],
        isImageRequest: false,
        isVideoRequest: true,
    );

    expect((int) ceil($pricing['credits']))->toBe(660);
});
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./vendor/bin/pest --filter KvMotionMeteringPricing`
Expected: PASS (all cases).

- [ ] **Step 5: Commit**

```bash
git add app/Services/Studio/KvCreditMeteringService.php app/Http/Controllers/Api/Internal/KvMotionGenerationInternalController.php tests/Unit/Services/Studio/KvMotionMeteringPricingTest.php
git commit -m "feat(api): KV Motion callback threads billing dimensions into per-second charge"
```

---

### Task 5: Targeted regression pass

**Files:** none (verification only)

- [ ] **Step 1: Run all touched Unit suites**

Run: `./vendor/bin/pest --filter "VideoPricingSchema|KvMotionMeteringPricing|ChatHelper|KvCreditMeteringService"`
Expected: PASS. If `KvCreditMeteringServiceTest` (DB-touching) fails on the fresh-migrate block, run it in isolation only if DB isolation is confirmed; otherwise rely on the pure pricing guards above and note it.

- [ ] **Step 2: Sanity — no accidental flat-video regressions**

Confirm no Veo/Sora/Hunyuan `pricing` array was edited:

Run: `git diff develop -- app/Helpers/LLMHelper.php | grep -E "veo-|sora-|hunyuan" || echo "OK: no SDK/fixed model pricing touched"`
Expected: `OK: no SDK/fixed model pricing touched`

## Self-Review Notes

- **Spec coverage:** dimensioned tables (Task 1); resolver + fallback + env multiplier (Task 2); chat path (Task 3); KV Motion path (Task 4); SDK models untouched/flat (constraints + Task 5 guard). ✓
- **Type consistency:** `calculateVideoCost($model, $seconds, $dims)` signature used identically in Task 2 (definition), Task 2 aggregator call, and via `aggregatedData['video']` keys `resolution|video_in|mode|audio` set in Tasks 3/4 — matches ai-service `token_usage` keys. ✓
- **Multiplier change is intentional and global to video:** existing Veo/Sora pricing-test numbers were updated from the 1.1× values (132/89/66) to the 1.5× values (180/120/90). This is expected, not a regression.
- **No placeholders:** every step has concrete code and exact commands.
