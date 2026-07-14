# Standalone Resizer — API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the API surface for a standalone Resizer tool — create a `tool=resizer` studio file with no chat thread, expose its source generation, and bundle completed resize exports into a downloadable ZIP — while reusing the existing `kv_resize` export pipeline unchanged.

**Architecture:** Approach A from the design spec (`docs/superpowers/specs/2026-07-14-studio-standalone-resizer-design.md`). The uploaded image is minted as a normal `kv_generation` via the **existing** `import-from-upload` endpoint (already tool-agnostic), and `kv_resize_exports` hang off it exactly as for KV resize. The only new API is: a slim resizer file-create service + controller, a lean resizer file `show`, and a download-ZIP endpoint on the existing resize controller. No schema changes, no ai-service changes.

**Tech Stack:** Laravel 13 (PHP 8.5), Pest 4 feature/unit tests, SQLite `:memory:` for tests, native `ZipArchive` for the zip, Laravel `Http` client for fetching export bytes.

## Global Constraints

- **DB isolation (MANDATORY before any Feature test):** confirm `api/phpunit.xml` has `<env name="DB_CONNECTION" value="sqlite"/>` and `<env name="DB_DATABASE" value=":memory:"/>`, and `api/tests/Pest.php` applies `RefreshDatabase` to `Feature`. If either is missing/commented, STOP and tell the user (this has wiped the dev DB before — see memory `lesson_test_db_isolation.md`).
- **Branch:** `feature/daffa/vc-studio-standalone-resizer` off latest `develop`. Never commit on `develop`.
- **Resizer routes live inside the existing `Route::middleware('feature.flag:show-kv-generator')->group(...)` block** (opens at `routes/api.php:2868`), same as the resize-export routes they depend on. Do NOT create a new flag in v1.
- **File name base for resizer files:** `"Untitled Resize Job"` (KV uses `"Untitled KV"`).
- **`resizer` Tool row** already exists via `database/seeders/StudioDevelopmentSeeder.php:91` (`slug=resizer`, `status=live`). Tests must seed it explicitly (see the Tool factory/create step in each feature test) since `RefreshDatabase` starts empty.
- Run `vendor/bin/pint --dirty --format agent` after editing PHP, before each commit.

---

## File Structure

| Path | Action | Responsibility |
|---|---|---|
| `app/Services/Studio/ResizerFileService.php` | Create | Mint a `tool=resizer` studio file, no thread, `"Untitled Resize Job N"` naming |
| `app/Http/Requests/Studio/CreateResizerFileRequest.php` | Create | Validate `brand_id` (required), `project_id` (nullable) |
| `app/Http/Controllers/Api/Studio/ResizerFileController.php` | Create | `store()` (create file) + `show()` (file + generations) |
| `app/Http/Controllers/Api/Studio/KvResizeExportController.php` | Modify | Add `downloadZip()` method |
| `routes/api.php` | Modify | Register `POST/GET resizer/files…` + `GET …/resize-exports/download-zip` inside the gated group |
| `tests/Unit/Services/Studio/ResizerFileServiceTest.php` | Create | Unit test for the service |
| `tests/Feature/Studio/ResizerFileControllerTest.php` | Create | Feature test for store + show |
| `tests/Feature/Studio/KvResizeExportZipTest.php` | Create | Feature test for download-zip |

Reused unchanged: `KvGenerationService::persistImportFromUpload`, the entire `files/{file}/resize-exports` route block + `KvResizeExportService` + `ProcessKvResizeExportJob`, `StudioFileResource`, `KvGenerationResource`, `KvResizeExportResource`, `ImportKvGenerationFromUploadRequest` + its route.

---

## Task 1: `ResizerFileService` — create a resizer studio file

**Files:**
- Create: `app/Services/Studio/ResizerFileService.php`
- Test: `tests/Unit/Services/Studio/ResizerFileServiceTest.php`

**Interfaces:**
- Consumes: `App\Models\{StudioFile, Tool, User}`.
- Produces: `ResizerFileService::createFile(User $user, string $workspaceId, string $brandId, ?string $projectId = null): StudioFile` — returns a persisted `StudioFile` with `tool.slug === 'resizer'`, `thread_id === null`, `metadata['current_mode'] === 'resize'`, name `"Untitled Resize Job"` (then `"Untitled Resize Job 2"`, …).

- [ ] **Step 1: Write the failing unit test**

Create `tests/Unit/Services/Studio/ResizerFileServiceTest.php`:

```php
<?php

use App\Models\Brand;
use App\Models\Tool;
use App\Models\User;
use App\Models\Workspace;
use App\Services\Studio\ResizerFileService;

it('creates a resizer file with no thread and a resize default name', function () {
    $workspace = Workspace::factory()->create();
    $user = User::factory()->create(['current_workspace_id' => $workspace->id]);
    $brand = Brand::factory()->create(['workspace_id' => $workspace->id]);
    Tool::factory()->create(['slug' => 'resizer', 'name' => 'Resizer']);

    $file = app(ResizerFileService::class)->createFile(
        user: $user,
        workspaceId: $workspace->id,
        brandId: $brand->id,
    );

    expect($file->tool->slug)->toBe('resizer');
    expect($file->thread_id)->toBeNull();
    expect($file->name)->toBe('Untitled Resize Job');
    expect($file->metadata['current_mode'])->toBe('resize');
    expect($file->status->value)->toBe('draft');
});

it('increments the default name for subsequent files in the same scope', function () {
    $workspace = Workspace::factory()->create();
    $user = User::factory()->create(['current_workspace_id' => $workspace->id]);
    $brand = Brand::factory()->create(['workspace_id' => $workspace->id]);
    Tool::factory()->create(['slug' => 'resizer', 'name' => 'Resizer']);

    $svc = app(ResizerFileService::class);
    $svc->createFile(user: $user, workspaceId: $workspace->id, brandId: $brand->id);
    $second = $svc->createFile(user: $user, workspaceId: $workspace->id, brandId: $brand->id);

    expect($second->name)->toBe('Untitled Resize Job 2');
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd api && php artisan test --compact --filter=ResizerFileServiceTest`
Expected: FAIL — `Class "App\Services\Studio\ResizerFileService" not found`.

- [ ] **Step 3: Write the service**

Create `app/Services/Studio/ResizerFileService.php`:

```php
<?php

namespace App\Services\Studio;

use App\Models\StudioFile;
use App\Models\Tool;
use App\Models\User;

class ResizerFileService
{
    /**
     * Create a standalone Resizer studio file. Unlike KvStudioFileService,
     * this mints NO chat thread (resize-only has no chat) and tags the file
     * with the `resizer` tool so it groups under the Resizer tile and routes
     * to `/studio/resizer/{id}`.
     */
    public function createFile(
        User $user,
        string $workspaceId,
        string $brandId,
        ?string $projectId = null,
    ): StudioFile {
        $tool = Tool::where('slug', 'resizer')->firstOrFail();

        return StudioFile::create([
            'workspace_id' => $workspaceId,
            'brand_id' => $brandId,
            'project_id' => $projectId,
            'thread_id' => null,
            'tool_id' => $tool->id,
            'created_by' => $user->id,
            'last_edited_by' => $user->id,
            'name' => $this->nextDefaultName($workspaceId, $brandId, $projectId),
            'status' => 'draft',
            'last_edited_at' => now(),
            'metadata' => ['current_mode' => 'resize'],
        ]);
    }

    /**
     * Next "Untitled Resize Job N" within the (workspace, brand, project)
     * scope. Mirrors KvStudioFileService::nextDefaultName with a resize base.
     */
    private function nextDefaultName(string $workspaceId, ?string $brandId, ?string $projectId): string
    {
        $base = 'Untitled Resize Job';

        $names = StudioFile::withoutGlobalScope('workspace')
            ->where('workspace_id', $workspaceId)
            ->where('brand_id', $brandId)
            ->where('project_id', $projectId)
            ->where(function ($q) use ($base) {
                $q->where('name', $base)->orWhere('name', 'like', $base.' %');
            })
            ->pluck('name');

        if ($names->isEmpty()) {
            return $base;
        }

        $max = 1;
        $pattern = '/^'.preg_quote($base, '/').' (\d+)$/';
        foreach ($names as $name) {
            if (preg_match($pattern, $name, $m)) {
                $max = max($max, (int) $m[1]);
            }
        }

        return $base.' '.($max + 1);
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd api && php artisan test --compact --filter=ResizerFileServiceTest`
Expected: PASS (2 passed).

- [ ] **Step 5: Format and commit**

```bash
cd api && vendor/bin/pint --dirty --format agent
git add app/Services/Studio/ResizerFileService.php tests/Unit/Services/Studio/ResizerFileServiceTest.php
git commit -m "feat(api): add ResizerFileService for standalone resizer files"
```

---

## Task 2: `ResizerFileController` — store + show, with routes

