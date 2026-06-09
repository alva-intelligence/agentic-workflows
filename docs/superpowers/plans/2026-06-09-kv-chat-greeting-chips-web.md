# KV Chat Greeting Chips — Web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the KV chat empty-state's static three-chip array with a computed list — two static chips, a brand-aware chip (`Brainstorm a campaign for {brandName}` or fallback), and a fourth LLM-generated suggestion chip fetched only while the chat is empty.

**Architecture:** A new `getKvChatSuggestion(fileId)` axios wrapper hits `GET v1/studio/files/{fileId}/chat-suggestion` and unwraps `data.suggestion` (string | null). A `useKvChatSuggestion(fileId, enabled)` TanStack Query hook (session-cached, `staleTime: Infinity`) wraps it, enabled only when the empty state is visible. `KvChat` gains a `brandName` prop (threaded from `KvGeneratorLayout`, where `brandName` is already resolved via `getBrandDetail`), and its `GreetingState` builds chips from a pure helper `buildGreetingChips({ brandName })` (static + brand-aware) plus the dynamic suggestion chip with a loading skeleton in slot 4.

**Tech Stack:** Next.js 16, React 19, TypeScript, TanStack Query v5, Vitest

---

## Context (verified against real code)

- **Empty-state detection:** `KvChat` receives a `hasMessages: boolean` prop and renders `hasMessages ? <MessagesList … /> : <GreetingState … />` (`KvChat.tsx:347`). In `KvGeneratorLayout.tsx:142`, `hasMessages = stream.messages.length > 0`. **Chat is empty when `!hasMessages`**, which is exactly when `GreetingState` mounts. The query's `enabled` is therefore tied to "the GreetingState is rendered" — passed in as a prop from `KvChat` computed as `!hasMessages`.
- **Current chips:** `GREETING_CHIPS` is a module-level `string[]` (`KvChat.tsx:69-73`) mapped in `GreetingState` (`KvChat.tsx:442-451`) into `<Button variant="secondary" size="small" onClick={() => onPickChip(chip)}>{chip}</Button>`.
- **`onPickChip`:** Wired at `KvChat.tsx:358-365` — `(text) => { if (stream.isStreaming) return; stream.send(text, {...}); }`. Unchanged by this feature.
- **api.ts GET/unwrap pattern:** `const { data } = await axiosInstance.get(\`v1/studio/files/${fileId}/…\`); return unwrap(data);` where `unwrap<T>(response: { message?: string; data: T }): T => response.data` (`api.ts:55-57`). Paths are relative (no leading slash), e.g. `v1/studio/files/${fileId}/resize-exports`.
- **Button types:** `variant="secondary"`, `size="small"` are valid (`ButtonVariant` / `ButtonSize` in `Button.tsx`).
- **`brandName` in layout:** `const brandName = brandQuery.data?.data?.name ?? null;` (`KvGeneratorLayout.tsx:127`), already passed to `KvCanvasTopNav` (`:992`). The `<KvChat … />` render block is `KvGeneratorLayout.tsx:1028-1052`.

> Run all test commands from `web/`. Test runner: `npx vitest run <path>`. Typecheck: `npx tsc --noEmit -p tsconfig.json 2>&1 | grep -E '<touched files>'` (no output = clean for those files).
>
> **IMPLEMENT-ONLY note:** if running without test execution, still author every test file as written — just skip the `npx vitest run` steps. Keep impl steps separable.

---

## Task 1 — `getKvChatSuggestion(fileId)` in `api.ts`

**Files:**
- `web/src/services/kv/api.ts` (impl)
- `web/src/services/kv/api.test.ts` (test — append a new `describe`)

- [ ] 1.1 Write the failing test. Append to `web/src/services/kv/api.test.ts`:

```ts
import { getKvChatSuggestion } from "@/services/kv/api";

describe("getKvChatSuggestion", () => {
  it("GETs the chat-suggestion endpoint and unwraps data.suggestion", async () => {
    (axiosInstance.get as any).mockResolvedValue({
      data: { data: { suggestion: "Sketch a bold launch poster" } },
    });

    const suggestion = await getKvChatSuggestion("file-1");

    expect(axiosInstance.get).toHaveBeenCalledWith(
      "v1/studio/files/file-1/chat-suggestion",
    );
    expect(suggestion).toBe("Sketch a bold launch poster");
  });

  it("returns null when the backend reports no suggestion", async () => {
    (axiosInstance.get as any).mockResolvedValue({
      data: { data: { suggestion: null } },
    });

    const suggestion = await getKvChatSuggestion("file-1");
    expect(suggestion).toBeNull();
  });
});
```

