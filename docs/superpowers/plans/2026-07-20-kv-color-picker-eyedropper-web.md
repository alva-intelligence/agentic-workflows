# KV Canvas Color Picker + Eyedropper — Implementation Plan (web)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the KV canvas's eight fixed preset swatches with a reusable color picker offering arbitrary color selection, a hex field, recently-used colors, and a native eyedropper.

**Architecture:** A presentational `ColorPicker` in `frndos/v2` that knows nothing about overlays, Konva, or Fabric — it takes a `#RRGGBB` value, an anchor point, and optional preset/recent rows. Its popover renders into a `document.body` portal with `position: fixed`, because the canvas viewport (`KvCanvas.tsx:882`) is `overflow-hidden` and would clip it. `OverlayColorChip.tsx` becomes a thin KV wrapper that supplies the anchor, the adaptive scale, and the localStorage-backed recents, so the three existing canvas mount sites need no changes at all.

**Tech Stack:** Next.js 16 / React 19, TypeScript, Tailwind, `react-colorful` (new dependency), `bun test` + `@testing-library/react`.

**Spec:** `docs/superpowers/specs/2026-07-20-kv-color-picker-eyedropper-design.md`

## Global Constraints

- **Branch:** all work happens on a new branch `feature/daffa/vc-kv-color-picker` cut from `develop` in the `web/` repo. Do not build on `feature/daffa/vc-kv-canvas-shapes` or `feature/daffa/vc-kv-canvas-custom-fonts`.
- **Repo root for every path and command in this plan:** `/Users/alva.e202511001/Desktop/work/frndos-agentic/web`. All `git` commands run there, not in the parent workspace.
- **Test runner is `bun test`, never `bunx vitest`** — `bunfig.toml` preloads the jsdom and jest-dom setup files. Test files still `import { describe, expect, it } from "vitest"`, matching every existing test in the repo.
- **`bun run build` is the real gate.** The web build does not type-check on its own, so type errors must be caught deliberately by running the build.
- **Tests are colocated** — `foo.test.ts` sits next to `foo.ts`, per repo convention.
- **Color values are `#RRGGBB` uppercase** everywhere across module boundaries. No alpha, no `rgba()`, no 3-digit shorthand in stored values.
- **New UI components go in `src/components/frndos/v2/`** (Base UI era), never in v1.
- **`OverlayColorChip`'s public props must not change.** `KvKonvaCanvas.tsx:1397`, `KvFabricCanvas.tsx:2493`, and `KvTileOverlayEditor.tsx:405` are not to be edited.

## File Structure

| File | Responsibility |
|---|---|
| `src/lib/color/hexColor.ts` | *new* — pure hex normalize/compare. Generic, no KV knowledge, so `frndos/v2` may import it. |
| `src/lib/color/hexColor.test.ts` | *new* — tests for the above. |
| `src/lib/studio/kv/recentColors.ts` | *new* — recents reducer + guarded localStorage read/write. KV-scoped (owns the storage key). |
| `src/lib/studio/kv/recentColors.test.ts` | *new* — tests for the above. |
| `src/components/frndos/v2/colorPickerPlacement.ts` | *new* — pure popover placement math (flip above / clamp to viewport). |
| `src/components/frndos/v2/colorPickerPlacement.test.ts` | *new* — tests for the above. |
| `src/components/frndos/v2/EyeDropperButton.tsx` | *new* — native `EyeDropper` button; renders nothing when unsupported. |
| `src/components/frndos/v2/EyeDropperButton.test.tsx` | *new* — tests for the above. |
| `src/components/frndos/v2/ColorPicker.tsx` | *new* — `ColorPickerSwatch` + its portal popover. |
| `src/components/frndos/v2/ColorPicker.test.tsx` | *new* — tests for the above. |
| `src/components/frndos/v2/index.ts` | *modify* — export the new component. |
| `src/components/studio/kv-generator/overlays/OverlayColorChip.tsx` | *rewrite* — thin KV wrapper; props unchanged. |
| `package.json` | *modify* — add `react-colorful`. |

**Deviation from the spec's blast-radius table:** the spec listed one new lib file; this plan splits it into `src/lib/color/hexColor.ts` (generic) and `src/lib/studio/kv/recentColors.ts` (KV-scoped). The reason is layering — `frndos/v2` must not import from `lib/studio/kv`, or the component stops being reusable by the shapes and gradient branches, which is the whole point of the boundary. Placement math likewise lives beside the component rather than in `lib/`.

---

### Task 1: Branch setup and hex color utilities

**Files:**
- Create: `src/lib/color/hexColor.ts`
- Test: `src/lib/color/hexColor.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `normalizeHex(input: string): string | null` — returns uppercase `#RRGGBB`, or `null` when the input is not a valid hex color. Accepts an optional leading `#`, and 3-digit shorthand (which it expands).
  - `isSameColor(a: string, b: string): boolean` — case- and shorthand-insensitive equality. `false` if either side is invalid.

- [ ] **Step 1: Cut the branch**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web
git fetch origin
git checkout develop
git pull --rebase origin develop
git checkout -b feature/daffa/vc-kv-color-picker
```

Expected: `Switched to a new branch 'feature/daffa/vc-kv-color-picker'`.

- [ ] **Step 2: Write the failing test**

Create `src/lib/color/hexColor.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { isSameColor, normalizeHex } from "./hexColor";

describe("normalizeHex", () => {
  it("uppercases and keeps the leading hash", () => {
    expect(normalizeHex("#ff9500")).toBe("#FF9500");
  });

  it("adds a missing leading hash", () => {
    expect(normalizeHex("ff9500")).toBe("#FF9500");
  });

  it("expands 3-digit shorthand", () => {
    expect(normalizeHex("#f90")).toBe("#FF9900");
  });

  it("trims surrounding whitespace", () => {
    expect(normalizeHex("  #FFF  ")).toBe("#FFFFFF");
  });

  it("rejects invalid input", () => {
    expect(normalizeHex("")).toBeNull();
    expect(normalizeHex("#ff95")).toBeNull();
    expect(normalizeHex("#gggggg")).toBeNull();
    expect(normalizeHex("rgb(1,2,3)")).toBeNull();
    expect(normalizeHex("#ff9500ff")).toBeNull();
  });
});

