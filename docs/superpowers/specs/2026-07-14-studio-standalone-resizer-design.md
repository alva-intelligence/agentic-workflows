---
title: Studio — Standalone Resizer Tool
slug: studio-standalone-resizer
author: daffa
created: 2026-07-14
status: draft
services: [web, api]
parent: studio-kv-resize
---

## Overview

Turn **Resizer** into a first-class, standalone Studio tool. Today "Resize" is
only reachable as the third canvas tab inside the KV Generator, and its source
is locked to the *latest KV generation* of an open KV file — so a user cannot
resize anything without first generating or crafting a KV.

This design makes Resizer usable on its own: the user opens the Resizer tool,
sees a **My Resize Files** list, starts a **New Resize**, **uploads a source
image**, picks target platforms, and gets one export per platform — with no KV
generation involved. Under the hood it reuses the entire proven `kv_resize`
pipeline (Approach A below), so the backend barely moves and every existing
resize enhancement (additional-prompt, cancel, subject-aware crop, tile-upscale)
comes along for free.

The **Resizer tile already exists** in the Studio tool registry
(`StudioDevelopmentSeeder.php`: `slug=resizer`, `status=live`,
`href=/studio/resizer`) but is force-disabled in the web via
`COMING_SOON_OVERRIDE_SLUGS = ["image-editor", "resizer"]`, and no
`/studio/resizer` page exists yet. This design builds that tool out.

## Why

- Resize's user intent — "give me deliverables for these channels, don't change
  the design" — is independent of KV generation. Requiring a KV first is an
  artificial gate for a user who already has a finished asset.
- The resize-export pipeline is *already file-generic* — its public routes are
  `studio/files/{file}/resize-exports` (not KV-scoped). The only KV coupling is
  that a resize batch needs a `parent_generation_id` (the file's latest
  `kv_generation`). Minting the uploaded image as that generation — exactly how
  Craft's upload-base entry point already works
  (`2026-06-18-kv-craft-upload-base-entry`) — unlocks standalone resize with
  almost no new backend.

## Chosen approach — reuse the pipeline via an imported source generation (Approach A)

The Resizer tool creates a `tool = resizer` `studio_file`. The uploaded image is
minted as **one** `kv_generation` tagged `imported_from_upload` (reusing the
existing `import-from-upload` machinery). `kv_resize_exports` hang off that
generation exactly as they do for KV resize today. Because the resize-export
endpoints, `KvResizeExportService`, `ProcessKvResizeExportJob`, the ai-service
`kv_resize` agent, SSE, crop-adjust, and upscale are all already file-generic,
they work unchanged.

**Rejected alternatives:**

- **Approach B — decouple the source model** (nullable `parent_generation_id` +
  a real uploaded-source column/table; API + ai-service accept a source with no
  generation). Cleaner conceptually but adds a schema migration, branching in
  the service/controller/validation ("must be latest generation"), ai-service
  request-shape changes, and more tests — for a distinction users never see.
- **Approach C — fully separate resizer subsystem** (new tables + new ai
  route). Massive duplication of a working pipeline. Rejected as YAGNI.

**Consequence accepted:** a standalone resize source is technically a
`kv_generation` on a resizer file — a slight semantic smudge, already
precedented by Craft's uploaded bases.

## Resolved decisions

| Decision | Outcome |
|---|---|
| Source of a standalone resize | **Upload only** (JPG/PNG, ≤ 20 MB). No "pick existing asset", no artboard picker. |
| Entry point | The existing **Resizer tool tile** (un-gated), landing on a **My Resize Files** list page. |
| Canvas scope | **Resize-only** — no Sketch/Craft tabs, no chat. Upload → platform picker → stacked exports. |
| Architecture | **Approach A** — reuse the `kv_resize` pipeline via an imported source generation. |
| Download ZIP | **Yes** — bundle every completed export into one `.zip` (server-side). |
| History button | **Dropped for v1** — resize-only has no meaningful version timeline. |
| Schema changes | **None** — reuse `studio_files`, `kv_generations`, `kv_resize_exports`. |
| ai-service changes | **None**. |

## UX flow

### Screen A — My Resize Files (list)

Route: `(dashboard)/brands/[id]/studio/resizer/page.tsx`. Reuses the `all-files`
page pattern: `ModuleHubShell` + search `Input` (`MagnifyingGlass`) + a
"**+ New Resize**" `Button` + a tool-scoped file list.

- **Empty state** → `FileEmptyState`: "No resize jobs yet · Upload a master
  campaign image to adapt it to all platform sizes" + "Create your first resize
  job" CTA. (The mockup's "Show List / Show Empty State" toggle is a prototype
  demo switch only — not a real control.)
- **Populated** → `StudioAllFilesGrid` / `BaseTable` with columns: **File name**
  (thumbnail + name), **Date modified**, **Platforms** ("7 sizes"), **Last
  edited by** (`Avatar` + name), and a `…` overflow (`Dropdown`: rename /
  delete). Rows link to the job canvas.
