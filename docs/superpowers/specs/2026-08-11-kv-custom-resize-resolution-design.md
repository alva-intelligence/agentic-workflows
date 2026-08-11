# KV Studio — Custom resize resolution for layer-composed KVs

**Date:** 2026-08-11
**Author:** daffa
**Services:** web, api
**Status:** approved

## Problem

KV Resize offers a fixed menu of 32 platform presets. A user who imports a PSD
and needs 1240×1750 — a size no preset covers — has no way to ask for it.

The obvious explanation is that the image model constrains output dimensions.
That is not what blocks it. `_gpt_image_2_aligned_dims`
(`ai-service/app/tools/outpaint_image.py:43`) already accepts near-arbitrary
targets: it rounds each edge up to a multiple of 16, bumps the smaller edge
until total pixels clear gpt-image-2's 655,360 floor, then LANCZOS-resizes the
result back to the exact requested size. Arbitrary dimensions already work end
to end.

What blocks custom sizes is a closed preset registry in three places:

| Layer | Constraint |
|---|---|
| `web/src/types/kv/resize.ts` | `PlatformId` is a closed union of 32 literals; `PLATFORMS` is the registry |
| `api/config/studio.php` | `resize_platforms` — the server's copy of the same registry |
| `KvResizeExportController.php:92` | `'platform_ids.*' => [..., 'in:'.implode(',', $registryIds)]` |

## Why gate on layer-composed

Removing the registry constraint for *every* KV would be wrong, but not for the
reason the model story suggests. The real asymmetry is cost and fidelity.

Phase 1 of `2026-08-06-kv-layer-composed-resize-design.md` shipped.
`KvResizeExportService.php:41` branches on `$parent->isLayerComposed()`, and
when true the export row is created already `Done` (`:59`) with no job
dispatched (`:67`), no model call, and no credit charged. The tile renders from
layers projected at draw time by `resolveTileOverlays`.

So for a layer-composed KV, resize is pure geometry — any resolution is instant,
free, and lossless. For an AI-generated KV it is a gpt-image-2 outpaint that
costs credits and degrades at extreme ratios. Offering unbounded custom sizes on
the AI path changes the cost model; offering them on the layer path costs
nothing.

`isLayerComposed()` covers both PSD import and Magic Layers. Both store artwork
as overlays over a blank base, and both resize deterministically. One predicate,
already the resize branch point, so the UI and the server cannot disagree about
what is eligible.

## Decisions

| Question | Decision | Reasoning |
|---|---|---|
| Which sources get custom sizes? | Anything `isLayerComposed()` — PSD import and Magic Layers | Both resize without a model. Splitting them would need a new marker to distinguish two cases that behave identically. |
| How is a custom size identified? | Synthetic `platform_id` of the form `custom-{w}x{h}` | Needs no migration, and the existing unique index supplies dedup for free. |
| How does the client request one? | A separate `custom_sizes: [{width, height}]` field, not a client-built id string | The server validates the numbers and synthesizes the id. Regex-parsing a validated dimension out of a client-controlled identifier is the shape of a validation bypass. |
| What bounds? | 64–8192 per side | See below. |
| Where is the gate enforced? | api, with the web UI mirroring it | UI-only gating is the exact mistake the 2026-08-06 spec had to correct. |

### Why 64–8192

The tempting ceiling is `MAX_BASE_DIM = 4096` (`makeBlankBase.ts:42`), the cap a
PSD base board is downscaled to. It is the wrong ceiling. That cap applies to
the *flattened composite*; individual layer bitmaps go through
`canvasToPngUnderCap` (`psd/index.ts:66`), which downscales only until the PNG
fits the 10 MB upload cap, so layers keep PSD-native resolution. And for a
layer-composed KV the base is a blank white board by definition — upscaling it
past 4096 loses nothing, because all the detail lives in overlays. Capping at
4096 would cap tiles below the detail the layers actually carry.

The binding constraint is the browser. A tile is rendered and downloaded by
flattening it on a canvas (`KvResizeCanvas.downloadAll()` → JSZip). Chrome caps
a canvas at 16,384px per side and roughly 268M total pixels; past that `toBlob`
returns null or a blank bitmap — which would reproduce precisely the silent
blank-file bug this area just got fixed.

8192 per side is chosen so that **one rule suffices**: 8192 × 8192 = 67.1M
pixels, about 4× under Chrome's area ceiling, so a per-side cap is self-limiting
on area and a second total-pixel rule buys nothing. That is worth more than the
extra headroom a two-rule scheme would allow. This codebase's recurring failure
mode is precisely this kind of drift — four overlay renderers have already
diverged — and two bounds to keep in sync between web and api validation is two
chances for them to disagree.

Minimum 64 keeps degenerate 1px tiles out of the projection math.

## Non-goals

- **Custom sizes for AI-generated KVs.** They keep the preset menu.
- **Saved or reusable custom presets** per file, user, or workspace.
- **Changing the preset registry.** The 32 presets stay exactly as they are.
- **Fixing the two known defects nearby** — that an identical-size AI resize is
  not a no-op, and that `instagram-story` and `tiktok-video` are duplicate
  dimensions. Both are tracked in the 2026-08-06 spec.

## Design

### 1. Data model — no migration

`platform_id` is `string(64)`
(`2026_04_28_120000_create_kv_resize_exports_table.php:17`) and
`custom-8192x8192` is 17 characters. `width` and `height` are already columns;
the registry only ever supplied their values.

The table's unique index `(parent_generation_id, platform_id)` (`:30`) gives
dedup for free: requesting 1080×1350 twice synthesizes the same id, so
`firstOrCreate` returns the existing row rather than creating a duplicate tile.

