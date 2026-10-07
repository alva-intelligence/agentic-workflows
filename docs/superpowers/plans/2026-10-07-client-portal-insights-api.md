# Client Portal — Insights (the brand share dashboard inside the portal) — API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a signed-in client read the brand's Insights dashboard at `public/portal/{workspaceSlug}/{brandSlug}/insight/*` — the same 27 read endpoints the public share link serves — gated by their session and lane instead of the link, showing only the tabs the agency ticked "Clients" for, with agency-internal fields trimmed; the public share link keeps behaving byte-for-byte as today.

**Architecture:** `BrandShareInsightController` stops resolving a positional `$slug`. A new `InsightBrandAccess` seam answers "which brand may this request read" — `ShareLinkBrandAccess` (today's `resolveSlug`, moved verbatim) or `PortalBrandAccess` (the brand `client.session:brand` put on the request) — bound per route group by a new `insight.access:{share|portal}` middleware. On `portal` that middleware also runs the tab guard (`InsightTabGuard`, a map of controller method → Insights tab) against the new `InsightsTabResolver::resolveForClients()`, which reads a new `brand_insights_tab_settings.client_visible` column; a closed tab is the dead-link 404. The controller trims `ideations`, `createdBy` and shared-in reports when the bound access's audience is `client`.

**Tech Stack:** Laravel 13, PHP 8.5, PostgreSQL, Pest 4.

**Spec:** `docs/superpowers/specs/2026-10-07-client-portal-insights-design.md` (workspace root). This plan implements its api half: §3.1–§3.5 and decisions I-1 (api seam), I-2 (column + settings + server-side enforcement), I-3, I-4 (api: Business/Listening are just tab keys — see IR5), I-5. I-6 (Review Signal / Ask a follow-up on the public Overview) is **web-only** and is not in this plan. Builds on `docs/superpowers/specs/2026-10-06-client-portal-from-share-links-design.md` and its plan `docs/superpowers/plans/2026-10-06-client-portal-api.md` (sessions, `client.session:brand`, lanes, PR1–PR22 still hold).

## API contract for web

> **Reconciled with the web plan (2026-10-07, coordinator) — authoritative additions:**
> 1. **Agency "Preview as client" route group (NEW, Task 6b below).** `GET v1/brands/{brand}/client-preview/insight-info` and `v1/brands/{brand}/client-preview/insight/*` mirror the 27 portal insight routes exactly (same methods, same sub-paths), behind the normal authenticated agency stack (`auth:api`, workspace context, `permissions:brand.settings.read` — the same as reading Insights Tabs settings). A third `InsightBrandAccess` implementation, `AgencyPreviewBrandAccess`, takes the brand from the `{brand}` route binding (must be in the caller's workspace → else 404) and reports audience `client`, so the tab guard (client-visible only → else 404) and the client payload trims apply exactly as on the portal. Response shapes are identical to the portal's.
> 2. `insight-info` keeps the public share envelope: `{message, data:{brand_id, brand_name, brand_logo, insights_tab_settings:{resolved}, owned_media_table_view}, is_protected:false}`. Every tab key is always present in `resolved` with `is_visible` = client-visible (IR1); the web treats a missing key as closed for clients.
> 3. Settings: each override row in GET carries `client_visible`; a PUT without the key keeps the stored value; a row carrying only `client_visible: true` survives (IR2).

### Task 6b (reconciliation): agency client-preview route group

Implement after Task 6, in Task 5/6 style: a `AgencyPreviewBrandAccess` class (brand from `$request->route('brand')`, workspace check → 404 via the same abort used by `BrandClientController::inWorkspace`, `audience(): 'client'`); register it for `insight.access:preview`; add the route group `Route::prefix('{brand}/client-preview')` inside the existing authenticated `v1/brands` group with `permissions:brand.settings.read` + `insight.access:preview`, mirroring every portal insight route + `insight-info` (reuse the same controller methods / `PortalController::insightInfo` logic via the access seam). Pest tests (new file `tests/Feature/ClientPortal/InsightPreviewTest.php`): a client-visible tab → 200 with the same body as the portal for the same brand; a hidden tab → 404; another workspace's brand → 404 (build that fixture BEFORE actAsAgency — HasWorkspaceScope trap); route middleware asserts `permissions:brand.settings.read`; trims applied (no `ideations`). Commit `feat(api): agency preview of the client Insights view`.


Everything the web plan relies on. Field names are final. All portal calls carry **`X-Client-Session`** (sent by the web BFF from the `frnd_client` cookie, never from page JavaScript); there is no `X-Share-Token` and no password on the portal. Every portal response carries `Cache-Control: no-store`; every 2xx carries `X-Client-Session-Expires-At` (from `client.session`, unchanged).

### Brand info for the portal Insights shell

**`GET public/portal/{workspaceSlug}/{brandSlug}/insight-info`** → `200`, the **same envelope as the public `GET v1/share/brand/{slug}`** (`BrandShareController::getBrandResponse`), so the web reuses its share-info reader:

```json
{ "message": "Brand info retrieved successfully.",
  "data": {
    "brand_id": "01JABCDEF…",
    "brand_name": "Kopi Kenangan",
    "brand_logo": "https://frnd.s3…/logo.png",
    "insights_tab_settings": { "resolved": {
      "overview":         { "label": "Overview",     "is_visible": false },
      "campaigns":        { "label": "Campaigns",    "is_visible": false },
      "paid-media":       { "label": "Ads",          "is_visible": false },
      "owned-media":      { "label": "Social Media", "is_visible": true  },
      "earned-media":     { "label": "Influencers",  "is_visible": false },
      "atl":              { "label": "ATL",          "is_visible": false },
      "dashboard":        { "label": "Dashboard",    "is_visible": false },
      "signals":          { "label": "Trend radar",  "is_visible": true  },
      "social-listening": { "label": "Listening",    "is_visible": false },
      "business":         { "label": "Business",     "is_visible": false } } },
    "owned_media_table_view": { "visibleColIds": ["post", "sentiment"] } },
  "is_protected": false }
```

- `insights_tab_settings.resolved` = `InsightsTabResolver::resolveForClients()` (IR1): **every** `InsightsTabKey` is present (the web's `resolvedMapToTabs` reads a missing key as visible); `is_visible` = the agency ticked **Clients** for that tab **and** the tab is on in-app; `label` = brand override → global default (never a workspace override — same as the public link).
- `brand_logo` is an absolute URL or `null` (resolved with `PublicBrandLogo::url`, independent of `Accept`).
- `owned_media_table_view` = the brand's `brand_share_settings.owned_media_table_view` whether or not the public link is enabled; `null` when the brand has no share-settings row.
- No `access_token` key (it exists only on the public password response).
- `200` even when no tab is open (every `is_visible: false`): the web hides the **Insights** nav item then.
- `401 {"code":"session_required","message":"Sign in to continue."}` | `404 {"message":"Not found."}` (unknown workspace/brand, no active lane — revoked, expired, client role removed) | `429`.

### The 27 portal insight endpoints

Prefix `public/portal/{workspaceSlug}/{brandSlug}/insight`. Each mirrors `v1/share/brand/{slug}/insight` + the same suffix: **same query parameters, same body, same success payload, same endpoint-level errors** (e.g. `404 {"message":"Signal not found"}`, `404 {"message":"Report not found"}`, `404 {"error":"no_analysis"}`, `404 {"error":"no_playbook"}`, `422` validation, `400` date range, `403 {"message":"Brand mismatch"}`, `400/500` data service) — except the trims below. An endpoint is **open** when any tab in its "Tab" column is client-visible in `insight-info`; otherwise it answers `404 {"message":"Not found."}` before any validation (a closed `POST /reports/query` with an empty body is `404`, not `422`).

| Method | Suffix | Tab (client-visible) |
|---|---|---|
| GET | `/overview` | `overview` |
| GET | `/home` | `overview` |
| GET | `/signals` | `signals` |
| GET | `/signals/{id}` | `signals` |
| GET | `/reports` | `campaigns` |
| GET | `/reports/{reportId}` | `campaigns` |
| POST | `/reports/query` | `campaigns` |
| GET | `/report-templates` | `campaigns` |
| GET | `/campaign` | `campaigns` |
| GET | `/campaign/filters` | `campaigns` |
| GET | `/paid-media/overview` | `paid-media` |
| GET | `/paid-media/detail` | `paid-media` |
| GET | `/paid-media/filters` | `paid-media` |
| GET | `/owned-media/overview` | `owned-media` |
| GET | `/owned-media/detail` | `owned-media` |
| GET | `/owned-media/filters` | `owned-media` |
| GET | `/owned-media/sentiment` | `owned-media` |
| GET | `/owned-media/label-attributes` | `owned-media` |
| GET | `/owned-media/creative/playbooks` | `owned-media`; with `?tab=ads` → `paid-media` |
| GET | `/owned-media/creative/playbook` | `owned-media`; with `?tab=ads` → `paid-media` |
| GET | `/owned-media/content/{content_id}/creative-analysis` | `owned-media` **or** `paid-media` |
| GET | `/earned-media` | `earned-media` |
| GET | `/earned-media/influencers` | `earned-media` |
| GET | `/earned-media/filters` | `earned-media` |
| GET | `/atl/overview` | `atl` |
| GET | `/atl/detail` | `atl` |
| GET | `/atl/filters` | `atl` |

`business`, `social-listening` and `dashboard` have no api endpoint (Business and Listening render sample data in the web); their client visibility only drives the nav through `insight-info`. **The web must not call an endpoint of one tab from another tab's page** — it is closed whenever that other tab is.

Errors on every portal insight route: `401 session_required` (missing/dead session) | `404 {"message":"Not found."}` (unknown brand, no active lane, **tab not client-visible**) | `429` (`throttle:public-portal`, 120/min per session, shared with the Approvals inbox). There is never a `403 {"message":"Authentication required."}` on the portal.

### Client payload trims (portal only; the public link is unchanged)

- `GET …/signals`: every `data.data[*]` item and `hero_spotlight` have **no `ideations` key**. `GET …/signals/{id}`: `data` has no `ideations` key.
- `GET …/reports`: only reports the brand owns (`brandId` = the brand) — a report another brand shared **into** this one is never listed; `sharingContext` is always `{"isOwned": true}`; items have **no `createdBy` key**. `meta.total` counts owned reports only.
- `GET …/reports/{reportId}`: a shared-in report → `404 {"message":"Report not found"}`; `data` has **no `createdBy` key**.

### Insights Tabs settings (agency, changed — additive)

**`GET v1/brands/{brand}/insights-tab-settings`** (`permissions:brand.settings.read`, unchanged) → each override row gains `client_visible: boolean`:

```json
{ "data": { "overrides": {
  "signals":     { "label": null,      "is_visible": null, "client_visible": true },
  "owned-media": { "label": "Socials", "is_visible": true, "client_visible": false } } } }
```

A tab with no row is `client_visible: false` (the web defaults it).

**`PUT v1/brands/{brand}/insights-tab-settings`** (`permissions:brand.settings.write`, unchanged) — body `overrides.<tab_key>.client_visible?: boolean`:
- absent → the row keeps its current value (a new row starts `false`) — today's web, which never sends the key, closes nothing;
- `null` or a non-boolean → `422` with `errors["overrides.<tab_key>.client_visible"]`;
- a row is deleted only when `label` and `is_visible` are both `null` **and** `client_visible` is `false` (before: both `null`);
- a ticked tab that is hidden in-app (brand `is_visible: false`, or hidden workspace-wide) stays closed to clients — the web should show the Clients toggle disabled with a hint in that case.

**`GET|PUT v1/workspace/insights-tab-settings`** — unchanged (no `client_visible` at workspace scope; a workspace-scope body carrying it is still `422`).

## Rulings

Spec ambiguities resolved here; Task 8 copies this and the contract above into the contract notes.

- **IR1 — `resolveForClients(Brand)`:** labels fold brand → global (like `resolveForPublicShare`; a client is outside the workspace, so workspace-internal tab names never reach them). `is_visible` = brand row `client_visible` **AND** the in-app visibility (`resolveForBrand`: brand → workspace → global). "The tab otherwise valid" in spec §3.1 is read as "on in-app". Every `InsightsTabKey` is present.
- **IR2 — `client_visible` is brand-scope only**, `boolean NOT NULL DEFAULT false`. In a PUT row: absent = keep, `null`/non-boolean = 422. Delete rule: `label === null && is_visible === null && client_visible === false`.
- **IR3 — The seam:** interface `App\Services\Insights\InsightBrandAccess` (`brandFor(Request): Brand`, `audience(): 'public'|'client'`); the `insight.access:{share|portal}` middleware puts the group's implementation on the request (attribute keyed `InsightBrandAccess::class`). `ShareLinkBrandAccess::brandFor()` throws `HttpResponseException` carrying today's exact bodies, and the controller calls it where `resolveSlug()` ran (after FormRequest validation, before `withExceptionHandling()`), so public behaviour — status, body and ordering — is unchanged.
- **IR4 — The tab guard runs in the middleware**, not the controller: the controller's FormRequests (`BrandTrendSignalIndexRequest`, `QueryReportRequest`) validate before the method body, so a guard in the body would answer a closed tab with `422`. The map is `InsightTabGuard::TABS`, keyed by the controller method the route calls. A method missing from the map is **closed** to clients (fail closed); a route-table test keeps the map complete.
- **IR5 — Endpoint → tab:** see the contract table. Two departures from the spec's prefix rule, both read from the web: the Ads tab calls `owned-media/creative/playbook(s)` with `tab=ads` (→ `paid-media`), and the post analysis endpoint serves both tabs (→ `owned-media` or `paid-media`). Business and Listening have no api endpoints (web sample data), so I-4's "Sample data" label is web-only and they need no guard entry.
- **IR6 — Portal throttle = `throttle:public-portal` only** (spec §3.3). The share routes' `throttle:share-owned-label-filter` is **not** mirrored: it keys on `{slug}` (absent here) and then the IP, which on the portal is the web BFF's — one bucket for every client.
- **IR7 — `insight-info`** is the public share-info envelope verbatim (contract above). It lives on `PortalController::insightInfo()` in the existing brand-scoped group. Its keys are pinned against the public response in a test, so the two cannot drift.
- **IR8 — Trims are exactly spec I-5:** `ideations` (signal list items, `hero_spotlight`, detail), `createdBy` (report list + detail), shared-in reports (list excluded, detail 404). Other agency-ish fields (`operator_notes`, `operator_score`, `is_bookmarked`, `status`, `user_id` on signals; `owner` on reports) are served to clients exactly as the public link serves them today — flagged for Daffa, not changed.
- **IR9 — One "no":** unknown brand, no active lane and closed tab are all `404 {"message":"Not found."}` (enumeration-safe, PR rule from the portal plan).
- **IR10 — No access-level check** (I-3): `own`, `all_approve` and `all_view` read the same tabs.

## Global Constraints

- **Repo + shell:** every command runs in the existing worktree `/Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal` on branch `feature/daffa/vc-client-portal`. Agent shells reset cwd, so every shell call starts with `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && `. Paths below are relative to that root unless absolute. The shell is zsh; an `rtk` hook rewrites `grep`/`git` output, so commands use `/usr/bin/grep` and `/usr/bin/git`. Daffa's dev api on :9191 serves the main `api/` checkout — never edit it, and never touch `web/`.
- **Never commit on `develop`. Never push, never open a PR** (Daffa decides). **Never `git stash`.**
- **Commit messages:** `<type>(api): …`, **no attribution trailer** (`api/AGENTS.md` forbids it; the repo rule wins over the session default).
- **Test permission:** Daffa granted permission (2026-10-07) to run Pest on `frnd_testing` for this feature. It covers exactly: the baseline files of Task 0 and the new/changed files `tests/Unit/Services/InsightsTabResolverTest.php`, `tests/Feature/Brand/BrandInsightsTabClientVisibilityTest.php`, `tests/Feature/Share/BrandShareInsightCharacterizationTest.php`, `tests/Feature/ClientPortal/PortalInsightsTest.php`. Anything else needs a new ask.
- **Test DB = `frnd_testing`. Never `frnd`** (the dev DB; the worktree `.env` points at it). `tests/TestCase.php` refuses any DB without a `test` token. Every test command has this exact shape — `test ! -e` aborts the chain when a cached config would override the exported DB vars (it wiped the dev DB twice), and the stale route cache is deleted, never restored (it 405s new routes):
  `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest <file> [<file> …] --compact`
  If `test ! -e` stops the chain, run `php artisan config:clear` and retry. **File paths only**, one Pest process at a time; `--filter` only together with a file path (the suite mapper dies on `tests/Feature/Report/ReportQueryMultiBrandTest.php` otherwise). `TELESCOPE_ENABLED=false` is required (Telescope OOMs migrations); `-d memory_limit=2G` because 128M OOMs while loading routes.
- **Tests in this plan were written from reading the code, not from running it** (lesson: six such tests proved defective in one feature). For every test: run it BEFORE the implementation step and confirm it fails *for the stated reason* (not a typo, not a fixture error) — the Task 3 characterization tests are the exception: they must PASS on unchanged code. After it passes, apply the task's **named mutation**, watch the named test fail, restore, re-run green. If an assertion fails on UNCHANGED production code where the plan expected a pass (JSON paths, key order, labels, a fixture the factory shapes differently), dump the actual value, confirm it by reading the code, correct the expectation — never weaken the behaviour under test — and log the correction in the track file.
- **Fixture traps found in this suite (2026-10-07):** (a) `HasWorkspaceScope` (on `Brand`, `BrandTrendSignal`, …) stamps a newly saved model with the **signed-in** user's workspace — build every "other workspace / other brand" fixture BEFORE `ClientLaneFixtures::actAsAgency()`; the portal tests in this plan never sign in an agency user. (b) Laravel checks every throttle limit before hitting any, so a rejected request counts toward no bucket — keep each portal test under 119 requests per session and never write a test that relies on a 429.
- **No global functions in test files** (Pest loads every file of a run into one process; `tests/Feature/BrandSharePublicCreativeTest.php` already declares `makeShareLink()` and `shareToken()`). Use closures on `$this`. **No `uses()` in new Feature files** (`tests/Pest.php` binds `TestCase` + `RefreshDatabase` for `Feature`). Per-request headers are passed as the headers argument (`getJson($uri, $headers)`), never `withHeader()`.
- **No real HTTP from tests:** `tests/Feature/ClientPortal/PortalInsightsTest.php` does `Http::fake(['*' => Http::response(['message' => 'stubbed'], 503)])` in `beforeEach`, so an endpoint that wrongly reaches the data service fails fast (a `400`/`500`, never the guard's `404 {"message":"Not found."}`) instead of calling Daffa's local data service.
- **Gates at every commit:** `php -l` on each touched PHP file; `vendor/bin/pint <touched files>` then `vendor/bin/pint --test <touched files>` must pass.
- **Enumeration safety:** every "no" on a portal route is `401 session_required` or `404 {"message":"Not found."}`. Never `abort(404)` on a portal route (its body varies).
- **Validation and nested payloads:** `UpdateBrandInsightsTabSettingsRequest` has `overrides.*.label` / `overrides.*.is_visible` sub-rules, so `validated()` rebuilds each row from the listed sub-keys only (`excludeUnvalidatedArrayKeys`). `client_visible` therefore needs its own `overrides.*.client_visible` rule **and** a place in `array:label,is_visible,client_visible`, or it is silently dropped.
- Line numbers cite the worktree at `4341acfec` as read on 2026-10-07. Earlier tasks shift them — re-read each file before editing and anchor edits on the quoted code.

## Review Focus

1. **Today's web saves Insights Tabs settings without `client_visible`** (every PUT until the web ships). It must not close the tabs an agency opened for clients, and a row that only carries the Clients tick must survive a save that clears its label and visibility. → Task 2, test "a save without client_visible keeps the current value (today's web)".
2. **The Ads tab reads its creative playbooks and post analyses through `owned-media/…` URLs.** A client with only Ads open must get Ads playbooks and analyses; a client with only Social Media open must not get Ads playbooks. → Task 5, test "the Ads tab opens the ads playbooks and the post analysis, never the Social Media ones" and the `ads playbooks` / `ads playbook` dataset rows.
3. **A tab the agency hid in-app (for the brand, or workspace-wide) but ticked for clients.** It must stay closed in the portal and read `is_visible: false` in `insight-info`. → Task 1 unit test (workspace-wide + brand), Task 5 test "every access level reads opened tabs; a tab hidden in-app stays closed even when ticked".
4. **A client is removed (lane revoked) while their Insights page is open.** The next insight call and `insight-info` must be the one 404, never data. → Task 5 test "Insights needs a session and an active lane…", Task 6 test "insight-info needs a session and an active lane…".
5. **A public share link with a password, opened by `?share_token=` (not the header), and a disabled link, after the controller refactor.** Same 200 / same 403 / same 404 bodies, and validation still answers before the link check on `POST reports/query`. → Task 3 tests (run before and after Task 4).

---

## File Structure

Create:
- `database/migrations/2026_10_07_110000_add_client_visible_to_brand_insights_tab_settings.php` — the column.
- `app/Services/Insights/InsightBrandAccess.php` — the seam (interface + audience constants).
- `app/Services/Insights/ShareLinkBrandAccess.php` — public link: slug + `link_enabled` + password token.
- `app/Services/Insights/PortalBrandAccess.php` — the brand `client.session:brand` resolved.
- `app/Services/Insights/InsightTabGuard.php` — controller method → tab(s); `isOpenToClients()`.
- `app/Http/Middleware/UseInsightBrandAccess.php` — alias `insight.access`; binds the seam, runs the client tab guard.
- Tests: `tests/Feature/Brand/BrandInsightsTabClientVisibilityTest.php`, `tests/Feature/Share/BrandShareInsightCharacterizationTest.php`, `tests/Feature/ClientPortal/PortalInsightsTest.php`.

Modify:
- `app/Models/BrandInsightsTabSetting.php` (fillable, cast, docblock).
- `app/Services/InsightsTabResolver.php` (`resolveForClients`).
- `app/Http/Requests/UpdateBrandInsightsTabSettingsRequest.php` (rules), `app/Http/Controllers/Api/Brand/BrandInsightsTabSettingsController.php` (`update`), `app/Http/Resources/BrandInsightsTabSettingsResource.php` (`client_visible`).
- `app/Http/Controllers/Api/Share/BrandShareInsightController.php` (seam, sub-ids from the route, trims).
- `app/Http/Controllers/Api/ClientPortal/PortalController.php` (`insightInfo`).
- `bootstrap/app.php` (alias), `routes/api.php` (share group middleware, portal insight group, `insight-info`).
- `tests/Unit/Services/InsightsTabResolverTest.php` (+1 test).
- `docs/prd/client-lane-p0a/api.md` (contract notes), `docs/tracks/client-portal.track.md` (Insights section).

---

### Task 0: Pre-flight — worktree, caches, DB, baseline

**Files:** none changed.

**Interfaces:**
- Consumes: nothing.
- Produces: an up-to-date worktree and the baseline failure list every later task compares against.

- [ ] **Step 1: Worktree is clean and current**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && /usr/bin/git status --short && /usr/bin/git branch --show-current && /usr/bin/git pull --ff-only && /usr/bin/git log --oneline -1
```

Expected: no `status` lines; `feature/daffa/vc-client-portal`; `Already up to date.` or a fast-forward; HEAD at or after `4341acfec`. If `status` prints anything or the pull is not a fast-forward: STOP and ask Daffa (AskUserQuestion) — never stash, never reset.

- [ ] **Step 2: Caches, vendor, env, DB**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && ls bootstrap/cache/config.php bootstrap/cache/routes-v7.php 2>/dev/null; ls vendor/autoload.php .env && psql -lqt | cut -d'|' -f1 | /usr/bin/grep -w frnd_testing
```

Expected: no cache file listed (if one is: `php artisan config:clear`, `rm -f bootstrap/cache/routes-v7.php`); `vendor/autoload.php` and `.env` listed (if `vendor/` is missing: `composer install --no-interaction --quiet`); `frnd_testing` printed (if missing: `psql -d postgres -c 'CREATE DATABASE frnd_testing'`).

- [ ] **Step 3: Baseline run (one process)**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/BrandSharePublicCreativeTest.php tests/Feature/BrandSharePublicRoutesTest.php tests/Unit/Http/Requests/InsightsTabSettingsRequestTest.php tests/Unit/Services/InsightsTabResolverTest.php tests/Feature/ClientPortal/ActiveLaneTest.php tests/Feature/ClientPortal/AddClientTest.php tests/Feature/ClientPortal/AgencyClientsTest.php tests/Feature/ClientPortal/ClientSessionTest.php tests/Feature/ClientPortal/PortalInboxTest.php tests/Feature/ClientPortal/RequestPageSessionTest.php tests/Feature/ClientPortal/ReservedWorkspaceSlugTest.php --compact
```

Expected: a pass/fail summary. Write every failing test name into a scratch note (it goes into the track file in Task 8). These are **pre-existing**: later tasks must not add to them and must not "fix" them. If the run dies in `migrate:fresh`, STOP and report.

- [ ] **Step 4: No commit** (nothing tracked changed).

---

### Task 1: `client_visible` column, model, and `resolveForClients()`

**Files:**
- Create: `database/migrations/2026_10_07_110000_add_client_visible_to_brand_insights_tab_settings.php`
- Modify: `app/Models/BrandInsightsTabSetting.php` (fillable, casts, class docblock)
- Modify: `app/Services/InsightsTabResolver.php` (new public method after `resolveForPublicShare`)
- Test: `tests/Unit/Services/InsightsTabResolverTest.php` (append one test)

**Interfaces:**
- Consumes: `InsightsTabResolver::resolve(iterable $brandRows, ?Workspace $workspace): array` (existing).
- Produces: column `brand_insights_tab_settings.client_visible` (`boolean`, not null, default `false`); `BrandInsightsTabSetting::$client_visible` (cast `bool`, fillable); `InsightsTabResolver::resolveForClients(Brand $brand): array<string, array{label: string, is_visible: bool}>` — every `InsightsTabKey::values()` key, in enum order.

- [ ] **Step 1: Write the failing test** — append to `tests/Unit/Services/InsightsTabResolverTest.php` (keep the existing two tests; add these imports at the top: `use App\Enums\InsightsTabKey;`, `use App\Models\Brand;`, `use App\Models\Workspace;`, `use App\Models\WorkspaceInsightsTabSetting;`, `use Illuminate\Database\Eloquent\Collection as EloquentCollection;`)

```php
/*
 * Mutation checks (plan Task 1, Step 5):
 * - fold labels with `$this->resolve($brandRows, $workspace)` → fails at `paid-media` (label `Q3 push`);
 * - drop `&& $inApp[$key]['is_visible']` → fails at `atl` and `campaigns` (true);
 * - default an untouched tab to open (`$ticked[$key] ?? true`) → fails at `overview`.
 */
it('opens a tab to clients only when the agency ticked it and the tab is on in-app, without workspace labels', function () {
    $workspace = new Workspace;
    $workspace->setRelation('insightsTabSettings', new EloquentCollection([
        (new WorkspaceInsightsTabSetting)->forceFill(['tab_key' => 'atl', 'label' => 'Above the line', 'is_visible' => false]),
        (new WorkspaceInsightsTabSetting)->forceFill(['tab_key' => 'paid-media', 'label' => 'Q3 push', 'is_visible' => null]),
    ]));

    $brand = new Brand;
    $brand->setRelation('workspace', $workspace);
    $brand->setRelation('insightsTabSettings', new EloquentCollection([
        (new BrandInsightsTabSetting)->forceFill(['tab_key' => 'signals', 'label' => 'Trend radar', 'is_visible' => null, 'client_visible' => true]),
        (new BrandInsightsTabSetting)->forceFill(['tab_key' => 'atl', 'label' => null, 'is_visible' => null, 'client_visible' => true]),
        (new BrandInsightsTabSetting)->forceFill(['tab_key' => 'paid-media', 'label' => null, 'is_visible' => true, 'client_visible' => true]),
        (new BrandInsightsTabSetting)->forceFill(['tab_key' => 'campaigns', 'label' => null, 'is_visible' => false, 'client_visible' => true]),
        (new BrandInsightsTabSetting)->forceFill(['tab_key' => 'owned-media', 'label' => 'Socials', 'is_visible' => true, 'client_visible' => false]),
    ]));

    $resolved = (new InsightsTabResolver)->resolveForClients($brand);

    expect(array_keys($resolved))->toBe(InsightsTabKey::values())
        // Ticked, on in-app, brand label.
        ->and($resolved['signals'])->toBe(['label' => 'Trend radar', 'is_visible' => true])
        // Ticked, but the WORKSPACE hides ATL in-app; its label never leaks.
        ->and($resolved['atl'])->toBe(['label' => 'ATL', 'is_visible' => false])
        // Ticked and on; the workspace label "Q3 push" never leaks.
        ->and($resolved['paid-media'])->toBe(['label' => 'Ads', 'is_visible' => true])
        // Ticked, but the BRAND hides Campaigns in-app.
        ->and($resolved['campaigns'])->toBe(['label' => 'Campaigns', 'is_visible' => false])
        // On in-app, not ticked.
        ->and($resolved['owned-media'])->toBe(['label' => 'Socials', 'is_visible' => false])
        // No row at all: closed.
        ->and($resolved['overview'])->toBe(['label' => 'Overview', 'is_visible' => false]);
});
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Unit/Services/InsightsTabResolverTest.php --compact
```

Expected: the new test FAILS with `Call to undefined method App\Services\InsightsTabResolver::resolveForClients()`; the two existing tests pass.

- [ ] **Step 3: Write the migration** — `database/migrations/2026_10_07_110000_add_client_visible_to_brand_insights_tab_settings.php`

```php
<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Client portal — Insights (spec 2026-10-07 §3.1, I-2): the agency's
 * per-tab "Clients" tick. Independent of the public share link and of the
 * in-app visibility; default OFF (least privilege), so every existing row
 * stays closed to clients.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('brand_insights_tab_settings', function (Blueprint $table) {
            $table->boolean('client_visible')->default(false);
        });
    }

    public function down(): void
    {
        Schema::table('brand_insights_tab_settings', function (Blueprint $table) {
            $table->dropColumn('client_visible');
        });
    }
};
```

- [ ] **Step 4: Model + resolver**

In `app/Models/BrandInsightsTabSetting.php`, replace the class docblock's first paragraph line `* Per-brand Insights tab label + visibility override row.` with:

```php
 * Per-brand Insights tab label + visibility override row, plus the
 * agency's "Clients" tick (`client_visible`, client portal Insights spec
 * 2026-10-07 — never NULL, default false; read by
 * InsightsTabResolver::resolveForClients()).
