# KV Agentic Canvas P1 — Round B (web) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The KV chat shows a plan card for the paid structure tools (variants, sizes) and sends Go/Cancel through the stream. Agent placeholder boards render on the canvas while their renders run. The run card lists each board or size the run produces, with its state, credits and an honest undo.

**Architecture:** Wire shapes and their mappers live in `services/kv/api.ts`, next to the run view; the domain types live in `types/kv/`. Pure helpers in `lib/studio/kv/` hold every decision a test can pin: the Go payload, estimates, size dims, the progress reducer and placeholder derivation. Components stay thin. `KvPlanCard` registers in the S17 registry behind the `structure` gate. `useKvStream` owns the new frames and the per-run progress map. `KvGeneratorLayout` merges agent placeholders into the existing `pendingBoards` render path (`BoardChrome`), so the canvas gains no new renderer.

**Tech Stack:** Next.js 16 / React 19, TanStack Query v5, bun test + RTL, posthog-js.

**Spec:** `docs/superpowers/plans/2026-10-22-kv-agentic-canvas-p1-structure-contracts.md` (S12, S15, S17, R1–R12 and the R9 amendment), `web/.worktrees/kv-agentic-canvas-p1/docs/prd/kv-agentic-canvas-p1.md` (TASK-4..11), and the wireframe `src/wireframes/kv-agent-structure-cards/`. Wire choices the contract leaves open are recorded in the shared notes folder, file `web-round-b-wire.md`.

## Global Constraints

- Worktree `web/.worktrees/kv-agentic-canvas-p1`, branch `feature/daffa/vc-kv-agentic-canvas-p1`. No push, no rebase, no new branch, never `git stash`.
- Flag off (`kv-agentic-canvas-structure`, or its parent `kv-agentic-canvas`) ⇒ no plan card, no placeholders, no progress state used; P0 and Round A behaviour stay byte-identical.
- Test with `bun test <file paths>` only. Use `within(document.body)` and no partial `mock.module`; inject APIs through props. Keep every test file under 45 KB.
- No new dark hex colours. Reuse the wireframe's token classes (`text-text-inverse*`, `bg-white/[0.0x]`, `var(--warning-400)`). The purple accent `#7b5cff` already exists in the wireframe and its accent classes; reuse `bg-[#7b5cff]/[0.22]` exactly as the wireframe does.
- Copy is verbatim from the wireframe:
  - PLAN_STATUS_COPY: `Waiting for your Go` / `Running` / `Cancelled` / `Replaced by a newer plan` / `Expired` / `Done`.
  - PLAN_CLOSED_NOTE: `superseded` "You asked for something new, so this plan was replaced."; `expired` "Plans expire after 15 minutes. Ask again for a fresh one."; `cancelled` "Nothing was generated or charged."
  - Undo confirm: "Undo removes the boards this run added, unless you edited them since. Credits already spent are not refunded."
  - Row states: `Queued` / `Rendering…` / `Ready` / `Couldn't render`.
  - Placeholder: `Generating…`, failed `Couldn't render · removing`.
