---
title: KV Canvas Custom Fonts
slug: kv-canvas-custom-fonts
author: daffa
created: 2026-07-15
status: draft
services: [api, web]
---

# KV Canvas Custom Fonts — Design

## Overview

Let users choose the font for **text overlays** on the KV canvas, and upload their
own **OTF/TTF** fonts to use there. Today there is no font-selection system for
overlays at all — both canvas implementations hard-code a single font. This feature
adds (1) a font-family picker for text overlays and (2) brand-scoped custom font
upload that feeds that picker.

Scope is deliberately narrow: **font family only**. Font size stays auto-derived
from the overlay box height, and the existing color control is unchanged. Weight,
italic, and manual size are explicit non-goals for this phase.

## Current State (as-is)

- **Text overlays** (`StudioOverlay`, `type: "text"`) carry only
  `{ content, color }` — no font field. `web/src/types/studio.ts:449`.
- **Fabric.js** canvas (`KvFabricCanvas`, the current default, gated by the
  fail-open `KV_MULTI_BOARD` PostHog flag) hard-codes `fontFamily: "Geist"` on the
  `fabric.Textbox`. `web/src/components/studio/kv-generator/KvFabricCanvas.tsx:995`.
- **Konva** canvas (`KvKonvaCanvas`, the legacy kill-switch fallback when the flag
  is off) sets no `fontFamily`, so Konva defaults to Arial.
  `web/src/components/studio/kv-generator/KvKonvaCanvas.tsx:1801`.
- The final KV is flattened **client-side** via `stage.toDataURL()`
  (`exportFlatten.ts` → `flattenTile.ts`). **There is no server-side text
  rasterization.** This is the key enabler: a custom font only needs to be loaded
  into the browser before flatten.
- Brand-scoped shared assets already exist as precedent: `BrandOverlayPreset`
  (`web/src/types/studio.ts:478`) with `StudioBrandOverlayPresetController` on the
  api side (`GET/POST brands/{brand}/overlay-presets`, `DELETE overlay-presets/{id}`).
- Overlay image uploads already establish the storage pattern:
  `StudioOverlayAssetController` stores on the `s3` disk via
  `storeAs(...)` + `Storage::disk('s3')->url($path)`.

## Decisions (locked during brainstorming)

1. **Ownership: brand-scoped.** An uploaded font belongs to a brand and is reusable
   by everyone working on that brand — mirrors `BrandOverlayPreset`.
2. **Picker contents: built-in set + custom.** Ship a curated list of the fonts the
   app already bundles (Neue Montreal, Space Grotesk, Archivo, Funnel, General Sans,
   Geist) as ready-to-use options, plus the brand's uploaded fonts.
3. **Toolbar scope: font family only.** Auto-size-from-height and color are untouched.
4. Upload limits: **TTF + OTF**, **5 MB** max.
5. Gated behind a PostHog flag **`kv_custom_fonts`**, fail-closed.
6. Delete available to any brand member (matches preset behavior).

## Approach

**Chosen — A: Raw font files in S3 + `FontFace` API loading.** Store the uploaded
`.ttf`/`.otf` as-is in S3 under a new `brand_fonts` table; the browser loads each via
the `FontFace` API and registers it with `document.fonts` before the canvas renders.
Works directly with the existing client-side flatten. No new server dependencies.

**Rejected — B: server-side transcode to WOFF2 on upload.** Smaller/faster delivery,
but adds a build dependency and a conversion job for marginal gain at current scale.
Revisit as a later optimization; the `format` column and stable `font_family` id make
it a non-breaking upgrade.

**Rejected — C: inline font bytes on the file/overlay record.** Bloats every file, no
brand reuse, contradicts the brand-scoped decision.

## Architecture

### api

**Migration — `create_brand_fonts_table`:**

| Column | Type | Notes |
|--------|------|-------|
| `id` | ULID (pk) | |
| `brand_id` | FK → brands | indexed |
| `workspace_id` | FK → workspaces | for the workspace-scoped delete guard |
| `name` | string | display name, e.g. "Acme Sans" |
| `font_family` | string | stable CSS family id, e.g. `bf_<ulid>`; unique. Avoids collision with built-ins and other brands. |
| `file_path` | string | S3 path |
| `original_filename` | string | |
| `format` | string | `ttf` \| `otf` |
| `file_size` | integer | bytes |
| `created_by` | FK → users | |
| `created_at` / `updated_at` | timestamps | |

**Model — `BrandFont`** with a `url` accessor (`Storage::disk('s3')->url($file_path)`).

**Controller — `StudioBrandFontController`**, mirroring
`StudioBrandOverlayPresetController` (same `authorizeBrand` = `$brand->workspace_id
=== $request->user()->current_workspace_id`):

- `index(Request, string $brandId)` → list brand fonts (`where('brand_id', …)`).
- `store(UploadBrandFontRequest, string $brandId)` → validate, store on `s3` at
  `studio/brands/{brand}/fonts/<ulid>.<ext>`, generate `font_family = "bf_".Str::ulid()`,
  persist row, return it (201).
- `destroy(Request, string $id)` → workspace-scoped delete (matches preset destroy);
  best-effort delete the S3 object.

