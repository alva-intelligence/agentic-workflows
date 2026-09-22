# Studio Storyboard → Video — Design

> **Status:** design (approved in brainstorming 2026-07-03)
> **Author:** daffa
> **Type:** new standalone Studio tool
> **Services:** api, ai-service, web

## Overview

A new **Storyboard** tool inside the Studio area that takes a user from an idea to a
video: draft a sequence of scenes, generate an on-brand still **frame** for each scene
with **consistent recurring subjects**, animate each frame into a **clip**, and
(optionally) **stitch** the clips into one continuous video.

It is a **separate tool from the KV generator** — its own route, its own data model,
its own canvas. It shares **zero** data model with KV. It reuses only *infrastructure*:
the image-generation tools (`generate_image`, `edit_image`), the video-generation tool
(`generate_video`), the Agno/Gemini chat setup, and the internal-token callback +
credit-metering patterns. Reusing model integrations is not "KV mindset" — it is not
rebuilding integrations.

### What it is not

- Not an extension of KV / key-visual generation. "Storyboard" is its own product concept.
- Not text-to-video from scratch — every clip is **frame-first** (still image → video),
  which keeps output on-brand and gives a cheap review loop before video spend.

## Core concept: the artifact

A **Storyboard** is a brand-scoped document containing:

- an ordered list of **Scenes** — each with a beat/description, camera & motion notes,
  a generated **frame** image, and (later) a **clip**; and
- a **Cast** — the recurring subjects (characters / products / settings) with **locked
  reference images**, scoped to that one storyboard, that keep subjects visually
  consistent across scenes.

### Three entry points, one artifact

All three populate the same board and can be mixed freely:

1. **Brief → board.** User types a brief; AI decomposes it into scenes and a proposed
   cast, pre-tagging which cast members appear in each scene.
2. **Manual.** User adds/edits scenes and cast by hand.
3. **Shot-list-first.** User works the text (scene descriptions, camera notes) first;
   frames and clips are generated downstream, per scene.

### Consistency: explicit cast + reference-conditioning (Approach A)

Subject consistency is a first-class requirement. The mechanism:

- A **cast member** is a named recurring subject (`kind`: character | product | setting
  | prop) anchored by **one or more locked reference images**.
- References come from **either** an **upload** (user brings a product photo / existing
  render) **or** **generate-and-lock** (user describes the subject, the tool generates a
  portrait/hero shot, user approves → locked). Both converge on the same thing: a locked
  reference image.
- Each scene is **tagged** with the cast members that appear in it. Tagging is **AI-inferred**
  from the scene description (with manual override).
- A scene's frame is generated **conditioned on the locked references of its tagged cast**,
  using the multi-reference image path (see Pipeline §3). This is the consistency step.

**Feasibility (verified against the codebase):** multi-reference conditioning is already
wired and proven. `edit_image` accepts **multiple reference images + a text prompt** in a
single call for both OpenAI (`gpt-image-2`) and Gemini (`gemini-3.1-flash-image-preview`).
KV's "craft" mode uses this exact path daily (base + N reference attachments → preserves
subject while changing composition). Plain text-to-image (`generate_image`) has **no**
reference support, so scene-frame generation **must** use the `edit_image` path.

**Model choice:** `gpt-image-2` for scene frames (production-hardened here, proven
multi-reference). Gemini is a viable alternative (cleaner API, higher latency).

## Data model

Six new tables. Naming, soft-delete, and activity conventions mirror the existing Studio
tables. Nothing here touches KV tables.

