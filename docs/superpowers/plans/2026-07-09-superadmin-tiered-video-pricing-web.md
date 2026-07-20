# Superadmin Tiered Video Pricing — Web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a superadmin enter **tiered** (dimension-priced) video pricing in the Add/Edit-model form, producing the structured `tiers` payload the API already accepts — replacing the current single flat `price_per_second` field for video models.

**Architecture:** The API side is done (commits `860286aa..b87eba31` on `feature/daffa/vc-video-dynamic-pricing`): `GET v1/admin/model-settings` now returns `video_pricing_shapes` (provider→allowed shape keys) and `video_pricing_shape_defs` (shape key→`{priced_on, values, type?}`), and `POST`/`PATCH` accept `pricing` as `{type:"per_second", priced_on:[...], tiers:[{dims,rate}]}` (tiered), `{type:"per_second", price_per_second}` (flat), or `{type:"fixed", fixed_price}`. The web adds: (1) a **pricing-shape dropdown** shown after Provider is chosen for a video model; (2) a **rate-editor** (dimension-value checkboxes + a $/s matrix + read-only fallback) for tiered/fixed shapes; (3) the structured `tiers` payload builder; (4) edit-mode prefill that decodes the stored `rates` map back into the editor. The API resolver and storage are unchanged.

**Tech Stack:** Next.js 16 App Router, React 19, TypeScript, TanStack Query v5, Tailwind, Bun. Form state is plain `useState` (no react-hook-form). frndos component library.

## Global Constraints

- **Target branch:** web work goes on `feature/daffa/vc-video-dynamic-pricing` (web), branched from `develop` — mirrors the api branch. The exploration map was taken from the current `feature/daffa/vc-studio-storyboard-video` checkout; before Task 1, confirm `AddModelModal.tsx` / `types/admin.ts` match on the `develop`-based branch (the `model_settings` feature is already on develop, so the form exists there). If line numbers below differ, re-locate by symbol name, not line.
- **No API change.** The web consumes the existing index payload and posts the structured `tiers` shape. If edit-prefill needs data the index doesn't return, decode it client-side — do NOT add an API field.
- **Structured payload, not built keys.** The form submits `tiers: [{dims:{...}, rate:number}]`; the API builds the `rates` keys (via `PricingHelper::videoRateKey`) and `fallback_per_second = max(rate)`. The web must NOT build `rates` keys or send `fallback_per_second`.
- **Dimension vocab is fixed** — only what `video_pricing_shape_defs` declares: `resolution` ∈ {480p,720p,1080p,4k}, `mode` ∈ {standard,pro,4k} (from `values`), plus the implicit boolean axes `video_in` (variants: reference-video `true` / `default` `false`) and `audio` (`true`/`false`). Never invent a dimension or value not present in the shape def.
- **Free model unchanged:** `is_free` still omits `pricing` entirely (both create and edit). The tiered editor only renders when `!isFree && modelType === "video"` and a non-flat shape is selected.
- **Flat stays the safe default.** Every provider's allowed shapes include `flat`; when `flat` is selected the UI is exactly today's single `price_per_second` input and the payload is `{type:"per_second", price_per_second}` (unchanged).
- **Client validation blocks submit** until every rendered rate cell is a number ≥ 0 (mirrors existing `pricingComplete`).
- **Test runner is `bun test`** (bunfig preloads jest-dom), NOT vitest. The real gate is `bun run build`. Do not run `bunx vitest`.

---

## File Structure

