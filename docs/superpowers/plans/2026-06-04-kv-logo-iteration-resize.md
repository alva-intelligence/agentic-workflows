# KV Logo — Iteration-Safe Source + Resize Re-bake — Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or executing-plans. Steps use `- [ ]`.

**Goal:** Stop the baked logo from being redrawn/doubled when a generation is iterated (craft/edit) or resized, by (a) keeping a logo-free `source_image_url` per generation and using it as the img-to-img base, and (b) re-baking the logo fresh at the new aspect ratio in the resize flow.

**Architecture:** The image tool already produces a logo-free render (prompt is stripped of logo text). We currently bake over it and discard the logo-free URL. Keep it as `source_image_url`. craft/edit use that logo-free URL as their img-to-img base → gpt-image never sees a baked logo → no redraw. Resize starts from the logo-free source and re-bakes the logo at the new dimensions (anchor/scale recompute automatically because `stamp_logo` is canvas-relative). Web is untouched (`image_url` stays the baked, displayed/downloaded image).

**Tech Stack:** ai-service (Python, Pillow), api (Laravel 13, PostgreSQL). No web changes.

**Branches:** ai-service `development`, api `develop` (commit on current branch; do not push — user pushes manually).

**Builds on:** the strict-bake feature (spec `2026-06-04-kv-brand-logo-strict-bake-design.md`) and fix #1 (logo-sentence strip, commit c59d10e).

---

## Data model

`kv_generations` gains a nullable `source_image_url` (the logo-free render). `image_url` stays the baked image. Resize *exports* (`kv_resize_exports`) are terminal — no new column there.

Per-generation invariant after this change:
- `image_url` = baked (what the user sees/downloads) — unchanged contract.
- `source_image_url` = logo-free render (used only as the img-to-img base for the next craft/edit, and as the resize source). Null for old rows → callers fall back to `image_url`.

---

## ai-service tasks

### Task A1: Emit `source_image_url` from kv_generator (image + edit)

**File:** `ai-service/app/agents/kv_generator/service.py`

- [ ] **Step 1: image mode — capture the pre-bake URL**

In `_run_image_mode`, the stamp block (around lines 394-398) currently is:
```python
    stamped_url = _maybe_stamp_logo_url(render["image_url"], request, resolved_stamp)
    render["image_url"] = stamped_url
    render["thumbnail_url"] = stamped_url
```
Replace with:
```python
    # Keep the logo-free render as the iteration source; bake only into the
    # displayed image_url. craft/edit will reuse source_image_url as the
    # img-to-img base so the model never redraws a baked logo.
    source_url = render["image_url"]
    stamped_url = _maybe_stamp_logo_url(source_url, request, resolved_stamp)
    render["image_url"] = stamped_url
    render["thumbnail_url"] = stamped_url
    render["source_image_url"] = source_url
```

- [ ] **Step 2: image mode — add to the GenerationReady payload**

In the `GenerationReadyEvent(payload={...})` in `_run_image_mode` (lines ~415-436), add after `"image_url": render["image_url"],`:
```python
        "source_image_url": render.get("source_image_url"),
```

- [ ] **Step 3: edit mode — capture + emit**

In `_run_edit_mode`, the stamp block (lines ~1215-1218):
```python
    if request.brand_logo_stamp is not None:
        image_url = _maybe_stamp_logo_url(image_url, request, request.brand_logo_stamp)
```
Replace with:
```python
    source_image_url = image_url  # logo-free edit result (pre-bake)
    if request.brand_logo_stamp is not None:
        image_url = _maybe_stamp_logo_url(image_url, request, request.brand_logo_stamp)
```
Then in the edit-mode `GenerationReadyEvent` payload (lines ~1221-1239), add after `"image_url": image_url,`:
```python
            "source_image_url": source_image_url,
```

- [ ] **Step 4: import-load + commit**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/ai-service && source .venv/bin/activate && python -c "import app.agents.kv_generator.service"`
Then commit: `git add app/agents/kv_generator/service.py && git commit -m "feat(ai): emit logo-free source_image_url from kv generations"`

---

### Task A2: Re-bake the logo in kv_resize

**Files:**
- `ai-service/app/agents/kv_resize/request_schema.py`
- `ai-service/app/agents/kv_resize/service.py`
- `ai-service/app/agents/kv_resize/api_client.py`

- [ ] **Step 1: extend `ResizeExportRequest`**

In `request_schema.py`, import the shared types and add fields:
```python
from app.agents.kv_generator.request_schema import BrandLogoAsset, BrandLogoStamp
```
Add to `ResizeExportRequest`:
```python
    brand_logo: Optional[BrandLogoAsset] = None
    brand_logo_stamp: Optional[BrandLogoStamp] = None
