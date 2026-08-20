# KV Motion — Multi-Tile Canvas — Design Spec

> **Status:** draft
> **Author:** daffa
> **Created:** 2026-08-20
> **Services:** web only
> **Topic slug:** kv-motion-multi-tile
> **Builds on:** `2026-08-02-kv-motion-timeline-editor-design.md`, `2026-08-05-kv-motion-output-size-design.md`, `2026-08-05-kv-motion-canvas-camera-design.md`

## Overview

A motion project animates exactly one output size today. `KvMotionSizePicker` is
a radio group: pick one, the project locks to it, the editor renders one stage,
the export dialog renders one row.

Resize does not work that way. There, the user picks many platforms at once and
gets a vertical list of tiles side by side, all derived from one master board.
The two surfaces sit one click apart in the same studio and disagree about
whether "pick sizes" means one or many.

This spec makes Motion match: choose several sizes at the entry point, see them
all on one canvas, author **one** animation, export **N** MP4s.

## Note on process

Daffa asked for a feasibility read and got one; the recommendation (phase the
work, ship shared-timeline first) was accepted. Decisions that would otherwise
have been asked one at a time are recorded under **Decisions taken without
asking**, each with its reasoning, so they can be reversed on review.

## Goals

1. Select **multiple** output sizes when creating a motion project.
2. Render every selected size as a tile on one pannable, zoomable canvas.
3. Author one animation that drives every tile.
4. Export one MP4 per tile, recorded as separate `kv_motion_exports` rows.
5. Open every existing single-size project unchanged, with no migration.

## Non-goals

- **Per-tile overlay override** ("this tile's logo sits lower"). Phase 2 — §10.
- **Per-tile timeline override** ("this tile's logo enters later"). Phase 3 — §10.
- **Adding or removing tiles after creation.** The tile set is chosen once, at
  creation. Changing it later is a follow-up; §10 records why the schema already
  allows it.
- **Any api change.** `snapshot` and `timeline` are opaque JSON on the api
  (`StoreKvMotionProjectRequest` validates `['required','array', new MaxJsonBytes]`
  with no nested key rules; `KvMotionProjectController::store` writes
  `$v['snapshot']` wholesale). Zero migrations, zero controller edits.
- **Touching Resize.** `KvResizeCanvas` and `KvResizeViewport` are not modified.
- **Simultaneous playback of every tile at full frame rate.** §6 explains the
  focus/poster model instead.

## 1. The central mechanism: one master, N derived tiles

The enabling property already exists in the codebase and is worth stating
plainly, because the whole design rests on it:

> `resolveTileOverlays` **preserves `overlay.id`** when projecting a master
> overlay onto a different aspect, and `MotionTimeline` tracks are keyed by
> `overlay_id`.

So a single timeline document already addresses every tile's overlays correctly.
No fan-out, no per-tile track duplication, no id remapping.

The three adapters this needs are all shipped and tested:

| Need | Existing function | Notes |
|---|---|---|
| Project master overlays onto a tile's aspect | `resolveTileOverlays` (`src/lib/studio/kv/overlayAspect.ts`) | The exact call Resize makes for its own tiles. Anchor-preserving projection, cluster grouping, coverage capping, canvas clamping, and `scaleTextStylingWithHeight`. |
| Same, wrapped for a snapshot | `remapSnapshotForRatio` (`motion/exportMotion.ts`) | Already used per-project; becomes per-tile. |
| Shift keyframed absolute x/y to match | `remapTimelineForRatio` (`motion/exportMotion.ts`) | Already used per-project; becomes per-tile. |
| Encode an arbitrary size | `exportMotionRatio({ id, w, h })` | Already accepts any `{id,w,h}`, not just `MOTION_RATIOS`. |

This spec adds no new geometry maths. It changes cardinality from 1 to N and
adds the UI to drive it.

## 2. Data model

### 2.1 Tile descriptors, not baked overlays

