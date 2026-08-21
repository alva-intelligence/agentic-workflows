# KV Layer Decomposition — api Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Own the decomposition job lifecycle — create it, dispatch it to ai-service, receive its completion, bill it, and turn a user's chosen layers into a new board with image overlays.

**Architecture:** Mirrors `KvResizeExport` end to end: a ULID table, a status enum, a service that owns every transition, a queued job that fires a 202 request at ai-service, and an internal callback controller that lands the result. Every piece of orchestration lives in `KvLayerDecompositionService` so that a future askFRND tool controller is a thin second caller.

**Tech Stack:** Laravel 13, PHP 8.5, PostgreSQL, Pest.

**Spec:** `docs/superpowers/specs/2026-08-21-kv-layer-decomposition-design.md`

## Global Constraints

- **All orchestration lives in `KvLayerDecompositionService`.** Controllers validate and format only. The spec requires this so `KvToolController::decompose` can be added later as a thin caller. Do NOT copy the shape of `KvToolController::generate`, which inlines its own flag check, credit gate, and file resolution.
- Geometry arriving from ai-service is already normalized **0..1**. Do not divide by anything.
- BytePlus bills layer decomposition **per image**, not per token. Use the `chargeUpscale` precedent (a physical quantity → a dedicated cost function), never `charge()`, which prices per 1000 tokens and would produce a wrong number from `output_tokens`.
- `studio_files.overlays` is a **single JSON column holding every overlay on the whole file**. The commit endpoint must **append**; replacing the array destroys the overlays on every other board.
- Gate both entry points on `config('services.ai.kv_layer_decompose_enabled')`.
- `Http::retry()` throws by default, which makes a following `if ($response->failed())` dead code. Follow the pattern used here: catch `RequestException`, or check `$response->failed()` without `retry()`. See `lesson: Http::retry() throws by default`.
- **Feature tests need a scratch Postgres.** SQLite cannot run these migrations (`DROP SEQUENCE`). Pass test *paths*, never `--filter` — the suite loader is broken and `--filter` cannot dodge it. A stale `bootstrap/cache/config.php` will hijack the DB; delete it first.

## File Structure

| File | Responsibility |
|---|---|
| `database/migrations/2026_08_21_100000_create_kv_layer_decompositions_table.php` | the table |
| `app/Enums/KvLayerDecompositionStatus.php` | status enum |
| `app/Enums/CostHistoryType.php` | +1 case |
| `app/Models/KvLayerDecomposition.php` | model |
| `app/Helpers/PricingHelper.php` | per-image tier pricing |
| `app/Services/Studio/KvCreditMeteringService.php` | `chargeLayerDecomposition()` |
| `app/Services/Studio/KvLayerDecompositionService.php` | **all** orchestration |
| `app/Jobs/Studio/ProcessKvLayerDecompositionJob.php` | calls ai-service |
| `app/Http/Controllers/Api/Studio/KvLayerDecompositionController.php` | web-facing create / show / commit |
| `app/Http/Controllers/Api/Internal/KvLayerDecompositionInternalController.php` | completion callback |
| `app/Http/Requests/Studio/CreateKvLayerDecompositionRequest.php` | create validation |
| `app/Http/Requests/Studio/CommitKvLayerDecompositionRequest.php` | commit validation |
| `app/Http/Requests/Internal/KvLayerDecompositionCompleteRequest.php` | callback validation |
| `app/Http/Resources/Studio/KvLayerDecompositionResource.php` | wire shape |
| `routes/api.php` | 3 studio routes + 1 internal route |
| `config/services.php` | the feature flag |

---

### Task 1: Table, enum, model, cost type

**Files:**
- Create: `api/database/migrations/2026_08_21_100000_create_kv_layer_decompositions_table.php`
- Create: `api/app/Enums/KvLayerDecompositionStatus.php`
- Create: `api/app/Models/KvLayerDecomposition.php`
- Modify: `api/app/Enums/CostHistoryType.php`
- Modify: `api/config/services.php`
- Test: `api/tests/Unit/Studio/KvLayerDecompositionModelTest.php`

**Interfaces:**
- Produces: `KvLayerDecomposition` (ULID, SoftDeletes) with `layers` cast to array and `status` cast to `KvLayerDecompositionStatus`; relations `file()`, `sourceGeneration()`.

- [ ] **Step 1: Write the migration**

Create `database/migrations/2026_08_21_100000_create_kv_layer_decompositions_table.php`:

```php
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('kv_layer_decompositions', function (Blueprint $t) {
            $t->ulid('id')->primary();
            $t->foreignUlid('studio_file_id')->constrained('studio_files')->cascadeOnDelete();
            // Nullable on purpose: the upload-base entry point (and, later, an
            // askFRND-originated image) decomposes a picture that has no
            // KvGeneration behind it yet.
            $t->foreignUlid('source_generation_id')->nullable()
                ->constrained('kv_generations')->nullOnDelete();
            $t->foreignUlid('created_by')->constrained('users')->cascadeOnDelete();

            $t->text('source_image_url');
            $t->text('base_image_url')->nullable();
            $t->jsonb('layers')->nullable();

            $t->string('status', 16)->default('pending');
            $t->text('error_message')->nullable();
            $t->string('ai_service_run_id')->nullable();
            $t->string('model')->nullable();

            $t->timestamps();
            $t->softDeletes();

            $t->index(['studio_file_id', 'created_at'], 'kv_layer_decomps_file_created_idx');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('kv_layer_decompositions');
    }
};
```

- [ ] **Step 2: Write the enum**

Create `app/Enums/KvLayerDecompositionStatus.php`:

```php
<?php

namespace App\Enums;

enum KvLayerDecompositionStatus: string
{
    case Pending = 'pending';
    case Generating = 'generating';
    case Done = 'done';
    case Failed = 'failed';
}
```

- [ ] **Step 3: Add the cost type**

In `app/Enums/CostHistoryType.php`, add the case beside the other `KV_*` entries:

```php
    case KV_LAYER_DECOMPOSITION = 'kv_layer_decomposition'; // KV Generator: layer decomposition
```

and add the matching arm to `getName()`:

```php
            self::KV_LAYER_DECOMPOSITION => 'KV Layer Decomposition',
```

- [ ] **Step 4: Add the feature flag**

In `config/services.php`, inside the existing `'ai' => [...]` block (beside `kv_resize_vision_prepass`):

```php
        'kv_layer_decompose_enabled' => env('KV_LAYER_DECOMPOSE_ENABLED', false),
```

- [ ] **Step 5: Write the failing model test**

Create `tests/Unit/Studio/KvLayerDecompositionModelTest.php`:

```php
<?php

use App\Enums\KvLayerDecompositionStatus;
use App\Models\KvLayerDecomposition;

it('casts status to the enum', function () {
    $row = new KvLayerDecomposition(['status' => 'generating']);
    expect($row->status)->toBe(KvLayerDecompositionStatus::Generating);
});

it('casts layers to an array', function () {
    $row = new KvLayerDecomposition();
    $row->layers = [['index' => 1, 'x' => 0.5]];
    expect($row->layers)->toBeArray()->and($row->layers[0]['index'])->toBe(1);
});

it('exposes every writable column as fillable', function () {
    $fillable = (new KvLayerDecomposition())->getFillable();
    expect($fillable)->toContain(
        'studio_file_id', 'source_generation_id', 'created_by',
        'source_image_url', 'base_image_url', 'layers',
        'status', 'error_message', 'ai_service_run_id', 'model',
    );
});
```

- [ ] **Step 6: Run it to verify it fails**

Run: `cd api && ./vendor/bin/pest tests/Unit/Studio/KvLayerDecompositionModelTest.php`
Expected: FAIL — `Class "App\Models\KvLayerDecomposition" not found`

- [ ] **Step 7: Write the model**

Create `app/Models/KvLayerDecomposition.php`:

