# KV Chat Inline Chips Editor (Lexical) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the KV Generator chat input's stacked rows (selection chip / attachment chips / `<input>`) with a single Lexical-powered rich editor where chips render inline as decorator nodes. Send messages as a multi-modal `ContentBlock[]` payload; backend flattens to today's plain-prose behavior in Phase 1, with no model regression.

**Architecture:** Two-service change — Laravel `api/` accepts a new optional JSON `message_blocks` field on the stream endpoint and flattens it to the existing `message` string before invoking the model (zero behavior change). Web introduces a Lexical editor with two custom decorator nodes (`SelectionRefNode`, `AttachmentRefNode`), a `useChipSync` hook for bidirectional state binding with the parent canvas state, and a `serializeToContentBlocks` helper for the wire format. Whole feature ships behind a PostHog flag (`kv-inline-chips-editor`).

**Tech Stack:** Web — Next.js 15, React 19, TypeScript, Lexical (new dep), PostHog flags, Playwright e2e. API — Laravel 13, PHP 8.5, Pest.

**Spec reference:** [docs/superpowers/specs/2026-05-05-kv-chat-inline-chips-design.md](../specs/2026-05-05-kv-chat-inline-chips-design.md)

**Service ordering:** API first (accept + flatten `message_blocks`, additive only — no behavior change), web second (consumes the new field).

---

## File Structure

**API — `frndos/api`:**
- Modify: `app/Http/Controllers/Api/Chat/ThreadController.php` — methods `store()` (line ~160) and `update()` (line ~398). Read `message_blocks` if present, flatten to plain text, replace `$messageData['message']` body with the flattened text before passing to the AI service.
- Modify: `app/Http/Requests/StreamChatRequest.php` — add validation rules for the new optional `message_blocks` array.
- Create: `tests/Feature/Studio/KvChatMessageBlocksTest.php` — Pest tests for flatten behavior + schema validation + ref-id integrity.

**Web — `frndos/web`:**
- Create: `src/types/kvChatBlocks.ts` — `ContentBlock` discriminated union + helpers.
- Create: `src/components/studio/kv-generator/lexical/SelectionRefNode.tsx` — Lexical decorator node.
- Create: `src/components/studio/kv-generator/lexical/AttachmentRefNode.tsx` — Lexical decorator node.
- Create: `src/components/studio/kv-generator/lexical/serializeToContentBlocks.ts` — editor state → blocks.
- Create: `src/components/studio/kv-generator/lexical/blocksToEditorState.ts` — blocks → initial editor state (for hydration / future).
- Create: `src/components/studio/kv-generator/lexical/useChipSync.ts` — bidirectional state ↔ editor binding.
- Create: `src/components/studio/kv-generator/lexical/KvLexicalEditor.tsx` — composer + plugins + ContentEditable.
- Create: `src/components/studio/kv-generator/lexical/KvLexicalEditor.stories.tsx` — Storybook story for visual smoke.
- Modify: `src/hooks/useKvStream.ts` (line 699) — `send()` accepts `string | ContentBlock[]`; new optional `message_blocks` JSON field on the request.
- Modify: `src/components/studio/kv-generator/KvChat.tsx` (lines 1020-1170) — gate on PostHog flag; if on, render `KvLexicalEditor`; if off, render existing input.
- Modify: `src/components/studio/kv-generator/SelectionSummaryModal.tsx` — accept optional `focusBoxId` prop.
- Create: `tests/e2e/studio-kv-inline-chips.spec.ts` — Playwright e2e for happy paths.

---

## Phase 1 — API

### Task 1: Discovery — confirm current request shape

**Files:**
- Read-only: `app/Http/Controllers/Api/Chat/ThreadController.php`, `app/Http/Requests/StreamChatRequest.php`

- [ ] **Step 1: Trace `message` field handling in `ThreadController::update()` and `store()`**

Run from `frndos/api`:

```bash
git grep -nE "->input\('message'\)|messageData\[" app/Http/Controllers/Api/Chat/ThreadController.php app/Http/Requests/StreamChatRequest.php
```

Document the exact line where `message` is read off the request and where it is written into `$messageData` (or equivalent payload to the AI service). This is the line the Phase-1 flatten will overwrite.

- [ ] **Step 2: Confirm `attachments[]` and `bounding_boxes[]` are read by id today**

```bash
git grep -nE "'attachments'|'bounding_boxes'" app/Http/Controllers/Api/Chat/ app/Http/Requests/
```

Confirm both arrays carry an `id` property per entry. If one doesn't, raise it — the chip-by-id binding requires both arrays to be id-keyed. (Spec assumes yes; `useKvStream.send` already passes id.)

- [ ] **Step 3: Note discovery in PR description**

No commit yet. Findings inform Tasks 2-4.

---

### Task 2: Add validation rules for `message_blocks`

**Files:**
- Modify: `app/Http/Requests/StreamChatRequest.php`
- Test: `tests/Feature/Studio/KvChatMessageBlocksTest.php`

- [ ] **Step 1: Write the failing validation test**

Create `tests/Feature/Studio/KvChatMessageBlocksTest.php`:

```php
<?php

namespace Tests\Feature\Studio;

use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class KvChatMessageBlocksTest extends TestCase
{
    use RefreshDatabase;

    public function test_accepts_message_blocks_array_with_text_and_refs(): void
    {
        $user = User::factory()->create();
        $this->actingAs($user);

        $response = $this->postJson('/v1/threads/stream', [
            'message' => 'fallback prose',
            'message_blocks' => [
                ['type' => 'text', 'text' => 'Make '],
                ['type' => 'selection_ref', 'id' => 'box-1'],
                ['type' => 'text', 'text' => ' brighter'],
            ],
            'mode' => 'image',
            'canvas_mode' => 'sketch',
            'bounding_boxes' => [
                ['id' => 'box-1', 'x' => 0.1, 'y' => 0.1, 'width' => 0.2, 'height' => 0.2],
            ],
            'base_generation_id' => 'gen-1',
        ]);

        // We expect the request to *validate* and proceed past validation.
        // The exact downstream outcome is asserted in Task 3.
        $response->assertStatus(200);
    }

    public function test_rejects_message_blocks_with_unknown_type(): void
    {
        $user = User::factory()->create();
        $this->actingAs($user);

        $response = $this->postJson('/v1/threads/stream', [
            'message' => 'fallback',
            'message_blocks' => [
                ['type' => 'bogus_type', 'text' => 'no'],
            ],
            'mode' => 'image',
            'canvas_mode' => 'sketch',
        ]);

        $response->assertStatus(422)
            ->assertJsonValidationErrors(['message_blocks.0.type']);
    }

    public function test_rejects_text_block_without_text_field(): void
    {
        $user = User::factory()->create();
        $this->actingAs($user);

        $response = $this->postJson('/v1/threads/stream', [
            'message' => 'fallback',
            'message_blocks' => [
                ['type' => 'text'],
            ],
            'mode' => 'image',
            'canvas_mode' => 'sketch',
        ]);

        $response->assertStatus(422)
            ->assertJsonValidationErrors(['message_blocks.0.text']);
    }

    public function test_rejects_ref_block_without_id(): void
    {
        $user = User::factory()->create();
        $this->actingAs($user);

        $response = $this->postJson('/v1/threads/stream', [
            'message' => 'fallback',
            'message_blocks' => [
                ['type' => 'selection_ref'],
            ],
            'mode' => 'image',
            'canvas_mode' => 'sketch',
        ]);

        $response->assertStatus(422)
            ->assertJsonValidationErrors(['message_blocks.0.id']);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd api && ./vendor/bin/pest tests/Feature/Studio/KvChatMessageBlocksTest.php
```

Expected: all 4 tests FAIL — validation rules for `message_blocks` don't exist yet.

- [ ] **Step 3: Add validation rules to `StreamChatRequest`**

In `app/Http/Requests/StreamChatRequest.php`, extend the `rules()` method with:

```php
'message_blocks' => ['nullable', 'array'],
'message_blocks.*.type' => ['required_with:message_blocks', 'string', 'in:text,selection_ref,attachment_ref'],
'message_blocks.*.text' => ['required_if:message_blocks.*.type,text', 'string'],
'message_blocks.*.id' => ['required_if:message_blocks.*.type,selection_ref', 'required_if:message_blocks.*.type,attachment_ref', 'string'],
```

- [ ] **Step 4: Run validation tests to verify they pass**

```bash
cd api && ./vendor/bin/pest tests/Feature/Studio/KvChatMessageBlocksTest.php --filter "rejects|accepts"
```

Expected: all 4 PASS.

- [ ] **Step 5: Commit**

