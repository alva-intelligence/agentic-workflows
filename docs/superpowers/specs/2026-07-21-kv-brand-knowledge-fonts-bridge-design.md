# KV — Surface Brand Knowledge Fonts in the Text Font Picker

**Date:** 2026-07-21
**Author:** daffa
**Services:** api, web
**Status:** approved

## Problem

Users can upload custom font files (`.ttf/.otf/.woff/.woff2`) in **Brand Knowledge**
(the Brand Identity tab). Those fonts are stored, but they do **not** appear in the KV
text-overlay font picker, so a user cannot set KV text in a font they added to their brand.

The cause is that the app has two independent brand-font stores:

| | Brand Knowledge fonts (System A) | KV brand fonts (System B) |
|---|---|---|
| Upload UI | Brand Identity tab (`BrandIdentityTab.tsx`) | KV picker "Upload font" (`KvTextFontToolbar.tsx`) |
| Backend store | `brands.fonts` JSONB column | dedicated `brand_fonts` table |
| Upload endpoint | `POST /v1/brands/{id}/identity/fonts` | `POST /v1/studio/brands/{id}/fonts` |
| List endpoint | `GET /v1/brands/{id}/identity` (`fonts[]`) | `GET /v1/studio/brands/{id}/fonts` |
| Per-font shape | `{ name, file_path, is_primary }` | `BrandFont { id, name, font_family, url, format, ... }` |
| Returns a load-ready URL? | No — raw S3 object key | Yes — resolved `url` |
| Stable CSS family id? | No — name only | Yes — `font_family` = `bf_<ulid>` |

The KV font picker reads **System B** only (`useBrandFonts` → `GET /v1/studio/brands/{id}/fonts`).
Fonts uploaded in Brand Knowledge land in **System A**, so they never reach the picker.

KV's rendering side is already capable: it loads fonts from arbitrary URLs via the `FontFace`
API (`fonts/fontLoader.ts` → `new FontFace(family, url("<url>"))` → `document.fonts.add`) and
applies them on both the Konva and Fabric canvases. Nothing on the rendering side needs to change.

## Goal

A font a user adds in Brand Knowledge becomes selectable in the KV text-overlay font picker,
rendered correctly on canvas, with no change to where users upload fonts.

## Non-goals

- **No consolidation / migration.** System A and System B stay as separate stores. This is a
  read-only bridge, explicitly not a merge (that was considered and scoped out).
- **No change to either upload flow.** Both uploaders stay exactly as they are.
- **No change to the Brand Identity endpoint.** Its known raw-S3-key limitation is sidestepped,
  not fixed, here.
- **No new font-weight support.** The KV text payload has no `fontWeight` field today; that is
  unchanged.

## Approach

Merge on the **backend**, inside the **existing** KV endpoint. `GET /v1/studio/brands/{id}/fonts`
continues to return the `brand_fonts` rows and additionally maps the brand's Brand Knowledge
fonts (`brands.fonts` JSON) into the **same `BrandFontResource` shape**. The KV frontend receives
one unified list — no new query, no new hook, and the existing FontFace/Konva/Fabric pipeline
consumes it unchanged.

Merging on the backend is required, not just convenient: resolving a System A `file_path`
(an S3 object key) into a URL needs `Storage::disk('s3')->url(...)`, which is backend-only
knowledge. A purely frontend merge could not produce a loadable URL.

### Mapping a Brand Knowledge font into `BrandFontResource`

For each entry in `brands.fonts` (`{ name, file_path, is_primary }`):

| Resource field | Value |
|---|---|
| `url` | `Storage::disk('s3')->url($file_path)` — same accessor `BrandFont` (System B) uses |
| `font_family` | `"bk_" . substr(sha1($file_path), 0, 16)` — deterministic, so an overlay that stored this family resolves to the same `FontFace` key on any later load |
| `id` | the same synthesized `bk_...` family id (System A fonts have no row id) |
| `name` | `name` (the display name) |
| `format` | derived from the `file_path` extension, lowercased (`ttf`/`otf`/`woff`/`woff2`) |
| `source` | `"brand_identity"` (see below) |
| `file_size`, `original_filename`, `created_at`, `updated_at` | best-effort / null — not required by the picker or the loader |

### New `source` discriminator

`BrandFontResource` gains a `source` field:

- `"studio"` — a real `brand_fonts` row (System B). Deletable via `DELETE /v1/studio/fonts/{id}`.
- `"brand_identity"` — mapped from `brands.fonts` (System A). Managed in Brand Knowledge; **not**
  deletable from KV (no `brand_fonts` row exists for it).

The web `BrandFont` type gains the matching `source: "studio" | "brand_identity"` field.

### Dedup

If the same font exists in both stores (same case-insensitive `name`), it is collapsed to a
single entry and the **`"studio"`** one wins (it is the deletable, purpose-built record; the
System A twin would be a non-actionable duplicate). Implementation: build the list studio-first,
key a set/map by `strtolower(trim(name))`, and skip a Brand Knowledge font whose name is already
present. Worst case — two genuinely different fonts that happen to share a name — hides one; this
is rare and recoverable by renaming, and is preferable to showing an indistinguishable twin.

## Frontend changes (small)

The picker's existing merged **"Brand fonts"** group renders both sources together — to the user
they are all just brand fonts. The only behavioral change:

- The **delete action is rendered only when `source === "studio"`.** Brand-Knowledge-sourced
  fonts show no delete affordance in KV.

Everything else is unchanged: selection writes `fontFamily = <font_family>` onto the overlay,
`registerBrandFonts` builds the `FontFace` from `url`, and Konva/Fabric render via
`resolveOverlayFamily`. Because the mapped entries are the same shape, they flow through all of
this with no special-casing beyond the delete gate.

## Error handling

- A Brand Knowledge font with a missing or unresolvable `file_path` is **skipped** during
  mapping rather than emitted with a broken `url` — a font that cannot load should not appear
  selectable. This mirrors `fontLoader.ts`, which is already non-throwing per font.
- `brands.fonts` being `null` or `[]` yields no mapped entries (the endpoint returns just the
  System B rows, i.e. today's behavior).
- Malformed entries (missing `name` or `file_path`) are skipped.

## Accepted limitation

The synthesized `bk_` family id is derived from the S3 `file_path`. If a user **deletes and
re-uploads** the same font in Brand Knowledge, the path changes, so the family id changes, and
any existing KV overlay that referenced the old id loses its font (falls back to the default
family). This exactly mirrors how System B already behaves when a `brand_fonts` row is deleted.
Building path-stable identity would require giving System A fonts their own persistent id — the
consolidation this design deliberately excludes — so the limitation is accepted rather than fixed.

## Testing

**api (Pest, Unit-safe — no DB per repo convention):**
- The mapper turns a `{ name, file_path, is_primary }` entry into a `BrandFontResource` with a
  resolved `url`, a `bk_<16 hex>` `font_family`, `source: "brand_identity"`, and the correct
  `format` from the extension.
- The `font_family` is deterministic: the same `file_path` yields the same id across calls.
- `null` / `[]` / malformed `brands.fonts` yields no mapped entries and does not error.
- Dedup: a Brand Knowledge font whose name case-insensitively matches a `brand_fonts` row is
  omitted; the `"studio"` entry is the one returned.
- A `brand_fonts` row serializes with `source: "studio"`.

**web (`bun test`):**
- The picker renders `source: "brand_identity"` fonts in the "Brand fonts" group with **no**
  delete control, and `source: "studio"` fonts **with** one.
- The `BrandFont` type change compiles and `useBrandFonts` consumers handle the new field.

The real gate for web remains `bun run build`; for api, Unit tests (the Feature suite is
pre-existing-broken on fresh migrate in this repo).

## Blast radius

| File | Change |
|---|---|
| `api/app/Http/Controllers/Api/Studio/StudioBrandFontController.php` | `index` also maps + dedups Brand Knowledge fonts |
| `api/app/Http/Resources/Studio/BrandFontResource.php` | add `source` field |
| `api/app/.../` (new) | a small mapper (Brand Knowledge font → resource array) + its Unit test |
| `web/src/types/studio.ts` | add `source: "studio" \| "brand_identity"` to `BrandFont` |
| `web/src/components/studio/kv-generator/KvTextFontToolbar.tsx` | gate the delete action on `source === "studio"` |

No change to: either upload flow, the Brand Identity endpoint, `fontLoader.ts`, the Konva/Fabric
render paths, or the overlay payload shape.

## Open questions

None.
