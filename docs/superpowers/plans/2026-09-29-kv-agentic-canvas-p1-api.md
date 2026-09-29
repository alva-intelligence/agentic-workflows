# KV Agentic Canvas P1 — api Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the KV chat agent (and, through the MCP mirror, external clients) server-executed layer tools on the KV canvas: read the canvas, edit / add / remove layers on boards and resize sizes, record every write in a run ledger, and undo a run with compare-and-set.

**Architecture:** A thin `KvCanvasToolController` on the existing `mcp/tools` surface calls `KvCanvasEditService`, the only unit that knows the sinks: board layers are written into the live Y.Doc through `KvCollabWriter` → collab `POST /internal/kv-files/{id}/ops` (contract C1), size layers are written into `kv_resize_exports.overlays` under a row lock. Detaching an inheriting size uses a PHP port of the web projection (`KvTileOverlayProjector`) pinned to the TypeScript by generated fixtures. `KvAgentRunRecorder` keeps the `kv_agent_runs` ledger and the per-file run lock; `KvAgentRunReverter` undoes newest-first with CAS. `ChatService::streamKvGenerator` mints the run id per flagged Craft chat turn, ships the inventory, relays `kv_agent_run`, and settles the run at `done`. Collab calls back into `POST internal/kv-files/{id}/overlays` (C2), which reuses the browser PATCH's validation through the extracted `StudioOverlayNormalizer`.

**Tech Stack:** Laravel 13, PHP 8.5, PostgreSQL (jsonb), Pest 4, laravel/mcp 0.7, Pint. Test-only: bun (runs the web TypeScript once to generate projection fixtures).

**Spec:** `docs/superpowers/specs/2026-09-29-kv-agentic-canvas-design.md` (read §3–§8, §10, §13). **Contracts (binding, never rename):** `docs/superpowers/plans/2026-09-29-kv-agentic-canvas-p1-contracts.md` (C1–C7). Executors read both before Task 1.

## Global Constraints

- Repo: `api/` (`/Users/alva.e202511001/Desktop/work/frndos-agentic/api`). Branch `feature/daffa/vc-kv-agentic-canvas`, cut from `develop` (Task 1). Commit on it; do not push.
- Every name, route, payload key and error code in the contracts file is used verbatim. Anything this plan adds or changes is listed under **Contract deviations** at the end — nowhere else.
- **Feature tests run on a scratch Postgres, never the dev DB `frnd`, never SQLite** (`api/phpunit.xml` defaults to sqlite `:memory:`, which cannot migrate this schema). Before the first test run in a session: `ls api/bootstrap/cache/config.php api/bootstrap/cache/routes-v7.php` must list nothing — if either exists, `rm` it and do NOT restore it (a cached config silently points tests at `frnd`; a cached route table hides new routes). Then confirm the scratch DB: `psql -lqt | cut -d'|' -f1 | grep -qw frnd_test || psql -d postgres -c 'CREATE DATABASE frnd_test'`.
- Feature test command shape (always pass **file paths**, never `--filter` — a broken file elsewhere kills the suite mapper before filtering): `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest <path> [<path>...] --compact`. Pure unit tests (no `RefreshDatabase`) may run with `vendor/bin/pest <path> --compact`.
- Collab is always faked with `Http::fake` (via `Tests\Support\FakeKvCollab` from Task 9 on). One `Http::fake` per test: a second call MERGES and the first matching pattern wins, so pass extra patterns into `FakeKvCollab::install($doc, [...])`. `Http::preventStrayRequests()` is on in every canvas test.
- Collab client (`KvCollabWriter`): `GET /document` timeout 10 s; `POST /ops` timeout **20 s** (collab materialises overlays back to api with up to ~9.75 s of retries before it answers; must be ≥ 15 s). Token header `X-Internal-Token` = `config('services.internal.workflow_token')`, base `config('services.collab.url')`. Never `->retry()` (it throws by default and makes status branches dead code). Every failure is logged and raised — never silent.
- Collab error mapping: connection error, any 5xx (`ops_failed`, `read_failed`), a bare 404 (route not deployed), no collab URL → `KvCollabUnavailableException` → skipped reason `collab_unavailable`. 409 `layer_changed` / `layer_exists` → `KvLayerChangedException`. 404 `layer_not_found` → `KvLayerNotFoundException`. 400 `invalid_json`, 422 `invalid_body` / `too_many_ops`, body > 1.9 MB → `KvCollabRejectedException` → skipped reason `invalid_payload`.
- Collab does not validate payload keys or rect ranges. Before any `/ops` call or tile write, every layer is validated **as it will look after the op** with `StudioOverlayNormalizer` (the browser PATCH's exact rules). Failure → skipped reason `invalid_payload`; nothing is sent.
- No api-side fallback read of `studio_files.overlays` / `metadata.kv_canvas` for the canvas: collab's `GET /document` backfills a never-opened doc itself. An unreadable collab means `collab_unavailable` (writes: every target skipped; `get_kv_canvas`: 503; chat turn: no tools this turn).
- `studio_files.overlays` full-replace from collab (C2) keeps only items whose `id` matches `/^[0-9A-Za-z]{26}$/` and never mints ids; the browser PATCH keeps minting for a missing id (the browser strips `tmp_` ids to "missing" in `useDebouncedOverlaySave.ts::sanitizeForSave`). Both run the same `StudioOverlayNormalizer`.
- Never read overlay/style input through `validated()` or add `*.payload.*` / `*.style.*` sub-rules to a tool request: with `excludeUnvalidatedArrayKeys` on, one sub-rule strips every unlisted key. Tool controllers validate shape with `Validator::make($request->all(), ...)` and then read `$request->input(...)`.
- Caps (spec §5, §8.1): 30 boards, 50 sizes per board, 60 layers per surface, `text` 200 chars in the inventory; 60 targets per call (after expansion); 200 ops per run.
- Style keys an agent may set (the text typography/fill/compositing keys `UpdateStudioFileOverlaysRequest` already whitelists): `color, fontFamily, fontSize, fontWeight, fontStyle, textAlign, lineHeight, letterSpacing, paragraphSpacing, textTransform, gradient, opacity, blendMode`. Any other key → 422 `invalid_style_key` before anything is written.
- Feature flag key `kv-agentic-canvas`, fail-closed: routes use `feature.flag:kv-agentic-canvas,off`; code paths outside route middleware (MCP gateway, ChatService) use `FeatureFlagService::isEnabledForWorkspace('kv-agentic-canvas', $user, $workspaceId, default: false)` via `App\Support\Studio\KvAgentCanvasFlag`. (Non-production is force-open, so tests exercise the OFF path by mocking `FeatureFlagService`.)
- Response envelope: tool and user routes return `{"data": <contract body>}`; errors return `{"message": "...", "error": "<code>", "data": null, ...extra}`. C2 returns exactly `{"count": n}`.
- After ANY change to the `mcp/tools` route group or `app/Mcp/`: `php artisan mcp:verify-mirror` must print `Mirror OK`.
- Every commit step runs `vendor/bin/pint --dirty --format agent` first. Commit messages end with the line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Tests are derived from the real code: each asserts an outcome that disappears if the behaviour is removed. Where a step dictates a number, the step also says how the implementer re-derives it; if a dictated number disagrees with what the implementation produces, recompute by hand from the formula before changing either side, and record the resolution in the commit message.

## Review Focus

1. A board id the agent read before a rekey (an older id in the board's `versionIds`) must still land on the current board, and results must report the current id — Task 11 test "resolves a version-chain id to the current board".
2. Two edits to the same layer in one call must reach collab as ONE `set_layer` op carrying both changes (collab validates a batch before applying, so two ops on one layer would CAS against stale values) — Task 11 test "coalesces two edits on one layer into one collab op".
3. A size the user deliberately emptied (`overlays: []`) is detached, not inheriting; an edit on it must report `layer_absent_on_size` and must not re-detach it (PHP `if ([])` is false where JS `if ([])` is true) — Task 11 test "never re-detaches a deliberately emptied size".
4. Replacing text that contains emoji must set the collapsed run's `length` in UTF-16 code units, the unit the browser counts runs in — Task 11 test "counts UTF-16 units for the collapsed run".
5. Undo after the user deleted a layer the run had edited must skip that layer (`layer_not_found`) and still revert the rest — Task 15 test "skips a layer the user deleted and reverts the others".

---

## File Structure

Create:
- `app/Services/Studio/StudioOverlayNormalizer.php` — the browser PATCH's overlay rules, after-checks and stamping, shared with C2 and with every agent write.
- `app/Http/Controllers/Api/Internal/InternalKvOverlaysController.php` — C2.
- `database/migrations/2026_09_29_200000_create_kv_agent_runs_table.php`, `app/Models/KvAgentRun.php` — C6.
- `app/Exceptions/Studio/{KvCollabUnavailableException,KvLayerChangedException,KvLayerNotFoundException,KvCollabRejectedException,KvCanvasToolException,KvLayerPatchException}.php`.
- `app/Services/Studio/AgentCanvas/KvCollabWriter.php` — HTTP client for C1.
- `app/Support/Studio/KvImageDimensions.php` — pixel size of a generation / asset URL.
- `app/Services/Studio/AgentCanvas/KvTileOverlayProjector.php` + `tests/Fixtures/kv-projection/{generate.ts,cases.json}` — PHP port of `resolveTileOverlays`.
- `app/Services/Studio/AgentCanvas/{KvLayerShape,KvLayerDiff,KvLayerPatch,KvLayerPlacement}.php` — pure layer primitives.
- `app/Services/Studio/AgentCanvas/{KvCanvasState,KvCanvasContextAssembler}.php` — the loaded canvas + inventory (§5 / C3.2).
- `app/Support/Studio/KvAgentCanvasFlag.php` — flag key + check.
- `app/Http/Controllers/Api/ModelContextProtocol/KvCanvasToolController.php` — C3.
- `app/Mcp/Tools/{GetKvCanvasTool,UpdateKvLayersTool,AddKvLayerTool,RemoveKvLayersTool,UndoKvAgentRunTool}.php` — MCP twins.
- `app/Services/Studio/AgentCanvas/KvAgentRunRecorder.php` — ledger + per-file run lock.
- `app/Services/Studio/AgentCanvas/{KvCanvasEditService,KvCanvasWriteLog}.php` — sink routing.
- `app/Services/Studio/AgentCanvas/KvLayerAssetResolver.php` — `brand_logo` / `asset_url` for `add_kv_layer`.
- `app/Services/Studio/AgentCanvas/KvAgentRunReverter.php` — server-mode undo.
- `app/Http/Controllers/Api/Studio/KvAgentRunController.php` — C5.
- `app/Services/Studio/AgentCanvas/KvAgentCanvasTurn.php` — C4 decision + payload.
- Tests: `tests/Support/{FakeKvCollab,KvCanvasFixture}.php`, `tests/Traits/BuildsKvCanvas.php`, `tests/Feature/Studio/AgentCanvas/*.php`, `tests/Unit/Studio/AgentCanvas/*.php`, `tests/Unit/Mcp/KvCanvasToolsTest.php`.

Modify:
- `app/Http/Requests/Studio/UpdateStudioFileOverlaysRequest.php`, `app/Http/Controllers/Api/Studio/StudioFileController.php` (`updateOverlays`) — delegate to the normaliser.
- `app/Services/Studio/KvResizeExportService.php` (+`writeOverlays`), `app/Http/Controllers/Api/Studio/KvResizeExportController.php` (`updateOverlays` calls it).
- `routes/api.php` — tool routes, user routes, internal route.
- `app/Mcp/Servers/FrndosServer.php` — register twins.
- `app/Services/ChatService.php` (`streamKvGenerator`), `app/Http/Controllers/Api/Studio/KvGeneratorFileController.php` (hydration surfaces `agent_run_id`).
- `docs/superpowers/specs/2026-09-29-kv-agentic-canvas-design.md` (workspace root repo) — one-line CAS note (Task 19).

---
### Task 1: Branch, scratch database, baselines

**Files:** none changed.

**Interfaces:**
- Consumes: nothing.
- Produces: branch `feature/daffa/vc-kv-agentic-canvas`; a recorded baseline of the three existing test files this plan touches and of `mcp:verify-mirror`.

- [ ] **Step 1: Cut the branch from a fresh develop**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
git status --short            # must be empty; stop and ask if not
git checkout develop && git pull --rebase origin develop
git checkout -b feature/daffa/vc-kv-agentic-canvas
```

- [ ] **Step 2: Clear the caches that hijack tests and routes, confirm the scratch DB**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
ls bootstrap/cache/config.php bootstrap/cache/routes-v7.php 2>/dev/null && rm -f bootstrap/cache/config.php bootstrap/cache/routes-v7.php
psql -lqt | cut -d'|' -f1 | grep -qw frnd_test || psql -d postgres -c 'CREATE DATABASE frnd_test'
```
Expected: no file listed (or removed; never restore them). `frnd_test` exists.

- [ ] **Step 3: Record the baseline of the files this plan modifies**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/UpdateStudioFileOverlaysTest.php tests/Feature/Studio/KvResizeExportControllerTest.php tests/Feature/Chat/StreamChatKvModeTest.php --compact
php artisan mcp:verify-mirror
```
Expected: `Mirror OK: …`. Write down every failing test name from the pest run (for example `PATCH overlays rejects > 30 items` asserts a 30-item cap while the request allows 300, so it may already fail). Those are the pre-existing baseline; later tasks must not add to that list and must not "fix" unrelated failures.

No commit (nothing changed).

---

### Task 2: Extract `StudioOverlayNormalizer` from the browser PATCH

**Files:**
- Create: `app/Services/Studio/StudioOverlayNormalizer.php`
- Modify: `app/Http/Requests/Studio/UpdateStudioFileOverlaysRequest.php` (whole class body), `app/Http/Controllers/Api/Studio/StudioFileController.php:363-398` (`updateOverlays`)
- Test: `tests/Feature/Studio/AgentCanvas/StudioOverlayNormalizerTest.php`

**Interfaces:**
- Consumes: nothing new.
- Produces (`App\Services\Studio\StudioOverlayNormalizer`):
  - `rules(): array<string, mixed>` — exactly the rules the PATCH request had.
  - `afterChecks(\Illuminate\Contracts\Validation\Validator $v, array $overlays, \Closure $resolveFile): void` — trusted-asset host + `board_generation_id ∈ file generations`; `$resolveFile(): ?StudioFile` is only called when some overlay is board-bound.
  - `validate(array $overlays, StudioFile $file): array` — validated overlay list (whitelisted payload keys), throws `ValidationException`.
  - `stamp(array $validated): array` — server-stamps `id`/`z`/timestamps (unchanged behaviour).
  - `normalize(array $overlays, StudioFile $file): array` — `stamp(validate(...))`.
  - `rowError(array $row, StudioFile $file): ?string` — first validation message for ONE flat row, or null. The row's `id` is ignored (tile snapshots can carry web `tmp_` ids).
  - `normalizeRow(array $row, StudioFile $file): array` — the validated (key-stripped) row with its original `id`; throws `ValidationException`.

- [ ] **Step 1: Write the failing test**

`tests/Feature/Studio/AgentCanvas/StudioOverlayNormalizerTest.php`:

```php
<?php

use App\Http\Requests\Studio\UpdateStudioFileOverlaysRequest;
use App\Models\KvGeneration;
use App\Models\Role;
use App\Models\StudioFile;
use App\Models\Tool;
use App\Models\User;
use App\Models\Workspace;
use App\Services\Studio\StudioOverlayNormalizer;
use Illuminate\Support\Str;
use Illuminate\Validation\ValidationException;

beforeEach(function () {
    $this->user = User::factory()->create();
    $this->workspace = Workspace::factory()->create(['type' => 'organization']);
    $this->user->update(['current_workspace_id' => $this->workspace->id]);
    $this->user->workspaces()->attach($this->workspace->id);
    $role = Role::factory()->create(['slug' => 'internal-'.Str::random(6), 'type' => 'workspace', 'scope' => 'internal']);
    $this->user->workspaceRoles()->attach($role->id, ['workspace_id' => $this->workspace->id]);
    $this->file = StudioFile::factory()->create([
        'workspace_id' => $this->workspace->id,
        'brand_id' => null,
        'tool_id' => Tool::factory()->create()->id,
        'created_by' => $this->user->id,
        'last_edited_by' => $this->user->id,
    ]);
    $this->generation = KvGeneration::factory()->create(['studio_file_id' => $this->file->id, 'created_by' => $this->user->id]);
    $this->actingAs($this->user, 'api');
});

function normalizerTextOverlay(array $payload = []): array
{
    return [
        'type' => 'text',
        'x' => 0.1, 'y' => 0.2, 'width' => 0.3, 'height' => 0.05, 'rotation' => 0,
        'payload' => array_merge(['type' => 'text', 'content' => 'Hello', 'color' => '#FFFFFF'], $payload),
    ];
}

it('the PATCH request validates with exactly the normaliser rules', function () {
    // toEqual, not toBe: Rule::in() builds a fresh object per call.
    expect((new UpdateStudioFileOverlaysRequest)->rules())
        ->toEqual(app(StudioOverlayNormalizer::class)->rules());
});

it('keeps every whitelisted payload key and strips unknown ones through the PATCH', function () {
    $overlay = normalizerTextOverlay([
        'name' => 'Headline', 'hidden' => true, 'locked' => false, 'blendMode' => 'multiply',
        'fontFamily' => 'bf_01', 'fontSize' => 0.05, 'runs' => [['length' => 2, 'fontWeight' => 'bold']],
        'bogus' => 'dropped',
    ]);

    $stored = $this->patchJson("/api/v1/studio/files/{$this->file->id}/overlays", ['overlays' => [$overlay]])
        ->assertOk()
        ->json('data.overlays.0.payload');

    expect($stored)->toMatchArray([
        'name' => 'Headline', 'hidden' => true, 'locked' => false, 'blendMode' => 'multiply',
        'fontFamily' => 'bf_01', 'fontSize' => 0.05, 'runs' => [['length' => 2, 'fontWeight' => 'bold']],
    ])->and($stored)->not->toHaveKey('bogus');
});

it('still rejects a board binding from another file', function () {
    $overlay = normalizerTextOverlay() + ['board_generation_id' => (string) Str::ulid()];

    $this->patchJson("/api/v1/studio/files/{$this->file->id}/overlays", ['overlays' => [$overlay]])
        ->assertStatus(422)
        ->assertJsonValidationErrors(['overlays.0.board_generation_id']);
});

it('rowError reports the first problem of one row and ignores a tmp_ id', function () {
    $normalizer = app(StudioOverlayNormalizer::class);
    $row = normalizerTextOverlay() + ['id' => 'tmp_1727600000_ab12cd', 'z' => 1, 'board_generation_id' => $this->generation->id];

    expect($normalizer->rowError($row, $this->file))->toBeNull()
        ->and($normalizer->rowError(array_merge($row, ['width' => 0]), $this->file))->toBeString()
        ->and($normalizer->rowError(array_merge($row, ['payload' => ['type' => 'text', 'content' => str_repeat('a', 501), 'color' => '#FFFFFF']]), $this->file))->toBeString();
});

it('normalizeRow strips unknown payload keys and keeps the id', function () {
    $row = normalizerTextOverlay(['bogus' => 1]) + ['id' => '01JAGENTHEADLINE0000000001', 'z' => 2, 'board_generation_id' => null];

    $normalized = app(StudioOverlayNormalizer::class)->normalizeRow($row, $this->file);

    expect($normalized['id'])->toBe('01JAGENTHEADLINE0000000001')
        ->and($normalized['payload'])->not->toHaveKey('bogus')
        ->and($normalized['payload']['content'])->toBe('Hello');
    expect(fn () => app(StudioOverlayNormalizer::class)->normalizeRow(array_merge($row, ['height' => 0]), $this->file))
        ->toThrow(ValidationException::class);
});
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/StudioOverlayNormalizerTest.php --compact`
Expected: FAIL — `Class "App\Services\Studio\StudioOverlayNormalizer" not found`.

- [ ] **Step 3: Create the normaliser (rules and after-checks MOVED verbatim from the request)**

`app/Services/Studio/StudioOverlayNormalizer.php`:

```php
<?php

namespace App\Services\Studio;

use App\Http\Requests\Studio\Concerns\HasBlendModePayloadRules;
use App\Http\Requests\Studio\Concerns\HasShapeOverlayPayloadRules;
use App\Http\Requests\Studio\Concerns\HasTextOverlayPayloadRules;
use App\Models\StudioFile;
use App\Support\Studio\TrustedAssetHost;
use Closure;
use Illuminate\Contracts\Validation\Validator as ValidatorContract;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;
use Illuminate\Validation\Rule;
use Illuminate\Validation\ValidationException;

/**
 * One definition of "a valid stored overlay" — the rules, the after-checks
 * and the server stamping the browser's `PATCH studio/files/{id}/overlays`
 * applies. Shared by that PATCH, the collab materialisation endpoint (C2) and
 * every agent write (KvCanvasEditService), so a payload key the browser keeps
 * is kept everywhere and one it strips is stripped everywhere.
 *
 * The payload whitelist below is load-bearing: `excludeUnvalidatedArrayKeys`
 * is on, so `validated()` rebuilds `payload` from the listed sub-keys only.
 * Adding one `payload.*` rule without listing every key strips the rest.
 */
final class StudioOverlayNormalizer
{
    use HasBlendModePayloadRules;
    use HasShapeOverlayPayloadRules;
    use HasTextOverlayPayloadRules;

    /** @return array<string, mixed> */
    public function rules(): array
    {
        return [
            // Ceiling mirrored by the web client's MAX_OVERLAYS_PER_FILE — a
            // save above it is rejected wholesale and would poison every
            // autosave after a PSD import. Raised 100 → 300 for real agency
            // PSDs; keep the two in sync.
            'overlays' => ['present', 'array', 'max:300'],
            'overlays.*.id' => ['nullable', 'string', 'size:26'], // ULID
            'overlays.*.type' => ['required', Rule::in(['text', 'image', 'shape'])],
            // Coords are normalized to the bg image's fit rect, but users
            // can drag overlays past the bg edges (Canva-style off-canvas
            // positioning). Allow a generous range; positive sizes are
            // still required.
            'overlays.*.x' => ['required', 'numeric', 'between:-5,5'],
            'overlays.*.y' => ['required', 'numeric', 'between:-5,5'],
            'overlays.*.width' => ['required', 'numeric', 'gt:0', 'lte:5'],
            'overlays.*.height' => ['required', 'numeric', 'gt:0', 'lte:5'],
            'overlays.*.rotation' => ['required', 'numeric'],
            'overlays.*.z' => ['nullable', 'integer'],
            // The tip generation id of the board this overlay is bound to,
            // so it stays anchored to and moves with that board on the
            // multi-board canvas. Nullable for legacy overlays (fall back to
            // the active/master board on render).
            'overlays.*.board_generation_id' => ['nullable', 'string'],
            'overlays.*.payload' => ['required', 'array'],

            // Discriminated payload — text. Empty content is a valid draft
            // state (user just placed the overlay and hasn't typed yet);
            // the frontend auto-deletes empty text on edit-commit.
            'overlays.*.payload.type' => ['required', Rule::in(['text', 'image', 'shape'])],
            // Optional display name for the layers panel (e.g. the source PSD
            // layer name on import). Must be whitelisted or validated() strips
            // it on save. Applies to text + image payloads.
            'overlays.*.payload.name' => ['nullable', 'string', 'max:120'],
            // Layer visibility (Photoshop-style eye toggle). Absent ⇒ visible.
            // Whitelisted for the same validated()-stripping reason as `name`.
            'overlays.*.payload.hidden' => ['nullable', 'boolean'],
            // Position lock (Photoshop/Figma-style). Locked layers render but
            // can't be selected/moved on the canvas. Whitelisted for the same
            // validated()-stripping reason as `name`.
            'overlays.*.payload.locked' => ['nullable', 'boolean'],
            'overlays.*.payload.content' => ['nullable', 'string', 'max:500'],
            // Text typography (fontFamily / fontSize / gradient, plus the
            // per-run `runs.*` overrides) — shared with
            // StoreBrandOverlayPresetRequest via the trait so the two stay in
            // sync. Whitelisting is required or validated() strips them on save.
            ...$this->textOverlayPayloadRules(),
            ...$this->blendModePayloadRules(),

            // Discriminated payload — image
            'overlays.*.payload.asset_url' => ['required_if:overlays.*.payload.type,image', 'url'],
            'overlays.*.payload.mime_type' => [
                'required_if:overlays.*.payload.type,image',
                Rule::in(['image/png', 'image/jpeg', 'image/webp', 'image/svg+xml']),
            ],

            // Discriminated payload — shape (rectangle/ellipse/triangle/polygon/line).
            ...$this->shapeOverlayPayloadRules(),

            // `color` is defined by both textOverlayPayloadRules()-adjacent logic
            // above and shapeOverlayPayloadRules() (shape's `required_if:...,shape`
            // would otherwise win as the last array-literal definition and stop
            // requiring it for text). This final definition governs every overlay
            // type: required for text + shape, optional for image.
            'overlays.*.payload.color' => ['required_unless:overlays.*.payload.type,image', 'regex:/^#[0-9A-Fa-f]{6}$/'],
        ];
    }

    /**
     * @param  array<int, mixed>  $overlays
     * @param  Closure(): ?StudioFile  $resolveFile  called only when some overlay is board-bound
     */
    public function afterChecks(ValidatorContract $v, array $overlays, Closure $resolveFile): void
    {
        // Resolve this file's generation ids ONCE, but only if at least one
        // overlay is board-bound — so the common (no-binding) path skips the
        // query. Any board_generation_id must belong to THIS file's
        // generations, matching the strictness updateCanvasState already
        // applies to the sibling artboards map (KvGeneratorFileController).
        $hasBinding = collect($overlays)
            ->contains(fn ($o) => is_array($o) && ! empty($o['board_generation_id'] ?? null));
        $allowedGenerationIds = [];
        if ($hasBinding) {
            $file = $resolveFile();
            // If the file doesn't resolve, the caller 404s; skip the
            // cross-check here rather than mint a misleading error.
            $allowedGenerationIds = $file
                ? $file->generations()->pluck('id')->all()
                : null;
        }

        foreach ($overlays as $i => $overlay) {
            if (! is_array($overlay)) {
                continue;
            }
            if (($overlay['payload']['type'] ?? null) === 'image') {
                $url = $overlay['payload']['asset_url'] ?? '';
                // Bucket must be in our trusted S3 host (config-driven).
                if (! TrustedAssetHost::allows($url)) {
                    $v->errors()->add(
                        "overlays.$i.payload.asset_url",
                        'asset_url host is not on the trusted list.',
                    );
                }
            }

            $boundId = $overlay['board_generation_id'] ?? null;
            if ($boundId !== null && $allowedGenerationIds !== null
                && ! in_array($boundId, $allowedGenerationIds, true)) {
                $v->errors()->add(
                    "overlays.$i.board_generation_id",
                    'board_generation_id does not belong to this file.',
                );
            }
        }
    }

    /**
     * @param  array<int, mixed>  $overlays
     * @return array<int, array<string, mixed>>
     *
     * @throws ValidationException
     */
    public function validate(array $overlays, StudioFile $file): array
    {
        $validator = Validator::make(['overlays' => $overlays], $this->rules());
        $validator->after(fn (ValidatorContract $v) => $this->afterChecks($v, $overlays, fn () => $file));

        return $validator->validate()['overlays'] ?? [];
    }

    /**
     * Server-stamp id, z, created_at, updated_at on every element.
     *
     * @param  array<int, array<string, mixed>>  $validated
     * @return array<int, array<string, mixed>>
     */
    public function stamp(array $validated): array
    {
        $now = now()->toIso8601String();

        return collect($validated)
            ->values()
            ->map(function (array $o, int $idx) use ($now) {
                return [
                    'id' => $o['id'] ?? (string) Str::ulid(),
                    'type' => $o['type'],
                    'x' => (float) $o['x'],
                    'y' => (float) $o['y'],
                    'width' => (float) $o['width'],
                    'height' => (float) $o['height'],
                    'rotation' => (float) $o['rotation'],
                    'z' => $o['z'] ?? $idx,
                    // M2d: persist the board anchor so a board-bound overlay
                    // survives the save→reload round-trip. The request already
                    // validates this; without it here the overlay comes back
                    // unbound and falls back to the master/active board.
                    'board_generation_id' => $o['board_generation_id'] ?? null,
                    'payload' => $o['payload'],
                    'created_at' => $o['created_at'] ?? $now,
                    'updated_at' => $now,
                ];
            })
            ->all();
    }

    /**
     * @param  array<int, mixed>  $overlays
     * @return array<int, array<string, mixed>>
     *
     * @throws ValidationException
     */
    public function normalize(array $overlays, StudioFile $file): array
    {
        return $this->stamp($this->validate($overlays, $file));
    }

    /** First validation message for one flat overlay row, or null when it is valid. */
    public function rowError(array $row, StudioFile $file): ?string
    {
        try {
            $this->validate([self::forValidation($row)], $file);

            return null;
        } catch (ValidationException $e) {
            return (string) collect($e->errors())->flatten()->first();
        }
    }

    /**
     * The row as the browser PATCH would store it (payload keys outside the
     * whitelist dropped), keeping its own id.
     *
     * @return array<string, mixed>
     *
     * @throws ValidationException
     */
    public function normalizeRow(array $row, StudioFile $file): array
    {
        $validated = $this->validate([self::forValidation($row)], $file)[0];
        $validated['id'] = $row['id'] ?? null;

        return $validated;
    }

    /**
     * The id is not what is being validated here: a tile snapshot can carry
     * a web `tmp_…` id (useTileOverlayEditing) that the `size:26` rule would
     * refuse, and the id never changes on an agent write.
     */
    private static function forValidation(array $row): array
    {
        $row = array_intersect_key($row, array_flip([
            'id', 'type', 'x', 'y', 'width', 'height', 'rotation', 'z', 'board_generation_id', 'payload',
        ]));
        $row['id'] = null;

        return $row;
    }
}
```

- [ ] **Step 4: Make the request and the controller delegate**

Replace the body of `app/Http/Requests/Studio/UpdateStudioFileOverlaysRequest.php` with:

```php
<?php

// craftsman-ignore: PHP001

namespace App\Http\Requests\Studio;

use App\Models\StudioFile;
use App\Services\Studio\StudioOverlayNormalizer;
use Illuminate\Foundation\Http\FormRequest;

/**
 * The browser's full-replace overlay save. Rules, after-checks and stamping
 * live in StudioOverlayNormalizer so the collab materialisation endpoint and
 * the agent canvas tools validate exactly the same way.
 */
class UpdateStudioFileOverlaysRequest extends FormRequest
{
    public function authorize(): bool
    {
        // The route is bound to a StudioFile via implicit binding +
        // workspace scope; controller-level authorization is enough.
        return true;
    }

    public function rules(): array
    {
        return app(StudioOverlayNormalizer::class)->rules();
    }

    public function withValidator($validator): void
    {
        $validator->after(function ($v) {
            app(StudioOverlayNormalizer::class)->afterChecks(
                $v,
                (array) $this->input('overlays', []),
                fn () => StudioFile::query()->find($this->route('id')),
            );
        });
    }
}
```

In `app/Http/Controllers/Api/Studio/StudioFileController.php`, replace `updateOverlays` with (add `use App\Services\Studio\StudioOverlayNormalizer;`; leave `Str` imported if other methods use it, pint will tell you):

```php
    public function updateOverlays(
        UpdateStudioFileOverlaysRequest $request,
        string $id,
        StudioOverlayNormalizer $normalizer,
    ): StudioFileResource {
        $file = StudioFile::query()->findOrFail($id);
        $this->authorizeAccess($file, $request);

        $stamped = $normalizer->stamp($request->validated()['overlays'] ?? []);

        $file->forceFill(['overlays' => $stamped])->save();

        return new StudioFileResource($file->fresh());
    }
```

- [ ] **Step 5: Run the new test and the existing PATCH test**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/StudioOverlayNormalizerTest.php tests/Feature/Studio/UpdateStudioFileOverlaysTest.php --compact`
Expected: the 5 new tests PASS; `UpdateStudioFileOverlaysTest` shows exactly the Task 1 baseline (no new failures).

- [ ] **Step 6: Prove the parity test is not vacuous**

Temporarily delete the `'overlays.*.payload.blendMode'` rule by commenting out `...$this->blendModePayloadRules(),` in the normaliser, re-run the new test file: `keeps every whitelisted payload key…` must FAIL (blendMode stripped). Restore the line and re-run: PASS.

- [ ] **Step 7: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
vendor/bin/pint --dirty --format agent
git add app/Services/Studio/StudioOverlayNormalizer.php app/Http/Requests/Studio/UpdateStudioFileOverlaysRequest.php app/Http/Controllers/Api/Studio/StudioFileController.php tests/Feature/Studio/AgentCanvas/StudioOverlayNormalizerTest.php
git commit -m "refactor(api): extract StudioOverlayNormalizer from the overlay PATCH

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: C2 — `POST internal/kv-files/{studioFile}/overlays`

**Files:**
- Create: `app/Services/Studio/AgentCanvas/KvLayerShape.php`, `app/Http/Controllers/Api/Internal/InternalKvOverlaysController.php`
- Modify: `routes/api.php` (internal `RequireInternalToken` group, right after the `internal.kv-files.snapshot` route; add the `use` line next to `InternalKvSnapshotController`)
- Test: `tests/Feature/Studio/AgentCanvas/InternalKvOverlaysTest.php`

**Interfaces:**
- Consumes: `StudioOverlayNormalizer::normalize()` (Task 2).
- Produces:
  - `App\Services\Studio\AgentCanvas\KvLayerShape::RECT_KEYS = ['x','y','width','height','rotation']`, `toRow(array $layer): array` (Layer JSON → flat row: `id, type, x, y, width, height, rotation, z, payload, board_generation_id`, floats for geometry, int `z`), `toLayer(array $row): array` (flat row → Layer JSON `{id, type, rect:{x,y,width,height,rotation}, z, payload, board_generation_id}`), `isUlid(mixed $id): bool`.
  - Route `POST /api/internal/kv-files/{studioFile}/overlays` → `{"count": n}` (C2).

- [ ] **Step 1: Write the failing test**

`tests/Feature/Studio/AgentCanvas/InternalKvOverlaysTest.php`:

```php
<?php

use App\Models\KvGeneration;
use App\Models\Role;
use App\Models\StudioFile;
use App\Models\Tool;
use App\Models\User;
use App\Models\Workspace;
use Illuminate\Support\Str;

beforeEach(function () {
    config(['services.internal.workflow_token' => 'test-internal-token']);
    $this->user = User::factory()->create();
    $this->workspace = Workspace::factory()->create(['type' => 'organization']);
    $this->user->update(['current_workspace_id' => $this->workspace->id]);
    $this->user->workspaces()->attach($this->workspace->id);
    $role = Role::factory()->create(['slug' => 'internal-'.Str::random(6), 'type' => 'workspace', 'scope' => 'internal']);
    $this->user->workspaceRoles()->attach($role->id, ['workspace_id' => $this->workspace->id]);
    $this->file = StudioFile::factory()->create([
        'workspace_id' => $this->workspace->id, 'brand_id' => null, 'tool_id' => Tool::factory()->create()->id,
        'created_by' => $this->user->id, 'last_edited_by' => $this->user->id,
    ]);
    $this->board = KvGeneration::factory()->create(['studio_file_id' => $this->file->id, 'created_by' => $this->user->id]);
});

/** One overlay, in the doc/wire shape collab posts. */
function c2Layer(string $id, array $payload = [], array $rect = []): array
{
    return [
        'id' => $id,
        'type' => 'text',
        'rect' => array_merge(['x' => 0.1, 'y' => 0.2, 'width' => 0.3, 'height' => 0.05, 'rotation' => 0], $rect),
        'z' => 4,
        'payload' => array_merge(['type' => 'text', 'content' => 'Promo', 'color' => '#FFFFFF'], $payload),
        'board_generation_id' => test()->board->id,
    ];
}

function c2Post(array $overlays): Illuminate\Testing\TestResponse
{
    return test()->withHeader('X-Internal-Token', 'test-internal-token')
        ->postJson('/api/internal/kv-files/'.test()->file->id.'/overlays', ['overlays' => $overlays, 'source' => 'agent_write']);
}

it('refuses a caller without the internal token', function () {
    $this->postJson('/api/internal/kv-files/'.$this->file->id.'/overlays', ['overlays' => []])->assertUnauthorized();
});

it('full-replaces the overlays with the flattened, normalised list', function () {
    $this->file->forceFill(['overlays' => [['id' => '01JOLDOVERLAY0000000000000', 'type' => 'text']]])->save();

    c2Post([c2Layer('01JAGENTHEADLINE0000000001', ['bogus' => 1])])->assertOk()->assertExactJson(['count' => 1]);

    $stored = $this->file->fresh()->overlays;
    expect($stored)->toHaveCount(1)
        ->and($stored[0])->toMatchArray([
            'id' => '01JAGENTHEADLINE0000000001', 'type' => 'text', 'x' => 0.1, 'y' => 0.2,
            'width' => 0.3, 'height' => 0.05, 'z' => 4, 'board_generation_id' => $this->board->id,
        ])
        ->and($stored[0]['payload'])->not->toHaveKey('bogus');
});

it('stores exactly what the browser PATCH stores for the same layer', function () {
    $this->actingAs($this->user, 'api');
    $payload = ['name' => 'Headline', 'hidden' => true, 'locked' => true, 'blendMode' => 'screen',
        'fontFamily' => 'bf_01', 'fontSize' => 0.05, 'runs' => [['length' => 2, 'color' => '#FF0000']], 'bogus' => 'x'];
    $layer = c2Layer('01JAGENTHEADLINE0000000001', $payload);

    $flat = ['id' => $layer['id'], 'type' => 'text', 'z' => 4, 'board_generation_id' => $this->board->id, 'payload' => $layer['payload']] + $layer['rect'];
    $this->patchJson("/api/v1/studio/files/{$this->file->id}/overlays", ['overlays' => [$flat]])->assertOk();
    $viaBrowser = collect($this->file->fresh()->overlays)->map(fn ($o) => Illuminate\Support\Arr::except($o, ['created_at', 'updated_at']))->all();

    c2Post([$layer])->assertOk();
    $viaCollab = collect($this->file->fresh()->overlays)->map(fn ($o) => Illuminate\Support\Arr::except($o, ['created_at', 'updated_at']))->all();

    expect($viaCollab)->toBe($viaBrowser);
});

it('drops unsaved tmp_ layers instead of minting ids or failing the batch', function () {
    c2Post([
        c2Layer('tmp_1727600000_ab12cd'),
        c2Layer('01JAGENTHEADLINE0000000001'),
    ])->assertOk()->assertExactJson(['count' => 1]);

    expect(array_column($this->file->fresh()->overlays, 'id'))->toBe(['01JAGENTHEADLINE0000000001']);
});

it('answers an invalid layer with the PATCH validation errors and writes nothing', function () {
    $this->file->forceFill(['overlays' => []])->save();

    c2Post([c2Layer('01JAGENTHEADLINE0000000001', [], ['width' => 0])])
        ->assertStatus(422)
        ->assertJsonValidationErrors(['overlays.0.width']);

    expect($this->file->fresh()->overlays)->toBe([]);
});

it('404s an unknown file', function () {
    $this->withHeader('X-Internal-Token', 'test-internal-token')
        ->postJson('/api/internal/kv-files/'.Str::ulid().'/overlays', ['overlays' => []])
        ->assertNotFound();
});
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/InternalKvOverlaysTest.php --compact`
Expected: FAIL — 404 on the route (and the 401 test may pass already; that is fine).

- [ ] **Step 3: Write `KvLayerShape`**

`app/Services/Studio/AgentCanvas/KvLayerShape.php`:

```php
<?php

namespace App\Services\Studio\AgentCanvas;

/**
 * The two spellings of one overlay. The live Y.Doc and the collab wire use
 * Layer JSON (contract C0: `rect` nested); `studio_files.overlays`, tile
 * snapshots and the browser PATCH use the flat row. Converting in ONE place
 * keeps the keys from drifting between the two.
 */
final class KvLayerShape
{
    public const RECT_KEYS = ['x', 'y', 'width', 'height', 'rotation'];

    /** @return array<string, mixed> */
    public static function toRow(array $layer): array
    {
        $rect = is_array($layer['rect'] ?? null) ? $layer['rect'] : [];
        $bound = $layer['board_generation_id'] ?? null;

        return [
            'id' => (string) ($layer['id'] ?? ''),
            'type' => (string) ($layer['type'] ?? ''),
            'x' => (float) ($rect['x'] ?? 0),
            'y' => (float) ($rect['y'] ?? 0),
            'width' => (float) ($rect['width'] ?? 0),
            'height' => (float) ($rect['height'] ?? 0),
            'rotation' => (float) ($rect['rotation'] ?? 0),
            'z' => (int) ($layer['z'] ?? 0),
            'payload' => is_array($layer['payload'] ?? null) ? $layer['payload'] : [],
            'board_generation_id' => is_string($bound) && $bound !== '' ? $bound : null,
        ];
    }

    /** @return array<string, mixed> */
    public static function toLayer(array $row): array
    {
        return [
            'id' => (string) ($row['id'] ?? ''),
            'type' => (string) ($row['type'] ?? ''),
            'rect' => [
                'x' => (float) ($row['x'] ?? 0),
                'y' => (float) ($row['y'] ?? 0),
                'width' => (float) ($row['width'] ?? 0),
                'height' => (float) ($row['height'] ?? 0),
                'rotation' => (float) ($row['rotation'] ?? 0),
            ],
            'z' => (int) ($row['z'] ?? 0),
            'payload' => is_array($row['payload'] ?? null) ? $row['payload'] : [],
            'board_generation_id' => $row['board_generation_id'] ?? null,
        ];
    }

    public static function isUlid(mixed $id): bool
    {
        return is_string($id) && preg_match('/^[0-9A-Za-z]{26}$/', $id) === 1;
    }
}
```

- [ ] **Step 4: Write the controller and route**

`app/Http/Controllers/Api/Internal/InternalKvOverlaysController.php`:

```php
<?php

namespace App\Http\Controllers\Api\Internal;

use App\Http\Controllers\Controller;
use App\Models\StudioFile;
use App\Services\Studio\AgentCanvas\KvLayerShape;
use App\Services\Studio\StudioOverlayNormalizer;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Log;

/**
 * Contract C2 — collab materialises the live doc's overlays here right after
 * a server write (KV agentic canvas), so export/resize/share paths that read
 * `studio_files.overlays` see agent edits even when no browser is open.
 *
 * Same validation and stamping as the browser PATCH (StudioOverlayNormalizer),
 * same full-replace semantics. One difference, on purpose: only ULID ids are
 * authoritative here and ids are never minted. Collab leaves out unsaved
 * browser layers (`tmp_…`), and the browser mints their ULIDs itself through
 * its own PATCH (useDebouncedOverlaySave strips tmp_ to "missing id"); minting
 * here too would create a second copy of the same layer.
 */
class InternalKvOverlaysController extends Controller
{
    public function store(Request $request, StudioFile $studioFile, StudioOverlayNormalizer $normalizer): JsonResponse
    {
        // Userless back-channel: only the internal shared secret may call this.
        abort_unless($request->attributes->get('auth.via') === 'internal_token', 403);

        $request->validate([
            'overlays' => ['present', 'array'],
            'source' => ['nullable', 'string', 'max:32'],
        ]);

        $rows = [];
        $dropped = 0;
        foreach ((array) $request->input('overlays', []) as $layer) {
            if (! is_array($layer) || ! KvLayerShape::isUlid($layer['id'] ?? null)) {
                $dropped++;

                continue;
            }
            $rows[] = KvLayerShape::toRow($layer);
        }
        if ($dropped > 0) {
            Log::info('kv.overlays.materialize_dropped_unsaved', [
                'studio_file_id' => $studioFile->id,
                'dropped' => $dropped,
            ]);
        }

        $stamped = $normalizer->normalize($rows, $studioFile);
        $studioFile->forceFill(['overlays' => $stamped])->save();

        return response()->json(['count' => count($stamped)]);
    }
}
```

In `routes/api.php`, add `use App\Http\Controllers\Api\Internal\InternalKvOverlaysController;` beside the `InternalKvSnapshotController` import, and directly after

```php
    Route::post('kv-files/{studioFile}/snapshot', [InternalKvSnapshotController::class, 'snapshot'])
        ->name('internal.kv-files.snapshot');
```

add:

```php
    // KV agentic canvas (contract C2): collab materialises the live doc's
    // overlays after a server write. Same validation as the browser PATCH.
    Route::post('kv-files/{studioFile}/overlays', [InternalKvOverlaysController::class, 'store'])
        ->name('internal.kv-files.overlays');
```

- [ ] **Step 5: Run the test**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/InternalKvOverlaysTest.php --compact`
Expected: 6 PASS. Then prove the parity test bites: in the controller replace `$normalizer->normalize($rows, $studioFile)` with `$rows` and re-run — `stores exactly what the browser PATCH stores` and `full-replaces…` must FAIL (bogus kept, no timestamps). Restore.

- [ ] **Step 6: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
vendor/bin/pint --dirty --format agent
git add app/Services/Studio/AgentCanvas/KvLayerShape.php app/Http/Controllers/Api/Internal/InternalKvOverlaysController.php routes/api.php tests/Feature/Studio/AgentCanvas/InternalKvOverlaysTest.php
git commit -m "feat(api): internal kv-files overlays materialisation endpoint (C2)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 4: C6 — `kv_agent_runs` migration and model

**Files:**
- Create: `database/migrations/2026_09_29_200000_create_kv_agent_runs_table.php`, `app/Models/KvAgentRun.php`
- Test: `tests/Feature/Studio/AgentCanvas/KvAgentRunModelTest.php`

**Interfaces:**
- Consumes: nothing.
- Produces `App\Models\KvAgentRun`: consts `STATUS_RUNNING='running'`, `STATUS_COMPLETED='completed'`, `STATUS_UNDONE='undone'`, `STATUS_FAILED='failed'`, `SOURCE_APP='app'`, `SOURCE_MCP='mcp'`, `MAX_OPS=200`; casts `ops`, `skipped`, `detached_sizes`, `undo_result` to arrays; `file(): BelongsTo`; `isUndone(): bool`; `toView(): array` (the C5 run view). Ledger op entry shape (written by Task 11+): `{type: set_layer|add_layer|remove_layer|detach_size, sink: doc|tile, target, target_kind: board|size, target_label, layer_id|null, before, after, at, index?}`; skipped entry `{target, target_kind, target_label, layer_id|null, reason}`; detached entry `{size_id, label}`.

- [ ] **Step 1: Write the failing test**

`tests/Feature/Studio/AgentCanvas/KvAgentRunModelTest.php`:

```php
<?php

use App\Models\KvAgentRun;
use App\Models\StudioFile;
use App\Models\User;
use App\Models\Workspace;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

beforeEach(function () {
    $this->workspace = Workspace::factory()->create();
    $this->user = User::factory()->create(['current_workspace_id' => $this->workspace->id]);
    $this->file = StudioFile::factory()->create(['workspace_id' => $this->workspace->id, 'brand_id' => null]);
});

it('defaults the ledger columns to empty arrays in the database', function () {
    $id = (string) Str::ulid();
    DB::table('kv_agent_runs')->insert([
        'id' => $id, 'studio_file_id' => $this->file->id, 'user_id' => $this->user->id,
        'workspace_id' => $this->workspace->id, 'source' => 'mcp', 'created_at' => now(), 'updated_at' => now(),
    ]);

    $run = KvAgentRun::findOrFail($id);
    expect($run->status)->toBe('running')
        ->and($run->ops)->toBe([])
        ->and($run->skipped)->toBe([])
        ->and($run->detached_sizes)->toBe([])
        ->and($run->undo_result)->toBeNull();
});

it('keeps an uppercase ULID id exactly as given', function () {
    $id = (string) Str::ulid();
    KvAgentRun::create(['id' => $id, 'studio_file_id' => $this->file->id, 'user_id' => $this->user->id,
        'workspace_id' => $this->workspace->id, 'source' => 'app']);

    expect(KvAgentRun::find($id)?->id)->toBe($id)->and($id)->toBe(strtoupper($id));
});

it('renders the C5 run view from the ledger', function () {
    $run = KvAgentRun::create([
        'id' => (string) Str::ulid(), 'studio_file_id' => $this->file->id, 'user_id' => $this->user->id,
        'workspace_id' => $this->workspace->id, 'source' => 'app', 'status' => 'completed',
        'ops' => [
            ['type' => 'detach_size', 'sink' => 'tile', 'target' => 'exp_1', 'target_kind' => 'size', 'target_label' => 'Concept A · Story', 'layer_id' => null, 'before' => null, 'after' => [], 'at' => 'x'],
            ['type' => 'set_layer', 'sink' => 'tile', 'target' => 'exp_1', 'target_kind' => 'size', 'target_label' => 'Concept A · Story', 'layer_id' => 'L1', 'before' => [], 'after' => [], 'at' => 'x'],
        ],
        'skipped' => [['target' => 'exp_2', 'target_kind' => 'size', 'target_label' => 'Concept A · Post', 'layer_id' => 'L1', 'reason' => 'layer_absent_on_size']],
        'detached_sizes' => [['size_id' => 'exp_1', 'label' => 'Concept A · Story']],
    ]);

    expect($run->fresh()->toView())->toMatchArray([
        'id' => $run->id, 'status' => 'completed', 'source' => 'app',
        'applied' => [['target' => 'exp_1', 'target_kind' => 'size', 'target_label' => 'Concept A · Story', 'layer_id' => 'L1', 'op' => 'set_layer']],
        'skipped' => [['target' => 'exp_2', 'target_kind' => 'size', 'target_label' => 'Concept A · Post', 'layer_id' => 'L1', 'reason' => 'layer_absent_on_size']],
        'detached_sizes' => [['size_id' => 'exp_1', 'label' => 'Concept A · Story']],
        'undo' => null,
    ]);
});
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/KvAgentRunModelTest.php --compact`
Expected: FAIL — relation `kv_agent_runs` does not exist / class not found.

- [ ] **Step 3: Write the migration and the model**

`database/migrations/2026_09_29_200000_create_kv_agent_runs_table.php`:

```php
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Query\Expression;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * KV agentic canvas (spec 2026-09-29 §8.1, contract C6): one row per agent
 * run that wrote to a KV canvas. The id IS the run_id — minted per chat turn
 * by ChatService (uppercase `Str::ulid()`, so NOT a HasUlids key, which would
 * lowercase it) or by the api for an MCP caller that sent none. `ops` is the
 * ledger Undo replays newest-first; it is only ever appended to atomically.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('kv_agent_runs', function (Blueprint $table) {
            $table->string('id', 26)->primary();
            $table->foreignUlid('studio_file_id')->constrained('studio_files')->cascadeOnDelete();
            $table->foreignUlid('user_id')->constrained('users')->cascadeOnDelete();
            $table->foreignUlid('workspace_id')->constrained('workspaces')->cascadeOnDelete();
            $table->string('source', 8);
            $table->string('status', 16)->default('running');
            $table->jsonb('ops')->default(new Expression("'[]'::jsonb"));
            $table->jsonb('skipped')->default(new Expression("'[]'::jsonb"));
            $table->jsonb('detached_sizes')->default(new Expression("'[]'::jsonb"));
            $table->jsonb('undo_result')->nullable();
            $table->timestamps();

            $table->index(['studio_file_id', 'created_at']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('kv_agent_runs');
    }
};
```

`app/Models/KvAgentRun.php`:

```php
<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/**
 * One agent run on a KV canvas (spec §8, contract C6). Written only by
 * KvAgentRunRecorder (ledger + status) and KvAgentRunReverter (undo).
 *
 * `ops` entries: {type: set_layer|add_layer|remove_layer|detach_size,
 * sink: doc|tile, target, target_kind: board|size, target_label,
 * layer_id|null, before, after, at, index?}. `before`/`after` are flat rows
 * (a detach's `after` is the whole snapshot it froze).
 */
class KvAgentRun extends Model
{
    public const STATUS_RUNNING = 'running';

    public const STATUS_COMPLETED = 'completed';

    public const STATUS_UNDONE = 'undone';

    public const STATUS_FAILED = 'failed';

    public const SOURCE_APP = 'app';

    public const SOURCE_MCP = 'mcp';

    /** Spec §8.1: ops per run. */
    public const MAX_OPS = 200;

    protected $table = 'kv_agent_runs';

    public $incrementing = false;

    protected $keyType = 'string';

    protected $fillable = [
        'id', 'studio_file_id', 'user_id', 'workspace_id', 'source', 'status',
        'ops', 'skipped', 'detached_sizes', 'undo_result',
    ];

    protected $attributes = [
        'status' => self::STATUS_RUNNING,
        'ops' => '[]',
        'skipped' => '[]',
        'detached_sizes' => '[]',
    ];

    protected function casts(): array
    {
        return [
            'ops' => 'array',
            'skipped' => 'array',
            'detached_sizes' => 'array',
            'undo_result' => 'array',
        ];
    }

    public function file(): BelongsTo
    {
        return $this->belongsTo(StudioFile::class, 'studio_file_id');
    }

    public function isUndone(): bool
    {
        return $this->status === self::STATUS_UNDONE;
    }

    /** Contract C5 run view. */
    public function toView(): array
    {
        $ops = array_values(array_filter($this->ops ?? [], 'is_array'));

        return [
            'id' => $this->id,
            'status' => $this->status,
            'source' => $this->source,
            'created_at' => $this->created_at?->toIso8601String(),
            'applied' => array_values(array_map(static fn (array $op): array => [
                'target' => $op['target'] ?? null,
                'target_kind' => $op['target_kind'] ?? null,
                'target_label' => $op['target_label'] ?? null,
                'layer_id' => $op['layer_id'] ?? null,
                'op' => $op['type'] ?? null,
            ], array_filter($ops, static fn (array $op): bool => ($op['type'] ?? '') !== 'detach_size'))),
            'skipped' => array_values(array_filter($this->skipped ?? [], 'is_array')),
            'detached_sizes' => array_values(array_filter($this->detached_sizes ?? [], 'is_array')),
            'undo' => $this->undo_result,
        ];
    }
}
```

- [ ] **Step 4: Run the test**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/KvAgentRunModelTest.php --compact`
Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
vendor/bin/pint --dirty --format agent
git add database/migrations/2026_09_29_200000_create_kv_agent_runs_table.php app/Models/KvAgentRun.php tests/Feature/Studio/AgentCanvas/KvAgentRunModelTest.php
git commit -m "feat(api): kv_agent_runs ledger table and model (C6)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Exceptions and `KvCollabWriter` (C1 client)

**Files:**
- Create: `app/Exceptions/Studio/KvCollabUnavailableException.php`, `KvLayerChangedException.php`, `KvLayerNotFoundException.php`, `KvCollabRejectedException.php`, `KvCanvasToolException.php`, `KvLayerPatchException.php`; `app/Services/Studio/AgentCanvas/KvCollabWriter.php`
- Test: `tests/Feature/Studio/AgentCanvas/KvCollabWriterTest.php`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `KvCollabUnavailableException`, `KvCollabRejectedException` (extend `RuntimeException`).
  - `KvLayerChangedException(string $layerId, string $errorCode)` with `public readonly string $layerId`, `$errorCode`; `KvLayerNotFoundException(string $layerId)` with `$layerId`.
  - `KvCanvasToolException(int $status, string $errorCode, string $message, array $extra = [])`; statics `unprocessable(code, message, extra = [])` (422), `conflict(code, message, extra = [])` (409), `notFound(message)` (404, code `not_found`); `toResponse(): JsonResponse` → `{"message", "error", "data": null, ...extra}`.
  - `KvLayerPatchException(string $message, string $reason = 'invalid_payload')` with `public readonly string $reason` (a skipped reason from C3.3).
  - `KvCollabWriter::liveDocument(StudioFile $file): array` → C1.1 `document` (`meta`, `boards`, `overlays`, `removed`); throws `KvCollabUnavailableException`.
  - `KvCollabWriter::applyOps(StudioFile $file, array $ops, ?string $runId): array{applied: list<array>, before: array<string, ?array>, materialized: bool}`; throws the four exceptions per Global Constraints. Consts `READ_TIMEOUT_SECONDS = 10`, `WRITE_TIMEOUT_SECONDS = 20`, `BODY_CAP_BYTES = 1_900_000`.

- [ ] **Step 1: Write the failing test**

`tests/Feature/Studio/AgentCanvas/KvCollabWriterTest.php`:

```php
<?php

use App\Exceptions\Studio\KvCollabRejectedException;
use App\Exceptions\Studio\KvCollabUnavailableException;
use App\Exceptions\Studio\KvLayerChangedException;
use App\Exceptions\Studio\KvLayerNotFoundException;
use App\Models\StudioFile;
use App\Services\Studio\AgentCanvas\KvCollabWriter;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;

beforeEach(function () {
    config(['services.collab.url' => 'http://collab.test', 'services.internal.workflow_token' => 'test-internal-token']);
    $this->file = StudioFile::factory()->create(['brand_id' => null]);
    $this->writer = app(KvCollabWriter::class);
    $this->doc = ['meta' => ['schemaVersion' => 2, 'masterGenerationId' => null], 'boards' => [], 'overlays' => [], 'removed' => []];
});

it('reads the live document with the internal token', function () {
    Http::fake(['collab.test/internal/kv-files/*/document' => Http::response(['document' => $this->doc])]);

    expect($this->writer->liveDocument($this->file))->toBe($this->doc);
    Http::assertSent(fn ($r) => $r->method() === 'GET'
        && $r->url() === 'http://collab.test/internal/kv-files/'.$this->file->id.'/document'
        && $r->header('X-Internal-Token') === ['test-internal-token']);
});

it('refuses to read when collab is unreachable, unconfigured, or answers garbage', function (callable $arrange) {
    $arrange();
    expect(fn () => $this->writer->liveDocument($this->file))->toThrow(KvCollabUnavailableException::class);
})->with([
    'unreachable' => fn () => fn () => Http::fake(['collab.test/*' => Http::failedConnection()]),
    'not configured' => fn () => function () { config(['services.collab.url' => '']); Http::fake(); },
    'read_failed 500' => fn () => fn () => Http::fake(['collab.test/*' => Http::response(['error' => 'read_failed'], 500)]),
    'no document' => fn () => fn () => Http::fake(['collab.test/*' => Http::response(['ok' => true])]),
]);

it('posts ops with the run id and returns the pre-images', function () {
    Http::fake(['collab.test/internal/kv-files/*/ops' => Http::response([
        'applied' => [['kind' => 'set_layer', 'layer_id' => 'L1']],
        'before' => ['layers' => ['L1' => ['id' => 'L1']]],
        'materialized' => true,
    ])]);
    $ops = [['kind' => 'set_layer', 'layer_id' => 'L1', 'set' => ['z' => 3], 'expected' => ['z' => 2]]];

    $out = $this->writer->applyOps($this->file, $ops, '01JRUN0000000000000000000A');

    expect($out)->toBe(['applied' => [['kind' => 'set_layer', 'layer_id' => 'L1']], 'before' => ['L1' => ['id' => 'L1']], 'materialized' => true]);
    Http::assertSent(fn ($r) => $r->method() === 'POST' && $r->data() === ['run_id' => '01JRUN0000000000000000000A', 'ops' => $ops]);
});

it('maps every collab refusal to the exception the caller turns into a skip reason', function (int $status, array $body, string $exception) {
    Http::fake(['collab.test/internal/kv-files/*/ops' => Http::response($body, $status)]);
    expect(fn () => $this->writer->applyOps($this->file, [['kind' => 'remove_layer', 'layer_id' => 'L1']], null))->toThrow($exception);
})->with([
    'layer_changed' => [409, ['error' => 'layer_changed', 'layer_id' => 'L1', 'expected' => [], 'current' => []], KvLayerChangedException::class],
    'layer_exists' => [409, ['error' => 'layer_exists', 'layer_id' => 'L1'], KvLayerChangedException::class],
    'layer_not_found' => [404, ['error' => 'layer_not_found', 'layer_id' => 'L1'], KvLayerNotFoundException::class],
    'route not deployed' => [404, ['error' => 'not found'], KvCollabUnavailableException::class],
    'ops_failed' => [500, ['error' => 'ops_failed'], KvCollabUnavailableException::class],
    'invalid_json' => [400, ['error' => 'invalid_json'], KvCollabRejectedException::class],
    'invalid_body' => [422, ['error' => 'invalid_body', 'issues' => []], KvCollabRejectedException::class],
]);

it('carries the layer id on a CAS conflict', function () {
    Http::fake(['collab.test/*' => Http::response(['error' => 'layer_changed', 'layer_id' => 'L7'], 409)]);
    try {
        $this->writer->applyOps($this->file, [['kind' => 'remove_layer', 'layer_id' => 'L7']], null);
        $this->fail('expected a conflict');
    } catch (KvLayerChangedException $e) {
        expect($e->layerId)->toBe('L7')->and($e->errorCode)->toBe('layer_changed');
    }
});

it('logs an unreachable write loudly instead of failing silently', function () {
    Log::spy();
    Http::fake(['collab.test/*' => Http::failedConnection()]);

    expect(fn () => $this->writer->applyOps($this->file, [['kind' => 'remove_layer', 'layer_id' => 'L1']], null))
        ->toThrow(KvCollabUnavailableException::class);
    Log::shouldHaveReceived('error')->withArgs(fn ($message) => $message === 'kv.collab.ops_unreachable')->once();
});

it('refuses a body over the collab cap without sending it', function () {
    Http::fake();
    $huge = [['kind' => 'add_layer', 'layer' => ['id' => 'L1', 'payload' => ['content' => str_repeat('x', 2_000_000)]]]];

    expect(fn () => $this->writer->applyOps($this->file, $huge, null))->toThrow(KvCollabRejectedException::class);
    Http::assertNothingSent();
});

it('gives the write enough time for collab to materialise first', function () {
    expect(KvCollabWriter::WRITE_TIMEOUT_SECONDS)->toBeGreaterThanOrEqual(15)
        ->and(KvCollabWriter::READ_TIMEOUT_SECONDS)->toBe(10);
});
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/KvCollabWriterTest.php --compact`
Expected: FAIL — classes not found.

- [ ] **Step 3: Write the exceptions**

`app/Exceptions/Studio/KvCollabUnavailableException.php`:

```php
<?php

namespace App\Exceptions\Studio;

use RuntimeException;

/** Collab could not be read or did not accept a write (skipped reason `collab_unavailable`, or 503). */
class KvCollabUnavailableException extends RuntimeException {}
```

`app/Exceptions/Studio/KvCollabRejectedException.php`:

```php
<?php

namespace App\Exceptions\Studio;

use RuntimeException;

/** Collab refused the body itself (400/422/too large) — an api bug, reported as `invalid_payload`. */
class KvCollabRejectedException extends RuntimeException {}
```

`app/Exceptions/Studio/KvLayerChangedException.php`:

```php
<?php

namespace App\Exceptions\Studio;

use RuntimeException;

/** Collab 409: the layer no longer matches `expected` (or an add hit an existing id). */
class KvLayerChangedException extends RuntimeException
{
    public function __construct(public readonly string $layerId, public readonly string $errorCode = 'layer_changed')
    {
        parent::__construct("Layer {$layerId} changed on the canvas ({$errorCode}).");
    }
}
```

`app/Exceptions/Studio/KvLayerNotFoundException.php`:

```php
<?php

namespace App\Exceptions\Studio;

use RuntimeException;

/** Collab 404 `layer_not_found`. */
class KvLayerNotFoundException extends RuntimeException
{
    public function __construct(public readonly string $layerId)
    {
        parent::__construct("Layer {$layerId} is not on the canvas.");
    }
}
```

`app/Exceptions/Studio/KvLayerPatchException.php`:

```php
<?php

namespace App\Exceptions\Studio;

use RuntimeException;

/** One target cannot take this edit; `$reason` is the C3.3 skipped reason. */
class KvLayerPatchException extends RuntimeException
{
    public function __construct(string $message, public readonly string $reason = 'invalid_payload')
    {
        parent::__construct($message);
    }
}
```

`app/Exceptions/Studio/KvCanvasToolException.php`:

```php
<?php

namespace App\Exceptions\Studio;

use Illuminate\Http\JsonResponse;
use RuntimeException;

/** A whole-call refusal of a canvas tool, rendered as `{message, error, data: null, ...extra}`. */
class KvCanvasToolException extends RuntimeException
{
    /** @param  array<string, mixed>  $extra */
    public function __construct(
        public readonly int $status,
        public readonly string $errorCode,
        string $message,
        public readonly array $extra = [],
    ) {
        parent::__construct($message);
    }

    /** @param  array<string, mixed>  $extra */
    public static function unprocessable(string $code, string $message, array $extra = []): self
    {
        return new self(422, $code, $message, $extra);
    }

    /** @param  array<string, mixed>  $extra */
    public static function conflict(string $code, string $message, array $extra = []): self
    {
        return new self(409, $code, $message, $extra);
    }

    public static function notFound(string $message): self
    {
        return new self(404, 'not_found', $message);
    }

    public function toResponse(): JsonResponse
    {
        return response()->json(
            ['message' => $this->getMessage(), 'error' => $this->errorCode, 'data' => null] + $this->extra,
            $this->status,
        );
    }
}
```

- [ ] **Step 4: Write `KvCollabWriter`**

`app/Services/Studio/AgentCanvas/KvCollabWriter.php`:

```php
<?php

namespace App\Services\Studio\AgentCanvas;

use App\Exceptions\Studio\KvCollabRejectedException;
use App\Exceptions\Studio\KvCollabUnavailableException;
use App\Exceptions\Studio\KvLayerChangedException;
use App\Exceptions\Studio\KvLayerNotFoundException;
use App\Models\StudioFile;
use Illuminate\Http\Client\PendingRequest;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;

/**
 * HTTP client for the collab KV routes (contract C1). The KV mirror of
 * DeckCollabWriter, for the same reason: frnd-hocuspocus owns the live
 * Y.Doc and every open tab autosaves a full replace of the overlays from it,
 * so a server write anywhere else is erased the next time a tab saves.
 *
 * Posture: every failure is logged and raised, never swallowed. There is no
 * fallback read of `studio_files.overlays` — collab backfills a never-opened
 * doc itself, so an unreadable collab really means "cannot act now".
 * No `Http::retry()`: it throws by default and would make the status
 * branches below dead code.
 */
final class KvCollabWriter
{
    public const READ_TIMEOUT_SECONDS = 10;

    /**
     * Collab applies the ops, then materialises the overlays back to api
     * (C2) with up to ~9.75 s of retries, and only then answers. The write
     * therefore needs more than the read's budget, or a slow materialisation
     * reads here as an outage while the write actually landed.
     */
    public const WRITE_TIMEOUT_SECONDS = 20;

    /** The collab body cap (2 MB) less envelope headroom. */
    public const BODY_CAP_BYTES = 1_900_000;

    /**
     * @return array{meta: array<string,mixed>, boards: array<string,mixed>, overlays: list<array<string,mixed>>, removed: list<string>}
     *
     * @throws KvCollabUnavailableException
     */
    public function liveDocument(StudioFile $file): array
    {
        $base = $this->base('The canvas could not be read');
        $url = $base.'/internal/kv-files/'.rawurlencode($file->id).'/document';

        try {
            $response = $this->request(self::READ_TIMEOUT_SECONDS)->get($url);
        } catch (\Throwable $e) {
            Log::error('kv.collab.read_unreachable', ['studio_file_id' => $file->id, 'message' => $e->getMessage()]);

            throw new KvCollabUnavailableException('The canvas could not be read because the collaboration service is unreachable.');
        }

        $document = $response->successful() ? $response->json('document') : null;
        if (! is_array($document) || ! is_array($document['boards'] ?? null) || ! is_array($document['overlays'] ?? null)) {
            Log::error('kv.collab.read_unusable', [
                'studio_file_id' => $file->id,
                'status' => $response->status(),
                'body' => mb_substr($response->body(), 0, 500),
            ]);

            throw new KvCollabUnavailableException('The canvas could not be read from the collaboration service (status '.$response->status().').');
        }

        return $document;
    }

    /**
     * @param  list<array<string, mixed>>  $ops
     * @return array{applied: list<array<string,mixed>>, before: array<string, ?array<string,mixed>>, materialized: bool}
     *
     * @throws KvCollabUnavailableException|KvLayerChangedException|KvLayerNotFoundException|KvCollabRejectedException
     */
    public function applyOps(StudioFile $file, array $ops, ?string $runId): array
    {
        $base = $this->base('The canvas could not be changed');
        $body = ['run_id' => $runId, 'ops' => array_values($ops)];
        $log = ['studio_file_id' => $file->id, 'run_id' => $runId, 'op_count' => count($ops)];

        $encoded = json_encode($body);
        if ($encoded === false || strlen($encoded) > self::BODY_CAP_BYTES) {
            Log::error('kv.collab.ops_too_large', $log + ['bytes' => $encoded === false ? null : strlen($encoded)]);

            throw new KvCollabRejectedException('The change is too large to send to the canvas in one write.');
        }

        try {
            $response = $this->request(self::WRITE_TIMEOUT_SECONDS)
                ->post($base.'/internal/kv-files/'.rawurlencode($file->id).'/ops', $body);
        } catch (\Throwable $e) {
            Log::error('kv.collab.ops_unreachable', $log + ['message' => $e->getMessage()]);

            throw new KvCollabUnavailableException('The canvas could not be changed because the collaboration service is unreachable.');
        }

        if ($response->successful()) {
            $materialized = (bool) $response->json('materialized', false);
            if (! $materialized) {
                // The write landed in the live doc; REST readers catch up on
                // the next materialisation (the next tab autosave or snapshot).
                Log::warning('kv.collab.ops_not_materialized', $log);
            }

            return [
                'applied' => array_values((array) $response->json('applied', [])),
                'before' => (array) $response->json('before.layers', []),
                'materialized' => $materialized,
            ];
        }

        $status = $response->status();
        $code = (string) $response->json('error', '');
        Log::warning('kv.collab.ops_refused', $log + ['status' => $status, 'error' => $code, 'body' => mb_substr($response->body(), 0, 500)]);

        if ($status === 409 && in_array($code, ['layer_changed', 'layer_exists'], true)) {
            throw new KvLayerChangedException((string) $response->json('layer_id', ''), $code);
        }
        if ($status === 404 && $code === 'layer_not_found') {
            throw new KvLayerNotFoundException((string) $response->json('layer_id', ''));
        }
        if (in_array($status, [400, 422], true)) {
            Log::error('kv.collab.ops_rejected', $log + ['status' => $status, 'error' => $code]);

            throw new KvCollabRejectedException("The collaboration service rejected the change ({$code}).");
        }

        // 5xx (ops_failed / read_failed), a bare 404 (route not deployed yet),
        // anything else: the write did not land.
        throw new KvCollabUnavailableException("The canvas could not be changed because the collaboration service did not accept the write (status {$status}).");
    }

    private function base(string $what): string
    {
        $base = rtrim((string) config('services.collab.url'), '/');
        if ($base === '') {
            Log::error('kv.collab.not_configured');

            throw new KvCollabUnavailableException($what.' because the collaboration service is not configured.');
        }

        return $base;
    }

    private function request(int $timeout): PendingRequest
    {
        return Http::withHeaders(['X-Internal-Token' => (string) config('services.internal.workflow_token')])
            ->acceptJson()
            ->timeout($timeout);
    }
}
```

- [ ] **Step 5: Run the test**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/KvCollabWriterTest.php --compact`
Expected: all PASS (7 dataset rows + 6 single tests).

- [ ] **Step 6: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
vendor/bin/pint --dirty --format agent
git add app/Exceptions/Studio app/Services/Studio/AgentCanvas/KvCollabWriter.php tests/Feature/Studio/AgentCanvas/KvCollabWriterTest.php
git commit -m "feat(api): KvCollabWriter for the collab KV document and ops routes

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: `KvImageDimensions`

**Files:**
- Create: `app/Support/Studio/KvImageDimensions.php`
- Test: `tests/Feature/Studio/AgentCanvas/KvImageDimensionsTest.php`

**Interfaces:**
- Consumes: nothing.
- Produces `App\Support\Studio\KvImageDimensions`:
  - `forGeneration(KvGeneration $g): ?array{width:int,height:int}` — `metadata.width/height` when present (uploads), else probes `image_url` (AI renders carry no dimensions).
  - `forUrl(string $url): ?array{width:int,height:int,mime:string}` — ranged GET (first 128 KB) then one full GET; cached forever per URL on success; null when unreadable (logged).

- [ ] **Step 1: Write the failing test**

`tests/Feature/Studio/AgentCanvas/KvImageDimensionsTest.php`:

```php
<?php

use App\Models\KvGeneration;
use App\Support\Studio\KvImageDimensions;
use Illuminate\Support\Facades\Http;

function kvDimsPng(int $w, int $h): string
{
    $image = imagecreatetruecolor($w, $h);
    ob_start();
    imagepng($image);

    return (string) ob_get_clean();
}

it('uses the generation metadata when it carries dimensions', function () {
    Http::fake();
    $g = KvGeneration::factory()->create(['metadata' => ['width' => 1080, 'height' => 1350]]);

    expect(app(KvImageDimensions::class)->forGeneration($g))->toBe(['width' => 1080, 'height' => 1350]);
    Http::assertNothingSent();
});

it('probes the image with a ranged request when the metadata has none, and caches it', function () {
    Http::fake(['s3.test/*' => Http::response(kvDimsPng(64, 40), 200, ['Content-Type' => 'image/png'])]);
    $g = KvGeneration::factory()->create(['metadata' => [], 'image_url' => 'https://s3.test/frnd/kv/a.png']);

    $dims = app(KvImageDimensions::class);
    expect($dims->forGeneration($g))->toBe(['width' => 64, 'height' => 40])
        ->and($dims->forUrl('https://s3.test/frnd/kv/a.png'))->toBe(['width' => 64, 'height' => 40, 'mime' => 'image/png']);

    Http::assertSentCount(1);
    Http::assertSent(fn ($r) => str_starts_with((string) ($r->header('Range')[0] ?? ''), 'bytes=0-'));
});

it('answers null for an unreadable image', function () {
    Http::fake(['s3.test/*' => Http::response('nope', 404)]);

    expect(app(KvImageDimensions::class)->forUrl('https://s3.test/frnd/missing.png'))->toBeNull();
});
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/KvImageDimensionsTest.php --compact`
Expected: FAIL — class not found.

- [ ] **Step 3: Implement**

`app/Support/Studio/KvImageDimensions.php`:

```php
<?php

namespace App\Support\Studio;

use App\Models\KvGeneration;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;

/**
 * Pixel size of a board image or an asset. Uploads record it in
 * `metadata.width/height`; AI renders do not (ai-service's generation
 * metadata has none), so those are probed once and cached forever — an
 * image at a URL never changes size. A ranged GET reads only the header
 * bytes getimagesizefromstring() needs; a server that ignores Range simply
 * answers with the whole body, which works too.
 */
final class KvImageDimensions
{
    private const PROBE_BYTES = 131_071;

    private const MAX_BYTES = 15_000_000;

    /** @return array{width:int,height:int}|null */
    public function forGeneration(KvGeneration $generation): ?array
    {
        $meta = is_array($generation->metadata) ? $generation->metadata : [];
        $width = (int) ($meta['width'] ?? 0);
        $height = (int) ($meta['height'] ?? 0);
        if ($width > 0 && $height > 0) {
            return ['width' => $width, 'height' => $height];
        }

        $url = (string) ($generation->image_url ?? '');
        $probe = $url === '' ? null : $this->forUrl($url);

        return $probe === null ? null : ['width' => $probe['width'], 'height' => $probe['height']];
    }

    /** @return array{width:int,height:int,mime:string}|null */
    public function forUrl(string $url): ?array
    {
        $key = 'kv-image-dims:'.sha1($url);
        $cached = Cache::get($key);
        if (is_array($cached)) {
            return $cached;
        }

        $probe = $this->probe($url);
        if ($probe !== null) {
            Cache::forever($key, $probe);
        }

        return $probe;
    }

    /** @return array{width:int,height:int,mime:string}|null */
    private function probe(string $url): ?array
    {
        foreach ([['Range' => 'bytes=0-'.self::PROBE_BYTES], []] as $headers) {
            try {
                $response = Http::timeout(10)->withHeaders($headers)->get($url);
            } catch (\Throwable $e) {
                Log::warning('kv.image_dims.unreachable', ['url' => $url, 'message' => $e->getMessage()]);

                return null;
            }
            if (! $response->successful()) {
                Log::warning('kv.image_dims.refused', ['url' => $url, 'status' => $response->status()]);

                return null;
            }

            $body = $response->body();
            if (strlen($body) > self::MAX_BYTES) {
                return null;
            }
            $info = @getimagesizefromstring($body);
            if (is_array($info) && $info[0] > 0 && $info[1] > 0) {
                return ['width' => (int) $info[0], 'height' => (int) $info[1], 'mime' => (string) ($info['mime'] ?? '')];
            }
            if ($headers === []) {
                break;
            }
        }

        Log::warning('kv.image_dims.unreadable', ['url' => $url]);

        return null;
    }
}
```

- [ ] **Step 4: Run the test**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/KvImageDimensionsTest.php --compact`
Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
vendor/bin/pint --dirty --format agent
git add app/Support/Studio/KvImageDimensions.php tests/Feature/Studio/AgentCanvas/KvImageDimensionsTest.php
git commit -m "feat(api): KvImageDimensions for board and asset pixel sizes

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: `KvTileOverlayProjector` — PHP port of `resolveTileOverlays`, pinned by generated fixtures

Detaching an inheriting size must freeze exactly what the browser shows for it (`web/src/lib/studio/kv/overlayAspect.ts::resolveTileOverlays` over `overlayMutations.ts::overlaysForResizeSource`, as `KvCanvas.tsx` and `resizeBoardOverlays.ts` call it). The expected values are produced by running that TypeScript, never typed by hand.

**Files:**
- Create: `tests/Fixtures/kv-projection/generate.ts`, `tests/Fixtures/kv-projection/cases.json` (generated), `app/Services/Studio/AgentCanvas/KvTileOverlayProjector.php`
- Test: `tests/Unit/Studio/AgentCanvas/KvTileOverlayProjectorTest.php`

**Interfaces:**
- Consumes: nothing.
- Produces `App\Services\Studio\AgentCanvas\KvTileOverlayProjector`:
  - `static overlaysForResizeSource(array $rows, string $sourceId, ?array $versionIds): array` — unbound rows, rows bound to `$sourceId`, rows bound to any id in `$versionIds`.
  - `resolve(?array $tileSnapshot, array $projectRows, float $srcW, float $srcH, float $dstW, float $dstH): array` — `null` snapshot ⇒ projection; any array (including `[]`) ⇒ returned untouched. Rows are flat rows; geometry comes back as floats.

- [ ] **Step 1: Write the fixture generator**

`tests/Fixtures/kv-projection/generate.ts`:

```ts
/**
 * Generates cases.json by running the REAL web projection
 * (web/src/lib/studio/kv/overlayAspect.ts). Expected values are never typed
 * by hand: when the TypeScript changes, re-run this and commit the result.
 *
 *   cd api && bun run tests/Fixtures/kv-projection/generate.ts > tests/Fixtures/kv-projection/cases.json
 *
 * Needs the sibling web/ checkout with its node_modules (bun resolves the
 * module's own "@/..." imports through web/tsconfig.json).
 */
import { resolveTileOverlays } from "../../../../web/src/lib/studio/kv/overlayAspect";

type Payload = Record<string, unknown>;
const img: Payload = { type: "image", asset_url: "https://s3.test/frnd/a.png", mime_type: "image/png" };
const txt = (extra: Payload = {}): Payload => ({ type: "text", content: "Promo", color: "#FFFFFF", ...extra });
const L = (id: string, x: number, y: number, w: number, h: number, payload: Payload = img, z = 0) => ({
  id, type: payload.type, x, y, width: w, height: h, rotation: 0, z, payload, board_generation_id: "gen_a",
});

const cases = [
  { name: "left_top_anchored_singleton_portrait", src: [1080, 1350], dst: [1080, 1920], layers: [L("logo", 0.03, 0.03, 0.2, 0.08)] },
  { name: "right_bottom_anchored_singleton", src: [1080, 1080], dst: [1920, 1080], layers: [L("cta", 0.75, 0.9, 0.22, 0.07)] },
  { name: "centered_text_with_styling", src: [1080, 1350], dst: [1080, 1920], layers: [L("head", 0.2, 0.4, 0.6, 0.1, txt({ fontSize: 0.05, letterSpacing: 0.002, paragraphSpacing: 0.01, runs: [{ length: 2, fontSize: 0.08 }, { length: 3 }] }))] },
  { name: "cluster_logo_and_tagline", src: [1080, 1080], dst: [1080, 1920], layers: [L("logo", 0.1, 0.1, 0.2, 0.1), L("tag", 0.1, 0.22, 0.4, 0.06, txt({ fontSize: 0.04 }))] },
  { name: "covering_background_plus_foreground", src: [1080, 1350], dst: [1920, 1080], layers: [L("bg", 0, 0, 1, 1, img, 0), L("head", 0.1, 0.1, 0.5, 0.1, txt({ fontSize: 0.05 }), 1)] },
  { name: "same_aspect_clamps_only_invisible", src: [1080, 1080], dst: [2160, 2160], layers: [L("off", 0.2, 1.05, 0.2, 0.1), L("bleed", -0.1, 0.5, 0.5, 0.2)] },
  { name: "extreme_banner_coverage_cap", src: [1080, 1080], dst: [1920, 300], layers: [L("big", 0.3, 0.3, 0.4, 0.4)] },
  { name: "overlap_growth_uniform_union_fit", src: [1080, 1920], dst: [1920, 1080], layers: [L("a", 0.1, 0.2, 0.8, 0.25), L("b", 0.1, 0.55, 0.8, 0.25)] },
  { name: "empty_project", src: [1080, 1080], dst: [1080, 1920], layers: [] },
  { name: "zero_source_dims_passthrough", src: [0, 0], dst: [1080, 1920], layers: [L("x", 0.1, 0.1, 0.2, 0.2)] },
];

const out = cases.map((c) => ({
  ...c,
  expected: resolveTileOverlays(null, c.layers as never, c.src[0], c.src[1], c.dst[0], c.dst[1]),
}));
console.log(JSON.stringify(out, null, 2));
```

- [ ] **Step 2: Generate the fixtures from the TypeScript**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
bun run tests/Fixtures/kv-projection/generate.ts > tests/Fixtures/kv-projection/cases.json
php -r '$c = json_decode(file_get_contents("tests/Fixtures/kv-projection/cases.json"), true); echo count($c), " cases\n";'
```
Expected: `10 cases`. (The `overlap_growth_uniform_union_fit` case was chosen by running the TS: both layers come back with one shared scale factor, i.e. the union-fit branch ran.)

- [ ] **Step 3: Write the failing test**

`tests/Unit/Studio/AgentCanvas/KvTileOverlayProjectorTest.php`:

```php
<?php

use App\Services\Studio\AgentCanvas\KvTileOverlayProjector;

function projectionCases(): array
{
    return json_decode((string) file_get_contents(__DIR__.'/../../../Fixtures/kv-projection/cases.json'), true);
}

it('matches the TypeScript projection', function (array $case) {
    $out = (new KvTileOverlayProjector)->resolve(null, $case['layers'], $case['src'][0], $case['src'][1], $case['dst'][0], $case['dst'][1]);

    expect(array_column($out, 'id'))->toBe(array_column($case['expected'], 'id'));
    foreach ($case['expected'] as $i => $want) {
        foreach (['x', 'y', 'width', 'height'] as $key) {
            expect(abs((float) $out[$i][$key] - (float) $want[$key]))
                ->toBeLessThan(1e-9, "{$case['name']} {$want['id']}.{$key}");
        }
        foreach (['fontSize', 'letterSpacing', 'paragraphSpacing'] as $key) {
            if (isset($want['payload'][$key])) {
                expect(abs((float) $out[$i]['payload'][$key] - (float) $want['payload'][$key]))
                    ->toBeLessThan(1e-9, "{$case['name']} {$want['id']}.payload.{$key}");
            }
        }
        foreach ($want['payload']['runs'] ?? [] as $r => $run) {
            expect($out[$i]['payload']['runs'][$r]['fontSize'] ?? null)
                ->toEqualWithDelta($run['fontSize'] ?? null, 1e-9);
        }
    }
})->with(function () {
    foreach (projectionCases() as $case) {
        yield $case['name'] => [$case];
    }
});

it('the fixtures actually move layers, so the parity test is not an identity check', function () {
    $moved = 0;
    foreach (projectionCases() as $case) {
        foreach ($case['expected'] as $i => $want) {
            $in = $case['layers'][$i];
            if (abs($want['y'] - $in['y']) > 1e-6 || abs($want['height'] - $in['height']) > 1e-6) {
                $moved++;
            }
        }
    }
    expect($moved)->toBeGreaterThanOrEqual(8);
});

it('returns any snapshot untouched, including a deliberately empty one', function () {
    $projector = new KvTileOverlayProjector;
    $row = ['id' => 'a', 'type' => 'image', 'x' => 2.0, 'y' => 2.0, 'width' => 0.1, 'height' => 0.1, 'rotation' => 0.0, 'z' => 0, 'payload' => ['type' => 'image']];

    expect($projector->resolve([], [$row], 1080, 1080, 1080, 1920))->toBe([])
        ->and($projector->resolve([$row], [], 1080, 1080, 1080, 1920))->toBe([$row]);
});

it('scopes the project layers to the board being resized, keeping unbound ones', function () {
    $rows = [
        ['id' => 'unbound', 'board_generation_id' => null],
        ['id' => 'tip', 'board_generation_id' => 'gen_b'],
        ['id' => 'older', 'board_generation_id' => 'gen_a'],
        ['id' => 'other', 'board_generation_id' => 'gen_z'],
    ];

    expect(array_column(KvTileOverlayProjector::overlaysForResizeSource($rows, 'gen_b', ['gen_a', 'gen_b']), 'id'))
        ->toBe(['unbound', 'tip', 'older'])
        ->and(array_column(KvTileOverlayProjector::overlaysForResizeSource($rows, 'gen_b', null), 'id'))
        ->toBe(['unbound', 'tip']);
});
```

- [ ] **Step 4: Run it to see it fail**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && vendor/bin/pest tests/Unit/Studio/AgentCanvas/KvTileOverlayProjectorTest.php --compact`
Expected: FAIL — class not found.

- [ ] **Step 5: Implement the port**

`app/Services/Studio/AgentCanvas/KvTileOverlayProjector.php` (function-by-function port of `overlayAspect.ts`; the comments there explain every constant — keep the two in step):

```php
<?php

namespace App\Services\Studio\AgentCanvas;

/**
 * PHP port of web `resolveTileOverlays` (web/src/lib/studio/kv/overlayAspect.ts)
 * and `overlaysForResizeSource` (overlayMutations.ts): the layers an INHERITING
 * resize tile shows. Used only where the server must FREEZE that list into a
 * tile snapshot (an agent edit aimed at one inheriting size, spec §6). Every
 * other reader keeps projecting on the client from the inputs
 * (KvSharePayloadService), so this port must return what the browser draws at
 * the moment of detaching, or the tile visibly jumps.
 *
 * Parity is pinned by tests/Unit/Studio/AgentCanvas/KvTileOverlayProjectorTest.php
 * against fixtures GENERATED from the TypeScript (tests/Fixtures/kv-projection).
 * Changing the TS means regenerating them — and then this file.
 */
final class KvTileOverlayProjector
{
    private const ANCHOR_THRESHOLD = 0.08;

    private const COVERAGE_CAP = 0.6;

    private const CLUSTER_THRESHOLD = 0.12;

    private const OVERLAP_GROWTH_TOLERANCE = 0.01;

    /**
     * @param  list<array<string,mixed>>  $rows
     * @param  list<string>|null  $versionIds
     * @return list<array<string,mixed>>
     */
    public static function overlaysForResizeSource(array $rows, string $sourceId, ?array $versionIds): array
    {
        $chain = is_array($versionIds) && $versionIds !== [] ? array_flip(array_filter($versionIds, 'is_string')) : null;

        return array_values(array_filter($rows, static function (array $o) use ($sourceId, $chain): bool {
            $bound = $o['board_generation_id'] ?? null;
            if ($bound === null) {
                return true;
            }
            if ($bound === $sourceId) {
                return true;
            }

            return $chain !== null && isset($chain[$bound]);
        }));
    }

    /**
     * @param  list<array<string,mixed>>|null  $tileSnapshot  null = inherit. An array — even [] — is a
     *                                                         snapshot and comes back untouched (JS `if ([])` is truthy; PHP's
     *                                                         is not, hence the explicit null test).
     * @param  list<array<string,mixed>>  $projectRows
     * @return list<array<string,mixed>>
     */
    public function resolve(?array $tileSnapshot, array $projectRows, float $srcW, float $srcH, float $dstW, float $dstH): array
    {
        if ($tileSnapshot !== null) {
            return $tileSnapshot;
        }
        if ($projectRows === []) {
            return [];
        }
        $project = array_map(self::numeric(...), array_values($projectRows));

        // The TS would divide by zero further down (NaN, no clustering). The
        // server never projects from an unmeasured board (callers skip it),
        // so return the input rather than port the NaN behaviour.
        if ($srcW <= 0 || $srcH <= 0 || $dstW <= 0 || $dstH <= 0) {
            return $project;
        }

        if (abs($srcW / $srcH - $dstW / $dstH) < 1e-6) {
            return array_map(static fn (array $o): array => self::hasVisibleArea($o) ? $o : self::clampOverlayToCanvas($o), $project);
        }

        $covering = self::coveringLayerIds($project);
        $rest = array_values(array_filter($project, static fn (array $o): bool => ! isset($covering[$o['id']])));
        $resolved = [];

        if ($rest !== []) {
            $pairs = [];
            foreach (self::detectGroups($rest, $srcW, $srcH) as $indices) {
                if (count($indices) === 1) {
                    $src = $rest[$indices[0]];
                    $pairs[] = [$src, self::capOverlayCoverage(self::transformOverlayForAspect($src, $srcW, $srcH, $dstW, $dstH), $src)];

                    continue;
                }
                $cluster = array_map(static fn (int $i): array => $rest[$i], $indices);
                $projected = self::transformGroupForAspect($cluster, $srcW, $srcH, $dstW, $dstH);
                foreach ($cluster as $k => $src) {
                    $pairs[] = [$src, $projected[$k]];
                }
            }
            foreach ($pairs as [$src, $out]) {
                $resolved[$src['id']] = self::scaleTextStylingWithHeight(self::clampOverlayToCanvas($out), $src);
            }
            if (self::projectionGrewOverlap($rest, $resolved, $srcW, $srcH, $dstW, $dstH)) {
                foreach (self::uniformUnionFit($rest, $srcW, $srcH, $dstW, $dstH) as $o) {
                    $resolved[$o['id']] = $o;
                }
            }
        }

        foreach ($project as $o) {
            if (isset($covering[$o['id']])) {
                $resolved[$o['id']] = self::coverProjectOverlay($o, $srcW, $srcH, $dstW, $dstH);
            }
        }

        return array_map(static fn (array $o): array => $resolved[$o['id']] ?? $o, $project);
    }

    private static function numeric(array $o): array
    {
        foreach (['x', 'y', 'width', 'height', 'rotation'] as $key) {
            $o[$key] = (float) ($o[$key] ?? 0);
        }
        $o['id'] = (string) ($o['id'] ?? '');

        return $o;
    }

    private static function coverageBudget(float $sourceCoverage): float
    {
        return min(1.0, max($sourceCoverage, self::COVERAGE_CAP));
    }

    private static function transformOverlayForAspect(array $o, float $srcW, float $srcH, float $dstW, float $dstH): array
    {
        if ($srcW <= 0 || $srcH <= 0 || $dstW <= 0 || $dstH <= 0) {
            return $o;
        }
        if (abs($srcW / $srcH - $dstW / $dstH) < 1e-6) {
            return $o;
        }

        $x = $o['x'];
        $y = $o['y'];
        $w = $o['width'];
        $h = $o['height'];
        $newW = $w * ($srcW / $dstW);
        $newH = $h * ($srcH / $dstH);

        $shortestSrc = min($srcW, $srcH);
        $shortestDst = min($dstW, $dstH);
        $leftDist = ($x * $srcW) / $shortestSrc;
        $rightDist = ((1 - $x - $w) * $srcW) / $shortestSrc;
        $topDist = ($y * $srcH) / $shortestSrc;
        $bottomDist = ((1 - $y - $h) * $srcH) / $shortestSrc;

        $leftValid = $leftDist >= 0 && $leftDist < self::ANCHOR_THRESHOLD;
        $rightValid = $rightDist >= 0 && $rightDist < self::ANCHOR_THRESHOLD;
        if ($leftValid && (! $rightValid || $leftDist <= $rightDist)) {
            $newX = ($leftDist * $shortestDst) / $dstW;
        } elseif ($rightValid) {
            $newX = 1 - $newW - ($rightDist * $shortestDst) / $dstW;
        } else {
            $newX = $x + $w / 2 - $newW / 2;
        }

        $topValid = $topDist >= 0 && $topDist < self::ANCHOR_THRESHOLD;
        $bottomValid = $bottomDist >= 0 && $bottomDist < self::ANCHOR_THRESHOLD;
        if ($topValid && (! $bottomValid || $topDist <= $bottomDist)) {
            $newY = ($topDist * $shortestDst) / $dstH;
        } elseif ($bottomValid) {
            $newY = 1 - $newH - ($bottomDist * $shortestDst) / $dstH;
        } else {
            $newY = $y + $h / 2 - $newH / 2;
        }

        return array_merge($o, ['x' => $newX, 'y' => $newY, 'width' => $newW, 'height' => $newH]);
    }

    private static function coverProjectOverlay(array $o, float $srcW, float $srcH, float $dstW, float $dstH): array
    {
        if ($srcW <= 0 || $srcH <= 0 || $dstW <= 0 || $dstH <= 0) {
            return $o;
        }
        $pxW = $o['width'] * $srcW;
        $pxH = $o['height'] * $srcH;
        if ($pxW <= 0 || $pxH <= 0) {
            return $o;
        }

        $scale = max($dstW / $pxW, $dstH / $pxH);
        $newW = ($pxW * $scale) / $dstW;
        $newH = ($pxH * $scale) / $dstH;
        $cx = $o['x'] + $o['width'] / 2;
        $cy = $o['y'] + $o['height'] / 2;
        $newX = min(0.0, max($cx - $newW / 2, 1 - $newW));
        $newY = min(0.0, max($cy - $newH / 2, 1 - $newH));

        return array_merge($o, ['x' => $newX, 'y' => $newY, 'width' => $newW, 'height' => $newH]);
    }

    /** @return array<string, true> */
    private static function coveringLayerIds(array $overlays): array
    {
        $ids = [];
        foreach ($overlays as $o) {
            if ($o['x'] <= 0 && $o['y'] <= 0 && $o['x'] + $o['width'] >= 1 && $o['y'] + $o['height'] >= 1) {
                $ids[$o['id']] = true;
            }
        }

        return $ids;
    }

    private static function bboxDistance(array $a, array $b, float $srcW, float $srcH): float
    {
        $shortest = min($srcW, $srcH);
        $aLeft = $a['x'] * $srcW;
        $aRight = ($a['x'] + $a['width']) * $srcW;
        $aTop = $a['y'] * $srcH;
        $aBottom = ($a['y'] + $a['height']) * $srcH;
        $bLeft = $b['x'] * $srcW;
        $bRight = ($b['x'] + $b['width']) * $srcW;
        $bTop = $b['y'] * $srcH;
        $bBottom = ($b['y'] + $b['height']) * $srcH;
        $dx = max(0.0, $aLeft - $bRight, $bLeft - $aRight);
        $dy = max(0.0, $aTop - $bBottom, $bTop - $aBottom);

        return sqrt($dx * $dx + $dy * $dy) / $shortest;
    }

    /** @return list<list<int>> groups of indices, in first-member order */
    private static function detectGroups(array $overlays, float $srcW, float $srcH): array
    {
        $n = count($overlays);
        $parent = $n > 0 ? range(0, $n - 1) : [];
        $find = static function (int $i) use (&$parent): int {
            while ($parent[$i] !== $i) {
                $parent[$i] = $parent[$parent[$i]];
                $i = $parent[$i];
            }

            return $i;
        };
        for ($i = 0; $i < $n; $i++) {
            for ($j = $i + 1; $j < $n; $j++) {
                if (self::bboxDistance($overlays[$i], $overlays[$j], $srcW, $srcH) < self::CLUSTER_THRESHOLD) {
                    $ri = $find($i);
                    $rj = $find($j);
                    if ($ri !== $rj) {
                        $parent[$ri] = $rj;
                    }
                }
            }
        }
        $groups = [];
        for ($i = 0; $i < $n; $i++) {
            $groups[$find($i)][] = $i;
        }

        return array_values($groups);
    }

    private static function transformGroupForAspect(array $group, float $srcW, float $srcH, float $dstW, float $dstH): array
    {
        $xMin = INF;
        $yMin = INF;
        $xMax = -INF;
        $yMax = -INF;
        foreach ($group as $o) {
            if ($o['x'] < $xMin) {
                $xMin = $o['x'];
            }
            if ($o['y'] < $yMin) {
                $yMin = $o['y'];
            }
            if ($o['x'] + $o['width'] > $xMax) {
                $xMax = $o['x'] + $o['width'];
            }
            if ($o['y'] + $o['height'] > $yMax) {
                $yMax = $o['y'] + $o['height'];
            }
        }
        $groupW = $xMax - $xMin;
        $groupH = $yMax - $yMin;
        if ($groupW <= 0 || $groupH <= 0) {
            return $group;
        }

        $virtual = array_merge($group[0], ['x' => $xMin, 'y' => $yMin, 'width' => $groupW, 'height' => $groupH]);
        $projected = self::transformOverlayForAspect($virtual, $srcW, $srcH, $dstW, $dstH);

        $bboxW = $projected['width'];
        $bboxH = $projected['height'];
        $bboxX = $projected['x'];
        $bboxY = $projected['y'];
        $budgetW = self::coverageBudget($groupW);
        $budgetH = self::coverageBudget($groupH);
        $fitScale = 1.0;
        if ($bboxW > $budgetW) {
            $fitScale = min($fitScale, $budgetW / $bboxW);
        }
        if ($bboxH > $budgetH) {
            $fitScale = min($fitScale, $budgetH / $bboxH);
        }
        if ($fitScale < 1) {
            $bboxW *= $fitScale;
            $bboxH *= $fitScale;
            $origRight = $bboxX + $projected['width'];
            if (abs($bboxX) < 1e-4) {
                // left-anchored — keep at left
            } elseif (abs($origRight - 1) < 1e-4) {
                $bboxX = 1 - $bboxW;
            } else {
                $center = $bboxX + $projected['width'] / 2;
                $bboxX = $center - $bboxW / 2;
            }
            $origBottom = $bboxY + $projected['height'];
            if (abs($bboxY) < 1e-4) {
                // top-anchored
            } elseif (abs($origBottom - 1) < 1e-4) {
                $bboxY = 1 - $bboxH;
            } else {
                $center = $bboxY + $projected['height'] / 2;
                $bboxY = $center - $bboxH / 2;
            }
            $bboxX = max(0.0, min(1 - $bboxW, $bboxX));
            $bboxY = max(0.0, min(1 - $bboxH, $bboxY));
        }

        $xScale = $bboxW / $groupW;
        $yScale = $bboxH / $groupH;

        return array_map(static fn (array $o): array => array_merge($o, [
            'x' => $bboxX + ($o['x'] - $xMin) * $xScale,
            'y' => $bboxY + ($o['y'] - $yMin) * $yScale,
            'width' => $o['width'] * $xScale,
            'height' => $o['height'] * $yScale,
        ]), $group);
    }

    private static function capOverlayCoverage(array $projected, array $src): array
    {
        $budgetW = self::coverageBudget($src['width']);
        $budgetH = self::coverageBudget($src['height']);
        $scale = 1.0;
        if ($projected['width'] > $budgetW) {
            $scale = min($scale, $budgetW / $projected['width']);
        }
        if ($projected['height'] > $budgetH) {
            $scale = min($scale, $budgetH / $projected['height']);
        }
        if ($scale >= 1) {
            return $projected;
        }

        $newW = $projected['width'] * $scale;
        $newH = $projected['height'] * $scale;
        if (abs($projected['x']) < 1e-4) {
            $newX = 0.0;
        } elseif (abs($projected['x'] + $projected['width'] - 1) < 1e-4) {
            $newX = 1 - $newW;
        } else {
            $newX = $projected['x'] + $projected['width'] / 2 - $newW / 2;
        }
        if (abs($projected['y']) < 1e-4) {
            $newY = 0.0;
        } elseif (abs($projected['y'] + $projected['height'] - 1) < 1e-4) {
            $newY = 1 - $newH;
        } else {
            $newY = $projected['y'] + $projected['height'] / 2 - $newH / 2;
        }

        return array_merge($projected, ['x' => $newX, 'y' => $newY, 'width' => $newW, 'height' => $newH]);
    }

    private static function scaleTextStylingWithHeight(array $projected, array $src): array
    {
        if (($projected['payload']['type'] ?? null) !== 'text' || $src['height'] <= 0) {
            return $projected;
        }
        $ratio = $projected['height'] / $src['height'];
        if (abs($ratio - 1) < 1e-9) {
            return $projected;
        }

        $payload = $projected['payload'];
        if (isset($payload['fontSize'])) {
            $payload['fontSize'] = $payload['fontSize'] * $ratio;
        }
        if (isset($payload['letterSpacing'])) {
            $payload['letterSpacing'] = $payload['letterSpacing'] * $ratio;
        }
        if (isset($payload['paragraphSpacing'])) {
            $payload['paragraphSpacing'] = $payload['paragraphSpacing'] * $ratio;
        }
        if (isset($payload['runs']) && is_array($payload['runs'])) {
            $payload['runs'] = self::scaleTextRuns($payload['runs'], $ratio);
        }
        $projected['payload'] = $payload;

        return $projected;
    }

    /** Port of web overlays/textRuns.ts::scaleTextRuns (a run's fontSize is absolute). */
    private static function scaleTextRuns(array $runs, float $factor): array
    {
        if ($factor === 1.0) {
            return $runs;
        }
        $any = false;
        foreach ($runs as $run) {
            if (is_array($run) && ! empty($run['fontSize'])) {
                $any = true;
            }
        }
        if (! $any) {
            return $runs;
        }

        return array_map(static fn ($run) => is_array($run) && ! empty($run['fontSize'])
            ? array_merge($run, ['fontSize' => $run['fontSize'] * $factor])
            : $run, $runs);
    }

    private static function hasVisibleArea(array $o): bool
    {
        $left = max(0.0, $o['x']);
        $top = max(0.0, $o['y']);
        $right = min(1.0, $o['x'] + $o['width']);
        $bottom = min(1.0, $o['y'] + $o['height']);

        return $right - $left > 0 && $bottom - $top > 0;
    }

    private static function clampOverlayToCanvas(array $o): array
    {
        $w = $o['width'];
        $h = $o['height'];
        if ($w > 0 && $h > 0 && ($w > 1 || $h > 1)) {
            $s = min(1 / $w, 1 / $h);
            $w *= $s;
            $h *= $s;
        }
        $x = min(max($o['x'], 0.0), max(0.0, 1 - $w));
        $y = min(max($o['y'], 0.0), max(0.0, 1 - $h));

        return array_merge($o, ['x' => $x, 'y' => $y, 'width' => $w, 'height' => $h]);
    }

    private static function overlapFractionPx(array $a, array $b, float $w, float $h): float
    {
        $ax = $a['x'] * $w;
        $ay = $a['y'] * $h;
        $aw = $a['width'] * $w;
        $ah = $a['height'] * $h;
        $bx = $b['x'] * $w;
        $by = $b['y'] * $h;
        $bw = $b['width'] * $w;
        $bh = $b['height'] * $h;
        $ox = max(0.0, min($ax + $aw, $bx + $bw) - max($ax, $bx));
        $oy = max(0.0, min($ay + $ah, $by + $bh) - max($ay, $by));
        $smaller = min($aw * $ah, $bw * $bh);

        return $smaller > 0 ? ($ox * $oy) / $smaller : 0.0;
    }

    private static function projectionGrewOverlap(array $src, array $projected, float $srcW, float $srcH, float $dstW, float $dstH): bool
    {
        $n = count($src);
        for ($i = 0; $i < $n; $i++) {
            for ($j = $i + 1; $j < $n; $j++) {
                $a = $projected[$src[$i]['id']] ?? null;
                $b = $projected[$src[$j]['id']] ?? null;
                if ($a === null || $b === null) {
                    continue;
                }
                $before = self::overlapFractionPx($src[$i], $src[$j], $srcW, $srcH);
                $after = self::overlapFractionPx($a, $b, $dstW, $dstH);
                if ($after - $before > self::OVERLAP_GROWTH_TOLERANCE) {
                    return true;
                }
            }
        }

        return false;
    }

    private static function uniformUnionFit(array $layers, float $srcW, float $srcH, float $dstW, float $dstH): array
    {
        $left = INF;
        $top = INF;
        $right = -INF;
        $bottom = -INF;
        foreach ($layers as $o) {
            $left = min($left, $o['x'] * $srcW);
            $top = min($top, $o['y'] * $srcH);
            $right = max($right, ($o['x'] + $o['width']) * $srcW);
            $bottom = max($bottom, ($o['y'] + $o['height']) * $srcH);
        }
        $unionW = $right - $left;
        $unionH = $bottom - $top;
        if (! ($unionW > 0) || ! ($unionH > 0)) {
            return $layers;
        }

        $s = min($dstW / $unionW, $dstH / $unionH);
        $offX = ($dstW - $unionW * $s) / 2;
        $offY = ($dstH - $unionH * $s) / 2;

        return array_map(static function (array $o) use ($srcW, $srcH, $dstW, $dstH, $left, $top, $s, $offX, $offY): array {
            $px = $offX + ($o['x'] * $srcW - $left) * $s;
            $py = $offY + ($o['y'] * $srcH - $top) * $s;
            $pw = $o['width'] * $srcW * $s;
            $ph = $o['height'] * $srcH * $s;

            return self::scaleTextStylingWithHeight(
                array_merge($o, ['x' => $px / $dstW, 'y' => $py / $dstH, 'width' => $pw / $dstW, 'height' => $ph / $dstH]),
                $o,
            );
        }, $layers);
    }
}
```

- [ ] **Step 6: Run the test, then prove it bites**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && vendor/bin/pest tests/Unit/Studio/AgentCanvas/KvTileOverlayProjectorTest.php --compact`
Expected: all PASS (10 dataset cases + 3 tests).
Then change `COVERAGE_CAP` to `0.5`, re-run: `extreme_banner_coverage_cap` (and at least one other case) must FAIL. Change `ANCHOR_THRESHOLD` to `0.02`, re-run: `left_top_anchored_singleton_portrait` must FAIL. Restore both constants and re-run: PASS.

- [ ] **Step 7: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
vendor/bin/pint --dirty --format agent
git add app/Services/Studio/AgentCanvas/KvTileOverlayProjector.php tests/Fixtures/kv-projection tests/Unit/Studio/AgentCanvas/KvTileOverlayProjectorTest.php
git commit -m "feat(api): PHP port of resolveTileOverlays pinned to TS-generated fixtures

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 8: Layer primitives — `KvLayerDiff`, `KvLayerPatch`, `KvLayerPlacement`

**Files:**
- Create: `app/Services/Studio/AgentCanvas/KvLayerDiff.php`, `KvLayerPatch.php`, `KvLayerPlacement.php`
- Test: `tests/Unit/Studio/AgentCanvas/KvLayerPrimitivesTest.php`

**Interfaces:**
- Consumes: `KvLayerShape::RECT_KEYS` (Task 3), `KvLayerPatchException` (Task 5).
- Produces:
  - `KvLayerDiff::changedKeys(?array $a, ?array $b): array{rect: list<string>, z: bool, payload: list<string>}`; `isEmpty(array $keys): bool`; `matches(array $row, array $reference, array $keys): bool`; `applyKeys(array $row, array $source, array $keys): array` (a key absent/null in `$source` is removed from the payload); `setLayerOp(string $layerId, array $current, array $target): ?array` (C1.2 `set_layer`, only differing keys, `expected` = current values, `null` for a payload key the current layer lacks — collab matches null to absent); `fullExpected(array $row): array` (whole-layer CAS for `remove_layer`); `sameList(array $a, array $b): bool`. Numbers compare with 1e-9 tolerance, arrays key-order-insensitively.
  - `KvLayerPatch::TEXT_STYLE_KEYS` (Global Constraints list); `unknownStyleKeys(array $style): list<string>`; `apply(array $row, array $set): array` (C3.4 `set`: `text` → `payload.content` with run collapse; `style` → payload keys, `null` deletes, per-type allowance text=all, shape=`color,gradient,opacity,blendMode`, image=`opacity,blendMode`; `rect` `x,y,w,h,rotation` → `x,y,width,height,rotation`; `visible` → `payload.hidden`; `z`); throws `KvLayerPatchException` (`invalid_payload`); `withText(array $payload, string $text): array`; `utf16Length(string $text): int`.
  - `KvLayerPlacement::ANCHORS` (C3.5 list), `DEFAULT_FONT_SIZE = 0.05`, `DEFAULT_LINE_HEIGHT = 1.2`, `rect(array $placement, int $surfaceW, int $surfaceH, ?float $assetAspect, ?float $textHeight): array{x,y,width,height}` — width = `placement.width` of the surface width; height = `$textHeight` (already normalised) for text, `width·W / aspect / H` for an image, square in pixels otherwise; margin = `placement.margin` × the surface's shorter side, converted per axis.

- [ ] **Step 1: Write the failing test**

`tests/Unit/Studio/AgentCanvas/KvLayerPrimitivesTest.php`:

```php
<?php

use App\Exceptions\Studio\KvLayerPatchException;
use App\Services\Studio\AgentCanvas\KvLayerDiff;
use App\Services\Studio\AgentCanvas\KvLayerPatch;
use App\Services\Studio\AgentCanvas\KvLayerPlacement;

function primitiveRow(array $payload = [], array $geometry = []): array
{
    return array_merge([
        'id' => 'L1', 'type' => 'text', 'x' => 0.1, 'y' => 0.4, 'width' => 0.6, 'height' => 0.1, 'rotation' => 0.0, 'z' => 1,
        'payload' => array_merge(['type' => 'text', 'content' => 'Promo', 'color' => '#FFFFFF'], $payload),
        'board_generation_id' => 'gen_a',
    ], $geometry);
}

it('finds exactly the keys that differ, treating 1 and 1.0 as equal', function () {
    $a = primitiveRow(['fontSize' => 0.05], ['z' => 1]);
    $b = primitiveRow(['fontSize' => 0.05, 'hidden' => true], ['y' => 0.5, 'z' => 1.0]);

    expect(KvLayerDiff::changedKeys($a, $b))->toBe(['rect' => ['y'], 'z' => false, 'payload' => ['hidden']])
        ->and(KvLayerDiff::isEmpty(KvLayerDiff::changedKeys($a, $a)))->toBeTrue();
});

it('builds a set_layer op from the differing keys with the current values as expected', function () {
    $current = primitiveRow(['runs' => [['length' => 5, 'fontWeight' => 'bold']]]);
    $target = primitiveRow(['content' => 'Sale'], ['y' => 0.5]);
    unset($target['payload']['runs']);

    expect(KvLayerDiff::setLayerOp('L1', $current, $target))->toBe([
        'kind' => 'set_layer',
        'layer_id' => 'L1',
        'set' => ['rect' => ['y' => 0.5], 'payload' => ['content' => 'Sale', 'runs' => null]],
        'expected' => ['rect' => ['y' => 0.4], 'payload' => ['content' => 'Promo', 'runs' => [['length' => 5, 'fontWeight' => 'bold']]]],
    ])->and(KvLayerDiff::setLayerOp('L1', $current, $current))->toBeNull();
});

it('expects null for a payload key the current layer does not have', function () {
    $op = KvLayerDiff::setLayerOp('L1', primitiveRow(), primitiveRow(['hidden' => true]));

    expect($op['set'])->toBe(['payload' => ['hidden' => true]])
        ->and($op['expected'])->toBe(['payload' => ['hidden' => null]]);
});

it('restores keys from a source and removes the ones the source lacks', function () {
    $before = primitiveRow();
    $after = primitiveRow(['content' => 'Sale', 'hidden' => true]);
    $keys = KvLayerDiff::changedKeys($before, $after);

    expect(KvLayerDiff::matches($after, $after, $keys))->toBeTrue()
        ->and(KvLayerDiff::matches(primitiveRow(['content' => 'User', 'hidden' => true]), $after, $keys))->toBeFalse()
        ->and(KvLayerDiff::applyKeys($after, $before, $keys)['payload'])->toBe($before['payload']);
});

it('collapses per-run styling into the first run when text is replaced', function () {
    $row = primitiveRow(['runs' => [['length' => 2, 'fontFamily' => 'bf_01', 'fontWeight' => 'bold'], ['length' => 3, 'color' => '#FF0000']]]);

    $next = KvLayerPatch::apply($row, ['text' => 'Ramadan Sale']);

    expect($next['payload']['content'])->toBe('Ramadan Sale')
        ->and($next['payload']['runs'])->toBe([['fontFamily' => 'bf_01', 'fontWeight' => 'bold', 'length' => 12]]);
});

it('counts run length in UTF-16 code units and drops unstyled runs', function () {
    expect(KvLayerPatch::utf16Length('🎉 Sale'))->toBe(7)
        ->and(KvLayerPatch::apply(primitiveRow(['runs' => [['length' => 5]]]), ['text' => 'X'])['payload'])->not->toHaveKey('runs');
});

it('maps rect, visibility, z and style; null style deletes', function () {
    $next = KvLayerPatch::apply(primitiveRow(['gradient' => ['from' => '#000000', 'to' => '#FFFFFF', 'angle' => 90]]), [
        'rect' => ['x' => 0.2, 'w' => 0.5, 'h' => 0.2],
        'visible' => false,
        'z' => 9,
        'style' => ['fontSize' => 0.07, 'gradient' => null],
    ]);

    expect([$next['x'], $next['y'], $next['width'], $next['height'], $next['z']])->toBe([0.2, 0.4, 0.5, 0.2, 9])
        ->and($next['payload']['hidden'])->toBeTrue()
        ->and($next['payload']['fontSize'])->toBe(0.07)
        ->and($next['payload'])->not->toHaveKey('gradient');
    expect(KvLayerPatch::apply(primitiveRow(), ['visible' => true])['payload'])->not->toHaveKey('hidden')
        ->and(KvLayerPatch::apply(primitiveRow(['hidden' => true]), ['visible' => true])['payload']['hidden'])->toBeFalse();
});

it('refuses fields that do not apply to the layer type', function (array $row, array $set) {
    expect(fn () => KvLayerPatch::apply($row, $set))->toThrow(KvLayerPatchException::class);
})->with([
    'text on an image' => [primitiveRow(['type' => 'image']), ['text' => 'x']],
    'font on an image' => [primitiveRow(['type' => 'image']), ['style' => ['fontFamily' => 'bf_01']]],
    'font on a shape' => [primitiveRow(['type' => 'shape']), ['style' => ['fontSize' => 0.1]]],
]);

it('names the style keys no layer type accepts', function () {
    expect(KvLayerPatch::unknownStyleKeys(['fontSize' => 1, 'bogusKey' => 2, 'content' => 'x']))->toBe(['bogusKey', 'content']);
});

it('places a layer by anchor, margin of the shorter side and width fraction', function () {
    // Text, top-left on a 1080×1350 board: margin 0.04·1080 = 43.2 px.
    expect(KvLayerPlacement::rect(['anchor' => 'top_left', 'margin' => 0.04, 'width' => 0.5], 1080, 1350, null, 0.06))
        ->toEqualWithDelta(['x' => 43.2 / 1080, 'y' => 43.2 / 1350, 'width' => 0.5, 'height' => 0.06], 1e-9);
    // Image 2:1, bottom-right: 0.2·1080 = 216 px wide → 108 px tall.
    expect(KvLayerPlacement::rect(['anchor' => 'bottom_right', 'margin' => 0.04, 'width' => 0.2], 1080, 1350, 2.0, null))
        ->toEqualWithDelta(['x' => 1 - 0.2 - 43.2 / 1080, 'y' => 1 - 108 / 1350 - 43.2 / 1350, 'width' => 0.2, 'height' => 108 / 1350], 1e-9);
    // Shape, centred on 1920×1080: square in pixels.
    expect(KvLayerPlacement::rect(['anchor' => 'center', 'margin' => 0.1, 'width' => 0.25], 1920, 1080, null, null))
        ->toEqualWithDelta(['x' => 0.375, 'y' => (1 - 0.25 * 1920 / 1080) / 2, 'width' => 0.25, 'height' => 0.25 * 1920 / 1080], 1e-9);
});
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && vendor/bin/pest tests/Unit/Studio/AgentCanvas/KvLayerPrimitivesTest.php --compact`
Expected: FAIL — classes not found.

- [ ] **Step 3: Implement the three classes**

`app/Services/Studio/AgentCanvas/KvLayerDiff.php`:

```php
<?php

namespace App\Services\Studio\AgentCanvas;

/**
 * Field-level comparison of two flat rows, and the collab ops that turn one
 * into the other. Used for the forward write (the CAS subset is what the api
 * just read) and for Undo (the CAS subset is what the agent wrote).
 */
final class KvLayerDiff
{
    /** @return array{rect: list<string>, z: bool, payload: list<string>} */
    public static function changedKeys(?array $a, ?array $b): array
    {
        $a ??= [];
        $b ??= [];
        $rect = [];
        foreach (KvLayerShape::RECT_KEYS as $key) {
            if (! self::same($a[$key] ?? null, $b[$key] ?? null)) {
                $rect[] = $key;
            }
        }
        $pa = is_array($a['payload'] ?? null) ? $a['payload'] : [];
        $pb = is_array($b['payload'] ?? null) ? $b['payload'] : [];
        $payload = [];
        foreach (array_keys($pa + $pb) as $key) {
            if (! self::same($pa[$key] ?? null, $pb[$key] ?? null)) {
                $payload[] = (string) $key;
            }
        }

        return ['rect' => $rect, 'z' => ! self::same($a['z'] ?? null, $b['z'] ?? null), 'payload' => $payload];
    }

    public static function isEmpty(array $keys): bool
    {
        return $keys['rect'] === [] && ! $keys['z'] && $keys['payload'] === [];
    }

    public static function matches(array $row, array $reference, array $keys): bool
    {
        foreach ($keys['rect'] as $key) {
            if (! self::same($row[$key] ?? null, $reference[$key] ?? null)) {
                return false;
            }
        }
        if ($keys['z'] && ! self::same($row['z'] ?? null, $reference['z'] ?? null)) {
            return false;
        }
        foreach ($keys['payload'] as $key) {
            if (! self::same($row['payload'][$key] ?? null, $reference['payload'][$key] ?? null)) {
                return false;
            }
        }

        return true;
    }

    public static function applyKeys(array $row, array $source, array $keys): array
    {
        foreach ($keys['rect'] as $key) {
            $row[$key] = $source[$key] ?? $row[$key];
        }
        if ($keys['z']) {
            $row['z'] = $source['z'] ?? $row['z'];
        }
        foreach ($keys['payload'] as $key) {
            $value = $source['payload'][$key] ?? null;
            if ($value === null) {
                unset($row['payload'][$key]);
            } else {
                $row['payload'][$key] = $value;
            }
        }

        return $row;
    }

    /** @return array<string, mixed>|null null when nothing differs */
    public static function setLayerOp(string $layerId, array $current, array $target): ?array
    {
        $keys = self::changedKeys($current, $target);
        if (self::isEmpty($keys)) {
            return null;
        }

        $set = [];
        $expected = [];
        foreach ($keys['rect'] as $key) {
            $set['rect'][$key] = (float) ($target[$key] ?? 0);
            $expected['rect'][$key] = (float) ($current[$key] ?? 0);
        }
        if ($keys['z']) {
            $set['z'] = (int) ($target['z'] ?? 0);
            $expected['z'] = (int) ($current['z'] ?? 0);
        }
        foreach ($keys['payload'] as $key) {
            // null DELETES the key (C1.2); an expected null matches an absent key.
            $set['payload'][$key] = $target['payload'][$key] ?? null;
            $expected['payload'][$key] = $current['payload'][$key] ?? null;
        }

        return ['kind' => 'set_layer', 'layer_id' => $layerId, 'set' => $set, 'expected' => $expected];
    }

    /** Whole-layer CAS for remove_layer: the layer exactly as read. */
    public static function fullExpected(array $row): array
    {
        $rect = [];
        foreach (KvLayerShape::RECT_KEYS as $key) {
            $rect[$key] = (float) ($row[$key] ?? 0);
        }

        return ['rect' => $rect, 'z' => (int) ($row['z'] ?? 0), 'payload' => is_array($row['payload'] ?? null) ? $row['payload'] : []];
    }

    public static function sameList(array $a, array $b): bool
    {
        $a = array_values($a);
        $b = array_values($b);
        if (count($a) !== count($b)) {
            return false;
        }
        foreach ($a as $i => $row) {
            if (! is_array($row) || ! is_array($b[$i]) || ($row['id'] ?? null) !== ($b[$i]['id'] ?? null)
                || ! self::isEmpty(self::changedKeys($row, $b[$i]))) {
                return false;
            }
        }

        return true;
    }

    private static function same(mixed $a, mixed $b): bool
    {
        if ((is_int($a) || is_float($a)) && (is_int($b) || is_float($b))) {
            return abs((float) $a - (float) $b) < 1e-9;
        }
        if (is_array($a) && is_array($b)) {
            return json_encode(self::canon($a)) === json_encode(self::canon($b));
        }

        return $a === $b;
    }

    private static function canon(mixed $value): mixed
    {
        if (is_array($value)) {
            if (! array_is_list($value)) {
                ksort($value);
            }

            return array_map(self::canon(...), $value);
        }

        return is_int($value) ? (float) $value : $value;
    }
}
```

`app/Services/Studio/AgentCanvas/KvLayerPatch.php`:

```php
<?php

namespace App\Services\Studio\AgentCanvas;

use App\Exceptions\Studio\KvLayerPatchException;

/**
 * Contract C3.4 `set` applied to one flat row — the same change the manual
 * edit makes (spec §6: "an agent edit on a surface is the same as the same
 * manual edit on that surface"). No new payload keys: every key written here
 * is one UpdateStudioFileOverlaysRequest already whitelists; the resulting
 * row is still validated by StudioOverlayNormalizer before it is sent.
 */
final class KvLayerPatch
{
    /** The text payload keys an agent may set through `style` (Global Constraints). */
    public const TEXT_STYLE_KEYS = [
        'color', 'fontFamily', 'fontSize', 'fontWeight', 'fontStyle', 'textAlign', 'lineHeight',
        'letterSpacing', 'paragraphSpacing', 'textTransform', 'gradient', 'opacity', 'blendMode',
    ];

    private const STYLE_KEYS_BY_TYPE = [
        'text' => self::TEXT_STYLE_KEYS,
        'shape' => ['color', 'gradient', 'opacity', 'blendMode'],
        'image' => ['opacity', 'blendMode'],
    ];

    /** @return list<string> */
    public static function unknownStyleKeys(array $style): array
    {
        return array_values(array_diff(array_map('strval', array_keys($style)), self::TEXT_STYLE_KEYS));
    }

    /**
     * @param  array{text?: ?string, style?: array<string,mixed>, rect?: array<string,mixed>, visible?: bool, z?: int}  $set
     *
     * @throws KvLayerPatchException
     */
    public static function apply(array $row, array $set): array
    {
        $payload = is_array($row['payload'] ?? null) ? $row['payload'] : [];
        $type = (string) ($payload['type'] ?? $row['type'] ?? '');

        if (array_key_exists('text', $set)) {
            if ($type !== 'text') {
                throw new KvLayerPatchException("text can only be set on a text layer, not a {$type} layer.");
            }
            $payload = self::withText($payload, (string) $set['text']);
        }

        if (isset($set['style']) && is_array($set['style'])) {
            $allowed = self::STYLE_KEYS_BY_TYPE[$type] ?? [];
            foreach ($set['style'] as $key => $value) {
                if (! in_array($key, $allowed, true)) {
                    throw new KvLayerPatchException("style.{$key} does not apply to a {$type} layer.");
                }
                if ($value === null) {
                    unset($payload[$key]);
                } else {
                    $payload[$key] = $value;
                }
            }
        }

        if (isset($set['rect']) && is_array($set['rect'])) {
            foreach (['x' => 'x', 'y' => 'y', 'w' => 'width', 'h' => 'height', 'rotation' => 'rotation'] as $in => $out) {
                if (array_key_exists($in, $set['rect'])) {
                    $row[$out] = (float) $set['rect'][$in];
                }
            }
        }

        if (array_key_exists('visible', $set)) {
            if ((bool) $set['visible']) {
                if (array_key_exists('hidden', $payload)) {
                    $payload['hidden'] = false;
                }
            } else {
                $payload['hidden'] = true;
            }
        }

        if (array_key_exists('z', $set)) {
            $row['z'] = (int) $set['z'];
        }

        $row['payload'] = $payload;

        return $row;
    }

    /**
     * Replace the text. A layer with per-run styling keeps ONE run carrying
     * the first run's style over the whole new string (spec §6) — the old run
     * lengths described the old string and would mis-style the new one.
     */
    public static function withText(array $payload, string $text): array
    {
        $payload['content'] = $text;
        $runs = $payload['runs'] ?? null;
        if (is_array($runs) && $runs !== []) {
            $first = is_array($runs[0] ?? null) ? $runs[0] : [];
            unset($first['length']);
            $first = array_filter($first, static fn ($value) => $value !== null);
            $length = self::utf16Length($text);
            if ($first === [] || $length === 0) {
                unset($payload['runs']);
            } else {
                $payload['runs'] = [$first + ['length' => $length]];
            }
        }

        return $payload;
    }

    /** Run lengths count UTF-16 code units — the unit the browser authors runs in. */
    public static function utf16Length(string $text): int
    {
        return intdiv(strlen((string) mb_convert_encoding($text, 'UTF-16LE', 'UTF-8')), 2);
    }
}
```

`app/Services/Studio/AgentCanvas/KvLayerPlacement.php`:

```php
<?php

namespace App\Services\Studio\AgentCanvas;

/** Contract C3.5 placement → a normalised rect on one surface. */
final class KvLayerPlacement
{
    public const ANCHORS = [
        'top_left', 'top_center', 'top_right',
        'middle_left', 'center', 'middle_right',
        'bottom_left', 'bottom_center', 'bottom_right',
    ];

    /** Normalised to the surface height, like every text size on the canvas. */
    public const DEFAULT_FONT_SIZE = 0.05;

    public const DEFAULT_LINE_HEIGHT = 1.2;

    /**
     * @param  array{anchor: string, margin: float|int, width: float|int}  $placement
     * @param  float|null  $assetAspect  intrinsic width/height of an image
     * @param  float|null  $textHeight  one line of text, already normalised to the surface height
     * @return array{x: float, y: float, width: float, height: float}
     */
    public static function rect(array $placement, int $surfaceW, int $surfaceH, ?float $assetAspect, ?float $textHeight): array
    {
        $width = max(0.01, min(1.0, (float) $placement['width']));
        if ($textHeight !== null) {
            $height = $textHeight;
        } elseif ($assetAspect !== null && $assetAspect > 0) {
            $height = ($width * $surfaceW / $assetAspect) / $surfaceH;
        } else {
            $height = $width * $surfaceW / $surfaceH;
        }

        $marginPx = max(0.0, (float) $placement['margin']) * min($surfaceW, $surfaceH);
        $mx = $marginPx / $surfaceW;
        $my = $marginPx / $surfaceH;
        $anchor = (string) $placement['anchor'];

        $x = match (true) {
            str_ends_with($anchor, 'left') => $mx,
            str_ends_with($anchor, 'right') => 1 - $width - $mx,
            default => (1 - $width) / 2,
        };
        $y = match (true) {
            str_starts_with($anchor, 'top') => $my,
            str_starts_with($anchor, 'bottom') => 1 - $height - $my,
            default => (1 - $height) / 2,
        };

        return ['x' => $x, 'y' => $y, 'width' => $width, 'height' => $height];
    }
}
```

- [ ] **Step 4: Run the test**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && vendor/bin/pest tests/Unit/Studio/AgentCanvas/KvLayerPrimitivesTest.php --compact`
Expected: all PASS. If a placement number disagrees, recompute it by hand from the formula in the test comment before touching either side.

- [ ] **Step 5: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
vendor/bin/pint --dirty --format agent
git add app/Services/Studio/AgentCanvas/KvLayerDiff.php app/Services/Studio/AgentCanvas/KvLayerPatch.php app/Services/Studio/AgentCanvas/KvLayerPlacement.php tests/Unit/Studio/AgentCanvas/KvLayerPrimitivesTest.php
git commit -m "feat(api): KV layer diff, patch and placement primitives

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Canvas state, inventory and `get_kv_canvas` (C3 read + C7 flag + MCP twin)

**Files:**
- Create: `app/Services/Studio/AgentCanvas/KvCanvasState.php`, `KvCanvasContextAssembler.php`; `app/Support/Studio/KvAgentCanvasFlag.php`; `app/Http/Controllers/Api/ModelContextProtocol/KvCanvasToolController.php`; `app/Mcp/Tools/GetKvCanvasTool.php`; `tests/Support/KvCanvasFixture.php`, `tests/Support/FakeKvCollab.php`, `tests/Traits/BuildsKvCanvas.php`
- Modify: `routes/api.php` (`mcp/tools` group, right after `Route::post('kv/generate', [KvToolController::class, 'generate']);`; `use` line beside `KvToolController`), `app/Mcp/Servers/FrndosServer.php` (`// Key Visuals` block)
- Test: `tests/Feature/Studio/AgentCanvas/KvCanvasInventoryTest.php`, `tests/Unit/Mcp/KvCanvasToolsTest.php`

**Interfaces:**
- Consumes: `KvCollabWriter::liveDocument` (Task 5), `KvImageDimensions` (Task 6), `KvTileOverlayProjector::overlaysForResizeSource` (Task 7), `KvLayerShape` (Task 3), `KvLayerPatch::TEXT_STYLE_KEYS` (Task 8), `KvCanvasToolException` (Task 5).
- Produces:
  - `KvAgentCanvasFlag::KEY = 'kv-agentic-canvas'`, `KvAgentCanvasFlag::enabledFor(User $user, string $workspaceId): bool` (fail-closed).
  - `KvCanvasState` (read-only view of one loaded canvas): public `file`, `boards` (list of `{id, name, chain, is_master, index}`), `layers` (flat rows, doc order, first copy of a duplicated id wins), `tiles` (Collection of `KvResizeExport`), `tips` (tip generation per board id); methods `board(string $anyId): ?array` (tip OR any id in `versionIds`), `tile(string $id): ?KvResizeExport`, `boardOfTile(KvResizeExport): ?array`, `tilesOf(array $board): list<KvResizeExport>`, `isOnBoard(array $row, array $board): bool` (unbound rows belong to the master board), `layersOnBoard(array $board): list`, `layer(string $id): ?array`, `projectOverlays(array $board): list` (what an inheriting size of the board re-projects), `maxZ(): int`, `boardDims(array $board): ?array{width,height}`, `boardLabel(array $board): string`, `sizeLabel(KvResizeExport $tile): string` (`"<board> · <preset>"`), `resolveTargets(array $targets): array{surfaces: list<Surface>, missing: list<array{id,kind}>}` where `Surface = array{kind: 'board'|'size', id: string, board: array, tile: ?KvResizeExport, label: string}` (C3.1: board targets; `include_sizes` adds that board's DETACHED sizes; size ids resolve through the tile's parent board; de-duplicated), static `targetIds(array $targets): list<string>`.
  - `KvCanvasContextAssembler::load(StudioFile $file): KvCanvasState` (throws `KvCollabUnavailableException`), `inventory(KvCanvasState $state, ?string $activeBoardId = null, ?string $activeSizeId = null, array $selectedLayerIds = []): array` (C3.2), static `layerItem(array $row): array`, static `clean(string $text): string`; consts `MAX_BOARDS=30`, `MAX_SIZES=50`, `MAX_LAYERS=60`, `MAX_TEXT=200`.
  - `KvCanvasToolController::show(Request, string $fileId)`; protected `withFile(Request, string $fileId, Closure(StudioFile, ToolContext): array): JsonResponse` (flag re-check → file lookup → `{data}`; maps `KvCanvasToolException` and 503 `collab_unavailable`); protected `kvFileFor(string, ToolContext): ?StudioFile`.
  - Route group `mcp/tools` → `feature.flag:kv-agentic-canvas,off` → `GET kv/canvas/{fileId}`. MCP twin `get_kv_canvas`.
  - Test support: `Tests\Support\KvCanvasFixture` (consts `HEADLINE`, `LOGO`, `CAPTION`, `OLD_A`, `TOKEN`; `textLayer()`, `imageLayer()`, `row()`), `Tests\Support\FakeKvCollab` (`install(array $doc, array $extraFakes = []): self`, public `document`, `down`, `batches`, `refusals`, `layer(string $id): ?array`, `editLayer(string $id, callable $edit): void`, `removeLayer(string $id): void`, `opsRequestCount(): int`), `Tests\Traits\BuildsKvCanvas` (`setUpKvCanvas(array $extraFakes = [])`, `kvDocument()`, `kvTile(array $attributes = [])`, `kvCtx(?string $runId = null, string $via = 'internal')`, `kvTool(string $method, string $path, array $payload = [], ?string $runId = null)`; properties `user, workspace, file, boardA (1080×1350, master, "Concept A", versionIds [OLD_A, tip]), boardB (1080×1080, "Concept B"), collab, runId`).

- [ ] **Step 1: Write the test support**

`tests/Support/KvCanvasFixture.php`:

```php
<?php

namespace Tests\Support;

use App\Services\Studio\AgentCanvas\KvLayerShape;

/** Ids and layer builders shared by the KV agentic canvas tests (26-char ids, like real ULIDs). */
final class KvCanvasFixture
{
    public const HEADLINE = '01JAGENTHEADLINE0000000001';

    public const LOGO = '01JAGENTLOGO00000000000002';

    public const CAPTION = '01JAGENTCAPTION00000000003';

    /** An older generation id in board A's versionIds (a pre-rekey tip). */
    public const OLD_A = '01JAGENTOLDVERSIONA0000000';

    public const TOKEN = 'test-internal-token';

    public static function textLayer(string $id, ?string $boardId, string $content, int $z, array $payload = [], array $rect = []): array
    {
        return [
            'id' => $id,
            'type' => 'text',
            'rect' => array_merge(['x' => 0.1, 'y' => 0.4, 'width' => 0.6, 'height' => 0.1, 'rotation' => 0], $rect),
            'z' => $z,
            'payload' => array_merge(['type' => 'text', 'content' => $content, 'color' => '#FFFFFF', 'fontSize' => 0.05], $payload),
            'board_generation_id' => $boardId,
        ];
    }

    public static function imageLayer(string $id, ?string $boardId, int $z, array $rect = []): array
    {
        return [
            'id' => $id,
            'type' => 'image',
            'rect' => array_merge(['x' => 0.03, 'y' => 0.03, 'width' => 0.2, 'height' => 0.08, 'rotation' => 0], $rect),
            'z' => $z,
            'payload' => ['type' => 'image', 'asset_url' => 'https://s3.test/frnd/logo.png', 'mime_type' => 'image/png', 'name' => 'Brand logo'],
            'board_generation_id' => $boardId,
        ];
    }

    /** A layer as a flat row — the shape tile snapshots store. */
    public static function row(array $layer): array
    {
        return KvLayerShape::toRow($layer);
    }
}
```

`tests/Support/FakeKvCollab.php`:

```php
<?php

namespace Tests\Support;

use Illuminate\Http\Client\Request;
use Illuminate\Support\Facades\Http;

/**
 * Stateful stand-in for the collab KV routes (contract C1). GET /document
 * serves `$document`; POST /ops applies set_layer / add_layer / remove_layer
 * all-or-nothing with the contract's CAS (an expected null matches an absent
 * key) and answers with the pre-images. Tests read the doc back to see what
 * the api REALLY wrote, and edit it directly to play a collaborator.
 */
final class FakeKvCollab
{
    public bool $down = false;

    /** @var list<array<string, mixed>> accepted /ops bodies, in order */
    public array $batches = [];

    /** @var list<array{0: int, 1: array<string, mixed>}> canned answers for the next /ops calls */
    public array $refusals = [];

    public function __construct(public array $document) {}

    /** @param  array<string, mixed>  $extraFakes  more Http::fake patterns; merged FIRST so they win */
    public static function install(array $document, array $extraFakes = []): self
    {
        $fake = new self($document);
        Http::preventStrayRequests();
        Http::fake($extraFakes + [
            'collab.test/internal/kv-files/*/document' => fn () => $fake->down
                ? Http::failedConnection()
                : Http::response(['document' => $fake->document]),
            'collab.test/internal/kv-files/*/ops' => fn (Request $request) => $fake->down
                ? Http::failedConnection()
                : $fake->apply($request->data()),
        ]);

        return $fake;
    }

    public function apply(array $body): mixed
    {
        if ($this->refusals !== []) {
            [$status, $answer] = array_shift($this->refusals);

            return Http::response($answer, $status);
        }

        $overlays = $this->document['overlays'];
        $before = [];
        $applied = [];
        foreach ((array) ($body['ops'] ?? []) as $op) {
            $id = (string) ($op['kind'] === 'add_layer' ? ($op['layer']['id'] ?? '') : ($op['layer_id'] ?? ''));
            $index = self::indexOf($overlays, $id);
            if (! array_key_exists($id, $before)) {
                $before[$id] = $index === null ? null : $overlays[$index];
            }
            if ($op['kind'] === 'add_layer') {
                if ($index !== null) {
                    return Http::response(['error' => 'layer_exists', 'layer_id' => $id], 409);
                }
                $overlays[] = $op['layer'];
            } else {
                if ($index === null) {
                    return Http::response(['error' => 'layer_not_found', 'layer_id' => $id], 404);
                }
                if (! self::matches($overlays[$index], (array) ($op['expected'] ?? []))) {
                    return Http::response(['error' => 'layer_changed', 'layer_id' => $id, 'expected' => $op['expected'], 'current' => $overlays[$index]], 409);
                }
                if ($op['kind'] === 'remove_layer') {
                    array_splice($overlays, $index, 1);
                } else {
                    $overlays[$index] = self::merge($overlays[$index], (array) ($op['set'] ?? []));
                }
            }
            $applied[] = ['kind' => $op['kind'], 'layer_id' => $id];
        }

        $this->batches[] = $body;
        $this->document['overlays'] = $overlays;

        return Http::response(['applied' => $applied, 'before' => ['layers' => (object) $before], 'materialized' => true]);
    }

    public function layer(string $id): ?array
    {
        $index = self::indexOf($this->document['overlays'], $id);

        return $index === null ? null : $this->document['overlays'][$index];
    }

    /** Play a collaborator: change a layer in the live doc. */
    public function editLayer(string $id, callable $edit): void
    {
        $index = self::indexOf($this->document['overlays'], $id);
        $this->document['overlays'][$index] = $edit($this->document['overlays'][$index]);
    }

    public function removeLayer(string $id): void
    {
        $index = self::indexOf($this->document['overlays'], $id);
        array_splice($this->document['overlays'], $index, 1);
    }

    public function opsRequestCount(): int
    {
        return count(Http::recorded(fn ($request) => str_ends_with($request->url(), '/ops')));
    }

    private static function indexOf(array $overlays, string $id): ?int
    {
        foreach ($overlays as $i => $layer) {
            if (($layer['id'] ?? null) === $id) {
                return $i;
            }
        }

        return null;
    }

    private static function matches(array $layer, array $expected): bool
    {
        foreach ((array) ($expected['rect'] ?? []) as $key => $value) {
            if (($layer['rect'][$key] ?? null) != $value) {
                return false;
            }
        }
        if (array_key_exists('z', $expected) && ($layer['z'] ?? null) != $expected['z']) {
            return false;
        }
        foreach ((array) ($expected['payload'] ?? []) as $key => $value) {
            if (($layer['payload'][$key] ?? null) != $value) {
                return false;
            }
        }

        return true;
    }

    private static function merge(array $layer, array $set): array
    {
        foreach ((array) ($set['rect'] ?? []) as $key => $value) {
            $layer['rect'][$key] = $value;
        }
        if (array_key_exists('z', $set)) {
            $layer['z'] = $set['z'];
        }
        foreach ((array) ($set['payload'] ?? []) as $key => $value) {
            if ($value === null) {
                unset($layer['payload'][$key]);
            } else {
                $layer['payload'][$key] = $value;
            }
        }

        return $layer;
    }
}
```

`tests/Traits/BuildsKvCanvas.php`:

```php
<?php

namespace Tests\Traits;

use App\Enums\KvResizeExportStatus;
use App\Models\KvGeneration;
use App\Models\KvResizeExport;
use App\Models\Role;
use App\Models\StudioFile;
use App\Models\Tool;
use App\Models\User;
use App\Models\Workspace;
use App\Services\ModelContextProtocol\ToolContext;
use Illuminate\Support\Str;
use Illuminate\Testing\TestResponse;
use Tests\Support\FakeKvCollab;
use Tests\Support\KvCanvasFixture;

/** A KV file with two boards in a faked live doc, for the agentic canvas tests. */
trait BuildsKvCanvas
{
    protected User $user;

    protected Workspace $workspace;

    protected StudioFile $file;

    protected KvGeneration $boardA;

    protected KvGeneration $boardB;

    protected FakeKvCollab $collab;

    protected string $runId;

    protected function setUpKvCanvas(array $extraFakes = []): void
    {
        config([
            'services.collab.url' => 'http://collab.test',
            'services.internal.workflow_token' => KvCanvasFixture::TOKEN,
            'broadcasting.default' => 'null',
        ]);

        $this->workspace = Workspace::factory()->create(['type' => 'organization']);
        $this->user = User::factory()->create(['current_workspace_id' => $this->workspace->id]);
        $this->user->workspaces()->attach($this->workspace->id);
        $role = Role::factory()->create(['slug' => 'internal-'.Str::random(6), 'type' => 'workspace', 'scope' => 'internal']);
        $this->user->workspaceRoles()->attach($role->id, ['workspace_id' => $this->workspace->id]);

        $tool = Tool::query()->where('slug', 'kv-generator')->first() ?? Tool::factory()->create(['slug' => 'kv-generator']);
        // brand_id null: brand/Tower permissioning is orthogonal to these tests.
        $this->file = StudioFile::factory()->create([
            'workspace_id' => $this->workspace->id, 'brand_id' => null, 'tool_id' => $tool->id,
            'created_by' => $this->user->id, 'last_edited_by' => $this->user->id, 'name' => 'Ramadan KV',
        ]);
        $this->boardA = KvGeneration::factory()->create([
            'studio_file_id' => $this->file->id, 'version_number' => 1, 'image_url' => 'https://s3.test/frnd/a.png',
            'metadata' => ['width' => 1080, 'height' => 1350], 'created_by' => $this->user->id,
        ]);
        $this->boardB = KvGeneration::factory()->create([
            'studio_file_id' => $this->file->id, 'version_number' => 2, 'image_url' => 'https://s3.test/frnd/b.png',
            'metadata' => ['width' => 1080, 'height' => 1080], 'created_by' => $this->user->id,
        ]);
        $this->runId = (string) Str::ulid();
        $this->collab = FakeKvCollab::install($this->kvDocument(), $extraFakes);
    }

    protected function kvDocument(): array
    {
        return [
            'meta' => ['schemaVersion' => 2, 'masterGenerationId' => $this->boardA->id],
            'boards' => [
                $this->boardA->id => ['x' => 0, 'y' => 0, 'name' => 'Concept A', 'versionIds' => [KvCanvasFixture::OLD_A, $this->boardA->id]],
                $this->boardB->id => ['x' => 1200, 'y' => 0, 'name' => 'Concept B', 'versionIds' => [$this->boardB->id]],
            ],
            'overlays' => [
                KvCanvasFixture::textLayer(KvCanvasFixture::HEADLINE, $this->boardA->id, 'Promo Ramadan', 1),
                KvCanvasFixture::imageLayer(KvCanvasFixture::LOGO, $this->boardA->id, 2),
                KvCanvasFixture::textLayer(KvCanvasFixture::CAPTION, $this->boardB->id, 'Diskon 50%', 3, [], ['y' => 0.8]),
            ],
            'removed' => [],
        ];
    }

    /** A done resize tile of board A, 1080×1920, inheriting unless `overlays` is given. */
    protected function kvTile(array $attributes = []): KvResizeExport
    {
        return KvResizeExport::factory()->create(array_merge([
            'studio_file_id' => $this->file->id,
            'parent_generation_id' => $this->boardA->id,
            'created_by' => $this->user->id,
            'platform_id' => 'size-'.Str::lower(Str::random(8)),
            'width' => 1080,
            'height' => 1920,
            'status' => KvResizeExportStatus::Done,
            'image_url' => 'https://s3.test/frnd/tile.png',
            'overlays' => null,
        ], $attributes));
    }

    protected function kvCtx(?string $runId = null, string $via = 'internal'): ToolContext
    {
        return new ToolContext($this->user, (string) $this->workspace->id, $via, $runId);
    }

    /** Call a canvas tool route the way ai-service does (internal token + ids in the query). */
    protected function kvTool(string $method, string $path, array $payload = [], ?string $runId = null): TestResponse
    {
        $query = http_build_query(array_filter([
            'user_id' => $this->user->id,
            'workspace_id' => $this->workspace->id,
            'agent_run_id' => $runId,
        ]));
        $url = '/api/v1/mcp/tools/kv/canvas/'.ltrim($path, '/').'?'.$query;
        $request = $this->withHeader('X-Internal-Token', KvCanvasFixture::TOKEN);

        return $method === 'GET'
            ? $request->getJson($url.($payload === [] ? '' : '&'.http_build_query($payload)))
            : $request->postJson($url, $payload);
    }
}
```

- [ ] **Step 2: Write the failing tests**

`tests/Feature/Studio/AgentCanvas/KvCanvasInventoryTest.php`:

```php
<?php

use App\Models\StudioFile;
use App\Models\Workspace;
use App\Services\FeatureFlagService;
use Tests\Support\KvCanvasFixture as K;
use Tests\Traits\BuildsKvCanvas;

uses(BuildsKvCanvas::class);

beforeEach(fn () => $this->setUpKvCanvas());

it('returns the canvas inventory from the live document', function () {
    $inheriting = $this->kvTile();
    $logoHiddenOnTile = K::row(K::imageLayer(K::LOGO, $this->boardA->id, 2));
    $logoHiddenOnTile['payload']['hidden'] = true;
    $detached = $this->kvTile(['width' => 1080, 'height' => 1080, 'overlays' => [
        // Same copy with a projected font size: not an override.
        K::row(K::textLayer(K::HEADLINE, $this->boardA->id, 'Promo Ramadan', 1, ['fontSize' => 0.07])),
        $logoHiddenOnTile,
        K::row(K::textLayer('01JAGENTTILEONLY0000000009', $this->boardA->id, 'Only here', 4)),
    ]]);

    $data = $this->kvTool('GET', $this->file->id, ['active_board_id' => K::OLD_A])->assertOk()->json('data');

    expect($data['file'])->toBe(['id' => $this->file->id, 'name' => 'Ramadan KV', 'brand' => null])
        ->and($data['active'])->toBe(['board_id' => $this->boardA->id, 'size_id' => null, 'selected_layer_ids' => []])
        ->and($data['truncated'])->toBe(['boards' => false, 'sizes' => false, 'layers' => false])
        ->and(array_column($data['boards'], 'board_id'))->toBe([$this->boardA->id, $this->boardB->id]);

    $a = $data['boards'][0];
    expect($a)->toMatchArray(['name' => 'Concept A', 'is_master' => true, 'width' => 1080, 'height' => 1350, 'image_url' => 'https://s3.test/frnd/a.png'])
        ->and($a['layers'])->toEqual([
            ['layer_id' => K::HEADLINE, 'type' => 'text', 'rect' => ['x' => 0.1, 'y' => 0.4, 'w' => 0.6, 'h' => 0.1, 'rotation' => 0], 'z' => 1,
                'text' => 'Promo Ramadan', 'style' => ['color' => '#FFFFFF', 'fontSize' => 0.05], 'image_kind' => null],
            ['layer_id' => K::LOGO, 'type' => 'image', 'rect' => ['x' => 0.03, 'y' => 0.03, 'w' => 0.2, 'h' => 0.08, 'rotation' => 0], 'z' => 2,
                'text' => null, 'style' => null, 'image_kind' => 'logo'],
        ]);
    expect($data['boards'][1]['is_master'])->toBeFalse()
        ->and(array_column($data['boards'][1]['layers'], 'layer_id'))->toBe([K::CAPTION]);

    $sizes = collect($a['sizes'])->keyBy('size_id');
    expect($sizes[$inheriting->id])->toMatchArray(['mode' => 'inherit', 'overrides' => [], 'width' => 1080, 'height' => 1920, 'status' => 'done'])
        ->and($sizes[$inheriting->id]['preset'])->toBeString()
        ->and($sizes[$detached->id]['mode'])->toBe('detached')
        ->and(array_column($sizes[$detached->id]['overrides'], 'layer_id'))->toBe([K::LOGO, '01JAGENTTILEONLY0000000009']);
});

it('caps text at 200 characters and strips control characters', function () {
    $this->collab->editLayer(K::HEADLINE, function (array $layer) {
        $layer['payload']['content'] = "Bell\x07".str_repeat('a', 300);

        return $layer;
    });

    $text = $this->kvTool('GET', $this->file->id)->assertOk()->json('data.boards.0.layers.0.text');

    expect(mb_strlen($text))->toBe(200)->and($text)->toStartWith('Bella');
});

it('truncates a surface past 60 layers and says so', function () {
    for ($i = 0; $i < 61; $i++) {
        $this->collab->document['overlays'][] = K::textLayer(sprintf('01JAGENTBULK%014d', $i), $this->boardB->id, "L{$i}", 10 + $i);
    }

    $data = $this->kvTool('GET', $this->file->id)->assertOk()->json('data');

    expect($data['boards'][1]['layers'])->toHaveCount(60)->and($data['truncated']['layers'])->toBeTrue();
});

it('leaves a removed board out', function () {
    $this->collab->document['removed'] = [$this->boardB->id];

    expect(array_column($this->kvTool('GET', $this->file->id)->assertOk()->json('data.boards'), 'board_id'))->toBe([$this->boardA->id]);
});

it('answers 503 collab_unavailable when the live doc cannot be read', function () {
    $this->collab->down = true;

    $this->kvTool('GET', $this->file->id)->assertStatus(503)->assertJsonPath('error', 'collab_unavailable');
});

it('404s a KV file of another workspace', function () {
    $other = StudioFile::factory()->create(['workspace_id' => Workspace::factory()->create()->id, 'brand_id' => null, 'tool_id' => $this->file->tool_id]);

    $this->kvTool('GET', $other->id)->assertNotFound();
});

it('404s while the flag is off, even though route middleware is open outside production', function () {
    $this->mock(FeatureFlagService::class, fn ($mock) => $mock->shouldReceive('isEnabledForWorkspace')->andReturn(false));

    $this->kvTool('GET', $this->file->id)->assertNotFound();
    expect($this->collab->opsRequestCount())->toBe(0);
});
```

`tests/Unit/Mcp/KvCanvasToolsTest.php`:

```php
<?php

use App\Http\Controllers\Api\ModelContextProtocol\KvCanvasToolController;
use App\Mcp\Servers\FrndosServer;
use App\Mcp\Tools\GetKvCanvasTool;
use Illuminate\Support\Facades\Route;
use Tests\TestCase;

/**
 * The MCP twins of the KV agentic canvas tools (MIRROR RULE): each is
 * registered, wraps the right controller method, and admits the arguments
 * the controller reads. `mcp:verify-mirror` proves the pairing is 1:1.
 */
uses(TestCase::class);

function kvTwinSchema(object $tool): array
{
    return $tool->toArray()['inputSchema'];
}

it('mirrors every mcp/tools route, the canvas tools included', function () {
    $this->artisan('mcp:verify-mirror')->assertExitCode(0);
});

it('registers get_kv_canvas as the twin of KvCanvasToolController@show', function () {
    expect((new ReflectionClass(FrndosServer::class))->getDefaultProperties()['tools'])->toContain(GetKvCanvasTool::class)
        ->and(GetKvCanvasTool::CONTROLLER)->toBe(KvCanvasToolController::class)
        ->and(GetKvCanvasTool::METHOD)->toBe('show')
        ->and((new GetKvCanvasTool)->toArray()['name'])->toBe('get_kv_canvas')
        ->and(kvTwinSchema(new GetKvCanvasTool)['required'])->toBe(['workspace_id', 'file_id']);
});

it('puts the canvas tool routes behind the fail-closed flag', function () {
    $route = Route::getRoutes()->match(Illuminate\Http\Request::create('/api/v1/mcp/tools/kv/canvas/abc', 'GET'));

    expect($route->gatherMiddleware())->toContain('feature.flag:kv-agentic-canvas,off');
});
```

- [ ] **Step 3: Run them to see them fail**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/KvCanvasInventoryTest.php tests/Unit/Mcp/KvCanvasToolsTest.php --compact`
Expected: FAIL — route 404 / classes not found.

- [ ] **Step 4: Write the flag, state and assembler**

`app/Support/Studio/KvAgentCanvasFlag.php`:

```php
<?php

namespace App\Support\Studio;

use App\Models\User;
use App\Services\FeatureFlagService;

/**
 * PostHog flag `kv-agentic-canvas` (contract C7), fail-closed. Routes use
 * `feature.flag:kv-agentic-canvas,off`; this is the same answer for the
 * paths route middleware cannot see — the in-process MCP gateway and the
 * chat stream.
 */
final class KvAgentCanvasFlag
{
    public const KEY = 'kv-agentic-canvas';

    public static function enabledFor(User $user, string $workspaceId): bool
    {
        return app(FeatureFlagService::class)->isEnabledForWorkspace(self::KEY, $user, $workspaceId, default: false);
    }
}
```

`app/Services/Studio/AgentCanvas/KvCanvasState.php`:

```php
<?php

namespace App\Services\Studio\AgentCanvas;

use App\Models\KvGeneration;
use App\Models\KvResizeExport;
use App\Models\StudioFile;
use App\Support\Studio\KvImageDimensions;
use Illuminate\Support\Collection;

/**
 * One read of a KV canvas: the live doc's boards and layers (from collab)
 * plus the file's resize tiles (REST rows). Everything that routes an agent
 * edit asks this object, so board-id resolution and "which layers are on
 * which board" are answered one way.
 */
final class KvCanvasState
{
    /** @var array<string, array{width:int,height:int}|null> */
    private array $dims = [];

    /**
     * @param  list<array{id:string,name:?string,chain:list<string>,is_master:bool,index:int}>  $boards
     * @param  list<array<string,mixed>>  $layers  flat rows, doc order
     * @param  Collection<int, KvResizeExport>  $tiles
     * @param  array<string, KvGeneration>  $tips
     */
    public function __construct(
        public readonly StudioFile $file,
        public readonly array $boards,
        public readonly array $layers,
        public readonly Collection $tiles,
        public readonly array $tips,
        private readonly KvImageDimensions $dimensions,
    ) {}

    /** The board whose tip — or any id in its version chain (a pre-rekey id) — is `$anyId`. */
    public function board(string $anyId): ?array
    {
        foreach ($this->boards as $board) {
            if ($board['id'] === $anyId || in_array($anyId, $board['chain'], true)) {
                return $board;
            }
        }

        return null;
    }

    public function tile(string $id): ?KvResizeExport
    {
        return $this->tiles->first(fn (KvResizeExport $tile) => $tile->id === $id);
    }

    public function boardOfTile(KvResizeExport $tile): ?array
    {
        $parent = (string) ($tile->parent_generation_id ?? '');

        return $parent === '' ? null : $this->board($parent);
    }

    /** @return list<KvResizeExport> */
    public function tilesOf(array $board): array
    {
        return $this->tiles
            ->filter(fn (KvResizeExport $tile) => ($this->boardOfTile($tile)['id'] ?? null) === $board['id'])
            ->values()
            ->all();
    }

    /** Craft draws a layer on the board its binding names; an unbound (legacy) layer on the master board. */
    public function isOnBoard(array $row, array $board): bool
    {
        $bound = $row['board_generation_id'] ?? null;

        return $bound === null ? $board['is_master'] : in_array($bound, $board['chain'], true);
    }

    /** @return list<array<string,mixed>> */
    public function layersOnBoard(array $board): array
    {
        return array_values(array_filter($this->layers, fn (array $row) => $this->isOnBoard($row, $board)));
    }

    public function layer(string $id): ?array
    {
        foreach ($this->layers as $row) {
            if ($row['id'] === $id) {
                return $row;
            }
        }

        return null;
    }

    /** What an INHERITING size of this board re-projects (web overlaysForResizeSource). */
    public function projectOverlays(array $board): array
    {
        return KvTileOverlayProjector::overlaysForResizeSource($this->layers, $board['id'], $board['chain']);
    }

    public function maxZ(): int
    {
        $max = -1;
        foreach ($this->layers as $row) {
            $max = max($max, (int) ($row['z'] ?? 0));
        }

        return $max;
    }

    /** @return array{width:int,height:int}|null */
    public function boardDims(array $board): ?array
    {
        if (! array_key_exists($board['id'], $this->dims)) {
            $tip = $this->tips[$board['id']] ?? null;
            $this->dims[$board['id']] = $tip === null ? null : $this->dimensions->forGeneration($tip);
        }

        return $this->dims[$board['id']];
    }

    public function boardLabel(array $board): string
    {
        $name = trim((string) ($board['name'] ?? ''));

        return $name !== '' ? $name : 'Board '.($board['index'] + 1);
    }

    public function sizeLabel(KvResizeExport $tile): string
    {
        $board = $this->boardOfTile($tile);

        return ($board !== null ? $this->boardLabel($board).' · ' : '').$tile->displayLabel();
    }

    /**
     * Contract C3.1. A board target is the board; `include_sizes` adds the
     * board's DETACHED sizes (inheriting ones follow by re-projection); a size
     * id resolves through its tile's parent board. De-duplicated.
     *
     * @return array{surfaces: list<array{kind:string,id:string,board:array,tile:?KvResizeExport,label:string}>, missing: list<array{id:string,kind:string}>}
     */
    public function resolveTargets(array $targets): array
    {
        $surfaces = [];
        $missing = [];
        $includeSizes = filter_var($targets['include_sizes'] ?? false, FILTER_VALIDATE_BOOLEAN);

        foreach (self::ids($targets['board_ids'] ?? []) as $id) {
            $board = $this->board($id);
            if ($board === null) {
                $missing[] = ['id' => $id, 'kind' => 'board'];

                continue;
            }
            $surfaces['board:'.$board['id']] ??= ['kind' => 'board', 'id' => $board['id'], 'board' => $board, 'tile' => null, 'label' => $this->boardLabel($board)];
            if ($includeSizes) {
                foreach ($this->tilesOf($board) as $tile) {
                    if ($tile->overlays !== null) {
                        $surfaces['size:'.$tile->id] ??= $this->sizeSurface($tile, $board);
                    }
                }
            }
        }

        foreach (self::ids($targets['size_ids'] ?? []) as $id) {
            $tile = $this->tile($id);
            $board = $tile === null ? null : $this->boardOfTile($tile);
            if ($tile === null || $board === null) {
                $missing[] = ['id' => $id, 'kind' => 'size'];

                continue;
            }
            $surfaces['size:'.$tile->id] ??= $this->sizeSurface($tile, $board);
        }

        return ['surfaces' => array_values($surfaces), 'missing' => $missing];
    }

    /** @return list<string> */
    public static function targetIds(array $targets): array
    {
        return array_values(array_unique(array_merge(self::ids($targets['board_ids'] ?? []), self::ids($targets['size_ids'] ?? []))));
    }

    /** @return list<string> */
    private static function ids(mixed $ids): array
    {
        return array_values(array_unique(array_filter(
            is_array($ids) ? $ids : [],
            static fn ($id) => is_string($id) && $id !== '',
        )));
    }

    private function sizeSurface(KvResizeExport $tile, array $board): array
    {
        return ['kind' => 'size', 'id' => $tile->id, 'board' => $board, 'tile' => $tile, 'label' => $this->sizeLabel($tile)];
    }
}
```

`app/Services/Studio/AgentCanvas/KvCanvasContextAssembler.php`:

```php
<?php

namespace App\Services\Studio\AgentCanvas;

use App\Models\KvGeneration;
use App\Models\KvResizeExport;
use App\Models\StudioFile;
use App\Support\Studio\KvImageDimensions;

/**
 * Loads a KV canvas (live doc from collab + resize tiles) and renders the
 * inventory the agent reads (spec §5, contract C3.2). No fallback read of
 * `studio_files.overlays`: collab backfills a never-opened doc itself, so an
 * unreadable collab is reported, not papered over with a stale copy.
 */
final class KvCanvasContextAssembler
{
    public const MAX_BOARDS = 30;

    public const MAX_SIZES = 50;

    public const MAX_LAYERS = 60;

    public const MAX_TEXT = 200;

    /**
     * Payload keys that say what a size's copy of a layer IS. Projection
     * legitimately rescales fontSize/letterSpacing, so those are not overrides.
     */
    private const OVERRIDE_KEYS = ['content', 'asset_url', 'hidden', 'color', 'fontFamily', 'fontWeight', 'fontStyle', 'kind'];

    public function __construct(
        private readonly KvCollabWriter $collab,
        private readonly KvImageDimensions $dimensions,
    ) {}

    /** @throws \App\Exceptions\Studio\KvCollabUnavailableException */
    public function load(StudioFile $file): KvCanvasState
    {
        $doc = $this->collab->liveDocument($file);
        $removed = array_flip(array_filter((array) ($doc['removed'] ?? []), 'is_string'));
        $master = $doc['meta']['masterGenerationId'] ?? null;

        $boards = [];
        foreach ((array) $doc['boards'] as $id => $board) {
            $id = (string) $id;
            if (isset($removed[$id]) || ! is_array($board)) {
                continue;
            }
            $versions = array_filter((array) ($board['versionIds'] ?? []), static fn ($v) => is_string($v) && $v !== '');
            $boards[] = [
                'id' => $id,
                'name' => is_string($board['name'] ?? null) ? $board['name'] : null,
                'chain' => array_values(array_unique([...$versions, $id])),
                'is_master' => $master === $id,
                'index' => count($boards),
            ];
        }
        if ($boards !== [] && ! in_array(true, array_column($boards, 'is_master'), true)) {
            $boards[0]['is_master'] = true;
        }

        // The overlays Y.Array can transiently hold a duplicate id (a cold
        // seed race); the first copy wins, as in web kvOverlaysFromDoc.
        $layers = [];
        $seen = [];
        foreach ((array) $doc['overlays'] as $layer) {
            if (! is_array($layer)) {
                continue;
            }
            $row = KvLayerShape::toRow($layer);
            if ($row['id'] === '' || isset($seen[$row['id']])) {
                continue;
            }
            $seen[$row['id']] = true;
            $layers[] = $row;
        }

        $tiles = KvResizeExport::query()
            ->where('studio_file_id', $file->id)
            ->orderBy('created_at')
            ->orderBy('id')
            ->get();
        $tips = KvGeneration::query()
            ->where('studio_file_id', $file->id)
            ->whereIn('id', array_column($boards, 'id'))
            ->get()
            ->keyBy('id')
            ->all();

        return new KvCanvasState($file, $boards, $layers, $tiles, $tips, $this->dimensions);
    }

    public function inventory(KvCanvasState $state, ?string $activeBoardId = null, ?string $activeSizeId = null, array $selectedLayerIds = []): array
    {
        $file = $state->file->loadMissing('brand:id,name');
        $truncated = ['boards' => count($state->boards) > self::MAX_BOARDS, 'sizes' => false, 'layers' => false];

        $boards = [];
        foreach (array_slice($state->boards, 0, self::MAX_BOARDS) as $board) {
            $onBoard = $state->layersOnBoard($board);
            $layers = self::byZ($onBoard);
            if (count($layers) > self::MAX_LAYERS) {
                $truncated['layers'] = true;
                $layers = array_slice($layers, 0, self::MAX_LAYERS);
            }
            $tiles = $state->tilesOf($board);
            if (count($tiles) > self::MAX_SIZES) {
                $truncated['sizes'] = true;
                $tiles = array_slice($tiles, 0, self::MAX_SIZES);
            }
            $sizes = [];
            foreach ($tiles as $tile) {
                $sizes[] = $this->sizeItem($tile, $onBoard, $truncated);
            }
            $dims = $state->boardDims($board);

            $boards[] = [
                'board_id' => $board['id'],
                'name' => $board['name'],
                'is_master' => $board['is_master'],
                'width' => $dims['width'] ?? null,
                'height' => $dims['height'] ?? null,
                'image_url' => ($state->tips[$board['id']] ?? null)?->image_url,
                'layers' => array_map(self::layerItem(...), $layers),
                'sizes' => $sizes,
            ];
        }

        $active = $activeBoardId !== null && $activeBoardId !== '' ? $state->board($activeBoardId) : null;
        $activeSize = $activeSizeId !== null && $activeSizeId !== '' ? $state->tile($activeSizeId) : null;

        return [
            'file' => ['id' => $file->id, 'name' => $file->name, 'brand' => $file->brand?->name],
            'active' => [
                'board_id' => $active['id'] ?? null,
                'size_id' => $activeSize?->id,
                'selected_layer_ids' => array_values(array_filter($selectedLayerIds, static fn ($id) => is_string($id) && $id !== '')),
            ],
            'boards' => $boards,
            'truncated' => $truncated,
        ];
    }

    /** One layer as the agent sees it (C3.2 item). */
    public static function layerItem(array $row): array
    {
        $payload = is_array($row['payload'] ?? null) ? $row['payload'] : [];
        $type = (string) ($payload['type'] ?? $row['type'] ?? '');
        $style = $type === 'text' ? array_intersect_key($payload, array_flip(KvLayerPatch::TEXT_STYLE_KEYS)) : [];

        return [
            'layer_id' => (string) $row['id'],
            'type' => $type,
            'rect' => [
                'x' => round((float) $row['x'], 4),
                'y' => round((float) $row['y'], 4),
                'w' => round((float) $row['width'], 4),
                'h' => round((float) $row['height'], 4),
                'rotation' => round((float) ($row['rotation'] ?? 0), 2),
            ],
            'z' => (int) ($row['z'] ?? 0),
            'text' => $type === 'text' ? self::clean((string) ($payload['content'] ?? '')) : null,
            // An empty PHP array would encode as `[]`, not an object — null instead.
            'style' => $style === [] ? null : $style,
            'image_kind' => $type === 'image'
                ? (preg_match('/logo/i', (string) ($payload['name'] ?? '')) === 1 ? 'logo' : 'upload')
                : null,
        ];
    }

    /** User-authored text as prompt data: no control characters, bounded. */
    public static function clean(string $text): string
    {
        $text = (string) preg_replace('/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u', '', $text);

        return mb_substr($text, 0, self::MAX_TEXT);
    }

    private function sizeItem(KvResizeExport $tile, array $boardLayers, array &$truncated): array
    {
        $overrides = [];
        if ($tile->overlays !== null) {
            $byId = [];
            foreach ($boardLayers as $row) {
                $byId[$row['id']] = $row;
            }
            foreach ((array) $tile->overlays as $raw) {
                if (! is_array($raw) || ! isset($raw['id'])) {
                    continue;
                }
                $row = KvLayerShape::toRow(KvLayerShape::toLayer($raw));
                $boardRow = $byId[$row['id']] ?? null;
                if ($boardRow === null || self::identity($boardRow) != self::identity($row)) {
                    $overrides[] = self::layerItem($row);
                }
            }
            if (count($overrides) > self::MAX_LAYERS) {
                $truncated['layers'] = true;
                $overrides = array_slice($overrides, 0, self::MAX_LAYERS);
            }
        }

        return [
            'size_id' => $tile->id,
            'preset' => $tile->displayLabel(),
            'width' => (int) $tile->width,
            'height' => (int) $tile->height,
            'status' => $tile->status?->value,
            'mode' => $tile->overlays === null ? 'inherit' : 'detached',
            'overrides' => $overrides,
        ];
    }

    private static function identity(array $row): array
    {
        return array_intersect_key(is_array($row['payload'] ?? null) ? $row['payload'] : [], array_flip(self::OVERRIDE_KEYS));
    }

    private static function byZ(array $rows): array
    {
        usort($rows, static fn (array $a, array $b) => ((int) $a['z']) <=> ((int) $b['z']));

        return $rows;
    }
}
```

- [ ] **Step 5: Write the controller, the route and the MCP twin**

`app/Http/Controllers/Api/ModelContextProtocol/KvCanvasToolController.php`:

```php
<?php

namespace App\Http\Controllers\Api\ModelContextProtocol;

use App\Exceptions\Studio\KvCanvasToolException;
use App\Exceptions\Studio\KvCollabUnavailableException;
use App\Models\StudioFile;
use App\Services\ModelContextProtocol\ToolContext;
use App\Services\Studio\AgentCanvas\KvCanvasContextAssembler;
use App\Support\Studio\KvAgentCanvasFlag;
use Closure;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;

/**
 * KV agentic canvas tools (spec 2026-09-29 §6, contract C3): read the canvas,
 * change layers across boards and sizes, undo a run. Thin: every rule about
 * WHERE an edit goes lives in KvCanvasEditService. Mirrored 1:1 to MCP
 * (App\Mcp\Tools\*KvCanvas*, *KvLayer*, UndoKvAgentRunTool).
 *
 * The MCP gateway calls these methods in-process, past route middleware, so
 * the flag is re-checked here and the file lookup applies the same
 * workspace + KV-tool + brand gate as KvToolController.
 */
class KvCanvasToolController extends ToolController
{
    private const KV_TOOL_SLUG = 'kv-generator';

    public function __construct(private readonly KvCanvasContextAssembler $assembler) {}

    /** get_kv_canvas — the canvas inventory (spec §5). */
    public function show(Request $request, string $fileId): JsonResponse
    {
        return $this->withFile($request, $fileId, function (StudioFile $file) use ($request): array {
            $selected = $request->input('selected_layer_ids', []);

            return $this->assembler->inventory(
                $this->assembler->load($file),
                self::optionalString($request->input('active_board_id')),
                self::optionalString($request->input('active_size_id')),
                is_array($selected) ? $selected : [],
            );
        });
    }

    /** @param  Closure(StudioFile, ToolContext): array<string, mixed>  $action */
    protected function withFile(Request $request, string $fileId, Closure $action): JsonResponse
    {
        $ctx = $this->ctx($request);
        if (! KvAgentCanvasFlag::enabledFor($ctx->user, $ctx->workspaceId)) {
            return response()->json(['message' => 'Not found', 'data' => null], 404);
        }

        $file = $this->kvFileFor($fileId, $ctx);
        if ($file === null) {
            return KvCanvasToolException::notFound('Key Visual file not found')->toResponse();
        }

        try {
            return response()->json(['data' => $action($file, $ctx)]);
        } catch (KvCanvasToolException $e) {
            return $e->toResponse();
        } catch (KvCollabUnavailableException $e) {
            return response()->json(['message' => $e->getMessage(), 'error' => 'collab_unavailable', 'data' => null], 503);
        }
    }

    protected function kvFileFor(string $fileId, ToolContext $ctx): ?StudioFile
    {
        $file = StudioFile::withoutGlobalScope('workspace')
            ->where('workspace_id', $ctx->workspaceId)
            ->whereHas('tool', fn ($q) => $q->where('slug', self::KV_TOOL_SLUG))
            ->find($fileId);

        return $file !== null && $this->canAccessBrand($file->brand_id, $ctx) ? $file : null;
    }

    protected static function optionalString(mixed $value): ?string
    {
        return is_string($value) && $value !== '' ? $value : null;
    }
}
```

`app/Mcp/Tools/GetKvCanvasTool.php`:

```php
<?php

namespace App\Mcp\Tools;

use App\Http\Controllers\Api\ModelContextProtocol\KvCanvasToolController;
use Illuminate\Contracts\JsonSchema\JsonSchema;

/** The KV canvas inventory: boards, their sizes, and the layers on each. */
class GetKvCanvasTool extends FrndosTool
{
    public const CONTROLLER = KvCanvasToolController::class;

    public const METHOD = 'show';

    protected string $name = 'get_kv_canvas';

    protected string $description = 'Read a Key Visual canvas: every board (current id, name, size in px, image), its resize sizes (inherit = follows the board, detached = own layers, with the layers that differ), and each layer (id, type, rect as fractions, z, text, style). Use these ids in the layer tools. Caps: 30 boards, 50 sizes per board, 60 layers per surface, text cut at 200 characters — `truncated` says when a cap was hit.';

    protected array $routeParamMap = ['file_id' => 'fileId'];

    public function schema(JsonSchema $schema): array
    {
        return [
            'workspace_id' => $this->workspaceIdSchema($schema),
            'file_id' => $schema->string()->description('KV file id (from list_kv_files).')->required(),
            'active_board_id' => $schema->string()->description('Optional: the board the user is looking at; echoed back in `active`.'),
            'active_size_id' => $schema->string()->description('Optional: the size the user is looking at; echoed back in `active`.'),
            'selected_layer_ids' => $schema->array()->items($schema->string())->description('Optional: layer ids the user has selected; echoed back in `active`.'),
        ];
    }
}
```

In `routes/api.php`: add `use App\Http\Controllers\Api\ModelContextProtocol\KvCanvasToolController;` beside the `KvToolController` import; directly after `Route::post('kv/generate', [KvToolController::class, 'generate']);` add:

```php
        // KV agentic canvas (spec 2026-09-29, contract C3): board layers are
        // written through collab, size layers into kv_resize_exports — see
        // KvCanvasEditService. Fail-closed flag; the controller re-checks it
        // because the MCP gateway calls it past this middleware.
        Route::middleware('feature.flag:kv-agentic-canvas,off')->group(function () {
            Route::get('kv/canvas/{fileId}', [KvCanvasToolController::class, 'show']);
        });
```

In `app/Mcp/Servers/FrndosServer.php`, in the `// Key Visuals` block after `Tools\GenerateKvTool::class,` add `Tools\GetKvCanvasTool::class,`.

- [ ] **Step 6: Run the tests and the mirror**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/KvCanvasInventoryTest.php tests/Unit/Mcp/KvCanvasToolsTest.php --compact && php artisan mcp:verify-mirror`
Expected: all PASS; `Mirror OK`.

- [ ] **Step 7: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
vendor/bin/pint --dirty --format agent
git add app/Support/Studio/KvAgentCanvasFlag.php app/Services/Studio/AgentCanvas/KvCanvasState.php app/Services/Studio/AgentCanvas/KvCanvasContextAssembler.php app/Http/Controllers/Api/ModelContextProtocol/KvCanvasToolController.php app/Mcp/Tools/GetKvCanvasTool.php app/Mcp/Servers/FrndosServer.php routes/api.php tests/Support/KvCanvasFixture.php tests/Support/FakeKvCollab.php tests/Traits/BuildsKvCanvas.php tests/Feature/Studio/AgentCanvas/KvCanvasInventoryTest.php tests/Unit/Mcp/KvCanvasToolsTest.php
git commit -m "feat(api): get_kv_canvas inventory tool behind kv-agentic-canvas (C3.2, C7)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: `KvAgentRunRecorder` — ledger, per-file run lock, settling

**Files:**
- Create: `app/Services/Studio/AgentCanvas/KvAgentRunRecorder.php`
- Test: `tests/Feature/Studio/AgentCanvas/KvAgentRunRecorderTest.php`

**Interfaces:**
- Consumes: `KvAgentRun` (Task 4), `KvCanvasToolException` (Task 5), `ToolContext`.
- Produces `KvAgentRunRecorder`:
  - `ensureRun(StudioFile $file, ToolContext $ctx, ?string $requestedRunId): KvAgentRun` — creates the row on first use (source `app` when the id came with an internal-token call, else `mcp`; a new id is minted when none is given — C3.8), takes/refreshes the per-file lock; throws 409 `run_mismatch` (run of another file/user), `run_undone`, `run_in_progress` (another running run holds the file).
  - `remainingOps(KvAgentRun $run): int`, `record(KvAgentRun $run, array $ops, array $skipped, array $detachedSizes): void` (atomic jsonb append; stamps `at` on ops), `settle(?string $runId): void` (running → completed, releases the lock), `fail(?string $runId, string $reason): void` (running → failed), `settleIfIdle(KvAgentRun $run): KvAgentRun` (MCP run idle > 10 min → completed; app run silent > 15 min → failed), `releaseFileLock(KvAgentRun $run): void`, `static fileLockKey(string $fileId): string`; consts `FILE_LOCK_SECONDS = 600`, `MCP_IDLE_SECONDS = 600`, `APP_STALE_SECONDS = 900`.

- [ ] **Step 1: Write the failing test**

`tests/Feature/Studio/AgentCanvas/KvAgentRunRecorderTest.php`:

```php
<?php

use App\Exceptions\Studio\KvCanvasToolException;
use App\Models\KvAgentRun;
use App\Models\StudioFile;
use App\Services\Studio\AgentCanvas\KvAgentRunRecorder;
use Illuminate\Support\Str;
use Tests\Traits\BuildsKvCanvas;

uses(BuildsKvCanvas::class);

beforeEach(function () {
    $this->setUpKvCanvas();
    $this->recorder = app(KvAgentRunRecorder::class);
});

function recorderConflict(callable $call): string
{
    try {
        $call();
    } catch (KvCanvasToolException $e) {
        expect($e->status)->toBe(409);

        return $e->errorCode;
    }
    test()->fail('expected a 409');
}

it('opens an app run for the chat-minted id and an mcp run when none is given', function () {
    $app = $this->recorder->ensureRun($this->file, $this->kvCtx($this->runId), $this->runId);
    expect($app->id)->toBe($this->runId)->and($app->source)->toBe('app')->and($app->status)->toBe('running')
        ->and($app->workspace_id)->toBe($this->workspace->id);

    $this->recorder->settle($app->id);
    $mcp = $this->recorder->ensureRun($this->file, $this->kvCtx(null, 'user'), null);
    expect($mcp->source)->toBe('mcp')->and(strlen($mcp->id))->toBe(26)->and($mcp->id)->not->toBe($this->runId);
});

it('lets one run hold a file and refuses a second until it settles', function () {
    $this->recorder->ensureRun($this->file, $this->kvCtx($this->runId), $this->runId);
    $this->recorder->ensureRun($this->file, $this->kvCtx($this->runId), $this->runId); // same run: fine

    $other = (string) Str::ulid();
    expect(recorderConflict(fn () => $this->recorder->ensureRun($this->file, $this->kvCtx($other), $other)))->toBe('run_in_progress')
        ->and(KvAgentRun::find($other))->toBeNull();

    $this->recorder->settle($this->runId);
    expect(KvAgentRun::find($this->runId)->status)->toBe('completed')
        ->and($this->recorder->ensureRun($this->file, $this->kvCtx($other), $other)->id)->toBe($other);
});

it('takes over the file from an MCP run idle for more than ten minutes', function () {
    $idle = $this->recorder->ensureRun($this->file, $this->kvCtx(null, 'user'), null);
    KvAgentRun::whereKey($idle->id)->update(['updated_at' => now()->subMinutes(11)]);

    $next = $this->recorder->ensureRun($this->file, $this->kvCtx($this->runId), $this->runId);

    expect($next->id)->toBe($this->runId)->and($idle->fresh()->status)->toBe('completed');
});

it('refuses a run id that belongs to another file, and an undone run', function () {
    $otherFile = StudioFile::factory()->create(['workspace_id' => $this->workspace->id, 'brand_id' => null, 'tool_id' => $this->file->tool_id]);
    $this->recorder->ensureRun($otherFile, $this->kvCtx($this->runId), $this->runId);
    expect(recorderConflict(fn () => $this->recorder->ensureRun($this->file, $this->kvCtx($this->runId), $this->runId)))->toBe('run_mismatch');

    $undone = (string) Str::ulid();
    KvAgentRun::create(['id' => $undone, 'studio_file_id' => $this->file->id, 'user_id' => $this->user->id,
        'workspace_id' => $this->workspace->id, 'source' => 'app', 'status' => 'undone']);
    expect(recorderConflict(fn () => $this->recorder->ensureRun($this->file, $this->kvCtx($undone), $undone)))->toBe('run_undone');
});

it('appends ledger entries atomically and counts the op budget', function () {
    $run = $this->recorder->ensureRun($this->file, $this->kvCtx($this->runId), $this->runId);

    $this->recorder->record($run, [['type' => 'set_layer', 'layer_id' => 'A']], [], []);
    $this->recorder->record($run, [['type' => 'set_layer', 'layer_id' => 'B']], [['target' => 't', 'reason' => 'layer_not_found']], [['size_id' => 's', 'label' => 'S']]);

    $fresh = $run->fresh();
    expect(array_column($fresh->ops, 'layer_id'))->toBe(['A', 'B'])
        ->and($fresh->ops[0]['at'])->toBeString()
        ->and($fresh->skipped)->toHaveCount(1)
        ->and($fresh->detached_sizes)->toBe([['size_id' => 's', 'label' => 'S']])
        ->and($this->recorder->remainingOps($fresh))->toBe(198);
});

it('fails a running run and leaves a settled one alone', function () {
    $run = $this->recorder->ensureRun($this->file, $this->kvCtx($this->runId), $this->runId);
    $this->recorder->fail($run->id, 'stream_failed');
    expect($run->fresh()->status)->toBe('failed');

    $this->recorder->settle($run->id);
    expect($run->fresh()->status)->toBe('failed');
});
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/KvAgentRunRecorderTest.php --compact`
Expected: FAIL — class not found.

- [ ] **Step 3: Implement**

`app/Services/Studio/AgentCanvas/KvAgentRunRecorder.php`:

```php
<?php

namespace App\Services\Studio\AgentCanvas;

use App\Exceptions\Studio\KvCanvasToolException;
use App\Models\KvAgentRun;
use App\Models\StudioFile;
use App\Services\ModelContextProtocol\ToolContext;
use Illuminate\Database\QueryException;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

/**
 * The KV run ledger (spec §8.1, contract C6) and the one-run-per-file lock.
 *
 * `ensureRun` runs before a write; `record` after it. agno runs a turn's tool
 * calls concurrently, so the row is created with a unique-violation guard and
 * the ledger is appended in SQL (`ops || ?`), never read-modify-written —
 * the model's copy is stale the moment two calls race (DeckAgentRunRecorder
 * learned this the hard way).
 */
final class KvAgentRunRecorder
{
    /** The per-file lock slides forward on every write. */
    public const FILE_LOCK_SECONDS = 600;

    /** An MCP run has no stream to close it: 10 min without a write completes it (C6). */
    public const MCP_IDLE_SECONDS = 600;

    /** An app run whose stream died without `done` is treated as failed after 15 min. */
    public const APP_STALE_SECONDS = 900;

    /** @throws KvCanvasToolException 409 run_mismatch | run_undone | run_in_progress */
    public function ensureRun(StudioFile $file, ToolContext $ctx, ?string $requestedRunId): KvAgentRun
    {
        $runId = $requestedRunId ?? (string) Str::ulid();

        $existing = $requestedRunId !== null ? KvAgentRun::query()->find($runId) : null;
        if ($existing !== null) {
            $this->assertUsable($existing, $file, $ctx);
        }

        $this->acquireFileLock($file->id, $runId);
        if ($existing !== null) {
            return $existing;
        }

        try {
            $run = KvAgentRun::query()->firstOrCreate(['id' => $runId], [
                'studio_file_id' => $file->id,
                'user_id' => $ctx->user->id,
                'workspace_id' => $ctx->workspaceId,
                // The chat turn mints the id and ai-service forwards it with
                // the internal token; anything else is an MCP client's run.
                'source' => $requestedRunId !== null && $ctx->via === 'internal' ? KvAgentRun::SOURCE_APP : KvAgentRun::SOURCE_MCP,
                'status' => KvAgentRun::STATUS_RUNNING,
            ]);
        } catch (QueryException $e) {
            // Lost the insert race; only a unique violation means that.
            if ($e->getCode() !== '23505') {
                throw $e;
            }
            $run = KvAgentRun::query()->findOrFail($runId);
        }
        $this->assertUsable($run, $file, $ctx);

        return $run;
    }

    public function remainingOps(KvAgentRun $run): int
    {
        return max(0, KvAgentRun::MAX_OPS - count($run->fresh()?->ops ?? []));
    }

    /**
     * @param  list<array<string, mixed>>  $ops
     * @param  list<array<string, mixed>>  $skipped
     * @param  list<array{size_id: string, label: string}>  $detachedSizes
     */
    public function record(KvAgentRun $run, array $ops, array $skipped, array $detachedSizes): void
    {
        if ($ops === [] && $skipped === [] && $detachedSizes === []) {
            return;
        }
        $at = now()->toIso8601String();
        $ops = array_map(static fn (array $op): array => $op + ['at' => $at], array_values($ops));

        if (DB::getDriverName() === 'pgsql') {
            DB::update(
                'UPDATE kv_agent_runs SET ops = ops || ?::jsonb, skipped = skipped || ?::jsonb, detached_sizes = detached_sizes || ?::jsonb, updated_at = ? WHERE id = ?',
                [json_encode($ops), json_encode(array_values($skipped)), json_encode(array_values($detachedSizes)), now(), $run->id],
            );
        } else {
            $fresh = $run->fresh();
            $fresh?->forceFill([
                'ops' => array_merge($fresh->ops ?? [], $ops),
                'skipped' => array_merge($fresh->skipped ?? [], array_values($skipped)),
                'detached_sizes' => array_merge($fresh->detached_sizes ?? [], array_values($detachedSizes)),
            ])->save();
        }
        $run->refresh();

        $key = self::fileLockKey($run->studio_file_id);
        if (Cache::get($key) === $run->id) {
            Cache::put($key, $run->id, self::FILE_LOCK_SECONDS);
        }
    }

    /** The chat turn reached `done`: close the run and free the file. */
    public function settle(?string $runId): void
    {
        $this->close($runId, KvAgentRun::STATUS_COMPLETED);
    }

    public function fail(?string $runId, string $reason): void
    {
        $this->close($runId, KvAgentRun::STATUS_FAILED);
    }

    public function settleIfIdle(KvAgentRun $run): KvAgentRun
    {
        if ($run->status !== KvAgentRun::STATUS_RUNNING || $run->updated_at === null) {
            return $run;
        }
        if ($run->source === KvAgentRun::SOURCE_MCP && $run->updated_at->lt(now()->subSeconds(self::MCP_IDLE_SECONDS))) {
            $this->close($run->id, KvAgentRun::STATUS_COMPLETED);
        } elseif ($run->source === KvAgentRun::SOURCE_APP && $run->updated_at->lt(now()->subSeconds(self::APP_STALE_SECONDS))) {
            $this->close($run->id, KvAgentRun::STATUS_FAILED);
        }

        return $run->fresh() ?? $run;
    }

    public function releaseFileLock(KvAgentRun $run): void
    {
        $key = self::fileLockKey($run->studio_file_id);
        if (Cache::get($key) === $run->id) {
            Cache::forget($key);
        }
    }

    public static function fileLockKey(string $fileId): string
    {
        return 'kv-agent-run-file:'.$fileId;
    }

    private function close(?string $runId, string $status): void
    {
        if ($runId === null || $runId === '') {
            return;
        }
        $run = KvAgentRun::query()->find($runId);
        if ($run === null || $run->status !== KvAgentRun::STATUS_RUNNING) {
            return;
        }
        $run->forceFill(['status' => $status])->save();
        $this->releaseFileLock($run);
    }

    private function assertUsable(KvAgentRun $run, StudioFile $file, ToolContext $ctx): void
    {
        if ($run->studio_file_id !== $file->id || $run->user_id !== $ctx->user->id) {
            throw KvCanvasToolException::conflict('run_mismatch', 'That agent run belongs to another file or user. Omit agent_run_id to start a new run.');
        }
        if ($run->isUndone()) {
            throw KvCanvasToolException::conflict('run_undone', 'That agent run was undone; start a new run for further changes.');
        }
    }

    private function acquireFileLock(string $fileId, string $runId): void
    {
        $key = self::fileLockKey($fileId);
        if (Cache::add($key, $runId, self::FILE_LOCK_SECONDS)) {
            return;
        }

        $holder = Cache::get($key);
        if ($holder !== $runId) {
            $holderRun = is_string($holder) ? KvAgentRun::query()->find($holder) : null;
            if ($holderRun !== null) {
                $holderRun = $this->settleIfIdle($holderRun);
            }
            if ($holderRun !== null && $holderRun->status === KvAgentRun::STATUS_RUNNING) {
                throw KvCanvasToolException::conflict(
                    'run_in_progress',
                    'Another agent run is changing this canvas right now. Try again when it finishes.',
                    ['run_id' => $holderRun->id],
                );
            }
        }

        Cache::put($key, $runId, self::FILE_LOCK_SECONDS);
    }
}
```

- [ ] **Step 4: Run the test**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/KvAgentRunRecorderTest.php --compact`
Expected: 6 PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
vendor/bin/pint --dirty --format agent
git add app/Services/Studio/AgentCanvas/KvAgentRunRecorder.php tests/Feature/Studio/AgentCanvas/KvAgentRunRecorderTest.php
git commit -m "feat(api): KV agent run recorder with per-file run lock

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 11: `KvCanvasEditService` — routing layer edits to the doc and to sizes (incl. detach)

**Files:**
- Create: `app/Services/Studio/AgentCanvas/KvCanvasWriteLog.php`, `app/Services/Studio/AgentCanvas/KvCanvasEditService.php`
- Modify: `app/Services/Studio/KvResizeExportService.php` (add `writeOverlays`), `app/Http/Controllers/Api/Studio/KvResizeExportController.php:404` (`updateOverlays` calls it), `tests/Traits/BuildsKvCanvas.php` (add `kvUpdate`)
- Test: `tests/Feature/Studio/AgentCanvas/KvCanvasEditServiceTest.php`

**Interfaces:**
- Consumes: `KvCanvasContextAssembler::load`, `KvCanvasState` (Task 9), `KvCollabWriter::applyOps` (Task 5), `KvAgentRunRecorder` (Task 10), `KvTileOverlayProjector::resolve` (Task 7), `StudioOverlayNormalizer::rowError` (Task 2), `KvLayerPatch::apply`, `KvLayerDiff::setLayerOp/fullExpected` (Task 8), `KvLayerShape::toLayer` (Task 3).
- Produces:
  - `KvResizeExportService::writeOverlays(KvResizeExport $row, ?array $overlays): KvResizeExport` — the one writer of a tile snapshot (Eloquent update, so `updated_at` moves and the resize SSE feed re-sends the row).
  - `KvCanvasWriteLog` (public `budget`, `applied`, `skipped`, `detachedSizes`, `ops`, `skippedLedger`, `detachedLedger`; `apply(array $surface, string $layerId, string $op, ?array $before, ?array $after, array $extra = [])`, `detach(array $surface, array $snapshot)`, `skip(string $target, string $kind, string $label, ?string $layerId, string $reason)`, `skipSurface(array $surface, ?string $layerId, string $reason)`, `result(?string $runId): array` = C3.3).
  - `KvCanvasEditService::MAX_TARGETS = 60`; `updateLayers(StudioFile $file, ToolContext $ctx, ?string $runId, array $edits): array` (C3.3 result; throws `KvCanvasToolException` 422 `too_many_targets`, 409 from `ensureRun`). Private engine `execute()` handles intents of kind `set` here; Tasks 13/14 add `add` and `remove` arms to `nextRow()`.
  - Test helper `BuildsKvCanvas::kvUpdate(array $edits, ?string $runId = null): array`.

- [ ] **Step 1: Add the tile writer and route the browser's tile PATCH through it**

In `app/Services/Studio/KvResizeExportService.php` add (after `duplicate()`):

```php
    /**
     * The one writer of a tile's overlay snapshot — the browser's PATCH and
     * agent canvas writes both land here. `null` puts the tile back to
     * inheriting its board. An Eloquent update on purpose: `updated_at` moves,
     * so the resize-exports SSE feed (`export.updated`) re-sends the row to an
     * open editor.
     *
     * @param  list<array<string, mixed>>|null  $overlays
     */
    public function writeOverlays(KvResizeExport $row, ?array $overlays): KvResizeExport
    {
        $row->update(['overlays' => $overlays === null ? null : array_values($overlays)]);

        return $row;
    }
```

In `KvResizeExportController::updateOverlays` replace `$export->update(['overlays' => $request->input('overlays')]);` with `$this->service->writeOverlays($export, $request->input('overlays'));`.

Add to `tests/Traits/BuildsKvCanvas.php` (import `App\Services\Studio\AgentCanvas\KvCanvasEditService`):

```php
    /** update_kv_layers through the service, as the chat turn's run. */
    protected function kvUpdate(array $edits, ?string $runId = null): array
    {
        $runId ??= $this->runId;

        return app(KvCanvasEditService::class)->updateLayers($this->file, $this->kvCtx($runId), $runId, $edits);
    }
```

- [ ] **Step 2: Write the failing tests (board targets / the doc sink)**

`tests/Feature/Studio/AgentCanvas/KvCanvasEditServiceTest.php`:

```php
<?php

use App\Models\KvAgentRun;
use App\Models\KvResizeExport;
use App\Services\Studio\AgentCanvas\KvTileOverlayProjector;
use Illuminate\Support\Facades\Http;
use Tests\Support\KvCanvasFixture as K;
use Tests\Traits\BuildsKvCanvas;

uses(BuildsKvCanvas::class);

beforeEach(fn () => $this->setUpKvCanvas());

function kvSet(string $layerId, array $targets, array $set): array
{
    return ['layer_id' => $layerId, 'targets' => $targets, 'set' => $set];
}

// --- board targets: the live doc ------------------------------------------

it('writes a board target into the live doc and leaves an inheriting size alone', function () {
    $inheriting = $this->kvTile();

    $result = $this->kvUpdate([kvSet(K::HEADLINE, ['board_ids' => [$this->boardA->id]], ['text' => 'Ramadan Sale'])]);

    expect($result)->toBe([
        'run_id' => $this->runId,
        'applied' => [['target' => $this->boardA->id, 'layer_id' => K::HEADLINE, 'op' => 'set_layer']],
        'skipped' => [],
        'detached_sizes' => [],
    ])
        ->and($this->collab->layer(K::HEADLINE)['payload']['content'])->toBe('Ramadan Sale')
        ->and($inheriting->fresh()->overlays)->toBeNull();

    // One batch, one op, CAS on what the api read immediately before.
    expect($this->collab->batches)->toHaveCount(1)
        ->and($this->collab->batches[0]['run_id'])->toBe($this->runId)
        ->and($this->collab->batches[0]['ops'])->toBe([[
            'kind' => 'set_layer', 'layer_id' => K::HEADLINE,
            'set' => ['payload' => ['content' => 'Ramadan Sale']],
            'expected' => ['payload' => ['content' => 'Promo Ramadan']],
        ]]);

    $op = KvAgentRun::findOrFail($this->runId)->ops[0];
    expect($op)->toMatchArray(['type' => 'set_layer', 'sink' => 'doc', 'target' => $this->boardA->id, 'target_kind' => 'board', 'target_label' => 'Concept A', 'layer_id' => K::HEADLINE])
        ->and($op['before']['payload']['content'])->toBe('Promo Ramadan')
        ->and($op['after']['payload']['content'])->toBe('Ramadan Sale');
});

it('resolves a version-chain id to the current board', function () {
    $result = $this->kvUpdate([kvSet(K::HEADLINE, ['board_ids' => [K::OLD_A]], ['text' => 'Ramadan Sale'])]);

    expect($result['applied'][0]['target'])->toBe($this->boardA->id)
        ->and($this->collab->layer(K::HEADLINE)['payload']['content'])->toBe('Ramadan Sale');
});

it('coalesces two edits on one layer into one collab op', function () {
    $result = $this->kvUpdate([
        kvSet(K::HEADLINE, ['board_ids' => [$this->boardA->id]], ['text' => 'Ramadan Sale']),
        kvSet(K::HEADLINE, ['board_ids' => [$this->boardA->id]], ['rect' => ['y' => 0.5]]),
    ]);

    expect($result['applied'])->toHaveCount(2)
        ->and($this->collab->batches)->toHaveCount(1)
        ->and($this->collab->batches[0]['ops'])->toHaveCount(1)
        ->and($this->collab->batches[0]['ops'][0]['set'])->toEqual(['rect' => ['y' => 0.5], 'payload' => ['content' => 'Ramadan Sale']])
        ->and($this->collab->layer(K::HEADLINE)['rect']['y'])->toEqual(0.5);
    // The ledger chains the two steps, so Undo can walk them back in order.
    $ops = KvAgentRun::findOrFail($this->runId)->ops;
    expect($ops[1]['before']['payload']['content'])->toBe('Ramadan Sale');
});

it('collapses per-run styling into the first run when the text is replaced', function () {
    $this->collab->editLayer(K::HEADLINE, function (array $layer) {
        $layer['payload']['runs'] = [['length' => 5, 'fontFamily' => 'bf_01'], ['length' => 8, 'color' => '#FF0000']];

        return $layer;
    });

    $this->kvUpdate([kvSet(K::HEADLINE, ['board_ids' => [$this->boardA->id]], ['text' => 'Ramadan Sale'])]);

    expect($this->collab->layer(K::HEADLINE)['payload']['runs'])->toBe([['fontFamily' => 'bf_01', 'length' => 12]]);
});

it('counts UTF-16 units for the collapsed run', function () {
    $this->collab->editLayer(K::HEADLINE, function (array $layer) {
        $layer['payload']['runs'] = [['length' => 13, 'fontWeight' => 'bold']];

        return $layer;
    });

    $this->kvUpdate([kvSet(K::HEADLINE, ['board_ids' => [$this->boardA->id]], ['text' => '🎉 Sale'])]);

    expect($this->collab->layer(K::HEADLINE)['payload']['runs'])->toBe([['fontWeight' => 'bold', 'length' => 7]]);
});

it('reports a layer that is not on the targeted board, and an unknown target', function () {
    $result = $this->kvUpdate([kvSet(K::CAPTION, ['board_ids' => [$this->boardA->id, 'nope']], ['text' => 'x'])]);

    expect($result['applied'])->toBe([])
        ->and($result['skipped'])->toEqualCanonicalizing([
            ['target' => 'nope', 'layer_id' => K::CAPTION, 'reason' => 'target_not_found'],
            ['target' => $this->boardA->id, 'layer_id' => K::CAPTION, 'reason' => 'layer_not_found'],
        ])
        ->and($this->collab->batches)->toBe([]);
});

it('never sends a layer the browser PATCH would reject', function (array $set) {
    $result = $this->kvUpdate([kvSet(K::HEADLINE, ['board_ids' => [$this->boardA->id]], $set)]);

    expect($result['skipped'][0]['reason'])->toBe('invalid_payload')
        ->and($this->collab->opsRequestCount())->toBe(0)
        ->and($this->collab->layer(K::HEADLINE)['rect']['width'])->toBe(0.6);
})->with([
    'zero width' => [['rect' => ['w' => 0]]],
    'text over 500 characters' => [['text' => str_repeat('a', 501)]],
]);

it('refuses a style key that does not apply to the layer type', function () {
    $result = $this->kvUpdate([kvSet(K::LOGO, ['board_ids' => [$this->boardA->id]], ['style' => ['fontFamily' => 'bf_01']])]);

    expect($result['skipped'])->toBe([['target' => $this->boardA->id, 'layer_id' => K::LOGO, 'reason' => 'invalid_payload']])
        ->and($this->collab->opsRequestCount())->toBe(0);
});

it('skips every target when the live doc cannot be read, without opening a run', function () {
    $this->collab->down = true;

    $result = $this->kvUpdate([kvSet(K::HEADLINE, ['board_ids' => [$this->boardA->id]], ['text' => 'x'])]);

    expect($result['skipped'])->toBe([['target' => $this->boardA->id, 'layer_id' => K::HEADLINE, 'reason' => 'collab_unavailable']])
        ->and(KvAgentRun::count())->toBe(0);
});

it('reports collab_unavailable when collab fails the write, and records nothing applied', function () {
    $this->collab->refusals = [[500, ['error' => 'ops_failed']]];

    $result = $this->kvUpdate([kvSet(K::HEADLINE, ['board_ids' => [$this->boardA->id]], ['text' => 'x'])]);

    $run = KvAgentRun::findOrFail($this->runId);
    expect($result['skipped'][0]['reason'])->toBe('collab_unavailable')
        ->and($run->ops)->toBe([])
        ->and($run->skipped[0]['reason'])->toBe('collab_unavailable')
        ->and($this->collab->layer(K::HEADLINE)['payload']['content'])->toBe('Promo Ramadan');
});

it('retries a CAS race once against a fresh read', function () {
    $this->collab->refusals = [[409, ['error' => 'layer_changed', 'layer_id' => K::HEADLINE]]];

    $result = $this->kvUpdate([kvSet(K::HEADLINE, ['board_ids' => [$this->boardA->id]], ['text' => 'Ramadan Sale'])]);

    expect($result['applied'])->toHaveCount(1)
        ->and($this->collab->opsRequestCount())->toBe(2)
        ->and($this->collab->layer(K::HEADLINE)['payload']['content'])->toBe('Ramadan Sale');
});
```

- [ ] **Step 3: Run them to see them fail**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/KvCanvasEditServiceTest.php --compact`
Expected: FAIL — `KvCanvasEditService` not found.

- [ ] **Step 4: Write `KvCanvasWriteLog` and `KvCanvasEditService`**

`app/Services/Studio/AgentCanvas/KvCanvasWriteLog.php`:

```php
<?php

namespace App\Services\Studio\AgentCanvas;

/**
 * What one tool call did: the C3.3 result and the ledger rows behind it,
 * built in step so the agent is never told about a change the ledger (and so
 * Undo) does not hold.
 */
final class KvCanvasWriteLog
{
    /** @var list<array{target: string, layer_id: ?string, op: string}> */
    public array $applied = [];

    /** @var list<array{target: string, layer_id: ?string, reason: string}> */
    public array $skipped = [];

    /** @var list<string> */
    public array $detachedSizes = [];

    /** @var list<array<string, mixed>> */
    public array $ops = [];

    /** @var list<array<string, mixed>> */
    public array $skippedLedger = [];

    /** @var list<array{size_id: string, label: string}> */
    public array $detachedLedger = [];

    public function __construct(public int $budget) {}

    public function apply(array $surface, string $layerId, string $op, ?array $before, ?array $after, array $extra = []): void
    {
        $this->budget--;
        $this->applied[] = ['target' => $surface['id'], 'layer_id' => $layerId, 'op' => $op];
        $this->ops[] = [
            'type' => $op,
            'sink' => $surface['kind'] === 'board' ? 'doc' : 'tile',
            'target' => $surface['id'],
            'target_kind' => $surface['kind'],
            'target_label' => $surface['label'],
            'layer_id' => $layerId,
            'before' => $before,
            'after' => $after,
        ] + $extra;
    }

    public function detach(array $surface, array $snapshot): void
    {
        $this->budget--;
        $this->detachedSizes[] = $surface['id'];
        $this->detachedLedger[] = ['size_id' => $surface['id'], 'label' => $surface['label']];
        $this->ops[] = [
            'type' => 'detach_size', 'sink' => 'tile', 'target' => $surface['id'], 'target_kind' => 'size',
            'target_label' => $surface['label'], 'layer_id' => null, 'before' => null, 'after' => $snapshot,
        ];
    }

    public function skip(string $target, string $kind, string $label, ?string $layerId, string $reason): void
    {
        $this->skipped[] = ['target' => $target, 'layer_id' => $layerId, 'reason' => $reason];
        $this->skippedLedger[] = ['target' => $target, 'target_kind' => $kind, 'target_label' => $label, 'layer_id' => $layerId, 'reason' => $reason];
    }

    public function skipSurface(array $surface, ?string $layerId, string $reason): void
    {
        $this->skip($surface['id'], $surface['kind'], $surface['label'], $layerId, $reason);
    }

    /** Contract C3.3. */
    public function result(?string $runId): array
    {
        return ['run_id' => $runId, 'applied' => $this->applied, 'skipped' => $this->skipped, 'detached_sizes' => $this->detachedSizes];
    }
}
```

`app/Services/Studio/AgentCanvas/KvCanvasEditService.php`:

```php
<?php

namespace App\Services\Studio\AgentCanvas;

use App\Exceptions\Studio\KvCanvasToolException;
use App\Exceptions\Studio\KvCollabRejectedException;
use App\Exceptions\Studio\KvCollabUnavailableException;
use App\Exceptions\Studio\KvLayerChangedException;
use App\Exceptions\Studio\KvLayerNotFoundException;
use App\Exceptions\Studio\KvLayerPatchException;
use App\Models\KvAgentRun;
use App\Models\KvResizeExport;
use App\Models\StudioFile;
use App\Services\ModelContextProtocol\ToolContext;
use App\Services\Studio\KvResizeExportService;
use App\Services\Studio\StudioOverlayNormalizer;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;

/**
 * The only place that knows where an agent's layer edit goes (spec §4.1).
 *
 * - A BOARD target is a layer in the live Y.Doc, written through collab in
 *   ONE atomic batch per call, one coalesced op per layer (collab validates
 *   the whole batch before applying, so two ops on one layer would CAS
 *   against stale values). Inheriting sizes follow by re-projection.
 * - A SIZE target is a row in `kv_resize_exports.overlays`, written under a
 *   row lock. An inheriting size named directly is DETACHED first — frozen
 *   to exactly what the browser shows (KvTileOverlayProjector) — then edited,
 *   as the same manual edit would do.
 *
 * Every layer is validated as it will look AFTER the op with the browser
 * PATCH's own rules (StudioOverlayNormalizer) before anything is written:
 * collab does not validate, and a value api later rejects would sit in the
 * live doc and fail every open tab's autosave.
 */
final class KvCanvasEditService
{
    public const MAX_TARGETS = 60;

    public function __construct(
        private readonly KvCanvasContextAssembler $assembler,
        private readonly KvCollabWriter $collab,
        private readonly KvAgentRunRecorder $recorder,
        private readonly KvTileOverlayProjector $projector,
        private readonly StudioOverlayNormalizer $normalizer,
        private readonly KvResizeExportService $tiles,
    ) {}

    /**
     * update_kv_layers (C3.4).
     *
     * @param  list<array{layer_id: string, targets: array, set: array}>  $edits
     * @return array{run_id: ?string, applied: list<array>, skipped: list<array>, detached_sizes: list<string>}
     */
    public function updateLayers(StudioFile $file, ToolContext $ctx, ?string $runId, array $edits): array
    {
        $intents = [];
        foreach ($edits as $edit) {
            $intents[] = [
                'kind' => 'set',
                'layer_id' => (string) $edit['layer_id'],
                'targets' => (array) $edit['targets'],
                'set' => (array) $edit['set'],
            ];
        }

        return $this->execute($file, $ctx, $runId, $intents);
    }

    private function execute(StudioFile $file, ToolContext $ctx, ?string $requestedRunId, array $intents): array
    {
        try {
            $state = $this->assembler->load($file);
        } catch (KvCollabUnavailableException $e) {
            Log::warning('kv.agent_canvas.write_unavailable', ['studio_file_id' => $file->id, 'message' => $e->getMessage()]);
            $log = new KvCanvasWriteLog(0);
            foreach ($intents as $intent) {
                foreach (KvCanvasState::targetIds($intent['targets']) as $target) {
                    $log->skip($target, 'unknown', $target, $intent['layer_id'], 'collab_unavailable');
                }
            }

            return $log->result($requestedRunId);
        }

        // Expand and cap BEFORE a run is opened or anything is written.
        $count = 0;
        foreach ($intents as $i => $intent) {
            $intents[$i]['resolved'] = $state->resolveTargets($intent['targets']);
            $count += count($intents[$i]['resolved']['surfaces']) + count($intents[$i]['resolved']['missing']);
        }
        if ($count > self::MAX_TARGETS) {
            throw KvCanvasToolException::unprocessable(
                'too_many_targets',
                "This call expands to {$count} targets; at most ".self::MAX_TARGETS.' are allowed per call. Split it into smaller calls.',
                ['max' => self::MAX_TARGETS],
            );
        }

        $run = $this->recorder->ensureRun($file, $ctx, $requestedRunId);
        $log = new KvCanvasWriteLog($this->recorder->remainingOps($run));

        $docItems = [];
        $tileItems = [];
        foreach ($intents as $intent) {
            foreach ($intent['resolved']['missing'] as $missing) {
                $log->skip($missing['id'], $missing['kind'], $missing['id'], $intent['layer_id'], 'target_not_found');
            }
            foreach ($intent['resolved']['surfaces'] as $surface) {
                if ($surface['kind'] === 'board') {
                    $docItems[] = [$intent, $surface];
                } else {
                    $tileItems[$surface['id']][] = [$intent, $surface];
                }
            }
        }

        $this->writeDoc($state, $run, $docItems, $log);
        foreach ($tileItems as $tileId => $items) {
            $this->writeTile($state, (string) $tileId, $items, $log);
        }

        $this->recorder->record($run, $log->ops, $log->skippedLedger, $log->detachedLedger);

        return $log->result($run->id);
    }

    /** Board targets: one atomic collab batch, retried once against a fresh read on a CAS race. */
    private function writeDoc(KvCanvasState $state, KvAgentRun $run, array $items, KvCanvasWriteLog $log): void
    {
        if ($items === []) {
            return;
        }

        for ($attempt = 1; ; $attempt++) {
            $plan = $this->planDoc($state, $items, $log->budget);
            $failure = null;
            if ($plan['ops'] !== []) {
                try {
                    $this->collab->applyOps($state->file, $plan['ops'], $run->id);
                } catch (KvLayerChangedException|KvLayerNotFoundException) {
                    if ($attempt < 2) {
                        try {
                            $state = $this->assembler->load($state->file);

                            continue;
                        } catch (KvCollabUnavailableException) {
                            $failure = 'collab_unavailable';
                        }
                    } else {
                        $failure = 'layer_changed';
                    }
                } catch (KvCollabUnavailableException) {
                    $failure = 'collab_unavailable';
                } catch (KvCollabRejectedException) {
                    $failure = 'invalid_payload';
                }
            }

            foreach ($plan['skips'] as [$surface, $layerId, $reason]) {
                $log->skipSurface($surface, $layerId, $reason);
            }
            foreach ($plan['pending'] as [$surface, $layerId, $op, $before, $after]) {
                if ($failure !== null) {
                    $log->skipSurface($surface, $layerId, $failure);
                } else {
                    $log->apply($surface, $layerId, $op, $before, $after);
                }
            }

            return;
        }
    }

    /**
     * @return array{pending: list<array{0: array, 1: string, 2: string, 3: ?array, 4: ?array}>, skips: list<array{0: array, 1: string, 2: string}>, ops: list<array<string, mixed>>}
     */
    private function planDoc(KvCanvasState $state, array $items, int $budget): array
    {
        $original = [];
        $working = [];
        $pending = [];
        $skips = [];
        $adds = 0;

        foreach ($items as [$intent, $surface]) {
            $board = $surface['board'];
            $layerId = self::layerIdFor($intent, $surface);
            if (! array_key_exists($layerId, $working)) {
                $original[$layerId] = $working[$layerId] = $state->layer($layerId);
            }
            $current = $working[$layerId];

            if ($intent['kind'] !== 'add' && ($current === null || ! $state->isOnBoard($current, $board))) {
                $skips[] = [$surface, $layerId, 'layer_not_found'];

                continue;
            }
            if (count($pending) >= $budget) {
                $skips[] = [$surface, $layerId, 'run_op_cap_reached'];

                continue;
            }
            // Only a NEW layer needs the board's pixel size (placement); an AI
            // render has none recorded and would otherwise be probed on every edit.
            $dims = $intent['kind'] === 'add' ? $state->boardDims($board) : null;
            try {
                $next = $this->nextRow($intent, $current, $dims, $state->maxZ() + 1 + $adds, $board['id'], $layerId, $state->file);
            } catch (KvLayerPatchException $e) {
                $skips[] = [$surface, $layerId, $e->reason];

                continue;
            }
            if ($intent['kind'] === 'add') {
                $adds++;
            }
            $working[$layerId] = $next;
            $pending[] = [$surface, $layerId, self::opName($intent['kind']), $current, $next];
        }

        return ['pending' => $pending, 'skips' => $skips, 'ops' => self::collabOps($original, $working)];
    }

    /** Size targets: one tile, one transaction, under a row lock. */
    private function writeTile(KvCanvasState $state, string $tileId, array $items, KvCanvasWriteLog $log): void
    {
        $outcome = DB::transaction(function () use ($state, $tileId, $items, $log): array {
            $pending = [];
            $skips = [];
            $detached = null;
            $used = 0;

            $tile = KvResizeExport::query()
                ->whereKey($tileId)
                ->where('studio_file_id', $state->file->id)
                ->lockForUpdate()
                ->first();
            if ($tile === null) {
                foreach ($items as [$intent, $surface]) {
                    $skips[] = [$surface, self::layerIdFor($intent, $surface), 'target_not_found'];
                }

                return ['pending' => $pending, 'skips' => $skips, 'detached' => $detached];
            }

            // null = inherits its board; [] = deliberately emptied — a snapshot, never re-detached.
            $list = is_array($tile->overlays) ? array_values($tile->overlays) : null;

            foreach ($items as [$intent, $surface]) {
                $board = $surface['board'];
                $layerId = self::layerIdFor($intent, $surface);
                $base = $list;
                $detaching = $base === null;
                if ($detaching) {
                    $dims = $state->boardDims($board);
                    if ($dims === null) {
                        $skips[] = [$surface, $layerId, 'target_not_found'];

                        continue;
                    }
                    // Freeze exactly what the browser shows for this size, then edit that.
                    $base = $this->projector->resolve(
                        null,
                        $state->projectOverlays($board),
                        (float) $dims['width'],
                        (float) $dims['height'],
                        (float) $tile->width,
                        (float) $tile->height,
                    );
                }

                $index = self::indexOf($base, $layerId);
                if ($intent['kind'] !== 'add' && $index === null) {
                    $skips[] = [$surface, $layerId, 'layer_absent_on_size'];

                    continue;
                }
                if ($used + ($detaching ? 2 : 1) > $log->budget) {
                    $skips[] = [$surface, $layerId, 'run_op_cap_reached'];

                    continue;
                }
                $current = $index === null ? null : $base[$index];
                try {
                    $next = $this->nextRow(
                        $intent,
                        $current,
                        ['width' => (int) $tile->width, 'height' => (int) $tile->height],
                        self::maxZ($base) + 1,
                        $board['id'],
                        $layerId,
                        $state->file,
                    );
                } catch (KvLayerPatchException $e) {
                    $skips[] = [$surface, $layerId, $e->reason];

                    continue;
                }

                if ($detaching) {
                    $detached = ['surface' => $surface, 'snapshot' => $base];
                    $used++;
                }
                if ($next === null) {
                    array_splice($base, $index, 1);
                } elseif ($index === null) {
                    $base[] = $next;
                } else {
                    $base[$index] = $next;
                }
                $pending[] = [$surface, $layerId, self::opName($intent['kind']), $current, $next, ['index' => $index ?? count($base) - 1]];
                $used++;
                $list = $base;
            }

            if ($pending !== []) {
                $this->tiles->writeOverlays($tile, $list);
            }

            return ['pending' => $pending, 'skips' => $skips, 'detached' => $detached];
        });

        foreach ($outcome['skips'] as [$surface, $layerId, $reason]) {
            $log->skipSurface($surface, $layerId, $reason);
        }
        if ($outcome['detached'] !== null) {
            $log->detach($outcome['detached']['surface'], $outcome['detached']['snapshot']);
        }
        foreach ($outcome['pending'] as [$surface, $layerId, $op, $before, $after, $extra]) {
            $log->apply($surface, $layerId, $op, $before, $after, $extra);
        }
    }

    /**
     * The layer as it will look after this intent (null = removed), validated
     * with the browser PATCH's rules. `$dims`, `$z` and `$boardId` describe a
     * NEW layer and are read by the `add` arm only.
     *
     * @throws KvLayerPatchException
     */
    private function nextRow(array $intent, ?array $current, ?array $dims, int $z, string $boardId, string $layerId, StudioFile $file): ?array
    {
        $next = match ($intent['kind']) {
            'set' => KvLayerPatch::apply((array) $current, $intent['set']),
        };

        $error = $next === null ? null : $this->normalizer->rowError($next, $file);
        if ($error !== null) {
            throw new KvLayerPatchException($error, 'invalid_payload');
        }

        return $next;
    }

    /** @return list<array<string, mixed>> one op per touched layer, from its state as read to its final state */
    private static function collabOps(array $original, array $working): array
    {
        $ops = [];
        foreach ($working as $layerId => $to) {
            $layerId = (string) $layerId;
            $from = $original[$layerId] ?? null;
            if ($from === null && $to === null) {
                continue;
            }
            if ($from === null) {
                $ops[] = ['kind' => 'add_layer', 'layer' => KvLayerShape::toLayer($to)];

                continue;
            }
            if ($to === null) {
                $ops[] = ['kind' => 'remove_layer', 'layer_id' => $layerId, 'expected' => KvLayerDiff::fullExpected($from)];

                continue;
            }
            $set = KvLayerDiff::setLayerOp($layerId, $from, $to);
            if ($set !== null) {
                $ops[] = $set;
            }
        }

        return $ops;
    }

    private static function layerIdFor(array $intent, array $surface): string
    {
        return $intent['kind'] === 'add'
            ? ($intent['board_layer_ids'][$surface['board']['id']] ?? $intent['layer_id'])
            : $intent['layer_id'];
    }

    private static function opName(string $kind): string
    {
        return match ($kind) {
            'set' => 'set_layer',
            'add' => 'add_layer',
            'remove' => 'remove_layer',
        };
    }

    private static function indexOf(array $rows, string $layerId): ?int
    {
        foreach ($rows as $i => $row) {
            if (is_array($row) && ($row['id'] ?? null) === $layerId) {
                return $i;
            }
        }

        return null;
    }

    private static function maxZ(array $rows): int
    {
        $max = -1;
        foreach ($rows as $row) {
            if (is_array($row)) {
                $max = max($max, (int) ($row['z'] ?? 0));
            }
        }

        return $max;
    }
}
```

- [ ] **Step 5: Run the doc tests**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/KvCanvasEditServiceTest.php --compact`
Expected: all PASS.

- [ ] **Step 6: Append the failing tests for size targets and detaching**

Append to `tests/Feature/Studio/AgentCanvas/KvCanvasEditServiceTest.php`:

```php
// --- size targets: kv_resize_exports.overlays ------------------------------

it('with include_sizes writes every detached size of the board, never an inheriting one', function () {
    $logo = K::row(K::imageLayer(K::LOGO, $this->boardA->id, 2));
    $detached = $this->kvTile(['width' => 1080, 'height' => 1080, 'overlays' => [
        K::row(K::textLayer(K::HEADLINE, $this->boardA->id, 'Promo Ramadan', 1)), $logo,
    ]]);
    $inheriting = $this->kvTile();

    $result = $this->kvUpdate([kvSet(K::HEADLINE, ['board_ids' => [$this->boardA->id], 'include_sizes' => true], ['text' => 'Ramadan Sale'])]);

    expect(array_column($result['applied'], 'target'))->toBe([$this->boardA->id, $detached->id])
        ->and($result['detached_sizes'])->toBe([])
        ->and($detached->fresh()->overlays[0]['payload']['content'])->toBe('Ramadan Sale')
        ->and($detached->fresh()->overlays[1])->toEqual($logo)
        ->and($inheriting->fresh()->overlays)->toBeNull();
    $ops = KvAgentRun::findOrFail($this->runId)->ops;
    expect($ops[1])->toMatchArray(['sink' => 'tile', 'target' => $detached->id, 'target_kind' => 'size', 'index' => 0]);
});

it('skips a detached size that does not carry the layer', function () {
    $only = K::row(K::imageLayer(K::LOGO, $this->boardA->id, 2));
    $detached = $this->kvTile(['overlays' => [$only]]);

    $result = $this->kvUpdate([kvSet(K::HEADLINE, ['size_ids' => [$detached->id]], ['text' => 'x'])]);

    expect($result['applied'])->toBe([])
        ->and($result['skipped'])->toBe([['target' => $detached->id, 'layer_id' => K::HEADLINE, 'reason' => 'layer_absent_on_size']])
        ->and($detached->fresh()->overlays)->toEqual([$only]);
});

it('detaches an inheriting size named by id, freezing what the browser shows, and reports it', function () {
    $tile = $this->kvTile();
    $projected = app(KvTileOverlayProjector::class)->resolve(null, [
        K::row(K::textLayer(K::HEADLINE, $this->boardA->id, 'Promo Ramadan', 1)),
        K::row(K::imageLayer(K::LOGO, $this->boardA->id, 2)),
    ], 1080, 1350, 1080, 1920);

    $result = $this->kvUpdate([kvSet(K::HEADLINE, ['size_ids' => [$tile->id]], ['text' => 'Ramadan Sale'])]);

    $stored = $tile->fresh()->overlays;
    expect($result['detached_sizes'])->toBe([$tile->id])
        ->and($result['applied'])->toBe([['target' => $tile->id, 'layer_id' => K::HEADLINE, 'op' => 'set_layer']])
        ->and(array_column($stored, 'id'))->toBe([K::HEADLINE, K::LOGO]) // board B's caption is not board A's
        ->and($stored[0]['payload']['content'])->toBe('Ramadan Sale')
        ->and($stored[0]['y'])->toEqualWithDelta($projected[0]['y'], 1e-9)
        ->and(abs($stored[0]['y'] - 0.4))->toBeGreaterThan(1e-3) // projected, not copied
        ->and($stored[1])->toEqual($projected[1])
        ->and($this->collab->batches)->toBe([]);

    $run = KvAgentRun::findOrFail($this->runId);
    expect(array_column($run->ops, 'type'))->toBe(['detach_size', 'set_layer'])
        ->and(array_column($run->ops[0]['after'], 'id'))->toBe([K::HEADLINE, K::LOGO])
        ->and($run->ops[0]['after'][0]['payload']['content'])->toBe('Promo Ramadan')
        ->and($run->detached_sizes)->toBe([['size_id' => $tile->id, 'label' => 'Concept A · '.$tile->displayLabel()]]);
});

it('never re-detaches a deliberately emptied size', function () {
    $emptied = $this->kvTile(['overlays' => []]);

    $result = $this->kvUpdate([kvSet(K::HEADLINE, ['size_ids' => [$emptied->id]], ['text' => 'x'])]);

    expect($result['skipped'])->toBe([['target' => $emptied->id, 'layer_id' => K::HEADLINE, 'reason' => 'layer_absent_on_size']])
        ->and($result['detached_sizes'])->toBe([])
        ->and($emptied->fresh()->overlays)->toBe([]);
});

it('does not detach a size when the layer would not be on it', function () {
    $tile = $this->kvTile();

    $result = $this->kvUpdate([kvSet(K::CAPTION, ['size_ids' => [$tile->id]], ['text' => 'x'])]);

    expect($result['skipped'][0]['reason'])->toBe('layer_absent_on_size')
        ->and($tile->fresh()->overlays)->toBeNull();
});

it('skips detaching when the board cannot be measured', function () {
    Http::fake(['s3.test/*' => Http::response('', 404)]);
    $this->boardA->update(['metadata' => []]);
    $tile = $this->kvTile();

    $result = $this->kvUpdate([kvSet(K::HEADLINE, ['size_ids' => [$tile->id]], ['text' => 'x'])]);

    expect($result['skipped'][0]['reason'])->toBe('target_not_found')
        ->and($tile->fresh()->overlays)->toBeNull();
});

it('stops at the run op cap and reports the rest', function () {
    KvAgentRun::create([
        'id' => $this->runId, 'studio_file_id' => $this->file->id, 'user_id' => $this->user->id,
        'workspace_id' => $this->workspace->id, 'source' => 'app',
        'ops' => array_fill(0, 199, ['type' => 'set_layer', 'sink' => 'doc', 'target' => 'x', 'layer_id' => 'y']),
    ]);
    $detached = $this->kvTile(['overlays' => [K::row(K::textLayer(K::HEADLINE, $this->boardA->id, 'Promo Ramadan', 1))]]);

    $result = $this->kvUpdate([kvSet(K::HEADLINE, ['board_ids' => [$this->boardA->id], 'include_sizes' => true], ['text' => 'Ramadan Sale'])]);

    expect($result['applied'])->toBe([['target' => $this->boardA->id, 'layer_id' => K::HEADLINE, 'op' => 'set_layer']])
        ->and($result['skipped'])->toBe([['target' => $detached->id, 'layer_id' => K::HEADLINE, 'reason' => 'run_op_cap_reached']])
        ->and(KvAgentRun::findOrFail($this->runId)->ops)->toHaveCount(200);
});

it('moves updated_at on a tile write so the resize feed re-sends the row', function () {
    $detached = $this->kvTile(['overlays' => [K::row(K::textLayer(K::HEADLINE, $this->boardA->id, 'Promo Ramadan', 1))]]);
    KvResizeExport::whereKey($detached->id)->update(['updated_at' => now()->subHour()]);

    $this->kvUpdate([kvSet(K::HEADLINE, ['size_ids' => [$detached->id]], ['text' => 'Ramadan Sale'])]);

    expect($detached->fresh()->updated_at->gt(now()->subMinute()))->toBeTrue();
});
```

- [ ] **Step 7: Run all service tests**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/KvCanvasEditServiceTest.php tests/Feature/Studio/KvResizeExportControllerTest.php --compact`
Expected: all new tests PASS; `KvResizeExportControllerTest` matches the Task 1 baseline. Then prove the detach test bites: in `writeTile` replace `$state->projectOverlays($board)` with `$state->layersOnBoard($board)` and skip the projector call (`$base = $state->layersOnBoard($board);`) — the detach test must FAIL (`y` not projected). Restore.

- [ ] **Step 8: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
vendor/bin/pint --dirty --format agent
git add app/Services/Studio/AgentCanvas/KvCanvasWriteLog.php app/Services/Studio/AgentCanvas/KvCanvasEditService.php app/Services/Studio/KvResizeExportService.php app/Http/Controllers/Api/Studio/KvResizeExportController.php tests/Traits/BuildsKvCanvas.php tests/Feature/Studio/AgentCanvas/KvCanvasEditServiceTest.php
git commit -m "feat(api): KvCanvasEditService routes layer edits to the live doc and to sizes

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: `update_kv_layers` route, validation and MCP twin (C3.4, C3.8)

**Files:**
- Create: `app/Mcp/Tools/UpdateKvLayersTool.php`
- Modify: `app/Http/Controllers/Api/ModelContextProtocol/KvCanvasToolController.php` (add `updateLayers` + helpers), `routes/api.php` (inside the `feature.flag:kv-agentic-canvas,off` group), `app/Mcp/Servers/FrndosServer.php`, `tests/Unit/Mcp/KvCanvasToolsTest.php`
- Test: `tests/Feature/Studio/AgentCanvas/UpdateKvLayersToolTest.php`

**Interfaces:**
- Consumes: `KvCanvasEditService::updateLayers` (Task 11), `KvCanvasState::targetIds` (Task 9), `KvLayerPatch::unknownStyleKeys/TEXT_STYLE_KEYS` (Task 8), `KvLayerShape::isUlid` (Task 3).
- Produces:
  - `KvCanvasToolController::updateLayers(Request, string $fileId, KvCanvasEditService $edits)`; protected helpers `validateInput(Request, array $rules): void` (422 `invalid_input` with `errors`), static `requireTargets(array $targets): void` (422 `targets_required`), static `rejectUnknownStyle(array $style): void` (422 `invalid_style_key` with `keys`), `runIdFrom(Request, ToolContext): ?string` (ToolContext run id, else a ULID-shaped `agent_run_id` input — the MCP gateway builds a ToolContext without one).
  - Route `POST mcp/tools/kv/canvas/{fileId}/layers/update`; MCP twin `update_kv_layers` (`requiresSubscription`).

- [ ] **Step 1: Write the failing test**

`tests/Feature/Studio/AgentCanvas/UpdateKvLayersToolTest.php`:

```php
<?php

use App\Mcp\Support\ToolControllerGateway;
use App\Mcp\Tools\UpdateKvLayersTool;
use App\Models\KvAgentRun;
use App\Models\StudioFile;
use App\Models\SubscriptionHistory;
use App\Models\SubscriptionPlan;
use App\Models\Workspace;
use Illuminate\Support\Str;
use Laravel\Mcp\Request as McpRequest;
use Tests\Support\KvCanvasFixture as K;
use Tests\Traits\BuildsKvCanvas;

uses(BuildsKvCanvas::class);

beforeEach(fn () => $this->setUpKvCanvas());

function kvHttpEdit(string $text = 'Ramadan Sale', ?array $targets = null): array
{
    return ['layer_id' => K::HEADLINE, 'targets' => $targets ?? ['board_ids' => [test()->boardA->id]], 'set' => ['text' => $text]];
}

function kvSubscribe(Workspace $workspace): void
{
    $plan = SubscriptionPlan::create([
        'name' => 'Test Plan', 'slug' => 'test-plan-'.Str::random(6), 'description' => 'Test plan', 'credits' => 1000,
        'max_members' => 10, 'price' => 100000, 'billing_cycle' => 'monthly', 'is_active' => true, 'is_default' => false,
    ]);
    SubscriptionHistory::create([
        'id' => (string) Str::ulid(), 'workspace_id' => $workspace->id, 'subscription_plan_id' => $plan->id,
        'status' => 'active', 'start_date' => now()->subMonth(), 'end_date' => now()->addMonth(),
    ]);
}

it('applies an edit and answers the C3.3 result', function () {
    $this->kvTool('POST', $this->file->id.'/layers/update', ['edits' => [kvHttpEdit()]], $this->runId)
        ->assertOk()
        ->assertJsonPath('data.run_id', $this->runId)
        ->assertJsonPath('data.applied.0', ['target' => $this->boardA->id, 'layer_id' => K::HEADLINE, 'op' => 'set_layer'])
        ->assertJsonPath('data.skipped', [])
        ->assertJsonPath('data.detached_sizes', []);
});

it('refuses a call that names no target, and writes nothing', function () {
    $this->kvTool('POST', $this->file->id.'/layers/update', ['edits' => [kvHttpEdit(targets: ['include_sizes' => true])]], $this->runId)
        ->assertStatus(422)
        ->assertJsonPath('error', 'targets_required');

    expect($this->collab->opsRequestCount())->toBe(0)->and(KvAgentRun::count())->toBe(0);
});

it('refuses style keys outside the whitelist before anything is written', function () {
    $edit = kvHttpEdit();
    $edit['set'] = ['style' => ['fontSize' => 0.07, 'bogusKey' => 1]];

    $this->kvTool('POST', $this->file->id.'/layers/update', ['edits' => [$edit]], $this->runId)
        ->assertStatus(422)
        ->assertJsonPath('error', 'invalid_style_key')
        ->assertJsonPath('keys', ['bogusKey']);

    expect($this->collab->opsRequestCount())->toBe(0)->and(KvAgentRun::count())->toBe(0);
});

it('refuses an edit that changes nothing', function () {
    $edit = kvHttpEdit();
    $edit['set'] = ['unknown' => 1];

    $this->kvTool('POST', $this->file->id.'/layers/update', ['edits' => [$edit]], $this->runId)
        ->assertStatus(422)->assertJsonPath('error', 'invalid_input');
});

it('refuses a call that expands past 60 targets', function () {
    for ($i = 0; $i < 60; $i++) {
        $this->kvTile(['overlays' => [K::row(K::textLayer(K::HEADLINE, $this->boardA->id, 'Promo Ramadan', 1))]]);
    }

    $this->kvTool('POST', $this->file->id.'/layers/update', [
        'edits' => [kvHttpEdit(targets: ['board_ids' => [$this->boardA->id], 'include_sizes' => true])],
    ], $this->runId)->assertStatus(422)->assertJsonPath('error', 'too_many_targets')->assertJsonPath('max', 60);

    expect($this->collab->opsRequestCount())->toBe(0)->and(KvAgentRun::count())->toBe(0);
});

it('answers 409 run_in_progress while another run holds the file', function () {
    $this->kvTool('POST', $this->file->id.'/layers/update', ['edits' => [kvHttpEdit()]], $this->runId)->assertOk();

    $this->kvTool('POST', $this->file->id.'/layers/update', ['edits' => [kvHttpEdit('Other')]], (string) Str::ulid())
        ->assertStatus(409)
        ->assertJsonPath('error', 'run_in_progress')
        ->assertJsonPath('run_id', $this->runId);

    expect($this->collab->opsRequestCount())->toBe(1)
        ->and($this->collab->layer(K::HEADLINE)['payload']['content'])->toBe('Ramadan Sale');
});

it('answers 409 run_undone for a write into an undone run', function () {
    KvAgentRun::create(['id' => $this->runId, 'studio_file_id' => $this->file->id, 'user_id' => $this->user->id,
        'workspace_id' => $this->workspace->id, 'source' => 'app', 'status' => 'undone']);

    $this->kvTool('POST', $this->file->id.'/layers/update', ['edits' => [kvHttpEdit()]], $this->runId)
        ->assertStatus(409)->assertJsonPath('error', 'run_undone');
});

it('404s a KV file of another workspace', function () {
    $other = StudioFile::factory()->create(['workspace_id' => Workspace::factory()->create()->id, 'brand_id' => null, 'tool_id' => $this->file->tool_id]);

    $this->kvTool('POST', $other->id.'/layers/update', ['edits' => [kvHttpEdit()]], $this->runId)->assertNotFound();
});

it('opens a run for an MCP caller that sent none, and groups the next call into it', function () {
    kvSubscribe($this->workspace);
    $this->be($this->user, 'mcp');
    $call = fn (array $args) => json_decode((string) (new UpdateKvLayersTool)->handle(
        new McpRequest(array_merge(['workspace_id' => $this->workspace->id, 'file_id' => $this->file->id], $args)),
        app(ToolControllerGateway::class),
    )->content(), true);

    $first = $call(['edits' => [kvHttpEdit()]]);
    $runId = $first['data']['run_id'];

    expect($runId)->toBeString()->and(strlen($runId))->toBe(26)
        ->and(KvAgentRun::findOrFail($runId)->source)->toBe('mcp');

    $second = $call(['edits' => [kvHttpEdit('Second')], 'agent_run_id' => $runId]);

    expect($second['data']['run_id'])->toBe($runId)
        ->and(KvAgentRun::count())->toBe(1)
        ->and(KvAgentRun::findOrFail($runId)->ops)->toHaveCount(2)
        ->and($this->collab->layer(K::HEADLINE)['payload']['content'])->toBe('Second');
});
```

Append to `tests/Unit/Mcp/KvCanvasToolsTest.php` (import `App\Mcp\Tools\UpdateKvLayersTool`):

```php
it('registers update_kv_layers as the twin of KvCanvasToolController@updateLayers', function () {
    expect((new ReflectionClass(FrndosServer::class))->getDefaultProperties()['tools'])->toContain(UpdateKvLayersTool::class)
        ->and(UpdateKvLayersTool::METHOD)->toBe('updateLayers')
        ->and((new UpdateKvLayersTool)->toArray()['name'])->toBe('update_kv_layers')
        ->and(kvTwinSchema(new UpdateKvLayersTool)['required'])->toBe(['workspace_id', 'file_id', 'edits'])
        ->and(kvTwinSchema(new UpdateKvLayersTool)['properties'])->toHaveKey('agent_run_id');
});
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/UpdateKvLayersToolTest.php tests/Unit/Mcp/KvCanvasToolsTest.php --compact`
Expected: FAIL — route 404 / twin class not found.

- [ ] **Step 3: Add the controller method and helpers**

In `KvCanvasToolController` add imports `App\Exceptions\Studio\KvCanvasToolException` (already there), `App\Services\Studio\AgentCanvas\KvCanvasEditService`, `App\Services\Studio\AgentCanvas\KvCanvasState`, `App\Services\Studio\AgentCanvas\KvLayerPatch`, `App\Services\Studio\AgentCanvas\KvLayerShape`, `Illuminate\Support\Facades\Validator`, and these methods:

```php
    /**
     * update_kv_layers (C3.4). Shape is validated here; `style` and `set`
     * are then read from input() — never validated(), whose key exclusion
     * would strip every style key not listed as a sub-rule.
     */
    public function updateLayers(Request $request, string $fileId, KvCanvasEditService $edits): JsonResponse
    {
        return $this->withFile($request, $fileId, function (StudioFile $file, ToolContext $ctx) use ($request, $edits): array {
            $this->validateInput($request, [
                'edits' => ['required', 'array', 'min:1', 'max:'.KvCanvasEditService::MAX_TARGETS],
                'edits.*' => ['array'],
                'edits.*.layer_id' => ['required', 'string', 'max:64'],
                'edits.*.targets' => ['required', 'array'],
                'edits.*.set' => ['required', 'array'],
                'edits.*.set.text' => ['sometimes', 'nullable', 'string'],
                'edits.*.set.style' => ['sometimes', 'array'],
                'edits.*.set.rect' => ['sometimes', 'array'],
                'edits.*.set.rect.x' => ['sometimes', 'numeric'],
                'edits.*.set.rect.y' => ['sometimes', 'numeric'],
                'edits.*.set.rect.w' => ['sometimes', 'numeric'],
                'edits.*.set.rect.h' => ['sometimes', 'numeric'],
                'edits.*.set.rect.rotation' => ['sometimes', 'numeric'],
                'edits.*.set.visible' => ['sometimes', 'boolean'],
                'edits.*.set.z' => ['sometimes', 'integer'],
            ]);

            $list = array_values((array) $request->input('edits'));
            foreach ($list as $i => $edit) {
                self::requireTargets((array) $edit['targets']);
                $set = (array) $edit['set'];
                if (array_intersect_key($set, array_flip(['text', 'style', 'rect', 'visible', 'z'])) === []) {
                    throw KvCanvasToolException::unprocessable('invalid_input', "edits.{$i}.set names nothing to change (text, style, rect, visible or z).");
                }
                self::rejectUnknownStyle((array) ($set['style'] ?? []));
            }

            return $edits->updateLayers($file, $ctx, $this->runIdFrom($request, $ctx), $list);
        });
    }

    protected function validateInput(Request $request, array $rules): void
    {
        $validator = Validator::make($request->all(), $rules);
        if ($validator->fails()) {
            throw KvCanvasToolException::unprocessable('invalid_input', (string) $validator->errors()->first(), ['errors' => $validator->errors()->toArray()]);
        }
    }

    /** Contract C3.1: targets are always explicit — there is no implicit "everything". */
    protected static function requireTargets(array $targets): void
    {
        foreach (['board_ids', 'size_ids'] as $key) {
            if (isset($targets[$key]) && ! is_array($targets[$key])) {
                throw KvCanvasToolException::unprocessable('invalid_input', "targets.{$key} must be a list of ids.");
            }
        }
        if (KvCanvasState::targetIds($targets) === []) {
            throw KvCanvasToolException::unprocessable('targets_required', 'targets must name at least one board_id or size_id; there is no implicit "everything".');
        }
    }

    protected static function rejectUnknownStyle(array $style): void
    {
        $unknown = KvLayerPatch::unknownStyleKeys($style);
        if ($unknown !== []) {
            throw KvCanvasToolException::unprocessable(
                'invalid_style_key',
                'style may only set '.implode(', ', KvLayerPatch::TEXT_STYLE_KEYS).'; not '.implode(', ', $unknown).'.',
                ['keys' => $unknown],
            );
        }
    }

    /** The chat turn's run id (internal token), else the one an MCP client passed back. */
    protected function runIdFrom(Request $request, ToolContext $ctx): ?string
    {
        if ($ctx->agentRunId !== null) {
            return $ctx->agentRunId;
        }
        $raw = $request->input('agent_run_id');

        return KvLayerShape::isUlid($raw) ? $raw : null;
    }
```

Inside the route group add: `Route::post('kv/canvas/{fileId}/layers/update', [KvCanvasToolController::class, 'updateLayers']);`

- [ ] **Step 4: Add the MCP twin**

`app/Mcp/Tools/UpdateKvLayersTool.php`:

```php
<?php

namespace App\Mcp\Tools;

use App\Http\Controllers\Api\ModelContextProtocol\KvCanvasToolController;
use Illuminate\Contracts\JsonSchema\JsonSchema;

/** Change existing layers across the boards and sizes named — applied at once, undoable as a run. */
class UpdateKvLayersTool extends FrndosTool
{
    public const CONTROLLER = KvCanvasToolController::class;

    public const METHOD = 'updateLayers';

    protected string $name = 'update_kv_layers';

    protected string $description = 'Change existing layers on a Key Visual canvas — text, style, position/size, visibility, stacking — on exactly the boards and sizes you name. Applies at once. Returns run_id (pass it back as agent_run_id to group later changes into one undoable run), applied, skipped (one reason per target: layer_changed, layer_not_found, layer_absent_on_size, target_not_found, collab_unavailable, invalid_payload, run_op_cap_reached) and detached_sizes (sizes that now keep their own layers because you named them directly).';

    protected bool $requiresSubscription = true;

    protected array $routeParamMap = ['file_id' => 'fileId'];

    public function schema(JsonSchema $schema): array
    {
        return [
            'workspace_id' => $this->workspaceIdSchema($schema),
            'file_id' => $schema->string()->description('KV file id (from list_kv_files).')->required(),
            'edits' => $schema->array()->items($schema->object())->description('1–60 edits, each {layer_id, targets: {board_ids?: [...], size_ids?: [...], include_sizes?: bool}, set: {text?, style?, rect?: {x?, y?, w?, h?, rotation?}, visible?, z?}}. Ids come from get_kv_canvas. A board target changes that board (sizes that inherit follow by themselves); include_sizes also changes the board\'s detached sizes; a size id changes only that size, detaching it first if it inherited. style keys: color, fontFamily, fontSize, fontWeight, fontStyle, textAlign, lineHeight, letterSpacing, paragraphSpacing, textTransform, gradient, opacity, blendMode (any other key is refused). rect values are fractions of the surface. text replaces the whole string; mixed per-word styling collapses to the first style. At most 60 targets per call after expansion.')->required(),
            'agent_run_id' => $schema->string()->description('Optional: a run_id returned by an earlier canvas write, to group this change into the same undoable run. Omit to start a new run.'),
        ];
    }
}
```

Register `Tools\UpdateKvLayersTool::class,` after `Tools\GetKvCanvasTool::class,` in `FrndosServer`.

- [ ] **Step 5: Run the tests and the mirror**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/UpdateKvLayersToolTest.php tests/Unit/Mcp/KvCanvasToolsTest.php --compact && php artisan mcp:verify-mirror`
Expected: all PASS; `Mirror OK`.

- [ ] **Step 6: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
vendor/bin/pint --dirty --format agent
git add app/Http/Controllers/Api/ModelContextProtocol/KvCanvasToolController.php app/Mcp/Tools/UpdateKvLayersTool.php app/Mcp/Servers/FrndosServer.php routes/api.php tests/Feature/Studio/AgentCanvas/UpdateKvLayersToolTest.php tests/Unit/Mcp/KvCanvasToolsTest.php
git commit -m "feat(api): update_kv_layers tool + MCP twin (C3.4, C3.8)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 13: `add_kv_layer` (C3.5) — asset resolution, placement, route and twin

**Files:**
- Create: `app/Services/Studio/AgentCanvas/KvLayerAssetResolver.php`, `app/Mcp/Tools/AddKvLayerTool.php`
- Modify: `app/Services/Studio/AgentCanvas/KvCanvasEditService.php` (`addLayer`, `assertNewLayerValid`, `newRow`, the `add` arm of `nextRow`, per-board ids in `execute`), `KvCanvasToolController.php` (`addLayer`), `routes/api.php`, `FrndosServer.php`, `tests/Unit/Mcp/KvCanvasToolsTest.php`
- Test: `tests/Feature/Studio/AgentCanvas/AddKvLayerToolTest.php`

**Interfaces:**
- Consumes: `KvLayerPlacement` (Task 8), `KvImageDimensions::forUrl` (Task 6), `StudioOverlayNormalizer::normalizeRow` (Task 2), `BrandLogoAssetBuilder::tryBuild`, `DeckAssetHost::isOurs`, `TrustedAssetHost::allows`.
- Produces:
  - `KvLayerAssetResolver::resolve(StudioFile $file, array $image): array{asset_url, mime_type, width, height}` — `brand_logo` copies the brand's logo bytes to `studio/{file}/overlays/{ulid}.{ext}` on the s3 disk (where a manual upload lands); `asset_url` must be on our own bucket (`DeckAssetHost::isOurs` and `TrustedAssetHost::allows`) and a readable PNG/JPEG/WebP. Throws 422 `no_brand_logo`, `untrusted_asset_url`, `invalid_input`.
  - `KvCanvasEditService::addLayer(StudioFile $file, ToolContext $ctx, ?string $runId, array $targets, array $layer, array $placement, ?array $asset): array` (C3.3); `assertNewLayerValid(StudioFile $file, array $layer, array $placement, ?array $asset): void` (422 `invalid_payload`).
  - Route `POST mcp/tools/kv/canvas/{fileId}/layers/add`; twin `add_kv_layer`.

- [ ] **Step 1: Write the failing test**

`tests/Feature/Studio/AgentCanvas/AddKvLayerToolTest.php`:

```php
<?php

use App\Exceptions\Studio\KvCanvasToolException;
use App\Models\Brand;
use App\Services\Studio\AgentCanvas\KvCanvasEditService;
use App\Services\Studio\AgentCanvas\KvLayerAssetResolver;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Storage;
use Tests\Support\KvCanvasFixture as K;
use Tests\Traits\BuildsKvCanvas;

uses(BuildsKvCanvas::class);

beforeEach(fn () => $this->setUpKvCanvas());

function kvAddPng(int $w, int $h): string
{
    $image = imagecreatetruecolor($w, $h);
    ob_start();
    imagepng($image);

    return (string) ob_get_clean();
}

function kvAddedLayer(string $id): ?array
{
    return collect(test()->collab->document['overlays'])->firstWhere('id', $id);
}

it('adds a text layer to a board and its detached sizes under one id', function () {
    $detached = $this->kvTile(['overlays' => [K::row(K::textLayer(K::HEADLINE, $this->boardA->id, 'Promo Ramadan', 1))]]);

    $data = $this->kvTool('POST', $this->file->id.'/layers/add', [
        'targets' => ['board_ids' => [$this->boardA->id], 'include_sizes' => true],
        'layer' => ['type' => 'text', 'text' => 'Eid Mubarak', 'style' => ['color' => '#FFD700']],
        'placement' => ['anchor' => 'top_left', 'margin' => 0.04, 'width' => 0.5],
    ], $this->runId)->assertOk()->json('data');

    $id = $data['applied'][0]['layer_id'];
    expect(strlen($id))->toBe(26)
        ->and($data['applied'])->toBe([
            ['target' => $this->boardA->id, 'layer_id' => $id, 'op' => 'add_layer'],
            ['target' => $detached->id, 'layer_id' => $id, 'op' => 'add_layer'],
        ])
        ->and($this->collab->batches[0]['ops'][0]['kind'])->toBe('add_layer');

    // Board A is 1080×1350: margin 0.04·1080 = 43.2 px; one text line = 0.05·1.2 of the height.
    $doc = kvAddedLayer($id);
    expect($doc['rect'])->toEqualWithDelta(['x' => 43.2 / 1080, 'y' => 43.2 / 1350, 'width' => 0.5, 'height' => 0.06, 'rotation' => 0.0], 1e-9)
        ->and($doc['z'])->toBe(4) // above the doc's highest z (3)
        ->and($doc['board_generation_id'])->toBe($this->boardA->id)
        ->and($doc['payload'])->toMatchArray(['type' => 'text', 'content' => 'Eid Mubarak', 'color' => '#FFD700', 'fontSize' => 0.05]);

    // The size is 1080×1920: same pixel margin, re-expressed for that frame.
    $tileRow = collect($detached->fresh()->overlays)->firstWhere('id', $id);
    expect([$tileRow['x'], $tileRow['y'], $tileRow['z']])->toEqualWithDelta([43.2 / 1080, 43.2 / 1920, 2], 1e-9);
});

it('gives each additional board its own layer id, because a doc id cannot repeat', function () {
    $data = $this->kvTool('POST', $this->file->id.'/layers/add', [
        'targets' => ['board_ids' => [$this->boardA->id, $this->boardB->id]],
        'layer' => ['type' => 'shape', 'shape' => ['kind' => 'ellipse', 'color' => '#112233']],
        'placement' => ['anchor' => 'center', 'margin' => 0, 'width' => 0.2],
    ], $this->runId)->assertOk()->json('data');

    [$a, $b] = $data['applied'];
    expect($a['layer_id'])->not->toBe($b['layer_id'])
        ->and(kvAddedLayer($a['layer_id'])['board_generation_id'])->toBe($this->boardA->id)
        ->and(kvAddedLayer($b['layer_id'])['board_generation_id'])->toBe($this->boardB->id);
});

it('copies the brand logo onto the file and sizes the layer from its aspect', function () {
    Storage::fake('s3', ['url' => 'https://s3.test/frnd']);
    Storage::disk('s3')->put('brands/logo.png', kvAddPng(40, 20));
    $brand = Brand::factory()->create(['workspace_id' => $this->workspace->id]);
    DB::table('brands')->where('id', $brand->id)->update(['logo' => 'brands/logo.png']);
    $this->file->forceFill(['brand_id' => $brand->id])->save();

    $asset = app(KvLayerAssetResolver::class)->resolve($this->file, ['source' => 'brand_logo']);

    expect($asset)->toMatchArray(['mime_type' => 'image/png', 'width' => 40, 'height' => 20])
        ->and($asset['asset_url'])->toStartWith('https://s3.test/frnd/studio/'.$this->file->id.'/overlays/');
    Storage::disk('s3')->assertExists(str_replace('https://s3.test/frnd/', '', $asset['asset_url']));

    $result = app(KvCanvasEditService::class)->addLayer($this->file->fresh(), $this->kvCtx($this->runId), $this->runId,
        ['board_ids' => [$this->boardA->id]], ['type' => 'image', 'image' => ['source' => 'brand_logo']],
        ['anchor' => 'bottom_right', 'margin' => 0.04, 'width' => 0.2], $asset);

    // 0.2·1080 = 216 px wide at 2:1 → 108 px tall on a 1350 px board.
    $doc = kvAddedLayer($result['applied'][0]['layer_id']);
    expect($doc['rect']['height'])->toEqualWithDelta(108 / 1350, 1e-9)
        ->and($doc['rect']['y'])->toEqualWithDelta(1 - 108 / 1350 - 43.2 / 1350, 1e-9)
        ->and($doc['payload'])->toMatchArray(['type' => 'image', 'asset_url' => $asset['asset_url'], 'mime_type' => 'image/png']);
});

it('refuses a brand without a logo and a url outside our bucket', function (array $image, string $code) {
    Storage::fake('s3', ['url' => 'https://s3.test/frnd']);
    try {
        app(KvLayerAssetResolver::class)->resolve($this->file, $image);
        $this->fail('expected a refusal');
    } catch (KvCanvasToolException $e) {
        expect($e->status)->toBe(422)->and($e->errorCode)->toBe($code);
    }
})->with([
    'no brand logo' => [['source' => 'brand_logo'], 'no_brand_logo'],
    'foreign url' => [['source' => 'asset_url', 'url' => 'https://evil.test/x.png'], 'untrusted_asset_url'],
]);

it('refuses an invalid new layer before anything is written', function () {
    $this->kvTool('POST', $this->file->id.'/layers/add', [
        'targets' => ['board_ids' => [$this->boardA->id]],
        'layer' => ['type' => 'shape', 'shape' => ['kind' => 'blob']],
        'placement' => ['anchor' => 'center', 'margin' => 0, 'width' => 0.2],
    ], $this->runId)->assertStatus(422)->assertJsonPath('error', 'invalid_payload');

    expect($this->collab->opsRequestCount())->toBe(0);
});

it('refuses an unknown anchor', function () {
    $this->kvTool('POST', $this->file->id.'/layers/add', [
        'targets' => ['board_ids' => [$this->boardA->id]],
        'layer' => ['type' => 'text', 'text' => 'x'],
        'placement' => ['anchor' => 'somewhere', 'margin' => 0, 'width' => 0.2],
    ], $this->runId)->assertStatus(422)->assertJsonPath('error', 'invalid_input');
});
```

Append to `tests/Unit/Mcp/KvCanvasToolsTest.php` (import `App\Mcp\Tools\AddKvLayerTool`):

```php
it('registers add_kv_layer as the twin of KvCanvasToolController@addLayer', function () {
    expect((new ReflectionClass(FrndosServer::class))->getDefaultProperties()['tools'])->toContain(AddKvLayerTool::class)
        ->and(AddKvLayerTool::METHOD)->toBe('addLayer')
        ->and((new AddKvLayerTool)->toArray()['name'])->toBe('add_kv_layer')
        ->and(kvTwinSchema(new AddKvLayerTool)['required'])->toBe(['workspace_id', 'file_id', 'targets', 'layer', 'placement']);
});
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/AddKvLayerToolTest.php tests/Unit/Mcp/KvCanvasToolsTest.php --compact`
Expected: FAIL — classes/route missing.

- [ ] **Step 3: Write the asset resolver**

`app/Services/Studio/AgentCanvas/KvLayerAssetResolver.php`:

```php
<?php

namespace App\Services\Studio\AgentCanvas;

use App\Exceptions\Studio\KvCanvasToolException;
use App\Models\Brand;
use App\Models\StudioFile;
use App\Services\Brand\BrandLogoAssetBuilder;
use App\Services\Deck\DeckAssetHost;
use App\Support\Studio\KvImageDimensions;
use App\Support\Studio\TrustedAssetHost;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;

/** The image behind an `add_kv_layer` image layer (C3.5): the brand logo, or an asset already in our bucket. */
final class KvLayerAssetResolver
{
    private const EXTENSIONS = ['image/png' => 'png', 'image/jpeg' => 'jpg', 'image/webp' => 'webp'];

    public function __construct(private readonly KvImageDimensions $dimensions) {}

    /**
     * @return array{asset_url: string, mime_type: string, width: int, height: int}
     *
     * @throws KvCanvasToolException
     */
    public function resolve(StudioFile $file, array $image): array
    {
        return match ((string) ($image['source'] ?? '')) {
            'brand_logo' => $this->brandLogo($file),
            'asset_url' => $this->assetUrl((string) ($image['url'] ?? '')),
            default => throw KvCanvasToolException::unprocessable('invalid_input', 'layer.image.source must be brand_logo or asset_url.'),
        };
    }

    private function brandLogo(StudioFile $file): array
    {
        $brand = $file->brand_id !== null ? Brand::withoutGlobalScope('workspace')->find($file->brand_id) : null;
        $asset = $brand !== null ? BrandLogoAssetBuilder::tryBuild($brand) : null;
        $bytes = $asset !== null ? base64_decode($asset['data_base64'], true) : false;
        $size = is_string($bytes) ? @getimagesizefromstring($bytes) : false;
        if ($asset === null || ! is_array($size) || ! isset(self::EXTENSIONS[$asset['mime_type']])) {
            throw KvCanvasToolException::unprocessable('no_brand_logo', "This file's brand has no usable logo (PNG, JPEG or WebP).");
        }

        // Copied onto the file's own overlay path — where a manual upload
        // lands (StudioOverlayAssetController) — so the layer never depends on
        // the brand's logo object staying where it is.
        $path = "studio/{$file->id}/overlays/".Str::ulid().'.'.self::EXTENSIONS[$asset['mime_type']];
        Storage::disk('s3')->put($path, $bytes);

        return ['asset_url' => Storage::disk('s3')->url($path), 'mime_type' => $asset['mime_type'], 'width' => (int) $size[0], 'height' => (int) $size[1]];
    }

    private function assetUrl(string $url): array
    {
        // Only our own bucket: the size probe below FETCHES the url, so any
        // other host would be an SSRF surface.
        if (! DeckAssetHost::isOurs($url) || ! TrustedAssetHost::allows($url)) {
            throw KvCanvasToolException::unprocessable('untrusted_asset_url', 'asset_url must be an image already uploaded to frndOS storage.');
        }
        $probe = $this->dimensions->forUrl($url);
        if ($probe === null || ! isset(self::EXTENSIONS[$probe['mime']])) {
            throw KvCanvasToolException::unprocessable('untrusted_asset_url', 'asset_url is not a readable PNG, JPEG or WebP image.');
        }

        return ['asset_url' => $url, 'mime_type' => $probe['mime'], 'width' => $probe['width'], 'height' => $probe['height']];
    }
}
```

- [ ] **Step 4: Teach the edit service to add**

In `KvCanvasEditService` add imports `Illuminate\Support\Str`, `Illuminate\Validation\ValidationException`, then:

1. Public entry points (after `updateLayers`):

```php
    /**
     * add_kv_layer (C3.5). One new id shared by every SIZE target, so later
     * edits address it as one layer across sizes. A Y.Doc layer id cannot
     * repeat, so each board beyond the first gets its own id (reported per
     * `applied` entry; sizes use their own board's id).
     *
     * @param  array{asset_url: string, mime_type: string, width: int, height: int}|null  $asset
     */
    public function addLayer(StudioFile $file, ToolContext $ctx, ?string $runId, array $targets, array $layer, array $placement, ?array $asset): array
    {
        return $this->execute($file, $ctx, $runId, [[
            'kind' => 'add',
            'layer_id' => (string) Str::ulid(),
            'targets' => $targets,
            'layer' => $layer,
            'placement' => $placement,
            'asset' => $asset,
        ]]);
    }

    /**
     * Validate the new layer once, on a neutral 1000×1000 surface, so a bad
     * spec is refused for the whole call instead of skipped per target.
     *
     * @throws KvCanvasToolException 422 invalid_payload
     */
    public function assertNewLayerValid(StudioFile $file, array $layer, array $placement, ?array $asset): void
    {
        $probe = ['kind' => 'add', 'layer_id' => (string) Str::ulid(), 'layer' => $layer, 'placement' => $placement, 'asset' => $asset];
        try {
            $this->normalizer->normalizeRow($this->newRow($probe, ['width' => 1000, 'height' => 1000], 0, null, $probe['layer_id']), $file);
        } catch (ValidationException $e) {
            throw KvCanvasToolException::unprocessable('invalid_payload', (string) collect($e->errors())->flatten()->first());
        } catch (KvLayerPatchException $e) {
            throw KvCanvasToolException::unprocessable('invalid_payload', $e->getMessage());
        }
    }
```

2. In `execute()`, inside the `foreach ($intents as $i => $intent)` expansion loop, after `$intents[$i]['resolved'] = …`, add:

```php
            if ($intent['kind'] === 'add') {
                $ids = [];
                foreach ($intents[$i]['resolved']['surfaces'] as $surface) {
                    if ($surface['kind'] === 'board') {
                        $ids[$surface['id']] = $ids === [] ? $intent['layer_id'] : (string) Str::ulid();
                    }
                }
                $intents[$i]['board_layer_ids'] = $ids;
            }
```

3. Replace `nextRow()` with:

```php
    /**
     * The layer as it will look after this intent (null = removed), validated
     * with the browser PATCH's rules. A new layer is normalised (unknown keys
     * dropped); an existing one is only validated, so web-only payload keys
     * the api does not know yet survive an agent edit.
     *
     * @throws KvLayerPatchException
     */
    private function nextRow(array $intent, ?array $current, ?array $dims, int $z, string $boardId, string $layerId, StudioFile $file): ?array
    {
        if ($intent['kind'] === 'add') {
            try {
                return $this->normalizer->normalizeRow($this->newRow($intent, $dims, $z, $boardId, $layerId), $file);
            } catch (ValidationException $e) {
                throw new KvLayerPatchException((string) collect($e->errors())->flatten()->first(), 'invalid_payload');
            }
        }

        $next = match ($intent['kind']) {
            'set' => KvLayerPatch::apply((array) $current, $intent['set']),
        };

        $error = $next === null ? null : $this->normalizer->rowError($next, $file);
        if ($error !== null) {
            throw new KvLayerPatchException($error, 'invalid_payload');
        }

        return $next;
    }

    /** @throws KvLayerPatchException when the surface has no known size */
    private function newRow(array $intent, ?array $dims, int $z, ?string $boardId, string $layerId): array
    {
        if ($dims === null || $dims['width'] <= 0 || $dims['height'] <= 0) {
            throw new KvLayerPatchException('The size of this surface is unknown, so the layer cannot be placed.', 'target_not_found');
        }
        $spec = $intent['layer'];
        $type = (string) ($spec['type'] ?? '');
        $style = array_filter(is_array($spec['style'] ?? null) ? $spec['style'] : [], static fn ($v) => $v !== null);
        $asset = $intent['asset'] ?? null;

        $payload = match ($type) {
            'text' => array_merge(
                ['type' => 'text', 'content' => (string) ($spec['text'] ?? ''), 'color' => '#000000', 'fontSize' => KvLayerPlacement::DEFAULT_FONT_SIZE],
                $style,
            ),
            'image' => array_merge(
                ['type' => 'image', 'asset_url' => (string) ($asset['asset_url'] ?? ''), 'mime_type' => (string) ($asset['mime_type'] ?? '')],
                array_intersect_key($style, array_flip(['opacity', 'blendMode'])),
            ),
            'shape' => array_merge(['kind' => 'rectangle', 'color' => '#000000'], is_array($spec['shape'] ?? null) ? $spec['shape'] : [], ['type' => 'shape']),
            default => throw new KvLayerPatchException("Unknown layer type {$type}."),
        };

        $textHeight = $type === 'text'
            ? (float) $payload['fontSize'] * (float) ($payload['lineHeight'] ?? KvLayerPlacement::DEFAULT_LINE_HEIGHT)
            : null;
        $aspect = $type === 'image' && $asset !== null ? $asset['width'] / max(1, $asset['height']) : null;
        $rect = KvLayerPlacement::rect($intent['placement'], (int) $dims['width'], (int) $dims['height'], $aspect, $textHeight);

        return ['id' => $layerId, 'type' => $type] + $rect + [
            'rotation' => 0.0,
            'z' => $z,
            'payload' => $payload,
            'board_generation_id' => $boardId,
        ];
    }
```

- [ ] **Step 5: Controller method, route and twin**

In `KvCanvasToolController` (imports `App\Services\Studio\AgentCanvas\KvLayerAssetResolver`, `App\Services\Studio\AgentCanvas\KvLayerPlacement`, `Illuminate\Validation\Rule`):

```php
    /** add_kv_layer (C3.5). */
    public function addLayer(Request $request, string $fileId, KvCanvasEditService $edits, KvLayerAssetResolver $assets): JsonResponse
    {
        return $this->withFile($request, $fileId, function (StudioFile $file, ToolContext $ctx) use ($request, $edits, $assets): array {
            $this->validateInput($request, [
                'targets' => ['required', 'array'],
                'layer' => ['required', 'array'],
                'layer.type' => ['required', Rule::in(['text', 'image', 'shape'])],
                'layer.text' => ['required_if:layer.type,text', 'string', 'max:500'],
                'layer.style' => ['sometimes', 'array'],
                'layer.image' => ['required_if:layer.type,image', 'array'],
                'layer.image.source' => ['required_if:layer.type,image', Rule::in(['brand_logo', 'asset_url'])],
                'layer.image.url' => ['required_if:layer.image.source,asset_url', 'string'],
                'layer.shape' => ['sometimes', 'array'],
                'placement' => ['required', 'array'],
                'placement.anchor' => ['required', Rule::in(KvLayerPlacement::ANCHORS)],
                'placement.margin' => ['required', 'numeric', 'between:0,0.5'],
                'placement.width' => ['required', 'numeric', 'gt:0', 'lte:1'],
            ]);
            $targets = (array) $request->input('targets');
            self::requireTargets($targets);
            $layer = (array) $request->input('layer');
            self::rejectUnknownStyle((array) ($layer['style'] ?? []));
            $placement = (array) $request->input('placement');

            $asset = ($layer['type'] ?? null) === 'image' ? $assets->resolve($file, (array) $layer['image']) : null;
            $edits->assertNewLayerValid($file, $layer, $placement, $asset);

            return $edits->addLayer($file, $ctx, $this->runIdFrom($request, $ctx), $targets, $layer, $placement, $asset);
        });
    }
```

Route (inside the flag group): `Route::post('kv/canvas/{fileId}/layers/add', [KvCanvasToolController::class, 'addLayer']);`

`app/Mcp/Tools/AddKvLayerTool.php`:

```php
<?php

namespace App\Mcp\Tools;

use App\Http\Controllers\Api\ModelContextProtocol\KvCanvasToolController;
use Illuminate\Contracts\JsonSchema\JsonSchema;

/** Add one new layer (text, image or shape) to the boards and sizes named. */
class AddKvLayerTool extends FrndosTool
{
    public const CONTROLLER = KvCanvasToolController::class;

    public const METHOD = 'addLayer';

    protected string $name = 'add_kv_layer';

    protected string $description = 'Add a new layer — text, an image (the brand logo or an image already in frndOS storage) or a shape — to the boards and sizes you name, placed by anchor on each. Applies at once. Sizes share one layer id; each extra board gets its own id (see applied[].layer_id). Returns run_id, applied, skipped, detached_sizes like update_kv_layers.';

    protected bool $requiresSubscription = true;

    protected array $routeParamMap = ['file_id' => 'fileId'];

    public function schema(JsonSchema $schema): array
    {
        return [
            'workspace_id' => $this->workspaceIdSchema($schema),
            'file_id' => $schema->string()->description('KV file id (from list_kv_files).')->required(),
            'targets' => $schema->object()->description('{board_ids?: [...], size_ids?: [...], include_sizes?: bool} — ids from get_kv_canvas; at least one id. include_sizes also adds to each board\'s detached sizes; a size id detaches that size first if it inherited.')->required(),
            'layer' => $schema->object()->description('{type: "text"|"image"|"shape", text? (text, ≤500 chars), style? (same keys as update_kv_layers), image?: {source: "brand_logo"|"asset_url", url?}, shape?: {kind: rectangle|ellipse|triangle|polygon|line|arrow|star|diamond|chevron, color: "#RRGGBB", …}}.')->required(),
            'placement' => $schema->object()->description('{anchor: top_left|top_center|top_right|middle_left|center|middle_right|bottom_left|bottom_center|bottom_right, margin: fraction of the surface\'s shorter side (0–0.5), width: fraction of the surface width (0–1]}. Height follows the image\'s aspect, one line of text, or a square for a shape.')->required(),
            'agent_run_id' => $schema->string()->description('Optional: a run_id from an earlier canvas write, to group this into the same undoable run.'),
        ];
    }
}
```

Register `Tools\AddKvLayerTool::class,` after `Tools\UpdateKvLayersTool::class,`.

- [ ] **Step 6: Run the tests and the mirror**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/AddKvLayerToolTest.php tests/Feature/Studio/AgentCanvas/KvCanvasEditServiceTest.php tests/Unit/Mcp/KvCanvasToolsTest.php --compact && php artisan mcp:verify-mirror`
Expected: all PASS; `Mirror OK`. If a placement number differs, recompute from `KvLayerPlacement::rect` by hand first.

- [ ] **Step 7: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
vendor/bin/pint --dirty --format agent
git add app/Services/Studio/AgentCanvas/KvLayerAssetResolver.php app/Services/Studio/AgentCanvas/KvCanvasEditService.php app/Http/Controllers/Api/ModelContextProtocol/KvCanvasToolController.php app/Mcp/Tools/AddKvLayerTool.php app/Mcp/Servers/FrndosServer.php routes/api.php tests/Feature/Studio/AgentCanvas/AddKvLayerToolTest.php tests/Unit/Mcp/KvCanvasToolsTest.php
git commit -m "feat(api): add_kv_layer tool + MCP twin (C3.5)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: `remove_kv_layers` (C3.6)

**Files:**
- Create: `app/Mcp/Tools/RemoveKvLayersTool.php`
- Modify: `KvCanvasEditService.php` (`removeLayers`, `remove` arm of `nextRow`), `KvCanvasToolController.php` (`removeLayers`), `routes/api.php`, `FrndosServer.php`, `tests/Unit/Mcp/KvCanvasToolsTest.php`
- Test: `tests/Feature/Studio/AgentCanvas/RemoveKvLayersToolTest.php`

**Interfaces:**
- Consumes: the engine from Task 11.
- Produces: `KvCanvasEditService::removeLayers(StudioFile $file, ToolContext $ctx, ?string $runId, array $layerIds, array $targets): array` (C3.3); route `POST mcp/tools/kv/canvas/{fileId}/layers/remove`; twin `remove_kv_layers`.

- [ ] **Step 1: Write the failing test**

`tests/Feature/Studio/AgentCanvas/RemoveKvLayersToolTest.php`:

```php
<?php

use App\Models\KvAgentRun;
use Tests\Support\KvCanvasFixture as K;
use Tests\Traits\BuildsKvCanvas;

uses(BuildsKvCanvas::class);

beforeEach(fn () => $this->setUpKvCanvas());

it('removes board layers in one batch with a whole-layer CAS each', function () {
    $this->kvTool('POST', $this->file->id.'/layers/remove', [
        'layer_ids' => [K::HEADLINE, K::LOGO],
        'targets' => ['board_ids' => [$this->boardA->id]],
    ], $this->runId)->assertOk()->assertJsonPath('data.applied.1', ['target' => $this->boardA->id, 'layer_id' => K::LOGO, 'op' => 'remove_layer']);

    expect($this->collab->batches)->toHaveCount(1)
        ->and($this->collab->batches[0]['ops'][0])->toEqual([
            'kind' => 'remove_layer', 'layer_id' => K::HEADLINE,
            'expected' => [
                'rect' => ['x' => 0.1, 'y' => 0.4, 'width' => 0.6, 'height' => 0.1, 'rotation' => 0],
                'z' => 1,
                'payload' => ['type' => 'text', 'content' => 'Promo Ramadan', 'color' => '#FFFFFF', 'fontSize' => 0.05],
            ],
        ])
        ->and($this->collab->layer(K::HEADLINE))->toBeNull()
        ->and($this->collab->layer(K::LOGO))->toBeNull()
        ->and($this->collab->layer(K::CAPTION))->not->toBeNull();

    $op = KvAgentRun::findOrFail($this->runId)->ops[0];
    expect($op['type'])->toBe('remove_layer')->and($op['before']['id'])->toBe(K::HEADLINE)->and($op['after'])->toBeNull();
});

it('removes from detached sizes with include_sizes and reports sizes without the layer', function () {
    $with = $this->kvTile(['overlays' => [K::row(K::textLayer(K::HEADLINE, $this->boardA->id, 'Promo Ramadan', 1)), K::row(K::imageLayer(K::LOGO, $this->boardA->id, 2))]]);
    $without = $this->kvTile(['overlays' => [K::row(K::imageLayer(K::LOGO, $this->boardA->id, 2))]]);

    $data = $this->kvTool('POST', $this->file->id.'/layers/remove', [
        'layer_ids' => [K::HEADLINE],
        'targets' => ['board_ids' => [$this->boardA->id], 'include_sizes' => true],
    ], $this->runId)->assertOk()->json('data');

    expect(array_column($with->fresh()->overlays, 'id'))->toBe([K::LOGO])
        ->and($data['skipped'])->toBe([['target' => $without->id, 'layer_id' => K::HEADLINE, 'reason' => 'layer_absent_on_size']])
        ->and(KvAgentRun::findOrFail($this->runId)->ops[1])->toMatchArray(['sink' => 'tile', 'type' => 'remove_layer', 'index' => 0]);
});

it('detaches an inheriting size named by id and removes the layer only there', function () {
    $tile = $this->kvTile();

    $data = $this->kvTool('POST', $this->file->id.'/layers/remove', [
        'layer_ids' => [K::LOGO],
        'targets' => ['size_ids' => [$tile->id]],
    ], $this->runId)->assertOk()->json('data');

    expect($data['detached_sizes'])->toBe([$tile->id])
        ->and(array_column($tile->fresh()->overlays, 'id'))->toBe([K::HEADLINE])
        ->and($this->collab->layer(K::LOGO))->not->toBeNull();
});
```

Append to `tests/Unit/Mcp/KvCanvasToolsTest.php` (import `App\Mcp\Tools\RemoveKvLayersTool`):

```php
it('registers remove_kv_layers as the twin of KvCanvasToolController@removeLayers', function () {
    expect((new ReflectionClass(FrndosServer::class))->getDefaultProperties()['tools'])->toContain(RemoveKvLayersTool::class)
        ->and(RemoveKvLayersTool::METHOD)->toBe('removeLayers')
        ->and((new RemoveKvLayersTool)->toArray()['name'])->toBe('remove_kv_layers')
        ->and(kvTwinSchema(new RemoveKvLayersTool)['required'])->toBe(['workspace_id', 'file_id', 'layer_ids', 'targets']);
});
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/RemoveKvLayersToolTest.php tests/Unit/Mcp/KvCanvasToolsTest.php --compact`
Expected: FAIL — route/twin missing.

- [ ] **Step 3: Implement**

In `KvCanvasEditService` add after `addLayer`:

```php
    /**
     * remove_kv_layers (C3.6).
     *
     * @param  list<string>  $layerIds
     */
    public function removeLayers(StudioFile $file, ToolContext $ctx, ?string $runId, array $layerIds, array $targets): array
    {
        $intents = [];
        foreach (array_values(array_unique($layerIds)) as $layerId) {
            $intents[] = ['kind' => 'remove', 'layer_id' => (string) $layerId, 'targets' => $targets];
        }

        return $this->execute($file, $ctx, $runId, $intents);
    }
```

and extend the `match` in `nextRow` with a `remove` arm:

```php
        $next = match ($intent['kind']) {
            'set' => KvLayerPatch::apply((array) $current, $intent['set']),
            'remove' => null,
        };
```

In `KvCanvasToolController`:

```php
    /** remove_kv_layers (C3.6). */
    public function removeLayers(Request $request, string $fileId, KvCanvasEditService $edits): JsonResponse
    {
        return $this->withFile($request, $fileId, function (StudioFile $file, ToolContext $ctx) use ($request, $edits): array {
            $this->validateInput($request, [
                'layer_ids' => ['required', 'array', 'min:1', 'max:'.KvCanvasEditService::MAX_TARGETS],
                'layer_ids.*' => ['required', 'string', 'max:64'],
                'targets' => ['required', 'array'],
            ]);
            $targets = (array) $request->input('targets');
            self::requireTargets($targets);

            return $edits->removeLayers($file, $ctx, $this->runIdFrom($request, $ctx), (array) $request->input('layer_ids'), $targets);
        });
    }
```

Route (inside the flag group): `Route::post('kv/canvas/{fileId}/layers/remove', [KvCanvasToolController::class, 'removeLayers']);`

`app/Mcp/Tools/RemoveKvLayersTool.php`:

```php
<?php

namespace App\Mcp\Tools;

use App\Http\Controllers\Api\ModelContextProtocol\KvCanvasToolController;
use Illuminate\Contracts\JsonSchema\JsonSchema;

/** Remove layers from the boards and sizes named — applied at once, undoable as a run. */
class RemoveKvLayersTool extends FrndosTool
{
    public const CONTROLLER = KvCanvasToolController::class;

    public const METHOD = 'removeLayers';

    protected string $name = 'remove_kv_layers';

    protected string $description = 'Remove layers from a Key Visual canvas on exactly the boards and sizes you name. Applies at once; Undo (undo_kv_agent_run) puts them back. A board target removes the layer from the board (inheriting sizes follow); include_sizes also removes it from that board\'s detached sizes; a size id removes it only there, detaching that size first if it inherited. Returns run_id, applied, skipped, detached_sizes.';

    protected bool $requiresSubscription = true;

    protected array $routeParamMap = ['file_id' => 'fileId'];

    public function schema(JsonSchema $schema): array
    {
        return [
            'workspace_id' => $this->workspaceIdSchema($schema),
            'file_id' => $schema->string()->description('KV file id (from list_kv_files).')->required(),
            'layer_ids' => $schema->array()->items($schema->string())->description('Layer ids from get_kv_canvas.')->required(),
            'targets' => $schema->object()->description('{board_ids?: [...], size_ids?: [...], include_sizes?: bool}; at least one id. At most 60 targets per call after expansion.')->required(),
            'agent_run_id' => $schema->string()->description('Optional: a run_id from an earlier canvas write, to group this into the same undoable run.'),
        ];
    }
}
```

Register `Tools\RemoveKvLayersTool::class,` after `Tools\AddKvLayerTool::class,`.

- [ ] **Step 4: Run the tests and the mirror**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/RemoveKvLayersToolTest.php tests/Feature/Studio/AgentCanvas/KvCanvasEditServiceTest.php tests/Unit/Mcp/KvCanvasToolsTest.php --compact && php artisan mcp:verify-mirror`
Expected: all PASS; `Mirror OK`.

- [ ] **Step 5: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
vendor/bin/pint --dirty --format agent
git add app/Services/Studio/AgentCanvas/KvCanvasEditService.php app/Http/Controllers/Api/ModelContextProtocol/KvCanvasToolController.php app/Mcp/Tools/RemoveKvLayersTool.php app/Mcp/Servers/FrndosServer.php routes/api.php tests/Feature/Studio/AgentCanvas/RemoveKvLayersToolTest.php tests/Unit/Mcp/KvCanvasToolsTest.php
git commit -m "feat(api): remove_kv_layers tool + MCP twin (C3.6)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 15: `KvAgentRunReverter` and `undo_kv_agent_run` (C3.7, spec §8.2)

**Files:**
- Create: `app/Services/Studio/AgentCanvas/KvAgentRunReverter.php`, `app/Mcp/Tools/UndoKvAgentRunTool.php`
- Modify: `KvCanvasToolController.php` (`undoRun`), `routes/api.php`, `FrndosServer.php`, `tests/Support/KvCanvasFixture.php` (add `edit()`), `tests/Unit/Mcp/KvCanvasToolsTest.php`
- Test: `tests/Feature/Studio/AgentCanvas/UndoKvAgentRunTest.php`

**Interfaces:**
- Consumes: `KvCollabWriter` (Task 5), `KvAgentRunRecorder::settleIfIdle/settle/releaseFileLock` (Task 10), `KvResizeExportService::writeOverlays` (Task 11), `KvLayerDiff` (Task 8), `KvLayerShape` (Task 3). Ledger op shape from Task 4.
- Produces:
  - `KvAgentRunReverter::undo(StudioFile $file, KvAgentRun $run): array{status: 'undone'|'already_undone', reverted: int, skipped: list<array{target, layer_id, reason}>}` — reasons `changed_after_run`, `layer_not_found`. Throws `KvCanvasToolException` 409 `run_in_progress` (an app run still streaming) / `undo_in_progress`; throws `KvCollabUnavailableException` when the live doc cannot be read or written — nothing is reverted in either sink then (the doc batch goes first, atomically; tiles only after it succeeded).
  - Route `POST mcp/tools/kv/canvas/runs/{runId}/undo`; twin `undo_kv_agent_run`.
  - `KvCanvasFixture::edit(string $layerId, array $targets, array $set): array`.

- [ ] **Step 1: Write the failing test**

Add to `tests/Support/KvCanvasFixture.php`:

```php
    /** One update_kv_layers edit. */
    public static function edit(string $layerId, array $targets, array $set): array
    {
        return ['layer_id' => $layerId, 'targets' => $targets, 'set' => $set];
    }
```

`tests/Feature/Studio/AgentCanvas/UndoKvAgentRunTest.php`:

```php
<?php

use App\Models\KvAgentRun;
use App\Models\KvResizeExport;
use App\Services\Studio\AgentCanvas\KvAgentRunRecorder;
use App\Services\Studio\AgentCanvas\KvCanvasEditService;
use Illuminate\Support\Str;
use Tests\Support\KvCanvasFixture as K;
use Tests\Traits\BuildsKvCanvas;

uses(BuildsKvCanvas::class);

beforeEach(fn () => $this->setUpKvCanvas());

function undoRun(string $runId): Illuminate\Testing\TestResponse
{
    return test()->kvTool('POST', 'runs/'.$runId.'/undo');
}

it('reverts every sink newest-first and marks the run undone', function () {
    $tile = $this->kvTile();
    $this->kvUpdate([
        K::edit(K::HEADLINE, ['board_ids' => [$this->boardA->id]], ['text' => 'Ramadan Sale']),
        K::edit(K::LOGO, ['size_ids' => [$tile->id]], ['rect' => ['x' => 0.5]]),
    ]);
    app(KvAgentRunRecorder::class)->settle($this->runId);

    $data = undoRun($this->runId)->assertOk()->json('data');

    // board set + the size's detach + the size's set
    expect($data)->toBe(['status' => 'undone', 'reverted' => 3, 'skipped' => []])
        ->and($this->collab->layer(K::HEADLINE)['payload']['content'])->toBe('Promo Ramadan')
        ->and($tile->fresh()->overlays)->toBeNull();
    $run = KvAgentRun::findOrFail($this->runId);
    expect($run->status)->toBe('undone')->and($run->undo_result)->toBe(['reverted' => 3, 'skipped' => []]);
});

it('skips a layer the user changed after the run and reverts the others', function () {
    $this->kvUpdate([
        K::edit(K::HEADLINE, ['board_ids' => [$this->boardA->id]], ['text' => 'Ramadan Sale']),
        K::edit(K::LOGO, ['board_ids' => [$this->boardA->id]], ['rect' => ['x' => 0.5]]),
    ]);
    app(KvAgentRunRecorder::class)->settle($this->runId);
    $this->collab->editLayer(K::HEADLINE, function (array $layer) {
        $layer['payload']['content'] = 'User copy';

        return $layer;
    });

    $data = undoRun($this->runId)->assertOk()->json('data');

    expect($data['reverted'])->toBe(1)
        ->and($data['skipped'])->toBe([['target' => $this->boardA->id, 'layer_id' => K::HEADLINE, 'reason' => 'changed_after_run']])
        ->and($this->collab->layer(K::HEADLINE)['payload']['content'])->toBe('User copy')
        ->and($this->collab->layer(K::LOGO)['rect']['x'])->toEqual(0.03);
    // The undo's own write carried CAS on what the agent wrote.
    expect(end($this->collab->batches)['ops'])->toEqual([[
        'kind' => 'set_layer', 'layer_id' => K::LOGO, 'set' => ['rect' => ['x' => 0.03]], 'expected' => ['rect' => ['x' => 0.5]],
    ]]);
});

it('skips a layer the user deleted and reverts the others', function () {
    $this->kvUpdate([
        K::edit(K::HEADLINE, ['board_ids' => [$this->boardA->id]], ['text' => 'Ramadan Sale']),
        K::edit(K::LOGO, ['board_ids' => [$this->boardA->id]], ['rect' => ['x' => 0.5]]),
    ]);
    app(KvAgentRunRecorder::class)->settle($this->runId);
    $this->collab->removeLayer(K::HEADLINE);

    $data = undoRun($this->runId)->assertOk()->json('data');

    expect($data['reverted'])->toBe(1)
        ->and($data['skipped'])->toBe([['target' => $this->boardA->id, 'layer_id' => K::HEADLINE, 'reason' => 'layer_not_found']])
        ->and($this->collab->layer(K::HEADLINE))->toBeNull()
        ->and($this->collab->layer(K::LOGO)['rect']['x'])->toEqual(0.03);
});

it('puts a removed layer back', function () {
    app(KvCanvasEditService::class)->removeLayers($this->file, $this->kvCtx($this->runId), $this->runId, [K::HEADLINE], ['board_ids' => [$this->boardA->id]]);
    app(KvAgentRunRecorder::class)->settle($this->runId);
    expect($this->collab->layer(K::HEADLINE))->toBeNull();

    undoRun($this->runId)->assertOk()->assertJsonPath('data.reverted', 1);

    expect($this->collab->layer(K::HEADLINE)['payload']['content'])->toBe('Promo Ramadan');
});

it('skips a size the user changed after the run', function () {
    $tile = $this->kvTile(['overlays' => [K::row(K::textLayer(K::HEADLINE, $this->boardA->id, 'Promo Ramadan', 1))]]);
    $this->kvUpdate([K::edit(K::HEADLINE, ['size_ids' => [$tile->id]], ['text' => 'Ramadan Sale'])]);
    app(KvAgentRunRecorder::class)->settle($this->runId);
    $userEdit = $tile->fresh()->overlays;
    $userEdit[0]['payload']['content'] = 'User copy';
    KvResizeExport::whereKey($tile->id)->update(['overlays' => json_encode($userEdit)]);

    $data = undoRun($this->runId)->assertOk()->json('data');

    expect($data['skipped'])->toBe([['target' => $tile->id, 'layer_id' => K::HEADLINE, 'reason' => 'changed_after_run']])
        ->and($tile->fresh()->overlays[0]['payload']['content'])->toBe('User copy');
});

it('answers already_undone the second time and writes nothing', function () {
    $this->kvUpdate([K::edit(K::HEADLINE, ['board_ids' => [$this->boardA->id]], ['text' => 'Ramadan Sale'])]);
    app(KvAgentRunRecorder::class)->settle($this->runId);
    undoRun($this->runId)->assertOk();
    $requests = $this->collab->opsRequestCount();

    undoRun($this->runId)->assertOk()->assertJsonPath('data', ['status' => 'already_undone', 'reverted' => 0, 'skipped' => []]);

    expect($this->collab->opsRequestCount())->toBe($requests);
});

it('refuses to undo an in-app run whose reply is still streaming', function () {
    $this->kvUpdate([K::edit(K::HEADLINE, ['board_ids' => [$this->boardA->id]], ['text' => 'Ramadan Sale'])]);

    undoRun($this->runId)->assertStatus(409)->assertJsonPath('error', 'run_in_progress');

    expect($this->collab->layer(K::HEADLINE)['payload']['content'])->toBe('Ramadan Sale');
});

it('lets an MCP client undo its own run straight away', function () {
    $result = app(KvCanvasEditService::class)->updateLayers($this->file, $this->kvCtx(null, 'user'), null,
        [K::edit(K::HEADLINE, ['board_ids' => [$this->boardA->id]], ['text' => 'Ramadan Sale'])]);

    undoRun($result['run_id'])->assertOk()->assertJsonPath('data.status', 'undone');

    expect($this->collab->layer(K::HEADLINE)['payload']['content'])->toBe('Promo Ramadan');
});

it('answers 503 and reverts nothing anywhere when collab is down', function () {
    $tile = $this->kvTile();
    $this->kvUpdate([
        K::edit(K::HEADLINE, ['board_ids' => [$this->boardA->id]], ['text' => 'Ramadan Sale']),
        K::edit(K::LOGO, ['size_ids' => [$tile->id]], ['rect' => ['x' => 0.5]]),
    ]);
    app(KvAgentRunRecorder::class)->settle($this->runId);
    $this->collab->down = true;

    undoRun($this->runId)->assertStatus(503)->assertJsonPath('error', 'collab_unavailable');

    expect($tile->fresh()->overlays)->not->toBeNull()
        ->and(KvAgentRun::findOrFail($this->runId)->status)->toBe('completed');
});

it('404s an unknown run', function () {
    undoRun((string) Str::ulid())->assertNotFound();
});
```

Append to `tests/Unit/Mcp/KvCanvasToolsTest.php` (import `App\Mcp\Tools\UndoKvAgentRunTool`):

```php
it('registers undo_kv_agent_run as the twin of KvCanvasToolController@undoRun', function () {
    expect((new ReflectionClass(FrndosServer::class))->getDefaultProperties()['tools'])->toContain(UndoKvAgentRunTool::class)
        ->and(UndoKvAgentRunTool::METHOD)->toBe('undoRun')
        ->and((new UndoKvAgentRunTool)->toArray()['name'])->toBe('undo_kv_agent_run')
        ->and(kvTwinSchema(new UndoKvAgentRunTool)['required'])->toBe(['workspace_id', 'run_id']);
});
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/UndoKvAgentRunTest.php tests/Unit/Mcp/KvCanvasToolsTest.php --compact`
Expected: FAIL — route/classes missing.

- [ ] **Step 3: Write the reverter**

`app/Services/Studio/AgentCanvas/KvAgentRunReverter.php`:

```php
<?php

namespace App\Services\Studio\AgentCanvas;

use App\Exceptions\Studio\KvCanvasToolException;
use App\Exceptions\Studio\KvCollabRejectedException;
use App\Exceptions\Studio\KvCollabUnavailableException;
use App\Exceptions\Studio\KvLayerChangedException;
use App\Exceptions\Studio\KvLayerNotFoundException;
use App\Models\KvAgentRun;
use App\Models\KvResizeExport;
use App\Models\StudioFile;
use App\Services\Studio\KvResizeExportService;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;

/**
 * Server-mode Undo run (spec §8.2): replay the ledger newest-first, each
 * reversal a compare-and-set against what the AGENT wrote. A layer a person
 * changed (or deleted) after the run is left as they left it and reported in
 * `skipped` — undo never overwrites user work.
 *
 * Per sink, all or nothing: the doc reversals go to collab as ONE batch
 * (re-read and re-decided if someone edits in between), and the size
 * reversals run per tile in a transaction — only after the doc batch
 * landed, so a collab outage reverts nothing anywhere and the run stays
 * undoable. Credits already spent are not refunded (nothing in P1 spends).
 */
final class KvAgentRunReverter
{
    /** Longer than any replay: a few collab round-trips plus the tile transactions. */
    private const UNDO_LOCK_SECONDS = 120;

    private const DOC_ATTEMPTS = 3;

    public function __construct(
        private readonly KvCollabWriter $collab,
        private readonly KvAgentRunRecorder $recorder,
        private readonly KvResizeExportService $tiles,
    ) {}

    /**
     * @return array{status: string, reverted: int, skipped: list<array{target: string, layer_id: ?string, reason: string}>}
     *
     * @throws KvCanvasToolException 409 run_in_progress | undo_in_progress
     * @throws KvCollabUnavailableException nothing was reverted
     */
    public function undo(StudioFile $file, KvAgentRun $run): array
    {
        $lock = Cache::lock('kv-agent-run-undo:'.$run->id, self::UNDO_LOCK_SECONDS);
        if (! $lock->get()) {
            throw KvCanvasToolException::conflict('undo_in_progress', 'This run is already being undone — try again in a moment.');
        }

        try {
            $run = $run->fresh() ?? $run;
            if ($run->isUndone()) {
                return ['status' => 'already_undone', 'reverted' => 0, 'skipped' => []];
            }
            $run = $this->recorder->settleIfIdle($run);
            if ($run->status === KvAgentRun::STATUS_RUNNING) {
                if ($run->source !== KvAgentRun::SOURCE_MCP) {
                    throw KvCanvasToolException::conflict('run_in_progress', 'This run is still going — wait for the reply to finish, then undo.');
                }
                // An MCP run has no stream to close it; asking to undo it is the client closing it.
                $this->recorder->settle($run->id);
                $run = $run->fresh() ?? $run;
            }

            $ops = array_values(array_filter($run->ops ?? [], 'is_array'));
            $docOps = array_reverse(array_values(array_filter($ops, static fn (array $op) => ($op['sink'] ?? '') === 'doc')));
            $tileOps = array_reverse(array_values(array_filter($ops, static fn (array $op) => ($op['sink'] ?? '') === 'tile')));

            [$docReverted, $docSkipped] = $docOps === [] ? [0, []] : $this->revertDoc($file, $run, $docOps);
            [$tileReverted, $tileSkipped] = $tileOps === [] ? [0, []] : $this->revertTiles($file, $tileOps);

            $result = [
                'status' => 'undone',
                'reverted' => $docReverted + $tileReverted,
                'skipped' => array_merge($docSkipped, $tileSkipped),
            ];
            $run->forceFill([
                'status' => KvAgentRun::STATUS_UNDONE,
                'undo_result' => ['reverted' => $result['reverted'], 'skipped' => $result['skipped']],
            ])->save();
            $this->recorder->releaseFileLock($run);

            return $result;
        } finally {
            $lock->release();
        }
    }

    /** @return array{0: int, 1: list<array{target: string, layer_id: ?string, reason: string}>} */
    private function revertDoc(StudioFile $file, KvAgentRun $run, array $ops): array
    {
        for ($attempt = 1; $attempt <= self::DOC_ATTEMPTS; $attempt++) {
            $live = [];
            foreach ((array) ($this->collab->liveDocument($file)['overlays'] ?? []) as $layer) {
                if (is_array($layer)) {
                    $row = KvLayerShape::toRow($layer);
                    $live[$row['id']] ??= $row;
                }
            }

            $work = $live;
            $touched = [];
            $reverted = 0;
            $skipped = [];
            foreach ($ops as $op) {
                $layerId = (string) ($op['layer_id'] ?? '');
                $current = $work[$layerId] ?? null;
                $reason = null;
                $next = $current;
                switch ($op['type'] ?? '') {
                    case 'set_layer':
                        $keys = KvLayerDiff::changedKeys($op['before'] ?? null, $op['after'] ?? null);
                        if ($current === null) {
                            $reason = 'layer_not_found';
                        } elseif (! KvLayerDiff::matches($current, (array) $op['after'], $keys)) {
                            $reason = 'changed_after_run';
                        } else {
                            $next = KvLayerDiff::applyKeys($current, (array) $op['before'], $keys);
                        }
                        break;
                    case 'add_layer':
                        if ($current === null) {
                            $reason = 'layer_not_found';
                        } elseif (! KvLayerDiff::isEmpty(KvLayerDiff::changedKeys($current, $op['after'] ?? null))) {
                            $reason = 'changed_after_run';
                        } else {
                            $next = null;
                        }
                        break;
                    case 'remove_layer':
                        if ($current !== null) {
                            $reason = 'changed_after_run';
                        } else {
                            $next = (array) $op['before'];
                        }
                        break;
                    default:
                        continue 2;
                }

                if ($reason !== null) {
                    $skipped[] = ['target' => (string) $op['target'], 'layer_id' => $layerId, 'reason' => $reason];

                    continue;
                }
                $work[$layerId] = $next;
                $touched[$layerId] = true;
                $reverted++;
            }

            $collabOps = [];
            foreach (array_keys($touched) as $layerId) {
                $layerId = (string) $layerId;
                $from = $live[$layerId] ?? null;
                $to = $work[$layerId] ?? null;
                if ($from === null && $to !== null) {
                    $collabOps[] = ['kind' => 'add_layer', 'layer' => KvLayerShape::toLayer($to)];
                } elseif ($from !== null && $to === null) {
                    $collabOps[] = ['kind' => 'remove_layer', 'layer_id' => $layerId, 'expected' => KvLayerDiff::fullExpected($from)];
                } elseif ($from !== null && $to !== null && ($setOp = KvLayerDiff::setLayerOp($layerId, $from, $to)) !== null) {
                    $collabOps[] = $setOp;
                }
            }
            if ($collabOps === []) {
                return [$reverted, $skipped];
            }

            try {
                $this->collab->applyOps($file, $collabOps, $run->id);

                return [$reverted, $skipped];
            } catch (KvLayerChangedException|KvLayerNotFoundException) {
                // Someone edited between our read and the write: re-read and
                // re-decide; that layer will now read as changed_after_run.
                continue;
            } catch (KvCollabRejectedException $e) {
                throw new KvCollabUnavailableException('The undo could not be written to the canvas: '.$e->getMessage());
            }
        }

        throw new KvCollabUnavailableException('The canvas kept changing while the run was being undone. Nothing was reverted — try again.');
    }

    /** @return array{0: int, 1: list<array{target: string, layer_id: ?string, reason: string}>} */
    private function revertTiles(StudioFile $file, array $ops): array
    {
        $byTile = [];
        foreach ($ops as $op) {
            $byTile[(string) $op['target']][] = $op; // still newest-first within each tile
        }

        $reverted = 0;
        $skipped = [];
        foreach ($byTile as $tileId => $tileOps) {
            [$count, $skips] = DB::transaction(function () use ($file, $tileId, $tileOps): array {
                $tile = KvResizeExport::query()
                    ->whereKey((string) $tileId)
                    ->where('studio_file_id', $file->id)
                    ->lockForUpdate()
                    ->first();
                if ($tile === null) {
                    return [0, array_map(static fn (array $op) => ['target' => (string) $tileId, 'layer_id' => $op['layer_id'] ?? null, 'reason' => 'layer_not_found'], $tileOps)];
                }

                $list = is_array($tile->overlays) ? array_values($tile->overlays) : null;
                $count = 0;
                $skips = [];
                foreach ($tileOps as $op) {
                    $layerId = $op['layer_id'] ?? null;
                    $reason = null;
                    if (($op['type'] ?? '') === 'detach_size') {
                        if ($list === null || ! KvLayerDiff::sameList($list, (array) $op['after'])) {
                            $reason = 'changed_after_run';
                        } else {
                            $list = null;
                        }
                    } else {
                        $index = $list === null ? null : self::indexOf($list, (string) $layerId);
                        $current = $index === null ? null : $list[$index];
                        switch ($op['type'] ?? '') {
                            case 'set_layer':
                                $keys = KvLayerDiff::changedKeys($op['before'] ?? null, $op['after'] ?? null);
                                if ($current === null) {
                                    $reason = 'layer_not_found';
                                } elseif (! KvLayerDiff::matches($current, (array) $op['after'], $keys)) {
                                    $reason = 'changed_after_run';
                                } else {
                                    $list[$index] = KvLayerDiff::applyKeys($current, (array) $op['before'], $keys);
                                }
                                break;
                            case 'add_layer':
                                if ($current === null) {
                                    $reason = 'layer_not_found';
                                } elseif (! KvLayerDiff::isEmpty(KvLayerDiff::changedKeys($current, $op['after'] ?? null))) {
                                    $reason = 'changed_after_run';
                                } else {
                                    array_splice($list, $index, 1);
                                }
                                break;
                            case 'remove_layer':
                                if ($list === null || $current !== null) {
                                    $reason = 'changed_after_run';
                                } else {
                                    $at = min((int) ($op['index'] ?? count($list)), count($list));
                                    array_splice($list, $at, 0, [(array) $op['before']]);
                                }
                                break;
                            default:
                                continue 2;
                        }
                    }

                    if ($reason !== null) {
                        $skips[] = ['target' => (string) $tileId, 'layer_id' => $layerId, 'reason' => $reason];

                        continue;
                    }
                    $count++;
                }

                if ($count > 0) {
                    $this->tiles->writeOverlays($tile, $list);
                }

                return [$count, $skips];
            });
            $reverted += $count;
            $skipped = array_merge($skipped, $skips);
        }

        return [$reverted, $skipped];
    }

    private static function indexOf(array $rows, string $layerId): ?int
    {
        foreach ($rows as $i => $row) {
            if (is_array($row) && ($row['id'] ?? null) === $layerId) {
                return $i;
            }
        }

        return null;
    }
}
```

- [ ] **Step 4: Controller method, route, twin**

In `KvCanvasToolController` (imports `App\Models\KvAgentRun`, `App\Services\Studio\AgentCanvas\KvAgentRunReverter`):

```php
    /** undo_kv_agent_run (C3.7): any member who can open the run's file may undo it. */
    public function undoRun(Request $request, string $runId, KvAgentRunReverter $reverter): JsonResponse
    {
        $run = KvAgentRun::query()->find($runId);
        if ($run === null) {
            return KvCanvasToolException::notFound('Agent run not found')->toResponse();
        }

        return $this->withFile($request, $run->studio_file_id, fn (StudioFile $file): array => $reverter->undo($file, $run));
    }
```

Route (inside the flag group): `Route::post('kv/canvas/runs/{runId}/undo', [KvCanvasToolController::class, 'undoRun']);`

`app/Mcp/Tools/UndoKvAgentRunTool.php`:

```php
<?php

namespace App\Mcp\Tools;

use App\Http\Controllers\Api\ModelContextProtocol\KvCanvasToolController;
use Illuminate\Contracts\JsonSchema\JsonSchema;

/** Undo every change one agent run made on a KV canvas. */
class UndoKvAgentRunTool extends FrndosTool
{
    public const CONTROLLER = KvCanvasToolController::class;

    public const METHOD = 'undoRun';

    protected string $name = 'undo_kv_agent_run';

    protected string $description = 'Undo every canvas change an agent run made, newest first. A layer someone changed or deleted after the run is left as they left it and listed in skipped (changed_after_run / layer_not_found). Sizes the run detached go back to following their board. Returns {status: undone|already_undone, reverted, skipped}. Fails with collab_unavailable (nothing reverted) when the canvas service is down.';

    protected bool $requiresSubscription = true;

    protected array $routeParamMap = ['run_id' => 'runId'];

    public function schema(JsonSchema $schema): array
    {
        return [
            'workspace_id' => $this->workspaceIdSchema($schema),
            'run_id' => $schema->string()->description('The run_id a canvas write returned.')->required(),
        ];
    }
}
```

Register `Tools\UndoKvAgentRunTool::class,` after `Tools\RemoveKvLayersTool::class,`.

- [ ] **Step 5: Run the tests and the mirror**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/UndoKvAgentRunTest.php tests/Unit/Mcp/KvCanvasToolsTest.php --compact && php artisan mcp:verify-mirror`
Expected: all PASS; `Mirror OK`. Then prove the CAS bites: in `revertDoc` replace `! KvLayerDiff::matches($current, (array) $op['after'], $keys)` with `false` — "skips a layer the user changed…" must FAIL (the user's copy gets overwritten). Restore.

- [ ] **Step 6: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
vendor/bin/pint --dirty --format agent
git add app/Services/Studio/AgentCanvas/KvAgentRunReverter.php app/Http/Controllers/Api/ModelContextProtocol/KvCanvasToolController.php app/Mcp/Tools/UndoKvAgentRunTool.php app/Mcp/Servers/FrndosServer.php routes/api.php tests/Support/KvCanvasFixture.php tests/Feature/Studio/AgentCanvas/UndoKvAgentRunTest.php tests/Unit/Mcp/KvCanvasToolsTest.php
git commit -m "feat(api): server-mode undo of KV agent runs + undo_kv_agent_run (C3.7)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 16: C5 user routes — run view and undo for the run card

**Files:**
- Create: `app/Http/Controllers/Api/Studio/KvAgentRunController.php`
- Modify: `routes/api.php` (studio group, inside `Route::middleware('feature.flag:show-kv-generator')->group(`, directly above the comment `// KV Background Removal (per-overlay, file-scoped`; `use` line beside the other Studio controllers)
- Test: `tests/Feature/Studio/AgentCanvas/KvAgentRunRoutesTest.php`

**Interfaces:**
- Consumes: `KvAgentRun::toView()` (Task 4), `KvAgentRunRecorder::settleIfIdle` (Task 10), `KvAgentRunReverter::undo` (Task 15), `AuthorizesStudioFileAccess`.
- Produces: `GET /api/v1/studio/files/{fileId}/agent/runs/{runId}` → `{"message": "OK", "data": <C5 run view>}`; `POST …/undo` → `{"message": "OK", "data": <C3.7 body>}` (409/503 as `{message, error, data: null}`). Both behind `feature.flag:kv-agentic-canvas,off` inside the existing `scope_role:internal` + `feature.flag:show-kv-generator` studio group.

- [ ] **Step 1: Write the failing test**

`tests/Feature/Studio/AgentCanvas/KvAgentRunRoutesTest.php`:

```php
<?php

use App\Models\KvAgentRun;
use App\Models\StudioFile;
use App\Services\Studio\AgentCanvas\KvAgentRunRecorder;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Route;
use Illuminate\Support\Str;
use Tests\Support\KvCanvasFixture as K;
use Tests\Traits\BuildsKvCanvas;

uses(BuildsKvCanvas::class);

beforeEach(function () {
    $this->setUpKvCanvas();
    $this->actingAs($this->user, 'api');
});

it('shows the run the way the run card renders it', function () {
    $tile = $this->kvTile();
    $this->kvUpdate([
        K::edit(K::HEADLINE, ['board_ids' => [$this->boardA->id], 'size_ids' => [$tile->id]], ['text' => 'Ramadan Sale']),
        K::edit(K::CAPTION, ['board_ids' => [$this->boardA->id]], ['text' => 'x']),
    ]);
    $sizeLabel = 'Concept A · '.$tile->displayLabel();

    $response = $this->getJson("/api/v1/studio/files/{$this->file->id}/agent/runs/{$this->runId}")
        ->assertOk()
        ->assertJsonPath('message', 'OK');

    $data = $response->json('data');
    expect($data)->toMatchArray(['id' => $this->runId, 'status' => 'running', 'source' => 'app', 'undo' => null])
        ->and($data['applied'])->toBe([
            ['target' => $this->boardA->id, 'target_kind' => 'board', 'target_label' => 'Concept A', 'layer_id' => K::HEADLINE, 'op' => 'set_layer'],
            ['target' => $tile->id, 'target_kind' => 'size', 'target_label' => $sizeLabel, 'layer_id' => K::HEADLINE, 'op' => 'set_layer'],
        ])
        ->and($data['skipped'])->toBe([['target' => $this->boardA->id, 'target_kind' => 'board', 'target_label' => 'Concept A', 'layer_id' => K::CAPTION, 'reason' => 'layer_not_found']])
        ->and($data['detached_sizes'])->toBe([['size_id' => $tile->id, 'label' => $sizeLabel]]);
});

it('undoes the run from the card', function () {
    $this->kvUpdate([K::edit(K::HEADLINE, ['board_ids' => [$this->boardA->id]], ['text' => 'Ramadan Sale'])]);
    app(KvAgentRunRecorder::class)->settle($this->runId);

    $this->postJson("/api/v1/studio/files/{$this->file->id}/agent/runs/{$this->runId}/undo")
        ->assertOk()
        ->assertJsonPath('data', ['status' => 'undone', 'reverted' => 1, 'skipped' => []]);

    expect($this->collab->layer(K::HEADLINE)['payload']['content'])->toBe('Promo Ramadan')
        ->and(KvAgentRun::findOrFail($this->runId)->toView()['undo'])->toBe(['reverted' => 1, 'skipped' => []]);
});

it('answers 409 while the reply is still streaming', function () {
    $this->kvUpdate([K::edit(K::HEADLINE, ['board_ids' => [$this->boardA->id]], ['text' => 'Ramadan Sale'])]);

    $this->postJson("/api/v1/studio/files/{$this->file->id}/agent/runs/{$this->runId}/undo")
        ->assertStatus(409)->assertJsonPath('error', 'run_in_progress');
});

it('404s a run that belongs to another file', function () {
    $other = StudioFile::factory()->create(['workspace_id' => $this->workspace->id, 'brand_id' => null, 'tool_id' => $this->file->tool_id]);
    KvAgentRun::create(['id' => $id = (string) Str::ulid(), 'studio_file_id' => $other->id, 'user_id' => $this->user->id,
        'workspace_id' => $this->workspace->id, 'source' => 'app']);

    $this->getJson("/api/v1/studio/files/{$this->file->id}/agent/runs/{$id}")->assertNotFound();
});

it('puts both routes behind the fail-closed flag', function () {
    foreach (['GET' => '', 'POST' => '/undo'] as $method => $suffix) {
        $route = Route::getRoutes()->match(Request::create("/api/v1/studio/files/f/agent/runs/r{$suffix}", $method));
        expect($route->gatherMiddleware())->toContain('feature.flag:kv-agentic-canvas,off', 'scope_role:internal');
    }
});
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/KvAgentRunRoutesTest.php --compact`
Expected: FAIL — 404 routes.

- [ ] **Step 3: Controller and routes**

`app/Http/Controllers/Api/Studio/KvAgentRunController.php`:

```php
<?php

namespace App\Http\Controllers\Api\Studio;

use App\Exceptions\Studio\KvCanvasToolException;
use App\Exceptions\Studio\KvCollabUnavailableException;
use App\Http\Controllers\Api\Studio\Concerns\AuthorizesStudioFileAccess;
use App\Http\Controllers\Controller;
use App\Models\KvAgentRun;
use App\Models\StudioFile;
use App\Services\Studio\AgentCanvas\KvAgentRunRecorder;
use App\Services\Studio\AgentCanvas\KvAgentRunReverter;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;

/**
 * The run card's two calls (contract C5): what a run did, and Undo run.
 * Same file gate as every studio file route; the undo is the same reverter
 * the `undo_kv_agent_run` tool uses.
 */
class KvAgentRunController extends Controller
{
    use AuthorizesStudioFileAccess;

    public function show(Request $request, string $fileId, string $runId, KvAgentRunRecorder $recorder): JsonResponse
    {
        $run = $this->runOf($request, $fileId, $runId);

        return response()->json(['message' => 'OK', 'data' => $recorder->settleIfIdle($run)->toView()]);
    }

    public function undo(Request $request, string $fileId, string $runId, KvAgentRunReverter $reverter): JsonResponse
    {
        $run = $this->runOf($request, $fileId, $runId);

        try {
            return response()->json(['message' => 'OK', 'data' => $reverter->undo($run->file, $run)]);
        } catch (KvCanvasToolException $e) {
            return $e->toResponse();
        } catch (KvCollabUnavailableException $e) {
            return response()->json(['message' => $e->getMessage(), 'error' => 'collab_unavailable', 'data' => null], 503);
        }
    }

    private function runOf(Request $request, string $fileId, string $runId): KvAgentRun
    {
        $file = StudioFile::query()->findOrFail($fileId);
        $this->authorizeAccess($file, $request);

        $run = KvAgentRun::query()->where('studio_file_id', $file->id)->find($runId);
        abort_if($run === null, 404, 'Agent run not found');
        $run->setRelation('file', $file);

        return $run;
    }
}
```

In `routes/api.php` add `use App\Http\Controllers\Api\Studio\KvAgentRunController;` and, inside the `feature.flag:show-kv-generator` group directly above `// KV Background Removal (per-overlay, file-scoped`:

```php
                            // KV agentic canvas run card (contract C5): the run a
                            // chat turn or MCP client made, and Undo run.
                            Route::middleware('feature.flag:kv-agentic-canvas,off')->group(
                                function () {
                                    Route::get('files/{fileId}/agent/runs/{runId}', [
                                        KvAgentRunController::class,
                                        'show',
                                    ]);
                                    Route::post('files/{fileId}/agent/runs/{runId}/undo', [
                                        KvAgentRunController::class,
                                        'undo',
                                    ]);
                                }
                            );
```

- [ ] **Step 4: Run the test, then probe for a stale route cache**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/KvAgentRunRoutesTest.php --compact && ls bootstrap/cache/routes-v7.php 2>/dev/null; php artisan route:list --path=agent/runs`
Expected: 5 PASS; no `routes-v7.php` listed; `route:list` shows the GET and POST routes.

- [ ] **Step 5: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
vendor/bin/pint --dirty --format agent
git add app/Http/Controllers/Api/Studio/KvAgentRunController.php routes/api.php tests/Feature/Studio/AgentCanvas/KvAgentRunRoutesTest.php
git commit -m "feat(api): KV agent run view and undo routes for the run card (C5)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 17: C4 — the chat turn carries the canvas, relays `kv_agent_run`, settles the run

**Files:**
- Create: `app/Services/Studio/AgentCanvas/KvAgentCanvasTurn.php`
- Modify: `app/Services/ChatService.php` (`streamKvGenerator`, ~L1364–2378), `app/Http/Controllers/Api/Studio/KvGeneratorFileController.php` (`show` chat_history loop ~L97–250, `simpleChatHistoryForThread` ~L449)
- Test: `tests/Feature/Studio/AgentCanvas/KvAgentCanvasStreamTest.php`

**Interfaces:**
- Consumes: `KvCanvasContextAssembler::load/inventory` (Task 9), `KvAgentCanvasFlag::enabledFor` (Task 9), `KvAgentRunRecorder::settle/fail` (Task 10).
- Produces:
  - `KvAgentCanvasTurn::forTurn(User $user, Workspace $workspace, ?StudioFile $file, string $canvasMode, string $mode, ?string $activeBoardId): ?array{run_id, file_id, inventory}` — non-null only for flag on + KV file + `canvas_mode = craft` + `mode = chat` + a readable live doc.
  - ai-service body gains `agent_canvas` (C4) only when non-null (older ai-service builds never see an unknown key); `workspace_id` stays at the body root.
  - NDJSON `{"event":"kv_agent_run","run_id":…}` (a `case` of the existing `switch ($parsedData['event'])`) → SSE `{"type":"kv_agent_run","run_id":…}`, only for the run id this turn minted; the assistant row of the turn gets `message.agent_run_id` (the existing row is updated — the frame arrives after it is saved; a turn with no text still gets one assistant row carrying the id). `done` → `settle`; a stream that ends without `done` or throws → `fail`.
  - Hydration: every `chat_history[]` item and every `kv_chat_history[<mode>][]` item of `GET studio/kv-generator/files/{id}` carries `agent_run_id` (string or null); an assistant row with empty text but a run id is no longer dropped.

- [ ] **Step 1: Write the failing test**

`tests/Feature/Studio/AgentCanvas/KvAgentCanvasStreamTest.php`:

```php
<?php

use App\Enums\ThreadType;
use App\Models\KvAgentRun;
use App\Models\UserChatHistory;
use App\Models\UserThread;
use App\Services\ChatService;
use App\Services\FeatureFlagService;
use Illuminate\Http\Client\Request;
use Illuminate\Support\Facades\Http;
use Tests\Traits\BuildsKvCanvas;

uses(BuildsKvCanvas::class);

/** A ChatService whose SSE writes are captured instead of echoed. */
function kvStreamService(): ChatService
{
    return new class extends ChatService
    {
        /** @var list<array<string, mixed>> */
        public array $emitted = [];

        public function emitStreamStart(?array $data = []): void {}

        public function emitStreamContent(array $data): void
        {
            $this->emitted[] = json_decode((string) json_encode($data), true);
        }

        public function emitStreamComplete(array $data): void
        {
            $this->emitted[] = ['type' => 'complete'];
        }

        public function emitStreamError(string $message, ?array $data = []): void
        {
            $this->emitted[] = ['type' => 'error', 'message' => $message];
        }
    };
}

function kvStreamTurn(ChatService $service, string $mode, string $canvasMode): void
{
    $response = $service->streamKvGenerator(
        test()->thread, 'Change the headline', $mode, test()->user, test()->workspace,
        canvasMode: $canvasMode, baseGenerationId: test()->boardA->id,
    );
    ob_start();
    $response->sendContent();
    ob_end_clean();
}

/** ai-service answers with these NDJSON frames; a callable receives the minted run id. */
function kvAiFrames(callable $frames): void
{
    test()->frames = $frames;
}

function kvOpenRun(string $runId): void
{
    // What the turn's first canvas write does (KvAgentRunRecorder::ensureRun).
    KvAgentRun::create(['id' => $runId, 'studio_file_id' => test()->file->id, 'user_id' => test()->user->id,
        'workspace_id' => test()->workspace->id, 'source' => 'app']);
}

beforeEach(function () {
    config(['services.ai.url' => 'http://ai.test']);
    $this->seen = null;
    $this->frames = fn (?string $runId) => [['event' => 'message', 'text' => 'Hi.'], ['event' => 'done']];
    $this->setUpKvCanvas([
        'ai.test/ai/kv-generator/stream' => function (Request $request) {
            $this->seen = $request->data();
            $frames = ($this->frames)($this->seen['agent_canvas']['run_id'] ?? null);

            return Http::response(implode('', array_map(fn ($f) => json_encode($f)."\n", $frames)));
        },
    ]);
    $this->actingAs($this->user, 'api');
    $this->thread = UserThread::create([
        'user_id' => $this->user->id, 'workspace_id' => $this->workspace->id, 'thread_type' => ThreadType::KvGenerator->value,
        'launch_context' => ['studio_file_id' => $this->file->id, 'brand_id' => null, 'use_brand_knowledge' => false, 'project_id' => null],
    ]);
});

it('gives a flagged Craft chat turn the canvas and relays its run', function () {
    kvAiFrames(function (?string $runId) {
        kvOpenRun($runId);

        return [
            ['event' => 'message', 'text' => 'Changed the headline on Concept A.'],
            ['event' => 'kv_agent_run', 'run_id' => $runId],
            ['event' => 'done'],
        ];
    });
    $service = kvStreamService();

    kvStreamTurn($service, 'chat', 'craft');

    $canvas = $this->seen['agent_canvas'];
    $runId = $canvas['run_id'];
    expect(strlen($runId))->toBe(26)
        ->and($canvas['file_id'])->toBe($this->file->id)
        ->and($canvas['inventory']['active']['board_id'])->toBe($this->boardA->id)
        ->and(array_column($canvas['inventory']['boards'], 'board_id'))->toBe([$this->boardA->id, $this->boardB->id])
        ->and($this->seen['workspace_id'])->toBe($this->workspace->id);

    expect(array_values(array_filter($service->emitted, fn ($f) => ($f['type'] ?? null) === 'kv_agent_run')))
        ->toBe([['type' => 'kv_agent_run', 'run_id' => $runId]]);

    $assistant = UserChatHistory::where('session_id', $this->thread->id)->get()->filter(fn ($m) => ($m->message['type'] ?? null) === 'ai');
    expect($assistant)->toHaveCount(1)
        ->and($assistant->first()->message['content'])->toBe('Changed the headline on Concept A.')
        ->and($assistant->first()->message['agent_run_id'])->toBe($runId)
        ->and(KvAgentRun::findOrFail($runId)->status)->toBe('completed');
});

it('still stores one assistant row for a run whose reply had no text', function () {
    kvAiFrames(function (?string $runId) {
        kvOpenRun($runId);

        return [['event' => 'kv_agent_run', 'run_id' => $runId], ['event' => 'done']];
    });

    kvStreamTurn(kvStreamService(), 'chat', 'craft');

    $assistant = UserChatHistory::where('session_id', $this->thread->id)->get()->filter(fn ($m) => ($m->message['type'] ?? null) === 'ai');
    expect($assistant)->toHaveCount(1)
        ->and($assistant->first()->message['content'])->toBe('')
        ->and($assistant->first()->message['agent_run_id'])->toBe($this->seen['agent_canvas']['run_id']);
});

it('ignores a run id the turn did not mint', function () {
    kvAiFrames(fn (?string $runId) => [
        ['event' => 'message', 'text' => 'Hi.'],
        ['event' => 'kv_agent_run', 'run_id' => '01JSOMEONEELSESRUN00000000'],
        ['event' => 'done'],
    ]);
    $service = kvStreamService();

    kvStreamTurn($service, 'chat', 'craft');

    expect(array_filter($service->emitted, fn ($f) => ($f['type'] ?? null) === 'kv_agent_run'))->toBe([])
        ->and(UserChatHistory::where('session_id', $this->thread->id)->get()->pluck('message.agent_run_id')->filter()->all())->toBe([]);
});

it('fails the run when the stream ends without done', function () {
    kvAiFrames(function (?string $runId) {
        kvOpenRun($runId);

        return [['event' => 'kv_agent_run', 'run_id' => $runId], ['event' => 'message', 'text' => 'Half']];
    });

    kvStreamTurn(kvStreamService(), 'chat', 'craft');

    expect(KvAgentRun::findOrFail($this->seen['agent_canvas']['run_id'])->status)->toBe('failed');
});

it('sends no canvas outside a Craft chat turn', function (string $mode, string $canvasMode) {
    kvStreamTurn(kvStreamService(), $mode, $canvasMode);

    expect($this->seen)->not->toHaveKey('agent_canvas');
})->with([
    'craft image turn' => ['image', 'craft'],
    'sketch chat turn' => ['chat', 'sketch'],
]);

it('sends no canvas while the flag is off', function () {
    $this->mock(FeatureFlagService::class, fn ($mock) => $mock->shouldReceive('isEnabledForWorkspace')->andReturn(false));

    kvStreamTurn(kvStreamService(), 'chat', 'craft');

    expect($this->seen)->not->toHaveKey('agent_canvas');
});

it('hands agent_run_id back on hydration, including a text-less run row', function () {
    $this->file->forceFill(['thread_id' => $this->thread->id, 'metadata' => ['kv_threads' => ['craft' => $this->thread->id]]])->save();
    $this->thread->messages()->create(['message' => ['content' => 'Done.', 'type' => 'ai', 'agent_run_id' => 'RUN_ONE'], 'created_at' => now()->subSecond()]);
    $this->thread->messages()->create(['message' => ['content' => '', 'type' => 'ai', 'agent_run_id' => 'RUN_TWO'], 'created_at' => now()]);

    $data = $this->getJson("/api/v1/studio/kv-generator/files/{$this->file->id}")->assertOk()->json('data');

    expect(array_column($data['chat_history'], 'agent_run_id'))->toBe(['RUN_ONE', 'RUN_TWO'])
        ->and(array_column($data['kv_chat_history']['craft'], 'agent_run_id'))->toBe(['RUN_ONE', 'RUN_TWO']);
});
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/KvAgentCanvasStreamTest.php --compact`
Expected: FAIL — `agent_canvas` missing (null offset), hydration lacks `agent_run_id`.

- [ ] **Step 3: Write `KvAgentCanvasTurn`**

`app/Services/Studio/AgentCanvas/KvAgentCanvasTurn.php`:

```php
<?php

namespace App\Services\Studio\AgentCanvas;

use App\Models\StudioFile;
use App\Models\User;
use App\Models\Workspace;
use App\Support\Studio\KvAgentCanvasFlag;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Str;

/**
 * Contract C4: whether a KV chat turn carries the canvas tools, and what it
 * ships with them. The run id is minted HERE, per turn — ai-service only
 * relays it, and ChatService only accepts that one id back.
 */
final class KvAgentCanvasTurn
{
    public function __construct(private readonly KvCanvasContextAssembler $assembler) {}

    /** @return array{run_id: string, file_id: string, inventory: array<string, mixed>}|null */
    public function forTurn(User $user, Workspace $workspace, ?StudioFile $file, string $canvasMode, string $mode, ?string $activeBoardId): ?array
    {
        if ($file === null || $canvasMode !== 'craft' || $mode !== 'chat') {
            return null;
        }
        if ($file->loadMissing('tool')->tool?->slug !== 'kv-generator') {
            return null;
        }
        if (! KvAgentCanvasFlag::enabledFor($user, (string) $workspace->id)) {
            return null;
        }

        try {
            $inventory = $this->assembler->inventory($this->assembler->load($file), $activeBoardId);
        } catch (\Throwable $e) {
            // No canvas this turn — every canvas write would fail anyway; the
            // chat itself still runs exactly as it does without the flag.
            Log::warning('kv.agent_canvas.turn_without_canvas', ['studio_file_id' => $file->id, 'message' => $e->getMessage()]);

            return null;
        }

        return ['run_id' => (string) Str::ulid(), 'file_id' => $file->id, 'inventory' => $inventory];
    }
}
```

- [ ] **Step 4: Wire it into `ChatService::streamKvGenerator`**

Add imports `use App\Services\Studio\AgentCanvas\KvAgentCanvasTurn;` and `use App\Services\Studio\AgentCanvas\KvAgentRunRecorder;`. Then, inside `streamKvGenerator`'s `response()->stream(function () use (...) {` closure:

1. Directly before its `try {` add:

```php
            // KV agentic canvas (contract C4): the run this turn minted, if it carries the canvas tools.
            $agentRunId = null;
```

2. Directly after `$agentConfig = $this->resolveKvAgentConfig($workspace, $effectiveAgentRoleSlug, $studioFile);` add:

```php
                // KV agentic canvas (spec 2026-09-29 §4.2): a flagged Craft CHAT
                // turn gets the canvas inventory and a run id; ai-service binds
                // the canvas tools to both. Null = today's chat, unchanged.
                $agentCanvas = app(KvAgentCanvasTurn::class)->forTurn(
                    $user, $workspace, $studioFile, $canvasMode, $mode, $baseGenerationId ?: $editingBoardGenerationId,
                );
                $agentRunId = $agentCanvas['run_id'] ?? null;
```

3. Directly after the `$payload = [ … 'brand_logo_stamp' => $brandLogoStamp, ];` array add:

```php
                // Only when present: an ai-service without the field never sees it.
                if ($agentCanvas !== null) {
                    $payload['agent_canvas'] = $agentCanvas;
                }
```

4. Directly before `$handleLine = function (string $line) use (` add:

```php
                // The run id ai-service confirmed with `kv_agent_run`, and whether `done` arrived.
                $turnRunId = null;
                $sawDone = false;
```

and append `&$turnRunId, &$sawDone, $agentRunId,` to that closure's `use (...)` list.

5. In `case 'message':` replace the `'message' => ['content' => $text, 'type' => ChatMessageType::ASSISTANT],` element of the `$thread->messages()->create([...])` call with:

```php
                                    'message' => array_filter([
                                        'content' => $text,
                                        'type' => ChatMessageType::ASSISTANT,
                                        'agent_run_id' => $turnRunId,
                                    ], static fn ($value) => $value !== null),
```

6. Replace

```php
                        case 'done':
                            break;
```

with

```php
                        case 'kv_agent_run':
                            // ai-service relays the run THIS turn minted; it never names one.
                            $claimed = (string) ($parsedData['run_id'] ?? '');
                            if ($agentRunId === null || ! hash_equals($agentRunId, $claimed)) {
                                Log::warning('kv.agent_run.unexpected_run_id', ['thread_id' => $thread->id, 'claimed' => $claimed]);
                                break;
                            }
                            $turnRunId = $agentRunId;
                            // The frame comes after the assistant row is saved: stamp that row.
                            if ($aiMessage !== null) {
                                $aiMessage->forceFill([
                                    'message' => array_merge((array) $aiMessage->message, ['agent_run_id' => $agentRunId]),
                                ])->save();
                            }
                            $this->emitStreamContent(['type' => 'kv_agent_run', 'run_id' => $agentRunId]);
                            break;

                        case 'done':
                            $sawDone = true;
                            // The turn is over: close the run and free the file for the next one.
                            app(KvAgentRunRecorder::class)->settle($agentRunId);
                            break;
```

7. Replace the fallback block

```php
                // Ensure AI message row exists even if AI_EVENT_COMPLETED was not sent
                if (! $aiMessage && $streamCompleteContent !== '') {
                    $aiMessage = $thread->messages()->create([
                        'message' => [
                            'content' => $streamCompleteContent,
                            'type' => ChatMessageType::ASSISTANT,
                        ],
                        'reply_to' => $newUserMessage->id,
                        'created_at' => now(),
                    ]);
                }
```

with

```php
                // Ensure AI message row exists even if AI_EVENT_COMPLETED was not sent —
                // and for a canvas run whose reply had no text, so its run card survives a reload.
                if (! $aiMessage && ($streamCompleteContent !== '' || $turnRunId !== null)) {
                    $aiMessage = $thread->messages()->create([
                        'message' => array_filter([
                            'content' => $streamCompleteContent,
                            'type' => ChatMessageType::ASSISTANT,
                            'agent_run_id' => $turnRunId,
                        ], static fn ($value) => $value !== null),
                        'reply_to' => $newUserMessage->id,
                        'created_at' => now(),
                    ]);
                }
                if (! $sawDone) {
                    app(KvAgentRunRecorder::class)->fail($agentRunId, 'stream_incomplete');
                }
```

8. In the closure's `catch (\Throwable $e) {` block, as its first statement add:

```php
                app(KvAgentRunRecorder::class)->fail($agentRunId, 'stream_failed');
```

- [ ] **Step 5: Surface `agent_run_id` on hydration**

In `KvGeneratorFileController::show`, inside the `foreach ($messages as $m)` loop, directly before the guard `if (! $role || ! is_string($content) || ($content === '' && ! $hasUserContext)) {` add

```php
                // KV agentic canvas: the run card re-renders from this after a reload.
                $agentRunId = $role === 'assistant' && is_string($msg['agent_run_id'] ?? null) ? $msg['agent_run_id'] : null;
```

change that guard to `if (! $role || ! is_string($content) || ($content === '' && ! $hasUserContext && $agentRunId === null)) {`, and add `'agent_run_id' => $agentRunId,` as the last element of the `$chatHistory[] = [...]` entry.

In `simpleChatHistoryForThread`, replace

```php
                $content = $msg['content'] ?? '';
                if (! $role || ! is_string($content) || trim($content) === '') {
                    return null;
                }

                return [
                    'id' => (string) $m->id,
                    'role' => $role,
                    'text' => $content,
                ];
```

with

```php
                $content = $msg['content'] ?? '';
                $agentRunId = $role === 'assistant' && is_string($msg['agent_run_id'] ?? null) ? $msg['agent_run_id'] : null;
                if (! $role || ! is_string($content) || (trim($content) === '' && $agentRunId === null)) {
                    return null;
                }

                return [
                    'id' => (string) $m->id,
                    'role' => $role,
                    'text' => $content,
                    'agent_run_id' => $agentRunId,
                ];
```

- [ ] **Step 6: Run the test and the existing KV stream tests**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/AgentCanvas/KvAgentCanvasStreamTest.php tests/Feature/Chat/StreamChatKvModeTest.php tests/Feature/Studio/KvGeneratorFileLifecycleTest.php --compact`
Expected: the 8 new tests PASS (one dataset of 2); `StreamChatKvModeTest` matches the Task 1 baseline; `KvGeneratorFileLifecycleTest` has no new failures.

- [ ] **Step 7: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
vendor/bin/pint --dirty --format agent
git add app/Services/Studio/AgentCanvas/KvAgentCanvasTurn.php app/Services/ChatService.php app/Http/Controllers/Api/Studio/KvGeneratorFileController.php tests/Feature/Studio/AgentCanvas/KvAgentCanvasStreamTest.php
git commit -m "feat(api): KV chat turns carry the agent canvas and relay kv_agent_run (C4)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 18: Whole-branch verification

**Files:** none changed (unless a check fails — then fix in the owning task's files and commit with that task's message style).

- [ ] **Step 1: Run every test this plan added, plus the touched baselines, in one process**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
ls bootstrap/cache/config.php bootstrap/cache/routes-v7.php 2>/dev/null   # must list nothing
env DB_CONNECTION=pgsql DB_DATABASE=frnd_test DB_HOST=localhost DB_PORT=5432 TELESCOPE_ENABLED=false vendor/bin/pest \
  tests/Feature/Studio/AgentCanvas tests/Unit/Studio/AgentCanvas tests/Unit/Mcp/KvCanvasToolsTest.php \
  tests/Feature/Studio/UpdateStudioFileOverlaysTest.php tests/Feature/Studio/KvResizeExportControllerTest.php \
  tests/Feature/Chat/StreamChatKvModeTest.php tests/Feature/Studio/KvGeneratorFileLifecycleTest.php tests/Unit/Mcp/DeckTemplateToolsTest.php --compact
```
Expected: every new test PASS in one run (this is what catches two files declaring the same Pest helper function — every helper name in this plan is unique; keep it so); baseline files show only the Task 1 failures.

- [ ] **Step 2: Mirror, style, routes**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api
php artisan mcp:verify-mirror
vendor/bin/pint --test --format agent
php artisan route:list --path=kv/canvas
php artisan route:list --path=agent/runs
php artisan route:list --path=kv-files
```
Expected: `Mirror OK: … (+…)` with 5 more endpoints than the Task 1 baseline; pint reports nothing to fix; routes listed: `GET kv/canvas/{fileId}`, `POST …/layers/update|add|remove`, `POST kv/canvas/runs/{runId}/undo`, `GET|POST studio/files/{fileId}/agent/runs/{runId}[/undo]`, `POST internal/kv-files/{studioFile}/overlays`.

- [ ] **Step 3: If the api is running locally, probe the live server (stale route cache check)**

```bash
for m in GET POST; do echo "$m -> $(curl -so /dev/null -w '%{http_code}' -X $m http://localhost:9191/api/v1/mcp/tools/kv/canvas/x)"; done
```
Expected: `401`/`422`/`404` (auth or lookup), never `405`. A `405` means a stale `bootstrap/cache/routes-v7.php`: delete it, do not restore it.

- [ ] **Step 4: Confirm the tree is clean**

Run: `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && git status --short && git log --oneline develop..HEAD`
Expected: nothing uncommitted; one commit per task 2–17.

---

### Task 19: The one-line CAS note in the spec

**Files:**
- Modify: `/Users/alva.e202511001/Desktop/work/frndos-agentic/docs/superpowers/specs/2026-09-29-kv-agentic-canvas-design.md` (§7.1, the `expected` bullet) — workspace root repo, not `api/`.

- [ ] **Step 1: Add the note under the `expected` bullet of §7.1**

Directly after the line

```
- `expected` is the subset of fields the agent read (compare-and-set). A
  mismatch → 409 `layer_changed {layer_id, expected, current}`.
```

insert

```
  *P1 note:* the api builds `expected` from its own fresh read of the live doc immediately before the write (the read that also yields the ledger pre-image), not from what the agent read at the start of the turn; user work is protected by the undo-time CAS in §8.2 (see `docs/superpowers/plans/2026-09-29-kv-agentic-canvas-p1-contracts.md`).
```

- [ ] **Step 2: Commit in the workspace root repo (its current branch)**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic
git add docs/superpowers/specs/2026-09-29-kv-agentic-canvas-design.md
git commit -m "docs(spec): note P1's write-time CAS reads the live doc itself

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Contract deviations

Each item is an addition or a correction the other three plans must agree with. Nothing in C1–C7 is renamed.

1. **NDJSON discriminator (C4)** — *already amended in the contracts file; listed for traceability.* The frame is `{"event":"kv_agent_run","run_id":…}`, handled as a `case` of the existing `switch ($parsedData['event'])`; the SSE frame to web stays `{"type":"kv_agent_run","run_id":…}`.
2. **Envelope.** C5's wrapped `{"message", "data"}` form is already amended into the contracts. Not yet written there: tool routes (C3) answer `{"data": <contract body>}` (the repo's tool convention, which ai-service `_call` accepts), every error is `{"message", "error": <machine code>, "data": null, ...extra}`, and C2 answers exactly `{"count": n}` as written. *Resolution:* note the C3 envelope in the contracts.
3. **Flag posture (C7).** Fail-closed: `feature.flag:kv-agentic-canvas,off`, and `isEnabledForWorkspace(..., default: false)` wherever middleware cannot see the call (MCP gateway, chat stream). With the contract's default-on spelling, an undefined or unreachable PostHog flag would switch the feature ON in production. *Resolution:* adopt `,off`.
4. **`add_kv_layer` on several boards (C3.5).** One Y.Doc cannot hold the same layer id twice, so the shared id goes to the first board and every size target; each additional board gets its own ULID, reported in its `applied[].layer_id` (its detached sizes use that board's id). *Resolution:* amend C3.5 to "one id per board; sizes share their board's id".
5. **Undo of an MCP run (C3.7).** An MCP run has no stream to settle it, so C6's "completed after 10 min" would make `undo_kv_agent_run` answer 409 for ten minutes after every MCP write. The api completes a running **MCP** run on an undo request and proceeds; an **app** run still answers 409 `run_in_progress` while its turn streams. *Resolution:* amend C3.7.
6. **Undo during a collab outage (C3.7 vs spec §8.2).** The spec's 503 is used: doc reversals are one atomic batch sent first, tile reversals only after it lands, so an outage reverts nothing anywhere and the run stays undoable. `collab_unavailable` therefore never appears in undo `skipped`. *Resolution:* drop `collab_unavailable` from C3.7's skipped reasons, add "503 `collab_unavailable`".
7. **Extra error codes.** 409 `run_mismatch` (an `agent_run_id` belonging to another file or user), 409 `undo_in_progress` (two undos racing), 422 `invalid_input` (shape validation, with `errors`), 422 `invalid_style_key` (with `keys`), 422 `invalid_payload` (a new layer that fails the overlay rules), 503 `collab_unavailable` (`get_kv_canvas` and undo), 404 `not_found`. 409 `run_in_progress` also carries `run_id` of the holder. *Resolution:* add to C3.3/C3.7.
8. **`visible` (C3.4).** The overlay model has `payload.hidden`, so `visible` maps to it (`false` → `hidden: true`; `true` → `hidden: false` only when the key exists). No `unsupported_field` is ever returned. *Resolution:* record the mapping in C3.4.
9. **Ledger/run-view fields (C5/C6).** Each ledger op and skipped entry also stores `target_kind` and `target_label` at write time (the run view needs no second lookup); tile ops store `index` (so an undone remove goes back in place); a `detach_size` op (`layer_id` null, `after` = the frozen snapshot) records each detach. `detached_sizes` stores `{size_id, label}` objects (the C5 shape) while the tool result lists ids (C3.3). *Resolution:* additive; note in C6.
10. **Hydration of `agent_run_id` (C4).** `GET studio/kv-generator/files/{id}` adds `agent_run_id` (string|null) to every `chat_history[]` item and every `kv_chat_history[<mode>][]` item; an assistant row with empty text but a run is kept. *Resolution:* the web plan reads it there.
11. **Inventory details (C3.2).** `style` is filled for text layers only (null for image/shape) and holds only the whitelisted keys; `image_kind` is `logo` when `payload.name` matches `/logo/i`, else `upload` (`product` is not derivable in P1); `overrides` compares identity keys only (`content, asset_url, hidden, color, fontFamily, fontWeight, fontStyle, kind`) because projection legitimately rescales font sizes; board `width`/`height` come from generation metadata or a one-time probe of the image and are `null` if unreadable. *Resolution:* record in C3.2.
12. **Unmeasurable boards.** A size whose board cannot be measured cannot be detached (projection needs pixel sizes), and an add on such a board cannot be placed: both are skipped with the existing reason `target_not_found`.
13. **Run source.** A run created from an internal-token call that carried `agent_run_id` is `app`; every other newly created run (MCP with or without an id) is `mcp`.
14. **`/complete` (C4).** Its only caller (`generate_kv`) sends image mode, so it never carries `agent_canvas`; no change there.
15. **Realtime for size writes.** There is no broadcast channel for resize tiles. A server write to a detached size bumps `updated_at` (Eloquent update in `KvResizeExportService::writeOverlays`), so an open `resize-exports/stream` SSE (`export.updated`, which carries `overlays`) re-sends the row — but that feed is only open while the web watches renders. *Resolution for web:* refetch the file's resize exports on the `kv_agent_run` frame (and on `tool_call` completion of `update_kv_layers` / `add_kv_layer` / `remove_kv_layers`); a push channel for MCP-only writes is P4 scope.
16. **`asset_url` (C3.5).** Accepted only on our own bucket (`DeckAssetHost::isOurs` and `TrustedAssetHost::allows`), because the api fetches it to read its size; anything else is `untrusted_asset_url`. `brand_logo` bytes are copied onto the file's overlay path so the layer never depends on the brand's logo object.

---

## Self-Review (done while writing; recorded for the reviewer)

- **Spec coverage (P1 rows of spec §12, api column):** assembler (Task 9), edit service (11, 13, 14), collab writer (5), normaliser extraction + C2 (2, 3), ledger (4, 10), undo (15), tool controller + MCP twins for read/layer/undo (9, 12–15), chat wiring C4 (17), user routes C5 (16), flag C7 (9, 16), caps §5/§8.1 (9, 11, 12), sanitising §5 (9, `clean`), trusted assets §10 (13), `mcp:verify-mirror` §13 (9, 12–15, 18). P2/P3 (variant boards, sizes, plans, pixel edits) are out of scope by the contracts file.
- **Placeholder scan:** every code step carries the code; no "TBD"/"similar to"; each command has an expected result.
- **Type consistency:** `KvCanvasState::resolveTargets` → `{surfaces, missing}` used by `KvCanvasEditService::execute`; ledger op keys written by `KvCanvasWriteLog` are the ones `KvAgentRun::toView` and `KvAgentRunReverter` read (`type, sink, target, target_kind, target_label, layer_id, before, after, index`); `KvLayerPatchException::$reason` values are C3.3 reasons; tool results are `KvCanvasWriteLog::result()` everywhere.
- **Review Focus:** the five lines each have a test in the owning task (Tasks 11, 11, 11, 11, 15).
