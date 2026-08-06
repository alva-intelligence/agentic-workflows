# KV Layer-Composed Resize — api Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mark PSD-imported KVs as layer-composed and complete their resize exports without ever calling ai-service.

**Architecture:** A boolean flag rides the existing import-from-upload endpoint into `kv_generations.metadata`. `KvResizeExportService` reads it and, instead of dispatching `ProcessKvResizeExportJob`, marks the export row done with a null `image_url`. Because ai-service is never called, the internal completion callback never fires and no credit is charged — no metering code is touched.

**Tech Stack:** PHP 8.5, Laravel 13, Pest 4, PostgreSQL (dev) / in-memory SQLite (tests).

Spec: `docs/superpowers/specs/2026-08-06-kv-layer-composed-resize-design.md` (§1 and §2).
Companion plan: `docs/superpowers/plans/2026-08-06-kv-layer-composed-resize-web.md`.

## Global Constraints

- Metadata key is exactly `layer_composed`, a boolean. Web sends it as `layer_composed` in the import-from-upload body.
- A layer-composed export completes with `status = done`, `image_url = null`, `overlays = null`, `model = null`.
- Never charge credits for a layer-composed resize.
- Do **not** compute overlay projections in PHP. Projection is web-side, at render time — see the spec's §2.
- Behaviour for non-layer-composed KVs must not change at all.
- Run `vendor/bin/pint --dirty --format agent` before every commit that touches PHP.

---

### Task 0: Verify test DB isolation before running anything

This repo has wiped a developer's Postgres dev database before, when `phpunit.xml`'s SQLite override was commented out. Confirm isolation is live **before** running any test in this plan.

- [ ] **Step 1: Confirm phpunit.xml forces in-memory SQLite**

Run: `grep -nE 'DB_CONNECTION|DB_DATABASE|QUEUE_CONNECTION' api/phpunit.xml`

Expected, all three present and uncommented:

```xml
<env name="DB_CONNECTION" value="sqlite"/>
<env name="DB_DATABASE" value=":memory:"/>
<env name="QUEUE_CONNECTION" value="sync"/>
```

If `DB_CONNECTION`/`DB_DATABASE` are missing or commented, **stop and report**. Do not run tests — they would run against the dev Postgres database.

- [ ] **Step 2: Confirm RefreshDatabase scope**

Run: `grep -n 'RefreshDatabase' api/tests/Pest.php`

Expected: `uses(TestCase::class, RefreshDatabase::class)->in('Feature');`

Unit tests must opt in explicitly. Tasks 2–4 below do opt in.

Note: `QUEUE_CONNECTION=sync` means a dispatched job runs **inline** during tests and would attempt a real HTTP call to ai-service. Every test that touches `createBatch` or `regenerate` must call `Queue::fake()`.

---

### Task 1: Accept and persist `layer_composed` on import-from-upload

**Files:**
- Modify: `api/app/Http/Requests/Studio/ImportKvGenerationFromUploadRequest.php`
- Modify: `api/app/Http/Controllers/Api/Studio/KvGeneratorFileController.php:650-673`
- Modify: `api/app/Services/Studio/KvGenerationService.php:132-140`
- Test: `api/tests/Feature/Studio/KvGenerationImportFromUploadTest.php`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `kv_generations.metadata['layer_composed']` as a boolean, always present on rows created through this endpoint. Task 2 reads it.

- [ ] **Step 1: Write the failing test**

Append to `api/tests/Feature/Studio/KvGenerationImportFromUploadTest.php`. The file's existing `beforeEach` already creates `$this->user`, `$this->file` and calls `actingAs`, so the test body only posts and asserts.

```php
it('stores layer_composed when the uploaded base is a PSD blank base', function () {
    $response = $this->postJson(
        "/api/v1/studio/kv-generator/files/{$this->file->id}/generations/import-from-upload",
        [
            'image_url' => 'https://example.com/uploads/blank-base.png',
            'mime_type' => 'image/png',
            'size' => 48139,
            'original_filename' => 'WF - V SAFE AREA.png',
            'width' => 1080,
            'height' => 1920,
            'layer_composed' => true,
        ],
    )->assertCreated();

    $gen = KvGeneration::findOrFail($response->json('data.id'));
    expect(data_get($gen->metadata, 'layer_composed'))->toBeTrue();
});

it('defaults layer_composed to false for an ordinary uploaded image', function () {
    $response = $this->postJson(
        "/api/v1/studio/kv-generator/files/{$this->file->id}/generations/import-from-upload",
        [
            'image_url' => 'https://example.com/uploads/ref.png',
            'mime_type' => 'image/png',
            'size' => 123456,
            'original_filename' => 'brand-hero.png',
            'width' => 1920,
            'height' => 1080,
        ],
    )->assertCreated();

    $gen = KvGeneration::findOrFail($response->json('data.id'));
    expect(data_get($gen->metadata, 'layer_composed'))->toBeFalse();
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd api && php artisan test --compact --filter='layer_composed'`

