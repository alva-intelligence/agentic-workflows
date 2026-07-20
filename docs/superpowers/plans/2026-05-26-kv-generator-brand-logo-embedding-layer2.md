# KV Generator Brand Logo Embedding (Layer 2) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a brand has a logo and the user asks for it in the KV (e.g. "tambahkan logo Telkomsel"), automatically fetch the logo bytes from S3 server-side, base64-encode them, and inject them into the existing `attachments` array — so ai-service routes the generation through `/v1/images/edits` (img-to-img) with the real brand logo as a reference. gpt-image-2 then embeds the actual brand logo into the output instead of generating a hand-drawn text approximation.

**Architecture:** This is the **second layer** of the KV brand-asset feeding feature, built on top of Layer 1 (which is on the same branch — commits `feef997f` through `2e6fec86`). Layer 1 made the LLM aware of the brand's logo URL. Layer 2 makes the IMAGE-GENERATION model actually use it. The existing `attachments` pipeline already routes image references through `/v1/images/edits` in image mode — we just need a server-side step that detects "user wants brand logo," fetches it from S3, and pushes it into `attachments`. Zero changes on the ai-service side; the existing img-to-img plumbing handles the rest.

**Tech Stack:**
- API — Laravel 13, PHP 8.5, Pest 3, Laravel `Storage` facade (S3 disk)
- ai-service — no changes (existing `Attachment` schema + image-mode routing handles this transparently)
- Web — no changes (server-side feature)

**Branch:** `feature/daffa/vc-kv-brand-asset-feeding` (continues the Layer 1 branch — bundled PR)

**Scope boundary (explicit):**
- ✅ Server-side fetch of brand logo from S3 → base64 → `attachments` injection
- ✅ Intent detection via prompt keywords (`logo`, `lambang`) with simple negation guard (`tanpa logo`, `no logo`, `without logo`)
- ✅ MIME-type validation (only `image/png|jpeg|webp|gif` — matches ai-service Attachment schema)
- ✅ Feature test asserting outbound payload's `attachments` array carries brand-logo when intent is detected
- ✅ Cleanup of Layer-1 smoke-test debug print in `context_builder.py`
- ❌ LLM-driven intent detection via tool calls (heuristic regex is good enough for v1; revisit if false positives are common)
- ❌ Logo variant selection (dark/light/mono) — those don't exist as separate fields yet (Layer 3 / brand_assets table)
- ❌ Caching of fetched logo bytes (1 S3 GET per generation is fine; revisit if it becomes a hot path)
- ❌ Frontend / UI changes — none

---

## File Structure

### API
- `api/app/Services/Brand/BrandLogoIntentDetector.php` — **NEW**: static helper that scans a user prompt for logo-request keywords with negation guard
- `api/app/Services/Brand/BrandLogoAttachmentBuilder.php` — **NEW**: fetches a `Brand`'s logo from S3, base64-encodes, validates MIME, returns an Attachment-shaped array
- `api/app/Services/ChatService.php` — wires detector + builder into the prefetched brand block right after Layer 1's `$prefetched['brand']` assignment
- `api/tests/Unit/Brand/BrandLogoIntentDetectorTest.php` — **NEW**: unit tests for keyword detection + negation
- `api/tests/Unit/Brand/BrandLogoAttachmentBuilderTest.php` — **NEW**: unit tests for the builder using `Storage::fake('s3')`
- `api/tests/Feature/Chat/BrandLogoEmbeddingTest.php` — **NEW**: end-to-end feature test asserting outbound ai-service payload includes the brand logo in `attachments` when intent + data align

### ai-service
- `ai-service/app/agents/kv_generator/context_builder.py` — revert smoke-test `print()` debug from Layer 1 work (small cleanup task before shipping)

### web
- No changes

---

## Task 0: Revert smoke-test debug print in `context_builder.py`

**Files:**
- Modify: `ai-service/app/agents/kv_generator/context_builder.py:80-84`

**Rationale:** Earlier in the smoke-test session, a `print("\n========== KV GENERATOR SYSTEM PROMPT ==========\n" + final_prompt + ...)` block was added inside `build_system_prompt()` to inspect the rendered prompt. This is debug code that must NOT ship with the PR. Strip it before any Layer 2 work lands.

- [ ] **Step 1: Read the file to confirm the debug block is still there**

Read: `ai-service/app/agents/kv_generator/context_builder.py` lines 75-90.

Look for a block matching:

```python
    final_prompt = "\n\n".join(sections)
    # SMOKE-TEST-ONLY: dump the rendered system prompt so we can verify the
    # brand visual-asset block actually reached the LLM. REVERT before commit.
    print("\n========== KV GENERATOR SYSTEM PROMPT ==========\n" + final_prompt + "\n========== END SYSTEM PROMPT ==========\n", flush=True)
    return final_prompt
```

