# KV Motion Bumpers — Design

**Date:** 2026-09-20
**Author:** daffa (with Claude)
**Status:** IMPLEMENTED 2026-09-20 on `feature/daffa/vc-kv-motion-bumpers` (api 7 commits, web 24 commits, both unpushed); manual e2e pending. Plans in `docs/superpowers/plans/2026-09-20-kv-motion-bumpers-{api,web}.md`
**Services:** api, web
**Source:** MFS live simulation session, 16 Sep 2026

## 1. Summary

A **bumper** is a logo lockup (e.g. Telkomsel → Simpati) that plays before
and/or after a motion asset. Today a user who wants one has to rebuild it
inside the composition by hand, on every project. This design adds:

- a **brand-level bumper library** — upload a static image or short video
  once, reuse it on every motion project of that brand;
- two **fixed slots per project**, `start` and `end`, that sit *outside* the
  main timeline, so adding, swapping or removing a bumper never touches a
  keyframe, an audio clip or a motion path;
- rendering through the **existing deterministic frame loop** — no ffmpeg,
  no server-side concat, one encoder pass per tile.

Decisions taken in the brainstorm (all "recommended" options):

| Question | Decision |
|---|---|
| Asset source | Brand library + per-project pick (api table + endpoints) |
| Slot model | Fixed: one `start`, one `end`. Dynamic / mid-roll is out of scope |
| Multi-tile | One asset per slot + `fit` (contain/cover) + background colour |
| Audio | Main audio stays on the main clock; a video bumper carries its own audio (mutable) |
| Transition | Hard cut only |
| Render path | Composite inside `drawFrame` (option A) — see §3.3 for why not remux (B) or server ffmpeg (C) |

## 2. Current state (what the design builds on)

- Export is a deterministic frame loop: `encodeTimelineToMp4` calls
  `drawFrame(tMs)` per frame on a detached Konva stage and muxes one
  `AudioBuffer` (`web/src/lib/video-editor/encode.ts`,
  `web/src/components/studio/kv-generator/motion/exportMotion.ts`).
- Audio is mixed offline by `renderAudioMix({ clips, durationMs })` from
  `{ source: AudioBuffer, audio: MotionAudio }` pairs
  (`web/src/lib/video-editor/audio.ts`).
- `kv_motion_projects.timeline` is **opaque JSON** in the api
  (`KvMotionProjectController` only clamps the denormalised `duration_ms` /
  `fps`). Adding a field to the timeline needs no migration.
- `kv_motion_templates` is the precedent for a brand-scoped, reusable Motion
  asset: `workspace_id`, `brand_id`, `created_by`, `name`, opaque `body`,
  soft deletes, index on `(workspace_id, brand_id, deleted_at)`; routes hang
  off `files/{file}/motion-templates`.
- The editor has no video layer type; overlays are text/image/shape only.
- `mediabunny@^1.52.2` is already installed and exposes `Input` and
  `VideoSampleSink`, which is what frame-exact video decode needs.

## 3. Design

### 3.1 Data model — api: `kv_motion_bumpers`

Mirrors `kv_motion_templates` column for column where it makes sense.

```
id            ulid PK
workspace_id  → workspaces  (HasWorkspaceScope, cascade)
brand_id      → brands      (visibility scope, cascade)
created_by    → users       (cascade)
name          string
kind          string  'image' | 'video'
url           string  S3 public URL
duration_ms   unsigned int   video: natural length; image: 0
width         unsigned int   natural pixel size of the asset
height        unsigned int
timestamps, softDeletes
index (workspace_id, brand_id, deleted_at)  kv_motion_bumpers_scope_idx
```

Storage path: `brands/{brand_id}/motion-bumpers/{ulid}.{ext}` on the `s3`
disk. Brand-scoped, not file-scoped — the asset outlives any one KV.

Endpoints (`api/routes/api.php`, next to the template routes; brand is
resolved from the file, exactly as templates do):

| Method | Route | Body / result |
|---|---|---|
| `GET` | `files/{file}/motion-bumpers` | list of `KvMotionBumperResource`, newest first |
| `POST` | `files/{file}/motion-bumpers` | multipart `name`, `file`, `duration_ms`, `width`, `height` → the created resource |
| `DELETE` | `files/{file}/motion-bumpers/{bumper}` | soft delete → 204 |

Validation (`StoreKvMotionBumperRequest`):

