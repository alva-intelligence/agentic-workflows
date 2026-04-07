# KV Generator — AI-Powered Image Resize

## Summary

Replace the current crop-based image resizer in the KV Generator workflow with AI-powered resizing using Google Gemini. When a user selects platform sizes (e.g., Meta Square, IG Stories, TikTok Vertical), the system uses Gemini's image editing API to intelligently extend the canvas (outpainting) and recompose the image for each target aspect ratio — preserving all original objects in their relative positions and proportions.

## Problem

The current resizer uses deterministic crop/scale via `POST v1/kv/projects/{id}/resize`. When the aspect ratio changes significantly (e.g., 1:1 → 9:16), the backend simply crops the image, cutting off content. Users lose important visual elements, especially products and branding.

## Solution

AI-powered resize using Gemini's image editing capabilities:
- **Outpainting** — extend the background/canvas naturally to fill new dimensions
- **Recomposition** — intelligently fit content into the new aspect ratio while preserving the original spatial relationships between objects (no rearranging)

## Decisions Made

| Decision | Choice | Rationale |
|----------|--------|-----------|
| AI Provider | Google Gemini (gemini-3.1-flash-image-preview) | Native aspect ratio support (14 ratios), simple API (image + prompt, no masks), team already uses Google APIs |
| Trigger | Automatic for all dimensions | No manual toggle — AI resize replaces crop-based resize as the default |
| Processing | Redis queue with parallel workers | AI service already uses this pattern; handles 10-20+ dimensions efficiently |
| Per-tile editing | Full Konva editor | Reuses existing ImageEditorCanvas component; full editing power (mask, lasso, text, erase, overlay) |
| Frontend → Backend | Through PHP API | Keeps auth centralized, consistent with existing KV endpoints, PHP stores results in DB |

---

## Architecture

```
Frontend (Next.js)
    → PHP API (Laravel) — auth, validation, DB storage, proxy
        → AI Service (FastAPI) — job orchestration, prompt engineering
            → Redis — job queue, parallel workers, progress tracking
                → Gemini API — image editing with target aspect ratio
```

### Service Responsibilities

**Frontend (Next.js):**
- Trigger AI resize after platform size selection
- Poll for job progress, render tiles progressively
- Review grid with clickable tiles
- Per-tile Konva editor (reuse existing component)
- Export ZIP with final tile images

**PHP API (Laravel):**
- Auth and project validation
- 3 new proxy endpoints (see API Contract)
- Store job metadata and tile results in database
- Existing ZIP export unchanged — uses AI-resized tile URLs instead of crop URLs

**AI Service (FastAPI):**
- 3 new endpoints (see API Contract)
- Job creation and Redis task enqueueing
- Prompt engineering for Gemini
- Gemini API integration
- Upload results to cloud storage (S3/GCS)

**Redis:**
- Job queue for per-tile resize tasks
- Parallel worker processing
- Progress state per job (completed/total count, per-tile status)

---

## API Contract

### PHP API Endpoints (proxy + storage)

#### POST /api/v1/kv/projects/{id}/ai-resize

Create an AI resize job for a project.

**Request:**
```json
{
  "source_image_url": "https://storage.example.com/kv/original.png",
  "dimensions": [
    { "width": 1080, "height": 1080, "label": "Meta Square" },
    { "width": 1080, "height": 1920, "label": "IG Stories" },
    { "width": 1200, "height": 628, "label": "Meta Horizontal" }
  ]
}
```

**Response:**
```json
{
  "job_id": "air_abc123",
  "status": "queued",
  "total_tiles": 12
}
```

**Behavior:** Validate project ownership → forward to AI Service → store job_id in DB → return to frontend.

#### GET /api/v1/kv/projects/{id}/ai-resize/{job_id}

Poll job progress.

**Response:**
```json
{
  "job_id": "air_abc123",
  "status": "processing",
  "progress": { "completed": 5, "total": 12 },
  "tiles": [
    {
      "id": "tile_001",
      "dimension_label": "Meta Square",
      "width": 1080,
      "height": 1080,
      "gemini_aspect_ratio": "1:1",
      "image_url": "https://storage.example.com/kv/resized/tile_001.png",
      "status": "completed"
    },
    {
      "id": "tile_002",
      "dimension_label": "IG Stories",
      "width": 1080,
      "height": 1920,
      "gemini_aspect_ratio": "9:16",
      "image_url": null,
      "status": "processing"
    }
  ]
}
```

**Behavior:** Proxy poll to AI Service → cache completed tile URLs in DB → return to frontend.

#### POST /api/v1/kv/projects/{id}/ai-resize/single

Re-generate a single tile (from review grid).

**Request:**
```json
{
  "source_image_url": "https://storage.example.com/kv/original.png",
  "width": 1080,
  "height": 1920,
  "label": "IG Stories",
  "prompt_override": "Extend more sky on the top"
}
```

**Response:**
```json
{
  "tile_id": "tile_002_v2",
  "image_url": "https://storage.example.com/kv/resized/tile_002_v2.png",
  "status": "completed"
}
```

**Behavior:** Forward to AI Service (immediate, no queue) → update DB → return to frontend.

### AI Service Endpoints (job orchestration)

The AI Service exposes matching endpoints without the `/api` prefix and without project-scoped paths (PHP handles project context):

- `POST /v1/kv/ai-resize` — create job, enqueue per-tile tasks in Redis, return job_id
- `GET /v1/kv/ai-resize/{job_id}` — read Redis progress, return tiles with status + image URLs
- `POST /v1/kv/ai-resize/single` — immediate Gemini call (no queue), return resized image URL

---

