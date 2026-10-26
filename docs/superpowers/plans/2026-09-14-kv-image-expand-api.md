# KV Expand Image — api Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `kv_image_expands` row + `POST/GET files/{fileId}/image-expands` + the ai-service dispatch job + the internal completion callback that stores the result and charges credits from gpt-image-2 token usage.

**Architecture:** File-for-file clone of the KV background-removal feature (`KvBackgroundRemoval*`): enum, model, factory, migration, resource, create request, service, queued job, public controller, internal callback controller, complete request, routes, config. The only new shape is the `placement` JSON column and its containment validation, and the callback charging via `KvCreditMeteringService::charge()` (token-based, as resize does) instead of `chargeBackgroundRemoval()` (megapixel-based).

**Tech Stack:** Laravel 13 / PHP 8.5, Pest, Postgres scratch DB.

**Spec:** `docs/superpowers/specs/2026-09-14-kv-image-expand-design.md` (workspace root) — §3 placement contract, §5 api, §7 error handling, §8 testing.

## Global Constraints

- Placement keys: `canvas_w, canvas_h, image_x, image_y` — integers, natural pixels of the source. `canvas_* ≤ 4096`, `image_* ≥ 0`, `image_x + source_w ≤ canvas_w`, `image_y + source_h ≤ canvas_h`.
- `excludeUnvalidatedArrayKeys` is on in this repo: **every** `placement.*` key must have its own rule, and the containment check goes in `withValidator()` (no rule key → nothing stripped). Regression-assert all four keys survive `validated()`.
- Feature-flag key: `show-kv-image-expand` (same string the web uses), middleware `feature.flag:show-kv-image-expand,off`. Non-production is force-on inside `FeatureFlag` middleware, so tests pass without PostHog.
- Rate limit: `config('studio.image_expand_rate_limit_per_hour', 30)`, key `image-expand-start:{userId}`.
- Job: `Http::timeout(60)->post("{$aiUrl}/ai/kv-image-expand/run", ...)`, **no `Http::retry()`** (it throws → `failed()` check becomes dead code; each retry is a billed vendor run).
- Charge: `KvCreditMeteringService::charge(costType:'kv_image_expand', toolName:'KV Expand Image', batchId:"kv_image_expand_{$row->id}", model, tokenUsage, brandId)`; empty usage → warning + skip (existing behaviour).
- Watchdog: `STALE_AFTER_MINUTES = 10`.
- Tests: run by **file path** against a scratch Postgres DB, never the dev DB:
  ```
  cd api && DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 \
    TELESCOPE_ENABLED=false php artisan test --compact <path>
  ```
  If `bootstrap/cache/config.php` or `bootstrap/cache/routes-v7.php` exist, move them aside first and restore after (a cached config points tests at the dev DB). Check `psql -lqt | grep frnd_test` before assuming the scratch DB exists; create with `psql -d postgres -c 'CREATE DATABASE frnd_test'` if missing.
- Work on branch `feature/daffa/vc-kv-image-expand` cut from `develop`. Commit per task; do not push.

---

### Task 0: Branch

- [ ] **Step 1: Create the branch**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
git checkout develop && git pull --rebase origin develop
git checkout -b feature/daffa/vc-kv-image-expand
```

---

### Task 1: Enum, migration, model, factory

**Files:**
- Create: `api/app/Enums/KvImageExpandStatus.php`
- Create: `api/database/migrations/2026_09_14_100000_create_kv_image_expands_table.php`
- Create: `api/app/Models/KvImageExpand.php`
- Create: `api/database/factories/KvImageExpandFactory.php`
- Test: `api/tests/Feature/Studio/KvImageExpandModelTest.php`

**Interfaces:**
- Produces: `KvImageExpandStatus::{Pending,Generating,Done,Failed}`; `KvImageExpand` model with fillable `studio_file_id, created_by, source_image_url, source_w, source_h, placement, image_url, width, height, model_version, token_usage, status, error_message`, casts `placement:array`, `token_usage:array`, relations `file()`, `creator()`; factory states `done()`, `generating()`, `failed()`.

- [ ] **Step 1: Write the failing test**

```php
<?php
// api/tests/Feature/Studio/KvImageExpandModelTest.php

use App\Enums\KvImageExpandStatus;
use App\Models\KvImageExpand;

it('round-trips placement and token_usage as arrays', function () {
    $row = KvImageExpand::factory()->create([
        'placement' => ['canvas_w' => 640, 'canvas_h' => 360, 'image_x' => 120, 'image_y' => 30],
    ]);

    $fresh = KvImageExpand::find($row->id);
    expect($fresh->placement)->toBe(['canvas_w' => 640, 'canvas_h' => 360, 'image_x' => 120, 'image_y' => 30]);
    expect($fresh->status)->toBe(KvImageExpandStatus::Pending);
    expect($fresh->token_usage)->toBeNull();
    expect($fresh->file)->not->toBeNull();
    expect($fresh->creator)->not->toBeNull();
});

it('factory done state carries a result and usage', function () {
    $row = KvImageExpand::factory()->done()->create();

    expect($row->status)->toBe(KvImageExpandStatus::Done);
    expect($row->image_url)->toBe('https://example.com/expanded.png');
    expect($row->token_usage['output_image_tokens'])->toBe(1290);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd api && DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false php artisan test --compact tests/Feature/Studio/KvImageExpandModelTest.php`
Expected: FAIL — `Class "App\Models\KvImageExpand" not found`

- [ ] **Step 3: Write enum, migration, model, factory**

```php
<?php
// api/app/Enums/KvImageExpandStatus.php

namespace App\Enums;

enum KvImageExpandStatus: string
{
    case Pending = 'pending';
    case Generating = 'generating';
    case Done = 'done';
    case Failed = 'failed';
}
```

```php
<?php
// api/database/migrations/2026_09_14_100000_create_kv_image_expands_table.php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('kv_image_expands', function (Blueprint $t) {
            $t->ulid('id')->primary();
            // File-scoped like kv_background_removals: the source is an
            // OVERLAY's image, which lives in the collaborative doc, not in
            // an API table — so the row carries the raw source URL.
            $t->foreignUlid('studio_file_id')->constrained('studio_files')->cascadeOnDelete();
            $t->foreignUlid('created_by')->constrained('users')->cascadeOnDelete();

            // Inbound and arbitrary (presigned / deep-keyed S3 URL) — same
            // 2048 as kv_background_removals.
            $t->string('source_image_url', 2048);
            // Natural size the web measured; the placement below is in these
            // pixels. Persisted so a support query can reconstruct the run.
            $t->unsignedInteger('source_w');
            $t->unsignedInteger('source_h');
            // {canvas_w, canvas_h, image_x, image_y}
            $t->jsonb('placement');

            $t->unsignedInteger('width')->nullable();
            $t->unsignedInteger('height')->nullable();
            // Ours, short key shape ({env}/kv-image-expands/{ulid}.png).
            $t->string('image_url')->nullable();
            $t->string('model_version', 64)->nullable();
            // gpt-image-2 usage from the completion callback — the metering
            // input. Kept on the row for auditability of the charge.
            $t->jsonb('token_usage')->nullable();

            $t->string('status', 16)->default('pending');
            $t->text('error_message')->nullable();

            $t->timestamps();
            $t->softDeletes();

            $t->index(['studio_file_id', 'status'], 'kv_image_expands_file_status_idx');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('kv_image_expands');
    }
};
```

```php
<?php
// api/app/Models/KvImageExpand.php

