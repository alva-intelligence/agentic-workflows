# KV Magic Layers — api (Laravel) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Job lifecycle for magic-layer decomposition: create a job for a studio file, dispatch it to ai-service, receive the internal completion callback, persist the inpainted background as a base generation + the cutouts as image overlays, and meter credits.

**Architecture:** Mirrors the kv-resize pipeline exactly: controller/service creates a `pending` row → `ShouldQueue` job flips it to `generating` and fire-and-forgets to ai-service (`Http` facade, 202) → ai-service POSTs `internal/kv-magic-layer-jobs/completed` (auth via `AuthorizesInternalKvCallback` trait, `X-Internal-Token`) → callback idempotently persists results and charges via `KvCreditMeteringService::charge` with deterministic batch ids. Staleness is handled lazily on the polling GET (no scheduler wiring).

**Tech Stack:** Laravel 13, PostgreSQL (jsonb), Pest (+ RefreshDatabase, SQLite in-memory).

## Global Constraints

- Branch: `feature/daffa/vc-kv-magic-layers` from `origin/develop`. Setup inside `api/`: `git fetch origin && git checkout -b feature/daffa/vc-kv-magic-layers origin/develop`.
- Spec: `docs/superpowers/specs/2026-07-23-kv-magic-layers-design.md` (workspace root repo). Callback contract fields are defined there and in the ai-service plan's Global Constraints — field names are load-bearing.
- ai-service endpoint dispatched to: `POST {FRND_AI_SERVICES_URL}/ai/kv-magic-layer/jobs` (`config('services.ai.url')`).
- Credits: token-metered stages only — `detect` (`kv_magic_layer_vision`) and `inpaint` (`kv_magic_layer`) via `KvCreditMeteringService::charge`. The `segment` (Replicate) stage has no token usage; it is stored in `usage_entries` for audit and **not charged in v1** (flat pricing is a follow-up). Charge only on `status=done` (spec: never charge failures / `no_layers_detected`).
- Testing note (known workspace lesson): if a fresh-migrate Feature run trips the workspaces-backfill issue, fall back to targeted Unit tests for verification — but write tests in the conventional Pest style regardless.
- Commits: `feat(api): …` / `test(api): …`.

---

### Task 1: Migration, enum, model, factory

**Files:**
- Create: `database/migrations/2026_07_23_090000_create_kv_magic_layer_jobs_table.php`
- Create: `app/Enums/KvMagicLayerJobStatus.php`
- Create: `app/Models/KvMagicLayerJob.php`
- Create: `database/factories/KvMagicLayerJobFactory.php`
- Modify: `app/Enums/CostHistoryType.php` (two new cases next to the KV block, lines 31-36)
- Test: `tests/Unit/Models/KvMagicLayerJobTest.php`

**Interfaces:**
- Produces: `KvMagicLayerJob` model (`HasUlids`; casts `layers`, `usage_entries` → array, `status` → `KvMagicLayerJobStatus`; relations `file()`, `generation()`), statuses `Pending|Generating|Done|Failed`, `CostHistoryType::KV_MAGIC_LAYER = 'kv_magic_layer'` and `KV_MAGIC_LAYER_VISION = 'kv_magic_layer_vision'`.

- [ ] **Step 1: Write the failing test**

```php
<?php
// tests/Unit/Models/KvMagicLayerJobTest.php

use App\Enums\KvMagicLayerJobStatus;
use App\Models\KvMagicLayerJob;
use App\Models\StudioFile;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

uses(TestCase::class, RefreshDatabase::class);

it('creates a pending job with array casts', function () {
    $user = User::factory()->create();
    $file = StudioFile::factory()->create();

    $job = KvMagicLayerJob::factory()->create([
        'studio_file_id' => $file->id,
        'created_by' => $user->id,
        'layers' => [['kind' => 'subject']],
    ]);

    expect($job->status)->toBe(KvMagicLayerJobStatus::Pending)
        ->and($job->layers)->toBe([['kind' => 'subject']])
        ->and($job->file->id)->toBe($file->id);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `php artisan test tests/Unit/Models/KvMagicLayerJobTest.php`
Expected: FAIL — class `KvMagicLayerJob` not found

- [ ] **Step 3: Implement**

```php
<?php
// database/migrations/2026_07_23_090000_create_kv_magic_layer_jobs_table.php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('kv_magic_layer_jobs', function (Blueprint $t) {
            $t->ulid('id')->primary();
            $t->foreignUlid('studio_file_id')->constrained('studio_files')->cascadeOnDelete();
            $t->foreignUlid('created_by')->constrained('users')->cascadeOnDelete();

            $t->string('source_image_url', 2048);
            $t->string('mime_type', 32);
            $t->unsignedBigInteger('size')->default(0);
            $t->unsignedInteger('width');
            $t->unsignedInteger('height');
            $t->string('canvas_mode', 8)->default('craft');

            $t->string('status', 16)->default('pending');
            $t->string('background_url', 2048)->nullable();
            $t->foreignUlid('generation_id')->nullable()->constrained('kv_generations')->nullOnDelete();
            $t->jsonb('layers')->nullable();
            $t->jsonb('usage_entries')->nullable();
            $t->text('error_message')->nullable();
            $t->string('ai_service_run_id')->nullable();

            $t->timestamps();
            $t->index(['studio_file_id', 'created_at'], 'kv_magic_layer_jobs_file_idx');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('kv_magic_layer_jobs');
    }
};
```

```php
<?php
// app/Enums/KvMagicLayerJobStatus.php

