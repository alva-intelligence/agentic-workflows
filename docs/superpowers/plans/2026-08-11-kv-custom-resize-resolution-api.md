# KV Custom Resize Resolution — API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a client request a resize export at an arbitrary width × height, accepted only when the parent generation is layer-composed.

**Architecture:** A custom size is stored as a synthetic `platform_id` of the form `custom-{w}x{h}`, so it rides the existing `kv_resize_exports` table, its `(parent_generation_id, platform_id)` unique index, and the existing layer-composed short-circuit with no migration. The client sends structured `custom_sizes: [{width, height}]`; the server validates the numbers and synthesizes the id. A request carrying custom sizes for a non-layer-composed parent is refused with 422.

**Tech Stack:** PHP 8.5, Laravel 13, Pest 4, PostgreSQL.

**Spec:** `docs/superpowers/specs/2026-08-11-kv-custom-resize-resolution-design.md`

## Global Constraints

- Bounds are **64 to 8192 inclusive**, per side. Same numbers in web; they must not drift.
- Canonical id form is **`custom-{width}x{height}`**, e.g. `custom-1080x1350`. No leading zeros, lowercase `x`.
- Custom sizes are permitted **only** when `$parent->isLayerComposed()` is true.
- `platform_ids` keeps its existing `in:` rule against `config('studio.resize_platforms')`. Custom sizes never travel through that field.
- Follow api conventions: explicit return types, typed params, curly braces on all control structures, PHPDoc array shapes. Run `vendor/bin/pint --dirty --format agent` before every commit.
- Feature tests need a scratch Postgres — the SQLite config cannot migrate (`DROP SEQUENCE`). Run them as:
  `DB_DATABASE=frnd_test TELESCOPE_ENABLED=false php artisan test --compact --filter=<name>`

---

### Task 1: Custom size value object

A pure helper with no framework dependencies — id synthesis, parsing, bounds, and display label. Everything else in this plan depends on it, and it is fully unit-testable with no database.

**Files:**
- Create: `app/Support/Studio/CustomResizeSize.php`
- Test: `tests/Unit/Support/Studio/CustomResizeSizeTest.php`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `CustomResizeSize::MIN_DIMENSION` = `64` (int)
  - `CustomResizeSize::MAX_DIMENSION` = `8192` (int)
  - `CustomResizeSize::id(int $width, int $height): string`
  - `CustomResizeSize::isCustomId(string $platformId): bool`
  - `CustomResizeSize::parse(string $platformId): ?array` returning `array{width:int,height:int}` or `null`
  - `CustomResizeSize::label(int $width, int $height): string`

- [ ] **Step 1: Write the failing test**

Create `tests/Unit/Support/Studio/CustomResizeSizeTest.php`:

```php
<?php

use App\Support\Studio\CustomResizeSize;

it('synthesizes a canonical id', function () {
    expect(CustomResizeSize::id(1080, 1350))->toBe('custom-1080x1350');
});

it('recognizes its own ids and rejects preset ids', function () {
    expect(CustomResizeSize::isCustomId('custom-1080x1350'))->toBeTrue();
    expect(CustomResizeSize::isCustomId('instagram-post'))->toBeFalse();
    expect(CustomResizeSize::isCustomId('custom-tall'))->toBeFalse();
});

it('round-trips a canonical id', function () {
    expect(CustomResizeSize::parse('custom-1080x1350'))
        ->toBe(['width' => 1080, 'height' => 1350]);
});

it('rejects non-canonical forms', function (string $id) {
    expect(CustomResizeSize::parse($id))->toBeNull();
})->with([
    'leading zeros' => 'custom-01080x1350',
    'uppercase separator' => 'custom-1080X1350',
    'trailing junk' => 'custom-1080x1350x',
    'negative' => 'custom--10x20',
    'preset that starts with custom' => 'custom-tall',
    'empty dims' => 'custom-x',
]);

it('rejects dimensions outside the bounds', function (int $w, int $h) {
    expect(CustomResizeSize::parse(CustomResizeSize::id($w, $h)))->toBeNull();
})->with([
    'below min width' => [63, 1080],
    'below min height' => [1080, 63],
    'above max width' => [8193, 1080],
    'above max height' => [1080, 8193],
]);

it('accepts the exact bounds', function () {
    expect(CustomResizeSize::parse('custom-64x64'))
        ->toBe(['width' => 64, 'height' => 64]);
    expect(CustomResizeSize::parse('custom-8192x8192'))
        ->toBe(['width' => 8192, 'height' => 8192]);
});

it('builds a display label', function () {
    expect(CustomResizeSize::label(1080, 1350))->toBe('1080 × 1350');
});
```

