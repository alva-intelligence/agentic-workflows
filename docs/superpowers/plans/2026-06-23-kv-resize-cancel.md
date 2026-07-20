# KV Resize — Manual Cancel for In-Flight Exports — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give users a visible stop/cancel control on every in-flight "Resizing…" row that instantly frees the UI and discards the backend result without charging credits.

**Architecture:** Cancel reuses the existing hard-delete path. Clicking ⨯ optimistically drops the row from the React Query cache (platform returns to idle/re-selectable) and `DELETE`s the export. The still-running ai-service task's late completion callback lands on a now-missing row and no-ops — the existing `completed` controller already only charges inside the `done` branch, so no credits are billed. The only backend change is making that callback return a clean `200 {ignored:true}` instead of a `404` when the row is gone.

**Tech Stack:** Laravel 13 / PHP (api), Next.js 16 / React 19 / TypeScript / TanStack Query v5 / Zustand (web), PostHog analytics, Phosphor icons.

**Spec:** `docs/superpowers/specs/2026-06-23-kv-resize-cancel-design.md`

**Branch:** work directly on `develop` in both `api/` and `web/` (Daffa pushes manually). Both repos are already on `develop`.

**Note on testing:** `web/` has no test framework (per `web/AGENTS.md`) — verify with `bun lint` + `bun run build` + manual preview. `api/`'s Feature suite is blocked on fresh-migrate and migrating risks the dev DB — verify the one api change manually via curl. This plan adapts the usual TDD loop accordingly.

---

### Task 1: API — no-op the completion callback for a cancelled (deleted) export

**Files:**
- Modify: `api/app/Http/Controllers/Api/Internal/KvResizeExportInternalController.php:25`

- [ ] **Step 1: Replace `findOrFail` with a `find` + null guard**

In `completed()`, change the lookup so a hard-deleted (cancelled) export makes the
late callback a clean no-op instead of a 404.

Replace:

```php
        $row = KvResizeExport::with('file')->findOrFail($validated['export_id']);

        if (! in_array($row->status, [KvResizeExportStatus::Pending, KvResizeExportStatus::Generating])) {
            return response()->json(['ok' => true, 'ignored' => true]);
        }
```

with:

```php
        $row = KvResizeExport::with('file')->find($validated['export_id']);

        // The export may have been hard-deleted by a user cancel while the
        // ai-service task was still running. A late completion callback for a
        // cancelled export is a clean no-op — discard the result, charge
        // nothing (the credit charge lives in the `done` branch below, which
        // we never reach without a row).
        if (! $row) {
            return response()->json(['ok' => true, 'ignored' => true]);
        }

        if (! in_array($row->status, [KvResizeExportStatus::Pending, KvResizeExportStatus::Generating])) {
            return response()->json(['ok' => true, 'ignored' => true]);
        }
```

- [ ] **Step 2: Lint the changed file**

Run: `cd api && ./vendor/bin/pint app/Http/Controllers/Api/Internal/KvResizeExportInternalController.php`
Expected: `PASS` (file formatted, no errors).

- [ ] **Step 3: Manually verify the callback no-ops on a missing row**

With the API + queue running, POST a `done` callback for a bogus export id
(use the real internal token from `api/.env` `INTERNAL_API_TOKEN` or the
configured header name):

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  -X POST http://localhost:9191/api/v1/internal/kv-resize-exports/completed \
  -H "Content-Type: application/json" \
  -H "X-Internal-Token: $INTERNAL_TOKEN" \
  -d '{"export_id":"00000000000000000000000000","status":"done","image_url":"https://example.com/x.png"}'