namespace App\Enums;

enum KvMagicLayerJobStatus: string
{
    case Pending = 'pending';
    case Generating = 'generating';
    case Done = 'done';
    case Failed = 'failed';
}
```

```php
<?php
// app/Models/KvMagicLayerJob.php

namespace App\Models;

use App\Enums\KvMagicLayerJobStatus;
use Illuminate\Database\Eloquent\Concerns\HasUlids;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class KvMagicLayerJob extends Model
{
    use HasFactory, HasUlids;

    protected $fillable = [
        'studio_file_id', 'created_by', 'source_image_url', 'mime_type', 'size',
        'width', 'height', 'canvas_mode', 'status', 'background_url',
        'generation_id', 'layers', 'usage_entries', 'error_message', 'ai_service_run_id',
    ];

    protected $casts = [
        'layers' => 'array',
        'usage_entries' => 'array',
        'status' => KvMagicLayerJobStatus::class,
    ];

    public function file(): BelongsTo
    {
        return $this->belongsTo(StudioFile::class, 'studio_file_id');
    }

    public function generation(): BelongsTo
    {
        return $this->belongsTo(KvGeneration::class, 'generation_id');
    }
}
```

```php
<?php
// database/factories/KvMagicLayerJobFactory.php

namespace Database\Factories;

use App\Models\KvMagicLayerJob;
use App\Models\StudioFile;
use App\Models\User;
use Illuminate\Database\Eloquent\Factories\Factory;

class KvMagicLayerJobFactory extends Factory
{
    protected $model = KvMagicLayerJob::class;

    public function definition(): array
    {
        return [
            'studio_file_id' => StudioFile::factory(),
            'created_by' => User::factory(),
            'source_image_url' => 'https://s3.test/source.png',
            'mime_type' => 'image/png',
            'size' => 1024,
            'width' => 1080,
            'height' => 1350,
            'canvas_mode' => 'craft',
            'status' => 'pending',
        ];
    }
}
```

In `app/Enums/CostHistoryType.php`, next to the existing KV cases:

```php
case KV_MAGIC_LAYER = 'kv_magic_layer';
case KV_MAGIC_LAYER_VISION = 'kv_magic_layer_vision';
```

and in its `getName()` match block:

```php
self::KV_MAGIC_LAYER => 'Magic Layers',
self::KV_MAGIC_LAYER_VISION => 'Magic Layers Vision Analysis',
```

- [ ] **Step 4: Run test to verify it passes**

Run: `php artisan test tests/Unit/Models/KvMagicLayerJobTest.php`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add database/migrations/2026_07_23_090000_create_kv_magic_layer_jobs_table.php \
  app/Enums/KvMagicLayerJobStatus.php app/Models/KvMagicLayerJob.php \
  database/factories/KvMagicLayerJobFactory.php app/Enums/CostHistoryType.php \
  tests/Unit/Models/KvMagicLayerJobTest.php
git commit -m "feat(api): kv_magic_layer_jobs table, model, statuses, cost types"
```

---

### Task 2: Service + dispatch job

**Files:**
- Create: `app/Services/Studio/KvMagicLayerJobService.php`
- Create: `app/Jobs/Studio/ProcessKvMagicLayerJob.php`
- Test: `tests/Unit/Services/Studio/KvMagicLayerJobServiceTest.php`

**Interfaces:**
- Produces (consumed by Tasks 3–4):
  - `createJob(StudioFile $file, User $user, array $payload): KvMagicLayerJob` — creates `pending` row, dispatches `ProcessKvMagicLayerJob`
  - `markGenerating/markFailed(KvMagicLayerJob $job, ?string $error = null): void`
  - `failIfStale(KvMagicLayerJob $job): void` — pending/generating older than `STALE_AFTER_MINUTES = 6` → failed `'timeout'`
  - `persistCompletion(KvMagicLayerJob $job, array $validated): KvMagicLayerJob` — transactionally: base generation via `KvGenerationService::persistImportFromUpload`, stamped image overlays appended to `studio_files.overlays`, job marked done

- [ ] **Step 1: Write the failing tests**