Expected: both FAIL. The first because the key is absent (`toBeTrue` receives `null`), the second likewise (`toBeFalse` receives `null`).

If the whole Feature suite errors during migration for unrelated reasons (a known problem in this repo — a workspaces backfill collides with SoftDeletes on a fresh migrate), report that and rely on Tasks 2–4's Unit tests for verification rather than fighting it here.

- [ ] **Step 3: Add validation for the new field**

In `ImportKvGenerationFromUploadRequest.php`, add one line to the rules array alongside the existing `canvas_mode` rule:

```php
'layer_composed' => ['sometimes', 'boolean'],
```

- [ ] **Step 4: Pass it through the controller**

In `KvGeneratorFileController::importGenerationFromUpload`, add one entry to the array handed to `persistImportFromUpload`, after `'canvas_mode'`:

```php
'layer_composed' => $request->validated('layer_composed', false),
```

- [ ] **Step 5: Persist it into metadata**

In `KvGenerationService::persistImportFromUpload`, extend the `$metadata` array with a final entry:

```php
$metadata = [
    'imported_from_upload' => true,
    'mime_type' => $payload['mime_type'],
    'size' => $payload['size'],
    'original_filename' => $payload['original_filename'] ?? null,
    'width' => $width,
    'height' => $height,
    'craft_supported' => KvAspectRatio::isSupported($width, $height),
    'layer_composed' => (bool) ($payload['layer_composed'] ?? false),
];
```

Writing the key unconditionally (rather than only when true) means every row created from here on is explicit about what it is, so a missing key reliably indicates a row that predates this change.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd api && php artisan test --compact --filter='layer_composed'`

Expected: both PASS.

- [ ] **Step 7: Confirm nothing else broke**

Run: `cd api && php artisan test --compact --filter='KvGenerationImportFromUpload'`

Expected: every test in the file passes, including the pre-existing `promotes an uploaded reference…` case.

- [ ] **Step 8: Format and commit**

```bash
cd api && vendor/bin/pint --dirty --format agent
git add app/Http/Requests/Studio/ImportKvGenerationFromUploadRequest.php app/Http/Controllers/Api/Studio/KvGeneratorFileController.php app/Services/Studio/KvGenerationService.php tests/Feature/Studio/KvGenerationImportFromUploadTest.php
git commit -m "feat(api): accept layer_composed on KV import-from-upload"
```

---

### Task 2: `KvGeneration::isLayerComposed()`

**Files:**
- Modify: `api/app/Models/KvGeneration.php`
- Test: `api/tests/Unit/Models/KvGenerationLayerComposedTest.php` (create)

**Interfaces:**
- Consumes: `metadata['layer_composed']` written by Task 1.
- Produces: `KvGeneration::isLayerComposed(): bool`. Task 4 calls it.

- [ ] **Step 1: Write the failing test**

Create `api/tests/Unit/Models/KvGenerationLayerComposedTest.php`:

```php
<?php

use App\Models\KvGeneration;

it('is layer composed when the metadata flag is true', function () {
    $gen = new KvGeneration(['metadata' => ['layer_composed' => true]]);

    expect($gen->isLayerComposed())->toBeTrue();
});

it('is not layer composed when the flag is false', function () {
    $gen = new KvGeneration(['metadata' => ['layer_composed' => false]]);

    expect($gen->isLayerComposed())->toBeFalse();
});

it('is not layer composed when the flag is absent', function () {
    $gen = new KvGeneration(['metadata' => ['imported_from_upload' => true]]);

    expect($gen->isLayerComposed())->toBeFalse();
});

it('is not layer composed when metadata is null', function () {
    $gen = new KvGeneration(['metadata' => null]);

    expect($gen->isLayerComposed())->toBeFalse();
});
```

No `RefreshDatabase` here — these are unsaved model instances, so the test needs no database at all and stays fast.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd api && php artisan test --compact --filter='KvGenerationLayerComposed'`

Expected: FAIL with `Call to undefined method App\Models\KvGeneration::isLayerComposed()`.

- [ ] **Step 3: Implement the method**

Add to `app/Models/KvGeneration.php`, after the `$casts` property and before the relations:

```php
/**
 * Whether this KV's artwork lives in overlay layers rather than in
 * `image_url`. PSD imports mint a blank base and carry the picture as
 * layers, so anything that needs real pixels must composite first.
 */
public function isLayerComposed(): bool
{
    return (bool) ($this->metadata['layer_composed'] ?? false);
}
```

