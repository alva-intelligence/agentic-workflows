---
title: KV Resize — Manual Cancel for In-Flight Exports
slug: kv-resize-cancel
author: daffa
created: 2026-06-23
status: draft
services: [api, web]
---

# KV Resize — Manual Cancel for In-Flight Exports

## Problem

When a KV resize export hangs (observed >30 min with no error), the user is
trapped: the row spins on "Resizing…" with no way to stop, exit, or restart.
Existing error states only cover standard timeouts/failures; the silent-hang
root cause is being fixed separately. Impatient users need a manual way out.

## Goal (DOD)

- **Cancel UI:** a stop/cancel icon is visible next to any active "Resizing…"
  row.
- **Manual abort:** clicking it immediately halts the frontend loading state and
  the backend stops accounting for that export (result discarded, no credits).

## Decisions (from brainstorming)

1. **Logical cancel**, not a true mid-call process kill. The user is freed
   instantly and no credits are charged; the in-flight model call may still
   finish in the background but its result is discarded. The ai-service
   `FastAPI BackgroundTask` model is left untouched.
2. **Scope: resize exports only.** Tile upscales (identical architecture) are
   out of scope for now.
3. **Post-cancel state: back to idle / re-selectable.** To restart, the user
   re-checks the platform and hits "Start Resizing" again.
4. **Implementation: reuse the existing hard-delete path** rather than adding a
   new `cancelled` status. The codebase already supports everything we need.

## Architecture today (relevant)

```
web (TanStack poll + SSE)
  → POST  /api/v1/studio/files/{file}/resize-exports        (create, status=pending)
  → GET   …/resize-exports/stream                            (SSE: export.updated)
  → DELETE …/resize-exports/{export}                         (hard-delete; frees re-resize)
api: ProcessKvResizeExportJob (db queue)
  → markGenerating → POST {AI}/ai/kv-resize/export (202)     → returns
ai-service: BackgroundTask process_resize_export(...)
  → model call (gpt-image-2 / Replicate)
  → POST /api/v1/internal/kv-resize-exports/completed        (markDone/markFailed + credit charge)
```

Three properties of the existing code make cancel almost free:

- `KvResizeExportController::destroy` **hard-deletes** the row specifically so the
  platform can be re-resized (`firstOrCreate` in `createBatch` would otherwise
  return a stale row without dispatching). Comment at
  `KvResizeExportController.php:181`.
- `KvResizeExportInternalController::completed` **ignores any row whose status is
  not `pending`/`generating`** and only charges credits inside the `done` branch
  (`KvResizeExportInternalController.php:27`). A row that no longer exists never
  reaches the charge.
- `ProcessKvResizeExportJob::handle` **early-returns when the row is gone**
  (`ProcessKvResizeExportJob.php:32`).

## Solution

Cancel is **"remove, exposed on an in-flight row"**:

```
User clicks ⨯ on a "Resizing…" row
  → web: optimistic → row dropped from cache → platform instantly idle & re-resizable
  → DELETE …/resize-exports/{export}   (hard-delete)
  → the still-running ai-service task later POSTs "completed":
       row no longer exists → callback no-ops → result discarded, NO credits charged
```

No new status, route, service method, job guard, or `createBatch` change.

### api/ changes (one defensive guard)

- `app/Http/Controllers/Api/Internal/KvResizeExportInternalController.php`
  - Change `KvResizeExport::with('file')->findOrFail($id)` to `find($id)` and,
    when the row is `null` (cancelled = hard-deleted mid-flight), return
    `200 {ok:true, ignored:true}` instead of throwing a 404. This makes the late
    completion callback for a cancelled export a clean no-op rather than a logged
    `ModelNotFoundException`. Credits are already untouched (charge lives in the
    `done` branch, which we never reach without a row).

### web/ changes

- `src/lib/analytics/kv-generator-events.ts`
  - Add `KvResizeCancelledProps { export_id; platform_id; parent_generation_id }`
    and `trackKvResizeCancelled` → `safeCapture("kv_generator.resize_cancelled", p)`.
- `src/lib/studio/kv/useResizeExports.ts`
  - Add a `cancel` mutation: `mutationFn` calls the existing
    `deleteResizeExport(fileId, exportId)`; `onSuccess` filters the row out of the
    cache (identical to `remove.onSuccess`). It exists as a distinct mutation
    (not a reuse of `remove`) so the call site can fire `trackKvResizeCancelled`
    with the platform/generation context.
- `src/components/studio/kv-generator/KvResizePanel.tsx`
  - Add `onCancel?: (platformId: PlatformId) => void` to `Props` and thread it
    through `Group` → `PlatformRow`.
  - In `PlatformRow`, when `state === "in-progress" && onCancel`, render a
    trailing stop/cancel icon button (`X`, matching the Done-state remove button)
    — **always visible** (not hover-gated), `aria-label="Cancel {label} resize"`,
    `onClick` calls `e.stopPropagation()` then `onCancel()`.
- `src/components/studio/kv-generator/KvGeneratorLayout.tsx`
  - Destructure `cancel: cancelResize` from `useResizeExports`.
  - Add `handleCancelResize(platformId)`: resolve the export via
    `exportsByPlatformId`; if it is the armed regenerate target, `disarmRegenerate()`;
    call `cancelResize.mutate(ex.id)`; fire `trackKvResizeCancelled`.
  - Pass `onCancel={handleCancelResize}` to `<KvResizePanel>`.

## Edge cases

- **Cancel races with completion.** If the result lands first, the row is already
  `done` and the user sees the finished tile (cancel button is gone). If cancel
  lands first, the row is deleted and the late callback no-ops.
- **Cancel before ai-service POST.** The job's existing `find()` null-guard
  returns early — no model call at all.
- **Cancel after `markGenerating` but before delete.** `markGenerating` runs an
  UPDATE that affects 0 rows after deletion — harmless; the late callback still
  no-ops.
- **Credits.** Never charged for a cancelled export — the charge is inside the
  `done` branch, unreachable without a row.
- **Re-resize after cancel.** `createBatch`/`firstOrCreate` creates a brand-new
  row (the old one was hard-deleted) and dispatches a fresh job. No change needed.
- **Orphaned S3 image.** If the cancelled task still completes, its PNG is
  uploaded but unreferenced. Acceptable (same as today's discard-on-remove).

## Testing

- **api/** — the change is a 2-line defensive guard. Verify manually (the Feature
  suite is blocked on fresh-migrate per repo history, and migrating risks the dev
  DB): with the API running, POST to
  `/api/v1/internal/kv-resize-exports/completed` (with the `X-Internal-Token`)
  using a non-existent `export_id` and a `done` payload → expect
  `200 {ok:true, ignored:true}` (previously `404`). No `cost_histories` row is
  written.
- **web/** — no test framework in this repo; verify via `bun lint` + `bun run
  build` (type-check) and manual preview:
  - The stop/cancel icon is visible on every in-progress ("Resizing…") row and
    only on those rows.
  - Clicking it removes the loading state immediately and the platform becomes
    re-selectable (checkbox returns).
  - Re-selecting + "Start Resizing" starts a fresh resize.
  - `kv_generator.resize_cancelled` appears in PostHog Live Events with
    `export_id` / `platform_id` / `parent_generation_id` plus base context.

## Out of scope

- Tile upscales.
- The silent-hang / no-error root cause (fixed separately).
- True mid-call kill of the OpenAI/Replicate request.
- A server-side cancellation audit trail / dedicated `cancelled` status.
- Feature flag (additive safety affordance; ship unflagged unless requested).
