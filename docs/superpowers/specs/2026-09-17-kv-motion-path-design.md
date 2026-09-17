# KV Motion — Path channel: an editable curve a layer follows

**Date:** 2026-09-17
**Author:** Daffa (with Claude)
**Status:** approved design, not implemented
**Services:** web only (api stores `timeline` opaquely — `array` + `MaxJsonBytes`, no inner validation)
**Depends on:** `2026-08-31-motion-build-tab-design.md` (Build tab, revived 2026-09-17 on `feature/daffa/vc-motion-build-tab`), `2026-09-14-kv-motion-canvas-transform-design.md` (Transformer, onion-skin, camera-scale compensation, auto-preview badge)

---

## Problem

The Build tab composes a layer's animation from property channels — Move,
Rotate, Scale, Opacity. Move is a straight line: the sampler interpolates
x and y independently between two keyframes, so the only shape a layer can
travel is a segment (or a polyline, one keyframe per corner, all sharp).

Every mainstream motion tool offers **Path**: a smooth curve the layer
follows, shaped by dragging points on the canvas, with its own duration and
easing, living on the timeline as one block. That is the fifth Build option
and the one the current model cannot express.

Two ways were considered and one ruled out:

- **Bake** the curve into ~10 x/y keyframes. Zero engine change, but the path
  is not editable afterwards (redraw to change one point), and the dock fills
  with diamonds that mean nothing to the user. Rejected — the reference UX
  ("Drag the points on the canvas to shape the path", "Add new point") is an
  editable object, and baking cannot give that.
- **Store the curve** on the keyframe it leads into. This spec.

## Verified on `develop` (2026-09-17)

- `src/lib/video-editor/timeline.ts` — `MotionKeyframe = { t_ms, props: Partial<MotionProps>, easing, label? }`. Persisted; api stores it opaquely (`StoreKvMotionProjectRequest`: `'timeline' => ['required', 'array', new MaxJsonBytes]`).
- `src/lib/video-editor/sample.ts::sampleTimelineAt` — per-property, sparse: for each prop it filters the keyframes carrying that prop, finds the surrounding pair `(a, b)`, applies `EASINGS[b.easing](frac)`, lerps. x and y are resolved **independently**.
- `motion/exportMotion.ts::remapTimelineForRatio` — per-tile remap is a pure **delta-shift** of keyframed x/y (`props.x += deltaX`). Nothing else about the keyframe is touched.
- `src/lib/video-editor/presets.ts::applyBuildChannels` (branch) — per-slot window (`in` `[0, 500]`, `out` `[dur−500, dur]`, `emphasis` `[atMs, atMs+min(600, room)]`), strips only the props it writes inside the window, merges by `t_ms`, stamps no label.
- `src/lib/video-editor/blocks.ts::segmentLabel` — a bar shows its keyframes' `label` if present, else the property list. `presetFamilyForLabel` returns `null` for unknown labels; the "Change motion" menu then falls back to the slot's family.
- `motion/KvMotionTileStage.tsx` — Transformer on the focused tile only; `transformerStyleForScale(cameraScale)` compensates handle sizes for the CSS camera scale; drag commit → `onOverlayTransformed` → `writeAutoKeyframes`.
- `motion/KvMotionEditor.tsx::shouldStartPan` — hit-tests the focused stage; a hit that is not an overlay node (or inside one) pans the camera.
- `motion/onionSkin.ts` — `path` = the keyframes carrying x or y, drawn as dots + straight segments.
- `MotionPresetGrid` (branch) — multi-select mode (`selectedIds` + `onToggle`) used by the Build tab.
- Every keyframe rewriter that moves x/y (`remapTimelineForRatio`, `bakeTemplateToTrack`, copy/paste offset in `overlayClipboard`, `duplicateMotionLayer`) shifts by a delta or copies the keyframe object whole.

## Decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Where Path lives | A **Build channel** card, top of the list, `NEW` badge | It is the fifth way to say "which property animates"; the slot chip gives it a window like every other channel |
| Path vs Move | **Mutually exclusive** within one Build; Path + Rotate/Scale/Opacity allowed | Both write x/y. Two writers of the same props in one action is a bug, not a feature |
| Point coordinates | **Deltas from the destination keyframe's x/y** | Every existing translator (tile remap, template bake, copy/paste, duplicate) shifts x/y by a delta or copies the object — a delta-based path survives all of them with zero new code |
| Curve | Catmull-Rom **through** the points (centripetal, α = 0.5) | Points sit on the curve, as in the reference UX; centripetal avoids cusps/loops when points are close |
| Controls | Click the "Path" block in the dock → popover | Matches the reference; the block is the object, so it is the entry point |
| Layer drag inside a Path window | **Blocked**, with a hint to drag the points | A mid-window auto-keyframe would cut the curve; splitting is more code and rarely what the user meant. Scale/rotate handles stay live (they never write x/y) |
| Tween type (Quart, Elastic…) | **Non-goal** | A new easing family touches the Inspector and the audio envelope too. `MotionEasing`'s four curves apply as they are |
| Orient layer to path direction | **Non-goal** | Rotation stays its own channel |
| Arc-length parametrisation | **Non-goal v1** (uniform per segment) | Speed varies with point spacing; revisit if it shows in real use |

## Design

### 1. Data model — `src/lib/video-editor/timeline.ts`

```ts
export type MotionPathPoint = { dx: number; dy: number };

export type MotionKeyframe = {
  t_ms: number;
  props: Partial<MotionProps>;
  easing: MotionEasing;
  label?: string;
  /** The curve x/y travel INTO this keyframe from the previous x/y keyframe.
   *  `points` are intermediate points as DELTAS from this keyframe's own
   *  (x, y), same normalized units; empty = straight line. Only meaningful
   *  when this keyframe carries BOTH x and y — a writer that strips either
   *  MUST drop `path` too (see `stripProps`). Additive and optional: every
   *  document written before this field is unchanged and reads the same. */
  path?: { points: MotionPathPoint[] };
};
```

No `version` bump: the field is optional and absent means "as before".

**Invariant — `path` ⇒ x and y present.** Today each writer strips props with
its own loop (`applyPreset`, `applyEmphasisPreset`, `applyBuildChannels`,
`replaceSegmentPreset`, lane ops in `blocks.ts`). This spec adds one helper,
`stripProps(keyframe, props)` in `timeline.ts` beside the type, that deletes the props and drops `path` when
`x` or `y` is among them, and routes every existing strip through it. That
is the one targeted refactor this feature makes to existing code.

**Label.** Both keyframes a Path channel writes are stamped `label: "Path"`
(added to the label namespace `presetFamilyForLabel` already reads; it maps
to `null`, i.e. no family, so "Change motion" keeps offering the slot's
family). `segmentLabel` therefore shows **Path** on the bar.

### 2. Curve math — `src/lib/video-editor/path.ts` (new, pure)

```ts
export function absolutePoints(dest: {x:number;y:number}, path): {x,y}[];
export function toDeltas(dest, abs: {x,y}[]): MotionPathPoint[];
/** Position at eased fraction `u ∈ [0,1]` along the curve start → …points → end. */
export function evalPath(start: {x,y}, end: {x,y}, points: MotionPathPoint[], u: number): {x,y};
/** Polyline for drawing: `n` samples of evalPath. */
export function samplePath(start, end, points, n = 32): {x,y}[];
/** Insert a point at the midpoint of the LONGEST sub-segment. */
export function insertMidpoint(start, end, points): MotionPathPoint[];
export function removePoint(points, i): MotionPathPoint[];
```

Centripetal Catmull-Rom over the control polygon `[start, ...abs, end]`, end
tangents by duplicating the endpoints. Uniform parametrisation: `u` maps to
segment `floor(u·N)` and local `t = u·N − i`. Zero points → plain lerp, so a
Path with no midpoints samples identically to today's linear x/y.

### 3. Sampler — `src/lib/video-editor/sample.ts`

When resolving `x`: with the surrounding pair `(a, b)`, if
`b.path` exists **and** `a` and `b` both carry x and y **and** the pair the
`y` filter would pick is the same `(a, b)` — then `evalPath(a, b, b.path.points,
EASINGS[b.easing](frac))` resolves x **and** y together and `y` is skipped.
Any condition failing → the existing per-prop lerp (silent degradation, never a
throw). The y-pair check matters: a hand-authored y-only keyframe between `a`
and `b` means x and y no longer share a segment, and the curve has no
consistent meaning.

Export, poster tiles, onion-skin poses and the Inspector's sampled values all
go through `sampleTimelineAt`, so they follow for free.

