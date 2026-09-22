# KV text overlay — per-run font styling

**Date:** 2026-09-09
**Author:** Daffa (with Claude)
**Status:** approved for planning
**Branch:** `feature/daffa/vc-kv-text-runs` (web + api)
**Services:** web, api

---

## Problem

A KV text overlay stores exactly one `fontFamily` / `fontWeight` / `fontStyle`
for the whole `content` string (`web/src/types/studio.ts`, the `type: "text"`
arm of `StudioOverlay["payload"]`). To bold one word mid-sentence a user has to
split the sentence into several overlapping overlays and hand-align them — which
then breaks on every resize, because each overlay's geometry is normalized
independently.

We want one text layer to carry several font/weight/style runs, and we want the
run model to be engine-neutral: Motion still draws on Konva, and the KV canvas
is mid-migration to Fabric. Whatever we build must not have to be rewritten when
Motion moves.

## Where text is actually drawn (verified on `develop`, 2026-09-09)

This matters more than usual, because a styling prop added to some renderers and
not others is invisible until a user downloads a file — the failure mode that
shipped `blendMode` broken.

**Fabric — 4 sites, 3 already share one builder:**

| Site | Role |
|---|---|
| `KvFabricCanvas.tsx` (2 Textbox branches) | live Craft canvas — the authoring surface |
| `fabricExport.ts::buildTextObject` | shared builder |
| `fabricExport.ts::flattenBoardOverlaysToBlob` | Craft download / flatten → `buildTextObject` |
| `KvResizeTileStage.tsx` | read-only Resize tile → `buildTextObject` |
| `renderResizeBoards.ts` | `KvResizeUnifiedCanvas` (read-only spike, flag `KV_RESIZE_UNIFIED_CANVAS`) → `buildTextObject` |

**Konva — 2 sites:**

| Site | Role |
|---|---|
| `renderBoardStage.ts::buildBoardStage` | Motion live stage, Motion export, Motion size-picker preview, **and the public share page** (`app/share/[token]/KvShareBoardCanvas.tsx`) |
| `KvKonvaCanvas.tsx` | legacy Craft fallback |

> **Corrected during implementation (2026-09-09).** This map originally listed
> `KvTileOverlayEditor.tsx` (the Resize result-row editor) under Konva. It is
> Fabric-based, and its text already routes through `fabricExport.buildTextObject`
> — so it gained run rendering from the Fabric change, not the Konva one. It still
> edits through a plain `<textarea>`, so `remapRuns` is still needed on that path.
> The claim that this repo has no `canvas` package was also wrong: `canvas@3.2.3`
> arrives via fabric's `optionalDependencies`, so text measurement is real under
> `bun test` and cross-engine parity is genuinely testable.

Both engines already funnel geometry through `overlayGeometry.ts`
(`overlayTextMetrics`) and text semantics through `overlays/textProps.ts`
(`resolveDisplayText`, `resolveFontStyle`). Those two modules are the seam this
design extends. Rules go there, never into a renderer.

## Decisions

Settled with Daffa on 2026-09-09. Do not re-litigate.

1. **Run model is a list of consecutive lengths**, not start/end offsets. One
   invariant (`sum(length) === content.length`), overlap and gaps are
   unrepresentable, and it is the same shape as PSD's `styleRuns`, so the
   deferred PSD work is a direct map.
2. **Per-run props are `fontFamily`, `fontWeight`, `fontStyle` only.** These
   change advance width and nothing else — no baseline, line-height, or fill
   consequences. Per-run colour, size and tracking are out of scope.
3. **Shared pure module + one adapter per engine.** Fabric keeps its native
   per-character `styles`; Konva gets a run renderer built on a shared layout
   module. Overlays without runs never enter the new path at all.
4. **Selection-scoped controls.** Text selected while inline-editing ⇒ the
   panel's Font/Bold/Italic controls apply to that range. Layer selected
   normally ⇒ they apply to the whole layer and clear that property's run
   overrides. (Figma/Canva semantics.)
5. **Content edits keep runs** via a common-prefix/common-suffix diff. This is
   not an edge case: Resize editing goes through a `<textarea>`
   (`OverlayTextEditor`), which hands back a whole new string with no notion of
   what changed, so it is a daily path.
6. **No new feature flag.** Back-compat is structural — absent `runs` means the
   legacy path, byte for byte. The font picker itself is already behind
   `KV_CUSTOM_FONTS`.

## Data model

Added to the `type: "text"` arm of `StudioOverlay["payload"]` **only**. It is
deliberately *not* added to `BrandOverlayPreset["overlays"][n]["payload"]`: a
preset is a style template re-stamped onto different content, so a stored run
length would be meaningless or wrong there.

