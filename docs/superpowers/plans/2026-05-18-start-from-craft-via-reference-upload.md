# Start-from-Craft via Reference Upload — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users start a fresh KV Generator project in Craft mode by uploading a reference image — the reference becomes version 1 (no AI credits charged), the polish becomes version 2, and the existing Craft pipeline runs unchanged.

**Architecture:** Add one new API endpoint (`POST /v1/studio/kv-generator/files/{id}/generations/import-from-upload`) that promotes an already-S3-uploaded asset into a real `KvGeneration` row tagged as user-uploaded. Web frontend detects "craft + no base + has attachment" before the stream send, calls the new endpoint, and splices the returned generation id in as `baseGenerationId`. The version timeline marks imported rows with a "Reference" badge. Zero changes to ai-service.

**Tech Stack:** Laravel 11 (PHP 8.5) + Pest tests on the API side; Next.js 16 / React + Vitest (`*.test.tsx`) on the web side. Image storage via the existing S3 disk. The reference image is uploaded through the existing `/v1/studio/chat-attachments` endpoint (no new upload route needed) — we only need a "register as generation" endpoint.

---

## File Structure

### API (`/Users/alva.e202511001/Desktop/work/frndos-agentic/api/`)

| Path | Action | Responsibility |
|---|---|---|
| `app/Http/Requests/Studio/ImportKvGenerationFromUploadRequest.php` | Create | FormRequest: validate `image_url`, `mime_type`, `size` |
| `app/Http/Controllers/Api/Studio/KvGeneratorFileController.php` | Modify | Add `importGenerationFromUpload()` method |
| `app/Services/Studio/KvGenerationService.php` | Modify | Add `persistImportFromUpload()` method (no credit metering, no AI activity event) |
| `routes/api.php` | Modify | Register new route inside the existing studio `kv-generator/files` group |
| `tests/Feature/Studio/KvGenerationImportFromUploadTest.php` | Create | Pest feature test covering happy path + auth + validation |

### Web (`/Users/alva.e202511001/Desktop/work/frndos-agentic/web/`)

| Path | Action | Responsibility |
|---|---|---|
| `src/services/kv/api.ts` | Modify | Add `importKvGenerationFromUpload()` function |
| `src/components/studio/kv-generator/promoteAttachmentToBase.ts` | Create | Pure helper: takes an uploaded `KvAttachmentDescriptor`, calls the import endpoint, returns the new generation id. Extracts the new logic out of `KvChat.tsx` (which is already >1100 lines). |
| `src/components/studio/kv-generator/promoteAttachmentToBase.test.ts` | Create | Vitest unit tests for the helper |
| `src/components/studio/kv-generator/KvChat.tsx` | Modify | In `onSend`, when `canvasMode === "craft"` and `!baseGenerationId` and there's at least one attachment, promote the first uploaded attachment via the helper, then use the returned id as `baseGenerationId` in the existing send path. When craft+no base+no attachments, show inline message instead of silently aborting. |
| `src/components/studio/kv-generator/KvChat.test.tsx` | Modify (or create if absent) | Integration test for the craft-promote branch |
| `src/components/studio/kv-generator/KvVersionCard.tsx` | Modify | Render a "Reference" badge when `generation.metadata?.imported_from_upload === true` |
| `src/components/studio/kv-generator/KvVersionCard.test.tsx` | Modify | Add a test case for the Reference badge |

### Boundaries

- `promoteAttachmentToBase` is a tiny pure-ish module (one function, one network call). It does not touch React state. KvChat orchestrates; the helper executes.
- `KvGenerationService::persistImportFromUpload` is intentionally separate from `persistCompletion` because the two have different rules (no credit metering, no AI activity event, no token usage payload).
- AI service untouched. Validation on `base_generation` stays strict.

---

## Task 1 — API: Pest test for the import endpoint (RED)

**Files:**
- Create: `api/tests/Feature/Studio/KvGenerationImportFromUploadTest.php`

- [ ] **Step 1: Verify Pest DB isolation is set up correctly before running any Feature test**

Read `api/phpunit.xml` and confirm it contains:
```xml
<env name="DB_CONNECTION" value="sqlite"/>
<env name="DB_DATABASE" value=":memory:"/>
```
Also read `api/tests/Pest.php` and confirm `RefreshDatabase::class` is applied in `Feature`.

