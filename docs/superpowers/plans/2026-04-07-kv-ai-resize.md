# KV AI Resize Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the crop-based image resizer with AI-powered resizing using Google Gemini, including Redis queue-based parallel processing, review grid UI, and per-tile Konva editing.

**Architecture:** Frontend → PHP API (3 new proxy endpoints) → AI Service (3 new endpoints + Redis job queue + Gemini integration). Frontend gets new pages for progress tracking and review grid with per-tile Konva editor.

**Tech Stack:** Next.js 16, React 19, TypeScript, Zustand, TanStack Query v5, Laravel 13, FastAPI, Redis, Google GenAI (Gemini), Pillow, boto3

**Spec:** `docs/superpowers/specs/2026-04-07-kv-ai-resize-design.md`

---

## File Structure

### AI Service (new files)

| File | Responsibility |
|------|---------------|
| `ai-service/app/services/kv/ai_resize_service.py` | Gemini API calls, aspect ratio mapping, image download/upload, prompt building |
| `ai-service/app/services/kv/ai_resize_schemas.py` | Pydantic request/response models for AI resize endpoints |
| `ai-service/app/routes/kv_resize.py` | FastAPI router with 3 endpoints (create job, poll, single re-gen) |

### PHP API (new files)

| File | Responsibility |
|------|---------------|
| `api/app/Http/Controllers/Api/Kv/KvAiResizeController.php` | 3 proxy endpoints — auth, validate, forward to AI service, store in DB |
| `api/app/Models/KvAiResizeJob.php` | Eloquent model for AI resize jobs |
| `api/database/migrations/xxxx_create_kv_ai_resize_jobs_table.php` | Migration for tracking jobs and tile results |

### Frontend (new files)

| File | Responsibility |
|------|---------------|
| `web/src/services/kv/ai-resize.ts` | API functions: createAiResize, pollAiResize, regenerateSingleTile |
| `web/src/hooks/kv/useAiResize.ts` | TanStack Query hooks for AI resize operations |
| `web/src/types/kv/ai-resize.ts` | TypeScript types for AI resize job, tiles, progress |
| `web/src/app/(dashboard)/workflows/kv-generator/projects/[id]/ai-resize/page.tsx` | Progress page during AI resize processing |
| `web/src/app/(dashboard)/workflows/kv-generator/projects/[id]/ai-resize/components/AiResizeProgress.tsx` | Progress bar + progressive tile grid component |
| `web/src/app/(dashboard)/workflows/kv-generator/projects/[id]/ai-resize-review/page.tsx` | Review grid page |
| `web/src/app/(dashboard)/workflows/kv-generator/projects/[id]/ai-resize-review/components/AiResizeReviewGrid.tsx` | Clickable tile grid with actions |
| `web/src/app/(dashboard)/workflows/kv-generator/projects/[id]/ai-resize-review/components/TileEditorModal.tsx` | Modal wrapping Konva ImageEditorCanvas for single-tile editing |

### Frontend (modified files)

| File | Change |
|------|--------|
| `web/src/store/kv/useKvResizerStore.ts` | Add AI resize state: jobId, aiTiles, aiResizeStatus |
| `web/src/app/(dashboard)/workflows/kv-generator/platform-size-selection/components/PlatformSizeSelection.tsx` | Change confirm to navigate to AI resize page instead of export preview |

---

## Task 1: AI Service — Schemas & Aspect Ratio Mapping

**Files:**
- Create: `ai-service/app/services/kv/ai_resize_schemas.py`

- [ ] **Step 1: Create the schemas file with request/response models and aspect ratio mapping**

```python
"""
Pydantic models and utilities for KV AI Resize feature.
"""

from enum import Enum
from typing import Any, Dict, List, Optional
from pydantic import BaseModel, Field


class AiResizeTileStatus(str, Enum):
    QUEUED = "queued"
    PROCESSING = "processing"
    COMPLETED = "completed"
    FAILED = "failed"


class AiResizeJobStatus(str, Enum):
    QUEUED = "queued"
    PROCESSING = "processing"
    COMPLETED = "completed"
    FAILED = "failed"


# ─── Request Models ──────────────────────────────────────────────────────────


class DimensionInput(BaseModel):
    width: int = Field(..., gt=0)
    height: int = Field(..., gt=0)
    label: Optional[str] = None


class AiResizeRequest(BaseModel):
    source_image_url: str
    dimensions: List[DimensionInput] = Field(..., min_length=1)
    project_id: Optional[str] = None


class AiResizeSingleRequest(BaseModel):
    source_image_url: str
    width: int = Field(..., gt=0)
    height: int = Field(..., gt=0)
    label: Optional[str] = None
    prompt_override: Optional[str] = None


# ─── Response Models ─────────────────────────────────────────────────────────


class AiResizeTileResult(BaseModel):
    id: str
    dimension_label: Optional[str]
    width: int
    height: int
    gemini_aspect_ratio: str
    image_url: Optional[str] = None
    status: AiResizeTileStatus


class AiResizeJobResponse(BaseModel):
    job_id: str
    status: AiResizeJobStatus
    total_tiles: int


class AiResizePollResponse(BaseModel):
    job_id: str
    status: AiResizeJobStatus
    progress: Dict[str, int]  # {"completed": N, "total": M}
    tiles: List[AiResizeTileResult]


class AiResizeSingleResponse(BaseModel):
    tile_id: str
    image_url: str
    status: str = "completed"


# ─── Aspect Ratio Mapping ───────────────────────────────────────────────────

# Gemini supported aspect ratios
GEMINI_ASPECT_RATIOS = [
    (1, 1), (1, 4), (1, 8), (2, 3), (3, 2), (3, 4),
    (4, 1), (4, 3), (4, 5), (5, 4), (8, 1), (9, 16), (16, 9), (21, 9),
]


def find_nearest_gemini_ratio(width: int, height: int) -> str:
    """
    Map a pixel dimension to the nearest Gemini-supported aspect ratio.
    Returns the ratio as a string like "9:16".
    """
    target = width / height
    best_ratio = None
    best_distance = float("inf")

    for w, h in GEMINI_ASPECT_RATIOS:
        ratio = w / h
        distance = abs(ratio - target)
        if distance < best_distance:
            best_distance = distance
            best_ratio = (w, h)

    return f"{best_ratio[0]}:{best_ratio[1]}"


def group_dimensions_by_ratio(
    dimensions: List[DimensionInput],
) -> Dict[str, List[DimensionInput]]:
    """
    Group dimensions by their nearest Gemini aspect ratio.
    Dimensions sharing a ratio will use one Gemini call, then downscale.
    """
    groups: Dict[str, List[DimensionInput]] = {}
    for dim in dimensions:
        ratio = find_nearest_gemini_ratio(dim.width, dim.height)
        groups.setdefault(ratio, []).append(dim)
    return groups
```

- [ ] **Step 2: Commit**

```bash
git add ai-service/app/services/kv/ai_resize_schemas.py
git commit -m "feat(ai): add AI resize schemas and aspect ratio mapping"
```

---

## Task 2: AI Service — Resize Service (Gemini + S3)

**Files:**
- Create: `ai-service/app/services/kv/ai_resize_service.py`
- Read: `ai-service/app/services/aws.py` (S3 upload pattern)
- Read: `ai-service/app/tools/edit_image.py:139-157` (Gemini client pattern)
- Read: `ai-service/app/services/kv/generation_service.py:560-590` (image upload pattern)

- [ ] **Step 1: Create the AI resize service**