```

Add `'client_visible',` to `$fillable` after `'is_visible',`, and `'client_visible' => 'boolean',` to `casts()` after `'is_visible' => 'boolean',`.

In `app/Services/InsightsTabResolver.php`, insert after `resolveForPublicShare()`:

```php
    /**
     * Client portal variant (client portal Insights spec 2026-10-07 §3.1,
     * ruling IR1).
     *
     * Labels fold **brand → global** like {@see resolveForPublicShare()}: a
     * client is outside the workspace, so workspace-internal tab names never
     * reach them. `is_visible` is true only when the agency ticked "Clients"
     * on the brand row (`client_visible`) AND the tab is on in-app
     * ({@see resolveForBrand()}: brand → workspace → global) — a tab hidden
     * for the brand or workspace-wide stays closed to clients. Every
     * InsightsTabKey is present: the web reads a missing key as visible.
     *
     * @return array<string, array{label: string, is_visible: bool}>
     */
    public function resolveForClients(Brand $brand): array
    {
        $brandRows = $brand->relationLoaded('insightsTabSettings')
            ? $brand->getRelation('insightsTabSettings')
            : $brand->insightsTabSettings()->get();

        $workspace = $brand->relationLoaded('workspace')
            ? $brand->getRelation('workspace')
            : $brand->workspace()->first();

        $labelled = $this->resolve($brandRows, null);
        $inApp = $this->resolve($brandRows, $workspace);

        $ticked = [];
        foreach ($this->indexByTabKey($brandRows) as $key => $row) {
            $ticked[$key] = (bool) $row->client_visible;
        }

        foreach ($labelled as $key => $tab) {
            $labelled[$key]['is_visible'] = ($ticked[$key] ?? false) && $inApp[$key]['is_visible'];
        }

        return $labelled;
    }