If either is missing/commented, **STOP** and tell the user — running Feature tests without this isolation will overwrite the dev DB (this has happened before; see memory entry `lesson_test_db_isolation.md`).

- [ ] **Step 2: Write the failing test**

Create `api/tests/Feature/Studio/KvGenerationImportFromUploadTest.php`:

```php
<?php

use App\Models\Brand;
use App\Models\KvGeneration;
use App\Models\Role;
use App\Models\StudioFile;
use App\Models\StudioProject;
use App\Models\Tool;
use App\Models\User;
use App\Models\Workspace;
use Illuminate\Support\Str;

beforeEach(function () {
    $this->user = User::factory()->create();
    $this->brand = Brand::factory()->create();

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

    $this->tool = Tool::factory()->create(['slug' => 'kv-generator']);
    $this->actingAs($this->user, 'api');

    $this->project = StudioProject::factory()
        ->for($this->workspace)
        ->for($this->brand)
        ->create([
            'created_by' => $this->user->id,
            'last_edited_by' => $this->user->id,
        ]);

    // A kv-generator studio file is the parent the generation hangs off.
    $createResp = $this->postJson('/api/v1/studio/kv-generator/files', [
        'project_id' => $this->project->id,
        'brand_id' => $this->brand->id,
    ])->assertCreated();

    $this->file = StudioFile::findOrFail($createResp->json('data.id'));
});

it('promotes an uploaded reference into a KvGeneration row tagged as imported', function () {
    $payload = [
        'image_url' => 'https://example.com/uploads/ref.png',
        'mime_type' => 'image/png',
        'size' => 123456,
        'original_filename' => 'brand-hero.png',
    ];

    $response = $this->postJson(
        "/api/v1/studio/kv-generator/files/{$this->file->id}/generations/import-from-upload",
        $payload,
    )->assertCreated();

    $genId = $response->json('data.id');
    expect($genId)->toBeString();

    $gen = KvGeneration::findOrFail($genId);
    expect($gen->studio_file_id)->toBe($this->file->id);
    expect($gen->version_number)->toBe(1);
    expect($gen->mode->value)->toBe('sketch');
    expect($gen->model)->toBe('user_upload');
    expect($gen->parent_generation_id)->toBeNull();
    expect($gen->image_url)->toBe('https://example.com/uploads/ref.png');
    expect($gen->prompt_snapshot)->toBe('');
    expect(data_get($gen->metadata, 'imported_from_upload'))->toBeTrue();
    expect(data_get($gen->metadata, 'original_filename'))->toBe('brand-hero.png');
    expect(data_get($gen->metadata, 'mime_type'))->toBe('image/png');
});

it('increments version_number when a generation already exists on the file', function () {
    KvGeneration::create([
        'studio_file_id' => $this->file->id,
        'version_number' => 1,
        'image_url' => 'https://example.com/v1.png',
        'prompt_snapshot' => 'seed',
        'model' => 'gpt-image-1',
        'mode' => 'sketch',
        'metadata' => [],
        'created_by' => $this->user->id,
        'created_at' => now(),
    ]);

    $response = $this->postJson(
        "/api/v1/studio/kv-generator/files/{$this->file->id}/generations/import-from-upload",
        [
            'image_url' => 'https://example.com/uploads/ref.png',
            'mime_type' => 'image/png',
            'size' => 1024,
        ],
    )->assertCreated();

    expect($response->json('data.version_number'))->toBe(2);
});

it('rejects missing image_url', function () {
    $this->postJson(
        "/api/v1/studio/kv-generator/files/{$this->file->id}/generations/import-from-upload",
        ['mime_type' => 'image/png', 'size' => 1],
    )->assertStatus(422)
     ->assertJsonValidationErrors(['image_url']);
});

it('rejects non-image mime types', function () {
    $this->postJson(
        "/api/v1/studio/kv-generator/files/{$this->file->id}/generations/import-from-upload",
        [
            'image_url' => 'https://example.com/uploads/ref.pdf',
            'mime_type' => 'application/pdf',
            'size' => 1,
        ],
    )->assertStatus(422)
     ->assertJsonValidationErrors(['mime_type']);
});

it('returns 404 for an unknown studio_file_id', function () {
    $this->postJson(
        '/api/v1/studio/kv-generator/files/01jzzznotreal/generations/import-from-upload',
        [
            'image_url' => 'https://example.com/uploads/ref.png',
            'mime_type' => 'image/png',
            'size' => 1,
        ],
    )->assertStatus(404);
});

it('does not charge credits for an imported reference', function () {
    $before = $this->workspace->fresh()->balance ?? 0;

    $this->postJson(
        "/api/v1/studio/kv-generator/files/{$this->file->id}/generations/import-from-upload",
        [
            'image_url' => 'https://example.com/uploads/ref.png',
            'mime_type' => 'image/png',
            'size' => 1,
        ],
    )->assertCreated();

    $after = $this->workspace->fresh()->balance ?? 0;
    expect($after)->toBe($before);
});
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd api && ./vendor/bin/pest --filter=KvGenerationImportFromUpload`
Expected: ALL FAIL — route doesn't exist (404), so most assertions error out.