- **Modify** `web/src/types/admin.ts` — extend the pricing union + `AdminModelSettingsData` with the two shape-config fields + new shape-def types.
- **Create** `web/src/app/admin/models-settings/lib/videoPricing.ts` — pure helpers: build the tier grid from a shape def + selected values, build the `tiers` payload, decode a stored tiered `pricing` back into editor state, and validate completeness. (Keeps `AddModelModal.tsx` thin and makes the logic unit-testable without rendering.)
- **Create** `web/src/app/admin/models-settings/components/VideoPricingEditor.tsx` — the tiered rate-editor UI (shape dropdown + dimension-value checkboxes + rate matrix + read-only fallback).
- **Modify** `web/src/app/admin/models-settings/components/AddModelModal.tsx` — for video models, swap the flat pricing loop for `VideoPricingEditor` when a tiered/fixed shape is selected; wire `buildPricing`, validation, and edit prefill through the new helpers.
- **Modify** `web/src/app/admin/models-settings/page.tsx` and `.../components/ModelTypeSection.tsx` — thread `videoPricingShapes` + `videoPricingShapeDefs` from the query data down to `AddModelModal` (parallel to how `allowed_providers`/`providers` flows today).
- **Create** `web/src/app/admin/models-settings/lib/__tests__/videoPricing.test.ts` — unit tests for the pure helpers (build/decode round-trip, payload shape, completeness).

---

## Task 1: Types for shape configs + tiered/fixed pricing

**Files:**
- Modify: `web/src/types/admin.ts` (near `AdminVideoModelPricing` ~575-583 and `AdminModelSettingsData` ~462-467)
- Test: none (types only; compile-checked by later tasks + `bun run build`)

**Interfaces:**
- Produces (consumed by Tasks 2-5):
  - `VideoPricingShapeDef` = `{ priced_on: VideoPricingDimension[]; values: Partial<Record<VideoPricingDimension, string[]>>; type?: "fixed" }`
  - `VideoPricingDimension` = `"resolution" | "video_in" | "mode" | "audio"`
  - `AdminVideoTieredModelPricing` = `{ type: "per_second"; priced_on: VideoPricingDimension[]; tiers: VideoPricingTier[] }`
  - `VideoPricingTier` = `{ dims: Partial<Record<VideoPricingDimension, string | boolean>>; rate: number }`
  - `AdminVideoFixedModelPricing` = `{ type: "fixed"; fixed_price: number }`
  - `AdminModelSettingsData` gains `video_pricing_shapes: Record<string, string[]>` and `video_pricing_shape_defs: Record<string, VideoPricingShapeDef>`

- [ ] **Step 1: Add the dimension + shape-def + tier types**

Add near the other admin model types (e.g. just above `AdminVideoModelPricing`, ~line 575):

```ts
/** The four dimension axes video pricing can key on (matches ai-service + PricingHelper). */
export type VideoPricingDimension = "resolution" | "video_in" | "mode" | "audio";

/** One dimension-combo → rate row the form submits (API builds the rates map + fallback). */
export interface VideoPricingTier {
  /** e.g. { resolution: "1080p", video_in: true } — keys are a subset of the shape's priced_on. */
  dims: Partial<Record<VideoPricingDimension, string | boolean>>;
  rate: number;
}

/** A pricing shape the API offers for a provider (from video_pricing_shape_defs). */
export interface VideoPricingShapeDef {
  /** Dimensions this shape prices on; empty for flat/fixed. */
  priced_on: VideoPricingDimension[];
  /** Selectable literal values per non-boolean dimension (resolution, mode). */
  values: Partial<Record<VideoPricingDimension, string[]>>;
  /** Present only on the "fixed" shape. */
  type?: "fixed";
}
```

- [ ] **Step 2: Extend the video pricing union**

Replace the `AdminModelSettingPricing` union (~580-583) so it admits tiered + fixed video shapes. Keep `AdminVideoModelPricing` (flat `per_second`) as-is:

```ts
/** Video pricing — tiered per-second, keyed on dimensions; API builds rates + fallback. */
export interface AdminVideoTieredModelPricing {
  type: "per_second";
  priced_on: VideoPricingDimension[];
  tiers: VideoPricingTier[];
}

/** Video pricing — a single fixed price per generation (no duration factor). */
export interface AdminVideoFixedModelPricing {
  type: "fixed";
  fixed_price: number;
}

export type AdminModelSettingPricing =
  | AdminChatModelPricing
  | AdminImageModelPricing
  | AdminVideoModelPricing
  | AdminVideoTieredModelPricing
  | AdminVideoFixedModelPricing;
```

