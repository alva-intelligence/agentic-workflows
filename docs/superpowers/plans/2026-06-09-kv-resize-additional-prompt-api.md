# KV Resize Additional Prompt — API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users steer KV resize/regenerate with an optional free-text `additional_prompt`, persist it, forward it to ai-service, and log every resize/regenerate as a persistent system marker in the file's side chat.

**Architecture:** `store()`/`regenerate()` gain a nullable `additional_prompt` (max 1000, empty→null). It is stored on the `kv_resize_exports` row, forwarded inside `ProcessKvResizeExportJob`'s POST to `/ai/kv-resize/export`, and — for both New Resize (batch) and Regenerate — a system/`ai` marker row is written to `user_chat_history` keyed by the file's `thread_id`, carrying a `kind=resize_marker` + `payload` (platform ids + labels + prompt) so the existing KV chat panel rehydrates it on reload.

**Tech Stack:** Laravel 13, PHP 8.5, PostgreSQL, Pest

---

## Shared contract (must match web + ai-service)

- Request/JSON/DB field: `additional_prompt` — nullable string, max 1000. Empty/whitespace → stored as `null`.
- ai-service payload key: `additional_prompt`.
- New Resize marker text: `Resizing original KV to [<Label A>, <Label B>] with instructions: "<prompt>"`. Drop the ` with instructions: "<prompt>"` clause entirely when prompt is null. Labels are the human `label` from `config('studio.resize_platforms')` (id → label), in the order the platform ids were submitted.
- Regenerate marker text: `Regenerated <Label> with: "<prompt>"`; becomes just `Regenerated <Label>` when prompt is null.
- Marker is persisted to `user_chat_history` as a single row: `session_id = $file->thread_id`, `message = { type: 'ai', content: <text>, kind: 'resize_marker', payload: { action, platform_ids, platform_labels, additional_prompt, export_ids } }`. When `$file->thread_id` is null, the writer no-ops (no marker, no error).

### Discovered facts (do not re-derive)

- Message JSON shape (from `KvGeneratorFileController::show` ~L127-252): rows in `user_chat_history.message` carry `type` (`human`/`ai`), `content` (string), optional `kind`, optional `payload`. The web hook reads typed cards by branching on `kind` (`question_card`, `mode_suggestion`) and falls back to plain `text` otherwise. Each typed-card branch emits a flat `chat_history` entry of `{ id, role, text, kind, payload }` — `kind`/`payload` are emitted directly on the entry (snake_case keys), NOT nested under a `metadata` object. **The `show()` mapping for `kind: 'resize_marker'` is now covered by Task 7 of THIS plan (in scope).** Task 7 surfaces the row **flat** — `{ id, role:'assistant', text, kind:'resize_marker', payload }` — exactly like the sibling cards, with NO `metadata` object. The web plan's `useKvStream.hydrateInitialMessages` rebuilds `metadata.resizeMarker = { action, text, platformLabels, prompt }` from the flat `kind`+`payload` (camelCase object fields, consumed verbatim by the renderer via `m.metadata?.resizeMarker.{action,text,platformLabels,prompt}`).
- File→thread link: `studio_files.thread_id` (`StudioFile::$fillable` + `thread()` belongsTo `UserThread`). This is the chat `session_id`.
- `user_chat_history.session_id` is a FK to `user_threads.id` (cascade) — a marker row needs a real parent `UserThread`.
- Platform id→label registry: `config('studio.resize_platforms')` — array of `['id','label','group','width','height',...]`.
- `UserChatHistory`: `$timestamps = false`, `created_at` cast datetime, `message`/`files` cast array, `fillable` includes `session_id`, `message`, `files`.

### DB isolation (VERIFY BEFORE ANY FEATURE-STYLE TEST — project memory `lesson_test_db_isolation`)

`api/phpunit.xml` MUST set `DB_CONNECTION=sqlite` + `DB_DATABASE=:memory:` (currently does — lines in `<php>` block). `tests/Pest.php` applies `RefreshDatabase` to `Feature` only; Unit tests that need a DB opt in explicitly via `uses(TestCase::class, RefreshDatabase::class)` (see `tests/Unit/Services/Studio/KvResizeExportServiceTest.php`). **Never** run a test whose `phpunit.xml` points `DB_CONNECTION` at the dev postgres. Step 0 of each DB-touching task re-asserts this.

---

## Task 1 — Migration + model: `additional_prompt` column

**Files:**
- Create: `api/database/migrations/2026_06_09_000001_add_additional_prompt_to_kv_resize_exports_table.php`
- Modify: `api/app/Models/KvResizeExport.php` (add `'additional_prompt'` to `$fillable`, ~L19-33)
- Test: `api/tests/Unit/Models/KvResizeExportAdditionalPromptTest.php` (new)

Steps:

- [ ] 1. Verify DB isolation: open `api/phpunit.xml`, confirm `<env name="DB_CONNECTION" value="sqlite"/>` and `<env name="DB_DATABASE" value=":memory:"/>` are present and NOT commented. If they point at postgres, STOP and fix before continuing.
- [ ] 2. Write the failing test `api/tests/Unit/Models/KvResizeExportAdditionalPromptTest.php`:

```php
<?php

use App\Models\KvResizeExport;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

uses(TestCase::class, RefreshDatabase::class);

it('persists additional_prompt on a resize export row', function () {
    $export = KvResizeExport::factory()->create([
        'additional_prompt' => 'keep the text at the very bottom',
    ]);

    expect($export->fresh()->additional_prompt)
        ->toBe('keep the text at the very bottom');
});

it('defaults additional_prompt to null', function () {
    $export = KvResizeExport::factory()->create();

    expect($export->fresh()->additional_prompt)->toBeNull();
});
```

- [ ] 3. Run (expect FAIL — column/fillable missing):

```bash
./vendor/bin/pest tests/Unit/Models/KvResizeExportAdditionalPromptTest.php
```

- [ ] 4. Create the migration `api/database/migrations/2026_06_09_000001_add_additional_prompt_to_kv_resize_exports_table.php`:

```php
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('kv_resize_exports', function (Blueprint $table) {
            $table->string('additional_prompt', 1000)->nullable()->after('crop_window');
        });
    }

    public function down(): void
    {
        Schema::table('kv_resize_exports', function (Blueprint $table) {
            $table->dropColumn('additional_prompt');
        });
    }
};
```

- [ ] 5. Add `'additional_prompt'` to `$fillable` in `api/app/Models/KvResizeExport.php`, immediately after `'crop_window',`:

```php
        'crop_window',
        'additional_prompt',
        'overlays',
```

- [ ] 6. Run (expect PASS):

```bash
./vendor/bin/pest tests/Unit/Models/KvResizeExportAdditionalPromptTest.php
```

- [ ] 7. Commit: `feat(api): add additional_prompt column to kv_resize_exports`

---

## Task 2 — `store()` accepts + persists `additional_prompt` (via createBatch)

**Files:**
- Modify: `api/app/Services/Studio/KvResizeExportService.php` (`createBatch` signature + `firstOrCreate` attributes, ~L23-62)
- Modify: `api/app/Http/Controllers/Api/Studio/KvResizeExportController.php` (`store` validation + call, ~L50-77)
- Test: `api/tests/Unit/Services/Studio/KvResizeExportServiceTest.php` (extend existing)

Steps:

- [ ] 1. Verify DB isolation (as Task 1 step 1).
- [ ] 2. Add failing tests to `api/tests/Unit/Services/Studio/KvResizeExportServiceTest.php`:

```php
it('persists additional_prompt on each created row', function () {
    $rows = $this->service->createBatch(
        $this->file,
        $this->generation,
        ['instagram-post', 'tiktok-video'],
        cropWindowMap: [],
        userId: $this->user->id,
        additionalPrompt: 'make the background calmer',
    );

    expect($rows->pluck('additional_prompt')->all())
        ->each->toBe('make the background calmer');
});

it('stores null additional_prompt when none given', function () {
    $rows = $this->service->createBatch(
        $this->file,
        $this->generation,
        ['instagram-post'],
        cropWindowMap: [],
        userId: $this->user->id,
    );

    expect($rows->first()->additional_prompt)->toBeNull();
});
```

- [ ] 3. Run (expect FAIL — unknown named arg `additionalPrompt`):

```bash
./vendor/bin/pest tests/Unit/Services/Studio/KvResizeExportServiceTest.php
```

- [ ] 4. Update `createBatch` in `api/app/Services/Studio/KvResizeExportService.php` — add the param (default `null` to keep existing callers working) and store it:

```php
    public function createBatch(
        StudioFile $file,
        KvGeneration $parent,
        array $platformIds,
        array $cropWindowMap,
        string $userId,
        ?string $additionalPrompt = null,
    ): Collection {
```

and inside the `firstOrCreate` attributes array, after `'crop_window' => $cropWindowMap[$platformId] ?? null,`:

```php
                    'crop_window' => $cropWindowMap[$platformId] ?? null,
                    'additional_prompt' => $additionalPrompt,
```

- [ ] 5. Update `store()` in `api/app/Http/Controllers/Api/Studio/KvResizeExportController.php`. Add validation rule (after `'crop_windows' => 'nullable|array',`):

```php
            'crop_windows' => 'nullable|array',
            'additional_prompt' => 'nullable|string|max:1000',
```

Normalize empty/whitespace to null and pass into the service call:

