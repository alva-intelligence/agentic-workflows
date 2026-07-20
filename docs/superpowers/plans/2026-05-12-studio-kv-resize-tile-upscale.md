# KV Resize — Per-Tile Upscale-on-Download Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users upscale any individual resize tile (Instagram Post, Instagram Landscape, etc.) the same way they upscale a source generation today. Replace the bare download-arrow icon on each resize tile row with the same 4-row dropdown the top-nav uses on Sketch/Craft (`Tile size / 1.5× size / 2× size`), so a tile can be downloaded at native dimensions or AI-upscaled and auto-downloaded.

**Motivation:** The top-bar `KvDownloadDropdown` only upscales the source generation. In Resize mode the user is working with multiple platform tiles, and there is no path to get a larger version of any one tile. Per the 2026-05-12 decision the top-bar dropdown is now hidden in Resize (see [KvCanvasTopNav.tsx:271](web/src/components/studio/kv-generator/KvCanvasTopNav.tsx:271)), making this the only remaining gap to make Resize feel complete.

**Architecture:** Mirrors the existing `kv_generation_upscales` feature one-to-one but keyed off `kv_resize_exports` instead of `kv_generations`. New `kv_resize_export_upscales` table, new controller / service / job / resource / internal-complete in api, new agent in ai-service that reuses the existing `upscale()` primitive in `app/tools/upscale_image.py`, and a new dropdown component in web that swaps in place of the current download button on the tile row.

**Tech Stack:** PHP 8.5 / Laravel 12 / Pest 4 (api), Python 3.12 / FastAPI / Pillow (ai-service), Next.js 15 / React 19 / Zustand 5 / vitest / Testing Library (web).

**Reference feature:** [`2026-05-06-studio-kv-upscale-download-*`](docs/superpowers/plans/) — three-service plan for the source-generation upscale. This plan is intentionally structured the same way so an agent that has executed that plan recognises every step.

**Spec:** none — this plan is small enough to embed the design notes inline. If the team prefers a separate spec, snapshot the "Design notes" section below into `docs/superpowers/specs/2026-05-12-studio-kv-resize-tile-upscale-design.md` and reference it here.

**Project test policy:** `api/AGENTS.md` and `ai-service/AGENTS.md` both state: *"DO NOT MAKE OR RUN ANY TESTS WITHOUT USER PERMISSION."* Tasks that add or run tests are gated below. Default flow is code-first; pause for user before running tests.

---

## Design notes

### Schema: new table vs. polymorphic existing table

**Decision:** New table `kv_resize_export_upscales`. Mirrors `kv_generation_upscales` 1:1 with a different FK column.

**Rejected alternative:** Add `parent_type` / `parent_id` to `kv_generation_upscales`. Cleaner long-term, but rewriting the existing unique key and indexes on a populated table is migration risk we don't need for a v1. Revisit when a third upscale source appears.

### Quota

Per-tile upscales count against the same `upscale-start:{userId}` RateLimiter bucket as source-generation upscales (default 30/hour, `studio.upscale_rate_limit_per_hour`). Otherwise the user could 5× their quota by spawning five tiles. No new config key.

### Idempotency

`UNIQUE (kv_resize_export_id, factor)` matches the source-side `UNIQUE (kv_generation_id, factor)`. Re-clicking 1.5× on the same tile returns the cached row (Ready or in-flight) instead of starting a second job.

### Cascade

`onDelete: cascade` from `kv_resize_export_id` so deleting a tile drops its upscales. Matches how generation deletes cascade to their upscales today.

### Top-bar dropdown

Stays hidden in Resize mode (already shipped). This plan does **not** re-expose it. If we ever want a "Download everything" mega-menu in Resize, that's a separate scope.

### Original row

`KvResizeOriginalRow` (the source image shown above the tiles) also gets the new dropdown swap — even though "Original" technically maps to a `kv_generations` row, we route it through the **existing** source-upscale endpoint (no new code path), just rendered with the same component for visual consistency. This is a render-only change in that file; data flow uses today's `useUpscales`.

---

## File Structure

### api (Laravel) — modify and add

