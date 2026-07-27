# KV PSD Import Fidelity — Web Pipeline Implementation Plan (Phase 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make an imported PSD actually look like the PSD — masks and clipping respected, blend modes rendered, geometry neither clamped nor stretched.

**Architecture:** `importPsd.ts` splits into a `psd/` module of pure functions. Parsing switches to ag-psd's `useImageData: true`, so layers and masks arrive as raw `Uint8ClampedArray` buffers and all compositing becomes array math with no DOM. Anything intrinsic to a layer (mask, clipping, effects) is baked into its raster at parse time; anything compositional (blend mode) travels to the renderers as data.

**Tech Stack:** Next.js 16, React 19, TypeScript, ag-psd 31, Fabric.js, Konva, Bun (test runner).

**Spec:** `docs/superpowers/specs/2026-07-27-kv-psd-import-fidelity-design.md`

## Global Constraints

- **Tests run with `bun test`, NOT `bunx vitest`.** `bunfig.toml` scopes discovery to `src/` and preloads the jsdom + jest-dom setup. Test files import from `"vitest"` (this works under bun's runner — follow the existing files' style).
- **jsdom has NO working 2D canvas context.** Existing PSD tests stub `initializeCanvas` (`src/lib/studio/kv/importPsd.test.ts:220`), so canvases in tests hold no real pixels. Never write a test that asserts on canvas pixels. All new pixel logic operates on `Pixels` buffers and is asserted on the array directly.
- **The real build gate is `bun run build`, not `tsc`.** Run it before the final commit of the plan.
- **Normalized geometry convention:** `x`/`y`/`width`/`height` are fractions of the host **board**, and the server accepts `-5..5` for position and `≤5` for size. Off-canvas is legal — do not clamp to `[0,1]`.
- **Payload blend values are CSS/canvas names** (`soft-light`), never Photoshop's (`soft light`). The api rejects anything outside the 17 allowed values, so unsupported PSD modes must fall back to `normal` client-side.
- **Branch:** `feature/daffa/vc-kv-psd-import-fidelity` (already created from `develop`).
- **Depends on:** the api plan's Task 1 (blendMode whitelist) must be merged before blend modes survive a reload. The web work can be built and unit-tested before that.

---

### Task 1: Extract `importPsd.ts` into a `psd/` module (pure refactor)

**Files:**
- Create: `src/lib/studio/kv/psd/types.ts`
- Create: `src/lib/studio/kv/psd/fonts.ts`
- Create: `src/lib/studio/kv/psd/text.ts`
- Create: `src/lib/studio/kv/psd/geometry.ts`
- Create: `src/lib/studio/kv/psd/index.ts`
- Modify: `src/lib/studio/kv/importPsd.ts` (becomes a re-export barrel)
- Test: `src/lib/studio/kv/importPsd.test.ts` (unchanged — it is the regression net)

**Interfaces:**
- Produces: every symbol `importPsd.ts` exports today, from the same import path. Call sites (`KvGeneratorLayout.tsx`, `KvFabricCanvas.tsx`, `KvEmptyCanvasDropArea.tsx`) must not change.

This task moves code without changing behaviour. The existing test file is the proof.

- [ ] **Step 1: Run the existing tests to establish the baseline**

```bash
cd web && bun test src/lib/studio/kv/importPsd.test.ts
```

Expected: PASS, 15 tests. Record the count — it must be identical at the end of this task.

- [ ] **Step 2: Create `psd/types.ts`**

```ts
/** Raw pixel buffer as ag-psd hands it back under `useImageData: true`.
 *  RGBA, 4 bytes per pixel, row-major. Deliberately structural rather than
 *  imported from ag-psd so the pure modules never pull the heavy parser in. */
export type Pixels = {
  width: number;
  height: number;
  data: Uint8ClampedArray;
};

/** Layer bounds in PSD pixel space. */
export type Bounds = {
  left: number;
  top: number;
  right: number;
  bottom: number;
};

/** Geometry normalized against the PSD canvas — the same convention as
 *  StudioOverlay coordinates against a board. May fall outside [0,1]: a PSD
 *  layer can legitimately bleed past the artboard. */
export type NormRect = {
  x: number;
  y: number;
  width: number;
  height: number;
};
```

- [ ] **Step 3: Move the font-matching helpers into `psd/fonts.ts`**

Move `PsdFontCandidate`, `normalizeFontKey`, `STYLE_SUFFIX`, `matchPsdFont`, `psdFontStyleFlags`, `collectMissingPsdFonts` and `rematchTextDrafts` out of `importPsd.ts` verbatim — no logic edits. `collectMissingPsdFonts` and `rematchTextDrafts` take `PsdImportLayer[]`, so import that type from `./types` once Step 5 defines it there.

- [ ] **Step 4: Move geometry into `psd/geometry.ts`**

Move `clamp01` and `normalizeRect` verbatim. Behaviour changes in Task 3, not here.

- [ ] **Step 5: Move draft types + text conversion**

Move `PsdTextDraft`, `PsdImageDraft`, `PsdImportLayer`, `PsdImportResult` into `psd/types.ts`. Move `toHex`, `psdColorToHex`, `AgPsdTextStyle`, `AgPsdLayer`, `justificationToAlign` and `convertTextLayer` into `psd/text.ts`.

- [ ] **Step 6: Move the orchestration into `psd/index.ts`**

Move `isPsdFile`, the byte-cap constants, `canvasToPngUnderCap`, `scaleCanvas`, `encodeComposite`, `importPsd` and `rebuildComposite`, importing what they need from the sibling modules. Re-export the public surface:

```ts
export type {
  Pixels, Bounds, NormRect,
  PsdTextDraft, PsdImageDraft, PsdImportLayer, PsdImportResult,
} from "./types";
export type { PsdFontCandidate } from "./fonts";
export {
  matchPsdFont, psdFontStyleFlags, collectMissingPsdFonts, rematchTextDrafts,
} from "./fonts";
```

- [ ] **Step 7: Turn `importPsd.ts` into a barrel**

Replace the entire contents of `src/lib/studio/kv/importPsd.ts` with:

```ts
/** PSD import — see `./psd/` for the implementation. This barrel keeps the
 *  original import path stable for existing call sites (KvGeneratorLayout,
 *  KvFabricCanvas, KvEmptyCanvasDropArea). */
export * from "./psd";
```

- [ ] **Step 8: Run the tests — identical result required**

```bash
cd web && bun test src/lib/studio/kv/importPsd.test.ts
```

Expected: PASS, 15 tests — the same count as Step 1. Any difference means the move changed behaviour; fix before committing.

- [ ] **Step 9: Commit**

```bash
cd web && git add src/lib/studio/kv/psd src/lib/studio/kv/importPsd.ts
git commit -m "refactor(web): split PSD import into a psd/ module"
```

---

### Task 2: `blend.ts` — PSD blend mode → canvas composite operation

**Files:**
- Create: `src/lib/studio/kv/psd/blend.ts`
- Test: `src/lib/studio/kv/psd/blend.test.ts`

