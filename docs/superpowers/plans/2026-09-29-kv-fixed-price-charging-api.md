# KV Fixed-Price Charging — api Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Charge a fixed, admin-editable credit price for two currently-free KV paths — resizing a layer-composed (PSD-import) board, and creating a Motion project — refusing up front when the user cannot afford it.

**Architecture:** A new keyed `credit_prices` table holds whole-number prices. A new `KvFixedPriceChargeService` gates on `CreditService::hasSpendableCredits()` and funds through `CreditService::deductCreditsWithDebt()`, writing the usual `CostHistory` audit row. It is deliberately separate from `KvCreditMeteringService`, whose every method is post-hoc, non-blocking and debt-tolerant. Three call sites charge: `KvResizeExportService::createBatch()`, `::duplicate()`, and `KvMotionProjectController::store()`.

**Tech Stack:** Laravel 13, PHP 8.5, PostgreSQL, Pest (Unit) + PHPUnit class style with `DatabaseTransactions` on pgsql (Feature).

**Spec:** [docs/superpowers/specs/2026-09-29-kv-fixed-price-charging-design.md](../specs/2026-09-29-kv-fixed-price-charging-design.md)

**Repo:** `api/` — branch off `develop`.

## Global Constraints

- Prices are **whole numbers, 0 or higher**. `0` means the action is free.
- **No price may be hardcoded** outside `CreditPrice::DEFAULTS` (the fallback) and the seed.
- The charge path reads the price **live** — no cache. Only the public read endpoint may be cached.
- Seeded keys and defaults, exactly: `kv_resize_overlay_only` = **5**, `kv_motion_create` = **25**.
- Gate with `CreditService::hasSpendableCredits()`. Fund with `CreditService::deductCreditsWithDebt()`. **Never `deductCredits()`** — it does not draw Extra Credit and would refuse a workspace the gate just admitted.
- A resolved total of `0` short-circuits: no gate, no deduction, no `CostHistory` row. `hasSpendableCredits()` applies `max(1, $cost)`, so passing 0 would demand 1 credit.
- `CostHistory` rows use `chat_features => 'KV Generator'`, `entry_type => 'deduction'`, `amount => 0.0`, and all token columns `0`.
- `batch_identifier` is a readable row-derived string (`kv_resize_overlay_{ulid}`, `kv_motion_create_{ulid}`). **Not** a UUID — that constraint was relaxed on 2026-04-30 and 2026-08-22.
- `cost_type` values: `kv_resize_overlay_only`, `kv_motion_create`.
- AI-generated (`layer_composed = false`) resize behaviour must not change at all.

## Review Focus

Five things the spec implies that a naive implementation gets wrong. Each has a test pinned to the task that owns the code.

1. **Pool short, Extra Credit sufficient** — must be *allowed* and funded from Extra Credit, with `is_from_extra_credit` true. Gating and funding with different primitives is the whole point of §4.3. (Task 3)
2. **Repeat resize request for sizes that already exist** — `firstOrCreate` returns existing rows; charging per *requested* id re-bills them. Must charge 0. (Task 4)
3. **A price row that is missing or unreadable** — must fall back to the code default, never to 0. A DB blip must not silently make a paid feature free. (Task 1)
4. **A price of 0 with a zero-credit user** — must pass, not be refused by `max(1, $cost)`. (Task 3)
5. **`size_count` disagreeing with `snapshot.tiles`** — must 422, or web can under-report the size count and underpay. (Task 5)

---

## File Structure

| File | Responsibility |
|------|---------------|
| `database/migrations/2026_09_29_100000_create_credit_prices_table.php` | The table |
| `app/Models/CreditPrice.php` | Read/write a keyed price, with a code default fallback |
| `app/Exceptions/InsufficientCreditsException.php` | Typed refusal carrying `required`/`available` |
| `app/Services/Studio/KvFixedPriceChargeService.php` | Gate + fund + audit for a fixed-credit KV charge |
| `app/Services/Studio/KvResizeExportService.php` | *modify* — charge on the layer-composed branch and on duplicate |
| `app/Http/Controllers/Api/Studio/KvMotionProjectController.php` | *modify* — charge before creating a project |
| `app/Http/Requests/Studio/StoreKvMotionProjectRequest.php` | *modify* — add `size_count` |
| `app/Http/Controllers/Api/Studio/KvPricingController.php` | Public price read |
| `app/Http/Controllers/Api/Admin/CreditPriceController.php` | Superadmin list/edit, audit-logged |
| `routes/api.php` | *modify* — three routes |

---

### Task 1: `credit_prices` table and `CreditPrice` model

**Files:**
- Create: `api/database/migrations/2026_09_29_100000_create_credit_prices_table.php`
- Create: `api/app/Models/CreditPrice.php`
- Test: `api/tests/Unit/Models/CreditPriceTest.php`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `CreditPrice::DEFAULTS` — `array<string,int>`
  - `CreditPrice::KEY_RESIZE_OVERLAY_ONLY = 'kv_resize_overlay_only'`
  - `CreditPrice::KEY_MOTION_CREATE = 'kv_motion_create'`
  - `CreditPrice::credits(string $key): int`
  - `CreditPrice::set(string $key, int $credits, ?string $userId = null): self`
  - `CreditPrice::effective(): array<string,int>` — every known key with the value in force

- [ ] **Step 1: Write the failing test**

```php
<?php

use App\Models\CreditPrice;
use Illuminate\Foundation\Testing\DatabaseTransactions;
use Illuminate\Support\Facades\DB;
use Tests\TestCase;

uses(TestCase::class, DatabaseTransactions::class);

beforeEach(function () {
    putenv('DB_CONNECTION=pgsql');
    putenv('DB_DATABASE=frnd_testing');
    $_ENV['DB_CONNECTION'] = 'pgsql';
    $_ENV['DB_DATABASE'] = 'frnd_testing';

    try {
        DB::connection('pgsql')->getPdo();
    } catch (\Throwable) {
        test()->markTestSkipped('CreditPriceTest requires a reachable Postgres connection.');
    }
});

it('falls back to the code default when no row exists', function () {
    CreditPrice::query()->where('key', CreditPrice::KEY_MOTION_CREATE)->delete();

    expect(CreditPrice::credits(CreditPrice::KEY_MOTION_CREATE))->toBe(25);
});

it('reads the stored value once a row exists', function () {
    CreditPrice::set(CreditPrice::KEY_MOTION_CREATE, 30);

    expect(CreditPrice::credits(CreditPrice::KEY_MOTION_CREATE))->toBe(30);
});

it('honours a stored zero rather than treating it as absent', function () {
    CreditPrice::set(CreditPrice::KEY_RESIZE_OVERLAY_ONLY, 0);

    expect(CreditPrice::credits(CreditPrice::KEY_RESIZE_OVERLAY_ONLY))->toBe(0);
});

it('reads live, with no cache between two writes', function () {
    CreditPrice::set(CreditPrice::KEY_RESIZE_OVERLAY_ONLY, 7);
    expect(CreditPrice::credits(CreditPrice::KEY_RESIZE_OVERLAY_ONLY))->toBe(7);

    CreditPrice::set(CreditPrice::KEY_RESIZE_OVERLAY_ONLY, 9);
    expect(CreditPrice::credits(CreditPrice::KEY_RESIZE_OVERLAY_ONLY))->toBe(9);
});

it('returns the code default for an unknown key rather than throwing', function () {
    expect(CreditPrice::credits('kv_nonexistent'))->toBe(0);
});

it('records who changed a price', function () {
    $row = CreditPrice::set(CreditPrice::KEY_MOTION_CREATE, 40, '01J00000000000000000000000');

    expect($row->updated_by)->toBe('01J00000000000000000000000');
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd api && php artisan test tests/Unit/Models/CreditPriceTest.php`
Expected: FAIL — `Class "App\Models\CreditPrice" not found`.