**FormRequest — `UploadBrandFontRequest`:** `file` required, `mimes:ttf,otf` +
extension whitelist, `max:5120`. Add a magic-byte sniff (font signatures:
`0x00010000`/`true`/`OTTO` for TTF, `OTTO` for OTF) to reject mislabeled files.

**Routes** (in the studio group, next to overlay-presets):
- `GET  brands/{brand}/fonts`
- `POST brands/{brand}/fonts`
- `DELETE fonts/{id}`

### web

**Types.** Extend the text payload in `web/src/types/studio.ts`:

```ts
payload:
  | { type: "text"; content: string; color: string; fontFamily?: string }
  | { type: "image"; asset_url: string; mime_type: string };
```

`fontFamily` undefined ⇒ default (`"Geist"`). Existing overlays and
`BrandOverlayPreset` payloads are unaffected (optional field). Add a `BrandFont`
type + the same optional field to the preset payload shape.

**Font registry (built-ins).** A small static module mapping each bundled font to its
real CSS family string (from `next/font/local` `.style.fontFamily`) and a label. This
is the "Built-in" group and the source of the default.

**Data + loader (canvas-agnostic):**
- `useBrandFonts(brandId)` — TanStack Query hook fetching `GET brands/{brand}/fonts`.
- `registerBrandFonts(fonts)` — for each font, `new FontFace(font.font_family,
  \`url(${font.url})\`).load()` then `document.fonts.add(face)`. Idempotent (skip
  families already registered). Returns when all requested faces are ready.
- Canvas text renders with a fallback until the face is ready, so after registration
  completes the canvas must re-render: Fabric `canvas.requestRenderAll()`, Konva
  `layer.batchDraw()`. The canvases call the loader on mount (with the brand's fonts)
  and again when a new font is uploaded.

**Rendering.** Both canvases read `overlay.payload.fontFamily ?? DEFAULT_FAMILY`:
- Fabric: pass to `new fabric.Textbox(..., { fontFamily })` and `set({ fontFamily })`
  on the update path (`KvFabricCanvas.tsx:986/995`).
- Konva: add `fontFamily={…}` to the overlay `<Text>` (`KvKonvaCanvas.tsx:1801`).

**Flatten safety (critical).** Before `stage.toDataURL()` in the flatten helpers,
`await document.fonts.ready` and await each in-use `FontFace`, so the exported PNG
never bakes the fallback font. This is the single most important test.

**Picker UI.** A floating **text toolbar**, shown when a text overlay is selected,
containing:
- A font-family dropdown, grouped **Brand fonts** (each row previewed in its own
  face) and **Built-in**. Selecting one patches `payload.fontFamily` on the overlay
  (goes through the normal overlay `update` → autosave / Y.Doc path).
- An **"Upload font"** action: file input (`.ttf,.otf`) → `POST brands/{brand}/fonts`
  → optimistic insert into the list + `registerBrandFonts` → auto-select on the
  current overlay. Upload dialog carries a one-line licensing acknowledgment
  ("you have rights to use this font") — documented stance, not enforced.
- Delete a brand font from its dropdown row (any brand member).

**Feature flag.** Gate the toolbar's font affordances behind `kv_custom_fonts`
(PostHog, fail-closed) per the frndos-feature-flags convention. Flag off ⇒ toolbar
hides the font control and overlays render with the default family (current behavior).

## Data Flow

1. User selects a text overlay → text toolbar appears (flag on).
2. User uploads a font → `POST brands/{brand}/fonts` → S3 + `brand_fonts` row →
   response added to the query cache → `registerBrandFonts` loads the face →
   overlay `payload.fontFamily` set → canvas re-renders in the new face.
3. Autosave/Y.Doc persists the overlay with its `fontFamily`.
4. On reopening the file, `useBrandFonts` + `registerBrandFonts` reload the faces
   before/at canvas mount; overlays render correctly.
5. Export/download → flatten awaits fonts ready → `toDataURL` bakes the true face.

## Error Handling

- Upload rejected (bad type/size/signature) → 422 with a clear message; toolbar shows
  an inline error, no optimistic row.
- Font URL fails to load in the browser (`FontFace.load()` rejects) → the family falls
  back to the default; log once, don't block the canvas.
- Deleting a font still referenced by overlays → those overlays fall back to the
  default family (undefined family resolves to default). No cascade needed.

## Testing

- **api:** `BrandFont` unit test (accessor); controller Feature test if the suite is
  runnable, else Unit-level request-validation tests (mimes/size/signature) —
  respecting the known Feature-suite fresh-migrate limitation.
- **web:** loader idempotency + "await before flatten" test (flatten waits on
  `document.fonts`), payload-default resolution (`fontFamily ?? default`), picker
  select → payload patch, and a Konva/Fabric parity check that both read the field.

## Non-Goals (this phase)

- Weight/italic/style selection and manual font size.
- Google Fonts / external font library integration.
- Server-side WOFF2 transcoding.
- Any ai-service change (text is never rasterized server-side).

## Services Touched

- **api:** migration, `BrandFont` model, `StudioBrandFontController`,
  `UploadBrandFontRequest`, routes.
- **web:** `studio.ts` types, built-in font registry, `useBrandFonts` + font loader,
  text toolbar + font picker, Fabric + Konva render wiring, flatten guard, feature flag.
- **ai-service:** none.
