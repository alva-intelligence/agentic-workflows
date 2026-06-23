# KV Motion Generation — api Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist KV motion (video) generations attached to a KV file, dispatch generation to ai-service via a queued job, and record the resulting video + credit usage via an internal callback.

**Architecture:** Mirror the KV **Resize export** feature (`KvResizeExport*`), but single-row per request instead of a per-platform batch. A `KvMotionController` creates a `pending` row and dispatches `GenerateKvMotionJob`, which marks it `generating` and POSTs to `POST {AI_URL}/ai/kv-motion/generate`. ai-service later calls `POST /api/v1/internal/kv-motion-generations/completed`, handled by `KvMotionGenerationInternalController`, which sets the video URL and meters credits via the existing `KvCreditMeteringService`.

**Tech Stack:** Laravel 13, PHP 8.5, PostgreSQL, queued Jobs, Pest/PHPUnit (Unit tests only — see caution).

**Spec:** `docs/superpowers/specs/2026-06-23-kv-motion-generation-design.md`

> **DB-TEST CAUTION (read first):** Before running ANY DB-touching test, verify
> `api/phpunit.xml` has the SQLite test-connection override **active** (not
> commented) and `tests/Pest.php` isolation is intact. A previously-commented
> SQLite override once wiped the dev Postgres DB. The api **Feature** suite is
> additionally blocked by the workspaces backfill + SoftDeletes migration on a
> fresh migrate — use **Unit** tests here, exactly like the existing
> `tests/Unit/Services/Studio/KvResizeExportServiceTest.php`.

**Working directory for all paths below:** `api/`

---

## File Structure

- Create: `database/migrations/2026_06_24_100000_create_kv_motion_generations_table.php`
- Create: `app/Enums/KvMotionGenerationStatus.php`
- Create: `app/Models/KvMotionGeneration.php`
- Create: `app/Http/Requests/Studio/StoreKvMotionRequest.php`
- Create: `app/Http/Requests/Internal/KvMotionGenerationCompleteRequest.php`
- Create: `app/Services/Studio/KvMotionService.php`
- Create: `app/Jobs/Studio/GenerateKvMotionJob.php`
- Create: `app/Http/Controllers/Api/Studio/KvMotionController.php`
- Create: `app/Http/Controllers/Api/Internal/KvMotionGenerationInternalController.php`
- Create: `app/Http/Resources/Studio/KvMotionGenerationResource.php`
- Modify: `routes/api.php` (studio routes + internal callback route)
- Create: `database/factories/KvMotionGenerationFactory.php`
- Create: `tests/Unit/Services/Studio/KvMotionServiceTest.php`
- Create: `tests/Unit/Http/Requests/StoreKvMotionRequestTest.php`

**Contract** — see the ai-service plan. Request to ai-service:
`{generation_id, source_image_url, model, provider, preset, prompt, duration, ratio}`.
Callback from ai-service:
`{generation_id, status, video_url?, error_message?, token_usage?, ai_service_run_id?, model?}`.

---

## Task 1: Migration, status enum, model, factory

**Files:**
- Create migration, enum, model, factory (paths above)

- [ ] **Step 1: Create the status enum**

```php
// app/Enums/KvMotionGenerationStatus.php
<?php

namespace App\Enums;

enum KvMotionGenerationStatus: string
{
    case Pending = 'pending';
    case Generating = 'generating';
    case Done = 'done';
    case Failed = 'failed';
}
```

- [ ] **Step 2: Create the migration** (mirror `2026_04_28_..._create_kv_resize_exports_table.php`)

