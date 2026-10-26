# Studio Canvas P0 — Web Surface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put the headless core on screen: a flag-gated Studio route that opens a Studio file, syncs its graph over Hocuspocus (or local-only when collab is not configured), and renders an infinite canvas where people add File and Text nodes, wire them, add sections and sticky notes, undo and redo.

**Architecture:** Four layers per ADR `web/docs/adr/0005-canvas-layering.md`: Fabric content layer (section backgrounds now, compositions later), world overlay DOM (node cards, ports, wires as SVG, stickies) positioned with `lib/canvas/worldOverlay.ts` and camera CSS vars, screen overlay (Add menu, toasts), and one pointer/tool system. All writes go through `StudioEditor`. Node types are plugins: a core definition plus a React UI part, registered by `lib/studio/plugins.ts`. UI chrome uses frndOS v2 components.

**Tech Stack:** Next.js 16 (client components, `useParams`), React 19, `fabric ^7`, `yjs`, `@hocuspocus/provider ^2`, TanStack Query v5, `posthog-js`, `bun test`.

**Spec:** `frnd/docs/prd/studio-canvas.md` (FR-6, FR-8, FR-9, FR-27, FR-28, FR-32, FR-33, NFR-4, NFR-5, NFR-6, AC-1, AC-2, AC-14, AC-16, AC-17) and `web/docs/prd/studio-canvas.md` (TASK-1, TASK-9…TASK-12, "UI Component Rules"). Requires `2026-10-21-studio-canvas-p0-web-core.md` to be done first.

## Global Constraints

