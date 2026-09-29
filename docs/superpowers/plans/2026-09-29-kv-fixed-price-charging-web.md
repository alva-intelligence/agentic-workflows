# KV Fixed-Price Charging — web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the credit cost before the user commits to a Motion or a layer-composed Resize, disable the action when they cannot afford it, surface the api's refusal clearly, and give superadmins a page to edit both prices.

**Architecture:** One hook (`useKvFixedPricing`) reads `GET v1/studio/kv/pricing`, so no price is written in web source. The Motion size picker gains Cost / Balance rows in its existing footer — the `KvUpscaleConfirmModal` pattern at zero added friction. The Resize panel extends its existing inline `· ~N credits` label for the layer-composed branch. Affordability comes from the existing `useEffectiveCredits().canSpend()`. A new `Admin → Financials → KV Generator Pricing` page edits the prices.

**Tech Stack:** Next.js 16, React 19, TypeScript, TanStack Query v5, Tailwind, `bun test` (bunfig preloads jest-dom).

**Spec:** [docs/superpowers/specs/2026-09-29-kv-fixed-price-charging-design.md](../specs/2026-09-29-kv-fixed-price-charging-design.md)

**Depends on:** [the api plan](2026-09-29-kv-fixed-price-charging-api.md) must be green first — every task here calls an endpoint it creates.

**Repo:** `web/` — branch off `develop`.

## Global Constraints

- **No price literal anywhere in `web/`.** Not `5`, not `25`, not in a constant, not in a test fixture standing in for production. Every number comes from `useKvFixedPricing()`. A test may assert against a stubbed value, but nothing in `src/` outside a test may name a price.
- `size_count` is now **required** on the create-motion POST. Send `options.length`.
- A price of `0` renders as **"Free"**, never `"0 credits"`.
- Use theme-aware surface tokens (`bg-surface-*`, `text-text-*`). **No new dark hex** like `bg-[rgba(26,26,26,…)]` — it is invisible to the theme sweep.
- Tests run with `bun test`, never `bunx vitest`. There is no type gate: the build sets `ignoreBuildErrors` and `tsc` has a large pre-existing baseline, so compare against a baseline worktree rather than expecting zero.
- Build with `node`, not `bun run build` (which is broken on this repo).
- Keep any test file under ~51 KB — past that, `bun test` dies with a bogus SCSS error naming `base.module.scss`. Add new test files rather than growing existing ones.
- Every new user-facing surface needs PostHog events — invoke `frndos-analytics-events` before calling this done (Task 6).

## Review Focus

Five things a reasonable user will hit that the happy path does not cover. Each has a test pinned to the task that owns it.

1. **Price still loading** — the hook returns `undefined` on first paint. The button must not read "Create motion · NaN credits" or claim the action is free. It shows the size count alone until the price arrives. (Task 1, Task 2)
2. **A price of 0** — must read "Free" and must **not** disable the button for a user with no credits. A truthy-check on the price treats 0 as missing. (Task 1, Task 2)
3. **The api refuses anyway** — the estimate can be stale if an admin edits mid-session. The 400's own message must reach the user; `err.message` on an axios error is `"Request failed with status code 400"`, which tells them nothing. (Task 2)
4. **Extra Credit covers the shortfall** — `canSpend()` counts eligible Extra Credit. Gating on `mainCredits` alone would disable the button for a workspace that can in fact pay. (Task 2, Task 3)
5. **An AI-generated board** — the Resize panel must keep showing the existing per-model estimate, not the flat overlay price. Choosing the wrong branch silently misquotes every AI resize. (Task 3)

---

## File Structure

| File | Responsibility |
|------|---------------|
| `src/services/kv/pricing.ts` | Wire call + types for the public price read |
| `src/hooks/useKvFixedPricing.ts` | Query hook exposing the two prices |
| `src/services/admin/creditPrices.ts` | Admin list/update wire calls |
| `src/hooks/useCreditPrices.ts` | Admin query + mutation hooks |
| `src/app/admin/financials/kv-generator-pricing/page.tsx` | The admin page |
| `src/app/admin/components/AdminSidebar.tsx` | *modify* — one nav child |
| `src/services/kv/motionProjects.ts` | *modify* — send `size_count` |
| `src/components/studio/kv-generator/motion/KvMotionSizePicker.tsx` | *modify* — cost, balance, gate |
| `src/components/studio/kv-generator/motion/KvMotionProjectsPanel.tsx` | *modify* — pass sizeCount, surface the 400 |
| `src/components/studio/kv-generator/KvResizePanel.tsx` | *modify* — overlay-only price branch + gate |

---

### Task 1: The pricing hook

**Files:**
- Create: `web/src/services/kv/pricing.ts`
- Create: `web/src/hooks/useKvFixedPricing.ts`
- Test: `web/src/hooks/useKvFixedPricing.test.ts`

