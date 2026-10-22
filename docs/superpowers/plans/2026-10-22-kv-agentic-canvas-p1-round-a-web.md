# KV Agentic Canvas P1 — Round A (web) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship web Round A of kv-agentic-canvas-p1: the board-placement fixture export the api's PHP ports are tested against (S18), the KV card registry (S17), and the `kv-agentic-canvas-structure` flag (S3/NFR-1).

**Architecture:** Fixture cases + expected values are built by a pure module in `src/` (so `bun test` can drift-check them) and written to `web/fixtures/board-placement/*.json` by a thin script. The card registry is a small typed `card_kind → component` map with per-entry flag gates; `KvChat` resolves its run card and question card through it instead of naming the components. The structure flag is a child of the P0 `kv-agentic-canvas` flag and only feeds the registry's gates in Round A (no card uses it until Round B's `plan_card`).

**Tech Stack:** TypeScript, React 19, bun test + RTL, PostHog (`useExperimentalFeatureEnabled`).

**Spec:** `web/.worktrees/kv-agentic-canvas-p1/docs/prd/kv-agentic-canvas-p1.md` (TASK-1..3), contracts `docs/superpowers/plans/2026-10-22-kv-agentic-canvas-p1-structure-contracts.md` (S3, S6, S17, S18). P0 precedent: `docs/superpowers/plans/2026-09-29-kv-agentic-canvas-p1-web.md`.

All paths below are relative to `web/.worktrees/kv-agentic-canvas-p1/` unless stated.

## Global Constraints

- Branch `feature/daffa/vc-kv-agentic-canvas-p1`, worktree `web/.worktrees/kv-agentic-canvas-p1`. Commit there only; no push, no PR, never `git stash`, never touch `.workflow-state.json`.
- Contract names are frozen: `kv-agentic-canvas-structure`, `KvCardRegistry`, `run_card`, `question_card`, `plan_card`, `scripts/exportBoardPlacementFixtures.ts`, `web/fixtures/board-placement/`.
- Fixture sources (do not copy logic): `adjacentFreeCenter`, `nextFreeCenters`, `deriveVariantName` from `src/components/studio/kv-generator/boardLayout.ts`; `overlaysForVariant` from `src/lib/studio/kv/overlayMutations.ts`; `editOutcome` from `src/lib/studio/kv/editOutcome.ts`.
- Flag is fail-closed on web: `useExperimentalFeatureEnabled(key) === true` (dev/staging force-on), and only meaningful when the parent `kv-agentic-canvas` is on.
- Flag off ⇒ P0 behaviour byte-identical (run card + question card render exactly as before).
- Tests: `bun test <file paths>` only — never a directory, never `bunx vitest`. RTL via `within(document.body)`. No partial `mock.module`. Test files < 50 KB.
- Commits: `feat(web): …`, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- No new interaction ⇒ no PostHog events; no new UI ⇒ no frndos-ui pass (the QuestionCard move is pixel-identical).

## Review Focus

1. **Fixture drift** — someone changes `boardLayout.ts` and forgets to re-export: the on-disk JSON must fail a `bun test` (drift test in Task 1) and `--check` must exit non-zero.
2. **Tie-breaks a PHP port gets wrong** — `nextFreeCenter` keeps the FIRST board on an x tie; `adjacentFreeCenter` uses a strict `< ARTBOARD_STEP/2` (320) tolerance on both axes; `overlaysForVariant` sort is stable on equal `z`. Each needs a named case with a hand-checked expected value (Task 1).
3. **`deriveVariantName` string edges** — curly apostrophe lead (`Let’s`), all-filler prompt, >32-char truncation with `…`, non-ASCII text (Task 1).
4. **Card host regression** — with the registry, a turn with `agentRun` and the flag off must render no run card, and the question card must still pick/send (existing `KvChat.agentRun.test.tsx`, `KvChat.questionCard.test.tsx` stay green; Task 2).
5. **Structure without parent** — `kv-agentic-canvas-structure` on while `kv-agentic-canvas` is off must NOT open the structure gate (Task 3).

---

### Task 1 (TASK-2): Board-placement fixture export — FIRST

