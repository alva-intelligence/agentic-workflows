# KV Expand Image — web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** "Expand image" on image overlays in KV Studio — right-click menus (Craft + Resize) and the Layers-panel row menu open a modal where the user picks a ratio preset or drags the expand bounds, runs the AI fill, and applies the result so the overlay's box grows while the original pixels stay put.

**Architecture:** Pure placement maths in `lib/studio/kv/expandPlacement.ts` (presets, clamping, drag, and the geometry+payload apply patch), a DOM-only `ExpandBoundsEditor`, a `KvExpandImageModal` that clones `KvRemoveBackgroundModal`'s phase machine + start/poll client, and the same optional-callback gating (`onExpandImage?`) that "Remove background" uses across `KvOverlayContextMenu`, `KvResizeOverlayContextMenu`, `layerRowMenu`, `KvLayersPanel`, `KvFabricCanvas`, `KvGeneratorLayout`, `KvResizeCanvas`. Network calls are injected (`api` param/prop) so nothing needs `mock.module`.

**Tech Stack:** Next.js 16 / React 19 / TypeScript, Tailwind, frndos v1 `BaseModal` + `Button`, TanStack Query (only in the lifted estimate hook), `bun test` + RTL.

**Spec:** `docs/superpowers/specs/2026-09-14-kv-image-expand-design.md` (workspace root) — §3 placement, §4 web, §7 errors, §8 testing.

## Global Constraints

- Placement type is the wire shape, snake_case, integer natural source pixels: `{ canvas_w, canvas_h, image_x, image_y }`. `MAX_CANVAS_EDGE = 4096`.
- Overlay geometry is normalised to the board (fractions 0..1), `rotation` in degrees, pivot = centre. Never assume pixel units in the patch builder.
- Gating: an entry point renders "Expand image" **only** when its `onExpandImage` (or `onExpandOverlayImage`) prop is supplied; parents supply it only when `useExperimentalFeatureEnabled(MAJOR_FEATURE_FLAGS.KV_IMAGE_EXPAND) === true`. Flag key string: `"show-kv-image-expand"`.
- Apply patch = geometry **and** payload in one call; payload spreads the existing image payload and swaps `asset_url` + `mime_type` (never `buildImageReplacePatch`, which drops `name/hidden/locked/opacity`).
- Test runner: `cd web && bun test <file>` — never `bunx vitest`, never a directory (memory: a directory run ate 26 GB). Query modal content via `within(document.body)` (Radix portal; `screen` is broken under bun). Keep every test file < 51 KB. No `mock.module` in new tests — inject.
- No `git stash`. Baseline comparisons use a worktree; a web worktree needs its own `bun install`.
- Build check at the end: `cd web && node node_modules/next/dist/bin/next build` (memory: `bun run build` is broken). The build does not type-check; diff `bunx tsc --noEmit -p . 2>&1 | grep <new file names>` instead.
- PostHog events are part of the feature: `trackKvImageExpandOpened / Run / Applied / Failed`.
- Work on branch `feature/daffa/vc-kv-image-expand` cut from `develop`. Commit per task; do not push.

---

### Task 0: Branch

- [ ] **Step 1: Create the branch**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web
git checkout develop && git pull --rebase origin develop
git checkout -b feature/daffa/vc-kv-image-expand
bun install
```

---

### Task 1: Types + api client

**Files:**
- Create: `web/src/types/kv/imageExpand.ts`
- Modify: `web/src/services/kv/api.ts` — add after the `getBackgroundRemoval` function (ends near line 1320)
- Test: `web/src/services/kv/imageExpand.api.test.ts`

**Interfaces:**
- Produces: `KvExpandPlacement`, `KvImageExpandStatus`, `KvImageExpand` (camelCase row), `createImageExpand(fileId, args: {sourceImageUrl, sourceW, sourceH, placement}) → Promise<KvImageExpand>`, `getImageExpand(fileId, id, signal?) → Promise<KvImageExpand>`.

- [ ] **Step 1: Write the failing test**

```ts
// web/src/services/kv/imageExpand.api.test.ts
import { describe, expect, it } from "bun:test";
import { toImageExpand, type WireImageExpand } from "./api";

