# KV Generator — Resize Mode (API) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the API layer of KV Resize: a new `kv_resize_exports` table, model, resource, controller (CRUD + SSE stream), service, async job, and internal callback endpoint. Spec: [`docs/superpowers/specs/2026-04-28-studio-kv-resize-design.md`](../specs/2026-04-28-studio-kv-resize-design.md).

**Architecture:** Resize exports live in a new table keyed by `(parent_generation_id, platform_id)` (UNIQUE — UPSERT semantics). The controller dispatches a queued job per row that POSTs to the AI service; the AI service calls back through `/api/internal/kv-resize-exports/completed` to persist `image_url` + `status`. Status changes fan out over an SSE channel.

**Tech Stack:** Laravel 13, PHP 8.5, PostgreSQL, Pest. Reuses existing patterns from `KvGenerationService` / `KvGeneratorFileController`.

**Branch:** `feature/daffa/vc-studio-projects-kv-generator` (extension of in-flight feature; no new branch).

---

## File Structure

**New files:**
- `api/database/migrations/2026_04_28_120000_create_kv_resize_exports_table.php`
- `api/app/Models/KvResizeExport.php`
- `api/database/factories/KvResizeExportFactory.php`
- `api/app/Enums/KvResizeExportStatus.php`
- `api/app/Http/Resources/Studio/KvResizeExportResource.php`
- `api/app/Http/Controllers/Api/Studio/KvResizeExportController.php`
- `api/app/Http/Controllers/Api/Internal/KvResizeExportInternalController.php`
- `api/app/Services/Studio/KvResizeExportService.php`
- `api/app/Jobs/Studio/ProcessKvResizeExportJob.php`
- `api/tests/Feature/Studio/KvResizeExportControllerTest.php`
- `api/tests/Feature/Studio/KvResizeExportInternalCallbackTest.php`
- `api/tests/Unit/Services/Studio/KvResizeExportServiceTest.php`

**Modified files:**
- `api/config/studio.php` — add `resize_platforms` registry
- `api/routes/api.php` — register 5 public + 1 internal route

---

## Task 1: Platform registry config

**Files:**
- Modify: `api/config/studio.php`

- [ ] **Step 1: Add `resize_platforms` array to the existing config**

If `api/config/studio.php` doesn't exist yet, create it with:

```php
<?php

return [
    'resize_platforms' => [
        ['id' => 'instagram-post',       'label' => 'Instagram Post',       'group' => 'social-media', 'width' => 1080, 'height' => 1080],
        ['id' => 'instagram-story',      'label' => 'Instagram Story / Reel','group' => 'social-media','width' => 1080, 'height' => 1920],
        ['id' => 'instagram-landscape',  'label' => 'Instagram Landscape',  'group' => 'social-media', 'width' => 1080, 'height' => 566],
        ['id' => 'facebook-post',        'label' => 'Facebook Post',        'group' => 'social-media', 'width' => 1200, 'height' => 630],
        ['id' => 'facebook-cover',       'label' => 'Facebook Cover',       'group' => 'social-media', 'width' => 820,  'height' => 360],
        ['id' => 'tiktok-video',         'label' => 'TikTok Video',         'group' => 'social-media', 'width' => 1080, 'height' => 1920],
        ['id' => 'youtube-thumbnail',    'label' => 'YouTube Thumbnail',    'group' => 'social-media', 'width' => 1280, 'height' => 720],
        ['id' => 'linkedin-post',        'label' => 'LinkedIn Post',        'group' => 'social-media', 'width' => 1200, 'height' => 627],
        ['id' => 'twitter-post',         'label' => 'X / Twitter Post',     'group' => 'social-media', 'width' => 1200, 'height' => 675],
        ['id' => 'a4-portrait',          'label' => 'A4 Portrait',          'group' => 'print',        'width' => 1240, 'height' => 1754, 'note' => 'Preview quality'],
        ['id' => 'a4-landscape',         'label' => 'A4 Landscape',         'group' => 'print',        'width' => 1754, 'height' => 1240, 'note' => 'Preview quality'],
        ['id' => 'square-poster',        'label' => 'Square Poster',        'group' => 'print',        'width' => 1200, 'height' => 1200],
    ],
];
```

If the file exists, merge `resize_platforms` into it as a top-level key.

