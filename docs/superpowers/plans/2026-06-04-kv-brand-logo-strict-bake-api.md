# KV Brand Logo Strict Bake — api Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Supply the brand logo bytes (base64) + the persisted placement spec to ai-service on image-producing KV turns, and persist the resolved spec back to `studio_files.brand_logo_stamp` by intercepting the ai-service stream.

**Architecture:** Two outbound additions to the `KvStreamRequest` payload (`brand_logo`, `brand_logo_stamp`) plus one inbound stream-event handler (`logo_stamp_state`) that writes the column — mirroring the existing `generation_ready` mid-stream DB write. Web is untouched (the logo is baked into the image the browser already receives).

**Tech Stack:** Laravel 13, PHP 8.5, PostgreSQL (jsonb), Pest 3, `Storage::disk('s3')`, `finfo`.

**Branch:** `feature/daffa/vc-studio-projects-kv-generator`

**Spec:** `docs/superpowers/specs/2026-06-04-kv-brand-logo-strict-bake-design.md`

**Depends on:** the ai-service plan defines the `brand_logo {data_base64, mime_type}` and `brand_logo_stamp {anchor, scale}` shapes + the `logo_stamp_state` event. This plan must match those shapes exactly.

---

## File Structure

- `api/database/migrations/2026_06_04_000000_add_brand_logo_stamp_to_studio_files_table.php` — **new**: nullable jsonb column.
- `api/app/Models/StudioFile.php` — **modify**: `$fillable` + `$casts`.
- `api/app/Services/ChatService.php` — **modify**: `buildBrandLogoAsset()` helper; add `brand_logo` + `brand_logo_stamp` to the payload; add inbound `case 'logo_stamp_state'`.
- `api/tests/Feature/Chat/BrandLogoStampTest.php` — **new**: outbound payload + inbound persistence tests.

---

## Task 0: DB-safety pre-flight (do this before ANY Pest run)

**Rationale:** A cached `bootstrap/cache/config.php` bakes `DB_CONNECTION=pgsql` and overrides phpunit.xml's SQLite override, so `RefreshDatabase` wipes the real dev Postgres DB. This bit us on 2026-04-25 (`lesson_test_db_isolation`).

- [ ] **Step 1: Confirm no cached config**

Run: `ls /Users/alva.e202511001/Desktop/work/frndos-agentic/api/bootstrap/cache/`
Expected: only `packages.php` and `services.php` — NO `config.php`. If present: `cd api && php artisan config:clear` before continuing.

- [ ] **Step 2: Confirm phpunit.xml forces SQLite**

Run: `grep -nE "DB_CONNECTION|DB_DATABASE" /Users/alva.e202511001/Desktop/work/frndos-agentic/api/phpunit.xml`
Expected: an active (un-commented) `DB_CONNECTION=sqlite` + `DB_DATABASE=:memory:` (or test sqlite). If commented out, STOP and report — do not run Pest until DB isolation is confirmed.

---

## Task 1: Migration + model column

**Files:**
- Create: `api/database/migrations/2026_06_04_000000_add_brand_logo_stamp_to_studio_files_table.php`
- Modify: `api/app/Models/StudioFile.php:19-43`

- [ ] **Step 1: Create the migration**

Create `api/database/migrations/2026_06_04_000000_add_brand_logo_stamp_to_studio_files_table.php` (mirror the `overlays` migration `2026_04_25_172545_add_overlays_to_studio_files_table.php`):

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
            // Sticky brand-logo placement for strict server-side bake.
            // Shape: {"anchor": "<9-grid>", "scale": "small|medium|large"}
            // NULL = no logo baked. See 2026-06-04 strict-bake spec.
            $table->jsonb('brand_logo_stamp')->nullable()->after('overlays');
        });
    }

    public function down(): void
    {
        Schema::table('studio_files', function (Blueprint $table) {
            $table->dropColumn('brand_logo_stamp');
        });
    }
};
```

- [ ] **Step 2: Add to model `$fillable` + `$casts`**

In `api/app/Models/StudioFile.php`, add `'brand_logo_stamp'` to `$fillable` (after `'overlays'`, line 32) and to `casts()` (after `'overlays' => 'array'`, line 41):

```php
        'overlays',
        'brand_logo_stamp',
