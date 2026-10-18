---
title: KV Agentic Canvas P0 — Layer Edits Across Boards and Sizes
slug: kv-agentic-canvas-p0
parent_feature: kv-agentic-canvas
author: daffa
created: 2026-10-18
status: approved # approved 2026-10-18 (daffa)
services: [api, web, ai-service, collab]
---

# KV Agentic Canvas P0 — Layer Edits Across Boards and Sizes

## Overview

KV chat today cannot see the canvas. It gets one `base_generation` image and the
chat history. It can answer only with text, question cards, a mode suggestion, or
one image render. When a user wants the same change on every board and every
resize size, they make it by hand, one surface at a time.

P0 lets the KV chat agent read the file's canvas (boards, their resize sizes,
their layers) and edit **layers** directly on every relevant board and size from
one chat instruction. It then reports what it did and gives the user one-click
undo. Edits run on the server (api + collab), not in the browser. The same tool
surface is mirrored 1:1 to the frndOS MCP server, so one implementation serves
both the in-app chat and external MCP clients.

Who it is for: KV Studio users (internal scope, behind `show-kv-generator`)
who keep one KV across several boards and platform sizes.

Feature split (parent `kv-agentic-canvas`):

| Sub-feature | Scope | Status |
|---|---|---|
| **kv-agentic-canvas-p0** (this PRD) | Inventory + layer tools (update/add/remove), run ledger, undo, run card | Built on an unpushed branch, needs rebase + audit |
| kv-agentic-canvas-p1 | Structure: variant boards, add sizes, plan card, `run_kv_plan` | Not started |
| kv-agentic-canvas-p2 | Pixel edits on boards and tiles (planned, credit-gated) + opening MCP to external clients | Not started |

Source design: `docs/superpowers/specs/2026-09-29-kv-agentic-canvas-design.md`.
Binding cross-service contract: `docs/superpowers/plans/2026-09-29-kv-agentic-canvas-p1-contracts.md`
(that file's "P1" = this PRD's P0).

## Brainstorming Outcome

Server-executed agentic canvas for KV chat. The agent gets a canvas inventory
(`<kv_canvas_state>`) and tools that always take explicit targets, through api
`v1/mcp/tools/kv/canvas/*`. api `KvCanvasEditService` routes each op either to
collab live Y.Doc ops (Craft boards) or to `KvResizeExportService` (detached
tiles). A `kv_agent_runs` ledger records every op with a compare-and-set undo.
Web shows a run card. Phases: layers (P0), structure (P1), pixel + open MCP (P2).

### Decisions

- **v1 edit scope (D1)** → Layers + pixel edits overall; **P0 = layers only**.
- **Confirmation (D2)** → Layer edits run automatically. Anything that spends credits (P1/P2) shows a plan card first.
- **Unstated targets (D3)** → The agent proposes targets through the existing question card ("Apply to which boards?": *Continue* / *Active board only* / *All boards*). When the user names the targets, the edit runs directly.
- **Entry point (D4)** → Inside the existing KV chat, behind the flag `kv-agentic-canvas`. No separate Agent mode.
- **Structural edits (D5)** → Add sizes, variant boards (P1); remove layers (P0).
- **Execution architecture (D6)** → Server-executed (deck pattern), MCP-ready.
- **PRD split (2026-10-18)** → p0/p1/p2 sub-features, each with its own branch/PR.
- **Wireframe (2026-10-18)** → One small wireframe `kv-agent-cards` (run card, tool chips, target question card inside a static KV chat panel).
- **Agent model (2026-10-18)** → Decided by eval (FR-14). The default stays until the eval passes.
- **collab review (2026-10-18)** → Reviewed inside the team (daffa + Claude); no external owner sign-off required.
- **Branch strategy (2026-10-18)** → See "Assumptions and Clarifications".
- **Composability (2026-10-18)** → P0 builds the canvas tools surface-agnostic, following AskFRND/deck tool practice (FR-25..FR-30), but mounts them only in the KV chat. AskFRND mount moves to p2 together with opening MCP (it needs an AskFRND run card and run settling on the AskFRND stream). Shared primitives are created now and used by KV; deck/proposal-step migrate in a separate PR coordinated with Jeff (deck_tools.py is under active change, with thin test coverage).

## User Stories

