# KV Resize Region Edit — web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the frame tool draw a bounding box on a resize tile, carry a prompt on it, and send it through the composer that already drives guided regenerate.

**Architecture:** `tool === "frame"` stops being a no-op on the Resize tile editor and seeds a rubber-band marquee in tile-normalized coordinates. Boxes live in `KvResizeCanvas`, keyed by export id so they never leak between ratios. Drawing a box arms that tile, so the existing chat chip and Send path carry the edit — the only fork is which mutation Send calls.

**Tech Stack:** Next.js 16, React 19, TypeScript, react-konva, Zustand, TanStack Query v5, `bun test`.

**Spec:** `docs/superpowers/specs/2026-08-20-kv-resize-region-edit-design.md`

## Global Constraints

- **Tests run with `bun test`** (bunfig preloads jest-dom). Not `bunx vitest`.
- **There is no type gate.** The build sets `ignoreBuildErrors` and `tsc` carries a ~777-error baseline, so diff `tsc` output against a baseline worktree rather than expecting zero.
- **RTL `screen` is broken under bun.** Use `within(document.body)`. A single misuse fails all ~129 component tests, which reads as "everything is broken".
- **jsdom cannot dispatch Konva pointer events.** `KvTileOverlayEditor` already carries `__testCommitDragEnd` / `__testCommitTransformEnd` for exactly this. Follow that seam; do not invent a different one, and do not skip the test because "Konva can't be tested".
- **Boxes are ephemeral.** They live in component state, are never PATCHed, and are dropped when the tile is regenerated or the file is left.
- **Coordinates are normalized `[0,1]` against the tile frame** — the same convention `KvBoundingBox` uses on every other surface.
- **Do not touch the master row.** `KvResizeOriginalRow` is out of scope.
- **PostHog events are part of the feature.** Before calling this done, invoke `frndos-analytics-events` for the new interactions.
- **A dev server is running on `web/` (develop).** Editing files mid-session triggers HMR in someone else's browser; coordinate before large edits.

## File Structure

| File | Responsibility |
|---|---|
| `src/components/studio/kv-generator/tileMarquee.ts` (create) | Pure geometry: drag rect in display px → normalized `KvBoundingBox` |
| `src/components/studio/kv-generator/KvTileOverlayEditor.tsx` (modify) | Frame-tool marquee, box rendering, inline prompt editor |
| `src/components/studio/kv-generator/KvResizeResultRow.tsx` (modify) | Forward box props |
| `src/components/studio/kv-generator/KvResizeCanvas.tsx` (modify) | Own `boxesByExportId`, arm on draw |
| `src/services/kv/api.ts` (modify) | `editResizeExportRegion` |
| `src/components/studio/kv-generator/KvGeneratorLayout.tsx` (modify) | Fork Send between `regenerate` and `editRegion` |

`tileMarquee.ts` is a separate file because it is the only part of this feature that jsdom can exercise directly, and geometry bugs here are invisible until export.

---

### Task 1: Marquee geometry

**Files:**
- Create: `src/components/studio/kv-generator/tileMarquee.ts`
- Test: `src/components/studio/kv-generator/tileMarquee.test.ts`

**Interfaces:**
- Produces:
  - `type MarqueeDraft = { startX: number; startY: number; x: number; y: number }` — display pixels.
  - `marqueeToBox(draft: MarqueeDraft, displayWidth: number, displayHeight: number, id: string): KvBoundingBox | null` — normalized box, or `null` when the drag is smaller than `MIN_BOX_PX` on either axis.
  - `MIN_BOX_PX = 8`.

- [ ] **Step 1: Write the failing test**

```ts
import { describe, expect, it } from "bun:test";

import { marqueeToBox, MIN_BOX_PX } from "./tileMarquee";

describe("marqueeToBox", () => {
  it("normalizes a drag against the tile's display size", () => {
    const box = marqueeToBox(
      { startX: 100, startY: 200, x: 300, y: 400 },
      1000,
      2000,
      "b1",
    );

    expect(box).toEqual({
      id: "b1",
      x: 0.1,
      y: 0.1,
      width: 0.2,
      height: 0.1,
    });
  });

  it("normalizes a drag made upward and leftward", () => {
    const box = marqueeToBox(
      { startX: 300, startY: 400, x: 100, y: 200 },
      1000,
      2000,
      "b1",
    );

    expect(box?.x).toBeCloseTo(0.1);
    expect(box?.y).toBeCloseTo(0.1);
    expect(box?.width).toBeCloseTo(0.2);
    expect(box?.height).toBeCloseTo(0.1);
  });

  it("clamps a drag that runs past the tile edge", () => {
    const box = marqueeToBox(
      { startX: 900, startY: 100, x: 1400, y: 300 },
      1000,
      2000,
      "b1",
    );

    expect(box!.x + box!.width).toBeLessThanOrEqual(1);
    expect(box!.x).toBeCloseTo(0.9);
  });

  it("rejects a click that never became a drag", () => {
    const tiny = MIN_BOX_PX - 1;
    expect(
      marqueeToBox({ startX: 10, startY: 10, x: 10 + tiny, y: 10 + tiny }, 1000, 2000, "b1"),
    ).toBeNull();
  });
});
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
cd web && bun test src/components/studio/kv-generator/tileMarquee.test.ts
```

Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

