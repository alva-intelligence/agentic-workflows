# KV PSD Import — Fidelity & Structure

> **Date:** 2026-07-27
> **Author:** Daffa
> **Status:** draft
> **Services:** web, api
> **Delivery:** `feature/daffa/vc-kv-psd-import-fidelity` (web + api), branched from `develop`

## Overview

The KV generator can already import a `.psd` client-side (ag-psd), turning raster layers into
image overlays and text layers into editable text overlays. What it cannot do is reproduce the
PSD accurately: masks, blend modes, clipping masks and layer effects are all ignored, off-canvas
geometry is clamped into the frame, and a PSD dropped on a board with a different aspect ratio is
non-uniformly stretched. The resulting board does not look like the source file.

Benchmarked against thebrief.ai importing the same PSD (`MULTIGUNA_KV 2_2.psd`), the visible
differences are: an opaque black band where a masked gradient scrim should be, squashed and
displaced artwork, and a flat layer list where the PSD has a group tree.

This spec covers two phases:

- **Phase 1 — fidelity.** Bake mask / clipping / effects into each layer's raster at parse time,
  pass blend modes through to the renderers as data, stop clamping geometry, create the base board
  at the PSD's own ratio, import simple vector layers as `shape` overlays, and put a pre-import
  review dialog — plus an explicit **Import PSD** entry point — in front of the whole thing.
- **Phase 2 — structure.** Photoshop-style group nesting via `parent_id` + a `group` overlay type,
  with rendering staying flat.

The organising principle: **anything intrinsic to a layer becomes pixels at parse time; anything
compositional stays data and travels to the renderer.** Mask, clipping and effects are intrinsic.
Blend mode and group membership are compositional.

## Current State

| Concern | Today | File |
|---|---|---|
| Parse | `readPsd(buffer, { skipThumbnail: true })`, main thread | `web/src/lib/studio/kv/importPsd.ts:422` |
| Masks | `layer.mask` never read — only `layer.canvas` (unmasked pixels) | `importPsd.ts:458` |
| Blend modes | `layer.blendMode` never read; no `globalCompositeOperation` anywhere in either renderer | — |
| Clipping | `layer.clipping` never read | — |
| Effects | `layer.effects` never read (not baked into `layer.canvas` by ag-psd) | — |
| Groups | Recursed and discarded; opacity multiplied down into leaves | `importPsd.ts:441` |
| Geometry | Clamped into `[0,1]` | `importPsd.ts:174` |
| Aspect | Rects are fractions of the *board* ⇒ non-uniform stretch on mismatch | — |
| Base board | Flattened composite uploaded as base, layers stacked on top | `KvGeneratorLayout.tsx:3457` |
| Missing fonts | Import parked mid-flight, resumed from a dialog | `KvGeneratorLayout.tsx:3140` |
| Cap | `max:100` server-side; excess silently sliced off the top of the stack | `UpdateStudioFileOverlaysRequest.php:27` |

Two facts that shape the design, both verified:

1. **`layer.mask.canvas` is already populated.** Only `skipLayerImageData` would suppress it, and we
   don't pass it. The mask pixels have always been available — we simply never read them. Same for
   `clipping`, `effects`, `vectorFill` / `vectorStroke`.
2. **The server already allows off-canvas geometry** — `x`/`y` in `-5..5`, `width`/`height` up to `5`
   (`UpdateStudioFileOverlaysRequest.php:31`). The clamping is a purely client-side self-inflicted
   limitation and needs no API change to remove.

## Constraints

- **Two renderers.** `KvFabricCanvas` (4,097 lines, main canvas) and `KvKonvaCanvas` (2,413 lines,
  tile editor + resize) are independent. **Export flattens through the Konva stage**
  (`overlays/exportFlatten.ts`), not Fabric — so any live render feature must be implemented in both
  or the download will disagree with the canvas.
- **`overlays` is a JSON column** cast to `array` on `StudioFile` (`app/Models/StudioFile.php:46`).
  No database migration is needed for either phase; only request validation changes.
- **`validated()` silently strips unlisted payload fields.** Every new payload key must be
  whitelisted in `UpdateStudioFileOverlaysRequest` or it will be dropped on save.

## Phase 1 — Fidelity

### Module structure

`importPsd.ts` is 536 lines and already carries font matching, text conversion, geometry,
compositing and encoding. Phase 1 roughly doubles it, so it splits into a focused module:

```
web/src/lib/studio/kv/psd/
  index.ts       orchestration — walk the tree, emit drafts
  bake.ts        mask ⊗ clipping ⊗ effects → a flattened layer canvas
  blend.ts       PSD blend mode → canvas globalCompositeOperation (+ unsupported set)
  geometry.ts    PSD px bounds → normalized rect (no clamping) + aspect fit
  text.ts        text layer → text draft, font matching
  vector.ts      vectorFill / vectorStroke → shape payload
  types.ts       draft types
```

