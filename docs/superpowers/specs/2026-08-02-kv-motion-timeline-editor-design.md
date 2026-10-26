# KV Motion Timeline Editor — Design Spec

> **Status:** draft
> **Author:** daffa
> **Created:** 2026-08-02
> **Services:** web, api (ai-service untouched)
> **Topic slug:** kv-motion-timeline-editor
> **Supersedes:** `2026-06-23-kv-motion-generation-design.md` (I2V Motion — frozen behind flag, not deleted)

## Overview

Replace the current KV Motion (image-to-video via `generate_video`) with a
**deterministic timeline editor** that animates the KV's overlay layers over a
frozen base image and exports MP4 **entirely client-side** (Konva + WebCodecs
via Mediabunny). No video model, no AI in the render path, zero generation
cost, frame-exact repeatable output.

Rationale: users now do heavy overlay work in KV (PSD import brings in dozens
of text/image/shape layers). The old I2V path threw all of that away — the job
sent `parentGeneration->image_url` (the bare generated base, no overlays) as
the first frame, so the user's composition never reached the video. Worse, I2V
models mangle typography and logos — exactly the content users just built.
Animating the overlays deterministically keeps them pixel-perfect by
construction.

The editor core is built as a **reusable motion engine + editor shell** so
upcoming video features (Storyboard→Video phase 3, video generation) inherit
the timeline UI and export pipeline via a small adapter interface. KV is the
first adapter.

## Decisions locked during brainstorming

| Decision | Choice |
|---|---|
| Base image | **Frozen** — no Ken Burns, no plate video in v1 |
| Animatable properties | **x, y, scale, rotation, opacity only** — identical for text/image/shape, one code path |
| Editor | Full timeline editor, **full-page route** under the KV file (not a canvas mode) |
| Data | **Snapshot** of overlays at project creation — decoupled from the KV Yjs doc; explicit "Resync from KV" |
| Scope | One board per project → **multi-ratio export** (reuses `overlayAspect` cross-aspect anchors) |
| Audio | **One uploaded audio track**: trim, volume, fade in/out |
| Render/export | **Client-side**, Mediabunny → MP4/H.264, non-realtime frame stepping |
| Renderer | **One stage + time dimension**: refactor `renderHiddenStage`, no 5th overlay renderer |
| Keyframing | **Auto-keyframe** with t=0-as-base-pose and anchor-keyframe rules (below) |
| Old I2V Motion | **Frozen behind flag**: `show-kv-motion` turned off for all workspaces; code, `kv_motion_generations` table, and paid-for MP4s untouched |
| Reusability | Engine + editor shell are domain-free modules; KV is adapter #1 |

## Non-goals (v1)

- Moving base plate (Ken Burns / video plate) — the track-union leaves room, nothing implemented.
- Per-character text reveal, wipe masks, path-draw effects.
- Keyframing styling properties (color, gradient angle, blur, letterSpacing, blendMode).
- Collaboration / Yjs on motion projects — plain JSON, single editor.
- AI auto-choreography, board-level templates.
- Music library; only user upload.
- OffscreenCanvas / Worker export (noted as follow-up optimization, not prerequisite).
- Credit metering — client-side render costs us nothing; metering is a separate product decision if ever wanted.
- Deleting the old I2V code/tables (separate cleanup release if ever).

## Architecture

### Module layout (reusability contract)

```
web/src/lib/motion/                    ← ENGINE (pure, reusable)
  timeline.ts     MotionTimeline types; tracks as a discriminated union
  sample.ts       sampleTimelineAt + easing functions
  encode.ts       Mediabunny export loop (takes a drawFrame(t) callback)
  audio.ts        decode → OfflineAudioContext (trim/volume/fade) → AudioBuffer

web/src/components/motion-editor/     ← EDITOR SHELL (reusable, domain-free)
  TimelineDock, TrackRow, KeyframeDiamond, Playhead, Transport,
  RatioChips, ExportDialog, useTimelineCommands (undo/redo)

web/src/components/studio/kv-generator/motion/   ← KV ADAPTER (feature-specific)
  snapshot from KV overlays, buildBoardStage + applyTimeline,
  overlayAspect remap, persistence to kv_motion_projects, entry/route
```

