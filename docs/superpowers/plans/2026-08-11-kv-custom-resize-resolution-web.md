# KV Custom Resize Resolution — Web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user type an arbitrary width × height in the Resize panel when the KV is layer-composed, and make every refusal visible.

**Architecture:** A custom size is a synthetic `PlatformId` of the form `` `custom-${w}x${h}` ``. Because `selectedPlatformIds` is already a `Set<PlatformId>` and everything downstream treats an id as an opaque string, adding a custom size is just adding an id to that set — queueing, dedup against existing exports, and the chat marker all work untouched. The only place that must distinguish the two kinds is the wire function, which splits preset ids into `platform_ids` and custom ids into `custom_sizes`.

**Tech Stack:** Next.js 16, React 19, TypeScript, Zustand, TanStack Query v5, Bun.

**Spec:** `docs/superpowers/specs/2026-08-11-kv-custom-resize-resolution-design.md`
**Depends on:** `2026-08-11-kv-custom-resize-resolution-api.md` — the api must accept `custom_sizes` before Task 2 here can pass an integration check.

## Global Constraints

- Bounds are **64 to 8192 inclusive**, per side — identical to `CustomResizeSize::MIN_DIMENSION` / `MAX_DIMENSION` in api. They must not drift.
- Canonical id form is **`custom-{width}x{height}`**, e.g. `custom-1080x1350`. No leading zeros, lowercase `x`.
- The custom control renders **only** when the parent generation is layer-composed.
- **No refusal may be silent.** Bounds are reported inline, server 422s raise a toast, a duplicate size is acknowledged, and an oversized flatten throws rather than writing a blank file.
- Tests run with **`bun test`** (bunfig preloads jest-dom), *not* `bunx vitest`.
- **There is no type gate.** `next.config.js:154` sets `typescript: { ignoreBuildErrors: true }`, so `bun run build` skips type-checking entirely — a passing build is never type verification. There is no `typecheck` script. `bunx tsc --noEmit` is the only type signal and carries a ~777-error pre-existing repo-wide baseline, so it is unusable as a pass/fail gate. The workable method: capture `bunx tsc --noEmit` output, then require zero *new* errors in the files your change touches — ideally diffed against the same command run on a clean baseline checkout. Still run `bun run build`: it catches broken imports and module moves.
- RTL's `screen` is broken under bun in this repo. Use `within(document.body)` for queries.
- UI chrome copy is English, matching the panel's existing "Start Resizing". Blocked-reason copy is Indonesian, matching `craftBlockedMessage`.

---

### Task 1: Custom size module and widened types

The shared vocabulary every later task uses. Pure functions, no React, fully unit-testable.

**Files:**
- Create: `src/lib/studio/kv/customSize.ts`
- Create: `src/lib/studio/kv/customSize.test.ts`
- Modify: `src/types/kv/resize.ts:7-46`
- Modify: `src/lib/studio/kv/resizePlatforms.ts:4-20`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `CUSTOM_SIZE_MIN` = `64`, `CUSTOM_SIZE_MAX` = `8192`
  - `customSizeId(width: number, height: number): CustomPlatformId`
  - `parseCustomSizeId(id: string): { width: number; height: number } | null`
  - `isCustomSizeId(id: string): boolean`
  - `validateCustomSize(width: number, height: number): string | null` — returns an error message, or `null` when valid
  - Type `CustomPlatformId = \`custom-${number}x${number}\``
  - `PlatformId` widened to `KnownPlatformId | CustomPlatformId`
  - `PlatformGroup` widened with `"custom"`; new `PresetGroup = Exclude<PlatformGroup, "custom">`

- [ ] **Step 1: Write the failing test**

Create `src/lib/studio/kv/customSize.test.ts`:

```ts
import { describe, expect, it } from "bun:test";

import {
  CUSTOM_SIZE_MAX,
  CUSTOM_SIZE_MIN,
  customSizeId,
  isCustomSizeId,
  parseCustomSizeId,
  validateCustomSize,
} from "./customSize";

describe("customSizeId", () => {
  it("builds a canonical id", () => {
    expect(customSizeId(1080, 1350)).toBe("custom-1080x1350");
  });
});

describe("isCustomSizeId", () => {
  it("accepts its own ids", () => {
    expect(isCustomSizeId("custom-1080x1350")).toBe(true);
  });

  it("rejects preset ids, including the one that starts with custom-", () => {
    expect(isCustomSizeId("instagram-post")).toBe(false);
    expect(isCustomSizeId("custom-tall")).toBe(false);
  });
});

describe("parseCustomSizeId", () => {
  it("round-trips a canonical id", () => {
    expect(parseCustomSizeId("custom-1080x1350")).toEqual({
      width: 1080,
      height: 1350,
    });
  });

  it.each([
    ["leading zeros", "custom-01080x1350"],
    ["uppercase separator", "custom-1080X1350"],
    ["trailing junk", "custom-1080x1350x"],
    ["preset", "custom-tall"],
  ])("rejects %s", (_label, id) => {
    expect(parseCustomSizeId(id)).toBeNull();
  });

  it("rejects out-of-bounds dimensions", () => {
    expect(parseCustomSizeId("custom-63x1080")).toBeNull();
    expect(parseCustomSizeId("custom-8193x1080")).toBeNull();
  });

  it("accepts the exact bounds", () => {
    expect(parseCustomSizeId(`custom-${CUSTOM_SIZE_MIN}x${CUSTOM_SIZE_MIN}`))
      .toEqual({ width: 64, height: 64 });
    expect(parseCustomSizeId(`custom-${CUSTOM_SIZE_MAX}x${CUSTOM_SIZE_MAX}`))
      .toEqual({ width: 8192, height: 8192 });
  });
});

describe("validateCustomSize", () => {
  it("accepts a valid size", () => {
    expect(validateCustomSize(1080, 1350)).toBeNull();
  });

  it("names the offending axis", () => {
    expect(validateCustomSize(10, 1350)).toContain("Width");
    expect(validateCustomSize(1080, 99999)).toContain("Height");
  });

  it("rejects non-integers", () => {
    expect(validateCustomSize(1080.5, 1350)).toContain("Width");
  });

  it("rejects NaN, which is what an empty input parses to", () => {
    expect(validateCustomSize(Number.NaN, 1350)).toContain("Width");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/lib/studio/kv/customSize.test.ts`
Expected: FAIL — cannot resolve `./customSize`.

- [ ] **Step 3: Write the module**

Create `src/lib/studio/kv/customSize.ts`:

```ts
import type { CustomPlatformId } from "@/types/kv/resize";

/** Below this, overlay projection math degenerates. */
export const CUSTOM_SIZE_MIN = 64;

/**
 * Above this, flattening the tile risks exceeding the browser's canvas
 * ceiling. 8192² is ~67M pixels — well inside Chrome's limit — so this single
 * per-side cap needs no companion area rule. Must stay in lockstep with
 * `CustomResizeSize::MAX_DIMENSION` in api.
 */
export const CUSTOM_SIZE_MAX = 8192;

/** Anchored, and it rejects a leading zero. `custom-tall` is a real preset
 *  id, so membership can never be decided by a `custom-` prefix. */
const PATTERN = /^custom-([1-9]\d*)x([1-9]\d*)$/;

export function customSizeId(width: number, height: number): CustomPlatformId {
  return `custom-${width}x${height}` as CustomPlatformId;
}

export function parseCustomSizeId(
  id: string
): { width: number; height: number } | null {
  const m = PATTERN.exec(id);
  if (!m) return null;

  const width = Number(m[1]);
  const height = Number(m[2]);
  if (validateCustomSize(width, height) !== null) return null;

  return { width, height };
}

export function isCustomSizeId(id: string): boolean {
  return parseCustomSizeId(id) !== null;
}

/** The user-facing reason a size is unacceptable, or null when it is fine.
 *  Returning the message rather than a boolean is what lets the panel say
 *  which axis is wrong instead of just refusing. */
export function validateCustomSize(
  width: number,
  height: number
): string | null {
  const bad = (axis: string) =>
    `${axis} must be a whole number between ${CUSTOM_SIZE_MIN} and ${CUSTOM_SIZE_MAX}.`;

  if (!Number.isInteger(width) || width < CUSTOM_SIZE_MIN || width > CUSTOM_SIZE_MAX) {
    return bad("Width");
  }
  if (!Number.isInteger(height) || height < CUSTOM_SIZE_MIN || height > CUSTOM_SIZE_MAX) {
    return bad("Height");
  }
  return null;
}
```

- [ ] **Step 4: Widen the types**

In `src/types/kv/resize.ts`, rename the existing closed union and add the custom arm. Change:

```ts
export type PlatformGroup = "social-media" | "print" | "digital";

export type PlatformId =
  | "instagram-post"
  // …all 32 literals, unchanged…
  | "digital-lounge-portrait";
```

to:

```ts
export type PlatformGroup = "social-media" | "print" | "digital" | "custom";

/** The three groups backed by the preset registry. `custom` is deliberately
 *  excluded: it has no registry entries and its own panel section. */
export type PresetGroup = Exclude<PlatformGroup, "custom">;

/** A user-specified size, encoded into the id so every consumer that treats
 *  a platform id as an opaque string keeps working. */
export type CustomPlatformId = `custom-${number}x${number}`;

export type KnownPlatformId =
  | "instagram-post"
  // …all 32 literals, unchanged…
  | "digital-lounge-portrait";

export type PlatformId = KnownPlatformId | CustomPlatformId;
```

