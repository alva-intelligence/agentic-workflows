# KV Resize Tile Version History — API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every successful render of a resize tile is kept as an immutable version; failures/cancel keep the last good image; a version can be listed and restored; upscales follow the current version.

**Architecture:** A new `kv_resize_export_versions` table plus `kv_resize_exports.current_version_id`; `image_url` on the export stays the denormalized current image so all readers are untouched. One service (`KvResizeExportVersionService`) owns appending (row lock + `max+1`). Hooks: the completion callback (`markDone`), the separate-layers commit, and a new restore endpoint. Upscales get a version column and are always read/created for the current version.

**Tech Stack:** Laravel 13, PHP 8.5, PostgreSQL, Pest.

**Spec:** `docs/superpowers/specs/2026-09-24-kv-resize-tile-version-history-design.md` (workspace repo)

## Global Constraints

- Repo `api/`, branch `feature/daffa/vc-kv-craft-resize-strip` — created from latest `develop` in Task 1. Commit per task; push to that branch at the end. No PR. Never `git stash`.
- **Test DB safety (two dev-DB wipes happened before):** before EVERY test run, `test ! -e bootstrap/cache/config.php` must hold (a cached config silently points tests at the dev DB). Run only with the scratch DB prefix:
  `DB_CONNECTION=pgsql DB_DATABASE=frnd_region_edit_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false php artisan test --compact <explicit test file paths>`
  Never `DB_DATABASE=frnd`. Pass file paths, never `--filter` alone (the suite mapper dies on an unrelated file). `tests/TestCase.php` refuses non-test databases as a last guard.
- Version kinds, verbatim: `create`, `regenerate`, `region_edit`, `separate`, `restore`.
- New routes (under the same group/prefix as the other resize-export routes, i.e. `/api/v1/studio/files/...`):
  - `GET  files/{file}/resize-exports/{export}/versions`
  - `POST files/{file}/resize-exports/{export}/versions/{version}/restore`
  - `POST files/{file}/resize-exports/{export}/cancel`
- Restore and cancel are free (no `check.credits`).
- Resource adds `current_version_id` (string|null) and `version_count` (int).
- Version list item JSON: `{id, version_number, image_url, kind, prompt, model, restored_from_version_number, created_by_name, created_at}`, newest first, max 100.

## Review Focus

1. **Late callback after cancel** — a render callback arriving after the user cancelled must not append a version or change the image. Pinned in Task 4.
2. **Region edit prompt with no box prompts** — boxes without `prompt` must produce a `region_edit` version with `prompt = null`, not `""`. Pinned in Task 3.
3. **Restore while rendering** — 409, nothing appended. Pinned in Task 5.
4. **Upscale after a regenerate** — the old version's upscale must not be returned for the new image. Pinned in Task 7.
5. **Layer-composed tile** (`image_url` null, done) — no version is ever created for it; regenerate on it still marks done without an image. Pinned in Task 3.

---

## File Structure

| File | Responsibility |
|---|---|
| `database/migrations/2026_09_24_100000_create_kv_resize_export_versions_table.php` (new) | versions table + `current_version_id` |
| `app/Models/KvResizeExportVersion.php` (new) | immutable model (`UPDATED_AT = null`) |
| `database/factories/KvResizeExportVersionFactory.php` (new) | factory |
| `app/Models/KvResizeExport.php` | `versions()`, `currentVersion()`, fillable `current_version_id` |
| `app/Services/Studio/KvResizeExportVersionService.php` (new) | `append`, `kindFor`, `restore`, `backfill` |
| `app/Services/Studio/KvResizeExportService.php` | `markDone` appends; `regenerate` keeps image; `editRegion` stores prompt; `cancel` |
| `app/Http/Controllers/Api/Internal/KvResizeExportInternalController.php` | write model before `markDone` |
| `app/Http/Controllers/Api/Studio/KvResizeExportController.php` | `versions`, `restoreVersion`, `cancel`; `withCount` on index/stream |
| `app/Http/Resources/Studio/KvResizeExportResource.php` | `current_version_id`, `version_count` |
| `app/Http/Resources/Studio/KvResizeExportVersionResource.php` (new) | list item |
| `app/Services/Studio/KvLayerDecompositionService.php` | `commitToResizeExport` appends `separate` |
| `database/migrations/2026_09_24_100100_add_version_to_kv_resize_export_upscales.php` (new) | version column + unique key |
| `app/Models/KvResizeExportUpscale.php`, `app/Services/Studio/KvResizeExportUpscaleService.php`, `app/Http/Controllers/Api/Studio/KvResizeExportUpscaleController.php` | version-scoped reads/creates |
| `database/migrations/2026_09_24_100200_backfill_kv_resize_export_versions.php` (new) | calls `KvResizeExportVersionService::backfill()` |
| `routes/api.php` | 3 routes |
| `tests/Feature/Studio/KvResizeExportVersionTest.php` (new) | all version behaviour |

---

### Task 1: Branch, schema, model

**Files:**
- Create: `database/migrations/2026_09_24_100000_create_kv_resize_export_versions_table.php`, `app/Models/KvResizeExportVersion.php`, `database/factories/KvResizeExportVersionFactory.php`
- Modify: `app/Models/KvResizeExport.php`
- Test: `tests/Feature/Studio/KvResizeExportVersionTest.php`

**Interfaces:**
- Produces: `KvResizeExportVersion` (fillable: `kv_resize_export_id, studio_file_id, version_number, image_url, kind, prompt, model, restored_from_version_id, created_by, created_at`; relations `export()`, `restoredFrom()`, `creator()`); `KvResizeExport::versions(): HasMany` (ordered by `version_number` desc), `KvResizeExport::currentVersion(): BelongsTo`.

- [ ] **Step 0: Branch + safety check**

```bash
cd api
git checkout develop && git pull --rebase origin develop
git checkout -b feature/daffa/vc-kv-craft-resize-strip
test ! -e bootstrap/cache/config.php && echo NO_CONFIG_CACHE
psql -lqt | cut -d'|' -f1 | grep -w frnd_region_edit_test
```
Expected: `NO_CONFIG_CACHE` and the scratch DB listed. If config.php exists, `php artisan config:clear` first.

- [ ] **Step 1: Write the failing test** (create the test file with the shared preamble)