- [ ] **Step 2: Replace it with the original return statement**

Replace those four lines with the single-line original:

```python
    return "\n\n".join(sections)
```

- [ ] **Step 3: Run the KV-generator test suite to confirm no regression**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/ai-service && source .venv/bin/activate && pytest tests/agents/kv_generator/ -v`
Expected: all tests still PASS (the print was non-functional debug; removing it changes nothing about behavior).

- [ ] **Step 4: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/ai-service
git add app/agents/kv_generator/context_builder.py
git commit -m "chore(ai): remove smoke-test prompt-dump debug print"
```

---

## Task 1: Intent detector — `BrandLogoIntentDetector`

**Files:**
- Create: `api/app/Services/Brand/BrandLogoIntentDetector.php`
- Test: `api/tests/Unit/Brand/BrandLogoIntentDetectorTest.php`

**Rationale:** Before fetching the logo (which costs an S3 GET on every KV stream call), decide whether the user actually wants it. Heuristic regex is cheap, fast, and good enough for v1. False positives are mitigated by a negation guard (`tanpa logo`, `no logo`, `without logo`). Adding an LLM tool call for this would double the cost per turn and is overkill at this stage.

- [ ] **Step 1: Write the failing unit test**

Create `api/tests/Unit/Brand/BrandLogoIntentDetectorTest.php`:

```php
<?php

use App\Services\Brand\BrandLogoIntentDetector;

dataset('logo_wanted_prompts', [
    ['tambahkan logo Telkomsel di pojok kanan bawah'],
    ['add the brand logo bottom-right'],
    ['use Telkomsel logo please'],
    ['pakai logo di sini'],
    ['LOGO di atas kiri'],
    ['letakkan lambang merek di pojok'],
    ['put the brand mark on top'],
]);

dataset('logo_not_wanted_prompts', [
    ['buat KV promo Telkomsel sunset cinematic'],
    ['tanpa logo, focus on the product'],
    ['no logo please'],
    ['without any branding marks'],
    ['bukan logo yang dipakai, tapi tagline'],
    ['suasana sunset dengan ombak'],
    [''],
]);

it('detects logo intent in user prompt', function (string $prompt) {
    expect(BrandLogoIntentDetector::wantsLogo($prompt))->toBeTrue();
})->with('logo_wanted_prompts');

it('rejects prompts without logo intent or with negation', function (string $prompt) {
    expect(BrandLogoIntentDetector::wantsLogo($prompt))->toBeFalse();
})->with('logo_not_wanted_prompts');
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && ./vendor/bin/pest tests/Unit/Brand/BrandLogoIntentDetectorTest.php -v`
Expected: FAIL — `Error: Class "App\Services\Brand\BrandLogoIntentDetector" not found`.

- [ ] **Step 3: Create the detector class**

Create `api/app/Services/Brand/BrandLogoIntentDetector.php`:

```php
<?php

namespace App\Services\Brand;

/**
 * Heuristic detector for "user wants the brand logo in this KV" intent.
 *
 * v1: simple keyword regex with a negation guard. The directive added to
 * the LLM system prompt in Layer 1 still tells the LLM to surface the
 * brand logo URL in image-mode prompts even when this returns false —
 * what this returns true for is "should the API server-side-fetch the
 * logo bytes and inject them as an img-to-img reference attachment."
 *
 * False positives are worse than false negatives here because a positive
 * triggers an S3 GET and routes the generation through /v1/images/edits
 * (img-to-img) instead of /v1/images/generations, which heavily anchors
 * output to the reference image. Hence the negation guard.
 */
class BrandLogoIntentDetector
{
    /**
     * Indonesian + English keywords that signal "include the brand logo."
     * Word-boundary matching keeps "monolog" / "catalogue" / "blogger"
     * from triggering. Keep this list narrow.
     */
    private const LOGO_KEYWORDS = [
        'logo',
        'lambang',
        'brand mark',
    ];

    /**
     * Phrases that REVERSE a logo-keyword match. Checked as substrings
     * (after lowercasing) to keep the regex simple. Order matters only
     * insofar as the most specific patterns appear first.
     */
    private const NEGATION_PHRASES = [
        'tanpa logo',
        'no logo',
        'without logo',
        'without any logo',
        'without any branding',
        'bukan logo',
    ];

    public static function wantsLogo(string $prompt): bool
    {
        if ($prompt === '') {
            return false;
        }

        $lower = mb_strtolower($prompt);

        foreach (self::NEGATION_PHRASES as $negation) {
            if (str_contains($lower, $negation)) {
                return false;
            }
        }

        foreach (self::LOGO_KEYWORDS as $keyword) {
            // \b word-boundary in PCRE — anchored at non-word transitions.
            // Use the `u` flag so Unicode letters count as word chars (the
            // negation guard runs on the original lowercased string, so we
            // don't lose Indonesian diacritics here).
            if (preg_match('/\b' . preg_quote($keyword, '/') . '\b/u', $lower) === 1) {
                return true;
            }
        }

        return false;
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && ./vendor/bin/pest tests/Unit/Brand/BrandLogoIntentDetectorTest.php -v`
Expected: all dataset rows PASS (7 positive + 7 negative).