```php
// database/migrations/2026_06_24_100000_create_kv_motion_generations_table.php
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('kv_motion_generations', function (Blueprint $t) {
            $t->ulid('id')->primary();
            $t->foreignUlid('studio_file_id')->constrained('studio_files')->cascadeOnDelete();
            $t->foreignUlid('parent_generation_id')->constrained('kv_generations')->cascadeOnDelete();
            $t->foreignUlid('created_by')->constrained('users')->cascadeOnDelete();
            // Guided-regenerate lineage: points at the motion row this was re-run from.
            $t->foreignUlid('parent_motion_id')->nullable()
                ->constrained('kv_motion_generations')->nullOnDelete();

            $t->string('model');               // e.g. veo-3.1-fast-generate-preview
            $t->string('provider');            // google | kuaishou | openai
            $t->string('preset')->nullable();  // preset key (null if prompt-only)
            $t->text('prompt')->nullable();    // optional user steering
            $t->unsignedSmallInteger('duration'); // seconds: 4 | 8 | 12 | 15
            $t->string('ratio', 8);            // 16:9 | 9:16 | 1:1

            $t->string('status', 16)->default('pending');
            $t->string('video_url')->nullable();
            $t->text('error_message')->nullable();
            $t->string('ai_service_run_id')->nullable();

            $t->timestamps();
            $t->softDeletes();

            $t->index(
                ['studio_file_id', 'parent_generation_id', 'created_at'],
                'kv_motion_file_parent_idx'
            );
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('kv_motion_generations');
    }
};
```

- [ ] **Step 3: Create the model** (mirror `KvResizeExport`)

```php
// app/Models/KvMotionGeneration.php
<?php

namespace App\Models;

use App\Enums\KvMotionGenerationStatus;
use Illuminate\Database\Eloquent\Concerns\HasUlids;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\SoftDeletes;

class KvMotionGeneration extends Model
{
    use HasFactory, HasUlids, SoftDeletes;

    protected $table = 'kv_motion_generations';

    protected $fillable = [
        'studio_file_id',
        'parent_generation_id',
        'parent_motion_id',
        'created_by',
        'model',
        'provider',
        'preset',
        'prompt',
        'duration',
        'ratio',
        'status',
        'video_url',
        'error_message',
        'ai_service_run_id',
    ];

    protected $casts = [
        'duration' => 'integer',
        'status' => KvMotionGenerationStatus::class,
    ];

    public function file(): BelongsTo
    {
        return $this->belongsTo(StudioFile::class, 'studio_file_id');
    }

    public function parentGeneration(): BelongsTo
    {
        return $this->belongsTo(KvGeneration::class, 'parent_generation_id');
    }

    public function parentMotion(): BelongsTo
    {
        return $this->belongsTo(self::class, 'parent_motion_id');
    }

    public function creator(): BelongsTo
    {
        return $this->belongsTo(User::class, 'created_by');
    }
}
```

- [ ] **Step 4: Create the factory**

```php
// database/factories/KvMotionGenerationFactory.php
<?php

namespace Database\Factories;

use App\Models\KvMotionGeneration;
use Illuminate\Database\Eloquent\Factories\Factory;

class KvMotionGenerationFactory extends Factory
{
    protected $model = KvMotionGeneration::class;

    public function definition(): array
    {
        return [
            'model' => 'veo-3.1-fast-generate-preview',
            'provider' => 'google',
            'preset' => 'subtle_zoom',
            'prompt' => null,
            'duration' => 8,
            'ratio' => '9:16',
            'status' => 'pending',
        ];
    }
}
```

- [ ] **Step 5: Commit**

```bash
git add app/Enums/KvMotionGenerationStatus.php database/migrations/2026_06_24_100000_create_kv_motion_generations_table.php app/Models/KvMotionGeneration.php database/factories/KvMotionGenerationFactory.php
git commit -m "feat(api): kv_motion_generations table, model, enum, factory"
```

---

## Task 2: Store request validation

**Files:**
- Create: `app/Http/Requests/Studio/StoreKvMotionRequest.php`
- Test: `tests/Unit/Http/Requests/StoreKvMotionRequestTest.php`

- [ ] **Step 1: Write the failing test** (pure rules() validation — no DB)