> Pass the test **path**, never `--filter` — the suite loader is broken and `--filter` does not dodge it. If the run reports a stale config, delete `bootstrap/cache/config.php` (delete it; do not restore it).

- [ ] **Step 3: Write the migration**

```php
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * Admin-editable, whole-number credit prices for KV actions that have a fixed
 * price rather than a vendor-derived one.
 *
 * Shaped after `feature_configurations`: a keyed row per setting, `updated_by`
 * for the audit trail, and absence meaning "the code default applies". Keyed
 * rows rather than named columns so a third price is one INSERT, not a
 * migration — see the deferred flatten price in the design doc, §3.1.
 *
 * Deliberately NOT cached. `FeatureConfiguration` caches because it is read on
 * every request; a price is read once per user action, so a lookup against a
 * two-row table is free — and reading live is what makes the quote the user
 * was shown and the amount actually deducted agree (J4).
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('credit_prices', function (Blueprint $table) {
            $table->ulid('id')->primary();
            $table->string('key')->unique();
            $table->unsignedInteger('credits');
            $table->foreignUlid('updated_by')->nullable();
            $table->timestamps();
        });

        // Seed the two launch prices so a fresh environment matches the PRD
        // without an admin having to visit the page first.
        $now = now();
        DB::table('credit_prices')->insert([
            [
                'id' => (string) Illuminate\Support\Str::ulid(),
                'key' => 'kv_resize_overlay_only',
                'credits' => 5,
                'created_at' => $now,
                'updated_at' => $now,
            ],
            [
                'id' => (string) Illuminate\Support\Str::ulid(),
                'key' => 'kv_motion_create',
                'credits' => 25,
                'created_at' => $now,
                'updated_at' => $now,
            ],
        ]);
    }

    public function down(): void
    {
        Schema::dropIfExists('credit_prices');
    }
};
```

- [ ] **Step 4: Write the model**

```php
<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Concerns\HasUlids;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Facades\Log;

/**
 * A whole-number credit price for one KV action, editable by a superadmin
 * under Admin -> Financials -> KV Generator Pricing.
 *
 * Read live on every charge — see the migration for why there is no cache.
 */
class CreditPrice extends Model
{
    use HasUlids;

    /** Resize of a layer-composed (PSD-import) board, per size produced. */
    public const KEY_RESIZE_OVERLAY_ONLY = 'kv_resize_overlay_only';

    /** Creating a Motion project, per size checked in the picker. */
    public const KEY_MOTION_CREATE = 'kv_motion_create';

    /**
     * The prices that apply when no row has been written — and the ONLY place
     * a number may be hardcoded.
     *
     * @var array<string,int>
     */
    public const DEFAULTS = [
        self::KEY_RESIZE_OVERLAY_ONLY => 5,
        self::KEY_MOTION_CREATE => 25,
    ];

    protected $fillable = ['key', 'credits', 'updated_by'];

    protected function casts(): array
    {
        return ['credits' => 'integer'];
    }

    /**
     * The price in force right now.
     *
     * FAILS TO THE CODE DEFAULT, never to 0. A missing row or a database blip
     * must not silently turn a paid feature free — that is the exact failure
     * this whole change exists to remove. An unknown key returns 0, because a
     * key with no default is not a price we charge.
     */
    public static function credits(string $key): int
    {
        $default = self::DEFAULTS[$key] ?? 0;

        try {
            $stored = static::query()->where('key', $key)->value('credits');

            return $stored === null ? $default : (int) $stored;
        } catch (\Throwable $e) {
            Log::warning('CreditPrice: could not read price, falling back to code default', [
                'key' => $key,
                'default' => $default,
                'error' => $e->getMessage(),
            ]);

            return $default;
        }
    }

    public static function set(string $key, int $credits, ?string $userId = null): self
    {
        return static::updateOrCreate(
            ['key' => $key],
            ['credits' => max(0, $credits), 'updated_by' => $userId],
        );
    }

    /**
     * Every known key with the value in force, for the admin list and the
     * public pricing endpoint.
     *
     * @return array<string,int>
     */
    public static function effective(): array
    {
        $out = [];
        foreach (array_keys(self::DEFAULTS) as $key) {
            $out[$key] = self::credits($key);
        }

        return $out;
    }
}
```

- [ ] **Step 5: Run the migration and the test**

```bash
cd api && TELESCOPE_ENABLED=false php artisan migrate
php artisan test tests/Unit/Models/CreditPriceTest.php
```

Expected: 6 passing.

- [ ] **Step 6: Commit**

```bash
git add database/migrations/2026_09_29_100000_create_credit_prices_table.php app/Models/CreditPrice.php tests/Unit/Models/CreditPriceTest.php
git commit -m "feat(api): add admin-editable credit_prices store"
```

---

### Task 2: `InsufficientCreditsException`

**Files:**
- Create: `api/app/Exceptions/InsufficientCreditsException.php`
- Test: `api/tests/Unit/Exceptions/InsufficientCreditsExceptionTest.php`

**Interfaces:**
- Consumes: nothing.
- Produces: `new InsufficientCreditsException(int $required, int $available)`, with `->required`, `->available`, and `->render(): JsonResponse` returning HTTP 400 in the shape `{message, errors, data}`.

- [ ] **Step 1: Write the failing test**

```php
<?php

use App\Exceptions\InsufficientCreditsException;
use Tests\TestCase;

uses(TestCase::class);

it('renders the same 400 shape the credit middleware emits', function () {
    $response = (new InsufficientCreditsException(75, 20))->render();

    expect($response->getStatusCode())->toBe(400);

    $body = $response->getData(true);
    expect($body['message'])->toBe('Insufficient user credits')
        ->and($body['errors'])->toContain('75')
        ->and($body['data'])->toBe(['required' => 75, 'available' => 20]);
});

it('carries the numbers for callers that want them', function () {
    $e = new InsufficientCreditsException(75, 20);

    expect($e->required)->toBe(75)->and($e->available)->toBe(20);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd api && php artisan test tests/Unit/Exceptions/InsufficientCreditsExceptionTest.php`
Expected: FAIL — class not found.

- [ ] **Step 3: Write the implementation**

```php
<?php

namespace App\Exceptions;

use Exception;
use Illuminate\Http\JsonResponse;

/**
 * A fixed-price KV action was refused because the user cannot pay for it.
 *
 * Renders to the SAME wire shape `CheckUserCredits` already emits
 * (`errorJsonResponse('Insufficient user credits', ..., 400)`), so web has one
 * insufficient-credits contract to recognise rather than two. It exists as a
 * type because `CreditService::deductCredits()` throws a bare `\Exception`,
 * which a client cannot tell apart from any other failure — and this path has
 * to produce a clear, actionable message.
 */
class InsufficientCreditsException extends Exception
{
    public function __construct(
        public readonly int $required,
        public readonly int $available,
    ) {
        parent::__construct("Insufficient credits: {$required} required, {$available} available.");
    }

    public function render(): JsonResponse
    {
        return response()->json([
            'message' => 'Insufficient user credits',
            'errors' => "This action costs {$this->required} credits and you have {$this->available}. Top up to continue.",
            'data' => ['required' => $this->required, 'available' => $this->available],
        ], 400);
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd api && php artisan test tests/Unit/Exceptions/InsufficientCreditsExceptionTest.php`
Expected: 2 passing.

- [ ] **Step 5: Commit**

```bash
git add app/Exceptions/InsufficientCreditsException.php tests/Unit/Exceptions/InsufficientCreditsExceptionTest.php
git commit -m "feat(api): add typed InsufficientCreditsException"
```

---

