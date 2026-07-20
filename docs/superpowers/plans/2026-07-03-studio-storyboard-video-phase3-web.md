# Studio Storyboard → Video — Phase 3 (web) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`. Execute tasks in order; each task is independently verifiable via `bun test` and/or `bun run build`. Do not batch tasks — commit after each.

Design spec: `docs/superpowers/specs/2026-07-03-studio-storyboard-video-design.md` (Pipeline ⑤ + stitch/transition decisions).
Skills that govern this plan (MANDATORY): `web/.claude/skills/frndos-components/`, `web/.claude/skills/frndos-analytics-events/`, `web/.claude/skills/frndos-feature-flags/`.

---

## Goal

Ship the **Phase 3 web UI** for the Storyboard Studio tool: an **assembly view** — a sub-page/panel of the board editor that lets the user (1) pick a transition (**cut** default / **crossfade**), (2) hit a **Render** button that is **DISABLED until every scene has a `ready` clip** (with helper text listing which scene numbers are still missing clips), (3) watch render status via the **existing TanStack Query polling** (poll while `render_status=rendering`), (4) **play** the finished `final_video_url` in a `<video>` element, and (5) **download** it. Every interaction fires a `storyboard_render_*` PostHog event. This depends on Phase 2 (scene clips exist) and consumes the Phase 3 api contract.

## Architecture

- **Consumes the api contract** under `/api/studio` (see Cross-service contract). Web owns no persistence — the render trigger hits api; the board (with `render_status` + `final_video_url`) is refetched/polled from api (api is the source of truth).
- **Async render:** the `POST /storyboards/{id}/render` trigger returns `202` with the storyboard now `render_status=rendering`; the UI reflects status via the **existing `useStoryboard(id)` query's `refetchInterval` polling** — extended to also poll while `render_status === "rendering"` (the exact KV-style mechanism already used for `frame_generating` scenes). When the render finishes, the poll picks up `render_status=ready` + `final_video_url` and stops. No websocket/Pusher, no dedicated status SSE.
- **Render readiness is derived client-side** from the already-loaded scenes: the Render button is enabled only when **every** scene has a clip with `status === "ready"`; otherwise it is disabled and helper text lists the 1-based scene numbers (positions) that lack a ready clip. The api re-validates and returns `422 { missing_scene_positions }` as the authoritative guard; the client shows that response if it ever races.
- **Data flow:** assembly view → `useStoryboard(id)` (existing query, now polled while rendering) + `useStoryboardRender(id)` (**new** hook: the render mutation + derived readiness).

## Tech Stack

- Next.js 16 App Router (`(canvas)` route group), React 19, TypeScript, Tailwind, Bun.
- TanStack Query v5 (server state).
- PostHog (`posthog-js`) via the typed wrapper module `storyboard-events.ts` (extended here).
- API client: `axiosInstance` from `@/services/axios`.

## Global Constraints

