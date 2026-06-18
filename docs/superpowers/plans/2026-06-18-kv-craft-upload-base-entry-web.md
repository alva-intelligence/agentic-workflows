# KV Craft Upload-Base — Entry Point + Extreme-Ratio Gate (Web) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a first-class "upload an image as the Craft base" entry point to the empty KV canvas, measure the upload's dimensions, and gate Craft (with a warning) when the upload's aspect ratio is too extreme — while keeping ratio-preserving upscale available.

**Architecture:** A new empty-state block (`KvUploadBaseBlock`) sits beneath the artboard picker (vertical). It measures the picked image's natural dimensions, uploads via the existing `uploadKvAttachment`, then registers it as Version 1 via `importKvGenerationFromUpload` (extended to send `width`/`height`). The API persists `craft_supported`; the web reads it to disable Craft on extreme uploads and surface a warning. Reuses the existing upload + import chain end-to-end.

**Tech Stack:** Next.js 16 / React 19 / TypeScript / Zustand / vitest + Testing Library.

**Spec:** [docs/superpowers/specs/2026-06-18-kv-craft-upload-base-entry-design.md](../specs/2026-06-18-kv-craft-upload-base-entry-design.md)

**Depends on:** the API plan ([2026-06-18-kv-craft-upload-base-entry-api.md](2026-06-18-kv-craft-upload-base-entry-api.md)) — the `width`/`height` request fields and `craft_supported` metadata. The web import call sends `width`/`height`; the gate reads `craft_supported`.

---

## File Structure

| Path | Action | Responsibility |
|---|---|---|
| `src/components/studio/kv-generator/measureImageSize.ts` | Create | Pure util: `File → { width, height }` |
| `src/components/studio/kv-generator/measureImageSize.test.ts` | Create | Unit test for the util |
| `src/services/kv/api.ts` | Modify | Add `width`/`height` to `importKvGenerationFromUpload` body |
| `src/components/studio/kv-generator/promoteAttachmentToBase.ts` | Modify | Thread `width`/`height` through |
| `src/components/studio/kv-generator/promoteAttachmentToBase.test.ts` | Modify | Assert the new fields are forwarded |
| `src/lib/studio/kv/craftBaseRatio.ts` | Create | Pure predicate: `isUploadedBaseUnsupported(gen)` |
| `src/lib/studio/kv/craftBaseRatio.test.ts` | Create | Unit test for the predicate |
| `src/components/studio/kv-generator/KvUploadBaseBlock.tsx` | Create | Empty-state upload affordance (button + drag-drop) |
| `src/components/studio/kv-generator/KvUploadBaseBlock.test.tsx` | Create | Component test |
| `src/components/studio/kv-generator/KvCanvas.tsx` | Modify | Mount the upload block beneath the artboard picker |
| `src/components/studio/kv-generator/KvGeneratorLayout.tsx` | Modify | Orchestrate upload→import→select; gate `craftStatus`; warning |

---

## Task 1 — `measureImageSize` util

**Files:**
- Create: `src/components/studio/kv-generator/measureImageSize.ts`
- Test: `src/components/studio/kv-generator/measureImageSize.test.ts`

- [ ] **Step 1: Write the util**

```typescript
/**
 * Read an image File's natural pixel dimensions in the browser. Prefers
 * createImageBitmap (fast, no DOM); falls back to an <img> + object URL.
 * Throws if the file is not a decodable image.
 */
export async function measureImageSize(
  file: File,
): Promise<{ width: number; height: number }> {
  if (typeof createImageBitmap === "function") {
    const bitmap = await createImageBitmap(file);
    try {
      return { width: bitmap.width, height: bitmap.height };
    } finally {
      bitmap.close();
    }
  }

  return await new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      const size = { width: img.naturalWidth, height: img.naturalHeight };
      URL.revokeObjectURL(url);
      resolve(size);
    };
    img.onerror = () => {
      URL.revokeObjectURL(url);
      reject(new Error("could not decode image"));
    };
    img.src = url;
  });
}
```

- [ ] **Step 2: Write the test**

```typescript
import { describe, it, expect, vi } from "vitest";
import { measureImageSize } from "./measureImageSize";

describe("measureImageSize", () => {
  it("returns dimensions via createImageBitmap when available", async () => {
    const close = vi.fn();
    vi.stubGlobal(
      "createImageBitmap",
      vi.fn(async () => ({ width: 2000, height: 582, close })),
    );
    const file = new File([new Uint8Array([1, 2, 3])], "banner.png", {
      type: "image/png",
    });

    const size = await measureImageSize(file);

    expect(size).toEqual({ width: 2000, height: 582 });
    expect(close).toHaveBeenCalled();
    vi.unstubAllGlobals();
  });
});
```