- `file`: `required|file|mimes:png,jpg,jpeg,webp,mp4,webm|max:51200`
  (same 50 MB ceiling as overlay assets);
- `kind` is **derived by the api from the uploaded mime**, never trusted from
  the client;
- `duration_ms`, `width`, `height`: `required|integer|min:0`, clamped
  server-side (`duration_ms` ≤ 60 000; dims ≤ 8192). The api has no ffprobe;
  the client reads `<video>`/`<img>` metadata and sends it, the same
  "denormalised from the client's opaque document" contract
  `kv_motion_projects.duration_ms` already uses. For `kind = image`
  `duration_ms` is stored as 0.
- Because `excludeUnvalidatedArrayKeys` is on in api, every key the resource
  reads is listed explicitly — no nested `payload.*` rules.

Soft delete only. A project that already uses the bumper keeps rendering
because the slot copies `url` (§3.2). Hard S3 cleanup is not part of this
design.

### 3.2 Data model — web: `timeline.bumpers`

```ts
// web/src/lib/video-editor/timeline.ts
export type MotionBumper = {
  /** Library row this slot was filled from. Kept for "swap"/"deleted from
   *  library" UI only — rendering never reads it. */
  bumper_id: string;
  kind: "image" | "video";
  /** Copied from the library row at pick time. Export must keep working
   *  after the library row is soft-deleted. */
  url: string;
  /** image: 500–10 000, default 2000. video: ≤ `natural_ms` (a tail trim). */
  duration_ms: number;
  /** A video's natural length (0 for an image), copied from the library row
   *  so the clamp in `bumperLayout` needs no network. */
  natural_ms: number;
  src_width: number;
  src_height: number;
  /** default "contain" */
  fit: "contain" | "cover";
  /** hex, default "#000000"; only visible with fit = contain */
  bg: string;
  /** video only; default false */
  mute: boolean;
  /** video only; 0–1, default 1 */
  volume: number;
};

export type MotionTimeline = {
  // …unchanged…
  /** ABSENT = no bumpers. Every existing consumer's meaning is unchanged by
   *  construction: `duration_ms` is still the MAIN duration. */
  bumpers?: { start?: MotionBumper; end?: MotionBumper };
};
```

Invariants:

1. `timeline.duration_ms` **remains the main composition's duration**. No
   existing consumer changes meaning. `kv_motion_projects.duration_ms` (the
   denormalised list-row column) therefore also stays main-only.
2. `kv_motion_exports.duration_ms` is the MP4's real length = total.
3. Bumpers live on the master timeline only. `KvMotionTile.timeline` is
   still always `null` (Phase 3 unbuilt); when it is built it inherits these
   rules unchanged.
4. Keyframes, audio clips, volume envelopes and motion paths are **never
   rewritten** by any bumper operation. Anything that needs a total-clock
   view derives it in memory (§3.3, §3.5).

### 3.3 Time resolver — one source of truth

```ts
// web/src/lib/video-editor/bumpers.ts   (pure, no DOM)
export type BumperLayout = { preMs: number; mainMs: number; postMs: number; totalMs: number };
export function bumperLayout(t: MotionTimeline): BumperLayout;

export type BumperFrame =
  | { kind: "main"; mainMs: number }
  | { kind: "bumper"; slot: "start" | "end"; bumper: MotionBumper; localMs: number };
/** Total-clock time → what to draw. Half-open bounds:
 *  [0, pre) = start · [pre, pre+main) = main · [pre+main, total) = end.
 *  Clamps t into [0, total). */
export function resolveBumperFrame(t: MotionTimeline, totalMs: number): BumperFrame;

/** contain/cover geometry for a src box inside a dst box. */
export function fitRect(src: { w: number; h: number }, dst: { w: number; h: number }, fit: MotionBumper["fit"]): { x: number; y: number; w: number; h: number };

/** Where the dock draws the playhead, in px from the lane origin (the
 *  start zone begins at 0, the main lane at preMs·px). */
export function playheadAxisPx(layout: BumperLayout, playheadMs: number, preview: BumperPreview, pxPerSecond: number): number;
/** Total-clock readout for the transport: pre + playhead, or the zone's own offset. */
export function totalClockMs(layout: BumperLayout, playheadMs: number, preview: BumperPreview): number;
```

