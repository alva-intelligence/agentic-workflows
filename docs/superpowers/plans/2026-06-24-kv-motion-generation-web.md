# KV Motion Generation — web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a **Motion** canvas mode to the KV studio that lets a user animate the active KV generation into a short video — pick a model + preset (+ optional prompt + duration/ratio), generate, poll status, and play/download/delete the result.

**Architecture:** Mirror the KV **Resize** UI. Add `canvasMode: "motion"` (4th top-nav tab, gated by a PostHog flag), a floating `KvMotionPanel` (bottom-left, like the Resize platform panel), a `KvMotionViewport` showing the first-frame preview + result player, and a `useKvMotion` TanStack Query hook that POSTs a generation and polls status until done/failed. One request → one motion row (not a per-platform batch).

**Tech Stack:** Next.js 16, React 19, TypeScript, Tailwind, Zustand, TanStack Query v5, Bun. Use **frndos components** first (Button, Input, RadioButton, etc.).

**Spec:** `docs/superpowers/specs/2026-06-23-kv-motion-generation-design.md`

> ## ⚠️ Revision 2026-06-27 — registry-driven models + capabilities + audio
>
> The picker is **no longer a hardcoded 3-model constant**. It is driven by the
> askFRND video-model registry (`getVideoModels()` → `GET /v1/threads/video-models`,
> the same source the chat picker uses), filtered to I2V-capable models, with
> per-model adaptive duration/ratio and an audio on/off toggle. web deltas:
>
> 1. **Task 1 (types)** — DROP the hardcoded `MOTION_MODELS`/`MOTION_DURATIONS`/
>    `MOTION_RATIOS`. Add a `VideoCapabilities` type (mirrors the api
>    `video_capabilities` block) and a `MotionModel = VideoModel & { video_capabilities }`
>    type, plus pure helpers: `isImageToVideo(m)`, `clampDuration(caps, d)`,
>    `resolveRatio(caps, kvRatio)`, `audioMode(caps)`. Keep `DEFAULT_MOTION_MODEL_ID
>    = "veo-3.1-fast-generate-preview"`. Add `generateAudio: boolean` to `KvMotion`;
>    widen `provider`/`ratio` to `string` (registry-driven, e.g. `bytedance`,
>    `adaptive`). Presets stay a hardcoded constant (model-agnostic).
> 2. **NEW Task** — fetch + filter models: reuse `getVideoModels()` (TanStack
>    Query, same cache key the chat picker uses), filter
>    `is_active && video_capabilities.image_to_video`. Default to Veo 3.1 Fast if
>    present, else first entry.
> 3. **Task 3 (api client)** — `createMotion` body adds `generate_audio`.
> 4. **Task 5 (panel)** — model picker uses `ProviderLogo`; duration/ratio options
>    come from the selected model's capabilities (adaptive); add an audio toggle
>    shown only when `audioMode(caps) === "optional"` (locked-on for `always`,
>    hidden for `none`). On model switch, clamp duration to nearest + resolve ratio
>    to KV ratio (if supported) else model default, with a one-line hint.
> 5. **Task 7 (wiring)** — derive `provider` from the selected registry model (not a
>    `MOTION_MODELS.find`); hold `generateAudio` in panel state; pass the filtered
>    model list + KV ratio into the panel.
>
> The `value` strings come from the registry at runtime, so the earlier "confirm
> Sora/Kling ids against generate_video.py" caveat is moot — ids are whatever the
> registry serves.

> **REQUIRED SKILLS while implementing (web-scoped):** `frndos-components`
> (use frndos UI components), `frndos-feature-flags` (flag naming + gating),
> `frndos-analytics-events` (typed snake_case events), `tanstack-query-best-practices`.

> **TEST RUNNER:** web tests run with **`bun test <file>`** (bunfig preloads
> jest-dom). Do NOT use `bunx vitest`. The real CI gate is **`bun run build`**.

**API surface consumed** (from the api plan):
- `GET  v1/studio/files/{file}/motions` → list rows
- `POST v1/studio/files/{file}/motions` → create (202) `{parent_generation_id, model, provider, preset, prompt, duration, ratio}`
- `GET  v1/studio/files/{file}/motions/{motion}` → single row
- `DELETE v1/studio/files/{file}/motions/{motion}`

Row shape: `{id, studio_file_id, parent_generation_id, model, provider, preset, prompt, duration, ratio, status, video_url, error_message, created_at, updated_at}` with `status ∈ pending|generating|done|failed`.

**Working directory for all paths below:** `web/`

---

## File Structure

- Create: `src/types/kv/motion.ts` — `KvMotion`, `KvMotionStatus`, model/preset constants
- Modify: `src/types/studio.ts` — add `"motion"` to `KvGenerationMode`
- Modify: `src/lib/featureFlags/constants.ts` — add `KV_MOTION` flag
- Modify: `src/lib/analytics/kv-generator-events.ts` — add motion events
- Modify: `src/services/kv/api.ts` — add `listMotions`, `createMotion`, `deleteMotion`
- Create: `src/lib/studio/kv/useKvMotion.ts` — TanStack Query hook (list + create + delete + poll)
- Create: `src/components/studio/kv-generator/KvMotionPanel.tsx`
- Create: `src/components/studio/kv-generator/KvMotionViewport.tsx`
- Modify: `src/components/studio/kv-generator/KvCanvasTopNav.tsx` — add Motion tab (flag-gated)
- Modify: `src/components/studio/kv-generator/KvGeneratorLayout.tsx` — `canvasMode` union + motion branch + panel mount
- Create tests: `KvMotionPanel.test.tsx`, `useKvMotion.test.ts(x)`

