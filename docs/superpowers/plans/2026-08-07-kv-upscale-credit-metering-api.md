# KV Upscale Credit Metering (api) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Charge credits for KV upscales, which are currently free because the charge is gated on a `token_usage` field the ai-service never sends.

**Architecture:** Upscales run on Replicate, which bills compute-seconds or output megapixels — never tokens — so the existing token-based `charge()` cannot price them. Motion hit this exact wall and solved it with `chargeVideo()`, a parallel non-token path. This adds `chargeUpscale()` against output megapixels, the unit Replicate actually bills. No ai-service change is needed: `post_completed()` already sends `width` and `height`, and `width × height` is the billable quantity.

**Tech Stack:** Laravel 13, PHP 8.5, Pest 4, PostgreSQL.

## Global Constraints

- **1 credit = $0.01** — `PricingHelper::calculateCreditsFromCosts()`, do not redefine.
- **Rate: `$0.03` per output megapixel** — clarity-pro-upscaler's published price.
- **Multiplier: `credits.upscale_multiplier`, default `1.1`**, env `UPSCALE_CREDIT_MULTIPLIER`. Mirrors `credits.video_multiplier` exactly.
- **Idempotency is by `batch_identifier`** — reuse the existing guard, never invent a second mechanism.
- **Metering must never break the callback.** Every failure path logs and returns; a billing error must not fail an upscale the user already received.
- Run `vendor/bin/pint --dirty --format agent` before every commit.
- This plan ships **against the current engine**. It must not depend on 2K/4K targets or on clarity-pro.

## Spec

`docs/superpowers/specs/2026-08-07-kv-upscale-fidelity-and-resolution-targets-design.md` § Credit metering.

## File Structure

| File | Responsibility |
|---|---|
| `config/credits.php` | Add `upscale_multiplier`. Config only. |
| `app/Helpers/PricingHelper.php` | Add `upscaleMultiplier()` and `calculateUpscaleCost()`. Pure maths, no I/O. |
| `app/Services/Studio/KvCreditMeteringService.php` | Add `chargeUpscale()`. Deduction + audit row. |
| `app/Http/Controllers/Api/Internal/KvGenerationUpscaleInternalController.php` | Call `chargeUpscale()` on completion. |
| `app/Http/Controllers/Api/Internal/KvResizeExportUpscaleInternalController.php` | Same, for the tile flow. |
| `tests/Unit/Helpers/UpscalePricingTest.php` | Pricing maths. |
| `tests/Unit/Services/KvUpscaleMeteringTest.php` | Guard behaviour. |

---

### Task 1: Upscale pricing maths

**Files:**
- Modify: `config/credits.php`
- Modify: `app/Helpers/PricingHelper.php`
- Test: `tests/Unit/Helpers/UpscalePricingTest.php`

**Interfaces:**
- Consumes: `PricingHelper::calculateCreditsFromCosts()` (existing, `$costs / 0.01`).
- Produces:
  - `PricingHelper::upscaleMultiplier(): float`
  - `PricingHelper::calculateUpscaleCost(float $outputMegapixels): float` — returns dollars, multiplier already applied.
  - `PricingHelper::UPSCALE_PRICE_PER_MEGAPIXEL: float`

- [ ] **Step 1: Write the failing test**

Create `tests/Unit/Helpers/UpscalePricingTest.php`:

```php
<?php

use App\Helpers\PricingHelper;

/**
 * Upscales run on Replicate, billed per output megapixel — not per token.
 * These values are the spec's reference table; a change here is a pricing
 * change and must be deliberate.
 */
it('prices a 2K-shaped upscale at roughly 20 credits', function () {
    // ~6 MP of model output is what a 2K target produces from a typical KV.
    $cost = PricingHelper::calculateUpscaleCost(6.0);

    expect(round(PricingHelper::calculateCreditsFromCosts($cost)))->toBe(20.0);
});

it('prices a 4K-shaped upscale at roughly 83 credits', function () {
    $cost = PricingHelper::calculateUpscaleCost(25.0);

    expect(round(PricingHelper::calculateCreditsFromCosts($cost)))->toBe(83.0);
});

it('scales linearly with megapixels', function () {
    expect(PricingHelper::calculateUpscaleCost(20.0))
        ->toBe(PricingHelper::calculateUpscaleCost(10.0) * 2);
});

it('returns zero for non-positive megapixels', function (float $mp) {
    expect(PricingHelper::calculateUpscaleCost($mp))->toBe(0.0);
})->with([0.0, -1.0]);

it('defaults the multiplier to 1.1, matching video', function () {
    expect(PricingHelper::upscaleMultiplier())->toBe(1.1);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `php artisan test --compact --filter=UpscalePricingTest`
Expected: FAIL — `Call to undefined method App\Helpers\PricingHelper::calculateUpscaleCost()`

- [ ] **Step 3: Add the config entry**

Append to the returned array in `config/credits.php`, before the closing `];`:

```php
    /*
    |--------------------------------------------------------------------------
    | Upscale Credit Multiplier
    |--------------------------------------------------------------------------
    |
    | Markup applied to raw provider upscale cost before converting to
    | credits. Upscales are billed by Replicate per output megapixel, not per
    | token, so they bypass PricingHelper::MULTIPLIER the same way video does.
    | Tunable per environment without redeploying rate tables.
    |
    */

    'upscale_multiplier' => (float) env('UPSCALE_CREDIT_MULTIPLIER', 1.1),
