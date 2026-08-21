# KV Layer Decomposition — web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user start a decomposition from a KV board or a fresh upload, review the returned layers in a panel, tick the ones they want, and land them on the canvas as a new board with image overlays.

**Architecture:** Two entry points feed one job, polled the way every other KV async job is polled. Results render in a floating review panel modelled on `KvVersionHistoryPanel`. Commit is a single api call; the new board and its overlays are then seeded into the Yjs doc so collaborators see them without a reload. The panel is addressable by URL so a future askFRND tool can link straight into it.

**Tech Stack:** Next.js 16, React 19, TypeScript, Zustand, axios, Yjs, `bun test` + Testing Library.

**Spec:** `docs/superpowers/specs/2026-08-21-kv-layer-decomposition-design.md`

## Global Constraints

- **Tests run with `bun test`, never `bunx vitest`.** `bunfig.toml` preloads jest-dom.
- **RTL's `screen` is broken under bun.** Use `within(document.body)` instead — one use of bare `screen` fails the whole component suite.
- **There is no type gate.** `next build` sets `ignoreBuildErrors` and `tsc` has a ~777-error baseline, so a new type error will not fail anything. Diff `tsc` output against a baseline worktree if you need to check.
- Layer geometry from api is **already normalized 0..1**. Never scale it.
- **The review panel must be openable from a URL** (`?decomposition=<id>`), including while the job is still running. This exists for the future askFRND tool, which can only hand the user a link, and it is the one thing here that cannot be retrofitted without reworking how the panel mounts. Do not drop it as unused.
- PostHog events ship with the feature, not after it.
- Poll for at least **225 s** — decomposition takes ~110 s at the vendor plus mirroring, so the 180 s used elsewhere is too tight.

## File Structure

| File | Responsibility |
|---|---|
| `src/types/studio.ts` | `KvLayerDecomposition`, `KvDecomposedLayer`, status union |
| `src/services/kv/api.ts` | create / get / commit calls |
| `src/components/studio/kv-generator/layerDecomposition.ts` | start + poll helpers |
| `src/components/studio/kv-generator/KvLayerDecomposePanel.tsx` | the review panel |
| `src/lib/analytics/kv-generator-events.ts` | four events |
| `src/components/studio/kv-generator/KvBoardContextMenu.tsx` | tile menu entry |
| `src/components/studio/kv-generator/KvUploadBaseBlock.tsx` | post-upload entry |
| `src/components/studio/kv-generator/KvGeneratorLayout.tsx` | wiring, deep link, doc seeding |

---

### Task 1: Types and API client

**Files:**
- Modify: `web/src/types/studio.ts` (append near the other KV job types, after `StudioOverlayAssetUpload` ~line 719)
- Modify: `web/src/services/kv/api.ts` (append after the resize-export block, ~line 800)
- Test: `web/src/services/kv/layerDecomposition.api.test.ts`

**Interfaces:**
- Produces:
  - `type KvLayerDecompositionStatus = "pending" | "generating" | "done" | "failed"`
  - `type KvDecomposedLayer = { index: number; z: number; name: string; description: string; x: number; y: number; width: number; height: number; image_url: string }`
  - `type KvLayerDecomposition = { id; studio_file_id; source_generation_id: string | null; status; error_message: string | null; source_image_url: string; base_image_url: string | null; layers: KvDecomposedLayer[]; created_at: string }`
  - `createLayerDecomposition(fileId, body: { sourceGenerationId?: string; sourceImageUrl?: string }): Promise<KvLayerDecomposition>`
  - `getLayerDecomposition(fileId, id): Promise<KvLayerDecomposition>`
  - `commitLayerDecomposition(fileId, id, layerIndexes: number[]): Promise<{ generationId: string; overlays: StudioOverlay[] }>`

- [ ] **Step 1: Add the types**

Append to `src/types/studio.ts`:

```ts
export type KvLayerDecompositionStatus =
  | "pending"
  | "generating"
  | "done"
  | "failed";

/** One layer returned by Seedream. Geometry is ALREADY normalized 0..1
 *  against the base image — api divided the vendor's 0-1000 scale once, at
 *  the ai-service boundary. Do not scale it again. */
export type KvDecomposedLayer = {
  index: number;
  z: number;
  /** The model's own label, e.g. "frndGlow Sunscreen Tube". */
  name: string;
  description: string;
  x: number;
  y: number;
  width: number;
  height: number;
  image_url: string;
};

/** Async layer-decomposition job: one image in, a clean plate plus alpha
 *  layers out. The user reviews the layers before any of them reach the
 *  canvas, so this is NOT applied automatically on completion. */
export type KvLayerDecomposition = {
  id: string;
  studio_file_id: string;
  source_generation_id: string | null;
  status: KvLayerDecompositionStatus;
  error_message: string | null;
  source_image_url: string;
  /** The reconstructed background. Null until the job is done. */
  base_image_url: string | null;
  layers: KvDecomposedLayer[];
  created_at: string;
};
```

- [ ] **Step 2: Write the failing API test**

Create `src/services/kv/layerDecomposition.api.test.ts`:

```ts
import { describe, expect, it, mock, beforeEach } from "bun:test";

const post = mock(() => Promise.resolve({ data: { data: {} } }));
const get = mock(() => Promise.resolve({ data: { data: {} } }));

mock.module("@/lib/axios", () => ({
  default: { post, get },
  axiosInstance: { post, get },
}));

const {
  createLayerDecomposition,
  getLayerDecomposition,
  commitLayerDecomposition,
} = await import("./api");

beforeEach(() => {
  post.mockClear();
  get.mockClear();
});

describe("createLayerDecomposition", () => {
  it("sends a generation id in snake_case", async () => {
    post.mockResolvedValueOnce({ data: { data: { id: "d1", layers: [] } } });

    await createLayerDecomposition("f1", { sourceGenerationId: "g1" });

    expect(post).toHaveBeenCalledWith(
      "v1/studio/files/f1/layer-decompositions",
      { source_generation_id: "g1" },
    );
  });

  it("sends a raw image url when there is no generation", async () => {
    post.mockResolvedValueOnce({ data: { data: { id: "d1", layers: [] } } });

    await createLayerDecomposition("f1", { sourceImageUrl: "https://s3/up.png" });

    expect(post).toHaveBeenCalledWith(
      "v1/studio/files/f1/layer-decompositions",
      { source_image_url: "https://s3/up.png" },
    );
  });
});

describe("getLayerDecomposition", () => {
  it("defaults layers to an empty array while the job is pending", async () => {
    get.mockResolvedValueOnce({
      data: { data: { id: "d1", status: "pending", layers: null } },
    });

    const row = await getLayerDecomposition("f1", "d1");

    expect(row.layers).toEqual([]);
    expect(row.status).toBe("pending");
  });

  it("passes layer geometry through untouched", async () => {
    get.mockResolvedValueOnce({
      data: { data: { id: "d1", status: "done", layers: [
        { index: 7, z: 7, name: "Tube", description: "",
          x: 0.34, y: 0.441, width: 0.083, height: 0.286,
          image_url: "https://s3/l7.png" },
      ] } },
    });

    const row = await getLayerDecomposition("f1", "d1");

    // A second /1000 here would be the classic bug. Values must be identical.
    expect(row.layers[0].x).toBe(0.34);
    expect(row.layers[0].width).toBe(0.083);
  });
});

describe("commitLayerDecomposition", () => {
  it("posts the ticked indexes and returns the new board", async () => {
    post.mockResolvedValueOnce({
      data: { data: { generation: { id: "g9" }, overlays: [{ id: "o1" }] } },
    });

    const out = await commitLayerDecomposition("f1", "d1", [1, 7]);

    expect(post).toHaveBeenCalledWith(
      "v1/studio/files/f1/layer-decompositions/d1/commit",
      { layer_indexes: [1, 7] },
    );
    expect(out.generationId).toBe("g9");
    expect(out.overlays).toHaveLength(1);
  });

  it("allows an empty selection, meaning bake everything flat", async () => {
    post.mockResolvedValueOnce({
      data: { data: { generation: { id: "g9" }, overlays: [] } },
    });

    await commitLayerDecomposition("f1", "d1", []);

    expect(post).toHaveBeenCalledWith(
      "v1/studio/files/f1/layer-decompositions/d1/commit",
      { layer_indexes: [] },
    );
  });
});
```

- [ ] **Step 3: Run it to verify it fails**

Run: `cd web && bun test src/services/kv/layerDecomposition.api.test.ts`
Expected: FAIL — the three functions are not exported

- [ ] **Step 4: Write the client functions**

Append to `src/services/kv/api.ts` (matching the `unwrap` helper already used
by the resize functions above it):

```ts
// ── Layer decomposition ───────────────────────

/** Start a decomposition. Pass EITHER a generation id (decompose a board on
 *  the canvas) OR a raw image url (decompose something just uploaded). */
export async function createLayerDecomposition(
  fileId: string,
  body: { sourceGenerationId?: string; sourceImageUrl?: string },
): Promise<KvLayerDecomposition> {
  const payload = body.sourceGenerationId
    ? { source_generation_id: body.sourceGenerationId }
    : { source_image_url: body.sourceImageUrl };

  const { data } = await axiosInstance.post(
    `v1/studio/files/${fileId}/layer-decompositions`,
    payload,
  );
  return normalizeDecomposition(unwrap(data));
}

export async function getLayerDecomposition(
  fileId: string,
  id: string,
): Promise<KvLayerDecomposition> {
  const { data } = await axiosInstance.get(
    `v1/studio/files/${fileId}/layer-decompositions/${id}`,
  );
  return normalizeDecomposition(unwrap(data));
}

/** Commit the ticked layers. Everything NOT ticked is baked into the plate
 *  server-side, so an empty selection produces one flat board rather than an
 *  empty one. */
export async function commitLayerDecomposition(
  fileId: string,
  id: string,
  layerIndexes: number[],
): Promise<{ generationId: string; overlays: StudioOverlay[] }> {
  const { data } = await axiosInstance.post(
    `v1/studio/files/${fileId}/layer-decompositions/${id}/commit`,
    { layer_indexes: layerIndexes },
  );
  const payload = unwrap(data);
  return {
    generationId: payload.generation.id,
    overlays: payload.overlays ?? [],
  };
}

function normalizeDecomposition(row: any): KvLayerDecomposition {
  // `layers` is null until the job finishes; every consumer wants an array.
  // Geometry is passed through verbatim — it is already 0..1.
  return { ...row, layers: row.layers ?? [] };
}
```

Add `KvLayerDecomposition` to the existing `@/types/studio` import at the top
of the file.

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd web && bun test src/services/kv/layerDecomposition.api.test.ts`
Expected: 6 pass

- [ ] **Step 6: Commit**

```bash
git add src/types/studio.ts src/services/kv/api.ts src/services/kv/layerDecomposition.api.test.ts
git commit -m "feat(web): layer-decomposition types + API client"
```

---

### Task 2: Start and poll helpers

**Files:**
- Create: `web/src/components/studio/kv-generator/layerDecomposition.ts`
- Test: `web/src/components/studio/kv-generator/layerDecomposition.test.ts`

**Interfaces:**
- Consumes: `createLayerDecomposition`, `getLayerDecomposition` (Task 1).
- Produces:
  - `startLayerDecomposition(args: { fileId: string; sourceGenerationId?: string; sourceImageUrl?: string }): Promise<KvLayerDecomposition | null>` — returns null instead of throwing, so a failed start never breaks the canvas.
  - `pollLayerDecomposition(fileId, id, opts?: { intervalMs?; maxAttempts?; sleep? }): Promise<KvLayerDecomposition>`
  - `DEFAULT_INTERVAL_MS = 3000`, `DEFAULT_MAX_ATTEMPTS = 75`

- [ ] **Step 1: Write the failing test**

Create `src/components/studio/kv-generator/layerDecomposition.test.ts`:

```ts
import { describe, expect, it, mock, beforeEach } from "bun:test";

