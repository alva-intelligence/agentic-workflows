# KV Motion — multi-select layers, apply one motion to all

**Date:** 2026-09-20
**Author:** Daffa (with Claude)
**Status:** IMPLEMENTED 2026-09-20 on `feature/daffa/vc-kv-motion-multi-select` (web, 14 commits `fae3e8b92..41484e90e`), unpushed; unit/RTL green, whole-branch review clean after one fix wave; **browser e2e checklist not run** (login needed — Daffa to verify manually)
**Services:** web only
**Branch:** `feature/daffa/vc-kv-motion-multi-select`, from `develop` (the Path + anchored-slots work is already on `develop`).
**Source:** MFS live simulation session, 16 Sep 2026 — "user cannot select multiple layers at once and apply one animation/preset to all of them; has to apply the same animation to each layer individually, one at a time."

---

## Problem

Selection in the Motion editor is a single track: `selectedKeyframe.trackId` in `useMotionEditorState` is the only selection state, and the Layers rail, the timeline dock rows, the Konva Transformer, the Inspector and the keyboard shortcuts all read it. The layer menu (✨ in the rail, right-click on a dock row) applies a preset to exactly one track (`applyPresetTo(trackId, preset)`).

The only bulk path is the toolbar **Stagger** pill, which deals one preset across **every** unhidden layer with a 150 ms step. There is no way to pick a *subset* of layers, and no way to give several layers the *same* motion at the *same* time in one action.

## Decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Where multi-select lives | **Layers rail + timeline dock rows.** Canvas stays single-select. | Rail and dock rows already funnel to one `selectTrack`; the Konva stage binds one Transformer to one node and is the most fragile surface (memory: four-renderer drift, tile editor clipping). Figma/Canva layer-list convention. |
| Gesture | Plain click = replace. **Cmd/Ctrl-click = toggle.** **Shift-click = range** from the primary to the clicked row, in rail z-order. | Standard; nothing to teach. |
| Selection shape | `selectedTrackIds: string[]` in rail z-order (not click order) **plus** the existing `selectedKeyframe` as the **primary** (last clicked). Primary is always a member. | Stagger and fan-out must be deterministic regardless of click order. Inspector / Transformer / keyboard keep reading the primary unchanged, so nothing downstream of them moves. |
| Timing of a bulk apply | **Simultaneous by default** (same `atMs` for every member — exactly what applying one-by-one gives), plus a **"Stagger across N layers"** item that runs `applyStagger` over the selection only. | The complaint is about repetition, not about wanting a cascade; the cascade already exists and only needed a subset. |
| Which menu actions fan out | Every action that **writes keyframes**: entrance/exit preset, emphasis preset, saved template (Motions), Paste motion. Copy motion, Save as template, Duplicate, Delete stay primary-only and are **hidden** from the menu while N > 1. | "Apply motion" is the ask. Hiding rather than disabling avoids an ambiguous "which one gets deleted?" |
| Undo | One `push()` per bulk action. | One decision, one undo step — the same rule `applyStagger` and `applyBuild` follow. |
| Members that can't take it | An emphasis with no room, a template that can't bake, a paste that can't place: that member is **skipped**, the rest are written, and the toast says "Applied to 3 of 4 layers". Zero written → the existing error toast, no push. | Never fail the whole gesture on one bad layer; never write a partial that lies about being complete. |
| Eligibility | `__base__`, locked and hidden tracks can't join a multi-selection, and are pruned from it the moment they become locked/hidden (`setOverlayFlag`). Every bulk writer gates on `multiSelectOrder` membership — **not** `base.has()`, which keeps locked overlays (it only skips hidden). Plain click on them still works as today. | Same gate the menu already uses; the writer gate was corrected during implementation (final review #1). |
| Menu on an unselected row | Right-click / ✨ on a row that is **not** a member collapses the selection to that row first (then the single-layer menu). On a member → multi menu targeting the whole selection. | Figma convention; avoids "I right-clicked X and it animated Y". |
| Collapse | `selectKeyframe` (a diamond / bar click), canvas click, `Esc`, plain click → single. Selection persists across playhead moves, Inspector edits, undo/redo. | Any gesture that means "this one specific thing" resets. |
| Toolbar Stagger | Targets the selection when N > 1 (label "Stagger (3)"), else all layers as today. | Same button, selection-aware. No new pill. |
| Analytics | `motion_preset_applied` gains `source: "multi" \| "multi_stagger"`, `track_count = N written`, `template_id` when the payload was a template. Existing sources unchanged. | Same funnel; the doc comment "always 1 for track/template" stays true. |
| Discoverability | Rail `PanelHeader` gets a subtle hint tooltip: "Shift/⌘-click to select multiple". | Cheap; MFS users are not Figma users. |