---

## Task 1: Types + mode union

**Files:**
- Create: `src/types/kv/motion.ts`
- Modify: `src/types/studio.ts` (line ~331 `KvGenerationMode`)

- [ ] **Step 1: Write the failing test**

```typescript
// src/types/kv/motion.test.ts
import { describe, expect, it } from "vitest";
import {
  MOTION_PRESETS,
  clampDuration,
  resolveRatio,
  isImageToVideo,
  type VideoCapabilities,
  type MotionModel,
} from "./motion";

const veoCaps: VideoCapabilities = {
  image_to_video: true,
  last_frame: true,
  durations: [4, 8],
  default_duration: 8,
  ratios: ["16:9", "9:16", "1:1"],
  default_ratio: "16:9",
  resolutions: ["1080p", "720p"],
  default_resolution: "1080p",
  reference_video: false,
  reference_audio: false,
  audio: "always",
};

describe("kv motion helpers", () => {
  it("exposes the five presets", () => {
    expect(MOTION_PRESETS.map((p) => p.id)).toEqual([
      "subtle_zoom",
      "parallax",
      "product_spin",
      "camera_pan",
      "cinematic_push_in",
    ]);
  });

  it("clamps an unsupported duration to the nearest option", () => {
    expect(clampDuration(veoCaps, 12)).toBe(8); // Veo max is 8
    expect(clampDuration(veoCaps, 4)).toBe(4);
  });

  it("keeps the KV ratio when supported, else falls back to model default", () => {
    expect(resolveRatio(veoCaps, "9:16")).toBe("9:16");
    expect(resolveRatio({ ...veoCaps, ratios: ["16:9", "9:16"] }, "1:1")).toBe("16:9");
  });

  it("filters out non-I2V / inactive models", () => {
    const hunyuan = {
      value: "hunyuan-video",
      is_active: true,
      video_capabilities: { ...veoCaps, image_to_video: false },
    } as MotionModel;
    expect(isImageToVideo(hunyuan)).toBe(false);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/types/kv/motion.test.ts`
Expected: FAIL — module not found

- [ ] **Step 3: Implement the types + constants**

```typescript
// src/types/kv/motion.ts
export type KvMotionStatus = "pending" | "generating" | "done" | "failed";

// Registry-driven — providers/ratios come from the askFRND video-model registry
// at runtime (e.g. "bytedance", "adaptive"), so these are plain strings.
export type KvMotionProvider = string;

export type KvMotion = {
  id: string;
  studioFileId: string;
  parentGenerationId: string;
  parentMotionId: string | null;
  model: string;
  provider: KvMotionProvider;
  preset: string | null;
  prompt: string | null;
  duration: number;
  ratio: string; // model-dependent: 16:9 | 9:16 | 1:1 | adaptive | …
  generateAudio: boolean;
  status: KvMotionStatus;
  videoUrl: string | null;
  errorMessage: string | null;
  createdAt: string;
  updatedAt: string;
};

// Mirrors the api `video_capabilities` block on each video model.
export type AudioMode = "always" | "optional" | "none";
export type VideoCapabilities = {
  image_to_video: boolean;
  last_frame: boolean;
  durations: number[];
  default_duration: number;
  ratios: string[];
  default_ratio: string | null;
  resolutions: string[];
  default_resolution: string;
  reference_video: boolean;
  reference_audio: boolean;
  audio: AudioMode;
};

// A registry VideoModel that carries capabilities (KV Motion picker entry).
export type MotionModel = {
  value: string;
  name: string;
  model_provider: string;
  is_active: boolean;
  video_capabilities: VideoCapabilities;
};

export const isImageToVideo = (m: MotionModel): boolean =>
  Boolean(m.is_active && m.video_capabilities?.image_to_video);

export const clampDuration = (caps: VideoCapabilities, d: number): number =>
  caps.durations.includes(d)
    ? d
    : caps.durations.reduce(
        (best, opt) => (Math.abs(opt - d) < Math.abs(best - d) ? opt : best),
        caps.durations[0] ?? caps.default_duration,
      );

// Prefer the KV's own ratio when the model supports it; else the model default.
export const resolveRatio = (caps: VideoCapabilities, kvRatio: string): string =>
  caps.ratios.includes(kvRatio)
    ? kvRatio
    : caps.default_ratio ?? caps.ratios[0] ?? kvRatio;

export const audioMode = (caps: VideoCapabilities): AudioMode => caps.audio;

// Presets stay hardcoded — they are model-agnostic prompt fragments.
export const MOTION_PRESETS: Array<{ id: string; label: string }> = [
  { id: "subtle_zoom", label: "Subtle Zoom" },
  { id: "parallax", label: "Parallax" },
  { id: "product_spin", label: "Product Spin" },
  { id: "camera_pan", label: "Camera Pan" },
  { id: "cinematic_push_in", label: "Cinematic Push-in" },
];

// Pinned default; the picker falls back to the first I2V model if absent.
export const DEFAULT_MOTION_MODEL_ID = "veo-3.1-fast-generate-preview";
```