```

Expected: `200` (previously `404`). Confirm no new row appears in `cost_histories`.

- [ ] **Step 4: Commit**

```bash
cd api
git add app/Http/Controllers/Api/Internal/KvResizeExportInternalController.php
git commit -m "fix(api): no-op kv-resize completion callback when export was cancelled"
```

---

### Task 2: Web — add the `resize_cancelled` analytics wrapper

**Files:**
- Modify: `web/src/lib/analytics/kv-generator-events.ts:197`

- [ ] **Step 1: Add the typed tracker**

Immediately after the `trackKvResizeRegenerateFailed` export (currently ending at
line 197), add:

```ts
export interface KvResizeCancelledProps {
  export_id: string;
  platform_id: string;
  parent_generation_id: string;
}

export const trackKvResizeCancelled = (p: KvResizeCancelledProps) =>
  safeCapture("kv_generator.resize_cancelled", p);
```

- [ ] **Step 2: Type-check**

Run: `cd web && bunx tsc --noEmit`
Expected: no new errors referencing `kv-generator-events.ts`.

- [ ] **Step 3: Commit**

```bash
cd web
git add src/lib/analytics/kv-generator-events.ts
git commit -m "feat(web): add kv_generator.resize_cancelled analytics event"
```

---

### Task 3: Web — add a `cancel` mutation to `useResizeExports`

**Files:**
- Modify: `web/src/lib/studio/kv/useResizeExports.ts:148-156` (after `remove`) and `:196` (return)

- [ ] **Step 1: Add the `cancel` mutation**

`deleteResizeExport` is already imported. Directly after the `remove` mutation
(ends at line 156), add a sibling `cancel` mutation that deletes the export and
optimistically removes it from the cache (so the platform returns to idle and is
re-selectable). Analytics is fired at the call site (Task 5), where the
platform/generation context is available — keep this mutation pure:

```ts
  const cancel = useMutation({
    mutationFn: (exportId: string) => deleteResizeExport(fileId, exportId),
    onSuccess: (_v, exportId) => {
      qc.setQueryData<KvResizeExport[]>(
        QUERY_KEY(fileId, parentGenerationId),
        (prev) => (prev ?? []).filter((r) => r.id !== exportId),
      );
    },
  });
```

- [ ] **Step 2: Expose it from the hook**

Change the return statement (line 196) from:

```ts
  return { query, exportsByPlatformId, create, regenerate, remove, updateOverlays };
```

to:

```ts
  return { query, exportsByPlatformId, create, regenerate, remove, cancel, updateOverlays };
```

- [ ] **Step 3: Type-check**

Run: `cd web && bunx tsc --noEmit`
Expected: no new errors referencing `useResizeExports.ts`.

- [ ] **Step 4: Commit**

```bash
cd web
git add src/lib/studio/kv/useResizeExports.ts
git commit -m "feat(web): add cancel mutation to useResizeExports"
```

---

### Task 4: Web — render the stop/cancel button on in-flight rows in `KvResizePanel`

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvResizePanel.tsx` (Props, `KvResizePanel`, `Group`, `PlatformRow`)

- [ ] **Step 1: Add `onCancel` to `Props`**

In the `Props` type (after the `onRetry` prop, around line 43), add:

```ts
  /** Cancel an in-flight resize for `platformId`. Required for the
   *  in-progress-state stop button to appear. */
  onCancel?: (platformId: PlatformId) => void;
```

- [ ] **Step 2: Destructure and forward it from `KvResizePanel`**

Add `onCancel` to the `KvResizePanel` destructured params (after `onRetry`, line 70):

```ts
  onRetry,
  onCancel,
  onScrollToPlatform,
```

Then pass it to `<Group>` (inside the `.map`, after `onRetry={onRetry}` near line 114):

```tsx
            onRetry={onRetry}
            onCancel={onCancel}
            onScrollToPlatform={onScrollToPlatform}
```

- [ ] **Step 3: Thread `onCancel` through `Group`**

In the `Group` function's prop type (after `onRetry?: (id: PlatformId) => void;`, line 164) add:

```ts
  onCancel?: (id: PlatformId) => void;
```

Add `onCancel` to the `Group` destructured params (after `onRetry`, line 153):

```ts
  onRetry,
  onCancel,
  onScrollToPlatform,
```

