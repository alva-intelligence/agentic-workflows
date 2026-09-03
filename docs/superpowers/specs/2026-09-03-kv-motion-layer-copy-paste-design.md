# KV Motion — Layer Copy/Paste — Design Spec

> **Status:** draft
> **Author:** daffa
> **Created:** 2026-09-03
> **Services:** web only (api unchanged)
> **Topic slug:** kv-motion-layer-copy-paste

## Overview

Let a user duplicate a layer inside a KV Motion project — the overlay *and* its
animation — via right-click and real `Cmd+C` / `Cmd+V`.

The feature is small. Its cost is not, and the reason is worth stating up
front: **Motion has never owned a layer.** Its overlays are a frozen mirror of
a KV board. You can delete a keyframe or a segment, but there is no delete-layer
anywhere in the editor, because overlay lifecycle belongs to Craft. Paste makes
Motion an author for the first time, and that pulls in three things that are
not optional: a delete affordance, an undo stack that spans both storage
layers, and an honest answer for what Resync does to a layer KV has never
heard of.

## Decisions taken (and what they cost)

| Question | Decision | Consequence accepted |
|---|---|---|
| Where does a pasted layer live? | Motion-only. The KV board is never written to. | Resync from KV destroys it. Mitigated by an explicit, counted warning — §4. |
| What does `Cmd+Z` do after a paste? | Full undo: layer + animation, one step. | The command layer is generalized from timeline to document — §2. |
| Scope | Within one motion project. | Cross-project and Craft→Motion paste are out of scope; `canPasteInto` already rejects them. |

The ownership decision is the cheap one and it was taken deliberately. The
obligation it creates is that the loss must never be a surprise.

## 1. What a paste produces

A layer in Motion is **two records in two different stores**:

- a `StudioOverlay` in `snapshot.overlays` — persisted by a REST `PATCH`
- a `MotionTrack` in `timeline.tracks`, keyed by `overlay_id` — persisted
  through the undo stack and the debounced autosave

A paste mints both, atomically:

1. Clone the overlay, mint a fresh id `mo_<ts>_<rand>`.
2. Clone the source's `MotionTrack` and remap `overlay_id` to the new id.
   Keyframes are copied whole, including each keyframe's preset `label`.
3. Commit both in **one** document push (§2).

A fresh id is mandatory, not cosmetic — the same rule `pasteOverlays` already
documents for Craft, where reusing a source id makes the write a silent no-op.

### Why `mo_`, not `tmp_`

`tmp_` is already a load-bearing convention in Craft: the server rekeys `tmp_`
ids to ULIDs and `KvGeneratorLayout` remaps them when the autosave PATCH echoes
back (`KvGeneratorLayout.tsx:3604`). A motion snapshot is opaque JSON that the
api never rewrites, so a `tmp_` id there would persist forever while
advertising the opposite. `mo_` says what is true.

The prefix doubles as the "authored in Motion" marker, which is what scopes
delete (§4) and what makes the resync warning countable (§4). It is intrinsic
to the record, so — unlike a separate `snapshot.motion_overlay_ids` array — it
cannot drift out of sync with the overlays it describes.

### Reuse, not reimplementation

`lib/studio/kv/overlayClipboard.ts` gains a third surface:

```ts
surface: "craft" | "resize" | "motion"
```

Everything else in that module is used as-is. Two consequences fall out for
free:

- `canPasteInto` is same-surface only, so a Craft or Resize copy cannot land in
  Motion. That is the desired scope, enforced by existing code.
- Scope is one project, so `targetFrameId === payload.sourceFrameId` always
  holds and paste always takes the **same-frame nudge** path (2% of the frame,
  clamped by `clampNudged`). `preservePixelGeometry` never runs here.

One new pure function, beside `pruneTimelineToOverlays`:

```ts
cloneTrackForOverlay(
  timeline: MotionTimeline,
  fromOverlayId: string,
  toOverlayId: string,
): MotionTrack | null   // null when the source layer has no track yet
```