namespace App\Models;

use App\Enums\KvImageExpandStatus;
use Illuminate\Database\Eloquent\Concerns\HasUlids;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\SoftDeletes;

class KvImageExpand extends Model
{
    use HasFactory, HasUlids, SoftDeletes;

    protected $table = 'kv_image_expands';

    protected $fillable = [
        'studio_file_id',
        'created_by',
        'source_image_url',
        'source_w',
        'source_h',
        'placement',
        'image_url',
        'width',
        'height',
        'model_version',
        'token_usage',
        'status',
        'error_message',
    ];

    protected $casts = [
        'source_w' => 'integer',
        'source_h' => 'integer',
        'placement' => 'array',
        'width' => 'integer',
        'height' => 'integer',
        'token_usage' => 'array',
        'status' => KvImageExpandStatus::class,
    ];

    public function file(): BelongsTo
    {
        return $this->belongsTo(StudioFile::class, 'studio_file_id');
    }

    public function creator(): BelongsTo
    {
        return $this->belongsTo(User::class, 'created_by');
    }
}
```

```php
<?php
// api/database/factories/KvImageExpandFactory.php

namespace Database\Factories;

use App\Enums\KvImageExpandStatus;
use App\Models\KvImageExpand;
use App\Models\StudioFile;
use App\Models\User;
use Illuminate\Database\Eloquent\Factories\Factory;

class KvImageExpandFactory extends Factory
{
    protected $model = KvImageExpand::class;

    public function definition(): array
    {
        return [
            'studio_file_id' => StudioFile::factory(),
            'created_by' => User::factory(),
            'source_image_url' => 'https://example.com/source.png',
            'source_w' => 400,
            'source_h' => 300,
            'placement' => ['canvas_w' => 640, 'canvas_h' => 360, 'image_x' => 120, 'image_y' => 30],
            'width' => null,
            'height' => null,
            'image_url' => null,
            'model_version' => null,
            'token_usage' => null,
            'status' => KvImageExpandStatus::Pending,
            'error_message' => null,
        ];
    }

    public function done(string $imageUrl = 'https://example.com/expanded.png'): self
    {
        return $this->state(fn () => [
            'status' => KvImageExpandStatus::Done,
            'image_url' => $imageUrl,
            'width' => 640,
            'height' => 360,
            'model_version' => 'gpt-image-2',
            'token_usage' => [
                'input_text_tokens' => 10,
                'input_image_tokens' => 200,
                'output_image_tokens' => 1290,
                'output_text_tokens' => 0,
            ],
        ]);
    }

    public function generating(): self
    {
        return $this->state(fn () => ['status' => KvImageExpandStatus::Generating]);
    }