- [ ] 1.2 Run — expect FAIL (`getKvChatSuggestion` is not exported yet):

```
npx vitest run src/services/kv/api.test.ts
```

- [ ] 1.3 Minimal impl. Add to `web/src/services/kv/api.ts` (after the Overlays / Studio-file helpers section, near `patchStudioFileCanvasMode`):

```ts
// ── KV Chat Suggestion ────────────────────────

/** Fetch the LLM-generated greeting-chip suggestion for a studio file.
 *  Returns the inner `suggestion` (string | null). The endpoint never
 *  errors the empty state — it returns `{ data: { suggestion: null } }`
 *  on any ai-service failure, so callers only need to handle null. */
export async function getKvChatSuggestion(
  fileId: string,
): Promise<string | null> {
  const { data } = await axiosInstance.get(
    `v1/studio/files/${fileId}/chat-suggestion`,
  );
  return unwrap<{ suggestion: string | null }>(data).suggestion;
}
```

- [ ] 1.4 Run — expect PASS:

```
npx vitest run src/services/kv/api.test.ts
```

- [ ] 1.5 Typecheck:

```
npx tsc --noEmit -p tsconfig.json 2>&1 | grep -E 'services/kv/api'
```

- [ ] 1.6 Commit: `feat(web): add getKvChatSuggestion api wrapper`

---

## Task 2 — `useKvChatSuggestion(fileId, enabled)` hook

**Files:**
- `web/src/lib/studio/kv/useKvChatSuggestion.ts` (impl — new)
- `web/src/lib/studio/kv/useKvChatSuggestion.test.ts` (test — new)

- [ ] 2.1 Write the failing test. Create `web/src/lib/studio/kv/useKvChatSuggestion.test.ts` (mirrors `useResizeExports.test.ts` — mock `@/services/kv/api`, `renderHook` + `QueryClientProvider`):

```ts
import { describe, it, expect, vi, beforeEach } from "vitest";
import { renderHook, waitFor } from "@testing-library/react";
import { createElement } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useKvChatSuggestion } from "./useKvChatSuggestion";

vi.mock("@/services/kv/api", () => ({
  getKvChatSuggestion: vi.fn(),
}));

import { getKvChatSuggestion } from "@/services/kv/api";

beforeEach(() => vi.clearAllMocks());

function makeWrapper() {
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });
  const wrapper = ({ children }: { children: React.ReactNode }) =>
    createElement(QueryClientProvider, { client: qc }, children);
  return { qc, wrapper };
}

describe("useKvChatSuggestion", () => {
  it("fetches and returns the suggestion when enabled", async () => {
    (getKvChatSuggestion as any).mockResolvedValue("Sketch a bold launch poster");
    const { wrapper } = makeWrapper();

    const { result } = renderHook(
      () => useKvChatSuggestion("file-1", true),
      { wrapper },
    );

    await waitFor(() => expect(result.current.suggestion).toBe("Sketch a bold launch poster"));
    expect(getKvChatSuggestion).toHaveBeenCalledWith("file-1");
  });

  it("does not fetch when disabled", async () => {
    (getKvChatSuggestion as any).mockResolvedValue("nope");
    const { wrapper } = makeWrapper();

    const { result } = renderHook(
      () => useKvChatSuggestion("file-1", false),
      { wrapper },
    );

    // Disabled query never fires and never resolves a suggestion.
    expect(getKvChatSuggestion).not.toHaveBeenCalled();
    expect(result.current.suggestion).toBeNull();
    expect(result.current.isLoading).toBe(false);
  });

  it("exposes null suggestion when the backend returns null", async () => {
    (getKvChatSuggestion as any).mockResolvedValue(null);
    const { wrapper } = makeWrapper();

    const { result } = renderHook(
      () => useKvChatSuggestion("file-1", true),
      { wrapper },
    );

    await waitFor(() => expect(result.current.isLoading).toBe(false));
    expect(result.current.suggestion).toBeNull();
  });
});
```