Leave `Platform.group` as `PlatformGroup` and `KvResizeExport.platformGroup` as `PlatformGroup` — both now admit `"custom"`, which is what the api resource sends for a custom row.

In `src/lib/studio/kv/resizePlatforms.ts`, narrow the two registry-shaped records to `PresetGroup` so they stay total, and teach `platformById` to synthesize:

```ts
import type {
  Platform,
  PlatformId,
  PresetGroup,
} from "@/types/kv/resize";
import { PLATFORMS } from "@/types/kv/resize";
import { parseCustomSizeId } from "./customSize";

export function platformsByGroup(): Record<PresetGroup, Platform[]> {
  return {
    "social-media": PLATFORMS.filter((p) => p.group === "social-media"),
    print: PLATFORMS.filter((p) => p.group === "print"),
    digital: PLATFORMS.filter((p) => p.group === "digital"),
  };
}

export function platformById(id: PlatformId): Platform | undefined {
  const custom = parseCustomSizeId(id);
  if (custom) {
    return {
      id,
      label: `${custom.width} × ${custom.height}`,
      group: "custom",
      width: custom.width,
      height: custom.height,
    };
  }
  return PLATFORMS.find((p) => p.id === id);
}

export const GROUP_LABEL: Record<PresetGroup, string> = {
  "social-media": "Social Media",
  print: "Print",
  digital: "Digital",
};
```

- [ ] **Step 5: Run tests and the type gate**

Run: `bun test src/lib/studio/kv/customSize.test.ts`
Expected: PASS.

Run: `bunx tsc --noEmit` and compare against a baseline (see Global Constraints — the build does NOT type-check).
Expected: no NEW errors in files this task touched. If a new one appears, the likely site is `KvResizePanel.tsx:99`, where `useState<Record<PlatformGroup, boolean>>` is now missing a `custom` key — change that annotation to `Record<PresetGroup, boolean>` and its import accordingly. Also check `KvResizePanel.tsx:187` (`group: PlatformGroup`) and `motion/motionSizeOptions.ts:39`; the latter assigns an explicit three-element array literal to `PlatformGroup[]`, which stays valid under the widened union.

- [ ] **Step 6: Commit**

```bash
git add src/lib/studio/kv/customSize.ts src/lib/studio/kv/customSize.test.ts src/types/kv/resize.ts src/lib/studio/kv/resizePlatforms.ts src/components/studio/kv-generator/KvResizePanel.tsx
git commit -m "feat(web): model a custom resize size as a synthetic platform id"
```

---

### Task 2: Split preset and custom ids on the wire

The api rejects a custom id inside `platform_ids`. Confine the split to the one function that builds the request, so the rest of the UI keeps working in `PlatformId` alone.

**Files:**
- Modify: `src/services/kv/api.ts:693-714`
- Create: `src/services/kv/createResizeExports.test.ts`

**Interfaces:**
- Consumes: `parseCustomSizeId` from Task 1.
- Produces: `createResizeExports` unchanged in signature — still takes `platformIds: PlatformId[]`. Only the emitted body changes.

- [ ] **Step 1: Write the failing test**

Create `src/services/kv/createResizeExports.test.ts`. The module imports its client as `import axiosInstance from "@/services/axios"` (`api.ts:7`) — a **default** export, so that is what the mock must provide.

```ts
import { beforeEach, describe, expect, it, mock } from "bun:test";

const post = mock(async () => ({ data: { data: [] } }));

mock.module("@/services/axios", () => ({
  default: { post },
}));

const { createResizeExports } = await import("./api");

describe("createResizeExports", () => {
  beforeEach(() => post.mockClear());

  it("sends preset ids in platform_ids and omits custom_sizes", async () => {
    await createResizeExports("file-1", {
      parentGenerationId: "gen-1",
      platformIds: ["instagram-post", "tiktok-video"],
    });

    const body = post.mock.calls[0][1];
    expect(body.platform_ids).toEqual(["instagram-post", "tiktok-video"]);
    expect(body.custom_sizes).toEqual([]);
  });

  it("routes custom ids into custom_sizes as dimensions", async () => {
    await createResizeExports("file-1", {
      parentGenerationId: "gen-1",
      platformIds: ["custom-1240x1750"],
    });

    const body = post.mock.calls[0][1];
    expect(body.platform_ids).toEqual([]);
    expect(body.custom_sizes).toEqual([{ width: 1240, height: 1750 }]);
  });

  it("splits a mixed batch", async () => {
    await createResizeExports("file-1", {
      parentGenerationId: "gen-1",
      platformIds: ["instagram-post", "custom-1240x1750"],
    });

    const body = post.mock.calls[0][1];
    expect(body.platform_ids).toEqual(["instagram-post"]);
    expect(body.custom_sizes).toEqual([{ width: 1240, height: 1750 }]);
  });

  it("keeps custom-tall as a preset", () => {
    // Guard against a prefix-based split: `custom-tall` is a registry id.
    return createResizeExports("file-1", {
      parentGenerationId: "gen-1",
      platformIds: ["custom-tall"],
    }).then(() => {
      const body = post.mock.calls[0][1];
      expect(body.platform_ids).toEqual(["custom-tall"]);
      expect(body.custom_sizes).toEqual([]);
    });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/services/kv/createResizeExports.test.ts`