const createLayerDecomposition = mock(() => Promise.resolve({ id: "d1" }));
const getLayerDecomposition = mock(() => Promise.resolve({ id: "d1" }));

mock.module("@/services/kv/api", () => ({
  createLayerDecomposition,
  getLayerDecomposition,
}));

const {
  DEFAULT_INTERVAL_MS,
  DEFAULT_MAX_ATTEMPTS,
  pollLayerDecomposition,
  startLayerDecomposition,
} = await import("./layerDecomposition");

const noSleep = () => Promise.resolve();

beforeEach(() => {
  createLayerDecomposition.mockClear();
  getLayerDecomposition.mockClear();
});

describe("the polling window", () => {
  it("covers at least 225 seconds", () => {
    // Decomposition is ~110s at the vendor plus mirroring. The 180s window
    // other KV jobs use would abandon healthy runs.
    expect(DEFAULT_INTERVAL_MS * DEFAULT_MAX_ATTEMPTS).toBeGreaterThanOrEqual(225_000);
  });
});

describe("startLayerDecomposition", () => {
  it("passes a generation id straight through", async () => {
    await startLayerDecomposition({ fileId: "f1", sourceGenerationId: "g1" });

    expect(createLayerDecomposition).toHaveBeenCalledWith("f1", {
      sourceGenerationId: "g1",
      sourceImageUrl: undefined,
    });
  });

  it("returns null rather than throwing when the request fails", async () => {
    createLayerDecomposition.mockRejectedValueOnce(new Error("500"));

    const out = await startLayerDecomposition({ fileId: "f1", sourceGenerationId: "g1" });

    expect(out).toBeNull();
  });

  it("refuses to start with neither a generation nor an image", async () => {
    const out = await startLayerDecomposition({ fileId: "f1" });

    expect(out).toBeNull();
    expect(createLayerDecomposition).not.toHaveBeenCalled();
  });
});

