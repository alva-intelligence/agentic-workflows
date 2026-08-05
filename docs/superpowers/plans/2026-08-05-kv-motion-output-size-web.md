# KV Motion — Output Size at the Entry Point — Implementation Plan (web)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user choose the motion project's output size from the same platform presets Resize uses, lock the project to it, and export an MP4 at exactly that size.

**Architecture:** Four pure helpers (`videoSafeDims`, `buildMotionSizeOptions`, `buildMotionSnapshot`, `resolveMotionTarget`) carry all the logic and all the tests. A new `KvMotionSizePicker` modal consumes them; `KvMotionProjectsPanel` opens it instead of creating immediately. The editor and export dialog then read the project's locked size instead of offering ratio choices. The render/encode pipeline is untouched — `exportMotionRatio` already accepts an arbitrary `{ id, w, h }`.

**Tech Stack:** Next.js 16 / React 19 / TypeScript, TanStack Query v5, Konva (offscreen stage for previews), Mediabunny/WebCodecs (existing encode path), `bun test` + `@testing-library/react` in jsdom.

**Spec:** `docs/superpowers/specs/2026-08-05-kv-motion-output-size-design.md`

## Global Constraints

- **Web only.** Do not touch `api/`. `snapshot` is opaque JSON there — verified: `StoreKvMotionProjectRequest` validates it as `['required','array', new MaxJsonBytes]` with no nested key rules, and `KvMotionProjectController::store` writes `$v['snapshot']` wholesale.
- **Test runner is `bun test`, never `bunx vitest`.** `bunfig.toml` preloads jest-dom.
- **`screen` is broken under bun's jsdom preload.** Always query via `within(document.body)`. Using `screen` causes every component test in the repo to fail, not just yours.
- **jsdom has no canvas 2D context.** No test may render a Konva stage or read pixels. Preview rendering is behind a DI seam and is exercised only with a stub.
- **Encoder ceiling:** longest edge ≤ `1920`, both axes even, minimum edge `16`. Values verbatim from spec §6.
- **Never `git stash`** to compare lint baselines. Use `git show HEAD:<path> > <path>.baseline.tsx` inside the repo, lint it, then delete.
- Commit after every task. Conventional commits, scope `web`.

## File Structure

| File | Responsibility |
|---|---|
| `src/lib/motion/videoSafeDims.ts` **(new)** | Clamp preset dims to something AVC can encode. Pure. |
| `src/lib/motion/motionSizeOptions.ts` **(new)** | Build the picker's grouped option list from `PLATFORMS` + the file's resize exports. Pure. |
| `src/lib/motion/motionSnapshot.ts` **(new)** | Build a `KvMotionSnapshot` from a chosen option; resolve a snapshot's locked target (incl. pre-spec inference). Pure. |
| `src/types/kv/motionProject.ts` | Add the optional `target` field to `KvMotionSnapshot`. |
| `src/components/studio/kv-generator/motion/KvMotionSizePicker.tsx` **(new)** | The modal: grouped list + one accurate preview pane. |
| `src/components/studio/kv-generator/motion/KvMotionProjectsPanel.tsx` | `New motion` opens the picker; create uses the chosen option. |
| `src/components/studio/kv-generator/motion/KvMotionEditor.tsx` | Drop ratio chips; preview locks to the project's size; canvas always editable. |
| `src/components/studio/kv-generator/motion/KvMotionExportDialog.tsx` | Checkbox list → one locked-size row. |
| `src/components/studio/kv-generator/KvGeneratorLayout.tsx` | Pass `exportsByPlatformId` down to the panel. |
| `src/lib/analytics/kv-generator-events.ts` | `KvMotionProjectCreatedProps` gains `platform_id` + `base_source`. |

---

### Task 1: `videoSafeDims`

**Files:**
- Create: `src/lib/motion/videoSafeDims.ts`
- Test: `src/lib/motion/videoSafeDims.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces: `videoSafeDims(w: number, h: number): { w: number; h: number }`, `MAX_VIDEO_EDGE: 1920`, `MIN_VIDEO_EDGE: 16`.

- [ ] **Step 1: Write the failing test**

```ts
// src/lib/motion/videoSafeDims.test.ts
import { describe, it, expect } from "bun:test";

import { videoSafeDims } from "./videoSafeDims";

