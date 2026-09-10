# KV text overlay — per-run size and colour

**Date:** 2026-09-10
**Author:** Daffa (with Claude)
**Status:** approved for planning
**Services:** web, api
**Extends:** [2026-09-09 — per-run font styling](./2026-09-09-kv-text-style-runs-design.md)

---

## Problem

The 2026-09-09 design shipped per-run `fontFamily` / `fontWeight` / `fontStyle`.
Its Decision #2 closed the door on the rest:

> Per-run props are `fontFamily`, `fontWeight`, `fontStyle` only. These change
> advance width and nothing else — no baseline, line-height, or fill
> consequences. Per-run colour, size and tracking are out of scope.

That reasoning was correct for what it bought at the time, and it is exactly
what this document reopens. Users want one word bigger, or one word in the
brand accent colour, without splitting the sentence into hand-aligned overlays —
the same complaint that motivated runs in the first place.

Tracking (`letterSpacing`) stays out of scope. It is not requested, and unlike
size it has no natural per-run meaning at a run boundary.

## The two halves are not the same size of job

This is one spec because the data model, the API rules, the panel dispatcher
and the PSD map all move once. But the implementation cost is lopsided, and a
plan should sequence accordingly:

**Colour is nearly free.** It has zero layout consequence. Fabric supports
per-character `fill` natively. Konva needs `paintRunLayout` to set `fillStyle`
per span instead of once per node — today it takes a single `fill` argument for
the whole layer (`konvaRunText.ts:156-166`).

**Size is the real work.** `textRunLayout.ts` and `konvaRunText.ts` both thread
a single scalar `fontSizePx` through everything: `lineHeightPx = fontSizePx *
lineHeight` (`textRunLayout.ts:324`), one `MeasureFn` built once per node
(`konvaRunText.ts:40`), and a baseline resolved from one font
(`konvaRunText.ts:216-240`). Mixed sizes invalidate all three.

## Decisions

Settled with Daffa on 2026-09-10. Do not re-litigate.

1. **Both props are added together**, in one model change, one API change and
   one panel dispatcher change. Sequencing inside the plan is free to ship
   colour first.
2. **Run `fontSize` is absolute, in the same unit as `payload.fontSize`** — a
   normalized fraction of the host board height. Not a multiplier of the layer
   size. One unit across the whole system, renderers denormalize it exactly as
   they already do, and PSD's absolute `styleRuns` font sizes map directly.
3. **Run `color` is a solid `#RRGGBB` only.** Gradients stay layer-level. A run
   with a colour override paints solid; every other character keeps the layer's
   gradient. Per-run gradients are rejected: gradient coordinates are computed
   over the whole box (`resolveTextFill.ts::gradientLineCoords`), PSD has no
   equivalent, and cross-engine parity would get much harder for a feature
   nobody asked for.
4. **Line height on a mixed-size line is `max(run size on that line) *
   lineHeight`.** This is Fabric's native behaviour. Choosing a fixed line
   height would mean forcing Fabric off its default *and* keeping Konva in step
   with a third rule we invented and must maintain forever. The authoring
   surface is the reference; Konva matches it.
5. **The size slider clears; a corner drag scales.** These are different
   gestures and they stay different:
   - Slider, layer selected ⇒ set the layer size and clear every run's size
     override. Consistent with Decision #4 of the 2026-09-09 spec (Bold/Font
     clear the same way) and with Figma, where setting size on a selected text
     layer flattens mixed sizes.
   - Corner/vertical drag ⇒ multiply every run's size override by the same
     `scaleY` the layer size is multiplied by (`KvFabricCanvas.tsx:1444-1452`).
     A drag is a transform, not a style assignment; clearing here would destroy
     work with no warning, and ignoring runs would visibly break the layer's
     proportions on the first drag.
6. **No new feature flag.** Both props ride the existing
   `MAJOR_FEATURE_FLAGS.KV_TEXT_RUNS` (`KvGeneratorLayout.tsx:2052`), which
   already gates the run-writing paths while leaving `resolveRunSpans` and every
   renderer ungated. Back-compat stays structural: an absent override inherits
   the layer value, byte for byte as today.

## Data model

`TextStyleRun` (`web/src/types/studio.ts:655`) gains two optional overrides:

```ts
export type TextStyleRun = {
  length: number;
  fontFamily?: string;
  fontWeight?: "normal" | "bold";
  fontStyle?: "normal" | "italic";
  /** Normalized as a fraction of the host board height — the SAME unit as
   *  the layer's `payload.fontSize`, not a multiple of it. */
  fontSize?: number;
  /** Solid `#RRGGBB`. A run never carries a gradient; when the layer has one,
   *  an overridden run paints solid and the rest keeps the gradient. */
  color?: string;
};
```

`RUN_PROPS` (`textRuns.ts:19`) gains `"fontSize"` and `"color"`. That constant
drives `sameOverrides`, `coalesceRuns`, `clearRunProp` and the panel dispatcher,
so most of the model layer generalizes for free.

### One trap in `overridesOf`

`overridesOf` (`textRuns.ts:37-43`) copies a property only when it is truthy.
That is correct for strings but wrong for a number: it must guard on
`Number.isFinite(v) && v > 0` so a nonsense `0` is dropped rather than silently
becoming an override. `sameOverrides` already compares with `===`, which is
correct for numbers, and needs no change.

### API validation

`UpdateStudioFileOverlaysRequest` (`api/app/Http/Requests/Studio/`) gains two
rules next to the existing three, mirroring the layer-level units:

```php
'overlays.*.payload.runs.*.fontSize' => ['sometimes', 'nullable', 'numeric', 'between:0,5'],
'overlays.*.payload.runs.*.color'    => ['sometimes', 'nullable', 'regex:/^#[0-9A-Fa-f]{6}$/'],
```

`between:0,5` matches `overlays.*.payload.fontSize` in
`HasTextOverlayPayloadRules`, which is the whole point of Decision 2. The
existing principle is unchanged and worth restating: the API validates the
*shape* of a run, never the relationship between runs and content — a 422 on a
full-array autosave would poison every subsequent save for the file.

Both rules stay out of `HasTextOverlayPayloadRules` for the same reason `runs`
already is: that trait is shared with `StoreBrandOverlayPresetRequest`, and a
preset is a style template re-stamped onto different content.

## Rendering

### Fabric — two lines

`applyRunStylesToTextbox` (`fabricExport.ts:285`) passes a style object to
`setSelectionStyles`. It gains `fontSize` (denormalized to px against the host
height, like the layer value) and `fill`. Fabric maintains per-character styles
through typing, paste and backspace on its own, and `initDimensions()` at the
end already reflows — mixed sizes rewrap correctly with no further work.

Note the naming seam: the payload calls it `color`, Fabric calls it `fill`. The
adapter translates; the model keeps `color` to match `payload.color`.

### Konva — the actual work

Three changes, all inside the shared layout module and its painter.

**1. Measurement becomes per-run.** `MeasureFn` (`textRunLayout.ts:43`) takes
family/weight/style and closes over one size. It gains a `fontSizePx`
parameter, and `canvasMeasure` (`konvaRunText.ts:40`) stops closing over a
single size. `LayoutSpan` and the internal `StyledSpan` carry `fontSizePx`.

**2. Line height becomes per-line.** `RunTextLayout.lineHeightPx` (one scalar)
becomes a per-line height on `LayoutLine`, computed as
`max(span.fontSizePx on that line) * lineHeight`. Total height is the sum, not
`lines.length * lineHeightPx`. The painter's `y` becomes a running sum of
preceding line heights instead of `i * layout.lineHeightPx`
(`konvaRunText.ts:176`).

**3. Baseline becomes per-line.** `resolveBaseline` (`konvaRunText.ts:215-240`)
currently reads metrics from the first span's font and returns one
`translateY`. It must resolve per line, from the span with the greatest ascent
on that line.

That function carries a constraint the plan must not lose. Its docstring
explains that it mirrors `Konva.Text._sceneFunc` because **both nodes are live
at once**: a layer renders as a `Konva.Text` until a run overrides something and
as this Shape afterwards. A baseline that differs would make the whole block
jump the moment one word is bolded. Per-run sizes must not break that.

### The parity invariant

This is the load-bearing test, and it is what keeps change (3) honest:

> For any text payload whose runs all resolve to the same `fontSize`, the new
> layout must produce output identical to today's.

If that holds, adding a size override and then clearing it returns the layer to
exactly where it started, and the `Konva.Text` ↔ run-Shape swap stays seamless.
`canvas@3.2.3` arrives via fabric's `optionalDependencies`, so text measurement
is real under `bun test` and this is genuinely testable rather than aspirational.

### Render sites

Verified on 2026-09-10. Both engines already route runs; nothing new is added
to this map, which is the point — no site may be left behind.

| Engine | Site | Serves |
|---|---|---|
| Fabric | `KvFabricCanvas.tsx` | Craft canvas (authoring) |
| Fabric | `fabricExport.ts::buildTextObject` | Craft download/flatten, Resize tile, tile overlay editor |
| Konva | `renderBoardStage.ts::buildBoardStage` | Motion stage, **Motion export**, Motion size picker, **public share page** |
| Konva | `KvKonvaCanvas.tsx` | legacy Craft fallback (editable) |

Fabric serves where users type; Konva serves where the work comes out. A
property honoured by one and not the other is invisible until download or
share — the `blendMode` compositing bug (`960c2bc41`, 2026-07-27) is the
precedent: Fabric was unaffected, every Konva path rendered blend modes as
normal, "including in the downloaded PNG".

> Aside, found while verifying this map: the `renderHiddenStage` docstring
> claims its callers are "Resize export, Craft download". Stale — the only
> remaining caller is the Motion size picker. Do not trust it.

## Panel and dispatch

The dispatcher in `KvGeneratorLayout.tsx:7909` is already prop-generic:

```ts
const touched = RUN_PROPS.filter((k) => k in partial);
```

Adding the two props to `RUN_PROPS` routes them through the range path
automatically. Its own comment — "Nothing run-scoped in this patch (size,
align, colour, spacing)" — becomes stale and must be updated in the same commit.

`FillControls` already lives inside `TextTypographyControls` (line 375) and
shares its `onPatch`, so colour needs no second dispatcher.

### The gradient trap

`FillControls` patches colour and gradient together: picking a solid emits
`{ color: hex, gradient: undefined }`, because at layer level choosing solid
means dropping the gradient. Under a range selection that patch would set the
run's colour **and clear the layer's gradient** — a global side effect from a
local edit.

The dispatcher must therefore split a patch that touches both: apply
run-scoped keys to the range, and drop `gradient` rather than applying it
layer-wide, whenever the selection is a non-collapsed range. Decision 3 makes
this coherent: a run override is always solid, so a range edit has no business
speaking about the layer's gradient at all.

### Mixed-value display

`runStyleAtRange` already returns `undefined` for a property that differs across
the range, and `SegBtn` renders a "mixed" state for it (`TextTypographyControls.tsx:105-108`).
The size field and the colour chip need the same treatment — a mixed size must
not display as a concrete number, or committing the field would flatten the
range without the user asking.

## Out of scope

- **Per-run tracking** (`letterSpacing`). Not requested; no natural meaning at a
  run boundary.
- **Per-run gradients.** Decision 3.
- **PSD per-run import.** `convertTextLayer` (`lib/studio/kv/psd/text.ts:131`)
  still reads `styleRuns[0]` and merges it over the layer default, flattening
  the rest. Unchanged here. Decision 2 exists partly so that work stays a direct
  map when it happens.
- **`BrandOverlayPreset`.** Runs are still deliberately absent from presets.

## Open risks

Stated as risks, not as settled matters.

1. **Two gestures, two behaviours.** Decision 5 makes the size slider destroy
   run overrides while a corner drag preserves and scales them. The distinction
   is principled — assignment versus multiplication, and it is what Figma does —
   but a user who thinks of both as "make it bigger" can lose styling to the
   slider and only find out via undo. This needs watching with real users; if it
   bites, the fallback is a confirmation or an undo affordance, not a change to
   the model.
2. **Mixed sizes change wrap results.** A line's width now depends on per-run
   sizes, so enabling a size override can rewrap a paragraph and change the
   layer's height. Expected, but it means a size edit is not a purely local
   visual change the way a colour edit is.
3. **Baseline metrics under node-canvas.** `resolveBaseline` already falls back
   from `fontBoundingBox*` to `actualBoundingBox*` where the platform has no
   font metrics. Per-line max-ascent resolution multiplies how often that
   fallback is hit; the parity invariant must be asserted under `bun test`,
   which is exactly that platform.

## Testing

- **Parity:** uniform-size payloads produce byte-identical layout before and
  after. The invariant above.
- **Round-trip:** apply a size override, clear it, assert the payload and the
  layout return to their original state.
- **Cross-engine:** same payload through Fabric and Konva measurement agrees on
  line count and wrap points for a mixed-size, mixed-family string.
- **Gradient trap:** a range colour edit on a layer with a gradient leaves
  `payload.gradient` untouched.
- **Drag vs slider:** a `scaleY` drag multiplies run sizes; a layer-scoped
  slider commit clears them.
- **API:** `fontSize` outside `0..5` and a malformed `color` are rejected for a
  run; run lengths that do not sum to the content length are still accepted.