`bumperLayout` is the **only** place that enforces
`duration_ms ≤ natural video length` (older rows, edited library assets):
it clamps, callers never re-check. With no bumpers it returns
`{0, duration_ms, 0, duration_ms}` and `resolveBumperFrame` is the identity
(`{ kind: "main", mainMs: t }`), so a project without bumpers is provably
unchanged.

Why option A (composite in the frame loop) over the alternatives considered:

- **B — post-encode remux/concat without re-encoding** only works when the
  bumper's codec, resolution, fps and timescale match the output exactly.
  Users upload from anywhere, so it would need A as a fallback anyway, image
  bumpers still need encoding, and audio splicing is a separate problem.
- **C — server-side ffmpeg** adds a worker, an async job, storage round-trips
  and credits to a pipeline that is entirely client-side today. Overkill for
  a 2–3 s logo lockup.

### 3.4 Export (`exportMotionRatio`)

- `durationMs` handed to `encodeTimelineToMp4` = `layout.totalMs`.
- `drawFrame(t)`:
  - `resolveBumperFrame` → `main`: the existing path, called with `mainMs`
    (`layer.draw()` clears and repaints the whole canvas, so nothing a
    bumper frame painted survives).
  - `bumper`: painted **directly on the layer's backing canvas** with the 2D
    context — `fillRect(bg)` then `drawImage(source, fitRect(...))` — and
    `layer.draw()` is NOT called for that frame. No Konva nodes are involved,
    which keeps the bumper path free of node lifecycle and makes it testable
    with a recording context.
    - image: the preloaded `HTMLImageElement`.
    - video: `VideoSampleSink.getSample(localMs / 1000)` on a Mediabunny
      `Input` opened once per export (`openBumperVideo`, §3.4a); the
      sample's `toCanvasImageSource()` is drawn immediately, then the sample
      is `close()`d (Mediabunny requires it). Deterministic per frame; no
      `<video>.currentTime` seek.
- `openBumperVideo(url)` (§3.4a) wraps Mediabunny. Bytes are fetched ONCE
  through `fetchAudioForExport` (`cache: "no-store"` + same-origin proxy
  fallback) and handed to `new Input({ source: new BlobSource(blob), formats:
  ALL_FORMATS })` — never `UrlSource`: the preview `<video>` has already
  loaded the URL no-CORS and Chrome would serve that header-less cache entry
  to Mediabunny's own CORS range requests (the trap that once silenced export
  audio). Then `getPrimaryVideoTrack()` + `canDecode()`, `computeDuration()`,
  `getPrimaryAudioTrack() !== null` → `hasAudio`, one `VideoSampleSink`, the
  `blob` exposed for the audio decode, and `dispose()` at the end.
- Preload gate (existing pattern, before the stage is built):
  - image bumper → `loadImage(url)`;
  - video bumper → open `Input`, assert a decodable primary video track
    (`canDecode`), read metadata.
  - Any failure → `MotionAssetError("Start bumper" | "End bumper")`, so the
    dialog surfaces the same actionable message it does for a broken layer
    image instead of dying mid-render.
- `canExportMp4(needsAudio)`: `needsAudio` is now also true when any slot
  holds a **video bumper with `mute = false`** that has an audio track.
- Per-tile: the same `MotionBumper` renders on every tile; only `fitRect`'s
  `dst` changes.

### 3.5 Export audio

`renderAudioMix` is **not changed**. The export dialog builds a *derived*
clip list:

1. Every project clip (from `normalizeTimelineAudio`) is cloned with
   `start_ms += preMs` and each `volume_keyframes[].t_ms += preMs`.
2. For each **unmuted video bumper** that has an audio track: one synthetic
   clip `{ source: decoded AudioBuffer, audio: { start_ms: 0 | preMs+mainMs,
   trim_in_ms: 0, trim_out_ms: natural − duration_ms, volume, fade_in_ms: 0,
   fade_out_ms: 0 } }`. The source buffer is `AudioContext.decodeAudioData`
   of the SAME blob `openBumperVideo` fetched (Chrome decodes AAC-in-MP4 and
   Opus/Vorbis-in-WebM) — one download per bumper per export. "Has an audio
   track" is `openBumperVideo(url).hasAudio`; a bumper without one, or one
   whose audio fails to decode, contributes no clip and never drops the
   project's own audio.
3. `renderAudioMix({ clips, durationMs: totalMs })`.

The persisted document is never touched. A video bumper with no audio track
is treated as `mute = true` silently.