**Interfaces:**
- Consumes: `GET v1/studio/kv/pricing` (api Task 6) → `{"data": {"kv_resize_overlay_only": number, "kv_motion_create": number}}`.
- Produces:
  - `type KvFixedPrices = { resizeOverlayOnly: number; motionCreate: number }`
  - `getKvFixedPricing(): Promise<KvFixedPrices>`
  - `useKvFixedPricing(): { prices: KvFixedPrices | undefined; isLoading: boolean }`
  - `formatCredits(credits: number | undefined): string | null` — `null` while unknown, `"Free"` for 0, `"N credits"` / `"1 credit"` otherwise

`formatCredits` lives in `src/services/kv/pricing.ts` so both the Motion and Resize surfaces render a price the same way.

- [ ] **Step 1: Write the failing test**

```ts
import { describe, expect, it } from "bun:test";
import { formatCredits } from "@/services/kv/pricing";

describe("formatCredits", () => {
  it("returns null while the price is unknown", () => {
    expect(formatCredits(undefined)).toBeNull();
  });

  it("says Free for zero rather than '0 credits'", () => {
    expect(formatCredits(0)).toBe("Free");
  });

  it("singularises one credit", () => {
    expect(formatCredits(1)).toBe("1 credit");
  });

  it("pluralises the rest", () => {
    expect(formatCredits(75)).toBe("75 credits");
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd web && bun test src/hooks/useKvFixedPricing.test.ts`
Expected: FAIL — cannot resolve `@/services/kv/pricing`.

- [ ] **Step 3: Write the service module**

```ts
import axiosInstance from "@/services/axios";

/** Fixed KV prices, in credits. Served by the api so the number the user is
 *  quoted and the number they are charged come from the same row — a price
 *  hardcoded here would drift the moment an admin edits it. */
export type KvFixedPrices = {
  /** Per size, for a resize of a layer-composed (PSD-import) board. */
  resizeOverlayOnly: number;
  /** Per size, charged when Create motion is pressed. */
  motionCreate: number;
};

type WireKvFixedPrices = {
  kv_resize_overlay_only: number;
  kv_motion_create: number;
};

export async function getKvFixedPricing(): Promise<KvFixedPrices> {
  const { data } = await axiosInstance.get("v1/studio/kv/pricing");
  const wire: WireKvFixedPrices = data.data;
  return {
    resizeOverlayOnly: wire.kv_resize_overlay_only,
    motionCreate: wire.kv_motion_create,
  };
}

/**
 * Render a credit price for a button or a summary row.
 *
 * `null` means "not known yet" — callers OMIT the price rather than guessing,
 * so a slow request never shows "NaN credits" or implies the action is free.
 * `0` is a real, admin-set price meaning free, which is why this checks for
 * `undefined` explicitly instead of testing truthiness.
 */
export function formatCredits(credits: number | undefined): string | null {
  if (credits === undefined || Number.isNaN(credits)) return null;
  if (credits === 0) return "Free";
  return credits === 1 ? "1 credit" : `${credits} credits`;
}
```

- [ ] **Step 4: Write the hook**

```ts
"use client";

import { useQuery } from "@tanstack/react-query";
import { getKvFixedPricing, type KvFixedPrices } from "@/services/kv/pricing";

export const kvFixedPricingKey = ["kv-fixed-pricing"] as const;

/**
 * The fixed KV prices in force.
 *
 * Short `staleTime` on purpose. The charge reads the price live on the server,
 * so a long cache here would let the button quote a number the api no longer
 * charges — the exact drift this feature exists to avoid. One minute bounds the
 * window to something a user cannot notice.
 */
export function useKvFixedPricing(): {
  prices: KvFixedPrices | undefined;
  isLoading: boolean;
} {
  const { data, isLoading } = useQuery({
    queryKey: kvFixedPricingKey,
    queryFn: getKvFixedPricing,
    staleTime: 60 * 1000,
  });

  return { prices: data, isLoading };
}
```

- [ ] **Step 5: Run it to verify it passes**

Run: `cd web && bun test src/hooks/useKvFixedPricing.test.ts`
Expected: 4 passing.

- [ ] **Step 6: Commit**

```bash
git add src/services/kv/pricing.ts src/hooks/useKvFixedPricing.ts src/hooks/useKvFixedPricing.test.ts
git commit -m "feat(web): read fixed KV prices from the api"
```

---

### Task 2: Motion — cost, balance, gate, and the refusal

**Files:**
- Modify: `web/src/services/kv/motionProjects.ts:112-127` — add `sizeCount`
- Modify: `web/src/components/studio/kv-generator/motion/KvMotionSizePicker.tsx` — footer at `:305-332`, props at `:75-90`
- Modify: `web/src/components/studio/kv-generator/motion/KvMotionProjectsPanel.tsx:140-191`
- Test: `web/src/components/studio/kv-generator/motion/KvMotionSizePicker.pricing.test.tsx`

