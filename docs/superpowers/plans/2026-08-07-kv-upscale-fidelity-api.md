# KV Upscale Fidelity — api Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the upscale contract from `factor` (1.5/2) to `target` (2k/4k), and bill from the model's real output rather than the delivered image.

**Architecture:** Both upscale tables key their cache on `(parent_id, factor)`. A new nullable `target` column takes over as the cache key, leaving legacy rows untouched with `target = NULL` — Postgres permits multiple NULLs in a unique index, so nothing collides and nothing needs backfilling. Metering switches from `width × height` to the `billable_megapixels` the ai-service now reports, because the delivered image is downscaled from what Replicate actually billed.

**Tech Stack:** Laravel 13, PHP 8.5, Pest 4, PostgreSQL.

## Prerequisites

- **Depends on:** `2026-08-07-kv-upscale-credit-metering-api.md` (ships first — `chargeUpscale()` must exist).
- **Depends on:** `2026-08-07-kv-upscale-fidelity-ai-service.md` for the `target` + `billable_megapixels` callback fields.

## Global Constraints

- **Targets are `2k` and `4k` only.** No other value validates.
- **Never reuse the `factor` column for targets.** Storing 2.0/4.0 as sentinels collides with existing 2× rows and would serve wrong-sized cached pixels under a new label.
- **Legacy rows are preserved, not migrated.** They stay readable as history.
- **Metering must never break the callback** — log and return on failure.
- Run `vendor/bin/pint --dirty --format agent` before every commit.

## Spec

`docs/superpowers/specs/2026-08-07-kv-upscale-fidelity-and-resolution-targets-design.md` § api

## File Structure

| File | Responsibility |
|---|---|
| `database/migrations/2026_08_07_*_add_target_to_kv_upscale_tables.php` | Column + index swap on both tables. |
| `app/Models/KvGenerationUpscale.php`, `KvResizeExportUpscale.php` | Fillable. |
| `app/Http/Requests/.../*UpscaleRequest.php` | `factor` → `target` validation. |
| `app/Http/Requests/Internal/*UpscaleCompleteRequest.php` | Accept `target`, `billable_megapixels`. |
| `app/Http/Controllers/Api/Studio/*UpscaleController.php` | Cache lookup by target. |
| `app/Http/Controllers/Api/Internal/*UpscaleInternalController.php` | Bill from `billable_megapixels`. |
| `app/Http/Resources/Studio/*UpscaleResource.php` | Expose `target`. |
| `app/Services/Studio/*UpscaleService.php` | Forward target to ai-service. |

---

### Task 1: Migration

**Files:**
- Create: `database/migrations/2026_08_07_120000_add_target_to_kv_upscale_tables.php`
- Modify: `app/Models/KvGenerationUpscale.php`, `app/Models/KvResizeExportUpscale.php`

**Interfaces:**
- Produces: a `target` column on both tables; unique index `(parent_id, target)`.

- [ ] **Step 1: Create the migration**

```bash
php artisan make:migration add_target_to_kv_upscale_tables --no-interaction
```

- [ ] **Step 2: Write it**

```php
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * Upscales move from ×-multipliers (1.5, 2) to resolution targets
     * (2k, 4k). `target` is nullable so existing rows keep their `factor`
     * and read as history; Postgres allows multiple NULLs in a unique
     * index, so legacy rows neither collide nor need backfilling.
     */
    public function up(): void
    {
        Schema::table('kv_generation_upscales', function (Blueprint $table) {
            $table->string('target', 8)->nullable()->after('factor');
            $table->unique(['kv_generation_id', 'target'], 'kv_generation_upscales_gen_target_unique');
        });

        Schema::table('kv_resize_export_upscales', function (Blueprint $table) {
            $table->string('target', 8)->nullable()->after('factor');
            $table->unique(['kv_resize_export_id', 'target'], 'kv_resize_export_upscales_export_target_unique');
        });

        // `factor` becomes optional — new rows carry a target instead.
        DB::statement('ALTER TABLE kv_generation_upscales ALTER COLUMN factor DROP NOT NULL');
        DB::statement('ALTER TABLE kv_resize_export_upscales ALTER COLUMN factor DROP NOT NULL');
    }

    public function down(): void
    {
        Schema::table('kv_generation_upscales', function (Blueprint $table) {
            $table->dropUnique('kv_generation_upscales_gen_target_unique');
            $table->dropColumn('target');
        });

        Schema::table('kv_resize_export_upscales', function (Blueprint $table) {
            $table->dropUnique('kv_resize_export_upscales_export_target_unique');
            $table->dropColumn('target');
        });
    }
};
```

