# Studio Projects & KV Generator — API (Laravel) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the data model (rename + new tables) and all backend endpoints to support Studio Projects (folders), the renamed studio_files (KV/image/resize outputs), and the KV Generator lifecycle including a signed internal callback from ai-service.

**Architecture:** Seven sequential migrations; new Eloquent models with existing workspace/brand scoping patterns; REST controllers grouped under `Api\Studio\*`; chat stream handler extended to recognize `thread_type='kv_generator'` and forward launch context + mode to ai-service.

**Tech Stack:** Laravel 13, PHP 8.5, PostgreSQL, ULID IDs, Pest/PHPUnit for feature tests, Sanctum + JWT for auth, existing internal-request signing pattern.

**Spec reference:** [docs/superpowers/specs/2026-04-23-studio-projects-kv-generator-design.md](docs/superpowers/specs/2026-04-23-studio-projects-kv-generator-design.md)

---

## File Structure

**Migrations (create):**
- `api/database/migrations/<ts>_rename_studio_projects_to_studio_files.php`
- `api/database/migrations/<ts>_add_project_and_thread_to_studio_files.php`
- `api/database/migrations/<ts>_create_studio_projects_folder_table.php`
- `api/database/migrations/<ts>_update_studio_activities_file_and_project.php`
- `api/database/migrations/<ts>_create_kv_generations_table.php`

**Models (create/modify):**
- Modify: `api/app/Models/StudioProject.php` → rename class + table to `StudioFile`, path `api/app/Models/StudioFile.php`
- Create: `api/app/Models/StudioProject.php` (folder)
- Modify: `api/app/Models/StudioActivity.php` (rename `project_id` accessor to `file_id`, add new `project_id`)
- Create: `api/app/Models/KvGeneration.php`
- Modify: `api/app/Enums/ThreadType.php` (add KvGenerator case)

**Resources (create/modify):**
- Modify rename: `api/app/Http/Resources/Studio/StudioProjectResource.php` → `StudioFileResource.php`
- Create: `api/app/Http/Resources/Studio/StudioProjectResource.php` (folder)
- Create: `api/app/Http/Resources/Studio/KvGenerationResource.php`

**Controllers (create/modify):**
- Modify: `api/app/Http/Controllers/Api/Studio/StudioProjectController.php` → split into `StudioFileController` (existing logic) + new `StudioProjectController` (folder)
- Create: `api/app/Http/Controllers/Api/Studio/KvGeneratorFileController.php`
- Create: `api/app/Http/Controllers/Api/Internal/KvGenerationCallbackController.php`

**Form Requests (create):**
- `api/app/Http/Requests/Studio/StoreStudioProjectRequest.php`
- `api/app/Http/Requests/Studio/UpdateStudioProjectRequest.php`
- `api/app/Http/Requests/Studio/MoveStudioFileRequest.php`
- `api/app/Http/Requests/Studio/CreateKvGeneratorFileRequest.php`
- `api/app/Http/Requests/Internal/KvGenerationCompleteRequest.php`

**Services (create):**
- `api/app/Services/Studio/StudioProjectService.php` (create, soft-delete with file orphaning, etc.)
- `api/app/Services/Studio/KvGenerationService.php` (persist callback row, bump file thumbnail)

**Chat extension (modify):**
- `api/app/Http/Requests/StreamChatRequest.php` (accept `mode`, extended `launch_context`)
- `api/app/Services/ChatService.php` (forward KV launch context + mode to ai-service)

**Routes (modify):**
- `api/routes/api.php` (new routes under `/api/studio/*` and `/api/internal/kv-generator/*`)

**Tests (create):**
- `api/tests/Feature/Studio/StudioProjectCrudTest.php`
- `api/tests/Feature/Studio/StudioFileMoveTest.php`
- `api/tests/Feature/Studio/StudioFileSoftDeleteTest.php`
- `api/tests/Feature/Studio/KvGeneratorFileLifecycleTest.php`
- `api/tests/Feature/Internal/KvGenerationCallbackTest.php`
- `api/tests/Feature/Studio/SoftDeleteProjectOrphansFilesTest.php`

---

## Task 1 — Migration A: rename `studio_projects` → `studio_files`

**Files:**
- Create: `api/database/migrations/2026_04_23_100000_rename_studio_projects_to_studio_files.php`

- [ ] **Step 1: Write the failing test**

File: `api/tests/Feature/Studio/RenameStudioProjectsMigrationTest.php`

```php
<?php

use Illuminate\Support\Facades\Schema;

it('has the studio_files table after migrations', function () {
    expect(Schema::hasTable('studio_files'))->toBeTrue();
    expect(Schema::hasTable('studio_projects'))->toBeFalse();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `php artisan test --filter=RenameStudioProjectsMigrationTest`
Expected: FAIL — studio_files table not found.

- [ ] **Step 3: Write the migration**

File: `api/database/migrations/2026_04_23_100000_rename_studio_projects_to_studio_files.php`

```php
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::rename('studio_projects', 'studio_files');
    }

    public function down(): void
    {
        Schema::rename('studio_files', 'studio_projects');
    }
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `php artisan migrate:fresh --env=testing && php artisan test --filter=RenameStudioProjectsMigrationTest`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add api/database/migrations/2026_04_23_100000_rename_studio_projects_to_studio_files.php \
       api/tests/Feature/Studio/RenameStudioProjectsMigrationTest.php
git commit -m "feat(api): rename studio_projects to studio_files

studio_projects is repurposed to become the folder entity.
The existing records (per-tool file rows) are renamed to studio_files."
```

---

## Task 2 — Migration B: add `project_id` + `thread_id` to `studio_files`

**Files:**
- Create: `api/database/migrations/2026_04_23_100010_add_project_and_thread_to_studio_files.php`

- [ ] **Step 1: Write the failing test**

File: `api/tests/Feature/Studio/StudioFilesFkColumnsTest.php`

```php
<?php

use Illuminate\Support\Facades\Schema;

