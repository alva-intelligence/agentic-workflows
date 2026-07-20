# KV Chat Bubble — Inline Pills (Persisted) — API Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist the structured `message_blocks` payload on `user_chat_history.message` JSONB and round-trip it (plus `attachments` + `selections`) through `GET /v1/threads/{id}` so the web KV bubble can render inline pills after a refresh.

**Architecture:** Two surface-level changes in `frndos/api`. (1) Where the controller / service currently flattens `message_blocks` to a string for the model, also nest the original blocks into the persisted `$message` JSONB blob — one new key, additive only. (2) `ChatHelper::formatChatHistoryEntry()` (called by the file-show endpoint to build `chat_history`) now emits `attachments`, `selections`, and `blocks` on user-role rows — closing two pre-existing TODOs and adding the new feature in one pass. Both shapes are absent for legacy rows; the web side falls back to the existing layout.

**Tech Stack:** Laravel 13, PHP 8.5, Pest.

**Spec reference:** [docs/superpowers/specs/2026-05-06-kv-chat-bubble-inline-pills-design.md](../specs/2026-05-06-kv-chat-bubble-inline-pills-design.md)

**Service ordering:** API first (this plan, additive — adds new keys to `chat_history`), Web second (consumes `blocks` to render the inline-pill bubble; falls back gracefully when absent).

---

## File Structure

**API — `frndos/api`:**

- Modify: `app/Http/Controllers/Api/Chat/ThreadController.php`
  - `store()` main Chat branch (line ~291) — nest `blocks` into `$message`.
  - `update()` main Chat branch (line ~611) — same.
  - The P&A entry points (`store()` line ~180, `update()` line ~421) call `ChatService::openPointAndAskThread` / `appendPointAndAskMessage` — those service methods get the same nest, see below.
  - The KV branch (`update()` line ~458) forwards through `ChatService::streamKvGenerator` — that method gets the nest too.

- Modify: `app/Services/ChatService.php`
  - `openPointAndAskThread()` (line ~105) — accept `?array $blocks` and nest into `message`.
  - `appendPointAndAskMessage()` (line ~150) — same.
  - `streamKvGenerator()` (line ~266) — accept `?array $blocks` and nest into `$messageBlob` at line ~360.

- Modify: `app/Helpers/ChatHelper.php`
  - `formatChatHistoryEntry()` (line ~437) — for user-role rows, emit `attachments` (from `$chat->files` filtered to image MIMEs), `selections` (from `$chat->message['selections']` reshaped to `{base_generation_id, boxes}`), and `blocks` (from `$chat->message['blocks']`). All optional.

- Create: `tests/Unit/Helpers/ChatHelperTest.php` — Pest unit tests for `formatChatHistoryEntry()`. Pure-function level (instantiates a `UserChatHistory` model in memory; no DB writes, no `RefreshDatabase`).

---

## Phase 1 — `formatChatHistoryEntry()` (TDD-first, the read path)

> **Order rationale:** Read first, write second. The web side reads via the file-show endpoint that fans out to `formatChatHistoryEntry`, so this is the contract the web depends on. Locking it down with unit tests first makes the controller/service writes drop in cleanly.

### Task 1: Set up the test file

**Files:**
- Create: `tests/Unit/Helpers/ChatHelperTest.php`

- [ ] **Step 1: Create the file with a single passing scaffold test**

```php
<?php

use App\Helpers\ChatHelper;
use App\Models\UserChatHistory;
use Tests\TestCase;

uses(TestCase::class);

/*
 * Unit tests for ChatHelper::formatChatHistoryEntry().
 *
 * These tests instantiate UserChatHistory models in memory (no `save()`,
 * no `RefreshDatabase`) and assert the shape of the formatted output.
 *
 * Why pure unit tests:
 *   - The function is the contract the web KV bubble reads from on refresh.
 *   - DB writes are out of scope — we just need to know that given a row
 *     with shape X on its columns, the output has shape Y.
 *   - Avoids the api/phpunit.xml SQLite override that previously wiped
 *     the dev DB (see lesson_test_db_isolation memory).
 */

function makeUserChatHistory(array $attrs): UserChatHistory
{
    $row = new UserChatHistory;
    foreach ($attrs as $k => $v) {
        $row->{$k} = $v;
    }
    return $row;
}

it('emits the baseline shape for a plain user row', function () {
    $row = makeUserChatHistory([
        'id' => 'cm_1',
        'message' => ['content' => 'hello', 'type' => 'human'],
        'tools' => null,
        'thinking' => null,
        'quick_replies' => null,
        'created_at' => now(),
    ]);

    $out = ChatHelper::formatChatHistoryEntry($row);

    expect($out['role'])->toBe('human');
    expect($out['message'])->toBe('hello');
    expect($out)->not->toHaveKey('attachments');
    expect($out)->not->toHaveKey('selections');
    expect($out)->not->toHaveKey('blocks');
});
```

