# KV Layer-Composed Resize — web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a PSD import declare itself layer-composed, and make resize tiles render and download from layers alone when they carry no base image.

**Architecture:** PSD import already mints a blank base and stores the artwork as overlays; it now sends `layer_composed: true` alongside. The api completes those resize tiles with `image_url = null`, so the tile renderer and the flatten-to-PNG path must both tolerate a missing base and draw overlays on their own. Layer positions come from the existing projection in `overlayAspect.ts`, extended with cover-scaling for a full-canvas background.

**Tech Stack:** Next.js 16, React 19, TypeScript, Konva, `bun test` (vitest-compatible API), Testing Library.

Spec: `docs/superpowers/specs/2026-08-06-kv-layer-composed-resize-design.md` (§1 and §2).
Companion plan: `docs/superpowers/plans/2026-08-06-kv-layer-composed-resize-api.md` — **Task 1 below depends on api Task 1 being merged**, since the endpoint rejects unknown fields only after validation is added there. The remaining web tasks are independent of api.

## Global Constraints

- The wire field is exactly `layer_composed` (snake_case); the TypeScript-side option is `layerComposed`.
- `image_url === null` on a `done` tile means "layer-composed, assemble on demand" — it is not an error state.
- Never store a projected layer set. Projection happens at render time via `resolveTileOverlays`; a tile snapshot is written only when the user edits that tile.
- Identical source and target aspect must stay pixel-exact — the existing same-aspect fast path must keep returning early, untouched.
- Tests run with `bun test <path>` from `web/`. There is no `test` script in `package.json`. Imports use `vitest` names; bun's runner aliases them.
- The real build gate is `bun run build`, not `tsc`. Run it before the final commit.

---

### Task 1: Send `layer_composed` from PSD import

**Files:**
- Modify: `web/src/services/kv/api.ts:230-249`
- Modify: `web/src/components/studio/kv-generator/promoteAttachmentToBase.ts:23-47`
- Modify: `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx:2391-2403` (opts type) and `:2418-2437` (call), `:3724-3726` (PSD call site)
- Test: `web/src/components/studio/kv-generator/promoteAttachmentToBase.test.ts`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `promoteAttachmentToBase({ fileId, attachment, canvasMode?, layerComposed? })` and `handleUploadBase(file, { name?, canvasMode?, layerComposed? })`. No later task consumes these.

- [ ] **Step 1: Write the failing test**

Append inside the existing `describe("promoteAttachmentToBase", …)` block in `promoteAttachmentToBase.test.ts`:

```ts
  it("forwards layerComposed to the import endpoint as layer_composed", async () => {
    mockImport.mockResolvedValue({ id: "gen_psd_1", version_number: 1 });

    await promoteAttachmentToBase({
      fileId: "file_abc",
      attachment: {
        id: "att_1",
        name: "blank-base.png",
        mime_type: "image/png",
        size: 48139,
        url: "https://s3/uploads/blank-base.png",
        width: 1080,
        height: 1920,
      },
      canvasMode: "craft",
      layerComposed: true,
    });

    expect(mockImport).toHaveBeenCalledWith("file_abc", {
      image_url: "https://s3/uploads/blank-base.png",
      mime_type: "image/png",
      size: 48139,
      original_filename: "blank-base.png",
      width: 1080,
      height: 1920,
      canvas_mode: "craft",
      layer_composed: true,
    });
  });
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/promoteAttachmentToBase.test.ts`

Expected: the new test FAILS — the actual call carries no `layer_composed` key. The two pre-existing tests still pass.

- [ ] **Step 3: Widen the service body type**

In `api.ts`, add one field to the `importKvGenerationFromUpload` body type, after `canvas_mode`:

```ts
    /** True when the base is a blank canvas and the artwork lives in
     *  overlay layers (PSD import). Resize skips the image model for these. */
    layer_composed?: boolean;
```

- [ ] **Step 4: Thread it through `promoteAttachmentToBase`**

