# KV Motion — mark ready to share without a manual export

**Date:** 2026-10-15
**Author:** Daffa Praramadhana (with Claude)
**Services:** api, web
**Status:** draft — awaiting review

## 1. Problem

> As a user, I want to mark a Motion size as ready to share right after I edit
> it. Right now "Mark ready to share" is blocked until I export that size first
> ("Export this size first"). So every time I change the design, I have to
> export the video again before the shared preview link shows the latest
> version. It slows down every revision.

Today, in the Motion editor (`KvMotionEditor.tsx`, tile chip `readyToShare`):

- A mark is a `share_ready_items` row on a `kv_motion_export` id. With no export
  row for a size, the chip toasts "Export this size first" and does nothing.
- The share link plays the **MP4** of an export. `KvSharePayloadService::resolveMotionClips`
  already follows the chain: a mark identifies a (project, size) and the guest
  gets the **newest** export of that pair. Re-exporting a marked size therefore
  already updates the link — the friction is the manual export round-trip.
- Exports are rendered **in the editor's browser** (`exportMotionRatio`,
  Mediabunny/WebCodecs) and uploaded; the export row stores no record of which
  design it rendered, so nothing can tell that an export is stale.

## 2. Decision

Keep the share link on a **rendered, frozen MP4** — the client only ever sees a
version the agency deliberately produced, and approvals keep pointing at a real
version. Remove the manual step instead:

- **Mark renders for you.** Marking a size with no up-to-date export renders and
  uploads it in the background, then marks it.
- **Outdated is visible.** A marked size whose design changed after its newest
  export shows "Outdated" with an **Update** action that re-renders it; the link
  follows the new export automatically (no re-mark).

Rejected:

- **Live render on the share page** — every half-finished edit reaches the
  client instantly, approvals lose a frozen version, the Motion engine + fonts +
  assets must be served publicly, and the guest render can drift from the
  downloadable MP4.
- **Auto re-export on every edit** — continuous GPU/encode load in the editor
  tab for marked sizes; and it publishes in-progress edits without a decision.

## 3. Behaviour

### 3.1 Tile chip states