- [ ] **Step 2: Commit**

```bash
git add api/config/studio.php
git commit -m "feat(api): add KV resize platform registry to config"
```

---

## Task 2: Migration — `kv_resize_exports` table

**Files:**
- Create: `api/database/migrations/2026_04_28_120000_create_kv_resize_exports_table.php`

- [ ] **Step 1: Write the migration**

```php
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('kv_resize_exports', function (Blueprint $t) {
            $t->ulid('id')->primary();
            $t->foreignUlid('studio_file_id')->constrained('studio_files')->cascadeOnDelete();
            $t->foreignUlid('parent_generation_id')->constrained('kv_generations')->cascadeOnDelete();
            $t->foreignUlid('created_by')->constrained('users')->cascadeOnDelete();

            $t->string('platform_id', 64);
            $t->unsignedInteger('width');
            $t->unsignedInteger('height');

            $t->string('image_url')->nullable();
            $t->string('status', 16)->default('pending');
            $t->jsonb('crop_window')->nullable();
            $t->text('error_message')->nullable();

            $t->timestamps();
            $t->softDeletes();

            $t->unique(
                ['parent_generation_id', 'platform_id'],
                'kv_resize_exports_parent_platform_unique'
            );
            $t->index(
                ['studio_file_id', 'parent_generation_id', 'created_at'],
                'kv_resize_exports_file_parent_idx'
            );
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('kv_resize_exports');
    }
};
```

- [ ] **Step 2: Run the migration locally**

```bash
cd api && php artisan migrate
```

Expected: `2026_04_28_120000_create_kv_resize_exports_table` migrates successfully.

- [ ] **Step 3: Commit**

```bash
git add api/database/migrations/2026_04_28_120000_create_kv_resize_exports_table.php
git commit -m "feat(api): add kv_resize_exports table"
```

---

## Task 3: Status enum

**Files:**
- Create: `api/app/Enums/KvResizeExportStatus.php`

- [ ] **Step 1: Write the enum**

```php
<?php

namespace App\Enums;

enum KvResizeExportStatus: string
{
    case Pending = 'pending';
    case Generating = 'generating';
    case Done = 'done';
    case Failed = 'failed';
}
```

- [ ] **Step 2: Commit**

```bash
git add api/app/Enums/KvResizeExportStatus.php
git commit -m "feat(api): add KvResizeExportStatus enum"
```

---

## Task 4: Eloquent model

**Files:**
- Create: `api/app/Models/KvResizeExport.php`

- [ ] **Step 1: Write the model**

```php
<?php

namespace App\Models;

use App\Enums\KvResizeExportStatus;
use Illuminate\Database\Eloquent\Concerns\HasUlids;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\SoftDeletes;

class KvResizeExport extends Model
{
    use HasFactory, HasUlids, SoftDeletes;

    protected $table = 'kv_resize_exports';

    protected $fillable = [
        'studio_file_id',
        'parent_generation_id',
        'created_by',
        'platform_id',
        'width',
        'height',
        'image_url',
        'status',
        'crop_window',
        'error_message',
    ];

    protected $casts = [
        'crop_window' => 'array',
        'width' => 'integer',
        'height' => 'integer',
        'status' => KvResizeExportStatus::class,
    ];

    public function file(): BelongsTo
    {
        return $this->belongsTo(StudioFile::class, 'studio_file_id');
    }

    public function parentGeneration(): BelongsTo
    {
        return $this->belongsTo(KvGeneration::class, 'parent_generation_id');
    }

    public function creator(): BelongsTo
    {
        return $this->belongsTo(User::class, 'created_by');
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add api/app/Models/KvResizeExport.php
git commit -m "feat(api): add KvResizeExport model"
```

---

## Task 5: Factory

**Files:**
- Create: `api/database/factories/KvResizeExportFactory.php`

- [ ] **Step 1: Write the factory**