```

```php
            'overlays' => 'array',
            'brand_logo_stamp' => 'array',
```

- [ ] **Step 3: Run the migration**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && php artisan migrate`
Expected: the new migration runs, `studio_files.brand_logo_stamp` created.

- [ ] **Step 4: Verify round-trip via tinker**

Run:
```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && php artisan tinker --execute="
\$f = App\Models\StudioFile::query()->first();
if (\$f) { \$f->brand_logo_stamp = ['anchor'=>'bottom-right','scale'=>'medium']; \$f->save();
echo gettype(\$f->fresh()->brand_logo_stamp).PHP_EOL; var_export(\$f->fresh()->brand_logo_stamp); }
else { echo 'no studio file rows'; }"
```
Expected: prints `array` and the array contents (cast works). Then reset it: re-run with `\$f->brand_logo_stamp = null; \$f->save();` so dev data is untouched.

- [ ] **Step 5: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
git add database/migrations/2026_06_04_000000_add_brand_logo_stamp_to_studio_files_table.php app/Models/StudioFile.php
git commit -m "feat(api): add brand_logo_stamp jsonb column to studio_files"
```

---

## Task 2: Supply `brand_logo` + `brand_logo_stamp` in the KV payload

**Files:**
- Modify: `api/app/Services/ChatService.php` (brand block ~467-495, payload ~510-554, helpers ~2501)
- Test: `api/tests/Feature/Chat/BrandLogoStampTest.php` (Task 4)

- [ ] **Step 1: Add the `buildBrandLogoAsset` helper**

In `api/app/Services/ChatService.php`, immediately after `buildBrandVisuals()` (ends line 2513), add:

```php
    /**
     * Read the brand's logo bytes from S3 and return them base64-encoded
     * for the ai-service strict-bake compositor. Returns null when the
     * brand has no logo, the object is missing, or the MIME is not an
     * allowed raster — the caller null-coalesces so a bad logo never
     * breaks the KV stream.
     *
     * @return array{data_base64: string, mime_type: string}|null
     */
    private static function buildBrandLogoAsset(Brand $brand): ?array
    {
        $rawLogo = $brand->getRawOriginal('logo');
        if (! is_string($rawLogo) || $rawLogo === '') {
            return null;
        }

        try {
            $bytes = Storage::disk('s3')->get($rawLogo);
        } catch (\Throwable $e) {
            Log::warning('KV brand logo fetch failed for strict bake', [
                'brand_id' => $brand->id,
                'path' => $rawLogo,
                'error' => $e->getMessage(),
            ]);

            return null;
        }

        if (! is_string($bytes) || $bytes === '') {
            return null;
        }

        $mime = (new \finfo(FILEINFO_MIME_TYPE))->buffer($bytes) ?: '';
        if (! in_array($mime, ['image/png', 'image/jpeg', 'image/webp', 'image/gif'], true)) {
            Log::warning('KV brand logo MIME not allowed for strict bake', [
                'brand_id' => $brand->id,
                'mime' => $mime,
            ]);

            return null;
        }

        return [
            'data_base64' => base64_encode($bytes),
            'mime_type' => $mime,
        ];
    }
```

(`Log` and `Storage` are already imported — `buildBrandVisuals` uses `Storage`.)

- [ ] **Step 2: Build the logo asset inside the brand block**

In `ChatService.php`, the brand block is at lines 467-495. Add `$brandLogoAsset = null;` just BEFORE the `if (($launchContext['use_brand_knowledge'] ...))` line (line 467), then inside `if ($brand) { ... }` (after the `array_merge` assignment, before its closing `}` at line 494) add:

```php
                        // Strict logo bake: ship the logo bytes only on
                        // image-producing turns (chat turns render nothing,
                        // so the payload bloat would be wasted).
                        if ($mode !== 'chat') {
                            $brandLogoAsset = self::buildBrandLogoAsset($brand);
                        }
