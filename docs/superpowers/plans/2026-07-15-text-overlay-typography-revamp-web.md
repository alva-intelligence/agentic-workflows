# Text Overlay Typography Revamp — Web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make KV text overlays auto-fit their text, and give them a consolidated typography panel with solid + 2-color linear gradient fill.

**Architecture:** Switch the Fabric text primitive from `Textbox` (fixed-width, wraps) to `IText` (hugs content); drop Konva's fixed width so it hugs too. Add an optional `payload.gradient {from,to,angle}` rendered via one `resolveTextFill` helper across Fabric + Konva + the resize/export stages. Move fill (solid/gradient) into the Text section of the properties panel and remove the floating color-chip palette.

**Tech Stack:** Next.js 16, React 19, TypeScript, Fabric.js v6, Konva/react-konva, Bun (`bun test`).

## Global Constraints

- `payload.gradient` is OPTIONAL. Absent ⇒ solid `payload.color` renders exactly as today (full back-compat for legacy overlays). Invalid/partial gradient ⇒ fall back to solid `color`.
- `gradient.angle` in degrees, `0 = left→right`, `90 = top→bottom`; default `90`. `from`/`to` are `#RRGGBB`.
- `payload.fontSize` (normalized fraction of host height) already exists — keep using it; legacy fallback `overlay.height * 0.8` (Fabric/Konva) / `overlay.height` (resize stages) stays.
- Tests run with `bun test <file>` (NOT vitest). Build gate: `bun run build`. For canvas/type changes verify with `bunx tsc --noEmit -p tsconfig.json` and grep your files against the pre-existing baseline (there is a known pre-existing `VideoCapabilities` error in `KvGeneratorLayout.tsx`, ~line 1797 — not yours).
- Fabric objects use `originX/originY: "center"`. Gradient coords use the object's own width/height (0..W, 0..H).
- Worktree = web repo root: `/Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/kv-canvas-custom-fonts`. Paths starting `web/` map here (strip `web/`).

---

### Task 1: Add `gradient` to the text payload types

**Files:**
- Modify: `src/types/studio.ts` (StudioOverlay text payload ~line 450, BrandOverlayPreset text payload ~line 516)
- Test: `src/types/studio.gradient.test.ts`

**Interfaces:**
- Produces: text payload gains `gradient?: { from: string; to: string; angle: number }` on BOTH `StudioOverlay` and `BrandOverlayPreset`.

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect } from "bun:test";
import type { StudioOverlay } from "@/types/studio";