```php
        $additionalPrompt = trim((string) ($validated['additional_prompt'] ?? '')) ?: null;

        $rows = $this->service->createBatch(
            file: $file,
            parent: $parent,
            platformIds: $validated['platform_ids'],
            cropWindowMap: $validated['crop_windows'] ?? [],
            userId: $request->user()->id,
            additionalPrompt: $additionalPrompt,
        );
```

- [ ] 6. Run (expect PASS):

```bash
./vendor/bin/pest tests/Unit/Services/Studio/KvResizeExportServiceTest.php
```

- [ ] 7. Commit: `feat(api): accept and persist additional_prompt on resize store`

---

## Task 3 — `regenerate()` accepts + persists `additional_prompt`

**Files:**
- Modify: `api/app/Services/Studio/KvResizeExportService.php` (`regenerate`, ~L64-76)
- Modify: `api/app/Http/Controllers/Api/Studio/KvResizeExportController.php` (`regenerate` validation + call, ~L92-100)
- Test: `api/tests/Unit/Services/Studio/KvResizeExportServiceTest.php` (extend)

Steps:

- [ ] 1. Verify DB isolation (as Task 1 step 1).
- [ ] 2. Add failing tests to `api/tests/Unit/Services/Studio/KvResizeExportServiceTest.php`:

```php
it('persists additional_prompt on regenerate', function () {
    $export = KvResizeExport::factory()->create([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $this->generation->id,
        'created_by' => $this->user->id,
        'platform_id' => 'instagram-post',
        'additional_prompt' => null,
    ]);

    $row = $this->service->regenerate($export, null, 'make it warmer');

    expect($row->additional_prompt)->toBe('make it warmer');
    expect($row->status)->toBe(KvResizeExportStatus::Pending);
});

it('clears additional_prompt to null on a plain regenerate', function () {
    $export = KvResizeExport::factory()->create([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $this->generation->id,
        'created_by' => $this->user->id,
        'platform_id' => 'instagram-post',
        'additional_prompt' => 'old instruction',
    ]);

    $row = $this->service->regenerate($export, null, null);

    expect($row->additional_prompt)->toBeNull();
});
```

- [ ] 3. Run (expect FAIL — `regenerate` takes 2 args):

```bash
./vendor/bin/pest tests/Unit/Services/Studio/KvResizeExportServiceTest.php
```

- [ ] 4. Update `regenerate` in `api/app/Services/Studio/KvResizeExportService.php`:

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

        ProcessKvResizeExportJob::dispatch($row->id);

        return $row->refresh();
    }
```

- [ ] 5. Update `regenerate()` in `api/app/Http/Controllers/Api/Studio/KvResizeExportController.php`. Add validation after the `crop_window.*` rules:

```php
            'crop_window.h' => 'required_with:crop_window|integer|min:1',
            'additional_prompt' => 'nullable|string|max:1000',
        ]);

        $additionalPrompt = trim((string) ($validated['additional_prompt'] ?? '')) ?: null;

        $row = $this->service->regenerate(
            $export,
            $validated['crop_window'] ?? null,
            $additionalPrompt,
        );
```

- [ ] 6. Run (expect PASS):

```bash
./vendor/bin/pest tests/Unit/Services/Studio/KvResizeExportServiceTest.php
```

- [ ] 7. Commit: `feat(api): accept and persist additional_prompt on resize regenerate`

---

## Task 4 — `ProcessKvResizeExportJob` forwards `additional_prompt` to ai-service

**Files:**
- Modify: `api/app/Jobs/Studio/ProcessKvResizeExportJob.php` (POST payload, ~L54-65)
- Test: `api/tests/Feature/Studio/ProcessKvResizeExportJobTest.php` (new — Feature for HTTP fake + factory DB)

Steps:

- [ ] 1. Verify DB isolation (as Task 1 step 1).
- [ ] 2. Write failing test `api/tests/Feature/Studio/ProcessKvResizeExportJobTest.php` (mirrors the `Http::fake` + `Http::recorded()` + `$request->data()[...]` pattern from `tests/Feature/Chat/BrandAssetFeedingTest.php`):

```php
<?php

use App\Jobs\Studio\ProcessKvResizeExportJob;
use App\Models\KvGeneration;
use App\Models\KvResizeExport;
use App\Models\StudioFile;
use App\Models\User;
use Illuminate\Support\Facades\Http;

beforeEach(function () {
    Http::fake([
        '*/ai/kv-resize/export' => Http::response(['status' => 'accepted'], 202),
    ]);

    $this->user = User::factory()->create();
    $this->file = StudioFile::factory()->create();
    $this->generation = KvGeneration::factory()->create([
        'studio_file_id' => $this->file->id,
        'version_number' => 1,
        'image_url' => 'https://example.com/source.png',
        'created_by' => $this->user->id,
    ]);
});