Add the option to the args type and pass it on:

```ts
export async function promoteAttachmentToBase(args: {
  fileId: string;
  attachment: UploadedAttachmentDescriptor;
  /** Canvas mode the new base board should belong to (defaults to
   *  "sketch" server-side when omitted). A drop in Craft passes "craft". */
  canvasMode?: "sketch" | "craft";
  /** True when the layers ARE the picture and this base is deliberately
   *  blank — see the PSD import path in KvGeneratorLayout. */
  layerComposed?: boolean;
}): Promise<KvGeneration | null> {
  const { fileId, attachment, canvasMode, layerComposed } = args;
  if (!attachment.url) return null;

  try {
    const generation = await importKvGenerationFromUpload(fileId, {
      image_url: attachment.url,
      mime_type: attachment.mime_type,
      size: attachment.size,
      original_filename: attachment.name,
      width: attachment.width,
      height: attachment.height,
      canvas_mode: canvasMode,
      layer_composed: layerComposed,
    });
    return generation;
  } catch {
    return null;
  }
}
```

Leaving the key `undefined` when not supplied keeps the two existing assertions passing, because axios drops undefined keys and the matcher ignores undefined properties.

- [ ] **Step 5: Thread it through `handleUploadBase`**

In `KvGeneratorLayout.tsx`, add to the `opts` type at `:2394-2402`:

```ts
        /** Blank base whose layers carry the artwork (PSD import). Recorded
         *  on the generation so resize can skip the image model. */
        layerComposed?: boolean;
```

and pass it in the `promoteAttachmentToBase` call at `:2418-2437`, after `canvasMode`:

```ts
          layerComposed: opts?.layerComposed,
```

- [ ] **Step 6: Set it at the PSD import call site**

At `KvGeneratorLayout.tsx:3724-3726`, the blank base minted for a PSD is exactly the case this flag describes:

```ts
      const importedId = await handleUploadBase(baseFile, {
        canvasMode: review.boardCanvasMode,
        layerComposed: true,
      });
```

Do **not** set it on the "Add blank frame" path at `:2485` — that base is blank too, but the user is about to draw on it, and it has no layers.

- [ ] **Step 7: Run the test to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/promoteAttachmentToBase.test.ts`

Expected: all 3+ tests pass.

- [ ] **Step 8: Commit**

```bash
cd web && git add src/services/kv/api.ts src/components/studio/kv-generator/promoteAttachmentToBase.ts src/components/studio/kv-generator/promoteAttachmentToBase.test.ts src/components/studio/kv-generator/KvGeneratorLayout.tsx
git commit -m "feat(web): flag PSD imports as layer-composed"
```

---

### Task 2: Render a done tile that has no base image

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvTileOverlayEditor.tsx:51` (prop type) and `:156-166` (loader)
- Modify: `web/src/components/studio/kv-generator/KvResizeResultRow.tsx:194-289` (the status ternary)
- Test: `web/src/components/studio/kv-generator/KvResizeResultRow.test.tsx`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `KvTileOverlayEditor` accepts `baseImageUrl: string | null`. Task 3 relies on the same nullability convention.

Today a `done` tile with a null `image_url` falls through `row.status === "done" && row.imageUrl` and lands in the red error branch, showing "Couldn't resize this tile. Please try again." — the overlays are computed and then thrown away. That is the single change that makes layer-composed tiles visible.

- [ ] **Step 1: Write the failing test**

Append to `KvResizeResultRow.test.tsx`. The file already stubs canvas and `Image`, and defines `baseProps`, `baseRow` and `overlay` fixtures.

