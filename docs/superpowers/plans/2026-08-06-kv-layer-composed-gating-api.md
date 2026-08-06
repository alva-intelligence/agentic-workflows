# KV Layer-Composed Gating — api Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop a layer-composed KV (PSD import, blank base) from reaching any image model, by refusing image generation and upscale server-side rather than only hiding the buttons.

**Architecture:** A PSD import already records `layer_composed` in generation metadata. This plan marks such imports craft-blocked with an honest reason, then enforces it at three seams: the Craft turn in `ThreadController`, and `getOrCreate` on both upscale services. Chat turns still work — they just stop carrying a blank canvas as vision context.

**Tech Stack:** PHP 8.5, Laravel 13, Pest 4.

Spec: `docs/superpowers/specs/2026-08-06-kv-layer-composed-resize-design.md`, section **"Phase 2 — revised after Phase 1 shipped"**.
Companion plan: `docs/superpowers/plans/2026-08-06-kv-layer-composed-gating-web.md`.
Branch: `feature/daffa/vc-kv-layer-composed-resize` (already checked out; continues the Phase 1 work).

## Global Constraints

- `KvGeneration::isLayerComposed()` already exists — use it, never re-read the metadata key by hand.
- `craft_blocked_reason` is exactly `"extreme_ratio"` or `"layer_composed"`, and is `null` when craft is allowed.
- Chat turns (`mode === 'chat'`) must keep working for a layer-composed KV. Only image-producing turns are refused.
- Never send a layer-composed generation's `image_url` to ai-service. It is a blank placeholder; that is the bug.
- **Known and accepted:** every DB-backed test in this repo fails during migration for a pre-existing reason (`2025_06_01_160001_create_user_chat_histories_table.php:16` runs Postgres-only `DROP SEQUENCE` that SQLite rejects). Do not fix it, do not report BLOCKED over it. Where a task's test needs no database, it must actually be run.
- Run `vendor/bin/pint --dirty --format agent` before every commit.

---

### Task 1: Mark layer-composed imports as craft-blocked

**Files:**
- Modify: `api/app/Services/Studio/KvGenerationService.php:132-141`
- Test: `api/tests/Feature/Studio/KvGenerationImportFromUploadTest.php`

**Interfaces:**
- Consumes: the `layer_composed` payload key (already threaded by Phase 1).
- Produces: `metadata['craft_supported']` (bool) and `metadata['craft_blocked_reason']` (string|null). Task 2 and the web plan both read the reason.

- [ ] **Step 1: Write the failing test**

Append to `KvGenerationImportFromUploadTest.php` (its `beforeEach` already provides `$this->file` and auth):

```php
it('blocks craft for a layer-composed import and says why', function () {
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
    expect(data_get($gen->metadata, 'craft_supported'))->toBeFalse();
    expect(data_get($gen->metadata, 'craft_blocked_reason'))->toBe('layer_composed');
});

it('leaves craft enabled with no reason for an ordinary supported upload', function () {
    $response = $this->postJson(
        "/api/v1/studio/kv-generator/files/{$this->file->id}/generations/import-from-upload",
        [
            'image_url' => 'https://example.com/uploads/ref.png',
            'mime_type' => 'image/png',
            'size' => 123456,
            'original_filename' => 'brand-hero.png',
            'width' => 1080,
            'height' => 1080,
        ],
    )->assertCreated();

    $gen = KvGeneration::findOrFail($response->json('data.id'));
    expect(data_get($gen->metadata, 'craft_supported'))->toBeTrue();
    expect(data_get($gen->metadata, 'craft_blocked_reason'))->toBeNull();
});
```

- [ ] **Step 2: Run them and record the real output**

Run: `cd api && php artisan test tests/Feature/Studio/KvGenerationImportFromUploadTest.php --compact`

Expected: the whole file errors during migration for the known pre-existing reason. Record the output verbatim in your report and move on — do not attempt a fix.

- [ ] **Step 3: Implement**

In `KvGenerationService::persistImportFromUpload`, replace the `$metadata` literal:

```php
            $layerComposed = (bool) ($payload['layer_composed'] ?? false);
            // A layer-composed base is a blank placeholder — the artwork is
            // in overlays — so there is nothing for the image model to work
            // from. Blocked for the same reason an extreme ratio is, but the
            // user needs to be told the real one.
            $ratioSupported = KvAspectRatio::isSupported($width, $height);
            $craftBlockedReason = match (true) {
                $layerComposed => 'layer_composed',
                ! $ratioSupported => 'extreme_ratio',
                default => null,
            };

            $metadata = [
                'imported_from_upload' => true,
                'mime_type' => $payload['mime_type'],
                'size' => $payload['size'],
                'original_filename' => $payload['original_filename'] ?? null,
                'width' => $width,
                'height' => $height,
                'craft_supported' => $ratioSupported && ! $layerComposed,
                'craft_blocked_reason' => $craftBlockedReason,
                'layer_composed' => $layerComposed,
            ];
```

