# KV Motion — Timeline Upgrades

**Date:** 2026-08-29
**Author:** daffa
**Status:** design approved, not implemented
**Repos:** `web` (frnd-web), `api` (frnd-api-php)
**Branch:** `feature/daffa/vc-kv-motion-timeline-upgrades` (cut from `origin/develop` in both repos)

## Overview

Four independent improvements to the KV Motion timeline editor, prompted by a
comparison against thebrief.ai's animation panel:

1. **Change motion in place** — swap the preset behind an existing block from a
   right-click menu, keeping the block's tuned duration, instead of
   delete-then-reapply.
2. **Motion templates** — save one layer's whole animation as a named,
   brand-scoped, server-persisted recipe and apply it to any other layer.
3. **Snapping on drag** — segment drags snap to the guides around them
   (timeline bounds, playhead, gridlines, other layers' block edges, the audio
   clip, the preview range).
4. **Per-property sub-rows** — expand a layer row into Position / Scale /
   Rotation / Opacity lanes so stacked animations become legible.

The features share no state and can land in any order; each is independently
shippable.

### What was deliberately left out

From the thebrief.ai comparison, three things were considered and dropped for
this round:

- **Masked reveal presets** (Blinds, Iris, Clock, Wipe, Zigzag) — these need
  per-layer masking or a shader pass. The engine animates five scalar
  properties (`x`, `y`, `scale`, `rotation`, `opacity`); there is no mask
  channel to animate. Out of scope, not deferred — it is a different feature.
- **Copy / paste animation between layers** — the machinery is a subset of
  Feature 2 (normalize a track, bake it onto another). Cheap to add *after*
  templates land; not in this round.
- **Preset search/filter and hover-preview** — the preset list is 13 entries;
  search earns its place later. Hover-preview needs a throwaway render path
  that cannot dirty the timeline or the undo stack, which is the riskiest thing
  on the shortlist for the smallest gain.

## Current state (what exists on `origin/develop`)

The engine lives in `web/src/lib/video-editor/` and is deliberately
KV-agnostic — `importBoundary.test.ts` fails the build if anything in it
imports from `components/studio/kv-generator` or `lib/studio/kv`. All four
features keep that boundary: engine logic goes in `lib/video-editor/`, engine
UI in `components/video-editor/`, and only the template *service* and *panel
wiring* touch KV code.

Relevant pieces:

- `timeline.ts` — the persisted document. `MotionKeyframe` carries a sparse
  `props` subset of the five `MotionProps`, an `easing`, and an optional
  descriptive `label` (the preset name that wrote it).
- `blocks.ts` — derives "segments" (contiguous keyframe clusters) from a
  track via `trackSegments`, buckets them into In / Emphasis / Out slots via
  `assignSegmentsToSlots`, and owns the segment-scoped edit primitives:
  `shiftSegmentKeyframes`, `stretchSegmentKeyframes`, `deleteSegmentKeyframes`.
  `MIN_BLOCK_SPAN_MS = 100`.
- `presets.ts` — `PRESET_WRITERS` (6 entrance + 3 exit, `ENTRANCE_MS = 500`),
  `EMPHASIS_WRITERS` (4, `EMPHASIS_WINDOW_MS = 600`), `PRESET_LABELS`,
  `applyPreset`, `applyEmphasisPreset`, `applyStagger`.
- `components/video-editor/BlockTrackRow.tsx` — the slot-lane row. Owns segment
  drag (body = shift, edge handles = stretch) and a right-click context menu
  whose only item today is **Delete**.
- `components/video-editor/TimelineRuler.tsx` — picks a "round" tick step from
  `TICK_STEPS_SEC` based on `pxPerSecond`, plus minor ticks at a quarter of
  that when they stay ≥ `MIN_MINOR_GAP_PX` apart.
- `components/studio/kv-generator/motion/KvMotionEditor.tsx` — the KV binding.
  Owns the left "Layers" rail, where each row has a `TrackPresetMenu` (the ✨
  button) listing entrance/exit presets and an Emphasis group.
