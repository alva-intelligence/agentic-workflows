# KV Generator — Force gpt-image-2 for Every Resize Export

**Date:** 2026-05-11
**Status:** Draft
**Supersedes:** decision branch in current implementation (per `2026-04-28-studio-kv-resize-design.md`)
**Alternate direction not taken:** `2026-04-07-kv-ai-resize-design.md` (Gemini-based rewrite)

## Summary

Today the KV resize pipeline calls `gpt-image-2` only when the cropped source doesn't cover the target dimensions; otherwise it does a pure PIL `LANCZOS` downscale with no model involvement. The "AI-powered resize" feature claim is therefore only half true — a meaningful share of platform tiles in any batch is produced by deterministic CPU image manipulation.

This spec forces every export tile through gpt-image-2's `/v1/images/edits` endpoint so resize output is uniformly AI-generated, while keeping the source content pixel-exact in the interior of every tile via a thin AI-extended frame.

## Goal

When a user picks N platform sizes and starts a resize, every one of the N output tiles should be AI-generated with consistent provenance, latency profile, and visual treatment — no quality cliff between tiles that "happened to be a clean downscale" and tiles that needed outpainting.

## Non-goals

- **Not switching providers.** gpt-image-2 is locked. The `flux-fill-pro` option is removed.
- **Not changing the API or web contract.** `POST /v1/studio/files/{file_id}/resize-exports`, the SSE stream, React Query polling, and the `kv_resize_exports` model stay identical.
- **Not introducing Gemini.** Alternate spec at `2026-04-07-kv-ai-resize-design.md` is explicitly not taken.
- **Not replacing `smart_crop` with AI.** Heuristic crop stays. Only the resize/extend stage moves to AI for all tiles.
- **Not adding a review grid or per-tile Konva editor for resize.** Those remain ideas in the Gemini spec; not part of this rework.

## Decisions

| Question | Decision | Reasoning |
|---|---|---|
| AI provider | `gpt-image-2` only (lock) | Already wired; preserves source pixels exactly via mask; one less branch. |
| Should every tile use AI? | Yes — remove the LANCZOS fast-path | "AI-powered resize" feature claim should be uniformly true. |
| What to do when cropped source covers target | Reserve a 32px frame on each side; AI fills the frame | 32px ≈ 3% of a 1080² canvas. Real AI imprint; subject pixel-exact in interior. Trivially tunable upward later. |
| Kill-switch | `KV_RESIZE_FORCE_AI` env var (default `true`) | Reversible without a deploy revert if production regresses. |
| `flux-fill-pro` provider | Removed | One model surface to reason about. Re-add later if needed. |

## Architecture (unchanged)

```
Web (Next.js)
  ↓ POST /v1/studio/files/{file_id}/resize-exports
API (Laravel)
  ↓ ProcessKvResizeExportJob → POST {AI}/ai/kv-resize/export
AI Service (FastAPI)
  ── service.py decision change happens here ──
  ↓ POST {API}/api/v1/internal/kv-resize-exports/completed
API
  ↓ SSE / polling
Web
```

## Changes

### ai-service