describe("videoSafeDims", () => {
  it("leaves an already-safe preset untouched", () => {
    expect(videoSafeDims(1080, 566)).toEqual({ w: 1080, h: 566 });
    expect(videoSafeDims(1080, 1920)).toEqual({ w: 1080, h: 1920 });
    expect(videoSafeDims(1920, 1080)).toEqual({ w: 1920, h: 1080 });
  });

  it("floors an odd axis to even (H.264 4:2:0 needs both axes even)", () => {
    // The three real offenders in PLATFORMS.
    expect(videoSafeDims(1200, 627)).toEqual({ w: 1200, h: 626 }); // linkedin-post
    expect(videoSafeDims(1200, 675)).toEqual({ w: 1200, h: 674 }); // twitter-post
    expect(videoSafeDims(1250, 463)).toEqual({ w: 1250, h: 462 }); // facebook-video-cover
  });

  it("scales oversized presets down so the longest edge is 1920", () => {
    expect(videoSafeDims(2560, 1440)).toEqual({ w: 1920, h: 1080 }); // youtube-channel-banner
    expect(videoSafeDims(1600, 2400)).toEqual({ w: 1280, h: 1920 }); // ebook-cover
    expect(videoSafeDims(1280, 3840)).toEqual({ w: 640, h: 1920 });  // custom-tall
  });

  it("always returns even axes", () => {
    for (const [w, h] of [[1200, 627], [2560, 1440], [1250, 463], [999, 333]]) {
      const out = videoSafeDims(w, h);
      expect(out.w % 2).toBe(0);
      expect(out.h % 2).toBe(0);
    }
  });

  it("preserves aspect within 1%", () => {
    for (const [w, h] of [[1200, 627], [2560, 1440], [1280, 3840], [1250, 463]]) {
      const out = videoSafeDims(w, h);
      const drift = Math.abs(out.w / out.h - w / h) / (w / h);
      expect(drift).toBeLessThan(0.01);
    }
  });

  it("clamps a degenerate size to the 16px floor", () => {
    expect(videoSafeDims(4, 4)).toEqual({ w: 16, h: 16 });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/lib/motion/videoSafeDims.test.ts`
Expected: FAIL — `Cannot find module './videoSafeDims'`

- [ ] **Step 3: Write minimal implementation**

```ts
// src/lib/motion/videoSafeDims.ts

/** Longest edge an in-browser AVC encode should attempt. The preset table in
 *  `@/types/kv/resize` was written for STILL-IMAGE resize output and contains
 *  sizes well past what WebCodecs should be asked for in a tab
 *  (`youtube-channel-banner` 2560×1440, `custom-tall` 1280×3840). */
export const MAX_VIDEO_EDGE = 1920;

/** Floor for either axis after scaling — guards against a degenerate preset
 *  producing a 0- or 2-pixel canvas. Not reachable with today's table (the
 *  smallest edge is 360); present so a future preset can't break the encoder. */
export const MIN_VIDEO_EDGE = 16;

/**
 * Clamp a preset's declared dimensions to something an H.264 (AVC) encode can
 * actually produce:
 *
 *   1. Scale down proportionally so the longest edge is ≤ {@link MAX_VIDEO_EDGE}.
 *   2. Floor BOTH axes to even — 4:2:0 chroma subsampling requires it, and
 *      three presets in the table ship odd heights (1200×627, 1200×675,
 *      1250×463).
 *
 * Flooring (never ceiling) guarantees the result stays under the level cap.
 * Aspect drift from the even-floor is ≤ 0.16% on the current table.
 *
 * `encodeTimelineToMp4` hands canvas dimensions straight to mediabunny's
 * `CanvasSource` with no guard of its own — this is the only thing standing
 * between a preset and a failed encode.
 */
export function videoSafeDims(w: number, h: number): { w: number; h: number } {
  const rawW = Math.max(1, Math.round(w));
  const rawH = Math.max(1, Math.round(h));
  const longest = Math.max(rawW, rawH);
  const scale = longest > MAX_VIDEO_EDGE ? MAX_VIDEO_EDGE / longest : 1;
  const clamp = (n: number) =>
    Math.max(MIN_VIDEO_EDGE, Math.floor((n * scale) / 2) * 2);
  return { w: clamp(rawW), h: clamp(rawH) };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/lib/motion/videoSafeDims.test.ts`
Expected: PASS — 6 tests

- [ ] **Step 5: Commit**

```bash
git add web/src/lib/motion/videoSafeDims.ts web/src/lib/motion/videoSafeDims.test.ts
git commit -m "feat(web): add videoSafeDims — clamp resize presets to encodable video dims"
```

---

### Task 2: `KvMotionSnapshot.target` + `resolveMotionTarget`

**Files:**
- Modify: `src/types/kv/motionProject.ts:10-15`
- Create: `src/lib/motion/motionSnapshot.ts`
- Test: `src/lib/motion/motionSnapshot.test.ts`

**Interfaces:**
- Consumes: `videoSafeDims` (Task 1); existing `closestMotionRatio` from `@/components/studio/kv-generator/motion/exportMotion`.
- Produces:
  - `type KvMotionTarget = { platform_id: PlatformId | "native"; label: string; source: "resize" | "master" | "native" }`
  - `type ResolvedMotionTarget = { id: string; label: string; w: number; h: number }`
  - `resolveMotionTarget(snapshot: KvMotionSnapshot): ResolvedMotionTarget`

- [ ] **Step 1: Write the failing test**

```ts
// src/lib/motion/motionSnapshot.test.ts
import { describe, it, expect } from "bun:test";

import type { KvMotionSnapshot } from "@/types/kv/motionProject";

import { resolveMotionTarget } from "./motionSnapshot";

function snap(over: Partial<KvMotionSnapshot> = {}): KvMotionSnapshot {
  return {
    base_image_url: "https://x/base.png",
    board_width: 1080,
    board_height: 566,
    overlays: [],
    ...over,
  };
}

describe("resolveMotionTarget", () => {
  it("uses the locked target when the snapshot has one", () => {
    const out = resolveMotionTarget(
      snap({
        target: {
          platform_id: "instagram-landscape",
          label: "Instagram Landscape",
          source: "resize",
        },
      }),
    );
    expect(out).toEqual({
      id: "instagram-landscape",
      label: "Instagram Landscape",
      w: 1080,
      h: 566,
    });
  });

  it("infers the closest fixed ratio for a pre-spec snapshot (no target)", () => {
    // 576×1024 is the old ARTBOARD_RATIO_BOARD_DIMS 9:16 entry.
    const out = resolveMotionTarget(snap({ board_width: 576, board_height: 1024 }));
    expect(out).toEqual({ id: "9:16", label: "9:16", w: 1080, h: 1920 });
  });

  it("infers 16:9 for a pre-spec landscape snapshot", () => {
    const out = resolveMotionTarget(snap({ board_width: 1024, board_height: 576 }));
    expect(out).toEqual({ id: "16:9", label: "16:9", w: 1920, h: 1080 });
  });

  it("infers 1:1 for a pre-spec square snapshot", () => {
    const out = resolveMotionTarget(snap({ board_width: 1024, board_height: 1024 }));
    expect(out).toEqual({ id: "1:1", label: "1:1", w: 1080, h: 1080 });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/lib/motion/motionSnapshot.test.ts`
Expected: FAIL — `Cannot find module './motionSnapshot'`

- [ ] **Step 3a: Add `target` to the snapshot type**

Replace `src/types/kv/motionProject.ts` lines 9-15 with:

```ts
/** Which output size a motion project is locked to. Absent on projects
 *  created before the size picker shipped — `resolveMotionTarget` infers
 *  those from the snapshot's own aspect. */
export type KvMotionTarget = {
  /** A Resize preset id, or `"native"` for the board's own ratio. */
  platform_id: PlatformId | "native";
  /** Human label, frozen at creation so the UI never re-derives it. */
  label: string;
  /** Which constructor built `base_image_url`. */
  source: "resize" | "master" | "native";
};

/** Frozen board state a motion project animates on top of. `board_width` /
 *  `board_height` are the project's REAL output pixels (encoder-safe — see
 *  `videoSafeDims`), not a ratio lookup. */
export type KvMotionSnapshot = {
  base_image_url: string;
  board_width: number;
  board_height: number;
  overlays: StudioOverlay[];
  target?: KvMotionTarget;
};
```

Add to the imports at the top of that file:

```ts
import type { PlatformId } from "@/types/kv/resize";
```

- [ ] **Step 3b: Write the resolver**

```ts
// src/lib/motion/motionSnapshot.ts
import { closestMotionRatio } from "@/components/studio/kv-generator/motion/exportMotion";
import type { KvMotionSnapshot } from "@/types/kv/motionProject";

/** The size a motion project actually renders and exports at. */
export type ResolvedMotionTarget = {
  id: string;
  label: string;
  w: number;
  h: number;
};

/**
 * Read a project's locked output size.
 *
 * Projects created by the size picker carry `snapshot.target` and their
 * `board_width`/`board_height` ARE the output pixels — return them directly.
 *
 * Projects created before the picker have no `target` and their dims came
 * from the old 1024-max ratio table, which are NOT output pixels. Infer via
 * `closestMotionRatio` — the same helper the editor and export dialog already
 * used to default-select a ratio for those projects, so the inferred size is
 * exactly what they would have exported anyway. One code path, no migration.
 */
export function resolveMotionTarget(
  snapshot: KvMotionSnapshot,
): ResolvedMotionTarget {
  if (snapshot.target) {
    return {
      id: snapshot.target.platform_id,
      label: snapshot.target.label,
      w: snapshot.board_width,
      h: snapshot.board_height,
    };
  }
  const ratio = closestMotionRatio(snapshot.board_width, snapshot.board_height);
  return { id: ratio.id, label: ratio.id, w: ratio.w, h: ratio.h };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/lib/motion/motionSnapshot.test.ts`
Expected: PASS — 4 tests

- [ ] **Step 5: Commit**

```bash
git add web/src/types/kv/motionProject.ts web/src/lib/motion/motionSnapshot.ts web/src/lib/motion/motionSnapshot.test.ts
git commit -m "feat(web): add KvMotionSnapshot.target and resolveMotionTarget"
```

---

### Task 3: `buildMotionSizeOptions`

**Files:**
- Create: `src/lib/motion/motionSizeOptions.ts`
- Test: `src/lib/motion/motionSizeOptions.test.ts`

**Interfaces:**
- Consumes: `videoSafeDims` (Task 1); `PLATFORMS`, `platformsByGroup`, `GROUP_LABEL` from `@/lib/studio/kv/resizePlatforms` and `@/types/kv/resize`.
- Produces:

```ts
export type MotionSizeOption = {
  key: string;                                  // platform id, or "native"
  platformId: PlatformId | "native";
  label: string;
  declared: { w: number; h: number };           // what the preset says
  video: { w: number; h: number };              // encoder-safe, what we render
  adjusted: boolean;                            // video !== declared
  source: "resize" | "master" | "native";
  baseImageUrl: string;
  resizeOverlays: StudioOverlay[] | null;       // tile override, if any
};
export type MotionSizeGroup = { id: string; heading: string; options: MotionSizeOption[] };
export function buildMotionSizeOptions(args: {
  nativeImageUrl: string;
  nativeWidth: number;
  nativeHeight: number;
  exportsByPlatformId: Map<PlatformId, KvResizeExport>;
}): MotionSizeGroup[];
```

- [ ] **Step 1: Write the failing test**

```ts
// src/lib/motion/motionSizeOptions.test.ts
import { describe, it, expect } from "bun:test";

import type { KvResizeExport, PlatformId } from "@/types/kv/resize";

import { buildMotionSizeOptions } from "./motionSizeOptions";

function exportRow(over: Partial<KvResizeExport>): KvResizeExport {
  return {
    id: "e1",
    studioFileId: "f1",
    parentGenerationId: "g1",
    platformId: "instagram-landscape",
    platformLabel: "Instagram Landscape",
    platformGroup: "social-media",
    width: 1080,
    height: 566,
    imageUrl: "https://x/tile.png",
    status: "done",
    cropWindow: null,
    overlays: null,
    errorMessage: null,
    createdAt: "2026-08-05T00:00:00Z",
    updatedAt: "2026-08-05T00:00:00Z",
    ...over,
  };
}

const base = {
  nativeImageUrl: "https://x/board.png",
  nativeWidth: 576,
  nativeHeight: 1024,
};

describe("buildMotionSizeOptions", () => {
  it("pins native as the first option of the first group", () => {
    const groups = buildMotionSizeOptions({ ...base, exportsByPlatformId: new Map() });
    expect(groups[0].id).toBe("native");
    expect(groups[0].options).toHaveLength(1);
    expect(groups[0].options[0]).toMatchObject({
      key: "native",
      platformId: "native",
      source: "native",
      baseImageUrl: "https://x/board.png",
      declared: { w: 576, h: 1024 },
      video: { w: 576, h: 1024 },
      adjusted: false,
    });
  });

  it("omits the resized group entirely when there are no resize results", () => {
    const groups = buildMotionSizeOptions({ ...base, exportsByPlatformId: new Map() });
    expect(groups.some((g) => g.id === "resized")).toBe(false);
  });

  it("puts a done resize result in the resized group and out of the others", () => {
    const groups = buildMotionSizeOptions({
      ...base,
      exportsByPlatformId: new Map<PlatformId, KvResizeExport>([
        ["instagram-landscape", exportRow({})],
      ]),
    });
    const resized = groups.find((g) => g.id === "resized");
    expect(resized?.options.map((o) => o.key)).toEqual(["instagram-landscape"]);
    expect(resized?.options[0]).toMatchObject({
      source: "resize",
      baseImageUrl: "https://x/tile.png",
    });
    const elsewhere = groups
      .filter((g) => g.id !== "resized")
      .flatMap((g) => g.options.map((o) => o.key));
    expect(elsewhere).not.toContain("instagram-landscape");
  });

  it("ignores resize rows that are not done or have no image", () => {
    const groups = buildMotionSizeOptions({
      ...base,
      exportsByPlatformId: new Map<PlatformId, KvResizeExport>([
        ["instagram-post", exportRow({ platformId: "instagram-post", status: "generating" })],
        ["tiktok-video", exportRow({ platformId: "tiktok-video", imageUrl: null })],
      ]),
    });
    expect(groups.some((g) => g.id === "resized")).toBe(false);
  });

  it("carries a resize row's per-tile overlay override through", () => {
    const overlays = [{ id: "o1" }] as unknown as KvResizeExport["overlays"];
    const groups = buildMotionSizeOptions({
      ...base,
      exportsByPlatformId: new Map<PlatformId, KvResizeExport>([
        ["instagram-landscape", exportRow({ overlays })],
      ]),
    });
    const opt = groups.find((g) => g.id === "resized")!.options[0];
    expect(opt.resizeOverlays).toBe(overlays);
  });

  it("marks presets whose dims the encoder rule changed", () => {
    const groups = buildMotionSizeOptions({ ...base, exportsByPlatformId: new Map() });
    const all = groups.flatMap((g) => g.options);
    const linkedin = all.find((o) => o.key === "linkedin-post")!;
    expect(linkedin.declared).toEqual({ w: 1200, h: 627 });
    expect(linkedin.video).toEqual({ w: 1200, h: 626 });
    expect(linkedin.adjusted).toBe(true);

    const igPost = all.find((o) => o.key === "instagram-post")!;
    expect(igPost.video).toEqual({ w: 1080, h: 1080 });
    expect(igPost.adjusted).toBe(false);
  });

  it("groups the remaining presets under the Resize group headings", () => {
    const groups = buildMotionSizeOptions({ ...base, exportsByPlatformId: new Map() });
    expect(groups.map((g) => g.id)).toEqual([
      "native",
      "social-media",
      "print",
      "digital",
    ]);
    expect(groups.map((g) => g.heading)).toEqual([
      "Same as board",
      "Social Media",
      "Print",
      "Digital",
    ]);
  });

  it("every non-native option carries the master board as its base image", () => {
    const groups = buildMotionSizeOptions({ ...base, exportsByPlatformId: new Map() });
    const masters = groups
      .filter((g) => g.id !== "native")
      .flatMap((g) => g.options);
    expect(masters.length).toBeGreaterThan(0);
    expect(masters.every((o) => o.baseImageUrl === "https://x/board.png")).toBe(true);
    expect(masters.every((o) => o.source === "master")).toBe(true);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/lib/motion/motionSizeOptions.test.ts`
Expected: FAIL — `Cannot find module './motionSizeOptions'`

- [ ] **Step 3: Write minimal implementation**

```ts
// src/lib/motion/motionSizeOptions.ts
import { GROUP_LABEL, platformsByGroup } from "@/lib/studio/kv/resizePlatforms";
import type {
  KvResizeExport,
  Platform,
  PlatformGroup,
  PlatformId,
} from "@/types/kv/resize";
import type { StudioOverlay } from "@/types/studio";

import { videoSafeDims } from "./videoSafeDims";

/** One selectable output size in the Motion size picker. */
export type MotionSizeOption = {
  /** Stable react key + selection id. A `PlatformId`, or `"native"`. */
  key: string;
  platformId: PlatformId | "native";
  label: string;
  /** What the preset table declares — shown to the user for recognition. */
  declared: { w: number; h: number };
  /** What we actually render and encode at (see `videoSafeDims`). */
  video: { w: number; h: number };
  /** `video` differs from `declared`; the row says so. */
  adjusted: boolean;
  source: "resize" | "master" | "native";
  /** Image the animation is built on: a resize tile, or the master board. */
  baseImageUrl: string;
  /** A resize tile's per-tile overlay override, when it has one. Passed
   *  straight to `resolveTileOverlays` as its tile-snapshot argument. */
  resizeOverlays: StudioOverlay[] | null;
};

export type MotionSizeGroup = {
  id: "native" | "resized" | PlatformGroup;
  heading: string;
  options: MotionSizeOption[];
};

/** Order the picker renders group sections in, after native and resized. */
const GROUP_ORDER: PlatformGroup[] = ["social-media", "print", "digital"];

function toOption(
  platform: Platform,
  source: "resize" | "master",
  baseImageUrl: string,
  resizeOverlays: StudioOverlay[] | null,
): MotionSizeOption {
  const video = videoSafeDims(platform.width, platform.height);
  return {
    key: platform.id,
    platformId: platform.id,
    label: platform.label,
    declared: { w: platform.width, h: platform.height },
    video,
    adjusted: video.w !== platform.width || video.h !== platform.height,
    source,
    baseImageUrl,
    resizeOverlays,
  };
}

/**
 * Build the Motion size picker's grouped option list.
 *
 * Three tiers, in render order:
 *   1. `native` — the board's own ratio, today's behaviour, always offered.
 *   2. `resized` — presets with a FINISHED resize result in this file. These
 *      animate the actual tile image, so the video matches what the user sees
 *      on the Resize surface. A row that is still generating, failed, or has
 *      no image yet does NOT qualify — there is no image to animate.
 *   3. the remaining presets, under the same group headings Resize uses,
 *      animating the master board re-projected onto the target size.
 *
 * A preset appears exactly once: promoted into `resized` or left in its group,
 * never both.
 */
export function buildMotionSizeOptions(args: {
  nativeImageUrl: string;
  nativeWidth: number;
  nativeHeight: number;
  exportsByPlatformId: Map<PlatformId, KvResizeExport>;
}): MotionSizeGroup[] {
  const { nativeImageUrl, nativeWidth, nativeHeight, exportsByPlatformId } = args;

  const groups: MotionSizeGroup[] = [
    {
      id: "native",
      heading: "Same as board",
      options: [
        {
          key: "native",
          platformId: "native",
          label: "Same as board",
          declared: { w: nativeWidth, h: nativeHeight },
          video: { w: nativeWidth, h: nativeHeight },
          adjusted: false,
          source: "native",
          baseImageUrl: nativeImageUrl,
          resizeOverlays: null,
        },
      ],
    },
  ];

  const byGroup = platformsByGroup();
  const resizedIds = new Set<PlatformId>();
  const resized: MotionSizeOption[] = [];

  for (const groupId of GROUP_ORDER) {
    for (const platform of byGroup[groupId]) {
      const row = exportsByPlatformId.get(platform.id);
      if (row && row.status === "done" && row.imageUrl) {
        resizedIds.add(platform.id);
        resized.push(toOption(platform, "resize", row.imageUrl, row.overlays));
      }
    }
  }

  if (resized.length > 0) {
    groups.push({ id: "resized", heading: "From your resizes", options: resized });
  }

  for (const groupId of GROUP_ORDER) {
    const options = byGroup[groupId]
      .filter((p) => !resizedIds.has(p.id))
      .map((p) => toOption(p, "master", nativeImageUrl, null));
    if (options.length > 0) {
      groups.push({ id: groupId, heading: GROUP_LABEL[groupId], options });
    }
  }

  return groups;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/lib/motion/motionSizeOptions.test.ts`
Expected: PASS — 8 tests

- [ ] **Step 5: Commit**

```bash
git add web/src/lib/motion/motionSizeOptions.ts web/src/lib/motion/motionSizeOptions.test.ts
git commit -m "feat(web): build the Motion size-picker option list from Resize presets"
```

---

### Task 4: `buildMotionSnapshot`

**Files:**
- Modify: `src/lib/motion/motionSnapshot.ts` (add to the file from Task 2)
- Test: `src/lib/motion/motionSnapshot.test.ts` (add to the file from Task 2)

**Interfaces:**
- Consumes: `MotionSizeOption` (Task 3); `resolveTileOverlays` from `@/lib/studio/kv/overlayAspect`.
- Produces: `buildMotionSnapshot(args): KvMotionSnapshot`.

**Note for the implementer:** the resize path and the master path differ in exactly ONE field — `base_image_url`. Both resolve overlays through the same `resolveTileOverlays(tileSnapshot, boardOverlays, srcW, srcH, tgtW, tgtH)` call that `KvResizeCanvas` uses; `remapSnapshotForRatio` in `exportMotion.ts` is that same call with a `null` first argument. Do not write two branches for overlay resolution.

- [ ] **Step 1: Write the failing test**

Append to `src/lib/motion/motionSnapshot.test.ts`:

```ts
import { resolveTileOverlays } from "@/lib/studio/kv/overlayAspect";
import type { StudioOverlay } from "@/types/studio";
import type { MotionSizeOption } from "./motionSizeOptions";
import { buildMotionSnapshot } from "./motionSnapshot";

const boardOverlay = {
  id: "o1",
  type: "image",
  x: 0.1,
  y: 0.1,
  width: 0.5,
  height: 0.25,
  rotation: 0,
  z: 0,
  payload: { type: "image", url: "https://x/logo.png" },
} as unknown as StudioOverlay;

const nativeArgs = {
  nativeImageUrl: "https://x/board.png",
  nativeWidth: 576,
  nativeHeight: 1024,
  nativeOverlays: [boardOverlay],
};

function option(over: Partial<MotionSizeOption>): MotionSizeOption {
  return {
    key: "instagram-landscape",
    platformId: "instagram-landscape",
    label: "Instagram Landscape",
    declared: { w: 1080, h: 566 },
    video: { w: 1080, h: 566 },
    adjusted: false,
    source: "master",
    baseImageUrl: "https://x/board.png",
    resizeOverlays: null,
    ...over,
  };
}

describe("buildMotionSnapshot", () => {
  it("native keeps the board image, dims and overlays untouched", () => {
    const out = buildMotionSnapshot({
      ...nativeArgs,
      option: option({
        key: "native",
        platformId: "native",
        label: "Same as board",
        declared: { w: 576, h: 1024 },
        video: { w: 576, h: 1024 },
        source: "native",
      }),
    });
    expect(out.base_image_url).toBe("https://x/board.png");
    expect(out.board_width).toBe(576);
    expect(out.board_height).toBe(1024);
    expect(out.overlays).toEqual([boardOverlay]);
    expect(out.target).toEqual({
      platform_id: "native",
      label: "Same as board",
      source: "native",
    });
  });

  it("master path uses the board image at the target's video dims", () => {
    const out = buildMotionSnapshot({ ...nativeArgs, option: option({}) });
    expect(out.base_image_url).toBe("https://x/board.png");
    expect(out.board_width).toBe(1080);
    expect(out.board_height).toBe(566);
    expect(out.target).toEqual({
      platform_id: "instagram-landscape",
      label: "Instagram Landscape",
      source: "master",
    });
  });

  it("master path projects overlays exactly as resolveTileOverlays does", () => {
    const out = buildMotionSnapshot({ ...nativeArgs, option: option({}) });
    expect(out.overlays).toEqual(
      resolveTileOverlays(null, [boardOverlay], 576, 1024, 1080, 566),
    );
  });

  it("resize path swaps the base image and honours the tile override", () => {
    const tileOverride = [{ ...boardOverlay, x: 0.4 }] as StudioOverlay[];
    const out = buildMotionSnapshot({
      ...nativeArgs,
      option: option({
        source: "resize",
        baseImageUrl: "https://x/tile.png",
        resizeOverlays: tileOverride,
      }),
    });
    expect(out.base_image_url).toBe("https://x/tile.png");
    expect(out.overlays).toEqual(
      resolveTileOverlays(tileOverride, [boardOverlay], 576, 1024, 1080, 566),
    );
    expect(out.target?.source).toBe("resize");
  });

  it("uses the encoder-safe dims, not the declared ones", () => {
    const out = buildMotionSnapshot({
      ...nativeArgs,
      option: option({
        key: "linkedin-post",
        platformId: "linkedin-post",
        label: "LinkedIn Post",
        declared: { w: 1200, h: 627 },
        video: { w: 1200, h: 626 },
        adjusted: true,
      }),
    });
    expect(out.board_width).toBe(1200);
    expect(out.board_height).toBe(626);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/lib/motion/motionSnapshot.test.ts`
Expected: FAIL — `buildMotionSnapshot is not a function`

- [ ] **Step 3: Write minimal implementation**

Append to `src/lib/motion/motionSnapshot.ts` (and add the two imports at the top):

```ts
import { resolveTileOverlays } from "@/lib/studio/kv/overlayAspect";
import type { StudioOverlay } from "@/types/studio";

import type { MotionSizeOption } from "./motionSizeOptions";
```

```ts
/**
 * Build the frozen snapshot a new motion project animates.
 *
 * The `native` option is a pass-through: the board's own image, dims and
 * overlays, exactly as `KvMotionProjectsPanel` froze them before this picker
 * existed.
 *
 * Every other option resolves overlays through ONE call — the same
 * `resolveTileOverlays` the Resize surface uses for its tiles, and the same
 * one `remapSnapshotForRatio` wraps. That call already handles
 * anchor-preserving projection, cluster grouping, coverage capping, canvas
 * clamping, AND the text-styling correction that keeps a text overlay's
 * rendered pixel font size tracking its projected box.
 *
 * The `resize` and `master` paths therefore differ in exactly one field:
 * which image the animation sits on. `resize` passes the tile's per-tile
 * overlay override as the tile snapshot; `master` passes `null`, meaning "no
 * override, project the board's overlays".
 */
export function buildMotionSnapshot(args: {
  option: MotionSizeOption;
  nativeImageUrl: string;
  nativeWidth: number;
  nativeHeight: number;
  nativeOverlays: StudioOverlay[];
}): KvMotionSnapshot {
  const { option, nativeWidth, nativeHeight, nativeOverlays } = args;

  const target = {
    platform_id: option.platformId,
    label: option.label,
    source: option.source,
  } as const;

  if (option.source === "native") {
    return {
      base_image_url: option.baseImageUrl,
      board_width: nativeWidth,
      board_height: nativeHeight,
      overlays: nativeOverlays,
      target,
    };
  }

  return {
    base_image_url: option.baseImageUrl,
    board_width: option.video.w,
    board_height: option.video.h,
    overlays: resolveTileOverlays(
      option.resizeOverlays,
      nativeOverlays,
      nativeWidth,
      nativeHeight,
      option.video.w,
      option.video.h,
    ),
    target,
  };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/lib/motion/motionSnapshot.test.ts`
Expected: PASS — 9 tests (4 from Task 2 + 5 new)

- [ ] **Step 5: Commit**

```bash
git add web/src/lib/motion/motionSnapshot.ts web/src/lib/motion/motionSnapshot.test.ts
git commit -m "feat(web): build a motion snapshot from a chosen output size"
```

---

### Task 5: `KvMotionSizePicker` modal

**Files:**
- Create: `src/components/studio/kv-generator/motion/KvMotionSizePicker.tsx`
- Test: `src/components/studio/kv-generator/motion/KvMotionSizePicker.test.tsx`

**Interfaces:**
- Consumes: `buildMotionSizeOptions`, `MotionSizeOption`, `MotionSizeGroup` (Task 3).
- Produces:

```ts
export type KvMotionSizePickerProps = {
  isOpen: boolean;
  onClose: () => void;
  onConfirm: (option: MotionSizeOption) => void;
  creating: boolean;
  nativeImageUrl: string;
  nativeWidth: number;
  nativeHeight: number;
  nativeOverlays: StudioOverlay[];
  exportsByPlatformId: Map<PlatformId, KvResizeExport>;
  /** DI seam — jsdom has no canvas 2D context, so tests stub the renderer. */
  renderPreviewFn?: (option: MotionSizeOption) => Promise<string>;
};
export function KvMotionSizePicker(props: KvMotionSizePickerProps): JSX.Element;
```

**Note for the implementer:** `renderPreviewFn` returns a data/object URL for the composited preview. The real implementation uses `renderHiddenStage` from `@/components/studio/kv-generator/renderBoardStage` (which builds an offscreen Konva stage) and `stage.toDataURL()`, then `stage.destroy()`. It MUST NOT run in tests — that is what the seam is for.

- [ ] **Step 1: Write the failing test**

```tsx
// src/components/studio/kv-generator/motion/KvMotionSizePicker.test.tsx
import { describe, it, expect, mock } from "bun:test";
import { fireEvent, render, waitFor, within } from "@testing-library/react";
import type { ReactElement } from "react";

import type { KvResizeExport, PlatformId } from "@/types/kv/resize";
import type { MotionSizeOption } from "@/lib/motion/motionSizeOptions";

import {
  KvMotionSizePicker,
  type KvMotionSizePickerProps,
} from "./KvMotionSizePicker";

// `screen` binds to a stale `document` under bun's jsdom preload — query via
// `within(document.body)` (same convention as KvMotionProjectsPanel.test.tsx).
function doneExport(platformId: PlatformId, label: string): KvResizeExport {
  return {
    id: `e-${platformId}`,
    studioFileId: "f1",
    parentGenerationId: "g1",
    platformId,
    platformLabel: label,
    platformGroup: "social-media",
    width: 1080,
    height: 566,
    imageUrl: "https://x/tile.png",
    status: "done",
    cropWindow: null,
    overlays: null,
    errorMessage: null,
    createdAt: "2026-08-05T00:00:00Z",
    updatedAt: "2026-08-05T00:00:00Z",
  };
}

function renderPicker(
  overrides: Partial<KvMotionSizePickerProps> = {},
): { onConfirm: ReturnType<typeof mock> } {
  const onConfirm = mock((_o: MotionSizeOption) => {});
  const props = {
    isOpen: true,
    onClose: mock(() => {}),
    onConfirm,
    creating: false,
    nativeImageUrl: "https://x/board.png",
    nativeWidth: 576,
    nativeHeight: 1024,
    nativeOverlays: [],
    exportsByPlatformId: new Map<PlatformId, KvResizeExport>(),
    renderPreviewFn: mock(async (_o: MotionSizeOption) => "data:image/png;base64,AA"),
    ...overrides,
  };
  const el: ReactElement = <KvMotionSizePicker {...props} />;
  render(el);
  return { onConfirm };
}

describe("KvMotionSizePicker", () => {
  it("defaults to the native option and names it on the confirm button", () => {
    renderPicker();
    const body = within(document.body);
    expect(body.getByRole("button", { name: /Create motion · 576×1024/ })).toBeTruthy();
  });

  it("confirms with the native option when nothing else is picked", () => {
    const { onConfirm } = renderPicker();
    const body = within(document.body);
    fireEvent.click(body.getByRole("button", { name: /Create motion/ }));
    expect(onConfirm).toHaveBeenCalledTimes(1);
    expect(onConfirm.mock.calls[0][0]).toMatchObject({
      platformId: "native",
      source: "native",
    });
  });

  it("shows a From your resizes section when a resize result exists", () => {
    renderPicker({
      exportsByPlatformId: new Map<PlatformId, KvResizeExport>([
        ["instagram-landscape", doneExport("instagram-landscape", "Instagram Landscape")],
      ]),
    });
    const body = within(document.body);
    expect(body.getByText("From your resizes")).toBeTruthy();
  });

  it("selecting a preset updates the confirm button's size and payload", async () => {
    const { onConfirm } = renderPicker();
    const body = within(document.body);
    fireEvent.click(body.getByRole("radio", { name: /Instagram Post/ }));
    await waitFor(() =>
      expect(body.getByRole("button", { name: /Create motion · 1080×1080/ })).toBeTruthy(),
    );
    fireEvent.click(body.getByRole("button", { name: /Create motion/ }));
    expect(onConfirm.mock.calls[0][0]).toMatchObject({
      platformId: "instagram-post",
      video: { w: 1080, h: 1080 },
      source: "master",
    });
  });

  it("discloses an encoder-adjusted size on the row", () => {
    renderPicker();
    const body = within(document.body);
    expect(body.getByText(/2560 × 1440 · video 1920 × 1080/)).toBeTruthy();
  });

  it("renders each option's preview once and reuses it on reselect", async () => {
    const renderPreviewFn = mock(async (_o: MotionSizeOption) => "data:image/png;base64,AA");
    renderPicker({ renderPreviewFn });
    const body = within(document.body);
    await waitFor(() => expect(renderPreviewFn).toHaveBeenCalledTimes(1)); // native

    fireEvent.click(body.getByRole("radio", { name: /Instagram Post/ }));
    await waitFor(() => expect(renderPreviewFn).toHaveBeenCalledTimes(2));

    fireEvent.click(body.getByRole("radio", { name: /Same as board/ }));
    fireEvent.click(body.getByRole("radio", { name: /Instagram Post/ }));
    // Both are cached — no further renders.
    await waitFor(() => expect(renderPreviewFn).toHaveBeenCalledTimes(2));
  });

  it("blocks confirm and explains when the chosen resize tile fails to preview", async () => {
    const { onConfirm } = renderPicker({
      exportsByPlatformId: new Map<PlatformId, KvResizeExport>([
        ["instagram-landscape", doneExport("instagram-landscape", "Instagram Landscape")],
      ]),
      renderPreviewFn: mock(async (o: MotionSizeOption) => {
        if (o.source === "resize") throw new Error("boom");
        return "data:image/png;base64,AA";
      }),
    });
    const body = within(document.body);
    fireEvent.click(body.getByRole("radio", { name: /Instagram Landscape/ }));
    await waitFor(() =>
      expect(body.getByText(/Couldn't load this resize result/)).toBeTruthy(),
    );
    expect(
      body.getByRole("button", { name: /Create motion/ }).hasAttribute("disabled"),
    ).toBe(true);
    expect(onConfirm).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/motion/KvMotionSizePicker.test.tsx`
Expected: FAIL — `Cannot find module './KvMotionSizePicker'`

- [ ] **Step 3: Write minimal implementation**

```tsx
// src/components/studio/kv-generator/motion/KvMotionSizePicker.tsx
"use client";

import { useEffect, useMemo, useRef, useState } from "react";

import BaseModal from "@/components/frndos/BaseModal";
import { Button } from "@/components/frndos/v2";
import {
  buildMotionSizeOptions,
  type MotionSizeOption,
} from "@/lib/motion/motionSizeOptions";
import { renderHiddenStage } from "@/components/studio/kv-generator/renderBoardStage";
import type { KvResizeExport, PlatformId } from "@/types/kv/resize";
import type { StudioOverlay } from "@/types/studio";

/** Composite one option's base image + overlays to a data URL for the preview
 *  pane. Offscreen Konva stage, destroyed on the way out. Never runs in tests
 *  — jsdom has no canvas 2D context, so callers inject a stub. */
async function renderPreview(
  option: MotionSizeOption,
  overlays: StudioOverlay[],
): Promise<string> {
  const stage = await renderHiddenStage({
    baseImageUrl: option.baseImageUrl,
    overlays,
    targetWidth: option.video.w,
    targetHeight: option.video.h,
  });
  try {
    return stage.toDataURL({ pixelRatio: 1 });
  } finally {
    stage.destroy();
  }
}

export type KvMotionSizePickerProps = {
  isOpen: boolean;
  onClose: () => void;
  onConfirm: (option: MotionSizeOption) => void;
  creating: boolean;
  nativeImageUrl: string;
  nativeWidth: number;
  nativeHeight: number;
  nativeOverlays: StudioOverlay[];
  exportsByPlatformId: Map<PlatformId, KvResizeExport>;
  /** DI seam — tests stub this; production call sites omit it. */
  renderPreviewFn?: (option: MotionSizeOption) => Promise<string>;
};

/**
 * Motion output-size picker. Left: a grouped, scrollable list of sizes with
 * cheap CSS-cropped thumbnails. Right: ONE accurate preview of the highlighted
 * size, composited through the same overlay projection the export uses.
 *
 * The cheap-list / one-accurate-preview split is deliberate: a size list is
 * scanned, not studied. Rendering ~31 composites to support a choice that
 * resolves to one is work discarded, and incurred at dialog-open.
 */
export function KvMotionSizePicker({
  isOpen,
  onClose,
  onConfirm,
  creating,
  nativeImageUrl,
  nativeWidth,
  nativeHeight,
  nativeOverlays,
  exportsByPlatformId,
  renderPreviewFn,
}: KvMotionSizePickerProps) {
  const groups = useMemo(
    () =>
      buildMotionSizeOptions({
        nativeImageUrl,
        nativeWidth,
        nativeHeight,
        exportsByPlatformId,
      }),
    [nativeImageUrl, nativeWidth, nativeHeight, exportsByPlatformId],
  );

  const allOptions = useMemo(() => groups.flatMap((g) => g.options), [groups]);
  const [selectedKey, setSelectedKey] = useState("native");
  const selected =
    allOptions.find((o) => o.key === selectedKey) ?? allOptions[0];

  const [previewUrl, setPreviewUrl] = useState<string | null>(null);
  const [previewError, setPreviewError] = useState(false);
  const [previewing, setPreviewing] = useState(false);

  // One composited render per option, kept for the modal's lifetime — moving
  // back to an already-seen size is instant instead of re-rendering an
  // offscreen Konva stage. Cleared on close so a reopened picker reflects any
  // resize results that landed in between.
  const previewCache = useRef(new Map<string, string>());
  useEffect(() => {
    if (!isOpen) previewCache.current.clear();
  }, [isOpen]);

  // Debounced preview render for the highlighted row only.
  useEffect(() => {
    if (!isOpen || !selected) return;

    const cached = previewCache.current.get(selected.key);
    if (cached) {
      setPreviewUrl(cached);
      setPreviewError(false);
      setPreviewing(false);
      return;
    }

    let cancelled = false;
    const render =
      renderPreviewFn ?? ((o: MotionSizeOption) => renderPreview(o, nativeOverlays));
    const key = selected.key;
    setPreviewError(false);
    setPreviewing(true);
    const timer = setTimeout(() => {
      render(selected)
        .then((url) => {
          previewCache.current.set(key, url);
          if (cancelled) return;
          setPreviewUrl(url);
          setPreviewing(false);
        })
        .catch(() => {
          if (cancelled) return;
          setPreviewUrl(null);
          setPreviewError(true);
          setPreviewing(false);
        });
    }, 150);
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [isOpen, selected, renderPreviewFn, nativeOverlays]);

  // A failed preview blocks creation ONLY for a resize row: that row is badged
  // `Resized` and its thumbnail promises the tile, so quietly falling back to
  // a master re-projection would break the picker's one guarantee. A master
  // row's preview failing is cosmetic — the snapshot is built from data, not
  // from the preview.
  const blocked = previewError && selected?.source === "resize";

  return (
    <BaseModal
      isOpen={isOpen}
      onClose={() => !creating && onClose()}
      title="Choose the video size"
      description="Motion animates the picture shown in the preview."
      preventCloseOnOverlayClick={creating}
      preventCloseOnEscape={creating}
      footer={
        <div className="flex justify-end gap-2 border-t border-white/10 px-6 py-4">
          <Button
            variant="secondary"
            size="medium"
            disabled={creating}
            onClick={onClose}
          >
            Cancel
          </Button>
          <Button
            variant="primary"
            size="medium"
            disabled={creating || blocked || !selected}
            onClick={() => selected && onConfirm(selected)}
          >
            {creating
              ? "Creating…"
              : `Create motion · ${selected?.video.w}×${selected?.video.h}`}
          </Button>
        </div>
      }
    >
      <div className="flex gap-4 px-6 py-4">
        <div
          role="radiogroup"
          aria-label="Video size"
          className="flex max-h-[420px] w-[320px] flex-col gap-3 overflow-y-auto pr-1"
        >
          {groups.map((group) => (
            <div key={group.id} className="flex flex-col gap-1">
              <p className="px-1 font-geist text-textXs uppercase tracking-[0.04em] text-text-inverse-subtlest">
                {group.heading}
              </p>
              {group.options.map((option) => (
                <button
                  key={option.key}
                  type="button"
                  role="radio"
                  aria-checked={option.key === selectedKey}
                  aria-label={option.label}
                  onClick={() => setSelectedKey(option.key)}
                  className={[
                    "flex items-center gap-3 rounded-lg border px-2 py-2 text-left",
                    option.key === selectedKey
                      ? "border-white/20 bg-[rgba(255,255,255,0.08)]"
                      : "border-transparent hover:bg-[rgba(255,255,255,0.04)]",
                  ].join(" ")}
                >
                  <span
                    className="shrink-0 overflow-hidden rounded bg-[rgba(255,255,255,0.06)]"
                    style={{
                      width: 44,
                      height: Math.max(
                        12,
                        Math.round((44 * option.video.h) / option.video.w),
                      ),
                    }}
                  >
                    {/* Cheap crop — no overlay compositing, no canvas. */}
                    {/* eslint-disable-next-line @next/next/no-img-element */}
                    <img
                      src={option.baseImageUrl}
                      alt=""
                      className="h-full w-full object-cover"
                    />
                  </span>
                  <span className="flex min-w-0 flex-col">
                    <span className="truncate font-geist text-textSm text-text-inverse">
                      {option.label}
                      {option.source === "resize" && (
                        <span className="ml-2 rounded-full border border-emerald-400/30 bg-emerald-400/10 px-1.5 py-0.5 font-geist text-textXs text-emerald-300">
                          Resized
                        </span>
                      )}
                    </span>
                    <span className="font-geist text-textXs text-text-inverse-subtlest">
                      {option.adjusted
                        ? `${option.declared.w} × ${option.declared.h} · video ${option.video.w} × ${option.video.h}`
                        : `${option.declared.w} × ${option.declared.h}`}
                    </span>
                  </span>
                </button>
              ))}
            </div>
          ))}
        </div>

        <div className="flex flex-1 items-center justify-center rounded-lg border border-white/5 bg-[rgba(255,255,255,0.02)] p-3">
          {previewError ? (
            <p className="max-w-[220px] text-center font-geist text-textSm text-text-inverse-subtlest">
              Couldn&apos;t load this resize result — try re-running Resize for
              this size.
            </p>
          ) : previewing || !previewUrl ? (
            <div className="h-40 w-40 animate-pulse rounded bg-[rgba(255,255,255,0.06)]" />
          ) : (
            // eslint-disable-next-line @next/next/no-img-element
            <img
              src={previewUrl}
              alt={`${selected?.label} preview`}
              className="max-h-[380px] max-w-full object-contain"
            />
          )}
        </div>
      </div>
    </BaseModal>
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/motion/KvMotionSizePicker.test.tsx`
Expected: PASS — 7 tests

- [ ] **Step 5: Commit**

```bash
git add web/src/components/studio/kv-generator/motion/KvMotionSizePicker.tsx web/src/components/studio/kv-generator/motion/KvMotionSizePicker.test.tsx
git commit -m "feat(web): add the Motion output-size picker modal"
```

---

### Task 6: Wire the picker into `KvMotionProjectsPanel`

**Files:**
- Modify: `src/lib/analytics/kv-generator-events.ts:385-389`
- Modify: `src/components/studio/kv-generator/motion/KvMotionProjectsPanel.tsx:32-37, 111-143, 185-195`
- Modify: `src/components/studio/kv-generator/KvGeneratorLayout.tsx:4223-4228`
- Test: `src/components/studio/kv-generator/motion/KvMotionProjectsPanel.test.tsx`

**Interfaces:**
- Consumes: `KvMotionSizePicker` (Task 5), `buildMotionSnapshot` (Task 4).
- Produces: `KvMotionActiveBoard` unchanged; `KvMotionProjectsPanelProps` gains `exportsByPlatformId: Map<PlatformId, KvResizeExport>`.

- [ ] **Step 1: Write the failing test**

Append to `src/components/studio/kv-generator/motion/KvMotionProjectsPanel.test.tsx`:

```tsx
describe("size picker", () => {
  it("New motion opens the picker instead of creating immediately", async () => {
    const { props } = renderPanel();
    const body = within(document.body);
    fireEvent.click(body.getByRole("button", { name: /New motion/ }));
    await waitFor(() => expect(body.getByText("Choose the video size")).toBeTruthy());
    expect(props.createProjectFn).not.toHaveBeenCalled();
  });

  it("confirming the picker creates a project with the chosen target", async () => {
    const { props } = renderPanel();
    const body = within(document.body);
    fireEvent.click(body.getByRole("button", { name: /New motion/ }));
    await waitFor(() => expect(body.getByText("Choose the video size")).toBeTruthy());
    fireEvent.click(body.getByRole("radio", { name: /Instagram Post/ }));
    fireEvent.click(body.getByRole("button", { name: /Create motion/ }));

    await waitFor(() => expect(props.createProjectFn).toHaveBeenCalledTimes(1));
    const body_ = props.createProjectFn.mock.calls[0][1] as {
      snapshot: { board_width: number; board_height: number; target?: { platform_id: string } };
    };
    expect(body_.snapshot.board_width).toBe(1080);
    expect(body_.snapshot.board_height).toBe(1080);
    expect(body_.snapshot.target?.platform_id).toBe("instagram-post");
  });
});
```

Also update `renderPanel`'s default props to include the new required prop:

```tsx
    exportsByPlatformId: new Map(),
    renderPreviewFn: mock(async () => "data:image/png;base64,AA"),
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/motion/KvMotionProjectsPanel.test.tsx`
Expected: FAIL — "Choose the video size" never appears; `createProjectFn` called on click

- [ ] **Step 3a: Extend the analytics props**

Replace `src/lib/analytics/kv-generator-events.ts` lines 385-389 with:

```ts
export interface KvMotionProjectCreatedProps {
  file_id: string;
  board_generation_id: string;
  overlay_count: number;
  /** Resize preset id the project is locked to, or "native". */
  platform_id: string;
  /** Which image the animation sits on. Answers the question this feature
   *  exists to serve: are people animating real Resize output, or re-crops? */
  base_source: "resize" | "master" | "native";
}
```

- [ ] **Step 3b: Rework the panel**

In `KvMotionProjectsPanel.tsx`:

1. Add imports:

```tsx
import { buildMotionSnapshot } from "@/lib/motion/motionSnapshot";
import type { MotionSizeOption } from "@/lib/motion/motionSizeOptions";
import type { KvResizeExport, PlatformId } from "@/types/kv/resize";

import { KvMotionSizePicker } from "./KvMotionSizePicker";
```

2. Add to `KvMotionProjectsPanelProps`:

```tsx
  /** The file's finished resize results, keyed by platform — promotes those
   *  sizes into the picker's "From your resizes" group. */
  exportsByPlatformId: Map<PlatformId, KvResizeExport>;
  /** DI seam forwarded to the picker; production call sites omit it. */
  renderPreviewFn?: (option: MotionSizeOption) => Promise<string>;
```

3. Add picker state next to the existing `confirmDelete` state:

```tsx
  const [pickerOpen, setPickerOpen] = useState(false);
```

4. Replace the `createMutation` (lines 111-143) with a variant taking the chosen option:

```tsx
  const createMutation = useMutation({
    mutationFn: async (option: MotionSizeOption) => {
      if (!activeBoard || !activeGenerationId) {
        throw new Error("No board to animate yet.");
      }
      return createProjectFn(fileId, {
        boardGenerationId: activeGenerationId,
        snapshot: buildMotionSnapshot({
          option,
          nativeImageUrl: activeBoard.imageUrl,
          nativeWidth: activeBoard.width,
          nativeHeight: activeBoard.height,
          nativeOverlays: activeBoard.overlays,
        }),
        timeline: DEFAULT_TIMELINE(),
      });
    },
    onSuccess: (project, option) => {
      trackKvMotionProjectCreated({
        file_id: fileId,
        board_generation_id: project.boardGenerationId,
        overlay_count: activeBoard?.overlays.length ?? 0,
        platform_id: String(option.platformId),
        base_source: option.source,
      });
      setPickerOpen(false);
      qc.invalidateQueries({ queryKey: motionProjectsKey(fileId) });
      goToProject(project.id);
    },
    onError: (err) => {
      showToast(
        "Couldn't create that motion project",
        err instanceof Error ? err.message : "Please try again.",
        "error"
      );
    },
  });
```

5. Change the header button's `onClick` from `() => createMutation.mutate()` to `() => setPickerOpen(true)`.

6. Mount the picker beside the existing delete `BaseModal`, guarded on `activeBoard`:

```tsx
      {activeBoard && (
        <KvMotionSizePicker
          isOpen={pickerOpen}
          onClose={() => setPickerOpen(false)}
          onConfirm={(option) => createMutation.mutate(option)}
          creating={createMutation.isPending}
          nativeImageUrl={activeBoard.imageUrl}
          nativeWidth={activeBoard.width}
          nativeHeight={activeBoard.height}
          nativeOverlays={activeBoard.overlays}
          exportsByPlatformId={exportsByPlatformId}
          renderPreviewFn={renderPreviewFn}
        />
      )}
```

- [ ] **Step 3c: Pass the exports map down from the layout**

In `KvGeneratorLayout.tsx`, add the prop to the `<KvMotionProjectsPanel …>` render (around line 4223):

```tsx
                exportsByPlatformId={exportsByPlatformId}
```

`exportsByPlatformId` is already in scope — it comes from the `useResizeExports(fileId, viewedGeneration?.id ?? null)` destructure at line 1934, which is scoped to the same generation Motion treats as its active board.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd web && bun test src/components/studio/kv-generator/motion/`
Expected: PASS — the panel's existing tests plus the 2 new ones

- [ ] **Step 5: Commit**

```bash
git add web/src/components/studio/kv-generator/motion/KvMotionProjectsPanel.tsx web/src/components/studio/kv-generator/motion/KvMotionProjectsPanel.test.tsx web/src/components/studio/kv-generator/KvGeneratorLayout.tsx web/src/lib/analytics/kv-generator-events.ts
git commit -m "feat(web): New motion opens the size picker and locks the chosen size"
```

---

### Task 7: Lock the editor to the project's size

**Files:**
- Modify: `src/components/studio/kv-generator/motion/KvMotionEditor.tsx:625-643, 678, 750, 756, 795, 1103-1112`

**Interfaces:**
- Consumes: `resolveMotionTarget` (Task 2).
- Produces: nothing new. Removes `activeRatioId`, `setActiveRatioId`, `isNativeRatio`, `nativeRatioId` from the component.

**Note for the implementer:** every `isNativeRatio` reference becomes `true`. Simplify rather than leaving a `const isNativeRatio = true` behind — `node.draggable(isNativeRatio && !locked)` becomes `node.draggable(!locked)`, and `if (isNativeRatio) { … }` loses its condition.

- [ ] **Step 1: Replace the ratio state with the resolved target**

Replace lines 625-643 with:

```tsx
  // ── The project is LOCKED to one output size, chosen at creation in the
  // size picker. The preview renders at exactly that size and is always
  // editable — the old 1:1 / 9:16 / 16:9 preview chips and their read-only
  // non-native mode are gone, along with the "a drag here has no well-defined
  // mapping back onto the native board" caveat that mode existed to guard.
  // Projects created before the picker have no `snapshot.target`; the resolver
  // infers their size from the snapshot's own aspect. ──
  const activeRatio = useMemo(
    () => resolveMotionTarget(project.snapshot),
    [project.snapshot]
  );
```

Add the import:

```tsx
import { resolveMotionTarget } from "@/lib/motion/motionSnapshot";
```

- [ ] **Step 2: Collapse the `isNativeRatio` branches**

- Line ~678: drop the `isNativeRatio` mention from the comment; the fast path is now unconditional.
- Line ~750: `node.draggable(isNativeRatio && !locked);` → `node.draggable(!locked);`
- Line ~756: `if (isNativeRatio) {` → remove the conditional, keeping its body.
- Line ~795: remove `isNativeRatio` from the dependency array.

- [ ] **Step 3: Delete the ratio chips**

Remove the `{MOTION_RATIOS.map((r) => (…))}` block at lines 1103-1112 and replace it with a static label:

```tsx
          <span className="font-geist text-textXs text-text-inverse-subtlest">
            {activeRatio.label} · {activeRatio.w}×{activeRatio.h}
          </span>
```

Remove `MOTION_RATIOS` from the import at line 78 if nothing else in the file uses it.

- [ ] **Step 4: Verify**

Run: `cd web && bun test src/components/studio/kv-generator/motion/ src/components/motion-editor/`
Expected: PASS — no test asserts on the chips; if one does, update it to assert the static label instead.

Run: `cd web && bun run build`
Expected: success, no type errors. (`bun run build` is the real gate — `bun test` does not type-check.)

- [ ] **Step 5: Commit**

```bash
git add web/src/components/studio/kv-generator/motion/KvMotionEditor.tsx
git commit -m "refactor(web): lock the motion editor preview to the project's size"
```

---

### Task 8: Export dialog renders the locked size

**Files:**
- Modify: `src/components/studio/kv-generator/motion/KvMotionExportDialog.tsx:113-148, 219, 308, 325-340`
- Test: `src/components/studio/kv-generator/motion/exportMotion.test.ts` (no change expected — verify it still passes)

**Interfaces:**
- Consumes: `resolveMotionTarget` (Task 2).
- Produces: nothing new.

**Note for the implementer:** `exportMotionRatio` already accepts `ratio: MotionRatio | { id: string; w: number; h: number }`, so a resolved target can be handed to it directly with no change to `exportMotion.ts`. Do NOT delete `remapSnapshotForRatio` / `remapTimelineForRatio` — pre-spec projects still resolve to a size that differs from their snapshot dims, so the remap is still live.

- [ ] **Step 1: Replace the multi-ratio state with the single locked target**

Replace lines 113-148's ratio bookkeeping so that instead of `Record<string, boolean>` `checked` state and a `Record<string, RatioState>` map keyed by `MOTION_RATIOS`, there is:

```tsx
  const target = useMemo(() => resolveMotionTarget(snapshot), [snapshot]);
  const [state, setState] = useState<RatioState>(INITIAL_STATE);

  useEffect(() => {
    if (isOpen) setState(INITIAL_STATE);
  }, [isOpen]);
```

Add the import:

```tsx
import { resolveMotionTarget } from "@/lib/motion/motionSnapshot";
```

- [ ] **Step 2: Render one row instead of the checkbox list**

Replace the `{MOTION_RATIOS.map((ratio) => {…})}` block (lines 325-340) with:

```tsx
          <div className="flex items-center justify-between gap-3 rounded-lg border border-white/10 bg-[rgba(255,255,255,0.03)] px-3 py-2.5">
            <span className="font-geist text-textSm text-text-inverse">
              {target.label}
            </span>
            <span className="font-geist text-textXs text-text-inverse-subtlest">
              {target.w} × {target.h}
            </span>
          </div>
```

- [ ] **Step 3: Collapse the render loop**

- Line ~219: `const ratios = MOTION_RATIOS.filter((r) => checked[r.id]);` → `const ratios = [target];`
- Line ~308: `const anyChecked = MOTION_RATIOS.some((r) => checked[r.id]);` → delete; the Export button's `disabled` loses that term.
- Remove the now-unused `Checkbox` import and `MOTION_RATIOS` / `closestMotionRatio` imports if nothing else in the file uses them.

The sequential render loop, shared `AbortController`, per-ratio progress, upload-on-completion and retained-blob retry all stay exactly as they are — they simply iterate a one-element array now.

- [ ] **Step 4: Verify**

Run: `cd web && bun test src/components/studio/kv-generator/motion/`
Expected: PASS

Run: `cd web && bun run build`
Expected: success, no type errors

- [ ] **Step 5: Commit**

```bash
git add web/src/components/studio/kv-generator/motion/KvMotionExportDialog.tsx
git commit -m "feat(web): export the motion project at its locked output size"
```

---

## Final verification

- [ ] `cd web && bun test` — full suite. Compare failures against the pre-change baseline; there are known pre-existing reds unrelated to this work.
- [ ] `cd web && bun run build` — the real type gate.
- [ ] `cd web && bunx eslint src/lib/motion src/components/studio/kv-generator/motion` — compare against a baseline captured with `git show HEAD:<path> > <path>.baseline.tsx` (never `git stash`), then delete the baseline files.
- [ ] Manual, against a real file: resize a KV to Instagram Landscape, switch to Motion, open `New motion`. Confirm Instagram Landscape appears under **From your resizes** with the tile as its preview, create, confirm the editor canvas is 1080×566 and editable, export, confirm the MP4 is 1080×566.
- [ ] Manual: pick **YouTube Channel Banner** and confirm the row reads `2560 × 1440 · video 1920 × 1080` and the export lands at 1920×1080.
- [ ] Manual: open a motion project created before this change and confirm it still opens, previews, and exports.
