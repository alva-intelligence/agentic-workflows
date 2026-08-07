# KV Upscale Fidelity — web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 1.5×/2× download rows with 2K/4K, show what each costs before it is clicked, and gate 4K behind a confirmation.

**Architecture:** Both download dropdowns already drive off one shared type, so the swap lands on the generation and resize-tile surfaces together. Credit estimates are computed client-side because `kv_generations` stores no dimensions — only the browser knows the source size. The 4K dialog blocks rather than warns: `useEffectiveCredits().canSpend()` stops a job the workspace cannot pay for, which today would still run and still cost us a Replicate call.

**Tech Stack:** Next.js 16, React 19, TypeScript, Tailwind, TanStack Query, Bun.

## Prerequisites

- **Depends on:** `2026-08-07-kv-upscale-fidelity-api.md` for the `target` request field and the `target` resource field.

## Global Constraints

- **Targets are `2k` and `4k`.** Long edge 2048 / 4096, aspect preserved.
- **Estimates: ~20 credits for 2K, ~83 for 4K**, and **Free** when the source long edge already meets the target.
- **The estimate logic is duplicated from Python.** One file, a comment naming `plan_upscale` as source of truth, and tests pinning exact values so drift fails loudly. This repo has already been bitten by the same logic drifting across renderers.
- **4K confirms; 2K does not.** Friction on a 20-credit export costs more than it saves.
- **No "don't ask again"** — it would hide the signal the guardrail exists to collect.
- Run tests with `bun test`, not `bunx vitest`. The real gate is `bun run build`, not `tsc`.
- Use existing `@/components/frndos/` components; do not hand-roll a modal.

## Spec

`docs/superpowers/specs/2026-08-07-kv-upscale-fidelity-and-resolution-targets-design.md` § web

## File Structure

| File | Responsibility |
|---|---|
| `src/types/kv/upscale.ts` | `UpscaleTarget`, `UPSCALE_TARGETS`, resource shape. |
| `src/lib/studio/kv/upscaleEstimate.ts` | **New.** Target maths + credit estimate. The only home for this logic. |
| `src/lib/studio/kv/useUpscales.ts` | Request by target. |
| `src/components/studio/kv-generator/KvDownloadDropdown.tsx` | Rows, estimates, 4K dialog trigger. |
| `src/components/studio/kv-generator/KvTileDownloadDropdown.tsx` | Same, tile flow. |
| `src/components/studio/kv-generator/KvUpscaleConfirmModal.tsx` | **New.** 4K confirmation. |
| `src/lib/studio/kv/upscaleEstimate.test.ts` | Pinned values. |

---

### Task 1: Estimate helper

Pure functions, no React. Everything else depends on this.

**Files:**
- Modify: `src/types/kv/upscale.ts` — the `UpscaleTarget` type only
- Create: `src/lib/studio/kv/upscaleEstimate.ts`
- Test: `src/lib/studio/kv/upscaleEstimate.test.ts`

**Interfaces:**
- Produces:
  - `UpscaleTarget = "2k" | "4k"` (the helper imports it, so it lands here;
    Task 2 does the rest of the type swap)
  - `TARGET_LONG_EDGE: Record<UpscaleTarget, number>`
  - `selectScaleFactor(w: number, h: number, target: UpscaleTarget): number | null`
  - `finalSize(w: number, h: number, target: UpscaleTarget): { width: number; height: number }`
  - `estimateUpscaleCredits(w: number, h: number, target: UpscaleTarget): number | null` — `null` means free.

- [ ] **Step 1: Write the failing test**

Create `src/lib/studio/kv/upscaleEstimate.test.ts`:

```ts
import { describe, expect, it } from "bun:test";
import {
  estimateUpscaleCredits,
  finalSize,
  selectScaleFactor,
} from "@/lib/studio/kv/upscaleEstimate";

/**
 * These values are pinned against the Python `plan_upscale` in
 * ai-service/app/tools/upscale_image.py. If that changes and this does not,
 * these fail — which is the point.
 */
describe("selectScaleFactor", () => {
  it("picks the smallest sufficient factor", () => {
    expect(selectScaleFactor(1088, 1376, "2k")).toBe(2);
    expect(selectScaleFactor(1088, 1376, "4k")).toBe(4);
    expect(selectScaleFactor(2400, 3000, "4k")).toBe(2);
  });

  it("returns null when the source already meets the target", () => {
    expect(selectScaleFactor(2048, 1200, "2k")).toBeNull();
    expect(selectScaleFactor(3000, 2000, "2k")).toBeNull();
  });

  it("ignores orientation", () => {
    expect(selectScaleFactor(1024, 1536, "4k")).toBe(
      selectScaleFactor(1536, 1024, "4k")
    );
  });
});

describe("finalSize", () => {
  it("lands the long edge exactly and preserves aspect", () => {
    expect(finalSize(1024, 1536, "4k")).toEqual({ width: 2731, height: 4096 });
    expect(finalSize(1536, 1024, "2k")).toEqual({ width: 2048, height: 1365 });
  });
});

describe("estimateUpscaleCredits", () => {
  it("estimates ~20 credits at 2K across real KV sizes", () => {
    expect(estimateUpscaleCredits(1088, 1376, "2k")).toBe(20);
    expect(estimateUpscaleCredits(1254, 1254, "2k")).toBe(21);
    expect(estimateUpscaleCredits(1504, 992, "2k")).toBe(20);
  });

  it("estimates ~83 credits at 4K across real KV sizes", () => {
    expect(estimateUpscaleCredits(1088, 1376, "4k")).toBe(79);
    expect(estimateUpscaleCredits(1254, 1254, "4k")).toBe(83);
    expect(estimateUpscaleCredits(1504, 992, "4k")).toBe(79);
  });

  it("returns null (free) when no upscale is needed", () => {
    expect(estimateUpscaleCredits(3000, 2000, "2k")).toBeNull();
  });

  it("charges roughly 4x more for 4K than 2K", () => {
    const twoK = estimateUpscaleCredits(1254, 1254, "2k")!;
    const fourK = estimateUpscaleCredits(1254, 1254, "4k")!;
    expect(fourK / twoK).toBeGreaterThan(3.5);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/lib/studio/kv/upscaleEstimate.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3a: Add the target type**

The helper imports it, so it has to exist first. In `src/types/kv/upscale.ts`,
alongside the existing `UpscaleFactor` (which Task 2 removes):

```ts
/** Allowed upscale targets, measured on the image's LONG edge:
 *  2K = 2048px, 4K = 4096px. */
export type UpscaleTarget = "2k" | "4k";
```

- [ ] **Step 3b: Implement the helper**

Create `src/lib/studio/kv/upscaleEstimate.ts`:

```ts
import type { UpscaleTarget } from "@/types/kv/upscale";

/**
 * Client-side mirror of `plan_upscale` in
 * ai-service/app/tools/upscale_image.py — THAT is the source of truth.
 *
 * It is duplicated here because `kv_generations` stores no width/height, so
 * only the browser knows the source size, and the estimate has to render
 * before any request is made. `upscaleEstimate.test.ts` pins the values; if
 * the Python changes and this does not, those tests fail.
 */

/** Targets are measured on the LONG edge, so portrait, square and landscape
 *  KVs all land on a predictable number. */
export const TARGET_LONG_EDGE: Record<UpscaleTarget, number> = {
  "2k": 2048,
  "4k": 4096,
};

/** clarity-pro's scale_factor is an enum, not a free float. */
const SCALE_FACTORS = [2, 4, 8, 16] as const;

/** $0.03 per output megapixel x 1.1 markup, at 1 credit = $0.01. Mirrors
 *  PricingHelper::UPSCALE_PRICE_PER_MEGAPIXEL and credits.upscale_multiplier. */
const PRICE_PER_MEGAPIXEL = 0.03;
const MULTIPLIER = 1.1;
const DOLLARS_PER_CREDIT = 0.01;

export function selectScaleFactor(
  width: number,
  height: number,
  target: UpscaleTarget
): number | null {
  const want = TARGET_LONG_EDGE[target];
  const longEdge = Math.max(width, height);
  // Already big enough — no model run, no spend.
  if (longEdge >= want) return null;
  return SCALE_FACTORS.find((sf) => longEdge * sf >= want) ?? 16;
}

export function finalSize(
  width: number,
  height: number,
  target: UpscaleTarget
): { width: number; height: number } {
  const longEdge = TARGET_LONG_EDGE[target];
  return width >= height
    ? { width: longEdge, height: Math.max(1, Math.round((height * longEdge) / width)) }
    : { width: Math.max(1, Math.round((width * longEdge) / height)), height: longEdge };
}