Add `use Illuminate\Support\Facades\DB;` at the top.

- [ ] **Step 3: Add `target` to both models' `$fillable`**

- [ ] **Step 4: Run the migration**

Run: `TELESCOPE_ENABLED=false php artisan migrate`
Expected: two tables altered.

> Always run migrations with `TELESCOPE_ENABLED=false` — Telescope OOMs on
> data migrations and the failure looks like a hung database.

- [ ] **Step 5: Verify the old index still stands**

```bash
php artisan tinker --execute 'foreach(\DB::select("select indexname from pg_indexes where tablename = ?",["kv_generation_upscales"]) as $i){ echo $i->indexname."\n"; }'
```

Expected: both `..._gen_factor_unique` and `..._gen_target_unique` present. The
old index must survive so legacy rows stay protected.

- [ ] **Step 6: Commit**

```bash
vendor/bin/pint --dirty --format agent
git add database/migrations/ app/Models/
git commit -m "feat(api): add target column to the KV upscale tables"
```

---

### Task 2: Request contract

**Files:**
- Modify: the public upscale request classes for both flows
- Modify: `app/Http/Requests/Internal/KvGenerationUpscaleCompleteRequest.php`
- Modify: `app/Http/Requests/Internal/KvResizeExportUpscaleCompleteRequest.php`
- Test: `tests/Feature/Studio/KvUpscaleTargetValidationTest.php`

**Interfaces:**
- Consumes: nothing.
- Produces: requests validating `target` in `['2k','4k']`; internal requests accepting `target` and `billable_megapixels`.

- [ ] **Step 1: Write the failing test**

```php
<?php

use App\Models\User;

it('rejects a factor-shaped upscale request', function () {
    $user = User::factory()->create();

    $this->actingAs($user)
        ->postJson('/api/v1/studio/kv-generations/'.fake()->uuid.'/upscales', [
            'factor' => 2,
        ])
        ->assertStatus(422)
        ->assertJsonValidationErrors(['target']);
});

it('rejects an unsupported target', function () {
    $user = User::factory()->create();

    $this->actingAs($user)
        ->postJson('/api/v1/studio/kv-generations/'.fake()->uuid.'/upscales', [
            'target' => '8k',
        ])
        ->assertStatus(422)
        ->assertJsonValidationErrors(['target']);
});
```

Adjust the route to match the real one in `routes/api.php`.

- [ ] **Step 2: Run test to verify it fails**

Run: `php artisan test --compact --filter=KvUpscaleTargetValidation`
Expected: FAIL — `factor` still accepted.

- [ ] **Step 3: Swap the public validation**

Replace the `factor` rule with:

```php
            'target' => ['required', 'string', 'in:2k,4k'],
```

- [ ] **Step 4: Extend both internal complete requests**

Add to the rules array:

```php
            'target' => ['nullable', 'string', 'in:2k,4k'],
            // Megapixels the MODEL produced. Larger than width x height
            // whenever we downscale to an exact target, and it is what
            // Replicate bills.
            'billable_megapixels' => ['nullable', 'numeric', 'min:0'],
```

- [ ] **Step 5: Run test to verify it passes**

