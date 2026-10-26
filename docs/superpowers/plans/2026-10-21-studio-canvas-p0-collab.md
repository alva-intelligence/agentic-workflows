# Studio Canvas P0 — Collab (frnd-hocuspocus) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the collab server host `studio:<studioFileId>` documents: verify them through api, persist their Yjs updates in `studio_yjs_updates`, and keep every existing room type (deck, KV, proposal, insight) unaffected.

**Architecture:** A new prefix in the table-driven `ROOM_VERIFIERS`, a standalone `StudioPersistence` extension (same load/append/snapshot mechanics as `KvPersistence`, but no seeding and no materialization), and explicit exclusions so `DeckPersistence` and the deck disconnect path never claim a Studio doc. `KvPersistence` is deliberately not refactored (no tests cover it today).

**Tech Stack:** TypeScript (ESM, `.js` import suffixes), `@hocuspocus/server ^2.15`, `yjs`, `pg`, vitest ^4.

**Spec:** `frnd/docs/prd/studio-canvas.md` (FR-27, NFR-4) and the decision record `.workflow-state.json` → `features["studio-canvas"].brainstorming.questions` (q10). api contract: `2026-10-21-studio-canvas-p0-api.md` Task 5 and Task 3 (`studio_yjs_updates`).

## Global Constraints

- Work in `collab/` on branch `feature/daffa/vc-studio-canvas` (cut from `main`). Never push. Deploy is manual after merge to `main` (`docs/deploy-staging.md`).
- Prefix is exactly `studio:`; the id after it is a `studio_files.id` (26-char ULID).
- Verify endpoint `/internal/sanctum-verify-for-studio`, body `{ token, studio_file_id }`.
- Table `studio_yjs_updates (id bigserial, studio_file_id, update bytea, is_snapshot bool, created_at)`, owned and migrated by api.
- Studio docs are never seeded from REST/DB state and never materialized on disconnect in P0.
- Commands from `collab/`: `npm test` (vitest run), `npm run typecheck`, `npm run build`. There is no lint script.
- Commits: `feat(collab): …` ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. A `studio:` document must never be loaded or stored by `DeckPersistence` (it claims every name it does not exclude and would try to seed from `decks`). → Task 2 test `DeckPersistence ignores studio docs`.
2. A Studio doc that has never been saved opens empty and writes nothing until the first real update (no seed snapshot row). → Task 2 test `opens an empty doc without writing`.
3. Reloading a doc after a snapshot replays only the latest snapshot and the updates after it, in id order. → Task 2 test `loads from the latest snapshot onward`.
4. The last client disconnecting from a Studio doc must not trigger the deck or KV materialize path. → Task 2 test `onDisconnect does not materialize studio docs`.
5. A viewer role from api must make the connection read-only (existing `onAuthenticate` behaviour, now reachable for Studio). → Task 1 test `routes studio docs to the studio verifier`.

---

### Task 1: `studio:` prefix and verifier

**Files:**
- Modify: `collab/src/auth.ts`
- Test: `collab/src/auth.test.ts` (extend)

**Interfaces:**
- Produces:
  - `export const STUDIO_DOC_PREFIX = 'studio:';` (in `auth.ts`, next to `PROPOSAL_DOC_PREFIX`).
  - `export async function verifyForStudio(args: { fileId: string; token: string }): Promise<AuthenticatedUser>` — `postSanctumVerify({ endpoint: '/internal/sanctum-verify-for-studio', body: { token, studio_file_id: fileId }, logId: fileId })`.
  - New `ROOM_VERIFIERS` entry `{ prefix: STUDIO_DOC_PREFIX, verify: (fileId, token) => verifyForStudio({ fileId, token }) }`.
  - `isPresenceOnlyRoom('studio:x')` stays `false` (Studio docs persist).

- [ ] **Step 1: Write the failing test.** Add `['studio:file-1', 'sanctum-verify-for-studio', { studio_file_id: 'file-1' }]` to the `it.each` routing table at `auth.test.ts:318`, and `['studio:file-1', false]` to the `isPresenceOnlyRoom` table at lines 357–371.
- [ ] **Step 2: Run, see the new row fail.** `npm test -- src/auth.test.ts`
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, see all of `auth.test.ts` pass.**
- [ ] **Step 5: Commit** `feat(collab): verify studio canvas documents via api`

---

### Task 2: `StudioPersistence` and room exclusions

**Files:**
- Create: `collab/src/studioPersistence.ts`, `collab/src/studioPersistence.test.ts`
- Modify: `collab/src/persistence.ts` (DeckPersistence guards), `collab/src/index.ts` (extensions array + `onDisconnect`)

