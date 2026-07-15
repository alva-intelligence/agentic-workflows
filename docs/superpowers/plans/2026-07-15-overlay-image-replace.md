# Replace Image in Overlay Layer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user replace an image overlay's picture from the Layers panel via a 3-dot menu, preserving the layer's position, size, rotation, z-index, and board binding exactly.

**Architecture:** A new kebab menu (reusing `ActionMenu`) on each Layers row exposes `Replace image` (image overlays) and `Delete layer`. Replace opens a hidden file input, uploads via the existing overlay-asset endpoint, and calls `docUpdateOverlay(id, { payload })` — which writes only the payload submap, leaving all geometry untouched. No backend, serializer, store, or type changes.

**Tech Stack:** Next.js 16 / React 19 / TypeScript, Zustand + Yjs (collab doc), Phosphor icons, Radix Popover (via `ActionMenu`), bun test.

## Global Constraints

- Service: **web** only. Work directly on `develop` (re-pull latest first). Do NOT touch `api/`, `ai-service/`, or `data-service/`.
- Replace must NEVER write `x`, `y`, `width`, `height`, `rotation`, `z`, or `board_generation_id`. Only `payload`.
- Device upload only (no library picker). Layers panel only (no canvas right-click).
- Reuse existing primitives: `uploadStudioOverlayAsset`, `docUpdateOverlay`, `ActionMenu`, `setTransientNotice`, `safeCapture`.
- File-input `accept` must match the existing overlay input exactly: `image/png,image/jpeg,image/webp,image/svg+xml`.
- Real type/lint gate for web is `bun run build`. Unit tests run with `bun test`.
- Commit after each task. Commit scope prefix: `feat(web):`.

---

### Task 1: `buildImageReplacePatch` helper (geometry-preservation invariant)

**Files:**
- Modify: `web/src/lib/studio/kv/overlayMutations.ts` (append new export)
- Test: `web/src/lib/studio/kv/overlayMutations.test.ts` (append)

**Interfaces:**
- Produces: `buildImageReplacePatch(assetUrl: string, mimeType: string): { payload: { type: "image"; asset_url: string; mime_type: string } }` — a `docUpdateOverlay` patch containing ONLY `payload`.

- [ ] **Step 1: Write the failing test**

Append to `web/src/lib/studio/kv/overlayMutations.test.ts`:

```ts
import { buildImageReplacePatch } from "./overlayMutations";

describe("buildImageReplacePatch", () => {
  it("returns a patch containing only payload (no geometry keys)", () => {
    const patch = buildImageReplacePatch("https://s3.example/new.png", "image/png");
    expect(Object.keys(patch)).toEqual(["payload"]);
  });

  it("carries the new image asset_url and mime_type", () => {
    const patch = buildImageReplacePatch("https://s3.example/new.png", "image/png");
    expect(patch.payload).toEqual({
      type: "image",
      asset_url: "https://s3.example/new.png",
      mime_type: "image/png",
    });
  });
});
```