A new test file rather than appending to `KvMotionSizePicker.test.tsx` (25.7 KB) — see the 51 KB cliff in Global Constraints.

**Interfaces:**
- Consumes: `useKvFixedPricing`, `formatCredits` (Task 1); existing `useEffectiveCredits()` → `{ mainCredits, extraCreditBalance, extraCreditEnabled, ecEligible, canSpend }`.
- Produces: `KvMotionSizePickerProps` gains
  - `pricePerSize?: number` — omit while unknown
  - `canAfford?: (totalCredits: number) => boolean`
  - `balanceCredits?: number`

  Passing these in rather than calling the hooks inside the picker keeps it the presentational component it already is (it takes `exportsByPlatformId` and `renderPreviewFn` the same way) and keeps it testable without a query client.

- [ ] **Step 1: Write the failing test**

```tsx
import { describe, expect, it } from "bun:test";
import { render, within } from "@testing-library/react";
import { KvMotionSizePicker } from "./KvMotionSizePicker";

// Reuse the fixture builders from KvMotionSizePicker.test.tsx — copy
// `baseProps()` from there verbatim rather than inventing a second one, so
// both files exercise the same component contract.
function props(overrides = {}) {
  return { ...baseProps(), isOpen: true, ...overrides };
}

const button = () =>
  within(document.body).getByRole("button", { name: /create motion|creating/i });

describe("KvMotionSizePicker pricing", () => {
  it("shows the size count alone while the price is still loading", () => {
    render(<KvMotionSizePicker {...props({ pricePerSize: undefined })} />);
    checkFirstThreeSizes();

    expect(button().textContent).toContain("3 sizes");
    expect(button().textContent).not.toContain("credit");
    expect(button().textContent).not.toContain("NaN");
  });

  it("multiplies the price by the number of checked sizes", () => {
    render(
      <KvMotionSizePicker
        {...props({ pricePerSize: 25, canAfford: () => true, balanceCredits: 500 })}
      />
    );
    checkFirstThreeSizes();

    expect(button().textContent).toContain("75 credits");
  });

  /** Review Focus 2 — a truthiness check on the price breaks this. */
  it("says Free for a zero price and stays enabled with no balance", () => {
    render(
      <KvMotionSizePicker
        {...props({ pricePerSize: 0, canAfford: () => false, balanceCredits: 0 })}
      />
    );
    checkFirstThreeSizes();

    expect(button().textContent).toContain("Free");
    expect(button()).not.toBeDisabled();
  });

  /** Review Focus 4 — canAfford is the only affordability authority. */
  it("disables the button and explains why when the user cannot afford it", () => {
    render(
      <KvMotionSizePicker
        {...props({ pricePerSize: 25, canAfford: () => false, balanceCredits: 20 })}
      />
    );
    checkFirstThreeSizes();

    expect(button()).toBeDisabled();
    expect(within(document.body).getByText(/not enough credits/i)).toBeTruthy();
  });

  it("stays enabled when canAfford passes on Extra Credit the main balance lacks", () => {
    render(
      <KvMotionSizePicker
        {...props({ pricePerSize: 25, canAfford: () => true, balanceCredits: 10 })}
      />
    );
    checkFirstThreeSizes();

    expect(button()).not.toBeDisabled();
  });

  it("does not gate at all when the price has not arrived", () => {
    render(
      <KvMotionSizePicker
        {...props({ pricePerSize: undefined, canAfford: () => false, balanceCredits: 0 })}
      />
    );
    checkFirstThreeSizes();

    expect(button()).not.toBeDisabled();
  });
});
```

> Use `within(document.body)`, never the bare `screen` export — `screen` is broken under this repo's `bun test` setup and one use of it fails all ~129 component tests.
>
> `checkFirstThreeSizes()` must tick three rows through real user events. Copy the row-toggling helper from `KvMotionSizePicker.test.tsx`; do **not** stub the checked-set state, or the multiplication assertion passes without the component computing anything.

- [ ] **Step 2: Run it to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/motion/KvMotionSizePicker.pricing.test.tsx`
Expected: FAIL — the button label carries no credits and never disables.

- [ ] **Step 3: Add the props and the footer**

In `KvMotionSizePickerProps`:

```tsx
  /** Credits per size. Omitted while the price is still loading — the footer
   *  then shows the size count alone and does NOT gate, because refusing an
   *  action over a price we have not fetched yet is worse than letting the
   *  server refuse it. */
  pricePerSize?: number;
  /** Extra-Credit-aware affordability, from `useEffectiveCredits().canSpend`.
   *  The only affordability authority here: `balanceCredits` is display copy
   *  and must never be compared against the total. */
  canAfford?: (totalCredits: number) => boolean;
  /** Spendable balance, for the summary row only. */
  balanceCredits?: number;