- api persists motion projects in `kv_motion_projects` (`KvMotionProject`,
  `KvMotionProjectController`), routed under
  `studio/files/{file}/motion-projects` inside the
  `feature.flag:show-kv-generator` group.

---

## Feature 1 — Change motion in place

### Problem

Swapping the preset behind an existing block means deleting it and applying a
new one from the ✨ menu. That costs two undo steps, re-anchors the block at
the playhead instead of where it was, and throws away a duration the user
tuned by dragging the handles.

### Engine

New export in `presets.ts`:

```ts
export function replaceSegmentPreset(
  timeline: MotionTimeline,
  base: Map<string, MotionProps>,
  overlayId: string,
  segStart: number,
  segEnd: number,
  preset: MotionPresetId | EmphasisPresetId,
): MotionTimeline
```

Steps:

1. **Guard.** No-op (returns the same `timeline` reference) when the track is
   missing, when `[segStart, segEnd]` does not match one of the track's
   *current* segments per `trackSegments`, or when `segStart === segEnd` (a
   still point has no span to preserve — see the UI rule below). This is the
   same staleness guard `deleteSegmentKeyframes` already uses, and it exists
   for the same reason: a context menu opened before an intervening edit must
   not rewrite the wrong keyframes.
2. **Delete** the old segment's keyframes via `deleteSegmentKeyframes`.
3. **Resolve the pose** the new preset animates around:
   - entrance / exit presets use the overlay's rest pose, `base.get(overlayId)`
     (matching `applyPreset`);
   - emphasis presets sample the post-delete timeline at `segStart` via
     `sampleTimelineAt` (matching `applyEmphasisPreset`), so an emphasis
     dropped after an entrance still starts from where the entrance left the
     layer.
4. **Write** the new keyframes by calling the preset's own writer directly
   (`PRESET_WRITERS[preset]` or `EMPHASIS_WRITERS[preset]`) at its natural
   anchor: `segStart` for entrance and emphasis, `segEnd` for exit (exit
   writers anchor their *last* keyframe).
5. **Rescale** those freshly written keyframes linearly from their natural
   window onto `[segStart, segEnd]` — the block keeps the exact span the user
   had.
6. **Upsert** the rescaled keyframes into the track, merging `props` into an
   existing keyframe at an identical `t_ms` and stamping `PRESET_LABELS[preset]`
   as the `label`, so the bar reads the new preset's name.

Returns one timeline → **one undo step**.

#### Why the writers are called directly instead of reusing `applyPreset`

The obvious composition — `deleteSegmentKeyframes` → `applyPreset` →
`stretchSegmentKeyframes` — has a real failure mode. `stretchSegmentKeyframes`
re-derives segments from the timeline and requires an exact `[start, end]`
match. The pair `applyPreset` just wrote can *merge* with an adjacent existing
cluster (`trackSegments` clusters by motion continuity, not by time gaps), and
the merged segment's bounds then match nothing the caller can predict — the
stretch silently no-ops and the block snaps back to the preset's default
length.

Calling the writer directly and rescaling its own output before insertion side-
steps segment re-derivation entirely and touches nothing outside
`[segStart, segEnd]`.

The strip logic inside `applyPreset` / `applyEmphasisPreset` is not needed here
either: step 2 already emptied the span, so there is nothing stale left to
strip. Emphasis' `EMPHASIS_MIN_WINDOW_MS` room check is likewise dropped — that
guard exists because emphasis is normally applied *at the playhead* and needs
room before the end; here the span is fixed, already inside the timeline, and
known-valid.

The upsert body (steps 4–6) is factored into a private
`upsertKeyframes(track, keyframes, label)` helper shared by `applyPreset`,
`applyEmphasisPreset`, and `replaceSegmentPreset`, so the three cannot drift.

#### Known limitation (accepted, documented in code)

