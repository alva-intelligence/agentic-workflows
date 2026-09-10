# KV text run size + colour — Web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let one text layer carry per-run font size and colour, rendered identically by Fabric (authoring) and Konva (Motion export, public share page).

**Architecture:** The run model is already prop-generic — `RUN_PROPS` drives coalescing, clearing and the panel dispatcher — so adding two entries carries most of the model layer. Colour has no layout consequence and lands first (Tasks 1–4). Size does: the shared layout module threads one scalar `fontSizePx` through measurement, line height and baseline, and all three become per-run or per-line (Tasks 5–7). Fabric gets both props via its native per-character styles; Konva gets them through the shared layout module.

**Tech Stack:** Next.js 16, React 19, TypeScript, Fabric v6, Konva 10, Bun test (with `canvas@3.2.3` via fabric's optionalDependencies, so text measurement is real in tests).

**Spec:** `docs/superpowers/specs/2026-09-10-kv-text-run-size-color-design.md`

## Global Constraints

- Repo: `web/` (`alva-intelligence/frnd-web`). Branch from `develop`: `feature/daffa/vc-kv-text-run-size-color`.
- Run `fontSize` is stored **absolute**, as a normalized fraction of board height — the same unit as `payload.fontSize`. It is NOT a multiplier. Renderers consume a derived `sizeScale` (see Task 1) so they never need the board height to interpret a run.
- Run `color` is solid `#RRGGBB` only. A run never carries a gradient. When the layer has a gradient, an overridden run paints solid and every other character keeps the gradient.
- Line height on a mixed-size line is `max(run size on that line) * lineHeight` — Fabric's native behaviour. Do not invent a third rule.
- **Parity invariant (load-bearing).** For any payload whose runs all resolve to the same size, the new layout must produce output identical to today's. This keeps the `Konva.Text` ↔ run-Shape swap seamless — see the `resolveBaseline` docstring at `konvaRunText.ts:215`, which exists because a layer renders as a `Konva.Text` until a run overrides something and as a custom Shape afterwards. Every layout task below asserts it.
- Both props ride the existing `MAJOR_FEATURE_FLAGS.KV_TEXT_RUNS` flag (`KvGeneratorLayout.tsx:2052`). No new flag.
- `overlayStyleSignature.ts:32` already serializes `JSON.stringify(o.payload.runs ?? null)`, so run edits already invalidate the Fabric style-sync effect. No change needed there — this is the seam the `blendMode` repaint bug (`b374f97ec`) was fixed at, so do not remove it.
- Test command: `bun test <path>` run from `web/`.

---

### Task 1: Model — two new run props

**Files:**
- Modify: `src/types/studio.ts:655-660`
- Modify: `src/components/studio/kv-generator/overlays/textRuns.ts:19` (RUN_PROPS), `:23-34` (RunSpan), `:37-43` (overridesOf), `:93-120` (buildSpans)
- Test: `src/components/studio/kv-generator/overlays/textRuns.test.ts`

**Interfaces:**
- Produces: `TextStyleRun` gains `fontSize?: number` and `color?: string`. `RunSpan` gains `sizeScale: number` (1 when the run does not override) and `color?: string` (absent ⇒ inherit the layer fill, gradient included). `RUN_PROPS` becomes `["fontFamily", "fontWeight", "fontStyle", "fontSize", "color"]`. Every later task consumes these names.

**Why `sizeScale` and not the stored value:** the stored `fontSize` is a fraction of board height, but renderers already hold the layer's size in pixels (`overlayTextMetrics().fontSizePx`), including the legacy `height * 0.8` fallback for layers that have no `payload.fontSize` at all. Handing renderers a ratio means they multiply what they already have and never need the board height. Storage stays absolute, exactly as the spec decided; the ratio is derived at read time like `resolveDisplayText` is.

- [ ] **Step 1: Write the failing tests**

Append to `src/components/studio/kv-generator/overlays/textRuns.test.ts`:

```ts
import { resolveRunSpans, normalizeRuns, RUN_PROPS } from "./textRuns";

const payload = (over: Record<string, unknown> = {}) => ({
  type: "text" as const,
  content: "Hello world",
  color: "#111111",
  fontSize: 0.1,
  ...over,
});

describe("per-run size and colour", () => {
  it("lists fontSize and color as run props", () => {
    expect([...RUN_PROPS]).toEqual([
      "fontFamily",
      "fontWeight",
      "fontStyle",
      "fontSize",
      "color",
    ]);
  });

  it("resolves a run size override to a scale against the layer size", () => {
    const spans = resolveRunSpans(
      payload({ runs: [{ length: 5, fontSize: 0.2 }, { length: 6 }] })
    );
    expect(spans).not.toBeNull();
    expect(spans![0].sizeScale).toBe(2);
    expect(spans![1].sizeScale).toBe(1);
  });

  it("falls back to scale 1 when the layer has no explicit fontSize", () => {
    const spans = resolveRunSpans(
      payload({ fontSize: undefined, runs: [{ length: 5, fontSize: 0.2 }] })
    );
    // Without a layer size there is no ratio to compute; ignoring the override
    // is safe, whereas guessing one would resize legacy text on first read.
    expect(spans![0].sizeScale).toBe(1);
  });

  it("carries a colour override and leaves un-overridden runs inheriting", () => {
    const spans = resolveRunSpans(
      payload({ runs: [{ length: 5, color: "#FF0066" }, { length: 6 }] })
    );
    expect(spans![0].color).toBe("#FF0066");
    expect(spans![1].color).toBeUndefined();
  });

  it("treats a zero or negative run fontSize as no override", () => {
    expect(normalizeRuns("Hello", [{ length: 5, fontSize: 0 }])[0]).toEqual({
      length: 5,
    });
    expect(normalizeRuns("Hello", [{ length: 5, fontSize: -3 }])[0]).toEqual({
      length: 5,
    });
  });

  it("does not coalesce runs that differ only in colour", () => {
    const spans = resolveRunSpans(
      payload({
        content: "abcdef",
        runs: [
          { length: 3, color: "#FF0000" },
          { length: 3, color: "#00FF00" },
        ],
      })
    );
    expect(spans!.length).toBe(2);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bun test src/components/studio/kv-generator/overlays/textRuns.test.ts
```

Expected: FAIL — `RUN_PROPS` has three entries, and `sizeScale` / `color` are not properties of `RunSpan`.

- [ ] **Step 3: Widen the payload type**

In `src/types/studio.ts`, replace the `TextStyleRun` definition at line 655:

```ts
export type TextStyleRun = {
  length: number;
  fontFamily?: string;
  fontWeight?: "normal" | "bold";
  fontStyle?: "normal" | "italic";
  /** Normalized as a fraction of the host board height — the SAME unit as the
   *  layer's `payload.fontSize`, not a multiple of it. Renderers consume the
   *  derived `RunSpan.sizeScale` instead, so they never need the board height
   *  to interpret this. */
  fontSize?: number;
  /** Solid `#RRGGBB`. A run never carries a gradient: gradient coordinates are
   *  computed across the whole text box, which has no meaning for a sub-range.
   *  When the layer has a gradient, an overridden run paints solid and every
   *  other character keeps the gradient. */
  color?: string;
};
```

- [ ] **Step 4: Extend the model module**

In `src/components/studio/kv-generator/overlays/textRuns.ts`:

Replace `RUN_PROPS` (line 19):

```ts
/** The properties a run may override. Anything else is layer-level. */
export const RUN_PROPS = [
  "fontFamily",
  "fontWeight",
  "fontStyle",
  "fontSize",
  "color",
] as const;
```

Add to `RunSpan` (after `fontStyle`, line 33):

```ts
  /** Multiplier on the LAYER's resolved font size, so a renderer that already
   *  holds `fontSizePx` needs nothing else. 1 when the run does not override. */
  sizeScale: number;
  /** Solid colour for this run. ABSENT means inherit the layer's fill — which
   *  may be a gradient, so this must stay optional rather than defaulting to
   *  `payload.color`. */
  color?: string;