```tsx
  it("renders the overlay editor for a done tile with no base image", () => {
    render(
      <KvResizeResultRow
        {...baseProps}
        row={{ ...baseRow, status: "done", imageUrl: null }}
        projectOverlays={[overlay]}
        selectedId={null}
        isActive={false}
        onSelect={() => {}}
        onActivate={() => {}}
        onCommitOverlays={() => {}}
        onResetOverlays={() => {}}
        onDownload={() => {}}
        onArmRegenerate={() => {}}
        armed={false}
        onRetry={() => {}}
      />,
    );

    expect(
      document.querySelector('[data-testid="tile-overlay-editor"]'),
    ).toBeInTheDocument();
    expect(screen.queryByText(/couldn't resize this tile/i)).not.toBeInTheDocument();
  });

  it("still shows the error state for a failed tile", () => {
    render(
      <KvResizeResultRow
        {...baseProps}
        row={{ ...baseRow, status: "failed", imageUrl: null }}
        projectOverlays={[overlay]}
        selectedId={null}
        isActive={false}
        onSelect={() => {}}
        onActivate={() => {}}
        onCommitOverlays={() => {}}
        onResetOverlays={() => {}}
        onDownload={() => {}}
        onArmRegenerate={() => {}}
        armed={false}
        onRetry={() => {}}
      />,
    );

    expect(screen.getByText(/couldn't resize this tile/i)).toBeInTheDocument();
    expect(
      document.querySelector('[data-testid="tile-overlay-editor"]'),
    ).not.toBeInTheDocument();
  });
```

The second test is a regression guard: widening the done branch must not swallow real failures.

- [ ] **Step 2: Run the tests to verify the first fails**

Run: `cd web && bun test src/components/studio/kv-generator/KvResizeResultRow.test.tsx`

Expected: "renders the overlay editor for a done tile with no base image" FAILS (the editor is absent, the error text is present). "still shows the error state for a failed tile" already PASSES.

- [ ] **Step 3: Make the editor accept a null base**

In `KvTileOverlayEditor.tsx`, change the prop type at `:51`:

```tsx
  baseImageUrl: string | null;
```

and guard the loader at `:156-166`:

```tsx
  useEffect(() => {
    if (!baseImageUrl) {
      setBaseImg(null);
      return;
    }
    // No crossOrigin: matches KvKonvaCanvas / KvResizeTileStage. S3 doesn't
    // send CORS headers ...
    const img = new window.Image();
    img.src = baseImageUrl;
    img.onload = () => setBaseImg(img);
  }, [baseImageUrl]);
```

Nothing else in this component needs changing: the render already falls back to a translucent `Rect` when `baseImg` is null and still draws every overlay, and the sizing at `:174-177` already falls back to `targetWidth`/`targetHeight`.

- [ ] **Step 4: Widen the done branch**

In `KvResizeResultRow.tsx`, change the second arm of the ternary at `:196` from `row.status === "done" && row.imageUrl` to `row.status === "done"`, and make the React key tolerate a null URL at `:204`:

```tsx
      ) : row.status === "done" ? (
        <div key={row.imageUrl ?? row.id}
```

