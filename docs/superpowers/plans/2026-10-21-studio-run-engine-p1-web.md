# Studio Run Engine P1 — web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In real Studio files, Text generator and File (brief) nodes run for real: Run sends intent, the UI shows the server's run facts live (queued, running, done, failed, Out of date, versions), errors show as short copy, and credits are the real balance.

**Architecture:** The core gains read-only access to the server-written `runFacts` / `nodeVersions` maps. A new `bindStudioRuns` (next to `bindNodeStudio`, same plain-TS rules) projects facts into the UI store and overrides the store's run actions for runnable node types; everything else keeps the prototype's mock, free. Input hashes are recomputed client-side for Out of date with the same canonical JSON as api.

**Tech Stack:** TypeScript, zustand, yjs, axios, `bun:test`.

**Spec:** `docs/superpowers/specs/2026-10-21-studio-run-engine-p1-design.md`. **Contracts:** `docs/superpowers/plans/2026-10-21-studio-run-engine-p1-contracts.md` (C0–C3 binding).

## Global Constraints

- Repo `web/`, branch `feature/daffa/vc-studio-canvas`. Never push. Commits `feat(web): …` + `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Tests `bun test <file>`; the prototype suite `bunx vitest run src/lib/node-studio src/store/node-studio src/components/node-studio` must stay green. No `mock.module` (process-global under bun); inject fakes. Use `within(document.body)`, not `screen`.
- `lib/studio/core` stays headless (yjs/zod/ulid only); `lib/studio/bridge` and the new `lib/studio/runs` are plain TS (lint rule: no React/components/hooks/xyflow/next; store imports type-only). Add `src/lib/studio/runs/**` to the bridge lint block.
- `/wireframes/node-studio` (mock store, no editor) must behave exactly as today.
- No raw error text in the UI: every failure renders copy from `runErrorCopy(code)`; unknown codes → the `generation_failed` copy.
- frndOS tokens and components for new UI (failed state, Retry); no new dark hex.
- PostHog events are part of the feature (Task 7 runs the `frndos-analytics-events` skill).

## Review Focus

1. Two tabs, one user starts a run, the other user's tab → sees queued/running/done live and has no Cancel.
2. A user edits a direction card, then steps ‹ › to another version and back → their edit is still there after a reload.
3. The api is down when Run is clicked → toast with `unavailable` copy, node unchanged, no stuck "Running…".
4. A mock node (Image) run in a real file → credits shown never drop.
5. Hash agreement: the same doc yields the same `input_hashes` as api (golden vectors + a resolver test on a doc with `{}` params).

---

### Task 1: Core read access to run facts; delete guard

**Files:** Create `src/lib/studio/core/runFacts.ts`. Modify `src/lib/studio/core/records.ts` (`createStudioDoc` adds `runFacts`, `nodeVersions` maps; `StudioYDoc` type), `src/lib/studio/core/editor.ts`, `src/lib/studio/core/index.ts`. Test `src/lib/studio/core/runFacts.test.ts`.

**Interfaces:**
- `runFacts.ts`: `RunFact`, `NodeVersionFact`, `TextGenOutput`, `BriefOutput`, `RunErrorCode` types exactly as C1/C2; `readRunFact(v: unknown): RunFact | null` and `readNodeVersions(v: unknown): NodeVersionFact[]` (zod-validated, invalid → null/[]).
- Editor additions: `getRunFact(nodeId): RunFact | null`, `listRunFacts(): Record<string, RunFact>`, `listNodeVersions(nodeId): NodeVersionFact[]`. No write API for these maps. The UndoManager does not track them.
- `deleteNodes(ids)` now returns `{ deleted: string[]; refused: string[] }`: ids whose fact state is `queued|running` are refused (not deleted, their wires kept).

- [ ] **Step 1: Failing tests:** facts written to `sdoc.doc.getMap("runFacts")` under a foreign origin are readable; an invalid fact reads as null; versions come back sorted by `n`; `deleteNodes` of a running node refuses it and keeps its wires; undo after a server fact write does not remove the fact.
- [ ] **Step 2: Run `bun test src/lib/studio/core`, expect FAIL.** **Step 3: Implement.** **Step 4: PASS (all core tests).**
- [ ] **Step 5: Commit** `feat(web): studio core reads server run facts`.

### Task 2: Run helpers — hashes, input resolution, error copy

**Files:** Create `src/lib/studio/runs/{canonicalJson.ts,resolveInputs.ts,runErrors.ts,index.ts}`, `src/lib/studio/runs/__fixtures__/input-hash-vectors.json` (byte-identical copy of the contracts fixture). Modify `eslint.config.mjs` (bridge lint block covers `src/lib/studio/runs/**`). Test `src/lib/studio/runs/{canonicalJson,resolveInputs,runErrors}.test.ts`.

**Interfaces:**
- `canonicalJson(v: unknown): string`; `sha256Hex(s: string): Promise<string>` (`crypto.subtle`).
- `resolveInputs(doc: StudioDoc /*UI doc*/, facts: { versions(nodeId): NodeVersionFact[] }, nodeId: string): { hashInputs: Record<string, unknown>; blocked: RunErrorCode[] }` — C3 rules (shown version = `node.data.shownVersion ?? newest`; edits from `data.itemsByVersion` / `data.briefFieldsByVersion`); `hashesOf(hashInputs): Promise<Record<string,string>>`.
- `staleKeys(current: Record<string,string>, version: Record<string,string>, kept: Record<string,string> | null): string[]` (keys whose hash differs from `kept ?? version`, plus added/removed keys).
- `staleReasonOf(keys: string[], labelOf: (nodeId) => string): string` — `settings` → "Settings changed after this was written"; `context:<id>`/`prompt:<id>` → "<label> changed after this was made"; several → first + " and N more".
- `runErrorCopy(code: string): string` — exact copy: `insufficient_credits` "Not enough credits for this run.", `inputs_missing` "Connect the inputs this node needs first.", `already_running` "This node is already running.", `generation_failed` "Couldn't generate this time. Credits refunded.", `timeout` "This took too long, so we stopped it. Credits refunded.", `cancelled` "Run cancelled. Credits refunded.", `not_allowed` "You can't run nodes in this file.", `not_found` "This node is no longer in the file.", `unavailable` "Studio can't run right now. Try again in a moment.", `unreadable_document` "We couldn't read any text in this file.", `file_too_large` "That file is over 25 MB.", `unsupported_file` "Studio reads PDF and Word (.docx) briefs.", `lark_not_connected` "Connect Lark to read this doc.", `lark_doc_not_accessible` "We can't open that Lark doc. Check that it's shared with you.", `live_objects_unsupported` "Live objects are coming soon.".

- [ ] **Step 1: Failing tests:** every golden vector's `canonical` and `sha256`; resolver: wired Text node → `context:<id>` = `{kind:"text", text}`; no context → blocked `inputs_missing`; File source without a version → blocked; File shown v2 with field edits uses the edited fields; live object source → `live_objects_unsupported`; a node with `data: {}` gives the hash listed for the same input in the api resolver test (copy the expected hex into the test); `staleKeys` with kept hashes acknowledging the change → `[]`; unknown error code → generation_failed copy.
- [ ] **Step 2: FAIL. Step 3: Implement. Step 4: PASS.**
- [ ] **Step 5: Commit** `feat(web): studio run helpers — hashes, inputs, error copy`.

### Task 3: Run API client

**Files:** Create `src/lib/studio/runs/api.ts` (types only: `StudioRunApi`), `src/services/studioCanvasRuns.ts`. Test `src/services/studioCanvasRuns.test.ts`.

**Interfaces:**
- `interface StudioRunApi { start(nodeId: string, idempotencyKey: string): Promise<RunDto>; cancel(runId: string): Promise<RunDto>; quote(nodeId: string): Promise<{ price: number; blocked: { code: RunErrorCode; port?: string }[] }>; upload(file: File): Promise<{ uploadId: string; fileName: string; mime: string }>; }` and `class StudioRunError extends Error { code: RunErrorCode }`.
- `createStudioRunApi(fileId: string, http = axiosInstance): StudioRunApi` — C2 routes; any non-2xx → `StudioRunError(body.error.code ?? "unavailable")`; network error → `unavailable`. Never surfaces `body.error.message` beyond logging.

- [ ] **Step 1: Failing tests** with an injected fake `http` (no axios mock module): start posts `{node_id}` with `Idempotency-Key`; 402 body → `StudioRunError` code `insufficient_credits`; network error → `unavailable`; HTML 500 body → `unavailable`.
- [ ] **Step 2: FAIL. Step 3: Implement. Step 4: PASS.**
- [ ] **Step 5: Commit** `feat(web): studio run api client`.

### Task 4: Project run facts into the Studio UI

**Files:** Create `src/lib/studio/bridge/bindStudioRuns.ts`. Modify `src/lib/node-studio/types.ts` (`NodeRunState` adds `"failed"`; `NodeRun.progress: number | null`; `NodeRun.errorCode?: string`; `BriefSource` adds `"docx"`; `BriefData` adds `uploadId: string | null`, `larkUrl: string | null`), `src/lib/node-studio/pricing.ts` (`setRunPriceOverrides(p: Partial<Record<"textGen"|"file", number>> | null)` used by `nodePriceIn` for those types). Test `src/lib/studio/bridge/bindStudioRuns.test.ts`.

**Interfaces:**
- `bindStudioRuns(store: Store, editor: StudioEditor, api: StudioRunApi, opts: { userId: string; onRunSettled?: () => void }): StudioRunsBinding` with `{ setBalance(credits: number): void; unbind(): void }`.
- Projection (on every editor update, after `bindNodeStudio`'s own projection, via a microtask): for each `textGen`/`file` node with a fact or versions: `runs[id] = { state, progress: null, versions: <NodeVersionFact → NodeVersion {id, n, createdAt, output: {kind:"text", count} | brief, price}>, viewIndex: <shown n - 1>, staleReason, staleKind?, spent, errorCode }`; `state` = fact state, except `done` → `outOfDate` when `staleKeys` is non-empty (computed async; recompute on doc change, debounce 100 ms); textGen `textGens[id].items` = `data.itemsByVersion[shown] ?? <version items mapped to TextItem with stable hue by index>`; file `briefs[id]` = version output with `briefFieldsByVersion[shown]` edits. Never writes `runFacts`.
- Credits: the store's `credits` is the real balance; any store change to `credits` not made by the binding is reverted to the last `setBalance` value (mock runs are free).
- History: when a fact for a run started by `opts.userId` moves to `done` or `failed`, call `editor.clearHistory()` and set the store's `past/future` to `[]` (credits cannot be taken back — spec §5; the store's own `tick` no longer runs for real nodes). Also call `opts.onRunSettled?.()` so the app can refresh the balance.
- `store.tasks`: one `Task` per fact with `state ∈ {queued, running}` and `started_by === opts.userId` (`id = run_id`, title "Run <label>", `status: "running"`); finished ones drop to `done`/`cancelled` like the prototype.

- [ ] **Step 1: Failing tests** (real store + real editor + facts written to the Y maps under a foreign origin, as in `bindNodeStudio.test.ts`): a `running` fact → `runs[id].state === "running"`; `done` + version 1 → items shown, `spent` set; v1 and v2 with `shownVersion: 1` → v1 items; `itemsByVersion["1"]` overrides v1 items; changing the wired Text node's text → `outOfDate` with reason "<label> changed after this was made"; `keptHashes` equal to current → back to `done`; `failed` fact with `error_code: "timeout"` → `state: "failed"`, `errorCode: "timeout"`; a mock run of an Image node in the store leaves `credits` at the `setBalance` value; a fact started by another user → no Task; my run moving `running → done` clears editor history (`canUndo() === false`) and calls `onRunSettled` once; another user's run settling does neither; unbind restores everything.
- [ ] **Step 2: FAIL. Step 3: Implement. Step 4: PASS** + the prototype vitest suite (types changed).
- [ ] **Step 5: Commit** `feat(web): project studio run facts into the UI`.

### Task 5: Run actions in real files

**Files:** Modify `src/lib/studio/bridge/bindStudioRuns.ts`, `src/store/node-studio/useNodeStudioStore.ts` (`startReadingBrief(id, source, fileName, opts?: { file?: File; larkUrl?: string })`; `dropFiles` passes the `File`; mock ignores `opts`), `src/components/node-studio/nodes/FileNode.tsx` (passes the picked `File` / the Lark link it already collects; accepts `.docx`). Test: extend `bindStudioRuns.test.ts`.

**Interfaces (binding overrides, restored on unbind):**
- `startRun(scope, nodeId)`: runnable node + scope `node` (and `Update`/`Retry`, which call it) → `api.start(nodeId, ulid())`; `StudioRunError` → toast `runErrorCopy(code)` (warning), node untouched. Runnable node in a multi-node scope (`from`, `all`, selected, section) → the scope runs its mock nodes only and toasts "Text generator and brief run one node at a time for now" once. Non-runnable node → original mock action.
- `cancelTask(taskId)`: a real run task → `api.cancel(taskId)`; errors → toast copy. Mock tasks → original.
- `startReadingBrief(id, source, fileName, opts)`: `pdf`/`docx` with `opts.file` → `api.upload(file)` → write `briefs[id] = {…, source, uploadId, fileName, reading: false}` through the store (synced edit) → flush → `api.start(id, ulid())`; `lark` → write `larkUrl` → start; `typed` → start (text already in `briefs[id].text`). Upload errors → toast copy, no run.
- `keepVersion(id)` → node `data.keptHashes` = current hashes. `stepVersion(id, delta)` → node `data.shownVersion` = clamp(n + delta). Card edits (`editTextItem`, `removeTextItem`, `addTextItem`) → also write `data.itemsByVersion[shown]` = resulting items; brief field edits (`editBriefField`) → `data.briefFieldsByVersion[shown]`.
- `removeNodes`/`removeSelection`: ids with fact state `queued|running` are dropped from the call and toast "Running · cancel it first"; the rest are removed.
- Prices: on bind and when a runnable type first appears, `api.quote(<a node of that type>)` → `setRunPriceOverrides`; failure leaves the prototype estimate.

- [ ] **Step 1: Failing tests** (fake `StudioRunApi` recording calls): Run on a textGen calls `start` once with a ulid key; `insufficient_credits` rejection → toast with the exact copy and `runs[id].state` unchanged; Run on an Image node → mock path, `start` not called; "Run from here" over [textGen, image] → only image mocked + the one-time toast; cancel of my running task → `api.cancel(runId)`; pdf brief with a `File` → `upload` then `start`, `briefs[id].uploadId` set in the editor record; Lark link → `larkUrl` in the record then `start`; delete of a running node → refused + toast, a done node deleted; `stepVersion(+1)` → `data.shownVersion` in the editor record; editing a card after stepping to v1 writes `itemsByVersion["1"]`.
- [ ] **Step 2: FAIL. Step 3: Implement. Step 4: PASS** (+ prototype vitest suite, FileNode tests).
- [ ] **Step 5: Commit** `feat(web): real run, cancel and brief reading in studio files`.

### Task 6: Failed state UI, real balance, app wiring

**Files:** Modify `src/components/node-studio/canvas/NodeFrame.tsx` (failed: border + copy + "Retry · N cr" `Button`; `progress === null` → "Running" with an indeterminate bar), `src/components/node-studio/nodes/TextGenNode.tsx` and `FileNode.tsx` (failed body keeps the previous version visible), `src/components/node-studio/NodeStudioApp.tsx` (create `createStudioRunApi(fileId)` + `bindStudioRuns(..., { userId })` when `editor` is set; `setBalance(mainCredits)` from `useEffectiveCredits()`; `onRunSettled` refreshes the balance the way the app already does after spending — `usePusherCredits` / the auth user refresh, whichever exists; find it, don't add a new endpoint), `src/components/studio/canvas/StudioCanvasView.tsx` (pass `fileId`). Test `src/components/node-studio/canvas/NodeFrame.failed.test.tsx` (bun), update `src/components/studio/canvas/StudioCanvasView.test.tsx`.

- [ ] **Step 1: Failing tests:** a node with `runs[id] = {state:"failed", errorCode:"timeout"}` renders "This took too long, so we stopped it. Credits refunded." and a "Retry · 2 cr" button that calls `startRun("node", id)`; no element contains the text "Exception", "Error:" or "500"; `progress: null` renders "Running" without a %; in the view test, `setBalance` is called with the auth user's credits and the top bar shows them.
- [ ] **Step 2: FAIL. Step 3: Implement. Step 4: PASS.**
- [ ] **Step 5: Commit** `feat(web): studio failed state, real balance, run wiring`.

### Task 7: Analytics and docs

**Files:** Modify `src/lib/analytics/studio-canvas-events.ts`, `docs/analytics/studio-canvas-events.md`, `docs/prd/studio-canvas.md` (web service PRD: P1 tasks), `docs/tracks/studio-canvas.track.md`. Test `src/lib/analytics/studio-canvas-events.test.ts` (if the file has tests; else create).

- [ ] **Step 1:** Invoke the `frndos-analytics-events` skill and follow it for: `studio_canvas_run_requested` (`node_type`, `preset?`, `count?`, `price`), `studio_canvas_run_succeeded` (`node_type`, `duration_ms`, `version_n`), `studio_canvas_run_failed` (`node_type`, `error_code`), `studio_canvas_run_cancelled` (`node_type`), `studio_canvas_version_stepped` (`node_type`, `version_n`), `studio_canvas_out_of_date_kept` (`node_type`). Succeeded/failed fire once per run, only in the starter's tab (fact `started_by === userId`, transition observed). Reconcile with `node-studio-events` (the unused `trackStudioCanvasNodeCreated`: emit it from the bridge on a local node create, or remove it — decide in the skill's review and record it in the events doc).
- [ ] **Step 2: Failing tests** for each tracker's payload; **Step 3: implement + wire** in `bindStudioRuns`; **Step 4: PASS.** Do not write Lark taxonomy rows without asking.
- [ ] **Step 5: Update PRD + track (dated session-log entry), run** `bun test src/lib/studio src/components/studio/canvas src/components/node-studio/canvas/NodeFrame.failed.test.tsx` and the prototype vitest suite — all green. **Commit** `feat(web): studio run analytics and docs`.
