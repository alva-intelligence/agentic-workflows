# Studio Canvas P0 — Web Headless Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the engine-agnostic Studio graph core (`web/src/lib/studio/core`): versioned records on a Y.Doc, typed ports, a node-type registry, a tool registry, one editor command API with undo, document migrations and templates, plus lint rules that keep the core free of nodes, renderers and React.

**Architecture:** The core is plain TypeScript over `yjs`. No React, no Fabric, no DOM. Every mutation goes through `StudioEditor`, which validates, writes inside one `Y.transact` with a local origin, and is undone by a `Y.UndoManager` that tracks only that origin. Node types are data (`defineNodeType`) registered at runtime; the core never imports a node.

**Tech Stack:** TypeScript, `yjs ^13`, `zod ^3.24.2`, `ulid ^3.0.1`, `bun test` (`import { describe, it, expect } from "bun:test"`), ESLint flat config.

**Spec:** `frnd/docs/prd/studio-canvas.md` (FR-1…FR-7, NFR-1, NFR-2, AC-1…AC-4) and `web/docs/prd/studio-canvas.md` (TASK-2…TASK-8, TASK-13). Decision record: `.workflow-state.json` → `features["studio-canvas"].brainstorming`.

**Sibling plans (same batch):** `2026-10-21-studio-canvas-p0-web-surface.md` (consumes this core), `2026-10-21-studio-canvas-p0-api.md`, `2026-10-21-studio-canvas-p0-collab.md`.

## Global Constraints

- Work in `web/` on branch `feature/daffa/vc-studio-canvas`. Never commit to `develop`. Never push.
- `web/src/lib/studio/core/**` imports only `yjs`, `zod`, `ulid` and other files inside `core/`. No `react`, `react-dom`, `fabric`, `@/components/*`, `@/lib/studio/nodes/*`, `@/lib/studio/render/*`, `@/lib/studio/ui/*`, `@/lib/studio/sync/*`.
- Consumers import the core only through `@/lib/studio/core` (the `index.ts` barrel).
- Ids: `ulid()` from `ulid` for every record id.
- Value kinds are exactly `text | list | document | image | composition | size_set` (FR-2).
- Context-style input ports declare their own `max` (Context = 4, FR-2).
- `document` and `composition` may be read as `text` (FR-2 coercion). No other coercion in P0.
- Presets and templates are data, never code (FR-7).
- Run, pricing execution, staleness and fan-out are P1/P3 — do not build them here. `estimateCost` is declared on the type (FR-3) but nothing calls it in P0.
- Tests: `bun test <path>` from `web/`. Never `bunx vitest`. Never `bun test` on a whole large directory outside `src/lib/studio` (memory blow-up lesson). There is no type gate; run `bunx tsc --noEmit -p . 2>&1 | grep "src/lib/studio"` and expect no lines.
- Lint: `bunx eslint src/lib/studio` must be clean.
- Commit messages: `feat(web): …` ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. A file contains a node whose type is not registered (plugin removed or renamed): the file must still open, the node must be kept untouched (never deleted), and its wires preserved. → Task 5 test `keeps unknown node types untouched`.
2. A file was saved by a newer client (`typeVersion` higher than the registered `version`): the core must not downgrade or rewrite its params. → Task 5 test `never downgrades a node from a newer client`.
3. A collaborator's change arrives while the local user has undo history: local undo must revert only local edits. → Task 4 test `undo ignores remote changes`.
4. A fifth wire into a Context port (max 4), a wire that closes a cycle, or a duplicate wire: rejected with a named reason and nothing written. → Task 4 tests `rejects connect when port is full`, `rejects a cycle`, `rejects a duplicate wire`.
5. A template where one later step is invalid: nothing from the template is written, and a valid template is one undo step. → Task 6 tests `writes nothing when any template step is invalid`, `a template is a single undo step`.

---

## File Structure