**Interfaces:**
- Produces: `psdBlendToCanvas(mode: string | undefined): { value: BlendValue | null; supported: boolean }` where `BlendValue` is the payload string. `value` is `null` for normal/pass-through/absent (meaning "store nothing"); `supported` is `false` when the PSD mode has no canvas equivalent, so the caller can warn.

- [ ] **Step 1: Write the failing test**

Create `src/lib/studio/kv/psd/blend.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { psdBlendToCanvas, PSD_BLEND_MODES } from "./blend";

describe("psdBlendToCanvas", () => {
  it("maps the modes canvas supports 1:1", () => {
    expect(psdBlendToCanvas("multiply")).toEqual({
      value: "multiply",
      supported: true,
    });
    expect(psdBlendToCanvas("soft light")).toEqual({
      value: "soft-light",
      supported: true,
    });
    expect(psdBlendToCanvas("color dodge")).toEqual({
      value: "color-dodge",
      supported: true,
    });
  });

  it("treats normal / pass through / absent as 'store nothing'", () => {
    expect(psdBlendToCanvas("normal")).toEqual({ value: null, supported: true });
    expect(psdBlendToCanvas("pass through")).toEqual({
      value: null,
      supported: true,
    });
    expect(psdBlendToCanvas(undefined)).toEqual({
      value: null,
      supported: true,
    });
  });

  it("approximates linear dodge with additive compositing", () => {
    expect(psdBlendToCanvas("linear dodge")).toEqual({
      value: "lighter",
      supported: true,
    });
  });

  it("reports modes canvas cannot express, falling back to normal", () => {
    for (const mode of ["vivid light", "pin light", "hard mix", "divide", "dissolve"]) {
      expect(psdBlendToCanvas(mode)).toEqual({ value: null, supported: false });
    }
  });

  // Guards against an ag-psd upgrade adding a mode that silently falls back.
  it("classifies every blend mode ag-psd can emit", () => {
    for (const mode of PSD_BLEND_MODES) {
      const out = psdBlendToCanvas(mode);
      expect(typeof out.supported).toBe("boolean");
      expect(out.value === null || typeof out.value === "string").toBe(true);
    }
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd web && bun test src/lib/studio/kv/psd/blend.test.ts
```

Expected: FAIL — `Cannot find module './blend'`.

- [ ] **Step 3: Write the implementation**

Create `src/lib/studio/kv/psd/blend.ts`:

```ts
/** PSD blend modes → canvas `globalCompositeOperation`.
 *
 *  Blend mode is COMPOSITIONAL, not intrinsic to a layer: it can't be baked
 *  into pixels without fusing the backdrop in, which would produce a visible
 *  seam the moment the user drags the layer. So it travels to the renderers
 *  as data and is applied at draw time.
 *
 *  Correct in a flat stack: canvas composites against everything already
 *  painted beneath on the same surface, which is exactly Photoshop's
 *  pass-through semantics. */

/** Every mode ag-psd's `BlendMode` union can produce. Kept here (rather than
 *  imported) so the pure module has no ag-psd dependency — the exhaustiveness
 *  test is what keeps it honest against an ag-psd upgrade. */
export const PSD_BLEND_MODES = [
  "pass through", "normal", "dissolve", "darken", "multiply", "color burn",
  "linear burn", "darker color", "lighten", "screen", "color dodge",
  "linear dodge", "lighter color", "overlay", "soft light", "hard light",
  "vivid light", "linear light", "pin light", "hard mix", "difference",
  "exclusion", "subtract", "divide", "hue", "saturation", "color",
  "luminosity", "linear height", "height", "subtraction",
] as const;

/** The 17 values the api accepts (CSS/canvas names). */
export type BlendValue =
  | "multiply" | "screen" | "overlay" | "darken" | "lighten"
  | "color-dodge" | "color-burn" | "hard-light" | "soft-light"
  | "difference" | "exclusion" | "hue" | "saturation" | "color"
  | "luminosity" | "lighter";

const SUPPORTED: Record<string, BlendValue> = {
  darken: "darken",
  multiply: "multiply",
  "color burn": "color-burn",
  lighten: "lighten",
  screen: "screen",
  "color dodge": "color-dodge",
  overlay: "overlay",
  "soft light": "soft-light",
  "hard light": "hard-light",
  difference: "difference",
  exclusion: "exclusion",
  hue: "hue",
  saturation: "saturation",
  color: "color",
  luminosity: "luminosity",
  // Photoshop's Linear Dodge (Add) is additive compositing — canvas 'lighter'.
  "linear dodge": "lighter",
};

/** Modes that render as normal (`value: null`) rather than being unsupported. */
const NEUTRAL = new Set(["normal", "pass through", ""]);

export function psdBlendToCanvas(mode: string | undefined): {
  value: BlendValue | null;
  supported: boolean;
} {
  if (!mode || NEUTRAL.has(mode)) return { value: null, supported: true };
  const mapped = SUPPORTED[mode];
  if (mapped) return { value: mapped, supported: true };
  // linear burn, darker/lighter color, vivid/linear/pin light, hard mix,
  // subtract, divide, dissolve, ... — no canvas equivalent. Render as normal
  // and let the caller surface it per-layer.
  return { value: null, supported: false };
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd web && bun test src/lib/studio/kv/psd/blend.test.ts
```

Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
cd web && git add src/lib/studio/kv/psd/blend.ts src/lib/studio/kv/psd/blend.test.ts
git commit -m "feat(web): map PSD blend modes to canvas composite operations"
```

---

### Task 3: `geometry.ts` — stop clamping, add uniform aspect fit

**Files:**
- Modify: `src/lib/studio/kv/psd/geometry.ts`
- Test: `src/lib/studio/kv/psd/geometry.test.ts`

**Interfaces:**
- Produces:
  - `normalizeRect(left, top, right, bottom, psdW, psdH): NormRect` — no longer clamps into `[0,1]`.
  - `fitRect(psdW, psdH, boardW, boardH): NormRect` — the uniform, centered sub-rect of the board the PSD maps into.
  - `mapIntoFit(rect: NormRect, fit: NormRect): NormRect`.

Today `normalizeRect` forces every edge into `[0,1]`, which moves and resizes any layer bleeding past the artboard — full-bleed photos, background plates, and anything with a baked drop shadow. The server already accepts `-5..5` / size `≤5`, so the clamp is a purely client-side limitation.

- [ ] **Step 1: Write the failing test**

Create `src/lib/studio/kv/psd/geometry.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { fitRect, mapIntoFit, normalizeRect } from "./geometry";