Note the `custom-tall` case: it is a real preset id in `config/studio.php`, and it starts with `custom-`. A sloppy prefix check would swallow it. That is why `isCustomId` must be anchored on the full numeric pattern, not on `str_starts_with`.

- [ ] **Step 2: Run test to verify it fails**

Run: `php artisan test --compact --filter=CustomResizeSize`
Expected: FAIL — `Class "App\Support\Studio\CustomResizeSize" not found`.

- [ ] **Step 3: Write minimal implementation**

Create `app/Support/Studio/CustomResizeSize.php`:

```php
<?php

namespace App\Support\Studio;

/**
 * A user-specified resize target, encoded as a synthetic `platform_id`.
 *
 * Custom sizes ride the existing `kv_resize_exports` schema rather than a new
 * column: the table's unique `(parent_generation_id, platform_id)` index then
 * supplies dedup for free, and every consumer that treats `platform_id` as an
 * opaque string keeps working.
 *
 * The canonical form is `custom-{width}x{height}`. Parsing is deliberately
 * strict — it accepts only what {@see self::id()} emits — so an id can never
 * mean two things. Note that `custom-tall` is a genuine preset id, which is
 * why membership is decided by the anchored pattern and not by a prefix.
 */
final class CustomResizeSize
{
    /** Below this, projection math degenerates. */
    public const MIN_DIMENSION = 64;

    /**
     * Above this, flattening the tile risks exceeding the browser canvas
     * ceiling. 8192 squared is ~67M pixels, comfortably inside Chrome's limit,
     * so a per-side cap needs no companion area rule.
     */
    public const MAX_DIMENSION = 8192;

    private const PATTERN = '/^custom-([1-9]\d*)x([1-9]\d*)$/';

    public static function id(int $width, int $height): string
    {
        return "custom-{$width}x{$height}";
    }

    public static function isCustomId(string $platformId): bool
    {
        return self::parse($platformId) !== null;
    }

    /**
     * @return array{width:int,height:int}|null Null when `$platformId` is not
     *                                          a canonical custom id, or names
     *                                          dimensions outside the bounds.
     */
    public static function parse(string $platformId): ?array
    {
        if (preg_match(self::PATTERN, $platformId, $m) !== 1) {
            return null;
        }

        $width = (int) $m[1];
        $height = (int) $m[2];

        if (! self::withinBounds($width) || ! self::withinBounds($height)) {
            return null;
        }

        return ['width' => $width, 'height' => $height];
    }

    public static function label(int $width, int $height): string
    {
        return "{$width} × {$height}";
    }

    private static function withinBounds(int $value): bool
    {
        return $value >= self::MIN_DIMENSION && $value <= self::MAX_DIMENSION;
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `php artisan test --compact --filter=CustomResizeSize`
Expected: PASS, 7 tests.

- [ ] **Step 5: Format and commit**

```bash
vendor/bin/pint --dirty --format agent
git add app/Support/Studio/CustomResizeSize.php tests/Unit/Support/Studio/CustomResizeSizeTest.php
git commit -m "feat(api): encode a custom resize size as a synthetic platform id"
```

---

### Task 2: Accept and dimension custom rows in createBatch

`createBatch` currently throws on any id absent from the registry. Teach it the custom form. The layer-composed short-circuit already present needs no change — this task proves that custom rows inherit it.

**Files:**
- Modify: `app/Services/Studio/KvResizeExportService.php:31-73`
- Test: `tests/Unit/Services/Studio/KvResizeExportServiceTest.php`

**Interfaces:**
- Consumes: `CustomResizeSize::parse()` from Task 1.
- Produces: `createBatch` accepts custom ids in its existing `$platformIds` array. Signature unchanged.

- [ ] **Step 1: Write the failing test**

Append to `tests/Unit/Services/Studio/KvResizeExportServiceTest.php`:

```php
it('dimensions a custom row from its id', function () {
    $this->generation->update(['metadata' => ['layer_composed' => true]]);

    $rows = $this->service->createBatch(
        $this->file,
        $this->generation->refresh(),
        ['custom-1240x1750'],
        cropWindowMap: [],
        userId: $this->user->id,
    );

    expect($rows)->toHaveCount(1);
    expect($rows->first()->width)->toBe(1240);
    expect($rows->first()->height)->toBe(1750);
});