A layer with no animation is a normal thing to duplicate; it yields an overlay
and no track, not an empty one.

## 2. Command layer and persistence

### The problem

`useTimelineCommands` (`components/video-editor/useTimelineCommands.ts`, 60
lines) stores a `MotionTimeline`. `Cmd+Z` therefore covers the timeline and
nothing else. Snapshot writes — today only the lock/hide toggle — sit outside
it entirely.

Left alone, a paste would undo **half**: the animation would vanish and the
duplicated layer would stay. That is worse than no undo at all.

### The change

The command state becomes a document:

```ts
type MotionDoc = { snapshot: KvMotionSnapshot; timeline: MotionTimeline };
```

- `push(next: MotionTimeline, label?)` is **kept verbatim** as sugar meaning
  "same snapshot, new timeline". All ~20 existing call sites in
  `useMotionEditorState.ts` are untouched.
- `pushDoc(next: MotionDoc, label?)` is added for the actions that change the
  layer set: paste, delete, and — folded in — the lock/hide toggle.

One stack, one history. `undo` restores layer and animation together.

Rejected: two coordinated stacks. Two histories that must agree exactly are a
reliable way to make them disagree, and this codebase has been bitten by that
class of divergence before.

### Who owns the snapshot for reads

**React-query stays the only place snapshot is read from.** All eight read
sites memoize on `project.snapshot` (`buildTracks`, `resolveMotionTiles`,
`deriveTileOverlays`, `baseProps`, the stages, the export dialog). Every
`push` / `pushDoc` / `undo` / `redo` mirrors the snapshot half into the cache
via `setQueryData`.

Rejected: moving snapshot into command state and rewriting those eight
readers. More churn, identical result, and it would create a second place
snapshot can be read from.

### Autosave becomes document-aware

Today the debounced autosave PATCHes `timeline` only. It must now compare the
snapshot against the last saved one and include `snapshot` when it differs —
in the **same** PATCH, not a second call. Without this, undoing a paste looks
right on screen and never reaches the server.

`toggleOverlayFlag`'s bespoke `patchMotionProject({ snapshot })` in
`KvMotionEditor.tsx:766` is **removed** and folded into this path. Two
independent snapshot writers racing each other is a bug waiting for a slow
network.

Retry and backoff reuse the existing `saveWithRetry`. Nothing new.

**The api is not touched.** `UpdateKvMotionProjectRequest` validates `snapshot`
as `['sometimes', 'array', new MaxJsonBytes]` — web owns the schema.

## 3. Interactions

### Copy

Motion has no multi-select: selection is `selectedKeyframe { trackId, tMs }`,
a single row. `Cmd+C` copies **the selected row's layer**, and only that.

With no row selected, `Cmd+C` does nothing and does not `preventDefault` —
same rule as an unlandable paste.

Refused, with no menu item rendered and no keystroke claimed: the synthetic
`__base__` row, locked layers, hidden layers. This is the same guard
`onTrackContextMenu` already applies (`KvMotionEditor.tsx:1774`) — a menu whose
every action would fail is worse than no menu.

### Keyboard

`clipboardShortcut()` and `isTypingTarget()` from
`lib/studio/kv/keyboardGuards.ts` handle Lexical/contentEditable retargeting,
non-QWERTY layouts, and Alt combos. Two rules:

- **`Cmd+A` is not claimed.** The helper classifies it, but Motion has no
  multi-select. Swallowing it without an answer would break the browser's own
  select-all.
- **`Cmd+V` does not `preventDefault` when nothing can land** — empty
  clipboard, or a payload from another surface. Otherwise it becomes a dead
  key.

Registered inside the **existing** keydown effect (the one handling `Cmd+Z`,
`KvMotionEditor.tsx:1216`), not a second `window` listener whose ordering is
unspecified.

### Delete