```ts
// src/types/kv/motionProject.ts

/** One output size inside a multi-tile motion project. */
export type KvMotionTile = {
  /** Stable react key + selection id. A `PlatformId`, or `"native"`. */
  key: string;
  platform_id: PlatformId | "native";
  /** Frozen at creation so the UI never re-derives it. */
  label: string;
  source: "resize" | "master" | "native";
  /** The image this tile animates: a finished resize tile, or the master board. */
  base_image_url: string;
  /** REAL output pixels — already through `videoSafeDims`. */
  width: number;
  height: number;
  /** Phase 2. Always `null` in phase 1. `null` = follow the master. */
  overlays: StudioOverlay[] | null;
  /** Phase 3. Always `null` in phase 1. `null` = follow the master timeline. */
  timeline: MotionTimeline | null;
};

export type KvMotionSnapshot = {
  // ── master (board space) — unchanged, still the source of truth ──
  base_image_url: string;
  board_width: number;
  board_height: number;
  overlays: StudioOverlay[];

  /** Multi-tile projects. Absent on every project created before this spec. */
  tiles?: KvMotionTile[];
  /** Single-size projects. Retained verbatim; never written for new projects. */
  target?: KvMotionTarget;
};
```

### 2.2 Do not persist projected overlays

`tiles[].overlays` stays `null` in phase 1 and the projection is recomputed at
render time via `resolveTileOverlays`. This is not laziness, it is a hard
constraint:

- `MaxJsonBytes::DEFAULT_MAX_BYTES = 524288` (512 KB) caps `snapshot`.
- `useMotionEditorState` autosaves on a 1.5 s debounce.

A KV with 20 overlays, projected and stored for 8 tiles, is 8× the overlay
payload on **every autosave**. That blows the cap on real work and does so
gradually enough that it would ship. Storing descriptors keeps the snapshot's
size a function of the master alone plus ~200 bytes per tile.

The same reasoning is why phase 2's per-tile override is `null` until the user
actually diverges a tile — exactly the semantics `KvResizeExport.overlays:
StudioOverlay[] | null` already has.

### 2.3 Backward compatibility, no migration

`resolveMotionTarget(snapshot)` already handles two generations of project
(with and without `snapshot.target`). It gains a third case and a plural
sibling:

```ts
// src/components/studio/kv-generator/motion/motionSnapshot.ts

/** Every tile this project renders and exports, newest schema first.
 *  Never returns an empty array. */
export function resolveMotionTiles(snapshot: KvMotionSnapshot): KvMotionTile[] {
  if (snapshot.tiles?.length) return snapshot.tiles;
  // Single-size project (with `target`) or pre-picker project (without):
  // `resolveMotionTarget` already covers both. Synthesize one tile from it so
  // every consumer below sees exactly one shape.
  const t = resolveMotionTarget(snapshot);
  return [{
    key: t.id,
    platform_id: (snapshot.target?.platform_id ?? "native"),
    label: t.label,
    source: snapshot.target?.source ?? "native",
    base_image_url: snapshot.base_image_url,
    width: t.w,
    height: t.h,
    overlays: null,
    timeline: null,
  }];
}
```

`resolveMotionTarget` is **kept, not replaced** — `KvMotionExportDialog` and the
editor's legacy paths call it, and one-tile projects must keep resolving
identically. Every new consumer calls `resolveMotionTiles`.

This is the same "synthesize the old shape, one code path, no migration"
approach `resolveMotionTarget` itself took for pre-picker projects.

## 3. The picker: radio group → checkbox group

`KvMotionSizePicker` keeps its layout (grouped scrollable list left, one
accurate preview right) and its three tiers from `buildMotionSizeOptions`
(`Same as board` / `From your resizes` / preset groups). `buildMotionSizeOptions`
itself is **unchanged** — it already returns everything needed.

What changes:

| Today | Multi-tile |
|---|---|
| `role="radiogroup"`, `role="radio"`, `aria-checked` | `role="group"` + `aria-label`, `role="checkbox"` per row, `aria-checked` |
| Roving `tabIndex`, Arrow keys move focus **and** selection | Roving `tabIndex`, Arrow keys move focus only; **Space toggles** |
| `selectedKey: string` | `checkedKeys: Set<string>` **and** `highlightedKey: string` |
| Footer: `Create motion · 1080×1080` | Footer: `Create motion · 3 sizes` |

**Highlight and check must be separate state.** The preview pane shows the
*highlighted* row; the checkboxes record what will be created. Merging them
(preview = last checked) means unchecking a row leaves the preview showing
something that is not in the set — and makes "look at this one before deciding"
impossible without also selecting it. Arrow keys move the highlight, Space
toggles the check, click does both (highlight + toggle).

Other picker rules:

- `native` starts checked, matching today's default. Nothing else does.
- Confirm is disabled when `checkedKeys` is empty.
- **Cap: 8 tiles.** Past the cap, unchecked rows go `aria-disabled` with the
  reason inline ("Up to 8 sizes per motion project"). §6 explains the cap.