```bash
cd api
git add app/Http/Requests/StreamChatRequest.php tests/Feature/Studio/KvChatMessageBlocksTest.php
git commit -m "feat(kv-chat): validate optional message_blocks field on stream POST"
```

---

### Task 3: Flatten `message_blocks` to `message` text in `ThreadController::update()` and `store()`

**Files:**
- Modify: `app/Http/Controllers/Api/Chat/ThreadController.php`
- Test: `tests/Feature/Studio/KvChatMessageBlocksTest.php`

- [ ] **Step 1: Write the failing flatten test**

Append to `tests/Feature/Studio/KvChatMessageBlocksTest.php`:

```php
public function test_flattens_message_blocks_overrides_message_string_on_update(): void
{
    $user = User::factory()->create();
    $this->actingAs($user);

    // Spy on AI-service call to capture the flattened prompt.
    // (Use whatever existing mock pattern the codebase uses for the
    // chat stream — check tests/Feature/Chat/ for examples; if a Mock
    // class exists for the AI client, reuse it. Otherwise, assert
    // against the persisted UserChatHistory row's `message` field.)

    $thread = \App\Models\Thread::factory()->for($user)->create();

    $response = $this->postJson("/v1/threads/{$thread->id}/stream", [
        'message' => 'IGNORED LEGACY STRING',
        'message_blocks' => [
            ['type' => 'text', 'text' => 'Make '],
            ['type' => 'selection_ref', 'id' => 'box-1'],
            ['type' => 'text', 'text' => ' brighter'],
        ],
        'mode' => 'image',
        'canvas_mode' => 'sketch',
        'bounding_boxes' => [
            ['id' => 'box-1', 'x' => 0.1, 'y' => 0.1, 'width' => 0.2, 'height' => 0.2],
        ],
        'base_generation_id' => 'gen-1',
    ]);

    $response->assertStatus(200);

    // Assert the persisted user-row carries the flattened text, not the
    // legacy string. Adjust the field path if the codebase stores the
    // user message under a different key.
    $userRow = \App\Models\UserChatHistory::where('thread_id', $thread->id)
        ->where('role', 'user')
        ->latest('id')
        ->first();
    $this->assertNotNull($userRow);
    $this->assertSame('Make  brighter', $userRow->message ?? data_get($userRow->message_data, 'message'));
}

public function test_falls_back_to_message_when_blocks_absent(): void
{
    $user = User::factory()->create();
    $this->actingAs($user);

    $thread = \App\Models\Thread::factory()->for($user)->create();

    $response = $this->postJson("/v1/threads/{$thread->id}/stream", [
        'message' => 'plain prose only',
        'mode' => 'chat',
        'canvas_mode' => 'sketch',
    ]);

    $response->assertStatus(200);

    $userRow = \App\Models\UserChatHistory::where('thread_id', $thread->id)
        ->where('role', 'user')
        ->latest('id')
        ->first();
    $this->assertSame('plain prose only', $userRow->message ?? data_get($userRow->message_data, 'message'));
}
```

> **Note for the implementer:** The exact field name (`message` vs nested `message_data`) and the AI-service mock pattern are project-specific. Look at `tests/Feature/Chat/` for an existing `ThreadController::update()` test and mirror its mock + assertion pattern. The behavioral assertion ("flattened prose ends up where today's plain `message` ends up") is the contract; the field path is a detail to mirror.

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd api && ./vendor/bin/pest tests/Feature/Studio/KvChatMessageBlocksTest.php --filter "flattens|falls_back"
```

Expected: `flattens` FAILS (controller still uses the raw `message` string), `falls_back` may pass already.

- [ ] **Step 3: Add a private flatten helper to `ThreadController`**

In `app/Http/Controllers/Api/Chat/ThreadController.php`, add:

```php
/**
 * Flatten a ContentBlock[] payload to plain prose. ref blocks become
 * empty strings — Phase 1 preserves today's model behavior. Phase 2
 * (separate PR) will replace refs with labels (`Image A`, `Region 1`).
 *
 * @param  array<int, array{type: string, text?: string, id?: string}>  $blocks
 */
private function flattenMessageBlocks(array $blocks): string
{
    $parts = [];
    foreach ($blocks as $block) {
        $parts[] = match ($block['type'] ?? null) {
            'text' => (string) ($block['text'] ?? ''),
            'selection_ref', 'attachment_ref' => '',
            default => '',
        };
    }
    return implode('', $parts);
}
```

- [ ] **Step 4: Use the helper in `update()` and `store()`**

In both `update()` and `store()`, immediately after the validated request data is read, replace the raw `message` value when `message_blocks` is present. Concretely, find the line that does something like `$message = $request->input('message');` (or where `messageData['message']` is built) and prepend:

```php
$blocks = $request->input('message_blocks');
if (is_array($blocks) && count($blocks) > 0) {
    $message = $this->flattenMessageBlocks($blocks);
} else {
    $message = (string) $request->input('message', '');
}
```

(Adapt the variable name to whatever the existing controller uses.)

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd api && ./vendor/bin/pest tests/Feature/Studio/KvChatMessageBlocksTest.php
```

Expected: all tests PASS.

- [ ] **Step 6: Run the full chat thread suite to confirm no regression**

```bash
cd api && ./vendor/bin/pest tests/Feature/Chat/
```

Expected: all existing chat tests still pass — Phase-1 flatten is purely additive.

- [ ] **Step 7: Commit**

```bash
cd api
git add app/Http/Controllers/Api/Chat/ThreadController.php tests/Feature/Studio/KvChatMessageBlocksTest.php
git commit -m "feat(kv-chat): flatten message_blocks to plain prose on stream POST"
```

---

### Task 4: Validate ref ids resolve against `attachments` / `bounding_boxes`

**Files:**
- Modify: `app/Http/Controllers/Api/Chat/ThreadController.php`
- Test: `tests/Feature/Studio/KvChatMessageBlocksTest.php`

- [ ] **Step 1: Write the failing integrity test**

Append to `tests/Feature/Studio/KvChatMessageBlocksTest.php`:

```php
public function test_rejects_selection_ref_with_unknown_box_id(): void
{
    $user = User::factory()->create();
    $this->actingAs($user);

    $response = $this->postJson('/v1/threads/stream', [
        'message' => 'fallback',
        'message_blocks' => [
            ['type' => 'selection_ref', 'id' => 'box-DOES-NOT-EXIST'],
        ],
        'mode' => 'image',
        'canvas_mode' => 'sketch',
        'bounding_boxes' => [
            ['id' => 'box-1', 'x' => 0.1, 'y' => 0.1, 'width' => 0.2, 'height' => 0.2],
        ],
        'base_generation_id' => 'gen-1',
    ]);

    $response->assertStatus(422)
        ->assertJsonValidationErrors(['message_blocks.0.id']);
}

public function test_rejects_attachment_ref_with_unknown_attachment_id(): void
{
    $user = User::factory()->create();
    $this->actingAs($user);

    $response = $this->postJson('/v1/threads/stream', [
        'message' => 'fallback',
        'message_blocks' => [
            ['type' => 'attachment_ref', 'id' => 'file-DOES-NOT-EXIST'],
        ],
        'mode' => 'image',
        'canvas_mode' => 'sketch',
        'attachments' => [
            ['id' => 'file-1', 'name' => 'a.png', 'mime_type' => 'image/png', 'data_base64' => 'AA=='],
        ],
    ]);

    $response->assertStatus(422)
        ->assertJsonValidationErrors(['message_blocks.0.id']);
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
cd api && ./vendor/bin/pest tests/Feature/Studio/KvChatMessageBlocksTest.php --filter "rejects_(selection|attachment)_ref_with_unknown"
```

Expected: both FAIL — validation passes today because we don't cross-check ids.

- [ ] **Step 3: Add a custom validator after the static rules**