| File | Responsibility |
|---|---|
| `web/src/lib/studio/core/result.ts` | `Result<T, E>` type + `ok`/`err` helpers |
| `web/src/lib/studio/core/values.ts` | `ValueKind`, `VALUE_KINDS`, `canReadAs` coercion |
| `web/src/lib/studio/core/ports.ts` | `InputPortSpec`, `OutputPortSpec`, `portAccepts` |
| `web/src/lib/studio/core/records.ts` | Record types, Y.Doc topology `createStudioDoc`, read/write helpers |
| `web/src/lib/studio/core/registry.ts` | `defineNodeType`, `createNodeRegistry`, `Preset` |
| `web/src/lib/studio/core/graph.ts` | `wouldCreateCycle` |
| `web/src/lib/studio/core/editor.ts` | `createStudioEditor`, `StudioEditor`, `STUDIO_ORIGIN_LOCAL` |
| `web/src/lib/studio/core/migrations.ts` | `migrateStudioDoc` |
| `web/src/lib/studio/core/templates.ts` | `StudioTemplate`, `instantiateTemplate` |
| `web/src/lib/studio/core/tools.ts` | `ToolDefinition`, `createToolRegistry`, `DEFAULT_STUDIO_TOOLS` |
| `web/src/lib/studio/core/index.ts` | Public barrel (the only import path for consumers) |
| `web/eslint.config.mjs` | Boundary rules for `lib/studio/**` |

Tests sit next to each file as `<name>.test.ts`.

---

### Task 1: Values, ports and the Result type

**Files:**
- Create: `web/src/lib/studio/core/result.ts`, `web/src/lib/studio/core/values.ts`, `web/src/lib/studio/core/ports.ts`
- Test: `web/src/lib/studio/core/ports.test.ts`

**Interfaces:**
- Produces:
  - `type Result<T, E extends string> = { ok: true; value: T } | { ok: false; error: E; detail?: string }`; `ok<T>(value: T)`, `err<E extends string>(error: E, detail?: string)`.
  - `type ValueKind = "text" | "list" | "document" | "image" | "composition" | "size_set"`; `const VALUE_KINDS: readonly ValueKind[]`.
  - `canReadAs(produced: ValueKind, accepted: ValueKind): boolean` — true when equal, or when `accepted === "text"` and `produced` is `"document"` or `"composition"`.
  - `interface InputPortSpec { id: string; label: string; accepts: readonly ValueKind[]; max: number }` (`max >= 1`).
  - `interface OutputPortSpec { id: string; label: string; kind: ValueKind }`.
  - `portAccepts(input: InputPortSpec, producedKind: ValueKind): boolean` — some `accepts` entry satisfies `canReadAs(producedKind, entry)`.

- [ ] **Step 1: Write the failing test** `ports.test.ts`

```ts
import { describe, it, expect } from "bun:test";
import { canReadAs, VALUE_KINDS } from "./values";
import { portAccepts, type InputPortSpec } from "./ports";

const context: InputPortSpec = { id: "context", label: "Context", accepts: ["text"], max: 4 };
const references: InputPortSpec = { id: "references", label: "References", accepts: ["image"], max: 4 };

describe("value coercion", () => {
  it("lists exactly the six value kinds", () => {
    expect([...VALUE_KINDS].sort()).toEqual(["composition", "document", "image", "list", "size_set", "text"]);
  });
  it("reads document and composition as text", () => {
    expect(canReadAs("document", "text")).toBe(true);
    expect(canReadAs("composition", "text")).toBe(true);
  });
  it("does not read list or image as text", () => {
    expect(canReadAs("list", "text")).toBe(false);
    expect(canReadAs("image", "text")).toBe(false);
  });
  it("never coerces away from text", () => {
    expect(canReadAs("text", "document")).toBe(false);
  });
});

describe("portAccepts", () => {
  it("accepts a document on a text Context port", () => {
    expect(portAccepts(context, "document")).toBe(true);
  });
  it("rejects text on an image References port", () => {
    expect(portAccepts(references, "text")).toBe(false);
  });
});
```