```ts
/** One consecutive stretch of `content` with its own font identity. Absent
 *  properties inherit the layer-level value — a run is an override, not a
 *  complete style. `length` counts UTF-16 code units of the STORED content,
 *  the same units `content.length` and a textarea's selection use. */
export type TextStyleRun = {
  length: number;
  fontFamily?: string;
  fontWeight?: "normal" | "bold";
  fontStyle?: "normal" | "italic";
};
```

```ts
/** Per-range font overrides. Absent ⇒ the layer's own fontFamily/fontWeight/
 *  fontStyle govern the whole string, exactly as before this field existed.
 *  Runs are normalized at READ time (see textRuns.ts), never trusted raw. */
runs?: TextStyleRun[];
```

### The invariant is enforced at read, not at write

`normalizeRuns(content, runs)` drops non-positive lengths, truncates the tail
that overruns `content.length`, and appends one un-styled run for any remainder.
Every renderer calls it; nothing downstream may assume raw runs are well-formed.

This is a deliberate choice over server-side rejection. A 422 fails the **whole**
overlays PATCH, and that PATCH is a full-array autosave — one bad derived value
would poison every subsequent save for that file, which is exactly the failure
`psd/text.ts` already clamps against. The API validates the *shape* of each run
(types and enum membership); the *relationship* between runs and content is the
client's and the renderer's to normalize.

## The display transform is applied per run

`resolveDisplayText` does two things to the stored string before it is painted:
`textTransform` (case) and `paragraphSpacing` (which **inserts blank lines**).
Naively, that means run offsets computed on `content` do not address the painted
string.

The fix is to never compute offsets on the joined string. Build the display text
**per run** — apply `applyTextTransform` then `applyParagraphSpacing` to each
run's own slice and concatenate. Injection only ever happens at `\n` characters,
and a `\n` lives entirely inside one run, so per-run application is exactly
equivalent to whole-string application. Index drift becomes structurally
impossible rather than something a mapping function has to chase.

Case transforms are length-preserving for effectively all real copy, but not
universally (`ß`.toUpperCase() is `SS`). So each span records **both** lengths,
and `displayIndexToContent` snaps to a run boundary whenever the two differ
inside that run. That is the only place the asymmetry can be observed.

## Architecture

### New modules (web)

**`overlays/textRuns.ts`** — the model. Pure, no canvas, no DOM.

```ts
export type RunSpan = {
  /** Display text for this run — case-transformed, paragraph-spaced. */
  text: string;
  contentStart: number;
  contentLength: number;
  displayStart: number;
  displayLength: number;
  fontFamily: string;
  fontWeight: "normal" | "bold";
  fontStyle: "normal" | "italic";
};

export function normalizeRuns(content: string, runs?: TextStyleRun[]): TextStyleRun[];
/** null ⇒ no run actually overrides anything ⇒ take the legacy path. */
export function resolveRunSpans(payload: TextPayload): RunSpan[] | null;
export function displayIndexToContent(spans: RunSpan[], i: number): number;
export function applyRunStyle(payload: TextPayload, start: number, end: number, patch: Partial<TextStyleRun>): TextStyleRun[];
export function clearRunProp(runs: TextStyleRun[], prop: "fontFamily" | "fontWeight" | "fontStyle"): TextStyleRun[];
/** null for a property means MIXED across the range. */
export function runStyleAtRange(payload: TextPayload, start: number, end: number): { fontFamily: string | null; fontWeight: "normal" | "bold" | null; fontStyle: "normal" | "italic" | null };
export function remapRuns(oldContent: string, newContent: string, runs?: TextStyleRun[]): TextStyleRun[];
```

`resolveRunSpans` returning `null` is the back-compat guarantee, expressed in the
type system: a payload with no runs, or with runs that set nothing, cannot reach
the new code path.

**`overlays/textRunLayout.ts`** — engine-agnostic wrapping. Greedy word wrap on
spaces to `boxWidth`, mirroring Fabric's `splitByGrapheme: false`; a single word
wider than the box gets its own line and is allowed to overflow. Emits lines of
positioned spans plus a total height. Measurement is injected so it is testable
without a canvas.

**`overlays/konvaRunText.ts`** — `buildRunTextNode(...)` returns one
`Konva.Shape` whose `sceneFunc` walks the layout and draws each span with its own
`ctx.font`. One node, not N — so Motion's `applyTimeline` animates it like any
other layer, and z-order/blend/opacity behave unchanged.