| File | Action | Responsibility |
|------|--------|----------------|
| `database/migrations/2026_05_12_120000_create_kv_resize_export_upscales_table.php` | NEW | Mirror of `kv_generation_upscales` schema with `kv_resize_export_id` FK. |
| `app/Enums/KvResizeExportUpscaleStatus.php` | NEW | `pending / generating / done / failed`. Identical to `KvGenerationUpscaleStatus`. |
| `app/Models/KvResizeExportUpscale.php` | NEW | Eloquent model, ULID, soft deletes, casts. |
| `app/Models/KvResizeExport.php` | MODIFY | Add `upscales(): HasMany` relation. |
| `app/Http/Resources/Studio/KvResizeExportUpscaleResource.php` | NEW | Wire shape — `id, kvResizeExportId, studioFileId, factor, width, height, imageUrl, modelVersion, status, errorMessage, createdAt, updatedAt`. camelCase. |
| `app/Services/Studio/KvResizeExportUpscaleService.php` | NEW | `getOrCreate(file, export, factor, userId)`, `retry(row)`, `markCompleted(row, …)`. |
| `app/Jobs/Studio/ProcessKvResizeExportUpscaleJob.php` | NEW | POST to ai-service `/v1/kv-resize-tile-upscale` with `{ upscale_id, source_image_url, factor }`. |
| `app/Http/Controllers/Api/Studio/KvResizeExportUpscaleController.php` | NEW | `index / store / retry / stream` — same shape as `KvGenerationUpscaleController`. |
| `app/Http/Controllers/Api/Internal/KvResizeExportUpscaleInternalController.php` | NEW | `complete` callback. |
| `app/Http/Requests/Internal/KvResizeExportUpscaleCompleteRequest.php` | NEW | Validation for `image_url, width, height, model_version, status, error_message`. |
| `routes/api.php` | MODIFY | Public: `v1/studio/kv-generator/files/{file}/resize-exports/{export}/upscales` (index/store) + `/stream` (SSE) + `/{upscale}/retry` (retry). Internal: `internal/kv-resize-tile-upscales/completed` (id is in the body, not the URL; method name is `completed`, not `complete`). |
| `tests/Feature/Studio/KvResizeExportUpscaleControllerTest.php` | NEW (gated) | Index/store/retry/stream/cache happy-paths and 403/404/422 edges. |
| `tests/Feature/Internal/KvResizeExportUpscaleInternalControllerTest.php` | NEW (gated) | Completion callback success + failure rows. |

### ai-service (FastAPI) — add

| File | Action | Responsibility |
|------|--------|----------------|
| `app/agents/kv_resize_tile_upscale/__init__.py` | NEW | Package marker. |
| `app/agents/kv_resize_tile_upscale/request_schema.py` | NEW | `KvResizeTileUpscaleRequest` with `upscale_id, source_image_url, factor`. |
| `app/agents/kv_resize_tile_upscale/service.py` | NEW | `process_tile_upscale(req)` — download → `upscale(path, factor)` (reuses [`app/tools/upscale_image.py`](ai-service/app/tools/upscale_image.py)) → upload to S3 → `post_completed`. |
| `app/agents/kv_resize_tile_upscale/api_client.py` | NEW | POST to api `/internal/kv-resize-export-upscales/{id}/complete`. |
| `app/agents/kv_resize_tile_upscale/router.py` | NEW | FastAPI router mounting `POST /ai/kv-resize-tile-upscale/run` returning 202 and scheduling `process_tile_upscale` on the worker pool. Matches the `/ai/kv-upscale/*` prefix convention used by the existing source-generation upscale agent. |
| `app/main.py` | MODIFY | Include the new router. |
| `tests/agents/kv_resize_tile_upscale/test_service.py` | NEW (gated) | Mock Replicate + httpx; assert callback fired with PNG URL + dimensions. |

### web (Next.js) — add and modify

| File | Action | Responsibility |
|------|--------|----------------|
| `src/types/kv/resize-tile-upscale.ts` | NEW | `KvResizeTileUpscale` type (mirrors `KvGenerationUpscale`); `UPSCALE_FACTORS` reused from `@/types/kv/upscale`; reuse `deriveRowState`. |
| `src/services/kv/api.ts` | MODIFY | Add `listTileUpscales / createTileUpscale / retryTileUpscale` against `…/resize-exports/{exportId}/upscales`. |
| `src/services/kv/resize-tile-upscale-stream.ts` | NEW | SSE client mirroring `upscale-stream.ts`. |
| `src/store/kv/useKvResizeTileUpscaleStore.ts` | NEW | Zustand store: `upscalesByExportId: Map<exportId, Map<factor, row>>`, `pendingDownloadIds`, `downloadHandler`. Mirrors `useKvUpscaleStore`. |
| `src/lib/studio/kv/useResizeTileUpscales.ts` | NEW | `useResizeTileUpscales(fileId, exportId, fileName, platformId)` — list query + SSE + polling fallback + auto-download wiring. |
| `src/components/studio/kv-generator/KvTileDownloadDropdown.tsx` | NEW | Same 4-row Radix `DropdownMenu` as `KvDownloadDropdown`. Rows: `Tile size / 1.5× size / 2× size`. Reuses `KvDownloadDropdownRow`. |
| `src/components/studio/kv-generator/KvResizeResultRow.tsx` | MODIFY | Replace the bare `<button aria-label="Download">` with `<KvTileDownloadDropdown export={row} … />`. Keep the regenerate button untouched. |
| `src/components/studio/kv-generator/KvResizeOriginalRow.tsx` | MODIFY | Same swap; data source is the existing source-upscale path via `useUpscales`. |
| `src/components/studio/kv-generator/KvTileDownloadDropdown.test.tsx` | NEW (gated) | Idle → start → running → ready → download; failed → retry. Mirror of `KvDownloadDropdownRow.test.tsx`. |