- [ ] **Step 2: Run it and see it fail**
  Run: `bun test src/lib/studio/core/ports.test.ts` — Expected: FAIL, cannot resolve `./values`.

- [ ] **Step 3: Implement the three files with the signatures above.**

- [ ] **Step 4: Run it and see it pass** — same command, Expected: 7 pass.

- [ ] **Step 5: Commit** `git add src/lib/studio/core && git commit -m "feat(web): studio core value kinds and typed ports"`

---

### Task 2: Records and the Y.Doc topology

**Files:**
- Create: `web/src/lib/studio/core/records.ts`
- Test: `web/src/lib/studio/core/records.test.ts`

**Interfaces:**
- Consumes: none.
- Produces:
  - `const CORE_SCHEMA_VERSION = 1`.
  - `interface NodeRecord { id: string; type: string; typeVersion: number; x: number; y: number; w: number; h: number; name: string | null; sectionId: string | null; params: Record<string, unknown> }`
  - `interface PortRef { nodeId: string; portId: string }`; `interface WireRecord { id: string; from: PortRef; to: PortRef }`
  - `interface SectionRecord { id: string; x: number; y: number; w: number; h: number; name: string }`
  - `interface StickyRecord { id: string; x: number; y: number; w: number; h: number; text: string }`
  - `interface StudioYDoc { doc: Y.Doc; meta: Y.Map<unknown>; nodes: Y.Map<Y.Map<unknown>>; wires: Y.Map<Y.Map<unknown>>; sections: Y.Map<Y.Map<unknown>>; stickies: Y.Map<Y.Map<unknown>> }`
  - `createStudioDoc(doc?: Y.Doc): StudioYDoc` — root maps named exactly `"meta"`, `"nodes"`, `"wires"`, `"sections"`, `"stickies"` (collab persists the doc opaquely; these names are the contract with later phases). Does not write `meta.schemaVersion` (a fresh doc and a not-yet-synced doc must look the same; `migrateStudioDoc` writes it).
  - `readNode(m: Y.Map<unknown>): NodeRecord`, `writeNode(target: Y.Map<Y.Map<unknown>>, rec: NodeRecord): void`, and the same `read*/write*` pair for `Wire`, `Section`, `Sticky`.
  - Storage rule: each record is a `Y.Map`; `params` is stored as one nested `Y.Map` (one key per param) so two people editing different params of one node merge; `from`/`to` are plain objects (wires are immutable once created).

- [ ] **Step 1: Write the failing test** `records.test.ts`

```ts
import { describe, it, expect } from "bun:test";
import * as Y from "yjs";
import { createStudioDoc, writeNode, readNode, writeWire, readWire, type NodeRecord } from "./records";

const node: NodeRecord = { id: "n1", type: "text", typeVersion: 1, x: 10, y: 20, w: 220, h: 100, name: null, sectionId: null, params: { text: "hi" } };

describe("studio doc records", () => {
  it("uses the five named root maps", () => {
    const sd = createStudioDoc();
    expect(sd.doc.getMap("nodes")).toBe(sd.nodes);
    expect(sd.doc.getMap("wires")).toBe(sd.wires);
    expect(sd.doc.getMap("sections")).toBe(sd.sections);
    expect(sd.doc.getMap("stickies")).toBe(sd.stickies);
    expect(sd.doc.getMap("meta")).toBe(sd.meta);
  });
  it("round-trips a node with params as a nested Y.Map", () => {
    const sd = createStudioDoc();
    writeNode(sd.nodes, node);
    const m = sd.nodes.get("n1")!;
    expect(m.get("params")).toBeInstanceOf(Y.Map);
    expect(readNode(m)).toEqual(node);
  });
  it("merges concurrent edits to different params of one node", () => {
    const a = createStudioDoc(); writeNode(a.nodes, { ...node, params: { text: "x", tone: "warm" } });
    const b = createStudioDoc(); Y.applyUpdate(b.doc, Y.encodeStateAsUpdate(a.doc));
    (a.nodes.get("n1")!.get("params") as Y.Map<unknown>).set("text", "from-a");
    (b.nodes.get("n1")!.get("params") as Y.Map<unknown>).set("tone", "from-b");
    Y.applyUpdate(a.doc, Y.encodeStateAsUpdate(b.doc));
    expect(readNode(a.nodes.get("n1")!).params).toEqual({ text: "from-a", tone: "from-b" });
  });
  it("round-trips a wire", () => {
    const sd = createStudioDoc();
    const w = { id: "w1", from: { nodeId: "n1", portId: "out" }, to: { nodeId: "n2", portId: "context" } };
    writeWire(sd.wires, w);
    expect(readWire(sd.wires.get("w1")!)).toEqual(w);
  });
});
```