- Work in `web/` on branch `feature/daffa/vc-studio-canvas`. Never push. A dev server may be running with HMR: never leave a half-written file between steps (finish each file before saving the next).
- Strategy `wireframe_then_implementation`: no run, no credits, no executors in P0. Price/status chips are not shown yet.
- Import the core only via `@/lib/studio/core`.
- **frndOS components (mandatory, see web PRD "UI Component Rules"):** read `.claude/skills/frndos-ui/SKILL.md` and `frndos-components-v2` before writing UI. Import from `@/components/frndos/v2`; v1 only as a recorded fallback; new shared pieces go in `components/frndos/v2/`; colours, surfaces and fonts from `frndos-design-foundations` tokens; no new hard-coded dark hex; every surface correct in Midnight, Aurora and Daylight. Toasts via `useToastStore` (`frndos-rules`).
- Flag: `MAJOR_FEATURE_FLAGS.STUDIO_CANVAS = "show-studio-canvas"`, fail-closed through `useExperimentalFeatureEnabled` (same posture as `KV_MOTION_EDITOR`).
- Permission resource: `brand.studio.studio_canvas`. Tool slug: `studio-canvas`.
- Collab document name: `studio:<fileId>`. URL: `process.env.NEXT_PUBLIC_HOCUSPOCUS_URL` (unset → local-only doc).
- API: `POST v1/studio/canvas/files`, `GET v1/studio/canvas/files/{id}` (api plan Task 4).
- Tests: `bun test <path>`; component tests use `within(document.body)` (RTL `screen` is broken under bun), and run long-suite files alone. Lint: `bunx eslint src/lib/studio/core src/lib/studio/nodes src/lib/studio/ui src/lib/studio/render src/lib/studio/sync src/lib/studio/plugins.ts src/components/studio/canvas "src/app/(canvas)/studio/canvas"` (not `src/lib/studio` as a whole: `src/lib/studio/kv/` has pre-existing prettier errors). `bun test src/lib/studio/boundaries.test.ts` must stay green.
- **Core API as built (web-core plan + review fix pass, commit `0777cea41`):** use `updateSticky(id, patch)`, `updateSection(id, patch)`, `resizeNode`, `setNodeSection`; `connect`/`updateParams`/`applyPreset` can return `version_mismatch`; `migrateStudioDoc` returns `{ migrated, unknownType, newerThanClient, failed, docNewerThanClient }`; `graphProblems(nodes, wires, registry)` lists dangling/overfull wires and cycles in a merged doc. Read `web/src/lib/studio/core/index.ts` before Task 3.
- PostHog: invoke the `frndos-analytics-events` skill before Task 6.
- Commits: `feat(web): …` ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. Collab is unreachable or `NEXT_PUBLIC_HOCUSPOCUS_URL` is unset: the canvas must still open and be editable locally, with a visible "Not syncing" state, and must not run migrations before the doc has synced from the server when a server exists. → Task 2 tests.
2. A viewer (read-only role from collab) opens a file: no node can be added, moved, wired or deleted, and the toolbar shows read-only. → Task 4 test `read-only blocks every edit`.
3. A wire is dropped on an incompatible or full port: nothing is written and a toast names the reason. → Task 4 test `shows the reason when a connection is rejected`.
4. Keyboard shortcuts (Delete, V/H/S/N/A, ⌘Z) fire while typing in a Text node or sticky: they must not. → Task 5 test `ignores shortcuts while typing`.
5. A file contains a node type this client does not know: it renders as a placeholder card ("Unknown node: <type>"), keeps its wires, and cannot be edited. → Task 3 test `renders unknown node types as placeholders`.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/lib/featureFlags/constants.ts` | `STUDIO_CANVAS` key with a fail-closed comment block |
| `src/lib/toolPermissions.ts`, `src/lib/studioRoutes.ts` | Slug → permission, slug → route |
| `src/services/studioCanvas.ts` | `createStudioCanvasFile`, `getStudioCanvasFile` |
| `src/hooks/useStudioCanvasFile.ts` | TanStack Query hook |
| `src/lib/studio/sync/hocuspocus.ts` | `studioDocumentName`, `connectStudioHocuspocus` |
| `src/hooks/useStudioYDoc.ts` | Doc + provider + sync/readOnly state |
| `src/lib/studio/ui/registry.ts` | Node UI parts registry (React) |
| `src/lib/studio/nodes/text/*`, `src/lib/studio/nodes/file/*` | P0 node plugins |
| `src/lib/studio/plugins.ts` | `createStudioRegistries()` — the one place plugins are listed |
| `src/lib/studio/render/portGeometry.ts` | Deterministic port anchors + wire paths |
| `src/lib/studio/render/useStudioCamera.ts` | Fabric camera store binding |
| `src/components/studio/canvas/*` | Page shell, canvas, layers, toolbar, add menu |
| `src/app/(canvas)/studio/canvas/{new,[file_id]}/page.tsx`, `src/app/(canvas)/brands/[id]/studio/canvas/{new,[file_id]}/page.tsx` | Routes |
| `src/lib/analytics/studio-canvas-events.ts` | Typed PostHog wrappers |

---

### Task 1: Flag, permissions, routes and the file API

**Files:**
- Modify: `src/lib/featureFlags/constants.ts`, `src/lib/toolPermissions.ts`, `src/lib/studioRoutes.ts`, the `PermissionResource` union (find it with `rtk proxy grep -rn "brand.studio.resizer" src/types src/lib | head`)
- Create: `src/services/studioCanvas.ts`, `src/hooks/useStudioCanvasFile.ts`, `src/components/studio/canvas/StudioCanvasGate.tsx`, the four route pages
- Test: `src/lib/studioRoutes.test.ts` (extend or create), `src/components/studio/canvas/StudioCanvasGate.test.tsx`

**Interfaces:**
- `MAJOR_FEATURE_FLAGS.STUDIO_CANVAS = "show-studio-canvas"`.
- `TOOL_PERMISSION_BY_SLUG["studio-canvas"] = "brand.studio.studio_canvas"`.
- `STUDIO_FILE_ROUTES["studio-canvas"] = (base, id) => \`${base}/canvas/${id}\``; brandless `studioFileHref("", "studio-canvas", id)` → `/studio/canvas/${id}`.
- `createStudioCanvasFile(body: { brand_id?: string | null; project_id?: string | null; name?: string }): Promise<{ data: StudioFile }>` and `getStudioCanvasFile(id: string): Promise<{ data: StudioFile }>` on `axiosInstance` (same style as `createKvFile` in `services/mutate.ts:3900`).
- `useStudioCanvasFile(id: string | null)` → `useQuery({ queryKey: ["studio", "canvas-file", id], queryFn: () => getStudioCanvasFile(id!), enabled: !!id })`.
- `StudioCanvasGate({ brandId, children }: { brandId: string | null; children: ReactNode })`: flag `undefined` → `null`; `false` → `router.replace("/home")`; `true` → with `brandId` wrap in `RoutePermissionGuard resource="brand.studio.studio_canvas" action="read" brandId`, without it use the `hasAnyBrandPermission` + `isPermissionsLoaded` pattern from `(canvas)/studio/kv-generator/[file_id]/page.tsx`.
- Pages (`"use client"`, read params with `useParams`): `new` calls `createStudioCanvasFile({ brand_id })` once and `router.replace(studioFileHref(brandId, "studio-canvas", data.id))`; `[file_id]` renders `<StudioCanvasGate><StudioCanvasPage fileId={…} /></StudioCanvasGate>` (Task 5 component; a placeholder `<div>` until then).
- Tool card entry: the api row has `href: "/studio/canvas"`. Find how a tool click turns `href` into a route (`rtk proxy grep -rn "tool.href\|\.href}" "src/app/(dashboard)" src/components/home | head`) and make sure it lands on the `new` page for brand and brandless cases; if the convention needs a different href, change it in the api data migration instead of special-casing the web.

- [ ] **Step 1: Write the failing tests:** `studioFileHref` cases (brand + brandless) and gate cases (`renders nothing while the flag resolves`, `redirects home when the flag is off`, `renders children when the flag is on and permitted`) mocking `next/navigation`, `@/hooks/usePermissions` and `@/lib/featureFlags` with `vi.mock` as `src/app/(canvas)/studio/kv-generator/guards.test.tsx` does.
- [ ] **Step 2: Run, see fail.** `bun test src/lib/studioRoutes.test.ts src/components/studio/canvas/StudioCanvasGate.test.tsx`
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, see pass.**
- [ ] **Step 5: Commit** `feat(web): studio canvas flag, routes and file api`

---

### Task 2: Yjs sync for `studio:` documents

**Files:**
- Create: `src/lib/studio/sync/hocuspocus.ts`, `src/hooks/useStudioYDoc.ts`
- Test: `src/lib/studio/sync/hocuspocus.test.ts`, `src/hooks/useStudioYDoc.test.tsx`

**Interfaces:**
- `studioDocumentName(fileId: string): string` → `` `studio:${fileId}` ``.
- `connectStudioHocuspocus(opts: { fileId: string; doc: Y.Doc; getToken: () => Promise<string>; onSynced?: () => void; onAuthenticated?: (p: { readOnly: boolean }) => void; onAuthenticationFailed?: (p: { reason: string }) => void; onStatus?: (s: "connecting" | "connected" | "disconnected") => void }): HocuspocusProvider | null` — returns `null` when `NEXT_PUBLIC_HOCUSPOCUS_URL` is unset. Mirrors `src/lib/kv/hocuspocus.ts`. `readOnly` comes from the provider's authenticated scope (`"readonly"`); check the exact callback and field name in the installed `@hocuspocus/provider` v2 types before writing it.
- `useStudioYDoc(fileId: string | null): { sdoc: StudioYDoc | null; mode: "live" | "local_only"; connected: boolean; synced: boolean; readOnly: boolean }` — creates `createStudioDoc()` once per file; token from `resolveAuthToken()` (`src/services/axios.ts`); auth failures retry with 2s/5s/10s backoff like `useKvYjsDoc`; `mode = "local_only"` and `synced = true` immediately when the provider is `null`; destroys the provider and doc on unmount or file change.

- [ ] **Step 1: Write the failing tests:** `documentName uses the studio prefix`; `returns null without a collab url`; hook tests `is local-only and synced without a collab url`, `stays unsynced until the provider reports synced` (mock `connectStudioHocuspocus`), `exposes readOnly from the provider`, `destroys the provider on unmount`.
- [ ] **Step 2: Run, see fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, see pass.**
- [ ] **Step 5: Commit** `feat(web): sync studio canvas docs over hocuspocus`

---

### Task 3: Node UI registry and the File and Text plugins

**Files:**
- Create: `src/lib/studio/ui/registry.ts`, `src/lib/studio/nodes/text/{definition.ts,TextCard.tsx,index.ts}`, `src/lib/studio/nodes/file/{definition.ts,FileCard.tsx,index.ts}`, `src/lib/studio/plugins.ts`, `src/components/studio/canvas/UnknownNodeCard.tsx`
- Test: `src/lib/studio/nodes/text/text.test.ts`, `src/lib/studio/nodes/file/file.test.ts`, `src/lib/studio/plugins.test.ts`, `src/lib/studio/plugins.echo.test.ts`, `src/components/studio/canvas/NodeCards.test.tsx`

**Interfaces:**
- `interface NodeCardProps { node: NodeRecord; editor: StudioEditor; selected: boolean; readOnly: boolean }`
- `interface NodeUiParts { Card: ComponentType<NodeCardProps>; Icon: ComponentType<{ className?: string }> }` (Inspector and FocusEditor arrive in P1/P2)
- `interface NodeUiRegistry { register(type: string, ui: NodeUiParts): void; get(type: string): NodeUiParts | undefined }`; `createNodeUiRegistry(): NodeUiRegistry` (throws on duplicate).
- A plugin's `index.ts` exports `{ definition, ui }` typed `StudioPlugin = { definition: NodeTypeDefinition<any>; ui: NodeUiParts }` (type declared in `ui/registry.ts`).
- `text@1`: no inputs; output `{ id: "out", label: "Text", kind: "text" }`; params `z.object({ text: z.string().max(20000) })`; default `{ text: "" }`; `defaultSize { w: 240, h: 140 }`; no `executor`, no `estimateCost`. `TextCard` edits `params.text` with v2 `AutoGrowTextarea`; commits via `editor.updateParams` on blur and after 400 ms idle (one undo step per pause); placeholder copy "Type or paste the brief, or a note…" (design frame 1.2).
- `file@1`: no inputs; output `{ id: "out", label: "File", kind: "document" }`; params `z.object({ fileName: z.string().nullable(), mimeType: z.string().nullable(), sizeBytes: z.number().int().nonnegative().nullable(), larkUrl: z.string().url().nullable(), status: z.enum(["empty", "attached"]) })`; default all `null` + `status: "empty"`; `defaultSize { w: 240, h: 140 }`. `FileCard` shows the drop zone copy "Drop a PDF or image, or paste a Lark link" with Upload and Paste link actions (frame 1.2); a dropped or picked file sets `fileName`, `mimeType`, `sizeBytes`, `status: "attached"` (no upload and no parsing in P0 — say so in a code comment); Paste link accepts URLs whose host ends in `larksuite.com` or `feishu.cn`, else shows the field error "Paste a Lark doc link".
- `createStudioRegistries(): { nodes: NodeRegistry; ui: NodeUiRegistry }` in `plugins.ts` registers `text` then `file`. This is the only file that lists plugins.
- `UnknownNodeCard({ node })`: title "Unknown node", body `node.type`, read-only, no ports beyond what its wires need.

- [ ] **Step 1: Write the failing tests:**
  - `text.test.ts`: `defines text@1 with one text output`, `rejects text over 20000 chars`.
  - `file.test.ts`: `defaults to an empty file`, `rejects a non-url lark link`.
  - `plugins.test.ts` (AC-2): build a canvas through the editor API only — create text + file nodes, try `connect(file.out → text.out)` and get `unknown_port`, undo → empty doc.
  - `src/lib/studio/plugins.echo.test.ts` (AC-1; outside `nodes/` because the node lint rule forbids importing other plugins): inside the test file, `defineNodeType({ type: "echo", version: 1, inputs: [{ id: "in", label: "In", accepts: ["text"], max: 1 }], outputs: [{ id: "out", label: "Out", kind: "text" }], … })`, register it next to the real plugins on a fresh registry, connect `text.out → echo.in`, undo. No file under `src/lib/studio/core` changes for this test — note that in the test's top comment.
  - `NodeCards.test.tsx`: `TextCard commits typed text after a pause`, `FileCard sets attached on drop`, `renders unknown node types as placeholders`.
- [ ] **Step 2: Run, see fail.** `bun test src/lib/studio/nodes src/lib/studio/plugins.test.ts` and the card test file alone.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, see pass. Lint:** `bunx eslint src/lib/studio` (the node boundary rule must stay clean).
- [ ] **Step 5: Commit** `feat(web): studio file and text node plugins`

---

### Task 4: Canvas surface — camera, layers, wires and connecting

**Files:**
- Create: `src/lib/studio/render/portGeometry.ts`, `src/lib/studio/render/useStudioCamera.ts`, `src/components/studio/canvas/StudioCanvas.tsx`, `NodeLayer.tsx`, `NodeChrome.tsx`, `WireLayer.tsx`, `SectionLayer.tsx`, `StickyLayer.tsx`, `connectErrorCopy.ts`
- Test: `src/lib/studio/render/portGeometry.test.ts`, `src/components/studio/canvas/StudioCanvas.test.tsx`

**Interfaces:**
- `portGeometry.ts` constants `NODE_HEADER_H = 40`, `PORT_ROW_H = 28`, `PORT_DOT = 10`. `portAnchor(node: NodeRecord, def: NodeTypeDefinition<any> | undefined, port: { id: string; side: "in" | "out" }): { x: number; y: number }` — input `i` at `(node.x, node.y + NODE_HEADER_H + i * PORT_ROW_H + PORT_ROW_H / 2)`, output `i` at `(node.x + node.w, same formula)`; unknown def or port → vertical middle of the node on that side. `wirePath(a: {x;y}, b: {x;y}): string` → `M ax ay C ax+d ay, bx-d by, bx by` with `d = max(40, |bx - ax| / 2)`. Deterministic: wires never depend on DOM measurement.
- `useStudioCamera({ fabricRef }): { cameraStore: CameraStore; cameraRef }` — mirrors `components/studio/kv-generator/fabric/useCanvasCamera.ts` (`createCameraStore` with `applyToEngine` setting `setViewportTransform([s,0,0,s,x,y])`). Pan/zoom via `attachPanZoomGestures(canvas, { minZoom: 0.1, maxZoom: 4, pan: { wheel: true, space: true, middleDrag: true }, isPanToolActive: () => tool === "hand" })`; the world overlay container binds `useCameraCssVars(ref, cameraStore)`.
- `StudioCanvas({ editor, registries, readOnly, tool, onToolChange }: …)`: one viewport-sized `fabric.Canvas` (`selection: false`, transparent background) for the content layer; `SectionLayer` draws sections as Fabric rects plus a DOM name label; `NodeLayer`, `WireLayer` (one SVG in world coordinates), `StickyLayer` live in the world overlay, positioned with `worldTranslate` / `lenCss`. Re-render from `editor.subscribe`.
- `NodeChrome({ node, def, selected, readOnly, onPortPointerDown, children })`: v2-based card shell (header with plugin `Icon` + title from `node.name ?? def.title`, port dots with `data-studio-port="<nodeId>:<portId>:<in|out>"`). If v2 lacks a suitable card shell or port dot, build `NodeShell`/`PortDot` in `components/frndos/v2/` and note it in the track file.
- Interactions: click selects (local React state, not the doc); dragging the header moves the card live and commits `editor.moveNode` on pointer up; pointer-down on an output dot starts a temporary wire to the pointer (`clientToWorld`), pointer-up on an input dot calls `editor.connect`; on `{ ok: false }` show a toast with `connectErrorCopy(error, { max })`:
  - `kind_mismatch` → "That output can't go into this input."
  - `port_full` → "This input already has {max} connections."
  - `cycle` → "That connection would make a loop."
  - `version_mismatch` → "That node was made with a different version of Studio, so it can't be wired here."
  - `duplicate` → "These are already connected."
  - any other → "Couldn't connect these nodes."
- `readOnly` disables dragging, connecting and deleting.
- `WireLayer` calls `graphProblems` on every render: dangling wires are not drawn; overfull wires are drawn dashed with a v2 `Tooltip` "This input has more connections than it allows" (a merged doc can produce both — see `records.ts` header).
- Stickies are dragged by their header (`editor.updateSticky(id, { x, y })` on pointer up) and edited in place (`updateSticky(id, { text })`); a section's name is edited inline (`updateSection(id, { name })`) and the section is moved by dragging its label (`updateSection(id, { x, y })`).

- [ ] **Step 1: Write the failing tests:** `portGeometry.test.ts` (`anchors inputs on the left by index`, `anchors outputs on the right`, `falls back to the middle for unknown ports`, `wirePath bends at least 40 units`); `StudioCanvas.test.tsx` with a stubbed Fabric module (jsdom has no canvas context): `renders a card per node`, `draws a wire per connection`, `shows the reason when a connection is rejected` (simulate pointer-down on a text output and pointer-up on another text output → toast "Couldn't connect these nodes.", no wire), `read-only blocks every edit`.
- [ ] **Step 2: Run, see fail** (each test file alone).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, see pass.**
- [ ] **Step 5: Commit** `feat(web): studio canvas surface with nodes and wires`

---

### Task 5: Page shell, toolbar, Add menu, keyboard

**Files:**
- Create: `src/components/studio/canvas/StudioCanvasPage.tsx`, `StudioTopBar.tsx`, `StudioToolbar.tsx`, `StudioAddMenu.tsx`, `useStudioKeyboard.ts`
- Modify: the `[file_id]` pages from Task 1 (render `StudioCanvasPage`)
- Test: `src/components/studio/canvas/StudioCanvasPage.test.tsx`, `src/components/studio/canvas/useStudioKeyboard.test.tsx`

**Interfaces:**
- `StudioCanvasPage({ fileId })`: `useStudioCanvasFile` + `useStudioYDoc`; once `synced`, runs `migrateStudioDoc` once (if `docNewerThanClient`, the whole page is View only with the notice "This file was made with a newer version of Studio. Reload to edit."; nodes in `unknownType`, `newerThanClient` or `failed` render as read-only placeholder cards) and creates the editor with `createStudioEditor({ sdoc, registry })` (one editor per doc, destroyed on unmount); shows "Opening canvas…" until synced; shows a "Not syncing" chip (v2 `Chip`) in `local_only` mode and "View only" when `readOnly`.
- `StudioTopBar`: file name, brand, Share (disabled in P0, `Tooltip` "Sharing arrives later"), using v2 `TextButton`/`IconButton`/`Chip`.
- `StudioToolbar({ tools, active, onSelect, readOnly })`: `DEFAULT_STUDIO_TOOLS` as v2 `IconButton`s with `Tooltip` showing label + shortcut; `comment` disabled with tooltip "Comments arrive later"; `add` opens `StudioAddMenu`.
- `StudioAddMenu`: v2 `Popover` + `Menu` listing `registries.nodes.list()` (icon + title); choosing one calls `editor.createNode({ type, x, y })` at `viewportCenterWorld(canvas)`.
- Tools: `section` = drag a rectangle on empty canvas → `editor.createSection({ …, name: "Section" })`; `sticky` = click on empty canvas → `editor.addSticky({ x, y, text: "" })`; `hand` = pan; `select` = default.
- `useStudioKeyboard({ editor, selection, setTool, readOnly })`: Delete/Backspace → inside one `editor.transact`, `deleteNodes` + `deleteStickies` + `deleteSections` for the selection (one undo step); ⌘Z/Ctrl+Z → undo; ⇧⌘Z/Ctrl+Y → redo; tool letters via `toolRegistry.byShortcut("canvas", key)`. Ignores events whose target is an input, textarea, or contenteditable, and ignores all edits when `readOnly`.

- [ ] **Step 1: Write the failing tests:** `shows opening state until synced`, `shows not syncing in local-only mode`, `opens view-only when the doc is from a newer schema`, `deleting a mixed selection is one undo step`, `adds a text node from the add menu`, `deletes the selected node with Backspace`, `undo restores a deleted node`, `ignores shortcuts while typing`, `read-only ignores delete and undo`.
- [ ] **Step 2: Run, see fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, see pass.**
- [ ] **Step 5: Commit** `feat(web): studio canvas page, toolbar and shortcuts`

---

### Task 6: PostHog events

Invoke the `frndos-analytics-events` skill first and follow it where it differs from this task.

**Files:**
- Create: `src/lib/analytics/studio-canvas-events.ts`
- Modify: call sites in Tasks 1, 4, 5
- Test: `src/lib/analytics/studio-canvas-events.test.ts`

**Interfaces** (module-local `safeCapture`, same as `kv-generator-events.ts`; base context comes from super properties, never passed by hand):
- `trackStudioCanvasFileCreated(p: { has_brand: boolean })` → `studio_canvas.file_created` (fired by the `new` page after the API returns).
- `trackStudioCanvasOpened(p: { mode: "live" | "local_only"; read_only: boolean })` → `studio_canvas.opened` (once per page mount, after sync).
- `trackStudioCanvasNodeCreated(p: { node_type: string; via: "add_menu" })` → `studio_canvas.node_created`.
- `trackStudioCanvasWireConnected(p: { from_type: string; to_type: string; to_port: string })` → `studio_canvas.wire_connected`.
- `trackStudioCanvasWireRejected(p: { reason: ConnectError })` → `studio_canvas.wire_rejected`.

- [ ] **Step 1: Write the failing test:** each wrapper calls `posthog.capture` with the exact event name and props; a throwing `capture` does not throw out of the wrapper.
- [ ] **Step 2: Run, see fail.**
- [ ] **Step 3: Implement the module and wire the call sites.**
- [ ] **Step 4: Run, see pass.** Add the five events to `docs/analytics/` following the skill.
- [ ] **Step 5: Commit** `feat(web): studio canvas analytics events`

---

### Task 7: Manual verification (needs the api and collab plans done)

- [ ] **Step 1:** `bun test src/lib/studio` and each canvas component test file alone → all pass; `bunx eslint src/lib/studio src/components/studio/canvas "src/app/(canvas)/studio/canvas" "src/app/(canvas)/brands/[id]/studio/canvas"` → clean; `bunx tsc --noEmit -p . 2>&1 | grep -E "lib/studio|studio/canvas"` → no lines.
- [ ] **Step 2:** With api, collab and web running, open `/studio/canvas/new` → redirected to a file; add Text and File nodes; wire File → Text fails with "Couldn't connect these nodes." (both are outputs-only) — expected in P0, there is no node with a text input yet besides the Echo test node; add a section and a sticky; undo/redo.
- [ ] **Step 3:** Open the same file in a second tab: changes appear live (AC-14). Reload: everything persists.
- [ ] **Step 4:** Check Midnight, Aurora and Daylight; take screenshots.
- [ ] **Step 5:** `grep -rn "components/frndos" src/lib/studio src/components/studio/canvas` shows only real imports from `@/components/frndos/v2` (or recorded v1 fallbacks).
- [ ] **Step 6:** Update `web/docs/tracks/studio-canvas.track.md`: tick TASK-1 and TASK-9…TASK-12, log the session, list any v1 fallbacks or new v2 components.