```python
"""
AI Resize Service — handles Gemini API calls for image resizing,
S3 uploads, and the Redis-backed job orchestration.
"""

import asyncio
import base64
import io
import json
import logging
import os
import time
from typing import Any, Dict, List, Optional, cast
from uuid import uuid4

import requests
from google import genai
from google.genai import types as genai_types
from google.genai.errors import ServerError as GeminiServerError
from PIL import Image as PILImage

from app.services.aws import upload_file_to_s3
from app.services.kv.job_queue import KVJobQueue, JOB_TTL_SECONDS
from app.utils.config import settings

from .ai_resize_schemas import (
    AiResizeJobStatus,
    AiResizeRequest,
    AiResizeSingleRequest,
    AiResizeTileResult,
    AiResizeTileStatus,
    DimensionInput,
    find_nearest_gemini_ratio,
    group_dimensions_by_ratio,
)

logger = logging.getLogger(__name__)

TEMP_FOLDER = "./temp/kv-resize"
GEMINI_MODEL = "gemini-3.1-flash-image-preview"
MAX_RETRIES = 3

BASE_PROMPT = (
    "Resize this image to {aspect_ratio} aspect ratio. "
    "Extend the background and canvas naturally to fill the new dimensions. "
    "Keep ALL objects, products, text, and visual elements in their original "
    "relative positions and proportions. Do not crop, remove, or rearrange "
    "any existing content. The extended areas should seamlessly match the "
    "existing style, lighting, and color palette."
)


class KVAiResizeService:
    """Orchestrates AI-powered image resizing via Gemini."""

    def __init__(self, job_queue: KVJobQueue):
        self._job_queue = job_queue
        self._redis = job_queue._redis

    # ─── Job Key Helpers ─────────────────────────────────────────────────

    @staticmethod
    def _resize_job_key(job_id: str) -> str:
        return f"kv:ai-resize:{job_id}"

    @staticmethod
    def _resize_tiles_key(job_id: str) -> str:
        return f"kv:ai-resize:{job_id}:tiles"

    # ─── Create Job ──────────────────────────────────────────────────────

    def create_job(self, request: AiResizeRequest) -> str:
        """
        Create a resize job: store metadata in Redis, enqueue per-tile tasks.
        Returns the job_id.
        """
        job_id = f"air_{uuid4().hex[:12]}"

        # Group dimensions by Gemini aspect ratio for deduplication
        ratio_groups = group_dimensions_by_ratio(request.dimensions)

        # Build tile list
        tiles = []
        for dim in request.dimensions:
            ratio = find_nearest_gemini_ratio(dim.width, dim.height)
            tile_id = f"tile_{uuid4().hex[:8]}"
            tiles.append({
                "id": tile_id,
                "width": dim.width,
                "height": dim.height,
                "label": dim.label or f"{dim.width}x{dim.height}",
                "gemini_aspect_ratio": ratio,
                "image_url": None,
                "status": AiResizeTileStatus.QUEUED.value,
            })

        # Store job metadata
        job_data = {
            "job_id": job_id,
            "status": AiResizeJobStatus.QUEUED.value,
            "source_image_url": request.source_image_url,
            "project_id": request.project_id or "",
            "total_tiles": len(tiles),
            "completed_tiles": 0,
            "failed_tiles": 0,
            "created_at": str(int(time.time())),
        }
        self._redis.hset(self._resize_job_key(job_id), mapping=job_data)
        self._redis.expire(self._resize_job_key(job_id), JOB_TTL_SECONDS)

        # Store tiles as JSON list
        self._redis.set(
            self._resize_tiles_key(job_id),
            json.dumps(tiles),
            ex=JOB_TTL_SECONDS,
        )

        # Enqueue per-ratio tasks (deduped — one task per unique ratio)
        for ratio, dims in ratio_groups.items():
            task = json.dumps({
                "job_id": job_id,
                "source_image_url": request.source_image_url,
                "aspect_ratio": ratio,
                "dimensions": [{"width": d.width, "height": d.height, "label": d.label} for d in dims],
            })
            self._redis.rpush("kv:queue:ai-resize", task)

        return job_id

    # ─── Poll Job ────────────────────────────────────────────────────────

    def get_job_status(self, job_id: str) -> Optional[Dict[str, Any]]:
        """Get the current status of an AI resize job."""
        job_data = self._redis.hgetall(self._resize_job_key(job_id))
        if not job_data:
            return None

        tiles_json = self._redis.get(self._resize_tiles_key(job_id))
        tiles = json.loads(tiles_json) if tiles_json else []

        completed = sum(1 for t in tiles if t["status"] == AiResizeTileStatus.COMPLETED.value)
        failed = sum(1 for t in tiles if t["status"] == AiResizeTileStatus.FAILED.value)
        total = len(tiles)

        # Determine overall status
        if completed + failed >= total:
            status = AiResizeJobStatus.COMPLETED.value if failed == 0 else AiResizeJobStatus.FAILED.value
            self._redis.hset(self._resize_job_key(job_id), "status", status)
        elif completed > 0 or any(t["status"] == AiResizeTileStatus.PROCESSING.value for t in tiles):
            status = AiResizeJobStatus.PROCESSING.value
            self._redis.hset(self._resize_job_key(job_id), "status", status)
        else:
            status = job_data.get("status", AiResizeJobStatus.QUEUED.value)

        return {
            "job_id": job_id,
            "status": status,
            "progress": {"completed": completed, "total": total},
            "tiles": tiles,
        }

    # ─── Process a Single Ratio Group ────────────────────────────────────

    async def process_ratio_task(self, task_data: Dict[str, Any]) -> None:
        """
        Process a single aspect ratio task: call Gemini once, then downscale
        to each target dimension within this ratio group.
        """
        job_id = task_data["job_id"]
        source_url = task_data["source_image_url"]
        aspect_ratio = task_data["aspect_ratio"]
        dimensions = task_data["dimensions"]

        try:
            # Mark tiles as processing
            self._update_tiles_status(
                job_id, aspect_ratio, AiResizeTileStatus.PROCESSING.value
            )

            # Download source image
            source_bytes = self._download_image(source_url)

            # Call Gemini with the aspect ratio
            prompt = BASE_PROMPT.format(aspect_ratio=aspect_ratio)
            gemini_bytes = await self._call_gemini(source_bytes, prompt, aspect_ratio)

            # Downscale to each target dimension and upload
            for dim in dimensions:
                width = dim["width"]
                height = dim["height"]
                label = dim.get("label", f"{width}x{height}")

                resized_bytes = self._downscale_image(gemini_bytes, width, height)
                image_url = self._upload_image(resized_bytes, job_id, label)

                # Update the specific tile in Redis
                self._update_tile_result(
                    job_id, width, height,
                    image_url=image_url,
                    status=AiResizeTileStatus.COMPLETED.value,
                )

        except Exception as e:
            logger.error(f"AI resize failed for job {job_id} ratio {aspect_ratio}: {e}")
            self._update_tiles_status(
                job_id, aspect_ratio, AiResizeTileStatus.FAILED.value
            )

    # ─── Single Tile Regeneration (Immediate) ────────────────────────────

    async def resize_single(self, request: AiResizeSingleRequest) -> Dict[str, str]:
        """
        Resize a single image immediately (no queue). Used for per-tile
        regeneration from the review grid.
        """
        source_bytes = self._download_image(request.source_image_url)
        ratio = find_nearest_gemini_ratio(request.width, request.height)

        prompt = request.prompt_override or BASE_PROMPT.format(aspect_ratio=ratio)
        gemini_bytes = await self._call_gemini(source_bytes, prompt, ratio)

        resized_bytes = self._downscale_image(gemini_bytes, request.width, request.height)
        label = request.label or f"{request.width}x{request.height}"
        tile_id = f"tile_{uuid4().hex[:8]}"
        image_url = self._upload_image(resized_bytes, f"single_{tile_id}", label)

        return {"tile_id": tile_id, "image_url": image_url}

    # ─── Gemini API Call ─────────────────────────────────────────────────

    async def _call_gemini(
        self, source_bytes: bytes, prompt: str, aspect_ratio: str
    ) -> bytes:
        """
        Call Gemini image editing API with the source image and prompt.
        Returns the generated image bytes.
        """

        def _sync_call() -> bytes:
            client = genai.Client(api_key=settings.GEMINI_API_KEY)

            pil_image = PILImage.open(io.BytesIO(source_bytes))

            config = genai_types.GenerateContentConfig(
                response_modalities=["IMAGE", "TEXT"],
            )

            # Gemini supports aspect_ratio in the config for image generation
            # We include it in the prompt as the primary mechanism
            response = client.models.generate_content(
                model=GEMINI_MODEL,
                contents=[prompt, pil_image],
                config=config,
            )

            # Validate response
            if hasattr(response, "prompt_feedback") and response.prompt_feedback:
                raise RuntimeError(f"Gemini prompt blocked: {response.prompt_feedback}")

            if not response.candidates:
                raise RuntimeError("No candidates from Gemini — possible safety block")

            candidate = response.candidates[0]
            if candidate.finish_reason and not candidate.content:
                raise RuntimeError(f"Gemini blocked: finish_reason={candidate.finish_reason}")

            # Extract image bytes from response
            for part in candidate.content.parts:
                if part.inline_data and part.inline_data.mime_type.startswith("image/"):
                    return part.inline_data.data

            raise RuntimeError("No image data in Gemini response")

        return await asyncio.to_thread(_sync_call)

    # ─── Image Helpers ───────────────────────────────────────────────────

    def _download_image(self, url: str) -> bytes:
        """Download an image from URL and return raw bytes."""
        resp = requests.get(url, timeout=60)
        resp.raise_for_status()
        return resp.content

    def _downscale_image(self, image_bytes: bytes, width: int, height: int) -> bytes:
        """Downscale image to exact pixel dimensions using Lanczos resampling."""
        img = PILImage.open(io.BytesIO(image_bytes))
        resized = img.resize((width, height), PILImage.LANCZOS)
        output = io.BytesIO()
        resized.save(output, format="PNG")
        return output.getvalue()

    def _upload_image(self, image_bytes: bytes, job_id: str, label: str) -> str:
        """Upload resized image to S3 and return the public URL."""
        os.makedirs(TEMP_FOLDER, exist_ok=True)

        file_name = f"ai_resize_{label}_{uuid4().hex[:8]}.png"
        file_path = os.path.join(TEMP_FOLDER, file_name)

        with open(file_path, "wb") as f:
            f.write(image_bytes)

        destination = f"{settings.API_ENV}/kv-generator/ai-resize/{job_id}/{file_name}"
        image_url = upload_file_to_s3(
            source_path=file_path,
            destination_path=destination,
            file_permission="public",
        )

        try:
            os.remove(file_path)
        except OSError:
            pass

        return image_url

    # ─── Redis Tile Helpers ──────────────────────────────────────────────

    def _update_tiles_status(
        self, job_id: str, aspect_ratio: str, status: str
    ) -> None:
        """Update all tiles matching a given aspect ratio to a new status."""
        tiles_json = self._redis.get(self._resize_tiles_key(job_id))
        if not tiles_json:
            return
        tiles = json.loads(tiles_json)
        for tile in tiles:
            if tile["gemini_aspect_ratio"] == aspect_ratio:
                tile["status"] = status
        self._redis.set(
            self._resize_tiles_key(job_id),
            json.dumps(tiles),
            ex=JOB_TTL_SECONDS,
        )

    def _update_tile_result(
        self, job_id: str, width: int, height: int,
        image_url: str, status: str,
    ) -> None:
        """Update a specific tile's image_url and status."""
        tiles_json = self._redis.get(self._resize_tiles_key(job_id))
        if not tiles_json:
            return
        tiles = json.loads(tiles_json)
        for tile in tiles:
            if tile["width"] == width and tile["height"] == height:
                tile["image_url"] = image_url
                tile["status"] = status
                break
        self._redis.set(
            self._resize_tiles_key(job_id),
            json.dumps(tiles),
            ex=JOB_TTL_SECONDS,
        )
```