```php
<?php

use App\Enums\KvResizeExportStatus;
use App\Models\Brand;
use App\Models\KvGeneration;
use App\Models\KvResizeExport;
use App\Models\KvResizeExportVersion;
use App\Models\Role;
use App\Models\StudioFile;
use App\Models\Tool;
use App\Models\User;
use App\Models\UserWorkspaceCredit;
use App\Models\Workspace;
use App\Models\WorkspaceCredit;
use Illuminate\Support\Facades\Queue;
use Illuminate\Support\Str;

beforeEach(function () {
    Queue::fake();

    $this->user = User::factory()->create();
    $this->brand = Brand::factory()->create();
    $this->workspace = Workspace::factory()->create(['type' => 'organization']);
    $this->user->update(['current_workspace_id' => $this->workspace->id]);
    $this->user->workspaces()->attach($this->workspace->id);

    $role = Role::factory()->create([
        'slug' => 'internal-'.Str::random(6),
        'type' => 'workspace',
        'scope' => 'internal',
    ]);
    $this->user->workspaceRoles()->attach($role->id, [
        'workspace_id' => $this->workspace->id,
    ]);

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

    $tool = Tool::factory()->create(['slug' => 'kv-generator']);

    $this->file = StudioFile::factory()->create([
        'workspace_id' => $this->workspace->id,
        'brand_id' => $this->brand->id,
        'tool_id' => $tool->id,
        'created_by' => $this->user->id,
        'last_edited_by' => $this->user->id,
    ]);
    $this->generation = KvGeneration::factory()->create([
        'studio_file_id' => $this->file->id,
        'version_number' => 1,
        'image_url' => 'https://example.com/source.png',
        'created_by' => $this->user->id,
    ]);

    $this->tile = fn (array $attrs = []) => KvResizeExport::factory()->create(array_merge([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $this->generation->id,
        'created_by' => $this->user->id,
    ], $attrs));

    $this->actingAs($this->user, 'api');
});

it('stores immutable versions linked to their tile', function () {
    $tile = ($this->tile)(['status' => KvResizeExportStatus::Done, 'image_url' => 'https://cdn/v1.png']);

    $v = KvResizeExportVersion::factory()->create([
        'kv_resize_export_id' => $tile->id,
        'studio_file_id' => $this->file->id,
        'version_number' => 1,
        'image_url' => 'https://cdn/v1.png',
        'kind' => 'create',
    ]);
    $tile->update(['current_version_id' => $v->id]);

    expect($tile->fresh()->currentVersion->id)->toBe($v->id);
    expect($tile->versions()->pluck('id')->all())->toBe([$v->id]);
    expect($v->updated_at ?? null)->toBeNull();
});

it('deletes a tile\'s versions when the tile is hard-deleted', function () {
    $tile = ($this->tile)(['status' => KvResizeExportStatus::Done, 'image_url' => 'https://cdn/v1.png']);
    KvResizeExportVersion::factory()->create([
        'kv_resize_export_id' => $tile->id,
        'studio_file_id' => $this->file->id,
    ]);

    $tile->forceDelete();

    expect(KvResizeExportVersion::count())->toBe(0);
});
```

- [ ] **Step 2: Run it — expect FAIL**

Run: `test ! -e bootstrap/cache/config.php && DB_CONNECTION=pgsql DB_DATABASE=frnd_region_edit_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false php artisan test --compact tests/Feature/Studio/KvResizeExportVersionTest.php`
Expected: FAIL — class `App\Models\KvResizeExportVersion` not found.

- [ ] **Step 3: Migration**

```php
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * Per-tile version history (spec 2026-09-24). Rows are immutable: a
     * restore appends a copy, nothing is ever rewritten — the same model as
     * kv_generations. `kv_resize_exports.image_url` stays the denormalized
     * current image so every existing reader keeps working.
     */
    public function up(): void
    {
        Schema::create('kv_resize_export_versions', function (Blueprint $t) {
            $t->ulid('id')->primary();
            $t->foreignUlid('kv_resize_export_id')
                ->constrained('kv_resize_exports')
                ->cascadeOnDelete();
            $t->foreignUlid('studio_file_id')->constrained('studio_files')->cascadeOnDelete();
            $t->unsignedInteger('version_number');
            $t->string('image_url', 2048);
            $t->string('kind', 24);
            $t->text('prompt')->nullable();
            $t->string('model')->nullable();
            $t->ulid('restored_from_version_id')->nullable();
            $t->foreignUlid('created_by')->nullable()->constrained('users')->nullOnDelete();
            $t->timestamp('created_at')->useCurrent();

            $t->unique(['kv_resize_export_id', 'version_number'], 'kv_resize_export_versions_tile_number_unique');
        });

        Schema::table('kv_resize_export_versions', function (Blueprint $t) {
            $t->foreign('restored_from_version_id')
                ->references('id')->on('kv_resize_export_versions')
                ->nullOnDelete();
        });

        Schema::table('kv_resize_exports', function (Blueprint $t) {
            $t->ulid('current_version_id')->nullable()->after('image_url');
            $t->foreign('current_version_id')
                ->references('id')->on('kv_resize_export_versions')
                ->nullOnDelete();
        });
    }

    public function down(): void
    {
        Schema::table('kv_resize_exports', function (Blueprint $t) {
            $t->dropForeign(['current_version_id']);
            $t->dropColumn('current_version_id');
        });
        Schema::dropIfExists('kv_resize_export_versions');
    }
};
```

- [ ] **Step 4: Model + factory + relations**

`app/Models/KvResizeExportVersion.php`:

```php
<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Concerns\HasUlids;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/**
 * One immutable render of a resize tile (spec 2026-09-24). Never updated:
 * a restore appends a copy with `restored_from_version_id` set.
 */
class KvResizeExportVersion extends Model
{
    use HasFactory, HasUlids;

    public const UPDATED_AT = null;

    public const KINDS = ['create', 'regenerate', 'region_edit', 'separate', 'restore'];

    protected $table = 'kv_resize_export_versions';

    protected $fillable = [
        'kv_resize_export_id',
        'studio_file_id',
        'version_number',
        'image_url',
        'kind',
        'prompt',
        'model',
        'restored_from_version_id',
        'created_by',
        'created_at',
    ];

    protected $casts = [
        'version_number' => 'integer',
        'created_at' => 'datetime',
    ];

    public function export(): BelongsTo
    {
        return $this->belongsTo(KvResizeExport::class, 'kv_resize_export_id');
    }

    public function restoredFrom(): BelongsTo
    {
        return $this->belongsTo(self::class, 'restored_from_version_id');
    }

    public function creator(): BelongsTo
    {
        return $this->belongsTo(User::class, 'created_by');
    }
}
```

`database/factories/KvResizeExportVersionFactory.php`:

```php
<?php

namespace Database\Factories;

use App\Models\KvResizeExport;
use App\Models\KvResizeExportVersion;
use App\Models\StudioFile;
use Illuminate\Database\Eloquent\Factories\Factory;

class KvResizeExportVersionFactory extends Factory
{
    protected $model = KvResizeExportVersion::class;

    public function definition(): array
    {
        return [
            'kv_resize_export_id' => KvResizeExport::factory(),
            'studio_file_id' => StudioFile::factory(),
            'version_number' => 1,
            'image_url' => 'https://example.com/version.png',
            'kind' => 'create',
            'prompt' => null,
            'model' => null,
            'restored_from_version_id' => null,
            'created_by' => null,
        ];
    }
}
```