- [ ] **Step 3: Run it**

Run: `cd web && bun run test src/components/studio/kv-generator/measureImageSize.test.ts`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/components/studio/kv-generator/measureImageSize.ts src/components/studio/kv-generator/measureImageSize.test.ts
git commit -m "feat(web): add measureImageSize util for KV uploads"
```

---

## Task 2 — Send width/height through import + promote

**Files:**
- Modify: `src/services/kv/api.ts` (~lines 229–243)
- Modify: `src/components/studio/kv-generator/promoteAttachmentToBase.ts`
- Test: `src/components/studio/kv-generator/promoteAttachmentToBase.test.ts`

- [ ] **Step 1: Extend the API body type**

In `src/services/kv/api.ts`, update `importKvGenerationFromUpload`:

```typescript
export async function importKvGenerationFromUpload(
  fileId: string,
  body: {
    image_url: string;
    mime_type: string;
    size: number;
    original_filename?: string;
    width: number;
    height: number;
  },
): Promise<KvGeneration> {
  const { data } = await axiosInstance.post(
    `v1/studio/kv-generator/files/${fileId}/generations/import-from-upload`,
    body,
  );
  return unwrap(data);
}
```

- [ ] **Step 2: Thread width/height through the promote helper**

In `src/components/studio/kv-generator/promoteAttachmentToBase.ts`, extend the descriptor + call:

```typescript
export interface UploadedAttachmentDescriptor {
  id: string;
  name: string;
  mime_type: string;
  size: number;
  url: string | undefined;
  width: number;
  height: number;
}

export async function promoteAttachmentToBase(args: {
  fileId: string;
  attachment: UploadedAttachmentDescriptor;
}): Promise<string | null> {
  const { fileId, attachment } = args;
  if (!attachment.url) return null;

  try {
    const generation = await importKvGenerationFromUpload(fileId, {
      image_url: attachment.url,
      mime_type: attachment.mime_type,
      size: attachment.size,
      original_filename: attachment.name,
      width: attachment.width,
      height: attachment.height,
    });
    return generation.id;
  } catch {
    return null;
  }
}
```

- [ ] **Step 3: Update the promote test**

In `promoteAttachmentToBase.test.ts`, add `width`/`height` to the attachment in the existing happy-path test and assert they reach the import call:

```typescript
  const id = await promoteAttachmentToBase({
    fileId: "file_abc",
    attachment: {
      id: "att_1",
      name: "ref.png",
      mime_type: "image/png",
      size: 4096,
      url: "https://s3/uploads/ref.png",
      width: 1920,
      height: 1080,
    },
  });

  expect(id).toBe("gen_synth_1");
  expect(mockImport).toHaveBeenCalledWith("file_abc", {
    image_url: "https://s3/uploads/ref.png",
    mime_type: "image/png",
    size: 4096,
    original_filename: "ref.png",
    width: 1920,
    height: 1080,
  });
```

> NOTE: callers of `promoteAttachmentToBase` that build a descriptor from a chat attachment must now also supply `width`/`height`. For the chat path, measure via `measureImageSize` at file-pick time, or fall back to `0/0` only if unavailable (the API requires positive ints, so prefer measuring). Confirm/adjust the existing call site in `KvChat.tsx`.

- [ ] **Step 4: Run + commit**

Run: `cd web && bun run test src/components/studio/kv-generator/promoteAttachmentToBase.test.ts`
Expected: PASS.

```bash
git add src/services/kv/api.ts src/components/studio/kv-generator/promoteAttachmentToBase.ts src/components/studio/kv-generator/promoteAttachmentToBase.test.ts
git commit -m "feat(web): send image dimensions on KV import-from-upload"
```

---

## Task 3 — Extreme-ratio predicate

**Files:**
- Create: `src/lib/studio/kv/craftBaseRatio.ts`
- Test: `src/lib/studio/kv/craftBaseRatio.test.ts`

- [ ] **Step 1: Write the predicate**

```typescript
import type { KvGeneration } from "@/types/studio";

/**
 * True when the given generation is a user-uploaded base whose aspect
 * ratio is too extreme for the image model to Craft (API set
 * metadata.craft_supported = false). Craft is gated for these; upscale
 * still works. Returns false for normal AI generations and for supported
 * uploads.
 */