- [ ] **Step 2: Commit**

```bash
git add ai-service/app/services/kv/ai_resize_service.py
git commit -m "feat(ai): add AI resize service with Gemini integration and S3 upload"
```

---

## Task 3: AI Service — Background Worker

**Files:**
- Create: `ai-service/app/services/kv/ai_resize_worker.py`
- Read: `ai-service/app/services/kv/ai_resize_service.py` (the service we just created)

- [ ] **Step 1: Create the background worker that processes the Redis queue**

```python
"""
Background worker that processes AI resize tasks from the Redis queue.
Runs as an asyncio task within the FastAPI lifespan.
"""

import asyncio
import json
import logging

import redis

from app.utils.config import settings
from .ai_resize_service import KVAiResizeService
from .job_queue import KVJobQueue

logger = logging.getLogger(__name__)

QUEUE_KEY = "kv:queue:ai-resize"
POLL_INTERVAL = 1  # seconds between queue checks
MAX_CONCURRENT_TASKS = 4  # parallel Gemini calls


async def run_ai_resize_worker(service: KVAiResizeService) -> None:
    """
    Long-running worker: pops tasks from Redis queue and processes them
    with bounded concurrency.
    """
    redis_client = redis.Redis(
        host=settings.REDIS_HOST,
        port=settings.REDIS_PORT,
        username=settings.REDIS_USERNAME,
        password=settings.REDIS_PASSWORD,
        db=settings.REDIS_DB,
        decode_responses=True,
    )

    semaphore = asyncio.Semaphore(MAX_CONCURRENT_TASKS)
    logger.info(f"AI resize worker started (max_concurrent={MAX_CONCURRENT_TASKS})")

    async def _process_task(task_json: str) -> None:
        async with semaphore:
            try:
                task_data = json.loads(task_json)
                logger.info(
                    f"Processing AI resize: job={task_data['job_id']} "
                    f"ratio={task_data['aspect_ratio']}"
                )
                await service.process_ratio_task(task_data)
            except Exception as e:
                logger.error(f"AI resize task failed: {e}", exc_info=True)

    while True:
        try:
            # BLPOP with 1s timeout to avoid busy-waiting
            result = redis_client.blpop(QUEUE_KEY, timeout=POLL_INTERVAL)
            if result:
                _, task_json = result
                asyncio.create_task(_process_task(task_json))
        except redis.ConnectionError:
            logger.warning("Redis connection lost, retrying in 5s...")
            await asyncio.sleep(5)
        except Exception as e:
            logger.error(f"AI resize worker error: {e}", exc_info=True)
            await asyncio.sleep(POLL_INTERVAL)
```

- [ ] **Step 2: Commit**

```bash
git add ai-service/app/services/kv/ai_resize_worker.py
git commit -m "feat(ai): add AI resize background worker with bounded concurrency"
```

---

## Task 4: AI Service — Router Endpoints

**Files:**
- Create: `ai-service/app/routes/kv_resize.py`
- Modify: `ai-service/main.py:37-42` (add router include)

- [ ] **Step 1: Create the router with 3 endpoints**