**Files:**
- Create: `src/lib/studio/kv/boardPlacementFixtures.ts`
- Create: `src/lib/studio/kv/boardPlacementFixtures.test.ts`
- Create: `scripts/exportBoardPlacementFixtures.ts`
- Create (generated): `fixtures/board-placement/{adjacent-free-center,next-free-centers,derive-variant-name,overlays-for-variant,edit-outcome}.json`
- Modify: `package.json` scripts — `"fixture:board-placement": "bun run scripts/exportBoardPlacementFixtures.ts"`

**Interfaces:**
- Produces:
  - `type BoardPlacementFixtureFile = { function: string; source: string; cases: Array<{ name: string; input: Record<string, unknown>; expected: unknown }> }`
  - `const BOARD_PLACEMENT_FIXTURE_DIR = "fixtures/board-placement"`
  - `buildBoardPlacementFixtures(): Record<string /* file name, e.g. "adjacent-free-center.json" */, BoardPlacementFixtureFile>`
  - `serializeFixture(file: BoardPlacementFixtureFile): string` — `JSON.stringify(file, null, 2) + "\n"`
- JSON input shapes (snake_case, what PHP reads):
  - adjacent-free-center: `input: { boards: [{ id, center: {x,y} }], parent_id }` → `expected: {x,y}`
  - next-free-centers: `input: { boards, n }` → `expected: [{x,y}]`
  - derive-variant-name: `input: { prompt, fallback_index }` → `expected: string`
  - overlays-for-variant: `input: { overlays: [{id,type,x,y,width,height,rotation,z,payload,board_generation_id}], parent_chain: string[], variant_id, minted_ids: string[] }` → `expected: [{id,type,x,y,width,height,rotation,board_generation_id,payload}]` (no `z`; `minted_ids` are handed out in call order by the `mintId` callback)
  - edit-outcome: `input: { parent_is_concept, parent_resize_count, variant_redirect_enabled: true|false|null }` (`null` = arg omitted) → `expected: "rekey"|"fork"|"variant"`
- Boards are passed to the TS functions as `{ id, center }` cast to `KvBoard` — the functions read only `center`.

- [ ] **Step 1: Record baseline** — `bun test src/components/studio/kv-generator/boardLayout.test.ts src/lib/studio/kv/overlayMutations.test.ts src/lib/studio/kv/editOutcome.test.ts` (whichever exist) and note pass/fail counts.
- [ ] **Step 2: Write the failing test** `boardPlacementFixtures.test.ts`:
  - `writes the five contract files` — keys of `buildBoardPlacementFixtures()` equal the five names above; each `function` matches its TS name; case names unique per file.
  - `committed JSON matches the TypeScript` — for each file, `readFileSync(join(BOARD_PLACEMENT_FIXTURE_DIR, name))` (resolved from the web root) `=== serializeFixture(built)`.
  - Hand-checked edges (Review Focus 2–3):
    - adjacent `near_miss_within_tolerance_is_occupied`: A(0,0), B(950,10), parent A → `{x:1280,y:0}`
    - adjacent `exactly_half_step_is_free`: A(0,0), B(960,0), parent A → `{x:640,y:0}`
    - adjacent `other_row_does_not_block`: A(0,800), B(640,0), parent A → `{x:640,y:800}`
    - next `x_tie_keeps_first_board`: A(640,0), B(640,700), n=1 → `[{x:1280,y:0}]`
    - next `negative_n_is_empty`: n=-2 → `[]`
    - name `curly_apostrophe_lead`: `"Let’s try a neon variant"` → `"Neon"`; `all_filler`: `"do it"` → `"It"`; `truncates_over_32` ends with `"…"` and has length 33
    - overlays `equal_z_keeps_input_order`: two chain overlays with the same z keep input order; `excludes_unbound_and_other_boards`: null-bound and off-chain overlays absent
    - edit-outcome has 12 cases (concept × count {0,2} × redirect {true,false,null}); `concept_wins_over_redirect_off` → `"fork"`
