---
title: KV Generator — Text + Image Overlay Tools
slug: studio-kv-overlays
author: daffa
created: 2026-04-25
status: draft
services: [web, api]
---

## Overview

Add two new bottom-nav canvas tools to the KV Generator — **Text** and **Image** overlay — that let users place editable, draggable elements on top of the generated background image. Overlays are pure client-side compositing (never sent to AI), persist on the file, float over whichever bg version is being viewed, and flatten into the final image only at export.

This is a **sketch / concepting** tool, not a final-art editor. Scope is intentionally minimal: drag, resize, rotate. Everything else (layers panel, z-order ops, multi-select, snap guides, undo/redo) is explicitly future work.

Figma reference: node `5277:95136` in the Studio file. The design extends the existing center pill in `KvCanvasBottomNav` from 2 buttons (cursor, frame) to 4 (cursor, frame, image, text).

## Why client compositing, not AI

Two clear, separate mental models:

- **Frame tool** (existing, bbox-edit spec) — tells the AI to *paint* something into a region. AI re-generates a new bg version.
- **Text/Image overlay** (this spec) — places something *on top of* the bg. AI is never involved.

Reasons:

1. **Brand fidelity.** Logos and headlines must be pixel-perfect. AI image models hallucinate text and approximate logos. Compositing keeps text as text and logos as actual SVG/PNG.
2. **Speed.** No model round-trip — drag/edit/undo are instant.
3. **Editability.** Text remains editable as text (content, color), not baked pixels.
4. **Industry norm.** Canva, Figma, Adobe Express all composite client-side and only flatten on export. Users expect this.

If anyone later wants "bake my overlays into a new AI generation," that's an opt-in future feature on top of the same data model — no rework.

## Re-generate lifecycle

Overlays are **file-scoped and bg-agnostic**. The bg image is just the layer underneath them.

| User action | What happens to overlays |
|---|---|
| User types a new prompt → AI generates bg v2 | No change. Same overlays, now floating over v2. |
| User uses frame tool + inpainting → produces v2 | No change. Inpainting modifies bg pixels only — overlays sit on a separate Konva layer above and are never sent to the AI. |
| User clicks an older version in the version sidebar | Overlays stay visible on top of whichever version they're viewing. |
| User deletes a generation | Overlays unaffected (they live on `studio_files`, not `kv_generations`). |
| User exports while viewing v2 | Flatten overlays over v2 → final PNG. Viewing v1 → flatten over v1. |

Coordinates are normalized `[0,1]` against the canvas working bounds, so the same `(x, y, width, height)` lands in the same visual spot across all versions in a file (versions in a file share `canvas_orientation`).

## Data model

### Single overlay element type

Text and image overlays are the same shape with a discriminated `payload`:

```ts
type StudioOverlay = {
  id: string;                    // ulid, server-assigned
  studio_file_id: string;
  type: "text" | "image";

  // Position + size — normalized [0,1] against canvas working bounds
  // (same convention as KvBoundingBox).
  x: number;
  y: number;
  width: number;
  height: number;
  rotation: number;              // degrees, 0 default

  // Stack order. v1: append-only — server fills with `max(z) + 1`.
  z: number;

  payload:
    | { type: "text"; content: string; color: string }            // hex, e.g. "#FFFFFF"
    | { type: "image"; asset_url: string; mime_type: string };

  created_at: string;
  updated_at: string;
};
```

### Sizing semantics

- **Text:** `fontSize` is derived from box height at render time (`fontSize = boxHeightPx * 0.8`). No font-size input. Dragging a corner handle scales the text. No font-family / weight / alignment controls in v1.
- **Image:** width/height drive natural display size; aspect is free by default, hold Shift while resizing for uniform.

Both element types share rotation (single rotation handle on the Transformer).

### Why a single type, not two

`StudioOverlay` could split into `StudioTextOverlay` / `StudioImageOverlay`. Keeping one shape with a tagged `payload` matches how the rest of the codebase handles discriminated state (e.g. `messages.kind` + `messages.payload` in the chat thread store) and lets the Konva layer iterate over a single homogeneous array.

## Frontend canvas

### Konva layer stack

Top to bottom in `KvKonvaCanvas`:

```
Layer: tool overlays (transformer handles, draft state)
Layer: overlays (text + image, sorted by z ascending)
Layer: bg image (the current generation)
```

The bg layer is the only layer that re-mounts on version switch. The overlay layer is independent and persists across version changes within a file session.

### Tool union

`KvCanvasBottomNav` `tool` prop union grows:

```ts
type Tool = "cursor" | "frame" | "text" | "image";
```

Lifted to `KvGeneratorLayout` (already done for cursor/frame). Two new icon buttons in the center pill — `TextT` and `Image` from `@phosphor-icons/react`, matching the Figma design (`5277:95138` and `5277:95139`).

