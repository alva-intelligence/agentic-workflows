# KV Agentic Canvas P1 — web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the KV chat agent's canvas runs in the KV chat — labelled tool chips, a run card (applied / skipped / detached, focus a target, Undo run) that survives reload — behind the `kv-agentic-canvas` flag, with PostHog events.

**Architecture:** `useKvStream` learns the `kv_agent_run` SSE frame (C4) and marks the turn's assistant message with `metadata.agentRun = { runId, live }`; the same field is rebuilt from `chat_history[].agent_run_id` on reload. `KvChat` renders a new `KvAgentRunCard` under that message when the layout says the flag is on; the card reads `GET v1/studio/files/{file}/agent/runs/{run}` (C5) with TanStack Query and undoes through the matching `POST …/undo`. Agent edits reach the canvas as remote Y updates (nothing to apply client-side); two small canvas-side fixes make them visible: tile Textboxes repaint their text, and detached size tiles (REST rows) are refetched.

**Tech Stack:** Next.js 16, React 19, TypeScript, Tailwind (surface tokens), TanStack Query v5, Fabric v7, posthog-js, `bun test` (bun 1.3.2 + jsdom preload).

**Spec:** `docs/superpowers/specs/2026-09-29-kv-agentic-canvas-design.md` (§4.2, §6, §8.2, §9, §12 P1). **Binding contracts:** `docs/superpowers/plans/2026-09-29-kv-agentic-canvas-p1-contracts.md` (C4 frame `kv_agent_run`, C5 user routes, C7 flag). Every name/route/field from those two is used verbatim.

**Repo:** `web/` (`alva-intelligence/frnd-web`), branch `feature/daffa/vc-kv-agentic-canvas` cut from `develop`. All paths below are relative to `web/`.

**How this plan was made:** every test in this plan was run against a prototype of the implementation in a scratch worktree of `develop` @ `d37a71ee1`, and each was **mutation-checked** (the behaviour it names was removed and the test went red). Numbers and strings in assertions are therefore observed, not reasoned. If `develop` has moved, re-run each test red→green anyway.

## Global Constraints

