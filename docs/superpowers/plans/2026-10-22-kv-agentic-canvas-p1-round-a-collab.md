# KV Agentic Canvas P1 — Round A — Collab (frnd-hocuspocus) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `POST /internal/kv-files/{fileId}/ops` change canvas structure (`add_board`, `rename_board`, `move_board`, `hide_board`, `unhide_board`, `rekey_board_tip`) through an op registry. The existing layer ops behave exactly as before.

**Architecture:** Each op kind becomes a handler object `{ kind, schema, touches, validate(doc, op), write(doc, op): before, applied(op) }`. Handlers live in `kvLayerOps.ts` / `kvBoardOps.ts` and are collected into a `Map` in `kvOpRegistry.ts`. `applyKvOps` validates the whole batch by running validate+write on a **scratch clone** of the doc, so later ops see earlier ones and nothing touches the live doc on a refusal. It then replays the writes into the live doc in one `SERVER_WRITE_ORIGIN` transaction. Materialisation follows what the batch touched: overlays go through C2, boards through the existing `/snapshot` back-channel, and the two run in parallel. Refusals are `KvOpRefusal` subclasses that carry their own HTTP status and body, so the route maps them generically.

**Tech Stack:** Node 20, TypeScript, Hocuspocus 2.15, Yjs 13, zod 3, vitest 4.

**Spec:** `collab/.worktrees/kv-agentic-canvas-p1/docs/prd/kv-agentic-canvas-p1.md` (TASK-1..9) + contracts S1, S2 in `docs/superpowers/plans/2026-10-22-kv-agentic-canvas-p1-structure-contracts.md`. P0 precedent: `docs/superpowers/plans/2026-09-29-kv-agentic-canvas-p1-collab.md`.

**Worktree:** `collab/.worktrees/kv-agentic-canvas-p1`, branch `feature/daffa/vc-kv-agentic-canvas-p1`. All paths below are relative to it.

**Baseline (2026-10-22, before any change):** `npx vitest run` → 17 files, **200 tests passed**. `npx tsc --noEmit` → clean.

## Global Constraints

- Op kind names, payload field names, error codes and `before` keys are exactly as in S1. No renames.
- Error bodies: `409 {error:'board_exists', board_id}`, `409 {error:'board_changed', board_id, expected, current}`, `404 {error:'board_not_found', board_id}`. Existing layer bodies are unchanged.
- One `doc.transact(…, SERVER_WRITE_ORIGIN)` per batch. A refusal anywhere means nothing is written and nothing is materialised.
- `MAX_KV_OPS = 200` counts layer and board ops together.
- Board Y.Map shape mirrors web `artboardToBoardMap`: `x, y, name, versionIds: Y.Array<string>, productionStatus: null, assigneeId: null`.
- Board pre-image shape = C1.1 `document.boards` entry: `{ x, y, name, versionIds: string[] }` (camelCase).
- Existing test files may change only where noted (one invalid-body case in `kvHttp.test.ts` used `rekey_board_tip` as the "unknown kind" example).
- Commits: `feat(collab): …` / `test(collab): …` / `refactor(collab): …`, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. No push, no PR, never `git stash`.

## Contract deviations (tell the lead)

1. **`rekey_board_tip` APPENDS `to` to `versionIds` instead of prepending it.** web's `docRekeyBoardTip` (`web/src/lib/kv/yjsSerializer.ts`) and every fixture keep the chain oldest→newest with the tip LAST (`['gen_board_v1','gen_board_a']` under key `gen_board_a`). Prepending would make collab-written chains disagree with web-written ones. Also mirrored from web: an empty chain falls back to `[from]`, the result is de-duplicated, and `meta.masterGenerationId` moves `from → to` when it pointed at `from`. `productionStatus` / `assigneeId` are carried over.
2. **`unhide_board` removes EVERY occurrence of `board_id` from `removed`**, not only the first. Two peers hiding concurrently leave duplicates, and removing one copy would keep the board hidden. This is the same reasoning as `remove_layer` deleting every seed-race copy.
3. **`rekey_board_tip` counts as an overlay write too**, because it rewrites `boardGenerationId`. It hydrates an empty doc overlay list from REST before writing, and it triggers overlay (C2) materialisation alongside board materialisation. Without this, REST overlays would keep pointing at `from` after a rekey on a file nobody has open.
4. **Additive response fields:** each `applied` board entry is `{kind, board_id}`, and rekey adds `from` (`board_id` = `to`). The response gains `materialization: {overlays: boolean|null, boards: boolean|null}` (`null` = not run). `materialized` stays a boolean: true only when every materialisation that ran succeeded. `before.removed` is present only when a hide/unhide op is in the batch.
5. **Name normalisation mirrors web `docRenameBoard`:** `rename_board` / `add_board` store `name.trim() || null`. The CAS compares `expected.name` with the stored value.
6. `add_board.agent_run_id` is accepted and logged but not stored in the doc (S1 lists no doc field for it). An empty `version_ids` is stored as `[board_id]`, the same as `artboardToBoardMap`.
8. **(Added after review) `hide_board` pushes `[board_id, ...versionIds]`** (deduped) into `removed`, the same as web's `docRemoveBoard`, and `unhide_board` removes all of them (every copy). web's `computeBoardLayout` drops only `removed` generations, so hiding just the tip lets the older versions auto-tile back as boards.
7. S2's internal signature is followed with one addition: handlers also expose `applied(op)` and `touches`. `validate` throws, and `write` returns the pre-image.