- The existing preview cache (`Map<string, string>`, cleared on close) is
  untouched — it is keyed by option, and highlighting is still one row at a time,
  so the "one accurate preview" cost model from the output-size spec still holds.
- The `blocked` rule (a failed preview blocks creation only for a `resize`-source
  row, because that row is badged `Resized` and its thumbnail promises the tile)
  now applies to the **checked** set, not the highlighted row: creation is
  blocked if any *checked* resize-source row failed its preview. A highlighted-
  but-unchecked failure is informational.

`onConfirm` changes from `(option: MotionSizeOption)` to
`(options: MotionSizeOption[])`, ordered as the groups render them so the
canvas layout is deterministic.

## 4. Creation

`KvMotionProjectsPanel`'s `createMutation` builds the snapshot from N options
instead of one. `buildMotionSnapshot` gains a plural sibling in the same module:

```ts
export function buildMultiTileSnapshot(args: {
  options: MotionSizeOption[];
  nativeImageUrl: string;
  nativeWidth: number;
  nativeHeight: number;
  nativeOverlays: StudioOverlay[];
}): KvMotionSnapshot;
```

It writes the master fields from the board (`nativeImageUrl`, `nativeWidth`,
`nativeHeight`, `nativeOverlays` — *not* from any tile) and maps each option to a
`KvMotionTile` descriptor with `overlays: null, timeline: null`. It writes no
`target`.

`buildMotionSnapshot` (singular) stays exactly as it is. It is still the right
function for a one-size project and its tests pin behaviour this spec must not
change; `buildMultiTileSnapshot` is not a rename.

Analytics: `trackKvMotionProjectCreated` currently takes `platform_id` and
`base_source` (singular). It gains `tile_count: number` and both singular fields
become the **first** tile's, so existing dashboards keep reading a value rather
than `undefined`. A `platform_ids: string[]` field carries the full set.

## 5. Canvas layout

One `KvMotionTileStage` per tile, laid out horizontally in **world space**
(board pixels), bottom-aligned, with a fixed gutter:

```
world bbox
┌──────────────────────────────────────────────────────────┐
│  ┌────────┐  ┌────┐  ┌──────────────┐                    │
│  │ 1:1    │  │9:16│  │    16:9      │   … gutter 80px    │
│  │1080²   │  │    │  │              │                    │
│  └────────┘  │    │  └──────────────┘                    │
│              └────┘                                      │
└──────────────────────────────────────────────────────────┘
        ↑ bottom-aligned, so labels sit on one line
```

Horizontal, not Resize's vertical list: Motion's canvas is a free camera with a
timeline dock eating the bottom of the screen, so vertical space is the scarce
axis. Resize's list is a scrolling DOM column with no camera and no dock — the
constraint that shaped it does not apply here.

Each tile is a `Konva.Stage` at its **own** `width × height` (real output
pixels), positioned in world space by absolute CSS. Not one big stage with N
groups: the per-stage sizing is exactly what makes `node.x() / targetWidth`
drag-commit math and `applyTimeline`'s `targetWidth/targetHeight` arguments keep
working per tile with no changes.

Each tile carries a label chip above it (`Instagram Story · 1080 × 1920`) plus a
`Resized` badge when `source === "resize"`, mirroring the picker's own badge.

## 6. Performance: focus tile plays, others poster

This is the one genuinely hard constraint and the reason for the 8-tile cap.

Resize renders N static stages and never redraws them. Motion adds a
`requestAnimationFrame` playback loop that pushes an interpolated pose onto every
node every frame. At 8 tiles × 30 fps × K overlays, the naive extension drops
frames on a laptop.

**Focus model:**

- Exactly one tile is **focused** at a time. Click a tile to focus it; the first
  tile is focused on load. The focused tile has a visible ring.
- The focused tile is fully live: overlay drag, selection, and full-rate
  playback.
- Unfocused tiles are **poster tiles**: they render the pose at the current
  playhead, but their `applyTimeline` + `batchDraw` is throttled to ~10 fps
  during playback via a shared rAF budget, and updates immediately (untrottled)
  when the playhead settles — scrub end, pause, keyframe edit.
- Overlay drag is only accepted on the focused tile. A press on an unfocused
  tile focuses it; it does not also begin a drag. (Phase 2 makes drags on a
  non-master tile meaningful; in phase 1 every tile drives the same master, so
  allowing drags anywhere would work but would make the phase-2 semantics change
  invisible and surprising.)

