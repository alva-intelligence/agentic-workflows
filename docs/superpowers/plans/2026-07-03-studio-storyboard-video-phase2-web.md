# Studio Storyboard → Video — Phase 2 (web) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`. Execute tasks in order; each task is independently verifiable via `bun test` and/or `bun run build`. Do not batch tasks — commit after each.

Design spec: `docs/superpowers/specs/2026-07-03-studio-storyboard-video-design.md`.
Skills that govern this plan (MANDATORY): `web/.claude/skills/frndos-components/`, `web/.claude/skills/frndos-analytics-events/`, `web/.claude/skills/frndos-feature-flags/`.

---

## Goal

Ship the **Phase 2 web UI** for the Storyboard Studio tool: extend the Phase 1 board editor `SceneCard` with **per-scene clip controls** — generate/regenerate a clip from the scene's approved frame, a **motion-preset picker** (reusing the KV Motion presets), a **motion-prompt** input, a **video-model picker** driven by the SAME registry KV Motion uses (`GET /v1/threads/video-models`, filtered to `image_to_video`), an **audio toggle** shown when the selected model supports audio, a `<video>` preview, and per-clip status via the existing TanStack Query polling (extended to keep polling while any scene is `clip_generating`). Phase 2 depends on Phase 1 (scenes + approved frames exist). Stitch/assembly (Phase 3) is **out of scope** here.

## Architecture

- **Consumes the Phase 2 api contract** under `/api/studio` (see Cross-service contract). Web owns no persistence — every clip mutation hits api; the board is polled from api (api is the source of truth).
- **Async clip generation reuses the KV Motion web pattern verbatim** (`web/src/lib/studio/kv/useKvMotion.ts`): the trigger endpoint returns a *pending clip row* (`status: queued`); the UI reflects per-clip status via **TanStack Query `refetchInterval` polling that stops when nothing is in-flight**. We extend the existing Phase 1 `useStoryboard(id)` poll predicate so it keeps polling while any scene is `clip_generating` (in addition to `frame_generating`). No websocket/Pusher.
- **Video-model picker reuses the KV Motion registry path.** `GET /v1/threads/video-models` via the existing `getVideoModels` query fn (`src/services/query.ts`), filtered to `image_to_video` capable + active models using the existing `MotionModel` / `isImageToVideo` helpers in `src/types/kv/motion.ts`. The audio toggle uses the same `video_capabilities.audio` mode (`always` | `optional` | `none`).
- **Motion presets are the KV Motion presets verbatim** — reuse the exported `MOTION_PRESETS` array from `src/types/kv/motion.ts` (`{ id, label }[]`), which maps 1:1 to ai-service `build_motion_prompt` keys.
- **Data flow:** clip controls live inside `SceneCard`; a new `useSceneClips(storyboardId)` hook wraps the clip mutations (`generateClip`, `regenerateClip`) and invalidates the Phase 1 `STORYBOARD_KEY(id)` query so the polled board reflects clip status. Clips arrive embedded on each scene (`scene.clips[]`) from the Phase 1 `GET /storyboards/{id}` detail response (which Phase 2 api extends to embed `clips`).

## Tech Stack

- Next.js 16 App Router, React 19, TypeScript, Tailwind, Bun.
- TanStack Query v5 (server state).
- PostHog (`posthog-js`) via typed wrappers — extend the Phase 1 `src/lib/analytics/storyboard-events.ts`.
- API client: `axiosInstance` from `@/services/axios`; video-model registry via the existing `getVideoModels` from `@/services/query`.

## Global Constraints