---

## Task 2 — API: FormRequest for validation

**Files:**
- Create: `api/app/Http/Requests/Studio/ImportKvGenerationFromUploadRequest.php`

- [ ] **Step 1: Create the FormRequest**

Create `api/app/Http/Requests/Studio/ImportKvGenerationFromUploadRequest.php`:

```php
<?php

namespace App\Http\Requests\Studio;

use Illuminate\Foundation\Http\FormRequest;

class ImportKvGenerationFromUploadRequest extends FormRequest
{
    public function authorize(): bool
    {
        return $this->user('api') !== null;
    }

    public function rules(): array
    {
        return [
            'image_url' => ['required', 'string', 'url', 'max:2048'],
            'mime_type' => [
                'required',
                'string',
                'in:image/png,image/jpeg,image/webp,image/gif',
            ],
            'size' => ['required', 'integer', 'min:1', 'max:20971520'], // 20 MB cap, matches the chat-attachments client guard
            'original_filename' => ['sometimes', 'nullable', 'string', 'max:255'],
        ];
    }
}
```

- [ ] **Step 2: Commit**

```bash
cd api && git add app/Http/Requests/Studio/ImportKvGenerationFromUploadRequest.php tests/Feature/Studio/KvGenerationImportFromUploadTest.php
git commit -m "test(api): add failing tests for KV import-from-upload endpoint"
```

---

## Task 3 — API: Service method that persists the synthetic generation

**Files:**
- Modify: `api/app/Services/Studio/KvGenerationService.php`

- [ ] **Step 1: Add `persistImportFromUpload` to the service**

Modify `api/app/Services/Studio/KvGenerationService.php` — add the new method below `persistCompletion`:

```php
    /**
     * Promote a user-uploaded reference image into a real KvGeneration row.
     *
     * Used by start-from-craft: a fresh project has no prior generation, so
     * we register the uploaded reference as version 1 (mode='sketch',
     * model='user_upload') and the existing Craft polish pipeline runs
     * unchanged against it as the base. No credit metering (it isn't an
     * AI call) and no StudioActivity row (the reference isn't a "generated"
     * event — the polish that follows will get its own activity row).
     */
    public function persistImportFromUpload(array $payload): KvGeneration
    {
        return DB::transaction(function () use ($payload) {
            $file = StudioFile::findOrFail($payload['studio_file_id']);

            $nextVersion = ($file->generations()->max('version_number') ?? 0) + 1;

            $generation = KvGeneration::create([
                'studio_file_id' => $file->id,
                'parent_generation_id' => null,
                'chat_message_id' => null,
                'version_number' => $nextVersion,
                'image_url' => $payload['image_url'],
                'thumbnail_url' => null,
                'prompt_snapshot' => '',
                'model' => 'user_upload',
                'mode' => KvGenerationMode::Sketch,
                'ai_service_run_id' => null,
                'metadata' => [
                    'imported_from_upload' => true,
                    'mime_type' => $payload['mime_type'],
                    'size' => $payload['size'],
                    'original_filename' => $payload['original_filename'] ?? null,
                ],
                'created_by' => $payload['created_by'],
                'created_at' => now(),
            ]);

            $file->thumbnail_url = $payload['image_url'];
            $file->last_edited_at = now();
            $file->last_edited_by = $payload['created_by'];
            $file->save();

            return $generation;
        });
    }
```