- [ ] 2.2 Run — expect FAIL (module does not exist):

```
npx vitest run src/lib/studio/kv/useKvChatSuggestion.test.ts
```

- [ ] 2.3 Minimal impl. Create `web/src/lib/studio/kv/useKvChatSuggestion.ts`:

```ts
import { useQuery } from "@tanstack/react-query";

import { getKvChatSuggestion } from "@/services/kv/api";

const QUERY_KEY = (fileId: string) => ["kv-chat-suggestion", fileId] as const;

/**
 * Fetches the LLM-generated greeting-chip suggestion for a studio file.
 *
 * `enabled` should be wired to "the chat empty state is visible" (no
 * messages) so the call fires once per file-open and never again after a
 * conversation exists. `staleTime: Infinity` makes it a session cache —
 * re-renders of the empty state never refetch.
 *
 * Returns `{ suggestion: string | null, isLoading }`. The api wrapper
 * already collapses every ai-service failure to `null`, so callers only
 * branch on string-vs-null.
 */
export function useKvChatSuggestion(fileId: string, enabled: boolean) {
  const query = useQuery({
    queryKey: QUERY_KEY(fileId),
    queryFn: () => getKvChatSuggestion(fileId),
    enabled: Boolean(fileId) && enabled,
    staleTime: Infinity,
  });

  return {
    suggestion: query.data ?? null,
    isLoading: query.isLoading && query.fetchStatus !== "idle",
  };
}
```