```php
<?php

namespace App\Models;

use App\Enums\KvLayerDecompositionStatus;
use Illuminate\Database\Eloquent\Concerns\HasUlids;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\SoftDeletes;

class KvLayerDecomposition extends Model
{
    use HasFactory, HasUlids, SoftDeletes;

    protected $table = 'kv_layer_decompositions';

    protected $fillable = [
        'studio_file_id',
        'source_generation_id',
        'created_by',
        'source_image_url',
        'base_image_url',
        'layers',
        'status',
        'error_message',
        'ai_service_run_id',
        'model',
    ];

    protected $casts = [
        'layers' => 'array',
        'status' => KvLayerDecompositionStatus::class,
    ];

    public function file(): BelongsTo
    {
        return $this->belongsTo(StudioFile::class, 'studio_file_id');
    }

    public function sourceGeneration(): BelongsTo
    {
        return $this->belongsTo(KvGeneration::class, 'source_generation_id');
    }
}
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `cd api && ./vendor/bin/pest tests/Unit/Studio/KvLayerDecompositionModelTest.php`
Expected: 3 passed

- [ ] **Step 9: Commit**

```bash
git add database/migrations/2026_08_21_100000_create_kv_layer_decompositions_table.php app/Enums/KvLayerDecompositionStatus.php app/Enums/CostHistoryType.php app/Models/KvLayerDecomposition.php config/services.php tests/Unit/Studio/KvLayerDecompositionModelTest.php
git commit -m "feat(api): kv_layer_decompositions table, model, status enum"
```

---

### Task 2: Per-image pricing and metering

BytePlus bills layer decomposition per returned image, on a per-image pixel
tier. `PricingHelper::calculateImageCostAgno()` prices per 1000 tokens and
would turn `output_tokens: 34772` into a meaningless charge. This follows the
`calculateUpscaleCost` / `chargeUpscale` precedent instead: a physical
quantity in, a dollar figure out.

**Files:**
- Modify: `api/app/Helpers/PricingHelper.php` (append beside `calculateUpscaleCost`)
- Modify: `api/app/Services/Studio/KvCreditMeteringService.php` (append beside `chargeUpscale`)
- Test: `api/tests/Unit/Studio/LayerDecompositionPricingTest.php`

**Interfaces:**
- Produces:
  - `PricingHelper::LAYER_DECOMPOSITION_CHEAP_TIER_MAX_PIXELS = 2_610_000`
  - `PricingHelper::LAYER_DECOMPOSITION_PRICE_CHEAP = 0.0225`
  - `PricingHelper::LAYER_DECOMPOSITION_PRICE_EXPENSIVE = 0.045`
  - `PricingHelper::calculateLayerDecompositionCost(array $pixelCounts): float`
  - `KvCreditMeteringService::chargeLayerDecomposition(User $user, Workspace $workspace, string $costType, string $toolName, string $batchId, string $model, array $pixelCounts, ?string $brandId = null): void`

- [ ] **Step 1: Write the failing pricing test**

Create `tests/Unit/Studio/LayerDecompositionPricingTest.php`:

```php
<?php

use App\Helpers\PricingHelper;

it('prices every image under the tier ceiling at the cheap rate', function () {
    // The real frndGlow run: a 1536x1024 base plus 7 layers, all under 2.61M px.
    $pixels = [1572864, 752212, 572862, 167040, 717776, 550000, 818436, 338522];

    $cost = PricingHelper::calculateLayerDecompositionCost($pixels);

    expect($cost)->toEqualWithDelta(8 * 0.0225 * PricingHelper::upscaleMultiplier(), 0.0001);
});

it('prices an image over the tier ceiling at the expensive rate', function () {
    // 1760x2176 = 3,829,760 px — over 2.61M.
    $cost = PricingHelper::calculateLayerDecompositionCost([3829760]);

    expect($cost)->toEqualWithDelta(0.045 * PricingHelper::upscaleMultiplier(), 0.0001);
});

it('prices a mixed response per image rather than by the largest', function () {
    $cost = PricingHelper::calculateLayerDecompositionCost([3829760, 100000]);
    $expected = (0.045 + 0.0225) * PricingHelper::upscaleMultiplier();

    expect($cost)->toEqualWithDelta($expected, 0.0001);
});

it('treats the tier boundary itself as cheap', function () {
    $cost = PricingHelper::calculateLayerDecompositionCost([2_610_000]);

    expect($cost)->toEqualWithDelta(0.0225 * PricingHelper::upscaleMultiplier(), 0.0001);
});

it('charges the expensive rate for an unknown pixel count rather than under-billing', function () {
    // ai-service sends 0 when it cannot parse the vendor's size string.
    // Never guess cheap: an unparsed size is more likely a large image.
    $cost = PricingHelper::calculateLayerDecompositionCost([0]);

    expect($cost)->toEqualWithDelta(0.045 * PricingHelper::upscaleMultiplier(), 0.0001);
});