describe("normalizeRect", () => {
  it("normalizes an in-bounds layer against the PSD canvas", () => {
    const r = normalizeRect(100, 100, 300, 300, 800, 600);
    expect(r.x).toBeCloseTo(100 / 800, 5);
    expect(r.y).toBeCloseTo(100 / 600, 5);
    expect(r.width).toBeCloseTo(200 / 800, 5);
    expect(r.height).toBeCloseTo(200 / 600, 5);
  });

  it("PRESERVES bleed past the artboard instead of clamping it", () => {
    // A full-bleed plate 40px outside every edge of an 800x600 PSD.
    const r = normalizeRect(-40, -40, 840, 640, 800, 600);
    expect(r.x).toBeCloseTo(-0.05, 5);
    expect(r.y).toBeCloseTo(-40 / 600, 5);
    expect(r.width).toBeCloseTo(880 / 800, 5);
    expect(r.height).toBeCloseTo(680 / 600, 5);
  });

  it("clamps only to the server's hard limits", () => {
    const r = normalizeRect(-8000, -8000, 16000, 16000, 800, 600);
    expect(r.x).toBeGreaterThanOrEqual(-5);
    expect(r.y).toBeGreaterThanOrEqual(-5);
    expect(r.width).toBeLessThanOrEqual(5);
    expect(r.height).toBeLessThanOrEqual(5);
  });

  it("keeps a minimum size so a 1px artifact stays selectable", () => {
    const r = normalizeRect(10, 10, 11, 11, 800, 600);
    expect(r.width).toBeGreaterThanOrEqual(0.01);
    expect(r.height).toBeGreaterThanOrEqual(0.01);
  });
});

describe("fitRect", () => {
  it("is the identity when aspects match", () => {
    expect(fitRect(1080, 1080, 500, 500)).toEqual({
      x: 0, y: 0, width: 1, height: 1,
    });
  });

  it("letterboxes a square PSD on a portrait board (full width, centered)", () => {
    const fit = fitRect(1000, 1000, 800, 1600); // board aspect 0.5
    expect(fit.width).toBeCloseTo(1, 5);
    expect(fit.height).toBeCloseTo(0.5, 5);
    expect(fit.x).toBeCloseTo(0, 5);
    expect(fit.y).toBeCloseTo(0.25, 5);
  });

  it("pillarboxes a square PSD on a landscape board (full height, centered)", () => {
    const fit = fitRect(1000, 1000, 1600, 800); // board aspect 2
    expect(fit.height).toBeCloseTo(1, 5);
    expect(fit.width).toBeCloseTo(0.5, 5);
    expect(fit.y).toBeCloseTo(0, 5);
    expect(fit.x).toBeCloseTo(0.25, 5);
  });
});