it('completes a custom row immediately and dispatches no job', function () {
    $this->generation->update(['metadata' => ['layer_composed' => true]]);

    $rows = $this->service->createBatch(
        $this->file,
        $this->generation->refresh(),
        ['custom-1240x1750'],
        cropWindowMap: [],
        userId: $this->user->id,
    );

    expect($rows->first()->status)->toBe(KvResizeExportStatus::Done);
    Queue::assertNotPushed(ProcessKvResizeExportJob::class);
});

it('returns the existing row when the same custom size is requested twice', function () {
    $this->generation->update(['metadata' => ['layer_composed' => true]]);
    $parent = $this->generation->refresh();

    $first = $this->service->createBatch(
        $this->file, $parent, ['custom-1240x1750'],
        cropWindowMap: [], userId: $this->user->id,
    );
    $second = $this->service->createBatch(
        $this->file, $parent, ['custom-1240x1750'],
        cropWindowMap: [], userId: $this->user->id,
    );

    expect($second->first()->id)->toBe($first->first()->id);
    expect(KvResizeExport::where('parent_generation_id', $parent->id)->count())->toBe(1);
});

it('still rejects an unknown non-custom platform id', function () {
    $this->service->createBatch(
        $this->file,
        $this->generation,
        ['not-a-platform'],
        cropWindowMap: [],
        userId: $this->user->id,
    );
})->throws(InvalidArgumentException::class, 'Unknown platform: not-a-platform');
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DB_DATABASE=frnd_test TELESCOPE_ENABLED=false php artisan test --compact --filter=KvResizeExportService`
Expected: FAIL — the custom tests throw `Unknown platform: custom-1240x1750`.

- [ ] **Step 3: Write minimal implementation**

In `app/Services/Studio/KvResizeExportService.php`, add the import:

```php
use App\Support\Studio\CustomResizeSize;
```

Then replace the registry lookup inside the `foreach` (currently lines 44–47):

```php
            $platform = $registry->firstWhere('id', $platformId);
            if (! $platform) {
                throw new InvalidArgumentException("Unknown platform: {$platformId}");
            }
```

with:

```php
            // A custom size carries its dimensions in its id, so it needs no
            // registry entry. Anything else that is absent from the registry
            // is still a programming error.
            $custom = CustomResizeSize::parse($platformId);
            $platform = $custom ?? $registry->firstWhere('id', $platformId);

            if (! $platform) {
                throw new InvalidArgumentException("Unknown platform: {$platformId}");
            }
```

`$platform['width']` and `$platform['height']` at lines 57–58 now read from either source, because `CustomResizeSize::parse()` returns exactly those two keys. No other line in the method changes.

- [ ] **Step 4: Run test to verify it passes**

Run: `DB_DATABASE=frnd_test TELESCOPE_ENABLED=false php artisan test --compact --filter=KvResizeExportService`
Expected: PASS, including the pre-existing tests.

- [ ] **Step 5: Format and commit**

```bash
vendor/bin/pint --dirty --format agent
git add app/Services/Studio/KvResizeExportService.php tests/Unit/Services/Studio/KvResizeExportServiceTest.php
git commit -m "feat(api): dimension a custom resize row from its synthetic id"
```

---

### Task 3: Validate the request and enforce the gate

The security-relevant task. A custom size reaching a non-layer-composed parent must be refused by the server, not merely hidden by the UI — that is the exact mistake the 2026-08-06 spec had to correct for `craft_supported`.

**Files:**
- Modify: `app/Http/Controllers/Api/Studio/KvResizeExportController.php:82-131`
- Test: `tests/Feature/Studio/KvResizeExportControllerTest.php`

**Interfaces:**
- Consumes: `CustomResizeSize::id()`, `CustomResizeSize::MIN_DIMENSION`, `CustomResizeSize::MAX_DIMENSION` from Task 1; `createBatch` from Task 2.
- Produces: `POST /v1/studio/files/{file}/resize-exports` accepts an optional `custom_sizes` array of `{width, height}`.

- [ ] **Step 1: Write the failing test**

Append to `tests/Feature/Studio/KvResizeExportControllerTest.php`. Match the file's existing setup for authenticating a user and creating a file plus generation — read the top of the file first and reuse its helpers rather than inventing new ones.

```php
it('creates a custom-size export for a layer-composed parent', function () {
    $this->generation->update(['metadata' => ['layer_composed' => true]]);

    $res = $this->postJson("/api/v1/studio/files/{$this->file->id}/resize-exports", [
        'parent_generation_id' => $this->generation->id,
        'custom_sizes' => [['width' => 1240, 'height' => 1750]],
    ]);

    $res->assertStatus(202); // store() returns 202 Accepted, not 201
    expect($res->json('data.0.platform_id'))->toBe('custom-1240x1750');
    expect($res->json('data.0.width'))->toBe(1240);
    expect($res->json('data.0.height'))->toBe(1750);
});