(No changes to the existing `persistCompletion` method. The `use` block already imports `KvGenerationMode`, `KvGeneration`, `StudioFile`, and `DB` — verify with a quick look at the top of the file.)

---

## Task 4 — API: Controller method + route

**Files:**
- Modify: `api/app/Http/Controllers/Api/Studio/KvGeneratorFileController.php`
- Modify: `api/routes/api.php`

- [ ] **Step 1: Add the controller method**

Modify `api/app/Http/Controllers/Api/Studio/KvGeneratorFileController.php` — add the method (and required `use` statements at the top of the file if not already present):

Imports to ensure are present near the existing imports:
```php
use App\Http\Requests\Studio\ImportKvGenerationFromUploadRequest;
use App\Http\Resources\Studio\KvGenerationResource;
use App\Services\Studio\KvGenerationService;
```

Add the method inside the controller class:
```php
    /**
     * Promote a user-uploaded reference image into a KvGeneration row so
     * the Craft polish pipeline (which requires a base_generation_id) can
     * run on the very first turn of a fresh project.
     *
     * The asset must already have been uploaded via /v1/studio/chat-attachments
     * — this endpoint only persists the descriptor as a generation row, it
     * doesn't accept multipart payloads. No credits charged.
     */
    public function importGenerationFromUpload(
        string $id,
        ImportKvGenerationFromUploadRequest $request,
        KvGenerationService $service,
    ): JsonResponse {
        $file = StudioFile::findOrFail($id);
        $this->authorize('view', $file);

        $generation = $service->persistImportFromUpload([
            'studio_file_id' => $file->id,
            'image_url' => $request->validated('image_url'),
            'mime_type' => $request->validated('mime_type'),
            'size' => $request->validated('size'),
            'original_filename' => $request->validated('original_filename'),
            'created_by' => $request->user('api')->id,
        ]);

        return (new KvGenerationResource($generation))
            ->response()
            ->setStatusCode(201);
    }
```

- [ ] **Step 2: Register the route**

Modify `api/routes/api.php` — inside the same block that already contains the existing `kv-generator/files/{id}/...` routes (look for line ~1644), add:

```php
                    Route::post(
                        'kv-generator/files/{id}/generations/import-from-upload',
                        [KvGeneratorFileController::class, 'importGenerationFromUpload'],
                    );
```

Place it directly under the `restoreGeneration` line (~1645) to keep KV-file routes grouped.

- [ ] **Step 3: Run the tests — they should now pass**

Run: `cd api && ./vendor/bin/pest --filter=KvGenerationImportFromUpload`
Expected: ALL 6 tests PASS.

If `authorize('view', $file)` fails because there's no policy registered for `StudioFile`, replace the `$this->authorize(...)` call with the workspace-membership check used by the existing `show()` method in the same controller (read that method to copy the pattern verbatim).

- [ ] **Step 4: Commit**

```bash
cd api && git add app/Http/Controllers/Api/Studio/KvGeneratorFileController.php app/Services/Studio/KvGenerationService.php routes/api.php
git commit -m "feat(api): import-from-upload endpoint promotes reference into KvGeneration

Lets the web client register a user-uploaded reference image as version 1
of a KV file so Craft mode can polish it on the very first turn. No credits
charged, no StudioActivity event — the reference is not an AI-generated
artifact, just a synthetic base for the existing polish pipeline.

Refs: Option 2a in 2026-05-18 design doc."
```

---

## Task 5 — Web: API client function

**Files:**
- Modify: `web/src/services/kv/api.ts`

- [ ] **Step 1: Add the client function**

Modify `web/src/services/kv/api.ts` — add this function in the `// ── Generation ────────────────────────────────` section (near the other generation helpers around line 215+; placement is cosmetic):

```ts
export async function importKvGenerationFromUpload(
  fileId: string,
  body: {
    image_url: string;
    mime_type: string;
    size: number;
    original_filename?: string;
  },
): Promise<KvGeneration> {
  const { data } = await axiosInstance.post(
    `v1/studio/kv-generator/files/${fileId}/generations/import-from-upload`,
    body,
  );
  return unwrap(data);
}
```

If `KvGeneration` isn't already imported at the top of `api.ts`, add it:
```ts
import type { KvGeneration } from "@/types/studio";
```
(Run `grep "^import" web/src/services/kv/api.ts | head -10` to check existing import style.)

