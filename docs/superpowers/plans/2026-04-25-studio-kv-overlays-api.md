# KV Overlays — API (Laravel) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add storage and endpoints for client-side text/image overlay layers on KV Generator files. One JSON column on `studio_files`, one PATCH endpoint to replace the array, one upload endpoint for image assets.

**Architecture:** JSON column on `studio_files`; whole-array PATCH (no per-overlay CRUD); separate multipart upload endpoint that returns an S3 URL the client embeds in the overlay payload. Reuses existing `s3` disk and the studio routes group.

**Tech Stack:** Laravel 13, PHP 8.5, PostgreSQL JSON column, ULID IDs, Pest/PHPUnit feature tests, Sanctum + JWT auth.

**Spec reference:** [docs/superpowers/specs/2026-04-25-studio-kv-overlays-design.md](docs/superpowers/specs/2026-04-25-studio-kv-overlays-design.md)

**Depends on:** existing `studio_files` table and `Api\Studio\StudioFileController` from the kv-generator API plan (already merged).

---

## File Structure

**Migrations (create):**
- `api/database/migrations/<ts>_add_overlays_to_studio_files_table.php`

**Models (modify):**
- `api/app/Models/StudioFile.php` — add `overlays` to `$fillable` + `'array'` cast.

**Form Requests (create):**
- `api/app/Http/Requests/Studio/UpdateStudioFileOverlaysRequest.php`
- `api/app/Http/Requests/Studio/UploadStudioOverlayAssetRequest.php`

**Resources (modify):**
- `api/app/Http/Resources/Studio/StudioFileResource.php` — include `overlays` field.
- `api/app/Http/Resources/Studio/KvGenerationResource.php` — unchanged (kept for reference).

**Controllers (modify + create):**
- Modify: `api/app/Http/Controllers/Api/Studio/StudioFileController.php` — add `updateOverlays` action.
- Create: `api/app/Http/Controllers/Api/Studio/StudioOverlayAssetController.php` — single `store` action for uploads.

**Routes (modify):**
- `api/routes/api.php` — register two new routes inside the existing `prefix('studio')` group.

**Tests (create):**
- `api/tests/Feature/Studio/UpdateStudioFileOverlaysTest.php`
- `api/tests/Feature/Studio/UploadStudioOverlayAssetTest.php`

---

## Task 1 — Migration: add `overlays` JSON column

**Files:**
- Create: `api/database/migrations/<ts>_add_overlays_to_studio_files_table.php`

- [ ] **Step 1: Generate the migration**

```bash
cd api && php artisan make:migration add_overlays_to_studio_files_table --table=studio_files
```

- [ ] **Step 2: Replace the migration body**

```php
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void
    {
        Schema::table('studio_files', function (Blueprint $table) {
            // Client-side overlay layers (text + image) composited on
            // top of the KV bg image. NULL = no overlays; read as [].
            $table->json('overlays')->nullable()->after('metadata');
        });
    }

    public function down(): void
    {
        Schema::table('studio_files', function (Blueprint $table) {
            $table->dropColumn('overlays');
        });
    }
};
```

- [ ] **Step 3: Run the migration**

```bash
cd api && php artisan migrate
```

Expected: `INFO  Running migrations.` followed by the new migration name and `DONE`.

- [ ] **Step 4: Commit**

```bash
git add api/database/migrations/*_add_overlays_to_studio_files_table.php
git commit -m "feat(api): add overlays JSON column to studio_files"
```

---

## Task 2 — Model: cast + fillable

**Files:**
- Modify: `api/app/Models/StudioFile.php`

- [ ] **Step 1: Add `overlays` to `$fillable`**

In `api/app/Models/StudioFile.php`, append `'overlays'` to the `$fillable` array:

```php
protected $fillable = [
    'workspace_id',
    'brand_id',
    'tool_id',
    'project_id',
    'thread_id',
    'created_by',
    'last_edited_by',
    'name',
    'status',
    'thumbnail_url',
    'last_edited_at',
    'metadata',
    'overlays',
];
```

- [ ] **Step 2: Add `'array'` cast**

In the same file, extend the `casts()` method:

```php
protected function casts(): array
{
    return [
        'status' => StudioProjectStatus::class,
        'last_edited_at' => 'datetime',
        'metadata' => 'array',
        'overlays' => 'array',
    ];
}
```

- [ ] **Step 3: Verify with tinker**

```bash
cd api && php artisan tinker --execute="\$f = \App\Models\StudioFile::first(); var_dump(\$f?->overlays);"
```