```ts
import type { KvBoundingBox } from "@/types/studio";

/** A drag below this on either axis is a click, not a marquee. Without it,
 *  every stray click on the tile would mint a degenerate zero-area box that
 *  the mask builder cannot punch. */
export const MIN_BOX_PX = 8;

export type MarqueeDraft = {
  startX: number;
  startY: number;
  x: number;
  y: number;
};

/**
 * Convert a drag in tile display pixels into a `[0,1]`-normalized box.
 *
 * Normalizing against the DISPLAY size (not the tile's target pixel size) is
 * what makes the box survive zoom: the caller hands us the same numbers the
 * Konva stage was laid out with, and the box means the same fraction of the
 * frame at any camera scale.
 *
 * Returns null when the drag never cleared MIN_BOX_PX.
 */
export function marqueeToBox(
  draft: MarqueeDraft,
  displayWidth: number,
  displayHeight: number,
  id: string,
): KvBoundingBox | null {
  if (displayWidth <= 0 || displayHeight <= 0) return null;

  const left = Math.min(draft.startX, draft.x);
  const top = Math.min(draft.startY, draft.y);
  const right = Math.max(draft.startX, draft.x);
  const bottom = Math.max(draft.startY, draft.y);

  if (right - left < MIN_BOX_PX || bottom - top < MIN_BOX_PX) return null;

  const clampedLeft = Math.max(0, Math.min(left, displayWidth));
  const clampedTop = Math.max(0, Math.min(top, displayHeight));
  const clampedRight = Math.max(0, Math.min(right, displayWidth));
  const clampedBottom = Math.max(0, Math.min(bottom, displayHeight));

  return {
    id,
    x: clampedLeft / displayWidth,
    y: clampedTop / displayHeight,
    width: (clampedRight - clampedLeft) / displayWidth,
    height: (clampedBottom - clampedTop) / displayHeight,
  };
}
```

- [ ] **Step 4: Run the tests**

```bash
cd web && bun test src/components/studio/kv-generator/tileMarquee.test.ts
```

Expected: 4 pass.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/tileMarquee.ts src/components/studio/kv-generator/tileMarquee.test.ts
git commit -m "feat(web): marquee geometry for resize tile bounding boxes"
```

---

### Task 2: Frame tool on the tile editor

**Files:**
- Modify: `src/components/studio/kv-generator/KvTileOverlayEditor.tsx` (props ~35-95; Stage `onClick` ~503; overlay `<Layer>` ~538)
- Test: `src/components/studio/kv-generator/KvTileOverlayEditor.boxes.test.tsx`

**Interfaces:**
- Consumes: `marqueeToBox`, `MIN_BOX_PX` (Task 1).
- Produces, on `KvTileOverlayEditor`'s props:
  - `boxes?: KvBoundingBox[]` (default `[]`)
  - `onBoxesChange?: (next: KvBoundingBox[]) => void`
  - `activeBoxId?: string | null`
  - `onActiveBoxIdChange?: (id: string | null) => void`
  - `__testCommitMarquee?: { id: string; startX: number; startY: number; x: number; y: number }` — test seam mirroring `__testCommitDragEnd`.

- [ ] **Step 1: Write the failing test**

```tsx
import { describe, expect, it, mock } from "bun:test";
import { render, within } from "@testing-library/react";

import { KvTileOverlayEditor } from "./KvTileOverlayEditor";

const BASE = {
  overlays: [],
  selectedId: null,
  onChange: () => {},
  onSelect: () => {},
  baseImageUrl: null,
  targetWidth: 1080,
  targetHeight: 1920,
  displayWidth: 500,
  isActive: true,
};