In `StreamChatRequest::withValidator()` (add the method if it doesn't exist):

```php
public function withValidator(\Illuminate\Validation\Validator $validator): void
{
    $validator->after(function ($validator) {
        $blocks = $this->input('message_blocks');
        if (!is_array($blocks)) return;

        $boxIds = collect($this->input('bounding_boxes', []))
            ->pluck('id')
            ->filter()
            ->all();
        $attachmentIds = collect($this->input('attachments', []))
            ->pluck('id')
            ->filter()
            ->all();

        foreach ($blocks as $i => $block) {
            $type = $block['type'] ?? null;
            $id = $block['id'] ?? null;
            if ($type === 'selection_ref' && !in_array($id, $boxIds, true)) {
                $validator->errors()->add(
                    "message_blocks.{$i}.id",
                    "Unknown selection_ref id '{$id}' — must match a bounding_boxes entry."
                );
            }
            if ($type === 'attachment_ref' && !in_array($id, $attachmentIds, true)) {
                $validator->errors()->add(
                    "message_blocks.{$i}.id",
                    "Unknown attachment_ref id '{$id}' — must match an attachments entry."
                );
            }
        }
    });
}
```

- [ ] **Step 4: Run to verify the integrity tests pass**

```bash
cd api && ./vendor/bin/pest tests/Feature/Studio/KvChatMessageBlocksTest.php
```

Expected: all 8 tests PASS.

- [ ] **Step 5: Commit**

```bash
cd api
git add app/Http/Requests/StreamChatRequest.php tests/Feature/Studio/KvChatMessageBlocksTest.php
git commit -m "feat(kv-chat): validate message_blocks ref ids against attachments and bounding_boxes"
```

---

### Task 5: Open the API PR

- [ ] **Step 1: Push branch and open PR**

```bash
cd api
git push -u origin "$(git branch --show-current)"
gh pr create --title "feat(kv-chat): accept optional message_blocks on stream POST (Phase 1)" --body "$(cat <<'EOF'
## Summary
- Adds optional JSON `message_blocks` field on `POST /v1/threads/{thread}/stream` and `POST /v1/threads/stream`.
- When present, blocks are flattened to plain prose (text blocks concatenated; ref blocks → empty string) and used in place of the legacy `message` string. **Identical model behavior to today** — Phase 1 is purely additive plumbing.
- Validates schema (allowed types, required fields per type) and that `selection_ref` / `attachment_ref` ids cross-resolve against the existing `bounding_boxes[]` / `attachments[]` arrays.
- Phase 2 (separate PR, future): backend renders refs as labels (`Image A`, `Region 1`) for multi-attachment / multi-selection disambiguation.

## Test plan
- [ ] CI green
- [ ] `./vendor/bin/pest tests/Feature/Studio/KvChatMessageBlocksTest.php` passes
- [ ] `./vendor/bin/pest tests/Feature/Chat/` regression suite passes
- [ ] Manual: POST a request with the legacy `message` field only — model behavior matches main

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Phase 2 — Web foundation

### Task 6: Install Lexical dependencies

**Files:**
- Modify: `web/package.json`
- Modify: `web/bun.lockb` (auto-generated)

- [ ] **Step 1: Install Lexical core + React bindings**

```bash
cd web
bun add lexical@^0.21.0 @lexical/react@^0.21.0 @lexical/utils@^0.21.0
```

(If your `bun` version is unfamiliar with these, swap to `npm install lexical @lexical/react @lexical/utils` or whatever the lockfile uses. Check the lockfile name first: `web/bun.lockb` → bun, `package-lock.json` → npm, `yarn.lock` → yarn.)

- [ ] **Step 2: Verify install**

```bash
cd web
bun pm ls | grep -E "^(lexical|@lexical)"
```

Expected: three lines confirming `lexical`, `@lexical/react`, `@lexical/utils`.

- [ ] **Step 3: Type-check the workspace to confirm no breakage**

```bash
cd web
bun run lint
```

Expected: clean (or matches existing main's lint output — Lexical is unused at this point).

- [ ] **Step 4: Commit**

```bash
cd web
git add package.json bun.lockb
git commit -m "chore(web): add Lexical (lexical, @lexical/react, @lexical/utils) for KV chat editor"
```

---

### Task 7: Add `ContentBlock` type

**Files:**
- Create: `src/types/kvChatBlocks.ts`

- [ ] **Step 1: Write the type module**

Create `web/src/types/kvChatBlocks.ts`:

```ts
/**
 * Wire format for the KV chat stream POST body's `message_blocks` field.
 * Walks 1:1 with the Lexical editor's paragraph children. The api flattens
 * these to plain prose for the model in Phase 1; Phase 2 will render refs
 * as labels (Image A, Region 1) for multi-ref disambiguation.
 */
export type ContentBlock =
  | { type: "text"; text: string }
  | { type: "selection_ref"; id: string }
  | { type: "attachment_ref"; id: string };

/**
 * The send() prompt argument — a plain string (legacy callers) or an
 * array of ContentBlocks (rich editor). Backend prefers blocks when both
 * are sent (we double-write `message` for backwards compat).
 */
export type ChatPrompt = string | ContentBlock[];

export const isContentBlockArray = (p: ChatPrompt): p is ContentBlock[] =>
  Array.isArray(p);

/**
 * Flatten ContentBlock[] to plain prose, mirroring the api's flatten.
 * Used as a backwards-compat double-write so `message` stays populated
 * even when `message_blocks` is sent.
 */
export const flattenBlocksToText = (blocks: ContentBlock[]): string =>
  blocks
    .map((b) => (b.type === "text" ? b.text : ""))
    .join("");
```

- [ ] **Step 2: Lint and commit**

```bash
cd web
bun run lint
git add src/types/kvChatBlocks.ts
git commit -m "feat(kv-chat): add ContentBlock type for inline-chips wire format"
```

---

### Task 8: `serializeToContentBlocks` helper

**Files:**
- Create: `src/components/studio/kv-generator/lexical/serializeToContentBlocks.ts`

- [ ] **Step 1: Write the serializer**

Create `web/src/components/studio/kv-generator/lexical/serializeToContentBlocks.ts`:

```ts
import { $getRoot, $isParagraphNode, $isTextNode, type EditorState } from "lexical";
import { type ContentBlock } from "@/types/kvChatBlocks";
import { $isSelectionRefNode } from "./SelectionRefNode";
import { $isAttachmentRefNode } from "./AttachmentRefNode";

/**
 * Walk a Lexical editor state's first paragraph and emit one ContentBlock
 * per child node. Consecutive text blocks are merged. Empty leading and
 * trailing text blocks are stripped. Returns an empty array for an empty
 * editor.
 */
export function serializeToContentBlocks(state: EditorState): ContentBlock[] {
  const out: ContentBlock[] = [];

  state.read(() => {
    const root = $getRoot();
    const para = root.getFirstChild();
    if (!para || !$isParagraphNode(para)) return;

    for (const child of para.getChildren()) {
      if ($isTextNode(child)) {
        const text = child.getTextContent();
        if (text.length === 0) continue;
        const last = out[out.length - 1];
        if (last && last.type === "text") {
          last.text += text;
        } else {
          out.push({ type: "text", text });
        }
      } else if ($isSelectionRefNode(child)) {
        out.push({ type: "selection_ref", id: child.getRefId() });
      } else if ($isAttachmentRefNode(child)) {
        out.push({ type: "attachment_ref", id: child.getRefId() });
      }
      // Other node types (line breaks, etc.) are intentionally dropped —
      // the editor is single-paragraph and shift+enter produces a soft
      // line break that we treat as a space when needed.
    }
  });

  // Strip empty edge text blocks (the user's actual leading/trailing
  // whitespace becomes meaningful — preserve it; only strip blocks that
  // are length 0, which the loop already skips).
  return out;
}
```

- [ ] **Step 2: Lint and commit (the SelectionRefNode/AttachmentRefNode imports won't resolve yet — we land them in Tasks 9 and 10. The next two tasks fix the lint error.)**

```bash
cd web
git add src/components/studio/kv-generator/lexical/serializeToContentBlocks.ts
git commit -m "feat(kv-chat): add serializeToContentBlocks helper for Lexical → wire format"
```

> **Implementer note:** This commit will leave the file with broken imports (the Ref nodes don't exist yet). That's fine — Tasks 9 and 10 land them and the workspace becomes clean. Do not run `bun run lint` between Task 8 and 10.

---

### Task 9: `SelectionRefNode` Lexical decorator node

**Files:**
- Create: `src/components/studio/kv-generator/lexical/SelectionRefNode.tsx`

- [ ] **Step 1: Write the decorator node + chip component**

Create `web/src/components/studio/kv-generator/lexical/SelectionRefNode.tsx`:

```tsx
"use client";

import { DecoratorNode, type EditorConfig, type LexicalNode, type NodeKey, type SerializedLexicalNode, type Spread } from "lexical";
import { SelectionPlus, X } from "@phosphor-icons/react";
import { type JSX } from "react";

export type SerializedSelectionRefNode = Spread<
  { refId: string; index: number; type: "selection-ref"; version: 1 },
  SerializedLexicalNode
>;

/**
 * Lexical decorator node that renders a chip pill inline with text,
 * referencing a bounding-box id from parent state. The chip is the
 * single source of truth for the user-facing presence; deletion in the
 * editor (backspace at boundary or click on ✕) calls back into parent
 * state to clear the corresponding box.
 */
export class SelectionRefNode extends DecoratorNode<JSX.Element> {
  __refId: string;
  __index: number;

  static getType(): string {
    return "selection-ref";
  }

  static clone(node: SelectionRefNode): SelectionRefNode {
    return new SelectionRefNode(node.__refId, node.__index, node.__key);
  }

  constructor(refId: string, index: number, key?: NodeKey) {
    super(key);
    this.__refId = refId;
    this.__index = index;
  }

  getRefId(): string {
    return this.__refId;
  }

  isInline(): boolean {
    return true;
  }

  isKeyboardSelectable(): boolean {
    return true;
  }

  createDOM(_config: EditorConfig): HTMLElement {
    const span = document.createElement("span");
    span.style.display = "inline-block";
    span.style.verticalAlign = "middle";
    span.style.margin = "0 4px";
    return span;
  }

  updateDOM(): false {
    return false;
  }

  decorate(): JSX.Element {
    return <SelectionRefChip refId={this.__refId} index={this.__index} nodeKey={this.__key} />;
  }

  static importJSON(serialized: SerializedSelectionRefNode): SelectionRefNode {
    return $createSelectionRefNode(serialized.refId, serialized.index);
  }

  exportJSON(): SerializedSelectionRefNode {
    return {
      type: "selection-ref",
      refId: this.__refId,
      index: this.__index,
      version: 1,
    };
  }
}

/**
 * Chip handlers are passed via React context so the decorator node
 * (which doesn't accept props directly) can call them. The provider
 * lives inside KvLexicalEditor.
 */
import { createContext, useContext } from "react";

type SelectionRefHandlers = {
  onRemove: (refId: string) => void;
  onClick: (refId: string) => void;
};

export const SelectionRefHandlersContext = createContext<SelectionRefHandlers | null>(null);

function SelectionRefChip({ refId, index, nodeKey }: { refId: string; index: number; nodeKey: NodeKey }) {
  const handlers = useContext(SelectionRefHandlersContext);
  return (
    <span
      contentEditable={false}
      data-lexical-decorator
      data-node-key={nodeKey}
      className="inline-flex h-7 items-center gap-1.5 rounded-xl border border-[rgba(255,255,255,0.08)] bg-[rgba(255,255,255,0.05)] pl-1.5 pr-1 align-middle"
    >
      <SelectionPlus size={14} className="text-text-inverse" />
      <button
        type="button"
        onClick={() => handlers?.onClick(refId)}
        className="font-geist text-textXsMedium font-medium leading-[1.4] tracking-[-0.12px] text-text-inverse"
      >
        Region {index}
      </button>
      <button
        type="button"
        onClick={() => handlers?.onRemove(refId)}
        aria-label={`Remove Region ${index}`}
        className="ml-1 flex h-4 w-4 items-center justify-center rounded-full text-text-inverse-subtle transition-colors hover:bg-[rgba(255,255,255,0.08)] hover:text-text-inverse"
      >
        <X size={10} />
      </button>
    </span>
  );
}

export function $createSelectionRefNode(refId: string, index: number): SelectionRefNode {
  return new SelectionRefNode(refId, index);
}

export function $isSelectionRefNode(node: LexicalNode | null | undefined): node is SelectionRefNode {
  return node instanceof SelectionRefNode;
}
```

- [ ] **Step 2: Lint**

```bash
cd web
bun run lint --quiet src/components/studio/kv-generator/lexical/SelectionRefNode.tsx
```

Expected: clean. (The `serializeToContentBlocks.ts` file will now resolve its `SelectionRefNode` import; only `AttachmentRefNode` import stays broken until Task 10.)

- [ ] **Step 3: Commit**

```bash
cd web
git add src/components/studio/kv-generator/lexical/SelectionRefNode.tsx
git commit -m "feat(kv-chat): add SelectionRefNode Lexical decorator with chip + handlers context"
```

---

### Task 10: `AttachmentRefNode` Lexical decorator node

**Files:**
- Create: `src/components/studio/kv-generator/lexical/AttachmentRefNode.tsx`

- [ ] **Step 1: Write the decorator node**

Create `web/src/components/studio/kv-generator/lexical/AttachmentRefNode.tsx`:

```tsx
"use client";

import { DecoratorNode, type EditorConfig, type LexicalNode, type NodeKey, type SerializedLexicalNode, type Spread } from "lexical";
import { X } from "@phosphor-icons/react";
import { createContext, useContext, type JSX } from "react";

export type SerializedAttachmentRefNode = Spread<
  { refId: string; type: "attachment-ref"; version: 1 },
  SerializedLexicalNode
>;

type AttachmentRefHandlers = {
  onRemove: (refId: string) => void;
  /** Resolves a refId to its display data — name + thumbnail URL.
   *  Lifted out so the node doesn't have to duplicate the parent
   *  attachments[] array; the chip just looks up by id at render time. */
  resolve: (refId: string) => { name: string; thumbnailUrl?: string } | null;
};

export const AttachmentRefHandlersContext = createContext<AttachmentRefHandlers | null>(null);

export class AttachmentRefNode extends DecoratorNode<JSX.Element> {
  __refId: string;

  static getType(): string {
    return "attachment-ref";
  }

  static clone(node: AttachmentRefNode): AttachmentRefNode {
    return new AttachmentRefNode(node.__refId, node.__key);
  }

  constructor(refId: string, key?: NodeKey) {
    super(key);
    this.__refId = refId;
  }

  getRefId(): string {
    return this.__refId;
  }

  isInline(): boolean {
    return true;
  }

  isKeyboardSelectable(): boolean {
    return true;
  }

  createDOM(_config: EditorConfig): HTMLElement {
    const span = document.createElement("span");
    span.style.display = "inline-block";
    span.style.verticalAlign = "middle";
    span.style.margin = "0 4px";
    return span;
  }

  updateDOM(): false {
    return false;
  }

  decorate(): JSX.Element {
    return <AttachmentRefChip refId={this.__refId} nodeKey={this.__key} />;
  }

  static importJSON(serialized: SerializedAttachmentRefNode): AttachmentRefNode {
    return $createAttachmentRefNode(serialized.refId);
  }

  exportJSON(): SerializedAttachmentRefNode {
    return {
      type: "attachment-ref",
      refId: this.__refId,
      version: 1,
    };
  }
}

function AttachmentRefChip({ refId, nodeKey }: { refId: string; nodeKey: NodeKey }) {
  const handlers = useContext(AttachmentRefHandlersContext);
  const resolved = handlers?.resolve(refId) ?? null;
  // If parent state cleared the attachment but the chip hasn't been
  // pruned yet (race between React state and Lexical sync), render an
  // empty span so we don't crash. useChipSync will remove the node on
  // the next tick.
  if (!resolved) return <span data-lexical-decorator data-node-key={nodeKey} />;

  return (
    <span
      contentEditable={false}
      data-lexical-decorator
      data-node-key={nodeKey}
      className="inline-flex h-7 max-w-[180px] items-center gap-1.5 rounded-xl border border-[rgba(255,255,255,0.08)] bg-[rgba(255,255,255,0.05)] pl-1 pr-1 align-middle"
    >
      {resolved.thumbnailUrl ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img src={resolved.thumbnailUrl} alt="" className="h-5 w-5 shrink-0 rounded-md object-cover" />
      ) : (
        <span className="h-5 w-5 shrink-0 rounded-md bg-[rgba(255,255,255,0.08)]" />
      )}
      <span
        className="truncate font-geist text-textXsMedium font-medium leading-[1.4] tracking-[-0.12px] text-text-inverse"
        title={resolved.name}
      >
        {resolved.name}
      </span>
      <button
        type="button"
        onClick={() => handlers?.onRemove(refId)}
        aria-label={`Remove ${resolved.name}`}
        className="ml-1 flex h-4 w-4 items-center justify-center rounded-full text-text-inverse-subtle transition-colors hover:bg-[rgba(255,255,255,0.08)] hover:text-text-inverse"
      >
        <X size={10} />
      </button>
    </span>
  );
}