- [ ] **Step 5: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
git add app/Services/Brand/BrandLogoIntentDetector.php tests/Unit/Brand/BrandLogoIntentDetectorTest.php
git commit -m "feat(api): add BrandLogoIntentDetector for KV brand-logo embedding"
```

---

## Task 2: Attachment builder — `BrandLogoAttachmentBuilder`

**Files:**
- Create: `api/app/Services/Brand/BrandLogoAttachmentBuilder.php`
- Test: `api/tests/Unit/Brand/BrandLogoAttachmentBuilderTest.php`

**Rationale:** Encapsulate the "fetch S3 bytes → MIME-validate → base64-encode → shape into Attachment array" pipeline behind a single static method so the call site in `ChatService` stays a one-liner. Failure modes (brand has no logo, S3 fetch fails, unsupported MIME) all return `null` so the caller can use a clean null-coalesce pattern. The shape returned MUST match what ai-service `Attachment` Pydantic schema accepts.

- [ ] **Step 1: Write the failing unit test**

Create `api/tests/Unit/Brand/BrandLogoAttachmentBuilderTest.php`:

```php
<?php

use App\Models\Brand;
use App\Models\User;
use App\Models\Workspace;
use App\Services\Brand\BrandLogoAttachmentBuilder;
use Illuminate\Http\Testing\File;
use Illuminate\Support\Facades\Storage;

beforeEach(function () {
    Storage::fake('s3');
});

it('returns null when the brand has no logo', function () {
    $brand = Brand::factory()
        ->for(Workspace::factory(), 'workspace')
        ->for(User::factory(), 'user')
        ->create(['logo' => null]);

    expect(BrandLogoAttachmentBuilder::tryBuild($brand))->toBeNull();
});

it('returns null when the logo S3 object is missing', function () {
    $brand = Brand::factory()
        ->for(Workspace::factory(), 'workspace')
        ->for(User::factory(), 'user')
        ->create(['logo' => 'logos/missing.png']);

    // Storage::fake('s3') is empty — the GET will return null bytes.
    expect(BrandLogoAttachmentBuilder::tryBuild($brand))->toBeNull();
});

it('builds an Attachment-shaped array when the logo PNG is present', function () {
    // Put a 1x1 transparent PNG in the fake S3 disk.
    $pngBytes = base64_decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4//8/AwAI/AL+JT04vQAAAABJRU5ErkJggg=='
    );
    Storage::disk('s3')->put('logos/test-brand-logo.png', $pngBytes);

    $brand = Brand::factory()
        ->for(Workspace::factory(), 'workspace')
        ->for(User::factory(), 'user')
        ->create([
            'name' => 'Test Brand',
            'logo' => 'logos/test-brand-logo.png',
        ]);

    $attachment = BrandLogoAttachmentBuilder::tryBuild($brand);

    expect($attachment)->toBeArray();
    expect($attachment['id'])->toBe('brand-logo-' . $brand->id);
    expect($attachment['name'])->toBe('Test Brand-logo.png');
    expect($attachment['mime_type'])->toBe('image/png');
    expect($attachment['data_base64'])->toBe(base64_encode($pngBytes));
});

it('returns null for unsupported MIME types', function () {
    // A plain text "image" — Brand UI should never produce this, but
    // defend against it so a malformed upload cannot poison the payload.
    Storage::disk('s3')->put('logos/bogus.txt', 'this is not an image');

    $brand = Brand::factory()
        ->for(Workspace::factory(), 'workspace')
        ->for(User::factory(), 'user')
        ->create(['logo' => 'logos/bogus.txt']);

    expect(BrandLogoAttachmentBuilder::tryBuild($brand))->toBeNull();
});