```python
"""
KV AI Resize Router

Endpoints:
- POST /ai/kv/ai-resize           — Create a batch AI resize job
- GET  /ai/kv/ai-resize/{job_id}  — Poll job status and tile progress
- POST /ai/kv/ai-resize/single    — Re-generate a single tile immediately
"""

from fastapi import APIRouter, status

from app.services.kv.ai_resize_schemas import (
    AiResizeJobResponse,
    AiResizePollResponse,
    AiResizeRequest,
    AiResizeSingleRequest,
    AiResizeSingleResponse,
)
from app.services.kv.ai_resize_service import KVAiResizeService
from app.services.kv.job_queue import KVJobQueue
from app.utils.response import error_response, success_response

router = APIRouter()

_ai_resize_service = None


def _get_ai_resize_service() -> KVAiResizeService:
    global _ai_resize_service
    if _ai_resize_service is None:
        _ai_resize_service = KVAiResizeService(job_queue=KVJobQueue())
    return _ai_resize_service


@router.post("/ai/kv/ai-resize", status_code=status.HTTP_202_ACCEPTED)
async def create_ai_resize_job(request: AiResizeRequest):
    """Create a batch AI resize job. Returns job_id for polling."""
    try:
        service = _get_ai_resize_service()
        job_id = service.create_job(request)
        return success_response(
            status_code=status.HTTP_202_ACCEPTED,
            message="AI resize job created",
            data={
                "job_id": job_id,
                "status": "queued",
                "total_tiles": len(request.dimensions),
            },
        )
    except Exception as e:
        return error_response(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            message=f"Failed to create AI resize job: {str(e)}",
        )


@router.get("/ai/kv/ai-resize/{job_id}")
async def poll_ai_resize_job(job_id: str):
    """Poll the status and progress of an AI resize job."""
    service = _get_ai_resize_service()
    result = service.get_job_status(job_id)

    if result is None:
        return error_response(
            status_code=status.HTTP_404_NOT_FOUND,
            message=f"AI resize job '{job_id}' not found",
        )

    return success_response(
        message="AI resize job status",
        data=result,
    )


@router.post("/ai/kv/ai-resize/single")
async def resize_single_tile(request: AiResizeSingleRequest):
    """Re-generate a single tile immediately (no queue)."""
    try:
        service = _get_ai_resize_service()
        result = await service.resize_single(request)
        return success_response(
            message="Single tile resized successfully",
            data=result,
        )
    except Exception as e:
        return error_response(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            message=f"Failed to resize single tile: {str(e)}",
        )
```

- [ ] **Step 2: Register the router in main.py**

In `ai-service/main.py`, add the import and include the router. After the existing line that includes `kv_router` (line 42), add:

```python
from app.routes.kv_resize import router as kv_resize_router
```

Add to the router includes section:

```python
app.include_router(kv_resize_router)
```

- [ ] **Step 3: Start the AI resize worker in FastAPI lifespan**

In `ai-service/main.py`, add the lifespan context manager to start the background worker. Add this before the `app = FastAPI(...)` block:

```python
import asyncio
from contextlib import asynccontextmanager
from app.services.kv.ai_resize_worker import run_ai_resize_worker
from app.services.kv.ai_resize_service import KVAiResizeService
from app.services.kv.job_queue import KVJobQueue


@asynccontextmanager
async def lifespan(app):
    # Start AI resize worker
    ai_resize_service = KVAiResizeService(job_queue=KVJobQueue())
    worker_task = asyncio.create_task(run_ai_resize_worker(ai_resize_service))
    yield
    worker_task.cancel()
```

Then add `lifespan=lifespan` to the `FastAPI()` constructor.

- [ ] **Step 4: Verify the AI service starts without errors**

Run: `cd ai-service && source .venv/bin/activate && python -c "from app.routes.kv_resize import router; print('Router OK')"`
Expected: `Router OK`

- [ ] **Step 5: Commit**

```bash
git add ai-service/app/routes/kv_resize.py ai-service/main.py
git commit -m "feat(ai): add AI resize endpoints and register worker in lifespan"
```

---

## Task 5: PHP API — Migration & Model

**Files:**
- Create: `api/database/migrations/xxxx_create_kv_ai_resize_jobs_table.php`
- Create: `api/app/Models/KvAiResizeJob.php`

- [ ] **Step 1: Create the migration**

Run: `cd api && php artisan make:migration create_kv_ai_resize_jobs_table`

Then replace the generated migration content with:

```php
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('kv_ai_resize_jobs', function (Blueprint $table) {
            $table->uuid('id')->primary();
            $table->uuid('project_id');
            $table->string('ai_job_id')->index();
            $table->string('source_image_url', 1024);
            $table->string('status')->default('queued');
            $table->json('dimensions');
            $table->json('tiles')->nullable();
            $table->timestamps();

            $table->foreign('project_id')
                ->references('id')
                ->on('kv_projects')
                ->cascadeOnDelete();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('kv_ai_resize_jobs');
    }
};
```

- [ ] **Step 2: Create the Eloquent model**

```php
<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class KvAiResizeJob extends Model
{
    use HasUuids;

    protected $fillable = [
        'project_id',
        'ai_job_id',
        'source_image_url',
        'status',
        'dimensions',
        'tiles',
    ];

    protected $casts = [
        'dimensions' => 'array',
        'tiles' => 'array',
    ];

    public function project(): BelongsTo
    {
        return $this->belongsTo(KvProject::class, 'project_id');
    }
}
```

- [ ] **Step 3: Run the migration**

Run: `cd api && php artisan migrate`
Expected: `Migrating ... create_kv_ai_resize_jobs_table ... DONE`

- [ ] **Step 4: Commit**

```bash
git add api/database/migrations/*create_kv_ai_resize_jobs_table.php api/app/Models/KvAiResizeJob.php
git commit -m "feat(api): add KvAiResizeJob model and migration"
```

---

## Task 6: PHP API — Controller (3 Proxy Endpoints)

**Files:**
- Create: `api/app/Http/Controllers/Api/Kv/KvAiResizeController.php`
- Modify: `api/routes/api.php:473-537` (add routes)

- [ ] **Step 1: Create the controller**

