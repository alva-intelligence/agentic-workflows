# KV Generator — Craft Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the existing `Craft` tab in the canvas TopNav to a one-click polish pass over the latest Sketch-generated KV. Refine lighting, sharpness, color balance, and text legibility while preserving subjects, composition, layout, text wording, and aspect ratio. Result is a new version stamped `Craft`, lineage tracked via `parent_generation_id`. Spec: [`docs/superpowers/specs/2026-04-28-studio-kv-craft-mode-design.md`](../specs/2026-04-28-studio-kv-craft-mode-design.md).

**Architecture:** Three services. AI service gets a new `craft_mode` prompt + `canvas_mode` field on the stream request. API adds a `mode` column to `kv_generations` and accepts `canvas_mode` on the chat stream. Web renders the `KvCraftOverlay` (dim layer + Start Crafting pill / placeholder / disabled), wires the trigger via the existing `useKvStream`, and adds mode badges to version cards.

**Tech Stack:** Laravel 13 / PHP 8.5 (api), FastAPI / Python (ai-service), Next.js 16 / React 19 / TypeScript / react-konva (web). Bun test runner on web; Pest on api; pytest on ai-service.

**Branch:** `feature/daffa/vc-studio-projects-kv-generator` (extension of in-flight feature; no new branch).

---

## File Structure

**API (new):**
- `api/database/migrations/2026_04_28_xxxxxx_add_mode_to_kv_generations.php`

**API (modify):**
- `api/app/Models/KvGeneration.php` — add `mode` to `$fillable` + cast
- `api/app/Http/Resources/KvGenerationResource.php` — expose `mode`
- `api/app/Http/Controllers/Api/ChatController.php` (or wherever `/api/chat/stream` lives) — accept `canvas_mode`, validate `attached_generation_id` for craft, force `mode='image'` for craft, forward to AI service
- `api/app/Http/Controllers/Api/Internal/KvGeneratorCallbackController.php` — accept `mode` in callback body, persist to column

**AI service (new):**
- `ai-service/app/agents/kv_generator/prompts/craft_mode.py`

**AI service (modify):**
- `ai-service/app/agents/kv_generator/request_schema.py` — add `canvas_mode` field
- `ai-service/app/agents/kv_generator/prompts/__init__.py` — export `craft_mode`
- `ai-service/app/agents/kv_generator/service.py` — branch on `canvas_mode == 'craft'`: load parent, swap prompt, trim history, post callback with `mode='craft'`
- `ai-service/app/agents/kv_generator/api_client.py` — pass `mode` field on the internal callback

**Web (new):**
- `web/src/components/studio/kv-generator/KvCraftOverlay.tsx`
- `web/src/components/studio/kv-generator/KvCraftOverlay.test.tsx`

**Web (modify):**
- `web/src/components/studio/kv-generator/KvGeneratorLayout.tsx` — overlay rendering, Start Crafting handler, auto-revert on completion
- `web/src/components/studio/kv-generator/KvCanvas.tsx` — overlay slot
- `web/src/components/studio/kv-generator/KvCanvasBottomNav.tsx` — hide tools when `canvasMode === 'craft'`
- `web/src/components/studio/kv-generator/KvVersionCard.tsx` — mode badge
- `web/src/components/studio/kv-generator/KvVersionHistoryPanel.tsx` — mode badge in row
- `web/src/lib/studio/kv/useKvStream.ts` (or equivalent) — accept `canvasMode: 'craft'` in `send()`
- `web/src/types/studio.ts` (or wherever `KvGeneration` lives) — add `mode` field

---

## Service order

Implement in this order so each layer can be tested against a real downstream:

1. **API migration + model + resource** — unblocks downstream by giving the column to write to.
2. **AI service prompt + schema + service flow** — unblocks the request shape.
3. **API chat-stream + callback wiring** — connects ends.
4. **Web overlay + trigger + badges** — user-facing.

Each section below is a coherent unit. Mark each task complete as it lands.

---

## Section A — API: data model + plumbing

### Task A1: Migration

- [ ] **Step A1.1** — Create migration `api/database/migrations/2026_04_28_xxxxxx_add_mode_to_kv_generations.php`:

```php
public function up(): void
{
    Schema::table('kv_generations', function (Blueprint $table) {
        $table->string('mode', 16)->default('sketch')->after('model');
        $table->index(['studio_file_id', 'mode', 'created_at']);
    });
}

public function down(): void
{
    Schema::table('kv_generations', function (Blueprint $table) {
        $table->dropIndex(['studio_file_id', 'mode', 'created_at']);
        $table->dropColumn('mode');
    });
}
```