---

## Task 6 — Web: helper module with TDD

**Files:**
- Create: `web/src/components/studio/kv-generator/promoteAttachmentToBase.ts`
- Create: `web/src/components/studio/kv-generator/promoteAttachmentToBase.test.ts`

- [ ] **Step 1: Write the failing test**

Create `web/src/components/studio/kv-generator/promoteAttachmentToBase.test.ts`:

```ts
import { describe, it, expect, vi, beforeEach } from "vitest";
import { promoteAttachmentToBase } from "./promoteAttachmentToBase";

const mockImport = vi.fn();
vi.mock("@/services/kv/api", () => ({
  importKvGenerationFromUpload: (...args: unknown[]) => mockImport(...args),
}));

describe("promoteAttachmentToBase", () => {
  beforeEach(() => {
    mockImport.mockReset();
  });

  it("calls the import endpoint with the uploaded descriptor and returns the new generation id", async () => {
    mockImport.mockResolvedValue({ id: "gen_synth_1", version_number: 1 });

    const id = await promoteAttachmentToBase({
      fileId: "file_abc",
      attachment: {
        id: "att_1",
        name: "ref.png",
        mime_type: "image/png",
        size: 4096,
        url: "https://s3/uploads/ref.png",
      },
    });

    expect(id).toBe("gen_synth_1");
    expect(mockImport).toHaveBeenCalledWith("file_abc", {
      image_url: "https://s3/uploads/ref.png",
      mime_type: "image/png",
      size: 4096,
      original_filename: "ref.png",
    });
  });

  it("returns null when the attachment has no url (upload failed)", async () => {
    const id = await promoteAttachmentToBase({
      fileId: "file_abc",
      attachment: {
        id: "att_1",
        name: "ref.png",
        mime_type: "image/png",
        size: 4096,
        url: undefined,
      },
    });

    expect(id).toBeNull();
    expect(mockImport).not.toHaveBeenCalled();
  });

  it("returns null and swallows network errors so the caller can fall back gracefully", async () => {
    mockImport.mockRejectedValue(new Error("boom"));

    const id = await promoteAttachmentToBase({
      fileId: "file_abc",
      attachment: {
        id: "att_1",
        name: "ref.png",
        mime_type: "image/png",
        size: 4096,
        url: "https://s3/uploads/ref.png",
      },
    });

    expect(id).toBeNull();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web && bun run vitest run src/components/studio/kv-generator/promoteAttachmentToBase.test.ts`
Expected: FAIL with "Failed to resolve import" / "Cannot find module".

- [ ] **Step 3: Implement the helper**

Create `web/src/components/studio/kv-generator/promoteAttachmentToBase.ts`:

```ts
import { importKvGenerationFromUpload } from "@/services/kv/api";

export interface UploadedAttachmentDescriptor {
  id: string;
  name: string;
  mime_type: string;
  size: number;
  url: string | undefined;
}

/**
 * Promote an already-S3-uploaded reference into a synthetic KvGeneration
 * so Craft mode can polish it on the first turn of a fresh project.
 *
 * Returns the new generation id, or `null` if the attachment has no url
 * or the import endpoint failed — callers should fall back to the
 * existing "no base, abort send" guard in that case.
 */
export async function promoteAttachmentToBase(args: {
  fileId: string;
  attachment: UploadedAttachmentDescriptor;
}): Promise<string | null> {
  const { fileId, attachment } = args;
  if (!attachment.url) return null;

  try {
    const generation = await importKvGenerationFromUpload(fileId, {
      image_url: attachment.url,
      mime_type: attachment.mime_type,
      size: attachment.size,
      original_filename: attachment.name,
    });
    return generation.id;
  } catch {
    return null;
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web && bun run vitest run src/components/studio/kv-generator/promoteAttachmentToBase.test.ts`
Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
cd web && git add src/services/kv/api.ts src/components/studio/kv-generator/promoteAttachmentToBase.ts src/components/studio/kv-generator/promoteAttachmentToBase.test.ts
git commit -m "feat(web): client helper for promoting reference upload to base generation

Adds importKvGenerationFromUpload() to the kv api client and a small
helper that wraps it for the start-from-craft flow. Returns null on
failure so the caller can fall back to the existing abort guard."
```

---

## Task 7 — Web: wire `KvChat.onSend` to promote on start-from-craft

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvChat.tsx`