**Import rule (enforced by a lint/import test, not discipline):**
`lib/motion` and `components/motion-editor` MUST NOT import anything from
`studio/kv`. The shell consumes a small adapter contract:

```ts
interface MotionSceneAdapter {
  tracks(): TrackDescriptor[];                    // id, name, icon, locked?
  renderPreview(container, ratio): SceneHandle;   // KV: buildBoardStage
  applyFrame(handle, sampled): void;              // KV: applyTimeline
  ratios(): RatioOption[];
  persist(timeline): Promise<void>;
}
```

Deliberately NOT generalized: persistence (each feature owns its table +
endpoints), snapshot semantics, presets. Those are domain. A future `clip`
track kind (video-as-layer, decoded via Mediabunny) has a reserved place in
the `TrackDescriptor` union and `timeline.version`, but is not implemented.

### Data model (api)

New table `kv_motion_projects`:

```
id, studio_file_id (FK), board_generation_id,
name,
snapshot     JSON   -- copied overlays + base_image_url + board ratio at creation
timeline     JSON   -- timeline document (below); web-defined, api stores opaquely
audio_url    nullable string
duration_ms  int    -- denormalized from timeline for listing; timeline JSON is source of truth
fps          int default 30   -- same
created_at, updated_at
```

Plus `kv_motion_exports`:

```
id, project_id (FK), ratio, url, width, height, duration_ms, created_at
```

Standard Studio CRUD controller; debounced PATCH autosave of `timeline` (same
pattern as overlay autosave). `snapshot` written once at create; "Resync from
KV" rewrites it from live overlays behind an explicit confirm. Audio and MP4
assets go through the existing overlay-asset upload path.

### Timeline document (core contract)

```ts
type MotionTimeline = {
  version: 1;
  duration_ms: number;                 // 1–30s
  fps: number;                         // default 30
  tracks: Array<{
    overlay_id: string;                // points into snapshot
    keyframes: Array<{
      t_ms: number;
      props: Partial<{ x; y; scale; rotation; opacity }>;  // sparse per property
      easing: "linear" | "in" | "out" | "in-out";          // easing INTO this keyframe
    }>;
  }>;
  audio?: { start_ms; trim_in_ms; trim_out_ms; volume; fade_in_ms; fade_out_ms };
};
```

- Keyframes are **sparse per property** — a keyframe may carry only `opacity`.
  This is what makes the t=0 anchor rule cheap.
- x/y/scale follow the existing normalized-to-board convention, so **one
  timeline is valid for every export ratio** via the existing `overlayAspect`
  remap.

### Core function

`sampleTimelineAt(timeline, overlays, t) → Map<overlayId, ResolvedProps>` —
pure function, no canvas, no DOM. Per-property interpolation between
keyframes, per-segment easing, clamp before first / after last keyframe. All
time logic lives here and is exhaustively unit-testable. Renderers know
nothing about time; they receive resolved values.

## Render pipeline

### One stage, two speeds

`renderHiddenStage` (web `components/studio/kv-generator/renderBoardStage.ts`)
is refactored into `buildBoardStage(opts)` which:

1. accepts `container?` — provided ⇒ visible stage (editor); absent ⇒ detached
   (export + existing callers),
2. returns `{ stage, nodeById: Map<overlayId, Konva.Node> }` instead of the
   stage alone.

Existing callers (Resize export, Craft "Original + overlays" download) keep
working through a thin wrapper with the old signature — `renderBoardStage.test.ts`
guards the refactor. New helper:

```ts
applyTimeline(nodeById, sampleTimelineAt(timeline, overlays, t))
```

