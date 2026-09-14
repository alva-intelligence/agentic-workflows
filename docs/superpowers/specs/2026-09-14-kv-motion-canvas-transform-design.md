# KV Motion — animate from the canvas: scale/rotate handles, onion-skin, auto-preview

**Date:** 2026-09-14
**Author:** Daffa (with Claude)
**Status:** implemented 2026-09-14 — web branch `feature/daffa/vc-kv-motion-canvas-transform`, manual e2e passed (handles, auto-preview, export)
**Branch:** `feature/daffa/vc-kv-motion-canvas-transform` (web only)
**Services:** web

---

## Problem

The Motion editor already auto-keyframes a **drag**: moving an overlay on the
focused tile at playhead *t* writes `x/y` at *t* (plus the t=0 anchor rule) via
`KvMotionTileStage` → `onOverlayTransformed` → `writeAutoKeyframes`. But that is
the whole of what the canvas can author today:

1. **No scale / rotate on the canvas.** No `Konva.Transformer` is mounted
   (`KvMotionTileStage.tsx` says so in a comment); the `transformend` listener
   that would commit `scale`/`rotation` exists but nothing ever fires it. Scale
   and rotation can only be typed into the Inspector.
2. **Authoring is blind.** While dragging at t=2s the user sees only the
   current pose — nothing shows where the layer *was* at the previous keyframe
   or *will be* at the next. They have to scrub back and forth to read the
   motion they just made.
3. **No feedback that a keyframe was written**, and no cue that at t=0 a drag
   sets the base pose rather than animating. The diamond appears in the dock,
   where the user is not looking.

The goal of this branch: make "transform on the canvas" a real animation tool —
complete (scale + rotate), legible (onion-skin + path), and self-confirming
(auto-preview + badge).

## Verified on `develop` (2026-09-14)

- `src/lib/video-editor/timeline.ts` — `MotionProps = { x, y, scale, rotation, opacity }`; `scale` is one uniform number. Persisted contract; unchanged here.
- `src/lib/video-editor/autokey.ts::writeAutoKeyframes` — at t>0, the first write of a prop anchors it at t=0 with its pre-change value; at t=0 it just upserts the keyframe (base pose). Unchanged here.
- `motion/applyTimeline.ts` — nodes are center-offset by `buildBoardStage`; position = `(p.x + ov.width/2) * targetWidth`, scale on `scaleX/scaleY`, rotation in degrees.
- `motion/KvMotionTileStage.tsx` — imperative Konva stage per tile at the tile's own pixels, inside a CSS-transformed camera layer. Drag commit is `node.x()/tile.width - ov.width/2`. Selection is a `listening:false` Group of two dashed Rects (`motion-selection-outline`), rebuilt on every `sampled` change. Konva runtime is lazy-imported so the module loads in jsdom.
- `motion/KvMotionEditor.tsx::shouldStartPan` — hit-tests the focused tile's stage; a hit that is not (inside) an overlay node → returns `true` → the camera pans. A Transformer anchor would hit that branch.
- `motion/KvMotionEditor.tsx` playback loop — one rAF effect keyed on `state.playing`; bounds come from `state.previewRange` else `[0, duration_ms]`; `loop` wraps, else pauses at the end.
- `motion/motionTileDerived.ts::deriveTileTimelines` — per-tile remap of the master timeline (`TileTimelineData { tile, timeline, base }`); `sampleTilePoses` samples every tile at the playhead. Onion-skin must sample the **remapped** timeline so ghosts land right on every aspect.
- `useCanvasCamera` exposes `camera.scale` (the CSS scale of the camera layer).
- Analytics: no event exists for canvas-authored transforms (drag included).

## Design

### 1. Transformer — scale + rotate handles

**Where:** `KvMotionTileStage.tsx`, replacing the selection-outline Group.