- **Target branch:** `develop` (frnd-web). Continue on the Phase 1 branch `feature/daffa/vc-studio-storyboard` (Phase 2 is additive).
- **The gate is `bun run build`** — NOT `tsc`, NOT `bunx vitest`. Unit tests run with **`bun test`** (bunfig preloads `src/test-jsdom-setup.ts` + `src/test-setup.ts`). Test files import from `"vitest"`; mirror `web/src/lib/studio/kv/useKvMotion.test.tsx`.
- **frndos components first.** Always use `@/components/frndos/*` before anything else. Reuse the KV Motion picker components/patterns where they exist. Use design-system text/font tokens — no arbitrary `text-[Npx]`, no `text-white`.
- **MUST add a PostHog event for every user interaction** — via the Phase 1 typed wrapper module `src/lib/analytics/storyboard-events.ts` (`safeCapture` + `track*` helpers, `storyboard_clip_*` snake_case names). NEVER raw inline `posthog.capture`.
- **The whole tool is already gated** behind the Phase 1 `show-storyboard` flag (canvas route guard). Phase 2 adds NO new flag.
- **Brand-scoped routes:** clip controls live inside the existing board editor at `brands/[id]/studio/storyboard/[storyboardId]`.
- **No comments in code** (AGENTS.md). `bun lint:fix` + `bun format` before each commit.

---

## Cross-service contract (consumed, do not build)

All under `/api/studio`, JSON is **snake_case** on the wire. Async triggers return `202` + a pending clip row.

```
POST   /scenes/{scene}/clip   {model, provider, motion_preset?, motion_prompt?, duration?, generate_audio?}
                                                        -> 202 { data: SceneClip (status=queued) }
POST   /clips/{clip}/regenerate {model?, provider?, motion_preset?, motion_prompt?, duration?, generate_audio?}
                                                        -> 202 { data: SceneClip (status=queued) }
GET    /storyboards/{id}   (Phase 1, now embeds clips)  -> { data: Storyboard (+ scenes[] each with clips[]) }
GET    /v1/threads/video-models   (existing registry)   -> { data: MotionModel[] }
```

A `SceneClip` on the wire:

```
{ id, scene_id, parent_clip_id, frame_id, video_url, duration, model, provider,
  motion_preset, motion_prompt, status: "queued"|"generating"|"ready"|"failed",
  error_message, created_at }
```

---

## Task 1 — Clip domain types + extended scene status

**Files:** `src/types/storyboard.ts` (edit — add clip types, extend `SceneStatus`, add `clips` to `Scene`).

**Interfaces:**
- Consumes: the Phase 2 wire contract above.
- Produces: `SceneClip`, `SceneClipStatus` types; `Scene.clips: SceneClip[]`; `SceneStatus` extended with `clip_generating | clip_ready`.

**Step:** Edit `src/types/storyboard.ts`.

Replace the Phase 1 `SceneStatus` union with the full vocab:

```ts
export type SceneStatus =
  | "empty"
  | "frame_generating"
  | "frame_ready"
  | "clip_generating"
  | "clip_ready"
  | "failed";
```

Add the clip types:

```ts
export type SceneClipStatus = "queued" | "generating" | "ready" | "failed";

export type SceneClip = {
  id: string;
  scene_id: string;
  parent_clip_id: string | null;
  frame_id: string;
  video_url: string | null;
  duration: number;
  model: string;
  provider: string;
  motion_preset: string | null;
  motion_prompt: string | null;
  status: SceneClipStatus;
  error_message: string | null;
  created_at: string;
};
```

Add `clips` to the existing `Scene` type (append the field):

```ts
  clips: SceneClip[];
```

Add the clip request param types:

```ts
export type GenerateClipParams = {
  model: string;
  provider: string;
  motion_preset: string | null;
  motion_prompt: string | null;
  duration: number;
  generate_audio: boolean;
};

export type RegenerateClipParams = Partial<GenerateClipParams>;
```

**Verify:** `cd web && bun run build`

**Commit:** `feat(web): storyboard clip domain types + clip scene statuses`

---

## Task 2 — Clip analytics wrappers

**Files:** `src/lib/analytics/storyboard-events.ts` (edit — add `storyboard_clip_*` wrappers), `src/lib/analytics/storyboard-events.test.ts` (edit — add clip assertions).