In `KvResizeExport`: add `'current_version_id'` to `$fillable`, and:

```php
    /** Newest first — the order every reader wants. */
    public function versions(): HasMany
    {
        return $this->hasMany(KvResizeExportVersion::class)->orderByDesc('version_number');
    }

    public function currentVersion(): BelongsTo
    {
        return $this->belongsTo(KvResizeExportVersion::class, 'current_version_id');
    }
```

- [ ] **Step 5: Run — expect PASS (2 tests)**, same command as Step 2.

- [ ] **Step 6: Commit**

```bash
git add database/migrations/2026_09_24_100000_create_kv_resize_export_versions_table.php app/Models/KvResizeExportVersion.php database/factories/KvResizeExportVersionFactory.php app/Models/KvResizeExport.php tests/Feature/Studio/KvResizeExportVersionTest.php
git commit -m "feat(api): kv_resize_export_versions table + current_version_id"
```

---

### Task 2: Version service — append with a row lock

**Files:**
- Create: `app/Services/Studio/KvResizeExportVersionService.php`
- Test: `tests/Feature/Studio/KvResizeExportVersionTest.php` (append)

**Interfaces:**
- Produces:
  - `append(KvResizeExport $row, string $imageUrl, string $kind, ?string $prompt = null, ?string $restoredFromId = null, ?string $userId = null): KvResizeExportVersion` — in a transaction: lock the export row, `version_number = max + 1`, insert, set `current_version_id` + `image_url` on the export.
  - `kindFor(KvResizeExport $row): string` — `region_edit` if `metadata.pending_region_edit`, else `regenerate` if the tile has ≥1 version, else `create`.
  - `promptFor(KvResizeExport $row, string $kind): ?string` — `region_edit`: `metadata.pending_region_edit_prompt`; `regenerate`: `additional_prompt`; else null.

- [ ] **Step 1: Failing tests**

```php
use App\Services\Studio\KvResizeExportVersionService;

it('appends numbered versions and moves the tile\'s current image', function () {
    $tile = ($this->tile)(['status' => KvResizeExportStatus::Generating]);
    $svc = app(KvResizeExportVersionService::class);

    $v1 = $svc->append($tile, 'https://cdn/a.png', 'create');
    $v2 = $svc->append($tile->fresh(), 'https://cdn/b.png', 'regenerate', 'warmer');

    expect([$v1->version_number, $v2->version_number])->toBe([1, 2]);
    $fresh = $tile->fresh();
    expect($fresh->current_version_id)->toBe($v2->id);
    expect($fresh->image_url)->toBe('https://cdn/b.png');
    expect($v2->prompt)->toBe('warmer');
    expect($v1->studio_file_id)->toBe($this->file->id);
});

it('decides the kind from the tile state', function () {
    $svc = app(KvResizeExportVersionService::class);
    $fresh = ($this->tile)(['status' => KvResizeExportStatus::Generating]);
    expect($svc->kindFor($fresh))->toBe('create');

    $svc->append($fresh, 'https://cdn/a.png', 'create');
    expect($svc->kindFor($fresh->fresh()))->toBe('regenerate');

    $fresh->update(['metadata' => ['pending_region_edit' => true]]);
    expect($svc->kindFor($fresh->fresh()))->toBe('region_edit');
});

it('reads the prompt for each kind', function () {
    $svc = app(KvResizeExportVersionService::class);
    $tile = ($this->tile)([
        'additional_prompt' => 'more contrast',
        'metadata' => ['pending_region_edit' => true, 'pending_region_edit_prompt' => 'remove logo'],
    ]);

    expect($svc->promptFor($tile, 'regenerate'))->toBe('more contrast');
    expect($svc->promptFor($tile, 'region_edit'))->toBe('remove logo');
    expect($svc->promptFor($tile, 'create'))->toBeNull();
});
```

- [ ] **Step 2: Run — expect FAIL** (class not found).

- [ ] **Step 3: Implement**

```php
<?php

namespace App\Services\Studio;

use App\Models\KvResizeExport;
use App\Models\KvResizeExportVersion;
use App\Services\Studio\KvResizeChatMarkerService;
use Illuminate\Support\Facades\DB;

/**
 * Owns a resize tile's version history (spec 2026-09-24). Every write goes
 * through append(): it locks the export row so two callbacks landing at
 * once cannot take the same version_number, and it moves the tile's
 * denormalized `image_url` together with `current_version_id`.
 */
class KvResizeExportVersionService
{
    public const PENDING_REGION_EDIT_PROMPT_KEY = 'pending_region_edit_prompt';

    public function append(
        KvResizeExport $row,
        string $imageUrl,
        string $kind,
        ?string $prompt = null,
        ?string $restoredFromId = null,
        ?string $userId = null,
    ): KvResizeExportVersion {
        return DB::transaction(function () use ($row, $imageUrl, $kind, $prompt, $restoredFromId, $userId) {
            $locked = KvResizeExport::query()->lockForUpdate()->findOrFail($row->id);
            $next = ((int) KvResizeExportVersion::where('kv_resize_export_id', $locked->id)
                ->max('version_number')) + 1;

            $version = KvResizeExportVersion::create([
                'kv_resize_export_id' => $locked->id,
                'studio_file_id' => $locked->studio_file_id,
                'version_number' => $next,
                'image_url' => $imageUrl,
                'kind' => $kind,
                'prompt' => $prompt,
                'model' => $locked->model,
                'restored_from_version_id' => $restoredFromId,
                'created_by' => $userId ?? $locked->created_by,
            ]);

            $locked->update([
                'current_version_id' => $version->id,
                'image_url' => $imageUrl,
            ]);
            $row->setRawAttributes($locked->getAttributes(), true);

            return $version;
        });
    }

    public function kindFor(KvResizeExport $row): string
    {
        if (($row->metadata[KvResizeChatMarkerService::PENDING_REGION_EDIT_KEY] ?? false) === true) {
            return 'region_edit';
        }

        return KvResizeExportVersion::where('kv_resize_export_id', $row->id)->exists()
            ? 'regenerate'
            : 'create';
    }

    public function promptFor(KvResizeExport $row, string $kind): ?string
    {
        $prompt = match ($kind) {
            'region_edit' => $row->metadata[self::PENDING_REGION_EDIT_PROMPT_KEY] ?? null,
            'regenerate' => $row->additional_prompt,
            default => null,
        };

        return is_string($prompt) && trim($prompt) !== '' ? $prompt : null;
    }
}
```

- [ ] **Step 4: Run — expect PASS (5 tests).**

- [ ] **Step 5: Commit** — `git add app/Services/Studio/KvResizeExportVersionService.php tests/Feature/Studio/KvResizeExportVersionTest.php && git commit -m "feat(api): KvResizeExportVersionService — locked append, kind + prompt"`