The Konva node mirrors Konva.Text's own vertical convention (`textBaseline
= "middle"`, line `i` centred at `i * lineHeightPx + lineHeightPx / 2`) so that
run text and legacy text at the same geometry sit on the same baseline.

### Why Fabric keeps its native styles

Fabric already maintains per-character styles correctly through typing, paste,
backspace and wrapping — reimplementing that is the single largest risk in this
change, and it would put **legacy** text on the new path too. So Fabric renders
via `setSelectionStyles` per span, and the shared layout module serves Konva.

The cost is that two wrapping implementations must agree. That is bought back by
the parity invariant below, which is cheap to test and catches drift directly.

### Payload is always the source of truth

Fabric's `styles` map is a render **output**, never an input we read back. When
the user edits content, runs are recomputed from `remapRuns(old, new, runs)` —
the same function the Konva `<textarea>` path uses. One code path, and no need to
invert the display transform on every keystroke.

The only place display→content conversion is needed is at *selection* time, where
the boundary is user-chosen and snapping is acceptable.

## Editing semantics

`KvFabricCanvas` gains one outbound prop:

```ts
onTextSelectionChange?: (sel: { overlayId: string; start: number; end: number } | null) => void;
```

fired from Fabric's `selection:changed` / editing events with **display**
indices. The owning layout converts through `displayIndexToContent` and routes
the panel's patch:

- selection non-empty ⇒ `applyRunStyle(payload, s, e, partial)`
- otherwise ⇒ the existing whole-layer patch, plus `clearRunProp` for the
  property being set

`TextTypographyControls` gains one optional prop carrying the resolved style for
whatever the controls currently act on, where `null` means mixed:

```ts
effectiveStyle?: { fontFamily: string | null; fontWeight: "normal" | "bold" | null; fontStyle: "normal" | "italic" | null };
```

Absent ⇒ the component reads the payload exactly as it does today, so the Resize
call site keeps working untouched until it is wired.

## Back-compat and the parity invariant

**A payload whose runs all resolve to the layer's own style must render pixel-
identical to the same payload with no runs at all, on both engines.**

This is the acceptance test that makes the two wrapping implementations
trustworthy, and it is cheap: build both, compare. It is also the regression net
for the legacy path, since a uniform-run payload exercises the new code while
promising the old result.

Separately, `overlayStyleSignature` must include `runs`. A prop applied by
`KvFabricCanvas`'s style effect but missing from that signature is invisible on
canvas until some unrelated edit re-runs the reconcile — how `blendMode` shipped
broken. The existing `overlayStyleSignature.test.ts` is the contract test.

## Measurement

Auto-fit width measurement (`KvKonvaCanvas.tsx:1474`,
`KvTileOverlayEditor.tsx:2564`) calls `measureTextWidth(text, fontSizePx)` with a
single font — and does not even pass family or style today. With runs it must sum
each span measured in its own font. `measureTextWidth` already accepts family and
a style prefix; the call sites just never used them.

## Collaboration

`docUpdateOverlay` replaces the payload wholesale and `diffOverlayArrays` compares
it with `JSON.stringify`, so runs ride along with no serializer change. The
consequence, accepted: two people styling different words in the same text layer
is last-write-wins on the whole payload, like every other payload edit today.

## API

`overlays.*.payload.runs` and its sub-keys must be whitelisted in
`UpdateStudioFileOverlaysRequest` — `validated()` strips any payload key without
a rule. They go **directly on that request, not in `HasTextOverlayPayloadRules`**,
because the trait is shared with `StoreBrandOverlayPresetRequest` and presets must
not carry runs.

Shape only: `runs` is a bounded array; each entry needs a positive integer
`length` and optional font properties constrained to the same enums the layer
level uses. No cross-field check against `content` — see the read-time
normalization rationale above.

## Out of scope

- Per-run colour, gradient, font size, letter spacing.
- Importing PSD `styleRuns[1..n]` — `psd/text.ts:131` keeps taking the first run.
  Tracked separately under the PSD import fidelity work (2026-07-27).
- Any new feature flag.
- Merging `KvResizeUnifiedCanvas` into `KvFabricCanvas`.

## Risks

- **Wrapping parity between Fabric and our layout.** Mitigated by the uniform-run
  parity test, and bounded by the fact that only runs-bearing overlays diverge.
  Known caveat: Fabric will grapheme-break a word wider than the box as a last
  resort; our layout lets it overflow. Documented, tested, accepted.
- **Fonts not loaded when a run's family differs from the layer's.** Canvas 2D
  does not trigger font loading. `TextTypographyControls` already
  `document.fonts.load(...)`s before committing a family; the run path must do
  the same for every distinct family in the spans before a Konva stage is built,
  or the first paint falls back.
- **Long styled strings.** `content` is capped at 500 characters server-side;
  runs are capped independently so a crafted payload cannot make the renderer
  walk an unbounded list.

## Acceptance criteria

1. Selecting a range inside a text layer and pressing Bold / Italic / choosing a
   font styles only that range.
2. The stored payload carries `runs`; reloading the file reproduces the styling.
3. The same styling appears in the Craft canvas, the Craft download, the Resize
   tile, the public share page, and a Motion export.
4. A payload with uniform runs renders identically to the same payload with no
   runs, on both engines.
5. An overlay with no `runs` renders exactly as it does today, everywhere.
6. Editing the text through the Resize `<textarea>` preserves run styling for
   appends, backspaces and mid-string edits.