- [ ] **Step 2: Run it to confirm green**

Run from `frndos/api`:

```bash
php artisan test tests/Unit/Helpers/ChatHelperTest.php
```

Expected: 1 passed. (No production code change yet — we're asserting today's behavior.)

- [ ] **Step 3: Commit**

```bash
git add tests/Unit/Helpers/ChatHelperTest.php
git commit -m "test(api): scaffold ChatHelperTest for formatChatHistoryEntry"
```

---

### Task 2: Failing test — user row with `message.blocks` should emit `blocks`

**Files:**
- Modify: `tests/Unit/Helpers/ChatHelperTest.php`

- [ ] **Step 1: Add the failing test**

Append to `tests/Unit/Helpers/ChatHelperTest.php`:

```php
it('emits blocks on a user row when message.blocks is set', function () {
    $blocks = [
        ['type' => 'text', 'text' => 'add '],
        ['type' => 'attachment_ref', 'id' => 'att_abc'],
        ['type' => 'text', 'text' => ' top-right'],
    ];
    $row = makeUserChatHistory([
        'id' => 'cm_2',
        'message' => [
            'content' => 'add  top-right',
            'type' => 'human',
            'blocks' => $blocks,
        ],
        'tools' => null,
        'thinking' => null,
        'quick_replies' => null,
        'created_at' => now(),
    ]);

    $out = ChatHelper::formatChatHistoryEntry($row);

    expect($out)->toHaveKey('blocks');
    expect($out['blocks'])->toBe($blocks);
});

it('omits blocks on a user row when message.blocks is absent', function () {
    $row = makeUserChatHistory([
        'id' => 'cm_3',
        'message' => ['content' => 'plain', 'type' => 'human'],
        'tools' => null,
        'thinking' => null,
        'quick_replies' => null,
        'created_at' => now(),
    ]);

    $out = ChatHelper::formatChatHistoryEntry($row);

    expect($out)->not->toHaveKey('blocks');
});

it('omits blocks on an ai row even if the array is non-empty', function () {
    // Defensive: only user rows should ever carry blocks. If an ai row
    // happens to have it (shouldn't, but be paranoid), we don't leak it.
    $row = makeUserChatHistory([
        'id' => 'cm_4',
        'message' => [
            'content' => 'reply',
            'type' => 'ai',
            'blocks' => [['type' => 'text', 'text' => 'noise']],
        ],
        'tools' => null,
        'thinking' => null,
        'quick_replies' => null,
        'created_at' => now(),
    ]);

    $out = ChatHelper::formatChatHistoryEntry($row);

    expect($out)->not->toHaveKey('blocks');
});
```

- [ ] **Step 2: Run to confirm 2 of 3 fail**