- [ ] **Step 2: Run and see it fail** — `bun test src/lib/studio/core/records.test.ts`, FAIL (module missing).
- [ ] **Step 3: Implement `records.ts`** with the signatures above.
- [ ] **Step 4: Run and see it pass** — 4 pass.
- [ ] **Step 5: Commit** `feat(web): studio core records on a Y.Doc`

---

### Task 3: Node-type registry and presets

**Files:**
- Create: `web/src/lib/studio/core/registry.ts`
- Test: `web/src/lib/studio/core/registry.test.ts`

**Interfaces:**
- Consumes: `InputPortSpec`, `OutputPortSpec` (Task 1).
- Produces:
  - `interface Preset<P> { id: string; label: string; params: Partial<P> }`
  - `interface NodeTypeDefinition<P extends Record<string, unknown>> { type: string; version: number; title: string; inputs: readonly InputPortSpec[]; outputs: readonly OutputPortSpec[]; params: z.ZodType<P>; defaultParams: P; defaultSize: { w: number; h: number }; presets?: readonly Preset<P>[]; estimateCost?: (params: P) => number | null; executor?: string; migrations?: Readonly<Record<number, (params: Record<string, unknown>) => Record<string, unknown>>> }`
    - `migrations[n]` upgrades params from version `n` to `n + 1`.
    - `executor`, when present, is exactly `` `${type}@${version}` `` (FR-3).
  - `defineNodeType<P>(def: NodeTypeDefinition<P>): NodeTypeDefinition<P>` — throws `Error` when: `type` is not `/^[a-z][a-z0-9_]*$/`; `version < 1`; port ids repeat within inputs or within outputs; an input `max < 1`; `executor` is set and differs from `` `${type}@${version}` ``; `defaultParams` fails `params.safeParse`; a version in `1 … version-1` has no `migrations` entry; a preset id repeats.
  - `interface NodeRegistry { register(def: NodeTypeDefinition<any>): void; get(type: string): NodeTypeDefinition<any> | undefined; list(): NodeTypeDefinition<any>[] }` — `register` throws on a duplicate `type`.
  - `createNodeRegistry(): NodeRegistry`.

- [ ] **Step 1: Write the failing test** `registry.test.ts` with these cases:

```ts
import { describe, it, expect } from "bun:test";
import { z } from "zod";
import { defineNodeType, createNodeRegistry } from "./registry";

const textDef = () => ({
  type: "text", version: 1, title: "Text",
  inputs: [], outputs: [{ id: "out", label: "Text", kind: "text" as const }],
  params: z.object({ text: z.string() }), defaultParams: { text: "" },
  defaultSize: { w: 220, h: 100 },
});

describe("defineNodeType", () => {
  it("accepts a valid definition", () => { expect(defineNodeType(textDef()).type).toBe("text"); });
  it("rejects an executor key that does not match type@version", () => {
    expect(() => defineNodeType({ ...textDef(), executor: "text@2" })).toThrow(/executor/);
  });
  it("rejects defaults that fail the params schema", () => {
    expect(() => defineNodeType({ ...textDef(), defaultParams: { text: 5 as unknown as string } })).toThrow(/defaultParams/);
  });
  it("requires a migration for every earlier version", () => {
    expect(() => defineNodeType({ ...textDef(), version: 3, migrations: { 1: (p) => p } })).toThrow(/migration.*2/);
  });
  it("rejects duplicate port ids", () => {
    expect(() => defineNodeType({ ...textDef(), outputs: [textDef().outputs[0], textDef().outputs[0]] })).toThrow(/port/);
  });
});

describe("node registry", () => {
  it("registers, gets and lists", () => {
    const r = createNodeRegistry(); r.register(defineNodeType(textDef()));
    expect(r.get("text")?.title).toBe("Text");
    expect(r.list().map((d) => d.type)).toEqual(["text"]);
  });
  it("throws on a duplicate type", () => {
    const r = createNodeRegistry(); r.register(defineNodeType(textDef()));
    expect(() => r.register(defineNodeType(textDef()))).toThrow(/text/);
  });
});
```

- [ ] **Step 2: Run, see fail.** `bun test src/lib/studio/core/registry.test.ts`
- [ ] **Step 3: Implement `registry.ts`.**
- [ ] **Step 4: Run, see 7 pass.**
- [ ] **Step 5: Commit** `feat(web): studio node-type registry`

---

### Task 4: Editor command API with validation and undo

**Files:**
- Create: `web/src/lib/studio/core/graph.ts`, `web/src/lib/studio/core/editor.ts`
- Test: `web/src/lib/studio/core/editor.test.ts`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces:
  - `wouldCreateCycle(wires: readonly WireRecord[], fromNodeId: string, toNodeId: string): boolean` — true when `toNodeId` can already reach `fromNodeId` along wires, or when they are equal.
  - `const STUDIO_ORIGIN_LOCAL: unique symbol`.
  - `type ConnectError = "unknown_node" | "unknown_type" | "unknown_port" | "kind_mismatch" | "port_full" | "cycle" | "duplicate"`.
  - `interface CreateNodeInput { type: string; x: number; y: number; params?: Record<string, unknown>; name?: string | null; sectionId?: string | null }`
  - `interface StudioEditor {`
    - `createNode(input: CreateNodeInput): Result<string, "unknown_type" | "invalid_params">` — merges `params` over `defaultParams`, validates with the type's schema, writes `typeVersion = def.version` and `defaultSize`.
    - `updateParams(nodeId: string, patch: Record<string, unknown>): Result<void, "unknown_node" | "unknown_type" | "invalid_params">` — validates the merged result; writes only changed keys.
    - `applyPreset(nodeId: string, presetId: string): Result<void, "unknown_node" | "unknown_type" | "unknown_preset" | "invalid_params">`
    - `moveNode(nodeId: string, x: number, y: number): Result<void, "unknown_node">`
    - `renameNode(nodeId: string, name: string | null): Result<void, "unknown_node">`
    - `deleteNodes(nodeIds: readonly string[]): void` — removes the nodes and every wire touching them, in one transaction.
    - `connect(from: PortRef, to: PortRef): Result<string, ConnectError>` — `from` must be an output port, `to` an input port; checks in this order: nodes exist, types registered, ports exist, `portAccepts`, duplicate (same from+to), `port_full` (count of wires into `to` ≥ `max`), `cycle`.
    - `disconnect(wireId: string): void`
    - `createSection(input: { x: number; y: number; w: number; h: number; name: string }): string`
    - `addSticky(input: { x: number; y: number; text: string }): string` — default size `{ w: 200, h: 140 }`.
    - `updateSticky(id: string, text: string): void`, `deleteSections(ids: readonly string[]): void`, `deleteStickies(ids: readonly string[]): void`
    - `transact(fn: () => void): void` — nests: inner editor calls join the outer transaction (one undo step).
    - `undo(): void; redo(): void; canUndo(): boolean; canRedo(): boolean`
    - `getNode(id: string): NodeRecord | undefined; listNodes(): NodeRecord[]; listWires(): WireRecord[]; listSections(): SectionRecord[]; listStickies(): StickyRecord[]; wiresInto(ref: PortRef): WireRecord[]`
    - `subscribe(listener: () => void): () => void` — fires after any doc change, local or remote.
    - `destroy(): void` — destroys the UndoManager and observers.
  - `}`
  - `createStudioEditor(opts: { sdoc: StudioYDoc; registry: NodeRegistry; newId?: () => string }): StudioEditor` — `newId` defaults to `ulid`. Every write is `sdoc.doc.transact(fn, STUDIO_ORIGIN_LOCAL)`. The UndoManager scope is `[nodes, wires, sections, stickies]` with `trackedOrigins: new Set([STUDIO_ORIGIN_LOCAL])` and `captureTimeout: 400`. `meta` is not in scope (migrations must not be undoable).
  - Rule: only one editor per `StudioYDoc` at a time (two UndoManagers on one doc conflict — same warning as `src/lib/kv/docUndo.ts`).