```

- [ ] **Step 5: Run the test, then the named mutations**

Run the Step 2 command. Expected: 3 passed. Then apply each mutation from the comment block, run, watch "opens a tab to clients only…" fail at the named key, restore, re-run green.

- [ ] **Step 6: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && for f in database/migrations/2026_10_07_110000_add_client_visible_to_brand_insights_tab_settings.php app/Models/BrandInsightsTabSetting.php app/Services/InsightsTabResolver.php tests/Unit/Services/InsightsTabResolverTest.php; do php -l $f || exit 1; done && vendor/bin/pint database/migrations/2026_10_07_110000_add_client_visible_to_brand_insights_tab_settings.php app/Models/BrandInsightsTabSetting.php app/Services/InsightsTabResolver.php tests/Unit/Services/InsightsTabResolverTest.php && vendor/bin/pint --test database/migrations/2026_10_07_110000_add_client_visible_to_brand_insights_tab_settings.php app/Models/BrandInsightsTabSetting.php app/Services/InsightsTabResolver.php tests/Unit/Services/InsightsTabResolverTest.php && /usr/bin/git add database/migrations/2026_10_07_110000_add_client_visible_to_brand_insights_tab_settings.php app/Models/BrandInsightsTabSetting.php app/Services/InsightsTabResolver.php tests/Unit/Services/InsightsTabResolverTest.php && /usr/bin/git commit -m "feat(api): Insights tabs can be opened for clients — client_visible and resolveForClients"
```

---

### Task 2: Insights Tabs settings read and write `client_visible`

**Files:**
- Modify: `app/Http/Requests/UpdateBrandInsightsTabSettingsRequest.php` (`rules()`, class docblock body shape)
- Modify: `app/Http/Controllers/Api/Brand/BrandInsightsTabSettingsController.php` (`update()` loop)
- Modify: `app/Http/Resources/BrandInsightsTabSettingsResource.php` (`toArray()`, docblock)
- Test: `tests/Feature/Brand/BrandInsightsTabClientVisibilityTest.php`

**Interfaces:**
- Consumes: `BrandInsightsTabSetting::$client_visible` (Task 1).
- Produces: `GET|PUT v1/brands/{brand}/insights-tab-settings` with `client_visible` per row (contract "Insights Tabs settings").

- [ ] **Step 1: Write the failing tests** — `tests/Feature/Brand/BrandInsightsTabClientVisibilityTest.php`

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Http\Middleware\CheckPermissions;
use App\Models\BrandInsightsTabSetting;
use Tests\Support\ClientLaneFixtures;

/**
 * Client portal Insights (spec 2026-10-07 §3.1, I-2): Brand Settings →
 * Insights Tabs reads and writes the per-tab "Clients" tick. `permissions:`
 * is stripped (its wiring is asserted on the routes); the FormRequest's
 * workspace check and the controller run.
 */
beforeEach(function () {
    $this->f = ClientLaneFixtures::deck();
    $this->brand = $this->f['brand'];
    $this->url = "/api/v1/brands/{$this->brand->id}/insights-tab-settings";

    ClientLaneFixtures::actAsAgency($this, $this->f['user']);
    $this->withoutMiddleware([CheckPermissions::class]);
});

/*
 * Mutation checks (plan Task 2, Step 5):
 * - drop `&& ! $clientVisible` from the delete condition → "ticking Clients…" fails (the signals row is deleted);
 * - drop the `overrides.*.client_visible` rule (keep the array: list) → "ticking Clients…" fails (validated() strips the key);
 * - treat an absent key as false (`: false`) → "a save without client_visible…" fails at `client_visible`;
 * - drop `'client_visible' => …` from the resource → "ticking Clients…" fails on the row shape.
 */
test('ticking Clients on a tab with no other override keeps a row, and GET reads it back', function () {
    $this->putJson($this->url, ['overrides' => [
        'signals' => ['label' => null, 'is_visible' => null, 'client_visible' => true],
        'owned-media' => ['label' => 'Socials', 'is_visible' => true, 'client_visible' => false],
    ]])->assertOk()
        ->assertJsonPath('data.overrides.signals', ['label' => null, 'is_visible' => null, 'client_visible' => true])
        ->assertJsonPath('data.overrides.owned-media', ['label' => 'Socials', 'is_visible' => true, 'client_visible' => false]);

    $this->getJson($this->url)->assertOk()
        ->assertJsonPath('data.overrides.signals.client_visible', true)
        ->assertJsonPath('data.overrides.owned-media.label', 'Socials')
        ->assertJsonPath('data.overrides.owned-media.client_visible', false);

    expect(BrandInsightsTabSetting::query()->where('brand_id', $this->brand->id)->where('tab_key', 'signals')->value('client_visible'))->toBeTrue();
});

test("a save without client_visible keeps the current value (today's web)", function () {
    BrandInsightsTabSetting::query()->create(['brand_id' => $this->brand->id, 'tab_key' => 'atl', 'client_visible' => true]);

    $this->putJson($this->url, ['overrides' => ['atl' => ['label' => 'Above the line', 'is_visible' => true]]])
        ->assertOk()
        ->assertJsonPath('data.overrides.atl', ['label' => 'Above the line', 'is_visible' => true, 'client_visible' => true]);

    // Clearing the label and the visibility keeps the row while Clients is ticked.
    $this->putJson($this->url, ['overrides' => ['atl' => ['label' => null, 'is_visible' => null]]])
        ->assertOk()
        ->assertJsonPath('data.overrides.atl', ['label' => null, 'is_visible' => null, 'client_visible' => true]);
});

test('unticking Clients on an otherwise empty row deletes it', function () {
    BrandInsightsTabSetting::query()->create(['brand_id' => $this->brand->id, 'tab_key' => 'atl', 'client_visible' => true]);

    $response = $this->putJson($this->url, ['overrides' => ['atl' => ['label' => null, 'is_visible' => null, 'client_visible' => false]]])
        ->assertOk();

    expect($response->json('data.overrides'))->toBe([])
        ->and(BrandInsightsTabSetting::query()->where('brand_id', $this->brand->id)->exists())->toBeFalse();
});

test('client_visible must be a boolean when sent', function () {
    $this->putJson($this->url, ['overrides' => ['signals' => ['client_visible' => 'yes']]])
        ->assertStatus(422)
        ->assertJsonValidationErrors(['overrides.signals.client_visible']);

    $this->putJson($this->url, ['overrides' => ['signals' => ['client_visible' => null]]])
        ->assertStatus(422)
        ->assertJsonValidationErrors(['overrides.signals.client_visible']);

    expect(BrandInsightsTabSetting::query()->where('brand_id', $this->brand->id)->exists())->toBeFalse();
});

test('the settings routes keep their Brand Settings permissions', function () {
    $middleware = collect(app('router')->getRoutes()->getRoutes())
        ->filter(fn ($route) => $route->uri() === 'api/v1/brands/{brand}/insights-tab-settings')
        ->mapWithKeys(fn ($route) => [$route->methods()[0] => $route->gatherMiddleware()]);

    expect($middleware['GET'])->toContain('permissions:brand.settings.read')
        ->and($middleware['PUT'])->toContain('permissions:brand.settings.write');
});
```

- [ ] **Step 2: Run to verify they fail**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/Brand/BrandInsightsTabClientVisibilityTest.php --compact
```

Expected: "ticking Clients…" FAILS with a `422` (`overrides.*` is `array:label,is_visible`, so `client_visible` is an unknown key); "a save without…" FAILS on the row shape (no `client_visible` in the resource); "unticking…" FAILS with a `422`; "client_visible must be a boolean…" FAILS — the first PUT is a `422` for the wrong key (`overrides.signals`, not `overrides.signals.client_visible`); the permissions test PASSES (characterization).

- [ ] **Step 3: Implement**

`app/Http/Requests/UpdateBrandInsightsTabSettingsRequest.php` — in the class docblock body shape, replace `*         "<tab_key>": { "label": string|null, "is_visible": bool|null },` with `*         "<tab_key>": { "label": string|null, "is_visible": bool|null, "client_visible"?: bool },`. In `rules()`, replace:

```php
            'overrides.*' => ['array:label,is_visible'],
            'overrides.*.label' => ['nullable', 'string', 'max:24'],
            'overrides.*.is_visible' => ['nullable', 'boolean'],
```

with:

```php
            'overrides.*' => ['array:label,is_visible,client_visible'],
            'overrides.*.label' => ['nullable', 'string', 'max:24'],
            'overrides.*.is_visible' => ['nullable', 'boolean'],
            // Client portal Insights (spec 2026-10-07, ruling IR2): absent =
            // keep the stored value; null is refused. This rule is also what
            // keeps the key in validated() — every `overrides.*` row is
            // rebuilt from its listed sub-keys only.
            'overrides.*.client_visible' => ['sometimes', 'boolean'],
```

`app/Http/Controllers/Api/Brand/BrandInsightsTabSettingsController.php` — update the class docblock sentence `Rows with both \`label\` AND \`is_visible\` NULL are deleted server-side (FR-10 / AC-16).` to `Rows with both \`label\` AND \`is_visible\` NULL and \`client_visible\` false are deleted server-side (FR-10 / AC-16; client portal Insights IR2).`, then replace the whole `foreach ($overrides as $tabKey => $row) { … }` loop in `update()` with:

```php
            foreach ($overrides as $tabKey => $row) {
                $label = $row['label'] ?? null;
                $isVisible = $row['is_visible'] ?? null;
                $existing = $existingRows->get($tabKey);

                // Client portal Insights (IR2): an absent `client_visible`
                // keeps the stored tick — today's web never sends it and
                // must not close the tabs an agency opened for clients.
                $clientVisible = array_key_exists('client_visible', $row)
                    ? (bool) $row['client_visible']
                    : (bool) ($existing?->client_visible ?? false);

                // FR-10 / AC-16: nothing left on the row -> queue for bulk delete.
                if ($label === null && $isVisible === null && ! $clientVisible) {
                    $toDelete[] = $tabKey;

                    continue;
                }

                if ($existing) {
                    $existing->fill([
                        'label' => $label,
                        'is_visible' => $isVisible,
                        'client_visible' => $clientVisible,
                        'updated_by' => $userId,
                    ])->save();
                } else {
                    BrandInsightsTabSetting::create([
                        'brand_id' => $brand->id,
                        'tab_key' => $tabKey,
                        'label' => $label,
                        'is_visible' => $isVisible,
                        'client_visible' => $clientVisible,
                        'updated_by' => $userId,
                    ]);
                }
            }
```

`app/Http/Resources/BrandInsightsTabSettingsResource.php` — in the docblock output shape replace `*           "<tab_key>": { "label": string|null, "is_visible": bool|null }` with `*           "<tab_key>": { "label": string|null, "is_visible": bool|null, "client_visible": bool }`, and in `toArray()` replace:

```php
            $overrides[$tabKey] = [
                'label' => $row->label,
                'is_visible' => $row->is_visible,
            ];
```

with:

```php
            $overrides[$tabKey] = [
                'label' => $row->label,
                'is_visible' => $row->is_visible,
                'client_visible' => (bool) $row->client_visible,
            ];
```

- [ ] **Step 4: Run the new file and the request unit test**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/Brand/BrandInsightsTabClientVisibilityTest.php tests/Unit/Http/Requests/InsightsTabSettingsRequestTest.php --compact
```

Expected: 5 + 4 passed (the request unit test's dataset still rejects unknown tab keys for both scopes; the workspace request is untouched).

- [ ] **Step 5: Named mutations** — apply each from the comment block, run the Step 4 command, watch the named test fail, restore, re-run green.

- [ ] **Step 6: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && for f in app/Http/Requests/UpdateBrandInsightsTabSettingsRequest.php app/Http/Controllers/Api/Brand/BrandInsightsTabSettingsController.php app/Http/Resources/BrandInsightsTabSettingsResource.php tests/Feature/Brand/BrandInsightsTabClientVisibilityTest.php; do php -l $f || exit 1; done && vendor/bin/pint app/Http/Requests/UpdateBrandInsightsTabSettingsRequest.php app/Http/Controllers/Api/Brand/BrandInsightsTabSettingsController.php app/Http/Resources/BrandInsightsTabSettingsResource.php tests/Feature/Brand/BrandInsightsTabClientVisibilityTest.php && vendor/bin/pint --test app/Http/Requests/UpdateBrandInsightsTabSettingsRequest.php app/Http/Controllers/Api/Brand/BrandInsightsTabSettingsController.php app/Http/Resources/BrandInsightsTabSettingsResource.php tests/Feature/Brand/BrandInsightsTabClientVisibilityTest.php && /usr/bin/git add app/Http/Requests/UpdateBrandInsightsTabSettingsRequest.php app/Http/Controllers/Api/Brand/BrandInsightsTabSettingsController.php app/Http/Resources/BrandInsightsTabSettingsResource.php tests/Feature/Brand/BrandInsightsTabClientVisibilityTest.php && /usr/bin/git commit -m "feat(api): Insights Tabs settings read and write the per-tab Clients tick"
```

---

### Task 3: Characterize the public share insight responses (before the refactor)

**Files:**
- Test: `tests/Feature/Share/BrandShareInsightCharacterizationTest.php`

**Interfaces:**
- Consumes: today's `BrandShareInsightController` (unchanged).
- Produces: a green pin of public-link behaviour that Tasks 4 and 7 must keep green.

- [ ] **Step 1: Write the characterization tests**

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Models\Brand;
use App\Models\BrandShareSetting;
use App\Models\BrandTrendSignal;
use App\Models\Report;
use App\Models\User;

/**
 * Client portal Insights (spec 2026-10-07 §3.5): the PUBLIC brand share link
 * (`v1/share/brand/{slug}/insight/*`) must read exactly as before the access
 * seam refactor — same statuses, same bodies, same ordering of checks, and
 * none of the client trims. Written and run green on the unchanged
 * controller (plan Task 3), then kept green through Tasks 4 and 7.
 */
