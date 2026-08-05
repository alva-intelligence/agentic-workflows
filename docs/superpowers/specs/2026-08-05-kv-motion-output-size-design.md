# KV Motion — Output Size at the Entry Point — Design Spec

> **Status:** draft
> **Author:** daffa
> **Created:** 2026-08-05
> **Services:** web only (api untouched — `snapshot` is opaque JSON)
> **Topic slug:** kv-motion-output-size
> **Builds on:** `2026-08-02-kv-motion-timeline-editor-design.md`

## Overview

Today a motion project's output size is implicit. `KvMotionProjectsPanel`
creates a project straight from the active board, freezing
`board_width`/`board_height` from a fixed three-entry lookup table
(`ARTBOARD_RATIO_BOARD_DIMS` — 1:1 1024², 16:9 1024×576, 9:16 576×1024).
The user never chooses; the export dialog later offers three generic ratios
(1:1 1080², 9:16 1080×1920, 16:9 1920×1080) unrelated to any platform.

The result: a user who has resized a KV to **Instagram Landscape 1080×566**,
is looking at that tile, and switches to Motion, has no way to say "animate
*that*". They get a project whose aspect came from the master board and whose
export lands on whichever of three ratios is closest.

This spec makes the output size an explicit, first-class choice **at the
moment the project is created**, drawn from the same platform presets the
Resize surface uses, and locks the project to it.

## Goals

1. "New motion" asks which size, offering the same ~31 presets Resize offers.
2. When a Resize result already exists for the chosen size, the motion project
   animates **that exact image** — not a re-crop of the master.
3. The exported MP4's pixel dimensions equal the chosen preset's (subject to
   the encoder-safety rule in §6).
4. The user sees what they are about to animate before committing.

## Non-goals

- Changing the render/encode pipeline. `exportMotionRatio` already accepts an
  arbitrary `{ id, w, h }` — no change needed there.
- Multi-size export from one project. One project, one size (§4).
- Any api change. Verified: `StoreKvMotionProjectRequest` validates `snapshot`
  as `['required','array', new MaxJsonBytes]` with **no nested key rules**, and
  `KvMotionProjectController::store` writes `$v['snapshot']` wholesale. New
  snapshot keys survive the round trip.
- Editing the size after creation. Want a different size, make another project.

## 1. Data model

`board_width`/`board_height` stop meaning "1024-max table entry for the board's
aspect" and start meaning **the target's real output pixels**. Every existing
consumer is already correct under that reinterpretation:

| Consumer | Uses dims as | Correct with real pixels? |
|---|---|---|
| `KvMotionEditor` (`nativeRatioId`) | aspect ratio | yes |
| `KvMotionExportDialog` (`nativeRatioId`) | aspect ratio | yes |
| `remapSnapshotForRatio` | source dims for projection | yes |
| `exportMotionRatio` | literal target pixels | yes — and now finally honest |

```ts
export type KvMotionSnapshot = {
  base_image_url: string;
  board_width: number;    // 1080
  board_height: number;   // 566
  overlays: StudioOverlay[];
  /** Preset this project is locked to. Absent on pre-spec projects. */
  target?: {
    platform_id: PlatformId | "native";
    label: string;                  // "Instagram Landscape"
    source: "resize" | "master";    // which constructor built the base
  };
};
```

`target` is additive and optional. §7 covers projects that lack it.

## 2. Entry point — the size picker

`New motion` opens a modal instead of firing `createMutation` directly.

**Left column — scrollable size list**

1. **`Same as board (native)`**, pinned at the top. Today's behaviour: the
   master board at its own aspect, dims from `ARTBOARD_RATIO_BOARD_DIMS`.
   Always present, always selectable, and the default highlight.
2. **`From your resizes`** — every platform with a Resize result in this file.
   Each row badged `Resized`.
3. **`Other sizes`** — the remaining `PLATFORMS`, under the same
   `Social Media` / `Print` / `Digital` group headings `platformsByGroup()`
   already produces for Resize.