If the rescaled window's boundary lands exactly on a keyframe belonging to a
neighbouring segment, the upsert merges into that keyframe and overwrites the
props the new preset touches at that one instant. Neighbours keep the 1ms
clearance the existing shift/stretch primitives enforce, so this needs an exact
collision to bite. It is the same accepted blast radius as
`applyEmphasisPreset`'s window-scoped strip.

### UI

`BlockTrackRow.tsx`'s context menu grows from one item to two:

```
Change motion  ▸   (submenu)
Delete
```

- The submenu is filtered by the segment's slot, resolved with the existing
  `assignSegmentsToSlots`: **In** → `ENTRANCE_PRESET_IDS`, **Emphasis** →
  `EMPHASIS_PRESET_IDS`, **Out** → `EXIT_PRESET_IDS`. This reuses exactly the
  filtering `SlotPlaceholder` already does for empty slots.
- The currently active preset (matched by `segmentLabel`'s output against
  `PRESET_LABELS`) renders with a check. A hand-authored segment has no label
  and simply shows nothing checked.
- **Still points** (zero-span diamonds) keep a Delete-only menu — there is no
  duration to preserve and no block to re-shape.
- Labels come from `PRESET_LABELS` — never a second local copy of that map.

The menu item calls a new `replaceSegment(trackId, segStart, segEnd, presetId)`
callback threaded `BlockTrackRow → TimelineDock → useMotionEditorState`, where
it wraps `replaceSegmentPreset` in a single `push()`.

### Tests (`presets.replaceSegment.test.ts`)

- Stretched block keeps its span: a fade-in stretched to 1200ms, changed to
  pop-in, still spans 1200ms.
- Preset label on the segment updates to the new preset's name.
- Neighbouring segments on the same track are untouched.
- A stale `[segStart, segEnd]` pair (not a current segment) is a no-op that
  returns the same reference.
- A still point is a no-op.
- Emphasis replacement starts from the sampled pose, not the rest pose (apply
  a slide-in, then replace a later pulse — the pulse's scale keyframes are
  relative to the post-entrance pose).
- Exit replacement anchors its last keyframe at `segEnd`.

---

## Feature 2 — Motion templates (brand-scoped)

### Scope decision

A template captures **one layer's entire animation** — its In, every Emphasis,
and its Out — as one named recipe. This mirrors thebrief.ai's Saved entries
(one of theirs composes Move + Scale + Scale) and is the unit a user actually
thinks in ("make this layer move like that one"). Per-segment templates and
whole-project templates were considered and rejected: the first cannot express
a combined entrance+emphasis identity, the second needs a layer-mapping rule
between KVs with different layer counts and kinds.

Templates are **server-persisted and brand-scoped** — visible to everyone
working on the same brand, surviving device and browser changes.

### The core problem: keyframe values are absolute

Keyframe props are absolute values derived from the *source* layer's rest pose.
`fade-in` ends at `base.opacity`; `slide-in-left` starts at `base.x - 0.15`;
`pop-in` starts at `POP_FROM_SCALE` times nothing — it starts at the literal
`0.6` and lands on `base.scale`. Pasting those numbers onto a layer that rests
somewhere else teleports it.

So a template stores **deltas against the source layer's rest pose**, and
applying it re-bakes those deltas against the *target* layer's rest pose.

New engine module `web/src/lib/video-editor/templates.ts`:

```ts
export type MotionTemplateKeyframe = {
  t_ms: number;
  /** Same sparse subset shape as MotionKeyframe.props, but every value is
   *  RELATIVE to the rest pose — see the per-prop encoding below. */
  props: Partial<MotionProps>;
  easing: MotionEasing;
  label?: string;
};

export type MotionTemplateBody = {
  version: 1;
  source_duration_ms: number;
  keyframes: MotionTemplateKeyframe[];
  /** Props whose values are stored ABSOLUTELY rather than relatively, because
   *  the source layer's rest pose made a ratio undefined — see "Degenerate
   *  rest poses" below. Empty for every normal template. */
  absolute_props: (keyof MotionProps)[];
};

export function normalizeTrackToTemplate(
  track: MotionTrack,
  base: MotionProps,
  sourceDurationMs: number,
): MotionTemplateBody;

export function bakeTemplateToTrack(
  body: MotionTemplateBody,
  overlayId: string,
  targetBase: MotionProps,
  targetDurationMs: number,
): MotionTrack | null;
```

