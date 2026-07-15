# KV Canvas Custom Fonts — Web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users pick a font family for KV text overlays — from a curated built-in set plus brand-uploaded OTF/TTF fonts — and have that font render on canvas and bake into the flattened export.

**Architecture:** Add one optional `fontFamily?` field to the text-overlay payload (default-safe). A canvas-agnostic loader registers custom fonts with the browser via the `FontFace` API before render and before flatten. Both canvases (Fabric primary, Konva fallback) read the field. A floating text toolbar surfaces a grouped font picker + upload, gated behind a fail-closed PostHog flag.

**Tech Stack:** Next.js 16, React 19, TypeScript, Zustand, TanStack Query v5, Fabric.js, Konva, Bun (`bun test`).

## Global Constraints

- Default family = **`"Geist"`** (the current hard-coded value). `payload.fontFamily === undefined` MUST render exactly as today.
- Feature flag key: **`KV_CUSTOM_FONTS: "show-kv-custom-fonts"`** in `web/src/lib/featureFlags/constants.ts`; gate via `useMajorFeatureFlag(MAJOR_FEATURE_FLAGS.KV_CUSTOM_FONTS)`, **fail-closed** (hide the control when off).
- Tests run with `bun test` (NOT vitest). The real build gate is `bun run build`.
- Upload accepts `.ttf,.otf` only, ≤ 5 MB (mirror the api limit client-side for UX).
- The final KV flattens **client-side** (`stage.toDataURL()`); fonts MUST be loaded before flatten or the PNG bakes the fallback face.

---

### Task 1: Add `fontFamily` to the text payload + `BrandFont` type

**Files:**
- Modify: `web/src/types/studio.ts:449-451` (text payload union) and add `BrandFont` type + preset payload field (`:490-492`).
- Test: `web/src/types/studio.fontFamily.test.ts`

**Interfaces:**
- Produces: text payload becomes `{ type: "text"; content: string; color: string; fontFamily?: string }`. New exported type `BrandFont = { id: string; brand_id: string; name: string; font_family: string; url: string; format: "ttf" | "otf"; file_size: number; original_filename: string; created_at: string; updated_at: string }`.

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect } from "bun:test";
import type { StudioOverlay, BrandFont } from "@/types/studio";

