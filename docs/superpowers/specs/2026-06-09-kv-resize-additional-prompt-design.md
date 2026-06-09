---
title: KV Resize — Additional Prompt + Guided Regenerate
date: 2026-06-09
author: daffa
status: design
scope: scene/outpaint-only (iteration 1)
services: [web, api, ai-service]
---

# KV Resize — Additional Prompt + Guided Regenerate

## Problem

Today users have zero control over how a Key Visual (KV) gets resized — the
engine guesses their intent. This is worst with **Regenerate**, which behaves
like a blind retry: if version 1 is bad, clicking regenerate gives the AI no
information about *why* it was bad or *what* to fix, so it may repeat the same
wrong approach.

## Solution (one sentence)

Add an **optional free-text prompt** to both the New Resize flow and the
Regenerate flow so the user can steer the AI outpainting (e.g. "keep the text at
the very bottom", "make the background calmer"), and log every resize/regenerate
action as a persistent marker in the side chat panel.

## Scope — Iteration 1 (locked)

**Scene / outpaint-only.** The additional prompt guides the generated
background/scene and (where the auto-picked strategy allows) text. **The brand
logo stays deterministic** — `stamp_logo` is not touched, so prompts that ask to
move/resize the logo are explicitly out of scope this iteration. This keeps
logo placement decoupled and predictable (see
`[[project_kv_logo_bake_decoupled_brand_knowledge]]`).

Out of scope for iteration 1:
- Logo repositioning/resizing via prompt (deterministic stamp only).
- Per-region (bounding-box) regenerate inside a single tile.
- Crop-window adjustment UX (does not exist today — see note below).
- Iterative refine on top of the previous tile output.

---

## Background — Current Implementation (verified)

### Resize / Regenerate (web)
- Platform picker + "Start Resizing": `web/src/components/studio/kv-generator/KvResizePanel.tsx`
  (button ~L114, calls `onResize()`). Selection state in
  `web/src/store/kv/useKvResizeStore.ts` (`selectedPlatformIds: Set`).
- Per-tile Regenerate button (icon ⟳): `web/src/components/studio/kv-generator/KvResizeResultRow.tsx`
  (~L122, prop `onAdjustCrop`, `aria-label="Regenerate"`).
- Wiring: `web/src/components/studio/kv-generator/KvResizeCanvas.tsx` —
  `onAdjustCrop={() => regenerateExport(row.id)}` (~L387) →
  `regenerate.mutate({ exportId })`. **No crop window is ever sent.** The file
  comment (L52-53) states: *"Regenerate always goes through the AI path with the
  full source — no crop selection UX."*
- Mutation: `web/src/lib/studio/kv/useResizeExports.ts` (~L99) →
  `regenerateResizeExport(fileId, exportId, cropWindow)` in
  `web/src/services/kv/api.ts` (~L592). `cropWindow` is a **dormant/dead param**
  threaded through types + API + Laravel validation + ai-service schema but never
  populated by the UI.
- Chat panel: `web/src/components/studio/kv-generator/KvChat.tsx` — `ModeButton`
  (Brainstorm/Design, ~L1386), `ModelButton` (model dropdown, ~L1475),
  `MessagesList` (~L441). Chip infra already exists: `SelectionRefNode`,
  `SelectionPill`.

### Resize / Regenerate (api)
- Routes: `api/routes/api.php` L1991-1998 →
  `POST files/{file}/resize-exports` (`store`) and
  `POST files/{file}/resize-exports/{export}/regenerate` (`regenerate`).
- Controller: `api/app/Http/Controllers/Api/Studio/KvResizeExportController.php`
  — `store()` validates `parent_generation_id`, `platform_ids`, `crop_windows`
  (no prompt). `regenerate()` validates only `crop_window` (no prompt).
- Job → ai-service: `api/app/Jobs/Studio/ProcessKvResizeExportJob.php` (~L54)
  POSTs to `/ai/kv-resize/export`. No prompt currently forwarded.
- Model `KvResizeExport`: no `version_number`; unique on
  `(parent_generation_id, platform_id)`. Regenerate reuses the row in place.
- Chat history persistence: `api/app/Models/UserChatHistory.php`
  (`session_id`, `message` JSON, `files` JSON). KvGeneration links via
  `chat_message_id`.

### Resize / Regenerate (ai-service)
- Endpoint: `ai-service/app/agents/kv_resize/router.py` —
  `POST /ai/kv-resize/export` (`ResizeExportRequest`). Resize **is** the
  regeneration; there is no separate regenerate endpoint.
- Pipeline: `ai-service/app/agents/kv_resize/service.py`
  `process_resize_export()` picks 1 of 5 strategies (ai_reframe,
  ai_restructure, fit_not_fill, subject_aware_crop, legacy_smart_crop) and
  calls `reframe()` / `outpaint()` in `ai-service/app/tools/outpaint_image.py`.
- **Both `outpaint(canvas, mask, prompt)` and `reframe(source, w, h, prompt)`
  already accept a `prompt: str`** passed straight to OpenAI `/v1/images/edits`.
- Request schema: `ai-service/app/agents/kv_resize/request_schema.py`
  `ResizeExportRequest` (no prompt field today).
- Logo: `ai-service/app/agents/kv_generator/logo_stamp.py` `stamp_logo()` runs
  **after** outpainting, composited deterministically from a persisted
  `BrandLogoStamp` (anchor + scale). Prompt cannot move it.

---

## Architecture / UX

### A. New Resize flow
1. User checks platforms in `KvResizePanel`. An optional `<textarea>` appears
   directly above "Start Resizing" — placeholder *"Any specific instructions?
   (Optional)"*.
2. A **single** prompt applies to **all** platforms checked in that batch.
3. On "Start Resizing": the prompt is sent with the batch, and a **system
   marker** is written to chat:
   *"Resizing original KV to [Instagram Post, Facebook Cover] with instructions:
   'keep the text at the very bottom'."* (No-prompt variant drops the
   "with instructions" clause.)