sets `x/y/scaleX/scaleY/rotation/opacity` on each node then `layer.batchDraw()`.
Scale animates via Konva `scaleX/scaleY` around the node's center offset — NOT
by changing width/height — so text wrap is computed once from the snapshot and
never re-wraps per frame.

This is explicitly **not a 5th overlay renderer** — it adds a time dimension to
the existing 4th (shared export) renderer. See the 4-renderer drift lesson.

### Preview

`requestAnimationFrame` loop: `t` from clock → `applyTimeline`. Scrub = same
call with `t` from playhead. Audio preview via one `<audio>` element seeked to
the playhead — rough sync is fine for preview; export is what must be exact.

### Export (deterministic, non-realtime)

```
for frame i in 0..N:  t = i/fps
  applyTimeline(...)  →  layer.draw()
  await canvasSource.add(t, 1/fps)     // Mediabunny CanvasSource
```

on a **second stage built by the same function** at native resolution of the
target ratio (e.g. 1080×1920), from the snapshot remapped via `overlayAspect`.

- Before frame 0: await all fonts (`document.fonts`) + all overlay images
  loaded — deterministic by construction, no blank early frames.
- Audio: decode upload → `OfflineAudioContext` applies trim/volume/fade → one
  final `AudioBuffer` → Mediabunny `AudioBufferSource` (which is
  timestamp-less by design — fine, the buffer is already final).
- Mux: Mediabunny `Mp4OutputFormat`, video codec `avc` (H.264), audio **AAC
  via `@mediabunny/aac-encoder`** (most compatible). Mediabunny is MPL-2.0 —
  file-level copyleft, safe as a dependency; obligations only if we modify its
  files.
- Capability gate at editor mount via `canEncode()` — never fail mid-render on
  codec availability.
- Multi-ratio export loops selected ratios **sequentially** (memory), progress
  per ratio. Finished MP4s upload via overlay-asset path and are recorded in
  `kv_motion_exports` so old renders replay without re-rendering.
- Runs on the main thread in v1 (stage is DOM-bound); 5–10s × 1080p is
  acceptable. OffscreenCanvas + Worker = follow-up.

## Editor UI

### Entry & route

KV studio's **Motion** tab (replacing the old one) lists the file's motion
projects + "New motion" (board picker when multi-board; defaults to active
board). Opening a project navigates to the full-page route
`web/src/app/(dashboard)/studio/kv/[fileId]/motion/[projectId]`. Back returns
to the KV studio.

### Layout (approved via mockup)

- **Left rail** — layers, mirroring the KV Layers panel exactly (same z-order,
  names, per-type icons). Base shown but **locked** at the bottom: hiding it
  would make "why can't I move the photo" a support mystery; locked, the
  constraint explains itself.
