# Studio Run Engine — P1 (Text generator, real runs)

> Feature: `studio-canvas`. Builds on Stage A (Rafly's Studio UI bound to our headless core over Yjs; `web/src/lib/studio/bridge`). Date: 2026-10-21. Owner: Daffa.

## 1. Intent

Studio is a node canvas. Today every Run in it is a local simulation: the
prototype's store fakes progress, invents output and subtracts from a mock
2,400 cr balance, and every brief is demo text from fixtures. P1 makes the
**first node type run for real** — the Text generator — end to end, and
makes the **File node read real briefs** (PDF/DOCX upload, Lark doc, typed
text) so the Text generator writes from the user's actual brief: the click
reaches api, api charges real credits, ai-service writes the text, and the
result appears live for everyone in the file.

Why the Text generator first: it is cheap and fast (an LLM call, not an
image), so the engine's hard parts — up-front price, credits and refunds,
versions, Out of date, failure handling, live delivery to collaborators — get
built and proven before an expensive, slow node type depends on them. The
engine is generic; Image, Size set, Video and in-place edits plug in later as
new runners, never new pipelines.

The prototype is the reference for **UI and UX only** (what the user sees and
does). Its run mechanics (`simulateRun`, `pricing.ts` numbers, the store's
`tick`/`completeNode`, mock credits) are not a spec and are replaced.

## 2. Goals, non-goals, anti-goals

**Goals**
- Text generator "Run · This node only", Cancel, Retry, Update / Keep this version, version stepping — all real.
- File node brief reading is real for PDF/DOCX uploads, Lark docs and typed text (§3a).
- Price shown before running is the price charged; credits charged up front, refunded automatically when the run does not deliver.
- Every collaborator sees queued / running / done / failed and the result live.
- Every negative case in §7 behaves as written.
- No raw error text ever reaches a user (§8).
- A generic run engine in api that a new node type joins by adding one runner.

**Non-goals (P2+)**
- Real runs for Image, Size set, Video, Motion, in-place edits (region edit, upscale, remove background).
- Live objects (out of v1 entirely). In a real file a live object cannot feed a real Text generator run: the run is blocked with "Live objects are coming soon".
- Multi-node scopes: "Run from here", "Whole workflow", "Run selected ×N", section Run (fan-out), template step-by-step, Review updates.
- A model picker on the Text generator (the UX has none).

**Anti-goals** (would be a failure even if it "works")
- A user is charged and gets nothing, or charged twice for one click.
- A user sees a provider message, stack trace, HTTP body or internal id as an error.
- A client can write run results or credits into the doc and have them believed.
- A collaborator's view disagrees with the database after the run settles.
- A second, parallel LLM integration in ai-service instead of the existing Agno path.

## 3. What the user sees (contract from the prototype UX, plus `failed`)

Node run states shown on the card (`NodeRunState` in `lib/node-studio/types.ts`, plus one new state):

| State | Card shows | Run button |
|---|---|---|
| idle | "Not run yet", "⚡ ~2 cr" | "Run · 2 cr" |
| waiting (derived) | faded, "Waits for the brief" / "Needs …" | disabled, tooltip lists reasons |
| queued | "Queued", empty bar | "Running…" disabled |
| running | "Running", shimmer rows "WRITING…" (progress may be indeterminate) | "Running…" disabled |
| done | items; "spent" price; "‹ n / N ›" when ≥2 versions | "Run · 2 cr" |
| outOfDate | yellow banner + reason, "Update · 2 cr" / "Keep this version" | "Update · 2 cr" |
| **failed (new)** | short copy from §8 + "Retry · 2 cr"; previous version (if any) still visible | "Retry · 2 cr" |

- **Cancel** lives in the top-bar Tasks menu (as in the prototype). A cancelled run returns the node to the state it had before the run. **Only the person who started (and paid for) a run can cancel it**; collaborators see the run but no Cancel (api enforces `run.user_id`; others get `not_allowed`).
- **Top-bar credits** show the real balance (the user's spendable credits in this workspace), refreshed after every run settles.
- **Delete is blocked while a node is queued or running**: Delete key, context menu and the bridge all refuse it, with tooltip/toast "Running · cancel it first". This holds in collaborators' tabs too (they see the running state).
- Other node types keep their mock run in real files, **free** (no change to the real balance), until their runner exists.

Text generator settings stay as designed: preset (None, Directions, Taglines, Captions), prompt, output Text/List, count 1–10, Context ports (required, up to 4), optional Prompt port. Output items `{title, body, prompt}` per preset fields.

## 3a. Real brief reading (File node)

Today `readBriefPatch` fills every brief from fixtures (`BRIEF_ORIGINAL_TEXT`, `BRIEF_FIXTURE_FIELDS`, `BRIEF_FORMATS`). In real files that path is replaced; the mock stays for `/wireframes/node-studio`.

- **Sources:** PDF/DOCX upload, Lark doc link, typed/pasted text. The UX is the prototype's (reading shimmer, "4 pages · text read", editable fields with page refs, Replace).
- **Output shape** = the prototype's `BriefData`: original `text` (PDF text with page markers so fields can cite a page) + `fields[]` (`key`, `label`, `value`, `page`) using the prototype's field set, plus the formats list the Captions preset counts from.
- **Reuse, not new integrations:** PDF/DOCX text via ai-service's existing parser (`brand_knowledge_extraction.parsers.parse_pdf`, as `brief_decoder` uses, page-prefixed); Lark via api's `LarkDocumentService` (the user's Lark connection; if not connected, the UI asks them to connect, never a raw OAuth error). Field extraction is a new small structured call on the same Agno pattern as §4.3 with a Studio brief-fields schema (the proposal `ProposalSetupPayload` is far heavier than what the File node shows).
- **Runs the same engine:** reading a brief is a run of the File node (`FileBriefRunner`): intent → api resolves the source server-side (uploaded file id / Lark URL / typed text from the doc), job → ai-service → callback → version + facts written by the server. All of §6–§8 apply (idempotency, failure, watchdog, error codes, no raw errors — e.g. a scanned PDF with no text → `unreadable_document`).
- **Price:** free in P1 (`CreditPrice` key `studio_brief_read`, default 0, so it can be priced later without a deploy). *(My call.)*
- **Uploads** go to the existing S3 asset path used for studio files; ai-service gets a short-lived URL, never a public one. Size/type limits mirror the existing KV upload limits; a rejected file gets a code (`file_too_large`, `unsupported_file`), not a server message.
- **Field edits** by the user stay in the doc and are part of the Text generator's resolved input (and its input hash). Re-reading a brief that has edits asks first (the prototype's "Replace your edits" / "Keep mine").

## 4. Architecture — client writes intent, server writes facts

```
web (Run click) ──POST intent──▶ api ──job──▶ ai-service (202, background)
   ▲                            │  ▲                    │
   │                            │  └──callback(result)──┘
   │ live Yjs update            ▼
   └──────────── collab ◀── POST run facts (internal, openDirectConnection)
```

### 4.1 web
- **Run intent**: `POST v1/studio/canvas/files/{file}/runs` with `{node_id, scope: "node"}` and an `Idempotency-Key` header (a ulid per click). Nothing else — no prompt, no inputs, no price. Cancel: `POST …/runs/{run}/cancel`. Read-back: `GET …/runs/{run}` (REST fallback when collab is unreachable).
- **Price before run**: `GET …/runs/quote?node_id=` returns `{price, blocked_reasons[]}` so the button shows the server price. (The client may show its local estimate until the quote arrives.)
- **Run facts are read from the doc** (written only by the server, §4.4) and projected into the UI store's `runs` / text output by the bridge. The store's mock run path stays for other node types and is free in real files.
- Bridge rules added: delete of a queued/running node is refused and reverted; the run-facts map is never diffed back to the editor (it is not the client's to write).
- PostHog events per §9 (feature is not done without them).

### 4.2 api (owner of truth)
- `StudioRunController` (routes under the existing `studio` prefix, `scope_role:internal`, `feature.flag:show-studio-canvas,off`): `store`, `quote`, `show`, `cancel`. Authorisation via `StudioCanvasFileService::canAccess` with **write** (viewers get 403).
- `StudioRunService`:
  1. Lock the node (one active run per file+node; a DB unique partial index on `studio_runs(studio_file_id, node_id) where status in ('queued','running')`, or an equivalent row lock).
  2. Idempotency: same `Idempotency-Key` for the same user+file returns the existing run, never a second charge (stored on `studio_runs`, unique).
  3. Read the **live doc** from collab (`GET /internal/studio-files/{id}/document`) and resolve the node's inputs **server-side**: own prompt/preset/count/output settings, wired Context (File text, Text nodes). Never trust inputs from the client.
  4. Validate (missing required input → `inputs_missing` with the same reasons the UI uses).
  5. `input_hash` = sha256 of the canonical resolved inputs + preset + count + runner version.
  6. Price via `CreditPrice` key `studio_text_generate` (default 2). **Note:** `CreditPrice::credits()` falls back to `DEFAULTS[$key] ?? 0`, so the key must be added to `DEFAULTS`.
  7. Gate + charge **up front** in one transaction (`KvFixedPriceChargeService` pattern: `assertAffordable` then charge; batch id `studio_run_{run_id}`), create `studio_runs` (status `queued`, `estimated_cost`), write `queued` to the doc, dispatch the job.
- `StudioRunner` registry keyed by node type; P1 registers `TextGeneratorRunner` (resolve inputs, build ai-service request, validate result, map to version output). New node types = new runner class.
- `RunStudioNodeJob` (queue `default`, no blind retries — `Http::retry` throws by default, wrap and map): marks `running` (doc write), calls ai-service, which answers 202.
- Internal callback `POST internal/studio-runs/{run}/completed` (fail-closed internal token + per-run nonce): validates the result schema, writes `studio_node_versions` (next `version` n, `input_hash`, full `output` items, `cost_credits`), sets run `succeeded`, `actual_cost`, writes `done` + the new version to the doc. Ignored unless the run is still `queued|running` (status-guarded update) — late callbacks after cancel/timeout are dropped.
- Failure path (ai error, invalid result, timeout, dispatch error): run `failed` with an internal `error_code`, **refund** (pattern of `BrandTonalityController::safelyRefund`: pool/user part, Extra Credit part, void debt by batch, `*_refund` `CostHistory` row), write `failed` + `error_code` to the doc.
- Watchdog (scheduled, every minute): runs `queued|running` past a deadline (default 5 min) → failed `timeout` + refund. Status-guarded claim so it never races a real callback.
- `StudioCollabWriter` (copy of `KvCollabWriter`): writes run facts; on collab failure, retries via a queued job with backoff. The DB stays the source of truth, and `GET …/runs/{run}` serves clients meanwhile.
- `cost_histories.batch_identifier` has no unique index today: add a unique index for `studio_run_%` batch ids (partial) so double charges are impossible, not just unlikely.

### 4.3 ai-service
- New endpoint (e.g. `POST /api/agent/studio/text-generate`) modelled on `app/agents/projects/artifact_generate.py` `/generate`: `verify_internal`, 202 + `BackgroundTask`, callback to api with the nonce; callback URL validated by `same_origin` against `API_INTERNAL_URL`.
- One-shot Agno `Agent` (from `app.agents._agent_defaults`) with `output_schema` = a pydantic schema per preset (Directions: title/rationale/prompt; Taglines: tagline; Captions: format/caption; None: free text), `count` enforced. Check `RunStatus.error` (Agno swallows provider errors).
- Model: server-chosen (`internal_model("workhorse")` or api-provided config); any `VendorChat` must pass `OPENAI_PLATFORM_ENUM[provider]`.
- **Timeout**: wrap `agent.arun` in `asyncio.wait_for` (several provider branches set none).
- Brand knowledge: api prefetches and sends it (avoid ai-service calling back into api under `php artisan serve`); guard "don't invent brand facts" as in `artifact_generate._brand_hint`.
- Tracing: `set_ai_context(...)` then `tracing_post_hooks(feature="studio_text_generator", ...)`.
- Errors returned to api as codes + internal detail; api never forwards detail to clients.

### 4.4 collab
- `POST /internal/studio-files/{id}/run-facts` and `GET /internal/studio-files/{id}/document`, same pattern as KV (`kvHttp.ts`, `applyKvOps.ts`): `internalTokenOk`, zod `.strict()` body, `openDirectConnection("studio:"+id, {internal:true})`, one `doc.transact(…, SERVER_WRITE_ORIGIN)`, `disconnect()` in `finally`. Persistence logs the write automatically.
- Run facts live in a **dedicated root map** (e.g. `runFacts`, keyed by node id) and per-node version outputs in another (e.g. `nodeVersions`), never inside a node's client-owned `params`. Each run-facts entry carries at least: `state`, `run_id`, `active_version` (id + n), `input_hash` of that version, `spent`, `error_code` (when failed), `updated_at`. Exact field set is the builder's.
- Known limit, accepted for P1: Hocuspocus cannot stop an editor client from writing to `runFacts`. Authority is the api DB (credits, versions, run status); a tampered doc only misleads that tab's display and is corrected on the next server write. Do not let any server path read run facts back from the doc as truth.

## 5. Versions, edits and Out of date
- Every successful run is a new immutable `studio_node_versions` row and a new version in the doc. "‹ › " shows that version's items (unlike the prototype, which kept only a count).
- **The shown version is shared and is what flows downstream.** Stepping ‹ › is a normal document edit by any editor (client-owned field in the node's params, synced like any edit, undoable), not a server fact. A new successful run becomes the shown version for everyone. When the server resolves inputs for a downstream node (e.g. a Text generator wired from another Text generator), it uses the upstream node's shown version. *(My call.)*
- **Each version stores per-input hashes** (one per resolved input: own settings, each wired source, the brief's fields), not only a combined hash, so the Out of date banner can name what changed ("Brief changed", "<label>'s settings changed") for everyone and after reload. *(My call.)*
- **User edits to items** (edit body, remove, add) are kept **on the version they were made on**; a new run starts a clean version and the old version keeps its edits. *(My call.)* Where edits are stored (doc working copy per version vs a server-side copy) is the builder's choice, as long as edits survive stepping and reload and sync to collaborators.
- **Out of date** = the current resolved-input hash ≠ the active version's `input_hash`. The client may compute it locally for display (the inputs are in the doc); the server recomputes it on every Run. "Keep this version" acknowledges the difference without running (stored so it survives reload).
- Credits are not undoable; editor history restarts after a run settles (as Stage A already does).

## 6. Run lifecycle

`queued → running → succeeded | failed | cancelled`. Only api moves a run; collab only mirrors.

| From | Event | To | Credits |
|---|---|---|---|
| — | intent accepted | queued | charged up front |
| queued/running | ai-service result valid | succeeded | kept |
| queued/running | ai error / invalid result / dispatch error | failed | refunded |
| queued/running | watchdog deadline | failed (`timeout`) | refunded |
| queued/running | user Cancel | cancelled | refunded |
| succeeded/failed/cancelled | late callback | unchanged (dropped) | — |

## 7. Negative cases (decided)

1. **Not enough credits** → refused before any charge; `insufficient_credits` with the price.
2. **Required input missing** → validated server-side; `inputs_missing` with UI-identical reasons.
3. **Double click / network retry** → same `Idempotency-Key` returns the same run; one charge.
4. **Already running / two users click at once** → one run per node; the loser gets `already_running` and simply sees the running state.
5. **ai-service down / 5xx / timeout** → failed + refund; "Couldn't generate this time. Credits refunded." + Retry.
6. **Malformed or empty LLM output** → schema validation fails → failed + refund.
7. **Callback never arrives** → watchdog fails it after the deadline + refund.
8. **Late callback** (after cancel/timeout) → dropped by the status guard + nonce.
9. **Cancel** → cancelled + refund; a later result is dropped.
10. **Inputs change while running** → the result lands as a new version and immediately shows Out of date.
11. **Delete while queued/running** → prevented in the UI and the bridge; if a node is still deleted (old client), the version is kept in the DB, nothing is written to the doc for it, and the run is refunded.
12. **Collab down when writing facts** → DB is truth; the doc write is retried by a queued job; clients can read `GET …/runs/{run}`.
13. **Viewer / flag off** → 403 / 404 with generic copy.
14. **Refund itself fails** → user sees nothing; Sentry alert + log with `run_id` for follow-up.
15. **File or brand access revoked mid-run** → the run completes or fails normally; facts are still written (collab writes bypass auth); the revoked user simply no longer sees the file.

## 8. Error contract

- Errors cross the API boundary and the doc **only as codes**: `insufficient_credits`, `inputs_missing`, `already_running`, `generation_failed`, `timeout`, `cancelled`, `not_allowed`, `unavailable`, `unreadable_document`, `file_too_large`, `unsupported_file`, `lark_not_connected`, `lark_doc_not_accessible`.
- The UI maps each code to short copy (owned by web), e.g. `generation_failed`/`timeout` → "Couldn't generate this time. Credits refunded.", `unavailable` → "Studio can't run right now. Try again in a moment."
- Provider messages, exception text, HTTP bodies, stack traces and internal ids stay in logs and Sentry, tagged with `run_id`, `file_id`, `node_id`, `workspace_id`.
- API validation errors on these routes are returned with the code and copy-safe message, never Laravel's raw validator text with internal field names.

## 9. Analytics (PostHog)

Run through the `frndos-analytics-events` skill before calling it done. At minimum: `studio_canvas_run_requested`, `studio_canvas_run_succeeded`, `studio_canvas_run_failed` (with `error_code`), `studio_canvas_run_cancelled`, `studio_canvas_version_stepped`, `studio_canvas_out_of_date_kept` — properties include `node_type`, `preset`, `count`, `price`, `duration_ms`, `version_n`. Reconcile with the prototype's `node-studio-events` (the Stage A follow-up).

## 10. Verification expectations

- api Feature tests on a scratch Postgres (never the dev DB `frnd`; see the test-isolation lessons): charge + succeed, each failure → refund exactly once, idempotent double submit, concurrent submit, late callback dropped, watchdog, viewer 403, flag-off 404, `CreditPrice` default non-zero.
- ai-service tests for schema per preset, count enforcement, timeout path, `RunStatus.error` path.
- collab tests for the run-facts route (token, strict body, written in one transaction, persisted).
- web bun tests: bridge projects run facts, delete-while-running refused, error code → copy mapping, no raw error string rendered.
- Manual two-tab check: run, watch the other tab, cancel, fail (stop ai-service), reload.

## 11. Left to the builder
- The P0 `studio_runs` / `studio_node_versions` tables are unpushed and may be edited in place (status names `pending`/`completed` → this lifecycle, `mode` values, idempotency key, error code, nonce, per-input hashes).
- Exact doc field names and nesting of `runFacts` / `nodeVersions`, and where per-version edits live.
- Whether progress is indeterminate or estimated.
- Watchdog deadline value (default 5 min) and collab retry backoff.
- ai-service endpoint path and schema class names; model tier.
- How `quote` is cached in the UI.

## 12. Calls I made (not yet confirmed by Daffa)
- Charge up front, refund on any non-success (not charge-after).
- Edits are kept per version; a re-run starts clean.
- Mock runs of other node types are free in real files.
- Deleted-mid-run (if it slips past prevention): keep the version, refund.
- `failed` is a new visible node state with Retry; the previous version stays visible.
- Brief reading is free in P1 (price key exists at 0).
- The shown version is a shared, client-owned edit and is what flows downstream; a new run becomes the shown version.
- Per-input hashes per version so Out of date can name what changed.

## 13. Decided by Daffa
- Text generator first; engine generic.
- Prototype is UI/UX reference only; mechanics designed here.
- Handle every negative case; no verbose error reaches the user.
- Delete is prevented while a node runs.
- Collab-down handling as in §7.12.
- Other node types stay mock in real files.
- Real brief reading (PDF/DOCX, Lark, typed) is in P1.
- Only the run's starter can cancel it.
- Server-chosen model; brand knowledge prefetched by api.