`metadata` is cast to `array` on this model, so `$this->metadata` is an array or null and the null-coalesce covers both.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd api && php artisan test --compact --filter='KvGenerationLayerComposed'`

Expected: 4 passed.

- [ ] **Step 5: Format and commit**

```bash
cd api && vendor/bin/pint --dirty --format agent
git add app/Models/KvGeneration.php tests/Unit/Models/KvGenerationLayerComposedTest.php
git commit -m "feat(api): add KvGeneration::isLayerComposed"
```

---

### Task 3: `markDoneWithoutImage()` on the resize export service

**Files:**
- Modify: `api/app/Services/Studio/KvResizeExportService.php:86-93`
- Test: `api/tests/Unit/Services/Studio/KvResizeExportServiceTest.php`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `KvResizeExportService::markDoneWithoutImage(KvResizeExport $row): void`. Task 4 calls it.

Why a new method rather than loosening `markDone(KvResizeExport $row, string $imageUrl)`: the existing signature's non-nullable `string` is what guarantees an AI-produced export always carries an image. Widening it to `?string` would remove that guarantee from the AI path too.

- [ ] **Step 1: Write the failing test**

Append to `api/tests/Unit/Services/Studio/KvResizeExportServiceTest.php`. The file's existing `beforeEach` provides `$this->service`, `$this->file`, `$this->generation` and `$this->user`, and calls `Queue::fake()`.

```php
it('marks an export done with no image and no error', function () {
    $row = KvResizeExport::factory()->create([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $this->generation->id,
        'created_by' => $this->user->id,
        'status' => KvResizeExportStatus::Pending,
        'error_message' => 'stale failure text',
    ]);

    $this->service->markDoneWithoutImage($row);

    $row->refresh();
    expect($row->status)->toBe(KvResizeExportStatus::Done);
    expect($row->image_url)->toBeNull();
    expect($row->error_message)->toBeNull();
});
```

Add `use App\Models\KvResizeExport;` and `use App\Enums\Studio\KvResizeExportStatus;` to the file's imports if they are not already there.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd api && php artisan test --compact --filter='marks an export done with no image'`

Expected: FAIL with `Call to undefined method …::markDoneWithoutImage()`.

- [ ] **Step 3: Implement the method**

Add to `KvResizeExportService.php` directly beneath `markDone`:

```php
/**
 * Complete an export that needs no AI call — a layer-composed KV whose
 * pixels are assembled on demand from its layers. `image_url` stays null
 * on purpose: a URL here would claim an image exists when none does.
 */
public function markDoneWithoutImage(KvResizeExport $row): void
{
    $row->update([
        'status' => KvResizeExportStatus::Done,
        'image_url' => null,
        'error_message' => null,
    ]);
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd api && php artisan test --compact --filter='marks an export done with no image'`

Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
cd api && vendor/bin/pint --dirty --format agent
git add app/Services/Studio/KvResizeExportService.php tests/Unit/Services/Studio/KvResizeExportServiceTest.php
git commit -m "feat(api): add markDoneWithoutImage for AI-free resize exports"
```

---

### Task 4: Route layer-composed resizes away from the AI job

**Files:**
- Modify: `api/app/Services/Studio/KvResizeExportService.php:58-60` (`createBatch`) and `:66-79` (`regenerate`)
- Test: `api/tests/Unit/Services/Studio/KvResizeExportServiceTest.php`

**Interfaces:**
- Consumes: `KvGeneration::isLayerComposed()` (Task 2), `markDoneWithoutImage()` (Task 3).
- Produces: no new API. After this task, a layer-composed parent yields export rows that are already `done` when the request returns.

Branching here rather than inside `ProcessKvResizeExportJob` avoids a pointless queue round-trip and makes the tile appear immediately, which is the whole point of skipping the model.

- [ ] **Step 1: Write the failing tests**

Append to `api/tests/Unit/Services/Studio/KvResizeExportServiceTest.php`:

```php
it('completes a layer-composed resize without dispatching the AI job', function () {
    $parent = KvGeneration::factory()->create([
        'studio_file_id' => $this->file->id,
        'version_number' => 2,
        'metadata' => ['layer_composed' => true],
    ]);

    $rows = $this->service->createBatch(
        $this->file,
        $parent,
        ['tiktok-video'],
        [],
        $this->user->id,
    );

    Queue::assertNothingPushed();

    $row = $rows->first()->refresh();
    expect($row->status)->toBe(KvResizeExportStatus::Done);
    expect($row->image_url)->toBeNull();
    expect($row->overlays)->toBeNull();
    expect($row->model)->toBeNull();
    expect($row->width)->toBe(1080);
    expect($row->height)->toBe(1920);
});