- [ ] **Step 1: Write the failing test** `editor.test.ts`. Fixture registry: `text@1` (output `out: text`), `textgen@1` (inputs `context: accepts [text], max 4`; output `out: list`), `image@1` (input `references: accepts [image], max 4`; output `out: image`). Ids from a counter (`n1`, `n2`, …). Cases (each asserts the exact result and the doc contents):
  - `creates a node with defaults merged and typeVersion set`
  - `rejects an unknown type` → `{ ok: false, error: "unknown_type" }`, `listNodes()` empty
  - `rejects params that fail the schema` → `invalid_params`, nothing written
  - `updateParams validates the merged params`
  - `connects text into a context port`
  - `rejects a kind mismatch` (text → `references`) → `kind_mismatch`
  - `rejects connect when port is full` (five text nodes into one `context`) → fifth returns `port_full`, `wiresInto` length 4
  - `rejects a duplicate wire` → `duplicate`
  - `rejects a cycle` (image A → image B → image A) → `cycle`
  - `deleting a node removes its wires`
  - `transact groups several commands into one undo step` (create two nodes + connect inside `transact`, one `undo()` → empty doc)
  - `undo ignores remote changes`: create node locally; apply a second `Y.Doc`'s update that adds node `r1` (origin ≠ local); `undo()` → `r1` still present, local node gone
  - `subscribe fires for local and remote changes`

- [ ] **Step 2: Run, see fail.** `bun test src/lib/studio/core/editor.test.ts`
- [ ] **Step 3: Implement `graph.ts` and `editor.ts`.** Validate fully before opening the transaction, so a rejected command never writes. Track nesting depth inside `transact`: only the outermost call runs `doc.transact`.
- [ ] **Step 4: Run, see 13 pass.**
- [ ] **Step 5: Commit** `feat(web): studio editor command api with undo`

---

### Task 5: Document migrations

**Files:**
- Create: `web/src/lib/studio/core/migrations.ts`
- Test: `web/src/lib/studio/core/migrations.test.ts`

**Interfaces:**
- Consumes: `StudioYDoc`, `readNode`, `NodeRegistry`, `CORE_SCHEMA_VERSION`.
- Produces:
  - `interface MigrationReport { migrated: string[]; unknownType: string[]; newerThanClient: string[] }` (node ids).
  - `migrateStudioDoc(sdoc: StudioYDoc, registry: NodeRegistry): MigrationReport` — call once after the doc has synced. In one transaction with origin `STUDIO_MIGRATION_ORIGIN` (a new exported symbol, untracked by undo): sets `meta.schemaVersion = CORE_SCHEMA_VERSION` when absent; for each node whose type is registered and `typeVersion < def.version`, applies `def.migrations[v]` for `v = typeVersion … def.version - 1`, writes the new params and `typeVersion`. Unknown types and newer versions are reported and left untouched. Idempotent.