    public function failed(string $error = 'Test failure'): self
    {
        return $this->state(fn () => [
            'status' => KvImageExpandStatus::Failed,
            'error_message' => $error,
        ]);
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: same command as Step 2.
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add app/Enums/KvImageExpandStatus.php database/migrations/2026_09_14_100000_create_kv_image_expands_table.php app/Models/KvImageExpand.php database/factories/KvImageExpandFactory.php tests/Feature/Studio/KvImageExpandModelTest.php
git commit -m "feat(api): kv_image_expands table, model, factory

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Service + job

**Files:**
- Create: `api/app/Services/Studio/KvImageExpandService.php`
- Create: `api/app/Jobs/Studio/ProcessKvImageExpandJob.php`
- Test: `api/tests/Unit/Studio/KvImageExpandServiceTest.php`
- Test: `api/tests/Feature/Studio/ProcessKvImageExpandJobTest.php`

**Interfaces:**
- Produces: `KvImageExpandService::create(StudioFile $file, string $sourceImageUrl, int $sourceW, int $sourceH, array $placement, string $userId): KvImageExpand`, `dispatchToAi`, `markGenerating`, `markDone(row, imageUrl, width, height, modelVersion, tokenUsage)`, `markFailed(row, msg)`, `failStale(StudioFile): int`, `STALE_AFTER_MINUTES = 10`; `ProcessKvImageExpandJob(string $imageExpandId)`.

- [ ] **Step 1: Write the failing tests**

```php
<?php
// api/tests/Unit/Studio/KvImageExpandServiceTest.php

use App\Enums\KvImageExpandStatus;
use App\Models\KvImageExpand;
use App\Models\StudioFile;
use App\Services\Studio\KvImageExpandService;

it('markDone stores result fields and clears error', function () {
    $row = KvImageExpand::factory()->generating()->create(['error_message' => 'old']);

    app(KvImageExpandService::class)->markDone(
        $row,
        imageUrl: 'https://cdn.example.com/out.png',
        width: 640,
        height: 360,
        modelVersion: 'gpt-image-2',
        tokenUsage: ['output_image_tokens' => 1290],
    );

    $row->refresh();
    expect($row->status)->toBe(KvImageExpandStatus::Done);
    expect($row->image_url)->toBe('https://cdn.example.com/out.png');
    expect($row->width)->toBe(640);
    expect($row->height)->toBe(360);
    expect($row->model_version)->toBe('gpt-image-2');
    expect($row->token_usage)->toBe(['output_image_tokens' => 1290]);
    expect($row->error_message)->toBeNull();
});

it('failStale fails only pending/generating rows older than the watchdog window', function () {
    $file = StudioFile::factory()->create();
    $stale = KvImageExpand::factory()->generating()->create(['studio_file_id' => $file->id]);
    $fresh = KvImageExpand::factory()->generating()->create(['studio_file_id' => $file->id]);
    $done = KvImageExpand::factory()->done()->create(['studio_file_id' => $file->id]);
    KvImageExpand::whereKey($stale->id)->update(['updated_at' => now()->subMinutes(11)]);
    KvImageExpand::whereKey($done->id)->update(['updated_at' => now()->subMinutes(11)]);

    $count = app(KvImageExpandService::class)->failStale($file);

    expect($count)->toBe(1);
    expect($stale->fresh()->status)->toBe(KvImageExpandStatus::Failed);
    expect($stale->fresh()->error_message)->toContain('Timed out');
    expect($fresh->fresh()->status)->toBe(KvImageExpandStatus::Generating);
    expect($done->fresh()->status)->toBe(KvImageExpandStatus::Done);
});
```

```php
<?php
// api/tests/Feature/Studio/ProcessKvImageExpandJobTest.php

use App\Enums\KvImageExpandStatus;
use App\Jobs\Studio\ProcessKvImageExpandJob;
use App\Models\Brand;
use App\Models\KvImageExpand;
use App\Models\StudioFile;
use App\Models\User;
use App\Models\Workspace;
use App\Services\Studio\KvImageExpandService;
use Illuminate\Support\Facades\Http;

function makeExpandRow(): KvImageExpand
{
    $workspace = Workspace::factory()->create();
    $brand = Brand::factory()->create(['workspace_id' => $workspace->id]);
    $creator = User::factory()->create(['current_workspace_id' => $workspace->id]);
    $file = StudioFile::factory()->create([
        'workspace_id' => $workspace->id,
        'brand_id' => $brand->id,
        'created_by' => $creator->id,
        'last_edited_by' => $creator->id,
    ]);

    return KvImageExpand::factory()->create([
        'studio_file_id' => $file->id,
        'created_by' => $creator->id,
        'source_image_url' => 'https://s3.test/source.png',
    ]);
}

it('posts the row, placement and identity to ai-service and marks generating', function () {
    Http::fake(['*' => Http::response(['status' => 'accepted'], 202)]);
    $row = makeExpandRow();

    (new ProcessKvImageExpandJob($row->id))->handle(app(KvImageExpandService::class));

    Http::assertSent(function ($request) use ($row) {
        return str_ends_with($request->url(), '/ai/kv-image-expand/run')
            && $request['image_expand_id'] === $row->id
            && $request['source_image_url'] === 'https://s3.test/source.png'
            && $request['source_w'] === 400
            && $request['source_h'] === 300
            && $request['placement'] === ['canvas_w' => 640, 'canvas_h' => 360, 'image_x' => 120, 'image_y' => 30]
            && $request['user_id'] === $row->created_by
            && $request['user_email'] === $row->creator->email
            && $request['workspace_id'] === $row->file->workspace_id
            && $request['workspace_name'] === $row->file->workspace->name
            && $request['brand_id'] === $row->file->brand_id
            && $request['brand_name'] === $row->file->brand->name;
    });
    expect($row->fresh()->status)->toBe(KvImageExpandStatus::Generating);
});

it('marks failed when ai-service returns non-2xx', function () {
    Http::fake(['*' => Http::response('nope', 500)]);
    $row = makeExpandRow();

    (new ProcessKvImageExpandJob($row->id))->handle(app(KvImageExpandService::class));

    expect($row->fresh()->status)->toBe(KvImageExpandStatus::Failed);
    expect($row->fresh()->error_message)->toBe('AI service error: 500');
});

it('marks failed when ai-service is unreachable', function () {
    Http::fake(fn () => throw new \Illuminate\Http\Client\ConnectionException('refused'));
    $row = makeExpandRow();

    (new ProcessKvImageExpandJob($row->id))->handle(app(KvImageExpandService::class));

    expect($row->fresh()->status)->toBe(KvImageExpandStatus::Failed);
    expect($row->fresh()->error_message)->toContain('AI service unreachable');
});

it('does not reopen a Done row when a redelivered job ultimately fails', function () {
    $row = makeExpandRow();
    $row->update(['status' => KvImageExpandStatus::Done, 'image_url' => 'https://cdn.test/out.png']);

    (new ProcessKvImageExpandJob($row->id))->failed(new \RuntimeException('late'));

    expect($row->fresh()->status)->toBe(KvImageExpandStatus::Done);
    expect($row->fresh()->image_url)->toBe('https://cdn.test/out.png');
});

it('failed() marks a non-Done row failed', function () {
    $row = makeExpandRow();

    (new ProcessKvImageExpandJob($row->id))->failed(new \RuntimeException('late'));

    expect($row->fresh()->status)->toBe(KvImageExpandStatus::Failed);
    expect($row->fresh()->error_message)->toBe('Job failed: late');
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd api && DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false php artisan test --compact tests/Unit/Studio/KvImageExpandServiceTest.php tests/Feature/Studio/ProcessKvImageExpandJobTest.php`
Expected: FAIL — class not found

- [ ] **Step 3: Write the service and job**

```php
<?php
// api/app/Services/Studio/KvImageExpandService.php

namespace App\Services\Studio;

use App\Enums\KvImageExpandStatus;
use App\Jobs\Studio\ProcessKvImageExpandJob;
use App\Models\KvImageExpand;
use App\Models\StudioFile;

// craftsman-ignore: PHP001, PHP002 (no service in this codebase uses strict_types/final; a repo-wide convention change is out of scope here)
class KvImageExpandService
{
    /**
     * gpt-image-2 outpaints in ~20-60s. 10 minutes matches the sibling
     * KvBackgroundRemovalService watchdog — generous over the worst case,
     * still rescues a row whose completion callback never lands.
     */
    public const STALE_AFTER_MINUTES = 10;

    /**
     * Create a fresh row and dispatch it to the ai-service. No idempotency
     * key: re-running the same overlay with a different placement is the
     * normal flow. The controller's rate limiter bounds abuse.
     *
     * @param  array{canvas_w:int,canvas_h:int,image_x:int,image_y:int}  $placement
     */
    public function create(
        StudioFile $file,
        string $sourceImageUrl,
        int $sourceW,
        int $sourceH,
        array $placement,
        string $userId,
    ): KvImageExpand {
        $row = KvImageExpand::create([
            'studio_file_id' => $file->id,
            'created_by' => $userId,
            'source_image_url' => $sourceImageUrl,
            'source_w' => $sourceW,
            'source_h' => $sourceH,
            'placement' => $placement,
            'status' => KvImageExpandStatus::Pending,
        ]);

        $this->dispatchToAi($row);

        return $row;
    }

    public function dispatchToAi(KvImageExpand $row): void
    {
        ProcessKvImageExpandJob::dispatch($row->id);
    }

    public function markGenerating(KvImageExpand $row): void
    {
        $row->update(['status' => KvImageExpandStatus::Generating]);
    }

    /**
     * @param  array<string,int>|null  $tokenUsage
     */
    public function markDone(
        KvImageExpand $row,
        string $imageUrl,
        ?int $width = null,
        ?int $height = null,
        ?string $modelVersion = null,
        ?array $tokenUsage = null,
    ): void {
        $row->update([
            'status' => KvImageExpandStatus::Done,
            'image_url' => $imageUrl,
            'width' => $width,
            'height' => $height,
            'model_version' => $modelVersion,
            'token_usage' => $tokenUsage,
            'error_message' => null,
        ]);
    }

    public function markFailed(KvImageExpand $row, string $errorMessage): void
    {
        $row->update([
            'status' => KvImageExpandStatus::Failed,
            'error_message' => $errorMessage,
        ]);
    }

    /**
     * Fail any row for this file stuck in pending/generating past the
     * watchdog window — same shape as KvBackgroundRemovalService::failStale.
     */
    public function failStale(StudioFile $file): int
    {
        return KvImageExpand::where('studio_file_id', $file->id)
            ->whereIn('status', [
                KvImageExpandStatus::Pending->value,
                KvImageExpandStatus::Generating->value,
            ])
            ->where('updated_at', '<', now()->subMinutes(self::STALE_AFTER_MINUTES))
            ->update([
                'status' => KvImageExpandStatus::Failed->value,
                'error_message' => 'Timed out waiting for the expand service — try again.',
                'updated_at' => now(),
            ]);
    }
}
```

```php
<?php
// api/app/Jobs/Studio/ProcessKvImageExpandJob.php

namespace App\Jobs\Studio;

use App\Enums\KvImageExpandStatus;
use App\Models\KvImageExpand;
use App\Services\Studio\KvImageExpandService;
use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Queue\SerializesModels;
use Illuminate\Support\Facades\Http;

// craftsman-ignore: PHP001, PHP002 (matches sibling KV job classes; repo-wide convention change out of scope here)
class ProcessKvImageExpandJob implements ShouldQueue
{
    use Dispatchable, InteractsWithQueue, Queueable, SerializesModels;

    public int $tries = 3;

    public int $timeout = 300;

    public function __construct(public string $imageExpandId)
    {
        $this->onQueue('default');
    }

    public function handle(KvImageExpandService $service): void
    {
        $row = KvImageExpand::find($this->imageExpandId);
        if (! $row) {
            return;
        }

        $service->markGenerating($row);

        // Reuse the established askFrnd ai-service URL (FRND_AI_SERVICES_URL).
        $aiUrl = rtrim(config('services.ai.url'), '/');

        // Deliberately not chaining Http::retry(): it THROWS on a final
        // failure, which would make the $response->failed() check below dead
        // code, and every extra attempt is another billed gpt-image-2 run
        // (ai-service acks 202, then works fire-and-forget). Same shape as
        // ProcessKvBackgroundRemovalJob.
        try {
            $response = Http::timeout(60)->post("{$aiUrl}/ai/kv-image-expand/run", [
                'image_expand_id' => $row->id,
                'source_image_url' => $row->source_image_url,
                'source_w' => $row->source_w,
                'source_h' => $row->source_h,
                'placement' => $row->placement,
                'user_id' => $row->created_by,
                'user_email' => $row->creator?->email,
                'workspace_id' => $row->file?->workspace_id,
                'workspace_name' => $row->file?->workspace?->name,
                'brand_id' => $row->file?->brand_id,
                'brand_name' => $row->file?->brand?->name,
            ]);
        } catch (\Throwable $e) {
            $service->markFailed($row, "AI service unreachable: {$e->getMessage()}");

            return;
        }

        if ($response->failed()) {
            $service->markFailed($row, "AI service error: {$response->status()}");

            return;
        }
        // AI service responds 202; final status comes via internal callback.
    }

    public function failed(\Throwable $e): void
    {
        $row = KvImageExpand::find($this->imageExpandId);

        // A terminal Done row must never be reopened by a late/retried job
        // failure — that would throw away a result (and the charge already
        // recorded for it) that already landed via the completion callback.
        if ($row && $row->status !== KvImageExpandStatus::Done) {
            app(KvImageExpandService::class)
                ->markFailed($row, "Job failed: {$e->getMessage()}");
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: same command as Step 2.
Expected: PASS (7 tests)

- [ ] **Step 5: Mutation check** — in `failed()`, remove the `!== Done` guard; `does not reopen a Done row…` must FAIL. Revert.

- [ ] **Step 6: Commit**

```bash
git add app/Services/Studio/KvImageExpandService.php app/Jobs/Studio/ProcessKvImageExpandJob.php tests/Unit/Studio/KvImageExpandServiceTest.php tests/Feature/Studio/ProcessKvImageExpandJobTest.php
git commit -m "feat(api): kv image expand service + ai-service dispatch job

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Create request, resource, public controller, routes, config

**Files:**
- Create: `api/app/Http/Requests/Studio/CreateKvImageExpandRequest.php`
- Create: `api/app/Http/Resources/Studio/KvImageExpandResource.php`
- Create: `api/app/Http/Controllers/Api/Studio/KvImageExpandController.php`
- Modify: `api/routes/api.php` — `use` line next to line 219 (`KvBackgroundRemovalController`), route block directly after the background-removals `Route::middleware('feature.flag:show-kv-bg-removal,off')->group(...)` (around line 4633–4643)
- Modify: `api/config/studio.php` — after `'background_removal_rate_limit_per_hour' => 30,` (line 53)
- Test: `api/tests/Feature/Studio/KvImageExpandApiTest.php`

**Interfaces:**
- Produces: `POST /api/v1/studio/files/{fileId}/image-expands` (202, `data` = resource), `GET /api/v1/studio/files/{fileId}/image-expands/{id}` (200). Resource fields: `id, studio_file_id, source_image_url, source_w, source_h, placement, image_url, width, height, model_version, status, error_message, created_at, updated_at`.

- [ ] **Step 1: Write the failing test**

```php
<?php
// api/tests/Feature/Studio/KvImageExpandApiTest.php

use App\Jobs\Studio\ProcessKvImageExpandJob;
use App\Models\KvImageExpand;
use App\Models\Role;
use App\Models\StudioFile;
use App\Models\User;
use App\Models\UserWorkspaceCredit;
use App\Models\Workspace;
use App\Models\WorkspaceCredit;
use Illuminate\Support\Facades\Queue;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Support\Str;

const EXPAND_BODY = [
    'source_image_url' => 'https://example.com/layer.png',
    'source_w' => 400,
    'source_h' => 300,
    'placement' => ['canvas_w' => 640, 'canvas_h' => 360, 'image_x' => 120, 'image_y' => 30],
];

beforeEach(function () {
    $this->user = User::factory()->create();
    $this->workspace = Workspace::factory()->create(['type' => 'organization']);
    $this->user->update(['current_workspace_id' => $this->workspace->id]);
    $this->user->workspaces()->attach($this->workspace->id);

    // The `studio` route group is gated by scope_role:internal.
    $role = Role::factory()->create([
        'slug' => 'internal-'.Str::random(6),
        'type' => 'workspace',
        'scope' => 'internal',
    ]);
    $this->user->workspaceRoles()->attach($role->id, ['workspace_id' => $this->workspace->id]);

    // check.credits:1 on the store route.
    UserWorkspaceCredit::factory()->create([
        'user_id' => $this->user->id,
        'workspace_id' => $this->workspace->id,
        'credits' => 100,
        'total_credits' => 100,
    ]);
    WorkspaceCredit::create([
        'workspace_id' => $this->workspace->id,
        'credits' => 100,
        'total_credits' => 100,
    ]);

    $this->file = StudioFile::factory()->create([
        'workspace_id' => $this->user->current_workspace_id,
        'brand_id' => null,
    ]);
    $this->url = "/api/v1/studio/files/{$this->file->id}/image-expands";
    $this->actingAs($this->user);

    RateLimiter::clear("image-expand-start:{$this->user->id}");
    Queue::fake();
});

it('creates a pending row with placement and dispatches the job', function () {
    $res = $this->postJson($this->url, EXPAND_BODY);

    $res->assertStatus(202)
        ->assertJsonPath('data.status', 'pending')
        ->assertJsonPath('data.source_w', 400)
        ->assertJsonPath('data.placement.canvas_w', 640)
        ->assertJsonPath('data.placement.image_y', 30);

    Queue::assertPushed(ProcessKvImageExpandJob::class);
});

it('persists all four placement keys (validated() must not strip them)', function () {
    $id = $this->postJson($this->url, EXPAND_BODY)->json('data.id');

    expect(KvImageExpand::find($id)->placement)
        ->toBe(['canvas_w' => 640, 'canvas_h' => 360, 'image_x' => 120, 'image_y' => 30]);
});

it('rejects a canvas edge over 4096', function () {
    $body = EXPAND_BODY;
    $body['placement']['canvas_w'] = 4097;
    $this->postJson($this->url, $body)->assertStatus(422);

    $body = EXPAND_BODY;
    $body['placement']['canvas_h'] = 4097;
    $this->postJson($this->url, $body)->assertStatus(422);
});

it('rejects a placement whose canvas does not contain the source', function () {
    // 241 + 400 > 640
    $body = EXPAND_BODY;
    $body['placement']['image_x'] = 241;
    $this->postJson($this->url, $body)->assertStatus(422)
        ->assertJsonValidationErrors(['placement']);

    // 61 + 300 > 360
    $body = EXPAND_BODY;
    $body['placement']['image_y'] = 61;
    $this->postJson($this->url, $body)->assertStatus(422);

    // canvas narrower than the source
    $body = EXPAND_BODY;
    $body['placement']['canvas_w'] = 399;
    $body['placement']['image_x'] = 0;
    $this->postJson($this->url, $body)->assertStatus(422);
});

it('rejects negative offsets and missing placement keys', function () {
    $body = EXPAND_BODY;
    $body['placement']['image_x'] = -1;
    $this->postJson($this->url, $body)->assertStatus(422);

    $body = EXPAND_BODY;
    unset($body['placement']['canvas_h']);
    $this->postJson($this->url, $body)->assertStatus(422);
});

it('rejects a source_image_url on an untrusted host', function () {
    config(['app.s3_overlay_host_pattern' => 's3.amazonaws.com']);
    $body = EXPAND_BODY;
    $body['source_image_url'] = 'https://attacker.example/steal.png';
    $this->postJson($this->url, $body)->assertStatus(422);
});

it('returns the row on show', function () {
    $row = KvImageExpand::factory()->done()->create([
        'studio_file_id' => $this->file->id,
        'created_by' => $this->user->id,
    ]);

    $this->getJson("{$this->url}/{$row->id}")
        ->assertOk()
        ->assertJsonPath('data.id', $row->id)
        ->assertJsonPath('data.status', 'done')
        ->assertJsonPath('data.image_url', 'https://example.com/expanded.png')
        ->assertJsonPath('data.width', 640);
});

it('404s show when the row belongs to another file', function () {
    $otherFile = StudioFile::factory()->create([
        'workspace_id' => $this->workspace->id,
        'brand_id' => null,
    ]);
    $row = KvImageExpand::factory()->create([
        'studio_file_id' => $otherFile->id,
        'created_by' => $this->user->id,
    ]);

    $this->getJson("{$this->url}/{$row->id}")->assertStatus(404);
});

it('403s when the file belongs to another workspace', function () {
    $foreignFile = StudioFile::factory()->create([
        'workspace_id' => Workspace::factory()->create()->id,
        'brand_id' => null,
    ]);

    $this->postJson("/api/v1/studio/files/{$foreignFile->id}/image-expands", EXPAND_BODY)
        ->assertStatus(403);
});

it('rate limits fresh starts per user per hour', function () {
    config(['studio.image_expand_rate_limit_per_hour' => 2]);

    $this->postJson($this->url, EXPAND_BODY)->assertStatus(202);
    $this->postJson($this->url, EXPAND_BODY)->assertStatus(202);
    $this->postJson($this->url, EXPAND_BODY)->assertStatus(429)
        ->assertJsonFragment(['message' => 'Expand image quota reached, try again in 60m']);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd api && DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false php artisan test --compact tests/Feature/Studio/KvImageExpandApiTest.php`
Expected: FAIL — 404s (route missing)

- [ ] **Step 3: Write request, resource, controller, routes, config**

```php
<?php
// api/app/Http/Requests/Studio/CreateKvImageExpandRequest.php

namespace App\Http\Requests\Studio;

use App\Support\Studio\TrustedAssetHost;
use Illuminate\Foundation\Http\FormRequest;

class CreateKvImageExpandRequest extends FormRequest
{
    /** Largest gpt-image-2 output edge we are willing to bill for. Mirrors
     *  ai-service's MAX_CANVAS_EDGE and web's clampPlacement. */
    public const MAX_CANVAS_EDGE = 4096;

    public function authorize(): bool
    {
        return true;
    }

    public function rules(): array
    {
        $edge = 'max:'.self::MAX_CANVAS_EDGE;

        return [
            'source_image_url' => ['required', 'url', 'max:2048'],
            'source_w' => ['required', 'integer', 'min:1', $edge],
            'source_h' => ['required', 'integer', 'min:1', $edge],
            // EVERY placement key is listed on purpose: validated() rebuilds
            // an array field from its listed sub-keys only
            // (excludeUnvalidatedArrayKeys), so an unlisted key would be
            // silently dropped before it reached the row.
            'placement' => ['required', 'array'],
            'placement.canvas_w' => ['required', 'integer', 'min:1', $edge],
            'placement.canvas_h' => ['required', 'integer', 'min:1', $edge],
            'placement.image_x' => ['required', 'integer', 'min:0'],
            'placement.image_y' => ['required', 'integer', 'min:0'],
        ];
    }

    public function withValidator($validator): void
    {
        $validator->after(function ($v) {
            $url = $this->input('source_image_url');
            if ($url && ! TrustedAssetHost::allows($url)) {
                // Same gate as CreateKvBackgroundRemovalRequest: otherwise any
                // authenticated user could point the pipeline at an arbitrary
                // URL that ai-service fetches, mirrors and bills.
                $v->errors()->add('source_image_url', 'source_image_url host is not on the trusted list.');
            }

            // Containment invariant (spec §3). Done here, not as a rule, so
            // it adds no rule key and therefore strips nothing.
            $p = $this->input('placement');
            $sw = $this->input('source_w');
            $sh = $this->input('source_h');
            if (! is_array($p) || ! is_numeric($sw) || ! is_numeric($sh)) {
                return;
            }
            foreach (['canvas_w', 'canvas_h', 'image_x', 'image_y'] as $k) {
                if (! isset($p[$k]) || ! is_numeric($p[$k])) {
                    return; // the rules above already reported it
                }
            }
            if ((int) $p['image_x'] + (int) $sw > (int) $p['canvas_w']) {
                $v->errors()->add('placement', 'placement.image_x + source_w must not exceed placement.canvas_w.');
            }
            if ((int) $p['image_y'] + (int) $sh > (int) $p['canvas_h']) {
                $v->errors()->add('placement', 'placement.image_y + source_h must not exceed placement.canvas_h.');
            }
        });
    }
}
```

```php
<?php
// api/app/Http/Resources/Studio/KvImageExpandResource.php

namespace App\Http\Resources\Studio;

use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

class KvImageExpandResource extends JsonResource
{
    public function toArray(Request $request): array
    {
        return [
            'id' => $this->id,
            'studio_file_id' => $this->studio_file_id,
            'source_image_url' => $this->source_image_url,
            'source_w' => $this->source_w,
            'source_h' => $this->source_h,
            'placement' => $this->placement,
            'image_url' => $this->image_url,
            'width' => $this->width,
            'height' => $this->height,
            'model_version' => $this->model_version,
            'status' => $this->status?->value,
            'error_message' => $this->error_message,
            'created_at' => $this->created_at?->toIso8601String(),
            'updated_at' => $this->updated_at?->toIso8601String(),
        ];
    }
}
```

```php
<?php
// api/app/Http/Controllers/Api/Studio/KvImageExpandController.php

namespace App\Http\Controllers\Api\Studio;

use App\Http\Controllers\Controller;
use App\Http\Requests\Studio\CreateKvImageExpandRequest;
use App\Http\Resources\Studio\KvImageExpandResource;
use App\Models\Brand;
use App\Models\KvImageExpand;
use App\Models\StudioFile;
use App\Services\BrandRole\ToolPermissionResolver;
use App\Services\Studio\KvImageExpandService;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Http\Response;
use Illuminate\Support\Facades\RateLimiter;

/**
 * AI "Expand image" (outpaint into a larger canvas) for a single KV overlay.
 *
 * File-scoped like background removals: the source is an overlay's asset and
 * overlays live in the collaborative doc, not in an API table. Thin —
 * validation and response shaping only; decisions live in
 * KvImageExpandService.
 */
// craftsman-ignore: PHP001, PHP002 (no controller in this codebase uses strict_types/final; a repo-wide convention change is out of scope here)
class KvImageExpandController extends Controller
{
    public function __construct(private readonly KvImageExpandService $service) {}

    public function store(CreateKvImageExpandRequest $request, string $fileId): JsonResponse
    {
        $file = StudioFile::query()->findOrFail($fileId);
        $this->authorizeAccess($file, $request);

        // Every store is a fresh gpt-image-2 dispatch, so every store counts
        // against the hourly budget.
        $key = "image-expand-start:{$request->user()->id}";
        $maxPerHour = (int) config('studio.image_expand_rate_limit_per_hour', 30);

        if (RateLimiter::tooManyAttempts($key, $maxPerHour)) {
            $seconds = RateLimiter::availableIn($key);
            $minutes = max(1, (int) ceil($seconds / 60));

            return response()->json([
                'message' => "Expand image quota reached, try again in {$minutes}m",
            ], Response::HTTP_TOO_MANY_REQUESTS);
        }
        RateLimiter::hit($key, 3600);

        $validated = $request->validated();

        $row = $this->service->create(
            $file,
            $validated['source_image_url'],
            (int) $validated['source_w'],
            (int) $validated['source_h'],
            [
                'canvas_w' => (int) $validated['placement']['canvas_w'],
                'canvas_h' => (int) $validated['placement']['canvas_h'],
                'image_x' => (int) $validated['placement']['image_x'],
                'image_y' => (int) $validated['placement']['image_y'],
            ],
            $request->user()->id,
        );

        return response()->json([
            'data' => (new KvImageExpandResource($row))->resolve(),
        ], Response::HTTP_ACCEPTED);
    }

    public function show(Request $request, string $fileId, string $id): KvImageExpandResource
    {
        $file = StudioFile::query()->findOrFail($fileId);
        $this->authorizeAccess($file, $request);

        $this->service->failStale($file);

        $row = KvImageExpand::where('studio_file_id', $file->id)
            ->whereKey($id)
            ->firstOrFail();

        return new KvImageExpandResource($row);
    }

    /**
     * Workspace + brand + per-tool gate. Mirrors
     * KvBackgroundRemovalController::authorizeAccess — the result is written
     * back into this file's overlays, so the caller must hold the same
     * access a direct overlay PATCH requires.
     */
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

            $file->loadMissing('tool');
            abort_unless(
                ToolPermissionResolver::canAccess($user, $file->tool?->slug ?? '', $file->brand_id),
                403,
                'You do not have access to this file.',
            );
        }
    }
}
```

In `api/routes/api.php`:

1. After `use App\Http\Controllers\Api\Studio\KvBackgroundRemovalController;` add
   `use App\Http\Controllers\Api\Studio\KvImageExpandController;`
2. Directly after the closing `);` of the `Route::middleware('feature.flag:show-kv-bg-removal,off')->group(...)` block that registers `files/{fileId}/background-removals`, add:

```php
                            // KV Expand Image (outpaint an overlay into a
                            // larger canvas). Same gate shape as background
                            // removals: flag key shared with web, credit
                            // floor check on store, exact charge computed
                            // from token usage on the completion callback.
                            Route::middleware('feature.flag:show-kv-image-expand,off')->group(
                                function () {
                                    Route::post('files/{fileId}/image-expands', [
                                        KvImageExpandController::class,
                                        'store',
                                    ])->middleware('check.credits:1');
                                    Route::get('files/{fileId}/image-expands/{id}', [
                                        KvImageExpandController::class,
                                        'show',
                                    ]);
                                }
                            );
```

In `api/config/studio.php`, after `'background_removal_rate_limit_per_hour' => 30,`:

```php
    // Per-user expand-image start budget. Every store is a fresh gpt-image-2
    // run (~$0.05-0.20 each) — bounds a hot-retry loop on a poison input.
    'image_expand_rate_limit_per_hour' => 30,
```

- [ ] **Step 4: Run the test to verify it passes**

Run: same command as Step 2.
Expected: PASS (10 tests). If `assertJsonFragment` on the 429 message fails on the exact minutes, relax that assertion to `assertJsonPath('message', fn ($m) => str_starts_with($m, 'Expand image quota reached'))`.

- [ ] **Step 5: Mutation check** — comment out the `'placement.image_y' => [...]` rule; `persists all four placement keys` must FAIL (key stripped). Revert.

- [ ] **Step 6: Commit**

```bash
git add app/Http/Requests/Studio/CreateKvImageExpandRequest.php app/Http/Resources/Studio/KvImageExpandResource.php app/Http/Controllers/Api/Studio/KvImageExpandController.php routes/api.php config/studio.php tests/Feature/Studio/KvImageExpandApiTest.php
git commit -m "feat(api): POST/GET files/{fileId}/image-expands behind show-kv-image-expand

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Internal completion callback + metering

**Files:**
- Create: `api/app/Http/Requests/Internal/KvImageExpandCompleteRequest.php`
- Create: `api/app/Http/Controllers/Api/Internal/KvImageExpandInternalController.php`
- Modify: `api/routes/api.php` — `use` line next to line 134 (`KvBackgroundRemovalInternalController`), route directly after the `kv-background-removals/completed` route (around line 5655–5658)
- Test: `api/tests/Feature/Studio/KvImageExpandInternalCallbackTest.php`

**Interfaces:**
- Produces: `POST /api/v1/internal/kv-image-expands/completed` with `X-Internal-Token`; body `image_expand_id, status(done|failed), image_url, width, height, model_version, token_usage{input_text_tokens,input_image_tokens,output_image_tokens,output_text_tokens}, error_message`.

- [ ] **Step 1: Write the failing test**

```php
<?php
// api/tests/Feature/Studio/KvImageExpandInternalCallbackTest.php

use App\Enums\KvImageExpandStatus;
use App\Models\Brand;
use App\Models\CostHistory;
use App\Models\KvImageExpand;
use App\Models\StudioFile;
use App\Models\Tool;
use App\Models\User;
use App\Models\UserWorkspaceCredit;
use App\Models\Workspace;

const EXPAND_CALLBACK_URL = '/api/v1/internal/kv-image-expands/completed';

beforeEach(function () {
    config(['services.internal.kv_callback_token' => 'test-token']);
    $this->headers = ['X-Internal-Token' => 'test-token'];

    $this->user = User::factory()->create();
    $this->workspace = Workspace::factory()
        ->state(['type' => 'organization'])
        ->hasAttached($this->user)
        ->create();
    UserWorkspaceCredit::factory()->create([
        'user_id' => $this->user->id,
        'workspace_id' => $this->workspace->id,
        'credits' => 1000,
        'total_credits' => 1000,
    ]);
    Tool::factory()->create(['slug' => 'kv-generator']);
    $this->file = StudioFile::factory()->create([
        'workspace_id' => $this->workspace->id,
        'brand_id' => Brand::factory()->create()->id,
        'tool_id' => Tool::where('slug', 'kv-generator')->first()->id,
        'created_by' => $this->user->id,
        'last_edited_by' => $this->user->id,
    ]);
    $this->row = KvImageExpand::factory()->generating()->create([
        'studio_file_id' => $this->file->id,
        'created_by' => $this->user->id,
    ]);
    $this->doneBody = [
        'image_expand_id' => $this->row->id,
        'status' => 'done',
        'image_url' => 'https://cdn.example.com/out.png',
        'width' => 640,
        'height' => 360,
        'model_version' => 'gpt-image-2',
        'token_usage' => [
            'input_text_tokens' => 10,
            'input_image_tokens' => 200,
            'output_image_tokens' => 1290,
            'output_text_tokens' => 0,
        ],
    ];
});

it('persists the result + usage and marks done', function () {
    $this->withHeaders($this->headers)->postJson(EXPAND_CALLBACK_URL, $this->doneBody)->assertOk();

    $this->row->refresh();
    expect($this->row->status)->toBe(KvImageExpandStatus::Done);
    expect($this->row->image_url)->toBe('https://cdn.example.com/out.png');
    expect($this->row->width)->toBe(640);
    expect($this->row->height)->toBe(360);
    expect($this->row->model_version)->toBe('gpt-image-2');
    expect($this->row->token_usage['output_image_tokens'])->toBe(1290);
});

it('charges credits once per row, keyed kv_image_expand_{id}', function () {
    $this->withHeaders($this->headers)->postJson(EXPAND_CALLBACK_URL, $this->doneBody)->assertOk();

    $batchId = "kv_image_expand_{$this->row->id}";
    $entry = CostHistory::where('batch_identifier', $batchId)->first();
    expect($entry)->not->toBeNull();
    expect($entry->cost_type)->toBe('kv_image_expand');
    expect($entry->actual_credit)->toBeGreaterThan(0);

    // A second done callback is ignored by the status guard; a direct
    // re-charge with the same batch id is a no-op inside charge().
    $this->withHeaders($this->headers)->postJson(EXPAND_CALLBACK_URL, $this->doneBody)
        ->assertOk()->assertJsonPath('ignored', true);
    expect(CostHistory::where('batch_identifier', $batchId)->count())->toBe(1);
});

it('marks done but skips the charge when token_usage is absent', function () {
    $body = $this->doneBody;
    unset($body['token_usage']);

    $this->withHeaders($this->headers)->postJson(EXPAND_CALLBACK_URL, $body)->assertOk();

    expect($this->row->fresh()->status)->toBe(KvImageExpandStatus::Done);
    expect(CostHistory::where('batch_identifier', "kv_image_expand_{$this->row->id}")->count())->toBe(0);
});

it('marks failed with error_message and charges nothing', function () {
    $this->withHeaders($this->headers)->postJson(EXPAND_CALLBACK_URL, [
        'image_expand_id' => $this->row->id,
        'status' => 'failed',
        'error_message' => 'gpt-image-2 520',
    ])->assertOk();

    expect($this->row->fresh()->status)->toBe(KvImageExpandStatus::Failed);
    expect($this->row->fresh()->error_message)->toBe('gpt-image-2 520');
    expect(CostHistory::where('batch_identifier', "kv_image_expand_{$this->row->id}")->count())->toBe(0);
});

it('ignores a late callback on a terminal row', function () {
    $this->row->update(['status' => KvImageExpandStatus::Done, 'image_url' => 'https://existing.example.com/x.png']);

    $this->withHeaders($this->headers)->postJson(EXPAND_CALLBACK_URL, [
        'image_expand_id' => $this->row->id,
        'status' => 'failed',
        'error_message' => 'late',
    ])->assertOk()->assertJsonPath('ignored', true);

    expect($this->row->fresh()->status)->toBe(KvImageExpandStatus::Done);
    expect($this->row->fresh()->image_url)->toBe('https://existing.example.com/x.png');
});

it('rejects non-integer token_usage values', function () {
    $body = $this->doneBody;
    $body['token_usage'] = ['output_image_tokens' => 'oops'];

    $this->withHeaders($this->headers)->postJson(EXPAND_CALLBACK_URL, $body)->assertStatus(422);
});

it('rejects a missing or wrong internal token', function () {
    $this->postJson(EXPAND_CALLBACK_URL, $this->doneBody)->assertStatus(401);
    $this->withHeaders(['X-Internal-Token' => 'wrong'])
        ->postJson(EXPAND_CALLBACK_URL, $this->doneBody)->assertStatus(401);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd api && DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false php artisan test --compact tests/Feature/Studio/KvImageExpandInternalCallbackTest.php`
Expected: FAIL — 404 (route missing)

- [ ] **Step 3: Write request, controller, route**

```php
<?php
// api/app/Http/Requests/Internal/KvImageExpandCompleteRequest.php

namespace App\Http\Requests\Internal;

use Illuminate\Foundation\Http\FormRequest;

class KvImageExpandCompleteRequest extends FormRequest
{
    use AuthorizesInternalKvCallback;

    public function rules(): array
    {
        return [
            'image_expand_id' => ['required', 'string'],
            'status' => ['required', 'string', 'in:done,failed'],
            'image_url' => ['required_if:status,done', 'nullable', 'url'],
            'width' => ['nullable', 'integer', 'min:1'],
            'height' => ['nullable', 'integer', 'min:1'],
            'model_version' => ['nullable', 'string', 'max:64'],
            // Same sub-key list as KvResizeExportCompleteRequest — every key
            // listed, since validated() keeps only listed sub-keys.
            'token_usage' => ['nullable', 'array'],
            'token_usage.input_text_tokens' => ['nullable', 'integer', 'min:0'],
            'token_usage.input_image_tokens' => ['nullable', 'integer', 'min:0'],
            'token_usage.output_image_tokens' => ['nullable', 'integer', 'min:0'],
            'token_usage.output_text_tokens' => ['nullable', 'integer', 'min:0'],
            'error_message' => ['required_if:status,failed', 'nullable', 'string'],
        ];
    }
}
```

```php
<?php
// api/app/Http/Controllers/Api/Internal/KvImageExpandInternalController.php

namespace App\Http\Controllers\Api\Internal;

use App\Enums\KvImageExpandStatus;
use App\Http\Controllers\Controller;
use App\Http\Requests\Internal\KvImageExpandCompleteRequest;
use App\Models\KvImageExpand;
use App\Models\User;
use App\Services\Studio\KvCreditMeteringService;
use App\Services\Studio\KvImageExpandService;
use Illuminate\Http\JsonResponse;

// craftsman-ignore: PHP001, PHP002 (no controller in this codebase uses strict_types/final; a repo-wide convention change is out of scope here)
class KvImageExpandInternalController extends Controller
{
    public function __construct(
        private readonly KvImageExpandService $service,
        private readonly KvCreditMeteringService $metering,
    ) {}

    public function completed(KvImageExpandCompleteRequest $request): JsonResponse
    {
        $validated = $request->validated();

        $row = KvImageExpand::with('file')->findOrFail($validated['image_expand_id']);

        // Idempotency guard — same shape as the background-removal callback.
        if (! in_array($row->status, [
            KvImageExpandStatus::Pending,
            KvImageExpandStatus::Generating,
        ])) {
            return response()->json(['ok' => true, 'ignored' => true]);
        }

        if ($validated['status'] === 'done') {
            $tokenUsage = $validated['token_usage'] ?? null;

            $this->service->markDone(
                $row,
                imageUrl: $validated['image_url'],
                width: $validated['width'] ?? null,
                height: $validated['height'] ?? null,
                modelVersion: $validated['model_version'] ?? null,
                tokenUsage: $tokenUsage,
            );

            // Token-based like resize exports (gpt-image-2 reports usage),
            // not megapixel-based like background removal. charge() logs and
            // skips on empty usage and is idempotent on batch id.
            $user = User::find($row->created_by);
            if ($user && $row->file && $row->file->workspace) {
                $this->metering->charge(
                    user: $user,
                    workspace: $row->file->workspace,
                    costType: 'kv_image_expand',
                    toolName: 'KV Expand Image',
                    batchId: "kv_image_expand_{$row->id}",
                    model: $validated['model_version'] ?? 'gpt-image-2',
                    tokenUsage: $tokenUsage ?? [],
                    brandId: $row->file->brand_id,
                );
            }
        } else {
            $this->service->markFailed($row, $validated['error_message']);
        }

        return response()->json(['ok' => true]);
    }
}
```

In `api/routes/api.php`:

1. After `use App\Http\Controllers\Api\Internal\KvBackgroundRemovalInternalController;` add
   `use App\Http\Controllers\Api\Internal\KvImageExpandInternalController;`
2. Directly after the `Route::post('kv-background-removals/completed', [...]);` registration add:

```php
        // KV Expand Image completion callback (called by ai-service after
        // the outpainted PNG finishes uploading to S3). Carries gpt-image-2
        // token usage for metering.
        Route::post('kv-image-expands/completed', [
            KvImageExpandInternalController::class,
            'completed',
        ]);
```

- [ ] **Step 4: Run the test to verify it passes**

Run: same command as Step 2.
Expected: PASS (7 tests). If `charges credits once…` fails with `actual_credit` = 0 because `PricingHelper` has no `gpt-image-2` pricing row in the test DB, look at how `tests/Feature/Internal/KvResizeExportCallbackCreditTest.php` seeds pricing (search it for `Pricing`/`ModelPricing`) and copy that seeding into `beforeEach`. Do not weaken the assertion to `>= 0`.

- [ ] **Step 5: Mutation check** — change the batch id to `"kv_image_expand"` (drop the row id); `charges credits once…` still passes but a second row would collide — add nothing, just revert. Then change `markDone`'s `tokenUsage` arg to `null`; `persists the result + usage…` must FAIL. Revert.

- [ ] **Step 6: Commit**

```bash
git add app/Http/Requests/Internal/KvImageExpandCompleteRequest.php app/Http/Controllers/Api/Internal/KvImageExpandInternalController.php routes/api.php tests/Feature/Studio/KvImageExpandInternalCallbackTest.php
git commit -m "feat(api): kv image expand completion callback + token-based metering

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Full run, migrate the dev DB, verify the live route

**Files:** none new.

- [ ] **Step 1: Run every new test file together**

Run:
```bash
cd api && DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false php artisan test --compact \
  tests/Feature/Studio/KvImageExpandModelTest.php \
  tests/Unit/Studio/KvImageExpandServiceTest.php \
  tests/Feature/Studio/ProcessKvImageExpandJobTest.php \
  tests/Feature/Studio/KvImageExpandApiTest.php \
  tests/Feature/Studio/KvImageExpandInternalCallbackTest.php
```
Expected: all PASS

- [ ] **Step 2: Run the sibling bg-removal suites to prove the shared routes file still loads**

Run: same prefix with `tests/Feature/Studio/KvBackgroundRemovalApiTest.php tests/Feature/Studio/KvBackgroundRemovalInternalCallbackTest.php`
Expected: same result as on `develop` (baseline with a worktree if unsure; never `git stash`).

- [ ] **Step 3: Pint**

Run: `cd api && vendor/bin/pint --test app/Enums/KvImageExpandStatus.php app/Models/KvImageExpand.php app/Services/Studio/KvImageExpandService.php app/Jobs/Studio/ProcessKvImageExpandJob.php app/Http/Requests/Studio/CreateKvImageExpandRequest.php app/Http/Requests/Internal/KvImageExpandCompleteRequest.php app/Http/Resources/Studio/KvImageExpandResource.php app/Http/Controllers/Api/Studio/KvImageExpandController.php app/Http/Controllers/Api/Internal/KvImageExpandInternalController.php database/migrations/2026_09_14_100000_create_kv_image_expands_table.php database/factories/KvImageExpandFactory.php`
Expected: clean; if not, run without `--test` and commit the formatting as `style(api): pint`.

- [ ] **Step 4: Migrate the dev DB** (needed for the web plan's manual e2e):

Run: `cd api && TELESCOPE_ENABLED=false php artisan migrate`
Expected: `2026_09_14_100000_create_kv_image_expands_table` DONE

- [ ] **Step 5: Clear the route cache and probe the live server** — `run-all.sh` never clears Laravel caches, and a stale route cache 405s every new route:

```bash
cd api && rm -f bootstrap/cache/routes-v7.php && php artisan optimize:clear
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:9191/api/v1/studio/files/x/image-expands
```
Expected: `401` (auth), not `404`/`405`. If the API isn't running, say so and skip.

- [ ] **Step 6: Report** — `git log --oneline develop..HEAD`, the pest summary line, and whether Step 5 was verified. Do not push.