Then pass a bound callback to `<PlatformRow>` (after `onRetry={...}`, line 195):

```tsx
                onRetry={onRetry ? () => onRetry(p.id) : undefined}
                onCancel={onCancel ? () => onCancel(p.id) : undefined}
```

- [ ] **Step 4: Accept `onCancel` in `PlatformRow`**

In the `PlatformRow` prop type (after `onRetry?: () => void;`, line 220) add:

```ts
  onCancel?: () => void;
```

Add `onCancel` to the `PlatformRow` destructured params (after `onRetry`, line 213):

```ts
  onToggle,
  onRemove,
  onRetry,
  onCancel,
  onScrollToPlatform,
```

- [ ] **Step 5: Render the always-visible stop button for in-progress rows**

`X` is already imported. Directly after the existing Done-state remove button
block (the `{state === "done" && onRemove && (…)}` block ending at line 288),
add a sibling block:

```tsx
        {state === "in-progress" && onCancel && (
          <button
            type="button"
            aria-label={`Cancel ${p.label} resize`}
            onClick={(e) => {
              e.stopPropagation();
              onCancel();
            }}
            className="shrink-0 rounded p-1 text-text-inverse-subtlest transition-colors hover:bg-[rgba(255,255,255,0.06)] hover:text-text-inverse"
          >
            <X size={14} />
          </button>
        )}
```

- [ ] **Step 6: Update the JSDoc state legend (optional but accurate)**

In the `PlatformRow`-states comment block (around line 55), change the
`in-progress` line from:

```
 *   - in-progress → spinner, disabled
```

to:

```
 *   - in-progress → spinner + stop button to cancel
```

- [ ] **Step 7: Type-check + lint**

Run: `cd web && bunx tsc --noEmit && bun lint`
Expected: no new errors referencing `KvResizePanel.tsx`.

- [ ] **Step 8: Commit**

```bash
cd web
git add src/components/studio/kv-generator/KvResizePanel.tsx
git commit -m "feat(web): show stop/cancel button on in-flight resize rows"
```

---

### Task 5: Web — wire cancel in `KvGeneratorLayout`

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx` (import:63-70, hook:305-310, handler:383, JSX:1071)

- [ ] **Step 1: Import the analytics tracker**

In the `@/lib/analytics/kv-generator-events` import block (lines 63-70), add
`trackKvResizeCancelled`:

```ts
import {
  trackKvOpened,
  trackKvOverlayAdded,
  trackKvVersionRestored,
  trackKvTemplateSaved,
  trackKvTemplateApplied,
  trackKvFileDeleted,
  trackKvResizeCancelled,
} from "@/lib/analytics/kv-generator-events";
```

- [ ] **Step 2: Destructure the `cancel` mutation from the hook**

Change the `useResizeExports` destructure (lines 305-310) from:

```ts
  const {
    create: createResize,
    regenerate: regenerateResize,
    remove: removeResize,
    exportsByPlatformId,
  } = useResizeExports(fileId, latestGenerationForResize?.id ?? null);
```

to:

```ts
  const {
    create: createResize,
    regenerate: regenerateResize,
    remove: removeResize,
    cancel: cancelResize,
    exportsByPlatformId,
  } = useResizeExports(fileId, latestGenerationForResize?.id ?? null);
```

- [ ] **Step 3: Add the `handleCancelResize` callback**

Directly after `handleRetryResize` (ends at line 383), add:

```ts
  const handleCancelResize = useCallback(
    (platformId: PlatformId) => {
      const ex = exportsByPlatformId.get(platformId);
      if (!ex) return;
      if (armedRegenerate === ex.id) disarmRegenerate();
      cancelResize.mutate(ex.id);
      trackKvResizeCancelled({
        export_id: ex.id,
        platform_id: ex.platformId,
        parent_generation_id: ex.parentGenerationId,
      });
    },
    [exportsByPlatformId, cancelResize, armedRegenerate, disarmRegenerate]
  );