Expected: FAIL — `body.custom_sizes` is `undefined`.

- [ ] **Step 3: Write the implementation**

In `src/services/kv/api.ts`, add the import:

```ts
import { parseCustomSizeId } from "@/lib/studio/kv/customSize";
```

Replace the body construction inside `createResizeExports`:

```ts
  const { data } = await axiosInstance.post(
    `v1/studio/files/${fileId}/resize-exports`,
    {
      parent_generation_id: body.parentGenerationId,
      platform_ids: body.platformIds,
      crop_windows: body.cropWindows,
      additional_prompt: body.additionalPrompt ?? null,
    },
  );
```

with:

```ts
  // The UI keys everything on PlatformId, but the API takes registry ids and
  // user-specified dimensions through separate fields — it will not accept a
  // custom id inside `platform_ids`. This is the only place the two kinds are
  // told apart.
  const presetIds: string[] = [];
  const customSizes: { width: number; height: number }[] = [];
  for (const id of body.platformIds) {
    const custom = parseCustomSizeId(id);
    if (custom) {
      customSizes.push(custom);
    } else {
      presetIds.push(id);
    }
  }

  const { data } = await axiosInstance.post(
    `v1/studio/files/${fileId}/resize-exports`,
    {
      parent_generation_id: body.parentGenerationId,
      platform_ids: presetIds,
      custom_sizes: customSizes,
      crop_windows: body.cropWindows,
      additional_prompt: body.additionalPrompt ?? null,
    },
  );
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test src/services/kv/createResizeExports.test.ts`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add src/services/kv/api.ts src/services/kv/createResizeExports.test.ts
git commit -m "feat(web): route custom sizes into custom_sizes on the resize request"
```

---

### Task 3: Refuse an oversized flatten instead of writing a blank file

The defect this feature makes reachable. `flattenStageToBlob` calls `stage.toDataURL()`; when a canvas exceeds browser limits that returns the string `"data:,"` rather than throwing, `fetch` resolves it to a zero-byte blob, and the caller's `try/catch` never fires. The user gets a blank PNG reported as a successful download.

Unreachable today — the largest preset is 1280×3840, 4.9M pixels. Reachable at 8192 per side.

**Files:**
- Modify: `src/components/studio/kv-generator/overlays/exportFlatten.ts:22-35`
- Create: `src/components/studio/kv-generator/overlays/exportFlatten.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces: `flattenStageToBlob` now rejects with an `Error` whose message mentions the size, instead of resolving to an empty blob.

- [ ] **Step 1: Write the failing test**

Create `src/components/studio/kv-generator/overlays/exportFlatten.test.ts`:

`ensureFontsReady` is defined in this same file and already guards on
`document.fonts?.ready`, so it is a no-op in a non-DOM env — nothing to mock.

```ts
import { describe, expect, it } from "bun:test";

import { flattenStageToBlob } from "./exportFlatten";

/** Konva returns this exact string when the canvas is too large to serialize.
 *  It does not throw — which is the whole problem. */
const OVERSIZED_DATA_URL = "data:,";

function fakeStage(dataUrl: string) {
  return { toDataURL: () => dataUrl } as unknown as Parameters<
    typeof flattenStageToBlob
  >[0];
}

describe("flattenStageToBlob", () => {
  it("throws when the canvas was too large to serialize", async () => {
    await expect(
      flattenStageToBlob(fakeStage(OVERSIZED_DATA_URL), 100, 100)
    ).rejects.toThrow(/too large/i);
  });

  it("throws on a zero-byte result", async () => {
    await expect(
      flattenStageToBlob(fakeStage("data:image/png;base64,"), 100, 100)
    ).rejects.toThrow(/too large/i);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/components/studio/kv-generator/overlays/exportFlatten.test.ts`
Expected: FAIL — resolves to an empty blob rather than rejecting.

- [ ] **Step 3: Write the implementation**

In `src/components/studio/kv-generator/overlays/exportFlatten.ts`, replace the body of `flattenStageToBlob` after the `pixelRatio` line:

```ts
  const dataUrl = stage.toDataURL({
    mimeType: "image/png",
    pixelRatio,
  });
  const res = await fetch(dataUrl);
  return await res.blob();
```

with:

```ts
  const dataUrl = stage.toDataURL({
    mimeType: "image/png",
    pixelRatio,
  });

  // A canvas past the browser's ceiling does not throw here — toDataURL
  // returns the empty URL "data:," and fetch resolves it to a zero-byte blob.
  // Left alone, that writes a blank PNG and reports success, which is the
  // silent-blank-file failure this area was fixed for once already.
  const res = await fetch(dataUrl);
  const blob = await res.blob();

  if (blob.size === 0) {
    throw new Error(
      "Canvas too large to export in this browser — try a smaller size."
    );
  }

  return blob;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test src/components/studio/kv-generator/overlays/exportFlatten.test.ts`
Expected: PASS, 2 tests.

- [ ] **Step 5: Surface it in the download toasts**

The three existing catch blocks in `KvResizeCanvas.tsx` (`:797`, `:830`, `:845`) all say `showToast("Download failed", "Please try again.", "error")`. "Please try again" is wrong advice for a size that will never fit. Change all three to pass the thrown message through:

```ts
    } catch (err) {
      Sentry.captureException(err);
      showToast(
        "Download failed",
        err instanceof Error ? err.message : "Please try again.",
        "error"
      );
    }
```

- [ ] **Step 6: Run the surrounding suite and commit**

Run: `bun test src/components/studio/kv-generator/`
Expected: PASS — or, if reds appear, confirm them against `develop` before treating them as yours; this directory has a documented baseline of unrelated failures.

```bash
git add src/components/studio/kv-generator/overlays/exportFlatten.ts src/components/studio/kv-generator/overlays/exportFlatten.test.ts src/components/studio/kv-generator/KvResizeCanvas.tsx
git commit -m "fix(web): refuse an oversized flatten instead of downloading a blank file"
```

---

### Task 4: Surface resize failures to the user

`useResizeExports.create.onError` fires `trackKvResizeFailed` and nothing else, so a 422 reaches PostHog and never reaches the user. Every server refusal added by this feature lands here.

**Files:**
- Modify: `src/lib/studio/kv/useResizeExports.ts:105-148`
- Test: `src/lib/studio/kv/useResizeExports.error.test.ts` (create)

**Interfaces:**
- Consumes: `useToastStore` from `@/store/useToast` — `showToast(title, description?, type?)`.
- Produces: `create.onError` raises an error toast carrying the server's message.

- [ ] **Step 1: Write the failing test**

Create `src/lib/studio/kv/useResizeExports.error.test.ts`:

```ts
import { describe, expect, it } from "bun:test";

import { resizeErrorMessage } from "./useResizeExports";

describe("resizeErrorMessage", () => {
  it("prefers the API's validation message", () => {
    const err = {
      response: {
        status: 422,
        data: {
          errors: {
            custom_sizes: ["Ukuran kustom hanya tersedia untuk KV layer."],
          },
        },
      },
    };
    expect(resizeErrorMessage(err)).toBe(
      "Ukuran kustom hanya tersedia untuk KV layer."
    );
  });

  it("falls back to the API's message field", () => {
    const err = { response: { status: 422, data: { message: "Nope." } } };
    expect(resizeErrorMessage(err)).toBe("Nope.");
  });

  it("falls back to generic copy when the server said nothing useful", () => {
    expect(resizeErrorMessage(new Error("Network Error"))).toBe(
      "Please try again."
    );
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/lib/studio/kv/useResizeExports.error.test.ts`
Expected: FAIL — `resizeErrorMessage` is not exported.

- [ ] **Step 3: Write the implementation**

In `src/lib/studio/kv/useResizeExports.ts`, add near the top:

```ts
import { useToastStore } from "@/store/useToast";

/**
 * The most specific message the server offered, or generic copy. Laravel puts
 * validation detail under `errors.<field>[0]` and a summary under `message`;
 * the summary for a 422 is the useless "The given data was invalid", so the
 * field detail is checked first.
 */
export function resizeErrorMessage(error: unknown): string {
  const data = (error as { response?: { data?: unknown } })?.response?.data as
    | { errors?: Record<string, string[]>; message?: string }
    | undefined;

  const firstFieldError = Object.values(data?.errors ?? {})[0]?.[0];
  if (firstFieldError) return firstFieldError;
  if (data?.message && data.message !== "The given data was invalid.") {
    return data.message;
  }
  return "Please try again.";
}
```

Inside the hook, above the `create` mutation:

```ts
  const showToast = useToastStore((s) => s.showToast);
```

Then extend `create`'s `onError` (line 138) — keep the existing `trackKvResizeFailed` call exactly as it is and add the toast after it:

```ts
    onError: (error, vars) => {
      trackKvResizeFailed({
        error_reason: error instanceof Error ? error.message : "unknown",
        http_status:
          (error as { response?: { status?: number } }).response?.status ??
          null,
        platform_ids: vars.platformIds,
        parent_generation_id: parentGenerationId ?? "",
      });
      // Without this the refusal reaches PostHog and never reaches the user.
      showToast("Resize failed", resizeErrorMessage(error), "error");
    },
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test src/lib/studio/kv/useResizeExports.error.test.ts`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add src/lib/studio/kv/useResizeExports.ts src/lib/studio/kv/useResizeExports.error.test.ts
git commit -m "fix(web): surface resize refusals to the user, not only to PostHog"
```

---

### Task 5: The custom size control

**Files:**
- Create: `src/components/studio/kv-generator/KvCustomSizeRow.tsx`
- Create: `src/components/studio/kv-generator/KvCustomSizeRow.test.tsx`
- Modify: `src/components/studio/kv-generator/KvResizePanel.tsx`
- Modify: `src/components/studio/kv-generator/KvGeneratorLayout.tsx:4340-4390`

**Interfaces:**
- Consumes: `customSizeId`, `validateCustomSize`, `CUSTOM_SIZE_MIN`, `CUSTOM_SIZE_MAX` from Task 1.
- Produces: `KvCustomSizeRow` with props
  `{ enabled: boolean; onAdd: (id: CustomPlatformId) => void; isAlreadyAdded: (id: CustomPlatformId) => boolean }`.
  `KvResizePanel` gains two optional props: `customSizeEnabled?: boolean` and `onAddCustomSize?: (id: CustomPlatformId) => void`.

- [ ] **Step 1: Write the failing test**

Create `src/components/studio/kv-generator/KvCustomSizeRow.test.tsx`:

```tsx
import { describe, expect, it, mock } from "bun:test";
import { fireEvent, render, within } from "@testing-library/react";

import { KvCustomSizeRow } from "./KvCustomSizeRow";

// `screen` is broken under bun in this repo — query through document.body.
const ui = () => within(document.body);

function setup(overrides: Partial<Parameters<typeof KvCustomSizeRow>[0]> = {}) {
  const onAdd = mock(() => {});
  render(
    <KvCustomSizeRow
      enabled
      onAdd={onAdd}
      isAlreadyAdded={() => false}
      {...overrides}
    />
  );
  return { onAdd };
}

function type(label: string, value: string) {
  fireEvent.change(ui().getByLabelText(label), { target: { value } });
}