4. The resize prompt input clears after submit.

### B. Regenerate flow (per-tile ⟳)
1. Clicking ⟳ on a tile **arms** regenerate mode (does NOT fire immediately):
   - Canvas focuses strictly on that tile.
   - A **locked** chip appears in the chat input: *"Instagram Post · 1080×1080"*
     plus a small thumbnail of the tile. The chip is not removable — it marks
     the active regenerate target.
2. In resize-mode the chat input is stripped:
   - **Brainstorm / Design mode toggles are hidden.**
   - **Model dropdown is locked/disabled** (always the resize engine; static
     label shown).
3. User types an optional prompt → **Send** → calls the `regenerate` REST
   endpoint **directly** with `additional_prompt` (NOT an Agno agent turn). The
   target tile is overwritten in place.
4. A **system marker** is written to chat:
   *"Regenerated Instagram Post with: 'make the background calmer'."*
   (No-prompt variant: *"Regenerated Instagram Post"*.)
5. Exiting armed mode without regenerating: click ⟳ again (toggle off) or a small
   ✕ on the armed-state indicator.

**Architecture note.** In resize-mode the chat box is a *prompt-capture UI that
fires a REST endpoint directly*, not an agent turn. This is what makes the
"Direct Regenerate (No Modes)" rule work without wiring resize into the Agno
chat agent. The rejected alternative — routing through the chat agent and
exposing resize as an Agno tool — is heavier and unnecessary for this feature.

### C. Per-service changes

**web**
- `KvResizePanel`: optional `<textarea>`; `resizePrompt` state in
  `useKvResizeStore`; forward to the `createResize` mutation.
- `KvResizeResultRow` / `KvResizeCanvas`: ⟳ no longer fires directly —
  `onArmRegenerate(exportId)`.
- New `armedRegenerate: exportId | null` state (layout/store) driving canvas
  focus, the locked chip, and mode/model lock.
- `KvChat`: in resize-mode hide `ModeButton`, disable `ModelButton`; when armed,
  `onSend` calls the regenerate mutation (with `additional_prompt`) instead of
  the stream.
- New **system/marker** message variant rendered in `MessagesList`.

**api**
- Migration: add `additional_prompt` (nullable string, max 1000) to
  `kv_resize_exports`.
- `store()` and `regenerate()`: accept + persist `additional_prompt`; forward it
  to ai-service via `ProcessKvResizeExportJob`.
- Helper to write a `UserChatHistory` system message for New Resize and
  Regenerate (`session_id = file thread_id`) with metadata (platforms, prompt,
  export ids) so the marker renders and **survives reload**.

**ai-service**
- `ResizeExportRequest`: add `additional_prompt: Optional[str] = None`.
- `service.py`: merge `additional_prompt` into the guidance string before
  `outpaint()` / `reframe()` / restructure (e.g. append
  `f"\n\nUser instructions: {additional_prompt}"`). `null` → unchanged legacy
  behavior. `stamp_logo` untouched.

### D. Versioning ("how version will treat?")
- **Regenerate = overwrite the `KvResizeExport` row in place** (already current
  behavior) → **no new version stack**. Matches DoD.
- **New Resize** = a new row per platform (existing unique constraint). The
  `KvGeneration` version stack (sketch/craft) is untouched.

### E. Edge cases
- Send with empty prompt while armed = plain retry (`additional_prompt = null`).
- Resize prompt clears each submit; regenerate prompt is per-action (not
  auto-carried to the next regenerate).
- Prompt length cap ~1000 chars.
- Model in resize-mode is always the resize engine (gpt-image-2); the dropdown
  is disabled and shows a static label.
- **"Component reflow" via prompt is partial by design**: text only shifts when
  the auto-picked strategy is `ai_restructure`; the logo never moves (scene-only
  scope).

---

## Testing
- **ai-service** (unit): `additional_prompt` is merged into the outpaint/reframe
  guidance string; `null` reproduces legacy behavior; `stamp_logo` unaffected.
- **api** (unit/feature): validation accepts + persists `additional_prompt`; the
  job payload to ai-service includes it; the system message row is written.
  Prefer Unit-style coverage where the Feature suite is blocked on fresh migrate
  (see `[[lesson_api_feature_suite_blocked_softdeletes]]`); verify
  `[[lesson_test_db_isolation]]` before running Feature tests.
- **web**: armed regenerate → Send calls the mutation with the prompt; mode
  toggles hidden and model locked in resize-mode; New Resize forwards the batch
  prompt and renders the marker.

## Open questions
None blocking. Logo-reposition-via-prompt and per-region regenerate are
deferred to a future iteration by explicit scope decision.