```

- [ ] **Step 3: Resolve the persisted stamp before the payload**

In `ChatService.php`, just BEFORE `$payload = [` (line 510), add:

```php
                $brandLogoStamp = null;
                $stampStudioFile = StudioFile::find($launchContext['studio_file_id'] ?? null);
                if ($stampStudioFile) {
                    $brandLogoStamp = $stampStudioFile->brand_logo_stamp ?: null;
                }
```

- [ ] **Step 4: Add both fields to the payload**

In the `$payload` array (after `'aspect_ratio' => $aspectRatio,` at line 553), add:

```php
                    // Strict brand-logo bake: the logo bytes (image turns
                    // only) and the sticky placement spec persisted on the
                    // studio file. ai-service composites the logo onto the
                    // finished render — it never goes through the image model.
                    'brand_logo' => $brandLogoAsset,
                    'brand_logo_stamp' => $brandLogoStamp,
```

- [ ] **Step 5: PHP syntax check**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && php -l app/Services/ChatService.php`
Expected: `No syntax errors detected`.

- [ ] **Step 6: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
git add app/Services/ChatService.php
git commit -m "feat(api): supply brand_logo bytes + sticky stamp in KV payload"
```

---

## Task 3: Persist the resolved stamp from the ai-service stream

**Files:**
- Modify: `api/app/Services/ChatService.php` (event switch ~872, before `case 'done':`)

- [ ] **Step 1: Add the `logo_stamp_state` case**

In `ChatService.php`, inside the `switch ($parsedData['event'] ?? '')` block, add a new case immediately before `case 'done':` (line 872):

```php
                        case 'logo_stamp_state':
                            // Strict bake: ai-service resolved where the
                            // brand logo was baked this turn. Persist it on
                            // the studio file so the placement sticks across
                            // regenerations (null = removed / none). Mirrors
                            // the generation_ready mid-stream DB write. No
                            // browser relay — the logo is already in the
                            // image the browser receives.
                            $stampFile = StudioFile::find(
                                $thread->launch_context['studio_file_id'] ?? null
                            );
                            if ($stampFile) {
                                $stamp = $parsedData['stamp'] ?? null;
                                $stampFile->brand_logo_stamp = is_array($stamp) ? $stamp : null;
                                $stampFile->save();
                            }
                            break;
```

- [ ] **Step 2: PHP syntax check**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && php -l app/Services/ChatService.php`
Expected: `No syntax errors detected`.

- [ ] **Step 3: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
git add app/Services/ChatService.php
git commit -m "feat(api): persist brand_logo_stamp from ai-service logo_stamp_state event"
```

---

## Task 4: Feature tests

**Files:**
- Create: `api/tests/Feature/Chat/BrandLogoStampTest.php`

**Rationale:** The api side is a JSON builder + a stream-event handler. Two cheap correctness checks: (a) given a brand with a logo + an image turn, the outbound ai-service payload carries `brand_logo` + `brand_logo_stamp`; (b) a `logo_stamp_state` line in the ai-service response writes the studio file column.

- [ ] **Step 1: Read the existing brand-asset test for the harness**

Read `api/tests/Feature/Chat/BrandAssetFeedingTest.php` — copy its `beforeEach` (Tool factory `kv-generator`, SubscriptionPlan, credit grant, role/permission, `Storage::fake('s3')`, `Http::fake()`), the exact KV-stream route + request body shape, and the `Http::recorded()` / `Http::assertSent` pattern. Do NOT invent request fields — the `StreamChatRequest` FormRequest rejects unknown keys.

- [ ] **Step 2: Write the outbound test**

Create `api/tests/Feature/Chat/BrandLogoStampTest.php`. Mirror `BrandAssetFeedingTest.php`'s setup exactly; the NEW parts are (a) seed PNG bytes at the brand's S3 logo path, (b) make it an `image` turn, (c) assert `brand_logo` + `brand_logo_stamp` in the recorded outbound body:

```php
<?php

use App\Models\Brand;
use App\Models\StudioFile;
use App\Models\User;
use App\Models\Workspace;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Storage;

// 1x1 transparent PNG — smallest legal PNG so the payload stays small.
function seedStrictLogo(string $path): string
{
    $bytes = base64_decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4//8/AwAI/AL+JT04vQAAAABJRU5ErkJggg=='
    );
    Storage::disk('s3')->put($path, $bytes);

    return $bytes;
}