describe("toImageExpand", () => {
  it("maps the wire row to camelCase and keeps placement verbatim", () => {
    const wire: WireImageExpand = {
      id: "e1",
      studio_file_id: "f1",
      source_image_url: "https://s3.test/src.png",
      source_w: 400,
      source_h: 300,
      placement: { canvas_w: 640, canvas_h: 360, image_x: 120, image_y: 30 },
      image_url: null,
      width: null,
      height: null,
      model_version: null,
      status: "pending",
      error_message: null,
      created_at: "2026-09-14T00:00:00Z",
      updated_at: "2026-09-14T00:00:00Z",
    };
    expect(toImageExpand(wire)).toEqual({
      id: "e1",
      studioFileId: "f1",
      sourceImageUrl: "https://s3.test/src.png",
      sourceW: 400,
      sourceH: 300,
      placement: { canvas_w: 640, canvas_h: 360, image_x: 120, image_y: 30 },
      imageUrl: null,
      width: null,
      height: null,
      modelVersion: null,
      status: "pending",
      errorMessage: null,
      createdAt: "2026-09-14T00:00:00Z",
      updatedAt: "2026-09-14T00:00:00Z",
    });
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web && bun test src/services/kv/imageExpand.api.test.ts`
Expected: FAIL — `toImageExpand` is not exported

- [ ] **Step 3: Write the types and client**

```ts
// web/src/types/kv/imageExpand.ts
/** AI "Expand image" (outpaint into a larger canvas) for one image overlay.
 *
 *  Wire mirror of `KvImageExpandResource` on the API side. FILE-scoped like
 *  background removals: the source is an overlay's `asset_url`, overlays live
 *  in the Yjs doc, so the API receives a `source_image_url`, not an overlay
 *  id. */

/** Every number is a NATURAL PIXEL of the source image. Same shape on the
 *  wire, in the api row and in ai-service — never translate the keys. */
export type KvExpandPlacement = {
  canvas_w: number;
  canvas_h: number;
  image_x: number;
  image_y: number;
};

export type KvImageExpandStatus = "pending" | "generating" | "done" | "failed";

export type KvImageExpand = {
  id: string;
  studioFileId: string;
  sourceImageUrl: string;
  sourceW: number;
  sourceH: number;
  placement: KvExpandPlacement;
  /** Expanded PNG. Null until `status === "done"`. */
  imageUrl: string | null;
  width: number | null;
  height: number | null;
  modelVersion: string | null;
  status: KvImageExpandStatus;
  errorMessage: string | null;
  createdAt: string;
  updatedAt: string;
};
```

In `web/src/services/kv/api.ts`, add to the imports near the top:

```ts
import type { KvExpandPlacement, KvImageExpand } from "@/types/kv/imageExpand";
```

and after `getBackgroundRemoval`:

```ts
// ── KV Expand Image ─────────────────────────────────────────────────────────

export type WireImageExpand = {
  id: string;
  studio_file_id: string;
  source_image_url: string;
  source_w: number;
  source_h: number;
  placement: KvExpandPlacement;
  image_url: string | null;
  width: number | null;
  height: number | null;
  model_version: string | null;
  status: "pending" | "generating" | "done" | "failed";
  error_message: string | null;
  created_at: string;
  updated_at: string;
};

export function toImageExpand(w: WireImageExpand): KvImageExpand {
  return {
    id: w.id,
    studioFileId: w.studio_file_id,
    sourceImageUrl: w.source_image_url,
    sourceW: w.source_w,
    sourceH: w.source_h,
    placement: w.placement,
    imageUrl: w.image_url,
    width: w.width,
    height: w.height,
    modelVersion: w.model_version,
    status: w.status,
    errorMessage: w.error_message,
    createdAt: w.created_at,
    updatedAt: w.updated_at,
  };
}

const IMAGE_EXPANDS_BASE = (fileId: string) =>
  `v1/studio/files/${fileId}/image-expands`;

/** Start an expand on an overlay's image. `sourceW/H` are the image's natural
 *  size — the api checks the placement contains the source without
 *  downloading it, and ai-service re-checks after download. */
export async function createImageExpand(
  fileId: string,
  args: {
    sourceImageUrl: string;
    sourceW: number;
    sourceH: number;
    placement: KvExpandPlacement;
  }
): Promise<KvImageExpand> {
  const { data } = await axiosInstance.post(IMAGE_EXPANDS_BASE(fileId), {
    source_image_url: args.sourceImageUrl,
    source_w: args.sourceW,
    source_h: args.sourceH,
    placement: args.placement,
  });
  return toImageExpand(unwrap<WireImageExpand>(data));
}

export async function getImageExpand(
  fileId: string,
  id: string,
  /** Per-request abort signal for the poll loop — `axiosInstance` sets no
   *  global timeout. Same reasoning as `getBackgroundRemoval`. */
  signal?: AbortSignal
): Promise<KvImageExpand> {
  const { data } = await axiosInstance.get(`${IMAGE_EXPANDS_BASE(fileId)}/${id}`, {
    signal,
  });
  return toImageExpand(unwrap<WireImageExpand>(data));
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web && bun test src/services/kv/imageExpand.api.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/types/kv/imageExpand.ts src/services/kv/api.ts src/services/kv/imageExpand.api.test.ts
git commit -m "feat(web): kv image expand types + api client

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Placement maths (pure)

**Files:**
- Create: `web/src/lib/studio/kv/expandPlacement.ts`
- Test: `web/src/lib/studio/kv/expandPlacement.test.ts`

**Interfaces:**
- Produces:
  - `MAX_CANVAS_EDGE = 4096`
  - `type KvExpandPreset = "original" | "square" | "portrait" | "landscape"`; `EXPAND_PRESETS: { key, label }[]`
  - `computePresetPlacement(sourceW, sourceH, preset) → KvExpandPlacement`
  - `presetExceedsCap(sourceW, sourceH, preset) → boolean`
  - `clampPlacement(p, sourceW, sourceH) → KvExpandPlacement`
  - `type ExpandHandle = "n"|"s"|"e"|"w"|"ne"|"nw"|"se"|"sw"`
  - `applyHandleDrag(start, handle, dx, dy, sourceW, sourceH) → KvExpandPlacement` (dx/dy in source px)
  - `applyImageDrag(start, dx, dy, sourceW, sourceH) → KvExpandPlacement`
  - `isExpandable(p, sourceW, sourceH) → boolean`
  - `sourceExceedsCap(sourceW, sourceH) → boolean`
  - `buildExpandApplyPatch({ overlay, placement, sourceW, sourceH, imageUrl, mimeType, hostAspect }) → { x, y, width, height, payload }`

- [ ] **Step 1: Write the failing tests**

```ts
// web/src/lib/studio/kv/expandPlacement.test.ts
import { describe, expect, it } from "bun:test";
import type { StudioOverlay } from "@/types/studio";
import {
  applyHandleDrag,
  applyImageDrag,
  buildExpandApplyPatch,
  clampPlacement,
  computePresetPlacement,
  isExpandable,
  MAX_CANVAS_EDGE,
  presetExceedsCap,
  sourceExceedsCap,
} from "./expandPlacement";

// Numbers below were computed by hand from spec §3.1 for a 400×300 source:
//  square   r=1      : sw/sh=1.333 ≥ 1     → 400 × ceil(400/1)=400,     x=0,   y=floor(100/2)=50
//  portrait r=0.5625 : 1.333 ≥ 0.5625      → 400 × ceil(400/0.5625)=712, x=0,   y=floor(412/2)=206
//  landscape r=1.777 : 1.333 < 1.777       → ceil(300*16/9)=534 × 300,   x=floor(134/2)=67, y=0

describe("computePresetPlacement", () => {
  it("original equals the source", () => {
    expect(computePresetPlacement(400, 300, "original")).toEqual({
      canvas_w: 400, canvas_h: 300, image_x: 0, image_y: 0,
    });
  });
  it("square on a landscape source pads top/bottom", () => {
    expect(computePresetPlacement(400, 300, "square")).toEqual({
      canvas_w: 400, canvas_h: 400, image_x: 0, image_y: 50,
    });
  });
  it("portrait on a landscape source pads top/bottom", () => {
    expect(computePresetPlacement(400, 300, "portrait")).toEqual({
      canvas_w: 400, canvas_h: 712, image_x: 0, image_y: 206,
    });
  });
  it("landscape on a landscape source pads left/right", () => {
    expect(computePresetPlacement(400, 300, "landscape")).toEqual({
      canvas_w: 534, canvas_h: 300, image_x: 67, image_y: 0,
    });
  });
  it("landscape on a portrait source pads left/right", () => {
    // 300×400: 0.75 < 1.777 → canvas_h=400, canvas_w=ceil(400*16/9)=712, x=floor(412/2)=206
    expect(computePresetPlacement(300, 400, "landscape")).toEqual({
      canvas_w: 712, canvas_h: 400, image_x: 206, image_y: 0,
    });
  });
  it("every preset contains the source", () => {
    for (const preset of ["original", "square", "portrait", "landscape"] as const) {
      const p = computePresetPlacement(400, 300, preset);
      expect(p.image_x).toBeGreaterThanOrEqual(0);
      expect(p.image_y).toBeGreaterThanOrEqual(0);
      expect(p.image_x + 400).toBeLessThanOrEqual(p.canvas_w);
      expect(p.image_y + 300).toBeLessThanOrEqual(p.canvas_h);
    }
  });
});

describe("caps", () => {
  it("MAX_CANVAS_EDGE is 4096", () => {
    expect(MAX_CANVAS_EDGE).toBe(4096);
  });
  it("presetExceedsCap flags a preset whose canvas would pass 4096", () => {
    // 3000×2000 portrait → canvas_h = ceil(3000/0.5625) = 5334
    expect(presetExceedsCap(3000, 2000, "portrait")).toBe(true);
    expect(presetExceedsCap(3000, 2000, "landscape")).toBe(false); // 3556×2000
    expect(presetExceedsCap(400, 300, "portrait")).toBe(false);
  });
  it("sourceExceedsCap", () => {
    expect(sourceExceedsCap(4097, 10)).toBe(true);
    expect(sourceExceedsCap(10, 4097)).toBe(true);
    expect(sourceExceedsCap(4096, 4096)).toBe(false);
  });
});

describe("clampPlacement", () => {
  it("never lets the canvas shrink below the source or grow past the cap", () => {
    expect(clampPlacement({ canvas_w: 100, canvas_h: 5000, image_x: 0, image_y: 0 }, 400, 300))
      .toEqual({ canvas_w: 400, canvas_h: 4096, image_x: 0, image_y: 0 });
  });
  it("keeps the image inside the canvas", () => {
    expect(clampPlacement({ canvas_w: 640, canvas_h: 360, image_x: 300, image_y: -5 }, 400, 300))
      .toEqual({ canvas_w: 640, canvas_h: 360, image_x: 240, image_y: 0 });
  });
  it("rounds to integers", () => {
    expect(clampPlacement({ canvas_w: 640.4, canvas_h: 360.6, image_x: 10.5, image_y: 0 }, 400, 300))
      .toEqual({ canvas_w: 640, canvas_h: 361, image_x: 11, image_y: 0 });
  });
});

describe("applyHandleDrag", () => {
  const start = { canvas_w: 640, canvas_h: 360, image_x: 120, image_y: 30 };
  it("east grows width only", () => {
    expect(applyHandleDrag(start, "e", 50, 999, 400, 300))
      .toEqual({ ...start, canvas_w: 690 });
  });
  it("west grows width AND shifts image_x so the source stays put", () => {
    expect(applyHandleDrag(start, "w", -50, 0, 400, 300))
      .toEqual({ ...start, canvas_w: 690, image_x: 170 });
  });
  it("north grows height AND shifts image_y", () => {
    expect(applyHandleDrag(start, "n", 0, -20, 400, 300))
      .toEqual({ ...start, canvas_h: 380, image_y: 50 });
  });
  it("south grows height only", () => {
    expect(applyHandleDrag(start, "s", 0, 20, 400, 300))
      .toEqual({ ...start, canvas_h: 380 });
  });
  it("corner combines both axes", () => {
    expect(applyHandleDrag(start, "nw", -10, -10, 400, 300))
      .toEqual({ canvas_w: 650, canvas_h: 370, image_x: 130, image_y: 40 });
  });
  it("cannot shrink past the source: west dragged far right pins image_x to 0", () => {
    expect(applyHandleDrag(start, "w", 500, 0, 400, 300))
      .toEqual({ ...start, canvas_w: 400, image_x: 0 });
  });
  it("cannot grow past the cap", () => {
    expect(applyHandleDrag(start, "e", 10_000, 0, 400, 300).canvas_w).toBe(4096);
  });
});

describe("applyImageDrag", () => {
  const start = { canvas_w: 640, canvas_h: 360, image_x: 120, image_y: 30 };
  it("moves the image inside the canvas", () => {
    expect(applyImageDrag(start, 30, -10, 400, 300))
      .toEqual({ ...start, image_x: 150, image_y: 20 });
  });
  it("clamps to the canvas edges", () => {
    expect(applyImageDrag(start, 1000, -1000, 400, 300))
      .toEqual({ ...start, image_x: 240, image_y: 0 });
  });
});

describe("isExpandable", () => {
  it("false when the canvas equals the source", () => {
    expect(isExpandable({ canvas_w: 400, canvas_h: 300, image_x: 0, image_y: 0 }, 400, 300)).toBe(false);
  });
  it("true when any axis grew", () => {
    expect(isExpandable({ canvas_w: 401, canvas_h: 300, image_x: 0, image_y: 0 }, 400, 300)).toBe(true);
    expect(isExpandable({ canvas_w: 400, canvas_h: 301, image_x: 0, image_y: 0 }, 400, 300)).toBe(true);
  });
});

// ── apply patch ───────────────────────────────────────────────────────────

const overlay = {
  id: "o1",
  studio_file_id: "f1",
  type: "image",
  x: 0.1, y: 0.2, width: 0.4, height: 0.3, rotation: 0, z: 1,
  payload: { type: "image", asset_url: "old", mime_type: "image/jpeg", name: "Hero", locked: true },
} as unknown as StudioOverlay;

const PLACEMENT = { canvas_w: 640, canvas_h: 360, image_x: 40, image_y: 10 };

/** Where the SOURCE's centre lands in board space after the patch — the
 *  invariant the whole feature rests on is that this equals the overlay's
 *  centre before the patch. Rotation happens in board pixels (x scaled by
 *  hostAspect), around the new box's centre. */
function sourceCenterAfter(
  patch: { x: number; y: number; width: number; height: number },
  rotationDeg: number,
  hostAspect: number,
  sx: number,
  sy: number,
  sourceW: number,
  sourceH: number
) {
  const cx = patch.x + patch.width / 2;
  const cy = patch.y + patch.height / 2;
  // source centre offset from the new box centre, local unrotated, normalised
  const lx = PLACEMENT.image_x * sx + (sourceW * sx) / 2 - patch.width / 2;
  const ly = PLACEMENT.image_y * sy + (sourceH * sy) / 2 - patch.height / 2;
  const t = (rotationDeg * Math.PI) / 180;
  const px = lx * hostAspect;
  const py = ly;
  const rx = px * Math.cos(t) - py * Math.sin(t);
  const ry = px * Math.sin(t) + py * Math.cos(t);
  return { x: cx + rx / hostAspect, y: cy + ry };
}

describe("buildExpandApplyPatch", () => {
  it("rotation 0: box grows, top-left shifts by -image_x*sx / -image_y*sy", () => {
    const patch = buildExpandApplyPatch({
      overlay, placement: PLACEMENT, sourceW: 400, sourceH: 300,
      imageUrl: "new", mimeType: "image/png", hostAspect: 1,
    });
    // sx = 0.4/400 = 0.001, sy = 0.3/300 = 0.001
    expect(patch.width).toBeCloseTo(0.64, 10);
    expect(patch.height).toBeCloseTo(0.36, 10);
    expect(patch.x).toBeCloseTo(0.1 - 0.04, 10);
    expect(patch.y).toBeCloseTo(0.2 - 0.01, 10);
  });

  it("swaps asset_url/mime_type and keeps the rest of the payload", () => {
    const patch = buildExpandApplyPatch({
      overlay, placement: PLACEMENT, sourceW: 400, sourceH: 300,
      imageUrl: "new", mimeType: "image/png", hostAspect: 1,
    });
    expect(patch.payload).toEqual({
      type: "image", asset_url: "new", mime_type: "image/png", name: "Hero", locked: true,
    });
  });

  it("uses per-axis scales when the overlay is stretched", () => {
    const stretched = { ...overlay, width: 0.8, height: 0.3 } as StudioOverlay; // sx=0.002, sy=0.001
    const patch = buildExpandApplyPatch({
      overlay: stretched, placement: PLACEMENT, sourceW: 400, sourceH: 300,
      imageUrl: "new", mimeType: "image/png", hostAspect: 1,
    });
    expect(patch.width).toBeCloseTo(1.28, 10);
    expect(patch.height).toBeCloseTo(0.36, 10);
    expect(patch.x).toBeCloseTo(0.1 - 0.08, 10);
    expect(patch.y).toBeCloseTo(0.2 - 0.01, 10);
  });

  for (const [rotation, hostAspect] of [[90, 1], [45, 1], [30, 16 / 9], [270, 0.5625]] as const) {
    it(`rotation ${rotation}° / hostAspect ${hostAspect.toFixed(3)}: the source's centre does not move`, () => {
      const rotated = { ...overlay, rotation } as StudioOverlay;
      const patch = buildExpandApplyPatch({
        overlay: rotated, placement: PLACEMENT, sourceW: 400, sourceH: 300,
        imageUrl: "new", mimeType: "image/png", hostAspect,
      });
      const before = { x: overlay.x + overlay.width / 2, y: overlay.y + overlay.height / 2 };
      const after = sourceCenterAfter(patch, rotation, hostAspect, 0.001, 0.001, 400, 300);
      expect(after.x).toBeCloseTo(before.x, 10);
      expect(after.y).toBeCloseTo(before.y, 10);
      // and the box really grew
      expect(patch.width).toBeCloseTo(0.64, 10);
      expect(patch.height).toBeCloseTo(0.36, 10);
    });
  }

  it("rotation 90°, hostAspect 1: concrete numbers", () => {
    // shiftN = (dx + newW/2 - w/2, dy + newH/2 - h/2) = (-0.04+0.32-0.2, -0.01+0.18-0.15) = (0.08, 0.02)
    // R(90°)·(0.08, 0.02) = (-0.02, 0.08) → newCenter = (0.28, 0.43) → x = -0.04, y = 0.25
    const patch = buildExpandApplyPatch({
      overlay: { ...overlay, rotation: 90 } as StudioOverlay,
      placement: PLACEMENT, sourceW: 400, sourceH: 300,
      imageUrl: "new", mimeType: "image/png", hostAspect: 1,
    });
    expect(patch.x).toBeCloseTo(-0.04, 10);
    expect(patch.y).toBeCloseTo(0.25, 10);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web && bun test src/lib/studio/kv/expandPlacement.test.ts`
Expected: FAIL — module not found

- [ ] **Step 3: Write the module**

```ts
// web/src/lib/studio/kv/expandPlacement.ts
import type { StudioOverlay } from "@/types/studio";
import type { KvExpandPlacement } from "@/types/kv/imageExpand";

/** Largest output edge we bill for. The api (CreateKvImageExpandRequest) and
 *  ai-service (MAX_CANVAS_EDGE) enforce the same number. */
export const MAX_CANVAS_EDGE = 4096;

export type KvExpandPreset = "original" | "square" | "portrait" | "landscape";

export const EXPAND_PRESETS: { key: KvExpandPreset; label: string }[] = [
  { key: "original", label: "Original" },
  { key: "square", label: "Square 1:1" },
  { key: "portrait", label: "Portrait 9:16" },
  { key: "landscape", label: "Landscape 16:9" },
];

const PRESET_RATIO: Record<Exclude<KvExpandPreset, "original">, number> = {
  square: 1,
  portrait: 9 / 16,
  landscape: 16 / 9,
};

function clampInt(v: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, Math.round(v)));
}

/** Smallest canvas of the preset's ratio that contains the source, source
 *  centred (spec §3.1). NOT clamped to the cap — see `presetExceedsCap`. */
export function computePresetPlacement(
  sourceW: number,
  sourceH: number,
  preset: KvExpandPreset
): KvExpandPlacement {
  if (preset === "original") {
    return { canvas_w: sourceW, canvas_h: sourceH, image_x: 0, image_y: 0 };
  }
  const r = PRESET_RATIO[preset];
  let canvas_w: number;
  let canvas_h: number;
  if (sourceW / sourceH >= r) {
    canvas_w = sourceW;
    canvas_h = Math.ceil(sourceW / r);
  } else {
    canvas_h = sourceH;
    canvas_w = Math.ceil(sourceH * r);
  }
  return {
    canvas_w,
    canvas_h,
    image_x: Math.floor((canvas_w - sourceW) / 2),
    image_y: Math.floor((canvas_h - sourceH) / 2),
  };
}

export function presetExceedsCap(
  sourceW: number,
  sourceH: number,
  preset: KvExpandPreset
): boolean {
  const p = computePresetPlacement(sourceW, sourceH, preset);
  return p.canvas_w > MAX_CANVAS_EDGE || p.canvas_h > MAX_CANVAS_EDGE;
}

export function sourceExceedsCap(sourceW: number, sourceH: number): boolean {
  return sourceW > MAX_CANVAS_EDGE || sourceH > MAX_CANVAS_EDGE;
}

/** Enforce the invariants: integers, canvas ≥ source and ≤ cap, image inside. */
export function clampPlacement(
  p: KvExpandPlacement,
  sourceW: number,
  sourceH: number
): KvExpandPlacement {
  const canvas_w = clampInt(p.canvas_w, sourceW, MAX_CANVAS_EDGE);
  const canvas_h = clampInt(p.canvas_h, sourceH, MAX_CANVAS_EDGE);
  return {
    canvas_w,
    canvas_h,
    image_x: clampInt(p.image_x, 0, canvas_w - sourceW),
    image_y: clampInt(p.image_y, 0, canvas_h - sourceH),
  };
}

export type ExpandHandle = "n" | "s" | "e" | "w" | "ne" | "nw" | "se" | "sw";

/** Drag one frame handle by (dx, dy) SOURCE pixels from `start`. Left/top
 *  handles move the canvas edge AND the image offset by the same amount so
 *  the source stays where it is on screen. */
export function applyHandleDrag(
  start: KvExpandPlacement,
  handle: ExpandHandle,
  dx: number,
  dy: number,
  sourceW: number,
  sourceH: number
): KvExpandPlacement {
  let { canvas_w, canvas_h, image_x, image_y } = start;
  if (handle.includes("e")) canvas_w += dx;
  if (handle.includes("w")) {
    canvas_w -= dx;
    image_x -= dx;
  }
  if (handle.includes("s")) canvas_h += dy;
  if (handle.includes("n")) {
    canvas_h -= dy;
    image_y -= dy;
  }
  return clampPlacement({ canvas_w, canvas_h, image_x, image_y }, sourceW, sourceH);
}

export function applyImageDrag(
  start: KvExpandPlacement,
  dx: number,
  dy: number,
  sourceW: number,
  sourceH: number
): KvExpandPlacement {
  return clampPlacement(
    { ...start, image_x: start.image_x + dx, image_y: start.image_y + dy },
    sourceW,
    sourceH
  );
}

/** "Original" (or a frame dragged back onto the source) has nothing to
 *  paint — the Run button is disabled in that state. */
export function isExpandable(
  p: KvExpandPlacement,
  sourceW: number,
  sourceH: number
): boolean {
  return p.canvas_w > sourceW || p.canvas_h > sourceH;
}

/**
 * Geometry + payload patch that applies an expand result to its overlay so
 * the ORIGINAL pixels keep their exact on-board position and size (spec §4.3).
 *
 * Overlay geometry is normalised to the host board and rotation pivots on the
 * overlay's centre, so: per-axis scales (`sx`, `sy`), and the centre shift is
 * rotated in board-PIXEL space (x scaled by `hostAspect = boardW / boardH`)
 * before being converted back. At rotation 0 `hostAspect` cancels out.
 *
 * The payload spreads the live image payload (name / hidden / locked / opacity
 * survive) and only swaps the asset — unlike `buildImageReplacePatch`.
 */
export function buildExpandApplyPatch(args: {
  overlay: StudioOverlay;
  placement: KvExpandPlacement;
  sourceW: number;
  sourceH: number;
  imageUrl: string;
  mimeType: string;
  hostAspect: number;
}): {
  x: number;
  y: number;
  width: number;
  height: number;
  payload: StudioOverlay["payload"];
} {
  const { overlay, placement, sourceW, sourceH, imageUrl, mimeType } = args;
  const hostAspect = args.hostAspect > 0 ? args.hostAspect : 1;
  const sx = overlay.width / sourceW;
  const sy = overlay.height / sourceH;
  const newW = placement.canvas_w * sx;
  const newH = placement.canvas_h * sy;
  const dx = -placement.image_x * sx;
  const dy = -placement.image_y * sy;

  const oldCx = overlay.x + overlay.width / 2;
  const oldCy = overlay.y + overlay.height / 2;
  const shiftNx = dx + newW / 2 - overlay.width / 2;
  const shiftNy = dy + newH / 2 - overlay.height / 2;

  const t = ((overlay.rotation ?? 0) * Math.PI) / 180;
  const px = shiftNx * hostAspect;
  const py = shiftNy;
  const rx = px * Math.cos(t) - py * Math.sin(t);
  const ry = px * Math.sin(t) + py * Math.cos(t);

  const newCx = oldCx + rx / hostAspect;
  const newCy = oldCy + ry;

  const payload =
    overlay.payload.type === "image"
      ? { ...overlay.payload, asset_url: imageUrl, mime_type: mimeType }
      : ({ type: "image", asset_url: imageUrl, mime_type: mimeType } as const);

  return {
    x: newCx - newW / 2,
    y: newCy - newH / 2,
    width: newW,
    height: newH,
    payload: payload as StudioOverlay["payload"],
  };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd web && bun test src/lib/studio/kv/expandPlacement.test.ts`
Expected: all PASS

- [ ] **Step 5: Mutation checks** (each: mutate, run, confirm RED, revert)
  1. In `applyHandleDrag`, delete the `image_x -= dx;` line → `west grows width AND shifts image_x` must fail.
  2. In `buildExpandApplyPatch`, replace `rx / hostAspect` with `rx` → the `hostAspect 1.778` and `0.5625` centre tests must fail, the `hostAspect 1` ones still pass.
  3. Replace `{ ...overlay.payload, ... }` with `{ type: "image", asset_url, mime_type }` → the payload test must fail.

- [ ] **Step 6: Commit**

```bash
git add src/lib/studio/kv/expandPlacement.ts src/lib/studio/kv/expandPlacement.test.ts
git commit -m "feat(web): kv expand placement maths + apply patch

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Start / poll client

**Files:**
- Create: `web/src/components/studio/kv-generator/imageExpand.ts`
- Test: `web/src/components/studio/kv-generator/imageExpand.test.ts`

**Interfaces:**
- Consumes: `createImageExpand`, `getImageExpand` (Task 1).
- Produces: `ImageExpandApi = { create: typeof createImageExpand; get: typeof getImageExpand }`, `realImageExpandApi`, `DEFAULT_INTERVAL_MS = 3000`, `DEFAULT_MAX_ATTEMPTS = 60`, `POLL_REQUEST_TIMEOUT_MS = 20_000`, `extractImageExpandErrorMessage(err, fallback, abortMessage?)`, `startImageExpand(args, api?) → Promise<{ok:true,row}|{ok:false,message}>`, `pollImageExpand(fileId, id, opts?, api?) → Promise<KvImageExpand>`.

- [ ] **Step 1: Write the failing tests**

```ts
// web/src/components/studio/kv-generator/imageExpand.test.ts
import { describe, expect, it } from "bun:test";
import type { KvImageExpand } from "@/types/kv/imageExpand";
import {
  DEFAULT_INTERVAL_MS,
  DEFAULT_MAX_ATTEMPTS,
  extractImageExpandErrorMessage,
  pollImageExpand,
  startImageExpand,
  type ImageExpandApi,
} from "./imageExpand";

const row = (status: KvImageExpand["status"], extra: Partial<KvImageExpand> = {}): KvImageExpand => ({
  id: "e1", studioFileId: "f1", sourceImageUrl: "s", sourceW: 400, sourceH: 300,
  placement: { canvas_w: 640, canvas_h: 360, image_x: 120, image_y: 30 },
  imageUrl: null, width: null, height: null, modelVersion: null,
  status, errorMessage: null, createdAt: "", updatedAt: "", ...extra,
});

const noSleep = () => Promise.resolve();
const PLACEMENT = { canvas_w: 640, canvas_h: 360, image_x: 120, image_y: 30 };

describe("the polling window", () => {
  it("covers at least 180 seconds (gpt-image-2 is slower than segmentation)", () => {
    expect(DEFAULT_INTERVAL_MS * DEFAULT_MAX_ATTEMPTS).toBeGreaterThanOrEqual(180_000);
  });
});

describe("startImageExpand", () => {
  it("forwards every field and returns ok", async () => {
    const calls: unknown[] = [];
    const api: ImageExpandApi = {
      create: async (fileId, args) => { calls.push([fileId, args]); return row("pending"); },
      get: async () => row("pending"),
    };
    const res = await startImageExpand(
      { fileId: "f1", sourceImageUrl: "https://s3.test/src.png", sourceW: 400, sourceH: 300, placement: PLACEMENT },
      api
    );
    expect(res.ok).toBe(true);
    expect(calls).toEqual([["f1", { sourceImageUrl: "https://s3.test/src.png", sourceW: 400, sourceH: 300, placement: PLACEMENT }]]);
  });

  it("returns the api's own message on failure instead of throwing", async () => {
    const api: ImageExpandApi = {
      create: async () => { throw { response: { data: { message: "Expand image quota reached, try again in 12m" } } }; },
      get: async () => row("pending"),
    };
    const res = await startImageExpand(
      { fileId: "f1", sourceImageUrl: "s", sourceW: 400, sourceH: 300, placement: PLACEMENT },
      api
    );
    expect(res).toEqual({ ok: false, message: "Expand image quota reached, try again in 12m" });
  });

  it("falls back to a generic message when the error has no body", async () => {
    const api: ImageExpandApi = {
      create: async () => { throw new Error("network"); },
      get: async () => row("pending"),
    };
    const res = await startImageExpand(
      { fileId: "f1", sourceImageUrl: "s", sourceW: 400, sourceH: 300, placement: PLACEMENT },
      api
    );
    expect(res.ok).toBe(false);
    if (!res.ok) expect(res.message).toBe("Couldn't start the expand. Try again.");
  });
});

describe("pollImageExpand", () => {
  function apiFrom(statuses: KvImageExpand["status"][]): { api: ImageExpandApi; gets: () => number } {
    let i = 0;
    const api: ImageExpandApi = {
      create: async () => row("pending"),
      get: async () => row(statuses[Math.min(i++, statuses.length - 1)]),
    };
    return { api, gets: () => i };
  }

  it("stops at done", async () => {
    const { api, gets } = apiFrom(["pending", "generating", "done"]);
    const r = await pollImageExpand("f1", "e1", { sleep: noSleep }, api);
    expect(r.status).toBe("done");
    expect(gets()).toBe(3);
  });

  it("stops at failed", async () => {
    const { api, gets } = apiFrom(["generating", "failed"]);
    const r = await pollImageExpand("f1", "e1", { sleep: noSleep }, api);
    expect(r.status).toBe("failed");
    expect(gets()).toBe(2);
  });

  it("stops when cancelled without another GET", async () => {
    const { api, gets } = apiFrom(["generating"]);
    let cancelled = false;
    const r = await pollImageExpand(
      "f1", "e1",
      { sleep: async () => { cancelled = true; }, isCancelled: () => cancelled },
      api
    );
    expect(r.status).toBe("generating");
    expect(gets()).toBe(1);
  });

  it("gives up after maxAttempts", async () => {
    const { api, gets } = apiFrom(["generating"]);
    const r = await pollImageExpand("f1", "e1", { sleep: noSleep, maxAttempts: 5 }, api);
    expect(r.status).toBe("generating");
    expect(gets()).toBe(5);
  });
});

describe("extractImageExpandErrorMessage", () => {
  it("uses abortMessage for a timed-out GET", () => {
    const err = new DOMException("aborted", "AbortError");
    expect(extractImageExpandErrorMessage(err, "fallback", "took too long")).toBe("took too long");
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web && bun test src/components/studio/kv-generator/imageExpand.test.ts`
Expected: FAIL — module not found

- [ ] **Step 3: Write the client**

```ts
// web/src/components/studio/kv-generator/imageExpand.ts
import { createImageExpand, getImageExpand } from "@/services/kv/api";
import type { KvExpandPlacement, KvImageExpand } from "@/types/kv/imageExpand";

/** Injected so tests never need `mock.module` (process-global, leaks across
 *  suites — see memory lesson_bun_mock_module_binding_capture). */
export type ImageExpandApi = {
  create: typeof createImageExpand;
  get: typeof getImageExpand;
};

export const realImageExpandApi: ImageExpandApi = {
  create: createImageExpand,
  get: getImageExpand,
};

/** gpt-image-2 outpaints in ~20-60s plus the S3 mirror. 3s × 60 = 180s —
 *  wider than bg-removal's 90s, narrower than decomposition's 225s. */
export const DEFAULT_INTERVAL_MS = 3000;
export const DEFAULT_MAX_ATTEMPTS = 60;
/** Bound on a SINGLE poll GET, not the window above — `axiosInstance` sets
 *  no global timeout, so a hung request would otherwise never resolve. */
export const POLL_REQUEST_TIMEOUT_MS = 20_000;

const realSleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export function extractImageExpandErrorMessage(
  err: unknown,
  fallback: string,
  abortMessage: string = fallback
): string {
  if (err instanceof DOMException && err.name === "AbortError") return abortMessage;
  const apiMessage = (err as { response?: { data?: { message?: string } } } | null)
    ?.response?.data?.message;
  return apiMessage ?? fallback;
}

export type StartImageExpandResult =
  | { ok: true; row: KvImageExpand }
  | { ok: false; message: string };

export async function startImageExpand(
  args: {
    fileId: string;
    sourceImageUrl: string;
    sourceW: number;
    sourceH: number;
    placement: KvExpandPlacement;
  },
  api: ImageExpandApi = realImageExpandApi
): Promise<StartImageExpandResult> {
  try {
    const row = await api.create(args.fileId, {
      sourceImageUrl: args.sourceImageUrl,
      sourceW: args.sourceW,
      sourceH: args.sourceH,
      placement: args.placement,
    });
    return { ok: true, row };
  } catch (err) {
    // Never rethrown: a failed start must not take the canvas down.
    console.error("[kv] image expand start failed", err);
    return {
      ok: false,
      message: extractImageExpandErrorMessage(err, "Couldn't start the expand. Try again."),
    };
  }
}

export async function pollImageExpand(
  fileId: string,
  id: string,
  opts?: {
    intervalMs?: number;
    maxAttempts?: number;
    sleep?: (ms: number) => Promise<void>;
    isCancelled?: () => boolean;
  },
  api: ImageExpandApi = realImageExpandApi
): Promise<KvImageExpand> {
  const intervalMs = opts?.intervalMs ?? DEFAULT_INTERVAL_MS;
  const maxAttempts = opts?.maxAttempts ?? DEFAULT_MAX_ATTEMPTS;
  const sleep = opts?.sleep ?? realSleep;
  const isCancelled = opts?.isCancelled ?? (() => false);

  let row = await api.get(fileId, id, AbortSignal.timeout(POLL_REQUEST_TIMEOUT_MS));
  for (let attempt = 1; attempt < maxAttempts; attempt += 1) {
    if (row.status === "done" || row.status === "failed") return row;
    if (isCancelled()) return row;
    await sleep(intervalMs);
    if (isCancelled()) return row;
    row = await api.get(fileId, id, AbortSignal.timeout(POLL_REQUEST_TIMEOUT_MS));
  }
  return row;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd web && bun test src/components/studio/kv-generator/imageExpand.test.ts`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/imageExpand.ts src/components/studio/kv-generator/imageExpand.test.ts
git commit -m "feat(web): kv image expand start/poll client

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Feature flag, analytics events, lifted credit-estimate hook

**Files:**
- Modify: `web/src/lib/featureFlags/constants.ts` — after `KV_BG_REMOVAL: "show-kv-bg-removal",` (line 283)
- Modify: `web/src/lib/analytics/kv-generator-events.ts` — after `trackKvBgRemovalFailed` (line ~768)
- Create: `web/src/lib/studio/kv/useGptImageCreditEstimate.ts`
- Modify: `web/src/components/studio/kv-generator/KvResizePanel.tsx` — replace the private `useResizeCreditEstimate` (lines 32–47) with the lifted hook
- Test: `web/src/lib/analytics/kvImageExpandEvents.test.ts`

**Interfaces:**
- Produces: `MAJOR_FEATURE_FLAGS.KV_IMAGE_EXPAND`; `KvImageExpandSource = "canvas" | "layers_panel" | "resize_canvas"`; `trackKvImageExpandOpened({overlay_id, source})`, `trackKvImageExpandRun({overlay_id, source, preset, canvas_w, canvas_h, source_w, source_h})`, `trackKvImageExpandApplied({overlay_id, source, preset, canvas_w, canvas_h, duration_ms, model_version})`, `trackKvImageExpandFailed({overlay_id, source, error_reason, duration_ms})`; `useGptImageCreditEstimate(count: number): number | null`.

- [ ] **Step 1: Write the failing test**

```ts
// web/src/lib/analytics/kvImageExpandEvents.test.ts
import { describe, expect, it } from "bun:test";
import {
  trackKvImageExpandApplied,
  trackKvImageExpandFailed,
  trackKvImageExpandOpened,
  trackKvImageExpandRun,
} from "./kv-generator-events";
import { MAJOR_FEATURE_FLAGS } from "@/lib/featureFlags/constants";

describe("kv image expand events", () => {
  it("are exported and callable without posthog loaded (safeCapture swallows)", () => {
    expect(() => {
      trackKvImageExpandOpened({ overlay_id: "o1", source: "canvas" });
      trackKvImageExpandRun({
        overlay_id: "o1", source: "layers_panel", preset: "landscape",
        canvas_w: 534, canvas_h: 300, source_w: 400, source_h: 300,
      });
      trackKvImageExpandApplied({
        overlay_id: "o1", source: "resize_canvas", preset: "custom",
        canvas_w: 640, canvas_h: 360, duration_ms: 1200, model_version: "gpt-image-2",
      });
      trackKvImageExpandFailed({
        overlay_id: "o1", source: "canvas", error_reason: "start_failed", duration_ms: 10,
      });
    }).not.toThrow();
  });

  it("flag key matches the api middleware string", () => {
    expect(MAJOR_FEATURE_FLAGS.KV_IMAGE_EXPAND).toBe("show-kv-image-expand");
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web && bun test src/lib/analytics/kvImageExpandEvents.test.ts`
Expected: FAIL — exports missing

- [ ] **Step 3: Write flag, events, hook; lift the Resize hook**

In `constants.ts`, after `KV_BG_REMOVAL: "show-kv-bg-removal",`:

```ts
  // KV Expand Image — "Expand image" on image layers (Layers-panel row menu
  // + Craft/Resize canvas right-click). Fail-CLOSED like bg-removal. The api
  // gates its routes on THIS SAME KEY (`feature.flag:show-kv-image-expand,off`).
  // ai-service needs OPENAI_API_KEY (gpt-image-2) before flipping this on.
  KV_IMAGE_EXPAND: "show-kv-image-expand",
```

In `kv-generator-events.ts`, after `trackKvBgRemovalFailed`:

```ts
/** Which surface opened the Expand-image dialog. Resize gets its own value
 *  (unlike bg-removal, which reuses "canvas") because its apply path commits
 *  to a tile snapshot, not the doc — a different failure surface. */
export type KvImageExpandSource = "canvas" | "layers_panel" | "resize_canvas";

/** "custom" = the user dragged the frame after (or instead of) a preset. */
export type KvImageExpandPresetProp =
  | "original"
  | "square"
  | "portrait"
  | "landscape"
  | "custom";

export interface KvImageExpandOpenedProps {
  overlay_id: string;
  source: KvImageExpandSource;
}

export const trackKvImageExpandOpened = (p: KvImageExpandOpenedProps) =>
  safeCapture("kv_generator.image_expand_opened", p);

export interface KvImageExpandRunProps {
  overlay_id: string;
  source: KvImageExpandSource;
  preset: KvImageExpandPresetProp;
  canvas_w: number;
  canvas_h: number;
  source_w: number;
  source_h: number;
}

export const trackKvImageExpandRun = (p: KvImageExpandRunProps) =>
  safeCapture("kv_generator.image_expand_run", p);

export interface KvImageExpandAppliedProps {
  overlay_id: string;
  source: KvImageExpandSource;
  preset: KvImageExpandPresetProp;
  canvas_w: number;
  canvas_h: number;
  duration_ms: number;
  model_version: string | null;
}

export const trackKvImageExpandApplied = (p: KvImageExpandAppliedProps) =>
  safeCapture("kv_generator.image_expand_applied", p);

export interface KvImageExpandFailedProps {
  overlay_id: string;
  source: KvImageExpandSource;
  error_reason: string;
  duration_ms: number;
}

export const trackKvImageExpandFailed = (p: KvImageExpandFailedProps) =>
  safeCapture("kv_generator.image_expand_failed", p);
```

```ts
// web/src/lib/studio/kv/useGptImageCreditEstimate.ts
"use client";

import { useQuery } from "@tanstack/react-query";
import { getImageModels } from "@/services/query";
import type { ImageModel } from "@/types/response";

/** Resize exports AND Expand image render server-side with this model
 *  (outpaint / reframe in ai-service). */
export const GPT_IMAGE_RENDER_MODEL = "gpt-image-2";

/** Flat per-run estimate from the image-models endpoint × `count`. Null while
 *  loading or when the model row is missing/inactive — callers omit the line.
 *  Lifted from KvResizePanel so the Expand-image modal shows the same figure
 *  the user already sees on Resize for the same model. */
export function useGptImageCreditEstimate(count: number): number | null {
  const { data } = useQuery({
    queryKey: ["image-models"],
    queryFn: getImageModels,
    staleTime: 1000 * 60 * 10,
    enabled: count > 0,
  });
  const model = (data?.data ?? []).find(
    (m: ImageModel) => m.value === GPT_IMAGE_RENDER_MODEL && m.is_active
  );
  const per = model?.estimated_credits ?? null;
  return per != null && count > 0 ? per * count : null;
}
```

In `KvResizePanel.tsx`: delete lines 32–47 (`RESIZE_RENDER_MODEL` const + `useResizeCreditEstimate` function) and the now-unused imports `useQuery`, `getImageModels`, `ImageModel`; add `import { useGptImageCreditEstimate } from "@/lib/studio/kv/useGptImageCreditEstimate";` and replace the call site `useResizeCreditEstimate(` with `useGptImageCreditEstimate(`. (`grep -n useResizeCreditEstimate` to find it — one call.)

- [ ] **Step 4: Run the test + the Resize panel tests**

Run: `cd web && bun test src/lib/analytics/kvImageExpandEvents.test.ts && ls src/components/studio/kv-generator/KvResizePanel*.test.tsx 2>/dev/null && bun test src/components/studio/kv-generator/KvResizePanel.test.tsx`
Expected: PASS; if no `KvResizePanel.test.tsx` exists, the `ls` prints nothing and that's fine.

- [ ] **Step 5: Commit**

```bash
git add src/lib/featureFlags/constants.ts src/lib/analytics/kv-generator-events.ts src/lib/analytics/kvImageExpandEvents.test.ts src/lib/studio/kv/useGptImageCreditEstimate.ts src/components/studio/kv-generator/KvResizePanel.tsx
git commit -m "feat(web): kv image expand flag, analytics events, shared gpt-image estimate hook

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: `ExpandBoundsEditor`

**Files:**
- Create: `web/src/components/studio/kv-generator/ExpandBoundsEditor.tsx`
- Test: `web/src/components/studio/kv-generator/ExpandBoundsEditor.test.tsx`

**Interfaces:**
- Consumes: `applyHandleDrag`, `applyImageDrag`, `ExpandHandle` (Task 2).
- Produces:
  ```ts
  type Props = {
    sourceUrl: string; sourceW: number; sourceH: number;
    placement: KvExpandPlacement;
    onChange: (next: KvExpandPlacement) => void;   // fired on pointer-up (one undo step per gesture)
    onPreview?: (next: KvExpandPlacement) => void; // fired on every pointer-move
    disabled?: boolean;
    resultUrl?: string | null;                       // set ⇒ read-only result view
  };
  ```
  Root has `data-testid="expand-bounds-editor"`, `data-canvas-w`, `data-canvas-h`, `data-image-x`, `data-image-y`. Handles have `data-handle="<ExpandHandle>"`. The image has `data-testid="expand-source"`.

- [ ] **Step 1: Write the failing test**

```tsx
// web/src/components/studio/kv-generator/ExpandBoundsEditor.test.tsx
import { describe, expect, it } from "bun:test";
import type { ComponentProps } from "react";
import { fireEvent, render, within } from "@testing-library/react";
import { ExpandBoundsEditor, STAGE_H, STAGE_MARGIN, STAGE_W } from "./ExpandBoundsEditor";

const P = { canvas_w: 640, canvas_h: 360, image_x: 120, image_y: 30 };
/** Display scale the component uses for P — the canvas is fitted inside the
 *  stage minus the handle margin. A 50px screen drag is 50/S source px. */
const S = Math.min((STAGE_W - 2 * STAGE_MARGIN) / 640, (STAGE_H - 2 * STAGE_MARGIN) / 360);

function setup(extra: Partial<ComponentProps<typeof ExpandBoundsEditor>> = {}) {
  const changes: unknown[] = [];
  const previews: unknown[] = [];
  render(
    <ExpandBoundsEditor
      sourceUrl="https://s3.test/src.png"
      sourceW={400}
      sourceH={300}
      placement={P}
      onChange={(p) => changes.push(p)}
      onPreview={(p) => previews.push(p)}
      {...extra}
    />
  );
  const body = within(document.body);
  return { body, changes, previews, root: body.getByTestId("expand-bounds-editor") };
}

describe("ExpandBoundsEditor", () => {
  it("exposes the placement on the root", () => {
    const { root } = setup();
    expect(root.getAttribute("data-canvas-w")).toBe("640");
    expect(root.getAttribute("data-image-y")).toBe("30");
  });

  it("dragging the east handle grows the canvas and commits once on pointer-up", () => {
    const { root, changes, previews } = setup();
    const handle = root.querySelector('[data-handle="e"]') as HTMLElement;
    fireEvent.pointerDown(handle, { clientX: 100, clientY: 100, pointerId: 1 });
    fireEvent.pointerMove(handle, { clientX: 100 + 50, clientY: 100, pointerId: 1 });
    fireEvent.pointerUp(handle, { clientX: 100 + 50, clientY: 100, pointerId: 1 });

    expect(previews.length).toBe(1);
    expect(changes.length).toBe(1);
    const next = changes[0] as typeof P;
    expect(next.canvas_w).toBe(Math.round(640 + 50 / S));
    expect(next.canvas_h).toBe(360);
    expect(next.image_x).toBe(120);
  });

  it("dragging the west handle left grows the canvas and shifts image_x equally", () => {
    const { root, changes } = setup();
    const handle = root.querySelector('[data-handle="w"]') as HTMLElement;
    fireEvent.pointerDown(handle, { clientX: 100, clientY: 100, pointerId: 1 });
    fireEvent.pointerMove(handle, { clientX: 100 - 40, clientY: 100, pointerId: 1 });
    fireEvent.pointerUp(handle, { clientX: 100 - 40, clientY: 100, pointerId: 1 });

    const next = changes[0] as typeof P;
    const d = Math.round(40 / S);
    expect(next.canvas_w).toBe(640 + d);
    expect(next.image_x).toBe(120 + d);
  });

  it("dragging the image moves it inside the canvas", () => {
    const { body, changes } = setup();
    const img = body.getByTestId("expand-source");
    fireEvent.pointerDown(img, { clientX: 0, clientY: 0, pointerId: 1 });
    fireEvent.pointerMove(img, { clientX: 20, clientY: -10, pointerId: 1 });
    fireEvent.pointerUp(img, { clientX: 20, clientY: -10, pointerId: 1 });

    const next = changes[0] as typeof P;
    expect(next.image_x).toBe(120 + Math.round(20 / S));
    expect(next.image_y).toBe(30 - Math.round(10 / S));
    expect(next.canvas_w).toBe(640);
  });

  it("ignores gestures when disabled", () => {
    const { root, changes } = setup({ disabled: true });
    const handle = root.querySelector('[data-handle="e"]') as HTMLElement;
    fireEvent.pointerDown(handle, { clientX: 0, clientY: 0, pointerId: 1 });
    fireEvent.pointerMove(handle, { clientX: 50, clientY: 0, pointerId: 1 });
    fireEvent.pointerUp(handle, { clientX: 50, clientY: 0, pointerId: 1 });
    expect(changes.length).toBe(0);
  });

  it("shows the result read-only when resultUrl is set", () => {
    const { root, body } = setup({ resultUrl: "https://cdn.test/out.png" });
    expect(root.querySelectorAll("[data-handle]").length).toBe(0);
    expect(body.getByTestId("expand-result").getAttribute("src")).toBe("https://cdn.test/out.png");
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/ExpandBoundsEditor.test.tsx`
Expected: FAIL — module not found

- [ ] **Step 3: Write the component**

```tsx
// web/src/components/studio/kv-generator/ExpandBoundsEditor.tsx
"use client";

import { useRef } from "react";
import clsx from "clsx";
import {
  applyHandleDrag,
  applyImageDrag,
  type ExpandHandle,
} from "@/lib/studio/kv/expandPlacement";
import type { KvExpandPlacement } from "@/types/kv/imageExpand";

/** Fixed stage in CSS px; the canvas is fitted inside with a margin so the
 *  handles have room. Exported for the tests' screen→source conversion. */
export const STAGE_W = 720;
export const STAGE_H = 480;
export const STAGE_MARGIN = 24;

const HANDLES: ExpandHandle[] = ["n", "s", "e", "w", "ne", "nw", "se", "sw"];

const HANDLE_POS: Record<ExpandHandle, string> = {
  n: "left-1/2 top-0 -translate-x-1/2 -translate-y-1/2 cursor-ns-resize",
  s: "left-1/2 bottom-0 -translate-x-1/2 translate-y-1/2 cursor-ns-resize",
  e: "right-0 top-1/2 translate-x-1/2 -translate-y-1/2 cursor-ew-resize",
  w: "left-0 top-1/2 -translate-x-1/2 -translate-y-1/2 cursor-ew-resize",
  ne: "right-0 top-0 translate-x-1/2 -translate-y-1/2 cursor-nesw-resize",
  nw: "left-0 top-0 -translate-x-1/2 -translate-y-1/2 cursor-nwse-resize",
  se: "right-0 bottom-0 translate-x-1/2 translate-y-1/2 cursor-nwse-resize",
  sw: "left-0 bottom-0 -translate-x-1/2 translate-y-1/2 cursor-nesw-resize",
};

type Props = {
  sourceUrl: string;
  sourceW: number;
  sourceH: number;
  placement: KvExpandPlacement;
  /** Committed once per gesture (pointer-up) — one undo step. */
  onChange: (next: KvExpandPlacement) => void;
  /** Every pointer-move, for live rendering. Optional. */
  onPreview?: (next: KvExpandPlacement) => void;
  disabled?: boolean;
  /** When set, the editor shows the expanded result (read-only) in place of
   *  the source, with the frame outline where the source sat. */
  resultUrl?: string | null;
};

/** `scale` is captured at pointer-down: the frame is re-fitted to the stage
 *  on every preview, so reading the live scale mid-gesture would make the
 *  drag non-linear (the handle would run away from the cursor). */
type Gesture =
  | { kind: "handle"; handle: ExpandHandle; startX: number; startY: number; start: KvExpandPlacement; scale: number }
  | { kind: "image"; startX: number; startY: number; start: KvExpandPlacement; scale: number };

/**
 * Drag-frame bounds editor for "Expand image". Plain DOM + pointer events —
 * NOT Fabric/Konva: this is a dialog-sized preview, not the canvas. All maths
 * is in `expandPlacement.ts`; this component only converts screen px to source
 * px (`/ scale`) and owns the pointer capture.
 */
export function ExpandBoundsEditor({
  sourceUrl,
  sourceW,
  sourceH,
  placement,
  onChange,
  onPreview,
  disabled = false,
  resultUrl = null,
}: Props) {
  const gesture = useRef<Gesture | null>(null);

  const scale = Math.min(
    (STAGE_W - STAGE_MARGIN * 2) / placement.canvas_w,
    (STAGE_H - STAGE_MARGIN * 2) / placement.canvas_h
  );
  const frameW = placement.canvas_w * scale;
  const frameH = placement.canvas_h * scale;

  const compute = (g: Gesture, clientX: number, clientY: number): KvExpandPlacement => {
    const dx = (clientX - g.startX) / g.scale;
    const dy = (clientY - g.startY) / g.scale;
    return g.kind === "handle"
      ? applyHandleDrag(g.start, g.handle, dx, dy, sourceW, sourceH)
      : applyImageDrag(g.start, dx, dy, sourceW, sourceH);
  };

  const begin = (e: React.PointerEvent, g: Omit<Gesture, "scale">) => {
    if (disabled || resultUrl) return;
    e.preventDefault();
    gesture.current = { ...g, scale } as Gesture;
    (e.currentTarget as HTMLElement).setPointerCapture?.(e.pointerId);
  };
  const move = (e: React.PointerEvent) => {
    const g = gesture.current;
    if (!g) return;
    onPreview?.(compute(g, e.clientX, e.clientY));
  };
  const end = (e: React.PointerEvent) => {
    const g = gesture.current;
    if (!g) return;
    gesture.current = null;
    (e.currentTarget as HTMLElement).releasePointerCapture?.(e.pointerId);
    onChange(compute(g, e.clientX, e.clientY));
  };

  const readOnly = disabled || !!resultUrl;

  return (
    <div
      data-testid="expand-bounds-editor"
      data-canvas-w={placement.canvas_w}
      data-canvas-h={placement.canvas_h}
      data-image-x={placement.image_x}
      data-image-y={placement.image_y}
      className="relative flex items-center justify-center overflow-hidden rounded-xl bg-white/[0.04]"
      style={{ width: STAGE_W, height: STAGE_H }}
    >
      {/* Frame = the output canvas. Checker background so new (transparent
          until filled) area reads as "to be painted". */}
      <div
        className={clsx(
          "relative border",
          readOnly ? "border-white/20" : "border-white/60"
        )}
        style={{
          width: frameW,
          height: frameH,
          backgroundImage:
            "linear-gradient(45deg, rgba(255,255,255,0.08) 25%, transparent 25%, transparent 75%, rgba(255,255,255,0.08) 75%), linear-gradient(45deg, rgba(255,255,255,0.08) 25%, transparent 25%, transparent 75%, rgba(255,255,255,0.08) 75%)",
          backgroundSize: "16px 16px",
          backgroundPosition: "0 0, 8px 8px",
        }}
      >
        {resultUrl ? (
          <img
            data-testid="expand-result"
            src={resultUrl}
            alt="Expanded result"
            draggable={false}
            className="absolute inset-0 h-full w-full select-none"
          />
        ) : null}

        {/* Source image at its placement. In result view it is replaced by a
            dashed outline so the user can see where the original sat. */}
        {resultUrl ? (
          <div
            className="absolute border border-dashed border-white/50"
            style={{
              left: placement.image_x * scale,
              top: placement.image_y * scale,
              width: sourceW * scale,
              height: sourceH * scale,
            }}
          />
        ) : (
          <img
            data-testid="expand-source"
            src={sourceUrl}
            alt="Source"
            draggable={false}
            className={clsx(
              "absolute select-none",
              readOnly ? "cursor-default" : "cursor-move"
            )}
            style={{
              left: placement.image_x * scale,
              top: placement.image_y * scale,
              width: sourceW * scale,
              height: sourceH * scale,
              touchAction: "none",
            }}
            onPointerDown={(e) =>
              begin(e, { kind: "image", startX: e.clientX, startY: e.clientY, start: placement })
            }
            onPointerMove={move}
            onPointerUp={end}
            onPointerCancel={end}
          />
        )}

        {!readOnly &&
          HANDLES.map((h) => (
            <div
              key={h}
              data-handle={h}
              role="presentation"
              className={clsx(
                "absolute h-3 w-3 rounded-full border border-black/40 bg-white shadow",
                HANDLE_POS[h]
              )}
              style={{ touchAction: "none" }}
              onPointerDown={(e) =>
                begin(e, { kind: "handle", handle: h, startX: e.clientX, startY: e.clientY, start: placement })
              }
              onPointerMove={move}
              onPointerUp={end}
              onPointerCancel={end}
            />
          ))}
      </div>
    </div>
  );
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/ExpandBoundsEditor.test.tsx`
Expected: all PASS. If jsdom lacks `setPointerCapture`, the `?.` calls already no-op. If `fireEvent.pointerDown` does not fire React's `onPointerDown` under this jsdom, switch the component to `onMouseDown/onMouseMove/onMouseUp` **and** the tests to `fireEvent.mouseDown/…` — record which in the commit message.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/ExpandBoundsEditor.tsx src/components/studio/kv-generator/ExpandBoundsEditor.test.tsx
git commit -m "feat(web): ExpandBoundsEditor drag-frame for kv image expand

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: `KvExpandImageModal`

**Files:**
- Create: `web/src/components/studio/kv-generator/KvExpandImageModal.tsx`
- Test: `web/src/components/studio/kv-generator/KvExpandImageModal.test.tsx`

**Interfaces:**
- Consumes: Tasks 2–5.
- Produces:
  ```ts
  export type KvExpandApplyResult = {
    imageUrl: string; mimeType: string; placement: KvExpandPlacement;
    sourceW: number; sourceH: number;
  };
  type Props = {
    open: boolean; fileId: string; overlayId: string; sourceImageUrl: string;
    source: KvImageExpandSource;
    estimatedCredits: number | null;   // parent calls useGptImageCreditEstimate(1)
    onClose: () => void;
    onApply: (result: KvExpandApplyResult) => void;
    api?: ImageExpandApi;              // tests inject; defaults to realImageExpandApi
    pollOpts?: { intervalMs?: number; maxAttempts?: number; sleep?: (ms: number) => Promise<void> };
  };
  ```

- [ ] **Step 1: Write the failing test**

```tsx
// web/src/components/studio/kv-generator/KvExpandImageModal.test.tsx
import { describe, expect, it } from "bun:test";
import { act, fireEvent, render, waitFor, within } from "@testing-library/react";
import type { KvImageExpand } from "@/types/kv/imageExpand";
import type { ImageExpandApi } from "./imageExpand";
import { KvExpandImageModal } from "./KvExpandImageModal";

const row = (status: KvImageExpand["status"], extra: Partial<KvImageExpand> = {}): KvImageExpand => ({
  id: "e1", studioFileId: "f1", sourceImageUrl: "s", sourceW: 400, sourceH: 300,
  placement: { canvas_w: 640, canvas_h: 360, image_x: 120, image_y: 30 },
  imageUrl: null, width: null, height: null, modelVersion: null,
  status, errorMessage: null, createdAt: "", updatedAt: "", ...extra,
});

function loadSource(body: ReturnType<typeof within>, w = 400, h = 300) {
  const img = body.getByTestId("expand-source") as HTMLImageElement;
  Object.defineProperty(img, "naturalWidth", { value: w, configurable: true });
  Object.defineProperty(img, "naturalHeight", { value: h, configurable: true });
  fireEvent.load(img);
}

function setup(api: Partial<ImageExpandApi> = {}, extra: Record<string, unknown> = {}) {
  const applied: unknown[] = [];
  const fullApi: ImageExpandApi = {
    create: async () => row("pending"),
    get: async () => row("done", { imageUrl: "https://cdn.test/out.png", modelVersion: "gpt-image-2" }),
    ...api,
  };
  render(
    <KvExpandImageModal
      open
      fileId="f1"
      overlayId="o1"
      sourceImageUrl="https://s3.test/src.png"
      source="canvas"
      estimatedCredits={3}
      onClose={() => {}}
      onApply={(r) => applied.push(r)}
      api={fullApi}
      pollOpts={{ sleep: async () => {} }}
      {...extra}
    />
  );
  return { body: within(document.body), applied };
}

describe("KvExpandImageModal", () => {
  it("starts on Original with Run disabled, enables Run after a preset", () => {
    const { body } = setup();
    loadSource(body);
    const run = body.getByRole("button", { name: /^Expand image$/ });
    expect(run).toBeDisabled();

    fireEvent.click(body.getByRole("button", { name: /Landscape 16:9/ }));
    const editor = body.getByTestId("expand-bounds-editor");
    expect(editor.getAttribute("data-canvas-w")).toBe("534");
    expect(editor.getAttribute("data-image-x")).toBe("67");
    expect(run).not.toBeDisabled();
  });

  it("shows the estimate line", () => {
    const { body } = setup();
    expect(body.getByText(/Estimated cost: ~3 credits/)).toBeTruthy();
  });

  it("runs, shows the result and applies placement + source size", async () => {
    const created: unknown[] = [];
    const { body, applied } = setup({
      create: async (_fileId, args) => { created.push(args); return row("pending"); },
    });
    loadSource(body);
    fireEvent.click(body.getByRole("button", { name: /Square 1:1/ }));
    await act(async () => { fireEvent.click(body.getByRole("button", { name: /^Expand image$/ })); });

    await waitFor(() => expect(body.getByTestId("expand-result")).toBeTruthy());
    expect(created).toEqual([{
      sourceImageUrl: "https://s3.test/src.png", sourceW: 400, sourceH: 300,
      placement: { canvas_w: 400, canvas_h: 400, image_x: 0, image_y: 50 },
    }]);

    fireEvent.click(body.getByRole("button", { name: /Apply changes/ }));
    expect(applied).toEqual([{
      imageUrl: "https://cdn.test/out.png", mimeType: "image/png",
      placement: { canvas_w: 400, canvas_h: 400, image_x: 0, image_y: 50 },
      sourceW: 400, sourceH: 300,
    }]);
  });

  it("surfaces the api's start error and offers Try again", async () => {
    const { body } = setup({
      create: async () => { throw { response: { data: { message: "Expand image quota reached, try again in 12m" } } }; },
    });
    loadSource(body);
    fireEvent.click(body.getByRole("button", { name: /Square 1:1/ }));
    await act(async () => { fireEvent.click(body.getByRole("button", { name: /^Expand image$/ })); });

    await waitFor(() => expect(body.getByText(/quota reached, try again in 12m/)).toBeTruthy());
    expect(body.getByRole("button", { name: /Try again/ })).toBeTruthy();
  });

  it("surfaces a failed job's error_message", async () => {
    const { body } = setup({ get: async () => row("failed", { errorMessage: "Source image is 401x300, expected 400x300" }) });
    loadSource(body);
    fireEvent.click(body.getByRole("button", { name: /Square 1:1/ }));
    await act(async () => { fireEvent.click(body.getByRole("button", { name: /^Expand image$/ })); });
    await waitFor(() => expect(body.getByText(/expected 400x300/)).toBeTruthy());
  });

  it("disables presets and Run when the source exceeds 4096", () => {
    const { body } = setup();
    loadSource(body, 5000, 300);
    expect(body.getByText(/too large to expand/)).toBeTruthy();
    expect(body.getByRole("button", { name: /Square 1:1/ })).toBeDisabled();
    expect(body.getByRole("button", { name: /^Expand image$/ })).toBeDisabled();
  });

  it("disables a preset that would exceed the cap", () => {
    const { body } = setup();
    loadSource(body, 3000, 2000); // portrait → 3000×5334
    expect(body.getByRole("button", { name: /Portrait 9:16/ })).toBeDisabled();
    expect(body.getByRole("button", { name: /Landscape 16:9/ })).not.toBeDisabled();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/KvExpandImageModal.test.tsx`
Expected: FAIL — module not found

- [ ] **Step 3: Write the modal**

```tsx
// web/src/components/studio/kv-generator/KvExpandImageModal.tsx
"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { ArrowUUpLeft, ArrowUUpRight, Sparkle } from "@phosphor-icons/react";
import clsx from "clsx";
import BaseModal from "@/components/frndos/BaseModal";
import Button from "@/components/frndos/Button";
import {
  trackKvImageExpandApplied,
  trackKvImageExpandFailed,
  trackKvImageExpandOpened,
  trackKvImageExpandRun,
  type KvImageExpandPresetProp,
  type KvImageExpandSource,
} from "@/lib/analytics/kv-generator-events";
import {
  computePresetPlacement,
  EXPAND_PRESETS,
  isExpandable,
  MAX_CANVAS_EDGE,
  presetExceedsCap,
  sourceExceedsCap,
  type KvExpandPreset,
} from "@/lib/studio/kv/expandPlacement";
import type { KvExpandPlacement } from "@/types/kv/imageExpand";
import { ExpandBoundsEditor } from "./ExpandBoundsEditor";
import {
  extractImageExpandErrorMessage,
  pollImageExpand,
  realImageExpandApi,
  startImageExpand,
  type ImageExpandApi,
} from "./imageExpand";

export type KvExpandApplyResult = {
  imageUrl: string;
  mimeType: string;
  placement: KvExpandPlacement;
  sourceW: number;
  sourceH: number;
};

type Phase =
  | { kind: "idle" }
  | { kind: "running" }
  | { kind: "ready"; imageUrl: string; modelVersion: string | null }
  | { kind: "failed"; message: string };

type Props = {
  open: boolean;
  fileId: string;
  overlayId: string;
  sourceImageUrl: string;
  source: KvImageExpandSource;
  /** From `useGptImageCreditEstimate(1)` in the parent; null hides the line. */
  estimatedCredits: number | null;
  onClose: () => void;
  onApply: (result: KvExpandApplyResult) => void;
  /** Injected in tests; defaults to the real network client. */
  api?: ImageExpandApi;
  pollOpts?: { intervalMs?: number; maxAttempts?: number; sleep?: (ms: number) => Promise<void> };
};

/**
 * "Expand image" dialog for one image overlay (spec §4.1). Presets on the
 * left, drag-frame editor on the right, run → result → Apply. The parent
 * turns the result into a geometry+payload patch via `buildExpandApplyPatch`.
 *
 * Components: v1 throughout (BaseModal / Button), same reasoning as
 * KvRemoveBackgroundModal — v2 has no dialog primitive.
 */
export function KvExpandImageModal({
  open,
  fileId,
  overlayId,
  sourceImageUrl,
  source,
  estimatedCredits,
  onClose,
  onApply,
  api = realImageExpandApi,
  pollOpts,
}: Props) {
  const [phase, setPhase] = useState<Phase>({ kind: "idle" });
  const [natural, setNatural] = useState<{ w: number; h: number } | null>(null);
  const [placement, setPlacement] = useState<KvExpandPlacement | null>(null);
  const [preview, setPreview] = useState<KvExpandPlacement | null>(null);
  const [preset, setPreset] = useState<KvExpandPreset | "custom">("original");
  // Undo/redo of committed placements (one entry per gesture / preset click).
  const [history, setHistory] = useState<{ past: KvExpandPlacement[]; future: KvExpandPlacement[] }>({
    past: [],
    future: [],
  });
  const cancelledRef = useRef(false);
  const runStartedAtRef = useRef<number | null>(null);

  useEffect(() => {
    if (!open) return;
    cancelledRef.current = false;
    setPhase({ kind: "idle" });
    setNatural(null);
    setPlacement(null);
    setPreview(null);
    setPreset("original");
    setHistory({ past: [], future: [] });
    trackKvImageExpandOpened({ overlay_id: overlayId, source });
    return () => {
      cancelledRef.current = true;
    };
  }, [open, overlayId, source]);

  const tooLarge = natural ? sourceExceedsCap(natural.w, natural.h) : false;

  const commit = useCallback(
    (next: KvExpandPlacement, nextPreset: KvExpandPreset | "custom") => {
      setHistory((h) => ({ past: placement ? [...h.past, placement] : h.past, future: [] })); // pure: no setState inside
      setPlacement(next);
      setPreview(null);
      setPreset(nextPreset);
      // Editing after a result discards it — the result was for the old frame.
      setPhase((p) => (p.kind === "ready" ? { kind: "idle" } : p));
    },
    [placement]
  );

  const onSourceLoad = (e: React.SyntheticEvent<HTMLImageElement>) => {
    const img = e.currentTarget;
    const w = img.naturalWidth;
    const h = img.naturalHeight;
    if (!(w > 0 && h > 0)) return;
    setNatural({ w, h });
    setPlacement(computePresetPlacement(w, h, "original"));
  };

  // Undo/redo read `history` + `placement` from the render closure and issue
  // plain setState calls — no side effects inside an updater (StrictMode
  // double-invokes updaters, which would apply the step twice).
  const undo = () => {
    if (!history.past.length || !placement) return;
    const prev = history.past[history.past.length - 1];
    setHistory({ past: history.past.slice(0, -1), future: [placement, ...history.future] });
    setPlacement(prev);
    setPreview(null);
    setPreset("custom");
    setPhase((p) => (p.kind === "ready" ? { kind: "idle" } : p));
  };
  const redo = () => {
    if (!history.future.length || !placement) return;
    const [next, ...rest] = history.future;
    setHistory({ past: [...history.past, placement], future: rest });
    setPlacement(next);
    setPreview(null);
    setPreset("custom");
    setPhase((p) => (p.kind === "ready" ? { kind: "idle" } : p));
  };

  const running = phase.kind === "running";
  const ready = phase.kind === "ready";
  const shown = preview ?? placement;
  const canRun =
    !!natural && !!placement && !tooLarge && !running && isExpandable(placement, natural.w, natural.h);

  const presetProp: KvImageExpandPresetProp = preset;

  const handleRun = useCallback(async () => {
    if (!natural || !placement) return;
    setPhase({ kind: "running" });
    runStartedAtRef.current = Date.now();
    const durationMs = () => (runStartedAtRef.current ? Date.now() - runStartedAtRef.current : 0);
    trackKvImageExpandRun({
      overlay_id: overlayId,
      source,
      preset: presetProp,
      canvas_w: placement.canvas_w,
      canvas_h: placement.canvas_h,
      source_w: natural.w,
      source_h: natural.h,
    });

    const started = await startImageExpand(
      { fileId, sourceImageUrl, sourceW: natural.w, sourceH: natural.h, placement },
      api
    );
    if (!started.ok) {
      setPhase({ kind: "failed", message: started.message });
      trackKvImageExpandFailed({ overlay_id: overlayId, source, error_reason: "start_failed", duration_ms: durationMs() });
      return;
    }

    try {
      const row = await pollImageExpand(
        fileId,
        started.row.id,
        { ...pollOpts, isCancelled: () => cancelledRef.current },
        api
      );
      if (cancelledRef.current) return;
      if (row.status === "done" && row.imageUrl) {
        setPhase({ kind: "ready", imageUrl: row.imageUrl, modelVersion: row.modelVersion });
      } else if (row.status === "failed") {
        const message = row.errorMessage ?? "Expand failed. Try again.";
        setPhase({ kind: "failed", message });
        trackKvImageExpandFailed({ overlay_id: overlayId, source, error_reason: row.errorMessage ?? "job_failed", duration_ms: durationMs() });
      } else {
        setPhase({ kind: "failed", message: "This is taking longer than expected. Try again." });
        trackKvImageExpandFailed({ overlay_id: overlayId, source, error_reason: "poll_timeout", duration_ms: durationMs() });
      }
    } catch (err) {
      if (cancelledRef.current) return;
      console.error("[kv] image expand poll failed", err);
      setPhase({
        kind: "failed",
        message: extractImageExpandErrorMessage(
          err,
          "Couldn't check the expand status. Try again.",
          "Checking the expand status took too long. Try again."
        ),
      });
      trackKvImageExpandFailed({ overlay_id: overlayId, source, error_reason: "poll_error", duration_ms: durationMs() });
    }
  }, [natural, placement, overlayId, source, presetProp, fileId, sourceImageUrl, api, pollOpts]);

  const handleApply = useCallback(() => {
    if (phase.kind !== "ready" || !natural || !placement) return;
    trackKvImageExpandApplied({
      overlay_id: overlayId,
      source,
      preset: presetProp,
      canvas_w: placement.canvas_w,
      canvas_h: placement.canvas_h,
      duration_ms: runStartedAtRef.current ? Date.now() - runStartedAtRef.current : 0,
      model_version: phase.modelVersion,
    });
    onApply({
      imageUrl: phase.imageUrl,
      mimeType: "image/png",
      placement,
      sourceW: natural.w,
      sourceH: natural.h,
    });
  }, [phase, natural, placement, overlayId, source, presetProp, onApply]);

  const presetButtons = useMemo(
    () =>
      EXPAND_PRESETS.map((p) => {
        const exceeds = natural ? presetExceedsCap(natural.w, natural.h, p.key) : false;
        const disabled = !natural || tooLarge || running || exceeds;
        return (
          <button
            key={p.key}
            type="button"
            disabled={disabled}
            title={exceeds ? `Exceeds ${MAX_CANVAS_EDGE} px` : undefined}
            className={clsx(
              "w-full rounded-lg px-3 py-2 text-left font-funnel text-textSmMedium transition-colors",
              preset === p.key ? "bg-white/10 text-white" : "text-white/70 hover:bg-white/5 hover:text-white",
              disabled && "cursor-not-allowed opacity-40"
            )}
            onClick={() => natural && commit(computePresetPlacement(natural.w, natural.h, p.key), p.key)}
          >
            {p.label}
          </button>
        );
      }),
    [natural, tooLarge, running, preset, commit]
  );

  return (
    <BaseModal
      isOpen={open}
      onClose={onClose}
      title="Expand image"
      align="left"
      contentClassName="w-[1080px] max-w-[calc(100vw-32px)]"
      preventCloseOnOverlayClick={running}
      footer={
        <div className="flex items-center justify-end gap-2 border-t border-white/10 px-6 py-4">
          <Button variant="secondary" size="medium" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="primary" size="medium" disabled={!ready} onClick={handleApply}>
            Apply changes
          </Button>
        </div>
      }
    >
      <div className="flex gap-6 px-6 py-4">
        <div className="flex w-[280px] shrink-0 flex-col gap-3">
          <p className="font-geist text-textSm text-white/70">
            Expand your image by resizing the frame outside the image and placing the image where you
            want it inside the new canvas.
          </p>
          <div className="flex flex-col gap-1">{presetButtons}</div>
          <Button
            variant="primary"
            size="medium"
            disabled={!canRun}
            onClick={handleRun}
          >
            <Sparkle size={14} className="mr-1.5" />
            {running ? "Expanding…" : phase.kind === "failed" ? "Try again" : "Expand image"}
          </Button>
          {estimatedCredits != null && (
            <span className="font-geist text-textXs text-text-inverse-subtlest">
              Estimated cost: ~{estimatedCredits} credits
            </span>
          )}
          {tooLarge && natural && (
            <p role="alert" className="font-geist text-textXs text-red-400">
              This image is {natural.w}×{natural.h} — too large to expand (max {MAX_CANVAS_EDGE} px per side).
            </p>
          )}
          {phase.kind === "failed" && (
            <p role="alert" className="font-geist text-textXs text-red-400">
              {phase.message}
            </p>
          )}
        </div>

        <div className="relative flex flex-1 flex-col gap-2">
          <div className="flex gap-1">
            <button
              type="button"
              aria-label="Undo"
              disabled={!history.past.length || running}
              className="rounded-md p-1.5 text-white/70 hover:bg-white/10 disabled:opacity-40"
              onClick={undo}
            >
              <ArrowUUpLeft size={16} />
            </button>
            <button
              type="button"
              aria-label="Redo"
              disabled={!history.future.length || running}
              className="rounded-md p-1.5 text-white/70 hover:bg-white/10 disabled:opacity-40"
              onClick={redo}
            >
              <ArrowUUpRight size={16} />
            </button>
          </div>

          {/* Hidden probe: the editor renders its own <img>, but the placement
              can't exist until the natural size is known, so measure here. */}
          {!natural && (
            <img
              data-testid="expand-source"
              src={sourceImageUrl}
              alt="Source"
              className="absolute h-0 w-0 opacity-0"
              onLoad={onSourceLoad}
            />
          )}

          {natural && shown ? (
            <ExpandBoundsEditor
              sourceUrl={sourceImageUrl}
              sourceW={natural.w}
              sourceH={natural.h}
              placement={shown}
              onPreview={setPreview}
              onChange={(next) => commit(next, "custom")}
              disabled={running || tooLarge}
              resultUrl={ready ? phase.imageUrl : null}
            />
          ) : (
            <div className="flex h-[480px] w-[720px] items-center justify-center font-geist text-textSm text-white/50">
              Loading image…
            </div>
          )}
        </div>
      </div>
    </BaseModal>
  );
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/KvExpandImageModal.test.tsx`
Expected: all PASS. Known snags:
- `loadSource` finds the **probe** `<img data-testid="expand-source">` first; after load the editor renders its own `expand-source`. That's intended — the helper fires load on whichever exists at call time (the probe).
- If Radix's `BaseModal` needs `open` to be re-rendered before content mounts, add `await act(async () => {})` after `render` in `setup`.
- Two `role="alert"` elements can coexist (too-large + failed) — the tests query by text, not role.

- [ ] **Step 5: Mutation check** — change `isExpandable` in `canRun` to `true`; the first test's `expect(run).toBeDisabled()` must fail. Revert.

- [ ] **Step 6: Commit**

```bash
git add src/components/studio/kv-generator/KvExpandImageModal.tsx src/components/studio/kv-generator/KvExpandImageModal.test.tsx
git commit -m "feat(web): KvExpandImageModal (presets, drag frame, run/poll, apply)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Menu entry points (Craft menu, Resize menu, Layers row menu, prop threading)

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvOverlayContextMenu.tsx`
- Modify: `web/src/components/studio/kv-generator/KvResizeOverlayContextMenu.tsx`
- Modify: `web/src/components/studio/kv-generator/layerRowMenu.tsx`
- Modify: `web/src/components/studio/kv-generator/KvLayersPanel.tsx` (prop at ~line 88, destructure ~142, pass-through ~715)
- Modify: `web/src/components/studio/kv-generator/KvFabricCanvas.tsx` (prop type ~355, destructure ~646, `hasMenu` ~3924, right-click gate ~3939, effect deps ~4015, render ~5534)
- Test: `web/src/components/studio/kv-generator/layerRowMenu.test.tsx` (append)
- Test: `web/src/components/studio/kv-generator/KvOverlayContextMenu.test.tsx` (new)

**Interfaces:**
- Produces: `onExpandImage?: (overlayId: string) => void` on `KvOverlayContextMenu`, `KvResizeOverlayContextMenu`, `KvLayersPanel`, `buildLayerRowMenuItems` opts (item key `"expand-image"`, label `"Expand image"`); `onExpandOverlayImage?: (overlayId: string) => void` on `KvFabricCanvas`.

- [ ] **Step 1: Write the failing tests**

Append to `layerRowMenu.test.tsx` inside the `describe`:

```tsx
  it("image overlay with onExpandImage → expand sits after remove-background, before delete", () => {
    const items = buildLayerRowMenuItems(imageOverlay, {
      onReplaceImage: () => {},
      onRemoveBackground: () => {},
      onExpandImage: () => {},
      onRemove: () => {},
    });
    expect(items.map((i) => i.key)).toEqual(["replace", "remove-background", "expand-image", "delete"]);
    expect(items[2].label).toBe("Expand image");
  });

  it("expand onClick calls onExpandImage with the overlay id", () => {
    let called = "";
    const items = buildLayerRowMenuItems(imageOverlay, {
      onExpandImage: (id) => (called = id),
      onRemove: () => {},
    });
    items.find((i) => i.key === "expand-image")!.onClick();
    expect(called).toBe("o1");
  });

  it("text overlay never gets expand-image", () => {
    const items = buildLayerRowMenuItems(textOverlay, {
      onExpandImage: () => {},
      onRemove: () => {},
    });
    expect(items.map((i) => i.key)).toEqual(["delete"]);
  });
```

```tsx
// web/src/components/studio/kv-generator/KvOverlayContextMenu.test.tsx
import { describe, expect, it } from "bun:test";
import { fireEvent, render, within } from "@testing-library/react";
import { KvOverlayContextMenu } from "./KvOverlayContextMenu";
import { KvResizeOverlayContextMenu } from "./KvResizeOverlayContextMenu";

const base = { overlayId: "o1", x: 10, y: 10, bounds: { width: 800, height: 600 }, onClose: () => {} };

describe("KvOverlayContextMenu", () => {
  it("renders Expand image only when onExpandImage is supplied", () => {
    render(<KvOverlayContextMenu {...base} onReplaceImage={() => {}} />);
    expect(within(document.body).queryByText("Expand image")).toBeNull();
  });

  it("calls onExpandImage then closes", () => {
    const calls: string[] = [];
    let closed = 0;
    render(
      <KvOverlayContextMenu
        {...base}
        onClose={() => closed++}
        onExpandImage={(id) => calls.push(id)}
      />
    );
    fireEvent.click(within(document.body).getByText("Expand image"));
    expect(calls).toEqual(["o1"]);
    expect(closed).toBe(1);
  });
});

describe("KvResizeOverlayContextMenu", () => {
  it("renders Expand image only when onExpandImage is supplied, and calls it", () => {
    const calls: string[] = [];
    render(
      <KvResizeOverlayContextMenu
        overlayId="o1"
        x={10}
        y={10}
        onClose={() => {}}
        onExpandImage={(id) => calls.push(id)}
      />
    );
    fireEvent.click(within(document.body).getByText("Expand image"));
    expect(calls).toEqual(["o1"]);
  });
});
```

(Check `KvResizeOverlayContextMenu`'s actual prop list at the top of the file — it has no `bounds` prop; if it requires something else, pass it.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web && bun test src/components/studio/kv-generator/layerRowMenu.test.tsx src/components/studio/kv-generator/KvOverlayContextMenu.test.tsx`
Expected: FAIL — `expand-image` missing / "Expand image" not found

- [ ] **Step 3: Add the entry points**

`KvOverlayContextMenu.tsx` — add to `Props` after `onRemoveBackground`:

```ts
  /** Open the "Expand image" dialog. Absent when the show-kv-image-expand flag
   *  is off — same gating-by-absence convention as onRemoveBackground. */
  onExpandImage?: (overlayId: string) => void;
```

destructure `onExpandImage`, and after the `onRemoveBackground` button add:

```tsx
      {onExpandImage && (
        <button
          type="button"
          className="flex w-full items-center px-3 py-2 text-left font-funnel text-textSmMedium text-white/70 transition-colors hover:bg-white/5 hover:text-white"
          onClick={() => {
            onClose();
            onExpandImage(overlayId);
          }}
        >
          Expand image
        </button>
      )}
```

`KvResizeOverlayContextMenu.tsx` — same prop + button; also change the early return at line ~70 to
`if (!onReplaceImage && !onRemoveBackground && !onExpandImage) return null;`.

`layerRowMenu.tsx` — add `onExpandImage?: (id: string) => void;` to `opts`, import `ArrowsOutSimple` from `@phosphor-icons/react`, and after the `remove-background` push:

```tsx
  if (overlay.payload.type === "image" && opts.onExpandImage) {
    const expand = opts.onExpandImage;
    items.push({
      key: "expand-image",
      label: "Expand image",
      icon: <ArrowsOutSimple size={14} />,
      onClick: () => expand(overlay.id),
    });
  }
```

and extend the docblock with a `- \`Expand image\`` bullet mirroring the remove-background one.

`KvLayersPanel.tsx` — add prop after `onRemoveBackground`:

```ts
  /** Open the "Expand image" dialog for an image overlay. Omitted when the
   *  show-kv-image-expand flag is off (menu item hides itself). */
  onExpandImage?: (id: string) => void;
```

destructure it next to `onRemoveBackground` and pass `onExpandImage,` into `buildLayerRowMenuItems(o, {...})`.

`KvFabricCanvas.tsx` — add prop after `onRemoveOverlayBackground`:

```ts
  /** Open the "Expand image" dialog for an image overlay (right-click on the
   *  layer). Absent when the show-kv-image-expand flag is off. */
  onExpandOverlayImage?: (overlayId: string) => void;
```

destructure it (~646); in the `hasMenu` expression add `|| onExpandOverlayImage`; in the right-click gate change `if (onRemoveOverlayBackground || onReplaceOverlayImage)` to `if (onRemoveOverlayBackground || onReplaceOverlayImage || onExpandOverlayImage)`; add `onExpandOverlayImage,` to that effect's dependency array; and in the `<KvOverlayContextMenu ... />` render add `onExpandImage={onExpandOverlayImage}`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd web && bun test src/components/studio/kv-generator/layerRowMenu.test.tsx src/components/studio/kv-generator/KvOverlayContextMenu.test.tsx`
Expected: all PASS (including the pre-existing row-menu cases)

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/KvOverlayContextMenu.tsx src/components/studio/kv-generator/KvResizeOverlayContextMenu.tsx src/components/studio/kv-generator/layerRowMenu.tsx src/components/studio/kv-generator/KvLayersPanel.tsx src/components/studio/kv-generator/KvFabricCanvas.tsx src/components/studio/kv-generator/layerRowMenu.test.tsx src/components/studio/kv-generator/KvOverlayContextMenu.test.tsx
git commit -m "feat(web): 'Expand image' entry in overlay menus + layers row menu

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: Craft wiring — `KvGeneratorLayout`

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx`
  - imports (~line 179, next to `KvRemoveBackgroundModal`)
  - flag (~line 3482, after `kvBgRemovalEnabled`)
  - handlers (after `handleApplyBackgroundRemoval`, ~line 4930)
  - Fabric canvas props (~line 7171, next to `onRemoveOverlayBackground`)
  - Layers panel props (~line 7564, next to `onRemoveBackground`)
  - modal mount (~line 8142, next to `KvRemoveBackgroundModal`)

**Interfaces:**
- Consumes: `KvExpandImageModal`, `KvExpandApplyResult`, `buildExpandApplyPatch`, `useGptImageCreditEstimate`, `MAJOR_FEATURE_FLAGS.KV_IMAGE_EXPAND`, `KvImageExpandSource`, existing `measuredBoardDims`, `overlays`, `kvDoc`, `update`, `docUpdateOverlay`, `setTransientNotice`, `file`.

- [ ] **Step 1: Add imports**

```ts
import { KvExpandImageModal, type KvExpandApplyResult } from "./KvExpandImageModal";
import { buildExpandApplyPatch } from "@/lib/studio/kv/expandPlacement";
import { useGptImageCreditEstimate } from "@/lib/studio/kv/useGptImageCreditEstimate";
import type { KvImageExpandSource } from "@/lib/analytics/kv-generator-events";
```

(Add `KvImageExpandSource` to the existing `kv-generator-events` import if one exists rather than a duplicate import line.)

- [ ] **Step 2: Add the flag next to `kvBgRemovalEnabled`**

```ts
  // AI Expand-image on image overlays. Same fail-closed resolution and
  // shared api key (`feature.flag:show-kv-image-expand,off`) as bg-removal.
  const kvImageExpandEnabled =
    useExperimentalFeatureEnabled(MAJOR_FEATURE_FLAGS.KV_IMAGE_EXPAND) === true;
  // Flat per-run gpt-image-2 estimate — the same figure Resize shows.
  const imageExpandEstimate = useGptImageCreditEstimate(kvImageExpandEnabled ? 1 : 0);
```

- [ ] **Step 3: Add target state + handlers after `handleApplyBackgroundRemoval`**

```ts
  // AI Expand-image dialog target. Set from the Layers-panel row menu or a
  // canvas right-click on an image layer; null = closed.
  const [expandTarget, setExpandTarget] = useState<{
    overlayId: string;
    sourceImageUrl: string;
    source: KvImageExpandSource;
  } | null>(null);

  const handleRequestExpandImage = useCallback(
    (id: string, source: KvImageExpandSource) => {
      if (!file?.id) {
        setTransientNotice("Couldn't open Expand image. Try again.");
        return;
      }
      const overlay = overlays.find((o) => o.id === id);
      if (!overlay || overlay.payload.type !== "image") return;
      setExpandTarget({ overlayId: id, sourceImageUrl: overlay.payload.asset_url, source });
    },
    [overlays, file?.id, setTransientNotice]
  );

  // Apply from the dialog: ONE patch carrying geometry + payload so the box
  // grows and the image swaps in the same frame, with the original pixels
  // staying exactly where they were (buildExpandApplyPatch). Re-resolves the
  // overlay at apply time — same guard as bg-removal.
  const handleApplyExpand = useCallback(
    (result: KvExpandApplyResult) => {
      const target = expandTarget;
      if (!target) return;
      const live = overlays.find((o) => o.id === target.overlayId);
      if (!live || live.payload.type !== "image") {
        setExpandTarget(null);
        setTransientNotice("That layer changed — expand not applied.");
        return;
      }
      // hostAspect: the ACTIVE board's measured size. Exact for rotation 0 on
      // any board (aspect cancels out); approximate only for a rotated
      // overlay bound to a non-active board.
      const hostAspect =
        measuredBoardDims && measuredBoardDims.height > 0
          ? measuredBoardDims.width / measuredBoardDims.height
          : 1;
      const patch = buildExpandApplyPatch({
        overlay: live,
        placement: result.placement,
        sourceW: result.sourceW,
        sourceH: result.sourceH,
        imageUrl: result.imageUrl,
        mimeType: result.mimeType,
        hostAspect,
      });
      if (kvDoc) docUpdateOverlay(kvDoc, target.overlayId, patch);
      else update(target.overlayId, patch);
      setExpandTarget(null);
    },
    [expandTarget, kvDoc, update, overlays, setTransientNotice, measuredBoardDims]
  );
```

If `measuredBoardDims` is declared **after** this block in the file (it lives near line 3530, the handlers near 4930 — so it is before), fine; otherwise move the handlers below it.

- [ ] **Step 4: Thread props**

Next to `onRemoveOverlayBackground={...}` on `<KvFabricCanvas>`:

```tsx
              onExpandOverlayImage={
                kvImageExpandEnabled
                  ? (id) => handleRequestExpandImage(id, "canvas")
                  : undefined
              }
```

Next to `onRemoveBackground={...}` on `<KvLayersPanel>`:

```tsx
            onExpandImage={
              kvImageExpandEnabled
                ? (id) => handleRequestExpandImage(id, "layers_panel")
                : undefined
            }
```

- [ ] **Step 5: Mount the modal next to `KvRemoveBackgroundModal`**

```tsx
      {expandTarget && file?.id && (
        <KvExpandImageModal
          key={expandTarget.overlayId}
          open
          fileId={file.id}
          overlayId={expandTarget.overlayId}
          sourceImageUrl={expandTarget.sourceImageUrl}
          source={expandTarget.source}
          estimatedCredits={imageExpandEstimate}
          onClose={() => setExpandTarget(null)}
          onApply={handleApplyExpand}
        />
      )}
```

- [ ] **Step 6: Type-check the touched files**

Run: `cd web && bunx tsc --noEmit -p . 2>&1 | grep -E "KvGeneratorLayout|KvExpandImageModal|ExpandBoundsEditor|expandPlacement|imageExpand|KvFabricCanvas|KvLayersPanel|layerRowMenu|OverlayContextMenu" || echo "no new type errors in touched files"`
Expected: `no new type errors in touched files` (the repo has a ~777-error baseline elsewhere; only these names matter).

- [ ] **Step 7: Commit**

```bash
git add src/components/studio/kv-generator/KvGeneratorLayout.tsx
git commit -m "feat(web): wire Expand image into the Craft canvas + layers panel

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 9: Resize wiring — `KvResizeCanvas`

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvResizeCanvas.tsx`
  - import (~line 94)
  - flag (~line 405, after `bgRemovalEnabled`)
  - state + handlers (after `handleApplyBackgroundRemoval`, ~line 2227)
  - context-menu props (~line 2570)
  - layers-panel props (~line 2621)
  - modal mount (~line 2545)

**Interfaces:**
- Consumes: same as Task 8 plus Resize's `activeRowOverlays`, `isMasterActive`, `activeRow`, `projectOverlays`, `commitMasterOverlays`, `baseOverlaysFor`, `commitTileOverlays`, `sourceSize`, `showToast`, `fileId`.

- [ ] **Step 1: Imports + flag**

```ts
import { KvExpandImageModal, type KvExpandApplyResult } from "./KvExpandImageModal";
import { buildExpandApplyPatch } from "@/lib/studio/kv/expandPlacement";
import { useGptImageCreditEstimate } from "@/lib/studio/kv/useGptImageCreditEstimate";
import type { KvImageExpandSource } from "@/lib/analytics/kv-generator-events";
```

after `bgRemovalEnabled`:

```ts
  const imageExpandEnabled =
    useExperimentalFeatureEnabled(MAJOR_FEATURE_FLAGS.KV_IMAGE_EXPAND) === true;
  const imageExpandEstimate = useGptImageCreditEstimate(imageExpandEnabled ? 1 : 0);
```

- [ ] **Step 2: State + handlers after `handleApplyBackgroundRemoval`**

```ts
  // ── AI expand-image ─────────────────────────────────────────────────────
  // Self-contained duplicate of Craft's flow, same split as bg-removal above:
  // Resize tile overlays live in a REST snapshot on the export row, Craft's in
  // the Yjs doc, so the two surfaces commit through different paths.
  const [expandTarget, setExpandTarget] = useState<
    | { row: KvResizeExport; overlayId: string; sourceImageUrl: string; isMaster: false; source: KvImageExpandSource }
    | { row: null; overlayId: string; sourceImageUrl: string; isMaster: true; source: KvImageExpandSource }
    | null
  >(null);

  function handleRequestExpandImage(id: string, source: KvImageExpandSource = "layers_panel") {
    const overlay = activeRowOverlays.find((o) => o.id === id);
    if (!overlay || overlay.payload.type !== "image") return;
    if (isMasterActive) {
      setExpandTarget({ row: null, overlayId: id, sourceImageUrl: overlay.payload.asset_url, isMaster: true, source });
      return;
    }
    if (!activeRow) return;
    setExpandTarget({ row: activeRow, overlayId: id, sourceImageUrl: overlay.payload.asset_url, isMaster: false, source });
  }

  // Apply: geometry + payload in one object (buildExpandApplyPatch) so the
  // original pixels keep their on-frame position. hostAspect is EXACT here —
  // the master's frame is the source image, a tile's frame is the row size.
  function handleApplyExpand(result: KvExpandApplyResult) {
    const target = expandTarget;
    if (!target) return;
    const apply = (o: StudioOverlay, hostAspect: number) => ({
      ...o,
      ...buildExpandApplyPatch({
        overlay: o,
        placement: result.placement,
        sourceW: result.sourceW,
        sourceH: result.sourceH,
        imageUrl: result.imageUrl,
        mimeType: result.mimeType,
        hostAspect,
      }),
    });
    if (target.isMaster) {
      const live = projectOverlays.find((o) => o.id === target.overlayId);
      if (!live || live.payload.type !== "image") {
        setExpandTarget(null);
        showToast("Expand not applied", "That layer changed — try again.", "error");
        return;
      }
      const hostAspect = sourceSize.h > 0 ? sourceSize.w / sourceSize.h : 1;
      commitMasterOverlays(
        projectOverlays.map((o) => (o.id === target.overlayId ? apply(o, hostAspect) : o))
      );
      setExpandTarget(null);
      return;
    }
    const current = baseOverlaysFor(target.row);
    const live = current.find((o) => o.id === target.overlayId);
    if (!live || live.payload.type !== "image") {
      setExpandTarget(null);
      showToast("Expand not applied", "That layer changed — try again.", "error");
      return;
    }
    const hostAspect = target.row.height > 0 ? target.row.width / target.row.height : 1;
    commitTileOverlays(
      target.row,
      current.map((o) => (o.id === target.overlayId ? apply(o, hostAspect) : o))
    );
    setExpandTarget(null);
  }
```

(`StudioOverlay` and `KvResizeExport` are already imported in this file — verify with `grep -n "StudioOverlay\|KvResizeExport" | head`; `sourceSize` is the master frame size used by the replace path at ~line 2076.)

- [ ] **Step 3: Thread props + mount modal**

In `<KvResizeOverlayContextMenu ...>` after `onRemoveBackground={...}`:

```tsx
          onExpandImage={
            imageExpandEnabled
              ? (id) => handleRequestExpandImage(id, "resize_canvas")
              : undefined
          }
```

In the floating `<KvLayersPanel ...>` after `onRemoveBackground={...}`:

```tsx
          onExpandImage={imageExpandEnabled ? handleRequestExpandImage : undefined}
```

Next to the `KvRemoveBackgroundModal` mount:

```tsx
      {expandTarget && (
        <KvExpandImageModal
          key={expandTarget.overlayId}
          open
          fileId={fileId}
          overlayId={expandTarget.overlayId}
          sourceImageUrl={expandTarget.sourceImageUrl}
          source={expandTarget.source}
          estimatedCredits={imageExpandEstimate}
          onClose={() => setExpandTarget(null)}
          onApply={handleApplyExpand}
        />
      )}
```

- [ ] **Step 4: Type-check + run the Resize suites that exist**

Run: `cd web && bunx tsc --noEmit -p . 2>&1 | grep -E "KvResizeCanvas" || echo "no new type errors in KvResizeCanvas"`
Then: `cd web && bun test src/components/studio/kv-generator/KvResizeCanvas.decompose.test.tsx`
Expected: no new type errors; the decompose suite result unchanged from `develop`.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/KvResizeCanvas.tsx
git commit -m "feat(web): wire Expand image into the Resize canvas (master + tile)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 10: Build, full new-test run, manual e2e

**Files:** none new.

- [ ] **Step 1: Run every new/changed test file together (files, never a directory)**

```bash
cd web && bun test \
  src/services/kv/imageExpand.api.test.ts \
  src/lib/studio/kv/expandPlacement.test.ts \
  src/components/studio/kv-generator/imageExpand.test.ts \
  src/lib/analytics/kvImageExpandEvents.test.ts \
  src/components/studio/kv-generator/ExpandBoundsEditor.test.tsx \
  src/components/studio/kv-generator/KvExpandImageModal.test.tsx \
  src/components/studio/kv-generator/layerRowMenu.test.tsx \
  src/components/studio/kv-generator/KvOverlayContextMenu.test.tsx
```
Expected: all PASS

- [ ] **Step 2: Production build**

Run: `cd web && node node_modules/next/dist/bin/next build 2>&1 | tail -20`
Expected: build succeeds (it does not type-check — Task 8/9 Step 6/4 covered that).

- [ ] **Step 3: Lint the touched files**

Run: `cd web && bunx eslint src/lib/studio/kv/expandPlacement.ts src/lib/studio/kv/useGptImageCreditEstimate.ts src/components/studio/kv-generator/ExpandBoundsEditor.tsx src/components/studio/kv-generator/KvExpandImageModal.tsx src/components/studio/kv-generator/imageExpand.ts src/components/studio/kv-generator/layerRowMenu.tsx src/components/studio/kv-generator/KvOverlayContextMenu.tsx src/components/studio/kv-generator/KvResizeOverlayContextMenu.tsx`
Expected: clean (fix anything reported in these files only).

- [ ] **Step 4: Manual e2e** (needs api migrated + route cache cleared per the api plan Task 5, ai-service running with `OPENAI_API_KEY`, flag on in dev — dev is force-on). Use the Browser pane on `http://localhost:3000`, open a KV file with an uploaded image layer, and walk spec §8's checklist:
  1. Craft canvas right-click → Expand image → Landscape 16:9 → Expand image → Apply changes. Verify the layer's box grew and the original content did not move (compare against a screenshot taken before).
  2. Layers-panel row menu → drag the west handle left + the north handle up → Apply.
  3. Resize surface: expand a layer on a tile, then on the master — only the chosen one changes.
  4. Rotate a layer ~30° first, then expand → original still visually in place.
  5. `psql -d frnd -c "select cost_type, actual_credit, batch_identifier from cost_histories where cost_type='kv_image_expand' order by created_at desc limit 5"` → one row per run.
  6. Temporarily set `KV_IMAGE_EXPAND` off (or check `?ff=...` override if the project has one) → no menu items.
  Record pass/fail per item in the report; do not claim any unverified item.

- [ ] **Step 5: Report** — `git log --oneline develop..HEAD`, the bun summary line, build result, and the e2e table. Do not push.