describe("isSameColor", () => {
  it("ignores case and shorthand", () => {
    expect(isSameColor("#ffffff", "#FFF")).toBe(true);
  });

  it("distinguishes different colors", () => {
    expect(isSameColor("#FFFFFF", "#000000")).toBe(false);
  });

  it("is false when either side is invalid", () => {
    expect(isSameColor("nope", "#FFFFFF")).toBe(false);
    expect(isSameColor("#FFFFFF", "nope")).toBe(false);
  });
});
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bun test src/lib/color/hexColor.test.ts`
Expected: FAIL — module `./hexColor` cannot be resolved.

- [ ] **Step 4: Write the implementation**

Create `src/lib/color/hexColor.ts`:

```ts
/** Pure hex-color helpers. Generic — no KV or studio knowledge. */

const HEX_RE = /^#?([0-9a-f]{3}|[0-9a-f]{6})$/i;

/**
 * Normalize a hex color to uppercase `#RRGGBB`.
 * Accepts an optional leading `#` and 3-digit shorthand.
 * Returns `null` for anything that is not a valid hex color.
 */
export function normalizeHex(input: string): string | null {
  const trimmed = input.trim();
  if (!HEX_RE.test(trimmed)) return null;
  const body = trimmed.startsWith("#") ? trimmed.slice(1) : trimmed;
  const full =
    body.length === 3
      ? body
          .split("")
          .map((c) => c + c)
          .join("")
      : body;
  return `#${full.toUpperCase()}`;
}

/** Case- and shorthand-insensitive color equality. False if either side is invalid. */
export function isSameColor(a: string, b: string): boolean {
  const na = normalizeHex(a);
  const nb = normalizeHex(b);
  return na !== null && na === nb;
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bun test src/lib/color/hexColor.test.ts`
Expected: PASS — 8 tests.

- [ ] **Step 6: Commit**

```bash
git add src/lib/color/hexColor.ts src/lib/color/hexColor.test.ts
git commit -m "feat(web): add pure hex color normalize/compare helpers"
```

---

### Task 2: Recent colors reducer and storage

**Files:**
- Create: `src/lib/studio/kv/recentColors.ts`
- Test: `src/lib/studio/kv/recentColors.test.ts`

**Interfaces:**
- Consumes: `normalizeHex` from `@/lib/color/hexColor` (Task 1).
- Produces:
  - `RECENT_COLORS_KEY: "frnd.kv.recentColors"`
  - `RECENT_COLORS_MAX: 8`
  - `addRecentColor(list: string[], color: string): string[]` — pure; returns a new most-recent-first list, de-duped case-insensitively, capped at 8. Returns `list` unchanged if `color` is invalid.
  - `readRecentColors(): string[]` — guarded `localStorage` read; always returns an array, never throws.
  - `writeRecentColors(list: string[]): void` — guarded `localStorage` write; never throws.

- [ ] **Step 1: Write the failing test**

Create `src/lib/studio/kv/recentColors.test.ts`:

```ts
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  addRecentColor,
  RECENT_COLORS_KEY,
  readRecentColors,
  writeRecentColors,
} from "./recentColors";

afterEach(() => {
  window.localStorage.clear();
  vi.restoreAllMocks();
});

describe("addRecentColor", () => {
  it("puts the new color first", () => {
    expect(addRecentColor(["#000000"], "#FFFFFF")).toEqual([
      "#FFFFFF",
      "#000000",
    ]);
  });

  it("normalizes before storing", () => {
    expect(addRecentColor([], "fff")).toEqual(["#FFFFFF"]);
  });

  it("de-dupes case-insensitively and moves the color to the front", () => {
    expect(addRecentColor(["#000000", "#FFFFFF"], "#ffffff")).toEqual([
      "#FFFFFF",
      "#000000",
    ]);
  });

  it("caps the list at 8", () => {
    const nine = [
      "#111111", "#222222", "#333333", "#444444",
      "#555555", "#666666", "#777777", "#888888",
    ];
    const result = addRecentColor(nine, "#999999");
    expect(result).toHaveLength(8);
    expect(result[0]).toBe("#999999");
    expect(result).not.toContain("#888888");
  });

  it("ignores an invalid color", () => {
    const list = ["#000000"];
    expect(addRecentColor(list, "not-a-color")).toEqual(list);
  });
});

describe("readRecentColors", () => {
  it("returns an empty array when nothing is stored", () => {
    expect(readRecentColors()).toEqual([]);
  });

  it("reads back what was written", () => {
    writeRecentColors(["#FFFFFF", "#000000"]);
    expect(readRecentColors()).toEqual(["#FFFFFF", "#000000"]);
  });

  it("tolerates corrupt JSON", () => {
    window.localStorage.setItem(RECENT_COLORS_KEY, "{not json");
    expect(readRecentColors()).toEqual([]);
  });

  it("tolerates a non-array payload", () => {
    window.localStorage.setItem(RECENT_COLORS_KEY, '{"a":1}');
    expect(readRecentColors()).toEqual([]);
  });

  it("drops entries that are not valid colors", () => {
    window.localStorage.setItem(
      RECENT_COLORS_KEY,
      JSON.stringify(["#FFFFFF", 42, "nope", "#000"])
    );
    expect(readRecentColors()).toEqual(["#FFFFFF", "#000000"]);
  });

  it("does not throw when localStorage access throws", () => {
    vi.spyOn(window.localStorage, "getItem").mockImplementation(() => {
      throw new Error("private browsing");
    });
    expect(readRecentColors()).toEqual([]);
  });
});