beforeEach(function () {
    // (Copy the FULL beforeEach from BrandAssetFeedingTest.php here —
    //  Tool factory slug 'kv-generator', SubscriptionPlan, credit grant,
    //  role + chat permission. Then:)
    Storage::fake('s3');
    Http::fake();
});

it('sends brand_logo bytes + persisted stamp on an image turn', function () {
    // (Use the same setup helper / inline setup as BrandAssetFeedingTest.)
    $user = User::factory()->create();
    $workspace = Workspace::factory()->create();
    $user->workspaces()->attach($workspace);

    $logoBytes = seedStrictLogo('logos/strict-test.png');
    $brand = Brand::factory()->create([
        'workspace_id' => $workspace->id,
        'user_id' => $user->id,
        'name' => 'TestCo',
        'logo' => 'logos/strict-test.png',
    ]);

    // A studio file that already has a sticky stamp persisted.
    // (Build it the same way BrandAssetFeedingTest builds its thread +
    //  studio file; set launch_context.use_brand_knowledge=true and
    //  brand_id=$brand->id, and brand_logo_stamp below.)
    $file = StudioFile::factory()->create([
        'workspace_id' => $workspace->id,
        'brand_id' => $brand->id,
        'brand_logo_stamp' => ['anchor' => 'bottom-right', 'scale' => 'medium'],
    ]);

    // Drive the KV stream as an IMAGE turn (mode=image), reusing the exact
    // request body shape from BrandAssetFeedingTest, with the thread whose
    // launch_context.studio_file_id = $file->id.
    // ... actingAs($user)->postJson(route(...), [... 'mode' => 'image' ...])
    //        ->streamedContent();

    Http::assertSent(function ($request) {
        if (! str_contains($request->url(), '/ai/kv-generator/stream')) {
            return false;
        }
        $body = $request->data();
        $logo = $body['brand_logo'] ?? null;
        $stamp = $body['brand_logo_stamp'] ?? null;

        return is_array($logo)
            && $logo['mime_type'] === 'image/png'
            && ! empty($logo['data_base64'])
            && is_array($stamp)
            && $stamp['anchor'] === 'bottom-right'
            && $stamp['scale'] === 'medium';
    });
});

