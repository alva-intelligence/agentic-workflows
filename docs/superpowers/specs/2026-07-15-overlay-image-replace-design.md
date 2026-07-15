# Design — Replace image in Overlay layer

- **Date:** 2026-07-15
- **Author:** Daffa (via Claude)
- **Service:** web (`frnd-web`)
- **Branch:** `develop` (implement directly, per owner decision)
- **Status:** approved (design), pending spec review

## Overview

Add the ability to replace the image content of an existing **image overlay** from
the Layers panel. Replacing swaps only the image; the layer's position, size,
rotation, z-index, and board binding stay exactly as set.

Entry point is a new **kebab (3-dot) menu** on each layer row (per the user's
mockup). The menu also absorbs the existing per-row delete action.

## Goals

- Replace an image overlay's picture without disturbing its geometry.
- `x`, `y`, `width`, `height`, `rotation`, `z`, `board_generation_id` remain
  byte-for-byte identical after a replace.
- Reuse the existing overlay-asset upload endpoint and Yjs mutation primitives —
  no backend or serializer changes.

## Non-Goals

- Canvas right-click "Replace image" (Layers panel only for now).
- Replacing from a brand-asset library / existing assets (device upload only).
- Aspect-aware refit on replace (box is preserved exactly; see Decision 1).
- Wiring the feature into the Resize-tile Layers panel instance (fast follow;
  the new prop is optional, so that instance is unaffected).

## Key Decisions

1. **Box preserved exactly.** Image overlays render with `width={w} height={h}`
   in `KvTileOverlayEditor.tsx` (no aspect-fit), so a replacement with a
   different aspect ratio stretches to fill the old box. This is the literal
   "size stays exactly as set" behavior the user requested. We do **not** touch
   any geometry field on replace.
2. **Kebab holds both actions.** The hover-only delete "X" on each row is
   replaced by a 3-dot menu. Image rows show `Replace image` + `Delete layer`;
   text rows show `Delete layer` only.
3. **Implement on `develop` directly** (owner decision), re-pull latest first.

## Current State (as-is)

- **Panel:** `web/src/components/studio/kv-generator/KvLayersPanel.tsx`
  - Layer rows: lines ~429–489. Each row has a drag handle
    (`DotsSixVertical`), a `LayerIcon` (image thumbnail or icon), a label, and a
    hover-reveal delete button (`aria-label="Delete layer"`, lines ~476–486).
  - `labelForOverlay` returns `"Image overlay"` / text content / `"Text overlay"`.
  - No existing kebab / context menu on rows.
- **Overlay model:** `StudioOverlay` in `web/src/types/studio.ts` (lines ~433–454).
  Image payload is `{ type: "image", asset_url, mime_type }`. Geometry lives in
  the sibling fields `x, y, width, height, rotation, z, board_generation_id`.
- **Upload:** `uploadStudioOverlayAsset(fileId, file)` in
  `web/src/services/kv/api.ts` → `POST v1/studio/files/{fileId}/overlay-assets`
  → `{ asset_url, mime_type, file_size, file_name }`.
- **Mutation primitive:** `docUpdateOverlay(doc, id, patch)` in
  `web/src/lib/kv/yjsSerializer.ts` (line ~425). Already supports a `payload`
  patch and replaces the payload submap wholesale while leaving `rect` (geometry)
  and `z` untouched when they are absent from the patch. **No change needed.**
- **Store fallback:** `useKvOverlaysStore().update(id, patch)` for when `kvDoc`
  is not yet ready (mirrors the `addOverlay` doc-vs-store fallback at
  `KvGeneratorLayout.tsx` ~2498–2520).
- **Owner of state:** `KvGeneratorLayout.tsx` holds `kvDoc`, `file`,
  `fileInputRef`, upload helpers, and mounts `KvLayersPanel` (~3298–3330).

## Design

### 1. `KvLayersPanel` — kebab menu on rows

- Add an optional prop:
  ```ts
  /** Replace an image overlay's picture. Omitted in tile scope, where the
   *  menu shows Delete only. */
  onReplaceImage?: (id: string) => void;
  ```
- Replace the row's inline delete `<button>` with a `RowMenu` component:
  - A 3-dot trigger button (`DotsThreeVertical` from `@phosphor-icons/react`),
    hover-revealed with the same `opacity-0 group-hover:opacity-100` treatment,
    plus always-visible while its menu is open.
  - Clicking opens a small dropdown anchored to the row.
  - Menu items:
    - `Replace image` — shown only when `overlay.payload.type === "image"` **and**
      `onReplaceImage` is provided. Calls `onReplaceImage(o.id)`.
    - `Delete layer` — always shown. Calls `onRemove(o.id)`.
  - `e.stopPropagation()` on the trigger and items so row-select / drag don't fire.
  - Close on outside click / Escape / after an item is chosen.
- Use the existing frndOS menu/popover primitive if one is already used in this
  panel's neighborhood (check `@/components/frndos/v2` first, then v1); otherwise
  a lightweight local dropdown consistent with the panel's existing dark styling.
  Reuse the panel's existing outside-click pattern (the preset dropdown already
  manages open/close + outside click — follow that).