it('forwards additional_prompt in the ai-service payload', function () {
    $export = KvResizeExport::factory()->create([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $this->generation->id,
        'created_by' => $this->user->id,
        'platform_id' => 'instagram-post',
        'additional_prompt' => 'keep the text at the very bottom',
    ]);

    (new ProcessKvResizeExportJob($export->id))
        ->handle(app(\App\Services\Studio\KvResizeExportService::class));

    Http::assertSent(fn ($request) => str_contains((string) $request->url(), '/ai/kv-resize/export')
        && ($request->data()['additional_prompt'] ?? null) === 'keep the text at the very bottom');
});

it('forwards null additional_prompt when none set', function () {
    $export = KvResizeExport::factory()->create([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $this->generation->id,
        'created_by' => $this->user->id,
        'platform_id' => 'instagram-post',
        'additional_prompt' => null,
    ]);

    (new ProcessKvResizeExportJob($export->id))
        ->handle(app(\App\Services\Studio\KvResizeExportService::class));

    $recorded = collect(Http::recorded())
        ->first(fn ($pair) => str_contains((string) $pair[0]->url(), '/ai/kv-resize/export'));

    expect($recorded)->not->toBeNull();
    expect($recorded[0]->data())->toHaveKey('additional_prompt');
    expect($recorded[0]->data()['additional_prompt'])->toBeNull();
});
```

- [ ] 3. Run (expect FAIL — payload lacks `additional_prompt`):

```bash
./vendor/bin/pest tests/Feature/Studio/ProcessKvResizeExportJobTest.php
```

- [ ] 4. Add the key to the POST body in `api/app/Jobs/Studio/ProcessKvResizeExportJob.php`, inside the `->post("{$aiUrl}/ai/kv-resize/export", [ ... ])` array (after `'crop_window' => $row->crop_window,`):

```php
                'crop_window' => $row->crop_window,
                'additional_prompt' => $row->additional_prompt,
```

- [ ] 5. Run (expect PASS):

```bash
./vendor/bin/pest tests/Feature/Studio/ProcessKvResizeExportJobTest.php
```

- [ ] 6. Commit: `feat(api): forward additional_prompt to ai-service resize payload`

---

## Task 5 — Chat marker writer + New Resize (batch) marker

**Files:**
- Create: `api/app/Services/Studio/KvResizeChatMarkerService.php`
- Modify: `api/app/Http/Controllers/Api/Studio/KvResizeExportController.php` (`store` — call marker writer after batch, ~L77-82)
- Test: `api/tests/Unit/Services/Studio/KvResizeChatMarkerServiceTest.php` (new)

Marker writer design: a small service that resolves platform labels from `config('studio.resize_platforms')`, builds the marker text, and writes one `UserChatHistory` row keyed by `$file->thread_id`. No-ops when `thread_id` is null. Kept as a service (not inline in the controller) so it is Unit-testable without HTTP/auth and reused by both store and regenerate.

Steps:

- [ ] 1. Verify DB isolation (as Task 1 step 1).
- [ ] 2. Write failing test `api/tests/Unit/Services/Studio/KvResizeChatMarkerServiceTest.php`. It creates a real `UserThread` (FK target for `session_id`) via the model and a `StudioFile` pointing at it:

```php
<?php

use App\Models\StudioFile;
use App\Models\User;
use App\Models\UserChatHistory;
use App\Models\UserThread;
use App\Models\Workspace;
use App\Services\Studio\KvResizeChatMarkerService;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

uses(TestCase::class, RefreshDatabase::class);

beforeEach(function () {
    $this->service = app(KvResizeChatMarkerService::class);
    $this->user = User::factory()->create();
    $this->workspace = Workspace::factory()->create();
    $this->thread = UserThread::withoutGlobalScopes()->create([
        'user_id' => $this->user->id,
        'workspace_id' => $this->workspace->id,
        'title' => 'KV thread',
    ]);
    $this->file = StudioFile::factory()->create([
        'workspace_id' => $this->workspace->id,
        'thread_id' => $this->thread->id,
    ]);
});

it('writes a batch marker with platform labels and prompt', function () {
    $this->service->writeBatchMarker(
        $this->file,
        ['instagram-post', 'facebook-cover'],
        'keep the text at the very bottom',
        ['exp_1', 'exp_2'],
    );

    $row = UserChatHistory::where('session_id', $this->thread->id)->first();

    expect($row)->not->toBeNull();
    expect($row->message['type'])->toBe('ai');
    expect($row->message['kind'])->toBe('resize_marker');
    expect($row->message['content'])->toBe(
        'Resizing original KV to [Instagram Post, Facebook Cover] with instructions: "keep the text at the very bottom"'
    );
    expect($row->message['payload']['action'])->toBe('resize');
    expect($row->message['payload']['platform_ids'])->toBe(['instagram-post', 'facebook-cover']);
    expect($row->message['payload']['platform_labels'])->toBe(['Instagram Post', 'Facebook Cover']);
    expect($row->message['payload']['additional_prompt'])->toBe('keep the text at the very bottom');
    expect($row->message['payload']['export_ids'])->toBe(['exp_1', 'exp_2']);
});

