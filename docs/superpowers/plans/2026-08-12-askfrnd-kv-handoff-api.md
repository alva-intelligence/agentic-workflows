# askFRND → KV Studio handoff — api Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `import-from-upload` accept an image whose byte length the browser cannot read, by making `size` optional.

**Architecture:** One validation rule changes. No controller, service, migration, or route change — `$request->validated('size')` already returns `null` for an absent `sometimes` key, and `KvGenerationService::persistImportFromUpload` only writes `size` into the generation's `metadata` JSON, where `null` is valid.

**Tech Stack:** Laravel 13, PHP 8.5, Pest.

**Spec:** `docs/superpowers/specs/2026-08-12-askfrnd-kv-handoff-design.md`

## Global Constraints

- Branch: `feature/daffa/vc-askfrnd-kv-handoff`, cut from `develop`.
- `width` and `height` stay `required`. They feed `KvAspectRatio::isSupported`, which sets `craft_supported` and the extreme-ratio block — making them optional would silently mis-gate Craft.
- `size`'s `min:1` and `max:20971520` bounds are preserved for the case where a value IS sent (the existing upload path always sends one).
- **Do NOT touch `KvGeneratorFileController::importGenerationFromUpload` or `KvGenerationService::persistImportFromUpload`.** They already handle a null size. Changing them is out of scope and would widen the diff for no behavioural gain.
- **api Feature tests cannot run in this workspace.** `phpunit.xml:26-27` forces `sqlite`/`:memory:` (this is the guard that keeps `RefreshDatabase` off the dev Postgres — verified present, do not remove it), but the migration set is Postgres-only and dies on `database/migrations/2025_06_01_160001_create_user_chat_histories_table.php`. Verification for this plan is therefore a **Unit** test on the FormRequest rules, following the existing precedent in `tests/Unit/Requests/TextOverlayStylingValidationTest.php`.
- If `php artisan test` fails with *"Refusing to run: the 'pgsql' connection points at …"*, that is `tests/TestCase.php:39-47` catching a stale `bootstrap/cache/config.php`. Run `php artisan config:clear` first.

## File Structure

| File | Responsibility |
|---|---|
| `app/Http/Requests/Studio/ImportKvGenerationFromUploadRequest.php` (modify) | the one rule change |
| `tests/Unit/Requests/ImportKvGenerationSizeOptionalTest.php` (create) | proves size may be omitted and that width/height may not |

---

### Task 1: Make `size` optional on import-from-upload

**Files:**
- Create: `api/tests/Unit/Requests/ImportKvGenerationSizeOptionalTest.php`
- Modify: `api/app/Http/Requests/Studio/ImportKvGenerationFromUploadRequest.php:26`

**Interfaces:**
- Consumes: nothing from earlier tasks (first and only task).
- Produces: `POST v1/studio/kv-generator/files/{id}/generations/import-from-upload` accepts a body without `size`. The web plan's `importKvGenerationFromUpload` call relies on this.

- [ ] **Step 1: Write the failing test**

Create `api/tests/Unit/Requests/ImportKvGenerationSizeOptionalTest.php`:

```php
<?php

use App\Http\Requests\Studio\ImportKvGenerationFromUploadRequest;
use Illuminate\Support\Facades\Validator;
use Tests\TestCase;

uses(TestCase::class);

/**
 * The askFRND → KV Studio handoff imports an image the browser only has a URL
 * for. The S3 bucket serving those assets sends no CORS headers, so `fetch()`
 * is blocked and the client cannot read Content-Length — it can only read
 * natural width/height off a plain `<img>` load. `size` must therefore be
 * optional. It is safe to relax because KvGenerationService only stores it in
 * the generation's `metadata` JSON; no logic reads it.
 */
function importPayload(array $overrides = []): array
{
    return array_merge([
        'image_url' => 'https://example.com/uploads/serum-shot.png',
        'mime_type' => 'image/png',
        'size' => 123456,
        'width' => 1024,
        'height' => 1024,
    ], $overrides);
}

test('size may be omitted entirely', function () {
    $payload = importPayload();
    unset($payload['size']);

    $v = Validator::make($payload, (new ImportKvGenerationFromUploadRequest)->rules());

    expect($v->fails())->toBeFalse();
    expect($v->validated())->not->toHaveKey('size');
});

test('size may be explicitly null', function () {
    $v = Validator::make(
        importPayload(['size' => null]),
        (new ImportKvGenerationFromUploadRequest)->rules(),
    );

    expect($v->fails())->toBeFalse();
});

test('a supplied size still has to be a sane positive integer', function () {
    $v = Validator::make(
        importPayload(['size' => 0]),
        (new ImportKvGenerationFromUploadRequest)->rules(),
    );

    expect($v->fails())->toBeTrue();
    expect($v->errors()->has('size'))->toBeTrue();
});

test('width and height remain required — they gate craft_supported', function () {
    $payload = importPayload();
    unset($payload['width'], $payload['height']);

    $v = Validator::make($payload, (new ImportKvGenerationFromUploadRequest)->rules());

    expect($v->fails())->toBeTrue();
    expect($v->errors()->has('width'))->toBeTrue();
    expect($v->errors()->has('height'))->toBeTrue();
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd api && php artisan config:clear && php artisan test tests/Unit/Requests/ImportKvGenerationSizeOptionalTest.php
```

Expected: the first two tests FAIL — `size` is currently `required`, so omitting it produces a validation error and `$v->fails()` is `true`. The third and fourth tests should already PASS.

- [ ] **Step 3: Change the rule**

In `api/app/Http/Requests/Studio/ImportKvGenerationFromUploadRequest.php`, replace the `size` rule:

```php
            // Optional: the askFRND → KV Studio handoff imports an image the
            // browser only has a URL for, and the S3 bucket sends no CORS
            // headers, so the client cannot read Content-Length. Only stored
            // in the generation's metadata — no logic reads it, unlike
            // width/height which gate craft_supported.
            'size' => ['sometimes', 'nullable', 'integer', 'min:1', 'max:20971520'], // 20 MB cap, matches the chat-attachments client guard
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd api && php artisan test tests/Unit/Requests/ImportKvGenerationSizeOptionalTest.php
```

Expected: 4 passed.

- [ ] **Step 5: Confirm nothing else regressed on the same request class**

```bash
cd api && php artisan test tests/Unit/Requests/
```

Expected: all pass. (Do not attempt `tests/Feature/Studio/` — see Global Constraints.)

- [ ] **Step 6: Commit**

```bash
cd api && git add app/Http/Requests/Studio/ImportKvGenerationFromUploadRequest.php tests/Unit/Requests/ImportKvGenerationSizeOptionalTest.php
git commit -m "feat(api): allow import-from-upload without a size

The askFRND → KV Studio handoff imports a generated image the browser only
has a URL for. The S3 bucket sends no CORS headers, so the client can read
natural dimensions off a plain <img> load but cannot read Content-Length.

size is metadata-only in KvGenerationService::persistImportFromUpload, so
relaxing it changes no behaviour. width/height stay required — they gate
craft_supported via KvAspectRatio::isSupported."
```

---

## Deployment note (not a code task)

`import-from-upload` rejects any `image_url` whose host is not `S3_OVERLAY_HOST_PATTERN` or a subdomain of it (`app/Support/Studio/TrustedAssetHost.php`). Locally that variable is unset, which `TrustedAssetHost::matches` treats as permissive — so **local testing cannot detect a staging/prod mismatch**.

Before release, confirm with arhen that the deployed `S3_OVERLAY_HOST_PATTERN` covers the host ai-service uploads generated images to (`app/services/aws.py` → `settings.S3_BUCKET_NAME`; api's own `AWS_BUCKET=frnd`, so they are very likely the same bucket). A mismatch surfaces as a 422 on import, which the web card's error state handles without stranding the user — but the feature would be dead in that environment.
