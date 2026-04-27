# KV Canvas Reclaim + Floating Chat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the KV Generator canvas fill the viewport between top + bottom nav, move the chat to a fixed floating panel anchored bottom-right, scale overlay chrome (Transformer handles, rotation arm, color chip) with the overlay's pixel size, and bump the default text overlay to a headline-sized box. Spec: [`docs/superpowers/specs/2026-04-27-studio-kv-canvas-reclaim-design.md`](../specs/2026-04-27-studio-kv-canvas-reclaim-design.md).

**Architecture:** Pure frontend, web service only. The chat panel moves out of the flex flow into `position: fixed`. The canvas drops its `max-w: 900px / max-h: 70vh` caps and uses `flex-1` for sizing. A new `adaptiveSizing.ts` helper module isolates the chrome-scaling math (handle size, rotation offset, chip scale) so it can be unit tested. The color chip gains a `visible` prop that the canvas toggles off during overlay drag/transform.

**Tech Stack:** Next.js 16, React 19, TypeScript, Tailwind, react-konva, Zustand, Vitest, React Testing Library.

---

## File Structure

**New:**
- `web/src/components/studio/kv-generator/overlays/adaptiveSizing.ts` — pure helpers for handle size, rotation offset, chip scale
- `web/src/components/studio/kv-generator/overlays/adaptiveSizing.test.ts` — unit tests for the helpers

**Modify:**
- `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx` — float chat container; bump default text overlay size in `handlePlaceText`
- `web/src/components/studio/kv-generator/KvCanvas.tsx` — drop canvas caps in `KonvaStageFrame`; remove version label markup
- `web/src/components/studio/kv-generator/KvKonvaCanvas.tsx` — feed adaptive sizes into Transformer; pass `chipVisible` flag based on transform state
- `web/src/components/studio/kv-generator/overlays/OverlayColorChip.tsx` — accept `overlayWidthPx` and `visible` props; CSS-scale the chip; respect visibility
- `web/src/components/studio/kv-generator/KvCanvas.test.tsx` — drop assertions tied to the removed version label

No backend changes. No data model changes.

---

## Task 1: Float the chat panel

Take the chat container out of the flex flow so the canvas reclaims the 444px column. The chat becomes `position: fixed`, anchored bottom-right, ~24px from the right edge and ~96px above the bottom nav. The existing scale-from-bottom-right animation keeps working — fixed positioning doesn't affect `transform-origin`.

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx:305-365`

- [ ] **Step 1: Verify dev server runs cleanly before changes**

Run from repo root:
```bash
cd web && bun dev
```
Open `http://localhost:3000/studio/kv-generator/<any-file-id>` (or any KV file route) and confirm the canvas + docked chat render without console errors. Stop with Ctrl-C.

- [ ] **Step 2: Replace the chat flex column with a fixed-positioned wrapper**

In `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx`, find the section starting around line 305 (`{/* Middle row: canvas body (flex-1) + chat card (animated width) */}`). Replace the entire middle-row block:

```tsx
{/* Middle row: canvas body (flex-1) + chat card (animated width) */}
<div className="flex min-h-0 flex-1 overflow-hidden">
  <div className="flex min-h-0 flex-1 items-center justify-center overflow-hidden px-6">
    <KvCanvas ... />
  </div>

  {/* Chat column — floats in the middle row. ... */}
  <div
    className="shrink-0 overflow-hidden"
    style={{
      width: chatOpen ? 444 : 0,
      transition: "width 300ms ease-out",
    }}
    aria-hidden={!chatOpen}
  >
    <div className="flex h-full items-center pr-6">
      <div className={[...].join(" ")}>
        <KvChat ... />
      </div>
    </div>
  </div>
</div>
```

with:

```tsx
{/* Middle row: canvas fills the full work area; chat floats in a
    fixed-position panel anchored to the bottom-right corner. */}
<div className="flex min-h-0 flex-1 overflow-hidden">
  <div className="flex min-h-0 flex-1 items-center justify-center overflow-hidden px-6">
    <KvCanvas
      generations={stream.generations}
      pendingGeneration={stream.pendingGeneration}
      tool={canvasTool}
      boxes={boxes}
      onBoxesChange={setBoxes}
      overlays={overlays}
      overlaysHidden={isHidden}
      selectedOverlayId={selectedOverlayId}
      onSelectOverlay={setSelected}
      onUpdateOverlay={update}
      onRemoveOverlay={remove}
      onPlaceText={handlePlaceText}
      onPlaceImage={handlePlaceImage}
      editingTextId={editingTextId}
      onEditTextOverlay={handleEditTextOverlay}
      onChangeTextColor={handleChangeTextColor}
    />
  </div>
</div>

{/* Floating chat panel — fixed bottom-right, scales from the chat
    pill in the bottom nav (origin-bottom-right matches the pill's
    location on the screen). */}
<div
  className="fixed z-30"
  style={{
    right: 24,
    bottom: 96,
    width: 420,
    maxHeight: "calc(100vh - 64px - 80px - 32px)",
    pointerEvents: chatOpen ? "auto" : "none",
  }}
  aria-hidden={!chatOpen}
>
  <div
    className={[
      "h-full origin-bottom-right transition-[transform,opacity] duration-300 ease-out",
      chatOpen ? "scale-100 opacity-100" : "scale-0 opacity-0",
    ].join(" ")}
  >
    <KvChat
      title={file?.project_id ? title : "New Chat"}
      stream={stream}
      hasMessages={hasMessages}
      onMinimize={() => setChatOpen(false)}
      boxes={boxes}
      baseGenerationId={latestGenerationId}
      onRemoveBox={(id) =>
        setBoxes((prev) => prev.filter((b) => b.id !== id))
      }
      onClearBoxes={() => setBoxes([])}
      attachments={attachments}
      onAddAttachments={(next) =>
        setAttachments((prev) => [...prev, ...next])
      }
      onRemoveAttachment={removeAttachment}
      onClearAttachments={clearAttachments}
    />
  </div>
</div>
```

The middle row now contains only the canvas. The chat lives outside the row, positioned `fixed` against the viewport. The props above are copied verbatim from the original docked-chat block (lines 350-367 of the pre-change file) — note `onAddAttachments` is plural and `removeAttachment` is the existing local handler; both must match your file exactly.

- [ ] **Step 3: Remove the now-unused chat-column wrapper closing tags**

If the original middle-row block had any leftover closing `</div>` tags after the replacement, remove them. The replacement block above is self-contained — count opening and closing tags and ensure balance. Run TypeScript check to verify:

```bash
cd web && bun run tsc --noEmit
```

Expected: no errors related to JSX structure.

- [ ] **Step 4: Manual verification**

Run the dev server:
```bash
cd web && bun dev
```

Open a KV generator file. Verify:
- Canvas now extends across the full width of the work area (no docked chat column eating 444px).
- Chat appears as a floating panel at the bottom-right.
- Clicking the chat toggle pill in the bottom nav closes/opens the floating chat with the same scale animation as before.
- Closing chat does NOT change the canvas size — canvas is full-bleed regardless.
- Console has no errors.

- [ ] **Step 5: Commit**

```bash
git add web/src/components/studio/kv-generator/KvGeneratorLayout.tsx
git commit -m "feat(web): float KV chat panel as fixed bottom-right card"
```

---

## Task 2: Remove canvas caps

Drop the `max-w: 900px / max-h: 70vh` caps so the canvas fills the entire flex parent. The aspect ratio is still preserved by the `aspectRatio` CSS prop, just inside the larger area.

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvCanvas.tsx:225-244`

- [ ] **Step 1: Replace the wrapper style block**

In `web/src/components/studio/kv-generator/KvCanvas.tsx`, find the `KonvaStageFrame` component's outer `<div ref={wrapRef}>`. Replace its `style` block:

```tsx
style={{
  // Match the image's aspect exactly; cap so it never overflows
  // the viewport. `max-w` keeps wide banners inside the canvas
  // column gutter, `max-h` keeps tall posters above the fold.
  aspectRatio: String(aspect),
  maxWidth: "min(100%, 900px)",
  maxHeight: "min(70vh, 720px)",
  // If the image is tall (aspect < 1), `aspect-ratio` will try to
  // derive width from height once `max-h` clamps, which is what we
  // want. For wide images (aspect > 1), width is capped and height
  // is derived. No further logic needed — CSS handles it.
  width: aspect >= 1 ? "min(100%, 900px)" : undefined,
  height: aspect < 1 ? "min(70vh, 720px)" : undefined,
}}
```

with:

```tsx
style={{
  // Match the image's aspect exactly. The canvas now fills the
  // available work area (the parent flex column has `flex-1`), so
  // the bg image scales up to whichever dimension the aspect-ratio
  // box hits first.
  aspectRatio: String(aspect),
  maxWidth: "100%",
  maxHeight: "100%",
  width: aspect >= 1 ? "100%" : undefined,
  height: aspect < 1 ? "100%" : undefined,
}}
```

- [ ] **Step 2: Type check**

```bash
cd web && bun run tsc --noEmit
```

Expected: no errors.

- [ ] **Step 3: Manual verification**

Run `bun dev` and open a KV file. Verify:
- 9:16 portrait fills the available height (~85vh on a 900px-tall display).
- 16:9 landscape fills the available width.
- 1:1 square fills whichever dimension is smaller.
- Aspect is preserved; the bg image isn't stretched.

- [ ] **Step 4: Commit**

```bash
git add web/src/components/studio/kv-generator/KvCanvas.tsx
git commit -m "feat(web): drop KV canvas max-w/max-h caps to fill work area"
```

---

## Task 3: Remove the version label below the canvas

The "Version X / Apr 25" label below the canvas is removed in this iteration so the full-viewport canvas keeps all vertical space. Spec §2 captures the rationale; it's listed in Future Work to re-surface as a chip / nav slot / sidebar.

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvCanvas.tsx:267-274`
- Modify: `web/src/components/studio/kv-generator/KvCanvas.test.tsx`

