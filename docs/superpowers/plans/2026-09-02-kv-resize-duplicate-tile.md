# KV Resize — Duplicate a custom-size tile — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user duplicate an existing custom-size KV Resize tile, producing an independent tile at the same dimensions seeded from the source's overlay snapshot and crop window.

**Architecture:** The custom `platform_id` grammar gains an optional ordinal (`custom-100x200-2`), so a size can back more than one tile while the DB's `(parent_generation_id, platform_id)` unique index stays intact. The server allocates the ordinal as `max + 1` on a new `duplicate` endpoint; the unique index is the arbiter and the endpoint retries on violation. Both entry points (canvas tile action cluster, panel hover icon) call that one endpoint.

**Tech Stack:** api — Laravel 13 / PHP 8.5, Pest, PostgreSQL. web — Next.js 16 / React 19, TypeScript, TanStack Query v5, `bun test` with Testing Library.

**Spec:** `docs/superpowers/specs/2026-09-02-kv-resize-duplicate-tile-design.md`

## Global Constraints

- Dimension bounds stay in lockstep across services: min `64`, max `8192` (`CUSTOM_SIZE_MIN`/`CUSTOM_SIZE_MAX` in web, `CustomResizeSize::MIN_DIMENSION`/`MAX_DIMENSION` in api).
- Ordinal is `>= 2`. The regex group is `(?:[2-9]|[1-9]\d+)` — **not** `[2-9]\d*`, which wrongly rejects `-10`. `-1` must be rejected so `custom-100x200` has exactly one spelling.
- `id(w, h, 1)` and `id(w, h, null)` both emit the bare form. Never `custom-100x200-1`.
- Label: `100 × 200` for ordinal 1, `100 × 200 (n)` otherwise. The separator is U+00D7 (`×`), not the letter `x`.
- The duplicate route carries **no** `check.credits` middleware. No model call, no credit.
- The duplicate copies `overlays`, `crop_window`, `additional_prompt`. It does **not** copy `metadata`.
- No chat marker is written for a duplicate.
- Only custom-size tiles can be duplicated. Preset tiles are out of scope.
- api Feature tests need a scratch PostgreSQL — SQLite cannot run this repo's migrations. Pass test **paths**, not `--filter`.
- web tests run with `bun test <path>` per file. Never run it on a directory.

---

### Task 1: Ordinal in the api id grammar

**Files:**
- Modify: `api/app/Support/Studio/CustomResizeSize.php`
- Test: `api/tests/Unit/Support/Studio/CustomResizeSizeTest.php`

**Interfaces:**
- Consumes: nothing.
- Produces: `CustomResizeSize::id(int $width, int $height, ?int $ordinal = null): string`; `CustomResizeSize::parse(string $platformId): ?array{width:int,height:int,ordinal:int}`; `CustomResizeSize::label(int $width, int $height, int $ordinal = 1): string`; `CustomResizeSize::labelFor(string $platformId): ?string`. `isCustomId()` keeps its signature.

**Note before you start:** `parse()` currently returns a two-key array and the existing test asserts it with `toBe()`, which is strict. Adding `ordinal` breaks three existing assertions. Updating them is part of this task, not a surprise.

- [ ] **Step 1: Write the failing tests**

Append to `api/tests/Unit/Support/Studio/CustomResizeSizeTest.php`:

```php
it('appends an ordinal from the second tile onward', function () {
    expect(CustomResizeSize::id(100, 200, 2))->toBe('custom-100x200-2');
    expect(CustomResizeSize::id(100, 200, 10))->toBe('custom-100x200-10');
});

it('never emits a second spelling of the first tile', function () {
    expect(CustomResizeSize::id(100, 200))->toBe('custom-100x200');
    expect(CustomResizeSize::id(100, 200, null))->toBe('custom-100x200');
    expect(CustomResizeSize::id(100, 200, 1))->toBe('custom-100x200');
});

it('parses an ordinal, defaulting the bare form to 1', function () {
    expect(CustomResizeSize::parse('custom-100x200'))
        ->toBe(['width' => 100, 'height' => 200, 'ordinal' => 1]);
    expect(CustomResizeSize::parse('custom-100x200-2'))
        ->toBe(['width' => 100, 'height' => 200, 'ordinal' => 2]);
    expect(CustomResizeSize::parse('custom-100x200-10'))
        ->toBe(['width' => 100, 'height' => 200, 'ordinal' => 10]);
});

it('rejects ordinals that would make one tile answer to two ids', function (string $id) {
    expect(CustomResizeSize::parse($id))->toBeNull();
})->with([
    'ordinal one is the bare form' => 'custom-100x200-1',
    'ordinal zero' => 'custom-100x200-0',
    'leading zero ordinal' => 'custom-100x200-02',
    'empty ordinal' => 'custom-100x200-',
    'non-numeric ordinal' => 'custom-100x200-a',
    'two ordinals' => 'custom-100x200-2-3',
]);

it('labels an ordinal but leaves the first tile bare', function () {
    expect(CustomResizeSize::label(100, 200))->toBe('100 × 200');
    expect(CustomResizeSize::label(100, 200, 1))->toBe('100 × 200');
    expect(CustomResizeSize::label(100, 200, 2))->toBe('100 × 200 (2)');
    expect(CustomResizeSize::labelFor('custom-100x200-2'))->toBe('100 × 200 (2)');
    expect(CustomResizeSize::labelFor('custom-100x200'))->toBe('100 × 200');
});
```

