# askFRND → KV Studio handoff — web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render an "Edit in KV Studio" card under every askFRND-generated image that creates a KV file, imports the image as the Craft base, and lands the user on the canvas.

**Architecture:** `MarkdownRenderer` gains one optional `imageFooter` render-prop and stays ignorant of KV Studio; `ChatMessage` supplies it. All decision logic lives in pure functions (`kvHandoff.ts`) so it is testable without a DOM, and the two-call orchestration lives in `performKvHandoff.ts` so the card only owns presentation and state.

**Tech Stack:** Next.js 16, React 19, TypeScript, Tailwind, Zustand, TanStack Query v5, Bun, vitest + @testing-library/react, PostHog.

**Spec:** `docs/superpowers/specs/2026-08-12-askfrnd-kv-handoff-design.md`
**Depends on:** `docs/superpowers/plans/2026-08-12-askfrnd-kv-handoff-api.md` Task 1 (`size` optional). Tasks 1–3 and 5 here do not need it; Task 4's runtime path does.

## Global Constraints

- Branch: `feature/daffa/vc-askfrnd-kv-handoff`, cut from `develop`.
- **Test runner: `bunx vitest run <path>`.** Write tests against `vitest` (`import { describe, it, expect, vi } from "vitest"`), which is what 225 of the repo's 321 test files use, including every chat component test. `bun test` is for the 83 files importing `bun:test` and does NOT provide `vi.advanceTimersByTimeAsync` or a working RTL `screen` — verified 2026-08-12: `bunx vitest run src/components/chat/DeckLinkPreview.test.tsx` → 5 pass, `bun test` on the same file → 5 fail.
- RTL's `screen` is fine under vitest. Use it.
- **There is no type gate.** `next.config.js` sets `typescript: { ignoreBuildErrors: true }` and `bunx tsc --noEmit` has a large pre-existing baseline. Verify types by grepping `tsc` output for only the files you touched (Task 8).
- All user-facing copy is **English**, matching every other askFRND string. Card title: `Edit in KV Studio`. Card subtitle: `Use this image as a key visual base`.
- Every new component's root element must be **phrasing content** (`<button>`, `<span>`) — the card renders inside a markdown `<p>`, so a `<div>` root would be invalid nesting. `GeneratedFileCard` already does this (an `<a>` with `<span>` children); follow it.
- No new feature flag. Gate on the existing `MAJOR_FEATURE_FLAGS.KV_GENERATOR`.

## File Structure

| File | Responsibility |
|---|---|
| `src/store/useChatStore.ts` (modify) | carry `origin_brand_id` on `ChatSession` so brand survives a reload |
| `src/lib/chat/kvHandoff.ts` (create) | pure: MIME whitelist, eligibility predicate, brand resolution |
| `src/lib/chat/measureRemoteImage.ts` (create) | pure-ish: read natural w/h off a CORS-less URL |
| `src/lib/analytics/askfrnd-kv-handoff-events.ts` (create) | the two PostHog captures |
| `src/lib/chat/performKvHandoff.ts` (create) | orchestration: measure → create → import → route |
| `src/services/kv/api.ts` (modify) | `size` becomes optional on the import body type |
| `src/components/chat/KvHandoffBrandPicker.tsx` (create) | brand picker modal |
| `src/components/chat/KvHandoffCard.tsx` (create) | the card: gating, states, click |
| `src/components/base/MarkdownRenderer.tsx` (modify) | `imageFooter` render-prop |
| `src/components/chat/ChatMessage.tsx` (modify) | supply the footer for AI image turns |

## Refinements to the spec, made deliberately

Two places where this plan is more precise than the spec. Both are improvements, not drift:

1. **Measure before create.** The spec listed `create → measure → import`. This plan measures first, so a measurement failure creates nothing at all and the orphan-file window shrinks to the import step alone.
2. **Four brand-resolution values, not three.** The spec's analytics enum was `url | thread | picker`. A workspace-level user with exactly one accessible brand is auto-resolved with no picker shown, and labelling that `picker` would make the metric lie. The enum is `url | thread | single | picker`.

---

### Task 1: Carry `origin_brand_id` on the chat session

The brand a thread started from is returned by the thread-detail API (`ThreadDetail.origin_brand_id`, `src/types/response.ts:187`) but discarded when the store maps it into a `ChatSession`. Without this, a chat opened from a brand page loses its brand on reload and needlessly shows the picker.

**Files:**
- Modify: `src/store/useChatStore.ts` — `ChatSession` interface (~line 239), `loadThreadDetail` mapping (~line 1053), `createNewChatWithMessageStream` session seed (~line 2603)
- Test: `src/store/useChatStore.originBrand.test.ts`

**Interfaces:**
- Produces: `ChatSession.origin_brand_id?: string | null`. Task 6 reads it via `useChatStore`.

- [ ] **Step 1: Write the failing test**

Create `src/store/useChatStore.originBrand.test.ts`:

```ts
import { beforeEach, expect, it, vi } from "vitest";

// Verified 2026-08-12: mocking `@/services/query` alone is enough — the store
// imports and `loadThreadDetail` runs under vitest with no other mocks.
const getThreadDetail = vi.fn();
vi.mock("@/services/query", () => ({
  getThreadDetail: (...a: unknown[]) => getThreadDetail(...a),
  getPublicThreads: vi.fn(),
}));

import { useChatStore } from "./useChatStore";

const THREAD_ID = "thread-1";

function threadDetail(originBrandId: string | null) {
  return {
    data: {
      id: THREAD_ID,
      title: "Serum shot",
      is_public: false,
      is_owner: true,
      description: "",
      thread_type: "chat",
      created_at: "2026-08-12T00:00:00Z",
      updated_at: "2026-08-12T00:00:00Z",
      chat_history: [],
      origin_brand_id: originBrandId,
      origin_brand_name: originBrandId ? "frndGlow" : null,
    },
  };
}

beforeEach(() => {
  getThreadDetail.mockReset();
  useChatStore.setState({ chatSessions: [], currentChatId: null });
});

it("keeps the thread's origin brand on the session", async () => {
  getThreadDetail.mockResolvedValue(threadDetail("brand-42"));

  await useChatStore.getState().loadThreadDetail(THREAD_ID);

  const session = useChatStore
    .getState()
    .chatSessions.find((c) => c.id === THREAD_ID);
  expect(session?.origin_brand_id).toBe("brand-42");
});

it("stores null when the thread has no origin brand", async () => {
  getThreadDetail.mockResolvedValue(threadDetail(null));

  await useChatStore.getState().loadThreadDetail(THREAD_ID);

  const session = useChatStore
    .getState()
    .chatSessions.find((c) => c.id === THREAD_ID);
  expect(session?.origin_brand_id).toBeNull();
});
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd web && bunx vitest run src/store/useChatStore.originBrand.test.ts
```

Expected: FAIL — the first test gets `undefined` instead of `"brand-42"`, because the `chatSession` literal at `useChatStore.ts:1053` never copies the field across.

- [ ] **Step 3: Add the field to `ChatSession`**

In `src/store/useChatStore.ts`, inside `export interface ChatSession` (after `branched_from`):