### 3.6 Editor preview

The editor's `playheadMs` stays on the **main clock** (`[0, duration_ms]`)
— it is read by sampling, audio sync, insert-keyframe, the dock and the
inspector, and none of those change. A bumper zone is previewed through one
extra piece of session-only state:

```ts
type BumperPreview = { slot: "start" | "end"; localMs: number } | null;
```

- `bumperPreview !== null` means "the user is looking at a bumper"; the main
  playhead is parked at `0` (start) or `duration_ms` (end) underneath it.
- Any user seek onto the main axis (dock scrub, transport field, keyboard)
  clears it. Clicking a bumper zone sets it (`localMs` from the click's
  fraction of the zone).
- The playback loop runs on the total clock and routes every tick through
  `resolveBumperFrame`: a `main` frame → `seek(mainMs)` + clear the preview;
  a `bumper` frame → set the preview and leave the main playhead parked.
  Preview-range and once-through playback are main-only and skip bumpers.
- `KvMotionTileStage` receives `bumperFrame: { bumper, localMs } | null`.
  When set, a `BumperOverlay` (bg + `<img>` or `<video currentTime =
  localMs>` sized by `fitRect`) covers the stage and swallows pointer events,
  so nothing underneath can be selected or dragged. For preview a plain
  `<video>` seek is fine — determinism is an export requirement only.
- Audio preview is unchanged (`audioWindowAt` keeps reading the main
  playhead). A video bumper's own audio previews through its `<video>`
  element, honouring `mute` / `volume`.

### 3.7 Editor UX

**Entry point — `Bumpers` button in the Transport bar.** The Transport never
scrolls or zooms away, unlike anything placed at the ends of a lane. It opens
a `BumperSlots` popover with two cards, **Start** and **End**.

- Empty card: `Choose bumper` → `BumperLibraryPicker`: thumbnail grid from
  `GET motion-bumpers` (name, image/video badge, duration), plus
  `Upload new` (client reads metadata → `POST` → the new row is selected
  immediately). Kebab → `Delete from library` with confirmation.
  Empty state: *"No bumpers yet for this brand — upload a logo lockup once
  and reuse it on every motion."*
- Filled card: thumbnail + name; `Duration` (image: 0.5–10 s; video: ≤
  natural, i.e. a tail trim); `Fit` contain/cover; `Background` swatch
  (shown for contain); `Mute` + volume (video only); `Remove`. `Swap` picks
  a different library item into the SAME slot: `fit`, `bg`, `mute` and
  `volume` are kept, while `url`/`kind`/dims/`natural_ms` come from the new
  row and `duration_ms` resets to the new asset's default (image 2000 ms,
  video natural). Only one tile's overlay is audible in preview (the focused
  one) so a multi-tile project does not play the bumper's audio N times.
- A slot whose `bumper_id` no longer exists in the library shows a
  *"deleted from library"* hint but keeps working.