Run: `php artisan test --compact --filter=KvUpscaleTargetValidation`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
vendor/bin/pint --dirty --format agent
git add app/Http/Requests/
git commit -m "feat(api): validate 2k/4k targets on upscale requests"
```

---

### Task 3: Cache lookup, dispatch, and resource

**Files:**
- Modify: `app/Http/Controllers/Api/Studio/KvGenerationUpscaleController.php`
- Modify: `app/Http/Controllers/Api/Studio/KvResizeExportUpscaleController.php`
- Modify: both `app/Services/Studio/*UpscaleService.php`
- Modify: both `app/Http/Resources/Studio/*UpscaleResource.php`

**Interfaces:**
- Consumes: `target` from Task 2; the `target` column from Task 1.
- Produces: resources carrying `target`; ai-service dispatch carrying `target`.

- [ ] **Step 1: Key the cache lookup on target**

Wherever a controller or service does `where('factor', $factor)` to find or
create an existing upscale row, change it to `where('target', $target)` and
persist `'target' => $target` on create. Leave `factor` unset on new rows.

- [ ] **Step 2: Forward the target to ai-service**

In both services, replace `'factor' => $factor` in the ai-service payload with
`'target' => $target`.

- [ ] **Step 3: Expose it on both resources**

Add `'target' => $this->target,` beside the existing `factor` entry. Keep
`factor` so legacy rows still render in history.

- [ ] **Step 4: Verify no stale factor plumbing on the write path**

Run: `grep -rn "factor" app/Http/Controllers/Api/Studio/KvGenerationUpscaleController.php app/Services/Studio/KvGenerationUpscaleService.php`
Expected: no output. Resources may still mention `factor`; the write path must not.

- [ ] **Step 5: Run the upscale suite**

Run: `php artisan test --compact --filter=Upscale`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
vendor/bin/pint --dirty --format agent
git add app/Http/Controllers/ app/Services/ app/Http/Resources/
git commit -m "feat(api): key upscale cache and dispatch on target"
```

---

### Task 4: Bill from the model's real output

**Files:**
- Create: `app/Support/UpscaleBilling.php`
- Modify: both `app/Http/Controllers/Api/Internal/*UpscaleInternalController.php`
- Test: `tests/Unit/Services/KvUpscaleBillableMegapixelsTest.php`

**Interfaces:**
- Consumes: `chargeUpscale()` (metering plan, Task 2); `billable_megapixels` from the ai-service plan.
- Produces: nothing further.

The metering plan derived megapixels from `width × height`, which was correct
against the old engine. It no longer is: we downscale to the exact target, so
the delivered image is smaller than what Replicate billed.

Extract the rule into a shared helper so both controllers and the test point at
one implementation rather than a copy each.

- [ ] **Step 1: Write the failing test**

Create `tests/Unit/Services/KvUpscaleBillableMegapixelsTest.php`:

```php
<?php

use App\Support\UpscaleBilling;

/**
 * The delivered image is downscaled from the model's output, so width x height
 * under-bills. Prefer the reported figure; fall back only when it is absent
 * (an ai-service older than 2026-08-07).
 */
it('prefers billable_megapixels over the delivered dimensions', function () {
    expect(UpscaleBilling::megapixels([
        'width' => 4096, 'height' => 3277, 'billable_megapixels' => 25.16,
    ]))->toBe(25.16);
});

it('falls back to width x height when the field is absent', function () {
    expect(UpscaleBilling::megapixels(['width' => 2000, 'height' => 3000]))
        ->toBe(6.0);
});

it('returns zero when neither is usable', function () {
    expect(UpscaleBilling::megapixels([]))->toBe(0.0);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `php artisan test --compact --filter=KvUpscaleBillableMegapixels`
Expected: FAIL — `Class "App\Support\UpscaleBilling" not found`

- [ ] **Step 3: Create the helper and use it in both controllers**

```bash
php artisan make:class Support/UpscaleBilling --no-interaction
```

```php
<?php

namespace App\Support;

class UpscaleBilling
{
    /**
     * Billable megapixels for one upscale completion.
     *
     * Prefer what the model reported producing: the delivered image is
     * downscaled to an exact target, so width x height under-bills. The
     * fallback covers an ai-service older than 2026-08-07, which did not
     * send the field and did not downscale either.
     *
     * @param  array<string,mixed>  $validated
     */
    public static function megapixels(array $validated): float
    {
        if (isset($validated['billable_megapixels'])) {
            return (float) $validated['billable_megapixels'];
        }

        return ((int) ($validated['width'] ?? 0) * (int) ($validated['height'] ?? 0)) / 1_000_000;
    }
}
```

Then in both internal controllers, replace the megapixel derivation the
metering plan added with:

```php
            $megapixels = UpscaleBilling::megapixels($validated);
```

- [ ] **Step 4: Run the suite**

Run: `php artisan test --compact --filter=Upscale`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
vendor/bin/pint --dirty --format agent
git add app/Http/Controllers/Api/Internal/ tests/
git commit -m "fix(api): bill upscales from model output, not the downscaled delivery"
```

---

### Task 5: Verify a full round trip

**Files:** none — verification only.

- [ ] **Step 1: Request a 2K upscale end-to-end**

- [ ] **Step 2: Confirm the row carries a target and no factor**

```bash
php artisan tinker --execute '$r=\App\Models\KvGenerationUpscale::latest("created_at")->first(); echo $r->target." | factor=".var_export($r->factor,true)." | ".$r->width."x".$r->height;'
```

Expected: `2k | factor=NULL | <w>x2048` (or `2048x<h>`).

- [ ] **Step 3: Confirm exactly one charge, at the expected size**

```bash
php artisan tinker --execute '$r=\DB::table("cost_histories")->where("cost_type","kv_generation_upscale")->latest("created_at")->first(); echo $r->system_credit." credits";'
```

Expected: **~20 credits**. A number near 5 means `billable_megapixels` is not
arriving and the fallback is under-billing the downscaled image.

- [ ] **Step 4: Confirm the cache key holds**

Request the same target on the same generation again.

Expected: no second row, no second charge — the unique index on
`(parent_id, target)` did its job.
