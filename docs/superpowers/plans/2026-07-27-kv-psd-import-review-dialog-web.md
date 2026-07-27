# KV PSD Import — Review Dialog & Entry Point (Phase 1, Web)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the user what's in a PSD — and what will be lost — before anything is uploaded, and give PSD import a discoverable entry point.

**Architecture:** The parser gains an `outline` tree describing the PSD as Photoshop sees it (groups, clipped layers, adjustment layers, per-layer warnings). A new dialog renders that tree with tristate checkboxes, resolves missing fonts inline, and returns the chosen subset. Wiring it in **deletes** the existing park-and-resume font flow rather than adding to it.

**Tech Stack:** Next.js 16, React 19, TypeScript, frndos components (`BaseModal`, `Button`, `Checkbox`), Bun test runner + React Testing Library.

**Spec:** `docs/superpowers/specs/2026-07-27-kv-psd-import-fidelity-design.md`

## Global Constraints

- **Depends on** `2026-07-27-kv-psd-import-fidelity-web-pipeline.md` being complete — this plan consumes `PsdImportResult.unsupportedBlendLayers` and the `psd/` module layout it creates.
- **Test import style differs by location, deliberately — follow the sibling files.** Component tests import from `"bun:test"` and use `@testing-library/react` (see `KvPsdImportOverlay.test.tsx`); `src/lib` tests import from `"vitest"`.
- **Run tests with `bun test`, never `bunx vitest`.** The real build gate is `bun run build`.
- **Use frndos components first** — `BaseModal`, `Button`, `Checkbox` from `@/components/frndos/`. `KvPsdMissingFontsDialog.tsx` is the closest existing model for structure and class conventions.
- **Nothing uploads until the user confirms.** Parse is fully client-side, so Cancel must cost zero network calls.
- **Branch:** `feature/daffa/vc-kv-psd-import-fidelity`.

---

### Task 1: `outline.ts` — describe the PSD as a reviewable tree

**Files:**
- Create: `src/lib/studio/kv/psd/outline.ts`
- Modify: `src/lib/studio/kv/psd/types.ts`
- Modify: `src/lib/studio/kv/psd/index.ts`
- Test: `src/lib/studio/kv/psd/outline.test.ts`

**Interfaces:**
- Produces:
  - `PsdOutlineNode = { key: string; name: string; kind: "group" | "text" | "image" | "shape" | "clipped" | "adjustment"; draftIndex: number | null; selectable: boolean; warnings: PsdLayerWarning[]; children: PsdOutlineNode[] }`
  - `PsdLayerWarning = "missing-font" | "blend-unsupported" | "effect-dropped" | "group-flattened"`
  - `selectedDraftIndices(nodes: PsdOutlineNode[], deselected: Set<string>): number[]`
  - `PsdImportResult` gains `outline: PsdOutlineNode[]`.

`draftIndex` points into `PsdImportResult.layers`. Nodes with `selectable: false` (clipped layers, adjustment layers) have `draftIndex: null` — they were baked into the layer below and do not survive as independent objects, which is exactly what the dialog must communicate.

- [ ] **Step 1: Write the failing test**

Create `src/lib/studio/kv/psd/outline.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { selectedDraftIndices, type PsdOutlineNode } from "./outline";

const leaf = (key: string, draftIndex: number): PsdOutlineNode => ({
  key,
  name: key,
  kind: "image",
  draftIndex,
  selectable: true,
  warnings: [],
  children: [],
});

const tree: PsdOutlineNode[] = [
  {
    key: "g1",
    name: "Group 1",
    kind: "group",
    draftIndex: null,
    selectable: true,
    warnings: ["group-flattened"],
    children: [leaf("t1", 0), leaf("t2", 1)],
  },
  leaf("img", 2),
  {
    key: "base",
    name: "CEFRON",
    kind: "image",
    draftIndex: 3,
    selectable: true,
    warnings: [],
    children: [
      {
        key: "clip",
        name: "Layer 2",
        kind: "clipped",
        draftIndex: null,
        selectable: false,
        warnings: [],
        children: [],
      },
    ],
  },
];

describe("selectedDraftIndices", () => {
  it("returns every draft when nothing is deselected", () => {
    expect(selectedDraftIndices(tree, new Set())).toEqual([0, 1, 2, 3]);
  });

  it("deselecting a group drops all its descendants", () => {
    expect(selectedDraftIndices(tree, new Set(["g1"]))).toEqual([2, 3]);
  });

  it("deselecting a single leaf leaves its siblings", () => {
    expect(selectedDraftIndices(tree, new Set(["t1"]))).toEqual([1, 2, 3]);
  });

  it("ignores non-selectable nodes — they are baked into their base", () => {
    // 'clip' carries no draftIndex, so it can never contribute one.
    expect(selectedDraftIndices(tree, new Set(["clip"]))).toEqual([0, 1, 2, 3]);
  });

  it("deselecting a base layer does not resurrect its clipped child", () => {
    expect(selectedDraftIndices(tree, new Set(["base"]))).toEqual([0, 1, 2]);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd web && bun test src/lib/studio/kv/psd/outline.test.ts
```