### Task 3: `KvFixedPriceChargeService`

**Files:**
- Create: `api/app/Services/Studio/KvFixedPriceChargeService.php`
- Test: `api/tests/Feature/Studio/KvFixedPriceChargeServiceTest.php`

This is a Feature test rather than Unit because it exercises real credit rows, the Extra Credit path and the `CostHistory` write — the exact things Review Focus items 1 and 4 are about, and the parts a mock would render vacuous.

**Interfaces:**
- Consumes: `CreditPrice::credits()` (Task 1), `InsufficientCreditsException` (Task 2).
- Produces:
  - `quote(string $priceKey, int $quantity): int` — total credits, `0` when quantity ≤ 0.
  - `assertAffordable(User $user, Workspace $workspace, int $total): void` — throws `InsufficientCreditsException`; no-op when `$total <= 0`.
  - `charge(User $user, Workspace $workspace, int $total, string $costType, string $toolName, string $batchId, ?string $brandId = null): void` — no-op when `$total <= 0`.

- [ ] **Step 1: Write the failing test**

```php
<?php

namespace Tests\Feature\Studio;

use App\Exceptions\InsufficientCreditsException;
use App\Models\CostHistory;
use App\Models\CreditPrice;
use App\Models\User;
use App\Models\UserWorkspaceCredit;
use App\Models\Workspace;
use App\Models\WorkspaceCredit;
use App\Services\Studio\KvFixedPriceChargeService;
use Illuminate\Foundation\Testing\DatabaseTransactions;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use PHPUnit\Framework\Attributes\Test;
use Tests\TestCase;

/**
 * Runs against the live pgsql connection with DatabaseTransactions, mirroring
 * KvMotionProjectControllerTest — the wider suite's sqlite path cannot run a
 * fresh migrate against this schema.
 */
class KvFixedPriceChargeServiceTest extends TestCase
{
    use DatabaseTransactions;

    protected function setUp(): void
    {
        putenv('DB_CONNECTION=pgsql');
        putenv('DB_DATABASE=frnd_testing');
        $_ENV['DB_CONNECTION'] = 'pgsql';
        $_ENV['DB_DATABASE'] = 'frnd_testing';
        $_SERVER['DB_CONNECTION'] = 'pgsql';
        $_SERVER['DB_DATABASE'] = 'frnd_testing';

        parent::setUp();

        try {
            DB::connection('pgsql')->getPdo();
        } catch (\Throwable) {
            $this->markTestSkipped('Requires a reachable Postgres connection.');
        }
    }

    /** @return array{0: User, 1: Workspace} */
    private function member(int $userCredits, int $poolCredits): array
    {
        $workspace = Workspace::factory()->create(['type' => 'organization']);
        $user = User::factory()->create(['current_workspace_id' => $workspace->id]);
        $user->workspaces()->attach($workspace->id);

        UserWorkspaceCredit::create([
            'user_id' => $user->id,
            'workspace_id' => $workspace->id,
            'credits' => $userCredits,
        ]);
        WorkspaceCredit::create([
            'workspace_id' => $workspace->id,
            'credits' => $poolCredits,
        ]);

        return [$user, $workspace];
    }

    #[Test]
    public function it_quotes_price_times_quantity(): void
    {
        CreditPrice::set(CreditPrice::KEY_MOTION_CREATE, 25);

        $this->assertSame(75, app(KvFixedPriceChargeService::class)
            ->quote(CreditPrice::KEY_MOTION_CREATE, 3));
    }

    #[Test]
    public function it_quotes_zero_for_a_zero_quantity(): void
    {
        $this->assertSame(0, app(KvFixedPriceChargeService::class)
            ->quote(CreditPrice::KEY_MOTION_CREATE, 0));
    }

    #[Test]
    public function it_refuses_when_the_member_cannot_afford_it(): void
    {
        [$user, $workspace] = $this->member(userCredits: 10, poolCredits: 1000);

        $this->expectException(InsufficientCreditsException::class);

        app(KvFixedPriceChargeService::class)
            ->assertAffordable($user, $workspace, 75);
    }

    /** Review Focus 4 — max(1, $cost) inside hasSpendableCredits would refuse this. */
    #[Test]
    public function a_zero_total_is_allowed_for_a_user_with_no_credits(): void
    {
        [$user, $workspace] = $this->member(userCredits: 0, poolCredits: 0);

        app(KvFixedPriceChargeService::class)->assertAffordable($user, $workspace, 0);

        $this->assertTrue(true, 'assertAffordable must not throw on a zero total');
    }

    #[Test]
    public function a_zero_total_writes_no_cost_history_row(): void
    {
        [$user, $workspace] = $this->member(userCredits: 0, poolCredits: 0);
        $batchId = 'kv_resize_overlay_'.Str::ulid();

        app(KvFixedPriceChargeService::class)->charge(
            $user, $workspace, 0, 'kv_resize_overlay_only', 'KV Resize', $batchId,
        );

        $this->assertSame(0, CostHistory::where('batch_identifier', $batchId)->count());
    }

    #[Test]
    public function it_deducts_and_writes_one_audit_row(): void
    {
        [$user, $workspace] = $this->member(userCredits: 100, poolCredits: 100);
        $batchId = 'kv_motion_create_'.Str::ulid();

        app(KvFixedPriceChargeService::class)->charge(
            $user, $workspace, 75, 'kv_motion_create', 'KV Motion', $batchId,
        );

        $row = CostHistory::where('batch_identifier', $batchId)->firstOrFail();

        $this->assertSame('kv_motion_create', $row->cost_type);
        $this->assertSame('deduction', $row->entry_type);
        $this->assertSame(75, (int) $row->system_credit);
        $this->assertSame(0.0, (float) $row->amount);
        $this->assertSame(0, (int) $row->total_tokens);
        $this->assertSame('KV Generator', $row->chat_features);

        $this->assertSame(25, (int) UserWorkspaceCredit::where('user_id', $user->id)
            ->where('workspace_id', $workspace->id)->value('credits'));
    }

    /** Review Focus 2 — charging the same row twice must not double-bill. */
    #[Test]
    public function charging_the_same_batch_id_twice_writes_one_row(): void
    {
        [$user, $workspace] = $this->member(userCredits: 100, poolCredits: 100);
        $batchId = 'kv_motion_create_'.Str::ulid();
        $service = app(KvFixedPriceChargeService::class);

        $service->charge($user, $workspace, 25, 'kv_motion_create', 'KV Motion', $batchId);
        $service->charge($user, $workspace, 25, 'kv_motion_create', 'KV Motion', $batchId);

        $this->assertSame(1, CostHistory::where('batch_identifier', $batchId)->count());
        $this->assertSame(75, (int) UserWorkspaceCredit::where('user_id', $user->id)
            ->where('workspace_id', $workspace->id)->value('credits'));
    }

    /**
     * Review Focus 1 — the single most likely regression.
     *
     * The member's own cap covers the cost but the workspace pool does not.
     * `hasSpendableCredits` admits this when Extra Credit is eligible, and
     * `deductCreditsWithDebt` funds it from Extra Credit. Swapping the funding
     * call for `deductCredits()` makes this test throw.
     */
    #[Test]
    public function a_pool_shortfall_covered_by_extra_credit_is_allowed_and_flagged(): void
    {
        [$user, $workspace] = $this->member(userCredits: 100, poolCredits: 10);
        $workspace->update(['extra_credit_enabled' => true]);
        $this->giveWorkspaceExtraCredit($workspace, 500);
        $this->giveWorkspaceActiveSubscription($workspace);

        $batchId = 'kv_motion_create_'.Str::ulid();
        $service = app(KvFixedPriceChargeService::class);

        $service->assertAffordable($user, $workspace, 75);
        $service->charge($user, $workspace, 75, 'kv_motion_create', 'KV Motion', $batchId);

        $row = CostHistory::where('batch_identifier', $batchId)->firstOrFail();
        $this->assertTrue((bool) $row->is_from_extra_credit);
    }
}
```