---

### Task 3: Renders append; regenerate and failure keep the image

**Files:**
- Modify: `app/Services/Studio/KvResizeExportService.php` (`regenerate` ≈247, `editRegion` ≈287, `markDone` ≈328), `app/Http/Controllers/Api/Internal/KvResizeExportInternalController.php` (≈41-47)
- Test: `tests/Feature/Studio/KvResizeExportVersionTest.php`

**Interfaces:**
- Consumes: `KvResizeExportVersionService::append / kindFor / promptFor` (Task 2).

- [ ] **Step 1: Failing tests**

```php
$callback = fn (KvResizeExport $row, array $body) => test()->postJson(
    '/api/v1/internal/kv-resize-exports/completed',
    array_merge(['export_id' => $row->id], $body),
);

it('appends a create version on the first successful render', function () use ($callback) {
    $tile = ($this->tile)(['status' => KvResizeExportStatus::Generating]);

    $callback($tile, ['status' => 'done', 'image_url' => 'https://cdn/first.png', 'model' => 'gpt-image-2'])->assertOk();

    $v = $tile->fresh()->currentVersion;
    expect($v->kind)->toBe('create');
    expect($v->version_number)->toBe(1);
    expect($v->model)->toBe('gpt-image-2');
    expect($tile->fresh()->image_url)->toBe('https://cdn/first.png');
});

it('keeps the image when a regenerate is requested and appends on success', function () use ($callback) {
    $tile = ($this->tile)(['status' => KvResizeExportStatus::Generating]);
    $callback($tile, ['status' => 'done', 'image_url' => 'https://cdn/first.png'])->assertOk();

    $this->postJson(
        "/api/v1/studio/files/{$this->file->id}/resize-exports/{$tile->id}/regenerate",
        ['crop_window' => null, 'additional_prompt' => 'warmer light'],
    )->assertStatus(202);

    expect($tile->fresh()->image_url)->toBe('https://cdn/first.png');
    expect($tile->fresh()->status)->toBe(KvResizeExportStatus::Pending);

    $callback($tile, ['status' => 'done', 'image_url' => 'https://cdn/second.png'])->assertOk();

    $v = $tile->fresh()->currentVersion;
    expect($v->kind)->toBe('regenerate');
    expect($v->prompt)->toBe('warmer light');
    expect($v->version_number)->toBe(2);
});

it('keeps the last image and adds no version when a render fails', function () use ($callback) {
    $tile = ($this->tile)(['status' => KvResizeExportStatus::Generating]);
    $callback($tile, ['status' => 'done', 'image_url' => 'https://cdn/first.png'])->assertOk();
    $tile->update(['status' => KvResizeExportStatus::Pending]);

    $callback($tile, ['status' => 'failed', 'error_message' => 'boom'])->assertOk();

    $fresh = $tile->fresh();
    expect($fresh->status)->toBe(KvResizeExportStatus::Failed);
    expect($fresh->image_url)->toBe('https://cdn/first.png');
    expect($fresh->versions()->count())->toBe(1);
});

it('records a region edit with the joined box prompts', function () use ($callback) {
    $tile = ($this->tile)(['status' => KvResizeExportStatus::Generating]);
    $callback($tile, ['status' => 'done', 'image_url' => 'https://cdn/first.png'])->assertOk();

    $this->postJson(
        "/api/v1/studio/files/{$this->file->id}/resize-exports/{$tile->id}/edit-region",
        ['bounding_boxes' => [
            ['id' => 'b1', 'x' => 0.1, 'y' => 0.1, 'width' => 0.2, 'height' => 0.2, 'prompt' => 'remove logo'],
            ['id' => 'b2', 'x' => 0.5, 'y' => 0.5, 'width' => 0.2, 'height' => 0.2, 'prompt' => 'brighter sky'],
        ]],
    )->assertSuccessful();

    $callback($tile, ['status' => 'done', 'image_url' => 'https://cdn/edited.png'])->assertOk();

    $v = $tile->fresh()->currentVersion;
    expect($v->kind)->toBe('region_edit');
    expect($v->prompt)->toBe('remove logo · brighter sky');
});

it('stores a null prompt for a region edit whose boxes carry none', function () use ($callback) {
    $tile = ($this->tile)(['status' => KvResizeExportStatus::Generating]);
    $callback($tile, ['status' => 'done', 'image_url' => 'https://cdn/first.png'])->assertOk();

    $this->postJson(
        "/api/v1/studio/files/{$this->file->id}/resize-exports/{$tile->id}/edit-region",
        ['bounding_boxes' => [['id' => 'b1', 'x' => 0.1, 'y' => 0.1, 'width' => 0.2, 'height' => 0.2]]],
    )->assertSuccessful();
    $callback($tile, ['status' => 'done', 'image_url' => 'https://cdn/edited.png'])->assertOk();

    expect($tile->fresh()->currentVersion->prompt)->toBeNull();
});

it('never versions a layer-composed tile', function () {
    $tile = ($this->tile)(['status' => KvResizeExportStatus::Done, 'image_url' => null]);
    app(\App\Services\Studio\KvResizeExportService::class)->markDoneWithoutImage($tile);

    expect($tile->fresh()->versions()->count())->toBe(0);
    expect($tile->fresh()->current_version_id)->toBeNull();
});
```

Before Step 2, open `tests/Feature/Studio/KvResizeRegionEditTest.php` and copy how it asserts the edit-region response status (202 vs 200) into `assertSuccessful()` if it differs; the helper `$callback` uses `test()` because Pest closures bind `$this` only inside `it`.

- [ ] **Step 2: Run — expect FAIL** (no versions appended; regenerate nulls the image).

- [ ] **Step 3: Implement**

`KvResizeExportService` — inject the version service (constructor property promotion alongside the existing dependencies):

```php
    public function markDone(KvResizeExport $row, string $imageUrl): void
    {
        $kind = $this->versions->kindFor($row);
        $this->versions->append($row, $imageUrl, $kind, $this->versions->promptFor($row, $kind));

        $row->update([
            'status' => KvResizeExportStatus::Done,
            'error_message' => null,
        ]);
    }
```

`regenerate()`: delete the `'image_url' => null,` line and replace the comment above the update with: `// The current image stays until the new render lands (spec 2026-09-24): a failed or cancelled regenerate must leave the tile on its last version, not blank.` Also drop `pending_region_edit_prompt` together with the flag — extend `withoutPendingRegionEdit` to unset `KvResizeExportVersionService::PENDING_REGION_EDIT_PROMPT_KEY` too.

`editRegion()`: store the prompt next to the flag:

```php
        $prompts = collect($boundingBoxes)
            ->map(fn (array $b) => trim((string) ($b['prompt'] ?? '')))
            ->filter()
            ->values()
            ->all();

        $row->update([
            'status' => KvResizeExportStatus::Pending,
            'error_message' => null,
            'metadata' => array_merge(
                $row->metadata ?? [],
                [
                    KvResizeChatMarkerService::PENDING_REGION_EDIT_KEY => true,
                    KvResizeExportVersionService::PENDING_REGION_EDIT_PROMPT_KEY => $prompts === [] ? null : implode(' · ', $prompts),
                ],
            ),
        ]);
```

Internal callback: write `ai_service_run_id` / `model` BEFORE `markDone` so the version records the model:

```php
        if ($validated['status'] === 'done') {
            $row->update([
                'ai_service_run_id' => $validated['ai_service_run_id'] ?? null,
                'model' => $validated['model'] ?? null,
            ]);

            $this->service->markDone($row, $validated['image_url']);
```
(and delete the old `$row->update([...])` that followed `markDone`).

`markDoneWithoutImage` is unchanged (no version).

- [ ] **Step 4: Run** `tests/Feature/Studio/KvResizeExportVersionTest.php tests/Feature/Studio/KvResizeExportInternalCallbackTest.php tests/Feature/Studio/KvResizeExportControllerTest.php tests/Feature/Studio/KvResizeRegionEditTest.php` — expect PASS. If an existing test asserted `image_url` null after regenerate, update it to the new rule and note it in the ledger as a Ruling (spec decision 4).

- [ ] **Step 5: Commit** — `git commit -m "feat(api): renders append tile versions; regenerate and failure keep the last image"`

---

### Task 4: Cancel endpoint

**Files:**
- Modify: `KvResizeExportService.php` (+`cancel`), `KvResizeExportController.php` (+`cancel`), `routes/api.php`
- Test: `tests/Feature/Studio/KvResizeExportVersionTest.php`

**Interfaces:**
- Produces: `KvResizeExportService::cancel(KvResizeExport $row): ?KvResizeExport` — returns the reverted row, or `null` when it deleted a first render. Route `POST files/{file}/resize-exports/{export}/cancel` → 200 `{data: resource}` or 204.

- [ ] **Step 1: Failing tests**

```php
it('cancels a render on a versioned tile by reverting to its image', function () use ($callback) {
    $tile = ($this->tile)(['status' => KvResizeExportStatus::Generating]);
    $callback($tile, ['status' => 'done', 'image_url' => 'https://cdn/first.png'])->assertOk();
    $tile->update([
        'status' => KvResizeExportStatus::Pending,
        'metadata' => ['pending_region_edit' => true, 'pending_region_edit_prompt' => 'x'],
    ]);

    $this->postJson("/api/v1/studio/files/{$this->file->id}/resize-exports/{$tile->id}/cancel")
        ->assertOk()
        ->assertJsonPath('data.status', 'done')
        ->assertJsonPath('data.image_url', 'https://cdn/first.png');

    expect($tile->fresh()->metadata)->not->toHaveKey('pending_region_edit');
});

it('ignores a render callback that lands after a cancel', function () use ($callback) {
    $tile = ($this->tile)(['status' => KvResizeExportStatus::Generating]);
    $callback($tile, ['status' => 'done', 'image_url' => 'https://cdn/first.png'])->assertOk();
    $tile->update(['status' => KvResizeExportStatus::Pending]);

    $this->postJson("/api/v1/studio/files/{$this->file->id}/resize-exports/{$tile->id}/cancel")->assertOk();
    $callback($tile, ['status' => 'done', 'image_url' => 'https://cdn/late.png'])->assertOk();

    expect($tile->fresh()->image_url)->toBe('https://cdn/first.png');
    expect($tile->fresh()->versions()->count())->toBe(1);
});

it('deletes a tile whose first render is cancelled', function () {
    $tile = ($this->tile)(['status' => KvResizeExportStatus::Pending]);

    $this->postJson("/api/v1/studio/files/{$this->file->id}/resize-exports/{$tile->id}/cancel")
        ->assertNoContent();

    expect(KvResizeExport::withTrashed()->find($tile->id))->toBeNull();
});

it('refuses to cancel another file\'s tile', function () {
    $other = KvResizeExport::factory()->create();
    $this->postJson("/api/v1/studio/files/{$this->file->id}/resize-exports/{$other->id}/cancel")
        ->assertNotFound();
});
```

- [ ] **Step 2: Run — expect FAIL** (404 route).

- [ ] **Step 3: Implement**

Service:

```php
    /**
     * Stop a render. A tile that already has a version goes back to it
     * (status done, image untouched); a late callback is then ignored because
     * the callback only acts on pending/generating rows. A tile with no version
     * yet is a first render — deleting it is the only way back, as before.
     */
    public function cancel(KvResizeExport $row): ?KvResizeExport
    {
        if ($row->current_version_id === null) {
            $row->forceDelete();

            return null;
        }

        $row->update([
            'status' => KvResizeExportStatus::Done,
            'error_message' => null,
            'metadata' => $this->withoutPendingRegionEdit($row),
        ]);

        return $row->refresh();
    }
```

Controller:

```php
    public function cancel(Request $request, string $fileId, string $exportId): JsonResponse|Response
    {
        $file = StudioFile::findOrFail($fileId);
        abort_unless($file->workspace_id === $request->user()->current_workspace_id, 403);

        $export = KvResizeExport::findOrFail($exportId);
        abort_unless($export->studio_file_id === $file->id, 404);

        $row = $this->service->cancel($export);

        if ($row === null) {
            return response()->noContent();
        }

        return response()->json([
            'data' => (new KvResizeExportResource($row))->resolve(),
        ]);
    }
```

Route, next to `destroy` (no `check.credits`):

```php
                            // No check.credits: cancelling calls no model.
                            Route::post(
                                'files/{file}/resize-exports/{export}/cancel',
                                [KvResizeExportController::class, 'cancel'],
                            );
```

- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Commit** — `git commit -m "feat(api): cancel a tile render back to its last version"`

---

### Task 5: List + restore endpoints, resource fields

**Files:**
- Create: `app/Http/Resources/Studio/KvResizeExportVersionResource.php`
- Modify: `KvResizeExportVersionService.php` (+`restore`), `KvResizeExportController.php` (+`versions`, +`restoreVersion`, `withCount('versions')` on the index and stream queries), `KvResizeExportResource.php`, `routes/api.php`
- Test: `tests/Feature/Studio/KvResizeExportVersionTest.php`

**Interfaces:**
- Produces: `KvResizeExportVersionService::restore(KvResizeExport $row, KvResizeExportVersion $source, ?string $userId): KvResizeExportVersion` (throws `\DomainException` when the tile is pending/generating). Resource keys `current_version_id`, `version_count`.

- [ ] **Step 1: Failing tests**