- [ ] **Step 1: Write the failing test** `migrations.test.ts` — cases:
  - `upgrades params across two versions` (`note@3` with migrations `1: rename body→text`, `2: add tone "neutral"`; a stored `typeVersion 1` node `{ body: "x" }` becomes `typeVersion 3`, `{ text: "x", tone: "neutral" }`, report `migrated: ["n1"]`)
  - `keeps unknown node types untouched` (node type `legacy_thing` stays byte-identical; report `unknownType: ["n2"]`; its wire still exists)
  - `never downgrades a node from a newer client` (`typeVersion 5` vs registered 3 → unchanged; `newerThanClient: ["n3"]`)
  - `writes schemaVersion once and is idempotent` (second call returns empty arrays and changes nothing)
  - `migration writes are not undoable` (create an editor on the same doc, run the migration, `canUndo()` is false)

- [ ] **Step 2: Run, see fail.** `bun test src/lib/studio/core/migrations.test.ts`
- [ ] **Step 3: Implement `migrations.ts`.**
- [ ] **Step 4: Run, see 5 pass.**
- [ ] **Step 5: Commit** `feat(web): studio document migrations`

---

### Task 6: Templates

**Files:**
- Create: `web/src/lib/studio/core/templates.ts`
- Test: `web/src/lib/studio/core/templates.test.ts`

**Interfaces:**
- Consumes: `StudioEditor` (Task 4), `NodeRegistry`, `portAccepts`.
- Produces:
  - `interface StudioTemplate { id: string; name: string; version: 1; nodes: readonly { key: string; type: string; x: number; y: number; params?: Record<string, unknown>; presetId?: string; name?: string }[]; wires: readonly { from: { key: string; port: string }; to: { key: string; port: string } }[] }` — positions are relative to the template origin.
  - `type TemplateError = "unknown_type" | "invalid_params" | "unknown_preset" | "unknown_key" | "unknown_port" | "kind_mismatch" | "port_full" | "duplicate_key"`
  - `instantiateTemplate(editor: StudioEditor, registry: NodeRegistry, template: StudioTemplate, at: { x: number; y: number }): Result<Record<string, string>, TemplateError>` — returns template key → node id. Validates every node and wire against the registry before writing (port counts are checked within the template). Writes all of it inside one `editor.transact` (one undo step). `detail` names the failing key or wire.
  - `parseStudioTemplate(json: unknown): Result<StudioTemplate, "invalid_template">` — zod schema for the shape above; templates arrive as JSON.

- [ ] **Step 1: Write the failing test** `templates.test.ts` — cases:
  - `instantiates nodes at an offset and wires them` (a 2-node text → textgen template at `{x:100,y:50}`; node positions are template position + offset; one wire)
  - `applies a preset declared on a template node`
  - `writes nothing when any template step is invalid` (third wire references `unknown_key` → `{ ok:false, error:"unknown_key" }` and `listNodes()` empty)
  - `a template is a single undo step`
  - `parseStudioTemplate rejects a malformed template`

- [ ] **Step 2: Run, see fail.** `bun test src/lib/studio/core/templates.test.ts`
- [ ] **Step 3: Implement `templates.ts`.**
- [ ] **Step 4: Run, see 5 pass.**
- [ ] **Step 5: Commit** `feat(web): studio templates as data`

---

### Task 7: Tool registry and the public barrel

**Files:**
- Create: `web/src/lib/studio/core/tools.ts`, `web/src/lib/studio/core/index.ts`
- Test: `web/src/lib/studio/core/tools.test.ts`