describe("mapIntoFit", () => {
  it("maps PSD-normalized geometry into the fit rect without distortion", () => {
    const fit = fitRect(1000, 1000, 800, 1600); // height 0.5, y 0.25
    const mapped = mapIntoFit({ x: 0, y: 0, width: 1, height: 1 }, fit);
    expect(mapped).toEqual({ x: 0, y: 0.25, width: 1, height: 0.5 });
  });

  it("preserves relative proportions of an inner layer", () => {
    const fit = fitRect(1000, 1000, 800, 1600);
    const mapped = mapIntoFit({ x: 0.25, y: 0.5, width: 0.5, height: 0.25 }, fit);
    expect(mapped.x).toBeCloseTo(0.25, 5);
    expect(mapped.y).toBeCloseTo(0.25 + 0.5 * 0.5, 5);
    expect(mapped.width).toBeCloseTo(0.5, 5);
    expect(mapped.height).toBeCloseTo(0.125, 5);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd web && bun test src/lib/studio/kv/psd/geometry.test.ts
```

Expected: FAIL — the bleed test fails (values clamped to 0 / 1), and `fitRect` / `mapIntoFit` are not exported.

- [ ] **Step 3: Write the implementation**

Replace the contents of `src/lib/studio/kv/psd/geometry.ts`:

```ts
import type { NormRect } from "./types";

/** Server-side limits on overlay geometry (UpdateStudioFileOverlaysRequest):
 *  position between -5 and 5, size greater than 0 and at most 5. Off-canvas
 *  positioning is legal and intentional (Canva-style) — a PSD layer that
 *  bleeds past the artboard MUST keep its real bounds, or it gets visibly
 *  moved and resized on import. */
const MIN_POS = -5;
const MAX_POS = 5;
const MAX_SIZE = 5;

/** Floor so a 1px artifact never becomes a zero-size, unselectable overlay. */
const MIN_SIZE = 0.01;

const clamp = (n: number, lo: number, hi: number) =>
  Math.max(lo, Math.min(hi, n));

/** Normalize PSD pixel bounds to fractions of the PSD canvas. Values outside
 *  [0,1] are PRESERVED — only the server's hard limits are enforced. */
export function normalizeRect(
  left: number,
  top: number,
  right: number,
  bottom: number,
  psdW: number,
  psdH: number
): NormRect {
  const x = clamp(left / psdW, MIN_POS, MAX_POS);
  const y = clamp(top / psdH, MIN_POS, MAX_POS);
  const width = clamp(right / psdW - left / psdW, MIN_SIZE, MAX_SIZE);
  const height = clamp(bottom / psdH - top / psdH, MIN_SIZE, MAX_SIZE);
  return { x, y, width, height };
}

/** The uniform, centered sub-rect of a board that a PSD of the given pixel
 *  size maps into. Overlay geometry is a fraction of the BOARD, so mapping a
 *  1:1 PSD straight onto a 4:5 board stretches every layer non-uniformly.
 *  Fitting preserves the design's proportions and adds margin instead. */
export function fitRect(
  psdW: number,
  psdH: number,
  boardW: number,
  boardH: number
): NormRect {
  const psdAspect = psdW / psdH;
  const boardAspect = boardW / boardH;
  if (!Number.isFinite(psdAspect) || !Number.isFinite(boardAspect)) {
    return { x: 0, y: 0, width: 1, height: 1 };
  }
  if (psdAspect > boardAspect) {
    // PSD is relatively wider — full board width, letterboxed vertically.
    const height = boardAspect / psdAspect;
    return { x: 0, y: (1 - height) / 2, width: 1, height };
  }
  // PSD is relatively taller (or equal) — full board height, pillarboxed.
  const width = psdAspect / boardAspect;
  return { x: (1 - width) / 2, y: 0, width, height: 1 };
}

/** Map PSD-normalized geometry into a fit rect. Identity when the fit is the
 *  whole board. */
export function mapIntoFit(rect: NormRect, fit: NormRect): NormRect {
  return {
    x: fit.x + rect.x * fit.width,
    y: fit.y + rect.y * fit.height,
    width: rect.width * fit.width,
    height: rect.height * fit.height,
  };
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd web && bun test src/lib/studio/kv/psd/geometry.test.ts
```

Expected: PASS, 9 tests.

- [ ] **Step 5: Run the import regression suite**

```bash
cd web && bun test src/lib/studio/kv/importPsd.test.ts
```

Expected: PASS, 15 tests. The existing round-trip assertions use in-bounds layers, so removing the clamp must not move them.

- [ ] **Step 6: Commit**

```bash
cd web && git add src/lib/studio/kv/psd/geometry.ts src/lib/studio/kv/psd/geometry.test.ts
git commit -m "feat(web): preserve off-canvas PSD bounds and add uniform aspect fit"
```

---

### Task 4: Parse with `useImageData`, add pixel helpers

**Files:**
- Create: `src/lib/studio/kv/psd/pixels.ts`
- Modify: `src/lib/studio/kv/psd/index.ts`
- Test: `src/lib/studio/kv/psd/pixels.test.ts`

**Interfaces:**
- Produces:
  - `emptyPixels(width, height): Pixels`
  - `clonePixels(src: Pixels): Pixels`
  - `pixelsToCanvas(px: Pixels): HTMLCanvasElement`
  - `boundsOf(layer): Bounds` (from a layer's `left/top/right/bottom`, defaulting to 0)

Switching to `useImageData: true` makes ag-psd return `{ width, height, data }` buffers on `layer.imageData` and `layer.mask.imageData` instead of canvases. This is what makes mask/clipping logic testable — jsdom's canvas has no real pixels — and it avoids the premultiplied-alpha corruption ag-psd warns about for canvas-backed reads.

- [ ] **Step 1: Write the failing test**

Create `src/lib/studio/kv/psd/pixels.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { boundsOf, clonePixels, emptyPixels } from "./pixels";

describe("emptyPixels", () => {
  it("allocates a fully transparent RGBA buffer", () => {
    const px = emptyPixels(3, 2);
    expect(px.width).toBe(3);
    expect(px.height).toBe(2);
    expect(px.data.length).toBe(3 * 2 * 4);
    expect([...px.data].every((v) => v === 0)).toBe(true);
  });
});

describe("clonePixels", () => {
  it("copies the buffer without aliasing the source", () => {
    const src = emptyPixels(2, 1);
    src.data[0] = 200;
    const copy = clonePixels(src);
    expect(copy.data[0]).toBe(200);
    copy.data[0] = 5;
    expect(src.data[0]).toBe(200);
  });
});

describe("boundsOf", () => {
  it("reads a layer's PSD bounds", () => {
    expect(boundsOf({ left: 10, top: 20, right: 110, bottom: 220 })).toEqual({
      left: 10, top: 20, right: 110, bottom: 220,
    });
  });

  it("defaults missing edges to zero", () => {
    expect(boundsOf({})).toEqual({ left: 0, top: 0, right: 0, bottom: 0 });
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd web && bun test src/lib/studio/kv/psd/pixels.test.ts
```

Expected: FAIL — `Cannot find module './pixels'`.

- [ ] **Step 3: Write the implementation**

Create `src/lib/studio/kv/psd/pixels.ts`:

```ts
import type { Bounds, Pixels } from "./types";

/** A fully transparent RGBA buffer. */
export function emptyPixels(width: number, height: number): Pixels {
  return {
    width: Math.max(1, Math.round(width)),
    height: Math.max(1, Math.round(height)),
    data: new Uint8ClampedArray(
      Math.max(1, Math.round(width)) * Math.max(1, Math.round(height)) * 4
    ),
  };
}

/** Deep copy — bake steps are non-mutating so a layer can be re-derived. */
export function clonePixels(src: Pixels): Pixels {
  return {
    width: src.width,
    height: src.height,
    data: new Uint8ClampedArray(src.data),
  };
}

/** Layer/mask bounds in PSD pixel space, with absent edges defaulting to 0. */
export function boundsOf(node: {
  left?: number;
  top?: number;
  right?: number;
  bottom?: number;
}): Bounds {
  return {
    left: node.left ?? 0,
    top: node.top ?? 0,
    right: node.right ?? 0,
    bottom: node.bottom ?? 0,
  };
}

/** Materialize a buffer onto a canvas for PNG encoding. This is the ONLY
 *  place the pipeline touches the DOM — everything upstream is array math,
 *  which is what makes it testable under jsdom (no real 2D context). */
export function pixelsToCanvas(px: Pixels): HTMLCanvasElement {
  const canvas = document.createElement("canvas");
  canvas.width = px.width;
  canvas.height = px.height;
  const ctx = canvas.getContext("2d");
  if (ctx) {
    const img = ctx.createImageData(px.width, px.height);
    img.data.set(px.data);
    ctx.putImageData(img, 0, 0);
  }
  return canvas;
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd web && bun test src/lib/studio/kv/psd/pixels.test.ts
```

Expected: PASS, 4 tests.

- [ ] **Step 5: Switch the parser to `useImageData`**

In `src/lib/studio/kv/psd/index.ts`, change the parse call:

```ts
  const psd = readPsd(buffer, {
    skipThumbnail: true,
    // Raw RGBA buffers instead of canvases: makes mask/clipping/effect
    // compositing pure array math (testable under jsdom, which has no real
    // 2D context) and avoids canvas premultiplied-alpha corrupting the data.
    useImageData: true,
  }) as {
    width: number;
    height: number;
    imageData?: Pixels;
    children?: AgPsdLayer[];
  };
```

Update the local `AgPsdLayer` type in `psd/text.ts` to carry `imageData?: Pixels` alongside `canvas?: HTMLCanvasElement`, and add `blendMode?: string`, `clipping?: boolean`, and `mask?: { left?: number; top?: number; right?: number; bottom?: number; defaultColor?: number; disabled?: boolean; imageData?: Pixels }`.

Then replace every `node.canvas` read in `index.ts` with `node.imageData`, routing through `pixelsToCanvas` before `canvasToPngUnderCap`. `rebuildComposite` likewise draws `pixelsToCanvas(node.imageData)` rather than `node.canvas`.

- [ ] **Step 6: Update the round-trip test's canvas stub**

In `src/lib/studio/kv/importPsd.test.ts`, the `initializeCanvas` stub exists because ag-psd needed canvases. With `useImageData: true` the parser no longer creates them, but `writePsd` in the test fixtures still does. Leave the `initializeCanvas` call in place, and change the round-trip assertions that read `layer.blob` to remain as they are — `pixelsToCanvas` runs through the same stubbed canvas, so a `Blob` is still produced.

- [ ] **Step 7: Run the full PSD test set**

```bash
cd web && bun test src/lib/studio/kv/
```

Expected: PASS. If the round-trip test now reports zero layers, the `node.canvas` → `node.imageData` swap was missed somewhere in the walk.

- [ ] **Step 8: Commit**

```bash
cd web && git add src/lib/studio/kv/psd src/lib/studio/kv/importPsd.test.ts
git commit -m "refactor(web): parse PSD with useImageData for pure-array compositing"
```

---

### Task 5: `bake.ts` — layer masks

**Files:**
- Create: `src/lib/studio/kv/psd/bake.ts`
- Test: `src/lib/studio/kv/psd/bake.test.ts`

**Interfaces:**
- Produces: `applyMask(layer: Pixels, layerBounds: Bounds, mask: Pixels, maskBounds: Bounds, defaultColor: number): Pixels` — returns a new buffer with the mask multiplied into alpha.
- Also produces the shared primitive `multiplyAlphaFrom(...)` used again by clipping in Task 6.

**This is the fix for the opaque black band.** `layer.imageData` holds the layer's **unmasked** pixels; the mask is a separate grayscale buffer with its **own bounds**, plus `defaultColor` (the value covering everything outside those bounds: `0` hidden, `255` visible) and `disabled`.

- [ ] **Step 1: Write the failing test**

Create `src/lib/studio/kv/psd/bake.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { applyMask } from "./bake";
import type { Bounds, Pixels } from "./types";

/** An opaque red buffer of the given size. */
function redLayer(w: number, h: number): Pixels {
  const data = new Uint8ClampedArray(w * h * 4);
  for (let i = 0; i < w * h; i++) {
    data[i * 4] = 255;
    data[i * 4 + 3] = 255;
  }
  return { width: w, height: h, data };
}

/** A grayscale mask buffer where every pixel has the given luminance. */
function grayMask(w: number, h: number, value: number): Pixels {
  const data = new Uint8ClampedArray(w * h * 4);
  for (let i = 0; i < w * h; i++) {
    data[i * 4] = value;
    data[i * 4 + 1] = value;
    data[i * 4 + 2] = value;
    data[i * 4 + 3] = 255;
  }
  return { width: w, height: h, data };
}

const alphaAt = (px: Pixels, x: number, y: number) =>
  px.data[(y * px.width + x) * 4 + 3];

const B = (l: number, t: number, r: number, b: number): Bounds => ({
  left: l, top: t, right: r, bottom: b,
});

describe("applyMask", () => {
  it("makes fully-black mask areas transparent", () => {
    const out = applyMask(
      redLayer(2, 2), B(0, 0, 2, 2),
      grayMask(2, 2, 0), B(0, 0, 2, 2),
      0
    );
    expect(alphaAt(out, 0, 0)).toBe(0);
    expect(alphaAt(out, 1, 1)).toBe(0);
  });

  it("leaves fully-white mask areas opaque", () => {
    const out = applyMask(
      redLayer(2, 2), B(0, 0, 2, 2),
      grayMask(2, 2, 255), B(0, 0, 2, 2),
      0
    );
    expect(alphaAt(out, 0, 0)).toBe(255);
  });

  it("scales alpha proportionally for mid-gray (the gradient scrim case)", () => {
    const out = applyMask(
      redLayer(1, 1), B(0, 0, 1, 1),
      grayMask(1, 1, 128), B(0, 0, 1, 1),
      0
    );
    expect(alphaAt(out, 0, 0)).toBeCloseTo(128, -1);
  });

  it("honours mask bounds offset from the layer's", () => {
    // Layer at 10,10 (2x2). Mask covers only the layer's bottom-right pixel.
    const out = applyMask(
      redLayer(2, 2), B(10, 10, 12, 12),
      grayMask(1, 1, 255), B(11, 11, 12, 12),
      0 // outside the mask rect → hidden
    );
    expect(alphaAt(out, 0, 0)).toBe(0);
    expect(alphaAt(out, 1, 1)).toBe(255);
  });

  it("uses defaultColor 255 to keep pixels outside the mask rect visible", () => {
    const out = applyMask(
      redLayer(2, 2), B(10, 10, 12, 12),
      grayMask(1, 1, 0), B(11, 11, 12, 12),
      255
    );
    expect(alphaAt(out, 0, 0)).toBe(255);
    expect(alphaAt(out, 1, 1)).toBe(0);
  });

  it("does not mutate the source layer", () => {
    const layer = redLayer(1, 1);
    applyMask(layer, B(0, 0, 1, 1), grayMask(1, 1, 0), B(0, 0, 1, 1), 0);
    expect(alphaAt(layer, 0, 0)).toBe(255);
  });

  it("preserves colour channels — only alpha changes", () => {
    const out = applyMask(
      redLayer(1, 1), B(0, 0, 1, 1),
      grayMask(1, 1, 128), B(0, 0, 1, 1),
      0
    );
    expect(out.data[0]).toBe(255);
    expect(out.data[1]).toBe(0);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd web && bun test src/lib/studio/kv/psd/bake.test.ts
```

Expected: FAIL — `Cannot find module './bake'`.

- [ ] **Step 3: Write the implementation**

Create `src/lib/studio/kv/psd/bake.ts`:

```ts
import { clonePixels } from "./pixels";
import type { Bounds, Pixels } from "./types";

/** Multiply a source buffer's channel into a layer's alpha, sampling by PSD
 *  pixel position so the two buffers' differing bounds line up.
 *
 *  Shared by masks (sample the RED channel — masks are grayscale, so red IS
 *  the value) and clipping (sample the ALPHA channel of the base layer).
 *
 *  `outside` is the value used where the source doesn't cover the layer:
 *  Photoshop's mask `defaultColor` for masks, and 0 for clipping (a clipped
 *  layer shows nothing beyond its base). */
export function multiplyAlphaFrom(
  layer: Pixels,
  layerBounds: Bounds,
  source: Pixels,
  sourceBounds: Bounds,
  channel: 0 | 3,
  outside: number
): Pixels {
  const out = clonePixels(layer);
  const dx = layerBounds.left - sourceBounds.left;
  const dy = layerBounds.top - sourceBounds.top;

  for (let y = 0; y < layer.height; y++) {
    const sy = y + dy;
    for (let x = 0; x < layer.width; x++) {
      const sx = x + dx;
      const inside =
        sx >= 0 && sy >= 0 && sx < source.width && sy < source.height;
      const value = inside
        ? source.data[(sy * source.width + sx) * 4 + channel]
        : outside;
      const at = (y * layer.width + x) * 4 + 3;
      out.data[at] = (out.data[at] * value) / 255;
    }
  }
  return out;
}

/** Bake a layer mask into the layer's alpha.
 *
 *  ag-psd hands back the layer's UNMASKED pixels plus a separate grayscale
 *  mask buffer — so a gradient scrim that fades to transparent in Photoshop
 *  arrives as a solid opaque rectangle unless this runs. */
export function applyMask(
  layer: Pixels,
  layerBounds: Bounds,
  mask: Pixels,
  maskBounds: Bounds,
  defaultColor: number
): Pixels {
  return multiplyAlphaFrom(layer, layerBounds, mask, maskBounds, 0, defaultColor);
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd web && bun test src/lib/studio/kv/psd/bake.test.ts
```

Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
cd web && git add src/lib/studio/kv/psd/bake.ts src/lib/studio/kv/psd/bake.test.ts
git commit -m "feat(web): bake PSD layer masks into layer alpha"
```

---

### Task 6: `bake.ts` — clipping masks

**Files:**
- Modify: `src/lib/studio/kv/psd/bake.ts`
- Modify: `src/lib/studio/kv/psd/bake.test.ts`

**Interfaces:**
- Consumes: `multiplyAlphaFrom` from Task 5.
- Produces: `applyClipping(layer: Pixels, layerBounds: Bounds, base: Pixels, baseBounds: Bounds): Pixels`.

`layer.clipping === true` means "clip to the alpha of the nearest non-clipping layer below me, within the same group"; a run of consecutive clipping layers all clip to the same base. Both layers stay separate overlays — the clipped one is simply cropped, so it remains individually selectable.

- [ ] **Step 1: Add the failing tests**

Append to `src/lib/studio/kv/psd/bake.test.ts`:

```ts
import { applyClipping } from "./bake";

/** A buffer whose left half is opaque and right half transparent. */
function halfOpaque(w: number, h: number): Pixels {
  const data = new Uint8ClampedArray(w * h * 4);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = (y * w + x) * 4;
      data[i + 2] = 255;
      data[i + 3] = x < w / 2 ? 255 : 0;
    }
  }
  return { width: w, height: h, data };
}

describe("applyClipping", () => {
  it("keeps the clipped layer only where the base is opaque", () => {
    const out = applyClipping(
      redLayer(4, 1), B(0, 0, 4, 1),
      halfOpaque(4, 1), B(0, 0, 4, 1)
    );
    expect(alphaAt(out, 0, 0)).toBe(255);
    expect(alphaAt(out, 3, 0)).toBe(0);
  });

  it("clips away everything outside the base's bounds", () => {
    // Base covers only the layer's first pixel.
    const out = applyClipping(
      redLayer(2, 1), B(0, 0, 2, 1),
      redLayer(1, 1), B(0, 0, 1, 1)
    );
    expect(alphaAt(out, 0, 0)).toBe(255);
    expect(alphaAt(out, 1, 0)).toBe(0);
  });

  it("does not mutate the clipped layer", () => {
    const layer = redLayer(2, 1);
    applyClipping(layer, B(0, 0, 2, 1), redLayer(1, 1), B(0, 0, 1, 1));
    expect(alphaAt(layer, 1, 0)).toBe(255);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd web && bun test src/lib/studio/kv/psd/bake.test.ts
```

Expected: FAIL — `applyClipping` is not exported.

- [ ] **Step 3: Write the implementation**

Append to `src/lib/studio/kv/psd/bake.ts`:

```ts
/** Bake a clipping mask: the layer survives only where its base layer is
 *  opaque. `outside` is 0 — beyond the base's bounds a clipped layer shows
 *  nothing at all. */
export function applyClipping(
  layer: Pixels,
  layerBounds: Bounds,
  base: Pixels,
  baseBounds: Bounds
): Pixels {
  return multiplyAlphaFrom(layer, layerBounds, base, baseBounds, 3, 0);
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd web && bun test src/lib/studio/kv/psd/bake.test.ts
```

Expected: PASS, 10 tests.

- [ ] **Step 5: Commit**

```bash
cd web && git add src/lib/studio/kv/psd/bake.ts src/lib/studio/kv/psd/bake.test.ts
git commit -m "feat(web): bake PSD clipping masks into layer alpha"
```

---

### Task 7: Wire bake + blend into the layer walk

**Files:**
- Modify: `src/lib/studio/kv/psd/index.ts`
- Modify: `src/lib/studio/kv/psd/types.ts`
- Test: `src/lib/studio/kv/psd/import-bake.test.ts`

**Interfaces:**
- Consumes: `applyMask`, `applyClipping`, `psdBlendToCanvas`, `boundsOf`, `pixelsToCanvas`.
- Produces: `PsdImageDraft` and `PsdTextDraft` gain `blendMode?: BlendValue`; `PsdImportResult` gains `unsupportedBlendLayers: string[]` (layer names whose blend mode canvas can't express).

- [ ] **Step 1: Extend the draft types**

In `src/lib/studio/kv/psd/types.ts`, add to both `PsdTextDraft` and `PsdImageDraft`:

```ts
  /** Canvas composite operation for this layer, when the PSD's blend mode has
   *  an equivalent. Absent ⇒ normal. Never baked — see psd/blend.ts. */
  blendMode?: BlendValue;
```

and to `PsdImportResult`:

```ts
  /** Names of layers whose PSD blend mode canvas cannot express — they render
   *  as normal. Surfaced per-layer in the import review dialog. */
  unsupportedBlendLayers: string[];
```

Import `BlendValue` from `./blend`.

- [ ] **Step 2: Write the failing test**

Create `src/lib/studio/kv/psd/import-bake.test.ts`. Build a PSD with `writePsd` containing (a) an opaque layer with an all-black mask and (b) a layer with `blendMode: 'multiply'`, then assert the mask made the layer transparent and the blend mode came through:

```ts
import { describe, expect, it } from "vitest";
import { initializeCanvas, writePsd } from "ag-psd";
import { importPsd } from "./index";

function solid(w: number, h: number, r: number, g: number, b: number) {
  const data = new Uint8ClampedArray(w * h * 4);
  for (let i = 0; i < w * h; i++) {
    data[i * 4] = r;
    data[i * 4 + 1] = g;
    data[i * 4 + 2] = b;
    data[i * 4 + 3] = 255;
  }
  return { width: w, height: h, data };
}

function stubCanvas(w: number, h: number) {
  return {
    width: w,
    height: h,
    getContext: () => ({
      createImageData: (cw: number, ch: number) => ({
        width: cw, height: ch, data: new Uint8ClampedArray(cw * ch * 4),
      }),
      putImageData: () => {},
      drawImage: () => {},
      getImageData: (_x: number, _y: number, cw: number, ch: number) => ({
        width: cw, height: ch, data: new Uint8ClampedArray(cw * ch * 4),
      }),
    }),
    toBlob: (cb: (b: Blob) => void) => cb(new Blob(["x"])),
  };
}

describe("importPsd — bake + blend", () => {
  initializeCanvas(
    ((w: number, h: number) => stubCanvas(w, h)) as never,
    ((w: number, h: number) => ({
      width: w, height: h, data: new Uint8ClampedArray(w * h * 4),
    })) as never
  );

  function buildFile() {
    const psd = {
      width: 100,
      height: 100,
      children: [
        {
          name: "Scrim",
          left: 0, top: 0, right: 100, bottom: 100,
          imageData: solid(100, 100, 0, 0, 0),
          blendMode: "multiply" as const,
          mask: {
            left: 0, top: 0, right: 100, bottom: 100,
            defaultColor: 0,
            imageData: solid(100, 100, 0, 0, 0), // all black ⇒ fully hidden
          },
        },
        {
          name: "Exotic",
          left: 0, top: 0, right: 50, bottom: 50,
          imageData: solid(50, 50, 10, 20, 30),
          blendMode: "vivid light" as const,
        },
      ],
      imageData: solid(100, 100, 5, 5, 5),
    };
    const buffer = writePsd(psd as never, { generateThumbnail: false });
    const file = new File([buffer], "bake.psd");
    if (typeof file.arrayBuffer !== "function") {
      Object.defineProperty(file, "arrayBuffer", { value: async () => buffer });
    }
    return file;
  }

  it("carries a supported blend mode onto the draft", async () => {
    const result = await importPsd(buildFile(), { fonts: [] });
    const scrim = result.layers.find((l) => l.name === "Scrim");
    expect(scrim?.blendMode).toBe("multiply");
  });

  it("reports blend modes canvas cannot express instead of failing silently", async () => {
    const result = await importPsd(buildFile(), { fonts: [] });
    const exotic = result.layers.find((l) => l.name === "Exotic");
    expect(exotic?.blendMode).toBeUndefined();
    expect(result.unsupportedBlendLayers).toContain("Exotic");
  });
});
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
cd web && bun test src/lib/studio/kv/psd/import-bake.test.ts
```

Expected: FAIL — `blendMode` is undefined on the draft and `unsupportedBlendLayers` does not exist.

- [ ] **Step 4: Wire the walk**

In `src/lib/studio/kv/psd/index.ts`, inside `walk`, replace the raster branch so that before encoding:

1. Track the most recent non-clipping sibling's `{ pixels, bounds }` in a local variable, resetting it per `children` list (clipping never crosses a group boundary).
2. Start from `node.imageData`; if `node.mask?.imageData && !node.mask.disabled`, run `applyMask(px, boundsOf(node), node.mask.imageData, boundsOf(node.mask), node.mask.defaultColor ?? 0)`.
3. If `node.clipping === true` and a clip base exists, run `applyClipping(...)` against it.
4. If `node.clipping !== true`, record this layer as the new clip base **after** its own mask is applied (Photoshop clips to the masked result).
5. Encode via `canvasToPngUnderCap(pixelsToCanvas(px))`.
6. Compute `const { value, supported } = psdBlendToCanvas(node.blendMode)`; spread `...(value ? { blendMode: value } : {})` onto the draft, and push `node.name ?? "Layer"` onto `unsupportedBlendLayers` when `!supported`.

Apply the same blend lines to the text branch (a PSD text layer can carry a blend mode). Return `unsupportedBlendLayers` from `importPsd`.

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd web && bun test src/lib/studio/kv/psd/import-bake.test.ts
```

Expected: PASS, 2 tests.

- [ ] **Step 6: Run the full PSD suite**

```bash
cd web && bun test src/lib/studio/kv/
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
cd web && git add src/lib/studio/kv/psd
git commit -m "feat(web): apply masks, clipping and blend modes during PSD import"
```

---

### Task 8: Render blend modes in both canvases

**Files:**
- Modify: `src/types/studio.ts` (image + text + shape payloads)
- Modify: `src/components/studio/kv-generator/KvFabricCanvas.tsx`
- Modify: `src/components/studio/kv-generator/KvKonvaCanvas.tsx`
- Modify: `src/components/studio/kv-generator/KvGeneratorLayout.tsx` (`placePsdLayers`)

**Interfaces:**
- Consumes: `PsdImageDraft.blendMode` / `PsdTextDraft.blendMode` from Task 7.
- Produces: `payload.blendMode` persisted and rendered.

**Both renderers must change together.** Export flattens through the **Konva** stage (`overlays/exportFlatten.ts`), not Fabric — a Fabric-only change makes the download disagree with the canvas.

- [ ] **Step 1: Add `blendMode` to the payload types**

In `src/types/studio.ts`, add to the text, image and shape payload members of `StudioOverlay["payload"]`:

```ts
        /** Canvas composite operation (CSS blend name, e.g. "multiply"),
         *  imported from a PSD layer's blend mode. Absent ⇒ normal
         *  ("source-over"). Whitelisted in UpdateStudioFileOverlaysRequest —
         *  validated() strips unlisted payload keys. */
        blendMode?:
          | "multiply" | "screen" | "overlay" | "darken" | "lighten"
          | "color-dodge" | "color-burn" | "hard-light" | "soft-light"
          | "difference" | "exclusion" | "hue" | "saturation" | "color"
          | "luminosity" | "lighter";
```

- [ ] **Step 2: Add a shared resolver**

Create `src/components/studio/kv-generator/overlays/resolveBlendMode.ts`:

```ts
import type { StudioOverlay } from "@/types/studio";

/** Canvas composite operation for an overlay. Absent/normal ⇒ "source-over",
 *  which is what both Fabric and Konva expect for default compositing. */
export function resolveBlendMode(payload: StudioOverlay["payload"]): string {
  const mode = "blendMode" in payload ? payload.blendMode : undefined;
  return mode ?? "source-over";
}
```

- [ ] **Step 3: Apply it in Fabric**

In `KvFabricCanvas.tsx`, every `found.set({...})` / `img.set({...})` / object construction for image, text and shape overlays gains:

```ts
  globalCompositeOperation: resolveBlendMode(overlay.payload),
```

For the image branch this means both the reuse path (around line 1607) and the `fromURL` path (around line 1630).

- [ ] **Step 4: Apply it in Konva**

In `KvKonvaCanvas.tsx`, next to the existing `opacity={...}` prop (around line 1800), add:

```tsx
  globalCompositeOperation={
    resolveBlendMode(overlay.payload) as GlobalCompositeOperation
  }
```

Apply it to the image, text and shape nodes alike.

- [ ] **Step 5: Persist it on import**

In `KvGeneratorLayout.tsx`'s `placePsdLayers`, add to both the image and text `addOverlay` payloads:

```ts
          ...(layer.blendMode ? { blendMode: layer.blendMode } : {}),
```

- [ ] **Step 6: Verify the build**

```bash
cd web && bun run build
```

Expected: build succeeds. (`bun run build` is the real gate — it type-checks the app in a way `tsc` alone does not cover here.)

- [ ] **Step 7: Commit**

```bash
cd web && git add src/types/studio.ts src/components/studio/kv-generator
git commit -m "feat(web): render overlay blend modes in Fabric and Konva"
```

---

### Task 9: Blank base at the PSD's ratio, and uniform fit on board drops

**Files:**
- Modify: `src/components/studio/kv-generator/makeBlankBase.ts`
- Modify: `src/components/studio/kv-generator/KvGeneratorLayout.tsx` (`importPsdFile`, `placePsdLayers`)
- Test: `src/components/studio/kv-generator/makeBlankBase.test.ts`

**Interfaces:**
- Produces: `blankBaseDimensions(width: number, height: number): { w: number; h: number }` (pure, capped at 4096, aspect preserved) and `makeBlankBaseAt(width: number, height: number, opts?: { fileName?: string }): Promise<File>`, alongside the existing ratio-based `makeBlankBase`.

**Why the dimension maths is a separate exported function:** jsdom implements neither `getContext("2d")` nor `toBlob` — `toBlob` never invokes its callback, so a test awaiting `makeBlankBaseAt` would hang rather than fail. Only the pure part is tested; `makeBlankBaseAt` itself is verified in the manual pass, exactly like the existing untested `makeBlankBase`.

Two behaviour changes: an empty-canvas drop no longer uploads the flattened composite as the base (it becomes a blank board at the PSD's own size), and a board drop maps layers through a uniform fit rect instead of stretching them.

- [ ] **Step 1: Write the failing test**

Create `src/components/studio/kv-generator/makeBlankBase.test.ts`:

```ts
import { describe, expect, it } from "bun:test";
import { blankBaseDimensions } from "./makeBlankBase";

describe("blankBaseDimensions", () => {
  it("passes through a size already under the ceiling", () => {
    expect(blankBaseDimensions(1080, 1351)).toEqual({ w: 1080, h: 1351 });
  });

  it("caps the long edge at 4096, preserving aspect", () => {
    expect(blankBaseDimensions(8192, 4096)).toEqual({ w: 4096, h: 2048 });
  });

  it("caps on height when the PSD is portrait", () => {
    expect(blankBaseDimensions(4096, 8192)).toEqual({ w: 2048, h: 4096 });
  });

  it("never returns a zero dimension", () => {
    const d = blankBaseDimensions(10000, 1);
    expect(d.w).toBeGreaterThan(0);
    expect(d.h).toBeGreaterThan(0);
  });
});
```

Note the `bun:test` import: files under `src/components/` follow their siblings (`KvPsdImportOverlay.test.tsx`), while `src/lib/` tests import from `vitest`.

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd web && bun test src/components/studio/kv-generator/makeBlankBase.test.ts
```

Expected: FAIL — `blankBaseDimensions` is not exported.

- [ ] **Step 3: Add `makeBlankBaseAt`**

Append to `makeBlankBase.ts`:

```ts
/** Ceiling for a generated base board — matches the cap PSD composites already
 *  use. Anything larger only bloats the upload. */
const MAX_BASE_DIM = 4096;

/** Pixel size a blank base board should use for a PSD of the given size:
 *  aspect preserved, long edge capped at MAX_BASE_DIM. Pure and exported so
 *  it can be tested — jsdom implements neither getContext("2d") nor toBlob,
 *  so makeBlankBaseAt itself is not unit-testable. */
export function blankBaseDimensions(
  width: number,
  height: number
): { w: number; h: number } {
  const maxDim = Math.max(width, height);
  const scale = maxDim > MAX_BASE_DIM ? MAX_BASE_DIM / maxDim : 1;
  return {
    w: Math.max(1, Math.round(width * scale)),
    h: Math.max(1, Math.round(height * scale)),
  };
}

/**
 * A solid-white PNG at explicit pixel dimensions (aspect preserved, capped at
 * MAX_BASE_DIM). Used for PSD imports: the base board is created at the PSD's
 * OWN size so imported layers land unstretched, instead of being mapped onto
 * whatever ratio the user happened to pick.
 */
export async function makeBlankBaseAt(
  width: number,
  height: number,
  opts?: { fileName?: string }
): Promise<File> {
  const { w, h } = blankBaseDimensions(width, height);

  const canvas = document.createElement("canvas");
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext("2d");
  if (ctx) {
    ctx.fillStyle = "#ffffff";
    ctx.fillRect(0, 0, w, h);
  }

  const blob = await new Promise<Blob>((resolve) => {
    canvas.toBlob(
      (b) => resolve(b ?? new Blob([], { type: "image/png" })),
      "image/png"
    );
  });

  return new File([blob], opts?.fileName ?? `blank-${w}x${h}.png`, {
    type: "image/png",
  });
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd web && bun test src/components/studio/kv-generator/makeBlankBase.test.ts
```

Expected: PASS, 2 tests.

- [ ] **Step 5: Use the blank base on empty-canvas drops**

In `KvGeneratorLayout.tsx`'s `importPsdFile`, replace the composite upload (around line 3451) so the base is blank at the PSD's size, keeping the composite ONLY as a fallback when no layers parsed:

```ts
      const baseName = f.name.replace(/\.psd$/i, "");
      // Blank base at the PSD's own ratio: layers ARE the picture, so the
      // export carries one copy of the artwork and any import gap is visible
      // rather than patched over by a perfect composite underneath.
      const baseFile = parsed.layers.length
        ? await makeBlankBaseAt(parsed.width, parsed.height, {
            fileName: `${baseName}.png`,
          })
        : parsed.composite
          ? new File(
              [parsed.composite],
              `${baseName}.${parsed.composite.type === "image/jpeg" ? "jpg" : "png"}`,
              { type: parsed.composite.type }
            )
          : null;
      if (!baseFile) {
        trackKvPsdImportFailed({
          target: analyticsTarget,
          failure_stage: "empty",
          duration_ms: Date.now() - startedAt,
        });
        setTransientNotice("This PSD has no image data to import.");
        psdImportBusyRef.current = false;
        setPsdImporting(false);
        return;
      }
      const importedId = await handleUploadBase(baseFile);
```

- [ ] **Step 6: Fit layers to the board on board drops**

Add a helper above `importPsdFile`:

```ts
  /** Natural pixel size of a board's base image, for aspect fitting. Returns
   *  null when the probe fails — callers then map 1:1 (previous behaviour)
   *  rather than guessing a ratio. */
  const probeImageDims = (url: string) =>
    new Promise<{ w: number; h: number } | null>((resolve) => {
      const img = new Image();
      img.onload = () => resolve({ w: img.naturalWidth, h: img.naturalHeight });
      img.onerror = () => resolve(null);
      img.src = url;
    });
```

In `importPsdFile`, for the `target.kind === "board"` path, resolve the board's generation, probe its `image_url`, and compute the fit:

```ts
      const board = stream.generations.find(
        (g) => g.id === target.boardGenerationId
      );
      const dims = board ? await probeImageDims(board.image_url) : null;
      fit = dims
        ? fitRect(parsed.width, parsed.height, dims.w, dims.h)
        : { x: 0, y: 0, width: 1, height: 1 };
```

For the empty-canvas path the board is created at the PSD's own size, so `fit` is the identity `{ x: 0, y: 0, width: 1, height: 1 }`.

Thread `fit` through both functions — `finishPsdImport(layers, boardGenerationId, fit, analyticsTarget, startedAt, parsedSkipped)` and `placePsdLayers(layers, boardGenerationId, fit)` — and map each draft's rect through it inside `placePsdLayers`:

```ts
        const rect = mapIntoFit(layer.rect, fit);
```

using `...rect` in place of `...layer.rect` in **both** `addOverlay` calls (image and text).

- [ ] **Step 7: Verify the build**

```bash
cd web && bun run build
```

Expected: build succeeds.

- [ ] **Step 8: Commit**

```bash
cd web && git add src/components/studio/kv-generator
git commit -m "feat(web): blank PSD base board at source ratio, fit layers without stretching"
```

---

### Task 10: Raise the client overlay cap to match the API

**Files:**
- Modify: `src/components/studio/kv-generator/KvGeneratorLayout.tsx:3136`

- [ ] **Step 1: Raise the constant**

```ts
  // The server rejects overlay saves past this count (UpdateStudioFileOverlaysRequest
  // `max:300`) — importing past it would poison the autosave, so the import
  // caps itself and reports what was dropped. MUST stay in sync with the BE cap.
  const MAX_OVERLAYS_PER_FILE = 300;
```

- [ ] **Step 2: Verify the build**

```bash
cd web && bun run build
```

Expected: build succeeds.

- [ ] **Step 3: Run the whole KV test set**

```bash
cd web && bun test src/lib/studio src/components/studio
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
cd web && git add src/components/studio/kv-generator/KvGeneratorLayout.tsx
git commit -m "feat(web): raise client overlay cap to 300 to match the api"
```

---

## Done criteria

- A PSD whose scrim is a masked gradient imports as a soft gradient, not an opaque rectangle.
- A layer with a Multiply blend mode renders multiplied on the canvas **and** in the downloaded PNG.
- A full-bleed layer keeps its true bounds instead of being pulled inside the frame.
- A 1:1 PSD dropped on a 4:5 board lands proportioned and centered, not stretched.
- An empty-canvas drop produces a blank board at the PSD's own dimensions with the layers on top.
- `bun test src/lib/studio/kv/` and `bun run build` are both green.

## Not in this plan

- The import review dialog and the Import PSD entry point — see `2026-07-27-kv-psd-import-review-dialog-web.md`.
- Layer effects (drop shadow, stroke, colour/gradient overlay) and vector-layer → `shape` conversion — deliberately last in phase 1, planned after the dialog lands so they can be cut without blocking.
- Groups (`parent_id`, `group` overlay type) — phase 2.
