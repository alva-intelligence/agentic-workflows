# Brand-Aware AskFrnd — api Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve the AskFrnd location context (Condition A active brand, or Condition B brand directory) server-side and forward it to ai-service in the chat/PAA payload — without any deep brand-knowledge fetch (that happens on-demand in ai-service).

**Architecture:** A small `BrandLocationContextResolver` turns `(user, workspaceId, originBrandId)` into `active_brand` (when inside a brand) or `brand_directory` (on Home, via `Brand::accessibleBy`). Two new nullable fields on `ChatPayloadData` carry it to ai-service. Everything is resolved **before** the stream opens, so there is no `php artisan serve` deadlock.

**Tech Stack:** Laravel 13, PHP 8.5, Pest. The `brands` table + `Brand::accessibleBy` scope already exist.

**Spec:** `docs/superpowers/specs/2026-06-23-askfrnd-brand-context-awareness-design.md`

**Sibling plans:** `2026-06-23-askfrnd-brand-context-ai-service.md` (defines the wire contract `active_brand`/`brand_directory`), `2026-06-23-askfrnd-brand-context-web.md`

> ⚠️ **Before running ANY Pest Feature test:** verify `api/phpunit.xml` + `api/tests/Pest.php` DB isolation (SQLite override) is active — a previously-commented override wiped the dev DB once. Prefer Unit tests for verification; only run the optional Feature test after confirming isolation.

**Run tests with:** `cd api && ./vendor/bin/pest <path>`

---

## File Structure

- Create: `api/app/Services/Chat/BrandLocationContextResolver.php` — resolves active_brand / brand_directory.
- Modify: `api/app/Data/Chat/ChatPayloadData.php` — add `activeBrand`, `brandDirectory` props + payload keys.
- Modify: `api/app/Http/Controllers/Api/Chat/ThreadController.php` — wire resolver into main-chat store (line ~375) + update (line ~781).
- Modify: `api/app/Services/ChatService.php` — wire resolver into PAA construction (line ~222).
- Test: `api/tests/Unit/Chat/ChatPayloadBrandContextTest.php`, `api/tests/Unit/Chat/BrandLocationContextResolverTest.php`.

---

## Task 1: Add brand-context fields to ChatPayloadData

**Files:**
- Modify: `api/app/Data/Chat/ChatPayloadData.php`
- Test: `api/tests/Unit/Chat/ChatPayloadBrandContextTest.php`

- [ ] **Step 1: Write the failing test**

```php
<?php
// api/tests/Unit/Chat/ChatPayloadBrandContextTest.php

use App\Data\Chat\ChatPayloadData;

function basePayload(array $override = []): ChatPayloadData
{
    return new ChatPayloadData(
        userId: 'u1', workspaceId: 'w1', threadId: 't1', message: 'hi',
        isImageGeneration: false, isWebSearch: false, isVideoGeneration: false,
        model: 'gpt-4o', modelProvider: 'openai', imageModel: 'gpt-image-1',
        imageModelProvider: 'openai', videoModel: 'veo', videoModelProvider: 'google',
        images: [], video: null, files: [], websearchProvider: 'tavily',
        activeBrand: $override['activeBrand'] ?? null,
        brandDirectory: $override['brandDirectory'] ?? null,
    );
}

it('omits brand context keys when not set', function () {
    $payload = basePayload()->toPayload();
    expect($payload)->not->toHaveKey('active_brand');
    expect($payload)->not->toHaveKey('brand_directory');
});

it('includes active_brand when set (Condition A)', function () {
    $payload = basePayload(['activeBrand' => ['id' => 'b1', 'name' => 'OCBC', 'description' => 'bank']])->toPayload();
    expect($payload['active_brand'])->toBe(['id' => 'b1', 'name' => 'OCBC', 'description' => 'bank']);
    expect($payload)->not->toHaveKey('brand_directory');
});

it('includes brand_directory when set (Condition B)', function () {
    $dir = [['id' => 'b1', 'name' => 'OCBC', 'description' => 'bank']];
    $payload = basePayload(['brandDirectory' => $dir])->toPayload();
    expect($payload['brand_directory'])->toBe($dir);
    expect($payload)->not->toHaveKey('active_brand');
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd api && ./vendor/bin/pest tests/Unit/Chat/ChatPayloadBrandContextTest.php`
Expected: FAIL — `Unknown named parameter $activeBrand`.

- [ ] **Step 3: Add the constructor props**

In `api/app/Data/Chat/ChatPayloadData.php`, add two params after `public ?string $brandId = null,` (line 68), before the closing `) {}`:

```php
        /**
         * AskFrnd location context (Condition A). Resolved by the API before
         * streaming. Shape: ['id' => ..., 'name' => ..., 'description' => ...].
         * Null when not inside a brand workspace.
         */
        public ?array $activeBrand = null,
        /**
         * AskFrnd location context (Condition B — Home). A lightweight list of
         * brands the user can access: [['id','name','description'], ...].
         * Null when inside a brand workspace.
         */
        public ?array $brandDirectory = null,
```

- [ ] **Step 4: Add the payload keys**

In `toPayload()`, add after the `brand_id` block (line 141), before `return $payload;`:

```php
        if ($this->activeBrand !== null) {
            $payload['active_brand'] = $this->activeBrand;
        }

        if ($this->brandDirectory !== null) {
            $payload['brand_directory'] = $this->brandDirectory;
        }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd api && ./vendor/bin/pest tests/Unit/Chat/ChatPayloadBrandContextTest.php`
Expected: PASS (3 passed).

- [ ] **Step 6: Commit**

```bash
git -C api add app/Data/Chat/ChatPayloadData.php tests/Unit/Chat/ChatPayloadBrandContextTest.php
git -C api commit -m "feat(api): add active_brand/brand_directory to ChatPayloadData"
```

---

## Task 2: BrandLocationContextResolver

**Files:**
- Create: `api/app/Services/Chat/BrandLocationContextResolver.php`
- Test: `api/tests/Unit/Chat/BrandLocationContextResolverTest.php`

The resolver is a pure transform over a brand lookup. To keep it unit-testable without the DB, it depends on two closures injected at call time (or it queries `Brand` directly in production). We use a thin, mockable seam: the resolver accepts the already-loaded active brand model and the directory collection. The controller does the `Brand` queries (access-scoped) and hands results in.

- [ ] **Step 1: Write the failing test**

```php
<?php
// api/tests/Unit/Chat/BrandLocationContextResolverTest.php

use App\Services\Chat\BrandLocationContextResolver;

it('returns active_brand for Condition A', function () {
    $result = BrandLocationContextResolver::build(
        activeBrand: (object) ['id' => 'b1', 'name' => 'OCBC', 'description' => 'bank'],
        directory: collect(),
    );
    expect($result['active_brand'])->toBe(['id' => 'b1', 'name' => 'OCBC', 'description' => 'bank']);
    expect($result['brand_directory'])->toBeNull();
});

it('returns brand_directory for Condition B', function () {
    $dir = collect([
        (object) ['id' => 'b1', 'name' => 'OCBC', 'description' => 'bank'],
        (object) ['id' => 'b2', 'name' => 'Acme', 'description' => null],
    ]);
    $result = BrandLocationContextResolver::build(activeBrand: null, directory: $dir);
    expect($result['active_brand'])->toBeNull();
    expect($result['brand_directory'])->toBe([
        ['id' => 'b1', 'name' => 'OCBC', 'description' => 'bank'],
        ['id' => 'b2', 'name' => 'Acme', 'description' => null],
    ]);
});

it('returns both null when no brand context', function () {
    $result = BrandLocationContextResolver::build(activeBrand: null, directory: collect());
    expect($result['active_brand'])->toBeNull();
    expect($result['brand_directory'])->toBeNull();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd api && ./vendor/bin/pest tests/Unit/Chat/BrandLocationContextResolverTest.php`
Expected: FAIL — class not found.

- [ ] **Step 3: Write minimal implementation**

```php
<?php
// api/app/Services/Chat/BrandLocationContextResolver.php

namespace App\Services\Chat;

use Illuminate\Support\Collection;

class BrandLocationContextResolver
{
    /**
     * Build the AskFrnd location context payload.
     *
     * @param  object|null  $activeBrand  Brand model/object with id,name,description (Condition A) or null.
     * @param  Collection<int, object>  $directory  Accessible brands for Home (Condition B).
     * @return array{active_brand: array<string,mixed>|null, brand_directory: array<int,array<string,mixed>>|null}
     */
    public static function build(?object $activeBrand, Collection $directory): array
    {
        if ($activeBrand !== null) {
            return [
                'active_brand' => [
                    'id' => $activeBrand->id,
                    'name' => $activeBrand->name,
                    'description' => $activeBrand->description ?? null,
                ],
                'brand_directory' => null,
            ];
        }

        if ($directory->isNotEmpty()) {
            return [
                'active_brand' => null,
                'brand_directory' => $directory->map(fn ($b) => [
                    'id' => $b->id,
                    'name' => $b->name,
                    'description' => $b->description ?? null,
                ])->values()->all(),
            ];
        }

        return ['active_brand' => null, 'brand_directory' => null];
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd api && ./vendor/bin/pest tests/Unit/Chat/BrandLocationContextResolverTest.php`
Expected: PASS (3 passed).