`bakeTemplateToTrack` returns `null` — never throws — for a body it cannot
read (see "Failure handling" below), so one bad row cannot take the editor
down.

Per-prop encoding (normalize → bake is an exact round-trip):

| prop | stored as | bake |
|---|---|---|
| `x`, `y` | additive offset `v - base` | `targetBase + offset` |
| `rotation` | additive delta in degrees | `targetBase.rotation + delta` |
| `scale` | ratio `v / base.scale` (`base.scale === 0` → store the absolute value and flag it, see below) | `targetBase.scale * ratio` |
| `opacity` | fraction `v / base.opacity` (`base.opacity === 0` → absolute) | `clamp(targetBase.opacity * fraction, 0, 1)` |

**Degenerate rest poses.** A layer resting at `scale: 0` or `opacity: 0` makes
a ratio undefined. In that case the value is stored absolutely and the prop is
listed in a `absolute_props: (keyof MotionProps)[]` field on the body, so bake
knows to pass it through untouched rather than multiply. This is rare (a layer
resting invisible) but silently producing `NaN` keyframes is not an acceptable
failure.

**Timing.** Stored as absolute ms plus `source_duration_ms`. On bake:

- target duration ≥ the template's own span → timing is preserved verbatim (a
  700ms entrance stays a 700ms entrance on a longer clip);
- target duration < the template's span → the whole template is scaled
  proportionally to fit `[0, targetDurationMs]`, so nothing is silently
  truncated past the end of the clip.

`bakeTemplateToTrack` returns a complete `MotionTrack`; applying a template
**replaces** the target layer's track wholesale (it is a whole-layer recipe, not
an additive one) in a single `push()`.

### api

New migration `database/migrations/2026_08_29_100000_create_kv_motion_templates_table.php`:

| column | type | notes |
|---|---|---|
| `id` | ulid, pk | matches `KvMotionProject`'s `HasUlids` |
| `workspace_id` | fk | for `HasWorkspaceScope` |
| `brand_id` | fk | the scope that decides visibility |
| `created_by` | fk users | for attribution in the list |
| `name` | string | user-supplied, required |
| `body` | jsonb | the `MotionTemplateBody` document, stored opaquely |
| `source_duration_ms` | integer | denormalised for display ("built for 5s") |
| timestamps, `deleted_at` | | `SoftDeletes`, as `KvMotionProject` |

Index on `(workspace_id, brand_id, deleted_at)` — the list query's shape.

- `app/Models/KvMotionTemplate.php` — `HasFactory, HasUlids, HasWorkspaceScope,
  SoftDeletes`; `body` cast to array; `creator()` belongsTo User.
- `app/Http/Controllers/Api/Studio/KvMotionTemplateController.php` —
  `index` / `store` / `update` (rename only) / `destroy`, following
  `KvMotionProjectController`'s structure.
- `app/Http/Requests/Studio/StoreKvMotionTemplateRequest.php` and
  `UpdateKvMotionTemplateRequest.php`.
- `app/Http/Resources/Studio/KvMotionTemplateResource.php`.

Routes, inside the existing `feature.flag:show-kv-generator` group in
`routes/api.php`, next to the motion-project routes:

```php
Route::get('files/{file}/motion-templates', [KvMotionTemplateController::class, 'index']);
Route::post('files/{file}/motion-templates', [KvMotionTemplateController::class, 'store']);
Route::patch('files/{file}/motion-templates/{template}', [KvMotionTemplateController::class, 'update']);
Route::delete('files/{file}/motion-templates/{template}', [KvMotionTemplateController::class, 'destroy']);
```

The brand is derived **server-side** from `$file->brand_id`; the client never
sends a `brand_id`, so there is no client-supplied scope to validate ownership
of. `index` lists every non-deleted template for that file's brand.