`layer_composed` wins over `extreme_ratio` when both apply: a PSD import's blank base is the more actionable explanation, and its ratio is usually fine anyway.

- [ ] **Step 4: Commit**

```bash
cd api && vendor/bin/pint --dirty --format agent
git add app/Services/Studio/KvGenerationService.php tests/Feature/Studio/KvGenerationImportFromUploadTest.php
git commit -m "feat(api): block craft for layer-composed imports with a reason"
```

---

### Task 2: Refuse image-producing Craft turns, keep chat turns working

**Files:**
- Modify: `api/app/Models/KvGeneration.php` (add the policy method)
- Modify: `api/app/Http/Controllers/Api/Chat/ThreadController.php:688-700` and `:745-758`
- Test: `api/tests/Unit/Models/KvGenerationLayerComposedTest.php`

**Interfaces:**
- Consumes: `KvGeneration::isLayerComposed()`.
- Produces: `KvGeneration::blocksImageGeneration(): bool`. Task 3 calls it too.

The decision goes on the model, not inline in the controller, so it is unit-testable without a database — the only kind of test that actually runs in this repo.

The seam is `ThreadController.php:691`:

```php
            if ($canvasMode === 'craft' && ! $hasBoundingBoxes && $mode !== 'chat') {
                $mode = 'image';
```

`mode` is one of `image` (polish), `edit` (region inpaint), `chat` (discuss, no regeneration — see the comment block at `:676-687`). Only the first two produce an image.

- [ ] **Step 1: Write the failing test**

Append to `tests/Unit/Models/KvGenerationLayerComposedTest.php` (no `RefreshDatabase` — unsaved instances only, so it runs):

```php
it('blocks image generation when layer composed', function () {
    $gen = new KvGeneration(['metadata' => ['layer_composed' => true]]);

    expect($gen->blocksImageGeneration())->toBeTrue();
});

it('allows image generation for an ordinary generation', function () {
    expect((new KvGeneration(['metadata' => []]))->blocksImageGeneration())->toBeFalse();
    expect((new KvGeneration(['metadata' => null]))->blocksImageGeneration())->toBeFalse();
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd api && php artisan test tests/Unit/Models/KvGenerationLayerComposedTest.php --compact`

Expected: FAIL with `Call to undefined method …::blocksImageGeneration()`. The four pre-existing cases in the file still pass — this file has no database dependency.

- [ ] **Step 3: Add the policy method**

In `app/Models/KvGeneration.php`, directly below `isLayerComposed()`:

```php
/**
 * Whether an image model must not be run against this generation. Its
 * `image_url` is a blank placeholder, so any img-to-img turn would edit
 * an empty canvas and return an empty result that looks successful.
 */
public function blocksImageGeneration(): bool
{
    return $this->isLayerComposed();
}
```

It delegates today, but the two concepts are distinct — a future reason to block generation need not be about layers — and every caller reads better for it.

- [ ] **Step 4: Run it to verify it passes**

Run: `cd api && php artisan test tests/Unit/Models/KvGenerationLayerComposedTest.php --compact`

Expected: 6 passed.

- [ ] **Step 5: Refuse image and edit turns in the controller**

In `ThreadController`, immediately after `$baseGen` is resolved and the not-found guard runs (around `:742-744`, before `$baseGeneration` is assembled at `:745`), add:

```php
                if ($baseGen && $baseGen->blocksImageGeneration() && $mode !== 'chat') {
                    return $this->streamErrorResponse(
                        'This KV is built from layers, so it can’t be regenerated by AI. '
                        .'You can still chat about it, or flatten it first.',
                    );
                }
```

`$mode !== 'chat'` is what keeps discussion working: only `image` and `edit` are refused. `streamErrorResponse` is the existing failure channel used a few lines above for a missing base generation, so the client already knows how to render it.

- [ ] **Step 6: Stop sending the blank canvas on chat turns**

Still in `ThreadController`, the `$baseGeneration` array at `:745-758` carries `'image_url' => $baseGen->source_image_url ?: $baseGen->image_url`. For a layer-composed base that is a blank PNG, and on a chat turn it becomes the model's vision context — so the model would confidently describe an empty image. Send no image instead:

```php
                if ($baseGen) {
                    $baseGeneration = [
                        'id' => $baseGen->id,
                        // A layer-composed base has no real pixels to show the
                        // model; a blank placeholder is worse than nothing,
                        // because the model describes the blank.
                        'image_url' => $baseGen->blocksImageGeneration()
                            ? null
                            : ($baseGen->source_image_url ?: $baseGen->image_url),
                        'mode' => $baseGen->mode?->value ?? 'sketch',
                    ];
                }
```