Expected: `NULL` (no overlays set yet) without an exception.

- [ ] **Step 4: Commit**

```bash
git add api/app/Models/StudioFile.php
git commit -m "feat(api): cast studio_files.overlays as array"
```

---

## Task 3 — `UpdateStudioFileOverlaysRequest` validation

**Files:**
- Create: `api/app/Http/Requests/Studio/UpdateStudioFileOverlaysRequest.php`

- [ ] **Step 1: Create the request file**

```php
<?php

namespace App\Http\Requests\Studio;

use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Validation\Rule;

class UpdateStudioFileOverlaysRequest extends FormRequest
{
    public function authorize(): bool
    {
        // The route is bound to a StudioFile via implicit binding +
        // workspace scope; controller-level authorization is enough.
        return true;
    }

    public function rules(): array
    {
        return [
            'overlays' => ['present', 'array', 'max:30'],
            'overlays.*.id' => ['nullable', 'string', 'size:26'], // ULID
            'overlays.*.type' => ['required', Rule::in(['text', 'image'])],
            'overlays.*.x' => ['required', 'numeric', 'between:0,1'],
            'overlays.*.y' => ['required', 'numeric', 'between:0,1'],
            'overlays.*.width' => ['required', 'numeric', 'between:0,1'],
            'overlays.*.height' => ['required', 'numeric', 'between:0,1'],
            'overlays.*.rotation' => ['required', 'numeric'],
            'overlays.*.z' => ['nullable', 'integer'],
            'overlays.*.payload' => ['required', 'array'],

            // Discriminated payload — text
            'overlays.*.payload.type' => ['required', Rule::in(['text', 'image'])],
            'overlays.*.payload.content' => ['required_if:overlays.*.payload.type,text', 'string', 'max:500'],
            'overlays.*.payload.color' => ['required_if:overlays.*.payload.type,text', 'regex:/^#[0-9A-Fa-f]{6}$/'],

            // Discriminated payload — image
            'overlays.*.payload.asset_url' => ['required_if:overlays.*.payload.type,image', 'url'],
            'overlays.*.payload.mime_type' => [
                'required_if:overlays.*.payload.type,image',
                Rule::in(['image/png', 'image/jpeg', 'image/webp', 'image/svg+xml']),
            ],
        ];
    }

    public function withValidator($validator): void
    {
        $validator->after(function ($v) {
            $overlays = $this->input('overlays', []);
            $allowedHosts = collect(config('filesystems.disks.s3'))
                ->only(['bucket', 'url'])
                ->values()
                ->all();

            foreach ($overlays as $i => $overlay) {
                if (($overlay['payload']['type'] ?? null) === 'image') {
                    $url = $overlay['payload']['asset_url'] ?? '';
                    $host = parse_url($url, PHP_URL_HOST) ?? '';
                    // Bucket must be in our trusted S3 host (config-driven).
                    $trusted = config('app.s3_overlay_host_pattern', '');
                    if ($trusted && !str_contains($host, $trusted)) {
                        $v->errors()->add(
                            "overlays.$i.payload.asset_url",
                            'asset_url host is not on the trusted list.',
                        );
                    }
                }
            }
        });
    }
}
```

- [ ] **Step 2: Add the trusted-host config key**

In `api/config/app.php`, add:

```php
's3_overlay_host_pattern' => env('S3_OVERLAY_HOST_PATTERN', ''),
```

In `api/.env.example`, add:

```
S3_OVERLAY_HOST_PATTERN=
```

(Set to a substring of your S3 bucket host in environment-specific `.env` files. Empty disables the check, which is fine for local dev.)

- [ ] **Step 3: Commit**

```bash
git add api/app/Http/Requests/Studio/UpdateStudioFileOverlaysRequest.php api/config/app.php api/.env.example
git commit -m "feat(api): add UpdateStudioFileOverlaysRequest with discriminated payload validation"
```

---

## Task 4 — Controller: `updateOverlays` action + route

**Files:**
- Modify: `api/app/Http/Controllers/Api/Studio/StudioFileController.php`
- Modify: `api/app/Http/Resources/Studio/StudioFileResource.php`
- Modify: `api/routes/api.php`

- [ ] **Step 1: Write the failing test**

File: `api/tests/Feature/Studio/UpdateStudioFileOverlaysTest.php`