- **Center** — visible Konva stage (the adapter's preview stage).
- **Right inspector** — playhead-aware: shows the five property values at
  current `t`. Playhead exactly on a keyframe ⇒ edit keyframe values + easing;
  between keyframes ⇒ sampled values read-only with a "make keyframe here"
  button. The user edits an overlay's values *at a time*, never the overlay.
- **Bottom dock** — one track row per overlay (order mirrors left rail),
  keyframe diamonds, ruler + draggable playhead, transport (Space =
  play/pause, loop toggle, `00:00.00 / 00:05.00`, fps display), duration input
  (1–30s; shrinking clamps out-of-range keyframes behind a confirm). Audio row
  at the bottom.
- **Top bar** — back, project name, ratio chips (1:1 / 9:16 / 16:9 …), Export
  button, "Saved" autosave indicator.

### Keyframing rules (auto-keyframe, approved)

- **At t=0, dragging = setting the base pose**, not animating. Sessions always
  open at t=0, giving a safe "lay it out first" phase for free.
- **At t>0, the first drag on a layer** writes TWO keyframes: one at the
  playhead (new values) and an **anchor at t=0** (old values) if none exists.
  Without the anchor, a lone keyframe at 0.8s produces no visible motion and
  reads as broken; with it, the drag immediately plays back as movement.
- **Playhead ≠ 0 indicator**: playhead line + canvas border switch to accent
  color — "you are editing inside time" is always visible.
- Undo is one step for the whole action (drag + any keyframes it created).
- Keyframe diamonds: horizontal drag moves `t_ms`, click selects (inspector
  shows values), `Delete` removes, double-click on a track row inserts a
  keyframe at that position from the currently sampled values.

### Presets as sugar, not a system

Per-layer dropdown in the left rail: *Fade in · Slide in (direction) · Pop in ·
Fade out · Slide out*. Picking one only **writes ordinary keyframes** into the
track (fade in = opacity 0→1 over 500ms from the insert time). No persistent
"preset state" — the user edits the resulting keyframes directly. A **Stagger**
toolbar button applies the chosen preset to all visible layers with a chained
delay following z-order — the fastest path from a 20-layer PSD to a
publishable animation in one click.

### Audio

Upload button on the audio row → store asset → static waveform drawn once
(decode → peaks). Dragging the clip body moves `start_ms`, edge handles trim,
a small popover holds volume + fade in/out.

### Undo / autosave

Editor-local undo/redo (command stack over the timeline document, `Cmd+Z`),
separate from KV undo. Debounced 1.5s autosave PATCH; "Saved" indicator in the
top bar.

### Ratios

Ratio chips swap the preview stage to that ratio (snapshot remapped via
`overlayAspect` on the fly; read-only with respect to the timeline — there is
only one timeline). Export dialog: check the ratios to render, per-ratio
progress, results listed in the same panel.

## Error handling

- **Capability gate up front.** `canEncode("avc")` (+ AAC extension) at mount.
  Failure ⇒ editor fully usable for authoring; only Export is disabled with a
  browser-support message.
- **Asset load failure** (missing font, image 403) ⇒ export blocked before
  frame 0 with a message **naming the layer/font**; preview shows a
  placeholder for failed images.
- **Cancelable export** (AbortController): second stage destroyed, Mediabunny
  output discarded, no half-state. `beforeunload` warning while exporting.
- **MP4 upload failure** ⇒ local blob kept; retry or direct download from the
  blob. Paid-in render time is never lost.
- **Autosave failure** ⇒ warning banner + backoff retry; local document stays
  source of truth until saved.
- **Undecodable audio** ⇒ rejected at upload, not at export.
- **Resync from KV** ⇒ explicit confirm + warning that tracks whose overlays
  were deleted in KV are dropped; keyframes for still-existing overlay ids are
  preserved.

## Testing

- `sampleTimelineAt` — densest pure unit suite: interpolation, sparse props,
  per-segment easing, edge clamps, t=0 anchor rule. No canvas (jsdom lesson).
- `applyTimeline` — tests read the **live Konva node**
  (`layer.findOne(...).opacity()`), not DOM assertions — the 4-renderer drift
  lesson formalized as tests.
- `buildBoardStage` refactor guarded by existing `renderBoardStage.test.ts` +
  a new test that the legacy wrapper produces identical node configs.
- Export loop tested with a mocked `CanvasSource` (timestamp sequence, frame
  duration, await-per-add).
- Import-boundary test: `lib/motion` + `components/motion-editor` contain no
  `studio/kv` imports.
- api: request validation + policy tests; run with
  `API_INTERNAL_TOKEN=test-token` (known env gotcha).
- Web runner is `bun test` (NOT vitest); build gate is `bun run build`.

## Rollout

- New PostHog flag `show-kv-motion-editor`; old `show-kv-motion` turned off
  for all workspaces in the same release (I2V code left in place).
- Land order: **api first** (table + endpoints), web second — web without api
  only fails at project creation, breaks nothing else.

## Open questions

None — all forks resolved during brainstorming (see decision table above).
