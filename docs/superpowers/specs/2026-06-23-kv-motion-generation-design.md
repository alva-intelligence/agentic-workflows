# KV Motion Generation — Design Spec

> **Status:** draft
> **Author:** daffa
> **Created:** 2026-06-23
> **Revised:** 2026-06-27 — model picker now driven by the askFRND video-model
> registry (dynamic, capability-filtered) instead of a hardcoded 3-model list;
> adds per-model adaptive duration/ratio and an audio on/off toggle.
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
- Fine-grained audio control / audio prompt. v1 exposes only a simple **audio
  on/off toggle** for models that support it (see "Audio" below) — no audio
  prompt, no per-channel mixing.
- **Reference video / reference audio upload** (Kling Omni video-ref, Seedance
  lip-sync). Even for models that support it, v1 does NOT surface a reference
  upload — the KV image is the sole input (first frame). Capability metadata
  records `reference_video` / `reference_audio` for the future, but no UI in v1.
- Text-only models (e.g. HunYuan) are **auto-excluded** by the I2V capability
  filter — they cannot take an image input, so they never appear in the picker.
  This is now a runtime filter, not a hardcoded omission.

## User Flow

1. User is in the KV studio with a KV version active → clicks the **Motion** tab
   in the top nav (4th tab: Sketch · Craft · Resize · **Motion**).
2. Canvas swaps to Motion mode (same architecture as Resize). A floating panel
   (bottom-left, mirroring the Resize platform panel) shows:
   - **First-frame preview** — the active KV version.
   - **Model picker** — **dynamic list from the askFRND video-model registry**
     (`GET /v1/threads/video-models`, the same source the chat picker uses),
     **filtered to image-to-video–capable models** (`video_capabilities.image_to_video`).
     Each model shows its provider logo (reuse `ProviderLogo`). Default selection
     on entering Motion mode = **Veo 3.1 Fast** (pinned; falls back to the first
     I2V model if Veo is absent). See "Model source & capabilities" below.
   - **Motion presets** (chips): Subtle Zoom · Parallax · Product Spin · Camera
     Pan · Cinematic Push-in.
   - **Optional prompt** for extra detail.
   - **Duration & ratio** — **adaptive per selected model**: options rebuild from
     that model's `video_capabilities`. Ratio defaults to the KV's aspect ratio
     when the model supports it; otherwise it clamps to the model's default ratio
     with a hint (e.g. Sora has no 1:1). Duration defaults to 8s, clamped to the
     nearest supported value when a model can't honor it (e.g. 12s → 8s on Veo).
   - **Audio toggle** — shown only for models whose `video_capabilities.audio`
     is `optional` (Kling, Seedance); default **on**. `always` models (Veo) show
     a locked-on indicator; `none`/uncontrollable (Sora) hide the toggle.
   - **Generate motion** button.
3. Submit → an async job runs (KV image as `first_frame_image`, preset+prompt as
   `refined_prompt`). The panel shows status **queued → generating → done/failed**
   (same pattern as Resize export jobs).
4. On completion → video plays inline in the panel, is added to the file's
   **motion list** and recorded in Version History. User can **download** (MP4)
   or **delete**.
5. **Secondary entry:** from Version History, selecting an older version → "Animate"
   → enters Motion mode with that version as the first frame.
6. **Guided regenerate:** each result row has a "Regenerate" action. It prefills
   the panel from that row (model, preset, prompt, duration, ratio) and exposes a
   small "steering" input ("make the zoom slower", "add rain"). On submit, the
   steering text is merged into the prompt and a NEW motion row is created with
   `parent_motion_id` pointing at the source row (lineage). This stays
   direct-call and deterministic — it mirrors the existing KV Resize
   guided-regenerate (`additional_prompt`). No Agno / chat agent involved.

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

### Reuse boundary (video engine vs chat orchestration)

Motion **reuses the same video engine FRND chat uses** —
`app/tools/generate_video.py` (multi-provider Veo/Kling/Sora, S3 upload, token
usage). It is NOT a new/parallel video integration. `generate_video` is a plain
standalone callable (no `@tool` decorator, no Agno dependency) and is already
invoked directly elsewhere (`app/tools/router.py`), so calling it directly from
the motion job is an established pattern.

Motion does **not** route through the Agno chat agent or the chat request flow
(`ThreadController` + `isVideoGeneration`). Decision: **direct-call**, mirroring
Resize (a one-shot studio job, not a conversational turn). Rationale:

- **Determinism** — the button must always produce a video with the chosen
  first frame + preset; an LLM-driven tool call could alter args, skip, or refuse.
- **Cost/latency** — no extra LLM turn on top of an already slow (~30s–2min)
  generation.
- **No session coupling** — avoids the Agno `session_data` wholesale-rewrite
  class of bug that one-shot jobs sidestep.
- **Consistency** — matches Resize and the rest of studio one-shot generation.