describe("text payload gradient", () => {
  it("accepts an optional linear gradient", () => {
    const p: StudioOverlay["payload"] = {
      type: "text",
      content: "hi",
      color: "#ffffff",
      gradient: { from: "#ff0000", to: "#0000ff", angle: 90 },
    };
    expect(p.type === "text" && p.gradient?.angle).toBe(90);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/types/studio.gradient.test.ts`
Expected: FAIL (type error: `gradient` not on payload).

- [ ] **Step 3: Edit `src/types/studio.ts`**

Add `gradient?: { from: string; to: string; angle: number }` to the text member of BOTH payload unions (the `StudioOverlay.payload` text object and the `BrandOverlayPreset.overlays[].payload` text object), directly after `fontSize?: number`. Add a JSDoc line: normalized angle in degrees, from/to are `#RRGGBB`, absent ⇒ solid `color`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/types/studio.gradient.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web/src/types/studio.ts web/src/types/studio.gradient.test.ts
git commit -m "feat(web): add optional linear gradient to text overlay payload"
```

---

### Task 2: `resolveTextFill` helper (Fabric + Konva gradient math)

**Files:**
- Create: `src/components/studio/kv-generator/overlays/resolveTextFill.ts`
- Test: `src/components/studio/kv-generator/overlays/resolveTextFill.test.ts`

**Interfaces:**
- Consumes: `StudioOverlay` payload type (Task 1), `fabric` (import type only in the ts; the Gradient is constructed by callers to avoid importing fabric into Konva bundles — see below).
- Produces:
  - `hasTextGradient(payload): boolean` — true only when payload is text AND `gradient` has valid `from`/`to` strings and finite `angle`.
  - `gradientLineCoords(angle, w, h): { x1:number; y1:number; x2:number; y2:number }` — pure geometry: unit vector `(cos,sin)` of the angle, projected length `L = |cos|*w + |sin|*h`, centered on `(w/2,h/2)`; start `= center - dir*L/2`, end `= center + dir*L/2`.
  - `konvaTextFill(payload, w, h)` → for gradient: `{ fillLinearGradientStartPoint:{x:x1,y:y1}, fillLinearGradientEndPoint:{x:x2,y:y2}, fillLinearGradientColorStops:[0, from, 1, to] }`; for solid: `{ fill: payload.color }`. (Konva has no fabric dependency.)
  - `fabricTextColorStops(payload)` → `[{offset:0,color:from},{offset:1,color:to}]` (callers build the `fabric.Gradient` with `gradientLineCoords`).

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect } from "bun:test";
import {
  hasTextGradient,
  gradientLineCoords,
  konvaTextFill,
} from "./resolveTextFill";

const solid = { type: "text", content: "x", color: "#112233" } as const;
const grad = {
  type: "text",
  content: "x",
  color: "#112233",
  gradient: { from: "#ff0000", to: "#0000ff", angle: 0 },
} as const;

describe("resolveTextFill", () => {
  it("detects gradients", () => {
    expect(hasTextGradient(solid)).toBe(false);
    expect(hasTextGradient(grad)).toBe(true);
    expect(
      hasTextGradient({ ...grad, gradient: { from: "", to: "#000000", angle: 0 } })
    ).toBe(false);
  });

  it("angle 0 spans left→right across the box", () => {
    const c = gradientLineCoords(0, 100, 40);
    expect(c.x1).toBeCloseTo(0, 3);
    expect(c.x2).toBeCloseTo(100, 3);
    expect(c.y1).toBeCloseTo(20, 3);
    expect(c.y2).toBeCloseTo(20, 3);
  });

  it("angle 90 spans top→bottom", () => {
    const c = gradientLineCoords(90, 100, 40);
    expect(c.y1).toBeCloseTo(0, 3);
    expect(c.y2).toBeCloseTo(40, 3);
  });

  it("konvaTextFill returns solid fill when no gradient", () => {
    expect(konvaTextFill(solid, 100, 40)).toEqual({ fill: "#112233" });
  });

  it("konvaTextFill returns linear-gradient props when gradient", () => {
    const f = konvaTextFill(grad, 100, 40) as Record<string, unknown>;
    expect(f.fillLinearGradientColorStops).toEqual([0, "#ff0000", 1, "#0000ff"]);
    expect(f.fillLinearGradientStartPoint).toBeDefined();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/overlays/resolveTextFill.test.ts`
Expected: FAIL ("Cannot find module './resolveTextFill'").

- [ ] **Step 3: Write the helper**

```ts
import type { StudioOverlay } from "@/types/studio";

type TextPayload = Extract<StudioOverlay["payload"], { type: "text" }>;

export function hasTextGradient(
  payload: StudioOverlay["payload"]
): payload is TextPayload & { gradient: { from: string; to: string; angle: number } } {
  if (payload.type !== "text" || !payload.gradient) return false;
  const g = payload.gradient;
  return (
    typeof g.from === "string" &&
    /^#[0-9A-Fa-f]{6}$/.test(g.from) &&
    typeof g.to === "string" &&
    /^#[0-9A-Fa-f]{6}$/.test(g.to) &&
    Number.isFinite(g.angle)
  );
}

/** Start/end of the gradient line across a w×h box (local coords, top-left
 *  origin), for the given angle in degrees (0 = →, 90 = ↓). The line is
 *  centered and spans the box's extent along the direction so both stops are
 *  visible regardless of angle. */
export function gradientLineCoords(
  angle: number,
  w: number,
  h: number
): { x1: number; y1: number; x2: number; y2: number } {
  const rad = (angle * Math.PI) / 180;
  const dx = Math.cos(rad);
  const dy = Math.sin(rad);
  const len = Math.abs(dx) * w + Math.abs(dy) * h;
  const cx = w / 2;
  const cy = h / 2;
  return {
    x1: cx - (dx * len) / 2,
    y1: cy - (dy * len) / 2,
    x2: cx + (dx * len) / 2,
    y2: cy + (dy * len) / 2,
  };
}

/** Konva `<Text>` fill props for a text overlay — solid or linear gradient. */
export function konvaTextFill(
  payload: StudioOverlay["payload"],
  w: number,
  h: number
):
  | { fill: string }
  | {
      fillLinearGradientStartPoint: { x: number; y: number };
      fillLinearGradientEndPoint: { x: number; y: number };
      fillLinearGradientColorStops: (number | string)[];
    } {
  if (!hasTextGradient(payload)) {
    return { fill: payload.type === "text" ? payload.color : "#ffffff" };
  }
  const { from, to, angle } = payload.gradient;
  const c = gradientLineCoords(angle, w, h);
  return {
    fillLinearGradientStartPoint: { x: c.x1, y: c.y1 },
    fillLinearGradientEndPoint: { x: c.x2, y: c.y2 },
    fillLinearGradientColorStops: [0, from, 1, to],
  };
}

/** Fabric `Gradient` colorStops for a text overlay (callers build the Gradient
 *  with `gradientLineCoords` so fabric isn't imported into Konva code paths). */
export function fabricTextColorStops(
  payload: StudioOverlay["payload"]
): { offset: number; color: string }[] | null {
  if (!hasTextGradient(payload)) return null;
  return [
    { offset: 0, color: payload.gradient.from },
    { offset: 1, color: payload.gradient.to },
  ];
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/overlays/resolveTextFill.test.ts`
Expected: PASS (all cases).

- [ ] **Step 5: Commit**

```bash
git add web/src/components/studio/kv-generator/overlays/resolveTextFill.ts web/src/components/studio/kv-generator/overlays/resolveTextFill.test.ts
git commit -m "feat(web): add resolveTextFill helper (solid + linear gradient)"
```

---

### Task 3: `ColorField` control (swatch + preset/hex popover)

**Files:**
- Create: `src/components/studio/kv-generator/overlays/ColorField.tsx`
- Test: `src/components/studio/kv-generator/overlays/ColorField.test.tsx`

**Interfaces:**
- Produces: `ColorField({ value, onChange, label? })` — a swatch button showing `value`; clicking opens a popover with the existing preset swatch palette (reuse the color list from `OverlayColorChip` — extract the array to a shared `overlayColors.ts` constant if inlined there) + a hex `<input>`. `onChange(hex)` fires on a preset click or a valid `#RRGGBB` hex entry.

- [ ] **Step 1: Write the failing test**

```tsx
import { describe, it, expect, mock } from "bun:test";
import { render, screen, fireEvent } from "@testing-library/react";
import { ColorField } from "./ColorField";

describe("ColorField", () => {
  it("renders the current value and emits a new hex on preset click", () => {
    const onChange = mock(() => {});
    render(<ColorField value="#112233" onChange={onChange} />);
    fireEvent.click(screen.getByRole("button")); // open popover
    // A preset swatch has an accessible name of its hex; click one.
    const swatch = screen.getAllByRole("button").find((b) =>
      (b.getAttribute("aria-label") ?? "").startsWith("#")
    );
    expect(swatch).toBeDefined();
    fireEvent.click(swatch!);
    expect(onChange).toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/overlays/ColorField.test.tsx`
Expected: FAIL ("Cannot find module './ColorField'").

- [ ] **Step 3: Write `ColorField`**

Requirements (use frndOS v2 popover/primitives where available — check `frndos-components-v2`; a plain absolutely-positioned popover is acceptable if none fits):
- A swatch `<button aria-label={value}>` with `style={{ background: value }}`.
- On click, toggles an inline popover containing: the preset swatches (each `<button aria-label={hex} style={{background:hex}} onClick={() => { onChange(hex); close(); }}>`), and a hex `<input maxLength={7}>` that calls `onChange` when the value matches `/^#[0-9A-Fa-f]{6}$/`.
- Extract the preset color array from `OverlayColorChip.tsx` into `overlays/overlayColors.ts` (`export const OVERLAY_PRESET_COLORS: string[]`) and import it here + in `OverlayColorChip` (keep that file working until it's removed in Task 7).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/overlays/ColorField.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web/src/components/studio/kv-generator/overlays/ColorField.tsx web/src/components/studio/kv-generator/overlays/ColorField.test.tsx web/src/components/studio/kv-generator/overlays/overlayColors.ts
git commit -m "feat(web): add ColorField control (presets + hex)"
```

---

### Task 4: Fabric — `Textbox → IText` (auto-fit) + gradient fill + corner-only controls

**Files:**
- Modify: `src/components/studio/kv-generator/KvFabricCanvas.tsx`
- Test: `src/components/studio/kv-generator/fonts/resolveFamily.test.ts` already covers family; add no new unit test (canvas is integration — verify via `bun run build`).

**Interfaces:**
- Consumes: `hasTextGradient`, `gradientLineCoords`, `fabricTextColorStops` (Task 2).

- [ ] **Step 1: Swap the primitive**

Replace every text-overlay `fabric.Textbox` with `fabric.IText`:
- The create branch (~line 1046): `new fabric.IText(overlay.payload.content ?? "", {...})` — REMOVE the `width: w` line (IText auto-sizes; a fixed width is a Textbox concept). Keep `fontSize: fontPx`, `fill`, `angle`, `editable: true`, `textAlign: "center"`, `fontFamily`.
- The update branch (~line 1021 `if (found instanceof fabric.Textbox)`) → `if (found instanceof fabric.IText)`. In its `found.set({...})`, REMOVE `width: w` (auto). Keep `left, top, fontSize: fontPx, scaleX:1, scaleY:1` and the second `.set` (fill/angle/selectable/evented/fontFamily).
- The font-sync effect cast (~line 1189) and the editing-effect cast (~line 1212): `as fabric.IText`.
- The onModified `curFontPx` guard (~line 612): `obj instanceof fabric.IText`.
- Any other `instanceof fabric.Textbox` / `as fabric.Textbox` for overlay text → `IText`. (Grep to confirm none remain for text overlays.)

- [ ] **Step 2: Apply the fill (solid or gradient)**

Add a helper inside the component near the reconcile:

```ts
function applyTextFill(obj: fabric.IText, overlay: StudioOverlay) {
  const stops = fabricTextColorStops(overlay.payload);
  if (stops && overlay.payload.type === "text" && overlay.payload.gradient) {
    const w = obj.width || 1;
    const h = obj.height || 1;
    const c = gradientLineCoords(overlay.payload.gradient.angle, w, h);
    obj.set(
      "fill",
      new fabric.Gradient({
        type: "linear",
        gradientUnits: "pixels",
        coords: { x1: c.x1, y1: c.y1, x2: c.x2, y2: c.y2 },
        colorStops: stops,
      })
    );
  } else {
    obj.set(
      "fill",
      overlay.payload.type === "text" ? overlay.payload.color : "#ffffff"
    );
  }
}
```

Call `applyTextFill(found, overlay)` in the update branch AFTER the `.set` calls, and `applyTextFill(box, overlay)` right before `add(box, overlay)` in the create branch. REPLACE the `fill: overlay.payload.color ?? "#ffffff"` literals in both `.set`/constructor with a neutral default (the fill is now driven by `applyTextFill`). Recompute the gradient when the box size or gradient changes: extend the existing font-sync signature (`overlayFontSig`) OR add a parallel `overlayFillSig` that includes `payload.color`, `payload.gradient` (JSON), and the rendered `obj.width/height`, and re-run `applyTextFill` in that effect (initDimensions first so `obj.width/height` are current).

- [ ] **Step 3: Corner-only resize controls**

In the overlay `add` helper (~line 940), for TEXT overlays set:
```ts
obj.setControlsVisibility({ ml: false, mr: false, mt: false, mb: false });
```
so only corners (uniform) + rotate show — matching auto-fit (no independent wrap width). Leave image overlays unchanged.

- [ ] **Step 4: Verify**

Run: `cd web && bunx tsc --noEmit -p tsconfig.json` → grep `KvFabricCanvas` → no NEW errors.
Run: `cd web && bun run build` → succeeds.
Grep: `grep -n "fabric.Textbox" src/components/studio/kv-generator/KvFabricCanvas.tsx` → only comments may mention it; no live `Textbox` construction/instanceof for overlay text remains.

- [ ] **Step 5: Commit**

```bash
git add web/src/components/studio/kv-generator/KvFabricCanvas.tsx
git commit -m "feat(web): Fabric text overlays auto-fit (IText) with gradient fill"
```

---

### Task 5: Konva — hug + gradient fill

**Files:**
- Modify: `src/components/studio/kv-generator/KvKonvaCanvas.tsx` (overlay content `<Text>`, ~line 1810)

- [ ] **Step 1: Hug + gradient**

On the overlay content `<Text>`:
- REMOVE the fixed `width={pw}` so the text hugs its content (keep `height` off too, or leave as-is if removal breaks centering — prefer removing both; verify centering with `offsetX`/`align`).
- Replace `fill={overlay.payload.type === "text" ? overlay.payload.color : "#fff"}` by spreading `konvaTextFill(overlay.payload, pw, ph)`:
  ```tsx
  {...konvaTextFill(overlay.payload, pw, ph)}
  ```
  (Import `konvaTextFill` from `../overlays/resolveTextFill`. Keep `fontSize` + `fontFamily` as-is.)

- [ ] **Step 2: Verify**

Run: `cd web && bunx tsc --noEmit -p tsconfig.json` → grep `KvKonvaCanvas` → no NEW errors.
Run: `cd web && bun run build` → succeeds.

- [ ] **Step 3: Commit**

```bash
git add web/src/components/studio/kv-generator/KvKonvaCanvas.tsx
git commit -m "feat(web): Konva text overlays hug + gradient fill"
```

---

### Task 6: Resize / export stages — gradient fill

**Files:**
- Modify: `src/components/studio/kv-generator/KvResizeTileStage.tsx` (~line 117), `KvTileOverlayEditor.tsx` (~line 279), `KvResizeCanvas.tsx` (~line 613)

- [ ] **Step 1: Apply gradient fill at all three sites**

Each currently renders a Konva `Text`/`Konva.Text` with `fill={ov.payload.color}` (JSX) or `fill: ov.payload.color` (imperative) and the explicit `fontSize`. Replace the `fill` with the resolved fill using the stage's box dims:
- JSX (`KvResizeTileStage`, `KvTileOverlayEditor`): spread `{...konvaTextFill(ov.payload, w, h)}` in place of `fill={ov.payload.color}`.
- Imperative (`KvResizeCanvas`, `new Konva.Text({...})`): merge `konvaTextFill(ov.payload, ow, oh)` into the config object (spread), replacing `fill: ov.payload.color`.
Import `konvaTextFill` from `../overlays/resolveTextFill` in each. Keep the explicit `fontSize` expressions already present.

- [ ] **Step 2: Verify**

Run: `cd web && bunx tsc --noEmit -p tsconfig.json` → grep the three files → no NEW errors.
Run: `cd web && bun run build` → succeeds.

- [ ] **Step 3: Commit**

```bash
git add web/src/components/studio/kv-generator/KvResizeTileStage.tsx web/src/components/studio/kv-generator/KvTileOverlayEditor.tsx web/src/components/studio/kv-generator/KvResizeCanvas.tsx
git commit -m "feat(web): render text gradient in resize + export stages"
```

---

### Task 7: Typography panel — Fill control + remove floating chips

**Files:**
- Modify: `src/components/studio/kv-generator/KvGeneratorLayout.tsx` (Text section, ~line 3375; `handleChangeTextColor` ~line 1999; `onChangeTextColor` prop passed to canvas ~line 3273)
- Modify: `src/components/studio/kv-generator/KvFabricCanvas.tsx` + `KvKonvaCanvas.tsx` — remove the floating `OverlayColorChip` render + `onChangeTextColor` handling
- Delete: `src/components/studio/kv-generator/overlays/OverlayColorChip.tsx` (after refs removed)

- [ ] **Step 1: Add the Fill control to the Text section**

Below the existing Size input (inside the `selectedOverlayForTransform?.type === "text"` Text block), add a **Fill** control:
- A **Solid | Gradient** toggle (two small buttons) reflecting `hasTextGradient(payload)`.
- *Solid*: one `<ColorField value={payload.color} onChange={(hex) => patch({ color: hex, gradient: undefined })} />`.
- *Gradient*: two `<ColorField>` (From = `payload.gradient?.from ?? payload.color`, To = `payload.gradient?.to ?? payload.color`) + an angle number input (0–360, default 90). Any change writes `patch({ gradient: { from, to, angle } })`. Switching the toggle to Gradient seeds `gradient` from the current color; switching to Solid writes `patch({ gradient: undefined })` (keep `color`).
- `patch(partial)` = `docUpdateOverlay(kvDoc, selectedOverlayForTransform.id, { payload: { ...selectedOverlayForTransform.payload, ...partial } })` (same pattern as the font-size input; preserves content/fontFamily/fontSize). Guard `payload.type === "text"`.

- [ ] **Step 2: Remove the floating color chip**

- In `KvFabricCanvas.tsx` and `KvKonvaCanvas.tsx`: remove the `OverlayColorChip` import + its render + the `onChangeTextColor`-driven color UI (the Konva `onChangeTextColor(overlay.id, color)` call site ~line 1405). Remove the now-unused `onChangeTextColor` prop from these components and from `KvCanvas.tsx`'s prop plumbing (~lines 172/277/654/734/805/937) and the `KvGeneratorLayout` pass-through (~line 3273).
- Keep `handleChangeTextColor` ONLY if still referenced; otherwise remove it. (Grep to confirm no references remain after the panel uses `patch` directly.)
- Delete `overlays/OverlayColorChip.tsx` once `grep -rn OverlayColorChip src/` returns nothing but the deletion.

- [ ] **Step 3: Verify**

Run: `cd web && bunx tsc --noEmit -p tsconfig.json` → grep `KvGeneratorLayout|KvFabricCanvas|KvKonvaCanvas|KvCanvas` → no NEW errors.
Run: `cd web && bun run build` → succeeds.
Grep: `grep -rn "OverlayColorChip\|onChangeTextColor" src/` → empty.

- [ ] **Step 4: Commit**

```bash
git add -A web/src/components/studio/kv-generator/
git commit -m "feat(web): consolidate text fill (solid/gradient) into typography panel; remove floating color chips"
```

---

### Task 8: Analytics + manual e2e

**Files:**
- Modify: `src/lib/analytics/kv-generator-events.ts` + the Fill control call sites.

- [ ] **Step 1: Analytics**

Per `frndos-analytics-events`, add (dot-namespaced, matching the module) `kv_generator.text_fill_changed` with `{ fill_type: "solid" | "gradient" }`, fired when the user changes fill/toggle. Use the existing `safeCapture` wrapper.

- [ ] **Step 2: Manual e2e (record in the track file)**

On the Fabric multi-board canvas AND the Konva fallback:
1. Add text → it hugs the content; type multi-line (Enter) → box grows.
2. Corner-drag → font scales, box follows, no runaway; no side handles.
3. Size input changes font size.
4. Solid color via ColorField; then Gradient (from/to + angle) → gradient renders; change angle → updates.
5. Reload → font, size, color, AND gradient persist.
6. Resize → download → exported PNG shows the gradient + font + size.

- [ ] **Step 3: Commit**

```bash
git add web/src/lib/analytics/kv-generator-events.ts web/src/components/studio/kv-generator/
git commit -m "feat(web): analytics for text fill changes"
```

---

## Self-Review

- **Spec coverage:** auto-fit box (Task 4 Fabric IText, Task 5 Konva hug) ✓; gradient payload (Task 1) ✓; fill helper (Task 2) ✓; render Fabric/Konva/resize+export (Tasks 4–6) ✓; consolidated panel + remove chips (Tasks 3, 7) ✓; analytics + e2e (Task 8) ✓. Persistence is the separate api plan.
- **Placeholders:** Tasks 3 and 7 delegate exact markup to `frndos-components-v2` with a precise structural + behavioral spec; all logic/helpers/types have complete code.
- **Type consistency:** `hasTextGradient` / `gradientLineCoords` / `konvaTextFill` / `fabricTextColorStops` names consistent across Tasks 2/4/5/6; `patch()` preserves full payload; `payload.gradient` shape identical to the api whitelist (api plan).