- [ ] **Step 2: Write the two Extra-Credit fixture helpers**

`giveWorkspaceExtraCredit()` and `giveWorkspaceActiveSubscription()` do not exist. Before implementing the service, read `CreditService::canDrawExtraCredit()` (`app/Services/CreditService.php:641`) and `availableExtraCredit`, then read an existing test that sets up Extra Credit:

```bash
cd api && grep -rln "extra_credit_enabled" tests/ | head
```

Add the two helpers as private methods on the test class, building whatever rows `canDrawExtraCredit()` requires: an organization workspace, `extra_credit_enabled = true`, and a `SubscriptionHistory` with status `active`. Do not guess the column names — copy them from the existing test you found.

- [ ] **Step 3: Run test to verify it fails**

Run: `cd api && php artisan test tests/Feature/Studio/KvFixedPriceChargeServiceTest.php`
Expected: FAIL — `Class "App\Services\Studio\KvFixedPriceChargeService" not found`.

- [ ] **Step 4: Write the implementation**

```php
<?php

namespace App\Services\Studio;

use App\Exceptions\InsufficientCreditsException;
use App\Models\Brand;
use App\Models\CostHistory;
use App\Models\CreditPrice;
use App\Models\User;
use App\Models\Workspace;
use App\Services\CreditService;
use Illuminate\Database\UniqueConstraintViolationException;
use Illuminate\Support\Facades\DB;

/**
 * Fixed-credit, affordability-gated charging for KV actions whose price is a
 * product decision rather than a vendor invoice.
 *
 * DELIBERATELY SEPARATE FROM {@see KvCreditMeteringService}. That service
 * meters work the AI service has ALREADY DONE: it runs in an internal callback,
 * derives credits from vendor usage, funds through the debt-tolerant path, and
 * swallows every Throwable so a billing failure can never fail a request the
 * user has already been served. This one runs BEFORE the work, prices from an
 * admin-set number, and REFUSES when the user cannot pay.
 *
 * Reach for this one when the action has a fixed price and must not happen
 * unless it is paid for; reach for the other when an external model has already
 * billed us and we are recording it.
 *
 * Gating and funding deliberately use DIFFERENT primitives:
 *   - gate:  CreditService::hasSpendableCredits()  — counts pool + Extra Credit
 *   - fund:  CreditService::deductCreditsWithDebt() — draws pool + Extra Credit
 * `deductCredits()` must NOT be used here: it never draws Extra Credit, so it
 * would throw out a workspace the gate just admitted on its Extra Credit
 * balance — refusing a user who can in fact pay.
 */
class KvFixedPriceChargeService
{
    public function __construct(
        private readonly CreditService $creditService = new CreditService,
    ) {}

    /** Total credits for `$quantity` units of `$priceKey`. */
    public function quote(string $priceKey, int $quantity): int
    {
        if ($quantity <= 0) {
            return 0;
        }

        return CreditPrice::credits($priceKey) * $quantity;
    }

    /**
     * Refuse up front when the user cannot pay.
     *
     * A total of 0 short-circuits: `hasSpendableCredits()` applies
     * `max(1, $cost)`, so passing 0 through would demand one credit and refuse
     * a broke user an action an admin has deliberately priced at free.
     */
    public function assertAffordable(User $user, Workspace $workspace, int $total): void
    {
        if ($total <= 0) {
            return;
        }

        if ($this->creditService->hasSpendableCredits($user, $workspace, $total)) {
            return;
        }

        $available = $this->creditService
            ->getUserWorkspaceCredits($user, $workspace)?->credits ?? 0;

        throw new InsufficientCreditsException($total, (int) $available);
    }

    /**
     * Deduct and write the audit row. Call INSIDE the caller's transaction so a
     * failure here rolls back whatever the charge was paying for.
     *
     * `$batchId` must be derived from the row being paid for
     * (`kv_motion_create_{ulid}`), which makes it unique by construction and
     * makes a repeated charge for the same row a no-op.
     */
    public function charge(
        User $user,
        Workspace $workspace,
        int $total,
        string $costType,
        string $toolName,
        string $batchId,
        ?string $brandId = null,
    ): void {
        if ($total <= 0) {
            return;
        }

        if (CostHistory::where('batch_identifier', $batchId)->exists()) {
            return;
        }

        try {
            $deduction = $this->creditService->deductCreditsWithDebt(
                $user,
                $workspace,
                $total,
                $batchId,
            );

            CostHistory::create([
                'user_id' => $user->id,
                'username' => $user->name,
                'workspace_id' => $workspace->id,
                'brand_id' => $brandId,
                'brand_name' => $brandId ? Brand::query()->whereKey($brandId)->value('name') : null,
                'cost_type' => $costType,
                'entry_type' => 'deduction',
                // No vendor call was made — that is precisely why these paths
                // were free. Recording 0 is accurate; margin analysis correctly
                // shows pure margin rather than an invented cost.
                'amount' => 0.0,
                'actual_credit' => $deduction['credits_deducted'],
                'system_credit' => $total,
                'is_indexed' => true,
                'is_from_extra_credit' => ($deduction['extra_credit_drawn'] ?? 0) > 0,
                'tool_name' => $toolName,
                'prompt_tokens' => 0,
                'completion_tokens' => 0,
                'total_tokens' => 0,
                'batch_identifier' => $batchId,
                'chat_features' => 'KV Generator',
            ]);
        } catch (UniqueConstraintViolationException) {
            // Race-safe: a concurrent request already charged this same row.
        }
    }
}
```

> Note the deliberate absence of a `catch (Throwable)`. `KvCreditMeteringService` swallows everything because it runs after the user has been served. This one runs *before*, inside the caller's transaction — a failure here must roll the work back, not be logged and ignored.

- [ ] **Step 5: Run test to verify it passes**

Run: `cd api && php artisan test tests/Feature/Studio/KvFixedPriceChargeServiceTest.php`
Expected: 8 passing.

- [ ] **Step 6: Commit**

```bash
git add app/Services/Studio/KvFixedPriceChargeService.php tests/Feature/Studio/KvFixedPriceChargeServiceTest.php
git commit -m "feat(api): add KvFixedPriceChargeService for gated fixed-price KV charges"
```

---

### Task 4: Charge layer-composed resize

**Files:**
- Modify: `api/app/Services/Studio/KvResizeExportService.php` — `createBatch()` (~`:34-96`) and `duplicate()` (~`:112`)
- Test: `api/tests/Feature/Studio/KvResizeOverlayChargeTest.php`

**Interfaces:**
- Consumes: `KvFixedPriceChargeService::quote/assertAffordable/charge` (Task 3), `CreditPrice::KEY_RESIZE_OVERLAY_ONLY` (Task 1).
- Produces: no new public signatures. `createBatch()` and `duplicate()` keep their existing signatures and now throw `InsufficientCreditsException`.

- [ ] **Step 1: Write the failing test**

Build the fixture by copying the workspace/user/brand/file setup from `tests/Feature/Studio/KvMotionBumperControllerTest.php`'s `bumperUser()` helper — do not invent factory columns. Add a layer-composed parent generation:

```php
$parent = KvGeneration::factory()->create([
    'studio_file_id' => $file->id,
    'metadata' => ['layer_composed' => true],
]);
```

Tests to write:

```php
#[Test]
public function it_charges_five_per_newly_created_size(): void
{
    [$user, $workspace, $file, $parent] = $this->layerComposedFixture(userCredits: 100, poolCredits: 100);
    CreditPrice::set(CreditPrice::KEY_RESIZE_OVERLAY_ONLY, 5);

    app(KvResizeExportService::class)->createBatch(
        file: $file, parent: $parent,
        platformIds: ['instagram_post', 'instagram_story'],
        cropWindowMap: [], userId: $user->id,
    );

    $this->assertSame(90, (int) UserWorkspaceCredit::where('user_id', $user->id)
        ->where('workspace_id', $workspace->id)->value('credits'));
    $this->assertSame(2, CostHistory::where('cost_type', 'kv_resize_overlay_only')->count());
}

/** Review Focus 2 — firstOrCreate returns existing rows; they must not re-bill. */
#[Test]
public function a_repeat_request_for_existing_sizes_charges_nothing(): void
{
    [$user, $workspace, $file, $parent] = $this->layerComposedFixture(userCredits: 100, poolCredits: 100);
    CreditPrice::set(CreditPrice::KEY_RESIZE_OVERLAY_ONLY, 5);
    $service = app(KvResizeExportService::class);

    $service->createBatch(file: $file, parent: $parent, platformIds: ['instagram_post'],
        cropWindowMap: [], userId: $user->id);
    $service->createBatch(file: $file, parent: $parent, platformIds: ['instagram_post'],
        cropWindowMap: [], userId: $user->id);

    $this->assertSame(95, (int) UserWorkspaceCredit::where('user_id', $user->id)
        ->where('workspace_id', $workspace->id)->value('credits'));
    $this->assertSame(1, CostHistory::where('cost_type', 'kv_resize_overlay_only')->count());
}

/** The affordability check must count only the sizes that will actually be new. */
#[Test]
public function it_prices_a_mixed_request_on_the_new_sizes_only(): void
{
    [$user, $workspace, $file, $parent] = $this->layerComposedFixture(userCredits: 105, poolCredits: 1000);
    CreditPrice::set(CreditPrice::KEY_RESIZE_OVERLAY_ONLY, 5);
    $service = app(KvResizeExportService::class);

    $service->createBatch(file: $file, parent: $parent, platformIds: ['instagram_post'],
        cropWindowMap: [], userId: $user->id);
    $service->createBatch(file: $file, parent: $parent,
        platformIds: ['instagram_post', 'instagram_story'],
        cropWindowMap: [], userId: $user->id);

    $this->assertSame(95, (int) UserWorkspaceCredit::where('user_id', $user->id)
        ->where('workspace_id', $workspace->id)->value('credits'));
}

#[Test]
public function it_refuses_and_creates_nothing_when_unaffordable(): void
{
    [$user, $workspace, $file, $parent] = $this->layerComposedFixture(userCredits: 4, poolCredits: 1000);
    CreditPrice::set(CreditPrice::KEY_RESIZE_OVERLAY_ONLY, 5);

    try {
        app(KvResizeExportService::class)->createBatch(
            file: $file, parent: $parent, platformIds: ['instagram_post'],
            cropWindowMap: [], userId: $user->id,
        );
        $this->fail('Expected InsufficientCreditsException');
    } catch (InsufficientCreditsException) {
        // expected
    }

    $this->assertSame(0, KvResizeExport::where('parent_generation_id', $parent->id)->count());
}

#[Test]
public function an_ai_generated_parent_is_untouched(): void
{
    [$user, $workspace, $file] = $this->fixture(userCredits: 100, poolCredits: 100);
    $parent = KvGeneration::factory()->create([
        'studio_file_id' => $file->id,
        'metadata' => [],
    ]);
    Queue::fake();

    app(KvResizeExportService::class)->createBatch(
        file: $file, parent: $parent, platformIds: ['instagram_post'],
        cropWindowMap: [], userId: $user->id,
    );

    $this->assertSame(100, (int) UserWorkspaceCredit::where('user_id', $user->id)
        ->where('workspace_id', $workspace->id)->value('credits'));
    Queue::assertPushed(ProcessKvResizeExportJob::class);
}

#[Test]
public function duplicating_a_tile_charges_one_size(): void
{
    [$user, $workspace, $file, $parent] = $this->layerComposedFixture(userCredits: 100, poolCredits: 100);
    CreditPrice::set(CreditPrice::KEY_RESIZE_OVERLAY_ONLY, 5);
    $service = app(KvResizeExportService::class);

    $rows = $service->createBatch(file: $file, parent: $parent,
        platformIds: [CustomResizeSize::id(1000, 1000)],
        cropWindowMap: [], userId: $user->id);

    $service->duplicate($rows->first(), $user->id);

    $this->assertSame(90, (int) UserWorkspaceCredit::where('user_id', $user->id)
        ->where('workspace_id', $workspace->id)->value('credits'));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd api && php artisan test tests/Feature/Studio/KvResizeOverlayChargeTest.php`
Expected: FAIL — balances unchanged, no `CostHistory` rows.

- [ ] **Step 3: Change `createBatch()`**

`createBatch` needs the charging user's `User` and `Workspace`, which it does not currently receive — it takes `string $userId`. Resolve them inside rather than changing every caller's signature:

```php
$user = User::findOrFail($userId);
$workspace = $user->currentWorkspace;
```

Then restructure the body. The existing per-platform loop stays exactly as it is; wrap it:

```php
$isLayerComposed = $parent->isLayerComposed();

// Layer-composed resizes are charged a fixed price per NEW size. The count
// must be of sizes that do not yet exist: `firstOrCreate` below returns the
// existing row for a repeat request, and pricing the requested ids would
// re-bill sizes the user already paid for.
$chargeable = 0;
if ($isLayerComposed) {
    $existing = KvResizeExport::where('parent_generation_id', $parent->id)
        ->whereIn('platform_id', $platformIds)
        ->pluck('platform_id')
        ->all();
    $chargeable = count(array_diff($platformIds, $existing));

    $total = $this->charges->quote(CreditPrice::KEY_RESIZE_OVERLAY_ONLY, $chargeable);
    $this->charges->assertAffordable($user, $workspace, $total);
}

return DB::transaction(function () use (...) {
    // ... the existing foreach, unchanged ...

    if ($isLayerComposed) {
        foreach ($rows as $row) {
            if (! $row->wasRecentlyCreated) {
                continue;
            }
            $this->charges->charge(
                $user,
                $workspace,
                $this->charges->quote(CreditPrice::KEY_RESIZE_OVERLAY_ONLY, 1),
                'kv_resize_overlay_only',
                'KV Resize',
                "kv_resize_overlay_{$row->id}",
                $file->brand_id,
            );
        }
    }

    return $rows;
});
```

Charging per row rather than once for the batch is what makes the batch id row-derived, and therefore what makes a retry idempotent.

Inject the service:

```php
public function __construct(
    private readonly KvFixedPriceChargeService $charges = new KvFixedPriceChargeService,
) {}
```

If the class already has a constructor, add the parameter to it rather than replacing it.

- [ ] **Step 4: Change `duplicate()`**

`duplicate()` receives `KvResizeExport $source` and `string $userId`. Custom sizes exist only on layer-composed parents, so every duplicate is chargeable — but assert it rather than assume:

```php
$user = User::findOrFail($userId);
$workspace = $user->currentWorkspace;
$total = $this->charges->quote(CreditPrice::KEY_RESIZE_OVERLAY_ONLY, 1);
$this->charges->assertAffordable($user, $workspace, $total);

// ... existing duplicate logic, which produces $copy ...

$this->charges->charge(
    $user, $workspace, $total, 'kv_resize_overlay_only', 'KV Resize',
    "kv_resize_overlay_{$copy->id}", $source->file?->brand_id,
);
```

The existing docblock says the insert is deliberately not wrapped in a transaction because a unique violation must be retried outside one. **Preserve that.** Charge after the retry loop has produced a row, not around it.