- Limits: `MAX_VARIANTS = 4`, direction `maxLength 500`, at most 3 suggestions per variant, plan poll every 5 000 ms while `proposed`.
- Every commit: `feat(web): KV agentic canvas P1 Round B — …` + `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. The tree must compile at every save, because the user's HMR browser runs from this worktree.
- tsc: compare against the base (964 errors at bd2049f02); no new errors in touched files.

## Review Focus

1. **A plan that expires while the card is open.** Go must not send once `expires_at` has passed, even before the next poll. The card shows Expired and fires `plan_expired` once. → Task 3 test `expired_by_clock_blocks_go`.
2. **Go fails** (stream error, or the `insufficient_credits` error frame, after which the plan stays `proposed`). The card unlocks so Go can be pressed again. → Task 2 test (`clearCardAnswer` covers plan cards), Task 3 test `go_unlocks_when_send_resolves_and_plan_still_proposed`.
3. **A run whose items never settle.** Polling must stop: the 3 s poll caps at 300 reads, and a 403/404 stops it at once. → Task 4 test `item_poll_caps`.
4. **A placeholder that was hidden** (its id is in `removed`) or that already has a generation. It must never draw a ghost. → Task 5 tests.
5. **A remount or a rehydrated plan card.** `plan_shown` fires once per plan per session, and `variant_done`/`variant_failed` fire only for live runs, once per item. → Task 3 and Task 4 tests.

---

### Task 1: Plan + run-view types, API client, chip labels (TASK-4, TASK-11)

**Files:**
- Create: `src/types/kv/agentPlan.ts`
- Modify: `src/types/kv/agentRun.ts` (items, summaryCredits, boards, undo creditsSpent)
- Modify: `src/services/kv/api.ts` (plan view client + run view mapping)
- Modify: `src/lib/studio/kv/kvAgentToolResult.ts` (board and plan tool chips)
- Test: `src/services/kv/agentPlan.api.test.ts`, `src/services/kv/agentRun.api.test.ts` (extend), `src/lib/studio/kv/kvAgentToolResult.test.ts` (extend)

**Interfaces — Produces:**
```ts
// types/kv/agentPlan.ts
export type KvAgentPlanStatus = "proposed"|"accepted"|"cancelled"|"superseded"|"expired"|"executed";
export type KvAgentPlanCapability = "variant_boards"|"add_sizes";
export interface KvAgentPlanEstimate { creditsMin: number; creditsMax: number; seconds: number }
export interface KvDirectionSuggestion { label: string; direction: string }
export interface KvVariantStepParams { boardId: string; direction: string; suggestions: KvDirectionSuggestion[] }
export type KvPlanSize = { preset: string } | { width: number; height: number };
export interface KvSizeStepParams { boardId: string; size: KvPlanSize; method: "layers"|"ai"; blockedReason: string|null }
export type KvAgentPlanStep =
  | { id: string; capability: "variant_boards"; params: KvVariantStepParams; estimate: KvAgentPlanEstimate; done: boolean }
  | { id: string; capability: "add_sizes"; params: KvSizeStepParams; estimate: KvAgentPlanEstimate; done: boolean };
export interface KvAgentPlan { id; status; goal: string; capability; sourceBoard: {boardId; name: string|null}|null;
  steps: KvAgentPlanStep[]; options: { copyLayers: boolean; extraDirections: KvDirectionSuggestion[] };
  estimate; acceptedSteps: string[]|null; stepOverrides: Record<string,{direction:string}>|null;
  runId: string|null; expiresAt: string; createdAt: string; balance: number|null }
export interface KvPlanAction { planId: string; acceptedSteps?: string[];
  stepOverrides?: Record<string,{direction:string}>; options?: { copyLayers: boolean } }
export const kvAgentPlanQueryKey = (fileId: string, planId: string) => ["kv-agent-plan", fileId, planId] as const;

// types/kv/agentRun.ts additions
export type KvAgentItemState = "queued"|"generating"|"done"|"failed";
export interface KvAgentRunItem { planStepId: string; kind: "board"|"size"; boardId: string|null; sizeId: string|null;
  name: string|null; state: KvAgentItemState; generationId: string|null; imageUrl: string|null;
  credits: number|null; sourceBoardId: string|null }
// KvAgentRun gains: items: KvAgentRunItem[]; summaryCredits: number|null;
//   boards: Array<{op: string|null; boardId: string|null; name: string|null; sourceBoardId: string|null}>
// KvAgentRunUndoResult/Outcome gain creditsSpent: number|null