Check the ai-service contract before finalising: `ai-service/app/agents/kv_generator/request_schema.py` defines `BaseGenerationRef`. If its `image_url` is not `Optional`, report that in your report rather than widening the schema — the api side must not send a field the service will reject, and changing ai-service is outside this plan.

- [ ] **Step 7: Commit**

```bash
cd api && vendor/bin/pint --dirty --format agent
git add app/Models/KvGeneration.php app/Http/Controllers/Api/Chat/ThreadController.php tests/Unit/Models/KvGenerationLayerComposedTest.php
git commit -m "feat(api): refuse AI regeneration for layer-composed KVs, keep chat"
```

---

### Task 3: Refuse upscale for layer-composed sources

**Files:**
- Modify: `api/app/Services/Studio/KvGenerationUpscaleService.php:26` (`getOrCreate`)
- Modify: `api/app/Services/Studio/KvResizeExportUpscaleService.php:26` (`getOrCreate`)
- Test: `api/tests/Unit/Services/Studio/KvUpscaleGatingTest.php` (create)

**Interfaces:**
- Consumes: `KvGeneration::blocksImageGeneration()` from Task 2.
- Produces: nothing new.

Upscaling a layer-composed KV enlarges a blank canvas and stores a blank file that reports success — the same silent failure this whole change exists to remove. The tile variant reads `$row->tile->image_url`, which Phase 1 made null, so it would ship a null source to ai-service.

- [ ] **Step 1: Read both services first**

Open both `getOrCreate` methods in full before writing anything. They differ: one starts from a `KvGeneration`, the other from a `KvResizeExport` whose parent generation carries the flag. Note the exception type each already throws for invalid input, and match it — do not introduce a new exception class.

- [ ] **Step 2: Write the failing test**

Create `api/tests/Unit/Services/Studio/KvUpscaleGatingTest.php`. Build unsaved models so the test needs no database:

```php
<?php

use App\Models\KvGeneration;

it('reports a layer-composed generation as ineligible for upscale', function () {
    $gen = new KvGeneration(['metadata' => ['layer_composed' => true]]);

    expect($gen->blocksImageGeneration())->toBeTrue();
});

it('reports an ordinary generation as eligible for upscale', function () {
    $gen = new KvGeneration(['metadata' => ['imported_from_upload' => true]]);

    expect($gen->blocksImageGeneration())->toBeFalse();
});
```

This asserts the predicate the services will branch on. A test that exercises `getOrCreate` itself needs factories and therefore a database, which cannot run here — if you can write one that genuinely runs without a DB, do, and say so in your report.

- [ ] **Step 3: Run it**

Run: `cd api && php artisan test tests/Unit/Services/Studio/KvUpscaleGatingTest.php --compact`

Expected: 2 passed (the method landed in Task 2).

- [ ] **Step 4: Guard both services**

In each `getOrCreate`, before any row is created or any job dispatched, refuse when the source generation blocks image generation. Use the same exception type the method already uses for bad input, with this message:

```
This KV is built from layers, so there is no image to upscale.
```

For `KvResizeExportUpscaleService`, the flag lives on the tile's parent generation, not the tile — reach it via the export row's `parentGeneration` relation and use the null-safe operator, so a row whose parent was deleted falls through to the existing behaviour instead of fataling.

- [ ] **Step 5: Verify by reading, then commit**

Re-read both methods and confirm the guard sits before every side effect (row creation, job dispatch, credit check). State that reasoning explicitly in your report, since no test covers it here.

```bash
cd api && vendor/bin/pint --dirty --format agent
git add app/Services/Studio/KvGenerationUpscaleService.php app/Services/Studio/KvResizeExportUpscaleService.php tests/Unit/Services/Studio/KvUpscaleGatingTest.php
git commit -m "feat(api): refuse upscale for layer-composed KVs"
```

---

## Verification after all tasks

- [ ] Run the tests that genuinely run here:

```bash
cd api && php artisan test tests/Unit/Models/KvGenerationLayerComposedTest.php tests/Unit/Services/Studio/KvUpscaleGatingTest.php --compact
```

- [ ] Confirm no blank image can still reach ai-service:

```bash
cd api && grep -rn "source_image_url\|image_url" app/Jobs/Studio/ app/Http/Controllers/Api/Chat/ThreadController.php | grep -v "^.*://"
```

Every hit must either be guarded by `blocksImageGeneration()` or belong to a path this plan deliberately left alone (the legacy `GenerateKvMotionJob`, which web no longer calls). List what you find and which bucket it falls in.

## Notes for the reviewer

- No migration: `metadata` is an existing JSON column cast to `array`.
- Generations created before this change have no `craft_blocked_reason`; web must treat a missing reason as "not blocked", never as a blocked-with-unknown-reason.
- The legacy motion route (`files/{file}/motions` → `GenerateKvMotionJob`) is deliberately NOT gated. Web calls `motion-projects` instead, and Motion was revamped to render overlays in the browser.