- [ ] **Step 5: Update the stale comment**

`KvResizeExportService.php:~50` says the layer-composed branch means "no model call, no credit". Half of that is now false:

```
// The artwork lives in layers, not in the parent's image_url, so there is
// nothing for the image model to extend. No model call — but NOT free:
// this path is charged a fixed admin-set price per new size
// (CreditPrice::KEY_RESIZE_OVERLAY_ONLY), because the user still walks away
// with a finished, placeable deliverable.
```

Fix the same claim at `KvResizeExportController.php:~146`.

- [ ] **Step 6: Run test to verify it passes**

Run: `cd api && php artisan test tests/Feature/Studio/KvResizeOverlayChargeTest.php`
Expected: 6 passing.

- [ ] **Step 7: Run the neighbouring resize tests for regressions**

```bash
cd api && php artisan test tests/Feature/Studio/KvResizeExportInternalCallbackTest.php tests/Feature/Studio/KvResizeRegionEditTest.php tests/Unit/Models/KvResizeExportMetadataTest.php
```

Expected: no new failures against their state on `develop`.

- [ ] **Step 8: Commit**

```bash
git add app/Services/Studio/KvResizeExportService.php app/Http/Controllers/Api/Studio/KvResizeExportController.php tests/Feature/Studio/KvResizeOverlayChargeTest.php
git commit -m "feat(api): charge layer-composed resize per new size"
```

---

### Task 5: `size_count` and the Motion create charge

**Files:**
- Modify: `api/app/Http/Requests/Studio/StoreKvMotionProjectRequest.php`
- Modify: `api/app/Http/Controllers/Api/Studio/KvMotionProjectController.php:35-60`
- Test: `api/tests/Unit/Requests/KvMotionProjectRequestsTest.php` (append)
- Test: `api/tests/Feature/Studio/KvMotionCreateChargeTest.php`

**Interfaces:**
- Consumes: `KvFixedPriceChargeService` (Task 3), `CreditPrice::KEY_MOTION_CREATE` (Task 1).
- Produces: the POST accepts `size_count` — `integer`, `min:1`, `max:8`, required.

`max:8` matches `MAX_TILES` in `web/src/components/studio/kv-generator/motion/KvMotionSizePicker.tsx:73`.

- [ ] **Step 1: Write the failing request test**

Append to `tests/Unit/Requests/KvMotionProjectRequestsTest.php`:

```php
it('requires size_count on store', function () {
    $v = validateWith(StoreKvMotionProjectRequest::class, [
        'board_generation_id' => '01J00000000000000000000000',
        'snapshot' => ['base_image_url' => 'https://x/y.png', 'overlays' => []],
        'timeline' => ['version' => 1, 'duration_ms' => 5000, 'fps' => 30, 'tracks' => []],
    ]);
    expect($v->fails())->toBeTrue()->and($v->errors()->has('size_count'))->toBeTrue();
});

it('rejects a size_count above the picker maximum', function () {
    $v = validateWith(StoreKvMotionProjectRequest::class, [
        'board_generation_id' => '01J00000000000000000000000',
        'snapshot' => ['base_image_url' => 'https://x/y.png', 'overlays' => []],
        'timeline' => ['version' => 1, 'duration_ms' => 5000, 'fps' => 30, 'tracks' => []],
        'size_count' => 9,
    ]);
    expect($v->fails())->toBeTrue()->and($v->errors()->has('size_count'))->toBeTrue();
});

it('accepts a store payload carrying size_count', function () {
    $v = validateWith(StoreKvMotionProjectRequest::class, [
        'board_generation_id' => '01J00000000000000000000000',
        'snapshot' => ['base_image_url' => 'https://x/y.png', 'overlays' => []],
        'timeline' => ['version' => 1, 'duration_ms' => 5000, 'fps' => 30, 'tracks' => []],
        'size_count' => 3,
    ]);
    expect($v->passes())->toBeTrue();
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd api && php artisan test tests/Unit/Requests/KvMotionProjectRequestsTest.php`
Expected: the two new rejection tests FAIL (validation currently passes without `size_count`).

- [ ] **Step 3: Add the rule**

In `StoreKvMotionProjectRequest::rules()`:

```php
// The BILLED quantity. Deliberately its own validated field rather than
// derived from `snapshot.tiles`: `snapshot` is opaque JSON this api promises
// not to interpret (see the rule below), so pricing off its internals would
// let a web-side refactor silently change what users are charged. Upper bound
// mirrors MAX_TILES in the web size picker.
'size_count' => ['required', 'integer', 'min:1', 'max:8'],
```

- [ ] **Step 4: Run it to verify it passes**

Run: `cd api && php artisan test tests/Unit/Requests/KvMotionProjectRequestsTest.php`
Expected: all passing.

- [ ] **Step 5: Write the failing controller test**

Create `tests/Feature/Studio/KvMotionCreateChargeTest.php`, copying the `setUp()` and fixture helpers from `tests/Feature/Studio/KvMotionProjectControllerTest.php` verbatim — same middleware stubs, same pgsql override.

```php
#[Test]
public function it_charges_price_times_size_count(): void
{
    [$user, $file, $workspace] = $this->motionUser(userCredits: 100, poolCredits: 100);
    CreditPrice::set(CreditPrice::KEY_MOTION_CREATE, 25);

    $this->actingAs($user, 'api')
        ->postJson("/api/v1/studio/files/{$file->id}/motion-projects", $this->payload(sizeCount: 3))
        ->assertCreated();

    $this->assertSame(25, (int) UserWorkspaceCredit::where('user_id', $user->id)
        ->where('workspace_id', $workspace->id)->value('credits'));
    $this->assertSame(1, CostHistory::where('cost_type', 'kv_motion_create')->count());
}

#[Test]
public function it_refuses_and_creates_no_project_when_unaffordable(): void
{
    [$user, $file, $workspace] = $this->motionUser(userCredits: 10, poolCredits: 1000);
    CreditPrice::set(CreditPrice::KEY_MOTION_CREATE, 25);

    $this->actingAs($user, 'api')
        ->postJson("/api/v1/studio/files/{$file->id}/motion-projects", $this->payload(sizeCount: 3))
        ->assertStatus(400)
        ->assertJsonPath('message', 'Insufficient user credits')
        ->assertJsonPath('data.required', 75);

    $this->assertSame(0, KvMotionProject::where('studio_file_id', $file->id)->count());
    $this->assertSame(10, (int) UserWorkspaceCredit::where('user_id', $user->id)
        ->where('workspace_id', $workspace->id)->value('credits'));
}

/** Review Focus 5 — web must not be able to under-report the billed quantity. */
#[Test]
public function it_rejects_a_size_count_that_disagrees_with_the_snapshot_tiles(): void
{
    [$user, $file] = $this->motionUser(userCredits: 1000, poolCredits: 1000);

    $payload = $this->payload(sizeCount: 1);
    $payload['snapshot']['tiles'] = [['id' => 'a'], ['id' => 'b'], ['id' => 'c']];

    $this->actingAs($user, 'api')
        ->postJson("/api/v1/studio/files/{$file->id}/motion-projects", $payload)
        ->assertStatus(422)
        ->assertJsonValidationErrors('size_count');

    $this->assertSame(0, KvMotionProject::where('studio_file_id', $file->id)->count());
}

#[Test]
public function a_snapshot_without_tiles_is_accepted_as_a_single_size(): void
{
    [$user, $file, $workspace] = $this->motionUser(userCredits: 100, poolCredits: 100);
    CreditPrice::set(CreditPrice::KEY_MOTION_CREATE, 25);

    $payload = $this->payload(sizeCount: 1);
    unset($payload['snapshot']['tiles']);

    $this->actingAs($user, 'api')
        ->postJson("/api/v1/studio/files/{$file->id}/motion-projects", $payload)
        ->assertCreated();

    $this->assertSame(75, (int) UserWorkspaceCredit::where('user_id', $user->id)
        ->where('workspace_id', $workspace->id)->value('credits'));
}

#[Test]
public function creating_an_export_never_charges(): void
{
    [$user, $file] = $this->motionUser(userCredits: 1000, poolCredits: 1000);
    CreditPrice::set(CreditPrice::KEY_MOTION_CREATE, 25);

    $created = $this->actingAs($user, 'api')
        ->postJson("/api/v1/studio/files/{$file->id}/motion-projects", $this->payload(sizeCount: 1))
        ->json('data.id');

    $before = CostHistory::count();

    $this->actingAs($user, 'api')->postJson(
        "/api/v1/studio/files/{$file->id}/motion-projects/{$created}/exports",
        $this->exportPayload(),
    );

    $this->assertSame($before, CostHistory::count());
}
```