// services/kv/api.ts
export function toKvAgentPlan(w: WireKvAgentPlan): KvAgentPlan;
export async function getKvAgentPlan(fileId: string, planId: string): Promise<KvAgentPlan>;
```

- [ ] **Step 1: Write the failing tests.**
  - `agentPlan.api.test.ts`:
    - `toKvAgentPlan maps a variant plan`: R3 sample → camelCase; `options.extraDirections` is kept; at most 3 suggestions per step.
    - `maps a size plan with a preset string and a custom size`: `"Instagram Story"` → `{preset}`, and `{width,height}` stays as it is; `blocked_reason` → `blockedReason`.
    - `missing options default copyLayers true, extraDirections []`.
    - `balance absent → null`.
    - `unwraps {data}` and accepts a bare body.
  - `agentRun.api.test.ts`:
    - `maps items + summary.credits`.
    - `run view without items → items [] and summaryCredits null`.
    - An unknown item state maps to `queued`.
    - `boards[]` is mapped.
    - `undo maps credits_spent`.
  - `kvAgentToolResult.test.ts`:
    - `Duplicating Boards` / `duplicate_kv_board` → kind `board`, detail "Added 2 boards" (from `boards`/`applied`) or "Nothing applied · 1 skipped".
    - `Planning Variants`, `propose_kv_variants`, `Planning Sizes` → `plan`, detail "Plan ready · 3 steps".
    - `Running Plan` / `run_kv_plan_step` → `plan_run`, detail "Started 3 · 1 skipped".
- [ ] **Step 2: Run them; they fail.** `bun test src/services/kv/agentPlan.api.test.ts src/services/kv/agentRun.api.test.ts src/lib/studio/kv/kvAgentToolResult.test.ts`
- [ ] **Step 3: Implement.**
  - The R3 wire type and `toKvAgentPlan` go in api.ts; `getKvAgentPlan` uses `unwrapAgentBody`.
  - Run-view mapping: `items` reads `source_board_id` when present; any state other than the four maps to `queued`.
  - Chip kinds: add `board` (Duplicating Boards, Renaming Board, Arranging Boards, Hiding Boards plus their raw names), `plan` and `plan_run`.
- [ ] **Step 4: Run them; they pass.**
- [ ] **Step 5: Commit** `… — plan/run view types, API client, chip labels`.

### Task 2: Stream — plan card frame, hydrate, Go/Cancel send, item progress (R4, R5, R9; TASK-4, TASK-7)

**Files:**
- Create: `src/lib/studio/kv/kvAgentItemProgress.ts`
- Modify: `src/hooks/useKvStream.ts`
- Test: `src/lib/studio/kv/kvAgentItemProgress.test.ts`, `src/hooks/useKvStream.planCard.test.ts`

**Interfaces — Produces:**
```ts
// kvAgentItemProgress.ts
export interface KvAgentItemProgress { runId: string; itemId: string; kind: "board"|"size"; state: KvAgentItemState; boardId: string|null }
export type KvAgentItemProgressMap = Record<string /*runId*/, Record<string /*itemId*/, KvAgentItemProgress>>;
export function parseAgentItemProgress(frame: unknown): KvAgentItemProgress | null; // event==="agent_item_progress"; data.item_kind ?? data.kind; data.agent_run_id ?? data.run_id
export function reduceAgentItemProgress(map: KvAgentItemProgressMap, p: KvAgentItemProgress): KvAgentItemProgressMap; // later state never goes back (queued<generating<done|failed); same ref when unchanged
// useKvStream
// ChatMessageMeta.planCard?: { planId: string; cardId: string; live: boolean; answeredOptionId?: "go"|"cancel" }
// KvQuestionCardPurpose unchanged; KvCardAnswer.purpose: KvQuestionCardPurpose | "plan"
// KvSendOptions.planAction?: KvPlanAction  → body `plan_action` {plan_id, accepted_steps, step_overrides, options:{copy_layers}} (keys omitted when undefined)
// hook returns agentItemProgress: KvAgentItemProgressMap
// initialMessages[].kv_plan_card?: {plan_id, card_id} | null
```

- [ ] **Step 1: Write the failing tests.**
  - The reducer:
    - parses the amended shape (`item_kind`, `agent_run_id`) and also the legacy `kind`/`run_id`;
    - rejects other events, a missing item_id and an unknown state;
    - never moves `done` back to `queued`;
    - returns the same reference for a no-op.
  - Hook (`useKvStream.planCard.test.ts`, using the existing `useKvStream.cardAnswer.test.ts` harness with a `sseRequest` stub):
    - a `kv_plan_card` frame pushes an assistant message `{planCard:{planId, cardId, live:true}}`;
    - hydrate with `kv_plan_card` gives `live:false`, and so does `kind:"plan_card"` with a payload;
    - `send("Go",{cardAnswer:{cardId,optionIds:["go"],purpose:"plan"}, planAction:{…}})` posts `card_answer.purpose:"plan"` and the snake_case `plan_action`;
    - the plan message gets `answeredOptionId:"go"`, which is cleared when `onError` fires;
    - a `tool_progress` frame updates `agentItemProgress`.
- [ ] **Step 2: Run them; they fail.**
- [ ] **Step 3: Implement.**
  - Add the frame case `kv_plan_card`: seal the streaming bubble, then push the message.
  - Add the case `tool_progress`, calling `parseAgentItemProgress` and then `setAgentItemProgress`.
  - Extend `markCardAnswered`/`clearCardAnswer` to cover `planCard` matched by `cardId`.
  - Add `plan_action` to the body.
- [ ] **Step 4: Run them; they pass.** Also run the existing `src/hooks/useKvStream*.test.ts` files (each one named).
- [ ] **Step 5: Commit** `… — plan card frame, Go/Cancel send, item progress`.

### Task 3: KvPlanCard + registry + host + plan events (TASK-5, TASK-6, TASK-10 part)

**Files:**
- Create: `src/lib/studio/kv/kvAgentPlan.ts` (pure)
- Create: `src/components/studio/kv-generator/KvPlanCard.tsx`
- Modify: `src/components/studio/kv-generator/cards/kvCards.ts` (`plan_card` gated on `structure`)
- Modify: `src/components/studio/kv-generator/KvChat.tsx` (host)
- Modify: `src/lib/analytics/kv-agent-events.ts`
- Test: `src/lib/studio/kv/kvAgentPlan.test.ts`, `src/components/studio/kv-generator/KvPlanCard.test.tsx`, `src/components/studio/kv-generator/cards/kvCards.test.ts` (extend)

**Interfaces — Produces:**
```ts
// kvAgentPlan.ts
export const MAX_VARIANTS = 4;
export interface KvVariantRowDraft { id: string /* step id or new_<n> */; original: string; direction: string; kept: boolean; suggestions: KvDirectionSuggestion[]; added: boolean }
export function initialVariantRows(plan: KvAgentPlan): KvVariantRowDraft[];
export function addVariantRow(rows: KvVariantRowDraft[], extra: KvDirectionSuggestion[]): KvVariantRowDraft[] | null; // null at MAX or no unused extra; id new_<count of added rows + 1>; suggestions = the other extras
export function variantPlanAction(planId: string, rows: KvVariantRowDraft[], copyLayers: boolean): KvPlanAction; // accepted = kept rows with a non-blank direction; overrides = edited kept steps + every kept added row (trimmed)
export function sizePlanAction(planId: string, keptStepIds: string[]): KvPlanAction; // stepOverrides {}
export function variantEstimate(plan: KvAgentPlan, acceptedCount: number): KvAgentPlanEstimate; // per-step = first variant step's estimate; seconds = max
export function sizeEstimate(steps: KvAgentPlanStep[]): KvAgentPlanEstimate; // sum credits, max seconds
export function describePlanEstimate(e: KvAgentPlanEstimate): string; // wireframe describeEstimate, verbatim
export function planSizeDims(size: KvPlanSize): { label: string; width: number|null; height: number|null }; // PLATFORMS by id or label (case-insensitive, label prefix)
export function effectivePlanStatus(plan: KvAgentPlan, now: number): KvAgentPlanStatus; // proposed past expiresAt → expired
export const PLAN_STATUS_COPY, PLAN_CLOSED_NOTE; // wireframe copy