```

Replace `overridesOf` (lines 37-43) — note the numeric guard, which `if (r.fontSize)` would get wrong for `0`:

```ts
function overridesOf(r: TextStyleRun): Omit<TextStyleRun, "length"> {
  const out: Omit<TextStyleRun, "length"> = {};
  if (r.fontFamily) out.fontFamily = r.fontFamily;
  if (r.fontWeight) out.fontWeight = r.fontWeight;
  if (r.fontStyle) out.fontStyle = r.fontStyle;
  // A number needs a real guard: `if (r.fontSize)` would also drop a legitimate
  // small value's sibling cases inconsistently, and a stored 0 or NaN must not
  // become an override that renderers then divide by.
  if (Number.isFinite(r.fontSize) && (r.fontSize as number) > 0)
    out.fontSize = r.fontSize;
  if (r.color) out.color = r.color;
  return out;
}
```

In `buildSpans` (around lines 96-120), add the base size and emit the two new fields:

```ts
  const baseSize = payload.fontSize;
  const canScale = Number.isFinite(baseSize) && (baseSize as number) > 0;
```

and inside the `for (const r of norm)` loop, add to the pushed span object:

```ts
      sizeScale:
        canScale && r.fontSize ? r.fontSize / (baseSize as number) : 1,
      color: r.color,
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bun test src/components/studio/kv-generator/overlays/textRuns.test.ts src/components/studio/kv-generator/overlays/textRuns.mutations.test.ts
```

Expected: PASS. The mutations suite must pass untouched — `applyRunStyle`, `clearRunProp` and `runStyleAtRange` are already written against `RUN_PROPS` and generalize for free.

- [ ] **Step 6: Commit**

```bash
git add src/types/studio.ts src/components/studio/kv-generator/overlays/textRuns.ts src/components/studio/kv-generator/overlays/textRuns.test.ts
git commit -m "feat(web): model per-run size and colour for text overlays

fontSize is stored absolute in the layer's own unit and resolved to a
sizeScale at read time, so a renderer multiplies the fontSizePx it
already holds and never needs the board height. color stays optional on
the span rather than defaulting to payload.color, because absent has to
mean 'inherit the layer fill' — which may be a gradient."
```

---

### Task 2: Konva paints per-run colour

**Files:**
- Modify: `src/components/studio/kv-generator/overlays/textRunLayout.ts:50-58` (LayoutSpan), `:115-120` (StyledSpan), `:85-95` (Atom), `:167-197` (splitAtomToFit), `:205-231` (packLine)
- Modify: `src/components/studio/kv-generator/overlays/konvaRunText.ts:156-190` (paintRunLayout)
- Test: `src/components/studio/kv-generator/overlays/konvaRunText.test.ts`

**Interfaces:**
- Consumes: `RunSpan.color` from Task 1.
- Produces: `LayoutSpan.color?: string`, honoured by `paintRunLayout`.

- [ ] **Step 1: Write the failing test**

Append to `src/components/studio/kv-generator/overlays/konvaRunText.test.ts`:

```ts
it("paints a run's colour override and restores the layer fill after it", () => {
  const calls: Array<{ text: string; fill: string }> = [];
  let fillStyle = "";
  const ctx = {
    save() {},
    restore() {},
    set fillStyle(v: string) {
      fillStyle = v;
    },
    get fillStyle() {
      return fillStyle;
    },
    font: "",
    textBaseline: "" as CanvasTextBaseline,
    textAlign: "" as CanvasTextAlign,
    fillText(text: string) {
      calls.push({ text, fill: fillStyle });
    },
  } as unknown as Konva.Context;

  const layout = layoutRunText({
    spans: [
      { text: "red", fontFamily: "Geist", fontWeight: "normal", fontStyle: "normal", sizeScale: 1, color: "#FF0000" },
      { text: "plain", fontFamily: "Geist", fontWeight: "normal", fontStyle: "normal", sizeScale: 1 },
    ],
    boxWidth: 1000,
    fontSizePx: 20,
    lineHeight: 1,
    letterSpacingPx: 0,
    align: "left",
    measure: () => 10,
  });

  paintRunLayout(ctx, layout, 20, { type: "solid", color: "#111111" });

  expect(calls).toEqual([
    { text: "red", fill: "#FF0000" },
    { text: "plain", fill: "#111111" },
  ]);
});