**Validation of `body`.** `api` stores the document opaquely, exactly as it
stores `kv_motion_projects.timeline`. The request validates only the envelope:
`body` is a required array, `body.version` must be `1`, `body.keyframes` a
required array. It does **not** validate individual keyframes.

> Note for implementation: `api/` runs with `excludeUnvalidatedArrayKeys`
> enabled, so declaring a `body.*` sub-rule strips every unlisted key from the
> payload. Validate the envelope through `withValidator()` (or whitelist every
> key), never with a bare `body.version` rule — a `payload.*`-style sub-rule
> has silently emptied a JSON column here before.

**Tests.** Unit tests only (`tests/Unit/...`), following the existing
`KvMotionProjectRequestsTest` / `KvMotionProjectResourceTest` pattern — the
api Feature suite does not survive a fresh migrate. Cover: request validation
(including that a full `body` document survives validation intact), resource
shape, and the controller's brand derivation.

### web

- `src/services/kv/motionTemplates.ts` — list / create / rename / delete,
  following `motionProjects.ts`.
- `src/types/kv/motionTemplate.ts` — the row shape (`id`, `name`,
  `sourceDurationMs`, `createdBy`, `createdAt`, `body`).
- **Save**: a "Save motion as template…" item in the layer row's ✨ menu,
  disabled when the layer has no keyframes. Opens a small name dialog, then
  `normalizeTrackToTemplate(track, base.get(overlayId), timeline.duration_ms)`
  → POST.
- **Apply**: a **Saved** group at the top of the same ✨ menu, above Entrance
  and Emphasis. Clicking an entry bakes and replaces the layer's track in one
  `push()`. Each entry carries a hover affordance for rename and delete.
- Templates are fetched once when the editor mounts and refetched after a
  create/rename/delete; the list is small and brand-scoped.

**Why not a tabbed panel like thebrief.ai.** The ✨ per-layer menu is already
"give this layer some motion" — the same question the Saved list answers.
Adding a third floating panel to an already-busy canvas for one list is not
worth the space yet. When Saved grows past a couple of dozen entries, promoting
it to its own tabbed panel is a contained follow-up.

### Failure handling

- A create/rename/delete failure surfaces a toast and leaves the local list
  untouched (no optimistic insert to roll back).
- A `body` that fails to bake — an unreadable or future `version`, or a
  keyframe with a non-finite value after baking — is rejected client-side with
  a toast, and the timeline is left unchanged. `bakeTemplateToTrack` returns
  `null` in that case rather than throwing, so one bad row cannot take the
  editor down.
- A template saved from a layer and applied to *the same* layer must round-trip
  to an identical track; this is asserted in tests.

### Tests (`templates.test.ts`)

- normalize → bake against the **same** base reproduces the original track
  exactly (round-trip).
- bake against a **different** base repositions correctly: a slide-in-left
  saved from a layer at `x: 0.2` and applied to one at `x: 0.7` starts at
  `0.55`, not `0.05`.
- `scale` and `opacity` bake multiplicatively; a target at half the source's
  rest scale gets a proportionally smaller pop.
- Degenerate rest pose (`scale: 0`, `opacity: 0`) stores absolutely, bakes
  through untouched, and produces no `NaN`.
- Target shorter than the template's span scales the whole thing to fit; target
  longer preserves absolute timing.
- An unknown `version` returns `null` rather than throwing.

---

## Feature 3 — Snapping on drag

### Problem

`SegmentBar.handleMove` in `BlockTrackRow.tsx` is a bare `clamp()`. Aligning
one layer's entrance to another layer's exit, or landing a block on a round
second, is pixel-hunting.

### Tick extraction (prerequisite)

Snapping to a gridline is only meaningful if it snaps to a gridline that is
actually **drawn**. `TimelineRuler` currently owns that arithmetic privately.
Extract it to a new `web/src/lib/video-editor/ticks.ts`:

```ts
export function rulerTicks(
  durationMs: number,
  pxPerSecond: number,
): { labelTicksSec: number[]; minorTicksSec: number[] }
```