- **Target branch:** `develop` (frnd-web). Branch: `feature/daffa/vc-studio-storyboard` (same branch as Phases 1/2 if continuing).
- **The gate is `bun run build`** — NOT `tsc`, NOT `bunx vitest`. Unit tests run with **`bun test`** (bunfig preloads jsdom + jest-dom + `afterEach(cleanup)`). Test files import from `"vitest"` (bun's vitest-compat shim resolves it); mirror `src/hooks/storyboard/useStoryboards.test.tsx` from Phase 1.
- **frndos components first.** Always use `@/components/frndos/*` before anything else (frndos → base → Radix → shadcn). Use design-system text/font tokens (`text-textMdMedium`, `font-generalSans`) — no arbitrary `text-[Npx]`, no `text-white`.
- **MUST add a PostHog event for every user interaction** — via the existing typed wrapper module `src/lib/analytics/storyboard-events.ts` (`safeCapture` + `track*` helpers, `storyboard_render_*` snake_case names). NEVER raw inline `posthog.capture`. NEVER hand-pass base context (`brand_id`/`workspace_id`/etc. ride via super properties).
- **The whole tool is already gated** behind `useMajorFeatureFlag(MAJOR_FEATURE_FLAGS.STORYBOARD)` via the Phase 1 canvas layout route guard — the assembly view lives under that same `(canvas)` guard, so no new flag wiring is needed.
- **Brand-scoped routes:** everything lives under `brands/[id]/studio/storyboard/[storyboardId]/...`; `brandId = params.id`.
- **No comments in code** (AGENTS.md). `bun lint` + `bun format` before each commit.

---

## Cross-service contract (consumed, do not build)

New in Phase 3, under `/api/studio`, JSON snake_case on the wire:

```
POST /storyboards/{id}/render  { transition: "cut" | "crossfade" }
     -> 202 { data: Storyboard (render_status=rendering, render_transition) }
     -> 422 { message, missing_scene_positions: number[] }   (some scenes lack a ready clip)
```

The `Storyboard` object now also carries (added by Phase 3 api):

```
final_video_url:    string | null
render_status:      "idle" | "rendering" | "ready" | "failed"
render_transition:  "cut" | "crossfade" | null
```

Each `Scene` carries its clip (from Phase 2). This plan reads `scene`'s latest clip status to derive readiness — the exact field is defined in Task 1 (`current_clip` / `clip_status`), conform to the Phase 2 web types.

---

## Task 1 — Extend domain types for render

**Files:** `src/types/storyboard.ts` (edit).

**Interfaces:**
- Consumes: the Phase 3 contract above + the Phase 2 clip shape already on `Scene`.
- Produces: `RenderStatus`, `RenderTransition` types + three new fields on `Storyboard`; a `SceneClipStatus`-aware readiness field on `Scene` (align to Phase 2 — if Phase 2 already added `current_clip` / `clip_status`, reuse it; otherwise add `clip_status`).

**Step:** Edit `src/types/storyboard.ts`:

```ts
export type RenderStatus = "idle" | "rendering" | "ready" | "failed";
export type RenderTransition = "cut" | "crossfade";
```

Add to the `Storyboard` type (after `thumbnail_url`):

```ts
  final_video_url: string | null;
  render_status: RenderStatus;
  render_transition: RenderTransition | null;
```

Ensure `Scene` exposes a clip-readiness signal (reuse the Phase 2 field if present; otherwise add):

```ts
  clip_status: "empty" | "generating" | "ready" | "failed";
```

> If Phase 2 already named this `current_clip: SceneClip | null` (with `SceneClip.status`), do NOT duplicate — derive readiness from `scene.current_clip?.status === "ready"` in Task 3 instead of `clip_status`. Pick ONE and use it consistently across Tasks 2–4. This plan's snippets assume `clip_status`; if reusing `current_clip`, swap the reads accordingly.

**Verify:** `cd web && bun run build`

**Commit:** `feat(web): storyboard render domain types`

---

## Task 2 — Render analytics wrappers + API client

**Files:** `src/lib/analytics/storyboard-events.ts` (edit), `src/lib/analytics/storyboard-events.test.ts` (edit), `src/services/storyboard/api.ts` (edit).

**Interfaces:**
- Produces: `trackStoryboardRender*` typed wrappers + a `renderStoryboard(id, transition)` axios call returning `{ data: Storyboard }`.
- Consumes: `safeCapture` (existing), `axiosInstance` + `Storyboard`/`RenderTransition` types.

**Step 2a — analytics wrappers** (append to `src/lib/analytics/storyboard-events.ts`):

```ts
export type StoryboardRenderTransition = "cut" | "crossfade";

export const trackStoryboardRenderRequested = (p: {
  storyboard_id: string;
  transition: StoryboardRenderTransition;
  scene_count: number;
  is_rerender: boolean;
}) => safeCapture("storyboard_render_requested", p);

export const trackStoryboardRenderBlocked = (p: {
  storyboard_id: string;
  missing_scene_count: number;
}) => safeCapture("storyboard_render_blocked", p);

export const trackStoryboardRenderCompleted = (p: {
  storyboard_id: string;
  transition: StoryboardRenderTransition;
}) => safeCapture("storyboard_render_completed", p);

export const trackStoryboardRenderFailed = (p: {
  storyboard_id: string;
  error_reason: string;
  http_status: number | null;
}) => safeCapture("storyboard_render_failed", p);

export const trackStoryboardRenderDownloaded = (p: {
  storyboard_id: string;
}) => safeCapture("storyboard_render_downloaded", p);
```

**Step 2b — API client** (append to `src/services/storyboard/api.ts`):

```ts
export async function renderStoryboard(
  storyboardId: string,
  transition: "cut" | "crossfade"
): Promise<{ data: Storyboard }> {
  const { data } = await axiosInstance.post(
    `v1/studio/storyboards/${storyboardId}/render`,
    { transition }
  );
  return data;
}
```

> `Storyboard` is already imported in `api.ts` from Phase 1; if not, add it to the existing `import type { … } from "@/types/storyboard"` block.

**Step 2c — test** (append to `src/lib/analytics/storyboard-events.test.ts`):

```ts
import {
  trackStoryboardRenderRequested,
  trackStoryboardRenderFailed,
} from "./storyboard-events";

describe("storyboard render events", () => {
  beforeEach(() => capture.mockClear());

  it("fires storyboard_render_requested with transition + timestamp", () => {
    trackStoryboardRenderRequested({
      storyboard_id: "sb1",
      transition: "crossfade",
      scene_count: 3,
      is_rerender: false,
    });
    expect(capture).toHaveBeenCalledWith(
      "storyboard_render_requested",
      expect.objectContaining({ transition: "crossfade", timestamp: expect.any(String) })
    );
  });

  it("fires storyboard_render_failed with http_status", () => {
    trackStoryboardRenderFailed({ storyboard_id: "sb1", error_reason: "422", http_status: 422 });
    expect(capture).toHaveBeenCalledWith(
      "storyboard_render_failed",
      expect.objectContaining({ http_status: 422 })
    );
  });
});
```

> The `capture` mock + `vi.mock("posthog-js", …)` already sit at the top of this test file from Phase 1 — the new `describe` block reuses them.

**Verify:** `cd web && bun test src/lib/analytics/storyboard-events.test.ts && bun run build`

**Commit:** `feat(web): storyboard render event wrappers + render api client`

---

## Task 3 — Render hook (mutation + derived readiness) + extend polling

**Files:** `src/hooks/storyboard/useStoryboardRender.ts` (new), `src/hooks/storyboard/useStoryboard.ts` (edit), `src/hooks/storyboard/useStoryboardRender.test.tsx` (new).

**Interfaces:**
- Produces: `useStoryboardRender(storyboardId, brandId) → { render, readiness }` where:
  - `readiness: { ready: boolean; missingPositions: number[] }` derived from the passed scenes.
  - `render`: a TanStack mutation; `mutate({ transition, sceneCount, isRerender })`; `onSuccess` invalidates `STORYBOARD_KEY(id)` + fires `trackStoryboardRenderRequested`; `onError` fires `trackStoryboardRenderFailed` (and `trackStoryboardRenderBlocked` on a `422`).
- Consumes: `renderStoryboard` (Task 2), `STORYBOARD_KEY` (Phase 1), render event wrappers.

**Step 3a — extend `useStoryboard` polling** (edit `src/hooks/storyboard/useStoryboard.ts`) so it keeps polling while `render_status === "rendering"` (in addition to the Phase 1 `frame_generating` condition):

```ts
    refetchInterval: (q) => {
      const sb = (q.state.data as { data: Storyboard } | undefined)?.data;
      const sceneInFlight = (sb?.scenes ?? []).some(
        (s) => s.status === "frame_generating"
      );
      const rendering = sb?.render_status === "rendering";
      return sceneInFlight || rendering ? 4000 : false;
    },
```

**Step 3b — render hook** (`useStoryboardRender.ts`):

```ts
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { renderStoryboard } from "@/services/storyboard/api";
import { STORYBOARD_KEY } from "@/hooks/storyboard/useStoryboard";
import {
  trackStoryboardRenderRequested,
  trackStoryboardRenderBlocked,
  trackStoryboardRenderFailed,
} from "@/lib/analytics/storyboard-events";
import type { Scene } from "@/types/storyboard";

export function deriveRenderReadiness(scenes: Scene[]): {
  ready: boolean;
  missingPositions: number[];
} {
  if (scenes.length === 0) {
    return { ready: false, missingPositions: [] };
  }
  const missingPositions = scenes
    .filter((s) => s.clip_status !== "ready")
    .map((s) => s.position)
    .sort((a, b) => a - b);
  return { ready: missingPositions.length === 0, missingPositions };
}

export function useStoryboardRender(storyboardId: string, scenes: Scene[]) {
  const qc = useQueryClient();
  const readiness = deriveRenderReadiness(scenes);

  const render = useMutation({
    mutationFn: (v: { transition: "cut" | "crossfade" }) =>
      renderStoryboard(storyboardId, v.transition),
    onSuccess: (_r, v) => {
      qc.invalidateQueries({ queryKey: STORYBOARD_KEY(storyboardId) });
      trackStoryboardRenderRequested({
        storyboard_id: storyboardId,
        transition: v.transition,
        scene_count: scenes.length,
        is_rerender: false,
      });
    },
    onError: (err) => {
      const status =
        (err as { response?: { status?: number } }).response?.status ?? null;
      if (status === 422) {
        trackStoryboardRenderBlocked({
          storyboard_id: storyboardId,
          missing_scene_count: readiness.missingPositions.length,
        });
      }
      trackStoryboardRenderFailed({
        storyboard_id: storyboardId,
        error_reason: err instanceof Error ? err.message : "unknown",
        http_status: status,
      });
    },
  });

  return { render, readiness };
}
```

**Step 3c — test** (`useStoryboardRender.test.tsx`), mirroring the Phase 1 `useStoryboards.test.tsx` wrapper:

```ts
import { describe, expect, it, vi } from "vitest";
import { renderHook, waitFor } from "@testing-library/react";
import { createElement } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { deriveRenderReadiness, useStoryboardRender } from "./useStoryboardRender";
import type { Scene } from "@/types/storyboard";

vi.mock("@/services/storyboard/api", () => ({ renderStoryboard: vi.fn() }));
vi.mock("@/lib/analytics/storyboard-events", () => ({
  trackStoryboardRenderRequested: vi.fn(),
  trackStoryboardRenderBlocked: vi.fn(),
  trackStoryboardRenderFailed: vi.fn(),
}));

function scene(position: number, clip_status: Scene["clip_status"]): Scene {
  return {
    id: `s${position}`,
    storyboard_id: "sb1",
    position,
    description: "",
    camera_notes: null,
    duration: 5,
    ratio: null,
    status: "frame_ready",
    current_frame_id: null,
    current_frame: null,
    cast_member_ids: [],
    clip_status,
    error_message: null,
    created_at: "",
  } as Scene;
}

function wrapper({ children }: { children: React.ReactNode }) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return createElement(QueryClientProvider, { client: qc }, children);
}

describe("deriveRenderReadiness", () => {
  it("is ready only when every scene has a ready clip", () => {
    expect(deriveRenderReadiness([scene(1, "ready"), scene(2, "ready")])).toEqual({
      ready: true,
      missingPositions: [],
    });
  });

  it("lists missing scene positions sorted ascending", () => {
    const r = deriveRenderReadiness([scene(2, "generating"), scene(1, "ready"), scene(3, "empty")]);
    expect(r.ready).toBe(false);
    expect(r.missingPositions).toEqual([2, 3]);
  });

  it("is not ready for an empty board", () => {
    expect(deriveRenderReadiness([])).toEqual({ ready: false, missingPositions: [] });
  });
});

describe("useStoryboardRender", () => {
  it("exposes readiness derived from scenes", async () => {
    const { result } = renderHook(
      () => useStoryboardRender("sb1", [scene(1, "ready"), scene(2, "empty")]),
      { wrapper }
    );
    await waitFor(() => expect(result.current.render.isPending).toBe(false));
    expect(result.current.readiness.ready).toBe(false);
    expect(result.current.readiness.missingPositions).toEqual([2]);
  });
});
```

**Verify:** `cd web && bun test src/hooks/storyboard/useStoryboardRender.test.tsx && bun run build`

**Commit:** `feat(web): storyboard render hook + readiness derivation + rendering poll`

---

## Task 4 — Assembly view (transition picker + Render button + player + download)

**Files:** `src/app/(canvas)/brands/[id]/studio/storyboard/[storyboardId]/components/AssemblyPanel.tsx` (new); wire it into the board editor `[storyboardId]/page.tsx` (edit).

**Props:**

```ts
type AssemblyPanelProps = {
  storyboard: Storyboard;
  scenes: Scene[];
};
```

**Step 4a — AssemblyPanel** (`AssemblyPanel.tsx`), built with frndos components:

- **Transition picker:** `SegmentedControl`/`RadioButton` (frndos) with two options — `Cut` (default) and `Crossfade` — held in local `useState<"cut" | "crossfade">("cut")`.
- **Render button** (`Button` from frndos): `disabled={!readiness.ready || render.isPending || storyboard.render_status === "rendering"}`. Label: `render_status === "rendering"` → "Rendering…" (with a spinner); `final_video_url` present → "Re-render"; else "Render video". `onClick` → `render.mutate({ transition })`.
- **Helper text** (below the button, using a design token `text-textSmRegular text-text-secondary`) shown only when `!readiness.ready`: e.g. `Add a clip to scene {n}, {m} before rendering.` built from `readiness.missingPositions` (1-based scene numbers). When `readiness.ready`, no helper text.
- **Status region** driven by `storyboard.render_status`:
  - `rendering` → a `Skeleton`/spinner + "Stitching your clips…" (the Task 3b poll flips it automatically).
  - `ready` + `final_video_url` → a `<video src={storyboard.final_video_url} controls className="w-full rounded-lg" />` player, plus a **Download** action.
  - `failed` → error text ("Render failed — try again") + the Render button re-enabled for a retry.
  - `idle` → just the picker + Render button.
- **Download action:** a `Button`/`CopyButton`-style control that triggers a download of `final_video_url`. Implement as an `<a href={final_video_url} download>` styled as a frndos `Button` (anchor variant) so no blob fetch is needed; `onClick` fires `trackStoryboardRenderDownloaded({ storyboard_id })`.
- On a successful render completion (transition `render_status` `rendering` → `ready`, detected via a `useEffect` watching `storyboard.render_status`), fire `trackStoryboardRenderCompleted({ storyboard_id, transition: storyboard.render_transition ?? "cut" })` once (guard with a `useRef` so it fires a single time per completion).

Wire the hook:

```tsx
const { render, readiness } = useStoryboardRender(storyboard.id, scenes);
```

Use only design tokens for text; wrap nothing in `BaseLayout` (the panel sits inside the existing `(canvas)` board editor shell).

**Step 4b — mount in the board editor** (`[storyboardId]/page.tsx`): render `<AssemblyPanel storyboard={storyboard} scenes={scenes} />` as a panel/tab of the board (e.g. a right-rail section or a "Assemble" tab via the existing `TabsRounded` used for cast/board). Pass the already-loaded `storyboard` + `scenes` from `useStoryboard(id)` — no extra fetch.

**Verify:** `cd web && bun run build`

**Commit:** `feat(web): storyboard assembly panel (transition picker + render + player + download)`

---

## Task 5 — Final verification + lint/format

**Files:** none (verification only).

**Steps:**
1. `cd web && bun lint:fix && bun format`
2. `cd web && bun test src/hooks/storyboard/useStoryboardRender.test.tsx src/lib/analytics/storyboard-events.test.ts`
3. `cd web && bun run build` — MUST pass (the real gate).
4. Manual smoke (dev, flag forced ON): open a storyboard where every scene has a `ready` clip → assembly panel → Render enabled → pick `crossfade` → Render → observe `render_status: rendering` (spinner via poll) → `ready` → `<video>` plays `final_video_url` → Download works. Then delete a clip so a scene is not ready → Render disabled + helper text lists the missing scene number(s). Trigger a re-render to confirm overwrite.
5. Verify the `storyboard_render_*` events land in PostHog Live Events with base-context props.

**Commit:** `chore(web): lint/format + storyboard phase-3 verification`

---

## Out of scope (Phase 3 web)

- Per-scene trims, audio mixing, overlays beyond stitch transitions.
- Generative-bridge / video-model transitions (future enhancement).
- Any api / ai-service work (separate per-service plans).