- As a KV user, I want to type "change the headline to *Ramadan Sale 50%* on every size" and have every board and size updated, so I don't edit each surface by hand.
- As a KV user, when I don't say where, I want the AI to propose the targets and let me confirm, so it never edits boards I didn't mean.
- As a KV user, I want a summary of exactly what changed and what was skipped (and why), so I can trust the result.
- As a KV user, I want one button that undoes the whole AI run without overwriting edits I made afterwards, so trying the AI is safe.
- As a KV user, I want to click a target in the summary and jump to that board/size on the canvas, so I can check the change.
- As a collaborator with the same file open in another tab, I want the AI's edits to appear live, so we don't fork the file.
- As an external MCP client user (P2 opens access), I want the same tools to behave exactly like the in-app agent.

## Requirements

### Functional Requirements

**Inventory**

- **FR-1:** When `kv-agentic-canvas` is on for the user, the file is a KV file, `canvas_mode = craft`, and `mode = chat`, api builds a canvas inventory and sends it to ai-service as `agent_canvas {run_id, file_id, inventory}`. In every other case the field is absent and chat behaves exactly as today.
- **FR-2:** The inventory lists boards (`board_id` = tip generation id, name, `is_master`, size, image), layers per board (`layer_id`, type, normalised `rect`, `z`, `text` ≤200 chars, whitelisted `style`, `image_kind`), and each board's resize sizes (`size_id`, preset, size, status, `mode` inherit|detached, `overrides` for detached). It also carries the active board, size, and selected layers.
- **FR-3:** Caps: 30 boards, 50 sizes per board, 60 layers per surface (highest-z kept). A `truncated` flag is set and the prompt notes it. `get_kv_canvas(board_id)` reads one board in full.
- **FR-4:** User-authored strings (layer text, names) are sanitised (control chars, fences, backticks, quotes) and rendered inside a fenced `<kv_canvas_state>` block that is labelled as data, not instructions.

**Layer tools** (api `v1/mcp/tools/kv/canvas/*`, MCP twins of the same name)

- **FR-5:** `get_kv_canvas`, `update_kv_layers`, `add_kv_layer`, `remove_kv_layers`, `undo_kv_agent_run`, with shapes as defined in contracts C3.
- **FR-6:** Every write takes explicit `targets {board_ids, size_ids, include_sizes}`. Empty targets → 422 `targets_required`. More than 60 targets after expansion → 422 `too_many_targets`. There is no implicit "everything".
- **FR-7:** A board target edits that board's layer. Its **inheriting** sizes follow by re-projection. `include_sizes: true` also writes the board's **detached** sizes. Targeting an inheriting size alone detaches it first (snapshot of its resolved layers, taken after the write), then applies the edit; the size is listed in `detached_sizes`.
- **FR-8:** `set` merges into the payload by top-level key (it does not replace the whole payload). `set.text` on a text layer with per-run styling collapses the runs into one run carrying the first run's style. `set.visible` maps to `payload.hidden`. Allowed payload keys are exactly what `UpdateStudioFileOverlaysRequest` accepts; no new overlay properties are introduced.
- **FR-9:** `add_kv_layer` supports text, image (`brand_logo` or an `asset_url` on the platform bucket), and shape. Placement uses a 9-point anchor + margin + width fraction, resolved per surface. The api mints the layer id: the first board and all its sizes share one id; each additional board gets its own id.
- **FR-10:** Every write result is `{run_id, applied[], skipped[{target, layer_id, reason, detail?}], detached_sizes[]}` with HTTP 200 even when everything was skipped. Reasons: `layer_changed`, `layer_not_found`, `layer_absent_on_size`, `target_not_found`, `collab_unavailable`, `invalid_payload`, `run_op_cap_reached`.

**Execution and consistency**

- **FR-11:** Board writes go through collab `POST /internal/kv-files/{id}/ops`: all ops are validated first, then run in one `doc.transact(…, SERVER_WRITE_ORIGIN)` (all or nothing), with compare-and-set on `expected`. Open browsers receive the change as a remote Y update. After a write, collab materialises overlays to api (`POST internal/kv-files/{id}/overlays` through `StudioOverlayNormalizer`), so REST readers (export, resize) see agent edits even when no browser has the file open.
- **FR-12:** A per-file write lock (`kv-canvas-write:{fileId}`, TTL 90 s, wait ≤20 s; otherwise 409 `write_in_progress`). Only one running agent run per file (409 `run_in_progress`). Max 200 ops per run. A write that would push the file past 300 layers is refused whole (422 `too_many_layers`).