The deeper principle from prior guidance (reuse `app.tools.*`, no parallel
integrations) is honored: we reuse `generate_video` verbatim. Routing through
the Agno agent would only be warranted for a conversational/context-aware motion
UX (e.g. "make the zoom slower" in chat), which is out of scope for v1.

### Model source & capabilities (single source of truth)

KV Motion does **not** maintain its own model list. It reuses the askFRND
video-model registry and adds the per-model **rules** that the picker needs.

**Where the list lives.** `api/app/Helpers/LLMHelper.php` (`MODELS` constant,
`getVideoModels()`) is the canonical registry, served by
`GET /v1/threads/video-models` (`ThreadController@models`). The chat picker
already consumes it via `getVideoModels()` (web `services/query.ts`).

**Where the rules live today (the problem).** Per-model constraints (I2V support,
last-frame, durations, ratios, resolutions, reference video/audio, audio
behavior) are currently hardcoded inside the provider branches of
`ai-service/app/tools/generate_video.py`. They are NOT in the endpoint payload,
so the picker can't honor them without duplicating them.

**Decision — extend the registry payload (additive).** Add a `video_capabilities`
block to each **video-type** entry in `MODELS`. The existing serializer
(`ThreadController@models`) passes model arrays through verbatim (it only strips
`type` + `pricing`), so the new block flows into the `type=video` payload with no
serializer change. Shape:

```jsonc
"video_capabilities": {
  "image_to_video": true,        // KV-Motion filter key; false → excluded
  "last_frame": true,
  "durations": [4, 8],           // supported seconds
  "default_duration": 8,
  "ratios": ["16:9", "9:16", "1:1"],
  "default_ratio": "16:9",       // used when KV ratio unsupported; null = inherit KV
  "resolutions": ["1080p", "720p"],
  "default_resolution": "1080p",
  "reference_video": false,      // recorded for future; not surfaced in v1
  "reference_audio": false,
  "audio": "always"              // "always" | "optional" | "none"
}
```

Values are authored to **match `generate_video.py`'s existing per-provider rules**
(the audit table below). A code comment on each entry marks the sync point
(`// keep in sync with generate_video.py <provider> branch`). `generate_video.py`
remains the **enforcing backstop** — if the registry and the tool ever disagree,
the tool's validation/clamp wins, so a stale capability value degrades to a
clamp, never a crash.

**No impact on chat (verified).** `video_capabilities` is added only to
`type === 'video'` entries; the chat (`type=chat`) and image payloads filter by
type and never include it. The serializer is additive passthrough; the web chat
parses the payload structurally (`as VideoModel`, no zod/strict schema), so the
extra field is inert for chat. Chat behavior is unchanged.

**Capability values (v1, from the `generate_video.py` audit):**

| Model | I2V | last-frame | durations | ratios | audio | ref video / audio |
|-------|:---:|:---:|---|---|---|---|
| `veo-3.1-fast-generate-preview` / `veo-3.1-generate-preview` | ✅ | ✅ | 4, 8 | 16:9, 9:16, 1:1 | always | – / – |
| `sora-2` / `sora-2-pro` | ✅ | ❌ | 6 | 16:9, 9:16 | none | – / – |
| `kling-v3-video` / `kling-v3-omni-video` | ✅ | ✅ | 4, 5, 8, 12, 15 | 16:9, 9:16, 1:1 | optional | omni: video / – |
| `seedance-2.0` / `seedance-2.0-fast` | ✅ | ✅ | 4, 8, 12, 15 | 16:9, 4:3, 1:1, 3:4, 9:16, 21:9, 9:21, adaptive | optional | video / audio |
| `hunyuan-video` | ❌ | ❌ | — | — | — | — (filtered out) |

> The exact set surfaced is whatever the registry returns with
> `image_to_video: true` at runtime — the table reflects the current registry,
> not a hardcoded allow-list.

### Adaptive picker rules (web)

- **Filter:** show only models with `is_active` and `video_capabilities.image_to_video`.
- **Default model:** Veo 3.1 Fast if present, else first filtered entry.
- **Duration/ratio:** rebuilt from the selected model's capabilities on every
  model change. On switch, clamp the current duration to the nearest supported
  value and reset ratio to the KV ratio (if supported) or the model default,
  surfacing a one-line hint when a value was changed.
- **Hard-disable** a model only when it has **zero** config compatible with the
  current KV (rare). Otherwise prefer clamping over hiding.
- **Audio toggle** visibility/behavior driven by `video_capabilities.audio`
  (`optional` → toggle, default on; `always` → locked-on; `none` → hidden).

### Audio control (ai-service)

`generate_video.py` currently hardcodes `generate_audio` (Kling `True`; Seedance
derived; Veo emits audio inherently with no flag). v1 threads a `generate_audio`
boolean from the motion request through `kwargs` into the Kling and Seedance
input dicts (replacing the hardcode), preserving today's default (`True`) when
unset. This is a **small passthrough change**, not a new integration; Veo/Sora
audio behavior is unchanged (their capability is `always`/`none`).