## Review Focus

- `removed` holds duplicate copies of an id (concurrent hides) → `unhide_board` must leave zero copies → test in Task 5.
- `rekey_board_tip` on a never-opened file whose doc overlay list is empty → overlays are hydrated from REST, rekeyed, and materialised → test in Task 6.
- `rekey_board_tip` of the master board or of a board with an empty chain → master follows and the chain is `[from, to]` → tests in Task 6.
- A board-only batch must not read `studio_files.overlays` and must not POST overlays → test in Task 7.
- A refusal on the LAST op of a mixed layer+board batch leaves the live doc byte-identical, and no materialiser is called → tests in Task 9.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/kvOpRegistry.ts` (create) | `KvOpRefusal`, `KvTooManyOps`, `KvOpHandler`, `KvApplied`, `KvBefore`, `mergeBefore`, `KV_OP_HANDLERS: Map`, `handlerFor(kind)`, `kvOpSchema` (zod discriminated union over all handler schemas), `KvOp` type |
| `src/kvLayerOps.ts` (create) | Layer zod schemas, `KvLayerChanged/NotFound/Exists`, the `set_layer`/`add_layer`/`remove_layer` handlers, `LAYER_OP_HANDLERS` |
| `src/kvBoardOps.ts` (create) | Board zod schemas, `KvBoardExists/Changed/NotFound`, the six board handlers, `BOARD_OP_HANDLERS` |
| `src/applyKvOps.ts` (modify) | Orchestrator: scratch-doc validation, one live transaction, materialisation dispatch. Re-exports layer errors + `KvTooManyOps` + `MAX_KV_OPS` (existing imports keep working) |
| `src/kvHttp.ts` (modify) | `kvOpsBody` built from `kvOpSchema`; generic `KvOpRefusal` mapping; deps gain `materializeBoards` |
| `src/snapshot.ts` (modify) | `materializeKvBoards(fileId, canvas): Promise<boolean>`; `materializeKvSnapshot` shares its POST loop |
| `src/kvSerialize.ts` (modify) | export `artboardToBoardMap` |
| `src/readKvDocument.ts` (modify) | export `boardMapToJson(board)` (extracted from `docToKvDocumentJson`) |
| `src/index.ts` (modify) | wire `materializeBoards: materializeKvBoards` |
| `src/kvBoardOps.test.ts` (create) | per-kind board tests through `applyKvOps` |
| `src/kvOpRegistry.test.ts` (create) | registry + refusal-shape tests |

---

### Task 1: Op registry refactor (TASK-1, S2) — no behaviour change

**Files:** Create `src/kvOpRegistry.ts`, `src/kvLayerOps.ts`, `src/kvOpRegistry.test.ts`. Modify `src/applyKvOps.ts`, `src/kvHttp.ts`.

**Interfaces — Produces:**
```ts
// kvOpRegistry.ts
export abstract class KvOpRefusal extends Error { abstract readonly status: number; abstract body(): Record<string, unknown>; }
export class KvTooManyOps extends KvOpRefusal { constructor(public readonly max: number) } // 422 {error:'too_many_ops', max}
export type KvApplied = { kind: string; layer_id: string } | { kind: string; board_id: string; from?: string };
export interface KvBoardJson { x: number; y: number; name: string | null; versionIds: string[] }
export interface KvBefore { layers: Record<string, KvLayer | null>; boards: Record<string, KvBoardJson | null>; removed?: string[] }
export interface KvOpHandler<O extends { kind: string } = any> {
  kind: O['kind'];
  schema: z.AnyZodObject;               // has `kind: z.literal(kind)`, .strict()
  touches: { overlays: boolean; boards: boolean };
  validate(doc: Y.Doc, op: O): void;    // throws KvOpRefusal
  write(doc: Y.Doc, op: O): Partial<KvBefore>; // pre-image of what it touched, read BEFORE writing
  applied(op: O): KvApplied;
}
export function mergeBefore(into: KvBefore, part: Partial<KvBefore>): void; // first touch per key wins; `removed` first wins
export const KV_OP_HANDLERS: ReadonlyMap<string, KvOpHandler>;             // [...LAYER_OP_HANDLERS, ...BOARD_OP_HANDLERS]
export function handlerFor(kind: string): KvOpHandler;                      // throws Error on unknown (schema already rejected it)
export const kvOpSchema: z.ZodDiscriminatedUnion<'kind', …>;               // built from KV_OP_HANDLERS
export type KvOp = KvLayerOp | KvBoardOp;
// kvLayerOps.ts
export type KvLayerOp = { kind: 'set_layer'; … } | { kind: 'add_layer'; … } | { kind: 'remove_layer'; … }; // moved verbatim from applyKvOps
export class KvLayerChanged / KvLayerNotFound / KvLayerExists extends KvOpRefusal  // same ctor args + fields as today
export const LAYER_OP_HANDLERS: KvOpHandler[];
```
In Task 1, `BOARD_OP_HANDLERS` is `[]` in a stub `kvBoardOps.ts` and `KvBoardOp = never`. `ApplyKvOpsResult.before` becomes `KvBefore` and is always `{layers, boards: {}}`.

- [ ] **Step 1: Write failing tests** in `src/kvOpRegistry.test.ts`:
  - `registers set_layer, add_layer, remove_layer` → `[...KV_OP_HANDLERS.keys()]` contains exactly those 3 (board kinds are added by later tasks; assert with `toEqual(expect.arrayContaining([...]))` plus each handler's `kind` equals its key).
  - `refusals carry their HTTP status and body` → `new KvLayerChanged('l', {z:1}, {z:2})` → `status 409`, `body()` = `{error:'layer_changed', layer_id:'l', expected:{z:1}, current:{z:2}}`. `KvLayerNotFound('l')` → 404 `{error:'layer_not_found', layer_id:'l'}`. `KvLayerExists('l')` → 409 `{error:'layer_exists', layer_id:'l'}`. `KvTooManyOps(200)` → 422 `{error:'too_many_ops', max:200}`.
  - `mergeBefore keeps the first pre-image per key` → merging `{layers:{a:null}}` then `{layers:{a:X}}` leaves `a: null`. `removed` is set once and is not overwritten.
- [ ] **Step 2:** `npx vitest run src/kvOpRegistry.test.ts` → FAIL (module not found).
- [ ] **Step 3: Implement.** Move the layer zod schemas (`finite`, `rectPatch`, `payloadPatch`, `expectation`, `layerJson`, and the three op objects) out of `kvHttp.ts` into `kvLayerOps.ts`, one `schema` per handler. Move the `writeOp` branches into each handler's `write`. `validate` replicates `planKvOps` on the doc it is given: use `readKvLayers(doc)` and the first copy, throw `KvLayerExists` / `KvLayerNotFound` / `KvLayerChanged` with `currentFor`. `write` reads the pre-image (`readKvLayers(doc).find(...) ?? null`) before mutating. Rewrite `applyKvOps`:
  1. `ops.length > MAX_KV_OPS` → throw `KvTooManyOps`.
  2. `needsOverlays = ops.some(op => handlerFor(op.kind).touches.overlays)`. Load persisted overlays only if `needsOverlays && readKvLayers(doc).length === 0`.
  3. Inside `connection.transact((d) => …)`: build `scratch = new Y.Doc()` with `Y.applyUpdate(scratch, Y.encodeStateAsUpdate(d))` and push the hydrate list into it. For each op run `h.validate(scratch, op); mergeBefore(before, h.write(scratch, op)); applied.push(h.applied(op))`. Any throw means `d` is untouched. Then `d.transact(() => { hydrate; for op: h.write(d, op) }, SERVER_WRITE_ORIGIN)`.
  4. Materialise overlays only if `needsOverlays` (Task 7 adds boards).

  Delete `planKvOps` and `writeOp`. Re-export `KvLayerChanged, KvLayerExists, KvLayerNotFound, KvTooManyOps, MAX_KV_OPS, type KvOp` from `applyKvOps.ts`. In `kvHttp.ts`, `kvOpsBody.ops = z.array(kvOpSchema).min(1)`. The existing explicit `instanceof` error mapping stays as it is for this task.
- [ ] **Step 4:** `npx vitest run` → **203 passed** (200 baseline + 3 new), zero edits to existing tests. `npx tsc --noEmit` is clean.
- [ ] **Step 5: Commit** `refactor(collab): KV op registry — handler objects per op kind (S2)`.

### Task 2: `add_board` (TASK-2)

**Files:** Modify `src/kvBoardOps.ts`, `src/kvSerialize.ts` (export `artboardToBoardMap`), `src/readKvDocument.ts` (export `boardMapToJson`). Create `src/kvBoardOps.test.ts`.

**Interfaces — Produces:** `KvBoardExists(boardId)` → 409 `{error:'board_exists', board_id}`. `KvBoardNotFound(boardId)` → 404 `{error:'board_not_found', board_id}`. `readBoardJson(doc, id): KvBoardJson | null`. `add_board` schema: `{kind, board_id: str min1, x: finite, y: finite, name: string|null, version_ids: string(min1)[], agent_run_id: string|null}` with `.strict()`. `touches {overlays:false, boards:true}`. `applied` = `{kind:'add_board', board_id}`.

- [ ] **Step 1: Failing tests** in `kvBoardOps.test.ts`. Use the same harness as `applyKvOps.test.ts` (`closedFile` over `webKvDoc()`, plus `materializeBoards = vi.fn(async () => true)`; until Task 7, pass it through only where the signature accepts it):
  - `add_board creates a web-shaped board and reports a null pre-image`. Run `add_board {board_id:'ph_1', x:1200, y:0, name:'Variant B', version_ids:['ph_1'], agent_run_id:'run_1'}`. The stored board map has `x 1200, y 0, name 'Variant B'`, `versionIds` is a `Y.Array` equal to `['ph_1']`, and `productionStatus`/`assigneeId` are `null`. `result.before.boards` = `{ph_1: null}`, `applied` = `[{kind:'add_board', board_id:'ph_1'}]`, and overlays are unchanged.
  - `add_board stores an empty version_ids as [board_id]` and `name '  '` as `null`.
  - `409 board_exists when the key exists; nothing written` → `add_board board_id:'gen_board_a'` rejects with `KvBoardExists` (`boardId 'gen_board_a'`), and the stored update is byte-identical.
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3:** Implement the handler. `write` sets `boards.set(id, artboardToBoardMap(id, {x, y, name: norm(name), version_ids: v.length ? v : [id]}))`. `norm = (s) => s?.trim() || null`. Log `agent_run_id`.
- [ ] **Step 4:** `npx vitest run` → all green.
- [ ] **Step 5: Commit** `feat(collab): add_board op kind (S1)`.

### Task 3: `rename_board` (TASK-3)

**Interfaces — Produces:** `KvBoardChanged(boardId, expected, current)` → 409 `{error:'board_changed', board_id, expected, current}`. Schema `{kind, board_id, name: string, expected?: {name: string|null}.strict()}`. `touches {false, true}`.

- [ ] **Step 1: Failing tests:**
  - `rename_board sets the name and returns the full board pre-image` → `before.boards.gen_board_a` = `{x:0, y:0, name:'Concept A', versionIds:['gen_board_v1','gen_board_a']}`, and the stored name is `'Hero'`.
  - `a matching expected.name writes`. `a stale expected.name → KvBoardChanged` with `expected {name:'Old'}`, `current {name:'Concept A'}`, and nothing written.
  - `expected {name:null}` matches a board whose name is null (use a doc where `name` is `null`).
  - `a blank name clears to null` (web parity).
  - `unknown board → KvBoardNotFound('ghost')`.
- [ ] **Step 2–4:** FAIL → implement (CAS compares `expected.name` with the stored `name ?? null`) → green.
- [ ] **Step 5: Commit** `feat(collab): rename_board op kind with name CAS (S1)`.

### Task 4: `move_board` (TASK-4)

Schema `{kind, board_id, x: finite, y: finite, expected?: {x: finite, y: finite}.strict()}`. `touches {false, true}`. `current` in the 409 is `{x, y}`.

- [ ] **Step 1: Failing tests:** `move_board sets x and y and returns the pre-image`. `a stale expected {x:5,y:5} → KvBoardChanged` with `current {x:0,y:0}` and nothing written. `unknown board → 404`. `the board Y.Map instance is kept` (the same object before and after, because web observes it).
- [ ] **Step 2–4:** FAIL → implement (`board.set('x')`, `board.set('y')` on the existing map) → green.
- [ ] **Step 5: Commit** `feat(collab): move_board op kind with position CAS (S1)`.

### Task 5: `hide_board` / `unhide_board` (TASK-5)

Schemas `{kind, board_id}` with `.strict()`. `touches {false, true}`. `write` returns `{removed: removedArray.toArray()}` read before mutating.

- [ ] **Step 1: Failing tests:**
  - `hide_board pushes the id into removed; before.removed is the array before` (`[]`).
  - `hide_board is idempotent` → hiding twice in one batch, or across two calls, leaves exactly one copy.
  - `unhide_board removes the id` and `is a no-op when not hidden` (it still returns 200-style success).
  - `unhide_board removes EVERY copy` (doc seeded with `removed = ['gen_board_a','gen_board_a']`) → `[]`.
  - `hide/unhide of a board missing from boards → KvBoardNotFound`, even when the id is already in `removed`.
  - `before.removed in a hide+unhide batch is the pre-batch array`.
- [ ] **Step 2–4:** FAIL → implement (delete indexes from the end) → green.
- [ ] **Step 5: Commit** `feat(collab): hide_board / unhide_board op kinds (S1)`.

### Task 6: `rekey_board_tip` (TASK-6)

Schema `{kind, from: str min1, to: str min1}` with `.strict()`. `touches {overlays:true, boards:true}`. `applied` = `{kind:'rekey_board_tip', board_id: to, from}`. `write` returns `{boards: {[from]: pre, [to]: null}}`.

- [ ] **Step 1: Failing tests:**
  - `rekey moves the board to the new key and appends the tip to the chain` → `boards` has `gen_board_b` and no `gen_board_a`; `versionIds` = `['gen_board_v1','gen_board_a','gen_board_b']`; `x, y, name` are kept; `before.boards` = `{gen_board_a: {…pre}, gen_board_b: null}`.
  - `rekey rewrites boardGenerationId on every overlay of the old board` (HEADLINE + LOGO → `gen_board_b`). A layer on another board is untouched (add a third overlay with `board_generation_id:'other'`).
  - `rekey moves master when it pointed at from` (`meta.masterGenerationId` → `gen_board_b`).
  - `an empty chain becomes [from, to]`.
  - `from absent → KvBoardNotFound(from)`. `to exists → KvBoardExists(to)`. `from === to → KvBoardExists`. In every refusal case nothing is written.
  - `on a never-opened file (empty doc overlays) the REST overlays are hydrated then rekeyed` → `loadPersistedOverlays` is called, and the stored overlays carry `boardGenerationId 'gen_board_b'`.
- [ ] **Step 2–4:** FAIL → implement (carry `productionStatus`/`assigneeId`; iterate every overlay map, not only the first copies) → green.
- [ ] **Step 5: Commit** `feat(collab): rekey_board_tip op kind — moves board, chain, master and overlays (S1)`.

### Task 7: Board materialisation (TASK-7)

**Files:** `src/snapshot.ts`, `src/applyKvOps.ts`, `src/snapshot.test.ts`.

**Interfaces — Produces:** `export type MaterializeBoards = (fileId: string, canvas: KvCanvasState) => Promise<boolean>`. `export async function materializeKvBoards(fileId, canvas): Promise<boolean>` posts `{document: canvas, source: 'auto_snapshot'}` to `${API_BASE_URL}/internal/kv-files/{id}/snapshot` with `X-Internal-Token` and `AbortSignal.timeout(KV_OVERLAYS_POST_TIMEOUT_MS)`. 4xx → false after 1 attempt; 5xx/transport errors → up to 3 attempts; zero artboards → false with no POST. `applyKvOps` args gain `materializeBoards: MaterializeBoards`. The result gains `materialization: {overlays: boolean|null, boards: boolean|null}`.

- [ ] **Step 1: Failing tests:**
  - snapshot.test.ts `materializeKvBoards`: `POSTs the canvas to /snapshot and returns true on 2xx` (assert the URL, the token header, and `body.document.artboards`); `4xx → false after one attempt`; `5xx ×3 → false`; `zero artboards → false, no fetch`.
  - kvBoardOps.test.ts: `a board-only batch materialises boards with docToKvCanvasState of the written doc, never overlays, never loads persisted overlays` (`materializeBoards` is called once with `artboards` containing `ph_1`; `materialize` and `loadPersistedOverlays` are not called; result is `materialization {overlays:null, boards:true}`, `materialized true`). `a mixed batch runs both`. `boards false → materialized false, write kept`. `a throwing materializeBoards → false, write kept`. `hide_board materialises removed_generation_ids`.
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3:** Extract the POST/retry loop of `materializeKvSnapshot` into `postKvCanvasSnapshot(fileId, canvas, timeoutMs?): Promise<boolean>`. `materializeKvSnapshot` keeps its guard, its logs and no timeout. `applyKvOps` computes `needsBoards` from `touches` and runs the needed materialisers in `Promise.all`, each wrapped in try/catch → false. `materialized = every ran → true`.
- [ ] **Step 4:** `npx vitest run` → green (the existing `materializeKvSnapshot` tests are unchanged).
- [ ] **Step 5: Commit** `feat(collab): materialise boards via /snapshot after board ops (S1, FR-5)`.

### Task 8: Route delegation + response shape (TASK-8)

**Files:** `src/kvHttp.ts`, `src/index.ts`, `src/kvHttp.test.ts`.

- [ ] **Step 1: Failing tests** in `kvHttp.test.ts`. `boot()` adds `materializeBoards = vi.fn(async () => true)` to deps.
  - `200 add_board → applied [{kind:'add_board', board_id}], before {layers:{}, boards:{ph_1:null}}, materialization {overlays:null, boards:true}`.
  - `409 board_exists body`, `409 board_changed body {error, board_id, expected:{name:'Old'}, current:{name:'Concept A'}}`, `404 board_not_found body`.
  - `422 invalid_body for a board op with an unknown key` (`move_board` + `z`).
  - Edit the existing invalid-body case: replace `{kind:'rekey_board_tip', from:'a', to:'b'}` (now valid) with `{kind:'delete_board', board_id:'a'}`.
- [ ] **Step 2:** run → FAIL (board refusals come back as 500).
- [ ] **Step 3:** Replace the `instanceof` chain with `if (err instanceof KvOpRefusal) { logger.info(...); json(res, err.status, err.body()); return; }`. Add `materializeBoards` to `KvRouteDeps`, pass it through, and wire `materializeKvBoards` in `index.ts`.
- [ ] **Step 4:** `npx vitest run` + `npx tsc --noEmit` → green.
- [ ] **Step 5: Commit** `feat(collab): ops route delegates board refusals and reports board materialisation (S1)`.

### Task 9: Cross-kind tests (TASK-9)

**Files:** `src/kvBoardOps.test.ts`, `src/kvHttp.test.ts`.

- [ ] **Step 1: Write tests** (they should pass straight away; if one fails, fix the code before committing):
  - `a mixed batch whose LAST op is refused writes nothing`. Run `[set_layer HEADLINE, add_board ph_1, hide_board gen_board_a, add_board gen_board_a]` → `KvBoardExists`. The stored update is byte-identical, and neither materialiser is called.
  - `a board refusal FIRST also blocks later layer ops` (`rename_board ghost` then `remove_layer LOGO`) → 404, LOGO still present.
  - `a mixed layer+board batch reaches peers as ONE update` (holder doc `update` count is 1).
  - `later ops see earlier board ops` (`add_board ph_1` then `rename_board ph_1` then `move_board ph_1`).
  - HTTP + provider: `an open browser sees add_board live` (AC-2): the browser's `boards` gains `ph_1` via `vi.waitFor`. `an open browser's overlays follow rekey_board_tip live`.
- [ ] **Step 2:** `npx vitest run` → green. `npx tsc --noEmit` → clean.
- [ ] **Step 3: Commit** `test(collab): mixed layer+board batch atomicity and live board ops`.

### Task 10: Track + session log

- [ ] Tick TASK-1..9 in `docs/tracks/kv-agentic-canvas-p1.track.md`. Set `Service PRD: in_progress` and `Implementation: completed`. Append `### 2026-10-22 — daffa (executing-plans)` with the commits, the test counts (200 → N), and the contract deviations 1–7.
- [ ] Commit `docs(collab): tick KV P1 Round A tasks and log the session`.

### Task 11: Code review

- [ ] Run superpowers:requesting-code-review on `git diff 999bdc3..HEAD`. Fix Critical/Important findings (TDD, one commit each). Re-run `npx vitest run` + `npx tsc --noEmit`.