**Interfaces:**
- Produces `export class StudioPersistence implements Extension` with the same hook set and mechanics as `KvPersistence` (`persistence.ts:262`), table `studio_yjs_updates`, prefix `STUDIO_DOC_PREFIX`:
  - `onLoadDocument({ documentName, document })`: returns `undefined` for other prefixes. Runs the `latest_snap` CTE query from `KvPersistence` against `studio_yjs_updates`, applies each row with `Y.applyUpdate(document, new Uint8Array(row.update))`, and returns the document. When no rows exist it returns the empty document and inserts nothing.
  - `afterLoadDocument`: registers `document.on('update', (u) => this.appendUpdate(fileId, u).catch(log))`.
  - `onStoreDocument`: writes a snapshot row (`is_snapshot = true`, `Buffer.from(Y.encodeStateAsUpdate(document))`) when `updatesSinceSnapshot >= config.SNAPSHOT_UPDATE_THRESHOLD` or `now - lastSnapshotAt >= config.SNAPSHOT_INTERVAL_MS` (same config keys as KV).
  - `afterUnloadDocument`: clears the per-file state.
  - `private appendUpdate(fileId: string, update: Uint8Array): Promise<void>` — `INSERT INTO studio_yjs_updates (studio_file_id, update, is_snapshot, created_at) VALUES ($1, $2, false, now())`.
- `DeckPersistence`: every hook's guard becomes `documentName.startsWith(KV_DOC_PREFIX) || documentName.startsWith(STUDIO_DOC_PREFIX) || isPresenceOnlyRoom(documentName)`.
- `index.ts`: `extensions: [persistence, kvPersistence, studioPersistence]`; `onDisconnect` returns early for `STUDIO_DOC_PREFIX` before the KV and deck branches.

- [ ] **Step 1: Write the failing test** `studioPersistence.test.ts`, using the db mock pattern from `src/kvPersistedOverlays.test.ts` (`vi.hoisted` query fn, `vi.mock('./db.js', ...)`, env set before a dynamic import, `query.mockReset()` in `beforeEach`). Cases:
  - `ignores documents without the studio prefix` (`onLoadDocument` for `kv_file:x` and `deck-1` → `undefined`, no query)
  - `opens an empty doc without writing` (query returns `{ rows: [] }` → document returned, exactly one query (the SELECT), no INSERT)
  - `loads from the latest snapshot onward` (two rows: a snapshot encoding `{ nodes.n1 }` and an update encoding `{ nodes.n2 }` → both keys present; the SQL text references `studio_yjs_updates` and `is_snapshot = true`)
  - `appends each update as a non-snapshot row` (after `afterLoadDocument`, a local `doc.transact` produces one INSERT with params `[fileId, Buffer]` and `false` in the SQL)
  - `writes a snapshot once the update threshold is reached` (set `SNAPSHOT_UPDATE_THRESHOLD=2` in env, two updates, `onStoreDocument` → one INSERT with `is_snapshot` true)
  - `DeckPersistence ignores studio docs` (import `DeckPersistence`; `onLoadDocument({ documentName: 'studio:x', … })` → `undefined`, no query)
  - `onDisconnect does not materialize studio docs`: extract the routing in `index.ts` `onDisconnect` into `export function disconnectRoute(documentName: string): 'none' | 'kv' | 'deck'` in a new `collab/src/disconnectRoute.ts` (presence-only and `studio:` → `'none'`, `kv_file:` → `'kv'`, else `'deck'`), have `onDisconnect` switch on it, and test it with `it.each` (so the test does not import the server module).
- [ ] **Step 2: Run, see fail.** `npm test -- src/studioPersistence.test.ts`
- [ ] **Step 3: Implement `studioPersistence.ts`, `disconnectRoute.ts`, and the guard and index changes.**
- [ ] **Step 4: Run the full suite and the type check.** `npm test` → all pass; `npm run typecheck` → no errors; `npm run build` → succeeds.
- [ ] **Step 5: Commit** `feat(collab): persist studio canvas docs in studio_yjs_updates`

---

### Task 3: End-to-end smoke against local api

Depends on the api plan (Tasks 3 and 5 migrated and served on :9191).

- [ ] **Step 1:** In `api/`, run the new migrations against the dev DB (`TELESCOPE_ENABLED=false php artisan migrate`), then `php artisan optimize:clear && php artisan optimize`.
- [ ] **Step 2:** Start collab locally (`npm run dev`) with `API_BASE_URL=http://localhost:9191/api` and the same `X_INTERNAL_TOKEN` as api's `API_INTERNAL_TOKEN`.
- [ ] **Step 3:** Run `node scripts/verify-e2e.mjs` if it can target a document name; otherwise connect a `HocuspocusProvider` from a short script to `studio:<a real studio-canvas file id>` with a valid JWT, set `doc.getMap('nodes').set('probe', new Y.Map())`, disconnect, reconnect, and confirm `probe` is back. Expected: one or more rows in `studio_yjs_updates` for that file; zero new rows in `kv_yjs_updates` and `deck_yjs_updates`.
- [ ] **Step 4:** Record the result in `api/docs/tracks/studio-canvas.track.md` (session log). No commit in collab for this task.