Each is a pure function over ag-psd structures and a canvas — unit-testable without a browser.
`KvGeneratorLayout` keeps calling `importPsd()` with essentially the same signature.

**Key seam:** `bake.ts` returns a `HTMLCanvasElement`; `index.ts` encodes it to a blob. Tests assert
pixels via `getImageData` rather than decoding PNGs.

### Mask baking

`layer.mask` carries its own canvas *and its own bounds*, frequently different from the layer's,
plus `defaultColor` (the value covering everything outside the mask rect: `0` hidden, `255` visible)
and `disabled`.

1. Allocate a canvas at the layer's bounds; draw `layer.canvas`.
2. Build an alpha canvas the same size, filled with `defaultColor`, then draw `mask.canvas` at
   `(mask.left − layer.left, mask.top − layer.top)`.
3. **Convert luminance to alpha** — the mask is grayscale; read `ImageData`, set `a = r`, write back.
   This step is the one that is easy to get subtly wrong.
4. Composite the layer against it with `destination-in`.

Skip entirely when `mask.disabled`. `realMask` (vector masks) receives the same treatment when
present. This is the fix for the black band.

### Clipping masks

`layer.clipping === true` means "clip to the alpha of the nearest non-clipping layer below me,
within the same group"; a run of consecutive clipping layers all clip to the same base. Bake with
`destination-in` against the base's alpha.

Both layers remain **separate overlays** — the clipped one is simply cropped, so it stays
individually selectable and movable.

### Layer effects

Baked: **drop shadow, stroke, color overlay, gradient overlay**. Out of scope and reported as
skipped: bevel, satin, inner/outer glow.

A drop shadow extends beyond the layer's bounds, so baking must **grow the output rect** by the
effect's extent. This is only safe because of the geometry change below.

**Text layers are exempt from baking** — they stay live and editable, which is the point of
importing them as text. A text layer carrying a stroke or shadow keeps the text and loses the
effect, reported per-layer in the review dialog. (Both Fabric and Konva support text `stroke` and
`shadow` natively, so passing these through as data is a follow-up candidate — deliberately not in
scope here.)

### Blend modes (data, not pixels)

`payload.blendMode` is added to the **text, image and shape** payloads (a PSD text layer can carry a
blend mode too), whitelisted in api, and assigned to `globalCompositeOperation` on the object in
**both** renderers. Group payloads do not need it — a group with a non-pass-through blend is baked
at parse time (see phase 2).

- **Maps 1:1 (16):** normal, multiply, screen, overlay, darken, lighten, color dodge, color burn,
  hard light, soft light, difference, exclusion, hue, saturation, color, luminosity.
- **Approximated:** `linear dodge` → `lighter`.
- **No equivalent:** dissolve, vivid light, linear light, pin light, hard mix, divide, subtract,
  darker color, lighter color → fall back to `normal` **and report the layer in the review dialog**,
  so the loss is visible rather than silent.

`'pass through'` only occurs on groups and is the default; phase 1 ignores it.

Per-layer blend is correct in a flat stack: Canvas 2D's `globalCompositeOperation` composites against
everything already painted beneath it on the same canvas, which is exactly Photoshop's pass-through
semantics.

### Geometry

**Stop clamping.** `normalizeRect` currently forces every edge into `[0,1]`, displacing and resizing
any layer that bleeds past the artboard — full-bleed photos, background plates, and now anything
with a baked drop shadow. True bounds are preserved, clamped only to the server's hard limits
(`-5..5`, size `≤5`). The minimum-size floor stays so a 1px artifact cannot become unselectable.

**Aspect mismatch: fit, never stretch.** Overlay rects are fractions of the *board*, so a 1:1 PSD on
a 4:5 board stretches every layer. Instead compute a uniform fit-rect (aspect preserved, centered)
and map all PSD geometry into it. No dialog, no distortion — the design lands correctly proportioned
with margin, and the user can scale from there.

### Base board

An empty-canvas drop creates a **blank base at the PSD's own dimensions** (capped at 4096), not the
flattened composite. `makeBlankBase` gains an explicit-dimensions variant alongside its
`KvArtboardRatio` form.

The composite is still parsed, but only as a **fallback** for the case where zero layers import
successfully, so a PSD never lands as an empty board.

Rationale: stacking reconstructed layers on top of a perfect composite makes every reconstruction
error maximally visible, doubles the pixels baked into every export, and reveals a ghost copy of a
layer underneath itself when the user drags it.

### Vector layers → `shape` overlays

Conservative translation: solid-fill rectangles, ellipses and lines with simple paths become real
`shape` overlays — crisp at any scale and recolorable. Anything with a complex path, pattern fill or
multi-stop gradient falls back to raster. Both renderers already draw shapes.

