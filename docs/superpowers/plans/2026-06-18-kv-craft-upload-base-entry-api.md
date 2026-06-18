# KV Craft Upload-Base — Capture Dimensions + Snap Ratio (API) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a user-uploaded image is imported as a Craft base, capture its pixel dimensions and persist a snapped supported-ratio label so Craft sizing works and the web can gate extreme ratios.

**Architecture:** Add a small pure helper that snaps a `width`×`height` to the nearest of the model's three output ratios (1.0 / 1.5 / 0.67), gating beyond 25%. The import request accepts client-measured `width`/`height`; `persistImportFromUpload` runs the helper and writes `width`, `height`, `aspect_ratio` (label, only when supported), and `craft_supported` (bool) into `KvGeneration.metadata`. The existing Craft aspect backfill ([ThreadController.php:575](../../../api/app/Http/Controllers/Api/Chat/ThreadController.php)) then sizes Craft from `metadata.aspect_ratio` with no further change.

**Tech Stack:** PHP 8.5 / Laravel / Pest 4. No new image library — dimensions are client-measured and server-validated.

**Spec:** [docs/superpowers/specs/2026-06-18-kv-craft-upload-base-entry-design.md](../specs/2026-06-18-kv-craft-upload-base-entry-design.md)

**Project test policy:** `api/AGENTS.md`: *"DO NOT MAKE OR RUN ANY TESTS WITHOUT USER PERMISSION."* Default flow is **code-first**. Test tasks below write test code but are **gated** — pause and ask the user before running. Note the known caveat (`lesson_api_feature_suite_blocked_softdeletes`): the full Feature suite can fail on a fresh migrate; run the focused file with `--filter` only, and verify DB isolation first.

---

## File Structure

| Path | Action | Responsibility |
|---|---|---|
| `app/Support/Studio/KvAspectRatio.php` | Create | Pure snap helper: `snap(int $w, int $h): ?string` |
| `tests/Unit/Support/KvAspectRatioTest.php` | Create | Unit tests for the snap helper (no DB — safe to run) |
| `app/Http/Requests/Studio/ImportKvGenerationFromUploadRequest.php` | Modify | Add `width`/`height` validation rules |
| `app/Http/Controllers/Api/Studio/KvGeneratorFileController.php` | Modify | Pass `width`/`height` into the service payload |
| `app/Services/Studio/KvGenerationService.php` | Modify | Store `width`/`height`/`aspect_ratio`/`craft_supported` in metadata |
| `tests/Feature/Studio/KvGenerationImportFromUploadTest.php` | Modify | Add metadata assertions for the new fields (gated) |

---

## Task 1 — Snap helper (pure, unit-tested)

**Files:**
- Create: `app/Support/Studio/KvAspectRatio.php`
- Test: `tests/Unit/Support/KvAspectRatioTest.php`

- [ ] **Step 1: Write the helper**

Create `app/Support/Studio/KvAspectRatio.php`:

```php
<?php

namespace App\Support\Studio;

/**
 * Maps an uploaded image's pixel dimensions to the KV image model's
 * supported output ratio. The model only renders three sizes
 * (see ai-service edit_image.py OPENAI_SIZE_BY_RATIO):
 *   "1:1"  → 1024x1024  (decimal 1.0)
 *   "16:9" → 1536x1024  (decimal 1.5, i.e. 3:2)
 *   "9:16" → 1024x1536  (decimal 0.67, i.e. 2:3)
 *
 * We snap to the nearest target by relative difference and treat the
 * upload as "extreme" (unsupported for Craft) when even the nearest
 * target is off by more than 25%.
 */
class KvAspectRatio
{
    /** label => target decimal (width / height) */
    private const TARGETS = [
        '1:1' => 1.0,
        '16:9' => 1.5,
        '9:16' => 0.6666666666666666,
    ];

    /** Relative tolerance: gate Craft beyond this distance from the nearest target. */
    public const TOLERANCE = 0.25;

    /**
     * Return the supported ratio label nearest the given dimensions, or
     * null when the image is too extreme to map (Craft should be gated).
     */
    public static function snap(int $width, int $height): ?string
    {
        if ($width <= 0 || $height <= 0) {
            return null;
        }

        $ratio = $width / $height;
        $bestLabel = null;
        $bestDiff = PHP_FLOAT_MAX;

        foreach (self::TARGETS as $label => $target) {
            $diff = abs($ratio - $target) / $target;
            if ($diff < $bestDiff) {
                $bestDiff = $diff;
                $bestLabel = $label;
            }
        }

        return $bestDiff <= self::TOLERANCE ? $bestLabel : null;
    }
}
```

- [ ] **Step 2: Write the unit test**

Create `tests/Unit/Support/KvAspectRatioTest.php`:

