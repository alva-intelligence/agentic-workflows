# Studio Run Engine P1 — collab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** api can read a Studio doc and write run facts into it, live for every connected tab.

**Architecture:** Two internal routes on the Hocuspocus server, same pattern as KV (`kvHttp.ts` + `applyKvOps.ts` + `readKvDocument.ts`): `internalTokenOk`, zod `.strict()`, `openDirectConnection("studio:"+id, {internal:true})`, one `doc.transact(…, SERVER_WRITE_ORIGIN)`, `disconnect()` in `finally`. `StudioPersistence` logs the write automatically.

**Tech Stack:** Node, `@hocuspocus/server` 2.15.3, yjs, zod, vitest.

**Spec:** `docs/superpowers/specs/2026-10-21-studio-run-engine-p1-design.md`. **Contracts:** `docs/superpowers/plans/2026-10-21-studio-run-engine-p1-contracts.md` (C1, C6 binding).

## Global Constraints

- Repo `collab/`, branch `feature/daffa/vc-studio-canvas`. Never push. Commits `feat(collab): …` + `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Tests: `npm test` (vitest).
- Error bodies are `{ code }` only (`node_missing`, `invalid_body`, `unauthorized`); never echo exception text.
- Map names `runFacts` and `nodeVersions` exactly as C1; values are plain JSON (no nested Y types).

## Review Focus

1. A run-facts write to a doc no tab has open → persisted and seen on next open (direct connection loads via `StudioPersistence`).
2. The same version posted twice (api retry) → appended once.
3. A write for a node deleted moments ago → `409 node_missing`, nothing written.
4. A fact body with an unknown key or a wrong `state` → 422, nothing written.
5. Document read of a fresh, never-edited doc → `{nodes:[],wires:[],runFacts:{},nodeVersions:{}}`, not 500.

---

### Task 1: Studio document read + run-facts write routes

**Files:**
- Create: `src/studioHttp.ts`, `src/studioRunFacts.ts`, `src/readStudioDocument.ts`, `src/studioHttp.test.ts`, `src/studioRunFacts.test.ts`
- Modify: `src/routes.ts` (+ `routes.test.ts`), `src/index.ts` (dispatch the two kinds)

**Interfaces:**
- `routes.ts`: `STUDIO_DOCUMENT = /^\/internal\/studio-files\/([^/]+)\/document$/` (GET) → `{ kind: 'read_studio_document'; fileId }`; `STUDIO_RUN_FACTS = /^\/internal\/studio-files\/([^/]+)\/run-facts$/` (POST) → `{ kind: 'write_studio_run_facts'; fileId }`.
- `readStudioDocument(hocuspocus: Hocuspocus, fileId: string): Promise<StudioDocumentJson>` — `{ nodes, wires, runFacts, nodeVersions }` (C6), `nodes`/`wires` as the core's records (`nodes` map values `toJSON()`).
- `studioRunFactsBody` zod schema (C6 body, `RunFact` and `NodeVersionFact` per C1, `.strict()` at every level; `output` validated as `kind ∈ {text_list, brief}` + `z.record(z.unknown())` for the rest).
- `writeStudioRunFacts(hocuspocus, fileId, body): Promise<{ ok: true } | { code: 'node_missing' }>` — inside one `doc.transact(fn, SERVER_WRITE_ORIGIN)`: node absent from `nodes` → return `node_missing` without writing; else `runFacts.set(node_id, fact)`; if `version` and no entry with its `id` in `nodeVersions.get(node_id) ?? []` → set the array with it appended (sorted by `n`).
- `handleStudioRoute(req, res, route, deps)` in `studioHttp.ts`: token check (`internalTokenOk`) → 401 `{code:'unauthorized'}`; body parse → 422 `{code:'invalid_body'}`; 409/200 per result.

- [ ] **Step 1: Failing tests:** routes match both paths only for the right method; read of an empty doc returns the empty shape; write sets `runFacts[n1]` and appends version n=1; posting the same version twice leaves one entry; a second version n=2 appends in order; node missing → `node_missing` and `runFacts` unchanged; extra key in `fact` → 422; wrong token → 401; a connected client doc (second `Y.Doc` synced through a provider or via `Y.applyUpdate` of the server doc's update event) receives the change in ONE update event (one transaction).
- [ ] **Step 2: Run `npm test`, expect FAIL.**
- [ ] **Step 3: Implement** (mirror `kvHttp.ts` structure and its tests' harness).
- [ ] **Step 4: Run `npm test` — all green (existing deck/KV tests included).**
- [ ] **Step 5: Commit** `feat(collab): studio document read and run-facts write`.