it('has nullable project_id and thread_id on studio_files', function () {
    expect(Schema::hasColumn('studio_files', 'project_id'))->toBeTrue();
    expect(Schema::hasColumn('studio_files', 'thread_id'))->toBeTrue();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `php artisan test --filter=StudioFilesFkColumnsTest`
Expected: FAIL — columns missing.

- [ ] **Step 3: Write the migration**

File: `api/database/migrations/2026_04_23_100010_add_project_and_thread_to_studio_files.php`

```php
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('studio_files', function (Blueprint $table) {
            $table->foreignUlid('project_id')->nullable()->after('workspace_id');
            $table->foreignUlid('thread_id')->nullable()->after('project_id');

            $table->index(['project_id', 'last_edited_at']);
        });
    }

    public function down(): void
    {
        Schema::table('studio_files', function (Blueprint $table) {
            $table->dropIndex(['project_id', 'last_edited_at']);
            $table->dropColumn(['project_id', 'thread_id']);
        });
    }
};
```

Note: foreign key constraints for `project_id` and `thread_id` are added in Task 3 (after the `studio_projects` folder table exists) and Task 6 (chat extension). We add columns first, constraints after.

- [ ] **Step 4: Run test to verify it passes**

Run: `php artisan migrate:fresh --env=testing && php artisan test --filter=StudioFilesFkColumnsTest`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add api/database/migrations/2026_04_23_100010_add_project_and_thread_to_studio_files.php \
       api/tests/Feature/Studio/StudioFilesFkColumnsTest.php
git commit -m "feat(api): add project_id and thread_id columns to studio_files"
```

---

## Task 3 — Migration C: create `studio_projects` (folder entity)

**Files:**
- Create: `api/database/migrations/2026_04_23_100020_create_studio_projects_folder_table.php`

- [ ] **Step 1: Write the failing test**

File: `api/tests/Feature/Studio/StudioProjectsFolderSchemaTest.php`

```php
<?php

use Illuminate\Support\Facades\Schema;

it('creates studio_projects folder table with required columns', function () {
    expect(Schema::hasTable('studio_projects'))->toBeTrue();

    foreach (['id','workspace_id','brand_id','created_by','last_edited_by',
              'name','description','use_brand_knowledge','thumbnail_url',
              'last_edited_at','created_at','updated_at','deleted_at'] as $col) {
        expect(Schema::hasColumn('studio_projects', $col))->toBeTrue("missing column: {$col}");
    }
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `php artisan test --filter=StudioProjectsFolderSchemaTest`
Expected: FAIL — table doesn't exist yet.

- [ ] **Step 3: Write the migration**

File: `api/database/migrations/2026_04_23_100020_create_studio_projects_folder_table.php`

```php
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('studio_projects', function (Blueprint $table) {
            $table->ulid('id')->primary();
            $table->foreignUlid('workspace_id')->constrained('workspaces')->cascadeOnDelete();
            $table->foreignUlid('brand_id')->constrained('brands')->cascadeOnDelete();
            $table->foreignUlid('created_by')->constrained('users')->cascadeOnDelete();
            $table->foreignUlid('last_edited_by')->constrained('users')->cascadeOnDelete();
            $table->string('name');
            $table->text('description')->nullable();
            $table->boolean('use_brand_knowledge')->default(false);
            $table->string('thumbnail_url')->nullable();
            $table->timestamp('last_edited_at')->useCurrent();
            $table->timestamps();
            $table->softDeletes();

            $table->index(['workspace_id', 'brand_id', 'last_edited_at']);
            $table->index(['workspace_id', 'created_by', 'last_edited_at']);
        });

        // Now add the FK from studio_files.project_id → studio_projects.id
        Schema::table('studio_files', function (Blueprint $table) {
            $table->foreign('project_id')
                ->references('id')->on('studio_projects')
                ->nullOnDelete();
        });
    }

    public function down(): void
    {
        Schema::table('studio_files', function (Blueprint $table) {
            $table->dropForeign(['project_id']);
        });
        Schema::dropIfExists('studio_projects');
    }
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `php artisan migrate:fresh --env=testing && php artisan test --filter=StudioProjectsFolderSchemaTest`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add api/database/migrations/2026_04_23_100020_create_studio_projects_folder_table.php \
       api/tests/Feature/Studio/StudioProjectsFolderSchemaTest.php
git commit -m "feat(api): create studio_projects folder table with files FK"
```

---

## Task 4 — Migration D: update `studio_activities` (rename project_id → file_id, add new project_id)

**Files:**
- Create: `api/database/migrations/2026_04_23_100030_update_studio_activities_file_and_project.php`

- [ ] **Step 1: Write the failing test**

File: `api/tests/Feature/Studio/StudioActivitiesColumnsTest.php`

```php
<?php

use Illuminate\Support\Facades\Schema;

it('has file_id and project_id columns on studio_activities', function () {
    expect(Schema::hasColumn('studio_activities', 'file_id'))->toBeTrue();
    expect(Schema::hasColumn('studio_activities', 'project_id'))->toBeTrue();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `php artisan test --filter=StudioActivitiesColumnsTest`
Expected: FAIL — file_id doesn't exist.

- [ ] **Step 3: Write the migration**

File: `api/database/migrations/2026_04_23_100030_update_studio_activities_file_and_project.php`

```php
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('studio_activities', function (Blueprint $table) {
            // Drop old FK and rename column
            $table->dropForeign(['project_id']);
            $table->renameColumn('project_id', 'file_id');
        });

        Schema::table('studio_activities', function (Blueprint $table) {
            // Re-add FK under new name → studio_files
            $table->foreign('file_id')
                ->references('id')->on('studio_files')
                ->nullOnDelete();

            // Add new project_id pointing to the folder table
            $table->foreignUlid('project_id')
                ->nullable()
                ->after('file_id')
                ->constrained('studio_projects')
                ->nullOnDelete();
        });
    }

    public function down(): void
    {
        Schema::table('studio_activities', function (Blueprint $table) {
            $table->dropForeign(['project_id']);
            $table->dropColumn('project_id');

            $table->dropForeign(['file_id']);
            $table->renameColumn('file_id', 'project_id');
        });

        Schema::table('studio_activities', function (Blueprint $table) {
            $table->foreign('project_id')
                ->references('id')->on('studio_files')
                ->nullOnDelete();
        });
    }
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `php artisan migrate:fresh --env=testing && php artisan test --filter=StudioActivitiesColumnsTest`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add api/database/migrations/2026_04_23_100030_update_studio_activities_file_and_project.php \
       api/tests/Feature/Studio/StudioActivitiesColumnsTest.php
git commit -m "feat(api): rename studio_activities.project_id to file_id, add new project_id"
```

---

## Task 5 — Migration E: create `kv_generations` table

**Files:**
- Create: `api/database/migrations/2026_04_23_100040_create_kv_generations_table.php`

- [ ] **Step 1: Write the failing test**

File: `api/tests/Feature/Studio/KvGenerationsSchemaTest.php`

```php
<?php

use Illuminate\Support\Facades\Schema;

it('creates kv_generations table with required columns', function () {
    expect(Schema::hasTable('kv_generations'))->toBeTrue();

    foreach (['id','studio_file_id','parent_generation_id','chat_message_id',
              'version_number','image_url','thumbnail_url','prompt_snapshot',
              'model','ai_service_run_id','metadata','created_at','created_by'] as $col) {
        expect(Schema::hasColumn('kv_generations', $col))->toBeTrue("missing column: {$col}");
    }
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `php artisan test --filter=KvGenerationsSchemaTest`
Expected: FAIL — table doesn't exist.

- [ ] **Step 3: Write the migration**

File: `api/database/migrations/2026_04_23_100040_create_kv_generations_table.php`

```php
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('kv_generations', function (Blueprint $table) {
            $table->ulid('id')->primary();
            $table->foreignUlid('studio_file_id')->constrained('studio_files')->cascadeOnDelete();
            $table->foreignUlid('parent_generation_id')->nullable();
            $table->foreignUlid('chat_message_id')->nullable();
            $table->unsignedInteger('version_number');
            $table->string('image_url');
            $table->string('thumbnail_url')->nullable();
            $table->text('prompt_snapshot');
            $table->string('model');
            $table->string('ai_service_run_id')->nullable();
            $table->jsonb('metadata')->nullable();
            $table->timestamp('created_at')->useCurrent();
            $table->foreignUlid('created_by')->constrained('users')->cascadeOnDelete();

            $table->foreign('parent_generation_id')
                ->references('id')->on('kv_generations')
                ->nullOnDelete();

            $table->foreign('chat_message_id')
                ->references('id')->on('user_chat_histories')
                ->nullOnDelete();

            $table->index(['studio_file_id', 'version_number']);
            $table->index(['studio_file_id', 'created_at']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('kv_generations');
    }
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `php artisan migrate:fresh --env=testing && php artisan test --filter=KvGenerationsSchemaTest`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add api/database/migrations/2026_04_23_100040_create_kv_generations_table.php \
       api/tests/Feature/Studio/KvGenerationsSchemaTest.php
git commit -m "feat(api): create kv_generations table"
```

---

## Task 6 — Enum: add `ThreadType::KvGenerator`

**Files:**
- Modify: `api/app/Enums/ThreadType.php`

- [ ] **Step 1: Write the failing test**

File: `api/tests/Unit/Enums/ThreadTypeTest.php`

```php
<?php

use App\Enums\ThreadType;

it('includes kv_generator case', function () {
    expect(ThreadType::KvGenerator->value)->toBe('kv_generator');
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `php artisan test --filter=ThreadTypeTest`
Expected: FAIL — KvGenerator case not found.

- [ ] **Step 3: Modify the enum**

File: `api/app/Enums/ThreadType.php`

```php
<?php

namespace App\Enums;

enum ThreadType: string
{
    case Chat = 'chat';
    case PointAndAsk = 'point-and-ask';
    case KvGenerator = 'kv_generator';
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `php artisan test --filter=ThreadTypeTest`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add api/app/Enums/ThreadType.php api/tests/Unit/Enums/ThreadTypeTest.php
git commit -m "feat(api): add ThreadType::KvGenerator"
```

---

## Task 7 — Models: rename StudioProject → StudioFile; create new StudioProject (folder)

**Files:**
- Rename: `api/app/Models/StudioProject.php` → `api/app/Models/StudioFile.php`
- Create: `api/app/Models/StudioProject.php` (new — folder)

- [ ] **Step 1: Write the failing test**

File: `api/tests/Feature/Studio/StudioFileModelTest.php`

```php
<?php

use App\Models\StudioFile;
use App\Models\StudioProject;

it('StudioFile maps to studio_files table', function () {
    $file = new StudioFile();
    expect($file->getTable())->toBe('studio_files');
});

it('StudioProject maps to studio_projects table', function () {
    $project = new StudioProject();
    expect($project->getTable())->toBe('studio_projects');
});

it('StudioFile has project and thread relations', function () {
    $file = new StudioFile();
    expect(method_exists($file, 'project'))->toBeTrue();
    expect(method_exists($file, 'thread'))->toBeTrue();
});

it('StudioProject has files relation', function () {
    $project = new StudioProject();
    expect(method_exists($project, 'files'))->toBeTrue();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `php artisan test --filter=StudioFileModelTest`
Expected: FAIL — StudioFile class missing.

- [ ] **Step 3: Rename old model + create new**

**a) Rename file:** `git mv api/app/Models/StudioProject.php api/app/Models/StudioFile.php`

**b) Edit `api/app/Models/StudioFile.php`:**

```php
<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Concerns\HasUlids;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;
use Illuminate\Database\Eloquent\SoftDeletes;

class StudioFile extends Model
{
    use HasFactory, HasUlids, SoftDeletes;

    protected $table = 'studio_files';

    protected $fillable = [
        'workspace_id', 'brand_id', 'tool_id', 'project_id', 'thread_id',
        'created_by', 'last_edited_by', 'name', 'status',
        'thumbnail_url', 'last_edited_at', 'metadata',
    ];

    protected $casts = [
        'metadata' => 'array',
        'last_edited_at' => 'datetime',
    ];

    public function project(): BelongsTo
    {
        return $this->belongsTo(StudioProject::class, 'project_id');
    }

    public function thread(): BelongsTo
    {
        return $this->belongsTo(UserThread::class, 'thread_id');
    }

    public function tool(): BelongsTo
    {
        return $this->belongsTo(Tool::class);
    }

    public function createdBy(): BelongsTo
    {
        return $this->belongsTo(User::class, 'created_by');
    }

    public function lastEditedBy(): BelongsTo
    {
        return $this->belongsTo(User::class, 'last_edited_by');
    }

    public function generations(): HasMany
    {
        return $this->hasMany(KvGeneration::class, 'studio_file_id')->orderBy('version_number', 'desc');
    }
}
```

**c) Create new `api/app/Models/StudioProject.php`:**

```php
<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Concerns\HasUlids;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;
use Illuminate\Database\Eloquent\SoftDeletes;

class StudioProject extends Model
{
    use HasFactory, HasUlids, SoftDeletes;

    protected $table = 'studio_projects';

    protected $fillable = [
        'workspace_id', 'brand_id', 'created_by', 'last_edited_by',
        'name', 'description', 'use_brand_knowledge',
        'thumbnail_url', 'last_edited_at',
    ];

    protected $casts = [
        'use_brand_knowledge' => 'boolean',
        'last_edited_at' => 'datetime',
    ];

    public function files(): HasMany
    {
        return $this->hasMany(StudioFile::class, 'project_id');
    }

    public function brand(): BelongsTo
    {
        return $this->belongsTo(Brand::class);
    }

    public function workspace(): BelongsTo
    {
        return $this->belongsTo(Workspace::class);
    }

    public function createdBy(): BelongsTo
    {
        return $this->belongsTo(User::class, 'created_by');
    }

    public function lastEditedBy(): BelongsTo
    {
        return $this->belongsTo(User::class, 'last_edited_by');
    }
}
```

**d) Update ALL callsites** that previously used `\App\Models\StudioProject` to now use `\App\Models\StudioFile` (the old "file-like" usage). Run:

```bash
grep -rln "App\\\\Models\\\\StudioProject" api/app api/routes api/tests api/database | xargs sed -i '' 's|App\\Models\\StudioProject|App\\Models\\StudioFile|g'
```

Then manually re-point any call that was truly about folders (there shouldn't be any yet — the folder concept is new). Verify with `grep -rn "StudioProject" api/app` and sanity-check each hit.

- [ ] **Step 4: Run test to verify it passes**

Run: `php artisan test --filter=StudioFileModelTest`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add api/app/Models/StudioFile.php api/app/Models/StudioProject.php \
       api/tests/Feature/Studio/StudioFileModelTest.php
git add -u api/app api/routes api/database  # callsite renames
git commit -m "feat(api): split StudioProject into StudioFile (renamed) + StudioProject (folder)"
```

---

## Task 8 — Model: `KvGeneration`

**Files:**
- Create: `api/app/Models/KvGeneration.php`

- [ ] **Step 1: Write the failing test**

File: `api/tests/Feature/Studio/KvGenerationModelTest.php`

```php
<?php

use App\Models\KvGeneration;
use App\Models\StudioFile;

it('KvGeneration belongs to a studio file', function () {
    $gen = new KvGeneration();
    expect(method_exists($gen, 'file'))->toBeTrue();
});

it('KvGeneration has self-reference for variations', function () {
    $gen = new KvGeneration();
    expect(method_exists($gen, 'parent'))->toBeTrue();
    expect(method_exists($gen, 'children'))->toBeTrue();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `php artisan test --filter=KvGenerationModelTest`
Expected: FAIL.

- [ ] **Step 3: Create model**

File: `api/app/Models/KvGeneration.php`

```php
<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Concerns\HasUlids;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;

class KvGeneration extends Model
{
    use HasFactory, HasUlids;

    protected $table = 'kv_generations';
    public $timestamps = false;

    protected $fillable = [
        'studio_file_id', 'parent_generation_id', 'chat_message_id',
        'version_number', 'image_url', 'thumbnail_url',
        'prompt_snapshot', 'model', 'ai_service_run_id', 'metadata',
        'created_at', 'created_by',
    ];

    protected $casts = [
        'metadata' => 'array',
        'version_number' => 'integer',
        'created_at' => 'datetime',
    ];

    public function file(): BelongsTo
    {
        return $this->belongsTo(StudioFile::class, 'studio_file_id');
    }

    public function parent(): BelongsTo
    {
        return $this->belongsTo(self::class, 'parent_generation_id');
    }

    public function children(): HasMany
    {
        return $this->hasMany(self::class, 'parent_generation_id');
    }

    public function createdBy(): BelongsTo
    {
        return $this->belongsTo(User::class, 'created_by');
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `php artisan test --filter=KvGenerationModelTest`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add api/app/Models/KvGeneration.php api/tests/Feature/Studio/KvGenerationModelTest.php
git commit -m "feat(api): add KvGeneration model"
```

---

## Task 9 — Resources (rename + new)

**Files:**
- Rename: `api/app/Http/Resources/Studio/StudioProjectResource.php` → `StudioFileResource.php`
- Create: `api/app/Http/Resources/Studio/StudioProjectResource.php` (new, folder)
- Create: `api/app/Http/Resources/Studio/KvGenerationResource.php`

- [ ] **Step 1: Write the failing test**

File: `api/tests/Feature/Studio/ResourcesTest.php`

```php
<?php

use App\Http\Resources\Studio\KvGenerationResource;
use App\Http\Resources\Studio\StudioFileResource;
use App\Http\Resources\Studio\StudioProjectResource;

it('loads StudioFileResource', function () {
    expect(class_exists(StudioFileResource::class))->toBeTrue();
});
it('loads new StudioProjectResource (folder)', function () {
    expect(class_exists(StudioProjectResource::class))->toBeTrue();
});
it('loads KvGenerationResource', function () {
    expect(class_exists(KvGenerationResource::class))->toBeTrue();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `php artisan test --filter=ResourcesTest`
Expected: FAIL (missing KvGenerationResource + new StudioProjectResource).

- [ ] **Step 3: Rename + create resources**

**a) Rename:** `git mv api/app/Http/Resources/Studio/StudioProjectResource.php api/app/Http/Resources/Studio/StudioFileResource.php`

**b) Edit `StudioFileResource.php`:**

```php
<?php

namespace App\Http\Resources\Studio;

use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

class StudioFileResource extends JsonResource
{
    public function toArray(Request $request): array
    {
        return [
            'id' => $this->id,
            'name' => $this->name,
            'status' => $this->status,
            'thumbnail_url' => $this->thumbnail_url,
            'project_id' => $this->project_id,
            'thread_id' => $this->thread_id,
            'tool' => $this->whenLoaded('tool', fn () => [
                'id' => $this->tool->id,
                'name' => $this->tool->name,
                'slug' => $this->tool->slug,
            ]),
            'last_edited_at' => $this->last_edited_at?->toIso8601String(),
            'last_edited_by' => $this->whenLoaded('lastEditedBy', fn () => [
                'id' => $this->lastEditedBy->id,
                'name' => $this->lastEditedBy->name,
            ]),
            'created_at' => $this->created_at?->toIso8601String(),
        ];
    }
}
```

**c) Create new `StudioProjectResource.php` (folder):**

```php
<?php

namespace App\Http\Resources\Studio;

use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

class StudioProjectResource extends JsonResource
{
    public function toArray(Request $request): array
    {
        return [
            'id' => $this->id,
            'name' => $this->name,
            'description' => $this->description,
            'use_brand_knowledge' => (bool) $this->use_brand_knowledge,
            'brand_id' => $this->brand_id,
            'thumbnail_url' => $this->thumbnail_url,
            'files_count' => $this->files_count ?? $this->files()->count(),
            'last_edited_at' => $this->last_edited_at?->toIso8601String(),
            'created_at' => $this->created_at?->toIso8601String(),
        ];
    }
}
```

**d) Create `KvGenerationResource.php`:**

```php
<?php

namespace App\Http\Resources\Studio;

use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

class KvGenerationResource extends JsonResource
{
    public function toArray(Request $request): array
    {
        return [
            'id' => $this->id,
            'studio_file_id' => $this->studio_file_id,
            'version_number' => $this->version_number,
            'image_url' => $this->image_url,
            'thumbnail_url' => $this->thumbnail_url,
            'prompt_snapshot' => $this->prompt_snapshot,
            'model' => $this->model,
            'parent_generation_id' => $this->parent_generation_id,
            'metadata' => $this->metadata,
            'created_at' => $this->created_at?->toIso8601String(),
        ];
    }
}
```

**e) Fix any callsites** still importing the old `StudioProjectResource` for file-shaped responses — repoint to `StudioFileResource`. Search:

```bash
grep -rln "Studio\\\\StudioProjectResource" api/app | xargs grep -l "file\|tool" | # inspect each
```

Manually update controllers that returned file rows — they should now return `StudioFileResource`.

- [ ] **Step 4: Run test to verify it passes**

Run: `php artisan test --filter=ResourcesTest`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add api/app/Http/Resources/Studio/ api/tests/Feature/Studio/ResourcesTest.php
git add -u api/app/Http/Controllers
git commit -m "feat(api): split StudioProjectResource → StudioFileResource + new folder + KvGenerationResource"
```

---

## Task 10 — Form requests (validation)

**Files:**
- Create: `api/app/Http/Requests/Studio/StoreStudioProjectRequest.php`
- Create: `api/app/Http/Requests/Studio/UpdateStudioProjectRequest.php`
- Create: `api/app/Http/Requests/Studio/MoveStudioFileRequest.php`
- Create: `api/app/Http/Requests/Studio/CreateKvGeneratorFileRequest.php`

- [ ] **Step 1: Write the failing test**

File: `api/tests/Feature/Studio/FormRequestsTest.php`

```php
<?php

use App\Http\Requests\Studio\CreateKvGeneratorFileRequest;
use App\Http\Requests\Studio\MoveStudioFileRequest;
use App\Http\Requests\Studio\StoreStudioProjectRequest;
use App\Http\Requests\Studio\UpdateStudioProjectRequest;

it('loads all new form requests', function () {
    expect(class_exists(StoreStudioProjectRequest::class))->toBeTrue();
    expect(class_exists(UpdateStudioProjectRequest::class))->toBeTrue();
    expect(class_exists(MoveStudioFileRequest::class))->toBeTrue();
    expect(class_exists(CreateKvGeneratorFileRequest::class))->toBeTrue();
});

it('StoreStudioProjectRequest requires name and brand_id', function () {
    $rules = (new StoreStudioProjectRequest())->rules();
    expect($rules['name'])->toContain('required');
    expect($rules['brand_id'])->toContain('required');
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `php artisan test --filter=FormRequestsTest`
Expected: FAIL — classes missing.

- [ ] **Step 3: Create each request**

**a) `StoreStudioProjectRequest.php`:**

```php
<?php

namespace App\Http\Requests\Studio;

use Illuminate\Foundation\Http\FormRequest;

class StoreStudioProjectRequest extends FormRequest
{
    public function authorize(): bool
    {
        return $this->user() !== null;
    }

    public function rules(): array
    {
        return [
            'name' => ['required', 'string', 'min:1', 'max:80'],
            'description' => ['nullable', 'string', 'max:5000'],
            'brand_id' => ['required', 'string', 'exists:brands,id'],
            'use_brand_knowledge' => ['sometimes', 'boolean'],
        ];
    }
}
```

**b) `UpdateStudioProjectRequest.php`:**

```php
<?php

namespace App\Http\Requests\Studio;

use Illuminate\Foundation\Http\FormRequest;

class UpdateStudioProjectRequest extends FormRequest
{
    public function authorize(): bool
    {
        return $this->user() !== null;
    }

    public function rules(): array
    {
        return [
            'name' => ['sometimes', 'string', 'min:1', 'max:80'],
            'description' => ['sometimes', 'nullable', 'string', 'max:5000'],
            'use_brand_knowledge' => ['sometimes', 'boolean'],
        ];
    }
}
```

**c) `MoveStudioFileRequest.php`:**

```php
<?php

namespace App\Http\Requests\Studio;

use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Validation\Rule;

class MoveStudioFileRequest extends FormRequest
{
    public function authorize(): bool
    {
        return $this->user() !== null;
    }

    public function rules(): array
    {
        return [
            'project_id' => ['nullable', 'string', Rule::exists('studio_projects', 'id')->whereNull('deleted_at')],
        ];
    }
}
```

**d) `CreateKvGeneratorFileRequest.php`:**

```php
<?php

namespace App\Http\Requests\Studio;

use Illuminate\Foundation\Http\FormRequest;

class CreateKvGeneratorFileRequest extends FormRequest
{
    public function authorize(): bool
    {
        return $this->user() !== null;
    }

    public function rules(): array
    {
        return [
            'project_id' => ['nullable', 'string', 'exists:studio_projects,id'],
            'initial_prompt' => ['nullable', 'string', 'max:4000'],
            'brand_id' => ['required', 'string', 'exists:brands,id'],
        ];
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `php artisan test --filter=FormRequestsTest`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add api/app/Http/Requests/Studio/ api/tests/Feature/Studio/FormRequestsTest.php
git commit -m "feat(api): add form requests for studio projects, files, kv-generator"
```

---

## Task 11 — `StudioProjectService` (folder create + soft-delete with file orphaning)

**Files:**
- Create: `api/app/Services/Studio/StudioProjectService.php`

- [ ] **Step 1: Write the failing test**

File: `api/tests/Feature/Studio/StudioProjectServiceTest.php`

```php
<?php

use App\Models\StudioFile;
use App\Models\StudioProject;
use App\Models\Tool;
use App\Models\User;
use App\Services\Studio\StudioProjectService;

beforeEach(function () {
    // use your test factories for Workspace, Brand, User, Tool
    $this->user = User::factory()->create();
    $this->brand = \App\Models\Brand::factory()->create();
    $this->workspace = \App\Models\Workspace::factory()->create();
    $this->tool = Tool::factory()->create();
});

it('creates a project with defaults', function () {
    $service = app(StudioProjectService::class);

    $project = $service->create(
        workspaceId: $this->workspace->id,
        brandId: $this->brand->id,
        userId: $this->user->id,
        name: 'Test Campaign',
        description: 'A brief',
        useBrandKnowledge: true,
    );

    expect($project->name)->toBe('Test Campaign')
        ->and($project->use_brand_knowledge)->toBeTrue()
        ->and($project->brand_id)->toBe($this->brand->id);
});

it('soft-deleting a project orphans its files', function () {
    $service = app(StudioProjectService::class);

    $project = $service->create(
        workspaceId: $this->workspace->id,
        brandId: $this->brand->id,
        userId: $this->user->id,
        name: 'X',
    );

    $file = StudioFile::factory()->create([
        'workspace_id' => $this->workspace->id,
        'brand_id' => $this->brand->id,
        'tool_id' => $this->tool->id,
        'created_by' => $this->user->id,
        'last_edited_by' => $this->user->id,
        'project_id' => $project->id,
    ]);

    $service->softDelete($project);

    expect($file->fresh()->project_id)->toBeNull()
        ->and($project->fresh()->trashed())->toBeTrue();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `php artisan test --filter=StudioProjectServiceTest`
Expected: FAIL — service class missing.

- [ ] **Step 3: Create service**

File: `api/app/Services/Studio/StudioProjectService.php`

```php
<?php

namespace App\Services\Studio;

use App\Models\StudioFile;
use App\Models\StudioProject;
use Illuminate\Support\Facades\DB;

class StudioProjectService
{
    public function create(
        string $workspaceId,
        string $brandId,
        string $userId,
        string $name,
        ?string $description = null,
        bool $useBrandKnowledge = false,
    ): StudioProject {
        return StudioProject::create([
            'workspace_id' => $workspaceId,
            'brand_id' => $brandId,
            'created_by' => $userId,
            'last_edited_by' => $userId,
            'name' => $name,
            'description' => $description,
            'use_brand_knowledge' => $useBrandKnowledge,
            'last_edited_at' => now(),
        ]);
    }

    public function update(StudioProject $project, string $userId, array $attributes): StudioProject
    {
        $project->fill($attributes);
        $project->last_edited_by = $userId;
        $project->last_edited_at = now();
        $project->save();
        return $project;
    }

    /**
     * Soft-delete a project and orphan all its files in the same transaction.
     * The FK SET NULL rule only fires on hard-delete; for soft-delete we null
     * out project_id on files explicitly.
     */
    public function softDelete(StudioProject $project): void
    {
        DB::transaction(function () use ($project) {
            StudioFile::where('project_id', $project->id)->update(['project_id' => null]);
            $project->delete();  // soft delete
        });
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `php artisan test --filter=StudioProjectServiceTest`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add api/app/Services/Studio/StudioProjectService.php api/tests/Feature/Studio/StudioProjectServiceTest.php
git commit -m "feat(api): add StudioProjectService with soft-delete orphaning logic"
```

---

## Task 12 — `StudioProjectController` (folder CRUD)

**Files:**
- Create: `api/app/Http/Controllers/Api/Studio/StudioProjectController.php`

- [ ] **Step 1: Write the failing tests**

File: `api/tests/Feature/Studio/StudioProjectCrudTest.php`

```php
<?php

use App\Models\Brand;
use App\Models\StudioProject;
use App\Models\User;
use App\Models\Workspace;

beforeEach(function () {
    $this->user = User::factory()->create();
    $this->brand = Brand::factory()->create();
    $this->workspace = Workspace::factory()->hasAttached($this->user)->create();
    $this->user->update(['current_workspace_id' => $this->workspace->id]);
    $this->actingAs($this->user);
});

it('lists projects scoped to workspace and brand', function () {
    StudioProject::factory()->for($this->workspace)->for($this->brand)->count(3)->create([
        'created_by' => $this->user->id, 'last_edited_by' => $this->user->id,
    ]);

    $this->getJson("/api/studio/projects?brand_id={$this->brand->id}")
        ->assertOk()
        ->assertJsonCount(3, 'data');
});

it('creates a project', function () {
    $response = $this->postJson('/api/studio/projects', [
        'name' => 'New Campaign',
        'description' => 'Bold and bright',
        'brand_id' => $this->brand->id,
        'use_brand_knowledge' => true,
    ]);

    $response->assertCreated()
        ->assertJsonPath('data.name', 'New Campaign')
        ->assertJsonPath('data.use_brand_knowledge', true);
});

it('rejects a project without a brand_id', function () {
    $this->postJson('/api/studio/projects', [
        'name' => 'No Brand',
    ])->assertStatus(422);
});

it('updates a project', function () {
    $project = StudioProject::factory()->for($this->workspace)->for($this->brand)->create([
        'created_by' => $this->user->id, 'last_edited_by' => $this->user->id,
        'use_brand_knowledge' => false,
    ]);

    $this->patchJson("/api/studio/projects/{$project->id}", [
        'use_brand_knowledge' => true,
    ])->assertOk()
      ->assertJsonPath('data.use_brand_knowledge', true);
});

it('soft-deletes a project and orphans its files', function () {
    $project = StudioProject::factory()->for($this->workspace)->for($this->brand)->create([
        'created_by' => $this->user->id, 'last_edited_by' => $this->user->id,
    ]);

    $this->deleteJson("/api/studio/projects/{$project->id}")->assertNoContent();
    expect($project->fresh()->trashed())->toBeTrue();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `php artisan test --filter=StudioProjectCrudTest`
Expected: FAIL — controller + routes missing.

- [ ] **Step 3: Create controller**

File: `api/app/Http/Controllers/Api/Studio/StudioProjectController.php`

```php
<?php

namespace App\Http\Controllers\Api\Studio;

use App\Http\Controllers\Controller;
use App\Http\Requests\Studio\StoreStudioProjectRequest;
use App\Http\Requests\Studio\UpdateStudioProjectRequest;
use App\Http\Resources\Studio\StudioProjectResource;
use App\Models\StudioProject;
use App\Services\Studio\StudioProjectService;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\AnonymousResourceCollection;

class StudioProjectController extends Controller
{
    public function __construct(private readonly StudioProjectService $service) {}

    public function index(Request $request): AnonymousResourceCollection
    {
        $workspaceId = $request->user()->current_workspace_id;
        $brandId = $request->query('brand_id');
        $search = $request->query('search');
        $limit = (int) $request->query('limit', 20);

        $query = StudioProject::query()
            ->where('workspace_id', $workspaceId)
            ->when($brandId, fn ($q) => $q->where('brand_id', $brandId))
            ->when($search, fn ($q, $s) => $q->where('name', 'ilike', "%{$s}%"))
            ->withCount('files')
            ->orderByDesc('last_edited_at');

        return StudioProjectResource::collection($query->paginate($limit));
    }

    public function store(StoreStudioProjectRequest $request): JsonResponse
    {
        $project = $this->service->create(
            workspaceId: $request->user()->current_workspace_id,
            brandId: $request->input('brand_id'),
            userId: $request->user()->id,
            name: $request->input('name'),
            description: $request->input('description'),
            useBrandKnowledge: (bool) $request->input('use_brand_knowledge', false),
        );

        return (new StudioProjectResource($project))
            ->response()
            ->setStatusCode(201);
    }

    public function show(string $id): StudioProjectResource
    {
        $project = StudioProject::withCount('files')->findOrFail($id);
        $this->authorizeAccess($project);
        return new StudioProjectResource($project);
    }

    public function update(UpdateStudioProjectRequest $request, string $id): StudioProjectResource
    {
        $project = StudioProject::findOrFail($id);
        $this->authorizeAccess($project);

        $this->service->update($project, $request->user()->id, $request->validated());

        return new StudioProjectResource($project->loadCount('files'));
    }

    public function destroy(Request $request, string $id): JsonResponse
    {
        $project = StudioProject::findOrFail($id);
        $this->authorizeAccess($project);

        $this->service->softDelete($project);

        return response()->json(null, 204);
    }

    private function authorizeAccess(StudioProject $project): void
    {
        abort_unless(
            $project->workspace_id === request()->user()->current_workspace_id,
            403,
            'You do not have access to this project.'
        );
    }
}
```

- [ ] **Step 4: Register routes**

Edit: `api/routes/api.php` — inside the authenticated route group, add:

```php
Route::prefix('studio')->group(function () {
    Route::apiResource('projects', \App\Http\Controllers\Api\Studio\StudioProjectController::class);
});
```

- [ ] **Step 5: Run test to verify it passes**

Run: `php artisan test --filter=StudioProjectCrudTest`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add api/app/Http/Controllers/Api/Studio/StudioProjectController.php \
       api/routes/api.php api/tests/Feature/Studio/StudioProjectCrudTest.php
git commit -m "feat(api): add studio projects CRUD endpoints"
```

---

## Task 13 — `StudioFileController` (list, rename, move, delete)

**Files:**
- Create: `api/app/Http/Controllers/Api/Studio/StudioFileController.php`

- [ ] **Step 1: Write the failing tests**

File: `api/tests/Feature/Studio/StudioFileMoveTest.php`

```php
<?php

use App\Models\Brand;
use App\Models\StudioFile;
use App\Models\StudioProject;
use App\Models\Tool;
use App\Models\User;
use App\Models\Workspace;

beforeEach(function () {
    $this->user = User::factory()->create();
    $this->brand = Brand::factory()->create();
    $this->otherBrand = Brand::factory()->create();
    $this->workspace = Workspace::factory()->hasAttached($this->user)->create();
    $this->user->update(['current_workspace_id' => $this->workspace->id]);
    $this->tool = Tool::factory()->create();
    $this->actingAs($this->user);
});

it('moves an orphan file into a project with matching brand', function () {
    $project = StudioProject::factory()->for($this->workspace)->for($this->brand)->create([
        'created_by' => $this->user->id, 'last_edited_by' => $this->user->id,
    ]);
    $file = StudioFile::factory()->create([
        'workspace_id' => $this->workspace->id,
        'brand_id' => $this->brand->id,
        'tool_id' => $this->tool->id,
        'project_id' => null,
        'created_by' => $this->user->id, 'last_edited_by' => $this->user->id,
    ]);

    $this->patchJson("/api/studio/files/{$file->id}/move", [
        'project_id' => $project->id,
    ])->assertOk();

    expect($file->fresh()->project_id)->toBe($project->id);
});

it('blocks move across brands', function () {
    $project = StudioProject::factory()->for($this->workspace)->for($this->otherBrand)->create([
        'created_by' => $this->user->id, 'last_edited_by' => $this->user->id,
    ]);
    $file = StudioFile::factory()->create([
        'workspace_id' => $this->workspace->id,
        'brand_id' => $this->brand->id,
        'tool_id' => $this->tool->id,
        'project_id' => null,
        'created_by' => $this->user->id, 'last_edited_by' => $this->user->id,
    ]);

    $this->patchJson("/api/studio/files/{$file->id}/move", [
        'project_id' => $project->id,
    ])->assertStatus(422)
      ->assertJsonPath('errors.project_id.0', "Can't move — brand mismatch");
});

it('moves a file to orphan (project_id=null)', function () {
    $project = StudioProject::factory()->for($this->workspace)->for($this->brand)->create([
        'created_by' => $this->user->id, 'last_edited_by' => $this->user->id,
    ]);
    $file = StudioFile::factory()->create([
        'workspace_id' => $this->workspace->id,
        'brand_id' => $this->brand->id,
        'tool_id' => $this->tool->id,
        'project_id' => $project->id,
        'created_by' => $this->user->id, 'last_edited_by' => $this->user->id,
    ]);

    $this->patchJson("/api/studio/files/{$file->id}/move", [
        'project_id' => null,
    ])->assertOk();

    expect($file->fresh()->project_id)->toBeNull();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `php artisan test --filter=StudioFileMoveTest`
Expected: FAIL.

- [ ] **Step 3: Create controller**

File: `api/app/Http/Controllers/Api/Studio/StudioFileController.php`

```php
<?php

namespace App\Http\Controllers\Api\Studio;

use App\Http\Controllers\Controller;
use App\Http\Requests\Studio\MoveStudioFileRequest;
use App\Http\Resources\Studio\StudioFileResource;
use App\Models\StudioFile;
use App\Models\StudioProject;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\AnonymousResourceCollection;
use Illuminate\Validation\ValidationException;

class StudioFileController extends Controller
{
    public function index(Request $request): AnonymousResourceCollection
    {
        $workspaceId = $request->user()->current_workspace_id;
        $query = StudioFile::query()
            ->with(['tool', 'lastEditedBy'])
            ->where('workspace_id', $workspaceId);

        if ($request->has('project_id')) {
            $pid = $request->query('project_id');
            $pid === 'null'
                ? $query->whereNull('project_id')
                : $query->where('project_id', $pid);
        }
        if ($toolSlug = $request->query('tool_slug')) {
            $query->whereHas('tool', fn ($q) => $q->where('slug', $toolSlug));
        }

        return StudioFileResource::collection(
            $query->orderByDesc('last_edited_at')->paginate((int) $request->query('limit', 20))
        );
    }

    public function update(Request $request, string $id): StudioFileResource
    {
        $request->validate(['name' => ['required', 'string', 'min:1', 'max:120']]);

        $file = StudioFile::findOrFail($id);
        $this->authorizeAccess($file, $request);

        $file->name = $request->input('name');
        $file->last_edited_by = $request->user()->id;
        $file->last_edited_at = now();
        $file->save();

        return new StudioFileResource($file->load(['tool', 'lastEditedBy']));
    }

    public function move(MoveStudioFileRequest $request, string $id): StudioFileResource
    {
        $file = StudioFile::findOrFail($id);
        $this->authorizeAccess($file, $request);

        $targetProjectId = $request->input('project_id');
        if ($targetProjectId !== null) {
            $target = StudioProject::findOrFail($targetProjectId);
            if ($target->brand_id !== $file->brand_id) {
                throw ValidationException::withMessages([
                    'project_id' => ["Can't move — brand mismatch"],
                ]);
            }
        }

        $file->project_id = $targetProjectId;
        $file->last_edited_by = $request->user()->id;
        $file->last_edited_at = now();
        $file->save();

        return new StudioFileResource($file->load(['tool', 'lastEditedBy']));
    }

    public function destroy(Request $request, string $id): JsonResponse
    {
        $file = StudioFile::findOrFail($id);
        $this->authorizeAccess($file, $request);

        $file->delete();  // soft delete if SoftDeletes is added; else hard

        return response()->json(null, 204);
    }

    private function authorizeAccess(StudioFile $file, Request $request): void
    {
        abort_unless(
            $file->workspace_id === $request->user()->current_workspace_id,
            403,
            'You do not have access to this file.'
        );
    }
}
```

- [ ] **Step 4: Register routes**

Edit: `api/routes/api.php` — inside the `studio` prefix group:

```php
Route::get('files', [\App\Http\Controllers\Api\Studio\StudioFileController::class, 'index']);
Route::patch('files/{id}', [\App\Http\Controllers\Api\Studio\StudioFileController::class, 'update']);
Route::patch('files/{id}/move', [\App\Http\Controllers\Api\Studio\StudioFileController::class, 'move']);
Route::delete('files/{id}', [\App\Http\Controllers\Api\Studio\StudioFileController::class, 'destroy']);

Route::get('projects/{id}/files', function ($id, \Illuminate\Http\Request $request) {
    $request->merge(['project_id' => $id]);
    return app(\App\Http\Controllers\Api\Studio\StudioFileController::class)->index($request);
});
```

- [ ] **Step 5: Run test to verify it passes**

Run: `php artisan test --filter=StudioFileMoveTest`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add api/app/Http/Controllers/Api/Studio/StudioFileController.php \
       api/routes/api.php api/tests/Feature/Studio/StudioFileMoveTest.php
git commit -m "feat(api): add studio files list/rename/move/delete endpoints"
```

---

## Task 14 — `KvGeneratorFileController` (create file + thread, detail, list generations)

**Files:**
- Create: `api/app/Http/Controllers/Api/Studio/KvGeneratorFileController.php`

- [ ] **Step 1: Write the failing tests**

File: `api/tests/Feature/Studio/KvGeneratorFileLifecycleTest.php`

```php
<?php

use App\Enums\ThreadType;
use App\Models\Brand;
use App\Models\StudioFile;
use App\Models\StudioProject;
use App\Models\Tool;
use App\Models\User;
use App\Models\UserThread;
use App\Models\Workspace;

beforeEach(function () {
    $this->user = User::factory()->create();
    $this->brand = Brand::factory()->create();
    $this->workspace = Workspace::factory()->hasAttached($this->user)->create();
    $this->user->update(['current_workspace_id' => $this->workspace->id]);
    Tool::factory()->create(['slug' => 'kv-generator']);
    $this->actingAs($this->user);
});

it('creates a kv file with a thread and sane launch_context', function () {
    $project = StudioProject::factory()->for($this->workspace)->for($this->brand)->create([
        'created_by' => $this->user->id, 'last_edited_by' => $this->user->id,
        'use_brand_knowledge' => true,
    ]);

    $response = $this->postJson('/api/studio/kv-generator/files', [
        'project_id' => $project->id,
        'brand_id' => $this->brand->id,
    ])->assertCreated();

    $fileId = $response->json('data.id');
    $file = StudioFile::findOrFail($fileId);

    expect($file->project_id)->toBe($project->id)
        ->and($file->thread_id)->not->toBeNull();

    $thread = UserThread::findOrFail($file->thread_id);
    expect($thread->thread_type)->toBe(ThreadType::KvGenerator->value)
        ->and($thread->launch_context['project_id'] ?? null)->toBe($project->id)
        ->and($thread->launch_context['use_brand_knowledge'] ?? null)->toBeTrue();
});

it('creates an orphan kv file when no project_id is given', function () {
    $response = $this->postJson('/api/studio/kv-generator/files', [
        'brand_id' => $this->brand->id,
    ])->assertCreated();

    $fileId = $response->json('data.id');
    $file = StudioFile::findOrFail($fileId);

    expect($file->project_id)->toBeNull();
    $thread = UserThread::findOrFail($file->thread_id);
    expect($thread->launch_context['project_id'] ?? null)->toBeNull()
        ->and($thread->launch_context['use_brand_knowledge'] ?? null)->toBeFalse();
});

it('returns file detail including generations', function () {
    $file = StudioFile::factory()->create([
        'workspace_id' => $this->workspace->id,
        'brand_id' => $this->brand->id,
        'tool_id' => Tool::where('slug', 'kv-generator')->first()->id,
        'created_by' => $this->user->id, 'last_edited_by' => $this->user->id,
    ]);

    $this->getJson("/api/studio/kv-generator/files/{$file->id}")
        ->assertOk()
        ->assertJsonPath('data.id', $file->id)
        ->assertJsonStructure(['data' => ['id', 'name', 'thread_id', 'generations']]);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `php artisan test --filter=KvGeneratorFileLifecycleTest`
Expected: FAIL.

- [ ] **Step 3: Create controller**

File: `api/app/Http/Controllers/Api/Studio/KvGeneratorFileController.php`

```php
<?php

namespace App\Http\Controllers\Api\Studio;

use App\Enums\ThreadType;
use App\Http\Controllers\Controller;
use App\Http\Requests\Studio\CreateKvGeneratorFileRequest;
use App\Http\Resources\Studio\KvGenerationResource;
use App\Http\Resources\Studio\StudioFileResource;
use App\Models\StudioFile;
use App\Models\StudioProject;
use App\Models\Tool;
use App\Models\UserThread;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\AnonymousResourceCollection;
use Illuminate\Support\Facades\DB;

class KvGeneratorFileController extends Controller
{
    public function store(CreateKvGeneratorFileRequest $request): JsonResponse
    {
        $workspaceId = $request->user()->current_workspace_id;
        $brandId = $request->input('brand_id');
        $projectId = $request->input('project_id');

        $tool = Tool::where('slug', 'kv-generator')->firstOrFail();

        $project = $projectId ? StudioProject::findOrFail($projectId) : null;
        if ($project && $project->brand_id !== $brandId) {
            abort(422, "Project brand does not match file brand");
        }

        [$file, $thread] = DB::transaction(function () use (
            $workspaceId, $brandId, $projectId, $project, $tool, $request
        ) {
            $thread = UserThread::create([
                'user_id' => $request->user()->id,
                'workspace_id' => $workspaceId,
                'thread_type' => ThreadType::KvGenerator->value,
                'title' => 'New KV',
                'launch_context' => [
                    'project_id' => $projectId,
                    'studio_file_id' => null,
                    'use_brand_knowledge' => $project ? (bool) $project->use_brand_knowledge : false,
                    'brand_id' => $brandId,
                ],
            ]);

            $file = StudioFile::create([
                'workspace_id' => $workspaceId,
                'brand_id' => $brandId,
                'project_id' => $projectId,
                'thread_id' => $thread->id,
                'tool_id' => $tool->id,
                'created_by' => $request->user()->id,
                'last_edited_by' => $request->user()->id,
                'name' => 'Untitled KV',
                'status' => 'draft',
                'last_edited_at' => now(),
                'metadata' => ['current_mode' => 'chat'],
            ]);

            // Write studio_file_id back into thread launch_context
            $thread->launch_context = [
                ...$thread->launch_context,
                'studio_file_id' => $file->id,
            ];
            $thread->save();

            return [$file, $thread];
        });

        return (new StudioFileResource($file->load(['tool'])))->response()->setStatusCode(201);
    }

    public function show(Request $request, string $id): JsonResponse
    {
        $file = StudioFile::with(['tool', 'generations', 'lastEditedBy'])->findOrFail($id);
        abort_unless($file->workspace_id === $request->user()->current_workspace_id, 403);

        return response()->json([
            'data' => array_merge(
                (new StudioFileResource($file))->toArray($request),
                ['generations' => KvGenerationResource::collection($file->generations)->toArray($request)],
            ),
        ]);
    }

    public function generations(Request $request, string $id): AnonymousResourceCollection
    {
        $file = StudioFile::findOrFail($id);
        abort_unless($file->workspace_id === $request->user()->current_workspace_id, 403);

        return KvGenerationResource::collection(
            $file->generations()->paginate((int) $request->query('limit', 20))
        );
    }
}
```

- [ ] **Step 4: Register routes**

Edit: `api/routes/api.php` — inside the `studio` prefix group:

```php
Route::post('kv-generator/files',          [\App\Http\Controllers\Api\Studio\KvGeneratorFileController::class, 'store']);
Route::get('kv-generator/files/{id}',       [\App\Http\Controllers\Api\Studio\KvGeneratorFileController::class, 'show']);
Route::get('kv-generator/files/{id}/generations', [\App\Http\Controllers\Api\Studio\KvGeneratorFileController::class, 'generations']);
```

- [ ] **Step 5: Run test to verify it passes**

Run: `php artisan test --filter=KvGeneratorFileLifecycleTest`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add api/app/Http/Controllers/Api/Studio/KvGeneratorFileController.php \
       api/routes/api.php api/tests/Feature/Studio/KvGeneratorFileLifecycleTest.php
git commit -m "feat(api): add KV generator file lifecycle endpoints (create/show/generations)"
```

---

## Task 15 — Internal callback: `KvGenerationCallbackController`

**Files:**
- Create: `api/app/Http/Requests/Internal/KvGenerationCompleteRequest.php`
- Create: `api/app/Services/Studio/KvGenerationService.php`
- Create: `api/app/Http/Controllers/Api/Internal/KvGenerationCallbackController.php`

- [ ] **Step 1: Write the failing tests**

File: `api/tests/Feature/Internal/KvGenerationCallbackTest.php`

```php
<?php

use App\Models\KvGeneration;
use App\Models\StudioFile;
use App\Models\Tool;
use App\Models\User;
use App\Models\Workspace;
use Illuminate\Support\Facades\Config;

beforeEach(function () {
    Config::set('services.internal.kv_callback_token', 'test-internal-token-123');

    $this->user = User::factory()->create();
    $this->workspace = Workspace::factory()->hasAttached($this->user)->create();
    Tool::factory()->create(['slug' => 'kv-generator']);

    $this->file = StudioFile::factory()->create([
        'workspace_id' => $this->workspace->id,
        'brand_id' => \App\Models\Brand::factory()->create()->id,
        'tool_id' => Tool::where('slug', 'kv-generator')->first()->id,
        'created_by' => $this->user->id,
        'last_edited_by' => $this->user->id,
    ]);
});

it('rejects unsigned callback', function () {
    $this->postJson('/api/internal/kv-generator/generation-complete', [
        'studio_file_id' => $this->file->id,
        'image_url' => 'https://storage.example.com/kv/image.png',
        'prompt_snapshot' => 'Bold campaign KV',
        'model' => 'gemini-2.5-nano-banana',
    ])->assertUnauthorized();
});

it('writes a kv_generation row with version 1 for first generation', function () {
    $response = $this->postJson('/api/internal/kv-generator/generation-complete', [
        'studio_file_id' => $this->file->id,
        'image_url' => 'https://storage.example.com/kv/image.png',
        'thumbnail_url' => 'https://storage.example.com/kv/thumb.png',
        'prompt_snapshot' => 'Bold campaign KV',
        'model' => 'gemini-2.5-nano-banana',
        'metadata' => ['aspect_ratio' => '1:1'],
        'created_by' => $this->user->id,
    ], ['X-Internal-Token' => 'test-internal-token-123'])->assertCreated();

    $gen = KvGeneration::where('studio_file_id', $this->file->id)->firstOrFail();
    expect($gen->version_number)->toBe(1)
        ->and($gen->image_url)->toBe('https://storage.example.com/kv/image.png')
        ->and($gen->metadata['aspect_ratio'])->toBe('1:1');

    expect($this->file->fresh()->thumbnail_url)->toBe('https://storage.example.com/kv/thumb.png');
});

it('increments version_number across generations', function () {
    for ($i = 1; $i <= 3; $i++) {
        $this->postJson('/api/internal/kv-generator/generation-complete', [
            'studio_file_id' => $this->file->id,
            'image_url' => "https://s/image{$i}.png",
            'prompt_snapshot' => "p{$i}",
            'model' => 'm',
            'created_by' => $this->user->id,
        ], ['X-Internal-Token' => 'test-internal-token-123']);
    }

    $versions = KvGeneration::where('studio_file_id', $this->file->id)
        ->pluck('version_number')->sort()->values()->all();
    expect($versions)->toBe([1, 2, 3]);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `php artisan test --filter=KvGenerationCallbackTest`
Expected: FAIL.

- [ ] **Step 3: Create service**

File: `api/app/Services/Studio/KvGenerationService.php`

```php
<?php

namespace App\Services\Studio;

use App\Models\KvGeneration;
use App\Models\StudioActivity;
use App\Models\StudioFile;
use Illuminate\Support\Facades\DB;

class KvGenerationService
{
    public function persistCompletion(array $payload): KvGeneration
    {
        return DB::transaction(function () use ($payload) {
            $file = StudioFile::findOrFail($payload['studio_file_id']);

            $nextVersion = ($file->generations()->max('version_number') ?? 0) + 1;

            $generation = KvGeneration::create([
                'studio_file_id' => $file->id,
                'parent_generation_id' => $payload['parent_generation_id'] ?? null,
                'chat_message_id' => $payload['chat_message_id'] ?? null,
                'version_number' => $nextVersion,
                'image_url' => $payload['image_url'],
                'thumbnail_url' => $payload['thumbnail_url'] ?? null,
                'prompt_snapshot' => $payload['prompt_snapshot'],
                'model' => $payload['model'],
                'ai_service_run_id' => $payload['ai_service_run_id'] ?? null,
                'metadata' => $payload['metadata'] ?? [],
                'created_by' => $payload['created_by'],
                'created_at' => now(),
            ]);

            $file->thumbnail_url = $payload['thumbnail_url'] ?? $payload['image_url'];
            $file->last_edited_at = now();
            $file->last_edited_by = $payload['created_by'];
            $file->save();

            StudioActivity::create([
                'workspace_id' => $file->workspace_id,
                'user_id' => $payload['created_by'],
                'file_id' => $file->id,
                'project_id' => $file->project_id,
                'tool_id' => $file->tool_id,
                'brand_id' => $file->brand_id,
                'action' => 'kv_generated',
                'summary' => "Generated version {$nextVersion}",
                'metadata' => ['generation_id' => $generation->id, 'model' => $payload['model']],
            ]);

            return $generation;
        });
    }
}
```

- [ ] **Step 4: Create form request**

File: `api/app/Http/Requests/Internal/KvGenerationCompleteRequest.php`

```php
<?php

namespace App\Http\Requests\Internal;

use Illuminate\Foundation\Http\FormRequest;

class KvGenerationCompleteRequest extends FormRequest
{
    public function authorize(): bool
    {
        return $this->header('X-Internal-Token') === config('services.internal.kv_callback_token');
    }

    public function rules(): array
    {
        return [
            'studio_file_id' => ['required', 'string', 'exists:studio_files,id'],
            'image_url' => ['required', 'url'],
            'thumbnail_url' => ['nullable', 'url'],
            'prompt_snapshot' => ['required', 'string'],
            'model' => ['required', 'string'],
            'parent_generation_id' => ['nullable', 'string', 'exists:kv_generations,id'],
            'chat_message_id' => ['nullable', 'string'],
            'ai_service_run_id' => ['nullable', 'string'],
            'metadata' => ['nullable', 'array'],
            'created_by' => ['required', 'string', 'exists:users,id'],
        ];
    }
}
```

- [ ] **Step 5: Create controller**

File: `api/app/Http/Controllers/Api/Internal/KvGenerationCallbackController.php`

```php
<?php

namespace App\Http\Controllers\Api\Internal;

use App\Http\Controllers\Controller;
use App\Http\Requests\Internal\KvGenerationCompleteRequest;
use App\Http\Resources\Studio\KvGenerationResource;
use App\Services\Studio\KvGenerationService;
use Illuminate\Http\JsonResponse;

class KvGenerationCallbackController extends Controller
{
    public function __construct(private readonly KvGenerationService $service) {}

    public function complete(KvGenerationCompleteRequest $request): JsonResponse
    {
        $generation = $this->service->persistCompletion($request->validated());

        return (new KvGenerationResource($generation))
            ->response()
            ->setStatusCode(201);
    }
}
```

- [ ] **Step 6: Register route + config**

Edit: `api/config/services.php` — add:

```php
'internal' => [
    'kv_callback_token' => env('INTERNAL_KV_CALLBACK_TOKEN'),
],
```

Edit: `api/routes/api.php` — OUTSIDE the auth middleware group:

```php
Route::prefix('internal')->group(function () {
    Route::post('kv-generator/generation-complete',
        [\App\Http\Controllers\Api\Internal\KvGenerationCallbackController::class, 'complete']);
});
```

Edit: `api/.env.example` — add `INTERNAL_KV_CALLBACK_TOKEN=`.

- [ ] **Step 7: Run test to verify it passes**

Run: `php artisan test --filter=KvGenerationCallbackTest`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add api/app/Http/Controllers/Api/Internal/KvGenerationCallbackController.php \
       api/app/Http/Requests/Internal/KvGenerationCompleteRequest.php \
       api/app/Services/Studio/KvGenerationService.php \
       api/config/services.php api/routes/api.php api/.env.example \
       api/tests/Feature/Internal/KvGenerationCallbackTest.php
git commit -m "feat(api): add signed internal callback for KV generation persistence"
```

---

## Task 16 — Extend chat stream: accept `mode` and KV `launch_context`

**Files:**
- Modify: `api/app/Http/Requests/StreamChatRequest.php`
- Modify: `api/app/Services/ChatService.php`

- [ ] **Step 1: Write the failing test**

File: `api/tests/Feature/Chat/StreamChatKvModeTest.php`

```php
<?php

use App\Enums\ThreadType;
use App\Models\StudioFile;
use App\Models\Tool;
use App\Models\User;
use App\Models\UserThread;
use App\Models\Workspace;
use Illuminate\Support\Facades\Http;

beforeEach(function () {
    Http::fake();
    $this->user = User::factory()->create();
    $this->workspace = Workspace::factory()->hasAttached($this->user)->create();
    $this->user->update(['current_workspace_id' => $this->workspace->id]);
    Tool::factory()->create(['slug' => 'kv-generator']);
    $this->actingAs($this->user);
});

it('forwards mode and launch_context to ai-service for kv threads', function () {
    $thread = UserThread::factory()->create([
        'user_id' => $this->user->id,
        'workspace_id' => $this->workspace->id,
        'thread_type' => ThreadType::KvGenerator->value,
        'launch_context' => [
            'project_id' => null,
            'studio_file_id' => 'some-file-id',
            'use_brand_knowledge' => false,
            'brand_id' => 'some-brand-id',
        ],
    ]);

    $this->postJson('/api/chat/stream', [
        'thread_id' => $thread->id,
        'message' => 'Create a bold KV',
        'mode' => 'image',
    ])->assertOk();

    Http::assertSent(function ($request) {
        $body = $request->data();
        return str_contains((string) $request->url(), '/ai/kv-generator/stream')
            && ($body['mode'] ?? null) === 'image'
            && isset($body['launch_context']);
    });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `php artisan test --filter=StreamChatKvModeTest`
Expected: FAIL.

- [ ] **Step 3: Extend StreamChatRequest**

Edit: `api/app/Http/Requests/StreamChatRequest.php` — add `mode` to rules:

```php
public function rules(): array
{
    return [
        // ... existing rules ...
        'mode' => ['sometimes', 'in:chat,image'],
    ];
}
```

- [ ] **Step 4: Extend ChatService**

Edit: `api/app/Services/ChatService.php` — in the method that forwards to ai-service, branch on `thread_type`. Look for the existing forwarding section (e.g. `stream()` or similar) and add a branch:

```php
use App\Enums\ThreadType;

// ... inside the forwarding method ...

if ($thread->thread_type === ThreadType::KvGenerator->value) {
    $aiUrl = rtrim(config('services.ai_service.url'), '/') . '/ai/kv-generator/stream';
    $payload = [
        'thread_id' => $thread->id,
        'studio_file_id' => $thread->launch_context['studio_file_id'] ?? null,
        'mode' => $request->input('mode', 'chat'),
        'prompt' => $request->input('message'),
        'launch_context' => $thread->launch_context,
        'chat_history' => $this->loadRecentHistory($thread),
        'attached_generation_id' => $request->input('attached_generation_id'),
    ];
    // ... forward with SSE streaming (follow existing streaming pattern in this file) ...
}
```

(The exact streaming mechanism follows the pattern already used for `ThreadType::Chat` in ChatService — copy that scaffolding, only the URL and body differ.)

- [ ] **Step 5: Run test to verify it passes**

Run: `php artisan test --filter=StreamChatKvModeTest`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add api/app/Http/Requests/StreamChatRequest.php api/app/Services/ChatService.php \
       api/tests/Feature/Chat/StreamChatKvModeTest.php
git commit -m "feat(api): forward mode + kv launch_context to ai-service for KV threads"
```

---

## Task 17 — Internal project-fetch endpoint (used by ai-service)

**Files:**
- Create: `api/app/Http/Controllers/Api/Internal/StudioProjectLookupController.php`

- [ ] **Step 1: Write the failing test**

File: `api/tests/Feature/Internal/StudioProjectLookupTest.php`

```php
<?php

use App\Models\Brand;
use App\Models\StudioProject;
use App\Models\User;
use App\Models\Workspace;
use Illuminate\Support\Facades\Config;

beforeEach(function () {
    Config::set('services.internal.kv_callback_token', 'test-internal-token-456');

    $this->user = User::factory()->create();
    $this->brand = Brand::factory()->create();
    $this->workspace = Workspace::factory()->create();
    $this->project = StudioProject::factory()->for($this->workspace)->for($this->brand)->create([
        'created_by' => $this->user->id,
        'last_edited_by' => $this->user->id,
        'name' => 'CIMB × XG',
        'description' => 'Savings push',
        'use_brand_knowledge' => true,
    ]);
});

it('returns project fields to ai-service', function () {
    $this->getJson("/api/internal/studio/projects/{$this->project->id}", [
        'X-Internal-Token' => 'test-internal-token-456',
    ])->assertOk()
      ->assertJsonPath('data.name', 'CIMB × XG')
      ->assertJsonPath('data.use_brand_knowledge', true);
});

it('rejects unsigned requests', function () {
    $this->getJson("/api/internal/studio/projects/{$this->project->id}")
        ->assertUnauthorized();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `php artisan test --filter=StudioProjectLookupTest`
Expected: FAIL.

- [ ] **Step 3: Create controller**

File: `api/app/Http/Controllers/Api/Internal/StudioProjectLookupController.php`

```php
<?php

namespace App\Http\Controllers\Api\Internal;

use App\Http\Controllers\Controller;
use App\Http\Resources\Studio\StudioProjectResource;
use App\Models\StudioProject;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;

class StudioProjectLookupController extends Controller
{
    public function show(Request $request, string $id): StudioProjectResource | JsonResponse
    {
        if ($request->header('X-Internal-Token') !== config('services.internal.kv_callback_token')) {
            return response()->json(['message' => 'Unauthorized'], 401);
        }

        $project = StudioProject::findOrFail($id);
        return new StudioProjectResource($project);
    }
}
```

- [ ] **Step 4: Register route**

Edit: `api/routes/api.php` — under the `internal` prefix group:

```php
Route::get('studio/projects/{id}',
    [\App\Http\Controllers\Api\Internal\StudioProjectLookupController::class, 'show']);
```

- [ ] **Step 5: Run test to verify it passes**

Run: `php artisan test --filter=StudioProjectLookupTest`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add api/app/Http/Controllers/Api/Internal/StudioProjectLookupController.php \
       api/routes/api.php api/tests/Feature/Internal/StudioProjectLookupTest.php
git commit -m "feat(api): add signed internal endpoint for ai-service to fetch project context"
```

---

## Task 18 — Studio activities taxonomy

**Files:**
- Modify: `api/app/Enums/StudioActivityAction.php` (if it exists; else create)

- [ ] **Step 1: Write the failing test**

File: `api/tests/Unit/Enums/StudioActivityActionTest.php`

```php
<?php

use App\Enums\StudioActivityAction;

it('has all new studio activity actions', function () {
    expect(StudioActivityAction::KvGenerated->value)->toBe('kv_generated')
        ->and(StudioActivityAction::KvGenerationFailed->value)->toBe('kv_generation_failed')
        ->and(StudioActivityAction::ProjectCreated->value)->toBe('project_created')
        ->and(StudioActivityAction::ProjectUpdated->value)->toBe('project_updated')
        ->and(StudioActivityAction::ProjectDeleted->value)->toBe('project_deleted')
        ->and(StudioActivityAction::FileMoved->value)->toBe('file_moved')
        ->and(StudioActivityAction::ModeSwitched->value)->toBe('mode_switched')
        ->and(StudioActivityAction::QuestionCardAnswered->value)->toBe('question_card_answered');
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `php artisan test --filter=StudioActivityActionTest`
Expected: FAIL.

- [ ] **Step 3: Create/modify enum**

File: `api/app/Enums/StudioActivityAction.php`

```php
<?php

namespace App\Enums;

enum StudioActivityAction: string
{
    case ProjectCreated = 'project_created';
    case ProjectUpdated = 'project_updated';
    case ProjectDeleted = 'project_deleted';
    case FileMoved = 'file_moved';
    case KvGenerated = 'kv_generated';
    case KvGenerationFailed = 'kv_generation_failed';
    case ModeSwitched = 'mode_switched';
    case QuestionCardAnswered = 'question_card_answered';
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `php artisan test --filter=StudioActivityActionTest`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add api/app/Enums/StudioActivityAction.php api/tests/Unit/Enums/StudioActivityActionTest.php
git commit -m "feat(api): add StudioActivityAction enum for new action types"
```

---

## Task 19 — End-to-end sanity test

**Files:**
- Create: `api/tests/Feature/Studio/StudioProjectsE2ETest.php`

- [ ] **Step 1: Write the test**

File: `api/tests/Feature/Studio/StudioProjectsE2ETest.php`

```php
<?php

use App\Models\Brand;
use App\Models\KvGeneration;
use App\Models\StudioFile;
use App\Models\StudioProject;
use App\Models\Tool;
use App\Models\User;
use App\Models\Workspace;
use Illuminate\Support\Facades\Config;

it('happy path: create project → new KV file → simulate callback → list generations', function () {
    Config::set('services.internal.kv_callback_token', 'e2e-token');

    $user = User::factory()->create();
    $brand = Brand::factory()->create();
    $workspace = Workspace::factory()->hasAttached($user)->create();
    $user->update(['current_workspace_id' => $workspace->id]);
    Tool::factory()->create(['slug' => 'kv-generator']);

    $this->actingAs($user);

    // 1. Create project
    $project = $this->postJson('/api/studio/projects', [
        'name' => 'CIMB × XG',
        'description' => 'Savings campaign',
        'brand_id' => $brand->id,
        'use_brand_knowledge' => true,
    ])->assertCreated()->json('data');

    // 2. Create KV file inside project
    $file = $this->postJson('/api/studio/kv-generator/files', [
        'project_id' => $project['id'],
        'brand_id' => $brand->id,
    ])->assertCreated()->json('data');

    // 3. Simulate ai-service callback
    $this->postJson('/api/internal/kv-generator/generation-complete', [
        'studio_file_id' => $file['id'],
        'image_url' => 'https://s/kv.png',
        'thumbnail_url' => 'https://s/kv-thumb.png',
        'prompt_snapshot' => 'Bold KV',
        'model' => 'gemini-2.5-nano-banana',
        'created_by' => $user->id,
    ], ['X-Internal-Token' => 'e2e-token'])->assertCreated();

    // 4. List generations for the file
    $this->getJson("/api/studio/kv-generator/files/{$file['id']}/generations")
        ->assertOk()
        ->assertJsonCount(1, 'data')
        ->assertJsonPath('data.0.version_number', 1);

    // 5. Project thumbnail + files_count is correct
    $this->getJson("/api/studio/projects/{$project['id']}")
        ->assertOk()
        ->assertJsonPath('data.files_count', 1);

    // 6. Soft-delete project → file orphaned
    $this->deleteJson("/api/studio/projects/{$project['id']}")->assertNoContent();
    expect(StudioFile::findOrFail($file['id'])->project_id)->toBeNull();
});
```

- [ ] **Step 2: Run test to verify it passes** (should pass since everything's built)

Run: `php artisan test --filter=StudioProjectsE2ETest`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add api/tests/Feature/Studio/StudioProjectsE2ETest.php
git commit -m "test(api): add e2e sanity test for studio projects + KV generation"
```

---

## Final Verification

- [ ] **Run the full API test suite**

```bash
cd api && php artisan test
```

Expected: all tests pass. Pay special attention to any test that previously referenced `App\Models\StudioProject` with file semantics — these should now reference `StudioFile`.

- [ ] **Run migrations on a real local DB**

```bash
cd api && php artisan migrate:fresh && php artisan db:seed
```

Expected: migrations run clean. Seeders adapted to new model names.

- [ ] **Manual smoke via tinker**

```bash
cd api && php artisan tinker
> $p = \App\Models\StudioProject::factory()->create([...]);
> $f = \App\Models\StudioFile::factory()->create([...'project_id' => $p->id]);
> $p->files->count(); // 1
> $p->delete();
> $f->fresh()->project_id; // null
```

---

## Self-Review Checklist

- Spec Data Model covered: ✓ (Tasks 1–8)
- Spec API Contracts covered: ✓ (Tasks 12–17)
- Internal signing / callback: ✓ (Tasks 15, 17)
- Chat extension for KV mode: ✓ (Task 16)
- Soft-delete orphaning behavior: ✓ (Task 11)
- Cross-brand move block: ✓ (Task 13)
- Activity taxonomy: ✓ (Task 18)
- E2E happy path: ✓ (Task 19)

**Out of scope for this plan (belongs in other plans):**
- ai-service `kv_generator` agent → see `-ai-service.md` plan
- web UI, routes, components → see `-web.md` plan
- Feature flag `NEXT_PUBLIC_STUDIO_PROJECTS_ENABLED` → web plan
- Wireframe → web plan

**Open items requiring stakeholder input (not blocking plan execution):**
- Style preset catalog (MVP list) — deferred to implementation per spec
- Chat history truncation strategy — deferred per spec