- [ ] **Step 3: Run it to verify it fails** — `bun test src/lib/studio/kv/boardPlacementFixtures.test.ts` → FAIL (module not found).
- [ ] **Step 4: Implement `boardPlacementFixtures.ts`** — case tables per function (≥ 8 adjacent, ≥ 7 next, ≥ 12 names, ≥ 5 overlay, 12 edit-outcome), each `expected` computed by calling the real import. `mintId` = shift from a copy of `minted_ids`.
- [ ] **Step 5: Implement `scripts/exportBoardPlacementFixtures.ts`** — writes each file (mkdir -p) under the web root resolved from `import.meta.dir`; `--check` compares instead of writing and `process.exit(1)` listing stale files. Add the `fixture:board-placement` package script.
- [ ] **Step 6: Generate** — `bun run scripts/exportBoardPlacementFixtures.ts`, then `bun run scripts/exportBoardPlacementFixtures.ts --check` → exit 0.
- [ ] **Step 7: Run test to verify it passes** — `bun test src/lib/studio/kv/boardPlacementFixtures.test.ts` → PASS. Mutation check: temporarily change `ARTBOARD_STEP / 2` → `<=` in a scratch copy is not allowed in-tree; instead hand-edit one expected value in a fixture JSON, confirm the drift test fails, regenerate.
- [ ] **Step 8: Commit** `feat(web): KV agentic canvas P1 — board placement fixtures for the PHP ports (S18)`.
- [ ] **Step 9: Notify the lead** (SendMessage to `local_bd9f4295-cdda-428e-9eea-c307a22cbe2f`) with the five paths, the JSON shape above, and the commit SHA.

### Task 2 (TASK-1): KV card registry

**Files:**
- Create: `src/components/studio/kv-generator/cards/kvCardRegistry.ts`, `kvCardRegistry.test.ts`
- Create: `src/components/studio/kv-generator/cards/kvCards.ts` (the P0 registry instance), `kvCards.test.ts`
- Create: `src/components/studio/kv-generator/KvQuestionCard.tsx` — `QuestionCard` moved verbatim out of `KvChat.tsx` and exported as `KvQuestionCard`
- Create: `src/components/studio/kv-generator/useImageModelEstimate.ts` — `useImageModelEstimate` + `CRAFT_LOCKED_MODEL` moved out of `KvChat.tsx` (QuestionCard, GenerateBar and ModeSuggestion all use them)
- Modify: `src/components/studio/kv-generator/KvChat.tsx` (question-card branch ~L1575, run-card mount ~L2053, delete moved code ~L2449–2668)

**Interfaces:**
- Produces:
  - `type KvCardGate = "agentCanvas" | "structure"`; `type KvCardGates = Record<KvCardGate, boolean>`
  - `type KvCardEntry<P> = { component: ComponentType<P>; gate?: KvCardGate }`
  - `type KvCardRegistry<E extends Record<string, KvCardEntry<any>>> = { resolve<K extends keyof E & string>(kind: K, gates: KvCardGates): E[K]["component"] | null; kinds(): (keyof E & string)[] }`
  - `createKvCardRegistry<E>(entries: E): KvCardRegistry<E>` — ungated entry always resolves; gated entry resolves only when `gates[gate] === true`; unknown kind → `null`.
  - `KV_CARDS = createKvCardRegistry({ run_card: { component: KvAgentRunCard, gate: "agentCanvas" }, question_card: { component: KvQuestionCard } })`
- Round B adds `plan_card: { component: KvPlanCard, gate: "structure" }` — one line.

- [ ] **Step 1: Baseline** — `bun test src/components/studio/kv-generator/KvChat.agentRun.test.tsx src/components/studio/kv-generator/KvChat.questionCard.test.tsx src/components/studio/kv-generator/KvChat.craftSendMode.test.tsx src/components/studio/kv-generator/KvChat.nextMove.test.tsx src/components/studio/kv-generator/KvChat.pickers.contract.test.ts src/components/studio/kv-generator/KvChat.surface.contract.test.ts src/components/studio/kv-generator/KvAgentRunCard.test.tsx`; record counts.
- [ ] **Step 2: Failing tests** — `kvCardRegistry.test.ts`: `resolves an ungated card regardless of gates`; `hides a gated card until its gate is on`; `unknown kind resolves to null`; `a throwaway card kind needs only its registration` (AC-13: register `fake_card` with gate `structure`, resolve it with no other change). `kvCards.test.ts`: `run_card → KvAgentRunCard behind agentCanvas`; `question_card → KvQuestionCard always`; `kinds() is exactly run_card, question_card`.
- [ ] **Step 3: Run → FAIL** (modules missing).
- [ ] **Step 4: Implement** the registry + `KV_CARDS`; move `QuestionCard`/`useImageModelEstimate`/`CRAFT_LOCKED_MODEL` out of `KvChat.tsx` unchanged (imports follow the code).
- [ ] **Step 5: Host reads the registry** — in `KvChat` build `const cardGates: KvCardGates = { agentCanvas: agentRunCardsEnabled, structure: false }` (Task 3 replaces `structure`); question branch renders `const QuestionCardComponent = KV_CARDS.resolve("question_card", cardGates)` (fall through to the default assistant render if null); run-card mount uses `const RunCard = KV_CARDS.resolve("run_card", cardGates)` and `agentRun = RunCard && fileId ? m.metadata?.agentRun : undefined`. `agentRunCardsEnabled` other uses (pending-dots, brainstorm suggestions) stay as they are.
- [ ] **Step 6: Run** the new tests + Step 1 baseline set → new PASS, baseline counts unchanged.
- [ ] **Step 7: Commit** `feat(web): KV agentic canvas P1 — KV card registry (S17)`.