> The model **list** is NOT hardcoded — it comes from the registry at runtime (see
> the new fetch task). Only presets + the default-id hint live as constants here.

- [ ] **Step 4: Add `"motion"` to the mode union** in `src/types/studio.ts` (~line 331)

```typescript
export type KvGenerationMode = "sketch" | "craft" | "resize" | "motion";
```

- [ ] **Step 5: Run to verify it passes**

Run: `bun test src/types/kv/motion.test.ts`
Expected: PASS (3 tests)

- [ ] **Step 6: Commit**

```bash
git add src/types/kv/motion.ts src/types/kv/motion.test.ts src/types/studio.ts
git commit -m "feat(web): kv motion types + mode union"
```

---

## Task 2: Feature flag + analytics events

**Files:**
- Modify: `src/lib/featureFlags/constants.ts`
- Modify: `src/lib/analytics/kv-generator-events.ts`

- [ ] **Step 1: Add the flag constant** (in `MAJOR_FEATURE_FLAGS`)

```typescript
  KV_MOTION: "show-kv-motion",
```

- [ ] **Step 2: Add analytics events** (append to `src/lib/analytics/kv-generator-events.ts`, mirroring the `trackKvResize*` pattern with the existing `safeCapture` helper)

```typescript
export interface KvMotionRequestedProps {
  model: string;
  provider: string;
  preset: string | null;
  has_prompt: boolean;
  duration: number;
  ratio: string;
  parent_generation_id: string;
}

export const trackKvMotionRequested = (p: KvMotionRequestedProps) =>
  safeCapture("kv_generator.motion_requested", p);

export interface KvMotionFailedProps {
  error_reason: string;
  http_status: number | null;
  parent_generation_id: string;
}

export const trackKvMotionFailed = (p: KvMotionFailedProps) =>
  safeCapture("kv_generator.motion_failed", p);

export const trackKvMotionDownloaded = (p: { motion_id: string }) =>
  safeCapture("kv_generator.motion_downloaded", p);
```

- [ ] **Step 3: Commit**

```bash
git add src/lib/featureFlags/constants.ts src/lib/analytics/kv-generator-events.ts
git commit -m "feat(web): kv motion feature flag + analytics events"
```

> Register the `show-kv-motion` flag in PostHog (off by default) per the
> frndos-feature-flags skill before enabling in any environment.

---

## Task 3: API client functions

**Files:**
- Modify: `src/services/kv/api.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// src/services/kv/motion-api.test.ts
import { describe, expect, it, vi, beforeEach } from "vitest";
import axiosInstance from "@/services/axios";
import { createMotion, listMotions } from "./api";

vi.mock("@/services/axios");

describe("kv motion api", () => {
  beforeEach(() => vi.clearAllMocks());

  it("lists motions and maps wire → KvMotion", async () => {
    (axiosInstance.get as unknown as ReturnType<typeof vi.fn>).mockResolvedValue({
      data: {
        data: [
          {
            id: "01HX",
            studio_file_id: "f1",
            parent_generation_id: "g1",
            model: "veo-3.1-fast-generate-preview",
            provider: "google",
            preset: "subtle_zoom",
            prompt: null,
            duration: 8,
            ratio: "9:16",
            status: "done",
            video_url: "https://cdn/x.mp4",
            error_message: null,
            created_at: "2026-06-24T00:00:00Z",
            updated_at: "2026-06-24T00:00:00Z",
          },
        ],
      },
    });

    const rows = await listMotions("f1");
    expect(rows[0].videoUrl).toBe("https://cdn/x.mp4");
    expect(rows[0].parentGenerationId).toBe("g1");
  });

  it("posts a create request with snake_case body", async () => {
    (axiosInstance.post as unknown as ReturnType<typeof vi.fn>).mockResolvedValue({
      data: { data: { id: "01HY", status: "pending" } },
    });

    await createMotion("f1", {
      parentGenerationId: "g1",
      model: "veo-3.1-fast-generate-preview",
      provider: "google",
      preset: "subtle_zoom",
      prompt: null,
      duration: 8,
      ratio: "9:16",
    });

    expect(axiosInstance.post).toHaveBeenCalledWith(
      "v1/studio/files/f1/motions",
      expect.objectContaining({
        parent_generation_id: "g1",
        provider: "google",
        duration: 8,
        ratio: "9:16",
      }),
    );
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/services/kv/motion-api.test.ts`
Expected: FAIL — `createMotion` / `listMotions` not exported

- [ ] **Step 3: Implement the client functions** (append to `src/services/kv/api.ts`, reuse the existing `unwrap` helper)