---

## Task 1 (api): Migration for `kv_resize_export_upscales`

**Files:**
- New: `api/database/migrations/2026_05_12_120000_create_kv_resize_export_upscales_table.php`

- [ ] **Step 1: Confirm reference schema**

Run: `cat api/database/migrations/2026_05_06_120000_create_kv_generation_upscales_table.php`
Expected: the schema documented in this plan's Design notes.

- [ ] **Step 2: Create the migration**

```php
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('kv_resize_export_upscales', function (Blueprint $t) {
            $t->ulid('id')->primary();
            $t->foreignUlid('kv_resize_export_id')
                ->constrained('kv_resize_exports')
                ->cascadeOnDelete();
            $t->foreignUlid('studio_file_id')->constrained('studio_files')->cascadeOnDelete();
            $t->foreignUlid('created_by')->constrained('users')->cascadeOnDelete();

            $t->decimal('factor', 3, 1);
            $t->unsignedInteger('width')->nullable();
            $t->unsignedInteger('height')->nullable();
            $t->string('image_url')->nullable();
            $t->string('model_version', 64)->nullable();

            $t->string('status', 16)->default('pending');
            $t->text('error_message')->nullable();

            $t->timestamps();
            $t->softDeletes();

            $t->unique(
                ['kv_resize_export_id', 'factor'],
                'kv_resize_export_upscales_export_factor_unique'
            );
            $t->index(
                ['studio_file_id', 'kv_resize_export_id', 'status'],
                'kv_resize_export_upscales_file_export_status_idx'
            );
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('kv_resize_export_upscales');
    }
};
```

- [ ] **Step 3: Run migration locally (gated — user permission)**

```bash
cd api && php artisan migrate
```

- [ ] **Step 4: Commit**

```bash
cd api
git add database/migrations/2026_05_12_120000_create_kv_resize_export_upscales_table.php
git commit -m "feat(api): add kv_resize_export_upscales table"
```

---

## Task 2 (api): Enum + Model + Resource

**Files:**
- New: `api/app/Enums/KvResizeExportUpscaleStatus.php`
- New: `api/app/Models/KvResizeExportUpscale.php`
- New: `api/app/Http/Resources/Studio/KvResizeExportUpscaleResource.php`
- Modify: `api/app/Models/KvResizeExport.php`

- [ ] **Step 1: Enum**

Copy `KvGenerationUpscaleStatus` verbatim into a new file under the new namespace name. Same cases: `Pending, Generating, Done, Failed` with string values `pending, generating, done, failed`.

- [ ] **Step 2: Model**

Mirror `app/Models/KvGenerationUpscale.php`. Replace `kv_generation_id` with `kv_resize_export_id`, change the `parentGeneration()` relation to `tile(): BelongsTo` against `KvResizeExport`. Same `$fillable`, `$casts`, and `HasUlids + SoftDeletes`.

- [ ] **Step 3: Add `upscales()` relation on the tile**

Edit `app/Models/KvResizeExport.php` (already exists, see [KvResizeExport.php](api/app/Models/KvResizeExport.php)):

```php
public function upscales(): \Illuminate\Database\Eloquent\Relations\HasMany
{
    return $this->hasMany(KvResizeExportUpscale::class);
}
```

- [ ] **Step 4: Resource**

Mirror `KvGenerationUpscaleResource`. Rename the field `kvGenerationId` → `kvResizeExportId`. Keep all other fields and camelCase.

- [ ] **Step 5: Commit**

```bash
cd api
git add app/Enums/KvResizeExportUpscaleStatus.php \
        app/Models/KvResizeExportUpscale.php \
        app/Models/KvResizeExport.php \
        app/Http/Resources/Studio/KvResizeExportUpscaleResource.php
git commit -m "feat(api): KvResizeExportUpscale enum, model, resource"
```

---

## Task 3 (api): Service + Job

**Files:**
- New: `api/app/Services/Studio/KvResizeExportUpscaleService.php`
- New: `api/app/Jobs/Studio/ProcessKvResizeExportUpscaleJob.php`

- [ ] **Step 1: Read reference service**

```bash
cat api/app/Services/Studio/KvGenerationUpscaleService.php
```

Confirm: `getOrCreate(file, generation, factor, userId)`, `retry(row)`, `markCompleted(row, …)`.

- [ ] **Step 2: Service**

