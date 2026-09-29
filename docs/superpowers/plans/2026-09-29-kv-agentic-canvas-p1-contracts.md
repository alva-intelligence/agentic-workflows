# KV Agentic Canvas P1 — Cross-Service Contracts

**Spec:** `docs/superpowers/specs/2026-09-29-kv-agentic-canvas-design.md`
**Phase:** P1 (foundation + layer tools). Board ops, plans, sizes and pixel edits are P2/P3 and are NOT in these contracts.

This file is the single source of truth for every name, route and payload that crosses a service boundary in P1. The four per-repo plans implement against it and must not rename anything here. If a plan finds a contract field impossible, it records the problem in its "Contract deviations" section instead of silently changing it.

Plans:
- `2026-09-29-kv-agentic-canvas-p1-collab.md` (frnd-hocuspocus, `collab/`)
- `2026-09-29-kv-agentic-canvas-p1-api.md` (`api/`)
- `2026-09-29-kv-agentic-canvas-p1-ai-service.md` (`ai-service/`)
- `2026-09-29-kv-agentic-canvas-p1-web.md` (`web/`)

Branch in every repo: `feature/daffa/vc-kv-agentic-canvas`, cut from the repo's default branch (`develop` for api/web, `development` for ai-service, `main` for collab).

Build order (each repo is testable alone with fakes): collab → api → ai-service → web.

## Deliberate simplification vs. the spec (recorded)

Spec §7.1 says the write-time compare-and-set `expected` is "what the agent read". In P1 the api builds `expected` from its own fresh read of the live document immediately before writing (the same read that produces the ledger pre-image). This closes the api-read→collab-write race and gives exact pre-images; it does not protect a field the user changed between the start of the turn and the tool call (that behaves like two collaborators editing). Undo-time CAS (spec §8.2) is unchanged and is where user work is protected. The spec gets a one-line note when the api plan lands.

---

## C0. Shared vocabulary

- **Layer** = one overlay. Web type `StudioOverlay` (`web/src/types/studio.ts:681`); Y.Doc overlay map `{id, type, rect:Y.Map{x,y,width,height,rotation}, z, payload:Y.Map, board_generation_id}` (`web/src/lib/kv/yjsDoc.ts`, `yjsSerializer.ts:34`).
- **Board id** = the board's current tip generation id (the key in `boards`). Any id in a board's `versionIds` resolves to that board.
- **Size id** = a `KvResizeExport` id.
- **Target** = a board id or a size id.
- **Layer JSON** (used on the wire between collab and api), flat rect, exactly the web doc shape:

```jsonc
{ "id": "01J…", "type": "text", "rect": { "x": 0.1, "y": 0.1, "width": 0.5, "height": 0.1, "rotation": 0 },
  "z": 3, "payload": { /* type-specific, plain JSON */ }, "board_generation_id": "…" | null }
```

## C1. collab HTTP routes (called by api only)

Auth: header `X-Internal-Token` (constant-time compare, existing `internalTokenOk`). 401 on mismatch. Body cap 2 MB. Doc name `kv_file:{studioFileId}`.

### C1.1 `GET /internal/kv-files/{fileId}/document`

Read-only (no transact, no store, no snapshot). Works when no browser has the doc open.

200:
```jsonc
{ "document": {
    "meta": { "schemaVersion": 2, "masterGenerationId": "…" | null },
    "boards": { "<tipId>": { "x": 0, "y": 0, "name": "…" | null, "versionIds": ["…"] } },
    "overlays": [ /* Layer JSON, doc order */ ],
    "removed": ["…"] } }
```

### C1.2 `POST /internal/kv-files/{fileId}/ops`

Request:
```jsonc
{ "run_id": "01J…" | null,
  "ops": [   // 1..200
    { "kind": "set_layer", "layer_id": "…",
      "set": { "rect"?: { "x"?, "y"?, "width"?, "height"?, "rotation"? }, "z"?: 3,
               "payload"?: { /* top-level payload keys to replace; others kept */ } },
      "expected"?: { "rect"?: {…}, "z"?: 3, "payload"?: { /* same key subset */ } } },
    { "kind": "add_layer", "layer": { /* Layer JSON; id required, must not exist */ } },
    { "kind": "remove_layer", "layer_id": "…", "expected"?: { /* as above */ } }
  ] }
```

