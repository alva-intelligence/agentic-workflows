# Studio Storyboard → Video — Phase 1 (web) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`. Execute tasks in order; each task is independently verifiable via `bun test` and/or `bun run build`. Do not batch tasks — commit after each.

Design spec: `docs/superpowers/specs/2026-07-03-studio-storyboard-video-design.md`.
Skills that govern this plan (MANDATORY): `web/.claude/skills/frndos-components/`, `web/.claude/skills/frndos-analytics-events/`, `web/.claude/skills/frndos-feature-flags/`.

---

## Goal

Ship the **Phase 1 web UI** for the Storyboard Studio tool: a new brand-scoped Studio tool at `.../studio/storyboard/...` that lets a user (1) list & create storyboards, (2) manage a storyboard-scoped **cast** (upload OR generate-and-lock locked references), (3) edit an ordered board of **scene cards** (description, camera notes, duration, drag-reorder), (4) generate/regenerate a **cast-conditioned frame** per scene with live async status, (5) tag each scene with the cast that appears (AI-inferred + manual override), and (6) run a **brief → decompose** flow that streams an *editable draft* (SSE) and persists on confirm via CRUD. Clips (Phase 2) and stitch (Phase 3) are **out of scope** here.

## Architecture

- **Consumes the api contract** under `/api/studio` (see Global Constraints). Web owns no persistence — every mutation hits api; the board is refetched/polled from api (api is the source of truth).
- **Async frame + cast generation:** the trigger endpoint returns a *pending row* (`status: frame_generating` / `generating`); the UI reflects per-row status via **TanStack Query `refetchInterval` polling that stops when no row is in-flight** — the exact mechanism KV uses (`useKvMotion`, `useUpscales`, `useResizeExports`). We reuse it verbatim. No websocket/Pusher, no dedicated status SSE for frames.
- **Decompose is SSE-streamed** via the shared `sseRequest` client in `src/services/sseClient.ts` (the same client KV chat uses through `sseRequestRaw`). The streamed draft lives in **component state only** and is **not persisted** until the user confirms; confirm creates storyboard → scenes → cast via the CRUD mutations.
- **Data flow per surface:**
  - list/create → `useStoryboards` (query) + `useStoryboardMutations` (create).
  - board editor → `useStoryboard(id)` (query, polled while any scene is generating) + `useSceneMutations` (create/update/delete/reorder/frame trigger) + `useSceneCastMutations`.
  - cast panel → `useCast(storyboardId)` (query, polled while any cast row is generating) + `useCastMutations` (add-upload / generate / approve-lock / delete).
  - decompose → `useDecompose` (SSE hook, returns an in-memory draft + `confirm()` that fans out CRUD).

## Tech Stack

- Next.js 16 App Router (`src/app/(canvas)` + `(dashboard)` route groups), React 19, TypeScript, Tailwind, Bun.
- TanStack Query v5 (server state), Zustand only where an existing store is needed (`useLayoutStore`).
- `@dnd-kit/core` + `@dnd-kit/sortable` for scene reorder (already in `web/package.json` — verify in Task 6; if absent, `bun add @dnd-kit/core @dnd-kit/sortable`).
- PostHog (`posthog-js`) via typed wrappers.
- API client: `axiosInstance` from `@/services/axios`; SSE via `sseRequest` from `@/services/sseClient`.

## Global Constraints