```php
it('lists versions newest first with labels', function () use ($callback) {
    $tile = ($this->tile)(['status' => KvResizeExportStatus::Generating]);
    $callback($tile, ['status' => 'done', 'image_url' => 'https://cdn/1.png'])->assertOk();
    $tile->update(['status' => KvResizeExportStatus::Pending, 'additional_prompt' => 'warmer']);
    $callback($tile, ['status' => 'done', 'image_url' => 'https://cdn/2.png'])->assertOk();

    $this->getJson("/api/v1/studio/files/{$this->file->id}/resize-exports/{$tile->id}/versions")
        ->assertOk()
        ->assertJsonPath('data.0.version_number', 2)
        ->assertJsonPath('data.0.kind', 'regenerate')
        ->assertJsonPath('data.0.prompt', 'warmer')
        ->assertJsonPath('data.1.version_number', 1)
        ->assertJsonPath('data.1.kind', 'create')
        ->assertJsonPath('data.1.image_url', 'https://cdn/1.png')
        ->assertJsonPath('data.0.created_by_name', $this->user->name);
});

it('restores a version by appending a copy and making it current', function () use ($callback) {
    $tile = ($this->tile)(['status' => KvResizeExportStatus::Generating]);
    $callback($tile, ['status' => 'done', 'image_url' => 'https://cdn/1.png'])->assertOk();
    $v1 = $tile->fresh()->currentVersion;
    $tile->update(['status' => KvResizeExportStatus::Pending]);
    $callback($tile, ['status' => 'done', 'image_url' => 'https://cdn/2.png'])->assertOk();
    $tile->update(['overlays' => [['id' => 'ov_1']]]);

    $this->postJson("/api/v1/studio/files/{$this->file->id}/resize-exports/{$tile->id}/versions/{$v1->id}/restore")
        ->assertOk()
        ->assertJsonPath('data.image_url', 'https://cdn/1.png')
        ->assertJsonPath('data.version_count', 3);

    $fresh = $tile->fresh();
    expect($fresh->currentVersion->kind)->toBe('restore');
    expect($fresh->currentVersion->restored_from_version_id)->toBe($v1->id);
    expect($fresh->currentVersion->created_by)->toBe($this->user->id);
    expect($fresh->overlays)->toBe([['id' => 'ov_1']]);

    $this->getJson("/api/v1/studio/files/{$this->file->id}/resize-exports/{$tile->id}/versions")
        ->assertJsonPath('data.0.restored_from_version_number', 1);
});

it('refuses to restore while the tile is rendering', function () use ($callback) {
    $tile = ($this->tile)(['status' => KvResizeExportStatus::Generating]);
    $callback($tile, ['status' => 'done', 'image_url' => 'https://cdn/1.png'])->assertOk();
    $v1 = $tile->fresh()->currentVersion;
    $tile->update(['status' => KvResizeExportStatus::Pending]);

    $this->postJson("/api/v1/studio/files/{$this->file->id}/resize-exports/{$tile->id}/versions/{$v1->id}/restore")
        ->assertStatus(409);
    expect($tile->fresh()->versions()->count())->toBe(1);
});

it('404s a version that belongs to another tile', function () use ($callback) {
    $a = ($this->tile)(['status' => KvResizeExportStatus::Generating, 'platform_id' => 'instagram-post']);
    $b = ($this->tile)(['status' => KvResizeExportStatus::Generating, 'platform_id' => 'instagram-story']);
    $callback($b, ['status' => 'done', 'image_url' => 'https://cdn/b.png'])->assertOk();
    $callback($a, ['status' => 'done', 'image_url' => 'https://cdn/a.png'])->assertOk();

    $this->postJson("/api/v1/studio/files/{$this->file->id}/resize-exports/{$a->id}/versions/{$b->fresh()->current_version_id}/restore")
        ->assertNotFound();
});

it('exposes current_version_id and version_count on the tile list', function () use ($callback) {
    $tile = ($this->tile)(['status' => KvResizeExportStatus::Generating]);
    $callback($tile, ['status' => 'done', 'image_url' => 'https://cdn/1.png'])->assertOk();

    $this->getJson("/api/v1/studio/files/{$this->file->id}/resize-exports?parent_generation_id={$this->generation->id}")
        ->assertOk()
        ->assertJsonPath('data.0.current_version_id', $tile->fresh()->current_version_id)
        ->assertJsonPath('data.0.version_count', 1);
});
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement**

Service `restore`:

```php
    public function restore(KvResizeExport $row, KvResizeExportVersion $source, ?string $userId): KvResizeExportVersion
    {
        if (in_array($row->status, [KvResizeExportStatus::Pending, KvResizeExportStatus::Generating], true)) {
            throw new \DomainException('This tile is still rendering — wait for it to finish, then restore.');
        }

        return $this->append($row, $source->image_url, 'restore', null, $source->id, $userId);
    }
```
(import `App\Enums\KvResizeExportStatus`).

`KvResizeExportVersionResource`:

```php
<?php

namespace App\Http\Resources\Studio;

use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

class KvResizeExportVersionResource extends JsonResource
{
    public function toArray(Request $request): array
    {
        return [
            'id' => $this->id,
            'version_number' => $this->version_number,
            'image_url' => $this->image_url,
            'kind' => $this->kind,
            'prompt' => $this->prompt,
            'model' => $this->model,
            'restored_from_version_number' => $this->restoredFrom?->version_number,
            'created_by_name' => $this->creator?->name,
            'created_at' => $this->created_at?->toIso8601String(),
        ];
    }
}
```

Controller:

```php
    public function versions(Request $request, string $fileId, string $exportId): JsonResponse
    {
        [$file, $export] = $this->fileAndExport($request, $fileId, $exportId);

        $rows = $export->versions()->with(['restoredFrom:id,version_number', 'creator:id,name'])->limit(100)->get();

        return response()->json([
            'data' => KvResizeExportVersionResource::collection($rows)->resolve(),
        ]);
    }

    public function restoreVersion(Request $request, string $fileId, string $exportId, string $versionId): JsonResponse
    {
        [$file, $export] = $this->fileAndExport($request, $fileId, $exportId);

        $source = KvResizeExportVersion::where('kv_resize_export_id', $export->id)->findOrFail($versionId);

        try {
            $this->versions->restore($export, $source, $request->user()->id);
        } catch (\DomainException $e) {
            return response()->json(['message' => $e->getMessage()], Response::HTTP_CONFLICT);
        }

        return response()->json([
            'data' => (new KvResizeExportResource($export->fresh()->loadCount('versions')))->resolve(),
        ]);
    }

    /** @return array{0: StudioFile, 1: KvResizeExport} */
    private function fileAndExport(Request $request, string $fileId, string $exportId): array
    {
        $file = StudioFile::findOrFail($fileId);
        abort_unless($file->workspace_id === $request->user()->current_workspace_id, 403);

        $export = KvResizeExport::findOrFail($exportId);
        abort_unless($export->studio_file_id === $file->id, 404);

        return [$file, $export];
    }
