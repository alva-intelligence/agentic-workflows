# KV Resize Region Edit — api Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Accept a region edit on one resize tile, dispatch it to ai-service, and cache per-tile object detection.

**Architecture:** A new `edit-region` action on `KvResizeExportController` reuses the resize export's existing status lifecycle and internal callback — only the dispatch target differs. The `bounding_boxes` validation rules move out of `StreamChatRequest` into a shared provider so the chat and resize surfaces cannot drift. Detection gains a tile-scoped twin of the generation routes, backed by a new `metadata` column.

**Tech Stack:** Laravel 13, PHP 8.5, PostgreSQL, Pest.

**Spec:** `docs/superpowers/specs/2026-08-20-kv-resize-region-edit-design.md`

## Global Constraints

- **Validation parity is the point.** The rules for `bounding_boxes.*` must come from one shared provider consumed by both `StreamChatRequest` and the new request class. The 120-char `label` cap is load-bearing — ai-service interpolates the label into the render model's region header.
- **Bounds come from `KvObjectDetectService`,** never re-typed: `MAX_POLYGON_POINTS` (60), `MAX_TEXT_RINGS` (120).
- **Guard on the tile, not the parent.** Region edits operate on the tile's own `image_url`. A row that is not `done`, or has a null `image_url` (layer-composed KVs deliberately keep it null), has nothing to edit.
- **Workspace scoping** follows the existing controller shape exactly: `abort_unless($file->workspace_id === $request->user()->current_workspace_id, 403)` then `abort_unless($export->studio_file_id === $file->id, 404)`.
- **Feature tests need a scratch Postgres.** SQLite cannot run these migrations (`DROP SEQUENCE`). `frnd_test` no longer exists — create a scratch database. A stale `bootstrap/cache/config.php` will hijack the connection; clear it first. Pass test **paths**, not `--filter`.
- **Run migrations with `TELESCOPE_ENABLED=false`** — Telescope OOMs on data migrations and the failure masquerades as a hung database.

## File Structure

| File | Responsibility |
|---|---|
| `app/Validation/KvBoundingBoxRules.php` (create) | One static provider returning the `bounding_boxes.*` rule array |
| `app/Http/Requests/StreamChatRequest.php` (modify) | Consume the provider instead of inlining the rules |
| `app/Http/Requests/Studio/KvResizeRegionEditRequest.php` (create) | The new endpoint's form request |
| `database/migrations/*_add_metadata_to_kv_resize_exports_table.php` (create) | Nullable `json` column for the detection cache |
| `app/Models/KvResizeExport.php` (modify) | `metadata` in `$fillable` + `array` cast |
| `app/Services/Studio/KvResizeExportService.php` (modify) | `editRegion()` |
| `app/Jobs/Studio/ProcessKvResizeRegionEditJob.php` (create) | Dispatch to `/ai/kv-resize-region-edit/edit` |
| `app/Http/Controllers/Api/Studio/KvResizeExportController.php` (modify) | `editRegion()` |
| `app/Http/Controllers/Api/Studio/KvResizeObjectDetectController.php` (create) | Tile-scoped `detect` / `detections` |
| `routes/api.php` (modify) | Three routes |

---

### Task 1: Extract the bounding-box validation rules

**Files:**
- Create: `app/Validation/KvBoundingBoxRules.php`
- Modify: `app/Http/Requests/StreamChatRequest.php:672-702`
- Test: `tests/Unit/Validation/KvBoundingBoxRulesTest.php`

**Interfaces:**
- Consumes: `KvObjectDetectService::MAX_POLYGON_POINTS`, `::MAX_TEXT_RINGS`.
- Produces: `KvBoundingBoxRules::forKey(string $key): array` — rules keyed by `"{$key}"`, `"{$key}.*.id"`, and so on, so both `bounding_boxes` and any future key reuse them.

- [ ] **Step 1: Write the failing test**