Leave `baseImageUrl={row.imageUrl}` as-is — it is now legally nullable.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd web && bun test src/components/studio/kv-generator/KvResizeResultRow.test.tsx`

Expected: every test passes, including the pre-existing pending, generating and failed cases.

- [ ] **Step 6: Check the sibling editor tests still pass**

Run: `cd web && bun test src/components/studio/kv-generator/KvTileOverlayEditor.test.tsx`

Expected: all pass. If a test asserts the prop type by passing a non-null URL only, nothing changes for it.

- [ ] **Step 7: Commit**

```bash
cd web && git add src/components/studio/kv-generator/KvTileOverlayEditor.tsx src/components/studio/kv-generator/KvResizeResultRow.tsx src/components/studio/kv-generator/KvResizeResultRow.test.tsx
git commit -m "feat(web): render resize tiles that have layers but no base image"
```

---

### Task 3: Flatten and download a tile with no base image

**Files:**
- Modify: `web/src/components/studio/kv-generator/renderBoardStage.ts:32-36` (`buildBoardStage` args), `:71-78` (the base load), `:219-223` (`renderHiddenStage` args)
- Modify: `web/src/components/studio/kv-generator/KvResizeCanvas.tsx:244`, `:758-762` (`flattenTile` args), `:772-773`, `:800`
- Test: `web/src/components/studio/kv-generator/renderBoardStage.test.ts` (exists — append)

**Interfaces:**
- Consumes: the nullable-base convention from Task 2.
- Produces: `buildBoardStage` and `renderHiddenStage` accept `baseImageUrl: string | null` and render overlays only when it is null.

Note the file is named `renderBoardStage.ts` but the functions are `buildBoardStage` (`:32`) and its thin wrapper `renderHiddenStage` (`:219`). `flattenBoardOverlaysToBlob` (`:265`) takes `imageUrl` and sizes the stage from that image, so it cannot work without a base and is deliberately left alone — it is not on the resize download path.

`loadImage` rejects on error, so today flattening a tile with `baseImageUrl = ""` throws and the download fails outright. Without this task, Task 2's tiles are visible but cannot be saved.

- [ ] **Step 1: Write the failing test**

Append to the existing `describe("renderHiddenStage", …)` block in `renderBoardStage.test.ts`. The file already stubs `window.Image` with a canvas-backed `FakeImage` in its `beforeEach`, so Konva's draw pass works under jsdom and the test needs no extra setup.

```ts
  it("renders overlays with no Image node when the board has no base url", async () => {
    const overlay: StudioOverlay = {
      id: "o_bg",
      studio_file_id: "f",
      type: "shape",
      x: 0.1,
      y: 0.1,
      width: 0.2,
      height: 0.2,
      rotation: 0,
      z: 1,
      payload: {
        type: "shape",
        kind: "rectangle",
        color: "#ff0000",
      },
      created_at: "t",
      updated_at: "t",
    };

    const stage = await renderHiddenStage({
      baseImageUrl: null,
      overlays: [overlay],
      targetWidth: 1080,
      targetHeight: 1920,
    });

    try {
      // Still exactly one Layer, still draws the overlay — just no base.
      expect(stage.getLayers().length).toBe(1);
      expect(stage.findOne("Image")).toBeUndefined();
      expect(stage.findOne("Rect")).toBeDefined();
    } finally {
      stage.destroy();
    }
  });
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/renderBoardStage.test.ts`

Expected: the new test FAILS. With `baseImageUrl: null` the unconditional `loadImage(null)` sets `img.src = "null"`, and depending on the stub it either rejects or produces an `Image` node — either way the assertion `stage.findOne("Image")` being undefined does not hold. The three pre-existing tests still pass.

- [ ] **Step 3: Skip the base when there is none**

In `renderBoardStage.ts`, widen both signatures. `buildBoardStage` at `:32-37`:

```ts
export async function buildBoardStage(args: {
  baseImageUrl: string | null;
  overlays: StudioOverlay[];
  targetWidth: number;
  targetHeight: number;
  container?: HTMLDivElement;
}): Promise<{
```

and `renderHiddenStage` at `:219-224`:

```ts
export async function renderHiddenStage(args: {
  baseImageUrl: string | null;
  overlays: StudioOverlay[];
  targetWidth: number;
  targetHeight: number;
}) {
```

Then replace the unconditional load at `:71-78`:

```ts
  // A layer-composed board (PSD import) has no base image — the layers ARE
  // the picture. Skip the base rather than failing the whole flatten; the
  // stage stays transparent behind the overlays.
  if (baseImageUrl) {
    const baseImg = await loadImage(baseImageUrl);
    layer.add(
      new Konva.Image({
        image: baseImg,
        width: targetWidth,
        height: targetHeight,
      }),
    );
  }
```

The base and the overlays must stay on this one shared `layer` — an existing test asserts that, because splitting them silently degrades every blend mode.

- [ ] **Step 4: Let layer-only tiles reach the download path**

In `KvResizeCanvas.tsx`, three call sites currently assume an image URL exists.

At `:244`, drop the URL condition so layer-only tiles count as ready:

```ts
  const readyExports = exports.filter((r) => r.status === "done");
```

At `:758-762`, widen the local `flattenTile` helper's argument type:

```ts
  async function flattenTile(args: {
    baseImageUrl: string | null;
    overlays: StudioOverlay[];
    targetWidth: number;
    targetHeight: number;
  }): Promise<Blob> {
```

At `:772-773`, remove the early return in `downloadOne` so the flatten runs from overlays:

```ts
  async function downloadOne(row: KvResizeExport) {
    try {
```

(delete the `if (!row.imageUrl) return;` line that sits between them). Its `baseImageUrl: row.imageUrl` at `:776` now type-checks on its own.

At `:800` in `downloadAll`, pass the null through instead of coercing to an empty string, and delete the now-unneeded ignore comment:

```ts
          baseImageUrl: row.imageUrl,
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd web && bun test src/components/studio/kv-generator/renderBoardStage.test.ts`

Expected: the new test passes and all pre-existing tests in the file still pass — in particular the shared-Layer and clipping-Group assertions, which guard blend-mode correctness.

- [ ] **Step 6: Run the wider resize test set**

Run: `cd web && bun test src/components/studio/kv-generator/KvResize`

Expected: all resize component tests pass.

- [ ] **Step 7: Commit**

```bash
cd web && git add src/components/studio/kv-generator/renderBoardStage.ts src/components/studio/kv-generator/renderBoardStage.test.ts src/components/studio/kv-generator/KvResizeCanvas.tsx
git commit -m "feat(web): flatten layer-only tiles without a base image"
```

---

### Task 4: Cover-scale a full-canvas background on aspect change

**Files:**
- Modify: `web/src/lib/studio/kv/overlayAspect.ts` (add two functions, extend `resolveTileOverlays`)
- Test: `web/src/lib/studio/kv/overlayAspect.test.ts`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `coverProjectOverlay(overlay, srcW, srcH, dstW, dstH): StudioOverlay`, exported for testing. `resolveTileOverlays` keeps its existing signature.

The default projection preserves each layer's pixel size, which is right for text and logos but leaves a full-bleed background short of the new frame. This is the "scale to cover, crop the overflow" behaviour from the spec.

- [ ] **Step 1: Write the failing tests**

Append to `overlayAspect.test.ts`:

```ts
describe("coverProjectOverlay", () => {
  const bg = (over: Partial<StudioOverlay> = {}): StudioOverlay =>
    ({
      id: "bg",
      studio_file_id: "f1",
      type: "image",
      x: 0,
      y: 0,
      width: 1,
      height: 1,
      rotation: 0,
      z: 0,
      payload: { type: "image", asset_url: "u", mime_type: "image/png" },
      created_at: "",
      updated_at: "",
      ...over,
    }) as StudioOverlay;

  it("fills a wider frame and lets the overflow run off the top and bottom", () => {
    const out = coverProjectOverlay(bg(), 1080, 1920, 1280, 720);

    expect(out.width).toBeCloseTo(1, 5);
    expect(out.height).toBeGreaterThan(1);
    expect(out.x).toBeCloseTo(0, 5);
    expect(out.y).toBeLessThanOrEqual(0);
  });

  it("leaves no gap at any edge", () => {
    const out = coverProjectOverlay(bg(), 1080, 1920, 1280, 720);

    expect(out.x).toBeLessThanOrEqual(1e-9);
    expect(out.y).toBeLessThanOrEqual(1e-9);
    expect(out.x + out.width).toBeGreaterThanOrEqual(1 - 1e-9);
    expect(out.y + out.height).toBeGreaterThanOrEqual(1 - 1e-9);
  });

  it("pulls a strongly off-centre background back so no edge gap appears", () => {
    const out = coverProjectOverlay(
      bg({ x: -0.6, y: 0, width: 1.8, height: 1.2 }),
      1080,
      1920,
      1080,
      1350,
    );

    // Honouring its own centre would leave a gap on the right, so it lands
    // flush against the right edge instead.
    expect(out.x + out.width).toBeCloseTo(1, 5);
    expect(out.x).toBeLessThanOrEqual(0);
  });

  it("returns the overlay untouched for degenerate dimensions", () => {
    const o = bg();
    expect(coverProjectOverlay(o, 0, 1920, 1280, 720)).toBe(o);
    expect(coverProjectOverlay(o, 1080, 1920, 1280, 0)).toBe(o);
  });
});

describe("resolveTileOverlays background handling", () => {
  const layer = (over: Partial<StudioOverlay>): StudioOverlay =>
    ({
      id: "x",
      studio_file_id: "f1",
      type: "image",
      x: 0,
      y: 0,
      width: 0.2,
      height: 0.1,
      rotation: 0,
      z: 5,
      payload: { type: "image", asset_url: "u", mime_type: "image/png" },
      created_at: "",
      updated_at: "",
      ...over,
    }) as StudioOverlay;

  it("cover-scales the lowest full-canvas layer and projects the rest normally", () => {
    const background = layer({ id: "bg", z: 0, x: 0, y: 0, width: 1, height: 1 });
    const headline = layer({ id: "headline", z: 5, x: 0.05, y: 0.3 });

    const out = resolveTileOverlays(
      null,
      [background, headline],
      1080,
      1920,
      1280,
      720,
    );

    const outBg = out.find((o) => o.id === "bg")!;
    expect(outBg.width).toBeCloseTo(1, 5);
    expect(outBg.height).toBeGreaterThan(1);

    const outHeadline = out.find((o) => o.id === "headline")!;
    expect(outHeadline.height).toBeLessThan(1);
  });

  it("leaves everything alone when the aspect is unchanged", () => {
    const background = layer({ id: "bg", z: 0, x: 0, y: 0, width: 1, height: 1 });

    const out = resolveTileOverlays(null, [background], 1080, 1920, 1080, 1920);

    expect(out[0].width).toBe(1);
    expect(out[0].height).toBe(1);
    expect(out[0].x).toBe(0);
    expect(out[0].y).toBe(0);
  });

  it("does not cover-scale when no layer covers the canvas", () => {
    const small = layer({ id: "small", z: 0, x: 0.1, y: 0.1, width: 0.3, height: 0.2 });

    const out = resolveTileOverlays(null, [small], 1080, 1920, 1280, 720);

    expect(out[0].width).toBeLessThan(1);
  });
});
```

Import `coverProjectOverlay` alongside the existing imports at the top of the test file, and `StudioOverlay` from `@/types/studio` if it is not already imported.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web && bun test src/lib/studio/kv/overlayAspect.test.ts`

Expected: the `coverProjectOverlay` block FAILS on the missing export. The "leaves everything alone when the aspect is unchanged" and "does not cover-scale" cases already PASS — they are regression guards.

- [ ] **Step 3: Add the cover projection**

Add to `overlayAspect.ts`, next to `transformOverlayForAspect`:

```ts
/** Scale a full-canvas background so it still covers the target frame, then
 *  crop the overflow — an artboard resize, not a generation. The layer's own
 *  centre is preserved so the artist's framing survives, and the result is
 *  nudged back inside so no edge gap can appear. */
export function coverProjectOverlay(
  overlay: StudioOverlay,
  srcW: number,
  srcH: number,
  dstW: number,
  dstH: number,
): StudioOverlay {
  if (srcW <= 0 || srcH <= 0 || dstW <= 0 || dstH <= 0) return overlay;

  const pxW = overlay.width * srcW;
  const pxH = overlay.height * srcH;
  if (pxW <= 0 || pxH <= 0) return overlay;

  const scale = Math.max(dstW / pxW, dstH / pxH);
  const newW = (pxW * scale) / dstW;
  const newH = (pxH * scale) / dstH;

  const cx = overlay.x + overlay.width / 2;
  const cy = overlay.y + overlay.height / 2;

  // Valid range is [1 - new, 0]: left edge at or left of 0, right edge at or
  // right of 1. Cover guarantees new >= 1, so the range is never empty.
  const newX = Math.min(0, Math.max(cx - newW / 2, 1 - newW));
  const newY = Math.min(0, Math.max(cy - newH / 2, 1 - newH));

  return { ...overlay, x: newX, y: newY, width: newW, height: newH };
}

/** The background is the bottom-most layer that already covers the whole
 *  source canvas. A KV with no such layer has no background, which is a
 *  valid shape — every layer then projects normally. */
function backgroundLayerId(overlays: StudioOverlay[]): string | null {
  const covering = overlays.filter(
    (o) => o.x <= 0 && o.y <= 0 && o.x + o.width >= 1 && o.y + o.height >= 1,
  );
  if (covering.length === 0) return null;
  return covering.reduce((lowest, o) => (o.z < lowest.z ? o : lowest)).id;
}
```

- [ ] **Step 4: Use it in `resolveTileOverlays`**

At the end of `resolveTileOverlays`, replace the final return at `:494-496`:

```ts
  const projected = pairs.map(({ src, out }) =>
    scaleTextStylingWithHeight(clampOverlayToCanvas(out), src),
  );

  // Cover-scale the background after the fact and match by id: group
  // projection can reorder `pairs`, so positional indexing is not safe.
  const bgId = backgroundLayerId(projectOverlays);
  if (bgId === null) return projected;

  const source = projectOverlays.find((o) => o.id === bgId);
  if (!source) return projected;

  return projected.map((o) =>
    o.id === bgId ? coverProjectOverlay(source, srcW, srcH, dstW, dstH) : o,
  );
```

This sits after the same-aspect fast path's early return, so an identical-size resize never reaches it and stays pixel-exact.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd web && bun test src/lib/studio/kv/overlayAspect.test.ts`

Expected: the whole file passes — the new blocks plus all pre-existing `transformOverlayForAspect`, `resolveTileOverlays`, coverage-cap and text-styling suites.

- [ ] **Step 6: Commit**

```bash
cd web && git add src/lib/studio/kv/overlayAspect.ts src/lib/studio/kv/overlayAspect.test.ts
git commit -m "feat(web): cover-scale a full-canvas background on resize"
```

---

## Verification after all tasks

- [ ] Run every touched suite:

```bash
cd web && bun test src/lib/studio/kv/overlayAspect.test.ts src/components/studio/kv-generator/
```

- [ ] Run the real build gate (types are not checked by `bun test`):

```bash
cd web && bun run build
```

- [ ] Manual check, once api Tasks 1–4 are also merged: import the PSD from the bug report, resize to TikTok Video and YouTube Thumbnail. Both tiles should show the artwork immediately with no spinner and no credit spend. Download one tile and confirm the PNG contains the artwork. Move a layer on one tile and confirm the master and the other tile are unchanged.

## Notes for the reviewer

- Task 2 widens the `done` branch, which would also catch an AI tile that somehow completed without an image. That is deliberate: such a tile has layers to draw and is better shown than hidden behind a false error. Genuine failures still land in the error branch via `status === "failed"`.
- `KvResizeTileStage.tsx` is untouched. It hard-returns a placeholder when `baseImageUrl` is null, but it is only used by `KvResizeOriginalRow` for the read-only master row, which always has a base.
- Cover projection may shrink a background that was drawn larger than the canvas, since it scales to exactly cover. That keeps behaviour predictable, at the cost of some deliberate bleed. The spec flags this — the reported KV has four full-canvas layers and only the bottom-most is cover-scaled, so the result is worth eyeballing on the real file before this ships.
- PostHog events are not part of this plan. Before calling the feature done, run the `frndos-analytics-events` skill over the new resize path — a layer-composed resize is a distinct, free, instant flow and the existing resize events assume an AI call.