export function isUploadedBaseUnsupported(
  gen: KvGeneration | null | undefined,
): boolean {
  if (!gen?.metadata) return false;
  const meta = gen.metadata as Record<string, unknown>;
  return meta.imported_from_upload === true && meta.craft_supported === false;
}
```

- [ ] **Step 2: Write the test**

```typescript
import { describe, it, expect } from "vitest";
import { isUploadedBaseUnsupported } from "./craftBaseRatio";

const base = {
  id: "g1", studio_file_id: "f", version_number: 1, mode: "sketch",
  image_url: "u", thumbnail_url: null, prompt_snapshot: "", model: "user_upload",
  parent_generation_id: null, created_at: "2026-06-18T00:00:00Z",
} as const;

describe("isUploadedBaseUnsupported", () => {
  it("is true for an extreme uploaded base", () => {
    expect(isUploadedBaseUnsupported({ ...base, metadata: { imported_from_upload: true, craft_supported: false } })).toBe(true);
  });
  it("is false for a supported uploaded base", () => {
    expect(isUploadedBaseUnsupported({ ...base, metadata: { imported_from_upload: true, craft_supported: true, aspect_ratio: "16:9" } })).toBe(false);
  });
  it("is false for a normal AI generation", () => {
    expect(isUploadedBaseUnsupported({ ...base, model: "gpt-image-1", metadata: { aspect_ratio: "1:1" } })).toBe(false);
  });
  it("is false for null/no metadata", () => {
    expect(isUploadedBaseUnsupported(null)).toBe(false);
    expect(isUploadedBaseUnsupported({ ...base, metadata: null })).toBe(false);
  });
});
```

- [ ] **Step 3: Run + commit**

Run: `cd web && bun run test src/lib/studio/kv/craftBaseRatio.test.ts`
Expected: PASS.

```bash
git add src/lib/studio/kv/craftBaseRatio.ts src/lib/studio/kv/craftBaseRatio.test.ts
git commit -m "feat(web): add extreme-ratio uploaded-base predicate"
```

---

## Task 4 — `KvUploadBaseBlock` component

**Files:**
- Create: `src/components/studio/kv-generator/KvUploadBaseBlock.tsx`
- Test: `src/components/studio/kv-generator/KvUploadBaseBlock.test.tsx`

- [ ] **Step 1: Write the component**

The block owns only UI (file input + drag-drop). The parent passes an
`onUpload(file)` handler (orchestration lives in `KvGeneratorLayout`, Task 6)
and a `busy` flag.

```tsx
"use client";

import { useRef, useState } from "react";

type Props = {
  onUpload: (file: File) => void;
  busy?: boolean;
};

const ACCEPT = "image/png,image/jpeg,image/webp,image/gif";

export function KvUploadBaseBlock({ onUpload, busy = false }: Props) {
  const inputRef = useRef<HTMLInputElement>(null);
  const [dragging, setDragging] = useState(false);

  const pick = (files: FileList | null) => {
    const file = files?.[0];
    if (file) onUpload(file);
  };

  return (
    <div className="flex flex-col items-center gap-3">
      <div className="flex w-[240px] items-center gap-2 text-xs text-text-inverse-subtle">
        <span className="h-px flex-1 bg-border-inverse-subtle" />
        atau
        <span className="h-px flex-1 bg-border-inverse-subtle" />
      </div>

      <button
        type="button"
        disabled={busy}
        onClick={() => inputRef.current?.click()}
        onDragOver={(e) => {
          e.preventDefault();
          setDragging(true);
        }}
        onDragLeave={() => setDragging(false)}
        onDrop={(e) => {
          e.preventDefault();
          setDragging(false);
          pick(e.dataTransfer.files);
        }}
        aria-label="Upload an image as the base"
        className={`flex w-[280px] flex-col items-center gap-2 rounded-lg border border-dashed px-4 py-5 text-center transition-colors ${
          dragging ? "border-primary bg-primary/5" : "border-border-inverse-subtle"
        } ${busy ? "opacity-60" : ""}`}
      >
        <span className="text-sm font-medium text-text-inverse">
          {busy ? "Uploading…" : "Upload image jadi base"}
        </span>
        <span className="text-xs text-text-inverse-subtle">
          drag &amp; drop atau browse · rasio canvas ikut gambar
        </span>
      </button>

      <input
        ref={inputRef}
        type="file"
        accept={ACCEPT}
        className="hidden"
        onChange={(e) => pick(e.target.files)}
      />
    </div>
  );
}
```

> NOTE: the className tokens above mirror the empty-state styling used by the
> sibling `KvArtboardPicker`. Confirm the exact Tailwind token names against
> that file and adjust if the project uses different inverse-text tokens.

- [ ] **Step 2: Write the component test**

```tsx
import "@testing-library/jest-dom/vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { vi } from "vitest";
import { KvUploadBaseBlock } from "./KvUploadBaseBlock";