Expected: FAIL — `Cannot find module './outline'`.

- [ ] **Step 3: Write the implementation**

Create `src/lib/studio/kv/psd/outline.ts`:

```ts
/** A reviewable description of a PSD, mirroring what Photoshop shows — built
 *  from the parse result rather than from the overlay model, so it stays
 *  truthful about the source file even while the importer flattens groups. */

export type PsdLayerWarning =
  | "missing-font"
  | "blend-unsupported"
  | "effect-dropped"
  | "group-flattened";

export type PsdOutlineNode = {
  /** Stable within one parse — the dialog keys selection off this. */
  key: string;
  name: string;
  kind: "group" | "text" | "image" | "shape" | "clipped" | "adjustment";
  /** Index into PsdImportResult.layers, or null for nodes that don't produce
   *  an overlay: groups (phase 1 flattens them), clipped layers and
   *  adjustment layers (both baked into the layer below). */
  draftIndex: number | null;
  /** False for nodes baked into another layer — shown for transparency but
   *  not independently toggleable, because they don't survive as objects. */
  selectable: boolean;
  warnings: PsdLayerWarning[];
  children: PsdOutlineNode[];
};

/** Draft indices to import, given the set of deselected node keys.
 *  Deselecting a node removes its whole subtree. Order is preserved so
 *  placement still runs bottom → top. */
export function selectedDraftIndices(
  nodes: PsdOutlineNode[],
  deselected: Set<string>
): number[] {
  const out: number[] = [];
  const walk = (list: PsdOutlineNode[]) => {
    for (const node of list) {
      if (deselected.has(node.key)) continue;
      if (node.draftIndex !== null) out.push(node.draftIndex);
      walk(node.children);
    }
  };
  walk(nodes);
  return out;
}

/** Every node key in the tree, for select-all / indeterminate calculations. */
export function allNodeKeys(nodes: PsdOutlineNode[]): string[] {
  const out: string[] = [];
  const walk = (list: PsdOutlineNode[]) => {
    for (const node of list) {
      out.push(node.key);
      walk(node.children);
    }
  };
  walk(nodes);
  return out;
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd web && bun test src/lib/studio/kv/psd/outline.test.ts
```

Expected: PASS, 5 tests.

- [ ] **Step 5: Build the outline during the walk**

In `src/lib/studio/kv/psd/index.ts`, have `walk` build outline nodes alongside drafts:

- A group node (`node.children` present) becomes `kind: "group"`, `draftIndex: null`, `selectable: true`, `warnings: ["group-flattened"]`, with its children nested.
- A text draft becomes `kind: "text"`, with `"missing-font"` when `fontFamily` is null and `psFontName` is non-empty.
- A raster draft becomes `kind: "image"`, with `"blend-unsupported"` when `psdBlendToCanvas(node.blendMode).supported` is false.
- A clipping layer (`node.clipping === true`) becomes `kind: "clipped"`, `draftIndex: null`, `selectable: false`, nested under the base layer's node.
- A layer with no pixels and no text (today's `skippedCount` case) becomes `kind: "adjustment"`, `draftIndex: null`, `selectable: false`, nested under the base layer's node.

Use the layer's index path as the key (e.g. `"0.2.1"`) so keys are stable and unique. Add `outline: PsdOutlineNode[]` to `PsdImportResult` and return it.

- [ ] **Step 6: Run the full PSD suite**

```bash
cd web && bun test src/lib/studio/kv/
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
cd web && git add src/lib/studio/kv/psd
git commit -m "feat(web): build a reviewable outline tree from a parsed PSD"
```

---

### Task 2: The review dialog component

**Files:**
- Create: `src/components/studio/kv-generator/KvPsdImportReviewDialog.tsx`
- Test: `src/components/studio/kv-generator/KvPsdImportReviewDialog.test.tsx`

**Interfaces:**
- Consumes: `PsdOutlineNode`, `PsdLayerWarning`, `selectedDraftIndices`, `allNodeKeys`.
- Produces a presentational component:

```ts
type Props = {
  isOpen: boolean;
  fileName: string;
  width: number;
  height: number;
  outline: PsdOutlineNode[];
  /** Server/client overlay ceiling — selecting past it blocks confirm. */
  maxLayers: number;
  missingFonts: string[];
  fontsUploading: boolean;
  fontError: string | null;
  onUploadFonts: (files: File[]) => void;
  onCancel: () => void;
  /** Confirm with the draft indices the user kept, in stacking order. */
  onConfirm: (draftIndices: number[]) => void;
};
```

- [ ] **Step 1: Write the failing test**

Create `src/components/studio/kv-generator/KvPsdImportReviewDialog.test.tsx`:

```tsx
import { describe, it, expect, mock } from "bun:test";
import { render, screen, fireEvent } from "@testing-library/react";
import { KvPsdImportReviewDialog } from "./KvPsdImportReviewDialog";
import type { PsdOutlineNode } from "@/lib/studio/kv/psd/outline";

const outline: PsdOutlineNode[] = [
  {
    key: "g1",
    name: "Group 1",
    kind: "group",
    draftIndex: null,
    selectable: true,
    warnings: ["group-flattened"],
    children: [
      {
        key: "t1",
        name: "Buka Lebih Banyak Peluang",
        kind: "text",
        draftIndex: 0,
        selectable: true,
        warnings: ["missing-font"],
        children: [],
      },
    ],
  },
  {
    key: "i1",
    name: "CEFRON",
    kind: "image",
    draftIndex: 1,
    selectable: true,
    warnings: [],
    children: [
      {
        key: "c1",
        name: "Layer 2",
        kind: "clipped",
        draftIndex: null,
        selectable: false,
        warnings: [],
        children: [],
      },
    ],
  },
];

const base = {
  isOpen: true,
  fileName: "MULTIGUNA_KV 2_2.psd",
  width: 1080,
  height: 1351,
  outline,
  maxLayers: 300,
  missingFonts: [] as string[],
  fontsUploading: false,
  fontError: null,
  onUploadFonts: () => {},
  onCancel: () => {},
  onConfirm: () => {},
};

describe("KvPsdImportReviewDialog", () => {
  it("shows the file name and pixel dimensions", () => {
    render(<KvPsdImportReviewDialog {...base} />);
    expect(screen.getByText("MULTIGUNA_KV 2_2.psd")).toBeInTheDocument();
    expect(screen.getByText("1080 × 1351 px")).toBeInTheDocument();
  });

  it("renders the whole tree including non-selectable baked layers", () => {
    render(<KvPsdImportReviewDialog {...base} />);
    expect(screen.getByText("Group 1")).toBeInTheDocument();
    expect(screen.getByText("CEFRON")).toBeInTheDocument();
    expect(screen.getByText("Layer 2")).toBeInTheDocument();
  });

  it("gives baked layers no checkbox — they can't be imported separately", () => {
    render(<KvPsdImportReviewDialog {...base} />);
    expect(screen.queryByTestId("psd-layer-checkbox-c1")).toBeNull();
    expect(screen.getByTestId("psd-layer-checkbox-i1")).toBeInTheDocument();
  });

  it("confirms with every draft index by default", () => {
    const onConfirm = mock(() => {});
    render(<KvPsdImportReviewDialog {...base} onConfirm={onConfirm} />);
    fireEvent.click(screen.getByTestId("psd-import-confirm"));
    expect(onConfirm).toHaveBeenCalledWith([0, 1]);
  });

  it("deselecting a group drops its descendants from the confirm payload", () => {
    const onConfirm = mock(() => {});
    render(<KvPsdImportReviewDialog {...base} onConfirm={onConfirm} />);
    fireEvent.click(screen.getByTestId("psd-layer-checkbox-g1"));
    fireEvent.click(screen.getByTestId("psd-import-confirm"));
    expect(onConfirm).toHaveBeenCalledWith([1]);
  });

  it("surfaces a per-layer missing-font warning", () => {
    render(<KvPsdImportReviewDialog {...base} />);
    expect(screen.getByTestId("psd-warning-t1")).toHaveTextContent(
      /font/i
    );
  });

  it("blocks confirm when the selection exceeds the cap", () => {
    render(<KvPsdImportReviewDialog {...base} maxLayers={1} />);
    expect(screen.getByTestId("psd-import-confirm")).toBeDisabled();
  });

  it("cancels without confirming", () => {
    const onCancel = mock(() => {});
    const onConfirm = mock(() => {});
    render(
      <KvPsdImportReviewDialog {...base} onCancel={onCancel} onConfirm={onConfirm} />
    );
    fireEvent.click(screen.getByTestId("psd-import-cancel"));
    expect(onCancel).toHaveBeenCalled();
    expect(onConfirm).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd web && bun test src/components/studio/kv-generator/KvPsdImportReviewDialog.test.tsx
```

Expected: FAIL — the module does not exist.

- [ ] **Step 3: Write the component**

Create `src/components/studio/kv-generator/KvPsdImportReviewDialog.tsx`. Model its shell on `KvPsdMissingFontsDialog.tsx` (same `BaseModal` usage, same typography classes). Requirements:

- `"use client"` at the top.
- Local state: `const [deselected, setDeselected] = useState<Set<string>>(new Set())`.
- Toggling a node key adds/removes it from `deselected`; descendants follow automatically because `selectedDraftIndices` skips whole subtrees.
- Header row: `fileName` on the left, `` `${width} × ${height} px` `` on the right.
- "Select all layers" checkbox: checked when `deselected.size === 0`; clicking it clears the set or fills it with `allNodeKeys(outline)`.
- Recursive `<LayerRow>`: indent by depth (`paddingLeft: depth * 16`), a type icon per `kind`, the name, and a warning badge when `warnings.length > 0` with `data-testid={"psd-warning-" + key}`.
- Selectable rows render a `Checkbox` with `data-testid={"psd-layer-checkbox-" + key}`. Non-selectable rows render a clip indicator instead of a checkbox.
- Warning copy: `missing-font` → "Font not available", `blend-unsupported` → "Blend mode not supported", `effect-dropped` → "Layer effect not imported", `group-flattened` → "Group will be flattened".
- Footer: selected count vs cap (`` `${selected.length} of ${totalDrafts} layers · max ${maxLayers}` ``), the missing-fonts affordance (a file input + "Upload fonts" button, plus "Use default font" copy) shown only when `missingFonts.length > 0`, `fontError` when present, then Cancel (`data-testid="psd-import-cancel"`) and Import (`data-testid="psd-import-confirm"`).
- Import is `disabled` when `selected.length === 0`, `selected.length > maxLayers`, or `fontsUploading`.
- `onConfirm(selectedDraftIndices(outline, deselected))`.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd web && bun test src/components/studio/kv-generator/KvPsdImportReviewDialog.test.tsx
```

Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
cd web && git add src/components/studio/kv-generator/KvPsdImportReviewDialog.tsx src/components/studio/kv-generator/KvPsdImportReviewDialog.test.tsx
git commit -m "feat(web): add the PSD import review dialog"
```

---

### Task 3: Wire the dialog in and delete the park-and-resume font flow

**Files:**
- Modify: `src/components/studio/kv-generator/KvGeneratorLayout.tsx`
- Delete: `src/components/studio/kv-generator/KvPsdMissingFontsDialog.tsx`

**Interfaces:**
- Consumes: `KvPsdImportReviewDialog`, `PsdImportResult.outline`.

This task is a **net deletion**. Today the import parks mid-flight when fonts are missing (`psdFontPrompt`), reopens later, and needs `psdImportBusyRef` to stop a second drop racing the parked state and double-placing every layer. With fonts resolved inside the review dialog, that entire machine goes away.

- [ ] **Step 1: Replace the parked-prompt state with review state**

Remove `psdFontPrompt`, `handlePsdFontsSkip`, and the `KvPsdMissingFontsDialog` render. Replace with:

```ts
  // Parsed PSD awaiting user review. Nothing has been uploaded at this point —
  // cancelling is free. Fonts are resolved inside the dialog, so there is no
  // mid-import park/resume to guard against any more.
  const [psdReview, setPsdReview] = useState<{
    parsed: Awaited<ReturnType<typeof importPsd>>;
    fileName: string;
    fit: NormRect;
    target: { kind: "board"; boardGenerationId: string } | { kind: "canvas" };
    analyticsTarget: KvPsdImportTarget;
    startedAt: number;
    missingFonts: string[];
  } | null>(null);
```

Keep `psdFontUploading` and `psdFontError` — they now drive the dialog's inline font affordance.

- [ ] **Step 2: Stop `importPsdFile` after parse**

`importPsdFile` now parses, computes `fit`, collects `collectMissingPsdFonts(parsed.layers)`, sets `psdReview`, and returns. **All uploading moves after confirm** — including base-board creation, which must not happen until the user commits.

- [ ] **Step 3: Add the confirm handler**

```ts
  // User confirmed the review dialog: create the base board (empty-canvas
  // drops only), then place the layers they kept.
  const handlePsdReviewConfirm = async (draftIndices: number[]) => {
    const review = psdReview;
    if (!review) return;
    setPsdReview(null);
    setPsdImporting(true);
    const layers = draftIndices
      .map((i) => review.parsed.layers[i])
      .filter((l): l is PsdImportLayer => Boolean(l));

    let boardGenerationId: string;
    if (review.target.kind === "board") {
      boardGenerationId = review.target.boardGenerationId;
    } else {
      // Blank base at the PSD's own dimensions (pipeline plan, Task 9) — the
      // layers ARE the picture, so nothing is uploaded until this point.
      const baseFile = await makeBlankBaseAt(
        review.parsed.width,
        review.parsed.height,
        { fileName: `${review.fileName.replace(/\.psd$/i, "")}.png` }
      );
      const importedId = await handleUploadBase(baseFile);
      if (!importedId) {
        // handleUploadBase already surfaced its own failure notice.
        trackKvPsdImportFailed({
          target: review.analyticsTarget,
          failure_stage: "base_upload",
          duration_ms: Date.now() - review.startedAt,
        });
        psdImportBusyRef.current = false;
        setPsdImporting(false);
        return;
      }
      boardGenerationId = importedId;
    }

    await finishPsdImport(
      layers,
      boardGenerationId,
      review.fit,
      review.analyticsTarget,
      review.startedAt,
      review.parsed.skippedCount + (review.parsed.layers.length - layers.length)
    );
  };
```

- [ ] **Step 4: Add the cancel handler**

```ts
  // Cancel before any upload — release the lock and leave the canvas untouched.
  const handlePsdReviewCancel = () => {
    setPsdReview(null);
    setPsdFontError(null);
    psdImportBusyRef.current = false;
    setPsdImporting(false);
  };
```

- [ ] **Step 5: Rework the font upload handler**

`handlePsdFontsUpload` keeps its upload + `registerBrandFonts` + `rematchTextDrafts` logic, but instead of resuming the import it updates `psdReview` in place with the re-matched layers and the remaining `missingFonts`, leaving the dialog open.

- [ ] **Step 6: Render the dialog**

```tsx
      <KvPsdImportReviewDialog
        isOpen={psdReview !== null}
        fileName={psdReview?.fileName ?? ""}
        width={psdReview?.parsed.width ?? 0}
        height={psdReview?.parsed.height ?? 0}
        outline={psdReview?.parsed.outline ?? []}
        maxLayers={Math.max(0, MAX_OVERLAYS_PER_FILE - overlays.length)}
        missingFonts={psdReview?.missingFonts ?? []}
        fontsUploading={psdFontUploading}
        fontError={psdFontError}
        onUploadFonts={handlePsdFontsUpload}
        onCancel={handlePsdReviewCancel}
        onConfirm={handlePsdReviewConfirm}
      />
```

The blocking `KvPsdImportOverlay` must gate on `psdReview === null`, exactly as it previously gated on `psdFontPrompt === null`, so it hides while the dialog is open.

- [ ] **Step 7: Delete the old dialog**

```bash
cd web && git rm src/components/studio/kv-generator/KvPsdMissingFontsDialog.tsx
```

- [ ] **Step 8: Verify the build and the KV tests**

```bash
cd web && bun run build && bun test src/components/studio src/lib/studio
```

Expected: build succeeds, tests pass. Any `KvPsdMissingFontsDialog` import left behind fails the build — that is the intended signal.

- [ ] **Step 9: Commit**

```bash
cd web && git add -A src/components/studio/kv-generator
git commit -m "feat(web): review PSD imports before upload, drop the parked font flow"
```

---

### Task 4: Explicit "Import PSD" entry point

**Files:**
- Modify: `src/components/studio/kv-generator/KvCanvasBottomNav.tsx`
- Modify: `src/components/studio/kv-generator/KvEmptyCanvasDropArea.tsx`
- Modify: `src/components/studio/kv-generator/KvGeneratorLayout.tsx`

Drag-and-drop is invisible to users who don't think to try it. The button reuses the same pipeline — file picker → `importPsdFile({ kind: "canvas" })` → review dialog.

- [ ] **Step 1: Add a hidden file input + handler in `KvGeneratorLayout`**

```tsx
  const psdInputRef = useRef<HTMLInputElement | null>(null);

  // Explicit entry point — same pipeline as a drop on empty canvas.
  const handlePsdPicked = (e: React.ChangeEvent<HTMLInputElement>) => {
    const picked = e.target.files?.[0];
    e.target.value = ""; // allow re-picking the same file
    if (picked && isPsdFile(picked)) void importPsdFile(picked, { kind: "canvas" });
  };
```

```tsx
      <input
        ref={psdInputRef}
        type="file"
        accept=".psd,image/vnd.adobe.photoshop"
        className="hidden"
        onChange={handlePsdPicked}
      />
```

- [ ] **Step 2: Add the button to the empty state**

In `KvEmptyCanvasDropArea.tsx`, add an "Import PSD" `Button` next to the existing upload affordance, calling a new `onImportPsd` prop wired to `psdInputRef.current?.click()`.

- [ ] **Step 3: Add the button to the canvas toolbar**

In `KvCanvasBottomNav.tsx`, add an "Import PSD" action alongside the existing image tool, wired to the same callback.

- [ ] **Step 4: Verify the build**

```bash
cd web && bun run build
```

Expected: build succeeds.

- [ ] **Step 5: Manual verification**

```bash
cd web && bun dev
```

Open a KV file, click **Import PSD**, pick `MULTIGUNA_KV 2_2.psd`, and confirm: the review dialog lists `Group 1` with its text children, shows `Layer 2` / `Layer 3` / `Curves 2` as non-selectable clipped rows, flags the missing fonts, and imports only the checked layers. Then compare the board against the same PSD in thebrief.ai — the black band must be gone and nothing stretched.

- [ ] **Step 6: Commit**

```bash
cd web && git add src/components/studio/kv-generator
git commit -m "feat(web): add an explicit Import PSD entry point"
```

---

## Done criteria

- Dropping or picking a PSD opens a review dialog before any network call.
- The dialog shows the PSD's real group tree, with clipped and adjustment layers visible but not selectable.
- Missing fonts, unsupported blend modes and dropped effects are flagged per layer.
- Deselecting layers reduces what gets imported; exceeding the cap blocks Import instead of silently truncating.
- Cancel leaves the canvas and the network untouched.
- `KvPsdMissingFontsDialog.tsx` is gone and nothing references it.
- `bun run build` and `bun test src/components/studio src/lib/studio` are green.

## Not in this plan

- Layer effects baking and vector-layer → `shape` conversion (last of phase 1).
- Groups as real overlays — phase 2.
