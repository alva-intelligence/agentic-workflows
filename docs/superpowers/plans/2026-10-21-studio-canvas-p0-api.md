# Studio Canvas P0 — API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Register the Studio tool and its brand permission, create the P0 tables (composition, variant, node version, run, Yjs updates), add file create/read endpoints, and add the internal verify endpoint the collab server calls for `studio:` documents.

**Architecture:** Follows the existing KV/Resizer file pattern (`ResizerFileController` + `*FileService` + `StudioFileResource`). Deployed environments get the tool row and permissions from a data migration (seeders never run there). The collab verify endpoint mirrors `InternalSanctumVerifyForKvController` but applies the full file-access check that KV's controller does (workspace, tool slug, brand access, tool permission).

**Tech Stack:** Laravel 13, PHP 8.5, PostgreSQL, Pest, JWT (`JWTAuth`).

**Spec:** `frnd/docs/prd/studio-canvas.md` (FR-20, FR-20a, FR-27, FR-32, NFR-6, NFR-7, §7, §8) and `api/docs/prd/studio-canvas.md` (TASK-1…TASK-4). Collab contract: `2026-10-21-studio-canvas-p0-collab.md`.

## Global Constraints

- Work in `api/` on branch `feature/daffa/vc-studio-canvas`. Never push.
- Tool slug `studio-canvas`; constant `Tool::SLUG_STUDIO_CANVAS`. Name `Studio`, href `/studio/canvas`, pillar `studio`, category `visual`, status `live`, `is_brand_scoped` true, sort_order 0.
- Permission base `brand.studio.studio_canvas` (`.read`, `.write`).
- Feature flag `show-studio-canvas`, fail-closed: routes use `feature.flag:show-studio-canvas,off`.
- KV tables, models and behaviour are untouched (NFR-7). Do not modify `kv_yjs_updates`, `InternalSanctumVerifyForKvController` or `KvStudioFileService`.
- New tables: `ulid('id')->primary()` (except `studio_yjs_updates`, which mirrors `kv_yjs_updates` with `bigIncrements`), `foreignUlid(...)->constrained(...)->cascadeOnDelete()`, `jsonb` for JSON.
- Layers, motion and overrides live in Yjs; the DB columns are server-written snapshots (FR-20a). Column names end in `_snapshot`.
- **Test DB safety (mandatory before every Pest run):** `bootstrap/cache/config.php` is currently cached against the dev DB `frnd`, and RefreshDatabase would wipe it. Run `php artisan config:clear` first, then run Pest only with `DB_CONNECTION=pgsql DB_DATABASE=frnd_studio_test php -d memory_limit=2G vendor/bin/pest <file paths>`. Create the DB once with `createdb -h localhost frnd_studio_test` if it is missing. Pass test file paths, not `--filter`. After testing, run `php artisan optimize` again so the running dev server keeps working.
- If the scratch DB cannot migrate (known: some migrations are pgsql-specific; seeded-DB ordering issues), record the failure in the track file and fall back to Unit tests. Never point tests at `frnd`.
- Commits: `feat(api): …` ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. A user who knows a Studio file id but has no access (other workspace, inaccessible brand, missing `brand.studio.studio_canvas.read`) opens the websocket: the verify endpoint must return 404, never a role. → Task 5 tests.
2. A user with read but not write permission opens a Studio file: collab must receive role `viewer` so the connection is read-only. → Task 5 test `returns viewer for read-only users`.
3. The verify endpoint is called with a KV file id: it must not authorise it as a Studio doc. → Task 5 test `rejects a non-studio file`.
4. The data migration runs twice (re-deploy) or on an environment where an admin already created the row: no duplicate row, existing id kept. → Task 1 test `is idempotent and keeps an existing row id`.
5. Flag off in production: the tool card is not listed and the file routes 404. → Task 2 and Task 4 tests.

---

## File Structure

