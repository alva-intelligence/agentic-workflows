# KV Motion Bumpers — web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Start/end bumper slots on a motion project, filled from the brand library, previewed in the editor and baked into every exported MP4 — without touching a single keyframe, audio clip or path.

**Architecture:** `timeline.bumpers` is an optional field on the persisted timeline; `duration_ms` keeps meaning "the main composition". One pure module (`lib/video-editor/bumpers.ts`) answers every time question (layout, which frame to draw at a total-clock time, fit geometry, where the dock's playhead goes). Export routes each frame through it and paints bumper frames straight onto the layer canvas (image element or a Mediabunny-decoded video sample); audio is a derived clip list so `renderAudioMix` is unchanged. The editor keeps its main-clock `playheadMs` and previews bumpers through a separate `bumperPreview` state. UI: a `Bumpers` button in the Transport opens a two-slot popover backed by the library picker; the dock shows hatched zones beside the main lane.

**Tech Stack:** Next.js 16 / React 19 / TypeScript, TanStack Query v5, Konva (export stage), mediabunny 1.52 (`Input`, `BlobSource`, `VideoSampleSink`), Web Audio `decodeAudioData` + `OfflineAudioContext`, PostHog, `bun test` (jsdom, RTL).

**Spec:** `docs/superpowers/specs/2026-09-20-kv-motion-bumpers-design.md`

## Global Constraints

- `timeline.duration_ms` stays MAIN-only. Total = `preMs + duration_ms + postMs`, computed only by `bumperLayout`.
- No bumper operation may rewrite `tracks`, `audio`, `audio_clips`, or any keyframe. Anything total-clock is derived in memory.
- Image bumper `duration_ms`: 500–10 000, default 2000. Video: ≤ natural length; `bumperLayout` is the only place that clamps.
- Bumper `fit` default `"contain"`, `bg` default `"#000000"`, `mute` default `false`, `volume` default `1`.
- Frame bounds are half-open: `[0, pre)` start, `[pre, pre+main)` main, `[pre+main, total)` end.
- Hard cut only. One bumper per side.
- Export bumper frames are painted on the layer's backing canvas with the 2D context; `layer.draw()` is not called on those frames. Video frames come from `VideoSampleSink.getSample`, never from `<video>.currentTime`.
- Tests run with `bun test <file>` (never `bunx vitest`). `within(document.body)` not `screen`. New test files, never appended to a file near 51 KB (`exportMotion.test.ts` is 14.7 KB + this plan adds a separate file; `useMotionEditorState.test.ts` — add a separate `useMotionEditorState.bumpers.test.ts`). No partial `mock.module` of a module other suites import (memory `lesson_bun_mock_module_binding_capture`).
- Numbers inside tests are derived by the implementer from the function under test and mutation-tested (flip one operator, confirm red) before the step is called green.
- Analytics: every new user action fires a PostHog event (Task 4); the export event gains `has_bumpers`.
- Branch `feature/daffa/vc-kv-motion-bumpers` from `develop` in the `web/` repo (a worktree with its own `bun install` and a copied `.env.local` — memory `lesson_web_worktree_needs_bun_install`). Commit format `<type>(web): …`, ending with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- Build is verified with `node node_modules/next/dist/bin/next build` (memory `lesson_web_bun_run_build_broken_use_node`); there is no type gate — run `bunx tsc --noEmit -p . 2>&1 | grep -c "error TS"` before and after and require no increase.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/lib/video-editor/timeline.ts` (modify) | `MotionBumper`, `MotionTimeline.bumpers` |
| `src/lib/video-editor/bumpers.ts` (create) | Pure: `bumperLayout`, `resolveBumperFrame`, `fitRect`, `playheadAxisPx`, `totalClockMs`, `bumperFromLibrary`, `BumperPreview` |
| `src/lib/video-editor/bumperAudio.ts` (create) | Pure: `shiftClipsForBumpers`, `bumperAudioClip` |
| `src/components/studio/kv-generator/motion/bumperVideoSource.ts` (create) | `openBumperVideo` — Mediabunny wrapper (BlobSource over the CORS-safe fetch) with DI seam |
| `src/lib/video-editor/bumperMetadata.ts` (create) | `readBumperFileMetadata(file)` — `<img>`/`<video>` metadata in the browser |
| `src/types/kv/motionBumper.ts` (create) | `KvMotionBumperRow` |
| `src/services/kv/motionBumpers.ts` (create) | `listMotionBumpers`, `uploadMotionBumper`, `deleteMotionBumper`, query keys |
| `src/lib/analytics/kv-generator-events.ts` (modify) | Four bumper events + `has_bumpers` on export |
| `src/components/studio/kv-generator/motion/exportMotion.ts` (modify) | Preload gate, per-frame router, bumper paint |
| `src/components/studio/kv-generator/motion/KvMotionExportDialog.tsx` (modify) | Total duration, derived audio, bumper audio decode, event props |
| `src/components/studio/kv-generator/motion/useMotionEditorState.ts` (modify) | `setBumper`, `bumperPreview`, `setBumperPreview`, seek clears preview |
| `src/components/studio/kv-generator/motion/BumperOverlay.tsx` (create) | The stage overlay (bg + img/video) |
| `src/components/studio/kv-generator/motion/KvMotionTileStage.tsx` (modify) | `bumperFrame` prop → `BumperOverlay` |
| `src/components/video-editor/types.ts` (modify) | `LANE_OFFSET_VAR`, `LANE_BOX_STYLE`, `BumperDock`, dock prop |
| `src/components/video-editor/{BlockTrackRow,TrackRow}.tsx`, `motion/KvMotionAudioRow.tsx` (modify) | Lane boxes use `LANE_BOX_STYLE` |
| `src/components/video-editor/Transport.tsx` (modify) | `elapsedMs`/`totalMs` readout + `bumpersControl` slot |
| `src/components/video-editor/TimelineDock.tsx` (modify) | Zones, offset var, playhead px, fit scale |
| `src/components/studio/kv-generator/motion/BumperSlots.tsx` (create) | Popover: two slot cards |
| `src/components/studio/kv-generator/motion/BumperLibraryPicker.tsx` (create) | Library grid + upload + delete |
| `src/components/studio/kv-generator/motion/KvMotionEditor.tsx` (modify) | Query/mutations, playback loop, codec gate, wiring |

---

### Task 1: Types + pure time module

**Files:**
- Modify: `src/lib/video-editor/timeline.ts` (after `MotionAudio`, before `MotionTimeline`)
- Create: `src/lib/video-editor/bumpers.ts`
- Test: `src/lib/video-editor/bumpers.test.ts`

**Interfaces:**
- Produces (all exported from `bumpers.ts`, pure, no DOM):
  - `type BumperSlot = "start" | "end"`
  - `type BumperLayout = { preMs; mainMs; postMs; totalMs }`
  - `bumperLayout(t: MotionTimeline): BumperLayout`
  - `type BumperFrame = { kind: "main"; mainMs } | { kind: "bumper"; slot; bumper: MotionBumper; localMs }`
  - `resolveBumperFrame(t: MotionTimeline, totalClockMs: number): BumperFrame`
  - `fitRect(src: {w,h}, dst: {w,h}, fit: "contain"|"cover"): {x,y,w,h}`
  - `type BumperPreview = { slot: BumperSlot; localMs: number } | null`
  - `playheadAxisPx(layout, playheadMs, preview, pxPerSecond): number`
  - `totalClockMs(layout, playheadMs, preview): number`
  - `bumperFromLibrary(row: { id; kind; url; duration_ms; width; height }): MotionBumper`
  - `IMAGE_BUMPER_MIN_MS = 500`, `IMAGE_BUMPER_MAX_MS = 10000`, `IMAGE_BUMPER_DEFAULT_MS = 2000`
  - `bumperDurationBounds(b: MotionBumper): { min: number; max: number }` — image: 500..10000; video: 100..natural, where natural = `b.natural_ms`.
- Note: `MotionBumper` gains `natural_ms` (video's natural length copied from the library row; `0` for image) so the clamp needs no network. This is an addition to spec §3.2 — record it there in Step 6.

- [ ] **Step 1: Add the types to `timeline.ts`**

Insert after the `MotionAudio` type, before `MotionTimeline`:

```ts
/** One bumper slot — a logo lockup played before (`start`) or after (`end`)
 *  the main composition. Lives OUTSIDE the main clock: `duration_ms` on the
 *  timeline is still the main composition only (see lib/video-editor/bumpers.ts
 *  for every total-clock derivation). */
export type MotionBumper = {
  /** Library row this slot was filled from — for the "swap" / "deleted from
   *  library" UI only. Rendering never reads it. */
  bumper_id: string;
  kind: "image" | "video";
  /** Copied from the library row at pick time so export keeps working after
   *  the row is soft-deleted. */
  url: string;
  /** image: 500–10 000, default 2000. video: ≤ `natural_ms` (a tail trim). */
  duration_ms: number;
  /** A video's natural length (0 for an image). Copied from the library row
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
```

And add to `MotionTimeline` after `audio_clips?`:

```ts
  /** Start/end bumpers (2026-09-20). ABSENT = none; every existing consumer's
   *  meaning is unchanged by construction — `duration_ms` is still the MAIN
   *  duration. Total-clock questions go through `bumperLayout`. */
  bumpers?: { start?: MotionBumper; end?: MotionBumper };
```

- [ ] **Step 2: Write the failing tests**

`src/lib/video-editor/bumpers.test.ts`:

```ts
import { describe, expect, it } from "bun:test";

import type { MotionBumper, MotionTimeline } from "./timeline";
import {
  bumperDurationBounds,
  bumperFromLibrary,
  bumperLayout,
  fitRect,
  IMAGE_BUMPER_DEFAULT_MS,
  playheadAxisPx,
  resolveBumperFrame,
  totalClockMs,
} from "./bumpers";

function image(over: Partial<MotionBumper> = {}): MotionBumper {
  return {
    bumper_id: "b-img",
    kind: "image",
    url: "https://x/lockup.png",
    duration_ms: 2000,
    natural_ms: 0,
    src_width: 400,
    src_height: 200,
    fit: "contain",
    bg: "#000000",
    mute: false,
    volume: 1,
    ...over,
  };
}

function video(over: Partial<MotionBumper> = {}): MotionBumper {
  return {
    ...image({ bumper_id: "b-vid", kind: "video", url: "https://x/s.mp4" }),
    duration_ms: 1500,
    natural_ms: 1500,
    src_width: 1920,
    src_height: 1080,
    ...over,
  };
}

const MAIN: MotionTimeline = { version: 1, duration_ms: 5000, fps: 30, tracks: [] };
const withBumpers = (start?: MotionBumper, end?: MotionBumper): MotionTimeline => ({
  ...MAIN,
  bumpers: { ...(start && { start }), ...(end && { end }) },
});

describe("bumperLayout", () => {
  it("is the identity layout when there are no bumpers", () => {
    expect(bumperLayout(MAIN)).toEqual({ preMs: 0, mainMs: 5000, postMs: 0, totalMs: 5000 });
    expect(bumperLayout({ ...MAIN, bumpers: {} })).toEqual({ preMs: 0, mainMs: 5000, postMs: 0, totalMs: 5000 });
  });

  it("adds a start bumper in front and an end bumper behind", () => {
    expect(bumperLayout(withBumpers(image()))).toEqual({ preMs: 2000, mainMs: 5000, postMs: 0, totalMs: 7000 });
    expect(bumperLayout(withBumpers(undefined, video()))).toEqual({ preMs: 0, mainMs: 5000, postMs: 1500, totalMs: 6500 });
    expect(bumperLayout(withBumpers(image(), video()))).toEqual({ preMs: 2000, mainMs: 5000, postMs: 1500, totalMs: 8500 });
  });

  it("clamps a video slot's duration to its natural length — the ONLY place that clamps", () => {
    const stale = video({ duration_ms: 9000, natural_ms: 1500 });
    expect(bumperLayout(withBumpers(stale)).preMs).toBe(1500);
  });

  it("never clamps an image (natural_ms is 0 for images)", () => {
    expect(bumperLayout(withBumpers(image({ duration_ms: 3000 }))).preMs).toBe(3000);
  });
});

describe("resolveBumperFrame", () => {
  const tl = withBumpers(image(), video()); // pre 2000, main 5000, post 1500

  it("is the identity without bumpers", () => {
    expect(resolveBumperFrame(MAIN, 1234)).toEqual({ kind: "main", mainMs: 1234 });
  });

  it("routes each half-open segment", () => {
    expect(resolveBumperFrame(tl, 0)).toMatchObject({ kind: "bumper", slot: "start", localMs: 0 });
    expect(resolveBumperFrame(tl, 1999)).toMatchObject({ kind: "bumper", slot: "start", localMs: 1999 });
    expect(resolveBumperFrame(tl, 2000)).toEqual({ kind: "main", mainMs: 0 });
    expect(resolveBumperFrame(tl, 6999)).toEqual({ kind: "main", mainMs: 4999 });
    expect(resolveBumperFrame(tl, 7000)).toMatchObject({ kind: "bumper", slot: "end", localMs: 0 });
    expect(resolveBumperFrame(tl, 8499)).toMatchObject({ kind: "bumper", slot: "end", localMs: 1499 });
  });

  it("clamps outside [0, total)", () => {
    expect(resolveBumperFrame(tl, -50)).toMatchObject({ kind: "bumper", slot: "start", localMs: 0 });
    expect(resolveBumperFrame(tl, 8500)).toMatchObject({ kind: "bumper", slot: "end", localMs: 1499 });
    expect(resolveBumperFrame(withBumpers(image()), 99999)).toEqual({ kind: "main", mainMs: 4999 });
  });

  it("hands back the slot's own bumper object", () => {
    const f = resolveBumperFrame(tl, 7100);
    expect(f.kind === "bumper" && f.bumper.bumper_id).toBe("b-vid");
  });
});

describe("fitRect", () => {
  it("contain: letterboxes a wide source in a square", () => {
    expect(fitRect({ w: 400, h: 200 }, { w: 1080, h: 1080 }, "contain")).toEqual({ x: 0, y: 270, w: 1080, h: 540 });
  });
  it("contain: pillarboxes a tall source in a wide frame", () => {
    expect(fitRect({ w: 1080, h: 1920 }, { w: 1920, h: 1080 }, "contain")).toEqual({ x: 656.25, y: 0, w: 607.5, h: 1080 });
  });
  it("cover: overflows the shorter axis, centred", () => {
    expect(fitRect({ w: 400, h: 200 }, { w: 1080, h: 1080 }, "cover")).toEqual({ x: -540, y: 0, w: 2160, h: 1080 });
  });
  it("exact aspect fills either way", () => {
    expect(fitRect({ w: 16, h: 9 }, { w: 1920, h: 1080 }, "contain")).toEqual({ x: 0, y: 0, w: 1920, h: 1080 });
    expect(fitRect({ w: 16, h: 9 }, { w: 1920, h: 1080 }, "cover")).toEqual({ x: 0, y: 0, w: 1920, h: 1080 });
  });
  it("degenerate source fills the frame instead of dividing by zero", () => {
    expect(fitRect({ w: 0, h: 0 }, { w: 100, h: 50 }, "contain")).toEqual({ x: 0, y: 0, w: 100, h: 50 });
  });
});

describe("playheadAxisPx / totalClockMs", () => {
  const layout = { preMs: 2000, mainMs: 5000, postMs: 1500, totalMs: 8500 };
  const pps = 100; // px per second

  it("main playhead sits after the start zone", () => {
    expect(playheadAxisPx(layout, 1000, null, pps)).toBe(300);
    expect(totalClockMs(layout, 1000, null)).toBe(3000);
  });
  it("start-zone preview sits inside the zone", () => {
    expect(playheadAxisPx(layout, 0, { slot: "start", localMs: 500 }, pps)).toBe(50);
    expect(totalClockMs(layout, 0, { slot: "start", localMs: 500 })).toBe(500);
  });
  it("end-zone preview sits after the main lane", () => {
    expect(playheadAxisPx(layout, 5000, { slot: "end", localMs: 250 }, pps)).toBe(725);
    expect(totalClockMs(layout, 5000, { slot: "end", localMs: 250 })).toBe(7250);
  });
  it("no bumpers = the old fraction", () => {
    const plain = { preMs: 0, mainMs: 5000, postMs: 0, totalMs: 5000 };
    expect(playheadAxisPx(plain, 2500, null, pps)).toBe(250);
  });
});

describe("bumperFromLibrary + bounds", () => {
  it("fills defaults for an image", () => {
    const b = bumperFromLibrary({ id: "r1", kind: "image", url: "u", duration_ms: 0, width: 4, height: 2 });
    expect(b).toEqual({
      bumper_id: "r1", kind: "image", url: "u", duration_ms: IMAGE_BUMPER_DEFAULT_MS, natural_ms: 0,
      src_width: 4, src_height: 2, fit: "contain", bg: "#000000", mute: false, volume: 1,
    });
    expect(bumperDurationBounds(b)).toEqual({ min: 500, max: 10000 });
  });
  it("a video starts at its natural length and is bounded by it", () => {
    const b = bumperFromLibrary({ id: "r2", kind: "video", url: "u", duration_ms: 3200, width: 16, height: 9 });
    expect(b.duration_ms).toBe(3200);
    expect(b.natural_ms).toBe(3200);
    expect(bumperDurationBounds(b)).toEqual({ min: 100, max: 3200 });
  });
});
```

- [ ] **Step 3: Run to verify they fail**

Run: `bun test src/lib/video-editor/bumpers.test.ts`
Expected: FAIL — cannot resolve `./bumpers`.

- [ ] **Step 4: Write `bumpers.ts`**

```ts
// ──────────────────────────────────────────────
// KV Motion — bumpers (start/end logo lockups)
// Pure time + geometry helpers. The ONLY module that turns `timeline.bumpers`
// into total-clock numbers; preview, dock, transport and export all read it.
// ──────────────────────────────────────────────

import type { MotionBumper, MotionTimeline } from "./timeline";

export type BumperSlot = "start" | "end";

export const IMAGE_BUMPER_MIN_MS = 500;
export const IMAGE_BUMPER_MAX_MS = 10000;
export const IMAGE_BUMPER_DEFAULT_MS = 2000;
/** A video bumper can be trimmed down to this; anything shorter is a flash. */
export const VIDEO_BUMPER_MIN_MS = 100;

export type BumperLayout = {
  preMs: number;
  mainMs: number;
  postMs: number;
  totalMs: number;
};

/** A slot's effective length. This is the one place a video's stored
 *  `duration_ms` is clamped to its natural length (older rows, edited
 *  assets); callers never re-check. */
function effectiveMs(b: MotionBumper | undefined): number {
  if (!b) return 0;
  const d = Math.max(0, Math.round(b.duration_ms));
  if (b.kind === "video" && b.natural_ms > 0) return Math.min(d, b.natural_ms);
  return d;
}

export function bumperLayout(t: MotionTimeline): BumperLayout {
  const preMs = effectiveMs(t.bumpers?.start);
  const postMs = effectiveMs(t.bumpers?.end);
  const mainMs = t.duration_ms;
  return { preMs, mainMs, postMs, totalMs: preMs + mainMs + postMs };
}

export type BumperFrame =
  | { kind: "main"; mainMs: number }
  | { kind: "bumper"; slot: BumperSlot; bumper: MotionBumper; localMs: number };

/** Total-clock time → what to draw. Half-open: [0, pre) start · [pre,
 *  pre+main) main · [pre+main, total) end. Clamps `t` into [0, total). */
export function resolveBumperFrame(t: MotionTimeline, totalClock: number): BumperFrame {
  const L = bumperLayout(t);
  const clamped = Math.min(Math.max(0, totalClock), Math.max(0, L.totalMs - 1));
  const start = t.bumpers?.start;
  const end = t.bumpers?.end;
  if (start && L.preMs > 0 && clamped < L.preMs) {
    return { kind: "bumper", slot: "start", bumper: start, localMs: clamped };
  }
  if (end && L.postMs > 0 && clamped >= L.preMs + L.mainMs) {
    return { kind: "bumper", slot: "end", bumper: end, localMs: clamped - L.preMs - L.mainMs };
  }
  return { kind: "main", mainMs: clamped - L.preMs };
}

/** contain / cover geometry for `src` inside `dst`, centred. A degenerate
 *  source (0×0) fills the frame rather than dividing by zero. */
export function fitRect(
  src: { w: number; h: number },
  dst: { w: number; h: number },
  fit: MotionBumper["fit"]
): { x: number; y: number; w: number; h: number } {
  if (src.w <= 0 || src.h <= 0) return { x: 0, y: 0, w: dst.w, h: dst.h };
  const sx = dst.w / src.w;
  const sy = dst.h / src.h;
  const s = fit === "contain" ? Math.min(sx, sy) : Math.max(sx, sy);
  const w = src.w * s;
  const h = src.h * s;
  return { x: (dst.w - w) / 2, y: (dst.h - h) / 2, w, h };
}

/** Session-only editor state: "the user is looking at a bumper zone". The
 *  main playhead stays on the main clock underneath it (parked at 0 for
 *  start, at duration_ms for end). */
export type BumperPreview = { slot: BumperSlot; localMs: number } | null;

/** Elapsed time on the total clock, for the transport readout. */
export function totalClockMs(layout: BumperLayout, playheadMs: number, preview: BumperPreview): number {
  if (preview?.slot === "start") return Math.min(preview.localMs, Math.max(0, layout.preMs - 1));
  if (preview?.slot === "end") return layout.preMs + layout.mainMs + Math.min(preview.localMs, Math.max(0, layout.postMs - 1));
  return layout.preMs + playheadMs;
}

/** Where the dock draws the playhead, in px from the lane origin (the start
 *  zone begins at 0; the main lane at preMs·px). */
export function playheadAxisPx(
  layout: BumperLayout,
  playheadMs: number,
  preview: BumperPreview,
  pxPerSecond: number
): number {
  return (totalClockMs(layout, playheadMs, preview) / 1000) * pxPerSecond;
}

/** Fill a slot from a library row with the spec defaults. */
export function bumperFromLibrary(row: {
  id: string;
  kind: "image" | "video";
  url: string;
  duration_ms: number;
  width: number;
  height: number;
}): MotionBumper {
  const isVideo = row.kind === "video";
  return {
    bumper_id: row.id,
    kind: row.kind,
    url: row.url,
    duration_ms: isVideo ? row.duration_ms : IMAGE_BUMPER_DEFAULT_MS,
    natural_ms: isVideo ? row.duration_ms : 0,
    src_width: row.width,
    src_height: row.height,
    fit: "contain",
    bg: "#000000",
    mute: false,
    volume: 1,
  };
}

export function bumperDurationBounds(b: MotionBumper): { min: number; max: number } {
  if (b.kind === "video") return { min: VIDEO_BUMPER_MIN_MS, max: Math.max(VIDEO_BUMPER_MIN_MS, b.natural_ms) };
  return { min: IMAGE_BUMPER_MIN_MS, max: IMAGE_BUMPER_MAX_MS };
}
```

- [ ] **Step 5: Run to verify they pass; mutation-check**

Run: `bun test src/lib/video-editor/bumpers.test.ts`
Expected: all pass. Then temporarily change `clamped < L.preMs` to `<=` — the `2000 → main 0` case must go red; revert.

- [ ] **Step 6: Record `natural_ms` in the spec**

In `docs/superpowers/specs/2026-09-20-kv-motion-bumpers-design.md` §3.2 add the `natural_ms` line to the `MotionBumper` block (same comment as the type). One-line change.

- [ ] **Step 7: Commit**

```bash
git add src/lib/video-editor/timeline.ts src/lib/video-editor/bumpers.ts src/lib/video-editor/bumpers.test.ts
git commit -m "feat(web): add MotionBumper type and pure bumper time/geometry module

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

(The spec edit is committed with the root-repo docs, not here.)

---

### Task 2: Derived export audio

**Files:**
- Create: `src/lib/video-editor/bumperAudio.ts`
- Test: `src/lib/video-editor/bumperAudio.test.ts`

**Interfaces:**
- Consumes: `BumperLayout` (Task 1), `MotionAudio`, `ResolvedMotionAudio` (`timeline.ts`).
- Produces:
  - `shiftClipsForBumpers(clips: ResolvedMotionAudio[], layout: BumperLayout): ResolvedMotionAudio[]` — clones with `start_ms += preMs` and every `volume_keyframes[].t_ms += preMs`. Never mutates.
  - `bumperAudioClip(bumper: MotionBumper, slot: BumperSlot, layout: BumperLayout): ResolvedMotionAudio | null` — `null` for image, for `mute`, or when the effective length is 0.

- [ ] **Step 1: Write the failing tests**

```ts
import { describe, expect, it } from "bun:test";

import { bumperAudioClip, shiftClipsForBumpers } from "./bumperAudio";
import type { MotionBumper, ResolvedMotionAudio } from "./timeline";

const layout = { preMs: 2000, mainMs: 5000, postMs: 1500, totalMs: 8500 };

const clip: ResolvedMotionAudio = {
  url: "https://x/song.mp3",
  start_ms: 1000,
  trim_in_ms: 0,
  trim_out_ms: 4000,
  volume: 0.8,
  fade_in_ms: 100,
  fade_out_ms: 200,
  volume_keyframes: [
    { t_ms: 1000, volume: 0.8, easing: "linear" },
    { t_ms: 3000, volume: 0.2, easing: "linear" },
  ],
};

const vid: MotionBumper = {
  bumper_id: "b", kind: "video", url: "https://x/s.mp4", duration_ms: 1500, natural_ms: 2400,
  src_width: 16, src_height: 9, fit: "contain", bg: "#000", mute: false, volume: 0.6,
};

describe("shiftClipsForBumpers", () => {
  it("shifts start_ms and every envelope point by preMs, cloning", () => {
    const out = shiftClipsForBumpers([clip], layout);
    expect(out[0].start_ms).toBe(3000);
    expect(out[0].volume_keyframes?.map((k) => k.t_ms)).toEqual([3000, 5000]);
    expect(out[0]).not.toBe(clip);
    expect(clip.start_ms).toBe(1000);
    expect(clip.volume_keyframes?.[0].t_ms).toBe(1000);
  });
  it("is a no-op clone with preMs 0", () => {
    const out = shiftClipsForBumpers([clip], { ...layout, preMs: 0 });
    expect(out[0]).toEqual(clip);
    expect(out[0]).not.toBe(clip);
  });
  it("leaves a clip without an envelope without one", () => {
    const { volume_keyframes: _k, ...bare } = clip;
    const out = shiftClipsForBumpers([bare], layout);
    expect("volume_keyframes" in out[0]).toBe(false);
  });
});

describe("bumperAudioClip", () => {
  it("start slot: plays from 0, trimmed to the effective length, at the slot volume", () => {
    expect(bumperAudioClip(vid, "start", layout)).toEqual({
      url: "https://x/s.mp4",
      start_ms: 0,
      trim_in_ms: 0,
      trim_out_ms: 1500,
      volume: 0.6,
      fade_in_ms: 0,
      fade_out_ms: 0,
    });
  });
  it("end slot: starts after the main composition", () => {
    expect(bumperAudioClip(vid, "end", layout)?.start_ms).toBe(7000);
  });
  it("uses the layout's clamped length, not the raw duration_ms", () => {
    const stale = { ...vid, duration_ms: 9000 };
    expect(bumperAudioClip(stale, "end", { ...layout, postMs: 2400 })?.trim_out_ms).toBe(2400);
  });
  it("is null for an image, a muted video, or a zero-length slot", () => {
    expect(bumperAudioClip({ ...vid, kind: "image" }, "start", layout)).toBeNull();
    expect(bumperAudioClip({ ...vid, mute: true }, "start", layout)).toBeNull();
    expect(bumperAudioClip(vid, "start", { ...layout, preMs: 0 })).toBeNull();
  });
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `bun test src/lib/video-editor/bumperAudio.test.ts` — FAIL, module missing.

- [ ] **Step 3: Write `bumperAudio.ts`**

```ts
// ──────────────────────────────────────────────
// KV Motion — bumper audio (export-time derivation)
// `renderAudioMix` is untouched: the export dialog hands it a DERIVED clip
// list built here. The persisted timeline never changes.
// ──────────────────────────────────────────────

import type { BumperLayout, BumperSlot } from "./bumpers";
import type { MotionBumper, ResolvedMotionAudio } from "./timeline";

/** Project clips moved onto the total clock: each starts `preMs` later, and
 *  so does every point of its volume envelope (envelope times are TIMELINE
 *  times — see `MotionVolumeKeyframe`). Clones; never mutates. */
export function shiftClipsForBumpers(
  clips: ResolvedMotionAudio[],
  layout: BumperLayout
): ResolvedMotionAudio[] {
  const d = layout.preMs;
  return clips.map((c) => {
    const next: ResolvedMotionAudio = { ...c, start_ms: c.start_ms + d };
    if (c.volume_keyframes) {
      next.volume_keyframes = c.volume_keyframes.map((k) => ({ ...k, t_ms: k.t_ms + d }));
    }
    return next;
  });
}

/** The synthetic clip for an unmuted video bumper, or null when there is
 *  nothing to mix. Length comes from the LAYOUT (already clamped), not from
 *  the raw `duration_ms`. */
export function bumperAudioClip(
  bumper: MotionBumper,
  slot: BumperSlot,
  layout: BumperLayout
): ResolvedMotionAudio | null {
  if (bumper.kind !== "video" || bumper.mute) return null;
  const lengthMs = slot === "start" ? layout.preMs : layout.postMs;
  if (lengthMs <= 0) return null;
  return {
    url: bumper.url,
    start_ms: slot === "start" ? 0 : layout.preMs + layout.mainMs,
    trim_in_ms: 0,
    trim_out_ms: lengthMs,
    volume: bumper.volume,
    fade_in_ms: 0,
    fade_out_ms: 0,
  };
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `bun test src/lib/video-editor/bumperAudio.test.ts` — all pass.

- [ ] **Step 5: Commit**

```bash
git add src/lib/video-editor/bumperAudio.ts src/lib/video-editor/bumperAudio.test.ts
git commit -m "feat(web): derive export audio clips for bumpers without touching the timeline

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Service, wire type, client metadata reader

**Files:**
- Create: `src/types/kv/motionBumper.ts`
- Create: `src/services/kv/motionBumpers.ts`
- Create: `src/lib/video-editor/bumperMetadata.ts`
- Test: `src/services/kv/motionBumpers.test.ts`, `src/lib/video-editor/bumperMetadata.test.ts`
- Reference: `src/services/kv/motionTemplates.ts`, `src/services/kv/api.ts::uploadStudioOverlayAsset`

**Interfaces:**
- Produces:
  - `type KvMotionBumperRow = { id; brandId; name; kind: "image"|"video"; url; durationMs; width; height; createdBy; createdAt; updatedAt }`
  - `MOTION_BUMPERS_ROOT = ["kv-motion-bumpers"] as const`, `motionBumpersKey(fileId)`
  - `listMotionBumpers(fileId): Promise<KvMotionBumperRow[]>`
  - `uploadMotionBumper(fileId, body: { name; file: File; durationMs; width; height }): Promise<KvMotionBumperRow>`
  - `deleteMotionBumper(fileId, bumperId): Promise<void>`
  - `readBumperFileMetadata(file: File): Promise<{ kind: "image"|"video"; durationMs: number; width: number; height: number }>` — rejects with `Error("Couldn't read this video — try an MP4 (H.264).")` / `Error("Couldn't read this image.")`.
  - `BUMPER_UPLOAD_MAX_BYTES = 50 * 1024 * 1024`, `BUMPER_ACCEPT = "image/png,image/jpeg,image/webp,video/mp4,video/webm"`.
- The api resource keys consumed are exactly: `id, brand_id, name, kind, url, duration_ms, width, height, created_by, created_at, updated_at` (api plan Task 3).

- [ ] **Step 1: Write the type**

```ts
// src/types/kv/motionBumper.ts
// Mirrors api's kv_motion_bumpers rows (KvMotionBumperResource).

/** One library bumper, visible to everyone on the same brand. */
export type KvMotionBumperRow = {
  id: string;
  brandId: string;
  name: string;
  kind: "image" | "video";
  url: string;
  /** Natural length of a video; 0 for an image. */
  durationMs: number;
  width: number;
  height: number;
  createdBy: string;
  createdAt: string;
  updatedAt: string;
};
```

- [ ] **Step 2: Write the failing service test**

`src/services/kv/motionBumpers.test.ts` — mock the axios instance the same way any existing `src/services/kv/*.test.ts` does (find one with `mock.module("@/services/axios", …)` and copy its exact shape; if none exists, use the pattern below):

```ts
import { beforeEach, describe, expect, it, mock } from "bun:test";

const get = mock(async () => ({ data: { data: [] } }));
const post = mock(async () => ({ data: { data: {} } }));
const del = mock(async () => ({ data: {} }));
mock.module("@/services/axios", () => ({ default: { get, post, delete: del } }));

const { listMotionBumpers, uploadMotionBumper, deleteMotionBumper, motionBumpersKey } =
  await import("./motionBumpers");

const wire = {
  id: "b1", brand_id: "br", name: "Lockup", kind: "video", url: "https://x/s.mp4",
  duration_ms: 2500, width: 1920, height: 1080, created_by: "u", created_at: "c", updated_at: "u2",
};

beforeEach(() => { get.mockClear(); post.mockClear(); del.mockClear(); });

describe("motionBumpers service", () => {
  it("lists and maps snake_case rows", async () => {
    get.mockResolvedValueOnce({ data: { data: [wire] } });
    const rows = await listMotionBumpers("f1");
    expect(get).toHaveBeenCalledWith("v1/studio/files/f1/motion-bumpers");
    expect(rows[0]).toEqual({
      id: "b1", brandId: "br", name: "Lockup", kind: "video", url: "https://x/s.mp4",
      durationMs: 2500, width: 1920, height: 1080, createdBy: "u", createdAt: "c", updatedAt: "u2",
    });
  });

  it("uploads as multipart with the metadata fields", async () => {
    post.mockResolvedValueOnce({ data: { data: wire } });
    const file = new File([new Uint8Array([1, 2, 3])], "s.mp4", { type: "video/mp4" });
    const row = await uploadMotionBumper("f1", { name: "Lockup", file, durationMs: 2500, width: 1920, height: 1080 });
    expect(row.id).toBe("b1");
    const [url, body, config] = post.mock.calls[0] as [string, FormData, { headers: Record<string, string> }];
    expect(url).toBe("v1/studio/files/f1/motion-bumpers");
    expect(body).toBeInstanceOf(FormData);
    expect(body.get("name")).toBe("Lockup");
    expect(body.get("duration_ms")).toBe("2500");
    expect(body.get("width")).toBe("1920");
    expect(body.get("height")).toBe("1080");
    expect(body.get("file")).toBeInstanceOf(File);
    expect(config.headers["Content-Type"]).toBe("multipart/form-data");
  });

  it("deletes by id", async () => {
    await deleteMotionBumper("f1", "b1");
    expect(del).toHaveBeenCalledWith("v1/studio/files/f1/motion-bumpers/b1");
  });

  it("keys the list under the shared root", () => {
    expect(motionBumpersKey("f1")).toEqual(["kv-motion-bumpers", "f1"]);
  });
});
```

- [ ] **Step 3: Run to verify it fails**

Run: `bun test src/services/kv/motionBumpers.test.ts` — FAIL, module missing.

- [ ] **Step 4: Write the service**

```ts
// ──────────────────────────────────────────────
// KV Motion — bumper library API service functions
// ──────────────────────────────────────────────

import axiosInstance from "@/services/axios";
import type { KvMotionBumperRow } from "@/types/kv/motionBumper";

function unwrap<T>(response: { message?: string; data: T }): T {
  return response.data;
}

type WireMotionBumper = {
  id: string;
  brand_id: string;
  name: string;
  kind: "image" | "video";
  url: string;
  duration_ms: number;
  width: number;
  height: number;
  created_by: string;
  created_at: string;
  updated_at: string;
};

function toRow(w: WireMotionBumper): KvMotionBumperRow {
  return {
    id: w.id,
    brandId: w.brand_id,
    name: w.name,
    kind: w.kind,
    url: w.url,
    durationMs: w.duration_ms,
    width: w.width,
    height: w.height,
    createdBy: w.created_by,
    createdAt: w.created_at,
    updatedAt: w.updated_at,
  };
}

/** File-addressed route, BRAND-scoped list — the api derives the brand from
 *  the file, exactly like motion-templates. */
const BUMPERS_BASE = (fileId: string) => `v1/studio/files/${fileId}/motion-bumpers`;

/** Writers invalidate THIS root, not one file's key: every open file on the
 *  same brand holds the same rows under its own fileId. */
export const MOTION_BUMPERS_ROOT = ["kv-motion-bumpers"] as const;
export const motionBumpersKey = (fileId: string) => [...MOTION_BUMPERS_ROOT, fileId] as const;

export async function listMotionBumpers(fileId: string): Promise<KvMotionBumperRow[]> {
  const { data } = await axiosInstance.get(BUMPERS_BASE(fileId));
  const rows: WireMotionBumper[] = unwrap(data);
  return rows.map(toRow);
}

export async function uploadMotionBumper(
  fileId: string,
  body: { name: string; file: File; durationMs: number; width: number; height: number }
): Promise<KvMotionBumperRow> {
  const form = new FormData();
  form.append("name", body.name);
  form.append("file", body.file);
  form.append("duration_ms", String(Math.round(body.durationMs)));
  form.append("width", String(Math.round(body.width)));
  form.append("height", String(Math.round(body.height)));
  const { data } = await axiosInstance.post(BUMPERS_BASE(fileId), form, {
    headers: { "Content-Type": "multipart/form-data" },
  });
  return toRow(unwrap<WireMotionBumper>(data));
}

export async function deleteMotionBumper(fileId: string, bumperId: string): Promise<void> {
  await axiosInstance.delete(`${BUMPERS_BASE(fileId)}/${bumperId}`);
}
```

- [ ] **Step 5: Run the service test** — `bun test src/services/kv/motionBumpers.test.ts` → pass.

- [ ] **Step 6: Write the failing metadata-reader test**

`src/lib/video-editor/bumperMetadata.test.ts`. jsdom never fires `loadedmetadata` / `load` on its own, so the reader takes a DI seam for element creation:

```ts
import { describe, expect, it } from "bun:test";

import { BUMPER_ACCEPT, BUMPER_UPLOAD_MAX_BYTES, readBumperFileMetadata } from "./bumperMetadata";

type FakeVideo = { videoWidth: number; videoHeight: number; duration: number; src: string;
  onloadedmetadata: (() => void) | null; onerror: (() => void) | null; preload: string };
type FakeImage = { naturalWidth: number; naturalHeight: number; src: string;
  onload: (() => void) | null; onerror: (() => void) | null };

function deps(fire: "meta" | "error", video: Partial<FakeVideo> = {}, image: Partial<FakeImage> = {}) {
  return {
    createVideo: () => {
      const v: FakeVideo = { videoWidth: 1920, videoHeight: 1080, duration: 2.5, src: "", preload: "", onloadedmetadata: null, onerror: null, ...video };
      queueMicrotask(() => (fire === "meta" ? v.onloadedmetadata?.() : v.onerror?.()));
      return v as unknown as HTMLVideoElement;
    },
    createImage: () => {
      const i: FakeImage = { naturalWidth: 400, naturalHeight: 200, src: "", onload: null, onerror: null, ...image };
      queueMicrotask(() => (fire === "meta" ? i.onload?.() : i.onerror?.()));
      return i as unknown as HTMLImageElement;
    },
    createObjectURL: () => "blob:fake",
    revokeObjectURL: () => {},
  };
}

const mp4 = new File([new Uint8Array([0])], "s.mp4", { type: "video/mp4" });
const png = new File([new Uint8Array([0])], "l.png", { type: "image/png" });

describe("readBumperFileMetadata", () => {
  it("reads a video's dimensions and duration in ms", async () => {
    await expect(readBumperFileMetadata(mp4, deps("meta"))).resolves.toEqual({ kind: "video", durationMs: 2500, width: 1920, height: 1080 });
  });
  it("reads an image's natural size with duration 0", async () => {
    await expect(readBumperFileMetadata(png, deps("meta"))).resolves.toEqual({ kind: "image", durationMs: 0, width: 400, height: 200 });
  });
  it("rejects a video the browser cannot read, or one with no duration", async () => {
    await expect(readBumperFileMetadata(mp4, deps("error"))).rejects.toThrow("Couldn't read this video — try an MP4 (H.264).");
    await expect(readBumperFileMetadata(mp4, deps("meta", { duration: 0 }))).rejects.toThrow("Couldn't read this video");
    await expect(readBumperFileMetadata(mp4, deps("meta", { duration: Infinity }))).rejects.toThrow("Couldn't read this video");
  });
  it("rejects an unreadable image", async () => {
    await expect(readBumperFileMetadata(png, deps("error"))).rejects.toThrow("Couldn't read this image.");
  });
  it("rejects a mime outside the accept list before touching the DOM", async () => {
    const gif = new File([new Uint8Array([0])], "x.gif", { type: "image/gif" });
    await expect(readBumperFileMetadata(gif, deps("meta"))).rejects.toThrow("Use a PNG, JPG, WebP, MP4 or WebM file.");
  });
  it("rejects an oversized file", async () => {
    const big = { type: "video/mp4", size: BUMPER_UPLOAD_MAX_BYTES + 1, name: "big.mp4" } as unknown as File;
    await expect(readBumperFileMetadata(big, deps("meta"))).rejects.toThrow("Bumpers must be under 50 MB.");
  });
  it("exposes the accept string the input uses", () => {
    expect(BUMPER_ACCEPT).toBe("image/png,image/jpeg,image/webp,video/mp4,video/webm");
  });
});
```

- [ ] **Step 7: Run to verify it fails** — `bun test src/lib/video-editor/bumperMetadata.test.ts`.

- [ ] **Step 8: Write `bumperMetadata.ts`**

```ts
// ──────────────────────────────────────────────
// KV Motion — read a bumper upload's metadata in the browser.
// The api has no ffprobe: the client reports duration / dimensions and the
// api clamps them (same contract as kv_motion_projects.duration_ms).
// ──────────────────────────────────────────────

export const BUMPER_UPLOAD_MAX_BYTES = 50 * 1024 * 1024;
export const BUMPER_ACCEPT = "image/png,image/jpeg,image/webp,video/mp4,video/webm";
const ACCEPTED = new Set(BUMPER_ACCEPT.split(","));

export type BumperFileMetadata = {
  kind: "image" | "video";
  durationMs: number;
  width: number;
  height: number;
};

/** DI seam — jsdom never fires media/image load events. */
export type BumperMetadataDeps = {
  createVideo: () => HTMLVideoElement;
  createImage: () => HTMLImageElement;
  createObjectURL: (f: File) => string;
  revokeObjectURL: (u: string) => void;
};

const defaultDeps = (): BumperMetadataDeps => ({
  createVideo: () => document.createElement("video"),
  createImage: () => new Image(),
  createObjectURL: (f) => URL.createObjectURL(f),
  revokeObjectURL: (u) => URL.revokeObjectURL(u),
});

export async function readBumperFileMetadata(
  file: File,
  deps: BumperMetadataDeps = defaultDeps()
): Promise<BumperFileMetadata> {
  if (!ACCEPTED.has(file.type)) throw new Error("Use a PNG, JPG, WebP, MP4 or WebM file.");
  if (file.size > BUMPER_UPLOAD_MAX_BYTES) throw new Error("Bumpers must be under 50 MB.");
  const url = deps.createObjectURL(file);
  try {
    if (file.type.startsWith("video/")) {
      return await new Promise<BumperFileMetadata>((resolve, reject) => {
        const v = deps.createVideo();
        v.preload = "metadata";
        v.onloadedmetadata = () => {
          const d = v.duration;
          if (!Number.isFinite(d) || d <= 0 || v.videoWidth <= 0 || v.videoHeight <= 0) {
            reject(new Error("Couldn't read this video — try an MP4 (H.264)."));
            return;
          }
          resolve({ kind: "video", durationMs: Math.round(d * 1000), width: v.videoWidth, height: v.videoHeight });
        };
        v.onerror = () => reject(new Error("Couldn't read this video — try an MP4 (H.264)."));
        v.src = url;
      });
    }
    return await new Promise<BumperFileMetadata>((resolve, reject) => {
      const i = deps.createImage();
      i.onload = () => resolve({ kind: "image", durationMs: 0, width: i.naturalWidth, height: i.naturalHeight });
      i.onerror = () => reject(new Error("Couldn't read this image."));
      i.src = url;
    });
  } finally {
    deps.revokeObjectURL(url);
  }
}
```

- [ ] **Step 9: Run both tests** — pass.

- [ ] **Step 10: Commit**

```bash
git add src/types/kv/motionBumper.ts src/services/kv/motionBumpers.ts src/services/kv/motionBumpers.test.ts src/lib/video-editor/bumperMetadata.ts src/lib/video-editor/bumperMetadata.test.ts
git commit -m "feat(web): motion bumper library service + client metadata reader

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Analytics events

**Files:**
- Modify: `src/lib/analytics/kv-generator-events.ts` (append after `trackKvMotionTemplateDeleted`; add `has_bumpers` to `KvMotionExportCompletedProps`)
- Test: `src/lib/analytics/kv-generator-events.bumpers.test.ts`

**Interfaces:**
- Produces:
  - `trackKvMotionBumperSet({ project_id, slot, kind, source: "library"|"upload", duration_ms, fit })` → `kv_generator.motion_bumper_set`
  - `trackKvMotionBumperRemoved({ project_id, slot, kind })` → `kv_generator.motion_bumper_removed`
  - `trackKvMotionBumperLibraryUploaded({ project_id, kind, duration_ms, bytes })` → `kv_generator.motion_bumper_library_uploaded`
  - `trackKvMotionBumperLibraryDeleted({ project_id, kind })` → `kv_generator.motion_bumper_library_deleted`
  - `KvMotionExportCompletedProps.has_bumpers: boolean` and `bumper_kinds: ("image"|"video")[]` (both required).

- [ ] **Step 1: Write the failing test** (same prototype-preserving posthog mock as `kv-generator-events.motionTransform.test.ts` — copy its top 14 lines verbatim)

```ts
// …posthog mock block copied verbatim from kv-generator-events.motionTransform.test.ts…

const {
  trackKvMotionBumperSet,
  trackKvMotionBumperRemoved,
  trackKvMotionBumperLibraryUploaded,
  trackKvMotionBumperLibraryDeleted,
} = await import("./kv-generator-events");

describe("motion bumper events", () => {
  it("bumper_set carries slot, kind, source, duration and fit", () => {
    trackKvMotionBumperSet({ project_id: "p1", slot: "start", kind: "video", source: "library", duration_ms: 1500, fit: "contain" });
    expect(capture).toHaveBeenCalledWith("kv_generator.motion_bumper_set", expect.objectContaining({ project_id: "p1", slot: "start", kind: "video", source: "library", duration_ms: 1500, fit: "contain" }));
  });
  it("bumper_removed", () => {
    trackKvMotionBumperRemoved({ project_id: "p1", slot: "end", kind: "image" });
    expect(capture).toHaveBeenCalledWith("kv_generator.motion_bumper_removed", expect.objectContaining({ slot: "end", kind: "image" }));
  });
  it("library_uploaded / library_deleted", () => {
    trackKvMotionBumperLibraryUploaded({ project_id: "p1", kind: "image", duration_ms: 0, bytes: 1234 });
    expect(capture).toHaveBeenCalledWith("kv_generator.motion_bumper_library_uploaded", expect.objectContaining({ kind: "image", bytes: 1234 }));
    trackKvMotionBumperLibraryDeleted({ project_id: "p1", kind: "video" });
    expect(capture).toHaveBeenCalledWith("kv_generator.motion_bumper_library_deleted", expect.objectContaining({ kind: "video" }));
  });
});
```

- [ ] **Step 2: Run to verify it fails** — the four functions are undefined.

- [ ] **Step 3: Add the events**

Append to `kv-generator-events.ts`:

```ts
// ── Motion bumpers (2026-09-20) ──

export type KvMotionBumperSlot = "start" | "end";
export type KvMotionBumperKind = "image" | "video";

export interface KvMotionBumperSetProps {
  project_id: string;
  slot: KvMotionBumperSlot;
  kind: KvMotionBumperKind;
  /** "library" = picked an existing row; "upload" = uploaded and picked in one go. */
  source: "library" | "upload";
  duration_ms: number;
  fit: "contain" | "cover";
}

/** A slot was filled or swapped. */
export const trackKvMotionBumperSet = (p: KvMotionBumperSetProps) =>
  safeCapture("kv_generator.motion_bumper_set", p);

export interface KvMotionBumperRemovedProps {
  project_id: string;
  slot: KvMotionBumperSlot;
  kind: KvMotionBumperKind;
}

export const trackKvMotionBumperRemoved = (p: KvMotionBumperRemovedProps) =>
  safeCapture("kv_generator.motion_bumper_removed", p);

export interface KvMotionBumperLibraryUploadedProps {
  project_id: string;
  kind: KvMotionBumperKind;
  duration_ms: number;
  bytes: number;
}

export const trackKvMotionBumperLibraryUploaded = (p: KvMotionBumperLibraryUploadedProps) =>
  safeCapture("kv_generator.motion_bumper_library_uploaded", p);

export interface KvMotionBumperLibraryDeletedProps {
  project_id: string;
  kind: KvMotionBumperKind;
}

export const trackKvMotionBumperLibraryDeleted = (p: KvMotionBumperLibraryDeletedProps) =>
  safeCapture("kv_generator.motion_bumper_library_deleted", p);
```

And extend `KvMotionExportCompletedProps`:

```ts
  /** Whether the MP4 carries a start/end bumper, and which kinds. */
  has_bumpers: boolean;
  bumper_kinds: KvMotionBumperKind[];
```

(`KvMotionExportDialog.tsx` will not compile until Task 7 fills these in; that is expected — Task 7 follows.)

- [ ] **Step 4: Run** — `bun test src/lib/analytics/kv-generator-events.bumpers.test.ts` → pass.

- [ ] **Step 5: Commit**

```bash
git add src/lib/analytics/kv-generator-events.ts src/lib/analytics/kv-generator-events.bumpers.test.ts
git commit -m "feat(web): PostHog events for motion bumpers

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: `openBumperVideo` — Mediabunny wrapper

**Files:**
- Create: `src/components/studio/kv-generator/motion/bumperVideoSource.ts` (next to `exportAudioFetch.ts`, whose fetch it reuses)
- Test: `src/components/studio/kv-generator/motion/bumperVideoSource.test.ts`

**Why bytes, not `UrlSource`:** by export time the editor's preview `<video>` and the picker thumbnails have loaded the bumper URL no-CORS. Chrome hands that cached, header-less entry to a later CORS fetch of the same URL and it fails with `Failed to fetch` (memory `lesson_chrome_image_cache_ignores_cors_mode` — the exact trap that silenced export audio). Mediabunny's `UrlSource` performs its own ranged fetches and would hit it. So the whole file (≤ 50 MB) is fetched once through `fetchAudioForExport` — `cache: "no-store"` + same-origin proxy fallback — and handed to Mediabunny as a `BlobSource`. The same blob is what Task 7 decodes the audio from, so the file is downloaded exactly once per export.

**Interfaces:**
- Produces:
  ```ts
  export type BumperVideoSource = {
    durationMs: number;
    width: number;
    height: number;
    hasAudio: boolean;
    /** The fetched file — Task 7 decodes its audio from this without a second download. */
    blob: Blob;
    /** Frame at a local time. The caller draws it IMMEDIATELY and then calls `close()` on it. */
    frameAt(localMs: number): Promise<VideoSample | null>;
    dispose(): void;
  };
  export type BumperVideoDeps = { Input; BlobSource; VideoSampleSink; ALL_FORMATS; fetchBytes: (url: string) => Promise<Blob> };
  export async function openBumperVideo(url: string, deps?: Partial<BumperVideoDeps>): Promise<BumperVideoSource>;
  export class BumperVideoError extends Error {}
  ```
  Throws `BumperVideoError("no decodable video track")` when `getPrimaryVideoTrack()` is null or `canDecode()` is false. A failing `fetchBytes` rejects with its own error.

- [ ] **Step 1: Write the failing test** (fakes through `deps`; the real Mediabunny and network are never touched)

```ts
import { describe, expect, it, mock } from "bun:test";

import { BumperVideoError, openBumperVideo } from "./bumperVideoSource";

function fakes(opts: { video?: boolean; decodable?: boolean; audio?: boolean; duration?: number } = {}) {
  const { video = true, decodable = true, audio = true, duration = 2.5 } = opts;
  const track = { displayWidth: 1280, displayHeight: 720, canDecode: mock(async () => decodable) };
  const sample = { close: mock(() => {}) };
  const getSample = mock(async (_t: number) => sample);
  const dispose = mock(() => {});
  const blob = new Blob([new Uint8Array([1, 2, 3])], { type: "video/mp4" });
  const fetchBytes = mock(async (_url: string) => blob);
  let sourceSeen: unknown;
  class Input {
    constructor(public options: { source: unknown }) { sourceSeen = options.source; }
    getPrimaryVideoTrack = mock(async () => (video ? track : null));
    getPrimaryAudioTrack = mock(async () => (audio ? {} : null));
    computeDuration = mock(async () => duration);
    dispose = dispose;
  }
  class BlobSource { constructor(public blob: Blob) {} }
  class VideoSampleSink { constructor(public t: unknown) {} getSample = getSample; }
  return {
    deps: { Input, BlobSource, VideoSampleSink, ALL_FORMATS: ["all"], fetchBytes } as never,
    getSample, sample, dispose, track, blob, fetchBytes, sourceSeen: () => sourceSeen as { blob: Blob },
  };
}

describe("openBumperVideo", () => {
  it("fetches the bytes once, feeds them to a BlobSource, reads metadata and hands back frames by local ms", async () => {
    const f = fakes();
    const src = await openBumperVideo("https://x/s.mp4", f.deps);
    expect(f.fetchBytes).toHaveBeenCalledTimes(1);
    expect(f.fetchBytes).toHaveBeenCalledWith("https://x/s.mp4");
    expect(f.sourceSeen().blob).toBe(f.blob);
    expect(src).toMatchObject({ durationMs: 2500, width: 1280, height: 720, hasAudio: true });
    expect(src.blob).toBe(f.blob);
    const s = await src.frameAt(1234);
    expect(f.getSample).toHaveBeenCalledWith(1.234);
    expect(s).toBe(f.sample as never);
    src.dispose();
    expect(f.dispose).toHaveBeenCalled();
  });
  it("hasAudio is false without an audio track", async () => {
    const src = await openBumperVideo("u", fakes({ audio: false }).deps);
    expect(src.hasAudio).toBe(false);
  });
  it("throws BumperVideoError without a video track or when it cannot be decoded", async () => {
    await expect(openBumperVideo("u", fakes({ video: false }).deps)).rejects.toBeInstanceOf(BumperVideoError);
    await expect(openBumperVideo("u", fakes({ decodable: false }).deps)).rejects.toBeInstanceOf(BumperVideoError);
  });
  it("disposes the input when opening fails after construction", async () => {
    const f = fakes({ decodable: false });
    await openBumperVideo("u", f.deps).catch(() => {});
    expect(f.dispose).toHaveBeenCalled();
  });
  it("propagates a fetch failure", async () => {
    const f = fakes();
    f.fetchBytes.mockRejectedValueOnce(new Error("[kv] could not fetch audio for export: u"));
    await expect(openBumperVideo("u", f.deps)).rejects.toThrow("could not fetch");
  });
});
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Write the wrapper**

```ts
// ──────────────────────────────────────────────
// KV Motion — frame-exact decode of a video bumper for export.
// Mediabunny Input + VideoSampleSink: `getSample(t)` is deterministic per
// timestamp, unlike `<video>.currentTime`, which is what the export loop
// needs (the same reason encode.ts pushes frames with explicit timestamps).
//
// Bytes come in through `fetchAudioForExport`, NOT `UrlSource`: the preview
// <video> has already loaded this URL no-CORS, and Chrome would hand that
// header-less cache entry to Mediabunny's own CORS fetches (see the comment
// in exportAudioFetch.ts). One download per export; Task 7 decodes the audio
// from the same blob.
// ──────────────────────────────────────────────

import {
  ALL_FORMATS,
  BlobSource,
  Input,
  VideoSampleSink,
  type VideoSample,
} from "mediabunny";

import { fetchAudioForExport } from "./exportAudioFetch";

export class BumperVideoError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "BumperVideoError";
  }
}

export type BumperVideoSource = {
  durationMs: number;
  width: number;
  height: number;
  hasAudio: boolean;
  /** The fetched file — the audio mix decodes from this, no second download. */
  blob: Blob;
  /** Frame at a local time. Draw it IMMEDIATELY, then `close()` it —
   *  Mediabunny may close the underlying VideoFrame on the next microtask. */
  frameAt(localMs: number): Promise<VideoSample | null>;
  dispose(): void;
};

/** DI seam for tests — defaults to the real mediabunny classes and the
 *  CORS-safe export fetch. */
export type BumperVideoDeps = {
  Input: typeof Input;
  BlobSource: typeof BlobSource;
  VideoSampleSink: typeof VideoSampleSink;
  ALL_FORMATS: typeof ALL_FORMATS;
  fetchBytes: (url: string) => Promise<Blob>;
};

const defaultFetchBytes = (url: string) => fetchAudioForExport(url).then((r) => r.blob());

export async function openBumperVideo(
  url: string,
  deps?: Partial<BumperVideoDeps>
): Promise<BumperVideoSource> {
  const D: BumperVideoDeps = { Input, BlobSource, VideoSampleSink, ALL_FORMATS, fetchBytes: defaultFetchBytes, ...deps };
  const blob = await D.fetchBytes(url);
  const input = new D.Input({ source: new D.BlobSource(blob), formats: D.ALL_FORMATS });
  try {
    const video = await input.getPrimaryVideoTrack();
    if (!video || !(await video.canDecode())) {
      throw new BumperVideoError("no decodable video track");
    }
    const [audio, durationS] = await Promise.all([
      input.getPrimaryAudioTrack(),
      input.computeDuration(),
    ]);
    const sink = new D.VideoSampleSink(video);
    return {
      durationMs: Math.round(durationS * 1000),
      width: video.displayWidth,
      height: video.displayHeight,
      hasAudio: audio !== null,
      blob,
      frameAt: (localMs) => sink.getSample(localMs / 1000),
      dispose: () => input.dispose(),
    };
  } catch (err) {
    input.dispose();
    throw err;
  }
}
```

- [ ] **Step 4: Run** — pass.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/motion/bumperVideoSource.ts src/components/studio/kv-generator/motion/bumperVideoSource.test.ts
git commit -m "feat(web): openBumperVideo — Mediabunny frame-exact decode over the CORS-safe fetch

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Export — preload gate, frame router, bumper paint

**Files:**
- Modify: `src/components/studio/kv-generator/motion/exportMotion.ts` (`ExportMotionRatioDeps`, `MotionAssetError`, `exportMotionRatio`)
- Test: `src/components/studio/kv-generator/motion/exportMotion.bumpers.test.ts` (new file)

**Interfaces:**
- Consumes: `bumperLayout`, `resolveBumperFrame`, `fitRect` (Task 1); `openBumperVideo`, `BumperVideoSource` (Task 5).
- Produces:
  - `ExportMotionRatioDeps.openBumperVideo: typeof openBumperVideo` (new DI field).
  - `exportMotionRatio` encodes `bumperLayout(timeline).totalMs` frames and paints bumper frames itself. Existing callers without bumpers are byte-for-byte unchanged (identity layout).
  - `MotionAssetError` is reused with `layerName` = `"Start bumper"` / `"End bumper"`.
  - New exported helper (for tests): `paintBumperFrame(ctx, source: CanvasImageSource, bumper: MotionBumper, w: number, h: number): void` — `fillRect(bg)` then `drawImage(source, fitRect(...))`.

- [ ] **Step 1: Write the failing tests**

`exportMotion.bumpers.test.ts`. The fake stage exposes `getLayers()[0].getCanvas()._canvas` whose `getContext("2d")` is a recorder; the fake encoder calls `drawFrame` at chosen timestamps and records `durationMs`.

```ts
import { describe, expect, it, mock } from "bun:test";

import type { MotionBumper, MotionTimeline } from "@/lib/video-editor/timeline";
import type { KvMotionSnapshot } from "@/types/kv/motionProject";

import { exportMotionRatio, MOTION_RATIOS, MotionAssetError, paintBumperFrame } from "./exportMotion";

const snapshot: KvMotionSnapshot = { base_image_url: "https://x/base.png", board_width: 1080, board_height: 1080, overlays: [] };
const MAIN: MotionTimeline = { version: 1, duration_ms: 1000, fps: 10, tracks: [] };

const img: MotionBumper = { bumper_id: "i", kind: "image", url: "https://x/lockup.png", duration_ms: 500, natural_ms: 0, src_width: 400, src_height: 200, fit: "contain", bg: "#112233", mute: false, volume: 1 };
const vid: MotionBumper = { ...img, bumper_id: "v", kind: "video", url: "https://x/s.mp4", duration_ms: 300, natural_ms: 300, src_width: 16, src_height: 9 };

function recorderCanvas() {
  const calls: unknown[][] = [];
  const ctx = {
    save: () => calls.push(["save"]),
    restore: () => calls.push(["restore"]),
    setTransform: (...a: number[]) => calls.push(["setTransform", ...a]),
    fillRect: (...a: number[]) => calls.push(["fillRect", ...a]),
    drawImage: (src: unknown, ...a: number[]) => calls.push(["drawImage", src, ...a]),
    set fillStyle(v: string) { calls.push(["fillStyle", v]); },
  };
  return { canvas: { getContext: () => ctx } as unknown as HTMLCanvasElement, calls };
}

function harness(timeline: MotionTimeline, opts: { frameTimes: number[]; imageFails?: boolean; videoFails?: boolean } ) {
  const { canvas, calls } = recorderCanvas();
  const layerDraw = mock(() => {});
  const stage = { getLayers: () => [{ getCanvas: () => ({ _canvas: canvas }), draw: layerDraw }], destroy: mock(() => {}) };
  const buildBoardStage = mock(async () => ({ stage, nodeById: new Map() }));
  const imageEl = { tag: "img" } as unknown as HTMLImageElement;
  const loadImage = mock(async (src: string) => {
    if (opts.imageFails && src === img.url) throw new Error("404");
    return imageEl;
  });
  const sample = { toCanvasImageSource: () => ({ tag: "frame" }), close: mock(() => {}) };
  const frameAt = mock(async (_ms: number) => sample);
  const dispose = mock(() => {});
  const openBumperVideo = mock(async () => {
    if (opts.videoFails) throw new Error("no decodable video track");
    return { durationMs: 300, width: 16, height: 9, hasAudio: false, blob: new Blob(), frameAt, dispose };
  });
  let seenDuration = -1;
  const encodeTimelineToMp4 = mock(async (o: { durationMs: number; drawFrame: (t: number) => void | Promise<void> }) => {
    seenDuration = o.durationMs;
    for (const t of opts.frameTimes) await o.drawFrame(t);
    return new Blob();
  });
  const run = () => exportMotionRatio({
    snapshot, timeline, ratio: MOTION_RATIOS[0],
    deps: { loadImage, fontsReady: Promise.resolve(), buildBoardStage: buildBoardStage as never, encodeTimelineToMp4: encodeTimelineToMp4 as never, openBumperVideo: openBumperVideo as never },
  });
  return { run, calls, layerDraw, imageEl, sample, frameAt, dispose, openBumperVideo, loadImage, seenDuration: () => seenDuration };
}

describe("exportMotionRatio with bumpers", () => {
  it("encodes the TOTAL length and routes frames: start bumper, main (shifted), end bumper", async () => {
    const tl: MotionTimeline = { ...MAIN, bumpers: { start: img, end: vid } }; // 500 + 1000 + 300
    const h = harness(tl, { frameTimes: [0, 400, 500, 1400, 1500, 1799] });
    await h.run();
    expect(h.seenDuration()).toBe(1800);
    // Two start frames: painted with the image, layer NOT drawn.
    const paints = h.calls.filter((c) => c[0] === "drawImage");
    expect(paints.slice(0, 2).every((c) => c[1] === h.imageEl)).toBe(true);
    // Two main frames → layer.draw() exactly twice.
    expect(h.layerDraw).toHaveBeenCalledTimes(2);
    // Two end frames: decoded at local 0 and 299 ms, each sample closed.
    expect(h.frameAt.mock.calls.map((c) => c[0])).toEqual([0, 299]);
    expect(h.sample.close).toHaveBeenCalledTimes(2);
    expect(paints.slice(2).every((c) => (c[1] as { tag: string }).tag === "frame")).toBe(true);
    expect(h.dispose).toHaveBeenCalledTimes(1);
  });

  it("is unchanged without bumpers: no video opened, every frame draws the layer", async () => {
    const h = harness(MAIN, { frameTimes: [0, 500, 999] });
    await h.run();
    expect(h.seenDuration()).toBe(1000);
    expect(h.openBumperVideo).not.toHaveBeenCalled();
    expect(h.layerDraw).toHaveBeenCalledTimes(3);
    expect(h.calls.filter((c) => c[0] === "drawImage")).toHaveLength(0);
  });

  it("fails in the preload gate with the slot name when the image cannot load", async () => {
    const h = harness({ ...MAIN, bumpers: { start: img } }, { frameTimes: [], imageFails: true });
    await expect(h.run()).rejects.toBeInstanceOf(MotionAssetError);
    await h.run().catch((e: MotionAssetError) => expect(e.layerName).toBe("Start bumper"));
  });

  it("fails in the preload gate with the slot name when the video cannot be decoded", async () => {
    const h = harness({ ...MAIN, bumpers: { end: vid } }, { frameTimes: [], videoFails: true });
    await h.run().catch((e: MotionAssetError) => {
      expect(e).toBeInstanceOf(MotionAssetError);
      expect(e.layerName).toBe("End bumper");
    });
  });

  it("disposes the video source even when encoding throws", async () => {
    const h = harness({ ...MAIN, bumpers: { end: vid } }, { frameTimes: [] });
    // Make the encoder reject after opening.
    const failing = { ...h };
    void failing;
    // Simplest: run with a drawFrame that throws via a frame time inside the end zone whose sample is null.
    h.frameAt.mockResolvedValueOnce(null as never);
    await h.run(); // a null sample just skips the drawImage; must not throw
    expect(h.dispose).toHaveBeenCalledTimes(1);
  });
});

describe("paintBumperFrame", () => {
  it("fills the background then draws the source at the contain rect", () => {
    const { canvas, calls } = recorderCanvas();
    const ctx = canvas.getContext("2d") as unknown as CanvasRenderingContext2D;
    paintBumperFrame(ctx, { tag: "img" } as unknown as CanvasImageSource, img, 1080, 1080);
    expect(calls).toEqual([
      ["save"],
      ["setTransform", 1, 0, 0, 1, 0, 0],
      ["fillStyle", "#112233"],
      ["fillRect", 0, 0, 1080, 1080],
      ["drawImage", { tag: "img" }, 0, 270, 1080, 540],
      ["restore"],
    ]);
  });
});
```

(The implementer replaces the "disposes even when encoding throws" placeholder body with a real encoder rejection: make `encodeTimelineToMp4` reject on a flag and assert `dispose` was still called. It is listed here as intent so the case is not dropped.)

- [ ] **Step 2: Run to verify it fails** — `bun test src/components/studio/kv-generator/motion/exportMotion.bumpers.test.ts`: `paintBumperFrame` missing; `openBumperVideo` not a known dep.

- [ ] **Step 3: Implement in `exportMotion.ts`**

Imports to add:

```ts
import { bumperLayout, fitRect, resolveBumperFrame } from "@/lib/video-editor/bumpers";
import { openBumperVideo, type BumperVideoSource } from "./bumperVideoSource";
import type { MotionBumper, MotionTimeline } from "@/lib/video-editor/timeline";
```

Extend the deps type:

```ts
export type ExportMotionRatioDeps = {
  loadImage: (src: string) => Promise<HTMLImageElement>;
  buildBoardStage: typeof buildBoardStage;
  encodeTimelineToMp4: typeof encodeTimelineToMp4;
  fontsReady: Promise<unknown>;
  /** Frame-exact video decode for a video bumper (Task 5). */
  openBumperVideo: typeof openBumperVideo;
};
```

and default it in `exportMotionRatio` (`openBumperVideo,` next to `encodeTimelineToMp4,`).

Add the paint helper (exported):

```ts
/** Paint one bumper frame straight onto the layer's backing canvas: opaque
 *  background, then the source at its contain/cover rect. Resets the
 *  transform first — the encoder reads this canvas 1:1 (`exactPixels`), so
 *  any Konva transform left on the context would offset the paint. */
export function paintBumperFrame(
  ctx: CanvasRenderingContext2D,
  source: CanvasImageSource,
  bumper: MotionBumper,
  w: number,
  h: number
): void {
  const r = fitRect({ w: bumper.src_width, h: bumper.src_height }, { w, h }, bumper.fit);
  ctx.save();
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.fillStyle = bumper.bg;
  ctx.fillRect(0, 0, w, h);
  ctx.drawImage(source, r.x, r.y, r.w, r.h);
  ctx.restore();
}

const SLOT_LABEL = { start: "Start bumper", end: "End bumper" } as const;
```

Inside `exportMotionRatio`, after the existing overlay preload loop (step "1. Preload gate") and before "2. Detached stage", add the bumper preload:

```ts
  // 1b. Bumper preload gate — same contract as the overlay probe above: a
  // broken slot fails HERE with the slot's name, never mid-render.
  const layout = bumperLayout(timeline);
  const bumperImages = new Map<"start" | "end", HTMLImageElement>();
  const bumperVideos = new Map<"start" | "end", BumperVideoSource>();
  for (const slot of ["start", "end"] as const) {
    const b = timeline.bumpers?.[slot];
    if (!b) continue;
    try {
      if (b.kind === "image") {
        bumperImages.set(slot, await deps.loadImage(b.url));
      } else {
        bumperVideos.set(slot, await deps.openBumperVideo(b.url));
      }
    } catch {
      for (const v of bumperVideos.values()) v.dispose();
      throw new MotionAssetError(SLOT_LABEL[slot]);
    }
  }
```

Replace the encoder call's `durationMs` and `drawFrame`, and dispose the videos in the `finally`:

```ts
    return await deps.encodeTimelineToMp4({
      canvas,
      width: ratio.w,
      height: ratio.h,
      fps: remappedTimeline.fps,
      // Total clock: start bumper + main + end bumper. Identity without bumpers.
      durationMs: layout.totalMs,
      drawFrame: async (tMs) => {
        const frame = resolveBumperFrame(remappedTimeline, tMs);
        if (frame.kind === "main") {
          const sampled = sampleTimelineAt(remappedTimeline, base, frame.mainMs);
          applyTimeline({ nodeById, overlays, sampled, targetWidth: ratio.w, targetHeight: ratio.h });
          // Clears and repaints the whole canvas, so nothing a bumper frame
          // painted survives into a main frame.
          layer.draw();
          return;
        }
        const ctx = canvas.getContext("2d");
        if (!ctx) return;
        if (frame.bumper.kind === "image") {
          const el = bumperImages.get(frame.slot);
          if (el) paintBumperFrame(ctx, el, frame.bumper, ratio.w, ratio.h);
          return;
        }
        const src = bumperVideos.get(frame.slot);
        const sample = src ? await src.frameAt(frame.localMs) : null;
        if (!sample) return;
        try {
          // Drawn immediately — the VideoFrame may be closed next microtask.
          paintBumperFrame(ctx, sample.toCanvasImageSource(), frame.bumper, ratio.w, ratio.h);
        } finally {
          sample.close();
        }
      },
      audioBuffer: opts.audioBuffer ?? null,
      signal: opts.signal,
      onProgress: opts.onProgress,
      onFinalizing: opts.onFinalizing,
    });
  } finally {
    for (const v of bumperVideos.values()) v.dispose();
    stage.destroy();
  }
```

Note `remappedTimeline` carries `bumpers` through because `remapTimelineForRatio` spreads the timeline (`{ ...timeline, tracks }`) — verify by reading it; if it constructs a fresh object listing fields, add `bumpers: timeline.bumpers`. Add a test line in the first test asserting the end-bumper frames were drawn (already covered by `frameAt` calls) — that fails if `bumpers` were dropped.

- [ ] **Step 4: Run both export test files**

Run: `bun test src/components/studio/kv-generator/motion/exportMotion.bumpers.test.ts src/components/studio/kv-generator/motion/exportMotion.test.ts`
Expected: all pass (the old file must stay green — identity layout).

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/motion/exportMotion.ts src/components/studio/kv-generator/motion/exportMotion.bumpers.test.ts
git commit -m "feat(web): bake start/end bumpers into motion export

Frames route through resolveBumperFrame; bumper frames are painted on the
layer canvas (image element or Mediabunny video sample), main frames are
unchanged. Total length = pre + main + post.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Export dialog — total duration + derived audio + event props

**Files:**
- Modify: `src/components/studio/kv-generator/motion/KvMotionExportDialog.tsx`
- Test: `src/components/studio/kv-generator/motion/KvMotionExportDialog.bumpers.test.tsx` (new; copy the harness/fixtures from `KvMotionExportDialog.test.tsx`'s top — `render`, its `exportRatioFn` / `uploadAssetFn` / `createExportFn` props)

**Interfaces:**
- Consumes: `bumperLayout` (T1), `shiftClipsForBumpers`, `bumperAudioClip` (T2), `openBumperVideo` incl. its `blob` (T5), analytics props (T4).
- Produces: `createExportFn(... { durationMs: layout.totalMs })`; `trackKvMotionExportCompleted({ …, duration_ms: layout.totalMs, has_bumpers, bumper_kinds })`; `renderAudioMix({ clips: derived, durationMs: layout.totalMs })`.

- [ ] **Step 1: Write the failing test**

Using the existing dialog test's harness (its `renderDialog(props)` helper and the fake `exportRatioFn` that resolves a Blob), add:

```ts
it("records the TOTAL duration on the export row and event when bumpers are set", async () => {
  const timeline = { ...BASE_TIMELINE, bumpers: { start: IMAGE_BUMPER /* 2000ms */ } };
  const createExportFn = mock(async () => EXPORT_ROW);
  renderDialog({ timeline, createExportFn });
  // …click Export, await the done state exactly as the sibling test does…
  expect(createExportFn.mock.calls[0][2].durationMs).toBe(BASE_TIMELINE.duration_ms + 2000);
  expect(capture).toHaveBeenCalledWith(
    "kv_generator.motion_export_completed",
    expect.objectContaining({ duration_ms: BASE_TIMELINE.duration_ms + 2000, has_bumpers: true, bumper_kinds: ["image"] })
  );
});

it("without bumpers the event says has_bumpers false and duration is the main length", async () => {
  // …same flow with BASE_TIMELINE…
  expect(capture).toHaveBeenCalledWith(
    "kv_generator.motion_export_completed",
    expect.objectContaining({ duration_ms: BASE_TIMELINE.duration_ms, has_bumpers: false, bumper_kinds: [] })
  );
});
```

(Audio mixing cannot run under jsdom — `OfflineAudioContext` is absent — so the derived-clip logic is covered by Task 2's pure tests; the dialog test covers duration + event props.)

- [ ] **Step 2: Run to verify it fails** (durationMs is the main length; `has_bumpers` missing).

- [ ] **Step 3: Implement**

In `KvMotionExportDialog.tsx`:

```ts
import { bumperLayout } from "@/lib/video-editor/bumpers";
import { bumperAudioClip, shiftClipsForBumpers } from "@/lib/video-editor/bumperAudio";
import { openBumperVideo } from "./bumperVideoSource";
```

Inside the export run, right where `audioClips` is computed:

```ts
        const layout = bumperLayout(timeline);
        const bumperKinds = (["start", "end"] as const)
          .map((s) => timeline.bumpers?.[s]?.kind)
          .filter((k): k is "image" | "video" => k !== undefined);
        // Project clips move onto the total clock (derived; the persisted
        // timeline is untouched).
        const projectClips = shiftClipsForBumpers(normalizeTimelineAudio(timeline, audioUrl), layout);
        // Unmuted video bumpers: ONE download each (openBumperVideo goes
        // through the CORS-safe fetch), decoded from that blob. A bumper
        // without an audio track, or one whose file can't be decoded, simply
        // contributes no clip — the render's own preload gate is what reports
        // an undecodable bumper, and a silent bumper is not an error. Kept
        // separate from the project clips' try/catch below so a bumper
        // problem never drops the project's own audio with a toast.
        const bumperSources: { audio: ResolvedMotionAudio; source: AudioBuffer }[] = [];
        for (const slot of ["start", "end"] as const) {
          const b = timeline.bumpers?.[slot];
          if (!b) continue;
          const clip = bumperAudioClip(b, slot, layout);
          if (!clip) continue;
          try {
            const opened = await openBumperVideo(b.url);
            try {
              if (opened.hasAudio) {
                bumperSources.push({ audio: clip, source: await decodeAudioFile(new Response(opened.blob)) });
              }
            } finally {
              opened.dispose();
            }
          } catch (err) {
            console.warn("[kv] motion export: bumper audio skipped", slot, err);
          }
        }
        const audioClips = projectClips;
```
then the existing `if (audioClips.length > 0) { … }` block becomes `if (audioClips.length > 0 || bumperSources.length > 0)`, the project clips are decoded exactly as before into `decoded`, and the mix call is `renderAudioMix({ clips: [...decoded, ...bumperSources], durationMs: layout.totalMs })`. Import `ResolvedMotionAudio` from `@/lib/video-editor/timeline`. `createExportFn(… durationMs: layout.totalMs)` and both `trackKvMotionExportCompleted` calls get `duration_ms: layout.totalMs, has_bumpers: bumperKinds.length > 0, bumper_kinds: bumperKinds`. Anywhere the dialog displays the duration (search `formatTime`/`duration_ms` in its JSX) shows `layout.totalMs`.

- [ ] **Step 4: Run** the new test and the existing `KvMotionExportDialog.test.tsx` — both green.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/motion/KvMotionExportDialog.tsx src/components/studio/kv-generator/motion/KvMotionExportDialog.bumpers.test.tsx
git commit -m "feat(web): export dialog mixes bumper audio and records total duration

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: Editor state — `setBumper`, `bumperPreview`

**Files:**
- Modify: `src/components/studio/kv-generator/motion/useMotionEditorState.ts`
- Test: `src/components/studio/kv-generator/motion/useMotionEditorState.bumpers.test.ts` (new; copy `ov1`, `qcWrapper`, `makeProject` verbatim from `useMotionEditorState.test.ts`)

**Interfaces:**
- Consumes: `push` (existing timeline writer with undo), `seek`, `seekByUser`, `BumperPreview` (T1).
- Produces (added to the hook's return):
  - `setBumper(slot: BumperSlot, bumper: MotionBumper | null): void` — writes `timeline.bumpers` through `push` (undoable, autosaved); removing the last slot deletes the `bumpers` key entirely.
  - `updateBumper(slot, patch: Partial<Pick<MotionBumper, "duration_ms"|"fit"|"bg"|"mute"|"volume">>): void`
  - `bumperPreview: BumperPreview`, `setBumperPreview(p: BumperPreview): void` (parks the main playhead at 0 / duration_ms).
  - `seekByUser` now also clears `bumperPreview`.
  - `bumperLayoutValue: BumperLayout` (memoised `bumperLayout(timeline)`).

- [ ] **Step 1: Write the failing tests**

```ts
// …ov1 / qcWrapper / makeProject copied verbatim…
import type { MotionBumper } from "@/lib/video-editor/timeline";

const img: MotionBumper = { bumper_id: "i", kind: "image", url: "u", duration_ms: 2000, natural_ms: 0, src_width: 4, src_height: 2, fit: "contain", bg: "#000000", mute: false, volume: 1 };

function mount() {
  return renderHook(() => useMotionEditorState(makeProject(), { autosave: false }), { wrapper: qcWrapper });
}

describe("useMotionEditorState — bumpers", () => {
  it("setBumper writes the slot without touching duration_ms or tracks, and is undoable", () => {
    const { result } = mount();
    act(() => result.current.setBumper("start", img));
    expect(result.current.timeline.bumpers?.start).toEqual(img);
    expect(result.current.timeline.duration_ms).toBe(5000);
    expect(result.current.bumperLayoutValue).toEqual({ preMs: 2000, mainMs: 5000, postMs: 0, totalMs: 7000 });
    act(() => result.current.undo());
    expect(result.current.timeline.bumpers).toBeUndefined();
  });

  it("removing the last slot deletes the bumpers key", () => {
    const { result } = mount();
    act(() => result.current.setBumper("end", img));
    act(() => result.current.setBumper("end", null));
    expect("bumpers" in result.current.timeline).toBe(false);
  });

  it("updateBumper patches only the given fields", () => {
    const { result } = mount();
    act(() => result.current.setBumper("start", img));
    act(() => result.current.updateBumper("start", { fit: "cover", duration_ms: 3000 }));
    expect(result.current.timeline.bumpers?.start).toMatchObject({ fit: "cover", duration_ms: 3000, bg: "#000000" });
  });

  it("setBumperPreview parks the main playhead; a user seek clears it", () => {
    const { result } = mount();
    act(() => result.current.setBumper("end", img));
    act(() => result.current.seekByUser(2500));
    act(() => result.current.setBumperPreview({ slot: "end", localMs: 400 }));
    expect(result.current.bumperPreview).toEqual({ slot: "end", localMs: 400 });
    expect(result.current.playheadMs).toBe(5000);
    act(() => result.current.setBumperPreview({ slot: "start", localMs: 10 }));
    expect(result.current.playheadMs).toBe(0);
    act(() => result.current.seekByUser(1000));
    expect(result.current.bumperPreview).toBeNull();
    expect(result.current.playheadMs).toBe(1000);
  });

  it("clears the preview when its slot is removed", () => {
    const { result } = mount();
    act(() => result.current.setBumper("start", img));
    act(() => result.current.setBumperPreview({ slot: "start", localMs: 10 }));
    act(() => result.current.setBumper("start", null));
    expect(result.current.bumperPreview).toBeNull();
  });
});
```

- [ ] **Step 2: Run to verify it fails** — `bun test src/components/studio/kv-generator/motion/useMotionEditorState.bumpers.test.ts`.

- [ ] **Step 3: Implement in the hook**

Imports: `import { bumperLayout, type BumperPreview, type BumperSlot } from "@/lib/video-editor/bumpers";` and `MotionBumper` from timeline.

After `seekByUser` is defined, add:

```ts
  // ── Bumpers (2026-09-20) ──
  // Session-only: "the user is looking at a bumper zone". The main playhead
  // stays on the main clock, parked under the zone.
  const [bumperPreview, setBumperPreviewState] = useState<BumperPreview>(null);
  const setBumperPreview = useCallback(
    (p: BumperPreview) => {
      setBumperPreviewState(p);
      if (p) seek(p.slot === "start" ? 0 : timeline.duration_ms);
    },
    [seek, timeline.duration_ms]
  );
  const bumperLayoutValue = useMemo(() => bumperLayout(timeline), [timeline]);

  const setBumper = useCallback(
    (slot: BumperSlot, bumper: MotionBumper | null) => {
      const next = { ...(timeline.bumpers ?? {}) };
      if (bumper) next[slot] = bumper;
      else delete next[slot];
      const { bumpers: _drop, ...rest } = timeline;
      push(Object.keys(next).length > 0 ? { ...rest, bumpers: next } : rest);
      if (!bumper) setBumperPreviewState((p) => (p?.slot === slot ? null : p));
    },
    [timeline, push]
  );

  const updateBumper = useCallback(
    (slot: BumperSlot, patch: Partial<Pick<MotionBumper, "duration_ms" | "fit" | "bg" | "mute" | "volume">>) => {
      const current = timeline.bumpers?.[slot];
      if (!current) return;
      push({ ...timeline, bumpers: { ...timeline.bumpers, [slot]: { ...current, ...patch } } });
    },
    [timeline, push]
  );
```

Change `seekByUser` to also clear the preview:

```ts
  const seekByUser = useCallback(
    (tMs: number) => {
      setPreviewOnce(null);
      setBumperPreviewState(null);
      seek(tMs);
    },
    [seek]
  );
```

(`seekByUser` is declared before the bumper block; `setBumperPreviewState` must be declared above it — move the `useState<BumperPreview>` line up next to `playheadMs`'s `useState`.)

Add to the return object: `bumperPreview, setBumperPreview, bumperLayoutValue, setBumper, updateBumper`.

- [ ] **Step 4: Run** the new test and `useMotionEditorState.test.ts` — both green.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/motion/useMotionEditorState.ts src/components/studio/kv-generator/motion/useMotionEditorState.bumpers.test.ts
git commit -m "feat(web): editor state for bumper slots and bumper preview

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 9: Stage overlay

**Files:**
- Create: `src/components/studio/kv-generator/motion/BumperOverlay.tsx`
- Modify: `src/components/studio/kv-generator/motion/KvMotionTileStage.tsx` (`Props` + root JSX)
- Test: `src/components/studio/kv-generator/motion/BumperOverlay.test.tsx`

**Interfaces:**
- Produces: `<BumperOverlay bumper={MotionBumper} localMs={number} playing={boolean} width={number} height={number} />` — absolutely positioned `inset-0`, `pointer-events: auto`, `data-testid="bumper-overlay"`; renders `<div style={{background: bg}}>` + `<img>` or `<video muted={mute} …>` at `fitRect`.
- `KvMotionTileStage` gains `bumperFrame?: { bumper: MotionBumper; localMs: number } | null` and renders the overlay as the LAST child of its root `div` when set.

- [ ] **Step 1: Write the failing test**

```tsx
import { describe, expect, it } from "bun:test";
import { render, within } from "@testing-library/react";

import type { MotionBumper } from "@/lib/video-editor/timeline";
import { BumperOverlay } from "./BumperOverlay";

const img: MotionBumper = { bumper_id: "i", kind: "image", url: "https://x/l.png", duration_ms: 2000, natural_ms: 0, src_width: 400, src_height: 200, fit: "contain", bg: "#123456", mute: false, volume: 1 };

describe("BumperOverlay", () => {
  it("paints the background and places the image at the contain rect", () => {
    render(<BumperOverlay bumper={img} localMs={0} playing={false} width={1080} height={1080} />);
    const body = within(document.body);
    const root = body.getByTestId("bumper-overlay");
    expect(root.style.backgroundColor).toBe("rgb(18, 52, 86)");
    const image = body.getByRole("img", { hidden: true }) as HTMLImageElement;
    expect(image.src).toBe("https://x/l.png");
    expect(image.style.left).toBe("0px");
    expect(image.style.top).toBe("270px");
    expect(image.style.width).toBe("1080px");
    expect(image.style.height).toBe("540px");
  });

  it("renders a muted video for a video bumper honouring mute", () => {
    const vid = { ...img, kind: "video" as const, url: "https://x/s.mp4", mute: true };
    render(<BumperOverlay bumper={vid} localMs={0} playing={false} width={1080} height={1080} />);
    const video = document.body.querySelector("video") as HTMLVideoElement;
    expect(video.src).toBe("https://x/s.mp4");
    expect(video.muted).toBe(true);
  });

  it("swallows pointer events so nothing beneath can be dragged", () => {
    render(<BumperOverlay bumper={img} localMs={0} playing={false} width={100} height={100} />);
    expect(within(document.body).getByTestId("bumper-overlay").style.pointerEvents).toBe("auto");
  });
});
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Write the component**

```tsx
"use client";

import { useEffect, useRef } from "react";

import { fitRect } from "@/lib/video-editor/bumpers";
import type { MotionBumper } from "@/lib/video-editor/timeline";

type Props = {
  bumper: MotionBumper;
  /** Time inside the bumper, ms. */
  localMs: number;
  playing: boolean;
  width: number;
  height: number;
};

/** Drift beyond this and the preview <video> is re-seeked; below it we let
 *  the element free-run so playback isn't a stutter of seeks. */
const RESYNC_MS = 200;

/** Covers a tile's stage while the playhead is inside a bumper zone. For
 *  preview a plain <img>/<video> is enough — determinism is an export
 *  concern (exportMotion.ts paints decoded samples instead). Pointer events
 *  are swallowed on purpose: nothing under a bumper is editable. */
export function BumperOverlay({ bumper, localMs, playing, width, height }: Props) {
  const r = fitRect({ w: bumper.src_width, h: bumper.src_height }, { w: width, h: height }, bumper.fit);
  const videoRef = useRef<HTMLVideoElement>(null);

  useEffect(() => {
    const v = videoRef.current;
    if (!v) return;
    v.volume = bumper.volume;
    const target = localMs / 1000;
    if (playing) {
      if (Math.abs(v.currentTime - target) > RESYNC_MS / 1000) v.currentTime = target;
      if (v.paused) void v.play().catch(() => {});
    } else {
      if (!v.paused) v.pause();
      if (Math.abs(v.currentTime - target) > 0.001) v.currentTime = target;
    }
  }, [localMs, playing, bumper.volume]);

  const box = { position: "absolute" as const, left: r.x, top: r.y, width: r.w, height: r.h };

  return (
    <div
      data-testid="bumper-overlay"
      style={{ position: "absolute", inset: 0, overflow: "hidden", backgroundColor: bumper.bg, pointerEvents: "auto" }}
    >
      {bumper.kind === "image" ? (
        <img src={bumper.url} alt="" draggable={false} style={box} />
      ) : (
        <video ref={videoRef} src={bumper.url} muted={bumper.mute} playsInline preload="auto" style={box} />
      )}
    </div>
  );
}
```

- [ ] **Step 4: Wire it into `KvMotionTileStage`**

Add to `Props`:

```ts
  /** Set while the playhead is inside a bumper zone — the overlay covers the
   *  stage and nothing underneath can be selected or dragged. */
  bumperFrame?: { bumper: MotionBumper; localMs: number } | null;
```

and as the last child of the root `<div data-tile-key…>`:

```tsx
      {bumperFrame && (
        <BumperOverlay
          bumper={bumperFrame.bumper}
          localMs={bumperFrame.localMs}
          playing={playing}
          width={tile.width}
          height={tile.height}
        />
      )}
```

(`playing` is already a prop of the stage.)

- [ ] **Step 5: Run** `bun test src/components/studio/kv-generator/motion/BumperOverlay.test.tsx` and the existing `KvMotionTileStage` tests (if any) — green.

- [ ] **Step 6: Commit**

```bash
git add src/components/studio/kv-generator/motion/BumperOverlay.tsx src/components/studio/kv-generator/motion/BumperOverlay.test.tsx src/components/studio/kv-generator/motion/KvMotionTileStage.tsx
git commit -m "feat(web): bumper overlay on the motion tile stage

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 10: Dock + Transport — zones, lane offset, playhead, readout

**Files:**
- Modify: `src/components/video-editor/types.ts` (constants + `TimelineDockProps.bumpers`)
- Modify: `src/components/video-editor/BlockTrackRow.tsx` (2 lane boxes), `TrackRow.tsx` (1), `src/components/studio/kv-generator/motion/KvMotionAudioRow.tsx` (3)
- Modify: `src/components/video-editor/Transport.tsx`
- Modify: `src/components/video-editor/TimelineDock.tsx`
- Test: `src/components/video-editor/TimelineDock.bumpers.test.tsx` (new; copy the render harness from `TimelineDock.motionclip.test.tsx`), `src/components/video-editor/Transport.bumpers.test.tsx`

**Interfaces:**
- Produces in `types.ts`:
  ```ts
  export const LANE_OFFSET_VAR = "--motion-lane-offset";
  export const LANE_POST_VAR = "--motion-lane-post";
  /** Every lane box on the axis: width from the axis, left margin = start-bumper zone. */
  export const LANE_BOX_STYLE: React.CSSProperties = {
    width: `var(${LANE_WIDTH_VAR})`,
    marginLeft: `var(${LANE_OFFSET_VAR}, 0px)`,
  };
  export type BumperDock = {
    layout: BumperLayout;
    preview: BumperPreview;
    /** A click inside a zone, `localMs` from the click's fraction of it. */
    onPreviewBumper: (slot: BumperSlot, localMs: number) => void;
    /** Rendered inside the Transport, next to Duration. */
    control: ReactNode;
  };
  ```
  and `TimelineDockProps.bumpers?: BumperDock`.
- `Transport` gains `elapsedMs?: number`, `totalMs?: number`, `bumpersControl?: ReactNode`.

- [ ] **Step 1: Write the failing dock test**

```tsx
// …harness copied from TimelineDock.motionclip.test.tsx: `renderDock(propsOverride)` that
//    mounts <TimelineDock …baseProps …override /> and returns within(document.body)…
import { fireEvent } from "@testing-library/react";

const layout = { preMs: 2000, mainMs: 5000, postMs: 1000, totalMs: 8000 };

describe("TimelineDock — bumper zones", () => {
  it("renders no zones and no offset var without bumpers", () => {
    const body = renderDock({});
    expect(body.queryByTestId("bumper-zone-start")).toBeNull();
    expect(body.queryByTestId("bumper-zone-end")).toBeNull();
    const scroll = body.getByTestId("timeline-scroll").firstElementChild as HTMLElement;
    expect(scroll.style.getPropertyValue("--motion-lane-offset")).toBe("");
  });

  it("renders labelled zones sized from the layout and sets the lane offset var", () => {
    const onPreviewBumper = mock(() => {});
    const body = renderDock({ bumpers: { layout, preview: null, onPreviewBumper, control: null } });
    const start = body.getByTestId("bumper-zone-start");
    const end = body.getByTestId("bumper-zone-end");
    expect(start.textContent).toContain("Start bumper");
    expect(start.textContent).toContain("2.0s");
    expect(end.textContent).toContain("End bumper · 1.0s");
    const scroll = body.getByTestId("timeline-scroll").firstElementChild as HTMLElement;
    // The exact px depends on the dock's measured pxPerSecond; assert the var is a px value > 0.
    expect(scroll.style.getPropertyValue("--motion-lane-offset")).toMatch(/^\d+(\.\d+)?px$/);
  });

  it("a click inside a zone previews that slot at the click's fraction", () => {
    const onPreviewBumper = mock(() => {});
    const body = renderDock({ bumpers: { layout, preview: null, onPreviewBumper, control: null } });
    const start = body.getByTestId("bumper-zone-start");
    Object.defineProperty(start, "getBoundingClientRect", { value: () => ({ left: 100, width: 200, top: 0, height: 24, right: 300, bottom: 24 }) });
    fireEvent.click(start, { clientX: 150 });
    expect(onPreviewBumper).toHaveBeenCalledWith("start", 500);
  });

  it("draws the playhead inside the end zone while previewing it", () => {
    const body = renderDock({ bumpers: { layout, preview: { slot: "end", localMs: 500 }, onPreviewBumper: () => {}, control: null }, playheadMs: 5000 });
    const playhead = body.getByTestId("timeline-playhead");
    // left = calc(12rem + <px>) — the px is playheadAxisPx(layout, 5000, preview, pxPerSecond) = 7.5s * pps.
    expect(playhead.style.left).toMatch(/^calc\(12rem \+ \d+(\.\d+)?px\)$/);
  });
});
```

- [ ] **Step 2: Write the failing transport test**

```tsx
import { describe, expect, it } from "bun:test";
import { render, within } from "@testing-library/react";
import { Transport } from "./Transport";

const base = {
  playing: false, onTogglePlay: () => {}, playheadMs: 1000, durationMs: 5000, fps: 30,
  onDurationChange: () => {}, loop: false, onToggleLoop: () => {}, view: "slots" as const, onViewChange: () => {},
  zoom: 1, onZoomIn: () => {}, onZoomOut: () => {}, canZoomIn: true, canZoomOut: true, onZoomFit: () => {}, fitted: true,
};

describe("Transport — bumpers", () => {
  it("shows elapsed/total on the total clock when given, and the bumpers control", () => {
    render(<Transport {...base} elapsedMs={3000} totalMs={8000} bumpersControl={<button>Bumpers</button>} />);
    const body = within(document.body);
    expect(body.getByText("00:08.00")).toBeInTheDocument();
    expect(body.getByRole("button", { name: "Bumpers" })).toBeInTheDocument();
    expect(body.getByLabelText("Timeline duration in seconds")).toHaveAttribute("title", "Main composition only — excludes bumpers");
  });
  it("falls back to the main clock without them", () => {
    render(<Transport {...base} />);
    expect(within(document.body).getByText("00:05.00")).toBeInTheDocument();
  });
});
```

- [ ] **Step 3: Run both to verify they fail.**

- [ ] **Step 4: Implement `types.ts`**

Add the constants/type from **Interfaces** next to `LANE_WIDTH_VAR` (import `BumperLayout`, `BumperPreview`, `BumperSlot` from `@/lib/video-editor/bumpers`, `ReactNode` from react, `CSSProperties`). Add `bumpers?: BumperDock;` to `TimelineDockProps` with the comment: `/** Start/end bumper zones beside the main lane (2026-09-20). Absent = the pre-bumper dock, byte for byte. */`.

- [ ] **Step 5: Replace the six lane-box styles**

In `BlockTrackRow.tsx` (both `style={{ width: \`var(${LANE_WIDTH_VAR})\` }}` occurrences, on `prop-lane-*` and `track-lane-*`), `TrackRow.tsx` (one), `KvMotionAudioRow.tsx` (three): replace with `style={LANE_BOX_STYLE}` and import `LANE_BOX_STYLE` from `@/components/video-editor/types` (drop the now-unused `LANE_WIDTH_VAR` import where applicable). Run the whole `src/components/video-editor` test directory and the three `KvMotionAudioRow*.test.*` files — they must stay green (the var defaults to `0px`).

- [ ] **Step 6: Implement `Transport.tsx`**

Props:

```ts
  /** Total-clock readout (2026-09-20 bumpers). Falls back to `playheadMs` /
   *  `durationMs` when absent, so a host without bumpers is unchanged. */
  elapsedMs?: number;
  totalMs?: number;
  /** The Bumpers popover trigger — lives here because the transport never
   *  scrolls or zooms away (see lesson_dock_row_controls_must_live_in_sticky_rail). */
  bumpersControl?: ReactNode;
```

Readout: `formatTime(elapsedMs ?? playheadMs)` in the non-`onSeek` branch and for `timeDraft`'s follow value; `/ {formatTime(totalMs ?? durationMs)}`. The seek field's clamp stays `[0, durationMs]` (a typed time is a main-clock time). Duration `Input` gets `title="Main composition only — excludes bumpers"`. Render `{bumpersControl}` inside the right cluster, before the Duration group:

```tsx
      <div className="ml-auto flex items-center gap-3">
        {bumpersControl}
        <div role="group" aria-label="Timeline view" …>
```

- [ ] **Step 7: Implement `TimelineDock.tsx`**

Imports: `LANE_OFFSET_VAR, LANE_POST_VAR` from `./types`; `playheadAxisPx` from `@/lib/video-editor/bumpers`.

Derive, after `pxPerSecond`:

```ts
  const bumperLayoutV = bumpers?.layout ?? { preMs: 0, mainMs: timeline.duration_ms, postMs: 0, totalMs: timeline.duration_ms };
  const prePx = (bumperLayoutV.preMs / 1000) * pxPerSecond;
  const postPx = (bumperLayoutV.postMs / 1000) * pxPerSecond;
```

Fit scale includes bumpers: in `fitScale`, replace `durationSec * BASE_PX_PER_SECOND` with `((bumpers?.layout.totalMs ?? timeline.duration_ms) / 1000) * BASE_PX_PER_SECOND`.

Container style (the `relative` div inside `timeline-scroll`, and the audio slot's mirror):

```ts
{
  [LANE_WIDTH_VAR]: `${lanePx}px`,
  ...(bumpers ? { [LANE_OFFSET_VAR]: `${prePx}px`, [LANE_POST_VAR]: `${postPx}px` } : {}),
  width: `calc(${RAIL_WIDTH_CSS} + ${prePx + lanePx + postPx}px)`,
  minWidth: "100%",
}
```

Ruler wrapper `<div className="shrink-0" style={{ width: lanePx }}>` becomes `style={{ width: lanePx, marginLeft: prePx }}`.

Zones — rendered as absolutely positioned siblings of the playhead (inside the `relative` container), only when `bumpers` is set; a helper component in the same file:

```tsx
function BumperZone({ slot, ms, leftPx, widthPx, onClick }: { slot: "start" | "end"; ms: number; leftPx: number; widthPx: number; onClick: (localMs: number) => void }) {
  if (widthPx <= 0) return null;
  return (
    <button
      type="button"
      data-testid={`bumper-zone-${slot}`}
      aria-label={`${slot === "start" ? "Start" : "End"} bumper, ${(ms / 1000).toFixed(1)} seconds`}
      onClick={(e) => {
        const rect = e.currentTarget.getBoundingClientRect();
        const frac = rect.width > 0 ? Math.min(1, Math.max(0, (e.clientX - rect.left) / rect.width)) : 0;
        onClick(Math.round(frac * ms));
      }}
      className="absolute inset-y-0 z-10 flex items-start justify-center overflow-hidden border-x border-border-default text-textXs text-text-inverse-subtlest"
      style={{
        left: `calc(${RAIL_WIDTH_CSS} + ${leftPx}px)`,
        width: widthPx,
        backgroundImage: "repeating-linear-gradient(135deg, transparent 0 6px, rgba(255,255,255,0.06) 6px 7px)",
      }}
    >
      <span className="sticky top-0 whitespace-nowrap px-2 py-1">
        {slot === "start" ? "Start" : "End"} bumper · {(ms / 1000).toFixed(1)}s
      </span>
    </button>
  );
}
```

mounted as:

```tsx
          {bumpers && (
            <>
              <BumperZone slot="start" ms={bumperLayoutV.preMs} leftPx={0} widthPx={prePx} onClick={(ms) => bumpers.onPreviewBumper("start", ms)} />
              <BumperZone slot="end" ms={bumperLayoutV.postMs} leftPx={prePx + lanePx} widthPx={postPx} onClick={(ms) => bumpers.onPreviewBumper("end", ms)} />
            </>
          )}
```

Playhead (both the lane line and the audio-slot segment):

```ts
const playheadPx = bumpers
  ? playheadAxisPx(bumpers.layout, playheadMs, bumpers.preview, pxPerSecond)
  : (playheadMs / 1000) * pxPerSecond;
// style: left: `calc(${RAIL_WIDTH_CSS} + ${playheadPx}px)`
```

(This replaces the `frac * var(LANE_WIDTH_VAR)` expression; without bumpers `playheadPx === frac * lanePx`, so the position is unchanged.) The preview-range dims add `prePx` to their `left` (`left: \`calc(${RAIL_WIDTH_CSS} + ${prePx}px)\`` and `+ ${prePx}px` inside the "after" calc).

Transport props: `elapsedMs={bumpers ? totalClockMs(bumpers.layout, playheadMs, bumpers.preview) : undefined}`, `totalMs={bumpers?.layout.totalMs}`, `bumpersControl={bumpers?.control}` (import `totalClockMs`).

- [ ] **Step 8: Run** the two new tests plus every `src/components/video-editor/*.test.tsx` and `KvMotionAudioRow*.test.*` — all green. Pay attention to any existing test asserting the playhead's `left` as `calc(12rem + <frac> * var(--motion-lane-w))`: update it to the px form and confirm the number equals `frac * lanePx` for that test's measured width (the harness stubs `getBoundingClientRect`; read the value it stubs).

- [ ] **Step 9: Commit**

```bash
git add src/components/video-editor/types.ts src/components/video-editor/BlockTrackRow.tsx src/components/video-editor/TrackRow.tsx src/components/studio/kv-generator/motion/KvMotionAudioRow.tsx src/components/video-editor/Transport.tsx src/components/video-editor/TimelineDock.tsx src/components/video-editor/TimelineDock.bumpers.test.tsx src/components/video-editor/Transport.bumpers.test.tsx
git commit -m "feat(web): bumper zones on the timeline dock and total-clock transport readout

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 11: `BumperSlots` popover + `BumperLibraryPicker`

**Files:**
- Create: `src/components/studio/kv-generator/motion/BumperLibraryPicker.tsx`
- Create: `src/components/studio/kv-generator/motion/BumperSlots.tsx`
- Test: `src/components/studio/kv-generator/motion/BumperLibraryPicker.test.tsx`, `src/components/studio/kv-generator/motion/BumperSlots.test.tsx`
- Reference: `TrackPresetMenu.tsx` (Popover usage), `KvMotionNamePill.test.tsx` (test style), `@/components/frndos/v2` `Button`, `Popover`, `Slider`; `@/components/frndos` `Input`, `Toggle`.

**Interfaces:**
- `BumperLibraryPicker` props:
  ```ts
  {
    rows: KvMotionBumperRow[];
    loading: boolean;
    onPick: (row: KvMotionBumperRow) => void;
    onUpload: (file: File) => Promise<KvMotionBumperRow>;   // resolves the created row; the picker calls onPick with it
    onDelete: (row: KvMotionBumperRow) => Promise<void>;
    onError: (message: string) => void;
  }
  ```
  Renders `data-testid="bumper-library"`, one `button` per row named `Use <name>`, a file `input` (`aria-label="Upload bumper"`, `accept={BUMPER_ACCEPT}`), kebab → `Delete from library` → inline confirm (`Delete` / `Cancel`), empty state text *"No bumpers yet for this brand — upload a logo lockup once and reuse it on every motion."*
- `BumperSlots` props:
  ```ts
  {
    open: boolean;
    onOpenChange: (o: boolean) => void;
    focusSlot: BumperSlot | null;           // which card to scroll/highlight on open
    bumpers: MotionTimeline["bumpers"];
    library: KvMotionBumperRow[];
    libraryLoading: boolean;
    onSet: (slot: BumperSlot, row: KvMotionBumperRow, source: "library" | "upload") => void;
    onUpdate: (slot: BumperSlot, patch: Partial<Pick<MotionBumper, "duration_ms"|"fit"|"bg"|"mute"|"volume">>) => void;
    onRemove: (slot: BumperSlot) => void;
    onUpload: (file: File) => Promise<KvMotionBumperRow>;
    onDeleteFromLibrary: (row: KvMotionBumperRow) => Promise<void>;
    onError: (message: string) => void;
  }
  ```
  Renders a `Popover` whose trigger is a `Button` labelled `Bumpers` (with a count badge `1`/`2` when filled) and content `data-testid="bumper-slots"` with two `section`s `aria-label="Start bumper"` / `"End bumper"`. Empty card: `Choose bumper` opens the picker inline for that slot. Filled card: name, thumbnail, `Duration` number input (seconds, one decimal; clamped by `bumperDurationBounds`), `Fit` two-button group `Contain`/`Cover`, `Background` colour `<input type="color">` (contain only), `Mute` toggle + `Volume` slider (video only), `Remove`, `Swap` (reopens picker).

- [ ] **Step 1: Write the failing picker test**

```tsx
import { describe, expect, it, mock } from "bun:test";
import { fireEvent, render, waitFor, within } from "@testing-library/react";
import type { KvMotionBumperRow } from "@/types/kv/motionBumper";
import { BumperLibraryPicker } from "./BumperLibraryPicker";

const row = (o: Partial<KvMotionBumperRow> = {}): KvMotionBumperRow => ({
  id: "b1", brandId: "br", name: "Telkomsel lockup", kind: "image", url: "https://x/l.png",
  durationMs: 0, width: 400, height: 200, createdBy: "u", createdAt: "c", updatedAt: "u", ...o,
});

function setup(rows: KvMotionBumperRow[], over: Partial<Parameters<typeof BumperLibraryPicker>[0]> = {}) {
  const props = {
    rows, loading: false,
    onPick: mock(() => {}), onUpload: mock(async () => row({ id: "new", name: "s.mp4" })),
    onDelete: mock(async () => {}), onError: mock(() => {}), ...over,
  };
  render(<BumperLibraryPicker {...props} />);
  return { body: within(document.body), ...props };
}

describe("BumperLibraryPicker", () => {
  it("shows the empty state", () => {
    const s = setup([]);
    expect(s.body.getByText(/No bumpers yet for this brand/)).toBeInTheDocument();
  });
  it("lists rows with kind and duration, and picks on click", () => {
    const s = setup([row(), row({ id: "b2", name: "Sting", kind: "video", durationMs: 2500 })]);
    expect(s.body.getByText("2.5s")).toBeInTheDocument();
    fireEvent.click(s.body.getByRole("button", { name: "Use Sting" }));
    expect(s.onPick).toHaveBeenCalledWith(expect.objectContaining({ id: "b2" }));
  });
  it("uploads then picks the new row", async () => {
    const s = setup([]);
    const input = s.body.getByLabelText("Upload bumper") as HTMLInputElement;
    const file = new File([new Uint8Array([1])], "s.mp4", { type: "video/mp4" });
    fireEvent.change(input, { target: { files: [file] } });
    await waitFor(() => expect(s.onUpload).toHaveBeenCalledWith(file));
    await waitFor(() => expect(s.onPick).toHaveBeenCalledWith(expect.objectContaining({ id: "new" })));
  });
  it("surfaces an upload failure through onError", async () => {
    const s = setup([], { onUpload: mock(async () => { throw new Error("Couldn't read this video — try an MP4 (H.264)."); }) });
    fireEvent.change(s.body.getByLabelText("Upload bumper"), { target: { files: [new File([new Uint8Array([1])], "x.mp4", { type: "video/mp4" })] } });
    await waitFor(() => expect(s.onError).toHaveBeenCalledWith("Couldn't read this video — try an MP4 (H.264)."));
  });
  it("deletes only after confirming", async () => {
    const s = setup([row()]);
    fireEvent.click(s.body.getByRole("button", { name: "More actions for Telkomsel lockup" }));
    fireEvent.click(s.body.getByRole("menuitem", { name: "Delete from library" }));
    expect(s.onDelete).not.toHaveBeenCalled();
    fireEvent.click(s.body.getByRole("button", { name: "Delete" }));
    await waitFor(() => expect(s.onDelete).toHaveBeenCalledWith(expect.objectContaining({ id: "b1" })));
  });
});
```

- [ ] **Step 2: Write the failing slots test**

```tsx
import { describe, expect, it, mock } from "bun:test";
import { fireEvent, render, within } from "@testing-library/react";
import type { MotionBumper } from "@/lib/video-editor/timeline";
import { BumperSlots } from "./BumperSlots";

const img: MotionBumper = { bumper_id: "b1", kind: "image", url: "https://x/l.png", duration_ms: 2000, natural_ms: 0, src_width: 4, src_height: 2, fit: "contain", bg: "#000000", mute: false, volume: 1 };
const vid: MotionBumper = { ...img, bumper_id: "b2", kind: "video", url: "https://x/s.mp4", duration_ms: 2500, natural_ms: 2500 };

function setup(bumpers: { start?: MotionBumper; end?: MotionBumper } | undefined) {
  const props = {
    open: true, onOpenChange: mock(() => {}), focusSlot: null, bumpers,
    library: [], libraryLoading: false,
    onSet: mock(() => {}), onUpdate: mock(() => {}), onRemove: mock(() => {}),
    onUpload: mock(async () => { throw new Error("unused"); }), onDeleteFromLibrary: mock(async () => {}), onError: mock(() => {}),
  };
  render(<BumperSlots {...props} />);
  return { body: within(document.body), ...props };
}

describe("BumperSlots", () => {
  it("shows two empty cards with Choose buttons", () => {
    const s = setup(undefined);
    const start = s.body.getByRole("region", { name: "Start bumper" });
    expect(within(start).getByRole("button", { name: "Choose bumper" })).toBeInTheDocument();
    expect(within(s.body.getByRole("region", { name: "End bumper" })).getByRole("button", { name: "Choose bumper" })).toBeInTheDocument();
  });
  it("a filled image card edits duration (clamped), fit and background", () => {
    const s = setup({ start: img });
    const start = s.body.getByRole("region", { name: "Start bumper" });
    const duration = within(start).getByLabelText("Duration in seconds") as HTMLInputElement;
    fireEvent.change(duration, { target: { value: "99" } });
    fireEvent.blur(duration);
    expect(s.onUpdate).toHaveBeenCalledWith("start", { duration_ms: 10000 });
    fireEvent.click(within(start).getByRole("button", { name: "Cover" }));
    expect(s.onUpdate).toHaveBeenCalledWith("start", { fit: "cover" });
    fireEvent.change(within(start).getByLabelText("Background colour"), { target: { value: "#ff0000" } });
    expect(s.onUpdate).toHaveBeenCalledWith("start", { bg: "#ff0000" });
    expect(within(start).queryByLabelText("Mute")).toBeNull();
  });
  it("a filled video card clamps duration to natural and exposes mute", () => {
    const s = setup({ end: vid });
    const end = s.body.getByRole("region", { name: "End bumper" });
    const duration = within(end).getByLabelText("Duration in seconds");
    fireEvent.change(duration, { target: { value: "9" } });
    fireEvent.blur(duration);
    expect(s.onUpdate).toHaveBeenCalledWith("end", { duration_ms: 2500 });
    fireEvent.click(within(end).getByLabelText("Mute"));
    expect(s.onUpdate).toHaveBeenCalledWith("end", { mute: true });
  });
  it("Remove clears the slot", () => {
    const s = setup({ start: img });
    fireEvent.click(within(s.body.getByRole("region", { name: "Start bumper" })).getByRole("button", { name: "Remove" }));
    expect(s.onRemove).toHaveBeenCalledWith("start");
  });
  it("the trigger shows how many slots are filled", () => {
    const s = setup({ start: img, end: vid });
    expect(s.body.getByRole("button", { name: /Bumpers.*2/ })).toBeInTheDocument();
  });
});
```

- [ ] **Step 3: Run both to verify they fail.**

- [ ] **Step 4: Write `BumperLibraryPicker.tsx`**

```tsx
"use client";

import { useRef, useState } from "react";
import { DotsThreeVertical, UploadSimple } from "@phosphor-icons/react";

import { Button, Popover } from "@/components/frndos/v2";
import { BUMPER_ACCEPT } from "@/lib/video-editor/bumperMetadata";
import type { KvMotionBumperRow } from "@/types/kv/motionBumper";

type Props = {
  rows: KvMotionBumperRow[];
  loading: boolean;
  onPick: (row: KvMotionBumperRow) => void;
  /** Resolves the created row; the picker then picks it. Rejects with a
   *  user-facing message (metadata read or api failure). */
  onUpload: (file: File) => Promise<KvMotionBumperRow>;
  onDelete: (row: KvMotionBumperRow) => Promise<void>;
  onError: (message: string) => void;
};

const fmt = (ms: number) => `${(ms / 1000).toFixed(1)}s`;

/** The brand's bumper library: pick, upload-and-pick, delete. */
export function BumperLibraryPicker({ rows, loading, onPick, onUpload, onDelete, onError }: Props) {
  const fileRef = useRef<HTMLInputElement>(null);
  const [uploading, setUploading] = useState(false);
  const [confirming, setConfirming] = useState<string | null>(null);

  async function handleFile(file: File | undefined) {
    if (!file) return;
    setUploading(true);
    try {
      onPick(await onUpload(file));
    } catch (err) {
      onError(err instanceof Error ? err.message : "Upload failed.");
    } finally {
      setUploading(false);
      if (fileRef.current) fileRef.current.value = "";
    }
  }

  return (
    <div data-testid="bumper-library" className="flex flex-col gap-2">
      <input
        ref={fileRef}
        type="file"
        accept={BUMPER_ACCEPT}
        aria-label="Upload bumper"
        className="hidden"
        onChange={(e) => void handleFile(e.target.files?.[0])}
      />
      <Button variant="secondary" size="small" disabled={uploading} onClick={() => fileRef.current?.click()}>
        <UploadSimple /> {uploading ? "Uploading…" : "Upload new"}
      </Button>

      {loading ? (
        <p className="text-textXs text-text-inverse-subtlest">Loading…</p>
      ) : rows.length === 0 ? (
        <p className="text-textXs text-text-inverse-subtlest">
          No bumpers yet for this brand — upload a logo lockup once and reuse it on every motion.
        </p>
      ) : (
        <ul className="grid grid-cols-2 gap-2">
          {rows.map((row) => (
            <li key={row.id} className="relative">
              <button
                type="button"
                aria-label={`Use ${row.name}`}
                onClick={() => onPick(row)}
                className="flex w-full flex-col gap-1 rounded-lg border border-border-default p-2 text-left hover:bg-white/[0.06]"
              >
                <span className="flex aspect-video w-full items-center justify-center overflow-hidden rounded bg-black">
                  {row.kind === "image" ? (
                    <img src={row.url} alt="" className="max-h-full max-w-full object-contain" />
                  ) : (
                    <video src={row.url} muted playsInline preload="metadata" className="max-h-full max-w-full" />
                  )}
                </span>
                <span className="truncate text-textXsMedium text-text-inverse">{row.name}</span>
                <span className="text-textXs text-text-inverse-subtlest">
                  {row.kind === "image" ? "Image" : `Video · ${fmt(row.durationMs)}`}
                </span>
              </button>
              {confirming === row.id ? (
                <span className="absolute right-1 top-1 flex gap-1 rounded bg-app-panel p-1">
                  <Button size="tiny" variant="secondary" onClick={() => { setConfirming(null); void onDelete(row); }}>Delete</Button>
                  <Button size="tiny" variant="text" onClick={() => setConfirming(null)}>Cancel</Button>
                </span>
              ) : (
                <Popover>
                  <Popover.Trigger asChild>
                    <button type="button" aria-label={`More actions for ${row.name}`} className="absolute right-1 top-1 rounded bg-black/60 p-1">
                      <DotsThreeVertical />
                    </button>
                  </Popover.Trigger>
                  <Popover.Content side="bottom" align="end">
                    <button type="button" role="menuitem" onClick={() => setConfirming(row.id)} className="px-2 py-1 text-textXs">
                      Delete from library
                    </button>
                  </Popover.Content>
                </Popover>
              )}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
```

(If `Popover` in this project needs `open`/`onOpenChange` to be controlled — check `TrackPresetMenu.tsx` — mirror that; the test only needs the `menuitem` to appear after the trigger click.)

- [ ] **Step 5: Write `BumperSlots.tsx`**

```tsx
"use client";

import { useState } from "react";
import { FilmStrip } from "@phosphor-icons/react";

import { Input, Toggle } from "@/components/frndos";
import { Button, Popover, Slider } from "@/components/frndos/v2";
import { bumperDurationBounds, type BumperSlot } from "@/lib/video-editor/bumpers";
import type { MotionBumper, MotionTimeline } from "@/lib/video-editor/timeline";
import type { KvMotionBumperRow } from "@/types/kv/motionBumper";

import { BumperLibraryPicker } from "./BumperLibraryPicker";

type Patch = Partial<Pick<MotionBumper, "duration_ms" | "fit" | "bg" | "mute" | "volume">>;

type Props = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  focusSlot: BumperSlot | null;
  bumpers: MotionTimeline["bumpers"];
  library: KvMotionBumperRow[];
  libraryLoading: boolean;
  onSet: (slot: BumperSlot, row: KvMotionBumperRow, source: "library" | "upload") => void;
  onUpdate: (slot: BumperSlot, patch: Patch) => void;
  onRemove: (slot: BumperSlot) => void;
  onUpload: (file: File) => Promise<KvMotionBumperRow>;
  onDeleteFromLibrary: (row: KvMotionBumperRow) => Promise<void>;
  onError: (message: string) => void;
};

const LABEL: Record<BumperSlot, string> = { start: "Start bumper", end: "End bumper" };

export function BumperSlots(props: Props) {
  const filled = ["start", "end"].filter((s) => props.bumpers?.[s as BumperSlot]).length;
  return (
    <Popover open={props.open} onOpenChange={props.onOpenChange}>
      <Popover.Trigger asChild>
        <Button variant={filled ? "secondary" : "text"} size="tiny" aria-label={`Bumpers${filled ? `, ${filled} set` : ""}`}>
          <FilmStrip /> Bumpers{filled ? ` ${filled}` : ""}
        </Button>
      </Popover.Trigger>
      <Popover.Content side="top" align="end" className="w-96">
        <div data-testid="bumper-slots" className="flex flex-col gap-3">
          {(["start", "end"] as const).map((slot) => (
            <SlotCard key={slot} slot={slot} highlighted={props.focusSlot === slot} bumper={props.bumpers?.[slot]} {...props} />
          ))}
        </div>
      </Popover.Content>
    </Popover>
  );
}

function SlotCard({ slot, highlighted, bumper, library, libraryLoading, onSet, onUpdate, onRemove, onUpload, onDeleteFromLibrary, onError }:
  Props & { slot: BumperSlot; highlighted: boolean; bumper: MotionBumper | undefined }) {
  const [picking, setPicking] = useState(false);
  const [uploadedId, setUploadedId] = useState<string | null>(null);

  const pick = (row: KvMotionBumperRow) => {
    onSet(slot, row, row.id === uploadedId ? "upload" : "library");
    setUploadedId(null);
    setPicking(false);
  };
  const upload = async (file: File) => {
    const row = await onUpload(file);
    setUploadedId(row.id);
    return row;
  };

  return (
    <section aria-label={LABEL[slot]} className={`rounded-xl border p-3 ${highlighted ? "border-white/40" : "border-border-default"}`}>
      <h3 className="mb-2 text-textXsMedium text-text-inverse">{LABEL[slot]}</h3>
      {!bumper || picking ? (
        picking || !bumper ? (
          <>
            {!picking && <Button variant="secondary" size="small" onClick={() => setPicking(true)}>Choose bumper</Button>}
            {picking && (
              <BumperLibraryPicker rows={library} loading={libraryLoading} onPick={pick} onUpload={upload} onDelete={onDeleteFromLibrary} onError={onError} />
            )}
          </>
        ) : null
      ) : (
        <FilledCard slot={slot} bumper={bumper} inLibrary={library.some((r) => r.id === bumper.bumper_id)} onUpdate={onUpdate} onRemove={onRemove} onSwap={() => setPicking(true)} />
      )}
    </section>
  );
}

function FilledCard({ slot, bumper, inLibrary, onUpdate, onRemove, onSwap }: {
  slot: BumperSlot; bumper: MotionBumper; inLibrary: boolean;
  onUpdate: Props["onUpdate"]; onRemove: Props["onRemove"]; onSwap: () => void;
}) {
  const bounds = bumperDurationBounds(bumper);
  const [draft, setDraft] = useState((bumper.duration_ms / 1000).toFixed(1));
  const commitDuration = () => {
    const n = Number(draft);
    if (!Number.isFinite(n)) { setDraft((bumper.duration_ms / 1000).toFixed(1)); return; }
    const ms = Math.min(bounds.max, Math.max(bounds.min, Math.round(n * 1000)));
    setDraft((ms / 1000).toFixed(1));
    if (ms !== bumper.duration_ms) onUpdate(slot, { duration_ms: ms });
  };
  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-center gap-2">
        <span className="flex h-10 w-16 items-center justify-center overflow-hidden rounded bg-black" style={{ backgroundColor: bumper.bg }}>
          {bumper.kind === "image" ? <img src={bumper.url} alt="" className="max-h-full max-w-full object-contain" /> : <video src={bumper.url} muted playsInline preload="metadata" className="max-h-full max-w-full" />}
        </span>
        <span className="min-w-0 flex-1 text-textXs text-text-inverse-subtle">
          {bumper.kind === "image" ? "Image" : "Video"}
          {!inLibrary && <span className="ml-1 text-text-inverse-subtlest">(deleted from library)</span>}
        </span>
        <Button variant="text" size="tiny" onClick={onSwap}>Swap</Button>
        <Button variant="text" size="tiny" onClick={() => onRemove(slot)}>Remove</Button>
      </div>
      <label className="flex items-center justify-between gap-2 text-textXs text-text-inverse-subtlest">
        Duration
        <Input size="compact" type="text" inputMode="decimal" aria-label="Duration in seconds" value={draft}
          onChange={(e) => setDraft(e.target.value)} onBlur={commitDuration}
          onKeyDown={(e) => { if (e.key === "Enter") e.currentTarget.blur(); }}
          rightIcon={<span className="text-textXs">s</span>} classNameContainer="w-24" />
      </label>
      <div role="group" aria-label="Fit" className="flex items-center justify-between gap-2 text-textXs text-text-inverse-subtlest">
        Fit
        <span className="flex gap-1">
          <Button size="tiny" variant={bumper.fit === "contain" ? "secondary" : "text"} aria-pressed={bumper.fit === "contain"} onClick={() => onUpdate(slot, { fit: "contain" })}>Contain</Button>
          <Button size="tiny" variant={bumper.fit === "cover" ? "secondary" : "text"} aria-pressed={bumper.fit === "cover"} onClick={() => onUpdate(slot, { fit: "cover" })}>Cover</Button>
        </span>
      </div>
      {bumper.fit === "contain" && (
        <label className="flex items-center justify-between gap-2 text-textXs text-text-inverse-subtlest">
          Background
          <input type="color" aria-label="Background colour" value={bumper.bg} onChange={(e) => onUpdate(slot, { bg: e.target.value })} />
        </label>
      )}
      {bumper.kind === "video" && (
        <>
          <label className="flex items-center justify-between gap-2 text-textXs text-text-inverse-subtlest">
            Mute
            <Toggle aria-label="Mute" checked={bumper.mute} onChange={(next: boolean) => onUpdate(slot, { mute: next })} />
          </label>
          {!bumper.mute && (
            <label className="flex items-center justify-between gap-2 text-textXs text-text-inverse-subtlest">
              Volume
              <Slider aria-label="Volume" min={0} max={1} step={0.05} value={bumper.volume} onChange={(v: number) => onUpdate(slot, { volume: v })} />
            </label>
          )}
        </>
      )}
    </div>
  );
}
```

Check `Toggle`'s and `Slider`'s actual prop names in `src/components/frndos/Toggle.tsx` and `src/components/frndos/v2/Slider.tsx` (`checked`/`onChange` vs `value`/`onValueChange`) and use those; the test queries by `aria-label="Mute"`.

- [ ] **Step 6: Run** both tests — green. Fix prop names per the actual primitives.

- [ ] **Step 7: Commit**

```bash
git add src/components/studio/kv-generator/motion/BumperLibraryPicker.tsx src/components/studio/kv-generator/motion/BumperLibraryPicker.test.tsx src/components/studio/kv-generator/motion/BumperSlots.tsx src/components/studio/kv-generator/motion/BumperSlots.test.tsx
git commit -m "feat(web): Bumpers popover with start/end slot cards and brand library picker

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 12: Editor wiring — query, mutations, playback loop, codec gate

**Files:**
- Modify: `src/components/studio/kv-generator/motion/KvMotionEditor.tsx`
- Test: `src/components/studio/kv-generator/motion/KvMotionEditor.bumpers.test.tsx` only if `KvMotionEditor` already has a render-level test harness to copy; otherwise verification is the manual checklist in Step 6 (the editor is a 100 KB component with no existing render test — do not invent a harness here).

**Interfaces:**
- Consumes everything above. Produces the user-visible feature.

- [ ] **Step 1: Library query + mutations**

Next to `templatesQuery`:

```ts
  const bumpersQuery = useQuery({
    queryKey: motionBumpersKey(fileId),
    queryFn: () => listMotionBumpers(fileId),
    enabled: Boolean(fileId),
    meta: { suppressErrorToast: true }, // same reason as templatesQuery: api may lag web
  });
  const bumperLibrary = useMemo(() => bumpersQuery.data ?? [], [bumpersQuery.data]);
  const invalidateBumpers = () => qc.invalidateQueries({ queryKey: MOTION_BUMPERS_ROOT });

  const uploadBumper = useCallback(
    async (file: File): Promise<KvMotionBumperRow> => {
      const meta = await readBumperFileMetadata(file); // throws the user-facing message
      const row = await uploadMotionBumper(fileId, {
        name: file.name.replace(/\.[^.]+$/, ""),
        file,
        durationMs: meta.durationMs,
        width: meta.width,
        height: meta.height,
      });
      trackKvMotionBumperLibraryUploaded({ project_id: project.id, kind: row.kind, duration_ms: row.durationMs, bytes: file.size });
      void invalidateBumpers();
      return row;
    },
    [fileId, project.id]
  );

  const deleteBumperFromLibrary = useCallback(
    async (row: KvMotionBumperRow) => {
      await deleteMotionBumper(fileId, row.id);
      trackKvMotionBumperLibraryDeleted({ project_id: project.id, kind: row.kind });
      void invalidateBumpers();
    },
    [fileId, project.id]
  );
```

- [ ] **Step 2: Slot handlers + popover state**

```ts
  const [bumpersOpen, setBumpersOpen] = useState(false);
  const [bumperFocusSlot, setBumperFocusSlot] = useState<BumperSlot | null>(null);

  const handleSetBumper = useCallback(
    (slot: BumperSlot, row: KvMotionBumperRow, source: "library" | "upload") => {
      const b = bumperFromLibrary({ id: row.id, kind: row.kind, url: row.url, duration_ms: row.durationMs, width: row.width, height: row.height });
      state.setBumper(slot, b);
      trackKvMotionBumperSet({ project_id: project.id, slot, kind: b.kind, source, duration_ms: b.duration_ms, fit: b.fit });
    },
    [state, project.id]
  );
  const handleRemoveBumper = useCallback(
    (slot: BumperSlot) => {
      const kind = state.timeline.bumpers?.[slot]?.kind;
      state.setBumper(slot, null);
      if (kind) trackKvMotionBumperRemoved({ project_id: project.id, slot, kind });
    },
    [state, project.id]
  );

  const bumpersControl = (
    <BumperSlots
      open={bumpersOpen}
      onOpenChange={(o) => { setBumpersOpen(o); if (!o) setBumperFocusSlot(null); }}
      focusSlot={bumperFocusSlot}
      bumpers={state.timeline.bumpers}
      library={bumperLibrary}
      libraryLoading={bumpersQuery.isPending}
      onSet={handleSetBumper}
      onUpdate={state.updateBumper}
      onRemove={handleRemoveBumper}
      onUpload={uploadBumper}
      onDeleteFromLibrary={deleteBumperFromLibrary}
      onError={(m) => showToast("Bumper", m, "error")}
    />
  );
```

Pass to the dock:

```tsx
          bumpers={{
            layout: state.bumperLayoutValue,
            preview: state.bumperPreview,
            onPreviewBumper: (slot, localMs) => {
              pauseAudioPreview();
              state.setBumperPreview({ slot, localMs });
            },
            control: bumpersControl,
          }}
```

(Only pass `bumpers` when `state.timeline.bumpers` has a slot OR always? Always — the `Bumpers` button must be reachable to add the first one. With no slots, `layout` is the identity and the zones render at 0 width.)

- [ ] **Step 3: Stage frame prop**

Where each `<KvMotionTileStage …>` is rendered:

```tsx
                bumperFrame={
                  state.bumperPreview
                    ? (() => {
                        const b = state.timeline.bumpers?.[state.bumperPreview.slot];
                        return b ? { bumper: b, localMs: state.bumperPreview.localMs } : null;
                      })()
                    : null
                }
```

(Hoist to a `useMemo` named `bumperFrame` above the JSX rather than an IIFE in props.)

- [ ] **Step 4: Playback loop on the total clock**

In the `useEffect` playback loop, after `const range = state.previewRange;`:

```ts
    const layout = state.bumperLayoutValue;
    // Bumpers play only in the plain, unscoped case: a preview range or a
    // once-through auto-preview is a main-clock look at one stretch.
    const withBumpers = !once && !range && layout.totalMs > layout.mainMs;
```

Then, when `withBumpers`, run the clock on total ms:

```ts
    if (withBumpers) {
      let startTotal = totalClockMs(layout, state.playheadMs, state.bumperPreview);
      if (startTotal >= layout.totalMs - 1) startTotal = 0;
      let startTs2: number | null = null;
      function tickTotal(ts: number) {
        if (startTs2 === null) startTs2 = ts;
        let next = startTotal + (ts - startTs2);
        if (next >= layout.totalMs) {
          if (loop) {
            next = next % layout.totalMs;
            startTotal = 0;
            startTs2 = ts;
            pauseAudioPreview();
          } else {
            state.setBumperPreview(null);
            state.seek(layout.mainMs);
            pauseAudioPreview();
            state.setPlaying(false);
            return;
          }
        }
        const frame = resolveBumperFrame(state.timeline, next);
        if (frame.kind === "main") {
          if (state.bumperPreview) state.setBumperPreview(null);
          state.seek(frame.mainMs);
          syncAudioForPlayhead(frame.mainMs);
        } else {
          pauseAudioPreview();
          state.setBumperPreview({ slot: frame.slot, localMs: frame.localMs });
        }
        raf = requestAnimationFrame(tickTotal);
      }
      raf = requestAnimationFrame(tickTotal);
      return () => { cancelAnimationFrame(raf); pauseAudioPreview(); };
    }
```

placed BEFORE the existing `let startPlayhead = …` block so the old loop is untouched for the non-bumper case. Add `state.bumperLayoutValue`, `state.bumperPreview`, `state.setBumperPreview`, `state.timeline` to the effect's dependency list only if they are not already covered by the existing `// eslint-disable-next-line` — read the list; the loop already restarts when `state.playing` flips, which is the trigger that matters. Note `state.setBumperPreview` calls `seek` internally (Task 8), so `state.seek(frame.mainMs)` is only needed on the main branch.

- [ ] **Step 5: Codec gate**

```ts
  const needsAudioForExport =
    audioClips.length > 0 ||
    (["start", "end"] as const).some((s) => {
      const b = state.timeline.bumpers?.[s];
      return b?.kind === "video" && !b.mute;
    });
```

- [ ] **Step 6: Manual verification checklist** (dev server via `preview_start`, a branded KV with a motion project; record results in the commit message)

1. `Bumpers` button visible in the transport; opens two empty cards. Library empty-state text shows.
2. Upload a PNG → appears in library and fills the slot in one go; toast on a `.gif` reads "Use a PNG, JPG, WebP, MP4 or WebM file."
3. Upload a short MP4 with sound → duration shows its natural length; `Mute` toggle present.
4. Start zone appears left of the lane, labelled `Start bumper · 2.0s`; the lane and every keyframe bar shifted right by exactly the zone; the ruler's `0s` sits at the lane start.
5. Click inside the zone → stage shows the lockup on the chosen background; transformer hidden; transport reads e.g. `00:00.80 / 00:07.00`.
6. Press play from the zone → bumper plays through, cuts to the main at `0`, main audio starts at the cut, end bumper plays, loops.
7. Undo (`⌘Z`) after adding a bumper removes it; autosave indicator cycles.
8. Export 1:1 → MP4 length = total; first frames are the bumper; main is unchanged frame-for-frame against a pre-bumper export at the same playhead; end bumper audio audible when unmuted, silent when muted.
9. Remove both → dock is pixel-identical to before; `bumpers` key absent in the PATCH payload (Network tab).
10. Delete the bumper from the library while a project uses it → slot shows "(deleted from library)", export still works.

- [ ] **Step 7: Type-error baseline, build, full motion test run**

```bash
bunx tsc --noEmit -p . 2>&1 | grep -c "error TS"     # compare with the develop baseline
node node_modules/next/dist/bin/next build
bun test src/lib/video-editor src/components/video-editor src/components/studio/kv-generator/motion/exportMotion.bumpers.test.ts src/components/studio/kv-generator/motion/useMotionEditorState.bumpers.test.ts src/components/studio/kv-generator/motion/Bumper*.test.tsx src/components/studio/kv-generator/motion/KvMotionExportDialog.bumpers.test.tsx
```

(Do not run `bun test` on the whole `motion/` directory at once — memory `lesson_bun_test_motion_dir_memory_blowup`.)

- [ ] **Step 8: Commit**

```bash
git add src/components/studio/kv-generator/motion/KvMotionEditor.tsx
git commit -m "feat(web): wire bumper slots into the motion editor

Library query + upload/delete, slot set/update/remove with PostHog events,
bumper preview on the stage, total-clock playback loop, AAC gate for unmuted
video bumpers.

Manual checklist (spec §3.6–3.7): <fill in pass/fail per item>

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Self-review

- **Spec coverage:** §3.2 types (T1), §3.3 resolver incl. clamp-once and `playheadAxisPx`/`totalClockMs` (T1), §3.4 export gate/router/paint/dispose (T6), §3.4a `openBumperVideo` (T5), §3.5 derived audio, one download per bumper, decode from the same blob (T2, T5, T7), §3.6 `bumperPreview`, parked playhead, seek clears, loop routing, stage overlay swallowing pointer events (T8, T9, T12), §3.7 Transport button, two cards, picker, empty state, filled-card controls, deleted-from-library hint, zones via lane offset, playhead px, readout, tooltip, undo/autosave for free (T10, T11, T12), §3.8 four events + `has_bumpers`/`bumper_kinds` (T4, T7, T12), §3.9 client mime/size rejection + metadata errors (T3), asset 404/undecodable → `MotionAssetError` with slot name (T6), no-audio-track → no clip (T7), stale duration clamp (T1), soft-deleted row keeps url (T1 `bumperFromLibrary` copies url; T11 hint), §3.10 test placement and lessons (Global Constraints).
- **Placeholders:** the T6 "disposes even when encoding throws" case is explicitly flagged for the implementer to finish with a rejecting encoder — kept as a named requirement rather than a vague "handle errors". T7/T10/T11 tests reference harness helpers that exist in sibling test files by name (`renderDialog`, `renderDock`) — the implementer copies them; no invented APIs.
- **Type consistency:** `MotionBumper.natural_ms` used in T1, T2, T6 tests, T8, T11; `BumperSlot` from `bumpers.ts` everywhere; `bumperFromLibrary` takes the api row shape `{ id, kind, url, duration_ms, width, height }` and T12 maps `KvMotionBumperRow` (camelCase) into it explicitly; `openBumperVideo` returns `{ durationMs, width, height, hasAudio, blob, frameAt, dispose }` in T5, T6, T7; `ExportMotionRatioDeps.openBumperVideo` name matches the T6 harness; `Transport` props `elapsedMs`/`totalMs`/`bumpersControl` match T10's dock wiring; `BumperDock.control` → `bumpersControl`.