it('sends null brand_logo on a chat turn', function () {
    // Same setup, but mode=chat. Assert brand_logo is null in the body.
    // ... (mirror the test above with 'mode' => 'chat')
    Http::assertSent(function ($request) {
        if (! str_contains($request->url(), '/ai/kv-generator/stream')) {
            return false;
        }

        return ($request->data()['brand_logo'] ?? 'MISSING') === null;
    });
});
```

> **Note for the engineer:** The `postJson(...)` bodies + the thread/studio-file setup are marked with comments — copy them verbatim from `BrandAssetFeedingTest.php` (it already drives a KV stream with brand knowledge). If `StudioFile::factory()` does not exist, create the row the same way `BrandAssetFeedingTest` does (it must create a studio file to set `studio_file_id` in `launch_context`). Substitute only `mode`, `brand_logo_stamp`, and the seeded logo path.

- [ ] **Step 3: Write the inbound persistence test**

Append to `BrandLogoStampTest.php`. This fakes the ai-service NDJSON response to include a `logo_stamp_state` line and asserts the column is written:

```php
it('persists brand_logo_stamp from a logo_stamp_state stream event', function () {
    // Fake the ai-service stream so it emits a logo_stamp_state frame.
    // ndjson: one JSON object per line.
    Http::fake([
        '*/ai/kv-generator/stream' => Http::response(
            json_encode(['event' => 'logo_stamp_state',
                         'stamp' => ['anchor' => 'top-left', 'scale' => 'large']])."\n".
            json_encode(['event' => 'done'])."\n",
            200,
            ['Content-Type' => 'application/x-ndjson'],
        ),
    ]);

    // Same setup as the outbound test: $user, $workspace, $brand, $file
    // with launch_context.studio_file_id = $file->id, brand_knowledge on.
    // Drive the stream (mode=image), flush with ->streamedContent().

    expect($file->fresh()->brand_logo_stamp)
        ->toBe(['anchor' => 'top-left', 'scale' => 'large']);
});

it('clears brand_logo_stamp when stamp is null', function () {
    Http::fake([
        '*/ai/kv-generator/stream' => Http::response(
            json_encode(['event' => 'logo_stamp_state', 'stamp' => null])."\n".
            json_encode(['event' => 'done'])."\n",
            200,
            ['Content-Type' => 'application/x-ndjson'],
        ),
    ]);

    // $file seeded WITH a stamp; after the stream it must be null.
    // ... drive the stream as above ...

    expect($file->fresh()->brand_logo_stamp)->toBeNull();
});
```

> **Note for the engineer:** The streaming consumer in `ChatService` reads the response byte-by-byte. `Http::response(...)` with a plain string body works with `Http::fake()` for tests because the fake returns the whole body at once. If the existing chat tests stub the stream differently (e.g. a sequence helper), match that approach — check whether any existing test exercises `generation_ready`/`generation_done` parsing and reuse its faking style.

- [ ] **Step 4: Run the tests (after Task 0 pre-flight!)**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && ./vendor/bin/pest tests/Feature/Chat/BrandLogoStampTest.php -v`
Expected: 4/4 PASS. If the URL match fails, `dump($request->url())` once and adjust the fragment to the configured ai-service host (`config/services.php`).

- [ ] **Step 5: Run the broader chat suite for regressions**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && ./vendor/bin/pest tests/Feature/Chat/ -v 2>&1 | tail -20`
Expected: `BrandAssetFeedingTest` still passes; the new file passes. Pre-existing unrelated failures are out of scope — call them out.

- [ ] **Step 6: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
git add tests/Feature/Chat/BrandLogoStampTest.php
git commit -m "test(api): cover brand_logo payload + logo_stamp_state persistence"
```

---

## Self-review checklist

- ✅ **Spec coverage:** migration+model (T1), outbound `brand_logo`+`brand_logo_stamp` with image-turn gating (T2), inbound persistence (T3), tests (T4). DB-safety pre-flight (T0).
- ✅ **No placeholders:** all net-new code shown verbatim. The test bodies point to `BrandAssetFeedingTest.php` for the FormRequest body + stream-fake harness — load-bearing references, not invented fields (same approach as the existing Layer-1/B3 plans).
- ✅ **Type consistency:** payload `brand_logo {data_base64, mime_type}` and `brand_logo_stamp {anchor, scale}` match the ai-service `BrandLogoAsset` / `BrandLogoStamp` schemas in the ai-service plan. The `logo_stamp_state` event's `stamp` key matches `LogoStampStateEvent.stamp`.
- ✅ **TDD:** T4 tests assert both directions; T1 verified by tinker round-trip; T2/T3 are structural and covered by T4.
- ✅ **DB-safety:** T0 enforces the bootstrap/cache + phpunit.xml checks before any Pest run (lesson_test_db_isolation).
- ✅ **YAGNI:** no PATCH endpoint, no web changes, no resize handling.