**Files:**
- Create: `app/Http/Requests/Studio/CreateResizerFileRequest.php`
- Create: `app/Http/Controllers/Api/Studio/ResizerFileController.php`
- Modify: `routes/api.php` (inside the `feature.flag:show-kv-generator` group, near line 2870)
- Test: `tests/Feature/Studio/ResizerFileControllerTest.php`

**Interfaces:**
- Consumes: `ResizerFileService::createFile(...)` (Task 1); `StudioFileResource`, `KvGenerationResource`, `StudioFile`, `StudioProject`, `KvGeneration`.
- Produces:
  - `POST /v1/studio/resizer/files` → 201, body `{ data: StudioFileResource }`.
  - `GET  /v1/studio/resizer/files/{id}` → 200, body `{ data: StudioFileResource, generations: KvGenerationResource[] }` (generations ordered latest-first, so `generations[0]` is the resize source).

- [ ] **Step 1: Write the failing feature test**

Create `tests/Feature/Studio/ResizerFileControllerTest.php`:

```php
<?php

use App\Models\Brand;
use App\Models\KvGeneration;
use App\Models\StudioFile;
use App\Models\Tool;
use App\Models\User;
use App\Models\Workspace;

use function Pest\Laravel\actingAs;
use function Pest\Laravel\getJson;
use function Pest\Laravel\postJson;

beforeEach(function () {
    config()->set('features.show-kv-generator', true); // fail-open flag helper; see note below
    Tool::factory()->create(['slug' => 'resizer', 'name' => 'Resizer']);
    $this->workspace = Workspace::factory()->create();
    $this->user = User::factory()->create(['current_workspace_id' => $this->workspace->id]);
    $this->brand = Brand::factory()->create(['workspace_id' => $this->workspace->id]);
});

it('creates a resizer file scoped to the brand', function () {
    actingAs($this->user);

    $res = postJson('/api/v1/studio/resizer/files', [
        'brand_id' => $this->brand->id,
    ]);

    $res->assertCreated()
        ->assertJsonPath('data.tool.slug', 'resizer')
        ->assertJsonPath('data.name', 'Untitled Resize Job');

    expect(StudioFile::where('brand_id', $this->brand->id)->count())->toBe(1);
});

it('requires a valid brand_id', function () {
    actingAs($this->user);

    postJson('/api/v1/studio/resizer/files', [])
        ->assertStatus(422)
        ->assertJsonValidationErrors('brand_id');
});

it('shows a resizer file with its generations, latest first', function () {
    actingAs($this->user);

    $file = StudioFile::factory()->create([
        'workspace_id' => $this->workspace->id,
        'brand_id' => $this->brand->id,
        'tool_id' => Tool::where('slug', 'resizer')->first()->id,
        'created_by' => $this->user->id,
        'last_edited_by' => $this->user->id,
    ]);
    $gen = KvGeneration::factory()->create([
        'studio_file_id' => $file->id,
        'version_number' => 1,
        'image_url' => 'https://example.test/src.png',
        'created_by' => $this->user->id,
    ]);

    getJson("/api/v1/studio/resizer/files/{$file->id}")
        ->assertOk()
        ->assertJsonPath('data.id', $file->id)
        ->assertJsonPath('generations.0.id', $gen->id);
});

it('forbids showing a file from another workspace', function () {
    actingAs($this->user);

    $otherWorkspace = Workspace::factory()->create();
    $otherBrand = Brand::factory()->create(['workspace_id' => $otherWorkspace->id]);
    $foreign = StudioFile::factory()->create([
        'workspace_id' => $otherWorkspace->id,
        'brand_id' => $otherBrand->id,
        'tool_id' => Tool::where('slug', 'resizer')->first()->id,
        'created_by' => $this->user->id,
        'last_edited_by' => $this->user->id,
    ]);

    getJson("/api/v1/studio/resizer/files/{$foreign->id}")->assertForbidden();
});
```

> **Flag note for Step 2:** the resize routes sit behind `feature.flag:show-kv-generator`. Before running, check how existing resize feature tests satisfy this middleware — grep `tests/Feature/Studio` for `show-kv-generator` or `feature.flag` and copy that exact enabling mechanism (a config set, a `Feature::define`, or a helper) into `beforeEach`, replacing the placeholder `config()->set(...)` line above if it differs. Do not invent a new mechanism.

- [ ] **Step 2: Verify DB isolation, then run the test to confirm it fails**