- [ ] **Step A1.2** — Run migration on local dev DB (read `CLAUDE.md` memory: verify `phpunit.xml` SQLite override before running tests against the dev DB). Confirm column exists: `\d+ kv_generations` shows `mode varchar(16) DEFAULT 'sketch'`.

### Task A2: Model + resource

- [ ] **Step A2.1** — In `api/app/Models/KvGeneration.php`, add `'mode'` to `$fillable` and cast it to a string. If a `KvGenerationMode` enum class makes sense (matching the `ThreadType` enum pattern in `app/Enums/`), create `app/Enums/KvGenerationMode.php` with cases `Sketch = 'sketch'`, `Craft = 'craft'`, `Resize = 'resize'`. Otherwise plain string is fine for v1.
- [ ] **Step A2.2** — In `api/app/Http/Resources/KvGenerationResource.php`, return `'mode' => $this->mode`.
- [ ] **Step A2.3** — Pest unit test in `api/tests/Unit/Http/Resources/KvGenerationResourceTest.php` (or extend existing): asserts the resource includes `mode` and that it defaults to `'sketch'` for new rows that don't pass an explicit mode.

### Task A3: Chat stream — accept `canvas_mode`

- [ ] **Step A3.1** — Locate the existing chat-stream request validator (likely `api/app/Http/Requests/ChatStreamRequest.php` or inline in the controller). Add validation:

```php
'canvas_mode' => ['nullable', Rule::in(['sketch', 'craft', 'resize'])],
'attached_generation_id' => [
    'nullable', 'ulid',
    Rule::requiredIf(fn () => $this->input('canvas_mode') === 'craft'),
],
```

- [ ] **Step A3.2** — In the controller before forwarding to AI service, if `canvas_mode === 'craft'`:
  - Force `mode = 'image'` (overwrite or assert).
  - Look up the parent generation by `attached_generation_id`, verify it belongs to the same `studio_file_id`. 422 with clear message if mismatch.
  - Pass `canvas_mode` through to AI service in the forwarded payload.
- [ ] **Step A3.3** — Pest feature test: `tests/Feature/ChatStreamCanvasModeTest.php`:
  - 422 when `canvas_mode=craft` and `attached_generation_id` missing.
  - 422 when `attached_generation_id` belongs to a different file.
  - 200 when valid; assert AI-service forward payload contains `canvas_mode='craft'`.

### Task A4: Internal callback persists `mode`

- [ ] **Step A4.1** — In the internal callback controller (likely `app/Http/Controllers/Api/Internal/KvGeneratorCallbackController.php`), add to validated body:

```php
'mode' => ['nullable', Rule::in(['sketch', 'craft', 'resize'])],
```

- [ ] **Step A4.2** — When persisting `KvGeneration::create([...])`, include `'mode' => $validated['mode'] ?? 'sketch'`.
- [ ] **Step A4.3** — Pest feature test: `tests/Feature/Internal/KvGeneratorCallbackTest.php`:
  - Existing happy-path test gets a parameterized variant for `mode='craft'`.
  - Assert the persisted row has `mode='craft'` and `parent_generation_id` set.

### Task A5: Activity logging

- [ ] **Step A5.1** — Wherever `studio_activities` is written for KV generation (likely a service class invoked from the callback), branch on `mode`:
  - `mode='sketch'` → action `'kv_generated'` (existing).
  - `mode='craft'` → action `'kv_craft_completed'` (new) with metadata `{ parent_generation_id, generation_id }`.
- [ ] **Step A5.2** — On the chat-stream forward (Task A3 controller), log `'kv_craft_started'` with metadata `{ parent_generation_id }` when `canvas_mode='craft'`. On AI-service failure response, log `'kv_craft_failed'`.
- [ ] **Step A5.3** — Pest test asserting both activity rows are written for a successful craft round-trip.

---

## Section B — AI service: craft prompt + service flow

### Task B1: Craft prompt

- [ ] **Step B1.1** — Create `ai-service/app/agents/kv_generator/prompts/craft_mode.py`:

```py
GUIDANCE = (
    "In craft mode you are POLISHING an existing key visual. The user has "
    "approved its composition and just wants it refined. You MUST preserve: "
    "the subjects, their pose and identity, the layout and framing, the "
    "background scene, the brand elements, and any text content (wording, "
    "language, position, hierarchy). You MAY refine: lighting consistency, "
    "edge sharpness, color balance, contrast, micro-details, text rendering "
    "quality (fix garbled or warped letterforms while keeping the same "
    "wording), and overall production polish. Do NOT add or remove subjects. "
    "Do NOT redesign layouts. Do NOT change wording or language. Do NOT "
    "change aspect ratio. Your reply MUST be a single paragraph image prompt "
    "that describes the SAME scene as the reference image with these "
    "refinements applied. Reference the parent image as the source of "
    "truth for everything visual; only the refinements above are additive. "
    "Do not address the user, ask questions, or include meta commentary."
)
```

- [ ] **Step B1.2** — Update `ai-service/app/agents/kv_generator/prompts/__init__.py` to expose `craft_mode` alongside `chat_mode` and `image_mode`.
- [ ] **Step B1.3** — pytest unit test: `ai-service/tests/agents/kv_generator/test_prompts.py` adds an assertion that `craft_mode.GUIDANCE` is non-empty and contains the strings `"polish"`, `"preserve"`, `"composition"`. Cheap regression guard against future edits that drop the constraints.

### Task B2: Request schema

- [ ] **Step B2.1** — In `ai-service/app/agents/kv_generator/request_schema.py`, add field:

```py
canvas_mode: Literal["sketch", "craft", "resize"] = "sketch"
```

- [ ] **Step B2.2** — Add a Pydantic root-validator (or `@model_validator`):
  - If `canvas_mode == "craft"`, require `attached_generation_id` is set (raise ValueError otherwise).
  - If `canvas_mode == "craft"`, require `mode == "image"` (raise ValueError otherwise).
- [ ] **Step B2.3** — pytest unit tests for the validators in `tests/agents/kv_generator/test_request_schema.py` covering: valid craft request, missing parent (raises), `mode='chat'` with `canvas_mode='craft'` (raises), valid sketch (default).

### Task B3: Service flow

- [ ] **Step B3.1** — In `ai-service/app/agents/kv_generator/service.py`, branch early on `request.canvas_mode == "craft"`:
  - Fetch the parent generation via `api_client.get_generation(request.attached_generation_id)` — endpoint already exists for variation chains; reuse it.
  - Build the system prompt: `base.GUIDANCE + craft_mode.GUIDANCE` (skip `image_mode.GUIDANCE` for craft).
  - Trim chat history: pass only the parent generation's `prompt_snapshot` as the prior context. Drop other turns.
  - If `request.prompt` is empty, substitute the canned default ("Refine this key visual — preserve composition, subjects, and text. Improve lighting, sharpness, color balance, and text legibility.").
  - Run image generation with `parent_image_url=parent.image_url` (image-to-image). The existing `generate_image` tool already supports this path — same as Sketch's variation flow.