- Data source: existing studio file listing filtered to `tool = resizer`
  (`useResizerFiles`, backed by the studio gallery/home hooks with a tool
  filter).

"**+ New Resize**" calls `createResizerFile`, then routes to the returned
`[file_id]` on its upload empty state (matches the "Untitled Resize Job" state
before any upload in the reference).

### Screen B — Resize job canvas

Route: `(canvas)/brands/[id]/studio/resizer/[file_id]/page.tsx`. Renders the new
slim `ResizerLayout`.

- **Header** (`ResizerHeader`): editable title ("Untitled Resize Job", reusing
  the KV file-title inline editor) · a "Standalone" `Label` pill · **Download
  ZIP** action (no History).
- **No source yet** → `KvUploadBaseBlock` styled as the big dropzone: "Upload
  Source Image · Click or drag file here · JPG/PNG, max 20 MB". On upload:
  measure dimensions client-side → `importResizerGenerationFromUpload` mints the
  source generation → canvas re-renders.
- **Source exists** → resize-only canvas: `KvResizePanel` (platform picker —
  Social Media / Print groups, checkboxes, `Resize · N selected` CTA) on the
  left rail + `KvResizeCanvas` (Original row on top, then a stacked result row
  per selected platform, each with Download + Adjust-crop) as the main area. No
  Sketch/Craft/Resize segmented control, no chat panel, no canvas tools cluster.

## Backend

**No schema changes.** `studio_files`, `kv_generations`, `kv_resize_exports` are
reused as-is.

### 1. Resizer file creation

`KvStudioFileService::createFile` is **not** generalized — it hardcodes a chat
`UserThread`, `ThreadType::KvGenerator`, and a kv-generator `origin_path`, none
of which a resize-only file wants. Instead:

- **`ResizerStudioFileService::createFile()`** (new, slim) — mints a
  `tool = resizer` `studio_file`, `metadata.current_mode = 'resize'`, **no
  UserThread**. Resolves the resizer `Tool` by slug; scopes to
  `(workspace, brand, project?)` like the KV service; default name "Untitled
  Resize Job" via the existing next-default-name helper pattern.
- **`ResizerFileController@store`** → `POST /v1/studio/resizer/files`. Returns a
  `StudioFileResource`.
- Web `createResizerFile` mutation.

### 2. Source upload

Reuse the existing `import-from-upload` machinery (its
`KvGenerationService::persistImportFromUpload` already sets `tool_id` from the
file, so it is tool-agnostic — no credit metering, no AI activity event):

- Add a resizer-scoped route
  `POST /v1/studio/resizer/files/{id}/generations/import-from-upload` pointing at
  the **same** `KvGeneratorFileController@importGenerationFromUpload` method (low
  blast radius — no change to the existing kv-generator route).
- Body carries `image_url`, `mime_type`, `size`, `width`, `height`
  (client-measured, server-validated), as with craft upload-base.

### 3. Resize pipeline — unchanged

`GET/POST files/{file}/resize-exports`, `…/{export}/regenerate`,
`…/{export}` (DELETE), `…/resize-exports/stream`, plus `KvResizeExportService`,
`ProcessKvResizeExportJob`, the ai-service `kv_resize` agent, SSE, crop-adjust,
and upscale are all already file-generic. The resizer file + its single imported
source generation satisfy the existing "`parent_generation_id` must belong to
the file and be the latest generation" validation with no branching.

### 4. Download ZIP (new)

- **`GET /v1/studio/files/{file}/resize-exports/download-zip`** — streams a zip
  of every `done` export for the file's latest generation. Filenames:
  `{platform-label-slug}-{w}x{h}.png` (e.g. `instagram-story-1080x1920.png`).
  Excludes `pending`/`generating`/`failed` rows. Auth via the existing
  studio-file membership check.
- **Server-side** (streamed) rather than client-side JSZip — avoids S3 CORS
  problems fetching export bytes in the browser, and keeps filenames consistent.
- New method on `KvResizeExportController` (e.g. `downloadZip`).
- Web: the Download-ZIP button is a plain download link to that URL; disabled
  until ≥ 1 export is `done`.

### 5. Analytics

Reuse the existing `kv_resize_*` studio activity actions (the shared pipeline
already emits `kv_resize_started`, `kv_resize_export_completed`,
`kv_resize_export_failed`, `kv_resize_export_regenerated`). Add:

- `resizer_file_created` — metadata: `{ file_id }`
- `resize_zip_downloaded` — metadata: `{ file_id, parent_generation_id, export_count }`

## Web

### Routes

- `(dashboard)/brands/[id]/studio/resizer/page.tsx` — My Resize Files list.
- `(canvas)/brands/[id]/studio/resizer/[file_id]/page.tsx` — job canvas.

(The two live in sibling route groups resolving to `/…/studio/resizer` and
`/…/studio/resizer/[file_id]` — same split as `all-files` (dashboard) vs
`kv-generator/[file_id]` (canvas). No path conflict.)