```php
<?php

namespace App\Http\Controllers\Api\Kv;

use App\Http\Controllers\Controller;
use App\Models\KvAiResizeJob;
use App\Models\KvProject;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Str;

class KvAiResizeController extends Controller
{
    /**
     * POST /api/v1/kv/projects/{project}/ai-resize
     *
     * Create a batch AI resize job. Forwards to AI service and stores job reference.
     */
    public function store(Request $request, KvProject $project): JsonResponse
    {
        $validated = $request->validate([
            'source_image_option_id' => ['nullable', 'string'],
            'source_image_url' => ['nullable', 'string'],
            'dimensions' => ['required', 'array', 'min:1'],
            'dimensions.*.width' => ['required', 'integer', 'min:1'],
            'dimensions.*.height' => ['required', 'integer', 'min:1'],
            'dimensions.*.label' => ['nullable', 'string'],
        ]);

        // Determine source image URL (same pattern as KvResizeController)
        $sourceImageUrl = $validated['source_image_url'] ?? null;

        if (! $sourceImageUrl && ! empty($validated['source_image_option_id'])) {
            $imageOption = $project->imageOptions()
                ->where('id', $validated['source_image_option_id'])
                ->first();
            $sourceImageUrl = $imageOption?->image_url;
        }

        if (! $sourceImageUrl) {
            $firstOption = $project->imageOptions()->whereNotNull('image_url')->first();
            $sourceImageUrl = $firstOption?->image_url;
        }

        if (! $sourceImageUrl) {
            return response()->json([
                'message' => 'No source image found for AI resize',
                'data' => null,
            ], 422);
        }

        // Forward to AI service
        $aiEndpoint = config(
            'services.agno.kv_ai_resize_endpoint',
            'http://localhost:8000/ai/kv/ai-resize'
        );

        try {
            $response = Http::timeout(30)->post($aiEndpoint, [
                'source_image_url' => $sourceImageUrl,
                'dimensions' => $validated['dimensions'],
                'project_id' => $project->id,
            ]);

            if (! $response->successful()) {
                return response()->json([
                    'message' => 'AI service failed to create resize job',
                    'errors' => $response->json(),
                    'data' => null,
                ], 502);
            }

            $aiData = $response->json('data');

            // Store job reference in DB
            $job = KvAiResizeJob::create([
                'project_id' => $project->id,
                'ai_job_id' => $aiData['job_id'],
                'source_image_url' => $sourceImageUrl,
                'status' => 'queued',
                'dimensions' => $validated['dimensions'],
            ]);

            return response()->json([
                'message' => 'AI resize job created',
                'data' => [
                    'id' => $job->id,
                    'job_id' => $aiData['job_id'],
                    'status' => 'queued',
                    'total_tiles' => $aiData['total_tiles'],
                ],
            ], 202);

        } catch (\Exception $e) {
            return response()->json([
                'message' => 'Failed to create AI resize job',
                'errors' => $e->getMessage(),
                'data' => null,
            ], 500);
        }
    }

    /**
     * GET /api/v1/kv/projects/{project}/ai-resize/{jobId}
     *
     * Poll AI resize job status. Proxies to AI service.
     */
    public function show(Request $request, KvProject $project, string $jobId): JsonResponse
    {
        $aiEndpoint = config(
            'services.agno.kv_ai_resize_endpoint',
            'http://localhost:8000/ai/kv/ai-resize'
        );

        try {
            $response = Http::timeout(10)->get("{$aiEndpoint}/{$jobId}");

            if (! $response->successful()) {
                return response()->json([
                    'message' => 'AI resize job not found',
                    'data' => null,
                ], 404);
            }

            $aiData = $response->json('data');

            // Cache completed tiles in DB
            $job = KvAiResizeJob::where('ai_job_id', $jobId)
                ->where('project_id', $project->id)
                ->first();

            if ($job && $aiData) {
                $job->update([
                    'status' => $aiData['status'],
                    'tiles' => $aiData['tiles'],
                ]);
            }

            return response()->json([
                'message' => 'AI resize job status',
                'data' => $aiData,
            ]);

        } catch (\Exception $e) {
            return response()->json([
                'message' => 'Failed to poll AI resize job',
                'errors' => $e->getMessage(),
                'data' => null,
            ], 500);
        }
    }

    /**
     * POST /api/v1/kv/projects/{project}/ai-resize/single
     *
     * Re-generate a single tile immediately.
     */
    public function resizeSingle(Request $request, KvProject $project): JsonResponse
    {
        $validated = $request->validate([
            'source_image_url' => ['required', 'string'],
            'width' => ['required', 'integer', 'min:1'],
            'height' => ['required', 'integer', 'min:1'],
            'label' => ['nullable', 'string'],
            'prompt_override' => ['nullable', 'string'],
        ]);

        $aiEndpoint = config(
            'services.agno.kv_ai_resize_single_endpoint',
            'http://localhost:8000/ai/kv/ai-resize/single'
        );

        try {
            $response = Http::timeout(120)->post($aiEndpoint, $validated);

            if (! $response->successful()) {
                return response()->json([
                    'message' => 'AI service failed to resize tile',
                    'errors' => $response->json(),
                    'data' => null,
                ], 502);
            }

            return response()->json([
                'message' => 'Tile resized successfully',
                'data' => $response->json('data'),
            ]);

        } catch (\Exception $e) {
            return response()->json([
                'message' => 'Failed to resize tile',
                'errors' => $e->getMessage(),
                'data' => null,
            ], 500);
        }
    }
}
```

- [ ] **Step 2: Add routes to api.php**

In `api/routes/api.php`, inside the KV route group (after the existing resize route around line 507), add:

```php
// AI Resize
Route::post('projects/{project}/ai-resize', [KvAiResizeController::class, 'store']);
Route::get('projects/{project}/ai-resize/{jobId}', [KvAiResizeController::class, 'show']);
Route::post('projects/{project}/ai-resize/single', [KvAiResizeController::class, 'resizeSingle']);
```

And add the import at the top of the route file:

```php
use App\Http\Controllers\Api\Kv\KvAiResizeController;
```

- [ ] **Step 3: Verify routes are registered**

Run: `cd api && php artisan route:list --path=kv/projects | grep ai-resize`
Expected: 3 routes listed (POST store, GET show, POST resizeSingle)

- [ ] **Step 4: Commit**

```bash
git add api/app/Http/Controllers/Api/Kv/KvAiResizeController.php api/routes/api.php
git commit -m "feat(api): add AI resize proxy controller with 3 endpoints"
```

---

## Task 7: Frontend — Types & API Functions

**Files:**
- Create: `web/src/types/kv/ai-resize.ts`
- Create: `web/src/services/kv/ai-resize.ts`

- [ ] **Step 1: Create TypeScript types**

```typescript
export interface AiResizeDimension {
  width: number;
  height: number;
  label?: string;
}

export interface AiResizeTile {
  id: string;
  dimension_label: string | null;
  width: number;
  height: number;
  gemini_aspect_ratio: string;
  image_url: string | null;
  status: "queued" | "processing" | "completed" | "failed";
}

export interface AiResizeJobResponse {
  id: string;
  job_id: string;
  status: "queued" | "processing" | "completed" | "failed";
  total_tiles: number;
}

export interface AiResizePollResponse {
  job_id: string;
  status: "queued" | "processing" | "completed" | "failed";
  progress: { completed: number; total: number };
  tiles: AiResizeTile[];
}

export interface AiResizeSingleResponse {
  tile_id: string;
  image_url: string;
  status: string;
}
```

- [ ] **Step 2: Create API functions**

```typescript
import { api } from "@/services/api";
import type {
  AiResizeDimension,
  AiResizeJobResponse,
  AiResizePollResponse,
  AiResizeSingleResponse,
} from "@/types/kv/ai-resize";

export async function createAiResize(
  projectId: string,
  body: {
    dimensions: AiResizeDimension[];
    source_image_option_id?: string;
    source_image_url?: string;
  },
): Promise<AiResizeJobResponse> {
  const res = await api.post(`/kv/projects/${projectId}/ai-resize`, body);
  return res.data.data;
}

export async function pollAiResize(
  projectId: string,
  jobId: string,
): Promise<AiResizePollResponse> {
  const res = await api.get(`/kv/projects/${projectId}/ai-resize/${jobId}`);
  return res.data.data;
}

export async function regenerateSingleTile(
  projectId: string,
  body: {
    source_image_url: string;
    width: number;
    height: number;
    label?: string;
    prompt_override?: string;
  },
): Promise<AiResizeSingleResponse> {
  const res = await api.post(`/kv/projects/${projectId}/ai-resize/single`, body);
  return res.data.data;
}
```

- [ ] **Step 3: Commit**

```bash
git add web/src/types/kv/ai-resize.ts web/src/services/kv/ai-resize.ts
git commit -m "feat(web): add AI resize types and API functions"
```

---

## Task 8: Frontend — React Query Hooks

**Files:**
- Create: `web/src/hooks/kv/useAiResize.ts`

- [ ] **Step 1: Create the hooks**