```php
// tests/Unit/Http/Requests/StoreKvMotionRequestTest.php
<?php

use App\Http\Requests\Studio\StoreKvMotionRequest;
use Illuminate\Support\Facades\Validator;

function validateMotion(array $payload): \Illuminate\Contracts\Validation\Validator
{
    return Validator::make($payload, (new StoreKvMotionRequest())->rules());
}

it('passes with a valid payload', function () {
    $v = validateMotion([
        'parent_generation_id' => '01HX',
        'model' => 'veo-3.1-fast-generate-preview',
        'provider' => 'google',
        'preset' => 'subtle_zoom',
        'prompt' => null,
        'duration' => 8,
        'ratio' => '9:16',
    ]);
    expect($v->fails())->toBeFalse();
});

it('rejects an unknown provider', function () {
    $v = validateMotion([
        'parent_generation_id' => '01HX',
        'model' => 'x',
        'provider' => 'midjourney',
        'duration' => 8,
        'ratio' => '9:16',
    ]);
    expect($v->errors()->has('provider'))->toBeTrue();
});

it('rejects an invalid duration and ratio', function () {
    $v = validateMotion([
        'parent_generation_id' => '01HX',
        'model' => 'x',
        'provider' => 'google',
        'duration' => 7,
        'ratio' => '4:5',
    ]);
    expect($v->errors()->has('duration'))->toBeTrue();
    expect($v->errors()->has('ratio'))->toBeTrue();
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `php artisan test tests/Unit/Http/Requests/StoreKvMotionRequestTest.php`
Expected: FAIL — class not found

- [ ] **Step 3: Implement the request**

```php
// app/Http/Requests/Studio/StoreKvMotionRequest.php
<?php

namespace App\Http\Requests\Studio;

use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Validation\Rule;

class StoreKvMotionRequest extends FormRequest
{
    public function authorize(): bool
    {
        return $this->user() !== null;
    }