### 4. Build channel — `src/lib/video-editor/presets.ts`

`BuildChannelId` gains `"path"`, listed first: `["path", "move", "rotate",
"scale", "opacity"]`. `BUILD_CHANNEL_LABELS.path = "Path"`.

Default shape per slot (deltas are from the destination keyframe):

| Slot | Start | End | Midpoints |
| --- | --- | --- | --- |
| `in` | `(base.x − SLIDE_OFFSET, base.y)` | rest | 1: `{dx: −SLIDE_OFFSET/2, dy: −0.06}` — a gentle arc up into place |
| `out` | rest | `(base.x + SLIDE_OFFSET, base.y)` | 1: `{dx: −SLIDE_OFFSET/2, dy: −0.06}` |
| `emphasis` | pose at `atMs` | same pose | 2: `{dx: +0.05, dy: −0.05}`, `{dx: −0.05, dy: −0.05}` — a small swoop up and back |

Windows and room checks are those of every other channel. The end keyframe
gets `easing: "out"` like the edge channels. Both keyframes get `label:
"Path"`. Preview card: `buildChannelPreviewKeyframes("path", slot)` — the
grid's card samples through `sampleTimelineAt`, so the preview curves too.

**Exclusivity.** `MotionPresetGrid`'s multi-select gains an optional
`exclusive?: string[][]` (groups whose members cannot be selected together;
here `[["path", "move"]]`). Toggling a member on deselects its group-mates.
Declared in one place (`BUILD_EXCLUSIVE_GROUPS` beside `BUILD_CHANNEL_IDS`).

### 5. Dock — the Path popover

**Trigger:** left-click on a segment whose keyframes carry `label: "Path"`
(the segment's `keyframes` are already on `SegmentMenu`'s props). Right-click
keeps today's segment menu. Popover anchored to the bar.

`PathSegmentPopover` (`src/components/video-editor/`):

| Control | Writes |
| --- | --- |
| Duration (s) | `t_ms` of the end keyframe via the existing `stretchSegmentKeyframes`, clamped by the neighbouring segments exactly as a bar-edge drag is |
| Ease | `easing` of the end keyframe, from `EASING_OPTIONS` |
| Add new point | `path.points = insertMidpoint(...)` |
| Delete path | removes `path` **and** x/y from both keyframes (`stripProps`) — the layer stops moving; other props on those keyframes survive |

Every write goes through `push()` as one undo step. Plumbing mirrors
`onApplyBuild`: `TimelineDockProps.onEditPath?(trackId, endMs, patch)`, and
`useMotionEditorState.editPath`.

Selecting the popover also sets **the active path** (`{ trackId, endMs }`) in
editor state; closing it clears it. That is what the canvas reads.

### 6. Canvas — `motion/KvMotionTileStage.tsx` (focused tile only)

When an active path exists and belongs to an overlay on this tile:

- Draw the curve: a Konva `Line` from `samplePath(...)` in tile pixels
  (`(p.x + ov.width/2) * tile.width`, same centre convention as
  `applyTimeline`), dashed, on the base layer. Poster tiles: curve only, no
  handles — the same rule as the Transformer.
- Handles: one Konva `Circle` per point of `[start, ...mid, end]`, name
  `motion-path-handle`, `draggable: true`, radius and stroke scaled by
  `transformerStyleForScale(cameraScale)` so they stay ~10 px on screen at
  any zoom. Mid handles filled, endpoints hollow (they are keyframes, not
  path points).