export function $createAttachmentRefNode(refId: string): AttachmentRefNode {
  return new AttachmentRefNode(refId);
}

export function $isAttachmentRefNode(node: LexicalNode | null | undefined): node is AttachmentRefNode {
  return node instanceof AttachmentRefNode;
}
```

- [ ] **Step 2: Lint the full lexical/ directory**

```bash
cd web
bun run lint -- src/components/studio/kv-generator/lexical/
```

Expected: clean. The `serializeToContentBlocks.ts` imports now all resolve.

- [ ] **Step 3: Commit**

```bash
cd web
git add src/components/studio/kv-generator/lexical/AttachmentRefNode.tsx
git commit -m "feat(kv-chat): add AttachmentRefNode Lexical decorator with chip + handlers context"
```

---

### Task 11: `useChipSync` hook

**Files:**
- Create: `src/components/studio/kv-generator/lexical/useChipSync.ts`

- [ ] **Step 1: Write the sync hook**

Create `web/src/components/studio/kv-generator/lexical/useChipSync.ts`:

```ts
import { useEffect } from "react";
import { useLexicalComposerContext } from "@lexical/react/LexicalComposerContext";
import { $getRoot, $getSelection, $isParagraphNode, $isRangeSelection } from "lexical";
import { $createSelectionRefNode, $isSelectionRefNode, SelectionRefNode } from "./SelectionRefNode";
import { $createAttachmentRefNode, $isAttachmentRefNode, AttachmentRefNode } from "./AttachmentRefNode";