describe("KvTileOverlayEditor frame tool", () => {
  it("commits a normalized box when a marquee is drawn", () => {
    const onBoxesChange = mock(() => {});

    render(
      <KvTileOverlayEditor
        {...BASE}
        tool="frame"
        boxes={[]}
        onBoxesChange={onBoxesChange}
        __testCommitMarquee={{ id: "b1", startX: 50, startY: 100, x: 150, y: 300 }}
      />,
    );

    expect(onBoxesChange).toHaveBeenCalledTimes(1);
    const next = onBoxesChange.mock.calls[0][0];
    expect(next).toHaveLength(1);
    expect(next[0].x).toBeCloseTo(0.1);
  });

  it("appends rather than replacing existing boxes", () => {
    const onBoxesChange = mock(() => {});
    const existing = { id: "b0", x: 0, y: 0, width: 0.1, height: 0.1 };

    render(
      <KvTileOverlayEditor
        {...BASE}
        tool="frame"
        boxes={[existing]}
        onBoxesChange={onBoxesChange}
        __testCommitMarquee={{ id: "b1", startX: 50, startY: 100, x: 150, y: 300 }}
      />,
    );

    const next = onBoxesChange.mock.calls[0][0];
    expect(next.map((b: { id: string }) => b.id)).toEqual(["b0", "b1"]);
  });

  it("ignores a marquee too small to be a drag", () => {
    const onBoxesChange = mock(() => {});

    render(
      <KvTileOverlayEditor
        {...BASE}
        tool="frame"
        boxes={[]}
        onBoxesChange={onBoxesChange}
        __testCommitMarquee={{ id: "b1", startX: 50, startY: 50, x: 52, y: 52 }}
      />,
    );

    expect(onBoxesChange).not.toHaveBeenCalled();
  });

  it("stays inert on an inactive tile", () => {
    const onBoxesChange = mock(() => {});

    render(
      <KvTileOverlayEditor
        {...BASE}
        isActive={false}
        tool="frame"
        boxes={[]}
        onBoxesChange={onBoxesChange}
        __testCommitMarquee={{ id: "b1", startX: 50, startY: 100, x: 150, y: 300 }}
      />,
    );

    expect(onBoxesChange).not.toHaveBeenCalled();
  });

  it("still renders the editor container", () => {
    const { container } = render(<KvTileOverlayEditor {...BASE} tool="frame" />);
    expect(
      within(document.body).getByTestId("tile-overlay-editor"),
    ).toBeInTheDocument();
    expect(container).toBeTruthy();
  });
});
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
cd web && bun test src/components/studio/kv-generator/KvTileOverlayEditor.boxes.test.tsx
```

Expected: FAIL — `onBoxesChange` is never called; the prop does not exist.

- [ ] **Step 3: Implement the props and the test seam**

Add the five props to the `Props` type with the doc comments describing them, destructure them with `boxes = []`, and add the commit effect beside the existing `__testCommitDragEnd` effect:

```tsx
// Test seam, mirroring __testCommitDragEnd: jsdom cannot dispatch Konva
// pointer events, so component tests drive the marquee through a prop
// instead of a fake drag.
useEffect(() => {
  if (!__testCommitMarquee) return;
  commitMarquee(__testCommitMarquee, __testCommitMarquee.id);
  // eslint-disable-next-line react-hooks/exhaustive-deps
}, [__testCommitMarquee]);
```

with the shared commit path used by both the seam and the real gesture:

```tsx
const commitMarquee = useCallback(
  (draft: MarqueeDraft, id: string) => {
    if (!isActive || !onBoxesChange) return;
    const box = marqueeToBox(draft, displayWidth, displayHeight, id);
    if (!box) return;
    onBoxesChange([...boxes, box]);
    onActiveBoxIdChange?.(box.id);
  },
  [isActive, onBoxesChange, displayWidth, displayHeight, boxes, onActiveBoxIdChange],
);
```

- [ ] **Step 4: Wire the real gesture**

On the Stage, when `tool === "frame"` and `isActive`, seed a draft on `onMouseDown` / `onTouchStart`, track it on move, and commit on `onMouseUp` / `onTouchEnd` with `crypto.randomUUID()` as the id. Keep the draft in a ref plus a state mirror, following the pattern the file already uses for drag guides. Render the live draft as a dashed `<Rect>` in the overlay `<Layer>`, and the committed `boxes` as dashed rects with their index label — matching Craft's marquee affordance.

While `tool === "frame"`, overlay nodes must not steal the gesture: pass `listening={tool !== "frame"}` on the overlay nodes so a marquee can start on top of an overlay.

- [ ] **Step 5: Run the tests**

```bash
cd web && bun test src/components/studio/kv-generator/KvTileOverlayEditor.boxes.test.tsx
cd web && bun test src/components/studio/kv-generator/KvTileOverlayEditor.test.tsx
```

Expected: the new file passes; the existing `KvTileOverlayEditor` tests show no new failures.

- [ ] **Step 6: Commit**

```bash
git add src/components/studio/kv-generator/KvTileOverlayEditor.tsx src/components/studio/kv-generator/KvTileOverlayEditor.boxes.test.tsx
git commit -m "feat(web): frame tool marquee on resize tiles"
```

---

### Task 3: Inline prompt editor on the active box

**Files:**
- Modify: `src/components/studio/kv-generator/KvTileOverlayEditor.tsx`
- Test: `src/components/studio/kv-generator/KvTileOverlayEditor.boxes.test.tsx` (extend)

**Interfaces:**
- Consumes: `boxes`, `activeBoxId`, `onBoxesChange` (Task 2).
- Produces: a `<textarea>` positioned over the active box, `data-testid="box-prompt-input"`, committing to that box's `prompt` on blur and on Enter (Shift+Enter inserts a newline), mirroring Craft's `promptDraft` behaviour.

- [ ] **Step 1: Write the failing test**

```tsx
import { fireEvent } from "@testing-library/react";