- One `Konva.Transformer` (name `motion-transformer`) on the base layer, attached to the selected overlay's node **only on the focused tile**. Poster tiles never get one — the outline rule today, kept.
- `enabledAnchors`: the four corners only. `keepRatio: true`. Rationale: `MotionProps.scale` is uniform; side anchors would produce `scaleX ≠ scaleY`, which the document cannot store. Non-uniform scale is explicitly out of scope (it is a persisted-contract change: sampler, export, Inspector).
- `rotateEnabled: true`, `rotationSnaps: [0, 90, 180, 270]`, `rotationSnapTolerance: 5`.
- Hidden overlay → nothing. Locked overlay → the Transformer stays attached with resize/rotate disabled, so its border keeps acting as the selection outline (it is not hittable, so panning through a locked layer still works). *(Deviation from the first draft, which said "not attached when locked": the old outline also showed on locked layers, and losing all selection feedback on lock was worse.)*
- Commit: the existing `transformend` listener — `onOverlayTransformed(ov.id, { scale: node.scaleX(), rotation: node.rotation() })`. Because `keepRatio` holds, `scaleX === scaleY`. `writeAutoKeyframes` handles t=0 / anchor exactly as for drag.
- Position drift: Konva's Transformer moves the node's `x/y` while scaling around a corner. Since the node is center-offset and our pose is "center + uniform scale", the commit must send `x/y` too when they changed: `{ x, y, scale, rotation }` computed with the same formula as `dragend`. (Otherwise a corner-scale visually shifts the layer, then the next `applyTimeline` snaps it back.) Alternative considered: `centeredScaling: true` so the node's center never moves — simpler and matches the Inspector's semantics. **Decision: `centeredScaling: true`**, and commit **only the gestured prop** — `input === "rotate" ? { rotation } : { scale }`, where `input` comes from `Transformer.getActiveAnchor() === "rotater"` captured at `transformstart`. Committing both would write an anchor + a noise keyframe (Konva's matrix decompose leaves `1.0000000000000002`-style scale after a pure rotate) on a lane the user never touched. No modifier modes in this branch.
- **Camera-scale compensation.** The stage is CSS-scaled by the camera; at a fit scale of ~0.35 a 10 px anchor renders at ~3.5 px. The editor passes `cameraScale` (from `camera.scale`) as a prop; the stage sets `anchorSize`, `borderStrokeWidth`, `anchorStrokeWidth`, `rotateAnchorOffset` to `base / cameraScale` and updates them on change without re-attaching. Pure helper `transformerStyleForScale(scale)` returns the numbers (unit-tested).
- Live sync while a transform is in progress: the Transformer draws its own border, so the `dragmove` outline-glue code goes away with the outline.

**Pan guard** — `KvMotionEditor.tsx::shouldStartPan`: after `getIntersection`, walk ancestors; if any is a `Konva.Transformer` (`getClassName() === "Transformer"`) → `return false`. Extract the ancestor walk into a pure predicate `isPanBlockingHit(hit, overlayNodes)` so it can be unit-tested with fake nodes.

### 2. Onion-skin + motion path

**Derivation (pure)** — new `motion/onionSkin.ts`:

```ts
type OnionPose = { tMs: number; props: MotionProps };
type OnionSkin = {
  prev: OnionPose | null;   // nearest keyframe strictly before playhead (any prop)
  next: OnionPose | null;   // nearest keyframe strictly after playhead (any prop)
  path: OnionPose[];        // pose at every keyframe of the track that carries x or y, ascending
};
onionSkinFor(timeline: MotionTimeline, base: Map<string, MotionProps>,
             trackId: string, playheadMs: number): OnionSkin | null
```

- Returns `null` when the track is missing or has fewer than 2 keyframes.
- Poses come from `sampleTimelineAt(timeline, base, tMs)` — so easing and sparse keyframes resolve exactly as playback does.
- The editor calls it with the **focused tile's** `TileTimelineData` (remapped timeline + base), `selectedKeyframe.trackId`, `playheadMs`, in a `useMemo`. Result is passed to the focused `KvMotionTileStage` as `onion: OnionSkin | null`; every other tile gets `null`.

**Paint** — `KvMotionTileStage.tsx`, a new effect independent of selection:

- Prev ghost and next ghost: `node.clone({ listening: false, name: "motion-onion" })`, opacity 0.3 (prev) / 0.45 (next) — next is the destination, so it reads a touch stronger. Positioned with the same center-offset math as `applyTimeline` (extract `poseToNode(node, ov, props, targetW, targetH)` from `applyTimeline` and reuse it, so the two can't drift).
- Path: one dashed `Konva.Line` through the center point of every `path` pose, plus a `Konva.Circle` (r ≈ 4 / cameraScale) at each; the circle whose `tMs` equals the playhead is filled. All `listening: false`.
- Drawn only when: tile is focused, `onion` is non-null, `!playing`. Cleared otherwise (during playback the picture must be clean — it is what the export looks like).
- Rebuild key: `(prev?.tMs, next?.tMs, timeline identity, selectedOverlayId)`. Scrubbing between two keyframes does not re-clone; a drag in progress does not touch the ghosts (they are other keyframes' poses).
- Clone caveat to verify during implementation: image nodes clone by reference (fine); text nodes with custom fonts clone their attrs (fine). If `clone()` of a Group turns out expensive for large images, fall back to a ghost Rect of the node's client rect — the derivation and the path are unaffected.

### 3. Auto-preview + badge / HUD

**Auto-preview** — `useMotionEditorState.ts`:

- New UI state `previewOnce: { fromMs: number; toMs: number } | null` and `playOnce(fromMs, toMs)` which sets it and `playing = true`. Session-only, never persisted, never read by export (same class as `previewRange`).
- `togglePlay` clears it. User seeks clear it too, but the playback loop's per-tick `seek` must not: `seek` itself stays as is (the loop keeps calling it), and the hook exposes `seekByUser(t)` = clear `previewOnce` + `seek(t)`, which the editor wires to every user-facing seek (dock `onSeek`, transport, keyboard). `seek` keeps its current contract, so existing tests are untouched.
- Playback loop in `KvMotionEditor.tsx`: if `previewOnce` is set, bounds are `[fromMs, toMs]`, no wrap regardless of `loop`; reaching `toMs` → `seek(toMs)`, clear `previewOnce`, `setPlaying(false)`. Audio sync is untouched (it reads the playhead per tick).
- Trigger, in `useMotionEditorState.onOverlayTransformed` after the `push`: if `playheadMs > 0` and not already `playing`, `from = prev keyframe tMs on that track (any prop) ?? 0`; if `playheadMs - from >= 100` → `playOnce(from, playheadMs)`. At t=0 nothing plays (base pose edit).

**Badge** — a DOM element inside the focused tile's container (outside the Konva stage, `pointer-events: none`, top-left, inverse-scaled font so it stays legible), rendered only when an overlay is selected on that tile and `!playing`:

| State | Text |
|---|---|
| playhead = 0 | `Base pose` |
| playhead > 0, on a keyframe of the selected track | `⏺ Keyframe 2.4s` |
| playhead > 0, between keyframes | `Keyframe @ 2.4s` (dimmed) — "the next transform writes here" |

Pure `badgeLabel(playheadMs, track | null): { text, kind }` in `onionSkin.ts` (unit-tested). Time formatting reuses the dock's existing formatter.

**Live HUD** — during `dragmove` / `transform`, the badge's text is swapped for the live value, written straight to the element via ref (no React state per frame): drag → `x +24 · y −8` (tile px, delta from gesture start); scale → `1.25×`; rotate → `37°`. On `dragend`/`transformend` the badge returns to its state text on the next render.

### 4. Analytics

New event via the `frndos-analytics-events` skill:

`kv_motion_overlay_transformed { input: "drag" | "scale" | "rotate", at_t0: boolean, auto_preview: boolean }` — fired from `KvMotionEditor.handleOverlayTransformed`. `input` is decided by which listener fired (`dragend` → drag; `transformend` → `rotate` if rotation changed and scale did not, else `scale`).

### Undo

One undo step per gesture. The old `drag:${overlayId}:${playheadMs}` coalescing label was dropped: every gesture is exactly one push, and the label only ever merged *distinct* gestures at the same (overlay, t) — drag → scale → rotate at 2 s would have been one ⌘Z. `previewOnce`, onion-skin and badge are derived/UI state and never enter the undo stack.

## Not in scope

- Non-uniform scale (`scaleX/scaleY`) — persisted-contract change.
- Off-frame apron (drag a layer outside the tile to author slide-in/out) — separate spec.
- Modifier snapping (axis lock, 15° / 10% steps, snap to tile center).
- Dragging keyframe dots on the canvas path to edit position keyframes.
- Auto-key on/off toggle.

## Testing

Konva does not run under jsdom, so the stage itself is verified manually; everything derivable is a pure function with unit tests.

**Unit (bun test):**
- `onionSkin.test.ts` — `onionSkinFor`: prev/next selection around the playhead (strictly before/after; on-keyframe playhead), `path` only from x/y keyframes and ascending, `<2` keyframes → `null`, remapped per-tile timeline yields tile-space poses; `badgeLabel` for the three states.
- `KvMotionTileStage` helper — `transformerStyleForScale`: inverse scaling, clamped at a floor so a huge zoom-in does not produce sub-pixel anchors.
- `KvMotionEditor` helper — `isPanBlockingHit`: overlay node → blocks pan iff draggable; Transformer (or descendant) → blocks; base image / nothing → pans.
- `useMotionEditorState.test.ts` — `playOnce` sets state + playing; `seek`/`togglePlay` clear it; `onOverlayTransformed` at t>0 arms it from the previous keyframe (and from 0 when there is none), never at t=0, never while playing, never for a span < 100 ms.
- Playback loop: `previewOnce` overrides `previewRange` bounds and never wraps under `loop = true` (whatever harness the existing loop tests use).

**Manual (browser, focused tile):**
1. Select a layer at t=2s, drag a corner → two diamonds on the scale lane (0 and 2s), layer scaled around its center, one undo reverts both. Rotate → rotation lane; snaps near 90°.
2. Same at t=0 → single keyframe at 0, no auto-preview, badge reads "Base pose".
3. After the corner drag at t=2s the segment 0→2s plays once and stops at 2s; loop mode on does not make it repeat; pressing space mid-preview takes over normally.
4. With ≥2 keyframes, ghosts show prev/next poses and the dashed path; scrubbing between them does not flicker; ghosts vanish during playback and on poster tiles.
5. Zoom out to fit → anchors still grabbable; zoom in → not oversized. Pressing an anchor never pans the camera; pressing the base image still does.
6. Locked layer → no handles; hidden → nothing.
7. Badge/HUD: shows the three states; live numbers update while dragging/scaling/rotating.
8. Export an MP4 after a scale/rotate keyframe — matches the preview (no ghosts, no handles in the frame).