```php
<?php

use App\Services\KvObjectDetectService;
use App\Validation\KvBoundingBoxRules;

it('keys every rule under the given field', function () {
    $rules = KvBoundingBoxRules::forKey('bounding_boxes');

    expect($rules)->toHaveKeys([
        'bounding_boxes',
        'bounding_boxes.*.id',
        'bounding_boxes.*.x',
        'bounding_boxes.*.width',
        'bounding_boxes.*.prompt',
        'bounding_boxes.*.polygon',
        'bounding_boxes.*.rings',
        'bounding_boxes.*.label',
    ]);
});

it('caps the label at 120 characters', function () {
    $rules = KvBoundingBoxRules::forKey('bounding_boxes');

    expect($rules['bounding_boxes.*.label'])->toContain('max:120');
});

it('sources its bounds from KvObjectDetectService', function () {
    $rules = KvBoundingBoxRules::forKey('bounding_boxes');

    expect($rules['bounding_boxes.*.polygon'])
        ->toContain('max:'.KvObjectDetectService::MAX_POLYGON_POINTS)
        ->and($rules['bounding_boxes.*.rings'])
        ->toContain('max:'.KvObjectDetectService::MAX_TEXT_RINGS);
});
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
cd api && ./vendor/bin/pest tests/Unit/Validation/KvBoundingBoxRulesTest.php
```

Expected: `Class "App\Validation\KvBoundingBoxRules" not found`.

- [ ] **Step 3: Implement**

Create `app/Validation/KvBoundingBoxRules.php`. Move the rules from `StreamChatRequest.php:672-702` **verbatim**, including their comments — they document why `polygon` and `rings` are optional and why the label cap exists — swapping the literal key prefix for `{$key}`:

```php
<?php

namespace App\Validation;

use App\Services\KvObjectDetectService;

/**
 * One source of truth for `bounding_boxes.*` validation.
 *
 * Consumed by StreamChatRequest (Craft's region edit, via the chat stream)
 * and KvResizeRegionEditRequest (a region edit on one resize tile). The two
 * surfaces MUST validate identically: ai-service builds the same mask from
 * either payload, and the 120-char label cap is what keeps the region header
 * it composes within bounds.
 */
class KvBoundingBoxRules
{
    public static function forKey(string $key): array
    {
        return [
            $key => ['sometimes', 'array'],
            "{$key}.*.id" => ["required_with:{$key}", 'string', 'max:64'],
            "{$key}.*.x" => ["required_with:{$key}", 'numeric', 'between:0,1'],
            "{$key}.*.y" => ["required_with:{$key}", 'numeric', 'between:0,1'],
            "{$key}.*.width" => ["required_with:{$key}", 'numeric', 'between:0,1'],
            "{$key}.*.height" => ["required_with:{$key}", 'numeric', 'between:0,1'],
            "{$key}.*.prompt" => ['sometimes', 'nullable', 'string', 'max:2000'],
            "{$key}.*.polygon" => ['sometimes', 'nullable', 'array', 'max:'.KvObjectDetectService::MAX_POLYGON_POINTS],
            "{$key}.*.polygon.*" => ['array', 'size:2'],
            "{$key}.*.polygon.*.*" => ['numeric', 'between:0,1'],
            "{$key}.*.rings" => ['sometimes', 'nullable', 'array', 'max:'.KvObjectDetectService::MAX_TEXT_RINGS],
            "{$key}.*.rings.*" => ['array', 'max:'.KvObjectDetectService::MAX_POLYGON_POINTS],
            "{$key}.*.rings.*.*" => ['array', 'size:2'],
            "{$key}.*.rings.*.*.*" => ['numeric', 'between:0,1'],
            "{$key}.*.label" => ['sometimes', 'nullable', 'string', 'max:120'],
        ];
    }
}
```

In `StreamChatRequest::rules()`, delete those lines and merge the provider in:

```php
return array_merge([
    // ... every other rule, unchanged ...
], KvBoundingBoxRules::forKey('bounding_boxes'));
```

Leave the `withValidator` "at least one bounding box is required for edit mode" check where it is — that is edit-mode-specific, not a shape rule.

- [ ] **Step 4: Run the unit test and the chat regression tests**

```bash
cd api && ./vendor/bin/pest tests/Unit/Validation/KvBoundingBoxRulesTest.php
cd api && ./vendor/bin/pest tests/Unit --group=chat 2>/dev/null || ./vendor/bin/pest tests/Unit
```

Expected: new tests pass; no new failures elsewhere.

- [ ] **Step 5: Commit**