```php
<?php

use App\Models\StudioFile;
use App\Models\User;

beforeEach(function () {
    $this->user = User::factory()->create();
    $this->file = StudioFile::factory()->create([
        'workspace_id' => $this->user->workspaces->first()->id,
    ]);
    $this->actingAs($this->user);
});

test('PATCH overlays replaces the array atomically', function () {
    $payload = [
        'overlays' => [
            [
                'type' => 'text',
                'x' => 0.1, 'y' => 0.2, 'width' => 0.3, 'height' => 0.05, 'rotation' => 0,
                'payload' => ['type' => 'text', 'content' => 'Hello', 'color' => '#FFFFFF'],
            ],
        ],
    ];

    $res = $this->patchJson("/api/v1/studio/files/{$this->file->id}/overlays", $payload);

    $res->assertOk();
    $res->assertJsonPath('data.overlays.0.type', 'text');
    $res->assertJsonPath('data.overlays.0.payload.content', 'Hello');

    // Server should have stamped id + z + timestamps.
    $first = $res->json('data.overlays.0');
    expect($first['id'])->toBeString()->and(strlen($first['id']))->toBe(26);
    expect($first['z'])->toBe(0);

    // Replace with a different array — old element gone.
    $this->patchJson("/api/v1/studio/files/{$this->file->id}/overlays", ['overlays' => []])
        ->assertOk()
        ->assertJsonPath('data.overlays', []);
});

test('PATCH overlays rejects > 30 items', function () {
    $overlays = collect()->range(1, 31)->map(fn ($i) => [
        'type' => 'text',
        'x' => 0.0, 'y' => 0.0, 'width' => 0.1, 'height' => 0.05, 'rotation' => 0,
        'payload' => ['type' => 'text', 'content' => "$i", 'color' => '#FFFFFF'],
    ])->all();

    $this->patchJson("/api/v1/studio/files/{$this->file->id}/overlays", ['overlays' => $overlays])
        ->assertStatus(422)
        ->assertJsonValidationErrors(['overlays']);
});

test('PATCH overlays rejects out-of-range coords', function () {
    $this->patchJson("/api/v1/studio/files/{$this->file->id}/overlays", [
        'overlays' => [[
            'type' => 'text',
            'x' => 1.5, 'y' => 0, 'width' => 0.1, 'height' => 0.05, 'rotation' => 0,
            'payload' => ['type' => 'text', 'content' => 'x', 'color' => '#FFFFFF'],
        ]],
    ])->assertStatus(422)->assertJsonValidationErrors(['overlays.0.x']);
});

test('PATCH overlays denies access to a file in another workspace', function () {
    $otherFile = StudioFile::factory()->create();

    $this->patchJson("/api/v1/studio/files/{$otherFile->id}/overlays", ['overlays' => []])
        ->assertNotFound();
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd api && php artisan test --filter=UpdateStudioFileOverlaysTest
```

Expected: FAIL with route-not-found (`PATCH /api/v1/studio/files/{id}/overlays`).

- [ ] **Step 3: Add the controller action**

In `api/app/Http/Controllers/Api/Studio/StudioFileController.php`, add (and add necessary imports `use App\Http\Requests\Studio\UpdateStudioFileOverlaysRequest;` + `use Illuminate\Support\Str;`):

```php
public function updateOverlays(
    UpdateStudioFileOverlaysRequest $request,
    string $id,
) {
    $file = StudioFile::query()->findOrFail($id);
    $this->authorize('update', $file);

    $validated = $request->validated()['overlays'] ?? [];
    $now = now()->toIso8601String();

    // Server-stamp id, z, created_at, updated_at on every element.
    $stamped = collect($validated)
        ->values()
        ->map(function (array $o, int $idx) use ($now) {
            return [
                'id' => $o['id'] ?? (string) Str::ulid(),
                'type' => $o['type'],
                'x' => (float) $o['x'],
                'y' => (float) $o['y'],
                'width' => (float) $o['width'],
                'height' => (float) $o['height'],
                'rotation' => (float) $o['rotation'],
                'z' => $o['z'] ?? $idx,
                'payload' => $o['payload'],
                'created_at' => $o['created_at'] ?? $now,
                'updated_at' => $now,
            ];
        })
        ->all();

    $file->forceFill(['overlays' => $stamped])->save();

    return new StudioFileResource($file->fresh());
}
```

- [ ] **Step 4: Include `overlays` in `StudioFileResource`**

In `api/app/Http/Resources/Studio/StudioFileResource.php`, add to the returned array (typical place: between `metadata` and timestamps):

