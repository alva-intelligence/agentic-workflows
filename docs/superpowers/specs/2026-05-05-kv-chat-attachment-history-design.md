---
title: KV Chat — Persisted Attachment + Selection History
slug: kv-chat-attachment-history
author: daffa
created: 2026-05-05
status: draft
services: [web, api, ai-service]
---

## Overview

Make two pieces of per-turn user input in the KV Generator chat **persist on the message** and **render in the thread history**:

1. **Paperclip attachments** — external images the user uploaded as context (`KvAttachment`).
2. **Bounding-box selections** — regions the user drew on the current generation to scope an edit (`KvBoundingBox`), shown today as the "2 selections" chip above the input.

Both are session-only today: they sit in the input row, ride the stream POST as transient payload, and vanish after send — even the same-session bubble only shows the typed text. After refresh, a user looking at their own thread cannot tell *what* they uploaded or *where* they edited.

This spec turns both into first-class content on user messages, stored once per row (reusing `UserChatHistory.files` for attachments, extending the `message` JSONB blob for selections), surfaced by the KV file-show endpoint, hydrated by the web stream hook, and rendered above the user-message bubble in `KvChat` — attachments as a thumbnail strip, selections as a mini annotated thumbnail of the base generation with the bbox rectangles overlaid.

Out of scope: multi-file attachments per message beyond what the input already accepts; non-image MIME types (v1 stays images-only, matching `KvAttachment.mime_type` validation today); reply/quote of an attachment or selection; lightbox / fullscreen viewer; hovering a selection thumbnail to flash the boxes on the canvas.

## Why now

Both the thumbnail strip (for files) and the inline edit-region preview (for selections) are "table stakes" for any chat app that accepts richer-than-text input. Today:
- A user attaches an image → AI responds about it → user has zero visible record of *what* they uploaded. Refresh = even input-row blob URL is dead.
- A user draws "edit this nose region" → AI returns a new version → user looking at the thread sees only the new version + their text prompt; the *where* is gone. They can't tell at a glance which version was the edit's parent or what region they constrained.

Both are the same shape of bug: per-turn intent that informed the AI is invisible to the user after the turn. Persisting + rendering both fixes a coherent feature, not just a file-attachment leak.

## Current state (as of 2026-05-05)

**Web** — `frndos/web` on branch `develop`:
- `KvAttachment` ([studio.ts:273](web/src/types/studio.ts:273)) holds blob URL + base64 + raw `File` in component state on `KvGeneratorLayout`.
- Send flow: `useKvStream.ts` line 716 inserts the optimistic user message as `{ id, role: 'user', text }` only. Line 781 sends `attachments: [{ id, name, mime_type, data_base64 }]` in the JSON stream POST. Line 913 in `KvChat.tsx` clears attachments after send.
- Render: `KvChat.tsx` line 444 renders only `{m.text}` for user messages.
- Hydrate: `hydrateInitialMessages` (`useKvStream.ts:161`) inflates user rows as `{ id, role, text }` — no attachments.

**API** — `frndos/api` on branch `feature/daffa/vc-studio-projects-kv-generator`:
- KV chat hits `/v1/threads/{thread}/stream` → askFrnd `ThreadController::update`.
- `UserChatHistory.files` is a JSONB column already cast to `array` ([UserChatHistory.php:42-58](api/app/Models/UserChatHistory.php)).
- `ThreadController::update` populates `files` via `$categorizedFiles->getAllFiles()` (multipart upload path) but the JSON `attachments` field the KV web sends is silently ignored on persist (and likely on AI forward too — verification task in the api plan).
- The stream POST does accept `bounding_boxes` + `base_generation_id` and forwards them to the AI — but neither lands on the persisted `UserChatHistory` row, so they vanish from history. Today the `message` JSONB blob is stored as `{ content, type }` only.
- `KvGeneratorFileController::show` rebuilds `chat_history` for the panel ([line 76-170](api/app/Http/Controllers/Api/Studio/KvGeneratorFileController.php)) and includes `tools` on assistant rows, but emits **no attachments and no selections** on user rows.