- Tests run with `bun test <file>` — ONE file (or an explicit short list of files) per invocation. Never a directory (a directory run of kv-generator blew up to ~26 GB), never `bunx vitest`.
- In component tests query through `within(document.body)`, never RTL's `screen`.
- No new `mock.module` / `vi.mock` registrations except the three in `src/hooks/useKvStream.agentRun.test.ts`, which must stay **shape-identical** to `src/hooks/useKvStream.test.ts` (same specifiers, same factories). Everything else is injected (`api` prop) or spied (`spyOn(axiosInstance, …)`, `spyOn(posthog, "capture")`).
- Every test file stays well under 51 KB (bun's transpiler cliff at ~51,150 bytes reports a bogus SCSS error). The largest file in this plan is ~10 KB.
- There is NO type gate: `next build` ignores type errors and `tsc --noEmit` has a ~890-line baseline. The type check is a baseline diff of the files this plan touches (Task 9).
- Build with `node ./node_modules/next/dist/bin/next build`, never `bun run build`. A fresh worktree needs its own `bun install` and a copied `.env.local`.
- Colours: surface/text/border tokens only (`bg-surface-raised`, `bg-surface-overlay`, `border-border-default`, `text-text-inverse*`, `text-positive-400`, `text-warning-400`). No new hex or `rgba(…)` arbitrary values.
- Analytics: typed `track*` helpers in `src/lib/analytics/kv-agent-events.ts` (no inline `posthog.capture`), snake_case props, no hand-passed user/workspace/brand context, fire on the interaction/outcome, never in render.
- Do NOT touch `src/lib/kv/yjsBinding.ts` or any Y.UndoManager wiring. Agent writes are remote updates and are deliberately not on the ⌘Z stack (spec §8.2).
- Contract names are fixed: frame `kv_agent_run {run_id}`; history field `agent_run_id`; routes `v1/studio/files/{file}/agent/runs/{run}` and `…/undo`; flag key `kv-agentic-canvas`; tool names `get_kv_canvas`, `update_kv_layers`, `add_kv_layer`, `remove_kv_layers`, `undo_kv_agent_run`.
- Undo confirmation copy names that credits already spent are not refunded, kept generic (P1 spends none).

## Review Focus

1. **A run that never leaves `running`** (turn aborted, api never saw `done`): the card must stop polling. Pinned in Task 5 (`agentRunRefetchInterval` stops after 30 reads).
2. **A tool result that is not JSON** (ai-service can fall back to a Python repr string): the chip must still read "Updating Layers" and must not show the raw tool name as its detail. Pinned in Task 2.
3. **Undo refused because ANOTHER run holds the file lock** (409 `run_in_progress` from C3.7/C8.1): the toast must not claim the clicked run is still working. Pinned in Task 5 (generic "still working on this canvas" copy asserted).
4. **A focus target whose board or size no longer exists**: the retry must give up quietly after its frame budget instead of looping. Pinned in Task 8 (`retryEachFrame` gives up after `maxFrames`).
5. **A deleted target that comes back with an empty `target_label`**: rows must never render blank. Pinned in Task 3 (mapper falls back to "A board" / "A size").

## Grounding (read-only verification — no task needed unless stated)

**Frame order.** ai-service emits `message` then (C4) `kv_agent_run` then `done` (`ai-service/app/agents/kv_generator/service.py:233-242` — mode runners yield their `MessageEvent`, `DoneEvent` is last). api persists the assistant row and relays `kv_message {chat_message_id}` while handling `message` (`api/app/Services/ChatService.php:1917-1958`), so on web `kv_message` has already finalized the bubble and nulled `streamingMessageIdRef`/`lastStreamedMessageIdRef` when `kv_agent_run` arrives. Task 1 therefore records the finalized id in a per-turn ref.

**Chips.** The KV relay emits tool frames as `type: "tool_usage"` (api `ChatService.php:1960-1985`, web `useKvStream.ts:152-165`), not `tool_call`. ai-service's `_tool_name_slug` maps only five known tools and passes every other name through raw (`service.py:2078-2093`), and uses `tool_args.action || query || tool_name` as the action (`service.py:1795-1805`). So canvas chips arrive as `tool_display_name: "update_kv_layers"`, `tool_action: "update_kv_layers"`. `ToolUsageIndicators` labels unmapped tools with `tool_display_name` (`src/components/chat/ToolUsageIndicators.tsx:509-513`). Task 2 relabels where frames enter the hook.

**Remote Y updates reach the canvas (verified with citations).**
- Store/Layers panel: `KvGeneratorLayout.tsx:1445-1461` projects `doc.overlays.observeDeep(project)` with no origin filter ("projection must re-run for REMOTE edits", `:1464-1468`); `useKvOverlaysStore.projectFromDoc` (`src/store/kv/useKvOverlaysStore.ts:119-162`) replaces changed rows.
- Fabric, Craft boards: `yjsBinding.ts:518-525, 544-545` skip only `YDOC_ORIGIN_LOCAL`; the store path feeds `overlays` → `KvCanvas` (`:1868`) → `useOverlayReconcile`, whose geometry effect depends on `allOverlays` (`fabric/useOverlayReconcile.ts:820-831`) and whose style effect re-applies `payload.content` via `overlayStyleSig` (`:959-978`). Board text, colour, rect, add and remove all repaint.
- Inheriting size tiles: `KvCanvas.tsx:746-773` re-projects `restOverlays` from the live store `overlays` (deps `[strip, boards, boardMetrics, overlays]`) through `resolveTileOverlays` (`src/lib/studio/kv/overlayAspect.ts:633`), so a board edit re-projects every inheriting tile without reload.
- **Gap found → Task 7.** The font/style/fill syncs loop the DOC `overlays` only (`useOverlayReconcile.ts:847-850, 879-882`, param doc at `:50-53`), and the geometry reconcile's existing-Textbox branch (`:382-440`) restyles everything except the string. A tile Textbox therefore kept its OLD text after its board's headline changed — confirmed by a failing test before the fix ("Expected: Diskon 50% / Received: Promo Ramadan"). This is exactly the P1 demo ("change the headline on every size"), and it also affects plain local edits.
- **Gap found → Task 5.** Detached size tiles are REST rows (`KvResizeExport.overlays`), not doc data; the api writes them server-side (spec §7.2) and nothing pushes that to the browser (the resize SSE only opens while a tile is rendering, `src/lib/studio/kv/useResizeExports.ts:139`; the app QueryClient has `refetchOnWindowFocus: false`, `staleTime` 5 min, `src/lib/queryClient.ts:79-83`). The run card invalidates `resizeExportsQueryKey(fileId)` (`useResizeExports.ts:65-79`) once for a live run that touched sizes, and again after an undo.
- The browser's full-replace overlay autosave re-fires on remote changes (`src/hooks/useDebouncedOverlaySave.ts:216-217`, fed at `KvGeneratorLayout.tsx:4494-4503`) — accepted by spec §7.1; no change.

**Focus.** `KvFocusApi.focusBoard(id, at?)` CENTRES a surface and matches `id` or `version_ids` (`KvFabricCanvas.tsx:1525-1547`). Size tiles are Fabric surfaces whose id IS the `KvResizeExport` id (`src/components/studio/kv-generator/resizeStrip.ts:93-95`), and they live on the Craft canvas only (the Resize tab is retired: `src/lib/studio/kv/seedCanvasMode.ts:1`, `KvCanvas.tsx:682-685`). Comment navigation already focuses tiles with `focusBoard(rowId)` (`KvGeneratorLayout.tsx:3772-3782`). `handleCanvasModeChange` refuses mid-stream (`:5036-5043`) and a surface only exists after the switch re-renders and the strip lays out, so focus retries per frame (Task 8). `onNavigateToBoard` (`:8405-8423`) is the model for switching mode + pinning a board.

**Flag hook.** Fail-closed KV experimental flags are read in the layout as `useExperimentalFeatureEnabled(MAJOR_FEATURE_FLAGS.X) === true` (`KvGeneratorLayout.tsx:4155-4168`), which ORs workspace Labs enrollment exactly like the api's `feature.flag` middleware (`api/app/Http/Middleware/FeatureFlag.php`). The layout resolves the flag and passes a boolean down, so no test needs to mock PostHog flags.

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `src/hooks/useKvStream.ts` | modify | `kv_agent_run` frame → `metadata.agentRun`; `agent_run_id` hydration; chip relabel at the two entry points |
| `src/hooks/useKvStream.agentRun.test.ts` | create | frame attach, turn isolation, hydration, chip labels |
| `src/types/studio.ts` | modify | `chat_history[].agent_run_id` on `StudioFile` |
| `src/lib/studio/kv/kvAgentToolLabels.ts` (+ `.test.ts`) | create | canvas tool names → human labels + result detail line |
| `src/types/kv/agentRun.ts` | create | domain types, focus target, query key |
| `src/services/kv/api.ts` | modify | `getKvAgentRun`, `undoKvAgentRun`, wire mapper |
| `src/services/kv/agentRun.api.test.ts` | create | routes, mapping, envelope, label fallback |
| `src/lib/studio/kv/kvAgentRunCopy.ts` (+ `.test.ts`) | create | reason text, grouping, summary, undo line, confirm copy |
| `src/lib/analytics/kv-agent-events.ts` | create | `kv_agent.*` typed helpers |
| `src/components/studio/kv-generator/KvAgentRunCard.tsx` (+ `.test.tsx`) | create | the run card |
| `src/components/studio/kv-generator/KvChat.tsx` | modify | render the card under its message behind `agentRunCardsEnabled` |
| `src/components/studio/kv-generator/KvChat.agentRun.test.tsx` | create | flag on/off + reload through the real KvChat |
| `src/components/studio/kv-generator/fabric/useOverlayReconcile.ts` | modify | repaint a tile Textbox's text |
| `src/components/studio/kv-generator/fabric/useOverlayReconcile.tileText.test.ts` | create | tile text repaint + inline-edit guard |
| `src/lib/studio/kv/kvAgentFocus.ts` (+ `.test.ts`) | create | focus plan (mode/pin/surface) + per-frame retry |
| `src/lib/featureFlags/constants.ts` | modify | `KV_AGENTIC_CANVAS: "kv-agentic-canvas"` |
| `src/components/studio/kv-generator/KvGeneratorLayout.tsx` | modify | resolve flag, `handleFocusAgentTarget`, pass both to `KvChat` |

---

### Task 1: `kv_agent_run` frame and reload hydration in `useKvStream`

**Files:**
- Modify: `src/hooks/useKvStream.ts` (meta type `:31-104`, `ApiFrame` `:139-201`, `Props.initialMessages` `:314-334`, `hydrateInitialMessages` `:345-547`, refs `:601`, `finalizeMessage` `:757-795`, `handleFrame` `:890-1134`, `send` reset `:1278-1282`)
- Modify: `src/types/studio.ts:294-309` (`StudioFile.chat_history` item)
- Create: `src/hooks/useKvStream.agentRun.test.ts`

**Interfaces:**
- Consumes: C4 SSE frame `{ type: "kv_agent_run", run_id: string }`; C4 history field `chat_history[].agent_run_id: string | null` (assistant rows, from `GET v1/studio/files/{id}`).
- Produces: `ChatMessageMeta.agentRun?: { runId: string; live: boolean }` — `live: true` from the frame, `false` from hydration. `hydrateInitialMessages` input rows accept `agent_run_id?: string | null`. `StudioFile.chat_history[]` gains `agent_run_id?: string | null`.

- [ ] **Step 1: Create the branch**

```bash
cd web
git checkout develop && git pull origin develop
git checkout -b feature/daffa/vc-kv-agentic-canvas
```

If you work in a worktree instead, run `bun install` inside it and `cp ../.env.local .env.local` (paths relative to the worktree) before any build or dev server.

- [ ] **Step 2: Write the failing test**

Create `src/hooks/useKvStream.agentRun.test.ts`:

```ts
/*
 * KV agentic canvas (P1, contract C4): the `kv_agent_run` frame and the
 * reload path that rebuilds the run card from `chat_history[].agent_run_id`.
 *
 * The three mocks mirror useKvStream.test.ts EXACTLY (same specifiers, same
 * factory shapes): bun's module registry is process-global, so a divergent
 * factory here would change what the sibling suites see.
 */
vi.mock("@/services/sseClient", () => ({
  sseRequest: vi.fn(async () => undefined),
}));
vi.mock("@/services/axios", () => ({
  getValidAccessToken: vi.fn(async () => "test-token"),
}));
vi.mock("@/lib/session", () => ({
  getSession: () => ({ accessToken: "test-token" }),
}));

import { describe, expect, it, vi } from "vitest";
import { act, renderHook } from "@testing-library/react";
import { sseRequest } from "@/services/sseClient";
import { hydrateInitialMessages, useKvStream } from "./useKvStream";

async function sendAndCapture(
  result: { current: ReturnType<typeof useKvStream> },
  prompt: string
): Promise<(frame: unknown) => void> {
  await act(async () => {
    await result.current.send(prompt, { mode: "chat", canvasMode: "craft" });
  });
  const calls = (sseRequest as unknown as ReturnType<typeof vi.fn>).mock.calls;
  const last = calls.at(-1)?.[0] as
    | { onFrame?: (frame: unknown) => void }
    | undefined;
  if (!last?.onFrame) throw new Error("sseRequest was not called with onFrame");
  return last.onFrame;
}

function mount() {
  return renderHook(() =>
    useKvStream({ fileId: "f1", enabled: true, initialGenerations: [] })
  );
}

describe("kv_agent_run frame", () => {
  it("attaches the run to the assistant message kv_message settled, under its server id", async () => {
    const { result } = mount();
    const onFrame = await sendAndCapture(result, "change the headline");
    act(() => {
      onFrame({ type: "kv_message_delta", chunk: "Done — ", full_content: "Done — " });
      onFrame({ type: "kv_message", text: "Done — headline changed.", chat_message_id: "901" });
      onFrame({ type: "kv_agent_run", run_id: "01JRUN" });
    });
    const owner = result.current.messages.find((m) => m.id === "901");
    expect(owner?.metadata?.agentRun).toEqual({ runId: "01JRUN", live: true });
    // Exactly one message carries it — the user bubble does not.
    expect(
      result.current.messages.filter((m) => m.metadata?.agentRun)
    ).toHaveLength(1);
  });

  it("attaches to the NEW turn's message, never to the previous turn's", async () => {
    const { result } = mount();
    let onFrame = await sendAndCapture(result, "first");
    act(() => {
      onFrame({ type: "kv_message", text: "First reply.", chat_message_id: "801" });
    });
    onFrame = await sendAndCapture(result, "second");
    act(() => {
      onFrame({ type: "kv_message", text: "Second reply.", chat_message_id: "802" });
      onFrame({ type: "kv_agent_run", run_id: "01JRUN2" });
    });
    const byId = (id: string) => result.current.messages.find((m) => m.id === id);
    expect(byId("801")?.metadata?.agentRun).toBeUndefined();
    expect(byId("802")?.metadata?.agentRun).toEqual({ runId: "01JRUN2", live: true });
  });

  it("pushes its own assistant row when the turn produced no message (not the previous turn's)", async () => {
    const { result } = mount();
    let onFrame = await sendAndCapture(result, "first");
    act(() => {
      onFrame({ type: "kv_message", text: "First reply.", chat_message_id: "801" });
    });
    onFrame = await sendAndCapture(result, "quiet turn");
    const before = result.current.messages.length;
    act(() => {
      onFrame({ type: "kv_agent_run", run_id: "01JRUN3" });
    });
    expect(result.current.messages).toHaveLength(before + 1);
    const last = result.current.messages.at(-1);
    expect(last?.role).toBe("assistant");
    expect(last?.metadata?.agentRun).toEqual({ runId: "01JRUN3", live: true });
    expect(
      result.current.messages.find((m) => m.id === "801")?.metadata?.agentRun
    ).toBeUndefined();
  });

  it("ignores a frame without a run id", async () => {
    const { result } = mount();
    const onFrame = await sendAndCapture(result, "x");
    act(() => {
      onFrame({ type: "kv_message", text: "Reply.", chat_message_id: "701" });
      onFrame({ type: "kv_agent_run" });
      onFrame({ type: "kv_agent_run", run_id: "" });
    });
    expect(
      result.current.messages.some((m) => m.metadata?.agentRun)
    ).toBe(false);
  });
});

describe("hydrateInitialMessages — agent_run_id", () => {
  it("rebuilds the run card on reload as a NOT-live run, keeping tools", () => {
    const [m] = hydrateInitialMessages([
      {
        id: "901",
        role: "assistant",
        text: "Done — headline changed.",
        tools: [
          { tool_call_id: "c1", tool_display_name: "update_kv_layers", status: "completed", order: 0 },
        ],
        agent_run_id: "01JRUN",
      },
    ]);
    expect(m.metadata?.agentRun).toEqual({ runId: "01JRUN", live: false });
    expect(m.metadata?.tools).toHaveLength(1);
  });

  it("carries the run on a row with no tools, and nothing when the id is absent or empty", () => {
    const rows = hydrateInitialMessages([
      { id: "1", role: "assistant", text: "a", agent_run_id: "01JRUN" },
      { id: "2", role: "assistant", text: "b", agent_run_id: null },
      { id: "3", role: "assistant", text: "c", agent_run_id: "" },
      { id: "4", role: "assistant", text: "d" },
    ]);
    expect(rows[0].metadata?.agentRun).toEqual({ runId: "01JRUN", live: false });
    expect(rows.slice(1).map((r) => r.metadata)).toEqual([undefined, undefined, undefined]);
  });
});
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bun test src/hooks/useKvStream.agentRun.test.ts`
Expected: FAIL — 3 of the 4 `kv_agent_run frame` tests fail (no message carries `agentRun`) and both hydration tests fail (`metadata?.agentRun` is `undefined`). "ignores a frame without a run id" already passes; it guards the check you are about to add.

- [ ] **Step 4: Implement**

In `src/hooks/useKvStream.ts`:

(a) Extend `ChatMessageMeta` — replace the closing of the `modeDivider` field:

```ts
  modeDivider?: {
    to: "sketch" | "craft";
    persona: string;
  };
};
```

with:

```ts
  modeDivider?: {
    to: "sketch" | "craft";
    persona: string;
  };
  /** KV agentic canvas (P1): the turn wrote to the canvas through the api's
   *  canvas tools, and this message owns the run card. `live` is true when
   *  the id arrived on this session's `kv_agent_run` frame, false when it was
   *  rehydrated from `chat_history[].agent_run_id` — the card fires
   *  `kv_agent.run_completed` only for live runs, never on reload. */
  agentRun?: {
    runId: string;
    live: boolean;
  };
};
```

(b) Add the frame to `ApiFrame`, directly before the final catch-all member `| { type: string; [k: string]: unknown };`:

```ts
  // KV agentic canvas (contract C4): emitted once, after `kv_message` and
  // before `complete`, only when a canvas write tool was accepted this turn.
  | { type: "kv_agent_run"; run_id: string }
```

(c) In `Props.initialMessages` item type, after the `blocks?: ContentBlock[];` member (the one documented "User-only: structured block payload…", `:328-332`), add:

```ts
    /** Assistant-only: the KV agent run this turn wrote (contract C4). */
    agent_run_id?: string | null;
```

and in `hydrateInitialMessages`'s parameter item type, after the `editing_board?: {…} | null;` member, add:

```ts
    agent_run_id?: string | null;
```

(d) In `hydrateInitialMessages`, replace the final plain-assistant return:

```ts
    return {
      id: m.id,
      role: m.role,
      text: m.text,
      metadata: tools.length > 0 ? { streaming: false, tools } : undefined,
    };
```

with:

```ts
    const agentRunId =
      typeof m.agent_run_id === "string" && m.agent_run_id !== ""
        ? m.agent_run_id
        : null;
    return {
      id: m.id,
      role: m.role,
      text: m.text,
      metadata:
        tools.length > 0 || agentRunId
          ? {
              streaming: false,
              ...(tools.length > 0 ? { tools } : {}),
              ...(agentRunId
                ? { agentRun: { runId: agentRunId, live: false } }
                : {}),
            }
          : undefined,
    };
```

(e) After `const lastStreamedMessageIdRef = useRef<string | null>(null);` (`:601`) add:

```ts
  // The assistant message `finalizeMessage` settled THIS turn (its final,
  // server-issued id). `kv_agent_run` arrives after `kv_message` has already
  // nulled both refs above, so this is how the run card finds its message.
  // Reset at every send so a turn can never attach to the previous turn.
  const turnAssistantIdRef = useRef<string | null>(null);
```

(f) In `finalizeMessage`, right after

```ts
      const id =
        streamingMessageIdRef.current ?? lastStreamedMessageIdRef.current;
```

add

```ts
      // Resolved OUTSIDE the updater (StrictMode runs it twice) so the id
      // recorded for `kv_agent_run` is exactly the id the list ends up with.
      const settledId = chatMessageId ?? id ?? genId();
      turnAssistantIdRef.current = settledId;
```

and in the same function's append branch replace `id: chatMessageId ?? genId(),` with `id: settledId,`.

(g) After `finalizeMessage`'s `useCallback(...)` closes (right before `const pushAssistantMessage = useCallback(`), add:

```ts
  /** Mark the turn's assistant message as the owner of a KV agent run.
   *  Prefers a still-streaming bubble (frame arrived before `kv_message`),
   *  then the message this turn finalized, and only pushes an empty
   *  assistant row when the turn produced no message at all. */
  const attachAgentRun = useCallback((runId: string) => {
    const targetId =
      streamingMessageIdRef.current ?? turnAssistantIdRef.current;
    const pushedId = genId();
    setMessages((prev) => {
      const idx = targetId ? prev.findIndex((m) => m.id === targetId) : -1;
      if (idx >= 0) {
        const next = prev.slice();
        next[idx] = {
          ...next[idx],
          metadata: {
            ...next[idx].metadata,
            agentRun: { runId, live: true },
          },
        };
        return next;
      }
      return [
        ...prev,
        {
          id: pushedId,
          role: "assistant",
          text: "",
          metadata: { agentRun: { runId, live: true } },
        },
      ];
    });
  }, []);
```

(h) In `handleFrame`'s switch, directly before `case "start":`, add:

```ts
        case "kv_agent_run": {
          const runId = (frame as { run_id?: unknown }).run_id;
          if (typeof runId === "string" && runId !== "") attachAgentRun(runId);
          break;
        }
```

and add `attachAgentRun,` as the first entry of `handleFrame`'s dependency array.

(i) In `send`, in the per-turn reset block

```ts
      abortRef.current?.abort();
      streamingMessageIdRef.current = null;
      lastStreamedMessageIdRef.current = null;
      const controller = new AbortController();
```

insert `turnAssistantIdRef.current = null;` right before `const controller = new AbortController();`.

In `src/types/studio.ts`, inside `StudioFile.chat_history`'s item type, after `payload?: Record<string, unknown> | null;` add:

```ts
    /** Assistant rows: the KV agent run this turn wrote (contract C4). */
    agent_run_id?: string | null;
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bun test src/hooks/useKvStream.agentRun.test.ts`
Expected: PASS (6 tests).

Prove non-vacuity once (then restore): (1) delete the `turnAssistantIdRef.current = null;` line in `send` → "pushes its own assistant row … (not the previous turn's)" fails; (2) change `streamingMessageIdRef.current ?? turnAssistantIdRef.current` to `streamingMessageIdRef.current` → the first two frame tests fail; (3) change `live: true` in `attachAgentRun`'s patch branch to `live: false` → the first two frame tests fail. These are the mutations the plan author ran.

- [ ] **Step 6: Run the sibling suites together**

The three mocks are process-global; confirm the new file does not disturb the existing ones.

Run: `bun test src/hooks/useKvStream.test.ts src/hooks/useKvStream.resizeMarker.test.ts src/hooks/useKvStream.agentRun.test.ts`
Expected: PASS (26 tests), and no `N error` line in the summary (bun reports a file that died at import as an error line, not as failed tests).

- [ ] **Step 7: Commit**

```bash
git add src/hooks/useKvStream.ts src/hooks/useKvStream.agentRun.test.ts src/types/studio.ts
git commit -m "feat(web): attach KV agent runs to their chat message, live and on reload

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Human labels for the canvas tool chips

**Files:**
- Create: `src/lib/studio/kv/kvAgentToolLabels.ts`
- Create: `src/lib/studio/kv/kvAgentToolLabels.test.ts`
- Modify: `src/hooks/useKvStream.ts` (imports `:16`, hydration tool map `:520-541`, `tool_usage` case `:893-915`)
- Modify: `src/hooks/useKvStream.agentRun.test.ts` (append a describe block)

**Interfaces:**
- Consumes: `ToolUsageData` from `@/store/useChatStore`; C3.2 / C3.3 / C3.7 result shapes (as `tool_result`).
- Produces: `KV_AGENT_TOOL_LABELS`, `kvAgentToolName(displayName): KvAgentToolName | null`, `describeKvAgentToolResult(name, rawResult): string | null`, `labelKvAgentTool(tool: ToolUsageData): ToolUsageData` (returns the same object for non-canvas tools).

Labels follow ai-service's `TOOL_NAME_ENUM` style (Title Case gerunds: "Generating Image", "Viewing Key Visual") — the KV chat's chip copy is English. None of the five labels contains a substring another `ToolUsageIndicators` matcher keys on ("updating agent", "delegat", "skill", "email", "brand iq", …), so they render as the generic row. Spec §9's example "Changing headline · Board A + 3 sizes" needs target names the write result does not carry (C3.3 has ids only); the detail line uses counts instead, and the run card carries the names.

- [ ] **Step 1: Write the failing tests**

Create `src/lib/studio/kv/kvAgentToolLabels.test.ts`:

```ts
import { describe, expect, it } from "bun:test";
import type { ToolUsageData } from "@/store/useChatStore";
import {
  describeKvAgentToolResult,
  kvAgentToolName,
  labelKvAgentTool,
} from "./kvAgentToolLabels";

const chip = (over: Partial<ToolUsageData>): ToolUsageData => ({
  id: "c1",
  tool_display_name: "update_kv_layers",
  status: "completed",
  timestamp: new Date(0),
  ...over,
});

describe("labelKvAgentTool", () => {
  it("gives each canvas tool its human label", () => {
    const labels = [
      "get_kv_canvas",
      "update_kv_layers",
      "add_kv_layer",
      "remove_kv_layers",
      "undo_kv_agent_run",
    ].map((n) => labelKvAgentTool(chip({ tool_display_name: n })).tool_display_name);
    expect(labels).toEqual([
      "Reading Canvas",
      "Updating Layers",
      "Adding Layer",
      "Removing Layers",
      "Undoing Agent Run",
    ]);
  });

  it("drops the raw tool name ai-service uses as a fallback action", () => {
    const out = labelKvAgentTool(
      chip({ status: "started", tool_action: "update_kv_layers", tool_result: null })
    );
    expect(out.tool_action).toBeUndefined();
  });

  it("writes the detail line from a write result (object or JSON string)", () => {
    const result = {
      run_id: "01JRUN",
      applied: [
        { target: "gen_a", layer_id: "L1", op: "set_layer" },
        { target: "exp_1", layer_id: "L1", op: "set_layer" },
        { target: "exp_1", layer_id: "L2", op: "set_layer" },
      ],
      skipped: [{ target: "exp_2", layer_id: "L1", reason: "layer_absent_on_size" }],
      detached_sizes: ["exp_1"],
    };
    expect(labelKvAgentTool(chip({ tool_result: result as never })).tool_action).toBe(
      "Applied to 2 targets · 1 skipped · 1 size detached"
    );
    expect(
      labelKvAgentTool(chip({ tool_result: JSON.stringify(result) as never })).tool_action
    ).toBe("Applied to 2 targets · 1 skipped · 1 size detached");
  });

  it("keeps the label but no detail when the result is not JSON (a Python repr)", () => {
    const out = labelKvAgentTool(
      chip({ tool_action: "update_kv_layers", tool_result: "{'applied': []}" as never })
    );
    expect(out.tool_display_name).toBe("Updating Layers");
    expect(out.tool_action).toBeUndefined();
  });

  it("says nothing was applied when every target was skipped", () => {
    expect(
      describeKvAgentToolResult("remove_kv_layers", {
        applied: [],
        skipped: [{ target: "gen_a", layer_id: "L9", reason: "layer_not_found" }],
        detached_sizes: [],
      })
    ).toBe("Nothing applied · 1 skipped");
  });

  it("summarises the inventory and an undo", () => {
    expect(
      describeKvAgentToolResult("get_kv_canvas", {
        boards: [{ sizes: [{}, {}] }, { sizes: [{}] }],
      })
    ).toBe("2 boards · 3 sizes");
    expect(
      describeKvAgentToolResult("undo_kv_agent_run", {
        status: "undone",
        reverted: 7,
        skipped: [{ reason: "changed_after_run" }],
      })
    ).toBe("Reverted 7 · 1 skipped");
    expect(
      describeKvAgentToolResult("undo_kv_agent_run", {
        status: "already_undone",
        reverted: 0,
        skipped: [],
      })
    ).toBe("Already undone");
  });

  it("leaves every other tool untouched (same object)", () => {
    const web = chip({ tool_display_name: "Searching the Web", tool_action: "q" });
    expect(labelKvAgentTool(web)).toBe(web);
    expect(kvAgentToolName("Generating Image")).toBeNull();
  });
});
```

Append to `src/hooks/useKvStream.agentRun.test.ts`:

```ts
describe("KV canvas tool chips", () => {
  it("labels a live tool_usage frame, started then completed, on one chip", async () => {
    const { result } = mount();
    const onFrame = await sendAndCapture(result, "change the headline");
    act(() => {
      onFrame({ type: "tool_usage", status: "started", tool_call_id: "c1", tool_display_name: "update_kv_layers", tool_action: "update_kv_layers" });
      onFrame({
        type: "tool_usage",
        status: "completed",
        tool_call_id: "c1",
        tool_display_name: "update_kv_layers",
        tool_action: "update_kv_layers",
        tool_result: { run_id: "01JRUN", applied: [{ target: "gen_a", layer_id: "L1", op: "set_layer" }], skipped: [], detached_sizes: [] },
      });
    });
    const tools = result.current.messages.at(-1)?.metadata?.tools ?? [];
    expect(tools).toHaveLength(1);
    expect(tools[0].tool_display_name).toBe("Updating Layers");
    expect(tools[0].tool_action).toBe("Applied to 1 target");
  });

  it("labels a rehydrated chip the same way", () => {
    const [m] = hydrateInitialMessages([
      {
        id: "9",
        role: "assistant",
        text: "Done.",
        tools: [{ tool_call_id: "c1", tool_display_name: "get_kv_canvas", tool_action: "get_kv_canvas", status: "completed", order: 0 }],
      },
    ]);
    expect(m.metadata?.tools?.[0].tool_display_name).toBe("Reading Canvas");
    expect(m.metadata?.tools?.[0].tool_action).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bun test src/lib/studio/kv/kvAgentToolLabels.test.ts`
Expected: FAIL — `Cannot find module './kvAgentToolLabels'`.

Run: `bun test src/hooks/useKvStream.agentRun.test.ts`
Expected: the two `KV canvas tool chips` tests FAIL (`tool_display_name` is still `"update_kv_layers"` / `"get_kv_canvas"`); the 6 Task 1 tests still pass.

- [ ] **Step 3: Implement the label module**

Create `src/lib/studio/kv/kvAgentToolLabels.ts`:

```ts
import type { ToolUsageData } from "@/store/useChatStore";

/**
 * KV agentic canvas (P1) — human chip labels for the canvas tools.
 *
 * ai-service's KV stream labels a tool through `_tool_name_slug`, which only
 * knows web search / image / video / knowledge search and passes every other
 * name through RAW (ai-service/app/agents/kv_generator/service.py). Contract
 * C4 fixes the tool names to the MCP twins, so the chip row would read
 * `update_kv_layers`. The label is applied here, once, where frames enter the
 * KV hook (live `tool_usage` frame and `chat_history[].tools` on reload), so
 * the shared `<ToolUsageIndicators>` needs no KV branch.
 *
 * Title Case gerunds, matching ai-service's TOOL_NAME_ENUM ("Generating
 * Image", "Viewing Key Visual"). None of them contains a substring another
 * matcher in ToolUsageIndicators keys on ("updating agent", "delegat",
 * "skill", "email", ...), so they fall to the generic row.
 */
export const KV_AGENT_TOOL_LABELS = {
  get_kv_canvas: "Reading Canvas",
  update_kv_layers: "Updating Layers",
  add_kv_layer: "Adding Layer",
  remove_kv_layers: "Removing Layers",
  undo_kv_agent_run: "Undoing Agent Run",
} as const;

export type KvAgentToolName = keyof typeof KV_AGENT_TOOL_LABELS;

const LABEL_TO_NAME = new Map<string, KvAgentToolName>(
  (Object.entries(KV_AGENT_TOOL_LABELS) as [KvAgentToolName, string][]).map(
    ([name, label]) => [label, name]
  )
);

/** The tool behind a display name — the raw MCP name, or (if ai-service ever
 *  starts sending our label itself) the label. Null for every other tool. */
export function kvAgentToolName(displayName: string): KvAgentToolName | null {
  if (displayName in KV_AGENT_TOOL_LABELS) return displayName as KvAgentToolName;
  return LABEL_TO_NAME.get(displayName) ?? null;
}

function asObject(raw: unknown): Record<string, unknown> | null {
  if (raw && typeof raw === "object" && !Array.isArray(raw)) {
    return raw as Record<string, unknown>;
  }
  if (typeof raw === "string") {
    try {
      const parsed: unknown = JSON.parse(raw);
      return parsed && typeof parsed === "object" && !Array.isArray(parsed)
        ? (parsed as Record<string, unknown>)
        : null;
    } catch {
      return null;
    }
  }
  return null;
}

const plural = (n: number, one: string, many: string) =>
  `${n} ${n === 1 ? one : many}`;

/** The chip's detail line, from the tool's result (contract C3.2/C3.3/C3.7).
 *  Null when the result is absent or not the expected shape — a started chip,
 *  or a failure whose message the row already shows. */
export function describeKvAgentToolResult(
  name: KvAgentToolName,
  rawResult: unknown
): string | null {
  const r = asObject(rawResult);
  if (!r) return null;
  if (name === "get_kv_canvas") {
    if (!Array.isArray(r.boards)) return null;
    const sizes = r.boards.reduce<number>((n, b) => {
      const s = (b as { sizes?: unknown }).sizes;
      return n + (Array.isArray(s) ? s.length : 0);
    }, 0);
    return `${plural(r.boards.length, "board", "boards")} · ${plural(sizes, "size", "sizes")}`;
  }
  if (name === "undo_kv_agent_run") {
    if (r.status === "already_undone") return "Already undone";
    if (typeof r.reverted !== "number") return null;
    const skipped = Array.isArray(r.skipped) ? r.skipped.length : 0;
    return skipped > 0
      ? `Reverted ${r.reverted} · ${skipped} skipped`
      : `Reverted ${r.reverted}`;
  }
  if (!Array.isArray(r.applied) || !Array.isArray(r.skipped)) return null;
  const targets = new Set(
    r.applied.map((a) => String((a as { target?: unknown }).target ?? ""))
  ).size;
  const parts = [
    r.applied.length > 0
      ? `Applied to ${plural(targets, "target", "targets")}`
      : "Nothing applied",
  ];
  if (r.skipped.length > 0) parts.push(`${r.skipped.length} skipped`);
  const detached = Array.isArray(r.detached_sizes) ? r.detached_sizes.length : 0;
  if (detached > 0) parts.push(`${plural(detached, "size", "sizes")} detached`);
  return parts.join(" · ");
}

/** Relabel a KV canvas tool chip; every other tool passes through untouched
 *  (same object), so web search / image chips keep their existing rows. */
export function labelKvAgentTool(tool: ToolUsageData): ToolUsageData {
  const name = kvAgentToolName(tool.tool_display_name);
  if (!name) return tool;
  const detail = describeKvAgentToolResult(name, tool.tool_result);
  return {
    ...tool,
    tool_display_name: KV_AGENT_TOOL_LABELS[name],
    // ai-service falls back to the raw tool name as the action when the call
    // has no `action`/`query` arg — never show that as the detail line.
    tool_action:
      detail ??
      (tool.tool_action && tool.tool_action !== name ? tool.tool_action : undefined),
  };
}
```

- [ ] **Step 4: Relabel where frames enter the hook**

In `src/hooks/useKvStream.ts`:

Add after `import { maybeTriggerCsatFeedback } from "@/lib/feedback/csat";`:

```ts
import { labelKvAgentTool } from "@/lib/studio/kv/kvAgentToolLabels";
```

In `hydrateInitialMessages`, the tool chain ends with

```ts
          order: typeof obj.order === "number" ? obj.order : undefined,
        };
      })
      .sort((a, b) => (a.order ?? 0) - (b.order ?? 0));
```

— insert `.map(labelKvAgentTool)` between the `})` and `.sort(`:

```ts
          order: typeof obj.order === "number" ? obj.order : undefined,
        };
      })
      .map(labelKvAgentTool)
      .sort((a, b) => (a.order ?? 0) - (b.order ?? 0));