```php
<?php

use App\Support\Studio\KvAspectRatio;

it('snaps an exact square to 1:1', function () {
    expect(KvAspectRatio::snap(1080, 1080))->toBe('1:1');
});

it('snaps 3:2 and 4:3 and 16:9 landscape to the 16:9 label', function () {
    expect(KvAspectRatio::snap(1500, 1000))->toBe('16:9'); // 1.5 exact
    expect(KvAspectRatio::snap(1280, 960))->toBe('16:9');  // 4:3 ≈ 1.33, ~11% off
    expect(KvAspectRatio::snap(1920, 1080))->toBe('16:9'); // 16:9 ≈ 1.78, ~19% off
});

it('snaps portrait near 2:3 to the 9:16 label', function () {
    expect(KvAspectRatio::snap(1024, 1536))->toBe('9:16'); // 0.67 exact
    expect(KvAspectRatio::snap(960, 1280))->toBe('9:16');  // 3:4 ≈ 0.75
});

it('gates an extreme wide banner as unsupported', function () {
    expect(KvAspectRatio::snap(2000, 582))->toBeNull(); // ≈ 3.44, ~129% off
});

it('gates an extreme tall skyscraper as unsupported', function () {
    expect(KvAspectRatio::snap(400, 1600))->toBeNull(); // 0.25, far from 0.67
});

it('returns null for non-positive dimensions', function () {
    expect(KvAspectRatio::snap(0, 100))->toBeNull();
    expect(KvAspectRatio::snap(100, 0))->toBeNull();
});
```

- [ ] **Step 3 (GATED — ask user before running): run the unit test**

Run: `cd api && ./vendor/bin/pest tests/Unit/Support/KvAspectRatioTest.php`
Expected: all pass. (Unit test, no DB — safe per `lesson_api_feature_suite_blocked_softdeletes`.)

- [ ] **Step 4: Commit**

```bash
git add app/Support/Studio/KvAspectRatio.php tests/Unit/Support/KvAspectRatioTest.php
git commit -m "feat(api): add KvAspectRatio snap helper for uploaded Craft bases"
```

---

## Task 2 — Accept width/height in the import request

**Files:**
- Modify: `app/Http/Requests/Studio/ImportKvGenerationFromUploadRequest.php`

- [ ] **Step 1: Add validation rules**

In `rules()`, add `width` and `height` after `original_filename`:

```php
    public function rules(): array
    {
        return [
            'image_url' => ['required', 'string', 'url', 'max:2048'],
            'mime_type' => [
                'required',
                'string',
                'in:image/png,image/jpeg,image/webp,image/gif',
            ],
            'size' => ['required', 'integer', 'min:1', 'max:20971520'], // 20 MB cap, matches the chat-attachments client guard
            'original_filename' => ['sometimes', 'nullable', 'string', 'max:255'],
            // Client-measured natural pixel dimensions of the uploaded image.
            // Used to snap to a supported Craft ratio (see KvAspectRatio).
            // Capped at 30000 px — well above any real asset, rejects garbage.
            'width' => ['required', 'integer', 'min:1', 'max:30000'],
            'height' => ['required', 'integer', 'min:1', 'max:30000'],
        ];
    }
```

- [ ] **Step 2: Commit**

```bash
git add app/Http/Requests/Studio/ImportKvGenerationFromUploadRequest.php
git commit -m "feat(api): validate width/height on KV import-from-upload"
```

---

## Task 3 — Persist dimensions + snapped ratio in metadata

**Files:**
- Modify: `app/Http/Controllers/Api/Studio/KvGeneratorFileController.php` (~lines 359–366)
- Modify: `app/Services/Studio/KvGenerationService.php` (imports + metadata array ~lines 123–128)

- [ ] **Step 1: Forward width/height from the controller**

In `importGenerationFromUpload`, add `width`/`height` to the payload array:

```php
        $generation = $service->persistImportFromUpload([
            'studio_file_id' => $file->id,
            'image_url' => $request->validated('image_url'),
            'mime_type' => $request->validated('mime_type'),
            'size' => $request->validated('size'),
            'original_filename' => $request->validated('original_filename'),
            'width' => $request->validated('width'),
            'height' => $request->validated('height'),
            'created_by' => $request->user('api')->id,
        ]);
```

- [ ] **Step 2: Add the import in the service**

At the top of `app/Services/Studio/KvGenerationService.php`, add to the `use` block:

```php
use App\Support\Studio\KvAspectRatio;
```

- [ ] **Step 3: Compute + store the new metadata fields**

In `persistImportFromUpload`, before `KvGeneration::create([...])`, compute the snap, then extend the `metadata` array:

```php
        return DB::transaction(function () use ($payload) {
            $file = StudioFile::findOrFail($payload['studio_file_id']);

            $nextVersion = ($file->generations()->max('version_number') ?? 0) + 1;

            $width = (int) $payload['width'];
            $height = (int) $payload['height'];
            $supportedRatio = KvAspectRatio::snap($width, $height);

            $metadata = [
                'imported_from_upload' => true,
                'mime_type' => $payload['mime_type'],
                'size' => $payload['size'],
                'original_filename' => $payload['original_filename'] ?? null,
                'width' => $width,
                'height' => $height,
                'craft_supported' => $supportedRatio !== null,
            ];
            // Only set aspect_ratio when supported — the Craft backfill in
            // ThreadController reads this key to size the polish output.
            if ($supportedRatio !== null) {
                $metadata['aspect_ratio'] = $supportedRatio;
            }

            $generation = KvGeneration::create([
                'studio_file_id' => $file->id,
                'parent_generation_id' => null,
                'chat_message_id' => null,
                'version_number' => $nextVersion,
                'image_url' => $payload['image_url'],
                'thumbnail_url' => null,
                'prompt_snapshot' => '',
                'model' => 'user_upload',
                'mode' => KvGenerationMode::Sketch,
                'ai_service_run_id' => null,
                'metadata' => $metadata,
                'created_by' => $payload['created_by'],
                'created_at' => now(),
            ]);

            $file->thumbnail_url = $payload['image_url'];
            $file->last_edited_at = now();
            $file->last_edited_by = $payload['created_by'];
            $file->save();

            return $generation;
        });
```