```
Inject `private KvResizeExportVersionService $versions` in the constructor; import `KvResizeExportVersion`, `KvResizeExportVersionResource`, `KvResizeExportVersionService`. Add `->withCount('versions')` to the `index` query (before `->orderBy('created_at')`) and to the query the `stream` method builds per tick (the one feeding `new KvResizeExportResource($row)` at ≈457).

Resource: after `'image_url' => $this->image_url,` add

```php
            'current_version_id' => $this->current_version_id,
            // withCount on list/stream reads; single-row responses count once.
            'version_count' => $this->versions_count ?? $this->resource->versions()->count(),
```

Routes (after `cancel`):

```php
                            Route::get(
                                'files/{file}/resize-exports/{export}/versions',
                                [KvResizeExportController::class, 'versions'],
                            );
                            // No check.credits: a restore re-points the tile
                            // at an image it already had; no model call.
                            Route::post(
                                'files/{file}/resize-exports/{export}/versions/{version}/restore',
                                [KvResizeExportController::class, 'restoreVersion'],
                            );
```

- [ ] **Step 4: Run** the version test file + `KvResizeExportControllerTest.php` + `KvResizeExportStreamTest.php` — expect PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(api): list and restore tile versions; resource carries current_version_id + version_count"`

---

### Task 6: Separate layers onto a tile appends a version

**Files:**
- Modify: `app/Services/Studio/KvLayerDecompositionService.php` (`commitToResizeExport` ≈343-356)
- Test: `tests/Feature/Studio/KvResizeExportVersionTest.php`

- [ ] **Step 1: Failing test** — find the existing test that exercises `commitToResizeExport` (`grep -rln "commitToResizeExport\|committed_resize_export_id" tests/`) and copy its arrangement (decomposition factory + layer rows + fake flatten) into a new test in the version test file that asserts, after the commit:

```php
    $fresh = $tile->fresh();
    expect($fresh->currentVersion->kind)->toBe('separate');
    expect($fresh->image_url)->toBe($fresh->currentVersion->image_url);
```
If that arrangement needs Storage/HTTP fakes the copied test sets up, copy those too. Ledger a Ruling naming the source test you copied from.

- [ ] **Step 2: Run — expect FAIL** (no version).
- [ ] **Step 3: Implement** — inside the existing `DB::transaction`, replace

```php
            $export->forceFill([
                'image_url' => $flattenedUrl,
                'overlays' => $overlays,
            ])->save();
```
with

```php
            $export->forceFill(['overlays' => $overlays])->save();
            // The flattened plate is a new image for the tile: record it as a
            // version (spec 2026-09-24) — append() also moves image_url.
            $this->versions->append($export, $flattenedUrl, 'separate', null, null, $export->created_by);
```
and inject `KvResizeExportVersionService $versions` into the service constructor.

- [ ] **Step 4: Run** the version test file + the decomposition test file you copied from — expect PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(api): separate-layers commit records a tile version"`

---

### Task 7: Upscales follow the current version

**Files:**
- Create: `database/migrations/2026_09_24_100100_add_version_to_kv_resize_export_upscales.php`
- Modify: `app/Models/KvResizeExportUpscale.php` (fillable + `scopeForCurrentVersionOf`), `app/Services/Studio/KvResizeExportUpscaleService.php` (`getOrCreate`), `app/Http/Controllers/Api/Studio/KvResizeExportUpscaleController.php` (every `KvResizeExportUpscale::where('kv_resize_export_id', $tile->id)` — lines ≈26, 60, 152, 168)
- Test: `tests/Feature/Studio/KvResizeExportVersionTest.php`

**Interfaces:**
- Produces: `KvResizeExportUpscale::scopeForCurrentVersionOf(Builder $q, KvResizeExport $tile)` — `where kv_resize_export_id = tile.id` AND (`kv_resize_export_version_id = tile.current_version_id`, or `whereNull` when the tile has none).

- [ ] **Step 1: Failing test**

```php
it('scopes upscales to the tile\'s current version', function () use ($callback) {
    $tile = ($this->tile)(['status' => KvResizeExportStatus::Generating]);
    $callback($tile, ['status' => 'done', 'image_url' => 'https://cdn/1.png'])->assertOk();
    $v1 = $tile->fresh()->current_version_id;

    \App\Models\KvResizeExportUpscale::factory()->create([
        'kv_resize_export_id' => $tile->id,
        'studio_file_id' => $this->file->id,
        'kv_resize_export_version_id' => $v1,
        'target' => '2k',
        'status' => \App\Enums\KvResizeExportUpscaleStatus::Done,
        'image_url' => 'https://cdn/1-2k.png',
    ]);

    $tile->update(['status' => KvResizeExportStatus::Pending]);
    $callback($tile, ['status' => 'done', 'image_url' => 'https://cdn/2.png'])->assertOk();

    $scoped = \App\Models\KvResizeExportUpscale::forCurrentVersionOf($tile->fresh())->get();
    expect($scoped)->toHaveCount(0);

    $this->getJson("/api/v1/studio/kv-generator/files/{$this->file->id}/resize-exports/{$tile->id}/upscales")
        ->assertOk()
        ->assertJsonCount(0, 'data');
});
```
(Before running, open `KvResizeExportUpscaleController::index` and confirm the list response is `{data: [...]}`; adjust `assertJsonCount` path if not.)

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement**

Migration:

```php
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * An upscale is of ONE image: after a regenerate the tile's old upscale
     * must stop answering for the new pixels (spec 2026-09-24). The unique
     * key moves from (tile, target) to (version, target). Legacy rows get
     * their version in the backfill migration.
     */
    public function up(): void
    {
        Schema::table('kv_resize_export_upscales', function (Blueprint $t) {
            $t->ulid('kv_resize_export_version_id')->nullable()->after('kv_resize_export_id');
            $t->foreign('kv_resize_export_version_id')
                ->references('id')->on('kv_resize_export_versions')
                ->cascadeOnDelete();
            $t->dropUnique('kv_resize_export_upscales_export_target_unique');
            $t->unique(['kv_resize_export_version_id', 'target'], 'kv_resize_export_upscales_version_target_unique');
        });
    }

    public function down(): void
    {
        Schema::table('kv_resize_export_upscales', function (Blueprint $t) {
            $t->dropUnique('kv_resize_export_upscales_version_target_unique');
            $t->dropForeign(['kv_resize_export_version_id']);
            $t->dropColumn('kv_resize_export_version_id');
            $t->unique(['kv_resize_export_id', 'target'], 'kv_resize_export_upscales_export_target_unique');
        });
    }
};
```