| File | Responsibility |
|---|---|
| `database/migrations/2026_10_21_120000_add_studio_canvas_tool_and_permissions.php` | Data migration: tool row + permissions |
| `app/Models/Tool.php` | `SLUG_STUDIO_CANVAS` constant |
| `app/Services/BrandRole/ToolPermissionResolver.php` | MAP entry |
| `database/seeders/PermissionsSeeder.php`, `StudioDevelopmentSeeder.php` | Dev seed parity |
| `app/Services/BrandRole/BrandRoleProvisioningService.php` | `FEATURE_PREFIXES` entry |
| `app/Http/Controllers/Api/Studio/StudioToolController.php` | Hide the tool while the flag is off |
| `database/migrations/2026_10_21_120100_create_studio_canvas_tables.php` | Four Studio tables |
| `database/migrations/2026_10_21_120200_create_studio_yjs_updates_table.php` | Yjs update log |
| `app/Models/Studio/{StudioComposition,StudioCompositionVariant,StudioNodeVersion,StudioRun,StudioYjsUpdate}.php` | Models |
| `app/Services/Studio/StudioCanvasFileService.php` | File creation + access check |
| `app/Http/Requests/Studio/CreateStudioCanvasFileRequest.php` | Validation |
| `app/Http/Controllers/Api/Studio/StudioCanvasFileController.php` | `store`, `show` |
| `app/Http/Controllers/Api/Internal/InternalSanctumVerifyForStudioController.php` | Collab verify |
| `routes/api.php` | Routes |

---

### Task 1: Tool row and brand permission

**Files:**
- Create: `database/migrations/2026_10_21_120000_add_studio_canvas_tool_and_permissions.php`
- Modify: `app/Models/Tool.php`, `app/Services/BrandRole/ToolPermissionResolver.php` (MAP), `app/Services/BrandRole/BrandRoleProvisioningService.php` (FEATURE_PREFIXES), `database/seeders/PermissionsSeeder.php` (`.read`/`.write` rows near line 383 + `$brandScopedSlugs` near line 684), `database/seeders/StudioDevelopmentSeeder.php` (tool entry next to kv-generator at line 89)
- Test: `tests/Feature/Studio/StudioCanvasToolMigrationTest.php`

**Interfaces:**
- Produces: `Tool::SLUG_STUDIO_CANVAS = 'studio-canvas'`; `ToolPermissionResolver` MAP `'studio-canvas' => 'brand.studio.studio_canvas'`; permission rows `brand.studio.studio_canvas.read` and `.write` (category `tools`, `is_internal` true, same shape as the resizer rows).
- The migration clones `2026_08_06_100000_add_studio_resizer_image_editor_permissions.php`: raw `DB::table`, manual exists-check (update when present, insert with `Str::ulid()` otherwise), `submenu_id` looked up from `tool_submenus` where `pillar = 'studio'` and `slug = 'visual'`, and the same `flushPermissionCache()` call. `down()` deletes the tool row and both permission rows.

- [ ] **Step 1: Write the failing test** — cases:
  - `creates the studio-canvas tool with the agreed fields` (assert name `Studio`, href `/studio/canvas`, pillar `studio`, category `visual`, status `live`, `is_brand_scoped` true, `submenu_id` = the studio/visual submenu)
  - `creates read and write permissions` (both slugs exist)
  - `is idempotent and keeps an existing row id` (insert a `studio-canvas` row with a known id, run `(require migration path)->up()` twice → one row, same id)
  - `maps the slug in ToolPermissionResolver` (`ToolPermissionResolver::permissionBaseFor('studio-canvas')` returns `brand.studio.studio_canvas`; verify the method name in the class before writing the assertion)
- [ ] **Step 2: Run (after the DB-safety steps), see fail.**
- [ ] **Step 3: Implement the migration, constants and seeder entries.**
- [ ] **Step 4: Run, see 4 pass.**
- [ ] **Step 5: Commit** `feat(api): register studio canvas tool and permissions`

---

### Task 2: Hide the tool while the flag is off

**Files:**
- Modify: `app/Http/Controllers/Api/Studio/StudioToolController.php` (`index(Request $request)`)
- Test: `tests/Feature/Studio/StudioCanvasToolListingTest.php`

**Interfaces:**
- `index` excludes `tools.slug = 'studio-canvas'` unless `FeatureGate::allows('show-studio-canvas', $request->user(), (string) FeatureGate::workspaceIdFor($request->user()), 'off')`.

- [ ] **Step 1: Write the failing test** — `lists the tool outside production` (default test env bypasses flags), and `hides the tool in production when the flag is off` (follow `tests/Feature/Studio/AgentCanvas/KvAgentCanvasIntentFlagTest.php`: partial-mock `FeatureFlagService` so `isEnabledOrDefault` returns false, `app()->detectEnvironment(fn () => 'production')`; GET `/api/v1/studio/tools` → no item with slug `studio-canvas`, kv-generator still listed).
- [ ] **Step 2: Run, see fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, see 2 pass.**
- [ ] **Step 5: Commit** `feat(api): gate studio canvas tool listing behind its flag`

---

### Task 3: Studio tables and models