### 2. Request and validation

`KvResizeExportController::store` gains an optional field:

```
custom_sizes            array, optional
custom_sizes.*.width    integer, 64..8192
custom_sizes.*.height   integer, 64..8192
```

Custom sizes never travel through `platform_ids`, whose `in:` rule against the
registry stays exactly as it is.

Two checks beyond the numeric bounds:

1. **The gate.** If `custom_sizes` is non-empty and `$parent->isLayerComposed()`
   is false, respond 422. For a layer-composed parent nothing is dispatched
   anyway, so a custom size cannot reach gpt-image-2 — this check makes that
   invariant true rather than incidentally true.
2. **Combined minimum.** `platform_ids` is `required|array|min:1` today. Once a
   request may legitimately carry only custom sizes, `platform_ids` becomes
   `sometimes|array` and the "at least one" requirement moves up to the pair:
   the request is invalid when both `platform_ids` and `custom_sizes` are empty
   or absent.

The controller synthesizes `custom-{width}x{height}` per entry and appends the
ids to the list handed to `createBatch`.

### 3. Batch creation

`KvResizeExportService::createBatch` currently throws
`InvalidArgumentException("Unknown platform: {$platformId}")` on a registry miss
(`:46`). It gains a custom branch: an id matching the custom form takes its
dimensions from the validated request rather than from the registry. The
`$isLayerComposed` short-circuit already present (`:41`, `:59`, `:67`) covers
custom rows without change — they are created `Done`, dispatch nothing, and
charge nothing.

`regenerate` (`:75`) needs no change: it already routes on
`$row->parentGeneration?->isLayerComposed()` (`:85`).

### 4. Read path

`KvResizeExportResource` already degrades on a registry miss — `platform_label`
falls back to the raw `platform_id`, `platform_group` to `null`. One refinement
so the UI has something real to render: for an id matching the custom form, emit
`platform_label` as `"1080 × 1350"` and `platform_group` as `"custom"`.

### 5. Web types

- `PlatformId` widens to ``KnownPlatformId | `custom-${number}x${number}` ``
- `PlatformGroup` gains `"custom"`
- `platformById()` synthesizes a `Platform` for a custom id instead of returning
  `undefined`

Everything else keyed by `PlatformId` is unaffected: the `exportsByPlatformId`
Map, crop windows, and analytics all treat it as an opaque string. Both
`Record<PlatformId, …>` sites (`useResizeExports.ts:109`, `api.ts:698`) are
wrapped in `Partial<>`, which tolerates a template-literal member.

### 6. UI

A "Custom size" row in `KvResizePanel`, beneath the three existing groups: two
number inputs and an Add action, with inline bounds feedback.

The row renders only when the parent generation is layer-composed. Web already
receives the signal — `layer_composed` arrives on generation metadata
(`services/kv/api.ts:244`), and `craftBaseRatio.ts` already reads
`craft_blocked_reason` for the Craft equivalent. For an AI-generated KV the row
is replaced by a one-line explanation in the same style as
`craftBlockedMessage`, in Indonesian to match the existing copy.

Download filenames need no change. The browser download path names a tile
`` `${row.platformId}.png` `` (`KvResizeCanvas.tsx:794` for a single tile, `:818`
inside the ZIP), so a custom tile already lands as `custom-1080x1350.png`. The
server's `downloadZip` endpoint builds `{platform_id}-{width}x{height}.png`
(`KvResizeExportController.php:350`), which would read redundantly as
`custom-1080x1350-1080x1350.png` — but the 2026-08-06 spec established that
endpoint is never called by web and deliberately left it alone. This spec does
the same rather than touch dead code.

### 7. Analytics

`kv_resize_requested` and `kv_resize_succeeded` already carry `platform_id` as a
string, so custom ids flow through unchanged. Add a `custom_size` boolean to
both so preset and custom usage are separable in PostHog — the whole point of
shipping this is to learn which sizes people actually need.

## Testing

Unit, no network:

1. Id synthesis — validated dims produce `custom-1080x1350`.
2. Bounds — 63 and 8193 are both rejected on each axis; 64 and 8192 accepted.
3. **Gate** — a non-layer-composed parent plus any custom size returns 422.
4. Dedup — the same custom size requested twice yields one row.
5. Empty request — neither `platform_ids` nor `custom_sizes` returns 422.
6. Resource — a custom id renders label `"1080 × 1350"` and group `"custom"`.
7. `platformById` — synthesizes for a custom id, still resolves presets.
8. Panel — the custom row is hidden for an AI-generated KV and shown for a
   layer-composed one.

Manual: import a PSD, add a custom size, confirm the tile renders on canvas and
downloads with real artwork; then one flatten check at 8192 in Safari.

## Risks and limits

**Safari canvas area.** Safari's canvas limits are stricter than Chrome's, so an
8192 tile may flatten correctly in Chrome and fail in Safari. The failure mode
matters: `toBlob` returning null yields a missing file, but a silently blank
bitmap yields the exact bug class this area was just fixed for. One manual check
before ship, and the download path should treat a null blob as an error rather
than skipping the file quietly.

**Blank-base false positives.** Inherited from the existing classifier, not
introduced here. A KV whose base is legitimately near-uniform — a solid colour
backdrop — can be misclassified as layer-composed, and would then be offered
custom sizes whose tiles it cannot honour. The 2026-08-06 spec already flags
this heuristic as unverified against real data; this feature widens its
consequences slightly.

**No upper bound on tile count.** Custom sizes make it easy to queue many tiles
in a session. Each is free for a layer-composed KV, but "Download all" flattens
every tile in the browser and zips them, so memory pressure scales with count ×
area. Not addressed here; worth watching if users start generating dozens.
