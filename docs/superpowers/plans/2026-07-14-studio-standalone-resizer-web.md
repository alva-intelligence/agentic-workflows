# Standalone Resizer — Web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the standalone Resizer tool in the web app — un-gate the Resizer tile, add a "My Resize Files" list page and a resize-only job canvas (upload → platform picker → stacked exports → Download ZIP) — reusing the entire existing resize UI slice.

**Architecture:** Approach A from `docs/superpowers/specs/2026-07-14-studio-standalone-resizer-design.md`. A `ResizerLayout` composes the already-built resize components (`KvResizePanel`, `KvResizeCanvas`, `KvUploadBaseBlock`) and hooks (`useResizeExports`, `useKvResizeStore`) — without forking the 3000-line `KvGeneratorLayout`. Upload reuses the exact craft-upload-base chain (`measureImageSize` → `uploadKvAttachment` → `promoteAttachmentToBase`, which hits the tool-agnostic `import-from-upload` endpoint). Depends on the API plan (`…-api.md`): `POST/GET /v1/studio/resizer/files…` and `GET …/resize-exports/download-zip`.

**Tech Stack:** Next.js 16 (App Router), React 19, TypeScript, TanStack Query v5, Zustand, Tailwind, Bun test runner (vitest-style API via `bunfig.toml` preload), PostHog analytics.

## Global Constraints

- **Branch:** `feature/daffa/vc-studio-standalone-resizer` off latest `develop`. Never commit on `develop`.
- **Test runner is `bun test`** (NOT `bunx vitest`); tests import from `vitest` but run under Bun via `web/bunfig.toml` preload (`src/test-jsdom-setup.ts`, `src/test-setup.ts`). The real gate is `bun run build` (type-check + build), not `tsc` alone. See memory `lesson_web_test_runner_bun_test`.
- **The Resizer tile depends on the resize pipeline, which is gated by `feature.flag:show-kv-generator`.** So in v1 the tile is shown only when the KV-generator flag is on (same gate as `kv-generator`). Do NOT introduce a new flag.
- **Reuse, don't reinvent:** the resize components, hooks, upload chain, and `updateStudioFile` rename all exist. New code is glue + two pages + a slim layout/header.
- **Upload accept types** follow the existing `KvUploadBaseBlock` (`image/png,image/jpeg,image/webp,image/gif`). Empty-state copy can say "JPG, PNG, WEBP".
- **PostHog events** follow `src/lib/analytics/kv-generator-events.ts` conventions (snake_case, typed wrapper, base context) — see `frndos-analytics-events` skill.

---

## File Structure

| Path | Action | Responsibility |
|---|---|---|
| `src/lib/studioTools.ts` | Modify | Un-gate `resizer` tile, route it to `/studio/resizer`, gate on KV flag |
| `src/lib/studioRoutes.ts` | Modify | `resizer` file href → path form `/resizer/{id}` |
| `src/services/mutate.ts` | Modify | `createResizerFile`, `downloadResizeZip` |
| `src/services/query.ts` | Modify | `getResizerFile` (file + generations) |
| `src/lib/analytics/resizer-events.ts` | Create | `trackResizerFileCreated`, `trackResizeZipDownloaded` |
| `src/components/studio/resizer/ResizerHeader.tsx` | Create | Title (rename) + "Standalone" pill + Download ZIP |
| `src/components/studio/resizer/ResizerLayout.tsx` | Create | Job orchestrator: no-source → upload; source → panel + canvas |
| `src/app/(dashboard)/brands/[id]/studio/resizer/page.tsx` | Create | "My Resize Files" list |
| `src/app/(canvas)/brands/[id]/studio/resizer/[file_id]/page.tsx` | Create | Job canvas route |
| `src/components/studio/resizer/ResizerLayout.test.tsx` | Create | Component test (no-source vs source) |
| `src/app/(dashboard)/brands/[id]/studio/resizer/page.test.tsx` | Create | List page test (empty + rows) |

Reused unchanged: `KvResizePanel`, `KvResizeCanvas`, `KvUploadBaseBlock`, `useResizeExports`, `useKvResizeStore`, `measureImageSize`, `uploadKvAttachment`, `promoteAttachmentToBase`, `StudioAllFilesGrid`, `useStudioGallery`, `updateStudioFile`, `ModuleHubShell`, `Button`, `Input`, `FileEmptyState`.

---

## Task 1: Un-gate the Resizer tile + fix its route

**Files:**
- Modify: `src/lib/studioTools.ts`
- Modify: `src/lib/studioRoutes.ts`
- Test: `src/lib/studioTools.test.ts` (create if absent)