it("writes the typed prompt onto the active box", () => {
  const onBoxesChange = mock(() => {});
  const box = { id: "b1", x: 0.1, y: 0.1, width: 0.2, height: 0.2 };

  render(
    <KvTileOverlayEditor
      {...BASE}
      tool="frame"
      boxes={[box]}
      activeBoxId="b1"
      onBoxesChange={onBoxesChange}
    />,
  );

  const input = within(document.body).getByTestId("box-prompt-input");
  fireEvent.change(input, { target: { value: "remove the smudge" } });
  fireEvent.blur(input);

  expect(onBoxesChange).toHaveBeenCalled();
  const next = onBoxesChange.mock.calls.at(-1)![0];
  expect(next[0].prompt).toBe("remove the smudge");
});

it("shows no prompt input when no box is active", () => {
  render(<KvTileOverlayEditor {...BASE} tool="frame" boxes={[]} activeBoxId={null} />);

  expect(
    within(document.body).queryByTestId("box-prompt-input"),
  ).toBeNull();
});
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
cd web && bun test src/components/studio/kv-generator/KvTileOverlayEditor.boxes.test.tsx
```

Expected: FAIL — `box-prompt-input` not found.

- [ ] **Step 3: Implement**

Render the textarea as an absolutely-positioned DOM element inside the existing wrapper `<div>` (the one carrying `data-testid="tile-overlay-editor"`), not inside the Konva tree — the file already does this for `OverlayTextEditor`. Position it from the active box's normalized rect times `displayWidth` / `displayHeight`. Commit on blur and on Enter without Shift.

- [ ] **Step 4: Run the tests**

```bash
cd web && bun test src/components/studio/kv-generator/KvTileOverlayEditor.boxes.test.tsx
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/KvTileOverlayEditor.tsx src/components/studio/kv-generator/KvTileOverlayEditor.boxes.test.tsx
git commit -m "feat(web): inline prompt editor on a resize tile box"
```

---

### Task 4: Per-tile box state, and arming on draw

**Files:**
- Modify: `src/components/studio/kv-generator/KvResizeResultRow.tsx` (props ~39-113; `<KvTileOverlayEditor>` ~229)
- Modify: `src/components/studio/kv-generator/KvResizeCanvas.tsx` (state ~190; `<KvResizeResultRow>` ~1077)
- Test: `src/components/studio/kv-generator/KvResizeCanvas.boxes.test.tsx`

**Interfaces:**
- Consumes: the editor props from Tasks 2-3.
- Produces:
  - `KvResizeResultRow` forwards `boxes`, `onBoxesChange`, `activeBoxId`, `onActiveBoxIdChange`.
  - `KvResizeCanvas` owns `boxesByExportId: Record<string, KvBoundingBox[]>` and `activeBoxId: string | null`; committing a box for row `R` calls `armRegenerate(R.id)` and `setActiveTileId(R.id)`.

- [ ] **Step 1: Write the failing test**

```tsx
import { describe, expect, it } from "bun:test";

import { boxesForExport, withBoxesForExport } from "./KvResizeCanvas";

