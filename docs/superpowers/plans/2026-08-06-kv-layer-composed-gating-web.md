# KV Layer-Composed Gating — web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tell the user why a layer-composed KV cannot be crafted or upscaled, and disable those affordances, instead of letting them fire a request the server now refuses.

**Architecture:** api marks such generations `craft_supported: false` with `craft_blocked_reason: "layer_composed"`. Web already has the disabled plumbing for the extreme-ratio case in `craftBaseRatio.ts`; this widens it to be reason-aware and reuses it for the upscale entry points.

**Tech Stack:** Next.js 16, React 19, TypeScript, `bun test`.

Spec: `docs/superpowers/specs/2026-08-06-kv-layer-composed-resize-design.md`, section **"Phase 2 — revised after Phase 1 shipped"**.
Companion plan: `docs/superpowers/plans/2026-08-06-kv-layer-composed-gating-api.md` — **Task 1 there must be merged first**, since nothing sets `craft_blocked_reason` until it is.
Branch: `feature/daffa/vc-kv-layer-composed-resize` (already checked out; continues Phase 1).

## Global Constraints

- The reason values are exactly `"extreme_ratio"` and `"layer_composed"`. A missing or unrecognised reason means **not blocked** — older generations predate the field and must keep working.
- Chat must stay usable for a layer-composed KV. Only image generation and upscale are blocked.
- Run tests with `bun test <path>` from `web/`. There is no `test` script in package.json.
- `screen.*` from Testing Library is broken repo-wide under bun. Use `within(document.body)` in component tests.
- `bun run build` does NOT type-check (`ignoreBuildErrors: true`). For type confidence run `npx tsc --noEmit` and compare only the files you touched against the ~786-error pre-existing baseline.
- A dev server may be live against this working tree; ignore transient hot-reload errors and judge by test output.

---

### Task 1: Make the craft gate reason-aware

**Files:**
- Modify: `web/src/lib/studio/kv/craftBaseRatio.ts`
- Test: `web/src/lib/studio/kv/craftBaseRatio.test.ts` (exists — append)

**Interfaces:**
- Consumes: `generation.metadata.craft_supported` and `.craft_blocked_reason` from the api plan's Task 1.
- Produces: `craftBlockedReason(gen): CraftBlockedReason | null` and `isCraftBlocked(gen): boolean`, where `type CraftBlockedReason = "extreme_ratio" | "layer_composed"`. Tasks 2 and 3 use both.

`isUploadedBaseUnsupported` stays exported and unchanged so nothing breaks mid-plan; Task 2 migrates its call sites.

- [ ] **Step 1: Read the existing test file first**

Open `craftBaseRatio.test.ts` and match its fixture style — build your `KvGeneration` fixtures the same way it already does rather than inventing a second shape.

- [ ] **Step 2: Write the failing tests**

Append to `craftBaseRatio.test.ts`:

```ts
describe("craftBlockedReason", () => {
  it("reports layer_composed for a PSD import", () => {
    const gen = makeGen({
      imported_from_upload: true,
      craft_supported: false,
      craft_blocked_reason: "layer_composed",
    });

    expect(craftBlockedReason(gen)).toBe("layer_composed");
    expect(isCraftBlocked(gen)).toBe(true);
  });

  it("reports extreme_ratio for an unsupported aspect", () => {
    const gen = makeGen({
      imported_from_upload: true,
      craft_supported: false,
      craft_blocked_reason: "extreme_ratio",
    });

    expect(craftBlockedReason(gen)).toBe("extreme_ratio");
    expect(isCraftBlocked(gen)).toBe(true);
  });

  it("is not blocked for a supported upload", () => {
    const gen = makeGen({ imported_from_upload: true, craft_supported: true });

    expect(craftBlockedReason(gen)).toBeNull();
    expect(isCraftBlocked(gen)).toBe(false);
  });

  it("is not blocked for a normal AI generation or a null generation", () => {
    expect(isCraftBlocked(makeGen({}))).toBe(false);
    expect(isCraftBlocked(null)).toBe(false);
    expect(craftBlockedReason(null)).toBeNull();
  });

  it("treats an unrecognised reason as not blocked", () => {
    const gen = makeGen({
      imported_from_upload: true,
      craft_supported: false,
      craft_blocked_reason: "something_new",
    });

    expect(craftBlockedReason(gen)).toBeNull();
  });
});
```