- [ ] **Step 4: Commit**

```bash
git add app/Http/Controllers/Api/Studio/KvGeneratorFileController.php app/Services/Studio/KvGenerationService.php
git commit -m "feat(api): persist dimensions + snapped ratio on KV uploaded base"
```

---

## Task 4 — Feature test for the new metadata (GATED)

**Files:**
- Modify: `tests/Feature/Studio/KvGenerationImportFromUploadTest.php`

- [ ] **Step 1: Verify DB isolation BEFORE touching Feature tests**

Read `api/phpunit.xml` and confirm lines:
```xml
<env name="DB_CONNECTION" value="sqlite"/>
<env name="DB_DATABASE" value=":memory:"/>
```
and `api/tests/Pest.php` applies `RefreshDatabase` to `Feature`. If either is missing/commented, **STOP** and tell the user (see `lesson_test_db_isolation.md`).

- [ ] **Step 2: Update the existing happy-path payload + add metadata assertions**

In `tests/Feature/Studio/KvGenerationImportFromUploadTest.php`, the existing happy-path `it(...)` payload must now include `width`/`height` (they are required). Update its `$payload` and add assertions:

```php
    $payload = [
        'image_url' => 'https://example.com/uploads/ref.png',
        'mime_type' => 'image/png',
        'size' => 123456,
        'original_filename' => 'brand-hero.png',
        'width' => 1920,
        'height' => 1080,
    ];
```

After the existing metadata assertions, add:

```php
    expect(data_get($gen->metadata, 'width'))->toBe(1920);
    expect(data_get($gen->metadata, 'height'))->toBe(1080);
    expect(data_get($gen->metadata, 'craft_supported'))->toBeTrue();
    expect(data_get($gen->metadata, 'aspect_ratio'))->toBe('16:9');
```

- [ ] **Step 3: Add an extreme-ratio case**

Append a new test:

```php
it('marks an extreme-ratio upload as craft_supported=false with no aspect_ratio', function () {
    $payload = [
        'image_url' => 'https://example.com/uploads/banner.png',
        'mime_type' => 'image/png',
        'size' => 200000,
        'original_filename' => 'cimb-banner.png',
        'width' => 2000,
        'height' => 582,
    ];

    $response = $this->postJson(
        "/api/v1/studio/kv-generator/files/{$this->file->id}/generations/import-from-upload",
        $payload,
    )->assertCreated();

    $gen = KvGeneration::findOrFail($response->json('data.id'));
    expect(data_get($gen->metadata, 'craft_supported'))->toBeFalse();
    expect(data_get($gen->metadata, 'aspect_ratio'))->toBeNull();
    expect(data_get($gen->metadata, 'width'))->toBe(2000);
});
```

- [ ] **Step 4: Add a validation case (missing dimensions → 422)**

```php
it('rejects an import missing width/height', function () {
    $response = $this->postJson(
        "/api/v1/studio/kv-generator/files/{$this->file->id}/generations/import-from-upload",
        [
            'image_url' => 'https://example.com/uploads/ref.png',
            'mime_type' => 'image/png',
            'size' => 123456,
        ],
    );
    $response->assertStatus(422);
});
```

- [ ] **Step 5 (GATED — ask user before running): run the focused file only**

Run: `cd api && ./vendor/bin/pest tests/Feature/Studio/KvGenerationImportFromUploadTest.php`
Expected: all pass. Run ONLY this file (`--filter` / explicit path), not the whole Feature suite, per the known backfill caveat.

- [ ] **Step 6: Commit**

```bash
git add tests/Feature/Studio/KvGenerationImportFromUploadTest.php
git commit -m "test(api): cover dimensions + snapped ratio on KV import-from-upload"
```

---

## Self-Review

- **Spec coverage:** capture dimensions (Task 3), snap rule >25% (Task 1), `aspect_ratio` label only when supported + `craft_supported` flag (Task 3), Craft sizing via existing ThreadController backfill (no change — documented in Architecture), no new image library (client-measured dims, Task 2). ✓
- **Types:** helper signature `KvAspectRatio::snap(int $w, int $h): ?string` is used identically in Task 3. Metadata keys `width`/`height`/`aspect_ratio`/`craft_supported` match the web plan's reads. ✓
- **Placeholders:** none — all steps carry concrete code/commands. ✓