```php
'overlays' => $this->overlays ?? [],
```

- [ ] **Step 5: Register the route**

In `api/routes/api.php`, inside the `Route::prefix('studio')->middleware(['scope_role:internal'])->group(...)` block (right after the existing `files/{id}/move` line):

```php
Route::patch('files/{id}/overlays', [
    \App\Http\Controllers\Api\Studio\StudioFileController::class,
    'updateOverlays',
]);
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
cd api && php artisan test --filter=UpdateStudioFileOverlaysTest
```

Expected: PASS — all four cases.

- [ ] **Step 7: Commit**

```bash
git add api/app/Http/Controllers/Api/Studio/StudioFileController.php \
        api/app/Http/Resources/Studio/StudioFileResource.php \
        api/routes/api.php \
        api/tests/Feature/Studio/UpdateStudioFileOverlaysTest.php
git commit -m "feat(api): add PATCH /studio/files/{id}/overlays endpoint"
```

---

## Task 5 — `UploadStudioOverlayAssetRequest`

**Files:**
- Create: `api/app/Http/Requests/Studio/UploadStudioOverlayAssetRequest.php`

- [ ] **Step 1: Create the request**

```php
<?php

namespace App\Http\Requests\Studio;

use Illuminate\Foundation\Http\FormRequest;

class UploadStudioOverlayAssetRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    public function rules(): array
    {
        return [
            'file' => [
                'required',
                'file',
                'image',
                'mimes:png,jpg,jpeg,webp,svg',
                'max:10240', // 10 MB
            ],
        ];
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add api/app/Http/Requests/Studio/UploadStudioOverlayAssetRequest.php
git commit -m "feat(api): add UploadStudioOverlayAssetRequest"
```

---

## Task 6 — Overlay asset upload controller + route

**Files:**
- Create: `api/app/Http/Controllers/Api/Studio/StudioOverlayAssetController.php`
- Modify: `api/routes/api.php`

- [ ] **Step 1: Write the failing test**

File: `api/tests/Feature/Studio/UploadStudioOverlayAssetTest.php`

```php
<?php

use App\Models\StudioFile;
use App\Models\User;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Storage;

beforeEach(function () {
    Storage::fake('s3');

    $this->user = User::factory()->create();
    $this->file = StudioFile::factory()->create([
        'workspace_id' => $this->user->workspaces->first()->id,
    ]);
    $this->actingAs($this->user);
});

test('POST overlay-assets uploads a PNG and returns the asset URL', function () {
    $upload = UploadedFile::fake()->image('logo.png', 200, 200);

    $res = $this->postJson(
        "/api/v1/studio/files/{$this->file->id}/overlay-assets",
        ['file' => $upload],
    );

    $res->assertCreated();
    $res->assertJsonStructure(['data' => ['asset_url', 'mime_type', 'file_size', 'file_name']]);
    expect($res->json('data.mime_type'))->toBe('image/png');

    // File should exist on the fake S3 disk under studio/{file_id}/overlays/...
    $stored = collect(Storage::disk('s3')->files("studio/{$this->file->id}/overlays"))->first();
    expect($stored)->not->toBeNull();
});

test('POST overlay-assets rejects > 10MB', function () {
    $upload = UploadedFile::fake()->create('huge.png', 11 * 1024, 'image/png');

    $this->postJson(
        "/api/v1/studio/files/{$this->file->id}/overlay-assets",
        ['file' => $upload],
    )->assertStatus(422)->assertJsonValidationErrors(['file']);
});

test('POST overlay-assets rejects unsupported mime', function () {
    $upload = UploadedFile::fake()->create('doc.pdf', 100, 'application/pdf');

    $this->postJson(
        "/api/v1/studio/files/{$this->file->id}/overlay-assets",
        ['file' => $upload],
    )->assertStatus(422)->assertJsonValidationErrors(['file']);
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd api && php artisan test --filter=UploadStudioOverlayAssetTest
```

Expected: FAIL with route-not-found.

- [ ] **Step 3: Create the controller**

File: `api/app/Http/Controllers/Api/Studio/StudioOverlayAssetController.php`

