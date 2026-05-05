# KV Chat Attachment + Selection History — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist both kinds of per-turn user input (paperclip image attachments + canvas bounding-box selections) on each KV chat message and render them in the user-message bubble — attachments as a thumbnail strip, selections as a mini annotated thumbnail of the base generation. Same-session optimistic + post-refresh hydrated must look identical.

**Architecture:** Reuse `UserChatHistory.files` (existing JSONB column) for attachments. Extend the existing `message` JSONB blob with `selections` + `base_generation_id` for bounding boxes — no new column, no migration. Add a new `POST /v1/studio/chat-attachments` upload endpoint that returns S3-backed URL refs; the KV web stream POST sends those refs (replacing today's transient base64). The api persists both attachments and selections on the message row, the file-show endpoint hydrates both into `chat_history`, and the web bubble renders a selection tile (from existing `generations[]`) and an attachment tile strip above the text. Ship api → ai-service verification → web in that order so the wire shape is set first.

**Tech Stack:** Web — Next.js 15, React 19, TypeScript, Konva. API — Laravel 13, PHP 8.5, PostgreSQL JSON, ULID, Pest/PHPUnit, Sanctum. AI service — Python (FastAPI + Agno), `chat_agent/service.py`.

**Spec reference:** [docs/superpowers/specs/2026-05-05-kv-chat-attachment-history-design.md](docs/superpowers/specs/2026-05-05-kv-chat-attachment-history-design.md)

**Service ordering:** API first (uploads + attachment persistence + selection persistence + hydration), AI service verification second (no-op if already wired), web third (consumes the new upload endpoint and the new history shape).

---

## File Structure

**API — `frndos/api` on `feature/daffa/vc-studio-projects-kv-generator` (or rebase target if branch advanced):**
- Create: `app/Http/Controllers/Api/Studio/StudioChatAttachmentController.php`
- Create: `app/Http/Requests/Studio/UploadStudioChatAttachmentRequest.php`
- Modify: `app/Http/Controllers/Api/Chat/ThreadController.php` (`store`, `update` — accept `attachments` JSON refs and append to `$messageData['files']`)
- Modify: `app/Http/Controllers/Api/Studio/KvGeneratorFileController.php` (`show` — include `attachments` on user `chat_history` entries)
- Modify: `app/Http/Requests/StreamChatRequest.php` (declare new optional `attachments` array rule)
- Modify: `routes/api.php` (register `POST studio/chat-attachments`)
- Create: `tests/Feature/Studio/UploadStudioChatAttachmentTest.php`
- Create: `tests/Feature/Studio/KvChatAttachmentPersistenceTest.php`
- Create: `tests/Feature/Studio/KvGeneratorFileShowAttachmentsTest.php`

**AI service — `frndos/ai-service` (verification + tiny adaptor only if needed):**
- Inspect: `app/agents/chat_agent/service.py::process_message_with_files`
- Inspect: KV stream entry point (search for the `/threads/{id}/stream` consumer)
- Modify (only if discovery shows attachments aren't reaching the agent): wherever the KV path builds the agent call from the api stream payload — add the same `attachments → message` injection askFrnd uses

**Web — `frndos/web` on `develop`:**
- Modify: `src/types/studio.ts` (extend `KvAttachment`; add `KvHistoryAttachment` and `KvHistorySelections`)
- Modify: `src/hooks/useKvStream.ts` (new send shape, optimistic-message attachments + selections, hydrate both from history)
- Modify: `src/components/studio/kv-generator/KvGeneratorLayout.tsx` (add upload helper; pass selection snapshot to send)
- Modify: `src/components/studio/kv-generator/KvChat.tsx` (upload-first send flow, render attachment strip + selection tile on user bubble)
- Create: `src/components/studio/kv-generator/SelectionPreviewTile.tsx` (inline bbox-overlay tile)
- Tests: declare-const-style typecheck tests for the send-shape helper + selection-tile geometry; Playwright e2e at `tests/e2e/studio-kv-chat-attachments.spec.ts`

---

## Phase 1 — API

### Task 1: Discovery — confirm current KV attachment fate

**Files:**
- Read-only: `app/Http/Controllers/Api/Chat/ThreadController.php`, `app/Http/Requests/StreamChatRequest.php`, `app/Services/ChatService.php`

- [ ] **Step 1: Trace what `ThreadController::update` does with the `attachments` JSON field today**

Run from `frndos/api`:
```bash
git grep -nE "attachments|data_base64" app/Http/Controllers/Api/Chat/ app/Http/Requests/ app/Services/Chat
```

Document in the PR description: (a) is the JSON `attachments` field validated/used, or silently dropped? (b) does it reach the AI service today (so the agent can "see" the image), or has the KV path been image-blind since launch?

- [ ] **Step 2: Decide ship order based on discovery**

If KV attachments are silently dropped (most likely): ship the api change with no behavior loss for existing users — they were never seeing them in history anyway, AI was never "seeing" them.
If KV already forwards base64 to AI: keep base64 forwarding in place during the rollout (api fetches the URL → re-encodes → continues to call the agent the same way), so AI behavior doesn't regress while the wire shape changes.

Write the conclusion as a 3-line note in the PR — it informs Phase 2 (ai-service).

- [ ] **Step 3: Commit the discovery doc**

```bash
git add docs/  # or attach to PR description; no code commit yet
```

---

### Task 2: Migration — none

**Files:** none

- [ ] **Step 1: Confirm `UserChatHistory.files` exists and is cast `array`**

Run:
```bash
git grep -nA 1 "'files'" app/Models/UserChatHistory.php
```

Expected output includes `'files',` in `$fillable` and `'files' => 'array'` (implicit via `'array'` cast pattern; check with the file's `casts()` method too).

If both present, no migration needed and proceed.

- [ ] **Step 2: Note in PR description: "no DB migration"**

---

### Task 3: FormRequest for upload validation

**Files:**
- Create: `app/Http/Requests/Studio/UploadStudioChatAttachmentRequest.php`
- Test: `tests/Feature/Studio/UploadStudioChatAttachmentTest.php`

- [ ] **Step 1: Write the failing test**

```php
<?php

namespace Tests\Feature\Studio;

use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Storage;
use Tests\TestCase;

class UploadStudioChatAttachmentTest extends TestCase
{
    use RefreshDatabase;

    public function test_rejects_non_image_mime(): void
    {
        Storage::fake('s3');
        $user = User::factory()->create();

        $resp = $this->actingAs($user)->postJson('/api/v1/studio/chat-attachments', [
            'files' => [UploadedFile::fake()->create('doc.pdf', 100, 'application/pdf')],
        ]);

        $resp->assertStatus(422)->assertJsonValidationErrors(['files.0']);
    }

    public function test_rejects_oversize(): void
    {
        Storage::fake('s3');
        $user = User::factory()->create();

        $resp = $this->actingAs($user)->postJson('/api/v1/studio/chat-attachments', [
            'files' => [UploadedFile::fake()->image('big.png')->size(11 * 1024)], // 11 MB
        ]);

        $resp->assertStatus(422)->assertJsonValidationErrors(['files.0']);
    }

    public function test_rejects_too_many_files(): void
    {
        Storage::fake('s3');
        $user = User::factory()->create();

        $files = collect(range(1, 5))
            ->map(fn ($i) => UploadedFile::fake()->image("img-{$i}.png"))
            ->all();

        $resp = $this->actingAs($user)->postJson('/api/v1/studio/chat-attachments', [
            'files' => $files,
        ]);

        $resp->assertStatus(422)->assertJsonValidationErrors(['files']);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd frndos/api && php artisan test tests/Feature/Studio/UploadStudioChatAttachmentTest.php
```

Expected: FAIL — route does not exist yet.

- [ ] **Step 3: Write the FormRequest**

```php
<?php

namespace App\Http\Requests\Studio;

use Illuminate\Foundation\Http\FormRequest;

class UploadStudioChatAttachmentRequest extends FormRequest
{
    public function authorize(): bool
    {
        return $this->user() !== null && $this->user()->current_workspace_id !== null;
    }

    public function rules(): array
    {
        return [
            'files'   => ['required', 'array', 'min:1', 'max:4'],
            'files.*' => [
                'required',
                'file',
                'mimes:png,jpg,jpeg,webp',
                'mimetypes:image/png,image/jpeg,image/webp',
                'max:10240', // KB → 10 MB
            ],
        ];
    }
}
```

- [ ] **Step 4: Commit (controller wiring follows in next task)**

```bash
git add app/Http/Requests/Studio/UploadStudioChatAttachmentRequest.php tests/Feature/Studio/UploadStudioChatAttachmentTest.php
git commit -m "feat(api): add upload validation for studio chat attachments"
```

---

### Task 4: Upload controller

**Files:**
- Create: `app/Http/Controllers/Api/Studio/StudioChatAttachmentController.php`
- Modify: `routes/api.php` (inside the `prefix('studio')` group)
- Test: extend `tests/Feature/Studio/UploadStudioChatAttachmentTest.php` with the success path

- [ ] **Step 1: Add the success-path failing test**

Append to `UploadStudioChatAttachmentTest.php`:

```php
    public function test_uploads_returns_persisted_descriptors(): void
    {
        Storage::fake('s3');
        $user = User::factory()->create();

        $resp = $this->actingAs($user)->postJson('/api/v1/studio/chat-attachments', [
            'files' => [
                UploadedFile::fake()->image('moodboard.png', 800, 600),
                UploadedFile::fake()->image('reference.jpg', 1024, 768),
            ],
        ]);

        $resp->assertStatus(200)
            ->assertJsonCount(2, 'data')
            ->assertJsonStructure([
                'data' => [
                    '*' => ['id', 'name', 'mime_type', 'size', 'url'],
                ],
            ]);

        $first = $resp->json('data.0');
        $this->assertSame('moodboard.png', $first['name']);
        $this->assertSame('image/png', $first['mime_type']);
        $this->assertStringStartsWith('att_', $first['id']);
        Storage::disk('s3')->assertExists("studio/chat-attachments/{$first['id']}/moodboard.png");
    }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
php artisan test tests/Feature/Studio/UploadStudioChatAttachmentTest.php::test_uploads_returns_persisted_descriptors
```

Expected: FAIL — 404, route missing.

- [ ] **Step 3: Implement controller**

```php
<?php

namespace App\Http\Controllers\Api\Studio;

use App\Http\Controllers\Controller;
use App\Http\Requests\Studio\UploadStudioChatAttachmentRequest;
use Illuminate\Http\JsonResponse;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;

class StudioChatAttachmentController extends Controller
{
    public function store(UploadStudioChatAttachmentRequest $request): JsonResponse
    {
        $out = [];
        foreach ($request->file('files') as $file) {
            $id = 'att_' . (string) Str::ulid();
            $name = $file->getClientOriginalName();
            $path = "studio/chat-attachments/{$id}/{$name}";
            Storage::disk('s3')->put($path, file_get_contents($file->getRealPath()), 'public');
            $out[] = [
                'id'        => $id,
                'name'      => $name,
                'mime_type' => $file->getMimeType(),
                'size'      => $file->getSize(),
                'url'       => Storage::disk('s3')->url($path),
            ];
        }

        return response()->json(['data' => $out]);
    }
}
```

- [ ] **Step 4: Register the route**

In `routes/api.php`, inside `Route::prefix('studio')->group(function () { ... })`, add:

```php
Route::post('chat-attachments', [
    \App\Http\Controllers\Api\Studio\StudioChatAttachmentController::class,
    'store',
])->middleware(['permissions:chat.write']);
```

- [ ] **Step 5: Run all upload tests to verify they pass**

```bash
php artisan test tests/Feature/Studio/UploadStudioChatAttachmentTest.php
```

Expected: PASS (all 4 cases).

- [ ] **Step 6: Commit**

```bash
git add app/Http/Controllers/Api/Studio/StudioChatAttachmentController.php routes/api.php tests/Feature/Studio/UploadStudioChatAttachmentTest.php
git commit -m "feat(api): add upload endpoint for studio chat attachments"
```

---

### Task 5: Persist attachments AND selections on KV stream POST

**Files:**
- Modify: `app/Http/Requests/StreamChatRequest.php` (declare optional `attachments` + `bounding_boxes` + `base_generation_id` arrays)
- Modify: `app/Http/Controllers/Api/Chat/ThreadController.php` (`store` and `update`)
- Test: `tests/Feature/Studio/KvChatAttachmentPersistenceTest.php`
- Test: `tests/Feature/Studio/KvChatSelectionPersistenceTest.php`

- [ ] **Step 1: Write the failing persistence test**

```php
<?php

namespace Tests\Feature\Studio;

use App\Models\StudioFile;
use App\Models\User;
use App\Models\UserChatHistory;
use App\Models\UserThread;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class KvChatAttachmentPersistenceTest extends TestCase
{
    use RefreshDatabase;

    public function test_stream_post_persists_attachment_refs_on_user_message(): void
    {
        $user = User::factory()->create();
        $thread = UserThread::factory()->for($user)->create();

        // Avoid hitting the real AI service by mocking the chat service or
        // pointing it at a fake. The pattern in the existing askFrnd tests
        // (search for `ChatService::class` mock) is the reference.

        $resp = $this->actingAs($user)->postJson("/api/v1/threads/{$thread->id}/stream", [
            'message' => 'make me another version',
            'mode' => 'image',
            'attachments' => [
                [
                    'id' => 'att_01HXYZ',
                    'name' => 'moodboard.png',
                    'mime_type' => 'image/png',
                    'size' => 1234,
                    'url' => 'https://cdn.frnd.com/studio/chat-attachments/01HXYZ/moodboard.png',
                ],
            ],
        ]);

        $resp->assertOk();

        $msg = UserChatHistory::where('session_id', $thread->id)
            ->whereJsonContains('message->type', 'human')
            ->latest('id')
            ->first();

        $this->assertNotNull($msg);
        $this->assertCount(1, $msg->files);
        $this->assertSame('att_01HXYZ', $msg->files[0]['id']);
        $this->assertSame('moodboard.png', $msg->files[0]['name']);
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
php artisan test tests/Feature/Studio/KvChatAttachmentPersistenceTest.php
```

Expected: FAIL — `$msg->files` is null/empty because the controller drops the field today.

- [ ] **Step 3: Add validation rules for `attachments` AND `bounding_boxes` + `base_generation_id`**

In `app/Http/Requests/StreamChatRequest.php` (find the existing `rules()`), add:

```php
'attachments'                => ['sometimes', 'array', 'max:4'],
'attachments.*.id'           => ['required_with:attachments', 'string', 'max:64'],
'attachments.*.name'         => ['required_with:attachments', 'string', 'max:255'],
'attachments.*.mime_type'    => ['required_with:attachments', 'string', 'in:image/png,image/jpeg,image/webp'],
'attachments.*.size'         => ['required_with:attachments', 'integer', 'min:1', 'max:' . (10 * 1024 * 1024)],
'attachments.*.url'          => ['required_with:attachments', 'url'],

// Selections — already accepted by the controller for AI forwarding;
// adding rules here just locks them down + lets us persist confidently.
'bounding_boxes'             => ['sometimes', 'array', 'max:32'],
'bounding_boxes.*.id'        => ['required_with:bounding_boxes', 'string', 'max:64'],
'bounding_boxes.*.x'         => ['required_with:bounding_boxes', 'numeric', 'between:0,1'],
'bounding_boxes.*.y'         => ['required_with:bounding_boxes', 'numeric', 'between:0,1'],
'bounding_boxes.*.width'     => ['required_with:bounding_boxes', 'numeric', 'between:0,1'],
'bounding_boxes.*.height'    => ['required_with:bounding_boxes', 'numeric', 'between:0,1'],
'bounding_boxes.*.prompt'    => ['nullable', 'string', 'max:1000'],
'base_generation_id'         => ['sometimes', 'string', 'max:64'],
```

(URL host-allowlisting can be added later as a custom rule if abuse appears.)

- [ ] **Step 4: Persist refs onto `$messageData` in `store` and `update`**

In `ThreadController::store` (around the `$messageData = [...]` block, currently line ~172-178):

```php
$selections = $streamRequest->validated('bounding_boxes', []);
$baseGenId  = $streamRequest->validated('base_generation_id');

$message = [
    'content' => $userQuery,
    'type'    => ChatMessageType::USER,
];
if (!empty($selections)) {
    $message['selections'] = $selections;
}
if (!empty($baseGenId)) {
    $message['base_generation_id'] = $baseGenId;
}

$messageData = [
    'message' => $message,
    'files'   => array_merge(
        $categorizedFiles->getAllFiles(),
        $streamRequest->validated('attachments', [])
    ),
];
```

Apply the same shape change in `ThreadController::update` (around line 305-311).

- [ ] **Step 5: Run test to verify it passes**

```bash
php artisan test tests/Feature/Studio/KvChatAttachmentPersistenceTest.php
```

Expected: PASS.

- [ ] **Step 6: Run the full askFrnd thread test suite to confirm no regression**

```bash
php artisan test tests/Feature/Chat
```

Expected: PASS — askFrnd path is untouched (uses multipart, not the JSON `attachments` field).

- [ ] **Step 7: Add the failing selection-persistence test**

```php
<?php

namespace Tests\Feature\Studio;

use App\Models\User;
use App\Models\UserChatHistory;
use App\Models\UserThread;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class KvChatSelectionPersistenceTest extends TestCase
{
    use RefreshDatabase;

    public function test_stream_post_persists_bounding_boxes_into_message_blob(): void
    {
        $user = User::factory()->create();
        $thread = UserThread::factory()->for($user)->create();

        $resp = $this->actingAs($user)->postJson("/api/v1/threads/{$thread->id}/stream", [
            'message' => 'make this region younger',
            'mode' => 'edit',
            'bounding_boxes' => [
                ['id' => 'b_AAA', 'x' => 0.31, 'y' => 0.42, 'width' => 0.18, 'height' => 0.22, 'prompt' => 'younger face'],
            ],
            'base_generation_id' => 'g_BBB',
        ]);

        $resp->assertOk();

        $msg = UserChatHistory::where('session_id', $thread->id)
            ->whereJsonContains('message->type', 'human')
            ->latest('id')->first();

        $this->assertNotNull($msg);
        $this->assertCount(1, $msg->message['selections']);
        $this->assertSame('b_AAA', $msg->message['selections'][0]['id']);
        $this->assertSame('g_BBB', $msg->message['base_generation_id']);
    }

    public function test_stream_post_omits_selection_keys_when_no_boxes(): void
    {
        $user = User::factory()->create();
        $thread = UserThread::factory()->for($user)->create();

        $resp = $this->actingAs($user)->postJson("/api/v1/threads/{$thread->id}/stream", [
            'message' => 'just chatting',
            'mode' => 'chat',
        ]);

        $resp->assertOk();

        $msg = UserChatHistory::where('session_id', $thread->id)->latest('id')->first();
        $this->assertArrayNotHasKey('selections', $msg->message);
        $this->assertArrayNotHasKey('base_generation_id', $msg->message);
    }
}
```

- [ ] **Step 8: Run + commit**

```bash
php artisan test tests/Feature/Studio/KvChatSelectionPersistenceTest.php
git add app/Http/Requests/StreamChatRequest.php app/Http/Controllers/Api/Chat/ThreadController.php tests/Feature/Studio/KvChatAttachmentPersistenceTest.php tests/Feature/Studio/KvChatSelectionPersistenceTest.php
git commit -m "feat(api): persist KV chat attachments + bbox selections on message"
```

---

### Task 6: Hydrate attachments AND selections in `KvGeneratorFileController::show`

**Files:**
- Modify: `app/Http/Controllers/Api/Studio/KvGeneratorFileController.php` (`show`)
- Test: `tests/Feature/Studio/KvGeneratorFileShowAttachmentsTest.php`

- [ ] **Step 1: Write the failing test**

```php
<?php

namespace Tests\Feature\Studio;

use App\Enums\ChatMessageType;
use App\Models\StudioFile;
use App\Models\User;
use App\Models\UserChatHistory;
use App\Models\UserThread;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class KvGeneratorFileShowAttachmentsTest extends TestCase
{
    use RefreshDatabase;

    public function test_show_includes_attachments_on_user_messages(): void
    {
        $user = User::factory()->create();
        $thread = UserThread::factory()->for($user)->create();
        $file = StudioFile::factory()->create([
            'workspace_id' => $user->current_workspace_id,
            'thread_id' => $thread->id,
        ]);

        UserChatHistory::create([
            'session_id' => $thread->id,
            'message' => ['content' => 'with this image', 'type' => ChatMessageType::USER->value],
            'files' => [[
                'id' => 'att_AAA', 'name' => 'a.png', 'mime_type' => 'image/png',
                'size' => 100, 'url' => 'https://cdn.frnd.com/x/a.png',
            ]],
        ]);

        $resp = $this->actingAs($user)->getJson("/api/v1/studio/kv-generator/files/{$file->id}");

        $resp->assertOk();
        $entry = collect($resp->json('data.chat_history'))
            ->firstWhere('role', 'user');

        $this->assertNotNull($entry);
        $this->assertSame('with this image', $entry['text']);
        $this->assertCount(1, $entry['attachments']);
        $this->assertSame('att_AAA', $entry['attachments'][0]['id']);
        $this->assertSame('https://cdn.frnd.com/x/a.png', $entry['attachments'][0]['url']);
    }

    public function test_show_omits_attachments_when_none(): void
    {
        $user = User::factory()->create();
        $thread = UserThread::factory()->for($user)->create();
        $file = StudioFile::factory()->create([
            'workspace_id' => $user->current_workspace_id,
            'thread_id' => $thread->id,
        ]);

        UserChatHistory::create([
            'session_id' => $thread->id,
            'message' => ['content' => 'no image', 'type' => ChatMessageType::USER->value],
        ]);

        $resp = $this->actingAs($user)->getJson("/api/v1/studio/kv-generator/files/{$file->id}");

        $entry = collect($resp->json('data.chat_history'))
            ->firstWhere('role', 'user');

        $this->assertSame([], $entry['attachments'] ?? []);
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
php artisan test tests/Feature/Studio/KvGeneratorFileShowAttachmentsTest.php
```

Expected: FAIL — no `attachments` key on the entry.

- [ ] **Step 3: Add `attachments` AND `selections` to the user-row build in `show`**

In `KvGeneratorFileController::show`, find the block that builds the user/assistant entry (currently the `$chatHistory[] = [...]` near line 153). For the user role, include:

```php
$attachments = [];
$selections = null;
if ($role === 'user') {
    if (is_array($m->files)) {
        $attachments = array_values(array_filter(
            $m->files,
            fn ($f) => is_array($f) && isset($f['id'], $f['url'], $f['name']),
        ));
    }
    $rawSelections = $msg['selections'] ?? null;
    $baseGenId     = $msg['base_generation_id'] ?? null;
    if (is_array($rawSelections) && !empty($rawSelections) && is_string($baseGenId)) {
        $selections = [
            'base_generation_id' => $baseGenId,
            'boxes' => array_values(array_filter(
                $rawSelections,
                fn ($b) => is_array($b)
                    && isset($b['id'], $b['x'], $b['y'], $b['width'], $b['height']),
            )),
        ];
    }
}

$chatHistory[] = [
    'id' => (string) $m->id,
    'role' => $role,
    'text' => $content,
    'tools' => $tools,            // existing
    'attachments' => $attachments, // new — empty array when none
    'selections' => $selections,   // new — null when none
];
```

Also extend the existing `KvGeneratorFileShowAttachmentsTest` with a selection-hydration test:

```php
public function test_show_includes_selections_on_user_messages(): void
{
    $user = User::factory()->create();
    $thread = UserThread::factory()->for($user)->create();
    $file = StudioFile::factory()->create([
        'workspace_id' => $user->current_workspace_id,
        'thread_id' => $thread->id,
    ]);

    UserChatHistory::create([
        'session_id' => $thread->id,
        'message' => [
            'content' => 'edit this region',
            'type' => ChatMessageType::USER->value,
            'selections' => [
                ['id' => 'b_X', 'x' => 0.1, 'y' => 0.2, 'width' => 0.3, 'height' => 0.4, 'prompt' => 'rounder'],
            ],
            'base_generation_id' => 'g_Y',
        ],
    ]);

    $resp = $this->actingAs($user)->getJson("/api/v1/studio/kv-generator/files/{$file->id}");

    $entry = collect($resp->json('data.chat_history'))->firstWhere('role', 'user');
    $this->assertSame('g_Y', $entry['selections']['base_generation_id']);
    $this->assertCount(1, $entry['selections']['boxes']);
    $this->assertSame('b_X', $entry['selections']['boxes'][0]['id']);
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
php artisan test tests/Feature/Studio/KvGeneratorFileShowAttachmentsTest.php
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/Http/Controllers/Api/Studio/KvGeneratorFileController.php tests/Feature/Studio/KvGeneratorFileShowAttachmentsTest.php
git commit -m "feat(api): hydrate KV chat attachments in file-show response"
```

---

### Task 7: Open the api PR

- [ ] **Step 1: Push and open PR**

```bash
git push -u origin feature/<your-branch>
gh pr create --title "feat(api): persisted KV chat attachment history" --body-file <(cat <<'EOF'
## Summary
- New POST /v1/studio/chat-attachments upload endpoint
- KV stream POST now persists `attachments` JSON refs onto `user_chat_history.files`
- KV file-show response includes `attachments` on user history entries

## Test plan
- [ ] tests/Feature/Studio/UploadStudioChatAttachmentTest.php passes
- [ ] tests/Feature/Studio/KvChatAttachmentPersistenceTest.php passes
- [ ] tests/Feature/Studio/KvGeneratorFileShowAttachmentsTest.php passes
- [ ] tests/Feature/Chat (askFrnd) suite passes — no regression
- [ ] Manual: upload via the new endpoint returns 200 with descriptors; rows land in S3
EOF
)
```

---

## Phase 2 — AI service

### Task 8: Verify the KV agent already sees image attachments

**Files:**
- Read-only: `app/agents/chat_agent/service.py`, KV stream entrypoint (search the codebase)

- [ ] **Step 1: Locate KV's path into `chat_agent`**

```bash
cd frndos/ai-service
grep -rnE "studio|kv|images|attachments" app/agents/chat_agent/ app/api/ 2>/dev/null
```

Identify whether the KV chat invocation passes through `process_message_with_files` or a sibling helper that already accepts `images`/`attachments`.

- [ ] **Step 2: Decide whether changes are needed**

Three outcomes:
- (a) KV path already piggybacks on the askFrnd image flow → only add a smoke test (Task 9).
- (b) KV path does not forward images at all today → add the smallest possible adapter at the KV entrypoint (Task 10).
- (c) KV path forwards base64 today, and we need to switch to URL-fetch → add a tiny `httpx` fetch + base64 inline encode (Task 10 variant).

Document the choice in the PR.

---

### Task 9: Smoke test (only if Task 8 outcome is (a))

**Files:**
- Create: `app/agents/chat_agent/tests/test_kv_attachments_smoke.py` (or follow existing test layout)

- [ ] **Step 1: Write the smoke test**

```python
import pytest
from app.agents.chat_agent.service import process_message_with_files


@pytest.mark.asyncio
async def test_kv_attachment_url_reaches_agent(monkeypatch):
    """The KV stream payload's `attachments[].url` should land in the
    agent's vision-input list, not be silently dropped. This guards
    against future refactors of the api->agent bridge."""
    captured = {}

    async def fake_runner(*args, **kwargs):
        captured["images"] = kwargs.get("images") or []
        return ""

    monkeypatch.setattr(
        "app.agents.chat_agent.service.run_agent_with_messages",
        fake_runner,
    )

    await process_message_with_files(
        message="describe this",
        images=[{"url": "https://cdn.frnd.com/x/a.png"}],
    )

    assert any(i.get("url") == "https://cdn.frnd.com/x/a.png" for i in captured["images"])
```

(Adapt names to whatever the actual function signature is — the point is to assert the URL doesn't get dropped on the way to the agent.)

- [ ] **Step 2: Run + commit**

```bash
pytest app/agents/chat_agent/tests/test_kv_attachments_smoke.py -v
git add app/agents/chat_agent/tests/test_kv_attachments_smoke.py
git commit -m "test(ai-service): smoke test for KV chat attachment forwarding"
```

---

### Task 10: Wire the KV entrypoint (only if Task 8 outcome is (b) or (c))

**Files:**
- Modify: KV stream entrypoint identified in Task 8
- Test: as above

- [ ] **Step 1: Mirror askFrnd's `process_message_with_files` invocation in the KV path**

Pass `attachments` through by URL (preferred) so the agent's vision tool fetches lazily. If that's not supported, fetch + base64-encode inline at the entrypoint.

- [ ] **Step 2: Add the smoke test from Task 9**

- [ ] **Step 3: Commit + open PR**

```bash
git push origin feature/<your-branch>
gh pr create --title "feat(ai-service): forward KV chat attachments to chat_agent" ...
```

---

## Phase 3 — Web

### Task 11: Type extensions

**Files:**
- Modify: `src/types/studio.ts`

- [ ] **Step 1: Extend `KvAttachment` and add hydrated history shapes**

Replace the existing `KvAttachment` definition with:

```ts
/** A user-attached asset that should be fed as context to the AI when the
 *  next turn is sent. v1: images only (png / jpg / webp). The local-only
 *  `file`/`preview_url` fields hold pre-upload state; `id` and `url`
 *  populate after the upload endpoint resolves. */
export type KvAttachment = {
  /** Server-assigned ULID after upload (`att_*`). Local-only id before upload. */
  id: string;
  name: string;
  mime_type: string;
  size: number;
  /** Blob URL for the in-input preview tile — revoked on remove. */
  preview_url: string;
  /** S3 URL after successful upload. Required at send time. */
  url?: string;
  /** Original File for the upload request. Cleared after upload resolves. */
  file?: File;
  /** True while the upload request is in flight. */
  uploading?: boolean;
};

/** The hydrated, post-persistence shape — what GET file-show returns on
 *  user `chat_history` entries and what `ChatStreamMessage.attachments`
 *  carries. Distinct from `KvAttachment` because hydrated rows have no
 *  blob URL or File object. */
export type KvHistoryAttachment = {
  id: string;
  name: string;
  mime_type: string;
  size: number;
  url: string;
};

/** Bounding-box selections persisted on a user message. Joined to the
 *  base generation by `base_generation_id` so the bubble can render a
 *  mini preview with the boxes overlaid. */
export type KvHistorySelections = {
  base_generation_id: string;
  boxes: KvBoundingBox[];
};
```

- [ ] **Step 2: Find and update any places that destructure `attachment.file` to handle the now-optional field**

```bash
grep -rnE "attachment\.file|a\.file" src/components/studio/kv-generator/ src/hooks/
```

For each call site, add a guard like `if (!attachment.file) return null;` or short-circuit when the upload has resolved.

- [ ] **Step 3: Commit (no behavior change yet)**

```bash
git add src/types/studio.ts src/components/studio/kv-generator/ src/hooks/
git commit -m "refactor(web): split KvAttachment into pre/post-upload shapes"
```

---

### Task 12: Upload helper hook

**Files:**
- Create: `src/components/studio/kv-generator/uploadAttachment.ts`
- Test: `src/components/studio/kv-generator/uploadAttachment.test.ts` (declare-const style matching `gestureMath.test.ts`)

- [ ] **Step 1: Write the failing test (typecheck-only per project convention)**

```ts
import { uploadKvAttachment } from "./uploadAttachment";

declare const describe: (name: string, fn: () => void) => void;
declare const it: (name: string, fn: () => void) => void;
declare const expect: (value: unknown) => {
  toEqual: (expected: unknown) => void;
  toBe: (expected: unknown) => void;
};

describe("uploadKvAttachment", () => {
  it("posts multipart and returns the persisted descriptor", async () => {
    const fakeFile = new File(["x"], "a.png", { type: "image/png" });
    let captured: { url: string; method: string } | null = null;
    const fakeFetch = async (url: string, init: RequestInit) => {
      captured = { url, method: init.method ?? "GET" };
      return new Response(
        JSON.stringify({
          data: [
            { id: "att_X", name: "a.png", mime_type: "image/png", size: 1, url: "https://cdn/x" },
          ],
        }),
        { status: 200 },
      );
    };

    const out = await uploadKvAttachment([fakeFile], { fetchImpl: fakeFetch, baseUrl: "https://api", token: "t" });

    expect(out[0].id).toBe("att_X");
    expect(captured?.method).toBe("POST");
  });
});
```

- [ ] **Step 2: Implement**

```ts
import type { KvHistoryAttachment } from "@/types/studio";

type UploadOpts = {
  baseUrl: string;
  token: string | null;
  fetchImpl?: typeof fetch;
};

export async function uploadKvAttachment(
  files: File[],
  opts: UploadOpts,
): Promise<KvHistoryAttachment[]> {
  const fd = new FormData();
  for (const f of files) fd.append("files[]", f, f.name);
  const headers: Record<string, string> = {};
  if (opts.token) headers.Authorization = `Bearer ${opts.token}`;
  const fetchImpl = opts.fetchImpl ?? fetch;
  const res = await fetchImpl(`${opts.baseUrl.replace(/\/$/, "")}/v1/studio/chat-attachments`, {
    method: "POST",
    headers,
    body: fd,
  });
  if (!res.ok) throw new Error(`upload failed: ${res.status}`);
  const json = (await res.json()) as { data: KvHistoryAttachment[] };
  return json.data;
}
```

- [ ] **Step 3: Lint and commit**

```bash
npx eslint --fix src/components/studio/kv-generator/uploadAttachment.ts src/components/studio/kv-generator/uploadAttachment.test.ts
git add src/components/studio/kv-generator/uploadAttachment*.ts
git commit -m "feat(web): add uploadKvAttachment helper for studio chat-attachment uploads"
```

---

### Task 13: Wire upload-first send in `KvChat`

**Files:**
- Modify: `src/components/studio/kv-generator/KvChat.tsx`

- [ ] **Step 1: Replace base64 serialization with the upload helper**

Locate the existing block (currently around line 863-908) that base64-encodes attachments and calls `stream.send`. Replace with:

```ts
let descriptors: KvHistoryAttachment[] = [];
if (hasAttachments) {
  const filesToUpload = attachments.filter((a) => a.file).map((a) => a.file as File);
  if (filesToUpload.length > 0) {
    descriptors = await uploadKvAttachment(filesToUpload, {
      baseUrl: process.env.NEXT_PUBLIC_API_URL ?? "",
      token: (await getValidAccessToken().catch(() => null)) ?? getSession().accessToken,
    });
  }
  // For attachments that were already-uploaded (re-send case), pass the existing url descriptor.
  for (const a of attachments) {
    if (!a.file && a.url) {
      descriptors.push({
        id: a.id, name: a.name, mime_type: a.mime_type, size: a.size, url: a.url,
      });
    }
  }
}

stream.send(text, {
  ...rest,
  attachments: descriptors.length ? descriptors : undefined,
});
```

(Imports: `uploadKvAttachment`, `getValidAccessToken`, `getSession`, `KvHistoryAttachment`.)

- [ ] **Step 2: Manual smoke test in the dev server**

Open localhost:3000 → KV file → attach an image → send → DevTools Network: should see one `POST /v1/studio/chat-attachments` (200 with `data[]`) followed by the stream POST whose body has `attachments: [{ id, url, ... }]`. No `data_base64` key.

- [ ] **Step 3: Commit**

```bash
git add src/components/studio/kv-generator/KvChat.tsx
git commit -m "feat(web): upload KV chat attachments before stream POST"
```

---

### Task 14: Attach descriptors to the optimistic user message + hydrate from history

**Files:**
- Modify: `src/hooks/useKvStream.ts`

- [ ] **Step 1: Extend the in-memory `ChatStreamMessage` type**

In `useKvStream.ts`, locate the `ChatStreamMessage` type (or wherever `messages: ChatStreamMessage[]` is typed). Add:

```ts
type ChatStreamMessage = {
  // ...existing fields
  attachments?: KvHistoryAttachment[];
};
```

- [ ] **Step 2: Carry attachments AND selections on the optimistic insert**

At line 716 (`setMessages((prev) => [...prev, { id: genId(), role: "user", text: prompt }])`), change to:

```ts
setMessages((prev) => [
  ...prev,
  {
    id: genId(),
    role: "user",
    text: prompt,
    attachments: opts?.attachments?.length ? opts.attachments : undefined,
    selections:
      opts?.boundingBoxes?.length && opts.baseGenerationId
        ? { base_generation_id: opts.baseGenerationId, boxes: opts.boundingBoxes }
        : undefined,
  },
]);
```

(Also update the `opts.attachments` type from the old `{ id, name, mime_type, data_base64 }[]` to `KvHistoryAttachment[]`.)

- [ ] **Step 3: Lift `attachments` AND `selections` in `hydrateInitialMessages`**

Around line 173 (`if (m.role !== "assistant") return { id: m.id, role: m.role, text: m.text };`), replace with:

```ts
if (m.role !== "assistant") {
  return {
    id: m.id,
    role: m.role,
    text: m.text,
    attachments:
      Array.isArray(m.attachments) && m.attachments.length
        ? (m.attachments as KvHistoryAttachment[])
        : undefined,
    selections:
      m.selections && Array.isArray(m.selections.boxes) && m.selections.boxes.length
        ? (m.selections as KvHistorySelections)
        : undefined,
  };
}
```

Update the input type at line 162:

```ts
initial: Array<{
  id: string;
  role: "user" | "assistant";
  text: string;
  attachments?: KvHistoryAttachment[];
  selections?: KvHistorySelections | null;
  tools?: Array<Record<string, unknown>> | null;
  // ...rest unchanged
}>,
```

Also extend `ChatStreamMessage`:

```ts
type ChatStreamMessage = {
  // ...existing
  attachments?: KvHistoryAttachment[];
  selections?: KvHistorySelections;
};
```

- [ ] **Step 4: Commit**

```bash
git add src/hooks/useKvStream.ts
git commit -m "feat(web): carry KV chat attachments on optimistic + hydrated user messages"
```

---

### Task 15a: SelectionPreviewTile component

**Files:**
- Create: `src/components/studio/kv-generator/SelectionPreviewTile.tsx`
- Test: `src/components/studio/kv-generator/SelectionPreviewTile.test.ts` (declare-const-style typecheck)

- [ ] **Step 1: Add the failing tile-geometry test**

```ts
import { computeTileSize } from "./SelectionPreviewTile";

declare const describe: (name: string, fn: () => void) => void;
declare const it: (name: string, fn: () => void) => void;
declare const expect: (value: unknown) => {
  toEqual: (expected: unknown) => void;
};

describe("computeTileSize", () => {
  it("clamps the long edge to 144 while preserving aspect (landscape)", () => {
    expect(computeTileSize(1600, 900, 144)).toEqual({ width: 144, height: 81 });
  });
  it("clamps the long edge to 144 while preserving aspect (portrait)", () => {
    expect(computeTileSize(900, 1600, 144)).toEqual({ width: 81, height: 144 });
  });
  it("falls back to a 144 square when natural size is unknown", () => {
    expect(computeTileSize(0, 0, 144)).toEqual({ width: 144, height: 144 });
  });
});
```

- [ ] **Step 2: Implement the component**

```tsx
"use client";

import type { KvBoundingBox } from "@/types/studio";

const MAX_EDGE = 144;
const STROKE = "#4D8EFF";

/** Pure helper — exported for tests. Returns the rendered tile size with
 *  the long edge clamped to `max` and the short edge scaled to keep aspect.
 *  Falls back to a square when natural dimensions are unknown. */
export function computeTileSize(
  naturalW: number,
  naturalH: number,
  max: number = MAX_EDGE,
): { width: number; height: number } {
  if (!naturalW || !naturalH) return { width: max, height: max };
  const ratio = max / Math.max(naturalW, naturalH);
  return { width: Math.round(naturalW * ratio), height: Math.round(naturalH * ratio) };
}

export function SelectionPreviewTile({
  imageUrl,
  naturalWidth,
  naturalHeight,
  boxes,
}: {
  /** The base generation's image URL. May be empty when the generation
   *  is missing/deleted — we render a neutral grey tile in that case. */
  imageUrl?: string;
  naturalWidth?: number;
  naturalHeight?: number;
  boxes: KvBoundingBox[];
}) {
  const { width, height } = computeTileSize(naturalWidth ?? 0, naturalHeight ?? 0);
  const count = boxes.length;
  return (
    <div
      className="relative overflow-hidden rounded-2xl ring-1 ring-white/10"
      style={{ width, height, background: "#1a1a1a" }}
    >
      {imageUrl ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img
          src={imageUrl}
          alt="Edited base"
          className="absolute inset-0 h-full w-full object-cover"
          width={width}
          height={height}
        />
      ) : (
        <div className="absolute inset-0 flex items-center justify-center font-geist text-[10px] text-text-inverse-subtlest">
          Edited region
        </div>
      )}
      {/* Bbox overlay */}
      <svg
        viewBox="0 0 1 1"
        preserveAspectRatio="none"
        className="absolute inset-0 h-full w-full"
      >
        {boxes.map((b) => (
          <rect
            key={b.id}
            x={b.x}
            y={b.y}
            width={b.width}
            height={b.height}
            fill="rgba(77,142,255,0.08)"
            stroke={STROKE}
            strokeWidth={0.012}
            strokeDasharray="0.04 0.03"
            vectorEffect="non-scaling-stroke"
          />
        ))}
      </svg>
      {/* Count badge */}
      <div className="absolute bottom-1 right-1 flex h-5 min-w-5 items-center justify-center rounded-full bg-[rgba(47,107,224,0.95)] px-1.5 font-geist text-[10px] font-semibold text-white">
        {count}
      </div>
    </div>
  );
}
```

- [ ] **Step 3: Lint and commit**

```bash
npx eslint --fix src/components/studio/kv-generator/SelectionPreviewTile.tsx src/components/studio/kv-generator/SelectionPreviewTile.test.ts
git add src/components/studio/kv-generator/SelectionPreviewTile*
git commit -m "feat(web): add SelectionPreviewTile for KV chat history"
```

---

### Task 15b: Render thumbnail strip + selection tile on user messages

**Files:**
- Modify: `src/components/studio/kv-generator/KvChat.tsx` (the user-render branch around line 439-448)
- Modify: `src/components/studio/kv-generator/KvChat.tsx` (props — receive `generations` lookup)
- Modify: `src/components/studio/kv-generator/KvGeneratorLayout.tsx` (pass `generations` down to `KvChat`)

- [ ] **Step 1: Pass generations down to KvChat**

In `KvGeneratorLayout.tsx`, find the `<KvChat ... />` invocation (around line 900) and add `generations={generations}` prop. In `KvChat.tsx`, accept the new prop:

```ts
generations?: KvGeneration[];
```

…then declare:

```ts
generations = [],
```

in the destructure.

- [ ] **Step 2: Add the render branch**

Replace the user branch with:

```tsx
if (m.role === "user") {
  const attachments = m.attachments ?? [];
  const selections = m.selections;
  const baseGen = selections
    ? generations.find((g) => g.id === selections.base_generation_id)
    : null;
  return (
    <div key={m.id} data-testid="kv-user-message" className="flex w-full flex-col items-end gap-2 px-2 py-6">
      {selections && (
        <SelectionPreviewTile
          imageUrl={baseGen?.image_url}
          naturalWidth={
            (baseGen?.metadata as { natural_width?: number } | null)?.natural_width
          }
          naturalHeight={
            (baseGen?.metadata as { natural_height?: number } | null)?.natural_height
          }
          boxes={selections.boxes}
        />
      )}
      {attachments.length > 0 && (
        <div className="flex flex-wrap justify-end gap-2">
          {attachments.map((a) => {
            const tile = attachments.length === 1 ? "h-24 w-24" : "h-16 w-16";
            return (
              <a
                key={a.id}
                href={a.url}
                target="_blank"
                rel="noreferrer"
                className="group flex flex-col items-end gap-1"
              >
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img
                  src={a.url}
                  alt={a.name}
                  className={`${tile} rounded-2xl object-cover ring-1 ring-white/10 transition group-hover:ring-white/30`}
                />
                <span className="max-w-[120px] truncate font-geist text-[10px] text-text-inverse-subtlest">
                  {a.name}
                </span>
              </a>
            );
          })}
        </div>
      )}
      {m.text && (
        <div className="max-w-[348px] rounded-3xl bg-[rgba(255,255,255,0.15)] px-4 py-3 backdrop-blur-[8px]">
          <p className="font-geist text-textMdRegular leading-[1.4] tracking-[-0.16px] text-white whitespace-pre-wrap">
            {m.text}
          </p>
        </div>
      )}
    </div>
  );
}
```

(Add `import { SelectionPreviewTile } from "./SelectionPreviewTile";` at the top.)

- [ ] **Step 3: Visual check in the dev server**

Open the KV file → attach 1 image + draw 2 bbox selections + type a prompt → send. Confirm:
- Selection tile (max 144px edge) appears at the top of the user bubble showing the base generation with the 2 boxes overlaid in dashed blue and a `2` badge.
- 1 attachment thumbnail (96×96) below it.
- Text bubble at the bottom.
- Reload → identical render.
- Send a chat-only turn (no boxes, no attachments) → just text bubble.
- Send a 2-attachment turn → 64×64 row.

- [ ] **Step 4: Commit**

```bash
git add src/components/studio/kv-generator/KvChat.tsx src/components/studio/kv-generator/KvGeneratorLayout.tsx
git commit -m "feat(web): render attachment + selection tiles on KV user messages"
```

---

### Task 16: Playwright e2e

**Files:**
- Create: `tests/e2e/studio-kv-chat-attachments.spec.ts`

- [ ] **Step 1: Write the e2e (sketch — adapt to existing fixture/login pattern)**

```ts
import { test, expect } from "@playwright/test";

test("user sees attachment thumbnail in KV thread after send and refresh", async ({ page }) => {
  // Reuse the login + KV-file fixture from existing studio tests.
  // ...login + nav...

  await page.setInputFiles('input[type="file"]', "tests/fixtures/sample.png");
  await page.fill('textarea', "describe this");
  await page.getByRole("button", { name: /send/i }).click();

  // Optimistic render
  const userBubble = page.locator('[data-testid="kv-user-message"]').last();
  await expect(userBubble.locator("img").first()).toBeVisible();

  // Refresh and confirm persistence
  await page.reload();
  await expect(userBubble.locator("img").first()).toBeVisible();
});

test("user sees bounding-box selection tile in KV thread after edit + refresh", async ({ page }) => {
  // ...login + nav to a file with at least one generation...

  // Activate frame tool, draw a bbox (helper from existing kv-overlays e2e)
  await drawBoundingBox(page, { x: 0.3, y: 0.3, w: 0.2, h: 0.2 });
  await page.fill('textarea', "younger face");
  await page.getByRole("button", { name: /send/i }).click();

  const userBubble = page.locator('[data-testid="kv-user-message"]').last();
  // Selection tile renders an svg with at least one rect overlay
  await expect(userBubble.locator("svg rect")).toHaveCount(1);
  // Count badge
  await expect(userBubble.getByText("1", { exact: true })).toBeVisible();

  await page.reload();
  await expect(userBubble.locator("svg rect")).toHaveCount(1);
});
```

(Add a `data-testid="kv-user-message"` on the user wrapper div in `KvChat.tsx` per Task 15b. `drawBoundingBox` should reuse whatever helper the existing `tests/e2e/kv-overlays.spec.ts` uses for canvas drag.)

- [ ] **Step 2: Run and commit**

```bash
npx playwright test tests/e2e/studio-kv-chat-attachments.spec.ts
git add tests/e2e/studio-kv-chat-attachments.spec.ts src/components/studio/kv-generator/KvChat.tsx
git commit -m "test(web): e2e for KV chat attachment thumbnail history"
```

---

### Task 17: Open the web PR

- [ ] **Step 1: Push and open**

```bash
git push -u origin feature/<your-branch>
gh pr create --title "feat(web): persisted KV chat attachment history with thumbnails" --body "..."
```

---

## Self-review checklist

- [ ] **Spec coverage:**
  - Attachments: upload endpoint → Task 4; persistence → Task 5; hydration → Task 6; ai-service forwarding → Task 8-10; web type → Task 11; web upload → Task 12-13; web hydrate → Task 14; web render → Task 15b.
  - Selections: persistence → Task 5; hydration → Task 6; web type → Task 11; web hydrate → Task 14; web tile component → Task 15a; web render → Task 15b.
  - E2E coverage for both → Task 16.
- [ ] **No placeholders** — every code step has the actual code.
- [ ] **Type consistency:** `KvHistoryAttachment` shape `{id, name, mime_type, size, url}` matches the api response shape (Task 4) and the hydrated history (Task 6) and the web type (Task 11). `KvHistorySelections` shape `{base_generation_id, boxes}` matches the api response shape (Task 6 hydration block) and the web type (Task 11). `boxes[]` are `KvBoundingBox` (existing).
- [ ] **Ship order:** api → ai-service verification → web. Web's send call needs the new endpoint live for attachments; selections work even with old api but rendering needs hydration support so still ship api first.