```ts
  /** Brand the thread was started from (`ThreadDetail.origin_brand_id`).
   *  Null for workspace-level chats. Read by the askFRND → KV Studio handoff
   *  so a reloaded brand-page chat resolves its brand without a picker. */
  origin_brand_id?: string | null;
```

- [ ] **Step 4: Populate it in `loadThreadDetail`**

In the `const chatSession: ChatSession = {` literal, after `branched_from`:

```ts
        origin_brand_id: threadDetail.origin_brand_id ?? null,
```

- [ ] **Step 5: Populate it for a brand-new thread**

In `createNewChatWithMessageStream`, where the temp session is seeded:

```ts
      set((state) => ({
        chatSessions: [
          {
            ...tempChat,
            messages: branchedMessages,
            origin_brand_id: originBrandId ?? null,
          },
          ...state.chatSessions,
        ],
        currentChatId: tempChat.id,
      }));
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
cd web && bunx vitest run src/store/useChatStore.originBrand.test.ts
```

Expected: 2 passed.

- [ ] **Step 7: Commit**

```bash
cd web && git add src/store/useChatStore.ts src/store/useChatStore.originBrand.test.ts
git commit -m "feat(web): keep a thread's origin brand on the chat session

ThreadDetail returns origin_brand_id but the store dropped it, so a chat
opened from a brand page lost its brand on reload. Needed by the askFRND →
KV Studio handoff to resolve a brand without prompting."
```

---

### Task 2: Pure eligibility and brand-resolution logic

**Files:**
- Create: `src/lib/chat/kvHandoff.ts`
- Test: `src/lib/chat/kvHandoff.test.ts`

**Interfaces:**
- Produces:
  - `KV_HANDOFF_MIME_TYPES: readonly ["image/png", "image/jpeg", "image/webp"]`
  - `type KvHandoffMimeType = "image/png" | "image/jpeg" | "image/webp"`
  - `isKvHandoffMime(mime: string): mime is KvHandoffMimeType`
  - `type KvHandoffBrandSource = "url" | "thread" | "single" | "picker"`
  - `type KvHandoffBrandResolution = { kind: "resolved"; brandId: string; source: KvHandoffBrandSource } | { kind: "picker"; candidateBrandIds: string[] } | { kind: "unavailable" }`
  - `type KvHandoffFailureStage = "measure" | "create" | "import"`
  - `isKvHandoffEligible(input: KvHandoffEligibilityInput): boolean`
  - `resolveKvHandoffBrand(input: KvHandoffBrandInput): KvHandoffBrandResolution`
- Consumed by: Task 4 (`KvHandoffMimeType`, `KvHandoffFailureStage`), Task 6 (all of it).

`KvHandoffFailureStage` lives here, not in the analytics module, so the orchestration does not have to depend on analytics for its own error type.

- [ ] **Step 1: Write the failing test**

Create `src/lib/chat/kvHandoff.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import {
  isKvHandoffEligible,
  isKvHandoffMime,
  resolveKvHandoffBrand,
} from "./kvHandoff";

const ELIGIBLE = {
  sender: "ai" as const,
  imageModel: "gpt-image-2",
  mimeType: "image/png",
  kvFlagEnabled: true,
  accessibleBrandIds: ["brand-1"],
};

describe("isKvHandoffMime", () => {
  it("accepts the formats the api whitelist allows and getMimeTypeFromUrl can produce", () => {
    expect(isKvHandoffMime("image/png")).toBe(true);
    expect(isKvHandoffMime("image/jpeg")).toBe(true);
    expect(isKvHandoffMime("image/webp")).toBe(true);
  });

  it("rejects anything else, including the octet-stream fallback", () => {
    expect(isKvHandoffMime("application/octet-stream")).toBe(false);
    expect(isKvHandoffMime("video/mp4")).toBe(false);
    // getMimeTypeFromUrl has no .gif branch, so a gif URL arrives as
    // octet-stream and is correctly excluded rather than 422-ing at the api.
    expect(isKvHandoffMime("image/gif")).toBe(false);
  });
});

describe("isKvHandoffEligible", () => {
  it("accepts an AI image-generation turn", () => {
    expect(isKvHandoffEligible(ELIGIBLE)).toBe(true);
  });

  it("rejects a user message", () => {
    expect(isKvHandoffEligible({ ...ELIGIBLE, sender: "user" })).toBe(false);
  });

  it("rejects an AI turn that generated no image", () => {
    expect(isKvHandoffEligible({ ...ELIGIBLE, imageModel: null })).toBe(false);
    expect(isKvHandoffEligible({ ...ELIGIBLE, imageModel: "" })).toBe(false);
  });

  it("rejects an unsupported mime type", () => {
    expect(
      isKvHandoffEligible({ ...ELIGIBLE, mimeType: "application/octet-stream" })
    ).toBe(false);
  });

  it("rejects when the KV Generator flag is off", () => {
    expect(isKvHandoffEligible({ ...ELIGIBLE, kvFlagEnabled: false })).toBe(
      false
    );
  });

  it("rejects when no brand grants KV access", () => {
    expect(isKvHandoffEligible({ ...ELIGIBLE, accessibleBrandIds: [] })).toBe(
      false
    );
  });
});

describe("resolveKvHandoffBrand", () => {
  it("prefers the brand in the URL", () => {
    expect(
      resolveKvHandoffBrand({
        urlBrandId: "b1",
        threadOriginBrandId: "b2",
        accessibleBrandIds: ["b1", "b2"],
      })
    ).toEqual({ kind: "resolved", brandId: "b1", source: "url" });
  });

  it("falls back to the thread's origin brand at workspace level", () => {
    expect(
      resolveKvHandoffBrand({
        urlBrandId: null,
        threadOriginBrandId: "b2",
        accessibleBrandIds: ["b1", "b2"],
      })
    ).toEqual({ kind: "resolved", brandId: "b2", source: "thread" });
  });

  it("ignores a URL brand the user cannot use and keeps looking", () => {
    expect(
      resolveKvHandoffBrand({
        urlBrandId: "forbidden",
        threadOriginBrandId: "b2",
        accessibleBrandIds: ["b1", "b2"],
      })
    ).toEqual({ kind: "resolved", brandId: "b2", source: "thread" });
  });

  it("auto-resolves when exactly one brand is accessible", () => {
    expect(
      resolveKvHandoffBrand({
        urlBrandId: null,
        threadOriginBrandId: null,
        accessibleBrandIds: ["only"],
      })
    ).toEqual({ kind: "resolved", brandId: "only", source: "single" });
  });

  it("asks for a pick when several brands are accessible and nothing is implied", () => {
    expect(
      resolveKvHandoffBrand({
        urlBrandId: null,
        threadOriginBrandId: null,
        accessibleBrandIds: ["b1", "b2"],
      })
    ).toEqual({ kind: "picker", candidateBrandIds: ["b1", "b2"] });
  });

  it("reports unavailable when no brand is accessible", () => {
    expect(
      resolveKvHandoffBrand({
        urlBrandId: "b1",
        threadOriginBrandId: "b2",
        accessibleBrandIds: [],
      })
    ).toEqual({ kind: "unavailable" });
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd web && bunx vitest run src/lib/chat/kvHandoff.test.ts
```

Expected: FAIL — `Failed to resolve import "./kvHandoff"`.

- [ ] **Step 3: Write the implementation**