```typescript
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  createAiResize,
  pollAiResize,
  regenerateSingleTile,
} from "@/services/kv/ai-resize";
import type { AiResizePollResponse } from "@/types/kv/ai-resize";

export function useCreateAiResize() {
  return useMutation({
    mutationFn: ({
      projectId,
      body,
    }: {
      projectId: string;
      body: Parameters<typeof createAiResize>[1];
    }) => createAiResize(projectId, body),
  });
}

export function useAiResizePoll(
  projectId: string | null,
  jobId: string | null,
  options?: { enabled?: boolean },
) {
  return useQuery<AiResizePollResponse>({
    queryKey: ["ai-resize-poll", projectId, jobId],
    queryFn: () => pollAiResize(projectId!, jobId!),
    enabled: !!projectId && !!jobId && (options?.enabled ?? true),
    refetchInterval: (query) => {
      const status = query.state.data?.status;
      if (status === "completed" || status === "failed") return false;
      return 3000; // Poll every 3 seconds while processing
    },
  });
}

export function useRegenerateTile() {
  return useMutation({
    mutationFn: ({
      projectId,
      body,
    }: {
      projectId: string;
      body: Parameters<typeof regenerateSingleTile>[1];
    }) => regenerateSingleTile(projectId, body),
  });
}
```

- [ ] **Step 2: Export from hooks index**

Check if `web/src/hooks/kv/index.ts` exists and add the export. If hooks are imported directly from their files (not through an index), skip this step.

- [ ] **Step 3: Commit**

```bash
git add web/src/hooks/kv/useAiResize.ts
git commit -m "feat(web): add React Query hooks for AI resize"
```

---

## Task 9: Frontend — Store Updates

**Files:**
- Modify: `web/src/store/kv/useKvResizerStore.ts:24-72`

- [ ] **Step 1: Add AI resize state to the store**

Add these fields to the `KvResizerStore` interface (after the existing `focalPointOverrides` field):

```typescript
  // ── AI Resize ────────────────────────────────
  aiResizeJobId: string | null;
  aiResizeStatus: "idle" | "processing" | "completed" | "failed";
  aiResizeTiles: import("@/types/kv/ai-resize").AiResizeTile[];

  // ── AI Resize Actions ────────────────────────
  setAiResizeJob: (jobId: string) => void;
  setAiResizeStatus: (status: "idle" | "processing" | "completed" | "failed") => void;
  setAiResizeTiles: (tiles: import("@/types/kv/ai-resize").AiResizeTile[]) => void;
  updateAiResizeTile: (tileId: string, patch: Partial<import("@/types/kv/ai-resize").AiResizeTile>) => void;
  clearAiResize: () => void;
```

Add the initial state and actions in the `create` function:

```typescript
  // AI Resize initial state
  aiResizeJobId: null,
  aiResizeStatus: "idle",
  aiResizeTiles: [],

  // AI Resize actions
  setAiResizeJob: (jobId) => set({ aiResizeJobId: jobId, aiResizeStatus: "processing" }),
  setAiResizeStatus: (status) => set({ aiResizeStatus: status }),
  setAiResizeTiles: (tiles) => set({ aiResizeTiles: tiles }),
  updateAiResizeTile: (tileId, patch) =>
    set((state) => ({
      aiResizeTiles: state.aiResizeTiles.map((t) =>
        t.id === tileId ? { ...t, ...patch } : t
      ),
    })),
  clearAiResize: () =>
    set({ aiResizeJobId: null, aiResizeStatus: "idle", aiResizeTiles: [] }),
```

Also update the `reset` action to include AI resize state.

- [ ] **Step 2: Commit**

```bash
git add web/src/store/kv/useKvResizerStore.ts
git commit -m "feat(web): add AI resize state to resizer store"
```

---

## Task 10: Frontend — AI Resize Progress Page

**Files:**
- Create: `web/src/app/(dashboard)/workflows/kv-generator/projects/[id]/ai-resize/page.tsx`
- Create: `web/src/app/(dashboard)/workflows/kv-generator/projects/[id]/ai-resize/components/AiResizeProgress.tsx`

- [ ] **Step 1: Create the page component**

```tsx
"use client";

import { use } from "react";
import AiResizeProgress from "./components/AiResizeProgress";

export default function AiResizePage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id: projectId } = use(params);
  return <AiResizeProgress projectId={projectId} />;
}
```

- [ ] **Step 2: Create the AiResizeProgress component**

This component shows a progress bar and tiles appearing progressively as Gemini processes them. Read the existing `ExportPreview.tsx` component at `web/src/app/(dashboard)/workflows/kv-generator/export-preview/components/ExportPreview.tsx` for styling patterns, and the `Stepper` component usage.

```tsx
"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";
import { Stepper } from "@/components/frndos";
import { useKvResizerStore } from "@/store/kv";
import { useAiResizePoll } from "@/hooks/kv/useAiResize";
import { useKvProject } from "@/hooks/kv";
import type { AiResizeTile } from "@/types/kv/ai-resize";

const STEPS = [
  { label: "Context Setup", state: "done" as const },
  { label: "Generate", state: "done" as const },
  { label: "Edit", state: "done" as const },
  { label: "Select Sizes", state: "done" as const },
  { label: "AI Resize", state: "active" as const },
  { label: "Review", state: "default" as const },
  { label: "Export", state: "default" as const },
];

interface AiResizeProgressProps {
  projectId: string;
}

export default function AiResizeProgress({ projectId }: AiResizeProgressProps) {
  const router = useRouter();
  const { data: project } = useKvProject(projectId);
  const { aiResizeJobId, setAiResizeTiles, setAiResizeStatus } =
    useKvResizerStore();

  const { data: pollData } = useAiResizePoll(projectId, aiResizeJobId, {
    enabled: !!aiResizeJobId,
  });

  // Sync poll data to store
  useEffect(() => {
    if (!pollData) return;
    setAiResizeTiles(pollData.tiles);

    if (pollData.status === "completed" || pollData.status === "failed") {
      setAiResizeStatus(pollData.status);
    }
  }, [pollData, setAiResizeTiles, setAiResizeStatus]);

  // Navigate to review when complete
  useEffect(() => {
    if (pollData?.status === "completed") {
      router.push(`/workflows/kv-generator/projects/${projectId}/ai-resize-review`);
    }
  }, [pollData?.status, projectId, router]);

  const progress = pollData?.progress ?? { completed: 0, total: 0 };
  const percent =
    progress.total > 0
      ? Math.round((progress.completed / progress.total) * 100)
      : 0;
  const tiles = pollData?.tiles ?? [];

  return (
    <div className="flex flex-col gap-6">
      {/* Stepper */}
      <div className="rounded-2xl bg-white/5 px-2 py-1">
        <Stepper steps={STEPS} />
      </div>

      {/* Project bar */}
      {project && (
        <div className="flex items-center gap-3 rounded-xl border border-white/10 bg-white/5 px-4 py-3">
          <span className="font-geist text-sm font-medium text-gray-200">
            {project.name}
          </span>
        </div>
      )}

      {/* Header */}
      <div>
        <h1 className="font-geist text-xl font-semibold text-gray-100">
          AI Resize in Progress
        </h1>
        <p className="mt-1 font-geist text-sm text-gray-400">
          Resizing your image to {progress.total} platform sizes using AI...
        </p>
      </div>

      {/* Progress bar */}
      <div className="flex flex-col gap-2">
        <div className="flex items-center justify-between">
          <span className="font-geist text-sm text-gray-400">
            {progress.completed} / {progress.total} tiles completed
          </span>
          <span className="font-geist text-sm font-medium text-gray-200">
            {percent}%
          </span>
        </div>
        <div className="h-2 overflow-hidden rounded-full bg-white/10">
          <div
            className="h-full rounded-full bg-gradient-to-r from-emerald-500 to-teal-400 transition-all duration-500"
            style={{ width: `${percent}%` }}
          />
        </div>
      </div>

      {/* Progressive tile grid */}
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 xl:grid-cols-4">
        {tiles.map((tile: AiResizeTile) => (
          <div
            key={tile.id}
            className="overflow-hidden rounded-xl border border-white/10 bg-white/5"
          >
            {/* Image or placeholder */}
            <div className="relative aspect-video">
              {tile.image_url ? (
                <img
                  src={tile.image_url}
                  alt={tile.dimension_label ?? ""}
                  className="h-full w-full object-cover"
                />
              ) : (
                <div className="flex h-full w-full items-center justify-center bg-white/5">
                  {tile.status === "processing" ? (
                    <div className="h-5 w-5 animate-spin rounded-full border-2 border-white/20 border-t-emerald-400" />
                  ) : tile.status === "failed" ? (
                    <span className="font-geist text-xs text-red-400">Failed</span>
                  ) : (
                    <span className="font-geist text-xs text-gray-500">Queued</span>
                  )}
                </div>
              )}

              {/* Status badge */}
              {tile.status === "completed" && (
                <div className="absolute right-2 top-2 rounded-md bg-emerald-500/20 px-2 py-0.5 text-[10px] font-medium text-emerald-300 backdrop-blur-sm">
                  Done
                </div>
              )}
            </div>

            {/* Label */}
            <div className="px-3 py-2">
              <div className="font-geist text-xs font-medium text-gray-300">
                {tile.dimension_label}
              </div>
              <div className="font-geist text-[10px] text-gray-500">
                {tile.width} &times; {tile.height}
              </div>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
```