```

Compute above the return:

```tsx
  const totalCredits =
    pricePerSize === undefined ? undefined : pricePerSize * checkedKeys.size;
  const priceLabel = formatCredits(totalCredits);
  // Unaffordable only when we KNOW the price and it is not free. An unknown
  // price must not gate; a zero price is free and always affordable.
  const unaffordable =
    totalCredits !== undefined &&
    totalCredits > 0 &&
    canAfford !== undefined &&
    !canAfford(totalCredits);
```

Add the disabled term and the label segment:

```tsx
  disabled={creating || blocked || checkedKeys.size === 0 || unaffordable}
```

```tsx
  {creating
    ? "Creating…"
    : `Create motion · ${
        checkedKeys.size === 1 ? "1 size" : `${checkedKeys.size} sizes`
      }${priceLabel ? ` · ${priceLabel}` : ""}`}
```

And, above the buttons inside the footer, the summary + reason:

```tsx
  {priceLabel && (
    <div className="mr-auto flex flex-col gap-0.5 text-left">
      <span className="text-body-sm text-text-secondary">
        Cost {priceLabel}
        {balanceCredits !== undefined && (
          <> · Balance {balanceCredits.toLocaleString()} credits</>
        )}
      </span>
      {unaffordable && (
        <span className="text-body-sm text-text-error">
          Not enough credits — top up to create this motion.
        </span>
      )}
    </div>
  )}
```

Check the actual token names for error text in this codebase before using `text-text-error`:

```bash
cd web && grep -rn "text-text-error\|text-error" src/components/studio/kv-generator/KvUpscaleConfirmModal.tsx
```

Use whatever that modal uses. Do not introduce a hex colour.

- [ ] **Step 4: Update the stale comment at `:120`**

It says the custom-size tier "costs no credit". That is still true of *re-projecting* a size, but the surrounding create is now charged:

```tsx
  // Sizes typed into the row below, this session only. Deliberately NOT
  // persisted and NOT sent to Resize: this tier re-projects the master board,
  // so it incurs no RESIZE charge and has nothing to store until the project
  // is created. Creating the project is charged per size — see `pricePerSize`.
  // Cleared with the modal (see the `isOpen` effect).
```

- [ ] **Step 5: Run it to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/motion/KvMotionSizePicker.pricing.test.tsx src/components/studio/kv-generator/motion/KvMotionSizePicker.test.tsx`
Expected: the new file passes and the existing file is unchanged-green.

- [ ] **Step 6: Send `size_count` from the service**

In `src/services/kv/motionProjects.ts`, `createMotionProject`:

```ts
export async function createMotionProject(
  fileId: string,
  body: {
    boardGenerationId: string;
    name?: string;
    snapshot: KvMotionSnapshot;
    timeline: MotionTimeline;
    /** The BILLED quantity — how many sizes this project animates. Sent as its
     *  own field because the api validates and prices from it; it deliberately
     *  does not read `snapshot.tiles`, which is opaque to it. */
    sizeCount: number;
  },
): Promise<KvMotionProject> {
  const { data } = await axiosInstance.post(MOTION_PROJECTS_BASE(fileId), {
    board_generation_id: body.boardGenerationId,
    name: body.name,
    snapshot: body.snapshot,
    timeline: body.timeline,
    size_count: body.sizeCount,
  });
  return toMotionProject(unwrap<WireMotionProject>(data));
}
```

- [ ] **Step 7: Wire the panel**

In `KvMotionProjectsPanel.tsx`, add `sizeCount: options.length` to the `createProjectFn` call (`:145`), pass the three new props to the rendered `KvMotionSizePicker`, and fix `onError` so the api's own message reaches the user:

```tsx
  const { prices } = useKvFixedPricing();
  const { canSpend, mainCredits, extraCreditBalance, extraCreditEnabled, ecEligible } =
    useEffectiveCredits();
  const drawsExtraCredit = extraCreditEnabled && ecEligible;
  const balanceCredits = mainCredits + (drawsExtraCredit ? extraCreditBalance : 0);
```

```tsx
    onError: (err) => {
      // An axios error's own `message` is "Request failed with status code 400",
      // which tells the user nothing. The api's insufficient-credits response
      // carries the actionable copy in `errors`.
      const fromApi = isAxiosError(err)
        ? (err.response?.data?.errors ?? err.response?.data?.message)
        : null;
      showToast(
        "Couldn't create that motion project",
        fromApi ?? (err instanceof Error ? err.message : "Please try again."),
        "error"
      );
    },
```

Import `isAxiosError` from `axios`, matching `src/app/admin/feature-configurations/page.tsx:2`.

- [ ] **Step 8: Test the panel's refusal path**

Add to `KvMotionProjectsPanel.test.tsx` (17.3 KB — safe to append):

```tsx
it("surfaces the api's insufficient-credits copy rather than the axios message", async () => {
  const createProjectFn = () =>
    Promise.reject({
      isAxiosError: true,
      response: {
        status: 400,
        data: {
          message: "Insufficient user credits",
          errors: "This action costs 75 credits and you have 20. Top up to continue.",
        },
      },
    });

  // render the panel with this stub, press Create motion, then:
  expect(shownToastBody()).toContain("75 credits and you have 20");
  expect(shownToastBody()).not.toContain("status code");
});
```