> Prereq (human): add the new event rows to the taxonomy doc before merge.

**Step 2a — wrappers** (append to `src/lib/analytics/storyboard-events.ts`, matching the Phase 1 `safeCapture` shape):

```ts
export const trackStoryboardClipRequested = (p: {
  storyboard_id: string;
  scene_id: string;
  model: string;
  provider: string;
  motion_preset: string | null;
  has_prompt: boolean;
  duration: number;
  generate_audio: boolean;
  is_regenerate: boolean;
}) => safeCapture("storyboard_clip_requested", p);

export const trackStoryboardClipFailed = (p: {
  scene_id: string;
  error_reason: string;
  http_status: number | null;
  is_regenerate: boolean;
}) => safeCapture("storyboard_clip_failed", p);

export const trackStoryboardClipModelChanged = (p: {
  storyboard_id: string;
  scene_id: string;
  model: string;
  provider: string;
}) => safeCapture("storyboard_clip_model_changed", p);
```

**Step 2b — test** (append to `src/lib/analytics/storyboard-events.test.ts`):

```ts
import { trackStoryboardClipRequested } from "./storyboard-events";

describe("storyboard clip events", () => {
  beforeEach(() => capture.mockClear());

  it("fires storyboard_clip_requested with a timestamp", () => {
    trackStoryboardClipRequested({
      storyboard_id: "sb1",
      scene_id: "sc1",
      model: "veo-3.1-fast-generate-preview",
      provider: "google",
      motion_preset: "subtle_zoom",
      has_prompt: false,
      duration: 8,
      generate_audio: true,
      is_regenerate: false,
    });
    expect(capture).toHaveBeenCalledWith(
      "storyboard_clip_requested",
      expect.objectContaining({
        scene_id: "sc1",
        model: "veo-3.1-fast-generate-preview",
        is_regenerate: false,
        timestamp: expect.any(String),
      })
    );
  });
});
```

> `capture` + the `posthog-js` mock are already declared at the top of the Phase 1 test file; reuse them — do not redeclare the mock.

**Verify:** `cd web && bun test src/lib/analytics/storyboard-events.test.ts && bun run build`

**Commit:** `feat(web): storyboard clip PostHog event wrappers`

---

## Task 3 — Clip API client + video-model registry hook

**Files:** `src/services/storyboard/api.ts` (edit — add clip functions), `src/hooks/storyboard/useClipVideoModels.ts` (new).

**Interfaces:**
- Consumes: `axiosInstance`, `getVideoModels` (`@/services/query`), types from Task 1, `MotionModel`/`isImageToVideo` (`@/types/kv/motion`).
- Produces: `generateClip`, `regenerateClip` API fns; `useClipVideoModels()` returning I2V-capable active models.

**Step 3a — clip API fns** (append to `src/services/storyboard/api.ts`):

```ts
import type { GenerateClipParams, RegenerateClipParams, SceneClip } from "@/types/storyboard";

export async function generateClip(
  sceneId: string,
  body: GenerateClipParams
): Promise<{ data: SceneClip }> {
  const { data } = await axiosInstance.post(
    `v1/studio/scenes/${sceneId}/clip`,
    body
  );
  return data;
}

export async function regenerateClip(
  clipId: string,
  body: RegenerateClipParams
): Promise<{ data: SceneClip }> {
  const { data } = await axiosInstance.post(
    `v1/studio/clips/${clipId}/regenerate`,
    body
  );
  return data;
}
```

**Step 3b — video-model hook** (`src/hooks/storyboard/useClipVideoModels.ts`) — reuse the KV Motion registry query key + I2V filter:

```ts
import { useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import { getVideoModels } from "@/services/query";
import { isImageToVideo, type MotionModel } from "@/types/kv/motion";

export function useClipVideoModels() {
  const query = useQuery({
    queryKey: ["video-models"],
    queryFn: getVideoModels,
    staleTime: 1000 * 60 * 10,
    retry: 2,
  });

  const models = useMemo<MotionModel[]>(() => {
    const all = (query.data?.data ?? []) as MotionModel[];
    return all.filter(isImageToVideo);
  }, [query.data]);

  return { models, isLoading: query.isLoading };
}
```