describe("per-tile box state", () => {
  it("returns an empty list for a tile that has none", () => {
    expect(boxesForExport({}, "exp-1")).toEqual([]);
  });

  it("keeps each tile's boxes to itself", () => {
    const box = { id: "b1", x: 0, y: 0, width: 0.1, height: 0.1 };
    const state = withBoxesForExport({}, "exp-1", [box]);

    expect(boxesForExport(state, "exp-1")).toHaveLength(1);
    expect(boxesForExport(state, "exp-2")).toEqual([]);
  });

  it("replaces one tile's boxes without disturbing another's", () => {
    const a = { id: "a", x: 0, y: 0, width: 0.1, height: 0.1 };
    const b = { id: "b", x: 0, y: 0, width: 0.2, height: 0.2 };
    let state = withBoxesForExport({}, "exp-1", [a]);
    state = withBoxesForExport(state, "exp-2", [b]);
    state = withBoxesForExport(state, "exp-1", []);

    expect(boxesForExport(state, "exp-1")).toEqual([]);
    expect(boxesForExport(state, "exp-2")).toHaveLength(1);
  });
});
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
cd web && bun test src/components/studio/kv-generator/KvResizeCanvas.boxes.test.tsx
```

Expected: FAIL — the helpers are not exported.

- [ ] **Step 3: Implement the helpers**

Export from `KvResizeCanvas.tsx` (pure, so they are testable without mounting the canvas):

```tsx
export type BoxesByExport = Record<string, KvBoundingBox[]>;

/** Boxes belong to ONE tile. Keying by export id is what stops a box drawn on
 *  the Story tile from appearing on the LinkedIn tile — they are different
 *  frames, and a normalized rect means a different region on each. */
export function boxesForExport(state: BoxesByExport, exportId: string): KvBoundingBox[] {
  return state[exportId] ?? [];
}

export function withBoxesForExport(
  state: BoxesByExport,
  exportId: string,
  next: KvBoundingBox[],
): BoxesByExport {
  return { ...state, [exportId]: next };
}
```

- [ ] **Step 4: Wire the state and the arming**

In `KvResizeCanvas`, add `const [boxesByExportId, setBoxesByExportId] = useState<BoxesByExport>({})` and `const [activeBoxId, setActiveBoxId] = useState<string | null>(null)`. Pass them down per row, and on commit:

```tsx
onBoxesChange={(next) => {
  setBoxesByExportId((s) => withBoxesForExport(s, row.id, next));
  // Drawing a box IS the intent to edit this tile: arm it so the composer's
  // chip names the right target, exactly as pressing ⟳ would.
  setActiveTileId(row.id);
  if (armedRegenerate !== row.id) armRegenerate(row.id);
}}
```

Clear a tile's boxes whenever its status leaves `done` — a regenerate discards the edit, so leaving stale boxes on screen would imply otherwise.

Track which tiles have had a region edit land (`regionEditedExportIds: Set<string>`, cleared on regenerate) and use it for the spec's warning: when the user arms a regenerate on such a tile, the composer notes that regenerating rebuilds the tile from its source and discards the region edit. The set is client-only — after a reload the warning is simply absent, which is acceptable because the boxes are gone too.

- [ ] **Step 5: Forward the props through the row**

Add the four props to `KvResizeResultRow`'s `Props` with doc comments, and pass them into `<KvTileOverlayEditor>` alongside the existing ones.

- [ ] **Step 6: Run the tests**

```bash
cd web && bun test src/components/studio/kv-generator/KvResizeCanvas.boxes.test.tsx
cd web && bun test src/components/studio/kv-generator/KvResizeResultRow.test.tsx
```

Expected: new tests pass; the row's existing tests show no new failures.

- [ ] **Step 7: Commit**

```bash
git add src/components/studio/kv-generator/KvResizeCanvas.tsx src/components/studio/kv-generator/KvResizeResultRow.tsx src/components/studio/kv-generator/KvResizeCanvas.boxes.test.tsx
git commit -m "feat(web): per-tile box state, armed on draw"
```

---

### Task 5: The API client call

**Files:**
- Modify: `src/services/kv/api.ts` (beside `regenerateResizeExport`, line 773)
- Test: `src/services/kv/editResizeExportRegion.test.ts`

**Interfaces:**
- Produces: `editResizeExportRegion(fileId: string, exportId: string, boxes: KvBoundingBox[]): Promise<KvResizeExport>` — POSTs `{ bounding_boxes }` to `v1/studio/files/{fileId}/resize-exports/{exportId}/edit-region` and maps the response through the existing `toResizeExport`.

- [ ] **Step 1: Write the failing test**

```ts
import { describe, expect, it, mock } from "bun:test";

mock.module("@/lib/axios", () => ({
  default: { post: mock(async () => ({ data: { data: WIRE } })) },
}));