it('uses raw original logo path, not the presigned URL accessor', function () {
    // If the builder accidentally calls $brand->logo (the accessor) it
    // would attempt to fetch from the URL rather than from the disk path,
    // and Storage::fake() would not return the bytes. This regression
    // test pins the implementation to getRawOriginal('logo').
    $pngBytes = base64_decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4//8/AwAI/AL+JT04vQAAAABJRU5ErkJggg=='
    );
    Storage::disk('s3')->put('logos/raw-path-only.png', $pngBytes);

    $brand = Brand::factory()
        ->for(Workspace::factory(), 'workspace')
        ->for(User::factory(), 'user')
        ->create(['logo' => 'logos/raw-path-only.png']);

    $attachment = BrandLogoAttachmentBuilder::tryBuild($brand);
    expect($attachment)->not->toBeNull();
    expect($attachment['mime_type'])->toBe('image/png');
});
```

- [ ] **Step 2: Run to verify failures**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && ./vendor/bin/pest tests/Unit/Brand/BrandLogoAttachmentBuilderTest.php -v`
Expected: FAIL — `Class "App\Services\Brand\BrandLogoAttachmentBuilder" not found`.

- [ ] **Step 3: Create the builder class**

Create `api/app/Services/Brand/BrandLogoAttachmentBuilder.php`:

```php
<?php

namespace App\Services\Brand;

use App\Models\Brand;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Storage;

/**
 * Server-side fetcher for a brand's logo. Produces an Attachment-shaped
 * array compatible with the ai-service `Attachment` Pydantic schema
 * (see `ai-service/app/agents/kv_generator/request_schema.py`).
 *
 * The output, when non-null, is inserted into the `attachments` array
 * passed to ai-service's `KvStreamRequest`. ai-service decodes the base64
 * to a temp file and threads it into the image-generation tool as an
 * `image[]` reference, which routes the call through `/v1/images/edits`
 * (img-to-img mode) so gpt-image-2 actually sees the brand logo bytes
 * instead of seeing a URL string in the text prompt.
 */
class BrandLogoAttachmentBuilder
{
    /**
     * Allowed MIME types. Mirrors ai-service `Attachment.mime_type`.
     * Anything outside this list is rejected — a malformed logo upload
     * must not be allowed to poison the outbound payload.
     */
    private const ALLOWED_MIMES = [
        'image/png',
        'image/jpeg',
        'image/webp',
        'image/gif',
    ];

    /**
     * @return array{id: string, name: string, mime_type: string, data_base64: string}|null
     */
    public static function tryBuild(Brand $brand): ?array
    {
        // Bypass the JSON-only accessor — we need the raw S3 object path,
        // not a presigned/public URL. Same approach as
        // ChatService::buildBrandVisuals (commit a9ac3ed7).
        $rawPath = $brand->getRawOriginal('logo');
        if (! is_string($rawPath) || $rawPath === '') {
            return null;
        }

        try {
            $bytes = Storage::disk('s3')->get($rawPath);
        } catch (\Throwable $e) {
            Log::warning('Brand logo fetch failed for KV img-to-img reference', [
                'brand_id' => $brand->id,
                'path' => $rawPath,
                'error' => $e->getMessage(),
            ]);

            return null;
        }

        if (! is_string($bytes) || $bytes === '') {
            return null;
        }

        $mime = self::detectMime($bytes);
        if (! in_array($mime, self::ALLOWED_MIMES, true)) {
            Log::warning('Brand logo MIME type not allowed for KV img-to-img', [
                'brand_id' => $brand->id,
                'path' => $rawPath,
                'detected_mime' => $mime,
            ]);

            return null;
        }

        return [
            'id' => 'brand-logo-' . $brand->id,
            'name' => trim((string) $brand->name) . '-logo.' . self::extensionFromMime($mime),
            'mime_type' => $mime,
            'data_base64' => base64_encode($bytes),
        ];
    }

    /**
     * Sniff MIME from bytes — file extension on S3 may be wrong. We use
     * finfo against the buffer, not the path, so a `.png` upload that's
     * actually a JPEG would be classified correctly.
     */
    private static function detectMime(string $bytes): string
    {
        $finfo = new \finfo(FILEINFO_MIME_TYPE);
        $detected = $finfo->buffer($bytes);

        return is_string($detected) ? $detected : 'application/octet-stream';
    }

    private static function extensionFromMime(string $mime): string
    {
        return match ($mime) {
            'image/png' => 'png',
            'image/jpeg' => 'jpg',
            'image/webp' => 'webp',
            'image/gif' => 'gif',
            default => 'bin',
        };
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && ./vendor/bin/pest tests/Unit/Brand/BrandLogoAttachmentBuilderTest.php -v`
Expected: all 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
git add app/Services/Brand/BrandLogoAttachmentBuilder.php tests/Unit/Brand/BrandLogoAttachmentBuilderTest.php
git commit -m "feat(api): add BrandLogoAttachmentBuilder for KV img-to-img references"
```

---

## Task 3: Wire detector + builder into `ChatService::streamKvGenerator`

**Files:**
- Modify: `api/app/Services/ChatService.php` (the `$prefetched['brand']` block, around lines 383-393, plus the `$attachments` injection right after it)

**Rationale:** Layer 1 ends with `$prefetched['brand'] = array_merge(...)` inside the `if (use_brand_knowledge && brand_id)` guard. Layer 2 piggybacks on the same guard — same Brand instance is in scope, so we don't re-query. Right after the merge, conditionally call detector + builder and push the resulting Attachment into the existing `$attachments` array if both return useful values.

**Important constraints:**
- Append to `$attachments`, do NOT replace — user-uploaded attachments are still valid and must coexist with the brand logo
- Only inject in `chat` and `image` modes — NOT `edit` mode (edit mode already has a base generation as ref; adding the brand logo on top would confuse gpt-image-2 about which is the anchor)
- Do not persist the brand-logo attachment to the chat-message `files` JSONB column (the `$persistedAttachments` filter on line 379 only keeps URL-bearing entries; our injected entry has no `url`, so it correctly drops out of persistence — confirm this happens naturally)

- [ ] **Step 1: Read the current `$prefetched['brand']` block to anchor the edit**

Read `api/app/Services/ChatService.php` lines 380-395. The block should look like (after the Layer 1 + a9ac3ed7 fix):

```php
                if (($launchContext['use_brand_knowledge'] ?? false) && ! empty($launchContext['brand_id'])) {
                    $brand = \App\Models\Brand::find($launchContext['brand_id']);
                    if ($brand) {
                        $prefetched['brand'] = array_merge(
                            [
                                'brand_name' => $brand->name,
                                'dna' => self::buildBrandDna($brand),
                                'identity' => self::buildBrandIdentity($brand),
                                'tonality' => $tonalityString,
                            ],
                            self::buildBrandVisuals($brand),
                        );
                    }
                }