it("calls onUpload with the picked file", () => {
  const onUpload = vi.fn();
  render(<KvUploadBaseBlock onUpload={onUpload} />);

  const file = new File([new Uint8Array([1])], "banner.png", { type: "image/png" });
  const input = document.querySelector('input[type="file"]') as HTMLInputElement;
  fireEvent.change(input, { target: { files: [file] } });

  expect(onUpload).toHaveBeenCalledWith(file);
});

it("disables the trigger while busy", () => {
  render(<KvUploadBaseBlock onUpload={vi.fn()} busy />);
  expect(screen.getByRole("button", { name: /upload an image/i })).toBeDisabled();
});
```

- [ ] **Step 3: Run + commit**

Run: `cd web && bun run test src/components/studio/kv-generator/KvUploadBaseBlock.test.tsx`
Expected: PASS.

```bash
git add src/components/studio/kv-generator/KvUploadBaseBlock.tsx src/components/studio/kv-generator/KvUploadBaseBlock.test.tsx
git commit -m "feat(web): add KvUploadBaseBlock empty-state upload affordance"
```

---

## Task 5 — Mount the block in the empty canvas (vertical)

**Files:**
- Modify: `src/components/studio/kv-generator/KvCanvas.tsx` (isEmpty branch, ~lines 186–197)

- [ ] **Step 1: Render the block beneath the picker**

KvCanvas needs an `onUploadBase?: (file: File) => void` prop (threaded from
`KvGeneratorLayout`, Task 6) and an `uploadingBase?: boolean` prop. Update the
`isEmpty` branch so the picker and upload block stack vertically:

```tsx
  if (isEmpty) {
    if (onSelectArtboardRatio) {
      return (
        <div className="flex h-full w-full flex-col items-center justify-center gap-4">
          <KvArtboardPicker
            selectedRatio={selectedArtboardRatio}
            onSelectRatio={onSelectArtboardRatio}
          />
          {onUploadBase ? (
            <KvUploadBaseBlock onUpload={onUploadBase} busy={uploadingBase} />
          ) : null}
        </div>
      );
    }
    // ...unchanged fallback copy...
  }
```

Add the import at the top of `KvCanvas.tsx`:

```tsx
import { KvUploadBaseBlock } from "./KvUploadBaseBlock";
```

Add `onUploadBase` and `uploadingBase` to KvCanvas's `Props` type.

> NOTE: `KvArtboardPicker` swaps to a placeholder frame once `selectedRatio`
> is set — only show the upload block while `selectedRatio` is null so it
> doesn't sit beneath the placeholder. Guard with `{selectedArtboardRatio === null && onUploadBase ? ... : null}`.

- [ ] **Step 2: Commit**

```bash
git add src/components/studio/kv-generator/KvCanvas.tsx
git commit -m "feat(web): mount upload-base block in empty KV canvas"
```

---

## Task 6 — Orchestrate upload + gate Craft + warning

**Files:**
- Modify: `src/components/studio/kv-generator/KvGeneratorLayout.tsx` (~line 699 `craftStatus`; add the upload handler + pass props to KvCanvas)

- [ ] **Step 1: Add the upload-base handler**

In `KvGeneratorLayout.tsx`, add a handler that measures, uploads, imports, then
refetches generations and selects the new base. Use the pieces already in the
module (`uploadKvAttachment`, the auth `token` + `baseUrl`, the generations
query/refetch, and `select`/`activeGenerationId`). Wire `importKvGenerationFromUpload`
via `promoteAttachmentToBase` so the descriptor + dimensions path is shared:

```tsx
const [uploadingBase, setUploadingBase] = useState(false);