- [ ] **Step 5: Commit**

```bash
git -C api add app/Services/Chat/BrandLocationContextResolver.php tests/Unit/Chat/BrandLocationContextResolverTest.php
git -C api commit -m "feat(api): add BrandLocationContextResolver"
```

---

## Task 3: Wire the resolver into the main-chat store path

**Files:**
- Modify: `api/app/Http/Controllers/Api/Chat/ThreadController.php` (store, around line 375)

- [ ] **Step 1: Add the use statement**

At the top of `ThreadController.php` with the other `use` imports, add:

```php
use App\Models\Brand;
use App\Services\Chat\BrandLocationContextResolver;
```

(Skip any that already exist.)

- [ ] **Step 2: Resolve location context just before constructing the payload**

Immediately before `$chatPayload = new ChatPayloadData(` (line 375), add:

```php
                $originBrandId = $streamRequest->input('origin_brand_id');
                $activeBrandModel = null;
                $brandDirectory = collect();
                if (! empty($originBrandId)) {
                    $activeBrandModel = Brand::accessibleBy($userId, $workspaceId)
                        ->where('id', $originBrandId)
                        ->first(['id', 'name', 'description']);
                }
                if ($activeBrandModel === null) {
                    $brandDirectory = Brand::accessibleBy($userId, $workspaceId)
                        ->orderBy('name')
                        ->get(['id', 'name', 'description']);
                }
                $brandLocation = BrandLocationContextResolver::build($activeBrandModel, $brandDirectory);
```

- [ ] **Step 3: Pass into the payload constructor**

Add these two named args to the `new ChatPayloadData(...)` call (before the closing `);` at line 401):

```php
                    activeBrand: $brandLocation['active_brand'],
                    brandDirectory: $brandLocation['brand_directory'],
```

- [ ] **Step 4: Verify it loads (no syntax errors)**

Run: `cd api && php -l app/Http/Controllers/Api/Chat/ThreadController.php`
Expected: `No syntax errors detected`.

- [ ] **Step 5: Commit**

```bash
git -C api add app/Http/Controllers/Api/Chat/ThreadController.php
git -C api commit -m "feat(api): forward AskFrnd location context on new chat thread"
```

---

## Task 4: Wire the resolver into the main-chat update (follow-up) path

**Files:**
- Modify: `api/app/Http/Controllers/Api/Chat/ThreadController.php` (update, around line 781)

On follow-up turns the origin brand was captured at thread creation and persisted on the thread (`origin_brand_id`). Read it from the thread, not the request, so cached context stays consistent across the session.

- [ ] **Step 1: Resolve location context before the construction at line 781**

Immediately before `$chatPayload = new ChatPayloadData(` (line 781), add (use the loaded `$thread` variable in scope — confirm its name by reading the surrounding method):

```php
                $originBrandId = $thread->origin_brand_id;
                $activeBrandModel = null;
                $brandDirectory = collect();
                if (! empty($originBrandId)) {
                    $activeBrandModel = Brand::accessibleBy($userId, $workspaceId)
                        ->where('id', $originBrandId)
                        ->first(['id', 'name', 'description']);
                }
                if ($activeBrandModel === null) {
                    $brandDirectory = Brand::accessibleBy($userId, $workspaceId)
                        ->orderBy('name')
                        ->get(['id', 'name', 'description']);
                }
                $brandLocation = BrandLocationContextResolver::build($activeBrandModel, $brandDirectory);
```

(If `$userId`/`$workspaceId` are named differently in this method, adapt to the in-scope variables.)

- [ ] **Step 2: Pass into the payload constructor**

Add to the `new ChatPayloadData(...)` at line 781:

```php
                    activeBrand: $brandLocation['active_brand'],
                    brandDirectory: $brandLocation['brand_directory'],
```

- [ ] **Step 3: Verify syntax**

Run: `cd api && php -l app/Http/Controllers/Api/Chat/ThreadController.php`
Expected: `No syntax errors detected`.

- [ ] **Step 4: Commit**

```bash
git -C api add app/Http/Controllers/Api/Chat/ThreadController.php
git -C api commit -m "feat(api): forward AskFrnd location context on chat follow-up turns"
```

---

## Task 5: Wire the resolver into the PAA path

**Files:**
- Modify: `api/app/Services/ChatService.php` (PAA construction, around line 222 in `streamPointAndAsk`)