```php
<?php

namespace Database\Factories;

use App\Enums\KvResizeExportStatus;
use App\Models\KvResizeExport;
use App\Models\KvGeneration;
use App\Models\StudioFile;
use App\Models\User;
use Illuminate\Database\Eloquent\Factories\Factory;

class KvResizeExportFactory extends Factory
{
    protected $model = KvResizeExport::class;

    public function definition(): array
    {
        return [
            'studio_file_id' => StudioFile::factory(),
            'parent_generation_id' => KvGeneration::factory(),
            'created_by' => User::factory(),
            'platform_id' => 'instagram-post',
            'width' => 1080,
            'height' => 1080,
            'image_url' => null,
            'status' => KvResizeExportStatus::Pending,
            'crop_window' => null,
            'error_message' => null,
        ];
    }

    public function done(string $imageUrl = 'https://example.com/test.png'): self
    {
        return $this->state(fn () => [
            'status' => KvResizeExportStatus::Done,
            'image_url' => $imageUrl,
        ]);
    }

    public function failed(string $error = 'Test failure'): self
    {
        return $this->state(fn () => [
            'status' => KvResizeExportStatus::Failed,
            'error_message' => $error,
        ]);
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add api/database/factories/KvResizeExportFactory.php
git commit -m "feat(api): add KvResizeExportFactory"
```

---

## Task 6: Resource

**Files:**
- Create: `api/app/Http/Resources/Studio/KvResizeExportResource.php`

- [ ] **Step 1: Write the resource**

```php
<?php

namespace App\Http\Resources\Studio;

use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

class KvResizeExportResource extends JsonResource
{
    public function toArray(Request $request): array
    {
        $registry = collect(config('studio.resize_platforms'));
        $platform = $registry->firstWhere('id', $this->platform_id) ?? [];

        return [
            'id' => $this->id,
            'studio_file_id' => $this->studio_file_id,
            'parent_generation_id' => $this->parent_generation_id,
            'platform_id' => $this->platform_id,
            'platform_label' => $platform['label'] ?? $this->platform_id,
            'platform_group' => $platform['group'] ?? null,
            'width' => $this->width,
            'height' => $this->height,
            'image_url' => $this->image_url,
            'status' => $this->status?->value,
            'crop_window' => $this->crop_window,
            'error_message' => $this->error_message,
            'created_at' => $this->created_at?->toIso8601String(),
            'updated_at' => $this->updated_at?->toIso8601String(),
        ];
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add api/app/Http/Resources/Studio/KvResizeExportResource.php
git commit -m "feat(api): add KvResizeExportResource"
```

---

## Task 7: Service — write failing test for `createBatch`

**Files:**
- Create: `api/tests/Unit/Services/Studio/KvResizeExportServiceTest.php`

- [ ] **Step 1: Write the failing test**

```php
<?php

use App\Enums\KvResizeExportStatus;
use App\Models\KvGeneration;
use App\Models\KvResizeExport;
use App\Models\StudioFile;
use App\Models\User;
use App\Services\Studio\KvResizeExportService;

beforeEach(function () {
    $this->user = User::factory()->create();
    $this->file = StudioFile::factory()->create();
    $this->generation = KvGeneration::factory()->create([
        'studio_file_id' => $this->file->id,
        'version_number' => 1,
    ]);
    $this->service = app(KvResizeExportService::class);
});

it('creates one row per platform with pending status', function () {
    $rows = $this->service->createBatch(
        $this->file,
        $this->generation,
        ['instagram-post', 'tiktok-video'],
        cropWindowMap: [],
        userId: $this->user->id,
    );

    expect($rows)->toHaveCount(2);
    expect($rows->pluck('status')->all())
        ->each->toBe(KvResizeExportStatus::Pending);
    expect($rows->pluck('platform_id')->sort()->values()->all())
        ->toBe(['instagram-post', 'tiktok-video']);
});

it('is idempotent — repeated calls return existing rows', function () {
    $first = $this->service->createBatch(
        $this->file, $this->generation, ['instagram-post'],
        cropWindowMap: [], userId: $this->user->id,
    );
    $second = $this->service->createBatch(
        $this->file, $this->generation, ['instagram-post'],
        cropWindowMap: [], userId: $this->user->id,
    );

    expect($second->first()->id)->toBe($first->first()->id);
    expect(KvResizeExport::count())->toBe(1);
});

it('rejects unknown platform ids', function () {
    expect(fn () => $this->service->createBatch(
        $this->file, $this->generation, ['no-such-platform'],
        cropWindowMap: [], userId: $this->user->id,
    ))->toThrow(InvalidArgumentException::class);
});

it('records correct width and height from registry', function () {
    $rows = $this->service->createBatch(
        $this->file, $this->generation, ['tiktok-video'],
        cropWindowMap: [], userId: $this->user->id,
    );

    expect($rows->first()->width)->toBe(1080);
    expect($rows->first()->height)->toBe(1920);
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd api && php artisan test --filter=KvResizeExportServiceTest
```