**Interfaces:**
- Produces: `normalizeStudioTools(...)` returns the `resizer` tool with `isComingSoon === false` and `href === \`${studioBase}/resizer\`` when the KV flag is on; `studioFileHref(brandId, "resizer", id) === \`/brands/${brandId}/studio/resizer/${id}\``.

- [ ] **Step 1: Write the failing test**

Create `src/lib/studioTools.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { normalizeStudioTools } from "./studioTools";
import { studioFileHref } from "./studioRoutes";

const base = "/brands/b1/studio";

const resizerTool = {
  id: "t-resizer",
  slug: "resizer",
  name: "Resizer",
  description: "Resize approved assets.",
  icon_url: "",
  video_url: "",
  href: "/studio/resizer",
  status: "live",
  category: "visual",
  submenu: null,
} as never;

describe("studio tools — resizer", () => {
  it("is live (not coming soon) and routes to the resizer tool when KV is enabled", () => {
    const [tool] = normalizeStudioTools([resizerTool], base, true);
    expect(tool.isComingSoon).toBe(false);
    expect(tool.href).toBe(`${base}/resizer`);
  });

  it("is hidden when the KV generator flag is off", () => {
    const tools = normalizeStudioTools([resizerTool], base, false);
    expect(tools.find((t) => t.slug === "resizer")).toBeUndefined();
  });

  it("builds a path-form file href", () => {
    expect(studioFileHref("b1", "resizer", "f9")).toBe(
      "/brands/b1/studio/resizer/f9",
    );
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web && bun test src/lib/studioTools.test.ts`
Expected: FAIL — resizer still coming-soon / href is `/studio/resizer` / hidden logic missing.

- [ ] **Step 3: Edit `studioTools.ts`**

Change the coming-soon override (line 13) to drop `resizer`:

```ts
export const COMING_SOON_OVERRIDE_SLUGS = ["image-editor"];
```

In `normalizeStudioTools`, extend the KV-flag filter (line 35) to also hide `resizer` when the flag is off, and add a `resizer` href branch (lines 43-44):

```ts
    .filter(
      (t) =>
        kvGeneratorEnabled ||
        (t.slug !== "kv-generator" && t.slug !== "resizer"),
    )
    .map((t) => ({
      id: t.id,
      slug: t.slug,
      name: t.name,
      description: t.description,
      iconSrc: t.icon_url ?? "",
      videoSrc: t.video_url ?? "",
      href:
        t.slug === "kv-generator"
          ? `${studioBase}/kv-generator/new`
          : t.slug === "resizer"
            ? `${studioBase}/resizer`
            : t.href,
      isComingSoon:
        t.status === "coming_soon" ||
        COMING_SOON_OVERRIDE_SLUGS.includes(t.slug),
      category: t.category,
      submenu: t.submenu,
    }));
```

- [ ] **Step 4: Edit `studioRoutes.ts`**

Change the `resizer` entry from the query-param form to a path segment:

```ts
    resizer: (base, id) => `${base}/resizer/${id}`,
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd web && bun test src/lib/studioTools.test.ts`
Expected: PASS (3 pass).

- [ ] **Step 6: Commit**

```bash
cd web && git add src/lib/studioTools.ts src/lib/studioRoutes.ts src/lib/studioTools.test.ts
git commit -m "feat(web): un-gate resizer tile and route to standalone resizer"
```

---

## Task 2: Services + analytics for the resizer

**Files:**
- Modify: `src/services/mutate.ts` (add `createResizerFile`, `downloadResizeZip`)
- Modify: `src/services/query.ts` (add `getResizerFile`)
- Create: `src/lib/analytics/resizer-events.ts`

**Interfaces:**
- Produces:
  - `createResizerFile(body: { project_id?: string; brand_id: string }): Promise<{ data: StudioFile }>`
  - `getResizerFile(fileId: string): Promise<{ data: StudioFile; generations: KvGeneration[] }>`
  - `downloadResizeZip(fileId: string, fileName: string): Promise<void>` (fetches the zip WITH auth via axios blob, triggers a browser download)
  - `trackResizerFileCreated(props: { file_id: string; brand_id: string })`, `trackResizeZipDownloaded(props: { file_id: string; export_count: number })`

- [ ] **Step 1: Add `createResizerFile` + `downloadResizeZip` to `mutate.ts`**

Append near `createKvFile` (line 2773). Reuse the existing `axiosInstance` import already at the top of the file:

```ts
export const createResizerFile = async (body: {
  project_id?: string;
  brand_id: string;
}): Promise<{ data: StudioFile }> => {
  const response = await axiosInstance.post(`v1/studio/resizer/files`, body);
  return response.data;
};

/**
 * Download every completed resize export as a single zip. The endpoint is
 * Bearer-auth-gated, so we fetch it as a blob through axios (which carries the
 * auth header) rather than a bare anchor navigation, then trigger a client-side
 * download.
 */
export const downloadResizeZip = async (
  fileId: string,
  fileName: string,
): Promise<void> => {
  const res = await axiosInstance.get(
    `v1/studio/files/${fileId}/resize-exports/download-zip`,
    { responseType: "blob" },
  );
  const url = URL.createObjectURL(res.data as Blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = `resize-${fileName || "export"}.zip`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
};
```

- [ ] **Step 2: Add `getResizerFile` to `query.ts`**

In `src/services/query.ts`, add (import `KvGeneration` from the SAME module `promoteAttachmentToBase.ts` imports it from — verify with `grep "import type { KvGeneration" src/components/studio/kv-generator/promoteAttachmentToBase.ts`; and `StudioFile` from `@/types/studio`):

```ts
export async function getResizerFile(
  fileId: string,
): Promise<{ data: StudioFile; generations: KvGeneration[] }> {
  const { data } = await axiosInstance.get(`v1/studio/resizer/files/${fileId}`);
  return data;
}
```

- [ ] **Step 3: Create the analytics module**

Read `src/lib/analytics/kv-generator-events.ts` and mirror its exact capture wrapper + import. Create `src/lib/analytics/resizer-events.ts` with the same structure, e.g.:

```ts
// Mirror the capture helper import used by kv-generator-events.ts.
import { captureStudioEvent } from "./kv-generator-events"; // if it re-exports one; else copy the posthog capture pattern verbatim from that file

export function trackResizerFileCreated(props: {
  file_id: string;
  brand_id: string;
}): void {
  captureStudioEvent("resizer_file_created", props);
}

export function trackResizeZipDownloaded(props: {
  file_id: string;
  export_count: number;
}): void {
  captureStudioEvent("resize_zip_downloaded", props);
}
```

> If `kv-generator-events.ts` does not export a reusable `captureStudioEvent`, copy its exact posthog `capture(...)` call pattern (and base-context handling) into these two functions instead of importing. The event names MUST be `resizer_file_created` and `resize_zip_downloaded` (snake_case).

- [ ] **Step 4: Type-check**

Run: `cd web && bun run build`
Expected: build succeeds (no type errors). If `KvGeneration`/`captureStudioEvent` import paths are wrong, fix them per the verify notes above.

- [ ] **Step 5: Commit**

```bash
cd web && git add src/services/mutate.ts src/services/query.ts src/lib/analytics/resizer-events.ts
git commit -m "feat(web): add resizer file services + analytics events"
```

---

## Task 3: ResizerHeader

**Files:**
- Create: `src/components/studio/resizer/ResizerHeader.tsx`

**Interfaces:**
- Produces: `ResizerHeader` — props `{ fileName: string; onRename: (name: string) => void | Promise<void>; canDownloadZip: boolean; onDownloadZip: () => void; downloadingZip?: boolean }`. Renders an inline-editable title, a "Standalone" `Label` pill, and a Download-ZIP `Button` (disabled when `!canDownloadZip`).

- [ ] **Step 1: Write the component**

Create `src/components/studio/resizer/ResizerHeader.tsx` (use frndos `Button` + `Label`; check `@/components/frndos` exports — mirror how `KvCanvasTopNav` imports them):

```tsx
"use client";

import { useEffect, useState } from "react";
import { DownloadSimple } from "@phosphor-icons/react";
import { Button } from "@/components/frndos/Button";
import { Label } from "@/components/frndos/Label";

type Props = {
  fileName: string;
  onRename: (name: string) => void | Promise<void>;
  canDownloadZip: boolean;
  onDownloadZip: () => void;
  downloadingZip?: boolean;
};

export function ResizerHeader({
  fileName,
  onRename,
  canDownloadZip,
  onDownloadZip,
  downloadingZip,
}: Props) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(fileName);

  useEffect(() => {
    setDraft(fileName);
  }, [fileName]);

  const commit = () => {
    const next = draft.trim();
    setEditing(false);
    if (next && next !== fileName) void onRename(next);
    else setDraft(fileName);
  };

  return (
    <div className="flex h-[64px] shrink-0 items-center justify-between border-b border-neutral-800 px-6">
      <div className="flex items-center gap-3">
        {editing ? (
          <input
            autoFocus
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onBlur={commit}
            onKeyDown={(e) => {
              if (e.key === "Enter") commit();
              if (e.key === "Escape") {
                setDraft(fileName);
                setEditing(false);
              }
            }}
            className="rounded bg-neutral-800 px-2 py-1 text-base font-semibold outline-none"
          />
        ) : (
          <button
            type="button"
            onClick={() => setEditing(true)}
            className="text-base font-semibold"
          >
            {fileName || "Untitled Resize Job"}
          </button>
        )}
        <Label variant="translucent" size="small">
          Standalone
        </Label>
      </div>
      <Button
        variant="secondary"
        size="medium"
        disabled={!canDownloadZip || downloadingZip}
        onClick={onDownloadZip}
      >
        <DownloadSimple size={16} />
        Download ZIP
      </Button>
    </div>
  );
}
```