Replace `makeGen({...})` with whatever fixture helper the existing file uses (or add one that builds a `KvGeneration` with the given `metadata`). The last case matters: a future api reason must degrade to "allowed" in an older web build rather than blocking with no explanation.

- [ ] **Step 3: Run them to verify they fail**

Run: `cd web && bun test src/lib/studio/kv/craftBaseRatio.test.ts`

Expected: the new block fails on the missing exports; every pre-existing test in the file still passes.

- [ ] **Step 4: Implement**

Add to `craftBaseRatio.ts`, leaving the two existing functions untouched:

```ts
export type CraftBlockedReason = "extreme_ratio" | "layer_composed";

const CRAFT_BLOCKED_REASONS: readonly string[] = [
  "extreme_ratio",
  "layer_composed",
];

/**
 * Why Craft is unavailable for this generation, or null when it is
 * available. An unknown reason from a newer API is treated as null: a build
 * that cannot explain a block should not impose one.
 */
export function craftBlockedReason(
  gen: KvGeneration | null | undefined
): CraftBlockedReason | null {
  if (!gen?.metadata) return null;
  const meta = gen.metadata as Record<string, unknown>;
  if (meta.craft_supported !== false) return null;
  const reason = meta.craft_blocked_reason;
  return typeof reason === "string" && CRAFT_BLOCKED_REASONS.includes(reason)
    ? (reason as CraftBlockedReason)
    : null;
}

export function isCraftBlocked(
  gen: KvGeneration | null | undefined
): boolean {
  return craftBlockedReason(gen) !== null;
}
```

- [ ] **Step 5: Run them to verify they pass, then commit**

Run: `cd web && bun test src/lib/studio/kv/craftBaseRatio.test.ts`

Expected: whole file passes.

```bash
cd web && git add src/lib/studio/kv/craftBaseRatio.ts src/lib/studio/kv/craftBaseRatio.test.ts
git commit -m "feat(web): make the craft gate carry a reason"
```

---

### Task 2: Disable Craft for a layer-composed KV and say why

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx:2961-2962` and `:2981`
- Test: `web/src/lib/studio/kv/craftBaseRatio.test.ts` is already covered; add no component test unless a message helper is extracted (see Step 3).

**Interfaces:**
- Consumes: `isCraftBlocked` and `craftBlockedReason` from Task 1.
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Widen the two gates**

At `KvGeneratorLayout.tsx:2961-2963`, `craftStatus` currently reads:

```tsx
  const craftStatus: "ready" | "polishing" | "disabled" =
    !latestGen || isUploadedBaseUnsupported(latestGen)