```php
<?php

namespace App\Http\Controllers\Api\Studio;

use App\Http\Controllers\Controller;
use App\Http\Requests\Studio\UploadStudioOverlayAssetRequest;
use App\Models\StudioFile;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;

class StudioOverlayAssetController extends Controller
{
    public function store(UploadStudioOverlayAssetRequest $request, string $id)
    {
        $file = StudioFile::query()->findOrFail($id);
        $this->authorize('update', $file);

        $upload = $request->file('file');
        $ext = $upload->getClientOriginalExtension();
        $name = Str::ulid() . '.' . $ext;
        $path = $upload->storeAs("studio/{$file->id}/overlays", $name, 's3');
        $url = Storage::disk('s3')->url($path);

        return response()->json([
            'data' => [
                'asset_url' => $url,
                'mime_type' => $upload->getMimeType(),
                'file_size' => $upload->getSize(),
                'file_name' => $upload->getClientOriginalName(),
            ],
        ], 201);
    }
}
```

- [ ] **Step 4: Register the route**

In `api/routes/api.php`, inside the same `Route::prefix('studio')` group (under the `files/{id}/overlays` route added in Task 4):

```php
Route::post('files/{id}/overlay-assets', [
    \App\Http\Controllers\Api\Studio\StudioOverlayAssetController::class,
    'store',
]);
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd api && php artisan test --filter=UploadStudioOverlayAssetTest
```

Expected: PASS — all three cases.

- [ ] **Step 6: Commit**

```bash
git add api/app/Http/Controllers/Api/Studio/StudioOverlayAssetController.php \
        api/routes/api.php \
        api/tests/Feature/Studio/UploadStudioOverlayAssetTest.php
git commit -m "feat(api): add POST /studio/files/{id}/overlay-assets upload endpoint"
```

---

## Task 7 — Include overlays in KV file `show` response

**Files:**
- Modify: `api/app/Http/Controllers/Api/Studio/KvGeneratorFileController.php`

- [ ] **Step 1: Verify current `show` response shape**

```bash
grep -n "show\|StudioFileResource" api/app/Http/Controllers/Api/Studio/KvGeneratorFileController.php | head
```

The `show` action returns `StudioFileResource` (or builds a similar payload). After Task 4 added `overlays` to that resource, this endpoint already includes `overlays` automatically.

- [ ] **Step 2: Write a regression test**

File: `api/tests/Feature/Studio/KvGeneratorFileShowOverlaysTest.php`

```php
<?php

use App\Models\StudioFile;
use App\Models\User;

test('GET kv-generator file show includes overlays array', function () {
    $user = User::factory()->create();
    $file = StudioFile::factory()->create([
        'workspace_id' => $user->workspaces->first()->id,
        'overlays' => [[
            'id' => '01J0000000000000000000000A',
            'type' => 'text',
            'x' => 0.1, 'y' => 0.2, 'width' => 0.3, 'height' => 0.05,
            'rotation' => 0, 'z' => 0,
            'payload' => ['type' => 'text', 'content' => 'Hi', 'color' => '#FFFFFF'],
            'created_at' => now()->toIso8601String(),
            'updated_at' => now()->toIso8601String(),
        ]],
    ]);

    $res = $this->actingAs($user)
        ->getJson("/api/v1/studio/kv-generator/files/{$file->id}");

    $res->assertOk();
    $res->assertJsonPath('data.overlays.0.type', 'text');
});
```

- [ ] **Step 3: Run the test**

```bash
cd api && php artisan test --filter=KvGeneratorFileShowOverlaysTest
```

Expected: PASS. If it fails because `KvGeneratorFileController::show` builds its own array (instead of using the resource), patch the action to include the `overlays` field directly from `$file->overlays ?? []`.

- [ ] **Step 4: Commit**

```bash
git add api/tests/Feature/Studio/KvGeneratorFileShowOverlaysTest.php api/app/Http/Controllers/Api/Studio/KvGeneratorFileController.php
git commit -m "test(api): assert overlays included in kv-generator file show"
```

---

## Self-review checklist (before handoff)

- [ ] **Spec coverage:**
  - JSON column on `studio_files` → Task 1
  - Model `array` cast + fillable → Task 2
  - Validation (discriminator, host check, max 30, range) → Task 3
  - PATCH endpoint replacing the array → Task 4
  - Upload validation → Task 5
  - Upload endpoint + S3 storage path → Task 6
  - File `show` returns overlays → Task 7
- [ ] **Placeholder scan:** none.
- [ ] **Type consistency:** `overlays` field name and shape consistent across migration / model cast / resource / request / controller / tests.
- [ ] **Auth:** every endpoint runs `authorize('update', $file)`; the workspace scope on `StudioFile` model handles cross-workspace isolation (regression-tested in Task 4 step 1).