The throttle is a presentation detail. Export is unaffected — it renders every
tile at full fidelity in its own detached stage (§8).

**Cap rationale:** 8 tiles × 1920-longest-edge stages is ~8 canvases of up to
1920×1080. Beyond that, GPU memory and compositing cost stop being a throttling
problem and start being a "the tab dies" problem. 8 covers every realistic
campaign set (the social-media preset group a user would plausibly want at once)
with headroom.

## 7. Camera

`useCanvasCamera` is extended, **not** forked, and Craft's camera is still not
touched (that decision from the camera spec stands).

Today it takes `board: { width, height }`. It gains the ability to be handed a
**world bbox** — the union of the laid-out tiles plus gutters — as its `board`.
Everything downstream (`fitCamera`, `zoomAt`, `panBy`, the CSS transform, the
zoom pill) is already expressed in terms of an arbitrary rectangle and needs no
change.

Two things do need changing:

1. **`shouldStartPan`.** The current predicate hit-tests one stage
   (`stage.getIntersection` with pointer converted via the container's rect ÷
   its unscaled pixel size). It becomes: find which tile's container the pointer
   is inside, hit-test **that** stage, and return `true` (pan) if the pointer is
   in a gutter, on a label, or outside every tile. The per-tile conversion maths
   is identical to today's, just selected by container first.
2. **Refit trigger.** Fit re-runs when the *world bbox* changes, not when one
   board's dims change. In phase 1 the tile set is fixed at creation so this
   fires once, but writing it against the bbox is what makes phase-2 tile
   add/remove correct for free.

The camera spec's rules are preserved verbatim: fit does not re-run on pane
resize, camera state stays ephemeral and unpersisted, scale clamped 0.1–5.

## 8. Export: N rows, sequential renders