it("keeps two runs that differ only in colour as separate spans", () => {
  const layout = layoutRunText({
    spans: [
      { text: "aa", fontFamily: "Geist", fontWeight: "normal", fontStyle: "normal", sizeScale: 1, color: "#FF0000" },
      { text: "bb", fontFamily: "Geist", fontWeight: "normal", fontStyle: "normal", sizeScale: 1, color: "#00FF00" },
    ],
    boxWidth: 1000,
    fontSizePx: 20,
    lineHeight: 1,
    letterSpacingPx: 0,
    align: "left",
    measure: () => 10,
  });
  expect(layout.lines[0].spans.map((s) => s.color)).toEqual(["#FF0000", "#00FF00"]);
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bun test src/components/studio/kv-generator/overlays/konvaRunText.test.ts
```

Expected: FAIL — `color` is not a property of the layout's span type, and `paintRunLayout` sets `fillStyle` once before the loop.

- [ ] **Step 3: Thread colour through the layout types**

In `textRunLayout.ts`, add `color?: string;` to **all three** of `LayoutSpan` (after `fontStyle`), `StyledSpan`, and `Atom` inherits it via `Omit<StyledSpan, "text">`.

In `splitAtomToFit`, the `style` object it rebuilds must carry it, or a mid-word break loses the colour:

```ts
  const style = {
    fontFamily: atom.fontFamily,
    fontWeight: atom.fontWeight,
    fontStyle: atom.fontStyle,
    color: atom.color,
  };
```

In `packLine`, the merge test must compare it, or two adjacent runs differing only in colour collapse into one `fillText` and the boundary disappears:

```ts
    if (
      merge &&
      prev &&
      prev.fontFamily === a.fontFamily &&
      prev.fontWeight === a.fontWeight &&
      prev.fontStyle === a.fontStyle &&
      prev.color === a.color
    ) {
```

and the pushed span gains `color: a.color,`.

- [ ] **Step 4: Paint per span**

In `konvaRunText.ts::paintRunLayout`, replace the single `fillStyle` assignment and the span loop body:

```ts
  const layerFill = resolveFillStyle(ctx, fill);
  ctx.fillStyle = layerFill;
  ...
    for (const s of line.spans) {
      // A run's colour override is always solid; everything else keeps the
      // layer fill, which may be a gradient spanning the whole box.
      ctx.fillStyle = s.color ?? layerFill;
      ctx.font = runFontShorthand(s.fontFamily, s.fontWeight, s.fontStyle, fontSizePx);
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bun test src/components/studio/kv-generator/overlays/konvaRunText.test.ts src/components/studio/kv-generator/overlays/textRunLayout.test.ts
```

Expected: PASS, including every pre-existing test in both files.

- [ ] **Step 6: Commit**

```bash
git add src/components/studio/kv-generator/overlays/textRunLayout.ts src/components/studio/kv-generator/overlays/konvaRunText.ts src/components/studio/kv-generator/overlays/konvaRunText.test.ts
git commit -m "feat(web): paint per-run colour in the Konva run renderer

packLine merged neighbouring atoms on font identity alone, so two runs
differing only in colour would have collapsed into one fillText and lost
the boundary; the merge test and splitAtomToFit's rebuilt style now carry
colour too. An un-overridden span still takes the layer fill, gradient
included."
```

---

### Task 3: Fabric paints per-run colour

**Files:**
- Modify: `src/components/studio/kv-generator/fabricExport.ts:285-306` (applyRunStylesToTextbox)
- Test: `src/components/studio/kv-generator/fabricExport.runs.test.ts`

**Interfaces:**
- Consumes: `RunSpan.color` from Task 1.
- Produces: nothing new — the same function, now writing Fabric's `fill` per character.

- [ ] **Step 1: Write the failing test**

Append to `src/components/studio/kv-generator/fabricExport.runs.test.ts`:

```ts
it("writes a run's colour onto the Textbox as a per-character fill", () => {
  const box = new fabric.Textbox("Hello world", { fontSize: 20 });
  applyRunStylesToTextbox(
    box,
    [
      { text: "Hello", contentStart: 0, contentLength: 5, displayStart: 0, displayLength: 5, fontFamily: "Geist", fontWeight: "normal", fontStyle: "normal", sizeScale: 1, color: "#FF0066" },
      { text: " world", contentStart: 5, contentLength: 6, displayStart: 5, displayLength: 6, fontFamily: "Geist", fontWeight: "normal", fontStyle: "normal", sizeScale: 1 },
    ],
    "display"
  );
  expect(box.getSelectionStyles(0, 1)[0].fill).toBe("#FF0066");
  // An un-overridden run must write NO fill, so the object-level fill (which
  // may be a gradient) still governs those characters.
  expect(box.getSelectionStyles(6, 7)[0].fill).toBeUndefined();
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bun test src/components/studio/kv-generator/fabricExport.runs.test.ts
```

Expected: FAIL — `fill` is `undefined` on the first character too, because the style object never mentions it.

- [ ] **Step 3: Write the fill only when the run overrides it**

In `fabricExport.ts::applyRunStylesToTextbox`, replace the `setSelectionStyles` call:

```ts
    // Only properties a run actually overrides are written, so an unstyled span
    // inherits the object-level font AND the object-level fill — which may be a
    // gradient. Writing `fill: undefined` would not be equivalent: Fabric stores
    // the key and the character stops inheriting.
    const style: Record<string, unknown> = {
      fontFamily: s.fontFamily,
      fontWeight: s.fontWeight,
      fontStyle: s.fontStyle,
    };
    if (s.color) style.fill = s.color;
    box.setSelectionStyles(style, start, start + length);
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bun test src/components/studio/kv-generator/fabricExport.runs.test.ts
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/fabricExport.ts src/components/studio/kv-generator/fabricExport.runs.test.ts
git commit -m "feat(web): apply per-run colour to Fabric textboxes

Written only when the run overrides it — setting fill: undefined is not
the same as omitting the key, and would stop the character inheriting the
object fill."
```

---

### Task 4: The panel routes colour to the selected range

**Files:**
- Modify: `src/components/studio/kv-generator/KvGeneratorLayout.tsx:7894-7938` (the `onPatch` dispatcher)
- Test: `src/components/studio/kv-generator/overlays/commitSemantics.test.tsx`

**Interfaces:**
- Consumes: `RUN_PROPS` (Task 1), `applyRunStyle`/`clearRunProp` (unchanged).
- Produces: no new exports. Behavioural contract: a range-scoped patch never writes `gradient`.

**The trap this task exists for:** `FillControls` lives inside `TextTypographyControls` (line 375) and shares its `onPatch`, so colour reaches the dispatcher for free. But picking a solid emits `{ color: hex, gradient: undefined }` — at layer level "solid" legitimately means "drop the gradient". Under a range selection that same patch would set the run's colour **and clear the whole layer's gradient**: a global side effect from a local edit.

- [ ] **Step 1: Write the failing test**

Append to `src/components/studio/kv-generator/overlays/commitSemantics.test.tsx`:

```tsx
it("a range-scoped colour edit leaves the layer gradient untouched", () => {
  const payload = {
    type: "text" as const,
    content: "Hello world",
    color: "#111111",
    fontSize: 0.1,
    gradient: { type: "linear" as const, from: "#000000", to: "#FFFFFF", angle: 90 },
  };
  const patch = dispatchTextPatch({
    payload,
    partial: { color: "#FF0066", gradient: undefined },
    range: { start: 0, end: 5 },
  });
  expect(patch).not.toHaveProperty("gradient");
  expect(patch.runs?.[0]).toMatchObject({ length: 5, color: "#FF0066" });
});

it("a layer-scoped colour edit still drops the gradient and clears run colours", () => {
  const payload = {
    type: "text" as const,
    content: "Hello world",
    color: "#111111",
    fontSize: 0.1,
    gradient: { type: "linear" as const, from: "#000000", to: "#FFFFFF", angle: 90 },
    runs: [{ length: 5, color: "#FF0066" }, { length: 6 }],
  };
  const patch = dispatchTextPatch({
    payload,
    partial: { color: "#00FF00", gradient: undefined },
    range: null,
  });
  expect(patch.gradient).toBeUndefined();
  expect("gradient" in patch).toBe(true);
  expect(patch.runs?.some((r) => r.color)).toBe(false);
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bun test src/components/studio/kv-generator/overlays/commitSemantics.test.tsx
```

Expected: FAIL with "dispatchTextPatch is not defined" — the dispatch logic currently lives inline in a JSX closure and is not testable.

- [ ] **Step 3: Extract the dispatcher into a pure function**

Create `src/components/studio/kv-generator/overlays/dispatchTextPatch.ts`:

```ts
import type { StudioOverlay, TextStyleRun } from "@/types/studio";
import { RUN_PROPS, applyRunStyle, clearRunProp } from "./textRuns";

type TextPayload = Extract<StudioOverlay["payload"], { type: "text" }>;

/**
 * Decide what a panel patch means given the current text selection.
 *
 * Pure on purpose: this rule set is the difference between a local edit and a
 * layer-wide one, and it was previously an inline closure inside a JSX map
 * where it could not be tested.
 */
export function dispatchTextPatch(args: {
  payload: TextPayload;
  partial: Partial<TextPayload>;
  /** Non-collapsed CONTENT range while inline-editing, else null. */
  range: { start: number; end: number } | null;
}): Partial<TextPayload> & { runs?: TextStyleRun[] } {
  const { payload, partial, range } = args;
  const touched = RUN_PROPS.filter((k) => k in partial);

  // Nothing run-scoped in this patch (align, spacing, transform) — always a
  // whole-layer change.
  if (touched.length === 0) return partial;

  if (range && range.start !== range.end) {
    // Range-scoped: apply ONLY the run-scoped keys to the range. Every other
    // key in the patch is layer-wide by definition and must be dropped —
    // FillControls emits `gradient: undefined` alongside a solid colour pick,
    // and honouring that here would clear the whole layer's gradient from a
    // local edit.
    const runScoped = Object.fromEntries(
      touched.map((k) => [k, partial[k]])
    ) as Partial<TextPayload>;
    return {
      runs: applyRunStyle(payload, range.start, range.end, runScoped),
    };
  }

  // No selection: the control owns the whole layer, so the layer value changes
  // AND that property's run overrides are cleared — otherwise pressing Bold
  // would leave some words stubbornly un-bold with no way to explain why.
  let runs = payload.runs ?? [];
  for (const k of touched) runs = clearRunProp(runs, k);
  return { ...partial, runs };
}
```

- [ ] **Step 4: Call it from the layout**

In `KvGeneratorLayout.tsx`, replace the body of the `onPatch` closure (lines 7894-7938) with:

```tsx
                      onPatch={(partial) => {
                        // Flag off: behave exactly as the pre-runs control did
                        // — a plain whole-layer patch that never reads or
                        // writes `runs` at all.
                        if (!kvTextRunsEnabled) {
                          patchOverlayPayload(partial);
                          return;
                        }
                        patchOverlayPayload(
                          dispatchTextPatch({
                            payload: selPayload,
                            partial,
                            // `rangeSel.start`/`.end` are already CONTENT
                            // indices — the Fabric Textbox holds the raw
                            // `content` string while editing.
                            range:
                              rangeSel && rangeSel.start !== rangeSel.end
                                ? rangeSel
                                : null,
                          })
                        );
                      }}
```

Add the import at the top of the file and drop `RUN_PROPS`, `applyRunStyle` and `clearRunProp` from its import list if nothing else in the file uses them.

- [ ] **Step 5: Give the fill event a scope**

A colour edit is now either layer-wide or range-scoped, and `kv_generator.text_fill_changed` cannot currently tell them apart — `KvTextFillChangedProps` carries only `fill_type`. House rule: analytics ships with the interaction, not after it (`.claude/skills/frndos-analytics-events`). This is a property added to an existing event, not a new or renamed one, so it needs no taxonomy row.

In `src/lib/analytics/kv-generator-events.ts`:

```ts
export interface KvTextFillChangedProps {
  fill_type: KvTextFillType;
  /** `"range"` when the edit was committed against a non-collapsed text
   *  selection, so a per-run colour is distinguishable from a layer-wide one. */
  scope: KvTextStyleScope;
}
```

Pass `scope={styleScope}` from `TextTypographyControls` into `FillControls`, and include it in the `trackKvTextFillChanged` call there. `styleScope` is already computed and already passed to this component — do not recompute it.

Do NOT use a raw `posthog.capture`; the typed helper is the only sanctioned path and the review bot flags inline captures.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
bun test src/components/studio/kv-generator/overlays/commitSemantics.test.tsx src/components/studio/kv-generator/overlays/TextTypographyControls.analytics.test.tsx
```

Expected: PASS. The analytics suite matters here: `styleScope` is computed from the same range condition, so a mismatch between it and the dispatcher would report the wrong scope. Add a case asserting a range-scoped colour edit reports `scope: "range"`.

- [ ] **Step 7: Commit**

```bash
git add src/components/studio/kv-generator/overlays/dispatchTextPatch.ts src/components/studio/kv-generator/overlays/commitSemantics.test.tsx src/components/studio/kv-generator/KvGeneratorLayout.tsx src/components/studio/kv-generator/overlays/FillControls.tsx src/components/studio/kv-generator/overlays/TextTypographyControls.tsx src/lib/analytics/kv-generator-events.ts
git commit -m "feat(web): route per-run colour edits to the selected range

Extracts the panel's patch dispatcher out of a JSX closure so it can be
tested, and fixes the case that motivated it: FillControls emits
'gradient: undefined' alongside a solid pick, which under a range
selection would have cleared the whole layer's gradient from a local
edit. A range patch now carries run-scoped keys only."
```

---

### Task 5: Measurement becomes per-run

**Files:**
- Modify: `src/components/studio/kv-generator/overlays/textRunLayout.ts:43-48` (MeasureFn), `:106-135` (measureAtom/makeAtom), `:167-197` (splitAtomToFit), `:264-320` (layoutRunText), `:365-387` (measureRunSpansWidth)
- Modify: `src/components/studio/kv-generator/overlays/konvaRunText.ts:38-47` (canvasMeasure)
- Modify call sites: `KvTileOverlayEditor.tsx:2646`, `KonvaRunTextNode.tsx:51`, `KvKonvaCanvas.tsx:1515`, `renderBoardStage.ts`, `fabricExport.runs.test.ts:219`
- Test: `src/components/studio/kv-generator/overlays/textRunLayout.test.ts`

**Interfaces:**
- Produces: `MeasureFn` becomes `(text, fontFamily, fontWeight, fontStyle, fontSizePx) => number`. `canvasMeasure()` takes **no argument** — the size now travels per call. Task 6 and Task 7 depend on both.

- [ ] **Step 1: Write the failing tests**

Append to `src/components/studio/kv-generator/overlays/textRunLayout.test.ts`:

```ts
/** 0.5 px per character per px of font size — so a 2x run measures 2x wide. */
const sizedMeasure: MeasureFn = (t, _f, _w, _s, px) => t.length * px * 0.5;

const sizedSpan = (text: string, sizeScale = 1) => ({
  text,
  fontFamily: "Geist",
  fontWeight: "normal" as const,
  fontStyle: "normal" as const,
  sizeScale,
});

describe("per-run size", () => {
  it("measures each run at its own size", () => {
    const layout = layoutRunText({
      ...base,
      boxWidth: 10000,
      fontSizePx: 20,
      spans: [sizedSpan("aa", 2), sizedSpan("bb", 1)],
      measure: sizedMeasure,
    });
    const [big, small] = layout.lines[0].spans;
    // 2 chars * 40px * 0.5 = 40 ; 2 chars * 20px * 0.5 = 20
    expect(big.width).toBe(40);
    expect(small.width).toBe(20);
    expect(small.x).toBe(40);
  });

  it("PARITY: a uniform-size payload lays out exactly as it does today", () => {
    const spans = [sizedSpan("hello world foo bar baz"), sizedSpan(" qux")];
    const withScale = layoutRunText({
      ...base,
      boxWidth: 120,
      fontSizePx: 20,
      spans,
      measure: sizedMeasure,
    });
    const uniform = layoutRunText({
      ...base,
      boxWidth: 120,
      fontSizePx: 20,
      spans: spans.map((s) => ({ ...s, sizeScale: 1 })),
      measure: sizedMeasure,
    });
    expect(withScale).toEqual(uniform);
  });

  it("wraps earlier when a run is enlarged", () => {
    const small = layoutRunText({
      ...base, boxWidth: 100, fontSizePx: 20,
      spans: [sizedSpan("aaa bbb ccc")], measure: sizedMeasure,
    });
    const large = layoutRunText({
      ...base, boxWidth: 100, fontSizePx: 20,
      spans: [sizedSpan("aaa ", 2), sizedSpan("bbb ccc")], measure: sizedMeasure,
    });
    expect(large.lines.length).toBeGreaterThan(small.lines.length);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bun test src/components/studio/kv-generator/overlays/textRunLayout.test.ts
```

Expected: FAIL — `MeasureFn` takes four arguments, so `px` is `undefined` and every width is `NaN`.

- [ ] **Step 3: Widen MeasureFn and thread the size**

In `textRunLayout.ts`:

```ts
export type MeasureFn = (
  text: string,
  fontFamily: string,
  fontWeight: "normal" | "bold",
  fontStyle: "normal" | "italic",
  /** The size this particular run draws at — layer size * the run's scale. */
  fontSizePx: number
) => number;
```

Add `sizeScale?: number;` to `StyledSpan` — **optional**, meaning 1. A layout caller that does not mix sizes must not be forced to write `sizeScale: 1` on every span, and Task 2's tests already construct spans without it. `LayoutSpan.sizeScale` is **required** (`packLine` sets `a.sizeScale ?? 1`), because every consumer downstream of layout reads it unconditionally. `RunSpan.sizeScale` stays required — `resolveRunSpans` always resolves it.

Give `measureAtom`, `makeAtom` and `splitAtomToFit` an extra `fontSizePx: number` parameter — the *resolved* per-run px — and pass it to `measure(...)`. `splitAtomToFit`'s rebuilt `style` object must carry `sizeScale` alongside `color`.

`Atom` must **store** that resolved size, because Task 6 reads it back to size a line:

```ts
type Atom = Omit<StyledSpan, "text"> & {
  text: string;
  width: number;
  trimmedWidth: number;
  isBreak: boolean;
  /** The size this atom was measured at — layer size * the run's scale. Kept
   *  on the atom because line height is `max(resolvedPx on the line)`, which is
   *  computed after wrapping, when the originating span is no longer in hand. */
  resolvedPx: number;
};
```

and `makeAtom` sets `resolvedPx: fontSizePx,` in the object it returns.

In `layoutRunText`, resolve each span's size before building atoms:

```ts
  const atoms = toAtoms(
    args.spans.map((s) => ({ ...s, resolvedPx: fontSizePx * s.sizeScale })),
    measure,
    letterSpacingPx
  );
```

`packLine`'s merge test gains `prev.sizeScale === a.sizeScale`, and the pushed span gains `sizeScale: a.sizeScale`.

`measureRunSpansWidth` takes the layer `fontSizePx` and multiplies per span: `measure(part, s.fontFamily, s.fontWeight, s.fontStyle, fontSizePx * s.sizeScale)`.

- [ ] **Step 4: Make `canvasMeasure` size-agnostic**

In `konvaRunText.ts`:

```ts
/** Canvas 2D measurement. The size travels per call, because a layer may mix
 *  run sizes — a curried size would silently measure every run at the layer's.
 *  Browser only; returns 0 without a document, same contract as measureText.ts. */
export function canvasMeasure(): MeasureFn {
  if (typeof document === "undefined") return () => 0;
  const ctx = document.createElement("canvas").getContext("2d");
  if (!ctx) return () => 0;
  return (text, family, weight, style, fontSizePx) => {
    ctx.font = runFontShorthand(family, weight, style, fontSizePx);
    return ctx.measureText(text).width;
  };
}
```

Update all five call sites to `canvasMeasure()`: `KvTileOverlayEditor.tsx:2646`, `KonvaRunTextNode.tsx:51` (its `useMemo` dependency list drops `props.fontSizePx`), `KvKonvaCanvas.tsx:1515`, `renderBoardStage.ts`, and `fabricExport.runs.test.ts:219`.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bun test src/components/studio/kv-generator/overlays/textRunLayout.test.ts src/components/studio/kv-generator/overlays/textRunMeasure.test.ts src/components/studio/kv-generator/fabricExport.runs.test.ts
```

Expected: PASS, including every pre-existing wrap test — those are the parity guarantee at this stage.

- [ ] **Step 6: Commit**

```bash
git add src/components/studio/kv-generator/overlays/textRunLayout.ts src/components/studio/kv-generator/overlays/konvaRunText.ts src/components/studio/kv-generator/overlays/textRunLayout.test.ts src/components/studio/kv-generator/KvTileOverlayEditor.tsx src/components/studio/kv-generator/overlays/KonvaRunTextNode.tsx src/components/studio/kv-generator/KvKonvaCanvas.tsx src/components/studio/kv-generator/renderBoardStage.ts src/components/studio/kv-generator/fabricExport.runs.test.ts
git commit -m "refactor(web): measure each text run at its own size

MeasureFn takes the size per call and canvasMeasure no longer curries
one, because a curried size would measure every run at the layer's.
Layout is unchanged for uniform text — asserted directly, since that
parity is what keeps the Konva.Text/run-Shape swap seamless."
```

---

### Task 6: Line height follows the tallest run on the line

**Files:**
- Modify: `src/components/studio/kv-generator/overlays/textRunLayout.ts:60-72` (RunTextLayout, LayoutLine), `:323-358` (positioning + return)
- Test: `src/components/studio/kv-generator/overlays/textRunLayout.test.ts`

**Interfaces:**
- Produces: `LayoutLine` gains `heightPx: number`; `height` becomes the sum of line heights. `RunTextLayout.lineHeightPx` **stays** in this task and is removed in Task 7 — removing it here would leave `paintRunLayout` reading a field that no longer exists, so this task's own commit would not compile.

- [ ] **Step 1: Write the failing tests**

```ts
it("sizes a line by its tallest run, and the block by the sum", () => {
  const layout = layoutRunText({
    ...base, boxWidth: 10000, fontSizePx: 20, lineHeight: 1,
    spans: [sizedSpan("big", 2), sizedSpan(" small\nplain")],
    measure: sizedMeasure,
  });
  expect(layout.lines[0].heightPx).toBe(40); // 20 * 2
  expect(layout.lines[1].heightPx).toBe(20); // no override on this line
  expect(layout.height).toBe(60);
});

it("PARITY: uniform text keeps lines.length * fontSizePx * lineHeight", () => {
  const layout = layoutRunText({
    ...base, boxWidth: 100, fontSizePx: 20, lineHeight: 1.5,
    spans: [sizedSpan("aaa bbb ccc ddd")], measure: sizedMeasure,
  });
  for (const l of layout.lines) expect(l.heightPx).toBe(30);
  expect(layout.height).toBe(layout.lines.length * 30);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bun test src/components/studio/kv-generator/overlays/textRunLayout.test.ts
```

Expected: FAIL — `heightPx` is undefined on a line.

- [ ] **Step 3: Compute height per line**

Add `heightPx: number;` to `LayoutLine`. **Keep** `lineHeightPx` on `RunTextLayout` and keep `const lineHeightPx = fontSizePx * lineHeight;` — it now means the layer's own default line height, and `paintRunLayout` still reads it until Task 7. Inside the `rows.map` compute:

```ts
    // Fabric's rule: a line is as tall as its tallest character. Matching it
    // keeps the authoring surface the reference rather than making both engines
    // follow a third rule we would have to maintain ourselves.
    const heightPx =
      Math.max(...r.map((a) => a.resolvedPx), fontSizePx) * lineHeight;
```

Note the `fontSizePx` floor in the `Math.max`: an empty row (a bare `\n`) has no atoms, and a blank line must still occupy the layer's own line height rather than collapsing to zero.

Return `height: lines.reduce((h, l) => h + l.heightPx, 0)`, include `heightPx` in each returned line object, and keep returning `lineHeightPx` unchanged.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bun test src/components/studio/kv-generator/overlays/textRunLayout.test.ts
```

Expected: PASS, and the tree still compiles — `paintRunLayout` keeps reading `lineHeightPx`, so uniform text is unchanged and mixed-size text is merely not yet painted at its new heights. Task 7 switches the painter over and then deletes the field.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/overlays/textRunLayout.ts src/components/studio/kv-generator/overlays/textRunLayout.test.ts
git commit -m "feat(web): size each text line by its tallest run

Line height becomes per-line (max run size * lineHeight, Fabric's own
rule) and block height the sum. A blank line floors at the layer size so
an empty paragraph does not collapse."
```

---

### Task 7: The painter walks per-line heights and baselines

**Files:**
- Modify: `src/components/studio/kv-generator/overlays/konvaRunText.ts:156-190` (paintRunLayout), `:191-240` (resolveBaseline)
- Test: `src/components/studio/kv-generator/overlays/konvaRunText.test.ts`

**Interfaces:**
- Consumes: `LayoutLine.heightPx` (Task 6), `LayoutSpan.sizeScale` (Task 5).
- Produces: `resolveBaseline` returns a per-line `translateY`; its signature becomes `(ctx, layout, fontSizePx) => { baseline, translateY: number[] }`. This task also **deletes** `RunTextLayout.lineHeightPx` — Task 6 deliberately left it so the tree kept compiling; once the painter walks `heightPx`, nothing reads it. Run `bunx tsc --noEmit` after removing it and fix any remaining reader.

**The constraint that governs this task:** `resolveBaseline`'s existing docstring explains it mirrors `Konva.Text._sceneFunc` because **both nodes are live at once** — a layer is a `Konva.Text` until a run overrides something and a custom Shape afterwards, so a baseline that differs would make the whole block jump the moment one word is bolded. It also states that metrics come from the **first span's font**, deliberately, so every line shares one baseline. Keep that: vary only the **size** per line. Re-deriving the font per line would change mixed-family multi-line text and break parity for a case this feature never touches.

- [ ] **Step 1: Write the failing tests**

```ts
it("advances y by each line's own height", () => {
  const ys: number[] = [];
  const ctx = makeRecordingContext((_t, _x, y) => ys.push(y));
  const layout = layoutRunText({
    ...base, boxWidth: 10000, fontSizePx: 20, lineHeight: 1,
    spans: [sizedSpan("big\n", 2), sizedSpan("small")],
    measure: sizedMeasure,
  });
  paintRunLayout(ctx, layout, 20, { type: "solid", color: "#111" });
  // Line 0 is 40 tall, so line 1 starts 40 down, not 20.
  expect(ys[1] - ys[0]).toBe(40);
});

it("PARITY: uniform text paints at the same y as before", () => {
  const ys: number[] = [];
  const ctx = makeRecordingContext((_t, _x, y) => ys.push(y));
  const layout = layoutRunText({
    ...base, boxWidth: 40, fontSizePx: 20, lineHeight: 1,
    spans: [sizedSpan("aaaa bbbb cccc")], measure: sizedMeasure,
  });
  paintRunLayout(ctx, layout, 20, { type: "solid", color: "#111" });
  for (let i = 1; i < ys.length; i++) expect(ys[i] - ys[i - 1]).toBe(20);
});
```

Add the helper at the top of the file if it is not already there:

```ts
function makeRecordingContext(
  onFill: (text: string, x: number, y: number) => void
): Konva.Context {
  return {
    save() {}, restore() {},
    fillStyle: "", font: "",
    textBaseline: "" as CanvasTextBaseline,
    textAlign: "" as CanvasTextAlign,
    fillText: onFill,
    measureText: () => ({
      width: 10,
      fontBoundingBoxAscent: 8,
      fontBoundingBoxDescent: 2,
    }),
  } as unknown as Konva.Context;
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bun test src/components/studio/kv-generator/overlays/konvaRunText.test.ts
```

Expected: FAIL — `layout.lineHeightPx` is `undefined` after Task 6, so every `y` is `NaN`.

- [ ] **Step 3: Resolve a baseline per line**

Replace `resolveBaseline`:

```ts
function resolveBaseline(
  ctx: Konva.Context,
  layout: RunTextLayout,
  fontSizePx: number
): { baseline: CanvasTextBaseline; translateY: number[] } {
  const middle = {
    baseline: "middle" as CanvasTextBaseline,
    translateY: layout.lines.map((l) => l.heightPx / 2),
  };
  // The metrics font stays GLOBAL — the first span of the first non-empty line,
  // exactly as before. Only the SIZE varies per line. Re-deriving the font per
  // line would move mixed-family multi-line text, which this feature does not
  // touch and whose parity we are obliged to keep.
  const first = layout.lines.find((l) => l.spans.length > 0)?.spans[0];
  if (!first || typeof ctx.measureText !== "function") return middle;
  const translateY = layout.lines.map((line) => {
    const linePx = Math.max(...line.spans.map((s) => s.sizeScale * fontSizePx), fontSizePx);
    ctx.font = runFontShorthand(first.fontFamily, first.fontWeight, first.fontStyle, linePx);
    const m = ctx.measureText("M");
    const ascent = m.fontBoundingBoxAscent ?? m.actualBoundingBoxAscent;
    const descent = m.fontBoundingBoxDescent ?? m.actualBoundingBoxDescent;
    if (!Number.isFinite(ascent) || !Number.isFinite(descent)) return line.heightPx / 2;
    return (ascent - descent) / 2 + line.heightPx / 2;
  });
  return { baseline: "alphabetic", translateY };
}
```

If any line falls back, the whole node must still use one `baseline` mode; the per-line `heightPx / 2` fallback above keeps `"alphabetic"` correct for the lines that did measure.

- [ ] **Step 4: Walk the lines with a running offset**

In `paintRunLayout`, replace the `forEach` header and the per-span font:

```ts
  let yTop = 0;
  layout.lines.forEach((line, i) => {
    const y = yTop + translateY[i];
    yTop += line.heightPx;
    for (const s of line.spans) {
      ctx.fillStyle = s.color ?? layerFill;
      ctx.font = runFontShorthand(
        s.fontFamily,
        s.fontWeight,
        s.fontStyle,
        fontSizePx * s.sizeScale
      );
```

The per-character tracking loop below it is unchanged — it re-measures with `ctx.measureText(ch)` under whatever font was just set, so it picks up the run size for free.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bun test src/components/studio/kv-generator/overlays/konvaRunText.test.ts src/components/studio/kv-generator/overlays/KonvaRunTextNode.test.tsx src/components/studio/kv-generator/renderBoardStage.test.ts
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/components/studio/kv-generator/overlays/konvaRunText.ts src/components/studio/kv-generator/overlays/konvaRunText.test.ts
git commit -m "feat(web): paint mixed-size text on per-line baselines

y accumulates each line's own height, and the baseline offset is resolved
per line. The metrics FONT stays global on purpose — only the size
varies — so mixed-family multi-line text lands exactly where it does
today and the Konva.Text/run-Shape swap stays seamless."
```

---

### Task 8: Fabric applies per-run size

**Files:**
- Modify: `src/components/studio/kv-generator/fabricExport.ts:285-306` (applyRunStylesToTextbox) and its two call sites at `:353` and in `KvFabricCanvas.tsx`
- Test: `src/components/studio/kv-generator/fabricExport.runs.test.ts`

**Interfaces:**
- Consumes: `RunSpan.sizeScale` (Task 1).
- Produces: `applyRunStylesToTextbox(box, spans, axis)` now reads `box.fontSize` as the layer size — no new parameter, because a Textbox always already carries its own resolved px size.

- [ ] **Step 1: Write the failing test**

```ts
it("scales a run's fontSize off the Textbox's own size", () => {
  const box = new fabric.Textbox("Hello world", { fontSize: 40 });
  applyRunStylesToTextbox(box, [
    { text: "Hello", contentStart: 0, contentLength: 5, displayStart: 0, displayLength: 5, fontFamily: "Geist", fontWeight: "normal", fontStyle: "normal", sizeScale: 1.5 },
    { text: " world", contentStart: 5, contentLength: 6, displayStart: 5, displayLength: 6, fontFamily: "Geist", fontWeight: "normal", fontStyle: "normal", sizeScale: 1 },
  ], "display");
  expect(box.getSelectionStyles(0, 1)[0].fontSize).toBe(60);
  expect(box.getSelectionStyles(6, 7)[0].fontSize).toBeUndefined();
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bun test src/components/studio/kv-generator/fabricExport.runs.test.ts
```

Expected: FAIL — `fontSize` is undefined on the first character.

- [ ] **Step 3: Write the size only when the run overrides it**

In `applyRunStylesToTextbox`, extend the style object built in Task 3:

```ts
    if (s.color) style.fill = s.color;
    // The Textbox's own fontSize is the layer size in px, already denormalized
    // by the caller — so the scale applies directly and this function still
    // needs no board height.
    if (s.sizeScale !== 1) style.fontSize = (box.fontSize ?? 0) * s.sizeScale;
```

`box.initDimensions()` at the end of the function already reflows, so mixed sizes rewrap with no further change.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bun test src/components/studio/kv-generator/fabricExport.runs.test.ts src/components/studio/kv-generator/exportFlatten.fonts.test.ts
```

Expected: PASS.

- [ ] **Step 5: Cross-engine check**

Add to `src/components/studio/kv-generator/fabricExport.runs.test.ts`:

```ts
it("Fabric and Konva agree on the line count for mixed-size text", () => {
  const spans = resolveRunSpans({
    type: "text", content: "The quick brown fox jumps over it",
    color: "#111111", fontSize: 0.1,
    runs: [{ length: 9, fontSize: 0.2 }, { length: 24 }],
  })!;
  const box = new fabric.Textbox("The quick brown fox jumps over it", {
    fontSize: 40, width: 300, splitByGrapheme: false,
  });
  applyRunStylesToTextbox(box, spans, "display");
  const konva = layoutRunText({
    spans, boxWidth: 300, fontSizePx: 40, lineHeight: 1,
    letterSpacingPx: 0, align: "left", measure: canvasMeasure(),
  });
  expect(konva.lines.length).toBe(box.textLines.length);
});
```

```bash
bun test src/components/studio/kv-generator/fabricExport.runs.test.ts
```

Expected: PASS. A failure here is the whole point of the task — it means the two engines disagree about where mixed-size text wraps, and that disagreement would ship as a share page that does not match the canvas. Do not weaken the assertion to make it pass; fix the layout.

- [ ] **Step 6: Commit**

```bash
git add src/components/studio/kv-generator/fabricExport.ts src/components/studio/kv-generator/fabricExport.runs.test.ts
git commit -m "feat(web): apply per-run size to Fabric textboxes

The Textbox already carries the layer size in px, so the scale applies
directly and no board height is needed. Adds the cross-engine assertion
that Fabric and Konva wrap mixed-size text onto the same number of lines."
```

---

### Task 9: The size field is range-scoped and shows "mixed"

**Files:**
- Modify: `src/components/studio/kv-generator/overlays/TextTypographyControls.tsx:240-246` (the size field), `:104-130` (mixed treatment)
- Modify: `src/components/studio/kv-generator/overlays/FontSizeField.tsx`
- Test: `src/components/studio/kv-generator/overlays/TextTypographyControls.test.tsx`

**Interfaces:**
- Consumes: `dispatchTextPatch` (Task 4) — already routes `fontSize` once it is in `RUN_PROPS`, so this task is presentation plus one materialization rule.

**Materialization rule:** `RunSpan.sizeScale` falls back to 1 when the layer has no `payload.fontSize` (Task 1). So a run size set on such a layer would be silently ignored. The field must therefore commit the layer's own `fontSize` alongside the run override whenever `payload.fontSize` is absent.

- [ ] **Step 1: Write the failing tests**

```tsx
it("shows no concrete number when the selected range mixes sizes", () => {
  render(
    <TextTypographyControls
      {...baseProps}
      payload={{ ...baseProps.payload, fontSize: 0.1, runs: [{ length: 2, fontSize: 0.2 }, { length: 3 }] }}
      effectiveStyle={{ fontSize: undefined }}
      styleScope="range"
    />
  );
  expect(screen.getByLabelText(/font size/i)).toHaveValue("");
  expect(screen.getByLabelText(/font size/i)).toHaveAttribute("placeholder", "Mixed");
});

```

And to `src/components/studio/kv-generator/overlays/commitSemantics.test.tsx` — this one belongs with the dispatcher, not the component:

```ts
it("materializes the layer fontSize when a run size lands on a layer without one", () => {
  const patch = dispatchTextPatch({
    payload: { type: "text", content: "Hello world", color: "#111111" },
    partial: { fontSize: 0.2 },
    range: { start: 0, end: 5 },
  });
  expect(patch.fontSize).toBe(0.2);
  expect(patch.runs?.[0]).toMatchObject({ length: 5, fontSize: 0.2 });
});

it("ROUND-TRIP: setting a run size then clearing it restores the original payload", () => {
  const original = {
    type: "text" as const, content: "Hello world", color: "#111111", fontSize: 0.1,
  };
  const sized = dispatchTextPatch({
    payload: original,
    partial: { fontSize: 0.2 },
    range: { start: 0, end: 5 },
  });
  const cleared = dispatchTextPatch({
    payload: { ...original, ...sized },
    partial: { fontSize: 0.1 },
    range: null,
  });
  expect(cleared.runs?.some((r) => r.fontSize)).toBe(false);
  expect(cleared.fontSize).toBe(0.1);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bun test src/components/studio/kv-generator/overlays/TextTypographyControls.test.tsx
```

Expected: FAIL — the field renders the layer size as a concrete number for a mixed range, and emits no layer `fontSize`.

- [ ] **Step 3: Add the mixed state to the field**

`FontSizeField` gains a `mixed?: boolean` prop. When true it renders an empty value with placeholder `"Mixed"`, matching the dotted-underline treatment `SegBtn` already uses for a property that differs across a range (`TextTypographyControls.tsx:105-108`). In `TextTypographyControls`, pass `mixed={effectiveStyle.fontSize === undefined && styleScope === "range"}`.

Committing a value from a mixed field is a deliberate flatten of the range — that is what the user asked for by typing a number — so no extra guard is needed there.

- [ ] **Step 4: Materialize the layer size in the dispatcher**

The size field's `onCommit` (line 244) stays exactly as it is — it already emits `{ fontSize: px / natH }`, and the field has no business knowing about runs. The materialization belongs in `dispatchTextPatch`, which is the one place that knows the patch is range-scoped:

```ts
    const out: Partial<TextPayload> & { runs?: TextStyleRun[] } = {
      runs: applyRunStyle(payload, range.start, range.end, runScoped),
    };
    if ("fontSize" in runScoped && payload.fontSize === undefined) {
      // Nothing to scale against otherwise — resolveRunSpans would fall back
      // to scale 1 and the override would vanish on the next read.
      out.fontSize = runScoped.fontSize;
    }
    return out;
```

- [ ] **Step 5: Correct the analytics docstring that this task falsifies**

`KvTextStyleChangedProps` in `src/lib/analytics/kv-generator-events.ts` currently documents its own behaviour as:

> `scope` is `"range"` only for `font_weight`/`font_style` edits committed while a non-collapsed text selection is active — every other property (and font_weight/font_style with no selection) is `"layer"`.

That sentence becomes false the moment `fontSize` joins `RUN_PROPS`. Rewrite it to name the run-scoped properties as the set they now are (font family, weight, style, size, colour), and confirm the size field's `trackKvTextStyleChanged({ property: "font_size", scope: styleScope })` call passes the real `styleScope` rather than a hardcoded `"layer"`.

A stale docstring on an analytics type is not cosmetic: it is what the next person reads before deciding whether a dashboard's `scope` breakdown is trustworthy.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
bun test src/components/studio/kv-generator/overlays/TextTypographyControls.test.tsx src/components/studio/kv-generator/overlays/TextTypographyControls.analytics.test.tsx src/components/studio/kv-generator/overlays/commitSemantics.test.tsx
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/lib/analytics/kv-generator-events.ts src/components/studio/kv-generator/overlays/TextTypographyControls.tsx src/components/studio/kv-generator/overlays/FontSizeField.tsx src/components/studio/kv-generator/overlays/TextTypographyControls.test.tsx src/components/studio/kv-generator/overlays/dispatchTextPatch.ts src/components/studio/kv-generator/overlays/commitSemantics.test.tsx
git commit -m "feat(web): range-scoped font size with a mixed state

A range that mixes sizes shows no concrete number, so committing the
field is an explicit flatten rather than an accident. Setting a run size
on a layer that has no explicit fontSize also materializes the layer
value, since a run size is resolved as a ratio and would otherwise be
dropped on the next read."
```

---

### Task 10: A corner drag scales run sizes

**Files:**
- Modify: `src/components/studio/kv-generator/KvFabricCanvas.tsx:1444-1452` (textFontPatch)
- Test: `src/components/studio/kv-generator/overlays/commitSemantics.test.tsx`

**Interfaces:**
- Consumes: `TextStyleRun.fontSize` (Task 1).
- Produces: `scaleTextRuns(runs, factor): TextStyleRun[]`, exported from `textRuns.ts`.

**Why this is not the same as the slider:** the slider assigns an absolute value and clears run overrides (Figma's behaviour, and consistent with Bold/Font). A drag multiplies — `fontSize: (curFontPx * scaleY) / hostH` — and a multiplier composes with absolute overrides. Clearing here would destroy work with no warning; ignoring runs would visibly break the layer's proportions on the first drag.

- [ ] **Step 1: Write the failing test**

```ts
it("scales every run size by the same factor as the layer", () => {
  const runs = [{ length: 5, fontSize: 0.2 }, { length: 6 }, { length: 4, fontSize: 0.05 }];
  expect(scaleTextRuns(runs, 1.5)).toEqual([
    { length: 5, fontSize: 0.30000000000000004 },
    { length: 6 },
    { length: 4, fontSize: 0.07500000000000001 },
  ]);
});

it("returns the same array reference when nothing overrides size", () => {
  const runs = [{ length: 5, fontWeight: "bold" as const }];
  expect(scaleTextRuns(runs, 2)).toBe(runs);
});

it("leaves runs alone for a factor of exactly 1", () => {
  const runs = [{ length: 5, fontSize: 0.2 }];
  expect(scaleTextRuns(runs, 1)).toBe(runs);
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bun test src/components/studio/kv-generator/overlays/textRuns.mutations.test.ts
```

Expected: FAIL with "scaleTextRuns is not exported".

- [ ] **Step 3: Add the helper**

Append to `textRuns.ts`:

```ts
/**
 * Multiply every run's size override by `factor`.
 *
 * A drag is a TRANSFORM, not a style assignment: it multiplies the layer size,
 * so it must multiply the overrides too or the layer's proportions break on the
 * first corner pull. This is deliberately the opposite of what the size SLIDER
 * does (which assigns an absolute value and clears overrides) — see the design
 * doc's Decision 5.
 *
 * Returns the input array unchanged when there is nothing to scale, so a drag
 * on ordinary text writes no new `runs` array.
 */
export function scaleTextRuns(
  runs: TextStyleRun[],
  factor: number
): TextStyleRun[] {
  if (factor === 1 || !runs.some((r) => r.fontSize)) return runs;
  return runs.map((r) =>
    r.fontSize ? { ...r, fontSize: r.fontSize * factor } : r
  );
}
```

- [ ] **Step 4: Call it from the drag writeback**

In `KvFabricCanvas.tsx`, extend `textFontPatch`:

```ts
        const textFontPatch = (hostH: number) =>
          textPayload && hostH > 0
            ? {
                payload: {
                  ...textPayload,
                  fontSize: (curFontPx * scaleY) / hostH,
                  // A drag multiplies the layer size; run overrides are stored
                  // absolute, so they must be multiplied by the same factor or
                  // the styled words stay put while the rest grows.
                  ...(textPayload.runs
                    ? { runs: scaleTextRuns(textPayload.runs, scaleY) }
                    : {}),
                },
              }
            : {};
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bun test src/components/studio/kv-generator/overlays/textRuns.mutations.test.ts src/components/studio/kv-generator/overlays/commitSemantics.test.tsx
```

Expected: PASS.

- [ ] **Step 6: Full suite + typecheck**

```bash
bun test src/components/studio/kv-generator/overlays src/components/studio/kv-generator/fabricExport.runs.test.ts src/components/studio/kv-generator/renderBoardStage.test.ts
bunx tsc --noEmit
```

Expected: PASS.

**Do NOT run `bun test src/components/studio/kv-generator` as a gate.** That whole-directory run is already red on `origin/develop` — 25-26 pre-existing failures, varying between runs — caused by cross-file interference, not by anything in this plan. Every file this plan touches passes in isolation. The pre-existing list is captured at `.superpowers/sdd/2026-09-10-kv-text-run-size-color-web/baseline-failures.txt`; compare against it rather than against zero, and never "fix" a test to make that run green.

`tsc` is the real gate for this plan — removing `RunTextLayout.lineHeightPx` in Task 6 and widening `MeasureFn` in Task 5 are both breaking changes, and the compiler is what proves no render site was left behind.

- [ ] **Step 7: Commit**

```bash
git add src/components/studio/kv-generator/overlays/textRuns.ts src/components/studio/kv-generator/overlays/textRuns.mutations.test.ts src/components/studio/kv-generator/KvFabricCanvas.tsx
git commit -m "feat(web): a corner drag scales run sizes with the layer

Deliberately the opposite of the size slider, which assigns an absolute
value and clears overrides. A drag multiplies, and a multiplier composes
with absolute overrides — clearing here would destroy styling with no
warning, and ignoring runs would break the layer's proportions on the
first pull."
```