First confirm `api/phpunit.xml` sqlite `:memory:` + `RefreshDatabase` (Global Constraints). Then:
Run: `cd api && php artisan test --compact --filter=ResizerFileControllerTest`
Expected: FAIL — 404/route-not-found (routes not registered yet).

- [ ] **Step 3: Write the FormRequest**

Create `app/Http/Requests/Studio/CreateResizerFileRequest.php`:

```php
<?php

namespace App\Http\Requests\Studio;

use Illuminate\Foundation\Http\FormRequest;

class CreateResizerFileRequest extends FormRequest
{
    public function authorize(): bool
    {
        return $this->user() !== null;
    }

    /**
     * @return array<string, array<int, string>>
     */
    public function rules(): array
    {
        return [
            'project_id' => ['nullable', 'string', 'exists:studio_projects,id'],
            'brand_id' => ['required', 'string', 'exists:brands,id'],
        ];
    }
}
```

- [ ] **Step 4: Write the controller**

Create `app/Http/Controllers/Api/Studio/ResizerFileController.php`:

```php
<?php

namespace App\Http\Controllers\Api\Studio;

use App\Http\Controllers\Controller;
use App\Http\Requests\Studio\CreateResizerFileRequest;
use App\Http\Resources\Studio\KvGenerationResource;
use App\Http\Resources\Studio\StudioFileResource;
use App\Models\StudioFile;
use App\Models\StudioProject;
use App\Services\Studio\ResizerFileService;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;

class ResizerFileController extends Controller
{
    public function store(CreateResizerFileRequest $request, ResizerFileService $files): JsonResponse
    {
        $workspaceId = $request->user()->current_workspace_id;
        $brandId = $request->input('brand_id');
        $projectId = $request->input('project_id');

        $project = $projectId ? StudioProject::findOrFail($projectId) : null;
        if ($project && $project->brand_id !== $brandId) {
            abort(422, 'Project brand does not match file brand');
        }

        $file = $files->createFile(
            user: $request->user(),
            workspaceId: $workspaceId,
            brandId: $brandId,
            projectId: $projectId,
        );

        return (new StudioFileResource($file->load(['tool'])))
            ->response()
            ->setStatusCode(201);
    }

    public function show(Request $request, string $id): JsonResponse
    {
        $file = StudioFile::with(['tool', 'generations', 'lastEditedBy'])->findOrFail($id);
        abort_unless($file->workspace_id === $request->user()->current_workspace_id, 403);

        return response()->json([
            'data' => (new StudioFileResource($file))->resolve(),
            'generations' => KvGenerationResource::collection($file->generations)->resolve(),
        ]);
    }
}
```

- [ ] **Step 5: Register the routes**

In `routes/api.php`, inside the `feature.flag:show-kv-generator` group (immediately after the `kv-generator/files` store route around line 2873), add:

```php
Route::post('resizer/files', [
    \App\Http\Controllers\Api\Studio\ResizerFileController::class,
    'store',
]);
Route::get('resizer/files/{id}', [
    \App\Http\Controllers\Api\Studio\ResizerFileController::class,
    'show',
]);
```

(Match the surrounding import style — if the file uses a top `use` import for `KvGeneratorFileController`, add `use App\Http\Controllers\Api\Studio\ResizerFileController;` and drop the FQCN. Verify with `php artisan route:list --path=studio/resizer`.)

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd api && php artisan test --compact --filter=ResizerFileControllerTest`
Expected: PASS (4 passed). If the flag middleware still blocks, fix the `beforeEach` enabling mechanism per the Step 1 flag note.

- [ ] **Step 7: Format and commit**

```bash
cd api && vendor/bin/pint --dirty --format agent
git add app/Http/Requests/Studio/CreateResizerFileRequest.php \
        app/Http/Controllers/Api/Studio/ResizerFileController.php \
        routes/api.php tests/Feature/Studio/ResizerFileControllerTest.php
git commit -m "feat(api): add resizer file store + show endpoints"
```

---

## Task 3: Download-ZIP endpoint for resize exports

**Files:**
- Modify: `app/Http/Controllers/Api/Studio/KvResizeExportController.php` (add `downloadZip`)
- Modify: `routes/api.php` (add `GET files/{file}/resize-exports/download-zip` inside the gated group, next to the other resize-export routes ~line 2927)
- Test: `tests/Feature/Studio/KvResizeExportZipTest.php`

**Interfaces:**
- Consumes: `StudioFile`, `KvGeneration`, `KvResizeExport`, `Illuminate\Support\Facades\Http`, `ZipArchive`.
- Produces: `GET /v1/studio/files/{file}/resize-exports/download-zip` → streams `application/zip` (attachment `resize-{fileName}.zip`) of every `done` export for the file's latest generation; 404 when the file has no generation or no `done` export; 403 cross-workspace.

- [ ] **Step 1: Write the failing feature test**

Create `tests/Feature/Studio/KvResizeExportZipTest.php`:

```php
<?php