Copy `exportPayload()` from the shape `StoreKvMotionExportRequest` requires.

- [ ] **Step 6: Run it to verify it fails**

Run: `cd api && php artisan test tests/Feature/Studio/KvMotionCreateChargeTest.php`
Expected: FAIL — no charge, 201 where 400 is expected.

- [ ] **Step 7: Change the controller**

Inject `KvFixedPriceChargeService`, then in `store()`, before `KvMotionProject::create`:

```php
$sizeCount = (int) $v['size_count'];

// Cross-check against the snapshot when it carries tiles. `size_count` is the
// billed quantity and `snapshot.tiles` is what actually gets animated; if they
// disagree, one of them is wrong and we must not guess which.
$tiles = $v['snapshot']['tiles'] ?? null;
if (is_array($tiles) && count($tiles) !== $sizeCount) {
    throw ValidationException::withMessages([
        'size_count' => 'size_count must match the number of tiles in the snapshot.',
    ]);
}

$total = $this->charges->quote(CreditPrice::KEY_MOTION_CREATE, $sizeCount);
$this->charges->assertAffordable($request->user(), $request->user()->currentWorkspace, $total);

$row = DB::transaction(function () use (...) {
    $row = KvMotionProject::create([... unchanged ...]);

    // Inside the transaction, AFTER the insert: the charge's idempotency key
    // is derived from the row, and a deduction failure here rolls the project
    // back so an unaffordable create leaves nothing behind.
    $this->charges->charge(
        $request->user(),
        $request->user()->currentWorkspace,
        $total,
        'kv_motion_create',
        'KV Motion',
        "kv_motion_create_{$row->id}",
        $file->brand_id,
    );

    return $row;
});
```

- [ ] **Step 8: Run it to verify it passes**

Run: `cd api && php artisan test tests/Feature/Studio/KvMotionCreateChargeTest.php tests/Feature/Studio/KvMotionProjectControllerTest.php`
Expected: the new file passes; `KvMotionProjectControllerTest` will have failures where its payloads lack `size_count` — **add `'size_count' => 1` to those payloads**, since the field is now required.

- [ ] **Step 9: Commit**

```bash
git add app/Http/Requests/Studio/StoreKvMotionProjectRequest.php app/Http/Controllers/Api/Studio/KvMotionProjectController.php tests/Unit/Requests/KvMotionProjectRequestsTest.php tests/Feature/Studio/KvMotionCreateChargeTest.php tests/Feature/Studio/KvMotionProjectControllerTest.php
git commit -m "feat(api): charge for creating a Motion, per size"
```

---

### Task 6: Public pricing endpoint

**Files:**
- Create: `api/app/Http/Controllers/Api/Studio/KvPricingController.php`
- Modify: `api/routes/api.php`
- Test: `api/tests/Feature/Studio/KvPricingEndpointTest.php`

**Interfaces:**
- Consumes: `CreditPrice::effective()` (Task 1).
- Produces: `GET v1/studio/kv/pricing` → `{"data": {"kv_resize_overlay_only": 5, "kv_motion_create": 25}}`.

- [ ] **Step 1: Write the failing test**

```php
#[Test]
public function it_returns_the_prices_in_force(): void
{
    [$user] = $this->pricingUser();
    CreditPrice::set(CreditPrice::KEY_MOTION_CREATE, 30);

    $this->actingAs($user, 'api')
        ->getJson('/api/v1/studio/kv/pricing')
        ->assertOk()
        ->assertJsonPath('data.kv_motion_create', 30)
        ->assertJsonPath('data.kv_resize_overlay_only', 5);
}

#[Test]
public function it_requires_authentication(): void
{
    $this->getJson('/api/v1/studio/kv/pricing')->assertUnauthorized();
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd api && php artisan test tests/Feature/Studio/KvPricingEndpointTest.php`
Expected: FAIL — 404.

- [ ] **Step 3: Write the controller**

```php
<?php

namespace App\Http\Controllers\Api\Studio;

use App\Http\Controllers\Controller;
use App\Models\CreditPrice;
use Illuminate\Http\JsonResponse;

/**
 * Fixed KV prices, for the estimate the user sees BEFORE they spend.
 *
 * Exists so no price is ever written into web source: the number on the button
 * and the number deducted must come from the same row, or the estimate is
 * decorative rather than a quote.
 */
class KvPricingController extends Controller
{
    public function index(): JsonResponse
    {
        return response()->json(['data' => CreditPrice::effective()]);
    }
}
```

- [ ] **Step 4: Add the route**

In `routes/api.php`, inside the same studio/kv-generator group that holds the motion-project routes (~line 4900), beside them:

```php
// Fixed KV prices for pre-spend estimates. Read-only; admins edit these
// under v1/admin/credit-prices.
Route::get('kv/pricing', [KvPricingController::class, 'index']);
```

Add the `use App\Http\Controllers\Api\Studio\KvPricingController;` import at the top.

- [ ] **Step 5: Run it to verify it passes**

Run: `cd api && php artisan test tests/Feature/Studio/KvPricingEndpointTest.php`
Expected: 2 passing.

> If the route 404s or 405s despite existing, the route cache is stale. **Delete** `bootstrap/cache/routes-*.php` rather than rebuilding it, and probe the running server rather than trusting a restart.

- [ ] **Step 6: Commit**

```bash
git add app/Http/Controllers/Api/Studio/KvPricingController.php routes/api.php tests/Feature/Studio/KvPricingEndpointTest.php
git commit -m "feat(api): expose fixed KV prices for pre-spend estimates"
```

---

### Task 7: Admin endpoints with audit logging

**Files:**
- Create: `api/app/Http/Controllers/Api/Admin/CreditPriceController.php`
- Modify: `api/routes/api.php`
- Test: `api/tests/Feature/Admin/CreditPriceAdminTest.php`

**Interfaces:**
- Consumes: `CreditPrice::effective()` / `::set()` (Task 1), `AuditLogService::log()`.
- Produces:
  - `GET v1/admin/credit-prices` → `{"data": [{key, label, description, credits, unit}]}`
  - `PATCH v1/admin/credit-prices/{key}` body `{credits: int}` → `{"message", "data": {key, credits}}`

- [ ] **Step 1: Write the failing test**