Then fix the three existing assertions that `toBe()` a two-key array — in `it('round-trips a canonical id')` and `it('accepts the exact bounds')` — by adding `'ordinal' => 1` to each expected array.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd api && ./vendor/bin/pest tests/Unit/Support/Studio/CustomResizeSizeTest.php
```

Expected: FAIL — `id()` rejects a third argument, and `parse()` returns no `ordinal` key.

- [ ] **Step 3: Implement**

In `api/app/Support/Studio/CustomResizeSize.php`, replace the pattern constant and the four methods:

```php
    private const PATTERN = '/^custom-([1-9]\d*)x([1-9]\d*)(?:-([2-9]|[1-9]\d+))?\z/';

    /**
     * The canonical id for a size. `$ordinal` numbers the second and later
     * tiles of the same size; 1 and null both mean the first, which carries
     * no suffix. Emitting `-1` would give one tile two spellings.
     */
    public static function id(int $width, int $height, ?int $ordinal = null): string
    {
        $base = "custom-{$width}x{$height}";

        return $ordinal === null || $ordinal <= 1 ? $base : "{$base}-{$ordinal}";
    }

    /**
     * @return array{width:int,height:int,ordinal:int}|null Null when
     *                                                     `$platformId` is not
     *                                                     a canonical custom
     *                                                     id, or names
     *                                                     dimensions outside
     *                                                     the bounds.
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

        return [
            'width' => $width,
            'height' => $height,
            'ordinal' => ($m[3] ?? '') === '' ? 1 : (int) $m[3],
        ];
    }

    public static function label(int $width, int $height, int $ordinal = 1): string
    {
        $base = "{$width} × {$height}";

        return $ordinal <= 1 ? $base : "{$base} ({$ordinal})";
    }

    public static function labelFor(string $platformId): ?string
    {
        $custom = self::parse($platformId);

        return $custom === null
            ? null
            : self::label($custom['width'], $custom['height'], $custom['ordinal']);
    }
```

Then rewrite the class docblock's dedup claim. It currently says the unique index "supplies dedup for free"; that was true when a size backed exactly one tile. Replace that sentence with:

```
 * Custom sizes ride the existing `kv_resize_exports` schema rather than a new
 * column, so every consumer that treats `platform_id` as an opaque string
 * keeps working. The table's unique `(parent_generation_id, platform_id)`
 * index no longer means "one tile per size" — an ordinal lets a size back
 * several tiles — but it remains the arbiter that keeps two tiles from
 * claiming the same ordinal.
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd api && ./vendor/bin/pest tests/Unit/Support/Studio/CustomResizeSizeTest.php
```

Expected: PASS, all cases.

- [ ] **Step 5: Verify nothing else read the two-key shape**

```bash
cd api && grep -rn "CustomResizeSize::parse" app --include="*.php"
```

Expected: every call site either uses `['width']`/`['height']` (still present) or passes the array straight into `$platform['width']`-style access. `KvResizeExportService::createBatch` does the latter and needs no change. If a call site destructures with `list()` or `array_values()`, fix it here.

- [ ] **Step 6: Commit**

```bash
cd api && git add app/Support/Studio/CustomResizeSize.php tests/Unit/Support/Studio/CustomResizeSizeTest.php
git commit -m "feat(api): ordinal in the custom resize size id grammar"
```

---

### Task 2: Service — allocate an ordinal and clone the row

**Files:**
- Modify: `api/app/Services/Studio/KvResizeExportService.php`
- Test: `api/tests/Feature/Studio/KvResizeExportDuplicateTest.php` (create)

**Interfaces:**
- Consumes: `CustomResizeSize::id()`, `CustomResizeSize::parse()` from Task 1.
- Produces: `KvResizeExportService::duplicate(KvResizeExport $source, string $userId): KvResizeExport`. Throws `InvalidArgumentException` when `$source->platform_id` is not a custom id.

**Design note that diverges from the spec, deliberately:** the spec says "inside a transaction". Do **not** wrap this in one. In PostgreSQL a unique violation aborts the surrounding transaction, so a retry inside it would fail on the next statement. The correct shape is a bare insert plus a retry loop — the unique index is the arbiter either way, and a single insert needs no atomicity beyond its own.

- [ ] **Step 1: Write the failing test**

Create `api/tests/Feature/Studio/KvResizeExportDuplicateTest.php`. Copy the `beforeEach` block verbatim from `api/tests/Feature/Studio/KvResizeExportControllerTest.php` (lines 1–66: the imports, the user/workspace/role/credit/tool/file/generation setup, and the `actingAs`), then append this so the generation is layer-composed and a custom source tile exists:

```php
beforeEach(function () {
    $this->generation->update(['metadata' => ['layer_composed' => true]]);

    $this->source = KvResizeExport::factory()->create([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $this->generation->id,
        'created_by' => $this->user->id,
        'platform_id' => 'custom-100x200',
        'width' => 100,
        'height' => 200,
        'status' => KvResizeExportStatus::Done,
        'image_url' => null,
        'crop_window' => ['x' => 1, 'y' => 2, 'w' => 3, 'h' => 4],
        'overlays' => [['id' => 'ov-1', 'type' => 'text']],
        'additional_prompt' => 'keep the logo clear',
        'metadata' => ['pending_region_edit' => ['boxes' => []]],
    ]);
});

it('clones the tile under the next ordinal', function () {
    $row = app(App\Services\Studio\KvResizeExportService::class)
        ->duplicate($this->source, $this->user->id);

    expect($row->platform_id)->toBe('custom-100x200-2');
    expect($row->width)->toBe(100);
    expect($row->height)->toBe(200);
    expect($row->status)->toBe(KvResizeExportStatus::Done);
    expect($row->image_url)->toBeNull();
    expect($row->id)->not->toBe($this->source->id);
});

it('copies the overlay snapshot, crop window and prompt', function () {
    $row = app(App\Services\Studio\KvResizeExportService::class)
        ->duplicate($this->source, $this->user->id);

    expect($row->overlays)->toBe([['id' => 'ov-1', 'type' => 'text']]);
    expect($row->crop_window)->toBe(['x' => 1, 'y' => 2, 'w' => 3, 'h' => 4]);
    expect($row->additional_prompt)->toBe('keep the logo clear');
});

it('does not carry the source metadata across', function () {
    $row = app(App\Services\Studio\KvResizeExportService::class)
        ->duplicate($this->source, $this->user->id);

    expect($row->metadata)->toBeNull();
});

it('counts up and never renumbers an existing tile', function () {
    $service = app(App\Services\Studio\KvResizeExportService::class);

    $second = $service->duplicate($this->source, $this->user->id);
    $third = $service->duplicate($this->source, $this->user->id);

    expect($second->platform_id)->toBe('custom-100x200-2');
    expect($third->platform_id)->toBe('custom-100x200-3');
    expect($this->source->fresh()->platform_id)->toBe('custom-100x200');
});

it('ignores a preset row that happens to share the dimensions', function () {
    KvResizeExport::factory()->create([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $this->generation->id,
        'created_by' => $this->user->id,
        'platform_id' => 'instagram-post',
        'width' => 100,
        'height' => 200,
    ]);

    $row = app(App\Services\Studio\KvResizeExportService::class)
        ->duplicate($this->source, $this->user->id);

    expect($row->platform_id)->toBe('custom-100x200-2');
});

it('records the duplicating user, not the source author', function () {
    $other = User::factory()->create();

    $row = app(App\Services\Studio\KvResizeExportService::class)
        ->duplicate($this->source, $other->id);

    expect($row->created_by)->toBe($other->id);
});

it('refuses a preset source', function () {
    $preset = KvResizeExport::factory()->create([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $this->generation->id,
        'created_by' => $this->user->id,
        'platform_id' => 'instagram-post',
        'width' => 1080,
        'height' => 1080,
    ]);

    expect(fn () => app(App\Services\Studio\KvResizeExportService::class)
        ->duplicate($preset, $this->user->id))
        ->toThrow(InvalidArgumentException::class);
});

it('dispatches no job — a layer-composed tile needs no render', function () {
    app(App\Services\Studio\KvResizeExportService::class)
        ->duplicate($this->source, $this->user->id);

    Queue::assertNothingPushed();
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd api && ./vendor/bin/pest tests/Feature/Studio/KvResizeExportDuplicateTest.php
```

Expected: FAIL — `Call to undefined method ...::duplicate()`.

If instead it fails with a migration or connection error, stop and fix the test database first: this repo needs a scratch PostgreSQL, and a stale `bootstrap/cache/config.php` will hijack the connection.

- [ ] **Step 3: Implement**

Add to the imports at the top of `api/app/Services/Studio/KvResizeExportService.php`:

```php
use Illuminate\Database\UniqueConstraintViolationException;
use RuntimeException;
```

Add these two methods to the class, after `createBatch`:

```php
    /**
     * Clone a custom-size tile under the next free ordinal.
     *
     * The copy is seeded from the source's overlay snapshot and crop window,
     * so it starts as an exact copy of what the user is looking at and
     * diverges only when they move something. `metadata` is deliberately NOT
     * carried across: it holds caches and markers bound to one render's
     * lifecycle, and a pending region-edit marker riding along would post a
     * "region edit applied" message for an edit this row never had.
     *
     * Not wrapped in a transaction. A unique violation aborts the surrounding
     * transaction in PostgreSQL, so the retry below has to happen outside one;
     * a single insert needs no atomicity beyond its own anyway.
     */
    public function duplicate(KvResizeExport $source, string $userId): KvResizeExport
    {
        $custom = CustomResizeSize::parse($source->platform_id);

        if ($custom === null) {
            throw new InvalidArgumentException(
                "Only a custom size can be duplicated: {$source->platform_id}"
            );
        }

        for ($attempt = 0; $attempt < 3; $attempt++) {
            $ordinal = $this->nextOrdinal(
                $source->parent_generation_id,
                $custom['width'],
                $custom['height'],
            );

            try {
                return KvResizeExport::create([
                    'studio_file_id' => $source->studio_file_id,
                    'parent_generation_id' => $source->parent_generation_id,
                    'created_by' => $userId,
                    'platform_id' => CustomResizeSize::id(
                        $custom['width'],
                        $custom['height'],
                        $ordinal,
                    ),
                    'width' => $custom['width'],
                    'height' => $custom['height'],
                    // Layer-composed parents finish immediately with no image:
                    // pixels are assembled on demand. Same as createBatch.
                    'status' => KvResizeExportStatus::Done,
                    'image_url' => null,
                    'crop_window' => $source->crop_window,
                    'overlays' => $source->overlays,
                    'additional_prompt' => $source->additional_prompt,
                ]);
            } catch (UniqueConstraintViolationException) {
                // Two duplicates in flight claimed the same ordinal. The
                // unique index is the arbiter; recompute and try again.
                continue;
            }
        }

        throw new RuntimeException(
            "Could not allocate a free ordinal for {$source->platform_id}"
        );
    }

    /**
     * The next ordinal for a size under one parent.
     *
     * Filters on the `width`/`height` columns rather than a LIKE over
     * `platform_id`, and lets `parse()` discard presets that happen to share
     * the dimensions. Counting from live rows only is what makes an ordinal
     * freed by a deletion reusable — safe here because the controller
     * hard-deletes, so no tombstone holds the number against the unique index.
     */
    private function nextOrdinal(string $parentGenerationId, int $width, int $height): int
    {
        $highest = 1;

        $ids = KvResizeExport::query()
            ->where('parent_generation_id', $parentGenerationId)
            ->where('width', $width)
            ->where('height', $height)
            ->pluck('platform_id');

        foreach ($ids as $id) {
            $parsed = CustomResizeSize::parse($id);

            if ($parsed !== null) {
                $highest = max($highest, $parsed['ordinal']);
            }
        }

        return $highest + 1;
    }
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd api && ./vendor/bin/pest tests/Feature/Studio/KvResizeExportDuplicateTest.php
```

Expected: PASS, all eight cases.

- [ ] **Step 5: Commit**

```bash
cd api && git add app/Services/Studio/KvResizeExportService.php tests/Feature/Studio/KvResizeExportDuplicateTest.php
git commit -m "feat(api): KvResizeExportService::duplicate clones a custom tile"
```

---

### Task 3: The duplicate endpoint

**Files:**
- Modify: `api/app/Http/Controllers/Api/Studio/KvResizeExportController.php`
- Modify: `api/routes/api.php` (beside the existing `resize-exports/{export}/regenerate` route, around line 4118)
- Test: `api/tests/Feature/Studio/KvResizeExportDuplicateTest.php`

**Interfaces:**
- Consumes: `KvResizeExportService::duplicate(KvResizeExport $source, string $userId): KvResizeExport` from Task 2; `CustomResizeSize::isCustomId()` from Task 1.
- Produces: `POST v1/studio/files/{file}/resize-exports/{export}/duplicate` → `201` with `{ data: KvResizeExportResource }`.

- [ ] **Step 1: Write the failing test**

Append to `api/tests/Feature/Studio/KvResizeExportDuplicateTest.php`:

```php
it('duplicates a tile over HTTP', function () {
    $response = $this->postJson(
        "/api/v1/studio/files/{$this->file->id}/resize-exports/{$this->source->id}/duplicate"
    );

    $response->assertCreated();
    expect($response->json('data.platform_id'))->toBe('custom-100x200-2');
    expect($response->json('data.id'))->not->toBe($this->source->id);
});