// KvPlanCard props
export interface KvAgentPlanApi { getPlan(fileId: string, planId: string): Promise<KvAgentPlan> }
export function KvPlanCard(props: { fileId: string; planId: string; cardId: string; live: boolean;
  answeredOptionId?: "go"|"cancel"; resolveBoardName?: (boardId: string) => string|null;
  onSubmit: (choice: "go"|"cancel", action: KvPlanAction) => Promise<void> | void; api?: KvAgentPlanApi }): JSX.Element | null;

// kv-agent-events.ts
trackKvAgentPlanShown({file_id, plan_id, capability, step_count})
trackKvAgentPlanConfirmed({file_id, plan_id, capability, accepted_count, edited_count, added_count, suggestion_count, copy_layers: boolean|null, credits_min, credits_max})
trackKvAgentPlanCancelled({file_id, plan_id, capability})
trackKvAgentPlanExpired({file_id, plan_id, capability})
```

- [ ] **Step 1: Write the failing pure tests** (`kvAgentPlan.test.ts`):
  - `variantPlanAction` sends edited directions only for changed steps.
  - An unticked step is left out.
  - An added row is `new_1`, appears in `accepted_steps` and in `step_overrides`.
  - A blank direction is left out.
  - `addVariantRow` stops at 4 and skips an extra already in use.
  - `variantEstimate(plan, 3)` gives `3×min`, `3×max` and the max seconds.
  - `effectivePlanStatus` reads expired past `expiresAt`.
  - `planSizeDims("Instagram Story")` gives 1080×1920.
  - `describePlanEstimate({6,10,70})` gives `≈ 6–10 credits · about 1 min`.
- [ ] **Step 2: Write the failing component tests** (`KvPlanCard.test.tsx`, api injected, posthog spied):
  - A proposed variant plan renders its rows, the chips, Copy layers and the estimate with the balance.
  - Clicking a chip prefills its direction; clicking the active chip restores the original.
  - Go calls `onSubmit("go", action)` with overrides and `copy_layers`.
  - Add variant appends from `extra_directions` up to 4; at 4 the button reads "Max 4 variants".
  - A size plan shows the blocked row unticked and disabled with its reason, and the method badges "From layers" / "AI resize".
  - Terminal statuses show their status copy and closed note, with no Go button.
  - `expired_by_clock_blocks_go`.
  - `go_unlocks_when_send_resolves_and_plan_still_proposed`.
  - `credits_max over balance disables Go with "Not enough credits"`.
  - `plan_shown fires once across remounts`.
  - `plan_cancelled on Cancel`.
  - `plan_expired fires once when a proposed plan reads expired`.
  - It polls every 5 s while proposed: `refetchInterval` is checked through an exported `planRefetchInterval`.
  - Registry: `KV_CARDS.resolve("plan_card", {agentCanvas:true, structure:false})` is null.
- [ ] **Step 3: Run them; they fail.**
- [ ] **Step 4: Implement.**
  - Port the wireframe's `VariantPlanCard`/`SizePlanCard` markup into one `KvPlanCard` that switches on `plan.capability` and reads its data from `useQuery(kvAgentPlanQueryKey)`.
  - `refetchInterval` is `planRefetchInterval`: 5000 while the effective status is proposed, false otherwise or on 403/404.
  - Status pill and footer follow the wireframe.
  - Local `submitting` state comes from `answeredOptionId` or Go/Cancel. After `onSubmit` resolves, invalidate the plan query; `submitting` clears when the plan is still proposed.
  - Host in KvChat:
    - `KV_CARDS.resolve("plan_card", cardGates)`.
    - `onSubmit` calls `stream.send(choice === "go" ? "Go" : "Cancel", {cardAnswer:{cardId, optionIds:[choice], purpose:"plan"}, planAction, mode:"chat", canvasMode})`.
    - `resolveBoardName` comes from generations (`V{version_number}`).
- [ ] **Step 5: Run them; they pass.** Then run the KvChat.* and cards tests.
- [ ] **Step 6: Commit** `… — KvPlanCard (variants + sizes) behind the structure flag`.

### Task 4: Run card enrichment (TASK-8, TASK-10 rest; R8, R11)

**Files:**
- Modify: `src/components/studio/kv-generator/KvAgentRunCard.tsx`
- Modify: `src/lib/studio/kv/kvAgentRunCopy.ts`
- Modify: `src/lib/analytics/kv-agent-events.ts` (`trackKvAgentVariantDone/Failed({file_id, run_id, plan_step_id, credits})`)
- Test: `src/components/studio/kv-generator/KvAgentRunCard.items.test.tsx` (new file, so the existing 16 KB one stays small), `src/lib/studio/kv/kvAgentRunCopy.test.ts` (extend)

**Interfaces — Produces:**
```ts
export function agentRunRefetchInterval(state): number|false; // unchanged for runs without open items; any queued/generating item → 3000 until reads < 300
export function describeKvAgentItemsTitle(run: KvAgentRun, undone: boolean): string;   // "Generating 3 variants" | "2 variants added" | "Adding 4 sizes" | "4 sizes added"
export function describeKvAgentItemsSubtitle(run: KvAgentRun): string | null; // names, "· 1 failed", "· N credits used" once not running
export const KV_AGENT_ITEMS_UNDO_CONFIRM_COPY; // wireframe UNDO_CONFIRM_COPY verbatim
// KvAgentRunCard gains optional prop: progress?: Record<string, KvAgentItemProgress> (live states for items the run view has not listed yet)
```

- [ ] **Step 1: Write the failing tests.**
  - A run with items renders one row per item with `Queued` / `Rendering…` / `Ready`.
  - A done row shows its thumbnail and focuses `{kind:"board", id: generationId ?? boardId}`; a size row focuses `{kind:"size", id:sizeId}`.
  - A failed item shows "{name} couldn't be rendered. Its board was removed and it wasn't charged."
  - Credits show only when the run is not running.
  - The undo confirm uses the credits copy when the run has items and the P0 copy otherwise.
  - The undo outcome shows "· N credits not refunded" when `creditsSpent > 0`.
  - `item_poll_caps`.
  - variant_done/failed fire once per item for live runs only.
  - Undo is enabled for a completed run with only items, or with only `boards` (a Round A duplicate with no layers).
- [ ] **Step 2: Run them; they fail.**
- [ ] **Step 3: Implement.** Add an items branch in the card: when `run.items.length > 0`, render item rows in the wireframe's `StructureRunCard` style instead of the applied tree. Layer applied rows still render under it when present.
- [ ] **Step 4: Run them, plus `KvAgentRunCard.test.tsx` and `kvAgentRunCopy.test.ts`; they pass.**
- [ ] **Step 5: Commit** `… — run card board/size rows, credits, undo refund copy`.

### Task 5: Agent placeholder boards on the canvas (TASK-9, R10)

**Files:**
- Create: `src/lib/studio/kv/kvAgentPlaceholders.ts`
- Create: `src/hooks/useKvAgentPlaceholderBoards.ts`
- Modify: `src/components/studio/kv-generator/boardLayout.ts` (`KvPendingBoard` gains `key?: string; agent?: boolean; failed?: boolean`)
- Modify: `src/components/studio/kv-generator/fabric/BoardChrome.tsx` (failed copy, no Cancel on agent placeholders, `key`)
- Modify: `src/components/studio/kv-generator/KvGeneratorLayout.tsx` (mount the hook, merge into the canvas `pendingBoards` prop only)
- Test: `src/lib/studio/kv/kvAgentPlaceholders.test.ts`, `src/hooks/useKvAgentPlaceholderBoards.test.tsx`

**Interfaces — Produces:**
```ts
export interface KvAgentPlaceholderItem { boardId: string; state: KvAgentItemState; name: string|null; sourceBoardId: string|null }
export function agentPlaceholderBoards(args: { docCanvasState: KvCanvasState|null|undefined; generations: Pick<KvGeneration,"id">[];
  items: KvAgentPlaceholderItem[]; fallbackBaseId: string|null; fallbackAspect: number }): KvPendingBoard[];
  // doc artboard whose key is an open/failed item boardId, is not a generation, and is not in removed_generation_ids → pending board at its center, name doc ?? item, baseId source ?? fallbackBaseId, failed = state==="failed", agent = true, key = "agent:"+id
