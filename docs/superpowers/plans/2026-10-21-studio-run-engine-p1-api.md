# Studio Run Engine P1 — api Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** api owns Studio node runs: accept run intent, resolve inputs from the live doc, price, charge up front, dispatch to ai-service, record immutable versions, refund every non-success, and push run facts into the doc through collab.

**Architecture:** `StudioRunService` (intent → queued run) + `StudioRunner` registry (`TextGeneratorRunner`, `FileBriefRunner`) + `RunStudioNodeJob` (→ ai-service, 202) + internal completion callback + watchdog. Credits via a `StudioRunCharger` that stores the deduction split on the run so refunds are exact. Doc reads/writes via `StudioCollabClient` (collab `/internal/studio-files/*`).

**Tech Stack:** Laravel 13, PHP 8.5, Pest, PostgreSQL.

**Spec:** `docs/superpowers/specs/2026-10-21-studio-run-engine-p1-design.md`. **Contracts:** `docs/superpowers/plans/2026-10-21-studio-run-engine-p1-contracts.md` (C0–C6 are binding; cite them, don't restate them).

## Global Constraints

- Repo `api/`, branch `feature/daffa/vc-studio-canvas`. Never push. Commits `feat(api): …` + `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Never run tests against the dev DB `frnd`.** Run: `php artisan config:clear` (move `bootstrap/cache/config.php` and `routes-v7.php` aside if present, restore after), then `DB_CONNECTION=pgsql DB_DATABASE=frnd_studio_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest <test paths> --compact`. Pass file paths, not `--filter`. Check `psql -lqt | grep frnd_studio_test` first; create it (`createdb frnd_studio_test`) if missing.
- The P0 migration `2026_10_21_120100_create_studio_canvas_tables.php` is already applied to the dev DB: **do not edit it**; add new migrations. Dev-DB migrate is the user's call (with `TELESCOPE_ENABLED=false`).
- No raw error text to clients: every Studio-run response error is `{ error: { code, message } }` per C2; exception messages go to `Log`/Sentry with `run_id`, `file_id`, `node_id`, `workspace_id`.
- `Http::retry()` throws on final failure — never chain it before a `->failed()` check; wrap calls in try/catch.
- Only collab writes `studio_yjs_updates`; api writes the doc only through `StudioCollabClient`.
- Price keys `studio_text_generate` = 2 and `studio_brief_read` = 0 must be in `CreditPrice::DEFAULTS` (it falls back to `?? 0`).

## Review Focus

1. Two requests with the same `Idempotency-Key` racing → exactly one charge and one run (unique index, not `exists()`).
2. A callback and the watchdog (or a cancel) landing at the same moment → exactly one terminal state and at most one refund.
3. A doc whose node `params.data` has `{}` vs `[]` (PHP decode) → hashes still match the web's (golden vectors through the real resolver, not only the hasher).
4. ai-service 202 but collab down when facts are written → run still settles in the DB, facts retried, `GET runs/{id}` correct meanwhile.
5. A user who is not the starter cancels → 403 `not_allowed`, run untouched.

---

### Task 1: Schema, enums, prices

**Files:**
- Create: `database/migrations/2026_10_22_100000_studio_run_engine.php`, `app/Enums/StudioRunStatus.php`, `app/Models/Studio/StudioCanvasUpload.php`
- Modify: `app/Models/Studio/StudioRun.php`, `app/Models/Studio/StudioNodeVersion.php`, `app/Models/CreditPrice.php`
- Test: `tests/Feature/Studio/StudioRunSchemaTest.php`

**Interfaces:**
- Produces: `StudioRunStatus` (`Queued='queued'`, `Running='running'`, `Succeeded='succeeded'`, `Failed='failed'`, `Cancelled='cancelled'`; `isActive(): bool` for queued|running; `isTerminal(): bool`). `CreditPrice::KEY_STUDIO_TEXT_GENERATE = 'studio_text_generate'`, `KEY_STUDIO_BRIEF_READ = 'studio_brief_read'`.
- `studio_runs` gains: `node_id` widened to `string(64)`; `node_type string(64)`; `idempotency_key string(64)`; `status` default `'queued'`; `error_code string(64) null`; `callback_nonce_hash string(64) null`; `charge jsonb null` (`{credits_deducted, extra_credit_drawn, debt_created}`); `refunded_at timestampTz null`; `version_id ulid null`; `started_at`, `finished_at`, `deadline_at timestampTz null`. Unique `(user_id, studio_file_id, idempotency_key)`. Partial unique index `studio_runs_one_active_per_node` on `(studio_file_id, node_id) WHERE status IN ('queued','running')`.
- `studio_node_versions` gains: `node_id` widened to `string(64)`, `run_id ulid null`, `input_hashes jsonb default '{}'`.
- `cost_histories`: partial unique index on `batch_identifier WHERE batch_identifier LIKE 'studio_run_%'`.
- `studio_canvas_uploads`: ulid `id`, `studio_file_id` FK cascade, `user_id` FK, `disk string`, `path string`, `file_name string`, `mime string`, `size_bytes bigint`, timestamps.

- [ ] **Step 1: Failing tests** — `StudioRunSchemaTest`: `it('allows only one active run per node')` (second insert with status `running` for same file+node throws `UniqueConstraintViolationException`; a `succeeded` one does not); `it('rejects a reused idempotency key for the same user and file')`; `it('accepts 64-char node ids')` (`str_repeat('a', 64)`); `it('refuses a second cost row for one studio_run batch id')`; `it('prices studio runs with non-zero defaults')` → `CreditPrice::credits('studio_text_generate') === 2` and `credits('studio_brief_read') === 0` with no DB row.
- [ ] **Step 2: Run, expect FAIL** (missing columns/indexes).
- [ ] **Step 3: Implement** migration (raw `DB::statement` for the partial indexes; `down()` drops what `up()` added), enum, model casts (`status` → enum, `charge`/`input_hashes` → array, datetimes), `StudioCanvasUpload`, price constants + `DEFAULTS`.
- [ ] **Step 4: Run, expect PASS**; also run `tests/Feature/Studio/StudioCanvasSchemaTest.php` (P0) green.
- [ ] **Step 5: Commit** `feat(api): studio run engine schema, statuses and prices`.

### Task 2: Charger with exact refunds

**Files:** Create `app/Services/Studio/Runs/StudioRunCharger.php`. Test `tests/Feature/Studio/StudioRunChargerTest.php`.

**Interfaces:**
- Consumes: `KvFixedPriceChargeService::assertAffordable/quote`, `CreditService::deductCreditsWithDebt`, `refundCredits`, `refundToExtraCredit`, `voidPendingDebtByBatch`.
- Produces: `StudioRunCharger::batchId(StudioRun $run): string` → `"studio_run_{$run->id}"`; `charge(StudioRun $run, User $user, Workspace $workspace, int $price): void` (inside caller's transaction; stores `charge` split on the run; writes `CostHistory` `cost_type = "studio_run_{runner}"`, `entry_type = deduction`; price 0 → no-op, `charge = null`); `refund(StudioRun $run, string $reason): void` (idempotent via `refunded_at` claimed with a status-guarded `update … where refunded_at is null`; restores pool/user part, Extra Credit part, voids debt by batch, writes `*_refund` `CostHistory` `entry_type = addition`; never throws — logs + reports to Sentry on failure); throws `App\Exceptions\Studio\StudioInsufficientCreditsException(int $price, int $available)` from `assertAffordable`.

- [ ] **Step 1: Failing tests:** charge 2 deducts 2 and stores the split; refund restores exactly the split (pool and Extra Credit cases); second `refund()` is a no-op (balances unchanged, one refund row); price 0 charges nothing and refund is a no-op; a member over cap → `StudioInsufficientCreditsException` with `available`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** (reuse `BrandTonalityController::safelyRefund` arithmetic; do not copy its controller coupling).
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat(api): studio run charger with exact refunds`.

### Task 3: Collab client, doc reader, input resolver, hasher

**Files:**
- Create: `app/Services/Studio/Runs/StudioCollabClient.php`, `app/Services/Studio/Runs/StudioDoc.php`, `app/Services/Studio/Runs/StudioInputResolver.php`, `app/Services/Studio/Runs/StudioInputHasher.php`, `app/Exceptions/Studio/StudioCollabUnavailable.php`, `app/Exceptions/Studio/StudioNodeMissing.php`
- Create: `tests/Fixtures/studio/input-hash-vectors.json` (copy of the contracts fixture)
- Test: `tests/Unit/Studio/StudioInputHasherTest.php`, `tests/Unit/Studio/StudioInputResolverTest.php`, `tests/Feature/Studio/StudioCollabClientTest.php`

**Interfaces:**
- `StudioCollabClient::document(StudioFile $file): StudioDoc` (C6 GET; 10 s timeout; non-2xx/connection error → `StudioCollabUnavailable`), `writeFact(StudioFile $file, string $runId, string $nodeId, array $fact, ?array $version): void` (C6 POST, 20 s; 409 `node_missing` → `StudioNodeMissing`; other failures → `StudioCollabUnavailable`). Base URL `config('services.collab.url')`, header `X-Internal-Token: config('services.internal.workflow_token')` (same as `KvCollabWriter`).
- `StudioDoc` wraps the decoded JSON **as objects** (`json_decode($body, false)`, keeps `{}` vs `[]`): `node(string $id): ?object`, `wiresInto(string $nodeId, string $portId): array`, `versions(string $nodeId): array`, `fact(string $nodeId): ?object`.
- `StudioInputHasher::canonical(mixed $v): string`, `hash(mixed $v): string` per C3 flags.
- `StudioInputResolver::forTextGen(StudioDoc $doc, string $nodeId): ResolvedInputs` and `forFile(StudioDoc $doc, string $nodeId): ResolvedInputs` where `ResolvedInputs` (readonly DTO) = `{ array $payload, array $hashes, array $blocked }` — `$blocked` = list of `['code' => RunErrorCode, 'port' => ?string]`; `$hashes` keys exactly as C3; `$payload` = the ai-service request fragment (C4 `preset, prompt, output, count, fields, context[]` / `source`). Resolution rules = C3 "resolved text value" (shown version = `params.data.shownVersion ?? newest`; edits from `itemsByVersion` / `briefFieldsByVersion`). Context required (≥1 resolvable source) for textGen; live object source → `live_objects_unsupported`; File with no source → `inputs_missing`.

- [ ] **Step 1: Failing tests:** hasher matches every vector in `tests/Fixtures/studio/input-hash-vectors.json` — a byte-identical copy of the contracts fixture `docs/superpowers/plans/fixtures/studio-input-hash-vectors.json` (the api repo cannot read the workspace root); read with `json_decode(…, false)` so `{}` survives; resolver: (a) textGen with one wired Text node → payload context `[{label, text}]` and hash keys `settings`, `context:<id>`; (b) no context wire → `blocked = [['code'=>'inputs_missing','port'=>'context']]`; (c) wired File without a succeeded version → blocked; (d) wired File with version 2 shown and field edits → payload uses the edited fields and the hash equals the hash of the same value built by hand; (e) live object source → `live_objects_unsupported`; (f) a node whose `params.data` is `{}` hashes identically to the TS fixture case. Collab client: `Http::fake` 200/409/500/connection exception → returns / `StudioNodeMissing` / `StudioCollabUnavailable`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat(api): studio doc reader, input resolver and hasher`.

### Task 4: Runner registry and the two runners

**Files:** Create `app/Services/Studio/Runs/StudioRunner.php` (interface), `StudioRunnerRegistry.php`, `TextGeneratorRunner.php`, `FileBriefRunner.php`. Modify `app/Providers/AppServiceProvider.php` (register singletons). Test `tests/Feature/Studio/StudioRunnersTest.php`.

**Interfaces:**
- `interface StudioRunner { public function key(): string; public function nodeType(): string; public function priceKey(): string; public function resolve(StudioDoc $doc, string $nodeId, StudioRun $run): ResolvedInputs; public function aiPath(): string; public function aiRequest(StudioRun $run, ResolvedInputs $in, string $callbackUrl, string $nonce): array; public function validateOutput(array $output): ?array /* normalized output or null */; }`
- `StudioRunnerRegistry::for(string $nodeType): ?StudioRunner`.
- `TextGeneratorRunner`: key `text_generate`, nodeType `textGen`, priceKey `studio_text_generate`, aiPath `/ai/studio/runs/text-generate`; `aiRequest` adds brand `{name, knowledge}` from the file's brand (reuse `KvBrandContextBuilder` / brand knowledge prefetch; null when no brand) and tracing ids; `validateOutput` requires `kind = text_list`, `1 ≤ count(items) ≤ 10`, every item has string `title|body|prompt`, assigns ulid `id`s.
- `FileBriefRunner`: key `brief_read`, nodeType `file`, priceKey `studio_brief_read`, aiPath `/ai/studio/runs/brief-read`; source resolution: upload → `StudioCanvasUpload` presigned URL (30 min, `Storage::disk($u->disk)->temporaryUrl`), `kind` from mime; Lark → `LarkDocumentService` text fetch at dispatch time (not connected → `lark_not_connected`; 403/404 → `lark_doc_not_accessible`) sent as `kind=text, origin=lark`; typed → `kind=text, origin=typed`. `validateOutput` requires `kind = brief`, string `text`, `fields` list of `{key,label,value,page}`, `formats` list of strings; adds `source`.

- [ ] **Step 1: Failing tests:** registry returns each runner and null for `image`; text runner builds the C4 body exactly (assert keys + values for a Directions node with count 6, fields `["title","rationale","prompt"]`); brand null when the file has none; `validateOutput` rejects 0 items, 11 items, a missing `body`, and accepts + assigns ids; brief runner for an upload builds `kind=pdf` with a temporary URL (fake disk), for Lark with `Http::fake` returning text builds `kind=text, origin=lark`, Lark not connected → blocked `lark_not_connected`.
- [ ] **Step 2: Run, expect FAIL.** **Step 3: Implement.** **Step 4: PASS.**
- [ ] **Step 5: Commit** `feat(api): studio runner registry with text and brief runners`.

### Task 5: Run intent API — start, quote, show, cancel, upload

**Files:**
- Create: `app/Services/Studio/Runs/StudioRunService.php`, `app/Http/Controllers/Api/Studio/StudioRunController.php`, `app/Http/Controllers/Api/Studio/StudioCanvasUploadController.php`, `app/Http/Requests/Studio/StartStudioRunRequest.php`, `app/Http/Resources/Studio/StudioRunResource.php`, `app/Exceptions/Studio/StudioRunException.php` (carries `RunErrorCode` + HTTP status + copy-safe message), `app/Jobs/Studio/WriteStudioRunFactJob.php`
- Modify: `routes/api.php` (inside the existing `feature.flag:show-studio-canvas,off` group at ~5336)
- Test: `tests/Feature/Studio/StudioRunControllerTest.php`, `tests/Feature/Studio/StudioCanvasUploadControllerTest.php`

**Interfaces:**
- Routes (C2): `POST canvas/files/{id}/runs` `studio.canvas.runs.store`; `GET canvas/files/{id}/runs/quote` `…quote` (registered BEFORE `{run}`); `GET canvas/files/{id}/runs/{run}` `…show`; `POST canvas/files/{id}/runs/{run}/cancel` `…cancel`; `POST canvas/files/{id}/uploads` `studio.canvas.uploads.store`.
- `StudioRunService::start(User $u, StudioFile $f, string $nodeId, string $idempotencyKey): StudioRun` — order: (1) `canAccess($u,$f,'write')` else `not_allowed`; (2) existing run for `(user, file, key)` → return it; (3) `document()` (`StudioCollabUnavailable` → `unavailable`); node missing → `not_found`; runner for its type or `not_found`; (4) `resolve` → blocked → `inputs_missing` / `live_objects_unsupported` / lark codes (first blocked code); (5) price via `KvFixedPriceChargeService::quote(priceKey, 1)`; (6) `DB::transaction`: `assertAffordable` → `insufficient_credits` (402, message includes the price), insert run (`queued`, `estimated_cost`, `deadline_at = now()+5min`, hashed nonce, hashes stored in a run column or passed to the job), `charge`; unique-violation on the active-run index → `already_running` (409), on the idempotency index → re-read and return; (7) `WriteStudioRunFactJob::dispatchSync`-then-queue-on-failure for the `queued` fact (`state=queued, run_id, started_by`); (8) dispatch `RunStudioNodeJob` after commit.
- `quote(User, StudioFile, string $nodeId): array{price:int, blocked:array}` (no charge, no writes).
- `cancel(User, StudioRun): StudioRun` — starter only (`not_allowed` 403 otherwise); status-guarded update `queued|running → cancelled` (no-op if already terminal: return as is); `refund($run,'cancelled')`; write fact restoring `state` = `done` if `active_version` else `idle`, keep `active_version`.
- `WriteStudioRunFactJob(string $runId, array $fact, ?array $version)` — queue `high`, `tries = 8`, `backoff = [2,5,10,30,60,120,300]`; `StudioNodeMissing` → do not retry (log); `StudioCollabUnavailable` → release with backoff.
- Error rendering: `StudioRunException` renders C2 envelope; `StartStudioRunRequest` failures render `{error:{code:'inputs_missing',message:'…'}}`, never Laravel's field-keyed messages.
- Upload: validate `mimes:pdf,docx`, `max:25600` (KB); stores `studio-canvas/{file_id}/uploads/{ulid}.{ext}` on `config('filesystems.default')`; 413/415 codes per C2.

- [ ] **Step 1: Failing tests** (`Http::fake` collab + ai-service, `Queue::fake`, `Storage::fake`): start happy path → 202, run `queued`, one `CostHistory` of 2, `WriteStudioRunFactJob` fact `queued`, `RunStudioNodeJob` pushed; replay same key → 200 same id, still one charge; second key while active → 409 `already_running`, no charge; no context → 422 `inputs_missing` + no charge + no run; broke member → 402 `insufficient_credits`, message contains "2"; viewer (read-only perm) → 403 `not_allowed`; flag off → 404; collab down at start → 503 `unavailable`, no charge; quote returns `{price:2, blocked:[]}` / blocked list and writes nothing; cancel by starter → `cancelled` + refunded + fact restored; cancel by another editor → 403 and run untouched; cancel of a succeeded run → 200 unchanged, no refund; every error body matches `{error:{code,message}}` and `message` contains no class names or SQL (`expect($msg)->not->toContain('Exception')`); upload pdf → 201 + row + stored; `.png` → 415; 26 MB → 413.
- [ ] **Step 2: Run, expect FAIL.** **Step 3: Implement.** **Step 4: PASS** (plus P0 `StudioCanvasFileControllerTest` green).
- [ ] **Step 5: Commit** `feat(api): studio run intent endpoints`.

### Task 6: Job, completion callback, terminal transitions

**Files:**
- Create: `app/Jobs/Studio/RunStudioNodeJob.php`, `app/Http/Controllers/Api/Internal/StudioRunCallbackController.php`, `app/Http/Requests/Internal/StudioRunCallbackRequest.php`, `app/Services/Studio/Runs/StudioRunSettler.php`
- Modify: `routes/api.php` (internal group, inside a `RequireInternalToken` group like the one at ~7142)
- Test: `tests/Feature/Studio/RunStudioNodeJobTest.php`, `tests/Feature/Studio/StudioRunCallbackTest.php`

**Interfaces:**
- `StudioRunSettler::succeed(StudioRun $run, array $output): bool`, `fail(StudioRun $run, string $errorCode, string $detail): bool` — each starts with a status-guarded `update … where id = ? and status in ('queued','running')` and returns false (does nothing else) when 0 rows changed. `succeed`: next `version` n (`max+1` inside the transaction), `studio_node_versions` row (`status = 'succeeded'`, `input_hashes`, `output`, `cost_credits`, `run_id`), run `succeeded`, `actual_cost`, `version_id`, `finished_at`; then fact `{state:'done', active_version:{id,n}, spent, error_code:null}` + version fact (C1) via `WriteStudioRunFactJob`; `StudioNodeMissing` → refund (spec §7.11, version kept). `fail`: run `failed` + `error_code`, `refund`, fact `{state:'failed', error_code}` (keeps `active_version`). `detail` only to `Log::warning` + Sentry breadcrumb.
- `RunStudioNodeJob(string $runId)`: `tries = 1`, `timeout = 60`, queue `default`; skips non-active runs; marks `running` (`started_at`) + fact `running`; re-resolves inputs from a fresh `document()` (hashes stored at start stay authoritative for the version); `Http::timeout(30)->withHeaders(['X-Internal-Token'=>…])->post(ai.url . runner.aiPath, runner.aiRequest(...))` in try/catch; connection error / non-2xx → `fail('unavailable'|'generation_failed', detail)`; `failed(Throwable)` → `fail('generation_failed', …)`.
- Callback `POST internal/studio-runs/{run}/completed` (`internal.studio-runs.completed`): token via middleware; nonce `hash_equals(run.callback_nonce_hash, hash('sha256', header))` else 403; body per C5; `succeeded` → `runner->validateOutput` null → `fail('generation_failed', 'invalid_output')`; else `succeed`; `failed` → `fail(code)` with `code` restricted to `generation_failed|timeout|unreadable_document|invalid_output` (`invalid_output` maps to `generation_failed`); always `200 {ok:true}` once authenticated (late callback included).

- [ ] **Step 1: Failing tests:** job happy → run `running`, ai-service called with C4 body and nonce; ai-service 500 → run `failed` `generation_failed` + refunded; connection exception → `unavailable` + refunded; job on a cancelled run → no HTTP call; callback succeeded → version n=1 with items + ids, run `succeeded`, facts job with `done` + version; a second successful run → n=2; callback with 0 items → `failed` + refund; callback `failed/timeout` → `failed timeout` + refund once; callback after cancel → 200, nothing changes, no second refund; bad nonce → 403; no token → 401; `StudioNodeMissing` on the done fact → refund + version row kept.
- [ ] **Step 2: Run, expect FAIL.** **Step 3: Implement.** **Step 4: PASS.**
- [ ] **Step 5: Commit** `feat(api): studio run job and completion callback`.

### Task 7: Watchdog

**Files:** Create `app/Console/Commands/FailStaleStudioRuns.php`. Modify `routes/console.php` (schedule `everyMinute()->withoutOverlapping()`). Test `tests/Feature/Studio/FailStaleStudioRunsTest.php`.

**Interfaces:** `studio:fail-stale-runs` — for each run `status in (queued,running) and deadline_at < now()`, `StudioRunSettler::fail($run, 'timeout', 'watchdog')`.

- [ ] **Step 1: Failing tests:** a running run past its deadline → `failed timeout`, refunded once, fact written; a run inside its deadline untouched; a run that a callback settled between the select and the update → unchanged (call `succeed` first, then the command; one terminal state, no refund).
- [ ] **Step 2: FAIL. Step 3: Implement. Step 4: PASS.**
- [ ] **Step 5: Commit** `feat(api): watchdog for stale studio runs`.

### Task 8: Service PRD and track update

**Files:** Modify `docs/prd/studio-canvas.md` (api service PRD: P1 tasks), `docs/tracks/studio-canvas.track.md` (session log entry, task checklist).

- [ ] **Step 1:** Add P1 task list + API contract pointer (contracts file path) to the service PRD; append a dated session-log entry to the track file.
- [ ] **Step 2: Run the whole Studio suite:** `… vendor/bin/pest tests/Feature/Studio/StudioRun*.php tests/Feature/Studio/StudioCanvas*.php tests/Feature/Studio/RunStudioNodeJobTest.php tests/Feature/Studio/FailStaleStudioRunsTest.php tests/Unit/Studio --compact` → all green.
- [ ] **Step 3: Commit** `docs(api): studio run engine P1 prd and track`.