```typescript
import type { KvMotion, KvMotionProvider } from "@/types/kv/motion";

type WireMotion = {
  id: string;
  studio_file_id: string;
  parent_generation_id: string;
  parent_motion_id: string | null;
  model: string;
  provider: KvMotionProvider;
  preset: string | null;
  prompt: string | null;
  duration: number;
  ratio: KvMotion["ratio"];
  generate_audio: boolean;
  status: KvMotion["status"];
  video_url: string | null;
  error_message: string | null;
  created_at: string;
  updated_at: string;
};

function toMotion(w: WireMotion): KvMotion {
  return {
    id: w.id,
    studioFileId: w.studio_file_id,
    parentGenerationId: w.parent_generation_id,
    parentMotionId: w.parent_motion_id,
    model: w.model,
    provider: w.provider,
    preset: w.preset,
    prompt: w.prompt,
    duration: w.duration,
    ratio: w.ratio,
    generateAudio: w.generate_audio,
    status: w.status,
    videoUrl: w.video_url,
    errorMessage: w.error_message,
    createdAt: w.created_at,
    updatedAt: w.updated_at,
  };
}

export async function listMotions(fileId: string): Promise<KvMotion[]> {
  const { data } = await axiosInstance.get(`v1/studio/files/${fileId}/motions`);
  const rows: WireMotion[] = unwrap(data);
  return rows.map(toMotion);
}

export async function createMotion(
  fileId: string,
  body: {
    parentGenerationId: string;
    parentMotionId?: string | null; // set on guided regenerate (lineage)
    model: string;
    provider: KvMotionProvider;
    preset: string | null;
    prompt: string | null;
    duration: number;
    ratio: KvMotion["ratio"];
    generateAudio: boolean;
  },
): Promise<KvMotion> {
  const { data } = await axiosInstance.post(`v1/studio/files/${fileId}/motions`, {
    parent_generation_id: body.parentGenerationId,
    parent_motion_id: body.parentMotionId ?? null,
    model: body.model,
    provider: body.provider,
    preset: body.preset,
    prompt: body.prompt,
    duration: body.duration,
    ratio: body.ratio,
    generate_audio: body.generateAudio,
  });
  return toMotion(unwrap(data));
}

export async function deleteMotion(fileId: string, motionId: string): Promise<void> {
  await axiosInstance.delete(`v1/studio/files/${fileId}/motions/${motionId}`);
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bun test src/services/kv/motion-api.test.ts`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add src/services/kv/api.ts src/services/kv/motion-api.test.ts
git commit -m "feat(web): kv motion api client (list/create/delete)"
```

---

## Task 4: `useKvMotion` hook (list + create + delete + poll)

**Files:**
- Create: `src/lib/studio/kv/useKvMotion.ts`

- [ ] **Step 1: Implement the hook** (mirror `useResizeExports`; poll while any row is in flight)

```typescript
// src/lib/studio/kv/useKvMotion.ts
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createMotion, deleteMotion, listMotions } from "@/services/kv/api";
import {
  trackKvMotionFailed,
  trackKvMotionRequested,
} from "@/lib/analytics/kv-generator-events";
import type { KvMotion, KvMotionProvider } from "@/types/kv/motion";

const QUERY_KEY = (fileId: string) => ["kv-motions", fileId] as const;

export function useKvMotion(fileId: string, parentGenerationId: string | null) {
  const qc = useQueryClient();

  const query = useQuery({
    queryKey: QUERY_KEY(fileId),
    queryFn: () => listMotions(fileId),
    enabled: Boolean(fileId),
    refetchInterval: (q) => {
      const rows = (q.state.data ?? []) as KvMotion[];
      const inFlight = rows.some(
        (r) => r.status === "pending" || r.status === "generating",
      );
      return inFlight ? 4000 : false;
    },
  });

  const create = useMutation({
    mutationFn: (vars: {
      model: string;
      provider: KvMotionProvider;
      preset: string | null;
      prompt: string | null;
      duration: number;
      ratio: KvMotion["ratio"];
      generateAudio: boolean;
      parentMotionId?: string | null; // set on guided regenerate
    }) => {
      if (!parentGenerationId) throw new Error("No active generation to animate");
      return createMotion(fileId, { parentGenerationId, ...vars });
    },
    onSuccess: (row, vars) => {
      qc.setQueryData<KvMotion[]>(QUERY_KEY(fileId), (prev) => {
        const map = new Map((prev ?? []).map((r) => [r.id, r]));
        map.set(row.id, row);
        return Array.from(map.values());
      });
      trackKvMotionRequested({
        model: vars.model,
        provider: vars.provider,
        preset: vars.preset,
        has_prompt: Boolean(vars.prompt && vars.prompt.trim()),
        duration: vars.duration,
        ratio: vars.ratio,
        parent_generation_id: parentGenerationId ?? "",
      });
    },
    onError: (error) => {
      trackKvMotionFailed({
        error_reason: error instanceof Error ? error.message : "unknown",
        http_status:
          (error as { response?: { status?: number } }).response?.status ?? null,
        parent_generation_id: parentGenerationId ?? "",
      });
    },
  });

  const remove = useMutation({
    mutationFn: (motionId: string) => deleteMotion(fileId, motionId),
    onSuccess: (_void, motionId) => {
      qc.setQueryData<KvMotion[]>(QUERY_KEY(fileId), (prev) =>
        (prev ?? []).filter((r) => r.id !== motionId),
      );
    },
  });

  const motions = (query.data ?? []).filter(
    (r) => !parentGenerationId || r.parentGenerationId === parentGenerationId,
  );

  return { motions, isLoading: query.isLoading, create, remove };
}
```

- [ ] **Step 2: Write a focused test** (create-disabled-without-parent)

```typescript
// src/lib/studio/kv/useKvMotion.test.tsx
import { describe, expect, it, vi } from "vitest";
import { renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useKvMotion } from "./useKvMotion";