```
studio_storyboards                the project / document (model `StudioStoryboard`)
  id, workspace_id, brand_id
  name, logline                  (the brief / description)
  status                         draft | ready | ...
  ratio                          default aspect ratio for all scenes (overridable per scene)
  thumbnail_url                  derived from scene 1's frame
  final_video_url                set when stitched (phase 3, nullable)
  created_by, last_edited_by, last_edited_at, timestamps, deleted_at (soft delete)

storyboard_cast_members          the cast (storyboard-scoped)
  id, storyboard_id              (cascade)
  name                           "Maya", "the sneaker"
  kind                           character | product | setting | prop
  description                    text used when generating/regenerating the reference
  source                         uploaded | generated
  reference_images               jsonb [urls]   -- one or more locked references
  thumbnail_url, created_by, timestamps

storyboard_scenes                the ordered beats
  id, storyboard_id              (cascade)
  position                       int (order)
  description                    the beat / action
  camera_notes                   shot type / movement (text)
  motion_preset                  nullable (reuse existing motion presets)
  motion_prompt                  nullable (steering text for the video step)
  duration                       seconds
  ratio                          nullable (falls back to studio_storyboards.ratio)
  status                         empty | frame_generating | frame_ready
                                 | clip_generating | clip_ready | failed
  current_frame_id               FK -> scene_frames (the approved frame)
  metadata jsonb, timestamps, created_by

scene_frames                     frame versions per scene (like kv_generations)
  id, scene_id                   (cascade)
  version_number, parent_frame_id (nullable -- iteration chain)
  image_url, source_image_url, thumbnail_url
  prompt_snapshot, model, provider
  cast_refs_used                 jsonb [cast_member_id] -- which references conditioned this frame
  ai_service_run_id, metadata jsonb, created_by, created_at

scene_cast                       join: who appears in a scene
  scene_id, cast_member_id       (composite PK)
  ai_inferred                    bool  (true = AI tagged it, false = user added)

scene_clips                      clip versions per scene (like kv motion rows)
  id, scene_id                   (cascade)
  parent_clip_id                 (nullable -- regenerate lineage)
  frame_id                       FK -> scene_frames (the frame this animated)
  video_url, duration, model, provider
  motion_preset, motion_prompt
  status, ai_service_run_id, created_at, created_by
```

**Notes:**

- **Frames and clips are both versioned** (own tables + parent links) → "regenerate frame"
  / "regenerate clip" get a cheap review loop, exactly like KV's version chains, without
  touching KV tables.
- `cast_refs_used` on each frame records **which references produced it** (debuggability +
  reproducibility).
- Cast is **storyboard-scoped** in v1. A brand-level cast library can be added later
  without breaking this (would introduce `brand_id` + a reference join); explicitly out of
  scope for v1.

## Pipeline (ai-service surface)

Five operations. Each reuses existing plumbing; none needs a new model integration. The
**heavy render steps** (frame, clip, stitch) follow the codebase's proven pattern —
**async job → `202 Accepted` → internal callback persists to api** (as KV Motion and the KV
callback already do); the browser polls/streams status, the DB is the source of truth, and
callbacks are **idempotent** on `generation_id` + internal token. **Decompose is the
exception** — it is a synchronous streaming call that returns an editable draft to the
client and persists nothing until the user confirms (see below).

```
(1) decompose --> [scenes + cast drafted, editable]
                    |-- (2) cast refs locked (generate or upload)
                    '-- per scene: (3) frame (cast-conditioned) --> (4) clip
                                                                      '-- (5) stitch (optional, last)
```

### (1) Decompose brief → scenes + cast  *(LLM, one call)*

`POST /ai/storyboard/decompose` — brief + brand context → a structured **editable draft**:
ordered scenes (description, camera notes, suggested duration) **and** a proposed cast
(detected recurring subjects), with each scene pre-tagged with its cast
(`scene_cast.ai_inferred = true`). **Produces text only — no image/video spend.**

**Transport:** synchronous **streaming (SSE)**, reusing KV's SSE transport — the draft
streams to the client as it is produced. **It persists nothing.** The user reviews/edits
the draft, and only on **confirm** does the client create the storyboard / scenes / cast
via normal CRUD endpoints. This differs deliberately from the async-job+callback pattern
of the render steps (decompose is a single, fast LLM turn with no heavy result to store),
and it is what enforces "editable draft before spend." Reuses the Agno/Gemini chat setup KV
uses.

### (2) Generate-and-lock a cast reference  *(text → image)*