```bash
git add app/Validation/KvBoundingBoxRules.php app/Http/Requests/StreamChatRequest.php tests/Unit/Validation/KvBoundingBoxRulesTest.php
git commit -m "refactor(api): share the bounding-box validation rules"
```

---

### Task 2: `metadata` column on `kv_resize_exports`

**Files:**
- Create: `database/migrations/2026_08_20_000000_add_metadata_to_kv_resize_exports_table.php`
- Modify: `app/Models/KvResizeExport.php:19-42`
- Test: `tests/Unit/Models/KvResizeExportMetadataTest.php`

**Interfaces:**
- Produces: `KvResizeExport->metadata` as a nullable array, holding `detected_objects` — mirroring `kv_generations.metadata.detected_objects`.

- [ ] **Step 1: Write the failing test**

```php
<?php

use App\Models\KvResizeExport;

it('casts metadata to an array', function () {
    $row = new KvResizeExport(['metadata' => ['detected_objects' => [['id' => 'det-1']]]]);

    expect($row->metadata)->toBeArray()
        ->and($row->metadata['detected_objects'][0]['id'])->toBe('det-1');
});

it('treats metadata as fillable', function () {
    expect((new KvResizeExport)->getFillable())->toContain('metadata');
});
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
cd api && ./vendor/bin/pest tests/Unit/Models/KvResizeExportMetadataTest.php
```

Expected: FAIL — `metadata` is neither fillable nor cast, so it stays null / stays a string.

- [ ] **Step 3: Implement**

Migration:

```php
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('kv_resize_exports', function (Blueprint $table) {
            // Per-tile detection cache: metadata.detected_objects, mirroring
            // kv_generations.metadata.detected_objects. A resize tile has no
            // generation of its own, so it needs its own home for this.
            $table->json('metadata')->nullable()->after('overlays');
        });
    }

    public function down(): void
    {
        Schema::table('kv_resize_exports', function (Blueprint $table) {
            $table->dropColumn('metadata');
        });
    }
};
```

In the model, add `'metadata'` to `$fillable` and `'metadata' => 'array'` to `$casts`.

- [ ] **Step 4: Run the migration and the test**

```bash
cd api && TELESCOPE_ENABLED=false php artisan migrate
cd api && ./vendor/bin/pest tests/Unit/Models/KvResizeExportMetadataTest.php
```

Expected: migration applies; both tests pass.

- [ ] **Step 5: Commit**

```bash
git add database/migrations app/Models/KvResizeExport.php tests/Unit/Models/KvResizeExportMetadataTest.php
git commit -m "feat(api): metadata column on kv_resize_exports for the tile detection cache"
```

---

### Task 3: The region-edit request class

**Files:**
- Create: `app/Http/Requests/Studio/KvResizeRegionEditRequest.php`
- Test: `tests/Unit/Requests/KvResizeRegionEditRequestTest.php`

**Interfaces:**
- Consumes: `KvBoundingBoxRules::forKey` (Task 1).
- Produces: `KvResizeRegionEditRequest` — authorises to `true` (the controller owns workspace scoping, matching every other method on it) and requires at least one box.

- [ ] **Step 1: Write the failing test**

```php
<?php

use App\Http\Requests\Studio\KvResizeRegionEditRequest;
use Illuminate\Support\Facades\Validator;

function validateRegionEdit(array $payload): \Illuminate\Contracts\Validation\Validator
{
    $request = new KvResizeRegionEditRequest;
    $v = Validator::make($payload, $request->rules());
    $request->withValidator($v);

    return $v;
}

it('accepts a single hand-drawn rectangle', function () {
    $v = validateRegionEdit([
        'bounding_boxes' => [
            ['id' => 'b1', 'x' => 0.1, 'y' => 0.1, 'width' => 0.2, 'height' => 0.2, 'prompt' => 'fix this'],
        ],
    ]);

    expect($v->fails())->toBeFalse();
});

it('rejects an empty box list', function () {
    expect(validateRegionEdit(['bounding_boxes' => []])->fails())->toBeTrue();
});

it('rejects coordinates outside the unit square', function () {
    $v = validateRegionEdit([
        'bounding_boxes' => [['id' => 'b1', 'x' => 1.4, 'y' => 0.1, 'width' => 0.2, 'height' => 0.2]],
    ]);

    expect($v->fails())->toBeTrue();
});

it('rejects a label past 120 characters', function () {
    $v = validateRegionEdit([
        'bounding_boxes' => [[
            'id' => 'b1', 'x' => 0.1, 'y' => 0.1, 'width' => 0.2, 'height' => 0.2,
            'label' => str_repeat('a', 121),
        ]],
    ]);

    expect($v->fails())->toBeTrue();
});
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
cd api && ./vendor/bin/pest tests/Unit/Requests/KvResizeRegionEditRequestTest.php
```