- [ ] **Step B3.2** — In the internal callback POST (where Sketch posts `mode` is currently absent), include `mode="craft"` for craft generations and `mode="sketch"` for everyone else.
- [ ] **Step B3.3** — pytest test in `tests/agents/kv_generator/test_service.py`:
  - Mock `api_client.get_generation` and `generate_image` tool.
  - Send a craft request, assert the prompt sent to the model contains `craft_mode.GUIDANCE` and NOT `image_mode.GUIDANCE`.
  - Assert the callback payload posted to the API mock has `mode='craft'` and `parent_generation_id` set.
  - Assert chat history passed to the model contains exactly one prior message (the parent's `prompt_snapshot`), not the full thread.

### Task B4: SSE events unchanged

No new event types. `generating` / `generation_done` / `generation_failed` reused as-is. `generation_done` payload includes `KvGenerationResource` which now carries `mode`.

- [ ] **Step B4.1** — Confirm via grep that `events.py` does not need changes. Add a comment if useful.

---

## Section C — Web: overlay, trigger, badges

### Task C1: `KvCraftOverlay` component (TDD)

- [ ] **Step C1.1** — Write failing tests at `web/src/components/studio/kv-generator/KvCraftOverlay.test.tsx`:

```tsx
import { describe, expect, it, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { KvCraftOverlay } from "./KvCraftOverlay";

describe("KvCraftOverlay", () => {
  it("renders the Start Crafting pill in ready state", () => {
    const onStart = vi.fn();
    render(<KvCraftOverlay status="ready" onStartCrafting={onStart} />);
    expect(screen.getByRole("button", { name: /start crafting/i })).toBeVisible();
  });

  it("calls onStartCrafting when the pill is clicked", () => {
    const onStart = vi.fn();
    render(<KvCraftOverlay status="ready" onStartCrafting={onStart} />);
    fireEvent.click(screen.getByRole("button", { name: /start crafting/i }));
    expect(onStart).toHaveBeenCalledTimes(1);
  });

  it("renders the polishing state with a spinner and timer", () => {
    render(<KvCraftOverlay status="polishing" onStartCrafting={() => {}} />);
    expect(screen.getByText(/polishing/i)).toBeVisible();
    // Timer present (any text matching mm:ss or "0s")
    expect(screen.getByTestId("kv-craft-timer")).toBeVisible();
  });

  it("renders the disabled state when no generation exists", () => {
    const onStart = vi.fn();
    render(<KvCraftOverlay status="disabled" onStartCrafting={onStart} />);
    expect(screen.getByText(/generate a kv first/i)).toBeVisible();
    fireEvent.click(screen.getByText(/generate a kv first/i));
    expect(onStart).not.toHaveBeenCalled();
  });

  it("renders a 50% black dim layer over its parent", () => {
    const { container } = render(
      <KvCraftOverlay status="ready" onStartCrafting={() => {}} />,
    );
    const dim = container.querySelector('[data-testid="kv-craft-dim"]');
    expect(dim).toBeInTheDocument();
    expect(dim).toHaveClass("bg-black/45");
  });
});
```

- [ ] **Step C1.2** — Implement `KvCraftOverlay.tsx` to make the tests pass. Use frndos `Button` for the pill where it fits; otherwise a custom pill matching the Figma styling (white bg, MagicWand icon, drop shadow `0 8px 24px rgba(0,0,0,0.18)`). Polishing state mirrors `KvVersionCardPlaceholder`'s skeleton/timer.
- [ ] **Step C1.3** — Run `bun test` — all four cases pass.

### Task C2: Wire overlay into canvas

- [ ] **Step C2.1** — In `KvCanvas.tsx`, accept new props `canvasMode: CanvasMode`, `craftStatus: 'ready' | 'polishing' | 'disabled' | null`, and `onStartCrafting: () => void`. When `canvasMode === 'craft' && craftStatus !== null`, render `<KvCraftOverlay>` absolutely positioned over the image area.
- [ ] **Step C2.2** — In `KvGeneratorLayout.tsx`, derive `craftStatus`:
  - `polishing` if there's an in-flight generation with `canvas_mode='craft'`.
  - `disabled` if there are no completed generations on this file.
  - `ready` otherwise.
- [ ] **Step C2.3** — Wire `onStartCrafting`:

```ts
const handleStartCrafting = useCallback(() => {
  const latest = generations[0]; // newest first
  if (!latest) return;
  send({
    canvasMode: "craft",
    mode: "image",
    attachedGenerationId: latest.id,
    prompt: "", // service substitutes the canned default
  });
}, [generations, send]);
```

- [ ] **Step C2.4** — On `generation_done`, if the completed generation's `mode === 'craft'`, set `canvasMode("sketch")` so the user lands back in normal iteration. Add a small effect:

```ts
useEffect(() => {
  if (latestCompletedGeneration?.mode === "craft" && canvasMode === "craft") {
    setCanvasMode("sketch");
  }
}, [latestCompletedGeneration?.id]);
```

- [ ] **Step C2.5** — Component test: render `KvGeneratorLayout` with mocked stream, switch to Craft, assert overlay renders. Mock a `generation_done` with `mode='craft'`, assert the overlay disappears and `canvasMode` reverted to `sketch`.

### Task C3: Hide canvas tools in Craft

- [ ] **Step C3.1** — In `KvCanvasBottomNav.tsx`, accept `canvasMode?: CanvasMode`. When `canvasMode === 'craft'`, conditionally render the cursor/frame/text/image tool group as `null`. Chat toggle pill stays.
- [ ] **Step C3.2** — Pass `canvasMode` from `KvGeneratorLayout` to `KvCanvasBottomNav`.
- [ ] **Step C3.3** — Existing tests in `KvCanvasBottomNav.test.tsx` get a new case: with `canvasMode='craft'`, the four tool buttons are not in the document.

### Task C4: Mode badges on version cards

- [ ] **Step C4.1** — In `web/src/types/studio.ts` (or wherever `KvGeneration` is typed), add `mode: 'sketch' | 'craft' | 'resize'`. Default `'sketch'` if backend sends nothing (defensive — should never happen post-migration).
- [ ] **Step C4.2** — In `KvVersionCard.tsx`, render a small chip beneath the version number:
  - `Sketch` — neutral pill, `PencilRuler` icon (lucide).
  - `Craft` — accent pill (use existing accent token), `MagicWand` icon (lucide).
  - For `Craft`, add a tooltip `Polished from v{parent.version_number}` when `parent_generation_id` resolves to a known version.
- [ ] **Step C4.3** — Same chip in `KvVersionHistoryPanel.tsx` rows.
- [ ] **Step C4.4** — Add tests in `KvVersionCard.test.tsx`: chip text matches mode; tooltip appears for Craft when parent is known.

### Task C5: `useKvStream` accepts `canvasMode`

- [ ] **Step C5.1** — In the stream hook (`web/src/lib/studio/kv/useKvStream.ts` or wherever `send()` is defined), extend the `send()` signature:

```ts
type SendOpts = {
  mode?: "chat" | "image";
  canvasMode?: "sketch" | "craft" | "resize";
  attachedGenerationId?: string;
  prompt?: string;
  // ...existing fields
};
```

- [ ] **Step C5.2** — Add client-side guard: if `canvasMode === 'craft'`, require `attachedGenerationId`, throw a console error otherwise (defensive — caller bug).
- [ ] **Step C5.3** — Forward `canvas_mode` and `attached_generation_id` in the POST body.

### Task C6: Block mode-switch mid-stream

- [ ] **Step C6.1** — `onCanvasModeChange` handler in `KvGeneratorLayout.tsx` checks if a stream is in flight (`pendingGeneration != null`). If yes, show toast `Wait for the current generation to finish` and ignore the change.
- [ ] **Step C6.2** — Component test asserting the toast.

### Task C7: Wireframe pages — none needed

The canvas chassis is already implemented. Craft mode reuses every existing surface. Skip wireframe creation.

---

## Section D — Verification

### Task D1: Local end-to-end smoke test

- [ ] **Step D1.1** — Start all services via `./run-all.sh`. Health-check each per CLAUDE.md.
- [ ] **Step D1.2** — Open a project, run KV Gen, generate a sketch.
- [ ] **Step D1.3** — Switch canvas mode to Craft. Observe dim + Start Crafting pill.
- [ ] **Step D1.4** — Click Start Crafting. Observe placeholder/polishing state. Confirm SSE events stream `generating(prompt_expanded) → generating(image_rendering) → generation_done`.
- [ ] **Step D1.5** — Confirm new version appears with `Craft` badge, version_number = previous + 1, canvasMode reverted to sketch.
- [ ] **Step D1.6** — Side-by-side compare parent vs polished — composition, subjects, text wording preserved.
- [ ] **Step D1.7** — Verify `kv_generations` row in DB has `mode='craft'` and `parent_generation_id` set.
- [ ] **Step D1.8** — Verify `studio_activities` rows: `kv_craft_started` and `kv_craft_completed`.

### Task D2: Failure path

- [ ] **Step D2.1** — Force AI service to fail (kill it mid-stream). Confirm `generation_failed` SSE; placeholder shows Retry. Click Retry; succeeds on second attempt.
- [ ] **Step D2.2** — Confirm `kv_craft_failed` activity row.

### Task D3: Edge cases

- [ ] **Step D3.1** — Open a fresh KV file with no generations; switch to Craft → disabled state.
- [ ] **Step D3.2** — Mid-Sketch generation, try to switch to Craft → toast appears, mode stays Sketch.
- [ ] **Step D3.3** — Polish a Craft version (chain polish) — works; `parent_generation_id` chain is correct.

### Task D4: Acceptance criteria walkthrough

- [ ] **Step D4.1** — Walk through all 12 acceptance criteria in the spec, confirming each.

---

## Risks & mitigations

- **Polish drift.** Mitigated by explicit guidance + image-to-image conditioning + history trimming. If still drifts in QA, follow up with a tighter prompt (add `"DO NOT regenerate from scratch — only refine."`) or move to a real image-edit endpoint instead of full re-render.
- **`canvas_mode` field name collision** with existing `mode` field. Kept distinct on purpose; reviewers should confirm the names read clearly. If preferred, rename to `operation` or `pipeline_mode` — surface the alternative in PR review.
- **Migration on a non-empty `kv_generations` table.** Default value handles it. Reversible.
- **Cost of an extra image-gen call per polish.** Same as a regular Sketch — no new per-call cost. Track usage post-launch.
