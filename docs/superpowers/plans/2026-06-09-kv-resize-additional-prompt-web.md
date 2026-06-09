# KV Resize Additional Prompt — Web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional free-text prompt to both the New Resize batch flow and the per-tile Regenerate flow (which now arms instead of firing immediately), sending it to the API as `additional_prompt`, and render persisted resize/regenerate system-marker messages in the chat.

**Architecture:** Resize UI-only state lives in `useKvResizeStore` (Zustand); server state lives in TanStack Query via `useResizeExports`. We add `resizePrompt` (New Resize batch text) and `armedRegenerate` (the exportId currently armed for guided regenerate) to the store. The New Resize and Regenerate mutations forward `additional_prompt` (snake_case) in their POST bodies through `api.ts`. When a tile is armed, `KvChat` swaps its input into a "resize-mode": the locked target chip shows, Brainstorm/Design mode is hidden, the model dropdown is disabled, and Send calls the regenerate mutation directly (NOT the Agno stream). A new system-marker message variant renders in `MessagesList`.

**Tech Stack:** Next.js 16, React 19, TypeScript, Zustand, TanStack Query v5, Vitest

---

## Conventions discovered

- **Run a single test file:** `npx vitest run <path>` (from `web/`). There is no `test` script in `package.json`; Vitest is invoked directly. Config: `web/vitest.config.ts` (jsdom, globals, `vite-tsconfig-paths`).
- **Store tests** (`web/src/store/kv/useKvUpscaleStore.test.ts`): call `useKvResizeStore.getState()` directly, mutate, assert on `getState()`. Reset state in `afterEach`.
- **Mutation/wire tests** (`web/src/lib/studio/kv/useResizeExports.test.ts`, `web/src/services/kv/api.test.ts`): `vi.mock("@/services/axios", …)` or `vi.mock("@/services/kv/api", …)`; assert `toHaveBeenCalledWith`.
- **Platform id→label/size config:** `web/src/types/kv/resize.ts` `PLATFORMS` array (e.g. `instagram-post` → "Instagram Post", 1080×1080). Lookup helper `platformById(id)` in `web/src/lib/studio/kv/resizePlatforms.ts`.
- **Current resize POST body** (`createResizeExports`, `api.ts` ~L580): `{ parent_generation_id, platform_ids, crop_windows }`.
- **Current regenerate POST body** (`regenerateResizeExport`, `api.ts` ~L597): `{ crop_window }` (always sent, `crop_window` is a DEAD param — keep sending `null`, add `additional_prompt`).
- **Commit type:** `feat(web)`.

---

## Task 1 — Store: `resizePrompt` + `armedRegenerate`

Add the New Resize batch prompt and the armed-regenerate target to `useKvResizeStore`, with arm/disarm/toggle reducers.

**Files:**
- Modify: `web/src/store/kv/useKvResizeStore.ts`
- Test: `web/src/store/kv/useKvResizeStore.test.ts` (new)

Steps:

- [ ] 1. Write failing test `web/src/store/kv/useKvResizeStore.test.ts`:

```ts
import { afterEach, describe, expect, it } from "vitest";
import { useKvResizeStore } from "./useKvResizeStore";

afterEach(() => {
  const s = useKvResizeStore.getState();
  s.clearSelection();
  s.setResizePrompt("");
  s.disarmRegenerate();
});

describe("useKvResizeStore — resizePrompt", () => {
  it("setResizePrompt stores the value", () => {
    useKvResizeStore.getState().setResizePrompt("keep text at bottom");
    expect(useKvResizeStore.getState().resizePrompt).toBe("keep text at bottom");
  });

  it("caps resizePrompt at 1000 chars", () => {
    useKvResizeStore.getState().setResizePrompt("x".repeat(1500));
    expect(useKvResizeStore.getState().resizePrompt).toHaveLength(1000);
  });

  it("clearSelection also clears the resize prompt", () => {
    useKvResizeStore.getState().setResizePrompt("something");
    useKvResizeStore.getState().clearSelection();
    expect(useKvResizeStore.getState().resizePrompt).toBe("");
  });
});

describe("useKvResizeStore — armedRegenerate", () => {
  it("starts disarmed", () => {
    expect(useKvResizeStore.getState().armedRegenerate).toBeNull();
  });

  it("armRegenerate sets the active export id", () => {
    useKvResizeStore.getState().armRegenerate("exp-1");
    expect(useKvResizeStore.getState().armedRegenerate).toBe("exp-1");
  });

  it("disarmRegenerate clears it", () => {
    useKvResizeStore.getState().armRegenerate("exp-1");
    useKvResizeStore.getState().disarmRegenerate();
    expect(useKvResizeStore.getState().armedRegenerate).toBeNull();
  });

  it("toggleRegenerate arms when off, and disarms when the same id is passed", () => {
    const { toggleRegenerate } = useKvResizeStore.getState();
    toggleRegenerate("exp-1");
    expect(useKvResizeStore.getState().armedRegenerate).toBe("exp-1");
    useKvResizeStore.getState().toggleRegenerate("exp-1");
    expect(useKvResizeStore.getState().armedRegenerate).toBeNull();
  });

  it("toggleRegenerate switches target when a different id is passed", () => {
    useKvResizeStore.getState().toggleRegenerate("exp-1");
    useKvResizeStore.getState().toggleRegenerate("exp-2");
    expect(useKvResizeStore.getState().armedRegenerate).toBe("exp-2");
  });
});
```