it('returns zero for an empty response', function () {
    expect(PricingHelper::calculateLayerDecompositionCost([]))->toBe(0.0);
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd api && ./vendor/bin/pest tests/Unit/Studio/LayerDecompositionPricingTest.php`
Expected: FAIL — `Call to undefined method ...::calculateLayerDecompositionCost()`

- [ ] **Step 3: Add the pricing function**

In `app/Helpers/PricingHelper.php`, directly after `calculateUpscaleCost()`:

```php
    /**
     * BytePlus tier boundary for Seedream 5.0 pro image pricing: 2.61 million
     * pixels (1.5K and below on one side, above it on the other).
     */
    public const int LAYER_DECOMPOSITION_CHEAP_TIER_MAX_PIXELS = 2_610_000;

    /**
     * Published layer-decomposition rates — HALF the single-image generation
     * rate, and billed per returned image rather than per token. Each layer in
     * one response is priced on its own tier, so a mixed response mixes rates.
     */
    public const float LAYER_DECOMPOSITION_PRICE_CHEAP = 0.0225;

    public const float LAYER_DECOMPOSITION_PRICE_EXPENSIVE = 0.045;

    /**
     * Dollar cost of one decomposition, multiplier already applied.
     *
     * A pixel count of 0 means ai-service could not parse the vendor's size
     * string. Bill it at the expensive tier: an unreadable size is more likely
     * a large image, and under-billing is the worse failure.
     *
     * @param  array<int, int>  $pixelCounts  one entry per returned image, base first
     */
    public static function calculateLayerDecompositionCost(array $pixelCounts): float
    {
        if ($pixelCounts === []) {
            return 0.0;
        }

        $raw = 0.0;
        foreach ($pixelCounts as $pixels) {
            $raw += ($pixels > 0 && $pixels <= self::LAYER_DECOMPOSITION_CHEAP_TIER_MAX_PIXELS)
                ? self::LAYER_DECOMPOSITION_PRICE_CHEAP
                : self::LAYER_DECOMPOSITION_PRICE_EXPENSIVE;
        }

        // Reuses the upscale multiplier: both are per-unit provider charges
        // rather than per-token, and there is no reason to diverge the markup.
        return $raw * self::upscaleMultiplier();
    }
```

- [ ] **Step 4: Run the pricing test to verify it passes**

Run: `cd api && ./vendor/bin/pest tests/Unit/Studio/LayerDecompositionPricingTest.php`
Expected: 6 passed

- [ ] **Step 5: Add the metering method**

In `app/Services/Studio/KvCreditMeteringService.php`, add `chargeLayerDecomposition()`
directly after `chargeUpscale()`. Copy `chargeUpscale`'s body exactly, changing
only the guard, the cost call, and the metadata written to the `CostHistory`
row — read `chargeUpscale` in full and mirror its `DB::transaction`,
`deductCreditsWithDebt`, and `CostHistory` write verbatim:

```php
    /**
     * Meter one layer decomposition. Deliberately NOT charge(): BytePlus bills
     * this per returned image on a per-image pixel tier, so there is no token
     * count to price. Mirrors chargeUpscale(), which has the same shape for
     * the same reason.
     *
     * @param  array<int, int>  $pixelCounts  one entry per returned image, base first
     */
    public function chargeLayerDecomposition(
        User $user,
        Workspace $workspace,
        string $costType,
        string $toolName,
        string $batchId,
        string $model,
        array $pixelCounts,
        ?string $brandId = null,
    ): void {
        if ($pixelCounts === []) {
            Log::warning('KV layer-decomposition metering skipped: no images reported', [
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

        $cost = PricingHelper::calculateLayerDecompositionCost($pixelCounts);
        $credits = (int) ceil(PricingHelper::calculateCreditsFromCosts($cost));

        if ($credits <= 0) {
            return;
        }

        try {
            DB::transaction(function () use (
                $user, $workspace, $brandId, $costType, $toolName,
                $batchId, $cost, $credits, $pixelCounts,
            ) {
                $deduction = $this->creditService->deductCreditsWithDebt(
                    $user,
                    $workspace,
                    $credits,
                    $batchId,
                );

                $extraCreditDrawn = $deduction['extra_credit_drawn'] ?? 0;
                // Decomposition bills per IMAGE. The token columns exist for
                // audit parity with the image/video/upscale paths, so the
                // billable quantity recorded there is the image count.
                $billableImages = count($pixelCounts);

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
                    'prompt_tokens' => 0,
                    'completion_tokens' => $billableImages,
                    'total_tokens' => $billableImages,
                    'batch_identifier' => $batchId,
                    'chat_features' => 'KV Generator',
                ]);
            });
        } catch (UniqueConstraintViolationException) {
            // Race-safe: another worker already wrote the same batch_identifier.
        } catch (Throwable $e) {
            Log::error('KV layer-decomposition metering charge failed', [
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

Every symbol above (`DB`, `CostHistory`, `Brand`, `Log`, `Throwable`,
`UniqueConstraintViolationException`) is already imported in this file for
`chargeUpscale`; add nothing.

- [ ] **Step 6: Write the failing metering test**

Create `tests/Unit/Studio/LayerDecompositionMeteringTest.php`:

```php
<?php

use App\Helpers\PricingHelper;

it('bills the base plus every layer, not just the base', function () {
    $baseOnly = PricingHelper::calculateLayerDecompositionCost([1572864]);
    $full = PricingHelper::calculateLayerDecompositionCost(array_fill(0, 8, 1572864));

    expect($full)->toEqualWithDelta($baseOnly * 8, 0.0001);
});

it('never prices a decomposition above the 17-image ceiling', function () {
    $worst = PricingHelper::calculateLayerDecompositionCost(array_fill(0, 17, 4_000_000));

    expect($worst)->toEqualWithDelta(
        17 * 0.045 * PricingHelper::upscaleMultiplier(), 0.0001
    );
});
```

- [ ] **Step 7: Run both unit tests**

Run: `cd api && ./vendor/bin/pest tests/Unit/Studio/LayerDecompositionPricingTest.php tests/Unit/Studio/LayerDecompositionMeteringTest.php`
Expected: 8 passed

- [ ] **Step 8: Commit**

```bash
git add app/Helpers/PricingHelper.php app/Services/Studio/KvCreditMeteringService.php tests/Unit/Studio/
git commit -m "feat(api): per-image tier pricing for layer decomposition"
```

---

### Task 3: The service and the queued job

**Files:**
- Create: `api/app/Services/Studio/KvLayerDecompositionService.php`
- Create: `api/app/Jobs/Studio/ProcessKvLayerDecompositionJob.php`
- Test: `api/tests/Unit/Studio/KvLayerDecompositionServiceTest.php`

**Interfaces:**
- Produces:
  - `KvLayerDecompositionService::create(StudioFile $file, string $sourceImageUrl, ?string $sourceGenerationId, string $userId): KvLayerDecomposition` — creates the row and dispatches the job. **This exact signature is what the future `KvToolController::decompose` will call**; do not bind it to a request object.
  - `markGenerating(KvLayerDecomposition $row): void`
  - `markDone(KvLayerDecomposition $row, string $baseImageUrl, array $layers): void`
  - `markFailed(KvLayerDecomposition $row, string $errorMessage): void`
  - `failStale(StudioFile $file): int` with `public const STALE_AFTER_MINUTES = 10`

- [ ] **Step 1: Write the failing service test**

Create `tests/Unit/Studio/KvLayerDecompositionServiceTest.php`:

```php
<?php

use App\Enums\KvLayerDecompositionStatus;
use App\Models\KvLayerDecomposition;
use App\Services\Studio\KvLayerDecompositionService;

it('moves a row to generating', function () {
    $row = Mockery::mock(KvLayerDecomposition::class)->makePartial();
    $row->shouldReceive('update')
        ->once()
        ->with(['status' => KvLayerDecompositionStatus::Generating]);

    (new KvLayerDecompositionService())->markGenerating($row);
});

it('clears any earlier error when it lands a result', function () {
    $layers = [['index' => 1, 'z' => 1, 'x' => 0.1, 'y' => 0.2,
                'width' => 0.3, 'height' => 0.4, 'name' => 'n',
                'description' => '', 'image_url' => 'https://s3/l1.png']];

    $row = Mockery::mock(KvLayerDecomposition::class)->makePartial();
    $row->shouldReceive('update')->once()->with([
        'status' => KvLayerDecompositionStatus::Done,
        'base_image_url' => 'https://s3/base.png',
        'layers' => $layers,
        'error_message' => null,
    ]);

    (new KvLayerDecompositionService())->markDone($row, 'https://s3/base.png', $layers);
});

it('records the failure message', function () {
    $row = Mockery::mock(KvLayerDecomposition::class)->makePartial();
    $row->shouldReceive('update')->once()->with([
        'status' => KvLayerDecompositionStatus::Failed,
        'error_message' => 'no_layers_detected',
    ]);

    (new KvLayerDecompositionService())->markFailed($row, 'no_layers_detected');
});

it('gives a stale job longer than resize does', function () {
    // Decomposition takes ~110s against resize's ~66s p95, so resize's 5-minute
    // watchdog would kill healthy jobs.
    expect(KvLayerDecompositionService::STALE_AFTER_MINUTES)->toBeGreaterThanOrEqual(10);
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd api && ./vendor/bin/pest tests/Unit/Studio/KvLayerDecompositionServiceTest.php`
Expected: FAIL — `Class "App\Services\Studio\KvLayerDecompositionService" not found`

- [ ] **Step 3: Write the service**

Create `app/Services/Studio/KvLayerDecompositionService.php`:

```php
<?php

namespace App\Services\Studio;

use App\Enums\KvLayerDecompositionStatus;
use App\Jobs\Studio\ProcessKvLayerDecompositionJob;
use App\Models\KvLayerDecomposition;
use App\Models\StudioFile;

/**
 * Every layer-decomposition state transition lives here.
 *
 * The web-facing controller and the future askFRND tool controller
 * (KvToolController::decompose) must both be thin callers of this class —
 * that is a spec requirement, so the tool can be added without duplicating
 * the flag gate, the row creation, or the dispatch.
 */
class KvLayerDecompositionService
{
    /**
     * Decomposition takes ~110s at the vendor plus mirroring, so resize's
     * 5-minute watchdog would fail healthy jobs. 10 minutes leaves headroom
     * over the observed worst case while still rescuing a lost callback.
     */
    public const STALE_AFTER_MINUTES = 10;

    /**
     * `$sourceImageUrl` rather than a generation is deliberate: the
     * upload-base entry point — and later an askFRND-originated image —
     * decomposes a picture with no KvGeneration behind it.
     */
    public function create(
        StudioFile $file,
        string $sourceImageUrl,
        ?string $sourceGenerationId,
        string $userId,
    ): KvLayerDecomposition {
        $row = KvLayerDecomposition::create([
            'studio_file_id' => $file->id,
            'source_generation_id' => $sourceGenerationId,
            'created_by' => $userId,
            'source_image_url' => $sourceImageUrl,
            'status' => KvLayerDecompositionStatus::Pending,
        ]);

        ProcessKvLayerDecompositionJob::dispatch($row->id);

        return $row;
    }

    public function markGenerating(KvLayerDecomposition $row): void
    {
        $row->update(['status' => KvLayerDecompositionStatus::Generating]);
    }

    public function markDone(KvLayerDecomposition $row, string $baseImageUrl, array $layers): void
    {
        $row->update([
            'status' => KvLayerDecompositionStatus::Done,
            'base_image_url' => $baseImageUrl,
            'layers' => $layers,
            'error_message' => null,
        ]);
    }

    public function markFailed(KvLayerDecomposition $row, string $errorMessage): void
    {
        $row->update([
            'status' => KvLayerDecompositionStatus::Failed,
            'error_message' => $errorMessage,
        ]);
    }

    /**
     * Watchdog for a lost completion callback. ai-service runs the work as a
     * fire-and-forget background task; if its callback never lands the row
     * would sit pending forever behind a spinner with no way to retry.
     */
    public function failStale(StudioFile $file): int
    {
        return KvLayerDecomposition::where('studio_file_id', $file->id)
            ->whereIn('status', [
                KvLayerDecompositionStatus::Pending->value,
                KvLayerDecompositionStatus::Generating->value,
            ])
            ->where('updated_at', '<', now()->subMinutes(self::STALE_AFTER_MINUTES))
            ->update([
                'status' => KvLayerDecompositionStatus::Failed->value,
                'error_message' => 'Timed out waiting for the decomposition service — try again.',
                'updated_at' => now(),
            ]);
    }
}
```

- [ ] **Step 4: Run the service test to verify it passes**

Run: `cd api && ./vendor/bin/pest tests/Unit/Studio/KvLayerDecompositionServiceTest.php`
Expected: 4 passed

- [ ] **Step 5: Write the job**

Create `app/Jobs/Studio/ProcessKvLayerDecompositionJob.php`:

```php
<?php

namespace App\Jobs\Studio;

use App\Models\Brand;
use App\Models\KvLayerDecomposition;
use App\Models\User;
use App\Services\Studio\KvLayerDecompositionService;
use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Http\Client\RequestException;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Queue\SerializesModels;
use Illuminate\Support\Facades\Http;

class ProcessKvLayerDecompositionJob implements ShouldQueue
{
    use Dispatchable, InteractsWithQueue, Queueable, SerializesModels;

    public int $tries = 3;

    public int $timeout = 300;

    public function __construct(public string $decompositionId)
    {
        $this->onQueue('default');
    }

    public function handle(KvLayerDecompositionService $service): void
    {
        $row = KvLayerDecomposition::find($this->decompositionId);
        if (! $row) {
            return;
        }

        $service->markGenerating($row);

        $user = User::find($row->created_by);
        $file = $row->file()->with('workspace')->first();
        $brandName = $file?->brand_id
            ? Brand::query()->whereKey($file->brand_id)->value('name')
            : null;

        // Same ai-service base URL every other KV feature uses — no parallel
        // env var for this one.
        $aiUrl = rtrim(config('services.ai.url'), '/');

        // Deliberately WITHOUT Laravel's HTTP retry helper: it throws on a
        // final failure, which would make the $response->failed() check below
        // dead code and leave the row stuck in `generating` forever. The catch
        // is the real error path. (ProcessKvResizeExportJob has that bug —
        // do not copy it.) The wording avoids naming the helper literally so
        // it does not collide with the test asserting the call is absent.
        try {
            $response = Http::timeout(30)->post("{$aiUrl}/ai/kv-layer-decompose", [
                'decomposition_id' => $row->id,
                'source_image_url' => $row->source_image_url,
                // Identity for PostHog attribution on the ai-service side.
                // ai-service captures the vendor call in a BackgroundTask, and
                // its bind_ai_context only reads the REQUEST body — omit these
                // and every decomposition lands on an anonymous person with no
                // workspace group, making the spend untraceable.
                'user_id' => $user?->id,
                'user_email' => $user?->email,
                'workspace_id' => $file?->workspace_id,
                'workspace_name' => $file?->workspace?->name,
                'brand_id' => $file?->brand_id,
                'brand_name' => $brandName,
            ]);
        } catch (RequestException|\Throwable $e) {
            $service->markFailed($row, "AI service unreachable: {$e->getMessage()}");

            return;
        }

        if ($response->failed()) {
            $service->markFailed($row, "AI service error: {$response->status()}");

            return;
        }

        // ai-service answers 202; the real result arrives via the internal
        // callback. Nothing else to do here.
    }

    public function failed(\Throwable $e): void
    {
        $row = KvLayerDecomposition::find($this->decompositionId);
        if ($row) {
            app(KvLayerDecompositionService::class)
                ->markFailed($row, "Job failed: {$e->getMessage()}");
        }
    }
}
```

- [ ] **Step 6: Write the failing job test**

Append to `tests/Unit/Studio/KvLayerDecompositionServiceTest.php`:

```php
it('sends only the id and the source url to ai-service', function () {
    // The ai-service contract is deliberately tiny: it re-reads nothing from
    // api, so anything extra here is dead weight that will drift.
    $reflection = new ReflectionMethod(
        \App\Jobs\Studio\ProcessKvLayerDecompositionJob::class, 'handle'
    );
    $body = file_get_contents($reflection->getFileName());

    expect($body)->toContain("'decomposition_id' => \$row->id")
        ->and($body)->toContain("'source_image_url' => \$row->source_image_url")
        ->and($body)->toContain('/ai/kv-layer-decompose');
});

it('sends identity so the ai-service PostHog capture is attributable', function () {
    // ai-service captures the byteplus call in a BackgroundTask; its
    // bind_ai_context only reads the request body. Drop these and every
    // decomposition attributes to a fresh anonymous person.
    $body = file_get_contents(
        app_path('Jobs/Studio/ProcessKvLayerDecompositionJob.php')
    );

    expect($body)->toContain("'user_id' =>")
        ->and($body)->toContain("'workspace_id' =>")
        ->and($body)->toContain("'brand_id' =>");
});

it('does not use Http::retry, which throws and would strand the row', function () {
    $body = file_get_contents(
        app_path('Jobs/Studio/ProcessKvLayerDecompositionJob.php')
    );

    expect($body)->not->toContain('->retry(');
});
```

- [ ] **Step 7: Run the tests**

Run: `cd api && ./vendor/bin/pest tests/Unit/Studio/KvLayerDecompositionServiceTest.php`
Expected: 7 passed

- [ ] **Step 8: Commit**

```bash
git add app/Services/Studio/KvLayerDecompositionService.php app/Jobs/Studio/ProcessKvLayerDecompositionJob.php tests/Unit/Studio/KvLayerDecompositionServiceTest.php
git commit -m "feat(api): layer-decomposition service + dispatch job"
```

---

### Task 4: Web-facing create and show

**Files:**
- Create: `api/app/Http/Requests/Studio/CreateKvLayerDecompositionRequest.php`
- Create: `api/app/Http/Resources/Studio/KvLayerDecompositionResource.php`
- Create: `api/app/Http/Controllers/Api/Studio/KvLayerDecompositionController.php`
- Modify: `api/routes/api.php` (beside the `files/{id}/resize-exports` routes, ~line 3820)
- Test: `api/tests/Feature/Studio/KvLayerDecompositionApiTest.php`

**Interfaces:**
- Consumes: `KvLayerDecompositionService::create()` (Task 3).
- Produces:
  - `POST v1/studio/files/{fileId}/layer-decompositions` → 201, resource
  - `GET v1/studio/files/{fileId}/layer-decompositions/{id}` → 200, resource
  - Resource shape: `{id, studio_file_id, status, error_message, source_image_url, base_image_url, layers, created_at}`

- [ ] **Step 1: Write the request**

Create `app/Http/Requests/Studio/CreateKvLayerDecompositionRequest.php`:

```php
<?php

namespace App\Http\Requests\Studio;

use Illuminate\Foundation\Http\FormRequest;

class CreateKvLayerDecompositionRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    public function rules(): array
    {
        return [
            // Either the caller names an existing generation to decompose, or
            // it supplies a raw image URL (the upload-base entry point, and
            // later an askFRND-originated image). Exactly one is required.
            'source_generation_id' => ['nullable', 'string', 'required_without:source_image_url'],
            'source_image_url' => ['nullable', 'url', 'max:2048', 'required_without:source_generation_id'],
        ];
    }
}
```

- [ ] **Step 2: Write the resource**

Create `app/Http/Resources/Studio/KvLayerDecompositionResource.php`:

```php
<?php

namespace App\Http\Resources\Studio;

use Illuminate\Http\Resources\Json\JsonResource;

class KvLayerDecompositionResource extends JsonResource
{
    public function toArray($request): array
    {
        return [
            'id' => $this->id,
            'studio_file_id' => $this->studio_file_id,
            'source_generation_id' => $this->source_generation_id,
            'status' => $this->status->value,
            'error_message' => $this->error_message,
            'source_image_url' => $this->source_image_url,
            'base_image_url' => $this->base_image_url,
            // Already normalized 0..1 by ai-service. Emitted verbatim: any
            // arithmetic here would be a second conversion.
            'layers' => $this->layers ?? [],
            'created_at' => $this->created_at?->toIso8601String(),
        ];
    }
}
```

- [ ] **Step 3: Write the failing feature test**

Create `tests/Feature/Studio/KvLayerDecompositionApiTest.php`:

```php
<?php

use App\Jobs\Studio\ProcessKvLayerDecompositionJob;
use App\Models\KvLayerDecomposition;
use App\Models\StudioFile;
use App\Models\User;
use Illuminate\Support\Facades\Queue;

beforeEach(function () {
    config()->set('services.ai.kv_layer_decompose_enabled', true);
    Queue::fake();

    $this->user = User::factory()->create();
    $this->file = StudioFile::factory()->create([
        'workspace_id' => $this->user->current_workspace_id,
    ]);
    $this->actingAs($this->user);
});

it('creates a pending row and dispatches the job', function () {
    $res = $this->postJson(
        "/api/v1/studio/files/{$this->file->id}/layer-decompositions",
        ['source_image_url' => 'https://example.com/kv.png'],
    );

    $res->assertCreated()
        ->assertJsonPath('data.status', 'pending')
        ->assertJsonPath('data.layers', []);

    Queue::assertPushed(ProcessKvLayerDecompositionJob::class);
});

it('refuses when the feature flag is off', function () {
    config()->set('services.ai.kv_layer_decompose_enabled', false);

    $this->postJson(
        "/api/v1/studio/files/{$this->file->id}/layer-decompositions",
        ['source_image_url' => 'https://example.com/kv.png'],
    )->assertForbidden();

    Queue::assertNothingPushed();
});

it('requires a source', function () {
    $this->postJson(
        "/api/v1/studio/files/{$this->file->id}/layer-decompositions", [],
    )->assertStatus(422);
});

it('refuses a file in another workspace', function () {
    $other = StudioFile::factory()->create();

    $this->postJson(
        "/api/v1/studio/files/{$other->id}/layer-decompositions",
        ['source_image_url' => 'https://example.com/kv.png'],
    )->assertForbidden();
});

it('shows a decomposition with its layers', function () {
    $row = KvLayerDecomposition::factory()->create([
        'studio_file_id' => $this->file->id,
        'created_by' => $this->user->id,
        'status' => 'done',
        'base_image_url' => 'https://s3/base.png',
        'layers' => [[
            'index' => 1, 'z' => 1, 'name' => 'Tube', 'description' => 'd',
            'x' => 0.34, 'y' => 0.441, 'width' => 0.083, 'height' => 0.286,
            'image_url' => 'https://s3/l1.png',
        ]],
    ]);

    $this->getJson("/api/v1/studio/files/{$this->file->id}/layer-decompositions/{$row->id}")
        ->assertOk()
        ->assertJsonPath('data.status', 'done')
        ->assertJsonPath('data.layers.0.x', 0.34)
        ->assertJsonPath('data.layers.0.name', 'Tube');
});
```

You will also need a factory. Create
`database/factories/KvLayerDecompositionFactory.php` following the shape of the
existing `KvResizeExportFactory` (read it first), defaulting `status` to
`'pending'` and `source_image_url` to a fake URL.

- [ ] **Step 4: Run it to verify it fails**

First clear any stale config cache, then run against a scratch Postgres:

```bash
cd api && rm -f bootstrap/cache/config.php && ./vendor/bin/pest tests/Feature/Studio/KvLayerDecompositionApiTest.php
```
Expected: FAIL — 404 on the route

- [ ] **Step 5: Write the controller**

Create `app/Http/Controllers/Api/Studio/KvLayerDecompositionController.php`:

```php
<?php

namespace App\Http\Controllers\Api\Studio;

use App\Http\Controllers\Controller;
use App\Http\Requests\Studio\CreateKvLayerDecompositionRequest;
use App\Http\Resources\Studio\KvLayerDecompositionResource;
use App\Models\Brand;
use App\Models\KvGeneration;
use App\Models\KvLayerDecomposition;
use App\Models\StudioFile;
use App\Services\Studio\KvLayerDecompositionService;
use Illuminate\Http\Request;

/**
 * Thin. Validation and response shaping only — every decision lives in
 * KvLayerDecompositionService so the future askFRND tool controller can reuse
 * it without copying anything from here.
 */
class KvLayerDecompositionController extends Controller
{
    public function __construct(private readonly KvLayerDecompositionService $service) {}

    public function store(
        CreateKvLayerDecompositionRequest $request,
        string $fileId,
    ): KvLayerDecompositionResource {
        abort_unless(
            (bool) config('services.ai.kv_layer_decompose_enabled'),
            403,
            'Layer decomposition is not enabled.',
        );

        $file = StudioFile::query()->findOrFail($fileId);
        $this->authorizeAccess($file, $request);

        $generationId = $request->validated('source_generation_id');
        $sourceImageUrl = $request->validated('source_image_url');

        if ($generationId) {
            $generation = KvGeneration::where('studio_file_id', $file->id)
                ->whereKey($generationId)
                ->firstOrFail();
            // source_image_url is the logo-free render where one exists; it is
            // the better decomposition input because a baked logo would come
            // back as its own spurious layer.
            $sourceImageUrl = $generation->source_image_url ?: $generation->image_url;
        }

        $row = $this->service->create(
            $file, $sourceImageUrl, $generationId, $request->user()->id
        );

        return new KvLayerDecompositionResource($row);
    }

    public function show(Request $request, string $fileId, string $id): KvLayerDecompositionResource
    {
        $file = StudioFile::query()->findOrFail($fileId);
        $this->authorizeAccess($file, $request);

        $this->service->failStale($file);

        $row = KvLayerDecomposition::where('studio_file_id', $file->id)
            ->whereKey($id)
            ->firstOrFail();

        return new KvLayerDecompositionResource($row);
    }

    private function authorizeAccess(StudioFile $file, Request $request): void
    {
        $user = $request->user();

        abort_unless(
            $file->workspace_id === $user->current_workspace_id,
            403,
            'You do not have access to this file.',
        );

        if ($file->brand_id !== null) {
            abort_unless(
                Brand::accessibleBy($user->id, $user->current_workspace_id)
                    ->where('id', $file->brand_id)
                    ->exists(),
                403,
                'You do not have access to this file.',
            );
        }
    }
}
```

- [ ] **Step 6: Register the routes**

In `routes/api.php`, beside the existing `files/{file}/resize-exports` routes
(~line 3820, inside the same authenticated studio group):

```php
                    Route::post('files/{fileId}/layer-decompositions', [
                        KvLayerDecompositionController::class,
                        'store',
                    ]);
                    Route::get('files/{fileId}/layer-decompositions/{id}', [
                        KvLayerDecompositionController::class,
                        'show',
                    ]);
```

Add the `use App\Http\Controllers\Api\Studio\KvLayerDecompositionController;`
import at the top of the file.

- [ ] **Step 7: Run the feature test to verify it passes**

Run: `cd api && rm -f bootstrap/cache/config.php && ./vendor/bin/pest tests/Feature/Studio/KvLayerDecompositionApiTest.php`
Expected: 5 passed

- [ ] **Step 8: Commit**

```bash
git add app/Http/Requests/Studio/CreateKvLayerDecompositionRequest.php app/Http/Resources/Studio/KvLayerDecompositionResource.php app/Http/Controllers/Api/Studio/KvLayerDecompositionController.php database/factories/KvLayerDecompositionFactory.php routes/api.php tests/Feature/Studio/KvLayerDecompositionApiTest.php
git commit -m "feat(api): create + show routes for layer decompositions"
```

---

### Task 5: Internal completion callback

**Files:**
- Create: `api/app/Http/Requests/Internal/KvLayerDecompositionCompleteRequest.php`
- Create: `api/app/Http/Controllers/Api/Internal/KvLayerDecompositionInternalController.php`
- Modify: `api/routes/api.php` (beside `kv-resize-exports/completed`, ~line 4419)
- Test: `api/tests/Feature/Studio/KvLayerDecompositionCallbackTest.php`

**Interfaces:**
- Consumes: the payload posted by ai-service Task 4 — `{decomposition_id, status, base_image_url?, layers?, image_pixel_counts?, error_message?, ai_service_run_id?, model?}`.
- Produces: `POST v1/internal/kv-layer-decompositions/completed` → `{"ok": true}`.

- [ ] **Step 1: Write the request**

Create `app/Http/Requests/Internal/KvLayerDecompositionCompleteRequest.php`:

```php
<?php

namespace App\Http\Requests\Internal;

use Illuminate\Foundation\Http\FormRequest;

class KvLayerDecompositionCompleteRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    public function rules(): array
    {
        return [
            'decomposition_id' => ['required', 'string'],
            'status' => ['required', 'in:done,failed'],
            'base_image_url' => ['required_if:status,done', 'string'],
            'layers' => ['required_if:status,done', 'array'],
            'layers.*.index' => ['required', 'integer'],
            'layers.*.z' => ['required', 'integer'],
            'layers.*.name' => ['required', 'string'],
            'layers.*.description' => ['present', 'string'],
            // Already normalized 0..1 by ai-service. The bounds are the guard
            // against a regression there re-sending the vendor's 0-1000 scale.
            'layers.*.x' => ['required', 'numeric', 'between:0,1'],
            'layers.*.y' => ['required', 'numeric', 'between:0,1'],
            'layers.*.width' => ['required', 'numeric', 'between:0,1'],
            'layers.*.height' => ['required', 'numeric', 'between:0,1'],
            'layers.*.image_url' => ['required', 'string'],
            'image_pixel_counts' => ['sometimes', 'array'],
            'image_pixel_counts.*' => ['integer', 'min:0'],
            'error_message' => ['required_if:status,failed', 'nullable', 'string'],
            'ai_service_run_id' => ['sometimes', 'nullable', 'string'],
            'model' => ['sometimes', 'nullable', 'string'],
        ];
    }
}
```

- [ ] **Step 2: Write the failing callback test**

Create `tests/Feature/Studio/KvLayerDecompositionCallbackTest.php`:

```php
<?php

use App\Models\KvLayerDecomposition;
use App\Models\StudioFile;
use App\Models\User;

beforeEach(function () {
    $this->user = User::factory()->create();
    $this->file = StudioFile::factory()->create([
        'workspace_id' => $this->user->current_workspace_id,
    ]);
    $this->row = KvLayerDecomposition::factory()->create([
        'studio_file_id' => $this->file->id,
        'created_by' => $this->user->id,
        'status' => 'generating',
    ]);
});

function donePayload(string $id): array
{
    return [
        'decomposition_id' => $id,
        'status' => 'done',
        'base_image_url' => 'https://s3/base.png',
        'layers' => [[
            'index' => 1, 'z' => 1, 'name' => 'Tube', 'description' => 'd',
            'x' => 0.34, 'y' => 0.441, 'width' => 0.083, 'height' => 0.286,
            'image_url' => 'https://s3/l1.png',
        ]],
        'image_pixel_counts' => [1572864, 338522],
        'ai_service_run_id' => 'run-1',
        'model' => 'dola-seedream-5-0-pro-260628',
    ];
}

it('lands a done result', function () {
    $this->postJson('/api/v1/internal/kv-layer-decompositions/completed', donePayload($this->row->id))
        ->assertOk()
        ->assertJson(['ok' => true]);

    $this->row->refresh();
    expect($this->row->status->value)->toBe('done')
        ->and($this->row->base_image_url)->toBe('https://s3/base.png')
        ->and($this->row->layers[0]['name'])->toBe('Tube')
        ->and($this->row->model)->toBe('dola-seedream-5-0-pro-260628');
});

it('lands a failure', function () {
    $this->postJson('/api/v1/internal/kv-layer-decompositions/completed', [
        'decomposition_id' => $this->row->id,
        'status' => 'failed',
        'error_message' => 'no_layers_detected',
    ])->assertOk();

    $this->row->refresh();
    expect($this->row->status->value)->toBe('failed')
        ->and($this->row->error_message)->toBe('no_layers_detected');
});

it('ignores a callback for a row that no longer exists', function () {
    $this->postJson('/api/v1/internal/kv-layer-decompositions/completed',
        donePayload('01JQQQQQQQQQQQQQQQQQQQQQQQ'))
        ->assertOk()
        ->assertJson(['ok' => true, 'ignored' => true]);
});

it('ignores a duplicate callback on an already-finished row', function () {
    $this->row->update(['status' => 'done']);

    $this->postJson('/api/v1/internal/kv-layer-decompositions/completed', donePayload($this->row->id))
        ->assertOk()
        ->assertJson(['ignored' => true]);
});

it('rejects layer geometry outside 0..1', function () {
    $payload = donePayload($this->row->id);
    // The vendor's own 0-1000 scale leaking through would look like this.
    $payload['layers'][0]['x'] = 340;

    $this->postJson('/api/v1/internal/kv-layer-decompositions/completed', $payload)
        ->assertStatus(422);
});

it('does not charge when the run id is missing', function () {
    $payload = donePayload($this->row->id);
    unset($payload['ai_service_run_id']);

    $this->postJson('/api/v1/internal/kv-layer-decompositions/completed', $payload)->assertOk();

    expect(\App\Models\CostHistory::count())->toBe(0);
});

it('writes exactly one cost history row with the layer-decomposition type', function () {
    // The metering METHOD has no unit test of its own — a unit test would be
    // mock-heavy and prove little. This is where the guard, the transaction,
    // the CostHistory field mapping and the arithmetic are actually verified.
    $this->postJson('/api/v1/internal/kv-layer-decompositions/completed', donePayload($this->row->id))
        ->assertOk();

    $rows = \App\Models\CostHistory::all();
    expect($rows)->toHaveCount(1);
    expect($rows[0]->cost_type)->toBe('kv_layer_decomposition')
        ->and($rows[0]->entry_type)->toBe('deduction')
        ->and($rows[0]->batch_identifier)->toBe("kv_layer_decompose_{$this->row->id}_run-1");

    // image_pixel_counts was [1572864, 338522] — two images, both under the
    // 2.61M cheap tier, so 2 x $0.0225 x the multiplier.
    $expected = 2 * 0.0225 * \App\Helpers\PricingHelper::upscaleMultiplier();
    expect((float) $rows[0]->amount)->toEqualWithDelta($expected, 0.0001);

    // Decomposition bills per IMAGE; the token columns carry the image count.
    expect((int) $rows[0]->total_tokens)->toBe(2);
});

it('does not double-charge a replayed callback', function () {
    $payload = donePayload($this->row->id);

    $this->postJson('/api/v1/internal/kv-layer-decompositions/completed', $payload)->assertOk();
    $this->postJson('/api/v1/internal/kv-layer-decompositions/completed', $payload)->assertOk();

    expect(\App\Models\CostHistory::count())->toBe(1);
});
```

- [ ] **Step 3: Run it to verify it fails**

Run: `cd api && rm -f bootstrap/cache/config.php && ./vendor/bin/pest tests/Feature/Studio/KvLayerDecompositionCallbackTest.php`
Expected: FAIL — 404

- [ ] **Step 4: Write the controller**

Create `app/Http/Controllers/Api/Internal/KvLayerDecompositionInternalController.php`:

```php
<?php

namespace App\Http\Controllers\Api\Internal;

use App\Enums\KvLayerDecompositionStatus;
use App\Http\Controllers\Controller;
use App\Http\Requests\Internal\KvLayerDecompositionCompleteRequest;
use App\Models\KvLayerDecomposition;
use App\Models\User;
use App\Services\Studio\KvCreditMeteringService;
use App\Services\Studio\KvLayerDecompositionService;
use Illuminate\Http\JsonResponse;

class KvLayerDecompositionInternalController extends Controller
{
    public function __construct(
        private readonly KvLayerDecompositionService $service,
        private readonly KvCreditMeteringService $metering,
    ) {}

    public function completed(KvLayerDecompositionCompleteRequest $request): JsonResponse
    {
        $validated = $request->validated();

        $row = KvLayerDecomposition::with('file')->find($validated['decomposition_id']);

        // The row may have been deleted while the background task ran. A late
        // callback for a vanished decomposition is a clean no-op — and charges
        // nothing, since metering lives in the `done` branch below.
        if (! $row) {
            return response()->json(['ok' => true, 'ignored' => true]);
        }

        if (! in_array($row->status, [
            KvLayerDecompositionStatus::Pending,
            KvLayerDecompositionStatus::Generating,
        ], true)) {
            return response()->json(['ok' => true, 'ignored' => true]);
        }

        if ($validated['status'] === 'failed') {
            $this->service->markFailed($row, $validated['error_message']);

            return response()->json(['ok' => true]);
        }

        $this->service->markDone($row, $validated['base_image_url'], $validated['layers']);
        $row->update([
            'ai_service_run_id' => $validated['ai_service_run_id'] ?? null,
            'model' => $validated['model'] ?? null,
        ]);

        $aiRunId = $validated['ai_service_run_id'] ?? null;
        $pixelCounts = $validated['image_pixel_counts'] ?? [];

        if ($aiRunId && $pixelCounts !== []) {
            $user = User::find($row->created_by);
            if ($user && $row->file && $row->file->workspace) {
                // chargeLayerDecomposition, NOT charge(): BytePlus bills this
                // per returned image on a per-image pixel tier, so there is no
                // token count to price.
                $this->metering->chargeLayerDecomposition(
                    user: $user,
                    workspace: $row->file->workspace,
                    costType: 'kv_layer_decomposition',
                    toolName: 'KV Layer Decomposition',
                    batchId: "kv_layer_decompose_{$row->id}_{$aiRunId}",
                    model: $validated['model'] ?? '',
                    pixelCounts: $pixelCounts,
                    brandId: $row->file->brand_id,
                );
            }
        }

        return response()->json(['ok' => true]);
    }
}
```

- [ ] **Step 5: Register the route**

In `routes/api.php`, beside `kv-resize-exports/completed` (~line 4419):

```php
        // KV Layer Decomposition completion callback (called by ai-service
        // after every returned image has been mirrored to our storage).
        Route::post('kv-layer-decompositions/completed', [
            KvLayerDecompositionInternalController::class,
            'completed',
        ]);
```

Add the import for `App\Http\Controllers\Api\Internal\KvLayerDecompositionInternalController`.

- [ ] **Step 6: Run the callback test to verify it passes**

Run: `cd api && rm -f bootstrap/cache/config.php && ./vendor/bin/pest tests/Feature/Studio/KvLayerDecompositionCallbackTest.php`
Expected: 8 passed

- [ ] **Step 7: Commit**

```bash
git add app/Http/Requests/Internal/KvLayerDecompositionCompleteRequest.php app/Http/Controllers/Api/Internal/KvLayerDecompositionInternalController.php routes/api.php tests/Feature/Studio/KvLayerDecompositionCallbackTest.php
git commit -m "feat(api): layer-decomposition completion callback + per-image billing"
```

---

### Task 6: Commit — new board plus overlays

The user has ticked a subset of layers. The unticked ones must be baked back
into the clean plate (or the board loses them), then a new board is created
with the ticked ones as image overlays.

**Files:**
- Create: `api/app/Http/Requests/Studio/CommitKvLayerDecompositionRequest.php`
- Modify: `api/app/Services/Studio/KvLayerDecompositionService.php` (add `commit()`)
- Modify: `api/app/Http/Controllers/Api/Studio/KvLayerDecompositionController.php` (add `commit()`)
- Modify: `api/routes/api.php` (one more route)
- Test: `api/tests/Feature/Studio/KvLayerDecompositionCommitTest.php`

**Interfaces:**
- Consumes: `KvGenerationService::persistCompletion(array $payload): KvGeneration`; ai-service `POST /ai/kv-layer-decompose/flatten`.
- Produces:
  - `KvLayerDecompositionService::commit(KvLayerDecomposition $row, array $layerIndexes, string $userId): array` returning `['generation' => KvGeneration, 'overlays' => array]`
  - `POST v1/studio/files/{fileId}/layer-decompositions/{id}/commit` → 201 `{data: {generation, overlays}}`

- [ ] **Step 1: Write the request**

Create `app/Http/Requests/Studio/CommitKvLayerDecompositionRequest.php`:

```php
<?php

namespace App\Http\Requests\Studio;

use Illuminate\Foundation\Http\FormRequest;

class CommitKvLayerDecompositionRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    public function rules(): array
    {
        return [
            // The layer `index` values the user ticked. An empty array is
            // legal and means "bake everything into one flat board".
            'layer_indexes' => ['present', 'array'],
            'layer_indexes.*' => ['integer'],
        ];
    }
}
```

- [ ] **Step 2: Write the failing commit test**

Create `tests/Feature/Studio/KvLayerDecompositionCommitTest.php`:

```php
<?php

use App\Models\KvLayerDecomposition;
use App\Models\StudioFile;
use App\Models\User;
use Illuminate\Support\Facades\Http;

beforeEach(function () {
    config()->set('services.ai.kv_layer_decompose_enabled', true);

    $this->user = User::factory()->create();
    $this->file = StudioFile::factory()->create([
        'workspace_id' => $this->user->current_workspace_id,
        'overlays' => [[
            'id' => 'existing-overlay', 'type' => 'text',
            'x' => 0.0, 'y' => 0.0, 'width' => 0.1, 'height' => 0.1,
            'rotation' => 0.0, 'z' => 0, 'board_generation_id' => null,
            'payload' => ['type' => 'text', 'content' => 'keep me', 'color' => '#000'],
        ]],
    ]);
    $this->actingAs($this->user);

    $this->row = KvLayerDecomposition::factory()->create([
        'studio_file_id' => $this->file->id,
        'created_by' => $this->user->id,
        'status' => 'done',
        'base_image_url' => 'https://s3/base.png',
        'layers' => [
            ['index' => 1, 'z' => 1, 'name' => 'Background', 'description' => '',
             'x' => 0.0, 'y' => 0.0, 'width' => 0.47, 'height' => 0.9,
             'image_url' => 'https://s3/l1.png'],
            ['index' => 7, 'z' => 7, 'name' => 'Tube', 'description' => '',
             'x' => 0.34, 'y' => 0.441, 'width' => 0.083, 'height' => 0.286,
             'image_url' => 'https://s3/l7.png'],
        ],
    ]);

    Http::fake([
        '*/ai/kv-layer-decompose/flatten' => Http::response(
            ['image_url' => 'https://s3/flattened.png'], 200
        ),
    ]);
});

it('sends only the UNSELECTED layers to the flatten endpoint', function () {
    $this->postJson(
        "/api/v1/studio/files/{$this->file->id}/layer-decompositions/{$this->row->id}/commit",
        ['layer_indexes' => [7]],
    )->assertCreated();

    Http::assertSent(function ($request) {
        $body = $request->data();
        // Layer 7 was selected, so only layer 1 gets baked in.
        return count($body['layers']) === 1 && $body['layers'][0]['z'] === 1;
    });
});

it('creates a new board whose image is the flattened plate', function () {
    $res = $this->postJson(
        "/api/v1/studio/files/{$this->file->id}/layer-decompositions/{$this->row->id}/commit",
        ['layer_indexes' => [7]],
    )->assertCreated();

    $generationId = $res->json('data.generation.id');
    $this->assertDatabaseHas('kv_generations', [
        'id' => $generationId,
        'studio_file_id' => $this->file->id,
        'image_url' => 'https://s3/flattened.png',
        // A NEW board, not a new version of the source: a parent would splice
        // it into the source's version chain and it would replace that board
        // instead of standing beside it.
        'parent_generation_id' => null,
    ]);
});

it('appends the selected layers as image overlays without dropping existing ones', function () {
    $this->postJson(
        "/api/v1/studio/files/{$this->file->id}/layer-decompositions/{$this->row->id}/commit",
        ['layer_indexes' => [7]],
    )->assertCreated();

    $overlays = $this->file->fresh()->overlays;

    // studio_files.overlays is ONE array for the WHOLE file. Replacing it
    // would wipe every other board's overlays.
    expect(collect($overlays)->pluck('id'))->toContain('existing-overlay');

    $added = collect($overlays)->firstWhere('payload.name', 'Tube');
    expect($added)->not->toBeNull()
        ->and($added['type'])->toBe('image')
        ->and($added['x'])->toBe(0.34)
        ->and($added['width'])->toBe(0.083)
        ->and($added['payload']['type'])->toBe('image');
});

it('binds each new overlay to the new board', function () {
    $res = $this->postJson(
        "/api/v1/studio/files/{$this->file->id}/layer-decompositions/{$this->row->id}/commit",
        ['layer_indexes' => [7]],
    );

    $generationId = $res->json('data.generation.id');
    $added = collect($this->file->fresh()->overlays)->firstWhere('payload.name', 'Tube');

    expect($added['board_generation_id'])->toBe($generationId);
});

it('bakes every layer in when nothing is selected', function () {
    $this->postJson(
        "/api/v1/studio/files/{$this->file->id}/layer-decompositions/{$this->row->id}/commit",
        ['layer_indexes' => []],
    )->assertCreated();

    Http::assertSent(fn ($request) => count($request->data()['layers']) === 2);
});

it('refuses to commit a decomposition that is not done', function () {
    $this->row->update(['status' => 'generating']);

    $this->postJson(
        "/api/v1/studio/files/{$this->file->id}/layer-decompositions/{$this->row->id}/commit",
        ['layer_indexes' => [7]],
    )->assertStatus(422);
});

it('fails cleanly when the flatten call errors', function () {
    Http::fake(['*/ai/kv-layer-decompose/flatten' => Http::response('boom', 500)]);

    $this->postJson(
        "/api/v1/studio/files/{$this->file->id}/layer-decompositions/{$this->row->id}/commit",
        ['layer_indexes' => [7]],
    )->assertStatus(502);

    // No half-built board.
    expect($this->file->fresh()->generations()->count())->toBe(0);
});
```

- [ ] **Step 3: Run it to verify it fails**

Run: `cd api && rm -f bootstrap/cache/config.php && ./vendor/bin/pest tests/Feature/Studio/KvLayerDecompositionCommitTest.php`
Expected: FAIL — 404

- [ ] **Step 4: Add `commit()` to the service**

Append to `app/Services/Studio/KvLayerDecompositionService.php`. Add these
imports at the top of the file first:

```php
use App\Models\KvGeneration;
use App\Services\Studio\KvGenerationService;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Str;
```


```php
    /**
     * Turn a reviewed decomposition into a NEW board.
     *
     * Layers the user did NOT pick are composited back into the clean plate
     * first — without that, unticking a layer silently deletes that element
     * from the board. The picked ones become image overlays bound to the new
     * board.
     *
     * @param  array<int, int>  $layerIndexes  the `index` values the user ticked
     * @return array{generation: KvGeneration, overlays: array}
     */
    public function commit(
        KvLayerDecomposition $row,
        array $layerIndexes,
        string $userId,
    ): array {
        if ($row->status !== KvLayerDecompositionStatus::Done) {
            throw new \InvalidArgumentException('Decomposition is not finished.');
        }

        $all = collect($row->layers ?? []);
        $selected = $all->whereIn('index', $layerIndexes)->values();
        $unselected = $all->whereNotIn('index', $layerIndexes)->values();

        $aiUrl = rtrim(config('services.ai.url'), '/');
        $response = Http::timeout(120)->post("{$aiUrl}/ai/kv-layer-decompose/flatten", [
            'decomposition_id' => $row->id,
            'base_image_url' => $row->base_image_url,
            'layers' => $unselected->map(fn (array $l) => [
                'z' => $l['z'], 'image_url' => $l['image_url'],
                'x' => $l['x'], 'y' => $l['y'],
                'width' => $l['width'], 'height' => $l['height'],
            ])->all(),
        ]);

        if ($response->failed()) {
            throw new \RuntimeException("Flatten failed: {$response->status()}");
        }

        $flattenedUrl = $response->json('image_url');

        $generation = app(KvGenerationService::class)->persistCompletion([
            'studio_file_id' => $row->studio_file_id,
            // NULL: this is a new board standing beside the source, not a new
            // version of it. A parent would splice it into the source's
            // version chain and the canvas would render it as a replacement.
            'parent_generation_id' => null,
            'image_url' => $flattenedUrl,
            'source_image_url' => $flattenedUrl,
            'thumbnail_url' => $flattenedUrl,
            'prompt_snapshot' => 'Layer decomposition',
            'model' => $row->model ?? '',
            'mode' => 'sketch',
            'ai_service_run_id' => $row->ai_service_run_id,
            'metadata' => ['layer_decomposition_id' => $row->id],
            'created_by' => $userId,
        ]);

        $file = $generation->file()->first();
        $now = now()->toIso8601String();
        $existing = $file->overlays ?? [];
        $maxZ = collect($existing)->max('z') ?? 0;

        $added = $selected->values()->map(function (array $layer, int $i) use ($generation, $now, $maxZ) {
            return [
                'id' => (string) Str::ulid(),
                'type' => 'image',
                'x' => (float) $layer['x'],
                'y' => (float) $layer['y'],
                'width' => (float) $layer['width'],
                'height' => (float) $layer['height'],
                'rotation' => 0.0,
                'z' => $maxZ + $i + 1,
                'board_generation_id' => $generation->id,
                'payload' => [
                    'type' => 'image',
                    'url' => $layer['image_url'],
                    // The model's own label, so the Layers panel reads
                    // "frndGlow Sunscreen Tube" with no extra vision call.
                    'name' => $layer['name'],
                ],
                'created_at' => $now,
                'updated_at' => $now,
            ];
        })->all();

        // APPEND. studio_files.overlays is one array for the entire file, so
        // writing only the new entries would delete every other board's work.
        $file->forceFill(['overlays' => array_merge($existing, $added)])->save();

        return ['generation' => $generation, 'overlays' => $added];
    }
```

- [ ] **Step 5: Add the controller action and route**

In `KvLayerDecompositionController`, add:

```php
    public function commit(
        CommitKvLayerDecompositionRequest $request,
        string $fileId,
        string $id,
    ): JsonResponse {
        abort_unless(
            (bool) config('services.ai.kv_layer_decompose_enabled'),
            403,
            'Layer decomposition is not enabled.',
        );

        $file = StudioFile::query()->findOrFail($fileId);
        $this->authorizeAccess($file, $request);

        $row = KvLayerDecomposition::where('studio_file_id', $file->id)
            ->whereKey($id)
            ->firstOrFail();

        try {
            $result = $this->service->commit(
                $row, $request->validated('layer_indexes'), $request->user()->id
            );
        } catch (\InvalidArgumentException $e) {
            return response()->json(['message' => $e->getMessage()], 422);
        } catch (\RuntimeException $e) {
            return response()->json(['message' => $e->getMessage()], 502);
        }

        return response()->json(['data' => [
            'generation' => ['id' => $result['generation']->id],
            'overlays' => $result['overlays'],
        ]], 201);
    }
```

Add `use Illuminate\Http\JsonResponse;` and
`use App\Http\Requests\Studio\CommitKvLayerDecompositionRequest;` to the
controller's imports, then register the route next to the other two:

```php
                    Route::post('files/{fileId}/layer-decompositions/{id}/commit', [
                        KvLayerDecompositionController::class,
                        'commit',
                    ]);
```

- [ ] **Step 6: Run the commit test to verify it passes**

Run: `cd api && rm -f bootstrap/cache/config.php && ./vendor/bin/pest tests/Feature/Studio/KvLayerDecompositionCommitTest.php`
Expected: 7 passed

- [ ] **Step 7: Run every test this plan added**

Run:
```bash
cd api && rm -f bootstrap/cache/config.php && ./vendor/bin/pest tests/Unit/Studio/KvLayerDecompositionModelTest.php tests/Unit/Studio/KvLayerDecompositionServiceTest.php tests/Unit/Studio/LayerDecompositionPricingTest.php tests/Unit/Studio/LayerDecompositionMeteringTest.php tests/Feature/Studio/KvLayerDecompositionApiTest.php tests/Feature/Studio/KvLayerDecompositionCallbackTest.php tests/Feature/Studio/KvLayerDecompositionCommitTest.php
```
Expected: all pass

- [ ] **Step 8: Commit**

```bash
git add app/Http/Requests/Studio/CommitKvLayerDecompositionRequest.php app/Services/Studio/KvLayerDecompositionService.php app/Http/Controllers/Api/Studio/KvLayerDecompositionController.php routes/api.php tests/Feature/Studio/KvLayerDecompositionCommitTest.php
git commit -m "feat(api): commit decomposition to a new board with image overlays"
```

---

## Review checkpoint

Two decisions in Task 6 are reasoned from how the canvas behaves rather than
from an existing identical call site. Confirm them with a reviewer before this
merges:

1. **`parent_generation_id: null` makes a new board rather than a new version.**
   The restore path in `KvGeneratorFileController` (~line 448) sets a parent
   precisely because it *wants* to extend the chain. If a null parent turns out
   not to produce a standalone board on the canvas, this is the line to change.
2. **`payload.name` on an image overlay is what the Layers panel reads.** Verify
   against `overlaysForTile` / the Layers panel in web before relying on it; if
   the panel keys off something else, carry the model's label there instead.