const handleUploadBase = useCallback(
  async (file: File) => {
    setUploadingBase(true);
    try {
      const { width, height } = await measureImageSize(file);
      const [descriptor] = await uploadKvAttachment([file], { baseUrl, token });
      if (!descriptor?.url) throw new Error("upload returned no url");

      const newId = await promoteAttachmentToBase({
        fileId,
        attachment: {
          id: descriptor.id,
          name: descriptor.name,
          mime_type: descriptor.mime_type,
          size: descriptor.size,
          url: descriptor.url,
          width,
          height,
        },
      });
      if (!newId) throw new Error("import failed");

      await refetchGenerations(); // existing generations query refetch
      selectGeneration(newId);    // existing active-generation setter
    } catch (err) {
      console.error("[kv] upload base failed", err);
      // surface a toast (existing Toast component)
    } finally {
      setUploadingBase(false);
    }
  },
  [baseUrl, token, fileId /* + refetch/select deps */],
);
```

Add imports:

```tsx
import { measureImageSize } from "./measureImageSize";
import { uploadKvAttachment } from "./uploadAttachment";
import { promoteAttachmentToBase } from "./promoteAttachmentToBase";
import { isUploadedBaseUnsupported } from "@/lib/studio/kv/craftBaseRatio";
```

> NOTE: `refetchGenerations` / `selectGeneration` are placeholders for the
> module's existing mechanisms — use the exact names already in
> `KvGeneratorLayout` (the same ones a streamed generation uses to appear +
> become active). `baseUrl`/`token`/`fileId` already exist in scope (the
> stream send uses them).

- [ ] **Step 2: Pass the handler + busy flag to KvCanvas**

Where `<KvCanvas ... />` is rendered, add:

```tsx
  onUploadBase={handleUploadBase}
  uploadingBase={uploadingBase}
```

- [ ] **Step 3: Gate `craftStatus` on extreme ratio**

Update the `craftStatus` computation (~line 699):

```tsx
const craftStatus: "ready" | "polishing" | "disabled" =
  !latestGen || isUploadedBaseUnsupported(latestGen)
    ? "disabled"
    : stream.pendingGeneration || stream.isPreparing
      ? "polishing"
      : "ready";
```

> NOTE: use whichever generation Craft actually polishes (the active/base gen).
> If that is not `latestGen`, apply `isUploadedBaseUnsupported` to that one.

- [ ] **Step 4: Proactive warning when an extreme upload becomes the base**

After `selectGeneration(newId)` in the handler, when the imported base is
unsupported, surface the warning. Concrete mechanism: show a Toast and (if the
chat-thread append API is readily available in this module) append an assistant
chat bubble — the spec prefers the chat. Re-read the freshly imported
generation's `metadata.craft_supported` (from the refetched list) to decide:

```tsx
const imported = generations.find((g) => g.id === newId) ?? null;
if (isUploadedBaseUnsupported(imported)) {
  showToast(
    "Rasio gambar ini belum didukung untuk Craft. Kamu tetap bisa upscale & download.",
  );
}
```

> NOTE: prefer the chat-bubble form if the module already exposes a way to push
> an assistant message into the thread; otherwise the Toast above is the
> concrete fallback. Either way the message text is identical.

- [ ] **Step 5: Run the related web tests + commit**

Run: `cd web && bun run test src/components/studio/kv-generator/ src/lib/studio/kv/craftBaseRatio.test.ts`
Expected: PASS.

```bash
git add src/components/studio/kv-generator/KvGeneratorLayout.tsx
git commit -m "feat(web): upload-base orchestration + extreme-ratio craft gate"
```

---

## Self-Review

- **Spec coverage:** entry point in empty-state vertical (Tasks 4–5), measure dimensions (Task 1) + send them (Task 2), Craft gate on extreme ratio via `craft_supported` (Tasks 3, 6.3), proactive warning (6.4), upscale untouched (no task — confirmed no guard exists). ✓
- **Types:** `measureImageSize → {width,height}` consumed in Task 6; `importKvGenerationFromUpload` body adds `width`/`height` (Task 2) matching the API plan's request fields; `isUploadedBaseUnsupported(gen)` used identically in Tasks 3 & 6; metadata keys `imported_from_upload`/`craft_supported` match the API plan's writes. ✓
- **Placeholders:** the three `NOTE:` blocks (Tasks 2, 5, 6) flag in-file integration names (`KvChat` call site, artboard-token names, `refetchGenerations`/`selectGeneration`/chat-append) the engineer must bind to the module's existing mechanisms — concrete code is provided against known signatures; these are integration-confirmation points, not missing logic. Resolve each by reading the current file before editing.