beforeEach(function () {
    $this->brand = Brand::factory()->create(['name' => 'Kopi Kenangan']);
    $this->setting = BrandShareSetting::create([
        'brand_id' => $this->brand->id,
        'link_slug' => BrandShareSetting::generateUniqueSlug(),
        'link_enabled' => true,
        'link_is_protected' => false,
    ]);
    $this->base = "/api/v1/share/brand/{$this->setting->link_slug}/insight";

    $this->ideations = [['title' => 'Iftar box unboxing', 'hook' => 'Open on the date reveal']];
    $this->signal = BrandTrendSignal::query()->create([
        'workspace_id' => $this->brand->workspace_id,
        'brand_id' => $this->brand->id,
        'signal_name' => 'Ramadan iftar boxes',
        'description' => 'Creators unbox iftar hampers at sunset.',
        'reasoning' => 'High save rate on hamper unboxing posts.',
        'relevancy' => 'high',
        'relevancy_total_score' => 82,
        'platforms' => ['TIKTOK'],
        'ideations' => $this->ideations,
    ]);

    $this->sister = Brand::factory()->create(['name' => 'Sister Brand']);
    $this->foreignSignal = BrandTrendSignal::query()->create([
        'workspace_id' => $this->sister->workspace_id,
        'brand_id' => $this->sister->id,
        'signal_name' => 'Back to school',
        'description' => 'x',
        'reasoning' => 'y',
    ]);

    $this->author = User::factory()->create(['name' => 'Rina Agency']);
    $this->owned = Report::factory()->create(['brand_id' => $this->brand->id, 'created_by' => $this->author->id]);
    $this->sharedIn = Report::factory()->create([
        'brand_id' => $this->sister->id,
        'created_by' => $this->author->id,
        'spec' => array_merge(Report::factory()->validSpec(), ['sharedToBrands' => [['brandId' => (string) $this->brand->id]]]),
    ]);
});

/*
 * Mutation checks (plan Task 3, Step 3 — on the unchanged controller; re-run in Task 4 against ShareLinkBrandAccess):
 * - drop `! $setting->link_enabled ||` from the link check → "a disabled link…" fails (200 instead of 404);
 * - read the token from the header only → "a disabled link…" fails at `?share_token` (403);
 * - drop the `orWhereRaw(... sharedToBrands ...)` in reports() → "reports list…" fails (one id).
 */
test('a disabled or unknown link is the same 404, a protected one the same 403, and ?share_token still opens it', function () {
    $this->setting->update(['link_enabled' => false]);
    $this->getJson("{$this->base}/signals")->assertNotFound()->assertExactJson(['message' => 'Share link not found or disabled.']);

    // The link check runs before the endpoint's own 422 (campaign_name missing).
    $this->getJson('/api/v1/share/brand/no-such-link/insight/campaign')->assertNotFound()->assertExactJson(['message' => 'Share link not found or disabled.']);

    $this->setting->update(['link_enabled' => true, 'link_is_protected' => true, 'link_password' => 'Sup3rSecret']);
    $this->getJson("{$this->base}/reports")->assertStatus(403)->assertExactJson(['message' => 'Authentication required.']);

    $token = hash('sha256', $this->setting->link_slug.'Sup3rSecret'.config('app.key'));
    $this->getJson("{$this->base}/reports?share_token={$token}")->assertOk();
    $this->getJson("{$this->base}/signals/{$this->signal->id}", ['X-Share-Token' => $token])->assertOk();
    $this->getJson("{$this->base}/signals/{$this->signal->id}", ['X-Share-Token' => 'wrong'])->assertStatus(403)->assertExactJson(['message' => 'Authentication required.']);
});

test('signals keep their ideations on the list, the spotlight and the detail; a foreign signal is 404', function () {
    $list = $this->getJson("{$this->base}/signals")->assertOk();

    expect($list->json('message'))->toBe('Trend signals retrieved successfully')
        ->and(array_column($list->json('data.data'), 'id'))->toBe([$this->signal->id])
        ->and($list->json('data.data.0.ideations'))->toBe($this->ideations)
        ->and($list->json('hero_spotlight.id'))->toBe($this->signal->id)
        ->and($list->json('hero_spotlight.ideations'))->toBe($this->ideations);

    $this->getJson("{$this->base}/signals/{$this->signal->id}")->assertOk()
        ->assertJsonPath('message', 'Trend signal retrieved successfully')
        ->assertJsonPath('data.ideations', $this->ideations);

    $this->getJson("{$this->base}/signals/{$this->foreignSignal->id}")->assertNotFound()->assertExactJson(['message' => 'Signal not found']);
});

test('reports list owned and shared-in reports with createdBy and the sharing context', function () {
    $rows = collect($this->getJson("{$this->base}/reports")->assertOk()->json('data'))->keyBy('id');

    expect($rows->keys()->all())->toEqualCanonicalizing([$this->owned->id, $this->sharedIn->id])
        ->and($rows[$this->owned->id]['createdBy'])->toMatchArray(['id' => $this->author->id, 'name' => 'Rina Agency'])
        ->and($rows[$this->owned->id]['sharingContext'])->toBe(['isOwned' => true])
        ->and($rows[$this->sharedIn->id]['sharingContext'])->toMatchArray(['isOwned' => false, 'sourceBrandName' => 'Sister Brand']);

    $this->getJson("{$this->base}/reports/{$this->sharedIn->id}")->assertOk()
        ->assertJsonPath('data.sharingContext.isOwned', false)
        ->assertJsonPath('data.createdBy.name', 'Rina Agency');

    $this->getJson("{$this->base}/reports/01JZZZZZZZZZZZZZZZZZZZZZZZ")->assertNotFound()->assertExactJson(['message' => 'Report not found']);
});

test('the report query validates its body first, then checks the brand', function () {
    // Validation runs in the FormRequest, before the link check: even a dead link answers 422.
    $this->postJson('/api/v1/share/brand/no-such-link/insight/reports/query', [])->assertStatus(422);

    $this->postJson("{$this->base}/reports/query", [
        'brandId' => (string) $this->sister->id,
        'spec' => Report::factory()->validSpec(),
    ])->assertStatus(403)->assertExactJson(['message' => 'Brand mismatch']);
});

test('the public share insight route table is unchanged', function () {
    $prefix = 'api/v1/share/brand/{slug}/insight/';
    $table = collect(app('router')->getRoutes()->getRoutes())
        ->filter(fn ($route) => str_starts_with($route->uri(), $prefix))
        ->map(fn ($route) => implode(',', array_values(array_diff($route->methods(), ['HEAD']))).' '.substr($route->uri(), strlen($prefix)))
        ->sort()->values()->all();

    expect($table)->toBe([
        'GET atl/detail',
        'GET atl/filters',
        'GET atl/overview',
        'GET campaign',
        'GET campaign/filters',
        'GET earned-media',
        'GET earned-media/filters',
        'GET earned-media/influencers',
        'GET home',
        'GET overview',
        'GET owned-media/content/{content_id}/creative-analysis',
        'GET owned-media/creative/playbook',
        'GET owned-media/creative/playbooks',
        'GET owned-media/detail',
        'GET owned-media/filters',
        'GET owned-media/label-attributes',
        'GET owned-media/overview',
        'GET owned-media/sentiment',
        'GET paid-media/detail',
        'GET paid-media/filters',
        'GET paid-media/overview',
        'GET report-templates',
        'GET reports',
        'GET reports/{reportId}',
        'GET signals',
        'GET signals/{id}',
        'POST reports/query',
    ]);
});
```

- [ ] **Step 2: Run — expect PASS on the unchanged controller**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/Share/BrandShareInsightCharacterizationTest.php --compact
```

Expected: 5 passed. These pin TODAY's behaviour, so a failure here is a wrong expectation, not a bug: dump the actual value (`dump($response->json())`), confirm it against `BrandShareInsightController`, correct the expectation, and log it in the track file. Two likely spots: `Report::factory()->validSpec()` may not satisfy `ValidatesReportSpec` (then the 403 assertion sees a 422 — dump `->json('errors')` and complete the spec in the test until it validates; never drop the brand-mismatch assertion), and `hero_spotlight` must be the signal itself (it is the only brand signal of the last 7 days).

- [ ] **Step 3: Named mutations** — apply each from the comment block to `BrandShareInsightController::resolveSlug()` / `reports()`, run, watch the named test fail, restore, re-run green.

- [ ] **Step 4: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && php -l tests/Feature/Share/BrandShareInsightCharacterizationTest.php && vendor/bin/pint tests/Feature/Share/BrandShareInsightCharacterizationTest.php && vendor/bin/pint --test tests/Feature/Share/BrandShareInsightCharacterizationTest.php && /usr/bin/git add tests/Feature/Share/BrandShareInsightCharacterizationTest.php && /usr/bin/git commit -m "test(api): characterize the public brand share insight responses"
```

---

### Task 4: The access seam — `InsightBrandAccess`, `ShareLinkBrandAccess`, `insight.access`, controller off positional `$slug`

**Files:**
- Create: `app/Services/Insights/InsightBrandAccess.php`, `app/Services/Insights/ShareLinkBrandAccess.php`, `app/Http/Middleware/UseInsightBrandAccess.php`
- Modify: `app/Http/Controllers/Api/Share/BrandShareInsightController.php` (all 27 public methods; `resolveSlug()` removed)
- Modify: `bootstrap/app.php:108` (alias), `routes/api.php:590` (share insight group middleware)
- Test: `tests/Feature/Share/BrandShareInsightCharacterizationTest.php` (append one test)

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `interface App\Services\Insights\InsightBrandAccess { const AUDIENCE_PUBLIC = 'public'; const AUDIENCE_CLIENT = 'client'; public function brandFor(Request $request): Brand; public function audience(): string; }` — `brandFor()` throws `Illuminate\Http\Exceptions\HttpResponseException` to refuse.
  - `final class App\Services\Insights\ShareLinkBrandAccess implements InsightBrandAccess` (audience `public`).
  - Middleware alias `insight.access` → `App\Http\Middleware\UseInsightBrandAccess::handle(Request $request, Closure $next, string $surface)`; sets `$request->attributes[InsightBrandAccess::class]`. Surfaces: `share` (this task), `portal` (Task 5).
  - `BrandShareInsightController::access(Request): InsightBrandAccess` and `::brandFor(Request): Brand` (private). Every public method now takes only its Request (`Request`, `BrandTrendSignalIndexRequest` or `QueryReportRequest`); sub-ids come from `$request->route('id' | 'reportId' | 'content_id')`.

- [ ] **Step 1: Write the failing test** — append to `tests/Feature/Share/BrandShareInsightCharacterizationTest.php`

```php
/*
 * Mutation check (plan Task 4, Step 6): remove `->middleware('insight.access:share')`
 * from the share insight group → this test fails AND every request test above
 * fails with a 500 (LogicException: insight route without the middleware).
 */
test('every public share insight route binds the share-link access', function () {
    $routes = collect(app('router')->getRoutes()->getRoutes())
        ->filter(fn ($route) => str_starts_with($route->uri(), 'api/v1/share/brand/{slug}/insight/'));

    expect($routes)->toHaveCount(27);
    foreach ($routes as $route) {
        expect($route->gatherMiddleware())->toContain('insight.access:share');
    }
});
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/Share/BrandShareInsightCharacterizationTest.php --compact
```

Expected: the new test FAILS (`insight.access:share` not in the middleware list); the 5 characterization tests pass.

- [ ] **Step 3: The seam** — create the three files.

`app/Services/Insights/InsightBrandAccess.php`:

```php
<?php

declare(strict_types=1);

namespace App\Services\Insights;

use App\Models\Brand;
use Illuminate\Http\Exceptions\HttpResponseException;
use Illuminate\Http\Request;

/**
 * Which brand an Insights request may read (client portal Insights spec
 * 2026-10-07 §3.2, I-1). One implementation per surface — the public share
 * link (slug + password) and the client portal (session + lane) — bound per
 * route group by the `insight.access:{share|portal}` middleware, so
 * BrandShareInsightController never knows which surface it serves.
 */
interface InsightBrandAccess
{
    public const AUDIENCE_PUBLIC = 'public';

    public const AUDIENCE_CLIENT = 'client';

    /**
     * @throws HttpResponseException carrying the surface's own refusal
     */
    public function brandFor(Request $request): Brand;

    /**
     * @return 'public'|'client'
     */
    public function audience(): string;
}
```

`app/Services/Insights/ShareLinkBrandAccess.php`:

```php
<?php

declare(strict_types=1);

namespace App\Services\Insights;

use App\Models\Brand;
use App\Models\BrandShareSetting;
use Illuminate\Http\Exceptions\HttpResponseException;
use Illuminate\Http\Request;

/**
 * The public brand share link (`v1/share/brand/{slug}/insight/*`):
 * BrandShareInsightController::resolveSlug() moved verbatim. An unknown or
 * disabled link → 404, a protected one without its token (`X-Share-Token`
 * header, else `?share_token`) → 403 — the same bodies as before the seam.
 */
final class ShareLinkBrandAccess implements InsightBrandAccess
{
    public function brandFor(Request $request): Brand
    {
        $setting = BrandShareSetting::with('brand')
            ->where('link_slug', (string) $request->route('slug'))
            ->first();

        if (! $setting || ! $setting->link_enabled || ! $setting->brand) {
            throw new HttpResponseException(response()->json(['message' => 'Share link not found or disabled.'], 404));
        }

        // Validate access token for password-protected links
        if ($setting->link_is_protected) {
            $token = $request->header('X-Share-Token') ?? $request->query('share_token');
            $expectedToken = hash('sha256', $setting->link_slug.$setting->link_password.config('app.key'));

            if (! $token || ! hash_equals($expectedToken, $token)) {
                throw new HttpResponseException(response()->json(['message' => 'Authentication required.'], 403));
            }
        }

        return $setting->brand;
    }

    public function audience(): string
    {
        return self::AUDIENCE_PUBLIC;
    }
}
```

`app/Http/Middleware/UseInsightBrandAccess.php` (share only; Task 5 replaces it with the portal arm and the guard):

```php
<?php

declare(strict_types=1);

namespace App\Http\Middleware;

// craftsman-ignore: PHP002 — middleware is not final in this codebase.

use App\Services\Insights\InsightBrandAccess;
use App\Services\Insights\ShareLinkBrandAccess;
use Closure;
use Illuminate\Http\Request;
use InvalidArgumentException;
use Symfony\Component\HttpFoundation\Response;

/**
 * `insight.access:{surface}` (client portal Insights spec 2026-10-07 §3.2):
 * binds the brand-access resolver of the route group onto the request, so
 * BrandShareInsightController only asks "which brand may this request read".
 */