Copy the reference. Replace constructor / parameters / FK column with the tile equivalents. `getOrCreate` becomes `getOrCreate(StudioFile $file, KvResizeExport $tile, float $factor, string $userId): array` and constructs the row with `kv_resize_export_id => $tile->id`. Same status-code semantics as the reference: cached `done` → `200 OK`, in-flight `pending`/`generating` → `202 Accepted`, terminal `failed` → `409 Conflict` (caller must call retry), newly-created → `202 Accepted` (job dispatched).

- [ ] **Step 3: Job**

Mirror `ProcessKvGenerationUpscaleJob`. POST body to ai-service:

```php
[
    'upscale_id' => $this->upscale->id,
    'source_image_url' => $this->upscale->tile->image_url,
    'factor' => (float) $this->upscale->factor,
]
```

Endpoint: `POST {AI_SERVICE_BASE_URL}/ai/kv-resize-tile-upscale/run`. (Matches the `/ai/kv-upscale/run` convention used by the source-generation upscale flow today; the originally-planned `/v1/...` path would not match the rest of ai-service.)

- [ ] **Step 4: Commit**

```bash
cd api
git add app/Services/Studio/KvResizeExportUpscaleService.php \
        app/Jobs/Studio/ProcessKvResizeExportUpscaleJob.php
git commit -m "feat(api): KvResizeExportUpscale service and dispatch job"
```

---

## Task 4 (api): Controllers + Internal complete + Routes

**Files:**
- New: `api/app/Http/Controllers/Api/Studio/KvResizeExportUpscaleController.php`
- New: `api/app/Http/Controllers/Api/Internal/KvResizeExportUpscaleInternalController.php`
- New: `api/app/Http/Requests/Internal/KvResizeExportUpscaleCompleteRequest.php`
- Modify: `api/routes/api.php`

- [ ] **Step 1: Public controller**

Mirror `KvGenerationUpscaleController` (see [KvGenerationUpscaleController.php](api/app/Http/Controllers/Api/Studio/KvGenerationUpscaleController.php)). Replace `resolveFileAndGeneration` with `resolveFileAndTile`. Reuse the same RateLimiter key `upscale-start:{userId}` — tiles share quota with source upscales by design.

`stream()` uses the same 750 ms tick / `event: upscale.updated` shape, querying `KvResizeExportUpscale::where('kv_resize_export_id', $tile->id)`.

- [ ] **Step 2: Internal complete request**

Mirror `KvGenerationUpscaleCompleteRequest`. Validates `image_url, width, height, model_version, status (done|failed), error_message`.

- [ ] **Step 3: Internal controller**

Mirror `KvGenerationUpscaleInternalController`. Look up the row by id (no FK chain dance — id is enough since ai-service echoes it back).

- [ ] **Step 4: Routes**

In `routes/api.php`, find the existing `kv-generator` route group and add:

```php
Route::prefix('files/{fileId}/resize-exports/{exportId}/upscales')->group(function () {
    Route::get('/', [KvResizeExportUpscaleController::class, 'index']);
    Route::post('/', [KvResizeExportUpscaleController::class, 'store']);
    Route::get('/stream', [KvResizeExportUpscaleController::class, 'stream']);
    Route::post('/{upscaleId}/retry', [KvResizeExportUpscaleController::class, 'retry']);
});
```

And in the internal section:

```php
Route::post(
    'kv-resize-export-upscales/{upscaleId}/complete',
    [KvResizeExportUpscaleInternalController::class, 'complete']
);
```

- [ ] **Step 5: Commit**

```bash
cd api
git add app/Http/Controllers/Api/Studio/KvResizeExportUpscaleController.php \
        app/Http/Controllers/Api/Internal/KvResizeExportUpscaleInternalController.php \
        app/Http/Requests/Internal/KvResizeExportUpscaleCompleteRequest.php \
        routes/api.php
git commit -m "feat(api): KvResizeExportUpscale controllers and routes"
```

---

## Task 5 (api): Tests (gated)

**Files:**
- New: `api/tests/Feature/Studio/KvResizeExportUpscaleControllerTest.php`
- New: `api/tests/Feature/Internal/KvResizeExportUpscaleInternalControllerTest.php`

- [ ] **Step 1: Stop and confirm with user**

`api/AGENTS.md` requires explicit permission before adding tests. Ask: "Add Feature tests for the new endpoints?" — proceed only on yes.

- [ ] **Step 2: Add tests**

Mirror the structure of `tests/Feature/Studio/KvGenerationUpscaleControllerTest.php` if it exists, or follow the standard Pest 4 fixture pattern (factory → act → assert) for: index, store (cache hit + fresh start), retry (only-failed guard), stream (one tick produces an `upscale.updated` line), quota exhaustion → 429, cross-workspace 403, unknown tile 404, complete callback flips status.

- [ ] **Step 3: Run tests (gated)**

```bash
cd api && ./vendor/bin/pest tests/Feature/Studio/KvResizeExportUpscaleControllerTest.php \
                            tests/Feature/Internal/KvResizeExportUpscaleInternalControllerTest.php
```