```

In `handleFrame`'s `case "tool_usage":`, wrap the object passed to `recordToolCall` in `labelKvAgentTool(...)`:

```ts
          recordToolCall(
            labelKvAgentTool({
              id,
              tool_display_name: f.tool_display_name,
              status: f.status,
              tool_action: f.tool_action ?? undefined,
              timestamp: new Date(),
              tool_execution_time: f.tool_execution_time ?? null,
              tool_error_message: f.tool_error_message ?? undefined,
              tool_result:
                (f.tool_result as _ToolUsageData["tool_result"]) ?? null,
            })
          );
```

The chip upsert keys on `id`, so the started and completed frames still land on one chip.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bun test src/lib/studio/kv/kvAgentToolLabels.test.ts`
Expected: PASS (7 tests).

Run: `bun test src/hooks/useKvStream.test.ts src/hooks/useKvStream.resizeMarker.test.ts src/hooks/useKvStream.agentRun.test.ts`
Expected: PASS (28 tests), no `N error` line.

Non-vacuity (author-run): removing `.map(labelKvAgentTool)` fails "labels a rehydrated chip the same way"; removing the `labelKvAgentTool(` wrap in the live path fails "labels a live tool_usage frame…".

- [ ] **Step 6: Commit**

```bash
git add src/lib/studio/kv/kvAgentToolLabels.ts src/lib/studio/kv/kvAgentToolLabels.test.ts src/hooks/useKvStream.ts src/hooks/useKvStream.agentRun.test.ts
git commit -m "feat(web): label KV canvas tool chips in the KV chat

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Run types and the C5 API client

**Files:**
- Create: `src/types/kv/agentRun.ts`
- Modify: `src/services/kv/api.ts` (type import block after `:56`, new section appended at the end of the file)
- Create: `src/services/kv/agentRun.api.test.ts`

**Interfaces:**
- Consumes: C5 `GET v1/studio/files/{file}/agent/runs/{run}` (run view) and `POST v1/studio/files/{file}/agent/runs/{run}/undo` (C3.7 body).
- Produces (types, `@/types/kv/agentRun`): `KvAgentRunStatus`, `KvAgentTargetKind = "board" | "size"`, `KvAgentRunApplied`, `KvAgentRunSkipped`, `KvAgentRunUndoSkipped`, `KvAgentRunUndoOutcome { reverted; skipped }`, `KvAgentRun { id, status, source, createdAt, applied, skipped, detachedSizes: {sizeId,label}[], undo: KvAgentRunUndoOutcome | null }`, `KvAgentRunUndoResult extends KvAgentRunUndoOutcome { status: "undone" | "already_undone" }`, `KvAgentFocusTarget { kind: KvAgentTargetKind; id: string }`, `kvAgentRunQueryKey(fileId, runId) => ["kv-agent-run", fileId, runId]`.
- Produces (api, `@/services/kv/api`): `getKvAgentRun(fileId, runId): Promise<KvAgentRun>`, `undoKvAgentRun(fileId, runId): Promise<KvAgentRunUndoResult>`, `toKvAgentRun(w: WireKvAgentRun): KvAgentRun`, `type WireKvAgentRun`.

Conventions followed: KV calls live in `services/kv/api.ts` with a snake_case `Wire*` type and a camelCase mapper (`toImageExpand`, `toBackgroundRemoval`). C5 does not pin the response envelope, so the client accepts Laravel's `{ message, data }` AND a bare body (see Contract deviations, D1).

- [ ] **Step 1: Write the failing test**

Create `src/services/kv/agentRun.api.test.ts` (spies on the shared axios instance — no module mock):

```ts
import { afterEach, describe, expect, it, spyOn } from "bun:test";
import axiosInstance from "@/services/axios";
import { getKvAgentRun, undoKvAgentRun } from "./api";

const WIRE = {
  id: "01JRUN",
  status: "completed",
  source: "app",
  created_at: "2026-09-29T10:00:00Z",
  applied: [
    { target: "gen_a", target_kind: "board", target_label: "Concept A", layer_id: "L1", op: "set_layer" },
  ],
  skipped: [
    { target: "exp_2", target_kind: "size", target_label: "Concept A · Story", layer_id: "L1", reason: "layer_absent_on_size" },
  ],
  detached_sizes: [{ size_id: "exp_1", label: "Concept A · Feed" }],
  undo: null,
};

const spies: Array<{ mockRestore: () => void }> = [];
afterEach(() => spies.splice(0).forEach((s) => s.mockRestore()));