```php
<?php
// tests/Unit/Services/Studio/KvMagicLayerJobServiceTest.php

use App\Enums\KvMagicLayerJobStatus;
use App\Jobs\Studio\ProcessKvMagicLayerJob;
use App\Models\KvMagicLayerJob;
use App\Models\StudioFile;
use App\Models\User;
use App\Services\Studio\KvMagicLayerJobService;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Queue;
use Tests\TestCase;

uses(TestCase::class, RefreshDatabase::class);

beforeEach(function () {
    Queue::fake();
    $this->service = app(KvMagicLayerJobService::class);
    $this->user = User::factory()->create();
    $this->file = StudioFile::factory()->create();
});

it('creates a pending job and dispatches the ai-service dispatch job', function () {
    $job = $this->service->createJob($this->file, $this->user, [
        'image_url' => 'https://s3.test/src.png',
        'mime_type' => 'image/png',
        'size' => 2048,
        'width' => 1080,
        'height' => 1350,
        'canvas_mode' => 'craft',
    ]);

    expect($job->status)->toBe(KvMagicLayerJobStatus::Pending)
        ->and($job->source_image_url)->toBe('https://s3.test/src.png');
    Queue::assertPushed(ProcessKvMagicLayerJob::class, fn ($q) => $q->jobId === $job->id);
});

it('fails stale generating jobs lazily', function () {
    $job = KvMagicLayerJob::factory()->create(['status' => 'generating']);
    $job->timestamps = false;
    $job->forceFill(['updated_at' => now()->subMinutes(10)])->save();

    $this->service->failIfStale($job->refresh());

    expect($job->refresh()->status)->toBe(KvMagicLayerJobStatus::Failed)
        ->and($job->error_message)->toBe('timeout');
});

it('does not touch fresh or terminal jobs on failIfStale', function () {
    $fresh = KvMagicLayerJob::factory()->create(['status' => 'generating']);
    $done = KvMagicLayerJob::factory()->create(['status' => 'done']);

    $this->service->failIfStale($fresh);
    $this->service->failIfStale($done);

    expect($fresh->refresh()->status)->toBe(KvMagicLayerJobStatus::Generating)
        ->and($done->refresh()->status)->toBe(KvMagicLayerJobStatus::Done);
});

it('persistCompletion creates a base generation and appends stamped overlays', function () {
    $job = KvMagicLayerJob::factory()->create([
        'studio_file_id' => $this->file->id,
        'created_by' => $this->user->id,
        'status' => 'generating',
    ]);

    $result = $this->service->persistCompletion($job, [
        'background_url' => 'https://s3.test/bg.png',
        'ai_service_run_id' => 'run-1',
        'usage_entries' => [['stage' => 'detect', 'model' => 'gpt-4o-mini', 'token_usage' => []]],
        'layers' => [
            ['kind' => 'subject', 'label' => 'person', 'image_url' => 'https://s3.test/cut1.png',
             'x' => 0.1, 'y' => 0.2, 'width' => 0.3, 'height' => 0.4, 'z' => 1],
        ],
    ]);

    expect($result->status)->toBe(KvMagicLayerJobStatus::Done)
        ->and($result->generation_id)->not->toBeNull()
        ->and($result->generation->model)->toBe('user_upload');

    $overlays = $this->file->refresh()->overlays;
    expect($overlays)->toHaveCount(1)
        ->and($overlays[0]['type'])->toBe('image')
        ->and($overlays[0]['board_generation_id'])->toBe($result->generation_id)
        ->and($overlays[0]['payload']['asset_url'])->toBe('https://s3.test/cut1.png')
        ->and(strlen($overlays[0]['id']))->toBe(26);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `php artisan test tests/Unit/Services/Studio/KvMagicLayerJobServiceTest.php`
Expected: FAIL — class `KvMagicLayerJobService` not found

- [ ] **Step 3: Implement service + job**

```php
<?php
// app/Services/Studio/KvMagicLayerJobService.php

namespace App\Services\Studio;

use App\Enums\KvMagicLayerJobStatus;
use App\Jobs\Studio\ProcessKvMagicLayerJob;
use App\Models\KvMagicLayerJob;
use App\Models\StudioFile;
use App\Models\User;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

class KvMagicLayerJobService
{
    public const STALE_AFTER_MINUTES = 6;

    public function __construct(private readonly KvGenerationService $generations)
    {
    }

    public function createJob(StudioFile $file, User $user, array $payload): KvMagicLayerJob
    {
        $job = KvMagicLayerJob::create([
            'studio_file_id' => $file->id,
            'created_by' => $user->id,
            'source_image_url' => $payload['image_url'],
            'mime_type' => $payload['mime_type'],
            'size' => $payload['size'],
            'width' => $payload['width'],
            'height' => $payload['height'],
            'canvas_mode' => $payload['canvas_mode'] ?? 'craft',
            'status' => KvMagicLayerJobStatus::Pending,
        ]);

        ProcessKvMagicLayerJob::dispatch($job->id);

        return $job;
    }