**Files:**
- Create: `database/migrations/2026_10_21_120100_create_studio_canvas_tables.php`, `database/migrations/2026_10_21_120200_create_studio_yjs_updates_table.php`, `app/Models/Studio/StudioComposition.php`, `StudioCompositionVariant.php`, `StudioNodeVersion.php`, `StudioRun.php`, `StudioYjsUpdate.php`
- Modify: `app/Models/StudioFile.php` (relations `compositions()`, `nodeVersions()`, `runs()`)
- Test: `tests/Feature/Studio/StudioCanvasSchemaTest.php`

**Interfaces (exact columns):**
- `studio_compositions`: `id` ulid pk; `studio_file_id` foreignUlid → studio_files cascade; `node_id` string(26); `base_image_version_id` ulid nullable (no FK — it may point at a `kv_generations` row or a future Studio image version; check `kv_generations.id` type and note it in the model docblock); `layers_snapshot` jsonb default `'[]'`; `motion_snapshot` jsonb nullable; timestamps; unique `[studio_file_id, node_id]`.
- `studio_composition_variants`: `id` ulid pk; `composition_id` foreignUlid → studio_compositions cascade; `width`, `height` unsignedInteger; `platform_id` string(26) nullable (brand size preset id, no FK); `layout_strategy` string default `keep_layers` (`keep_layers` | `ai_regenerate`); `overrides_snapshot` jsonb default `'{}'`; `motion_overrides_snapshot` jsonb default `'{}'`; `status` string default `current` (`current` | `out_of_date` | `generating` | `failed`); `image_url` text nullable; timestamps.
- `studio_node_versions`: `id` ulid pk; `studio_file_id` foreignUlid cascade; `node_id` string(26); `node_type` string(64) (e.g. `text@1`); `version` unsignedInteger; `input_hash` string(64); `output` jsonb default `'{}'`; `cost_credits` decimal(12,4) nullable; `status` string default `pending` (`pending` | `running` | `completed` | `failed`); `created_at` timestampTz useCurrent; unique `[studio_file_id, node_id, version]`.
- `studio_runs`: `id` ulid pk; `studio_file_id` foreignUlid cascade; `user_id` foreignUlid → users; `workspace_id` foreignUlid → workspaces; `node_id` string(26); `mode` string (`single` | `step_by_step` | `downstream`); `status` string default `pending`; `estimated_cost` decimal(12,4) default 0; `actual_cost` decimal(12,4) nullable; `node_versions` jsonb default `'[]'`; timestamps; index `[studio_file_id, created_at]`.
- `studio_yjs_updates`: identical to `2026_07_12_100000_create_kv_yjs_updates_table.php` with the table name changed: `bigIncrements('id')`, `foreignUlid('studio_file_id')->constrained('studio_files')->cascadeOnDelete()`, `binary('update')`, `boolean('is_snapshot')->default(false)`, `timestampTz('created_at')->useCurrent()`, index `['studio_file_id','id']`.
- Models: `HasUlids` (except `StudioYjsUpdate`: `$timestamps = false`, like `KvYjsUpdate`), jsonb columns cast to `array`, decimals cast to `decimal:4`, `belongsTo` back to their parent. Status/mode stay strings in P0 (enums arrive with the run engine in P1).

- [ ] **Step 1: Write the failing test** — `creates the five tables with their columns` (`Schema::hasColumns` per table with the exact names above), `enforces one composition per node per file` (unique violation), `cascades composition rows when the file is force-deleted`, `casts snapshot columns to arrays`.
- [ ] **Step 2: Run, see fail.**
- [ ] **Step 3: Implement migrations and models.**
- [ ] **Step 4: Run, see 4 pass.**
- [ ] **Step 5: Commit** `feat(api): studio canvas tables and models`

---

### Task 4: Studio canvas file create and read

**Files:**
- Create: `app/Services/Studio/StudioCanvasFileService.php`, `app/Http/Requests/Studio/CreateStudioCanvasFileRequest.php`, `app/Http/Controllers/Api/Studio/StudioCanvasFileController.php`
- Modify: `routes/api.php` (inside the existing `Route::prefix('studio')->middleware(['scope_role:internal'])` group near line 5330: a new `Route::middleware('feature.flag:show-studio-canvas,off')->group(...)` with `POST canvas/files` and `GET canvas/files/{id}`)
- Test: `tests/Feature/Studio/StudioCanvasFileControllerTest.php`