```php
#[Test]
public function a_superadmin_can_change_a_price(): void
{
    $admin = $this->superadmin();

    $this->actingAs($admin, 'api')
        ->patchJson('/api/v1/admin/credit-prices/kv_motion_create', ['credits' => 30])
        ->assertOk()
        ->assertJsonPath('data.credits', 30);

    $this->assertSame(30, CreditPrice::credits(CreditPrice::KEY_MOTION_CREATE));
}

#[Test]
public function it_writes_an_audit_row_with_both_states(): void
{
    $admin = $this->superadmin();
    CreditPrice::set(CreditPrice::KEY_MOTION_CREATE, 25);

    $this->actingAs($admin, 'api')
        ->patchJson('/api/v1/admin/credit-prices/kv_motion_create', ['credits' => 30])
        ->assertOk();

    $log = AuditLog::where('action_type', 'credit_price.update')->latest()->firstOrFail();

    $this->assertSame('kv_motion_create', $log->resource_id);
    $this->assertSame(25, $log->before_state['credits']);
    $this->assertSame(30, $log->after_state['credits']);
    $this->assertSame($admin->id, $log->admin_user_id);
}

#[Test]
public function it_rejects_a_negative_price(): void
{
    $this->actingAs($this->superadmin(), 'api')
        ->patchJson('/api/v1/admin/credit-prices/kv_motion_create', ['credits' => -1])
        ->assertStatus(422)
        ->assertJsonValidationErrors('credits');
}

#[Test]
public function it_accepts_zero_as_free(): void
{
    $this->actingAs($this->superadmin(), 'api')
        ->patchJson('/api/v1/admin/credit-prices/kv_motion_create', ['credits' => 0])
        ->assertOk();

    $this->assertSame(0, CreditPrice::credits(CreditPrice::KEY_MOTION_CREATE));
}

#[Test]
public function it_404s_an_unknown_key(): void
{
    $this->actingAs($this->superadmin(), 'api')
        ->patchJson('/api/v1/admin/credit-prices/kv_nonsense', ['credits' => 5])
        ->assertNotFound();
}
```

Build `superadmin()` by copying the superadmin fixture from an existing admin test — find one with:

```bash
cd api && grep -rln "admin/feature-configurations\|superadmin" tests/Feature | head
```

Do not stub the `superadmin` middleware away in the authorisation test below; stub it only where it is not the subject.

- [ ] **Step 2: Add the non-superadmin rejection test**

```php
#[Test]
public function a_non_superadmin_cannot_change_a_price(): void
{
    $user = User::factory()->create();

    $this->actingAs($user, 'api')
        ->patchJson('/api/v1/admin/credit-prices/kv_motion_create', ['credits' => 1])
        ->assertForbidden();

    $this->assertSame(25, CreditPrice::credits(CreditPrice::KEY_MOTION_CREATE));
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `cd api && php artisan test tests/Feature/Admin/CreditPriceAdminTest.php`
Expected: FAIL — 404 on every route.

- [ ] **Step 4: Write the controller**

```php
<?php

namespace App\Http\Controllers\Api\Admin;

use App\Http\Controllers\Controller;
use App\Models\CreditPrice;
use App\Services\AuditLogService;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;

/**
 * Superadmin: fixed credit prices for KV actions
 * (Admin -> Financials -> KV Generator Pricing).
 *
 * Audit-logged through AuditLogService, NOT a bare Log::info — a price change
 * moves money, so "who changed it, old value -> new value, when" has to land in
 * the Audit Log the admin panel already renders. (FeatureConfigurationController
 * is the structural model for this controller, but not the audit model: it only
 * writes a log line.)
 */
class CreditPriceController extends Controller
{
    /** Human copy for the admin form, keyed by price key. */
    private const META = [
        CreditPrice::KEY_RESIZE_OVERLAY_ONLY => [
            'label' => 'Resize — full overlay only (no AI)',
            'description' => 'Charged when a board built entirely from imported layers (PSD import) is resized. '
                .'No image model runs on this path, but the user still receives a finished, placeable asset.',
            'unit' => 'credits per size',
        ],
        CreditPrice::KEY_MOTION_CREATE => [
            'label' => 'Motion — create',
            'description' => 'Charged once when Create motion is pressed, multiplied by the number of sizes checked. '
                .'Exporting the video afterwards is never charged again.',
            'unit' => 'credits per size',
        ],
    ];

    public function __construct(
        protected AuditLogService $auditLogService,
    ) {}

    public function index(): JsonResponse
    {
        $data = [];
        foreach (CreditPrice::effective() as $key => $credits) {
            $data[] = ['key' => $key, 'credits' => $credits] + self::META[$key];
        }

        return response()->json([
            'message' => 'Credit prices retrieved successfully',
            'data' => $data,
        ]);
    }

    public function update(Request $request, string $key): JsonResponse
    {
        if (! array_key_exists($key, self::META)) {
            return response()->json(['message' => 'Unknown credit price'], 404);
        }

        $validated = $request->validate([
            'credits' => ['required', 'integer', 'min:0', 'max:100000'],
        ]);

        $before = CreditPrice::credits($key);
        $after = (int) $validated['credits'];

        CreditPrice::set($key, $after, $request->user()?->id);

        $this->auditLogService->log($request->user(), [
            'action_type' => 'credit_price.update',
            'resource_type' => 'credit_price',
            'resource_id' => $key,
            'before_state' => ['credits' => $before],
            'after_state' => ['credits' => $after],
        ], $request);

        return response()->json([
            'message' => 'Credit price updated successfully',
            'data' => ['key' => $key, 'credits' => $after],
        ]);
    }
}
```

- [ ] **Step 5: Add the routes**

In `routes/api.php`, inside the existing
`Route::prefix('admin')->middleware(['auth:api', 'scope_role:internal', 'superadmin'])` group (~line 6173), directly after the `feature-configurations` pair:

```php
// KV Generator fixed pricing — Admin -> Financials -> KV Generator Pricing.
Route::get('/credit-prices', [CreditPriceController::class, 'index']);
Route::patch('/credit-prices/{key}', [CreditPriceController::class, 'update']);
```

Add `use App\Http\Controllers\Api\Admin\CreditPriceController;` at the top.

- [ ] **Step 6: Run it to verify it passes**

Run: `cd api && php artisan test tests/Feature/Admin/CreditPriceAdminTest.php`
Expected: 6 passing.

- [ ] **Step 7: Commit**

```bash
git add app/Http/Controllers/Api/Admin/CreditPriceController.php routes/api.php tests/Feature/Admin/CreditPriceAdminTest.php
git commit -m "feat(api): admin CRUD for KV fixed prices, audit-logged"
```

---

### Task 8: Full-surface regression run

- [ ] **Step 1: Run every test this change touches**

```bash
cd api && php artisan test \
  tests/Unit/Models/CreditPriceTest.php \
  tests/Unit/Exceptions/InsufficientCreditsExceptionTest.php \
  tests/Unit/Requests/KvMotionProjectRequestsTest.php \
  tests/Feature/Studio/KvFixedPriceChargeServiceTest.php \
  tests/Feature/Studio/KvResizeOverlayChargeTest.php \
  tests/Feature/Studio/KvMotionCreateChargeTest.php \
  tests/Feature/Studio/KvMotionProjectControllerTest.php \
  tests/Feature/Studio/KvPricingEndpointTest.php \
  tests/Feature/Admin/CreditPriceAdminTest.php \
  tests/Feature/Studio/KvResizeExportInternalCallbackTest.php
```

Expected: all green. Any red in `KvResizeExportInternalCallbackTest` means the AI path was disturbed — that path must be byte-for-byte unchanged in behaviour.

- [ ] **Step 2: Confirm no new lint findings**

```bash
cd api && ./vendor/bin/pint --test app/Models/CreditPrice.php app/Exceptions/InsufficientCreditsException.php app/Services/Studio/KvFixedPriceChargeService.php app/Http/Controllers/Api/Studio/KvPricingController.php app/Http/Controllers/Api/Admin/CreditPriceController.php
```

Never `git stash` to compare against a baseline — use a separate worktree at `develop` if you need one.

- [ ] **Step 3: Commit any fixes and stop**

The web plan depends on `GET v1/studio/kv/pricing` and the admin endpoints existing. Do not start it until this plan is green.