const WIRE = {
  id: "exp-1",
  studio_file_id: "file-1",
  parent_generation_id: "gen-1",
  platform_id: "instagram-story",
  width: 1080,
  height: 1920,
  image_url: "https://cdn.test/tile.png",
  status: "pending",
  crop_window: null,
  overlays: null,
  error_message: null,
  created_at: "2026-08-20T00:00:00Z",
  updated_at: "2026-08-20T00:00:00Z",
};

describe("editResizeExportRegion", () => {
  it("posts the boxes to the edit-region endpoint", async () => {
    const { editResizeExportRegion } = await import("./api");
    const axios = (await import("@/lib/axios")).default;

    const boxes = [{ id: "b1", x: 0.1, y: 0.1, width: 0.2, height: 0.2, prompt: "fix" }];
    const row = await editResizeExportRegion("file-1", "exp-1", boxes);

    expect(axios.post).toHaveBeenCalledWith(
      "v1/studio/files/file-1/resize-exports/exp-1/edit-region",
      { bounding_boxes: boxes },
    );
    expect(row.id).toBe("exp-1");
    expect(row.status).toBe("pending");
  });
});
```

Check `src/services/kv/` for the module path and mocking style its existing tests use, and match it — the import path above is illustrative of the shape, not a guess to keep if the repo differs.

- [ ] **Step 2: Run it to confirm it fails**

```bash
cd web && bun test src/services/kv/editResizeExportRegion.test.ts
```

Expected: FAIL — export not found.

- [ ] **Step 3: Implement**

```ts
/** Repaint one or more regions of a single resize tile. Unlike
 *  `regenerateResizeExport`, the tile's current image is the INPUT — the
 *  server keeps `image_url` in place and the edit is applied on top of it. */
export async function editResizeExportRegion(
  fileId: string,
  exportId: string,
  boxes: import("@/types/studio").KvBoundingBox[],
): Promise<KvResizeExport> {
  const { data } = await axiosInstance.post(
    `v1/studio/files/${fileId}/resize-exports/${exportId}/edit-region`,
    { bounding_boxes: boxes },
  );
  return toResizeExport(unwrap<WireResizeExport>(data));
}
```

- [ ] **Step 4: Run the test**

```bash
cd web && bun test src/services/kv/editResizeExportRegion.test.ts
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/services/kv/api.ts src/services/kv/editResizeExportRegion.test.ts
git commit -m "feat(web): edit-region api client"
```

---

### Task 6: Fork Send between regenerate and region edit

**Files:**
- Modify: `src/components/studio/kv-generator/KvGeneratorLayout.tsx` (`resizeRegenerate`, lines 2019-2044)
- Test: `src/components/studio/kv-generator/resizeSendTarget.test.ts`
- Create: `src/components/studio/kv-generator/resizeSendTarget.ts`

**Interfaces:**
- Consumes: `boxesForExport` (Task 4), `editResizeExportRegion` (Task 5).
- Produces: `resolveResizeSend(boxes: KvBoundingBox[], additionalPrompt: string): { kind: "region"; boxes: KvBoundingBox[] } | { kind: "regenerate"; additionalPrompt: string }` — a pure decision function, so the fork is testable without mounting the 4600-line layout.

Boxes carrying no prompt of their own inherit the composer's text, matching Craft, where one message applies to every box drawn.

- [ ] **Step 1: Write the failing test**

```ts
import { describe, expect, it } from "bun:test";

import { resolveResizeSend } from "./resizeSendTarget";

const box = (over = {}) => ({ id: "b1", x: 0.1, y: 0.1, width: 0.2, height: 0.2, ...over });

describe("resolveResizeSend", () => {
  it("regenerates when no box was drawn", () => {
    expect(resolveResizeSend([], "make it warmer")).toEqual({
      kind: "regenerate",
      additionalPrompt: "make it warmer",
    });
  });

  it("routes to a region edit once a box exists", () => {
    const result = resolveResizeSend([box()], "remove the smudge");
    expect(result.kind).toBe("region");
  });

  it("gives a promptless box the composer's text", () => {
    const result = resolveResizeSend([box()], "remove the smudge");
    if (result.kind !== "region") throw new Error("expected a region edit");
    expect(result.boxes[0].prompt).toBe("remove the smudge");
  });

  it("leaves a box that already carries its own prompt alone", () => {
    const result = resolveResizeSend([box({ prompt: "make it blue" })], "remove the smudge");
    if (result.kind !== "region") throw new Error("expected a region edit");
    expect(result.boxes[0].prompt).toBe("make it blue");
  });
});
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
cd web && bun test src/components/studio/kv-generator/resizeSendTarget.test.ts
```

Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

```ts
import type { KvBoundingBox } from "@/types/studio";