## Design

### 1. State — `useMotionEditorState.ts`

- New state: `selectedTrackIds: string[]`. Invariant: sorted by rail z-order (the hook receives `orderedOverlayIds` or derives the order from `snapshot.overlays` the same way the editor's `tracks` does); `selectedKeyframe?.trackId` ∈ `selectedTrackIds` whenever `selectedKeyframe` is non-null; length 0 ⇔ `selectedKeyframe === null`.
- `selectTrack(trackId, mode: "replace" | "toggle" | "range" = "replace")`:
  - `replace`: `[trackId]`, primary = trackId at current playhead (today's behaviour).
  - `toggle`: add if absent (primary = trackId); remove if present (primary = the remaining member nearest in z-order, or null when empty). Ineligible ids are ignored (no-op).
  - `range`: every eligible id between the current primary and `trackId` in z-order, inclusive; union with the current set; primary = `trackId`. No primary → behaves as `replace`.
- `selectKeyframe`, `selectTrackAtStart`, `clearSelection` (new; bound to `Esc` and the canvas background click) all collapse to a single member / none.
- `setSelectedKeyframe` callers that only move `tMs` (keyframe edits, undo re-anchoring at lines ~750/1204/1220) leave `selectedTrackIds` alone.
- Bulk writers, each one `push()`:
  - `applyPresetToTracks(ids, preset, atMs): number` — `ids.reduce((tl, id) => applyPreset(tl, base, id, preset, atMs), timeline)`; returns ids written.
  - `applyEmphasisToTracks(ids, preset): number` — reduce with `applyEmphasisPreset`; a `null` result skips that id and keeps the accumulator.
  - `applyTemplateToTracks(ids, body): number` — reduce with `bakeTemplateToTrack`; null bakes skipped.
  - `pasteMotionToTracks(ids, mode): number` — the body of today's `pasteMotion` is extracted into a pure `pasteMotionInto(timeline, base, trackId, clip, mode, atMs)`; `pasteMotion` (single) and the bulk writer both call it. Target is always "playhead" for bulk (no block/slot target).
  - `applyStaggerToTracks(ids, preset)` — thin wrapper over `applyStagger` with the selection order.
  - Each returns 0 without pushing when nothing was written.

### 2. Rail — `KvMotionEditor.tsx`

- Row `onClick={(e) => state.selectTrack(t.id, modeFromEvent(e))}` where `modeFromEvent` = `shiftKey → "range"`, `metaKey || ctrlKey → "toggle"`, else `"replace"`. Shared helper in `motion/selectionMode.ts` so the dock uses the same one.
- `selected = state.selectedTrackIds.includes(t.id)`; the primary additionally gets `ring-1 ring-border-default` (member = tint only, primary = tint + ring).
- `trackPresetMenuProps(trackId, …)` computes `targetIds = selectedTrackIds.includes(trackId) && selectedTrackIds.length > 1 ? selectedTrackIds : [trackId]` and passes `targetTrackIds` + the bulk handlers. Opening the menu on a non-member calls `state.selectTrack(trackId)` first.
- `applyPresetTo` / `applyTemplateTo` / `pasteMotionTo` grow a `targetIds` parameter; single-id calls keep today's toasts and analytics; N > 1 calls use the bulk writers, the "Applied to X of N" toast when X < N, and `source: "multi"`.
- Toolbar Stagger: `staggerIds = selectedTrackIds.length > 1 ? selectedTrackIds : orderedOverlayIds`; label `Stagger` / `Stagger (N)`; `source: "multi_stagger"` when it used the selection.

### 3. Dock — `TimelineDock.tsx`, `BlockTrackRow.tsx`, `TrackNameCell.tsx`

- `TimelineDockProps.selectedTrackIds: string[]` (new, alongside `selectedKeyframe`); `onFocusTrack(trackId, mode)` gains the mode. `BlockTrackRow`'s row `onClick` passes `modeFromEvent(e)`. `selected` for the row tint = membership; primary ring on `TrackNameCell` only.
- Bar body click (`handleBodyClick` → `onSelectTrack` → `selectTrackAtStart`) stays a collapse: clicking a block means *this* block.
- Right-click on a member row opens the multi menu (the editor already renders one anchored `TrackPresetMenu` for the dock — it just receives `targetTrackIds`).

### 4. Menu — `TrackPresetMenu.tsx`

- New prop `targetTrackIds: string[]` (default `[trackId]`). When length > 1: header shows `N layers` instead of the track name/icon; Copy / Save / Duplicate / Delete items are not rendered; the header carries a small **Stagger** toggle (off by default, local menu state). With it on, picking an entrance/exit preset from the grid runs `applyStaggerToTracks` instead of the simultaneous writer; Emphasis / Saved / Paste ignore the toggle (always simultaneous). Their handlers receive the ids from the host.
- `hasKeyframes` for the multi header = any member has keyframes (drives the Copy/Paste enablement as today).

### 5. Keyboard

- `Esc` → `clearSelection()` (today Esc is unbound in the editor; verify nothing else claims it).
- Existing `Cmd+C/V`, `Shift+Cmd+V`, Delete keep acting on the primary only (unchanged).

### 6. Analytics — `kv-generator-events.ts`

- `KvMotionPresetAppliedProps.source` adds `"multi" | "multi_stagger"`; comment updated. `track_count` = members actually written.

## Testing

- `useMotionEditorState.selection.test.tsx`: toggle add/remove/primary handoff; range in z-order with union; ineligible ids ignored; `selectKeyframe` / `selectTrackAtStart` / `clearSelection` collapse; undo/redo leaves selection; bulk writers = exactly one `push` and correct written count with one member skipped (emphasis with no room, unbakeable template).
- `presets`/`pasteMotionInto`: pure extraction is byte-for-byte equal to the previous `pasteMotion` for the single case.
- `KvMotionEditor` RTL: Cmd-click and Shift-click on rail rows highlight the set; ✨ on a member opens a menu whose header says `3 layers`; picking a preset writes keyframes on all three; ✨ on a non-member collapses first.
- `TimelineDock.multiselect.test.tsx`: modifier click on the name cell passes the mode; bar click collapses; member rows tinted, only the primary ringed.
- `TrackPresetMenu.test.tsx`: N > 1 hides Copy/Save/Duplicate/Delete and shows the Stagger item.
- Manual e2e in the preview: select 3 layers, apply Pop in → all three pop at the playhead; Stagger (3) → cascade; undo once → all reverted.

## Non-goals

Canvas / Transformer multi-select or marquee; bulk Delete / Duplicate / Copy; drag-moving several rows at once; persisting the selection.

## Rulings made during implementation (2026-09-20)

- **Toggle on an ineligible id is a no-op**, not a single-select (the plan's sample code fell through to `replace`; the Decisions table and the plan's own test say ignore).
- **`deleteKeyframe` on the primary's selected keyframe clears the whole selection** (keeps the pre-existing deselect-on-delete; no primary hand-off). `deleteLayer` and lock/hide DO hand the primary off to the first remaining member.
- **Primary ring is `ring-1 ring-inset ring-white/25`**, not `ring-border-default`; **hint is an inline muted span** "Shift / ⌘-click for multiple" in the Layers header, not a tooltip — more discoverable for MFS users, no new dark hex.
- **Stagger toggle resets inside `closeMenu()`** as well as on `onOpenChange` — the popover's own close callback never fires for a pick.
- **Menu's Stagger toggle reuses the v1 `Toggle` component** (`role="switch"`).
- **No `KvMotionEditor` RTL test** (never had one; Konva + queries). Editor wiring is covered by helper/hook/dock/menu tests + the manual checklist in the plan's Task 10, which is still pending.
- Parked, not fixed: `reportBulk` says "hidden, locked, or no room" even when the real cause is an unbakeable saved motion; Esc on the focused dock-resize handle also clears the selection (keyboard-only edge); `hasKeyframes` over the selection is dead in multi mode (Copy/Save hidden). Pre-existing: emphasis presets never report `motion_preset_applied`.