### 2. `KvGeneratorLayout` — replace flow

- Add a hidden file input dedicated to replace (separate from the place
  `fileInputRef` to avoid mode confusion):
  ```ts
  const replaceInputRef = useRef<HTMLInputElement | null>(null);
  const pendingReplaceIdRef = useRef<string | null>(null);
  ```
- `handleRequestReplaceImage(id)`: store `id` in `pendingReplaceIdRef`, then
  `replaceInputRef.current?.click()`.
- `onReplaceFileSelected(e)`: read `files[0]`, reset `e.target.value = ""`, read
  and clear `pendingReplaceIdRef`, then call `replaceImageOverlay(id, file)`.
- `replaceImageOverlay(id, file)`:
  ```ts
  if (!file?.id) return;
  setReplacingOverlayId(id);          // in-flight state (see UX)
  try {
    const uploaded = await uploadStudioOverlayAsset(file.id, file2);
    const patch = { payload: { type: "image", asset_url: uploaded.asset_url,
                               mime_type: uploaded.mime_type } };
    if (kvDoc) docUpdateOverlay(kvDoc, id, patch);
    else update(id, patch);           // store fallback, same guard as addOverlay
    trackKvOverlayImageReplaced({ overlay_id: id });
  } catch (err) {
    console.error("overlay replace failed", err);
    setTransientNotice("Couldn't replace the image. Try again.");
  } finally {
    setReplacingOverlayId(null);
  }
  ```
  Note: `file?.id` is the **studio file id** (upload target); `file2`/`file` is
  the picked `File`. No geometry field is ever written → position/size/rotation/
  layout preserved exactly.
- Pass `onReplaceImage={handleRequestReplaceImage}` into the main
  `KvLayersPanel` mount. Render the hidden `replaceInputRef` input
  (`accept="image/*"`) alongside the existing place input.

### 3. Validation

- Mirror the existing overlay-asset upload constraints (`accept="image/*"`; any
  size/type validation that `placeImageOverlay` / the upload endpoint already
  enforce). No new validation rules introduced.

### 4. UX / in-flight

- `replacingOverlayId` drives a brief "replacing…" affordance on the affected
  row's thumbnail (e.g. reduced opacity + spinner). While a row is replacing, its
  kebab `Replace image` item is disabled to prevent a double-submit.
- On error, the overlay is left unchanged and a transient notice is shown
  (existing `setTransientNotice` mechanism).

### 5. Analytics (mandatory)

Add a sibling event in `web/src/lib/analytics/kv-generator-events.ts`:
```ts
export interface KvOverlayImageReplacedProps {
  overlay_id: string;
}
export const trackKvOverlayImageReplaced = (p: KvOverlayImageReplacedProps) =>
  safeCapture("kv_generator.overlay_image_replaced", p);
```
Fire it after a successful `docUpdateOverlay` / store update. Follow the
`frndos-analytics-events` skill for base-context and fire-timing conventions.

## Data Flow

```
Layers row kebab → "Replace image"
  → onReplaceImage(id)                         [KvLayersPanel prop]
  → handleRequestReplaceImage(id)              [KvGeneratorLayout]
      pendingReplaceIdRef = id; replaceInput.click()
  → onReplaceFileSelected(file)
  → replaceImageOverlay(id, file)
      uploadStudioOverlayAsset(fileId, file) → { asset_url, mime_type }
      docUpdateOverlay(kvDoc, id, { payload }) | update(id, { payload })
      trackKvOverlayImageReplaced({ overlay_id })
  → Yjs projects to store → Konva re-renders new image in the SAME box
```

## Edge Cases

- **`tmp_` (unpersisted) overlays:** replace works by id via doc/store update.
- **Board-bound overlays:** `board_generation_id` is untouched → binding intact.
- **Rapid double replace:** blocked by the `replacingOverlayId` in-flight guard.
- **User cancels the file picker:** `pendingReplaceIdRef` is cleared on the next
  selection; no-op if no file chosen.
- **Text overlay rows:** kebab shows Delete only (no `Replace image`).
- **`kvDoc` not ready:** store `update` fallback keeps the swap working.

## Testing

- Unit (bun test): `replaceImageOverlay`-style payload patch leaves all geometry
  fields unchanged (assert the patch object contains only `payload`).
- Component: `KvLayersPanel` renders `Replace image` for image rows only, and
  omits it when `onReplaceImage` is not provided; `Delete layer` always present.
- Manual e2e: place an image overlay, move/resize/rotate it, replace with a
  differently-shaped image, confirm the box (x/y/w/h/rotation) is identical and
  only the picture changed. Verify undo behaves sanely.
- Gate: `bun run build` must pass (the real type/lint gate for web).

## Files Touched

- `web/src/components/studio/kv-generator/KvLayersPanel.tsx` — kebab menu + prop.
- `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx` — replace flow,
  hidden input, wiring.
- `web/src/lib/analytics/kv-generator-events.ts` — new event.
- (tests as above)

No changes to `yjsSerializer.ts`, the store, `types/studio.ts`, or any backend.
