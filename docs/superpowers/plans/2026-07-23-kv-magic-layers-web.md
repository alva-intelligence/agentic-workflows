# KV Magic Layers — web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** "Separate into layers" action on the KV craft empty-canvas upload entry: upload the image, create a magic-layer job, poll it, and on completion inject the background board + image overlays into the Yjs doc; on failure fall back to a plain base import.

**Architecture:** New api-service functions (axios + `unwrap`, inline path template — the repo convention), a pure helper module (`magicLayers.ts`) for job start + polling (testable with mocked api), a two-action choice in `KvUploadBaseBlock` (only when the new optional prop is passed — the standalone-resizer render site is untouched), and a `handleSeparateLayers` callback in `KvGeneratorLayout` modeled on `handleUploadBase` + `handlePasteBoard`'s additive board injection. Overlays are replayed into the doc explicitly via `docAddOverlay` (dedup-by-id makes the REST-recovery effect a harmless second net).

**Tech Stack:** Next.js 16 / React 19, TypeScript, TanStack Query, Yjs (`yjsSerializer` helpers), vitest-style tests run via `bun test`.

## Global Constraints

- Branch: `feature/daffa/vc-kv-magic-layers` from `origin/develop`. Setup inside `web/`: `git fetch origin && git checkout -b feature/daffa/vc-kv-magic-layers origin/develop`.
- Spec: `docs/superpowers/specs/2026-07-23-kv-magic-layers-design.md` (workspace root repo).
- API endpoints (from the api plan): `POST v1/studio/kv-generator/files/{fileId}/magic-layer-jobs`, `GET v1/studio/kv-generator/files/{fileId}/magic-layer-jobs/{jobId}`. Job resource: `{id, studio_file_id, status: "pending"|"generating"|"done"|"failed", error_message, background_url, generation: KvGeneration|null, overlays: StudioOverlay-shaped[], created_at}`. Sentinel failure: `error_message === "no_layers_detected"`.
- Tests run with `bun test` (bunfig preloads jest-dom); the type gate is `bun run build` (build does NOT type-check individual edits — run it at the end).
- User-facing copy is Bahasa Indonesia, matching the existing `transientNotice` strings.
- Commits: `feat(web): …` / `test(web): …`.

---

### Task 1: Types + api service functions

**Files:**
- Modify: `web/src/types/studio.ts` (append after `StudioOverlayAssetUpload`, ~line 552)
- Modify: `web/src/services/kv/api.ts` (append near `importKvGenerationFromUpload`, line 230)
- Test: `web/src/services/kv/api.test.ts` (append a describe block, following the file's existing axios-mock setup)

**Interfaces:**
- Produces (consumed by Tasks 2 and 4):
  ```ts
  export type KvMagicLayerJobStatus = "pending" | "generating" | "done" | "failed";
  export type KvMagicLayerJob = {
    id: string;
    studio_file_id: string;
    status: KvMagicLayerJobStatus;
    error_message: string | null;
    background_url: string | null;
    generation: KvGeneration | null;
    overlays: StudioOverlay[];
    created_at: string;
  };
  createKvMagicLayerJob(fileId: string, body: {image_url; mime_type; size; width; height; canvas_mode?}): Promise<KvMagicLayerJob>
  getKvMagicLayerJob(fileId: string, jobId: string): Promise<KvMagicLayerJob>
  ```

- [ ] **Step 1: Write the failing test**

Append to `web/src/services/kv/api.test.ts`, reusing the file's existing `axiosInstance` mock (match the surrounding describe blocks' setup — the file already mocks `@/services/axios`):

```ts
describe("magic layer jobs", () => {
  it("creates a job via POST and unwraps data", async () => {
    mockPost.mockResolvedValue({ data: { data: { id: "job_1", status: "pending" } } });
    const job = await createKvMagicLayerJob("file_1", {
      image_url: "https://s3/x.png",
      mime_type: "image/png",
      size: 10,
      width: 100,
      height: 100,
      canvas_mode: "craft",
    });
    expect(mockPost).toHaveBeenCalledWith(
      "v1/studio/kv-generator/files/file_1/magic-layer-jobs",
      expect.objectContaining({ image_url: "https://s3/x.png" }),
    );
    expect(job.id).toBe("job_1");
  });

  it("fetches a job via GET and unwraps data", async () => {
    mockGet.mockResolvedValue({ data: { data: { id: "job_1", status: "done" } } });
    const job = await getKvMagicLayerJob("file_1", "job_1");
    expect(mockGet).toHaveBeenCalledWith(
      "v1/studio/kv-generator/files/file_1/magic-layer-jobs/job_1",
    );
    expect(job.status).toBe("done");
  });
});
```