### Limits

- Server cap `max:100` → **300**; the client `MAX_OVERLAYS_PER_FILE` constant is kept in sync.
  Today anything past 100 is silently sliced off the top of the stack.
- Per-layer PNG stays capped at 10 MB with the existing downscale loop.
- Parsing stays on the main thread. Moving ag-psd into a worker requires `OffscreenCanvas` plumbing
  and is deliberately out of scope; phase 1 adds a layer-count / file-size guard and honest progress
  in the existing blocking overlay instead.

### Import review dialog

Opens **after parse, before any upload** — the entire tree, every warning and the exact dimensions
are known client-side before we touch the network, so Cancel costs nothing.

Contents:

- Filename and `W × H px`
- Select-all, then the PSD's real group tree with indentation
- Per-row type icon (`Aa` text, image, shape, folder)
- **Non-selectable rows with a clip indicator** for clipped and adjustment layers, nested under the
  layer they bake into — they do not survive as independent objects, and the dialog should say so
- Selected count against the cap: `24 of 31 layers · max 300`

Per-row warning badges:

| Badge | Meaning |
|---|---|
| Missing font | text layer's PSD font isn't available |
| Blend not supported | e.g. vivid light → will render as normal |
| Effect dropped | bevel / satin / glow won't be baked |
| Group flattened | phase 1 only: groups are shown but do not survive as groups |
| Group baked | phase 2 only: a non-pass-through blend group imports as one flat layer |

The dialog always displays the PSD's **true group tree**, because it is built from the parse result
rather than from the overlay model. In phase 1 that tree is display-only — selecting a group selects
its descendants, and every group is flattened on import (the "Group flattened" badge states this
plainly). Phase 2 changes what the import *produces*, not what the dialog *shows*.

**Selection semantics:** tristate. Unchecking a group unchecks descendants; a partially-selected
group renders indeterminate. Unchecked layers are never uploaded, which also gives users a manual
answer to the cap instead of silent truncation.

**It removes complexity.** Missing fonts are resolved *inside* the dialog ("2 fonts missing ·
Upload / Use default"), which deletes the park-and-resume state machine entirely — `psdFontPrompt`,
the mid-flight reopen, and the `psdImportBusyRef` guard that exists to stop a second drop racing the
parked state and double-placing every layer (`KvGeneratorLayout.tsx:3373`).

### Entry point

Alongside the existing drag-and-drop, an explicit **Import PSD** button (canvas toolbar + empty
state) opens a file picker and then the same review dialog and pipeline. Drag-and-drop is invisible
to users who don't think to try it.

### Not in phase 1

Groups in the overlay model (the layer list stays flat), rich per-run text styling, text effects as
data, worker-based parsing.

**Net effect:** after phase 1 the imported board *looks* like the PSD — masks respected, blend
correct, nothing stretched or shoved inside the frame — while the layer list still looks like
today's flat list.

## Phase 2 — Groups

### Data model

```ts
type StudioOverlay = {
  …
  type: "text" | "image" | "shape" | "group";
  /** Id of the group overlay this one lives inside. Null/absent = top level.
   *  Every pre-existing overlay is absent — the flat list is just a tree
   *  where everything is a root. */
  parent_id?: string | null;
  payload: … | {
    type: "group";
    name: string;
    opacity?: number;
    hidden?: boolean;
    locked?: boolean;
    collapsed?: boolean;  // panel UI state, persisted so it survives reload
  };
}
```

Group rows still satisfy the required geometry fields with `x:0, y:0, width:1, height:1,
rotation:0` — **meaningless by construction**. Anything needing a group's real bounds (focus-camera,
group drag) computes the union of its descendants on demand. No cached bbox is stored: it would be
one more invariant to keep in sync, and the union is cheap.

`z` keeps its meaning but now orders **siblings within a parent** rather than the whole file.

### Resolution

One new module, one job:

```
resolveOverlayTree(overlays) → {
  tree:     GroupNode[]        // for the layers panel
  drawList: ResolvedOverlay[]  // depth-first, siblings by z asc — for renderers
}
```

Each `ResolvedOverlay` carries its overlay plus **effective** values:

- `opacity` = own × every ancestor's
- `hidden` = own `hidden` **or** any ancestor's
- `locked` = own `locked` **or** any ancestor's
- `blendMode` = own only

Renderers stop sorting by `z` themselves and consume `drawList` order.

**This forces an audit, and it is the main risk in phase 2.** Every site reading `payload.opacity` /
`payload.hidden` / `payload.locked` directly must switch to the resolved value — most importantly
`renderBoardStage` and the export path, because a hidden *group* whose children aren't individually
hidden would otherwise still appear in the downloaded PNG. The resolver being the single source is
the mitigation for canvas/export divergence.

### API changes

No migration. Validation only:

- `type` and `payload.type` gain `'group'`.
- `parent_id`: `nullable, string, size:26`.
- Group payload rules: `name` (max 120), `opacity`, `hidden`, `locked`, `collapsed`.
- **Trap 1 — the `color` rule.** Currently `required_unless:overlays.*.payload.type,image`
  (`UpdateStudioFileOverlaysRequest.php:82`), which would require groups to carry a hex color.
  Groups must join the exclusion.
- **Trap 2 — referential integrity.** `withValidator` must verify every `parent_id` resolves to a
  `group` overlay **in the same payload array**, and reject cycles and depth beyond a limit (10).
  A cycle would hang the client resolver in an infinite walk.

### Import changes

`importPsd` currently multiplies group opacity down into leaves and discards the group
(`importPsd.ts:441`). That inverts: groups become real group drafts carrying their own
opacity/hidden/name, and leaves gain a `parent_id`.

Exception: a group with a **non-pass-through blend mode** cannot render correctly in a flat stack, so
it is composited at parse time and imported as a single baked layer. The user loses the ability to
edit inside it; the review dialog flags it with the "Group baked" badge.

### Layers panel

`KvLayersPanel` (782 lines) gains nesting with indentation, collapse/expand, group-level visibility /
opacity / lock, and drag-to-reorder within and across groups. Reordering is the fiddly part: a drop
must resolve to a `(parent_id, z)` pair, and dropping onto a collapsed group means "into it, at the
top".

### Group drag (last, cuttable)

Selecting a group row selects its descendants as a Fabric `ActiveSelection` (Konva equivalent in the
tile editor); dragging applies the delta to each and writes all back in one save.

**Group resize and rotate are out of scope** — they require the parent-relative coordinate model
that real nested nodes would provide, and must not creep in through the back door.

### Why `parent_id` and not real nested nodes

Real `fabric.Group` / `Konva.Group` nodes would give correct group-level blend and group transforms,
but child coordinates become **parent-relative**, and our overlay geometry is normalized against the
*board*. That contract is load-bearing across both renderers plus `adaptiveSizing`, `gestureMath`,
`dragGuides`, `focusCamera`, preset application, the resize canvas and export. The extra value over
`parent_id` is narrow (group-as-a-unit transforms, group blend modes) and it buys that by putting
selection, dragging, snapping and export back on the table for KVs already in customers' hands.

`parent_id` stores exactly the tree that nested nodes would need, so this is not a dead end — a
future move to real nodes is a renderer-only change with no data migration.

## Testing

**Unit (`bun test`).** Existing PSD tests synthesize files in-process with `writePsd` +
`initializeCanvas` (`importPsd.test.ts:237`); ag-psd can also write masks, clipping flags, blend
modes and effects, so every new behaviour is testable without fixture binaries.

- `blend.ts` — exhaustive over the `BlendMode` union, so a future ag-psd upgrade that adds a mode
  fails the test rather than silently falling back to normal.
- `geometry.ts` — off-canvas bounds preserved, hard limits respected, aspect-fit produces a uniform
  scale, minimum-size floor holds.
- `bake.ts` — mask luminance→alpha; `defaultColor` 0 vs 255; `disabled` masks ignored; mask bounds
  offset from layer bounds; clipping against the base's alpha; drop shadow growing the output rect.
- `vector.ts` — simple rect/ellipse/line become shape payloads; complex paths fall back to raster.
- `resolveOverlayTree.ts` — opacity multiplies through ancestors; hidden/locked inherit; draw order
  is depth-first with siblings by `z`; **cycles terminate** rather than hang.

**Integration.** Synthesized PSDs through the full `importPsd`: a masked gradient over a photo, a
clipped photo, a group with a blend mode, a text layer with a missing font — asserting the draft set
rather than pixels.

**API.** Explicit tests for both traps: a `group` overlay saving without `color`, and a `parent_id`
that cycles or points at a non-group being rejected.

**Manual acceptance.** Import `MULTIGUNA_KV 2_2.psd` and compare side by side against thebrief.ai:
black band gone, geometry unstretched, group tree matching.

## Sequencing

Phase 1 ships as its own PR and is independently valuable — it is the floor phase 2 stands on, and
none of it is discarded. Within phase 2, group drag is last so it can be cut without blocking.

## Open Questions

None blocking. Deliberately deferred, in rough priority order:

1. **Rich per-run text styling.** Only `styleRuns[0]` is used (`importPsd.ts:304`), so a bold or
   coloured word inside a paragraph collapses to a uniform style.
2. **Text effects as data** — Fabric and Konva both support text `stroke` and `shadow` natively.
3. **Worker-based parsing** for large PSDs (needs `OffscreenCanvas`).
4. **Real nested group nodes**, if group transforms or group blend modes are later wanted as an
   editor feature in their own right.
