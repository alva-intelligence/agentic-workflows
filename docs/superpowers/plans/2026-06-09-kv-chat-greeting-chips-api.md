# KV Chat Greeting Chips — API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `GET /api/v1/studio/files/{file}/chat-suggestion` that gathers project context (brand name, file title, recent generation prompts), POSTs it to ai-service, and returns `{ data: { suggestion: string|null } }` — never erroring the empty state.

**Architecture:** A thin `KvChatSuggestionService` resolves context off the `StudioFile` (brand via `file.brand_id` → `Brand.name`, falling back to the parent project's brand; title via `file.name`; up to 3 most-recent `KvGeneration.prompt_snapshot` ordered by `version_number desc`), then POSTs to ai-service `POST {config('services.ai.url')}/ai/kv-chat/suggestion`. The whole ai-service call is wrapped in try/catch and gated on `$response->successful()`; any unhappy path returns `null`. A controller in the existing studio route group wraps the service result in `{ data: { suggestion } }`.

**Tech Stack:** Laravel 13, PHP, PostgreSQL, Pest

---

## Shared contract (locked — must match ai-service + web)

- ai-service call: `POST {ai_url}/ai/kv-chat/suggestion`, body keys `brand_name`, `title`, `recent_prompts` (string[]).
- ai-service returns `{ "suggestion": string|null }`.
- This endpoint returns `{ "data": { "suggestion": string|null } }`, always HTTP 200 on auth-OK.

## Real field/route facts (verified against code, do NOT re-derive)

- File title column: `StudioFile.name` (`app/Models/StudioFile.php:27`).
- Brand: `StudioFile.brand_id` + `brand()` belongsTo `Brand`; `Brand.name` (`app/Models/Brand.php:25`). `Brand` has a `DemoBrandVisibilityScope` global scope + `SoftDeletes` — resolve via the `brand()` relation / `Brand::find()` (mirrors `ProcessKvResizeExportJob.php:43`), which respects scopes.
- Project fallback: `StudioFile.project_id` → `project()` belongsTo `StudioProject`; `StudioProject.brand_id` + `brand()` belongsTo `Brand` (`app/Models/StudioProject.php:20,40`).
- KvGeneration prompt field: `prompt_snapshot` (`text`, NOT NULL — `database/migrations/2026_04_23_100040_create_kv_generations_table.php:19`). FK to file is `studio_file_id`. Order recent rows by `version_number` desc (mirrors `KvResizeExportController.php:29-31`). `KvGeneration` has `public $timestamps = false`.
- ai-service URL: `config('services.ai.url')` (from `FRND_AI_SERVICES_URL`, `config/services.php:202-204`). Call pattern: `Http::timeout(...)->post("{$aiUrl}/ai/...", [...])` (`ProcessKvResizeExportJob.php:51-66`).
- Route group: `Route::prefix('v1') → prefix('studio') → middleware(['scope_role:internal'])`, with the KV routes inside a nested `middleware('feature.flag:show-kv-generator')->group(...)`. The sibling `files/{file}/resize-exports` routes live in that nested group (`routes/api.php:1953,1987`). Register the new route there so the full path resolves to `/api/v1/studio/files/{file}/chat-suggestion`.
- Auth guard (mirror exactly): `$file = StudioFile::findOrFail($fileId); abort_unless($file->workspace_id === $request->user()->current_workspace_id, 403);` (`KvResizeExportController.php:26-27`).

## DB isolation (project memory — MANDATORY)

The broad Feature suite is broken on fresh migrate (workspaces backfill + SoftDeletes). **Run ONLY the named test files below**, never `tests/Feature` wholesale, never against dev postgres. Step 0 of each DB-touching task re-asserts `api/phpunit.xml` has `<env name="DB_CONNECTION" value="sqlite"/>` + `<env name="DB_DATABASE" value=":memory:"/>` (currently correct — confirm before running).

---

## Task 1 — `KvChatSuggestionService` (context gather + ai-service call + null-on-failure)

**Files:**
- `app/Services/Studio/KvChatSuggestionService.php` (new)
- `tests/Feature/Studio/KvChatSuggestionServiceTest.php` (new)

Steps:

- [ ] **Step 0 — DB isolation check.** Open `api/phpunit.xml` and confirm lines exist (uncommented):
  ```xml
  <env name="DB_CONNECTION" value="sqlite"/>
  <env name="DB_DATABASE" value=":memory:"/>
  ```
  If commented or missing, STOP and fix before running any test (per `lesson_test_db_isolation`).

- [ ] **Step 1 — Write the failing test.** Create `tests/Feature/Studio/KvChatSuggestionServiceTest.php`. This builds a brand/file/generations via factories (mirroring `KvResizeExportControllerTest.php` setup), fakes the ai-service HTTP call, and asserts both the forwarded body and the returned suggestion + null-on-failure. If `KvGeneration::factory()` is missing a needed field, build the model directly with `->create([...])` (the factory exists and is used in `KvResizeExportControllerTest.php:42`).

  ```php
  <?php

  use App\Models\Brand;
  use App\Models\KvGeneration;
  use App\Models\StudioFile;
  use App\Models\StudioProject;
  use App\Models\Tool;
  use App\Models\User;
  use App\Models\Workspace;
  use App\Services\Studio\KvChatSuggestionService;
  use Illuminate\Support\Facades\Http;

  beforeEach(function () {
      $this->user = User::factory()->create();
      $this->workspace = Workspace::factory()->create(['type' => 'organization']);
      $this->user->update(['current_workspace_id' => $this->workspace->id]);

      $this->brand = Brand::factory()->create(['name' => 'Acme Co']);
      $tool = Tool::factory()->create(['slug' => 'kv-generator']);

      $this->file = StudioFile::factory()->create([
          'workspace_id' => $this->workspace->id,
          'brand_id' => $this->brand->id,
          'tool_id' => $tool->id,
          'created_by' => $this->user->id,
          'last_edited_by' => $this->user->id,
          'name' => 'Summer Launch KV',
      ]);

      // Three generations; recent-first by version_number desc.
      foreach ([1, 2, 3] as $v) {
          KvGeneration::factory()->create([
              'studio_file_id' => $this->file->id,
              'version_number' => $v,
              'image_url' => "https://example.com/v{$v}.png",
              'prompt_snapshot' => "prompt v{$v}",
              'created_by' => $this->user->id,
          ]);
      }
  });

  it('forwards brand name, title and recent prompts and returns the ai suggestion', function () {
      Http::fake([
          '*/ai/kv-chat/suggestion' => Http::response(['suggestion' => 'Design a bold summer hero'], 200),
      ]);

      $suggestion = app(KvChatSuggestionService::class)->suggest($this->file->fresh());

      expect($suggestion)->toBe('Design a bold summer hero');

      Http::assertSent(function ($request) {
          $body = $request->data();

          return str_contains((string) $request->url(), '/ai/kv-chat/suggestion')
              && $body['brand_name'] === 'Acme Co'
              && $body['title'] === 'Summer Launch KV'
              // most-recent-first, capped at 3
              && $body['recent_prompts'] === ['prompt v3', 'prompt v2', 'prompt v1'];
      });
  });

  it('falls back to the parent project brand when the file has no brand', function () {
      $projectBrand = Brand::factory()->create(['name' => 'Project Brand']);
      $project = StudioProject::factory()->create([
          'workspace_id' => $this->workspace->id,
          'brand_id' => $projectBrand->id,
          'created_by' => $this->user->id,
          'last_edited_by' => $this->user->id,
      ]);
      $this->file->update(['brand_id' => null, 'project_id' => $project->id]);

      Http::fake([
          '*/ai/kv-chat/suggestion' => Http::response(['suggestion' => 'ok'], 200),
      ]);

      app(KvChatSuggestionService::class)->suggest($this->file->fresh());

      Http::assertSent(fn ($request) => $request->data()['brand_name'] === 'Project Brand');
  });

  it('returns null when ai-service responds non-2xx', function () {
      Http::fake([
          '*/ai/kv-chat/suggestion' => Http::response('boom', 500),
      ]);

      expect(app(KvChatSuggestionService::class)->suggest($this->file->fresh()))->toBeNull();
  });

  it('returns null when the ai-service call throws (connection error)', function () {
      Http::fake(function () {
          throw new \Illuminate\Http\Client\ConnectionException('down');
      });

      expect(app(KvChatSuggestionService::class)->suggest($this->file->fresh()))->toBeNull();
  });

  it('returns null when the ai-service body is malformed (no suggestion key)', function () {
      Http::fake([
          '*/ai/kv-chat/suggestion' => Http::response(['nope' => true], 200),
      ]);

      expect(app(KvChatSuggestionService::class)->suggest($this->file->fresh()))->toBeNull();
  });
  ```

  > If `StudioProject::factory()` or `Brand::factory()` lacks a field, build directly with the model's `$fillable` keys (note `Brand` has `SoftDeletes` + `DemoBrandVisibilityScope` — factory-created brands are visible by default in tests).

- [ ] **Step 2 — Run, expect FAIL.** `KvChatSuggestionService` does not exist yet:
  ```bash
  ./vendor/bin/pest tests/Feature/Studio/KvChatSuggestionServiceTest.php
  ```
  Expect: error/fail (class `App\Services\Studio\KvChatSuggestionService` not found).

- [ ] **Step 3 — Minimal implementation.** Create `app/Services/Studio/KvChatSuggestionService.php`:

  ```php
  <?php

  namespace App\Services\Studio;

  use App\Models\KvGeneration;
  use App\Models\StudioFile;
  use Illuminate\Support\Facades\Http;
  use Throwable;

  class KvChatSuggestionService
  {
      /**
       * Build project context and ask ai-service for ONE short prompt
       * suggestion. Returns null on ANY failure — this must never throw,
       * so the chat empty state can degrade to its static chips.
       */
      public function suggest(StudioFile $file): ?string
      {
          try {
              $brandName = $this->resolveBrandName($file);
              $title = $file->name;
              $recentPrompts = $this->recentPrompts($file);

              $aiUrl = rtrim((string) config('services.ai.url'), '/');

              $response = Http::timeout(20)
                  ->post("{$aiUrl}/ai/kv-chat/suggestion", [
                      'brand_name' => $brandName,
                      'title' => $title,
                      'recent_prompts' => $recentPrompts,
                  ]);

              if (! $response->successful()) {
                  return null;
              }

              $suggestion = $response->json('suggestion');

              return is_string($suggestion) && $suggestion !== '' ? $suggestion : null;
          } catch (Throwable) {
              return null;
          }
      }

      private function resolveBrandName(StudioFile $file): ?string
      {
          // File brand wins; fall back to the parent project's brand.
          $brand = $file->brand_id ? $file->brand : null;

          if (! $brand && $file->project_id) {
              $brand = optional($file->project)->brand;
          }

          return $brand?->name;
      }

      /**
       * @return string[] up to 3 most-recent prompts, recent-first.
       */
      private function recentPrompts(StudioFile $file): array
      {
          return KvGeneration::where('studio_file_id', $file->id)
              ->orderByDesc('version_number')
              ->limit(3)
              ->pluck('prompt_snapshot')
              ->filter(fn ($p) => is_string($p) && $p !== '')
              ->values()
              ->all();
      }
  }
  ```

- [ ] **Step 4 — Run, expect PASS.**
  ```bash
  ./vendor/bin/pest tests/Feature/Studio/KvChatSuggestionServiceTest.php
  ```
  Expect: all 5 tests green.

- [ ] **Step 5 — Commit.**
  ```bash
  git add app/Services/Studio/KvChatSuggestionService.php tests/Feature/Studio/KvChatSuggestionServiceTest.php
  git commit -m "feat(api): add KvChatSuggestionService for KV chat greeting suggestion"
  ```

---

## Task 2 — Controller + route (`GET files/{file}/chat-suggestion`)

**Files:**
- `app/Http/Controllers/Api/Studio/KvChatSuggestionController.php` (new)
- `routes/api.php` (edit — add route inside the `feature.flag:show-kv-generator` group, next to `files/{file}/resize-exports`)
- `tests/Feature/Studio/KvChatSuggestionControllerTest.php` (new)

Steps:

- [ ] **Step 0 — DB isolation check.** Re-confirm `api/phpunit.xml` has sqlite `:memory:` (see Task 1 Step 0).

- [ ] **Step 1 — Write the failing test.** Create `tests/Feature/Studio/KvChatSuggestionControllerTest.php`, mirroring the auth/role/factory setup from `KvResizeExportControllerTest.php:15-50`:

  ```php
  <?php

  use App\Models\Brand;
  use App\Models\KvGeneration;
  use App\Models\Role;
  use App\Models\StudioFile;
  use App\Models\Tool;
  use App\Models\User;
  use App\Models\Workspace;
  use Illuminate\Support\Facades\Http;
  use Illuminate\Support\Str;

  beforeEach(function () {
      $this->user = User::factory()->create();
      $this->brand = Brand::factory()->create(['name' => 'Acme Co']);
      $this->workspace = Workspace::factory()->create(['type' => 'organization']);
      $this->user->update(['current_workspace_id' => $this->workspace->id]);
      $this->user->workspaces()->attach($this->workspace->id);

      $role = Role::factory()->create([
          'slug' => 'internal-'.Str::random(6),
          'type' => 'workspace',
          'scope' => 'internal',
      ]);
      $this->user->workspaceRoles()->attach($role->id, [
          'workspace_id' => $this->workspace->id,
      ]);

      $tool = Tool::factory()->create(['slug' => 'kv-generator']);

      $this->file = StudioFile::factory()->create([
          'workspace_id' => $this->workspace->id,
          'brand_id' => $this->brand->id,
          'tool_id' => $tool->id,
          'created_by' => $this->user->id,
          'last_edited_by' => $this->user->id,
          'name' => 'Summer Launch KV',
      ]);
      KvGeneration::factory()->create([
          'studio_file_id' => $this->file->id,
          'version_number' => 1,
          'image_url' => 'https://example.com/v1.png',
          'prompt_snapshot' => 'prompt v1',
          'created_by' => $this->user->id,
      ]);

      $this->actingAs($this->user, 'api');
  });

  it('returns the ai-service suggestion wrapped in data', function () {
      Http::fake([
          '*/ai/kv-chat/suggestion' => Http::response(['suggestion' => 'Design a bold summer hero'], 200),
      ]);

      $resp = $this->getJson("/api/v1/studio/files/{$this->file->id}/chat-suggestion");

      $resp->assertOk();
      $resp->assertExactJson(['data' => ['suggestion' => 'Design a bold summer hero']]);
  });

  it('returns suggestion null with HTTP 200 when ai-service fails', function () {
      Http::fake([
          '*/ai/kv-chat/suggestion' => Http::response('boom', 500),
      ]);

      $resp = $this->getJson("/api/v1/studio/files/{$this->file->id}/chat-suggestion");

      $resp->assertOk();
      $resp->assertExactJson(['data' => ['suggestion' => null]]);
  });

  it('403s when the file belongs to another workspace', function () {
      Http::fake();
      $otherWorkspace = Workspace::factory()->create(['type' => 'organization']);
      $otherFile = StudioFile::factory()->create([
          'workspace_id' => $otherWorkspace->id,
          'tool_id' => Tool::factory()->create(['slug' => 'kv-generator-2'])->id,
          'created_by' => $this->user->id,
          'last_edited_by' => $this->user->id,
      ]);

      $resp = $this->getJson("/api/v1/studio/files/{$otherFile->id}/chat-suggestion");

      $resp->assertStatus(403);
  });
  ```

- [ ] **Step 2 — Run, expect FAIL.** Route/controller not registered yet:
  ```bash
  ./vendor/bin/pest tests/Feature/Studio/KvChatSuggestionControllerTest.php
  ```
  Expect: 404 (route missing) / class-not-found failures.

- [ ] **Step 3 — Minimal implementation.**

  Create `app/Http/Controllers/Api/Studio/KvChatSuggestionController.php`:

  ```php
  <?php

  namespace App\Http\Controllers\Api\Studio;

  use App\Http\Controllers\Controller;
  use App\Models\StudioFile;
  use App\Services\Studio\KvChatSuggestionService;
  use Illuminate\Http\JsonResponse;
  use Illuminate\Http\Request;

  class KvChatSuggestionController extends Controller
  {
      public function __construct(
          private KvChatSuggestionService $service,
      ) {}

      public function show(Request $request, string $fileId): JsonResponse
      {
          $file = StudioFile::findOrFail($fileId);
          abort_unless($file->workspace_id === $request->user()->current_workspace_id, 403);

          return response()->json([
              'data' => ['suggestion' => $this->service->suggest($file)],
          ]);
      }
  }
  ```

  Add the import near the other `Api\Studio` controller imports in `routes/api.php` (the block around line 77, after `use App\Http\Controllers\Api\Studio\KvResizeExportController;`):

  ```php
  use App\Http\Controllers\Api\Studio\KvChatSuggestionController;
  ```

  Register the route inside the `feature.flag:show-kv-generator` group, immediately after the `files/{file}/resize-exports` block (after `routes/api.php:1990`, the `KvResizeExportController index` route):

  ```php
  // KV Chat greeting suggestion (LLM-generated empty-state chip).
  Route::get('files/{file}/chat-suggestion', [
      KvChatSuggestionController::class,
      'show',
  ]);
  ```

- [ ] **Step 4 — Run, expect PASS.**
  ```bash
  ./vendor/bin/pest tests/Feature/Studio/KvChatSuggestionControllerTest.php
  ```
  Expect: all 3 tests green.

- [ ] **Step 5 — Regression run (both new files only — never the whole suite).**
  ```bash
  ./vendor/bin/pest tests/Feature/Studio/KvChatSuggestionServiceTest.php tests/Feature/Studio/KvChatSuggestionControllerTest.php
  ```
  Expect: all 8 tests green.

- [ ] **Step 6 — Commit.**
  ```bash
  git add app/Http/Controllers/Api/Studio/KvChatSuggestionController.php routes/api.php tests/Feature/Studio/KvChatSuggestionControllerTest.php
  git commit -m "feat(api): add GET studio/files/{file}/chat-suggestion endpoint"
  ```

---

## Done criteria (api slice)

- `GET /api/v1/studio/files/{file}/chat-suggestion` returns `{ data: { suggestion: string|null } }`, HTTP 200 on auth-OK.
- Same workspace guard (`abort_unless(... === current_workspace_id, 403)`) as sibling studio endpoints.
- Context forwarded to ai-service `POST {ai_url}/ai/kv-chat/suggestion` with body keys `brand_name`, `title`, `recent_prompts`.
- Brand resolves file → project fallback; title = `StudioFile.name`; recent prompts = up to 3 `KvGeneration.prompt_snapshot` ordered by `version_number desc`.
- Every unhappy ai-service path (non-2xx, connection exception, malformed body) yields `suggestion: null` — the endpoint never errors the empty state.
- Tests run as named files only (DB isolation honored); never `tests/Feature` wholesale, never against dev postgres.