moving `TICK_STEPS_SEC`, `MIN_LABEL_GAP_PX`, `MIN_MINOR_GAP_PX` and
`buildTicks` with it. `TimelineRuler` imports it instead of computing inline —
a pure refactor with no behaviour change, covered by the ruler's existing
tests. Snap guides and drawn gridlines then cannot drift apart by construction.

### Engine

New `web/src/lib/video-editor/snap.ts`:

```ts
export type SnapGuideKind =
  | "bound"     // 0 and duration_ms
  | "playhead"
  | "preview"   // preview-range start/end
  | "segment"   // another block's edge, any track
  | "audio"     // the audio clip's start/end
  | "tick";     // a drawn ruler gridline

export type SnapGuide = { ms: number; kind: SnapGuideKind };
export type SnapMode = "body" | "left" | "right";
export type SnapResult = { startMs: number; endMs: number; hitMs: number | null };

export function snapEdges(
  startMs: number,
  endMs: number,
  mode: SnapMode,
  guides: readonly SnapGuide[],
  toleranceMs: number,
): SnapResult
```

Rules:

- `toleranceMs <= 0` or an empty `guides` list → passthrough, `hitMs: null`.
- `"body"` — both edges are candidates. For every guide, measure the distance
  to `startMs` and to `endMs`; the global minimum within tolerance wins; both
  edges shift by that delta so the span is preserved.
- `"left"` — only `startMs` moves; `endMs` is returned unchanged.
- `"right"` — only `endMs` moves; `startMs` is returned unchanged.
- Ties break toward the **lower** ms, so the result is deterministic and does
  not depend on guide ordering.
- Pure and total: never throws, never returns a non-finite number.

### Guide collection

`TimelineDock` builds the guide list — it is the only component that sees every
track, the duration, the playhead, the preview range, and `timeline.audio`:

- `bound`: `0`, `duration_ms`
- `playhead`: `playheadMs`
- `preview`: `previewRange.startMs`, `previewRange.endMs` (when set)
- `segment`: every `trackSegments` boundary on **every** track, including the
  dragging track's own neighbours
- `audio`: `audio.start_ms` and `audio.start_ms + (trim_out_ms - trim_in_ms)`
  (when audio is set)
- `tick`: `rulerTicks(...)`'s labelled **and** minor ticks, converted to ms —
  every gridline the ruler actually paints

Duplicates are collapsed by ms with a fixed kind priority
(`bound > playhead > preview > segment > audio > tick`) so a guide line renders
with one stable style.

The dragging segment's own two edges are excluded from the list before it
reaches `SegmentBar` — a block must not snap to itself.

### Interaction

- Tolerance is **8 CSS pixels**, converted to ms through the lane width the
  drag already measures, so the feel is identical at every zoom level.
- Order inside `handleMove`: snap **first**, then the existing wall clamp. If
  the clamp moves the result off the guide, `hitMs` is cleared — walls always
  win over snapping.
- While a snap is active, a vertical guide line renders at `hitMs` across the
  lane, and disappears on pointerup.
- Holding **Alt** disables snapping for the duration of the drag. The modifier
  is read from the live pointer event (`e.altKey`) on every move, so it can be
  pressed and released mid-drag.

Scope: the slot/blocks view's segment drags (body, left handle, right handle).
Keyframe-diamond drags in the "keyframes" view are unchanged this round.

### Tests

`snap.test.ts` (pure): each mode snaps the right edge(s); body preserves span;
out-of-tolerance guides are ignored; the nearest of several competing guides
wins; ties resolve to the lower ms; empty guides and zero tolerance pass
through.

`BlockTrackRow` drag tests: a drag that ends within tolerance of another
track's block edge commits the snapped value; the same drag with Alt held
commits the raw value; a snap that would cross a neighbour wall commits the
wall, not the guide.

---

## Feature 4 — Per-property sub-rows

### Engine

`blocks.ts` gains:

```ts
export type PropGroupKey = "position" | "scale" | "rotation" | "opacity";
export function propGroupSegments(
  track: MotionTrack,
  group: PropGroupKey,
): TrackSegment[]
```

It reuses `trackSegments`' clustering logic, restricted to the keyframes that
set at least one prop in that group. Groups come from the existing
`PROP_LABEL_GROUPS` (`x`+`y` → position, then scale, rotation, opacity), which
is already the single source of truth for how props are named to users — no
second grouping table.

### UI

- `TrackNameCell` gains a chevron, rendered only in the slots view and only
  when the track has at least one keyframe.
- Expanded state is local to `TimelineDock` (a `Set<trackId>`), not persisted —
  same rationale as `view` and `loop`, which are documented in `types.ts` as
  session-only UI state that never enters the timeline document.
- Each expanded track renders up to four sub-rows — only the groups that
  actually have keyframes — each showing its segments as bars, indented under
  the parent, with the group name in the rail and a duration tooltip.

### Sub-rows are read-only in v1

Sub-row bars can be looked at, not dragged. One `MotionKeyframe` carries a
sparse subset of *several* props, so dragging one property's bar means
**splitting a keyframe in two** — the dragged props move to a new keyframe at
the new time, the rest stay behind. That is a change to how the document is
mutated, not a UI addition, and it is the kind of change that corrupts
timelines quietly.

v1 ships the reading tool, which is where the value is (seeing that a layer's
Scale has two separate animations while Opacity has one). Making them draggable
is a self-contained follow-up once the read view proves what people actually
want to grab.

To keep that honest, sub-row bars carry no drag affordance at all: no resize
handles, no grab cursor, `aria-disabled` where a segment bar would be a button.

### Tests

`blocks.propGroups.test.ts`: an `x`-only shake and a `scale`-only pulse on one
track produce one position segment and one scale segment, not two of each;
a keyframe carrying both `x` and `scale` appears in both groups; a group with
no keyframes returns `[]`.

`BlockTrackRow`/dock tests: the chevron appears only for tracks with keyframes;
expanding renders one sub-row per non-empty group; sub-rows expose no resize
handles.

---

## Cross-cutting

**Undo.** Every new mutation (`replaceSegmentPreset`, template apply) goes
through `useMotionEditorState`'s existing `push()` exactly once, so each is a
single undo step. Snapping changes the *value* a drag commits, not the number
of commits.

**Persistence.** `MotionTimeline` is unchanged — no `version` bump, no
migration of existing motion projects. Templates are a new, separate document
type in a new table. Features 1, 3 and 4 write nothing new to disk.

**Engine boundary.** `snap.ts`, `ticks.ts`, `templates.ts` and the additions to
`blocks.ts` / `presets.ts` stay free of KV imports; `importBoundary.test.ts`
enforces it.

**Analytics.** `frndos-analytics-events` runs over the finished web work before
this is called done — PostHog events are part of the feature, not an
afterthought.

**Test runner.** `web` tests run with `bun test` (bunfig preloads jest-dom), not
vitest. There is no type gate in the build (`ignoreBuildErrors` is on and `tsc`
has a large pre-existing baseline), so type regressions must be caught by
diffing against a baseline worktree rather than by a clean `tsc` run.

**Worktrees.** `web/.worktrees/kv-motion-timeline-upgrades` and
`api/.worktrees/kv-motion-timeline-upgrades`, both on
`feature/daffa/vc-kv-motion-timeline-upgrades` cut from `origin/develop`. The
web worktree needs its own `bun install` before `bun run build` — Turbopack
rejects a `node_modules` symlink to the parent checkout.

## Build order

1. **Feature 1** — self-contained, smallest, and immediately useful.
2. **Feature 3** — the ticks extraction is a pure refactor; snapping lands on
   top of the drag code Feature 1 leaves alone.
3. **Feature 4** — engine helper plus a display row; touches no mutation path.
4. **Feature 2** — largest, spans both repos, and is the only one needing a
   migration.

Nothing in 2–4 depends on 1; the order is by risk and size, so the useful parts
land early.