### Reused as-is

`KvResizePanel`, `KvResizeCanvas`, `KvResizeOriginalRow`, `KvResizeResultRow`,
`KvResizeCropModal`, `KvResizeViewport`, `KvResizeDownloadDropdown`,
`KvResizeTileStage`, `KvUploadBaseBlock`, `uploadAttachment`, `useResizeExports`,
`useKvResizeStore`, `types/kv/resize`, `cropMath`, `resize-stream`.

### New (thin)

```
src/components/studio/resizer/
  ResizerLayout.tsx        NEW  slim orchestrator: no-source -> KvUploadBaseBlock;
                                source -> KvResizePanel + KvResizeCanvas wired via
                                useResizeExports + useKvResizeStore. Composes the
                                resize-only slice WITHOUT forking KvGeneratorLayout.
  ResizerHeader.tsx        NEW  title editor + "Standalone" Label pill + Download ZIP
  ResizerFileList.tsx      NEW  reuses StudioAllFilesGrid/BaseTable + FileEmptyState,
                                tool-scoped to resizer

src/app/(dashboard)/brands/[id]/studio/resizer/
  page.tsx                 NEW  My Resize Files list page

src/app/(canvas)/brands/[id]/studio/resizer/[file_id]/
  page.tsx                 NEW  job canvas page (loads file, renders ResizerLayout)

src/services/kv/ (or src/services/resizer/)
  api.ts / mutate.ts       MOD  createResizerFile, importResizerGenerationFromUpload,
                                resizeZipUrl(fileId)

src/hooks/
  useResizerFiles.ts       NEW  list query, tool=resizer

src/lib/studioTools.ts     MOD  remove "resizer" from COMING_SOON_OVERRIDE_SLUGS
src/lib/studioRoutes.ts    MOD  resizer: (base,id) => `${base}/resizer/${id}`
```

## Edge cases

| Case | Behavior |
|---|---|
| Fresh file, no source yet | Upload empty state; Download-ZIP disabled; no platform picker. |
| Upload wrong type / too big | Rejected client-side (JPG/PNG, ≤ 20 MB) and server-validated by the import request. |
| Download ZIP with 0 `done` exports | Button disabled until ≥ 1 export is `done`; zip only ever contains `done` rows. |
| Extreme-ratio source (> 3:1) | Resize outpaints to each target normally. The `> 3:1` **gate** was Craft-only; resize has no such gate. |
| Delete a resize file from the list | Soft-delete the `studio_file` (reuse existing studio-file deletion). |
| "Untitled Resize Job" created but never uploaded | Shows as a 0-size row in the list; user can delete. Accepted tradeoff of create-on-click. |
| User wants a different source | v1: create a New Resize (no in-file source-swap — History dropped). |

## Out of scope (v1)

- Source-swap / History (drop + re-upload a new source into the same file).
- Multiple sources per resize file.
- Craft/Sketch on the uploaded source (resize-only).
- Custom platform definitions.
- Full-DPI print export (inherits resize's half-DPI preview).
- Bulk delete from the list.
- Picking an existing studio asset as the source (upload-only for v1).

Platform count reflects our real registry (~12 platforms in `config/studio.php`),
not the mockup's "31 sizes" copy.

## Testing

- **api**: feature tests for `ResizerFileController@store` (mints a
  `tool = resizer` file, no `UserThread` created), the resizer
  `import-from-upload` route (creates the source generation on a resizer file),
  and `download-zip` (streams only `done` exports, excludes
  pending/generating/failed, auth-gated, correct filenames). Reuse the existing
  DB-isolation guard (`phpunit.xml` sqlite `:memory:` + `RefreshDatabase`) before
  running any Feature test.
- **web**: component tests for `ResizerLayout` (no-source → upload block;
  source → panel + canvas), `ResizerFileList` (empty state vs rows + search
  filter), and the list page "New Resize" → route. Existing resize component
  tests unchanged.
- **ai-service**: none (pipeline unchanged).

## Trade-offs accepted

- **Source is a `kv_generation` on a resizer file** — a minor semantic smudge,
  already precedented by Craft's uploaded bases; avoids a schema migration and
  pipeline branching.
- **Create-on-click leaves empty untitled files** if the user never uploads.
  Acceptable — they show as 0-size rows and are deletable; matches the reference
  which shows an untitled job before upload.
- **Server-side ZIP** adds one endpoint but avoids S3 CORS fragility and keeps
  filenames consistent — worth it for a batch-export tool.
- **No source-swap in v1** — resize files are effectively single-source. A new
  source means a new file. Keeps the tool lean; source-versioning can come later.

## Future work

- Source-swap / History (source-versioning inside one resize file).
- Pick an existing studio asset (KV export, all-files image) as the source.
- Custom platform definitions per workspace.
- Full-DPI print export via an upscale pass.
- Promote resize outputs to editable studio files.
