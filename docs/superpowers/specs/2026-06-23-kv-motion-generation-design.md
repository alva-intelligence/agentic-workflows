# KV Motion Generation — Design Spec

> **Status:** draft
> **Author:** daffa
> **Created:** 2026-06-23
> **Services:** web, api, ai-service
> **Topic slug:** kv-motion-generation

## Overview

Add a **Motion** mode to the KV (Key Visual) studio that turns an approved KV
image into a short video clip. The generated KV image becomes the **first frame**
of an image-to-video generation, so output stays on-brand by construction — the
user animates an asset that already passed brand review rather than starting from
a blank text-to-video prompt.

This is **"animate-your-approved-KV"**, not a general video studio. The video
generation infrastructure already exists in
`ai-service/app/tools/generate_video.py` (multi-provider, image-to-video capable
via Veo 3.1, Kling v3/Omni, Sora). The missing piece is the **product surface**
that connects KV output to that infrastructure. We reuse the existing tool — no
parallel video integration.

## Goals

- One-click path from a finished KV version to a short motion clip (≈4–8s).
- On-brand by default (KV image = first frame).
- Predictable results via curated motion presets + optional free-text prompt.
- Persisted as an artifact attached to the KV file, viewable/downloadable later.

## Non-Goals (YAGNI for v1)

- Text-to-video from scratch (no first frame). Motion always animates an existing KV.
- Multi-scene storyboard / stitching multiple KVs into one sequence.
- Project-level standalone video gallery decoupled from KV files.
- Fine-grained audio control. We accept whatever the chosen model's default audio
  behavior is (Veo can emit audio); no audio prompt UI in v1.
- HunYuan model (text-only, cannot take an image input → not applicable).

## User Flow

1. User is in the KV studio with a KV version active → clicks the **Motion** tab
   in the top nav (4th tab: Sketch · Craft · Resize · **Motion**).
2. Canvas swaps to Motion mode (same architecture as Resize). A floating panel
   (bottom-left, mirroring the Resize platform panel) shows:
   - **First-frame preview** — the active KV version.
   - **Model picker** (small): **Veo 3.1 Fast** (fast/cheap, ≤8s, may include
     audio) · **Kling Omni** (more control: last-frame support, duration ≤15s).
     *Sora optional as a third option.*
   - **Motion presets** (chips): Subtle Zoom · Parallax · Product Spin · Camera
     Pan · Cinematic Push-in.
   - **Optional prompt** for extra detail.
   - **Duration & ratio** — ratio defaults to the KV's aspect ratio; duration
     defaults to 8s.
   - **Generate motion** button.
3. Submit → an async job runs (KV image as `first_frame_image`, preset+prompt as
   `refined_prompt`). The panel shows status **queued → generating → done/failed**
   (same pattern as Resize export jobs).
4. On completion → video plays inline in the panel, is added to the file's
   **motion list** and recorded in Version History. User can **download** (MP4)
   or **delete**.
5. **Secondary entry:** from Version History, selecting an older version → "Animate"
   → enters Motion mode with that version as the first frame.

### Presets

A preset is a **curated prompt fragment**, not model-specific behavior. Example:

- *Subtle Zoom* → "slow cinematic push-in, gentle parallax, subtle ambient motion,
  hold composition"

Because presets are prompt fragments, they work across all models. The model
picker only affects **capabilities** (last-frame support, max duration, audio),
not preset semantics. This keeps the preset→model mapping simple.

## Architecture

KV generation uses SSE streaming (near-synchronous). Video generation is slow
(~30s–2min), so Motion follows the **job + callback** pattern already used by
**Resize export** (`KvResizeExportController` → ai-service → callback to
`KvResizeExportInternalController`), not SSE.

```
web (KvMotionPanel) ──POST /studio/kv/motion──► api (KvMotionController@store)
   │                                              │ create row status=queued
   │                                              │ dispatch job → POST ai-service
   │                                              ▼
   │                                    ai-service (agents/kv_motion)
   │                                       service.py: preset+prompt → refined_prompt
   │                                       call tools/generate_video.py
   │                                       (first_frame_image = KV image, model/provider)
   │                                              │ (slow; video → S3)
   │                                              ▼
   │                                    callback ──► api (KvMotionCallbackController)
   │                                                  update row: status=done, video_url
   ▼
web polls GET /studio/kv/motion/{id} (TanStack Query refetchInterval ~4s)
   status: queued → generating → done/failed → render <video> inline
```