```

Replace the predicate with `isCraftBlocked(latestGen)`, and do the same at `:2981` (`!isUploadedBaseUnsupported(latestGen)` → `!isCraftBlocked(latestGen)`). Update the import at `:133`. Because `isCraftBlocked` is a strict superset of the old condition for existing data, the extreme-ratio behaviour is unchanged.

- [ ] **Step 2: Give the user the right explanation**

Find the existing inline warning shown for an unsupported uploaded base and make its copy depend on `craftBlockedReason(latestGen)`. For `"layer_composed"` the message must convey three things, in the product's existing voice and language:

- this KV is built from layers, so AI cannot regenerate it;
- chat still works for discussing it;
- flattening it first is the way to get AI edits.

Keep the existing `"extreme_ratio"` copy exactly as it is. Do not invent a new warning component — reuse the one already rendered for unsupported bases.

- [ ] **Step 3: Extract the copy if it is not already a pure function**

If the message is built inline in JSX, extract a small pure helper (e.g. `craftBlockedMessage(reason)`) next to `craftBaseRatio.ts` and add a test asserting a distinct non-empty string for each reason and `null` for no reason. If it is already a lookup table or constant, extend that instead and skip the extraction — do not restructure working UI code for its own sake.

- [ ] **Step 4: Verify and commit**

Run: `cd web && bun test src/lib/studio/kv/ && npx tsc --noEmit 2>&1 | grep -c "KvGeneratorLayout\|craftBaseRatio"`

Expected: tests pass; the grep count is no higher than it was before your change (record the before value first).

```bash
cd web && git add src/components/studio/kv-generator/KvGeneratorLayout.tsx src/lib/studio/kv/
git commit -m "feat(web): disable craft for layer-composed KVs with a clear reason"
```

---

### Task 3: Disable the upscale entries for a layer-composed KV

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvDownloadDropdown.tsx`
- Modify: `web/src/components/studio/kv-generator/KvTileDownloadDropdown.tsx`
- Test: the touched components' existing test files

**Interfaces:**
- Consumes: `isCraftBlocked` from Task 1.
- Produces: nothing.

Both dropdowns offer 1.5×/2× upscale rows. api now refuses those requests, so the UI must not offer them — an enabled control that always errors is worse than an absent one.

- [ ] **Step 1: Read both components first**

Each already renders rows in a disabled state under some conditions (`KvDownloadDropdown.tsx:32` mentions "rendered disabled per spec § Edge cases", and `:64` describes a "no generation = disabled" rule). Find that mechanism and reuse it rather than adding a parallel one. Note what each component receives — one may take a generation, the other a tile row whose parent generation is not in scope; if the flag is not reachable in a component, thread it from the parent rather than refetching.

- [ ] **Step 2: Write the failing test**

For each component, add a case asserting the upscale rows are disabled when the relevant generation is layer-composed, and unchanged when it is not. Follow the file's existing patterns and use `within(document.body)` rather than `screen`.

- [ ] **Step 3: Run to verify failure**

Run: `cd web && bun test src/components/studio/kv-generator/KvDownloadDropdown.test.tsx src/components/studio/kv-generator/KvTileDownloadDropdown.test.tsx`

Expected: the new cases fail. Establish the file's pre-existing failure count FIRST and report it — this directory carries ~122 pre-existing failures from the `screen` bug, and you must not attribute those to yourself.

- [ ] **Step 4: Implement, verify, commit**

Disable the upscale rows when `isCraftBlocked` is true for the governing generation. Leave the plain "Tile size" / native download row enabled — Phase 1 deliberately made that work for these tiles, and it is the user's only way to get the file.

```bash
cd web && git add src/components/studio/kv-generator/KvDownloadDropdown.tsx src/components/studio/kv-generator/KvTileDownloadDropdown.tsx src/components/studio/kv-generator/KvDownloadDropdown.test.tsx src/components/studio/kv-generator/KvTileDownloadDropdown.test.tsx
git commit -m "feat(web): disable upscale for layer-composed KVs"
```

---

## Verification after all tasks

- [ ] `cd web && bun test src/lib/studio/kv/ src/components/studio/kv-generator/`, compared against the baseline failure count you recorded.
- [ ] `cd web && bun run build` — catches broken imports, though not types.
- [ ] Manual, once the api plan is merged too: import a PSD, confirm Craft is disabled with the layer-specific message, confirm chat still answers, confirm the upscale rows are disabled while plain download still works. Then open a normal AI KV and confirm Craft and upscale behave exactly as before.

## Notes for the reviewer

- The "unrecognised reason means not blocked" rule is deliberate: web and api deploy independently, and a newer api reason must not silently disable Craft in an older web build with no explanation to show.
- Task 3 gates only the upscale rows. The native download must stay enabled — for a layer-composed tile it is the only path to a file, and Phase 1 exists to make it work.