- [ ] 2. Run: `npx vitest run src/store/kv/useKvResizeStore.test.ts` — expect **FAIL** (`setResizePrompt`/`armRegenerate` etc. are not functions).

- [ ] 3. Minimal impl — replace `web/src/store/kv/useKvResizeStore.ts` body:

```ts
import { create } from "zustand";
import type { PlatformId } from "@/types/kv/resize";

const RESIZE_PROMPT_MAX = 1000;

type State = {
  selectedPlatformIds: Set<PlatformId>;
  togglePlatform: (id: PlatformId) => void;
  clearSelection: () => void;

  /** Optional batch prompt for the next New Resize submit. One prompt
   *  applies to every queued platform. Cleared after submit. */
  resizePrompt: string;
  setResizePrompt: (value: string) => void;

  /** Export id currently armed for guided regenerate, or null. Drives
   *  canvas focus, the locked chat chip, and the mode/model lock. */
  armedRegenerate: string | null;
  armRegenerate: (exportId: string) => void;
  disarmRegenerate: () => void;
  /** Arm `exportId`, or disarm if it's already the armed target. */
  toggleRegenerate: (exportId: string) => void;
};

export const useKvResizeStore = create<State>((set) => ({
  selectedPlatformIds: new Set(),

  togglePlatform: (id) =>
    set((s) => {
      const next = new Set(s.selectedPlatformIds);
      next.has(id) ? next.delete(id) : next.add(id);
      return { selectedPlatformIds: next };
    }),

  clearSelection: () => set({ selectedPlatformIds: new Set(), resizePrompt: "" }),

  resizePrompt: "",
  setResizePrompt: (value) =>
    set({ resizePrompt: value.slice(0, RESIZE_PROMPT_MAX) }),

  armedRegenerate: null,
  armRegenerate: (exportId) => set({ armedRegenerate: exportId }),
  disarmRegenerate: () => set({ armedRegenerate: null }),
  toggleRegenerate: (exportId) =>
    set((s) => ({
      armedRegenerate: s.armedRegenerate === exportId ? null : exportId,
    })),
}));
```

- [ ] 4. Run: `npx vitest run src/store/kv/useKvResizeStore.test.ts` — expect **PASS**.

- [ ] 5. Commit: `feat(web): add resizePrompt + armedRegenerate state to kv resize store`

---

## Task 2 — `api.ts` + `useResizeExports`: send `additional_prompt`

Thread `additionalPrompt` through both mutations and serialize it as `additional_prompt` in the request body. Keep sending `crop_window: null` on regenerate (dead param, do not remove yet).

**Files:**
- Modify: `web/src/services/kv/api.ts` (`createResizeExports` ~L572, `regenerateResizeExport` ~L592)
- Modify: `web/src/lib/studio/kv/useResizeExports.ts` (`create` ~L73, `regenerate` ~L97)
- Test: `web/src/services/kv/api.test.ts` (extend), `web/src/lib/studio/kv/useResizeExports.test.ts` (extend)

Steps:

- [ ] 1. Add failing wire test to `web/src/services/kv/api.test.ts`:

```ts
import { createResizeExports, regenerateResizeExport } from "@/services/kv/api";

describe("resize-exports — additional_prompt wire-up", () => {
  const wireRow = {
    id: "r1", studio_file_id: "f1", parent_generation_id: "g1",
    platform_id: "instagram-post", platform_label: "Instagram Post",
    platform_group: "social-media", width: 1080, height: 1080,
    image_url: null, status: "pending", crop_window: null, overlays: null,
    error_message: null, created_at: "x", updated_at: "x",
  };

  it("createResizeExports sends additional_prompt when provided", async () => {
    (axiosInstance.post as any).mockResolvedValue({ data: { data: [wireRow] } });
    await createResizeExports("f1", {
      parentGenerationId: "g1",
      platformIds: ["instagram-post"],
      additionalPrompt: "keep text at bottom",
    });
    expect(axiosInstance.post).toHaveBeenCalledWith(
      "v1/studio/files/f1/resize-exports",
      {
        parent_generation_id: "g1",
        platform_ids: ["instagram-post"],
        crop_windows: undefined,
        additional_prompt: "keep text at bottom",
      },
    );
  });

  it("createResizeExports sends additional_prompt: null when omitted", async () => {
    (axiosInstance.post as any).mockResolvedValue({ data: { data: [wireRow] } });
    await createResizeExports("f1", {
      parentGenerationId: "g1",
      platformIds: ["instagram-post"],
    });
    expect(axiosInstance.post).toHaveBeenCalledWith(
      "v1/studio/files/f1/resize-exports",
      expect.objectContaining({ additional_prompt: null }),
    );
  });

  it("regenerateResizeExport sends additional_prompt and crop_window: null", async () => {
    (axiosInstance.post as any).mockResolvedValue({ data: { data: wireRow } });
    await regenerateResizeExport("f1", "r1", "make the bg calmer");
    expect(axiosInstance.post).toHaveBeenCalledWith(
      "v1/studio/files/f1/resize-exports/r1/regenerate",
      { crop_window: null, additional_prompt: "make the bg calmer" },
    );
  });

  it("regenerateResizeExport sends additional_prompt: null on empty retry", async () => {
    (axiosInstance.post as any).mockResolvedValue({ data: { data: wireRow } });
    await regenerateResizeExport("f1", "r1");
    expect(axiosInstance.post).toHaveBeenCalledWith(
      "v1/studio/files/f1/resize-exports/r1/regenerate",
      { crop_window: null, additional_prompt: null },
    );
  });
});
```

- [ ] 2. Run: `npx vitest run src/services/kv/api.test.ts` — expect **FAIL** (`additionalPrompt` arg not accepted; body has no `additional_prompt`).

- [ ] 3. Impl in `web/src/services/kv/api.ts`. Update `createResizeExports`:

```ts
export async function createResizeExports(
  fileId: string,
  body: {
    parentGenerationId: string;
    platformIds: PlatformId[];
    cropWindows?: Partial<Record<PlatformId, CropWindow>>;
    /** Optional batch instruction; sent as `additional_prompt`. */
    additionalPrompt?: string | null;
  },
): Promise<KvResizeExport[]> {
  const { data } = await axiosInstance.post(
    `v1/studio/files/${fileId}/resize-exports`,
    {
      parent_generation_id: body.parentGenerationId,
      platform_ids: body.platformIds,
      crop_windows: body.cropWindows,
      additional_prompt: body.additionalPrompt ?? null,
    },
  );
  const rows: WireResizeExport[] = unwrap(data);
  return rows.map(toResizeExport);
}
```