`KvMotionExportDialog` returns to a multi-row dialog. Its sequential-render
machinery was never removed — the code still iterates a ratios array and its
own doc comment says so ("internally the render still iterates a (one-element)
ratios array so the sequential-render machinery is unchanged from when this
dialog supported multiple ratios"). This is largely a revert plus a source
change.

- `RatioState` (`waiting | rendering | uploading | done | failed`, progress,
  retained `blob`) becomes `Map<tileKey, RatioState>`.
- The ratios array comes from `resolveMotionTiles(snapshot)` instead of
  `[resolveMotionTarget(snapshot)]`.
- **Renders stay strictly sequential.** WebCodecs allows one active
  `VideoEncoder` in practice and each render already saturates the machine;
  parallelising is not an optimisation, it is a way to fail slower.
- One shared `AbortController`. Cancel stops the in-flight render and skips the
  rest.
- **The retained-blob rule is per tile.** An upload failure on tile 3 must not
  cost tiles 1–2 their uploads, nor tile 3 its render. Each tile keeps its own
  blob, Retry, and "Download locally" — the spec rule "render time is never
  lost" now has to hold N times independently.
- Each finished tile writes its own `kv_motion_exports` row. That table has no
  unique constraint on `(project, ratio)`, so N rows per project need no schema
  change; `ratio` is already a free `string(16)` fed from `ratio.id`, which is a
  `PlatformId` for preset tiles.
- Audio is decoded and mixed **once**, before the loop, and the same
  `AudioBuffer` is passed to every tile. Re-decoding per tile is pure waste.
- The existing `beforeunload` guard covers the whole run, not one render.

`exportMotionRatio` itself is untouched. It is called once per tile with that
tile's `{ id, w, h }`, and it already does the per-tile snapshot and timeline
remap internally.

## 9. Testing

Same split the camera spec used: jsdom has no layout and no canvas 2D context,
so geometry and selection logic go in pure modules and the Konva work stays
behind DI seams.

**Pure, fully tested:**

- `resolveMotionTiles` — a `tiles` project returns them verbatim; a `target`
  project synthesizes exactly one tile matching `resolveMotionTarget`; a
  pre-picker project (neither field) does too; never returns `[]`.
- `buildMultiTileSnapshot` — master fields come from the board and never from a
  tile; every tile gets `overlays: null, timeline: null`; no `target` written;
  tile order matches option order; snapshot JSON for 8 tiles × 20 overlays stays
  well under 512 KB (a direct `MaxJsonBytes` regression guard, asserted on
  `JSON.stringify(...).length`).
- Tile world layout — bbox union, gutters, bottom alignment, single-tile case
  equals today's geometry.

**Behavioural (`@testing-library/react`, `within(document.body)`, never
`screen`):**

- Picker: Space toggles a row without moving the highlight; Arrow moves the
  highlight without toggling; the cap disables unchecked rows at 8; confirm
  disabled at 0; a failed preview on a *checked* resize row blocks confirm, on an
  unchecked one does not; `onConfirm` receives options in group order.
- Export dialog: N rows render; renders fire sequentially (assert call order on
  a stubbed `exportRatioFn`); a mid-run failure does not abort the remaining
  tiles; Cancel aborts the in-flight render and skips the rest; a tile's Retry
  re-uploads without re-rendering (assert `exportRatioFn` call count unchanged).
- Editor: clicking an unfocused tile focuses it and does not start a drag.

**Not tested, verified manually:** multi-stage paint cost, throttle smoothness,
and that an exported MP4 for a given tile is byte-identical to what the same
size produced as a single-tile project.

## 10. Forward compatibility with phases 2 and 3

The phase-1 schema is chosen so neither follow-up needs a migration or a
breaking change:

**Phase 2 — per-tile overlay override.** `tiles[].overlays` goes non-null the
first time a user edits that tile's layout directly, and stays `null` for every
tile still following the master. Rendering already reads "override, else project
the master", which is
`resolveTileOverlays(tile.overlays, master.overlays, …)` — literally the call
signature that function already has, with the override in its first argument.
"Push to all tiles" is then `tiles.map(t => ({ ...t, overlays: null }))`, the
same clear-the-snapshots operation `KvResizeCanvas` already performs, and should
reuse its confirm copy.

**Phase 3 — per-tile timeline override.** `tiles[].timeline` goes non-null and
the render/export path reads `tile.timeline ?? masterTimeline`. Autosave is the
open question there, not the data model: N timelines under one 512 KB cap needs
either a per-tile PATCH or a raised ceiling, and that is an api conversation.

**Tile add/remove after creation.** `tiles` is a plain array and §7's refit is
keyed on the world bbox, so adding one is a snapshot PATCH plus a refit. Left
out of phase 1 only because the picker would need a second mode ("add sizes to
this project"), which is UI work with no bearing on the model.

## 11. What must not change

- `buildMotionSizeOptions` — consumed as-is.
- `resolveTileOverlays`, `remapSnapshotForRatio`, `remapTimelineForRatio` — no
  signature or behaviour change; called N times instead of once.
- `exportMotionRatio` — builds its own detached stage per call; no canvas,
  camera, or focus state can reach it.
- `resolveMotionTarget` and `buildMotionSnapshot` — kept, still used by
  one-tile paths and pinned by their own tests.
- Overlay drag commit math (`node.x() / targetWidth …`) — per tile, unchanged.
- The api. No migration, no controller edit, no request-validation change.
- `KvResizeCanvas` / `KvResizeViewport` / `KvKonvaCanvas`.

## Decisions taken without asking

1. **One project holds N tiles; not N projects.** N projects means N timelines
   to keep in sync by hand, which is the entire problem the feature exists to
   remove.
2. **Tile descriptors, projected at render time — never baked overlays.**
   Forced by `MaxJsonBytes` (512 KB) against a 1.5 s autosave. §2.2.
3. **Phase 1 ships shared-timeline only.** It delivers "animate once, output
   many", which is ~90% of the value, without committing to override semantics
   that are easier to design once the multi-tile canvas actually exists.
4. **Horizontal world layout, not Resize's vertical list.** Vertical space is
   what the timeline dock consumes; Resize's column has no dock and no camera.
   §5.
5. **Focus tile live, others throttled posters.** The only model that keeps 8
   stages interactive. Presentation-only — export fidelity is untouched. §6.
6. **8-tile cap.** Beyond it the failure mode stops being jank and becomes a
   dead tab. §6.
7. **Extend `useCanvasCamera` with a world bbox rather than forking it.** A
   third camera implementation in this codebase would be one too many; the hook
   is already expressed over an arbitrary rectangle. §7.
8. **Highlight and check are separate picker state.** Merging them makes
   "preview before deciding" impossible. §3.
9. **Exports stay sequential.** WebCodecs allows one active encoder in practice;
   parallel renders fail slower, not faster. §8.
10. **`buildMotionSnapshot` and `resolveMotionTarget` are kept, not renamed.**
    Their tests pin single-size behaviour that must not drift, and every
    pre-existing project still resolves through them.

## Open questions

None. Every decision above is recorded rather than deferred.