describe("writeRecentColors", () => {
  it("does not throw when localStorage access throws", () => {
    vi.spyOn(window.localStorage, "setItem").mockImplementation(() => {
      throw new Error("quota exceeded");
    });
    expect(() => writeRecentColors(["#FFFFFF"])).not.toThrow();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bun test src/lib/studio/kv/recentColors.test.ts`
Expected: FAIL — module `./recentColors` cannot be resolved.

- [ ] **Step 3: Write the implementation**

Create `src/lib/studio/kv/recentColors.ts`:

```ts
import { normalizeHex } from "@/lib/color/hexColor";

export const RECENT_COLORS_KEY = "frnd.kv.recentColors";
export const RECENT_COLORS_MAX = 8;

/**
 * Pure reducer: prepend `color`, de-duped case-insensitively, capped at
 * RECENT_COLORS_MAX. Invalid colors are ignored and `list` is returned as-is.
 */
export function addRecentColor(list: string[], color: string): string[] {
  const next = normalizeHex(color);
  if (!next) return list;
  const rest = list.filter((c) => normalizeHex(c) !== next);
  return [next, ...rest].slice(0, RECENT_COLORS_MAX);
}

/**
 * Read the recents list. Always returns an array — corrupt JSON, a non-array
 * payload, invalid entries, and a throwing localStorage all degrade to [].
 */
export function readRecentColors(): string[] {
  try {
    const raw = window.localStorage.getItem(RECENT_COLORS_KEY);
    if (!raw) return [];
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed
      .filter((c): c is string => typeof c === "string")
      .map(normalizeHex)
      .filter((c): c is string => c !== null)
      .slice(0, RECENT_COLORS_MAX);
  } catch {
    return [];
  }
}

/** Persist the recents list. Never throws — localStorage can be unavailable. */
export function writeRecentColors(list: string[]): void {
  try {
    window.localStorage.setItem(RECENT_COLORS_KEY, JSON.stringify(list));
  } catch {
    // localStorage unavailable (private browsing, quota) — recents are
    // best-effort, so a failed write is not worth surfacing.
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bun test src/lib/studio/kv/recentColors.test.ts`
Expected: PASS — 12 tests.

- [ ] **Step 5: Commit**

```bash
git add src/lib/studio/kv/recentColors.ts src/lib/studio/kv/recentColors.test.ts
git commit -m "feat(web): add KV recent-colors reducer with guarded storage"
```

---

### Task 3: Popover placement math

**Files:**
- Create: `src/components/frndos/v2/colorPickerPlacement.ts`
- Test: `src/components/frndos/v2/colorPickerPlacement.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `interface PlacementInput { anchor: { x: number; y: number }; anchorHeight: number; popover: { width: number; height: number }; viewport: { width: number; height: number }; gap?: number }`
  - `interface Placement { left: number; top: number; side: "above" | "below" }`
  - `computePopoverPlacement(input: PlacementInput): Placement` — all coordinates are viewport-relative, for use with `position: fixed`. `gap` defaults to `8`.

Behavior: prefer below the anchor; flip above when the popover would overflow the viewport bottom. Clamp `left` horizontally so the popover stays on screen, never less than `gap`. When flipped above, `top` is likewise never less than `gap`.

- [ ] **Step 1: Write the failing test**

Create `src/components/frndos/v2/colorPickerPlacement.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { computePopoverPlacement } from "./colorPickerPlacement";

const base = {
  anchorHeight: 24,
  popover: { width: 240, height: 300 },
  viewport: { width: 1280, height: 800 },
};

describe("computePopoverPlacement", () => {
  it("places the popover below the anchor when there is room", () => {
    const p = computePopoverPlacement({ ...base, anchor: { x: 100, y: 100 } });
    expect(p.side).toBe("below");
    expect(p.top).toBe(132); // 100 + 24 + 8
    expect(p.left).toBe(100);
  });

  it("flips above when the popover would overflow the bottom", () => {
    const p = computePopoverPlacement({ ...base, anchor: { x: 100, y: 700 } });
    expect(p.side).toBe("above");
    expect(p.top).toBe(392); // 700 - 8 - 300
  });

  it("clamps left so the popover stays inside the right edge", () => {
    const p = computePopoverPlacement({ ...base, anchor: { x: 1270, y: 100 } });
    expect(p.left).toBe(1032); // 1280 - 240 - 8
  });

  it("clamps left to the gap at the left edge", () => {
    const p = computePopoverPlacement({ ...base, anchor: { x: -50, y: 100 } });
    expect(p.left).toBe(8);
  });

  it("never places the flipped popover above the top edge", () => {
    const p = computePopoverPlacement({
      ...base,
      anchor: { x: 100, y: 40 },
      viewport: { width: 1280, height: 200 },
    });
    expect(p.side).toBe("above");
    expect(p.top).toBe(8);
  });

  it("honors a custom gap", () => {
    const p = computePopoverPlacement({
      ...base,
      anchor: { x: 100, y: 100 },
      gap: 20,
    });
    expect(p.top).toBe(144); // 100 + 24 + 20
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bun test src/components/frndos/v2/colorPickerPlacement.test.ts`
Expected: FAIL — module `./colorPickerPlacement` cannot be resolved.

- [ ] **Step 3: Write the implementation**

Create `src/components/frndos/v2/colorPickerPlacement.ts`:

```ts
export interface PlacementInput {
  /** Viewport-relative top-left of the anchor element. */
  anchor: { x: number; y: number };
  anchorHeight: number;
  popover: { width: number; height: number };
  viewport: { width: number; height: number };
  /** Space between anchor and popover, and minimum viewport inset. Default 8. */
  gap?: number;
}

export interface Placement {
  left: number;
  top: number;
  side: "above" | "below";
}

/**
 * Viewport-relative placement for a `position: fixed` popover.
 * Prefers below the anchor, flips above when it would overflow the bottom,
 * and clamps horizontally so the popover always stays on screen.
 */
export function computePopoverPlacement({
  anchor,
  anchorHeight,
  popover,
  viewport,
  gap = 8,
}: PlacementInput): Placement {
  const belowTop = anchor.y + anchorHeight + gap;
  const fitsBelow = belowTop + popover.height <= viewport.height;

  const top = fitsBelow
    ? belowTop
    : Math.max(gap, anchor.y - gap - popover.height);

  const maxLeft = Math.max(gap, viewport.width - popover.width - gap);
  const left = Math.min(Math.max(gap, anchor.x), maxLeft);

  return { left, top, side: fitsBelow ? "below" : "above" };
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bun test src/components/frndos/v2/colorPickerPlacement.test.ts`
Expected: PASS — 6 tests.

- [ ] **Step 5: Commit**

```bash
git add src/components/frndos/v2/colorPickerPlacement.ts src/components/frndos/v2/colorPickerPlacement.test.ts
git commit -m "feat(web): add color picker popover placement math"
```

---

### Task 4: Eyedropper button

**Files:**
- Create: `src/components/frndos/v2/EyeDropperButton.tsx`
- Test: `src/components/frndos/v2/EyeDropperButton.test.tsx`

**Interfaces:**
- Consumes: `normalizeHex` from `@/lib/color/hexColor` (Task 1).
- Produces:
  - `EyeDropperButton({ onPick, onOpenChange, className }: { onPick: (color: string) => void; onOpenChange?: (sampling: boolean) => void; className?: string })` — a React component. Renders `null` when `window.EyeDropper` is undefined.

`onOpenChange(true)` fires before the native picker opens and `onOpenChange(false)` after it settles (success or cancel), so the parent popover can hide itself while sampling and reappear afterwards. `onPick` fires only on success, with a normalized `#RRGGBB`.

TypeScript does not ship `EyeDropper` DOM types, so the component declares them.

- [ ] **Step 1: Write the failing test**

Create `src/components/frndos/v2/EyeDropperButton.test.tsx`:

```tsx
import { render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { EyeDropperButton } from "./EyeDropperButton";

afterEach(() => {
  delete (window as unknown as Record<string, unknown>).EyeDropper;
  vi.restoreAllMocks();
});

function installEyeDropper(open: () => Promise<{ sRGBHex: string }>) {
  (window as unknown as Record<string, unknown>).EyeDropper = class {
    open = open;
  };
}

describe("EyeDropperButton", () => {
  it("renders nothing when the browser has no EyeDropper", () => {
    const { container } = render(<EyeDropperButton onPick={() => {}} />);
    expect(container).toBeEmptyDOMElement();
  });

  it("renders a button when EyeDropper is supported", () => {
    installEyeDropper(async () => ({ sRGBHex: "#ff9500" }));
    render(<EyeDropperButton onPick={() => {}} />);
    expect(
      screen.getByRole("button", { name: /pick color from screen/i })
    ).toBeInTheDocument();
  });

  it("reports the normalized picked color", async () => {
    installEyeDropper(async () => ({ sRGBHex: "#ff9500" }));
    const onPick = vi.fn();
    render(<EyeDropperButton onPick={onPick} />);
    screen.getByRole("button", { name: /pick color from screen/i }).click();
    await waitFor(() => expect(onPick).toHaveBeenCalledWith("#FF9500"));
  });

  it("hides and restores the parent while sampling", async () => {
    installEyeDropper(async () => ({ sRGBHex: "#000000" }));
    const onOpenChange = vi.fn();
    render(<EyeDropperButton onPick={() => {}} onOpenChange={onOpenChange} />);
    screen.getByRole("button", { name: /pick color from screen/i }).click();
    await waitFor(() =>
      expect(onOpenChange.mock.calls).toEqual([[true], [false]])
    );
  });

  it("swallows a user cancel without picking a color", async () => {
    installEyeDropper(async () => {
      throw new DOMException("aborted", "AbortError");
    });
    const onPick = vi.fn();
    const onOpenChange = vi.fn();
    render(<EyeDropperButton onPick={onPick} onOpenChange={onOpenChange} />);
    screen.getByRole("button", { name: /pick color from screen/i }).click();
    await waitFor(() => expect(onOpenChange).toHaveBeenCalledWith(false));
    expect(onPick).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bun test src/components/frndos/v2/EyeDropperButton.test.tsx`
Expected: FAIL — module `./EyeDropperButton` cannot be resolved.

- [ ] **Step 3: Write the implementation**

Create `src/components/frndos/v2/EyeDropperButton.tsx`:

```tsx
"use client";

import { useEffect, useState } from "react";
import { normalizeHex } from "@/lib/color/hexColor";

// The EyeDropper API is not in TypeScript's DOM lib yet.
interface EyeDropperResult {
  sRGBHex: string;
}
interface EyeDropperInstance {
  open: (options?: { signal?: AbortSignal }) => Promise<EyeDropperResult>;
}
declare global {
  interface Window {
    EyeDropper?: new () => EyeDropperInstance;
  }
}

export interface EyeDropperButtonProps {
  /** Fired on a successful pick, with a normalized `#RRGGBB`. */
  onPick: (color: string) => void;
  /** true just before the native picker opens, false once it settles. */
  onOpenChange?: (sampling: boolean) => void;
  className?: string;
}

/**
 * Native eyedropper trigger. Renders nothing when unsupported
 * (Safari, Firefox) — supported in Chrome, Edge, and Arc.
 *
 * We use the native API rather than sampling our own canvas because KV board
 * images load from S3 without `crossOrigin` (S3 sends no CORS headers), which
 * taints the canvas and makes getImageData throw. The native picker samples
 * the composited screen instead, so the taint is irrelevant.
 */
export function EyeDropperButton({
  onPick,
  onOpenChange,
  className,
}: EyeDropperButtonProps) {
  // Resolved in an effect so SSR and the first client render agree.
  const [supported, setSupported] = useState(false);
  useEffect(() => {
    setSupported(typeof window !== "undefined" && "EyeDropper" in window);
  }, []);

  if (!supported) return null;

  const handleClick = async () => {
    const Ctor = window.EyeDropper;
    if (!Ctor) return;
    onOpenChange?.(true);
    try {
      const { sRGBHex } = await new Ctor().open();
      const normalized = normalizeHex(sRGBHex);
      if (normalized) onPick(normalized);
    } catch {
      // AbortError — the user dismissed the picker. Nothing to report.
    } finally {
      onOpenChange?.(false);
    }
  };

  return (
    <button
      type="button"
      aria-label="Pick color from screen"
      title="Pick color from screen"
      onClick={handleClick}
      className={[
        "flex size-8 shrink-0 items-center justify-center rounded-md",
        "border border-white/10 bg-white/5 text-white/80",
        "transition-colors hover:bg-white/10 hover:text-white",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-blue-500/60",
        className ?? "",
      ].join(" ")}
    >
      <svg
        width="16"
        height="16"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
        aria-hidden="true"
      >
        <path d="m2 22 1-1h3l9-9" />
        <path d="M3 21v-3l9-9" />
        <path d="m15 6 3.4-3.4a2.1 2.1 0 1 1 3 3L18 9l.4.4a2.1 2.1 0 1 1-3 3l-3.8-3.8a2.1 2.1 0 1 1 3-3l.4.4Z" />
      </svg>
    </button>
  );
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bun test src/components/frndos/v2/EyeDropperButton.test.tsx`
Expected: PASS — 5 tests.

- [ ] **Step 5: Commit**

```bash
git add src/components/frndos/v2/EyeDropperButton.tsx src/components/frndos/v2/EyeDropperButton.test.tsx
git commit -m "feat(web): add native EyeDropper button component"
```

---

### Task 5: ColorPicker component

**Files:**
- Create: `src/components/frndos/v2/ColorPicker.tsx`
- Test: `src/components/frndos/v2/ColorPicker.test.tsx`
- Modify: `src/components/frndos/v2/index.ts`
- Modify: `package.json` (adds `react-colorful`)

**Interfaces:**
- Consumes: `computePopoverPlacement` (Task 3), `EyeDropperButton` (Task 4), `isSameColor` and `normalizeHex` (Task 1).
- Produces:
  - `interface ColorPickerProps { value: string; onChange: (next: string) => void; onCommit?: (final: string) => void; anchor: { x: number; y: number }; scale?: number; presets?: string[]; recents?: string[]; visible?: boolean; disabled?: boolean; label?: string }`
  - `ColorPicker(props: ColorPickerProps)` — default export style matches the v2 barrel's named-export convention (`export { ColorPicker }`).
  - `DEFAULT_COLOR_PRESETS: string[]` — the eight colors currently in `OverlayColorChip`.

Behavior:
- Renders a single round swatch button filled with `value`, positioned absolutely at `anchor` and scaled by `scale` (default `1`), matching the existing chip's `transformOrigin: "top left"`.
- Clicking the swatch toggles a popover, portaled to `document.body` at `position: fixed`, placed via `computePopoverPlacement`.
- The popover contains, top to bottom: the presets row, the recents row (omitted entirely when `recents` is empty), the `HexColorPicker` area, then a footer with `HexColorInput` and `EyeDropperButton`.
- Preset/recent clicks and picker drags all call `onChange` immediately — the canvas updates live.
- `onCommit` fires **once** when the popover closes, with the latest value. This is what feeds recents, so a drag through many colors contributes a single entry.
- Closes on outside click, on `Escape`, and whenever `visible` flips to `false` (which is how canvas pan/zoom and overlay drag dismiss it).
- While the eyedropper is sampling, the popover is hidden but not closed.

- [ ] **Step 1: Install the dependency**

```bash
bun add react-colorful
```

Expected: `react-colorful` appears in `package.json` dependencies.

- [ ] **Step 2: Write the failing test**

Create `src/components/frndos/v2/ColorPicker.test.tsx`:

```tsx
import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { ColorPicker } from "./ColorPicker";

const anchor = { x: 100, y: 100 };

function open() {
  fireEvent.click(screen.getByRole("button", { name: /current color/i }));
}

describe("ColorPicker", () => {
  it("renders only the swatch until it is opened", () => {
    render(<ColorPicker value="#FF9500" onChange={() => {}} anchor={anchor} />);
    expect(
      screen.getByRole("button", { name: /current color/i })
    ).toBeInTheDocument();
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  it("renders nothing when not visible", () => {
    const { container } = render(
      <ColorPicker
        value="#FF9500"
        onChange={() => {}}
        anchor={anchor}
        visible={false}
      />
    );
    expect(container).toBeEmptyDOMElement();
  });

  it("opens a popover with the default presets", () => {
    render(<ColorPicker value="#FF9500" onChange={() => {}} anchor={anchor} />);
    open();
    expect(screen.getByRole("dialog")).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "Color #007AFF" })
    ).toBeInTheDocument();
  });

  it("applies a preset via onChange", () => {
    const onChange = vi.fn();
    render(<ColorPicker value="#FF9500" onChange={onChange} anchor={anchor} />);
    open();
    fireEvent.click(screen.getByRole("button", { name: "Color #007AFF" }));
    expect(onChange).toHaveBeenCalledWith("#007AFF");
  });

  it("omits the recents row when there are no recents", () => {
    render(<ColorPicker value="#FF9500" onChange={() => {}} anchor={anchor} />);
    open();
    expect(screen.queryByLabelText("Recent colors")).not.toBeInTheDocument();
  });

  it("shows recents when provided", () => {
    render(
      <ColorPicker
        value="#FF9500"
        onChange={() => {}}
        anchor={anchor}
        recents={["#123456"]}
      />
    );
    open();
    expect(screen.getByLabelText("Recent colors")).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "Color #123456" })
    ).toBeInTheDocument();
  });

  it("marks the active preset as pressed regardless of case", () => {
    render(<ColorPicker value="#007aff" onChange={() => {}} anchor={anchor} />);
    open();
    expect(screen.getByRole("button", { name: "Color #007AFF" })).toHaveAttribute(
      "aria-pressed",
      "true"
    );
  });

  it("closes on Escape and commits once", () => {
    const onCommit = vi.fn();
    render(
      <ColorPicker
        value="#FF9500"
        onChange={() => {}}
        onCommit={onCommit}
        anchor={anchor}
      />
    );
    open();
    fireEvent.keyDown(document, { key: "Escape" });
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    expect(onCommit).toHaveBeenCalledTimes(1);
    expect(onCommit).toHaveBeenCalledWith("#FF9500");
  });

  it("closes on an outside click", () => {
    render(<ColorPicker value="#FF9500" onChange={() => {}} anchor={anchor} />);
    open();
    fireEvent.pointerDown(document.body);
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  it("closes when visibility is withdrawn mid-edit", () => {
    const { rerender } = render(
      <ColorPicker value="#FF9500" onChange={() => {}} anchor={anchor} />
    );
    open();
    rerender(
      <ColorPicker
        value="#FF9500"
        onChange={() => {}}
        anchor={anchor}
        visible={false}
      />
    );
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });
});
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bun test src/components/frndos/v2/ColorPicker.test.tsx`
Expected: FAIL — module `./ColorPicker` cannot be resolved.

- [ ] **Step 4: Write the implementation**

Create `src/components/frndos/v2/ColorPicker.tsx`:

```tsx
"use client";

import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { HexColorInput, HexColorPicker } from "react-colorful";
import { isSameColor, normalizeHex } from "@/lib/color/hexColor";
import { computePopoverPlacement, type Placement } from "./colorPickerPlacement";
import { EyeDropperButton } from "./EyeDropperButton";

/** The eight colors the KV overlay chip has always offered. */
export const DEFAULT_COLOR_PRESETS = [
  "#FFFFFF", "#000000", "#FF3B30", "#FF9500",
  "#FFCC00", "#34C759", "#007AFF", "#AF52DE",
];

const POPOVER_WIDTH = 232;
const SWATCH_SIZE = 24;

export interface ColorPickerProps {
  /** Current color, `#RRGGBB`. */
  value: string;
  /** Fires on every change — presets, recents, picker drags, hex edits. */
  onChange: (next: string) => void;
  /** Fires once when the popover closes, with the final value. Feeds recents. */
  onCommit?: (final: string) => void;
  /**
   * Top-left of the swatch, in the coordinate space of the nearest positioned
   * ancestor (the canvas container) — NOT viewport coordinates. The popover
   * derives its own viewport position from the swatch's bounding rect.
   */
  anchor: { x: number; y: number };
  /** Swatch scale, for canvas zoom parity. Default 1. */
  scale?: number;
  presets?: string[];
  recents?: string[];
  /** When false the whole control unmounts (and any open popover closes). */
  visible?: boolean;
  disabled?: boolean;
  /** Accessible name for the swatch. Default "Current color". */
  label?: string;
}

function SwatchRow({
  colors,
  value,
  onPick,
  label,
}: {
  colors: string[];
  value: string;
  onPick: (color: string) => void;
  label: string;
}) {
  return (
    <div role="group" aria-label={label} className="flex flex-wrap gap-1.5">
      {colors.map((c) => (
        <button
          key={c}
          type="button"
          aria-label={`Color ${c}`}
          aria-pressed={isSameColor(c, value)}
          onClick={() => onPick(c)}
          className={[
            "size-5 rounded-full border transition-transform",
            isSameColor(c, value)
              ? "scale-110 border-white"
              : "border-white/20 hover:scale-105",
          ].join(" ")}
          style={{ backgroundColor: c }}
        />
      ))}
    </div>
  );
}

export function ColorPicker({
  value,
  onChange,
  onCommit,
  anchor,
  scale = 1,
  presets = DEFAULT_COLOR_PRESETS,
  recents = [],
  visible = true,
  disabled = false,
  label = "Current color",
}: ColorPickerProps) {
  const [open, setOpen] = useState(false);
  const [sampling, setSampling] = useState(false);
  const [placement, setPlacement] = useState<Placement>({
    left: anchor.x,
    top: anchor.y,
    side: "below",
  });
  const popoverRef = useRef<HTMLDivElement | null>(null);
  const swatchRef = useRef<HTMLButtonElement | null>(null);
  // Kept in a ref so the close handler always commits the newest value
  // without re-subscribing its listeners on every drag frame.
  const valueRef = useRef(value);
  valueRef.current = value;
  // Mirrors `open` so close() can guard against double-commit without doing
  // side effects inside a state updater (StrictMode invokes those twice).
  const openRef = useRef(false);

  const openPopover = useCallback(() => {
    openRef.current = true;
    setOpen(true);
  }, []);

  const close = useCallback(() => {
    if (!openRef.current) return;
    openRef.current = false;
    setOpen(false);
    onCommit?.(valueRef.current);
  }, [onCommit]);

  // Withdrawn visibility (canvas pan/zoom, overlay drag) dismisses the popover.
  useEffect(() => {
    if (!visible && open) close();
  }, [visible, open, close]);

  // Measure once open, so the popover can flip above near the viewport bottom.
  // The swatch's bounding rect is what converts the container-relative anchor
  // into the viewport coordinates a `position: fixed` popover needs.
  useLayoutEffect(() => {
    if (!open) return;
    const rect = swatchRef.current?.getBoundingClientRect();
    if (!rect) return;
    setPlacement(
      computePopoverPlacement({
        anchor: { x: rect.left, y: rect.top },
        anchorHeight: rect.height,
        popover: {
          width: POPOVER_WIDTH,
          height: popoverRef.current?.offsetHeight ?? 0,
        },
        viewport: { width: window.innerWidth, height: window.innerHeight },
      })
    );
  }, [open, anchor, scale]);

  useEffect(() => {
    if (!open) return;
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") close();
    };
    const onPointerDown = (e: PointerEvent) => {
      if (!popoverRef.current?.contains(e.target as Node)) close();
    };
    document.addEventListener("keydown", onKeyDown);
    document.addEventListener("pointerdown", onPointerDown);
    return () => {
      document.removeEventListener("keydown", onKeyDown);
      document.removeEventListener("pointerdown", onPointerDown);
    };
  }, [open, close]);

  const handleChange = useCallback(
    (next: string) => {
      const normalized = normalizeHex(next);
      if (normalized) onChange(normalized);
    },
    [onChange]
  );

  if (!visible) return null;

  return (
    <>
      <button
        ref={swatchRef}
        type="button"
        aria-label={label}
        aria-haspopup="dialog"
        aria-expanded={open}
        disabled={disabled}
        onClick={() => (open ? close() : openPopover())}
        className={[
          "absolute z-30 rounded-full border-2 border-white/80 shadow-lg",
          "transition-transform hover:scale-105 disabled:opacity-50",
          "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-blue-500/60",
        ].join(" ")}
        style={{
          left: anchor.x,
          top: anchor.y,
          width: SWATCH_SIZE,
          height: SWATCH_SIZE,
          backgroundColor: value,
          transform: `scale(${scale})`,
          transformOrigin: "top left",
        }}
      />
      {open &&
        typeof document !== "undefined" &&
        createPortal(
          <div
            ref={popoverRef}
            role="dialog"
            aria-label="Color picker"
            className={[
              "fixed z-50 flex flex-col gap-3 rounded-xl p-3",
              "border border-white/10 bg-[rgba(20,20,22,0.92)] backdrop-blur-md",
              "shadow-[0_8px_32px_rgba(0,0,0,0.5)]",
              sampling ? "invisible" : "",
            ].join(" ")}
            style={{
              left: placement.left,
              top: placement.top,
              width: POPOVER_WIDTH,
            }}
          >
            <SwatchRow
              colors={presets}
              value={value}
              onPick={handleChange}
              label="Preset colors"
            />
            {recents.length > 0 && (
              <SwatchRow
                colors={recents}
                value={value}
                onPick={handleChange}
                label="Recent colors"
              />
            )}
            <HexColorPicker
              color={value}
              onChange={handleChange}
              style={{ width: "100%", height: 140 }}
            />
            <div className="flex items-center gap-2">
              <HexColorInput
                color={value}
                onChange={handleChange}
                prefixed
                aria-label="Hex color"
                className={[
                  "h-8 min-w-0 flex-1 rounded-md border border-white/10 bg-white/5",
                  "px-2 font-mono text-xs uppercase text-white",
                  "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-blue-500/60",
                ].join(" ")}
              />
              <EyeDropperButton onPick={handleChange} onOpenChange={setSampling} />
            </div>
          </div>,
          document.body
        )}
    </>
  );
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bun test src/components/frndos/v2/ColorPicker.test.tsx`
Expected: PASS — 10 tests.

- [ ] **Step 6: Export from the v2 barrel**

Add to the end of `src/components/frndos/v2/index.ts`:

```ts
// ColorPicker
export { ColorPicker, DEFAULT_COLOR_PRESETS } from "./ColorPicker";
export type { ColorPickerProps } from "./ColorPicker";
export { EyeDropperButton } from "./EyeDropperButton";
export type { EyeDropperButtonProps } from "./EyeDropperButton";
```

- [ ] **Step 7: Commit**

```bash
git add package.json bun.lock src/components/frndos/v2/ColorPicker.tsx src/components/frndos/v2/ColorPicker.test.tsx src/components/frndos/v2/index.ts
git commit -m "feat(web): add frndOS v2 ColorPicker with presets, recents and eyedropper"
```

---

### Task 6: Wire the KV overlay chip to the new picker

**Files:**
- Rewrite: `src/components/studio/kv-generator/overlays/OverlayColorChip.tsx`
- Test: `src/components/studio/kv-generator/overlays/OverlayColorChip.test.tsx`

**Interfaces:**
- Consumes: `ColorPicker` (Task 5), `addRecentColor` / `readRecentColors` / `writeRecentColors` (Task 2), `getColorChipScale` from `./adaptiveSizing`.
- Produces: `OverlayColorChip` with **exactly the props it has today** — `{ value: string; onChange: (next: string) => void; anchor: { x: number; y: number }; overlayWidthPx: number; visible?: boolean }`. No consumer changes.

This is the task that must not break the three mount sites. Read `KvKonvaCanvas.tsx:1397`, `KvFabricCanvas.tsx:2493`, and `KvTileOverlayEditor.tsx:405` before starting, and confirm afterwards that none of them needed an edit.

- [ ] **Step 1: Write the failing test**

Create `src/components/studio/kv-generator/overlays/OverlayColorChip.test.tsx`:

```tsx
import { fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { RECENT_COLORS_KEY } from "@/lib/studio/kv/recentColors";
import { OverlayColorChip } from "./OverlayColorChip";

afterEach(() => {
  window.localStorage.clear();
});

const baseProps = {
  anchor: { x: 40, y: 40 },
  overlayWidthPx: 200,
};

describe("OverlayColorChip", () => {
  it("renders a single swatch showing the current color", () => {
    render(
      <OverlayColorChip value="#FF9500" onChange={() => {}} {...baseProps} />
    );
    const swatch = screen.getByRole("button", { name: /current color/i });
    expect(swatch).toHaveStyle({ backgroundColor: "#FF9500" });
  });

  it("renders nothing when not visible", () => {
    const { container } = render(
      <OverlayColorChip
        value="#FF9500"
        onChange={() => {}}
        visible={false}
        {...baseProps}
      />
    );
    expect(container).toBeEmptyDOMElement();
  });

  it("forwards preset picks to onChange", () => {
    const onChange = vi.fn();
    render(
      <OverlayColorChip value="#FF9500" onChange={onChange} {...baseProps} />
    );
    fireEvent.click(screen.getByRole("button", { name: /current color/i }));
    fireEvent.click(screen.getByRole("button", { name: "Color #34C759" }));
    expect(onChange).toHaveBeenCalledWith("#34C759");
  });

  it("persists the color to recents when the popover closes", () => {
    render(
      <OverlayColorChip value="#123456" onChange={() => {}} {...baseProps} />
    );
    fireEvent.click(screen.getByRole("button", { name: /current color/i }));
    fireEvent.keyDown(document, { key: "Escape" });
    expect(
      JSON.parse(window.localStorage.getItem(RECENT_COLORS_KEY) ?? "[]")
    ).toEqual(["#123456"]);
  });

  it("shows previously stored recents", () => {
    window.localStorage.setItem(
      RECENT_COLORS_KEY,
      JSON.stringify(["#ABCDEF"])
    );
    render(
      <OverlayColorChip value="#FF9500" onChange={() => {}} {...baseProps} />
    );
    fireEvent.click(screen.getByRole("button", { name: /current color/i }));
    expect(
      screen.getByRole("button", { name: "Color #ABCDEF" })
    ).toBeInTheDocument();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bun test src/components/studio/kv-generator/overlays/OverlayColorChip.test.tsx`
Expected: FAIL — no button named "Current color"; the old component renders a preset toolbar.

- [ ] **Step 3: Rewrite the component**

Replace the entire contents of `src/components/studio/kv-generator/overlays/OverlayColorChip.tsx`:

```tsx
"use client";

import { useCallback, useEffect, useState } from "react";
import { ColorPicker } from "@/components/frndos/v2";
import {
  addRecentColor,
  readRecentColors,
  writeRecentColors,
} from "@/lib/studio/kv/recentColors";
import { getColorChipScale } from "./adaptiveSizing";

/**
 * KV-specific wrapper around the shared v2 ColorPicker.
 *
 * Owns only what the canvas knows: where the chip sits, how big it should be
 * at the current overlay width, and the KV recents list. Everything else lives
 * in ColorPicker, so the shapes and gradient branches can reuse it as-is.
 */
export function OverlayColorChip({
  value,
  onChange,
  anchor,
  overlayWidthPx,
  visible = true,
}: {
  value: string;
  onChange: (next: string) => void;
  anchor: { x: number; y: number };
  /** Overlay's current pixel width — drives chip scale. */
  overlayWidthPx: number;
  /** When false, the chip is hidden (during drag/transform). */
  visible?: boolean;
}) {
  const [recents, setRecents] = useState<string[]>([]);

  // Read lazily on mount rather than at module load, so server and first
  // client render agree and hydration stays clean.
  useEffect(() => {
    setRecents(readRecentColors());
  }, []);

  const handleCommit = useCallback((final: string) => {
    setRecents((prev) => {
      const next = addRecentColor(prev, final);
      writeRecentColors(next);
      return next;
    });
  }, []);

  return (
    <ColorPicker
      value={value}
      onChange={onChange}
      onCommit={handleCommit}
      anchor={anchor}
      scale={getColorChipScale(overlayWidthPx)}
      recents={recents}
      visible={visible}
      label="Current color"
    />
  );
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bun test src/components/studio/kv-generator/overlays/OverlayColorChip.test.tsx`
Expected: PASS — 5 tests.

- [ ] **Step 5: Confirm the mount sites did not need editing**

```bash
git status --porcelain
```

Expected: `KvKonvaCanvas.tsx`, `KvFabricCanvas.tsx`, and `KvTileOverlayEditor.tsx` do **not** appear. If any of them does, the prop contract was broken — revert that edit and fix the wrapper's signature instead.

- [ ] **Step 6: Commit**

```bash
git add src/components/studio/kv-generator/overlays/OverlayColorChip.tsx src/components/studio/kv-generator/overlays/OverlayColorChip.test.tsx
git commit -m "feat(web): replace KV preset swatches with the shared color picker"
```

---

### Task 7: Full verification

**Files:** none — this task only runs gates.

- [ ] **Step 1: Run the whole test suite**

Run: `bun test`
Expected: PASS. No pre-existing test may regress. If something unrelated was already failing on `develop`, confirm that by stashing nothing and checking out `develop` in a scratch worktree — never `git stash` to compare (it has corrupted files in this repo before).

- [ ] **Step 2: Lint**

Run: `bun run lint`
Expected: no new errors or warnings attributable to the files in this plan.

- [ ] **Step 3: Build — this is the real type gate**

Run: `bun run build`
Expected: build succeeds. The dev server does not type-check, so this step is the only thing that catches type errors.

- [ ] **Step 4: Manual e2e on the KV canvas**

Start the frontend (`bun dev` in `web/`, or `./run-all.sh` from the workspace root) and open a KV project with a text overlay. Verify each of these:

1. Selecting a text overlay shows a **single** swatch in the current text color, not the old eight-swatch row.
2. Clicking the swatch opens the popover; the eight presets are present and apply on click.
3. Dragging in the saturation area updates the text color live on canvas.
4. Typing a hex into the field applies it.
5. The eyedropper button is present (Chrome/Arc), the popover hides while sampling, and the sampled color is applied.
6. Closing and reopening the popover shows the last-used color in the recents row; it survives a page reload.
7. With an overlay near the **bottom** of the canvas, the popover flips above the swatch instead of being cut off.
8. With an overlay near the **right** edge, the popover stays fully on screen.
9. Panning or zooming the canvas dismisses the popover; dragging the overlay hides the chip as before.
10. Repeat 1–3 in the resize-tile editor (`KvTileOverlayEditor`) and, with the multi-board flag on, in the Fabric canvas.

- [ ] **Step 5: Push and open the PR**

```bash
git push -u origin feature/daffa/vc-kv-color-picker
```

Open a PR targeting `develop` titled `feat(web): KV canvas color picker + eyedropper`, linking the spec at `docs/superpowers/specs/2026-07-20-kv-color-picker-eyedropper-design.md`. Note in the body that the shapes and custom-fonts branches can adopt `ColorPicker` for `fill`, `stroke`, and gradient stops once they land.

---

## AMENDMENT — 2026-07-20, after Task 5

**The premise of Tasks 6 and 7 was wrong.** The spec and plan were written against a survey of the `feature/novi/vc-kv-editing-board-history` checkout, not `develop`. On `develop`:

- Commit `762a2c60` (2026-07-15, *"consolidate text fill (solid/gradient) into typography panel; remove floating color chips"*) removed **every** mount site of `OverlayColorChip`. It is orphaned dead code, and `KvTileOverlayEditor.tsx` carries a comment stating color editing moved to the properties panel.
- The live control is `src/components/studio/kv-generator/overlays/ColorField.tsx` — a swatch plus an inline popover already offering the eight presets (from the shared `overlays/overlayColors.ts`) **and** a hex input.
- `ColorField` is consumed by both `FillControls.tsx` (text fill) and `ShapeStyleControls.tsx` (shape fill and stroke), so a single integration covers font *and* shape color — what the original request asked for.

`develop` therefore already has presets and hex. What it lacks is exactly the two things this feature exists to add: the saturation/hue picker area and the eyedropper.

Tasks 1, 2 and 4 (`hexColor`, `recentColors`, `EyeDropperButton`) are unaffected and directly reusable. Task 5's `ColorPicker` was built as a canvas-anchored floating swatch with a `document.body` portal — a shape that no longer exists — but its popover *body* is precisely what `ColorField`'s popover needs.

**Decision (Daffa):** extract the panel, drop the shell. Tasks 6 and 7 below replace the original Task 6; the original Task 7 becomes Task 8 unchanged.

### Task 6 (replaces original Task 6): extract ColorPickerPanel, prune the homeless shell

**Files:**
- Create: `src/components/frndos/v2/ColorPickerPanel.tsx` + colocated test
- Delete: `src/components/frndos/v2/ColorPicker.tsx`, `ColorPicker.test.tsx`, `colorPickerPlacement.ts`, `colorPickerPlacement.test.ts`
- Modify: `src/components/frndos/v2/index.ts`

`ColorPickerPanel` is the popover body lifted verbatim from `ColorPicker`: the presets row, the recents row (omitted when empty), the `HexColorPicker` area, and the footer with `HexColorInput` plus `EyeDropperButton`. It renders a plain `<div>` with no positioning, no portal, and no open/close state — the host owns all of that.

Props: `{ value, onChange, presets?, recents?, className? }`. It keeps `ColorPicker`'s internal `SwatchRow` helper and its `sampling` state (the eyedropper still hides the panel while the native picker is open, via `EyeDropperButton`'s `onOpenChange`). `DEFAULT_COLOR_PRESETS` moves here.

The swatch button, portal, placement, `openRef`/`onCommit` machinery, and outside-click/Escape handling are all deleted — `ColorField` already implements the equivalents.

`colorPickerPlacement` goes with them: with no portal there is nothing to place. Its tests were green and its math correct; it is removed because it has no consumer, not because it was wrong.

### Task 7 (replaces original Task 7): wire ColorPickerPanel into ColorField

**Files:**
- Modify: `src/components/studio/kv-generator/overlays/ColorField.tsx`
- Modify/create: `ColorField.test.tsx`

`ColorField` keeps its shell — the swatch trigger, the inline absolutely-positioned popover, the outside-click and `Escape` handling, the `label` prop. Inside the popover, its hand-rolled presets grid and hex `<input>` are replaced by `<ColorPickerPanel>`, which supplies presets, recents, the picker area, hex input and eyedropper.

`ColorField` owns the recents list, exactly as the original plan had the KV wrapper own it: `readRecentColors()` on first open, `addRecentColor` + `writeRecentColors` on close. Because `ColorField` unmounts and remounts as panels change, the commit must happen on close **and** on unmount.

Presets continue to come from `overlays/overlayColors.ts` (`OVERLAY_PRESET_COLORS`), not from `DEFAULT_COLOR_PRESETS` — the KV surface keeps its own palette source, and the two lists are identical today.

Behavior to preserve: clicking a preset currently closes the popover immediately. Dragging the picker must NOT close it. Keep the preset-closes behavior as-is.

`OverlayColorChip.tsx` is left untouched — it is pre-existing dead code on `develop` and its removal is not this feature's business.

### Task 8

The original Task 7 (full verification), unchanged except that the manual e2e checklist now exercises the properties-panel `ColorField` for both a text overlay (via `FillControls`) and a shape overlay (via `ShapeStyleControls`), rather than a floating canvas chip.