```
(`Optional` is already imported.)

- [ ] **Step 2: re-bake before upload in `process_resize_export`**

In `service.py`, add at top:
```python
from app.agents.kv_generator.logo_stamp import stamp_logo
```
After the resized `image_bytes` is produced and BEFORE `save_bytes_to_file(...)` (around line 175), insert:
```python
        # Strict bake: the source was logo-free, so re-stamp the brand logo
        # at the NEW dimensions (stamp_logo is canvas-relative, so the
        # anchor/scale recompute correctly for this platform's aspect).
        if req.brand_logo is not None and req.brand_logo_stamp is not None:
            try:
                import base64 as _b64
                image_bytes = stamp_logo(
                    image_bytes,
                    _b64.b64decode(req.brand_logo.data_base64),
                    req.brand_logo_stamp,
                )
            except Exception as exc:  # noqa: BLE001 — never break the export
                from agno.utils.log import log_warning
                log_warning(f"KV resize logo re-bake failed; exporting unstamped: {exc!r}")
```

- [ ] **Step 3: import-load + commit**

Run: `cd ai-service && source .venv/bin/activate && python -c "import app.agents.kv_resize.service"`
Commit: `git add app/agents/kv_resize/ && git commit -m "feat(ai): re-bake brand logo at new aspect in kv resize export"`

> Note: resize uses the persisted stamp directly (no classifier) — placement is the sticky spec from the studio file, supplied by the api job (api Task B5). No `source_image_url` is emitted for exports (they are terminal/non-iterated).

---

## api tasks

### Task B1: `source_image_url` column + model

- [ ] **Step 0:** DB-safety pre-flight (no cached `bootstrap/cache/config.php`; phpunit.xml sqlite active) — same as the strict-bake api plan Task 0.
- [ ] **Step 1:** Create migration `database/migrations/2026_06_04_010000_add_source_image_url_to_kv_generations_table.php`:
```php
<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('kv_generations', function (Blueprint $table) {
            // Logo-free render kept for img-to-img iteration + resize source.
            // image_url stays the baked (displayed/downloaded) image.
            $table->string('source_image_url')->nullable()->after('image_url');
        });
    }

    public function down(): void
    {
        Schema::table('kv_generations', function (Blueprint $table) {
            $table->dropColumn('source_image_url');
        });
    }
};
```
- [ ] **Step 2:** Add `'source_image_url'` to `app/Models/KvGeneration.php` `$fillable` (after `'image_url'`).
- [ ] **Step 3:** `php artisan migrate` (applies the new column). Confirm column exists via tinker `Schema::hasColumn('kv_generations','source_image_url')`.
- [ ] **Step 4:** Commit `git add database/migrations/2026_06_04_010000_* app/Models/KvGeneration.php && git commit -m "feat(api): add source_image_url to kv_generations"`

### Task B2: persist `source_image_url`

**File:** `app/Services/Studio/KvGenerationService.php`
- [ ] In `persistCompletion()`, where the create array is built (lines ~27-41), add:
```php
            'source_image_url' => $payload['source_image_url'] ?? ($payload['image_url'] ?? null),
```
(Fallback to `image_url` so a payload without the new key still records a usable base.)
- [ ] `php -l` + commit `git commit -m "feat(api): persist source_image_url on kv generations"`.

### Task B3: prefer logo-free base for craft/edit

**File:** `app/Http/Controllers/Api/Chat/ThreadController.php` (lines ~530-533)
- [ ] Change the `$baseGeneration` array's image url to prefer the logo-free source:
```php
        $baseGeneration = [
            'id' => $baseGen->id,
            'image_url' => $baseGen->source_image_url ?: $baseGen->image_url,
        ];
```
- [ ] `php -l` + commit `git commit -m "feat(api): use logo-free source as img-to-img base for craft/edit"`.

### Task B4: extract `BrandLogoAssetBuilder` (DRY) and use it in ChatService

**Files:**
- Create `app/Services/Brand/BrandLogoAssetBuilder.php`
- Modify `app/Services/ChatService.php`

- [ ] **Step 1:** Move the body of `ChatService::buildBrandLogoAsset()` into a reusable class:
```php
<?php

namespace App\Services\Brand;

use App\Models\Brand;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Storage;