vi.mock("@/services/kv/api", () => ({
  listMotions: vi.fn().mockResolvedValue([]),
  createMotion: vi.fn(),
  deleteMotion: vi.fn(),
}));

function wrapper({ children }: { children: React.ReactNode }) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return <QueryClientProvider client={qc}>{children}</QueryClientProvider>;
}

describe("useKvMotion", () => {
  it("rejects create when there is no parent generation", async () => {
    const { result } = renderHook(() => useKvMotion("f1", null), { wrapper });
    await waitFor(() => expect(result.current.isLoading).toBe(false));
    await expect(
      result.current.create.mutateAsync({
        model: "veo-3.1-fast-generate-preview",
        provider: "google",
        preset: "subtle_zoom",
        prompt: null,
        duration: 8,
        ratio: "9:16",
        generateAudio: true,
      }),
    ).rejects.toThrow("No active generation");
  });
});
```

- [ ] **Step 3: Run to verify it passes**

Run: `bun test src/lib/studio/kv/useKvMotion.test.tsx`
Expected: PASS (1 test)

- [ ] **Step 4: Commit**

```bash
git add src/lib/studio/kv/useKvMotion.ts src/lib/studio/kv/useKvMotion.test.tsx
git commit -m "feat(web): useKvMotion hook (create/list/delete/poll)"
```

---

## Task 5: `KvMotionPanel` component

**Files:**
- Create: `src/components/studio/kv-generator/KvMotionPanel.tsx`
- Test: `src/components/studio/kv-generator/KvMotionPanel.test.tsx`

Use **frndos components** (`Button`, `RadioButton`/chips, `Input`/textarea). Keep this presentational — it receives state + callbacks (the hook lives in the layout).

> **⚠️ Superseded by the 2026-06-27 revision — adapt the code below.** The panel no
> longer imports `MOTION_MODELS`/`MOTION_DURATIONS`. Instead it receives:
> - `models: MotionModel[]` (already filtered to I2V by the layout) — render each
>   with `ProviderLogo` (`model_provider`) + `name`; selecting one calls `onModelChange(value)`.
> - `capabilities: VideoCapabilities` for the selected model — **duration options =
>   `capabilities.durations`**, **ratio options = `capabilities.ratios`**.
> - `generateAudio: boolean` + `onGenerateAudioChange` — render a frndos `Toggle`
>   only when `audioMode(capabilities) === "optional"`; for `"always"` show a
>   locked-on indicator; for `"none"` render nothing.
> - Optional `hint?: string` (e.g. "Sora has no 1:1 → using 16:9") shown under the
>   ratio control when the layout clamped a value.
> The preset chips + result list below stay as-is. The test's "three models"
> assertion becomes "renders the models it is given" (pass 2–3 fake `MotionModel`s).

- [ ] **Step 1: Write the failing test**

```typescript
// src/components/studio/kv-generator/KvMotionPanel.test.tsx
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { KvMotionPanel } from "./KvMotionPanel";

const baseProps = {
  disabled: false,
  modelId: "veo-3.1-fast-generate-preview",
  onModelChange: vi.fn(),
  preset: "subtle_zoom" as string | null,
  onPresetChange: vi.fn(),
  prompt: "",
  onPromptChange: vi.fn(),
  duration: 8,
  onDurationChange: vi.fn(),
  ratio: "9:16" as const,
  onRatioChange: vi.fn(),
  onGenerate: vi.fn(),
  motions: [],
  onDelete: vi.fn(),
  onRegenerate: vi.fn(),
};