- `dragmove` on a handle → redraw the curve live. `dragend` → commit:
  mid handle `i` → `path.points[i] = toDeltas(...)`; start handle → x/y of
  the start keyframe; end handle → x/y of the end keyframe **and** the
  deltas are left untouched (the whole curve translates with its
  destination — intended, that is the delta representation's point).
  Commit label `path:<overlay>:<i>` so a continuous drag collapses into one
  undo.
- Selected handle (last clicked) + `Delete`/`Backspace` → `removePoint`.
  Endpoints cannot be removed (use "Delete path").
- `shouldStartPan`: a hit on `motion-path-handle` is **not** a pan.
- While a path is active, the Transformer is **detached** from that overlay
  (a handle over an anchor would be ambiguous; the popover being open means
  the user is editing the path, not the pose). It re-attaches on close.
- Layer drag guard: while the playhead is strictly inside `(startMs, endMs)`
  of any Path segment on the selected overlay, that node is `draggable:
  false` and the existing auto-preview badge shows "Drag the path points to
  reshape". `transformend` (scale/rotate) is unaffected.
- Onion-skin: for a Path segment, `onionSkin.ts` returns the sampled curve
  instead of a straight segment between its two poses; ghost poses unchanged.

### 7. What needs no change (and is tested as such)

- `remapTimelineForRatio` — deltas ride along. Test: a Path on a 1:1 master
  samples to the shifted curve on a 9:16 tile.
- `bakeTemplateToTrack`, `duplicateMotionLayer`, overlay copy/paste — they
  copy keyframe objects; a test per site asserts `path` survives.
- Block/segment shift & stretch (`t_ms`-only ops) — untouched.
- Per-property lane ops that clear `label` — they keep `path` (the curve is
  geometry, not a preset stamp); the bar then reads `position` and the
  popover is no longer reachable by click, but the curve still plays. Called
  out as accepted: pulling a lane apart is already "I am now hand-editing".

## Testing

| File | Covers |
| --- | --- |
| `lib/video-editor/path.test.ts` | evalPath endpoints & symmetry, zero points = lerp, centripetal no-cusp on close points, delta↔absolute round trip, insertMidpoint picks the longest segment, removePoint |
| `lib/video-editor/sample.path.test.ts` | curve used when conditions hold; degrades to lerp when `a` lacks y, when a y-only keyframe sits between, when `path` is on a keyframe without x |
| `lib/video-editor/presets.buildChannels.test.ts` (+) | `"path"` per slot: window, labels, default points; `stripProps` drops `path` when x or y is stripped; Path + Move exclusivity at the grid level |
| `lib/video-editor/timeline.stripProps.test.ts` | every writer's strip goes through the helper (mutation: a keyframe with `path` loses it when x is stripped by each writer) |
| `motion/exportMotion.remap.test.ts` (+) | path survives tile remap and samples correctly |
| `templates.test.ts`, `duplicateMotionLayer.test.ts`, `overlayClipboard.motion.test.ts` (+) | `path` copied |
| `components/video-editor/TimelineDock.pathpopover.test.tsx` | click on Path bar opens popover; duration/ease/add/delete each emit one `onEditPath`; right-click still opens the segment menu |
| `motion/KvMotionTileStage.path.test.tsx` | (mocked Konva, as the Transformer tests) handles mounted for the active path only on the focused tile, mid-drag commits deltas, end-drag commits keyframe x/y, layer `draggable` false inside a Path window |
| `motion/onionSkin.test.ts` (+) | curved segment returned for a Path pair |

Tests are written first per task (TDD); expected numbers come from running
`evalPath`, not from hand-derivation — see
`lesson_plan_tests_written_from_reasoning_are_vacuous`.

## Analytics

- `kv_generator.motion_build_applied` already carries `channels[]`; `"path"`
  appears with no change.
- New `kv_generator.motion_path_edited { project_id, action:
  "drag_point" | "drag_endpoint" | "add_point" | "remove_point" | "duration" |
  "ease" | "delete" }` — whether people actually shape paths after adding
  them is the question that decides whether the handles were worth it.

## Non-goals

- Tween type (Quart / Elastic / Back …) — a new easing family.
- Orient-to-path rotation.
- Arc-length / constant-speed parametrisation.
- Splitting a path when the layer is dragged mid-window (blocked instead).
- Freehand drawing; path shape presets.
- Path on the Konva-free Fabric editor or on Resize — Motion only.

## Risks

- **Two invented default shapes** (the `−0.06` arc, the emphasis swoop) have
  no precedent to calibrate against; expect to tune after the first manual
  pass, like `BUILD_ROTATE_DEG` before them.
- **Handles + Transformer on the same tile.** Both are camera-compensated
  Konva nodes on the base layer; a handle sitting on a Transformer anchor is
  ambiguous. Mitigation: while a path is active, the Transformer is hidden
  for that overlay (the popover is open — the user is editing the path, not
  the pose).
- **`stripProps` refactor touches every writer.** Behaviour-preserving by
  construction (same deletes, plus dropping `path`), but it is the one place
  this feature edits code that already ships; the mutation test above is
  what makes that safe.