    public function markGenerating(KvMagicLayerJob $job): void
    {
        $job->update(['status' => KvMagicLayerJobStatus::Generating]);
    }

    public function markFailed(KvMagicLayerJob $job, ?string $error = null): void
    {
        $job->update([
            'status' => KvMagicLayerJobStatus::Failed,
            'error_message' => $error,
        ]);
    }

    public function failIfStale(KvMagicLayerJob $job): void
    {
        $active = in_array($job->status, [KvMagicLayerJobStatus::Pending, KvMagicLayerJobStatus::Generating], true);
        if ($active && $job->updated_at->lt(now()->subMinutes(self::STALE_AFTER_MINUTES))) {
            $this->markFailed($job, 'timeout');
        }
    }

    public function persistCompletion(KvMagicLayerJob $job, array $validated): KvMagicLayerJob
    {
        return DB::transaction(function () use ($job, $validated) {
            $generation = $this->generations->persistImportFromUpload([
                'studio_file_id' => $job->studio_file_id,
                'image_url' => $validated['background_url'],
                'mime_type' => 'image/png',
                'size' => 0,
                'original_filename' => null,
                'width' => $job->width,
                'height' => $job->height,
                'canvas_mode' => $job->canvas_mode,
                'created_by' => $job->created_by,
            ]);

            $stamped = $this->stampOverlays($validated['layers'] ?? [], $generation->id);

            $file = StudioFile::whereKey($job->studio_file_id)->lockForUpdate()->firstOrFail();
            $file->forceFill([
                'overlays' => array_merge($file->overlays ?? [], $stamped),
            ])->save();

            $job->forceFill([
                'status' => KvMagicLayerJobStatus::Done,
                'background_url' => $validated['background_url'],
                'generation_id' => $generation->id,
                'layers' => $stamped,
                'usage_entries' => $validated['usage_entries'] ?? null,
                'ai_service_run_id' => $validated['ai_service_run_id'] ?? null,
                'error_message' => null,
            ])->save();

            return $job->refresh()->load('generation');
        });
    }

    private function stampOverlays(array $layers, string $generationId): array
    {
        $now = now()->toISOString();

        return array_map(fn (array $layer) => [
            'id' => (string) Str::ulid(),
            'type' => 'image',
            'x' => (float) $layer['x'],
            'y' => (float) $layer['y'],
            'width' => (float) $layer['width'],
            'height' => (float) $layer['height'],
            'rotation' => 0.0,
            'z' => (int) $layer['z'],
            'board_generation_id' => $generationId,
            'payload' => [
                'type' => 'image',
                'asset_url' => $layer['image_url'],
                'mime_type' => 'image/png',
            ],
            'created_at' => $now,
            'updated_at' => $now,
        ], $layers);
    }
}
```

```php
<?php
// app/Jobs/Studio/ProcessKvMagicLayerJob.php

namespace App\Jobs\Studio;

use App\Models\KvMagicLayerJob;
use App\Services\Studio\KvMagicLayerJobService;
use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Queue\SerializesModels;
use Illuminate\Support\Facades\Http;

class ProcessKvMagicLayerJob implements ShouldQueue
{
    use Dispatchable, InteractsWithQueue, Queueable, SerializesModels;

    public int $tries = 3;

    public int $timeout = 120;

    public function __construct(public readonly string $jobId)
    {
    }

    public function handle(KvMagicLayerJobService $service): void
    {
        $job = KvMagicLayerJob::with('file.workspace')->find($this->jobId);
        if (! $job || $job->status->value !== 'pending') {
            return;
        }

        $service->markGenerating($job);

        $user = $job->file?->workspace ? \App\Models\User::find($job->created_by) : null;
        $aiUrl = rtrim(config('services.ai.url'), '/');
        $response = Http::timeout(60)
            ->retry(2, 500)
            ->post("{$aiUrl}/ai/kv-magic-layer/jobs", [
                'job_id' => $job->id,
                'source_image_url' => $job->source_image_url,
                'user_id' => $job->created_by,
                'user_email' => $user?->email,
                'workspace_id' => $job->file?->workspace_id,
                'brand_id' => $job->file?->brand_id,
            ]);

        if ($response->failed()) {
            $service->markFailed($job, "AI service error: {$response->status()}");
        }
        // Success = 202; final status arrives via the internal callback.
    }