it('drops the instructions clause when prompt is null', function () {
    $this->service->writeBatchMarker(
        $this->file,
        ['instagram-post', 'facebook-cover'],
        null,
        ['exp_1', 'exp_2'],
    );

    $row = UserChatHistory::where('session_id', $this->thread->id)->first();

    expect($row->message['content'])
        ->toBe('Resizing original KV to [Instagram Post, Facebook Cover]');
    expect($row->message['payload']['additional_prompt'])->toBeNull();
});

it('no-ops when the file has no thread', function () {
    $file = StudioFile::factory()->create([
        'workspace_id' => $this->workspace->id,
        'thread_id' => null,
    ]);

    $this->service->writeBatchMarker($file, ['instagram-post'], 'x', ['exp_1']);

    expect(UserChatHistory::count())->toBe(0);
});
```

- [ ] 3. Run (expect FAIL — class missing):

```bash
./vendor/bin/pest tests/Unit/Services/Studio/KvResizeChatMarkerServiceTest.php
```

- [ ] 4. Create `api/app/Services/Studio/KvResizeChatMarkerService.php`:

```php
<?php

namespace App\Services\Studio;

use App\Models\StudioFile;
use App\Models\UserChatHistory;
use Illuminate\Support\Collection;

class KvResizeChatMarkerService
{
    /**
     * New Resize (batch). Marker:
     *   Resizing original KV to [Label A, Label B] with instructions: "<prompt>"
     * The instructions clause is dropped when $additionalPrompt is null.
     *
     * @param  array<int, string>  $platformIds
     * @param  array<int, string>  $exportIds
     */
    public function writeBatchMarker(
        StudioFile $file,
        array $platformIds,
        ?string $additionalPrompt,
        array $exportIds,
    ): void {
        if (! $file->thread_id) {
            return;
        }

        $labels = $this->labelsFor($platformIds);
        $content = 'Resizing original KV to ['.implode(', ', $labels).']';
        if ($additionalPrompt !== null) {
            $content .= ' with instructions: "'.$additionalPrompt.'"';
        }

        $this->persist($file->thread_id, $content, [
            'action' => 'resize',
            'platform_ids' => array_values($platformIds),
            'platform_labels' => $labels,
            'additional_prompt' => $additionalPrompt,
            'export_ids' => array_values($exportIds),
        ]);
    }

    /**
     * Regenerate (single tile). Marker:
     *   Regenerated <Label> with: "<prompt>"
     * becomes just `Regenerated <Label>` when $additionalPrompt is null.
     */
    public function writeRegenerateMarker(
        StudioFile $file,
        string $platformId,
        ?string $additionalPrompt,
        string $exportId,
    ): void {
        if (! $file->thread_id) {
            return;
        }

        $label = $this->labelsFor([$platformId])[0] ?? $platformId;
        $content = 'Regenerated '.$label;
        if ($additionalPrompt !== null) {
            $content .= ' with: "'.$additionalPrompt.'"';
        }

        $this->persist($file->thread_id, $content, [
            'action' => 'regenerate',
            'platform_ids' => [$platformId],
            'platform_labels' => [$label],
            'additional_prompt' => $additionalPrompt,
            'export_ids' => [$exportId],
        ]);
    }

    /**
     * @param  array<int, string>  $platformIds
     * @return array<int, string>
     */
    private function labelsFor(array $platformIds): array
    {
        $registry = collect(config('studio.resize_platforms'))->keyBy('id');

        return collect($platformIds)
            ->map(fn (string $id) => $registry->get($id)['label'] ?? $id)
            ->values()
            ->all();
    }

    /**
     * @param  array<string, mixed>  $payload
     */
    private function persist(string $sessionId, string $content, array $payload): void
    {
        UserChatHistory::create([
            'session_id' => $sessionId,
            'message' => [
                'type' => 'ai',
                'content' => $content,
                'kind' => 'resize_marker',
                'payload' => $payload,
            ],
        ]);
    }
}
```

- [ ] 5. Run (expect PASS):

```bash
./vendor/bin/pest tests/Unit/Services/Studio/KvResizeChatMarkerServiceTest.php
```

- [ ] 6. Wire the batch marker into `store()` in `api/app/Http/Controllers/Api/Studio/KvResizeExportController.php`. Inject the marker service in the constructor:

```php
    public function __construct(
        private KvResizeExportService $service,
        private KvResizeChatMarkerService $markers,
    ) {}
```

(add `use App\Services\Studio\KvResizeChatMarkerService;` to the imports), then after `$rows = $this->service->createBatch(...)` and before the JSON response:

```php
        $this->markers->writeBatchMarker(
            $file,
            $validated['platform_ids'],
            $additionalPrompt,
            $rows->pluck('id')->all(),
        );