**Verify:** `cd web && bun run build`

**Commit:** `feat(web): storyboard clip api client + I2V video-model hook`

---

## Task 4 — `useSceneClips` mutation hook

**Files:** `src/hooks/storyboard/useSceneClips.ts` (new), `src/hooks/storyboard/useSceneClips.test.tsx` (new).

**Interfaces:**
- Produces: `useSceneClips(storyboardId) → { generate, regenerate }` mutations. Both invalidate the Phase 1 `STORYBOARD_KEY(storyboardId)` on success so the polled board reflects the new clip. `generate` fires `trackStoryboardClipRequested`; `onError` fires `trackStoryboardClipFailed`.
- Consumes: `generateClip`/`regenerateClip` (Task 3), Phase 1 `STORYBOARD_KEY` (`@/hooks/storyboard/useStoryboard`), analytics wrappers (Task 2).

**Step:**

```ts
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { generateClip, regenerateClip } from "@/services/storyboard/api";
import { STORYBOARD_KEY } from "@/hooks/storyboard/useStoryboard";
import {
  trackStoryboardClipRequested,
  trackStoryboardClipFailed,
} from "@/lib/analytics/storyboard-events";
import type { GenerateClipParams, RegenerateClipParams } from "@/types/storyboard";

export function useSceneClips(storyboardId: string) {
  const qc = useQueryClient();

  const invalidate = () =>
    qc.invalidateQueries({ queryKey: STORYBOARD_KEY(storyboardId) });

  const generate = useMutation({
    mutationFn: (v: { sceneId: string; params: GenerateClipParams }) =>
      generateClip(v.sceneId, v.params),
    onSuccess: (_r, v) => {
      invalidate();
      trackStoryboardClipRequested({
        storyboard_id: storyboardId,
        scene_id: v.sceneId,
        model: v.params.model,
        provider: v.params.provider,
        motion_preset: v.params.motion_preset,
        has_prompt: Boolean(v.params.motion_prompt && v.params.motion_prompt.trim()),
        duration: v.params.duration,
        generate_audio: v.params.generate_audio,
        is_regenerate: false,
      });
    },
    onError: (err, v) =>
      trackStoryboardClipFailed({
        scene_id: v.sceneId,
        error_reason: err instanceof Error ? err.message : "unknown",
        http_status:
          (err as { response?: { status?: number } }).response?.status ?? null,
        is_regenerate: false,
      }),
  });

  const regenerate = useMutation({
    mutationFn: (v: {
      clipId: string;
      sceneId: string;
      params: RegenerateClipParams;
    }) => regenerateClip(v.clipId, v.params),
    onSuccess: (_r, v) => {
      invalidate();
      trackStoryboardClipRequested({
        storyboard_id: storyboardId,
        scene_id: v.sceneId,
        model: v.params.model ?? "",
        provider: v.params.provider ?? "",
        motion_preset: v.params.motion_preset ?? null,
        has_prompt: Boolean(v.params.motion_prompt && v.params.motion_prompt.trim()),
        duration: v.params.duration ?? 0,
        generate_audio: v.params.generate_audio ?? true,
        is_regenerate: true,
      });
    },
    onError: (err, v) =>
      trackStoryboardClipFailed({
        scene_id: v.sceneId,
        error_reason: err instanceof Error ? err.message : "unknown",
        http_status:
          (err as { response?: { status?: number } }).response?.status ?? null,
        is_regenerate: true,
      }),
  });

  return { generate, regenerate };
}
```

**Test** (`src/hooks/storyboard/useSceneClips.test.tsx`), mirroring `useKvMotion.test.tsx` wrapper:

```ts
import { describe, expect, it, vi } from "vitest";
import { renderHook, waitFor } from "@testing-library/react";
import { createElement } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useSceneClips } from "./useSceneClips";

const generateClip = vi.fn().mockResolvedValue({ data: { id: "cl1" } });
vi.mock("@/services/storyboard/api", () => ({
  generateClip: (...a: unknown[]) => generateClip(...a),
  regenerateClip: vi.fn(),
}));
vi.mock("@/hooks/storyboard/useStoryboard", () => ({
  STORYBOARD_KEY: (id: string) => ["storyboard", "detail", id],
}));
const trackRequested = vi.fn();
vi.mock("@/lib/analytics/storyboard-events", () => ({
  trackStoryboardClipRequested: (...a: unknown[]) => trackRequested(...a),
  trackStoryboardClipFailed: vi.fn(),
}));

function wrapper({ children }: { children: React.ReactNode }) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return createElement(QueryClientProvider, { client: qc }, children);
}

describe("useSceneClips", () => {
  it("calls generateClip and fires the requested event", async () => {
    const { result } = renderHook(() => useSceneClips("sb1"), { wrapper });
    await result.current.generate.mutateAsync({
      sceneId: "sc1",
      params: {
        model: "veo-3.1-fast-generate-preview",
        provider: "google",
        motion_preset: "subtle_zoom",
        motion_prompt: null,
        duration: 8,
        generate_audio: true,
      },
    });
    await waitFor(() => expect(generateClip).toHaveBeenCalled());
    expect(generateClip).toHaveBeenCalledWith("sc1", expect.objectContaining({ model: "veo-3.1-fast-generate-preview" }));
    expect(trackRequested).toHaveBeenCalledWith(
      expect.objectContaining({ scene_id: "sc1", is_regenerate: false })
    );
  });
});
```

**Verify:** `cd web && bun test src/hooks/storyboard/useSceneClips.test.tsx && bun run build`

**Commit:** `feat(web): useSceneClips generate + regenerate mutations`

---

## Task 5 — Extend board polling to clip_generating

**Files:** `src/hooks/storyboard/useStoryboard.ts` (edit — extend the `refetchInterval` predicate).

**Interfaces:**
- The Phase 1 `useStoryboard(id)` query already polls while any scene is `frame_generating`. Extend the predicate so it keeps polling while any scene is `clip_generating` OR any embedded clip is `queued`/`generating`.

**Step:** In `src/hooks/storyboard/useStoryboard.ts`, replace the `refetchInterval` body:

```ts
    refetchInterval: (q) => {
      const sb = (q.state.data as { data: Storyboard } | undefined)?.data;
      const scenes = sb?.scenes ?? [];
      const inFlight = scenes.some(
        (s) =>
          s.status === "frame_generating" ||
          s.status === "clip_generating" ||
          (s.clips ?? []).some(
            (c) => c.status === "queued" || c.status === "generating"
          )
      );
      return inFlight ? 4000 : false;
    },
```

**Verify:** `cd web && bun run build`

**Commit:** `feat(web): keep polling the board while clips are generating`

---

## Task 6 — Clip controls in SceneCard

**Files:** `.../storyboard/[storyboardId]/components/SceneCard.tsx` (edit — add clip section); `.../[storyboardId]/components/ClipControls.tsx` (new — extracted clip sub-panel).

**Interfaces:**
- `SceneCard` gains a **clip section** rendered only when the scene has an approved frame (`scene.status === "frame_ready"` or later, i.e. `scene.current_frame_id != null`). Clips are read from `scene.clips[]` (embedded by the api detail response).
- New `ClipControls` component props:

```ts
type ClipControlsProps = {
  scene: Scene;
  onGenerate: (params: GenerateClipParams) => void;
  onRegenerate: (clipId: string, params: RegenerateClipParams) => void;
};
```

