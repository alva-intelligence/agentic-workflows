# Studio Canvas Stage A — Rafly's prototype UI on the real core

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (chosen: native) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The real Studio route (`/studio/canvas/[file_id]`, brand twin) renders Rafly's prototype UI (`components/node-studio`, merged at `e529c0367`), with the document persisted and shared through our headless core + Yjs + collab instead of the prototype's mock-only store.

**Architecture:** A two-way bridge (strangler pattern). The prototype's zustand store stays the UI's view-model with all its actions. In real mode, a binding (a) diffs every store document change into `StudioEditor` commands (validated, undoable, synced over Yjs) and (b) projects editor/Yjs changes back into the store. Per-node domain data (texts, briefs, text generators, images, uploads, artboards, size sets, motion, live objects) travels generically in `NodeRecord.params`. Runs, tasks and credits stay local mock until P1. Undo/redo in real mode is the editor's.

**Tech Stack:** TypeScript, zustand (prototype store), `@xyflow/react` 12, yjs, `bun:test`.

**Spec:** `frnd/docs/prd/studio-canvas.md` + decision q11 in `.workflow-state.json` (follow Rafly's prototype; xyflow is the canvas adapter; core stays the source of truth; hybrid naming). Prototype docs: `web/plans/studio-prototype/README.md`, `REVIEW-NOTES.md`, `state-table.md`.

## Global Constraints

- Work in `web/` on `feature/daffa/vc-studio-canvas`. Never push.
- Hybrid naming: UI code stays in `components/node-studio`, `lib/node-studio`, `store/node-studio` (minimal diff to Rafly's branch). Real route + flag are ours: `/studio/canvas/[file_id]`, `/brands/[id]/studio/canvas/[file_id]`, `MAJOR_FEATURE_FLAGS.STUDIO_CANVAS`. Backend contracts unchanged (`studio-canvas`, `brand.studio.studio_canvas`, `studio:` docs, `v1/studio/canvas`).
- `/wireframes/node-studio?scenario=…` keeps running on the mock store, untouched (visual reference).
- Core stays headless; the bridge lives in `src/lib/studio/bridge/` (may import core, `lib/node-studio`, and the store types — never React).
- Every document write in real mode goes through `StudioEditor`. Selection, `dragging`, panel state, runs/tasks/credits never sync.
- Tests: `bun test <file>` (bun:test). Prototype's own vitest suite is run with `bunx vitest run src/lib/node-studio src/store/node-studio` (its README command) and must stay green.
- Commits: `feat(web): …` + `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. A drag (xyflow fires `onNodesChange` every frame) must become ONE editor write on drop, not 60 writes and 60 undo steps.
2. A collaborator's change arriving while the local user drags or types must not snap the local node back or eat keystrokes.
3. Echo: applying a local diff to the editor must not bounce back as a "remote" change that re-sets the store (infinite loop / flicker).
4. Prototype validation (`validateConnection`) and core `connect` must agree, or wires vanish after sync. A matrix test across every node kind pins it.
5. Undo in real mode must undo only local edits (editor), never restore a whole-document snapshot over collaborators' work.

---

### Task 1: Core — prototype port types and data-dependent outputs

**Files:** Modify `web/src/lib/studio/core/values.ts`, `ports.ts`, `editor.ts`, `templates.ts`, `index.ts`. Test: `web/src/lib/studio/core/ports.prototype.test.ts`.

**Interfaces:**
- `VALUE_KINDS` adds the prototype `PortType`s: `context`, `board`, `layeredKv`, `video`, `audio`, `regions` (keeps the six existing kinds).
- `OutputPortSpec` gains optional `resolveKind?: (params: Record<string, unknown>) => ValueKind` — the output's kind for a given node's params (the prototype's `outputTypeOf`: an Upload holding a document outputs `text`). `editor.connect` and template preflight use `resolveKind(params) ?? kind`.

- [ ] Failing tests: new kinds listed; an output with `resolveKind` connects by the resolved kind (upload-with-document → a text-only port connects; without document → rejected `kind_mismatch`).
- [ ] Implement; run `bun test src/lib/studio/core` (all green), commit.

### Task 2: Core node types from the prototype's NODE_SPECS

**Files:** Create `web/src/lib/studio/bridge/nodeStudioTypes.ts`. Test: `web/src/lib/studio/bridge/nodeStudioTypes.test.ts`.

**Interfaces:**
- `registerNodeStudioTypes(registry: NodeRegistry): void` — one `defineNodeType` per `SpecKey` of `NODE_SPECS` (`lib/node-studio/ports.ts`): `type` = the SpecKey (edit kinds keep their own keys), `version: 1`, inputs from `PortDef` (`accepts`, `max`), one output from `spec.output` (`id: "out"`, its `type`; Upload gets `resolveKind: (p) => (p.data as {document?: unknown})?.document ? "text" : "image"`), `params: z.record(z.unknown())`, `defaultParams: {}`, `defaultSize` from the spec (or 240×160).
- `bridgeNodeType(node: DocNode): string` — the core type for a prototype node (`edit` nodes map to `node.data.editKind`).

- [ ] Failing tests: every SpecKey registers; **agreement matrix** — for every (source kind, target kind, target port) the prototype's `validateConnection` (ignoring its `replaces` case) and core `connect` give the same ok/reject on a fresh doc.
- [ ] Implement; run; commit.

### Task 3: Pure projection and diff

**Files:** Create `web/src/lib/studio/bridge/projection.ts`. Test: `projection.test.ts`.

**Interfaces:**
- `DOMAIN_KEYS = ["texts","briefs","textGens","images","videos","uploads","artboards","sizeSets","motion","liveObjects"] as const` (per-node maps keyed by node id).
- `docToRecords(doc: StudioDoc): { nodes: NodeRecord[]; wires: WireRecord[] }` — `NodeRecord.params = { data, domain }` where `data` is the xyflow `data` minus `size`, and `domain[k] = doc[k][node.id]` for each present key; `x/y` = `position` (relative for children), `w/h` = `data.size` or default, `sectionId` = `parentId ?? null`. Wire id = edge id; `from = {source,"out"}`, `to = {target, targetHandle}`.
- `recordsToDoc(nodes, wires, prev: StudioDoc): Partial<StudioDoc>` — inverse; keeps `prev`'s local-only fields per node (`selected`, `dragging`, z-order from `prev.nodes` order with new nodes appended), and leaves `runs`, `credits` untouched.
- `diffDocs(before: StudioDoc, after: StudioDoc): BridgeOp[]` where `BridgeOp = {op:"create", rec} | {op:"delete", ids} | {op:"move", id, x, y} | {op:"resize", id, w, h} | {op:"params", id, params} | {op:"section", id, sectionId} | {op:"connect", wire} | {op:"disconnect", id}`. Nodes with `dragging: true` in `after` produce no `move`. Selection changes produce nothing.

- [ ] Failing tests: round trip doc→records→doc is identity on the synced fields; diff of an add / delete / move / resize / text edit / wire swap yields exactly the expected ops; a dragging node yields no move; selection-only change yields `[]`; runs-only change yields `[]`.
- [ ] Implement; run; commit.

### Task 4: The binding

**Files:** Create `web/src/lib/studio/bridge/bindNodeStudio.ts`. Test: `bindNodeStudio.test.ts` (real `useNodeStudioStore` + real editor on a fresh doc).

**Interfaces:**
- `bindNodeStudio(store: typeof useNodeStudioStore, editor: StudioEditor, opts?: { flushMs?: number }): () => void` (returns unbind):
  - On bind: `store.getState().initFromScenario("empty")`, then project the editor's current records into the store.
  - Store → editor: `store.subscribe` keeps the last synced doc; changes are coalesced and flushed after `flushMs` (default 120) inside ONE `editor.transact` (one undo step per flush). A node still `dragging` defers its move to the flush after drag end.
  - Editor → store: `editor.subscribe` (remote and local) re-projects with `recordsToDoc`; skipped while a local flush is being applied (echo guard); a node currently `dragging` keeps its local position.
  - Undo: replaces the store's `undo`/`redo` actions with `editor.undo()/redo()`, and keeps `past`/`future` lengths mirroring `editor.canUndo()/canRedo()` so `selectCanUndo/Redo` work.
  - Unbind restores the original actions and unsubscribes.

- [ ] Failing tests: `addNode("prompt", …)` via the store creates one editor record after flush; typing via `setText` lands in `params.domain.texts`; a node drag (onNodesChange with `dragging:true` ×10 then `false`) produces one `moveNode` and one undo step; a remote Yjs update (second doc) adding a node appears in the store; store `undo()` undoes the last local flush and not a remote change; no update loop (editor update count stays bounded after a single store edit).
- [ ] Implement; run; commit.

### Task 5: Real route renders the prototype

**Files:** Modify `components/node-studio/NodeStudioApp.tsx` (optional `binding?: { editor: StudioEditor }` and `syncStatus` / `fileName` props), `components/node-studio/shell/TopBar.tsx` (file name + "Not syncing"/"View only" chip from props/store), `components/studio/canvas/StudioCanvasView.tsx` (render `NodeStudioApp` with the binding instead of our Fabric surface). Test: `StudioCanvasView.test.tsx` (update).

- [ ] Failing tests: view renders the prototype shell (`EmptyStart` "what are we making today?") once ready; Not syncing shown offline; a node added through the store reaches the editor.
- [ ] Implement; verify `/studio/canvas/new` in the browser; commit.

### Task 6: Remove the superseded P0 surface

Delete the Fabric/DOM surface replaced by the prototype: `components/studio/canvas/{StudioCanvas,NodeChrome,StickyNote,StudioToolbar,StudioTopBar,useStudioKeyboard,connectErrorCopy,UnknownNodeCard,NodeCards.test,StudioCanvas.test}`, `lib/studio/{nodes,ui,plugins*,render}` and their tests, and the boundary-test cases that only exist for `lib/studio/nodes`. Keep: core, sync, hooks, gate, `StudioCanvasNew`, `StudioCanvasPage/View`, analytics. Update `eslint.config.mjs` nodes rule only if its folder is gone.

- [ ] `bun test src/lib/studio src/components/studio/canvas src/hooks/useStudioYDoc.test.tsx` green; lint clean; commit.

### Task 7: Tokens for the prototype palette

**Files:** Modify `components/node-studio/node-studio.css` (`--ns-*` variables), `lib/node-studio/ports.ts` (`PORT_COLORS` stays: categorical data colours, documented as such).

- [ ] Map each `--ns-*` surface/text/line variable to the closest frndOS token variable (`--surface-*`, `--text-*`, `--border-*`) for dark and `[data-theme="light"]`, keep categorical accents; screenshot Midnight/Aurora/Daylight before/after on `/wireframes/node-studio?scenario=master-done`; commit.

## Done when

All new bun tests and the prototype vitest suite pass; `/studio/canvas/new` shows the prototype shell, nodes persist across reload and appear live in a second tab; `/wireframes/node-studio` scenarios still work.