**Interfaces:**
- Produces:
  - `type ToolSurface = "canvas" | "focus"`; `interface ToolDefinition { id: string; label: string; shortcut: string; surface: ToolSurface; enabled: boolean }` (`shortcut` is one uppercase letter).
  - `interface ToolRegistry { register(t: ToolDefinition): void; list(surface: ToolSurface): ToolDefinition[]; byShortcut(surface: ToolSurface, key: string): ToolDefinition | undefined }` — `register` throws on a duplicate id or a shortcut already used on the same surface; `byShortcut` is case-insensitive.
  - `createToolRegistry(): ToolRegistry`
  - `const DEFAULT_STUDIO_TOOLS: readonly ToolDefinition[]` — canvas surface, in this order: `add` (A), `select` (V), `hand` (H), `section` (S), `sticky` (N), `comment` (C, `enabled: false` in P0). Focus-surface tools arrive in P2.
  - `index.ts` re-exports every public name from Tasks 1–7 and nothing private.

- [ ] **Step 1: Write the failing test** `tools.test.ts` — `lists default canvas tools in order`, `rejects a shortcut clash on one surface`, `byShortcut is case-insensitive`, `comment is disabled in P0`.
- [ ] **Step 2: Run, see fail.** `bun test src/lib/studio/core/tools.test.ts`
- [ ] **Step 3: Implement `tools.ts` and `index.ts`.**
- [ ] **Step 4: Run, see 4 pass, then the whole core:** `bun test src/lib/studio/core` → all pass.
- [ ] **Step 5: Commit** `feat(web): studio tool registry and core barrel`

---

### Task 8: Lint boundaries

**Files:**
- Modify: `web/eslint.config.mjs` (append config objects before the prettier entry)

**Interfaces:**
- Produces two `no-restricted-imports` blocks:
  - `files: ["src/lib/studio/core/**/*.{ts,tsx}"]` — forbid `react`, `react-dom`, `fabric`, `@/components/*`, `@/hooks/*`, `@/lib/studio/nodes`, `@/lib/studio/nodes/*`, `@/lib/studio/render`, `@/lib/studio/render/*`, `@/lib/studio/ui`, `@/lib/studio/ui/*`, `@/lib/studio/sync`, `@/lib/studio/sync/*`, and relative `../nodes/*`, `../render/*`, `../ui/*`, `../sync/*`. Message: `"studio core is headless: no React, Fabric, nodes, renderers, UI or sync (FR-6)."`
  - `files: ["src/lib/studio/nodes/**/*.{ts,tsx}"]` — forbid deep core imports `@/lib/studio/core/*` (message: `"import the studio core through @/lib/studio/core only"`), `@/lib/studio/render`, `@/lib/studio/render/*`, and other node plugins (`@/lib/studio/nodes/*`).

- [ ] **Step 1: Prove the rule is missing.** Create `web/src/lib/studio/core/__lint_probe.ts` containing `import "fabric"; export {};`. Run `bunx eslint src/lib/studio/core/__lint_probe.ts`. Expected: no `no-restricted-imports` error.
- [ ] **Step 2: Add the two config blocks.**
- [ ] **Step 3: Prove the rule bites.** Same command. Expected: 1 error, message contains `studio core is headless`. Then delete the probe file.
- [ ] **Step 4: Lint the real core:** `bunx eslint src/lib/studio` → clean.
- [ ] **Step 5: Commit** `chore(web): enforce studio core import boundaries`

---

## Done when

- `bun test src/lib/studio/core` passes (≈45 tests) with no browser.
- `bunx eslint src/lib/studio` is clean, and `bunx tsc --noEmit -p . 2>&1 | grep "src/lib/studio"` prints nothing.
- AC-3 (migration) and AC-4 (graph logic testable without a browser) are covered by Tasks 4–5. AC-1 and AC-2 are completed in the surface plan (Echo-node check and editor-API assembly).