Follow the file's existing toast-capture approach; if it has none, read `src/store/useToast.ts` and assert on the store rather than inventing a spy.

- [ ] **Step 9: Run the motion suites**

```bash
cd web && bun test src/components/studio/kv-generator/motion/KvMotionSizePicker.pricing.test.tsx \
  src/components/studio/kv-generator/motion/KvMotionSizePicker.test.tsx \
  src/components/studio/kv-generator/motion/KvMotionProjectsPanel.test.tsx
```

Pass the files explicitly. **Never `bun test` a directory** here — running the motion directory consumes ~26 GB and looks like a leak.

- [ ] **Step 10: Commit**

```bash
git add src/services/kv/motionProjects.ts src/components/studio/kv-generator/motion/KvMotionSizePicker.tsx src/components/studio/kv-generator/motion/KvMotionSizePicker.pricing.test.tsx src/components/studio/kv-generator/motion/KvMotionProjectsPanel.tsx src/components/studio/kv-generator/motion/KvMotionProjectsPanel.test.tsx
git commit -m "feat(web): quote and gate the Motion create charge"
```

---

### Task 3: Resize — the overlay-only price branch

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvResizePanel.tsx` — props `:36-108`, button `:453-470`
- Test: `web/src/components/studio/kv-generator/KvResizePanel.pricing.test.tsx`

**Interfaces:**
- Consumes: `useKvFixedPricing`, `formatCredits` (Task 1).
- Produces: `KvResizePanel` props gain
  - `isLayerComposed?: boolean`
  - `overlayPricePerSize?: number`
  - `canAfford?: (totalCredits: number) => boolean`

The panel already has `customSizeEnabled`, whose docblock says "True when the parent generation is layer-composed". **Do not reuse it.** It gates the custom-size *section*; conflating the two means a future change to where custom sizes are offered silently repricing resizes. Add the truthful prop and let the parent pass the same value to both for now.

- [ ] **Step 1: Write the failing test**

```tsx
import { describe, expect, it } from "bun:test";
import { render, within } from "@testing-library/react";
import { KvResizePanel } from "./KvResizePanel";

// Copy `baseProps()` from the existing KvResizePanel tests; if there are none,
// build the minimum the Props type requires and note it in the file header.
const button = () =>
  within(document.body).getByRole("button", { name: /resize|start resizing/i });