> 🛑 Before running, ALWAYS verify `api/phpunit.xml` and `api/tests/Pest.php` have proper DB isolation. The April 25 incident wiped a dev DB because the SQLite override was commented out. Confirm `DB_CONNECTION=sqlite_testing` is forced before tests fire.

- [ ] **Step 4: Commit**

```bash
cd api
git add tests/Feature/Studio/KvResizeExportUpscaleControllerTest.php \
        tests/Feature/Internal/KvResizeExportUpscaleInternalControllerTest.php
git commit -m "test(api): KvResizeExportUpscale controllers and internal callback"
```

---

## Task 6 (ai-service): Package + request schema

**Files:**
- New: `ai-service/app/agents/kv_resize_tile_upscale/__init__.py`
- New: `ai-service/app/agents/kv_resize_tile_upscale/request_schema.py`

- [ ] **Step 1: Empty package marker**

```bash
mkdir -p ai-service/app/agents/kv_resize_tile_upscale
touch ai-service/app/agents/kv_resize_tile_upscale/__init__.py
```

- [ ] **Step 2: Request schema**

```python
from pydantic import BaseModel


class KvResizeTileUpscaleRequest(BaseModel):
    upscale_id: str
    source_image_url: str
    factor: float
```

- [ ] **Step 3: Commit**

```bash
cd ai-service
git add app/agents/kv_resize_tile_upscale
git commit -m "feat(ai): scaffold kv_resize_tile_upscale agent"
```

---

## Task 7 (ai-service): Service + api_client

**Files:**
- New: `ai-service/app/agents/kv_resize_tile_upscale/api_client.py`
- New: `ai-service/app/agents/kv_resize_tile_upscale/service.py`

- [ ] **Step 1: api_client.py**

```python
import requests
from app.utils.config import settings


def post_completed(
    upscale_id: str,
    status: str,
    image_url: str | None = None,
    width: int | None = None,
    height: int | None = None,
    model_version: str | None = None,
    error_message: str | None = None,
) -> None:
    requests.post(
        f"{settings.API_BASE_URL}/internal/kv-resize-export-upscales/{upscale_id}/complete",
        json={
            "status": status,
            "image_url": image_url,
            "width": width,
            "height": height,
            "model_version": model_version,
            "error_message": error_message,
        },
        timeout=10,
        headers={"X-Internal-Token": settings.INTERNAL_TOKEN},
    )
```

Match whatever auth header the existing `app/agents/kv_resize/api_client.py` uses — copy from there.

- [ ] **Step 2: service.py**

```python
from io import BytesIO
from pathlib import Path
from tempfile import TemporaryDirectory
from uuid import uuid4

import requests
from PIL import Image

from app.agents.kv_resize_tile_upscale.api_client import post_completed
from app.agents.kv_resize_tile_upscale.request_schema import KvResizeTileUpscaleRequest
from app.tools.edit_image import save_bytes_to_file
from app.tools.upscale_image import upscale
from app.utils.config import settings


def process_tile_upscale(req: KvResizeTileUpscaleRequest) -> None:
    try:
        with TemporaryDirectory() as tmp:
            src_path = Path(tmp) / "src.png"
            r = requests.get(req.source_image_url, timeout=30)
            r.raise_for_status()
            src_path.write_bytes(r.content)

            png_bytes, model_version = upscale(str(src_path), req.factor)

            # Probe dimensions cheaply — pillow loads the header only.
            with Image.open(BytesIO(png_bytes)) as im:
                width, height = im.size

            image_url = save_bytes_to_file(
                image_bytes=png_bytes,
                temp_folder_path="./temp",
                destination_path=f"{settings.API_ENV}/kv-resize-tile-upscales/{req.upscale_id}",
                file_name=f"{uuid4()}.png",
            )

        post_completed(
            upscale_id=req.upscale_id,
            status="done",
            image_url=image_url,
            width=width,
            height=height,
            model_version=model_version,
        )
    except Exception as exc:  # noqa: BLE001
        post_completed(
            upscale_id=req.upscale_id,
            status="failed",
            error_message=str(exc)[:500],
        )
```

- [ ] **Step 3: Commit**

```bash
cd ai-service
git add app/agents/kv_resize_tile_upscale/api_client.py \
        app/agents/kv_resize_tile_upscale/service.py
git commit -m "feat(ai): kv_resize_tile_upscale orchestration via upscale()"
```

---

## Task 8 (ai-service): Router + wire it into main.py

**Files:**
- New: `ai-service/app/agents/kv_resize_tile_upscale/router.py`
- Modify: `ai-service/app/main.py`

The api Task 3 job posts to `{aiUrl}/ai/kv-resize-tile-upscale/run`. The path uses the `/ai/<feature>/run` convention established by the existing `kv_upscale` agent — match it.