Create `src/lib/chat/kvHandoff.ts`:

```ts
/**
 * Decision logic for the askFRND → KV Studio handoff, kept free of React and
 * the DOM so it is testable in isolation.
 */

/**
 * MIME types the handoff supports. Narrower than the api's whitelist
 * (which also allows image/gif) on purpose: `getMimeTypeFromUrl` has no `.gif`
 * branch and returns `application/octet-stream` for one, so claiming gif
 * support here would only produce a 422 at import time.
 */
export const KV_HANDOFF_MIME_TYPES = [
  "image/png",
  "image/jpeg",
  "image/webp",
] as const;

export type KvHandoffMimeType = (typeof KV_HANDOFF_MIME_TYPES)[number];

export function isKvHandoffMime(mime: string): mime is KvHandoffMimeType {
  return (KV_HANDOFF_MIME_TYPES as readonly string[]).includes(mime);
}

export interface KvHandoffEligibilityInput {
  sender: "user" | "ai";
  /** `ChatMessage.image_model` — set only on image-generation/editing turns,
   *  and rehydrated from the api by `convertApiMessages`. Used instead of a
   *  URL heuristic so web-search images and brand assets don't qualify. */
  imageModel?: string | null;
  mimeType: string;
  kvFlagEnabled: boolean;
  accessibleBrandIds: string[];
}

export function isKvHandoffEligible(input: KvHandoffEligibilityInput): boolean {
  return (
    input.sender === "ai" &&
    !!input.imageModel &&
    isKvHandoffMime(input.mimeType) &&
    input.kvFlagEnabled &&
    input.accessibleBrandIds.length > 0
  );
}

export type KvHandoffBrandSource = "url" | "thread" | "single" | "picker";

export type KvHandoffBrandResolution =
  | { kind: "resolved"; brandId: string; source: KvHandoffBrandSource }
  | { kind: "picker"; candidateBrandIds: string[] }
  | { kind: "unavailable" };

export interface KvHandoffBrandInput {
  /** Brand from the current route — askFRND opened on a brand-aware page. */
  urlBrandId: string | null;
  /** Brand the thread was started from — survives navigating away to /home. */
  threadOriginBrandId: string | null;
  /** Brands where the user can read `brand.studio.kv_generator`. */
  accessibleBrandIds: string[];
}

/**
 * Resolve which brand the new KV file belongs to. Both askFRND contexts are
 * covered: on a brand-aware page the URL wins; at workspace level the thread's
 * origin brand is tried, then a single accessible brand, then the user picks.
 * A candidate the user has no access to is skipped rather than trusted.
 */
export function resolveKvHandoffBrand(
  input: KvHandoffBrandInput
): KvHandoffBrandResolution {
  const { urlBrandId, threadOriginBrandId, accessibleBrandIds } = input;

  if (accessibleBrandIds.length === 0) return { kind: "unavailable" };

  if (urlBrandId && accessibleBrandIds.includes(urlBrandId)) {
    return { kind: "resolved", brandId: urlBrandId, source: "url" };
  }

  if (threadOriginBrandId && accessibleBrandIds.includes(threadOriginBrandId)) {
    return { kind: "resolved", brandId: threadOriginBrandId, source: "thread" };
  }

  if (accessibleBrandIds.length === 1) {
    return { kind: "resolved", brandId: accessibleBrandIds[0], source: "single" };
  }

  return { kind: "picker", candidateBrandIds: accessibleBrandIds };
}

/**
 * Which step of the handoff failed. Declared here rather than in the analytics
 * module so `performKvHandoff` does not depend on analytics for its own error
 * type; the analytics module imports it from here instead.
 */
export type KvHandoffFailureStage = "measure" | "create" | "import";
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd web && bunx vitest run src/lib/chat/kvHandoff.test.ts
```

Expected: 14 passed.

- [ ] **Step 5: Commit**

```bash
cd web && git add src/lib/chat/kvHandoff.ts src/lib/chat/kvHandoff.test.ts
git commit -m "feat(web): eligibility + brand resolution for the KV Studio handoff"
```

---

### Task 3: Read a CORS-less image's natural size

**Files:**
- Create: `src/lib/chat/measureRemoteImage.ts`
- Test: `src/lib/chat/measureRemoteImage.test.ts`

**Interfaces:**
- Produces: `measureRemoteImage(src: string): Promise<{ width: number; height: number }>`, rejecting with an `Error` on load failure or zero dimensions.
- Consumed by: Task 4.

- [ ] **Step 1: Write the failing test**

Create `src/lib/chat/measureRemoteImage.test.ts`:

```ts
import { afterEach, expect, it, vi } from "vitest";
import { measureRemoteImage } from "./measureRemoteImage";

const realImage = globalThis.Image;

/**
 * Stub `Image` — jsdom never actually loads anything, so the test drives the
 * load/error callbacks itself. Also asserts the element is NOT given a
 * crossOrigin, which matters: the S3 bucket sends no CORS headers, so an
 * anonymous request would fail outright.
 */
function stubImage(behaviour: {
  width?: number;
  height?: number;
  fail?: boolean;
}) {
  const instances: Array<Record<string, unknown>> = [];
  class FakeImage {
    naturalWidth = behaviour.width ?? 0;
    naturalHeight = behaviour.height ?? 0;
    onload: (() => void) | null = null;
    onerror: (() => void) | null = null;
    crossOrigin: string | null = null;
    #src = "";
    constructor() {
      instances.push(this as unknown as Record<string, unknown>);
    }
    get src() {
      return this.#src;
    }
    set src(value: string) {
      this.#src = value;
      queueMicrotask(() => {
        if (behaviour.fail) this.onerror?.();
        else this.onload?.();
      });
    }
  }
  (globalThis as unknown as { Image: unknown }).Image = FakeImage;
  return instances;
}

afterEach(() => {
  (globalThis as unknown as { Image: unknown }).Image = realImage;
  vi.restoreAllMocks();
});

it("resolves the natural dimensions", async () => {
  stubImage({ width: 1536, height: 1024 });

  await expect(measureRemoteImage("https://s3/x.png")).resolves.toEqual({
    width: 1536,
    height: 1024,
  });
});

it("never sets crossOrigin — the bucket sends no CORS headers", async () => {
  const instances = stubImage({ width: 10, height: 10 });

  await measureRemoteImage("https://s3/x.png");

  expect(instances).toHaveLength(1);
  expect(instances[0].crossOrigin).toBeNull();
});

it("rejects when the image fails to load", async () => {
  stubImage({ fail: true });

  await expect(measureRemoteImage("https://s3/gone.png")).rejects.toThrow(
    /failed to load/i
  );
});

it("rejects zero dimensions rather than importing an unusable base", async () => {
  stubImage({ width: 0, height: 0 });

  await expect(measureRemoteImage("https://s3/x.png")).rejects.toThrow(
    /zero dimensions/i
  );
});
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd web && bunx vitest run src/lib/chat/measureRemoteImage.test.ts
```

Expected: FAIL — `Failed to resolve import "./measureRemoteImage"`.

- [ ] **Step 3: Write the implementation**

Create `src/lib/chat/measureRemoteImage.ts`:

```ts
export interface RemoteImageSize {
  width: number;
  height: number;
}

/**
 * Read a remote image's natural pixel size.
 *
 * Deliberately does NOT set `crossOrigin`: the S3 bucket serving askFRND and
 * KV assets returns no CORS headers, so an anonymous request fails before any
 * HTTP exchange (see `src/lib/studio/kv/downloadFile.ts`). A plain load is
 * also what the chat bubble already did for this exact URL, so this reuses the
 * warm cache entry instead of creating a second, differently-moded one.
 *
 * This is why the api's `size` field is optional for URL imports — dimensions
 * are readable this way, byte length is not.
 */
export function measureRemoteImage(src: string): Promise<RemoteImageSize> {
  return new Promise((resolve, reject) => {
    const img = new Image();

    img.onload = () => {
      const width = img.naturalWidth;
      const height = img.naturalHeight;
      // A decoded-but-empty image would import a base whose ratio silently
      // mis-sets craft_supported, so fail loudly instead of guessing.
      if (width < 1 || height < 1) {
        reject(new Error("image reported zero dimensions"));
        return;
      }
      resolve({ width, height });
    };

    img.onerror = () => reject(new Error("image failed to load"));

    img.src = src;
  });
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd web && bunx vitest run src/lib/chat/measureRemoteImage.test.ts
```

Expected: 4 passed.

- [ ] **Step 5: Commit**

```bash
cd web && git add src/lib/chat/measureRemoteImage.ts src/lib/chat/measureRemoteImage.test.ts
git commit -m "feat(web): measure a CORS-less remote image's natural size"
```

---

### Task 4: Orchestrate the handoff

**Files:**
- Create: `src/lib/chat/performKvHandoff.ts`, `src/lib/analytics/askfrnd-kv-handoff-events.ts`
- Modify: `src/services/kv/api.ts` — the `importKvGenerationFromUpload` body type
- Test: `src/lib/chat/performKvHandoff.test.ts`

**Interfaces:**
- Consumes: `measureRemoteImage` (Task 3), `KvHandoffMimeType` (Task 2).
- Produces:
  - `class KvHandoffError extends Error` with `stage: "create" | "measure" | "import"`
  - `performKvHandoff(args: { brandId: string; imageUrl: string; mimeType: KvHandoffMimeType; originalFilename?: string }): Promise<{ fileId: string; route: string }>`
  - `trackAskfrndKvHandoffClicked`, `trackAskfrndKvHandoffFailed`
- Consumed by: Task 6.

- [ ] **Step 1: Write the failing test**

Create `src/lib/chat/performKvHandoff.test.ts`:

```ts
import { beforeEach, expect, it, vi } from "vitest";

const createKvFile = vi.fn();
const importKvGenerationFromUpload = vi.fn();
const measureRemoteImage = vi.fn();

vi.mock("@/services/mutate", () => ({
  createKvFile: (...a: unknown[]) => createKvFile(...a),
}));
vi.mock("@/services/kv/api", () => ({
  importKvGenerationFromUpload: (...a: unknown[]) =>
    importKvGenerationFromUpload(...a),
}));
vi.mock("./measureRemoteImage", () => ({
  measureRemoteImage: (...a: unknown[]) => measureRemoteImage(...a),
}));

import { KvHandoffError, performKvHandoff } from "./performKvHandoff";

const ARGS = {
  brandId: "brand-1",
  imageUrl: "https://s3/generated/serum.png",
  mimeType: "image/png" as const,
};

beforeEach(() => {
  createKvFile.mockReset();
  importKvGenerationFromUpload.mockReset();
  measureRemoteImage.mockReset();
});

it("measures, creates, imports as a craft base, and returns the route", async () => {
  measureRemoteImage.mockResolvedValue({ width: 1024, height: 1536 });
  createKvFile.mockResolvedValue({ data: { id: "file-9" } });
  importKvGenerationFromUpload.mockResolvedValue({ id: "gen-1" });

  const result = await performKvHandoff(ARGS);

  expect(createKvFile).toHaveBeenCalledWith({ brand_id: "brand-1" });
  expect(importKvGenerationFromUpload).toHaveBeenCalledWith("file-9", {
    image_url: ARGS.imageUrl,
    mime_type: "image/png",
    width: 1024,
    height: 1536,
    canvas_mode: "craft",
    original_filename: undefined,
  });
  expect(result).toEqual({
    fileId: "file-9",
    route: "/brands/brand-1/studio/kv-generator/file-9",
  });
});

it("measures BEFORE creating, so a bad image creates no orphan file", async () => {
  measureRemoteImage.mockRejectedValue(new Error("image failed to load"));

  await expect(performKvHandoff(ARGS)).rejects.toMatchObject({
    stage: "measure",
  });
  expect(createKvFile).not.toHaveBeenCalled();
});

it("labels a file-creation failure", async () => {
  measureRemoteImage.mockResolvedValue({ width: 10, height: 10 });
  createKvFile.mockRejectedValue(new Error("403"));

  await expect(performKvHandoff(ARGS)).rejects.toMatchObject({
    stage: "create",
  });
  expect(importKvGenerationFromUpload).not.toHaveBeenCalled();
});

it("labels an import failure and does not return a route", async () => {
  measureRemoteImage.mockResolvedValue({ width: 10, height: 10 });
  createKvFile.mockResolvedValue({ data: { id: "file-9" } });
  importKvGenerationFromUpload.mockRejectedValue(new Error("422"));

  const error = await performKvHandoff(ARGS).catch((e) => e);

  expect(error).toBeInstanceOf(KvHandoffError);
  expect(error.stage).toBe("import");
});

it("omits size entirely — the browser cannot read it", async () => {
  measureRemoteImage.mockResolvedValue({ width: 10, height: 10 });
  createKvFile.mockResolvedValue({ data: { id: "file-9" } });
  importKvGenerationFromUpload.mockResolvedValue({ id: "gen-1" });

  await performKvHandoff(ARGS);

  const body = importKvGenerationFromUpload.mock.calls[0][1] as Record<
    string,
    unknown
  >;
  expect(body).not.toHaveProperty("size");
});
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd web && bunx vitest run src/lib/chat/performKvHandoff.test.ts
```

Expected: FAIL — `Failed to resolve import "./performKvHandoff"`.

- [ ] **Step 3: Make `size` optional on the service body type**

In `src/services/kv/api.ts`, in `importKvGenerationFromUpload`'s `body` parameter, replace `size: number;` with:

```ts
    /** Optional: a URL import cannot read Content-Length, because the S3
     *  bucket sends no CORS headers. The api stores this in metadata only
     *  and accepts its absence. */
    size?: number;
```

- [ ] **Step 4: Write the analytics module**

Create `src/lib/analytics/askfrnd-kv-handoff-events.ts`:

```ts
import posthog from "posthog-js";
import type {
  KvHandoffBrandSource,
  KvHandoffFailureStage,
} from "@/lib/chat/kvHandoff";

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

export interface AskfrndKvHandoffClickedProps {
  brand_resolution: KvHandoffBrandSource;
  image_model: string | null;
  conversation_id: string | null;
}

export const trackAskfrndKvHandoffClicked = (
  p: AskfrndKvHandoffClickedProps
) => safeCapture("askfrnd.kv_handoff_clicked", p);

export interface AskfrndKvHandoffFailedProps {
  stage: KvHandoffFailureStage;
  reason: string;
  conversation_id: string | null;
}

export const trackAskfrndKvHandoffFailed = (p: AskfrndKvHandoffFailedProps) =>
  safeCapture("askfrnd.kv_handoff_failed", p);
```