### Task 3 (TASK-3): Flag `kv-agentic-canvas-structure`

**Files:**
- Modify: `src/lib/featureFlags/constants.ts` — `KV_AGENTIC_CANVAS_STRUCTURE: "kv-agentic-canvas-structure"` under `KV_AGENTIC_CANVAS`, commented (child of the P0 flag; api gates tool routes with `feature.flag:kv-agentic-canvas-structure,off`; web gates plan-card rendering; fail-closed; no `show-` prefix because the contract fixed the key).
- Modify: `src/components/studio/kv-generator/cards/kvCardRegistry.ts` (+ test) — `kvCardGates(flags: { agentCanvas: boolean; structure: boolean }): KvCardGates` with `structure = agentCanvas && structure`.
- Modify: `KvGeneratorLayout.tsx` (~L4404) — `kvAgenticStructureEnabled = useExperimentalFeatureEnabled(MAJOR_FEATURE_FLAGS.KV_AGENTIC_CANVAS_STRUCTURE) === true`; pass `agentStructureEnabled={kvAgenticStructureEnabled}` next to `agentRunCardsEnabled` (~L9764).
- Modify: `KvChat.tsx` — `agentStructureEnabled?: boolean` (default `false`) on both prop types that carry `agentRunCardsEnabled` (L277/361 → L779 → L1243/1260); `cardGates = kvCardGates({ agentCanvas: agentRunCardsEnabled, structure: agentStructureEnabled })`.

- [ ] **Step 1: Failing tests** in `kvCardRegistry.test.ts`: `structure stays closed while the parent flag is off` (`kvCardGates({agentCanvas:false, structure:true}).structure === false`), `structure opens only with its parent`, and `the flag key is kv-agentic-canvas-structure` (`MAJOR_FEATURE_FLAGS.KV_AGENTIC_CANVAS_STRUCTURE`).
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** constant, `kvCardGates`, layout read, prop plumbing.
- [ ] **Step 4: Run** registry tests + Task 2 baseline set → PASS / unchanged. tsc: `bunx tsc --noEmit -p . 2>&1 | grep -c "error TS"` compared with the base commit count (no new errors in touched files).
- [ ] **Step 5: Commit** `feat(web): KV agentic canvas P1 — kv-agentic-canvas-structure flag (S3)`.
- [ ] PostHog: check (read-only) whether `kv-agentic-canvas-structure` exists in project 389744; do not create it — report to the lead (api owns the S3 gate; absent = off is safe).

### Task 4: Track + review

- [ ] Tick TASK-1..3 in `docs/tracks/kv-agentic-canvas-p1.track.md`, Implementation → `in_progress`, append `### 2026-10-22 — daffa (Round A web)` log; commit `docs(web): KV agentic canvas P1 — Round A track`.
- [ ] superpowers:requesting-code-review over `ffd52e3f6..HEAD`; fix Critical/Important; re-run all touched tests.

## Contract deviations

- None expected. Note for the api: S18 puts the JSON under `web/fixtures/board-placement/`; the api repo cannot see that path in its own CI, so (like `api/tests/Fixtures/kv-projection/`) the api session decides whether to copy the files in or read the sibling checkout.