/** Estimated credits, or null when the export is free. */
export function estimateUpscaleCredits(
  width: number,
  height: number,
  target: UpscaleTarget
): number | null {
  const sf = selectScaleFactor(width, height, target);
  if (sf === null) return null;

  // Replicate bills the MODEL's output, which is larger than what we deliver
  // after downscaling to the exact target.
  const megapixels = (width * sf * (height * sf)) / 1_000_000;
  const dollars = megapixels * PRICE_PER_MEGAPIXEL * MULTIPLIER;
  return Math.ceil(dollars / DOLLARS_PER_CREDIT);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test src/lib/studio/kv/upscaleEstimate.test.ts`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add src/lib/studio/kv/upscaleEstimate.ts src/lib/studio/kv/upscaleEstimate.test.ts
git commit -m "feat(web): add client-side upscale target and credit estimate helper"
```

---

### Task 2: Swap the types

**Files:**
- Modify: `src/types/kv/upscale.ts`
- Modify: `src/lib/studio/kv/useUpscales.ts`

**Interfaces:**
- Produces: `UpscaleTarget = "2k" | "4k"`, `UPSCALE_TARGETS`, `KvGenerationUpscale.target`.

- [ ] **Step 1: Finish the type swap**

`UpscaleTarget` already exists from Task 1. Delete `UpscaleFactor` and
`UPSCALE_FACTORS`, and add:

```ts
/** Tuple form for iteration order in the dropdown. */
export const UPSCALE_TARGETS: readonly UpscaleTarget[] = ["2k", "4k"] as const;

/** Display labels. */
export const UPSCALE_TARGET_LABEL: Record<UpscaleTarget, string> = {
  "2k": "2K",
  "4k": "4K",
};
```

On `KvGenerationUpscale`, replace `factor: UpscaleFactor` with
`target: UpscaleTarget`.

- [ ] **Step 2: Update the request hook**

In `useUpscales.ts`, change `request(factor)` to `request(target)` and send
`{ target }` in the POST body. Key the returned map by target.

- [ ] **Step 3: Find every remaining consumer**

Run: `grep -rn "UpscaleFactor\|UPSCALE_FACTORS\|\.factor" src/ | grep -i upscale`
Expected: no output when done.

- [ ] **Step 4: Verify the build type-checks**

Run: `bun run build`
Expected: success. `bun run build` is the real gate here — it catches what
`tsc` alone does not.

- [ ] **Step 5: Commit**

```bash
git add src/types/kv/upscale.ts src/lib/studio/kv/
git commit -m "feat(web): replace upscale factors with 2k/4k targets"
```

---

### Task 3: The 4K confirmation modal

**Files:**
- Create: `src/components/studio/kv-generator/KvUpscaleConfirmModal.tsx`
- Test: `src/components/studio/kv-generator/KvUpscaleConfirmModal.test.tsx`

**Interfaces:**
- Consumes: `estimateUpscaleCredits`, `finalSize` (Task 1); `useEffectiveCredits` (existing).
- Produces:
  ```ts
  type Props = {
    open: boolean;
    target: UpscaleTarget;
    sourceWidth: number;
    sourceHeight: number;
    onConfirm: () => void;
    onCancel: () => void;
  };
  ```

- [ ] **Step 1: Write the failing test**

```tsx
import { describe, expect, it, mock } from "bun:test";
import { render, within } from "@testing-library/react";
import { KvUpscaleConfirmModal } from "./KvUpscaleConfirmModal";

// RTL's `screen` is broken under bun — use within(document.body).
const screen = () => within(document.body);

describe("KvUpscaleConfirmModal", () => {
  it("states the cost and the output size", () => {
    render(
      <KvUpscaleConfirmModal
        open
        target="4k"
        sourceWidth={1254}
        sourceHeight={1254}
        onConfirm={() => {}}
        onCancel={() => {}}
      />
    );

    expect(screen().getByText(/83 credits/)).toBeInTheDocument();
    expect(screen().getByText(/4096/)).toBeInTheDocument();
  });

  it("calls onConfirm when confirmed", () => {
    const onConfirm = mock(() => {});
    render(
      <KvUpscaleConfirmModal
        open
        target="4k"
        sourceWidth={1254}
        sourceHeight={1254}
        onConfirm={onConfirm}
        onCancel={() => {}}
      />
    );

    screen().getByRole("button", { name: /upscale/i }).click();
    expect(onConfirm).toHaveBeenCalledTimes(1);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/components/studio/kv-generator/KvUpscaleConfirmModal.test.tsx`
Expected: FAIL — module not found.

- [ ] **Step 3: Build the modal**

Wrap `BaseModal` from `@/components/frndos/BaseModal` and `Button` from
`@/components/frndos/Button`. It must:

- show target, `finalSize()` dimensions, the estimate, and `mainCredits`
- give `Cancel` initial focus
- disable confirm when `canSpend(estimate)` is false, with an
  insufficient-credit message in place of the cost line
- carry **no** "don't ask again" control

```tsx
const estimate = estimateUpscaleCredits(sourceWidth, sourceHeight, target);
const size = finalSize(sourceWidth, sourceHeight, target);
const { mainCredits, canSpend } = useEffectiveCredits();
const affordable = estimate === null || canSpend(estimate);
```

Guard: if `estimate === null` the caller should never have opened this — render
nothing rather than a "0 credits" dialog.

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test src/components/studio/kv-generator/KvUpscaleConfirmModal.test.tsx`
Expected: PASS.

> If every component test in the repo fails at once, that is the known
> RTL-under-bun `screen` bug, not your change. Use `within(document.body)`.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/KvUpscaleConfirmModal.tsx src/components/studio/kv-generator/KvUpscaleConfirmModal.test.tsx
git commit -m "feat(web): add 4K upscale confirmation modal"
```

---

### Task 4: Wire both dropdowns

**Files:**
- Modify: `src/components/studio/kv-generator/KvDownloadDropdown.tsx`
- Modify: `src/components/studio/kv-generator/KvTileDownloadDropdown.tsx`

**Interfaces:**
- Consumes: everything from Tasks 1–3.

- [ ] **Step 1: Render targets with estimates**

Replace the `UPSCALE_FACTORS.map(...)` block with `UPSCALE_TARGETS.map(...)`,
building each row's label from the target, its `finalSize()`, and its estimate:

```
2K · 2048×1638   ~20 credits
4K · 4096×3277   ~83 credits
```

When `estimateUpscaleCredits` returns `null`, render **Free** in place of the
estimate. That is not a cosmetic nicety — it steers people to variants that
cost nothing.

Source dimensions come from the generation's rendered image
(`naturalWidth` / `naturalHeight`).

- [ ] **Step 2: Gate 4K behind the modal**

`handleStart(target)` opens the modal when `target === "4k"` **and** the
estimate is non-null. 2K and Free rows start immediately.

- [ ] **Step 3: Apply the same to the tile dropdown**

- [ ] **Step 4: Verify the build**

Run: `bun run build`
Expected: success.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/
git commit -m "feat(web): show credit estimates and confirm 4K in the download panel"
```

---

### Task 5: Analytics

**Files:**
- Modify: both dropdowns and the modal

Per the standing rule that a web feature is not done until its PostHog events
exist. The confirm/cancel split is the measurement that says whether the
guardrail is working or is pure friction — without it there is no way to
revisit the decision with evidence.

- [ ] **Step 1: Invoke the events skill**

Use the `frndos-analytics-events` skill to name and register the events —
do not invent names by hand.

Events needed:
- upscale target selected (`target`, estimated credits, whether free)
- 4K confirmation shown
- 4K confirmation confirmed
- 4K confirmation cancelled (this is the number that matters)

- [ ] **Step 2: Fire them**

- [ ] **Step 3: Verify the build**

Run: `bun run build`

- [ ] **Step 4: Commit**

```bash
git add src/components/studio/kv-generator/
git commit -m "feat(web): track upscale target selection and 4K confirmation"
```

---

### Task 6: Verify in the browser

**Files:** none — verification only.

- [ ] **Step 1: Open a KV with a face and check the dropdown**

Expected: two rows, correct dimensions per that KV's aspect, `~20` and `~83`.

- [ ] **Step 2: Click 2K**

Expected: starts immediately, no dialog.

- [ ] **Step 3: Click 4K**

Expected: dialog with output size, cost, balance. Cancel starts nothing.

- [ ] **Step 4: Confirm 4K and inspect the result**

Expected: long edge exactly 4096, aspect preserved, **and the face is the same
person as the source**. That last one is the entire point of this work — if the
face changed, stop and check the ai-service side rather than shipping.

- [ ] **Step 5: Find a KV already at or above 2K**

Expected: its 2K row reads **Free** and skips the dialog.