Model: add `'kv_resize_export_version_id'` to `$fillable` and

```php
    public function scopeForCurrentVersionOf(Builder $q, KvResizeExport $tile): Builder
    {
        $q->where('kv_resize_export_id', $tile->id);

        return $tile->current_version_id === null
            ? $q->whereNull('kv_resize_export_version_id')
            : $q->where('kv_resize_export_version_id', $tile->current_version_id);
    }
```
(import `Illuminate\Database\Eloquent\Builder`).

Service `getOrCreate`: replace `KvResizeExportUpscale::where('kv_resize_export_id', $tile->id)` with `KvResizeExportUpscale::forCurrentVersionOf($tile)`, and add `'kv_resize_export_version_id' => $tile->current_version_id,` to the `create([...])`.

Controller: replace each `KvResizeExportUpscale::where('kv_resize_export_id', $tile->id)` with `KvResizeExportUpscale::forCurrentVersionOf($tile)`.

- [ ] **Step 4: Run** the version test file + `tests/Feature/Studio/KvResizeExportUpscaleInternalCallbackTest.php` + any `tests/Feature/Studio/*Upscale*` file that covers the resize-tile upscale controller (`ls tests/Feature/Studio | grep -i upscale`) — expect PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(api): tile upscales are scoped to the current version"`

---

### Task 8: Backfill existing tiles

**Files:**
- Modify: `KvResizeExportVersionService.php` (+`backfill(): int`)
- Create: `database/migrations/2026_09_24_100200_backfill_kv_resize_export_versions.php`
- Test: `tests/Feature/Studio/KvResizeExportVersionTest.php`

**Interfaces:**
- Produces: `KvResizeExportVersionService::backfill(): int` — idempotent: for every non-deleted export with `image_url` not null and `current_version_id` null, insert v1 `create` (`created_at` = export `updated_at`, `created_by` = export `created_by`, `model` = export `model`) and set `current_version_id`; then set `kv_resize_export_version_id` on that tile's upscales that have none. Returns the number of tiles backfilled.

- [ ] **Step 1: Failing test**

```php
it('backfills v1 for tiles that already have an image, once', function () {
    $withImage = ($this->tile)(['status' => KvResizeExportStatus::Done, 'image_url' => 'https://cdn/old.png', 'platform_id' => 'instagram-post']);
    $noImage = ($this->tile)(['status' => KvResizeExportStatus::Failed, 'image_url' => null, 'platform_id' => 'instagram-story']);
    $up = \App\Models\KvResizeExportUpscale::factory()->create([
        'kv_resize_export_id' => $withImage->id,
        'studio_file_id' => $this->file->id,
        'target' => '2k',
    ]);

    $svc = app(KvResizeExportVersionService::class);
    expect($svc->backfill())->toBe(1);
    expect($svc->backfill())->toBe(0);

    $v = $withImage->fresh()->currentVersion;
    expect($v->version_number)->toBe(1);
    expect($v->kind)->toBe('create');
    expect($v->image_url)->toBe('https://cdn/old.png');
    expect($noImage->fresh()->current_version_id)->toBeNull();
    expect($up->fresh()->kv_resize_export_version_id)->toBe($v->id);
});
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement**

```php
    /**
     * One-time (and re-runnable) seed of v1 for tiles that existed before
     * version history. History before this point is unrecoverable — the S3
     * files exist, but nothing records which render they belonged to.
     */
    public function backfill(): int
    {
        $count = 0;

        KvResizeExport::query()
            ->whereNotNull('image_url')
            ->whereNull('current_version_id')
            ->orderBy('id')
            ->chunkById(200, function ($rows) use (&$count) {
                foreach ($rows as $row) {
                    DB::transaction(function () use ($row) {
                        $version = KvResizeExportVersion::create([
                            'kv_resize_export_id' => $row->id,
                            'studio_file_id' => $row->studio_file_id,
                            'version_number' => 1,
                            'image_url' => $row->image_url,
                            'kind' => 'create',
                            'model' => $row->model,
                            'created_by' => $row->created_by,
                            'created_at' => $row->updated_at ?? now(),
                        ]);
                        $row->forceFill(['current_version_id' => $version->id])->saveQuietly();
                        KvResizeExportUpscale::where('kv_resize_export_id', $row->id)
                            ->whereNull('kv_resize_export_version_id')
                            ->update(['kv_resize_export_version_id' => $version->id]);
                    });
                    $count++;
                }
            });

        return $count;
    }
```
(`saveQuietly` + `forceFill` so `updated_at` is not bumped and no observers fire; import `KvResizeExportUpscale`. `KvResizeExport` uses SoftDeletes, so trashed rows are excluded by the default scope.)

Migration:

```php
<?php

use App\Services\Studio\KvResizeExportVersionService;
use Illuminate\Database\Migrations\Migration;

return new class extends Migration
{
    public function up(): void
    {
        app(KvResizeExportVersionService::class)->backfill();
    }

    public function down(): void
    {
        // Versions are dropped with their table by the create migration's down().
    }
};
```

- [ ] **Step 4: Run — expect PASS.** Then run the migration against the scratch DB once more from scratch to prove the three migrations chain: `DB_CONNECTION=pgsql DB_DATABASE=frnd_region_edit_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false php artisan migrate:fresh --force` → exit 0.
- [ ] **Step 5: Commit** — `git commit -m "feat(api): backfill v1 for existing resize tiles"`

---

### Task 9: Full resize suite + push

- [ ] **Step 1:** Run every resize test file explicitly:

```
test ! -e bootstrap/cache/config.php && DB_CONNECTION=pgsql DB_DATABASE=frnd_region_edit_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false php artisan test --compact tests/Feature/Studio/KvResizeExportVersionTest.php tests/Feature/Studio/KvResizeExportControllerTest.php tests/Feature/Studio/KvResizeExportDuplicateTest.php tests/Feature/Studio/KvResizeExportInternalCallbackTest.php tests/Feature/Studio/KvResizeExportRenameTest.php tests/Feature/Studio/KvResizeExportStreamTest.php tests/Feature/Studio/KvResizeExportUpscaleInternalCallbackTest.php tests/Feature/Studio/KvResizeExportZipTest.php tests/Feature/Studio/KvResizeObjectDetectTest.php tests/Feature/Studio/KvResizeRegionEditTest.php
```
Expected: all pass (compare against a baseline run of the same files at `develop` in a temporary worktree if anything fails, to separate pre-existing reds).

- [ ] **Step 2:** `vendor/bin/pint --dirty` (format only the touched files); commit if it changed anything.
- [ ] **Step 3:** `git push -u origin feature/daffa/vc-kv-craft-resize-strip`.
- [ ] **Step 4:** Tell Daffa to run `php artisan migrate` on the dev DB (with `TELESCOPE_ENABLED=false`) before testing the web side.