**Run ledger and undo**

- **FR-13:** `kv_agent_runs` stores every op with its pre-image and post-image. In-app runs use the chat turn's `run_id` (ULID minted by api); MCP runs are created on the first write. A run becomes `completed` when the chat turn ends (MCP: after 10 min idle).
- **FR-14 (eval):** A golden set of 10–15 instructions on a fixture file is scored on correct tool + correct targets for each candidate model (current default `conversation` tier vs Claude Haiku vs GPT tier). Pass threshold: ≥90% correct tool + exact targets, and 0 writes on unstated-target prompts. The model is switched for flagged turns only if the default fails.
- **FR-15:** Undo (`POST v1/studio/files/{file}/agent/runs/{run}/undo` and the `undo_kv_agent_run` tool) replays ops newest-first with compare-and-set. A layer the user changed after the run is **not** overwritten and is reported as `changed_after_run`. Undo is idempotent (`already_undone`). An in-app run still `running` → 409. A collab outage → 503 and nothing is reverted.
- **FR-16:** Agent edits are not on the browser's ⌘Z stack (remote origin). The run card's Undo is the only undo for an agent run.

**Chat behaviour**

- **FR-17:** The agent runs with canvas tools only on flagged craft chat turns, with the shared `AGENT_TOOL_CALL_LIMIT` tool budget unless the FR-14 eval shows a lower cap is needed. Existing chat behaviours (image generation, region edit, question cards, mode suggestions) are unchanged. `suggest_mode_switch` remains only for pixel changes.
- **FR-18:** When the user did not say where, the agent must ask through `present_question_card` ("Apply to which boards?": Continue / Active board only / All boards) and makes no writes that turn.
- **FR-19:** The agent's closing text is based on tool results. A deterministic honesty footnote (no second model call) is appended when the text claims a change api did not accept, or ignores skipped targets.
- **FR-20:** ai-service emits `{event: "kv_agent_run", run_id}` once before `done` when at least one write was applied. api relays it as the SSE frame `kv_agent_run` and stores `agent_run_id` on the assistant message, so the run card survives reload.

**Composability (AskFRND tool practice)**

- **FR-25:** `make_kv_canvas_tools` binds only turn context (`user_id`, `workspace_id`, `run_id`, ledger, optional default `file_id`/`active`). `file_id` is an optional per-call argument on every tool, matching the MCP twin schema, so any agent can mount the tools.
- **FR-26:** The write ledger implements a shared `WriteLedger` contract (`app/tools/write_ledger.py`: `attempts`, `has_accepted`, `last_problem`, `record()`, `footnote(answer)`) and registers in a ContextVar registry (`bind_ledger`, `active_ledgers`, `reset_ledgers`), so a router or team member can find it without plumbing.
- **FR-27:** Write-claim/skip-ack wording lives in one bilingual (EN+ID) lexicon module that the KV footnote uses. `safe_error_detail` is public in `app/utils/safe_error.py`; deck keeps a re-import until its migration PR.
- **FR-28:** Chip labels come from ai-service `TOOL_NAME_ENUM` + `TOOL_ICONS` (5 entries). Result shaping lives in `app/utils/kv_canvas_tool_result.py` and is used by `_trim_tool_result`. The web `KV_AGENT_TOOL_LABELS` map is deleted.
- **FR-29:** No reverse layering: `app/tools/kv_canvas_tools.py` imports nothing from `app/agents/*`. Inventory rendering moves to `app/utils/kv_canvas_state.py` and uses `app/utils/prompt_fence` (nonce fence).
- **FR-30:** The "ask where first" gate is a surface-agnostic `turn_closed` callable passed to the factory (as research/social tools do), not a dependency on the KV-panel `present_question_card` shim. `targets_required` error text names no surface-specific tool.

**Web**

- **FR-21:** Tool calls render as chips with human labels (e.g. "Changing headline · Concept A + 3 sizes").
- **FR-22:** The run card under the assistant turn shows applied targets (✓), skipped targets with plain-language reasons (⚠), sizes that became detached ("9:16 now has its own layers"), and an **Undo run** button with a confirmation and a result line (reverted N, skipped M). Clicking a target focuses that board/size on the canvas.
- **FR-23:** After a run that touched sizes, and after undo, web refetches `resizeExportsQueryKey(fileId)`. A tile Textbox repaints when its source text changes.
- **FR-24:** PostHog events: `kv_agent.run_completed` (op/target counts, source), `kv_agent.run_undone`, `kv_agent.run_undo_failed`, `kv_agent.run_target_focused`.