**Interfaces:**
- `StudioCanvasFileService::createFile(User $user, string $workspaceId, ?string $brandId, ?string $projectId, ?string $name): StudioFile` — `Tool::where('slug', Tool::SLUG_STUDIO_CANVAS)->firstOrFail()`; name defaults to `Untitled studio`; status `draft`; `metadata` = `['studio_canvas' => ['schema_version' => 1]]`. No thread (Studio has no chat in P0).
- `StudioCanvasFileService::canAccess(User $user, StudioFile $file, string $action = 'read'): bool` — true only when `$file->tool?->slug === Tool::SLUG_STUDIO_CANVAS`, `$file->workspace_id === $user->current_workspace_id`, the brand (if any) is in `Brand::accessibleBy($user->id, $user->current_workspace_id)`, and `$user->canForBrand("brand.studio.studio_canvas.{$action}", $file->brand_id)` (skip the permission check when `brand_id` is null, matching `ToolPermissionResolver::canAccess`). Task 5 reuses this method.
- `CreateStudioCanvasFileRequest` rules: `brand_id` nullable `exists:brands,id`; `project_id` nullable `exists:studio_projects,id`; `name` nullable string max 120. If `project_id` is set, its brand must equal `brand_id` (same check as `KvGeneratorFileController@store`), else 422.
- Controller: `store` → 201 `StudioFileResource`; `show(Request, string $id)` → 404 when the file is missing or `canAccess` is false; else 200 `StudioFileResource`.
- `StudioFileResource` metadata whitelist: add `studio_canvas`.

- [ ] **Step 1: Write the failing test** (setup copied from `KvGeneratorFileLifecycleTest.php` beforeEach, with `Tool::factory()->create(['slug' => 'studio-canvas'])` and the brand permission granted):
  - `creates a studio canvas file` (201, `data.tool.slug` = `studio-canvas`, `data.name` = `Untitled studio`, `data.metadata.studio_canvas.schema_version` = 1)
  - `rejects a project from another brand` (422)
  - `shows the file to its owner`
  - `returns 404 for another workspace's file`
  - `returns 404 for a kv-generator file id` (a KV file must not open as Studio)
  - `returns 404 in production when the flag is off` (same mocking as Task 2)
- [ ] **Step 2: Run, see fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, see 6 pass.**
- [ ] **Step 5: Commit** `feat(api): studio canvas file endpoints`

---

### Task 5: Internal verify endpoint for `studio:` documents

**Files:**
- Create: `app/Http/Controllers/Api/Internal/InternalSanctumVerifyForStudioController.php`
- Modify: `routes/api.php` (internal group near line 7894: `Route::post('sanctum-verify-for-studio', [InternalSanctumVerifyForStudioController::class, 'verify'])->name('internal.sanctum-verify-for-studio');`)
- Test: `tests/Feature/Internal/InternalSanctumVerifyForStudioTest.php` (pattern: `tests/Feature/Insight/InsightPresenceVerifyTest.php`, `JWTAuth::fromUser`)

**Interfaces (contract with collab — do not change names):**
- Request: `POST /api/internal/sanctum-verify-for-studio`, header `X-Internal-Token`, JSON `{ "token": string, "studio_file_id": string (26 chars) }`.
- Responses:
  - 200 `{ "data": { "user_id": string, "workspace_id": string, "role": "owner" | "editor" | "viewer" } }`.
  - `role`: `owner` when `created_by` is the user; otherwise `editor` when `canAccess($user, $file, 'write')`; otherwise `viewer`.
  - 401 for a bad or expired JWT. 404 when the file is missing or `StudioCanvasFileService::canAccess($user, $file, 'read')` is false. 422 for a malformed body. 401 without the internal token (middleware).
- Load the file with `StudioFile::withoutGlobalScopes()->with('tool')->find(...)`, as the KV verify does.

- [ ] **Step 1: Write the failing test** — cases:
  - `verifies the owner` (role `owner`, exact JSON shape)
  - `returns editor for a collaborator with write permission`
  - `returns viewer for read-only users`
  - `rejects a non-studio file` (KV file id → 404)
  - `rejects another workspace's file` (404)
  - `rejects a brand the user cannot access` (404)
  - `rejects a bad token` (401)
  - `requires the internal token` (no header → 401; do not disable the middleware in this one case)
- [ ] **Step 2: Run, see fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, see 8 pass.** Then run every Studio Canvas test file from Tasks 1–5 together.
- [ ] **Step 5: Commit** `feat(api): internal verify endpoint for studio collab docs`

---

## Done when

- All five test files pass on the scratch Postgres DB (or the fallback is recorded in `api/docs/tracks/studio-canvas.track.md`).
- `php artisan route:list --path=studio/canvas` shows the two routes behind `feature.flag:show-studio-canvas,off`, and `--path=internal/sanctum-verify-for-studio` shows the verify route.
- `php artisan optimize` has been re-run so the dev server picks up the new routes (stale route caches 405 new routes).