```

- [ ] 7. Run the full resize controller + marker + service suites (expect PASS):

```bash
./vendor/bin/pest tests/Unit/Services/Studio/KvResizeChatMarkerServiceTest.php tests/Unit/Services/Studio/KvResizeExportServiceTest.php
```

- [ ] 8. Commit: `feat(api): write batch resize chat marker to UserChatHistory`

---

## Task 6 — Regenerate marker

**Files:**
- Modify: `api/app/Http/Controllers/Api/Studio/KvResizeExportController.php` (`regenerate` — call marker writer, ~L100-105)
- Test: `api/tests/Unit/Services/Studio/KvResizeChatMarkerServiceTest.php` (extend)

Steps:

- [ ] 1. Verify DB isolation (as Task 1 step 1).
- [ ] 2. Add failing tests to `api/tests/Unit/Services/Studio/KvResizeChatMarkerServiceTest.php`:

```php
it('writes a regenerate marker with prompt', function () {
    $this->service->writeRegenerateMarker(
        $this->file,
        'instagram-post',
        'make the background calmer',
        'exp_9',
    );

    $row = UserChatHistory::where('session_id', $this->thread->id)->first();

    expect($row->message['content'])
        ->toBe('Regenerated Instagram Post with: "make the background calmer"');
    expect($row->message['kind'])->toBe('resize_marker');
    expect($row->message['payload']['action'])->toBe('regenerate');
    expect($row->message['payload']['platform_ids'])->toBe(['instagram-post']);
    expect($row->message['payload']['export_ids'])->toBe(['exp_9']);
});

it('writes a regenerate marker without prompt', function () {
    $this->service->writeRegenerateMarker($this->file, 'instagram-post', null, 'exp_9');

    $row = UserChatHistory::where('session_id', $this->thread->id)->first();

    expect($row->message['content'])->toBe('Regenerated Instagram Post');
    expect($row->message['payload']['additional_prompt'])->toBeNull();
});
```

- [ ] 3. Run (expect PASS for marker service — `writeRegenerateMarker` already implemented in Task 5):

```bash
./vendor/bin/pest tests/Unit/Services/Studio/KvResizeChatMarkerServiceTest.php
```

(If Task 5 only stubbed `writeRegenerateMarker`, implement it now so these pass.)

- [ ] 4. Wire the regenerate marker into `regenerate()` in `api/app/Http/Controllers/Api/Studio/KvResizeExportController.php`. After `$row = $this->service->regenerate(...)` and before the JSON response:

```php
        $this->markers->writeRegenerateMarker(
            $file,
            $export->platform_id,
            $additionalPrompt,
            $row->id,
        );
```

- [ ] 5. Run the marker suite again to confirm nothing regressed (expect PASS):

```bash
./vendor/bin/pest tests/Unit/Services/Studio/KvResizeChatMarkerServiceTest.php
```

- [ ] 6. Run the full new/changed test set as a final gate (expect PASS):

```bash
./vendor/bin/pest \
  tests/Unit/Models/KvResizeExportAdditionalPromptTest.php \
  tests/Unit/Services/Studio/KvResizeExportServiceTest.php \
  tests/Unit/Services/Studio/KvResizeChatMarkerServiceTest.php \
  tests/Feature/Studio/ProcessKvResizeExportJobTest.php