```

- [ ] **Step 4: Pass `onCancel` to the panel**

In the `<KvResizePanel>` JSX, after `onRetry={handleRetryResize}` (line 1070), add:

```tsx
                      onRetry={handleRetryResize}
                      onCancel={handleCancelResize}
                      onScrollToPlatform={handleScrollToPlatform}
```

- [ ] **Step 5: Type-check + lint + build**

Run: `cd web && bunx tsc --noEmit && bun lint && bun run build`
Expected: build succeeds, no new errors referencing `KvGeneratorLayout.tsx`.

- [ ] **Step 6: Commit**

```bash
cd web
git add src/components/studio/kv-generator/KvGeneratorLayout.tsx
git commit -m "feat(web): wire cancel action into KV resize panel"
```

---

### Task 6: End-to-end manual verification

**Files:** none (verification only)

- [ ] **Step 1: Start services**

Run: `./run-all.sh` (or ensure api+queue, web, ai-service are up). Confirm health
per `CLAUDE.md` health checks.

- [ ] **Step 2: Trigger a resize and cancel it**

In the KV Generator, open a generation, switch to the Resize tab, select ≥1
platform, hit "Start Resizing". While a row shows "Resizing…":
- Confirm a stop (⨯) icon is visible on that row (and only on in-flight rows).
- Click it. Confirm the loading state clears immediately and the platform's
  checkbox returns (re-selectable).

Expected: row leaves loading instantly; platform idle.

- [ ] **Step 3: Confirm no credit charge + clean callback**

After the cancelled ai-service task would have finished (watch the queue/ai-service
logs for the `completed` POST), confirm:
- The API returns `200` for that callback (no `404` / `ModelNotFoundException` in
  api logs).
- No new `cost_histories` row for the cancelled export.

- [ ] **Step 4: Confirm re-resize works**

Re-check the same platform, hit "Start Resizing" again. Confirm a fresh resize
starts (new row, spinner) and completes normally.

- [ ] **Step 5: Confirm analytics**

In PostHog Live Events (project `FRnD_OS`), confirm `kv_generator.resize_cancelled`
fired with `export_id`, `platform_id`, `parent_generation_id`, plus the automatic
base context (`user_id`, `workspace_id`, `brand_id`, …).

- [ ] **Step 6: Add the event to the taxonomy doc**

Add a `kv_generator.resize_cancelled` row to the analytics taxonomy doc
(https://fcn.sg.larksuite.com/wiki/DMbKwqbzQiWrXSkha5zl1wFvgod) with its property
schema, per `web/AGENTS.md`.

---

## Self-Review

**Spec coverage:**
- DOD "cancel UI visible on active rows" → Task 4 (always-visible stop button on `in-progress` rows only).
- DOD "manual abort halts frontend loading immediately" → Task 3 (optimistic cache removal) + Task 5 (wiring).
- DOD "kills/halts backend accounting, no credits" → Task 1 (callback no-op) + existing `done`-branch-only charge.
- Decision "back to idle / re-selectable" → Task 3 optimistic filter + existing `createBatch` firstOrCreate (no change needed).
- Decision "ai-service untouched" → no ai-service task.
- Analytics requirement (`web/AGENTS.md`) → Task 2 wrapper + Task 5 fire + Task 6 taxonomy row.

**Placeholder scan:** none — every step has concrete code/commands.

**Type consistency:** `cancel` mutation name is consistent across Task 3 (hook return), Task 5 (`cancel: cancelResize` destructure). `onCancel` prop name consistent across Props → `Group` → `PlatformRow` (Task 4) and the layout call site (Task 5). `trackKvResizeCancelled` / `KvResizeCancelledProps` consistent between Task 2 (definition) and Task 5 (use). Props passed to `trackKvResizeCancelled` (`export_id`, `platform_id`, `parent_generation_id`) match the `KvResizeExport` fields used (`ex.id`, `ex.platformId`, `ex.parentGenerationId`).