Expected: class not found.

- [ ] **Step 3: Implement**

```php
<?php

namespace App\Http\Requests\Studio;

use App\Validation\KvBoundingBoxRules;
use Illuminate\Contracts\Validation\Validator;
use Illuminate\Foundation\Http\FormRequest;

class KvResizeRegionEditRequest extends FormRequest
{
    public function authorize(): bool
    {
        // Workspace + ownership checks live in the controller, as they do for
        // every other action on KvResizeExportController.
        return true;
    }

    public function rules(): array
    {
        return KvBoundingBoxRules::forKey('bounding_boxes');
    }

    public function withValidator(Validator $validator): void
    {
        $validator->after(function (Validator $validator) {
            $boxes = $this->input('bounding_boxes', []);
            if (! is_array($boxes) || count($boxes) === 0) {
                $validator->errors()->add(
                    'bounding_boxes',
                    'At least one bounding box is required for a region edit.'
                );
            }
        });
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
cd api && ./vendor/bin/pest tests/Unit/Requests/KvResizeRegionEditRequestTest.php
```

Expected: 4 passed.

- [ ] **Step 5: Commit**

```bash
git add app/Http/Requests/Studio/KvResizeRegionEditRequest.php tests/Unit/Requests/KvResizeRegionEditRequestTest.php
git commit -m "feat(api): region-edit request validation for resize tiles"
```

---

### Task 4: `editRegion()` service method + job

**Files:**
- Modify: `app/Services/Studio/KvResizeExportService.php` (next to `regenerate`, line 89)
- Create: `app/Jobs/Studio/ProcessKvResizeRegionEditJob.php`
- Test: `tests/Feature/Studio/KvResizeRegionEditTest.php`