it('rejects duplicating a preset tile', function () {
    $preset = KvResizeExport::factory()->create([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $this->generation->id,
        'created_by' => $this->user->id,
        'platform_id' => 'instagram-post',
        'width' => 1080,
        'height' => 1080,
    ]);

    $this->postJson(
        "/api/v1/studio/files/{$this->file->id}/resize-exports/{$preset->id}/duplicate"
    )->assertStatus(422);
});

it('rejects duplicating when the parent is not layer-composed', function () {
    $this->generation->update(['metadata' => ['layer_composed' => false]]);

    $this->postJson(
        "/api/v1/studio/files/{$this->file->id}/resize-exports/{$this->source->id}/duplicate"
    )->assertStatus(422);
});

it('404s for an export belonging to another file', function () {
    $otherFile = StudioFile::factory()->create([
        'workspace_id' => $this->workspace->id,
        'brand_id' => $this->brand->id,
        'tool_id' => $this->file->tool_id,
        'created_by' => $this->user->id,
        'last_edited_by' => $this->user->id,
    ]);

    $this->postJson(
        "/api/v1/studio/files/{$otherFile->id}/resize-exports/{$this->source->id}/duplicate"
    )->assertStatus(404);
});

it('403s for a file in another workspace', function () {
    $otherWorkspace = Workspace::factory()->create(['type' => 'organization']);
    $foreignFile = StudioFile::factory()->create([
        'workspace_id' => $otherWorkspace->id,
        'brand_id' => $this->brand->id,
        'tool_id' => $this->file->tool_id,
        'created_by' => $this->user->id,
        'last_edited_by' => $this->user->id,
    ]);

    $this->postJson(
        "/api/v1/studio/files/{$foreignFile->id}/resize-exports/{$this->source->id}/duplicate"
    )->assertStatus(403);
});