- [ ] **Step 3: Commit**

```bash
git add web/src/app/\(dashboard\)/workflows/kv-generator/projects/\[id\]/ai-resize/
git commit -m "feat(web): add AI resize progress page with progressive tile rendering"
```

---

## Task 11: Frontend — Review Grid Page

**Files:**
- Create: `web/src/app/(dashboard)/workflows/kv-generator/projects/[id]/ai-resize-review/page.tsx`
- Create: `web/src/app/(dashboard)/workflows/kv-generator/projects/[id]/ai-resize-review/components/AiResizeReviewGrid.tsx`
- Create: `web/src/app/(dashboard)/workflows/kv-generator/projects/[id]/ai-resize-review/components/TileEditorModal.tsx`

- [ ] **Step 1: Create the page component**

```tsx
"use client";

import { use } from "react";
import AiResizeReviewGrid from "./components/AiResizeReviewGrid";

export default function AiResizeReviewPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id: projectId } = use(params);
  return <AiResizeReviewGrid projectId={projectId} />;
}
```

- [ ] **Step 2: Create the AiResizeReviewGrid component**

Read the existing `ImageOptionsGallery.tsx` at `web/src/app/(dashboard)/workflows/kv-generator/image-options-gallery/components/ImageOptionsGallery.tsx` for styling patterns. Also read the existing `ExportPreview.tsx` for tile rendering patterns.

```tsx
"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Stepper, Button } from "@/components/frndos";
import {
  ArrowDownTrayIcon,
  ArrowPathIcon,
  PencilSquareIcon,
} from "@heroicons/react/24/outline";
import { useKvResizerStore } from "@/store/kv";
import { useKvProject } from "@/hooks/kv";
import { useRegenerateTile } from "@/hooks/kv/useAiResize";
import { resizeAndExportZip } from "@/services/kv/api";
import type { AiResizeTile } from "@/types/kv/ai-resize";
import TileEditorModal from "./TileEditorModal";

const STEPS = [
  { label: "Context Setup", state: "done" as const },
  { label: "Generate", state: "done" as const },
  { label: "Edit", state: "done" as const },
  { label: "Select Sizes", state: "done" as const },
  { label: "AI Resize", state: "done" as const },
  { label: "Review", state: "active" as const },
  { label: "Export", state: "default" as const },
];

interface AiResizeReviewGridProps {
  projectId: string;
}

export default function AiResizeReviewGrid({
  projectId,
}: AiResizeReviewGridProps) {
  const router = useRouter();
  const { data: project } = useKvProject(projectId);
  const { aiResizeTiles, updateAiResizeTile } = useKvResizerStore();
  const regenerateTile = useRegenerateTile();

  const [editingTile, setEditingTile] = useState<AiResizeTile | null>(null);
  const [downloading, setDownloading] = useState(false);

  const sourceImageUrl = useKvResizerStore(
    (s) => s.aiResizeTiles[0]?.image_url ?? "",
  );

  const handleRegenerate = async (tile: AiResizeTile) => {
    const originalUrl = useKvResizerStore.getState().aiResizeTiles.find(
      (t) => t.id === tile.id,
    );
    if (!originalUrl) return;

    try {
      const result = await regenerateTile.mutateAsync({
        projectId,
        body: {
          source_image_url: sourceImageUrl,
          width: tile.width,
          height: tile.height,
          label: tile.dimension_label ?? undefined,
        },
      });

      updateAiResizeTile(tile.id, {
        image_url: result.image_url,
        status: "completed",
      });
    } catch (err) {
      console.error("Failed to regenerate tile:", err);
    }
  };

  const handleExportZip = async () => {
    setDownloading(true);
    try {
      const completedTiles = aiResizeTiles.filter(
        (t) => t.status === "completed" && t.image_url,
      );

      const result = await resizeAndExportZip(projectId, {
        dimensions: completedTiles.map((t) => ({
          width: t.width,
          height: t.height,
          label: t.dimension_label ?? undefined,
        })),
        source_image_url: completedTiles[0]?.image_url ?? "",
      });

      // Trigger download
      const link = document.createElement("a");
      link.href = result.zip_url;
      link.download = result.zip_file_name;
      document.body.appendChild(link);
      link.click();
      document.body.removeChild(link);
    } catch (err) {
      console.error("Export failed:", err);
    } finally {
      setDownloading(false);
    }
  };

  const handleTileEdited = (tileId: string, newImageUrl: string) => {
    updateAiResizeTile(tileId, { image_url: newImageUrl });
    setEditingTile(null);
  };

  return (
    <div className="flex flex-col gap-6">
      {/* Stepper */}
      <div className="rounded-2xl bg-white/5 px-2 py-1">
        <Stepper steps={STEPS} />
      </div>

      {/* Project bar */}
      {project && (
        <div className="flex items-center gap-3 rounded-xl border border-white/10 bg-white/5 px-4 py-3">
          <span className="font-geist text-sm font-medium text-gray-200">
            {project.name}
          </span>
        </div>
      )}

      {/* Header */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h1 className="font-geist text-xl font-semibold text-gray-100">
            Review AI-Resized Images
          </h1>
          <p className="mt-1 font-geist text-sm text-gray-400">
            Click any tile to edit with the full image editor. Regenerate tiles
            that don&apos;t look right.
          </p>
        </div>
        <Button
          variant="primary"
          size="medium"
          leftIcon={<ArrowDownTrayIcon className="h-4 w-4" />}
          onClick={handleExportZip}
          disabled={downloading}
        >
          {downloading ? "Exporting..." : "Export ZIP"}
        </Button>
      </div>

      {/* Tile grid */}
      <div className="grid grid-cols-2 gap-4 sm:grid-cols-3 xl:grid-cols-4">
        {aiResizeTiles.map((tile) => (
          <div
            key={tile.id}
            className="group overflow-hidden rounded-xl border border-white/10 bg-white/5 transition-colors hover:border-white/20"
          >
            {/* Image */}
            <div className="relative aspect-video">
              {tile.image_url ? (
                <img
                  src={tile.image_url}
                  alt={tile.dimension_label ?? ""}
                  className="h-full w-full object-cover"
                />
              ) : (
                <div className="flex h-full w-full items-center justify-center bg-white/5">
                  <span className="font-geist text-xs text-red-400">
                    Failed
                  </span>
                </div>
              )}

              {/* Hover actions */}
              {tile.image_url && (
                <div className="absolute inset-0 flex items-center justify-center gap-2 bg-black/50 opacity-0 transition-opacity group-hover:opacity-100">
                  <button
                    type="button"
                    onClick={() => setEditingTile(tile)}
                    className="flex items-center gap-1.5 rounded-lg bg-white/10 px-3 py-1.5 font-geist text-xs text-white backdrop-blur-sm hover:bg-white/20"
                  >
                    <PencilSquareIcon className="h-3.5 w-3.5" />
                    Edit
                  </button>
                  <button
                    type="button"
                    onClick={() => handleRegenerate(tile)}
                    className="flex items-center gap-1.5 rounded-lg bg-white/10 px-3 py-1.5 font-geist text-xs text-white backdrop-blur-sm hover:bg-white/20"
                  >
                    <ArrowPathIcon className="h-3.5 w-3.5" />
                    Regenerate
                  </button>
                </div>
              )}

              {/* AI badge */}
              <div className="absolute right-2 top-2 rounded-md bg-emerald-500/20 px-2 py-0.5 text-[10px] font-medium text-emerald-300 backdrop-blur-sm">
                AI
              </div>
            </div>

            {/* Label */}
            <div className="px-3 py-2">
              <div className="font-geist text-xs font-medium text-gray-300">
                {tile.dimension_label}
              </div>
              <div className="font-geist text-[10px] text-gray-500">
                {tile.width} &times; {tile.height} &middot;{" "}
                {tile.gemini_aspect_ratio}
              </div>
            </div>
          </div>
        ))}
      </div>

      {/* Tile Editor Modal */}
      {editingTile && (
        <TileEditorModal
          tile={editingTile}
          projectId={projectId}
          onClose={() => setEditingTile(null)}
          onSave={handleTileEdited}
        />
      )}
    </div>
  );
}
```