### ai-service — new module `app/agents/kv_motion/` (mirrors `kv_resize/`)

- `router.py` — `POST /ai/kv-motion` (internal endpoint).
- `service.py` — build `refined_prompt` from preset+prompt, call the existing
  `tools/generate_video.py` with `first_frame_image`, `video_model`, `provider`,
  `duration`, `video_ratio`, and `generate_audio` (passthrough kwarg).
  **Reuses the existing video tool fully** — no new video integration.
- `tools/generate_video.py` — minimal change: read `generate_audio` from kwargs
  (default `True`) and use it in the Kling/Seedance input dicts instead of the
  current hardcode. No change to Veo/Sora/Hunyuan branches.
- `prompts/presets.py` — prompt templates per preset.
- `api_client.py` — POST the completion/failure callback to api.
- `request_schema.py` / `response_schema.py` — Pydantic models.

### api — mirrors the Resize pattern

- `LLMHelper::MODELS` — add the `video_capabilities` block to each video entry
  (additive; see "Model source & capabilities"). No serializer change.
- Migration: `kv_motion_generations` table (schema below).
- Model: `KvMotionGeneration`.
- `KvMotionController` — `store` (dispatch job), `index`, `show`, `destroy`.
- `KvMotionCallbackController` — internal; receives `video_url` / error from
  ai-service.
- `StoreKvMotionRequest` — validates `model`, `provider`, `preset`, `prompt`,
  `duration`, `ratio`, `generate_audio`, `source_generation_id`. **Model must be
  an I2V-capable video model** (`LLMHelper::getVideoModels()` filtered by
  `video_capabilities.image_to_video`), and `duration`/`ratio` must be within the
  selected model's capability set (read from the registry — single source).
- `GenerateKvMotionJob` — queued job that POSTs to ai-service.
- Usage/billing: hook into existing video-usage tracking
  (`user_chat_log_usages` video columns).

### web — mirrors `KvResizePanel`

- New `canvasMode: "motion"` in `KvGeneratorLayout.tsx` + a Motion tab in
  `KvCanvasTopNav.tsx` (segmented control).
- **Model list from the registry**, not a hardcoded constant: reuse
  `getVideoModels()` (TanStack Query, same cache as chat), filter to I2V-capable.
  `web/src/types/kv/motion.ts` drops the hardcoded `MOTION_MODELS`/`MOTION_DURATIONS`/
  `MOTION_RATIOS` and instead defines the `VideoCapabilities` type + helpers
  (`isImageToVideo`, `clampDuration`, `resolveRatio`, `audioMode`).
- `KvMotionPanel.tsx` — floating panel (bottom-left); model picker uses
  `ProviderLogo`; duration/ratio/audio controls are capability-driven (adaptive).
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
| parent_motion_id | fk → kv_motion_generations (nullable) | lineage for guided regenerate |
| model | string | any I2V video-model id from the registry (no enum) |
| provider | string | `google` \| `kuaishou` \| `openai` \| `bytedance` \| … (registry-driven) |
| preset | string | preset key (nullable if prompt-only) |
| prompt | text | optional user detail |
| duration | string/int | seconds |
| ratio | string | aspect ratio (model-dependent set, e.g. `16:9`/`9:16`/`1:1`/`adaptive`) |
| generate_audio | boolean | audio on/off; default `true`; ignored by models whose `audio` is `always`/`none` |
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

## Resolved Decisions

- **Model picker (v1): dynamic from the askFRND registry** — reuse
  `GET /v1/threads/video-models`, filtered to I2V-capable models. No hardcoded
  list; text-only models (HunYuan) are auto-excluded. (Supersedes the earlier
  "3 hardcoded models" decision.)
- **Per-model rules live in the registry payload** via an additive
  `video_capabilities` block authored to match `generate_video.py`;
  `generate_video.py` stays the enforcing backstop. Verified additive/no chat impact.
- **Adaptive picker:** duration/ratio rebuild per model; unsupported values clamp
  to nearest (hint shown); hard-disable a model only when no compatible config
  exists. Ratio defaults to the KV's aspect ratio when supported.
- **Audio: on/off toggle**, capability-driven (`optional` → toggle default on;
  `always` → locked-on; `none` → hidden). Threaded as `generate_audio` into
  `generate_video.py` (Kling/Seedance).
- **Reference video/audio upload: out of scope v1** even for capable models
  (KV image is the sole input); capability recorded for the future.
- **Default model on entering Motion mode: Veo 3.1 Fast** (pinned; falls back to
  first I2V model if absent).
- **Presets: the 5 proposed** (Subtle Zoom, Parallax, Product Spin, Camera Pan,
  Cinematic Push-in) are sufficient for v1.