describe("KvCustomSizeRow", () => {
  it("adds a valid size as a synthetic id", () => {
    const { onAdd } = setup();
    type("Width", "1240");
    type("Height", "1750");
    fireEvent.click(ui().getByRole("button", { name: /add/i }));
    expect(onAdd).toHaveBeenCalledWith("custom-1240x1750");
  });

  it("refuses an out-of-range size and says which axis", () => {
    const { onAdd } = setup();
    type("Width", "20");
    type("Height", "1750");
    fireEvent.click(ui().getByRole("button", { name: /add/i }));
    expect(onAdd).not.toHaveBeenCalled();
    expect(ui().getByText(/Width must be/i)).toBeTruthy();
  });

  it("tells the user when the size is already added rather than doing nothing", () => {
    const { onAdd } = setup({ isAlreadyAdded: () => true });
    type("Width", "1240");
    type("Height", "1750");
    fireEvent.click(ui().getByRole("button", { name: /add/i }));
    expect(onAdd).not.toHaveBeenCalled();
    expect(ui().getByText(/already added/i)).toBeTruthy();
  });

  it("explains itself instead of rendering inputs when disabled", () => {
    setup({ enabled: false });
    expect(ui().queryByLabelText("Width")).toBeNull();
    expect(ui().getByText(/layer/i)).toBeTruthy();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/components/studio/kv-generator/KvCustomSizeRow.test.tsx`
Expected: FAIL — cannot resolve `./KvCustomSizeRow`.

- [ ] **Step 3: Write the component**

Create `src/components/studio/kv-generator/KvCustomSizeRow.tsx`:

```tsx
"use client";

import { useState } from "react";

import {
  CUSTOM_SIZE_MAX,
  CUSTOM_SIZE_MIN,
  customSizeId,
  validateCustomSize,
} from "@/lib/studio/kv/customSize";
import type { CustomPlatformId } from "@/types/kv/resize";

type Props = {
  /** False for an AI-generated KV: resizing it goes through the image model,
   *  where an arbitrary size costs credits and degrades at extreme ratios. */
  enabled: boolean;
  onAdd: (id: CustomPlatformId) => void;
  isAlreadyAdded: (id: CustomPlatformId) => boolean;
};

export function KvCustomSizeRow({ enabled, onAdd, isAlreadyAdded }: Props) {
  const [width, setWidth] = useState("");
  const [height, setHeight] = useState("");
  const [error, setError] = useState<string | null>(null);

  if (!enabled) {
    return (
      <p className="px-2 py-2 font-geist text-textSmRegular text-text-inverse-subtlest">
        Ukuran kustom hanya tersedia untuk KV yang disusun dari layer (impor PSD
        atau Magic Layers).
      </p>
    );
  }

  function handleAdd() {
    const w = Number(width);
    const h = Number(height);

    const invalid = validateCustomSize(w, h);
    if (invalid) {
      setError(invalid);
      return;
    }

    const id = customSizeId(w, h);
    // Adding a size that is already queued would silently no-op, because the
    // selection is a Set and the server dedups on the same id. Say so.
    if (isAlreadyAdded(id)) {
      setError(`${w} × ${h} is already added.`);
      return;
    }

    setError(null);
    setWidth("");
    setHeight("");
    onAdd(id);
  }

  return (
    <div className="mb-2 px-2">
      <div className="flex items-end gap-2">
        <label className="flex flex-1 flex-col gap-1">
          <span className="font-geist text-textXsRegular text-text-inverse-subtlest">
            Width
          </span>
          <input
            aria-label="Width"
            inputMode="numeric"
            min={CUSTOM_SIZE_MIN}
            max={CUSTOM_SIZE_MAX}
            value={width}
            onChange={(e) => setWidth(e.target.value)}
            className="w-full rounded-md bg-[rgba(255,255,255,0.06)] px-2 py-1.5 font-geist text-textSmRegular text-text-inverse outline-none"
          />
        </label>
        <label className="flex flex-1 flex-col gap-1">
          <span className="font-geist text-textXsRegular text-text-inverse-subtlest">
            Height
          </span>
          <input
            aria-label="Height"
            inputMode="numeric"
            min={CUSTOM_SIZE_MIN}
            max={CUSTOM_SIZE_MAX}
            value={height}
            onChange={(e) => setHeight(e.target.value)}
            className="w-full rounded-md bg-[rgba(255,255,255,0.06)] px-2 py-1.5 font-geist text-textSmRegular text-text-inverse outline-none"
          />
        </label>
        <button
          type="button"
          onClick={handleAdd}
          className="rounded-md bg-[rgba(255,255,255,0.10)] px-3 py-1.5 font-geist text-textSmMedium text-text-inverse hover:bg-[rgba(255,255,255,0.16)]"
        >
          Add
        </button>
      </div>
      {error ? (
        <p role="alert" className="mt-1 font-geist text-textXsRegular text-text-danger">
          {error}
        </p>
      ) : null}
    </div>
  );
}
```

Check the panel's existing rows for the exact Tailwind tokens in use and match them — the classes above follow `KvResizePanel`'s current idiom but should be reconciled against it rather than trusted blindly.

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test src/components/studio/kv-generator/KvCustomSizeRow.test.tsx`
Expected: PASS, 4 tests.

- [ ] **Step 5: Mount it in the panel**

In `KvResizePanel.tsx`, add to `Props`:

```ts
  /** True when the parent generation is layer-composed. */
  customSizeEnabled?: boolean;
  onAddCustomSize?: (id: CustomPlatformId) => void;
```

Destructure both in the component signature, then render the section immediately after the three preset groups close (after the `.map` over `["social-media", "print", "digital"]` at line 128) and before the footer:

```tsx
        <div className="mb-2">
          <span className="block px-2 py-2 font-geist text-textSmMedium font-medium tracking-[-0.14px] text-text-inverse">
            Custom
          </span>
          {onAddCustomSize ? (
            <KvCustomSizeRow
              enabled={customSizeEnabled ?? false}
              onAdd={onAddCustomSize}
              isAlreadyAdded={(id) =>
                selectedIds.has(id) || Boolean(exportsByPlatformId?.get(id))
              }
            />
          ) : null}
        </div>
```

Add the import and, if `bunx tsc --noEmit` flags it, change the `openGroups` annotation to `Record<PresetGroup, boolean>` as noted in Task 1.

- [ ] **Step 6: Wire it in the layout**

In `KvGeneratorLayout.tsx`, at the `<KvResizePanel …>` usage (the `onToggle={togglePlatform}` prop is at line 4359), add the two new props.

The selection lives in Zustand, not local state: `selectedPlatformIds` comes from `useKvResizeStore` (`:1915`) and `togglePlatform` is already destructured at `:1916`. Since `KvCustomSizeRow` refuses a duplicate before calling `onAdd`, the id is guaranteed absent from the set — so `togglePlatform` *is* the add action and no new store action is needed.

The layer-composed signal is already on the generation's metadata:

```tsx
                      customSizeEnabled={
                        (viewedGeneration?.metadata as
                          | { layer_composed?: boolean }
                          | undefined)?.layer_composed === true
                      }
                      onAddCustomSize={togglePlatform}
```

A custom size is just another `PlatformId` in the selection set, so the queued-count filter, the `onResize` handler at `:4362`, and the chat marker all treat it as opaque and need no change.

- [ ] **Step 7: Verify the type gate and commit**

Run: `bunx tsc --noEmit` and check for NEW errors in the files you touched (the build does not type-check — see Global Constraints). Then `bun run build` to catch broken imports.
Expected: no new type errors attributable to this task; build exits 0.

```bash
git add src/components/studio/kv-generator/KvCustomSizeRow.tsx src/components/studio/kv-generator/KvCustomSizeRow.test.tsx src/components/studio/kv-generator/KvResizePanel.tsx src/components/studio/kv-generator/KvGeneratorLayout.tsx
git commit -m "feat(web): add a custom size control to the resize panel"
```

---

### Task 6: Separate custom from preset in analytics

Shipping this to learn which sizes people actually need only works if the two are distinguishable in PostHog.

**Files:**
- Modify: `src/lib/analytics/kv-generator-events.ts:280-302`
- Modify: `src/lib/studio/kv/useResizeExports.ts`

**Interfaces:**
- Consumes: `isCustomSizeId` from Task 1.
- Produces: `KvResizeRequestedProps` gains `custom_size_count: number`; `KvResizeSucceededProps` gains `custom_size: boolean`.

- [ ] **Step 1: Extend the event props**

In `src/lib/analytics/kv-generator-events.ts`:

```ts
export interface KvResizeRequestedProps {
  platform_ids: string[];
  platform_count: number;
  /** How many of `platform_ids` were user-specified sizes rather than
   *  registry presets. Zero for every pre-custom-size event. */
  custom_size_count: number;
  has_prompt: boolean;
  prompt_length: number;
  parent_generation_id: string;
}

export interface KvResizeSucceededProps {
  export_id: string;
  platform_id: string;
  custom_size: boolean;
  parent_generation_id: string;
}
```

- [ ] **Step 2: Populate them**

In `src/lib/studio/kv/useResizeExports.ts`, add the import:

```ts
import { isCustomSizeId } from "./customSize";
```

At the `trackKvResizeRequested` call inside `create`'s `onSuccess`, add:

```ts
        custom_size_count: vars.platformIds.filter(isCustomSizeId).length,
```

At the `trackKvResizeSucceeded` call in the completion-tracking effect, add:

```ts
        custom_size: isCustomSizeId(row.platformId),
```

- [ ] **Step 3: Verify the type gate**

Run: `bunx tsc --noEmit` and check for NEW errors in the files you touched (the build does not type-check — see Global Constraints).
Expected: no new type errors. A missing property at either call site is exactly what this step is checking for — and note it will NOT surface in `bun run build`.

- [ ] **Step 4: Commit**

```bash
git add src/lib/analytics/kv-generator-events.ts src/lib/studio/kv/useResizeExports.ts
git commit -m "feat(web): separate custom sizes from presets in resize analytics"
```

---

### Task 7: Full check

- [ ] **Step 1: Run the touched suites**

```bash
bun test src/lib/studio/kv/ src/services/kv/ src/components/studio/kv-generator/
```

Expected: green, or reds that reproduce on `develop`. Do not "fix" a red without first confirming it is yours.

- [ ] **Step 2: The real gate**

```bash
bunx tsc --noEmit
```

Expected: no NEW errors in files this branch touched, compared against the same command on a clean baseline. This — not `bun run build` — is what proves the widened `PlatformId` did not break a consumer. Also run `bun run build` for import/module breakage.

- [ ] **Step 3: Lint**

```bash
bun run lint
```

- [ ] **Step 4: Manual verification**

With api and web running:

1. Import a PSD into a KV. Confirm the Custom section shows inputs.
2. Add 1240 × 1750. The tile appears immediately with real artwork — no spinner, no credit charge.
3. Add 1240 × 1750 again. Expect "already added", not a silent no-op.
4. Enter 20 × 1750. Expect an inline "Width must be…" message and no request.
5. Open an AI-generated KV. Expect the Indonesian explanation in place of the inputs.
6. Download the custom tile. Expect `custom-1240x1750.png` with real artwork.
7. Add 8192 × 8192 and download it. In Chrome expect a real file; in Safari, if it fails, expect the "Canvas too large" toast — **never** a blank or zero-byte PNG.

Step 7 is the one that matters most: it is the check that the silent-blank-file failure mode is actually closed.