## Gemini Integration

### Model & Config

- **Model:** `gemini-3.1-flash-image-preview`
- **Resolution:** 2K default, 4K for dimensions where both width and height exceed 2000px
- **Supported aspect ratios:** 1:1, 1:4, 1:8, 2:3, 3:2, 3:4, 4:1, 4:3, 4:5, 5:4, 8:1, 9:16, 16:9, 21:9

### Base Prompt

```
Resize this image to {aspect_ratio} aspect ratio. Extend the background and canvas
naturally to fill the new dimensions. Keep ALL objects, products, text, and visual
elements in their original relative positions and proportions. Do not crop, remove,
or rearrange any existing content. The extended areas should seamlessly match the
existing style, lighting, and color palette.
```

### Aspect Ratio Mapping

Each platform dimension maps to the nearest Gemini-supported ratio:

| Platform Dimension | Gemini Ratio |
|-------------------|-------------|
| 1080x1080 (Meta Square) | 1:1 |
| 640x640 (TikTok Square) | 1:1 |
| 1080x1920 (IG Stories/Reels) | 9:16 |
| 720x1280 (TikTok Vertical) | 9:16 |
| 500x888 (Meta Vertical) | 9:16 |
| 1200x628 (Meta Horizontal) | 16:9 |
| 500x262 (Meta Horizontal) | 16:9 |
| 750x421 (TikTok Horizontal) | 16:9 |
| 1080x1350 (Feed Portrait) | 4:5 |
| 328x141 | 21:9 |

### Deduplication Optimization

Dimensions sharing the same Gemini aspect ratio get ONE Gemini call, then the result is downscaled to each exact pixel size. Example: 1080x1080 and 640x640 both map to 1:1 — one Gemini call, two output files (downscaled). This reduces API calls and cost significantly (12 dimensions might only need 6 unique Gemini calls).

### Downscale After Gemini

After Gemini returns the AI-resized image at a given ratio:
1. Gemini outputs at 2K (or 4K) resolution for that ratio
2. Server downscales to each exact pixel dimension that maps to that ratio
3. Store each downscaled version as a separate tile

---

## User Flow

### Happy Path

1. User finishes editing in Konva editor, proceeds to Platform Size Selection
2. User selects platform sizes (e.g., 12 dimensions across Meta, TikTok, Google)
3. User clicks "Resize with AI" (replaces old "Export" button)
4. Frontend calls `POST /api/v1/kv/projects/{id}/ai-resize`
5. Progress screen appears — progress bar + tiles appearing progressively as they complete
6. All tiles complete → Review Grid shows all AI-resized tiles
7. User reviews tiles:
   - Tiles that look good → no action needed
   - Tile that looks off → click to open Konva editor with that resized image
   - In Konva editor: use mask/lasso/text/erase/overlay tools to fix, then save
   - Or: click "Regenerate" to re-run AI for that specific tile (`POST /ai-resize/single`)
8. User satisfied → clicks Export → existing ZIP export flow with final tile image URLs

### Error Handling

- **Individual tile failure:** Mark tile as "failed" in grid, show retry button. Other tiles continue.
- **Full job failure:** Show error state with "Retry All" button.
- **Gemini rate limit:** AI service implements exponential backoff per worker.
- **Timeout:** Per-tile timeout of 60s. If exceeded, mark as failed, allow retry.

---

## Frontend Changes

### New Components

| Component | Location | Purpose |
|-----------|----------|---------|
| AiResizeProgress | `kv-generator/ai-resize-progress/` | Progress bar + progressive tile grid during processing |
| AiResizeReviewGrid | `kv-generator/ai-resize-review/` | Clickable tile grid with status badges (AI / Outpainted / Recomposed) |
| TileEditorModal | `kv-generator/ai-resize-review/components/` | Modal wrapping existing Konva ImageEditorCanvas for single-tile editing |

### Modified Files

| File | Change |
|------|--------|
| `store/kv/useKvResizerStore.ts` | Add `aiResizeJobId`, `aiResizeTiles`, `aiResizeStatus` state |
| `services/kv/api.ts` | Add `createAiResize()`, `pollAiResize()`, `regenerateSingleTile()` functions |
| `hooks/kv/` | Add `useAiResize`, `useAiResizePoll`, `useRegenerateTile` hooks |
| `types/kv/index.ts` | Add `AiResizeJob`, `AiResizeTile` types |
| `PlatformSizeSelection` | Change confirm action to trigger AI resize instead of building static tiles |
| `ExportPreview` | Use AI-resized tile URLs from store instead of crop-based URLs |

### New Pages

The AI resize flow adds two new pages to the KV Generator stepper:

| Page | Route | Purpose |
|------|-------|---------|
| AI Resize Progress | `projects/[id]/ai-resize` | Progress bar while Redis workers process tiles |
| AI Resize Review | `projects/[id]/ai-resize-review` | Review grid with per-tile actions |

### Updated Stepper

```
Context Setup → Generate → Edit → Select Sizes → AI Resize → Review → Export
```

---

## Scope Boundaries

**In scope:**
- AI resize via Gemini for all selected platform dimensions
- Progress UI with progressive tile rendering
- Review grid with per-tile Konva editing
- Single-tile regeneration
- Aspect ratio deduplication optimization
- Redis queue parallel processing

**Out of scope:**
- Provider switching UI (Gemini is hardcoded as default, provider-agnostic architecture in AI service for future)
- Batch prompt customization (all tiles use the same base prompt)
- A/B comparison between crop-based and AI resize
- Cost tracking / usage limits (add later based on usage patterns)
- Fallback to crop-based resize if Gemini is down (can add later)