### Non-Functional Requirements

- **NFR-1 (flag, fail-closed):** `feature.flag:kv-agentic-canvas,off` on api tool and user routes. The flag defaults to off wherever middleware cannot see the call (MCP gateway, chat stream). Flag off = today's chat, byte for byte.
- **NFR-2 (security):** Tool routes use `ResolveToolContext` (`X-Internal-Token` + `user_id` + `workspace_id`, ULID `agent_run_id`) and re-check file access on every call (BOLA). collab routes use constant-time token compare, zod bodies, and a 2 MB cap. `asset_url` must be on the platform bucket. Layer text is untrusted prompt data (FR-4). api error `detail` text is sanitised before it reaches the footnote.
- **NFR-3 (atomicity):** No partially applied batch within one sink. If a tile write fails after a doc write, it becomes a per-target skip, never a 500 that hides an applied change.
- **NFR-4 (timeouts):** api → collab `/ops` timeout ≥15 s. ai-service tool read timeout 100 s (130 s for undo), so an applied write is never reported as failed.
- **NFR-5 (latency):** Target ≤10 s from tool call to the change showing in an open browser for a ≤20-target edit [target, to be measured in e2e].
- **NFR-6 (credits):** P0 layer ops are free. LLM tokens use the existing "KV AI Chat" metering.
- **NFR-7 (MCP parity):** `php artisan mcp:verify-mirror` passes. Twins live in `FrndosServer`; no logic exists only in prompts.

## Service Breakdown

### collab (`frnd-hocuspocus`)

- `GET /internal/kv-files/{id}/document` (read-only live doc JSON) and `POST /internal/kv-files/{id}/ops` (`set_layer`, `add_layer`, `remove_layer`; atomic; CAS; pre-images).
- Backfill from `studio_files.overlays` for a doc with no overlays, so the first agent write cannot wipe a never-opened file.
- Overlay materialisation to api after each successful write (3 s/try, bounded retries).
- Built: `src/applyKvOps.ts`, `readKvDocument.ts`, `kvOverlays.ts`, `kvPersistedOverlays.ts`, `kvHttp.ts`, `http.ts`, `routes.ts`, `snapshot.ts`.

### API (`api/`)

- Extract `StudioOverlayNormalizer` from `StudioFileController::updateOverlays`; internal overlays route (C2).
- `KvCollabWriter`, `KvCanvasContextAssembler` + `KvCanvasState` (inventory), `KvCanvasEditService` (sink routing, detach), `KvLayerPatch/Diff/Placement/Shape`, `KvLayerAssetResolver`, `KvTileOverlayProjector` (PHP port of web `resolveTileOverlays`, fixtures generated from the TS), `KvCanvasWriteLock`.
- `kv_agent_runs` migration + `KvAgentRun`; `KvAgentRunRecorder` / `KvAgentRunReverter`.
- `KvCanvasToolController` + 5 MCP twins; `KvAgentRunController` (run view, undo).
- `ChatService::streamKvGenerator` / `KvAgentCanvasTurn`: mint the run, attach `agent_canvas`, relay `kv_agent_run`, persist `agent_run_id`, settle the run on `done`.

### Frontend (`web/`)

- `useKvStream`: `kv_agent_run` frame + reload hydration.
- `KvAgentRunCard`, `kvAgentRunCopy`, `kvAgentToolLabels`, `kvAgentFocus`, `types/kv/agentRun.ts`, API client in `services/kv/api.ts`, `kv-agent-events.ts`, flag constant.
- `useOverlayReconcile`: tile text repaint.

### AI Service (`ai-service/`)

- `KvStreamRequest.agent_canvas`; `kv_agent_run` event.
- `canvas_context_prompt.py` (`<kv_canvas_state>` + `KV_CANVAS_GUIDANCE`).
- `app/tools/kv_canvas_tools.py` (tool wrappers, `KvCanvasWriteLedger`, `kv_canvas_footnote`, gated question card).
- `_run_chat_mode` wiring, chips, footnote on the normal and retry paths. Tool budget `AGENT_TOOL_CALL_LIMIT` (shared default) unless the eval shows a lower cap is needed.
- Composability (FR-25..FR-30): `app/tools/write_ledger.py`, `app/utils/safe_error.py`, `app/utils/kv_canvas_state.py`, `app/utils/kv_canvas_tool_result.py`, `TOOL_NAME_ENUM`/`TOOL_ICONS` entries, per-call `file_id`, `turn_closed` gate.
- Eval harness for FR-14.