This task does NOT add a new test (the helper is unit-tested in Task 6 and the integration is covered by the e2e/Playwright pass in Task 9). The change is a small surgical edit inside `onSend`.

- [ ] **Step 1: Determine the `fileId` source in KvChat**

Run `grep -n "studio_file_id\|file_id\|fileId" web/src/components/studio/kv-generator/KvChat.tsx | head -20` to see whether `KvChat` already has the studio file id in scope (via props / `stream` / a hook). It is needed for the import call.

If it's already in scope (most likely as `stream.fileId` or a prop), use it directly. If not, thread it through as an optional prop:

```ts
fileId?: string;
```

(Search the parent that renders `<KvChat />` and pass `studioFileId` — the file id appears in the URL `/studio/kv-generator/[file_id]`, so the parent route page has it.)

- [ ] **Step 2: Add the import + wire the new behavior into `onSend`**

In `web/src/components/studio/kv-generator/KvChat.tsx`, add to the imports near the top (look for the existing local-module imports around line 55):

```ts
import { promoteAttachmentToBase } from "./promoteAttachmentToBase";
```

Then modify the existing `onSend` body. Locate the block at lines 1075-1111 (the `setPromptBlocks([])` line down to the closing `})` of `stream.send`). Replace those lines exactly with:

```ts
    setPromptBlocks([]);

    // Start-from-Craft promotion. If the user opened a fresh project,
    // picked Craft, and uploaded a reference but doesn't have a
    // baseGenerationId yet, promote the first uploaded attachment into
    // a synthetic KvGeneration so the Craft pipeline (which validates
    // base_generation_id at three layers) has something to polish.
    let effectiveBaseGenerationId = baseGenerationId ?? null;
    if (
      canvasMode === "craft" &&
      !effectiveBaseGenerationId &&
      !hasBoxes &&
      encodedAttachments &&
      encodedAttachments.length > 0 &&
      fileId
    ) {
      const promoted = await promoteAttachmentToBase({
        fileId,
        attachment: {
          id: encodedAttachments[0].id,
          name: encodedAttachments[0].name,
          mime_type: encodedAttachments[0].mime_type,
          size: encodedAttachments[0].size ?? 0,
          url: encodedAttachments[0].url,
        },
      });
      if (promoted) effectiveBaseGenerationId = promoted;
    }

    // Craft turns route through the polish pipeline (img-to-img on the
    // latest generation) so chatting "make the brand pop more" while in
    // Craft mode refines the existing visual instead of producing a
    // fresh sketch. Bounding-box edits keep their existing 'edit' route
    // even in Craft because that flow is region-specific.
    const isCraft =
      canvasMode === "craft" &&
      !hasBoxes &&
      Boolean(effectiveBaseGenerationId);
    stream.send(promptBlocks, {
      boundingBoxes: hasBoxes
        ? boxes.map((b) => ({
            id: b.id,
            x: b.x,
            y: b.y,
            width: b.width,
            height: b.height,
            prompt: b.prompt,
          }))
        : undefined,
      // baseGenerationId flows for both bounding-box edits AND craft
      // polishes — both pipelines need the parent image as the source.
      baseGenerationId:
        hasBoxes || isCraft
          ? (effectiveBaseGenerationId ?? undefined)
          : undefined,
      attachments: encodedAttachments,
      aspectRatio: aspectRatio ?? undefined,
      useBrandKnowledge: useBrandKnowledge ?? undefined,
      canvasMode,
      mode: isCraft ? "image" : undefined,
    });
```

(This replacement also removes the stale "Falls back to sketch behaviour..." comment since the actual behavior is now "promote the attachment, then polish.")

- [ ] **Step 3: Type-check and run the existing KvChat tests**

Run: `cd web && bun run tsc --noEmit -p tsconfig.json 2>&1 | grep -E "KvChat|promoteAttachmentToBase" | head -20`
Expected: no errors. (Other unrelated pre-existing errors are not your concern — only flag KvChat/promote errors.)