```

- [ ] 7. Commit: `feat(api): write regenerate chat marker to UserChatHistory`

---

## Task 7 — `show()` surfaces `resize_marker` rows (flat, like sibling cards)

Persisting the marker row (Tasks 5–6) is not enough: the web KV chat panel only renders it if `KvGeneratorFileController::show()` maps the `kind: 'resize_marker'` history row into the returned `chat_history` entry. The existing `question_card`/`mode_suggestion` branches (~L147-176) emit a **flat** entry `{ id, role, text, kind, payload }` — they do NOT build a `metadata` object; the web hydrator rebuilds metadata from the flat `kind`+`payload`. This task adds a sibling `resize_marker` branch that mirrors them **exactly**: flat `{ id, role:'assistant', text, kind, payload }`, nothing more.

**Locked contract — `show()` emits flat, web builds the metadata:**

`show()` surfaces the row as (identical mechanics to `question_card`/`mode_suggestion`):

```
{ id, role: 'assistant', text: <message.content>, kind: 'resize_marker', payload: { action, platform_ids, platform_labels, additional_prompt, export_ids } }
```

The web plan's `useKvStream.hydrateInitialMessages` then rebuilds — from this flat `kind`+`payload`, mirroring how it rebuilds `metadata.questionCard` — the object its renderer reads:

```
metadata.resizeMarker = {
  action:  <payload.action>,            // 'resize' | 'regenerate'
  text:    <text>,                      // server-authored marker copy
  platformLabels: <payload.platform_labels>,
  prompt:  <payload.additional_prompt>, // string | null
}
```

Do NOT emit a `metadata` object from `show()` — the hydrator would discard it (it constructs `ChatStreamMessage.metadata` fresh from the flat shape, exactly as it does for the sibling cards).

**Files:**
- Modify: `api/app/Http/Controllers/Api/Studio/KvGeneratorFileController.php` (`show()` chat-history mapper — add a `resize_marker` branch alongside the `question_card`/`mode_suggestion` branches, ~L161-176)
- Test: `api/tests/Feature/Studio/KvGeneratorFileShowResizeMarkerTest.php` (new — Feature for HTTP show endpoint; mirrors `tests/Feature/Studio/KvGeneratorFileShowOverlaysTest.php` auth/workspace bootstrapping, builds the `UserThread` + `UserChatHistory` row directly with no factory per the plan idiom)

Steps:

- [ ] 1. Verify DB isolation (as Task 1 step 1): open `api/phpunit.xml`, confirm `<env name="DB_CONNECTION" value="sqlite"/>` and `<env name="DB_DATABASE" value=":memory:"/>` are present and NOT commented. If they point at postgres, STOP and fix before continuing.
- [ ] 2. Write the failing test `api/tests/Feature/Studio/KvGeneratorFileShowResizeMarkerTest.php`. It bootstraps user/workspace/role exactly like `KvGeneratorFileShowOverlaysTest`, attaches a `UserThread` (FK target for `session_id`) created via `UserThread::withoutGlobalScopes()->create([...])` (mirrors Task 5), links the file via `thread_id`, and writes one `resize_marker` `UserChatHistory` row directly:

```php
<?php

use App\Models\Role;
use App\Models\StudioFile;
use App\Models\Tool;
use App\Models\User;
use App\Models\UserChatHistory;
use App\Models\UserThread;
use App\Models\Workspace;
use Illuminate\Support\Str;

test('GET kv-generator file show surfaces a resize_marker row as a flat chat_history entry', function () {
    $user = User::factory()->create();
    $workspace = Workspace::factory()->create(['type' => 'organization']);
    $user->update(['current_workspace_id' => $workspace->id]);
    $user->workspaces()->attach($workspace->id);

    $role = Role::factory()->create([
        'slug' => 'internal-'.Str::random(6),
        'type' => 'workspace',
        'scope' => 'internal',
    ]);
    $user->workspaceRoles()->attach($role->id, [
        'workspace_id' => $workspace->id,
    ]);

    $tool = Tool::factory()->create(['slug' => 'kv-generator']);

    $thread = UserThread::withoutGlobalScopes()->create([
        'user_id' => $user->id,
        'workspace_id' => $workspace->id,
        'title' => 'KV thread',
    ]);

    $file = StudioFile::factory()->create([
        'workspace_id' => $workspace->id,
        'tool_id' => $tool->id,
        'created_by' => $user->id,
        'last_edited_by' => $user->id,
        'thread_id' => $thread->id,
    ]);

    UserChatHistory::create([
        'session_id' => $thread->id,
        'message' => [
            'type' => 'ai',
            'content' => 'Resizing original KV to [Instagram Post, Facebook Cover] with instructions: "keep text low"',
            'kind' => 'resize_marker',
            'payload' => [
                'action' => 'resize',
                'platform_ids' => ['instagram-post', 'facebook-cover'],
                'platform_labels' => ['Instagram Post', 'Facebook Cover'],
                'additional_prompt' => 'keep text low',
                'export_ids' => ['exp_1', 'exp_2'],
            ],
        ],
    ]);

    $res = $this->actingAs($user, 'api')
        ->getJson("/api/v1/studio/kv-generator/files/{$file->id}");

    $res->assertOk();
    $res->assertJsonPath('data.chat_history.0.kind', 'resize_marker');
    $res->assertJsonPath('data.chat_history.0.role', 'assistant');
    $res->assertJsonPath(
        'data.chat_history.0.text',
        'Resizing original KV to [Instagram Post, Facebook Cover] with instructions: "keep text low"'
    );
    $res->assertJsonPath('data.chat_history.0.payload.action', 'resize');
    $res->assertJsonPath(
        'data.chat_history.0.payload.platform_labels',
        ['Instagram Post', 'Facebook Cover']
    );
    $res->assertJsonPath('data.chat_history.0.payload.additional_prompt', 'keep text low');
});