type Box = { id: string };
type Attachment = { id: string };

/**
 * Bidirectional binding between parent canvas/attachment state and the
 * editor's chip nodes. Parent state is the source of truth.
 *
 * - When `boxes` adds/removes ids, this hook adds/removes
 *   SelectionRefNodes in the editor accordingly. New chips insert at
 *   the current cursor position (or end of paragraph if no focus).
 * - When `attachments` adds/removes ids, same for AttachmentRefNodes.
 *
 * Chip-initiated removals (chip ✕ click, backspace at chip boundary)
 * happen *outside* this hook — the chip's `onRemove` handler calls
 * back into parent state, which then triggers this effect to mirror
 * the removal in the editor (idempotent: if already removed, no-op).
 */
export function useChipSync({
  boxes,
  attachments,
}: {
  boxes: Box[];
  attachments: Attachment[];
}) {
  const [editor] = useLexicalComposerContext();

  // Sync selection chips
  useEffect(() => {
    editor.update(() => {
      const root = $getRoot();
      const para = root.getFirstChild();
      if (!para || !$isParagraphNode(para)) return;

      const desiredIds = boxes.map((b) => b.id);
      const presentNodes: SelectionRefNode[] = [];
      for (const child of para.getChildren()) {
        if ($isSelectionRefNode(child)) presentNodes.push(child);
      }
      const presentIds = presentNodes.map((n) => n.getRefId());

      // Remove nodes whose id is no longer in desiredIds
      for (const node of presentNodes) {
        if (!desiredIds.includes(node.getRefId())) {
          node.remove();
        }
      }

      // Insert nodes for ids not yet present, with their 1-based index
      // matching their position in `boxes` (draw order).
      desiredIds.forEach((id, i) => {
        if (presentIds.includes(id)) return;
        const node = $createSelectionRefNode(id, i + 1);
        const sel = $getSelection();
        if ($isRangeSelection(sel) && sel.isCollapsed()) {
          sel.insertNodes([node]);
        } else {
          para.append(node);
        }
      });

      // Reindex remaining nodes — if a middle box was removed, indices
      // need to shift so labels stay 1, 2, 3 in draw order.
      const refreshed: SelectionRefNode[] = [];
      for (const child of para.getChildren()) {
        if ($isSelectionRefNode(child)) refreshed.push(child);
      }
      refreshed.forEach((node, i) => {
        const desiredIndex = desiredIds.indexOf(node.getRefId()) + 1;
        if (desiredIndex > 0 && (node as SelectionRefNode & { __index: number }).__index !== desiredIndex) {
          // Lexical nodes are immutable in transactions — replace.
          const replacement = $createSelectionRefNode(node.getRefId(), desiredIndex);
          node.replace(replacement);
        }
      });
    });
  }, [editor, boxes]);

  // Sync attachment chips
  useEffect(() => {
    editor.update(() => {
      const root = $getRoot();
      const para = root.getFirstChild();
      if (!para || !$isParagraphNode(para)) return;

      const desiredIds = attachments.map((a) => a.id);
      const presentNodes: AttachmentRefNode[] = [];
      for (const child of para.getChildren()) {
        if ($isAttachmentRefNode(child)) presentNodes.push(child);
      }

      for (const node of presentNodes) {
        if (!desiredIds.includes(node.getRefId())) {
          node.remove();
        }
      }

      const presentIds = presentNodes.map((n) => n.getRefId());
      for (const id of desiredIds) {
        if (presentIds.includes(id)) continue;
        const node = $createAttachmentRefNode(id);
        const sel = $getSelection();
        if ($isRangeSelection(sel) && sel.isCollapsed()) {
          sel.insertNodes([node]);
        } else {
          para.append(node);
        }
      }
    });
  }, [editor, attachments]);
}
```

- [ ] **Step 2: Lint**

```bash
cd web
bun run lint -- src/components/studio/kv-generator/lexical/useChipSync.ts
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
cd web
git add src/components/studio/kv-generator/lexical/useChipSync.ts
git commit -m "feat(kv-chat): add useChipSync hook for bidirectional state↔editor binding"
```

---

### Task 12: `KvLexicalEditor` component

**Files:**
- Create: `src/components/studio/kv-generator/lexical/KvLexicalEditor.tsx`

- [ ] **Step 1: Write the editor**

Create `web/src/components/studio/kv-generator/lexical/KvLexicalEditor.tsx`:

```tsx
"use client";

import { useCallback, useMemo } from "react";
import { LexicalComposer } from "@lexical/react/LexicalComposer";
import { RichTextPlugin } from "@lexical/react/LexicalRichTextPlugin";
import { ContentEditable } from "@lexical/react/LexicalContentEditable";
import { LexicalErrorBoundary } from "@lexical/react/LexicalErrorBoundary";
import { OnChangePlugin } from "@lexical/react/LexicalOnChangePlugin";
import { HistoryPlugin } from "@lexical/react/LexicalHistoryPlugin";
import {
  KEY_ENTER_COMMAND,
  COMMAND_PRIORITY_HIGH,
  type EditorState,
} from "lexical";
import { useLexicalComposerContext } from "@lexical/react/LexicalComposerContext";
import { useEffect } from "react";
import { type ContentBlock } from "@/types/kvChatBlocks";
import { SelectionRefNode, SelectionRefHandlersContext } from "./SelectionRefNode";
import { AttachmentRefNode, AttachmentRefHandlersContext } from "./AttachmentRefNode";
import { useChipSync } from "./useChipSync";
import { serializeToContentBlocks } from "./serializeToContentBlocks";

type AttachmentForResolve = {
  id: string;
  name: string;
  url?: string;
};

type Box = { id: string; x: number; y: number; width: number; height: number };

export type KvLexicalEditorProps = {
  /** Called whenever the editor content changes. Parent owns the source
   *  of truth for the prompt — when send fires, parent reads the latest
   *  value from this onChange-pushed state. */
  onChange: (blocks: ContentBlock[]) => void;
  /** Called when the user presses Enter (without Shift). */
  onSend: () => void;
  placeholder?: string;
  attachments: AttachmentForResolve[];
  boxes: Box[];
  onRemoveBox?: (id: string) => void;
  onRemoveAttachment?: (id: string) => void;
  /** Opens the existing SelectionSummaryModal. Pass focusBoxId so the
   *  modal scrolls/highlights the chip the user clicked. */
  onOpenSelectionSummary: (focusBoxId?: string) => void;
};

export function KvLexicalEditor({
  onChange,
  onSend,
  placeholder = "What do you want to ask...",
  attachments,
  boxes,
  onRemoveBox,
  onRemoveAttachment,
  onOpenSelectionSummary,
}: KvLexicalEditorProps) {
  const initialConfig = useMemo(
    () => ({
      namespace: "KvChatEditor",
      onError: (error: Error) => {
        // Log but don't crash the page — the chat is recoverable on next
        // keystroke.
        console.error("[KvLexicalEditor]", error);
      },
      nodes: [SelectionRefNode, AttachmentRefNode],
      theme: {
        paragraph: "kv-lex-para",
      },
    }),
    []
  );

  const selectionHandlers = useMemo(
    () => ({
      onRemove: (refId: string) => onRemoveBox?.(refId),
      onClick: (refId: string) => onOpenSelectionSummary(refId),
    }),
    [onRemoveBox, onOpenSelectionSummary]
  );

  const attachmentHandlers = useMemo(
    () => ({
      onRemove: (refId: string) => onRemoveAttachment?.(refId),
      resolve: (refId: string) => {
        const a = attachments.find((x) => x.id === refId);
        return a ? { name: a.name, thumbnailUrl: a.url } : null;
      },
    }),
    [attachments, onRemoveAttachment]
  );

  const handleEditorStateChange = useCallback(
    (state: EditorState) => {
      const blocks = serializeToContentBlocks(state);
      onChange(blocks);
    },
    [onChange]
  );

  return (
    <SelectionRefHandlersContext.Provider value={selectionHandlers}>
      <AttachmentRefHandlersContext.Provider value={attachmentHandlers}>
        <LexicalComposer initialConfig={initialConfig}>
          <div className="relative">
            <RichTextPlugin
              contentEditable={
                <ContentEditable
                  className="text-textSmRegular min-h-[40px] w-full bg-transparent font-geist leading-[1.4] tracking-[-0.14px] text-text-inverse outline-none"
                  ariaLabel="KV chat input"
                />
              }
              placeholder={
                <div className="text-textSmRegular pointer-events-none absolute left-0 top-0 select-none font-geist leading-[1.4] tracking-[-0.14px] text-text-inverse-subtlest">
                  {placeholder}
                </div>
              }
              ErrorBoundary={LexicalErrorBoundary}
            />
            <OnChangePlugin onChange={handleEditorStateChange} ignoreSelectionChange />
            <HistoryPlugin />
            <EnterCommandPlugin onSend={onSend} />
            <ChipSyncBridge boxes={boxes} attachments={attachments} />
          </div>
        </LexicalComposer>
      </AttachmentRefHandlersContext.Provider>
    </SelectionRefHandlersContext.Provider>
  );
}