`POST /ai/storyboard/cast/generate` — cast member's text description → **`generate_image`**
(text-to-image, no refs) → candidate portrait/hero shot → user approves → locked reference.
Upload path skips this entirely; the uploaded file **is** the locked reference.

### (3) Generate a scene frame  *(multi-reference img → img — the consistency step)*

`POST /ai/storyboard/scenes/{id}/frame` — scene description + **locked references of that
scene's tagged cast** → **`edit_image` multi-reference path** (`gpt-image-2`) → new
composition featuring those subjects → new `scene_frames` row (versioned). Regenerate = new
version. Brand logo/knowledge baked server-side the same way KV does it (logo bake is **not**
gated on brand-knowledge — decoupled, per prior KV lesson).

### (4) Animate a frame → clip  *(image → video)*

`POST /ai/storyboard/scenes/{id}/clip` — approved frame as **first frame** + motion
preset/prompt → **`generate_video`** (direct-call, the KV Motion path verbatim) →
`scene_clips` row (versioned, regenerable). The scene's tagged cast references may also ride
into the video model's `image_context` for extra stability.

### (5) Stitch clips → one video  *(phase 3, additive)*

`POST /ai/storyboard/{id}/render` — ordered scene clips → concatenate with transitions →
`storyboards.final_video_url`. This is the **one net-new capability** (FFmpeg-based
assembly); everything above reuses existing tools. Blocks nothing upstream.

**Transitions (v1):** two options — **hard cut (default)** and **cross-fade** (dissolve).
Selected at render time (storyboard-level). Keeps the FFmpeg surface minimal; richer
transitions are out of scope for v1.

## Service breakdown

| Service | New work | Reuses |
|---|---|---|
| **api** | 6 migrations + models; `Storyboard`/`Scene`/`CastMember`/`Frame`/`Clip` controllers (CRUD + reorder); trigger endpoints (decompose/frame/clip/render); 5 internal callback controllers; persistence services; feature-flag gate | `KvCreditMeteringService` pattern, internal-token callback pattern, SoftDeletes/activity conventions |
| **ai-service** | New `app/agents/storyboard/` package (5 ops above); FFmpeg stitch util (the only net-new capability) | `generate_image`, `edit_image`, `generate_video` tools; Agno/Gemini chat setup; motion presets; callback client |
| **web** | New Studio tool route `studio/storyboard/...`; board editor (ordered scene cards + reorder), cast panel, brief→decompose, per-scene frame/clip controls, assembly view; hooks/types/API client; **PostHog events** (mandatory); feature flag | SSE transport, Studio shell/layout, frndos components |

## Placement

- Lives in the existing **Studio** area as its own tool, listed alongside the KV generator.
- Route: `web/src/app/.../brands/[id]/studio/storyboard/...` (brand-scoped).
- Own tables (above); shares no data model with KV.

## Build order (phases)

Each phase is shippable and gets its own per-service implementation plan (mirroring how KV
Motion had one design → plans per service). **v1 = all three phases.**

- **Phase 1 — Board + cast + AI authoring + consistent frames.** All 6 tables, CRUD, board
  editor, manual scene text/camera notes, cast upload + generate-and-lock, reorder,
  decompose (brief → scenes + cast), and cast-conditioned scene frames (pipeline 1/2/3).
  Delivers the headline: type a brief → editable board of on-brand frames with consistent
  subjects.
- **Phase 2 — Clips.** Animate each approved frame (pipeline 4). Reuses the KV Motion path.
- **Phase 3 — Stitch.** Assemble ordered clips into one video (pipeline 5). Only FFmpeg
  work; ships last, blocks nothing.

## Error handling & edge cases

Reuses the KV callback failure pattern (`status=failed` + `error_message` on the row,
retryable).

- **Any generation fails** (frame/clip/stitch) → that row goes `failed`; the rest of the
  board is unaffected; the user retries just that scene. No all-or-nothing.