test('resize_marker surfaces a null prompt through to payload.additional_prompt', function () {
    $user = User::factory()->create();
    $workspace = Workspace::factory()->create(['type' => 'organization']);
    $user->update(['current_workspace_id' => $workspace->id]);
    $user->workspaces()->attach($workspace->id);

    $role = Role::factory()->create([
        'slug' => 'internal-'.Str::random(6),
        'type' => 'workspace',
        'scope' => 'internal',
    ]);
    $user->workspaceRoles()->attach($role->id, [
        'workspace_id' => $workspace->id,
    ]);

    $tool = Tool::factory()->create(['slug' => 'kv-generator']);

    $thread = UserThread::withoutGlobalScopes()->create([
        'user_id' => $user->id,
        'workspace_id' => $workspace->id,
        'title' => 'KV thread',
    ]);

    $file = StudioFile::factory()->create([
        'workspace_id' => $workspace->id,
        'tool_id' => $tool->id,
        'created_by' => $user->id,
        'last_edited_by' => $user->id,
        'thread_id' => $thread->id,
    ]);

    UserChatHistory::create([
        'session_id' => $thread->id,
        'message' => [
            'type' => 'ai',
            'content' => 'Regenerated Instagram Post',
            'kind' => 'resize_marker',
            'payload' => [
                'action' => 'regenerate',
                'platform_ids' => ['instagram-post'],
                'platform_labels' => ['Instagram Post'],
                'additional_prompt' => null,
                'export_ids' => ['exp_9'],
            ],
        ],
    ]);

    $res = $this->actingAs($user, 'api')
        ->getJson("/api/v1/studio/kv-generator/files/{$file->id}");

    $res->assertOk();
    $res->assertJsonPath('data.chat_history.0.kind', 'resize_marker');
    $res->assertJsonPath('data.chat_history.0.payload.action', 'regenerate');
    $res->assertJsonPath('data.chat_history.0.text', 'Regenerated Instagram Post');
    $res->assertJsonPath('data.chat_history.0.payload.platform_labels', ['Instagram Post']);
    $res->assertJsonPath('data.chat_history.0.payload.additional_prompt', null);
});
```

- [ ] 3. Run (expect FAIL — `show()` has no `resize_marker` branch, so the marker row falls through to the plain-text mapper and the entry has no `kind: 'resize_marker'` / `payload`):

```bash
./vendor/bin/pest tests/Feature/Studio/KvGeneratorFileShowResizeMarkerTest.php
```

- [ ] 4. Add the `resize_marker` branch in `show()` in `api/app/Http/Controllers/Api/Studio/KvGeneratorFileController.php`, immediately after the `mode_suggestion` branch (after its `continue;`, ~L176). It mirrors the surrounding branch mechanics **exactly** — flat `{ id, role:'assistant', text, kind, payload }`, no `metadata` object (the web hydrator rebuilds `metadata.resizeMarker` from this flat shape):

```php
                if ($role === 'assistant' && $kind === 'resize_marker' && is_array($payload)) {
                    $chatHistory[] = [
                        'id' => (string) $m->id,
                        'role' => 'assistant',
                        'text' => $content,
                        'kind' => 'resize_marker',
                        'payload' => $payload,
                    ];

                    continue;
                }
```

- [ ] 5. Run (expect PASS):

```bash
./vendor/bin/pest tests/Feature/Studio/KvGeneratorFileShowResizeMarkerTest.php
```

- [ ] 6. Commit: `feat(api): map resize_marker chat rows to resizeMarker metadata in show()`

---

## Notes for the implementer

- **Existing callers of `createBatch`/`regenerate`:** the new params default to `null`, so existing tests (`KvResizeExportServiceTest`, `KvResizeExportControllerTest`) keep passing without edits.
- **`store()` `$additionalPrompt` variable** is defined in Task 2 and reused by the Task 5 marker call — keep it in scope.
- **Feature suite caution (project memory `lesson_api_feature_suite_blocked_softdeletes`):** the broad `Feature` suite can fail on fresh migrate due to the workspaces backfill + SoftDeletes. Run ONLY the specific test files listed above, never the whole `tests/Feature` directory, and never against the dev postgres DB.
- **No `UserThread`/`UserChatHistory` factory exists** — the marker tests create the thread via `UserThread::withoutGlobalScopes()->create([...])` (mirrors `ThreadSnapshotService::forkSnapshot`). Do not introduce a factory just for this.
- **Web sync:** the persisted marker uses `kind: 'resize_marker'`; the `KvGeneratorFileController::show()` chat-history mapper (~L140-176) adds a `resize_marker` branch (Task 7) that surfaces the row **flat** — `{ id, role:'assistant', text, kind:'resize_marker', payload }` — exactly like the existing `question_card`/`mode_suggestion` cards. It does NOT build a `metadata` object: the web plan's `useKvStream.hydrateInitialMessages` rebuilds `metadata.resizeMarker = { action, text, platformLabels, prompt }` from the flat `kind`+`payload`, mirroring how it rebuilds `metadata.questionCard`. This plan guarantees both the persisted row AND its flat surfacing through `show()`.