### Data Service (`data-service/`)

No changes.

## UI/UX

### Key Screens

Wireframe `kv-agent-cards` at `web/src/app/(dashboard)/wireframes/kv-agentic-canvas-p0/kv-agent-cards/`. It shows a static KV chat panel with these states:

1. **Target question card** — "Apply to which boards?" with Continue (suggested targets), Active board only, All boards.
2. **Tool chips** — started / completed / failed, e.g. "Reading canvas", "Changing headline · Concept A + 3 sizes".
3. **Run card: all applied** — grouped by board, then sizes; summary line; Undo run.
4. **Run card: mixed** — applied + skipped with reasons + a "now has its own layers" detached note.
5. **Run card: undo confirm → undone** — confirmation text ("Credits already spent are not refunded" is not shown in P0, since layer runs are free); result "Reverted 7 · 1 kept because you edited it".
6. **Run card: undo failed / still running / loading skeleton**.
7. **Honesty footnote** under the assistant text.

Interactions: clicking a target row focuses the canvas on that board/size; the Undo button is disabled while the run is running or the undo is in progress.

## Data Model

### New Tables

`kv_agent_runs`:

| column | type |
|---|---|
| `id` | ULID PK (= `run_id`) |
| `studio_file_id` | FK `studio_files` |
| `user_id`, `workspace_id` | FKs |
| `source` | `app` \| `mcp` |
| `status` | `running` \| `completed` \| `undone` \| `failed` |
| `ops` | jsonb `[]`, atomic append `{type, sink: doc\|tile, target, layer_id, before, after, at}` |
| `skipped` | jsonb `[]` |
| `detached_sizes` | jsonb `[]` |
| `undo_result` | jsonb nullable |
| timestamps | |

### Modified Tables

- Chat message rows for KV threads: the assistant message gets `agent_run_id` (in the existing metadata where generation ids and cards are stored; no column change).
- `studio_files.overlays`: now also written by collab materialisation (same normaliser as the browser PATCH).
- `kv_resize_exports.overlays`: may switch from `null` (inherit) to a snapshot (detached) because of an agent write.

## API Endpoints

| Method | Endpoint | Description | Service |
|--------|----------|-------------|---------|
| GET | `/internal/kv-files/{id}/document` | Live KV doc as JSON | collab |
| POST | `/internal/kv-files/{id}/ops` | Atomic layer op batch, CAS, pre-images | collab |
| POST | `internal/kv-files/{studioFile}/overlays` | Materialise overlays from collab | api |
| GET | `v1/mcp/tools/kv/canvas/{fileId}` | Inventory (`get_kv_canvas`) | api |
| POST | `v1/mcp/tools/kv/canvas/{fileId}/layers/update` | `update_kv_layers` | api |
| POST | `v1/mcp/tools/kv/canvas/{fileId}/layers/add` | `add_kv_layer` | api |
| POST | `v1/mcp/tools/kv/canvas/{fileId}/layers/remove` | `remove_kv_layers` | api |
| POST | `v1/mcp/tools/kv/canvas/runs/{runId}/undo` | `undo_kv_agent_run` | api |
| GET | `v1/studio/files/{file}/agent/runs/{run}` | Run view for the card | api |
| POST | `v1/studio/files/{file}/agent/runs/{run}/undo` | User undo | api |
| POST | `/ai/kv-generator/stream` (modified) | Accepts `agent_canvas`, emits `kv_agent_run` | ai-service |
| POST | `v1/threads/{id}/stream` (modified) | Relays SSE `kv_agent_run` | api |

## Existing System Reconciliation