```

- [ ] **Step 2: Insert the Layer 2 wiring at the bottom of the inner `if ($brand)` block**

In `api/app/Services/ChatService.php`, modify the inner block to append the brand-logo injection RIGHT BEFORE the closing `}` of `if ($brand) { ... }`:

```php
                if (($launchContext['use_brand_knowledge'] ?? false) && ! empty($launchContext['brand_id'])) {
                    $brand = \App\Models\Brand::find($launchContext['brand_id']);
                    if ($brand) {
                        $prefetched['brand'] = array_merge(
                            [
                                'brand_name' => $brand->name,
                                'dna' => self::buildBrandDna($brand),
                                'identity' => self::buildBrandIdentity($brand),
                                'tonality' => $tonalityString,
                            ],
                            self::buildBrandVisuals($brand),
                        );

                        // Layer 2: when the user asks for the brand logo (e.g.
                        // "tambahkan logo Telkomsel"), server-side fetch the
                        // logo bytes and append as an `attachments[]` entry so
                        // ai-service routes the generation through
                        // /v1/images/edits (img-to-img) with the actual logo
                        // as a reference. Without this step the LLM only puts
                        // the logo URL into the text prompt — gpt-image-2 can
                        // tokenize a URL but not fetch the image behind it.
                        //
                        // Skip in edit mode: an edit turn already carries a
                        // base generation as the img-to-img anchor; layering
                        // the brand logo on top would confuse the model.
                        if (
                            $mode !== 'edit'
                            && \App\Services\Brand\BrandLogoIntentDetector::wantsLogo($userQuery)
                        ) {
                            $logoAttachment = \App\Services\Brand\BrandLogoAttachmentBuilder::tryBuild($brand);
                            if ($logoAttachment !== null) {
                                $attachments[] = $logoAttachment;
                            }
                        }
                    }
                }
```

- [ ] **Step 3: Run the existing test suite (sanity, no new tests yet)**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && ./vendor/bin/pest tests/Feature/Chat/BrandAssetFeedingTest.php -v`
Expected: still 2/2 PASS — the Layer-1 tests should not regress (they construct prompts without the keyword "logo," so the new branch is not exercised).

- [ ] **Step 4: PHP syntax sanity**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && php -l app/Services/ChatService.php`
Expected: `No syntax errors detected`.

- [ ] **Step 5: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
git add app/Services/ChatService.php
git commit -m "feat(api): inject brand logo as img-to-img reference when user requests it"
```

---

## Task 4: Feature test — outbound payload carries the brand-logo attachment

**Files:**
- Create: `api/tests/Feature/Chat/BrandLogoEmbeddingTest.php`