describe("KvResizePanel pricing", () => {
  it("quotes the flat overlay price per queued size on a layer-composed board", () => {
    render(
      <KvResizePanel
        {...baseProps({ queuedCount: 3 })}
        isLayerComposed
        overlayPricePerSize={5}
        canAfford={() => true}
      />
    );

    expect(button().textContent).toContain("15 credits");
  });

  /** Review Focus 5 — the AI branch must keep its per-model estimate. */
  it("leaves the AI estimate alone on a non-layer-composed board", () => {
    render(
      <KvResizePanel
        {...baseProps({ queuedCount: 3 })}
        isLayerComposed={false}
        overlayPricePerSize={5}
        canAfford={() => true}
      />
    );

    // The AI branch's number comes from useGptImageCreditEstimate, which the
    // fixture stubs; it must NOT be 15.
    expect(button().textContent).not.toContain("15 credits");
  });

  it("disables with a reason when the overlay charge is unaffordable", () => {
    render(
      <KvResizePanel
        {...baseProps({ queuedCount: 3 })}
        isLayerComposed
        overlayPricePerSize={5}
        canAfford={() => false}
      />
    );

    expect(button()).toBeDisabled();
    expect(within(document.body).getByText(/not enough credits/i)).toBeTruthy();
  });

  it("stays enabled while the overlay price is unknown", () => {
    render(
      <KvResizePanel
        {...baseProps({ queuedCount: 3 })}
        isLayerComposed
        overlayPricePerSize={undefined}
        canAfford={() => false}
      />
    );

    expect(button()).not.toBeDisabled();
  });

  it("says Free for a zero overlay price", () => {
    render(
      <KvResizePanel
        {...baseProps({ queuedCount: 3 })}
        isLayerComposed
        overlayPricePerSize={0}
        canAfford={() => false}
      />
    );

    expect(button().textContent).toContain("Free");
    expect(button()).not.toBeDisabled();
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/KvResizePanel.pricing.test.tsx`
Expected: FAIL — the overlay price is not read.

- [ ] **Step 3: Branch the estimate**

The panel currently computes one number at `:229`:

```tsx
const estimatedCredits = useGptImageCreditEstimate(queuedCount);
```

Replace the *label source* without touching that call — the AI branch must keep it:

```tsx
  // Two pricing models, one button. An AI-generated board resizes through the
  // image model and is quoted per-model (`useGptImageCreditEstimate`); a
  // layer-composed board makes no model call and is quoted at the flat
  // admin-set price per size. Picking the wrong branch misquotes every resize
  // of the other kind, so this reads the same flag the api charges on.
  const aiEstimate = useGptImageCreditEstimate(queuedCount);

  const overlayTotal =
    isLayerComposed && overlayPricePerSize !== undefined
      ? overlayPricePerSize * queuedCount
      : undefined;

  const priceLabel = isLayerComposed
    ? formatCredits(overlayTotal)
    : aiEstimate != null
      ? `~${aiEstimate} credits`
      : null;

  const unaffordable =
    overlayTotal !== undefined &&
    overlayTotal > 0 &&
    canAfford !== undefined &&
    !canAfford(overlayTotal);
```

`useGptImageCreditEstimate` is called unconditionally — hooks may not be called in a branch.

Then the button:

```tsx
  disabled={disabled || !!disabledReason || queuedCount === 0 || unaffordable}
```

```tsx
  {queuedCount === 0
    ? "Start Resizing"
    : `Resize · ${queuedCount} selected${priceLabel ? ` · ${priceLabel}` : ""}`}
```

And extend the existing reason line below the button so it also carries the credits reason:

```tsx
  {(disabledReason || unaffordable) && (
    <p className="font-geist text-textXs text-text-inverse-subtlest">
      {disabledReason ??
        "Not enough credits — top up to resize this board."}
    </p>
  )}
```

- [ ] **Step 4: Wire the parent**

Find the parent rendering `KvResizePanel`:

```bash
cd web && grep -rn "<KvResizePanel" src --include='*.tsx'
```

It already computes the value it passes to `customSizeEnabled`. Pass the same boolean to `isLayerComposed`, and add:

```tsx
  const { prices } = useKvFixedPricing();
  const { canSpend } = useEffectiveCredits();
  // ...
  overlayPricePerSize={prices?.resizeOverlayOnly}
  canAfford={canSpend}
```

- [ ] **Step 5: Run it to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/KvResizePanel.pricing.test.tsx`
Expected: 5 passing.

- [ ] **Step 6: Commit**

```bash
git add src/components/studio/kv-generator/KvResizePanel.tsx src/components/studio/kv-generator/KvResizePanel.pricing.test.tsx
git commit -m "feat(web): quote and gate the layer-composed resize charge"
```

---

### Task 4: Admin — KV Generator Pricing page

**Files:**
- Create: `web/src/services/admin/creditPrices.ts`
- Create: `web/src/hooks/useCreditPrices.ts`
- Create: `web/src/app/admin/financials/kv-generator-pricing/page.tsx`
- Modify: `web/src/app/admin/components/AdminSidebar.tsx:74`
- Test: `web/src/app/admin/financials/kv-generator-pricing/page.test.tsx`

**Interfaces:**
- Consumes: `GET/PATCH v1/admin/credit-prices` (api Task 7).
- Produces:
  - `type AdminCreditPrice = { key: string; label: string; description: string; unit: string; credits: number }`
  - `getCreditPrices(): Promise<AdminCreditPrice[]>`
  - `updateCreditPrice(key: string, credits: number): Promise<{ key: string; credits: number }>`
  - `useCreditPrices()`, `useUpdateCreditPrice()`

Mirror `src/services/feature-configurations.ts` and `src/hooks/useFeatureConfigurations.ts` exactly — same module shape, same `invalidateQueries` on success. The mutation must **also** invalidate `kvFixedPricingKey` from Task 1, or an admin editing a price sees the old number on the Motion button in the same session.

- [ ] **Step 1: Write the failing test**

```tsx
it("rejects a negative price before calling the api", async () => {
  // type -1 into the Motion field, submit
  expect(updateSpy).not.toHaveBeenCalled();
  expect(within(document.body).getByText(/0 or higher/i)).toBeTruthy();
});

it("rejects a fractional price", async () => {
  // type 2.5, submit
  expect(updateSpy).not.toHaveBeenCalled();
});

it("accepts zero", async () => {
  // type 0, submit
  expect(updateSpy).toHaveBeenCalledWith("kv_motion_create", 0);
});

it("saves a changed price and shows the unit from the api", async () => {
  // type 30, submit
  expect(updateSpy).toHaveBeenCalledWith("kv_motion_create", 30);
  expect(within(document.body).getByText(/credits per size/i)).toBeTruthy();
});
```

Render with a stubbed list so nothing hardcodes a real price:

```tsx
const rows = [
  {
    key: "kv_motion_create",
    label: "Motion — create",
    description: "Charged once when Create motion is pressed.",
    unit: "credits per size",
    credits: 25,
  },
];
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd web && bun test src/app/admin/financials/kv-generator-pricing/page.test.tsx`
Expected: FAIL — module not found.

- [ ] **Step 3: Write the service module**

```ts
import axiosInstance from "@/services/axios";

export type AdminCreditPrice = {
  key: string;
  label: string;
  description: string;
  unit: string;
  credits: number;
};

/** Fixed KV prices, with their admin-facing copy. Superadmin only. */
export async function getCreditPrices(): Promise<AdminCreditPrice[]> {
  const response = await axiosInstance.get("v1/admin/credit-prices");
  return response.data.data;
}

export async function updateCreditPrice(
  key: string,
  credits: number
): Promise<{ key: string; credits: number }> {
  const response = await axiosInstance.patch(`v1/admin/credit-prices/${key}`, {
    credits,
  });
  return response.data.data;
}
```

- [ ] **Step 4: Write the hooks**

```ts
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { getCreditPrices, updateCreditPrice } from "@/services/admin/creditPrices";
import { kvFixedPricingKey } from "@/hooks/useKvFixedPricing";

export const creditPriceKeys = {
  all: ["admin-credit-prices"] as const,
};

export function useCreditPrices() {
  return useQuery({
    queryKey: creditPriceKeys.all,
    queryFn: getCreditPrices,
  });
}

export function useUpdateCreditPrice() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({ key, credits }: { key: string; credits: number }) =>
      updateCreditPrice(key, credits),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: creditPriceKeys.all });
      // Also bust the PUBLIC price cache. Without this, an admin who changes a
      // price keeps seeing the old number quoted on the Motion button for the
      // rest of their session — the exact estimate/charge drift this feature
      // exists to remove.
      queryClient.invalidateQueries({ queryKey: kvFixedPricingKey });
    },
  });
}
```

- [ ] **Step 5: Write the page**

```tsx
"use client";

import { useState } from "react";
import { isAxiosError } from "axios";
import { BanknotesIcon } from "@heroicons/react/24/outline";
import Button from "@/components/frndos/Button";
import Input from "@/components/frndos/Input";
import Label from "@/components/frndos/Label";
import { useToastStore } from "@/store/useToast";
import { useCreditPrices, useUpdateCreditPrice } from "@/hooks/useCreditPrices";

/**
 * Fixed credit prices for KV actions whose cost is a product decision rather
 * than a vendor invoice. Editing one takes effect on the very next charge —
 * both the amount deducted and the estimate the user is shown read this value,
 * so they can never disagree. Every change is written to the Audit Log.
 */
export default function KvGeneratorPricingPage() {
  const { showToast } = useToastStore();
  const { data: prices, isLoading } = useCreditPrices();
  const updatePrice = useUpdateCreditPrice();
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const [savingKey, setSavingKey] = useState<string | null>(null);

  const handleSave = async (key: string, original: number) => {
    const raw = drafts[key] ?? String(original);
    const value = Number(raw);

    if (!Number.isInteger(value) || value < 0) {
      showToast(
        "Invalid price",
        "A price must be a whole number, 0 or higher. 0 makes the action free.",
        "error"
      );
      return;
    }

    setSavingKey(key);
    try {
      await updatePrice.mutateAsync({ key, credits: value });
      setDrafts((d) => {
        const next = { ...d };
        delete next[key];
        return next;
      });
      showToast("Price updated", "It applies to the next charge.", "success");
    } catch (error) {
      showToast(
        "Update failed",
        isAxiosError(error)
          ? (error.response?.data?.message ?? "Failed to update")
          : "Failed to update",
        "error"
      );
    } finally {
      setSavingKey(null);
    }
  };

  return (
    <div className="flex flex-col gap-6 p-6">
      <div className="flex flex-col gap-1">
        <h1 className="text-heading-md text-text-primary">
          KV Generator Pricing
        </h1>
        <p className="text-body-sm text-text-secondary">
          Fixed credit prices for KV actions that are not priced by an image
          model. A change applies to the next charge — no deploy needed — and is
          recorded in the Audit Log. Set a price to 0 to make that action free.
        </p>
      </div>

      <div className="flex flex-col gap-3">
        {prices?.map((price) => {
          const draft = drafts[price.key] ?? String(price.credits);
          const changed = Number(draft) !== price.credits;

          return (
            <div
              key={price.key}
              className="border-border-primary bg-surface-primary flex items-start justify-between gap-6 rounded-lg border p-4"
            >
              <div className="flex items-start gap-3">
                <BanknotesIcon className="text-text-secondary mt-0.5 h-5 w-5 shrink-0" />
                <div className="flex flex-col gap-1">
                  <Label className="text-body-md text-text-primary">
                    {price.label}
                  </Label>
                  <p className="text-body-sm text-text-secondary max-w-2xl">
                    {price.description}
                  </p>
                </div>
              </div>

              <div className="flex shrink-0 items-center gap-2">
                <Input
                  type="number"
                  min={0}
                  step={1}
                  aria-label={price.label}
                  value={draft}
                  onChange={(e) =>
                    setDrafts((d) => ({ ...d, [price.key]: e.target.value }))
                  }
                  className="w-24"
                />
                <span className="text-body-sm text-text-secondary whitespace-nowrap">
                  {price.unit}
                </span>
                <Button
                  size="small"
                  disabled={!changed || savingKey === price.key}
                  onClick={() => handleSave(price.key, price.credits)}
                >
                  {savingKey === price.key ? "Saving…" : "Save"}
                </Button>
              </div>
            </div>
          );
        })}
      </div>

      {isLoading && (
        <p className="text-body-sm text-text-secondary">Loading prices…</p>
      )}
    </div>
  );
}
```

Check the real import shape of `Button` / `Input` / `Label` before relying on the default imports above — some frndos components are named exports:

```bash
cd web && grep -n "^export" src/components/frndos/Button.tsx src/components/frndos/Input.tsx src/components/frndos/Label.tsx
```

- [ ] **Step 6: Add the sidebar entry**

In `AdminSidebar.tsx`, after the `Extra Credit` child at `:74`:

```tsx
      {
        label: "KV Generator Pricing",
        href: "/admin/financials/kv-generator-pricing",
      },
```

- [ ] **Step 7: Run it to verify it passes**

Run: `cd web && bun test src/app/admin/financials/kv-generator-pricing/page.test.tsx`
Expected: 4 passing.

- [ ] **Step 8: Commit**

```bash
git add src/services/admin/creditPrices.ts src/hooks/useCreditPrices.ts "src/app/admin/financials/kv-generator-pricing" src/app/admin/components/AdminSidebar.tsx
git commit -m "feat(web): add Admin > Financials > KV Generator Pricing"
```

---

### Task 5: No hardcoded price anywhere

- [ ] **Step 1: Prove it**

```bash
cd web && grep -rn "resizeOverlayOnly\|motionCreate\|kv_motion_create\|kv_resize_overlay_only" src --include='*.ts' --include='*.tsx' | grep -v "\.test\." 
```

Every hit must be a *reference* to the hook, the service or the key — never an assignment of a number. Then:

```bash
cd web && grep -rnE "(25|5)\s*\*\s*(checkedKeys|queuedCount|options\.length|sizeCount)" src
```

Expected: no matches. A match means a price was inlined.

- [ ] **Step 2: Commit any fix**

```bash
git commit -am "fix(web): read every KV price from the pricing endpoint"
```

---

### Task 6: Analytics

- [ ] **Step 1: Invoke the analytics agent**

Run the `frndos-analytics-events` agent over this change. A web feature is not done without its PostHog events. At minimum it needs to answer:

- an event when the Motion cost is shown, carrying `size_count` and `total_credits`
- an event when a create is blocked for insufficient credits, on both surfaces, carrying `required` and `available`
- an event when an admin changes a price, carrying `key`, `before`, `after`

`trackKvMotionProjectCreated` already fires on success at `KvMotionProjectsPanel.tsx:172` and already carries `tile_count` — extend it with the charged amount rather than adding a parallel event.

- [ ] **Step 2: Commit the events**

```bash
git commit -am "feat(web): PostHog events for KV fixed-price charging"
```

---

### Task 7: Whole-surface verification

- [ ] **Step 1: Run every affected suite, by explicit path**

```bash
cd web && bun test \
  src/hooks/useKvFixedPricing.test.ts \
  src/components/studio/kv-generator/motion/KvMotionSizePicker.pricing.test.tsx \
  src/components/studio/kv-generator/motion/KvMotionSizePicker.test.tsx \
  src/components/studio/kv-generator/motion/KvMotionProjectsPanel.test.tsx \
  src/components/studio/kv-generator/KvResizePanel.pricing.test.tsx \
  src/app/admin/financials/kv-generator-pricing/page.test.tsx
```

- [ ] **Step 2: Build**

```bash
cd web && node ./node_modules/next/dist/bin/next build
```

Use `node`, not `bun run build`. The build does not type-check; if you want a type signal, compare `tsc` output against a baseline worktree at `develop` — **never** `git stash` to make that comparison.

- [ ] **Step 3: Verify the two flows in the browser**

With the api plan's branch running and prices seeded:

1. Open a PSD-import (layer-composed) board's Resize panel. Queue three sizes. The button must read `Resize · 3 selected · 15 credits`. Run it and confirm the balance drops by 15 and three tiles appear.
2. Queue the same three sizes again. The button must quote `Free`-to-nothing or the balance must not move — a repeat costs nothing.
3. Open a Motion size picker. Tick three sizes. The button must read `Create motion · 3 sizes · 75 credits`, with `Cost 75 credits · Balance N credits` beside it. Create it and confirm the balance drops by exactly 75.
4. Export that Motion. The balance must not move.
5. As a superadmin, change Motion create to 30. Reopen the picker: three sizes must now quote 90.
6. Set Motion create to 0. The button must read `Free` and work for an account with no credits.

Report the observed balances, not just "it worked".

- [ ] **Step 4: Commit and stop**

Do not push. Daffa pushes manually.