> Verify `Label`'s `variant`/`size` prop values and `Button`'s `variant`/`size` values against their actual definitions in `@/components/frndos` (mirror a nearby call site like `KvCanvasTopNav.tsx`). Adjust prop values if the components use different names.

- [ ] **Step 2: Type-check**

Run: `cd web && bun run build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
cd web && git add src/components/studio/resizer/ResizerHeader.tsx
git commit -m "feat(web): add ResizerHeader (title, standalone pill, download zip)"
```

---

## Task 4: ResizerLayout — the job orchestrator

**Files:**
- Create: `src/components/studio/resizer/ResizerLayout.tsx`
- Test: `src/components/studio/resizer/ResizerLayout.test.tsx`

**Interfaces:**
- Consumes: `getResizerFile` (Task 2), `downloadResizeZip` (Task 2), `trackResizeZipDownloaded` (Task 2), `updateStudioFile` (`@/services/mutate`), `ResizerHeader` (Task 3), the reused resize components/hooks, and the upload chain (`measureImageSize`, `uploadKvAttachment`, `promoteAttachmentToBase`, `getSession`, `getValidAccessToken`).
- Produces: `ResizerLayout` — props `{ fileId: string; brandId: string }`. Renders the header + (no source → `KvUploadBaseBlock`; source → `KvResizePanel` + `KvResizeCanvas`).

- [ ] **Step 1: Write the failing component test**

Create `src/components/studio/resizer/ResizerLayout.test.tsx`:

```tsx
import { describe, expect, it, vi, beforeEach } from "vitest";
import { render, screen } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { ResizerLayout } from "./ResizerLayout";

vi.mock("@/services/query", () => ({
  getResizerFile: vi.fn(),
}));
import { getResizerFile } from "@/services/query";

function renderWithClient(ui: React.ReactElement) {
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });
  return render(
    <QueryClientProvider client={qc}>{ui}</QueryClientProvider>,
  );
}

describe("ResizerLayout", () => {
  beforeEach(() => vi.clearAllMocks());

  it("shows the upload dropzone when the file has no source", async () => {
    (getResizerFile as unknown as ReturnType<typeof vi.fn>).mockResolvedValue({
      data: { id: "f1", name: "Untitled Resize Job" },
      generations: [],
    });

    renderWithClient(<ResizerLayout fileId="f1" brandId="b1" />);

    expect(await screen.findByText("Upload Source Image")).toBeInTheDocument();
  });

  it("shows the platform picker once a source generation exists", async () => {
    (getResizerFile as unknown as ReturnType<typeof vi.fn>).mockResolvedValue({
      data: { id: "f1", name: "Summer KV" },
      generations: [
        {
          id: "g1",
          image_url: "https://s3.test/src.png",
          version_number: 1,
          metadata: { width: 1080, height: 1080 },
        },
      ],
    });

    renderWithClient(<ResizerLayout fileId="f1" brandId="b1" />);

    // KvResizePanel renders the platform groups
    expect(await screen.findByText("Social Media")).toBeInTheDocument();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web && bun test src/components/studio/resizer/ResizerLayout.test.tsx`
Expected: FAIL — `ResizerLayout` module not found.

- [ ] **Step 3: Write `ResizerLayout.tsx`**

Create `src/components/studio/resizer/ResizerLayout.tsx`:

```tsx
"use client";

import { useCallback, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { getResizerFile } from "@/services/query";
import { downloadResizeZip, updateStudioFile } from "@/services/mutate";
import { trackResizeZipDownloaded } from "@/lib/analytics/resizer-events";
import { getSession } from "@/lib/session";
import { getValidAccessToken } from "@/services/axios";
import { measureImageSize } from "../kv-generator/measureImageSize";
import { uploadKvAttachment } from "../kv-generator/uploadAttachment";
import { promoteAttachmentToBase } from "../kv-generator/promoteAttachmentToBase";
import { KvUploadBaseBlock } from "../kv-generator/KvUploadBaseBlock";
import { KvResizePanel } from "../kv-generator/KvResizePanel";
import { KvResizeCanvas } from "../kv-generator/KvResizeCanvas";
import { useResizeExports } from "@/lib/studio/kv/useResizeExports";
import { useKvResizeStore } from "@/store/kv/useKvResizeStore";
import { ResizerHeader } from "./ResizerHeader";

type CanvasTool = "cursor" | "hand" | "frame" | "text" | "image";

const RESIZER_FILE_KEY = (fileId: string) => ["studio", "resizer-file", fileId];

export function ResizerLayout({
  fileId,
  brandId: _brandId,
}: {
  fileId: string;
  brandId: string;
}) {
  const qc = useQueryClient();
  const fileQuery = useQuery({
    queryKey: RESIZER_FILE_KEY(fileId),
    queryFn: () => getResizerFile(fileId),
  });
  const file = fileQuery.data?.data;
  const source = fileQuery.data?.generations?.[0] ?? null;

  const [uploading, setUploading] = useState(false);
  const [downloadingZip, setDownloadingZip] = useState(false);
  const [layersOpen, setLayersOpen] = useState(false);
  const [canvasTool, setCanvasTool] = useState<CanvasTool>("cursor");

  const selectedPlatformIds = useKvResizeStore((s) => s.selectedPlatformIds);
  const togglePlatform = useKvResizeStore((s) => s.togglePlatform);
  const resizePrompt = useKvResizeStore((s) => s.resizePrompt);
  const setResizePrompt = useKvResizeStore((s) => s.setResizePrompt);

  const {
    create: createResize,
    regenerate: regenerateResize,
    remove: removeResize,
    cancel: cancelResize,
    exportsByPlatformId,
  } = useResizeExports(fileId, source?.id ?? null);

  const handleUpload = useCallback(
    async (uploadFile: File) => {
      setUploading(true);
      try {
        const { width, height } = await measureImageSize(uploadFile);
        const baseUrl = (process.env.NEXT_PUBLIC_API_URL ?? "").replace(
          /\/$/,
          "",
        );
        const refreshed = await getValidAccessToken().catch(() => null);
        const token = refreshed ?? getSession().accessToken ?? null;
        const [descriptor] = await uploadKvAttachment([uploadFile], {
          baseUrl,
          token,
        });
        if (!descriptor?.url) throw new Error("upload returned no url");
        const imported = await promoteAttachmentToBase({
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
          canvasMode: "sketch",
        });
        if (!imported) throw new Error("import failed");
        await qc.invalidateQueries({ queryKey: RESIZER_FILE_KEY(fileId) });
      } catch (err) {
        console.error("[resizer] upload failed", err);
      } finally {
        setUploading(false);
      }
    },
    [fileId, qc],
  );

  const doneCount = [...exportsByPlatformId.values()].filter(
    (e) => e.status === "done",
  ).length;

  const handleDownloadZip = useCallback(async () => {
    setDownloadingZip(true);
    try {
      await downloadResizeZip(fileId, file?.name ?? "export");
      trackResizeZipDownloaded({ file_id: fileId, export_count: doneCount });
    } catch (err) {
      console.error("[resizer] zip download failed", err);
    } finally {
      setDownloadingZip(false);
    }
  }, [fileId, file?.name, doneCount]);

  return (
    <div className="flex h-screen flex-col bg-neutral-950 text-neutral-100">
      <ResizerHeader
        fileName={file?.name ?? "Untitled Resize Job"}
        onRename={async (name) => {
          await updateStudioFile(fileId, { name });
          await qc.invalidateQueries({ queryKey: RESIZER_FILE_KEY(fileId) });
        }}
        canDownloadZip={doneCount > 0}
        onDownloadZip={handleDownloadZip}
        downloadingZip={downloadingZip}
      />

      {!source ? (
        <div className="flex flex-1 flex-col items-center justify-center gap-6 p-8">
          <div className="text-center">
            <h2 className="text-2xl font-semibold">Upload Source Image</h2>
            <p className="mt-1 text-sm text-neutral-400">
              Drag &amp; drop a high-resolution asset to begin.
            </p>
          </div>
          <div className="w-full max-w-2xl">
            <KvUploadBaseBlock onUpload={handleUpload} busy={uploading} />
          </div>
        </div>
      ) : (
        <div className="flex flex-1 overflow-hidden">
          <div className="w-[232px] shrink-0 overflow-y-auto border-r border-neutral-800">
            <KvResizePanel
              disabled={createResize.isPending}
              selectedIds={selectedPlatformIds}
              exportsByPlatformId={exportsByPlatformId}
              onToggle={togglePlatform}
              resizePrompt={resizePrompt}
              onResizePromptChange={setResizePrompt}
              onResize={() => {
                const queued = [...selectedPlatformIds].filter(
                  (id) => !exportsByPlatformId.has(id),
                );
                if (!queued.length) return;
                createResize.mutate({
                  platformIds: queued,
                  additionalPrompt: resizePrompt || null,
                });
                setResizePrompt("");
              }}
              onRemove={(pid) => {
                const ex = exportsByPlatformId.get(pid);
                if (ex) removeResize.mutate(ex.id);
              }}
              onRetry={(pid) => {
                const ex = exportsByPlatformId.get(pid);
                if (ex) regenerateResize.mutate({ exportId: ex.id });
              }}
              onCancel={(pid) => {
                const ex = exportsByPlatformId.get(pid);
                if (ex) cancelResize.mutate(ex.id);
              }}
            />
          </div>
          <div className="flex-1 overflow-auto">
            <KvResizeCanvas
              fileId={fileId}
              fileName={file?.name ?? "resize"}
              source={source}
              layersOpen={layersOpen}
              onRequestLayersOpen={() => setLayersOpen(true)}
              onRequestLayersClose={() => setLayersOpen(false)}
              tool={canvasTool}
              onToolChange={setCanvasTool}
              brandId={null}
              onSavePreset={async () => {}}
              savingPreset={false}
            />
          </div>
        </div>
      )}
    </div>
  );
}
```