describe("KV agent run api", () => {
  it("GETs the run view from the file-scoped user route and maps it", async () => {
    const get = spyOn(axiosInstance, "get").mockResolvedValue({
      data: { message: "ok", data: WIRE },
    } as never);
    spies.push(get);
    const run = await getKvAgentRun("f1", "01JRUN");
    expect(get).toHaveBeenCalledWith("v1/studio/files/f1/agent/runs/01JRUN");
    expect(run.applied[0]).toEqual({
      target: "gen_a",
      targetKind: "board",
      targetLabel: "Concept A",
      layerId: "L1",
      op: "set_layer",
    });
    expect(run.skipped[0].reason).toBe("layer_absent_on_size");
    expect(run.detachedSizes).toEqual([{ sizeId: "exp_1", label: "Concept A · Feed" }]);
  });

  it("never maps a target to a blank label", async () => {
    spies.push(
      spyOn(axiosInstance, "get").mockResolvedValue({
        data: {
          data: {
            ...WIRE,
            applied: [{ ...WIRE.applied[0], target_label: "" }],
            skipped: [{ ...WIRE.skipped[0], target_label: null }],
          },
        },
      } as never)
    );
    const run = await getKvAgentRun("f1", "01JRUN");
    expect(run.applied[0].targetLabel).toBe("A board");
    expect(run.skipped[0].targetLabel).toBe("A size");
  });

  it("accepts an unwrapped body too", async () => {
    spies.push(spyOn(axiosInstance, "get").mockResolvedValue({ data: WIRE } as never));
    expect((await getKvAgentRun("f1", "01JRUN")).id).toBe("01JRUN");
  });

  it("POSTs undo to the run's undo route exactly once and maps the answer", async () => {
    const post = spyOn(axiosInstance, "post").mockResolvedValue({
      data: {
        data: {
          status: "undone",
          reverted: 3,
          skipped: [{ target: "gen_a", layer_id: "L1", reason: "changed_after_run" }],
        },
      },
    } as never);
    spies.push(post);
    const out = await undoKvAgentRun("f1", "01JRUN");
    expect(post).toHaveBeenCalledTimes(1);
    expect(post).toHaveBeenCalledWith("v1/studio/files/f1/agent/runs/01JRUN/undo");
    expect(out).toEqual({
      status: "undone",
      reverted: 3,
      skipped: [{ target: "gen_a", layerId: "L1", reason: "changed_after_run" }],
    });
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bun test src/services/kv/agentRun.api.test.ts`
Expected: FAIL — `getKvAgentRun` / `undoKvAgentRun` do not exist yet (bun reports the missing export at import, or the calls throw `is not a function`).

- [ ] **Step 3: Create the types**

Create `src/types/kv/agentRun.ts`:

```ts
/**
 * KV agentic canvas (P1) — a run the KV chat agent wrote to the canvas.
 * Domain (camelCase) shape of contract C5's run view; the wire shape and its
 * mapper live in `services/kv/api.ts` next to the calls.
 */
export type KvAgentRunStatus = "running" | "completed" | "undone" | "failed";

export type KvAgentTargetKind = "board" | "size";

export interface KvAgentRunApplied {
  target: string;
  targetKind: KvAgentTargetKind;
  targetLabel: string;
  layerId: string;
  op: "set_layer" | "add_layer" | "remove_layer";
}

export interface KvAgentRunSkipped {
  target: string;
  targetKind: KvAgentTargetKind;
  targetLabel: string;
  layerId: string | null;
  /** Contract C3.3 reason code (`layer_changed`, `layer_absent_on_size`, …). */
  reason: string;
}

/** Contract C3.7 undo `skipped` entry. */
export interface KvAgentRunUndoSkipped {
  target: string;
  layerId: string | null;
  reason: string;
}

export interface KvAgentRunUndoOutcome {
  reverted: number;
  skipped: KvAgentRunUndoSkipped[];
}

export interface KvAgentRun {
  id: string;
  status: KvAgentRunStatus;
  source: "app" | "mcp";
  createdAt: string;
  applied: KvAgentRunApplied[];
  skipped: KvAgentRunSkipped[];
  detachedSizes: Array<{ sizeId: string; label: string }>;
  /** Null until the run has been undone. */
  undo: KvAgentRunUndoOutcome | null;
}

/** Contract C3.7 — the undo route's answer. */
export interface KvAgentRunUndoResult extends KvAgentRunUndoOutcome {
  status: "undone" | "already_undone";
}

/** A board or size the run card can bring into view on the canvas. */
export interface KvAgentFocusTarget {
  kind: KvAgentTargetKind;
  id: string;
}

export const kvAgentRunQueryKey = (fileId: string, runId: string) =>
  ["kv-agent-run", fileId, runId] as const;
```

- [ ] **Step 4: Add the calls**

In `src/services/kv/api.ts`, after `import type { KvResizeTileUpscale } from "@/types/kv/resize-tile-upscale";` add:

```ts
import type {
  KvAgentRun,
  KvAgentRunApplied,
  KvAgentRunUndoResult,
  KvAgentRunUndoSkipped,
  KvAgentTargetKind,
} from "@/types/kv/agentRun";
```

Append at the end of the file:

```ts
// ── KV agentic canvas — agent runs (contract C5) ────────────────────────────

export type WireKvAgentRun = {
  id: string;
  status: KvAgentRun["status"];
  source: KvAgentRun["source"];
  created_at: string;
  applied: Array<{
    target: string;
    target_kind: KvAgentTargetKind;
    target_label: string | null;
    layer_id: string;
    op: KvAgentRunApplied["op"];
  }>;
  skipped: Array<{
    target: string;
    target_kind: KvAgentTargetKind;
    target_label: string | null;
    layer_id: string | null;
    reason: string;
  }>;
  detached_sizes: Array<{ size_id: string; label: string }>;
  undo: {
    reverted: number;
    skipped: Array<{ target: string; layer_id: string | null; reason: string }>;
  } | null;
};

type WireKvAgentUndoSkipped = {
  target: string;
  layer_id: string | null;
  reason: string;
};

/** A deleted board or size can come back with no label; never render a
 *  blank row. */
const agentTargetLabel = (label: string | null | undefined, kind: KvAgentTargetKind) =>
  label && label.trim() !== "" ? label : kind === "size" ? "A size" : "A board";

const toUndoSkipped = (s: WireKvAgentUndoSkipped): KvAgentRunUndoSkipped => ({
  target: s.target,
  layerId: s.layer_id ?? null,
  reason: s.reason,
});

export function toKvAgentRun(w: WireKvAgentRun): KvAgentRun {
  return {
    id: w.id,
    status: w.status,
    source: w.source,
    createdAt: w.created_at,
    applied: (w.applied ?? []).map((a) => ({
      target: a.target,
      targetKind: a.target_kind,
      targetLabel: agentTargetLabel(a.target_label, a.target_kind),
      layerId: a.layer_id,
      op: a.op,
    })),
    skipped: (w.skipped ?? []).map((s) => ({
      target: s.target,
      targetKind: s.target_kind,
      targetLabel: agentTargetLabel(s.target_label, s.target_kind),
      layerId: s.layer_id ?? null,
      reason: s.reason,
    })),
    detachedSizes: (w.detached_sizes ?? []).map((d) => ({
      sizeId: d.size_id,
      label: d.label,
    })),
    undo: w.undo
      ? {
          reverted: w.undo.reverted,
          skipped: (w.undo.skipped ?? []).map(toUndoSkipped),
        }
      : null,
  };
}

/** Contract C5 does not pin the response envelope. Every KV route here wraps
 *  in Laravel's `{ message, data }`; accept a bare body too so an api that
 *  returns the view unwrapped still renders (neither shape has a `data` key
 *  of its own). */
function unwrapAgentBody<T>(body: unknown): T {
  const b = body as { data?: unknown } | null;
  return (b && typeof b === "object" && "data" in b ? b.data : body) as T;
}

const agentRunPath = (fileId: string, runId: string) =>
  `v1/studio/files/${fileId}/agent/runs/${runId}`;

export async function getKvAgentRun(
  fileId: string,
  runId: string
): Promise<KvAgentRun> {
  const { data } = await axiosInstance.get(agentRunPath(fileId, runId));
  return toKvAgentRun(unwrapAgentBody<WireKvAgentRun>(data));
}

export async function undoKvAgentRun(
  fileId: string,
  runId: string
): Promise<KvAgentRunUndoResult> {
  const { data } = await axiosInstance.post(
    `${agentRunPath(fileId, runId)}/undo`
  );
  const body = unwrapAgentBody<{
    status: KvAgentRunUndoResult["status"];
    reverted: number;
    skipped: WireKvAgentUndoSkipped[];
  }>(data);
  return {
    status: body.status,
    reverted: body.reverted ?? 0,
    skipped: (body.skipped ?? []).map(toUndoSkipped),
  };
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bun test src/services/kv/agentRun.api.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add src/types/kv/agentRun.ts src/services/kv/api.ts src/services/kv/agentRun.api.test.ts
git commit -m "feat(web): KV agent run view + undo API client

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Run card copy — reasons, grouping, summary

**Files:**
- Create: `src/lib/studio/kv/kvAgentRunCopy.ts`
- Create: `src/lib/studio/kv/kvAgentRunCopy.test.ts`

**Interfaces:**
- Consumes: `KvAgentRun`, `KvAgentRunApplied`, `KvAgentRunUndoOutcome`, `KvAgentTargetKind` (Task 3).
- Produces: `kvAgentSkipReasonText(reason)`, `kvAgentUndoSkipReasonText(reason)`, `groupAppliedByTarget(applied): KvAgentAppliedTarget[]` (`{ target, targetKind, targetLabel, layerCount }`, first-seen order, distinct layers), `describeKvAgentRunSummary(run)`, `describeKvAgentUndoOutcome(outcome)`, `KV_AGENT_UNDO_CONFIRM_COPY`.

Every reason code in C3.3 (`layer_changed`, `layer_not_found`, `layer_absent_on_size`, `target_not_found`, `collab_unavailable`, `invalid_payload`, `run_op_cap_reached`) and C3.7 (`changed_after_run`, `layer_not_found`, `collab_unavailable`) gets a sentence; an unknown code reads as words, never snake_case.

- [ ] **Step 1: Write the failing test**

Create `src/lib/studio/kv/kvAgentRunCopy.test.ts`:

```ts
import { describe, expect, it } from "bun:test";
import type { KvAgentRun } from "@/types/kv/agentRun";
import {
  describeKvAgentRunSummary,
  describeKvAgentUndoOutcome,
  groupAppliedByTarget,
  kvAgentSkipReasonText,
  kvAgentUndoSkipReasonText,
} from "./kvAgentRunCopy";

const run = (over: Partial<KvAgentRun> = {}): KvAgentRun => ({
  id: "r1",
  status: "completed",
  source: "app",
  createdAt: "2026-09-29T00:00:00Z",
  applied: [
    { target: "gen_a", targetKind: "board", targetLabel: "Concept A", layerId: "L1", op: "set_layer" },
    { target: "exp_1", targetKind: "size", targetLabel: "Concept A · Story", layerId: "L1", op: "set_layer" },
    { target: "exp_1", targetKind: "size", targetLabel: "Concept A · Story", layerId: "L2", op: "set_layer" },
    { target: "exp_1", targetKind: "size", targetLabel: "Concept A · Story", layerId: "L2", op: "set_layer" },
  ],
  skipped: [],
  detachedSizes: [],
  undo: null,
  ...over,
});

describe("kvAgentRunCopy", () => {
  it("groups applied ops per target, counting distinct layers, first-seen order", () => {
    expect(groupAppliedByTarget(run().applied)).toEqual([
      { target: "gen_a", targetKind: "board", targetLabel: "Concept A", layerCount: 1 },
      { target: "exp_1", targetKind: "size", targetLabel: "Concept A · Story", layerCount: 2 },
    ]);
  });

  it("summarises by target, not by op", () => {
    expect(describeKvAgentRunSummary(run())).toBe("Changed 2 boards and sizes");
    expect(
      describeKvAgentRunSummary(
        run({
          applied: [],
          skipped: [{ target: "exp_2", targetKind: "size", targetLabel: "B", layerId: "L1", reason: "layer_absent_on_size" }],
        })
      )
    ).toBe("Nothing was changed · 1 skipped");
    expect(describeKvAgentRunSummary(run({ status: "running" }))).toBe("Working on the canvas…");
    expect(describeKvAgentRunSummary(run({ status: "failed" }))).toBe(
      "Changed 2 boards and sizes · stopped early"
    );
  });

  it("words every contract reason, and never shows snake_case for an unknown one", () => {
    expect(kvAgentSkipReasonText("layer_absent_on_size")).toBe("this size doesn't have that layer");
    expect(kvAgentUndoSkipReasonText("changed_after_run")).toBe("edited after the run, so it was kept");
    expect(kvAgentSkipReasonText("brand_new_code")).toBe("brand new code");
  });

  it("words the undo outcome", () => {
    expect(describeKvAgentUndoOutcome({ reverted: 3, skipped: [] })).toBe("Undone · 3 reverted");
    expect(
      describeKvAgentUndoOutcome({ reverted: 2, skipped: [{ target: "t", layerId: null, reason: "x" }] })
    ).toBe("Undone · 2 reverted · 1 skipped");
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bun test src/lib/studio/kv/kvAgentRunCopy.test.ts`
Expected: FAIL — `Cannot find module './kvAgentRunCopy'`.

- [ ] **Step 3: Implement**

Create `src/lib/studio/kv/kvAgentRunCopy.ts`:

```ts
import type {
  KvAgentRun,
  KvAgentRunApplied,
  KvAgentRunUndoOutcome,
  KvAgentTargetKind,
} from "@/types/kv/agentRun";

/** Contract C3.3 write-time skip reasons, in the user's words. */
const SKIP_REASON_TEXT: Record<string, string> = {
  layer_changed: "the layer changed before the agent could write it",
  layer_not_found: "that layer no longer exists",
  layer_absent_on_size: "this size doesn't have that layer",
  target_not_found: "this board or size no longer exists",
  collab_unavailable: "the canvas couldn't be reached",
  invalid_payload: "the change isn't valid for this layer",
  run_op_cap_reached: "the run hit its edit limit",
};

/** Contract C3.7 undo-time skip reasons. */
const UNDO_SKIP_REASON_TEXT: Record<string, string> = {
  changed_after_run: "edited after the run, so it was kept",
  layer_not_found: "that layer no longer exists",
  collab_unavailable: "the canvas couldn't be reached",
};

/** An unknown code still reads as words rather than as snake_case. */
const fallbackReason = (reason: string) => reason.replace(/_/g, " ");

export const kvAgentSkipReasonText = (reason: string): string =>
  SKIP_REASON_TEXT[reason] ?? fallbackReason(reason);

export const kvAgentUndoSkipReasonText = (reason: string): string =>
  UNDO_SKIP_REASON_TEXT[reason] ?? fallbackReason(reason);

export interface KvAgentAppliedTarget {
  target: string;
  targetKind: KvAgentTargetKind;
  targetLabel: string;
  layerCount: number;
}

/** One row per target, in first-applied order, counting distinct layers. */
export function groupAppliedByTarget(
  applied: KvAgentRunApplied[]
): KvAgentAppliedTarget[] {
  const rows = new Map<string, KvAgentAppliedTarget & { layers: Set<string> }>();
  for (const a of applied) {
    const row = rows.get(a.target) ?? {
      target: a.target,
      targetKind: a.targetKind,
      targetLabel: a.targetLabel,
      layerCount: 0,
      layers: new Set<string>(),
    };
    row.layers.add(a.layerId);
    row.layerCount = row.layers.size;
    rows.set(a.target, row);
  }
  return [...rows.values()].map(({ layers: _layers, ...row }) => row);
}

const plural = (n: number, one: string, many: string) =>
  `${n} ${n === 1 ? one : many}`;

/** The card's headline: what landed, what did not. */
export function describeKvAgentRunSummary(run: KvAgentRun): string {
  if (run.status === "running") return "Working on the canvas…";
  const targets = groupAppliedByTarget(run.applied).length;
  const parts = [
    targets > 0
      ? `Changed ${plural(targets, "board or size", "boards and sizes")}`
      : "Nothing was changed",
  ];
  if (run.skipped.length > 0) parts.push(`${run.skipped.length} skipped`);
  if (run.status === "failed") parts.push("stopped early");
  return parts.join(" · ");
}

/** "Undone · 3 reverted · 1 kept" — the line after an undo. */
export function describeKvAgentUndoOutcome(outcome: KvAgentRunUndoOutcome): string {
  const parts = ["Undone", `${outcome.reverted} reverted`];
  if (outcome.skipped.length > 0) parts.push(`${outcome.skipped.length} skipped`);
  return parts.join(" · ");
}

/** Kept generic on purpose: P1 runs spend nothing, later phases do. */
export const KV_AGENT_UNDO_CONFIRM_COPY =
  "Undo this run? Layers the agent changed go back to how they were. Anything edited since the run is left as it is. Credits already spent are not refunded.";
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bun test src/lib/studio/kv/kvAgentRunCopy.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add src/lib/studio/kv/kvAgentRunCopy.ts src/lib/studio/kv/kvAgentRunCopy.test.ts
git commit -m "feat(web): KV agent run card copy helpers

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: `KvAgentRunCard` + `kv_agent.*` analytics

**Files:**
- Create: `src/lib/analytics/kv-agent-events.ts`
- Create: `src/components/studio/kv-generator/KvAgentRunCard.tsx`
- Create: `src/components/studio/kv-generator/KvAgentRunCard.test.tsx`

**Interfaces:**
- Consumes: Task 3 (`getKvAgentRun`, `undoKvAgentRun`, types, `kvAgentRunQueryKey`), Task 4 (copy helpers), `resizeExportsQueryKey(fileId)` from `@/lib/studio/kv/useResizeExports`, `useToastStore`, `Button` from `@/components/frndos/v2`.
- Produces:
  - `KvAgentRunCard({ fileId: string; runId: string; live: boolean; onFocusTarget?: (t: KvAgentFocusTarget) => void; api?: KvAgentRunApi })` — renders `data-testid="kv-agent-run-card"` with `data-run-status`.
  - `type KvAgentRunApi = { getRun(fileId, runId): Promise<KvAgentRun>; undoRun(fileId, runId): Promise<KvAgentRunUndoResult> }` (defaults to the Task 3 calls).
  - `agentRunRefetchInterval(run: KvAgentRun | undefined, reads: number): number | false`.
  - `__resetKvAgentRunCardTracking()` (test seam for the module-level once-per-run guard).
  - Analytics helpers: `trackKvAgentRunCompleted`, `trackKvAgentRunUndone`, `trackKvAgentRunUndoFailed`, `trackKvAgentRunTargetFocused`.

Design notes (from `DeckRunCard.tsx` / `DeckRunCardHeadless`, adapted):
- Server-mode only: the card fetches the run by id and undoes through the api (spec §8.2). Inline two-step confirm ("Undo run" → copy + Undo / Keep), like `DeckRunCard`.
- The confirm "Undo" button uses `loading` with `loadingStyle="shimmer"` so it is disabled AND keeps its label while pending (the default spinner replaces the label, `Button.tsx:314`). The handler also guards `undo.isPending`.
- `already_undone` renders "Already undone" and fires no `run_undone` (same rule as `deck_agent.run_undone`).
- 403/404 on the run fetch → render nothing (api flag off or foreign file), matching `DeckRunCardHeadless`. Other failures show a muted line with Retry. Queries and the mutation carry `meta: { suppressErrorToast: true }` because the app `QueryClient` toasts every failure otherwise (`src/lib/queryClient.ts`).
- The frame arrives before the api has seen the turn's `done`, so the first read can say `running`; the card polls every 2 s for at most 30 reads (Review Focus 1).
- A live run that touched a size invalidates `resizeExportsQueryKey(fileId)` once (detached tiles are REST rows the doc does not carry); so does a successful undo.

Analytics decisions (skill `frndos-analytics-events`; spec §9 lists names):
- New dot-namespaced domain `kv_agent.*`, the sibling of `deck_agent.*` (`src/lib/analytics/deck-agent-events.ts`), because P2/P3 add more events to it. Spec §9's `kv_agent_run_completed` / `kv_agent_run_undone` ship as `kv_agent.run_completed` / `kv_agent.run_undone`; recorded in Contract deviations (D4).
- `kv_agent.run_completed` fires once per run (module-level Set survives the chat list's remount churn), only when `live` and the run reads `completed` — never on reload.
- `kv_agent.run_undo_failed` completes the attempt/outcome pair (`reason` = api `error` code, `http_status`). `kv_agent.run_target_focused` covers the target click.
- `kv_agent_targets_suggested` is **dropped from P1**: the question card frame carries only `label` + `options` (`useKvStream.ts:166-175`), nothing marks a target-suggestion card, and the generic `kv_generator.assistant_card_shown {card_type:"question"}` already fires for it. See D5.
- `kv_agent_plan_*` are P2.

- [ ] **Step 1: Write the failing test**

Create `src/components/studio/kv-generator/KvAgentRunCard.test.tsx`:

```tsx
/*
 * KvAgentRunCard — contract C5 run view + undo. The api is injected through
 * the `api` prop and PostHog is spied on its default export, so this file
 * registers NO mock.module (bun's registry is process-global; see
 * lesson_bun_mock_module_binding_capture). Queries use within(document.body),
 * never `screen`.
 */
import { afterEach, beforeEach, describe, expect, it, mock, spyOn } from "bun:test";
import { act, render, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import posthog from "posthog-js";
import { useToastStore } from "@/store/useToast";
import type { KvAgentRun, KvAgentRunUndoResult } from "@/types/kv/agentRun";
import {
  KvAgentRunCard,
  __resetKvAgentRunCardTracking,
  agentRunRefetchInterval,
  type KvAgentRunApi,
} from "./KvAgentRunCard";

const body = () => within(document.body);

function run(over: Partial<KvAgentRun> = {}): KvAgentRun {
  return {
    id: "01JRUN",
    status: "completed",
    source: "app",
    createdAt: "2026-09-29T10:00:00Z",
    applied: [
      { target: "gen_a", targetKind: "board", targetLabel: "Concept A", layerId: "L1", op: "set_layer" },
      { target: "exp_1", targetKind: "size", targetLabel: "Concept A · Instagram Story", layerId: "L1", op: "set_layer" },
    ],
    skipped: [
      { target: "exp_2", targetKind: "size", targetLabel: "Concept A · Banner", layerId: "L1", reason: "layer_absent_on_size" },
    ],
    detachedSizes: [{ sizeId: "exp_1", label: "Concept A · Instagram Story" }],
    undo: null,
    ...over,
  };
}

function fakeApi(over: Partial<KvAgentRunApi> = {}) {
  return {
    getRun: mock(async () => run()),
    undoRun: mock(
      async (): Promise<KvAgentRunUndoResult> => ({ status: "undone", reverted: 2, skipped: [] })
    ),
    ...over,
  };
}

let client: QueryClient;
function mount(ui: React.ReactElement) {
  return render(<QueryClientProvider client={client}>{ui}</QueryClientProvider>);
}

let capture: ReturnType<typeof spyOn>;
beforeEach(() => {
  client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  capture = spyOn(posthog, "capture").mockImplementation(() => undefined as never);
  __resetKvAgentRunCardTracking();
  useToastStore.setState({ toasts: [] });
});
afterEach(() => capture.mockRestore());

const events = (name: string) => capture.mock.calls.filter((c) => c[0] === name);

describe("KvAgentRunCard", () => {
  it("renders applied targets, skipped with a human reason, and the detached notice", async () => {
    const api = fakeApi();
    mount(<KvAgentRunCard fileId="f1" runId="01JRUN" live={false} api={api} />);
    await body().findByText("Changed 2 boards and sizes · 1 skipped");
    expect(api.getRun).toHaveBeenCalledWith("f1", "01JRUN");
    const applied = within(body().getByRole("list", { name: "Applied" }));
    expect(applied.getByText("Concept A")).toBeTruthy();
    expect(applied.getByText("Concept A · Instagram Story")).toBeTruthy();
    expect(
      body().getByText("Concept A · Banner — this size doesn't have that layer")
    ).toBeTruthy();
    expect(
      body().getByText("Concept A · Instagram Story now has its own layers (detached).")
    ).toBeTruthy();
  });

  it("focuses the clicked target on the canvas", async () => {
    const onFocusTarget = mock(() => {});
    mount(
      <KvAgentRunCard fileId="f1" runId="01JRUN" live={false} api={fakeApi()} onFocusTarget={onFocusTarget} />
    );
    await userEvent.click(await body().findByRole("button", { name: /Instagram Story/ }));
    expect(onFocusTarget).toHaveBeenCalledWith({ kind: "size", id: "exp_1" });
    expect(events("kv_agent.run_target_focused")).toHaveLength(1);
  });

  it("undoes through the run's route once, disabled while pending, then shows the result", async () => {
    let resolveUndo!: (r: KvAgentRunUndoResult) => void;
    const api = fakeApi({
      undoRun: mock(
        () =>
          new Promise<KvAgentRunUndoResult>((r) => {
            resolveUndo = r;
          })
      ),
    });
    mount(<KvAgentRunCard fileId="f1" runId="01JRUN" live={false} api={api} />);
    await userEvent.click(await body().findByRole("button", { name: "Undo run" }));
    expect(body().getByText(/Credits already spent are not refunded/)).toBeTruthy();

    const confirm = body().getByRole("button", { name: "Undo" });
    await userEvent.click(confirm);
    await waitFor(() => expect(body().getByRole("button", { name: "Undo" })).toHaveProperty("disabled", true));
    await userEvent.click(body().getByRole("button", { name: "Undo" }));
    expect(api.undoRun).toHaveBeenCalledTimes(1);
    expect(api.undoRun).toHaveBeenCalledWith("f1", "01JRUN");

    await act(async () =>
      resolveUndo({
        status: "undone",
        reverted: 2,
        skipped: [{ target: "gen_a", layerId: "L1", reason: "changed_after_run" }],
      })
    );
    await body().findByText("Undone · 2 reverted · 1 skipped");
    expect(body().getByText("A layer — edited after the run, so it was kept")).toBeTruthy();
    expect(body().queryByRole("button", { name: "Undo run" })).toBeNull();
    expect(events("kv_agent.run_undone")).toHaveLength(1);
    expect(events("kv_agent.run_undone")[0][1]).toMatchObject({
      file_id: "f1",
      run_id: "01JRUN",
      reverted: 2,
      skipped_count: 1,
    });
  });

  it("reads already_undone as Already undone, and does not count it as a revert", async () => {
    const api = fakeApi({
      undoRun: mock(async (): Promise<KvAgentRunUndoResult> => ({ status: "already_undone", reverted: 0, skipped: [] })),
    });
    mount(<KvAgentRunCard fileId="f1" runId="01JRUN" live={false} api={api} />);
    await userEvent.click(await body().findByRole("button", { name: "Undo run" }));
    await userEvent.click(body().getByRole("button", { name: "Undo" }));
    await body().findByText("Already undone");
    expect(events("kv_agent.run_undone")).toHaveLength(0);
  });

  it("shows a run that was undone before reload without an Undo button", async () => {
    const api = fakeApi({
      getRun: mock(async () => run({ status: "undone", undo: { reverted: 2, skipped: [] } })),
    });
    mount(<KvAgentRunCard fileId="f1" runId="01JRUN" live={false} api={api} />);
    await body().findByText("Undone · 2 reverted");
    expect(body().queryByRole("button", { name: "Undo run" })).toBeNull();
  });

  it("keeps Undo run disabled while the run is still running", async () => {
    const api = fakeApi({ getRun: mock(async () => run({ status: "running" })) });
    mount(<KvAgentRunCard fileId="f1" runId="01JRUN" live={false} api={api} />);
    await body().findByText("Working on the canvas…");
    expect(body().getByRole("button", { name: "Undo run" })).toHaveProperty("disabled", true);
  });

  it("tracks run_completed once for a live run, never for a reloaded one", async () => {
    const first = mount(<KvAgentRunCard fileId="f1" runId="01JRUN" live api={fakeApi()} />);
    await body().findByText("Changed 2 boards and sizes · 1 skipped");
    first.unmount();
    mount(<KvAgentRunCard fileId="f1" runId="01JRUN" live api={fakeApi()} />);
    await body().findByText("Changed 2 boards and sizes · 1 skipped");
    expect(events("kv_agent.run_completed")).toHaveLength(1);
    expect(events("kv_agent.run_completed")[0][1]).toMatchObject({
      file_id: "f1",
      run_id: "01JRUN",
      source: "app",
      op_count: 2,
      target_count: 2,
      skipped_count: 1,
      detached_count: 1,
    });

    __resetKvAgentRunCardTracking();
    capture.mockClear();
    mount(<KvAgentRunCard fileId="f1" runId="01JRUN" live={false} api={fakeApi()} />);
    await waitFor(() => expect(body().getAllByText("Changed 2 boards and sizes · 1 skipped").length).toBeGreaterThan(0));
    expect(events("kv_agent.run_completed")).toHaveLength(0);
  });

  it("refetches size tiles for a live run that touched sizes", async () => {
    const invalidate = spyOn(client, "invalidateQueries");
    mount(<KvAgentRunCard fileId="f1" runId="01JRUN" live api={fakeApi()} />);
    await body().findByText("Changed 2 boards and sizes · 1 skipped");
    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["kv-resize-exports", "f1"] });
  });

  it("toasts and tracks a failed undo, and keeps the run undoable", async () => {
    const api = fakeApi({
      undoRun: mock(async () => {
        throw { response: { status: 409, data: { error: "run_in_progress" } } };
      }),
    });
    mount(<KvAgentRunCard fileId="f1" runId="01JRUN" live={false} api={api} />);
    await userEvent.click(await body().findByRole("button", { name: "Undo run" }));
    await userEvent.click(body().getByRole("button", { name: "Undo" }));
    await waitFor(() => expect(useToastStore.getState().toasts).toHaveLength(1));
    expect(useToastStore.getState().toasts[0]).toMatchObject({
      title: "Couldn't undo the run",
      description: "The agent is still working on this canvas. Try again when it finishes.",
    });
    expect(events("kv_agent.run_undo_failed")[0][1]).toMatchObject({
      reason: "run_in_progress",
      http_status: 409,
    });
    expect(body().getByRole("button", { name: "Undo" })).toHaveProperty("disabled", false);
  });

  it("renders nothing when the api hides the run (404)", async () => {
    const api = fakeApi({
      getRun: mock(async () => {
        throw { response: { status: 404 } };
      }),
    });
    mount(<KvAgentRunCard fileId="f1" runId="01JRUN" live={false} api={api} />);
    await waitFor(() => expect(api.getRun).toHaveBeenCalled());
    await waitFor(() => expect(body().queryByTestId("kv-agent-run-card")).toBeNull());
  });

  it("polls a running run, but not forever", () => {
    expect(agentRunRefetchInterval(run({ status: "running" }), 1)).toBe(2000);
    expect(agentRunRefetchInterval(run({ status: "running" }), 30)).toBe(false);
    expect(agentRunRefetchInterval(run(), 1)).toBe(false);
    expect(agentRunRefetchInterval(undefined, 0)).toBe(false);
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bun test src/components/studio/kv-generator/KvAgentRunCard.test.tsx`
Expected: FAIL — `Cannot find module './KvAgentRunCard'`.

- [ ] **Step 3: Create the analytics module**

Create `src/lib/analytics/kv-agent-events.ts`:

```ts
import posthog from "posthog-js";

/**
 * KV agentic canvas — the chat agent writing to the canvas (spec
 * 2026-09-29 §9). Dot-namespaced as its own domain, the sibling of
 * `deck_agent.*`: one instruction fanned out across boards and sizes is a
 * different job from the `kv_generator.*` family's single render, and P2/P3
 * add the plan events to this same module.
 *
 * The number this surface exists to produce is TRUST: how often a run is
 * kept versus undone, and how often targets are skipped. Base context
 * (user / workspace / brand) is a super property — never passed here.
 */
const safeCapture = (event: string, props: object = {}) => {
  try {
    posthog?.capture(event, {
      ...props,
      timestamp: new Date().toISOString(),
    });
  } catch {
    // no-op: analytics never breaks the app
  }
};

/** A run that finished in THIS session's live stream (never on reload). */
export function trackKvAgentRunCompleted(props: {
  file_id: string;
  run_id: string;
  source: "app" | "mcp";
  /** Applied ops (one per layer per target). */
  op_count: number;
  /** Distinct boards + sizes that received at least one op. */
  target_count: number;
  skipped_count: number;
  detached_count: number;
}): void {
  safeCapture("kv_agent.run_completed", props);
}

/** The api reverted the run. An `already_undone` answer is not a revert and
 *  does not fire (same rule as `deck_agent.run_undone`). */
export function trackKvAgentRunUndone(props: {
  file_id: string;
  run_id: string;
  reverted: number;
  skipped_count: number;
}): void {
  safeCapture("kv_agent.run_undone", props);
}

/** The undo request did not come back — without it a failing undo and an
 *  unused one look the same. `reason` is the api `error` code when present. */
export function trackKvAgentRunUndoFailed(props: {
  file_id: string;
  run_id: string;
  reason: string;
  http_status: number | null;
}): void {
  safeCapture("kv_agent.run_undo_failed", props);
}

/** A target row on the run card was clicked to bring it into view. */
export function trackKvAgentRunTargetFocused(props: {
  file_id: string;
  run_id: string;
  target_kind: "board" | "size";
}): void {
  safeCapture("kv_agent.run_target_focused", props);
}
```

- [ ] **Step 4: Create the card**

Create `src/components/studio/kv-generator/KvAgentRunCard.tsx`:

```tsx
"use client";

import { useEffect, useRef, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Check, Warning } from "@phosphor-icons/react";
import { Button } from "@/components/frndos/v2";
import { getKvAgentRun, undoKvAgentRun } from "@/services/kv/api";
import { resizeExportsQueryKey } from "@/lib/studio/kv/useResizeExports";
import {
  KV_AGENT_UNDO_CONFIRM_COPY,
  describeKvAgentRunSummary,
  describeKvAgentUndoOutcome,
  groupAppliedByTarget,
  kvAgentSkipReasonText,
  kvAgentUndoSkipReasonText,
} from "@/lib/studio/kv/kvAgentRunCopy";
import {
  trackKvAgentRunCompleted,
  trackKvAgentRunTargetFocused,
  trackKvAgentRunUndoFailed,
  trackKvAgentRunUndone,
} from "@/lib/analytics/kv-agent-events";
import { useToastStore } from "@/store/useToast";
import {
  kvAgentRunQueryKey,
  type KvAgentFocusTarget,
  type KvAgentRun,
  type KvAgentRunUndoOutcome,
  type KvAgentRunUndoResult,
} from "@/types/kv/agentRun";

export interface KvAgentRunApi {
  getRun: (fileId: string, runId: string) => Promise<KvAgentRun>;
  undoRun: (fileId: string, runId: string) => Promise<KvAgentRunUndoResult>;
}

const DEFAULT_API: KvAgentRunApi = {
  getRun: getKvAgentRun,
  undoRun: undoKvAgentRun,
};

// Module-level so a remount (the chat list re-keys on every new message
// id) cannot fire `kv_agent.run_completed` twice for one run.
const completedTracked = new Set<string>();
/** Test seam: the Set outlives a test's unmount by design. */
export function __resetKvAgentRunCardTracking(): void {
  completedTracked.clear();
}

/** Poll a `running` run every 2 s, for at most ~1 minute of reads. An
 *  aborted turn can leave a run `running` until the api's own sweep, and a
 *  card must not poll forever for it. */
export function agentRunRefetchInterval(
  run: KvAgentRun | undefined,
  reads: number
): number | false {
  return run?.status === "running" && reads < 30 ? 2000 : false;
}

const touchesSizes = (run: KvAgentRun) =>
  run.detachedSizes.length > 0 ||
  run.applied.some((a) => a.targetKind === "size") ||
  run.skipped.some((s) => s.targetKind === "size");

const httpStatusOf = (err: unknown): number | null =>
  (err as { response?: { status?: number } } | null)?.response?.status ?? null;

const apiCodeOf = (err: unknown): string | null => {
  const code = (err as { response?: { data?: { error?: unknown } } } | null)
    ?.response?.data?.error;
  return typeof code === "string" ? code : null;
};

/**
 * The run card under a KV chat turn whose agent wrote to the canvas (spec
 * §9, contract C5). Analogous to `DeckRunCard`'s headless host: the api owns
 * the ledger, the card reads it by id and undoes server-side. Agent edits
 * reached the canvas as remote Y updates, so there is nothing to apply here —
 * the one client-side side effect is refetching detached size tiles (REST
 * rows the doc does not carry).
 */
export function KvAgentRunCard({
  fileId,
  runId,
  live,
  onFocusTarget,
  api = DEFAULT_API,
}: {
  fileId: string;
  runId: string;
  /** True when the run arrived on this session's stream (see ChatMessageMeta.agentRun). */
  live: boolean;
  onFocusTarget?: (target: KvAgentFocusTarget) => void;
  api?: KvAgentRunApi;
}) {
  const queryClient = useQueryClient();
  const showToast = useToastStore((s) => s.showToast);
  const queryKey = kvAgentRunQueryKey(fileId, runId);
  const {
    data: run,
    error,
    isPending,
    refetch,
  } = useQuery({
    queryKey,
    queryFn: () => api.getRun(fileId, runId),
    retry: false,
    // The frame lands before the api sees the turn's `done`, so the first
    // read can still say `running`. Poll until it settles.
    refetchInterval: (q) =>
      agentRunRefetchInterval(q.state.data, q.state.dataUpdateCount),
    meta: { suppressErrorToast: true },
  });

  const [confirming, setConfirming] = useState(false);
  const [undoResult, setUndoResult] = useState<KvAgentRunUndoResult | null>(
    null
  );

  // Detached size tiles are REST rows; the agent wrote them server-side.
  const sizesRefreshed = useRef(false);
  useEffect(() => {
    if (!run || !live || sizesRefreshed.current || !touchesSizes(run)) return;
    sizesRefreshed.current = true;
    void queryClient.invalidateQueries({ queryKey: resizeExportsQueryKey(fileId) });
  }, [run, live, fileId, queryClient]);

  useEffect(() => {
    if (!run || !live || run.status !== "completed") return;
    if (completedTracked.has(run.id)) return;
    completedTracked.add(run.id);
    trackKvAgentRunCompleted({
      file_id: fileId,
      run_id: run.id,
      source: run.source,
      op_count: run.applied.length,
      target_count: groupAppliedByTarget(run.applied).length,
      skipped_count: run.skipped.length,
      detached_count: run.detachedSizes.length,
    });
  }, [run, live, fileId]);

  const undo = useMutation({
    mutationFn: () => api.undoRun(fileId, runId),
    meta: { suppressErrorToast: true },
    onSuccess: (result) => {
      setUndoResult(result);
      setConfirming(false);
      if (result.status === "undone") {
        trackKvAgentRunUndone({
          file_id: fileId,
          run_id: runId,
          reverted: result.reverted,
          skipped_count: result.skipped.length,
        });
      }
      void queryClient.invalidateQueries({ queryKey });
      if (run && touchesSizes(run)) {
        void queryClient.invalidateQueries({
          queryKey: resizeExportsQueryKey(fileId),
        });
      }
    },
    onError: (err) => {
      const code = apiCodeOf(err);
      trackKvAgentRunUndoFailed({
        file_id: fileId,
        run_id: runId,
        reason: code ?? "request_failed",
        http_status: httpStatusOf(err),
      });
      showToast(
        "Couldn't undo the run",
        code === "run_in_progress"
          ? "The agent is still working on this canvas. Try again when it finishes."
          : "Please try again.",
        "error"
      );
    },
  });

  const status = httpStatusOf(error);
  if (status === 403 || status === 404) return null;

  const shell =
    "mx-4 mb-4 flex flex-col gap-2 rounded-xl border border-border-default bg-surface-raised px-3 py-2.5 font-geist";

  if (isPending) {
    return (
      <div className={shell} data-testid="kv-agent-run-card" aria-busy="true">
        <span className="text-textXs text-text-inverse-subtlest">Loading agent run…</span>
      </div>
    );
  }
  if (!run) {
    return (
      <div className={shell} data-testid="kv-agent-run-card">
        <span className="text-textXs text-text-inverse-subtle">
          Couldn't load this agent run.
        </span>
        <Button size="tiny" variant="secondary" onClick={() => void refetch()}>
          Retry
        </Button>
      </div>
    );
  }

  const outcome: (KvAgentRunUndoOutcome & { already?: boolean }) | null =
    undoResult
      ? { ...undoResult, already: undoResult.status === "already_undone" }
      : run.undo;
  const undone = Boolean(outcome) || run.status === "undone";
  const canUndo =
    !undone &&
    (run.status === "completed" || run.status === "failed") &&
    run.applied.length > 0;
  const targets = groupAppliedByTarget(run.applied);

  const focus = (target: KvAgentFocusTarget) => {
    if (!onFocusTarget) return;
    onFocusTarget(target);
    trackKvAgentRunTargetFocused({
      file_id: fileId,
      run_id: run.id,
      target_kind: target.kind,
    });
  };

  return (
    <div className={shell} data-testid="kv-agent-run-card" data-run-status={run.status}>
      <div className="flex items-baseline gap-2">
        <span className="text-textXs font-medium uppercase tracking-[0.08em] text-text-inverse-subtlest">
          Agent run
        </span>
        <span className="text-textSm text-text-inverse">
          {describeKvAgentRunSummary(run)}
        </span>
      </div>

      {targets.length > 0 && (
        <ul className="flex flex-col gap-1" aria-label="Applied">
          {targets.map((t) => (
            <li key={t.target}>
              <button
                type="button"
                disabled={!onFocusTarget}
                onClick={() => focus({ kind: t.targetKind, id: t.target })}
                className="flex w-full items-center gap-2 rounded-lg px-1.5 py-1 text-left text-textXs text-text-inverse-subtle transition-colors hover:bg-surface-overlay hover:text-text-inverse disabled:cursor-default disabled:hover:bg-transparent"
              >
                <Check size={12} weight="bold" className="shrink-0 text-positive-400" aria-hidden />
                <span className="min-w-0 flex-1 truncate">{t.targetLabel}</span>
                <span className="shrink-0 text-text-inverse-subtlest">
                  {t.layerCount} {t.layerCount === 1 ? "layer" : "layers"}
                </span>
              </button>
            </li>
          ))}
        </ul>
      )}

      {run.skipped.length > 0 && (
        <ul className="flex flex-col gap-1" aria-label="Skipped">
          {run.skipped.map((s, i) => (
            <li
              key={`${s.target}:${s.layerId ?? ""}:${i}`}
              className="flex items-start gap-2 px-1.5 text-textXs text-text-inverse-subtle"
            >
              <Warning size={12} weight="bold" className="mt-0.5 shrink-0 text-warning-400" aria-hidden />
              <span className="min-w-0 flex-1">
                {s.targetLabel} — {kvAgentSkipReasonText(s.reason)}
              </span>
            </li>
          ))}
        </ul>
      )}

      {run.detachedSizes.map((d) => (
        <p key={d.sizeId} className="px-1.5 text-textXs text-text-inverse-subtle">
          {d.label} now has its own layers (detached).
        </p>
      ))}

      {outcome ? (
        <div className="flex flex-col gap-1 border-t border-border-default pt-2" data-testid="kv-agent-run-undo-result">
          <span className="text-textXs text-text-inverse-subtle">
            {outcome.already ? "Already undone" : describeKvAgentUndoOutcome(outcome)}
          </span>
          {outcome.skipped.map((s, i) => (
            <span key={`${s.target}:${s.layerId ?? ""}:${i}`} className="text-textXs text-text-inverse-subtlest">
              {s.layerId ? "A layer" : "A target"} — {kvAgentUndoSkipReasonText(s.reason)}
            </span>
          ))}
        </div>
      ) : run.status === "undone" ? (
        <span className="border-t border-border-default pt-2 text-textXs text-text-inverse-subtle">
          Undone
        </span>
      ) : confirming ? (
        <div className="flex flex-col gap-2 border-t border-border-default pt-2" data-testid="kv-agent-run-undo-confirm">
          <p className="text-textXs text-text-inverse-subtle">{KV_AGENT_UNDO_CONFIRM_COPY}</p>
          <div className="flex gap-2">
            <Button
              size="small"
              loading={undo.isPending}
              loadingStyle="shimmer"
              onClick={() => {
                if (!undo.isPending) undo.mutate();
              }}
            >
              Undo
            </Button>
            <Button
              size="small"
              variant="secondary"
              disabled={undo.isPending}
              onClick={() => setConfirming(false)}
            >
              Keep
            </Button>
          </div>
        </div>
      ) : (
        <div className="flex justify-end">
          <Button
            size="small"
            variant="secondary"
            disabled={!canUndo}
            title={run.status === "running" ? "Available when the run finishes" : undefined}
            onClick={() => setConfirming(true)}
          >
            Undo run
          </Button>
        </div>
      )}
    </div>
  );
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bun test src/components/studio/kv-generator/KvAgentRunCard.test.tsx`
Expected: PASS (11 tests). A React `act(...)` warning, if printed, is noise (the same appears in `DeckRunCard.test.tsx`).

Non-vacuity (each was run by the plan author; re-run any you doubt, then restore): drop `loading={undo.isPending}` → the pending test fails; drop `!live ||` from the completed effect → the tracking test fails; drop the `completedTracked.has` guard → the tracking test fails; fire `run_undone` for every status → the already_undone test fails; drop the 403/404 `return null` → the 404 test fails; drop the sizes invalidation → the size-tiles test fails; ignore `run.undo` → the reload-undone test fails; allow `running` in `canUndo` → the running test fails; drop `onFocusTarget(target)` → the focus test fails; drop `showToast(` → the failed-undo test fails.

- [ ] **Step 6: Commit**

```bash
git add src/lib/analytics/kv-agent-events.ts src/components/studio/kv-generator/KvAgentRunCard.tsx src/components/studio/kv-generator/KvAgentRunCard.test.tsx
git commit -m "feat(web): KV agent run card with undo and kv_agent analytics

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Render the run card in `KvChat`

**Files:**
- Modify: `src/components/studio/kv-generator/KvChat.tsx` (imports `:86`, `Props` `:185-186`, `KvChat` destructure `:260-262`, `<MessagesList …>` `:520-533`, `MessagesList` signature `:842-865`, default assistant branch `:1520-1536`)
- Create: `src/components/studio/kv-generator/KvChat.agentRun.test.tsx`

**Interfaces:**
- Consumes: `ChatMessageMeta.agentRun` (Task 1), `KvAgentRunCard` (Task 5), `KvAgentFocusTarget` (Task 3).
- Produces: `KvChat` props `agentRunCardsEnabled?: boolean` (default `false`) and `onFocusAgentTarget?: (target: KvAgentFocusTarget) => void`, both threaded into `MessagesList`. Task 8 passes them from the layout.

No `KvChat` component test existed before this plan. The new one mounts the real `KvChat` with a plain-object stream built from `hydrateInitialMessages` (the exact reload path), and observes the card's fetch on `axiosInstance.get` — no module mocks.

- [ ] **Step 1: Write the failing test**

Create `src/components/studio/kv-generator/KvChat.agentRun.test.tsx`:

```tsx
/*
 * KvChat mounts the KV agent run card under the turn that owns it — only
 * behind the `agentRunCardsEnabled` prop the layout resolves from the
 * `kv-agentic-canvas` flag. No mock.module: the stream is a plain object and
 * the card's fetch is observed on axiosInstance.get (every other GET the
 * panel makes, e.g. image models, is answered 404 and ignored).
 *
 * canvasMode "motion" has no chat persona, so the brainstorm-suggestion
 * query under the last reply stays disabled and makes no request.
 */
import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { render, waitFor, within } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import axiosInstance from "@/services/axios";
import { hydrateInitialMessages, type useKvStream } from "@/hooks/useKvStream";
import { KvChat } from "./KvChat";

type Stream = ReturnType<typeof useKvStream>;
const body = () => within(document.body);

const RUN = {
  id: "01JRUN",
  status: "completed",
  source: "app",
  created_at: "2026-09-29T10:00:00Z",
  applied: [
    { target: "gen_a", target_kind: "board", target_label: "Concept A", layer_id: "L1", op: "set_layer" },
  ],
  skipped: [],
  detached_sizes: [],
  undo: null,
};

function fakeStream(messages: Stream["messages"]): Stream {
  const noop = () => {};
  return {
    messages,
    generations: [],
    pendingGeneration: null,
    mode: "chat",
    setMode: noop,
    send: async () => {},
    abort: noop,
    isStreaming: false,
    isPreparing: false,
    setIsPreparing: noop,
    pushError: noop,
    pushAssistantMessage: noop,
    ingestGeneration: noop,
    pushResizeMarker: noop,
  } as unknown as Stream;
}

// Exactly what a reload hands the chat: the api's history row, hydrated.
const reloaded = () =>
  hydrateInitialMessages([
    { id: "1", role: "user", text: "change the headline on every size" },
    { id: "2", role: "assistant", text: "Done — the headline now reads Diskon 50%.", agent_run_id: "01JRUN" },
  ]);

let get: ReturnType<typeof spyOn>;
beforeEach(() => {
  get = spyOn(axiosInstance, "get").mockImplementation((async (url: string) => {
    if (url === "v1/studio/files/f1/agent/runs/01JRUN") return { data: { data: RUN } };
    throw { response: { status: 404 } };
  }) as never);
});
afterEach(() => get.mockRestore());

function mount(enabled: boolean) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={client}>
      <KvChat
        title="Ramadan KV"
        brandName={null}
        stream={fakeStream(reloaded())}
        hasMessages
        fileId="f1"
        canvasMode="motion"
        agentRunCardsEnabled={enabled}
      />
    </QueryClientProvider>
  );
}

describe("KvChat — agent run card", () => {
  it("shows the run card under the reloaded turn when the flag is on", async () => {
    mount(true);
    await body().findByText("Changed 1 board or size");
    expect(body().getByText(/headline now reads Diskon 50%/)).toBeTruthy();
    expect(get).toHaveBeenCalledWith("v1/studio/files/f1/agent/runs/01JRUN");
  });

  it("renders no card and fetches nothing when the flag is off", async () => {
    mount(false);
    await body().findByText(/headline now reads Diskon 50%/);
    expect(body().queryByTestId("kv-agent-run-card")).toBeNull();
    expect(
      get.mock.calls.some((c) => String(c[0]).includes("/agent/runs/"))
    ).toBe(false);
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bun test src/components/studio/kv-generator/KvChat.agentRun.test.tsx`
Expected: "shows the run card under the reloaded turn when the flag is on" FAILS (no "Changed 1 board or size" text; `agentRunCardsEnabled` is not a prop yet). "renders no card … when the flag is off" passes already — it guards the gate you are about to add.

- [ ] **Step 3: Implement**

In `src/components/studio/kv-generator/KvChat.tsx`:

After `import { useKvChatSuggestions } from "@/lib/studio/kv/useKvChatSuggestions";` add:

```ts
import type { KvAgentFocusTarget } from "@/types/kv/agentRun";
import { KvAgentRunCard } from "./KvAgentRunCard";
```

In `type Props`, after `onNavigateToBoard?: (generationId: string) => void;` (the first occurrence, `:186`) add:

```ts
  /** KV agentic canvas — the `kv-agentic-canvas` flag, resolved by the
   *  layout. False (the default) renders no run card at all. */
  agentRunCardsEnabled?: boolean;
  /** Bring a run card's board or size into view on the canvas. */
  onFocusAgentTarget?: (target: KvAgentFocusTarget) => void;
```

In `export function KvChat({ … })`, after `onNavigateToBoard,` add:

```ts
  agentRunCardsEnabled = false,
  onFocusAgentTarget,
```

In the `<MessagesList … />` element (inside `{hasMessages ? (`), after `editTargetHasResizes={editTargetHasResizes}` add:

```tsx
            agentRunCardsEnabled={agentRunCardsEnabled}
            onFocusAgentTarget={onFocusAgentTarget}
```

In `function MessagesList({ … })`: after `editTargetHasResizes = false,` in the destructure add

```ts
  agentRunCardsEnabled = false,
  onFocusAgentTarget,
```

and after `editTargetHasResizes?: boolean;` in its inline prop type add

```ts
  agentRunCardsEnabled?: boolean;
  onFocusAgentTarget?: (target: KvAgentFocusTarget) => void;
```

In the default assistant branch at the end of the `stream.messages.map`, replace

```tsx
        return (
          <AssistantMessage
            key={m.id}
            messageId={m.id}
            tools={tools}
            hasReply={hasReply}
            isStreamingText={isStreamingText}
            text={m.text}
          />
        );
```

with

```tsx
        const agentRun =
          agentRunCardsEnabled && fileId ? m.metadata?.agentRun : undefined;
        const assistantMessage = (
          <AssistantMessage
            key={m.id}
            messageId={m.id}
            tools={tools}
            hasReply={hasReply}
            isStreamingText={isStreamingText}
            text={m.text}
          />
        );
        if (!agentRun || !fileId) return assistantMessage;
        // KV agentic canvas: the run card sits under the turn that wrote to
        // the canvas. A turn with no prose and no chips is just the card.
        return (
          <div key={m.id} className="flex w-full flex-col">
            {(tools.length > 0 || hasReply) && assistantMessage}
            <KvAgentRunCard
              fileId={fileId}
              runId={agentRun.runId}
              live={agentRun.live}
              onFocusTarget={onFocusAgentTarget}
            />
          </div>
        );
```

Messages without a run keep the exact element they rendered before (no wrapper), so no existing layout changes.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bun test src/components/studio/kv-generator/KvChat.agentRun.test.tsx`
Expected: PASS (2 tests).

Non-vacuity (author-run): dropping `agentRunCardsEnabled &&` from the `agentRun` line fails the flag-off test; not threading `agentRunCardsEnabled` into `<MessagesList>` fails the flag-on test.

- [ ] **Step 5: Run the new component suites together**

Run: `bun test src/components/studio/kv-generator/KvChat.agentRun.test.tsx src/components/studio/kv-generator/KvAgentRunCard.test.tsx src/services/kv/agentRun.api.test.ts`
Expected: PASS (17 tests), no `N error` line.

- [ ] **Step 6: Commit**

```bash
git add src/components/studio/kv-generator/KvChat.tsx src/components/studio/kv-generator/KvChat.agentRun.test.tsx
git commit -m "feat(web): show the KV agent run card under its chat turn

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Tile Textboxes repaint their text

**Files:**
- Modify: `src/components/studio/kv-generator/fabric/useOverlayReconcile.ts` (existing-Textbox branch, insert before the comment at `:415` "Clear stale per-character styles before re-applying")
- Create: `src/components/studio/kv-generator/fabric/useOverlayReconcile.tileText.test.ts`

**Interfaces:**
- Consumes: `useOverlayReconcile`'s existing params (`allOverlays`, `restSurfaceByOverlayId`), `resolveDisplayText` (already imported at `:26`).
- Produces: no new API. Behaviour: an existing Fabric Textbox for a REST/tile overlay (`restSurfaceByOverlayId.has(id)`) gets `text = resolveDisplayText(payload.content, payload)` on reconcile, unless it is being inline-edited.

Why (see Grounding): the geometry reconcile re-runs whenever `allOverlays` changes identity — which it does for every board edit, because `KvCanvas` re-projects inheriting tiles from the live store — but its existing-Textbox branch restyles font, weight, align, spacing, opacity, blend, runs and fill, and never the string. Doc (board) overlays get their string from the style sync, which only loops doc overlays. The fix is scoped to tile overlays so board overlays keep exactly today's path. Both inheriting tiles (re-projected) and detached tiles (refetched REST rows, Task 5) flow through here.

- [ ] **Step 1: Write the failing test**

Create `src/components/studio/kv-generator/fabric/useOverlayReconcile.tileText.test.ts` (a real `fabric.Canvas` on a jsdom canvas — bun supplies a working 2D context, and `fabricExport.test.ts` already builds Textboxes this way):

```ts
/*
 * A tile (REST) text overlay must repaint its TEXT when its content changes.
 *
 * Tile overlays reach the engine only through `allOverlays`; the render-only
 * font/style/fill syncs loop the DOC overlays, and the geometry reconcile's
 * existing-Textbox branch restyled everything except the string. An inheriting
 * tile therefore kept the old headline after its board's headline changed —
 * locally or, for the KV agent, as a remote Y update — until a remount.
 */
import { describe, expect, it } from "bun:test";
import { renderHook } from "@testing-library/react";
import * as fabric from "fabric";
import { createKvDoc } from "@/lib/kv/yjsDoc";
import { tileOverlayCanvasId } from "@/lib/studio/kv/tileOverlayId";
import type { StudioOverlay } from "@/types/studio";
import { useOverlayReconcile } from "./useOverlayReconcile";

const TILE = "exp_1";
const ID = tileOverlayCanvasId(TILE, "L1");

function textOverlay(content: string): StudioOverlay {
  return {
    id: ID,
    studio_file_id: "f1",
    type: "text",
    x: 0.1,
    y: 0.1,
    width: 0.6,
    height: 0.1,
    rotation: 0,
    z: 1,
    board_generation_id: "gen_a",
    payload: { type: "text", content, color: "#FFFFFF", fontSize: 0.05 },
  } as StudioOverlay;
}

function setup() {
  const el = document.createElement("canvas");
  const canvas = new fabric.Canvas(el, { width: 800, height: 800 });
  const base = {
    fabricRef: { current: canvas },
    tool: "cursor" as const,
    overlays: [] as StudioOverlay[],
    overlaysRef: { current: [] as StudioOverlay[] },
    overlaysHidden: false,
    restSurfaceByOverlayId: new Map([[ID, TILE]]),
    restOverlaysInteractive: false,
    doc: createKvDoc(),
    activeHostRect: { x: 0, y: 0, width: 512, height: 512 },
    overlayHostRect: () => ({ x: 0, y: 0, width: 512, height: 512 }),
    buildOverlayClip: () => undefined,
    boardsSig: "",
    boardAspects: {},
    editingTextId: null,
    overlayInteracting: false,
    draggingOverlayIdRef: { current: null },
    ghostRefreshHandleRef: { current: null },
    cbRef: { current: {} },
  };
  return { canvas, base };
}

const textOf = (canvas: fabric.Canvas) =>
  (canvas.getObjects().find(
    (o) => (o as { data?: { elementId?: string } }).data?.elementId === ID
  ) as fabric.Textbox | undefined)?.text;

describe("useOverlayReconcile — tile text", () => {
  it("repaints an existing tile Textbox when its content changes", () => {
    const { canvas, base } = setup();
    const { rerender } = renderHook((all: StudioOverlay[]) =>
      useOverlayReconcile({ ...base, allOverlays: all } as never),
      { initialProps: [textOverlay("Promo Ramadan")] }
    );
    expect(textOf(canvas)).toBe("Promo Ramadan");
    rerender([textOverlay("Diskon 50%")]);
    expect(textOf(canvas)).toBe("Diskon 50%");
  });

  it("leaves a tile Textbox alone while it is being inline-edited", () => {
    const { canvas, base } = setup();
    const { rerender } = renderHook((all: StudioOverlay[]) =>
      useOverlayReconcile({ ...base, allOverlays: all } as never),
      { initialProps: [textOverlay("Promo Ramadan")] }
    );
    const box = canvas
      .getObjects()
      .find((o) => (o as { data?: { elementId?: string } }).data?.elementId === ID) as fabric.Textbox;
    box.isEditing = true;
    rerender([textOverlay("Diskon 50%")]);
    expect(box.text).toBe("Promo Ramadan");
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bun test src/components/studio/kv-generator/fabric/useOverlayReconcile.tileText.test.ts`
Expected: "repaints an existing tile Textbox when its content changes" FAILS with `Expected: "Diskon 50%"` / `Received: "Promo Ramadan"`. The inline-edit test passes already (it guards the condition you are about to add).

- [ ] **Step 3: Implement**

In `src/components/studio/kv-generator/fabric/useOverlayReconcile.ts`, inside `if (found instanceof fabric.Textbox) {`, directly above the comment

```ts
          // Clear stale per-character styles before re-applying: a shrunken or
          // removed run would otherwise leave its styling on characters that no
          // longer belong to it.
```

insert:

```ts
          // A tile (REST) overlay's string. Doc overlays get theirs from the
          // style sync below, which loops the DOC list only, so without this a
          // tile Textbox kept its old text when the content it projects from
          // changed (the KV agent's "change the headline on every size", or a
          // plain local edit on the board). Never while inline-editing: the
          // Textbox then holds the raw string the user is typing.
          if (restSurfaceByOverlayId.has(overlay.id) && !found.isEditing) {
            const nextText = resolveDisplayText(
              overlay.payload.content ?? "",
              overlay.payload
            );
            if (found.text !== nextText) found.set({ text: nextText });
          }
```

It sits before `applyRunStylesToTextbox(...)` on purpose: run styles index the display string, so the string must be current first.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bun test src/components/studio/kv-generator/fabric/useOverlayReconcile.tileText.test.ts`
Expected: PASS (2 tests). Non-vacuity (author-run): removing `&& !found.isEditing` fails the inline-edit test.

- [ ] **Step 5: Commit**

```bash
git add src/components/studio/kv-generator/fabric/useOverlayReconcile.ts src/components/studio/kv-generator/fabric/useOverlayReconcile.tileText.test.ts
git commit -m "fix(web): repaint a resize tile's text when its source text changes

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Flag + focus a target from the card (layout wiring)

**Files:**
- Create: `src/lib/studio/kv/kvAgentFocus.ts`
- Create: `src/lib/studio/kv/kvAgentFocus.test.ts`
- Modify: `src/lib/featureFlags/constants.ts` (after `KV_IMAGE_EXPAND` at `:280`)
- Modify: `src/components/studio/kv-generator/KvGeneratorLayout.tsx` (imports after `:284`, flag next to `kvImageExpandEnabled` `:4167-4168`, new callback after `handleCanvasModeChange` closes `:5107-5109`, `<KvChat>` props before `initialInputValue` `:8424`)

**Interfaces:**
- Consumes: `KvAgentFocusTarget` (Task 3), `seedCanvasMode` / `LiveCanvasMode` (`src/lib/studio/kv/seedCanvasMode.ts`), layout locals `canvasMode`, `stream.generations`, `handleCanvasModeChange(next, { keepPin })`, `setViewingGenerationId(id, { explicitPin })`, `focusApiRef.current?.focusBoard?.(id): boolean`; `KvChat` props from Task 6.
- Produces: `planKvAgentFocus(target, { canvasMode, generations }): { switchToMode: LiveCanvasMode | null; pinGenerationId: string | null; surfaceId: string }`; `retryEachFrame(attempt, maxFrames, schedule?, cancel?): () => void`; `MAJOR_FEATURE_FLAGS.KV_AGENTIC_CANVAS = "kv-agentic-canvas"`.

Focus semantics (spec §9 "clicking a target focuses the canvas on that board/size"): the comment panel's model, not the Layers panel's — a run-card click IS the request to go look, so `focusBoard` CENTRES (`KvFabricCanvas.tsx:1525-1547`). A board is also pinned exactly like `onNavigateToBoard` (mode switch with `keepPin`, `explicitPin: true`). A size is a Craft strip surface keyed by its export id, so it only needs Craft. A mode switch is refused mid-stream (existing behaviour, shows "Wait for the current generation to finish"); the focus still retries and simply finds nothing if the target is in another mode.

- [ ] **Step 1: Write the failing test**

Create `src/lib/studio/kv/kvAgentFocus.test.ts`:

```ts
import { describe, expect, it, mock } from "bun:test";
import { planKvAgentFocus, retryEachFrame } from "./kvAgentFocus";

const generations = [
  { id: "gen_concept", mode: "sketch" as const },
  { id: "gen_craft", mode: "craft" as const },
  { id: "gen_legacy_resize", mode: "resize" as const },
];

describe("planKvAgentFocus", () => {
  it("pins a board and switches to the board's own mode", () => {
    expect(
      planKvAgentFocus({ kind: "board", id: "gen_concept" }, { canvasMode: "craft", generations })
    ).toEqual({ switchToMode: "sketch", pinGenerationId: "gen_concept", surfaceId: "gen_concept" });
    expect(
      planKvAgentFocus({ kind: "board", id: "gen_craft" }, { canvasMode: "craft", generations })
    ).toEqual({ switchToMode: null, pinGenerationId: "gen_craft", surfaceId: "gen_craft" });
  });

  it("maps a retired-Resize generation to Craft, and leaves an unknown board's mode alone", () => {
    expect(
      planKvAgentFocus({ kind: "board", id: "gen_legacy_resize" }, { canvasMode: "motion", generations })
        .switchToMode
    ).toBe("craft");
    expect(
      planKvAgentFocus({ kind: "board", id: "gen_missing" }, { canvasMode: "motion", generations })
        .switchToMode
    ).toBeNull();
  });

  it("sends a size to Craft by its export id and pins nothing", () => {
    expect(
      planKvAgentFocus({ kind: "size", id: "exp_1" }, { canvasMode: "sketch", generations })
    ).toEqual({ switchToMode: "craft", pinGenerationId: null, surfaceId: "exp_1" });
    expect(
      planKvAgentFocus({ kind: "size", id: "exp_1" }, { canvasMode: "craft", generations })
        .switchToMode
    ).toBeNull();
  });
});

describe("retryEachFrame", () => {
  // A manual frame queue: each `flush()` runs one frame.
  function frames() {
    const queue: Array<() => void> = [];
    return {
      schedule: (cb: () => void) => queue.push(cb),
      cancel: mock(() => {}),
      flush: () => queue.shift()?.(),
      pending: () => queue.length,
    };
  }

  it("stops as soon as the attempt succeeds", () => {
    const f = frames();
    let n = 0;
    const attempt = mock(() => ++n === 3);
    retryEachFrame(attempt, 10, f.schedule, f.cancel);
    for (let i = 0; i < 5; i++) f.flush();
    expect(attempt).toHaveBeenCalledTimes(3);
    expect(f.pending()).toBe(0);
  });

  it("gives up after maxFrames", () => {
    const f = frames();
    const attempt = mock(() => false);
    retryEachFrame(attempt, 4, f.schedule, f.cancel);
    for (let i = 0; i < 10; i++) f.flush();
    expect(attempt).toHaveBeenCalledTimes(4);
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bun test src/lib/studio/kv/kvAgentFocus.test.ts`
Expected: FAIL — `Cannot find module './kvAgentFocus'`.

- [ ] **Step 3: Implement the helper**

Create `src/lib/studio/kv/kvAgentFocus.ts`:

```ts
import type { KvGeneration } from "@/types/studio";
import type { KvAgentFocusTarget } from "@/types/kv/agentRun";
import { seedCanvasMode, type LiveCanvasMode } from "./seedCanvasMode";

/**
 * What the layout must do to bring a run card's target into view.
 *
 * - A BOARD target is a tip generation id: its mode decides the canvas mode
 *   (the canvas is mode-filtered, so a Concept board is invisible from
 *   Craft), and it is pinned like a chat "Editing" chip click.
 * - A SIZE target is a `KvResizeExport` id. Tiles live in Craft's strip and
 *   their Fabric surface id IS the export id (resizeStrip.ts), so only the
 *   mode is switched; nothing is pinned (a tile is not a generation).
 *
 * `surfaceId` is what `KvFocusApi.focusBoard` is called with in both cases.
 */
export interface KvAgentFocusPlan {
  switchToMode: LiveCanvasMode | null;
  pinGenerationId: string | null;
  surfaceId: string;
}

export function planKvAgentFocus(
  target: KvAgentFocusTarget,
  ctx: {
    canvasMode: LiveCanvasMode;
    generations: Pick<KvGeneration, "id" | "mode">[];
  }
): KvAgentFocusPlan {
  if (target.kind === "size") {
    return {
      switchToMode: ctx.canvasMode === "craft" ? null : "craft",
      pinGenerationId: null,
      surfaceId: target.id,
    };
  }
  const gen = ctx.generations.find((g) => g.id === target.id);
  const mode = gen ? seedCanvasMode(gen.mode) : null;
  return {
    switchToMode: mode && mode !== ctx.canvasMode ? mode : null,
    pinGenerationId: target.id,
    surfaceId: target.id,
  };
}

/**
 * Retry `attempt` once per frame until it returns true or `maxFrames` pass.
 * A surface only exists after a mode switch has re-rendered and (for tiles)
 * the strip has laid out, so the first `focusBoard` right after a switch
 * returns false. Returns a cancel function.
 */
export function retryEachFrame(
  attempt: () => boolean,
  maxFrames: number,
  schedule: (cb: () => void) => number = (cb) => requestAnimationFrame(cb),
  cancel: (handle: number) => void = (h) => cancelAnimationFrame(h)
): () => void {
  let frames = 0;
  let handle: number | null = null;
  const tick = () => {
    handle = null;
    if (attempt()) return;
    frames += 1;
    if (frames < maxFrames) handle = schedule(tick);
  };
  handle = schedule(tick);
  return () => {
    if (handle !== null) cancel(handle);
  };
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bun test src/lib/studio/kv/kvAgentFocus.test.ts`
Expected: PASS (5 tests).

- [ ] **Step 5: Register the flag**

In `src/lib/featureFlags/constants.ts`, after `KV_IMAGE_EXPAND: "show-kv-image-expand",` add:

```ts
  // KV agentic canvas (spec 2026-09-29) — the KV chat agent editing layers
  // across boards and sizes. Web gates ONLY the run card (contract C7); the
  // api gates the tool + run routes with `feature.flag:kv-agentic-canvas`
  // and decides whether the agent gets canvas tools at all. Fail-CLOSED on
  // web (read via `useExperimentalFeatureEnabled(...) === true`), dev/staging
  // force-on. The key has no `show-` prefix because the cross-service
  // contract fixed it before this registry was consulted — do not rename one
  // side alone.
  KV_AGENTIC_CANVAS: "kv-agentic-canvas",
```

- [ ] **Step 6: Wire the layout**

In `src/components/studio/kv-generator/KvGeneratorLayout.tsx`:

After `import { measureImageSize } from "./measureImageSize";` add:

```ts
import {
  planKvAgentFocus,
  retryEachFrame,
} from "@/lib/studio/kv/kvAgentFocus";
import type { KvAgentFocusTarget } from "@/types/kv/agentRun";
```

After

```ts
  const kvImageExpandEnabled =
    useExperimentalFeatureEnabled(MAJOR_FEATURE_FLAGS.KV_IMAGE_EXPAND) === true;
```

add:

```ts
  // KV agentic canvas — gates the chat's run card only (contract C7).
  const kvAgenticCanvasEnabled =
    useExperimentalFeatureEnabled(MAJOR_FEATURE_FLAGS.KV_AGENTIC_CANVAS) ===
    true;
```

Directly after `handleCanvasModeChange`'s closing

```ts
    [stream, canvasMode, fileId, disarmRegenerate]
  );
```

add (it must come after `handleCanvasModeChange`, which it lists as a dependency):

```ts
  // KV agentic canvas: a run card target → the canvas. Switches to the
  // target's mode when needed (refused mid-stream, like every mode switch),
  // pins a board like the chat's "Editing" chip does, then CENTRES the board
  // or tile surface. The surface may not exist until the switch re-renders
  // and the Resize strip lays out, so the focus retries per frame.
  const agentFocusCancelRef = useRef<(() => void) | null>(null);
  useEffect(() => () => agentFocusCancelRef.current?.(), []);
  const handleFocusAgentTarget = useCallback(
    (target: KvAgentFocusTarget) => {
      const plan = planKvAgentFocus(target, {
        canvasMode,
        generations: stream.generations,
      });
      if (plan.switchToMode) {
        handleCanvasModeChange(plan.switchToMode, { keepPin: true });
      }
      if (plan.pinGenerationId) {
        setViewingGenerationId(plan.pinGenerationId, { explicitPin: true });
      }
      agentFocusCancelRef.current?.();
      agentFocusCancelRef.current = retryEachFrame(
        () => focusApiRef.current?.focusBoard?.(plan.surfaceId) ?? false,
        60
      );
    },
    [canvasMode, stream.generations, handleCanvasModeChange, setViewingGenerationId]
  );
```

In the `<KvChat … />` element, directly before `initialInputValue={kvChatPrompt || undefined}` add:

```tsx
              agentRunCardsEnabled={kvAgenticCanvasEnabled}
              onFocusAgentTarget={handleFocusAgentTarget}
```

- [ ] **Step 7: Re-run the chat + card suites**

Run: `bun test src/lib/studio/kv/kvAgentFocus.test.ts src/components/studio/kv-generator/KvChat.agentRun.test.tsx src/components/studio/kv-generator/KvAgentRunCard.test.tsx`
Expected: PASS (18 tests).

- [ ] **Step 8: Commit**

```bash
git add src/lib/studio/kv/kvAgentFocus.ts src/lib/studio/kv/kvAgentFocus.test.ts src/lib/featureFlags/constants.ts src/components/studio/kv-generator/KvGeneratorLayout.tsx
git commit -m "feat(web): gate KV agent run cards on kv-agentic-canvas and focus their targets

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Verification, build, analytics hand-off

**Files:** none changed (unless a check fails).

**Interfaces:** consumes everything above; produces the evidence for the PR description.

- [ ] **Step 1: Run every new/changed suite, one invocation per group**

```bash
bun test src/hooks/useKvStream.test.ts src/hooks/useKvStream.resizeMarker.test.ts src/hooks/useKvStream.agentRun.test.ts
bun test src/lib/studio/kv/kvAgentToolLabels.test.ts src/lib/studio/kv/kvAgentRunCopy.test.ts src/lib/studio/kv/kvAgentFocus.test.ts
bun test src/services/kv/agentRun.api.test.ts src/components/studio/kv-generator/KvAgentRunCard.test.tsx src/components/studio/kv-generator/KvChat.agentRun.test.tsx
bun test src/components/studio/kv-generator/fabric/useOverlayReconcile.tileText.test.ts
```

Expected: 28, 16, 17 and 2 passing; 0 fail; no `N error` line in any summary. Then run each of the eight new test files ALONE once (`bun test <file>`) and confirm the same per-file counts — a suite that passes in a group but not alone (or vice versa) is the process-global mock hazard, not your code; investigate before moving on. Never pass a directory.

- [ ] **Step 2: File-size check**

Run: `wc -c src/hooks/useKvStream.agentRun.test.ts src/components/studio/kv-generator/KvAgentRunCard.test.tsx src/components/studio/kv-generator/KvChat.agentRun.test.tsx src/components/studio/kv-generator/fabric/useOverlayReconcile.tileText.test.ts src/lib/studio/kv/*.test.ts src/services/kv/agentRun.api.test.ts`
Expected: every file under 20,000 bytes (largest ≈ 10.5 KB, the card test).

- [ ] **Step 3: Type check by baseline diff**

```bash
BASE=$(git merge-base HEAD develop)
git worktree add --detach ../.tsc-base "$BASE"
(cd ../.tsc-base && bun install >/dev/null && ./node_modules/.bin/tsc --noEmit -p . > /tmp/kv-agent-tsc-base.txt 2>&1)
./node_modules/.bin/tsc --noEmit -p . > /tmp/kv-agent-tsc-head.txt 2>&1
for f in src/hooks/useKvStream src/types/studio.ts src/lib/studio/kv/kvAgent src/types/kv/agentRun src/services/kv/api.ts src/services/kv/agentRun src/lib/analytics/kv-agent-events src/components/studio/kv-generator/KvAgentRunCard src/components/studio/kv-generator/KvChat src/components/studio/kv-generator/fabric/useOverlayReconcile src/lib/featureFlags/constants.ts src/components/studio/kv-generator/KvGeneratorLayout.tsx; do
  echo "$f base=$(/usr/bin/grep -c "^$f" /tmp/kv-agent-tsc-base.txt) head=$(/usr/bin/grep -c "^$f" /tmp/kv-agent-tsc-head.txt)"
done
git worktree remove --force ../.tsc-base
```

(`/usr/bin/grep` on purpose: this machine's shell hook rewrites bare `grep` through `rtk`, whose output `-c` cannot count.)

Expected: `head` equals `base` for every line. At plan time the baseline was: `useOverlayReconcile.ts` 9 (Fabric `globalCompositeOperation` typing), `KvGeneratorLayout.tsx` 1 (`KvMotionExportRow`), `src/hooks/useKvStream` 50 (all in `useKvStream.test.ts`, which uses vitest globals without importing them), everything else 0. Any new line in a touched file is yours to fix.

- [ ] **Step 4: Build (node, not bun)**

Run: `node ./node_modules/next/dist/bin/next build`
Expected: completes and prints the route table. (It does not type-check — Step 3 is the type gate.)

- [ ] **Step 5: Colour-token check**

Run: `/usr/bin/grep -nE "#[0-9a-fA-F]{3,8}|rgba?\(" src/components/studio/kv-generator/KvAgentRunCard.tsx`
Expected: no output.

- [ ] **Step 6: Manual e2e (needs the api, ai-service and collab P1 plans landed; flag on in dev/staging automatically)**

1. Open a KV file with one Craft board, a text headline, and three resize sizes (at least one detached, one inheriting). In the KV chat (Craft) send "change the headline to Diskon 50% on every size".
   - Chips read "Reading Canvas" and "Updating Layers" with an "Applied to N targets …" detail; no raw `update_kv_layers`.
   - The board headline AND every inheriting tile's headline change without a reload (Task 7); the detached tile updates within a second (Task 5 refetch).
   - A run card appears under the reply: applied targets, any skipped row with a sentence, any "… now has its own layers (detached)." line.
2. Click a size row in the card → the canvas centres on that tile (from Concept mode it first switches to Craft). Click the board row → board centred and pinned ("Editing …" chip in the composer).
3. Edit one agent-changed layer by hand, then Undo run → confirm copy mentions credits; result line "Undone · N reverted · 1 skipped" with "edited after the run, so it was kept"; your edit survives.
4. Reload the page → the card is still there reading "Undone · …", no Undo button.
5. Second tab open on the same file during step 1 → the board and inheriting tiles update live there too (remote Y update). Known limitation: that tab's detached tile updates only on its next resize-exports refetch (D6).
6. Flag forced off (`window.posthog.featureFlags.override({"kv-agentic-canvas": false})` in production-like env) → no card; chips still labelled.

- [ ] **Step 7: Analytics hand-off (needs Daffa — signed-in steps)**

1. Create/confirm the PostHog flag `kv-agentic-canvas` (project FRnD_OS / 389744) with the name "KV Agentic Canvas — Gates the KV chat agent's canvas tools and run/undo routes on api and the run card on web (KvChat). When OFF: the KV chat behaves exactly as today. Default OFF." (the api plan may already have done this — check first).
2. Add these rows to the Lark taxonomy doc (https://fcn.sg.larksuite.com/wiki/DMbKwqbzQiWrXSkha5zl1wFvgod), section KV Studio → KV agent, status Active:

| Event | Trigger | Props |
|---|---|---|
| `kv_agent.run_completed` | A run card first reads `completed` for a run that arrived on this session's stream (not on reload); once per run | `file_id, run_id, source (app\|mcp), op_count, target_count, skipped_count, detached_count, timestamp` |
| `kv_agent.run_undone` | Undo run succeeded with status `undone` (not `already_undone`) | `file_id, run_id, reverted, skipped_count, timestamp` |
| `kv_agent.run_undo_failed` | Undo request failed | `file_id, run_id, reason (api error code or request_failed), http_status, timestamp` |
| `kv_agent.run_target_focused` | A target row on the run card was clicked | `file_id, run_id, target_kind (board\|size), timestamp` |

3. Verify all four in PostHog Live Events during the Step 6 run, with base context (user/workspace/brand) present.

- [ ] **Step 8: Push and open the PR (only when Daffa asks)**

PR title: `feat(web): KV agentic canvas P1 — run card, undo, tool chips`. Body links: spec, contracts, this plan; names the flag `kv-agentic-canvas`, default OFF, cleanup condition "remove the gate once P4 ships and the flag has been 100% for two weeks"; lists D1–D6 below for the api/ai-service owners. End the body with the attribution line from the session reminder.

---

## Contract deviations

No contract name, route, field or payload is renamed by this plan. The items below are gaps or ambiguities the web side found, each with a proposed resolution for the owning plan.

- **D1 — C5 response envelope is unspecified.** Every other KV route wraps in Laravel's `{ message, data }`; C5 shows the bare view. *Web:* accepts both (`unwrapAgentBody`, Task 3). *Proposal (api plan):* wrap in `{ message, data }` like the neighbouring studio routes, and write it into C5.
- **D2 — `agent_run_id` must reach `chat_history`, and it arrives after the row is written.** Web hydrates from `GET v1/studio/files/{id}` → `data.chat_history[]` (built in `api/app/Http/Controllers/Api/Studio/KvGeneratorFileController.php:88-255`), not from `kv_chat_history`. ai-service emits `kv_agent_run` AFTER `message`, and api creates the assistant row while handling `message` (`ChatService.php:1917-1936`). *Proposal (api plan):* (a) when `kv_agent_run` arrives, update that same `$aiMessage` row's `message.agent_run_id` (or defer the insert to `done`); (b) add `'agent_run_id' => $msg['agent_run_id'] ?? null` to the plain assistant entry in `show()`'s serializer; (c) an agent turn whose final text is empty currently creates NO row (`if ($text !== '')`), so its run card and chips would vanish on reload — create the row when a run exists.
- **D3 — Tool labels.** C4 fixes tool names to the MCP twins and ai-service's `_tool_name_slug` passes them through raw, so web owns the human label (Task 2). *Proposal (ai-service plan):* keep sending the raw names; if it ever maps them, use exactly "Reading Canvas", "Updating Layers", "Adding Layer", "Removing Layers", "Undoing Agent Run" (web accepts both forms). Please keep the write tool's `tool_result` the C3.3 JSON object — web derives the chip detail from it; a Python-repr string degrades to no detail (Review Focus 2).
- **D4 — Event names.** Spec §9 lists `kv_agent_run_completed`, `kv_agent_run_undone`. The web analytics skill puts a new multi-event domain under dot-namespacing (sibling `deck_agent.*`), so they ship as `kv_agent.run_completed` and `kv_agent.run_undone`, plus `kv_agent.run_undo_failed` (attempt/outcome pair) and `kv_agent.run_target_focused`. *Proposal:* update spec §9's names; P2 adds `kv_agent.plan_shown` / `plan_confirmed` / `plan_cancelled` to the same module.
- **D5 — `kv_agent_targets_suggested` dropped from P1.** The only client-visible signal is the generic `kv_question_card {label, options}` frame; nothing distinguishes a target-suggestion card (spec D3) from any other question card, and `kv_generator.assistant_card_shown {card_type: "question"}` already fires for it. *Proposal (P2 contract):* add `purpose: "targets"` to ai-service's `question_card` event, api's relay and persisted payload; web then fires `kv_agent.targets_suggested` in the existing `kv_question_card` handler.
- **D6 — Detached size tiles are not live in other tabs.** Agent writes to detached tiles are REST rows; the tab that ran the agent refetches them (Task 5), but another open tab only sees them on its next resize-exports refetch (the resize SSE is open only while a tile renders; `refetchOnWindowFocus` is off). Board layers and inheriting tiles ARE live everywhere (Y.Doc). *Proposal (api plan, optional for P1):* after a detached-tile overlay write, broadcast on the existing resize-export realtime channel so every tab invalidates `["kv-resize-exports", fileId]`.
- **Note for the collab/api plans (not a web change):** the web Y.Doc overlay map stores the board binding as `boardGenerationId` (camelCase, `src/lib/kv/yjsSerializer.ts:115-116, 155`) and text in `payload.content` (`src/lib/kv/yjsBinding.ts:495`); payload values are plain JSON, not nested Y types (`yjsSerializer.ts:164-166`). C0's Layer JSON (`board_generation_id`) is therefore a wire shape that collab must map to and from the doc key, and C3.4's `set.text` must land in `payload.content`. A collab write of `board_generation_id` into the doc would be read by web as unbound (painted on the active board).
- **Note (C7 naming):** the web flag skill wants a `show-` prefix; the contract key `kv-agentic-canvas` is kept verbatim on both sides (commented in `constants.ts`).

## Self-review

- **Spec coverage (§9 web items for P1):** chips with human labels → Task 2; run card with ✓ applied / ⚠ skipped + reason / detached notice → Tasks 4-5; clicking a target focuses the canvas → Task 8; Undo run with confirmation (credits copy) and result line → Task 5; survives reload via the stored run id → Tasks 1 + 6; flag gate on the card → Tasks 6 + 8; analytics + taxonomy row → Tasks 5 + 9. Spec §4.2 step 4 "open browsers receive the change as a normal remote Y update" → verified in Grounding, one gap fixed (Task 7), detached tiles handled (Task 5, D6). Out of P1 by the contracts: plan card, per-tile job progress, `kv_agent_plan_*`.
- **Placeholders:** none — every code step carries the code; every command has an expected result taken from a real run.
- **Type consistency:** `ChatMessageMeta.agentRun {runId, live}` (Task 1) is what `KvChat` reads (Task 6); `KvAgentFocusTarget {kind, id}` (Task 3) is what the card emits (Task 5), `KvChat` forwards (Task 6) and `planKvAgentFocus` consumes (Task 8); `KvAgentRunApi` defaults to `getKvAgentRun` / `undoKvAgentRun` (Task 3); `resizeExportsQueryKey(fileId)` is the existing export of `useResizeExports.ts`. Tool-name strings match C3/C4 exactly.
- **Review Focus:** all five lines have tests in their owning tasks (Tasks 5, 2, 5, 8, 3).

## Execution

Recommended: **Subagent-driven** — nine tasks with a strict interface chain (Task 1 → 6 → 8 and 3 → 5 → 6 → 8), and two of them (Tasks 1 and 7) touch hot shared code (`useKvStream`, the Fabric reconcile) where a fresh reviewer per task is worth the cost.