Expected: FAIL with "Class App\\Services\\Studio\\KvResizeExportService does not exist".

---

## Task 8: Service — implement `createBatch` + `regenerate`

**Files:**
- Create: `api/app/Services/Studio/KvResizeExportService.php`

- [ ] **Step 1: Write the service**

```php
<?php

namespace App\Services\Studio;

use App\Enums\KvResizeExportStatus;
use App\Jobs\Studio\ProcessKvResizeExportJob;
use App\Models\KvGeneration;
use App\Models\KvResizeExport;
use App\Models\StudioFile;
use Illuminate\Support\Collection;
use InvalidArgumentException;

class KvResizeExportService
{
    /**
     * Create one resize export per platform id (idempotent on the unique
     * (parent_generation_id, platform_id) constraint). Existing rows are
     * returned untouched. Newly-created rows are dispatched to the AI service.
     *
     * @param  array<int, string>  $platformIds
     * @param  array<string, array{x:int,y:int,w:int,h:int}>  $cropWindowMap
     */
    public function createBatch(
        StudioFile $file,
        KvGeneration $parent,
        array $platformIds,
        array $cropWindowMap,
        string $userId,
    ): Collection {
        $registry = collect(config('studio.resize_platforms'));
        $rows = collect();

        foreach ($platformIds as $platformId) {
            $platform = $registry->firstWhere('id', $platformId);
            if (! $platform) {
                throw new InvalidArgumentException("Unknown platform: {$platformId}");
            }

            $existing = KvResizeExport::where('parent_generation_id', $parent->id)
                ->where('platform_id', $platformId)
                ->first();

            if ($existing) {
                $rows->push($existing);
                continue;
            }

            $row = KvResizeExport::create([
                'studio_file_id' => $file->id,
                'parent_generation_id' => $parent->id,
                'created_by' => $userId,
                'platform_id' => $platformId,
                'width' => $platform['width'],
                'height' => $platform['height'],
                'status' => KvResizeExportStatus::Pending,
                'crop_window' => $cropWindowMap[$platformId] ?? null,
            ]);

            $rows->push($row);
            ProcessKvResizeExportJob::dispatch($row->id);
        }

        return $rows;
    }

    public function regenerate(KvResizeExport $row, ?array $cropWindow): KvResizeExport
    {
        $row->update([
            'status' => KvResizeExportStatus::Pending,
            'image_url' => null,
            'error_message' => null,
            'crop_window' => $cropWindow,
        ]);

        ProcessKvResizeExportJob::dispatch($row->id);

        return $row->refresh();
    }

    public function markGenerating(KvResizeExport $row): void
    {
        $row->update(['status' => KvResizeExportStatus::Generating]);
    }

    public function markDone(KvResizeExport $row, string $imageUrl): void
    {
        $row->update([
            'status' => KvResizeExportStatus::Done,
            'image_url' => $imageUrl,
            'error_message' => null,
        ]);
    }

    public function markFailed(KvResizeExport $row, string $errorMessage): void
    {
        $row->update([
            'status' => KvResizeExportStatus::Failed,
            'error_message' => $errorMessage,
        ]);
    }
}
```

- [ ] **Step 2: Run test to verify it passes**

```bash
cd api && php artisan test --filter=KvResizeExportServiceTest
```