- [ ] **Step 1: Update the existing test that asserts the label is rendered**

In `web/src/components/studio/kv-generator/KvCanvas.test.tsx`, find the test:

```tsx
it("renders generations when provided", () => {
  render(
    <KvCanvas
      generations={[
        {
          id: "g1", studio_file_id: "f", version_number: 1,
          ...
        },
      ]}
      pendingGeneration={null}
    />,
  );
  expect(screen.getByAltText(/Version 1/i)).toBeInTheDocument();
});
```

Replace it with a test that asserts the canvas mounts AND that the "Version 1" label is **no longer** rendered (the version number shouldn't appear in the canvas component anywhere):

```tsx
it("renders generations without an inline version label", () => {
  const { container } = render(
    <KvCanvas
      generations={[
        {
          id: "g1", studio_file_id: "f", version_number: 1,
          image_url: "https://s/img.png", thumbnail_url: null,
          prompt_snapshot: "p", model: "m",
          parent_generation_id: null, metadata: null,
          created_at: "2026-04-23T00:00:00Z",
        },
      ]}
      pendingGeneration={null}
    />,
  );
  // The KonvaStageFrame wrapper renders even before the bg image loads
  // (the Stage mounts only after ResizeObserver fires, but the wrapper
  // is in the DOM). Assert by structural presence, not by version text.
  expect(container.querySelector("[style*='aspect-ratio']")).toBeTruthy();
  // The old "Version 1" label markup must be gone.
  expect(container.textContent).not.toMatch(/Version\s+1/);
});
```

- [ ] **Step 2: Run the updated test — expect FAIL (label still rendered)**

```bash
cd web && bun run test KvCanvas.test.tsx
```

Expected: this single test fails because `Version 1` is still in the DOM.

- [ ] **Step 3: Remove the version label markup**

In `web/src/components/studio/kv-generator/KvCanvas.tsx`, find the `KonvaStageFrame` `return` block. Remove the entire `<div className="flex flex-col gap-1">` ... `</div>` block that contains the "Version X / Apr 25" markup (around line 267):

```tsx
<div className="flex flex-col gap-1">
  <p className="font-geist text-textSmMedium font-medium leading-[1.4] tracking-[-0.14px] text-text-inverse">
    Version {generation.version_number}
  </p>
  <p className="font-geist text-textXsRegular font-normal leading-[1.4] text-text-inverse-subtlest">
    {formatRelative(generation.created_at)}
  </p>
</div>
```

Also remove the now-unused `formatRelative` helper at the bottom of the file (lines ~304-313) since nothing else calls it.

The component's outer fragment `<> ... </>` simplifies to a single child — the wrapper `<div ref={wrapRef}>`. Either keep the fragment or unwrap it; both work. Keep for now to minimize diff.

- [ ] **Step 4: Run the test — expect PASS**

```bash
cd web && bun run test KvCanvas.test.tsx
```

Expected: all `KvCanvas.test.tsx` tests pass.

- [ ] **Step 5: Type check**

```bash
cd web && bun run tsc --noEmit
```

Expected: no errors. (If `formatRelative` was used elsewhere, restore it; otherwise its removal is fine.)

- [ ] **Step 6: Manual verification**

Run `bun dev` and open a KV file. Confirm:
- No "Version X / Apr 25" label appears below the canvas.
- The canvas fills its container.

- [ ] **Step 7: Commit**

```bash
git add web/src/components/studio/kv-generator/KvCanvas.tsx web/src/components/studio/kv-generator/KvCanvas.test.tsx
git commit -m "feat(web): remove inline version label below KV canvas"
```

---

## Task 4: Bigger default text overlay size

Bump `handlePlaceText` defaults from `0.1 × 0.05` to `0.4 × 0.08`, re-centered on the click point. New default lands ~48px font in a ~302px-wide box on a 756-tall canvas — sized for a headline.

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx:173-191`

- [ ] **Step 1: Locate or create a test for `handlePlaceText` defaults**

The existing test files don't cover this layout component directly (it's tested indirectly via the canvas component). For this small change, write a focused unit test on the `useKvOverlaysStore.add` flow combined with handler input. Append to `web/src/store/kv/useKvOverlaysStore.test.ts`:

```ts
import { describe, expect, it, beforeEach } from "vitest";
import { useKvOverlaysStore } from "./useKvOverlaysStore";

describe("useKvOverlaysStore default text overlay placement", () => {
  beforeEach(() => {
    useKvOverlaysStore.setState({
      overlays: [],
      selectedId: null,
      isHidden: false,
    });
  });

  it("accepts headline-sized default text overlays", () => {
    const { add } = useKvOverlaysStore.getState();
    add({
      type: "text",
      x: 0.3,
      y: 0.46,
      width: 0.4,
      height: 0.08,
      rotation: 0,
      payload: { type: "text", content: "", color: "#FFFFFF" },
    });
    const overlays = useKvOverlaysStore.getState().overlays;
    expect(overlays).toHaveLength(1);
    expect(overlays[0].width).toBeCloseTo(0.4);
    expect(overlays[0].height).toBeCloseTo(0.08);
  });
});
```

(This locks in the store's behavior with the new dimensions — if the store ever rejects valid `[0,1]` coords, this catches it.)

- [ ] **Step 2: Run the test — expect PASS**

```bash
cd web && bun run test useKvOverlaysStore.test.ts
```

Expected: PASS. (The store accepts arbitrary `[0,1]` coords already; this is a regression guard.)

- [ ] **Step 3: Update `handlePlaceText` defaults**

In `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx:173-191`, change:

```tsx
const handlePlaceText = useCallback(
  (nx: number, ny: number) => {
    add({
      type: "text",
      x: Math.max(0, nx - 0.05),
      y: Math.max(0, ny - 0.025),
      width: 0.1,
      height: 0.05,
      rotation: 0,
      payload: { type: "text", content: "", color: "#FFFFFF" },
    });
    const newId = useKvOverlaysStore.getState().selectedId;
    if (newId) setEditingTextId(newId);
    setCanvasTool("cursor");
  },
  [add],
);
```

to:

```tsx
const handlePlaceText = useCallback(
  (nx: number, ny: number) => {
    add({
      type: "text",
      // Centered on the click point; ~40% wide × 8% tall of canvas
      // gives a headline-sized starter (~48px font on a 756-tall
      // canvas). Clamped so the box never starts off-canvas.
      x: Math.max(0, Math.min(1 - 0.4, nx - 0.2)),
      y: Math.max(0, Math.min(1 - 0.08, ny - 0.04)),
      width: 0.4,
      height: 0.08,
      rotation: 0,
      payload: { type: "text", content: "", color: "#FFFFFF" },
    });
    const newId = useKvOverlaysStore.getState().selectedId;
    if (newId) setEditingTextId(newId);
    setCanvasTool("cursor");
  },
  [add],
);
```

The added `Math.min(1 - W, ...)` clamp keeps the box on-canvas when the user clicks near the right or bottom edge — at this larger default size it's worth defending against.

- [ ] **Step 4: Type check**

```bash
cd web && bun run tsc --noEmit
```

Expected: no errors.

- [ ] **Step 5: Manual verification**

Run `bun dev`. In a KV file with at least one generation, click the **Text** tool icon, click anywhere on the canvas. Confirm:
- The dropped text overlay is visibly larger than before — roughly a third of the canvas width and headline-sized font.
- Inline edit opens immediately.
- Clicking near the right edge places the box such that it doesn't extend past the canvas.

- [ ] **Step 6: Commit**

```bash
git add web/src/components/studio/kv-generator/KvGeneratorLayout.tsx web/src/store/kv/useKvOverlaysStore.test.ts
git commit -m "feat(web): use headline-sized default for KV text overlay"
```

---

## Task 5: Adaptive Transformer chrome (handle size + rotation arm)

Pull the math out into a small pure module so it can be unit tested. Then plumb it into the `OverlayNode` Transformer.

**Files:**
- Create: `web/src/components/studio/kv-generator/overlays/adaptiveSizing.ts`
- Create: `web/src/components/studio/kv-generator/overlays/adaptiveSizing.test.ts`
- Modify: `web/src/components/studio/kv-generator/KvKonvaCanvas.tsx` (the `OverlayNode` `<Transformer>` block, lines ~867-884)

- [ ] **Step 1: Write failing tests for the adaptive helpers**

Create `web/src/components/studio/kv-generator/overlays/adaptiveSizing.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import {
  getAdaptiveHandleSize,
  getAdaptiveRotationOffset,
  getColorChipScale,
} from "./adaptiveSizing";

describe("getAdaptiveHandleSize", () => {
  it("clamps to the lower bound (6) for tiny overlays", () => {
    expect(getAdaptiveHandleSize(20, 10)).toBe(6);
  });
  it("scales with the smaller dimension between bounds", () => {
    // min(80, 60) * 0.15 = 9 → between 6 and 12
    expect(getAdaptiveHandleSize(80, 60)).toBeCloseTo(9);
  });
  it("clamps to the upper bound (12) for large overlays", () => {
    expect(getAdaptiveHandleSize(800, 200)).toBe(12);
  });
});

describe("getAdaptiveRotationOffset", () => {
  it("clamps to the lower bound (18) for tiny overlays", () => {
    expect(getAdaptiveRotationOffset(20, 10)).toBe(18);
  });
  it("scales with the smaller dimension between bounds", () => {
    // min(60, 50) * 0.4 = 20 → between 18 and 32
    expect(getAdaptiveRotationOffset(60, 50)).toBeCloseTo(20);
  });
  it("clamps to the upper bound (32) for large overlays", () => {
    expect(getAdaptiveRotationOffset(500, 500)).toBe(32);
  });
});

describe("getColorChipScale", () => {
  it("clamps to the lower bound (0.7) for narrow overlays", () => {
    expect(getColorChipScale(50)).toBe(0.7);
  });
  it("scales linearly between bounds", () => {
    // 200 / 280 ≈ 0.714 → between 0.7 and 1
    expect(getColorChipScale(200)).toBeCloseTo(200 / 280);
  });
  it("clamps to the upper bound (1.0) for wide overlays", () => {
    expect(getColorChipScale(400)).toBe(1);
  });
});
```

- [ ] **Step 2: Run tests — expect FAIL ("module not found")**

```bash
cd web && bun run test adaptiveSizing.test.ts
```

Expected: FAIL — module doesn't exist yet.

- [ ] **Step 3: Implement the helpers**

Create `web/src/components/studio/kv-generator/overlays/adaptiveSizing.ts`:

```ts
/**
 * Helpers that scale overlay chrome (Transformer handles, rotation arm,
 * color chip) with the overlay's pixel size, so they don't dwarf small
 * overlays or look toy-sized on big ones.
 *
 * All inputs are CSS pixels measured on the rendered Konva stage.
 */

const clamp = (lo: number, x: number, hi: number) =>
  Math.max(lo, Math.min(hi, x));

/** Transformer corner/side handle size. 6–12 px. */
export function getAdaptiveHandleSize(widthPx: number, heightPx: number) {
  return clamp(6, Math.min(widthPx, heightPx) * 0.15, 12);
}

/** Distance from the bbox top edge to the rotation handle. 18–32 px. */
export function getAdaptiveRotationOffset(widthPx: number, heightPx: number) {
  return clamp(18, Math.min(widthPx, heightPx) * 0.4, 32);
}

/** CSS scale factor for the color chip pill. 0.7–1.0. */
export function getColorChipScale(overlayWidthPx: number) {
  return clamp(0.7, overlayWidthPx / 280, 1);
}
```

- [ ] **Step 4: Run tests — expect PASS**

```bash
cd web && bun run test adaptiveSizing.test.ts
```

Expected: all 9 tests pass.

- [ ] **Step 5: Plumb the helpers into the Transformer**

In `web/src/components/studio/kv-generator/KvKonvaCanvas.tsx`, find the `OverlayNode` component. At the top of the function body (after the existing `px / py / pw / ph` declarations), import and compute the adaptive sizes:

Add the import near the top of the file (with other relative imports):

```ts
import {
  getAdaptiveHandleSize,
  getAdaptiveRotationOffset,
} from "./overlays/adaptiveSizing";
```

Then inside `OverlayNode`, after `const ph = overlay.height * fit.height;`:

```ts
const handleSize = getAdaptiveHandleSize(pw, ph);
const rotationOffset = getAdaptiveRotationOffset(pw, ph);
```

Update the `<Transformer>` JSX (currently lines ~867-884) to consume them:

```tsx
{isSelected && (
  <Transformer
    ref={trRef}
    rotateEnabled
    anchorSize={handleSize}
    rotateAnchorOffset={rotationOffset}
    enabledAnchors={[
      "top-left",
      "top-right",
      "bottom-left",
      "bottom-right",
      "middle-left",
      "middle-right",
      "top-center",
      "bottom-center",
    ]}
    keepRatio={overlay.type === "text"}
  />
)}
```

- [ ] **Step 6: Type check**

```bash
cd web && bun run tsc --noEmit
```

Expected: no errors.

- [ ] **Step 7: Run all kv-generator tests**

```bash
cd web && bun run test src/components/studio/kv-generator/
```

Expected: all tests pass (existing overlay tests + new adaptiveSizing tests).

- [ ] **Step 8: Manual verification**

Run `bun dev`. Place a tiny text overlay (drag-resize it down to ~30×20 px), then a large one (~400×100 px). Verify:
- Tiny overlay: handles are visible but small (≈6 px squares); rotation arm is short (≈18 px).
- Large overlay: handles are 12 px; rotation arm is 32 px.
- Both feel proportional, neither dwarfs the overlay nor disappears into it.

- [ ] **Step 9: Commit**

```bash
git add web/src/components/studio/kv-generator/overlays/adaptiveSizing.ts web/src/components/studio/kv-generator/overlays/adaptiveSizing.test.ts web/src/components/studio/kv-generator/KvKonvaCanvas.tsx
git commit -m "feat(web): scale KV overlay Transformer chrome with overlay size"
```

---

## Task 6: Adaptive color chip + hide during drag/transform

The color chip CSS-scales between 0.7 and 1.0 based on the selected overlay's pixel width, so it never appears wider than the overlay. During drag/transform, the chip is hidden and re-shown on `onDragEnd` / `onTransformEnd` to avoid the "chip floating in old position" bug.

**Files:**
- Modify: `web/src/components/studio/kv-generator/overlays/OverlayColorChip.tsx`
- Modify: `web/src/components/studio/kv-generator/KvKonvaCanvas.tsx`

- [ ] **Step 1: Replace `OverlayColorChip.tsx` end-to-end**

Replace the entire file `web/src/components/studio/kv-generator/overlays/OverlayColorChip.tsx` with:

```tsx
"use client";

import { getColorChipScale } from "./adaptiveSizing";

const PRESETS = [
  "#FFFFFF", "#000000", "#FF3B30", "#FF9500",
  "#FFCC00", "#34C759", "#007AFF", "#AF52DE",
];

export function OverlayColorChip({
  value,
  onChange,
  anchor,
  overlayWidthPx,
  visible = true,
}: {
  value: string;
  onChange: (next: string) => void;
  anchor: { x: number; y: number };
  /** Overlay's current pixel width — drives chip scale. */
  overlayWidthPx: number;
  /** When false, the chip is hidden (during drag/transform). */
  visible?: boolean;
}) {
  if (!visible) return null;
  const scale = getColorChipScale(overlayWidthPx);
  return (
    <div
      role="toolbar"
      aria-label="Text color"
      className="absolute z-30 flex gap-1 rounded-full border border-[rgba(255,255,255,0.1)] bg-[rgba(0,0,0,0.6)] p-1.5 backdrop-blur-md"
      style={{
        left: anchor.x,
        top: anchor.y,
        transform: `scale(${scale})`,
        transformOrigin: "top left",
      }}
    >
      {PRESETS.map((c) => (
        <button
          key={c}
          type="button"
          aria-label={`Color ${c}`}
          aria-pressed={c.toUpperCase() === value.toUpperCase()}
          onClick={() => onChange(c)}
          className={[
            "h-5 w-5 rounded-full border transition-transform",
            c.toUpperCase() === value.toUpperCase()
              ? "border-white scale-110"
              : "border-transparent hover:scale-105",
          ].join(" ")}
          style={{ backgroundColor: c }}
        />
      ))}
    </div>
  );
}
```

The change set vs. the old file: imports `getColorChipScale`; adds two props (`overlayWidthPx`, `visible`); early-returns null when not visible; CSS-scales the wrapper via `transform: scale(...)` with `transformOrigin: "top left"`. PRESETS, swatch buttons, ARIA, and z-index are untouched.

- [ ] **Step 2: Track transform state in `OverlayNode`**

In `web/src/components/studio/kv-generator/KvKonvaCanvas.tsx`, the `OverlayNode` component renders the Konva `Group`. Add a piece of local state to track when this overlay is being dragged or transformed:

After the existing `useRef`s in `OverlayNode`:

```tsx
const [isInteracting, setIsInteracting] = useState(false);
```

(Add `useState` to the existing `react` imports at the top of the file if not already imported.)

Wire it into the Group's drag and transform events:

```tsx
<Group
  ref={groupRef}
  name="kv-overlay"
  x={px}
  y={py}
  rotation={overlay.rotation}
  draggable
  onClick={onSelect}
  onTap={onSelect}
  onDblClick={onDblClick}
  onDragStart={() => setIsInteracting(true)}
  onDragEnd={() => {
    setIsInteracting(false);
    commit();
  }}
  onTransformStart={() => setIsInteracting(true)}
  onTransformEnd={() => {
    setIsInteracting(false);
    commit();
  }}
>
```

- [ ] **Step 3: Lift `isInteracting` into a parent-shared signal**

The chip lives in `KvKonvaCanvas` (parent of `OverlayNode`), not inside `OverlayNode`. The parent needs to know whether the selected overlay is being interacted with. Add a state hook in `KvKonvaCanvas` body:

```tsx
const [isInteractingOverlayId, setIsInteractingOverlayId] = useState<string | null>(null);
```

Pass setter into `OverlayNode` via a new prop:

```tsx
<OverlayNode
  key={o.id}
  overlay={o}
  fit={fit}
  isSelected={o.id === selectedOverlayId}
  onSelect={() => onSelectOverlay?.(o.id)}
  onChange={(patch) => onUpdateOverlay?.(o.id, patch)}
  onDblClick={
    o.type === "text" ? () => onEditTextOverlay?.(o.id) : undefined
  }
  onInteractingChange={(active) =>
    setIsInteractingOverlayId(active ? o.id : null)
  }
/>
```

Update `OverlayNode` props type and remove the local `isInteracting` state — replace it with the upward signal:

```tsx
function OverlayNode({
  overlay,
  fit,
  isSelected,
  onSelect,
  onChange,
  onDblClick,
  onInteractingChange,
}: {
  overlay: StudioOverlay;
  fit: { x: number; y: number; width: number; height: number };
  isSelected: boolean;
  onSelect: () => void;
  onChange: (patch: Partial<StudioOverlay>) => void;
  onDblClick?: () => void;
  onInteractingChange?: (active: boolean) => void;
}) {
  // ... existing refs ...

  // ... existing px/py/pw/ph + adaptive size calcs from Task 5 ...

  const commit = () => { /* unchanged */ };

  return (
    <>
      <Group
        ref={groupRef}
        name="kv-overlay"
        x={px}
        y={py}
        rotation={overlay.rotation}
        draggable
        onClick={onSelect}
        onTap={onSelect}
        onDblClick={onDblClick}
        onDragStart={() => onInteractingChange?.(true)}
        onDragEnd={() => {
          onInteractingChange?.(false);
          commit();
        }}
        onTransformStart={() => onInteractingChange?.(true)}
        onTransformEnd={() => {
          onInteractingChange?.(false);
          commit();
        }}
      >
        {/* existing Text / Image children unchanged */}
      </Group>
      {/* existing Transformer block unchanged */}
    </>
  );
}
```

- [ ] **Step 4: Update the chip render in `KvKonvaCanvas` to pass `overlayWidthPx` and `visible`**

Find the existing color chip render block (around lines 665-700 in `KvKonvaCanvas.tsx`):

```tsx
{(() => {
  if (!selectedOverlayId) return null;
  const overlay = overlays.find(
    (o) => o.id === selectedOverlayId && o.type === "text",
  );
  if (!overlay) return null;
  const px = fit.x + overlay.x * fit.width;
  const py = fit.y + overlay.y * fit.height;
  const ph = overlay.height * fit.height;
  return (
    <OverlayColorChip
      value={...}
      onChange={...}
      anchor={{ x: px, y: py + ph + 8 }}
    />
  );
})()}
```

Update it:

```tsx
{(() => {
  if (!selectedOverlayId) return null;
  const overlay = overlays.find(
    (o) => o.id === selectedOverlayId && o.type === "text",
  );
  if (!overlay) return null;
  const px = fit.x + overlay.x * fit.width;
  const py = fit.y + overlay.y * fit.height;
  const pw = overlay.width * fit.width;
  const ph = overlay.height * fit.height;
  const isInteracting = isInteractingOverlayId === selectedOverlayId;
  return (
    <OverlayColorChip
      value={
        overlay.payload.type === "text"
          ? (overlay.payload.color ?? "#ffffff")
          : "#ffffff"
      }
      onChange={(color) => {
        if (onChangeTextColor) {
          onChangeTextColor(overlay.id, color);
        } else {
          onUpdateOverlay?.(overlay.id, {
            payload: {
              type: "text" as const,
              content:
                overlay.payload.type === "text"
                  ? overlay.payload.content
                  : "",
              color,
            },
          });
        }
      }}
      anchor={{ x: px, y: py + ph + 8 }}
      overlayWidthPx={pw}
      visible={!isInteracting}
    />
  );
})()}
```

- [ ] **Step 5: Type check**

```bash
cd web && bun run tsc --noEmit
```

Expected: no errors.

- [ ] **Step 6: Run all kv-generator tests**

```bash
cd web && bun run test src/components/studio/kv-generator/
```

Expected: all tests pass. If `KvKonvaCanvas.overlays.test.tsx` references the chip directly and breaks because of the new required props, update those test renders to pass the new props too.

- [ ] **Step 7: Manual verification**

Run `bun dev`. Select a text overlay. Verify:
- Color chip appears below the overlay at idle.
- For a small overlay (~80 px wide), chip is visibly scaled smaller than for a large one (~400 px wide).
- Drag the overlay → chip disappears during drag, reappears when drag ends.
- Resize/rotate the overlay → chip disappears during transform, reappears when finished.

- [ ] **Step 8: Commit**

```bash
git add web/src/components/studio/kv-generator/overlays/OverlayColorChip.tsx web/src/components/studio/kv-generator/KvKonvaCanvas.tsx
git commit -m "feat(web): scale KV color chip + hide during overlay transform"
```

---

## Final Verification

- [ ] **Step 1: Full TypeScript check**

```bash
cd web && bun run tsc --noEmit
```

Expected: no errors.

- [ ] **Step 2: Full test run for the kv-generator and store**

```bash
cd web && bun run test src/components/studio/kv-generator/ src/store/kv/
```

Expected: all tests pass.

- [ ] **Step 3: Lint**

```bash
cd web && bun run lint
```

Expected: no new lint errors. (Pre-existing warnings unchanged.)

- [ ] **Step 4: Manual end-to-end smoke test**

Run `bun dev` and walk through each spec acceptance criterion (1–11) on a real KV file:

1. Canvas fills the work area between top and bottom nav (chat open, default).
2. Chat is a 420 px-wide floating panel anchored bottom-right (~24 px right, ~96 px above bottom nav).
3. Toggling the chat pill animates the floating panel scale-in/out.
4. Closing chat does NOT change canvas size.
5. 9:16 portrait fills viewport height (~85 vh).
6. 16:9 landscape fills full available width.
7. Text-tool click drops a ~40 % × 8 % overlay (headline-sized).
8. Transformer handles 6–12 px, rotation arm 18–32 px, both adaptive.
9. Color chip CSS-scaled 0.7–1.0× based on overlay width.
10. Color chip hidden during drag/transform; reappears on idle.
11. No "Version X / Apr 25" label below canvas.

If any criterion fails, return to the relevant task and fix.

- [ ] **Step 5: Push the branch and create a PR**

```bash
git push -u origin feature/daffa/vc-studio-projects-kv-generator
```

Then open a PR via `gh pr create` per the project's PR conventions (CLAUDE.md → Git Conventions). Title: `feat(web): KV canvas reclaim + floating chat`. Body links the spec and lists the acceptance criteria as a checklist.

---

## Out of scope (do NOT implement here)

- Draggable / resizable chat panel
- Chat backdrop blur
- Auto-collapse chat on tool change
- Re-surfacing the version label (chip / nav slot / sidebar)
- Rotation-aware color chip anchor
- Multi-line auto-wrap or box-grow-with-text
- Mobile / small-viewport layout

These are listed in the spec's Future Work and will land as separate plans if/when prioritized.