- **Deck agent pattern is reused, not reinvented:** `DeckCollabWriter`, `deck_agent_runs`, `DeckAgentRunReverter`, `DeckRunCard`, `DeckWriteLedger`/`ledger_footnote`. P0 mirrors each one for KV.
- **Overlay persistence was browser-only** (full-replace `PATCH studio/files/{id}/overlays` from `useDebouncedOverlaySave`). A server write to the column alone would be erased by any open tab, so writes go into the live Y.Doc. A stale tab can briefly overwrite, then re-saves from the converged doc (accepted).
- **Resize tiles are REST rows** (`KvResizeExport`). There is no live master→tile cascade for detached tiles; P0 writes them through `KvResizeExportService`. There is no realtime channel for resize exports, so other tabs update on their next refetch.
- **`kv-resize-unified-canvas`** (alva, in progress on `feature/alva/vc-kv-fabric-export`) changes how tiles render on the Craft canvas, not their data. Rebase must reconcile `useOverlayReconcile.ts` and the focus wiring in `KvGeneratorLayout.tsx` with that work.
- **KV chat model:** the `conversation` tier defaults to `deepseek-flash`, with vision fallbacks. Multi-target planning quality is unproven → FR-14.
- **`/ai/kv-generator/complete`** (MCP `generate_kv`) never carries `agent_canvas`.

## Assumptions and Clarifications

- **Branch strategy (best practice):** the existing branches are local-only and unshared, so rebasing is safe and gives a clean, reviewable history (squash merge at the end anyway). Steps:
  1. Push the current `feature/daffa/vc-kv-agentic-canvas` in all four repos as a backup.
  2. At `branch_creation`, cut `feature/daffa/vc-kv-agentic-canvas-p0` from the latest `develop` / `development` / `main`.
  3. Rebase the P0 commits onto it, show the conflict list for review before resolving, and re-run each repo's verification.
  
  Merging base into the branch is rejected: it carries 700–1100 commits of noise into the review.
- The code on the branch was written before this PRD. It is treated as a candidate implementation and audited task by task against this PRD during `implementation`, not assumed done.
- The P0 web surface is chat-only; no canvas UI changes beyond focus and tile text repaint.
- The flag stays off in production until FR-14 passes and the manual e2e (AC-9) is done.

## Acceptance Criteria

- [ ] AC-1: Flag off → a KV chat turn sends no `agent_canvas`, registers no canvas tools, and behaves as today.
- [ ] AC-2: "Change the headline to X on every size" on a file with 2 boards × 3 sizes (1 detached) updates both boards, the inheriting sizes re-project, the detached size is written, and the run card lists every target ✓.
- [ ] AC-3: "Only on 9:16, move the headline up" on an inheriting size detaches that size, edits it, leaves the other sizes unchanged, and the card shows the detached note.
- [ ] AC-4: An instruction with no stated target produces the "Apply to which boards?" card and no writes that turn. Choosing an option then runs the write.
- [ ] AC-5: "Add the brand logo bottom-right" adds a logo layer on each target with correct per-surface placement. A file without a brand logo → the agent reports it, nothing is written.
- [ ] AC-6: A write while another tab edits the same layer in the api-read→collab-write window → `layer_changed` skip, reported in plain words.
- [ ] AC-7: Undo reverts all agent ops. A layer the user edited after the run is kept and reported. A second undo → `already_undone`.
- [ ] AC-8: With the file open nowhere, an agent write is visible in REST `studio_files.overlays` and in the next browser open.
- [ ] AC-9: Manual e2e: two tabs open at once see the change live; the run card survives reload; clicking a target focuses it.
- [ ] AC-10: A reply claiming a change api skipped gets the honesty footnote.
- [ ] AC-11: `mcp:verify-mirror` passes; the 5 MCP twins return the same results as the tool routes.
- [ ] AC-12: The FR-14 eval report is committed with per-model scores, and the chosen model is recorded.
- [ ] AC-13: `app/tools/kv_canvas_tools.py` has no `app.agents` import; the tools work when built with only `user_id`/`workspace_id`/`run_id`/ledger and a per-call `file_id` (throwaway script against a fixture file); chips show `TOOL_NAME_ENUM` labels with the web label map removed.

## Open Questions

- [x] Q-1: Eval pass threshold → ≥90% correct tool + exact targets on the golden set, 0 writes on unstated-target prompts (daffa, 2026-10-18).
- [ ] Q-2: Are 200 ops/run and 60 targets/call the right limits once MCP opens (P2)?
- [ ] Q-3: Accept the known P0 limitations? A stale tab can overwrite agent writes to detached sizes; layer-decomposition commits race with agent writes; an MCP run blocks in-app runs on the same file for up to 10 min.
- [ ] Q-4: Rollout cohort for the flag (internal workspace first?).