describe("text payload fontFamily", () => {
  it("accepts an optional fontFamily on text payload", () => {
    const o: StudioOverlay["payload"] = {
      type: "text",
      content: "Hi",
      color: "#fff",
      fontFamily: "bf_01H",
    };
    expect(o.type === "text" && o.fontFamily).toBe("bf_01H");
  });

  it("BrandFont carries a stable font_family id", () => {
    const f: BrandFont = {
      id: "1",
      brand_id: "b1",
      name: "Acme",
      font_family: "bf_01H",
      url: "https://x/x.ttf",
      format: "ttf",
      file_size: 1,
      original_filename: "Acme.ttf",
      created_at: "",
      updated_at: "",
    };
    expect(f.font_family).toBe("bf_01H");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/types/studio.fontFamily.test.ts`
Expected: FAIL (type error: `fontFamily` not on payload / `BrandFont` not exported).

- [ ] **Step 3: Edit `web/src/types/studio.ts`**

Change the text payload union member (line ~450) from:

```ts
    | { type: "text"; content: string; color: string }
```
to:
```ts
    | { type: "text"; content: string; color: string; fontFamily?: string }
```

Apply the SAME change to the `BrandOverlayPreset` payload member (line ~491). Then add near the other studio types:

```ts
/** A brand-scoped custom font (OTF/TTF) uploaded for KV canvas text overlays.
 *  `font_family` is the stable CSS family id the browser keys its FontFace on. */
export type BrandFont = {
  id: string;
  brand_id: string;
  name: string;
  font_family: string;
  url: string;
  format: "ttf" | "otf";
  file_size: number;
  original_filename: string;
  created_at: string;
  updated_at: string;
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/types/studio.fontFamily.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web/src/types/studio.ts web/src/types/studio.fontFamily.test.ts
git commit -m "feat(web): add optional fontFamily to text overlay payload + BrandFont type"
```

---

### Task 2: Built-in font registry + default family

**Files:**
- Create: `web/src/components/studio/kv-generator/fonts/fontDefaults.ts` (pure — no `next/font`; the default family other modules import)
- Create: `web/src/components/studio/kv-generator/fonts/builtinFonts.ts`
- Test: `web/src/components/studio/kv-generator/fonts/builtinFonts.test.ts`

**No layout change needed:** the root `web/src/app/layout.tsx` already mounts all
six font `.variable` classes (`spaceGrotesk neueMontreal archivo funnel
generalSans geist`) on `<body>` app-wide, so every built-in font is already
loaded for the KV canvas route. Do NOT add a font-loading wrapper to the KV
layout — a plain `<div>` around the full-screen canvas route risks breaking its
layout. Just confirm the root `<body>` classes are present.

**Interfaces:**
- Consumes: the `next/font` exports in `web/src/fonts/fonts.ts` (`neueMontreal`, `spaceGrotesk`, `archivo`, `funnel`, `generalSans` — the five non-Geist built-ins whose hashed families are read).
- Produces: `DEFAULT_FONT_FAMILY = "Geist"` (from `fontDefaults.ts`, re-exported by `builtinFonts.ts`); `BUILTIN_FONTS: Array<{ family: string; label: string }>`. The Geist built-in's `family` is the literal `"Geist"` (== `DEFAULT_FONT_FAMILY`); the other five use their `next/font` `.style.fontFamily`.

- [ ] **Step 1: Write the failing test**

IMPORTANT — `next/font` is a build-time transform: importing `@/fonts/fonts`
throws under bare `bun test` ("Missing 'default' export in module
'next/font/local'"). So the pure default lives in its own module
(`fontDefaults.ts`, no `next/font` import) and any test that must import the
`next/font`-backed registry MUST `mock.module("@/fonts/fonts", ...)` before a
dynamic import. `resolveFamily` (Task 6) and the canvases import the default
from `fontDefaults`, NOT from `builtinFonts`, so they stay testable without the mock.

```ts
// builtinFonts.test.ts
import { describe, it, expect, mock } from "bun:test";

// next/font is a build-time transform — stub it so this test can load the
// registry under bun test. Must run before the dynamic import below.
mock.module("@/fonts/fonts", () => ({
  geist: { style: { fontFamily: "__geist_hash" }, variable: "font-geist" },
  neueMontreal: { style: { fontFamily: "__nm_hash" }, variable: "font-nm" },
  spaceGrotesk: { style: { fontFamily: "__sg_hash" }, variable: "font-sg" },
  archivo: { style: { fontFamily: "__ar_hash" }, variable: "font-ar" },
  funnel: { style: { fontFamily: "__fn_hash" }, variable: "font-fn" },
  generalSans: { style: { fontFamily: "__gs_hash" }, variable: "font-gs" },
}));

const { BUILTIN_FONTS } = await import("./builtinFonts");
const { DEFAULT_FONT_FAMILY } = await import("./fontDefaults");

describe("builtin fonts", () => {
  it("defaults to Geist and includes it as a built-in", () => {
    expect(DEFAULT_FONT_FAMILY).toBe("Geist");
    // The Geist entry uses the literal "Geist" family (proven to render on
    // canvas today), so it equals the default regardless of next/font hashing.
    expect(BUILTIN_FONTS.some((f) => f.family === DEFAULT_FONT_FAMILY)).toBe(true);
  });

  it("exposes a non-empty label + family for each built-in", () => {
    for (const f of BUILTIN_FONTS) {
      expect(f.label.length).toBeGreaterThan(0);
      expect(f.family.length).toBeGreaterThan(0);
    }
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/fonts/builtinFonts.test.ts`
Expected: FAIL ("Cannot find module './builtinFonts'").

- [ ] **Step 3a: Write the pure default module**

Create `web/src/components/studio/kv-generator/fonts/fontDefaults.ts` (NO `next/font` import — safe to import from canvases and `resolveFamily`):

```ts
/** The family used when a text overlay has no explicit fontFamily.
 *  Matches the literal value both canvases hard-coded before this feature —
 *  known to render on the KV canvas today. Kept free of any next/font import
 *  so canvas + resolveFamily code stays unit-testable. */
export const DEFAULT_FONT_FAMILY = "Geist";
```

- [ ] **Step 3b: Write the registry**

Create `web/src/components/studio/kv-generator/fonts/builtinFonts.ts`:

```ts
import {
  neueMontreal,
  spaceGrotesk,
  archivo,
  funnel,
  generalSans,
} from "@/fonts/fonts";
import { DEFAULT_FONT_FAMILY } from "./fontDefaults";

export { DEFAULT_FONT_FAMILY };

/** Built-in fonts offered in the picker. `family` is the CSS family string the
 *  canvas + picker preview render with — all six are already loaded app-wide by
 *  the root layout's `<body>` font variables. The Geist entry uses the literal
 *  "Geist" (== DEFAULT_FONT_FAMILY, proven to render today); the others use
 *  their next/font hashed family. */
export const BUILTIN_FONTS: Array<{ family: string; label: string }> = [
  { family: DEFAULT_FONT_FAMILY, label: "Geist" },
  { family: neueMontreal.style.fontFamily, label: "Neue Montreal" },
  { family: spaceGrotesk.style.fontFamily, label: "Space Grotesk" },
  { family: archivo.style.fontFamily, label: "Archivo" },
  { family: funnel.style.fontFamily, label: "Funnel Sans" },
  { family: generalSans.style.fontFamily, label: "General Sans" },
];
```

Note: the non-Geist built-ins render via their next/font hashed family names, which resolve because the root layout already loads them. Confirm they actually render on canvas during Task 8 manual e2e; if a hashed name doesn't resolve, that font needs explicit `FontFace` loading like the custom ones.

- [ ] **Step 4: Confirm the fonts are loaded (no code change)**

Open `web/src/app/layout.tsx` and confirm the `<body>` className still includes all six font `.variable` values (`spaceGrotesk neueMontreal archivo funnel generalSans geist`). It does today — so no layout edit is needed. If any were removed, add the missing ones back to the root `<body>` (not to the KV layout).

- [ ] **Step 5: Run test to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/fonts/builtinFonts.test.ts`
Expected: PASS.

- [ ] **Step 5b: Verify the registry compiles with real next/font**

`bun test` uses the mock, so also confirm the real module type-checks/builds:
Run: `cd web && bun run build` (or, faster, `bunx tsc --noEmit` if the project supports it)
Expected: no type errors from the new font modules. (If `bun run build` is too slow/flaky in the worktree, a `tsc --noEmit` scoped check is acceptable — note which you ran in the report.)

- [ ] **Step 6: Commit**

```bash
git add web/src/components/studio/kv-generator/fonts/fontDefaults.ts web/src/components/studio/kv-generator/fonts/builtinFonts.ts web/src/components/studio/kv-generator/fonts/builtinFonts.test.ts
git commit -m "feat(web): add built-in font registry for KV canvas"
```

---

### Task 3: Custom-font loader (`FontFace` API, idempotent)

**Files:**
- Create: `web/src/components/studio/kv-generator/fonts/fontLoader.ts`
- Test: `web/src/components/studio/kv-generator/fonts/fontLoader.test.ts`

**Interfaces:**
- Consumes: `BrandFont` (Task 1).
- Produces:
  - `registerBrandFonts(fonts: BrandFont[]): Promise<void>` — for each font not already registered, `new FontFace(font.font_family, `url("${font.url}")`)`, `.load()`, then `document.fonts.add(face)`. Idempotent via a module-level `Set<string>` of registered families. A single face that fails to load is swallowed (logged once) and does not reject the batch.
  - `isFamilyRegistered(family: string): boolean`.

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect, beforeEach, mock } from "bun:test";
import { registerBrandFonts, isFamilyRegistered } from "./fontLoader";
import type { BrandFont } from "@/types/studio";

function font(id: string): BrandFont {
  return {
    id,
    brand_id: "b1",
    name: id,
    font_family: `bf_${id}`,
    url: `https://x/${id}.ttf`,
    format: "ttf",
    file_size: 1,
    original_filename: `${id}.ttf`,
    created_at: "",
    updated_at: "",
  };
}

describe("fontLoader", () => {
  let loadCount = 0;
  beforeEach(() => {
    loadCount = 0;
    // Minimal FontFace + document.fonts stubs.
    (globalThis as any).FontFace = class {
      family: string;
      constructor(family: string) {
        this.family = family;
      }
      load() {
        loadCount += 1;
        return Promise.resolve(this);
      }
    };
    (globalThis as any).document = { fonts: { add: () => {} } };
  });

  it("registers each family once", async () => {
    await registerBrandFonts([font("a"), font("b")]);
    expect(isFamilyRegistered("bf_a")).toBe(true);
    expect(loadCount).toBe(2);

    await registerBrandFonts([font("a")]); // already registered
    expect(loadCount).toBe(2); // no extra load
  });

  it("does not reject when one face fails to load", async () => {
    (globalThis as any).FontFace = class {
      family: string;
      constructor(family: string) {
        this.family = family;
      }
      load() {
        return Promise.reject(new Error("network"));
      }
    };
    await registerBrandFonts([font("c")]); // must resolve, not throw
    expect(isFamilyRegistered("bf_c")).toBe(false);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/fonts/fontLoader.test.ts`
Expected: FAIL ("Cannot find module './fontLoader'").

- [ ] **Step 3: Write the loader**

```ts
import type { BrandFont } from "@/types/studio";

const registered = new Set<string>();

export function isFamilyRegistered(family: string): boolean {
  return registered.has(family);
}

/** Register brand fonts with the browser so canvas text can render in them.
 *  Idempotent; a single failed face is logged and skipped (never rejects). */
export async function registerBrandFonts(fonts: BrandFont[]): Promise<void> {
  const pending = fonts.filter((f) => !registered.has(f.font_family));
  await Promise.all(
    pending.map(async (f) => {
      try {
        const face = new FontFace(f.font_family, `url("${f.url}")`);
        await face.load();
        (document as unknown as { fonts: FontFaceSet }).fonts.add(face);
        registered.add(f.font_family);
      } catch (err) {
        // Non-fatal: the overlay falls back to the default family.
        console.warn(`[kv-fonts] failed to load ${f.font_family}`, err);
      }
    }),
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/fonts/fontLoader.test.ts`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add web/src/components/studio/kv-generator/fonts/fontLoader.ts web/src/components/studio/kv-generator/fonts/fontLoader.test.ts
git commit -m "feat(web): add idempotent FontFace loader for brand fonts"
```

---

### Task 4: `useBrandFonts` query + font service (list/upload/delete)

**Files:**
- Modify: `web/src/services/kv/api.ts` — add the three font service functions next to the existing overlay-preset functions (around line 528). This is the established location: `api.ts` holds ALL KV service functions and already has the shared `axiosInstance` import and the `unwrap()` helper.
- Create: `web/src/hooks/useBrandFonts.ts`
- Test: `web/src/hooks/useBrandFonts.test.ts`

**Conventions to match (verified in the codebase — use these EXACT patterns):**
- HTTP client: `import axiosInstance from "@/services/axios";` (NOT `@/lib/api`).
- Response unwrap: the local `unwrap<T>(response)` helper in `api.ts` extracts the `{ data }` envelope. Use it: `const { data } = await axiosInstance.get(url); return unwrap<BrandFont[]>(data);`.
- URL prefix: `v1/studio/...` — mirroring the sibling overlay-presets calls (`v1/studio/brands/${brandId}/overlay-presets`, `v1/studio/overlay-presets/${id}`).
- Multipart POST: `new FormData()` + `axiosInstance.post(url, formData, { headers: { "Content-Type": "multipart/form-data" } })`.
- `BrandFont` is already snake_case matching the api response, so NO wire→model mapper is needed (unlike siblings that map WireX→X) — `unwrap<BrandFont[]>` / `unwrap<BrandFont>` directly.
- Query key convention (sibling `useBrandOverlayPresets` uses `["studio", "brand-overlay-presets", brandId]`): use `["studio", "brand-fonts", brandId]`.

**Interfaces:**
- Consumes: `BrandFont` (Task 1), `axiosInstance`, `unwrap` (both already in `api.ts`).
- Produces (exported from `api.ts`):
  - `listBrandFonts(brandId: string): Promise<BrandFont[]>` → `GET v1/studio/brands/{brandId}/fonts`.
  - `uploadBrandFont(brandId: string, name: string, file: File): Promise<BrandFont>` → `POST v1/studio/brands/{brandId}/fonts` (multipart `name`,`file`).
  - `deleteBrandFont(fontId: string): Promise<void>` → `DELETE v1/studio/fonts/{fontId}`.
  - From `useBrandFonts.ts`: `brandFontsQueryKey(brandId)` → `["studio", "brand-fonts", brandId]`; `useBrandFonts(brandId: string | null)` TanStack Query, `enabled: !!brandId`.

- [ ] **Step 1: Write the failing test (query-key shape)**

The test targets only the pure `brandFontsQueryKey` so it needs no api client. If importing `useBrandFonts.ts` transitively loads the axios client and that breaks under bun test, `mock.module("@/services/kv/api", () => ({ listBrandFonts: async () => [] }))` before a dynamic import — but try the plain static import first; it likely works.

```ts
import { describe, it, expect } from "bun:test";
import { brandFontsQueryKey } from "./useBrandFonts";

describe("useBrandFonts", () => {
  it("builds a stable, studio-scoped query key", () => {
    expect(brandFontsQueryKey("b1")).toEqual(["studio", "brand-fonts", "b1"]);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/hooks/useBrandFonts.test.ts`
Expected: FAIL ("Cannot find module './useBrandFonts'").

- [ ] **Step 3: Add the service functions to `api.ts`**

First open `web/src/services/kv/api.ts` and read the overlay-preset functions (~line 520-550) + the `unwrap` helper (~line 55) to copy the exact style. Then add near them:

```ts
export async function listBrandFonts(brandId: string): Promise<BrandFont[]> {
  const { data } = await axiosInstance.get(
    `v1/studio/brands/${brandId}/fonts`,
  );
  return unwrap<BrandFont[]>(data);
}

export async function uploadBrandFont(
  brandId: string,
  name: string,
  file: File,
): Promise<BrandFont> {
  const formData = new FormData();
  formData.append("name", name);
  formData.append("file", file);
  const { data } = await axiosInstance.post(
    `v1/studio/brands/${brandId}/fonts`,
    formData,
    { headers: { "Content-Type": "multipart/form-data" } },
  );
  return unwrap<BrandFont>(data);
}

export async function deleteBrandFont(fontId: string): Promise<void> {
  await axiosInstance.delete(`v1/studio/fonts/${fontId}`);
}
```

Add `BrandFont` to the `@/types/studio` import already present in `api.ts` (extend the existing import list rather than adding a second import statement).

- [ ] **Step 4: Write the hook**

```ts
import { useQuery } from "@tanstack/react-query";
import { listBrandFonts } from "@/services/kv/api";

export function brandFontsQueryKey(brandId: string) {
  return ["studio", "brand-fonts", brandId] as const;
}

export function useBrandFonts(brandId: string | null) {
  return useQuery({
    queryKey: brandFontsQueryKey(brandId ?? ""),
    queryFn: () => listBrandFonts(brandId!),
    enabled: !!brandId,
    staleTime: 5 * 60 * 1000,
  });
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd web && bun test src/hooks/useBrandFonts.test.ts`
Expected: PASS. Then `bunx tsc --noEmit -p tsconfig.json` to confirm the `api.ts` additions type-check (compare against pre-existing repo errors — no NEW errors from the font functions).

- [ ] **Step 6: Commit**

```bash
git add web/src/services/kv/api.ts web/src/hooks/useBrandFonts.ts web/src/hooks/useBrandFonts.test.ts
git commit -m "feat(web): add brand fonts service + query hook"
```

---

### Task 5: Flatten guard — await fonts before `toDataURL`

**Files:**
- Modify: `web/src/components/studio/kv-generator/overlays/exportFlatten.ts`
- Test: `web/src/components/studio/kv-generator/overlays/exportFlatten.fonts.test.ts`

**Interfaces:**
- Produces: `flattenStageToBlob` now `await ensureFontsReady()` before `stage.toDataURL()`. New exported `ensureFontsReady(): Promise<void>` — `await document.fonts.ready` (guarded for environments without `document.fonts`).

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect, mock } from "bun:test";
import { ensureFontsReady } from "./exportFlatten";

describe("ensureFontsReady", () => {
  it("awaits document.fonts.ready when present", async () => {
    let awaited = false;
    (globalThis as any).document = {
      fonts: { ready: Promise.resolve().then(() => (awaited = true)) },
    };
    await ensureFontsReady();
    expect(awaited).toBe(true);
  });

  it("no-ops when document.fonts is absent", async () => {
    (globalThis as any).document = {};
    await ensureFontsReady(); // must not throw
    expect(true).toBe(true);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/overlays/exportFlatten.fonts.test.ts`
Expected: FAIL ("ensureFontsReady is not exported").

- [ ] **Step 3: Edit `exportFlatten.ts`**

Add the helper and call it inside `flattenStageToBlob` before `stage.toDataURL()`:

```ts
/** Resolve once every registered font face is loaded, so a flatten never
 *  bakes the fallback font into the exported PNG. Safe in non-DOM envs. */
export async function ensureFontsReady(): Promise<void> {
  const fonts = (document as unknown as { fonts?: FontFaceSet }).fonts;
  if (fonts?.ready) {
    await fonts.ready;
  }
}
```

In `flattenStageToBlob`, add `await ensureFontsReady();` as the first line of the function body (before computing `pixelRatio`).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/overlays/exportFlatten.fonts.test.ts`
Expected: PASS (both).

- [ ] **Step 5: Commit**

```bash
git add web/src/components/studio/kv-generator/overlays/exportFlatten.ts web/src/components/studio/kv-generator/overlays/exportFlatten.fonts.test.ts
git commit -m "feat(web): await fonts ready before flattening KV overlays"
```

---

### Task 6: Render the chosen font in both canvases

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvFabricCanvas.tsx:986-996` (create) and the Textbox update path (~`:973-980`).
- Modify: `web/src/components/studio/kv-generator/KvKonvaCanvas.tsx:1801-1818` (overlay `<Text>`).
- Both canvases: on mount and when `overlays` change, call `registerBrandFonts` for the brand's fonts, then re-render.
- Modify: the parent (`KvGeneratorLayout` / `KvCanvas`) to pass the brand fonts down (or call `registerBrandFonts` centrally — see Task 7).
- Test: `web/src/components/studio/kv-generator/fonts/resolveFamily.test.ts` + `resolveFamily.ts`

**Interfaces:**
- Consumes: `DEFAULT_FONT_FAMILY` from `./fontDefaults` (Task 2 — the pure module, NOT `builtinFonts`, so this stays importable under `bun test` without the `@/fonts/fonts` mock), `registerBrandFonts` (Task 3).
- Produces: `resolveOverlayFamily(payload): string` — returns `payload.fontFamily ?? DEFAULT_FONT_FAMILY` for text payloads, `DEFAULT_FONT_FAMILY` otherwise. Both canvases use it.

- [ ] **Step 1: Write the failing test**

```ts
import { describe, it, expect } from "bun:test";
import { resolveOverlayFamily } from "./resolveFamily";

describe("resolveOverlayFamily", () => {
  it("uses the payload family when set", () => {
    expect(resolveOverlayFamily({ type: "text", content: "x", color: "#fff", fontFamily: "bf_1" })).toBe("bf_1");
  });
  it("falls back to Geist when unset", () => {
    expect(resolveOverlayFamily({ type: "text", content: "x", color: "#fff" })).toBe("Geist");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/fonts/resolveFamily.test.ts`
Expected: FAIL ("Cannot find module './resolveFamily'").

- [ ] **Step 3: Write `resolveFamily.ts`**

```ts
import type { StudioOverlay } from "@/types/studio";
import { DEFAULT_FONT_FAMILY } from "./fontDefaults";

export function resolveOverlayFamily(payload: StudioOverlay["payload"]): string {
  if (payload.type === "text" && payload.fontFamily) {
    return payload.fontFamily;
  }
  return DEFAULT_FONT_FAMILY;
}
```

- [ ] **Step 4: Wire Fabric** (`KvFabricCanvas.tsx`)

In the create branch (~line 986) replace `fontFamily: "Geist"` with:

```ts
fontFamily: resolveOverlayFamily(overlay.payload),
```

In the update branch where an existing `fabric.Textbox` is repositioned/restyled (~line 973-980), add to its `.set({...})`:

```ts
fontFamily: resolveOverlayFamily(overlay.payload),
```

Import at the top: `import { resolveOverlayFamily } from "./fonts/resolveFamily";`

- [ ] **Step 5: Wire Konva** (`KvKonvaCanvas.tsx`)

On the overlay `<Text>` at line ~1801, add the prop:

```tsx
fontFamily={resolveOverlayFamily(overlay.payload)}
```

Import: `import { resolveOverlayFamily } from "./fonts/resolveFamily";`
(Leave the UI-chrome `<Text fontFamily="Geist">` nodes untouched — only the overlay content text changes.)

- [ ] **Step 6: Run test + build**

Run: `cd web && bun test src/components/studio/kv-generator/fonts/resolveFamily.test.ts`
Expected: PASS.
Run: `cd web && bun run build`
Expected: build succeeds (type-checks the canvas edits).

- [ ] **Step 7: Commit**

```bash
git add web/src/components/studio/kv-generator/fonts/resolveFamily.ts web/src/components/studio/kv-generator/fonts/resolveFamily.test.ts web/src/components/studio/kv-generator/KvFabricCanvas.tsx web/src/components/studio/kv-generator/KvKonvaCanvas.tsx
git commit -m "feat(web): render selected font family in Fabric + Konva overlays"
```

---

### Task 7: Feature flag + font toolbar (picker + upload + delete)

**Files:**
- Modify: `web/src/lib/featureFlags/constants.ts` (add `KV_CUSTOM_FONTS`).
- Create: `web/src/components/studio/kv-generator/KvTextFontToolbar.tsx`
- Modify: `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx` — mount the toolbar when a text overlay is selected (has `brandId` @ ~line 277, `overlays`, `selectedOverlayId`, `onUpdateOverlay`), and call `registerBrandFonts(useBrandFonts(brandId).data ?? [])` in an effect so custom faces load for the canvas.
- Test: `web/src/components/studio/kv-generator/KvTextFontToolbar.test.tsx`

**Interfaces:**
- Consumes: `useBrandFonts` (Task 4), `uploadBrandFont`/`deleteBrandFont` (Task 4), `registerBrandFonts` (Task 3), `BUILTIN_FONTS` (Task 2), `useMajorFeatureFlag`.
- Produces: `KvTextFontToolbar` props `{ brandId: string; currentFamily: string | undefined; onSelectFamily: (family: string | undefined) => void }`. Selecting a built-in labeled "Geist" emits `undefined` (keep the default-safe payload); any other selection emits the concrete family.

- [ ] **Step 1: Add the flag constant**

In `web/src/lib/featureFlags/constants.ts`, add inside `MAJOR_FEATURE_FLAGS`:

```ts
  KV_CUSTOM_FONTS: "show-kv-custom-fonts",
```

- [ ] **Step 2: Write the failing test**

Mock rules (bun): all `mock.module` calls must run BEFORE the component is
loaded, so import `KvTextFontToolbar` via a post-mock dynamic `await import`
(NOT a static top import). `@/fonts/fonts` must be mocked (the toolbar imports
`BUILTIN_FONTS` → `@/fonts/fonts`, which throws under bun test). The component
calls `useQueryClient()`, so wrap the render in a real `QueryClientProvider`.
The test asserts "Geist" is visible — the toolbar's trigger must display the
current family's label (default "Geist" when `currentFamily` is undefined), so
this passes without opening the menu.

```tsx
import { describe, it, expect, mock } from "bun:test";
import { render, screen } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";

// next/font throws under bun test — stub the fonts module the registry reads.
mock.module("@/fonts/fonts", () => ({
  geist: { style: { fontFamily: "__g" }, variable: "v-g" },
  neueMontreal: { style: { fontFamily: "__nm" }, variable: "v-nm" },
  spaceGrotesk: { style: { fontFamily: "__sg" }, variable: "v-sg" },
  archivo: { style: { fontFamily: "__ar" }, variable: "v-ar" },
  funnel: { style: { fontFamily: "__fn" }, variable: "v-fn" },
  generalSans: { style: { fontFamily: "__gs" }, variable: "v-gs" },
}));
mock.module("@/lib/featureFlags", () => ({
  useMajorFeatureFlag: () => true,
  MAJOR_FEATURE_FLAGS: { KV_CUSTOM_FONTS: "show-kv-custom-fonts" },
}));
mock.module("@/hooks/useBrandFonts", () => ({
  useBrandFonts: () => ({ data: [] }),
  brandFontsQueryKey: (b: string) => ["studio", "brand-fonts", b],
}));
// The toolbar imports upload/delete from the heavy kv api module — stub it.
mock.module("@/services/kv/api", () => ({
  uploadBrandFont: async () => ({}),
  deleteBrandFont: async () => undefined,
}));

// Load the component AFTER the mocks are registered.
const { KvTextFontToolbar } = await import("./KvTextFontToolbar");

describe("KvTextFontToolbar", () => {
  it("renders the current font label (Geist) when enabled", () => {
    const qc = new QueryClient();
    render(
      <QueryClientProvider client={qc}>
        <KvTextFontToolbar brandId="b1" currentFamily={undefined} onSelectFamily={() => {}} />
      </QueryClientProvider>,
    );
    expect(screen.getByText("Geist")).toBeInTheDocument();
  });
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/KvTextFontToolbar.test.tsx`
Expected: FAIL ("Cannot find module './KvTextFontToolbar'").

- [ ] **Step 4: Write the toolbar**

Build with existing frndOS v2 components (dropdown/menu, button) — check `frndos-components-v2` for the dropdown primitive before writing custom markup. The component:
- Returns `null` when `useMajorFeatureFlag(MAJOR_FEATURE_FLAGS.KV_CUSTOM_FONTS)` is false (fail-closed).
- Renders a dropdown with two groups: **Brand fonts** (`useBrandFonts(brandId).data`, each row `style={{ fontFamily: f.font_family }}` preview + a delete affordance calling `deleteBrandFont` then invalidating `brandFontsQueryKey(brandId)`) and **Built-in** (`BUILTIN_FONTS`, each row `style={{ fontFamily: family }}`).
- An **Upload font** item: hidden `<input type="file" accept=".ttf,.otf">`; on change validates ≤ 5 MB, calls `uploadBrandFont(brandId, file.name.replace(/\.(ttf|otf)$/i, ""), file)`, then `registerBrandFonts([created])`, invalidates the query, and calls `onSelectFamily(created.font_family)`. Show an inline error on 422 / oversize. Include one line of copy: "Only upload fonts you have the rights to use."
- Selecting a built-in whose label is "Geist" ⇒ `onSelectFamily(undefined)`; any other ⇒ `onSelectFamily(family)`.
- The dropdown **trigger** shows the current family's display label so it's visible without opening the menu: resolve `currentFamily` to a label — a brand font's `name` (match `brandFonts` by `font_family`), else a built-in's `label` (match `BUILTIN_FONTS` by `family`), else `"Geist"` (the default when `currentFamily` is undefined or unmatched).

```tsx
"use client";

import { useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useMajorFeatureFlag, MAJOR_FEATURE_FLAGS } from "@/lib/featureFlags";
import { useBrandFonts, brandFontsQueryKey } from "@/hooks/useBrandFonts";
import { uploadBrandFont, deleteBrandFont } from "@/services/kv/api";
import { registerBrandFonts } from "./fonts/fontLoader";
import { BUILTIN_FONTS, DEFAULT_FONT_FAMILY } from "./fonts/builtinFonts";

const MAX_BYTES = 5 * 1024 * 1024;

export function KvTextFontToolbar({
  brandId,
  currentFamily,
  onSelectFamily,
}: {
  brandId: string;
  currentFamily: string | undefined;
  onSelectFamily: (family: string | undefined) => void;
}) {
  const enabled = useMajorFeatureFlag(MAJOR_FEATURE_FLAGS.KV_CUSTOM_FONTS);
  const { data: brandFonts } = useBrandFonts(brandId);
  const qc = useQueryClient();
  const fileRef = useRef<HTMLInputElement | null>(null);
  const [error, setError] = useState<string | null>(null);

  if (!enabled) return null;

  async function onFile(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    e.target.value = "";
    if (!file) return;
    if (file.size > MAX_BYTES) {
      setError("Font must be 5 MB or smaller.");
      return;
    }
    setError(null);
    try {
      const created = await uploadBrandFont(
        brandId,
        file.name.replace(/\.(ttf|otf)$/i, ""),
        file,
      );
      await registerBrandFonts([created]);
      qc.invalidateQueries({ queryKey: brandFontsQueryKey(brandId) });
      onSelectFamily(created.font_family);
    } catch {
      setError("Upload failed. Use a valid OTF or TTF under 5 MB.");
    }
  }

  async function onDelete(fontId: string) {
    await deleteBrandFont(fontId);
    qc.invalidateQueries({ queryKey: brandFontsQueryKey(brandId) });
  }

  // Render with a frndOS v2 dropdown/menu. Structure:
  //  - group "Brand fonts": (brandFonts ?? []).map(f => row previewed in f.font_family,
  //       click -> onSelectFamily(f.font_family); trailing delete -> onDelete(f.id))
  //  - group "Built-in": BUILTIN_FONTS.map(({family,label}) => row previewed in family,
  //       click -> onSelectFamily(label === "Geist" ? undefined : family))
  //  - action "Upload font" -> fileRef.current?.click()
  //  - hidden <input ref={fileRef} type="file" accept=".ttf,.otf" onChange={onFile} />
  //  - {error && <p role="alert">{error}</p>}
  //  - helper copy: "Only upload fonts you have the rights to use."
  //  - highlight the row matching currentFamily ?? DEFAULT_FONT_FAMILY
  return null; // replace with the dropdown markup described above
}
```

Replace the `return null` placeholder with real dropdown markup per the comment (the test only asserts "Geist" is present, so the built-in group must render its labels).

- [ ] **Step 5: Mount in the layout + load custom faces**

In `KvGeneratorLayout.tsx`:
- Add an effect: `const { data: brandFonts } = useBrandFonts(brandId); useEffect(() => { if (brandFonts?.length) registerBrandFonts(brandFonts); }, [brandFonts]);` so custom faces load for canvas rendering.
- Where a text overlay is selected, render:

```tsx
{selectedOverlay?.type === "text" && brandId && (
  <KvTextFontToolbar
    brandId={brandId}
    currentFamily={selectedOverlay.payload.type === "text" ? selectedOverlay.payload.fontFamily : undefined}
    onSelectFamily={(family) =>
      onUpdateOverlay(selectedOverlay.id, {
        payload: { ...selectedOverlay.payload, fontFamily: family },
      })
    }
  />
)}
```

(`selectedOverlay` = `overlays.find(o => o.id === selectedOverlayId)`. Reuse whatever the layout already computes for the selected overlay.)

- [ ] **Step 6: Run test + build**

Run: `cd web && bun test src/components/studio/kv-generator/KvTextFontToolbar.test.tsx`
Expected: PASS.
Run: `cd web && bun run build`
Expected: build succeeds.

- [ ] **Step 7: Commit**

```bash
git add web/src/lib/featureFlags/constants.ts web/src/components/studio/kv-generator/KvTextFontToolbar.tsx web/src/components/studio/kv-generator/KvTextFontToolbar.test.tsx web/src/components/studio/kv-generator/KvGeneratorLayout.tsx
git commit -m "feat(web): add KV text font toolbar with picker, upload, and delete"
```

---

### Task 8: Analytics + manual verification

**Files:**
- Modify: `KvTextFontToolbar.tsx` — add PostHog events per `frndos-analytics-events` (snake_case): `kv_font_selected` (`{ source: "builtin" | "custom" }`), `kv_font_uploaded` (`{ format, file_size }`), `kv_font_deleted`.

- [ ] **Step 1: Add typed events**

Follow the `frndos-analytics-events` skill: use the typed capture wrapper, fire `kv_font_selected` in `onSelectFamily`, `kv_font_uploaded` after a successful upload, `kv_font_deleted` after delete.

- [ ] **Step 2: Manual e2e (record in the track file)**

With the `show-kv-custom-fonts` flag ON for your user:
1. Select a text overlay → toolbar appears.
2. Pick a built-in font → canvas text re-renders in it.
3. Upload a `.ttf` → it appears under "Brand fonts", auto-selects, canvas re-renders.
4. Reload the file → overlay still renders in the uploaded font (loader re-registers).
5. Download/flatten → exported PNG shows the custom font (not the fallback).
6. Delete the font → overlay falls back to Geist.
7. Flag OFF → toolbar hidden, overlay renders in default. 

- [ ] **Step 3: Commit**

```bash
git add web/src/components/studio/kv-generator/KvTextFontToolbar.tsx
git commit -m "feat(web): add analytics events for KV custom fonts"
```

---

## Self-Review

- **Spec coverage:** payload field (Task 1) ✓; built-in set + default (Task 2) ✓; custom-font loading via FontFace (Task 3) ✓; brand-scoped list/upload/delete (Task 4) ✓; flatten-awaits-fonts (Task 5) ✓; render parity Fabric+Konva (Task 6) ✓; picker toolbar + upload + delete + fail-closed flag + licensing copy (Task 7) ✓; analytics + manual e2e (Task 8) ✓.
- **Placeholders:** the only intentional "fill-in" is Task 7's dropdown markup, delegated to `frndos-components-v2` primitives with an exact structural spec + working logic; all other steps contain complete code.
- **Type consistency:** `resolveOverlayFamily`, `registerBrandFonts`, `isFamilyRegistered`, `ensureFontsReady`, `brandFontsQueryKey`, `DEFAULT_FONT_FAMILY`, `BUILTIN_FONTS`, `BrandFont.font_family` are named identically everywhere they're consumed. `onSelectFamily(undefined)` for the Geist/default case keeps existing overlays on the default-safe payload.
- **Cross-service contract:** web `BrandFont` shape matches the api `BrandFontResource` (`font_family`, `url`, `format`, `file_size`, `original_filename`) exactly.