Semantics:
- All ops validated first; then ONE `doc.transact(fn, SERVER_WRITE_ORIGIN)`. Any failure → nothing written.
- `payload` merge is shallow by top-level key: each key in `set.payload` replaces that key's value; keys not mentioned are untouched. A key set to `null` is deleted.
- `expected` comparison: for every key present in `expected`, deep-equal against the current value (rect by field, payload by top-level key). Keys absent from `expected` are not compared.
- After a successful transact, collab materialises overlays to the api (C2) and awaits the result (bounded by the existing snapshot timeout/retry rules). A materialisation failure does NOT roll back the write; it is reported as `materialized: false`.

200:
```jsonc
{ "applied": [ { "kind": "set_layer", "layer_id": "…" } ],
  "before": { "layers": { "<layer_id>": /* Layer JSON before the op, or null for add_layer */ } },
  "materialized": true }
```

Errors (JSON body `{ "error": code, ... }`):
| Status | code | extra fields |
|---|---|---|
| 409 | `layer_changed` | `layer_id`, `expected`, `current` |
| 404 | `layer_not_found` | `layer_id` |
| 409 | `layer_exists` | `layer_id` (add_layer with an existing id) |
| 422 | `invalid_body` | `issues` (zod) |
| 422 | `too_many_ops` | `max: 200` |
| 401 | `unauthorized` | — |
| 400 | `invalid_json` | unreadable or oversized body |
| 500 | `ops_failed` / `read_failed` | unexpected failure — api maps to `collab_unavailable` |