Each row shows: label, `1080 × 566`, and a **cheap thumbnail** — the base image
in an aspect-correct box via CSS `object-fit: cover`. No overlay compositing,
no canvas, no per-row render.

**Right column — one accurate preview**

The highlighted row gets a large preview rendered once through
`resolveTileOverlays` with overlays composited, debounced ~150ms on highlight
change and cached per `platform_id` for the modal's lifetime. This is the
promise the picker makes: *Motion animates the picture in this preview.*

**Footer** — `Create motion · 1080×566`. Creation never waits on the preview:
the snapshot persists the base image's **URL**, not its pixels, so a
still-rendering preview is irrelevant to whether the project can be created.
The one exception is a base that has definitively failed to load — see §9.

Rationale for cheap-list + one-accurate-preview: a size list is scanned, not
studied. The list decision is about aspect and framing, which a CSS crop
conveys. Rendering ~31 composites to support a choice that resolves to one is
work discarded, incurred at dialog-open — the worst moment.

## 3. Snapshot construction — one struct, two constructors

```ts
buildMotionSnapshot(choice): KvMotionSnapshot
```

| Chosen row | `base_image_url` | `overlays` | dims |
|---|---|---|---|
| `native` | master board image | board overlays as-is | `ARTBOARD_RATIO_BOARD_DIMS[ratio]` |
| preset **with** a Resize tile | that tile's image URL | the tile's resolved overlays | preset W×H (§6-adjusted) |
| preset **without** a tile | master board image | `remapSnapshotForRatio(masterSnapshot, w, h)` | preset W×H (§6-adjusted) |

Both non-native paths already exist in the codebase: the tile resolution is
what `KvResizeCanvas` feeds its tile editors, and `remapSnapshotForRatio` is
what `KvMotionExportDialog` runs today for non-native ratios. This is one
struct with three constructors, not a new pipeline.

`target.source` records which branch ran, so the created project can be
explained later and the analytics event is meaningful.

## 4. Editor — the ratio chips are removed

`KvMotionEditor` currently renders 1:1 / 9:16 / 16:9 preview chips
(`KvMotionEditor.tsx:625`), where any non-native chip puts the canvas in a
read-only mode because "a drag there has no well-defined mapping back onto the
native board's coordinate space."

With the project locked to one size, that whole mechanism is dead weight:

- The preview always renders `board_width × board_height`.
- The canvas is **always** editable — the read-only non-native mode, and the
  caveat it existed to guard, are deleted.
- `activeRatioId` / `isNativeRatio` / `MOTION_RATIOS.find(...)` state goes away.

This is a net simplification of the editor, not added complexity.

## 5. Export dialog — one line instead of checkboxes

The multi-ratio checkbox list collapses to a single row naming the project's
locked size:

```
Instagram Landscape · 1080 × 566          [ Export ]
```

Everything else in that dialog is unchanged: sequential render, shared
`AbortController` for cancel, per-ratio progress, upload-on-completion via
`createMotionExport`, and retained-blob retry so render time is never lost on
an upload failure.

Because the snapshot is already at the target size, `exportMotionRatio`'s
internal remap collapses to `resolveTileOverlays`' same-aspect clone path — a
no-op in effect. No code is removed from `exportMotion.ts`; §7 still needs it.

## 6. Encoder-safe dimensions (correctness requirement)

The preset table was written for still-image resize output and contains sizes
H.264 cannot encode as-is. `encodeTimelineToMp4` passes canvas dimensions
straight to Mediabunny's `CanvasSource` with `codec: "avc"` and no dimension
guard, because the only three sizes that have ever reached it were 1080/1920.

Two classes of problem in `PLATFORMS`:

**Odd dimensions** — H.264 with 4:2:0 chroma subsampling requires even width
*and* height. Three presets violate this:

| Preset | Dims | Offending axis |
|---|---|---|
| `linkedin-post` | 1200 × 627 | height |
| `twitter-post` | 1200 × 675 | height |
| `facebook-video-cover` | 1250 × 463 | height |

**Oversized** — encodable in principle but far outside what a client-side
WebCodecs encode should attempt, and beyond common H.264 level limits:

| Preset | Dims |
|---|---|
| `youtube-channel-banner` | 2560 × 1440 |
| `ebook-cover` | 1600 × 2400 |
| `custom-tall` | 1280 × 3840 |

**Rule.** A single pure helper applied to every non-native choice:

```ts
/** Clamp a preset's dims to something an AVC encode can actually produce:
 *  scale down proportionally so the longest edge is ≤ 1920, then floor both
 *  axes to even. Aspect drift from the even-floor is ≤ 0.16% — imperceptible
 *  — and flooring (never ceiling) guarantees we stay under the level cap. */
export function videoSafeDims(w: number, h: number): { w: number; h: number };
```

Worked examples: `1200×627 → 1200×626`; `2560×1440 → 1920×1080`;
`1280×3840 → 640×1920`; `1080×566 → 1080×566` (untouched).

Presets are **never hidden** from the picker — hiding is more confusing than
adjusting. When `videoSafeDims` changes a preset's dims, the row says so:

```
YouTube Channel Banner    2560 × 1440 · video 1920 × 1080
```

The adjusted dims are what get written into the snapshot, so the preview, the
editor canvas, and the MP4 all agree on one number.

## 7. Pre-spec projects

A project whose snapshot has no `target` is read as locked to
`closestMotionRatio(board_width, board_height)` — the existing helper, already
used for exactly this defaulting. It yields a `MOTION_RATIOS` entry, which is a
`{id, w, h}`, which is all §4 and §5 need.

No compatibility branch, no data migration, no dual-mode UI. The feature is
Labs-gated behind `MAJOR_FEATURE_FLAGS.KV_MOTION_EDITOR` and marked
Experimental in the UI, so the affected population is opted-in users only, and
the inferred size matches what those projects would have exported anyway.

## 8. Analytics

Per the mandatory `frndos-analytics-events` convention, the existing
`trackKvMotionProjectCreated` gains two properties:

| Property | Values |
|---|---|
| `platform_id` | `PlatformId` or `"native"` |
| `base_source` | `"resize"` \| `"master"` \| `"native"` |

This answers the question the feature exists to serve: are people picking
platform sizes, and are they animating real Resize output or re-crops?

## 9. Error handling

| Failure | Behaviour |
|---|---|
| Resize tile image fails to load in the preview | That row only is blocked: the preview shows `Couldn't load this resize result — try re-running Resize for this size`, and `Create motion` is disabled while it is highlighted. Deliberately **not** a silent fallback to the master re-projection — the row is badged `Resized` and its thumbnail promises the tile, so quietly creating a master-based project would break the picker's one guarantee. Every other row stays selectable. |
| No active board at all | Unchanged: `New motion` stays disabled with today's tooltip. |
| Preset resolves to sub-16px on either axis after `videoSafeDims` | Not reachable with the current table (smallest is 360). Guard anyway: clamp to a 16px floor. |
| `isCodecSupported` gate already fails | Unchanged — the existing export-button gate fires before any of this. |

## 10. Testing

Unit tests, `bun test` (jsdom; no canvas context available — assert on data,
not pixels):

1. `videoSafeDims` — the three odd presets, the three oversized presets, an
   untouched preset, aspect preservation within tolerance, even-axis output,
   16px floor.
2. `buildMotionSnapshot` — all three constructors produce the right
   `base_image_url` / dims / `target`, and the master path's overlays equal
   `remapSnapshotForRatio`'s output.
3. Picker grouping — `native` pinned first, resized platforms in
   `From your resizes` and absent from `Other sizes`, groups ordered as
   `platformsByGroup()` returns.
4. Pre-spec inference — a snapshot without `target` resolves to the expected
   `closestMotionRatio` entry.

No e2e. Manual verification: resize a KV to Instagram Landscape, open Motion,
confirm the preset appears under `From your resizes` with the tile as its
preview, create, and confirm the exported MP4 is 1080×566.

## Open questions

None. The two judgement calls made without asking are recorded here as
decisions: `native` remains a first-class option at the top of the list, and
pre-spec projects are inferred rather than given their own UI branch.