| Size state | Chip | Click |
|---|---|---|
| Not marked; newest export is current | Mark ready to share | Mark the newest export (today's path) |
| Not marked; no export, or newest export is outdated | Mark ready to share | Background render → upload → mark |
| Render queued / running | Preparing… `NN%` (queued: "Queued") | No action |
| Marked; newest export is current | Ready to share | Remove from share (today's path) |
| Marked; newest export is outdated | Ready to share · Outdated + **Update** | Update → background render → upload (no re-mark) |

"Current" / "outdated" is defined in §4.1. An export with no fingerprint
(`source_hash = null`, every export made before this ships) is **unknown** and
is treated as current — never flagged Outdated, so the feature launches with no
false alarms. The first export after launch fills the hash in.

### 3.2 Exported files popover

`KvMotionProjectExports` rows (rendered in the editor's "Exported files"
popover and the projects panel) show the same **Outdated** badge and **Update**
button on a marked size whose newest export is outdated, and the same
"Preparing… NN%" while that size renders. Both surfaces read the same state as
the chip (§4.3), so they cannot disagree.

The Share panel / create-link form is **out of scope** (no outdated warning
there).

### 3.3 Rules

- **One render at a time.** Background renders queue FIFO, one active encode,
  to avoid GPU-process contention with the editor (see
  `lesson_export_starved_by_page_animations`). A size already queued or running
  is not queued twice.
- **Leaving the page.** While anything is queued or running, `beforeunload`
  warns. Closing the editor (unmount) aborts the active render and drops the
  queue; nothing is marked for an aborted render.
- **Failure.** Render/upload failure → error toast with the reason; nothing is
  marked; the chip returns to its prior state. A size the browser cannot encode
  (the dialog's `canEncodeAvcAt` / `MAX_VIDEO_EDGE` probe) → toast explaining it,
  no render attempted.
- **Exports list unavailable.** If the exports query failed, keep today's toast
  ("Couldn't check this size's export status") and do not render.
- **What the client sees.** A link already sent keeps playing the previous MP4
  until Update finishes. That is intentional.

## 4. Design

### 4.1 Fingerprint (web)

New pure module `motion/motionExportFingerprint.ts`:

```ts
export async function motionExportFingerprint(input: MotionExportInputs): Promise<string>
```

- `MotionExportInputs` is exactly what one size's render consumes: the remapped
  snapshot and timeline for that tile (`remapSnapshotForRatio` /
  `remapTimelineForRatio`), the tile's `baseImageUrl` / `overlays` / `source`,
  the output `{ id, w, h }`, the bumpers, and the audio clips (urls, offsets,
  trims, gain envelope).
- Canonical JSON (sorted keys, no volatile fields such as selection, playhead,
  UI prefs, `updated_at`) → SHA-256 via `crypto.subtle` → hex.
- Built from the **same** input object the runner (§4.2) passes to
  `exportMotionRatio`, so "different hash" means "the MP4 would differ".

Current vs outdated, per size: `outdated = newestExport.source_hash != null &&
newestExport.source_hash !== currentHash`. No export at all → "needs render".

The editor computes the current hash per tile **debounced** (~500 ms after the
last timeline change), never per playback frame — the tree re-renders ~60/s
during playback.

### 4.2 Shared export runner (web)

Move the per-size render → upload → `createMotionExport` sequence out of
`KvMotionExportDialog` into `motion/runMotionExport.ts`:

```ts
export async function runMotionExport(opts: {
  studioFileId: string; projectId: string;
  inputs: MotionExportInputs;           // §4.1 — also hashed
  signal?: AbortSignal;
  onProgress?: (frac: number) => void;
  onFinalizing?: () => void;
  deps?: Partial<RunMotionExportDeps>;  // uploadAsset, createExport, exportMotionRatio
}): Promise<KvMotionExportRow>
```

- Computes `source_hash` from `inputs`, renders, uploads, creates the export row
  with `source_hash`, returns the row.
- The dialog calls it per selected size (behaviour unchanged, now also storing
  the hash); the chip/popover call it through §4.3. One code path, so an MP4 from
  Mark is byte-for-byte the same pipeline as one from Export.
- Per-run shared resources the dialog opens once (bumper video sources, decoded
  audio) stay owned by the caller and are passed in, so a multi-size dialog run
  still opens each bumper once.

### 4.3 Background queue (web)

Hook `useBackgroundMotionExport(fileId, projectId)` in the editor:

- State: `Map<tileKey, { status: "queued" | "running"; progress: number }>`.
- `enqueue(tileKey, { then: "mark" | "none" })`; FIFO, one running.
- On success: invalidate `motionExportsKey(fileId, projectId)`; for `"mark"`,
  call the existing `toggleReadyToShare(row, chainIds, source)` with the new row.
- `AbortController` per run; abort + clear on unmount; `beforeunload` listener
  while the map is non-empty.
- The chip (`KvMotionTileStage` `readyToShare` prop) and the popover row read
  status from this hook; the "Export this size first" toast is removed.

### 4.4 api

- Migration: `kv_motion_exports.source_hash` — `string(64)`, nullable, no index.
- `StoreKvMotionExportRequest`: `source_hash` → `nullable|string|size:64|regex:/^[0-9a-f]{64}$/`.
- `KvMotionExport::$fillable` += `source_hash`; `KvMotionExportResource` returns it.
- No change to marks, `KvReadyToShareService`, share payloads or approvals: the
  chain-following in `resolveMotionClips` already serves the newest export.

### 4.5 Analytics

Per `frndos-analytics-events` (exact names fixed there before implementation):

- background render started / completed / failed — props: `file_id`,
  `project_id`, `source: "mark" | "update"`, `duration_ms` (completed),
  `reason` (failed).
- Update clicked — props: `file_id`, `project_id`, `surface: "chip" | "popover"`.

Existing `trackKvReadyToShareToggled` keeps firing for the mark itself.

## 5. Testing

- **Fingerprint (unit):** same inputs → same hash across key order; a timeline,
  overlay, bumper or audio change → different hash; playhead/selection changes
  → same hash.
- **Runner (unit, DI deps):** success stores `source_hash` and returns the row;
  render failure / upload failure / abort reject and create no row.
- **Queue (unit):** FIFO, single active run, no duplicate enqueue, mark only
  after success, abort on unmount, `beforeunload` armed only while busy.
- **Chip / popover state (unit):** every row of the §3.1 table, including
  `source_hash = null` → not outdated.
- **Export dialog:** existing `KvMotionExportDialog*.test.tsx` stay green after
  the extraction; add one assertion that the hash is sent.
- **api:** request accepts a valid hash, rejects a malformed one, accepts null;
  resource returns it. Feature tests need the scratch Postgres
  (`lesson_api_feature_tests_need_scratch_postgres`).
- **Manual e2e:** edit a tile → Mark → Preparing → Ready; edit again → Outdated
  → Update → open the share link and see the new cut.

## 6. Out of scope

- Outdated warning in the Share panel / create-link form.
- Live rendering on the share page; server-side rendering.
- Backfilling `source_hash` for existing exports.