- **Target branch:** `develop` (frnd-web). Branch: `feature/daffa/vc-studio-storyboard`.
- **The gate is `bun run build`** — NOT `tsc`, NOT `bunx vitest`. Unit tests run with **`bun test`** (bunfig preloads `src/test-jsdom-setup.ts` + `src/test-setup.ts` → jsdom + jest-dom + `afterEach(cleanup)`). Test files import from `"vitest"` (bun's vitest-compat shim resolves it); mirror `src/lib/studio/kv/useKvMotion.test.tsx`.
- **frndos components first.** Always use `@/components/frndos/*` before anything else (skill hierarchy: frndos → base → Radix → shadcn). Every page wraps in `BaseLayout` (dashboard) or reuses the canvas `(canvas)/layout.tsx` shell (board editor). Use design-system text/font tokens (`text-textMdMedium`, `font-generalSans`, `text-text-inverse-*`) — no arbitrary `text-[Npx]`, no `text-white`.
- **MUST add a PostHog event for every user interaction** — via a typed wrapper module `src/lib/analytics/storyboard-events.ts` (`safeCapture` + `track*` helpers, `storyboard_*` snake_case names). NEVER raw inline `posthog.capture`. NEVER hand-pass base context (`brand_id`/`workspace_id`/etc. ride via super properties).
- **MUST gate the whole tool behind a PostHog feature flag** `show-storyboard` (kebab-case, `show-*` prefix) via `useMajorFeatureFlag(MAJOR_FEATURE_FLAGS.STORYBOARD)` — same fail-open, flicker-guarded pattern as KV generator's canvas layout. Create the flag in PostHog **before** referencing the key.
- **Brand-scoped routes:** everything lives under `brands/[id]/studio/storyboard/...`; `brandId = params.id`.
- **No comments in code** (AGENTS.md). `bun lint` + `bun format` before each commit.

---

## File Structure

| Path | Kind | Responsibility |
|---|---|---|
| `src/types/storyboard.ts` | **new** type | All storyboard domain types (Storyboard, Scene, CastMember, SceneFrame, SceneCast, DecomposeDraft, wire params). |
| `src/lib/featureFlags/constants.ts` | **edit** | Add `STORYBOARD: "show-storyboard"` to `MAJOR_FEATURE_FLAGS`. |
| `src/lib/analytics/storyboard-events.ts` | **new** analytics | `safeCapture` + typed `track*` wrappers for every storyboard interaction. |
| `src/services/storyboard/api.ts` | **new** service | Axios CRUD client for storyboards / scenes / cast / frames / reorder (mirrors `src/services/kv/api.ts`). |
| `src/services/storyboard/decompose-stream.ts` | **new** service | `streamDecompose()` — wraps `sseRequest` for the decompose SSE (mirrors `src/services/mutate.ts` chat SSE auth pattern). |
| `src/hooks/storyboard/useStoryboards.ts` | **new** hook | List query + create mutation. |
| `src/hooks/storyboard/useStoryboard.ts` | **new** hook | Single-storyboard query (scenes embedded), polled while any scene in-flight. |
| `src/hooks/storyboard/useSceneMutations.ts` | **new** hook | Create/update/delete/reorder scene + trigger frame + set scene-cast mutations. |
| `src/hooks/storyboard/useCast.ts` | **new** hook | Cast list query (polled while any cast row generating) + add-upload/generate/approve/delete mutations. |
| `src/hooks/storyboard/useDecompose.ts` | **new** hook | SSE decompose → in-memory editable draft + `confirm()` fan-out to CRUD. |
| `src/app/(dashboard)/brands/[id]/studio/storyboard/page.tsx` | **new** route | Storyboards list (main tool entry). |
| `src/app/(dashboard)/brands/[id]/studio/storyboard/new/page.tsx` | **new** route | Create storyboard: manual name/ratio OR brief→decompose entry. |
| `src/app/(canvas)/brands/[id]/studio/storyboard/layout.tsx` | **new** route | Canvas shell + feature-flag route guard (mirrors kv-generator canvas layout). |
| `src/app/(canvas)/brands/[id]/studio/storyboard/[storyboardId]/page.tsx` | **new** route | Board editor: scene cards + cast panel + decompose-confirm. |
| `src/app/(canvas)/brands/[id]/studio/storyboard/[storyboardId]/components/SceneCard.tsx` | **new** component | One sortable scene card (text edit + frame preview + generate + cast tags). |
| `src/app/(canvas)/brands/[id]/studio/storyboard/[storyboardId]/components/CastPanel.tsx` | **new** component | Cast list + add (upload / generate-and-lock) + approve-lock. |
| `src/app/(canvas)/brands/[id]/studio/storyboard/[storyboardId]/components/DecomposeDraftReview.tsx` | **new** component | Editable streamed draft + confirm/discard. |
| `src/hooks/storyboard/useStoryboards.test.tsx` | **new** test | Mirrors `useKvMotion.test.tsx`. |
| `src/lib/analytics/storyboard-events.test.ts` | **new** test | Asserts wrappers call `safeCapture` with correct names. |

---

## Cross-service contract (consumed, do not build)

All under `/api/studio`, JSON is **snake_case** on the wire. Async triggers return `202` + a pending row.

```
GET    /storyboards?brand_id=&search=&page=&limit=      -> { data: Storyboard[], meta }
POST   /storyboards                                     -> { data: Storyboard }
GET    /storyboards/{id}                                -> { data: Storyboard (+ scenes[], cast[]) }
PATCH  /storyboards/{id}                                -> { data: Storyboard }
DELETE /storyboards/{id}                                -> 204
POST   /storyboards/{id}/scenes                         -> { data: Scene }
PATCH  /scenes/{id}                                     -> { data: Scene }
DELETE /scenes/{id}                                     -> 204
POST   /storyboards/{id}/scenes/reorder  {ordered_ids}  -> { data: Scene[] }
POST   /scenes/{id}/frame                               -> 202 { data: Scene (status=frame_generating) }
PUT    /scenes/{id}/cast  {cast_member_ids}             -> { data: SceneCast[] }
GET    /storyboards/{id}/cast                           -> { data: CastMember[] }
POST   /cast  (multipart for upload OR json for generate)-> { data: CastMember }
POST   /cast/{id}/generate                              -> 202 { data: CastMember (status=generating) }
PATCH  /cast/{id}  {reference_images / approve}         -> { data: CastMember }
DELETE /cast/{id}                                       -> 204
POST   /storyboards/decompose  (SSE)                    -> streamed draft frames
```

---

## Task 1 — Domain types

**Files:** `src/types/storyboard.ts` (new).

**Interfaces:**
- Consumes: the wire contract above.
- Produces: exported TS types imported by every hook/service/component.

**Step:** Create the file with the exact types.

```ts
export type StoryboardStatus = "draft" | "ready";
export type StoryboardRatio = "16:9" | "9:16" | "1:1";

export type SceneStatus =
  | "empty"
  | "frame_generating"
  | "frame_ready"
  | "failed";

export type CastKind = "character" | "product" | "setting" | "prop";
export type CastSource = "uploaded" | "generated";
export type CastStatus = "empty" | "generating" | "ready" | "failed";

export type CastMember = {
  id: string;
  storyboard_id: string;
  name: string;
  kind: CastKind;
  description: string | null;
  source: CastSource;
  status: CastStatus;
  reference_images: string[];
  thumbnail_url: string | null;
  error_message: string | null;
  created_at: string;
};

export type SceneFrame = {
  id: string;
  scene_id: string;
  version_number: number;
  parent_frame_id: string | null;
  image_url: string;
  thumbnail_url: string | null;
  prompt_snapshot: string;
  model: string;
  provider: string;
  cast_refs_used: string[];
  created_at: string;
};

export type Scene = {
  id: string;
  storyboard_id: string;
  position: number;
  description: string;
  camera_notes: string | null;
  duration: number;
  ratio: StoryboardRatio | null;
  status: SceneStatus;
  current_frame_id: string | null;
  current_frame: SceneFrame | null;
  cast_member_ids: string[];
  error_message: string | null;
  created_at: string;
};

export type Storyboard = {
  id: string;
  workspace_id: string;
  brand_id: string;
  name: string;
  logline: string | null;
  status: StoryboardStatus;
  ratio: StoryboardRatio;
  thumbnail_url: string | null;
  scenes_count: number;
  last_edited_at: string;
  created_at: string;
  scenes?: Scene[];
  cast?: CastMember[];
};

export type StoryboardsParams = {
  brandId?: string;
  search?: string;
  page?: number;
  limit?: number;
};

export type PaginationMeta = {
  current_page: number;
  last_page: number;
  per_page: number;
  total: number;
};

export type DecomposeDraftScene = {
  temp_id: string;
  position: number;
  description: string;
  camera_notes: string | null;
  duration: number;
  cast_temp_ids: string[];
};

export type DecomposeDraftCast = {
  temp_id: string;
  name: string;
  kind: CastKind;
  description: string;
};

export type DecomposeDraft = {
  name: string;
  logline: string;
  ratio: StoryboardRatio;
  scenes: DecomposeDraftScene[];
  cast: DecomposeDraftCast[];
};
```

**Verify:** `cd web && bun run build` (types-only file must not break the build).

**Commit:** `feat(web): add storyboard domain types`

---

## Task 2 — Feature-flag constant + analytics wrappers

**Files:** `src/lib/featureFlags/constants.ts` (edit), `src/lib/analytics/storyboard-events.ts` (new), `src/lib/analytics/storyboard-events.test.ts` (new).

> Prereq (human): create PostHog flag `show-storyboard` in project `FRnD_OS`/389744, name field:
> `Storyboard Studio — Gates the Storyboard tool on web (studio/storyboard routes) and /api/studio/storyboard* on api. When OFF: tool tile hidden, routes redirect to /home, endpoints 404. Default OFF (staged rollout).`

**Step 2a — flag constant:**

```ts
export const MAJOR_FEATURE_FLAGS = {
  ASKFRND: "show-askfrnd",
  BRAND_INSIGHT: "show-brand-insight",
  KV_GENERATOR: "show-kv-generator",
  POPULIX_SURVEY: "show-populix-survey",
  CUSTOMER_INTELLIGENCE: "show-customer-intelligence",
  SIDEBAR_SHELL: "show-sidebar-shell",
  ASKFRND_SHELL: "show-askfrnd-shell",
  EXTRA_CREDIT: "extra-credit-purchase",
  KV_MOTION: "show-kv-motion",
  SHOW_AGENTS: "show-agents",
  STORYBOARD: "show-storyboard",
} as const;
```

**Step 2b — analytics wrappers** (`src/lib/analytics/storyboard-events.ts`), copying the `kv-generator-events.ts` `safeCapture` shape exactly:

```ts
import posthog from "posthog-js";

const safeCapture = (event: string, props: object = {}) => {
  try {
    posthog?.capture(event, { ...props, timestamp: new Date().toISOString() });
  } catch {
    // no-op: analytics never breaks the app
  }
};

export type StoryboardEntryType = "manual" | "brief";
export type StoryboardCastSource = "uploaded" | "generated";
export type StoryboardCastTagAction = "added" | "removed";

export const trackStoryboardOpened = (p: {
  entry_type: "new" | "existing";
  scene_count: number;
  cast_count: number;
}) => safeCapture("storyboard_opened", p);

export const trackStoryboardCreated = (p: {
  entry_type: StoryboardEntryType;
  ratio: string;
  scene_count: number;
}) => safeCapture("storyboard_created", p);

export const trackStoryboardSceneAdded = (p: {
  storyboard_id: string;
  position: number;
}) => safeCapture("storyboard_scene_added", p);

export const trackStoryboardSceneEdited = (p: {
  storyboard_id: string;
  scene_id: string;
  field: "description" | "camera_notes" | "duration";
}) => safeCapture("storyboard_scene_edited", p);

export const trackStoryboardSceneDeleted = (p: {
  storyboard_id: string;
  scene_id: string;
}) => safeCapture("storyboard_scene_deleted", p);

export const trackStoryboardScenesReordered = (p: {
  storyboard_id: string;
  scene_count: number;
}) => safeCapture("storyboard_scenes_reordered", p);

export const trackStoryboardFrameRequested = (p: {
  storyboard_id: string;
  scene_id: string;
  cast_ref_count: number;
  is_regenerate: boolean;
}) => safeCapture("storyboard_frame_requested", p);

export const trackStoryboardFrameFailed = (p: {
  scene_id: string;
  error_reason: string;
  http_status: number | null;
}) => safeCapture("storyboard_frame_failed", p);

export const trackStoryboardCastAdded = (p: {
  storyboard_id: string;
  source: StoryboardCastSource;
  kind: string;
}) => safeCapture("storyboard_cast_added", p);

export const trackStoryboardCastGenerated = (p: {
  storyboard_id: string;
  cast_member_id: string;
}) => safeCapture("storyboard_cast_generated", p);

export const trackStoryboardCastGenerateFailed = (p: {
  cast_member_id: string;
  error_reason: string;
  http_status: number | null;
}) => safeCapture("storyboard_cast_generate_failed", p);

export const trackStoryboardCastLocked = (p: {
  storyboard_id: string;
  cast_member_id: string;
  reference_count: number;
}) => safeCapture("storyboard_cast_locked", p);

export const trackStoryboardSceneCastTagged = (p: {
  storyboard_id: string;
  scene_id: string;
  action: StoryboardCastTagAction;
  ai_inferred_override: boolean;
}) => safeCapture("storyboard_scene_cast_tagged", p);

export const trackStoryboardDecomposeStarted = (p: {
  brief_length: number;
}) => safeCapture("storyboard_decompose_started", p);

export const trackStoryboardDecomposeCompleted = (p: {
  scene_count: number;
  cast_count: number;
}) => safeCapture("storyboard_decompose_completed", p);

export const trackStoryboardDecomposeFailed = (p: {
  error_reason: string;
}) => safeCapture("storyboard_decompose_failed", p);

export const trackStoryboardDecomposeConfirmed = (p: {
  storyboard_id: string;
  scene_count: number;
  cast_count: number;
}) => safeCapture("storyboard_decompose_confirmed", p);

export const trackStoryboardDecomposeDiscarded = (p: {
  scene_count: number;
}) => safeCapture("storyboard_decompose_discarded", p);
```

**Step 2c — test** (`src/lib/analytics/storyboard-events.test.ts`), mirroring the mock/assert shape of `useKvMotion.test.tsx`:

```ts
import { describe, expect, it, vi, beforeEach } from "vitest";

const capture = vi.fn();
vi.mock("posthog-js", () => ({ default: { capture: (...a: unknown[]) => capture(...a) } }));

import {
  trackStoryboardCreated,
  trackStoryboardFrameRequested,
} from "./storyboard-events";

describe("storyboard-events", () => {
  beforeEach(() => capture.mockClear());

  it("fires storyboard_created with a timestamp", () => {
    trackStoryboardCreated({ entry_type: "manual", ratio: "16:9", scene_count: 0 });
    expect(capture).toHaveBeenCalledWith(
      "storyboard_created",
      expect.objectContaining({ entry_type: "manual", timestamp: expect.any(String) })
    );
  });

  it("fires storyboard_frame_requested", () => {
    trackStoryboardFrameRequested({
      storyboard_id: "s1", scene_id: "sc1", cast_ref_count: 2, is_regenerate: false,
    });
    expect(capture).toHaveBeenCalledWith(
      "storyboard_frame_requested",
      expect.objectContaining({ scene_id: "sc1", is_regenerate: false })
    );
  });
});
```

**Verify:** `cd web && bun test src/lib/analytics/storyboard-events.test.ts && bun run build`

**Commit:** `feat(web): storyboard feature flag constant + PostHog event wrappers`

---

## Task 3 — API client (axios) + decompose SSE service

**Files:** `src/services/storyboard/api.ts` (new), `src/services/storyboard/decompose-stream.ts` (new).

**Interfaces:**
- Consumes: `axiosInstance` (`@/services/axios`), `sseRequest` (`@/services/sseClient`), types from Task 1.
- Produces: async functions returning typed data (mirror `src/services/kv/api.ts` — return `response.data`, snake_case bodies, `v1/studio/...` paths).

**Step 3a — CRUD client** (`src/services/storyboard/api.ts`):

```ts
import axiosInstance from "@/services/axios";
import type {
  CastMember,
  PaginationMeta,
  Scene,
  Storyboard,
  StoryboardRatio,
  StoryboardsParams,
} from "@/types/storyboard";

export async function fetchStoryboards(
  params: StoryboardsParams
): Promise<{ data: Storyboard[]; meta: PaginationMeta }> {
  const q = new URLSearchParams();
  if (params.brandId) q.set("brand_id", params.brandId);
  if (params.search) q.set("search", params.search);
  if (params.page) q.set("page", String(params.page));
  if (params.limit) q.set("limit", String(params.limit));
  const { data } = await axiosInstance.get(`v1/studio/storyboards?${q.toString()}`);
  return data;
}

export async function fetchStoryboard(id: string): Promise<{ data: Storyboard }> {
  const { data } = await axiosInstance.get(`v1/studio/storyboards/${id}`);
  return data;
}

export async function createStoryboard(body: {
  brand_id: string;
  name: string;
  ratio: StoryboardRatio;
  logline?: string;
}): Promise<{ data: Storyboard }> {
  const { data } = await axiosInstance.post(`v1/studio/storyboards`, body);
  return data;
}

export async function updateStoryboard(
  id: string,
  body: Partial<Pick<Storyboard, "name" | "logline" | "ratio" | "status">>
): Promise<{ data: Storyboard }> {
  const { data } = await axiosInstance.patch(`v1/studio/storyboards/${id}`, body);
  return data;
}

export async function deleteStoryboard(id: string): Promise<void> {
  await axiosInstance.delete(`v1/studio/storyboards/${id}`);
}

export async function createScene(
  storyboardId: string,
  body: { description: string; camera_notes?: string; duration: number }
): Promise<{ data: Scene }> {
  const { data } = await axiosInstance.post(
    `v1/studio/storyboards/${storyboardId}/scenes`,
    body
  );
  return data;
}

export async function updateScene(
  id: string,
  body: Partial<Pick<Scene, "description" | "camera_notes" | "duration" | "ratio">>
): Promise<{ data: Scene }> {
  const { data } = await axiosInstance.patch(`v1/studio/scenes/${id}`, body);
  return data;
}

export async function deleteScene(id: string): Promise<void> {
  await axiosInstance.delete(`v1/studio/scenes/${id}`);
}

export async function reorderScenes(
  storyboardId: string,
  orderedIds: string[]
): Promise<{ data: Scene[] }> {
  const { data } = await axiosInstance.post(
    `v1/studio/storyboards/${storyboardId}/scenes/reorder`,
    { ordered_ids: orderedIds }
  );
  return data;
}

export async function triggerSceneFrame(sceneId: string): Promise<{ data: Scene }> {
  const { data } = await axiosInstance.post(`v1/studio/scenes/${sceneId}/frame`);
  return data;
}

export async function setSceneCast(
  sceneId: string,
  castMemberIds: string[]
): Promise<{ data: Scene }> {
  const { data } = await axiosInstance.put(`v1/studio/scenes/${sceneId}/cast`, {
    cast_member_ids: castMemberIds,
  });
  return data;
}

export async function fetchCast(
  storyboardId: string
): Promise<{ data: CastMember[] }> {
  const { data } = await axiosInstance.get(
    `v1/studio/storyboards/${storyboardId}/cast`
  );
  return data;
}

export async function createCastUpload(
  storyboardId: string,
  body: { name: string; kind: string; file: File }
): Promise<{ data: CastMember }> {
  const form = new FormData();
  form.append("storyboard_id", storyboardId);
  form.append("name", body.name);
  form.append("kind", body.kind);
  form.append("reference", body.file);
  const { data } = await axiosInstance.post(`v1/studio/cast`, form, {
    headers: { "Content-Type": "multipart/form-data" },
  });
  return data;
}

export async function createCastGenerate(
  storyboardId: string,
  body: { name: string; kind: string; description: string }
): Promise<{ data: CastMember }> {
  const { data } = await axiosInstance.post(`v1/studio/cast`, {
    storyboard_id: storyboardId,
    source: "generated",
    ...body,
  });
  return data;
}

export async function generateCastReference(
  castId: string
): Promise<{ data: CastMember }> {
  const { data } = await axiosInstance.post(`v1/studio/cast/${castId}/generate`);
  return data;
}

export async function approveCastReference(
  castId: string,
  referenceImages: string[]
): Promise<{ data: CastMember }> {
  const { data } = await axiosInstance.patch(`v1/studio/cast/${castId}`, {
    reference_images: referenceImages,
    approve: true,
  });
  return data;
}

export async function deleteCast(castId: string): Promise<void> {
  await axiosInstance.delete(`v1/studio/cast/${castId}`);
}
```

**Step 3b — decompose SSE** (`src/services/storyboard/decompose-stream.ts`), reusing `sseRequest` + the bearer-token/base-URL pattern from `mutate.ts` chat SSE:

```ts
import { sseRequest } from "@/services/sseClient";
import { getValidAccessToken } from "@/lib/token-manager";
import { getSession } from "@/lib/auth";
import axiosInstance from "@/services/axios";
import type { DecomposeDraft } from "@/types/storyboard";

type DecomposeFrame =
  | { type: "start" }
  | { type: "content"; draft: Partial<DecomposeDraft> }
  | { type: "complete"; draft: DecomposeDraft }
  | { type: "error"; message: string };

export async function streamDecompose(opts: {
  brandId: string;
  brief: string;
  ratio: string;
  signal?: AbortSignal;
  onDraft: (draft: Partial<DecomposeDraft>) => void;
  onComplete: (draft: DecomposeDraft) => void;
  onError: (err: Error) => void;
}): Promise<void> {
  const baseURL = axiosInstance.defaults.baseURL;
  const refreshed = await getValidAccessToken();
  const { accessToken } = getSession();
  const token = refreshed ?? accessToken;
  if (!token) {
    opts.onError(new Error("Missing session token"));
    return;
  }
  await sseRequest<DecomposeFrame>({
    url: `${baseURL}/v1/studio/storyboards/decompose`,
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ brand_id: opts.brandId, brief: opts.brief, ratio: opts.ratio }),
    signal: opts.signal,
    onFrame: (frame) => {
      if (frame.type === "content") opts.onDraft(frame.draft);
    },
    onComplete: (frame) => {
      if (frame && frame.type === "complete") opts.onComplete(frame.draft);
    },
    onError: (err) => opts.onError(err),
  });
}
```

**Verify:** `cd web && bun run build`

**Commit:** `feat(web): storyboard api client + decompose SSE service`

---

## Task 4 — List + create hooks

**Files:** `src/hooks/storyboard/useStoryboards.ts` (new), `src/hooks/storyboard/useStoryboards.test.tsx` (new).

**Interfaces:**
- Produces: `useStoryboards({ workspaceId, brandId, search }) → UseQueryResult<{ data: Storyboard[]; meta }>` and a `useCreateStoryboard()` mutation.
- Consumes: `fetchStoryboards` / `createStoryboard` (Task 3), `trackStoryboardCreated` (Task 2).

**Step:**

```ts
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createStoryboard, fetchStoryboards } from "@/services/storyboard/api";
import { trackStoryboardCreated } from "@/lib/analytics/storyboard-events";
import type { StoryboardRatio } from "@/types/storyboard";

const LIST_KEY = (brandId?: string, search?: string) =>
  ["storyboard", "list", brandId, search] as const;

export function useStoryboards(params: {
  workspaceId: string | undefined;
  brandId: string | undefined;
  search?: string;
  page?: number;
  limit?: number;
}) {
  return useQuery({
    queryKey: LIST_KEY(params.brandId, params.search),
    queryFn: () =>
      fetchStoryboards({
        brandId: params.brandId,
        search: params.search,
        page: params.page,
        limit: params.limit,
      }),
    enabled: !!params.workspaceId && !!params.brandId,
  });
}

export function useCreateStoryboard(brandId: string | undefined) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: { name: string; ratio: StoryboardRatio; logline?: string }) => {
      if (!brandId) throw new Error("No brand selected");
      return createStoryboard({ brand_id: brandId, ...body });
    },
    onSuccess: (res, vars) => {
      qc.invalidateQueries({ queryKey: ["storyboard", "list", brandId] });
      trackStoryboardCreated({ entry_type: "manual", ratio: vars.ratio, scene_count: 0 });
    },
  });
}
```

**Test** (`useStoryboards.test.tsx`), mirroring `useKvMotion.test.tsx` wrapper:

```ts
import { describe, expect, it, vi } from "vitest";
import { renderHook, waitFor } from "@testing-library/react";
import { createElement } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useCreateStoryboard } from "./useStoryboards";

vi.mock("@/services/storyboard/api", () => ({
  fetchStoryboards: vi.fn().mockResolvedValue({ data: [], meta: {} }),
  createStoryboard: vi.fn(),
}));
vi.mock("@/lib/analytics/storyboard-events", () => ({ trackStoryboardCreated: vi.fn() }));

function wrapper({ children }: { children: React.ReactNode }) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return createElement(QueryClientProvider, { client: qc }, children);
}

describe("useCreateStoryboard", () => {
  it("rejects when no brand is selected", async () => {
    const { result } = renderHook(() => useCreateStoryboard(undefined), { wrapper });
    await waitFor(() => expect(result.current.isPending).toBe(false));
    await expect(
      result.current.mutateAsync({ name: "x", ratio: "16:9" })
    ).rejects.toThrow("No brand selected");
  });
});
```

**Verify:** `cd web && bun test src/hooks/storyboard/useStoryboards.test.tsx && bun run build`

**Commit:** `feat(web): storyboard list + create hooks`

---

## Task 5 — Storyboards list page + create page + feature-flag route guard

**Files:** `src/app/(dashboard)/brands/[id]/studio/storyboard/page.tsx` (new), `.../storyboard/new/page.tsx` (new), `src/app/(canvas)/brands/[id]/studio/storyboard/layout.tsx` (new).

**Step 5a — canvas route guard** (mirrors kv-generator canvas layout exactly):

```tsx
"use client";
import { useEffect } from "react";
import { useRouter } from "next/navigation";
import { MAJOR_FEATURE_FLAGS, useMajorFeatureFlag } from "@/lib/featureFlags";

export default function StoryboardCanvasLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const router = useRouter();
  const enabled = useMajorFeatureFlag(MAJOR_FEATURE_FLAGS.STORYBOARD);
  useEffect(() => {
    if (!enabled) router.replace("/home");
  }, [enabled, router]);
  if (!enabled) return null;
  return <>{children}</>;
}
```

**Step 5b — list page** (`storyboard/page.tsx`): use `BaseLayout`, `useStoryboards`, `MediaCard`/`ProjectCard`-style grid, an `Input` search (frndos), a "New storyboard" card linking to `.../storyboard/new`. Gate with the same major flag at the top (`useMajorFeatureFlag(...STORYBOARD)` → if false, `notFound()`), and fire `trackStoryboardOpened({ entry_type: "existing", ... })` on mount via a once-guard `useRef`. Reuse the exact list-page skeleton from `studio/projects/page.tsx` (search + grid + empty state), swapping the hook and card. Cards link to `.../storyboard/[storyboardId]`.

**Step 5c — create page** (`storyboard/new/page.tsx`): `BaseLayout` with two tabs via `TabsRounded`:
- **Manual:** `Input` (name) + `SegmentedControl`/`RadioButton` (ratio 16:9 / 9:16 / 1:1) + `Button` → `useCreateStoryboard().mutateAsync` → `router.push(.../[id])`.
- **Brief → decompose:** `TextArea` (brief) + ratio picker + `Button` "Draft with AI" → creates an empty storyboard first (or routes to the board editor carrying the brief in query state) then opens the board editor's decompose flow. Keep the decompose engine in Task 9; here just route to `.../[storyboardId]?decompose=<brief>` after creating a draft storyboard, OR (simpler, DRY) route to `.../new`'s inline `DecomposeDraftReview` — pick the board-editor route to avoid duplicating the review UI.

Fire `trackStoryboardCreated({ entry_type })` only in the mutation `onSuccess` (already in Task 4 for manual; brief path fires it in Task 9's `confirm`).

**Verify:** `cd web && bun run build`

**Commit:** `feat(web): storyboard list + create pages behind show-storyboard flag`

---

## Task 6 — Board editor shell + scene/reorder hooks

**Files:** `src/hooks/storyboard/useStoryboard.ts` (new), `src/hooks/storyboard/useSceneMutations.ts` (new), `.../storyboard/[storyboardId]/page.tsx` (new).

**Step 6a — single-storyboard query with polling** (stops when no scene in-flight — the KV mechanism):

```ts
import { useQuery } from "@tanstack/react-query";
import { fetchStoryboard } from "@/services/storyboard/api";
import type { Storyboard } from "@/types/storyboard";

export const STORYBOARD_KEY = (id: string) => ["storyboard", "detail", id] as const;

export function useStoryboard(id: string | undefined) {
  return useQuery({
    queryKey: STORYBOARD_KEY(id ?? ""),
    queryFn: () => fetchStoryboard(id!),
    enabled: !!id,
    refetchInterval: (q) => {
      const sb = (q.state.data as { data: Storyboard } | undefined)?.data;
      const inFlight = (sb?.scenes ?? []).some(
        (s) => s.status === "frame_generating"
      );
      return inFlight ? 4000 : false;
    },
  });
}
```

**Step 6b — scene mutations** (`useSceneMutations.ts`): `create`, `update`, `remove`, `reorder`, `triggerFrame`, `setCast` — each `onSuccess` invalidates `STORYBOARD_KEY(id)`; `reorder` does an optimistic `qc.setQueryData` reordering + rollback on error (mirror `useKvMotion` `setQueryData` merge). `triggerFrame` fires `trackStoryboardFrameRequested`; `onError` fires `trackStoryboardFrameFailed`. `update` fires `trackStoryboardSceneEdited` (debounced by the caller). `reorder` fires `trackStoryboardScenesReordered`.

**Step 6c — board editor page** (`[storyboardId]/page.tsx`): reuse `(canvas)/layout.tsx` shell (the route lives under `(canvas)`, so the guard from 5a applies). Layout: left = `CastPanel` (Task 8), center = a `@dnd-kit/sortable` `SortableContext` of `SceneCard`s (Task 7) + an "Add scene" `Button`, top = storyboard name (inline-editable `Input`) + ratio label. Verify `@dnd-kit/*` is in `package.json`; if not, `bun add @dnd-kit/core @dnd-kit/sortable`. On drag end, call `reorder.mutate(orderedIds)`. Fire `trackStoryboardOpened({ entry_type: "existing" })` once on mount.

**Verify:** `cd web && bun run build`

**Commit:** `feat(web): storyboard board editor shell + scene/reorder hooks`

---

## Task 7 — SceneCard: text edit + frame preview + generate + status

**Files:** `.../storyboard/[storyboardId]/components/SceneCard.tsx` (new).

**Props:**

```ts
type SceneCardProps = {
  scene: Scene;
  cast: CastMember[];
  onUpdate: (patch: Partial<Pick<Scene, "description" | "camera_notes" | "duration">>) => void;
  onDelete: () => void;
  onGenerateFrame: () => void;
  onToggleCast: (castMemberId: string, next: boolean) => void;
};
```

**Step:** Build with frndos components:
- Drag handle (from `@dnd-kit/sortable` `useSortable` `listeners`).
- `TextArea` (description), `Input` (camera notes), `Input`/`SegmentedControl` (duration) — each fires `onUpdate` on blur/commit; caller debounces + fires `trackStoryboardSceneEdited`.
- **Frame preview area** driven by `scene.status`:
  - `empty` → placeholder + `Button` "Generate frame" → `onGenerateFrame`.
  - `frame_generating` → skeleton + spinner (the polling in Task 6a flips it automatically).
  - `frame_ready` → `img` (`scene.current_frame.image_url`) + `Button` "Regenerate".
  - `failed` → error text (`scene.error_message`) + retry `Button`.
- **Cast tags row** (Task 8b) using `Label` chips per tagged cast member.
- Delete via `ActionMenu` → `onDelete` (fires `trackStoryboardSceneDeleted` in caller).

Wrap in `useSortable({ id: scene.id })`, apply `transform`/`transition`. Use only design tokens for text.

**Verify:** `cd web && bun run build`

**Commit:** `feat(web): storyboard SceneCard with frame preview + async status`

---

## Task 8 — Cast panel + scene cast tagging

**Files:** `src/hooks/storyboard/useCast.ts` (new), `.../[storyboardId]/components/CastPanel.tsx` (new); edit `SceneCard.tsx` for the tag UI.

**Step 8a — cast hook** (poll while generating, KV mechanism):

```ts
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  approveCastReference,
  createCastGenerate,
  createCastUpload,
  deleteCast,
  fetchCast,
  generateCastReference,
} from "@/services/storyboard/api";
import {
  trackStoryboardCastAdded,
  trackStoryboardCastGenerated,
  trackStoryboardCastGenerateFailed,
  trackStoryboardCastLocked,
} from "@/lib/analytics/storyboard-events";
import type { CastMember } from "@/types/storyboard";

export const CAST_KEY = (sid: string) => ["storyboard", "cast", sid] as const;

export function useCast(storyboardId: string) {
  const qc = useQueryClient();
  const query = useQuery({
    queryKey: CAST_KEY(storyboardId),
    queryFn: () => fetchCast(storyboardId),
    enabled: !!storyboardId,
    refetchInterval: (q) => {
      const rows = (q.state.data as { data: CastMember[] } | undefined)?.data ?? [];
      return rows.some((r) => r.status === "generating") ? 4000 : false;
    },
  });

  const addUpload = useMutation({
    mutationFn: (v: { name: string; kind: string; file: File }) =>
      createCastUpload(storyboardId, v),
    onSuccess: (_r, v) => {
      qc.invalidateQueries({ queryKey: CAST_KEY(storyboardId) });
      trackStoryboardCastAdded({ storyboard_id: storyboardId, source: "uploaded", kind: v.kind });
    },
  });

  const addGenerate = useMutation({
    mutationFn: (v: { name: string; kind: string; description: string }) =>
      createCastGenerate(storyboardId, v),
    onSuccess: (r, v) => {
      qc.invalidateQueries({ queryKey: CAST_KEY(storyboardId) });
      trackStoryboardCastAdded({ storyboard_id: storyboardId, source: "generated", kind: v.kind });
      return generateCastReference(r.data.id);
    },
  });

  const generate = useMutation({
    mutationFn: (castId: string) => generateCastReference(castId),
    onSuccess: (r) => {
      qc.invalidateQueries({ queryKey: CAST_KEY(storyboardId) });
      trackStoryboardCastGenerated({ storyboard_id: storyboardId, cast_member_id: r.data.id });
    },
    onError: (err, castId) =>
      trackStoryboardCastGenerateFailed({
        cast_member_id: castId,
        error_reason: err instanceof Error ? err.message : "unknown",
        http_status: (err as { response?: { status?: number } }).response?.status ?? null,
      }),
  });

  const approve = useMutation({
    mutationFn: (v: { castId: string; images: string[] }) =>
      approveCastReference(v.castId, v.images),
    onSuccess: (r, v) => {
      qc.invalidateQueries({ queryKey: CAST_KEY(storyboardId) });
      trackStoryboardCastLocked({
        storyboard_id: storyboardId,
        cast_member_id: r.data.id,
        reference_count: v.images.length,
      });
    },
  });

  const remove = useMutation({
    mutationFn: (castId: string) => deleteCast(castId),
    onSuccess: () => qc.invalidateQueries({ queryKey: CAST_KEY(storyboardId) }),
  });

  return {
    cast: query.data?.data ?? [],
    isLoading: query.isLoading,
    addUpload,
    addGenerate,
    generate,
    approve,
    remove,
  };
}
```

**Step 8b — CastPanel** (`CastPanel.tsx`): list of cast rows (`Avatar`/thumbnail + name + `kind` `Label` + status). "Add cast" opens a `BaseModal` with a `TabsRounded` toggle:
- **Upload:** name `Input` + `kind` `SegmentedControl` + file picker → `addUpload`.
- **Generate & lock:** name `Input` + `kind` + `TextArea` (description) → `addGenerate`; when the row flips to `ready` (via poll), show the candidate image + "Lock reference" `Button` → `approve`.

**Step 8c — scene cast tagging** (in `SceneCard.tsx`): render tagged cast as `Label` chips (AI-inferred ones get a subtle "AI" badge). A `ChipInput` with `variant="selectOption"` + `options={cast.map(c => ({ id: c.id, label: c.name }))}` + `selectedValues={scene.cast_member_ids}` lets the user add/remove tags; `onAdd`/remove calls `onToggleCast(castId, next)` → `setSceneCast` mutation → fires `trackStoryboardSceneCastTagged({ action, ai_inferred_override })` (`ai_inferred_override: true` when the user removes an AI-inferred tag or adds a manual one).

**Verify:** `cd web && bun run build`

**Commit:** `feat(web): storyboard cast panel + AI-inferred scene cast tagging`

---

## Task 9 — Decompose stream + editable draft + confirm

**Files:** `src/hooks/storyboard/useDecompose.ts` (new), `.../[storyboardId]/components/DecomposeDraftReview.tsx` (new); wire into the create page (Task 5c) / board editor.

**Step 9a — decompose hook:**

```ts
import { useCallback, useRef, useState } from "react";
import { streamDecompose } from "@/services/storyboard/decompose-stream";
import {
  trackStoryboardDecomposeStarted,
  trackStoryboardDecomposeCompleted,
  trackStoryboardDecomposeFailed,
} from "@/lib/analytics/storyboard-events";
import type { DecomposeDraft } from "@/types/storyboard";

export function useDecompose(brandId: string) {
  const [draft, setDraft] = useState<DecomposeDraft | null>(null);
  const [isStreaming, setIsStreaming] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const abortRef = useRef<AbortController | null>(null);

  const start = useCallback(
    async (brief: string, ratio: string) => {
      setError(null);
      setIsStreaming(true);
      trackStoryboardDecomposeStarted({ brief_length: brief.length });
      abortRef.current = new AbortController();
      await streamDecompose({
        brandId,
        brief,
        ratio,
        signal: abortRef.current.signal,
        onDraft: (partial) =>
          setDraft((prev) => ({ ...(prev ?? emptyDraft(ratio)), ...partial } as DecomposeDraft)),
        onComplete: (full) => {
          setDraft(full);
          setIsStreaming(false);
          trackStoryboardDecomposeCompleted({
            scene_count: full.scenes.length,
            cast_count: full.cast.length,
          });
        },
        onError: (err) => {
          setError(err.message);
          setIsStreaming(false);
          trackStoryboardDecomposeFailed({ error_reason: err.message });
        },
      });
    },
    [brandId]
  );

  const cancel = useCallback(() => {
    abortRef.current?.abort();
    setIsStreaming(false);
  }, []);

  return { draft, setDraft, isStreaming, error, start, cancel };
}

function emptyDraft(ratio: string): DecomposeDraft {
  return { name: "", logline: "", ratio: ratio as DecomposeDraft["ratio"], scenes: [], cast: [] };
}
```

**Step 9b — DecomposeDraftReview** (`DecomposeDraftReview.tsx`): renders the in-memory `draft` (editable name `Input`, per-scene `TextArea`/`Input`, cast list), streaming shimmer while `isStreaming`. Two actions:
- **Discard** → clears draft, fires `trackStoryboardDecomposeDiscarded`.
- **Confirm & create** → `onConfirm(draft)`: the parent runs the CRUD fan-out — `createStoryboard` (name/ratio/logline) → for each draft cast `createCastGenerate` → for each draft scene `createScene` then `setSceneCast(scene, resolved cast ids)`. On success, fire `trackStoryboardCreated({ entry_type: "brief", ... })` + `trackStoryboardDecomposeConfirmed(...)` and `router.push(.../[newId])`. Nothing persists until this step (the guardrail the spec requires).

Resolve `cast_temp_ids` → real cast ids by keeping a `Map<temp_id, real_id>` populated as each `createCastGenerate` resolves, then map each scene's `cast_temp_ids` through it before `setSceneCast`.

**Verify:** `cd web && bun run build`

**Commit:** `feat(web): storyboard brief→decompose SSE draft with persist-on-confirm`

---

## Task 10 — Final verification + lint/format

**Files:** none (verification only).

**Steps:**
1. `cd web && bun lint:fix && bun format`
2. `cd web && bun test src/hooks/storyboard src/lib/analytics/storyboard-events.test.ts`
3. `cd web && bun run build` — MUST pass (the real gate).
4. Manual smoke (dev, flag forced ON in dev/staging): create storyboard → add scene → tag cast → generate frame (observe `frame_generating` → `frame_ready` via poll) → add cast (upload + generate-and-lock) → brief→decompose → edit draft → confirm. Force flag OFF in prod-mode to confirm `/home` redirect (route guard) and hidden tile.
5. Add all new events as rows to the taxonomy doc; verify base-context props in PostHog Live Events.

**Commit:** `chore(web): lint/format + storyboard phase-1 verification`

---

## Out of scope (Phase 1 web)

- Scene **clips** (Phase 2) and **stitch/assembly view** (Phase 3).
- Brand-level reusable cast library.
- Any api / ai-service work (separate per-service plans).