- [ ] **Step 5: Write the orchestration**

Create `src/lib/chat/performKvHandoff.ts`:

```ts
import { createKvFile } from "@/services/mutate";
import { importKvGenerationFromUpload } from "@/services/kv/api";
import { measureRemoteImage } from "./measureRemoteImage";
import type { KvHandoffFailureStage, KvHandoffMimeType } from "./kvHandoff";

export class KvHandoffError extends Error {
  constructor(
    public readonly stage: KvHandoffFailureStage,
    message: string
  ) {
    super(message);
    this.name = "KvHandoffError";
  }
}

export interface PerformKvHandoffArgs {
  brandId: string;
  imageUrl: string;
  mimeType: KvHandoffMimeType;
  originalFilename?: string;
}

export interface PerformKvHandoffResult {
  fileId: string;
  route: string;
}

/**
 * Turn an askFRND-generated image into a KV file the user can Craft on.
 *
 * Measurement runs FIRST on purpose: `width`/`height` are required by the api
 * (they gate `craft_supported`), and failing before `createKvFile` means a
 * bad image leaves nothing behind. An import failure after creation does leave
 * an empty KV file, which is indistinguishable from one made with "New KV" —
 * the caller keeps the user in the chat and offers a retry rather than
 * deleting it and adding another failure path.
 */
export async function performKvHandoff(
  args: PerformKvHandoffArgs
): Promise<PerformKvHandoffResult> {
  const { brandId, imageUrl, mimeType, originalFilename } = args;

  let size: { width: number; height: number };
  try {
    size = await measureRemoteImage(imageUrl);
  } catch (error) {
    throw new KvHandoffError("measure", (error as Error).message);
  }

  let fileId: string;
  try {
    const created = await createKvFile({ brand_id: brandId });
    fileId = created.data.id;
  } catch (error) {
    throw new KvHandoffError("create", (error as Error).message);
  }

  try {
    await importKvGenerationFromUpload(fileId, {
      image_url: imageUrl,
      mime_type: mimeType,
      width: size.width,
      height: size.height,
      // Continuing an existing image is polishing, not sketching.
      canvas_mode: "craft",
      original_filename: originalFilename,
    });
  } catch (error) {
    throw new KvHandoffError("import", (error as Error).message);
  }

  return {
    fileId,
    route: `/brands/${brandId}/studio/kv-generator/${fileId}`,
  };
}
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
cd web && bunx vitest run src/lib/chat/performKvHandoff.test.ts
```

Expected: 5 passed.

- [ ] **Step 7: Commit**

```bash
cd web && git add src/lib/chat/performKvHandoff.ts src/lib/chat/performKvHandoff.test.ts src/lib/analytics/askfrnd-kv-handoff-events.ts src/services/kv/api.ts
git commit -m "feat(web): orchestrate the askFRND → KV Studio handoff

Measure first so a bad image creates no orphan KV file. size is omitted from
the import body — the S3 bucket sends no CORS headers, so the browser cannot
read Content-Length."
```

---

### Task 5: Brand picker modal

**Files:**
- Create: `src/components/chat/KvHandoffBrandPicker.tsx`
- Test: `src/components/chat/KvHandoffBrandPicker.test.tsx`

**Interfaces:**
- Produces: `KvHandoffBrandPicker` with props `{ isOpen: boolean; brands: Array<{ id: string; name: string }>; onSelect: (brandId: string) => void; onClose: () => void }`
- Consumed by: Task 6.

- [ ] **Step 1: Write the failing test**

Create `src/components/chat/KvHandoffBrandPicker.test.tsx`:

```tsx
import "@testing-library/jest-dom";
import { expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import KvHandoffBrandPicker from "./KvHandoffBrandPicker";

const BRANDS = [
  { id: "b1", name: "frndGlow" },
  { id: "b2", name: "SIMPATI" },
];

it("lists every candidate brand", () => {
  render(
    <KvHandoffBrandPicker
      isOpen
      brands={BRANDS}
      onSelect={vi.fn()}
      onClose={vi.fn()}
    />
  );

  expect(screen.getByText("frndGlow")).toBeInTheDocument();
  expect(screen.getByText("SIMPATI")).toBeInTheDocument();
});

it("reports the chosen brand id", () => {
  const onSelect = vi.fn();
  render(
    <KvHandoffBrandPicker
      isOpen
      brands={BRANDS}
      onSelect={onSelect}
      onClose={vi.fn()}
    />
  );

  screen.getByRole("button", { name: "SIMPATI" }).click();

  expect(onSelect).toHaveBeenCalledWith("b2");
});

it("renders nothing when closed", () => {
  render(
    <KvHandoffBrandPicker
      isOpen={false}
      brands={BRANDS}
      onSelect={vi.fn()}
      onClose={vi.fn()}
    />
  );

  expect(screen.queryByText("frndGlow")).not.toBeInTheDocument();
});
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd web && bunx vitest run src/components/chat/KvHandoffBrandPicker.test.tsx
```

Expected: FAIL — `Failed to resolve import "./KvHandoffBrandPicker"`.

- [ ] **Step 3: Write the component**

Create `src/components/chat/KvHandoffBrandPicker.tsx`:

```tsx
"use client";

import BaseModal from "@/components/frndos/BaseModal";

export interface KvHandoffBrandOption {
  id: string;
  name: string;
}

interface KvHandoffBrandPickerProps {
  isOpen: boolean;
  brands: KvHandoffBrandOption[];
  onSelect: (brandId: string) => void;
  onClose: () => void;
}

/**
 * Shown only when askFRND is at workspace level and the user has more than
 * one brand with KV Studio access — a new KV file has to belong to a brand,
 * and guessing would file the work under the wrong one.
 */
export default function KvHandoffBrandPicker({
  isOpen,
  brands,
  onSelect,
  onClose,
}: KvHandoffBrandPickerProps) {
  return (
    <BaseModal
      isOpen={isOpen}
      onClose={onClose}
      title="Which brand?"
      description="The new key visual will be saved under this brand."
    >
      <div className="flex flex-col gap-2">
        {brands.map((brand) => (
          <button
            key={brand.id}
            type="button"
            onClick={() => onSelect(brand.id)}
            className="flex w-full items-center rounded-xl border border-white/10 bg-white/5 px-4 py-3 text-left font-funnel text-textSmMedium text-white transition-colors hover:bg-white/[0.08] focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-white/40"
          >
            {brand.name}
          </button>
        ))}
      </div>
    </BaseModal>
  );
}
```

