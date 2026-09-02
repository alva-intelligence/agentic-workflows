# KV Resize — Rename a tile — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user give a resize tile a meaningful name, so `100 × 200 (2)` can read `Hero variant` instead — on the tile, the canvas, the panel, a public share link and the downloaded zip.

**Architecture:** One nullable `name` column on `kv_resize_exports`, and one authoritative fallback chain — `name ?? registry label ?? derived label ?? platform_id` — written in PHP. Six web surfaces already read the server-sent `platform_label` and inherit rename with zero edits. The four client-derived surfaces are *ranked second*, not deleted: a panel row can exist for a preset with no export, and there is nothing to name there.

**Tech Stack:** api — Laravel 13 / PHP 8.5, Pest, PostgreSQL. web — Next.js 16 / React 19, TypeScript, TanStack Query v5, `bun test` with Testing Library.

**Spec:** `docs/superpowers/specs/2026-09-02-kv-resize-rename-tile-design.md`

---

## Corrections to the spec — read before Task 1

The spec was written from inspection. Six things did not survive contact with the code. **Each is handled in the task that owns it; do not "fix" the spec back.**

| Spec says | Actual | Owning task |
|---|---|---|
| Share page: "add `platform_label` to `KvSharePayloadService.php:271`" and the resource chain covers it | `KvSharePayloadService` **hand-builds** its item array (`:270-289`) and never touches `KvResizeExportResource`. Writing the chain there would be a **second implementation** — the exact thing Approach A was chosen to prevent. **Fix:** extract the chain into one static helper and call it from both. | Task 3, Task 8 |
| Delete `platformLabel()` in `KvShareClient.tsx:24-26` | That helper is **shared with motion** (`item.ratio`, `:298` and `:307`), which has no registry entry. Deleting it breaks motion captions. **Fix:** keep the helper, switch only the two `kind === "resize"` branches. | Task 9 |
| Zip needs an in-archive `-2` collision suffix | The zip query is scoped to **one** `parent_generation_id` (`KvResizeExportController.php:466`) — the same scope names are unique within. A collision is unreachable. **Fix:** no suffix logic. Keep the empty-slug fallback, which IS reachable. | Task 10 |
| `whereNull('deleted_at')` matters because "the table soft-deletes" | The only delete path is `forceDelete()` (`:359`), deliberately — a tombstone would block `firstOrCreate` in `createBatch`. So trashed rows do not occur in practice. **Keep the clause** (it is correct, and `Rule::unique` bypasses the model's `SoftDeletes` scope either way) but do not write a test that manufactures a trashed row to prove a bug that cannot happen. | Task 4 |
| Comment breadcrumbs: "change what `tilePlatforms` carries" | `tilePlatformSig` **encodes with `:` and splits on `:`** (`KvResizeCanvas.tsx:502-514`), joined by `|`. A user-authored name containing `:` or `|` silently corrupts the map. **Fix:** change the encoding, not just the payload. | Task 11 |
| LayersPanel is a clean pattern to copy | Its Escape path sets `renamingId = null` and the **blur that follows still calls `commitRename`** — which no-ops there only because `commitRename` re-checks `renamingId`. Copy the guard, not the shape. Our commit must be idempotent for the same reason. | Task 12 |

## Global Constraints

- **The fallback chain has exactly ONE implementation.** After Task 3 it lives in `KvResizeExport::displayLabel()`. Anything needing a label calls that. If you find yourself typing `?? CustomResizeSize::labelFor(` a second time, stop — you are re-creating the drift `CustomResizeSize::labelFor`'s own docblock warns about.
- `null` name means **derive**. It is a meaningful value, not "unset": clearing the field is how a user un-renames. Never coalesce `null` to `''` in the model or the request.
- Name cap is **120** chars, matching `objects.*.label` in `UpdateKvResizeExportDetectionsRequest`.
- Names are unique **per `parent_generation_id`**, case-**sensitive**, enforced at the **validation** layer only. No DB unique index — it would surface a clash as a 500-shaped `UniqueConstraintViolationException` where a 422 is wanted.
- **A duplicate must never fail because of a name.** The `(copy N)` search returns `null` rather than throwing. A rename can 422; a duplicate cannot.
- Copy naming is **flat**: duplicating `Hero (copy)` gives `Hero (copy 2)`, never `Hero (copy) (copy)`.
- The rename route carries **no** `check.credits`. No model call, no credit.
- **No chat marker** for a rename, and `KvResizeChatMarkerService` is not touched at all. Markers are a frozen historical record.
- **One entry point:** the panel row. No canvas rename affordance — see the spec §4 for why.
- Rename is gated on `state === "done"`. A pending tile has no result to name.
- api Feature tests need a scratch PostgreSQL — SQLite cannot run this repo's
  migrations (`DROP SEQUENCE` is Postgres-only), and `phpunit.xml` pins
  `DB_CONNECTION=sqlite`. A shell env var DOES override that pin (verified), so
  every Feature-test command below is prefixed
  `DB_CONNECTION=pgsql DB_DATABASE=frnd_dup_tile_test TELESCOPE_ENABLED=false`.
  The scratch database `frnd_dup_tile_test` already exists. **Never** point a
  Feature test at `frnd` — that is the live dev database and `RefreshDatabase`
  would wipe it. Pass test **paths**, not `--filter`.
- web tests run with `bun test <path>` per file. **Never** on a directory — it has consumed tens of gigabytes here. Test files import from `"vitest"`; that is correct, do not "fix" it.
- Build with `node ./node_modules/next/dist/bin/next build`. `bun run build` is broken for unrelated reasons.
- Run `vendor/bin/pint --dirty --format agent` in `api/` before each api commit.

## Branch — decided

Daffa chose to **stack on the duplicate-tile branch** (2026-09-02). Rename has its own branch cut *from* it, in both repos:

```
feature/daffa/vc-kv-resize-rename-tile
  api  ← cut at 0486c71b
  web  ← cut at a0a076976
```

`feature/daffa/vc-kv-resize-duplicate-tile` itself is **not committed onto** — its 6 + 10 commits stay exactly as they were, still unpushed, so it remains PR-able on its own. Rename's commits land only on the rename branch.

**Consequence:** rename inherits duplicate's commits. A PR from rename targets `develop` carrying **both** features unless duplicate merges first. That is understood and accepted.

**All 15 tasks are buildable**, Task 6 included — the reason this branch point was chosen. Verified 2026-09-02:

| Path | On `develop`? | On this branch? |
|---|---|---|
| `KvResizeExportService::duplicate()` | **No** | Yes |
| `tests/Feature/Studio/KvResizeExportDuplicateTest.php` | **No** | Yes |
| `tests/Feature/Studio/KvResizeExportZipTest.php` | Yes | Yes |
| `app/Http/Resources/Studio/KvResizeExportResource.php` | Yes | Yes |

Had rename been cut from clean `develop`, Task 6 would have had nothing to edit.

---

### Task 1: The `name` column

**Files:**
- Create: `api/database/migrations/2026_09_02_000001_add_name_to_kv_resize_exports_table.php`
- Modify: `api/app/Models/KvResizeExport.php:20-34` (`$fillable`)

**Interfaces:**
- Consumes: nothing.
- Produces: `kv_resize_exports.name` — `string(120)`, nullable, no default. `KvResizeExport` accepts `name` as fillable.

**Note before you start:** the sibling `kv_motion_projects.name` has `->default('Untitled motion')`. Do **not** copy that. A default would mark every existing tile as named and permanently mask its derived label. No cast either — it is a plain string.

- [ ] **Step 1: Write the migration**

Create `api/database/migrations/2026_09_02_000001_add_name_to_kv_resize_exports_table.php`:

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
            // Nullable with no default: null means "derive the label from the
            // platform id". A default would mark every existing tile as named
            // and permanently mask its derived label. Deliberately unlike
            // kv_motion_projects.name, which defaults to 'Untitled motion'.
            //
            // No unique index: names are unique per parent_generation_id, but
            // a DB constraint would surface a clash as a 500-shaped
            // UniqueConstraintViolationException where the endpoint owes a 422.
            $table->string('name', 120)->nullable()->after('platform_id');
        });
    }

    public function down(): void
    {
        Schema::table('kv_resize_exports', function (Blueprint $table) {
            $table->dropColumn('name');
        });
    }
};
```

- [ ] **Step 2: Add `name` to `$fillable`**

In `api/app/Models/KvResizeExport.php`, add `'name'` immediately after `'platform_id'`:

```php
    protected $fillable = [
        'studio_file_id',
        'parent_generation_id',
        'created_by',
        'platform_id',
        'name',
        'width',
        'height',
```

Leave `$casts` alone.

- [ ] **Step 3: Migrate the scratch database and verify the column landed**

```bash
cd api && DB_CONNECTION=pgsql DB_DATABASE=frnd_dup_tile_test php artisan migrate
```

Expected: the new migration runs, `DONE`.

```bash
cd api && DB_CONNECTION=pgsql DB_DATABASE=frnd_dup_tile_test php artisan tinker --execute 'echo json_encode(Schema::getColumnListing("kv_resize_exports"));'
```

Expected: the output contains `"name"`.

- [ ] **Step 4: Confirm nothing regressed**

```bash
cd api && DB_CONNECTION=pgsql DB_DATABASE=frnd_dup_tile_test TELESCOPE_ENABLED=false ./vendor/bin/pest tests/Feature/Studio/KvResizeExportDuplicateTest.php
```

Expected: PASS, same count as before the migration.

- [ ] **Step 5: Commit**

```bash
cd api && vendor/bin/pint --dirty --format agent
git add database/migrations/2026_09_02_000001_add_name_to_kv_resize_exports_table.php app/Models/KvResizeExport.php
git commit -m "feat(api): add a nullable name column to kv_resize_exports"
```

---

### Task 2: `displayLabel()` — the one fallback chain

**Files:**
- Modify: `api/app/Models/KvResizeExport.php`
- Test: `api/tests/Unit/Models/KvResizeExportDisplayLabelTest.php` (create)

**Interfaces:**
- Consumes: `CustomResizeSize::labelFor()`, `config('studio.resize_platforms')`.
- Produces: `KvResizeExport::displayLabel(): string`.

**Note before you start:** this is the whole architectural bet. The chain currently lives inline in `KvResizeExportResource.php:22`. Task 3 replaces that with a call to this method, and Task 8 has the share payload call the *same* method. Two consumers is exactly why it moves onto the model instead of staying in the resource.

- [ ] **Step 1: Write the failing tests**

Create `api/tests/Unit/Models/KvResizeExportDisplayLabelTest.php`:

```php
<?php

use App\Models\KvResizeExport;
use Tests\TestCase;

uses(TestCase::class);

it('prefers a name over every derived label', function () {
    $row = new KvResizeExport([
        'platform_id' => 'custom-100x200-2',
        'name' => 'Hero variant',
        'width' => 100,
        'height' => 200,
    ]);

    expect($row->displayLabel())->toBe('Hero variant');
});

it('prefers a name over a registry preset label too', function () {
    $row = new KvResizeExport([
        'platform_id' => 'instagram-post',
        'name' => 'Launch post',
        'width' => 1080,
        'height' => 1080,
    ]);

    expect($row->displayLabel())->toBe('Launch post');
});

it('derives a custom label when there is no name', function () {
    $row = new KvResizeExport([
        'platform_id' => 'custom-100x200-2',
        'width' => 100,
        'height' => 200,
    ]);

    expect($row->displayLabel())->toBe('100 × 200 (2)');
});

it('uses the registry label when there is no name', function () {
    $row = new KvResizeExport([
        'platform_id' => 'instagram-post',
        'width' => 1080,
        'height' => 1080,
    ]);

    expect($row->displayLabel())->toBe('Instagram Post');
});

it('falls back to the raw platform id when nothing else resolves', function () {
    $row = new KvResizeExport([
        'platform_id' => 'not-a-real-platform',
        'width' => 10,
        'height' => 10,
    ]);

    expect($row->displayLabel())->toBe('not-a-real-platform');
});

it('treats an empty name as no name', function () {
    // The endpoint normalises '' to null before it ever reaches the column,
    // so this asserts the model does not trust that and go blank on a row
    // written by a migration, a seeder, or a future writer.
    $row = new KvResizeExport([
        'platform_id' => 'custom-100x200',
        'name' => '',
        'width' => 100,
        'height' => 200,
    ]);

    expect($row->displayLabel())->toBe('100 × 200');
});
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd api && ./vendor/bin/pest tests/Unit/Models/KvResizeExportDisplayLabelTest.php
```

Expected: FAIL — `Call to undefined method App\Models\KvResizeExport::displayLabel()`.

- [ ] **Step 3: Implement**

In `api/app/Models/KvResizeExport.php`, add the import and the method after the relations:

```php
use App\Support\Studio\CustomResizeSize;
```

```php
    /**
     * The human label for this tile, in one place.
     *
     * A user-given `name` wins; otherwise the platform registry answers for a
     * preset and `CustomResizeSize` derives `100 × 200 (2)` for a custom size;
     * the raw id is the last resort. `CustomResizeSize::labelFor`'s docblock
     * warns that this chain "was written out verbatim at every such site,
     * which is one place too many for the fallback to drift" — so it lives
     * here, and both the API resource and the public share payload call it
     * rather than each spelling it out.
     *
     * An empty-string name is treated as no name. The rename endpoint
     * normalises '' to null before writing, but a label must not go blank for
     * a row written by anything that did not.
     */
    public function displayLabel(): string
    {
        $name = trim((string) $this->name);

        if ($name !== '') {
            return $name;
        }

        $platformId = (string) $this->platform_id;
        $platform = collect(config('studio.resize_platforms'))
            ->firstWhere('id', $platformId) ?? [];

        return $platform['label']
            ?? CustomResizeSize::labelFor($platformId)
            ?? $platformId;
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd api && ./vendor/bin/pest tests/Unit/Models/KvResizeExportDisplayLabelTest.php
```

Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
cd api && vendor/bin/pint --dirty --format agent
git add app/Models/KvResizeExport.php tests/Unit/Models/KvResizeExportDisplayLabelTest.php
git commit -m "feat(api): put the resize tile label fallback chain on the model"
```

---

### Task 3: The resource calls `displayLabel()`

**Files:**
- Modify: `api/app/Http/Resources/Studio/KvResizeExportResource.php:22`
- Test: `api/tests/Unit/Resources/KvResizeExportResourceTest.php`

**Interfaces:**
- Consumes: `KvResizeExport::displayLabel()`.
- Produces: `platform_label` in the API resource now reflects `name`. The wire key does **not** change, which is why six web surfaces need no edit.

**Note before you start:** the resource keeps its own `$platform` lookup for `platform_group` (`:23`), so do not delete those two lines when you replace `:22`. `CustomResizeSize` stays imported for `isCustomId` on the group line.

- [ ] **Step 1: Write the failing test**

Append to `api/tests/Unit/Resources/KvResizeExportResourceTest.php`:

```php
it('prefers a tile name over the derived label', function () {
    $row = new KvResizeExport([
        'platform_id' => 'custom-1240x1750',
        'name' => 'Hero variant',
        'width' => 1240,
        'height' => 1750,
    ]);

    $out = (new KvResizeExportResource($row))->toArray(request());

    expect($out['platform_label'])->toBe('Hero variant');
    // The group still comes from the id, not the name — a renamed custom tile
    // is still a custom tile.
    expect($out['platform_group'])->toBe('custom');
});

it('prefers a tile name over a preset registry label', function () {
    $row = new KvResizeExport([
        'platform_id' => 'instagram-post',
        'name' => 'Launch post',
        'width' => 1080,
        'height' => 1080,
    ]);

    $out = (new KvResizeExportResource($row))->toArray(request());

    expect($out['platform_label'])->toBe('Launch post');
    expect($out['platform_group'])->toBe('social-media');
});
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd api && ./vendor/bin/pest tests/Unit/Resources/KvResizeExportResourceTest.php
```

Expected: FAIL — `platform_label` is `'1240 × 1750'`, not `'Hero variant'`.

- [ ] **Step 3: Implement**

In `api/app/Http/Resources/Studio/KvResizeExportResource.php`, replace line 22:

```php
            'platform_label' => $platform['label'] ?? CustomResizeSize::labelFor($platformId) ?? $this->platform_id,
```

with:

```php
            // Chain lives on the model: the public share payload needs the
            // same answer and must not spell it a second time.
            'platform_label' => $this->resource->displayLabel(),
```

Leave `:13-15` and the `platform_group` line untouched.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd api && ./vendor/bin/pest tests/Unit/Resources/KvResizeExportResourceTest.php
```

Expected: PASS, 4 tests — the two existing label tests still pass, proving `null` name changes nothing.

- [ ] **Step 5: Commit**

```bash
cd api && vendor/bin/pint --dirty --format agent
git add app/Http/Resources/Studio/KvResizeExportResource.php tests/Unit/Resources/KvResizeExportResourceTest.php
git commit -m "feat(api): resize resource label reads the model's chain"
```

---

### Task 4: `KvResizeExportRenameRequest`

**Files:**
- Create: `api/app/Http/Requests/Studio/KvResizeExportRenameRequest.php`
- Test: covered by Task 5's feature test (a FormRequest in isolation cannot see the route's `{export}`).

**Interfaces:**
- Consumes: route parameter `export` (the `KvResizeExport` id).
- Produces: validated `name` — `string|null`, `<= 120` chars, unique among live rows under the same `parent_generation_id`.

**Note before you start:** `present` + `nullable`, **not** `sometimes`. `null` is the un-rename path; `sometimes` would make an omitted key a silent no-op and the caller would never learn the request did nothing. The `excludeUnvalidatedArrayKeys` trap in the spec concerns `payload.*` **array** rules — this is a flat scalar and is unaffected.

- [ ] **Step 1: Write the FormRequest**

Create `api/app/Http/Requests/Studio/KvResizeExportRenameRequest.php`:

```php
<?php

namespace App\Http\Requests\Studio;

use App\Models\KvResizeExport;
use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Validation\Rule;

class KvResizeExportRenameRequest extends FormRequest
{
    public function authorize(): bool
    {
        // Workspace and file-ownership checks live in the controller, beside
        // the identical checks on regenerate/editRegion.
        return true;
    }

    public function rules(): array
    {
        $export = KvResizeExport::find($this->route('export'));

        return [
            // `present` + `nullable`, NOT `sometimes`: null is a meaningful
            // value — it is how a user clears a name and returns to the
            // derived label. With `sometimes`, an omitted key would be a
            // silent no-op the caller could not detect.
            'name' => [
                'present',
                'nullable',
                'string',
                'max:120',
                // Uniqueness is enforced HERE rather than by a DB index: an
                // index would raise UniqueConstraintViolationException, a
                // 500 shape, where this endpoint owes a 422.
                //
                // Scoped to the parent generation, so the same name may be
                // reused on a different KV. `whereNull('deleted_at')` because
                // Rule::unique queries the table directly and bypasses the
                // model's SoftDeletes scope.
                Rule::unique('kv_resize_exports', 'name')
                    ->where(fn ($query) => $query
                        ->where('parent_generation_id', $export?->parent_generation_id)
                        ->whereNull('deleted_at'))
                    ->ignore($export?->id),
            ],
        ];
    }

    public function messages(): array
    {
        return [
            'name.unique' => 'That name is already used on this KV.',
        ];
    }
}
```

- [ ] **Step 2: Verify it parses**

```bash
cd api && php -l app/Http/Requests/Studio/KvResizeExportRenameRequest.php
```

Expected: `No syntax errors detected`.

- [ ] **Step 3: Commit**

```bash
cd api && vendor/bin/pint --dirty --format agent
git add app/Http/Requests/Studio/KvResizeExportRenameRequest.php
git commit -m "feat(api): add the resize tile rename form request"
```

---

### Task 5: The `updateName` endpoint

**Files:**
- Modify: `api/routes/api.php` (~`:4132`, beside the overlays PATCH)
- Modify: `api/app/Http/Controllers/Api/Studio/KvResizeExportController.php`
- Test: `api/tests/Feature/Studio/KvResizeExportRenameTest.php` (create)

**Interfaces:**
- Consumes: `KvResizeExportRenameRequest`.
- Produces: `PATCH v1/studio/files/{file}/resize-exports/{export}/name` → `200` with a `KvResizeExportResource`. `403` cross-workspace, `404` wrong file, `422` duplicate name or over-length.

**Note before you start:** do **not** extend the overlays PATCH route — add a sibling. No `check.credits`. **No custom-id guard**: presets are renamable (decision 3), unlike `duplicate`, which stays custom-only at `:236`. Copy the guard pair from `regenerate` (`:184-189`) verbatim.

- [ ] **Step 1: Write the failing tests**

Create `api/tests/Feature/Studio/KvResizeExportRenameTest.php`. Reuse `KvResizeExportDuplicateTest.php`'s `beforeEach` — copy it verbatim (user, workspace, role, credits, tool, file, generation, `actingAs`), then add:

```php
beforeEach(function () {
    $this->export = KvResizeExport::factory()->create([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $this->generation->id,
        'created_by' => $this->user->id,
        'platform_id' => 'custom-100x200',
        'width' => 100,
        'height' => 200,
        'status' => KvResizeExportStatus::Done,
    ]);

    $this->url = "/api/v1/studio/files/{$this->file->id}"
        ."/resize-exports/{$this->export->id}/name";
});

it('names a custom tile', function () {
    $this->patchJson($this->url, ['name' => 'Hero variant'])
        ->assertOk()
        ->assertJsonPath('data.name', 'Hero variant')
        ->assertJsonPath('data.platform_label', 'Hero variant');

    expect($this->export->fresh()->name)->toBe('Hero variant');
});

it('names a preset tile too', function () {
    $preset = KvResizeExport::factory()->create([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $this->generation->id,
        'created_by' => $this->user->id,
        'platform_id' => 'instagram-post',
        'width' => 1080,
        'height' => 1080,
        'status' => KvResizeExportStatus::Done,
    ]);

    $this->patchJson(
        "/api/v1/studio/files/{$this->file->id}/resize-exports/{$preset->id}/name",
        ['name' => 'Launch post'],
    )->assertOk()->assertJsonPath('data.platform_label', 'Launch post');
});

it('trims a name', function () {
    $this->patchJson($this->url, ['name' => '  Hero variant  '])->assertOk();

    expect($this->export->fresh()->name)->toBe('Hero variant');
});

it('clears a name and returns to the derived label', function () {
    $this->export->update(['name' => 'Hero variant']);

    $this->patchJson($this->url, ['name' => null])
        ->assertOk()
        ->assertJsonPath('data.platform_label', '100 × 200');

    expect($this->export->fresh()->name)->toBeNull();
});

it('treats a blank submit as clearing the name', function () {
    $this->export->update(['name' => 'Hero variant']);

    $this->patchJson($this->url, ['name' => '   '])->assertOk();

    expect($this->export->fresh()->name)->toBeNull();
});

it('rejects a missing name key rather than silently doing nothing', function () {
    $this->patchJson($this->url, [])
        ->assertStatus(422)
        ->assertJsonValidationErrors('name');
});

it('rejects a duplicate name under the same parent', function () {
    KvResizeExport::factory()->create([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $this->generation->id,
        'created_by' => $this->user->id,
        'platform_id' => 'custom-100x200-2',
        'name' => 'Hero variant',
        'width' => 100,
        'height' => 200,
        'status' => KvResizeExportStatus::Done,
    ]);

    $this->patchJson($this->url, ['name' => 'Hero variant'])
        ->assertStatus(422)
        ->assertJsonPath('errors.name.0', 'That name is already used on this KV.');
});

it('allows the same name under a different parent', function () {
    $other = KvGeneration::factory()->create([
        'studio_file_id' => $this->file->id,
        'version_number' => 2,
        'image_url' => 'https://example.com/source-2.png',
        'created_by' => $this->user->id,
    ]);
    KvResizeExport::factory()->create([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $other->id,
        'created_by' => $this->user->id,
        'platform_id' => 'custom-100x200',
        'name' => 'Hero variant',
        'width' => 100,
        'height' => 200,
        'status' => KvResizeExportStatus::Done,
    ]);

    $this->patchJson($this->url, ['name' => 'Hero variant'])->assertOk();
});

it('lets a tile keep its own name on a no-op rename', function () {
    $this->export->update(['name' => 'Hero variant']);

    // Without ->ignore() the row would collide with itself.
    $this->patchJson($this->url, ['name' => 'Hero variant'])->assertOk();
});

it('is case sensitive', function () {
    KvResizeExport::factory()->create([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $this->generation->id,
        'created_by' => $this->user->id,
        'platform_id' => 'custom-100x200-2',
        'name' => 'Hero',
        'width' => 100,
        'height' => 200,
        'status' => KvResizeExportStatus::Done,
    ]);

    $this->patchJson($this->url, ['name' => 'hero'])->assertOk();
});

it('accepts a name at the 120-char boundary and rejects one past it', function () {
    $this->patchJson($this->url, ['name' => str_repeat('a', 120)])->assertOk();

    $this->patchJson($this->url, ['name' => str_repeat('b', 121)])
        ->assertStatus(422)
        ->assertJsonValidationErrors('name');
});

it('refuses a tile in another workspace', function () {
    $otherWorkspace = Workspace::factory()->create(['type' => 'organization']);
    $this->file->update(['workspace_id' => $otherWorkspace->id]);

    $this->patchJson($this->url, ['name' => 'Hero variant'])->assertStatus(403);
});

it('refuses a tile that belongs to another file', function () {
    $otherFile = StudioFile::factory()->create([
        'workspace_id' => $this->workspace->id,
        'brand_id' => $this->brand->id,
        'tool_id' => $this->file->tool_id,
        'created_by' => $this->user->id,
        'last_edited_by' => $this->user->id,
    ]);

    $this->patchJson(
        "/api/v1/studio/files/{$otherFile->id}/resize-exports/{$this->export->id}/name",
        ['name' => 'Hero variant'],
    )->assertStatus(404);
});

it('writes no chat marker', function () {
    $before = \App\Models\UserChatHistory::count();

    $this->patchJson($this->url, ['name' => 'Hero variant'])->assertOk();

    expect(\App\Models\UserChatHistory::count())->toBe($before);
});
```

**Before running:** confirm the chat-history model name and table with
`ls app/Models | grep -i chat`, and confirm the route prefix by
`php artisan route:list --path=resize-exports`. Fix the two references above to match what you find rather than guessing.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd api && DB_CONNECTION=pgsql DB_DATABASE=frnd_dup_tile_test TELESCOPE_ENABLED=false ./vendor/bin/pest tests/Feature/Studio/KvResizeExportRenameTest.php
```

Expected: FAIL — every request 404s, the route does not exist.

- [ ] **Step 3: Add the route**

In `api/routes/api.php`, directly after the overlays PATCH block (~`:4132-4139`):

```php
                            // No check.credits: a rename calls no model.
                            // Its own route rather than a key on the overlays
                            // PATCH — `excludeUnvalidatedArrayKeys` has
                            // previously stripped an entire overlay payload,
                            // and a name has no business sharing that blast
                            // radius.
                            Route::patch(
                                'files/{file}/resize-exports/{export}/name',
                                [
                                    KvResizeExportController::class,
                                    'updateName',
                                ],
                            );
```

- [ ] **Step 4: Implement the controller method**

In `api/app/Http/Controllers/Api/Studio/KvResizeExportController.php`, add the import:

```php
use App\Http\Requests\Studio\KvResizeExportRenameRequest;
```

and add the method after `duplicate()`:

```php
    /**
     * Name a tile, or clear its name.
     *
     * No credits and no marker — a rename is display metadata, not a
     * generation event. Unlike `duplicate` there is no custom-id guard: a
     * preset tile is renamable too.
     */
    public function updateName(
        KvResizeExportRenameRequest $request,
        string $fileId,
        string $exportId
    ): JsonResponse {
        $file = StudioFile::findOrFail($fileId);
        abort_unless($file->workspace_id === $request->user()->current_workspace_id, 403);

        $export = KvResizeExport::findOrFail($exportId);
        abort_unless($export->studio_file_id === $file->id, 404);

        // Same normalisation regenerate applies to additional_prompt: a blank
        // submit is how a user clears the name, so '' becomes null rather
        // than a name that renders as an empty label.
        $nameRaw = trim((string) ($request->validated()['name'] ?? ''));
        $export->update(['name' => $nameRaw === '' ? null : $nameRaw]);

        return response()->json([
            'data' => (new KvResizeExportResource($export))->resolve(),
        ]);
    }
```

Also add `'name' => $this->name,` to the resource array in
`api/app/Http/Resources/Studio/KvResizeExportResource.php`, directly after
`'platform_id'` — the tests assert `data.name`, and web needs the raw value to
pre-fill the edit input (a derived label must not become a real name just
because someone opened the field).

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd api && DB_CONNECTION=pgsql DB_DATABASE=frnd_dup_tile_test TELESCOPE_ENABLED=false ./vendor/bin/pest tests/Feature/Studio/KvResizeExportRenameTest.php tests/Unit/Resources/KvResizeExportResourceTest.php
```

Expected: PASS, all tests.

- [ ] **Step 6: Commit**

```bash
cd api && vendor/bin/pint --dirty --format agent
git add routes/api.php app/Http/Controllers/Api/Studio/KvResizeExportController.php app/Http/Resources/Studio/KvResizeExportResource.php tests/Feature/Studio/KvResizeExportRenameTest.php
git commit -m "feat(api): add a rename endpoint for resize tiles"
```

---

### Task 6: The `(copy N)` free-name search

**Files:**
- Modify: `api/app/Services/Studio/KvResizeExportService.php` (`duplicate()` `:110-157`)
- Test: `api/tests/Feature/Studio/KvResizeExportDuplicateTest.php`

**Interfaces:**
- Consumes: the source row's `name`, sibling rows under the same parent.
- Produces: `duplicate()` now sets `name` on the copy. Private `copyName(KvResizeExport $source): ?string`.

**Note before you start:** three hard rules. (1) **It must never throw** — a duplicate failing because of a *name* is unacceptable, so exhaustion returns `null`. (2) The suffix cannot break the 120-char cap; the base gets truncated instead. (3) Flat, never nested: strip an existing `(copy)`/`(copy N)` off the source before appending. Presets never reach here — `duplicate` stays guarded to custom ids at the controller (`:236`) — so no preset-specific base rule is needed.

- [ ] **Step 1: Write the failing tests**

Append to `api/tests/Feature/Studio/KvResizeExportDuplicateTest.php`:

```php
it('names a copy after its source', function () {
    $this->source->update(['name' => 'Hero variant']);

    $row = app(KvResizeExportService::class)
        ->duplicate($this->source, $this->user->id);

    expect($row->name)->toBe('Hero variant (copy)');
});

it('leaves an unnamed copy unnamed', function () {
    $row = app(KvResizeExportService::class)
        ->duplicate($this->source, $this->user->id);

    expect($row->name)->toBeNull();
});

it('counts up when the plain copy name is taken', function () {
    $this->source->update(['name' => 'Hero variant']);
    $service = app(KvResizeExportService::class);

    $first = $service->duplicate($this->source, $this->user->id);
    $second = $service->duplicate($this->source, $this->user->id);

    expect($first->name)->toBe('Hero variant (copy)');
    expect($second->name)->toBe('Hero variant (copy 2)');
});

it('keeps copy names flat rather than nesting them', function () {
    $this->source->update(['name' => 'Hero variant (copy)']);

    $row = app(KvResizeExportService::class)
        ->duplicate($this->source, $this->user->id);

    // Not 'Hero variant (copy) (copy)'.
    expect($row->name)->toBe('Hero variant (copy 2)');
});

it('flattens a numbered copy name too', function () {
    $this->source->update(['name' => 'Hero variant (copy 2)']);

    $row = app(KvResizeExportService::class)
        ->duplicate($this->source, $this->user->id);

    expect($row->name)->toBe('Hero variant (copy)');
});

it('truncates the base rather than exceeding the column', function () {
    $this->source->update(['name' => str_repeat('a', 120)]);

    $row = app(KvResizeExportService::class)
        ->duplicate($this->source, $this->user->id);

    expect(mb_strlen((string) $row->name))->toBeLessThanOrEqual(120);
    expect($row->name)->toEndWith(' (copy)');
});

it('duplicates without a name rather than failing when no name is free', function () {
    $this->source->update(['name' => 'Hero']);
    $service = app(KvResizeExportService::class);

    // Occupy 'Hero (copy)' and 'Hero (copy 2)'..'(copy 50)' — past the search
    // ceiling — then prove the duplicate still SUCCEEDS.
    KvResizeExport::factory()->create([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $this->generation->id,
        'created_by' => $this->user->id,
        'platform_id' => 'custom-999x999',
        'name' => 'Hero (copy)',
        'width' => 999,
        'height' => 999,
        'status' => KvResizeExportStatus::Done,
    ]);
    for ($n = 2; $n <= 50; $n++) {
        KvResizeExport::factory()->create([
            'studio_file_id' => $this->file->id,
            'parent_generation_id' => $this->generation->id,
            'created_by' => $this->user->id,
            'platform_id' => "custom-999x{$n}",
            'name' => "Hero (copy {$n})",
            'width' => 999,
            'height' => $n,
            'status' => KvResizeExportStatus::Done,
        ]);
    }

    $row = $service->duplicate($this->source, $this->user->id);

    expect($row->id)->not->toBeNull();
    expect($row->name)->toBeNull();
});
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd api && DB_CONNECTION=pgsql DB_DATABASE=frnd_dup_tile_test TELESCOPE_ENABLED=false ./vendor/bin/pest tests/Feature/Studio/KvResizeExportDuplicateTest.php
```

Expected: FAIL on the new name assertions; the pre-existing duplicate tests still pass.

- [ ] **Step 3: Implement**

In `api/app/Services/Studio/KvResizeExportService.php`, add `'name' => $this->copyName($source),` to the `KvResizeExport::create([...])` array in `duplicate()`, directly after `'platform_id' => ...`, then add these two private methods beside `nextOrdinal()`:

```php
    /**
     * Ceiling on the (copy N) search. Well past any real use; the point is
     * that the loop is bounded, because the caller must not be able to fail.
     */
    private const COPY_NAME_LIMIT = 50;

    /**
     * A free name for a copy of `$source`, or null.
     *
     * Never throws and never returns a taken name: a duplicate failing
     * because of its NAME would be a worse outcome than an unnamed copy, so
     * exhaustion falls back to null and the copy derives its label from the
     * platform id like any unnamed tile.
     *
     * Names are flattened rather than nested — a copy of "Hero (copy)" is
     * "Hero (copy 2)", not "Hero (copy) (copy)". Uniqueness is enforced by
     * this search rather than by KvResizeExportRenameRequest, which
     * `duplicate()` does not run.
     */
    private function copyName(KvResizeExport $source): ?string
    {
        $sourceName = trim((string) $source->name);

        if ($sourceName === '') {
            return null;
        }

        // Strip an existing "(copy)" / "(copy N)" so suffixes stay flat.
        $base = preg_replace('/\s*\(copy(?:\s+\d+)?\)$/', '', $sourceName) ?? $sourceName;
        $base = trim($base);

        if ($base === '') {
            $base = $sourceName;
        }

        $taken = KvResizeExport::query()
            ->where('parent_generation_id', $source->parent_generation_id)
            ->whereNotNull('name')
            ->pluck('name')
            ->all();

        for ($n = 1; $n <= self::COPY_NAME_LIMIT; $n++) {
            $suffix = $n === 1 ? ' (copy)' : " (copy {$n})";
            // Truncate the BASE, not the finished name: chopping the tail
            // would produce "Hero (cop" and lose the only part that says
            // what this row is.
            $room = 120 - mb_strlen($suffix);
            $candidate = mb_substr($base, 0, max(0, $room)).$suffix;

            if (! in_array($candidate, $taken, true)) {
                return $candidate;
            }
        }

        return null;
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd api && DB_CONNECTION=pgsql DB_DATABASE=frnd_dup_tile_test TELESCOPE_ENABLED=false ./vendor/bin/pest tests/Feature/Studio/KvResizeExportDuplicateTest.php
```

Expected: PASS, all tests including the seven new ones.

- [ ] **Step 5: Commit**

```bash
cd api && vendor/bin/pint --dirty --format agent
git add app/Services/Studio/KvResizeExportService.php tests/Feature/Studio/KvResizeExportDuplicateTest.php
git commit -m "feat(api): name a duplicated tile after its source"
```

---

### Task 7: `platform_label` in the share payload

**Files:**
- Modify: `api/app/Services/Studio/KvSharePayloadService.php` (~`:270-289`)
- Test: `api/tests/Feature/Studio/` — find the existing public-share test with `ls tests/Feature/Studio | grep -i -E "share|public"` and extend it. Create `KvSharePayloadResizeNameTest.php` only if none exists.

**Interfaces:**
- Consumes: `KvResizeExport::displayLabel()`.
- Produces: `platform_label` on every `kind: "resize"` item in the public payload.

**Note before you start:** this service **hand-builds** its item array and never touches `KvResizeExportResource`. That is why Task 2 put the chain on the model — call `displayLabel()` here, do **not** re-spell the fallback. **Privacy:** this newly publishes user-authored text on a public link. Intended (decision 4), and within `PublicKvController`'s stated contract, which already publishes board names — but it is a deliberate choice, not an accident.

- [ ] **Step 1: Write the failing test**

Locate the existing share test first:

```bash
cd api && ls tests/Feature/Studio | grep -i -E "share|public"
```

Add to whichever file covers the resize items in a public payload:

```php
it('publishes a renamed tile under its name', function () {
    // Adapt the arrangement to the file's own beforeEach — the point of the
    // test is the two assertions below.
    $tile->update(['name' => 'Hero variant']);

    // ... build the payload the way the surrounding tests do ...

    expect($item['platform_label'])->toBe('Hero variant');
});

it('publishes a derived label when a tile has no name', function () {
    // $tile has platform_id 'custom-100x200' and no name.
    expect($item['platform_label'])->toBe('100 × 200');
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd api && DB_CONNECTION=pgsql DB_DATABASE=frnd_dup_tile_test TELESCOPE_ENABLED=false ./vendor/bin/pest tests/Feature/Studio/<the-share-test-file>.php
```

Expected: FAIL — `platform_label` is not a key on the item.

- [ ] **Step 3: Implement**

In `api/app/Services/Studio/KvSharePayloadService.php`, add one line to the `$items[] = [...]` array directly after `'platform_id' => $tile->platform_id,`:

```php
                // A guest reads "Hero variant", not custom-100x200-2. Routed
                // through the model rather than re-spelling the fallback
                // chain: this payload is hand-built and does NOT go through
                // KvResizeExportResource, so the chain has two callers and
                // exactly one implementation.
                'platform_label' => $tile->displayLabel(),
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd api && DB_CONNECTION=pgsql DB_DATABASE=frnd_dup_tile_test TELESCOPE_ENABLED=false ./vendor/bin/pest tests/Feature/Studio/<the-share-test-file>.php
```

Expected: PASS.

- [ ] **Step 5: Run the whole resize + share suite before handing off to web**

```bash
cd api && DB_CONNECTION=pgsql DB_DATABASE=frnd_dup_tile_test TELESCOPE_ENABLED=false ./vendor/bin/pest tests/Feature/Studio/KvResizeExportControllerTest.php tests/Feature/Studio/KvResizeExportDuplicateTest.php tests/Feature/Studio/KvResizeExportRenameTest.php tests/Feature/Studio/KvResizeExportZipTest.php tests/Unit/Resources/KvResizeExportResourceTest.php tests/Unit/Models/KvResizeExportDisplayLabelTest.php
```

Expected: PASS across the board.

- [ ] **Step 6: Commit**

```bash
cd api && vendor/bin/pint --dirty --format agent
git add app/Services/Studio/KvSharePayloadService.php tests/Feature/Studio/
git commit -m "feat(api): publish the tile label on public share links"
```

---

### Task 8: Zip entry names use the tile name

**Files:**
- Modify: `api/app/Http/Controllers/Api/Studio/KvResizeExportController.php:483-497`
- Test: `api/tests/Feature/Studio/KvResizeExportZipTest.php`

**Interfaces:**
- Consumes: the row's `name`.
- Produces: zip entry `hero-variant.png` for a named tile; unchanged names for unnamed tiles.

**Note before you start:** the spec's in-archive `-2` collision guard is **not needed** — the query is scoped to one `parent_generation_id` (`:466`), which is exactly the scope names are unique within. The empty-slug fallback IS needed: an all-emoji name slugifies to nothing. Reuse the slug expression already at `:500`, do not invent a second dialect.

- [ ] **Step 1: Write the failing tests**

Append to `api/tests/Feature/Studio/KvResizeExportZipTest.php`, following the file's own arrangement:

```php
it('names a zip entry after the tile name', function () {
    // ... arrange a done tile with an image_url, per this file's pattern ...
    $tile->update(['name' => 'Hero variant']);

    // ... download and open the archive the way the sibling tests do ...

    expect($entries)->toContain('hero-variant.png');
});

it('falls back to the platform-id form when a name slugifies to nothing', function () {
    $tile->update(['name' => '🎨🎨🎨']);

    expect($entries)->toContain('100x200.png');
});

it('leaves an unnamed tile entry alone', function () {
    // Regression guard on the existing template.
    expect($entries)->toContain('100x200.png');
});
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd api && DB_CONNECTION=pgsql DB_DATABASE=frnd_dup_tile_test TELESCOPE_ENABLED=false ./vendor/bin/pest tests/Feature/Studio/KvResizeExportZipTest.php
```

Expected: FAIL — the named tile still lands as `100x200.png`.

- [ ] **Step 3: Implement**

In `downloadZip()`, replace the `$name = ...` assignment (`:487-495`) with:

```php
            // A name the user chose beats a generated one. Slugified with the
            // SAME expression as the archive name below rather than a second
            // dialect. An all-emoji name slugifies to nothing, so it falls
            // through to the generated form.
            //
            // No in-archive collision suffix: this query is scoped to one
            // parent_generation_id, which is exactly the scope tile names are
            // unique within, so two entries cannot collide on a name.
            $named = trim((string) $row->name) === ''
                ? null
                : trim((string) preg_replace(
                    '/[^A-Za-z0-9_-]+/',
                    '-',
                    (string) $row->name,
                ), '-');

            $custom = CustomResizeSize::parse($row->platform_id);
            $generated = $custom === null
                ? "{$row->platform_id}-{$row->width}x{$row->height}.png"
                : substr(CustomResizeSize::id(
                    $custom['width'],
                    $custom['height'],
                    $custom['ordinal'],
                ), strlen('custom-')).'.png';

            $name = $named === null || $named === ''
                ? $generated
                : "{$named}.png";
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd api && DB_CONNECTION=pgsql DB_DATABASE=frnd_dup_tile_test TELESCOPE_ENABLED=false ./vendor/bin/pest tests/Feature/Studio/KvResizeExportZipTest.php
```

Expected: PASS, including the pre-existing entry-name tests.

- [ ] **Step 5: Commit**

```bash
cd api && vendor/bin/pint --dirty --format agent
git add app/Http/Controllers/Api/Studio/KvResizeExportController.php tests/Feature/Studio/KvResizeExportZipTest.php
git commit -m "feat(api): zip entries use the tile name when it has one"
```

---

### Task 9: web — wire type, mapper, and the rename call

**Files:**
- Modify: `web/src/services/kv/api.ts:772-806` (`WireResizeExport`, `toResizeExport`) and add `renameResizeExport`
- Modify: `web/src/types/kv/resize.ts` (`KvResizeExport`)
- Test: none — a type-and-transport change with no branch. Task 12 covers it end to end.

**Interfaces:**
- Consumes: `PATCH v1/studio/files/{fileId}/resize-exports/{exportId}/name`.
- Produces: `KvResizeExport.name: string | null`; `renameResizeExport(fileId, exportId, name): Promise<KvResizeExport>`.

**Note before you start:** `platformLabel` already carries the name after Task 3, so most of web needs nothing. `name` is carried **separately** because the edit input must pre-fill the *raw* name — pre-filling a derived label would turn `100 × 200` into a real stored name the moment someone opened the field and pressed Enter.

- [ ] **Step 1: Add `name` to the wire type and the mapper**

In `web/src/services/kv/api.ts`, add to `WireResizeExport` after `platform_id`:

```ts
  /** The user-given name, or null when the tile derives its label. Carried
   *  separately from `platform_label` (which already reflects it) because the
   *  rename input must pre-fill the RAW name — pre-filling a derived label
   *  would turn it into a real stored name on the next Enter. */
  name: string | null;
```

and to `toResizeExport`'s returned object after `platformId`:

```ts
    name: w.name,
```

- [ ] **Step 2: Add `name` to the domain type**

In `web/src/types/kv/resize.ts`, add `name: string | null;` to `KvResizeExport` beside `platformLabel`. Read the interface first and match its comment style.

- [ ] **Step 3: Add the request function**

Append to the Resize Exports section of `web/src/services/kv/api.ts`, beside `duplicateResizeExport`:

```ts
/** Name a tile, or clear its name with `null`. The server owns the fallback,
 *  so the response's `platform_label` is already what the UI should show. */
export async function renameResizeExport(
  fileId: string,
  exportId: string,
  name: string | null,
): Promise<KvResizeExport> {
  const { data } = await axiosInstance.patch(
    `v1/studio/files/${fileId}/resize-exports/${exportId}/name`,
    { name },
  );
  return toResizeExport(unwrap<WireResizeExport>(data));
}
```

- [ ] **Step 4: Typecheck the touched files against the baseline**

```bash
cd web && npx tsc --noEmit 2>&1 | grep -E "services/kv/api|types/kv/resize"
```

Expected: no output. (`tsc` has an ~810-error baseline repo-wide; diff by `file:line`, never by total.)

- [ ] **Step 5: Commit**

```bash
cd web && git add src/services/kv/api.ts src/types/kv/resize.ts
git commit -m "feat(web): carry the tile name and add the rename request"
```

---

### Task 10: web — the rename mutation

**Files:**
- Modify: `web/src/lib/studio/kv/useResizeExports.ts`
- Modify: `web/src/lib/analytics/kv-generator-events.ts`
- Test: `web/src/lib/studio/kv/useResizeExports.test.ts` if one exists (`ls src/lib/studio/kv | grep test`); otherwise covered by Task 12.

**Interfaces:**
- Consumes: `renameResizeExport`, `resizeErrorMessage`, `useToastStore`.
- Produces: `rename` mutation on the `useResizeExports` return object. Two PostHog events.

**Note before you start:** this is **optimistically applied with rollback**, unlike `editRegion`'s plain row-replace. A 422 for a duplicate name is an *expected* outcome, and without rollback the label would flicker into the new name and back. Copy `updateOverlays`'s `onMutate`/`onError` shape (`:371-396`) — it already does exactly this.

- [ ] **Step 1: Add the analytics wrappers**

Append to `web/src/lib/analytics/kv-generator-events.ts`, after the duplicate pair:

```ts
export interface KvResizeTileRenamedProps {
  export_id: string;
  platform_id: string;
  /** Length only, never the name. A tile name is user-authored free text and
   *  could carry a client identifier into analytics. */
  name_length: number;
  /** True when the user blanked the field to return to the derived label —
   *  how we learn whether people revert. */
  cleared: boolean;
}

export const trackKvResizeTileRenamed = (p: KvResizeTileRenamedProps) =>
  safeCapture("kv_generator.resize_tile_renamed", p);

export interface KvResizeTileRenameFailedProps {
  export_id: string;
  error_reason: string;
  http_status: number | null;
}

/** The other half of the pair. A rename's expected failure is a 422 on a
 *  duplicate name, and a success-only event would make the whole
 *  reject-duplicates decision invisible. */
export const trackKvResizeTileRenameFailed = (
  p: KvResizeTileRenameFailedProps,
) => safeCapture("kv_generator.resize_tile_rename_failed", p);
```

- [ ] **Step 2: Add the mutation**

In `web/src/lib/studio/kv/useResizeExports.ts`: add `renameResizeExport` to the `@/services/kv/api` import, add `trackKvResizeTileRenamed` and `trackKvResizeTileRenameFailed` to the analytics import, then add after `duplicate`:

```ts
  // Optimistic WITH rollback, unlike editRegion's plain row-replace: a 422 on
  // a duplicate name is an expected outcome here, not an exception, and
  // without the rollback the label would flicker into the new name and back
  // on a normal rejection.
  const rename = useMutation({
    mutationFn: (vars: { exportId: string; name: string | null }) =>
      renameResizeExport(fileId, vars.exportId, vars.name),
    onMutate: async (vars) => {
      await qc.cancelQueries({
        queryKey: QUERY_KEY(fileId, parentGenerationId),
      });
      const previous = qc.getQueryData<KvResizeExport[]>(
        QUERY_KEY(fileId, parentGenerationId)
      );
      // The server owns the fallback chain, so a cleared name cannot be
      // resolved to its derived label here. Showing the raw platform id for
      // one round trip would be a visible glitch, so a clear is NOT applied
      // optimistically — only a set is.
      if (vars.name !== null) {
        qc.setQueryData<KvResizeExport[]>(
          QUERY_KEY(fileId, parentGenerationId),
          (prev) =>
            (prev ?? []).map((r) =>
              r.id === vars.exportId
                ? { ...r, name: vars.name, platformLabel: vars.name as string }
                : r
            )
        );
      }
      return { previous };
    },
    onSuccess: (row, vars) => {
      qc.setQueryData<KvResizeExport[]>(
        QUERY_KEY(fileId, parentGenerationId),
        (prev) => (prev ?? []).map((r) => (r.id === row.id ? row : r))
      );
      trackKvResizeTileRenamed({
        export_id: row.id,
        platform_id: row.platformId,
        name_length: (vars.name ?? "").length,
        cleared: vars.name === null,
      });
    },
    onError: (error, vars, context) => {
      if (context?.previous) {
        qc.setQueryData(
          QUERY_KEY(fileId, parentGenerationId),
          context.previous
        );
      }
      trackKvResizeTileRenameFailed({
        export_id: vars.exportId,
        error_reason: error instanceof Error ? error.message : "unknown",
        http_status:
          (error as { response?: { status?: number } }).response?.status ??
          null,
      });
      // The 422 message is the whole point of rejecting duplicates — without
      // this the refusal reaches PostHog and never reaches the user.
      showToast("Rename failed", resizeErrorMessage(error), "error");
    },
  });
```

Add `rename,` to the returned object beside `duplicate,`.

- [ ] **Step 3: Typecheck against the baseline**

```bash
cd web && npx tsc --noEmit 2>&1 | grep -E "useResizeExports|kv-generator-events"
```

Expected: no output.

- [ ] **Step 4: Commit**

```bash
cd web && git add src/lib/studio/kv/useResizeExports.ts src/lib/analytics/kv-generator-events.ts
git commit -m "feat(web): add the tile rename mutation and its events"
```

---

### Task 11: web — panel rows show the server label

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvResizePanel.tsx` (`PlatformRow` `:332-462`, both call sites `:205-224` and `:308-325`)
- Test: `web/src/components/studio/kv-generator/KvResizePanel.test.tsx`

**Interfaces:**
- Consumes: `ex?.platformLabel` at both call sites.
- Produces: `PlatformRow` takes `label?: string`.

**Note before you start:** the spec's "one-line change" is wrong. `PlatformRow` takes `platform` + callbacks only, renders `{p.label}` at `:391`, and repeats the label in **four** `aria-label`s (`:407`, `:421`, `:435`, `:449`). All five sites change. **`platformById` stays** — a preset row with no export has no other label, which is why the prop is optional and ranked second.

- [ ] **Step 1: Write the failing tests**

Add to `web/src/components/studio/kv-generator/KvResizePanel.test.tsx`, matching the file's own render helper:

```ts
it("shows the server label when a row exists", () => {
  // A custom row whose export carries platformLabel "Hero variant".
  expect(screen.getByText("Hero variant")).toBeInTheDocument();
  expect(screen.queryByText("100 × 200")).not.toBeInTheDocument();
});

it("falls back to the registry label for a row with no export", () => {
  // A preset with nothing exported yet still needs a name.
  expect(screen.getByText("Instagram Post")).toBeInTheDocument();
});

it("carries the name into the row action labels", () => {
  // Screen readers must hear the name, not the derived size.
  expect(
    screen.getByRole("button", { name: "Duplicate Hero variant resize" })
  ).toBeInTheDocument();
  expect(
    screen.getByRole("button", { name: "Remove Hero variant resize" })
  ).toBeInTheDocument();
});
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd web && bun test src/components/studio/kv-generator/KvResizePanel.test.tsx
```

Expected: FAIL — the row renders `100 × 200`.

- [ ] **Step 3: Implement**

In `PlatformRow`, add the prop to both the destructure and the type:

```tsx
function PlatformRow({
  platform: p,
  label,
  state,
```

```tsx
  platform: Platform;
  /** The server's label for this row's export, when one exists. Ranked ABOVE
   *  `platform.label`, which is client-derived from the id and therefore
   *  cannot know a user-given name — but kept as the fallback, because a
   *  preset row with nothing exported yet has no other name. */
  label?: string;
  state: RowState;
```

Add one line under the destructure:

```tsx
  const rowLabel = label ?? p.label;
```

Replace `{p.label}` at `:391` with `{rowLabel}`, and each of the four `aria-label` templates — `Duplicate`, `Remove`, `Cancel`, `Discard` — from `${p.label}` to `${rowLabel}`.

At the custom call site, add after `platform={platform}`:

```tsx
                      label={ex?.platformLabel}
```

At the preset call site, add after `platform={p}`:

```tsx
                label={ex?.platformLabel}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd web && bun test src/components/studio/kv-generator/KvResizePanel.test.tsx
```

Expected: PASS, including the file's pre-existing tests.

- [ ] **Step 5: Commit**

```bash
cd web && git add src/components/studio/kv-generator/KvResizePanel.tsx src/components/studio/kv-generator/KvResizePanel.test.tsx
git commit -m "feat(web): panel rows prefer the server tile label"
```

---

### Task 12: web — the inline rename affordance

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvResizePanel.tsx`
- Modify: `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx` (wire `onRename` down to the panel — find the `onDuplicate` prop thread with `grep -n "onDuplicate" src/components/studio/kv-generator/KvGeneratorLayout.tsx` and follow it exactly)
- Test: `web/src/components/studio/kv-generator/KvResizePanel.test.tsx`

**Interfaces:**
- Consumes: the `rename` mutation from Task 10, threaded as `onRename?: (exportId: string, name: string | null) => void`.
- Produces: double-click a done row's label → inline input.

**Note before you start:** LayersPanel's Escape path sets `renamingId = null` and the blur that follows **still fires `commitRename`** — harmless there only because `commitRename` re-checks `renamingId`. Copy that guard. Also: gate on `state === "done"` (a pending tile has no result to name), pre-fill the **raw name** and use the derived label as `placeholder`, and fire nothing when the value is unchanged.

- [ ] **Step 1: Write the failing tests**

Add to `web/src/components/studio/kv-generator/KvResizePanel.test.tsx`:

```ts
it("commits a rename on Enter", async () => {
  // double-click the label, type, press Enter
  expect(onRename).toHaveBeenCalledWith(exportId, "Hero variant");
});

it("cancels on Escape without renaming", async () => {
  // double-click, type, press Escape — and note the blur that follows must
  // NOT sneak a commit through.
  expect(onRename).not.toHaveBeenCalled();
});

it("clears the name on a blank commit", async () => {
  // double-click a NAMED row, select-all, delete, Enter
  expect(onRename).toHaveBeenCalledWith(exportId, null);
});

it("fires nothing when the value is unchanged", async () => {
  // double-click a named row, press Enter without typing
  expect(onRename).not.toHaveBeenCalled();
});

it("pre-fills the raw name, not the derived label", async () => {
  // An unnamed row's input starts EMPTY with the derived label as
  // placeholder — pre-filling the label would store it as a real name.
  const input = screen.getByRole("textbox");
  expect(input).toHaveValue("");
  expect(input).toHaveAttribute("placeholder", "100 × 200");
});

it("offers no rename on a row that is not done", async () => {
  // A pending tile has no result to name.
  expect(screen.queryByRole("textbox")).not.toBeInTheDocument();
});
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd web && bun test src/components/studio/kv-generator/KvResizePanel.test.tsx
```

Expected: FAIL — no input appears on double-click.

- [ ] **Step 3: Implement**

Extend `PlatformRow`'s props:

```tsx
  /** The row's raw user-given name, or null. Distinct from `label`: the input
   *  must pre-fill THIS, because pre-filling a derived label would store it as
   *  a real name on the next Enter. */
  name?: string | null;
  /** Null clears the name. Absent on rows with no export to name. */
  onRename?: (name: string | null) => void;
```

Add the state and the commit, mirroring `LayersPanel.tsx:125-129`:

```tsx
  const [renaming, setRenaming] = useState(false);
  const [draft, setDraft] = useState("");

  const commitRename = () => {
    // Guarded because Escape clears `renaming` and the blur that follows
    // still calls this — the same shape LayersPanel relies on.
    if (!renaming) return;
    setRenaming(false);

    const next = draft.trim();
    const current = (name ?? "").trim();
    // Unchanged commits fire no request.
    if (next === current) return;
    onRename?.(next === "" ? null : next);
  };
```

Replace the label span at `:391` with:

```tsx
          {renaming ? (
            <input
              autoFocus
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              onClick={(e) => e.stopPropagation()}
              onBlur={commitRename}
              onKeyDown={(e) => {
                e.stopPropagation();
                if (e.key === "Enter") commitRename();
                if (e.key === "Escape") setRenaming(false);
              }}
              // The derived label as placeholder, so a user clearing the
              // field can see what they would fall back to.
              placeholder={p.label}
              maxLength={120}
              aria-label={`Rename ${rowLabel}`}
              className="font-geist w-full rounded border border-white/20 bg-white/10 px-1 py-0 text-textSm leading-[1.4] text-text-inverse focus:outline-none focus:ring-1 focus:ring-[#4D8EFF]"
            />
          ) : (
            <span
              className="font-geist text-textSm leading-[1.4] text-text-inverse"
              onDoubleClick={
                state === "done" && onRename
                  ? (e) => {
                      e.stopPropagation();
                      setRenaming(true);
                      setDraft(name ?? "");
                    }
                  : undefined
              }
            >
              {rowLabel}
            </span>
          )}
```

Then thread `name={ex?.name}` and `onRename={onRename && ex ? (next) => onRename(ex.id, next) : undefined}` at **both** call sites (mirroring how `onDuplicate` is threaded — the `state === "done"` gate lives in `PlatformRow`, not the call site), add `onRename` to `KvResizePanel`'s own props, and wire it from `KvGeneratorLayout` to `rename.mutate({ exportId, name })` following the `onDuplicate` thread.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd web && bun test src/components/studio/kv-generator/KvResizePanel.test.tsx
```

Expected: PASS.

- [ ] **Step 5: Typecheck against the baseline**

```bash
cd web && npx tsc --noEmit 2>&1 | grep -E "KvResizePanel|KvGeneratorLayout"
```

Expected: only the known pre-existing `KvGeneratorLayout.tsx:6681` (`TS2322`). Anything else is yours.

- [ ] **Step 6: Commit**

```bash
cd web && git add src/components/studio/kv-generator/KvResizePanel.tsx src/components/studio/kv-generator/KvGeneratorLayout.tsx src/components/studio/kv-generator/KvResizePanel.test.tsx
git commit -m "feat(web): rename a resize tile inline from the panel"
```

---

### Task 13: web — the share page reads the payload label

**Files:**
- Modify: `web/src/services/query.ts:5650-5666` (`PublicKvResizeItem`)
- Modify: `web/src/app/share/[token]/KvShareClient.tsx` (`itemAlt` `:296`, `itemLabel` `:304`)
- Test: `web/src/app/share/[token]/KvShareClient.test.tsx`

**Interfaces:**
- Consumes: `platform_label` from Task 7.
- Produces: a renamed tile shows its name on a public link.

**Note before you start:** **do NOT delete `platformLabel()`.** The spec says to, but that helper is shared with **motion** (`item.ratio`, `:298` and `:307`), which has no registry entry — deleting it breaks motion captions. Change only the two `kind === "resize"` branches. This test file **must run alone**: `@tremor/react`'s bundled `@headlessui/react` patches `HTMLElement.prototype.focus` at import time, and combined runs report fewer tests than the files hold.

- [ ] **Step 1: Add the field to the type**

In `web/src/services/query.ts`, add to `PublicKvResizeItem` after `platform_id`:

```ts
  /** The tile's display name, resolved server-side: a user-given name, else
   *  the registry or derived label. Preferred over deriving from
   *  `platform_id` here, which cannot know a name. */
  platform_label: string;
```

- [ ] **Step 2: Write the failing test**

Add to `web/src/app/share/[token]/KvShareClient.test.tsx`:

```ts
it("captions a resize tile with the payload label", () => {
  // A resize item with platform_label "Hero variant".
  expect(screen.getByText(/Hero variant · 100 × 200/)).toBeInTheDocument();
});

it("uses the payload label for the tile's alt text", () => {
  expect(screen.getByAltText("Hero variant export")).toBeInTheDocument();
});
```

- [ ] **Step 3: Run the test to verify it fails — ALONE**

```bash
cd web && bun test src/app/share/\[token\]/KvShareClient.test.tsx
```

Expected: FAIL. **Check the reported test count matches what the file holds** — a short count means the `@headlessui` import-time patch bit, not that your assertions passed.

- [ ] **Step 4: Implement**

In `web/src/app/share/[token]/KvShareClient.tsx`, change the two resize branches only:

```ts
function itemAlt(item: PublicKvItem): string {
  if (item.kind === "resize") return `${item.platform_label} export`;
  if (item.kind === "motion") return `${platformLabel(item.ratio)} motion`;
  return item.name ?? "Shared key visual";
}
```

```ts
  if (item.kind === "resize") {
    return `${item.platform_label} · ${item.width} × ${item.height}`;
  }
```

Leave `platformLabel()` in place — motion still needs it — and update its docblock to say resize no longer routes through it.

- [ ] **Step 5: Run the test to verify it passes — ALONE**

```bash
cd web && bun test src/app/share/\[token\]/KvShareClient.test.tsx
```

Expected: PASS, with the full expected test count.

- [ ] **Step 6: Typecheck against the baseline**

```bash
cd web && npx tsc --noEmit 2>&1 | grep -E "KvShareClient|services/query"
```

Expected: only the known pre-existing `KvShareClient.tsx:228` and `:230` (`TS2339`).

- [ ] **Step 7: Commit**

```bash
cd web && git add src/services/query.ts "src/app/share/[token]/KvShareClient.tsx" "src/app/share/[token]/KvShareClient.test.tsx"
git commit -m "feat(web): share page shows the server tile label"
```

---

### Task 14: web — comment breadcrumbs carry the name

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvResizeCanvas.tsx:501-514`
- Modify: `web/src/lib/studio/kv/kvCommentAdapter.ts:136-139`, `:172-176`
- Test: `web/src/lib/studio/kv/kvCommentAdapter.test.ts` if it exists (`ls src/lib/studio/kv | grep -i comment`)

**Interfaces:**
- Consumes: `platformLabel` off each export row.
- Produces: `tilePlatforms` now maps `rowId → label`. `anchorLabel` uses the value directly.

**Note before you start:** **the encoding is the whole task.** `tilePlatformSig` joins pairs with `|` and splits each on `:` (`:502-514`). A platform id can never contain either character; a **user-authored name can**. Naming a tile `Hero: v2` would silently corrupt the map. Rebuild the signature so the label is never parsed out of a delimited string. The `?? rowId` fallback in the adapter stays — it serves the legacy pin shape where the segment IS a platform id.

- [ ] **Step 1: Write the failing test**

Add to the comment-adapter test (or create one following a sibling in `src/lib/studio/kv/`):

```ts
it("labels a tile anchor with the tile's name", () => {
  const label = anchorLabel(tileAnchor, {
    generations,
    tilePlatforms: { "row-1": "Hero variant" },
  });

  expect(label).toContain("Hero variant");
});

it("still labels a legacy anchor that stored a platform id", () => {
  // Earliest tile pins put the platform id in the segment itself.
  const label = anchorLabel(legacyAnchor, { generations });

  expect(label).toContain("Instagram Post");
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd web && bun test src/lib/studio/kv/kvCommentAdapter.test.ts
```

Expected: FAIL — the label is derived from the id and ignores the passed name.

- [ ] **Step 3: Implement the canvas side**

In `web/src/components/studio/kv-generator/KvResizeCanvas.tsx`, replace the signature block (`:501-514`):

```tsx
  // Publish rowId → LABEL for comment labelling. Signature-keyed so a
  // re-render that leaves the tile set unchanged does not loop the parent.
  //
  // JSON rather than a "rowId:label|..." string: a platform id can never
  // contain ':' or '|', but a user-given tile NAME can, and the old encoding
  // silently corrupted the map for a tile named "Hero: v2".
  const tilePlatformSig = JSON.stringify(
    exports.map((r) => [r.id, r.platformLabel])
  );
  useEffect(() => {
    if (!onTilePlatformsChange) return;
    const map: Record<string, string> = {};
    for (const [rowId, label] of JSON.parse(tilePlatformSig) as [
      string,
      string,
    ][]) {
      if (rowId && label) map[rowId] = label;
    }
    onTilePlatformsChange(map);
  }, [tilePlatformSig, onTilePlatformsChange]);
```

- [ ] **Step 4: Implement the adapter side**

In `web/src/lib/studio/kv/kvCommentAdapter.ts`, update the doc on the ctx field (`:136-139`):

```ts
    /**
     * Resize row id → display LABEL. Tile anchors are keyed by ROW (a platform
     * can occupy several rows), but a reviewer reads "Hero variant", not a row
     * ulid — so the human name is looked up through this. The value is the
     * server-resolved label, so a renamed tile reads as its name.
     */
    tilePlatforms?: Record<string, string>;
```

and the lookup (`:172-176`):

```ts
      // A label from the canvas when the anchor is keyed by row (current
      // shape). Falling back to `platformById` covers the earliest tile pins,
      // which stored a platform id in the segment itself.
      const known = ctx.tilePlatforms?.[rowId];
      segments.push(
        known ?? platformById(rowId as PlatformId)?.label ?? rowId
      );
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd web && bun test src/lib/studio/kv/kvCommentAdapter.test.ts
```

Expected: PASS.

- [ ] **Step 6: Typecheck against the baseline**

```bash
cd web && npx tsc --noEmit 2>&1 | grep -E "KvResizeCanvas|kvCommentAdapter"
```

Expected: no output.

- [ ] **Step 7: Commit**

```bash
cd web && git add src/components/studio/kv-generator/KvResizeCanvas.tsx src/lib/studio/kv/kvCommentAdapter.ts src/lib/studio/kv/kvCommentAdapter.test.ts
git commit -m "feat(web): comment breadcrumbs read the tile label"
```

---

### Task 15: Full verification

**Files:** none — verification only.

- [ ] **Step 1: api suite**

```bash
cd api && DB_CONNECTION=pgsql DB_DATABASE=frnd_dup_tile_test TELESCOPE_ENABLED=false ./vendor/bin/pest tests/Feature/Studio/KvResizeExportControllerTest.php tests/Feature/Studio/KvResizeExportDuplicateTest.php tests/Feature/Studio/KvResizeExportRenameTest.php tests/Feature/Studio/KvResizeExportZipTest.php tests/Feature/Studio/KvResizeRegionEditTest.php tests/Unit/Resources/KvResizeExportResourceTest.php tests/Unit/Models/KvResizeExportDisplayLabelTest.php tests/Unit/Support/Studio/CustomResizeSizeTest.php
```

Expected: PASS.

- [ ] **Step 2: web suites, per file**

```bash
cd web && bun test src/components/studio/kv-generator/KvResizePanel.test.tsx
cd web && bun test src/lib/studio/kv/kvCommentAdapter.test.ts
cd web && bun test src/app/share/\[token\]/KvShareClient.test.tsx
```

The share test runs **alone** — do not combine it. Check each reported count against what the file holds.

`KvResizeResultRow.test.tsx` has **one pre-existing failure** (it queries `/reset overlays to project default/i` while the real aria-label is `"Not following master — reset to follow"`) — a stale expectation from an older rename, not this work. Do not "fix" it here.

- [ ] **Step 3: Build**

```bash
cd web && node ./node_modules/next/dist/bin/next build
```

Expected: succeeds. Do **not** use `bun run build`.

- [ ] **Step 4: Type diff**

```bash
cd web && npx tsc --noEmit 2>&1 | grep -E "^src/(components/studio/kv-generator|lib/studio/kv|app/share|services)" | sort > /tmp/tsc-after.txt && wc -l /tmp/tsc-after.txt
```

Compare by `file:line` against the same command on the base branch. Known pre-existing and unrelated: `KvShareClient.tsx:228`, `:230`, `KvGeneratorLayout.tsx:6681`. Never compare totals — the repo baseline is ~810 errors.

---

## Runtime checklist — owed, not optional

Nothing in the duplicate feature has ever been clicked in a browser, and this feature starts in the same state. **Before calling rename done:**

- [ ] Rename a custom tile from the panel; the label updates on the tile, the canvas and the board layout
- [ ] Clear the name; the derived `100 × 200 (2)` returns
- [ ] Rename a **preset** tile
- [ ] Escape mid-edit; the old label is intact and no request fired (check the network tab)
- [ ] Duplicate a named tile; the copy reads `… (copy)`
- [ ] Duplicate it again; the copy reads `… (copy 2)`
- [ ] Trigger the 422: two tiles, same name, same KV — the toast shows, the label reverts, no flicker
- [ ] Name a tile `Hero: v2 | draft`, then open a comment on it — the breadcrumb reads the full name (this is the encoding fix in Task 14)
- [ ] Open a share link; the renamed tile shows its name
- [ ] Download the zip; the entry is `hero-variant.png`
- [ ] Confirm both PostHog events fire, success and failure

## Still owed to Daffa, not code

- Lark wiki taxonomy rows for `kv_generator.resize_tile_duplicated`, `kv_generator.resize_tile_duplicate_failed`, `kv_generator.resize_tile_renamed` and `kv_generator.resize_tile_rename_failed` — those exact strings.
- PostHog event descriptions, tags and `verified` after the first production fire.
- Consider a `source: "canvas" | "panel"` property on the duplicate events. Daffa chose two entry points over a one-entry-point recommendation; that property is the data that would confirm or refute it. Deliberately not implemented — and the reason rename ships with one entry point.