function EnterCommandPlugin({ onSend }: { onSend: () => void }) {
  const [editor] = useLexicalComposerContext();
  useEffect(() => {
    return editor.registerCommand(
      KEY_ENTER_COMMAND,
      (event) => {
        if (event && (event.shiftKey || event.metaKey || event.ctrlKey)) {
          // Let Lexical handle shift+Enter (soft line break) and modifier
          // combos.
          return false;
        }
        event?.preventDefault();
        onSend();
        return true;
      },
      COMMAND_PRIORITY_HIGH
    );
  }, [editor, onSend]);
  return null;
}

function ChipSyncBridge({
  boxes,
  attachments,
}: {
  boxes: Box[];
  attachments: AttachmentForResolve[];
}) {
  // Hook needs to live inside the LexicalComposer subtree to access the
  // composer context.
  useChipSync({ boxes, attachments });
  return null;
}
```

- [ ] **Step 2: Lint**

```bash
cd web
bun run lint -- src/components/studio/kv-generator/lexical/KvLexicalEditor.tsx
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
cd web
git add src/components/studio/kv-generator/lexical/KvLexicalEditor.tsx
git commit -m "feat(kv-chat): add KvLexicalEditor composing nodes + chip sync + Enter-to-send"
```

---

### Task 13: Storybook story for visual smoke

**Files:**
- Create: `src/components/studio/kv-generator/lexical/KvLexicalEditor.stories.tsx`

- [ ] **Step 1: Write the story**

Create `web/src/components/studio/kv-generator/lexical/KvLexicalEditor.stories.tsx`:

```tsx
import type { Meta, StoryObj } from "@storybook/react";
import { useState } from "react";
import { KvLexicalEditor } from "./KvLexicalEditor";
import type { ContentBlock } from "@/types/kvChatBlocks";

const meta: Meta<typeof KvLexicalEditor> = {
  title: "Studio/KvGenerator/KvLexicalEditor",
  component: KvLexicalEditor,
  parameters: {
    backgrounds: { default: "dark" },
  },
};
export default meta;

type Story = StoryObj<typeof KvLexicalEditor>;

export const Empty: Story = {
  render: () => {
    const [, setBlocks] = useState<ContentBlock[]>([]);
    return (
      <div className="w-[640px] rounded-2xl bg-[rgba(255,255,255,0.05)] p-3">
        <KvLexicalEditor
          onChange={setBlocks}
          onSend={() => alert("send")}
          attachments={[]}
          boxes={[]}
          onOpenSelectionSummary={() => {}}
        />
      </div>
    );
  },
};

export const WithOneSelectionAndOneAttachment: Story = {
  render: () => {
    const [, setBlocks] = useState<ContentBlock[]>([]);
    const [boxes, setBoxes] = useState([
      { id: "box-1", x: 0.1, y: 0.1, width: 0.2, height: 0.2 },
    ]);
    const [attachments, setAttachments] = useState([
      { id: "file-1", name: "reference.png", url: "https://placehold.co/120x120" },
    ]);
    return (
      <div className="w-[640px] rounded-2xl bg-[rgba(255,255,255,0.05)] p-3">
        <KvLexicalEditor
          onChange={setBlocks}
          onSend={() => alert("send")}
          attachments={attachments}
          boxes={boxes}
          onRemoveBox={(id) => setBoxes((bs) => bs.filter((b) => b.id !== id))}
          onRemoveAttachment={(id) =>
            setAttachments((as) => as.filter((a) => a.id !== id))
          }
          onOpenSelectionSummary={(id) => alert(`open summary, focus=${id ?? "all"}`)}
        />
      </div>
    );
  },
};

export const TwoSelectionsTwoAttachments: Story = {
  render: () => {
    const [, setBlocks] = useState<ContentBlock[]>([]);
    const [boxes, setBoxes] = useState([
      { id: "box-1", x: 0.1, y: 0.1, width: 0.2, height: 0.2 },
      { id: "box-2", x: 0.5, y: 0.5, width: 0.2, height: 0.2 },
    ]);
    const [attachments, setAttachments] = useState([
      { id: "file-1", name: "style.png", url: "https://placehold.co/120x120/444/fff" },
      { id: "file-2", name: "subject.jpg", url: "https://placehold.co/120x120/888/fff" },
    ]);
    return (
      <div className="w-[640px] rounded-2xl bg-[rgba(255,255,255,0.05)] p-3">
        <KvLexicalEditor
          onChange={setBlocks}
          onSend={() => alert("send")}
          attachments={attachments}
          boxes={boxes}
          onRemoveBox={(id) => setBoxes((bs) => bs.filter((b) => b.id !== id))}
          onRemoveAttachment={(id) =>
            setAttachments((as) => as.filter((a) => a.id !== id))
          }
          onOpenSelectionSummary={(id) => alert(`open summary, focus=${id ?? "all"}`)}
        />
      </div>
    );
  },
};
```

- [ ] **Step 2: Run Storybook and visually verify**

```bash
cd web
bun run storybook
```

Open `http://localhost:6006`, navigate to `Studio/KvGenerator/KvLexicalEditor`. Verify:
- `Empty`: placeholder "What do you want to ask..." renders, typing produces text, Enter triggers the alert.
- `WithOneSelectionAndOneAttachment`: chips appear inline (Region 1, reference.png). Clicking ✕ on either removes it and the chip disappears. Typing between them works.
- `TwoSelectionsTwoAttachments`: Region 1, Region 2, both file chips render. Removing Region 1 in the editor reindexes Region 2 → Region 1.

- [ ] **Step 3: Commit**

```bash
cd web
git add src/components/studio/kv-generator/lexical/KvLexicalEditor.stories.tsx
git commit -m "test(kv-chat): add KvLexicalEditor Storybook stories for visual smoke"
```

---

## Phase 3 — Web integration

### Task 14: Update `SelectionSummaryModal` to accept `focusBoxId`

**Files:**
- Modify: `src/components/studio/kv-generator/KvChat.tsx` (the `SelectionSummaryModal` function is defined inline at line ~1412 of `KvChat.tsx`, not in a separate file)

- [ ] **Step 1: Read the existing modal definition**

```bash
cd web
sed -n '1410,1500p' src/components/studio/kv-generator/KvChat.tsx
```

Note its current props type and how rows are rendered.

- [ ] **Step 2: Add optional `focusBoxId` prop and scroll-to-row behavior**

In `KvChat.tsx` at line ~1412 where `function SelectionSummaryModal({...}) {` is defined, extend the props type with:

```ts
/** When provided, the modal scrolls and highlights this box's row on
 *  open. Used by chip clicks in the inline-chips editor so the user
 *  jumps to the right row. Omitted = no focus (existing behavior). */
focusBoxId?: string;
```

Inside the modal component body, add (right after destructuring props):

```ts
useEffect(() => {
  if (!focusBoxId) return;
  const row = document.querySelector(`[data-box-id="${focusBoxId}"]`);
  if (row && row instanceof HTMLElement) {
    row.scrollIntoView({ block: "nearest", behavior: "smooth" });
    row.classList.add("kv-summary-row-flash");
    const t = setTimeout(() => row.classList.remove("kv-summary-row-flash"), 1200);
    return () => clearTimeout(t);
  }
}, [focusBoxId]);
```

In the row render, ensure each row's outer element carries `data-box-id={box.id}`.

If `kv-summary-row-flash` doesn't exist as a CSS class, add this minimal rule to the same file (in the inline `<style>` if there is one, or to `web/src/app/globals.css`):

```css
.kv-summary-row-flash {
  animation: kv-summary-flash 1.2s ease-out;
}
@keyframes kv-summary-flash {
  0%   { background-color: rgba(255, 255, 255, 0.12); }
  100% { background-color: transparent; }
}
```

