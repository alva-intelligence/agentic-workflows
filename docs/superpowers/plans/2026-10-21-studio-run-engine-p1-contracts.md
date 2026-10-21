# Studio Run Engine P1 — Cross-service contracts

Shared by the four P1 plans (`…-api.md`, `…-ai-service.md`, `…-collab.md`, `…-web.md`). Spec: `docs/superpowers/specs/2026-10-21-studio-run-engine-p1-design.md`. A plan that needs a contract change edits THIS file first, then every consumer.

## C0. Runnable node types (P1)

| UI node (`DocNode.type`) | Core record type | Runner | Price key (default) |
|---|---|---|---|
| `textGen` | `textGen` | `text_generate` | `studio_text_generate` (2) |
| `upload` holding a brief (`briefs[id]` present, `source ≠ "none"`) | `upload` | `brief_read` | `studio_brief_read` (0) |

Every other node type keeps the prototype's mock run, free, in real files. **Naming:** the prototype's File node is node type `upload` (title "File"); wherever these plans say "File node" or `file`, the node type is `upload`. An `upload` holding an image (no brief) is not runnable.

## C1. Doc shape (Yjs `studio:<file_id>`)

Existing (Stage A): root maps `meta`, `nodes`, `wires`, `sections`, `stickies`. A node record's `params` = `{ data, domain, parentId?, extent? }` where `domain` holds this node's entry from the UI maps (`texts`, `briefs`, `textGens`, `uploads`, …; see `web/src/lib/studio/bridge/projection.ts`).

New root maps, **written only by the server** (collab direct connection, origin `SERVER_WRITE_ORIGIN`):

`runFacts` — `Y.Map<string /*node_id*/, RunFact>` (plain JSON values)
```ts
type RunFact = {
  state: "idle" | "queued" | "running" | "done" | "failed";
  run_id: string | null;        // the latest run touching this node
  started_by: string | null;    // user id of the latest run's starter (Cancel is theirs only)
  active_version: { id: string; n: number } | null; // newest succeeded version
  error_code: RunErrorCode | null;  // only when state === "failed"
  spent: number;                // credits charged for the latest succeeded run
  updated_at: string;           // ISO-8601
};
```
`nodeVersions` — `Y.Map<string /*node_id*/, NodeVersionFact[]>` (append-only array, ascending `n`)
```ts
type NodeVersionFact = {
  id: string;            // studio_node_versions.id (ulid)
  n: number;             // 1-based
  created_at: string;
  price: number;
  input_hashes: Record<string, string>; // C3
  output: TextGenOutput | BriefOutput;
};
type TextGenOutput = { kind: "text_list"; items: { id: string; title: string; body: string; prompt: string }[] };
type BriefOutput = {
  kind: "brief";
  source: "pdf" | "docx" | "lark" | "typed";
  file_name: string | null;
  pages: number | null;
  text: string;                       // page-marked for pdf/docx: "--- Page N ---"
  fields: { key: string; label: string; value: string; page: number | null }[];
  formats: string[];                  // Captions preset counts these
};
```
Client-owned (in node `params.data`, synced like any edit, undoable):
- `shownVersion: number | null` — the version shown and passed downstream (null = newest).
- `keptHashes: Record<string,string> | null` — input hashes acknowledged by "Keep this version".
- `itemsByVersion: Record<string /*n*/, TextItem[]>` (textGen) — user edits per version; absent = server items unedited.
- `briefFieldsByVersion: Record<string /*n*/, BriefField[]>` (file) — user field edits per version.