- [ ] **Step 3: Create the TileEditorModal component**

This wraps the existing Konva `ImageEditorCanvas` component. Read `web/src/app/(dashboard)/workflows/kv-generator/image-editor/components/ImageEditorCanvas.tsx` for the props interface.

```tsx
"use client";

import dynamic from "next/dynamic";
import { BaseModal } from "@/components/frndos";
import type { AiResizeTile } from "@/types/kv/ai-resize";

const ImageEditorCanvas = dynamic(
  () =>
    import(
      "@/app/(dashboard)/workflows/kv-generator/image-editor/components/ImageEditorCanvas"
    ),
  { ssr: false },
);

interface TileEditorModalProps {
  tile: AiResizeTile;
  projectId: string;
  onClose: () => void;
  onSave: (tileId: string, newImageUrl: string) => void;
}

export default function TileEditorModal({
  tile,
  projectId,
  onClose,
  onSave,
}: TileEditorModalProps) {
  return (
    <BaseModal
      isOpen={true}
      onClose={onClose}
      title={`Edit — ${tile.dimension_label} (${tile.width}×${tile.height})`}
      showCloseButton
      className="!w-[90vw] !max-w-[1200px]"
    >
      <div className="h-[70vh]">
        <ImageEditorCanvas
          projectId={projectId}
          optionId={null}
        />
      </div>
    </BaseModal>
  );
}
```

> **Note for implementer:** The `ImageEditorCanvas` component currently loads its image from `optionId`. For this tile editor use case, you may need to pass the tile's `image_url` as a prop or modify the editor to accept an external image URL. Check the component's implementation and add a `sourceImageUrl` prop if needed. This is a targeted modification — the existing editor behavior should stay unchanged when `optionId` is provided.

- [ ] **Step 4: Commit**

```bash
git add web/src/app/\(dashboard\)/workflows/kv-generator/projects/\[id\]/ai-resize-review/
git commit -m "feat(web): add AI resize review grid with per-tile editing and export"
```

---

## Task 12: Frontend — Wire Up Platform Size Selection

**Files:**
- Modify: `web/src/app/(dashboard)/workflows/kv-generator/platform-size-selection/components/PlatformSizeSelection.tsx`

- [ ] **Step 1: Read the current component**

Read the full `PlatformSizeSelection.tsx` file to understand the current "confirm" flow (around lines 361-383 where it builds tiles and navigates to export preview).

- [ ] **Step 2: Modify the confirm handler**

Replace the current logic that builds static tiles and navigates to export preview. Instead:

1. Import `useCreateAiResize` from `@/hooks/kv/useAiResize`
2. Import `useKvResizerStore` actions: `setAiResizeJob`
3. On confirm:
   - Collect selected dimensions from the store
   - Call `createAiResize` mutation with the project's source image and selected dimensions
   - Store the returned `job_id` via `setAiResizeJob(result.job_id)`
   - Navigate to `/workflows/kv-generator/projects/${projectId}/ai-resize` instead of `/export/preview`

The exact changes depend on the current code structure — read the file first, then make minimal edits to swap the navigation target and trigger the AI resize API call.

- [ ] **Step 3: Verify the navigation flow works**

Run: `cd web && bun dev`
Navigate to a KV project → Export → Select sizes → Confirm
Expected: Navigates to the AI resize progress page (not the old export preview)

- [ ] **Step 4: Commit**

```bash
git add web/src/app/\(dashboard\)/workflows/kv-generator/platform-size-selection/
git commit -m "feat(web): wire platform size selection to AI resize flow"
```

---

## Task 13: Integration Test — End-to-End Flow

**Files:**
- No new files — manual verification

- [ ] **Step 1: Start all services**

```bash
./run-all.sh
```

Verify all services are healthy:
```bash
curl -sf http://localhost:9191/api && echo "API OK"
curl -sf http://localhost:3000 && echo "Web OK"
curl -sf http://localhost:8000/health && echo "AI OK"
redis-cli ping
```

- [ ] **Step 2: Test AI service endpoint directly**

```bash
curl -X POST http://localhost:8000/ai/kv/ai-resize \
  -H "Content-Type: application/json" \
  -d '{
    "source_image_url": "https://placehold.co/1080x1080/png",
    "dimensions": [
      {"width": 1080, "height": 1920, "label": "IG Stories"},
      {"width": 1200, "height": 628, "label": "Meta Horizontal"}
    ]
  }'
```

Expected: 202 response with `job_id`

Then poll:
```bash
curl http://localhost:8000/ai/kv/ai-resize/{job_id}
```

Expected: Progress updates, tiles appearing as `completed`

- [ ] **Step 3: Test the full flow through the frontend**

1. Open http://localhost:3000
2. Navigate to KV Generator → open a project
3. Go through Generate → Edit → Select Sizes
4. Select a few platform sizes and confirm
5. Verify the AI resize progress page appears
6. Wait for tiles to complete
7. Verify the review grid shows all completed tiles
8. Click a tile to verify the Konva editor opens
9. Click Export ZIP to verify download works

- [ ] **Step 4: Final commit with any fixes**

```bash
git add -A
git commit -m "fix(web): integration fixes for AI resize flow"
```

---

## Summary

| Task | Service | What |
|------|---------|------|
| 1 | AI Service | Schemas + aspect ratio mapping |
| 2 | AI Service | Resize service (Gemini + S3 + Redis) |
| 3 | AI Service | Background worker |
| 4 | AI Service | Router endpoints + lifespan |
| 5 | PHP API | Migration + model |
| 6 | PHP API | Controller (3 proxy endpoints) |
| 7 | Frontend | Types + API functions |
| 8 | Frontend | React Query hooks |
| 9 | Frontend | Store updates |
| 10 | Frontend | Progress page |
| 11 | Frontend | Review grid + tile editor modal |
| 12 | Frontend | Wire platform size selection |
| 13 | All | Integration test |