**Rationale:** Tasks 1-3 are wired but only unit-tested at the component level. This is the integration check: given a real brand with a real logo, when the user types a prompt mentioning "logo," does the outbound HTTP body to ai-service carry the logo bytes in `attachments[]`? Mirrors `BrandAssetFeedingTest.php` (the Layer-1 feature test) in structure so the patterns are familiar.

- [ ] **Step 1: Inspect `BrandAssetFeedingTest.php` to copy the setup boilerplate**

Read `api/tests/Feature/Chat/BrandAssetFeedingTest.php` — note the `beforeEach` middleware setup (Tool factory, SubscriptionPlan, credit grant, etc.), `Storage::fake('s3')` (from the polish commit 14c227a5), and the `Http::recorded()` lookup pattern. Reuse the same patterns here.

- [ ] **Step 2: Write the feature test file**

Create `api/tests/Feature/Chat/BrandLogoEmbeddingTest.php`. Copy the EXACT `beforeEach` and request-body shape from `BrandAssetFeedingTest.php` — do not invent fields. The two NEW things this file does are: (a) seed the fake S3 disk with PNG bytes at the brand's logo path before the request, and (b) assert against the `attachments` array in the recorded outbound payload.

```php
<?php

use App\Models\Brand;
use App\Models\User;
use App\Models\Workspace;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Storage;

beforeEach(function () {
    // (Copy the same middleware setup as BrandAssetFeedingTest.php — Tool
    // factory with slug 'kv-generator', SubscriptionPlan::create(...),
    // user + workspace credit grants, role assignment with chat.write
    // permission, etc. Do NOT skip this — the KV stream route fails the
    // FormRequest validation otherwise.)
    //
    // Then add the fake S3 disk so BrandLogoAttachmentBuilder finds bytes:
    Storage::fake('s3');
    Http::fake();
});

/**
 * Tiny valid PNG used as the seeded brand logo. 1×1 transparent.
 * Base64 picks the smallest legal PNG so the test payload stays small.
 */
function seedBrandLogo(string $path): string
{
    $bytes = base64_decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4//8/AwAI/AL+JT04vQAAAABJRU5ErkJggg=='
    );
    Storage::disk('s3')->put($path, $bytes);

    return $bytes;
}

it('attaches brand logo bytes to ai-service payload when user mentions logo', function () {
    [$user, $workspace, $thread] = makeKvSetup(); // helper from BrandAssetFeedingTest pattern

    $logoBytes = seedBrandLogo('logos/test-brand.png');
    $brand = Brand::factory()->create([
        'workspace_id' => $workspace->id,
        'user_id' => $user->id,
        'name' => 'TestCo',
        'logo' => 'logos/test-brand.png',
    ]);

    $thread->update([
        'launch_context' => array_merge(
            (array) $thread->launch_context,
            ['use_brand_knowledge' => true, 'brand_id' => $brand->id],
        ),
    ]);

    $response = actingAs($user, 'api')->postJson("/api/v1/threads/{$thread->id}/stream", [
        'message' => 'tambahkan logo brand di pojok kanan bawah, suasana sunset',
        'mode' => 'image',
        // ... include other required keys per StreamChatRequest FormRequest
    ]);
    $response->streamedContent(); // flush the StreamedResponse so Http::fake records the outbound POST

    Http::assertSent(fn ($request) => str_contains($request->url(), '/kv-generator/stream'));

    $recorded = collect(Http::recorded())
        ->first(fn ($pair) => str_contains($pair[0]->url(), '/kv-generator/stream'));
    expect($recorded)->not->toBeNull();

    $attachments = $recorded[0]->data()['attachments'] ?? [];
    $brandLogo = collect($attachments)->firstWhere('id', 'brand-logo-' . $brand->id);

    expect($brandLogo)->not->toBeNull();
    expect($brandLogo['mime_type'])->toBe('image/png');
    expect($brandLogo['name'])->toBe('TestCo-logo.png');
    expect(base64_decode($brandLogo['data_base64']))->toBe($logoBytes);
});

it('does NOT attach brand logo when prompt has no logo intent', function () {
    [$user, $workspace, $thread] = makeKvSetup();

    seedBrandLogo('logos/another.png');
    $brand = Brand::factory()->create([
        'workspace_id' => $workspace->id,
        'user_id' => $user->id,
        'logo' => 'logos/another.png',
    ]);

    $thread->update([
        'launch_context' => array_merge(
            (array) $thread->launch_context,
            ['use_brand_knowledge' => true, 'brand_id' => $brand->id],
        ),
    ]);

    actingAs($user, 'api')->postJson("/api/v1/threads/{$thread->id}/stream", [
        'message' => 'buat KV promo sunset cinematic',
        'mode' => 'image',
        // ... include other required keys
    ])->streamedContent();

    $recorded = collect(Http::recorded())
        ->first(fn ($pair) => str_contains($pair[0]->url(), '/kv-generator/stream'));
    $attachments = $recorded[0]->data()['attachments'] ?? [];

    expect(collect($attachments)->where('id', 'brand-logo-' . $brand->id))->toHaveCount(0);
});

it('does NOT attach brand logo in edit mode even with logo intent', function () {
    [$user, $workspace, $thread] = makeKvSetup();

    seedBrandLogo('logos/edit-mode.png');
    $brand = Brand::factory()->create([
        'workspace_id' => $workspace->id,
        'user_id' => $user->id,
        'logo' => 'logos/edit-mode.png',
    ]);

    $thread->update([
        'launch_context' => array_merge(
            (array) $thread->launch_context,
            ['use_brand_knowledge' => true, 'brand_id' => $brand->id],
        ),
    ]);

    actingAs($user, 'api')->postJson("/api/v1/threads/{$thread->id}/stream", [
        'message' => 'tambahkan logo di area pojok kanan bawah',
        'mode' => 'edit',
        'base_generation_id' => /* a fake base generation id seeded earlier in makeKvSetup */ null,
        // ... include other required keys + edit-mode bounding boxes
    ])->streamedContent();

    $recorded = collect(Http::recorded())
        ->first(fn ($pair) => str_contains($pair[0]->url(), '/kv-generator/stream'));
    $attachments = $recorded[0]->data()['attachments'] ?? [];

    expect(collect($attachments)->where('id', 'brand-logo-' . $brand->id))->toHaveCount(0);
});
```