it('refuses a custom size when the parent is not layer-composed', function () {
    $this->generation->update(['metadata' => []]);

    $this->postJson("/api/v1/studio/files/{$this->file->id}/resize-exports", [
        'parent_generation_id' => $this->generation->id,
        'custom_sizes' => [['width' => 1240, 'height' => 1750]],
    ])->assertStatus(422)->assertJsonValidationErrors('custom_sizes');
});

it('rejects custom dimensions outside the bounds', function (int $w, int $h) {
    $this->generation->update(['metadata' => ['layer_composed' => true]]);

    $this->postJson("/api/v1/studio/files/{$this->file->id}/resize-exports", [
        'parent_generation_id' => $this->generation->id,
        'custom_sizes' => [['width' => $w, 'height' => $h]],
    ])->assertStatus(422);
})->with([
    'below min' => [63, 1080],
    'above max' => [8193, 1080],
    'below min height' => [1080, 63],
    'above max height' => [1080, 8193],
]);

it('rejects a request naming neither presets nor custom sizes', function () {
    $this->postJson("/api/v1/studio/files/{$this->file->id}/resize-exports", [
        'parent_generation_id' => $this->generation->id,
    ])->assertStatus(422)->assertJsonValidationErrors('platform_ids');
});

it('still accepts a presets-only request', function () {
    $this->postJson("/api/v1/studio/files/{$this->file->id}/resize-exports", [
        'parent_generation_id' => $this->generation->id,
        'platform_ids' => ['instagram-post'],
    ])->assertStatus(202);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DB_DATABASE=frnd_test TELESCOPE_ENABLED=false php artisan test --compact --filter=KvResizeExportController`
Expected: FAIL — `custom_sizes` is not yet a recognized field, so the first test 422s on the now-missing `platform_ids`.

- [ ] **Step 3: Write minimal implementation**

In `app/Http/Controllers/Api/Studio/KvResizeExportController.php`, add the import:

```php
use App\Support\Studio\CustomResizeSize;
```

Replace the `$validated = $request->validate([...]);` block (lines 89–95) with:

```php
        $min = CustomResizeSize::MIN_DIMENSION;
        $max = CustomResizeSize::MAX_DIMENSION;

        $validated = $request->validate([
            'parent_generation_id' => 'required|string',
            // Relaxed from `required` because a request may now legitimately
            // carry only custom sizes. The "at least one target" rule moves to
            // the pair via required_without_all.
            //
            // Do NOT add `sometimes` here. Validator::passesOptionalCheck()
            // is keyed on the attribute, not the rule: when `sometimes` is
            // present and the field is absent, isValidatable() skips EVERY
            // rule for that field — including implicit ones like
            // required_without_all. A request naming neither field would then
            // pass instead of 422ing.
            'platform_ids' => 'array|required_without_all:custom_sizes',
            'platform_ids.*' => ['required', 'string', 'in:'.implode(',', $registryIds)],
            'custom_sizes' => 'sometimes|array|max:20',
            'custom_sizes.*.width' => "required|integer|min:{$min}|max:{$max}",
            'custom_sizes.*.height' => "required|integer|min:{$min}|max:{$max}",
            'crop_windows' => 'nullable|array',
            'additional_prompt' => 'nullable|string|max:1000',
        ]);
```

Then, immediately **after** the `$parent = KvGeneration::…->firstOrFail();` block (currently ending line 109), insert the gate and the id synthesis:

```php
        $customSizes = $validated['custom_sizes'] ?? [];

        // The gate. A layer-composed parent resizes by deterministic layer
        // projection — no model call, no credit — so any target size is free
        // and exact. An AI-generated parent resizes by outpainting, where an
        // arbitrary size costs credits and degrades at extreme ratios.
        //
        // This check is not redundant with the UI hiding the control. A
        // request that slips past the UI is exactly how `craft_supported`
        // failed before it was enforced server-side.
        if ($customSizes !== [] && ! $parent->isLayerComposed()) {
            throw ValidationException::withMessages([
                'custom_sizes' => 'Ukuran kustom hanya tersedia untuk KV yang disusun dari layer (impor PSD atau Magic Layers).',
            ]);
        }

        $platformIds = array_values(array_unique([
            ...($validated['platform_ids'] ?? []),
            ...array_map(
                static fn (array $size): string => CustomResizeSize::id($size['width'], $size['height']),
                $customSizes,
            ),
        ]));
```

Add the import for the exception:

```php
use Illuminate\Validation\ValidationException;
```

Finally, replace every remaining use of `$validated['platform_ids']` in the method with `$platformIds` — there are two: the `platformIds:` argument to `createBatch` (line 114) and the first argument to `writeBatchMarker` (line 125).

- [ ] **Step 4: Run test to verify it passes**

Run: `DB_DATABASE=frnd_test TELESCOPE_ENABLED=false php artisan test --compact --filter=KvResizeExportController`
Expected: PASS, including the pre-existing tests in that file.

- [ ] **Step 5: Format and commit**

```bash
vendor/bin/pint --dirty --format agent
git add app/Http/Controllers/Api/Studio/KvResizeExportController.php tests/Feature/Studio/KvResizeExportControllerTest.php
git commit -m "feat(api): accept custom resize sizes, gated on a layer-composed parent"
```

---

### Task 4: Label custom rows on read

`KvResizeExportResource` already degrades on a registry miss — label falls back to the raw id, group to null. That yields `"custom-1240x1750"` as a display label and a null group. Give the UI something real.

**Files:**
- Modify: `app/Http/Resources/Studio/KvResizeExportResource.php:10-32`
- Test: `tests/Unit/Http/Resources/KvResizeExportResourceTest.php` (create)

**Interfaces:**
- Consumes: `CustomResizeSize::parse()`, `CustomResizeSize::label()` from Task 1.
- Produces: for a custom row, `platform_label` is `"1240 × 1750"` and `platform_group` is `"custom"`. Web's `PlatformGroup` must include `"custom"` — see the web plan, Task 1.

- [ ] **Step 1: Write the failing test**

Create `tests/Unit/Http/Resources/KvResizeExportResourceTest.php`:

```php
<?php

use App\Http\Resources\Studio\KvResizeExportResource;
use App\Models\KvResizeExport;

it('labels a custom row from its dimensions', function () {
    $row = new KvResizeExport([
        'platform_id' => 'custom-1240x1750',
        'width' => 1240,
        'height' => 1750,
    ]);

    $out = (new KvResizeExportResource($row))->toArray(request());

    expect($out['platform_label'])->toBe('1240 × 1750');
    expect($out['platform_group'])->toBe('custom');
});

it('still labels a preset row from the registry', function () {
    $row = new KvResizeExport([
        'platform_id' => 'instagram-post',
        'width' => 1080,
        'height' => 1080,
    ]);

    $out = (new KvResizeExportResource($row))->toArray(request());

    expect($out['platform_label'])->toBe('Instagram Post');
    expect($out['platform_group'])->toBe('social-media');
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `php artisan test --compact --filter=KvResizeExportResource`
Expected: FAIL — `platform_label` is `'custom-1240x1750'`, `platform_group` is `null`.

- [ ] **Step 3: Write minimal implementation**

In `app/Http/Resources/Studio/KvResizeExportResource.php`, add the import:

```php
use App\Support\Studio\CustomResizeSize;
```

Replace the two derived lines in `toArray`:

```php
            'platform_label' => $platform['label'] ?? $this->platform_id,
            'platform_group' => $platform['group'] ?? null,
```

with:

```php
            'platform_label' => $platform['label']
                ?? ($custom ? CustomResizeSize::label($custom['width'], $custom['height']) : $this->platform_id),
            'platform_group' => $platform['group'] ?? ($custom ? 'custom' : null),
```

and add, just below the existing `$platform` assignment:

```php
        $custom = CustomResizeSize::parse((string) $this->platform_id);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `php artisan test --compact --filter=KvResizeExportResource`
Expected: PASS, 2 tests.

- [ ] **Step 5: Format and commit**

```bash
vendor/bin/pint --dirty --format agent
git add app/Http/Resources/Studio/KvResizeExportResource.php tests/Unit/Http/Resources/KvResizeExportResourceTest.php
git commit -m "feat(api): give custom resize rows a real label and group"
```

---

### Task 5: Full suite check

- [ ] **Step 1: Run every touched suite**

```bash
DB_DATABASE=frnd_test TELESCOPE_ENABLED=false php artisan test --compact --filter="KvResize|CustomResizeSize"
```

Expected: all green. If a pre-existing failure appears that you did not cause, confirm it against `develop` before treating it as yours — this suite has a documented history of environment-driven reds.

- [ ] **Step 2: Lint**

```bash
vendor/bin/pint --dirty --format agent
```

Expected: no changes reported.