it('spends no credits', function () {
    $before = UserWorkspaceCredit::where('user_id', $this->user->id)
        ->where('workspace_id', $this->workspace->id)
        ->value('credits');

    $this->postJson(
        "/api/v1/studio/files/{$this->file->id}/resize-exports/{$this->source->id}/duplicate"
    )->assertCreated();

    $after = UserWorkspaceCredit::where('user_id', $this->user->id)
        ->where('workspace_id', $this->workspace->id)
        ->value('credits');

    expect($after)->toBe($before);
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd api && ./vendor/bin/pest tests/Feature/Studio/KvResizeExportDuplicateTest.php
```

Expected: FAIL — 404, the route does not exist yet.

- [ ] **Step 3: Add the controller action**

In `api/app/Http/Controllers/Api/Studio/KvResizeExportController.php`, add after `regenerate()`:

```php
    /**
     * Clone a custom-size tile so two tiles of the same size can be edited
     * independently.
     *
     * No credits and no marker: unlike store/regenerate this is not a
     * generation event — a layer-composed tile is projected, not rendered.
     */
    public function duplicate(Request $request, string $fileId, string $exportId): JsonResponse
    {
        $file = StudioFile::findOrFail($fileId);
        abort_unless($file->workspace_id === $request->user()->current_workspace_id, 403);

        $source = KvResizeExport::findOrFail($exportId);
        abort_unless($source->studio_file_id === $file->id, 404);

        if (! CustomResizeSize::isCustomId($source->platform_id)) {
            throw ValidationException::withMessages([
                'export' => 'Only a custom-size tile can be duplicated.',
            ]);
        }

        // Implied by the check above today — a custom id can only have been
        // created on a layer-composed parent, and that never changes. Kept as
        // defence in depth for the same reason createBatch documents: a custom
        // size on an AI-generated parent would bill credits for an outpaint
        // the layer path gives away free. Cheap assertion, expensive failure.
        if (! $source->parentGeneration?->isLayerComposed()) {
            throw ValidationException::withMessages([
                'export' => 'Custom sizes are only available for KVs composed from layers (PSD import or Magic Layers).',
            ]);
        }

        $row = $this->service->duplicate($source, $request->user()->id);

        return response()->json([
            'data' => (new KvResizeExportResource($row))->resolve(),
        ], Response::HTTP_CREATED);
    }
```

- [ ] **Step 4: Register the route**

In `api/routes/api.php`, directly after the `resize-exports/{export}/regenerate` route, add — **without** `check.credits`:

```php
                            // No check.credits: a duplicate projects an
                            // existing layer-composed tile, so there is no
                            // model call to bill for.
                            Route::post(
                                'files/{file}/resize-exports/{export}/duplicate',
                                [KvResizeExportController::class, 'duplicate'],
                            );
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd api && ./vendor/bin/pest tests/Feature/Studio/KvResizeExportDuplicateTest.php
```

Expected: PASS, all fourteen cases (Task 2's eight plus these six).

- [ ] **Step 6: Check the existing suite still passes**

```bash
cd api && ./vendor/bin/pest tests/Feature/Studio/KvResizeExportControllerTest.php tests/Unit/Support/Studio/CustomResizeSizeTest.php
```

Expected: PASS. A failure here means the `parse()` shape change leaked.

- [ ] **Step 7: Commit**

```bash
cd api && git add app/Http/Controllers/Api/Studio/KvResizeExportController.php routes/api.php tests/Feature/Studio/KvResizeExportDuplicateTest.php
git commit -m "feat(api): POST resize-exports/{export}/duplicate"
```

---

### Task 4: Readable ZIP entry names for custom tiles

**Files:**
- Modify: `api/app/Http/Controllers/Api/Studio/KvResizeExportController.php:446` (the `downloadZip` loop)
- Test: `api/tests/Feature/Studio/KvResizeExportZipTest.php`

**Interfaces:**
- Consumes: `CustomResizeSize::parse()` from Task 1.
- Produces: nothing other tasks depend on.

**Why:** entries are named `{platform_id}-{w}x{h}.png`, already redundant for a custom id (`custom-100x200-100x200.png`) and worse with an ordinal (`custom-100x200-2-100x200.png`). Preset names must not change.

- [ ] **Step 1: Write the failing test**

Append to `api/tests/Feature/Studio/KvResizeExportZipTest.php`. The existing
cases in that file only assert response headers, so there is no entry-name
helper to reuse — this adds one. Note the generation variable in this file is
`$this->gen`, not `$this->generation`. Add `use ZipArchive;` to the top of the
file.

```php
it('names custom entries by size and ordinal, and leaves presets alone', function () {
    Http::fake(['*' => Http::response('FAKEPNGBYTES', 200)]);

    foreach ([
        ['instagram-post', 1080, 1080],
        ['custom-100x200', 100, 200],
        ['custom-100x200-2', 100, 200],
    ] as [$platformId, $w, $h]) {
        KvResizeExport::factory()->create([
            'studio_file_id' => $this->file->id,
            'parent_generation_id' => $this->gen->id,
            'platform_id' => $platformId,
            'width' => $w,
            'height' => $h,
            'image_url' => 'https://s3.test/tile.png',
            'status' => 'done',
            'created_by' => $this->user->id,
        ]);
    }

    $res = getJson("/api/v1/studio/files/{$this->file->id}/resize-exports/download-zip");
    $res->assertOk();

    // The controller returns a BinaryFileResponse with deleteFileAfterSend,
    // so read the archive off the response's own file rather than sending it.
    $zip = new ZipArchive;
    expect($zip->open($res->baseResponse->getFile()->getPathname()))->toBeTrue();

    $names = [];
    for ($i = 0; $i < $zip->numFiles; $i++) {
        $names[] = $zip->getNameIndex($i);
    }
    $zip->close();

    expect($names)->toContain('instagram-post-1080x1080.png');
    expect($names)->toContain('100x200.png');
    expect($names)->toContain('100x200-2.png');
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd api && ./vendor/bin/pest tests/Feature/Studio/KvResizeExportZipTest.php
```

Expected: FAIL — entries come back as `custom-100x200-100x200.png` and `custom-100x200-2-100x200.png`.

- [ ] **Step 3: Implement**

Replace the name construction inside the `foreach ($rows as $row)` loop:

```php
        foreach ($rows as $row) {
            $bytes = Http::get($row->image_url)->body();
            // A custom id already spells its dimensions, so the old
            // "{platform_id}-{w}x{h}" template stuttered
            // (custom-100x200-100x200.png). Presets keep the original name.
            $custom = CustomResizeSize::parse($row->platform_id);
            $name = $custom === null
                ? "{$row->platform_id}-{$row->width}x{$row->height}.png"
                : CustomResizeSize::id(
                    $custom['width'],
                    $custom['height'],
                    $custom['ordinal'],
                ).'.png';
            $zip->addFromString($name, $bytes);
        }
```

Note the custom branch reuses `id()` minus its `custom-` prefix — so write it as:

```php
            $name = $custom === null
                ? "{$row->platform_id}-{$row->width}x{$row->height}.png"
                : substr(CustomResizeSize::id(
                    $custom['width'],
                    $custom['height'],
                    $custom['ordinal'],
                ), strlen('custom-')).'.png';
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd api && ./vendor/bin/pest tests/Feature/Studio/KvResizeExportZipTest.php
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd api && git add app/Http/Controllers/Api/Studio/KvResizeExportController.php tests/Feature/Studio/KvResizeExportZipTest.php
git commit -m "fix(api): stop stuttering custom size names in the resize zip"
```

---

### Task 5: Ordinal in the web id grammar and label

**Files:**
- Modify: `web/src/lib/studio/kv/customSize.ts`
- Modify: `web/src/lib/studio/kv/resizePlatforms.ts:18-27`
- Test: `web/src/lib/studio/kv/customSize.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces: `customSizeId(width: number, height: number, ordinal?: number): CustomPlatformId`; `parseCustomSizeId(id: string): { width: number; height: number; ordinal: number } | null`; `isCustomSizeId(id: string): boolean` unchanged; `platformById()` returns a `Platform` whose `label` carries the ordinal.

**Note:** `parseCustomSizeId` is also consumed by `services/kv/api.ts:847` (which reads `.width`/`.height` only) and by `resizePlatforms.ts`. Adding a key is additive for both.

- [ ] **Step 1: Write the failing tests**

Append to `web/src/lib/studio/kv/customSize.test.ts`, matching the import style already at the top of that file:

```ts
describe("ordinals", () => {
  it("appends an ordinal from the second tile onward", () => {
    expect(customSizeId(100, 200, 2)).toBe("custom-100x200-2");
    expect(customSizeId(100, 200, 10)).toBe("custom-100x200-10");
  });

  it("never emits a second spelling of the first tile", () => {
    expect(customSizeId(100, 200)).toBe("custom-100x200");
    expect(customSizeId(100, 200, 1)).toBe("custom-100x200");
  });

  it("parses an ordinal, defaulting the bare form to 1", () => {
    expect(parseCustomSizeId("custom-100x200")).toEqual({
      width: 100,
      height: 200,
      ordinal: 1,
    });
    expect(parseCustomSizeId("custom-100x200-2")).toEqual({
      width: 100,
      height: 200,
      ordinal: 2,
    });
    expect(parseCustomSizeId("custom-100x200-10")).toEqual({
      width: 100,
      height: 200,
      ordinal: 10,
    });
  });

  it.each([
    "custom-100x200-1",
    "custom-100x200-0",
    "custom-100x200-02",
    "custom-100x200-",
    "custom-100x200-a",
    "custom-100x200-2-3",
  ])("rejects %s", (id) => {
    expect(parseCustomSizeId(id)).toBeNull();
    expect(isCustomSizeId(id)).toBe(false);
  });
});
```

Then update any existing assertion in this file that compares a `parseCustomSizeId` result with `toEqual({ width, height })` — add `ordinal: 1`.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd web && bun test src/lib/studio/kv/customSize.test.ts
```

Expected: FAIL — `customSizeId` takes two arguments, and the parsed object has no `ordinal`.

- [ ] **Step 3: Implement in customSize.ts**

Replace the pattern and the two functions:

```ts
/** Anchored, and it rejects a leading zero. `custom-tall` is a real preset
 *  id, so membership can never be decided by a `custom-` prefix.
 *
 *  The ordinal group is `(?:[2-9]|[1-9]\d+)`, NOT `[2-9]\d*` — the latter
 *  rejects `-10`. Ordinal 1 is rejected on purpose: the first tile of a size
 *  carries no suffix, and accepting `-1` would give it a second spelling. */
const PATTERN = /^custom-([1-9]\d*)x([1-9]\d*)(?:-([2-9]|[1-9]\d+))?$/;

/** `ordinal` numbers the second and later tiles of the same size. 1 and
 *  undefined both mean the first, which carries no suffix. */
export function customSizeId(
  width: number,
  height: number,
  ordinal?: number
): CustomPlatformId {
  const base = `custom-${width}x${height}`;
  const suffixed =
    ordinal === undefined || ordinal <= 1 ? base : `${base}-${ordinal}`;

  return suffixed as CustomPlatformId;
}

export function parseCustomSizeId(
  id: string
): { width: number; height: number; ordinal: number } | null {
  const m = PATTERN.exec(id);
  if (!m) return null;

  const width = Number(m[1]);
  const height = Number(m[2]);
  if (validateCustomSize(width, height) !== null) return null;

  return { width, height, ordinal: m[3] ? Number(m[3]) : 1 };
}
```

Leave `validateCustomSize` and the two bound constants untouched.

- [ ] **Step 4: Carry the ordinal into the label**

In `web/src/lib/studio/kv/resizePlatforms.ts`, change the synthesised label inside `platformById`:

```ts
export function platformById(id: PlatformId): Platform | undefined {
  const custom = parseCustomSizeId(id);
  if (custom) {
    return {
      id,
      // Ordinal 1 stays bare: one tile per size is the common case, and a
      // meaningless "(1)" on it is worse than the asymmetry.
      label:
        custom.ordinal > 1
          ? `${custom.width} × ${custom.height} (${custom.ordinal})`
          : `${custom.width} × ${custom.height}`,
      group: "custom",
      width: custom.width,
      height: custom.height,
    };
  }
  return PLATFORMS.find((p) => p.id === id);
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd web && bun test src/lib/studio/kv/customSize.test.ts
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd web && git add src/lib/studio/kv/customSize.ts src/lib/studio/kv/resizePlatforms.ts src/lib/studio/kv/customSize.test.ts
git commit -m "feat(web): ordinal in the custom resize size id and label"
```

---

### Task 6: Client call, mutation and analytics event

**Files:**
- Modify: `web/src/services/kv/api.ts` (beside `regenerateResizeExport`, around line 869)
- Modify: `web/src/lib/studio/kv/useResizeExports.ts` (beside the `regenerate` mutation, around line 203, and the return object at the end)
- Modify: `web/src/lib/analytics/kv-generator-events.ts` (the "F. Output" section, around line 330)

**Interfaces:**
- Consumes: the `duplicate` endpoint from Task 3.
- Produces: `duplicateResizeExport(fileId: string, exportId: string): Promise<KvResizeExport>`; `trackKvResizeTileDuplicated(p: { export_id: string; source_export_id: string; platform_id: string; ordinal: number }): void`; a `duplicate` mutation on the object `useResizeExports` returns, callable as `duplicate.mutate({ exportId })`.

- [ ] **Step 1: Add the API call**

In `web/src/services/kv/api.ts`, after `regenerateResizeExport`:

```ts
/** Clone a custom-size tile. The server allocates the ordinal, so the caller
 *  passes only the source — there is no id to guess. */
export async function duplicateResizeExport(
  fileId: string,
  exportId: string,
): Promise<KvResizeExport> {
  const { data } = await axiosInstance.post(
    `v1/studio/files/${fileId}/resize-exports/${exportId}/duplicate`,
    {},
  );
  return toResizeExport(unwrap<WireResizeExport>(data));
}
```

- [ ] **Step 2: Add the analytics event**

In `web/src/lib/analytics/kv-generator-events.ts`, in the "F. Output" section:

```ts
export interface KvResizeTileDuplicatedProps {
  export_id: string;
  source_export_id: string;
  platform_id: string;
  /** Which copy this is: 2 for the first duplicate, 3 for the next. Reports
   *  how deep people actually go, which `custom_size_added` cannot see. */
  ordinal: number;
}

export const trackKvResizeTileDuplicated = (p: KvResizeTileDuplicatedProps) =>
  safeCapture("kv_generator.resize_tile_duplicated", p);
```

- [ ] **Step 3: Add the mutation**

In `web/src/lib/studio/kv/useResizeExports.ts`, after the `regenerate` mutation. Import `duplicateResizeExport` from `@/services/kv/api`, `trackKvResizeTileDuplicated` from `@/lib/analytics/kv-generator-events`, and `parseCustomSizeId` from `./customSize` alongside the existing imports:

```ts
  // Unlike regenerate, this ADDS a row rather than replacing one — the cache
  // update appends. The SSE stream will also announce it; appending here just
  // means the tile shows up without waiting for that round trip.
  const duplicate = useMutation({
    mutationFn: (vars: { exportId: string }) =>
      duplicateResizeExport(fileId, vars.exportId),
    onSuccess: (row, vars) => {
      qc.setQueryData<KvResizeExport[]>(
        QUERY_KEY(fileId, parentGenerationId),
        (prev) => {
          const rows = prev ?? [];
          // Guard against the stream having landed the same row first.
          return rows.some((r) => r.id === row.id) ? rows : [...rows, row];
        }
      );
      trackKvResizeTileDuplicated({
        export_id: row.id,
        source_export_id: vars.exportId,
        platform_id: row.platformId,
        ordinal: parseCustomSizeId(row.platformId)?.ordinal ?? 1,
      });
    },
  });
```

Then add `duplicate` to the returned object, after `regenerate`.

- [ ] **Step 4: Type-check the touched files**

```bash
cd web && bunx tsc --noEmit -p tsconfig.json 2>&1 | grep -E "useResizeExports|services/kv/api|kv-generator-events" || echo "no new errors in touched files"
```

Expected: `no new errors in touched files`. This repo has a large pre-existing `tsc` error baseline, so grep for the files you touched rather than reading the whole output.

- [ ] **Step 5: Commit**

```bash
cd web && git add src/services/kv/api.ts src/lib/studio/kv/useResizeExports.ts src/lib/analytics/kv-generator-events.ts
git commit -m "feat(web): duplicateResizeExport call, mutation and event"
```

---

### Task 7: Duplicate button in the canvas tile action cluster

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvResizeResultRow.tsx` (props block around line 25-80; action cluster around line 300-341)
- Modify: `web/src/components/studio/kv-generator/KvResizeCanvas.tsx` (the `KvResizeResultRow` call site, around line 2214-2226)

**Interfaces:**
- Consumes: the `duplicate` mutation from Task 6; `isCustomSizeId` from `@/lib/studio/kv/customSize`.
- Produces: two new `KvResizeResultRow` props — `onDuplicate: () => void` and `canDuplicate: boolean`.

- [ ] **Step 1: Add the props**

In `KvResizeResultRow.tsx`, beside `onArmRegenerate` in the props type:

```ts
  /** Clone this tile under the next ordinal of the same size. Only ever
   *  passed a real handler for a custom-size tile — a preset id has no
   *  ordinal to allocate. */
  onDuplicate: () => void;
  /** False for a preset tile, which hides the button entirely rather than
   *  disabling it: there is no state in which a preset becomes duplicable. */
  canDuplicate: boolean;
```

Destructure both in the component signature alongside `onArmRegenerate`.

- [ ] **Step 2: Render the button**

In the action cluster, immediately before the regenerate button (so order reads Reset · Download · Duplicate · Regenerate), add:

```tsx
              {canDuplicate ? (
                <button
                  type="button"
                  onClick={onDuplicate}
                  aria-label="Duplicate"
                  title="Duplicate this size"
                  className="flex h-6 w-6 items-center justify-center rounded-md text-text-inverse-subtlest transition-colors hover:bg-[rgba(255,255,255,0.05)] hover:text-text-inverse"
                >
                  <Copy size={16} />
                </button>
              ) : null}
```

Add `Copy` to the existing `@phosphor-icons/react` import in this file, beside `ArrowsClockwise` and `ArrowCounterClockwise`.

- [ ] **Step 3: Wire it up in KvResizeCanvas**

`KvResizeCanvas` calls `useResizeExports(fileId, source.id)` itself at line
270 and destructures `regenerate` at line 265. Add `duplicate` to that same
destructuring — no prop threading is needed.

Import `isCustomSizeId` from `@/lib/studio/kv/customSize`, then add this
module-level helper near the top of the file:

```tsx
/** Scroll to a tile that was just created. The row does not exist in the DOM
 *  when the mutation resolves — React has not committed the cache update yet —
 *  so poll a bounded number of frames for the `data-platform-id` node that
 *  `KvGeneratorLayout.handleScrollToPlatform` also targets. Giving up
 *  silently after 10 frames is fine: the tile is still there, just not
 *  scrolled to. */
function scrollToPlatformWhenMounted(platformId: string, attempts = 10): void {
  if (typeof document === "undefined") return;
  requestAnimationFrame(() => {
    const el = document.querySelector<HTMLElement>(
      `[data-platform-id="${platformId}"]`
    );
    if (el) {
      el.scrollIntoView({ behavior: "smooth", block: "center" });
      return;
    }
    if (attempts > 0) scrollToPlatformWhenMounted(platformId, attempts - 1);
  });
}
```

Then at the `KvResizeResultRow` call site, beside
`onArmRegenerate={() => armTile(row.id)}`:

```tsx
                canDuplicate={isCustomSizeId(row.platformId)}
                onDuplicate={() =>
                  duplicate.mutate(
                    { exportId: row.id },
                    {
                      // The copy is initially identical to its source, so
                      // without moving the view there is no visible sign
                      // anything happened.
                      onSuccess: (created) =>
                        scrollToPlatformWhenMounted(created.platformId),
                    }
                  )
                }
```

- [ ] **Step 4: Verify in the running app**

Start the dev server via the Browser pane (never `bun dev` in Bash), open a KV file with a layer-composed generation and a custom-size tile, click Duplicate, and confirm: a second tile appears labelled `(2)`, the canvas scrolls to it, its overlays match the source, and the network tab shows one `201` to `.../duplicate`.

- [ ] **Step 5: Commit**

```bash
cd web && git add src/components/studio/kv-generator/KvResizeResultRow.tsx src/components/studio/kv-generator/KvResizeCanvas.tsx
git commit -m "feat(web): Duplicate button on the resize tile action cluster"
```

---

### Task 8: Duplicate icon on the panel row

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvResizePanel.tsx` (panel props around line 50; the custom-rows `PlatformRow` call around line 197-213; `PlatformRow` props around line 320-335 and its trailing buttons around line 390-400)
- Modify: `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx` (the `KvResizePanel` call site, around line 6797)
- Test: `web/src/components/studio/kv-generator/KvResizePanel.test.tsx`

**Interfaces:**
- Consumes: the `duplicate` mutation from Task 6; `exportsByPlatformId` (already a `KvResizePanel` prop) to resolve a row's export id.
- Produces: a new optional `KvResizePanel` prop `onDuplicate?: (exportId: string) => void`, and a `PlatformRow` prop `onDuplicate?: () => void`.

**Why the panel needs the export id, not the platform id:** the endpoint is addressed by export id. The panel already holds `exportsByPlatformId`, so the custom-row loop resolves `ex.id` and passes a closure.

- [ ] **Step 1: Write the failing test**

Append to `web/src/components/studio/kv-generator/KvResizePanel.test.tsx`, following that file's existing `render` helper and `screen()` pattern:

```ts
  it("offers Duplicate on a done custom row and not on a preset row", () => {
    const onDuplicate = vi.fn();
    const exportsByPlatformId = new Map([
      [
        "custom-100x200",
        { id: "exp-1", platformId: "custom-100x200", status: "done" },
      ],
      [
        "instagram-post",
        { id: "exp-2", platformId: "instagram-post", status: "done" },
      ],
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any);

    render(
      <KvResizePanel
        disabled={false}
        selectedIds={new Set()}
        onToggle={() => {}}
        onResize={() => {}}
        onAddCustomSize={() => {}}
        customSizeEnabled
        exportsByPlatformId={exportsByPlatformId}
        onDuplicate={onDuplicate}
      />
    );

    expect(
      screen().queryByLabelText("Duplicate instagram-post resize")
    ).toBeNull();

    const button = screen().getByLabelText("Duplicate 100 × 200 resize");
    fireEvent.click(button);
    expect(onDuplicate).toHaveBeenCalledWith("exp-1");
  });
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd web && bun test src/components/studio/kv-generator/KvResizePanel.test.tsx
```

Expected: FAIL — no element with that label.

- [ ] **Step 3: Add the panel prop and pass it to custom rows only**

In `KvResizePanel.tsx`, add to the props type:

```ts
  /** Clone a custom-size tile. Addressed by export id because that is what
   *  the endpoint takes. Only wired for custom rows — a preset has no
   *  ordinal to allocate. */
  onDuplicate?: (exportId: string) => void;
```

Destructure it, then inside the custom-rows `.map` pass it down (the loop already computes `ex`):

```tsx
                      onDuplicate={
                        onDuplicate && ex && state === "done"
                          ? () => onDuplicate(ex.id)
                          : undefined
                      }
```

Leave the three preset `Group` renders untouched, so preset rows never receive the prop.

- [ ] **Step 4: Render the icon in PlatformRow**

Add to `PlatformRow`'s props type:

```ts
  onDuplicate?: () => void;
```

Destructure it, and add this button immediately **before** the existing `state === "done" && onRemove` block, so the order reads Duplicate then Remove:

```tsx
        {state === "done" && onDuplicate && (
          <button
            type="button"
            aria-label={`Duplicate ${p.label} resize`}
            onClick={(e) => {
              e.stopPropagation();
              onDuplicate();
            }}
            className="shrink-0 rounded p-1 text-text-inverse-subtlest opacity-0 transition-opacity hover:bg-[rgba(255,255,255,0.06)] hover:text-text-inverse group-hover:opacity-100"
          >
            <Copy size={14} />
          </button>
        )}
```

Add `Copy` to this file's `@phosphor-icons/react` import beside the existing `X`.

- [ ] **Step 5: Wire the call site**

In `KvGeneratorLayout.tsx`, add `duplicate: duplicateResize` to the
`useResizeExports` destructuring at lines 3047-3054 (which already renames
`create`/`regenerate`/`remove`/`cancel` the same way), then at the
`KvResizePanel` call beside `onAddCustomSize={togglePlatform}` (line 6799):

```tsx
        onDuplicate={(exportId) => duplicateResize.mutate({ exportId })}
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
cd web && bun test src/components/studio/kv-generator/KvResizePanel.test.tsx
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
cd web && git add src/components/studio/kv-generator/KvResizePanel.tsx src/components/studio/kv-generator/KvGeneratorLayout.tsx src/components/studio/kv-generator/KvResizePanel.test.tsx
git commit -m "feat(web): Duplicate icon on custom resize panel rows"
```

---

### Task 9: Real labels for custom tiles on the share page

**Files:**
- Modify: `web/src/app/share/[token]/KvShareClient.tsx:26`

**Interfaces:**
- Consumes: `platformById` from `@/lib/studio/kv/resizePlatforms` (Task 5).
- Produces: nothing.

**Why:** the line reads `platformId.startsWith("custom-") ? "Custom" : platformId`. Suffix-safe, but two duplicates would both render `"Custom"` on a share page — the very ambiguity the ordinal exists to remove. It is also the only place outside the shared parser that inspects an id.

- [ ] **Step 1: Read the surrounding expression**

```bash
cd web && sed -n '15,40p' "src/app/share/[token]/KvShareClient.tsx"
```

Confirm what the fallback branch feeds (a label string for a tile heading) before editing.

- [ ] **Step 2: Replace the ad-hoc check with the shared lookup**

```tsx
    (platformById(platformId as PlatformId)?.label ?? platformId)
```

Import `platformById` from `@/lib/studio/kv/resizePlatforms` and `PlatformId` from `@/types/kv/resize`. `platformById` already handles both kinds — it synthesises a custom label with its ordinal and looks presets up in the registry — so this branch stops being custom-specific at all.

- [ ] **Step 3: Verify in the running app**

Open a share link for a KV that has two same-size custom tiles. Expect `100 × 200` and `100 × 200 (2)` rather than two rows reading `Custom`.

- [ ] **Step 4: Type-check**

```bash
cd web && bunx tsc --noEmit -p tsconfig.json 2>&1 | grep "KvShareClient" || echo "no new errors in touched file"
```

Expected: `no new errors in touched file`.

- [ ] **Step 5: Commit**

```bash
cd web && git add "src/app/share/[token]/KvShareClient.tsx"
git commit -m "fix(web): label custom resize tiles on the share page"
```

---

## Final verification

- [ ] **api suites**

```bash
cd api && ./vendor/bin/pest tests/Unit/Support/Studio/CustomResizeSizeTest.php tests/Feature/Studio/KvResizeExportDuplicateTest.php tests/Feature/Studio/KvResizeExportControllerTest.php tests/Feature/Studio/KvResizeExportZipTest.php
```

- [ ] **web suites** (per file, never a directory)

```bash
cd web && bun test src/lib/studio/kv/customSize.test.ts src/components/studio/kv-generator/KvResizePanel.test.tsx src/components/studio/kv-generator/KvCustomSizeRow.test.tsx
```

- [ ] **web build**

```bash
cd web && bun run build
```

- [ ] **End-to-end, in the browser**

On a layer-composed KV with a `100 × 200` custom tile: duplicate from the canvas cluster, duplicate again, delete `(2)`, duplicate once more (expect `(4)` — a freed number is reusable but existing tiles never renumber), move an overlay on one copy and confirm the other does not follow, then download the ZIP and confirm the entries read `100x200.png`, `100x200-3.png`, `100x200-4.png`.

- [ ] **Confirm the untouched guard still holds**

In the Custom size form, type `100` × `200` and click Add. It must still answer "100 × 200 is already added." That form adds *sizes*; duplicating *tiles* is a different verb and lives elsewhere.