class UseInsightBrandAccess
{
    public function handle(Request $request, Closure $next, string $surface): Response
    {
        $access = match ($surface) {
            'share' => app(ShareLinkBrandAccess::class),
            default => throw new InvalidArgumentException("Unknown insight surface [{$surface}]."),
        };
        $request->attributes->set(InsightBrandAccess::class, $access);

        return $next($request);
    }
}
```

- [ ] **Step 4: Wire the alias and the share group**

`bootstrap/app.php` — after `'client.session' => AuthenticateClientSession::class,` add `'insight.access' => UseInsightBrandAccess::class,` and add `use App\Http\Middleware\UseInsightBrandAccess;` beside the other `App\Http\Middleware\…` imports (alphabetical; pint `ordered_imports` checks it).

`routes/api.php` — replace

```php
    // Public Brand Share Insight Proxy (no authentication required)
    Route::prefix('share/brand/{slug}/insight')->group(function () {
```

with

```php
    // Public Brand Share Insight Proxy (no authentication required).
    // `insight.access:share` binds ShareLinkBrandAccess (slug + password);
    // the client portal mirrors these routes with `insight.access:portal`.
    Route::prefix('share/brand/{slug}/insight')->middleware('insight.access:share')->group(function () {
```

- [ ] **Step 5: Refactor the controller**

In `app/Http/Controllers/Api/Share/BrandShareInsightController.php`:

1. Imports: remove `use App\Models\BrandShareSetting;`; add `use App\Services\Insights\InsightBrandAccess;` and `use LogicException;` (alphabetical).

2. Replace the whole `// ─── Slug Resolution ───` section (the comment header and `resolveSlug()`, lines 77–105) with:

```php
    // ─── Brand Access ─────────────────────────────────────────────────

    /**
     * The resolver `insight.access:{share|portal}` bound for this route
     * group (client portal Insights spec 2026-10-07 §3.2). A route without
     * that middleware is a wiring bug, never a public answer.
     */
    private function access(Request $request): InsightBrandAccess
    {
        $access = $request->attributes->get(InsightBrandAccess::class);
        if (! $access instanceof InsightBrandAccess) {
            throw new LogicException('Insight route without the insight.access middleware.');
        }

        return $access;
    }

    /**
     * The brand this request may read. Always called BEFORE
     * withExceptionHandling(): a refusal is an HttpResponseException (a
     * RuntimeException), which that wrapper would turn into a 500.
     */
    private function brandFor(Request $request): Brand
    {
        return $this->access($request)->brandFor($request);
    }
```

3. In every one of the 27 public methods, replace this exact block (it occurs 27 times, identical text — use one replace-all):

```php
        $resolved = $this->resolveSlug($slug);
        if ($resolved instanceof JsonResponse) {
            return $resolved;
        }

        ['brand' => $brand] = $resolved;
```

with

```php
        $brand = $this->brandFor($request);
```

4. Change each signature as follows (no other line of these methods changes, except the three sub-id rows):

| Method | Before | After |
|---|---|---|
| `overview` | `overview(string $slug)` | `overview(Request $request)` |
| `home` | `home(string $slug)` | `home(Request $request)` |
| `signals` | `signals(BrandTrendSignalIndexRequest $request, string $slug)` | `signals(BrandTrendSignalIndexRequest $request)` |
| `signal` | `signal(string $slug, string $id)` | `signal(Request $request)` |
| `reports` | `reports(string $slug)` | `reports(Request $request)` |
| `report` | `report(string $slug, string $reportId)` | `report(Request $request)` |
| `reportQuery` | `reportQuery(QueryReportRequest $request, string $slug)` | `reportQuery(QueryReportRequest $request)` |
| `reportTemplates` | `reportTemplates(string $slug)` | `reportTemplates(Request $request)` |
| `campaignFilters` | `campaignFilters(string $slug, Request $request)` | `campaignFilters(Request $request)` |
| `campaign` | `campaign(string $slug, Request $request)` | `campaign(Request $request)` |
| `paidMediaFilters` | `paidMediaFilters(string $slug, Request $request)` | `paidMediaFilters(Request $request)` |
| `paidMediaOverview` | `paidMediaOverview(string $slug, Request $request)` | `paidMediaOverview(Request $request)` |
| `paidMediaDetail` | `paidMediaDetail(string $slug, Request $request)` | `paidMediaDetail(Request $request)` |
| `ownedMediaFilters` | `ownedMediaFilters(string $slug, Request $request)` | `ownedMediaFilters(Request $request)` |
| `ownedMediaLabelAttributes` | `ownedMediaLabelAttributes(string $slug)` | `ownedMediaLabelAttributes(Request $request)` |
| `creativePlaybooks` | `creativePlaybooks(string $slug, Request $request)` | `creativePlaybooks(Request $request)` |
| `creativePlaybook` | `creativePlaybook(string $slug, Request $request)` | `creativePlaybook(Request $request)` |
| `creativeAnalysisShow` | `creativeAnalysisShow(string $slug, string $content_id, Request $request)` | `creativeAnalysisShow(Request $request)` |
| `ownedMediaOverview` | `ownedMediaOverview(string $slug, Request $request)` | `ownedMediaOverview(Request $request)` |
| `ownedMediaDetail` | `ownedMediaDetail(string $slug, Request $request)` | `ownedMediaDetail(Request $request)` |
| `ownedMediaSentiment` | `ownedMediaSentiment(string $slug, Request $request)` | `ownedMediaSentiment(Request $request)` |
| `earnedMediaFilters` | `earnedMediaFilters(string $slug, Request $request)` | `earnedMediaFilters(Request $request)` |
| `earnedMedia` | `earnedMedia(string $slug, Request $request)` | `earnedMedia(Request $request)` |
| `earnedMediaInfluencers` | `earnedMediaInfluencers(string $slug, Request $request)` | `earnedMediaInfluencers(Request $request)` |
| `atlFilters` | `atlFilters(string $slug, Request $request)` | `atlFilters(Request $request)` |
| `atlOverview` | `atlOverview(string $slug, Request $request)` | `atlOverview(Request $request)` |
| `atlDetail` | `atlDetail(string $slug, Request $request)` | `atlDetail(Request $request)` |

Laravel resolves the typed Request parameter from the container and passes the route parameters after it; PHP ignores the extra arguments, which is why no `$slug`/`$workspaceSlug` parameter may remain.

5. The three sub-id methods read the id from the route right after `$brand = $this->brandFor($request);`:

`signal()`:

```php
        $brand = $this->brandFor($request);
        $id = (string) $request->route('id');
```

`report()`:

```php
        $brand = $this->brandFor($request);
        $reportId = (string) $request->route('reportId');
```

`creativeAnalysisShow()` — the body becomes:

```php
        $brand = $this->brandFor($request);
        $contentId = (string) $request->route('content_id');

        $playbookId = $request->query('playbook_id');
        $playbookId = ($playbookId === null || $playbookId === '') ? null : (int) $playbookId;

        return $this->withExceptionHandling('creative_analysis_show', $brand->id, function () use ($brand, $contentId, $playbookId) {
            // Same list contract as the authenticated endpoint: analyses are
            // append-only history, newest first, and the client renders data[0].
            $analyses = $this->creativeAnalysisService->findCompletedAnalyses(
                $brand,
                $contentId,
                $playbookId,
            );

            if ($analyses === []) {
                return response()->json(['error' => 'no_analysis'], 404);
            }

            return response()->json([
                'data' => $analyses,
                'count' => count($analyses),
            ]);
        });
```

6. Check nothing positional is left:

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && /usr/bin/grep -n 'string \$slug\|resolveSlug\|\$content_id\|string \$id\|string \$reportId\|BrandShareSetting' app/Http/Controllers/Api/Share/BrandShareInsightController.php; /usr/bin/grep -c 'brandFor(\$request)' app/Http/Controllers/Api/Share/BrandShareInsightController.php
```

Expected: no lines from the first grep; `28` from the count (27 call sites + the helper's own `->brandFor($request)`).

- [ ] **Step 6: Run the characterization file + the existing share tests, then the mutation**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/Share/BrandShareInsightCharacterizationTest.php tests/Feature/BrandSharePublicCreativeTest.php tests/Feature/BrandSharePublicRoutesTest.php --compact
```

Expected: 6 + 6 + 1 passed (or BrandSharePublicCreativeTest's baseline count from Task 0). Then: (a) the named mutation in the comment block; (b) re-apply Task 3's first two mutations to `ShareLinkBrandAccess::brandFor()` (drop the `link_enabled` check; header-only token) and watch "a disabled or unknown link…" fail; restore; re-run green.

- [ ] **Step 7: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && for f in app/Services/Insights/InsightBrandAccess.php app/Services/Insights/ShareLinkBrandAccess.php app/Http/Middleware/UseInsightBrandAccess.php app/Http/Controllers/Api/Share/BrandShareInsightController.php bootstrap/app.php routes/api.php tests/Feature/Share/BrandShareInsightCharacterizationTest.php; do php -l $f || exit 1; done && vendor/bin/pint app/Services/Insights/InsightBrandAccess.php app/Services/Insights/ShareLinkBrandAccess.php app/Http/Middleware/UseInsightBrandAccess.php app/Http/Controllers/Api/Share/BrandShareInsightController.php bootstrap/app.php routes/api.php tests/Feature/Share/BrandShareInsightCharacterizationTest.php && vendor/bin/pint --test app/Services/Insights/InsightBrandAccess.php app/Services/Insights/ShareLinkBrandAccess.php app/Http/Middleware/UseInsightBrandAccess.php app/Http/Controllers/Api/Share/BrandShareInsightController.php bootstrap/app.php routes/api.php tests/Feature/Share/BrandShareInsightCharacterizationTest.php && /usr/bin/git add app/Services/Insights/InsightBrandAccess.php app/Services/Insights/ShareLinkBrandAccess.php app/Http/Middleware/UseInsightBrandAccess.php app/Http/Controllers/Api/Share/BrandShareInsightController.php bootstrap/app.php routes/api.php tests/Feature/Share/BrandShareInsightCharacterizationTest.php && /usr/bin/git commit -m "refactor(api): share insight endpoints read their brand from an access seam, not a positional slug"
```

---

### Task 5: Portal insight routes behind the session, the lane and the tab guard

**Files:**
- Create: `app/Services/Insights/PortalBrandAccess.php`, `app/Services/Insights/InsightTabGuard.php`
- Modify: `app/Http/Middleware/UseInsightBrandAccess.php` (whole file replaced: portal arm + guard)
- Modify: `routes/api.php` (new group after the brand-scoped portal group, ~line 7024)
- Test: `tests/Feature/ClientPortal/PortalInsightsTest.php`

**Interfaces:**
- Consumes: `InsightBrandAccess`, `UseInsightBrandAccess` (Task 4); `InsightsTabResolver::resolveForClients()` (Task 1); `AuthenticateClientSession::BRAND` (existing, set by `client.session:brand`).
- Produces:
  - `final class App\Services\Insights\PortalBrandAccess implements InsightBrandAccess` (audience `client`).
  - `final class App\Services\Insights\InsightTabGuard { public const TABS (array<string, list<InsightsTabKey>>); public static function tabsFor(string $method, Request $request): array (list<InsightsTabKey>); public function isOpenToClients(Brand $brand, string $method, Request $request): bool; }`
  - Routes `public/portal/{workspaceSlug}/{brandSlug}/insight/*` (27), names `public.portal.insight.*`, middleware `throttle:public-portal`, `client.session:brand`, `insight.access:portal`.

- [ ] **Step 1: Write the failing tests** — `tests/Feature/ClientPortal/PortalInsightsTest.php`

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Enums\InsightsTabKey;
use App\Jobs\SendApprovalRequestDigest;
use App\Models\BrandInsightsTabSetting;
use App\Models\BrandShareSetting;
use App\Models\ClientLaneLink;
use App\Services\Insights\InsightTabGuard;
use Illuminate\Support\Facades\Bus;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Mail;
use Tests\Support\ClientLaneFixtures;

/**
 * Client portal Insights (spec 2026-10-07 §3): the share insight endpoints
 * at `public/portal/{workspace}/{brand}/insight/*` behind the client
 * session and an active lane, each closed unless its tab is open to clients.
 *
 * One brand ("Kopi Kenangan"), one client (Dina, `own`). No agency user is
 * ever signed in here (HasWorkspaceScope would stamp fixtures otherwise).
 */
beforeEach(function () {
    Mail::fake();
    Bus::fake([SendApprovalRequestDigest::class]);
    // A route that wrongly reaches the data service fails fast (400/500),
    // never with the guard's 404 body, and never calls a live service.
    Http::fake(['*' => Http::response(['message' => 'stubbed'], 503)]);

    $this->f = ClientLaneFixtures::deck();
    $this->brand = $this->f['brand'];
    $this->dina = ClientLaneFixtures::namedClient($this->brand, 'dina@brand.test', 'Dina Pratiwi');
    [, $token] = ClientLaneFixtures::session($this->dina['user']);
    $this->as = ['X-Client-Session' => $token];
    $this->portal = "/api/public/portal/{$this->f['workspace']->slug}/{$this->brand->slug}";
    $this->base = "{$this->portal}/insight";
    $this->notFound = ['message' => 'Not found.'];

    /** Tick "Clients" on these tabs (in-app visibility stays inherited = on). */
    $this->open = function (array $tabs): void {
        foreach ($tabs as $tab) {
            BrandInsightsTabSetting::query()->updateOrCreate(
                ['brand_id' => $this->brand->id, 'tab_key' => $tab],
                ['client_visible' => true],
            );
        }
    };
});

dataset('portal insight endpoints', [
    'overview' => ['GET', 'overview', ['overview']],
    'home' => ['GET', 'home', ['overview']],
    'signals' => ['GET', 'signals', ['signals']],
    'signal' => ['GET', 'signals/1', ['signals']],
    'reports' => ['GET', 'reports', ['campaigns']],
    'report' => ['GET', 'reports/01JZZZZZZZZZZZZZZZZZZZZZZZ', ['campaigns']],
    'report query' => ['POST', 'reports/query', ['campaigns']],
    'report templates' => ['GET', 'report-templates', ['campaigns']],
    'campaign' => ['GET', 'campaign?campaign_name=Ramadan', ['campaigns']],
    'campaign filters' => ['GET', 'campaign/filters', ['campaigns']],
    'paid overview' => ['GET', 'paid-media/overview', ['paid-media']],
    'paid detail' => ['GET', 'paid-media/detail', ['paid-media']],
    'paid filters' => ['GET', 'paid-media/filters', ['paid-media']],
    'owned overview' => ['GET', 'owned-media/overview', ['owned-media']],
    'owned detail' => ['GET', 'owned-media/detail', ['owned-media']],
    'owned filters' => ['GET', 'owned-media/filters', ['owned-media']],
    'owned sentiment' => ['GET', 'owned-media/sentiment', ['owned-media']],
    'owned label attributes' => ['GET', 'owned-media/label-attributes', ['owned-media']],
    'owned playbooks' => ['GET', 'owned-media/creative/playbooks?tab=owned', ['owned-media']],
    'ads playbooks' => ['GET', 'owned-media/creative/playbooks?tab=ads', ['paid-media']],
    'owned playbook' => ['GET', 'owned-media/creative/playbook?tab=owned&objective=awareness', ['owned-media']],
    'ads playbook' => ['GET', 'owned-media/creative/playbook?tab=ads&objective=awareness', ['paid-media']],
    'creative analysis' => ['GET', 'owned-media/content/post-1/creative-analysis', ['owned-media', 'paid-media']],
    'earned' => ['GET', 'earned-media', ['earned-media']],
    'earned influencers' => ['GET', 'earned-media/influencers?platform=tiktok&username=dina', ['earned-media']],
    'earned filters' => ['GET', 'earned-media/filters', ['earned-media']],
    'atl overview' => ['GET', 'atl/overview', ['atl']],
    'atl detail' => ['GET', 'atl/detail', ['atl']],
    'atl filters' => ['GET', 'atl/filters', ['atl']],
]);

/*
 * Mutation checks (plan Task 5, Step 6):
 * - make InsightTabGuard::isOpenToClients() return true → every "a tab the agency has not opened…" row fails (200/400/404-other/422/500);
 * - map 'reports' => [InsightsTabKey::Signals] → its row fails (Signals is open there) and "the portal mirrors…" still passes;
 * - drop the `?tab=ads` branch in tabsFor() → the `ads playbooks` / `ads playbook` rows and "the Ads tab opens…" fail;
 * - return AUDIENCE_PUBLIC from PortalBrandAccess::audience() → every dataset row fails (no guard);
 * - remove 'insight.access:portal' from the portal group → "the portal mirrors…" fails, and "an opened tab answers…" fails (500 LogicException);
 * - skip the `&& $inApp…` part of resolveForClients() → "every access level reads…" fails at `reports` (200).
 */
test('the portal mirrors every share insight route, behind the session, the lane and the tab guard', function () {
    $routes = collect(app('router')->getRoutes()->getRoutes());
    $table = fn (string $prefix): array => $routes
        ->filter(fn ($route) => str_starts_with($route->uri(), $prefix))
        ->map(fn ($route) => implode(',', array_values(array_diff($route->methods(), ['HEAD']))).' '.substr($route->uri(), strlen($prefix)).' '.$route->getActionMethod())
        ->sort()->values()->all();

    $share = $table('api/v1/share/brand/{slug}/insight/');
    $portal = $table('api/public/portal/{workspaceSlug}/{brandSlug}/insight/');
    expect($share)->toHaveCount(27)->and($portal)->toBe($share);

    // The guard map covers every endpoint and nothing else.
    $methods = collect($share)->map(fn (string $row) => explode(' ', $row)[2])->unique()->values()->all();
    expect(array_keys(InsightTabGuard::TABS))->toEqualCanonicalizing($methods);

    foreach ($routes->filter(fn ($route) => str_starts_with($route->uri(), 'api/public/portal/{workspaceSlug}/{brandSlug}/insight/')) as $route) {
        expect($route->gatherMiddleware())
            ->toContain('throttle:public-portal', 'client.session:brand', 'insight.access:portal')
            ->not->toContain('throttle:share-owned-label-filter');
    }
});

test('a tab the agency has not opened for clients is the one 404 on every endpoint it serves', function (string $method, string $path, array $closed) {
    ($this->open)(array_values(array_diff(InsightsTabKey::values(), $closed)));

    $response = $this->json($method, "{$this->base}/{$path}", [], $this->as)
        ->assertNotFound()
        ->assertExactJson($this->notFound);

    expect($response->headers->get('Cache-Control'))->toContain('no-store');
})->with('portal insight endpoints');

test('an opened tab answers like the share link, no-store, with the slid session expiry', function () {
    ($this->open)(['signals', 'campaigns', 'owned-media']);

    $signals = $this->getJson("{$this->base}/signals", $this->as)->assertOk();
    expect($signals->json('message'))->toBe('Trend signals retrieved successfully')
        ->and($signals->headers->get('Cache-Control'))->toContain('no-store')
        ->and($signals->headers->get('X-Client-Session-Expires-At'))->not->toBeNull();

    $this->getJson("{$this->base}/reports", $this->as)->assertOk()->assertJsonStructure(['data', 'meta' => ['total', 'per_page', 'current_page', 'last_page']]);
    $this->getJson("{$this->base}/report-templates", $this->as)->assertOk()->assertJsonStructure(['data']);
    $this->getJson("{$this->base}/owned-media/label-attributes", $this->as)->assertOk()->assertJsonStructure(['data']);
    $this->getJson("{$this->base}/owned-media/creative/playbooks?tab=owned", $this->as)->assertOk()->assertJsonStructure(['playbooks', 'in_flight_runs']);
    $this->getJson("{$this->base}/owned-media/content/post-1/creative-analysis", $this->as)->assertNotFound()->assertExactJson(['error' => 'no_analysis']);
    $this->getJson("{$this->base}/signals/999999", $this->as)->assertNotFound()->assertExactJson(['message' => 'Signal not found']);

    // Ads playbooks follow the Ads tab (closed); an opened tab never opens its neighbour.
    $this->getJson("{$this->base}/owned-media/creative/playbooks?tab=ads", $this->as)->assertNotFound()->assertExactJson($this->notFound);
    $this->getJson("{$this->base}/atl/filters", $this->as)->assertNotFound()->assertExactJson($this->notFound);
});

test('the Ads tab opens the ads playbooks and the post analysis, never the Social Media ones', function () {
    ($this->open)(['paid-media']);

    $this->getJson("{$this->base}/owned-media/creative/playbooks?tab=ads", $this->as)->assertOk()->assertJsonStructure(['playbooks', 'in_flight_runs']);
    $this->getJson("{$this->base}/owned-media/content/post-1/creative-analysis", $this->as)->assertNotFound()->assertExactJson(['error' => 'no_analysis']);
    $this->getJson("{$this->base}/owned-media/creative/playbooks?tab=owned", $this->as)->assertNotFound()->assertExactJson($this->notFound);
    $this->getJson("{$this->base}/owned-media/label-attributes", $this->as)->assertNotFound()->assertExactJson($this->notFound);
});

test('every access level reads opened tabs; a tab hidden in-app stays closed even when ticked', function () {
    ($this->open)(['signals', 'campaigns']);
    BrandInsightsTabSetting::query()->where('brand_id', $this->brand->id)->where('tab_key', 'campaigns')->update(['is_visible' => false]);

    foreach (ClientLaneLink::ACCESS_LEVELS as $level) {
        $this->dina['lane']->forceFill(['access_level' => $level])->save();
        $this->getJson("{$this->base}/signals", $this->as)->assertOk();
    }

    $this->getJson("{$this->base}/reports", $this->as)->assertNotFound()->assertExactJson($this->notFound);
});

test('Insights needs a session and an active lane on the brand; anything else is the one 404', function () {
    ($this->open)(['signals']);

    $this->getJson("{$this->base}/signals")->assertStatus(401)->assertExactJson(['code' => 'session_required', 'message' => 'Sign in to continue.']);
    $this->getJson("/api/public/portal/{$this->f['workspace']->slug}/no-such-brand/insight/signals", $this->as)->assertNotFound()->assertExactJson($this->notFound);

    $other = ClientLaneFixtures::deck(); // a brand Dina has no lane on
    BrandInsightsTabSetting::query()->create(['brand_id' => $other['brand']->id, 'tab_key' => 'signals', 'client_visible' => true]);
    $this->getJson("/api/public/portal/{$other['workspace']->slug}/{$other['brand']->slug}/insight/signals", $this->as)->assertNotFound()->assertExactJson($this->notFound);

    $this->getJson("{$this->base}/signals", $this->as)->assertOk();
    $this->dina['lane']->forceFill(['revoked_at' => now()])->save();
    $this->getJson("{$this->base}/signals", $this->as)->assertNotFound()->assertExactJson($this->notFound);
});

test('the public share link ignores client visibility', function () {
    $setting = BrandShareSetting::create([
        'brand_id' => $this->brand->id,
        'link_slug' => BrandShareSetting::generateUniqueSlug(),
        'link_enabled' => true,
        'link_is_protected' => false,
    ]);

    // Nothing is open for clients; the public link reads as before.
    $this->getJson("/api/v1/share/brand/{$setting->link_slug}/insight/signals")->assertOk();
    $this->getJson("/api/v1/share/brand/{$setting->link_slug}")->assertOk()
        ->assertJsonPath('data.insights_tab_settings.resolved.signals.is_visible', true);
});
```

- [ ] **Step 2: Run to verify they fail**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/ClientPortal/PortalInsightsTest.php --compact
```

Expected: the file fails to load with `Class "App\Services\Insights\InsightTabGuard" not found` (the `use` is resolved when the first test touches `::TABS`), or — once the class exists — the route tests fail because no `api/public/portal/…/insight/` route exists (the dataset rows get Laravel's default 404 body `{"message":"…"}` ≠ `Not found.`). "the public share link ignores client visibility" passes (characterization).

- [ ] **Step 3: `PortalBrandAccess` and `InsightTabGuard`**

`app/Services/Insights/PortalBrandAccess.php`:

```php
<?php

declare(strict_types=1);

namespace App\Services\Insights;

use App\Http\Middleware\AuthenticateClientSession;
use App\Models\Brand;
use Illuminate\Http\Exceptions\HttpResponseException;
use Illuminate\Http\Request;

/**
 * The client portal (`public/portal/{workspace}/{brand}/insight/*`): the
 * brand `client.session:brand` resolved from the session and an ACTIVE lane
 * (client portal spec 2026-10-06 §4.4). No brand on the request → the
 * dead-link 404, no hint the brand exists.
 */
final class PortalBrandAccess implements InsightBrandAccess
{
    public function brandFor(Request $request): Brand
    {
        $brand = $request->attributes->get(AuthenticateClientSession::BRAND);
        if (! $brand instanceof Brand) {
            throw new HttpResponseException(response()->json(['message' => 'Not found.'], 404));
        }

        return $brand;
    }

    public function audience(): string
    {
        return self::AUDIENCE_CLIENT;
    }
}
```

`app/Services/Insights/InsightTabGuard.php`:

```php
<?php

declare(strict_types=1);

namespace App\Services\Insights;

use App\Enums\InsightsTabKey;
use App\Models\Brand;
use App\Services\InsightsTabResolver;
use Illuminate\Http\Request;

/**
 * Which Insights tab opens each share-insight endpoint for a CLIENT (client
 * portal Insights spec 2026-10-07 §3.2, rulings IR4–IR5). Keyed by the
 * BrandShareInsightController method a route calls; an endpoint is open when
 * ANY of its tabs is client-visible (InsightsTabResolver::resolveForClients).
 * A method missing here is closed to clients (fail closed) — the portal
 * route test keeps this map equal to the routed methods. The public share
 * link is never guarded here: its behaviour is unchanged.
 */
final class InsightTabGuard
{
    /** @var array<string, list<InsightsTabKey>> */
    public const TABS = [
        'overview' => [InsightsTabKey::Overview],
        'home' => [InsightsTabKey::Overview],
        'signals' => [InsightsTabKey::Signals],
        'signal' => [InsightsTabKey::Signals],
        'reports' => [InsightsTabKey::Campaigns],
        'report' => [InsightsTabKey::Campaigns],
        'reportQuery' => [InsightsTabKey::Campaigns],
        'reportTemplates' => [InsightsTabKey::Campaigns],
        'campaign' => [InsightsTabKey::Campaigns],
        'campaignFilters' => [InsightsTabKey::Campaigns],
        'paidMediaFilters' => [InsightsTabKey::PaidMedia],
        'paidMediaOverview' => [InsightsTabKey::PaidMedia],
        'paidMediaDetail' => [InsightsTabKey::PaidMedia],
        'ownedMediaFilters' => [InsightsTabKey::OwnedMedia],
        'ownedMediaOverview' => [InsightsTabKey::OwnedMedia],
        'ownedMediaDetail' => [InsightsTabKey::OwnedMedia],
        'ownedMediaSentiment' => [InsightsTabKey::OwnedMedia],
        'ownedMediaLabelAttributes' => [InsightsTabKey::OwnedMedia],
        // `?tab=ads` belongs to the Ads tab — see tabsFor().
        'creativePlaybooks' => [InsightsTabKey::OwnedMedia],
        'creativePlaybook' => [InsightsTabKey::OwnedMedia],
        // One post-analysis endpoint serves the Social Media AND the Ads tab.
        'creativeAnalysisShow' => [InsightsTabKey::OwnedMedia, InsightsTabKey::PaidMedia],
        'earnedMediaFilters' => [InsightsTabKey::EarnedMedia],
        'earnedMedia' => [InsightsTabKey::EarnedMedia],
        'earnedMediaInfluencers' => [InsightsTabKey::EarnedMedia],
        'atlFilters' => [InsightsTabKey::Atl],
        'atlOverview' => [InsightsTabKey::Atl],
        'atlDetail' => [InsightsTabKey::Atl],
    ];

    /** The playbook endpoints the Ads tab calls with `?tab=ads`. */
    private const PLAYBOOK_METHODS = ['creativePlaybooks', 'creativePlaybook'];

    public function __construct(private readonly InsightsTabResolver $tabs) {}

    /**
     * @return list<InsightsTabKey> any one of which opens the endpoint
     */
    public static function tabsFor(string $method, Request $request): array
    {
        if (in_array($method, self::PLAYBOOK_METHODS, true) && $request->query('tab') === 'ads') {
            return [InsightsTabKey::PaidMedia];
        }

        return self::TABS[$method] ?? [];
    }

    public function isOpenToClients(Brand $brand, string $method, Request $request): bool
    {
        $wanted = self::tabsFor($method, $request);
        if ($wanted === []) {
            return false;
        }

        $resolved = $this->tabs->resolveForClients($brand);
        foreach ($wanted as $tab) {
            if ($resolved[$tab->value]['is_visible'] ?? false) {
                return true;
            }
        }

        return false;
    }
}
```

- [ ] **Step 4: The middleware's portal arm** — replace the whole of `app/Http/Middleware/UseInsightBrandAccess.php` with:

```php
<?php

declare(strict_types=1);

namespace App\Http\Middleware;

// craftsman-ignore: PHP002 — middleware is not final in this codebase.

use App\Services\Insights\InsightBrandAccess;
use App\Services\Insights\InsightTabGuard;
use App\Services\Insights\PortalBrandAccess;
use App\Services\Insights\ShareLinkBrandAccess;
use Closure;
use Illuminate\Http\Request;
use InvalidArgumentException;
use Symfony\Component\HttpFoundation\Response;

/**
 * `insight.access:{share|portal}` (client portal Insights spec 2026-10-07
 * §3.2): binds the brand-access resolver of the route group onto the
 * request, so BrandShareInsightController only asks "which brand may this
 * request read".
 *
 * On `portal` it also runs the tab guard. It runs HERE, before the
 * controller's FormRequests validate, so a tab the agency has not opened
 * for clients is the dead-link `404 {"message":"Not found."}` on every
 * endpoint and never a 422 (ruling IR4). Must run after
 * `client.session:brand`, which puts the brand on the request.
 */
class UseInsightBrandAccess
{
    public function __construct(private readonly InsightTabGuard $guard) {}

    public function handle(Request $request, Closure $next, string $surface): Response
    {
        $access = match ($surface) {
            'share' => app(ShareLinkBrandAccess::class),
            'portal' => app(PortalBrandAccess::class),
            default => throw new InvalidArgumentException("Unknown insight surface [{$surface}]."),
        };
        $request->attributes->set(InsightBrandAccess::class, $access);

        if ($access->audience() === InsightBrandAccess::AUDIENCE_CLIENT) {
            $brand = $access->brandFor($request);
            $method = (string) $request->route()?->getActionMethod();
            if (! $this->guard->isOpenToClients($brand, $method, $request)) {
                return response()->json(['message' => 'Not found.'], 404);
            }
        }

        return $next($request);
    }
}
```

- [ ] **Step 5: The portal routes** — in `routes/api.php`, directly after the closing `});` of the brand-scoped group

```php
Route::middleware(['throttle:public-portal', 'client.session:brand'])->group(function () {
    Route::get('public/portal/{workspaceSlug}/{brandSlug}/approvals', [PortalController::class, 'approvals'])
        ->name('public.portal.approvals');
});
```

add:

```php
// Client portal — Insights (spec 2026-10-07 §3.3): the 27 share insight
// endpoints behind the client session and an active lane. Each is closed
// unless its tab is open to clients (InsightTabGuard, run by
// `insight.access:portal`). No password, and no share-owned-label-filter
// throttle: it keys on {slug}, then the IP — here the web BFF's, one bucket
// for every client. The per-session public-portal bucket guards these.
Route::middleware(['throttle:public-portal', 'client.session:brand', 'insight.access:portal'])
    ->prefix('public/portal/{workspaceSlug}/{brandSlug}/insight')
    ->name('public.portal.insight.')
    ->group(function () {
        Route::get('/overview', [BrandShareInsightController::class, 'overview'])->name('overview');
        Route::get('/home', [BrandShareInsightController::class, 'home'])->name('home');
        Route::get('/signals', [BrandShareInsightController::class, 'signals'])->name('signals');
        Route::get('/signals/{id}', [BrandShareInsightController::class, 'signal'])->name('signal');
        Route::get('/reports', [BrandShareInsightController::class, 'reports'])->name('reports');
        Route::get('/reports/{reportId}', [BrandShareInsightController::class, 'report'])->name('report');
        Route::post('/reports/query', [BrandShareInsightController::class, 'reportQuery'])->name('reports.query');
        Route::get('/report-templates', [BrandShareInsightController::class, 'reportTemplates'])->name('report-templates');
        Route::get('/campaign', [BrandShareInsightController::class, 'campaign'])->name('campaign');
        Route::get('/campaign/filters', [BrandShareInsightController::class, 'campaignFilters'])->name('campaign.filters');
        Route::get('/paid-media/overview', [BrandShareInsightController::class, 'paidMediaOverview'])->name('paid-media.overview');
        Route::get('/paid-media/detail', [BrandShareInsightController::class, 'paidMediaDetail'])->name('paid-media.detail');
        Route::get('/paid-media/filters', [BrandShareInsightController::class, 'paidMediaFilters'])->name('paid-media.filters');
        Route::get('/owned-media/overview', [BrandShareInsightController::class, 'ownedMediaOverview'])->name('owned-media.overview');
        Route::get('/owned-media/detail', [BrandShareInsightController::class, 'ownedMediaDetail'])->name('owned-media.detail');
        Route::get('/owned-media/filters', [BrandShareInsightController::class, 'ownedMediaFilters'])->name('owned-media.filters');
        Route::get('/owned-media/sentiment', [BrandShareInsightController::class, 'ownedMediaSentiment'])->name('owned-media.sentiment');
        Route::get('/owned-media/label-attributes', [BrandShareInsightController::class, 'ownedMediaLabelAttributes'])->name('owned-media.label-attributes');
        Route::get('/owned-media/creative/playbooks', [BrandShareInsightController::class, 'creativePlaybooks'])->name('owned-media.creative.playbooks');
        Route::get('/owned-media/creative/playbook', [BrandShareInsightController::class, 'creativePlaybook'])->name('owned-media.creative.playbook');
        Route::get('/owned-media/content/{content_id}/creative-analysis', [BrandShareInsightController::class, 'creativeAnalysisShow'])->name('owned-media.creative-analysis');
        Route::get('/earned-media', [BrandShareInsightController::class, 'earnedMedia'])->name('earned-media');
        Route::get('/earned-media/influencers', [BrandShareInsightController::class, 'earnedMediaInfluencers'])->name('earned-media.influencers');
        Route::get('/earned-media/filters', [BrandShareInsightController::class, 'earnedMediaFilters'])->name('earned-media.filters');
        Route::get('/atl/overview', [BrandShareInsightController::class, 'atlOverview'])->name('atl.overview');
        Route::get('/atl/detail', [BrandShareInsightController::class, 'atlDetail'])->name('atl.detail');
        Route::get('/atl/filters', [BrandShareInsightController::class, 'atlFilters'])->name('atl.filters');
    });
```

(`BrandShareInsightController` is already imported at the top of `routes/api.php`.)

- [ ] **Step 6: Run, then the named mutations**

Run the Step 2 command. Expected: 1 + 29 + 5 passed (35). If "the Ads tab opens…" fails on `playbooks?tab=ads` with anything but a 404 body from the guard, dump the response: `listPlaybooks($brand, 'ads', false)` may touch the data service on `ads` — then replace that assertion's `assertOk()…` with `->assertStatus(…)` of the dumped status **plus** `->assertJsonMissingExact($this->notFound)` (the point is "not the guard's 404"), and log the correction. Then apply each mutation from the comment block, run, watch the named tests fail, restore, re-run green.

- [ ] **Step 7: Regression — share + existing portal tests**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/Share/BrandShareInsightCharacterizationTest.php tests/Feature/BrandSharePublicCreativeTest.php tests/Feature/BrandSharePublicRoutesTest.php tests/Feature/ClientPortal/PortalInboxTest.php tests/Feature/ClientPortal/ClientSessionTest.php --compact
```

Expected: green apart from Task 0's recorded baseline failures.

- [ ] **Step 8: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && for f in app/Services/Insights/PortalBrandAccess.php app/Services/Insights/InsightTabGuard.php app/Http/Middleware/UseInsightBrandAccess.php routes/api.php tests/Feature/ClientPortal/PortalInsightsTest.php; do php -l $f || exit 1; done && vendor/bin/pint app/Services/Insights/PortalBrandAccess.php app/Services/Insights/InsightTabGuard.php app/Http/Middleware/UseInsightBrandAccess.php routes/api.php tests/Feature/ClientPortal/PortalInsightsTest.php && vendor/bin/pint --test app/Services/Insights/PortalBrandAccess.php app/Services/Insights/InsightTabGuard.php app/Http/Middleware/UseInsightBrandAccess.php routes/api.php tests/Feature/ClientPortal/PortalInsightsTest.php && /usr/bin/git add app/Services/Insights/PortalBrandAccess.php app/Services/Insights/InsightTabGuard.php app/Http/Middleware/UseInsightBrandAccess.php routes/api.php tests/Feature/ClientPortal/PortalInsightsTest.php && /usr/bin/git commit -m "feat(api): client portal Insights routes behind the session, the lane and the per-tab Clients guard"
```

---

### Task 6: `GET public/portal/{ws}/{brand}/insight-info`

**Files:**
- Modify: `app/Http/Controllers/Api/ClientPortal/PortalController.php` (new method `insightInfo`, imports)
- Modify: `routes/api.php` (one route in the brand-scoped portal group)
- Test: `tests/Feature/ClientPortal/PortalInsightsTest.php` (append three tests; add imports `use App\Models\WorkspaceInsightsTabSetting;`)

**Interfaces:**
- Consumes: `InsightsTabResolver::resolveForClients()` (Task 1); `AuthenticateClientSession::BRAND`; `PublicBrandLogo::url(Brand): ?string`.
- Produces: `PortalController::insightInfo(Request $request, InsightsTabResolver $tabs): JsonResponse`, route name `public.portal.insight-info` (contract "Brand info for the portal Insights shell").

- [ ] **Step 1: Write the failing tests** — append to `tests/Feature/ClientPortal/PortalInsightsTest.php`

```php
/*
 * Mutation checks (plan Task 6, Step 4):
 * - use resolveForPublicShare() instead of resolveForClients() → "insight-info has…" fails at `overview` (true);
 * - drop the `'is_protected' => false` key → "insight-info keys match…" fails;
 * - read owned_media_table_view only when `link_enabled` → "insight-info has…" fails (null).
 */
test('insight-info has the share-info shape with the client tab map', function () {
    ($this->open)(['signals', 'owned-media']);
    BrandInsightsTabSetting::query()->where('brand_id', $this->brand->id)->where('tab_key', 'signals')->update(['label' => 'Trend radar']);
    WorkspaceInsightsTabSetting::query()->create(['workspace_id' => $this->f['workspace']->id, 'tab_key' => 'owned-media', 'label' => 'Q3 push']);
    BrandShareSetting::create([
        'brand_id' => $this->brand->id,
        'link_slug' => BrandShareSetting::generateUniqueSlug(),
        'link_enabled' => false,
        'link_is_protected' => false,
        'owned_media_table_view' => ['visibleColIds' => ['post', 'sentiment']],
    ]);

    $response = $this->getJson("{$this->portal}/insight-info", $this->as)->assertOk();
    $data = $response->json('data');
    $resolved = $data['insights_tab_settings']['resolved'];

    expect($response->json('message'))->toBe('Brand info retrieved successfully.')
        ->and($response->json('is_protected'))->toBeFalse()
        ->and($response->json())->not->toHaveKey('access_token')
        ->and(array_keys($data))->toBe(['brand_id', 'brand_name', 'brand_logo', 'insights_tab_settings', 'owned_media_table_view'])
        ->and($data['brand_id'])->toBe($this->brand->id)
        ->and($data['brand_name'])->toBe('Kopi Kenangan')
        ->and($data['brand_logo'])->toBeNull()
        ->and(array_keys($resolved))->toBe(InsightsTabKey::values())
        ->and($resolved['signals'])->toBe(['label' => 'Trend radar', 'is_visible' => true])
        // The workspace's internal label never reaches a client.
        ->and($resolved['owned-media'])->toBe(['label' => 'Social Media', 'is_visible' => true])
        ->and($resolved['overview'])->toBe(['label' => 'Overview', 'is_visible' => false])
        ->and($data['owned_media_table_view'])->toBe(['visibleColIds' => ['post', 'sentiment']]);
    expect($response->headers->get('Cache-Control'))->toContain('no-store');
});

test('insight-info keys match the public share-info keys', function () {
    $setting = BrandShareSetting::create([
        'brand_id' => $this->brand->id,
        'link_slug' => BrandShareSetting::generateUniqueSlug(),
        'link_enabled' => true,
        'link_is_protected' => false,
    ]);

    $public = $this->getJson("/api/v1/share/brand/{$setting->link_slug}")->assertOk()->json();
    $portal = $this->getJson("{$this->portal}/insight-info", $this->as)->assertOk()->json();

    expect(array_keys($portal))->toBe(array_keys($public))
        ->and(array_keys($portal['data']))->toBe(array_keys($public['data']))
        ->and(array_keys($portal['data']['insights_tab_settings']['resolved']))->toBe(array_keys($public['data']['insights_tab_settings']['resolved']));
});

test('insight-info needs a session and an active lane, and answers 200 with every tab closed when nothing is open', function () {
    $this->getJson("{$this->portal}/insight-info")->assertStatus(401)->assertExactJson(['code' => 'session_required', 'message' => 'Sign in to continue.']);

    $closed = $this->getJson("{$this->portal}/insight-info", $this->as)->assertOk();
    expect(collect($closed->json('data.insights_tab_settings.resolved'))->pluck('is_visible')->unique()->all())->toBe([false])
        ->and($closed->json('data.owned_media_table_view'))->toBeNull();

    $this->dina['lane']->forceFill(['revoked_at' => now()])->save();
    $this->getJson("{$this->portal}/insight-info", $this->as)->assertNotFound()->assertExactJson($this->notFound);
});
```

- [ ] **Step 2: Run to verify they fail**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/ClientPortal/PortalInsightsTest.php --compact
```

Expected: the three new tests FAIL — the route does not exist, so the session-carrying calls get Laravel's default 404 (the 401 assertion also fails: no middleware runs on an unknown route). The Task 5 tests still pass.

- [ ] **Step 3: Implement**

`app/Http/Controllers/Api/ClientPortal/PortalController.php` — add imports `use App\Models\BrandShareSetting;` and `use App\Services\InsightsTabResolver;` (alphabetical), and add this method after `approvals()`:

```php
    /**
     * GET public/portal/{workspace}/{brand}/insight-info (client portal
     * Insights spec 2026-10-07 §3.3, ruling IR7): the public share-info
     * envelope (BrandShareController::getBrandResponse) with the CLIENT tab
     * map — `is_visible` = the agency opened the tab for clients and it is on
     * in-app. Every tab key is present (the web reads a missing key as
     * visible). The table view is the brand's share setting whether or not
     * the public link is enabled.
     */
    public function insightInfo(Request $request, InsightsTabResolver $tabs): JsonResponse
    {
        /** @var Brand $brand */
        $brand = $request->attributes->get(AuthenticateClientSession::BRAND);
        $setting = BrandShareSetting::query()->where('brand_id', $brand->id)->first();

        return response()->json([
            'message' => 'Brand info retrieved successfully.',
            'data' => [
                'brand_id' => $brand->id,
                'brand_name' => $brand->name,
                'brand_logo' => PublicBrandLogo::url($brand),
                'insights_tab_settings' => [
                    'resolved' => (object) $tabs->resolveForClients($brand),
                ],
                'owned_media_table_view' => $setting?->owned_media_table_view,
            ],
            'is_protected' => false,
        ]);
    }
```

(`->first()` and the model attribute, never `->value('owned_media_table_view')`: `value()` skips the `array` cast and would return the raw JSON string.)

`routes/api.php` — inside the brand-scoped group, after the `approvals` route:

```php
    Route::get('public/portal/{workspaceSlug}/{brandSlug}/insight-info', [PortalController::class, 'insightInfo'])
        ->name('public.portal.insight-info');
```

- [ ] **Step 4: Run, then the named mutations** — run the Step 2 command. Expected: 38 passed. Apply each mutation from the comment block, watch the named test fail, restore, re-run green.

- [ ] **Step 5: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && for f in app/Http/Controllers/Api/ClientPortal/PortalController.php routes/api.php tests/Feature/ClientPortal/PortalInsightsTest.php; do php -l $f || exit 1; done && vendor/bin/pint app/Http/Controllers/Api/ClientPortal/PortalController.php routes/api.php tests/Feature/ClientPortal/PortalInsightsTest.php && vendor/bin/pint --test app/Http/Controllers/Api/ClientPortal/PortalController.php routes/api.php tests/Feature/ClientPortal/PortalInsightsTest.php && /usr/bin/git add app/Http/Controllers/Api/ClientPortal/PortalController.php routes/api.php tests/Feature/ClientPortal/PortalInsightsTest.php && /usr/bin/git commit -m "feat(api): portal insight-info — the share-info shape with the client tab map"
```

---

### Task 7: Client payload trims — `ideations`, `createdBy`, shared-in reports

**Files:**
- Modify: `app/Http/Controllers/Api/Share/BrandShareInsightController.php` (`forClient` helper; `signals`, `signal`, `reports`, `report`; two private report helpers)
- Test: `tests/Feature/ClientPortal/PortalInsightsTest.php` (append two tests; add imports `use App\Models\Brand;`, `use App\Models\BrandTrendSignal;`, `use App\Models\Report;`)

**Interfaces:**
- Consumes: `BrandShareInsightController::access()` / `brandFor()` (Task 4); `InsightBrandAccess::AUDIENCE_CLIENT`.
- Produces: `private function forClient(Request $request): bool`; `private function scopeReportsReadableBy(Builder $query, Brand $brand, bool $forClient): void`; `private function presentReport(Report $report, Brand $brand, bool $forClient): array`.

- [ ] **Step 1: Write the failing tests** — append to `tests/Feature/ClientPortal/PortalInsightsTest.php`

```php
/*
 * Mutation checks (plan Task 7, Step 4):
 * - drop `$heroSpotlight?->makeHidden('ideations')` → "clients read signals…" fails at `hero_spotlight`;
 * - drop the makeHidden in signal() → "clients read signals…" fails at the detail;
 * - keep the `orWhereRaw(... sharedToBrands ...)` for clients → "clients read only…" fails (two ids, then a 200 on the shared-in detail);
 * - drop `unset($arr['createdBy'])` → "clients read only…" fails at `createdBy`.
 * The public side of each is pinned by tests/Feature/Share/BrandShareInsightCharacterizationTest.php.
 */
test('clients read signals without the agency ideations', function () {
    ($this->open)(['signals']);
    $signal = BrandTrendSignal::query()->create([
        'workspace_id' => $this->brand->workspace_id,
        'brand_id' => $this->brand->id,
        'signal_name' => 'Ramadan iftar boxes',
        'description' => 'Creators unbox iftar hampers at sunset.',
        'reasoning' => 'High save rate on hamper unboxing posts.',
        'ideations' => [['title' => 'Iftar box unboxing', 'hook' => 'Open on the date reveal']],
    ]);

    $list = $this->getJson("{$this->base}/signals", $this->as)->assertOk();
    expect($list->json('data.data.0.id'))->toBe($signal->id)
        ->and($list->json('data.data.0.signal_name'))->toBe('Ramadan iftar boxes')
        ->and($list->json('data.data.0'))->not->toHaveKey('ideations')
        ->and($list->json('hero_spotlight.id'))->toBe($signal->id)
        ->and($list->json('hero_spotlight'))->not->toHaveKey('ideations');

    $detail = $this->getJson("{$this->base}/signals/{$signal->id}", $this->as)->assertOk();
    expect($detail->json('data.id'))->toBe($signal->id)
        ->and($detail->json('data'))->not->toHaveKey('ideations');
});

test("clients read only the brand's own reports, without createdBy", function () {
    ($this->open)(['campaigns']);
    $own = Report::factory()->create(['brand_id' => $this->brand->id, 'created_by' => $this->f['user']->id]);
    $sister = Brand::factory()->create(['name' => 'Sister Brand']);
    $sharedIn = Report::factory()->create([
        'brand_id' => $sister->id,
        'spec' => array_merge(Report::factory()->validSpec(), ['sharedToBrands' => [['brandId' => (string) $this->brand->id]]]),
    ]);

    $list = $this->getJson("{$this->base}/reports", $this->as)->assertOk();
    expect(array_column($list->json('data'), 'id'))->toBe([$own->id])
        ->and($list->json('data.0'))->not->toHaveKey('createdBy')
        ->and($list->json('data.0.sharingContext'))->toBe(['isOwned' => true])
        ->and($list->json('meta.total'))->toBe(1);

    $this->getJson("{$this->base}/reports/{$own->id}", $this->as)->assertOk()
        ->assertJsonPath('data.id', $own->id)
        ->assertJsonMissingPath('data.createdBy');
    $this->getJson("{$this->base}/reports/{$sharedIn->id}", $this->as)->assertNotFound()->assertExactJson(['message' => 'Report not found']);
});
```

- [ ] **Step 2: Run to verify they fail**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/ClientPortal/PortalInsightsTest.php --compact
```

Expected: "clients read signals…" FAILS (`data.data.0` has `ideations`); "clients read only…" FAILS (two ids). Everything else passes.

- [ ] **Step 3: Implement** in `app/Http/Controllers/Api/Share/BrandShareInsightController.php`

Add `use Illuminate\Database\Eloquent\Builder;` to the imports. Add after `brandFor()`:

```php
    /** True on the client portal: agency-internal fields are trimmed (spec I-5). */
    private function forClient(Request $request): bool
    {
        return $this->access($request)->audience() === InsightBrandAccess::AUDIENCE_CLIENT;
    }
```

`signals()` — after `$brand = $this->brandFor($request);` add `$forClient = $this->forClient($request);`, change the closure's `use ($brand, $request)` to `use ($brand, $request, $forClient)`, and insert right before its `return response()->json([`:

```php
            if ($forClient) {
                // Agency-internal creative ideas (client portal Insights I-5).
                $signals->getCollection()->each(fn (BrandTrendSignal $signal) => $signal->makeHidden('ideations'));
                $heroSpotlight?->makeHidden('ideations');
            }
```

`signal()` — after `$id = (string) $request->route('id');` add `$forClient = $this->forClient($request);`, change the closure's `use ($brand, $id)` to `use ($brand, $id, $forClient)`, and insert after the `if (! $signal) { … }` block:

```php
            if ($forClient) {
                $signal->makeHidden('ideations');
            }
```

`reports()` — replace the body after `$brand = $this->brandFor($request);` with:

```php
        $forClient = $this->forClient($request);

        return $this->withExceptionHandling('reports', $brand->id, function () use ($brand, $forClient) {
            $reports = Report::query()
                ->where(fn (Builder $query) => $this->scopeReportsReadableBy($query, $brand, $forClient))
                ->with(['createdBy:id,name,avatar'])
                ->orderByDesc('created_at')
                ->paginate(50);

            $items = collect($reports->items())
                ->map(fn (Report $report) => $this->presentReport($report, $brand, $forClient));

            return response()->json([
                'data' => $items,
                'meta' => [
                    'total' => $reports->total(),
                    'per_page' => $reports->perPage(),
                    'current_page' => $reports->currentPage(),
                    'last_page' => $reports->lastPage(),
                ],
            ]);
        });
```

`report()` — replace the body after `$reportId = (string) $request->route('reportId');` with:

```php
        $forClient = $this->forClient($request);

        return $this->withExceptionHandling('report', $brand->id, function () use ($brand, $reportId, $forClient) {
            $report = Report::query()
                ->where('id', $reportId)
                ->where(fn (Builder $query) => $this->scopeReportsReadableBy($query, $brand, $forClient))
                ->with('createdBy:id,name,avatar')
                ->first();

            if (! $report) {
                return response()->json(['message' => 'Report not found'], 404);
            }

            return response()->json(['data' => $this->presentReport($report, $brand, $forClient)]);
        });
```

Add these private helpers in the `// ─── Private Helpers` section, above `getCampaignFromTaxonomy()`:

```php
    /**
     * Reports the brand owns, plus — on the public link only — reports
     * another brand shared INTO it (`spec.sharedToBrands`). A client never
     * sees a shared-in report (client portal Insights I-5).
     *
     * @param  Builder<Report>  $query
     */
    private function scopeReportsReadableBy(Builder $query, Brand $brand, bool $forClient): void
    {
        $query->where('brand_id', $brand->id);

        if (! $forClient) {
            $query->orWhereRaw(
                "spec::jsonb @> jsonb_build_object('sharedToBrands', jsonb_build_array(jsonb_build_object('brandId', ?::text)))",
                [$brand->id]
            );
        }
    }

    /**
     * The report as the FE reads it, with its sharing context. A client
     * gets no `createdBy` (agency-internal, I-5).
     *
     * @return array<string, mixed>
     */
    private function presentReport(Report $report, Brand $brand, bool $forClient): array
    {
        $arr = $report->toArray();
        if ($report->brand_id === $brand->id) {
            $arr['sharingContext'] = ['isOwned' => true];
        } else {
            $sourceBrand = $report->brand()->first(['id', 'name', 'logo']);
            $arr['sharingContext'] = [
                'isOwned' => false,
                'sourceBrandName' => $sourceBrand?->name,
                'sourceBrandLogo' => $sourceBrand?->logo,
            ];
        }

        if ($forClient) {
            unset($arr['createdBy']);
        }

        return $arr;
    }
```

- [ ] **Step 4: Run portal + characterization, then the named mutations**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/ClientPortal/PortalInsightsTest.php tests/Feature/Share/BrandShareInsightCharacterizationTest.php --compact
```

Expected: 40 + 6 passed (the characterization file proves the public link still lists the shared-in report with `createdBy` and keeps `ideations`). Apply each mutation from the comment block, watch the named test fail, restore, re-run green.

- [ ] **Step 5: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && php -l app/Http/Controllers/Api/Share/BrandShareInsightController.php && php -l tests/Feature/ClientPortal/PortalInsightsTest.php && vendor/bin/pint app/Http/Controllers/Api/Share/BrandShareInsightController.php tests/Feature/ClientPortal/PortalInsightsTest.php && vendor/bin/pint --test app/Http/Controllers/Api/Share/BrandShareInsightController.php tests/Feature/ClientPortal/PortalInsightsTest.php && /usr/bin/git add app/Http/Controllers/Api/Share/BrandShareInsightController.php tests/Feature/ClientPortal/PortalInsightsTest.php && /usr/bin/git commit -m "feat(api): clients read Insights without ideations, report authors or shared-in reports"
```

---

### Task 8: Full run, contract notes, track file

**Files:**
- Modify: `docs/prd/client-lane-p0a/api.md` (new subsection before `## Scope`, i.e. at the end of `## Contract (frozen …)`)
- Modify: `docs/tracks/client-portal.track.md` (new section at the end)

**Interfaces:**
- Consumes: everything above.
- Produces: the contract notes the web plan reads; the audit trail.

- [ ] **Step 1: One full run of every file this plan touches or guards**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Unit/Services/InsightsTabResolverTest.php tests/Unit/Http/Requests/InsightsTabSettingsRequestTest.php tests/Feature/Brand/BrandInsightsTabClientVisibilityTest.php tests/Feature/Share/BrandShareInsightCharacterizationTest.php tests/Feature/ClientPortal/PortalInsightsTest.php tests/Feature/BrandSharePublicCreativeTest.php tests/Feature/BrandSharePublicRoutesTest.php tests/Feature/ClientPortal/ActiveLaneTest.php tests/Feature/ClientPortal/AddClientTest.php tests/Feature/ClientPortal/AgencyClientsTest.php tests/Feature/ClientPortal/ClientSessionTest.php tests/Feature/ClientPortal/PortalInboxTest.php tests/Feature/ClientPortal/RequestPageSessionTest.php tests/Feature/ClientPortal/ReservedWorkspaceSlugTest.php --compact
```

Expected: every new test green; the existing files show exactly Task 0's baseline failures and no new ones. Any new failure: STOP, debug (superpowers:systematic-debugging), fix in the owning task's files, and re-run.

- [ ] **Step 2: Route sanity**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && php -d memory_limit=1G artisan route:list --path=public/portal 2>/dev/null | /usr/bin/grep -c 'insight' && rm -f bootstrap/cache/routes-v7.php
```

Expected: `28` (27 insight routes + `insight-info`).

- [ ] **Step 3: Append the contract notes** — copies this plan's "API contract for web" and "Rulings" sections (headings demoted under one `###`) before `## Scope`:

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && python3 - <<'PY'
import re
plan = open('/Users/alva.e202511001/Desktop/work/frndos-agentic/docs/superpowers/plans/2026-10-07-client-portal-insights-api.md').read()
section = plan.split('\n## API contract for web\n', 1)[1].split('\n## Global Constraints\n', 1)[0]
section = re.sub(r'^## Rulings$', '#### Rulings', section, flags=re.M)
section = re.sub(r'^### ', '#### ', section, flags=re.M)
header = ('### Additive notes (client portal Insights — spec `docs/superpowers/specs/2026-10-07-client-portal-insights-design.md`, 2026-10-07)\n\n'
          'Plan: `docs/superpowers/plans/2026-10-07-client-portal-insights-api.md` (workspace root). '
          'Builds on the client portal notes above; header `X-Client-Session`.\n')
path = 'docs/prd/client-lane-p0a/api.md'
doc = open(path).read()
assert doc.count('\n## Scope\n') == 1, 'anchor not unique'
doc = doc.replace('\n## Scope\n', '\n' + header + section.rstrip() + '\n\n## Scope\n', 1)
open(path, 'w').write(doc)
PY
/usr/bin/grep -n '^### Additive notes (client portal Insights\|^#### Rulings\|^#### The 27 portal insight endpoints\|^## Scope' docs/prd/client-lane-p0a/api.md
```

Expected: the four headings print in that order, the new `###` directly above `## Scope`'s preceding lines. Open the file and confirm no `## ` heading was introduced inside `## Contract`.

- [ ] **Step 4: Append the track section** — add at the end of `docs/tracks/client-portal.track.md`:

```markdown

## Insights (spec 2026-10-07)

Spec: `docs/superpowers/specs/2026-10-07-client-portal-insights-design.md` (workspace root). Plan: `docs/superpowers/plans/2026-10-07-client-portal-insights-api.md`. Contract: "Additive notes (client portal Insights …)" in `docs/prd/client-lane-p0a/api.md`.

| Item | Status |
|------|--------|
| Spec | approved 2026-10-07 |
| Implementation (api) | completed — Tasks 1–7 |
| Tests | run on `frnd_testing` (Daffa's permission, 2026-10-07) |
| PR | not_submitted (same branch, no push) |

- [x] TASK-0: Pre-flight — clean worktree, `git pull --ff-only`, caches absent, baseline run
- [x] TASK-1: `brand_insights_tab_settings.client_visible` + `InsightsTabResolver::resolveForClients()`
- [x] TASK-2: Insights Tabs settings read/write `client_visible` (absent = keep)
- [x] TASK-3: Characterization of the public share insight responses
- [x] TASK-4: `InsightBrandAccess` seam, `insight.access`, controller off positional `$slug`
- [x] TASK-5: 27 portal insight routes, `PortalBrandAccess`, `InsightTabGuard` (client 404)
- [x] TASK-6: `GET public/portal/{ws}/{brand}/insight-info`
- [x] TASK-7: Client trims — `ideations`, `createdBy`, shared-in reports
- [x] TASK-8: Full run, contract notes, track
- [ ] Web plan (InsightSurface, portal Insights pages, Clients column, Review Signal fix — I-6) — separate
- [ ] **Open for Daffa:** trim more on clients? (`operator_notes`, `operator_score`, `is_bookmarked`, `status`, `user_id` on signals; `owner` on reports — served to the public link today, untouched here, ruling IR8)
- [ ] `security-review` skill on this branch before the PR

### Pest files (one process, `frnd_testing`)

New: `tests/Feature/Brand/BrandInsightsTabClientVisibilityTest.php`, `tests/Feature/Share/BrandShareInsightCharacterizationTest.php`, `tests/Feature/ClientPortal/PortalInsightsTest.php`; changed: `tests/Unit/Services/InsightsTabResolverTest.php`. Regression: Task 0's list.
```

Then append one Session Log entry under the existing `## Session Log` heading, below the last entry, recording **facts from this run** — one bullet each:
- the date, `daffa (Claude, <subagent-driven | native> plan execution)`, and the commit range (`/usr/bin/git log --oneline 4341acfec..HEAD`);
- Task 0's baseline failures (test names, or "none") and that Step 1 of this task showed no new ones;
- every expectation corrected under the Global Constraints rule (file, test, old → new value, why), or "none";
- every named mutation that did NOT make its test fail (and what was done), or "all named mutations failed their tests".

- [ ] **Step 5: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && /usr/bin/git add docs/prd/client-lane-p0a/api.md docs/tracks/client-portal.track.md && /usr/bin/git commit -m "docs(api): client portal Insights contract notes and track"
```

Do not push.

---

## Spec coverage (self-review, 2026-10-07)

| Spec item | Where |
|---|---|
| §1 goal: portal Insights gated by session + lane, client-visible tabs only | Tasks 5, 6 |
| I-1 api: access separated from presentation (resolver per surface) | Task 4 (seam, share), Task 5 (portal) |
| I-2 per-tab Clients, default OFF, server-side, independent of the public link | Task 1 (column default false), Task 2 (settings), Task 5 (guard; "the public share link ignores client visibility") |
| I-3 every access level | Task 5 "every access level reads…" |
| I-4 Business/Listening can be opened | Tab keys in `resolveForClients` + `insight-info` (Task 1/6); no api endpoints exist for them (IR5); the "Sample data" label is web |
| I-5 trims: ideations, createdBy, shared-in reports | Task 7 |
| I-6 Review Signal / Ask a follow-up on public Overview | web-only — not in this plan |
| §3.1 column, `resolveForClients`, settings endpoints, same permission | Tasks 1, 2 |
| §3.2 interface `brandFor`/`audience`, two implementations, no positional `$slug`, sub-ids from `$request->route()`, tab guard, client 404, public unchanged | Tasks 3, 4, 5 |
| §3.3 27 mirrored routes under `throttle:public-portal` + `client.session:brand`, no-store; `insight-info` shape = `getBrandResponse` | Tasks 5, 6 |
| §3.4 payload trim (client only) | Task 7 |
| §3.5 tests: resolver per audience; hidden 404 / visible 200; no session 401; revoked lane 404; trims; public unchanged; settings round-trip | Tasks 1, 2, 3, 5, 6, 7 |

Placeholder scan: no TBD/TODO; every code step carries code; the only run-time-filled text is Task 8 Step 4's session log, which records facts of the run. Type consistency: `InsightBrandAccess::AUDIENCE_CLIENT|PUBLIC`, `brandFor(Request): Brand`, `InsightTabGuard::TABS` / `tabsFor()` / `isOpenToClients()`, `resolveForClients(Brand)`, `PortalController::insightInfo(Request, InsightsTabResolver)` are named identically in every task that uses them.