**Step 6a — `ClipControls.tsx`** — build with frndos components + the KV Motion registry/preset reuse:
- **Video-model picker:** `useClipVideoModels()` (Task 3) → a `Select`/dropdown of I2V models (`model.name`, value `model.value`, provider `model.model_provider`). Default to the KV Motion default `DEFAULT_MOTION_MODEL_ID` from `@/types/kv/motion` when present in the list, else the first model. On change fire `trackStoryboardClipModelChanged`. Resolve the selected model's `video_capabilities` for the audio toggle + duration options.
- **Motion-preset picker:** map the exported `MOTION_PRESETS` (`{ id, label }[]`) from `@/types/kv/motion` into `RadioButton`/`SegmentedControl` options; `null` selection is allowed when a motion prompt is provided.
- **Motion-prompt input:** `TextArea` (optional free-text steering). A preset OR a non-blank prompt is required — disable the Generate button until one is present (mirrors the api/ai-service validation).
- **Duration:** `SegmentedControl` from the selected model's `video_capabilities.durations` (clamp with `clampDuration`), default `default_duration`.
- **Audio toggle:** a `Toggle` shown when `video_capabilities.audio !== "none"`; forced ON + disabled when `audio === "always"`, user-controllable when `"optional"`, hidden when `"none"` (use the existing `audioMode` helper).
- **Ratio:** derive from the scene's ratio via `resolveRatio(caps, scene.ratio ?? storyboard ratio)` — the api falls back server-side, so web does not send ratio; it is informational only.
- **Latest clip preview:** pick the newest `scene.clips[0]` (api returns clips newest-first). Render by status:
  - `queued` / `generating` → skeleton + spinner (the Task 5 poll flips it automatically).
  - `ready` → `<video src={clip.video_url} controls playsInline />` + a **Regenerate** `Button` (opens the same controls prefilled from the clip's `motion_preset`/`motion_prompt`/`model`/`provider`/`duration`) → `onRegenerate(clip.id, params)`.
  - `failed` → `clip.error_message` + a **Retry** `Button` → `onGenerate(params)`.
  - no clips yet → a **Generate clip** `Button` → `onGenerate(params)`.

**Step 6b — wire into `SceneCard.tsx`:** below the Phase 1 frame preview area, render `<ClipControls scene={scene} onGenerate={...} onRegenerate={...} />` gated on `scene.current_frame_id != null`. The parent board editor passes `onGenerate`/`onRegenerate` from `useSceneClips(storyboardId)` (Task 4) — `onGenerate = (params) => generate.mutate({ sceneId: scene.id, params })`, `onRegenerate = (clipId, params) => regenerate.mutate({ clipId, sceneId: scene.id, params })`.

**Verify:** `cd web && bun run build`

**Commit:** `feat(web): SceneCard clip controls (model/preset/prompt/audio + video preview)`

---

## Task 7 — Final verification + lint/format

**Files:** none (verification only).

**Steps:**
1. `cd web && bun lint:fix && bun format`
2. `cd web && bun test src/hooks/storyboard src/lib/analytics/storyboard-events.test.ts`
3. `cd web && bun run build` — MUST pass (the real gate).
4. Manual smoke (dev, `show-storyboard` forced ON): open a storyboard with an approved frame → pick an I2V model → pick a preset (+ optional prompt) → toggle audio if supported → Generate clip (observe `queued`/`generating` → `ready` via poll, board keeps polling) → play the `<video>` preview → Regenerate (observe parent-prefilled controls + a new clip row) → force a failure to confirm the `failed` state + Retry.
5. Verify `storyboard_clip_*` events fire in PostHog Live Events (project `FRnD_OS` / 389744) with base-context props; add the new rows to the taxonomy doc.

**Commit:** `chore(web): lint/format + storyboard clip phase-2 verification`

---

## Out of scope (Phase 2 web)

- Stitch / assembly view (Phase 3).
- Any api / ai-service work (separate per-service plans).
- Clip trimming / timeline editing beyond generate + regenerate.