- [ ] **Step 3: Pass `focusBoxId` from `KvChat` (existing call site)**

`KvChat.tsx` currently renders the modal at line ~1051 with `<SelectionSummaryModal boxes={boxes} onClose={...} onRemove={...} />`. Add a new state and prop:

```tsx
const [summaryFocusId, setSummaryFocusId] = useState<string | undefined>(undefined);

// in the existing modal mount:
<SelectionSummaryModal
  boxes={boxes}
  focusBoxId={summaryFocusId}
  onClose={() => {
    setSummaryOpen(false);
    setSummaryFocusId(undefined);
  }}
  onRemove={onRemoveBox}
/>
```

(`summaryFocusId` is set by the inline-chips editor in Task 16.)

- [ ] **Step 4: Lint**

```bash
cd web
bun run lint -- src/components/studio/kv-generator/KvChat.tsx
```

- [ ] **Step 5: Commit**

```bash
cd web
git add src/components/studio/kv-generator/KvChat.tsx web/src/app/globals.css
git commit -m "feat(kv-chat): SelectionSummaryModal accepts optional focusBoxId for chip-click scroll"
```

---

### Task 15: Extend `useKvStream.send()` to accept `ContentBlock[]`

**Files:**
- Modify: `src/hooks/useKvStream.ts` (lines 699-947)

- [ ] **Step 1: Update the `send()` signature**

In `web/src/hooks/useKvStream.ts`, change line 700-701:

```ts
const send = useCallback(
    async (
      prompt: ChatPrompt,    // was: prompt: string
      opts?: { ... }
```

Add the import at the top of the file:

```ts
import { type ChatPrompt, type ContentBlock, flattenBlocksToText, isContentBlockArray } from "@/types/kvChatBlocks";
```

- [ ] **Step 2: Resolve prompt to plain text early for the optimistic message**

Right after `if (!target) return;` (around line 757) and the `craft` empty-prompt guard (lines 758-770), normalize the prompt:

```ts
const promptBlocks: ContentBlock[] = isContentBlockArray(prompt)
  ? prompt
  : [{ type: "text", text: prompt }];
const promptText = isContentBlockArray(prompt) ? flattenBlocksToText(prompt) : prompt;

// Replace the existing `prompt.trim()` empty-check with `promptText.trim()`.
if (opts?.canvasMode !== "craft" && !promptText.trim()) return;
```

Replace the existing `text: prompt` (line 806) on the optimistic message insert with `text: promptText`.

- [ ] **Step 3: Add `message_blocks` to the JSON request body**

In the `body: JSON.stringify({...})` block (lines 864-890), update `message` and add `message_blocks`:

```ts
body: JSON.stringify({
  message: promptText,                                       // was: message: prompt
  message_blocks: isContentBlockArray(prompt) ? promptBlocks : undefined,
  mode: effectiveMode,
  // ...rest unchanged
}),
```

- [ ] **Step 4: Lint and typecheck**

```bash
cd web
bun run lint -- src/hooks/useKvStream.ts
```

Expected: clean. If any caller of `send()` is now type-unhappy, those callers were passing a plain string and the new `ChatPrompt` union is a strict superset, so they should still typecheck. If TypeScript flags one, the compiler points exactly at it.

- [ ] **Step 5: Commit**

```bash
cd web
git add src/hooks/useKvStream.ts
git commit -m "feat(kv-chat): useKvStream.send accepts ContentBlock[] and posts message_blocks"
```

---

### Task 16: Wire `KvLexicalEditor` into `KvChat` behind PostHog flag

**Files:**
- Modify: `src/components/studio/kv-generator/KvChat.tsx` (lines 1020-1170)

- [ ] **Step 1: Add the flag check at the top of the component**

In `web/src/components/studio/kv-generator/KvChat.tsx`, add the import:

```ts
import { useFeatureFlagEnabled } from "posthog-js/react";
```

Inside the `KvChat` component body, near the top (next to other hook calls):

```ts
const inlineChipsEnabled = useFeatureFlagEnabled("kv-inline-chips-editor") ?? false;
```

- [ ] **Step 2: Track the prompt as `ContentBlock[]` when the editor is on**

Add new state next to the existing `value` / `setValue`:

```ts
const [promptBlocks, setPromptBlocks] = useState<ContentBlock[]>([]);
```

Import:

```ts
import { type ContentBlock, flattenBlocksToText } from "@/types/kvChatBlocks";
```

- [ ] **Step 3: Update the send handler to choose payload by flag**

Find the existing send handler (search for `stream.send(` in this file). The current call passes `value` as the first arg. Wrap it:

```ts
const promptToSend = inlineChipsEnabled ? promptBlocks : value;
await stream.send(promptToSend, { /* existing opts */ });
// After send, clear:
if (inlineChipsEnabled) {
  setPromptBlocks([]);
} else {
  setValue("");
}
```

Also gate the empty-prompt early return:

```ts
const isEmpty = inlineChipsEnabled
  ? flattenBlocksToText(promptBlocks).trim() === ""
  : value.trim() === "";
if (isEmpty && opts?.canvasMode !== "craft") return;
```

- [ ] **Step 4: Replace the input render with a flag-gated branch**

Find the section starting around line 1020 (the `<div className="flex flex-col rounded-2xl bg-[rgba(255,255,255,0.05)]">` container) and the input row at lines 1127-1142. Replace the rendering so that when `inlineChipsEnabled` is true, the existing **selection chip row** (1025-1048), **attachment chip row** (1084-1116), and **`<input>` row** (1127-1142) are replaced with a single `KvLexicalEditor` mount:

```tsx
{inlineChipsEnabled ? (
  <div className="px-4 py-3">
    <KvLexicalEditor
      onChange={setPromptBlocks}
      onSend={() => onSend()}
      placeholder="What do you want to ask..."
      attachments={attachments.map((a) => ({ id: a.id, name: a.name, url: a.preview_url }))}
      boxes={boxes}
      onRemoveBox={onClearBoxes ? (id) => onRemoveBox?.(id) : undefined}
      onRemoveAttachment={onRemoveAttachment}
      onOpenSelectionSummary={(id) => {
        setSummaryOpen(true);
        setSummaryFocusId(id);
      }}
    />
  </div>
) : (
  <>
    {/* keep the existing selection chip row + attachment chip row + <input> exactly as today */}
  </>
)}
```

(Add `import { KvLexicalEditor } from "./lexical/KvLexicalEditor";` and a new state `const [summaryFocusId, setSummaryFocusId] = useState<string | undefined>(undefined);` — pass it to `<SelectionSummaryModal focusBoxId={summaryFocusId} ... />`.)

The **pinned-style chip** row (lines 1064-1078) and the **tools row** (lines 1144-1168) stay rendered in **both** branches — they're always part of the card.

- [ ] **Step 5: Verify per-box remove handler exists**

The current `KvChat.tsx` exposes `onClearBoxes` (clear all). The chip's `onRemoveBox(id)` needs a per-box remove. Check if `onRemoveBox?: (id: string) => void` is already a prop on `KvChat` or if its parent `KvGeneratorLayout` exposes one. If not, add it:

```bash
cd web
git grep -n "onRemoveBox\|onClearBoxes" src/components/studio/kv-generator/
```

If no per-box remove exists, add one in `KvGeneratorLayout` (which owns `boxes` state) of the form:

```ts
const onRemoveBox = useCallback((id: string) => {
  setBoxes((prev) => prev.filter((b) => b.id !== id));
}, [setBoxes]);
```

…and thread it down to `KvChat` as a new prop. (If `boxes` state lives in `KvKonvaCanvas` / a context, mirror the pattern used by `onClearBoxes`.)

- [ ] **Step 6: Manual smoke test in the dev server**

```bash
cd web
bun run dev
```

Open the KV Generator. In Chrome devtools, run:

```js
posthog.featureFlags.override({ "kv-inline-chips-editor": true })
```

(Or set the flag value via the PostHog UI for your dev user.)

Reload. Verify:
- The chat input renders as a single Lexical editor (no separate chip rows above it).
- Drawing a bounding box on the canvas → a "Region 1" chip appears in the editor at the cursor.
- Attaching a file via the paperclip → a chip with the filename appears in the editor.
- Typing between chips works; the cursor moves through chips with arrow keys.
- Backspacing against a chip removes it (and the corresponding box / attachment from the canvas / picker).
- Clicking the chip's ✕ removes it.
- Clicking the chip body opens the SelectionSummaryModal with the matching row scrolled into view.
- Pressing Enter sends; Shift+Enter inserts a soft break.
- Toggle the flag back off (`posthog.featureFlags.override({ "kv-inline-chips-editor": false })`, reload). The legacy stacked-rows UI returns; nothing has regressed.

