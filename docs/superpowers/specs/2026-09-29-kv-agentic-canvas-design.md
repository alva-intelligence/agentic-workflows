# KV Agentic Canvas — one chat instruction, applied across every board and size

**Date:** 2026-09-29
**Author:** daffa (with Claude)
**Status:** design approved in chat section by section, awaiting written-spec review
**Services:** collab (frnd-hocuspocus), api, ai-service, web

## 1. Summary

> As a user, I want to just chat with the AI about what I want changed or
> added, and have it actually make the change directly on the canvas itself —
> across every relevant board or size on its own — instead of me manually
> applying each edit one board at a time.

The user sends one instruction in the KV chat. The agent reads the current
canvas (boards, their resize sizes, their layers), executes the change on every
relevant board and size, and reports what it did. The same capability is
exposed later to external clients (Claude, Cursor, …) through the existing
frndOS MCP server, with no second implementation.

The core decision: **edits execute on the server, not in the browser.** The
agent picks verbs and targets; the api guarantees correctness (sink routing,
inherit/detached tiles, credits, undo). Because none of that lives in a prompt,
an MCP client gets exactly the behaviour the in-app chat gets.

## 2. Decisions taken (daffa, 2026-09-29)

| # | Decision | Chosen | Rejected |
|---|---|---|---|
| D1 | v1 edit scope | **Layers + pixel edits** | layers only; pixel only |
| D2 | Confirmation | **Layer edits auto-execute; anything that spends credits (pixel edits, new sizes) shows a plan card the user runs once** | all auto; always plan first |
| D3 | Unstated targets | **Agent may decide, but only as a suggestion the user confirms** (question card). Stated targets execute directly. | fixed default scope; agent decides silently |
| D4 | Entry point | **Inside the existing KV chat**; the agent gains tools behind a flag. No separate "Agent" mode. | separate mode toggle |
| D5 | Structural edits in v1 | **Add sizes, create variant boards, remove layers** | edit-only |
| D6 | Execution architecture | **A — server-executed (deck pattern), MCP-ready.** Claude also implements the `frnd-hocuspocus` side. | B client-applied ops; C hybrid |

Rationale for D4 (asked "what is best practice"): current products (Figma AI,
Canva, Cursor, ChatGPT with tools) use one conversational surface where the
agent chooses tools; explicit modes exist to gate cost or risk, which D2/D3
already gate. MCP clients have no modes, only tools, so a tool-only in-app
agent behaves identically to the MCP one. Rollout safety comes from the flag.

Rationale for D6: the target is MCP, where no browser is open. Client-applied
ops (B) cannot serve that and would be rewritten; a hybrid (C) is two executors
with two sets of bugs.

## 3. What exists today (grounding)

- **frndOS MCP server exists.** `api/routes/ai.php` (gated by
  `services.mcp.server_enabled`), `api/app/Mcp/Servers/FrndosServer.php`
  (~75 tools, OAuth 2.1 via Passport `mcp` guard). Every tool is a 1:1 mirror
  of the internal REST surface `api/v1/mcp/tools/*` that ai-service calls with
  `X-Internal-Token` (`ResolveToolContext`), enforced by
  `php artisan mcp:verify-mirror`. Execution goes through
  `app/Mcp/Support/ToolControllerGateway.php` (membership, role scope,
  subscription, `hasSpendableCredits`). KV today: `list_kv_files`,
  `get_kv_file`, `generate_kv` only.
- **The `mcp/tools/*` REST path is not the MCP protocol.** It is plain internal
  HTTP; the in-app chat never speaks MCP.
- **Decks solved server writes into a live Y.Doc.**
  `api/app/Services/Deck/DeckCollabWriter.php` → collab
  `/internal/decks/{id}/…` (`collab/src/routes.ts`, `appendSlides.ts`,
  `replaceSlide.ts`, …) using `openDirectConnection` + `doc.transact(…,
  SERVER_WRITE_ORIGIN)`, which also works for a doc no browser has open
  (`onLoadDocument` replays the log). Its docblock records why writing the
  DB column instead silently lost agent writes.