    public function failed(\Throwable $e): void
    {
        $job = KvMagicLayerJob::find($this->jobId);
        if ($job) {
            app(KvMagicLayerJobService::class)->markFailed($job, $e->getMessage());
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `php artisan test tests/Unit/Services/Studio/KvMagicLayerJobServiceTest.php`
Expected: 4 PASS

- [ ] **Step 5: Commit**

```bash
git add app/Services/Studio/KvMagicLayerJobService.php app/Jobs/Studio/ProcessKvMagicLayerJob.php \
  tests/Unit/Services/Studio/KvMagicLayerJobServiceTest.php
git commit -m "feat(api): magic-layer job service + ai-service dispatch job"
```

---

### Task 3: Public endpoints (create + poll)

**Files:**
- Create: `app/Http/Requests/Studio/CreateKvMagicLayerJobRequest.php`
- Create: `app/Http/Resources/KvMagicLayerJobResource.php`
- Create: `app/Http/Controllers/Api/Studio/KvMagicLayerJobController.php`
- Modify: `routes/api.php` — inside the `feature.flag:show-kv-generator` group (near line 3025)
- Test: `tests/Feature/Studio/KvMagicLayerJobControllerTest.php`

**Interfaces:**
- Produces:
  - `POST /api/v1/studio/kv-generator/files/{id}/magic-layer-jobs` → 201 `{data: job}`
  - `GET /api/v1/studio/kv-generator/files/{id}/magic-layer-jobs/{jobId}` → 200 `{data: job}` (runs `failIfStale` first)
  - Resource JSON: `{id, studio_file_id, status, error_message, background_url, generation (KvGenerationResource|null), overlays (stamped layers array), created_at}` — the web plan consumes `status`, `error_message`, `generation`, `overlays`.

- [ ] **Step 1: Write the failing tests**

```php
<?php
// tests/Feature/Studio/KvMagicLayerJobControllerTest.php

use App\Jobs\Studio\ProcessKvMagicLayerJob;
use App\Models\KvMagicLayerJob;
use App\Models\StudioFile;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Queue;
use Tests\TestCase;

uses(TestCase::class, RefreshDatabase::class);

beforeEach(function () {
    Queue::fake();
    config(['app.s3_overlay_host_pattern' => 's3.test']);
    $this->user = User::factory()->create();
    $this->file = StudioFile::factory()->create([
        'workspace_id' => $this->user->current_workspace_id,
    ]);
});

it('creates a job and returns 201', function () {
    $resp = $this->actingAs($this->user, 'api')->postJson(
        "/api/v1/studio/kv-generator/files/{$this->file->id}/magic-layer-jobs",
        [
            'image_url' => 'https://s3.test/src.png',
            'mime_type' => 'image/png',
            'size' => 2048,
            'width' => 1080,
            'height' => 1350,
            'canvas_mode' => 'craft',
        ],
    );

    $resp->assertCreated()->assertJsonPath('data.status', 'pending');
    Queue::assertPushed(ProcessKvMagicLayerJob::class);
});

it('rejects untrusted image hosts', function () {
    $this->actingAs($this->user, 'api')->postJson(
        "/api/v1/studio/kv-generator/files/{$this->file->id}/magic-layer-jobs",
        [
            'image_url' => 'https://evil.example/src.png',
            'mime_type' => 'image/png',
            'size' => 2048,
            'width' => 1080,
            'height' => 1350,
        ],
    )->assertUnprocessable();
});

it('forbids files from another workspace', function () {
    $other = StudioFile::factory()->create();
    $this->actingAs($this->user, 'api')->postJson(
        "/api/v1/studio/kv-generator/files/{$other->id}/magic-layer-jobs",
        [
            'image_url' => 'https://s3.test/src.png',
            'mime_type' => 'image/png',
            'size' => 2048,
            'width' => 1080,
            'height' => 1350,
        ],
    )->assertForbidden();
});

it('shows a job and fails stale ones lazily', function () {
    $job = KvMagicLayerJob::factory()->create([
        'studio_file_id' => $this->file->id,
        'created_by' => $this->user->id,
        'status' => 'generating',
    ]);
    $job->timestamps = false;
    $job->forceFill(['updated_at' => now()->subMinutes(10)])->save();

    $this->actingAs($this->user, 'api')
        ->getJson("/api/v1/studio/kv-generator/files/{$this->file->id}/magic-layer-jobs/{$job->id}")
        ->assertOk()
        ->assertJsonPath('data.status', 'failed')
        ->assertJsonPath('data.error_message', 'timeout');
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `php artisan test tests/Feature/Studio/KvMagicLayerJobControllerTest.php`
Expected: FAIL — 404 (routes missing)

- [ ] **Step 3: Implement**

```php
<?php
// app/Http/Requests/Studio/CreateKvMagicLayerJobRequest.php

namespace App\Http\Requests\Studio;

use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Validation\Rule;
use Illuminate\Validation\Validator;

class CreateKvMagicLayerJobRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    public function rules(): array
    {
        return [
            'image_url' => ['required', 'url', 'max:2048'],
            'mime_type' => ['required', Rule::in(['image/png', 'image/jpeg', 'image/webp'])],
            'size' => ['required', 'integer', 'min:0', 'max:20971520'],
            'width' => ['required', 'integer', 'min:1', 'max:30000'],
            'height' => ['required', 'integer', 'min:1', 'max:30000'],
            'canvas_mode' => ['nullable', Rule::in(['sketch', 'craft'])],
        ];
    }

    public function withValidator(Validator $validator): void
    {
        $validator->after(function (Validator $v) {
            $host = parse_url((string) $this->input('image_url'), PHP_URL_HOST) ?? '';
            $pattern = (string) config('app.s3_overlay_host_pattern');
            if ($pattern !== '' && ! str_contains($host, $pattern)) {
                $v->errors()->add('image_url', 'Image host is not trusted.');
            }
        });
    }
}
```

```php
<?php
// app/Http/Resources/KvMagicLayerJobResource.php

namespace App\Http\Resources;

use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

class KvMagicLayerJobResource extends JsonResource
{
    public function toArray(Request $request): array
    {
        return [
            'id' => $this->id,
            'studio_file_id' => $this->studio_file_id,
            'status' => $this->status->value,
            'error_message' => $this->error_message,
            'background_url' => $this->background_url,
            'generation' => $this->whenLoaded('generation', fn () => new KvGenerationResource($this->generation)),
            'overlays' => $this->layers ?? [],
            'created_at' => $this->created_at?->toISOString(),
        ];
    }
}
```

```php
<?php
// app/Http/Controllers/Api/Studio/KvMagicLayerJobController.php

namespace App\Http\Controllers\Api\Studio;

use App\Http\Controllers\Controller;
use App\Http\Requests\Studio\CreateKvMagicLayerJobRequest;
use App\Http\Resources\KvMagicLayerJobResource;
use App\Models\KvMagicLayerJob;
use App\Models\StudioFile;
use App\Services\Studio\KvMagicLayerJobService;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;

class KvMagicLayerJobController extends Controller
{
    public function __construct(private readonly KvMagicLayerJobService $service)
    {
    }

    public function store(string $id, CreateKvMagicLayerJobRequest $request): JsonResponse
    {
        $file = StudioFile::findOrFail($id);
        abort_unless($file->workspace_id === $request->user()->current_workspace_id, 403);

        $job = $this->service->createJob($file, $request->user('api'), $request->validated());

        return (new KvMagicLayerJobResource($job))->response()->setStatusCode(201);
    }

    public function show(string $id, string $jobId, Request $request): KvMagicLayerJobResource
    {
        $file = StudioFile::findOrFail($id);
        abort_unless($file->workspace_id === $request->user()->current_workspace_id, 403);

        $job = KvMagicLayerJob::where('studio_file_id', $file->id)->findOrFail($jobId);
        $this->service->failIfStale($job);

        return new KvMagicLayerJobResource($job->refresh()->load('generation'));
    }
}
```

In `routes/api.php`, inside the `feature.flag:show-kv-generator` group (import the controller at the top with the other Studio controllers):

```php
Route::post('kv-generator/files/{id}/magic-layer-jobs', [KvMagicLayerJobController::class, 'store']);
Route::get('kv-generator/files/{id}/magic-layer-jobs/{jobId}', [KvMagicLayerJobController::class, 'show']);
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `php artisan test tests/Feature/Studio/KvMagicLayerJobControllerTest.php`
Expected: 4 PASS

- [ ] **Step 5: Commit**

```bash
git add app/Http/Requests/Studio/CreateKvMagicLayerJobRequest.php \
  app/Http/Resources/KvMagicLayerJobResource.php \
  app/Http/Controllers/Api/Studio/KvMagicLayerJobController.php \
  routes/api.php tests/Feature/Studio/KvMagicLayerJobControllerTest.php
git commit -m "feat(api): magic-layer job create + poll endpoints"
```

---

### Task 4: Internal completion callback + metering

**Files:**
- Create: `app/Http/Requests/Internal/KvMagicLayerJobCompleteRequest.php`
- Create: `app/Http/Controllers/Api/Internal/KvMagicLayerJobInternalController.php`
- Modify: `routes/api.php` — next to `kv-resize-exports/completed` (~line 3654), **outside** any feature flag (callbacks must land even when the flag is off, same rationale as the comment at routes/api.php:3020-3024)
- Test: `tests/Feature/Internal/KvMagicLayerJobCallbackTest.php`

**Interfaces:**
- Produces: `POST /api/v1/internal/kv-magic-layer-jobs/completed` — accepts the callback contract from the ai-service plan; idempotent; meters `detect` + `inpaint` usage entries on success.

- [ ] **Step 1: Write the failing tests**

```php
<?php
// tests/Feature/Internal/KvMagicLayerJobCallbackTest.php

use App\Models\CostHistory;
use App\Models\KvMagicLayerJob;
use App\Models\StudioFile;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

uses(TestCase::class, RefreshDatabase::class);

beforeEach(function () {
    config(['services.internal.kv_callback_token' => 'secret-token']);
    $this->user = User::factory()->create();
    $this->file = StudioFile::factory()->create();
    $this->job = KvMagicLayerJob::factory()->create([
        'studio_file_id' => $this->file->id,
        'created_by' => $this->user->id,
        'status' => 'generating',
    ]);
});

function donePayload(KvMagicLayerJob $job): array
{
    return [
        'job_id' => $job->id,
        'status' => 'done',
        'background_url' => 'https://s3.test/bg.png',
        'ai_service_run_id' => 'run-1',
        'layers' => [
            ['kind' => 'subject', 'label' => 'person', 'image_url' => 'https://s3.test/cut.png',
             'x' => 0.1, 'y' => 0.1, 'width' => 0.3, 'height' => 0.5, 'z' => 1],
        ],
        'usage_entries' => [
            ['stage' => 'detect', 'model' => 'gpt-4o-mini',
             'token_usage' => ['input_text_tokens' => 900, 'output_text_tokens' => 120]],
            ['stage' => 'segment', 'model' => 'meta/sam-2', 'token_usage' => []],
            ['stage' => 'inpaint', 'model' => 'gpt-image-2',
             'token_usage' => ['input_text_tokens' => 40, 'input_image_tokens' => 300, 'output_image_tokens' => 4000]],
        ],
    ];
}

it('rejects a bad internal token', function () {
    $this->postJson('/api/v1/internal/kv-magic-layer-jobs/completed', donePayload($this->job), [
        'X-Internal-Token' => 'wrong',
    ])->assertUnauthorized();
});

it('persists results, marks done, and meters detect + inpaint', function () {
    $this->postJson('/api/v1/internal/kv-magic-layer-jobs/completed', donePayload($this->job), [
        'X-Internal-Token' => 'secret-token',
    ])->assertOk();

    $job = $this->job->refresh();
    expect($job->status->value)->toBe('done')
        ->and($job->generation_id)->not->toBeNull()
        ->and($this->file->refresh()->overlays)->toHaveCount(1);

    expect(CostHistory::where('batch_identifier', "kv_magic_layer_vision_{$job->id}_run-1")->exists())->toBeTrue()
        ->and(CostHistory::where('batch_identifier', "kv_magic_layer_{$job->id}_run-1")->exists())->toBeTrue();
});

it('marks failed without charging', function () {
    $this->postJson('/api/v1/internal/kv-magic-layer-jobs/completed', [
        'job_id' => $this->job->id,
        'status' => 'failed',
        'error_message' => 'no_layers_detected',
    ], ['X-Internal-Token' => 'secret-token'])->assertOk();

    expect($this->job->refresh()->status->value)->toBe('failed')
        ->and($this->job->error_message)->toBe('no_layers_detected')
        ->and(CostHistory::count())->toBe(0);
});

it('ignores callbacks for terminal jobs (idempotency)', function () {
    $this->job->update(['status' => 'done']);

    $this->postJson('/api/v1/internal/kv-magic-layer-jobs/completed', donePayload($this->job), [
        'X-Internal-Token' => 'secret-token',
    ])->assertOk()->assertJsonPath('ignored', true);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `php artisan test tests/Feature/Internal/KvMagicLayerJobCallbackTest.php`
Expected: FAIL — 404 (route missing)

- [ ] **Step 3: Implement**

```php
<?php
// app/Http/Requests/Internal/KvMagicLayerJobCompleteRequest.php

namespace App\Http\Requests\Internal;

use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Validation\Rule;

class KvMagicLayerJobCompleteRequest extends FormRequest
{
    use AuthorizesInternalKvCallback;

    public function rules(): array
    {
        return [
            'job_id' => ['required', 'string'],
            'status' => ['required', Rule::in(['done', 'failed'])],
            'background_url' => ['required_if:status,done', 'url'],
            'error_message' => ['required_if:status,failed', 'string'],
            'ai_service_run_id' => ['nullable', 'string'],
            'layers' => ['required_if:status,done', 'array', 'max:12'],
            'layers.*.kind' => ['required', Rule::in(['subject', 'text'])],
            'layers.*.label' => ['nullable', 'string', 'max:120'],
            'layers.*.image_url' => ['required', 'url'],
            'layers.*.x' => ['required', 'numeric', 'between:0,1'],
            'layers.*.y' => ['required', 'numeric', 'between:0,1'],
            'layers.*.width' => ['required', 'numeric', 'gt:0', 'lte:1'],
            'layers.*.height' => ['required', 'numeric', 'gt:0', 'lte:1'],
            'layers.*.z' => ['required', 'integer', 'min:1'],
            'usage_entries' => ['nullable', 'array'],
            'usage_entries.*.stage' => ['required', Rule::in(['detect', 'segment', 'inpaint'])],
            'usage_entries.*.model' => ['required', 'string'],
            'usage_entries.*.token_usage' => ['nullable', 'array'],
        ];
    }
}
```

```php
<?php
// app/Http/Controllers/Api/Internal/KvMagicLayerJobInternalController.php

namespace App\Http\Controllers\Api\Internal;

use App\Enums\KvMagicLayerJobStatus;
use App\Http\Controllers\Controller;
use App\Http\Requests\Internal\KvMagicLayerJobCompleteRequest;
use App\Models\KvMagicLayerJob;
use App\Models\User;
use App\Services\Studio\KvCreditMeteringService;
use App\Services\Studio\KvMagicLayerJobService;
use Illuminate\Http\JsonResponse;

class KvMagicLayerJobInternalController extends Controller
{
    public function __construct(
        private readonly KvMagicLayerJobService $service,
        private readonly KvCreditMeteringService $metering,
    ) {
    }

    public function completed(KvMagicLayerJobCompleteRequest $request): JsonResponse
    {
        $validated = $request->validated();

        $job = KvMagicLayerJob::with('file.workspace')->find($validated['job_id']);
        if (! $job) {
            return response()->json(['ok' => true, 'ignored' => true]);
        }
        if (! in_array($job->status, [KvMagicLayerJobStatus::Pending, KvMagicLayerJobStatus::Generating], true)) {
            return response()->json(['ok' => true, 'ignored' => true]);
        }

        if ($validated['status'] === 'failed') {
            $this->service->markFailed($job, $validated['error_message'] ?? 'unknown');

            return response()->json(['ok' => true]);
        }

        $job = $this->service->persistCompletion($job, $validated);
        $this->meterUsage($job, $validated);

        return response()->json(['ok' => true]);
    }

    private function meterUsage(KvMagicLayerJob $job, array $validated): void
    {
        $runId = $validated['ai_service_run_id'] ?? null;
        if (! $runId) {
            return;
        }
        $user = User::find($job->created_by);
        $workspace = $job->file?->workspace;
        if (! $user || ! $workspace) {
            return;
        }

        $byStage = collect($validated['usage_entries'] ?? [])->keyBy('stage');

        $detect = $byStage->get('detect');
        if ($detect && ! empty($detect['token_usage'])) {
            $this->metering->charge(
                user: $user, workspace: $workspace,
                costType: 'kv_magic_layer_vision', toolName: 'Magic Layers Vision Analysis',
                batchId: "kv_magic_layer_vision_{$job->id}_{$runId}",
                model: $detect['model'], tokenUsage: $detect['token_usage'],
                brandId: $job->file->brand_id,
            );
        }

        $inpaint = $byStage->get('inpaint');
        if ($inpaint && ! empty($inpaint['token_usage'])) {
            $this->metering->charge(
                user: $user, workspace: $workspace,
                costType: 'kv_magic_layer', toolName: 'Magic Layers',
                batchId: "kv_magic_layer_{$job->id}_{$runId}",
                model: $inpaint['model'], tokenUsage: $inpaint['token_usage'],
                brandId: $job->file->brand_id,
            );
        }
        // segment stage: Replicate per-prediction cost, no token usage — audited via
        // kv_magic_layer_jobs.usage_entries, flat pricing is a deliberate follow-up.
    }
}
```

In `routes/api.php`, next to the kv-resize callback (~line 3654), inside `Route::prefix('internal')` but outside feature flags:

```php
// KV Magic Layer completion callback (called by ai-service after decomposition)
Route::post('kv-magic-layer-jobs/completed', [
    KvMagicLayerJobInternalController::class,
    'completed',
]);
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `php artisan test tests/Feature/Internal/KvMagicLayerJobCallbackTest.php`
Expected: 4 PASS. If the credit assertions fail because `PricingHelper` prices the mocked usage at 0 credits, assert on `KvMagicLayerJob.usage_entries` persistence instead and verify metering with larger token numbers (mirror the assertions used in `tests/Feature/Internal/KvResizeExportCallbackCreditTest.php`).

- [ ] **Step 5: Run the KV-related suites**

Run: `php artisan test tests/Unit/Services/Studio tests/Feature/Studio/KvMagicLayerJobControllerTest.php tests/Feature/Internal/KvMagicLayerJobCallbackTest.php`
Expected: all PASS

- [ ] **Step 6: Commit**

```bash
git add app/Http/Requests/Internal/KvMagicLayerJobCompleteRequest.php \
  app/Http/Controllers/Api/Internal/KvMagicLayerJobInternalController.php \
  routes/api.php tests/Feature/Internal/KvMagicLayerJobCallbackTest.php
git commit -m "feat(api): magic-layer internal callback with overlay persistence and metering"
```