describe("pollLayerDecomposition", () => {
  it("stops as soon as the job is done", async () => {
    getLayerDecomposition
      .mockResolvedValueOnce({ id: "d1", status: "generating", layers: [] })
      .mockResolvedValueOnce({ id: "d1", status: "done", layers: [{ index: 1 }] });

    const row = await pollLayerDecomposition("f1", "d1", { sleep: noSleep });

    expect(row.status).toBe("done");
    expect(getLayerDecomposition).toHaveBeenCalledTimes(2);
  });

  it("stops on failure without burning the remaining attempts", async () => {
    getLayerDecomposition.mockResolvedValueOnce({
      id: "d1", status: "failed", error_message: "no_layers_detected", layers: [],
    });

    const row = await pollLayerDecomposition("f1", "d1", { sleep: noSleep });

    expect(row.status).toBe("failed");
    expect(getLayerDecomposition).toHaveBeenCalledTimes(1);
  });

  it("gives up after maxAttempts and returns the last row it saw", async () => {
    getLayerDecomposition.mockResolvedValue({ id: "d1", status: "generating", layers: [] });

    const row = await pollLayerDecomposition("f1", "d1", {
      maxAttempts: 3, sleep: noSleep,
    });

    expect(row.status).toBe("generating");
    expect(getLayerDecomposition).toHaveBeenCalledTimes(3);
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/layerDecomposition.test.ts`
Expected: FAIL — module not found

- [ ] **Step 3: Write the implementation**

Create `src/components/studio/kv-generator/layerDecomposition.ts`:

```ts
import {
  createLayerDecomposition,
  getLayerDecomposition,
} from "@/services/kv/api";
import type { KvLayerDecomposition } from "@/types/studio";

export const DEFAULT_INTERVAL_MS = 3000;
/** 75 x 3s = 225s. Decomposition is ~110s at the vendor plus the time to
 *  mirror up to 17 images to our storage, so the 180s window other KV jobs
 *  use would abandon runs that are still healthy. */
export const DEFAULT_MAX_ATTEMPTS = 75;

const realSleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export async function startLayerDecomposition(args: {
  fileId: string;
  sourceGenerationId?: string;
  sourceImageUrl?: string;
}): Promise<KvLayerDecomposition | null> {
  const { fileId, sourceGenerationId, sourceImageUrl } = args;
  if (!sourceGenerationId && !sourceImageUrl) return null;

  try {
    return await createLayerDecomposition(fileId, {
      sourceGenerationId,
      sourceImageUrl,
    });
  } catch (err) {
    // Swallowed on purpose: a failed start must not take the canvas down.
    // The caller shows a toast; there is nothing to recover.
    console.error("[kv] layer decomposition start failed", err);
    return null;
  }
}

export async function pollLayerDecomposition(
  fileId: string,
  id: string,
  opts?: {
    intervalMs?: number;
    maxAttempts?: number;
    sleep?: (ms: number) => Promise<void>;
  },
): Promise<KvLayerDecomposition> {
  const intervalMs = opts?.intervalMs ?? DEFAULT_INTERVAL_MS;
  const maxAttempts = opts?.maxAttempts ?? DEFAULT_MAX_ATTEMPTS;
  const sleep = opts?.sleep ?? realSleep;

  let row = await getLayerDecomposition(fileId, id);
  for (let attempt = 1; attempt < maxAttempts; attempt += 1) {
    if (row.status === "done" || row.status === "failed") return row;
    await sleep(intervalMs);
    row = await getLayerDecomposition(fileId, id);
  }
  return row;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/layerDecomposition.test.ts`
Expected: 7 pass

- [ ] **Step 5: Write the failing input-guard test**

The vendor rejects anything outside its input limits, but it does so ~110 s
and one billed request later. The upload path is the only place we hold the
actual file, so it is the only place these can be caught cheaply. The tile
path needs no guard: a KV generation is our own output and is already inside
the limits by construction.

Append to `src/components/studio/kv-generator/layerDecomposition.test.ts`:

```ts
const { validateDecomposeSource } = await import("./layerDecomposition");

const fakeFile = (type: string, sizeBytes: number) =>
  ({ type, size: sizeBytes, name: "kv.png" }) as File;

describe("validateDecomposeSource", () => {
  it("accepts a normal png", () => {
    expect(validateDecomposeSource(fakeFile("image/png", 2_000_000), 1536, 1024))
      .toBeNull();
  });

  it("rejects a format the vendor does not take", () => {
    // ACCEPT elsewhere in KV allows webp and gif; decomposition does not.
    expect(validateDecomposeSource(fakeFile("image/webp", 1000), 1536, 1024))
      .toMatch(/PNG or JPEG/i);
  });

  it("rejects a file over 30 MB", () => {
    expect(validateDecomposeSource(fakeFile("image/png", 31 * 1024 * 1024), 1536, 1024))
      .toMatch(/30 ?MB/i);
  });

  it("rejects an image below the minimum pixel count", () => {
    // 512x512 = 262,144 is the floor; 400x400 = 160,000 is under it.
    expect(validateDecomposeSource(fakeFile("image/png", 1000), 400, 400))
      .toMatch(/too small/i);
  });

  it("accepts exactly the minimum pixel count", () => {
    expect(validateDecomposeSource(fakeFile("image/png", 1000), 512, 512)).toBeNull();
  });

  it("rejects an aspect ratio outside 1/16..16", () => {
    expect(validateDecomposeSource(fakeFile("image/png", 1000), 8000, 100))
      .toMatch(/too wide or too tall/i);
  });
});
```

- [ ] **Step 6: Run it to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/layerDecomposition.test.ts`
Expected: FAIL — `validateDecomposeSource` is not exported

- [ ] **Step 7: Add the guard**

Append to `src/components/studio/kv-generator/layerDecomposition.ts`:

```ts
/** BytePlus layer-decomposition input limits. Enforcing them here turns a
 *  ~110s billed round trip into an instant message. */
const MIN_PIXELS = 512 * 512;
const MAX_BYTES = 30 * 1024 * 1024;
const MIN_RATIO = 1 / 16;
const MAX_RATIO = 16;
const ALLOWED_TYPES = ["image/png", "image/jpeg"];

/** Returns an error message, or null when the file is acceptable. */
export function validateDecomposeSource(
  file: File,
  width: number,
  height: number,
): string | null {
  if (!ALLOWED_TYPES.includes(file.type)) {
    return "Layer separation needs a PNG or JPEG.";
  }
  if (file.size > MAX_BYTES) {
    return "That image is over 30MB — layer separation needs a smaller file.";
  }
  if (width * height < MIN_PIXELS) {
    return "That image is too small to separate — it needs to be at least 512x512.";
  }
  const ratio = width / height;
  if (ratio < MIN_RATIO || ratio > MAX_RATIO) {
    return "That image is too wide or too tall to separate.";
  }
  return null;
}
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `cd web && bun test src/components/studio/kv-generator/layerDecomposition.test.ts`
Expected: 13 pass

- [ ] **Step 9: Commit**

```bash
git add src/components/studio/kv-generator/layerDecomposition.ts src/components/studio/kv-generator/layerDecomposition.test.ts
git commit -m "feat(web): layer-decomposition start + poll helpers + input guard"
```

---

### Task 3: The review panel

Modelled on `KvVersionHistoryPanel` — read it first; it is the house style for
a floating canvas panel.

**Files:**
- Create: `web/src/components/studio/kv-generator/KvLayerDecomposePanel.tsx`
- Test: `web/src/components/studio/kv-generator/KvLayerDecomposePanel.test.tsx`

**Interfaces:**
- Produces: `KvLayerDecomposePanel` with props
  `{ open: boolean; decomposition: KvLayerDecomposition | null; committing?: boolean; onClose: () => void; onCommit: (layerIndexes: number[]) => void; onRetry: () => void }`

- [ ] **Step 1: Write the failing test**

Create `src/components/studio/kv-generator/KvLayerDecomposePanel.test.tsx`:

```tsx
import { describe, expect, it, mock } from "bun:test";
import { fireEvent, render, within } from "@testing-library/react";
import { KvLayerDecomposePanel } from "./KvLayerDecomposePanel";
import type { KvLayerDecomposition } from "@/types/studio";

// NOTE: `within(document.body)`, never RTL's `screen` — `screen` is broken
// under bun and one use fails the entire component suite.
const ui = () => within(document.body);

const layer = (index: number, name: string) => ({
  index, z: index, name, description: `${name} description`,
  x: 0.1, y: 0.2, width: 0.3, height: 0.4,
  image_url: `https://s3/l${index}.png`,
});

const done = (): KvLayerDecomposition => ({
  id: "d1", studio_file_id: "f1", source_generation_id: "g1",
  status: "done", error_message: null,
  source_image_url: "https://s3/src.png",
  base_image_url: "https://s3/base.png",
  layers: [layer(1, "Background"), layer(7, "Tube")],
  created_at: "2026-08-21T00:00:00Z",
});

const noop = () => {};

describe("while the job runs", () => {
  it("shows progress instead of an empty list", () => {
    render(
      <KvLayerDecomposePanel
        open
        decomposition={{ ...done(), status: "generating", layers: [], base_image_url: null }}
        onClose={noop} onCommit={noop} onRetry={noop}
      />,
    );

    expect(ui().getByText(/separating layers/i)).toBeTruthy();
    expect(ui().queryByRole("button", { name: /add to canvas/i })).toBeNull();
  });

  it("shows the error and a retry when it failed", () => {
    const onRetry = mock(noop);
    render(
      <KvLayerDecomposePanel
        open
        decomposition={{ ...done(), status: "failed", layers: [],
                         error_message: "no_layers_detected" }}
        onClose={noop} onCommit={noop} onRetry={onRetry}
      />,
    );

    expect(ui().getByText(/no_layers_detected/i)).toBeTruthy();
    fireEvent.click(ui().getByRole("button", { name: /try again/i }));
    expect(onRetry).toHaveBeenCalled();
  });
});

describe("reviewing the result", () => {
  it("lists every layer with the model's own name and description", () => {
    render(
      <KvLayerDecomposePanel open decomposition={done()}
        onClose={noop} onCommit={noop} onRetry={noop} />,
    );

    expect(ui().getByText("Tube")).toBeTruthy();
    expect(ui().getByText("Background")).toBeTruthy();
    expect(ui().getByText(/Tube description/)).toBeTruthy();
  });

  it("starts with every layer ticked", () => {
    render(
      <KvLayerDecomposePanel open decomposition={done()}
        onClose={noop} onCommit={noop} onRetry={noop} />,
    );

    const boxes = ui().getAllByRole("checkbox") as HTMLInputElement[];
    expect(boxes).toHaveLength(2);
    expect(boxes.every((b) => b.checked)).toBe(true);
  });

  it("commits only the ticked indexes", () => {
    const onCommit = mock(noop);
    render(
      <KvLayerDecomposePanel open decomposition={done()}
        onClose={noop} onCommit={onCommit} onRetry={noop} />,
    );

    // Untick "Background" (index 1), leaving only the tube.
    fireEvent.click(ui().getByLabelText("Background"));
    fireEvent.click(ui().getByRole("button", { name: /add to canvas/i }));

    expect(onCommit).toHaveBeenCalledWith([7]);
  });

  it("still allows a commit with nothing ticked", () => {
    const onCommit = mock(noop);
    render(
      <KvLayerDecomposePanel open decomposition={done()}
        onClose={noop} onCommit={onCommit} onRetry={noop} />,
    );

    fireEvent.click(ui().getByLabelText("Background"));
    fireEvent.click(ui().getByLabelText("Tube"));
    fireEvent.click(ui().getByRole("button", { name: /add to canvas/i }));

    // Legal: everything is baked into the plate, producing one flat board.
    expect(onCommit).toHaveBeenCalledWith([]);
  });

  it("warns that unticked layers are baked in rather than dropped", () => {
    render(
      <KvLayerDecomposePanel open decomposition={done()}
        onClose={noop} onCommit={noop} onRetry={noop} />,
    );

    expect(ui().getByText(/merged into the background/i)).toBeTruthy();
  });

  it("disables the commit button while committing", () => {
    render(
      <KvLayerDecomposePanel open decomposition={done()} committing
        onClose={noop} onCommit={noop} onRetry={noop} />,
    );

    const btn = ui().getByRole("button", { name: /adding/i }) as HTMLButtonElement;
    expect(btn.disabled).toBe(true);
  });
});

describe("visibility", () => {
  it("renders nothing when closed", () => {
    const { container } = render(
      <KvLayerDecomposePanel open={false} decomposition={done()}
        onClose={noop} onCommit={noop} onRetry={noop} />,
    );

    expect(container.firstChild).toBeNull();
  });

  it("renders nothing when there is no decomposition", () => {
    const { container } = render(
      <KvLayerDecomposePanel open decomposition={null}
        onClose={noop} onCommit={noop} onRetry={noop} />,
    );

    expect(container.firstChild).toBeNull();
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/KvLayerDecomposePanel.test.tsx`
Expected: FAIL — module not found

- [ ] **Step 3: Write the panel**

Create `src/components/studio/kv-generator/KvLayerDecomposePanel.tsx`:

```tsx
"use client";

import { useEffect, useState } from "react";
import { X } from "@phosphor-icons/react";
import { Button } from "@/components/frndos/Button";
import type { KvLayerDecomposition } from "@/types/studio";

type Props = {
  open: boolean;
  decomposition: KvLayerDecomposition | null;
  committing?: boolean;
  onClose: () => void;
  onCommit: (layerIndexes: number[]) => void;
  onRetry: () => void;
};

/**
 * Layer-decomposition review panel.
 *
 * Floats over the canvas. Nothing reaches the canvas until the user picks —
 * the model REGENERATES pixels rather than cutting them out, so the result
 * has to be looked at before it is accepted.
 *
 * Layers left unticked are composited back into the clean plate server-side,
 * not discarded. The panel says so, because "unchecked" otherwise reads as
 * "delete this element".
 */
export function KvLayerDecomposePanel({
  open,
  decomposition,
  committing = false,
  onClose,
  onCommit,
  onRetry,
}: Props) {
  const [selected, setSelected] = useState<Set<number>>(new Set());

  const layers = decomposition?.layers ?? [];
  const status = decomposition?.status;
  const layerKey = layers.map((l) => l.index).join(",");

  // Default to everything ticked, re-seeded whenever a different result
  // arrives (a retry produces a new set of layers).
  useEffect(() => {
    setSelected(new Set(layers.map((l) => l.index)));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [decomposition?.id, layerKey]);

  if (!open || !decomposition) return null;

  const toggle = (index: number) =>
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(index)) next.delete(index);
      else next.add(index);
      return next;
    });

  const running = status === "pending" || status === "generating";

  return (
    <div className="absolute right-4 top-20 z-30 flex w-80 flex-col gap-3 rounded-xl border border-gray-200 bg-white p-4 shadow-lg">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold">Separated layers</h3>
        <button aria-label="Close" onClick={onClose}>
          <X size={16} />
        </button>
      </div>

      {running && (
        <p className="text-sm text-gray-500">
          Separating layers… this usually takes about two minutes.
        </p>
      )}

      {status === "failed" && (
        <>
          <p className="text-sm text-red-600">
            {decomposition.error_message ?? "Separation failed."}
          </p>
          <Button onClick={onRetry}>Try again</Button>
        </>
      )}

      {status === "done" && (
        <>
          <ul className="flex max-h-80 flex-col gap-2 overflow-y-auto">
            {layers.map((layer) => (
              <li key={layer.index} className="flex items-start gap-2">
                <input
                  type="checkbox"
                  id={`layer-${layer.index}`}
                  aria-label={layer.name}
                  checked={selected.has(layer.index)}
                  onChange={() => toggle(layer.index)}
                />
                <img
                  src={layer.image_url}
                  alt=""
                  className="h-10 w-10 shrink-0 rounded border border-gray-200 object-contain"
                />
                <label htmlFor={`layer-${layer.index}`} className="flex flex-col">
                  <span className="text-sm font-medium">{layer.name}</span>
                  <span className="text-xs text-gray-500">{layer.description}</span>
                </label>
              </li>
            ))}
          </ul>

          <p className="text-xs text-gray-500">
            Unchecked layers are merged into the background of the new board —
            nothing is lost.
          </p>

          <Button
            disabled={committing}
            onClick={() => onCommit([...selected].sort((a, b) => a - b))}
          >
            {committing ? "Adding…" : "Add to canvas"}
          </Button>
        </>
      )}
    </div>
  );
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/KvLayerDecomposePanel.test.tsx`
Expected: 10 pass

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/KvLayerDecomposePanel.tsx src/components/studio/kv-generator/KvLayerDecomposePanel.test.tsx
git commit -m "feat(web): layer-decomposition review panel"
```

---

### Task 4: Analytics events

**Files:**
- Modify: `web/src/lib/analytics/kv-generator-events.ts` (append, following the `safeCapture` style already there)
- Test: `web/src/lib/analytics/layerDecomposition.events.test.ts`

**Interfaces:**
- Produces:
  - `trackKvLayerDecomposeStarted({ entry_point: "tile_menu" | "upload" | "deep_link" })`
  - `trackKvLayerDecomposeSucceeded({ layer_count: number; duration_ms: number })`
  - `trackKvLayerDecomposeFailed({ error_reason: string; duration_ms: number })`
  - `trackKvLayerDecomposeCommitted({ layer_count: number; selected_count: number })`

- [ ] **Step 1: Write the failing test**

Create `src/lib/analytics/layerDecomposition.events.test.ts`:

```ts
import { describe, expect, it, mock } from "bun:test";

const capture = mock(() => {});
mock.module("posthog-js", () => ({ default: { capture } }));

const events = await import("./kv-generator-events");

describe("layer-decomposition events", () => {
  it("exposes the four events the feature needs", () => {
    expect(typeof events.trackKvLayerDecomposeStarted).toBe("function");
    expect(typeof events.trackKvLayerDecomposeSucceeded).toBe("function");
    expect(typeof events.trackKvLayerDecomposeFailed).toBe("function");
    expect(typeof events.trackKvLayerDecomposeCommitted).toBe("function");
  });

  it("records which entry point started a run", () => {
    // The whole point of tracking entry_point is deciding whether the upload
    // path or the tile path deserves more investment.
    expect(() =>
      events.trackKvLayerDecomposeStarted({ entry_point: "upload" }),
    ).not.toThrow();
  });

  it("records how many layers were kept versus returned", () => {
    expect(() =>
      events.trackKvLayerDecomposeCommitted({ layer_count: 7, selected_count: 2 }),
    ).not.toThrow();
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd web && bun test src/lib/analytics/layerDecomposition.events.test.ts`
Expected: FAIL — the functions are undefined

- [ ] **Step 3: Add the events**

Append to `src/lib/analytics/kv-generator-events.ts`:

```ts
// D. Layer decomposition

/** Which surface started the run. `deep_link` covers a URL that opened the
 *  panel directly — the shape a future askFRND tool will use. */
export type KvLayerDecomposeEntryPoint = "tile_menu" | "upload" | "deep_link";

export interface KvLayerDecomposeStartedProps {
  entry_point: KvLayerDecomposeEntryPoint;
}

export const trackKvLayerDecomposeStarted = (p: KvLayerDecomposeStartedProps) =>
  safeCapture("kv_generator.layer_decompose_started", p);

export interface KvLayerDecomposeSucceededProps {
  layer_count: number;
  duration_ms: number;
}

export const trackKvLayerDecomposeSucceeded = (p: KvLayerDecomposeSucceededProps) =>
  safeCapture("kv_generator.layer_decompose_succeeded", p);

export interface KvLayerDecomposeFailedProps {
  error_reason: string;
  duration_ms: number;
}

export const trackKvLayerDecomposeFailed = (p: KvLayerDecomposeFailedProps) =>
  safeCapture("kv_generator.layer_decompose_failed", p);

export interface KvLayerDecomposeCommittedProps {
  /** How many layers came back. */
  layer_count: number;
  /** How many the user actually kept as overlays. The gap between these two
   *  is the signal for whether auto mode splits at a useful granularity. */
  selected_count: number;
}

export const trackKvLayerDecomposeCommitted = (p: KvLayerDecomposeCommittedProps) =>
  safeCapture("kv_generator.layer_decompose_committed", p);
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd web && bun test src/lib/analytics/layerDecomposition.events.test.ts`
Expected: 3 pass

- [ ] **Step 5: Commit**

```bash
git add src/lib/analytics/kv-generator-events.ts src/lib/analytics/layerDecomposition.events.test.ts
git commit -m "feat(web): PostHog events for layer decomposition"
```

---

### Task 5: Wiring — entry points, deep link, and doc seeding

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvBoardContextMenu.tsx` (new optional prop + menu item, in the `!isConcept` group at ~line 275)
- Modify: `web/src/components/studio/kv-generator/KvUploadBaseBlock.tsx` (new optional prop)
- Modify: `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx` (state, handlers, deep link, panel render)
- Test: `web/src/components/studio/kv-generator/KvBoardContextMenu.decompose.test.tsx`
- Test: `web/src/components/studio/kv-generator/layerDecompositionDeepLink.test.ts`

**Interfaces:**
- Consumes: everything from Tasks 1–4, plus `docAddBoardFromState` and `docAddOverlay` from `@/lib/kv/yjsSerializer` (both already imported by `KvGeneratorLayout`).
- Produces:
  - `KvBoardContextMenu` prop `onDecomposeLayers?: (generationId: string) => void`
  - `KvUploadBaseBlock` prop `onDecomposeUpload?: (file: File) => void`
  - `readDecompositionIdFromUrl(search: string): string | null` exported from `layerDecomposition.ts`

- [ ] **Step 1: Write the failing menu test**

Create `src/components/studio/kv-generator/KvBoardContextMenu.decompose.test.tsx`:

```tsx
import { describe, expect, it, mock } from "bun:test";
import { fireEvent, render, within } from "@testing-library/react";
import { KvBoardContextMenu } from "./KvBoardContextMenu";

const ui = () => within(document.body);

// Read KvBoardContextMenu.test.tsx first and reuse its prop fixture verbatim;
// this file only adds the decompose case on top of that baseline.
const baseProps = {
  /* ...copy from KvBoardContextMenu.test.tsx... */
} as any;

describe("separate layers menu item", () => {
  it("is offered on a craft board", () => {
    render(
      <KvBoardContextMenu {...baseProps} isConcept={false}
        onDecomposeLayers={() => {}} />,
    );

    expect(ui().getByText(/separate layers/i)).toBeTruthy();
  });

  it("is hidden on a concept board", () => {
    // Same rule as Send to Motion / Send to Resize: these adapt a FINISHED
    // design, not a concept idea.
    render(
      <KvBoardContextMenu {...baseProps} isConcept onDecomposeLayers={() => {}} />,
    );

    expect(ui().queryByText(/separate layers/i)).toBeNull();
  });

  it("is hidden when the handler is absent, which is how the flag is applied", () => {
    render(<KvBoardContextMenu {...baseProps} isConcept={false} />);

    expect(ui().queryByText(/separate layers/i)).toBeNull();
  });

  it("passes the board's generation id", () => {
    const onDecomposeLayers = mock(() => {});
    render(
      <KvBoardContextMenu {...baseProps} isConcept={false}
        onDecomposeLayers={onDecomposeLayers} />,
    );

    fireEvent.click(ui().getByText(/separate layers/i));

    expect(onDecomposeLayers).toHaveBeenCalledWith(baseProps.gen.id);
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/KvBoardContextMenu.decompose.test.tsx`
Expected: FAIL — no such menu item

- [ ] **Step 3: Add the menu item**

In `KvBoardContextMenu.tsx`, add to `type Props`:

```ts
  /** Absent when the feature flag is off — that absence IS the gate. */
  onDecomposeLayers?: (generationId: string) => void;
```

and extend the existing `onSendToMode && !isConcept` group (~line 275) so the
new item sits with the other finished-design actions:

```ts
    !isConcept
      ? [
          ...(onSendToMode
            ? [
                {
                  key: "send-motion",
                  label: "Send to Motion",
                  onClick: run(() => onSendToMode(gen.id, "motion")),
                },
                {
                  key: "send-resize",
                  label: "Send to Resize",
                  onClick: run(() => onSendToMode(gen.id, "resize")),
                },
              ]
            : []),
          ...(onDecomposeLayers
            ? [
                {
                  key: "decompose-layers",
                  label: "Separate layers",
                  onClick: run(() => onDecomposeLayers(gen.id)),
                },
              ]
            : []),
        ]
      : [],
```

- [ ] **Step 4: Run the menu test to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/KvBoardContextMenu.decompose.test.tsx`
Expected: 4 pass

- [ ] **Step 5: Write the failing deep-link test**

Create `src/components/studio/kv-generator/layerDecompositionDeepLink.test.ts`:

```ts
import { describe, expect, it } from "bun:test";
import { readDecompositionIdFromUrl } from "./layerDecomposition";

describe("readDecompositionIdFromUrl", () => {
  it("reads the id a chat tool would link to", () => {
    // A future askFRND tool cannot render the panel; it can only hand over a
    // link. This parameter is that link's payload.
    expect(readDecompositionIdFromUrl("?decomposition=01JABC")).toBe("01JABC");
  });

  it("reads it alongside other parameters", () => {
    expect(readDecompositionIdFromUrl("?tab=craft&decomposition=01JABC")).toBe("01JABC");
  });

  it("returns null when it is absent", () => {
    expect(readDecompositionIdFromUrl("?tab=craft")).toBeNull();
    expect(readDecompositionIdFromUrl("")).toBeNull();
  });

  it("returns null for an empty value rather than an empty id", () => {
    expect(readDecompositionIdFromUrl("?decomposition=")).toBeNull();
  });
});
```

- [ ] **Step 6: Run it to verify it fails**

Run: `cd web && bun test src/components/studio/kv-generator/layerDecompositionDeepLink.test.ts`
Expected: FAIL — not exported

- [ ] **Step 7: Add the deep-link reader**

Append to `src/components/studio/kv-generator/layerDecomposition.ts`:

```ts
/** Query parameter that opens the review panel straight onto one
 *  decomposition. Required by the spec so a future askFRND tool can link into
 *  KV Studio instead of trying to render the panel in chat. */
export const DECOMPOSITION_QUERY_PARAM = "decomposition";

export function readDecompositionIdFromUrl(search: string): string | null {
  const value = new URLSearchParams(search).get(DECOMPOSITION_QUERY_PARAM);
  return value && value.length > 0 ? value : null;
}
```

- [ ] **Step 8: Run the deep-link test to verify it passes**

Run: `cd web && bun test src/components/studio/kv-generator/layerDecompositionDeepLink.test.ts`
Expected: 4 pass

- [ ] **Step 9: Add the upload entry point**

In `KvUploadBaseBlock.tsx`, add to `type Props`:

```ts
  /** Offered after an upload lands. Absent when the flag is off. */
  onDecomposeUpload?: (file: File) => void;
```

The component's job is "pick a file, hand it to a handler", so the decompose
entry is a second picker rather than a post-upload prompt. Add a second hidden
input and a button beside the existing one, rendered only when the handler is
present:

```tsx
  const decomposeInputRef = useRef<HTMLInputElement>(null);

  const pickForDecompose = (files: FileList | null) => {
    const file = files?.[0];
    if (!file) return;
    // PSD has its own importer that already produces real layers — routing one
    // through the image decomposer would upload a file the model rejects.
    if (isPsdFile(file)) {
      onUploadPsd?.(file);
      return;
    }
    onDecomposeUpload?.(file);
  };
```

and, inside the returned markup directly after the existing upload button:

```tsx
      {onDecomposeUpload && (
        <>
          <input
            ref={decomposeInputRef}
            type="file"
            accept={DECOMPOSE_ACCEPT}
            className="hidden"
            onChange={(e) => pickForDecompose(e.target.files)}
          />
          <button
            type="button"
            disabled={busy}
            onClick={() => decomposeInputRef.current?.click()}
            className="text-xs text-text-inverse-subtle underline"
          >
            Upload and separate layers
          </button>
        </>
      )}
```

with this constant beside the existing `ACCEPT` at the top of the file:

```tsx
// Narrower than ACCEPT: Seedream layer decomposition takes png and jpeg only,
// so offering webp or gif here would upload a file the vendor rejects two
// minutes later.
const DECOMPOSE_ACCEPT = "image/png,image/jpeg";
```

- [ ] **Step 10: Wire it all up in KvGeneratorLayout**

In `KvGeneratorLayout.tsx`:

1. Import the panel, the helpers, and the four events.
2. Add state: `decomposition`, `decomposePanelOpen`, `committing`, and a
   `decomposeStartedAt` ref for the event durations.
3. On the upload path only, measure the picked file with an `<img>` (the same
   way the existing base-image upload probes dimensions) and run
   `validateDecomposeSource(file, width, height)` before uploading anything.
   On a non-null message, toast it and stop — do not create a job.
4. Add `handleDecompose(generationId?: string, imageUrl?: string, entryPoint)`:
   - `trackKvLayerDecomposeStarted({ entry_point: entryPoint })`
   - `startLayerDecomposition(...)`; on `null`, show a toast and stop
   - open the panel immediately with the pending row so the user sees progress
   - `pollLayerDecomposition(...)`, then fire the succeeded or failed event
5. Add `handleCommit(layerIndexes)`:
   - `commitLayerDecomposition(fileId, decomposition.id, layerIndexes)`
   - `trackKvLayerDecomposeCommitted({ layer_count: decomposition.layers.length, selected_count: layerIndexes.length })`
   - refetch the file's generations, then seed the doc:

```ts
        // The new board and its overlays exist server-side, but collaborators
        // only see what is in the Yjs doc. Seed both, the same way a finished
        // generation does at line ~1177.
        if (kvDoc) {
          docAddBoardFromState(kvDoc, nextState, generationId);
          for (const overlay of overlays) {
            docAddOverlay(kvDoc, overlay);
          }
        }
```

6. Gate both entry points on the flag by passing the handlers only when it is
   on — an absent handler is the gate (see the menu test).
7. On mount, read `readDecompositionIdFromUrl(window.location.search)`; when it
   returns an id, open the panel and poll that decomposition, firing
   `trackKvLayerDecomposeStarted({ entry_point: "deep_link" })`.
8. Render `<KvLayerDecomposePanel …>` beside the other floating panels.

- [ ] **Step 11: Run every test this plan added**

Run:
```bash
cd web && bun test src/services/kv/layerDecomposition.api.test.ts src/components/studio/kv-generator/layerDecomposition.test.ts src/components/studio/kv-generator/layerDecompositionDeepLink.test.ts src/components/studio/kv-generator/KvLayerDecomposePanel.test.tsx src/components/studio/kv-generator/KvBoardContextMenu.decompose.test.tsx src/lib/analytics/layerDecomposition.events.test.ts
```
Expected: all pass

- [ ] **Step 12: Confirm the existing suites still pass**

Run: `cd web && bun test src/components/studio/kv-generator/KvBoardContextMenu.test.tsx src/components/studio/kv-generator/KvUploadBaseBlock.test.tsx`
Expected: unchanged from before your edits

- [ ] **Step 13: Commit**

```bash
git add src/components/studio/kv-generator/ src/lib/analytics/kv-generator-events.ts
git commit -m "feat(web): wire layer decomposition into the canvas"
```

---

## Manual verification

Unit tests never exercise the real pipeline. Before calling this done, with
`KV_LAYER_DECOMPOSE_ENABLED=true` and a working BytePlus key:

1. Open a KV file with a finished craft board. Right-click the board →
   **Separate layers**. The panel should open immediately showing progress, not
   after a two-minute freeze.
2. Wait for completion. Every layer should show a thumbnail, the model's name,
   and its description.
3. Untick one layer, click **Add to canvas**. A new board appears beside the
   original. The original is untouched. The unticked element is still visible
   in the new board — baked into the background, not missing.
4. Drag a ticked layer on the new board. It should move cleanly with no hole
   left behind, and no duplicate of itself in the plate underneath.
5. Reload the page. The new board and its overlays survive.
6. Copy the URL, append `?decomposition=<the id>`, open it in a second tab. The
   panel should open on that decomposition. This is the path the future askFRND
   tool depends on — if it does not work, the tool cannot be added later
   without reworking the panel.