> **Note for the engineer:** The three `postJson` calls have `// ... include other required keys` markers. Look at `BrandAssetFeedingTest.php`'s `postJson` body (already correct against the current `StreamChatRequest` FormRequest) and copy the full body shape into each test, substituting only the `message`, `mode`, and `base_generation_id` keys as shown. Do NOT invent fields — the FormRequest will reject them. The `makeKvSetup()` helper does not exist yet; extract the `beforeEach` setup from BrandAssetFeedingTest.php into a Pest helper function in the same file (or pull it up to a shared `tests/Helpers.php` if there is one), returning `[$user, $workspace, $thread]`. If extraction is too invasive, copy the body inline in each test — duplication is fine for v1.

- [ ] **Step 3: Run the feature test**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && ./vendor/bin/pest tests/Feature/Chat/BrandLogoEmbeddingTest.php -v`
Expected: 3/3 PASS.

If a test fails, the most likely causes are: (a) `StreamChatRequest` rejected the request body — `dd($response->json())` once to see the validation error; (b) the brand-logo attachment ended up in `$persistedAttachments` (DB persistence) instead of the outbound array — that would be a bug to fix in Task 3, not here; (c) `Storage::fake('s3')` and the builder's disk name disagree (`s3` vs `s3-staging` etc.) — match what `filesystems.php` declares.

- [ ] **Step 4: Run the full Chat feature suite to catch regressions**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && ./vendor/bin/pest tests/Feature/Chat/ -v 2>&1 | tail -20`
Expected: `BrandAssetFeedingTest` still 2/2 PASS; `BrandLogoEmbeddingTest` 3/3 PASS. Other Chat tests (e.g. `StreamChatKvModeTest`) may have pre-existing failures unrelated to this work — call those out separately.