> Note on `isLoading`: TanStack Query v5 reports `isLoading === true` for a *disabled* query that has never run (status `pending`, fetchStatus `idle`). Gating on `fetchStatus !== "idle"` ensures the disabled path reports `isLoading: false` (asserted in test 2.2's "does not fetch when disabled").

- [ ] 2.4 Run — expect PASS:

```
npx vitest run src/lib/studio/kv/useKvChatSuggestion.test.ts
```

- [ ] 2.5 Typecheck:

```
npx tsc --noEmit -p tsconfig.json 2>&1 | grep -E 'useKvChatSuggestion'
```

- [ ] 2.6 Commit: `feat(web): add useKvChatSuggestion query hook`

---

## Task 3 — `buildGreetingChips` pure helper

A small pure helper that returns the static + brand-aware base chips (chips 1–3). Unit-tested in isolation; the dynamic chip + skeleton are JSX impl in Task 4.

**Files:**
- `web/src/components/studio/kv-generator/greetingChips.ts` (impl — new)
- `web/src/components/studio/kv-generator/greetingChips.test.ts` (test — new)

- [ ] 3.1 Write the failing test. Create `web/src/components/studio/kv-generator/greetingChips.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import { buildGreetingChips } from "./greetingChips";

describe("buildGreetingChips", () => {
  it("returns the two static chips plus a brand-aware chip when brandName is present", () => {
    expect(buildGreetingChips({ brandName: "XG" })).toEqual([
      "Brainstorm an idea for this project",
      "Start making a key visual from a sketch",
      "Brainstorm a campaign for XG",
    ]);
  });

  it("falls back to the static brand chip when brandName is null", () => {
    expect(buildGreetingChips({ brandName: null })).toEqual([
      "Brainstorm an idea for this project",
      "Start making a key visual from a sketch",
      "Explore brand ideas",
    ]);
  });

  it("falls back when brandName is an empty / whitespace string", () => {
    expect(buildGreetingChips({ brandName: "   " })[2]).toBe("Explore brand ideas");
  });
});
```

- [ ] 3.2 Run — expect FAIL (module does not exist):

```
npx vitest run src/components/studio/kv-generator/greetingChips.test.ts
```

- [ ] 3.3 Minimal impl. Create `web/src/components/studio/kv-generator/greetingChips.ts`:

```ts
/** Builds the static + brand-aware greeting chips (slots 1–3) for the KV
 *  chat empty state. The dynamic LLM-suggestion chip (slot 4) is appended
 *  in the component, not here, because it depends on async query state. */
export function buildGreetingChips({
  brandName,
}: {
  brandName: string | null;
}): string[] {
  const brand = (brandName ?? "").trim();
  const brandChip = brand
    ? `Brainstorm a campaign for ${brand}`
    : "Explore brand ideas";
  return [
    "Brainstorm an idea for this project",
    "Start making a key visual from a sketch",
    brandChip,
  ];
}
```

- [ ] 3.4 Run — expect PASS:

```
npx vitest run src/components/studio/kv-generator/greetingChips.test.ts
```

- [ ] 3.5 Typecheck:

```
npx tsc --noEmit -p tsconfig.json 2>&1 | grep -E 'greetingChips'
```

- [ ] 3.6 Commit: `feat(web): add buildGreetingChips helper for brand-aware chips`

---

## Task 4 — Wire the chips into `KvChat` (brandName prop + dynamic chip + skeleton)

This is the JSX integration: thread `brandName` into `KvChat`, fire `useKvChatSuggestion` only in the empty state, and render the four-chip list (static 1–3 from `buildGreetingChips`, dynamic slot 4 with skeleton-while-loading / omit-on-null).

**Files:**
- `web/src/components/studio/kv-generator/KvChat.tsx` (impl)
- `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx` (impl — pass `brandName`)

> No new component test for this task — the testable logic (chip list + fallback) lives in `buildGreetingChips` (Task 3) and the hook (Task 2). The JSX wiring is verified by typecheck + manual run. (`KvChat` is a large stateful component with SSE/stream deps; a render test would need heavy mocking for no extra coverage over Tasks 2–3.)

- [ ] 4.1 Remove the stale module-level `GREETING_CHIPS`. Delete `KvChat.tsx:69-73`:

```ts
const GREETING_CHIPS = [
  "Brainstorm an idea for this project",
  "Start making a key visual from a sketch",
  "Who is XG?",
];
```

- [ ] 4.2 Add imports near the top of `KvChat.tsx` (with the other relative imports, e.g. after the `./styles` import block):

```ts
import { useKvChatSuggestion } from "@/lib/studio/kv/useKvChatSuggestion";
import { buildGreetingChips } from "./greetingChips";
```

- [ ] 4.3 Add `brandName` to the `Props` type. In the `type Props = { … }` block (`KvChat.tsx:75`), add after `title`:

```ts
type Props = {
  title: string;
  /** Active brand name for the brand-aware greeting chip (slot 3). Null
   *  when the file/project has no brand — the chip falls back to the
   *  static "Explore brand ideas". Resolved upstream via getBrandDetail. */
  brandName: string | null;
  stream: Stream;
  hasMessages: boolean;
  // …rest unchanged
```

- [ ] 4.4 Destructure `brandName` in the `KvChat` function signature (`KvChat.tsx:151`), after `title`:

```ts
export function KvChat({
  title,
  brandName,
  stream,
  hasMessages,
  // …rest unchanged
}: Props) {
```

- [ ] 4.5 Pass `brandName` + the empty flag down to `GreetingState`. In the render branch (`KvChat.tsx:356-366`), replace the `GreetingState` call:

```tsx
) : (
  <GreetingState
    brandName={brandName}
    fileId={fileId}
    onPickChip={(text) => {
      if (stream.isStreaming) return;
      stream.send(text, {
        aspectRatio: aspectRatio ?? undefined,
        useBrandKnowledge: useBrandKnowledge ?? undefined,
      });
    }}
  />
)}
```

> `GreetingState` only mounts when `!hasMessages`, so the empty-state is implicit by virtue of being rendered. The hook's `enabled` is therefore `Boolean(fileId)` inside `GreetingState` (the component existing == chat is empty).

- [ ] 4.6 Update `GreetingState` to accept the new props and render the computed chips. Replace the whole `GreetingState` function (`KvChat.tsx:420-455`):

```tsx
function GreetingState({
  brandName,
  fileId,
  onPickChip,
}: {
  brandName: string | null;
  fileId?: string;
  onPickChip: (text: string) => void;
}) {
  // Personalise the greeting with the logged-in user's first name, matching
  // Figma 5022:10641 ("Good morning, Sabrina"). Falls back to a plain
  // greeting if the user store isn't hydrated yet (SSR / first paint).
  const userName = useAuth((s) => s.user?.name);
  const firstName = (userName ?? "").trim().split(/\s+/)[0] ?? "";
  const greeting = firstName
    ? `${greetingPrefix()}, ${firstName}`
    : greetingPrefix();

  // Static + brand-aware chips (slots 1–3) — always rendered immediately.
  const baseChips = buildGreetingChips({ brandName });

  // Dynamic LLM-suggestion chip (slot 4). The query is enabled simply by
  // virtue of this component being mounted: GreetingState only renders in
  // the empty state, so "rendered" == "chat is empty". A missing fileId
  // (shouldn't happen in the live layout) disables it gracefully.
  const { suggestion, isLoading } = useKvChatSuggestion(
    fileId ?? "",
    Boolean(fileId),
  );

  return (
    <div className="flex flex-1 flex-col items-center justify-center gap-8 p-4">
      <div className="flex max-w-[446px] flex-col items-center gap-4 text-center">
        <h2 className="font-generalSans text-displayXsMedium leading-[1.2] tracking-[-0.36px] text-text-inverse">
          {greeting}
        </h2>
        <p className="font-geist text-textMdRegular leading-[1.4] tracking-[-0.16px] text-text-inverse-subtle">
          How do you want to make today?
        </p>
      </div>

      <div className="flex w-full flex-col items-center gap-2 px-2">
        {baseChips.map((chip) => (
          <Button
            key={chip}
            variant="secondary"
            size="small"
            onClick={() => onPickChip(chip)}
          >
            {chip}
          </Button>
        ))}

        {/* Slot 4 — dynamic suggestion. Skeleton pill while loading; the
            chip when a non-empty suggestion resolves; nothing on null. */}
        {isLoading ? (
          <div
            aria-hidden
            className="h-9 w-48 animate-pulse rounded-full bg-[rgba(255,255,255,0.06)]"
          />
        ) : suggestion && suggestion.trim().length > 0 ? (
          <Button
            variant="secondary"
            size="small"
            onClick={() => onPickChip(suggestion)}
          >
            {suggestion}
          </Button>
        ) : null}
      </div>
    </div>
  );
}
```

> The skeleton pill height `h-9` matches the `size="small"` Button height; width `w-48` is a neutral placeholder. Adjust if the Button small-size height differs — keep it a muted, non-interactive pill.

- [ ] 4.7 Pass `brandName` from `KvGeneratorLayout`. In the `<KvChat … />` render (`KvGeneratorLayout.tsx:1028-1052`), add the prop (just after `title=`):

```tsx
<KvChat
  title={file?.project_id ? title : "New Chat"}
  brandName={brandName}
  stream={stream}
  hasMessages={hasMessages}
  // …rest unchanged
/>
```

> `brandName` already exists at `KvGeneratorLayout.tsx:127` (`brandQuery.data?.data?.name ?? null`) — no new resolution needed.

- [ ] 4.8 Re-run Tasks 1–3 suites to confirm no regression in the touched files:

```
npx vitest run src/services/kv/api.test.ts src/lib/studio/kv/useKvChatSuggestion.test.ts src/components/studio/kv-generator/greetingChips.test.ts
```

Expect PASS.

- [ ] 4.9 Typecheck the touched files:

```
npx tsc --noEmit -p tsconfig.json 2>&1 | grep -E 'KvChat|KvGeneratorLayout|greetingChips|useKvChatSuggestion'
```

Expect no output (clean).

- [ ] 4.10 Commit: `feat(web): brand-aware + dynamic suggestion chips in KV chat empty state`

---

## Done criteria (web slice)

- "Who is XG?" is gone; the module-level `GREETING_CHIPS` is removed.
- Slot 3 renders `Brainstorm a campaign for {brandName}` when `brandName` is present, else `Explore brand ideas`.
- Slot 4 renders the LLM suggestion when it's a non-empty string, shows a muted skeleton pill while loading, and is omitted entirely on null/empty.
- `useKvChatSuggestion` fires only while the empty state (`GreetingState`) is mounted — i.e. `stream.messages.length === 0` — and is session-cached (`staleTime: Infinity`).
- `onPickChip` behavior is unchanged (chip text sent as the user's message).
- Touched-file typecheck is clean; Tasks 1–3 vitest suites pass.