```

- [ ] **Step 4: Add the pricing methods**

In `app/Helpers/PricingHelper.php`, beside `videoMultiplier()`:

```php
    /**
     * Replicate's published price for clarity-pro-upscaler: $0.03 per
     * megapixel of model output. Note this is the model's output, not the
     * image we finally deliver — we may downscale afterwards, but Replicate
     * bills what it produced.
     */
    public const float UPSCALE_PRICE_PER_MEGAPIXEL = 0.03;

    public static function upscaleMultiplier(): float
    {
        // Defensive: pure unit tests have no container, so config() would
        // throw — same fallback as videoMultiplier().
        try {
            $value = config('credits.upscale_multiplier');

            return $value !== null ? (float) $value : 1.1;
        } catch (\Throwable) {
            return 1.1;
        }
    }

    /**
     * Dollar cost of an upscale, multiplier applied.
     */
    public static function calculateUpscaleCost(float $outputMegapixels): float
    {
        if ($outputMegapixels <= 0) {
            return 0.0;
        }

        return $outputMegapixels
            * self::UPSCALE_PRICE_PER_MEGAPIXEL
            * self::upscaleMultiplier();
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `php artisan test --compact --filter=UpscalePricingTest`
Expected: PASS, 5 tests.

- [ ] **Step 6: Commit**

```bash
vendor/bin/pint --dirty --format agent
git add config/credits.php app/Helpers/PricingHelper.php tests/Unit/Helpers/UpscalePricingTest.php
git commit -m "feat(api): add per-megapixel upscale pricing to PricingHelper"
```

---

### Task 2: `chargeUpscale()`

**Files:**
- Modify: `app/Services/Studio/KvCreditMeteringService.php`
- Test: `tests/Unit/Services/KvUpscaleMeteringTest.php`

**Interfaces:**
- Consumes: `PricingHelper::calculateUpscaleCost()`, `PricingHelper::calculateCreditsFromCosts()` from Task 1; `CreditService::deductCreditsWithDebt()` (existing).
- Produces: `KvCreditMeteringService::chargeUpscale(User $user, Workspace $workspace, string $costType, string $toolName, string $batchId, string $model, float $outputMegapixels, ?string $brandId = null): void`

Read `chargeVideo()` in the same file first and mirror its structure exactly — the transaction, the `UniqueConstraintViolationException` catch, and the `Throwable` catch are all load-bearing and must be reproduced, not improvised.

- [ ] **Step 1: Write the failing test**

Create `tests/Unit/Services/KvUpscaleMeteringTest.php`:

```php
<?php

use App\Models\CostHistory;
use App\Services\Studio\KvCreditMeteringService;

/**
 * Guard behaviour only — the deduction path itself is covered by the existing
 * credit test suite. What matters here is that a bad input never writes a row
 * and never throws into the internal callback.
 */
it('skips silently when megapixels are non-positive', function (float $mp) {
    $service = new KvCreditMeteringService;
    $before = CostHistory::count();

    $service->chargeUpscale(
        user: \App\Models\User::factory()->create(),
        workspace: \App\Models\Workspace::factory()->create(),
        costType: 'kv_generation_upscale',
        toolName: 'KV Upscale',
        batchId: 'batch-'.uniqid(),
        model: 'philz1337x/clarity-upscaler',
        outputMegapixels: $mp,
    );

    expect(CostHistory::count())->toBe($before);
})->with([0.0, -3.2]);

it('is idempotent on batch identifier', function () {
    $service = new KvCreditMeteringService;
    $user = \App\Models\User::factory()->create();
    $workspace = \App\Models\Workspace::factory()->create();
    $batchId = 'batch-'.uniqid();

    $args = [
        'user' => $user,
        'workspace' => $workspace,
        'costType' => 'kv_generation_upscale',
        'toolName' => 'KV Upscale',
        'batchId' => $batchId,
        'model' => 'philz1337x/clarity-upscaler',
        'outputMegapixels' => 6.0,
    ];

    $service->chargeUpscale(...$args);
    $service->chargeUpscale(...$args);

    expect(CostHistory::where('batch_identifier', $batchId)->count())->toBe(1);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `php artisan test --compact --filter=KvUpscaleMeteringTest`
Expected: FAIL — `Call to undefined method ...::chargeUpscale()`

- [ ] **Step 3: Implement `chargeUpscale()`**

Append to `KvCreditMeteringService`, after `chargeVideo()`:

```php
    /**
     * Charge a KV upscale. Priced on output megapixels because Replicate
     * bills that way — the token-based `charge()` above cannot express it,
     * which is why upscales were silently free until 2026-08-07.
     *
     * `$outputMegapixels` is the MODEL's output, not the delivered image.
     * We may downscale to an exact target afterwards; Replicate still bills
     * what it produced.
     */
    public function chargeUpscale(
        User $user,
        Workspace $workspace,
        string $costType,
        string $toolName,
        string $batchId,
        string $model,
        float $outputMegapixels,
        ?string $brandId = null,
    ): void {
        if ($outputMegapixels <= 0) {
            Log::warning('KV upscale metering skipped: non-positive megapixels', [
                'batch_id' => $batchId,
                'cost_type' => $costType,
                'user_id' => $user->id,
                'model' => $model,
            ]);

            return;
        }

        if (CostHistory::where('batch_identifier', $batchId)->exists()) {
            return;
        }

        $cost = PricingHelper::calculateUpscaleCost($outputMegapixels);
        $credits = (int) ceil(PricingHelper::calculateCreditsFromCosts($cost));

        if ($credits <= 0) {
            return;
        }

        try {
            DB::transaction(function () use (
                $user, $workspace, $brandId, $costType, $toolName,
                $batchId, $cost, $credits, $model, $outputMegapixels,
            ) {
                $deduction = $this->creditService->deductCreditsWithDebt(
                    $user,
                    $workspace,
                    $credits,
                    $batchId,
                );

                $extraCreditDrawn = $deduction['extra_credit_drawn'] ?? 0;

                CostHistory::create([
                    'user_id' => $user->id,
                    'username' => $user->name,
                    'workspace_id' => $workspace->id,
                    'brand_id' => $brandId,
                    'brand_name' => $brandId ? Brand::query()->whereKey($brandId)->value('name') : null,
                    'cost_type' => $costType,
                    'entry_type' => 'deduction',
                    'amount' => $cost,
                    'actual_credit' => $deduction['credits_deducted'],
                    'system_credit' => $credits,
                    'is_indexed' => true,
                    'is_from_extra_credit' => $extraCreditDrawn > 0,
                    'tool_name' => $toolName,
                    // Upscales bill per megapixel; record the billable
                    // quantity in the token columns for audit parity with
                    // the image and video paths.
                    'prompt_tokens' => 0,
                    'completion_tokens' => (int) round($outputMegapixels * 1_000_000),
                    'total_tokens' => (int) round($outputMegapixels * 1_000_000),
                    'batch_identifier' => $batchId,
                    'chat_features' => 'KV Generator',
                ]);
            });
        } catch (UniqueConstraintViolationException) {
            // Race-safe: another worker already wrote the same batch_identifier.
        } catch (Throwable $e) {
            Log::error('KV upscale metering charge failed', [
                'batch_id' => $batchId,
                'cost_type' => $costType,
                'user_id' => $user->id,
                'workspace_id' => $workspace->id,
                'model' => $model,
                'error' => $e->getMessage(),
                'trace' => $e->getTraceAsString(),
            ]);
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `php artisan test --compact --filter=KvUpscaleMeteringTest`
Expected: PASS, 3 tests.

> Feature tests need a scratch Postgres — SQLite cannot run these migrations
> (`DROP SEQUENCE`). Use `frnd_test` with `TELESCOPE_ENABLED=false`.

- [ ] **Step 5: Commit**

```bash
vendor/bin/pint --dirty --format agent
git add app/Services/Studio/KvCreditMeteringService.php tests/Unit/Services/KvUpscaleMeteringTest.php
git commit -m "feat(api): add chargeUpscale() megapixel-based credit metering"
```

---

### Task 3: Wire both completion callbacks

**Files:**
- Modify: `app/Http/Controllers/Api/Internal/KvGenerationUpscaleInternalController.php`
- Modify: `app/Http/Controllers/Api/Internal/KvResizeExportUpscaleInternalController.php`

**Interfaces:**
- Consumes: `chargeUpscale()` from Task 2.
- Produces: nothing further consumes this.

Read the existing `charge()` call in each controller first. It is guarded on
`! empty($validated['token_usage'])`, which is never true — that dead branch is
what this task replaces.

- [ ] **Step 1: Replace the dead token branch in the generation controller**

The existing block calls `$this->metering->charge(...)` gated on
`$aiRunId && ! empty($validated['token_usage'])`. Replace that condition and
call so it keys off dimensions instead:

```php
            // Upscales are billed by Replicate per output megapixel, never per
            // token, so the token_usage branch this used to sit behind could
            // never fire. width/height have always been sent; use them.
            $megapixels = (((int) ($validated['width'] ?? 0))
                * ((int) ($validated['height'] ?? 0))) / 1_000_000;

            if ($validated['status'] === 'done' && $megapixels > 0) {
                $this->metering->chargeUpscale(
                    user: $user,
                    workspace: $workspace,
                    costType: 'kv_generation_upscale',
                    toolName: 'KV Upscale',
                    batchId: $upscale->id,
                    model: $validated['model_version'] ?? '',
                    outputMegapixels: $megapixels,
                    brandId: $brandId,
                );
            }
```

Keep the surrounding `$user` / `$workspace` / `$brandId` resolution exactly as
the existing code already derives it — do not re-derive them differently.

`batchId` is the upscale row id: naturally unique, stable across retries, and
already the idempotency key the row is keyed on.

- [ ] **Step 2: Apply the same change to the resize-export controller**

Identical shape, with `costType: 'kv_resize_export_upscale'` and
`toolName: 'KV Tile Upscale'`.

- [ ] **Step 3: Verify no `token_usage` reference remains in either controller**

Run: `grep -rn "token_usage" app/Http/Controllers/Api/Internal/KvGenerationUpscaleInternalController.php app/Http/Controllers/Api/Internal/KvResizeExportUpscaleInternalController.php`
Expected: no output.

Leave `token_usage` in the two `*CompleteRequest` validation rules — it is
nullable, harmless, and removing it is an unrelated wire-contract change.

- [ ] **Step 4: Run the upscale test suites**

Run: `php artisan test --compact --filter=Upscale`
Expected: PASS, no regressions.

- [ ] **Step 5: Commit**

```bash
vendor/bin/pint --dirty --format agent
git add app/Http/Controllers/Api/Internal/
git commit -m "fix(api): charge credits for upscales instead of gating on token_usage"
```

---

### Task 4: Verify against real data

**Files:** none — verification only.

- [ ] **Step 1: Trigger an upscale end-to-end**

Run one upscale from the UI on a local or staging KV and let it complete.

- [ ] **Step 2: Confirm exactly one cost-history row**

```bash
php artisan tinker --execute 'echo \DB::table("cost_histories")->whereIn("cost_type",["kv_generation_upscale","kv_resize_export_upscale"])->count();'
```

Expected: `1` where it was `0` before. This count being `0` after a completed
upscale is the original bug; it is the single most important assertion here.

- [ ] **Step 3: Sanity-check the credit amount**

```bash
php artisan tinker --execute '$r=\DB::table("cost_histories")->where("cost_type","kv_generation_upscale")->latest("created_at")->first(); echo $r->system_credit." credits, \$".$r->amount;'
```

Expected: a 2×-shaped upscale of a typical KV lands near **20 credits**. An
order-of-magnitude miss means Task 1's maths or Task 3's megapixel derivation
is wrong — check whether `width`/`height` arrived as pixels rather than
already-divided megapixels.

- [ ] **Step 4: Commit nothing**

Verification task. If something is wrong, fix it in the owning task.

---

## Follow-on contract note

After the engine swap lands (see the ai-service plan), the delivered image is
**downscaled** from the model's output, so `width × height` from the callback
stops equalling the billable quantity. The ai-service plan adds
`billable_megapixels` to `post_completed()`; the api plan then prefers it and
falls back to `width × height` when absent.

Until then, `width × height` is correct — the current engine does not
downscale.