(If `overlayMutations.test.ts` already imports from `./overlayMutations`, merge the import instead of duplicating it.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/lib/studio/kv/overlayMutations.test.ts`
Expected: FAIL — `buildImageReplacePatch is not a function` / not exported.

- [ ] **Step 3: Write minimal implementation**

Append to `web/src/lib/studio/kv/overlayMutations.ts`:

```ts
/**
 * Patch that swaps ONLY an image overlay's picture. The returned object
 * contains solely `payload`, so passing it to docUpdateOverlay leaves every
 * geometry field (x/y/width/height/rotation/z/board binding) untouched —
 * position, size, rotation, and layout are preserved exactly.
 */
export function buildImageReplacePatch(
  assetUrl: string,
  mimeType: string
): { payload: { type: "image"; asset_url: string; mime_type: string } } {
  return {
    payload: { type: "image", asset_url: assetUrl, mime_type: mimeType },
  };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/lib/studio/kv/overlayMutations.test.ts`
Expected: PASS (all cases green).

- [ ] **Step 5: Commit**

```bash
cd web && git add src/lib/studio/kv/overlayMutations.ts src/lib/studio/kv/overlayMutations.test.ts
git commit -m "feat(web): add buildImageReplacePatch overlay helper"
```

---

### Task 2: `buildLayerRowMenuItems` menu builder

**Files:**
- Create: `web/src/components/studio/kv-generator/layerRowMenu.tsx`
- Test: `web/src/components/studio/kv-generator/layerRowMenu.test.tsx`

**Interfaces:**
- Consumes: `ActionMenuItem` from `@/components/frndos/ActionMenu`; `StudioOverlay` from `@/types/studio`.
- Produces:
  ```ts
  buildLayerRowMenuItems(
    overlay: StudioOverlay,
    opts: { onReplaceImage?: (id: string) => void; onRemove: (id: string) => void; replacing?: boolean }
  ): ActionMenuItem[]
  ```
  Order: `replace` (only when `overlay.payload.type === "image"` AND `onReplaceImage` provided), then always `delete`.

- [ ] **Step 1: Write the failing test**

Create `web/src/components/studio/kv-generator/layerRowMenu.test.tsx`:

```tsx
import { buildLayerRowMenuItems } from "./layerRowMenu";
import type { StudioOverlay } from "@/types/studio";

const imageOverlay = {
  id: "o1",
  type: "image",
  payload: { type: "image", asset_url: "u", mime_type: "image/png" },
} as unknown as StudioOverlay;

const textOverlay = {
  id: "o2",
  type: "text",
  payload: { type: "text", content: "hi", color: "#fff" },
} as unknown as StudioOverlay;

describe("buildLayerRowMenuItems", () => {
  it("image overlay with onReplaceImage → replace then delete", () => {
    const items = buildLayerRowMenuItems(imageOverlay, {
      onReplaceImage: () => {},
      onRemove: () => {},
    });
    expect(items.map((i) => i.key)).toEqual(["replace", "delete"]);
    expect(items[1].variant).toBe("danger");
  });

  it("image overlay without onReplaceImage → delete only", () => {
    const items = buildLayerRowMenuItems(imageOverlay, { onRemove: () => {} });
    expect(items.map((i) => i.key)).toEqual(["delete"]);
  });

  it("text overlay → delete only even with onReplaceImage", () => {
    const items = buildLayerRowMenuItems(textOverlay, {
      onReplaceImage: () => {},
      onRemove: () => {},
    });
    expect(items.map((i) => i.key)).toEqual(["delete"]);
  });

  it("replacing → replace item disabled with 'Replacing…' label", () => {
    const items = buildLayerRowMenuItems(imageOverlay, {
      onReplaceImage: () => {},
      onRemove: () => {},
      replacing: true,
    });
    expect(items[0].disabled).toBe(true);
    expect(items[0].label).toBe("Replacing…");
  });

  it("replace onClick calls onReplaceImage with the overlay id", () => {
    let called = "";
    const items = buildLayerRowMenuItems(imageOverlay, {
      onReplaceImage: (id) => (called = id),
      onRemove: () => {},
    });
    items[0].onClick();
    expect(called).toBe("o1");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/layerRowMenu.test.tsx`
Expected: FAIL — cannot resolve `./layerRowMenu`.

- [ ] **Step 3: Write minimal implementation**

Create `web/src/components/studio/kv-generator/layerRowMenu.tsx`:

```tsx
import { Image as ImageIcon, Trash } from "@phosphor-icons/react";
import type { ActionMenuItem } from "@/components/frndos/ActionMenu";
import type { StudioOverlay } from "@/types/studio";

/**
 * Build the kebab-menu items for a single Layers-panel row.
 * - `Replace image` is offered only for image overlays and only when the
 *   parent supplies `onReplaceImage` (the tile-scoped panel omits it).
 * - `Delete layer` is always present.
 */
export function buildLayerRowMenuItems(
  overlay: StudioOverlay,
  opts: {
    onReplaceImage?: (id: string) => void;
    onRemove: (id: string) => void;
    replacing?: boolean;
  }
): ActionMenuItem[] {
  const items: ActionMenuItem[] = [];

  if (overlay.payload.type === "image" && opts.onReplaceImage) {
    const replace = opts.onReplaceImage;
    const isReplacing = opts.replacing ?? false;
    items.push({
      key: "replace",
      label: isReplacing ? "Replacing…" : "Replace image",
      icon: <ImageIcon size={16} />,
      disabled: isReplacing,
      onClick: () => replace(overlay.id),
    });
  }

  items.push({
    key: "delete",
    label: "Delete layer",
    icon: <Trash size={16} />,
    variant: "danger",
    onClick: () => opts.onRemove(overlay.id),
  });

  return items;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/layerRowMenu.test.tsx`
Expected: PASS (all cases green).

- [ ] **Step 5: Commit**

```bash
cd web && git add src/components/studio/kv-generator/layerRowMenu.tsx src/components/studio/kv-generator/layerRowMenu.test.tsx
git commit -m "feat(web): add Layers row kebab-menu item builder"
```

---

### Task 3: Wire kebab menu into `KvLayersPanel`

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvLayersPanel.tsx`

**Interfaces:**
- Consumes: `buildLayerRowMenuItems` (Task 2), `ActionMenu` default export from `@/components/frndos/ActionMenu`.
- Produces: two new optional props on `KvLayersPanel`:
  - `onReplaceImage?: (id: string) => void`
  - `replacingOverlayId?: string | null`

- [ ] **Step 1: Add imports**

At the top of `KvLayersPanel.tsx`, add (keep the existing phosphor import; `X` is no longer used by the row — remove it from the phosphor import list only if nothing else references it, otherwise leave it):

```tsx
import ActionMenu from "@/components/frndos/ActionMenu";
import { buildLayerRowMenuItems } from "./layerRowMenu";
```

- [ ] **Step 2: Add the two props to the `Props` type**

In the `type Props = { … }` block (ends ~line 55), add:

```tsx
  /** Replace an image overlay's picture. Omitted in tile scope, where the
   *  kebab menu shows Delete only. */
  onReplaceImage?: (id: string) => void;
  /** Overlay id whose image is currently being replaced (drives the in-flight
   *  "Replacing…" disabled state on that row's menu item). */
  replacingOverlayId?: string | null;
```

- [ ] **Step 3: Destructure the new props**

In the `export function KvLayersPanel({ … })` parameter list, add `onReplaceImage` and `replacingOverlayId` alongside the existing destructured props.

- [ ] **Step 4: Replace the inline delete button with the kebab menu**

In the row `<li>` (currently lines ~476–486), replace the delete `<button>…<X/></button>` block with:

```tsx
                <div
                  className="shrink-0 opacity-0 transition-opacity focus-within:opacity-100 group-hover:opacity-100 [&:has([data-state=open])]:opacity-100"
                  onClick={(e) => e.stopPropagation()}
                >
                  <ActionMenu
                    items={buildLayerRowMenuItems(o, {
                      onReplaceImage,
                      onRemove,
                      replacing: replacingOverlayId === o.id,
                    })}
                  />
                </div>
```

Notes:
- The wrapper's `onClick` stopPropagation prevents opening the menu from toggling row selection (the `<li>` has `onClick={() => onSelect(...)}`).
- `[&:has([data-state=open])]:opacity-100` keeps the kebab visible while its Radix menu is open (Radix sets `data-state="open"` on the trigger).
- `ActionMenu` internally `stopPropagation`s item clicks and closes on select.

- [ ] **Step 5: Remove the now-unused `X` import if orphaned**

Run: `cd web && grep -n "<X " src/components/studio/kv-generator/KvLayersPanel.tsx`
If there are no remaining `<X` usages, remove `X` from the `@phosphor-icons/react` import list. If `X` is still used elsewhere in the file, leave it.

- [ ] **Step 6: Type-check**

Run: `cd web && bun run build`
Expected: PASS (no type errors). The panel now compiles with the optional props; existing mounts that don't pass them still type-check.

- [ ] **Step 7: Commit**

```bash
cd web && git add src/components/studio/kv-generator/KvLayersPanel.tsx
git commit -m "feat(web): kebab menu on Layers rows (replace + delete)"
```

---

### Task 4: Replace flow + analytics in `KvGeneratorLayout`

**Files:**
- Modify: `web/src/lib/analytics/kv-generator-events.ts` (new event)
- Modify: `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx`

**Interfaces:**
- Consumes: `buildImageReplacePatch` (Task 1), `uploadStudioOverlayAsset`, `docUpdateOverlay`, store `update`, `setTransientNotice`.
- Produces: `trackKvOverlayImageReplaced({ overlay_id })`; `handleRequestReplaceImage(id)` passed to the panel; `onReplaceFileSelected`; `replaceImageOverlay(id, file)`.

- [ ] **Step 1: Add the analytics event**

In `web/src/lib/analytics/kv-generator-events.ts`, directly after the `trackKvOverlayAdded` block (the `// C. Iteration` section, ~line 118), add:

```ts
export interface KvOverlayImageReplacedProps {
  overlay_id: string;
}

export const trackKvOverlayImageReplaced = (p: KvOverlayImageReplacedProps) =>
  safeCapture("kv_generator.overlay_image_replaced", p);
```

- [ ] **Step 2: Import the new symbols in the layout**

In `KvGeneratorLayout.tsx`:
- Add `buildImageReplacePatch` to the existing import from `@/lib/studio/kv/overlayMutations` (the file already imports `reorderOverlays` from there — add to that import list; if there is no existing import from that module, add a new one).
- Add `trackKvOverlayImageReplaced` to the existing import from `@/lib/analytics/kv-generator-events` (the file already imports `trackKvOverlayAdded` — add to that list).

- [ ] **Step 3: Pull `update` from the overlay store**

After the existing `const add = useKvOverlaysStore((s) => s.add);` (line ~1369), add:

```tsx
  const update = useKvOverlaysStore((s) => s.update);
```

- [ ] **Step 4: Add refs + in-flight state**

Immediately after the existing `const fileInputRef = useRef<HTMLInputElement | null>(null);` (line ~2548), add:

```tsx
  // Replace-image flow: a dedicated hidden input + the overlay id awaiting a
  // picked file, kept separate from the place flow's fileInputRef so the two
  // never cross wires. `replacingOverlayId` drives the row's disabled state.
  const replaceInputRef = useRef<HTMLInputElement | null>(null);
  const pendingReplaceIdRef = useRef<string | null>(null);
  const [replacingOverlayId, setReplacingOverlayId] = useState<string | null>(
    null
  );
```

- [ ] **Step 5: Add the replace handlers**

Immediately after `onOverlayFileSelected` (ends ~line 2642), add:

```tsx
  // Open the dedicated replace picker for a specific overlay.
  const handleRequestReplaceImage = useCallback((id: string) => {
    pendingReplaceIdRef.current = id;
    replaceInputRef.current?.click();
  }, []);

  // Core replace path: upload the new File, then patch ONLY the overlay's
  // payload via docUpdateOverlay — geometry (x/y/width/height/rotation/z/board
  // binding) is never written, so position/size/rotation/layout are preserved.
  const replaceImageOverlay = async (id: string, f: File) => {
    if (!file?.id) return;
    setReplacingOverlayId(id);
    try {
      const uploaded = await uploadStudioOverlayAsset(file.id, f);
      const patch = buildImageReplacePatch(
        uploaded.asset_url,
        uploaded.mime_type
      );
      if (kvDoc) docUpdateOverlay(kvDoc, id, patch);
      else update(id, patch);
      trackKvOverlayImageReplaced({ overlay_id: id });
    } catch (err) {
      console.error("overlay replace failed", err);
      setTransientNotice("Couldn't replace the image. Try again.");
    } finally {
      setReplacingOverlayId(null);
    }
  };

  // Hidden replace-input change handler: read the picked file + the pending
  // overlay id captured when the picker opened, then run the replace.
  const onReplaceFileSelected = async (
    e: React.ChangeEvent<HTMLInputElement>
  ) => {
    const f = e.target.files?.[0];
    e.target.value = ""; // allow re-picking the same file later
    const id = pendingReplaceIdRef.current;
    pendingReplaceIdRef.current = null;
    if (!f || !id) return;
    await replaceImageOverlay(id, f);
  };
```

- [ ] **Step 6: Render the hidden replace input**

Directly after the existing hidden file input (the `<input … ref={fileInputRef} … />` block ending ~line 2877), add a sibling:

```tsx
      {/* Hidden file input for the replace-image flow (per-overlay swap). */}
      <input
        type="file"
        ref={replaceInputRef}
        accept="image/png,image/jpeg,image/webp,image/svg+xml"
        onChange={onReplaceFileSelected}
        className="hidden"
      />
```

- [ ] **Step 7: Pass the new props to the main `KvLayersPanel` mount**

In the `<KvLayersPanel … />` mount (~line 3298), add these two props (anywhere among the existing props, e.g. right after `onReorder={…}`):

```tsx
            onReplaceImage={handleRequestReplaceImage}
            replacingOverlayId={replacingOverlayId}
```

Leave the tile-scoped `KvLayersPanel` inside `KvResizeCanvas` unchanged — it omits `onReplaceImage`, so its rows show Delete only (out of scope for this plan).

- [ ] **Step 8: Type-check + full unit run**

Run: `cd web && bun run build`
Expected: PASS (no type errors).

Run: `cd web && bun test src/lib/studio/kv/overlayMutations.test.ts src/components/studio/kv-generator/layerRowMenu.test.tsx`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
cd web && git add src/lib/analytics/kv-generator-events.ts src/components/studio/kv-generator/KvGeneratorLayout.tsx
git commit -m "feat(web): replace image in overlay, preserving geometry"
```

---

### Task 5: Manual verification (browser)

**Files:** none (verification only).

- [ ] **Step 1: Ensure web is running**

The dev server should already be up on http://localhost:3000. If not: `preview_start` the `web` server (or `cd web && bun dev`).

- [ ] **Step 2: Exercise the flow**

In the KV Generator studio:
1. Place an image overlay on the canvas.
2. Move it, resize it, and rotate it to a distinctive box.
3. Open the Layers panel; hover the image row → the 3-dot kebab appears.
4. Open the kebab → confirm `Replace image` + `Delete layer` are present.
5. Click `Replace image`, pick a differently-shaped image.
6. Confirm: the picture changes, and the box (position, width, height, rotation) is visually identical — the new image fills the same box.
7. Open the kebab on a text overlay → confirm only `Delete layer` shows.

- [ ] **Step 3: Confirm no console/network errors**

Use `read_console_messages` (only errors) and `read_network_requests` (filter `overlay-assets`) — the upload should 200 and no client errors should appear. Take a screenshot of the before/after box as proof.

- [ ] **Step 4: Confirm the geometry invariant in state (optional)**

In the browser, before replacing, note the selected overlay's `x/y/width/height/rotation` (via the panel's transform readout or `javascript_tool` reading the store). After replacing, confirm those five values are unchanged.

---

## Self-Review

**Spec coverage:**
- Kebab menu with Replace/Delete (image) and Delete (text) → Task 2 + Task 3. ✓
- Replace preserves geometry exactly → Task 1 (`buildImageReplacePatch` only-payload invariant) + Task 4 (`replaceImageOverlay` never writes geometry). ✓
- Reuse existing upload + `docUpdateOverlay` + store fallback → Task 4. ✓
- In-flight guard + "Replacing…" disabled + error notice → Task 2 (`replacing`) + Task 3 (wrapper) + Task 4 (`replacingOverlayId`, `setTransientNotice`). ✓
- Analytics event `kv_generator.overlay_image_replaced` → Task 4 Step 1. ✓
- Device upload only, Layers panel only, develop branch → Global Constraints. ✓
- Resize-tile panel out of scope (optional prop) → Task 4 Step 7. ✓

**Placeholder scan:** No TBD/TODO; all code blocks are concrete. ✓

**Type consistency:** `buildImageReplacePatch(assetUrl, mimeType)` (Task 1) is called with `uploaded.asset_url, uploaded.mime_type` (Task 4). `buildLayerRowMenuItems(overlay, { onReplaceImage, onRemove, replacing })` (Task 2) matches the call site in Task 3. Props `onReplaceImage` / `replacingOverlayId` defined in Task 3 match the mount in Task 4 Step 7. `ActionMenuItem` shape (`key/label/icon/variant/disabled/onClick`) matches `ActionMenu.tsx`. ✓