- [ ] **Step 1: Read the existing parallel for the exact pattern**

```bash
cat ai-service/app/agents/kv_upscale/router.py
```

- [ ] **Step 2: Create the new router**

```python
# ai-service/app/agents/kv_resize_tile_upscale/router.py
from fastapi import APIRouter, BackgroundTasks

from app.agents.kv_resize_tile_upscale.request_schema import KvResizeTileUpscaleRequest
from app.agents.kv_resize_tile_upscale.service import process_tile_upscale


router = APIRouter(prefix="/ai/kv-resize-tile-upscale", tags=["kv-resize-tile-upscale"])


@router.post("/run", status_code=202)
async def run(req: KvResizeTileUpscaleRequest, bg: BackgroundTasks):
    bg.add_task(process_tile_upscale, req)
    return {"accepted": True}
```

If `app/agents/kv_upscale/router.py` follows a slightly different pattern (e.g. different return shape, additional pre-validation), match it instead of this snippet.

- [ ] **Step 3: Include the router in main.py**

Find where `kv_upscale.router` is included in `app/main.py` and add the analogous line for `kv_resize_tile_upscale.router`.

- [ ] **Step 4: Commit**

```bash
cd ai-service
git add app/agents/kv_resize_tile_upscale/router.py app/main.py
git commit -m "feat(ai): expose POST /ai/kv-resize-tile-upscale/run"
```

---

## Task 9 (ai-service): Tests (gated)

**Files:**
- New: `ai-service/tests/agents/kv_resize_tile_upscale/test_service.py`

- [ ] **Step 1: Stop and confirm with user**

`ai-service/AGENTS.md` requires explicit permission. Ask: "Add a pytest for the new agent?" — proceed only on yes.

- [ ] **Step 2: Test happy path + failure path**

Mock `requests.get` (source download), `replicate_client.run_with_retry` (Replicate output), and `requests.post` (api callback). Assert callback fired with `status=done`, the expected `image_url`, dimensions, and `model_version`. Add a parallel test that raises from `upscale()` and asserts `status=failed` + `error_message`.

- [ ] **Step 3: Run tests (gated)**

```bash
cd ai-service && pytest tests/agents/kv_resize_tile_upscale -v
```

- [ ] **Step 4: Commit**

```bash
cd ai-service
git add tests/agents/kv_resize_tile_upscale
git commit -m "test(ai): kv_resize_tile_upscale happy + failure paths"
```

---

## Task 10 (web): Types and API client

**Files:**
- New: `web/src/types/kv/resize-tile-upscale.ts`
- Modify: `web/src/services/kv/api.ts`

- [ ] **Step 1: Types**

```ts
import type { KvGenerationUpscale } from "@/types/kv/upscale";

export type KvResizeTileUpscale = Omit<KvGenerationUpscale, "kvGenerationId"> & {
  kvResizeExportId: string;
};
```

`UPSCALE_FACTORS` and `deriveRowState` from `@/types/kv/upscale` are reused as-is — no duplication.

- [ ] **Step 2: API client**

In `web/src/services/kv/api.ts`, after the existing upscale block (search for `UPSCALES_BASE`):

```ts
const TILE_UPSCALES_BASE = (fileId: string, exportId: string) =>
  `v1/studio/kv-generator/files/${fileId}/resize-exports/${exportId}/upscales`;

export async function listTileUpscales(
  fileId: string,
  exportId: string,
): Promise<KvResizeTileUpscale[]> {
  const { data } = await axiosInstance.get(TILE_UPSCALES_BASE(fileId, exportId));
  const rows: WireTileUpscale[] = unwrap(data);
  return rows.map(toTileUpscale);
}

export async function createTileUpscale(
  fileId: string,
  exportId: string,
  factor: UpscaleFactor,
): Promise<KvResizeTileUpscale> {
  const { data } = await axiosInstance.post(
    TILE_UPSCALES_BASE(fileId, exportId),
    { factor },
  );
  return toTileUpscale(unwrap<WireTileUpscale>(data));
}

export async function retryTileUpscale(
  fileId: string,
  exportId: string,
  upscaleId: string,
): Promise<KvResizeTileUpscale> {
  const { data } = await axiosInstance.post(
    `${TILE_UPSCALES_BASE(fileId, exportId)}/${upscaleId}/retry`,
  );
  return toTileUpscale(unwrap<WireTileUpscale>(data));
}
```

Define `WireTileUpscale` and `toTileUpscale` analogously to the generation upscale ones already in this file.

- [ ] **Step 3: Commit**

```bash
cd web
git add src/types/kv/resize-tile-upscale.ts src/services/kv/api.ts
git commit -m "feat(web): KvResizeTileUpscale types and API client"
```

---

## Task 11 (web): SSE client + store + hook