### Adding overlays — click-to-place

| Tool | Single click on canvas | Result |
|---|---|---|
| Text | Drops a placeholder at cursor (default size ≈ 10% of canvas height). Color defaults to white if bg average luminance is dark, black otherwise. Enters inline edit mode immediately. | New `StudioOverlay` with `type: "text"`, payload `{ content: "", color }`. |
| Image | First click opens the OS file picker → user picks file → file uploads to S3 (see Backend) → on success, image appears centered on canvas (default size ≈ 30% of canvas, aspect-preserved). Tool returns to `cursor`. | New `StudioOverlay` with `type: "image"`, payload `{ asset_url, mime_type }`. |

Click-to-place (not drag-to-draw) matches the sketch / concept framing — drop fast, position after.

### Selection + Transformer

- Click an overlay → select. Konva `Transformer` attaches with corner + side handles + a rotation handle.
- For text: dragging any corner scales uniformly (locked aspect → text font size grows with height).
- For images: free aspect by default; hold Shift for uniform.
- Click empty canvas → deselect.
- `Delete` / `Backspace` while selected → remove.
- `Esc` while selected → deselect (also commits inline text edit).

### Inline text editing

- Double-click a text overlay → swap the Konva `Text` node for an absolutely-positioned HTML `<textarea>` aligned to the same bbox + rotation. User types, hits `Esc` or clicks away to commit.
- A small floating chip near the selected text shows just **color** (single swatch picker — the only typography control in v1).
- Empty string on commit → element auto-deletes (avoids ghost overlays).

### Bottom-nav UX

`KvCanvasBottomNav`:

- Center pill grows from 2 → 4 buttons. Active tool is the only one with white bg (existing pattern).
- Left "Edit Overlay" `UtilityPill` is repurposed: **toggle visibility of all overlays** (one-click "show me the bg without my overlays"). The label finally matches its function. Icon stays `Stack`.
- "Style" pill, chat toggle pill, and other existing affordances unchanged.

### State (Zustand)

New store `web/src/store/kv/useKvOverlaysStore.ts`:

```ts
{
  overlays: StudioOverlay[];               // local optimistic state
  selectedId: string | null;
  isHidden: boolean;                       // for the "Edit Overlay" toggle
  // Mutations — all update local immediately and schedule a debounced PATCH:
  add: (o: Omit<StudioOverlay, "id" | "z" | "created_at" | "updated_at" | "studio_file_id">) => void;
  update: (id: string, patch: Partial<StudioOverlay>) => void;     // drag/resize/rotate/text edit
  remove: (id: string) => void;
  setSelected: (id: string | null) => void;
  toggleHidden: () => void;
  hydrate: (fromServer: StudioOverlay[]) => void;                  // on file load
}
```

### Autosave

A `useDebouncedOverlaySave(fileId, overlays, 500)` hook owns the PATCH lifecycle:

- 500ms debounce on `overlays` changes.
- One in-flight request at a time. If a save is already going and a new debounce fires, queue exactly one follow-up save.
- On error → roll back local state to last-saved snapshot, surface a toast (`"Couldn't save layout, retry?"`).
- No optimistic concurrency / version field. Single-author tool, out of v1.

## Backend

### Storage

```sql
ALTER TABLE studio_files ADD COLUMN overlays JSON NULL;
```

`NULL` default — read as `[]` on the frontend. Matches the existing JSON-column pattern (`messages.tools`, `kv_generations.metadata`, template `canvas_state`).

### Endpoints

#### Replace overlays for a file

```
PATCH /api/v1/studio/files/{file_id}/overlays
Body:    { overlays: StudioOverlay[] }
Returns: { overlays: StudioOverlay[] }     // server-assigned id/z/created_at/updated_at filled in
```

The frontend always sends the full overlays array. Server validates and replaces. Idempotent. No per-overlay CRUD endpoints.

#### Upload an overlay image asset

```
POST /api/v1/studio/files/{file_id}/overlay-assets       (multipart)
Returns: { asset_url, mime_type, file_size, file_name }
```

- Storage path: `s3://.../studio/{file_id}/overlays/{ulid}.{ext}`.
- Max 10 MB.
- Accept: `image/png`, `image/jpeg`, `image/webp`, `image/svg+xml`.
- The returned `asset_url` is what the frontend assigns to `overlay.payload.asset_url`.

#### File detail response

The existing `GET /api/v1/studio/files/{file_id}` response includes the new `overlays` field. No new endpoint for read.

### Validation (FormRequest)

`StoreOverlaysRequest`:

- `overlays`: required array, max 30 items.
- Each item:
  - `id`: nullable ulid (server fills if absent)
  - `type`: required, in `['text', 'image']`
  - `x`, `y`, `width`, `height`: required, numeric, between `0` and `1`
  - `rotation`: required, numeric (any float)
  - `z`: nullable int (server fills if absent on insert)
  - `payload`: required object, validated against discriminator:
    - text → `content` string max 500, `color` regex `/^#[0-9A-Fa-f]{6}$/`
    - image → `asset_url` URL whose host matches our S3 bucket(s), `mime_type` in the allowed list
- 30-item cap is a sanity guard; sketch tool, no one needs more.

### Authorization

Reuse existing `StudioFile` ownership policy. The user must own the file (or be a collaborator if collaboration ships) to PATCH overlays or upload assets to the file's bucket prefix.

## Export flatten

The existing KV export path currently sends "the bg image of generation X." With overlays:

- Client renders the Konva stage at the bg's natural pixel dimensions with overlays composited in z-order.
- `stage.toDataURL({ pixelRatio })` produces the flattened PNG.
- Frontend uploads/sends that flattened PNG to the existing export endpoint instead of pointing at the raw bg URL.
- The export endpoint itself doesn't need to know about overlays — clean separation.

For the **Resizer hand-off** path, the same flatten output is what's handed to Resizer.

## Out of scope (v1)

Explicitly excluded so v1 stays small. All of these are anticipated for v2 and later — keeping the door open in the data model.

- z-order operations (bring forward / send back)
- Layers panel / sidebar
- Multi-select + group operations (move/align/delete as a group)
- Snap guides (to bg edges or center)
- Undo / redo
- Keyboard arrow nudging
- Copy / paste / duplicate
- Asset reuse picker (recently-uploaded overlay images)
- Brand Identity logo picker (auto-pull from `KvBrandIdentity.logos`)
- Project assets picker (existing `KvAsset[]` on the project)
- DAM browser
- Per-overlay PATCH endpoints
- Multi-user concurrent edit / optimistic concurrency / `version` field
- "Bake overlays into AI" path (regenerate bg with overlays as prompt context)

## Future work — known directions

How v1 deliberately leaves room for these:

- **z-order ops.** `z` is already a real integer column. Adding "bring forward / send back" is a UI change + one mutation; no migration.
- **Asset pickers (brand logos, project assets, DAM).** All produce an `asset_url` + `mime_type`. The data model doesn't change — only the picker UI in front of "Image overlay tool clicks the canvas."
- **Layers panel.** Pure FE — reads the same `overlays` array, sorted by `z`.
- **Multi-select.** Store needs `selectedIds: string[]` instead of `selectedId: string | null`. Konva supports multi-attach to a single Transformer.
- **Undo / redo.** Layer the existing `useKvOverlaysStore` on top of a redux-style history middleware, or maintain a snapshot ring inside the store. Either way, no backend impact.
- **AI bake.** Add a "Apply overlays to AI" button — sends `overlays` plus the bg as context to a new `mode: "compose"` stream. Doesn't touch v1 fields.

## Acceptance criteria

1. From a file with at least one generation, clicking the **Text** tool icon and clicking the canvas drops an editable text overlay at the click point. Inline edit opens immediately.
2. Clicking the **Image** tool icon opens an OS file picker; selecting an image uploads it and renders it centered on the canvas at default size.
3. Clicking an overlay selects it; corner handles resize, side handles stretch, the rotation handle rotates. Pressing `Delete` removes it.
4. Double-clicking a text overlay opens an inline `<textarea>` aligned to its bbox; typing + `Esc` commits. Empty content deletes.
5. The selected text overlay shows a small color chip; picking a color updates the rendered text.
6. Reloading the page restores all overlays in the same positions.
7. Generating a new bg version (chat or inpainting) leaves overlays in place.
8. Switching to an older version leaves overlays in place — they float on whichever bg is shown.
9. Toggling the **Edit Overlay** pill hides all overlays; toggling again restores them.
10. Exporting the current view produces a PNG with overlays flattened over the current bg.
11. Loading the file on a different browser / device shows the same overlays.

## Resolved decisions (auto-mode defaults)

- **Default text color** → flat **white** (`#FFFFFF`). Luminance-sampling adds code for marginal gain; users can change via the color chip in one click. (Earlier "luminance-based default" mention superseded — when adding text, the placeholder is white.)
- **Text editing fidelity (`<textarea>` vs Konva `Text`)** → accept the small visual jump at commit. Standard for any HTML-overlay-on-canvas editor (Figma, tldraw all do this). Acceptable for sketch tool.
- **SVG image overlay rendering** → SVGs are rendered as Konva `Image` nodes from the rasterized source URL (the browser rasterizes when loading via `new Image()`). No client-side rasterization step. Vector fidelity loss on heavy upscaling is acceptable for v1; if it bites, we can switch to a `<foreignObject>` overlay layer later.