Expected: 4 tests pass. (The job dispatch fires but is captured by Pest's default queue fake or the test will need `Queue::fake()` — if tests fail due to job dispatch, add `Queue::fake()` in `beforeEach()`.)

- [ ] **Step 3: Commit**

```bash
git add api/app/Services/Studio/KvResizeExportService.php \
        api/tests/Unit/Services/Studio/KvResizeExportServiceTest.php
git commit -m "feat(api): add KvResizeExportService with createBatch and regenerate"
```

---

## Task 9: Job — `ProcessKvResizeExportJob`

**Files:**
- Create: `api/app/Jobs/Studio/ProcessKvResizeExportJob.php`

- [ ] **Step 1: Write the job**

```php
<?php

namespace App\Jobs\Studio;

use App\Models\KvResizeExport;
use App\Services\Studio\KvResizeExportService;
use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Queue\SerializesModels;
use Illuminate\Support\Facades\Http;

class ProcessKvResizeExportJob implements ShouldQueue
{
    use Dispatchable, InteractsWithQueue, Queueable, SerializesModels;

    public int $tries = 3;
    public int $timeout = 300;
    public string $queue = 'default';

    public function __construct(public string $exportId) {}

    public function handle(KvResizeExportService $service): void
    {
        $row = KvResizeExport::with('parentGeneration')->find($this->exportId);
        if (! $row) {
            return;
        }

        $service->markGenerating($row);

        $aiUrl = rtrim(config('services.ai_service.url'), '/');
        $response = Http::timeout(120)
            ->retry(2, 500)
            ->post("{$aiUrl}/ai/kv-resize/export", [
                'export_id' => $row->id,
                'source_image_url' => $row->parentGeneration->image_url,
                'target_width' => $row->width,
                'target_height' => $row->height,
                'crop_window' => $row->crop_window,
            ]);

        if ($response->failed()) {
            $service->markFailed($row, "AI service error: {$response->status()}");
            return;
        }
        // AI service responds 202; final status comes via internal callback.
    }

    public function failed(\Throwable $e): void
    {
        $row = KvResizeExport::find($this->exportId);
        if ($row) {
            app(KvResizeExportService::class)
                ->markFailed($row, "Job failed: {$e->getMessage()}");
        }
    }
}
```

- [ ] **Step 2: Verify config has `services.ai_service.url`**

```bash
grep -A2 "ai_service" api/config/services.php
```

If missing, add to `api/config/services.php`:

```php
'ai_service' => [
    'url' => env('AI_SERVICE_URL', 'http://localhost:8000'),
],
```

- [ ] **Step 3: Commit**

```bash
git add api/app/Jobs/Studio/ProcessKvResizeExportJob.php api/config/services.php
git commit -m "feat(api): add ProcessKvResizeExportJob"
```

---

## Task 10: Controller — write failing tests

**Files:**
- Create: `api/tests/Feature/Studio/KvResizeExportControllerTest.php`

- [ ] **Step 1: Write the failing tests**

```php
<?php

use App\Enums\KvResizeExportStatus;
use App\Models\KvGeneration;
use App\Models\KvResizeExport;
use App\Models\StudioFile;
use App\Models\User;
use Illuminate\Support\Facades\Queue;

beforeEach(function () {
    Queue::fake();
    $this->user = User::factory()->create();
    $this->file = StudioFile::factory()->for($this->user, 'creator')->create();
    $this->generation = KvGeneration::factory()->create([
        'studio_file_id' => $this->file->id,
        'version_number' => 1,
        'image_url' => 'https://example.com/source.png',
    ]);
    $this->actingAs($this->user);
});

it('lists exports for the latest generation of a file', function () {
    KvResizeExport::factory()->count(2)->create([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $this->generation->id,
    ]);

    $resp = $this->getJson("/api/studio/files/{$this->file->id}/resize-exports");

    $resp->assertOk();
    $resp->assertJsonCount(2, 'data');
});

it('creates exports for the selected platforms', function () {
    $resp = $this->postJson("/api/studio/files/{$this->file->id}/resize-exports", [
        'parent_generation_id' => $this->generation->id,
        'platform_ids' => ['instagram-post', 'tiktok-video'],
    ]);

    $resp->assertStatus(202);
    $resp->assertJsonCount(2, 'data');
    expect(KvResizeExport::count())->toBe(2);
});

it('rejects unknown platform ids', function () {
    $resp = $this->postJson("/api/studio/files/{$this->file->id}/resize-exports", [
        'parent_generation_id' => $this->generation->id,
        'platform_ids' => ['no-such-platform'],
    ]);

    $resp->assertStatus(422);
});

it('rejects when parent_generation is not the latest', function () {
    $newer = KvGeneration::factory()->create([
        'studio_file_id' => $this->file->id,
        'version_number' => 2,
        'image_url' => 'https://example.com/v2.png',
    ]);

    $resp = $this->postJson("/api/studio/files/{$this->file->id}/resize-exports", [
        'parent_generation_id' => $this->generation->id,
        'platform_ids' => ['instagram-post'],
    ]);

    $resp->assertStatus(409);
});

it('regenerates a single export', function () {
    $row = KvResizeExport::factory()->done()->create([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $this->generation->id,
        'platform_id' => 'instagram-post',
    ]);

    $resp = $this->postJson(
        "/api/studio/files/{$this->file->id}/resize-exports/{$row->id}/regenerate",
        ['crop_window' => ['x' => 10, 'y' => 20, 'w' => 100, 'h' => 100]]
    );

    $resp->assertStatus(202);
    expect($row->fresh()->status)->toBe(KvResizeExportStatus::Pending);
    expect($row->fresh()->crop_window)->toBe(['x' => 10, 'y' => 20, 'w' => 100, 'h' => 100]);
});

it('soft-deletes an export', function () {
    $row = KvResizeExport::factory()->create([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $this->generation->id,
    ]);

    $resp = $this->deleteJson("/api/studio/files/{$this->file->id}/resize-exports/{$row->id}");

    $resp->assertNoContent();
    expect($row->fresh()->trashed())->toBeTrue();
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd api && php artisan test --filter=KvResizeExportControllerTest
```

Expected: FAIL — routes not registered.

---

## Task 11: Controller — implement endpoints

**Files:**
- Create: `api/app/Http/Controllers/Api/Studio/KvResizeExportController.php`

- [ ] **Step 1: Write the controller**

```php
<?php

namespace App\Http\Controllers\Api\Studio;

use App\Http\Controllers\Controller;
use App\Http\Resources\Studio\KvResizeExportResource;
use App\Models\KvGeneration;
use App\Models\KvResizeExport;
use App\Models\StudioFile;
use App\Services\Studio\KvResizeExportService;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Http\Response;
use Symfony\Component\HttpFoundation\StreamedResponse;

class KvResizeExportController extends Controller
{
    public function __construct(private KvResizeExportService $service) {}

    public function index(StudioFile $file): JsonResponse
    {
        $latest = KvGeneration::where('studio_file_id', $file->id)
            ->orderByDesc('version_number')
            ->first();

        if (! $latest) {
            return response()->json(['data' => []]);
        }

        $rows = KvResizeExport::where('studio_file_id', $file->id)
            ->where('parent_generation_id', $latest->id)
            ->orderBy('created_at')
            ->get();

        return response()->json([
            'data' => KvResizeExportResource::collection($rows)->resolve(),
        ]);
    }

    public function store(Request $request, StudioFile $file): JsonResponse
    {
        $registryIds = collect(config('studio.resize_platforms'))->pluck('id')->all();

        $validated = $request->validate([
            'parent_generation_id' => 'required|string',
            'platform_ids' => 'required|array|min:1',
            'platform_ids.*' => ['required', 'string', 'in:' . implode(',', $registryIds)],
            'crop_windows' => 'nullable|array',
        ]);

        $parent = KvGeneration::where('studio_file_id', $file->id)
            ->where('id', $validated['parent_generation_id'])
            ->firstOrFail();

        $latest = KvGeneration::where('studio_file_id', $file->id)
            ->orderByDesc('version_number')
            ->first();

        if ($latest->id !== $parent->id) {
            return response()->json([
                'message' => 'A newer generation exists. Refresh and try again.',
            ], Response::HTTP_CONFLICT);
        }

        $rows = $this->service->createBatch(
            file: $file,
            parent: $parent,
            platformIds: $validated['platform_ids'],
            cropWindowMap: $validated['crop_windows'] ?? [],
            userId: $request->user()->id,
        );

        return response()->json([
            'data' => KvResizeExportResource::collection($rows)->resolve(),
        ], Response::HTTP_ACCEPTED);
    }

    public function regenerate(Request $request, StudioFile $file, KvResizeExport $export): JsonResponse
    {
        abort_unless($export->studio_file_id === $file->id, 404);

        $validated = $request->validate([
            'crop_window' => 'nullable|array',
            'crop_window.x' => 'required_with:crop_window|integer|min:0',
            'crop_window.y' => 'required_with:crop_window|integer|min:0',
            'crop_window.w' => 'required_with:crop_window|integer|min:1',
            'crop_window.h' => 'required_with:crop_window|integer|min:1',
        ]);

        $row = $this->service->regenerate($export, $validated['crop_window'] ?? null);

        return response()->json([
            'data' => (new KvResizeExportResource($row))->resolve(),
        ], Response::HTTP_ACCEPTED);
    }

    public function destroy(StudioFile $file, KvResizeExport $export): Response
    {
        abort_unless($export->studio_file_id === $file->id, 404);
        $export->delete();

        return response()->noContent();
    }

    public function stream(StudioFile $file): StreamedResponse
    {
        return new StreamedResponse(function () use ($file) {
            $lastSeen = now()->subSeconds(5);

            while (true) {
                if (connection_aborted()) {
                    break;
                }

                $rows = KvResizeExport::where('studio_file_id', $file->id)
                    ->where('updated_at', '>', $lastSeen)
                    ->orderBy('updated_at')
                    ->get();

                foreach ($rows as $row) {
                    $payload = json_encode((new KvResizeExportResource($row))->resolve());
                    echo "event: export.updated\n";
                    echo "data: {$payload}\n\n";
                    @ob_flush();
                    @flush();
                    $lastSeen = $row->updated_at;
                }

                $pendingOrGenerating = KvResizeExport::where('studio_file_id', $file->id)
                    ->whereIn('status', ['pending', 'generating'])
                    ->exists();

                if (! $pendingOrGenerating && $rows->isEmpty()) {
                    break;
                }

                usleep(750_000); // 0.75s tick
            }
        }, 200, [
            'Content-Type' => 'text/event-stream',
            'Cache-Control' => 'no-cache',
            'X-Accel-Buffering' => 'no',
        ]);
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add api/app/Http/Controllers/Api/Studio/KvResizeExportController.php
git commit -m "feat(api): add KvResizeExportController with CRUD and SSE stream"
```

---

## Task 12: Routes

**Files:**
- Modify: `api/routes/api.php`

- [ ] **Step 1: Register routes**

Find the existing `studio` group (around the `kv-generator/files` routes) and add inside it:

```php
Route::get('studio/files/{file}/resize-exports', [
    \App\Http\Controllers\Api\Studio\KvResizeExportController::class,
    'index',
]);
Route::post('studio/files/{file}/resize-exports', [
    \App\Http\Controllers\Api\Studio\KvResizeExportController::class,
    'store',
]);
Route::post('studio/files/{file}/resize-exports/{export}/regenerate', [
    \App\Http\Controllers\Api\Studio\KvResizeExportController::class,
    'regenerate',
]);
Route::delete('studio/files/{file}/resize-exports/{export}', [
    \App\Http\Controllers\Api\Studio\KvResizeExportController::class,
    'destroy',
]);
Route::get('studio/files/{file}/resize-exports/stream', [
    \App\Http\Controllers\Api\Studio\KvResizeExportController::class,
    'stream',
]);
```

If the existing studio group uses `auth:sanctum`, ensure these routes inherit it. Otherwise wrap them in a `Route::middleware('auth:sanctum')->group(...)` matching the surrounding pattern.

- [ ] **Step 2: Run tests to verify controller tests now pass**

```bash
cd api && php artisan test --filter=KvResizeExportControllerTest
```

Expected: 6 tests pass.

- [ ] **Step 3: Commit**

```bash
git add api/routes/api.php
git commit -m "feat(api): register KV resize export routes"
```

---

## Task 13: Internal callback — write failing test

**Files:**
- Create: `api/tests/Feature/Studio/KvResizeExportInternalCallbackTest.php`

- [ ] **Step 1: Write the failing tests**

```php
<?php

use App\Enums\KvResizeExportStatus;
use App\Models\KvResizeExport;

it('persists image_url and marks done', function () {
    $row = KvResizeExport::factory()->create([
        'status' => KvResizeExportStatus::Generating,
    ]);

    $resp = $this->postJson('/api/internal/kv-resize-exports/completed', [
        'export_id' => $row->id,
        'status' => 'done',
        'image_url' => 'https://cdn.example.com/out.png',
    ]);

    $resp->assertOk();
    $row->refresh();
    expect($row->status)->toBe(KvResizeExportStatus::Done);
    expect($row->image_url)->toBe('https://cdn.example.com/out.png');
});

it('marks failed with error_message', function () {
    $row = KvResizeExport::factory()->create([
        'status' => KvResizeExportStatus::Generating,
    ]);

    $resp = $this->postJson('/api/internal/kv-resize-exports/completed', [
        'export_id' => $row->id,
        'status' => 'failed',
        'error_message' => 'flux rate-limited',
    ]);

    $resp->assertOk();
    $row->refresh();
    expect($row->status)->toBe(KvResizeExportStatus::Failed);
    expect($row->error_message)->toBe('flux rate-limited');
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd api && php artisan test --filter=KvResizeExportInternalCallback
```

Expected: FAIL — route not registered.

---

## Task 14: Internal callback — implement

**Files:**
- Create: `api/app/Http/Controllers/Api/Internal/KvResizeExportInternalController.php`
- Modify: `api/routes/api.php`

- [ ] **Step 1: Write the controller**

```php
<?php

namespace App\Http\Controllers\Api\Internal;

use App\Http\Controllers\Controller;
use App\Models\KvResizeExport;
use App\Services\Studio\KvResizeExportService;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;

class KvResizeExportInternalController extends Controller
{
    public function __construct(private KvResizeExportService $service) {}

    public function completed(Request $request): JsonResponse
    {
        $validated = $request->validate([
            'export_id' => 'required|string',
            'status' => 'required|in:done,failed',
            'image_url' => 'required_if:status,done|nullable|url',
            'error_message' => 'required_if:status,failed|nullable|string',
        ]);

        $row = KvResizeExport::findOrFail($validated['export_id']);

        if ($validated['status'] === 'done') {
            $this->service->markDone($row, $validated['image_url']);
        } else {
            $this->service->markFailed($row, $validated['error_message']);
        }

        return response()->json(['ok' => true]);
    }
}
```

- [ ] **Step 2: Register the route**

In `api/routes/api.php`, add (or inside the existing `internal` prefix group if there is one):

```php
Route::post('internal/kv-resize-exports/completed', [
    \App\Http\Controllers\Api\Internal\KvResizeExportInternalController::class,
    'completed',
]);
```

If the project has internal-callback authentication middleware (check `api/routes/api.php` for `internal` group), apply it here too.

- [ ] **Step 3: Run tests**

```bash
cd api && php artisan test --filter=KvResizeExportInternalCallback
```

Expected: 2 tests pass.

- [ ] **Step 4: Commit**

```bash
git add api/app/Http/Controllers/Api/Internal/KvResizeExportInternalController.php \
        api/routes/api.php \
        api/tests/Feature/Studio/KvResizeExportInternalCallbackTest.php
git commit -m "feat(api): add internal callback for KV resize export completion"
```

---

## Task 15: Final verification

- [ ] **Step 1: Run the full test suite**

```bash
cd api && php artisan test --parallel
```

Expected: all tests pass.

- [ ] **Step 2: Verify migrations run cleanly on a fresh DB**

```bash
cd api && php artisan migrate:fresh --env=testing
```

Expected: all migrations including the new one apply without errors.

- [ ] **Step 3: Self-check**

- All endpoints return the expected resource shape (curl spot-check or open the file in `KvResizeExportControllerTest` and verify resource fields).
- The job is dispatched on `createBatch` (Queue::fake assertion in test).
- The internal callback is reachable from the AI service (verify `internal/kv-resize-exports/completed` is in the route list with `php artisan route:list | grep resize`).

- [ ] **Step 4: Update the track file**

```bash
# Find the track file
ls api/docs/tracks/ 2>/dev/null
```

Append a session log entry to the relevant track (`studio-projects-kv-generator.track.md`) noting the resize endpoints landed.

---

## Self-review

- ✅ Spec § Data model → Task 2 (migration) + Task 4 (model)
- ✅ Spec § API contract (5 public endpoints + 1 internal) → Tasks 11, 12, 14
- ✅ Spec § Edge cases (idempotency, 409 on stale parent, soft delete) → Tasks 7, 10, 13
- ✅ Spec § Platform registry → Task 1
- ✅ Spec § Status enum → Task 3
- ✅ Spec § Tests → Tasks 7, 10, 13 (unit + feature)
- ✅ No placeholders; every step has full code
- ✅ Method signatures consistent across tasks (`createBatch`, `regenerate`, `markDone`, `markFailed`)
