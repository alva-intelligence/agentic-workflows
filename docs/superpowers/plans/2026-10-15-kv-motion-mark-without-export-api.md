# KV Motion — mark without export (api) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a Motion export row carry a `source_hash` (the fingerprint of the design it rendered) so the web can tell a marked size is outdated.

**Architecture:** One nullable column on `kv_motion_exports`, accepted by the existing store endpoint and returned by the existing resource. Nothing else in the api changes — marks, share payloads and approvals already follow the newest export of a (project, size).

**Tech Stack:** Laravel 13, PHP 8.5, PostgreSQL, Pest/PHPUnit.

**Spec:** `docs/superpowers/specs/2026-10-15-kv-motion-mark-without-export-design.md` (§4.4)

## Global Constraints

- Repo `api/` (alva-intelligence/frnd-api-php). Branch `feature/daffa/vc-kv-motion-mark-without-export` cut from latest `develop`.
- Column: `kv_motion_exports.source_hash` — `string(64)`, nullable, no index.
- Validation: `source_hash` → `nullable|string|size:64|regex:/^[0-9a-f]{64}$/` (lower-case hex SHA-256).
- A `null` / absent hash is valid forever (old web builds, legacy rows).
- Run migrations with `TELESCOPE_ENABLED=false` (Telescope OOMs data migrations).
- Commit messages: `<type>(api): …`, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

- **Upper-case hex** (`ABCD…`) — must be rejected (422), not silently stored; the web compares hashes with `===`.
- **Absent key** (old web build) — store must still succeed and the row's `source_hash` must be `null`, not `""`.
- **63/65-char hash** — rejected by `size:64`.
- **Rollback** — `down()` must drop the column cleanly on PostgreSQL.
- **Resource shape** — `source_hash` present (as `null`) on rows that never had one, so the web never sees `undefined`.

---

### Task 1: `source_hash` column, validation and resource

**Files:**
- Create: `api/database/migrations/2026_10_15_100000_add_source_hash_to_kv_motion_exports_table.php`
- Modify: `api/app/Models/KvMotionExport.php` (`$fillable`)
- Modify: `api/app/Http/Requests/Studio/StoreKvMotionExportRequest.php` (`rules()`)
- Modify: `api/app/Http/Resources/Studio/KvMotionExportResource.php` (`toArray()`)
- Test: `api/tests/Unit/Requests/KvMotionProjectRequestsTest.php`
- Test: `api/tests/Feature/Studio/KvMotionProjectControllerTest.php`

**Interfaces:**
- Produces: `POST v1/studio/files/{file}/motion-projects/{project}/exports` accepts optional `source_hash`; every export JSON (store + list) carries `source_hash: string | null`. The web plan's Task 2 relies on exactly this key name.

- [ ] **Step 1: Create the branch**

```bash
cd api
git checkout develop && git pull --ff-only origin develop
git checkout -b feature/daffa/vc-kv-motion-mark-without-export
```

- [ ] **Step 2: Write the failing request test**

Append to `api/tests/Unit/Requests/KvMotionProjectRequestsTest.php`:

```php
it('accepts an optional lower-case sha-256 source_hash on an export', function () {
    $base = [
        'ratio' => '9:16',
        'url' => STORAGE_HOST.'/motion.mp4',
        'width' => 1080,
        'height' => 1920,
        'duration_ms' => 5000,
    ];

    // Absent and null both pass — old web builds send neither.
    expect(validateWith(StoreKvMotionExportRequest::class, $base)->passes())->toBeTrue();
    expect(validateWith(StoreKvMotionExportRequest::class, [...$base, 'source_hash' => null])->passes())->toBeTrue();

    $hash = str_repeat('a1', 32); // 64 lower-case hex chars
    expect(validateWith(StoreKvMotionExportRequest::class, [...$base, 'source_hash' => $hash])->passes())->toBeTrue();
});

it('rejects a malformed source_hash', function () {
    $base = [
        'ratio' => '9:16',
        'url' => STORAGE_HOST.'/motion.mp4',
        'width' => 1080,
        'height' => 1920,
        'duration_ms' => 5000,
    ];

    foreach ([
        str_repeat('A1', 32),      // upper-case: the web compares with ===
        str_repeat('a', 63),       // too short
        str_repeat('a', 65),       // too long
        str_repeat('g', 64),       // not hex
        '',                        // empty string is not "no hash"
    ] as $bad) {
        expect(validateWith(StoreKvMotionExportRequest::class, [...$base, 'source_hash' => $bad])->fails())
            ->toBeTrue("expected '{$bad}' to fail");
    }
});
```

- [ ] **Step 3: Run it to verify it fails**

Pure unit tests — no DB. Move the cached config/routes aside first if present (they hijack the test env; see `lesson_api_feature_tests_need_scratch_postgres`), and restore them after:

```bash
cd api
[ -f bootstrap/cache/config.php ] && mv bootstrap/cache/config.php /tmp/aw-config.php
vendor/bin/pest tests/Unit/Requests/KvMotionProjectRequestsTest.php --compact
```

Expected: the "rejects a malformed source_hash" test FAILS (unknown keys pass validation today); the "accepts" test passes already.

- [ ] **Step 4: Add the rule**

In `StoreKvMotionExportRequest::rules()`, add after `'duration_ms' => …`:

```php
            // Fingerprint of the design this MP4 rendered (spec 2026-10-15
            // §4.1). Lets the editor tell a marked size is outdated. Optional
            // forever: older web builds send none, and a row without one is
            // "unknown", never "outdated". Lower-case hex only — the web
            // compares hashes with ===, so a case variant must not slip in.
            'source_hash' => ['nullable', 'string', 'size:64', 'regex:/^[0-9a-f]{64}$/'],
```