export type ResizeSend =
  | { kind: "region"; boxes: KvBoundingBox[] }
  | { kind: "regenerate"; additionalPrompt: string };

/**
 * Decide what Send means for the armed tile.
 *
 * A drawn box is the whole signal: it says "change THIS part", which the
 * whole-tile regenerate cannot express. A box with no prompt of its own
 * inherits the composer's text, so one message can drive several boxes —
 * the same way Craft applies one chat message to every box on the canvas.
 */
export function resolveResizeSend(
  boxes: KvBoundingBox[],
  additionalPrompt: string,
): ResizeSend {
  if (boxes.length === 0) {
    return { kind: "regenerate", additionalPrompt };
  }

  return {
    kind: "region",
    boxes: boxes.map((b) => ({ ...b, prompt: b.prompt ?? additionalPrompt })),
  };
}
```

- [ ] **Step 4: Wire it into the layout**

In the `resizeRegenerate` memo, replace the single `regenerateResize.mutate(...)` call with the fork, and clear the tile's boxes once the mutation is dispatched:

```tsx
onSubmit: (additionalPrompt: string) => {
  const decision = resolveResizeSend(
    boxesForExport(boxesByExportId, armedExport.id),
    additionalPrompt,
  );
  if (decision.kind === "region") {
    editResizeRegion.mutate({ exportId: armedExport.id, boxes: decision.boxes });
  } else {
    regenerateResize.mutate({
      exportId: armedExport.id,
      additionalPrompt: decision.additionalPrompt,
    });
  }
},
```

`boxesByExportId` currently lives in `KvResizeCanvas`. Lift it to `KvGeneratorLayout` and pass it down, matching how `armedRegenerate` already lives in the store and is read by both — do not duplicate the state in two places.

Add the `editResizeRegion` mutation beside `regenerateResize`, using the same `onSuccess` cache-update shape that mutation already uses.

- [ ] **Step 5: Run the tests**

```bash
cd web && bun test src/components/studio/kv-generator/resizeSendTarget.test.ts
cd web && bun test src/components/studio/kv-generator
```

Expected: new tests pass; the directory's failure count matches the baseline recorded before starting.

- [ ] **Step 6: Commit**

```bash
git add src/components/studio/kv-generator/resizeSendTarget.ts src/components/studio/kv-generator/resizeSendTarget.test.ts src/components/studio/kv-generator/KvGeneratorLayout.tsx src/components/studio/kv-generator/KvResizeCanvas.tsx
git commit -m "feat(web): send a resize tile's boxes as a region edit"
```

---

### Task 7: Object select on a tile

**Files:**
- Modify: `src/services/kv/api.ts` (beside `detectObjects`, line 530)
- Modify: `src/components/studio/kv-generator/KvTileOverlayEditor.tsx`
- Test: `src/components/studio/kv-generator/boxFromCandidate.test.ts`
- Create: `src/components/studio/kv-generator/boxFromCandidate.ts`

**Interfaces:**
- Consumes: the api's tile detect routes (api plan Task 6); `KvDetectedObject` from `@/types/studio`.
- Produces:
  - `detectTileObjects(fileId, exportId, region?): Promise<KvDetectedObject[]>` — the tile twin of `detectObjects`, posting to `v1/studio/kv-generator/files/{fileId}/resize-exports/{exportId}/detect`.
  - `boxFromCandidate(candidate: KvDetectedObject, id: string): KvBoundingBox` — turns a detected object into a box carrying `polygon`, `rings`, `label` and `objectId`.

This is what makes the feature feel like Craft rather than a crude rectangle: the mask is punched along the object's outline, so pixels inside the box but outside the object survive.

- [ ] **Step 1: Write the failing test**

```ts
import { describe, expect, it } from "bun:test";

import { boxFromCandidate } from "./boxFromCandidate";

const CANDIDATE = {
  id: "det-3",
  label: "Red CIMB Card",
  x: 0.2,
  y: 0.3,
  width: 0.25,
  height: 0.15,
  polygon: [[0.2, 0.3], [0.45, 0.3], [0.45, 0.45]],
};