it('still dispatches the AI job for a normal KV', function () {
    $rows = $this->service->createBatch(
        $this->file,
        $this->generation,
        ['tiktok-video'],
        [],
        $this->user->id,
    );

    Queue::assertPushed(ProcessKvResizeExportJob::class);
    expect($rows->first()->status)->toBe(KvResizeExportStatus::Pending);
});

it('completes a layer-composed regenerate without dispatching the AI job', function () {
    $parent = KvGeneration::factory()->create([
        'studio_file_id' => $this->file->id,
        'version_number' => 3,
        'metadata' => ['layer_composed' => true],
    ]);
    $row = KvResizeExport::factory()->create([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $parent->id,
        'created_by' => $this->user->id,
        'status' => KvResizeExportStatus::Failed,
        'error_message' => 'previous failure',
    ]);

    $this->service->regenerate($row, null);

    Queue::assertNothingPushed();
    expect($row->refresh()->status)->toBe(KvResizeExportStatus::Done);
    expect($row->image_url)->toBeNull();
    expect($row->error_message)->toBeNull();
});
```

Add `use App\Jobs\Studio\ProcessKvResizeExportJob;` to the imports if absent. `$this->generation` from `beforeEach` has no `layer_composed` key, which is exactly the "normal KV" case.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd api && php artisan test --compact --filter='KvResizeExportServiceTest'`

Expected: the two layer-composed tests FAIL (the job is pushed and status stays `Pending`). The "still dispatches" test PASSES already — it is a regression guard, and it must keep passing after Step 3.

- [ ] **Step 3: Branch in `createBatch`**

Replace the dispatch block at `KvResizeExportService.php:58-60`:

```php
            if ($row->wasRecentlyCreated) {
                if ($parent->isLayerComposed()) {
                    // The artwork lives in layers, not in the parent's
                    // image_url, so there is nothing for the image model to
                    // extend. The tile renders from projected layers; pixels
                    // are assembled on demand when something needs a file.
                    $this->markDoneWithoutImage($row);
                } else {
                    ProcessKvResizeExportJob::dispatch($row->id);
                }
            }
```

- [ ] **Step 4: Branch in `regenerate`**

Replace the body of `regenerate` at `:66-79`:

```php
    public function regenerate(KvResizeExport $row, ?array $cropWindow, ?string $additionalPrompt = null): KvResizeExport
    {
        $row->update([
            'status' => KvResizeExportStatus::Pending,
            'image_url' => null,
            'error_message' => null,
            'crop_window' => $cropWindow,
            'additional_prompt' => $additionalPrompt,
        ]);

        if ($row->parentGeneration?->isLayerComposed()) {
            $this->markDoneWithoutImage($row);

            return $row->refresh();
        }

        ProcessKvResizeExportJob::dispatch($row->id);

        return $row->refresh();
    }
```

The null-safe operator matters: `parentGeneration` is a relation, and a row whose parent was hard-deleted must fall through to the existing path rather than fatal.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd api && php artisan test --compact --filter='KvResizeExportServiceTest'`

Expected: all pass, including the "still dispatches the AI job for a normal KV" regression guard.

- [ ] **Step 6: Format and commit**

```bash
cd api && vendor/bin/pint --dirty --format agent
git add app/Services/Studio/KvResizeExportService.php tests/Unit/Services/Studio/KvResizeExportServiceTest.php
git commit -m "feat(api): skip the AI resize job for layer-composed KVs"
```

---

## Verification after all tasks

- [ ] Run the touched suites:

```bash
cd api && php artisan test --compact --filter='KvResizeExportService|KvGenerationLayerComposed|KvGenerationImportFromUpload'
```

- [ ] Confirm no credit path was touched:

```bash
cd api && git diff --stat develop -- app/Services/Studio/KvCreditMeteringService.php app/Http/Controllers/Api/Internal/KvResizeExportInternalController.php
```

Expected: empty output. A layer-composed export never reaches the internal callback, so charging is skipped structurally rather than by a new condition. If either file shows changes, something went wrong.

## Notes for the reviewer

- No migration is needed: `metadata` is an existing JSON column already cast to `array`.
- Rows created before this change have no `layer_composed` key and therefore keep today's AI behaviour. The spec's fallback heuristic for pre-existing KVs is deliberately **not** in this plan — it needs a pixel probe and a threshold validated against real data, and it should not gate the fix for new imports. Daffa's existing test KV will need re-importing to exercise this path.
- `failStaleExports` is unaffected: layer-composed rows are `done` before the request returns, so they never sit in `pending` long enough for the 5-minute watchdog.