> `brandId` is passed as `null` to `KvResizeCanvas` in v1 to suppress the craft-preset "Save as template" affordance (resize-only doesn't manage brand presets). The layout still receives the real `brandId` prop for future use; it's intentionally unused now (`_brandId`).

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web && bun test src/components/studio/resizer/ResizerLayout.test.tsx`
Expected: PASS (2 pass). If `KvResizeCanvas` throws in jsdom on the source branch (canvas APIs), narrow the second test to assert `KvResizePanel`'s "Social Media" text only, or mock `./KvResizeCanvas` with `vi.mock`. Prefer mocking `KvResizeCanvas` if it needs a real canvas context.

- [ ] **Step 5: Type-check + commit**

```bash
cd web && bun run build
git add src/components/studio/resizer/ResizerLayout.tsx src/components/studio/resizer/ResizerLayout.test.tsx
git commit -m "feat(web): add ResizerLayout resize-only orchestrator"
```

---

## Task 5: Job canvas route

**Files:**
- Create: `src/app/(canvas)/brands/[id]/studio/resizer/[file_id]/page.tsx`

**Interfaces:**
- Consumes: `ResizerLayout` (Task 4).

- [ ] **Step 1: Write the page (mirror the KV job page exactly)**

Create `src/app/(canvas)/brands/[id]/studio/resizer/[file_id]/page.tsx`:

```tsx
import { use } from "react";
import { ResizerLayout } from "@/components/studio/resizer/ResizerLayout";

export default function ResizerFilePage({
  params,
}: {
  params: Promise<{ id: string; file_id: string }>;
}) {
  const { id, file_id } = use(params);
  return <ResizerLayout fileId={file_id} brandId={id} />;
}
```

- [ ] **Step 2: Type-check + commit**

```bash
cd web && bun run build
git add "src/app/(canvas)/brands/[id]/studio/resizer/[file_id]/page.tsx"
git commit -m "feat(web): add resizer job canvas route"
```

---

## Task 6: "My Resize Files" list page

**Files:**
- Create: `src/app/(dashboard)/brands/[id]/studio/resizer/page.tsx`
- Test: `src/app/(dashboard)/brands/[id]/studio/resizer/page.test.tsx`

**Interfaces:**
- Consumes: `useStudioGallery` (filter `tool.slug === "resizer"`), `StudioAllFilesGrid`, `createResizerFile` + `trackResizerFileCreated` (Task 2), `ModuleHubShell`, `Button`, `Input`, `FileEmptyState`.
- Produces: the `/brands/[id]/studio/resizer` page — search + "New Resize" (creates a file, routes to `[file_id]`), grid of resizer files, empty state when none.

- [ ] **Step 1: Write the failing test**

Create `src/app/(dashboard)/brands/[id]/studio/resizer/page.test.tsx`:

```tsx
import { describe, expect, it, vi, beforeEach } from "vitest";
import { render, screen } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import ResizerListPage from "./page";

vi.mock("next/navigation", () => ({
  useParams: () => ({ id: "b1" }),
  useRouter: () => ({ push: vi.fn() }),
}));
vi.mock("@/hooks/useWorkspace", () => ({
  useWorkspace: () => ({ currentWorkspace: { id: "w1" } }),
}));
vi.mock("@/hooks/useStudioGallery", () => ({ useStudioGallery: vi.fn() }));
import { useStudioGallery } from "@/hooks/useStudioGallery";

function renderPage() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={qc}>
      <ResizerListPage />
    </QueryClientProvider>,
  );
}