Update `regenerateResizeExport` (drop `cropWindow` param — it's always sent as `null`; add `additionalPrompt`):

```ts
export async function regenerateResizeExport(
  fileId: string,
  exportId: string,
  additionalPrompt?: string | null,
): Promise<KvResizeExport> {
  const { data } = await axiosInstance.post(
    `v1/studio/files/${fileId}/resize-exports/${exportId}/regenerate`,
    { crop_window: null, additional_prompt: additionalPrompt ?? null },
  );
  return toResizeExport(unwrap<WireResizeExport>(data));
}
```

- [ ] 4. Impl in `web/src/lib/studio/kv/useResizeExports.ts`. Update the `create` mutation vars + call:

```ts
  const create = useMutation({
    mutationFn: (vars: {
      platformIds: PlatformId[];
      cropWindows?: Partial<Record<PlatformId, CropWindow>>;
      additionalPrompt?: string | null;
    }) => {
      if (!parentGenerationId) throw new Error("No parent generation");
      return createResizeExports(fileId, {
        parentGenerationId,
        platformIds: vars.platformIds,
        cropWindows: vars.cropWindows,
        additionalPrompt: vars.additionalPrompt ?? null,
      });
    },
    onSuccess: (rows) => { /* unchanged */ },
  });
```

Update the `regenerate` mutation vars + call (replace `cropWindow` with `additionalPrompt`):

```ts
  const regenerate = useMutation({
    mutationFn: (vars: { exportId: string; additionalPrompt?: string | null }) =>
      regenerateResizeExport(fileId, vars.exportId, vars.additionalPrompt ?? null),
    onSuccess: (row) => {
      qc.setQueryData<KvResizeExport[]>(
        QUERY_KEY(fileId, parentGenerationId),
        (prev) => (prev ?? []).map((r) => (r.id === row.id ? row : r)),
      );
    },
  });
```

> Note: `CropWindow` may become unused in `useResizeExports.ts` imports after this — keep it only if `create.cropWindows` still references it (it does), otherwise remove from the import to satisfy lint. Existing call sites `regenerateResize.mutate({ exportId: ex.id })` in `KvGeneratorLayout.tsx` (handleRetryResize ~L287) and `regenerate.mutate({ exportId })` in `KvResizeCanvas.tsx` (~L319) stay valid (no `additionalPrompt` = plain retry).

- [ ] 5. Run: `npx vitest run src/services/kv/api.test.ts src/lib/studio/kv/useResizeExports.test.ts` — expect **PASS**.

- [ ] 6. Commit: `feat(web): forward additional_prompt on resize + regenerate mutations`

---

## Task 3 — `KvResizePanel`: optional prompt textarea above "Start Resizing"

Add a capped `<textarea>` (placeholder "Any specific instructions? (Optional)") wired to `resizePrompt`, forward it on submit, and clear it after.

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvResizePanel.tsx` (button block ~L113-123)
- Modify: `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx` (`onResize` ~L860, store wiring ~L251)
- Test: covered by Task 1 store cap test + a layout submit-wiring assertion below (logic test; JSX is a described impl step).

Steps:

- [ ] 1. Failing test — add to `web/src/store/kv/useKvResizeStore.test.ts` (the submit contract: after a New Resize submit the prompt is cleared). This guards the "clear after submit" behavior at the store level (the panel calls `setResizePrompt("")`):

```ts
it("resize prompt round-trips and can be cleared after submit", () => {
  useKvResizeStore.getState().setResizePrompt("calmer background");
  expect(useKvResizeStore.getState().resizePrompt).toBe("calmer background");
  // Submit handler clears it:
  useKvResizeStore.getState().setResizePrompt("");
  expect(useKvResizeStore.getState().resizePrompt).toBe("");
});
```

- [ ] 2. Run: `npx vitest run src/store/kv/useKvResizeStore.test.ts` — expect **PASS** (setter already exists from Task 1; this documents the contract the JSX relies on).

- [ ] 3. Impl — `KvResizePanel.tsx`. Add two props to `Props`:

```ts
  /** Current batch prompt (controlled). */
  resizePrompt: string;
  /** Update the batch prompt. */
  onResizePromptChange: (value: string) => void;
```

Destructure them in the component signature, and render the textarea directly above the Start Resizing button — replace the footer block (~L113-123):

```tsx
      <div className="flex flex-col gap-2 border-t border-[rgba(255,255,255,0.05)] p-3">
        <textarea
          value={resizePrompt}
          onChange={(e) => onResizePromptChange(e.target.value)}
          maxLength={1000}
          rows={2}
          placeholder="Any specific instructions? (Optional)"
          aria-label="Resize instructions"
          className="w-full resize-none rounded-lg border border-[rgba(255,255,255,0.08)] bg-[rgba(255,255,255,0.04)] px-3 py-2 font-geist text-textSm text-text-inverse placeholder:text-text-inverse-subtlest focus:outline-none focus:ring-1 focus:ring-[rgba(255,255,255,0.2)]"
        />
        <Button
          onClick={onResize}
          disabled={disabled || queuedCount === 0}
          className="w-full"
        >
          {queuedCount === 0
            ? "Start Resizing"
            : `Resize · ${queuedCount} selected`}
        </Button>
      </div>
```

- [ ] 4. Impl — `KvGeneratorLayout.tsx`. Read the new store slices near L251:

```ts
  const resizePrompt = useKvResizeStore((s) => s.resizePrompt);
  const setResizePrompt = useKvResizeStore((s) => s.setResizePrompt);
```

Pass them to `<KvResizePanel>` (~L855) and forward + clear on submit (`onResize` ~L860):

```tsx
                    <KvResizePanel
                      disabled={createResize.isPending}
                      selectedIds={selectedPlatformIds}
                      exportsByPlatformId={exportsByPlatformId}
                      onToggle={togglePlatform}
                      resizePrompt={resizePrompt}
                      onResizePromptChange={setResizePrompt}
                      onResize={() => {
                        const queued = Array.from(selectedPlatformIds).filter(
                          (id) => !exportsByPlatformId.has(id)
                        );
                        if (queued.length === 0) return;
                        const prompt = resizePrompt.trim();
                        createResize.mutate({
                          platformIds: queued,
                          additionalPrompt: prompt.length > 0 ? prompt : null,
                        });
                        setResizePrompt("");
                      }}
                      onRemove={handleRemoveResize}
                      onRetry={handleRetryResize}
                      onScrollToPlatform={handleScrollToPlatform}
                    />
```

- [ ] 5. Run typecheck/lint on the touched files: `npx tsc --noEmit -p tsconfig.json 2>&1 | grep -E 'KvResizePanel|KvGeneratorLayout' || echo "no type errors in touched files"`. Expect no errors for these files.

- [ ] 6. Commit: `feat(web): add optional batch prompt textarea to resize panel`

---

## Task 4 — ⟳ arms regenerate; canvas focus + cancel affordance

The per-tile ⟳ no longer fires the mutation. It calls `onArmRegenerate(exportId)` which toggles `armedRegenerate`. The armed tile is focused (set as active), and a ✕/toggle cancels.

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvResizeResultRow.tsx` (⟳ button ~L122-129; rename `onAdjustCrop` semantics — keep prop name or rename to `onArmRegenerate`)
- Modify: `web/src/components/studio/kv-generator/KvResizeCanvas.tsx` (`regenerateExport`/`onAdjustCrop` ~L319, ~L387)
- Test: behavioral logic is in the store (`toggleRegenerate`, Task 1). JSX wiring is a described impl step; add an `armed`-state visual assertion as an optional rendering note.

Steps:

- [ ] 1. Failing test — already covered by Task 1's `toggleRegenerate` tests (arm/disarm/switch). No new test needed; the canvas wiring is pure prop plumbing. Confirm Task 1 tests still pass: `npx vitest run src/store/kv/useKvResizeStore.test.ts` — expect **PASS**.

- [ ] 2. Impl — `KvResizeResultRow.tsx`. Add an `armed` prop and rename the handler to `onArmRegenerate` (keep `onRetry` for the failed-state Retry which still fires immediately):

In `Props`, replace `onAdjustCrop: () => void;` with:

```ts
  /** Arm guided-regenerate mode for this tile (does NOT fire the
   *  mutation — the chat input captures the prompt and Send fires it). */
  onArmRegenerate: () => void;
  /** True when this tile is the armed regenerate target — shows the ⟳
   *  button in an active/pressed state. */
  armed: boolean;
```

Destructure `onArmRegenerate, armed` in the component, and update the ⟳ button (~L122-129):

```tsx
          <button
            type="button"
            onClick={onArmRegenerate}
            aria-label="Regenerate"
            aria-pressed={armed}
            className={[
              "flex h-6 w-6 items-center justify-center rounded-md transition-colors",
              armed
                ? "bg-[rgba(255,255,255,0.12)] text-text-inverse"
                : "text-text-inverse-subtlest hover:bg-[rgba(255,255,255,0.05)]",
            ].join(" ")}
          >
            <ArrowsClockwise size={16} className={armed ? "text-text-inverse" : "text-text-inverse-subtlest"} />
          </button>
```

- [ ] 3. Impl — `KvResizeCanvas.tsx`. Bring in the store and replace the immediate-fire wiring. Add near the top of the component (after `useResizeExports`, ~L73):

```ts
  const armedRegenerate = useKvResizeStore((s) => s.armedRegenerate);
  const toggleRegenerate = useKvResizeStore((s) => s.toggleRegenerate);
```

(Add `import { useKvResizeStore } from "@/store/kv/useKvResizeStore";` at the top.)

Replace the `regenerateExport` helper (~L319) — keep it ONLY for the failed-state Retry (plain retry, no prompt):

```ts
  // Failed-state Retry stays an immediate plain retry (no prompt).
  const retryExport = (id: string) => regenerate.mutate({ exportId: id });

  // Arming focuses the tile so the canvas matches the chat target.
  const armTile = (id: string) => {
    toggleRegenerate(id);
    setActiveTileId(id);
  };
```

Update the `<KvResizeResultRow>` props (~L387):

```tsx
              onArmRegenerate={() => armTile(row.id)}
              armed={armedRegenerate === row.id}
              onRetry={() => retryExport(row.id)}
```

> Note: the existing comment block at ~L384-386 ("Regenerate goes through the AI path…") should be updated to: "⟳ arms guided regenerate (the chat input captures the prompt and Send fires it). Failed-state Retry stays a plain immediate retry." Also clear `armedRegenerate` when the tile is removed if it was armed — `useResizeExports.remove` already drops the row; add a `disarmRegenerate()` call in the layout's `handleRemoveResize` if `armedRegenerate === ex.id` (Task 5 wires the disarm provider; safe to add here too).

- [ ] 4. Run: `npx tsc --noEmit -p tsconfig.json 2>&1 | grep -E 'KvResizeResultRow|KvResizeCanvas' || echo "no type errors in touched files"`. Expect none.

- [ ] 5. Commit: `feat(web): arm guided regenerate from tile instead of firing immediately`

---

## Task 5 — `KvChat` resize-mode: hide ModeButton, disable ModelButton, armed Send fires regenerate

When a tile is armed, the chat input shows a locked target chip, hides Brainstorm/Design, disables the model dropdown, and Send calls the regenerate mutation (with `additional_prompt`) instead of `stream.send`. Empty prompt = plain retry. Cancel via ✕ on the chip.

**Files:**
- Modify: `web/src/components/studio/kv-generator/KvChat.tsx` (ChatInputBar tools row ~L1348-1361, `onSend` ~L1105, `ModelButton` ~L1475 disabled path)
- Modify: `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx` (`<KvChat>` props ~L964 — pass armed target + a regenerate callback + disarm)
- Test: `web/src/lib/studio/kv/useResizeExports.test.ts` (extend — armed Send path fires regenerate with the prompt). The JSX (chip render, hidden ModeButton, disabled ModelButton) is described impl.

Steps:

- [ ] 1. Failing test — add to `web/src/lib/studio/kv/useResizeExports.test.ts` proving the regenerate mutation forwards `additionalPrompt` to the API (this is the behavior the armed Send relies on):

```ts
import { regenerateResizeExport } from "@/services/kv/api";

describe("useResizeExports — regenerate forwards additionalPrompt", () => {
  it("calls regenerateResizeExport with the prompt", async () => {
    (listResizeExports as any).mockResolvedValue([baseRow]);
    (regenerateResizeExport as any).mockResolvedValue({ ...baseRow, status: "pending" });

    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    const wrapper = ({ children }: { children: React.ReactNode }) =>
      createElement(QueryClientProvider, { client: qc }, children);
    const { result } = renderHook(() => useResizeExports("file-1", "gen-1"), { wrapper });

    await waitFor(() => expect(result.current.query.data).toHaveLength(1));
    await act(async () => {
      result.current.regenerate.mutate({ exportId: "r1", additionalPrompt: "calmer bg" });
    });
    await waitFor(() => expect(result.current.regenerate.isSuccess).toBe(true));

    expect(regenerateResizeExport).toHaveBeenCalledWith("file-1", "r1", "calmer bg");
  });
});
```

(Add `regenerateResizeExport` to the existing `vi.mock("@/services/kv/api", …)` import list at the top — it's already mocked, just import it.)

- [ ] 2. Run: `npx vitest run src/lib/studio/kv/useResizeExports.test.ts` — expect **PASS** (the mutation impl from Task 2 already supports this; this test locks the contract the armed Send depends on).

- [ ] 3. Impl — `KvChat.tsx` props. Add to the `KvChat` `Props` type and `ChatInputBar` prop type:

```ts
  /** Resize guided-regenerate target. When non-null the chat input enters
   *  resize-mode: locked chip, ModeButton hidden, ModelButton disabled,
   *  and Send fires the regenerate mutation instead of the agent stream. */
  resizeRegenerate?: {
    exportId: string;
    platformLabel: string;
    width: number;
    height: number;
    thumbnailUrl: string | null;
    /** Fire the regenerate REST mutation. `null` prompt = plain retry. */
    onSubmit: (additionalPrompt: string | null) => void;
    /** Cancel armed mode (✕ on the chip / Escape). */
    onCancel: () => void;
  } | null;
```

Default it to `null` in both destructures and forward from `KvChat` → `ChatInputBar` (~L379, add `resizeRegenerate={resizeRegenerate}`).

- [ ] 4. Impl — `ChatInputBar` resize-mode branch.

(a) Derive the flag near the top of `ChatInputBar`:

```ts
  const isResizeMode = Boolean(resizeRegenerate);
```

(b) In `onSend` (~L1105), short-circuit BEFORE the stream path. Insert right after the `isPreparing` guard (~L1111):

```ts
    // Resize-mode: the chat box is a prompt-capture UI that fires the
    // regenerate REST endpoint directly — NOT an Agno turn.
    if (resizeRegenerate) {
      const text = flattenBlocksToText(promptBlocks).trim();
      resizeRegenerate.onSubmit(text.length > 0 ? text : null);
      setPromptBlocks([]);
      return;
    }
```

(c) Render the locked chip above the editor (inside the input container ~L1303, before the `<KvLexicalEditor>` block). Use SelectionPill's styling as the reference (not removable except via the explicit ✕ that calls `onCancel`):

```tsx
      {resizeRegenerate && (
        <div className="flex items-center gap-2 px-4 pt-3">
          <span className="inline-flex h-8 items-center gap-2 rounded-xl border border-[rgba(255,255,255,0.08)] bg-[rgba(255,255,255,0.05)] py-1 pl-1 pr-2">
            {resizeRegenerate.thumbnailUrl && (
              /* eslint-disable-next-line @next/next/no-img-element */
              <img
                src={resizeRegenerate.thumbnailUrl}
                alt=""
                className="h-6 w-6 rounded-md object-cover ring-1 ring-white/10"
              />
            )}
            <span className="font-geist text-textXsMedium font-medium leading-[1.4] tracking-[-0.12px] text-text-inverse">
              {resizeRegenerate.platformLabel} · {resizeRegenerate.width}×{resizeRegenerate.height}
            </span>
            <button
              type="button"
              onClick={resizeRegenerate.onCancel}
              aria-label="Cancel regenerate"
              className="ml-1 flex h-4 w-4 items-center justify-center rounded-full text-text-inverse-subtle transition-colors hover:bg-[rgba(255,255,255,0.08)] hover:text-text-inverse"
            >
              <X size={10} />
            </button>
          </span>
        </div>
      )}
```

(d) Tools row (~L1348-1361): hide `ModeButton` and disable `ModelButton` in resize-mode. Update the left cluster:

```tsx
        <div className="flex items-center gap-4">
          <button
            type="button"
            aria-label="Attach"
            onClick={() => fileInputRef.current?.click()}
            className="flex h-8 w-8 items-center justify-center rounded-full transition-colors hover:bg-[rgba(255,255,255,0.05)]"
          >
            <Paperclip size={16} className="text-text-inverse" />
          </button>
          {!isResizeMode && (
            <ModeButton mode={stream.mode} onChange={stream.setMode} />
          )}
          <ModelButton editMode={hasBoxes} disabled={isResizeMode} />
        </div>
```

(e) `ModelButton` (~L1475): add a `disabled` prop. When `disabled`, render a static, non-interactive label (the resize engine) and never open the menu:

```ts
function ModelButton({ editMode = false, disabled = false }: { editMode?: boolean; disabled?: boolean }) {
```

Guard the trigger `onClick` and styling. In the trigger button:

```tsx
      <button
        type="button"
        onClick={() => { if (!disabled) setOpen((v) => !v); }}
        disabled={disabled}
        aria-disabled={disabled}
        aria-haspopup="menu"
        aria-expanded={disabled ? undefined : open}
        className={[
          "flex h-8 items-center gap-2 rounded-lg transition-colors",
          disabled ? "cursor-default opacity-60" : "hover:bg-[rgba(255,255,255,0.05)]",
        ].join(" ")}
      >
```

When `disabled`, the static label is "Resize engine" (the dropdown stays closed). Find the trigger's label span and render `disabled ? "Resize engine" : <current model label>`. Also early-return the menu render when `disabled` (i.e. `{!disabled && open && (…menu…)}`).

> Note: `Send` itself stays enabled in resize-mode (empty prompt = plain retry), so the existing empty-text guard (`if (!flattened && !hasBoxes && !hasAttachments) return;`) is bypassed by the resize-mode short-circuit added in step (b) — that branch returns before reaching the guard.

- [ ] 5. Impl — `KvGeneratorLayout.tsx`. Build the `resizeRegenerate` object from the armed store state and pass to `<KvChat>` (~L964). Near the resize-mode block (after `exportsByPlatformId`, ~L260), derive it:

```ts
  const armedRegenerate = useKvResizeStore((s) => s.armedRegenerate);
  const disarmRegenerate = useKvResizeStore((s) => s.disarmRegenerate);

  const armedExport = useMemo(() => {
    if (!armedRegenerate) return null;
    for (const ex of exportsByPlatformId.values()) {
      if (ex.id === armedRegenerate) return ex;
    }
    return null;
  }, [armedRegenerate, exportsByPlatformId]);

  const resizeRegenerate = useMemo(() => {
    if (!armedExport) return null;
    return {
      exportId: armedExport.id,
      platformLabel: armedExport.platformLabel,
      width: armedExport.width,
      height: armedExport.height,
      thumbnailUrl: armedExport.imageUrl,
      onSubmit: (additionalPrompt: string | null) => {
        regenerateResize.mutate({ exportId: armedExport.id, additionalPrompt });
        disarmRegenerate();
      },
      onCancel: () => disarmRegenerate(),
    };
  }, [armedExport, regenerateResize, disarmRegenerate]);
```

Pass `resizeRegenerate={resizeRegenerate}` to `<KvChat>` (~L964). Also, in `handleRemoveResize` (~L275), disarm if removing the armed tile:

```ts
  const handleRemoveResize = useCallback(
    (platformId: PlatformId) => {
      const ex = exportsByPlatformId.get(platformId);
      if (!ex) return;
      if (armedRegenerate === ex.id) disarmRegenerate();
      removeResize.mutate(ex.id);
    },
    [exportsByPlatformId, removeResize, armedRegenerate, disarmRegenerate]
  );
```

> `useMemo` is already imported in the layout (used elsewhere). Confirm; if not, add it.

- [ ] 6. Run: `npx vitest run src/lib/studio/kv/useResizeExports.test.ts src/store/kv/useKvResizeStore.test.ts` — expect **PASS**. Then `npx tsc --noEmit -p tsconfig.json 2>&1 | grep -E 'KvChat|KvGeneratorLayout' || echo "no type errors in touched files"`.

- [ ] 7. Commit: `feat(web): resize-mode chat input fires regenerate directly with prompt`

---

## Task 6 — `MessagesList`: system-marker message renderer

Render the persisted resize/regenerate marker rows that arrive through the existing chat-history fetch.

> ✅ **CONTRACT (LOCKED — matches the api plan, Task 7):**
> The api `KvGeneratorFileController::show()` surfaces each `kind: 'resize_marker'` history row **flat**, exactly like the existing `question_card`/`mode_suggestion` cards — it does NOT build a `metadata` object:
> ```
> { id, role: "assistant", text: <copy>, kind: "resize_marker",
>   payload: { action, platform_ids, platform_labels, additional_prompt, export_ids } }
> ```
> Web's `useKvStream.hydrateInitialMessages` rebuilds the renderer's metadata from this flat `kind`+`payload`, **mirroring exactly how it rebuilds `metadata.questionCard`** (useKvStream.ts:231-263). The api-provided shape is `snake_case` on `payload`; the rebuilt `metadata.resizeMarker` object is camelCase:
> ```ts
> metadata.resizeMarker = {
>   action: "resize" | "regenerate",  // = payload.action
>   text: string,                     // = the row's `text` (server-authored copy)
>   platformLabels: string[],         // = payload.platform_labels
>   prompt: string | null,            // = payload.additional_prompt
> }
> ```

**Files:**
- Modify: `web/src/hooks/useKvStream.ts` — (a) `ChatMessageMeta` ~L29: add `resizeMarker`; (b) the `initialMessages` `kind` union (~L169 and the `hydrateInitialMessages` param ~L200): add `"resize_marker"`; (c) `hydrateInitialMessages` (~L231-288): add a `resize_marker` branch next to the `question_card`/`mode_suggestion` branches.
- Modify: `web/src/components/studio/kv-generator/KvChat.tsx` (`MessagesList` ~L477, add a branch before the default assistant text)
- Test: a lightweight render-logic test for the type guard is impractical; instead add the type to `ChatMessageMeta` and gate the renderer behind the guard. The marker copy is server-provided (`text`), so the FE only renders it.

Steps:

- [ ] 1. Impl — `useKvStream.ts`. Add to `ChatMessageMeta` (~L29):

```ts
  /** Persisted resize/regenerate marker row (api-written `kind:'resize_marker'`),
   *  rebuilt here from the flat show() payload. Rendered as a centered, muted
   *  marker in the chat — not a bubble. */
  resizeMarker?: {
    action: "resize" | "regenerate";
    text: string;
    platformLabels: string[];
    prompt: string | null;
  };
```

Extend BOTH the `initialMessages` `kind` union (~L169) and the `hydrateInitialMessages` param `kind` (~L200) from `"question_card" | "mode_suggestion"` to `"question_card" | "mode_suggestion" | "resize_marker"`.

Then add a `resize_marker` branch in `hydrateInitialMessages`, immediately after the `mode_suggestion` branch (~L288), mirroring the `question_card` branch (L231-263) — rebuild `metadata.resizeMarker` from the flat `kind`+`payload`:

```ts
    if (
      m.kind === "resize_marker" &&
      m.payload &&
      typeof m.payload === "object"
    ) {
      const p = m.payload as {
        action?: "resize" | "regenerate";
        platform_labels?: string[];
        additional_prompt?: string | null;
      };
      return {
        id: m.id,
        role: "assistant",
        text: "",
        metadata: {
          resizeMarker: {
            action: p.action === "regenerate" ? "regenerate" : "resize",
            text: m.text,
            platformLabels: Array.isArray(p.platform_labels)
              ? p.platform_labels.map(String)
              : [],
            prompt: p.additional_prompt ?? null,
          },
        },
      };
    }
```

- [ ] 2. Impl — `MessagesList` in `KvChat.tsx`. Add a branch in the `stream.messages.map` BEFORE the default assistant text (i.e. before the `const tools = …` block ~L714), after the existing `m.metadata?.error` branch:

```tsx
        // Resize/regenerate marker (audit line) — persisted by the api,
        // surfaced as metadata.resizeMarker. Centered + muted, no bubble.
        if (m.metadata?.resizeMarker) {
          return (
            <div key={m.id} className="flex w-full justify-center px-6 py-3">
              <p className="max-w-[420px] text-center font-geist text-textXs leading-[1.4] text-text-inverse-subtlest">
                {m.metadata.resizeMarker.text}
              </p>
            </div>
          );
        }
```

- [ ] 3. Run: `npx tsc --noEmit -p tsconfig.json 2>&1 | grep -E 'KvChat|useKvStream' || echo "no type errors in touched files"`. Expect none. Run the full kv suite to confirm no regressions: `npx vitest run src/store/kv src/lib/studio/kv src/services/kv`.

- [ ] 4. Commit: `feat(web): render persisted resize/regenerate system markers in chat`

---

## Final verification

- [ ] Run the full kv test surface: `npx vitest run src/store/kv src/lib/studio/kv src/services/kv` — expect all PASS.
- [ ] Typecheck the touched files: `npx tsc --noEmit -p tsconfig.json` — expect no new errors.
- [ ] Lint the changed files: `bun run lint:changed` (or `npx eslint` on the touched paths).
- [ ] Manual smoke (resize mode): New Resize textarea forwards a batch prompt and clears after submit; ⟳ arms (does not fire), focuses the tile, shows the locked chip; in armed mode Brainstorm/Design is hidden and the model dropdown is a static "Resize engine"; Send fires regenerate with the prompt; empty Send = plain retry; ✕ cancels; marker lines appear after the api persists them.