Run: `cd web && bun run vitest run src/components/studio/kv-generator/KvChat.test.tsx 2>&1 | tail -20` (if the file exists; skip if it doesn't)
Expected: PASS (no regressions to the existing send paths).

- [ ] **Step 4: Manually verify in the browser**

The dev server should already be running on http://localhost:3000 (started earlier in the session). Refresh the page and:
1. Navigate to `/studio/kv-generator/new`
2. Switch the canvas to Craft mode
3. Attach a reference image
4. Type a prompt and hit Send

Expected: the send goes through (no console error `[useKvStream] craft requires baseGenerationId`). The version timeline shows v1 (the reference) and then v2 (the polish) after the stream completes. Open the browser DevTools Network tab — you should see one `POST /v1/studio/kv-generator/files/{id}/generations/import-from-upload` request fire before the stream request.

If the send still aborts with the old error, check that `fileId` is actually being passed into `KvChat` from the parent route — that's the most common miss.

- [ ] **Step 5: Commit**

```bash
cd web && git add src/components/studio/kv-generator/KvChat.tsx
git commit -m "feat(web): start-from-craft promotes the reference upload to base generation

When the user opens a fresh KV project, picks Craft, and uploads a
reference, the first attachment is promoted to a synthetic KvGeneration
(v1) and that id is used as base_generation_id for the polish send.
The Craft pipeline runs unchanged from there."
```

---

## Task 8 — Web: "Reference" badge on imported generations

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvVersionCard.tsx`
- Modify: `web/src/components/studio/kv-generator/KvVersionCard.test.tsx`

- [ ] **Step 1: Write the failing test**

Modify `web/src/components/studio/kv-generator/KvVersionCard.test.tsx` — add a test case (do not remove existing ones):

```ts
import { render, screen } from "@testing-library/react";
import { KvVersionCard } from "./KvVersionCard";

it("shows a Reference badge when the generation is an imported upload", () => {
  render(
    <KvVersionCard
      generation={{
        id: "g_ref",
        studio_file_id: "f1",
        version_number: 1,
        mode: "sketch",
        image_url: "https://example/ref.png",
        thumbnail_url: null,
        prompt_snapshot: "",
        model: "user_upload",
        parent_generation_id: null,
        metadata: { imported_from_upload: true },
        created_at: "2026-05-18T00:00:00Z",
      }}
    />,
  );
  expect(screen.getByText("Reference")).toBeInTheDocument();
});

it("shows the Sketch badge (not Reference) for normal sketch generations", () => {
  render(
    <KvVersionCard
      generation={{
        id: "g_sketch",
        studio_file_id: "f1",
        version_number: 1,
        mode: "sketch",
        image_url: "https://example/s.png",
        thumbnail_url: null,
        prompt_snapshot: "p",
        model: "gpt-image-1",
        parent_generation_id: null,
        metadata: {},
        created_at: "2026-05-18T00:00:00Z",
      }}
    />,
  );
  expect(screen.queryByText("Reference")).not.toBeInTheDocument();
  expect(screen.getByText("Sketch")).toBeInTheDocument();
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web && bun run vitest run src/components/studio/kv-generator/KvVersionCard.test.tsx`
Expected: the "Reference" assertion FAILS (the badge doesn't exist yet); the "Sketch" assertion passes.

- [ ] **Step 3: Update `KvVersionCard` to render the Reference badge**

Modify `web/src/components/studio/kv-generator/KvVersionCard.tsx`. Replace the existing `KvModeBadge` function with this version (keep everything above it as-is):

```tsx
/** Renders a tiny chip describing which operation produced this generation
 *  (Sketch / Craft / Reference). User-uploaded references promoted via
 *  start-from-craft show a "Reference" chip in place of "Sketch" so the
 *  timeline makes the lineage obvious: v1 = upload, v2 = polish. */
function KvModeBadge({ generation }: { generation: KvGeneration }) {
  const isImported =
    !!(generation.metadata && (generation.metadata as Record<string, unknown>).imported_from_upload);

  if (isImported) {
    return (
      <span
        title="Imported reference image"
        className="inline-flex items-center gap-1 rounded-full bg-amber-500/30 px-2 py-0.5 text-xs font-medium text-amber-50"
      >
        <Image size={12} weight="fill" />
        Reference
      </span>
    );
  }

  const mode = generation.mode ?? "sketch";
  if (mode === "craft") {
    return (
      <span
        title={
          generation.parent_generation_id
            ? `Polished from a previous version`
            : "Craft polish"
        }
        className="inline-flex items-center gap-1 rounded-full bg-violet-500/30 px-2 py-0.5 text-xs font-medium text-violet-50"
      >
        <MagicWand size={12} weight="fill" />
        Craft
      </span>
    );
  }
  // Note: 'resize' mode is reserved on kv_generations.mode but unused —
  // resize outputs live in kv_resize_exports, not on the version timeline.
  return (
    <span className="inline-flex items-center gap-1 rounded-full bg-white/10 px-2 py-0.5 text-xs font-medium text-text-inverse-subtle">
      <PencilRuler size={12} weight="regular" />
      Sketch
    </span>
  );
}
```

Also update the imports at the top of the same file:
```tsx
import { Image, MagicWand, PencilRuler } from "@phosphor-icons/react";
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web && bun run vitest run src/components/studio/kv-generator/KvVersionCard.test.tsx`
Expected: ALL PASS.

- [ ] **Step 5: Commit**

```bash
cd web && git add src/components/studio/kv-generator/KvVersionCard.tsx src/components/studio/kv-generator/KvVersionCard.test.tsx
git commit -m "feat(web): Reference badge on imported KV generation cards

User-uploaded references promoted via start-from-craft are marked
'Reference' instead of 'Sketch' so the timeline lineage is obvious:
v1 = imported reference, v2 = AI polish."
```

---

## Task 9 — End-to-end manual verification

**Files:** none (manual smoke test).

- [ ] **Step 1: Restart the API and web dev servers**

If either was running, restart so the new route and the new web bundle are picked up:
```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic && ./run-all.sh --stop
# then start api and web manually (as in the earlier session)
```

- [ ] **Step 2: Walk the golden path**

1. Open `http://localhost:3000/studio/kv-generator/new`
2. Switch to Craft mode
3. Attach a JPEG/PNG (under 20 MB)
4. Type a prompt: "Add a soft sunset light from the left"
5. Hit Send

Expected:
- No `[useKvStream] craft requires baseGenerationId` console error
- A single `POST /v1/studio/kv-generator/files/{id}/generations/import-from-upload` request in the Network tab
- A subsequent stream request to the kv-generator chat endpoint
- Version timeline shows **v1 with "Reference" badge** (the uploaded image) and, after the stream completes, **v2 with "Craft" badge** (the polish)

- [ ] **Step 3: Walk the unhappy-path branches**

a. **Craft + no attachments**: switch to Craft, type a prompt, hit Send.
   - Current expected behavior: the existing useKvStream guard fires and the send aborts. (We intentionally did NOT change this branch — it's still the right defense. A friendlier user-facing message is a follow-up.)

b. **Sketch mode unchanged**: switch back to Sketch, attach an image, send.
   - Expected: behaves exactly as before — no import call.

c. **Existing Craft polish (v2 → v3)**: after v2 lands from the golden path, send another prompt in Craft mode without uploading anything new.
   - Expected: no import call (a base exists). Stream goes through and v3 appears.

- [ ] **Step 4: Report results**

If anything fails the expected behavior above, capture the console error, the failing request/response in the Network tab, and the test output. Loop back to the task whose change caused the regression.

---

## Self-Review

**Spec coverage** — every section of the design has a task:
- New API endpoint → Tasks 1-4
- Frontend integration in KvChat → Tasks 5-7
- "Reference" badge → Task 8
- Manual verification → Task 9
- Edge cases ("multiple attachments → use first", "no attachments → keep current guard") → covered in Task 7 step 2 (the `encodedAttachments[0]` selection) and Task 9 step 3a

**Placeholder scan** — no "TBD", no "add appropriate validation". All code shown inline.

**Type consistency** — `KvGeneration.metadata` is `Record<string, unknown> | null` per [web/src/types/studio.ts:340](web/src/types/studio.ts:340), which is why Task 8 casts to `Record<string, unknown>` before reading `imported_from_upload`. API persists the same key (`imported_from_upload`) and the client checks the same key — consistent.

**Out of scope (YAGNI)**:
- No new upload endpoint — reuses `/v1/studio/chat-attachments`.
- No relaxation of the ai-service `BaseGenerationRef` validator.
- No backfill migration for old craft attempts that errored.
- No friendly toast for "craft + no attachments + no base" — keeps the existing guard untouched (could be a follow-up if the UX feels worse than expected).