- [ ] **Step 7: Commit**

```bash
cd web
git add src/components/studio/kv-generator/KvChat.tsx src/components/studio/kv-generator/KvGeneratorLayout.tsx
git commit -m "feat(kv-chat): gate inline-chips editor on PostHog flag kv-inline-chips-editor"
```

---

### Task 17: Playwright e2e

**Files:**
- Create: `tests/e2e/studio-kv-inline-chips.spec.ts`

- [ ] **Step 1: Find the existing KV e2e fixture/login pattern**

```bash
cd web
cat tests/e2e/studio-projects-kv-generator.spec.ts
```

Identify the login/fixture pattern (which auth helper, which seed user, how to navigate to a KV file). The new spec should mirror this exactly.

- [ ] **Step 2: Write the e2e**

Create `web/tests/e2e/studio-kv-inline-chips.spec.ts`:

```ts
import { test, expect } from "@playwright/test";

// Mirror the auth/fixture pattern from studio-projects-kv-generator.spec.ts
// — fill in the helper imports and beforeEach login as that file does.

test.describe("KV Generator inline chips editor (PostHog flag on)", () => {
  test.beforeEach(async ({ page }) => {
    // ... existing login + KV file open from the kv-overlays.spec.ts
    // pattern. Then force the flag on:
    await page.addInitScript(() => {
      // PostHog injects on load; ensure the override runs before flag-gated
      // components render.
      window.localStorage.setItem(
        "ph_test_flag_overrides",
        JSON.stringify({ "kv-inline-chips-editor": true })
      );
    });
    // Some PostHog setups support this override-via-JS as well:
    await page.evaluate(() => {
      // @ts-expect-error - posthog is global at runtime
      window.posthog?.featureFlags?.override({ "kv-inline-chips-editor": true });
    });
  });

  test("draw a box → Region 1 chip appears inline → send → message persists", async ({ page }) => {
    const editor = page.getByRole("textbox", { name: /KV chat input/i });
    await expect(editor).toBeVisible();

    // Draw a bounding box on the canvas. Adapt selector + drag to your
    // canvas testid — see kv-overlays.spec.ts for the existing pattern.
    const canvas = page.getByTestId("kv-konva-canvas");
    const box = await canvas.boundingBox();
    if (!box) throw new Error("canvas not found");
    await page.mouse.move(box.x + 50, box.y + 50);
    await page.mouse.down();
    await page.mouse.move(box.x + 200, box.y + 200);
    await page.mouse.up();

    // The chip should now be inline in the editor.
    await expect(editor.getByText(/Region 1/)).toBeVisible();

    // Type a prompt and send.
    await editor.click();
    await page.keyboard.type("make this brighter");
    await page.keyboard.press("Enter");

    // The optimistic user bubble shows the flattened text.
    await expect(page.getByTestId("kv-chat-bubble-user").last()).toContainText(
      "make this brighter"
    );
  });

  test("Region 2 reindexes to Region 1 when the first box is removed", async ({ page }) => {
    const canvas = page.getByTestId("kv-konva-canvas");
    const box = await canvas.boundingBox();
    if (!box) throw new Error("canvas not found");

    // Draw two boxes
    await page.mouse.move(box.x + 50, box.y + 50);
    await page.mouse.down();
    await page.mouse.move(box.x + 150, box.y + 150);
    await page.mouse.up();

    await page.mouse.move(box.x + 250, box.y + 50);
    await page.mouse.down();
    await page.mouse.move(box.x + 350, box.y + 150);
    await page.mouse.up();

    const editor = page.getByRole("textbox", { name: /KV chat input/i });
    await expect(editor.getByText(/Region 1/)).toBeVisible();
    await expect(editor.getByText(/Region 2/)).toBeVisible();

    // Click ✕ on Region 1's chip.
    await editor.locator('button[aria-label="Remove Region 1"]').click();

    // What was Region 2 should now be Region 1.
    await expect(editor.getByText(/Region 1/)).toBeVisible();
    await expect(editor.getByText(/Region 2/)).not.toBeVisible();
  });
});
```

- [ ] **Step 3: Run the e2e**

```bash
cd web
bun run dev &
DEV_PID=$!
sleep 5
bun playwright test tests/e2e/studio-kv-inline-chips.spec.ts
kill $DEV_PID
```

Expected: both tests pass. If the flag-override mechanism in your PostHog setup is different, swap to whatever the existing `kv-overlays.spec.ts` uses for flag overrides (or hardcode the flag to true via a debug query string param if that's the pattern).

- [ ] **Step 4: Commit**

```bash
cd web
git add tests/e2e/studio-kv-inline-chips.spec.ts
git commit -m "test(kv-chat): add Playwright e2e for inline chips editor"
```

---

### Task 18: Open the web PR

- [ ] **Step 1: Push and open**

```bash
cd web
git push -u origin "$(git branch --show-current)"
gh pr create --title "feat(kv-chat): inline-chips editor (Lexical) behind PostHog flag" --body "$(cat <<'EOF'
## Summary
- Replaces the KV chat's stacked rows (selection chip / attachment chip / `<input>`) with a single Lexical-powered editor where chips render inline as decorator nodes (`SelectionRefNode`, `AttachmentRefNode`).
- Bidirectional binding: parent canvas / attachment state owns the truth; `useChipSync` mirrors adds/removes into the editor; chip ✕ / backspace mirrors back into parent state.
- New wire format: `message_blocks: ContentBlock[]` sent alongside `message` for backwards compat. **Backend flattens blocks → plain prose; identical model behavior to today.** Phase 2 (separate PR) will render labels for multi-ref disambiguation.
- Gated on PostHog flag `kv-inline-chips-editor`. Flag off = legacy UI (default).
- Selection chip restyled to match attachment chip pattern (compact pill, integrated ✕, one chip per box).
- Storybook stories + Playwright e2e for visual + integration coverage.

## Test plan
- [ ] CI green
- [ ] Manual: flag off → legacy stacked-rows UI; no regression
- [ ] Manual: flag on → editor mounts; draw box → chip inline; attach file → chip inline; backspace removes; ✕ removes; chip click opens scroll-focused summary modal
- [ ] Manual: flag on, two boxes → "Region 1", "Region 2"; remove Region 1 → Region 2 reindexes to Region 1
- [ ] Playwright e2e (`tests/e2e/studio-kv-inline-chips.spec.ts`) passes
- [ ] Storybook (`Studio/KvGenerator/KvLexicalEditor`) renders Empty / WithOneSelectionAndOneAttachment / TwoSelectionsTwoAttachments

## Rollout
- Flag default off in production.
- Internal QA at flag=true for ~1 week.
- Flag → 100% in production.
- Follow-up cleanup PR removes the flag + dead legacy code paths.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-review checklist (run before declaring the plan ready)

- [ ] Each task lists exact files (Create / Modify / Test) at the top
- [ ] Each TDD task has Write-test → Run-fails → Implement → Run-passes → Commit
- [ ] Frontend integration verifies via Storybook + Playwright + manual dev-server smoke (no vitest in this codebase)
- [ ] All code blocks contain complete, runnable code — no `// ...` placeholders or "implement appropriate X" hand-waves
- [ ] Type names match between tasks: `ContentBlock`, `SelectionRefNode`, `AttachmentRefNode`, `KvLexicalEditor`, `useChipSync`, `serializeToContentBlocks`, `ChatPrompt`, `flattenBlocksToText` are referenced consistently
- [ ] Phase ordering is API-first → web (so the new field exists when the web hits it)
- [ ] PostHog flag `kv-inline-chips-editor` is the single rollout gate
- [ ] Spec coverage check:
  - ✓ KvLexicalEditor with chip decorator nodes (Tasks 9, 10, 12)
  - ✓ useChipSync bidirectional binding (Task 11)
  - ✓ serializeToContentBlocks (Task 8)
  - ✓ useKvStream.send extension (Task 15)
  - ✓ Backend message_blocks accept + flatten (Tasks 2, 3)
  - ✓ Backend ref-id integrity validation (Task 4)
  - ✓ SelectionSummaryModal focusBoxId (Task 14)
  - ✓ Selection chip restyled to match attachment chip (Task 9 — chip uses identical pl-1 pr-1 / h-7 pattern as Task 10)
  - ✓ Pinned-style chip stays separate (Task 16, Step 4 — explicit "stays rendered in both branches")
  - ✓ Feature flag (Task 16, Step 1)
  - ✓ Playwright e2e (Task 17)
  - ✓ Backend Pest tests (Tasks 2, 3, 4)
  - ✓ Storybook visual smoke (Task 13)