**`app/agents/kv_resize/service.py`** — replace the conditional branch (today's lines 41–57) with a single AI path, with the legacy branching retained behind `force_ai=False`:

```python
def process_resize_export(req: ResizeExportRequest) -> None:
    try:
        source = _download(req.source_image_url)
        cropped = _resolve_crop(source, req)   # smart_crop or user crop_window

        if req.force_ai:
            image_bytes = _ai_resize(cropped, req)
        else:
            image_bytes = _legacy_resize(cropped, req)  # today's logic, verbatim

        image_url = save_bytes_to_file(...)
        post_completed(export_id=req.export_id, status="done", image_url=image_url)
    except Exception as exc:
        post_completed(
            export_id=req.export_id, status="failed", error_message=str(exc)
        )


def _ai_resize(cropped: Image.Image, req: ResizeExportRequest) -> bytes:
    canvas, paste_box = place_on_target_with_frame(
        cropped, req.target_width, req.target_height, frame_px=32
    )
    mask = build_mask(req.target_width, req.target_height, paste_box)
    image_bytes, _model = outpaint(
        canvas, mask, OUTPAINT_GUIDANCE, provider="gpt-image-2"
    )
    return image_bytes


# _legacy_resize: lift today's existing branching (LANCZOS fast-path else outpaint)
# out of process_resize_export into this helper unchanged.
```

**`app/agents/kv_resize/canvas.py`** — add `place_on_target_with_frame(cropped, target_w, target_h, frame_px)`:

- Compute usable inner box: `(target_w - 2 * frame_px, target_h - 2 * frame_px)`.
- Scale `cropped` to fit (preserve aspect, fit not fill) inside the inner box.
- Paste centered on a `target_w × target_h` RGBA transparent canvas.
- Return `(canvas, paste_box)` where `paste_box = (x, y, x + w, y + h)` for the placed source.

`build_mask` and `pad_to_target` are unchanged (`build_mask` already accepts an arbitrary paste_box).

**`app/agents/kv_resize/request_schema.py`** — lock the model:

```python
# before
KvResizeModel = Literal["gpt-image-2", "flux-fill-pro"]

# after
KvResizeModel = Literal["gpt-image-2"]
```

Add to `ResizeExportRequest`: `force_ai: bool = True`.

**`app/tools/outpaint_image.py`** — delete the `flux-fill-pro` branch and the `outpaint_with_flux_fill` function/import. `outpaint()` keeps the `provider` keyword but only `"gpt-image-2"` is valid; passing anything else raises `ValueError`.

### api

**`config/services.php`** — keep `KV_RESIZE_MODEL` for telemetry; default and only-accepted value becomes `gpt-image-2` (fail fast with a clear error at job dispatch if env is anything else). Add `KV_RESIZE_FORCE_AI` env, default `true`.

**`app/Jobs/Studio/ProcessKvResizeExportJob.php`** — forward `force_ai` from config into the ai-service POST body:

```php
$payload = [
    'export_id' => $export->id,
    'source_image_url' => $sourceUrl,
    'target_width' => $platform->width,
    'target_height' => $platform->height,
    'crop_window' => $export->crop_window,
    'model' => config('services.ai.kv_resize_model'),
    'force_ai' => (bool) config('services.ai.kv_resize_force_ai'),
];
```

The DB row's `model` column continues to be set from the ai-service callback for audit.

### web

No changes.

### data-service

No changes.

## Cost & latency

|   | Today (mixed batches) | After |
|---|---|---|
| Per-tile latency | LANCZOS: <1s · outpaint: 15–45s | All tiles: 15–45s |
| Per-tile OpenAI cost | $0 or $0.04–0.19 | $0.04–0.19 |
| 12-tile batch token spend | $0.12–$0.40 typical | $0.50–$2.30 typical |
| 12-tile batch wall time (queue-paralleled) | 30–90s | 45–90s |

Multiplier in raw token spend: ~3–5×. Queue parallelism absorbs most of the wall-time impact. The existing `token_usage` field in the ai-service callback flows into the credits-charge path in `KvResizeExportInternalController` — no billing changes needed.

## Failure modes

| Failure | Today | After |
|---|---|---|
| gpt-image-2 rate limit / 5xx | Affects only the slow path; fast-path tiles unaffected | Affects every tile. Existing 2-retry envelope in `ProcessKvResizeExportJob` + per-row `failed` state + UI retry button absorbs this. |
| Content-policy block | Same handling, marked `failed` with `error_message` | Same, but more tiles now exposed to it. |
| Network timeout | 180s `requests` timeout | Unchanged. |

No new failure mode is introduced. The change widens the population of tiles that *can* hit existing failure modes.

## Rollout

1. Deploy ai-service with the new code. `force_ai` reads from request, defaults `True` on the model.
2. Deploy api with `KV_RESIZE_FORCE_AI=true` and `KV_RESIZE_MODEL=gpt-image-2`.
3. Smoke test on staging:
   - One tile that previously hit fast-path (e.g., 1536×1024 → 1200×628).
   - One tile that previously hit outpaint (e.g., 1536×1024 → 1080×1920).
   - One same-aspect downscale (e.g., 1080×1080 → 640×640).
4. If a smoke regression is observed: set `KV_RESIZE_FORCE_AI=false` in api `.env`, restart the queue worker. Legacy fast-path returns immediately. No code revert required.

## Out of scope (future work)

- Per-tile review grid (see `2026-04-07-kv-ai-resize-design.md`)
- Konva editor per-tile re-edits hooked into resize
- Replacing `smart_crop` with VLM-driven crop choice
- Making frame size user-tunable or platform-tunable
- Aspect-ratio-aware deduplication (one model call shared across same-ratio platforms)