describe("My Resize Files page", () => {
  beforeEach(() => vi.clearAllMocks());

  it("shows the empty state when there are no resizer files", () => {
    (useStudioGallery as unknown as ReturnType<typeof vi.fn>).mockReturnValue({
      data: { data: [] },
    });
    renderPage();
    expect(screen.getByText(/no resize/i)).toBeInTheDocument();
  });

  it("lists only resizer-tool files", () => {
    (useStudioGallery as unknown as ReturnType<typeof vi.fn>).mockReturnValue({
      data: {
        data: [
          {
            id: "f1",
            name: "Summer KV",
            tool: { slug: "resizer" },
            thumbnail_url: null,
            last_edited_at: "2026-07-14T00:00:00Z",
            last_edited_by: { name: "Novi" },
          },
          {
            id: "f2",
            name: "A KV file",
            tool: { slug: "kv-generator" },
            thumbnail_url: null,
            last_edited_at: "2026-07-14T00:00:00Z",
            last_edited_by: { name: "Novi" },
          },
        ],
      },
    });
    renderPage();
    expect(screen.getByText("Summer KV")).toBeInTheDocument();
    expect(screen.queryByText("A KV file")).not.toBeInTheDocument();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web && bun test "src/app/(dashboard)/brands/[id]/studio/resizer/page.test.tsx"`
Expected: FAIL — `./page` not found.

- [ ] **Step 3: Write the page**

Create `src/app/(dashboard)/brands/[id]/studio/resizer/page.tsx`. Model the structure on `all-files/page.tsx` (search + `ModuleHubShell` + `StudioAllFilesGrid`), filter to `resizer`, and add a "New Resize" action:

```tsx
"use client";

import { Suspense, useMemo, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import { MagnifyingGlass, Plus } from "@phosphor-icons/react";
import { useMutation } from "@tanstack/react-query";
import { Button } from "@/components/frndos/Button";
import { Input, ModuleHubShell } from "@/components/frndos";
import { StudioAllFilesGrid } from "@/components/studio";
import { useStudioGallery } from "@/hooks/useStudioGallery";
import { useWorkspace } from "@/hooks/useWorkspace";
import { createResizerFile } from "@/services/mutate";
import { trackResizerFileCreated } from "@/lib/analytics/resizer-events";
import type { StudioAllFileItem, StudioFile } from "@/types/studio";

function ResizerListContent() {
  const params = useParams();
  const router = useRouter();
  const brandId = params.id as string;
  const { currentWorkspace } = useWorkspace();
  const [search, setSearch] = useState("");

  const { data } = useStudioGallery(currentWorkspace?.id, brandId);

  const rawFiles = ((data?.data ?? []) as StudioFile[]).filter(
    (f) => f.tool?.slug === "resizer",
  );

  const items: StudioAllFileItem[] = useMemo(() => {
    const q = search.trim().toLowerCase();
    return rawFiles
      .filter((f) => !q || f.name.toLowerCase().includes(q))
      .map((f) => ({
        id: f.id,
        title: f.name,
        thumbnailSrc: f.thumbnail_url ?? undefined,
        editedLabel: f.last_edited_at ?? "",
        editorName: f.last_edited_by?.name ?? "",
        fileType: "resizer",
        toolName: "Resizer",
        projectName: f.project?.name,
      }));
  }, [rawFiles, search]);

  const createMutation = useMutation({
    mutationFn: () => createResizerFile({ brand_id: brandId }),
    onSuccess: (res) => {
      trackResizerFileCreated({ file_id: res.data.id, brand_id: brandId });
      router.push(`/brands/${brandId}/studio/resizer/${res.data.id}`);
    },
  });

  return (
    <ModuleHubShell
      lead={
        <div className="flex items-center justify-between">
          <h1 className="text-2xl font-semibold">My Resize Files</h1>
          <Button
            variant="primary"
            size="medium"
            onClick={() => createMutation.mutate()}
            disabled={createMutation.isPending}
          >
            <Plus size={16} />
            New Resize
          </Button>
        </div>
      }
    >
      <div className="flex flex-col gap-6">
        <Input
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Search files..."
          icon={<MagnifyingGlass size={16} />}
        />

        {items.length === 0 ? (
          <div className="flex flex-col items-center justify-center gap-4 rounded-2xl border border-dashed border-neutral-800 py-24 text-center">
            <h2 className="text-lg font-semibold">No resize jobs yet</h2>
            <p className="max-w-sm text-sm text-neutral-400">
              Upload a master campaign image to adapt it to all platform sizes.
            </p>
            <Button
              variant="primary"
              size="large"
              onClick={() => createMutation.mutate()}
              disabled={createMutation.isPending}
            >
              Create your first resize job
            </Button>
          </div>
        ) : (
          <StudioAllFilesGrid items={items} brandId={brandId} />
        )}
      </div>
    </ModuleHubShell>
  );
}

export default function ResizerListPage() {
  return (
    <Suspense
      fallback={
        <div className="flex min-h-screen items-center justify-center text-neutral-400">
          Loading resize files…
        </div>
      }
    >
      <ResizerListContent />
    </Suspense>
  );
}
```

> Verify against `all-files/page.tsx`: the exact `Input` prop for the leading icon (it may be `leftIcon`/`prefix` rather than `icon`), and the `ModuleHubShell` `lead` usage. Mirror the real props; adjust if they differ. `StudioAllFilesGrid` renders each item via `studioFileHref(brandId, "resizer", id)` → `/brands/{brandId}/studio/resizer/{id}` (Task 1), so row clicks route correctly.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web && bun test "src/app/(dashboard)/brands/[id]/studio/resizer/page.test.tsx"`
Expected: PASS (2 pass).

- [ ] **Step 5: Type-check + commit**

```bash
cd web && bun run build
git add "src/app/(dashboard)/brands/[id]/studio/resizer/page.tsx" \
        "src/app/(dashboard)/brands/[id]/studio/resizer/page.test.tsx"
git commit -m "feat(web): add My Resize Files list page"
```

---

## Task 7: Full-suite + build gate

- [ ] **Step 1: Run the new web tests**

Run: `cd web && bun test src/lib/studioTools.test.ts src/components/studio/resizer/ResizerLayout.test.tsx "src/app/(dashboard)/brands/[id]/studio/resizer/page.test.tsx"`
Expected: all pass.

- [ ] **Step 2: Build gate**

Run: `cd web && bun run build`
Expected: build succeeds with no type errors.

- [ ] **Step 3: Manual smoke (with the dev server + API running)**

Verify end-to-end in the browser preview: Studio → Resizer tile is live → lands on "My Resize Files" (empty state) → "New Resize" opens an Untitled Resize Job → upload an image → source renders → check 2–3 platforms → Resize → exports render → "Download ZIP" downloads a zip of the completed exports.

- [ ] **Step 4: Final commit (if any formatting)**

```bash
cd web && git add -A && git commit -m "chore(web): resizer smoke fixes" --allow-empty
```

---

## Self-review notes (verified against the spec)

- **Spec Screen A (My Resize Files list):** Task 6 — search, New Resize, grid, empty state, tool-scoped filter. ✓
- **Spec Screen B (job canvas):** Tasks 3–5 — header (title + Standalone pill + Download ZIP), upload empty state, resize-only panel + canvas. ✓
- **Spec §Web reused-as-is:** `KvResizePanel`, `KvResizeCanvas`, `KvUploadBaseBlock`, `useResizeExports`, `useKvResizeStore`, upload chain — all reused, none forked. ✓
- **Spec §Web config edits:** Task 1 — un-gate tile + path-form route. ✓
- **Spec Download ZIP:** Task 2 (`downloadResizeZip`, auth-blob) + Task 3/4 (button, disabled until ≥1 done). ✓
- **Spec analytics:** `resizer_file_created` (Task 6), `resize_zip_downloaded` (Task 4). ✓
- **Spec edge — no-source Download-ZIP disabled:** `canDownloadZip={doneCount > 0}`. ✓
- **Type-consistency:** `RESIZER_FILE_KEY` used identically in `ResizerLayout` invalidations; `createResize.mutate({ platformIds, additionalPrompt })` matches `useResizeExports.create` vars; `regenerateResize.mutate({ exportId })` matches; `remove/cancel.mutate(ex.id)` take a string. ✓
- **Known v1 tradeoffs recorded:** `brandId={null}` to `KvResizeCanvas` suppresses craft presets; a few frndos prop names (`Input` icon, `Label`/`Button` variants) flagged to verify against real call sites. ✓