**AI service** — `frndos/ai-service` on branch matching the api:
- `chat_agent/service.py` has the `process_message_with_files` machinery for askFrnd attachments. Whether the KV path threads attachments through (since the api doesn't store them), we need to verify in the api plan first — and only update ai-service if the inputs change shape.

## Wire shape

### Persisted shape (`UserChatHistory.files`)

Reuse the existing askFrnd shape — one row per attached image:

```json
[
  {
    "id": "att_01HXY...",
    "name": "moodboard.png",
    "mime_type": "image/png",
    "size": 234567,
    "url": "https://cdn.frnd.com/studio/chat-attachments/01HXY.../moodboard.png",
    "thumbnail_url": null
  }
]
```

`thumbnail_url` is reserved (null in v1). Frontend uses `url` for the thumb tile too — at the rendered size (~80×80) downscale cost is negligible and S3 origin can serve cached.

### Stream POST request body addition

Replace today's transient `attachments: [{..., data_base64}]` with persisted refs:

```json
{
  "message": "...",
  "mode": "image",
  ...
  "attachments": [
    { "id": "att_01HXY...", "url": "https://cdn.../moodboard.png", "name": "moodboard.png", "mime_type": "image/png", "size": 234567 }
  ]
}
```

The base64 path goes away. Client uploads images **first** to a new endpoint, gets back the persisted descriptors, then sends them in the stream POST body. Two reasons:
1. The api needs the URL to store on `UserChatHistory.files` — no point re-uploading per turn.
2. Base64-in-JSON for ~5MB images is ugly and clogs the SSE buffer.

### New upload endpoint

```
POST /v1/studio/chat-attachments
Content-Type: multipart/form-data
Body: files[]=@path/to/image.png  (1..N images)
Auth: Sanctum (workspace-scoped)

200 OK
{
  "data": [
    {
      "id": "att_01HXY...",
      "name": "moodboard.png",
      "mime_type": "image/png",
      "size": 234567,
      "url": "https://cdn.../studio/chat-attachments/01HXY.../moodboard.png"
    }
  ]
}
```

- Stored under `studio/chat-attachments/{att_id}/{original_name}` on the existing `s3` disk.
- Validates: image MIME (`image/png|jpeg|jpg|webp`), max 10 MB per file, max 4 files per request (matches current input UX limits).
- Returns the same shape that gets persisted on the message — so the client can store the descriptor and forward it unchanged in the stream POST.
- No DB row needed for the attachment itself in v1; the `id` is generated server-side as a ULID just for client-side keying. Persistence happens when the stream POST commits the user message.

### Selection persistence (bounding boxes)

Selections live on the `message` JSONB blob (extending the existing `{content, type}` shape). No new column, no migration:

```json
"message": {
  "content": "make this region younger",
  "type": "human",
  "selections": [
    { "id": "b_01HXY", "x": 0.31, "y": 0.42, "width": 0.18, "height": 0.22, "prompt": "younger face" }
  ],
  "base_generation_id": "g_01HW..."
}
```

`base_generation_id` is what the FE needs to render the mini preview — the bbox rectangles only make sense overlaid on the parent generation. `selections` is omitted (not `[]`) for non-edit turns, so existing rows stay byte-identical.

### Stream POST request body change

The stream POST already accepts `bounding_boxes` + `base_generation_id`. The api change is purely to **persist** them onto `message`. No wire-shape change for selections.

The wire change is only on the attachments side: replace `attachments: [{..., data_base64}]` with `attachments: [{id, url, name, mime_type, size}]` (post-upload refs).

### Hydrated chat-history shape

`KvGeneratorFileController::show`'s `chat_history` array gains two new fields on user rows:

```json
{
  "id": "01HX...",
  "role": "user",
  "text": "make this region younger",
  "attachments": [
    { "id": "att_...", "name": "moodboard.png", "mime_type": "image/png", "size": 234567, "url": "..." }
  ],
  "selections": {
    "base_generation_id": "g_01HW...",
    "boxes": [
      { "id": "b_01HXY", "x": 0.31, "y": 0.42, "width": 0.18, "height": 0.22, "prompt": "younger face" }
    ]
  }
}
```

Both fields are absent (or empty) when not used. The base generation's `image_url` is already in the `generations` array of the same response, so the FE joins by `base_generation_id` to render the mini preview — no extra API round-trip.

## UX

**Send time**
The optimistic user message renders the full new bubble shape immediately: selection preview (if any) at the top, attachment thumbnail strip below it, text bubble at the bottom — all right-aligned. Both attachments and selections stay on the message after `onClearAttachments?.()` / bbox-clear runs on the input — they're now part of the persisted message, not transient input state.

**Attachment render**
- 1 thumbnail: 96×96 rounded tile, shown above the bubble.
- 2-4 thumbnails: row of 64×64 tiles, gap 8px, wraps if needed.
- Right-aligned to match the user-bubble alignment.
- Click a tile → opens the asset URL in a new tab (v1 lightbox-free; viewer is a follow-up).
- Each tile shows the filename below in tiny text (truncated to ~12 chars).

**Selection render**
- A single 144×144 (max — clamps to keep aspect) rounded tile that shows the **base generation thumbnail** with the bbox rectangles overlaid as 1.5px dashed strokes in the same blue (`#4D8EFF`) used on the canvas.
- A small badge in the bottom-right of the tile shows the count: `2` / `3`.
- Each box's optional `prompt` is *not* rendered on the tile (would crowd it); accumulating prompts go into the text bubble below if the user typed one.
- Right-aligned, sits *above* any attachment strip, *below* nothing (top of the bubble stack).
- If `base_generation_id` doesn't match any loaded generation (deleted version, or not yet hydrated): render a neutral grey tile with just the bbox outlines + "Edited region" label. Don't crash, don't omit — the user still drew it.
- Click → no-op in v1 (focus follows in a later iteration that scrolls the canvas to the matching generation).

**Refresh**
Same render. The bubble looks identical to a freshly-sent one because both code paths feed the same `m.attachments` and `m.selections` fields on `ChatStreamMessage`.

## Data model decisions & tradeoffs

| Decision | Choice | Why |
|---|---|---|
| Attachment storage | Reuse `UserChatHistory.files` | Column exists, askFrnd uses the same shape, zero new tables. |
| Selection storage | Extend `message` JSONB blob with `selections` + `base_generation_id` | No migration; keeps user-turn metadata together; assistant rows unaffected. |
| Asset storage | S3 under `studio/chat-attachments/{id}/{name}` | Mirrors existing studio asset paths (`s3` disk, `Storage::url`). |
| Upload protocol | Pre-upload + stream-POST refs | Avoids base64 in JSON, keeps stream POST small, gives backend the URL to persist. |
| Attachment IDs | ULID generated by API on upload | Sortable, no DB lookups needed for keying client-side. |
| Selection mini-preview source | Existing `generations[]` in the file-show response, joined by `base_generation_id` | No extra round-trip; FE already has the URLs. |
| Cleanup | None in v1 | Orphaned uploads (user picked then never sent) are an accepted leak; size-cap them with the per-file limit and revisit if it becomes material. |
| Thumbnail | Same URL as full-size | At 64-144px the bandwidth cost is negligible and S3+CDN handles it. Add real thumbnails later if needed. |

## Validation rules

- MIME: `image/png`, `image/jpeg`, `image/jpg`, `image/webp` (mirrors KvChat input filter).
- Size: 10 MB per file, 4 files per upload request.
- Auth: same workspace scope as `studio/*` routes — Sanctum + `current_workspace_id`.
- The stream POST validates that each `attachments[].url` is on our `s3` host (defense against URL injection).

## Files touched

**web** (`frndos/web`):
- `src/types/studio.ts` — extend `KvAttachment` with `url?` + persisted `id`; add `KvHistoryAttachment` and `KvHistorySelections` types.
- `src/hooks/useKvStream.ts` — change `attachments` payload shape (URL refs not base64); attach attachments + selections to optimistic user message; lift both from history hydration.
- `src/components/studio/kv-generator/KvChat.tsx` — render attachment thumbnail strip + selection mini-preview tile on user message; new upload-first send flow.
- `src/components/studio/kv-generator/KvGeneratorLayout.tsx` — wire upload endpoint; pass `selections` snapshot through to the optimistic insert at send time.
- `src/components/studio/kv-generator/SelectionPreviewTile.tsx` (new) — small canvas/svg that draws bbox rectangles overlaid on a base-generation image; clamps to 144px max edge while preserving aspect.

**api** (`frndos/api`):
- `app/Http/Controllers/Api/Studio/StudioChatAttachmentController.php` — new, `store()` for upload.
- `app/Http/Requests/Studio/UploadStudioChatAttachmentRequest.php` — validation.
- `app/Http/Controllers/Api/Chat/ThreadController.php` — accept `attachments` JSON refs in stream POST body and persist on `$messageData['files']`; persist `bounding_boxes` + `base_generation_id` into `$messageData['message']['selections']` + `['base_generation_id']`. (Discovery task: confirm whether to scope the change to studio threads via `thread_type` guard or apply unconditionally.)
- `app/Http/Controllers/Api/Studio/KvGeneratorFileController.php` — include `attachments` AND `selections` on user `chat_history` entries.
- `routes/api.php` — register `POST /v1/studio/chat-attachments`.
- Tests: feature tests for upload + attachment persistence + selection persistence + hydration.

**ai-service** (`frndos/ai-service`):
- Discovery first: confirm the KV chat agent already receives image attachments via `chat_agent/service.py` (it does for askFrnd; the question is whether the KV stream invocation forwards them). Bounding boxes are already part of the AI input today (the edit pipeline reads them) so no change there. If attachments aren't forwarded today, mirror the askFrnd `process_message_with_files` integration.

## Migration / rollout

- No DB migrations needed (column already exists).
- Backward compatibility: old user messages with no `files` row keep rendering as bare text bubbles (the render branch noops on empty/missing `attachments`).
- Feature is silent for users who never attach — no behavioral change for them.

## Risks

1. **Stream POST shape change is breaking client/server contract.** Ship api change before web; web feature-flags (or just lands after) so a `data_base64` payload still works during the brief overlap window. Or — since we control both — ship together in coordinated PRs.
2. **Orphan uploads.** A user who picks an image then never sends accumulates dead S3 objects. Acceptable in v1; add a janitor cron later if it grows.
3. **AI service may rely on inline base64.** If the existing KV path actually does forward base64 to the agent, switching to URL refs needs the agent to fetch the URL itself (or the api to fetch and re-encode before forwarding). Discovery task in the api plan covers this.

## Open questions for review

- Should the upload endpoint live under `studio/` or under a more generic `chat-attachments/`? Recommend `studio/` to match the existing namespace and route group middleware.
- Should we expire orphan uploads after N days? Defer — out of scope for v1.
- Lightbox/fullscreen viewer on tile click? Defer — open-in-new-tab is fine for v1.