- [ ] **Step 5: Run the unit tests to verify they pass**

```bash
cd api
vendor/bin/pest tests/Unit/Requests/KvMotionProjectRequestsTest.php --compact
```

Expected: all tests in the file PASS.

- [ ] **Step 6: Write the failing feature test**

Add to `KvMotionProjectControllerTest` (same class, after `it_records_and_lists_exports`):

```php
    #[Test]
    public function it_stores_and_returns_the_export_source_hash(): void
    {
        [$user, $file] = $this->motionUser();
        $this->actingAs($user, 'api');

        $projectId = $this->postJson(
            "/api/v1/studio/files/{$file->id}/motion-projects",
            [
                'board_generation_id' => '01J00000000000000000000000',
                'snapshot' => [],
                'timeline' => ['version' => 1, 'duration_ms' => 5000, 'fps' => 30, 'tracks' => []],
                'size_count' => 1,
            ]
        )->json('data.id');

        $base = "/api/v1/studio/files/{$file->id}/motion-projects/{$projectId}/exports";
        $hash = str_repeat('0f', 32);

        $this->postJson($base, [
            'ratio' => '9:16', 'url' => 'https://bucket/m.mp4',
            'width' => 1080, 'height' => 1920, 'duration_ms' => 5000,
            'source_hash' => $hash,
        ])->assertCreated()->assertJsonPath('data.source_hash', $hash);

        // An old web build sends no hash: stored as NULL, returned as null.
        $this->postJson($base, [
            'ratio' => '1:1', 'url' => 'https://bucket/n.mp4',
            'width' => 1080, 'height' => 1080, 'duration_ms' => 5000,
        ])->assertCreated()->assertJsonPath('data.source_hash', null);

        $list = $this->getJson($base)->assertOk();
        $byRatio = collect($list->json('data'))->keyBy('ratio');
        $this->assertSame($hash, $byRatio['9:16']['source_hash']);
        $this->assertArrayHasKey('source_hash', $byRatio['1:1']);
        $this->assertNull($byRatio['1:1']['source_hash']);
    }
```

- [ ] **Step 7: Prepare the test DB and run it to verify it fails**

The test pins `DB_DATABASE=frnd_testing` and SKIPS (does not fail) when Postgres is unreachable — a skip is not a pass. Make sure the DB exists and is migrated first:

```bash
cd api
psql -h localhost -lqt | cut -d'|' -f1 | grep -qw frnd_testing || createdb -h localhost frnd_testing
DB_CONNECTION=pgsql DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php artisan migrate --force
vendor/bin/pest tests/Feature/Studio/KvMotionProjectControllerTest.php --compact
```

Expected: `it_stores_and_returns_the_export_source_hash` FAILS (`data.source_hash` missing / column missing). If it reports SKIPPED, the DB step did not take — fix that before continuing.

If the migrate step fails on an unrelated pre-existing migration, record it in the track notes and run the test after Step 9's migration only (`php artisan migrate --path=database/migrations/2026_10_15_100000_add_source_hash_to_kv_motion_exports_table.php`).

- [ ] **Step 8: Write the migration**

`api/database/migrations/2026_10_15_100000_add_source_hash_to_kv_motion_exports_table.php`:

```php
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * The fingerprint of the design an export rendered (spec 2026-10-15
     * §4.1), so the Motion editor can mark a shared size "Outdated" once the
     * design moves on. Nullable with no backfill: every row written before
     * this has no fingerprint and reads as "unknown", never as outdated.
     */
    public function up(): void
    {
        Schema::table('kv_motion_exports', function (Blueprint $t) {
            $t->string('source_hash', 64)->nullable();
        });
    }

    public function down(): void
    {
        Schema::table('kv_motion_exports', function (Blueprint $t) {
            $t->dropColumn('source_hash');
        });
    }
};
```

- [ ] **Step 9: Model + resource**

In `KvMotionExport::$fillable`, add `'source_hash',` after `'duration_ms',`.

In `KvMotionExportResource::toArray()`, add after `'duration_ms' => $this->duration_ms,`:

```php
            'source_hash' => $this->source_hash,
```

`storeExport` already spreads `$request->validated()` into `create()`, so no controller change.

- [ ] **Step 10: Migrate and run both test files**

```bash
cd api
DB_CONNECTION=pgsql DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php artisan migrate --force
vendor/bin/pest tests/Unit/Requests/KvMotionProjectRequestsTest.php tests/Feature/Studio/KvMotionProjectControllerTest.php --compact
```

Expected: all PASS, none SKIPPED.

- [ ] **Step 11: Check the rollback**

```bash
cd api
DB_CONNECTION=pgsql DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php artisan migrate:rollback --step=1 --force
DB_CONNECTION=pgsql DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php artisan migrate --force
```

Expected: both succeed.

- [ ] **Step 12: Migrate the dev DB, restore caches, lint**

```bash
cd api
TELESCOPE_ENABLED=false php artisan migrate --force
[ -f /tmp/aw-config.php ] && mv /tmp/aw-config.php bootstrap/cache/config.php
php artisan optimize:clear
vendor/bin/pint --dirty
```

- [ ] **Step 13: Commit**

```bash
cd api
git add database/migrations/2026_10_15_100000_add_source_hash_to_kv_motion_exports_table.php \
  app/Models/KvMotionExport.php \
  app/Http/Requests/Studio/StoreKvMotionExportRequest.php \
  app/Http/Resources/Studio/KvMotionExportResource.php \
  tests/Unit/Requests/KvMotionProjectRequestsTest.php \
  tests/Feature/Studio/KvMotionProjectControllerTest.php
git commit -m "feat(api): store the design fingerprint on Motion exports

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