export function placeholderItemsFrom(runs: KvAgentRun[], progress: KvAgentItemProgressMap): KvAgentPlaceholderItem[]; // board items not done; run view wins over progress for the same plan step
export function useKvAgentPlaceholderBoards(args: { fileId?: string; enabled: boolean; runIds: string[] /* latest 3 */; progress: KvAgentItemProgressMap;
  docCanvasState; generations; fallbackBaseId: string|null; fallbackAspect: number; api?: { getRun } }): KvPendingBoard[];
```

- [ ] **Step 1: Write the failing pure tests.**
  - An open item on a doc board with no generation becomes a placeholder at the board's center with its doc name.
  - A board in `removed` gives none.
  - A board whose id is a generation gives none.
  - A failed item gives `failed:true`.
  - A done item gives none.
  - An item whose board is not in the doc gives none.
  - A progress-only item (no run view yet) still gives a placeholder.
  - When both sources name the same step, the run view state wins.
- [ ] **Step 2: Write the failing hook test** (controlled Y-free harness, api injected):
  - With `enabled:false`, no fetch and `[]`.
  - The run ids are fetched under `kvAgentRunQueryKey`, so the cache is shared with the run card.
- [ ] **Step 3: Run them; they fail.**
- [ ] **Step 4: Implement.**
  - The hook reads `useQueries` with `agentRunRefetchInterval` and calls `agentPlaceholderBoards`.
  - In the layout:
    - `enabled = kvAgenticStructureEnabled && canvasMode === "craft"`;
    - `runIds` are the last 3 distinct `stream.messages[].metadata.agentRun.runId`;
    - the fallback base and aspect come from the active board;
    - the canvas gets `pendingBoards={agentPlaceholders.length ? [...pendingBoards, ...agentPlaceholders] : pendingBoards}`.
  - BoardChrome:
    - use `pb.key ?? center` as the React key;
    - show the failed text with a Warning icon in `text-warning-400`;
    - hide Cancel when `pb.agent`.
- [ ] **Step 5: Run the new tests and the existing `useRefetchKvFileOnUnknownBoards`, `boardLayout` and `BoardChrome` tests (if any); they pass. Run tsc against the base.**
- [ ] **Step 6: Commit** `… — agent placeholder boards survive reloads`.

### Task 6: Track, taxonomy note, self-review

- [ ] Tick TASK-4..11 in `docs/tracks/kv-agentic-canvas-p1.track.md`. Append a session log entry with the commits, test counts, tsc vs base and the contract deviations. Commit `docs(web): …`.
- [ ] Code review (superpowers:requesting-code-review) over `bd2049f02..HEAD`; fix Critical/Important.