**Files:**
- New: `web/src/services/kv/resize-tile-upscale-stream.ts`
- New: `web/src/store/kv/useKvResizeTileUpscaleStore.ts`
- New: `web/src/lib/studio/kv/useResizeTileUpscales.ts`

- [ ] **Step 1: SSE client**

Copy `web/src/services/kv/upscale-stream.ts` and rename:
- `connectUpscaleStream(fileId, generationId, onRow)` → `connectTileUpscaleStream(fileId, exportId, onRow)`
- URL: `…/files/${fileId}/resize-exports/${exportId}/upscales/stream`

- [ ] **Step 2: Zustand store**

Mirror `useKvUpscaleStore`. Store shape:

```ts
type State = {
  upscalesByExportId: Map<string, Map<UpscaleFactor, KvResizeTileUpscale>>;
  pendingDownloadIds: Set<string>;
  downloadHandler: ((row: KvResizeTileUpscale) => void) | null;
  // …same actions: setUpscalesForExport, applyServerEvent, markPendingDownload, setDownloadHandler
};
```

Same React-19-safe pattern: avoid returning new `Map()` from selectors — derive in `useMemo` in the hook.

- [ ] **Step 3: Hook**

Mirror `useUpscales`. Signature:

```ts
export function useResizeTileUpscales(
  fileId: string,
  exportId: string | null,
  fileName: string = "kv",
  platformId: string = "tile",
)
```

Filename builder uses `platformId` as the segment (`<file>__<platform>__1.5x.png` — adjust `buildDownloadFilename` if needed, or build a tile-specific one alongside it).

- [ ] **Step 4: Commit**

```bash
cd web
git add src/services/kv/resize-tile-upscale-stream.ts \
        src/store/kv/useKvResizeTileUpscaleStore.ts \
        src/lib/studio/kv/useResizeTileUpscales.ts
git commit -m "feat(web): KvResizeTileUpscale store, SSE, and hook"
```

---

## Task 12 (web): KvTileDownloadDropdown component

**Files:**
- New: `web/src/components/studio/kv-generator/KvTileDownloadDropdown.tsx`

- [ ] **Step 1: Component**

Near-clone of [KvDownloadDropdown.tsx](web/src/components/studio/kv-generator/KvDownloadDropdown.tsx) — including the **Radix `DropdownMenu`** wrapper (not frndos `Dropdown`; see the 2026-05-12 crash fix). Differences from the source-generation version:

- Props: `{ fileId: string; fileName: string; export: KvResizeExport }` (only one of `export.imageUrl` is needed to enable the trigger; disable when `export.status !== "done"`).
- Hook: `useResizeTileUpscales(fileId, export.id, fileName, export.platformId)` instead of `useUpscales`.
- "Original size" row label becomes "Tile size" and the immediate download uses `export.imageUrl`.
- Trigger styling: this lives inside a tile row's action group, so it should look like a 24×24 icon button, not the 40px pill. Use the same `<DownloadSimple size={16}>` shape the bare button uses today; the dropdown content is the full menu.

- [ ] **Step 2: Commit**

```bash
cd web
git add src/components/studio/kv-generator/KvTileDownloadDropdown.tsx
git commit -m "feat(web): KvTileDownloadDropdown — per-tile Original/1.5×/2× menu"
```

---

## Task 13 (web): Swap into KvResizeResultRow + KvResizeOriginalRow

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvResizeResultRow.tsx`
- Modify: `web/src/components/studio/kv-generator/KvResizeOriginalRow.tsx`

- [ ] **Step 1: KvResizeResultRow**

Replace the existing `<button aria-label="Download">` block in [KvResizeResultRow.tsx](web/src/components/studio/kv-generator/KvResizeResultRow.tsx) with:

```tsx
<KvTileDownloadDropdown
  fileId={fileId}
  fileName={fileName}
  export={row}
/>
```

Threading `fileId` and `fileName` through the row's props (they aren't there today). Update the call site in [KvResizeCanvas.tsx](web/src/components/studio/kv-generator/KvResizeCanvas.tsx) accordingly — it already has both in scope.

Keep `onDownload`/`downloadOne` as a fallback when `export.status === "done"` and the user clicks the "Tile size" row — the dropdown's `handleOriginalDownload` should call the prop, not re-fetch the URL itself. That preserves the existing **flatten-with-overlays** behavior the resize canvas does.

- [ ] **Step 2: KvResizeOriginalRow**

Same swap, but the underlying data source is the source generation (use `useUpscales` not `useResizeTileUpscales`). The simplest way is a thin wrapper component `KvOriginalDownloadDropdown` that calls `useUpscales` and renders the same UI — or just keep `KvDownloadDropdown` here but with the icon-button trigger variant.

**Recommendation:** add a `variant: "pill" | "icon"` prop to `KvDownloadDropdown` and reuse it; don't fork it.

- [ ] **Step 3: Sanity check the dev server**

`yarn dev` and confirm:
- Resize tab: each tile's right-side icon group now has a dropdown trigger where the bare download icon used to be
- Clicking opens 4 rows, "Tile size" downloads immediately, "1.5×" / "2×" start an upscale → ticking timer → auto-download on done
- Top-bar Download stays hidden in Resize (already shipped)
- Sketch / Craft top-bar Download still works (we didn't touch `KvDownloadDropdown` data flow)

- [ ] **Step 4: Commit**

```bash
cd web
git add src/components/studio/kv-generator/KvResizeResultRow.tsx \
        src/components/studio/kv-generator/KvResizeOriginalRow.tsx \
        src/components/studio/kv-generator/KvResizeCanvas.tsx \
        src/components/studio/kv-generator/KvDownloadDropdown.tsx