(`BaseModal` is a default export — `src/components/frndos/BaseModal.tsx:171`.)

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd web && bunx vitest run src/components/chat/KvHandoffBrandPicker.test.tsx
```

Expected: 3 passed.

- [ ] **Step 5: Commit**

```bash
cd web && git add src/components/chat/KvHandoffBrandPicker.tsx src/components/chat/KvHandoffBrandPicker.test.tsx
git commit -m "feat(web): brand picker for the KV Studio handoff"
```

---

### Task 6: The card

**Files:**
- Create: `src/components/chat/KvHandoffCard.tsx`
- Test: `src/components/chat/KvHandoffCard.test.tsx`

**Interfaces:**
- Consumes: everything from Tasks 2–5.
- Produces: `KvHandoffCard` with props `{ imageUrl: string; imageModel: string | null; sender: "user" | "ai" }`
- Consumed by: Task 7.

- [ ] **Step 1: Write the failing test**

Create `src/components/chat/KvHandoffCard.test.tsx`:

```tsx
import "@testing-library/jest-dom";
import { beforeEach, expect, it, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";

const push = vi.fn();
const performKvHandoff = vi.fn();
const canReadForBrand = vi.fn();
const useMajorFeatureFlag = vi.fn();
const trackClicked = vi.fn();
const trackFailed = vi.fn();

// The card reads the brand off the URL through the real `useUrlBrandId()`
// hook, which calls `usePathname()` — so mocking next/navigation here is
// what drives brand resolution. Do NOT mock `@/hooks/useUrlBrandId`.
vi.mock("next/navigation", () => ({
  useRouter: () => ({ push }),
  usePathname: () => "/brands/b1/insight",
}));
vi.mock("@/lib/chat/performKvHandoff", async () => {
  const actual = await vi.importActual<
    typeof import("@/lib/chat/performKvHandoff")
  >("@/lib/chat/performKvHandoff");
  return {
    KvHandoffError: actual.KvHandoffError,
    performKvHandoff: (...a: unknown[]) => performKvHandoff(...a),
  };
});
vi.mock("@/hooks/usePermissions", () => ({
  usePermissions: () => ({
    canReadForBrand: (...a: unknown[]) => canReadForBrand(...a),
  }),
}));
vi.mock("@/hooks/useWorkspaceBrands", () => ({
  useWorkspaceBrands: () => ({
    data: {
      data: {
        data: [
          { id: "b1", name: "frndGlow" },
          { id: "b2", name: "SIMPATI" },
        ],
      },
    },
  }),
}));
vi.mock("@/lib/featureFlags", () => ({
  MAJOR_FEATURE_FLAGS: { KV_GENERATOR: "show-kv-generator" },
  useMajorFeatureFlag: (...a: unknown[]) => useMajorFeatureFlag(...a),
}));
vi.mock("@/lib/analytics/askfrnd-kv-handoff-events", () => ({
  trackAskfrndKvHandoffClicked: (...a: unknown[]) => trackClicked(...a),
  trackAskfrndKvHandoffFailed: (...a: unknown[]) => trackFailed(...a),
}));
vi.mock("@/store/useChatStore", () => ({
  useChatStore: (selector: (s: unknown) => unknown) =>
    selector({
      currentChatId: "thread-1",
      chatSessions: [{ id: "thread-1", origin_brand_id: null }],
    }),
}));

import KvHandoffCard from "./KvHandoffCard";

const PROPS = {
  imageUrl: "https://s3/generated/serum.png",
  imageModel: "gpt-image-2",
  sender: "ai" as const,
};

beforeEach(() => {
  push.mockReset();
  performKvHandoff.mockReset();
  trackClicked.mockReset();
  trackFailed.mockReset();
  canReadForBrand.mockReset().mockReturnValue(true);
  useMajorFeatureFlag.mockReset().mockReturnValue(true);
});

it("renders the card for an AI image turn", () => {
  render(<KvHandoffCard {...PROPS} />);

  expect(screen.getByText("Edit in KV Studio")).toBeInTheDocument();
  expect(
    screen.getByText("Use this image as a key visual base")
  ).toBeInTheDocument();
});

it("renders nothing when the turn generated no image", () => {
  render(<KvHandoffCard {...PROPS} imageModel={null} />);

  expect(screen.queryByText("Edit in KV Studio")).not.toBeInTheDocument();
});

it("renders nothing for a user message", () => {
  render(<KvHandoffCard {...PROPS} sender="user" />);

  expect(screen.queryByText("Edit in KV Studio")).not.toBeInTheDocument();
});

it("renders nothing for an unsupported image type", () => {
  render(<KvHandoffCard {...PROPS} imageUrl="https://s3/clip.mp4" />);

  expect(screen.queryByText("Edit in KV Studio")).not.toBeInTheDocument();
});

it("renders nothing when the KV Generator flag is off", () => {
  useMajorFeatureFlag.mockReturnValue(false);

  render(<KvHandoffCard {...PROPS} />);

  expect(screen.queryByText("Edit in KV Studio")).not.toBeInTheDocument();
});

it("renders nothing when no brand grants KV access", () => {
  canReadForBrand.mockReturnValue(false);

  render(<KvHandoffCard {...PROPS} />);

  expect(screen.queryByText("Edit in KV Studio")).not.toBeInTheDocument();
});

it("uses the URL brand and navigates on success", async () => {
  performKvHandoff.mockResolvedValue({
    fileId: "file-9",
    route: "/brands/b1/studio/kv-generator/file-9",
  });

  render(<KvHandoffCard {...PROPS} />);
  screen.getByRole("button", { name: /Edit in KV Studio/ }).click();

  await waitFor(() =>
    expect(push).toHaveBeenCalledWith("/brands/b1/studio/kv-generator/file-9")
  );
  expect(performKvHandoff).toHaveBeenCalledWith({
    brandId: "b1",
    imageUrl: PROPS.imageUrl,
    mimeType: "image/png",
  });
  expect(trackClicked).toHaveBeenCalledWith({
    brand_resolution: "url",
    image_model: "gpt-image-2",
    conversation_id: "thread-1",
  });
});

it("stays in the chat and offers a retry when the import fails", async () => {
  const { KvHandoffError } = await import("@/lib/chat/performKvHandoff");
  performKvHandoff.mockRejectedValue(new KvHandoffError("import", "422"));

  render(<KvHandoffCard {...PROPS} />);
  screen.getByRole("button", { name: /Edit in KV Studio/ }).click();

  await waitFor(() =>
    expect(screen.getByText(/Couldn't open KV Studio/i)).toBeInTheDocument()
  );
  expect(push).not.toHaveBeenCalled();
  expect(trackFailed).toHaveBeenCalledWith({
    stage: "import",
    reason: "422",
    conversation_id: "thread-1",
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd web && bunx vitest run src/components/chat/KvHandoffCard.test.tsx
```

Expected: FAIL — `Failed to resolve import "./KvHandoffCard"`.

- [ ] **Step 3: Write the component**

Create `src/components/chat/KvHandoffCard.tsx`:

```tsx
"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { ArrowRight, ArrowClockwise, Sparkle } from "@phosphor-icons/react";
import { getMimeTypeFromUrl } from "@/lib/fileUtils";
import { useUrlBrandId } from "@/hooks/useUrlBrandId";
import { usePermissions } from "@/hooks/usePermissions";
import { useWorkspaceBrands } from "@/hooks/useWorkspaceBrands";
import { MAJOR_FEATURE_FLAGS, useMajorFeatureFlag } from "@/lib/featureFlags";
import { useChatStore } from "@/store/useChatStore";
import {
  isKvHandoffEligible,
  isKvHandoffMime,
  resolveKvHandoffBrand,
  type KvHandoffBrandSource,
} from "@/lib/chat/kvHandoff";
import { KvHandoffError, performKvHandoff } from "@/lib/chat/performKvHandoff";
import {
  trackAskfrndKvHandoffClicked,
  trackAskfrndKvHandoffFailed,
} from "@/lib/analytics/askfrnd-kv-handoff-events";
import KvHandoffBrandPicker from "./KvHandoffBrandPicker";

interface KvHandoffCardProps {
  imageUrl: string;
  imageModel: string | null;
  sender: "user" | "ai";
}

/**
 * "Edit in KV Studio", rendered under an askFRND-generated image.
 *
 * Shape follows `GeneratedFileCard` — in askFRND that card idiom means "a
 * result you can take out of this chat", which is exactly this. Root is a
 * <button> with <span> children because the card renders inside a markdown
 * <p>, where a <div> would be invalid nesting.
 */
export default function KvHandoffCard({
  imageUrl,
  imageModel,
  sender,
}: KvHandoffCardProps) {
  const router = useRouter();
  // Render-scope hook — the repo's idiom for "which brand is this page under".
  const urlBrandId = useUrlBrandId();
  const { canReadForBrand } = usePermissions();
  const brandsQuery = useWorkspaceBrands();
  const kvFlagEnabled = useMajorFeatureFlag(MAJOR_FEATURE_FLAGS.KV_GENERATOR);

  const conversationId = useChatStore((s) => s.currentChatId);
  const threadOriginBrandId = useChatStore(
    (s) =>
      s.chatSessions.find((c) => c.id === s.currentChatId)?.origin_brand_id ??
      null
  );

  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pickerOpen, setPickerOpen] = useState(false);

  const mimeType = getMimeTypeFromUrl(imageUrl);

  const accessibleBrands = useMemo(() => {
    const rows = brandsQuery.data?.data?.data ?? [];
    return rows
      .filter((b) => canReadForBrand("brand.studio.kv_generator", b.id))
      .map((b) => ({ id: b.id, name: b.name }));
    // canReadForBrand is recreated each render; the permission data it closes
    // over is what actually changes, and that arrives with brandsQuery.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [brandsQuery.data]);

  const eligible = isKvHandoffEligible({
    sender,
    imageModel,
    mimeType,
    kvFlagEnabled,
    accessibleBrandIds: accessibleBrands.map((b) => b.id),
  });

  if (!eligible || !isKvHandoffMime(mimeType)) return null;

  const run = async (brandId: string, source: KvHandoffBrandSource) => {
    setBusy(true);
    setError(null);
    trackAskfrndKvHandoffClicked({
      brand_resolution: source,
      image_model: imageModel,
      conversation_id: conversationId,
    });

    try {
      const { route } = await performKvHandoff({
        brandId,
        imageUrl,
        mimeType,
      });
      router.push(route);
    } catch (e) {
      const stage = e instanceof KvHandoffError ? e.stage : "import";
      trackAskfrndKvHandoffFailed({
        stage,
        reason: (e as Error).message,
        conversation_id: conversationId,
      });
      setError("Couldn't open KV Studio — tap to try again");
      setBusy(false);
    }
  };

  const handleClick = () => {
    if (busy) return;

    const resolution = resolveKvHandoffBrand({
      urlBrandId,
      threadOriginBrandId,
      accessibleBrandIds: accessibleBrands.map((b) => b.id),
    });

    if (resolution.kind === "unavailable") return;
    if (resolution.kind === "picker") {
      setPickerOpen(true);
      return;
    }
    void run(resolution.brandId, resolution.source);
  };

  return (
    <>
      <button
        type="button"
        onClick={handleClick}
        disabled={busy}
        aria-busy={busy}
        className="group my-2 flex w-full max-w-[420px] items-center gap-3 rounded-xl border border-white/10 bg-white/5 px-4 py-3 text-left transition-colors hover:bg-white/[0.08] disabled:cursor-progress"
      >
        <span className="flex size-10 shrink-0 items-center justify-center rounded-lg bg-white/5">
          <Sparkle size={22} weight="fill" className="text-sky-400" />
        </span>
        <span className="flex min-w-0 flex-1 flex-col">
          <span className="truncate font-funnel text-textSmMedium text-white">
            Edit in KV Studio
          </span>
          <span className="font-funnel text-textXsMedium text-white/40">
            {busy
              ? "Opening…"
              : (error ?? "Use this image as a key visual base")}
          </span>
        </span>
        {error ? (
          <ArrowClockwise
            size={20}
            className="shrink-0 text-white/40 transition-colors group-hover:text-white"
          />
        ) : (
          <ArrowRight
            size={20}
            className="shrink-0 text-white/40 transition-colors group-hover:text-white"
          />
        )}
      </button>

      <KvHandoffBrandPicker
        isOpen={pickerOpen}
        brands={accessibleBrands}
        onClose={() => setPickerOpen(false)}
        onSelect={(brandId) => {
          setPickerOpen(false);
          void run(brandId, "picker");
        }}
      />
    </>
  );
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd web && bunx vitest run src/components/chat/KvHandoffCard.test.tsx
```

Expected: 8 passed.

- [ ] **Step 5: Commit**

```bash
cd web && git add src/components/chat/KvHandoffCard.tsx src/components/chat/KvHandoffCard.test.tsx
git commit -m "feat(web): Edit in KV Studio card for askFRND generated images"
```

---

### Task 7: Wire the card into the rendered answer

**Files:**
- Modify: `src/components/base/MarkdownRenderer.tsx` — props interface (~line 10), destructure (~line 21), `img:` override (~line 309)
- Modify: `src/components/chat/ChatMessage.tsx` — the `MarkdownRenderer` call (~line 1381)
- Test: `src/components/base/MarkdownRenderer.imageFooter.test.tsx`

**Interfaces:**
- Consumes: `KvHandoffCard` (Task 6).
- Produces: `MarkdownRendererProps.imageFooter?: (src: string, alt?: string) => React.ReactNode`.

- [ ] **Step 1: Write the failing test**

Create `src/components/base/MarkdownRenderer.imageFooter.test.tsx`:

```tsx
import "@testing-library/jest-dom";
import { expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import MarkdownRenderer from "./MarkdownRenderer";

it("renders a footer under each image", () => {
  render(
    <MarkdownRenderer
      content={"Here it is\n\n![serum](https://s3/a.png)\n\nand another\n\n![bottle](https://s3/b.png)"}
      imageFooter={(src) => <span data-testid="footer">{src}</span>}
    />
  );

  const footers = screen.getAllByTestId("footer");
  expect(footers).toHaveLength(2);
  expect(footers[0]).toHaveTextContent("https://s3/a.png");
  expect(footers[1]).toHaveTextContent("https://s3/b.png");
});

it("does not render a footer for a video", () => {
  render(
    <MarkdownRenderer
      content={"![clip](https://s3/a.mp4)"}
      imageFooter={() => <span data-testid="footer">nope</span>}
    />
  );

  expect(screen.queryByTestId("footer")).not.toBeInTheDocument();
});

it("renders nothing extra when no footer is supplied", () => {
  const { container } = render(
    <MarkdownRenderer content={"![serum](https://s3/a.png)"} />
  );

  expect(container.querySelectorAll("img")).toHaveLength(1);
});

it("passes the alt text through", () => {
  const imageFooter = vi.fn(() => null);
  render(
    <MarkdownRenderer
      content={"![a serum bottle](https://s3/a.png)"}
      imageFooter={imageFooter}
    />
  );

  expect(imageFooter).toHaveBeenCalledWith(
    "https://s3/a.png",
    "a serum bottle"
  );
});
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd web && bunx vitest run src/components/base/MarkdownRenderer.imageFooter.test.tsx
```

Expected: FAIL — no footers rendered (the prop does not exist yet).

- [ ] **Step 3: Add the prop to `MarkdownRenderer`**

In `MarkdownRendererProps`:

```ts
  /** Rendered directly under each non-video image. Kept as a render-prop so
   *  this component stays ignorant of what goes there — `ChatMessage` decides
   *  (today: the KV Studio handoff card). */
  imageFooter?: (src: string, alt?: string) => React.ReactNode;
```

Add `imageFooter,` to the destructured parameter list.

- [ ] **Step 4: Render the footer in the `img:` override**

Replace the final `return` of the `img:` override (the non-video branch) with:

```tsx
            const footer = imageFooter?.(srcString, alt);

            return (
              <>
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img
                  src={srcString}
                  alt={alt || ""}
                  className="my-4 max-w-full rounded-lg"
                  style={{ maxHeight: "500px" }}
                />
                {/* `span`, not `div`: markdown puts the image inside a <p>,
                    where block-level children are invalid nesting. */}
                {footer ? <span className="mb-4 block">{footer}</span> : null}
              </>
            );
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd web && bunx vitest run src/components/base/MarkdownRenderer.imageFooter.test.tsx
```

Expected: 4 passed.

- [ ] **Step 6: Supply the footer from `ChatMessage`**

Add the import:

```tsx
import KvHandoffCard from "./KvHandoffCard";
```

Next to the other memoized callbacks (near `handleImageClick`, ~line 483):

```tsx
  // Under every generated image, offer the KV Studio handoff. The card does
  // its own flag / permission / mime gating and renders null when it cannot
  // act, so this only has to answer "was this an AI image turn?".
  const renderImageFooter = useCallback(
    (src: string) => (
      <KvHandoffCard
        imageUrl={src}
        imageModel={message.image_model ?? null}
        sender={message.sender}
      />
    ),
    [message.image_model, message.sender]
  );
```

Then pass it on the `MarkdownRenderer` element inside the segment loop:

```tsx
                          imageFooter={renderImageFooter}
```

- [ ] **Step 7: Verify the existing chat suites still pass**

```bash
cd web && bunx vitest run src/components/chat src/components/base
```

Expected: no new failures.

**If anything is already red, you need a baseline. NEVER use `git stash` to get one** — not `git stash push`, not `git stash pop`, not "just for a second". Popping a stale stash has already corrupted this repo's files with conflict markers once (2026-06-23). Get the baseline from a throwaway worktree instead, which cannot touch your working tree:

```bash
cd web && git worktree add /tmp/kv-handoff-baseline origin/develop
cd /tmp/kv-handoff-baseline && bun install   # required — Turbopack rejects a symlinked node_modules
bunx vitest run src/components/chat src/components/base
```

Compare the two failure lists. Only failures that appear in yours and NOT in the baseline are yours to fix. Clean up when done:

```bash
cd web && git worktree remove /tmp/kv-handoff-baseline
```

- [ ] **Step 8: Commit**

```bash
cd web && git add src/components/base/MarkdownRenderer.tsx src/components/base/MarkdownRenderer.imageFooter.test.tsx src/components/chat/ChatMessage.tsx
git commit -m "feat(web): render the KV Studio handoff card under generated images"
```

---

### Task 8: Whole-feature verification

**Files:** none created or modified — this task only runs checks and records results.

- [ ] **Step 1: Run every test this feature added**

```bash
cd web && bunx vitest run \
  src/lib/chat/kvHandoff.test.ts \
  src/lib/chat/measureRemoteImage.test.ts \
  src/lib/chat/performKvHandoff.test.ts \
  src/store/useChatStore.originBrand.test.ts \
  src/components/chat/KvHandoffBrandPicker.test.tsx \
  src/components/chat/KvHandoffCard.test.tsx \
  src/components/base/MarkdownRenderer.imageFooter.test.tsx
```

Expected: all pass. Record the counts.

- [ ] **Step 2: Check types on only the touched files**

```bash
cd web && bunx tsc --noEmit > /tmp/kvhandoff-tsc.txt 2>&1
grep -E "src/(lib/chat|lib/analytics/askfrnd-kv-handoff-events|components/chat/KvHandoff|components/base/MarkdownRenderer|store/useChatStore|services/kv/api)" /tmp/kvhandoff-tsc.txt
```

Expected: no output. The repo-wide baseline is large, so only these paths count.

- [ ] **Step 3: Confirm the bundle still builds**

```bash
cd web && bun run build
```

Expected: success. This catches broken imports and module moves; it does **not** verify types (`ignoreBuildErrors: true`).

- [ ] **Step 4: Run the analytics review**

Invoke the `frndos-analytics-events` agent on this diff. The feature is not done until it signs off on `askfrnd.kv_handoff_clicked` / `askfrnd.kv_handoff_failed` naming and properties.

- [ ] **Step 5: Manual end-to-end (requires a running stack)**

Start api + web, then:

1. Open a **brand page**, open askFRND, generate an image. Confirm the card appears under it, click it, and confirm you land on the KV canvas in **Craft** with the image as the base.
2. Repeat from **`/home`** (workspace level) with several accessible brands. Confirm the brand picker appears, pick one, and confirm the file is created under that brand.
3. Reload a brand-page thread from the thread list, then click the card. Confirm **no picker** appears — this exercises Task 1.
4. Generate a **video** and confirm no card appears under it.
5. Confirm the card is absent for images in a user's own uploaded attachments.
6. **Export the handed-off KV — the canvas-tainting check.** On the file from
   step 1, add a text overlay, then run **Download / Export**. The base came
   from a bucket that sends no CORS headers, so a client-side `toDataURL()`
   read of that canvas can throw a `SecurityError` ("tainted canvases may not
   be exported") or silently produce a blank/partial file. Verify **all three**:
   - the export completes with no `SecurityError` in the console,
   - the downloaded file is non-zero and opens,
   - the exported image actually contains the base image, not just the overlay
     on transparency (the blank-file trap — a tainted read can fail quietly).

   Do the same for **Flatten** if the flow offers it. The spec accepts this
   risk rather than designing around it: it is identical to any base imported
   through the existing upload path, and `/api/kv/flatten-image` is the
   server-side workaround. So if this step fails, **the fix is to route the
   export through `/api/kv/flatten-image`, not to change the handoff** — record
   it in the track file and raise it before release rather than patching the
   import.

- [ ] **Step 6: Record the outcome**

Write the results into the track file for this feature, including anything from Step 5 that could not be exercised and why.

---

## Known gap to check during Step 5

`TrustedAssetHost` (api) rejects an `image_url` whose host is not `S3_OVERLAY_HOST_PATTERN` or a subdomain of it. Locally that variable is unset, which the api treats as permissive — so **a passing local e2e does not prove staging will work**. If the import 422s in staging, this is the first thing to check; see the deployment note in the api plan.