(`mockPost`/`mockGet` are whatever the existing test file names its axios mocks — reuse them; if the file only mocks `post`, add the `get` mock alongside in the same `vi.mock` factory.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/services/kv/api.test.ts`
Expected: FAIL — `createKvMagicLayerJob` is not exported

- [ ] **Step 3: Implement types + service functions**

Append to `web/src/types/studio.ts`:

```ts
export type KvMagicLayerJobStatus = "pending" | "generating" | "done" | "failed";

/** Async magic-layer decomposition job (upload → subjects/text/background layers). */
export type KvMagicLayerJob = {
  id: string;
  studio_file_id: string;
  status: KvMagicLayerJobStatus;
  error_message: string | null;
  background_url: string | null;
  generation: KvGeneration | null;
  overlays: StudioOverlay[];
  created_at: string;
};
```

Append to `web/src/services/kv/api.ts` (import `KvMagicLayerJob` in the existing type import from `@/types/studio`):

```ts
export async function createKvMagicLayerJob(
  fileId: string,
  body: {
    image_url: string;
    mime_type: string;
    size: number;
    width: number;
    height: number;
    canvas_mode?: "sketch" | "craft";
  },
): Promise<KvMagicLayerJob> {
  const { data } = await axiosInstance.post(
    `v1/studio/kv-generator/files/${fileId}/magic-layer-jobs`,
    body,
  );
  return unwrap(data);
}

export async function getKvMagicLayerJob(
  fileId: string,
  jobId: string,
): Promise<KvMagicLayerJob> {
  const { data } = await axiosInstance.get(
    `v1/studio/kv-generator/files/${fileId}/magic-layer-jobs/${jobId}`,
  );
  return unwrap(data);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test src/services/kv/api.test.ts`
Expected: PASS (all blocks, old and new)

- [ ] **Step 5: Commit**

```bash
git add src/types/studio.ts src/services/kv/api.ts src/services/kv/api.test.ts
git commit -m "feat(web): magic-layer job types and api client functions"
```

---

### Task 2: `magicLayers.ts` helper (start + poll)

**Files:**
- Create: `web/src/components/studio/kv-generator/magicLayers.ts`
- Test: `web/src/components/studio/kv-generator/magicLayers.test.ts`

**Interfaces:**
- Consumes: Task 1 api functions, `UploadedAttachmentDescriptor` from `./promoteAttachmentToBase`.
- Produces (consumed by Task 4):
  ```ts
  startMagicLayerJob(args: {fileId: string; attachment: UploadedAttachmentDescriptor; canvasMode?: "sketch"|"craft"}): Promise<KvMagicLayerJob | null>
  pollMagicLayerJob(fileId: string, jobId: string, opts?: {intervalMs?: number; maxAttempts?: number; sleep?: (ms: number) => Promise<void>}): Promise<KvMagicLayerJob>
  ```
  `startMagicLayerJob` returns `null` on missing url or any throw (mirrors `promoteAttachmentToBase`). `pollMagicLayerJob` resolves on the first `done`/`failed` job; after `maxAttempts` (default 72 at 2500ms ≈ 3 min) it returns the last job as-is (caller treats non-`done` as failure).

- [ ] **Step 1: Write the failing tests**

```ts
// web/src/components/studio/kv-generator/magicLayers.test.ts
import { describe, it, expect, vi, beforeEach } from "vitest";
import { pollMagicLayerJob, startMagicLayerJob } from "./magicLayers";

const mockCreate = vi.fn();
const mockGet = vi.fn();
vi.mock("@/services/kv/api", () => ({
  createKvMagicLayerJob: (...args: unknown[]) => mockCreate(...args),
  getKvMagicLayerJob: (...args: unknown[]) => mockGet(...args),
}));

const attachment = {
  id: "att_1", name: "x.png", mime_type: "image/png",
  size: 10, url: "https://s3/x.png", width: 100, height: 200,
};

describe("startMagicLayerJob", () => {
  beforeEach(() => mockCreate.mockReset());

  it("creates the job from the attachment descriptor", async () => {
    mockCreate.mockResolvedValue({ id: "job_1", status: "pending" });
    const job = await startMagicLayerJob({ fileId: "f1", attachment, canvasMode: "craft" });
    expect(mockCreate).toHaveBeenCalledWith("f1", {
      image_url: "https://s3/x.png", mime_type: "image/png",
      size: 10, width: 100, height: 200, canvas_mode: "craft",
    });
    expect(job?.id).toBe("job_1");
  });

  it("returns null when the attachment has no url", async () => {
    const job = await startMagicLayerJob({
      fileId: "f1", attachment: { ...attachment, url: undefined },
    });
    expect(job).toBeNull();
    expect(mockCreate).not.toHaveBeenCalled();
  });

  it("returns null and swallows api errors", async () => {
    mockCreate.mockRejectedValue(new Error("nope"));
    expect(await startMagicLayerJob({ fileId: "f1", attachment })).toBeNull();
  });
});

describe("pollMagicLayerJob", () => {
  beforeEach(() => mockGet.mockReset());
  const instantSleep = () => Promise.resolve();

  it("polls until done", async () => {
    mockGet
      .mockResolvedValueOnce({ id: "j", status: "generating" })
      .mockResolvedValueOnce({ id: "j", status: "generating" })
      .mockResolvedValueOnce({ id: "j", status: "done" });
    const job = await pollMagicLayerJob("f1", "j", { sleep: instantSleep });
    expect(job.status).toBe("done");
    expect(mockGet).toHaveBeenCalledTimes(3);
  });

  it("resolves on failed", async () => {
    mockGet.mockResolvedValue({ id: "j", status: "failed", error_message: "no_layers_detected" });
    const job = await pollMagicLayerJob("f1", "j", { sleep: instantSleep });
    expect(job.status).toBe("failed");
  });

  it("returns the last job after maxAttempts", async () => {
    mockGet.mockResolvedValue({ id: "j", status: "generating" });
    const job = await pollMagicLayerJob("f1", "j", { sleep: instantSleep, maxAttempts: 5 });
    expect(job.status).toBe("generating");
    expect(mockGet).toHaveBeenCalledTimes(5);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bun test src/components/studio/kv-generator/magicLayers.test.ts`
Expected: FAIL — module not found

- [ ] **Step 3: Implement magicLayers.ts**

```ts
// web/src/components/studio/kv-generator/magicLayers.ts
import { createKvMagicLayerJob, getKvMagicLayerJob } from "@/services/kv/api";
import type { KvMagicLayerJob } from "@/types/studio";
import type { UploadedAttachmentDescriptor } from "./promoteAttachmentToBase";

const DEFAULT_INTERVAL_MS = 2500;
const DEFAULT_MAX_ATTEMPTS = 72; // ~3 minutes; server also fails stale jobs itself

const realSleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export async function startMagicLayerJob(args: {
  fileId: string;
  attachment: UploadedAttachmentDescriptor;
  canvasMode?: "sketch" | "craft";
}): Promise<KvMagicLayerJob | null> {
  const { fileId, attachment, canvasMode } = args;
  if (!attachment.url) return null;
  try {
    return await createKvMagicLayerJob(fileId, {
      image_url: attachment.url,
      mime_type: attachment.mime_type,
      size: attachment.size,
      width: attachment.width,
      height: attachment.height,
      canvas_mode: canvasMode,
    });
  } catch (err) {
    console.error("[kv] magic-layer job create failed", err);
    return null;
  }
}

export async function pollMagicLayerJob(
  fileId: string,
  jobId: string,
  opts?: {
    intervalMs?: number;
    maxAttempts?: number;
    sleep?: (ms: number) => Promise<void>;
  },
): Promise<KvMagicLayerJob> {
  const intervalMs = opts?.intervalMs ?? DEFAULT_INTERVAL_MS;
  const maxAttempts = opts?.maxAttempts ?? DEFAULT_MAX_ATTEMPTS;
  const sleep = opts?.sleep ?? realSleep;

  let job = await getKvMagicLayerJob(fileId, jobId);
  for (let attempt = 1; attempt < maxAttempts; attempt += 1) {
    if (job.status === "done" || job.status === "failed") return job;
    await sleep(intervalMs);
    job = await getKvMagicLayerJob(fileId, jobId);
  }
  return job;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bun test src/components/studio/kv-generator/magicLayers.test.ts`
Expected: 6 PASS

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/magicLayers.ts src/components/studio/kv-generator/magicLayers.test.ts
git commit -m "feat(web): magic-layer job start + poll helpers"
```

---

### Task 3: `KvUploadBaseBlock` two-action choice

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvUploadBaseBlock.tsx`
- Test: `web/src/components/studio/kv-generator/KvUploadBaseBlock.test.tsx`

**Interfaces:**
- Props gain two optional members (backward compatible — the standalone-resizer render site at `KvGeneratorLayout.tsx:3412` passes neither and keeps today's immediate-upload behavior):
  ```ts
  type Props = {
    onUpload: (file: File) => void;
    onSeparateLayers?: (file: File) => void;
    busy?: boolean;
    busyLabel?: string;
  };
  ```
- Behavior: without `onSeparateLayers`, picking a file calls `onUpload(file)` immediately (unchanged). With it, picking a file holds it in local state and shows two buttons — **"Gunakan sebagai base"** → `onUpload(file)`, **"Pisahkan jadi layer"** → `onSeparateLayers(file)` — plus a small "ganti gambar" reset. `busyLabel` (default "Uploading…") replaces the busy caption so the layout can show "Memisahkan layer…".

- [ ] **Step 1: Write the failing test**

```tsx
// web/src/components/studio/kv-generator/KvUploadBaseBlock.test.tsx
import { describe, it, expect, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import KvUploadBaseBlock from "./KvUploadBaseBlock";

function pickFile(input: HTMLElement) {
  const file = new File(["x"], "x.png", { type: "image/png" });
  fireEvent.change(input, { target: { files: [file] } });
  return file;
}

describe("KvUploadBaseBlock", () => {
  it("uploads immediately when onSeparateLayers is absent", () => {
    const onUpload = vi.fn();
    const { container } = render(<KvUploadBaseBlock onUpload={onUpload} />);
    pickFile(container.querySelector("input[type=file]")!);
    expect(onUpload).toHaveBeenCalledTimes(1);
  });

  it("offers a choice when onSeparateLayers is present", () => {
    const onUpload = vi.fn();
    const onSeparate = vi.fn();
    const { container } = render(
      <KvUploadBaseBlock onUpload={onUpload} onSeparateLayers={onSeparate} />,
    );
    pickFile(container.querySelector("input[type=file]")!);
    expect(onUpload).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole("button", { name: /pisahkan jadi layer/i }));
    expect(onSeparate).toHaveBeenCalledTimes(1);
    expect(onUpload).not.toHaveBeenCalled();
  });

  it("uses base action from the choice", () => {
    const onUpload = vi.fn();
    const { container } = render(
      <KvUploadBaseBlock onUpload={onUpload} onSeparateLayers={vi.fn()} />,
    );
    pickFile(container.querySelector("input[type=file]")!);
    fireEvent.click(screen.getByRole("button", { name: /gunakan sebagai base/i }));
    expect(onUpload).toHaveBeenCalledTimes(1);
  });

  it("shows the custom busy label", () => {
    render(<KvUploadBaseBlock onUpload={vi.fn()} busy busyLabel="Memisahkan layer…" />);
    expect(screen.getByText("Memisahkan layer…")).toBeInTheDocument();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/components/studio/kv-generator/KvUploadBaseBlock.test.tsx`
Expected: FAIL — choice buttons don't exist / busyLabel unsupported

- [ ] **Step 3: Implement**

Modify `KvUploadBaseBlock.tsx`: extend `Props` as in Interfaces; add `const [pickedFile, setPickedFile] = useState<File | null>(null);`. Change `pick()`:

```ts
const pick = (files: FileList | null) => {
  const file = files?.[0];
  if (!file) return;
  if (onSeparateLayers) {
    setPickedFile(file);
    return;
  }
  onUpload(file);
};
```

Busy caption becomes `{busy ? (busyLabel ?? "Uploading…") : "Upload image"}`. When `pickedFile` is set (and not busy), render the choice instead of the dropzone, styled with the block's existing border/typography classes:

```tsx
if (pickedFile && !busy) {
  return (
    <div className="flex w-[280px] flex-col items-center gap-2 rounded-lg border border-dashed p-4">
      <span className="max-w-full truncate text-sm">{pickedFile.name}</span>
      <button type="button" onClick={() => { onUpload(pickedFile); setPickedFile(null); }}>
        Gunakan sebagai base
      </button>
      <button type="button" onClick={() => { onSeparateLayers?.(pickedFile); setPickedFile(null); }}>
        Pisahkan jadi layer
      </button>
      <button type="button" className="text-xs underline" onClick={() => setPickedFile(null)}>
        ganti gambar
      </button>
    </div>
  );
}
```

Match the existing button classNames in the file for visual consistency (primary style for "Gunakan sebagai base", secondary for "Pisahkan jadi layer").

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test src/components/studio/kv-generator/KvUploadBaseBlock.test.tsx`
Expected: 4 PASS

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/KvUploadBaseBlock.tsx src/components/studio/kv-generator/KvUploadBaseBlock.test.tsx
git commit -m "feat(web): upload-base block two-action choice (base vs separate layers)"
```

---

### Task 4: `handleSeparateLayers` in KvGeneratorLayout + KvCanvas wiring

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx` (new callback next to `handleUploadBase` at line 2193; state next to `uploadingBase` at line 2192; pass props at the `KvCanvas` render)
- Modify: `web/src/components/studio/kv-generator/KvCanvas.tsx` (new optional props `onSeparateLayers?`, `uploadBusyLabel?` threaded to `KvUploadBaseBlock` at line 542)

**Interfaces:**
- Consumes: `startMagicLayerJob` / `pollMagicLayerJob` (Task 2), `promoteAttachmentToBase`, `uploadKvAttachment`, `measureImageSize`, `computeBoardLayout` / `canvasStateWithNewVariant` / `nextFreeCenter`, `docAddBoardFromState` + `docAddOverlay` (`@/lib/kv/yjsSerializer` — match `docAddOverlay`'s exact signature at `yjsSerializer.ts:409` when writing the call).
- No new exports; behavior only.

- [ ] **Step 1: Implement the callback** (no isolated unit test — all logic lives in already-tested helpers; this is glue verified by the existing suite + build + manual e2e)

In `KvGeneratorLayout.tsx`, add state and the callback next to `handleUploadBase`:

```ts
const [separatingLayers, setSeparatingLayers] = useState(false);

const handleSeparateLayers = useCallback(
  async (file: File) => {
    setUploadingBase(true);
    setSeparatingLayers(true);
    try {
      const { width, height } = await measureImageSize(file);
      const baseUrl = (process.env.NEXT_PUBLIC_API_URL ?? "").replace(/\/$/, "");
      const refreshed = await getValidAccessToken().catch(() => null);
      const token = refreshed ?? getSession().accessToken ?? null;
      const [descriptor] = await uploadKvAttachment([file], { baseUrl, token });
      if (!descriptor?.url) throw new Error("upload returned no url");

      const attachment = {
        id: descriptor.id, name: descriptor.name, mime_type: descriptor.mime_type,
        size: descriptor.size, url: descriptor.url, width, height,
      };
      const canvasMode = canvasModeRef.current === "craft" ? "craft" : "sketch";

      const job = await startMagicLayerJob({ fileId, attachment, canvasMode });
      const final = job ? await pollMagicLayerJob(fileId, job.id) : null;

      if (!final || final.status !== "done" || !final.generation) {
        // Fallback: import the original flat image as a plain base.
        const imported = await promoteAttachmentToBase({ fileId, attachment, canvasMode });
        if (!imported) throw new Error("fallback import failed");
        injectBoard(imported.id);
        await qc.invalidateQueries({ queryKey: ["studio", "kv-file", fileId] });
        setViewingGenerationId(imported.id);
        setTransientNotice(
          final?.error_message === "no_layers_detected"
            ? "Tidak ada layer yang bisa dipisah — gambar dipakai apa adanya."
            : "Pemisahan layer gagal — gambar dipakai apa adanya.",
        );
        return;
      }

      injectBoard(final.generation.id);
      if (kvDoc) {
        for (const overlay of final.overlays) {
          docAddOverlay(kvDoc, overlay);
        }
      }
      await qc.invalidateQueries({ queryKey: ["studio", "kv-file", fileId] });
      setViewingGenerationId(final.generation.id);
    } catch (err) {
      console.error("[kv] separate layers failed", err);
      setTransientNotice("Upload gagal. Coba lagi.");
    } finally {
      setUploadingBase(false);
      setSeparatingLayers(false);
    }
  },
  [fileId, qc, kvDoc, kvDocStateNow, stream.generations],
);
```

where `injectBoard` is the board-injection block extracted from `handleUploadBase` (lines 2222-2233) into a small local helper used by both callbacks (refactor, don't duplicate):

```ts
const injectBoard = useCallback(
  (generationId: string) => {
    if (!kvDoc) return;
    const current = kvDocStateNow();
    const boards = computeBoardLayout(stream.generations, current);
    const nextState = canvasStateWithNewVariant(
      boards, current, generationId, nextFreeCenter(boards), { name: null },
    );
    docAddBoardFromState(kvDoc, nextState, generationId);
  },
  [kvDoc, kvDocStateNow, stream.generations],
);
```

Refactor `handleUploadBase` to call `injectBoard(imported.id)` in place of its inline block. Import `startMagicLayerJob`, `pollMagicLayerJob` from `./magicLayers` and `docAddOverlay` from `@/lib/kv/yjsSerializer` (verify its exact signature at `yjsSerializer.ts:409` — if it takes `(doc, overlay, index?)` or similar, adapt the call; the overlay objects from the job resource are already fully-stamped `StudioOverlay` records).

In `KvCanvas.tsx`: add optional props `onSeparateLayers?: (file: File) => void;` and `uploadBusyLabel?: string;`, pass through at the `KvUploadBaseBlock` render (line 542):

```tsx
<KvUploadBaseBlock
  onUpload={onUploadBase}
  onSeparateLayers={onSeparateLayers}
  busy={uploadingBase}
  busyLabel={uploadBusyLabel}
/>
```

In `KvGeneratorLayout.tsx` at the `KvCanvas` render (~line 3451), pass:

```tsx
onSeparateLayers={handleSeparateLayers}
uploadBusyLabel={separatingLayers ? "Memisahkan layer…" : undefined}
```

Do NOT wire `onSeparateLayers` into the standalone-resizer `KvUploadBaseBlock` render at line 3412.

- [ ] **Step 2: Run the affected suites**

Run: `bun test src/components/studio/kv-generator src/services/kv`
Expected: all PASS (including `KvCanvas.test.tsx` — optional props are backward compatible)

- [ ] **Step 3: Type/build gate**

Run: `bun run build`
Expected: build succeeds

- [ ] **Step 4: Commit**

```bash
git add src/components/studio/kv-generator/KvGeneratorLayout.tsx src/components/studio/kv-generator/KvCanvas.tsx
git commit -m "feat(web): separate-into-layers flow on KV upload-base entry"
```

---

### Task 5: Manual e2e (requires api + ai-service branches running)

- [ ] Start all services (`./run-all.sh` from workspace root; check port conflicts first per CLAUDE.md).
- [ ] In the KV studio, open an empty craft canvas → drop a busy marketing image → choose **"Pisahkan jadi layer"**.
- [ ] Verify: busy label shows; after the job completes, a base board appears with the inpainted background; subject + text cutouts are separately selectable/movable; the Layers panel lists them; refresh the page and confirm overlays survive (REST recovery path).
- [ ] Drop a plain photo with no separable foreground → verify fallback notice and plain base import, and (api-side) that no CostHistory rows were charged for it.