Run: `php artisan test tests/Unit/Helpers/ChatHelperTest.php`
Expected: 2 failures (the "emits blocks" test and "omits blocks on an ai row" — the omit-when-absent test passes today because the helper doesn't touch the field at all).

- [ ] **Step 3: Implement the minimal change in `ChatHelper::formatChatHistoryEntry()`**

Open `app/Helpers/ChatHelper.php`. Find the `formatChatHistoryEntry()` method (line ~437). After the existing `paa_context` emission (line ~478, the `if (! empty($chat->paa_context))` block) and BEFORE the `if ($role === 'ai')` block (line ~483), insert:

```php
        // KV inline-pill bubble: surface the persisted block-by-block
        // structure on user rows so the web bubble can render attachments
        // and selections inline after a refresh. Absent on legacy rows
        // and on rows where the prompt was plain prose — web falls back
        // to the existing 3-section layout.
        if ($role === 'human'
            && is_array($chat->message['blocks'] ?? null)
            && ! empty($chat->message['blocks'])
        ) {
            $result['blocks'] = $chat->message['blocks'];
        }
```

- [ ] **Step 4: Run to confirm green**

Run: `php artisan test tests/Unit/Helpers/ChatHelperTest.php`
Expected: 4 passed.

- [ ] **Step 5: Commit**

```bash
git add app/Helpers/ChatHelper.php tests/Unit/Helpers/ChatHelperTest.php
git commit -m "feat(api): emit blocks on user chat-history entries for KV inline-pill bubble"
```

---

### Task 3: Failing test — user row with image files should emit `attachments`

**Files:**
- Modify: `tests/Unit/Helpers/ChatHelperTest.php`

- [ ] **Step 1: Add the failing tests**

Append to `tests/Unit/Helpers/ChatHelperTest.php`:

```php
it('emits attachments built from image-mime entries in $chat->files', function () {
    $row = makeUserChatHistory([
        'id' => 'cm_5',
        'message' => ['content' => '', 'type' => 'human'],
        'files' => [
            [
                'id' => 'att_img1',
                'name' => 'sketch.png',
                'mime_type' => 'image/png',
                'size' => 12345,
                'url' => 'https://s3.example.com/sketch.png',
            ],
            [
                // Non-image — should NOT appear in attachments[]
                'id' => 'doc_1',
                'name' => 'spec.pdf',
                'mime_type' => 'application/pdf',
                'size' => 6789,
                'url' => 'https://s3.example.com/spec.pdf',
            ],
        ],
        'tools' => null,
        'thinking' => null,
        'quick_replies' => null,
        'created_at' => now(),
    ]);

    $out = ChatHelper::formatChatHistoryEntry($row);

    expect($out)->toHaveKey('attachments');
    expect($out['attachments'])->toHaveCount(1);
    expect($out['attachments'][0])->toMatchArray([
        'id' => 'att_img1',
        'name' => 'sketch.png',
        'mime_type' => 'image/png',
        'size' => 12345,
        'url' => 'https://s3.example.com/sketch.png',
    ]);
});

it('omits attachments when only non-image files are present', function () {
    $row = makeUserChatHistory([
        'id' => 'cm_6',
        'message' => ['content' => '', 'type' => 'human'],
        'files' => [
            [
                'id' => 'doc_1',
                'name' => 'spec.pdf',
                'mime_type' => 'application/pdf',
                'size' => 1,
                'url' => 'https://s3.example.com/spec.pdf',
            ],
        ],
        'tools' => null,
        'thinking' => null,
        'quick_replies' => null,
        'created_at' => now(),
    ]);

    $out = ChatHelper::formatChatHistoryEntry($row);

    expect($out)->not->toHaveKey('attachments');
});

```

> **Note:** No `omits on ai row` test here — `formatChatHistoryEntry()`'s `ai` branch hits a DB query (`UserChatLogUsage::where(...)`) that throws under pure-unit conditions. The production guard `$role === 'human'` is self-evidently correct without a test.

- [ ] **Step 2: Run to confirm 1 of 2 fails**

Run: `php artisan test tests/Unit/Helpers/ChatHelperTest.php`
Expected: 1 failure (the "emits attachments" test fails because the helper doesn't emit the key today; the omit-when-non-image-only test passes because the helper doesn't touch the `attachments` key at all yet).

- [ ] **Step 3: Implement the minimal change**

Open `app/Helpers/ChatHelper.php`. Find the `formatChatHistoryEntry()` method. After the new `blocks` emission you added in Task 2, and BEFORE the `if ($role === 'ai')` block, insert:

```php
        // KV inline-pill bubble: emit the image subset of $chat->files as
        // a hydrated `attachments` array on user rows. The web bubble
        // resolves attachment_ref blocks against this list to render
        // thumbnail + name pills inline.
        if ($role === 'human' && is_array($chat->files ?? null)) {
            $images = collect($chat->files)
                ->filter(fn ($f) => is_array($f)
                    && ! empty($f['mime_type'])
                    && self::isImageMimeType((string) $f['mime_type']))
                ->map(fn ($f) => [
                    'id' => (string) ($f['id'] ?? ''),
                    'name' => (string) ($f['name'] ?? ''),
                    'mime_type' => (string) ($f['mime_type'] ?? ''),
                    'size' => (int) ($f['size'] ?? 0),
                    'url' => (string) ($f['url'] ?? ''),
                ])
                ->values()
                ->all();

            if (! empty($images)) {
                $result['attachments'] = $images;
            }
        }
```

- [ ] **Step 4: Run to confirm green**

Run: `php artisan test tests/Unit/Helpers/ChatHelperTest.php`
Expected: 5 passed (1 from Task 1 + 2 from Task 2 + 2 new from Task 3).

- [ ] **Step 5: Commit**

```bash
git add app/Helpers/ChatHelper.php tests/Unit/Helpers/ChatHelperTest.php
git commit -m "feat(api): emit attachments on user chat-history entries for KV bubble hydration"
```

---

### Task 4: Failing test — user row with `message.selections` should emit reshaped `selections`

**Files:**
- Modify: `tests/Unit/Helpers/ChatHelperTest.php`

- [ ] **Step 1: Add the failing tests**

Append to `tests/Unit/Helpers/ChatHelperTest.php`:

```php
it('emits selections reshaped to { base_generation_id, boxes }', function () {
    // Persisted shape on the row: a flat array under `message.selections`
    // (legacy from `bounding_boxes` validation) + a separate
    // `message.base_generation_id`. The wire-shape `selections` on the
    // chat-history response wraps both into one envelope so the web
    // matches what useKvStream emits optimistically in-session.
    $boxes = [
        ['id' => 'bx_1', 'x' => 0.1, 'y' => 0.1, 'width' => 0.2, 'height' => 0.2],
        ['id' => 'bx_2', 'x' => 0.5, 'y' => 0.5, 'width' => 0.1, 'height' => 0.1],
    ];
    $row = makeUserChatHistory([
        'id' => 'cm_8',
        'message' => [
            'content' => 'edit these',
            'type' => 'human',
            'selections' => $boxes,
            'base_generation_id' => 'gen_xyz',
        ],
        'tools' => null,
        'thinking' => null,
        'quick_replies' => null,
        'created_at' => now(),
    ]);

    $out = ChatHelper::formatChatHistoryEntry($row);

    expect($out)->toHaveKey('selections');
    expect($out['selections'])->toMatchArray([
        'base_generation_id' => 'gen_xyz',
        'boxes' => $boxes,
    ]);
});

it('omits selections when message.selections is absent', function () {
    $row = makeUserChatHistory([
        'id' => 'cm_9',
        'message' => ['content' => 'plain', 'type' => 'human'],
        'tools' => null,
        'thinking' => null,
        'quick_replies' => null,
        'created_at' => now(),
    ]);

    $out = ChatHelper::formatChatHistoryEntry($row);

    expect($out)->not->toHaveKey('selections');
});

```

> **Note:** No `omits on ai row` test here either — same DB-query issue as Task 3. The `$role === 'human'` guard in production is self-evidently correct.

- [ ] **Step 2: Run to confirm 1 of 2 fails**

Run: `php artisan test tests/Unit/Helpers/ChatHelperTest.php`
Expected: 1 failure (the "emits selections" test fails; the omit-when-absent test passes today because the helper doesn't touch the `selections` key yet).

- [ ] **Step 3: Implement the minimal change**

Open `app/Helpers/ChatHelper.php`. After the `attachments` emission block, and BEFORE the `if ($role === 'ai')` block, insert:

```php
        // KV inline-pill bubble: reshape persisted selections to the
        // wire envelope { base_generation_id, boxes } that web consumes
        // (matches useKvStream's optimistic in-session shape). Persisted
        // shape on the row stays flat; this is purely a response-side
        // reshape.
        if ($role === 'human'
            && is_array($chat->message['selections'] ?? null)
            && ! empty($chat->message['selections'])
        ) {
            $result['selections'] = [
                'base_generation_id' => (string) ($chat->message['base_generation_id'] ?? ''),
                'boxes' => $chat->message['selections'],
            ];
        }
```

- [ ] **Step 4: Run to confirm green**

Run: `php artisan test tests/Unit/Helpers/ChatHelperTest.php`
Expected: 7 passed (1 from Task 1 + 2 from Task 2 + 2 from Task 3 + 2 new from Task 4).

- [ ] **Step 5: Commit**

```bash
git add app/Helpers/ChatHelper.php tests/Unit/Helpers/ChatHelperTest.php
git commit -m "feat(api): emit reshaped selections on user chat-history entries for KV bubble hydration"
```

---

## Phase 2 — Persistence (write path)

> **What changes:** the controller / service code that constructs the `$message` JSONB blob now nests `blocks` whenever `message_blocks` was sent on the request. Five sites total — see file structure. None of these are covered by automated tests (no Feature-test surface — see `lesson_test_db_isolation` re: SQLite-incompatible migrations); manual verification at the end of the phase via pgAdmin.

### Task 5: KV branch — nest `blocks` in `streamKvGenerator`

**Files:**
- Modify: `app/Http/Controllers/Api/Chat/ThreadController.php` (line ~458)
- Modify: `app/Services/ChatService.php` (line ~266)

This is the most important site — the only one the bubble feature actively relies on at launch (KV chat is the surface that ships the new bubble).

- [ ] **Step 1: Thread `$blocks` from controller into the service signature**

Open `app/Http/Controllers/Api/Chat/ThreadController.php`. Find the KV branch in `update()` (line ~455 — `if ($thread->isKvGenerator())`).

The `$blocks` variable already exists at line ~458:

```php
            $blocks = $streamRequest->validated('message_blocks');
            $userQuery = is_array($blocks) && count($blocks) > 0
                ? MessageBlocksFlattener::flatten($blocks)
                : (string) $streamRequest->validated('message', '');
```

Find the `$chatService->streamKvGenerator(...)` call that follows (line ~537–556). Append the new `$blocks` argument (after `$streamRequest->input('base_generation_id')`):

Find:

```php
            return $chatService->streamKvGenerator(
                $thread,
                $userQuery,
                $mode,
                $user,
                $workspace,
                $imageModel,
                $boundingBoxes,
                $baseGeneration,
                $attachments,
                $stylePresetKey,
                $aspectRatio,
                $useBrandKnowledge,
                $canvasMode,
                // Forward the raw base_generation_id from the request so
                // ChatService can persist it on the user message blob for
                // history hydration. Distinct from $baseGeneration which
                // is the resolved generation row used by the AI service.
                $streamRequest->input('base_generation_id')
            );
```

Replace with:

```php
            return $chatService->streamKvGenerator(
                $thread,
                $userQuery,
                $mode,
                $user,
                $workspace,
                $imageModel,
                $boundingBoxes,
                $baseGeneration,
                $attachments,
                $stylePresetKey,
                $aspectRatio,
                $useBrandKnowledge,
                $canvasMode,
                // Forward the raw base_generation_id from the request so
                // ChatService can persist it on the user message blob for
                // history hydration. Distinct from $baseGeneration which
                // is the resolved generation row used by the AI service.
                $streamRequest->input('base_generation_id'),
                // KV inline-pill bubble: forward the original ContentBlock[]
                // for persistence on the user message blob. Web reads this
                // back via formatChatHistoryEntry to render inline pills
                // after a refresh.
                is_array($blocks) && count($blocks) > 0 ? $blocks : null
            );
```

- [ ] **Step 2: Accept `$blocks` in `streamKvGenerator` and nest it**

Open `app/Services/ChatService.php`. Find `streamKvGenerator()` (line ~266). Update the signature — add `?array $blocks = null` as the last parameter:

Find:

```php
    public function streamKvGenerator(
        UserThread $thread,
        string $userQuery,
        string $mode,
        User $user,
        Workspace $workspace,
        string $imageModel = 'gpt-image-1',
        array $boundingBoxes = [],
        ?array $baseGeneration = null,
        array $attachments = [],
        ?string $stylePresetKey = null,
        ?string $aspectRatio = null,
        ?bool $useBrandKnowledge = null,
        string $canvasMode = 'sketch',
        ?string $baseGenerationId = null
    ): StreamedResponse {
        return response()->stream(function () use ($thread, $userQuery, $mode, $user, $imageModel, $boundingBoxes, $baseGeneration, $attachments, $stylePresetKey, $aspectRatio, $useBrandKnowledge, $canvasMode, $baseGenerationId) {
```

Replace with:

```php
    public function streamKvGenerator(
        UserThread $thread,
        string $userQuery,
        string $mode,
        User $user,
        Workspace $workspace,
        string $imageModel = 'gpt-image-1',
        array $boundingBoxes = [],
        ?array $baseGeneration = null,
        array $attachments = [],
        ?string $stylePresetKey = null,
        ?string $aspectRatio = null,
        ?bool $useBrandKnowledge = null,
        string $canvasMode = 'sketch',
        ?string $baseGenerationId = null,
        ?array $blocks = null
    ): StreamedResponse {
        return response()->stream(function () use ($thread, $userQuery, $mode, $user, $imageModel, $boundingBoxes, $baseGeneration, $attachments, $stylePresetKey, $aspectRatio, $useBrandKnowledge, $canvasMode, $baseGenerationId, $blocks) {
```

- [ ] **Step 3: Nest `blocks` into `$messageBlob`**

In the same method, find the `$messageBlob` construction (line ~360):

```php
                $messageBlob = [
                    'content' => $userQuery,
                    'type' => ChatMessageType::USER,
                ];
                if (! empty($boundingBoxes)) {
                    $messageBlob['selections'] = $boundingBoxes;
                }
                if (! empty($baseGenerationId)) {
                    $messageBlob['base_generation_id'] = $baseGenerationId;
                }
```

Append (still before the `$thread->messages()->create([...])` call at line ~371):

```php
                // KV inline-pill bubble: persist the original ContentBlock[]
                // alongside the flattened `content`. The web bubble reads
                // this back to render attachments and selections inline.
                // `content` stays for back-compat — askFrnd / P&A / legacy
                // clients reading `$chat->message['content']` keep working.
                if (is_array($blocks) && count($blocks) > 0) {
                    $messageBlob['blocks'] = $blocks;
                }
```

- [ ] **Step 4: Type-check**

Run from `frndos/api`:

```bash
vendor/bin/pint --test app/Http/Controllers/Api/Chat/ThreadController.php app/Services/ChatService.php
php -l app/Http/Controllers/Api/Chat/ThreadController.php
php -l app/Services/ChatService.php
```

Expected: lint passes, both files report `No syntax errors detected`.

- [ ] **Step 5: Run all unit tests to confirm nothing else broke**

Run: `php artisan test tests/Unit/`
Expected: all green (the existing `KvChatMessageBlocksTest` continues to pass; new `ChatHelperTest` continues to pass).

- [ ] **Step 6: Commit**

```bash
git add app/Http/Controllers/Api/Chat/ThreadController.php app/Services/ChatService.php
git commit -m "feat(api): persist message_blocks on KV user-message rows"
```

---

### Task 6: Main Chat branches — nest `blocks` in `store()` and `update()`

**Files:**
- Modify: `app/Http/Controllers/Api/Chat/ThreadController.php` (lines ~291 + ~611)

These two sites construct `$messageData` directly in the controller. The KV bubble feature itself does not require these — non-KV chat surfaces never read `m.blocks` — but the spec opts to nest at all 5 sites so the data shape stays consistent across thread types. Strictly additive.

- [ ] **Step 1: Nest `blocks` in `store()` main Chat branch**

Open `app/Http/Controllers/Api/Chat/ThreadController.php`. Find the main Chat branch in `store()` (the `response()->stream(function () use (...)` block at line ~220). The `$blocks` variable is in scope (line ~225). Find the `$message` construction (line ~291):

```php
                $message = [
                    'content' => $userQuery,
                    'type' => ChatMessageType::USER,
                ];
                $selections = $streamRequest->validated('bounding_boxes', []);
                $baseGenerationId = $streamRequest->validated('base_generation_id');
                if (! empty($selections)) {
                    $message['selections'] = $selections;
                }
                if (! empty($baseGenerationId)) {
                    $message['base_generation_id'] = $baseGenerationId;
                }
```

Append (before the `$persistedAttachments = collect(...)` line that follows):

```php
                // KV inline-pill bubble: persist the original ContentBlock[]
                // when sent. Additive — non-KV consumers never read the key.
                if (is_array($blocks) && count($blocks) > 0) {
                    $message['blocks'] = $blocks;
                }
```

- [ ] **Step 2: Nest `blocks` in `update()` main Chat branch**

Find the main Chat branch in `update()` (the `response()->stream(function () use (...)` at line ~559). The `$blocks` variable is in scope (line ~562). Find the `$message` construction (line ~611):

```php
                $message = [
                    'content' => $userQuery,
                    'type' => ChatMessageType::USER,
                ];
                $selections = $streamRequest->validated('bounding_boxes', []);
                $baseGenerationId = $streamRequest->validated('base_generation_id');
                if (! empty($selections)) {
                    $message['selections'] = $selections;
                }
                if (! empty($baseGenerationId)) {
                    $message['base_generation_id'] = $baseGenerationId;
                }
```

Append (before the `$persistedAttachments = collect(...)` line that follows):

```php
                // KV inline-pill bubble: persist the original ContentBlock[]
                // when sent. Additive — non-KV consumers never read the key.
                if (is_array($blocks) && count($blocks) > 0) {
                    $message['blocks'] = $blocks;
                }
```

- [ ] **Step 3: Lint + sanity-check**

Run from `frndos/api`:

```bash
vendor/bin/pint --test app/Http/Controllers/Api/Chat/ThreadController.php
php -l app/Http/Controllers/Api/Chat/ThreadController.php
php artisan test tests/Unit/
```

Expected: lint passes, no syntax errors, all unit tests green.

- [ ] **Step 4: Commit**

```bash
git add app/Http/Controllers/Api/Chat/ThreadController.php
git commit -m "feat(api): persist message_blocks on main-chat user-message rows"
```

---

### Task 7: P&A branches — thread `blocks` through ChatService

**Files:**
- Modify: `app/Http/Controllers/Api/Chat/ThreadController.php` (lines ~180 + ~421)
- Modify: `app/Services/ChatService.php` (lines ~105 + ~150)

The P&A path doesn't render the new bubble (P&A surfaces are out of scope per the spec's "non-goals"), but the spec opts to thread the data through these sites anyway so the persistence shape is consistent for any future consumer. Strictly additive.

- [ ] **Step 1: Accept `?array $blocks` in `openPointAndAskThread`**

Open `app/Services/ChatService.php`. Find `openPointAndAskThread()` (line ~105):

```php
    public function openPointAndAskThread(
        User $user,
        Workspace $workspace,
        string $userQuery,
        array $context,
        array $launchContext = []
    ): array {
        return DB::transaction(function () use ($user, $workspace, $userQuery, $context, $launchContext) {
```

Replace with:

```php
    public function openPointAndAskThread(
        User $user,
        Workspace $workspace,
        string $userQuery,
        array $context,
        array $launchContext = [],
        ?array $blocks = null
    ): array {
        return DB::transaction(function () use ($user, $workspace, $userQuery, $context, $launchContext, $blocks) {
```

Then find the `$thread->messages()->create([...])` block inside (line ~125):

```php
            $userMessage = $thread->messages()->create([
                'message' => [
                    'content' => $userQuery,
                    'type' => ChatMessageType::USER,
                ],
                'files' => [],
                'paa_context' => ! empty($context) ? $context : null,
            ]);
```

Replace the `'message'` array with a built-up form so we can conditionally add `blocks`:

```php
            $messageBlob = [
                'content' => $userQuery,
                'type' => ChatMessageType::USER,
            ];
            // KV inline-pill bubble: persist the original ContentBlock[]
            // when sent. P&A doesn't render the new bubble, but the
            // persistence shape stays consistent across thread types.
            if (is_array($blocks) && count($blocks) > 0) {
                $messageBlob['blocks'] = $blocks;
            }

            $userMessage = $thread->messages()->create([
                'message' => $messageBlob,
                'files' => [],
                'paa_context' => ! empty($context) ? $context : null,
            ]);
```

- [ ] **Step 2: Accept `?array $blocks` in `appendPointAndAskMessage`**

In the same file, find `appendPointAndAskMessage()` (line ~150):

```php
    public function appendPointAndAskMessage(UserThread $thread, string $userQuery): UserChatHistory
    {
        return DB::transaction(function () use ($thread, $userQuery) {
            return $thread->messages()->create([
                'message' => [
                    'content' => $userQuery,
                    'type' => ChatMessageType::USER,
                ],
                'files' => [],
            ]);
        });
    }
```

Replace with:

```php
    public function appendPointAndAskMessage(
        UserThread $thread,
        string $userQuery,
        ?array $blocks = null
    ): UserChatHistory {
        return DB::transaction(function () use ($thread, $userQuery, $blocks) {
            $messageBlob = [
                'content' => $userQuery,
                'type' => ChatMessageType::USER,
            ];
            // KV inline-pill bubble: persist the original ContentBlock[]
            // when sent. Additive — P&A doesn't render the new bubble.
            if (is_array($blocks) && count($blocks) > 0) {
                $messageBlob['blocks'] = $blocks;
            }

            return $thread->messages()->create([
                'message' => $messageBlob,
                'files' => [],
            ]);
        });
    }
```

- [ ] **Step 3: Forward `$blocks` from controller P&A branches**

Open `app/Http/Controllers/Api/Chat/ThreadController.php`. In `store()`, find the P&A branch call (line ~186):

```php
                [$thread, $newUserMessage] = $chatService->openPointAndAskThread(
                    $user,
                    $workspace,
                    $userQuery,
                    $paaContext,
                    [
                        'origin_brand_id' => $streamRequest->input('origin_brand_id'),
                        'origin_brand_name' => $streamRequest->input('origin_brand_name'),
                        'origin_path' => $streamRequest->input('origin_path'),
                        'origin_scope' => LaunchContextHelper::resolveScope($streamRequest->input('origin_path')),
                    ]
                );
```

Replace with (add the new arg as the last parameter):

```php
                [$thread, $newUserMessage] = $chatService->openPointAndAskThread(
                    $user,
                    $workspace,
                    $userQuery,
                    $paaContext,
                    [
                        'origin_brand_id' => $streamRequest->input('origin_brand_id'),
                        'origin_brand_name' => $streamRequest->input('origin_brand_name'),
                        'origin_path' => $streamRequest->input('origin_path'),
                        'origin_scope' => LaunchContextHelper::resolveScope($streamRequest->input('origin_path')),
                    ],
                    is_array($blocks) && count($blocks) > 0 ? $blocks : null
                );
```

In `update()`, find the P&A branch call (line ~427):

```php
                $newUserMessage = $chatService->appendPointAndAskMessage($thread, $userQuery);
```

Replace with:

```php
                $newUserMessage = $chatService->appendPointAndAskMessage(
                    $thread,
                    $userQuery,
                    is_array($blocks) && count($blocks) > 0 ? $blocks : null
                );
```

- [ ] **Step 4: Lint + run unit tests**

Run from `frndos/api`:

```bash
vendor/bin/pint --test app/Http/Controllers/Api/Chat/ThreadController.php app/Services/ChatService.php
php -l app/Http/Controllers/Api/Chat/ThreadController.php
php -l app/Services/ChatService.php
php artisan test tests/Unit/
```

Expected: lint passes, no syntax errors, all unit tests green.

- [ ] **Step 5: Commit**

```bash
git add app/Http/Controllers/Api/Chat/ThreadController.php app/Services/ChatService.php
git commit -m "feat(api): persist message_blocks on Point-and-Ask user-message rows"
```

---

## Phase 3 — Manual smoke + PR prep

### Task 8: Manual smoke against pgAdmin

**Files:** none (verification only)

- [ ] **Step 1: Boot the api locally**

Run from `frndos/api`:

```bash
php artisan serve
```

Leave it running.

- [ ] **Step 2: From the web client (or curl), send a chip-laden message on a KV thread**

Skip if the web side hasn't shipped yet — in that case, simulate via curl:

```bash
# Replace TOKEN and THREAD_ID with valid values.
curl -X POST "http://localhost:8000/api/v1/threads/THREAD_ID/stream" \
  -H "Authorization: Bearer TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "message": "add this on top",
    "message_blocks": [
      {"type":"text","text":"add "},
      {"type":"attachment_ref","id":"att_test"},
      {"type":"text","text":" on top"}
    ],
    "mode": "chat",
    "canvas_mode": "sketch"
  }'
```

- [ ] **Step 3: Verify in pgAdmin (or `psql`)**

Run:

```sql
SELECT message
FROM user_chat_history
WHERE session_id = 'THREAD_ID'
ORDER BY id DESC
LIMIT 2;
```

Expected: the user-row's `message` JSONB has a `blocks` key matching what was sent. The `content` key is the flattened text (`"add  on top"`).

- [ ] **Step 4: Verify the chat-history response also includes `blocks`**

Run:

```bash
curl "http://localhost:8000/api/v1/threads/THREAD_ID" \
  -H "Authorization: Bearer TOKEN" | jq '.chat_history[] | select(.role == "human")'
```

Expected: each user-row entry now includes `blocks: [...]` (when present), `attachments: [...]` (for any image-mime files on that row), and `selections: { base_generation_id, boxes }` (for any KV-edit row).

- [ ] **Step 5: Document the smoke in the PR description (no commit needed)**

---

### Task 9: PR

**Files:** none

- [ ] **Step 1: Push the branch and open a PR**

Run from `frndos/api`:

```bash
git push -u origin HEAD
gh pr create --title "feat(api): persist message_blocks + hydrate KV chat-history user rows" --body "$(cat <<'EOF'
## Summary
- Persists `message_blocks` (the structured ContentBlock[] payload) on `user_chat_history.message` JSONB at all 5 prompt-string sites in `ThreadController` / `ChatService`. Additive — `content` stays for back-compat.
- Closes pre-existing TODOs by emitting hydrated `attachments` (image-mime subset of `$chat->files`) and reshaped `selections` (`{ base_generation_id, boxes }`) on user-role chat-history entries via `ChatHelper::formatChatHistoryEntry()`.
- New: `tests/Unit/Helpers/ChatHelperTest.php` — Pest unit tests covering all three new fields (present + absent + ai-row-omits).

## Why
Pairs with the upcoming web PR that renders the KV user-message bubble as a single rounded card with inline pills (matching the editor 1:1) and persists that structure across refreshes. This PR is the api-side prerequisite — without it the bubble has nothing to hydrate against on refresh.

Service ordering: api first → web second.

Spec: `docs/superpowers/specs/2026-05-06-kv-chat-bubble-inline-pills-design.md`

## Test plan
- [x] Unit tests: `php artisan test tests/Unit/Helpers/ChatHelperTest.php` (7 passed)
- [x] Existing tests: `php artisan test tests/Unit/` (all green)
- [x] Lint: `vendor/bin/pint --test app/Http/Controllers/Api/Chat/ThreadController.php app/Services/ChatService.php app/Helpers/ChatHelper.php`
- [x] Manual smoke (KV thread): pgAdmin shows `blocks` nested in `user_chat_history.message`; `GET /v1/threads/{id}` returns `blocks`, `attachments`, `selections` on user rows.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 2: Wait for CI to go green; share PR URL with the web side so they can rebase against this**

---

## Self-Review Checklist

Before handing off:

- [ ] All 5 prompt-string sites in `ThreadController` thread `$blocks` through to a place that nests it into the `$message` JSONB (controller-direct in main Chat sites, via service signature for KV + P&A).
- [ ] `ChatHelper::formatChatHistoryEntry()` emits `blocks`, `attachments`, `selections` only on `human` role rows; `ai` rows still emit `files` + `tools` etc. as before.
- [ ] No existing test broke (`php artisan test tests/Unit/`).
- [ ] No DB migration. No backfill. Legacy rows stay byte-identical.
- [ ] All commits are TDD-style (test → run → fail → implement → run → green → commit).