Client-owned brief source (in the File node's `params.domain.briefs` entry, i.e. the UI `briefs[node_id]`): `source: "pdf"|"docx"|"lark"|"typed"`, `uploadId: string|null` (from C2 `POST uploads`), `larkUrl: string|null`, `text` (typed/pasted text). api reads these to resolve a `file` run; it never trusts a client-written `fields`.

## C2. REST (web → api), all under `v1/studio/canvas/files/{file_id}` behind `scope_role:internal` + `feature.flag:show-studio-canvas,off`

| Method + path | Body / query | 2xx |
|---|---|---|
| `POST runs` | `{ node_id }`, header `Idempotency-Key: <ulid>` | `202 { data: Run }` (same run on replay, status 200) |
| `GET runs/quote` | `?node_id=` | `200 { data: { price: int, blocked: { code: RunErrorCode, port?: string }[] } }` |
| `GET runs/{run_id}` | — | `200 { data: Run }` |
| `POST runs/{run_id}/cancel` | — | `200 { data: Run }` |
| `POST uploads` | multipart `file` (pdf/docx ≤ 25 MB) | `201 { data: { upload_id, file_name, mime } }` |

`Run = { id, node_id, node_type, status: "queued"|"running"|"succeeded"|"failed"|"cancelled", error_code: RunErrorCode|null, price: int, version: { id, n } | null, started_by: string, created_at }`.

Errors (every 4xx/5xx on these routes): `{ error: { code: RunErrorCode, message: string } }`, `message` is copy-safe English (never exception text). HTTP: `insufficient_credits` 402, `inputs_missing` 422, `already_running` 409, `not_allowed` 403, `not_found` 404, `file_too_large` 413, `unsupported_file` 415, `lark_not_connected` 409, `lark_doc_not_accessible` 422, `unavailable` 503.

`RunErrorCode = "insufficient_credits" | "inputs_missing" | "already_running" | "generation_failed" | "timeout" | "cancelled" | "not_allowed" | "not_found" | "unavailable" | "unreadable_document" | "file_too_large" | "unsupported_file" | "lark_not_connected" | "lark_doc_not_accessible" | "live_objects_unsupported"`.

## C3. Input hashes (api computes and stores; web recomputes for Out of date)

`hash(value) = lowercase hex sha256 of canonicalJson(value)`; `canonicalJson` = JSON with object keys sorted (code-point order) at every depth, no whitespace, arrays in order, strings as UTF-8 with JSON escaping only of `"`, `\` and U+0000–U+001F (`/` not escaped, non-ASCII literal), numbers in shortest round-trip form, `null` kept, `undefined`/absent keys omitted.

Keys of `input_hashes` for a `textGen`:
- `settings` → `{ preset, prompt, output, count }` (prompt = the node's own prompt text, trimmed)
- `context:<source_node_id>` per wired Context source → the source's resolved text value (below)
- `prompt:<source_node_id>` for a wired Prompt port → its resolved text value
For an `upload` brief: `source` → `{ kind: briefs.source, upload_id: briefs.uploadId, lark_url: briefs.larkUrl, text: briefs.text }` with null/empty members omitted (`text` only when `kind = typed`).

Resolved text value of a source node:
- Text node (`text`/`prompt` types): `{ kind: "text", text: texts[id] }`
- File (`upload` brief) node: `{ kind: "brief", fields: <shown version's fields with edits>, text: <shown version text> }`; no succeeded version → the source is missing.
- textGen: `{ kind: "items", items: <shown version items with edits, each {title, body, prompt}> }`; no succeeded version → missing.
- liveObject → blocked `live_objects_unsupported`.

Implementation notes: TS `JSON.stringify` of a key-sorted copy matches; PHP must use `json_encode($v, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_LINE_TERMINATORS)` and must keep `{}` distinct from `[]` (decode the doc with objects, or carry `stdClass`; `json_decode(..., true)` turns `{}` into `[]` — see the api-relay lesson). Escapes are lowercase `\u00XX`.

Golden vectors live in `docs/superpowers/plans/fixtures/studio-input-hash-vectors.json` (`[{ value, canonical, sha256 }]`, at least: nested key order, unicode "Ramadan 2027 · kopi ☕", escaped quote/newline, empty object/array, null, integer and float). Both the PHP and the TS implementation test against this file.

## C4. api → ai-service

Both endpoints: header `X-Internal-Token: config('services.internal.workflow_token')`; ai-service checks with `verify_internal`; replies `202 { run_id, status: "accepted" }`; unknown fields → 422.

`POST {services.ai.url}/ai/studio/runs/text-generate`
```json
{ "run_id": "…", "callback_url": "http://…/api/internal/studio-runs/{run_id}/completed", "callback_nonce": "…",
  "preset": "none|directions|taglines|captions", "prompt": "…", "output": "text|list", "count": 1,
  "fields": ["title","rationale","prompt"],
  "context": [{ "label": "Brief", "text": "…" }],
  "brand": { "name": "…", "knowledge": "…" } | null,
  "user_id": "…", "user_email": "…", "workspace_id": "…", "workspace_name": "…", "brand_id": "…|null", "brand_name": "…|null" }
```
`POST {services.ai.url}/ai/studio/runs/brief-read`
```json
{ "run_id": "…", "callback_url": "…", "callback_nonce": "…",
  "source": { "kind": "pdf|docx|text", "url": "<presigned, 30 min>|null", "text": "…|null", "file_name": "…|null", "origin": "upload|lark|typed" },
  "user_id": "…", "workspace_id": "…", "brand_id": "…|null" }
```

## C5. ai-service → api callback

`POST /api/internal/studio-runs/{run_id}/completed`, headers `X-Internal-Token`, `X-Studio-Run-Nonce: <callback_nonce>`.
```json
{ "status": "succeeded", "output": <TextGenOutput without item ids | BriefOutput without source> }
{ "status": "failed", "error_code": "generation_failed|timeout|unreadable_document|invalid_output", "detail": "<internal, logged only>" }
```
api assigns item ids (ulid) and `source`. Response `200 { ok: true }` (also for a dropped late callback); `401` bad token; `403` bad nonce.

## C6. api → collab

`GET {services.collab.url}/internal/studio-files/{file_id}/document` → `200 { nodes: NodeRecord[], wires: WireRecord[], runFacts: Record<string,RunFact>, nodeVersions: Record<string,NodeVersionFact[]> }` (plain JSON of the maps).

`POST {services.collab.url}/internal/studio-files/{file_id}/run-facts`
```json
{ "run_id": "…", "node_id": "…", "fact": <RunFact>, "version": <NodeVersionFact> | null }
```
One transaction: set `runFacts[node_id] = fact`; if `version` and no entry with that `id` exists, append it to `nodeVersions[node_id]`. `200 { ok: true }`; `409 { code: "node_missing" }` when `nodes` has no `node_id` (the fact is NOT written); `401` bad token; `422` invalid body. Both routes: `X-Internal-Token`.