**Interfaces:**
- Consumes: `KvResizeExport`, `KvResizeExportStatus`.
- Produces:
  - `KvResizeExportService::editRegion(KvResizeExport $row, array $boundingBoxes): KvResizeExport` — sets status `Pending`, clears `error_message`, **keeps `image_url`** (it is the edit's input), dispatches the job.
  - `ProcessKvResizeRegionEditJob(string $exportId, array $boundingBoxes)`.

`image_url` is deliberately *not* cleared, unlike `regenerate()`. The job reads the tile's current pixels as the thing being edited; nulling it first would leave the job with nothing to send.

- [ ] **Step 1: Write the failing test**

```php
<?php

use App\Jobs\Studio\ProcessKvResizeRegionEditJob;
use App\Models\KvResizeExport;
use App\Services\Studio\KvResizeExportService;
use Illuminate\Support\Facades\Queue;

it('keeps the tile image and dispatches the region-edit job', function () {
    Queue::fake();

    $row = KvResizeExport::factory()->create([
        'status' => 'done',
        'image_url' => 'https://cdn.test/tile.png',
        'error_message' => 'stale failure',
    ]);

    $boxes = [['id' => 'b1', 'x' => 0.1, 'y' => 0.1, 'width' => 0.2, 'height' => 0.2]];
    $out = app(KvResizeExportService::class)->editRegion($row, $boxes);

    expect($out->image_url)->toBe('https://cdn.test/tile.png')
        ->and($out->error_message)->toBeNull()
        ->and($out->status->value)->toBe('pending');

    Queue::assertPushed(ProcessKvResizeRegionEditJob::class);
});
```

- [ ] **Step 2: Prepare the test database, then run it**

```bash
cd api && rm -f bootstrap/cache/config.php
cd api && createdb frnd_region_edit_scratch
cd api && DB_DATABASE=frnd_region_edit_scratch TELESCOPE_ENABLED=false php artisan migrate --force
cd api && DB_DATABASE=frnd_region_edit_scratch ./vendor/bin/pest tests/Feature/Studio/KvResizeRegionEditTest.php
```

Expected: FAIL — `Call to undefined method ...::editRegion()`.

- [ ] **Step 3: Implement the service method**

```php
/**
 * Repaint one region of THIS tile. Unlike regenerate(), `image_url` is left
 * in place: the tile's current pixels are the edit's input, not stale output
 * to be discarded.
 */
public function editRegion(KvResizeExport $row, array $boundingBoxes): KvResizeExport
{
    $row->update([
        'status' => KvResizeExportStatus::Pending,
        'error_message' => null,
    ]);

    ProcessKvResizeRegionEditJob::dispatch($row->id, $boundingBoxes);

    return $row->refresh();
}
```

- [ ] **Step 4: Implement the job**

Model it on `ProcessKvResizeExportJob`, with the source swapped from the parent generation to the tile:

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

class ProcessKvResizeRegionEditJob implements ShouldQueue
{
    use Dispatchable, InteractsWithQueue, Queueable, SerializesModels;

    public int $tries = 3;

    public int $timeout = 300;

    public function __construct(public string $exportId, public array $boundingBoxes)
    {
        $this->onQueue('default');
    }

    public function handle(KvResizeExportService $service): void
    {
        $row = KvResizeExport::find($this->exportId);
        if (! $row) {
            return;
        }

        $service->markGenerating($row);

        $aiUrl = rtrim(config('services.ai.url'), '/');
        $response = Http::timeout(120)
            ->retry(2, 500)
            ->post("{$aiUrl}/ai/kv-resize-region-edit/edit", [
                'export_id' => $row->id,
                // The TILE's own pixels — not the parent generation's. This is
                // what makes the edit local to this ratio.
                'source_image_url' => $row->image_url,
                'target_width' => $row->width,
                'target_height' => $row->height,
                'bounding_boxes' => $this->boundingBoxes,
            ]);

        if ($response->failed()) {
            $service->markFailed($row, "AI service error: {$response->status()}");

            return;
        }
        // 202 — final status arrives on the existing kv-resize-exports callback.
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

- [ ] **Step 5: Run the test**

```bash
cd api && DB_DATABASE=frnd_region_edit_scratch ./vendor/bin/pest tests/Feature/Studio/KvResizeRegionEditTest.php
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/Services/Studio/KvResizeExportService.php app/Jobs/Studio/ProcessKvResizeRegionEditJob.php tests/Feature/Studio/KvResizeRegionEditTest.php
git commit -m "feat(api): dispatch region edits against the tile's own image"
```

---

### Task 5: The `edit-region` endpoint

**Files:**
- Modify: `app/Http/Controllers/Api/Studio/KvResizeExportController.php` (after `regenerate`, line 217)
- Modify: `routes/api.php` (after the regenerate route, line 3818-3821)
- Test: `tests/Feature/Studio/KvResizeRegionEditTest.php` (extend)

**Interfaces:**
- Consumes: `KvResizeRegionEditRequest` (Task 3), `KvResizeExportService::editRegion` (Task 4).
- Produces: `POST v1/studio/files/{file}/resize-exports/{export}/edit-region` → `202` with `{"data": KvResizeExportResource}`.

- [ ] **Step 1: Write the failing test**

Append:

```php
it('refuses a region edit on a tile that has no image', function () {
    $user = actingAsWorkspaceUser();
    $file = studioFileForUser($user);
    $export = KvResizeExport::factory()->create([
        'studio_file_id' => $file->id,
        'status' => 'done',
        'image_url' => null,   // layer-composed tiles keep this null
    ]);

    $this->postJson("/api/v1/studio/files/{$file->id}/resize-exports/{$export->id}/edit-region", [
        'bounding_boxes' => [['id' => 'b1', 'x' => 0.1, 'y' => 0.1, 'width' => 0.2, 'height' => 0.2]],
    ])->assertStatus(422);
});

it('refuses a region edit on a tile that is still generating', function () {
    $user = actingAsWorkspaceUser();
    $file = studioFileForUser($user);
    $export = KvResizeExport::factory()->create([
        'studio_file_id' => $file->id,
        'status' => 'generating',
        'image_url' => 'https://cdn.test/tile.png',
    ]);

    $this->postJson("/api/v1/studio/files/{$file->id}/resize-exports/{$export->id}/edit-region", [
        'bounding_boxes' => [['id' => 'b1', 'x' => 0.1, 'y' => 0.1, 'width' => 0.2, 'height' => 0.2]],
    ])->assertStatus(422);
});

it('accepts a region edit on a done tile', function () {
    Queue::fake();
    $user = actingAsWorkspaceUser();
    $file = studioFileForUser($user);
    $export = KvResizeExport::factory()->create([
        'studio_file_id' => $file->id,
        'status' => 'done',
        'image_url' => 'https://cdn.test/tile.png',
    ]);

    $this->postJson("/api/v1/studio/files/{$file->id}/resize-exports/{$export->id}/edit-region", [
        'bounding_boxes' => [['id' => 'b1', 'x' => 0.1, 'y' => 0.1, 'width' => 0.2, 'height' => 0.2]],
    ])->assertStatus(202);

    Queue::assertPushed(ProcessKvResizeRegionEditJob::class);
});

it('refuses a tile belonging to another workspace', function () {
    $user = actingAsWorkspaceUser();
    $otherFile = studioFileForUser(otherWorkspaceUser());
    $export = KvResizeExport::factory()->create([
        'studio_file_id' => $otherFile->id,
        'status' => 'done',
        'image_url' => 'https://cdn.test/tile.png',
    ]);

    $this->postJson("/api/v1/studio/files/{$otherFile->id}/resize-exports/{$export->id}/edit-region", [
        'bounding_boxes' => [['id' => 'b1', 'x' => 0.1, 'y' => 0.1, 'width' => 0.2, 'height' => 0.2]],
    ])->assertStatus(403);
});
```

Reuse whatever workspace/file helpers `tests/Feature/Studio/KvResizeExportControllerTest.php` already defines rather than inventing new ones; if they are private to that file, lift them into `tests/Pest.php`.

- [ ] **Step 2: Run it to confirm it fails**

```bash
cd api && DB_DATABASE=frnd_region_edit_scratch ./vendor/bin/pest tests/Feature/Studio/KvResizeRegionEditTest.php
```

Expected: 404 on every request — the route does not exist.

- [ ] **Step 3: Implement the controller action**

```php
public function editRegion(
    KvResizeRegionEditRequest $request,
    string $fileId,
    string $exportId
): JsonResponse {
    $file = StudioFile::findOrFail($fileId);
    abort_unless($file->workspace_id === $request->user()->current_workspace_id, 403);

    $export = KvResizeExport::findOrFail($exportId);
    abort_unless($export->studio_file_id === $file->id, 404);

    // A region edit repaints part of an existing tile, so there must BE one.
    // Layer-composed KVs finish with a null image_url on purpose.
    if ($export->status !== KvResizeExportStatus::Done || ! $export->image_url) {
        return response()->json([
            'message' => 'This tile has no rendered image to edit.',
        ], Response::HTTP_UNPROCESSABLE_ENTITY);
    }

    $row = $this->service->editRegion($export, $request->validated()['bounding_boxes']);

    return response()->json([
        'data' => (new KvResizeExportResource($row))->resolve(),
    ], Response::HTTP_ACCEPTED);
}
```

- [ ] **Step 4: Register the route**

In `routes/api.php`, directly after the regenerate route:

```php
Route::post(
    'files/{file}/resize-exports/{export}/edit-region',
    [KvResizeExportController::class, 'editRegion'],
)->middleware('check.credits:1');
```

- [ ] **Step 5: Run the tests**

```bash
cd api && DB_DATABASE=frnd_region_edit_scratch ./vendor/bin/pest tests/Feature/Studio/KvResizeRegionEditTest.php
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add app/Http/Controllers/Api/Studio/KvResizeExportController.php routes/api.php tests/Feature/Studio/KvResizeRegionEditTest.php
git commit -m "feat(api): edit-region endpoint for resize tiles"
```

---

### Task 6: Tile-scoped object detection

**Files:**
- Create: `app/Http/Controllers/Api/Studio/KvResizeObjectDetectController.php`
- Modify: `routes/api.php` (beside the generation detect routes, line 3777-3788)
- Test: `tests/Feature/Studio/KvResizeObjectDetectTest.php`

**Interfaces:**
- Consumes: `KvObjectDetectService` (unchanged — it takes an image URL and a region, not a generation), `KvResizeExport->metadata` (Task 2).
- Produces:
  - `POST v1/studio/kv-generator/files/{id}/resize-exports/{export}/detect` → detected objects for the tile.
  - `PATCH v1/studio/kv-generator/files/{id}/resize-exports/{export}/detections` → persist to `metadata.detected_objects`.

Mirror `KvObjectDetectController` exactly: same `region` / `hint` validation (`region.*` numeric `between:0,1`, `width`/`height` `gt:0,lte:1`, `hint` string max 120), same cache-first ordering — **a cache hit must not touch the rate limiter**, which is why the cache read comes before the limiter in the original.

- [ ] **Step 1: Write the failing test**

```php
<?php

use App\Models\KvResizeExport;

it('serves detected objects from the tile cache without calling the model', function () {
    $user = actingAsWorkspaceUser();
    $file = studioFileForUser($user);
    $export = KvResizeExport::factory()->create([
        'studio_file_id' => $file->id,
        'status' => 'done',
        'image_url' => 'https://cdn.test/tile.png',
        'metadata' => ['detected_objects' => [['id' => 'det-1', 'label' => 'Red Card']]],
    ]);

    $this->postJson("/api/v1/studio/kv-generator/files/{$file->id}/resize-exports/{$export->id}/detect", [])
        ->assertOk()
        ->assertJsonPath('data.0.label', 'Red Card');
});

it('persists detections onto the tile metadata', function () {
    $user = actingAsWorkspaceUser();
    $file = studioFileForUser($user);
    $export = KvResizeExport::factory()->create([
        'studio_file_id' => $file->id,
        'status' => 'done',
        'image_url' => 'https://cdn.test/tile.png',
    ]);

    $this->patchJson("/api/v1/studio/kv-generator/files/{$file->id}/resize-exports/{$export->id}/detections", [
        'detected_objects' => [['id' => 'det-9', 'label' => 'Logo']],
    ])->assertOk();

    expect($export->refresh()->metadata['detected_objects'][0]['id'])->toBe('det-9');
});
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
cd api && DB_DATABASE=frnd_region_edit_scratch ./vendor/bin/pest tests/Feature/Studio/KvResizeObjectDetectTest.php
```

Expected: 404 on both routes.

- [ ] **Step 3: Implement**

Create the controller as a tile-scoped twin of `KvObjectDetectController`. Resolve the file and export with the same two `abort_unless` guards used everywhere else on the resize controller, read/write the cache at `metadata.detected_objects`, and pass `$export->image_url` where the generation controller passes the generation's image URL.

- [ ] **Step 4: Register the routes**

```php
Route::post(
    'kv-generator/files/{id}/resize-exports/{export}/detect',
    [KvResizeObjectDetectController::class, 'detect'],
)->middleware('check.credits');
Route::patch(
    'kv-generator/files/{id}/resize-exports/{export}/detections',
    [KvResizeObjectDetectController::class, 'detections'],
);
```

- [ ] **Step 5: Run the tests**

```bash
cd api && DB_DATABASE=frnd_region_edit_scratch ./vendor/bin/pest tests/Feature/Studio/KvResizeObjectDetectTest.php
```

Expected: both pass.

- [ ] **Step 6: Run the whole resize Feature area**

```bash
cd api && DB_DATABASE=frnd_region_edit_scratch ./vendor/bin/pest tests/Feature/Studio
```

Expected: no new failures.

- [ ] **Step 7: Commit**

```bash
git add app/Http/Controllers/Api/Studio/KvResizeObjectDetectController.php routes/api.php tests/Feature/Studio/KvResizeObjectDetectTest.php
git commit -m "feat(api): tile-scoped object detection for resize region edits"
```

---

## Done when

- `POST .../resize-exports/{export}/edit-region` returns 202 for a done tile with an image, 422 for one without, 403 across workspaces.
- The job posts the **tile's** `image_url` to `/ai/kv-resize-region-edit/edit`.
- `bounding_boxes` validates identically on the chat and resize surfaces, from one provider.
- Detection reads and writes `kv_resize_exports.metadata.detected_objects`, and a cache hit does not consume rate limit.