### ai-service — new module `app/agents/kv_motion/` (mirrors `kv_resize/`)

- `router.py` — `POST /ai/kv-motion` (internal endpoint).
- `service.py` — build `refined_prompt` from preset+prompt, call the existing
  `tools/generate_video.py` with `first_frame_image`, `video_model`, `provider`,
  `duration`, `video_ratio`. **Reuses the existing video tool fully** — no new
  video integration.
- `prompts/presets.py` — prompt templates per preset.
- `api_client.py` — POST the completion/failure callback to api.
- `request_schema.py` / `response_schema.py` — Pydantic models.

### api — mirrors the Resize pattern

- Migration: `kv_motion_generations` table (schema below).
- Model: `KvMotionGeneration`.
- `KvMotionController` — `store` (dispatch job), `index`, `show`, `destroy`.
- `KvMotionCallbackController` — internal; receives `video_url` / error from
  ai-service.
- `StoreKvMotionRequest` — validates `model`, `provider`, `preset`, `prompt`,
  `duration`, `ratio`, `source_generation_id`.
- `GenerateKvMotionJob` — queued job that POSTs to ai-service.
- Usage/billing: hook into existing video-usage tracking
  (`user_chat_log_usages` video columns).

### web — mirrors `KvResizePanel`

- New `canvasMode: "motion"` in `KvGeneratorLayout.tsx` + a Motion tab in
  `KvCanvasTopNav.tsx` (segmented control).
- `KvMotionPanel.tsx` — floating panel (bottom-left).
- `KvMotionViewport.tsx` — first-frame preview + result `<video>` player.
- `useKvMotion.ts` — create + poll status (TanStack Query).
- Type `KvMotionGeneration` in `web/src/types/studio.ts`.
- **Feature flag** (PostHog) gating the new user-facing feature.
- **Analytics events** (snake_case, frndOS conventions) for open-mode, generate,
  preset-select, download.
- Build from existing frndos components first.

## Data Model

New table `kv_motion_generations`:

| Column | Type | Notes |
|--------|------|-------|
| id | pk | |
| kv_file_id | fk → kv files | owning KV file |
| source_generation_id | fk → kv generation | which version was animated |
| model | string | e.g. `veo-3.1-fast-generate-preview` |
| provider | string | `google` \| `kuaishou` \| `openai` |
| preset | string | preset key (nullable if prompt-only) |
| prompt | text | optional user detail |
| duration | string/int | seconds |
| ratio | string | `16:9` \| `9:16` \| `1:1` |
| status | enum | `queued` \| `generating` \| `done` \| `failed` |
| video_url | string | S3 URL (null until done) |
| error | text | failure reason (null unless failed) |
| created_at / updated_at | timestamps | |

Mirrors how generations and resize results are stored today.

## Error Handling

- Generation failure (provider error, timeout): callback sets `status=failed` +
  `error`; panel shows a retry affordance (re-submit reuses the same params).
- Job dispatch failure: row stays `queued`; surfaced as failed after a timeout
  guard.
- Missing/expired KV image URL: validated before dispatch (the first frame must
  resolve).

## Testing

- **api:** Unit tests (the Feature suite is currently blocked by the workspaces
  backfill + SoftDeletes migration issue — use Unit tests). Cover request
  validation, the model, and callback controller logic.
- **ai-service:** Unit tests for preset→prompt construction and service
  orchestration with `generate_video` mocked.
- **web:** `bun test` for panel/hook logic (bunfig preloads jest-dom). The real
  gate is `bun run build`, not tsc.

## Open Questions

- Sora as the third picker option in v1, or ship with just Veo 3.1 Fast + Kling
  Omni and add Sora later?
- Exact preset list — confirm the 5 proposed presets cover the common cases.
- Default model when entering Motion mode (proposed: Veo 3.1 Fast).