describe("boxFromCandidate", () => {
  it("carries the outline and the label onto the box", () => {
    const box = boxFromCandidate(CANDIDATE as never, "b1");

    expect(box.polygon).toEqual(CANDIDATE.polygon);
    expect(box.label).toBe("Red CIMB Card");
  });

  it("keeps the detected object id so a re-pick can restore the prompt", () => {
    expect(boxFromCandidate(CANDIDATE as never, "b1").objectId).toBe("det-3");
  });

  it("copies the rectangle so a polygon-less candidate still masks", () => {
    const box = boxFromCandidate({ ...CANDIDATE, polygon: undefined } as never, "b1");

    expect(box.x).toBe(0.2);
    expect(box.width).toBe(0.25);
    expect(box.polygon).toBeUndefined();
  });

  it("carries glyph rings for a text candidate", () => {
    const rings = [[[0.2, 0.3], [0.25, 0.3], [0.25, 0.35]]];
    const box = boxFromCandidate({ ...CANDIDATE, rings } as never, "b1");

    expect(box.rings).toEqual(rings);
  });
});
```

- [ ] **Step 2: Run it to confirm it fails**

```bash
cd web && bun test src/components/studio/kv-generator/boxFromCandidate.test.ts
```

Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

```ts
import type { KvBoundingBox, KvDetectedObject } from "@/types/studio";

/**
 * Promote a detected object into a selection box.
 *
 * `polygon` / `rings` are what separate this from a hand-drawn rectangle:
 * ai-service punches the mask along them, so background between and inside
 * letters — and pixels inside the box but outside the object — survive the
 * regeneration. A candidate without them degrades to a plain rect, which is
 * still valid everywhere downstream.
 */
export function boxFromCandidate(
  candidate: KvDetectedObject,
  id: string,
): KvBoundingBox {
  return {
    id,
    x: candidate.x,
    y: candidate.y,
    width: candidate.width,
    height: candidate.height,
    polygon: candidate.polygon,
    rings: candidate.rings,
    label: candidate.label,
    // Client-only: keys prompt retention across unmark / re-pick, which the
    // box id cannot do. Never sent to the server.
    objectId: candidate.id,
  };
}
```

Add `detectTileObjects` to `src/services/kv/api.ts`, mirroring `detectObjects` exactly but against the resize-export path.

- [ ] **Step 4: Wire the picker**

On a click (not a drag) with `tool === "frame"` and `isActive`, call `detectTileObjects` with the clicked point as a small region, render the returned outlines as pickable candidates, and on pick push `boxFromCandidate(candidate, crypto.randomUUID())` through `onBoxesChange`. Follow the candidate-chip flow `KvFabricCanvas` uses (see its `onEnsureDetection` handling around line 3611) rather than designing a new affordance — the two surfaces should look the same.

Detection failures must be silent and non-blocking: the frame tool keeps working as a plain rectangle, which is the fallback `KvFabricCanvas` already documents.

- [ ] **Step 5: Run the tests**

```bash
cd web && bun test src/components/studio/kv-generator/boxFromCandidate.test.ts
cd web && bun test src/components/studio/kv-generator
```

Expected: new tests pass; no new failures against the baseline.

- [ ] **Step 6: Commit**

```bash
git add src/components/studio/kv-generator/boxFromCandidate.ts src/components/studio/kv-generator/boxFromCandidate.test.ts src/components/studio/kv-generator/KvTileOverlayEditor.tsx src/services/kv/api.ts
git commit -m "feat(web): object select for resize tile boxes"
```

---

### Task 8: Analytics

**Files:**
- Modify: wherever `trackKvCanvasToolSelected` and the resize tracking helpers live (see `KvCanvasBottomNav.tsx:314` for the established call shape)

- [ ] **Step 1: Invoke the analytics skill**

Run the `frndos-analytics-events` agent against this feature. New interactions worth an event: a box committed on a resize tile, and a Send that resolved to a region edit rather than a regenerate (carrying the box count, mirroring `box_count` in `useKvStream.ts:1251`).

- [ ] **Step 2: Commit**

```bash
git add -A && git commit -m "feat(web): analytics for resize region edits"
```

---

## Manual verification

Automated tests cannot exercise a Konva pointer gesture, so before calling this done, in the browser:

1. Open a KV with resize tiles, pick the frame tool, drag a box on a result tile → the box renders and the composer chip names that tile.
2. Type a prompt, press Send → the tile goes to `generating`, then returns with only that region changed.
3. Draw a box on a second tile → the first tile's box does not move or duplicate.
4. Zoom the viewport, then draw → the box lands where the cursor was.
5. Regenerate a tile that has a box → the box clears, and the composer warned first.
6. Click (not drag) with the frame tool → candidate outlines appear; pick one → the box hugs the object, not a rectangle.
7. With detection unavailable, the frame tool still draws plain rectangles.

## Done when

- The frame tool draws boxes on result tiles only, in normalized coordinates that survive zoom.
- A box carries its own prompt, or inherits the composer's.
- Send routes to `edit-region` when boxes exist and to `regenerate` when they do not.
- `bun test src/components/studio/kv-generator` shows no new failures against the pre-work baseline.