**Timeline dock.** `TimelineRuler` and the lane container get
`paddingLeft = preMs·px` and `paddingRight = postMs·px`. Main ticks, all
lanes, keyframe bars and every existing drag/hit-test render **exactly as
today inside the padding**. The padding areas hold hatched zones labelled
`Start bumper · 2.0s` / `End bumper · 1.5s`; clicking one opens the popover
focused on that slot. Zones are not draggable or resizable in this version.
The playhead's x is `playheadAxisPx(layout, playheadMs, bumperPreview,
pxPerSecond)`: inside the start zone, `pre + main` offset, or inside the end
zone. Pointer→time math in every row is lane-relative today and stays
main-clock; nothing converts back from a total clock.

**Transport readout.** `totalClockMs / totalMs` — elapsed includes the
start bumper. The
duration input stays main-only, with the tooltip *"excludes bumpers"*.

**For free.** Undo/redo and autosave, because bumpers are part of `timeline`
and go through the same setter. The export dialog's displayed duration
becomes the total.

### 3.8 Analytics (PostHog)

Every web feature ships its events (`frndos-analytics-events`):

- `kv_motion_bumper_set` — `slot`, `kind`, `source: "library" | "upload"`,
  `duration_ms`, `fit`
- `kv_motion_bumper_removed` — `slot`, `kind`
- `kv_motion_bumper_library_uploaded` — `kind`, `duration_ms`, `bytes`
- `kv_motion_bumper_library_deleted`
- existing export event gains `has_bumpers: boolean` and `bumper_kinds`.

### 3.9 Error handling

| Situation | Behaviour |
|---|---|
| Upload > 50 MB or wrong mime | Client rejects first (`accept` + size check); api 422 as backstop; toast shows the api message |
| Client cannot read video metadata (`<video>` error / 0 duration) | Upload refused before sending: *"Couldn't read this video — try an MP4 (H.264)"* |
| Bumper asset 404 at export | Preload gate → `MotionAssetError("Start bumper")` |
| Video codec not decodable in this browser | Same gate, same error, before any frame is rendered |
| Video bumper has no audio track | Treated as muted; no synthetic clip |
| Stored `duration_ms` > natural length | `bumperLayout` clamps; nothing else re-checks |
| Library row soft-deleted while in use | Slot keeps `url`, renders normally, shows the "deleted from library" hint |
| Bumper video with alpha/odd dims | Drawn through `fitRect` like anything else; no special casing |

### 3.10 Testing

Runner is `bun test` (never `bunx vitest`). Lessons that apply: use
`within(document.body)` not `screen`; jsdom has no canvas context; a test
file past ~51 KB dies with a bogus SCSS error; `mock.module` is process-
global — no partial module mocks that other suites depend on.

- **Pure (required, TDD):** `bumperLayout` (none / start only / end only /
  both; video clamp), `resolveBumperFrame` (each half-open boundary, clamp
  below 0 and at `total`, identity without bumpers), `fitRect` (contain and
  cover, landscape-in-portrait and portrait-in-landscape, exact fit),
  `playheadAxisPx` / `totalClockMs` for main, start-zone and end-zone
  positions, derived audio clip shift
  (`start_ms`, `volume_keyframes.t_ms`, clip entirely past `totalMs`).
- **Export:** new file `exportMotion.bumpers.test.ts` (not appended to the
  existing 14.7 KB test) using the existing `deps` seam: encoder receives
  `totalMs`; `drawFrame` reaches the main path with `t − preMs`; video path
  is exercised with a fake `VideoSampleSink` whose `getSample` records
  timestamps and whose samples record `close()` calls; the preload gate
  throws `MotionAssetError` with the slot name.
- **Components:** `BumperSlots` (empty → picker; filled → controls; Remove;
  swap resets duration), `BumperLibraryPicker` (list, upload flow with
  mocked metadata read, delete confirm, empty state).
- **api:** unit tests for the request rules (mime, max, `kind` derivation,
  clamps) and the resource shape. A controller feature test is written but
  only runs against a scratch Postgres (SQLite cannot migrate this schema;
  note it in the plan).
- Numbers in tests are **derived by the implementer** and mutation-tested
  before going green — not dictated by the plan.

## 4. Out of scope (recorded as Future)

- ~~Fade / crossfade transitions~~ → **In/out transitions DONE 2026-09-21**
  on `feature/daffa/vc-kv-bumper-transitions` (web-only, no migration):
  `MotionBumper.in` / `.out` = `{ preset: fade | slide-left/right/up/down |
  pop, duration_ms }` (default 300, 100–2000, `in + out ≤ duration_ms` via
  `clampBumperTransitions`). One pure `bumperPose(bumper, localMs)`
  (`lib/video-editor/bumperPose.ts`) drives both `paintBumperFrame` (context
  transform over the unchanged fit rect, after the opaque bg fill) and
  `BumperOverlay` (opacity + % transform on the media element). This is an
  animation over the bumper's OWN bg — a true crossfade into the main
  timeline (two frames per tick) is still out of scope.
- More than one bumper per side, or mid-roll bumpers (would require
  splitting the main timeline — conflicts with the no-rebuild requirement).
- Per-ratio asset variants in the library.
- Drag-resizing bumper zones on the ruler.
- Bumpers on the Share page — Share plays exported MP4s, so they are included
  automatically.
- Hard deletion / S3 cleanup of library assets.

## 5. Open questions (for MFS)

1. Do they need **per-ratio variants** of a bumper (separate 1:1 / 9:16 /
   16:9 files), or is one center-safe lockup with `contain` + background
   enough? The library schema can grow a `variants` JSON later.
2. Default duration for an **image** bumper — 2 s assumed.
3. Should the end bumper be allowed to be the **same** library item as the
   start bumper (assumed yes; nothing prevents it).