Amendments from the collab plan (binding):
- The doc key inside each overlay Y.Map is `boardGenerationId`; the wire (Layer JSON) keeps `board_generation_id`.
- Payload values in the doc are plain JSON (never nested Y types); `set.payload` edits the existing payload Y.Map per key.
- `before` for a layer touched twice in one batch = its state before the whole batch.
- An `expected` payload value of `null` matches an absent key; a 409 `current` reports an absent key as `null`.
- Duplicate layer ids in a doc: edits hit the first copy; `remove_layer` removes every copy.
- A doc with no overlays is backfilled from `studio_files.overlays` on read, and the first ops write pushes that backfill into the doc in the same transaction (mirrors web's recovery rule), so a never-opened file cannot be wiped by the first agent write.
- Collab does NOT validate payload keys or rect ranges: the api validates every layer as it will look after the op before calling `/ops`.
- The overlay POST (C2) is attempted with a 3 s timeout per try (worst case ≈ 9.75 s), so the api's timeout on `POST /ops` is **≥ 15 s**.
- Unsaved browser layers (`tmp_…` ids) are omitted from the C2 list.

## C2. api internal route (called by collab only)

`POST {API_BASE_URL}/internal/kv-files/{studioFile}/overlays` — sibling of the existing `internal/kv-files/{studioFile}/snapshot` route (`api/routes/api.php:6556`), same `RequireInternalToken` group.

Request: `{ "overlays": [ /* Layer JSON, full list for the file, doc order */ ], "source": "agent_write" }`
- api converts Layer JSON → the stored overlay row shape (`x,y,width,height,rotation` flattened from `rect`) and runs it through `StudioOverlayNormalizer` — the same validation + stamping as `PATCH studio/files/{id}/overlays` (`StudioFileController::updateOverlays`), so no payload key is stripped or added differently.
- Full replace of `studio_files.overlays` (same as the browser PATCH).

200 `{ "count": 12 }` · 422 validation (same messages as the browser PATCH) · 404 unknown file.

## C3. api tool routes (called by ai-service; mirrored to MCP)

Mounted in the existing `mcp/tools` group next to `kv/files` (`api/routes/api.php:~6182`), same middleware (`ResolveToolContext`: `X-Internal-Token` + `user_id` + `workspace_id`, optional `agent_run_id` ULID), plus `feature.flag:kv-agentic-canvas`.

| Method | Path | Controller method | MCP twin (FrndosServer) |
|---|---|---|---|
| GET | `kv/canvas/{fileId}` | `KvCanvasToolController::show` | `get_kv_canvas` |
| POST | `kv/canvas/{fileId}/layers/update` | `::updateLayers` | `update_kv_layers` |
| POST | `kv/canvas/{fileId}/layers/add` | `::addLayer` | `add_kv_layer` |
| POST | `kv/canvas/{fileId}/layers/remove` | `::removeLayers` | `remove_kv_layers` |
| POST | `kv/canvas/runs/{runId}/undo` | `::undoRun` | `undo_kv_agent_run` |

### C3.1 Targets

```jsonc
{ "board_ids": ["…"], "size_ids": ["…"], "include_sizes": true }
```
At least one of `board_ids`/`size_ids` non-empty (422 `targets_required` otherwise). Max 60 targets after expansion (422 `too_many_targets`).
- A board target writes the board's layer in the doc. Inheriting sizes of that board follow automatically (they re-project).
- `include_sizes: true` additionally writes every **detached** size of each targeted board.
- A size id target writes that size: detached → its overlay list; inheriting → detach first (snapshot of its resolved layers), then write; the size is listed in `detached_sizes`.

### C3.2 Inventory — `GET kv/canvas/{fileId}`

Query: optional `active_board_id`, `active_size_id`, `selected_layer_ids[]` (the in-app path passes these; MCP omits them).

200 — exactly spec §5:
```jsonc
{ "file": { "id": "…", "name": "…", "brand": "…" | null },
  "active": { "board_id": "…" | null, "size_id": "…" | null, "selected_layer_ids": [] },
  "boards": [ {
      "board_id": "…", "name": "…" | null, "is_master": true,
      "width": 1080, "height": 1350, "image_url": "…",
      "layers": [ { "layer_id": "…", "type": "text", "rect": { "x":0, "y":0, "w":0, "h":0, "rotation":0 }, "z": 0,
                    "text": "…" | null, "style": { /* text payload keys, verbatim names */ } | null,
                    "image_kind": "logo" | "product" | "upload" | null } ],
      "sizes": [ { "size_id": "…", "preset": "…" | null, "width": 1080, "height": 1920,
                   "status": "…", "mode": "inherit" | "detached",
                   "overrides": [ /* layers (same item shape) that differ from the board; [] when inherit */ ] } ] } ],
  "truncated": { "boards": false, "sizes": false, "layers": false } }
```
Caps: 30 boards, 50 sizes/board, 60 layers/surface, `text` ≤ 200 chars. `style` uses the text payload's own key names (whitelisted to the keys `UpdateStudioFileOverlaysRequest` accepts) so no mapping table exists anywhere.

### C3.3 Write result (all three layer tools)

```jsonc
{ "run_id": "01J…",
  "applied": [ { "target": "…", "layer_id": "…", "op": "set_layer" | "add_layer" | "remove_layer" } ],
  "skipped": [ { "target": "…", "layer_id": "…" | null, "reason": "<reason>" } ],
  "detached_sizes": ["…"] }
```
`reason` ∈ `layer_changed`, `layer_not_found`, `layer_absent_on_size`, `target_not_found`, `collab_unavailable`, `invalid_payload`, `run_op_cap_reached`.
HTTP 200 even when everything is skipped (the agent reads `skipped`). 409 `run_in_progress` when another run holds the file lock. 409 `run_undone` when writing to an undone run.

### C3.4 `POST …/layers/update`

```jsonc
{ "edits": [ { "layer_id": "…", "targets": { /* C3.1 */ },
               "set": { "text"?: "…", "style"?: { /* payload keys */ },
                        "rect"?: { "x"?, "y"?, "w"?, "h"?, "rotation"? }, "visible"?: true, "z"?: 3 } } ] }
```
- `text` on a text layer: replaces the text; if the payload has per-run styling, the runs collapse into one run carrying the first run's style.
- `rect` uses `w`/`h` on this interface (inventory shape) and maps to `width`/`height` internally.
- `visible` maps to the payload's existing visibility key if one exists; if the overlay model has none, the api returns 422 `unsupported_field: visible` (P1 does not invent a key — the api plan decides which by reading the type).

### C3.5 `POST …/layers/add`

```jsonc
{ "targets": { /* C3.1 */ },
  "layer": { "type": "text" | "image" | "shape",
             "text"?: "…", "style"?: { /* text payload keys */ },
             "image"?: { "source": "brand_logo" | "asset_url", "url"?: "…" },
             "shape"?: { /* shape payload keys */ } },
  "placement": { "anchor": "top_left" | "top_center" | "top_right" | "middle_left" | "center" | "middle_right" | "bottom_left" | "bottom_center" | "bottom_right",
                 "margin": 0.04, "width": 0.2 } }
```
- One new layer id (ULID, minted by api) shared by every target, so later edits address it as one layer across sizes.
- `asset_url` must pass the existing trusted-asset host check; otherwise 422 `untrusted_asset_url`. `brand_logo` resolves the file's brand logo; none → 422 `no_brand_logo`.
- Rect per target surface = anchor + margin (fraction of the surface's shorter side) + width (fraction of surface width); height from the asset's intrinsic aspect (image) or a single-line height from the text style (text).

### C3.6 `POST …/layers/remove`

`{ "layer_ids": ["…"], "targets": { /* C3.1 */ } }`

### C3.7 `POST kv/canvas/runs/{runId}/undo`

200 `{ "status": "undone" | "already_undone", "reverted": 7, "skipped": [ { "target": "…", "layer_id": "…", "reason": "changed_after_run" | "layer_not_found" | "collab_unavailable" } ] }`
409 `run_in_progress` while the run is `running`.

### C3.8 Run id for MCP callers

If `agent_run_id` is absent on a write tool, the api creates a run with `source = mcp` and returns its id in `run_id`; a caller passes it back as `agent_run_id` to group later calls.

## C4. api ↔ ai-service KV stream

api `ChatService::streamKvGenerator` adds one optional field to the body sent to ai-service `/ai/kv-generator/stream` (and `/complete`):

```jsonc
"agent_canvas": { "run_id": "01J…", "file_id": "…", "inventory": { /* C3.2 */ } } | null
```
Present only when: flag `kv-agentic-canvas` is on for the user, the file is a KV file, `canvas_mode == "craft"`, and `mode == "chat"`. The inventory is built with the request's `base_generation_id` as `active_board_id` and `editing_board_*`/selection when available.

ai-service (`KvStreamRequest`) accepts `agent_canvas`. When present, the chat-mode agent is built with the canvas tools bound to `run_id`, `file_id`, `user_id`, `workspace_id`.

New NDJSON event emitted by ai-service **once, just before `done`**, only if at least one canvas write tool was accepted by the api during the turn:
```jsonc
{ "event": "kv_agent_run", "run_id": "01J…" }
```
(Amended by the ai-service plan: every KV NDJSON frame is keyed by `event`, and `ChatService` switches on `$parsedData['event']`. The api→web SSE frame is still named `kv_agent_run`. `workspace_id` travels at the body root, as today; without it ai-service treats `agent_canvas` as absent.)
Tool calls continue to use the existing `tool_call` event (status started/completed/failed); tool names are the MCP twin names from C3 (`get_kv_canvas`, `update_kv_layers`, `add_kv_layer`, `remove_kv_layers`, `undo_kv_agent_run`).

api relays the event to web as the SSE frame `kv_agent_run` with the same body, and persists `agent_run_id` on the assistant message it stores for the turn (same place generation ids / cards are stored) so the run card survives reload.

## C5. api user routes (web, JWT)

Group: existing studio routes (`scope_role:internal`, `feature.flag:show-kv-generator`) + `feature.flag:kv-agentic-canvas`.

| Method | Path | Result |
|---|---|---|
| GET | `v1/studio/files/{file}/agent/runs/{run}` | run view (below) |
| POST | `v1/studio/files/{file}/agent/runs/{run}/undo` | C3.7 body |

Run view:
```jsonc
{ "id": "01J…", "status": "running" | "completed" | "undone" | "failed", "source": "app" | "mcp",
  "created_at": "…",
  "applied": [ { "target": "…", "target_kind": "board" | "size", "target_label": "Concept A · Instagram Story", "layer_id": "…", "op": "set_layer" } ],
  "skipped": [ { "target": "…", "target_kind": "board" | "size", "target_label": "…", "layer_id": "…" | null, "reason": "…" } ],
  "detached_sizes": [ { "size_id": "…", "label": "…" } ],
  "undo": { "reverted": 7, "skipped": [ … ] } | null }
```

Amendments from the web plan (binding):
- C5 responses use the api's wrapped form `{ "message": "…", "data": <body above> }`.
- The `kv_agent_run` frame arrives after the assistant message row is saved: api updates that row with `agent_run_id`, includes `agent_run_id` on each `chat_history` entry web hydrates, and creates the assistant row even when the turn's text is empty but a run exists.
- Text content lives in `payload.content`; C3.4 `set.text` writes it and the inventory `text` reads it.
- Web owns tool-chip labels; ai-service sends raw tool names and JSON `tool_result`.
- PostHog events are dot-namespaced like `deck_agent.*`: `kv_agent.run_completed`, `kv_agent.run_undone`, `kv_agent.run_undo_failed`, `kv_agent.run_target_focused`. `kv_agent_targets_suggested` is deferred to P2 (needs `purpose: "targets"` on the question card).
- Server writes to detached tiles are broadcast on the existing resize-export realtime channel so other tabs update (api task; deviation recorded there if no channel fits).

Amendments from the api plan (binding; full list in the api plan's "Contract deviations"):
- C3 success bodies are wrapped `{ "data": <body> }`; coded refusals are `{ "message", "error": "<code>", "data": null }`.
- Flag is fail-closed: `feature.flag:kv-agentic-canvas,off`; default false where middleware cannot see the call (MCP gateway, chat stream).
- `add_kv_layer` across several boards: the first board and all sizes share one id; each additional board gets its own id (one id cannot appear twice in a live doc). C3.5's "one id shared by every target" is superseded.
- `set.visible` maps to `payload.hidden`; `unsupported_field` is never returned.
- An MCP run may be undone while `running` (undo completes it first); app runs still get 409.
- Undo during a collab outage returns 503 and reverts nothing; `collab_unavailable` never appears in undo `skipped`.
- Additional codes: `run_mismatch`, `undo_in_progress`, `invalid_input`, `invalid_style_key`, 404 `not_found`.
- `asset_url` must be on the platform's own bucket (the api fetches it to read dimensions).
- `/complete` never carries `agent_canvas`.
Amendments from the cross-repo review (binding):
- `GET kv/canvas/{fileId}` accepts optional `board_id` (any id in the board's version chain; unknown → 404 `board_not_found`): only that board and its sizes. When a surface exceeds 60 layers the **highest-z** layers are kept (then listed in z order). ai-service's `get_kv_canvas(board_id)` passes it through instead of filtering locally.
- A write whose adds would take the file past 300 layers is refused whole with 422 `too_many_layers` (the normaliser's list cap would otherwise freeze REST materialisation and every browser save).
- Doc-sink ops are ledgered immediately after the collab write; a failing tile write becomes a per-target skip, never a 500 that hides an applied change.
- Detach snapshots are taken from the post-write board layers.
- `set.style` keys that text runs can override are removed from every run.
- `set.text` does not accept `null`.
- `skipped[]` entries may carry `detail` (first validation message) for `invalid_payload`.
- MCP error messages end with the machine code in parentheses.
- Undo holds the write lock with a 150 s TTL; ai-service read timeout is 130 s.
- Layer text values are quote-escaped in `<kv_canvas_state>`.
- Known limitations (accepted for P1): a stale tab can overwrite agent writes to detached sizes; layer-decomposition commits race with agent writes; an MCP run blocks in-app runs on the same file for up to 10 minutes.

- Every canvas write (update/add/remove and undo replay) holds a per-file lock `kv-canvas-write:{fileId}` (TTL 90 s, waits up to 20 s); after the wait api answers 409 `write_in_progress` and sends nothing. ai-service passes it to the model as `error_code` (no automatic retry) and its read timeout is 100 s so an applied write is never reported as failed.
- No realtime channel exists for resize exports: web refetches `resizeExportsQueryKey(fileId)` after a live run that touched sizes and after undo (web Task 5). Other open tabs update on their next refetch.

## C6. Ledger table `kv_agent_runs` (api)

| column | type |
|---|---|
| `id` | ULID primary key (= `run_id`) |
| `studio_file_id` | FK studio_files |
| `user_id`, `workspace_id` | FKs |
| `source` | string `app` \| `mcp` |
| `status` | string `running` \| `completed` \| `undone` \| `failed` |
| `ops` | jsonb, default `[]`, atomic append of `{type, sink:"doc"|"tile", target, layer_id, before, after, at}` |
| `skipped` | jsonb, default `[]` |
| `detached_sizes` | jsonb, default `[]` |
| `undo_result` | jsonb nullable |
| timestamps | |

`status` becomes `completed` when the chat turn ends (api sees `done`) or, for MCP runs, lazily after 10 minutes without writes. Max 200 ops per run.

## C7. Feature flag

PostHog flag key `kv-agentic-canvas`. api: `feature.flag:kv-agentic-canvas` middleware (existing mechanism). web: the existing PostHog flag hook gates the run card rendering and nothing else (the tools' presence is decided by api).
