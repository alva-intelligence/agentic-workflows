# KV Agentic Canvas — Intent Layer — Frozen Contracts (I1–I6)

Date: 2026-10-19. Source: `frnd/docs/prd/kv-agentic-canvas-intent.md` plus the 3 service PRDs. These shapes are binding for api, ai-service and web. Changing one requires editing this file first and telling the other two services.

Branch in every repo: `feature/daffa/vc-kv-agentic-canvas-intent`. Worktree: `<repo>/.worktrees/kv-agentic-canvas-intent`.

## I1 — `intent_mode` (api → ai-service)

PostHog multivariate flag `kv-agentic-canvas-intent`:

| Flag value | `intent_mode` |
|---|---|
| `shadow` | `"shadow"` |
| `live` | `"live"` |
| anything else, error, or `kv-agentic-canvas` off | `"off"` |

api resolves it once per turn and adds it to the `/ai/kv-generator/stream` body **only when `agent_canvas` is present**:

```json
{ "intent_mode": "off" | "shadow" | "live" }
```

ai-service: `KvStreamRequest.intent_mode: Literal["off","shadow","live"] = "off"`. A missing value is `off`.

## I2 — `card_id` on question cards (ai-service → api → web)

- ai-service `QuestionCardEvent` gains `card_id: str | None`, a 26-char ULID minted by ai-service for every card it emits. `None` only for legacy paths.
- Option `id`s are stable strings, as today.
- api `QuestionCardPayload::normalize` keeps `card_id` (string, ≤26) and adds `selected_option_ids` (list of strings, default absent).
  - SSE frame: `{"type":"kv_question_card", "label", "options":[...], "purpose", "card_id"}`.
  - The persisted assistant row `{kind:"question_card", payload:{..., card_id}}`.
- History hydrate returns `payload.card_id` and `payload.selected_option_ids`. The latter is derived from the next user row's `message.card_answer.option_ids` when that row's `card_id` matches.

## I3 — `card_answer` (web → api → ai-service)

Web → api, on `POST v1/threads/{id}/stream` (KV thread), top-level body field:

```json
{ "card_answer": { "card_id": "01J…(26)", "option_ids": ["opt_1"], "purpose": "layer", "surface": "kv_canvas" } }
```

- Validation (`App\Support\Chat\CardAnswer`):
  - `card_id`: required, 26 chars;
  - `option_ids`: required, 1..8 strings, each ≤64;
  - `purpose` ∈ `direction|targets|layer`;
  - `surface` ∈ `kv_canvas`.
- `card_id` must match a `question_card` row on this thread; otherwise 422 `{"message":"Unknown card"}`.
- The prompt text (`message`) is still the option label, as today.
- api persists the answer on the user row as `message.card_answer` (the same object) and forwards the same object to ai-service as `card_answer` on `/ai/kv-generator/stream`.
- ai-service: `KvStreamRequest.card_answer: CardAnswer | None`, a Pydantic model with the same 4 fields.

## I4 — `agent_canvas.recent_runs` + layer `description` (api → ai-service)

`agent_canvas.recent_runs` holds at most 3 runs, newest first:

```json
[{ "run_id": "01J…", "status": "completed|undone|failed|running",
   "change": "resized|moved|rotated|hidden|shown|text|style|restacked|added|removed|edited",
   "layers": ["brand logo", "layer at top-left"], "surfaces": 1, "boards": 1, "age_s": 42 }]
```

- ai-service: `AgentCanvas.recent_runs: list[RecentRun] = []`.
- Inventory layer item (inside `agent_canvas.inventory.boards[].layers[]` and the size/tile layer lists) gains an optional `"description": "<≤160 chars>"`, present only when cached. ai-service reads it from the dict; there is no schema change for it.

## I5 — `POST internal/agent-intent-events` (ai-service → api)

- Auth: `X-Internal-Token`. Response: 202 `{"data":{"id":"<ulid>"}}`. Errors:
  - 401: bad or missing token;
  - 404: the file is not in the workspace, or the user is not a member;
  - 422: validation failed.
- Body:

```json
{ "surface": "kv_canvas", "kind": "decision|resolver_timeout|mismatch_refused",
  "mode": "shadow|live", "studio_file_id": "…", "thread_id": "…", "run_id": "…|null",
  "user_id": "…", "workspace_id": "…", "prompt": "…|null (≤4000)",
  "payload": { }, "latency_ms": 1234 }
```

- `payload` for `decision`:
  - `{"intent": <CanvasIntent JSON>, "decision": {"kind":"write|ask|handoff", "reason": "…", "tool_calls": [{"tool":"update_kv_layers","args":{…}}]?, "card": {"purpose":"layer|targets","option_ids":[…]}?}, "model": "provider/model"}`;
  - in shadow mode it also has `"agent": {"tools": ["update_kv_layers"], "layer_ids": [...], "asked": bool}`, i.e. what the P0 agent actually did. ai-service posts it when the turn ends.
- `payload` for `resolver_timeout`: `{"error": "timeout|error|unparsed", "model": "…"}`.
- `payload` for `mismatch_refused`: `{"tool": "…", "layer_ids": [...], "reference": "brand logo"}`.
- The size limit is 32 KB per payload.
- api itself writes `clarified` (on a `card_answer`) and `undone_fast` (on an undo ≤300 s). ai-service never sends those 2 kinds.

## I6 — `POST /ai/kv-canvas/describe-layers` (api job → ai-service)

- Auth: `X-Internal-Token`.
- Request: `{"layers":[{"layer_id":"…","asset_url":"https://…","asset_hash":"<sha256 hex>","name":"…|null"}]}` with 1..12 items.
- Response 200: `{"data":[{"layer_id":"…","asset_hash":"…","description":"≤160 chars"}]}`. Layers that could not be described are omitted.
- `asset_url` hosts must pass the same allowlist the api uses (our S3/CDN). ai-service rejects other hosts with 422.

## Shared names

- PostHog: `agent_intent.decision`, `agent_intent.clarified`, `agent_intent.fast_undo`, each with a `surface` property. No prompt text.
- Tracing feature names: `agent_intent` (resolver), `kv_layer_describe` (descriptions).
- Thresholds (ai-service only): `MIN_CONFIDENCE=0.6`, `TIE_MARGIN=0.15`, `PIXEL_LAYER_FLOOR=0.4`, `RESOLVER_TIMEOUT_S=4`, `FAST_UNDO_S=300` (api).