- **Deleting a cast member** used by scenes → `scene_cast` rows cascade off, but
  already-generated frames keep their `cast_refs_used` snapshot and their `image_url` stays
  valid (history is not rewritten).
- **Stitch requires every included scene to have a `clip_ready` clip** → render is blocked
  with a clear "scenes N, M have no clip" message, or the user explicitly excludes them.
- **Model / rate-limit errors** → surface `retry_after_seconds` (already returned by
  `generate_video`) as a retry hint.
- **Per-scene duration / ratio** validated against the chosen video model's capabilities
  upstream, same as KV Motion.
- **Callbacks idempotent** on `generation_id` + internal token.

## Cost & non-functional

- **Cost can balloon** — a full storyboard is many image + video generations. Two guardrails
  are baked into the design: (1) **decompose produces text only** — no frame/clip render
  until the user confirms; (2) **generation is explicit per scene** (or an explicit
  "generate all frames" with a cost-count confirmation) — never silent auto-render.
- **Credit metering** reuses `KvCreditMeteringService` with new cost-type keys (following
  the `kv_motion_generation` naming):
  - `storyboard_frame_generation` — scene frame image (pipeline 3)
  - `storyboard_cast_generation` — generate-and-lock cast reference image (pipeline 2)
  - `storyboard_clip_generation` — scene clip video (pipeline 4)
  - **Stitch (pipeline 5) is not metered in v1** — FFmpeg compute only, no model cost.
    (Revisit if compute cost proves material.)
- **Feature flag** (PostHog) gates the whole tool, web + api.
- Generations are **async background jobs**; the board reflects per-scene status.

## Testing

Respecting this repo's known constraints:

- **api** → **Unit tests** for models/services/callbacks. The Feature suite is known-broken
  on a fresh migrate here (workspaces backfill + new SoftDeletes), and DB isolation in
  `phpunit.xml` / `tests/Pest.php` **must be verified before running any Feature tests**
  (a previously-commented SQLite override once wiped the dev DB). v1 verifies via Unit tests.
- **ai-service** → pytest for the storyboard agent (decompose schema, frame/clip contracts,
  stitch util), mirroring `tests/agents/kv_motion/`.
- **web** → `bun test` (jest-dom preloaded via bunfig); the real gate is `bun run build`.

## Out of scope (v1)

- Brand-level / reusable cast library across storyboards (v1 is storyboard-scoped).
- Text-to-video from scratch (v1 is always frame-first).
- Advanced timeline editing (per-frame trims, audio mixing, overlays beyond stitch transitions).
- **Video-model stitching** (see Future enhancements).

## Future enhancements (noted, not in v1)

- **Generative-bridge transitions (video-model stitch).** Keep the per-scene clips as
  designed, but between clip A and clip B generate a short bridge clip via image-to-video
  with `first_frame = A's last frame` and `last_frame = B's first frame` (already supported
  by Veo / Kling / Seedance; no bridge for Sora, which lacks last-frame). Then concatenate
  clips + generated bridges. Adds as an **opt-in transition type** at render time, alongside
  cut / cross-fade — the video model is used *for the transitions* without discarding the
  approved clips. Cost/latency is the tradeoff (extra video generations per transition).
- **Native multi-scene generation.** Kling omni's `multi_scene_prompt` can produce one
  continuous multi-shot video in a single call. Deliberately **not** pursued: it discards
  the per-scene clips, breaks per-scene review/regenerate and the model picker, and hits
  duration ceilings — effectively a different product (prompt-to-film) than v1's per-scene,
  reviewable pipeline. Recorded only so the option is not re-litigated from scratch.

## Resolved decisions

- **Credit cost-type keys:** `storyboard_frame_generation`, `storyboard_cast_generation`,
  `storyboard_clip_generation`. Stitch is **not** metered in v1 (FFmpeg compute only).
- **Decompose transport:** synchronous **streaming (SSE)**, persist-on-confirm via CRUD —
  not the async-job+callback pattern used by the render steps.
- **Stitch transitions:** **hard cut (default)** + **cross-fade**, selected at render time.