- **Deck run ledger and undo.** `deck_agent_runs`, `DeckAgentRunRecorder`,
  `DeckAgentRunReverter` (server-mode, newest-first, compare-and-set, `skipped`),
  `POST v1/decks/{deck}/agent/runs/{run}/undo`, web `DeckRunCard.tsx`.
  `agent_run_id` is the chat `run_id`, validated as a ULID in
  `ResolveToolContext`.
- **KV doc model.** Y.Doc `kv_file:{fileId}` (`web/src/lib/kv/yjsDoc.ts`):
  `meta`, `boards` (Y.Map keyed by **tip generation id**; `x`, `y`, `name`,
  `versionIds`), `overlays` (Y.Array of `{id, type, rect, z, payload,
  board_generation_id}`), `removed`. Writers in `web/src/lib/kv/yjsSerializer.ts`.
  Collab mirrors the layout in `collab/src/kvSerialize.ts` but never reads or
  writes `overlays`.
- **Overlay persistence is browser-only.** Web autosaves a **full-replace**
  `PATCH studio/files/{id}/overlays` from its doc projection
  (`useDebouncedOverlaySave.ts`). Collab materialises only boards
  (`metadata.kv_canvas`) and only on last disconnect (`snapshot.ts`,
  `KvSnapshotService::materialize`). A server write to the overlays column
  would be erased by any open tab.