class BrandLogoAssetBuilder
{
    /**
     * Read the brand's logo bytes from S3 and return them base64-encoded
     * for the ai-service strict-bake compositor, or null on any failure.
     *
     * @return array{data_base64: string, mime_type: string}|null
     */
    public static function tryBuild(Brand $brand): ?array
    {
        $rawLogo = $brand->getRawOriginal('logo');
        if (! is_string($rawLogo) || $rawLogo === '') {
            return null;
        }

        try {
            $bytes = Storage::disk('s3')->get($rawLogo);
        } catch (\Throwable $e) {
            Log::warning('KV brand logo fetch failed for strict bake', [
                'brand_id' => $brand->id, 'path' => $rawLogo, 'error' => $e->getMessage(),
            ]);

            return null;
        }

        if (! is_string($bytes) || $bytes === '') {
            return null;
        }

        $mime = (new \finfo(FILEINFO_MIME_TYPE))->buffer($bytes) ?: '';
        if (! in_array($mime, ['image/png', 'image/jpeg', 'image/webp'], true)) {
            Log::warning('KV brand logo MIME not allowed for strict bake', [
                'brand_id' => $brand->id, 'mime' => $mime,
            ]);

            return null;
        }

        return ['data_base64' => base64_encode($bytes), 'mime_type' => $mime];
    }
}
```

- [ ] **Step 2:** In `ChatService.php`, replace the private `buildBrandLogoAsset()` body so it delegates (keep the call sites working), or replace the call site `self::buildBrandLogoAsset($brand)` with `\App\Services\Brand\BrandLogoAssetBuilder::tryBuild($brand)` and delete the private method. Prefer deleting the private method + updating the one call site + adding `use App\Services\Brand\BrandLogoAssetBuilder;`.
- [ ] **Step 3:** `php -l app/Services/ChatService.php` + commit both files: `git commit -m "refactor(api): extract BrandLogoAssetBuilder for reuse"`.

### Task B5: resize job sends logo-free source + brand logo + stamp

**File:** `app/Jobs/Studio/ProcessKvResizeExportJob.php` (payload at lines ~48-57)
- [ ] **Step 1:** Load the studio file + brand and build the logo asset. Before the `Http::...->post(...)` call, add:
```php
        $studioFile = $row->studioFile; // or StudioFile::find($row->studio_file_id)
        $brandLogo = null;
        $brandLogoStamp = $studioFile?->brand_logo_stamp ?: null;
        $brand = $studioFile?->brand_id ? \App\Models\Brand::find($studioFile->brand_id) : null;
        if ($brand && $brandLogoStamp) {
            $brandLogo = \App\Services\Brand\BrandLogoAssetBuilder::tryBuild($brand);
        }
```
(Only build the logo bytes when a stamp exists — no stamp means nothing to re-bake.)
- [ ] **Step 2:** Change the payload (line ~50) to use the logo-free parent source and add the logo fields:
```php
        ->post("{$aiUrl}/ai/kv-resize/export", [
            'export_id' => $row->id,
            'source_image_url' => $row->parentGeneration->source_image_url
                ?: $row->parentGeneration->image_url,
            'target_width' => $row->width,
            'target_height' => $row->height,
            'crop_window' => $row->crop_window,
            'model' => $model,
            'force_ai' => (bool) config('services.ai.kv_resize_force_ai'),
            'use_vision_prepass' => (bool) config('services.ai.kv_resize_vision_prepass'),
            'brand_logo' => $brandLogo,
            'brand_logo_stamp' => $brandLogoStamp,
        ]);
```
Confirm `$row->studioFile` / `$row->parentGeneration` relations exist on `KvResizeExport` (the model has `parentGeneration`; add/confirm a `studioFile` relation, else use `StudioFile::find($row->studio_file_id)`).
- [ ] **Step 3:** `php -l` + commit `git commit -m "feat(api): feed logo-free source + brand logo into resize re-bake"`.

---

## Verification (manual smoke — no Pest this round, per user)

- [ ] ai-service imports clean (`python -c "import app.agents.kv_generator.service"` and `import app.agents.kv_resize.service`).
- [ ] api `php -l` on every modified file; `php artisan migrate` ran the new column.
- [ ] Smoke: place a logo (bottom-right), then **craft/iterate** ("make background bluer") → logo stays single + crisp (no double from the reference). Then **Resize** to a different platform aspect → logo re-baked at the correct corner/size for the new dimensions (not stretched).
- [ ] DB: `kv_generations.source_image_url` populated (logo-free), `image_url` baked.

## Notes / scope
- Web: no changes (`image_url` is still the baked, displayed image).
- Old generations (null `source_image_url`) fall back to `image_url` everywhere.
- Resize exports remain terminal (no `source_image_url` column on `kv_resize_exports`).