Paste can add layers, so layers must be removable, and Motion has no such
action today. Delete is offered **only for `mo_` layers**, in the row's
right-click menu, as a single `pushDoc` — so `Cmd+Z` brings back the layer and
its animation.

KV-mirrored layers stay non-deletable from Motion. Deleting one would be a
lie: the next Resync brings it straight back.

### Multi-tile

Overlays live on the master and are projected per tile (`deriveTileOverlays`);
per-tile `overlays` is typed but always `null` (Phase 2 unbuilt). A pasted
layer therefore appears on every tile, exactly like every other layer.

### Analytics

`trackKvMotionLayerCopied`, `trackKvMotionLayerPasted`,
`trackKvMotionLayerDeleted` — each carrying `project_id` and `overlay_type`,
shaped after the existing `KvMotionTrackToggledProps`. Fired on the
interaction, not on the PATCH's resolution, matching the convention already
documented at `KvMotionEditor.tsx:742`.

## 4. Resync warning

`handleResync` (`KvMotionEditor.tsx:1296`) replaces `snapshot.overlays`
wholesale with overlays read fresh from the KV file, then prunes the timeline
to the surviving ids. A `mo_` layer exists in neither, so it and its track are
destroyed.

That is the accepted behavior. The requirement is that it is never a surprise:

- Before opening the dialog, count
  `snapshot.overlays.filter(o => o.id.startsWith("mo_")).length`.
- When it is greater than zero, the dialog adds a sentence naming the number —
  "3 layers you created in Motion will be deleted" — not a generic caution.
- When it is zero, the copy is unchanged.

### Out of scope, filed separately

`handleResync` rebuilds `newSnapshot` from scratch and drops the optional
`target` and `tiles` fields, silently resetting a project's output size and
multi-tile configuration. Pre-existing, unrelated to this feature, tracked as
its own task.

## 5. Testing

Web only. `bun test` (never `bunx vitest`). Test files stay well under the
~51KB cliff, `bun test` is never pointed at a directory, and RTL queries use
`within(document.body)` rather than `screen`.

**Pure, no DOM**

- `cloneTrackForOverlay`: `overlay_id` remapped, keyframes and preset `label`s
  preserved, `null` for a layer with no track.
- `pasteOverlays` with `surface: "motion"`: fresh id, `z` on top, 2% nudge
  applied on the same-frame path.
- `canPasteInto` rejects `craft` and `resize` payloads against `"motion"`.

**Command layer**

- `pushDoc` → `undo` restores snapshot and timeline in one step.
- The legacy `push` leaves the snapshot untouched.
- Same-label collapse still holds.

**Autosave** — through the existing `patchFn` seam

- A paste sends `snapshot` and `timeline` in one PATCH.
- An ordinary timeline edit still sends no `snapshot`.

**Keyboard**

- `Cmd+C` / `Cmd+V` ignored while focus is in a text field.
- `Cmd+V` does not `preventDefault` on an empty or foreign clipboard.

### Not automatically verifiable

Konva stage rendering of a pasted layer, and its presence in the exported MP4.
jsdom provides no 2D context. These require a manual pass and will be reported
as unverified until that pass happens.

## Files touched

| File | Change |
|---|---|
| `lib/studio/kv/overlayClipboard.ts` | add `"motion"` to the surface union |
| `lib/video-editor/timeline.ts` | new `cloneTrackForOverlay` — the pure module, NOT beside `pruneTimelineToOverlays`, which lives in the `useMotionEditorState` hook file |
| `components/video-editor/useTimelineCommands.ts` | document state, `pushDoc`, keep `push` |
| `components/studio/kv-generator/motion/useMotionEditorState.ts` | document-aware autosave; copy/paste/delete actions |
| `components/studio/kv-generator/motion/KvMotionEditor.tsx` | keyboard, menu items, resync copy; remove bespoke snapshot PATCH |
| `components/video-editor/TrackNameCell.tsx` / row menus | Duplicate + Delete entries |
| `lib/analytics/kv-generator-events.ts` | three events |

api: none.