- **Resize tiles are REST rows** (`KvResizeExport`, `overlays: null` =
  inherit and re-project the parent's layers; non-null = detached snapshot
  that keeps the master's overlay ids). Service layer exists:
  `KvResizeExportService` (`createBatch`, `duplicate`, `regenerate`,
  `editRegion`, `cancel`), fixed-price charging via `KvFixedPriceChargeService`.
  There is **no live master→tile cascade** for detached tiles.
- **KV chat has no canvas awareness.** `ai-service/app/agents/kv_generator`
  sees one `base_generation` image; responses are text, UI cards
  (`present_question_card`, `suggest_mode_switch` shims) and one image
  generation. Tool calls already stream as `tool_call` frames.
- **Overlay mutation has no api service.** Logic is inline in
  `StudioFileController::updateOverlays` (server-stamps `id`/`z`/timestamps,
  keeps a client-supplied `id`) and `KvResizeExportController::updateOverlays`.

## 4. Architecture

```
 KV chat (web) ──┐                          ┌── Claude / Cursor (MCP, OAuth)
                 ▼                          ▼
        ai-service KV agent          api FrndosServer (twin tools)
        + canvas tools ──HTTP──► api  v1/mcp/tools/kv/canvas/*  ◄──┘
                                      │
                         KvCanvasToolController (thin)
                                      │
                ┌──────── KvCanvasEditService (domain verbs) ───────┐
                │                     │                              │
      KvCollabWriter           KvResizeExportService         KvGeneration / job
      (Craft boards: layers,   (tiles: detached layers,      pipeline (board
       boards, rekey)           new sizes, region edit)       pixel edits)
                │                     │                              │
      collab POST /internal/kv-files/{id}/ops                        │
      (apply in live Y.Doc, then materialise boards + overlays → api)│
                └──────────── KvAgentRunRecorder (ledger + pre-images) ┘
```

### 4.1 Units

| Unit | Service | Purpose | Depends on |
|---|---|---|---|
| Canvas tools (`make_kv_canvas_tools`) | ai-service | Thin HTTP wrappers over the api tool routes; add `agent_run_id`; per-turn honesty ledger (as `DeckWriteLedger`) | api tool routes |
| `<kv_canvas_state>` prompt block | ai-service | Renders the inventory as fenced data | inventory from api |
| `KvCanvasContextAssembler` | api | Builds the canvas inventory (§5) from the live doc + generations + resize exports | `KvCollabWriter::liveDocument`, models |
| `KvCanvasEditService` | api | The only place that knows which sink an op goes to, inherit/detached rules, board-id resolution | writer, resize service, generation pipeline, recorder |
| `KvCollabWriter` | api | HTTP client for collab KV routes (token, timeout, body cap, error mapping) | collab |
| `StudioOverlayNormalizer` | api | Extracted stamping/validation from `updateOverlays`, shared by the browser PATCH and the collab materialisation endpoint | — |
| `KvAgentRunRecorder` / `KvAgentRunReverter` | api | Ledger writes; server-mode undo | writer, resize service |
| `KvCanvasToolController` + `FrndosTool` twins | api | REST tool surface + MCP mirror | edit service |
| KV ops + read routes | collab | Apply op batches atomically inside the live doc; return pre-images; materialise | `kvSerialize.ts`, persistence |
| Run card, plan card, run API client | web | Show, confirm, track, undo | api user routes |

### 4.2 In-app flow (no MCP involved)

1. User types in the KV chat composer (unchanged) → `POST v1/threads/{id}/stream`
   → `ChatService::streamKvGenerator` → ai-service `/ai/kv-generator/stream`.
2. When the flag is on and `canvas_mode = craft`, api mints a `run_id` (ULID)
   for the turn, attaches the inventory, and ai-service gives the agent the
   canvas tools.
3. Tools call `v1/mcp/tools/kv/canvas/*` with `X-Internal-Token`, `user_id`,
   `workspace_id`, `agent_run_id`.
4. api writes through collab; open browsers receive the change as a normal
   remote Y update. The browser applies nothing itself.
5. Tool results stream as the existing `tool_call` frames (chips). The turn
   ends with the agent's summary and a run card referencing `run_id`.

The existing chat behaviours (image generation, region edit, question cards,
mode suggestions) are untouched. Flag off = no tools = today's chat exactly.

## 5. Canvas inventory

Returned by `get_kv_canvas` and injected as `<kv_canvas_state>`.

```jsonc
{
  "file": { "id": "…", "name": "Ramadan KV", "brand": "…" },
  "active": { "board_id": "gen_…", "size_id": null, "selected_layer_ids": ["01J…"] },
  "boards": [{
    "board_id": "gen_…",            // current tip generation id
    "name": "Concept A", "is_master": true,
    "width": 1080, "height": 1350, "image_url": "…",
    "layers": [{
      "layer_id": "01J…", "type": "text",       // text | image | shape
      "rect": { "x": 0.08, "y": 0.06, "w": 0.6, "h": 0.12, "rotation": 0 },
      "z": 3,
      "text": "Promo Ramadan",                  // ≤200 chars, sanitised
      "style": { "font": "Inter", "size": 64, "color": "#FFFFFF", "weight": 700 },
      "image_kind": null                        // logo | product | upload (image layers)
    }],
    "sizes": [{
      "size_id": "exp_…", "preset": "Instagram Story",
      "width": 1080, "height": 1920, "status": "ready",
      "mode": "inherit",                        // inherit | detached
      "overrides": []                           // detached only: layers that differ from the board
    }]
  }],
  "truncated": { "boards": false, "sizes": false }
}
```

Rules:

- `layer_id` is shared across sizes: detached tiles keep the master's overlay
  ids (`web/src/lib/studio/kv/tileOverlayId.ts`). "The headline on every size"
  is one `layer_id` and many targets.
- `board_id` is the tip generation id, which changes on rekey. The api resolves
  any id found in a board's `versionIds` chain to the current board, so a
  plan created before a rekey still lands.
- Caps: 30 boards, 50 sizes per board, 60 layers per surface, text 200 chars;
  a `truncated` flag and a prompt note when a cap is hit.
- All user-authored strings are sanitised like `deck_context_prompt._clean`
  (control chars, fence break-outs, backticks) and the block is labelled data,
  not instructions.

## 6. Tool catalogue (the contract; mirrored 1:1 to MCP)

Route prefix `v1/mcp/tools/kv/canvas/`. Every write tool accepts
`agent_run_id` (optional for MCP; see §8.1) and returns:

```jsonc
{ "run_id": "01J…",
  "applied":  [{ "target": "exp_…", "layer_id": "01J…", "op": "set_layer" }],
  "skipped":  [{ "target": "exp_…", "layer_id": "01J…", "reason": "layer_changed" }],
  "detached_sizes": ["exp_…"] }
```

`targets` is always explicit: `{ "board_ids": [...], "size_ids": [...],
"include_sizes": true|false }`. There is no implicit "everything". A board
target covers inheriting sizes automatically (they re-project); with
`include_sizes: true` the api also writes detached sizes of those boards.

| Group | Tool | Input (essentials) | Execution |
|---|---|---|---|
| Read | `get_kv_canvas` | `file_id` | immediate |
| Layers | `update_kv_layers` | `file_id`, `edits[{layer_id, targets, set:{text?, style?, rect?, visible?, z?}}]` | **auto** |
| | `add_kv_layer` | `file_id`, `targets`, `layer:{type, text?, style?, image:{source: brand_logo\|asset_id\|url}?, shape?}`, `placement:{anchor (9-point), margin, width}` | **auto** |
| | `remove_kv_layers` | `file_id`, `layer_ids`, `targets` | **auto** |
| Structure | `create_kv_variant_board` | `file_id`, `board_id`, `name?` | **auto** (free) |
| | `add_kv_sizes` | `file_id`, `board_id`, `sizes[preset \| {width,height}]` | **plan** (resize credits) |
| Pixel | `plan_kv_pixel_edits` | `file_id`, `edits[{target, instruction, region?:{bbox \| layer_id}}]` | **plan** |
| Execute | `run_kv_plan` | `plan_id` | in-app: **user only** (button); MCP: the client's user approves the tool call |
| Undo | `undo_kv_agent_run` | `run_id` | immediate |

Semantics:

- **An agent edit on a surface is the same as the same manual edit on that
  surface.** No new payload properties are introduced; allowed payload keys
  per type are exactly what `UpdateStudioFileOverlaysRequest` validates (the
  four overlay renderers stay in sync because nothing new is rendered).
- `set` on a layer **merges** into the existing payload (collab reads then
  writes; `docUpdateOverlay`'s whole-payload replace is not reused).
- Setting `text` on a text layer that has per-run styling collapses the runs
  into one run carrying the first run's style.
- A layer edit that targets a specific **inheriting** size (e.g. "only on 9:16,
  move the headline up") detaches that size first (snapshot of the resolved
  layers) and then applies the edit; the size appears in `detached_sizes`.
- A layer absent on a detached size is `skipped` with `layer_absent_on_size`.
- `add_kv_layer` placement is resolved by the api per target surface
  (anchor + margin + width fraction + the asset's intrinsic aspect) into a
  normalised rect; ids are ULIDs minted by the api.
- Plan tools create a stored plan (`kv_agent_runs.plans[]`) with per-target
  credit estimates and a 15-minute expiry. **No credits move before
  `run_kv_plan`.** `run_kv_plan` checks `hasSpendableCredits`, re-reads the
  inventory, skips targets that no longer exist, then dispatches.
- Unstated targets (D3): the in-app agent must call the existing
  `present_question_card` with its suggested targets and options
  (*Continue* / *Active board only* / *All boards*) before writing. The
  explicit-`targets` requirement makes this structural rather than a prompt
  hope. MCP clients ask their own user.

Tools are attached only when the flag is on and `canvas_mode = craft`.

## 7. Write paths

### 7.1 Craft boards — collab

New collab routes (`collab/src/routes.ts`), same `X-Internal-Token`, zod
bodies, 2 MB cap:

- `GET  /internal/kv-files/{id}/document` — live doc as JSON (boards,
  overlays, removed, meta); read-only, no transact.
- `POST /internal/kv-files/{id}/ops` — body
  `{ ops: [...], run_id }`, op kinds:
  `set_layer {layer_id, set, expected}`,
  `add_layer {layer}`,
  `remove_layer {layer_id, expected}`,
  `add_board {board_id, x, y, name, version_ids}`,
  `rekey_board_tip {from, to}`,
  `hide_board {board_id}` / `unhide_board {board_id}`.

Behaviour:

- `openDirectConnection("kv_file:{id}", {internal: true})`, all ops inside one
  `doc.transact(fn, SERVER_WRITE_ORIGIN)`. Every validation runs before the
  first write; any failure writes nothing.
- `expected` is the subset of fields the agent read (compare-and-set). A
  mismatch → 409 `layer_changed {layer_id, expected, current}`.
  *P1 note:* the api builds `expected` from its own fresh read of the live doc
  just before writing (the read that also yields the ledger pre-image), so it
  guards the api-read→collab-write window, not the whole turn; user work is
  protected at undo time (§8.2).
- Response: `{ applied: [...], before: { layers: {id: snapshot|null}, boards: {...} } }`
  — pre-images for the ledger.
- After a successful write, collab materialises immediately (not only on last
  disconnect): boards via the existing `internal/kv-files/{id}/snapshot`, and
  overlays via a new `POST internal/kv-files/{id}/overlays` on the api that
  uses `StudioOverlayNormalizer` (same validation and stamping as the browser
  PATCH — avoids the `payload.*` stripping trap). Export/resize paths that read
  REST therefore see agent edits even when no browser is open.
- Open browsers also keep their full-replace autosave. Both writers derive from
  the same converged doc; a stale tab can briefly overwrite, then re-saves on
  receiving the update. Accepted.

### 7.2 Resize tiles and jobs — existing api services

- Layers on detached tiles: `KvResizeExportService` gains an overlay-write
  method (moved out of `KvResizeExportController::updateOverlays`) with the
  same CAS + pre-image contract.
- Variant boards: the existing generation-duplicate path in
  `KvGeneratorFileController`, then collab `add_board` plus `add_layer` for
  each copied layer (fresh ULIDs, `board_generation_id` = the new board).
- New sizes: `createBatch`. Region edit / regenerate: `editRegion` /
  `regenerate`. Existing fixed-price charging unchanged.
- Board pixel edits: existing generation pipeline (`KvToolController::generate`
  pattern → ai-service `/ai/kv-generator/complete` → `persistCompletion`), then
  a collab `rekey_board_tip` or `add_board`. The outcome rule is ported from
  `web/src/lib/studio/kv/editOutcome.ts`: a board that has sizes gets a new
  variant board; otherwise the tip is rekeyed in place.

### 7.3 Board ids across sinks

`KvCanvasEditService` resolves every incoming board id through the
`versionIds` chain before routing, and returns the current id in results.

## 8. Run ledger and undo

### 8.1 Runs

Table `kv_agent_runs`: `id` (ULID, = `run_id`), `studio_file_id`, `user_id`,
`workspace_id`, `source` (`app` | `mcp`), `status`
(`running` | `completed` | `undone` | `failed`), `ops` (jsonb, atomic append of
`{type, sink: doc|tile|job, target, layer_id?, before, after, at}`),
`plans` (jsonb), timestamps.

- In-app: `run_id` is minted per chat turn by api; the row is created on the
  first write (`ensureRun`, with the concurrent-create guard used by decks).
- MCP: write tools accept an optional `run_id`; the first write without one
  creates a run and returns its id; the client passes it on later calls to
  group them.
- One running agent run per file (cache lock); a second gets 409
  `run_in_progress`.
- Cap: 200 ops per run; 60 targets per call.

### 8.2 Undo (server mode only)

`POST v1/studio/files/{file}/agent/runs/{run}/undo` (user route) and the
`undo_kv_agent_run` tool both call `KvAgentRunReverter`:

- Replays ops newest-first; each reversal is compare-and-set against what the
  agent wrote. A layer the user changed after the run is **not** overwritten;
  it is reported in `skipped`.
- Structural: variant boards are hidden (restorable), added sizes cancelled /
  deleted, pixel edits restored to the previous version
  (`KvResizeExportVersionService`; boards rekeyed back).
- **Credits already spent are not refunded**; the undo confirmation says so.
- Idempotent (`already_undone`); 409 while the run is still `running`;
  collab outage → 503, nothing half-reverted within one sink.
- Agent edits are remote Y updates and are **not** on the browser's ⌘Z stack
  (same as decks). Undo is the run card's button.

## 9. UX in the chat

- **Chips:** each tool call renders through the existing `tool_call` frames
  with human labels ("Changing headline · Board A + 3 sizes").
- **Target suggestion:** existing question card (D3).
- **Plan card (new):** targets with thumbnails, action per target, total
  credit estimate, expiry, **[Run]** / **[Cancel]**. *Run* calls
  `POST v1/studio/files/{file}/agent/plans/{plan}/run` (a user action, not the
  agent) and the card becomes a run card.
- **Run card (new, analogous to `DeckRunCard`):** per-target ✓ applied / ⚠
  skipped with reason / "9:16 now has its own layers (detached)"; live
  per-tile job progress from the existing tile realtime; clicking a target
  focuses the canvas on that board/size (existing layers-panel focus);
  **Undo run** with confirmation and a result line (reverted N, skipped M).
  Survives reload: the chat message stores `run_id`; state comes from
  `GET v1/studio/files/{file}/agent/runs/{run}`.
- **Final report:** the agent's closing text is written from tool results;
  the honesty ledger footnotes any claim the server did not accept. Pixel jobs
  finishing later only update the run card — no second LLM turn.
- **Analytics (PostHog):** dot-namespaced like `deck_agent.*`:
  `kv_agent.run_completed` (op and target counts, source),
  `kv_agent.run_undone`, `kv_agent.run_undo_failed`,
  `kv_agent.run_target_focused` (P1); `kv_agent.targets_suggested` (P2, needs
  `purpose: "targets"` on the question card), `kv_agent.plan_shown`,
  `kv_agent.plan_confirmed`, `kv_agent.plan_cancelled` (P2/P3). Taxonomy rows
  added with the web change.

Out of scope for v1 (YAGNI): an "FRND" presence avatar on the canvas,
highlighting agent-touched layers, per-op undo.

## 10. Security

- Tool context scoping as today (`ResolveToolContext` / MCP gateway:
  membership, role scope, subscription). Every tool re-checks file access
  (`authorizeAccess` semantics) and the KV feature flag.
- Layer text and names are untrusted data inside the prompt (§5 sanitising).
- `run_kv_plan` is not given to the in-app agent; spending requires a human
  click. For MCP it is a separate tool the client must call explicitly.
- `add_kv_layer` with `image.source = url` goes through the existing trusted
  asset / SSRF rules used by attachments.

## 11. Credits

- Layer ops, layer removal and variant boards: no charge.
- LLM tokens: existing "KV AI Chat" batching.
- Sizes and pixel edits: existing fixed-price / metering services, charged at
  `run_kv_plan` dispatch, never at plan time.

## 12. Phases

| Phase | Contents | Repos |
|---|---|---|
| **P1 — Foundation + layers** | collab `ops` + `document` + overlay materialisation; api assembler, edit service, collab writer, normaliser extraction, ledger, undo, tool controller + MCP twins for read/layer/undo; ai-service tools, inventory prompt, honesty ledger; web run card, undo, analytics. **Demo: "change the headline to X on every size".** | collab, api, ai-service, web |
| **P2 — Structure** | `create_kv_variant_board`, `add_kv_sizes`, `run_kv_plan`, plan card | api, ai-service, web, collab (`add_board`) |
| **P3 — Pixel** | `plan_kv_pixel_edits` for tiles and Craft boards, per-tile progress in the run card | all |
| **P4 — Open MCP** | Twins exist since P1 (mirror rule). Review OAuth scopes, rate limits, tool descriptions for external LLMs; live test from a Claude.ai connector | api |

Each phase gets its own implementation plan(s) and ships on its own.

**Flag:** PostHog `kv-agentic-canvas` — api `feature.flag` middleware on the
tool and user routes, web gate on the cards, ai-service attaches tools only
when api says the flag is on.

## 13. Testing

- **collab:** unit tests for each op kind; atomicity (a failing op writes
  nothing); 409 CAS; doc not currently open; materialisation calls.
- **api:** Pest Feature tests on a scratch Postgres (never SQLite, never the
  dev DB); collab faked with `Http::fake`; inherit/detached routing; detach on
  size-specific edit; CAS skip on undo; credit gates; plan expiry;
  `mcp:verify-mirror` green.
- **ai-service:** tool wrappers, inventory rendering and sanitising, honesty
  ledger — compared against the known pre-existing failure baseline.
- **web:** `bun test` for run card and plan card (controlled harness, not a
  stubbed push).
- **Manual e2e per phase:** two tabs open at once; file open by nobody; undo
  after the user edited one of the layers.
- **Agent eval:** 10–15 golden instructions on a fixture file, scoring tool
  choice and targets. Also decides whether the current KV chat model is
  sufficient for multi-target planning.

## 14. Open questions

1. Agent model — decided from the P1 eval results.
2. `frnd-hocuspocus` changes need review by the repo owner before deploy.
3. Are 200 ops per run / 60 targets per call the right MCP limits?