- [ ] **Step 5: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
git add tests/Feature/Chat/BrandLogoEmbeddingTest.php
git commit -m "test(api): cover brand-logo attachment injection in KV stream payload"
```

---

## Task 5: End-to-end smoke + PR description update

**Files:** none modified — verification + docs only.

**Rationale:** Confirm the full path actually produces a real logo in the generated KV with both services running. Then update the PR draft to cover both layers.

- [ ] **Step 1: Run the consolidated test suites**

Run:
```
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/ai-service && source .venv/bin/activate && pytest tests/agents/kv_generator/ -v
```
Expected: all kv_generator subtree tests pass. Pre-existing failures elsewhere are out of scope.

Run:
```
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && ./vendor/bin/pest tests/Unit/Brand tests/Feature/Chat -v
```
Expected: `BrandLogoIntentDetectorTest`, `BrandLogoAttachmentBuilderTest`, `BrandAssetFeedingTest`, `BrandLogoEmbeddingTest` all pass.

- [ ] **Step 2: Bootstrap-cache pre-flight (avoid the DB-wipe foot-gun)**

Run:
```
ls /Users/alva.e202511001/Desktop/work/frndos-agentic/api/bootstrap/cache/config.php 2>&1 || echo "OK: no cached config"
```
Expected: `OK: no cached config` (or the file does not exist).

If `config.php` exists, run `php artisan config:clear` first. This is the bug from the earlier session — cached config bakes `DB_CONNECTION=pgsql` and overrides phpunit.xml's SQLite override, so `RefreshDatabase` wipes the real Postgres dev DB instead of an in-memory SQLite. DO NOT proceed until cache is cleared.

- [ ] **Step 3: Manual smoke against a real brand**

In two terminals:
- Terminal A: `cd api && php artisan serve --port=9191` (NOT `optimize` — see Step 2)
- Terminal B: `cd ai-service && source .venv/bin/activate && fastapi dev`

Frontend (http://localhost:3000) — login, switch to a workspace that contains a brand with a populated logo (e.g. the FCN workspace's Telkomsel brand in the staging dump), open the KV generator, toggle brand knowledge ON, pick the brand, and submit:

```
buat KV promo Telkomsel sunset cinematic, dengan logo brand di pojok kanan bawah
```

Expected outcomes:
- The Network tab shows the api streaming the outbound `/api/v1/threads/{id}/stream` request with `attachments[0].id = 'brand-logo-{brand_id}'`
- ai-service log shows `POST https://api.openai.com/v1/images/edits` (NOT `/v1/images/generations`) — confirming the img-to-img route was taken
- The generated KV embeds the ACTUAL Telkomsel logo, not a hand-drawn "TELKOMSEL" text mark

If the model still draws text instead of the real logo: confirm the recorded outbound request to OpenAI hit `/v1/images/edits` and the multipart body contained the image bytes. If it didn't, ai-service may have a routing condition that didn't trigger — fall back to checking the existing `KvStreamRequest` handler in ai-service for the chat/image attachment dispatch logic.

- [ ] **Step 4: Update the PR draft**

Update `/Users/alva.e202511001/Desktop/work/frndos-agentic/docs/superpowers/notes/2026-05-26-kv-brand-asset-feeding-pr-draft.md` (the Layer-1 draft) so it covers both layers:

- Mention that Layer 2 ships server-side fetch + img-to-img injection
- Add the new ai-service revert commit to the commits list
- Add the three new api commits (intent detector, attachment builder, ChatService wire-in, feature test)
- Update the "Test plan" section to include the new smoke step ("manual: ai-service log shows /v1/images/edits route was taken")

Do this with `Edit` against the existing file, not a rewrite. Keep the Layer-1 sections intact.

- [ ] **Step 5: Final commit (housekeeping)**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic
git add docs/superpowers/notes/2026-05-26-kv-brand-asset-feeding-pr-draft.md
git commit -m "docs: extend KV brand-asset PR draft to cover layer 2 (img-to-img embedding)"
```

---

## Self-review checklist

- ✅ **Spec coverage:** S3 fetch + intent detection + MIME validation + ChatService wire-in + feature test + smoke verification + cleanup of Layer-1 debug print → all tasks present.
- ✅ **No placeholders:** Every code step shows the exact code. The `// ... include other required keys` markers in Task 4's `postJson` bodies are explicit pointers to `BrandAssetFeedingTest.php` for the FormRequest body shape, not invitations to invent fields — same approach as Layer-1 plan's Task 5.
- ✅ **Type consistency:**
  - `BrandLogoIntentDetector::wantsLogo(string): bool` — used the same signature in Task 1 (definition), Task 3 (call site), Task 4 (test).
  - `BrandLogoAttachmentBuilder::tryBuild(Brand): ?array` — same signature across Task 2, Task 3 call site, Task 4 expectations.
  - Returned array shape `['id', 'name', 'mime_type', 'data_base64']` — matches the ai-service `Attachment` Pydantic schema (verified in writing-plans research above).
- ✅ **TDD:** Tasks 1, 2, 4 start with failing tests. Task 3 is a structural wire-in that's verified by Task 4's feature test (same pattern as Layer-1 Task 4/5 split).
- ✅ **Frequent commits:** One commit per task.
- ✅ **DRY:** Intent detection and attachment building are separate classes so each is independently testable. ChatService stays thin — just calls both.
- ✅ **YAGNI:** No LLM tool-call intent detection, no caching, no Redis, no logo variant selection. All deferred.
- ✅ **Bootstrap-cache foot-gun:** Task 5 Step 2 has an explicit pre-flight check + remediation for the cached-config DB-wipe bug we hit in the smoke-test session.
- ✅ **Edit-mode skip:** Task 3 explicitly excludes `mode = 'edit'` from the attachment injection to avoid stacking refs on top of the base generation.