- [ ] **Step 3: Add the two shape-config fields to the index payload type**

In `AdminModelSettingsData` (~462-467) add:

```ts
export interface AdminModelSettingsData {
  chat: AdminModelSetting[];
  image: AdminModelSetting[];
  video: AdminModelSetting[];
  allowed_providers: Record<AdminModelType, string[]>;
  /** provider → allowed pricing-shape keys (e.g. { bytedance: ["flat","resolution_video_in"] }). */
  video_pricing_shapes: Record<string, string[]>;
  /** shape key → def (priced_on + selectable values + optional type:"fixed"). */
  video_pricing_shape_defs: Record<string, VideoPricingShapeDef>;
}
```

- [ ] **Step 4: Typecheck**

Run: `cd web && bunx tsc --noEmit` (or `bun run build` if tsc isn't wired standalone)
Expected: no new type errors from `admin.ts`. (Downstream files still compile — the union only widens.)

- [ ] **Step 5: Commit**

```bash
git add web/src/types/admin.ts
git commit -m "feat(web): types for tiered/fixed video pricing + shape configs"
```

---

## Task 2: Thread shape configs from query data into the form

**Files:**
- Modify: `web/src/app/admin/models-settings/page.tsx` (destructures `data` ~24-47)
- Modify: `web/src/app/admin/models-settings/components/ModelTypeSection.tsx` (passes props to `AddModelModal`)
- Modify: `web/src/app/admin/models-settings/components/AddModelModal.tsx` (accept new props; no UI yet)
- Test: none (prop plumbing; verified by build)

**Interfaces:**
- Consumes: `AdminModelSettingsData.video_pricing_shapes`, `.video_pricing_shape_defs` (Task 1)
- Produces: `AddModelModal` receives props `videoPricingShapes: Record<string,string[]>` and `videoPricingShapeDefs: Record<string, VideoPricingShapeDef>` (used in Task 4)

- [ ] **Step 1: Read the two fields from query data in `page.tsx`**

Where `data.allowed_providers` is currently destructured/threaded, also pull `data.video_pricing_shapes` and `data.video_pricing_shape_defs` (default to `{}` when loading). Pass both into each `ModelTypeSection` (they're only used by the video section, but pass uniformly — harmless for chat/image and avoids a special-case prop path).

```tsx
const videoPricingShapes = data?.video_pricing_shapes ?? {};
const videoPricingShapeDefs = data?.video_pricing_shape_defs ?? {};
// ...pass videoPricingShapes={videoPricingShapes} videoPricingShapeDefs={videoPricingShapeDefs} to each <ModelTypeSection/>
```

- [ ] **Step 2: Forward through `ModelTypeSection`**

Add the two props to `ModelTypeSection`'s props type and forward them into both the create and edit `AddModelModal` instances (the ones at `AddModelModal.tsx:307-312` / `318-325` mount sites).

- [ ] **Step 3: Accept the props in `AddModelModal`**

Add to `AddModelModalProps`: `videoPricingShapes: Record<string, string[]>;` and `videoPricingShapeDefs: Record<string, VideoPricingShapeDef>;`. Import the type from `@/types/admin`. Don't use them yet.

- [ ] **Step 4: Build**

Run: `cd web && bun run build`
Expected: compiles; no unused-var error (props are declared in the signature — referencing them lands in Task 4; if the linter flags unused, prefix with `void` usage or proceed to Task 4 in the same branch — note it, don't add throwaway code).

- [ ] **Step 5: Commit**

```bash
git add web/src/app/admin/models-settings/page.tsx web/src/app/admin/models-settings/components/ModelTypeSection.tsx web/src/app/admin/models-settings/components/AddModelModal.tsx
git commit -m "feat(web): thread video pricing shape configs into Add-model form"
```

---

## Task 3: Pure video-pricing helpers (grid, payload, decode, validate)

**Files:**
- Create: `web/src/app/admin/models-settings/lib/videoPricing.ts`
- Test: `web/src/app/admin/models-settings/lib/__tests__/videoPricing.test.ts`

**Interfaces:**
- Consumes: `VideoPricingShapeDef`, `VideoPricingTier`, `AdminModelSettingPricing`, `VideoPricingDimension` (Task 1)
- Produces (consumed by Tasks 4-5):
  - `booleanAxes: VideoPricingDimension[]` = `["video_in", "audio"]`
  - `buildTierRows(shapeKey: string, def: VideoPricingShapeDef, selectedValues: Record<string,string[]>): TierRow[]` where `TierRow = { key: string; dims: Record<VideoPricingDimension, string|boolean>; label: string }` — the ordered grid cells to render; `key` is a stable client id (join of dim tokens), NOT the API rates key.
  - `buildVideoPricingPayload(shapeKey, def, selectedValues, rates: Record<string,string>): AdminModelSettingPricing` — returns flat/fixed/tiered shape for submit.
  - `decodeVideoPricing(pricing: AdminModelSettingPricing): { shapeKey: string; selectedValues: Record<string,string[]>; rates: Record<string,string> } | null` — reverse of build, for edit prefill; `null` for flat/unknown (caller falls back to flat editor).
  - `isVideoPricingComplete(shapeKey, def, selectedValues, rates): boolean`

- [ ] **Step 1: Write the failing tests**

```ts
import { describe, it, expect } from "bun:test";
import {
  buildTierRows, buildVideoPricingPayload, decodeVideoPricing, isVideoPricingComplete,
} from "../videoPricing";
import type { VideoPricingShapeDef } from "@/types/admin";

const bytedanceRVI: VideoPricingShapeDef = {
  priced_on: ["resolution", "video_in"],
  values: { resolution: ["480p", "720p", "1080p", "4k"] },
};
const googleRes: VideoPricingShapeDef = {
  priced_on: ["resolution"],
  values: { resolution: ["480p", "720p", "1080p", "4k"] },
};
const tencentFixed: VideoPricingShapeDef = { priced_on: [], values: {}, type: "fixed" };

describe("buildTierRows", () => {
  it("resolution × video_in → one row per (resolution, boolean) combo", () => {
    const rows = buildTierRows("resolution_video_in", bytedanceRVI, { resolution: ["720p", "1080p"] });
    // 2 resolutions × 2 video_in variants = 4 rows
    expect(rows).toHaveLength(4);
    expect(rows.map((r) => r.dims)).toEqual([
      { resolution: "720p", video_in: true },
      { resolution: "720p", video_in: false },
      { resolution: "1080p", video_in: true },
      { resolution: "1080p", video_in: false },
    ]);
  });

  it("resolution-only shape → one row per resolution, no boolean axis", () => {
    const rows = buildTierRows("resolution", googleRes, { resolution: ["1080p"] });
    expect(rows).toHaveLength(1);
    expect(rows[0].dims).toEqual({ resolution: "1080p" });
  });
});

describe("buildVideoPricingPayload", () => {
  it("tiered → structured tiers, no rates map, no fallback", () => {
    const rows = buildTierRows("resolution_video_in", bytedanceRVI, { resolution: ["1080p"] });
    const rates = { [rows[0].key]: "0.60", [rows[1].key]: "0.50" };
    const payload = buildVideoPricingPayload("resolution_video_in", bytedanceRVI, { resolution: ["1080p"] }, rates);
    expect(payload).toEqual({
      type: "per_second",
      priced_on: ["resolution", "video_in"],
      tiers: [
        { dims: { resolution: "1080p", video_in: true }, rate: 0.6 },
        { dims: { resolution: "1080p", video_in: false }, rate: 0.5 },
      ],
    });
    expect("rates" in payload).toBe(false);
    expect("fallback_per_second" in payload).toBe(false);
  });

  it("fixed → { type: fixed, fixed_price }", () => {
    const payload = buildVideoPricingPayload("fixed", tencentFixed, {}, { fixed: "0.25" });
    expect(payload).toEqual({ type: "fixed", fixed_price: 0.25 });
  });
});

describe("decodeVideoPricing round-trips a tiered payload", () => {
  it("stored priced_on + tiers decodes back to the same editor state", () => {
    const built = buildVideoPricingPayload(
      "resolution_video_in", bytedanceRVI, { resolution: ["720p", "1080p"] },
      Object.fromEntries(
        buildTierRows("resolution_video_in", bytedanceRVI, { resolution: ["720p", "1080p"] })
          .map((r, i) => [r.key, String((i + 1) / 10)]),
      ),
    );
    const decoded = decodeVideoPricing(built);
    expect(decoded).not.toBeNull();
    expect(decoded!.shapeKey).toBe("resolution_video_in");
    expect(decoded!.selectedValues.resolution.sort()).toEqual(["1080p", "720p"]);
  });

  it("flat pricing → null (caller uses flat editor)", () => {
    expect(decodeVideoPricing({ type: "per_second", price_per_second: 0.3 })).toBeNull();
  });
});

describe("isVideoPricingComplete", () => {
  it("false when any rendered cell is blank; true when all filled ≥ 0", () => {
    const sel = { resolution: ["720p"] };
    const rows = buildTierRows("resolution_video_in", bytedanceRVI, sel);
    const partial = { [rows[0].key]: "0.2" };
    expect(isVideoPricingComplete("resolution_video_in", bytedanceRVI, sel, partial)).toBe(false);
    const full = { [rows[0].key]: "0.2", [rows[1].key]: "0.1" };
    expect(isVideoPricingComplete("resolution_video_in", bytedanceRVI, sel, full)).toBe(true);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd web && bun test src/app/admin/models-settings/lib/__tests__/videoPricing.test.ts`
Expected: FAIL — module `../videoPricing` not found.

- [ ] **Step 3: Implement `videoPricing.ts`**

Key rules the implementation must honor:
- **Client cell key** (`TierRow.key`): join the dim tokens with `|` in `priced_on` order, using the SAME token mapping the API's `videoRateKey` uses so decode is symmetric on the web side — resolution/mode → the literal value; `video_in` → `"video_in"`/`"default"`; `audio` → `"audio"`/`"default"`. (This is a client convenience key for the rates state map; the API still rebuilds its own keys from the submitted `tiers`.)
- **Boolean axes** expand to two rows each: `video_in` → `true` then `false`; `audio` → `true` then `false`. Row order: iterate selected literal values in the order they appear in `def.values[dim]`, and within each, the boolean variants in the `true, false` order shown above. For a shape whose `priced_on` has no boolean axis (e.g. `resolution`), one row per literal value.
- **`buildVideoPricingPayload`**: `flat` shape (empty `priced_on`, no `type:"fixed"`) → `{ type:"per_second", price_per_second: Number(rates.price_per_second) }`. `fixed` → `{ type:"fixed", fixed_price: Number(rates.fixed) }`. Tiered → `{ type:"per_second", priced_on: def.priced_on, tiers: rows.map(r => ({ dims: r.dims, rate: Number(rates[r.key]) })) }`. Never emit `rates`/`fallback_per_second`.
- **`decodeVideoPricing`**: only tiered (`priced_on` non-empty) and fixed decode; flat returns `null`. For tiered, read `pricing.priced_on` + `pricing.tiers`; reconstruct `selectedValues` from the distinct literal-dim values across tiers, and `rates` keyed by the same client `key` derived from each tier's `dims`. Infer `shapeKey` by matching `priced_on` against the shape defs — accept it as a param instead if simpler: signature may be `decodeVideoPricing(pricing, shapeDefs: Record<string,VideoPricingShapeDef>)`; pick ONE and reflect it in the Task 4 caller. (The tests above call the single-arg form; if you add the `shapeDefs` param, update the test calls in the same commit.)
- **`isVideoPricingComplete`**: for flat → `rates.price_per_second` parses to a number ≥ 0; fixed → `rates.fixed` ≥ 0; tiered → every `buildTierRows(...).key` present in `rates` and each parses to ≥ 0.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd web && bun test src/app/admin/models-settings/lib/__tests__/videoPricing.test.ts`
Expected: PASS (all cases). If you changed `decodeVideoPricing`'s signature, the edited tests pass too.

- [ ] **Step 5: Commit**

```bash
git add web/src/app/admin/models-settings/lib/videoPricing.ts web/src/app/admin/models-settings/lib/__tests__/videoPricing.test.ts
git commit -m "feat(web): pure helpers for tiered video pricing grid/payload/decode"
```

---

## Task 4: `VideoPricingEditor` component

**Files:**
- Create: `web/src/app/admin/models-settings/components/VideoPricingEditor.tsx`
- Test: none (thin presentational wrapper over Task 3 helpers; logic already tested; verified via build + manual)

**Interfaces:**
- Consumes: Task 3 helpers; `VideoPricingShapeDef` (Task 1); frndos `SearchableSelectOption`, `CheckboxList`, `Input`, `Label`.
- Produces: a controlled component
  ```tsx
  interface VideoPricingEditorProps {
    allowedShapeKeys: string[];                        // videoPricingShapes[provider]
    shapeDefs: Record<string, VideoPricingShapeDef>;   // videoPricingShapeDefs
    shapeKey: string;                                   // controlled
    onShapeKeyChange: (k: string) => void;
    selectedValues: Record<string, string[]>;           // controlled (e.g. { resolution: ["1080p"] })
    onSelectedValuesChange: (v: Record<string, string[]>) => void;
    rates: Record<string, string>;                      // controlled (cellKey → raw string)
    onRatesChange: (r: Record<string, string>) => void;
  }
  ```

- [ ] **Step 1: Render the shape dropdown**

`SearchableSelectOption` (matches the provider-select pattern, `showSearch={false}`) populated from `allowedShapeKeys` mapped to human labels: `flat`→"Flat (per second)", `fixed`→"Fixed price", `resolution`→"By resolution", `resolution_video_in`→"By resolution × reference-video", `mode_audio`→"By mode × audio". Selecting a shape calls `onShapeKeyChange`. When the shape has no tiers (`flat`/`fixed`), skip the checkbox + matrix and render a single `Input` (Task 4 Step 4).

- [ ] **Step 2: Render dimension-value checkboxes**

For each non-boolean dim in `shapeDefs[shapeKey].priced_on` that has `values` (i.e. `resolution` or `mode`), render a `CheckboxList` of its `values[dim]` options. Checking/unchecking updates `onSelectedValuesChange` for that dim. (Boolean axes `video_in`/`audio` are implicit — no checkboxes; they always expand to both variants.)

- [ ] **Step 3: Render the rate matrix**

Call `buildTierRows(shapeKey, def, selectedValues)`; render each row as a labelled `Input type="number" min={0} step="0.0001"` bound to `rates[row.key]`, updating via `onRatesChange`. Use `row.label` for the row caption (e.g. "1080p · reference video", "1080p · no reference"). Group visually by literal value when a boolean axis is present (two inputs per resolution). Below the matrix show a **read-only** `Input` (disabled) captioned "Fallback (auto = highest rate)" whose value is `max` of the entered numeric rates — computed client-side for display only; it is NOT submitted.

- [ ] **Step 4: Flat/fixed single-field mode**

When `shapeKey === "flat"`: one `Input` bound to `rates.price_per_second` (label "Price (USD per second)"). When `shapeKey === "fixed"`: one `Input` bound to `rates.fixed` (label "Fixed price (USD per generation)"). No checkboxes, no matrix, no fallback line.

- [ ] **Step 5: Build**

Run: `cd web && bun run build`
Expected: compiles, no type errors.

- [ ] **Step 6: Commit**

```bash
git add web/src/app/admin/models-settings/components/VideoPricingEditor.tsx
git commit -m "feat(web): VideoPricingEditor — shape dropdown + tiered rate matrix"
```

---

## Task 5: Wire the editor into `AddModelModal` (state, payload, validation, prefill)

**Files:**
- Modify: `web/src/app/admin/models-settings/components/AddModelModal.tsx`
- Test: none new (payload logic covered by Task 3; wiring verified via build + manual e2e)

**Interfaces:**
- Consumes: `VideoPricingEditor` (Task 4), Task 3 helpers, props from Task 2.

- [ ] **Step 1: Add editor state (video only)**

Alongside the existing `pricing` state, add `useState` for `videoShapeKey: string` (default `"flat"`), `videoSelectedValues: Record<string,string[]>` (default `{}`), and reuse the existing `pricing` object as the `rates` map for the editor cells (or a dedicated `videoRates` state — pick one and be consistent). Only used when `modelType === "video"`.

- [ ] **Step 2: Swap the video pricing UI**

In the pricing render block (currently the generic `pricingFields.map` at ~389-412), branch: when `modelType === "video" && !isFree`, render `<VideoPricingEditor .../>` fed by `videoPricingShapes[provider] ?? ["flat"]`, `videoPricingShapeDefs`, and the editor state. For `chat`/`image` keep the existing loop untouched. (When `provider` is empty, pass `["flat"]` so the editor still renders a flat field.)

- [ ] **Step 3: Build the payload from the editor**

In `buildPricing()` (~216-229), for the video branch return `buildVideoPricingPayload(videoShapeKey, videoPricingShapeDefs[videoShapeKey], videoSelectedValues, rates)` instead of the hardcoded `{ type:"per_second", price_per_second }`. Chat/image branches unchanged. (Flat shape still yields `{type:"per_second", price_per_second}` — identical wire output to today.)

- [ ] **Step 4: Extend completeness validation**

In `pricingComplete` (~202), when `modelType === "video"` use `isVideoPricingComplete(videoShapeKey, videoPricingShapeDefs[videoShapeKey], videoSelectedValues, rates)`; otherwise keep the existing per-field check. Submit stays disabled until true (and `isFree` still bypasses pricing entirely).

- [ ] **Step 5: Edit-mode prefill**

In the edit-init path (where `toPricingState()` seeds state from `initialModel.pricing` ~82-98), when `modelType === "video"` and `initialModel.pricing` is tiered/fixed, call `decodeVideoPricing(initialModel.pricing, videoPricingShapeDefs)` and seed `videoShapeKey` / `videoSelectedValues` / `rates` from the result; when it returns `null` (flat) fall back to seeding the flat `price_per_second` field and `videoShapeKey="flat"`. Guard: if the decoded `shapeKey` isn't in the provider's allowed list (provider changed upstream), still show it (read-only edit) rather than dropping data — do not silently reset to flat.

- [ ] **Step 6: Build + lint**

Run: `cd web && bun run build`
Expected: compiles. Manually confirm no unused props remain from Task 2.

- [ ] **Step 7: Commit**

```bash
git add web/src/app/admin/models-settings/components/AddModelModal.tsx
git commit -m "feat(web): tiered video pricing in Add/Edit-model form (payload, validation, prefill)"
```

---

## Manual verification (post-implementation, not a task gate)

Runtime e2e once services run (Feature-suite-blocked API means this is the real proof):
1. As superadmin, open Model Settings → video → Add model. Pick provider `bytedance` → shape dropdown offers `Flat` + `By resolution × reference-video`.
2. Select the tiered shape, check resolutions `720p`+`1080p` → matrix shows 4 rate inputs; fill them; fallback shows the max.
3. Submit → inspect `model_settings.pricing` row: `{type:"per_second", priced_on:["resolution","video_in"], rates:{"720p|video_in":...,"720p|default":...,"1080p|video_in":...,"1080p|default":...}, fallback_per_second:<max>}`.
4. Re-open the model for edit → matrix repopulates with the same values/rates (decode round-trip).
5. Switch shape to `Flat`, enter one price, submit → stored `{type:"per_second", price_per_second}`.
6. Provider `tencent` → offers `Fixed`; submit → `{type:"fixed", fixed_price}`.

## Out of scope (YAGNI)

- No new API fields (decode is client-side from the stored `pricing`).
- No new dimensions/values beyond what `video_pricing_shape_defs` declares.
- No changes to chat/image pricing UI.
- No resolver/pricing-math on the web — the API owns rate-key building, fallback, and all cost math.
