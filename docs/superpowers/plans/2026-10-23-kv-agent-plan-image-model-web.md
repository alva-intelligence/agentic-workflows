# KV agent plan image model — web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pin with tests that the web sends the composer's picked `image_model` on the plan-proposal turn and on Go, and add `image_model` to the `kv_agent.plan_confirmed` PostHog event.

**Architecture:** The wire format does not change. `useKvStream.send()` already puts `image_model: selectedImageModel || undefined` (from `useChatStore`) at the top level of every KV stream body. `KvPlanCard` reads `useChatStore((s) => s.selectedImageModel)` at Go time for analytics.

**Tech Stack:** Next.js 16, React 19, TypeScript, Zustand, `bun test`.

**Spec:** `docs/superpowers/specs/2026-10-23-kv-agent-plan-image-model-design.md` (§4.7)

**Branch:** `feature/daffa/vc-kv-agent-plan-image-model` in `web/`, from latest `develop`. A new worktree needs its own `bun install` and a copied `.env.local`.

## Global Constraints

- No change to the request body shape. Do not add `plan_action.options.image_model`.
- `kv_agent.plan_confirmed.image_model: string | null`:
  - `concept_boards` / `variant_boards`: the picker value at Go time, `null` when it is empty.
  - `add_sizes`: always `null`.
- Tests run with `bun test <file>` (never vitest, never a whole directory). Use `within(document.body)` for RTL queries. Do not add `mock.module` for modules other suites import; follow each test file's existing mock header exactly. Keep each test file under ~51 KB.
- There is no type gate. Compare `tsc` errors on touched files against the `develop` baseline, and introduce none.

## Review Focus

1. **The picker is empty on first load:** the body has no `image_model` key, never `""` (Task 1 test).
2. **The user changes the picker between proposal and Go:** the Go body carries the *new* value, because it is read at send time (Task 1 test).
3. **`add_sizes` Go:** `image_model: null` in analytics, even when the picker is set (Task 2 test).

---

### Task 1: Pin the picked model on proposal and Go turns

**Files:**
- Test: `src/hooks/useKvStream.planCard.test.ts`

**Interfaces:**
- Consumes: `useChatStore.setState({ selectedImageModel })`; the `GO` fixture and `lastCall()` already in the file.

- [ ] **Step 1: Write the tests** (they should pass at once; they pin existing behaviour the api now depends on, so watch them fail by temporarily changing `image_model: selectedImageModel || undefined` to `undefined`, then revert):
  - `it("sends the picked image_model on the proposal turn")`: `selectedImageModel: "gpt-image-2"`, `send("3 ide KV berbeda", { mode: "chat", canvasMode: "craft" })` → `JSON.parse(lastCall().body!).image_model === "gpt-image-2"`.
  - `it("sends the picker's current image_model on Go")`: set `"gpt-image-2"`, then set `"seedream-5-lite"`, then `send("Go", GO)` → the body has `image_model === "seedream-5-lite"`, and `plan_action` has no `image_model` key, including under `options`.
  - `it("omits image_model when the picker is empty")`: `selectedImageModel: ""` → `"image_model" in body` is false.
  - Restore `selectedImageModel` in `afterEach`.

- [ ] **Step 2: Run** — `bun test src/hooks/useKvStream.planCard.test.ts` → PASS. Then do the mutation check described in Step 1 → FAIL. Revert the mutation.

- [ ] **Step 3: Commit** — `test(web): pin image_model on KV plan proposal and Go turns`

---

### Task 2: `image_model` on `kv_agent.plan_confirmed`

**Files:**
- Modify: `src/lib/analytics/kv-agent-events.ts` (`trackKvAgentPlanConfirmed` props gain `image_model: string | null`; extend the docblock)
- Modify: `src/components/studio/kv-generator/KvPlanCard.tsx` (the three `trackKvAgentPlanConfirmed` calls, ~L538/797/920)
- Test: `src/components/studio/kv-generator/KvPlanCard.test.tsx` (variant + sizes), `KvPlanCard.concept.test.tsx` (concept)

**Interfaces:**
- Produces: `trackKvAgentPlanConfirmed({ ..., image_model: string | null })`

- [ ] **Step 1: Write the failing tests** (use each file's existing `posthog.capture` spy and `events("kv_agent.plan_confirmed")` helper):
  - Concept: with `useChatStore.setState({ selectedImageModel: "gpt-image-2" })`, Go → `toMatchObject({ capability: "concept_boards", image_model: "gpt-image-2" })`.
  - Variant: the same with `"seedream-5-lite"`. With an empty picker → `image_model: null`.
  - Sizes: picker `"gpt-image-2"`, Go → `image_model: null`.

- [ ] **Step 2: Run, expect FAIL** — `bun test src/components/studio/kv-generator/KvPlanCard.test.tsx`, then the concept file separately

- [ ] **Step 3: Implement.** Read `selectedImageModel` from `useChatStore` in the card. Concept/variant calls pass `selectedImageModel || null`, and the sizes call passes `null`.

- [ ] **Step 4: Run, expect PASS** — both files, each on its own

- [ ] **Step 5: Run the frndos-analytics-events check.** Invoke the `frndos-analytics-events` workflow/skill if it is available in the session. Otherwise update the taxonomy entry for `kv_agent.plan_confirmed` wherever the repo documents it (`docs/analytics/` or `docs/prd/kv-agentic-canvas-p1-1.md`).

- [ ] **Step 6: Commit** — `feat(web): image_model on kv_agent.plan_confirmed`

---

### Task 3: Docs

**Files:**
- Modify: `docs/prd/kv-agentic-canvas-p1-1.md`: a one-paragraph amendment: plans use the picked model (spec link); the wire is unchanged; the new analytics prop.
- Modify: `docs/tracks/kv-agentic-canvas-p1-1.track.md`: a session-log entry.

- [ ] **Step 1: Write the doc edits**
- [ ] **Step 2: Commit** — `docs(web): plan image model amendment`