describe("KvMotionPanel", () => {
  it("renders the five presets and three models", () => {
    render(<KvMotionPanel {...baseProps} />);
    expect(screen.getByText("Subtle Zoom")).toBeInTheDocument();
    expect(screen.getByText("Veo 3.1 Fast")).toBeInTheDocument();
    expect(screen.getByText("Kling Omni")).toBeInTheDocument();
    expect(screen.getByText("Sora")).toBeInTheDocument();
  });

  it("calls onGenerate when the button is clicked", async () => {
    const onGenerate = vi.fn();
    render(<KvMotionPanel {...baseProps} onGenerate={onGenerate} />);
    await userEvent.click(screen.getByRole("button", { name: /generate motion/i }));
    expect(onGenerate).toHaveBeenCalledTimes(1);
  });

  it("disables generate while disabled", () => {
    render(<KvMotionPanel {...baseProps} disabled />);
    expect(screen.getByRole("button", { name: /generate motion/i })).toBeDisabled();
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/components/studio/kv-generator/KvMotionPanel.test.tsx`
Expected: FAIL — module not found

- [ ] **Step 3: Implement the panel** (structure; swap raw elements for frndos `Button`/`Input` per frndos-components)

```tsx
// src/components/studio/kv-generator/KvMotionPanel.tsx
"use client";

import { Button } from "@/components/frndos/Button";
import {
  MOTION_DURATIONS,
  MOTION_MODELS,
  MOTION_PRESETS,
  type KvMotion,
} from "@/types/kv/motion";

type Props = {
  disabled: boolean;
  modelId: string;
  onModelChange: (id: string) => void;
  preset: string | null;
  onPresetChange: (preset: string | null) => void;
  prompt: string;
  onPromptChange: (value: string) => void;
  duration: number;
  onDurationChange: (value: number) => void;
  ratio: "16:9" | "9:16" | "1:1";
  onRatioChange: (value: "16:9" | "9:16" | "1:1") => void;
  onGenerate: () => void;
  motions: KvMotion[];
  onDelete: (motionId: string) => void;
  onRegenerate: (motion: KvMotion) => void; // prefills panel + sets lineage
};

export function KvMotionPanel(props: Props) {
  const {
    disabled, modelId, onModelChange, preset, onPresetChange,
    prompt, onPromptChange, duration, onDurationChange, ratio, onRatioChange,
    onGenerate, motions, onDelete, onRegenerate,
  } = props;

  return (
    <aside className="pointer-events-auto w-[280px] rounded-2xl border border-border bg-surface p-4 shadow-xl">
      <h2 className="text-sm font-semibold">Motion</h2>

      <section className="mt-3">
        <p className="text-xs uppercase text-text-subtle">Model</p>
        <div className="mt-1 flex flex-col gap-1">
          {MOTION_MODELS.map((m) => (
            <button
              key={m.id}
              type="button"
              onClick={() => onModelChange(m.id)}
              aria-pressed={modelId === m.id}
              className={`rounded-lg border px-2 py-1.5 text-left text-xs ${
                modelId === m.id ? "border-primary bg-primary/10" : "border-border"
              }`}
            >
              <span className="block font-medium">{m.label}</span>
              <span className="block text-[10px] text-text-subtle">{m.hint}</span>
            </button>
          ))}
        </div>
      </section>

      <section className="mt-3">
        <p className="text-xs uppercase text-text-subtle">Motion preset</p>
        <div className="mt-1 flex flex-wrap gap-1">
          {MOTION_PRESETS.map((p) => (
            <button
              key={p.id}
              type="button"
              onClick={() => onPresetChange(preset === p.id ? null : p.id)}
              aria-pressed={preset === p.id}
              className={`rounded-full border px-2.5 py-1 text-xs ${
                preset === p.id ? "border-primary bg-primary/10" : "border-border"
              }`}
            >
              {p.label}
            </button>
          ))}
        </div>
      </section>

      <section className="mt-3">
        <textarea
          value={prompt}
          onChange={(e) => onPromptChange(e.target.value)}
          placeholder="Optional motion detail…"
          rows={2}
          className="w-full rounded-lg border border-border bg-transparent p-2 text-xs"
        />
      </section>

      <section className="mt-2 flex items-center gap-3 text-xs">
        <label className="flex items-center gap-1">
          Duration
          <select
            value={duration}
            onChange={(e) => onDurationChange(Number(e.target.value))}
            className="rounded border border-border bg-transparent px-1 py-0.5"
          >
            {MOTION_DURATIONS.map((d) => (
              <option key={d} value={d}>{d}s</option>
            ))}
          </select>
        </label>
        <label className="flex items-center gap-1">
          Ratio
          <select
            value={ratio}
            onChange={(e) => onRatioChange(e.target.value as Props["ratio"])}
            className="rounded border border-border bg-transparent px-1 py-0.5"
          >
            <option value="9:16">9:16</option>
            <option value="16:9">16:9</option>
            <option value="1:1">1:1</option>
          </select>
        </label>
      </section>

      <Button
        className="mt-3 w-full"
        disabled={disabled}
        onClick={onGenerate}
      >
        Generate motion
      </Button>

      {motions.length > 0 && (
        <ul className="mt-3 flex flex-col gap-2">
          {motions.map((m) => (
            <li key={m.id} className="rounded-lg border border-border p-2 text-xs">
              <div className="flex items-center justify-between">
                <span className="capitalize">{m.status}</span>
                <button
                  type="button"
                  onClick={() => onDelete(m.id)}
                  aria-label="Delete motion"
                  className="text-text-subtle hover:text-red-400"
                >
                  ✕
                </button>
              </div>
              {m.status === "done" && m.videoUrl && (
                <video
                  src={m.videoUrl}
                  controls
                  className="mt-1 w-full rounded"
                />
              )}
              {m.status === "failed" && (
                <p className="mt-1 text-red-400">{m.errorMessage}</p>
              )}
              {(m.status === "done" || m.status === "failed") && (
                <button
                  type="button"
                  onClick={() => onRegenerate(m)}
                  className="mt-1 text-[11px] text-primary hover:underline"
                >
                  Regenerate
                </button>
              )}
            </li>
          ))}
        </ul>
      )}
    </aside>
  );
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bun test src/components/studio/kv-generator/KvMotionPanel.test.tsx`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/KvMotionPanel.tsx src/components/studio/kv-generator/KvMotionPanel.test.tsx
git commit -m "feat(web): KvMotionPanel (model/preset/prompt + result list)"
```

---

## Task 6: `KvMotionViewport` (first-frame preview)

**Files:**
- Create: `src/components/studio/kv-generator/KvMotionViewport.tsx`

- [ ] **Step 1: Implement the viewport** (shows the active KV image as the first frame, centered, like the resize viewport's static preview)

```tsx
// src/components/studio/kv-generator/KvMotionViewport.tsx
"use client";

type Props = { firstFrameUrl: string | null };

export function KvMotionViewport({ firstFrameUrl }: Props) {
  return (
    <div className="absolute inset-0 flex items-center justify-center p-16">
      {firstFrameUrl ? (
        <figure className="relative">
          <img
            src={firstFrameUrl}
            alt="Motion first frame"
            className="max-h-[70vh] max-w-[70vw] rounded-xl object-contain shadow-2xl"
          />
          <figcaption className="mt-2 text-center text-xs text-text-subtle">
            First frame
          </figcaption>
        </figure>
      ) : (
        <p className="text-sm text-text-subtle">
          Generate or select a KV first to animate it.
        </p>
      )}
    </div>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add src/components/studio/kv-generator/KvMotionViewport.tsx
git commit -m "feat(web): KvMotionViewport first-frame preview"
```

---

## Task 7: Wire Motion into the layout + top-nav tab (flag-gated)

**Files:**
- Modify: `src/components/studio/kv-generator/KvCanvasTopNav.tsx`
- Modify: `src/components/studio/kv-generator/KvGeneratorLayout.tsx`

> **⚠️ Superseded by the 2026-06-27 revision — model list is registry-driven.** In
> the layout, fetch + filter the models and drive the panel adaptively:
> ```tsx
> const { data: videoModelsResp } = useQuery({
>   queryKey: ["video-models"],          // SAME key the chat picker uses (shared cache)
>   queryFn: getVideoModels,
>   staleTime: 1000 * 60 * 10,
> });
> const motionModels = ((videoModelsResp?.data ?? []) as MotionModel[]).filter(isImageToVideo);
> const selectedModel =
>   motionModels.find((m) => m.value === motionModelId) ??
>   motionModels.find((m) => m.value === DEFAULT_MOTION_MODEL_ID) ??
>   motionModels[0];
> const caps = selectedModel?.video_capabilities;
> // provider comes from the selected registry model — NOT MOTION_MODELS.find:
> const provider = selectedModel?.model_provider ?? "google";
> ```
> On model switch, clamp duration (`clampDuration(caps, motionDuration)`) and
> resolve ratio (`resolveRatio(caps, kvRatio)`), set a `hint` when a value changed,
> and reset `motionGenerateAudio` to `true` when entering an `audio:"optional"`
> model. Hold `motionGenerateAudio` in state and include it in the `create.mutate`
> payload. Pass `models={motionModels}`, `capabilities={caps}`,
> `generateAudio`/`onGenerateAudioChange`, and `hint` into `KvMotionPanel`. The
> `DEFAULT_MOTION_MODEL_ID` import stays; the `MOTION_MODELS` import is removed.

- [ ] **Step 1: Add the Motion tab to the top nav** (flag-gated)

In `KvCanvasTopNav.tsx`, extend `CanvasMode` and `CANVAS_MODE_TABS` and conditionally include Motion. The component receives a new `motionEnabled` prop:

```typescript
export type CanvasMode = "sketch" | "craft" | "resize" | "motion";
```
```tsx
// where CANVAS_MODE_TABS is built — append Motion only when enabled
const tabs = [
  { id: "sketch", label: "Sketch", Icon: SketchIcon },
  { id: "craft", label: "Craft", Icon: CraftIcon },
  { id: "resize", label: "Resize", Icon: ({ className }: { className?: string }) => (
    <FrameCorners size={20} weight="regular" className={className} />
  ) },
  ...(motionEnabled
    ? [{ id: "motion", label: "Motion", Icon: ({ className }: { className?: string }) => (
        <FilmSlate size={20} weight="regular" className={className} />
      ) }]
    : []),
] as const;
```

Add `motionEnabled?: boolean` to the top-nav `Props` and use `tabs` in the existing `SegmentedControl` mapping. (Import `FilmSlate` from `@phosphor-icons/react`, matching how `FrameCorners` is imported.)

- [ ] **Step 2: In `KvGeneratorLayout.tsx`, widen the state union** (~line 210)

```typescript
const [canvasMode, setCanvasMode] = useState<
  "sketch" | "craft" | "resize" | "motion"
>("sketch");
```

Also update the seed effect (~line 561) and `handleCanvasModeChange` (~line 675) to allow `"motion"` (add it to the `seed === ...` guard and keep the persisted-mode patch working).

- [ ] **Step 3: Gate + read the flag, instantiate the hook**

```tsx
import { MAJOR_FEATURE_FLAGS, useMajorFeatureFlag } from "@/lib/featureFlags";
import { useKvMotion } from "@/lib/studio/kv/useKvMotion";
import { KvMotionPanel } from "./KvMotionPanel";
import { KvMotionViewport } from "./KvMotionViewport";

const motionEnabled = useMajorFeatureFlag(MAJOR_FEATURE_FLAGS.KV_MOTION);
const activeGeneration = stream.generations[0] ?? null;
const motion = useKvMotion(fileId, activeGeneration?.id ?? null);

// local panel form state
const [motionModelId, setMotionModelId] = useState(DEFAULT_MOTION_MODEL_ID);
const [motionPreset, setMotionPreset] = useState<string | null>("subtle_zoom");
const [motionPrompt, setMotionPrompt] = useState("");
const [motionDuration, setMotionDuration] = useState(8);
const [motionRatio, setMotionRatio] = useState<"16:9" | "9:16" | "1:1">("9:16");
// Guided-regenerate lineage: which prior motion this run was launched from.
const [motionParentId, setMotionParentId] = useState<string | null>(null);

// Regenerate: prefill the panel from a prior row and remember its lineage.
// The user can then add steering text to the prompt before generating.
const handleMotionRegenerate = useCallback((m: KvMotion) => {
  setMotionModelId(m.model);
  setMotionPreset(m.preset);
  setMotionPrompt(m.prompt ?? "");
  setMotionDuration(m.duration);
  setMotionRatio(m.ratio);
  setMotionParentId(m.id);
}, []);
```

(Import `KvMotion` from `@/types/kv/motion`.)

(Import `DEFAULT_MOTION_MODEL_ID` + helpers from `@/types/kv/motion`. Derive
`provider` from the selected **registry** model — `selectedModel?.model_provider`
— per the Task 7 revision note, not from a `MOTION_MODELS` constant.)

- [ ] **Step 4: Render the Motion branch** (next to the existing `canvasMode === "resize"` block, ~line 1028)

```tsx
{canvasMode === "motion" ? (
  <div className="absolute inset-0 overflow-hidden">
    <KvMotionViewport firstFrameUrl={activeGeneration?.image_url ?? null} />
    <div className="pointer-events-none fixed bottom-24 left-6 z-40">
      <KvMotionPanel
        disabled={!activeGeneration || motion.create.isPending}
        modelId={motionModelId}
        onModelChange={setMotionModelId}
        preset={motionPreset}
        onPresetChange={setMotionPreset}
        prompt={motionPrompt}
        onPromptChange={setMotionPrompt}
        duration={motionDuration}
        onDurationChange={setMotionDuration}
        ratio={motionRatio}
        onRatioChange={setMotionRatio}
        onGenerate={() => {
          // provider from the selected registry model (see Task 7 revision note)
          motion.create.mutate({
            model: motionModelId,
            provider,
            preset: motionPreset,
            prompt: motionPrompt.trim() ? motionPrompt.trim() : null,
            duration: motionDuration,
            ratio: motionRatio,
            generateAudio: motionGenerateAudio,
            parentMotionId: motionParentId,
          });
          setMotionParentId(null); // lineage applies to this run only
        }}
        motions={motion.motions}
        onDelete={(id) => motion.remove.mutate(id)}
        onRegenerate={handleMotionRegenerate}
      />
    </div>
  </div>
) : canvasMode === "resize" ? (
  /* ...existing resize block unchanged... */
) : (
  /* ...existing sketch/craft block unchanged... */
)}
```

- [ ] **Step 5: Pass `motionEnabled` to the top nav** wherever `KvCanvasTopNav` is rendered:

```tsx
<KvCanvasTopNav
  /* ...existing props... */
  motionEnabled={motionEnabled}
/>
```

- [ ] **Step 6: Verify the build**

Run: `bun run build`
Expected: build succeeds with no type errors.

- [ ] **Step 7: Commit**

```bash
git add src/components/studio/kv-generator/KvCanvasTopNav.tsx src/components/studio/kv-generator/KvGeneratorLayout.tsx
git commit -m "feat(web): wire Motion canvas mode + flag-gated top-nav tab"
```

---

## Self-Review Checklist (run after all tasks)

- [ ] `bun test src/components/studio/kv-generator/KvMotionPanel.test.tsx src/services/kv/motion-api.test.ts src/lib/studio/kv/useKvMotion.test.tsx src/types/kv/motion.test.ts` all green.
- [ ] `bun run build` passes (the real gate).
- [ ] Motion tab only appears when `show-kv-motion` is on (flag off by default → no tab).
- [ ] Model list comes from `getVideoModels()` filtered by `isImageToVideo` (no hardcoded list); text-only models (HunYuan) never appear.
- [ ] Duration/ratio options come from the selected model's `video_capabilities`; switching model clamps the current values with a hint.
- [ ] Audio toggle shows only for `audio:"optional"` models; locked-on for `"always"`, hidden for `"none"`.
- [ ] Polling stops once all rows are `done`/`failed` (no infinite refetch).
- [ ] Panel uses frndos components (`Button`, etc.) per the frndos-components skill; raw `<select>`/`<textarea>` swapped for frndos equivalents where they exist.
- [ ] Analytics events fire on request/fail/download with snake_case names.