use App\Models\Brand;
use App\Models\KvGeneration;
use App\Models\KvResizeExport;
use App\Models\StudioFile;
use App\Models\Tool;
use App\Models\User;
use App\Models\Workspace;
use Illuminate\Support\Facades\Http;

use function Pest\Laravel\actingAs;
use function Pest\Laravel\getJson;

beforeEach(function () {
    config()->set('features.show-kv-generator', true); // same flag mechanism as Task 2 (adjust to match existing resize tests)
    Tool::factory()->create(['slug' => 'resizer', 'name' => 'Resizer']);
    $this->workspace = Workspace::factory()->create();
    $this->user = User::factory()->create(['current_workspace_id' => $this->workspace->id]);
    $this->brand = Brand::factory()->create(['workspace_id' => $this->workspace->id]);
    $this->file = StudioFile::factory()->create([
        'workspace_id' => $this->workspace->id,
        'brand_id' => $this->brand->id,
        'tool_id' => Tool::where('slug', 'resizer')->first()->id,
        'created_by' => $this->user->id,
        'last_edited_by' => $this->user->id,
        'name' => 'Summer KV',
    ]);
    $this->gen = KvGeneration::factory()->create([
        'studio_file_id' => $this->file->id,
        'version_number' => 1,
        'image_url' => 'https://s3.test/src.png',
        'created_by' => $this->user->id,
    ]);
});

it('zips only the done exports of the latest generation', function () {
    actingAs($this->user);
    Http::fake(['*' => Http::response('FAKEPNGBYTES', 200)]);

    KvResizeExport::factory()->create([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $this->gen->id,
        'platform_id' => 'instagram-story',
        'width' => 1080, 'height' => 1920,
        'image_url' => 'https://s3.test/ig.png',
        'status' => 'done',
        'created_by' => $this->user->id,
    ]);
    KvResizeExport::factory()->create([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $this->gen->id,
        'platform_id' => 'tiktok-video',
        'width' => 1080, 'height' => 1920,
        'image_url' => null,
        'status' => 'pending',
        'created_by' => $this->user->id,
    ]);

    $res = getJson("/api/v1/studio/files/{$this->file->id}/resize-exports/download-zip");

    $res->assertOk();
    expect($res->headers->get('content-type'))->toContain('application/zip');
    expect($res->headers->get('content-disposition'))->toContain('.zip');
});

it('404s when there are no done exports', function () {
    actingAs($this->user);

    getJson("/api/v1/studio/files/{$this->file->id}/resize-exports/download-zip")
        ->assertNotFound();
});

it('forbids cross-workspace download', function () {
    actingAs($this->user);

    $otherWs = Workspace::factory()->create();
    $otherBrand = Brand::factory()->create(['workspace_id' => $otherWs->id]);
    $foreign = StudioFile::factory()->create([
        'workspace_id' => $otherWs->id,
        'brand_id' => $otherBrand->id,
        'tool_id' => Tool::where('slug', 'resizer')->first()->id,
        'created_by' => $this->user->id,
        'last_edited_by' => $this->user->id,
    ]);

    getJson("/api/v1/studio/files/{$foreign->id}/resize-exports/download-zip")
        ->assertForbidden();
});
```

> If `KvResizeExport` has no factory yet, create a minimal one at `database/factories/KvResizeExportFactory.php` mirroring the table columns from the resize migration (`studio_file_id`, `parent_generation_id`, `created_by`, `platform_id`, `width`, `height`, `image_url` nullable, `status` default `'pending'`, `crop_window` nullable). Fold that into this task's commit.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd api && php artisan test --compact --filter=KvResizeExportZipTest`
Expected: FAIL — route not found (download-zip not registered).

- [ ] **Step 3: Add the `downloadZip` method**

In `app/Http/Controllers/Api/Studio/KvResizeExportController.php`, add these imports at the top (if absent) — `use App\Models\KvResizeExport;`, `use Illuminate\Support\Facades\Http;`, `use ZipArchive;` — then add the method to the class:

```php
public function downloadZip(Request $request, string $fileId): \Symfony\Component\HttpFoundation\BinaryFileResponse
{
    $file = StudioFile::findOrFail($fileId);
    abort_unless($file->workspace_id === $request->user()->current_workspace_id, 403);

    $latest = KvGeneration::where('studio_file_id', $file->id)
        ->orderByDesc('version_number')
        ->first();
    abort_unless($latest, 404, 'This file has no source to export.');

    $rows = KvResizeExport::where('studio_file_id', $file->id)
        ->where('parent_generation_id', $latest->id)
        ->where('status', 'done')
        ->whereNotNull('image_url')
        ->get();
    abort_if($rows->isEmpty(), 404, 'No completed exports to download.');

    $dir = storage_path('app/tmp/resize-zip/'.$file->id.'-'.uniqid());
    if (! is_dir($dir)) {
        mkdir($dir, 0755, true);
    }
    $zipPath = $dir.'/exports.zip';

    $zip = new ZipArchive;
    if ($zip->open($zipPath, ZipArchive::CREATE | ZipArchive::OVERWRITE) !== true) {
        abort(500, 'Failed to create the export archive.');
    }

    foreach ($rows as $row) {
        $bytes = Http::get($row->image_url)->body();
        $name = "{$row->platform_id}-{$row->width}x{$row->height}.png";
        $zip->addFromString($name, $bytes);
    }
    $zip->close();

    $safeName = preg_replace('/[^A-Za-z0-9_-]+/', '-', $file->name ?: 'resize');

    return response()
        ->download($zipPath, "resize-{$safeName}.zip", ['Content-Type' => 'application/zip'])
        ->deleteFileAfterSend(true);
}
```

- [ ] **Step 4: Register the route**

In `routes/api.php`, inside the gated group next to the other resize-export routes (after the `resize-exports/stream` route ~line 2926), add:

```php
Route::get('files/{file}/resize-exports/download-zip', [
    KvResizeExportController::class,
    'downloadZip',
]);
```

(Place it BEFORE the `files/{file}/resize-exports/{export}` DELETE-style routes so `download-zip` isn't captured as an `{export}` id. Verify: `php artisan route:list --path=resize-exports/download-zip`.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd api && php artisan test --compact --filter=KvResizeExportZipTest`
Expected: PASS (3 passed).

- [ ] **Step 6: Format and commit**

```bash
cd api && vendor/bin/pint --dirty --format agent
git add app/Http/Controllers/Api/Studio/KvResizeExportController.php routes/api.php \
        tests/Feature/Studio/KvResizeExportZipTest.php database/factories/KvResizeExportFactory.php
git commit -m "feat(api): add resize-exports download-zip endpoint"
```

---

## Task 4: Full suite + route sanity

- [ ] **Step 1: Run all three new tests together**

Run: `cd api && php artisan test --compact --filter='ResizerFileServiceTest|ResizerFileControllerTest|KvResizeExportZipTest'`
Expected: PASS (9 passed).

- [ ] **Step 2: Confirm the routes exist and are gated**

Run: `cd api && php artisan route:list --path=studio/resizer && php artisan route:list --path=resize-exports/download-zip`
Expected: three rows (`POST resizer/files`, `GET resizer/files/{id}`, `GET …/resize-exports/download-zip`), each showing the `feature.flag:show-kv-generator` middleware.

- [ ] **Step 3: Commit any final formatting**

```bash
cd api && vendor/bin/pint --dirty --format agent
git add -A && git commit -m "chore(api): resizer route sanity" --allow-empty
```

---

## Self-review notes (verified against the spec)

- **Spec §Backend.1 (resizer file create):** Task 1 + 2. No thread, `tool=resizer`, `current_mode=resize`. ✓
- **Spec §Backend.2 (source upload):** reuses the existing `import-from-upload` endpoint unchanged (tool-agnostic) — no API task needed; the web plan calls it. ✓ (Noted, not re-implemented.)
- **Spec §Backend.3 (resize pipeline unchanged):** no task — verified the resize-export routes/services are file-generic and satisfied by the resizer file + its imported generation. ✓
- **Spec §Backend.4 (Download ZIP):** Task 3, server-side, `done`-only, latest generation, auth-gated. ✓
- **Spec §Backend.5 (analytics):** PostHog web events (web plan) — no API `StudioActivity` action added (resize writes none today). ✓ Intentional deviation, recorded here.
- **Spec §show endpoint:** added `GET resizer/files/{id}` (file + generations) so the web can hydrate the source — this is the one addition beyond the spec's literal text, needed because the KV `show` is too heavy to reuse. ✓