    public function rules(): array
    {
        return [
            'parent_generation_id' => ['required', 'string'],
            'parent_motion_id' => ['nullable', 'string'], // set on guided regenerate
            'model' => ['required', 'string', 'max:128'],
            'provider' => ['required', Rule::in(['google', 'kuaishou', 'openai'])],
            'preset' => ['nullable', 'string', 'max:64'],
            'prompt' => ['nullable', 'string', 'max:1000'], // already merged (base + steering) by web
            'duration' => ['required', 'integer', Rule::in([4, 8, 12, 15])],
            'ratio' => ['required', Rule::in(['16:9', '9:16', '1:1'])],
        ];
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `php artisan test tests/Unit/Http/Requests/StoreKvMotionRequestTest.php`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add app/Http/Requests/Studio/StoreKvMotionRequest.php tests/Unit/Http/Requests/StoreKvMotionRequestTest.php
git commit -m "feat(api): StoreKvMotionRequest validation"
```

---

## Task 3: Motion service (create + state transitions)

**Files:**
- Create: `app/Services/Studio/KvMotionService.php`
- Test: `tests/Unit/Services/Studio/KvMotionServiceTest.php`

- [ ] **Step 1: Write the failing test** (mirror `KvResizeExportServiceTest`)

```php
// tests/Unit/Services/Studio/KvMotionServiceTest.php
<?php

use App\Enums\KvMotionGenerationStatus;
use App\Models\KvGeneration;
use App\Models\KvMotionGeneration;
use App\Models\StudioFile;
use App\Models\User;
use App\Services\Studio\KvMotionService;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Queue;
use Tests\TestCase;

uses(TestCase::class, RefreshDatabase::class);

beforeEach(function () {
    Queue::fake();
    $this->user = User::factory()->create();
    $this->file = StudioFile::factory()->create();
    $this->generation = KvGeneration::factory()->create([
        'studio_file_id' => $this->file->id,
        'version_number' => 1,
    ]);
    $this->service = app(KvMotionService::class);
});

it('creates a pending row from a request', function () {
    $row = $this->service->create(
        file: $this->file,
        parent: $this->generation,
        userId: $this->user->id,
        model: 'veo-3.1-fast-generate-preview',
        provider: 'google',
        preset: 'subtle_zoom',
        prompt: null,
        duration: 8,
        ratio: '9:16',
    );

    expect($row->status)->toBe(KvMotionGenerationStatus::Pending);
    expect($row->parent_generation_id)->toBe($this->generation->id);
    expect($row->provider)->toBe('google');
});

it('transitions to generating, done, and failed', function () {
    $row = KvMotionGeneration::factory()->create([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $this->generation->id,
        'created_by' => $this->user->id,
    ]);

    $this->service->markGenerating($row);
    expect($row->fresh()->status)->toBe(KvMotionGenerationStatus::Generating);

    $this->service->markDone($row, 'https://cdn/x.mp4');
    expect($row->fresh()->status)->toBe(KvMotionGenerationStatus::Done);
    expect($row->fresh()->video_url)->toBe('https://cdn/x.mp4');

    $this->service->markFailed($row, 'boom');
    expect($row->fresh()->status)->toBe(KvMotionGenerationStatus::Failed);
    expect($row->fresh()->error_message)->toBe('boom');
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `php artisan test tests/Unit/Services/Studio/KvMotionServiceTest.php`
Expected: FAIL — class not found

- [ ] **Step 3: Implement the service**

```php
// app/Services/Studio/KvMotionService.php
<?php

namespace App\Services\Studio;

use App\Enums\KvMotionGenerationStatus;
use App\Models\KvGeneration;
use App\Models\KvMotionGeneration;
use App\Models\StudioFile;

class KvMotionService
{
    public function create(
        StudioFile $file,
        KvGeneration $parent,
        string $userId,
        string $model,
        string $provider,
        ?string $preset,
        ?string $prompt,
        int $duration,
        string $ratio,
        ?string $parentMotionId = null,
    ): KvMotionGeneration {
        return KvMotionGeneration::create([
            'studio_file_id' => $file->id,
            'parent_generation_id' => $parent->id,
            'parent_motion_id' => $parentMotionId,
            'created_by' => $userId,
            'model' => $model,
            'provider' => $provider,
            'preset' => $preset,
            'prompt' => $prompt,
            'duration' => $duration,
            'ratio' => $ratio,
            'status' => KvMotionGenerationStatus::Pending,
        ]);
    }

    public function markGenerating(KvMotionGeneration $row): void
    {
        $row->update(['status' => KvMotionGenerationStatus::Generating]);
    }

    public function markDone(KvMotionGeneration $row, string $videoUrl): void
    {
        $row->update([
            'status' => KvMotionGenerationStatus::Done,
            'video_url' => $videoUrl,
        ]);
    }

    public function markFailed(KvMotionGeneration $row, ?string $error): void
    {
        $row->update([
            'status' => KvMotionGenerationStatus::Failed,
            'error_message' => $error,
        ]);
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `php artisan test tests/Unit/Services/Studio/KvMotionServiceTest.php`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add app/Services/Studio/KvMotionService.php tests/Unit/Services/Studio/KvMotionServiceTest.php
git commit -m "feat(api): KvMotionService create + state transitions"
```

---

## Task 4: Job that POSTs to ai-service

**Files:**
- Create: `app/Jobs/Studio/GenerateKvMotionJob.php`

- [ ] **Step 1: Write the failing test** (fakes HTTP; asserts payload + generating transition)

```php
// tests/Unit/Jobs/Studio/GenerateKvMotionJobTest.php
<?php

use App\Enums\KvMotionGenerationStatus;
use App\Jobs\Studio\GenerateKvMotionJob;
use App\Models\KvGeneration;
use App\Models\KvMotionGeneration;
use App\Models\StudioFile;
use App\Models\User;
use App\Services\Studio\KvMotionService;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Http;
use Tests\TestCase;

uses(TestCase::class, RefreshDatabase::class);

it('marks generating and posts the motion payload to ai-service', function () {
    Http::fake(['*/ai/kv-motion/generate' => Http::response(['status' => 'accepted'], 202)]);
    config(['services.ai.url' => 'http://ai.test']);

    $user = User::factory()->create();
    $file = StudioFile::factory()->create();
    $parent = KvGeneration::factory()->create([
        'studio_file_id' => $file->id,
        'version_number' => 1,
        'image_url' => 'https://cdn/x.png',
    ]);
    $row = KvMotionGeneration::factory()->create([
        'studio_file_id' => $file->id,
        'parent_generation_id' => $parent->id,
        'created_by' => $user->id,
        'model' => 'veo-3.1-fast-generate-preview',
        'provider' => 'google',
        'preset' => 'subtle_zoom',
        'duration' => 8,
        'ratio' => '9:16',
    ]);

    (new GenerateKvMotionJob($row->id))->handle(app(KvMotionService::class));

    expect($row->fresh()->status)->toBe(KvMotionGenerationStatus::Generating);
    Http::assertSent(function ($request) use ($row, $parent) {
        return str_ends_with($request->url(), '/ai/kv-motion/generate')
            && $request['generation_id'] === $row->id
            && $request['source_image_url'] === $parent->image_url
            && $request['provider'] === 'google'
            && $request['duration'] === 8
            && $request['ratio'] === '9:16';
    });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `php artisan test tests/Unit/Jobs/Studio/GenerateKvMotionJobTest.php`
Expected: FAIL — class not found

- [ ] **Step 3: Implement the job** (mirror `ProcessKvResizeExportJob`)

```php
// app/Jobs/Studio/GenerateKvMotionJob.php
<?php

namespace App\Jobs\Studio;

use App\Models\KvMotionGeneration;
use App\Services\Studio\KvMotionService;
use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Queue\SerializesModels;
use Illuminate\Support\Facades\Http;

class GenerateKvMotionJob implements ShouldQueue
{
    use Dispatchable, InteractsWithQueue, Queueable, SerializesModels;

    public int $tries = 3;
    public int $timeout = 300;

    public function __construct(public string $motionId)
    {
        $this->onQueue('default');
    }

    public function handle(KvMotionService $service): void
    {
        $row = KvMotionGeneration::with('parentGeneration')->find($this->motionId);
        if (! $row) {
            return;
        }

        $service->markGenerating($row);

        $aiUrl = rtrim(config('services.ai.url'), '/');
        $response = Http::timeout(180)
            ->retry(2, 500)
            ->post("{$aiUrl}/ai/kv-motion/generate", [
                'generation_id' => $row->id,
                'source_image_url' => $row->parentGeneration->image_url,
                'model' => $row->model,
                'provider' => $row->provider,
                'preset' => $row->preset,
                'prompt' => $row->prompt,
                'duration' => $row->duration,
                'ratio' => $row->ratio,
            ]);

        if ($response->failed()) {
            $service->markFailed($row, "AI service error: {$response->status()}");
            return;
        }
        // ai-service responds 202; final status comes via the internal callback.
    }

    public function failed(\Throwable $e): void
    {
        $row = KvMotionGeneration::find($this->motionId);
        if ($row) {
            app(KvMotionService::class)->markFailed($row, "Job failed: {$e->getMessage()}");
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `php artisan test tests/Unit/Jobs/Studio/GenerateKvMotionJobTest.php`
Expected: PASS (1 test)

- [ ] **Step 5: Commit**

```bash
git add app/Jobs/Studio/GenerateKvMotionJob.php tests/Unit/Jobs/Studio/GenerateKvMotionJobTest.php
git commit -m "feat(api): GenerateKvMotionJob dispatches to ai-service"
```

---

## Task 5: Controller + resource + routes (store/index/show/destroy)

> **Guided regenerate is folded into `store`** — no separate route. The web client
> prefills the panel from a prior row and merges the base prompt + steering text
> into `prompt`, then POSTs `store` with `parent_motion_id` set to the source row
> (lineage). The controller validates that `parent_motion_id` belongs to the file
> and persists it; the merged prompt flows through unchanged. ai-service needs no
> change — `build_motion_prompt` already combines preset + prompt.

**Files:**
- Create: `app/Http/Resources/Studio/KvMotionGenerationResource.php`
- Create: `app/Http/Controllers/Api/Studio/KvMotionController.php`
- Modify: `routes/api.php`

- [ ] **Step 1: Create the resource**

```php
// app/Http/Resources/Studio/KvMotionGenerationResource.php
<?php

namespace App\Http\Resources\Studio;

use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

class KvMotionGenerationResource extends JsonResource
{
    public function toArray(Request $request): array
    {
        return [
            'id' => $this->id,
            'studio_file_id' => $this->studio_file_id,
            'parent_generation_id' => $this->parent_generation_id,
            'parent_motion_id' => $this->parent_motion_id,
            'model' => $this->model,
            'provider' => $this->provider,
            'preset' => $this->preset,
            'prompt' => $this->prompt,
            'duration' => $this->duration,
            'ratio' => $this->ratio,
            'status' => $this->status->value,
            'video_url' => $this->video_url,
            'error_message' => $this->error_message,
            'created_at' => $this->created_at?->toIso8601String(),
            'updated_at' => $this->updated_at?->toIso8601String(),
        ];
    }
}
```

- [ ] **Step 2: Create the controller** (mirror `KvResizeExportController` store/index/destroy, single-row)

```php
// app/Http/Controllers/Api/Studio/KvMotionController.php
<?php

namespace App\Http\Controllers\Api\Studio;

use App\Http\Controllers\Controller;
use App\Http\Requests\Studio\StoreKvMotionRequest;
use App\Http\Resources\Studio\KvMotionGenerationResource;
use App\Jobs\Studio\GenerateKvMotionJob;
use App\Models\KvGeneration;
use App\Models\KvMotionGeneration;
use App\Models\StudioFile;
use App\Services\Studio\KvMotionService;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

class KvMotionController extends Controller
{
    public function __construct(private readonly KvMotionService $service) {}

    public function index(Request $request, string $fileId): JsonResponse
    {
        $file = StudioFile::findOrFail($fileId);
        abort_unless($file->workspace_id === $request->user()->current_workspace_id, 403);

        $rows = KvMotionGeneration::where('studio_file_id', $file->id)
            ->orderByDesc('created_at')
            ->get();

        return response()->json([
            'data' => KvMotionGenerationResource::collection($rows)->resolve(),
        ]);
    }

    public function store(StoreKvMotionRequest $request, string $fileId): JsonResponse
    {
        $file = StudioFile::findOrFail($fileId);
        abort_unless($file->workspace_id === $request->user()->current_workspace_id, 403);

        $validated = $request->validated();

        $parent = KvGeneration::where('studio_file_id', $file->id)
            ->where('id', $validated['parent_generation_id'])
            ->firstOrFail();

        $promptRaw = trim((string) ($validated['prompt'] ?? ''));
        $prompt = $promptRaw === '' ? null : $promptRaw;

        // Guided regenerate: parent_motion_id, if present, must belong to this file.
        $parentMotionId = $validated['parent_motion_id'] ?? null;
        if ($parentMotionId !== null) {
            KvMotionGeneration::where('studio_file_id', $file->id)
                ->where('id', $parentMotionId)
                ->firstOrFail();
        }

        $row = $this->service->create(
            file: $file,
            parent: $parent,
            userId: $request->user()->id,
            model: $validated['model'],
            provider: $validated['provider'],
            preset: $validated['preset'] ?? null,
            prompt: $prompt,
            duration: (int) $validated['duration'],
            ratio: $validated['ratio'],
            parentMotionId: $parentMotionId,
        );

        GenerateKvMotionJob::dispatch($row->id);

        return response()->json(
            ['data' => (new KvMotionGenerationResource($row))->resolve()],
            Response::HTTP_ACCEPTED
        );
    }

    public function show(Request $request, string $fileId, string $motionId): JsonResponse
    {
        $file = StudioFile::findOrFail($fileId);
        abort_unless($file->workspace_id === $request->user()->current_workspace_id, 403);

        $row = KvMotionGeneration::where('studio_file_id', $file->id)
            ->where('id', $motionId)
            ->firstOrFail();

        return response()->json(['data' => (new KvMotionGenerationResource($row))->resolve()]);
    }

    public function destroy(Request $request, string $fileId, string $motionId): JsonResponse
    {
        $file = StudioFile::findOrFail($fileId);
        abort_unless($file->workspace_id === $request->user()->current_workspace_id, 403);

        $row = KvMotionGeneration::where('studio_file_id', $file->id)
            ->where('id', $motionId)
            ->firstOrFail();
        $row->delete();

        return response()->json(['ok' => true]);
    }
}
```

- [ ] **Step 3: Register the studio routes** (in `routes/api.php`, in the same authenticated Studio group as the resize-exports routes ~line 2066)

```php
// KV Motion (animate an approved KV generation into a short video)
Route::get('files/{file}/motions', [KvMotionController::class, 'index']);
Route::post('files/{file}/motions', [KvMotionController::class, 'store'])
    ->middleware('check.credits:1');
Route::get('files/{file}/motions/{motion}', [KvMotionController::class, 'show']);
Route::delete('files/{file}/motions/{motion}', [KvMotionController::class, 'destroy']);
```

Add the import at the top of `routes/api.php` next to the other Studio controllers:
```php
use App\Http\Controllers\Api\Studio\KvMotionController;
```

- [ ] **Step 4: Smoke-check routes are registered**

Run: `php artisan route:list --path=motions`
Expected: 4 routes listed (GET/POST/GET/DELETE) under `v1/studio/files/{file}/motions`.

- [ ] **Step 5: Commit**

```bash
git add app/Http/Resources/Studio/KvMotionGenerationResource.php app/Http/Controllers/Api/Studio/KvMotionController.php routes/api.php
git commit -m "feat(api): KvMotion controller, resource, studio routes"
```

---

## Task 6: Internal completion callback + credit metering

**Files:**
- Create: `app/Http/Requests/Internal/KvMotionGenerationCompleteRequest.php`
- Create: `app/Http/Controllers/Api/Internal/KvMotionGenerationInternalController.php`
- Modify: `routes/api.php` (internal prefix group ~line 2416)

- [ ] **Step 1: Create the callback request** (mirror `KvResizeExportCompleteRequest`)

```php
// app/Http/Requests/Internal/KvMotionGenerationCompleteRequest.php
<?php

namespace App\Http\Requests\Internal;

use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Http\Exceptions\HttpResponseException;

class KvMotionGenerationCompleteRequest extends FormRequest
{
    public function authorize(): bool
    {
        return $this->header('X-Internal-Token') === config('services.internal.kv_callback_token');
    }

    protected function failedAuthorization(): never
    {
        throw new HttpResponseException(
            response()->json(['message' => 'Invalid or missing internal token.'], 401)
        );
    }

    public function rules(): array
    {
        return [
            'generation_id' => ['required', 'string'],
            'status' => ['required', 'string', 'in:done,failed'],
            'video_url' => ['required_if:status,done', 'nullable', 'url'],
            'error_message' => ['required_if:status,failed', 'nullable', 'string'],
            'model' => ['nullable', 'string'],
            'ai_service_run_id' => ['nullable', 'string'],
            'token_usage' => ['nullable', 'array'],
        ];
    }
}
```

- [ ] **Step 2: Create the internal controller** (mirror `KvResizeExportInternalController`)

```php
// app/Http/Controllers/Api/Internal/KvMotionGenerationInternalController.php
<?php

namespace App\Http\Controllers\Api\Internal;

use App\Enums\KvMotionGenerationStatus;
use App\Http\Controllers\Controller;
use App\Http\Requests\Internal\KvMotionGenerationCompleteRequest;
use App\Models\KvMotionGeneration;
use App\Models\User;
use App\Services\Studio\KvCreditMeteringService;
use App\Services\Studio\KvMotionService;
use Illuminate\Http\JsonResponse;

class KvMotionGenerationInternalController extends Controller
{
    public function __construct(
        private readonly KvMotionService $service,
        private readonly KvCreditMeteringService $metering,
    ) {}

    public function completed(KvMotionGenerationCompleteRequest $request): JsonResponse
    {
        $validated = $request->validated();

        $row = KvMotionGeneration::with('file')->find($validated['generation_id']);
        if (! $row) {
            return response()->json(['ok' => true, 'ignored' => true]);
        }

        if (! in_array($row->status, [
            KvMotionGenerationStatus::Pending,
            KvMotionGenerationStatus::Generating,
        ], true)) {
            return response()->json(['ok' => true, 'ignored' => true]);
        }

        if ($validated['status'] === 'done') {
            $this->service->markDone($row, $validated['video_url']);
            $row->update([
                'ai_service_run_id' => $validated['ai_service_run_id'] ?? null,
                'model' => $validated['model'] ?? $row->model,
            ]);

            $aiRunId = $validated['ai_service_run_id'] ?? null;
            if ($aiRunId && ! empty($validated['token_usage'] ?? null)) {
                $user = User::find($row->created_by);
                if ($user && $row->file && $row->file->workspace) {
                    $this->metering->charge(
                        user: $user,
                        workspace: $row->file->workspace,
                        costType: 'kv_motion_generation',
                        toolName: 'KV Motion',
                        batchId: "kv_motion_{$row->id}_{$aiRunId}",
                        model: $validated['model'] ?? '',
                        tokenUsage: $validated['token_usage'],
                        brandId: $row->file->brand_id,
                    );
                }
            }
        } else {
            $this->service->markFailed($row, $validated['error_message']);
        }

        return response()->json(['ok' => true]);
    }
}
```

> NOTE on metering: `KvCreditMeteringService::charge()` currently maps token
> keys for image generations (`output_image_tokens`, etc.). Video token usage
> uses keys like `output_video_tokens`. For v1 the charge will still record a
> `CostHistory` row (idempotent by `batch_identifier`); confirm with the api
> owner (arhen) whether video token→credit pricing needs a dedicated branch in
> `PricingHelper`. If not ready, ship the callback WITHOUT the `charge()` block
> and add metering in a follow-up — the video result is unaffected.

- [ ] **Step 3: Register the internal route** (inside the `Route::prefix('internal')` group ~line 2416)

```php
// KV Motion generation completion callback (called by ai-service)
Route::post('kv-motion-generations/completed', [
    KvMotionGenerationInternalController::class,
    'completed',
]);
```

Add the import near the other internal controllers:
```php
use App\Http\Controllers\Api\Internal\KvMotionGenerationInternalController;
```

- [ ] **Step 4: Write the callback test** (Unit; fakes auth header + asserts state)

```php
// tests/Unit/Http/Controllers/Internal/KvMotionCallbackTest.php
<?php

use App\Enums\KvMotionGenerationStatus;
use App\Models\KvGeneration;
use App\Models\KvMotionGeneration;
use App\Models\StudioFile;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

uses(TestCase::class, RefreshDatabase::class);

beforeEach(function () {
    config(['services.internal.kv_callback_token' => 'secret']);
    $this->user = User::factory()->create();
    $this->file = StudioFile::factory()->create();
    $this->parent = KvGeneration::factory()->create([
        'studio_file_id' => $this->file->id,
        'version_number' => 1,
    ]);
    $this->row = KvMotionGeneration::factory()->create([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $this->parent->id,
        'created_by' => $this->user->id,
        'status' => 'generating',
    ]);
});

it('rejects a missing internal token', function () {
    $this->postJson('/api/v1/internal/kv-motion-generations/completed', [
        'generation_id' => $this->row->id,
        'status' => 'done',
        'video_url' => 'https://cdn/x.mp4',
    ])->assertStatus(401);
});

it('marks done and stores the video url', function () {
    $this->withHeader('X-Internal-Token', 'secret')
        ->postJson('/api/v1/internal/kv-motion-generations/completed', [
            'generation_id' => $this->row->id,
            'status' => 'done',
            'video_url' => 'https://cdn/x.mp4',
        ])->assertOk();

    expect($this->row->fresh()->status)->toBe(KvMotionGenerationStatus::Done);
    expect($this->row->fresh()->video_url)->toBe('https://cdn/x.mp4');
});

it('marks failed with an error message', function () {
    $this->withHeader('X-Internal-Token', 'secret')
        ->postJson('/api/v1/internal/kv-motion-generations/completed', [
            'generation_id' => $this->row->id,
            'status' => 'failed',
            'error_message' => 'provider down',
        ])->assertOk();

    expect($this->row->fresh()->status)->toBe(KvMotionGenerationStatus::Failed);
    expect($this->row->fresh()->error_message)->toBe('provider down');
});
```

> This test hits the HTTP route (it is a controller test) but uses no auth
> middleware beyond the internal-token header, so it does not trip the blocked
> Feature-suite auth/workspace setup. Keep it under `tests/Unit/...` and run it
> in isolation as below.

- [ ] **Step 5: Run the callback test**

Run: `php artisan test tests/Unit/Http/Controllers/Internal/KvMotionCallbackTest.php`
Expected: PASS (3 tests)

- [ ] **Step 6: Commit**

```bash
git add app/Http/Requests/Internal/KvMotionGenerationCompleteRequest.php app/Http/Controllers/Api/Internal/KvMotionGenerationInternalController.php routes/api.php tests/Unit/Http/Controllers/Internal/KvMotionCallbackTest.php
git commit -m "feat(api): kv motion internal completion callback + metering"
```

---

## Self-Review Checklist (run after all tasks)

- [ ] `php artisan test tests/Unit --filter=Motion` (or run the four new test files) all green.
- [ ] `php artisan route:list --path=motion` shows store/index/show/destroy + the internal completed route.
- [ ] `config('services.internal.kv_callback_token')` is the SAME key the ai-service sends as `X-Internal-Token` (it already exists for resize).
- [ ] `config('services.ai.url')` exists (used by resize job already).
- [ ] Confirmed with arhen whether `kv_motion_generation` needs a video pricing branch in `PricingHelper`, or whether metering ships in a follow-up.
- [ ] DB-test caution honored: `phpunit.xml` SQLite override active before running DB tests.