git commit -m "feat(web): per-tile download dropdown on resize rows"
```

---

## Task 14 (web): Tests (gated)

**Files:**
- New: `web/src/components/studio/kv-generator/KvTileDownloadDropdown.test.tsx`

- [ ] **Step 1: Stop and confirm with user**

Ask: "Add vitest coverage for KvTileDownloadDropdown?" — proceed only on yes.

- [ ] **Step 2: Tests**

Mirror `KvDownloadDropdownRow.test.tsx` but at the parent-dropdown level. With MSW (or a mock for `createTileUpscale` / `listTileUpscales`), assert:

- Clicking "Tile size" calls `onDownload` with the tile URL
- Clicking "1.5× size" issues a POST and the row enters the running state
- Hot-receive a `done` event → auto-download fired (mock `downloadImageUrl`)
- Failed row → click triggers retry

- [ ] **Step 3: Run tests (gated)**

```bash
cd web && yarn test KvTileDownloadDropdown
```

- [ ] **Step 4: Commit**

```bash
cd web
git add src/components/studio/kv-generator/KvTileDownloadDropdown.test.tsx
git commit -m "test(web): KvTileDownloadDropdown happy + failure paths"
```

---

## Verification checklist (end-to-end)

After all 14 tasks land, run the following manually in the browser:

- [ ] Generate a fresh KV. Switch to Resize. Pick Instagram Post + Instagram Landscape + Facebook Cover. Run resize.
- [ ] On the Instagram Post tile, click the download icon → menu shows `Tile size / 1.5× size / 2× size`.
- [ ] Click "1.5× size" — row shows `Upscaling… Ns` with a live timer. When done, browser auto-downloads `<file>__instagram-post__1.5x.png`. Network tab: one `POST …upscales`, one SSE connection, no polling traffic once `done` lands.
- [ ] Click "2× size" on the same tile — same flow, separate file.
- [ ] Refresh the page. Open the same tile's dropdown. `1.5×` and `2×` rows show as Ready (cached); clicking either re-downloads without re-running the AI job.
- [ ] Trigger a quota-exhaustion path (e.g. seed 30 upscales for this user via tinker). Next click → toast / 429 surface (matches source-side handling).
- [ ] Delete the tile (X button on the platform panel). DB: corresponding `kv_resize_export_upscales` rows are gone (cascade).
- [ ] Sketch and Craft tabs: top-bar Download still shows the source-generation upscales menu. No regressions.

---

## Out of scope (explicit non-goals)

- Bulk upscale of all tiles in one click — adds a multiplexed quota question we don't want to answer in v1.
- A new mega-menu in the top-bar that combines source + tile upscales for Resize mode.
- Re-introducing the LANCZOS fast-path. Per-tile upscale always goes through `upscale()` (clarity → ESRGAN fallback) for v1.
- Storing the upscale-of-a-tile back as a new resize export. Upscales are download-only artifacts; they never replace the tile shown in the canvas.

---

## Risk log

| Risk | Mitigation |
|------|------------|
| Quota multiplexing — a user could now consume 5× the source quota by spawning 5 tiles. | Shared RateLimiter bucket `upscale-start:{userId}`. Already covered in Task 4. |
| `clarity-upscaler` doesn't behave well on extreme aspect ratios (e.g. 820×360 Facebook Cover). | Pre-validate dimensions in the agent; fall back to `real-esrgan` for tiles where the shorter side < 256. Add to Task 7 service body if observed during dev. |
| SSE connection cap — every open tile dropdown opens a stream. A user opening 10 tile menus = 10 SSE connections. | Hook closes the stream when nothing is in-flight (`useUpscales.ts:91`). Same behaviour, no additional pressure. |
| Cache invalidation after the source generation regenerates — should a tile upscale be invalidated? | No. The upscale is keyed off the tile, and tile regeneration produces a **new** tile row with a new id. Old upscales remain associated with the old tile id (now deleted on regenerate). Confirm regenerate cascades.