- [ ] **Step 1: Add the use statements**

At the top of `ChatService.php`, add (skip if present):

```php
use App\Models\Brand;
use App\Services\Chat\BrandLocationContextResolver;
```

- [ ] **Step 2: Resolve location context before the `new ChatPayloadData(` at line 222**

PAA already has `$brandId` and the `$thread`/`$user`/`$workspace` in scope. Add before the construction:

```php
        $paaOriginBrandId = $brandId ?? $thread->origin_brand_id;
        $paaActiveBrand = null;
        $paaDirectory = collect();
        if (! empty($paaOriginBrandId)) {
            $paaActiveBrand = Brand::accessibleBy($user->id, $workspace->id)
                ->where('id', $paaOriginBrandId)
                ->first(['id', 'name', 'description']);
        }
        if ($paaActiveBrand === null) {
            $paaDirectory = Brand::accessibleBy($user->id, $workspace->id)
                ->orderBy('name')
                ->get(['id', 'name', 'description']);
        }
        $paaBrandLocation = BrandLocationContextResolver::build($paaActiveBrand, $paaDirectory);
```

(Confirm the in-scope variable names `$user`, `$workspace`, `$thread`, `$brandId` by reading `streamPointAndAsk` — adapt if different.)

- [ ] **Step 3: Pass into the PAA payload constructor**

Add to the `new ChatPayloadData(...)` at line 222 (after `brandId: $brandId,`):

```php
                    activeBrand: $paaBrandLocation['active_brand'],
                    brandDirectory: $paaBrandLocation['brand_directory'],
```

- [ ] **Step 4: Verify syntax**

Run: `cd api && php -l app/Services/ChatService.php`
Expected: `No syntax errors detected`.

- [ ] **Step 5: Commit**

```bash
git -C api add app/Services/ChatService.php
git -C api commit -m "feat(api): forward AskFrnd location context on PAA turns"
```

---

## Task 6: Optional Feature test (forwarding to ai-service)

> Only run after confirming `api/phpunit.xml` SQLite override is active (see banner). If the Feature suite is blocked on your machine (known workspaces/SoftDeletes backfill issue), skip the run and rely on Tasks 1–2 unit coverage; still commit the test file.

**Files:**
- Test: `api/tests/Feature/Chat/StreamChatBrandContextTest.php`

- [ ] **Step 1: Write the test**

```php
<?php
// api/tests/Feature/Chat/StreamChatBrandContextTest.php

use App\Models\Brand;
use App\Models\User;
use App\Models\Workspace;
use Illuminate\Support\Facades\Http;

it('forwards active_brand when starting a chat inside a brand workspace', function () {
    Http::fake(['*' => Http::response("data: {}\n\n", 200)]);

    $user = User::factory()->create();
    $workspace = Workspace::factory()->for($user)->create();
    $brand = Brand::factory()->for($user)->for($workspace)->create([
        'name' => 'OCBC Nyala', 'description' => 'Friendly modern bank',
    ]);

    $this->actingAs($user)->post('/api/v1/threads/stream', [
        'message' => 'What is our brand tone?',
        'model_name' => 'gpt-4o',
        'origin_brand_id' => $brand->id,
        'origin_brand_name' => 'OCBC Nyala',
        'origin_path' => "/brands/{$brand->id}/insights",
    ]);

    Http::assertSent(function ($request) use ($brand) {
        $body = $request->data();
        return ($body['active_brand']['id'] ?? null) === $brand->id
            && ($body['active_brand']['name'] ?? null) === 'OCBC Nyala';
    });
});
```

- [ ] **Step 2: (Conditional) run it**

Run: `cd api && ./vendor/bin/pest tests/Feature/Chat/StreamChatBrandContextTest.php`
Expected: PASS (1 passed) — IF the Feature suite is runnable. Otherwise skip per the banner.

- [ ] **Step 3: Commit**

```bash
git -C api add tests/Feature/Chat/StreamChatBrandContextTest.php
git -C api commit -m "test(api): assert AskFrnd active_brand forwarded to ai-service"
```

---

## Notes for the implementer
- Do NOT push or open a PR — Daffa pushes manually.
- `Brand::accessibleBy($userId, $workspaceId)` is the existing access-control scope (Brand.php:238) — always use it so the directory/active brand respects permissions. ai-service trusts these ids.
- Resolve everything BEFORE `processStream`/the HTTP stream opens — never inside the stream callback (deadlock).
- If a `new ChatPayloadData(` call site uses positional args anywhere, switch it to named args for the two new fields (the existing sites already use named args).
