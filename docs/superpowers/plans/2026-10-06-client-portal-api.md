# Client Lane — Client Portal from the Share Links — API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give a client one device session that survives several brands, a per-brand access level (`own | all_approve | all_view`), a brand-scoped portal api (`public/portal/*`: me, approvals inbox, code sign-in, sign-out), session-aware request pages (`view_only`, "opened"), the agency's Clients endpoints and approver suggestions — and fix the two live bugs (a removed client keeps their lane; approver suggestions can never show clients).

**Architecture:** A new `client_sessions` table (hash-only token) is read by `ClientSessionService::principal()`, which builds a `ClientPrincipal { user, session, lanes[brand_id] }` from the client's **active lanes**. "Active" is one Eloquent scope, `ClientLaneLink::scopeHonoured()` (unrevoked, unexpired, and — for a personal lane — the holder still has the brand's `client` role), used by `ClientLaneService::activeLanesFor()/activeLane()/resolveHeader()` alike. The `client.session` middleware turns a missing principal into `401 session_required` and, on brand routes, a missing lane into the dead-link `404`. `PublicShareLinkController` resolves the viewer from the session first, then the legacy `X-Lane-Code`. The access level lives on the lane row; removing a client role revokes the lane through `UserBrandRole` model events, with the read-time role check as the guarantee for every path that bypasses events.

**Tech Stack:** Laravel 13, PHP 8.5, PostgreSQL (jsonb `@>` + GIN `jsonb_path_ops`, CHECK constraints, `ON CONFLICT` upsert), Pest 4.

**Spec:** `docs/superpowers/specs/2026-10-06-client-portal-from-share-links-design.md` (workspace root). This plan implements the api half: §4 (all), §5 (all), §7.1, §7.3 api, §8 api, and the two bug fixes of §1/§4.2. §10 open question 1 is resolved with its proposal (Task 11). Predecessors: `docs/superpowers/specs/2026-10-01-client-lane-kv-approval-requests-design.md`, `docs/superpowers/specs/2026-10-06-client-lane-deck-plan-approval-requests-design.md` and its plan `docs/superpowers/plans/2026-10-06-client-lane-deck-plan-requests-api.md` (its rulings S1–S13 still hold).

### Rulings (spec ambiguities resolved here; Task 12 writes them into the contract notes)

- **PR1 — The role condition of an active lane applies to personal lanes only.** A `verified_guest` lane has `user_id NULL` and no role; it stays active while unrevoked and unexpired, exactly as today. The rule is one scope, `ClientLaneLink::scopeHonoured()`. `activeLanesFor()`/`activeLane()` additionally drop lanes on a soft-deleted brand.
- **PR2 — Role removal revokes through `UserBrandRole` model events** (`deleted`, and `updated` when `brand_role_id` moves off the client role). The paths that today use **mass** queries, which fire no events — `BrandMemberController::destroy`/`update` (`DELETE|PUT v1/brands/{brand}/members/{user}`) and `BrandRoleController::unassign` — switch to per-model writes. Every other mass path (`AdminUserController` replace-all, DB cascades) is covered by the read-time check of PR1: the lane stops being honoured even though `revoked_at` stays null.
- **PR3 — A session needs a person.** Sessions are issued only for a personal lane's user. A code that ends in a `verified_guest` lane issues none. `POST public/lane/code/verify` issues one only when the body carries `issue_session: true` — today's web calls that endpoint from page JavaScript, and the spec (§6.1) forbids the token reaching JS; the new web sends the flag only from its server route. Old web → no flag → response unchanged.
- **PR4 — Exchange on a device that already has a session:** same person → no new session (`session_token: null`, keep the cookie); another person → the old session is revoked and a new one issued (one cookie holds one person).
- **PR5 — Sliding expiry is written at most once per 60 s per session** (`last_seen_at`, `expires_at = min(now + 30 d, created_at + 90 d)`), so a portal page load is not N writes.
- **PR6 — A view is recorded for any personal-lane viewer of a request link** — session or legacy `X-Lane-Code` — on `GET public/share-links/{token}` only. Otherwise "opened" would miss every client still on the `frnd_lane` cookie during the transition.
- **PR7 — `all_view` never decides:** `403 {code:"view_only"}` on request links **and** P0a round links; comments and pins stay allowed. In the inbox, `all_view` has an empty `waiting_on_you` and `my_role: "viewer"` everywhere, even on requests that name them.
- **PR8 — `counts` and `item_count` count items** (live approvals: decided = approved + approved_with_changes + changes_required, total = decided + pending; replaced and withdrawn approvals excluded). `item_count = counts.total`. Per-approver progress ("1 of 2") is read from `approvers[].decided`.
- **PR9 — Decided paging:** the first call returns decided requests resolved in the last 90 days (at most 50); `decided_next_cursor` is the `(resolved_at, id)` of the last row (or the 90-day boundary when the page is empty) whenever anything older exists. A call with `decided_cursor` returns the next 50, any age. Both waiting groups are returned in full on every call, ordered `decide_by` ascending (nulls last), then `sent_at` descending.
- **PR10 — `message_line`:** the first non-blank line of the message, at most 120 characters by `mb_strlen` (cut to 119 + `…`); `null` when there is none.
- **PR11 — `outcome_line`:** `outcome` = the request status; `by` = the actor of the newest non-advisory resolving decision (null when none, e.g. an agency-closed request); `at` = `resolved_at`; `note_excerpt` = that decision's note, at most 140 characters (139 + `…`), or null.
- **PR12 — A request whose subject no longer resolves** (deleted deck/plan/file) is left out of the inbox — there is nothing to open.
- **PR13 — Workspace slugs are never user input** (`Workspace::generateUniqueSlug()` derives them from the name; no controller validates a slug). "Refused by validation" = the generator skips reserved slugs (`session` → `session-2`) and the model refuses an explicit reserved slug on create and update with a `ValidationException`. The migration fails loudly naming any colliding workspace.
- **PR14 — Portal codes are `client_verification_codes` rows with `share_link_id NULL`**, scoped to (email, brand). A link code is never spendable in the portal and a portal code never on a link.
- **PR15 — Throttles:** exchange 20/min per IP; portal code request 10/min per IP + 5/hour per (email, brand); portal code verify 10/min per IP + 20/hour per (email, brand); authenticated portal routes 120/min per session token. **Known limit:** the web BFF proxies portal calls, so a "per IP" bucket sees the BFF's address — the (email, brand) bucket is the real guard there.
- **PR16 — Retention (§10 Q1):** a daily `client-lane:purge-sessions` deletes sessions 30 days after `expires_at` or `revoked_at`, except a session a decision points at (the record PDF reads it). `approval_request_views` are kept with the request.
- **PR17 — URLs:** inbox `url` is the relative `/s/{token}` (portal-internal navigation); the agency's `portal-link` is absolute (`config('app.frontend_url')`), like every other `personal_url` the agency copies. Both endpoint bodies wrap in `data`.
- **PR18 — Clients endpoints:** `permissions:brand.settings.read|write` (spec §7.1) + the brand in the caller's workspace (404 otherwise, as `BrandClientLaneLinkController::rotate`); `{user}` not holding the brand's client role → 404. The access level is stored on the active personal lane (minted if none). **Rotating a personal link carries its access level to the new lane.**
- **PR19 — Decision audit:** `approval_decisions.client_session_id` is an FK `nullOnDelete`. The record PDF reads a session created by code as "verified · this device" and one created by personal link as "personal link".
- **PR20 — Request page additions are additive:** `workspace.slug`, `access.view_only`, `viewer.access_level`, `viewer.session`, `request.approvers[].opened`. The agency `AgencyRequest` shape does not change (§10 Q2 is out of scope).
- **PR21 — Clients tab `added_from`** = the subject type of the oldest approval request on the brand naming the client (P0a rounds → null); `last_opened_at` = the newest `last_used_at` of the client's personal lanes on the brand (a session page open and every portal brand route touch the lane).
- **PR22 — Approver suggestions** = every holder of the brand's client role, sorted by name; a brand-less subject answers `[]`.

## API contract for web

> **Reconciled with the web plan (2026-10-06, coordinator).** These additions are part of the contract and are implemented by the named tasks. Each one gets a test assertion in that task, with a named mutation.
> 1. **`X-Client-Session-Expires-At`** (ISO-8601). The `client.session` middleware (Task 3) sets it on every 2xx response it authenticated, carrying the slid `expires_at`. The web proxy resets the cookie `Max-Age` from it.
> 2. **`Item.my_decision: null | { outcome, at }`** (Task 6). The viewer's newest resolving decision across the request's live approvals. It drives "You approved Mon".
> 3. **`Item.subject.version_label: string | null`** (Task 6). Deck and plan: `"v" + round` of the request's approval. KV: `null`, since a request has many artboards.
> 4. **Approver suggestions rows gain `user_id`** (Task 9): `{ user_id, name, email, access_level }`. The web's inline upgrade PATCH needs it.
> 5. **`X-Forwarded-For` is NOT trusted.** Per-IP throttles and `ip_hash` see the direct caller, which is usually the web proxy. The (email, brand) and per-session limits are the real guards. The web plan drops its XFF assumption.


Everything the web plan relies on. Field names are final. The session header is **`X-Client-Session`** (43-char base64url token). **The web BFF owns the `frnd_client` cookie**: only server routes ever send this header, and every endpoint that returns a `session_token` is meant to be called from a web server route, never from page JavaScript. Forward the browser's `User-Agent` on session-issuing calls (it becomes `device_label`). Every public response carries `Cache-Control: no-store`. Throttled responses are `429 {"message":"Too many attempts. Please try again later.","retry_after_seconds":n}`.

### Session exchange (`?k=` personal link → session)

**`POST public/client/session`** `{ lane_code: string(16) }`, optional `X-Client-Session` (the device's current cookie) →

```json
{ "data": { "session_token": "<43 chars>|null", "expires_at": "2026-11-05T10:00:00.000000Z",
            "workspace_slug": "fcn", "brand_slug": "frndglow" } }
```

- `200` always on success. `session_token: null` = the cookie already belongs to this person; keep it (PR4). A cookie of another person is revoked server-side; replace it.
- `404 {"message":"Not found."}` for an unknown, revoked or expired code, a code whose holder lost the client role, and a verified-guest code. `422` for a malformed `lane_code`. `429` (20/min/IP).

### Request-link code verify (changed, additive)

**`POST public/lane/code/verify`** `{ email, code, share_token, issue_session?: boolean }` → `200 {data:{lane_code, kind, expires_at}}` as today. **New:** with `issue_session: true` the data also carries `session_token` (`null` when the lane is a verified guest — PR3) and `session_expires_at`. Without the flag the body is byte-identical to today. Errors unchanged: `422 invalid_code` (+`attempts_left`) | `422 code_expired`.

### Portal sign-in (no session)

**`POST public/portal/{workspace}/{brand}/code`** `{ email }` → always `202 {"message":"If that address can open this portal, a code is on its way."}`, for an unknown workspace/brand, an unknown address, a revoked client, or a real send. `422` only for a malformed email. `429` (10/min/IP, 5/hour per email+brand).

**`POST public/portal/{workspace}/{brand}/code/verify`** `{ email, code: "\d{6}" }` →
`200 {"data":{"session_token":"<43>","expires_at":"…"}}` | `422 {"code":"invalid_code","message":"…","attempts_left":n}` | `422 {"code":"code_expired","message":"…"}` (no live portal code, 5 wrong tries, unknown brand, or the client was removed since the code was sent). `429` (10/min/IP, 20/hour per email+brand).

### Portal (session required)

All take `X-Client-Session`. Missing, malformed, revoked or expired → `401 {"code":"session_required","message":"Sign in to continue."}`. `429` (120/min per session).

**`GET public/portal/me`** →

```json
{ "data": {
  "user": { "name": "Dina Pratiwi", "email": "dina@tokopedia.com" },
  "brands": [
    { "workspace": { "name": "FCN", "slug": "fcn" },
      "brand": { "name": "frndGlow", "slug": "frndglow", "logo_url": null },
      "access_level": "all_approve",
      "waiting_on_you": 1 } ] } }
```

Active lanes only; ordered `waiting_on_you` desc, then brand name. `brands: []` is possible (every lane revoked) — the web shows the sign-in screen.

**`GET public/portal/{workspace}/{brand}/approvals?decided_cursor=`** → `404 {"message":"Not found."}` for unknown slugs or no active lane on that brand (no hint the brand exists); `422 {"code":"invalid_cursor","message":"…"}`;

```json
{ "data": {
  "brand": { "name": "frndGlow", "slug": "frndglow", "workspace": "FCN", "logo_url": null },
  "access_level": "own|all_approve|all_view",
  "waiting_on_you": [Item], "waiting_on_others": [Item], "decided": [Item],
  "decided_next_cursor": "opaque|null" } }
```

```text
Item = { request_id, number, url: "/s/{token}" | null (link revoked),
  subject: { type: "kv_file"|"deck"|"campaign", title, thumbnail_url|null, version_label: string|null },
  item_count,                       // = counts.total (PR8)
  message_line: string|null,        // PR10
  requested_by: { name: string|null },
  sent_at, decide_by,               // ISO-8601 | null
  my_role: "approver"|"viewer",     // approver = named AND access_level != all_view
  my_decision: null | { outcome, at },   // reconciled 2026-10-06
  approvers: [{ name, decided: bool, opened: bool }],
  counts: { decided, total },       // items (PR8)
  status: "pending"|"approved"|"approved_with_changes"|"changes_required",
  resolved_at: ISO|null,
  outcome_line: null | { outcome, by: string|null, at: ISO|null, note_excerpt: string|null } }  // decided only
```

Visibility: `own` → requests whose `approvers` name the user; `all_approve`/`all_view` → every request with `approval_requests.brand_id` = the brand. Withdrawn (`not_relevant`) never appear. Groups: `waiting_on_you` = pending ∧ named ∧ some live approval lacks the user's resolving decision ∧ not `all_view`; `waiting_on_others` = every other pending one; `decided` = not pending (PR9 paging).

**`DELETE public/portal/session`** → `204` (revokes this device's session).

### Request page `/s/{token}` (changed, additive)

**`GET public/share-links/{token}`** with `X-Client-Session` and/or `X-Lane-Code`. Viewer resolution: the session user's active lane on the subject's brand → else `X-Lane-Code` → else anonymous. New keys:

```json
{ "data": {
  "workspace": { "name": "FCN", "slug": "fcn" },
  "access": { "…": "…", "view_only": false },
  "viewer": { "kind": "anonymous|client|verified", "name": null, "email": null,
              "access_level": "own|all_approve|all_view|null", "session": false },
  "request": { "…": "…", "approvers": [{ "name": "Dina", "decided": false, "opened": true }] } } }
```

- `viewer.session: true` only when the lane came from the session (the web shows the portal header and "← Approvals" to `/s/{workspace.slug}/{brand.slug}`).
- `access.view_only: true` for an `all_view` lane → the web replaces the decision bar with the view-only notice.
- A personal-lane viewer's open is recorded (`opened`, PR6).

**`POST public/share-links/{token}/decision`** — new `403 {"code":"view_only","message":"…"}` for an `all_view` lane (request and round links). Otherwise unchanged; a decision made through a session stores it.

**`POST public/share-links/{token}/comments`** — unchanged (allowed for `all_view`).

### Agency — `auth:api`, same stack as `v1/brands/{brand}/members`

```text
ClientRow = { user: { id, name, email }, access_level: "own"|"all_approve"|"all_view",
  added_at: ISO|null, added_from: "KV approval request"|"Deck approval request"|"Plan approval request"|null,
  last_opened_at: ISO|null, status: "not_opened"|"active" }
```

| Endpoint | Permission | Success | Errors |
|---|---|---|---|
| `GET v1/brands/{brand}/clients` | `brand.settings.read` | `200 {data: ClientRow[]}` (oldest first) | `404` brand outside workspace, `403` |
| `PATCH v1/brands/{brand}/clients/{user}` `{access_level}` | `brand.settings.write` | `200 {data: ClientRow}` | `422` bad level, `404` not a client |
| `POST v1/brands/{brand}/clients/{user}/portal-link` | `brand.settings.write` | `200 {data: {url: "https://app…/s/{ws}/{brand}?k={code}"}}` — existing code reused, never rotated | `404` |
| `DELETE v1/brands/{brand}/clients/{user}` | `brand.settings.write` | `204` — client role removed, lane revoked, decisions kept | `404` |

**`GET v1/approval-requests/approver-suggestions?subject_type={kv_file|deck|campaign}&subject_id={ulid}`** — same authorisation as `POST v1/approval-requests` (subject outside the workspace → `404`, no request permission on the subject → `403`, `422` bad params) → `200 {data: [{user_id, name, email, access_level}]}`, the clients of the subject's brand sorted by name (`[]` for a brand-less deck).

**Changed:** `DELETE v1/brands/{brand}/members/{user}` and `PUT v1/brands/{brand}/members/{user}` (moving a client onto an internal role) now revoke that client's lane.

## Global Constraints

- **Repo + shell:** every command runs from the worktree root `/Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal` (created in Task 0). Agent shells reset cwd, so every shell call starts with `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && `. Paths below are relative to that root unless absolute. The shell is zsh; an `rtk` hook rewrites `grep`/`git` output, so commands use `/usr/bin/grep` and `/usr/bin/git`. Daffa's dev api on :9191 serves the main `api/` checkout — never edit it.
- **Branch:** `feature/daffa/vc-client-portal` (base chosen in Task 0). Never commit on `develop`. **Never push, never open a PR** (Daffa decides). **Never `git stash`** (a popped stale stash once corrupted files).
- **api/AGENTS.md, verbatim: "DO NOT MAKE OR RUN ANY TESTS WITHOUT USER PERMISSION."** Task 0 asks Daffa for ONE approval covering exactly the Pest files this plan names (7 existing + 6 new), run only on `frnd_testing`. Nothing is written or run before that yes; anything beyond the list needs a new ask.
- **Commit trailer:** none. `api/AGENTS.md` forbids attribution trailers and the repo rule wins over the session default. Message format `<type>(api): …`.
- **Test DB = `frnd_testing`. Never `frnd`** (the dev DB; the worktree `.env` points at it). `tests/TestCase.php` refuses any DB without a `test` token. Every test command in this plan has this exact shape — the `test ! -e` aborts the chain when a cached config would override the exported DB vars (it wiped the dev DB twice), and the stale route cache is deleted, never restored (it 405s new routes):
  `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest <file> [<file> …] --compact`
  If `test ! -e` stops the chain, run `php artisan config:clear` and retry. **File paths only**, one Pest process at a time; `--filter` only together with a file path (the suite mapper dies on `tests/Feature/Report/ReportQueryMultiBrandTest.php` otherwise). `TELESCOPE_ENABLED=false` is required (Telescope OOMs migrations); `-d memory_limit=2G` because 128M OOMs while loading routes after ~40 tests.
- **Tests in this plan were written from reading the code, not from running it** (lesson: six such tests proved defective in one feature). For every test: run it BEFORE the implementation step and confirm it fails *for the stated reason* (not a typo, not a fixture error); after it passes, apply the task's **named mutation**, watch the named test fail, restore, re-run green. If an assertion fails on UNCHANGED production code where the plan expected a pass (labels, JSON paths, counts, throttle arithmetic), dump the actual value, confirm it by reading the code, and correct the expectation — never weaken the behaviour under test — and log the correction in the track file.
- **Per-request headers only:** tests pass `X-Client-Session` / `X-Lane-Code` / `User-Agent` as the headers argument (`getJson($uri, $headers)`, `postJson($uri, $data, $headers)`), never `withHeader()` — it sticks to every later request in the test.
- **Queue is `sync` in tests:** every test file that can trigger a decision does `Bus::fake([SendApprovalRequestDigest::class])` and `Mail::fake()` in `beforeEach`.
- **Public write throttle:** `public-share-link-write` is 10/min per IP — keep ≤ 9 decision/comment POSTs per test.
- **Gates at every commit:** `php -l` on each touched PHP file; `vendor/bin/pint <touched files>` then `vendor/bin/pint --test <touched files>` must pass.
- **The `client` role is the permission; the lane is the credential.** Never insert `user_workspaces` for a client; never let `X-Client-Session` reach an `auth:api` route.
- **Enumeration safety:** every "no" on a public route is one of exactly three bodies — the dead-link `404 {"message":"Not found."}`, the code-request `202` body, or `401 session_required`. Never `abort(404)` on a public route (its body varies).
- Line numbers cite the deck/plan worktree `feature/daffa/vc-client-lane-deck-plan-requests @ aa70b5a63` as read on 2026-10-06. Earlier tasks shift them — re-read each file before editing and anchor edits on the quoted code.

## Review Focus

1. **A client is removed while their portal is open, and they serve a second brand.** The next request on the removed brand must be the dead-link 404 and `me` must drop it, while the other brand keeps working. → Task 6, test "brand routes need a session and an active lane on that brand; anything else is the one 404".
2. **An agency rotates a client's personal link after raising their access.** The fresh lane must keep `all_approve`, not fall back to `own` (rotation mints a new row with the column default). → Task 2, test "rotating a personal link keeps its access level".
3. **One laptop, two people:** a second client opens their own personal link on a device that holds the first client's session. The first session must be revoked and a new one issued, never silently reused for the wrong person. → Task 4, test "the same person keeps their session; another person on the device replaces it".
4. **A portal code is mailed, then the client is removed before typing it.** Verification must refuse (`code_expired`), not mint a session for someone with no lane. → Task 7, test "a portal code verifies into a session; link and portal codes never cross; a removed client gets nothing".
5. **A client still on the legacy `frnd_lane` cookie (old web, or a device without a session) opens a request link.** The page must read exactly as before and still count as "opened". → Task 5, test "without a session or with a dead one the page reads as before; the legacy header still works and counts as opened".

---

## File Structure

Create:
- `database/migrations/2026_10_06_200000_create_client_sessions_table.php` — sessions (hash-only token).
- `database/migrations/2026_10_06_200100_add_access_level_to_workspace_external_invites.php` — lane access level, default `own`, CHECK.
- `database/migrations/2026_10_06_200200_create_approval_request_views_table.php` — per (request, user) first/last open.
- `database/migrations/2026_10_06_200300_add_client_session_id_to_approval_decisions.php` — decision audit.
- `database/migrations/2026_10_06_200400_add_approvers_gin_index_to_approval_requests.php` — `own` filter index.
- `database/migrations/2026_10_06_200500_allow_portal_codes_in_client_verification_codes.php` — `share_link_id` nullable.
- `database/migrations/2026_10_06_200600_refuse_reserved_workspace_slugs.php` — loud collision check.
- `app/Models/ClientSession.php`, `app/Models/ApprovalRequestView.php`.
- `app/Services/ClientLane/ClientSessionService.php` — issue, principal, slide, revoke, device label.
- `app/Services/ClientLane/ClientPrincipal.php` — the bound request principal.
- `app/Services/ClientLane/ClientPortalInbox.php` — visibility + grouping + paging.
- `app/Services/ClientLane/BrandClients.php` — the agency's client rows, access level, removal.
- `app/Http/Middleware/AuthenticateClientSession.php` — alias `client.session`.
- `app/Http/Controllers/Api/ClientPortal/ClientSessionController.php` — `?k=` exchange.
- `app/Http/Controllers/Api/ClientPortal/PortalController.php` — me, approvals, sign-out.
- `app/Http/Controllers/Api/ClientPortal/PortalSignInController.php` — portal code request/verify.
- `app/Http/Controllers/Api/Brand/BrandClientController.php` — Clients tab.
- `app/Http/Resources/ClientPortal/PortalInboxPresenter.php` — the `Item` shape.
- `app/Support/ClientLane/PublicBrandLogo.php` — brand logo URL independent of `Accept`.
- `app/Console/Commands/PurgeClientSessionsCommand.php` — retention.
- Tests: `tests/Feature/ClientPortal/{ActiveLaneTest, ClientSessionTest, RequestPageSessionTest, PortalInboxTest, AgencyClientsTest, ReservedWorkspaceSlugTest}.php`.
- `docs/tracks/client-portal.track.md`.

Modify:
- `app/Models/ClientLaneLink.php` (access levels, `scopeHonoured`), `app/Models/ApprovalDecision.php` (`client_session_id`), `app/Models/UserBrandRole.php` (revoke events), `app/Models/Workspace.php` (reserved slugs).
- `app/Services/ClientLane/ClientLaneService.php`, `app/Services/ClientLane/ClientVerificationCodeService.php`.
- `app/Services/Approval/ApprovalActor.php`, `app/Services/Approval/ApprovalService.php` (`recordDecision`), `app/Services/Approval/ApprovalRecordPdf.php` (`verifiedBy`).
- `app/Http/Resources/Approval/ApprovalRequestPresenter.php` (`opened`).
- `app/Http/Controllers/Api/PublicShareLinkController.php`, `app/Http/Controllers/Api/PublicLaneController.php`, `app/Http/Controllers/Api/Approval/ApprovalRequestController.php`, `app/Http/Controllers/Api/Workspace/BrandMemberController.php`, `app/Http/Controllers/Api/Workspace/BrandRoleController.php`.
- `app/Providers/AppServiceProvider.php` (rate limiters), `bootstrap/app.php` (alias), `routes/api.php`, `routes/console.php`.
- `tests/Support/ClientLaneFixtures.php` (helpers), `tests/Feature/Approval/KvRequestCharacterizationTest.php` (pin the workspace slug) + `tests/Fixtures/approval-requests/kv-public.json` (re-recorded, additive keys only).
- `docs/prd/client-lane-p0a/api.md` (additive contract notes).

---

### Task 0: Pre-flight — base branch, permission, worktree, caches, baseline

**Files:** none changed (worktree + `vendor/` + `.env` only).

**Interfaces:**
- Consumes: nothing.
- Produces: the worktree, Daffa's answers (base branch, test permission), the baseline failure list every later task compares against.

- [ ] **Step 1: Check whether the deck/plan branch has merged**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && /usr/bin/git fetch origin && /usr/bin/git branch -r --contains feature/daffa/vc-client-lane-deck-plan-requests | /usr/bin/grep -x '  origin/develop' || echo "NOT MERGED"
```

Expected: `  origin/develop` (merged) or `NOT MERGED`. Note the answer for the question below.

- [ ] **Step 2: Ask Daffa (AskUserQuestion), two questions in one call**
  1. "Base branch for `feature/daffa/vc-client-portal`? (Step 1 says: <merged | NOT MERGED>)" Options: *From `origin/develop` (deck/plan has merged)* / *Stacked on `feature/daffa/vc-client-lane-deck-plan-requests` (not merged yet)* / *Stop*. On *Stop*: STOP.
  2. "May I create and run these Pest files on `frnd_testing` only? Existing (baseline + regression): `tests/Feature/Approval/DeckPlanRequestFlowTest.php`, `tests/Feature/Approval/KvRequestCharacterizationTest.php` (incl. one re-record of `kv-public.json` in Task 5), `tests/Feature/Approval/ApprovalRequestDigestTest.php`, `tests/Feature/Approval/KvArtboardThumbnailTest.php`, `tests/Feature/Approval/KvSharePayloadItemsForTest.php`, `tests/Feature/Sharing/ShareLinksRevokedListenerTest.php`, `tests/Unit/Mail/ClientVerificationCodeMailTest.php`. New: `tests/Feature/ClientPortal/ActiveLaneTest.php`, `ClientSessionTest.php`, `RequestPageSessionTest.php`, `PortalInboxTest.php`, `AgencyClientsTest.php`, `ReservedWorkspaceSlugTest.php`." Options: *Yes* / *No*. On *No*: STOP.

- [ ] **Step 3: Create the worktree from the chosen base**

From `origin/develop`:

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && /usr/bin/git worktree add .worktrees/client-portal -b feature/daffa/vc-client-portal origin/develop
```

Stacked:

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && /usr/bin/git worktree add .worktrees/client-portal -b feature/daffa/vc-client-portal feature/daffa/vc-client-lane-deck-plan-requests
```

Expected: `Preparing worktree (new branch 'feature/daffa/vc-client-portal')`. (`.worktrees/` is git-ignored.)

- [ ] **Step 4: Install dependencies and the env file**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && cp ../../.env .env && composer install --no-interaction --quiet && /usr/bin/git status --short
```

Expected: `git status` prints nothing. Do NOT symlink `vendor/` (Composer's autoloader would load the main checkout's classes).

- [ ] **Step 5: Cache and DB checks**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && ls bootstrap/cache/config.php bootstrap/cache/routes-v7.php 2>/dev/null; psql -lqt | cut -d'|' -f1 | /usr/bin/grep -w frnd_testing; ls app/Services/Approval/Subjects/ApprovalRequestSubject.php
```

Expected: no cache file listed (if one is: `php artisan config:clear`, `rm bootstrap/cache/routes-v7.php`); `frnd_testing` printed (if missing: `psql -d postgres -c 'CREATE DATABASE frnd_testing'`); the subject-adapter file exists (it proves the deck/plan code is in the base — if missing, STOP: the base is wrong).

- [ ] **Step 6: Baseline run of the existing files (one process)**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/Approval/DeckPlanRequestFlowTest.php tests/Feature/Approval/KvRequestCharacterizationTest.php tests/Feature/Approval/ApprovalRequestDigestTest.php tests/Feature/Approval/KvArtboardThumbnailTest.php tests/Feature/Approval/KvSharePayloadItemsForTest.php tests/Feature/Sharing/ShareLinksRevokedListenerTest.php tests/Unit/Mail/ClientVerificationCodeMailTest.php --compact
```

Expected: a pass/fail summary. Write every failing test name into a scratch note (it goes into the track file in Task 12). These are **pre-existing**: later tasks must not add to them and must not "fix" them. If the run dies in `migrate:fresh`, STOP and report.

- [ ] **Step 7: No commit** (nothing tracked changed).

---
### Task 1: Schema — sessions, access level, views, decision audit, GIN index, link-less codes

**Files:**
- Create: `database/migrations/2026_10_06_200000_create_client_sessions_table.php`
- Create: `database/migrations/2026_10_06_200100_add_access_level_to_workspace_external_invites.php`
- Create: `database/migrations/2026_10_06_200200_create_approval_request_views_table.php`
- Create: `database/migrations/2026_10_06_200300_add_client_session_id_to_approval_decisions.php`
- Create: `database/migrations/2026_10_06_200400_add_approvers_gin_index_to_approval_requests.php`
- Create: `database/migrations/2026_10_06_200500_allow_portal_codes_in_client_verification_codes.php`
- Create: `app/Models/ClientSession.php`, `app/Models/ApprovalRequestView.php`
- Modify: `app/Models/ClientLaneLink.php` (constants, fillable, `@property`)
- Modify: `app/Models/ApprovalDecision.php` (fillable, `@property`, `clientSession()`)
- Modify: `tests/Support/ClientLaneFixtures.php` (`clientRole`, `personalLane` grants the role, `namedClient`, `deckOn`)
- Test: `tests/Feature/ClientPortal/ActiveLaneTest.php` (created here)

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `App\Models\ClientSession` (ULID; `user_id`, `token_hash`, `created_via`, `device_label`, `ip_hash`, `last_seen_at`, `expires_at`, `revoked_at`); consts `VIA_PERSONAL_LINK = 'personal_link'`, `VIA_CODE = 'code'`, `VIA`; `user(): BelongsTo`; `scopeLive(Builder): Builder`; `static hashToken(string $token): string`.
  - `App\Models\ApprovalRequestView`; `static record(string $requestId, string $userId): void`; `static openedBy(array $requestIds): array<string, list<string>>`.
  - `ClientLaneLink::ACCESS_OWN|ACCESS_ALL_APPROVE|ACCESS_ALL_VIEW`, `ClientLaneLink::ACCESS_LEVELS`, attribute `access_level` (string, default `own`).
  - `ApprovalDecision::$client_session_id`, `ApprovalDecision::clientSession(): BelongsTo`.
  - `ClientLaneFixtures::clientRole(string $workspaceId): BrandRole`, `ClientLaneFixtures::namedClient(Brand $brand, string $email, string $name): array{user: User, lane: ClientLaneLink}`, `ClientLaneFixtures::deckOn(array $fixture, string $title): Deck`; `ClientLaneFixtures::personalLane()` now also puts the client on the brand's `client` role.

- [ ] **Step 1: Write the failing schema test**

Create `tests/Feature/ClientPortal/ActiveLaneTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Jobs\SendApprovalRequestDigest;
use App\Models\ApprovalRequestView;
use App\Models\ClientVerificationCode;
use Illuminate\Database\QueryException;
use Illuminate\Support\Facades\Bus;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Mail;
use Illuminate\Support\Facades\Schema;
use Tests\Support\ClientLaneFixtures;

/**
 * Client portal (spec 2026-10-06 §4.1–§4.2): the schema, the active-lane
 * rule (bug 1) and the revocation of a lane when its client role goes.
 */
beforeEach(function () {
    Mail::fake();
    Bus::fake([SendApprovalRequestDigest::class]);
    config(['app.frontend_url' => 'https://app.frndos.test']);
});

test('the portal schema is in place: sessions, views, access level default own, decision session id, approvers GIN, link-less codes', function () {
    expect(Schema::hasColumns('client_sessions', [
        'id', 'user_id', 'token_hash', 'created_via', 'device_label', 'ip_hash',
        'last_seen_at', 'expires_at', 'revoked_at', 'created_at', 'updated_at',
    ]))->toBeTrue()
        ->and(Schema::hasColumns('approval_request_views', ['approval_request_id', 'user_id', 'first_opened_at', 'last_opened_at']))->toBeTrue()
        ->and(Schema::hasColumn('approval_decisions', 'client_session_id'))->toBeTrue();

    $f = ClientLaneFixtures::sendRequest('deck');
    $lane = ClientLaneFixtures::personalLane($f['brand']);
    expect($lane->fresh()->access_level)->toBe('own');

    // A view row: first open sets both stamps, a later one only moves `last`.
    ApprovalRequestView::record((string) $f['request']->id, (string) $lane->user_id);
    $this->travel(1)->hours();
    ApprovalRequestView::record((string) $f['request']->id, (string) $lane->user_id);
    $view = ApprovalRequestView::query()->sole();
    expect($view->last_opened_at->greaterThan($view->first_opened_at))->toBeTrue()
        ->and(ApprovalRequestView::openedBy([(string) $f['request']->id]))->toBe([(string) $f['request']->id => [(string) $lane->user_id]]);

    // A portal code carries no link.
    ClientVerificationCode::create([
        'email' => 'dina@brand.test',
        'brand_id' => (string) $f['brand']->id,
        'share_link_id' => null,
        'code_hash' => ClientVerificationCode::hashCode('123456'),
        'attempts' => 0,
        'expires_at' => now()->addMinutes(ClientVerificationCode::TTL_MINUTES),
    ]);
    expect(ClientVerificationCode::query()->whereNull('share_link_id')->count())->toBe(1);

    $gin = DB::selectOne("SELECT indexdef FROM pg_indexes WHERE indexname = 'approval_requests_approvers_gin'");
    expect($gin?->indexdef)->toContain('gin')->toContain('jsonb_path_ops');

    // Last: a CHECK violation aborts the transaction; the savepoint keeps
    // RefreshDatabase's outer transaction usable.
    expect(fn () => DB::transaction(fn () => DB::table('workspace_external_invites')
        ->where('id', $lane->id)->update(['access_level' => 'admin'])))->toThrow(QueryException::class);
});
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/ClientPortal/ActiveLaneTest.php --compact
```

Expected: FAIL — `Schema::hasColumns('client_sessions', …)` is false (no table), or `Class "App\Models\ApprovalRequestView" not found`.

- [ ] **Step 3: Write the six migrations**

`database/migrations/2026_10_06_200000_create_client_sessions_table.php`:

```php
<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * Client portal (spec 2026-10-06 §4.1, P-3): one row per signed-in device of
 * a client — what the web's `frnd_client` cookie points at. Only the sha256
 * of the 32-byte token is stored; the token itself exists in the cookie and
 * nowhere else. `expires_at` slides 30 days from last use, capped at 90 days
 * from creation (ClientSessionService).
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('client_sessions', function (Blueprint $table) {
            $table->ulid('id')->primary();
            $table->foreignUlid('user_id')->constrained('users')->cascadeOnDelete();
            $table->char('token_hash', 64)->unique();
            $table->string('created_via', 16);
            $table->string('device_label', 120)->nullable();
            $table->char('ip_hash', 64)->nullable();
            $table->timestampTz('last_seen_at')->nullable();
            $table->timestampTz('expires_at');
            $table->timestampTz('revoked_at')->nullable();
            $table->timestampsTz();

            $table->index('user_id');
        });

        if (DB::getDriverName() === 'pgsql') {
            DB::statement(
                'ALTER TABLE client_sessions ADD CONSTRAINT client_sessions_created_via_check '
                ."CHECK (created_via IN ('personal_link', 'code'))"
            );
        }
    }

    public function down(): void
    {
        Schema::dropIfExists('client_sessions');
    }
};
```

`database/migrations/2026_10_06_200100_add_access_level_to_workspace_external_invites.php`:

```php
<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * Client portal (spec 2026-10-06 §4.1, P-6): an access level per client per
 * brand, on the lane row. `own` (requests naming them), `all_approve` (every
 * request; decides those naming them), `all_view` (every request, read-only).
 * NOT NULL with a default: Postgres writes `own` into every existing row,
 * which is the backfill — the release opens nothing new.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('workspace_external_invites', function (Blueprint $table) {
            $table->string('access_level', 16)->default('own');
        });

        if (DB::getDriverName() === 'pgsql') {
            DB::statement(
                'ALTER TABLE workspace_external_invites ADD CONSTRAINT workspace_external_invites_access_level_check '
                ."CHECK (access_level IN ('own', 'all_approve', 'all_view'))"
            );
        }
    }

    public function down(): void
    {
        if (DB::getDriverName() === 'pgsql') {
            DB::statement('ALTER TABLE workspace_external_invites DROP CONSTRAINT IF EXISTS workspace_external_invites_access_level_check');
        }

        Schema::table('workspace_external_invites', function (Blueprint $table) {
            $table->dropColumn('access_level');
        });
    }
};
```

`database/migrations/2026_10_06_200200_create_approval_request_views_table.php`:

```php
<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Client portal (spec 2026-10-06 §4.1, §4.5): who opened a request link —
 * one row per (request, client), first and last open. Read as "Opened /
 * Not opened" beside each approver. Kept with the request (§10 Q1).
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('approval_request_views', function (Blueprint $table) {
            $table->id();
            $table->foreignUlid('approval_request_id')->constrained('approval_requests')->cascadeOnDelete();
            $table->foreignUlid('user_id')->constrained('users')->cascadeOnDelete();
            $table->timestampTz('first_opened_at');
            $table->timestampTz('last_opened_at');

            $table->unique(['approval_request_id', 'user_id']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('approval_request_views');
    }
};
```

`database/migrations/2026_10_06_200300_add_client_session_id_to_approval_decisions.php`:

```php
<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Client portal (spec 2026-10-06 §4.1, §4.5): the device session a decision
 * was made through — audit, and the record PDF's "verified · this device".
 * The retention purge never deletes a session a decision points at; a user
 * deletion still cascades the session away, which nulls this.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('approval_decisions', function (Blueprint $table) {
            $table->foreignUlid('client_session_id')->nullable()->constrained('client_sessions')->nullOnDelete();
            $table->index('client_session_id');
        });
    }

    public function down(): void
    {
        Schema::table('approval_decisions', function (Blueprint $table) {
            $table->dropForeign(['client_session_id']);
            $table->dropIndex(['client_session_id']);
            $table->dropColumn('client_session_id');
        });
    }
};
```

`database/migrations/2026_10_06_200400_add_approvers_gin_index_to_approval_requests.php`:

```php
<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Support\Facades\DB;

/**
 * Client portal (spec 2026-10-06 §4.1): the `own` inbox filter is
 * `approvers @> '[{"user_id": …}]'` (whereJsonContains); `jsonb_path_ops`
 * indexes exactly the `@>` operator, smaller than the default opclass.
 */
return new class extends Migration
{
    public function up(): void
    {
        if (DB::getDriverName() !== 'pgsql') {
            return;
        }

        DB::statement('CREATE INDEX IF NOT EXISTS approval_requests_approvers_gin ON approval_requests USING GIN (approvers jsonb_path_ops)');
    }

    public function down(): void
    {
        if (DB::getDriverName() !== 'pgsql') {
            return;
        }

        DB::statement('DROP INDEX IF EXISTS approval_requests_approvers_gin');
    }
};
```

`database/migrations/2026_10_06_200500_allow_portal_codes_in_client_verification_codes.php`:

```php
<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * Client portal (spec 2026-10-06 §5.3): a portal sign-in code is bound to
 * (address, brand), not to a link — `share_link_id` NULL. A link code is
 * looked up by `share_link_id = ?` and a portal code by `share_link_id IS
 * NULL`, so the two can never be spent in each other's place.
 */
return new class extends Migration
{
    public function up(): void
    {
        if (DB::getDriverName() === 'pgsql') {
            DB::statement('ALTER TABLE client_verification_codes ALTER COLUMN share_link_id DROP NOT NULL');
        }

        Schema::table('client_verification_codes', function (Blueprint $table) {
            $table->index(['email', 'brand_id']);
        });
    }

    public function down(): void
    {
        Schema::table('client_verification_codes', function (Blueprint $table) {
            $table->dropIndex(['email', 'brand_id']);
        });

        if (DB::getDriverName() === 'pgsql') {
            DB::statement('DELETE FROM client_verification_codes WHERE share_link_id IS NULL');
            DB::statement('ALTER TABLE client_verification_codes ALTER COLUMN share_link_id SET NOT NULL');
        }
    }
};
```

- [ ] **Step 4: Write the two models**

`app/Models/ClientSession.php`:

```php
<?php

declare(strict_types=1);

namespace App\Models;

// craftsman-ignore: PHP002 — Eloquent models are not final in this codebase.

use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Concerns\HasUlids;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Support\Carbon;

/**
 * One signed-in device of a client (client portal, spec 2026-10-06 §4.1).
 * The person, not the brand: what a session may open is decided per
 * request from the client's active lanes ({@see \App\Services\ClientLane\ClientSessionService}).
 *
 * @property string $id
 * @property string $user_id
 * @property string $token_hash
 * @property string $created_via
 * @property string|null $device_label
 * @property string|null $ip_hash
 * @property Carbon|null $last_seen_at
 * @property Carbon $expires_at
 * @property Carbon|null $revoked_at
 * @property Carbon|null $created_at
 * @property-read User|null $user
 */
class ClientSession extends Model
{
    use HasUlids;

    protected $table = 'client_sessions';

    public const VIA_PERSONAL_LINK = 'personal_link';

    public const VIA_CODE = 'code';

    /** @var list<string> */
    public const VIA = [self::VIA_PERSONAL_LINK, self::VIA_CODE];

    protected $fillable = [
        'user_id',
        'token_hash',
        'created_via',
        'device_label',
        'ip_hash',
        'last_seen_at',
        'expires_at',
        'revoked_at',
    ];

    /** A hash, but still never part of any payload. */
    protected $hidden = ['token_hash'];

    protected function casts(): array
    {
        return [
            'last_seen_at' => 'datetime',
            'expires_at' => 'datetime',
            'revoked_at' => 'datetime',
        ];
    }

    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    /** Not revoked, not expired. */
    public function scopeLive(Builder $query): Builder
    {
        return $query->whereNull('revoked_at')->where('expires_at', '>', now());
    }

    public static function hashToken(string $token): string
    {
        return hash('sha256', $token);
    }
}
```

`app/Models/ApprovalRequestView.php`:

```php
<?php

declare(strict_types=1);

namespace App\Models;

// craftsman-ignore: PHP002 — Eloquent models are not final in this codebase.

use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Carbon;

/**
 * A named client's opens of a request link (client portal, spec 2026-10-06
 * §4.5): read as "Opened / Not opened" beside each approver.
 *
 * @property int $id
 * @property string $approval_request_id
 * @property string $user_id
 * @property Carbon $first_opened_at
 * @property Carbon $last_opened_at
 */
class ApprovalRequestView extends Model
{
    protected $table = 'approval_request_views';

    public $timestamps = false;

    protected $fillable = ['approval_request_id', 'user_id', 'first_opened_at', 'last_opened_at'];

    protected function casts(): array
    {
        return [
            'first_opened_at' => 'datetime',
            'last_opened_at' => 'datetime',
        ];
    }

    /** First open sets both stamps; every later one moves only `last_opened_at` (one statement, race-free). */
    public static function record(string $requestId, string $userId): void
    {
        $now = now();

        static::query()->upsert(
            [['approval_request_id' => $requestId, 'user_id' => $userId, 'first_opened_at' => $now, 'last_opened_at' => $now]],
            ['approval_request_id', 'user_id'],
            ['last_opened_at'],
        );
    }

    /**
     * @param  list<string>  $requestIds
     * @return array<string, list<string>> request id → ids of the users who opened it
     */
    public static function openedBy(array $requestIds): array
    {
        if ($requestIds === []) {
            return [];
        }

        $out = [];
        foreach (static::query()->whereIn('approval_request_id', $requestIds)->get(['approval_request_id', 'user_id']) as $row) {
            $out[(string) $row->approval_request_id][] = (string) $row->user_id;
        }

        return $out;
    }
}
```

- [ ] **Step 5: Extend `ClientLaneLink` and `ApprovalDecision`**

In `app/Models/ClientLaneLink.php`, add `@property string $access_level` under `@property string $kind`, add after `public const VERIFIED_GUEST_DAYS = 30;`:

```php
    /** Access levels per client per brand (client portal, spec 2026-10-06 P-6). */
    public const ACCESS_OWN = 'own';

    public const ACCESS_ALL_APPROVE = 'all_approve';

    public const ACCESS_ALL_VIEW = 'all_view';

    /** @var list<string> */
    public const ACCESS_LEVELS = [self::ACCESS_OWN, self::ACCESS_ALL_APPROVE, self::ACCESS_ALL_VIEW];
```

and add `'access_level',` to `$fillable` after `'verified_at',`.

In `app/Models/ApprovalDecision.php`: add `@property string|null $client_session_id` under `@property string|null $ip_hash`, add `'client_session_id',` to `$fillable` after `'ip_hash',`, and add after `laneLink()`:

```php
    /** The device session the decision was made through (client portal §4.5), when there was one. */
    public function clientSession(): BelongsTo
    {
        return $this->belongsTo(ClientSession::class, 'client_session_id');
    }
```

- [ ] **Step 6: Fixture helpers in `tests/Support/ClientLaneFixtures.php`**

Add imports `use App\Models\BrandRole;`, `use App\Models\UserBrandRole;`, `use App\Services\ClientLane\ClientLaneService;`. Replace `personalLane()` with:

```php
    /**
     * A named client's personal lane on `$brand` (what a personal link
     * carries), WITH the brand's `client` role — without the role a personal
     * lane is not active (client portal §4.2).
     */
    public static function personalLane(Brand $brand, ?User $client = null): ClientLaneLink
    {
        $client ??= User::factory()->create(['email' => 'dina@brand.test', 'name' => 'Dina']);

        UserBrandRole::query()->updateOrCreate(
            ['user_id' => $client->id, 'brand_id' => $brand->id],
            ['brand_role_id' => self::clientRole((string) $brand->workspace_id)->id, 'workspace_id' => $brand->workspace_id],
        );

        return ClientLaneLink::factory()->create([
            'workspace_id' => $brand->workspace_id,
            'brand_id' => $brand->id,
            'user_id' => $client->id,
            'email' => $client->email,
            'kind' => ClientLaneLink::KIND_PERSONAL,
            'verified_at' => now(),
        ]);
    }
```

and add below it:

```php
    /** The workspace's locked external `client` brand role (BrandRoleProvisioningService seeds it in production). */
    public static function clientRole(string $workspaceId): BrandRole
    {
        return BrandRole::withoutGlobalScopes()->firstOrCreate(
            ['workspace_id' => $workspaceId, 'slug' => BrandRole::CLIENT_SLUG],
            ['name' => 'Client', 'is_locked' => true, 'is_default' => true, 'scope' => BrandRole::SCOPE_EXTERNAL],
        );
    }

    /**
     * A client the agency named, the production way: user + client role +
     * personal lane (ClientLaneService::ensureClientUser / mintLaneLink).
     *
     * @return array{user: User, lane: ClientLaneLink}
     */
    public static function namedClient(Brand $brand, string $email, string $name): array
    {
        self::clientRole((string) $brand->workspace_id);
        $lanes = app(ClientLaneService::class);
        $user = $lanes->ensureClientUser($brand, $email);
        $user->forceFill(['name' => $name])->save();

        return ['user' => $user, 'lane' => $lanes->mintLaneLink($brand, $user)];
    }

    /** Another deck on a `deck()` fixture's brand, so one brand can hold many requests. */
    public static function deckOn(array $fixture, string $title): Deck
    {
        return Deck::factory()->create([
            'workspace_id' => $fixture['workspace']->id,
            'brand_id' => $fixture['brand']->id,
            'created_by' => $fixture['user']->id,
            'title' => $title,
            'preview_url' => null,
            'document' => ['schema_version' => 1, 'slides' => [['id' => 's1', 'layout' => 'title', 'elements' => []]]],
        ]);
    }
```

Note: `clientRole()` must run before any `actingAs` in a test, or `HasWorkspaceScope`'s saving hook rewrites `workspace_id` to the acting user's workspace (harmless when it is the same workspace, which every test here arranges).

- [ ] **Step 7: Run the test to verify it passes**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/ClientPortal/ActiveLaneTest.php --compact
```

Expected: PASS (1 test).

- [ ] **Step 8: Mutation check**

Remove `->default('own')` from the access-level migration → the test fails at `access_level` (`null`, or the migration fails NOT NULL on existing rows). Change `['last_opened_at']` to `['first_opened_at', 'last_opened_at']` in `ApprovalRequestView::record` → the `greaterThan` assertion fails. Restore both; re-run green.

- [ ] **Step 9: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && for f in database/migrations/2026_10_06_2000*.php database/migrations/2026_10_06_2001*.php database/migrations/2026_10_06_2002*.php database/migrations/2026_10_06_2003*.php database/migrations/2026_10_06_2004*.php database/migrations/2026_10_06_2005*.php app/Models/ClientSession.php app/Models/ApprovalRequestView.php app/Models/ClientLaneLink.php app/Models/ApprovalDecision.php tests/Support/ClientLaneFixtures.php tests/Feature/ClientPortal/ActiveLaneTest.php; do php -l "$f" || exit 1; done && vendor/bin/pint database/migrations/2026_10_06_200000_create_client_sessions_table.php database/migrations/2026_10_06_200100_add_access_level_to_workspace_external_invites.php database/migrations/2026_10_06_200200_create_approval_request_views_table.php database/migrations/2026_10_06_200300_add_client_session_id_to_approval_decisions.php database/migrations/2026_10_06_200400_add_approvers_gin_index_to_approval_requests.php database/migrations/2026_10_06_200500_allow_portal_codes_in_client_verification_codes.php app/Models/ClientSession.php app/Models/ApprovalRequestView.php app/Models/ClientLaneLink.php app/Models/ApprovalDecision.php tests/Support/ClientLaneFixtures.php tests/Feature/ClientPortal/ActiveLaneTest.php && vendor/bin/pint --test database/migrations/2026_10_06_200000_create_client_sessions_table.php database/migrations/2026_10_06_200100_add_access_level_to_workspace_external_invites.php database/migrations/2026_10_06_200200_create_approval_request_views_table.php database/migrations/2026_10_06_200300_add_client_session_id_to_approval_decisions.php database/migrations/2026_10_06_200400_add_approvers_gin_index_to_approval_requests.php database/migrations/2026_10_06_200500_allow_portal_codes_in_client_verification_codes.php app/Models/ClientSession.php app/Models/ApprovalRequestView.php app/Models/ClientLaneLink.php app/Models/ApprovalDecision.php tests/Support/ClientLaneFixtures.php tests/Feature/ClientPortal/ActiveLaneTest.php
/usr/bin/git add database/migrations/2026_10_06_200000_create_client_sessions_table.php database/migrations/2026_10_06_200100_add_access_level_to_workspace_external_invites.php database/migrations/2026_10_06_200200_create_approval_request_views_table.php database/migrations/2026_10_06_200300_add_client_session_id_to_approval_decisions.php database/migrations/2026_10_06_200400_add_approvers_gin_index_to_approval_requests.php database/migrations/2026_10_06_200500_allow_portal_codes_in_client_verification_codes.php app/Models/ClientSession.php app/Models/ApprovalRequestView.php app/Models/ClientLaneLink.php app/Models/ApprovalDecision.php tests/Support/ClientLaneFixtures.php tests/Feature/ClientPortal/ActiveLaneTest.php
/usr/bin/git commit -m "feat(api): client sessions, lane access level, request views and portal codes schema"
```

---

### Task 2: The active-lane rule and role-removal revocation (bug 1); rotation keeps the access level

**Files:**
- Modify: `app/Models/ClientLaneLink.php` (`scopeHonoured`)
- Modify: `app/Services/ClientLane/ClientLaneService.php` (`activeLanesFor`, `activeLane`, `revokeBrandLanes`, `touch` public, `resolveHeader`/`activePersonalLane`/`verifyMagicLink` honour the role, `rotate` keeps the level)
- Modify: `app/Models/UserBrandRole.php` (revoke events)
- Modify: `app/Http/Controllers/Api/Workspace/BrandMemberController.php` (`destroy`, `update` per model)
- Modify: `app/Http/Controllers/Api/Workspace/BrandRoleController.php` (`unassign` per model)
- Modify: `tests/Support/ClientLaneFixtures.php` (`makeOwner`)
- Test: `tests/Feature/ClientPortal/ActiveLaneTest.php`

**Interfaces:**
- Consumes: Task 1 (`access_level`, fixtures).
- Produces:
  - `ClientLaneLink::scopeHonoured(Builder $query): Builder` — the one active-lane rule (PR1).
  - `ClientLaneService::activeLanesFor(User $user): \Illuminate\Database\Eloquent\Collection<int, ClientLaneLink>` (personal, honoured, brand not soft-deleted, `brand` eager-loaded without global scopes, ordered by id).
  - `ClientLaneService::activeLane(User $user, string $brandId): ?ClientLaneLink`.
  - `ClientLaneService::revokeBrandLanes(string $brandId, string $userId): int`.
  - `ClientLaneService::touch(ClientLaneLink $lane): void` (now public).
  - `ClientLaneFixtures::makeOwner(User $user, Workspace $workspace): void`.

- [ ] **Step 1: Write the failing tests** (append to `tests/Feature/ClientPortal/ActiveLaneTest.php`; add the imports to the top of the file)

```php
use App\Http\Middleware\CheckPermissions;
use App\Models\BrandRole;
use App\Models\ClientLaneLink;
use App\Models\User;
use App\Models\UserBrandRole;
use App\Services\ClientLane\ClientLaneService;
use Illuminate\Support\Str;
```

```php
test('a personal lane is honoured only while its holder keeps the client role (bug 1)', function () {
    $f = ClientLaneFixtures::sendRequest('deck');
    $lane = ClientLaneFixtures::personalLane($f['brand']);
    $page = "/api/public/share-links/{$f['link']->token}";
    $lanes = app(ClientLaneService::class);

    $this->getJson($page, ['X-Lane-Code' => $lane->unique_code])->assertOk()->assertJsonPath('data.viewer.kind', 'client');
    expect($lanes->activeLane($lane->user, (string) $f['brand']->id)?->id)->toBe($lane->id);

    // Removed behind the model's back (a mass delete fires no event): the
    // lane row stays unrevoked, yet nothing honours it any more.
    DB::table('user_brand_roles')->where('user_id', $lane->user_id)->where('brand_id', $f['brand']->id)->delete();

    $this->getJson($page, ['X-Lane-Code' => $lane->unique_code])->assertOk()->assertJsonPath('data.viewer.kind', 'anonymous');
    expect($lane->fresh()->revoked_at)->toBeNull()
        ->and($lanes->activeLane($lane->user, (string) $f['brand']->id))->toBeNull()
        ->and($lanes->activeLanesFor($lane->user))->toHaveCount(0)
        ->and($lanes->activePersonalLane((string) $f['brand']->id, 'dina@brand.test'))->toBeNull();

    // A verified-guest lane never had a role and stays honoured (PR1).
    $guest = ClientLaneFixtures::verifiedGuestLane($f['brand']);
    $this->getJson($page, ['X-Lane-Code' => $guest->unique_code])->assertOk()->assertJsonPath('data.viewer.kind', 'verified');
});

test('an expired, revoked or deleted-brand lane is never active', function () {
    $f = ClientLaneFixtures::deck();
    $lane = ClientLaneFixtures::personalLane($f['brand']);
    $user = $lane->user;
    $lanes = app(ClientLaneService::class);
    $brandId = (string) $f['brand']->id;

    $lane->forceFill(['expires_at' => now()->subMinute()])->save();
    expect($lanes->activeLane($user, $brandId))->toBeNull();

    $lane->forceFill(['expires_at' => null, 'revoked_at' => now()])->save();
    expect($lanes->activeLane($user, $brandId))->toBeNull();

    $lane->forceFill(['revoked_at' => null])->save();
    expect($lanes->activeLane($user, $brandId)?->id)->toBe($lane->id)
        ->and($lanes->activeLanesFor($user)->first()?->brand?->id)->toBe($f['brand']->id);

    // Soft-delete the brand without its observers (a direct write, as a brand deletion leaves it).
    DB::table('brands')->where('id', $f['brand']->id)->update(['deleted_at' => now()]);
    expect($lanes->activeLanesFor($user))->toHaveCount(0);
});

test('removing the client role revokes the lane: the old members DELETE, a model delete, a move to another role', function () {
    $f = ClientLaneFixtures::deck();
    ClientLaneFixtures::makeOwner($f['user'], $f['workspace']);
    $dina = ClientLaneFixtures::personalLane($f['brand']);
    $andi = ClientLaneFixtures::personalLane($f['brand'], User::factory()->create(['email' => 'andi@brand.test']));
    $bayu = ClientLaneFixtures::personalLane($f['brand'], User::factory()->create(['email' => 'bayu@brand.test']));
    $internal = BrandRole::withoutGlobalScopes()->create([
        'workspace_id' => $f['workspace']->id,
        'name' => 'Viewer',
        'slug' => 'viewer-'.Str::lower(Str::random(4)),
        'is_locked' => false,
        'is_default' => false,
        'scope' => BrandRole::SCOPE_INTERNAL,
    ]);
    ClientLaneFixtures::actAsAgency($this, $f['user']);
    $this->withoutMiddleware([CheckPermissions::class]);

    // The OLD route (spec §4.2: "covers the old DELETE … members/{user}").
    $this->deleteJson("/api/v1/brands/{$f['brand']->id}/members/{$dina->user_id}")->assertOk();
    expect($dina->fresh()->revoked_at)->not->toBeNull()
        ->and(UserBrandRole::query()->where('user_id', $dina->user_id)->exists())->toBeFalse();

    // A model delete — the Clients endpoint's path (Task 8).
    UserBrandRole::query()->where('user_id', $andi->user_id)->sole()->delete();
    expect($andi->fresh()->revoked_at)->not->toBeNull();

    // Moved onto an internal role through the old PUT.
    $this->putJson("/api/v1/brands/{$f['brand']->id}/members/{$bayu->user_id}", ['brand_role_id' => $internal->id])->assertOk();
    expect($bayu->fresh()->revoked_at)->not->toBeNull();
});

test('rotating a personal link keeps its access level', function () {
    $f = ClientLaneFixtures::deck();
    $lane = ClientLaneFixtures::personalLane($f['brand']);
    $lane->forceFill(['access_level' => ClientLaneLink::ACCESS_ALL_APPROVE])->save();

    $fresh = app(ClientLaneService::class)->rotate($f['brand'], $lane->user);

    expect($fresh->id)->not->toBe($lane->id)
        ->and($fresh->fresh()->access_level)->toBe('all_approve')
        ->and($lane->fresh()->revoked_at)->not->toBeNull();
});
```

Add the fixture helper to `tests/Support/ClientLaneFixtures.php` (import `use App\Models\Role;`):

```php
    /** Make `$user` an owner of `$workspace` — what BrandMemberController::authorizeBrandManage accepts. */
    public static function makeOwner(User $user, Workspace $workspace): void
    {
        $owner = Role::query()->where('slug', 'owner')->first()
            ?? Role::factory()->create(['slug' => 'owner', 'name' => 'Owner', 'type' => 'workspace', 'scope' => 'internal']);

        $user->roles()->attach($owner->id, ['workspace_id' => $workspace->id]);
    }
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/ClientPortal/ActiveLaneTest.php --compact
```

Expected: FAIL — test 2 with `Call to undefined method …activeLane()`; the first test's second GET still reads `client` (bug 1); test 3's `revoked_at` is null; test 4's level is `own`.

- [ ] **Step 3: The scope** — add to `app/Models/ClientLaneLink.php` after `scopeActive()` (import nothing new; `BrandRole` is in the same namespace):

```php
    /**
     * The one ACTIVE-LANE rule (client portal spec §4.2, ruling PR1):
     * unrevoked, unexpired, and — for a personal lane — its holder still
     * has the brand's locked `client` role. Removing the role anywhere,
     * even by a mass query that fires no event, stops the lane here.
     * A verified-guest lane has no user and no role.
     */
    public function scopeHonoured(Builder $query): Builder
    {
        return $query->active()->where(function (Builder $q) {
            $q->where('kind', self::KIND_VERIFIED_GUEST)
                ->orWhereExists(function ($sub) {
                    $sub->selectRaw('1')
                        ->from('user_brand_roles')
                        ->join('brand_roles', 'brand_roles.id', '=', 'user_brand_roles.brand_role_id')
                        ->whereColumn('user_brand_roles.user_id', 'workspace_external_invites.user_id')
                        ->whereColumn('user_brand_roles.brand_id', 'workspace_external_invites.brand_id')
                        ->where('brand_roles.slug', BrandRole::CLIENT_SLUG)
                        ->where('brand_roles.scope', BrandRole::SCOPE_EXTERNAL);
                });
        });
    }
```

- [ ] **Step 4: `ClientLaneService`** (`app/Services/ClientLane/ClientLaneService.php`)

Add imports `use Illuminate\Database\Eloquent\Builder;` and `use Illuminate\Database\Eloquent\Collection;`.

In `resolveHeader()` replace

```php
        $lane = ClientLaneLink::query()
            ->where('unique_code', $code)
            ->active()
            ->first();
```

with

```php
        $lane = ClientLaneLink::query()
            ->where('unique_code', $code)
            ->honoured()
            ->first();
```

In `activePersonalLane()` replace `->active()` with `->honoured()`. In `verifyMagicLink()` replace

```php
                $personal = $locked->lane_link_id !== null
                    ? ClientLaneLink::query()->whereKey($locked->lane_link_id)->active()->first()
                    : null;
```

with

```php
                $personal = $locked->lane_link_id !== null
                    ? ClientLaneLink::query()->whereKey($locked->lane_link_id)->honoured()->first()
                    : null;
```

(`mintLaneLink()` keeps `->active()`: the partial unique index is on unrevoked personal lanes, so it must find one whatever the role.)

Replace `rotate()` with:

```php
    public function rotate(Brand $brand, User $user, ?User $actor = null): ClientLaneLink
    {
        return DB::transaction(function () use ($brand, $user, $actor): ClientLaneLink {
            $previous = ClientLaneLink::query()
                ->where('brand_id', $brand->id)
                ->where('user_id', $user->id)
                ->where('kind', ClientLaneLink::KIND_PERSONAL)
                ->whereNull('revoked_at')
                ->orderByDesc('id')
                ->first();

            ClientLaneLink::query()
                ->where('brand_id', $brand->id)
                ->where('user_id', $user->id)
                ->where('kind', ClientLaneLink::KIND_PERSONAL)
                ->whereNull('revoked_at')
                ->update(['revoked_at' => now()]);

            $lane = $this->mintLaneLink($brand, $user, $actor);

            // A new code, not new permissions (ruling PR18): the access level
            // the agency set survives "Regenerate link".
            if ($previous !== null && $previous->access_level !== $lane->access_level) {
                $lane->forceFill(['access_level' => $previous->access_level])->save();
            }

            return $lane;
        });
    }
```

Make `touch()` public: change `private function touch(ClientLaneLink $lane): void` to `public function touch(ClientLaneLink $lane): void`.

Add after `activePersonalLane()`:

```php
    /**
     * Every active lane of a client (spec §4.2): personal, honoured, on a
     * brand that is not soft-deleted. What a client session may open.
     *
     * @return Collection<int, ClientLaneLink>
     */
    public function activeLanesFor(User $user): Collection
    {
        return $this->activeLanesQuery($user)->orderBy('id')->get();
    }

    /** The client's active lane on one brand, or null (spec §4.2). */
    public function activeLane(User $user, string $brandId): ?ClientLaneLink
    {
        return $this->activeLanesQuery($user)->where('brand_id', $brandId)->first();
    }

    /**
     * A removed client role revokes the brand's lane (spec §4.2) — called
     * from UserBrandRole's model events.
     */
    public function revokeBrandLanes(string $brandId, string $userId): int
    {
        return ClientLaneLink::query()
            ->where('brand_id', $brandId)
            ->where('user_id', $userId)
            ->where('kind', ClientLaneLink::KIND_PERSONAL)
            ->whereNull('revoked_at')
            ->update(['revoked_at' => now()]);
    }

    /** @return Builder<ClientLaneLink> */
    private function activeLanesQuery(User $user): Builder
    {
        return ClientLaneLink::query()
            ->where('user_id', $user->id)
            ->where('kind', ClientLaneLink::KIND_PERSONAL)
            ->honoured()
            ->whereIn('brand_id', Brand::query()->withoutGlobalScopes()->whereNull('deleted_at')->select('id'))
            ->with(['brand' => fn ($q) => $q->withoutGlobalScopes()]);
    }
```

- [ ] **Step 5: Revoke on role removal** — `app/Models/UserBrandRole.php` becomes:

```php
<?php

namespace App\Models;

use App\Services\ClientLane\ClientLaneService;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class UserBrandRole extends Model
{
    protected $fillable = [
        'user_id',
        'brand_id',
        'brand_role_id',
        'workspace_id',
    ];

    /**
     * Client portal spec §4.2: removing a client role anywhere revokes that
     * brand's lane. Model events only fire for per-model writes — every
     * removal path that can hit a client goes through one (PR2); the
     * read-time role check in ClientLaneLink::scopeHonoured() covers the rest.
     */
    protected static function booted(): void
    {
        static::deleted(function (self $row): void {
            app(ClientLaneService::class)->revokeBrandLanes((string) $row->brand_id, (string) $row->user_id);
        });

        static::updated(function (self $row): void {
            if (! $row->wasChanged('brand_role_id')) {
                return;
            }
            $stillClient = BrandRole::withoutGlobalScopes()
                ->whereKey($row->brand_role_id)
                ->where('slug', BrandRole::CLIENT_SLUG)
                ->exists();
            if (! $stillClient) {
                app(ClientLaneService::class)->revokeBrandLanes((string) $row->brand_id, (string) $row->user_id);
            }
        });
    }

    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    public function brand(): BelongsTo
    {
        return $this->belongsTo(Brand::class);
    }

    public function brandRole(): BelongsTo
    {
        return $this->belongsTo(BrandRole::class);
    }
}
```

- [ ] **Step 6: Per-model writes on the old routes**

`app/Http/Controllers/Api/Workspace/BrandMemberController.php` — in `update()` replace

```php
        UserBrandRole::where('brand_id', $brand->id)->where('user_id', $user)->update([
            'brand_role_id' => $validated['brand_role_id'],
        ]);
```

with

```php
        // Per model, not a mass update: UserBrandRole::updated revokes a
        // client's lane when they leave the client role (client portal §4.2).
        UserBrandRole::where('brand_id', $brand->id)->where('user_id', $user)->get()
            ->each(fn (UserBrandRole $row) => $row->update(['brand_role_id' => $validated['brand_role_id']]));
```

and in `destroy()` replace

```php
        UserBrandRole::where('brand_id', $brand->id)->where('user_id', $user)->delete();
```

with

```php
        // Per model, not a mass delete: UserBrandRole::deleted revokes a
        // client's lane (client portal §4.2).
        UserBrandRole::where('brand_id', $brand->id)->where('user_id', $user)->get()->each->delete();
```

`app/Http/Controllers/Api/Workspace/BrandRoleController.php` — in `unassign()` replace

```php
        UserBrandRole::where('user_id', $user->id)
            ->where('brand_id', $brand)
            ->where('workspace_id', $workspaceId)
            ->delete();
```

with

```php
        // Per model: UserBrandRole::deleted revokes a client's lane (client portal §4.2).
        UserBrandRole::where('user_id', $user->id)
            ->where('brand_id', $brand)
            ->where('workspace_id', $workspaceId)
            ->get()
            ->each->delete();
```

- [ ] **Step 7: Run the tests to verify they pass, plus the regression files**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/ClientPortal/ActiveLaneTest.php tests/Feature/Approval/DeckPlanRequestFlowTest.php tests/Feature/Approval/KvRequestCharacterizationTest.php --compact
```

Expected: ActiveLaneTest 5 passed; the two regression files exactly as in the Task 0 baseline.

- [ ] **Step 8: Mutation check**
  - In `resolveHeader()` put `->active()` back → "a personal lane is honoured only while…" fails (second GET reads `client`).
  - Delete the `->whereIn('brand_id', …deleted_at…)` line → "an expired, revoked or deleted-brand lane…" fails at the last expectation.
  - Revert `BrandMemberController::destroy` to the mass `->delete()` → "removing the client role revokes…" fails at the first `revoked_at`.
  - Remove the `if ($previous …)` block in `rotate()` → "rotating a personal link keeps its access level" fails (`own`).
  Restore each; re-run green.

- [ ] **Step 9: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && for f in app/Models/ClientLaneLink.php app/Models/UserBrandRole.php app/Services/ClientLane/ClientLaneService.php app/Http/Controllers/Api/Workspace/BrandMemberController.php app/Http/Controllers/Api/Workspace/BrandRoleController.php tests/Support/ClientLaneFixtures.php tests/Feature/ClientPortal/ActiveLaneTest.php; do php -l "$f" || exit 1; done && vendor/bin/pint app/Models/ClientLaneLink.php app/Models/UserBrandRole.php app/Services/ClientLane/ClientLaneService.php app/Http/Controllers/Api/Workspace/BrandMemberController.php app/Http/Controllers/Api/Workspace/BrandRoleController.php tests/Support/ClientLaneFixtures.php tests/Feature/ClientPortal/ActiveLaneTest.php && vendor/bin/pint --test app/Models/ClientLaneLink.php app/Models/UserBrandRole.php app/Services/ClientLane/ClientLaneService.php app/Http/Controllers/Api/Workspace/BrandMemberController.php app/Http/Controllers/Api/Workspace/BrandRoleController.php tests/Support/ClientLaneFixtures.php tests/Feature/ClientPortal/ActiveLaneTest.php
/usr/bin/git add app/Models/ClientLaneLink.php app/Models/UserBrandRole.php app/Services/ClientLane/ClientLaneService.php app/Http/Controllers/Api/Workspace/BrandMemberController.php app/Http/Controllers/Api/Workspace/BrandRoleController.php tests/Support/ClientLaneFixtures.php tests/Feature/ClientPortal/ActiveLaneTest.php
/usr/bin/git commit -m "fix(api): a removed client role revokes the lane and is never honoured again"
```

---
### Task 3: Client sessions — service, principal, `client.session` middleware, sign-out

**Files:**
- Create: `app/Services/ClientLane/ClientSessionService.php`
- Create: `app/Services/ClientLane/ClientPrincipal.php`
- Create: `app/Http/Middleware/AuthenticateClientSession.php`
- Create: `app/Http/Controllers/Api/ClientPortal/PortalController.php` (sign-out only; Task 6 completes it)
- Modify: `bootstrap/app.php` (alias `client.session`)
- Modify: `app/Providers/AppServiceProvider.php` (limiter `public-portal`)
- Modify: `routes/api.php` (`DELETE public/portal/session`)
- Modify: `tests/Support/ClientLaneFixtures.php` (`UA_*` constants, `session()`)
- Test: `tests/Feature/ClientPortal/ClientSessionTest.php` (created here)

**Interfaces:**
- Consumes: Task 1 `ClientSession`; Task 2 `ClientLaneService::activeLanesFor()`.
- Produces:
  - `ClientSessionService::HEADER = 'X-Client-Session'`, `IDLE_DAYS = 30`, `MAX_DAYS = 90`, `ATTRIBUTE = 'client_principal'`.
  - `ClientSessionService::issue(User $user, string $via, Request $request): array{0: ClientSession, 1: string}` — the row and the raw 43-char token.
  - `ClientSessionService::principal(Request $request): ?ClientPrincipal` — memoised on the request; slides the expiry (PR5).
  - `ClientSessionService::revoke(ClientSession $session): void`.
  - `static ClientSessionService::deviceLabel(?string $userAgent): string` — `"{Browser} · {OS}"`.
  - `ClientPrincipal` (`public readonly User $user`, `ClientSession $session`, `array<string, ClientLaneLink> $lanes`), `laneFor(string $brandId): ?ClientLaneLink`, `static of(Request $request): ClientPrincipal`.
  - Middleware alias `client.session`; route `DELETE public/portal/session` (name `public.portal.session.destroy`).
  - `ClientLaneFixtures::UA_CHROME_MAC`, `ClientLaneFixtures::UA_SAFARI_IPHONE`, `ClientLaneFixtures::session(User $user, string $via = ClientSession::VIA_PERSONAL_LINK): array{0: ClientSession, 1: string}`.

- [ ] **Step 1: Fixture helpers** — add to `tests/Support/ClientLaneFixtures.php` (imports `use App\Models\ClientSession;`, `use App\Services\ClientLane\ClientSessionService;`, `use Illuminate\Http\Request;`), at the top of the class:

```php
    public const UA_CHROME_MAC = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36';

    public const UA_SAFARI_IPHONE = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1';
```

and below `deckOn()`:

```php
    /**
     * A device session for `$user`, issued the production way.
     *
     * @return array{0: ClientSession, 1: string} the row and its raw token
     */
    public static function session(User $user, string $via = ClientSession::VIA_PERSONAL_LINK): array
    {
        $request = Request::create('/', 'POST', server: ['HTTP_USER_AGENT' => self::UA_CHROME_MAC, 'REMOTE_ADDR' => '203.0.113.7']);

        return app(ClientSessionService::class)->issue($user, $via, $request);
    }
```

- [ ] **Step 2: Write the failing tests** — create `tests/Feature/ClientPortal/ClientSessionTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Jobs\SendApprovalRequestDigest;
use App\Services\ClientLane\ClientSessionService;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Bus;
use Illuminate\Support\Facades\Mail;
use Tests\Support\ClientLaneFixtures;

/**
 * Client portal (spec 2026-10-06 §4.3–§4.4, §5.3, §10 Q1): sessions —
 * issue, sliding expiry, the middleware, the `?k=` exchange, sign-in by
 * code, sign-out and retention.
 */
beforeEach(function () {
    Mail::fake();
    Bus::fake([SendApprovalRequestDigest::class]);
    config(['app.frontend_url' => 'https://app.frndos.test']);
});

test("a session is issued hashed, labelled from the user agent, 30 days out, carrying the client's active lanes", function () {
    $this->freezeSecond();
    $f = ClientLaneFixtures::deck();
    $dina = ClientLaneFixtures::namedClient($f['brand'], 'dina@brand.test', 'Dina Pratiwi');

    [$session, $token] = ClientLaneFixtures::session($dina['user']);

    expect($token)->toMatch('/^[A-Za-z0-9_-]{43}$/')
        ->and($session->fresh()->token_hash)->toBe(hash('sha256', $token))
        ->and($session->created_via)->toBe('personal_link')
        ->and($session->device_label)->toBe('Chrome · macOS')
        ->and($session->ip_hash)->not->toBeNull()
        ->and($session->ip_hash)->not->toBe('203.0.113.7')
        ->and($session->fresh()->expires_at->toDateTimeString())->toBe(now()->addDays(30)->toDateTimeString());
    expect(ClientSessionService::deviceLabel(ClientLaneFixtures::UA_SAFARI_IPHONE))->toBe('Safari · iOS')
        ->and(ClientSessionService::deviceLabel(null))->toBe('Browser · Unknown OS');

    $principal = app(ClientSessionService::class)->principal(Request::create('/', 'GET', server: ['HTTP_X_CLIENT_SESSION' => $token]));
    expect($principal?->user->id)->toBe($dina['user']->id)
        ->and($principal->session->id)->toBe($session->id)
        ->and($principal->laneFor((string) $f['brand']->id)?->id)->toBe($dina['lane']->id)
        ->and($principal->laneFor('01jzzzzzzzzzzzzzzzzzzzzzzz'))->toBeNull();
});

test('use slides the expiry 30 days ahead, never past 90 days from creation', function () {
    $this->freezeSecond();
    $t0 = now();
    $f = ClientLaneFixtures::deck();
    $user = ClientLaneFixtures::personalLane($f['brand'])->user;
    [$session, $token] = ClientLaneFixtures::session($user);
    $use = fn () => app(ClientSessionService::class)->principal(Request::create('/', 'GET', server: ['HTTP_X_CLIENT_SESSION' => $token]));

    foreach ([20 => 50, 45 => 75, 70 => 90, 89 => 90] as $day => $expected) {
        $this->travelTo($t0->copy()->addDays($day));
        expect($use())->not->toBeNull()
            ->and($session->fresh()->expires_at->toDateTimeString())->toBe($t0->copy()->addDays($expected)->toDateTimeString());
    }

    $this->travelTo($t0->copy()->addDays(91));
    expect($use())->toBeNull();
});

test('an idle session dies after 30 days, a revoked one at once, and garbage is nobody', function () {
    $this->freezeSecond();
    $f = ClientLaneFixtures::deck();
    $user = ClientLaneFixtures::personalLane($f['brand'])->user;
    $sessions = app(ClientSessionService::class);
    $principal = fn (string $token) => $sessions->principal(Request::create('/', 'GET', server: ['HTTP_X_CLIENT_SESSION' => $token]));

    [, $idle] = ClientLaneFixtures::session($user);
    $this->travel(31)->days();
    expect($principal($idle))->toBeNull();

    [$revoked, $revokedToken] = ClientLaneFixtures::session($user);
    $sessions->revoke($revoked);
    expect($principal($revokedToken))->toBeNull()
        ->and($principal('not-a-token'))->toBeNull()
        ->and($principal(str_repeat('A', 43)))->toBeNull();
});

test('client.session answers 401 session_required for no, garbage, revoked or expired tokens; sign-out revokes this device only', function () {
    $f = ClientLaneFixtures::deck();
    $user = ClientLaneFixtures::personalLane($f['brand'])->user;
    [$here, $token] = ClientLaneFixtures::session($user);
    [$there, $otherToken] = ClientLaneFixtures::session($user);
    $body = ['code' => 'session_required', 'message' => 'Sign in to continue.'];

    $none = $this->deleteJson('/api/public/portal/session')->assertStatus(401)->assertExactJson($body);
    expect($none->headers->get('Cache-Control'))->toContain('no-store');
    $this->deleteJson('/api/public/portal/session', [], ['X-Client-Session' => str_repeat('A', 43)])->assertStatus(401)->assertExactJson($body);

    $out = $this->deleteJson('/api/public/portal/session', [], ['X-Client-Session' => $token])->assertNoContent();
    expect($out->headers->get('Cache-Control'))->toContain('no-store')
        ->and($here->fresh()->revoked_at)->not->toBeNull()
        ->and($there->fresh()->revoked_at)->toBeNull();
    $this->deleteJson('/api/public/portal/session', [], ['X-Client-Session' => $token])->assertStatus(401)->assertExactJson($body);

    $there->forceFill(['expires_at' => now()->subSecond()])->save();
    $this->deleteJson('/api/public/portal/session', [], ['X-Client-Session' => $otherToken])->assertStatus(401)->assertExactJson($body);
});
```

- [ ] **Step 3: Run them to verify they fail**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/ClientPortal/ClientSessionTest.php --compact
```

Expected: FAIL — `Target class [App\Services\ClientLane\ClientSessionService] does not exist` (and the route test 404s).

- [ ] **Step 4: `app/Services/ClientLane/ClientPrincipal.php`**

```php
<?php

declare(strict_types=1);

namespace App\Services\ClientLane;

use App\Models\ClientLaneLink;
use App\Models\ClientSession;
use App\Models\User;
use Illuminate\Http\Request;
use LogicException;

/**
 * Who a `client.session` request is (client portal spec §4.4): the person,
 * this device's session, and their active lanes keyed by brand id —
 * recomputed on every request, so a revoked lane or a removed role drops
 * the brand on the very next call (spec §8.1).
 */
final class ClientPrincipal
{
    /** @param  array<string, ClientLaneLink>  $lanes */
    public function __construct(
        public readonly User $user,
        public readonly ClientSession $session,
        public readonly array $lanes,
    ) {}

    public function laneFor(string $brandId): ?ClientLaneLink
    {
        return $this->lanes[$brandId] ?? null;
    }

    /** The principal the `client.session` middleware bound. */
    public static function of(Request $request): self
    {
        $principal = $request->attributes->get(ClientSessionService::ATTRIBUTE);
        if (! $principal instanceof self) {
            throw new LogicException('The client.session middleware did not run for this route.');
        }

        return $principal;
    }
}
```

- [ ] **Step 5: `app/Services/ClientLane/ClientSessionService.php`**

```php
<?php

declare(strict_types=1);

namespace App\Services\ClientLane;

// craftsman-ignore: PHP002 — resolved from the container and swapped in tests.

use App\Models\ClientLaneLink;
use App\Models\ClientSession;
use App\Models\User;
use Illuminate\Http\Request;

/**
 * Client device sessions (client portal spec 2026-10-06 §4.3–§4.4, P-3).
 *
 * SECURITY: the token is 32 random bytes, handed out exactly once by
 * `issue()` and stored only as its sha256. It travels as `X-Client-Session`
 * from the web BFF, which keeps it in an HttpOnly cookie — never in page
 * JavaScript. A session proves the person; what they may open is their
 * ACTIVE lanes, recomputed on every request.
 */
class ClientSessionService
{
    public const HEADER = 'X-Client-Session';

    /** Days of inactivity a session survives (sliding). */
    public const IDLE_DAYS = 30;

    /** Hard cap from creation, however active. */
    public const MAX_DAYS = 90;

    /** Request attribute the principal is memoised under. */
    public const ATTRIBUTE = 'client_principal';

    private const TOKEN_BYTES = 32;

    private const TOKEN_PATTERN = '/^[A-Za-z0-9_-]{43}$/';

    /** Slide at most once a minute per session (ruling PR5). */
    private const TOUCH_EVERY_SECONDS = 60;

    public function __construct(private readonly ClientLaneService $lanes) {}

    /**
     * @param  string  $via  ClientSession::VIA_*
     * @return array{0: ClientSession, 1: string} the row and the raw token (shown once)
     */
    public function issue(User $user, string $via, Request $request): array
    {
        $token = rtrim(strtr(base64_encode(random_bytes(self::TOKEN_BYTES)), '+/', '-_'), '=');
        $ip = $request->ip();

        $session = ClientSession::create([
            'user_id' => $user->id,
            'token_hash' => ClientSession::hashToken($token),
            'created_via' => $via,
            'device_label' => self::deviceLabel($request->userAgent()),
            'ip_hash' => $ip !== null ? hash('sha256', $ip.(string) config('app.key')) : null,
            'last_seen_at' => now(),
            'expires_at' => now()->addDays(self::IDLE_DAYS),
        ]);

        return [$session, $token];
    }

    /**
     * The request's principal, or null for a missing, malformed, revoked or
     * expired token. Memoised on the request (the middleware and the share
     * page both ask); slides the expiry.
     */
    public function principal(Request $request): ?ClientPrincipal
    {
        if ($request->attributes->has(self::ATTRIBUTE)) {
            $memo = $request->attributes->get(self::ATTRIBUTE);

            return $memo instanceof ClientPrincipal ? $memo : null;
        }

        $principal = $this->resolve((string) $request->header(self::HEADER, ''));
        $request->attributes->set(self::ATTRIBUTE, $principal ?? false);

        return $principal;
    }

    /** Sign-out: this device only. */
    public function revoke(ClientSession $session): void
    {
        ClientSession::query()->whereKey($session->id)->whereNull('revoked_at')->update(['revoked_at' => now()]);
        $session->revoked_at = now();
    }

    /** "Chrome · macOS" — coarse on purpose: a label, not a fingerprint. */
    public static function deviceLabel(?string $userAgent): string
    {
        $ua = (string) $userAgent;

        $browser = match (true) {
            str_contains($ua, 'Edg/') => 'Edge',
            str_contains($ua, 'OPR/') => 'Opera',
            str_contains($ua, 'Firefox/') || str_contains($ua, 'FxiOS/') => 'Firefox',
            str_contains($ua, 'Chrome/') || str_contains($ua, 'CriOS/') => 'Chrome',
            str_contains($ua, 'Safari/') => 'Safari',
            default => 'Browser',
        };

        // iPhone/iPad before macOS (their UA says "like Mac OS X"); Android
        // before Linux (Android UAs say "Linux").
        $os = match (true) {
            str_contains($ua, 'iPhone') || str_contains($ua, 'iPad') => 'iOS',
            str_contains($ua, 'Android') => 'Android',
            str_contains($ua, 'Macintosh') || str_contains($ua, 'Mac OS X') => 'macOS',
            str_contains($ua, 'Windows') => 'Windows',
            str_contains($ua, 'Linux') => 'Linux',
            default => 'Unknown OS',
        };

        return "{$browser} · {$os}";
    }

    private function resolve(string $token): ?ClientPrincipal
    {
        if (preg_match(self::TOKEN_PATTERN, $token) !== 1) {
            return null;
        }

        $session = ClientSession::query()
            ->where('token_hash', ClientSession::hashToken($token))
            ->live()
            ->with('user')
            ->first();
        if ($session === null || $session->user === null) {
            return null;
        }

        $this->slide($session);

        $lanes = $this->lanes->activeLanesFor($session->user)
            ->keyBy(static fn (ClientLaneLink $lane): string => (string) $lane->brand_id)
            ->all();

        return new ClientPrincipal($session->user, $session, $lanes);
    }

    /** 30 days from now, never past 90 days from creation (spec §4.1). */
    private function slide(ClientSession $session): void
    {
        $now = now();
        if ($session->last_seen_at !== null && $session->last_seen_at->gt($now->copy()->subSeconds(self::TOUCH_EVERY_SECONDS))) {
            return;
        }

        $cap = $session->created_at->copy()->addDays(self::MAX_DAYS);
        $expires = $now->copy()->addDays(self::IDLE_DAYS);
        if ($expires->gt($cap)) {
            $expires = $cap;
        }

        ClientSession::query()->whereKey($session->id)->update(['last_seen_at' => $now, 'expires_at' => $expires]);
        $session->last_seen_at = $now;
        $session->expires_at = $expires;
    }
}
```

- [ ] **Step 6: `app/Http/Middleware/AuthenticateClientSession.php`**

```php
<?php

declare(strict_types=1);

namespace App\Http\Middleware;

// craftsman-ignore: PHP002 — middleware is not final in this codebase.

use App\Services\ClientLane\ClientSessionService;
use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * `client.session` (client portal spec 2026-10-06 §4.4): `X-Client-Session`
 * → a live session → a ClientPrincipal on the request (ClientPrincipal::of).
 * Missing or dead → `401 session_required`. Every response it lets through
 * or makes carries `Cache-Control: no-store`.
 */
class AuthenticateClientSession
{
    public const SESSION_REQUIRED = 'session_required';

    public function __construct(private readonly ClientSessionService $sessions) {}

    public function handle(Request $request, Closure $next): Response
    {
        if ($this->sessions->principal($request) === null) {
            return response()
                ->json(['code' => self::SESSION_REQUIRED, 'message' => 'Sign in to continue.'], 401)
                ->header('Cache-Control', 'no-store');
        }

        $response = $next($request);
        $response->headers->set('Cache-Control', 'no-store');

        return $response;
    }
}
```

- [ ] **Step 7: `app/Http/Controllers/Api/ClientPortal/PortalController.php`** (sign-out only for now)

```php
<?php

declare(strict_types=1);

namespace App\Http\Controllers\Api\ClientPortal;

// craftsman-ignore: PHP002 — controllers are not final in this codebase.

use App\Http\Controllers\Controller;
use App\Services\ClientLane\ClientPrincipal;
use App\Services\ClientLane\ClientSessionService;
use Illuminate\Http\Request;
use Illuminate\Http\Response;

/**
 * The client portal api (spec 2026-10-06 §5), behind `client.session`.
 */
class PortalController extends Controller
{
    public function __construct(private readonly ClientSessionService $sessions) {}

    /** DELETE public/portal/session — "Sign out this device" (§5.3). */
    public function signOut(Request $request): Response
    {
        $this->sessions->revoke(ClientPrincipal::of($request)->session);

        return response()->noContent();
    }
}
```

- [ ] **Step 8: Wire the alias, the limiter and the route**

`bootstrap/app.php` — add `use App\Http\Middleware\AuthenticateClientSession;` with the other middleware imports, and in `$middleware->alias([...])` after `'study.method.permission' => RequireStudyMethodPermission::class,`:

```php
            'client.session' => AuthenticateClientSession::class,
```

`app/Providers/AppServiceProvider.php` — after the `RateLimiter::for('public-lane-code-verify', …);` block:

```php
        // Client portal (spec 2026-10-06 §5): session routes, per session
        // token (hashed into the key) — the web BFF makes every portal call,
        // so a per-IP bucket would be one bucket for every client (PR15).
        RateLimiter::for('public-portal', function (Request $request) use ($tooManyAttemptsResponse) {
            $token = (string) $request->header('X-Client-Session', '');
            $key = $token !== '' ? 'pp-s|'.hash('sha256', $token) : 'pp-ip|'.$request->ip();

            return Limit::perMinute(120)->by($key)->response($tooManyAttemptsResponse);
        });
```

`routes/api.php` — add `use App\Http\Controllers\Api\ClientPortal\PortalController;` beside `use App\Http\Controllers\Api\PublicLaneController;`, and after the `public/lane/code/verify` route (`->name('public.lane.code.verify');`):

```php

// =====================================================================
// Client portal (spec 2026-10-06 §4–§5): one device session per client,
// sent as `X-Client-Session` by the web BFF from its `frnd_client` cookie.
// Every "no" is the 401 session_required, the dead-link 404 or the one 202.
// =====================================================================
Route::middleware(['throttle:public-portal', 'client.session'])->group(function () {
    Route::delete('public/portal/session', [PortalController::class, 'signOut'])
        ->name('public.portal.session.destroy');
});
```

- [ ] **Step 9: Run the tests to verify they pass**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/ClientPortal/ClientSessionTest.php --compact
```

Expected: PASS (4 tests).

- [ ] **Step 10: Mutation check**
  - `ClientSession::scopeLive()` without `->whereNull('revoked_at')` → "an idle session dies…" and "client.session answers 401…" fail.
  - Delete the `if ($expires->gt($cap))` block → "use slides the expiry…" fails at day 70 (100 ≠ 90).
  - Store the raw token instead of `hashToken($token)` in `issue()` → the first test fails at `token_hash`.
  - Remove the `return` of the 401 in the middleware (fall through to `$next`) → the 401 test fails (a `LogicException` 500).
  Restore; re-run green.

- [ ] **Step 11: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && for f in app/Services/ClientLane/ClientSessionService.php app/Services/ClientLane/ClientPrincipal.php app/Http/Middleware/AuthenticateClientSession.php app/Http/Controllers/Api/ClientPortal/PortalController.php bootstrap/app.php app/Providers/AppServiceProvider.php routes/api.php tests/Support/ClientLaneFixtures.php tests/Feature/ClientPortal/ClientSessionTest.php; do php -l "$f" || exit 1; done && vendor/bin/pint app/Services/ClientLane/ClientSessionService.php app/Services/ClientLane/ClientPrincipal.php app/Http/Middleware/AuthenticateClientSession.php app/Http/Controllers/Api/ClientPortal/PortalController.php tests/Support/ClientLaneFixtures.php tests/Feature/ClientPortal/ClientSessionTest.php && vendor/bin/pint --test app/Services/ClientLane/ClientSessionService.php app/Services/ClientLane/ClientPrincipal.php app/Http/Middleware/AuthenticateClientSession.php app/Http/Controllers/Api/ClientPortal/PortalController.php tests/Support/ClientLaneFixtures.php tests/Feature/ClientPortal/ClientSessionTest.php
/usr/bin/git add app/Services/ClientLane/ClientSessionService.php app/Services/ClientLane/ClientPrincipal.php app/Http/Middleware/AuthenticateClientSession.php app/Http/Controllers/Api/ClientPortal/PortalController.php bootstrap/app.php app/Providers/AppServiceProvider.php routes/api.php tests/Support/ClientLaneFixtures.php tests/Feature/ClientPortal/ClientSessionTest.php
/usr/bin/git commit -m "feat(api): client device sessions, the client.session middleware and sign-out"
```

(`bootstrap/app.php`, `AppServiceProvider.php` and `routes/api.php` are not run through pint here: they are large pre-existing files whose formatting this task must not churn. `php -l` covers them; Task 12 runs pint `--test` on them and only fixes lines this plan added.)

---

### Task 4: Session exchange — `?k=` personal link and the request-link code

**Files:**
- Create: `app/Http/Controllers/Api/ClientPortal/ClientSessionController.php`
- Modify: `app/Http/Controllers/Api/PublicLaneController.php` (`verifyCode`: `issue_session`)
- Modify: `app/Providers/AppServiceProvider.php` (limiter `public-client-session`)
- Modify: `routes/api.php` (`POST public/client/session`)
- Test: `tests/Feature/ClientPortal/ClientSessionTest.php`

**Interfaces:**
- Consumes: Task 2 `ClientLaneService::activeLane()`, `touch()`; Task 3 `ClientSessionService::issue()/principal()/revoke()`.
- Produces: `POST public/client/session` (name `public.client.session`) and the `issue_session` flag on `POST public/lane/code/verify` — shapes in the contract above.

- [ ] **Step 1: Write the failing tests** (append to `tests/Feature/ClientPortal/ClientSessionTest.php`; add imports `use App\Models\ClientSession;`, `use App\Models\ClientVerificationCode;`, `use Illuminate\Support\Facades\DB;`)

```php
test('a personal link code exchanges for a session; a dead, role-less or guest code is the one 404', function () {
    $f = ClientLaneFixtures::deck();
    $dina = ClientLaneFixtures::namedClient($f['brand'], 'dina@brand.test', 'Dina Pratiwi');

    $data = $this->postJson('/api/public/client/session', ['lane_code' => $dina['lane']->unique_code], ['User-Agent' => ClientLaneFixtures::UA_CHROME_MAC])
        ->assertOk()->json('data');
    expect($data['session_token'])->toMatch('/^[A-Za-z0-9_-]{43}$/')
        ->and($data['expires_at'])->not->toBeNull()
        ->and($data['workspace_slug'])->toBe($f['workspace']->slug)
        ->and($data['brand_slug'])->toBe($f['brand']->slug);
    $session = ClientSession::query()->sole();
    expect($session->user_id)->toBe($dina['user']->id)
        ->and($session->created_via)->toBe('personal_link')
        ->and($session->device_label)->toBe('Chrome · macOS')
        ->and($dina['lane']->fresh()->last_used_at)->not->toBeNull();

    $guest = ClientLaneFixtures::verifiedGuestLane($f['brand']);
    foreach ([$guest->unique_code, 'AAAAAAAAAAAAAAAA'] as $code) {
        $this->postJson('/api/public/client/session', ['lane_code' => $code])->assertNotFound()->assertExactJson(['message' => 'Not found.']);
    }
    DB::table('user_brand_roles')->where('user_id', $dina['user']->id)->delete();
    $this->postJson('/api/public/client/session', ['lane_code' => $dina['lane']->unique_code])->assertNotFound()->assertExactJson(['message' => 'Not found.']);
    $this->postJson('/api/public/client/session', ['lane_code' => 'short'])->assertStatus(422);

    expect(ClientSession::query()->count())->toBe(1);
});

test('the same person keeps their session; another person on the device replaces it', function () {
    $f = ClientLaneFixtures::deck();
    $dina = ClientLaneFixtures::namedClient($f['brand'], 'dina@brand.test', 'Dina Pratiwi');
    $andi = ClientLaneFixtures::namedClient($f['brand'], 'andi@brand.test', 'Andi Wijaya');
    [$dinas, $token] = ClientLaneFixtures::session($dina['user']);

    $this->postJson('/api/public/client/session', ['lane_code' => $dina['lane']->unique_code], ['X-Client-Session' => $token])
        ->assertOk()->assertJsonPath('data.session_token', null);
    expect(ClientSession::query()->count())->toBe(1)->and($dinas->fresh()->revoked_at)->toBeNull();

    $new = $this->postJson('/api/public/client/session', ['lane_code' => $andi['lane']->unique_code], ['X-Client-Session' => $token])
        ->assertOk()->json('data.session_token');
    expect($new)->toMatch('/^[A-Za-z0-9_-]{43}$/')
        ->and($dinas->fresh()->revoked_at)->not->toBeNull()
        ->and(ClientSession::query()->whereNull('revoked_at')->sole()->user_id)->toBe($andi['user']->id);
});

test('a request-link code verify issues a session only when asked, and only for a named client', function () {
    $f = ClientLaneFixtures::sendRequest('deck');
    ClientLaneFixtures::namedClient($f['brand'], 'dina@brand.test', 'Dina Pratiwi');
    $plant = fn (string $email, string $code) => ClientVerificationCode::create([
        'email' => $email,
        'brand_id' => (string) $f['brand']->id,
        'share_link_id' => (string) $f['link']->id,
        'code_hash' => ClientVerificationCode::hashCode($code),
        'attempts' => 0,
        'expires_at' => now()->addMinutes(ClientVerificationCode::TTL_MINUTES),
    ]);
    $verify = fn (string $email, string $code, array $extra = []) => $this->postJson(
        '/api/public/lane/code/verify',
        ['email' => $email, 'code' => $code, 'share_token' => $f['link']->token, ...$extra],
    );

    $plant('dina@brand.test', '111111');
    $plain = $verify('dina@brand.test', '111111')->assertOk()->json('data');
    expect($plain)->not->toHaveKey('session_token')
        ->and($plain['kind'])->toBe('personal')
        ->and(ClientSession::query()->count())->toBe(0);

    $plant('dina@brand.test', '222222');
    $named = $verify('dina@brand.test', '222222', ['issue_session' => true])->assertOk()->json('data');
    expect($named['session_token'])->toMatch('/^[A-Za-z0-9_-]{43}$/')
        ->and($named['session_expires_at'])->not->toBeNull();
    expect(ClientSession::query()->sole())->created_via->toBe('code');

    $plant('bayu@brand.test', '333333');
    $guest = $verify('bayu@brand.test', '333333', ['issue_session' => true])->assertOk()->json('data');
    expect($guest['kind'])->toBe('verified_guest')
        ->and($guest['session_token'])->toBeNull()
        ->and(ClientSession::query()->count())->toBe(1);
});
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/ClientPortal/ClientSessionTest.php --compact
```

Expected: the 4 Task 3 tests pass; the 3 new ones FAIL — `public/client/session` has no route yet (the first `assertOk` gets a 404), and the verify test fails at `session_token` (the flag is ignored).

- [ ] **Step 3: `app/Http/Controllers/Api/ClientPortal/ClientSessionController.php`**

```php
<?php

declare(strict_types=1);

namespace App\Http\Controllers\Api\ClientPortal;

// craftsman-ignore: PHP002 — controllers are not final in this codebase.

use App\Http\Controllers\Controller;
use App\Models\ClientLaneLink;
use App\Models\ClientSession;
use App\Models\Workspace;
use App\Services\ClientLane\ClientLaneService;
use App\Services\ClientLane\ClientSessionService;
use Carbon\CarbonInterface;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;

/**
 * `POST public/client/session` (client portal spec 2026-10-06 §4.3 (1)):
 * the web's `/s/session` route trades a personal link's `?k=` code for a
 * device session. Called only by that server route — the token in the
 * body never reaches page JavaScript.
 */
class ClientSessionController extends Controller
{
    private const NOT_FOUND = ['message' => 'Not found.'];

    public function __construct(
        private readonly ClientLaneService $lanes,
        private readonly ClientSessionService $sessions,
    ) {}

    public function store(Request $request): JsonResponse
    {
        $validated = $request->validate([
            'lane_code' => ['required', 'string', 'regex:'.ClientLaneService::CODE_PATTERN],
        ]);

        $lane = ClientLaneLink::query()
            ->where('unique_code', $validated['lane_code'])
            ->where('kind', ClientLaneLink::KIND_PERSONAL)
            ->whereNotNull('user_id')
            ->first();
        $user = $lane?->user;
        // The one active-lane rule (§4.2): unrevoked, unexpired, role held,
        // brand alive. Everything else is the dead-link 404.
        $active = $user !== null ? $this->lanes->activeLane($user, (string) $lane->brand_id) : null;
        if ($active === null || $active->id !== $lane->id) {
            return response()->json(self::NOT_FOUND, 404)->header('Cache-Control', 'no-store');
        }

        $this->lanes->touch($active);
        $where = [
            'workspace_slug' => (string) Workspace::query()->whereKey($active->brand?->workspace_id)->value('slug'),
            'brand_slug' => (string) ($active->brand?->slug ?? ''),
        ];

        // Ruling PR4: the same person keeps this device's session; another
        // person's session is ended — one cookie holds one person.
        $current = $this->sessions->principal($request);
        if ($current !== null && (string) $current->user->id === (string) $user->id) {
            return $this->ok(null, $current->session->expires_at, $where);
        }
        if ($current !== null) {
            $this->sessions->revoke($current->session);
        }

        [$session, $token] = $this->sessions->issue($user, ClientSession::VIA_PERSONAL_LINK, $request);

        return $this->ok($token, $session->expires_at, $where);
    }

    /** @param  array{workspace_slug: string, brand_slug: string}  $where */
    private function ok(?string $token, ?CarbonInterface $expiresAt, array $where): JsonResponse
    {
        return response()
            ->json(['data' => ['session_token' => $token, 'expires_at' => $expiresAt?->toISOString(), ...$where]])
            ->header('Cache-Control', 'no-store');
    }
}
```

- [ ] **Step 4: `issue_session` on the request-link code verify** — `app/Http/Controllers/Api/PublicLaneController.php`

Add imports `use App\Models\ClientSession;` and `use App\Services\ClientLane\ClientSessionService;`. Constructor becomes:

```php
    public function __construct(
        private readonly ClientLaneService $lanes,
        private readonly ClientVerificationCodeService $codes,
        private readonly ClientSessionService $sessions,
    ) {}
```

In `verifyCode()` add to the validation array after `'share_token' => ['required', 'string', 'max:64'],`:

```php
            'issue_session' => ['sometimes', 'boolean'],
```

and replace the final return

```php
        return response()
            ->json(['data' => [
                'lane_code' => $lane->unique_code,
                'kind' => $lane->kind,
                'expires_at' => $lane->expires_at?->toISOString(),
            ]])
            ->header('Cache-Control', 'no-store');
```

with

```php
        $data = [
            'lane_code' => $lane->unique_code,
            'kind' => $lane->kind,
            'expires_at' => $lane->expires_at?->toISOString(),
        ];

        // Client portal §4.3 (2), ruling PR3: a session only when the web's
        // server route asks (page JS never sees a token) and only for a
        // named client — a verified guest has no person to sign in.
        if ($request->boolean('issue_session')) {
            $user = $lane->isPersonal() ? $lane->user : null;
            $issued = $user !== null ? $this->sessions->issue($user, ClientSession::VIA_CODE, $request) : null;
            $data['session_token'] = $issued[1] ?? null;
            $data['session_expires_at'] = $issued !== null ? $issued[0]->expires_at?->toISOString() : null;
        }

        return response()->json(['data' => $data])->header('Cache-Control', 'no-store');
```

- [ ] **Step 5: Limiter and route**

`app/Providers/AppServiceProvider.php`, after the `public-portal` limiter:

```php
        // `?k=` → session exchange: 20/min per IP. A lane code is a 96-bit
        // credential; this only keeps guessing expensive.
        RateLimiter::for('public-client-session', function (Request $request) use ($tooManyAttemptsResponse) {
            return Limit::perMinute(20)->by('pcs|'.$request->ip())->response($tooManyAttemptsResponse);
        });
```

`routes/api.php` — add `use App\Http\Controllers\Api\ClientPortal\ClientSessionController;` with the other imports, and directly above the `Route::middleware(['throttle:public-portal', 'client.session'])` group:

```php
Route::post('public/client/session', [ClientSessionController::class, 'store'])
    ->middleware('throttle:public-client-session')
    ->name('public.client.session');
```

- [ ] **Step 6: Run the tests to verify they pass, plus the existing code-verify path**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/ClientPortal/ClientSessionTest.php tests/Feature/Approval/DeckPlanRequestFlowTest.php --compact
```

Expected: ClientSessionTest 7 passed; DeckPlanRequestFlowTest as in the baseline.

- [ ] **Step 7: Mutation check**
  - Replace the `activeLane` check with `$active = $lane` (skip the rule) → "a personal link code exchanges…" fails at the role-less 404.
  - Remove the same-person early return → "the same person keeps their session…" fails (`session_token` not null, 2 rows).
  - Remove `if ($current !== null) { revoke }` → the same test fails at `revoked_at`.
  - Issue whenever the lane is personal, ignoring `$request->boolean('issue_session')` → "a request-link code verify…" fails at `not->toHaveKey('session_token')`.
  Restore; re-run green.

- [ ] **Step 8: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && for f in app/Http/Controllers/Api/ClientPortal/ClientSessionController.php app/Http/Controllers/Api/PublicLaneController.php app/Providers/AppServiceProvider.php routes/api.php tests/Feature/ClientPortal/ClientSessionTest.php; do php -l "$f" || exit 1; done && vendor/bin/pint app/Http/Controllers/Api/ClientPortal/ClientSessionController.php app/Http/Controllers/Api/PublicLaneController.php tests/Feature/ClientPortal/ClientSessionTest.php && vendor/bin/pint --test app/Http/Controllers/Api/ClientPortal/ClientSessionController.php app/Http/Controllers/Api/PublicLaneController.php tests/Feature/ClientPortal/ClientSessionTest.php
/usr/bin/git add app/Http/Controllers/Api/ClientPortal/ClientSessionController.php app/Http/Controllers/Api/PublicLaneController.php app/Providers/AppServiceProvider.php routes/api.php tests/Feature/ClientPortal/ClientSessionTest.php
/usr/bin/git commit -m "feat(api): exchange a personal link or a request-link code for a client session"
```

---
### Task 5: The request page with a session — viewer, `view_only`, "opened", decision audit

**Files:**
- Modify: `app/Http/Controllers/Api/PublicShareLinkController.php`
- Modify: `app/Http/Resources/Approval/ApprovalRequestPresenter.php` (`request.approvers[].opened`)
- Modify: `app/Services/Approval/ApprovalActor.php` (`clientSessionId`, `withClientSession`)
- Modify: `app/Services/Approval/ApprovalService.php` (`recordDecision` stores the session)
- Modify: `app/Services/Approval/ApprovalRecordPdf.php` (`verifiedBy` reads the session)
- Modify: `tests/Feature/Approval/KvRequestCharacterizationTest.php` (pin the workspace slug) + re-record `tests/Fixtures/approval-requests/kv-public.json`
- Test: `tests/Feature/ClientPortal/RequestPageSessionTest.php` (created here)

**Interfaces:**
- Consumes: Task 1 `ApprovalRequestView`, `ClientSession`, `ApprovalDecision::clientSession()`; Task 2 `ClientLaneService::touch()`; Task 3 `ClientSessionService::principal()`, `ClientPrincipal::laneFor()`.
- Produces:
  - `ApprovalActor::$clientSessionId` (`?string`), `ApprovalActor::withClientSession(?ClientSession $session): ApprovalActor`.
  - `PublicShareLinkController::resolve()` now returns `array{0: ShareLink, 1: ApprovalSubject, 2: ?ClientLaneLink, 3: ?ClientSession}` (the session only when the lane came from it).
  - The additive request-page keys of the contract (PR20) and `403 view_only` (PR7).
  - `ApprovalRecordPdf::verifiedBy()` → `"verified · this device"` for a decision made through a session created by code, `"personal link"` for one created by personal link (PR19).

- [ ] **Step 1: Write the failing tests** — create `tests/Feature/ClientPortal/RequestPageSessionTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Jobs\SendApprovalRequestDigest;
use App\Models\ApprovalDecision;
use App\Models\ApprovalRequestView;
use App\Models\ClientSession;
use App\Services\Approval\ApprovalRecordPdf;
use App\Services\Approval\ApprovalRequestService;
use Illuminate\Support\Facades\Bus;
use Illuminate\Support\Facades\Mail;
use Tests\Support\ClientLaneFixtures;

/**
 * Client portal (spec 2026-10-06 §4.5, §6.5): `/s/{token}` read through a
 * client session — viewer, view-only, "opened", the session on a decision.
 * Without a session the page reads exactly as before.
 */
beforeEach(function () {
    Mail::fake();
    Bus::fake([SendApprovalRequestDigest::class]);
    config(['app.frontend_url' => 'https://app.frndos.test']);

    $this->f = ClientLaneFixtures::deck();
    $this->dina = ClientLaneFixtures::namedClient($this->f['brand'], 'dina@brand.test', 'Dina Pratiwi');
    $sent = app(ApprovalRequestService::class)->create(
        $this->f['deck'], $this->f['user'], null, ['dina@brand.test'], 'Please review', null, notify: false,
    );
    $this->request = $sent['request'];
    $this->approvalId = (string) $this->request->approvals()->value('id');
    $this->page = "/api/public/share-links/{$sent['share_link']->token}";
    [$this->session, $this->sessionToken] = ClientLaneFixtures::session($this->dina['user']);
});

test('a session opens the request page as the named client, records the view and shows it opened', function () {
    $anon = $this->getJson($this->page)->assertOk()->json('data');
    expect($anon['viewer'])->toBe(['kind' => 'anonymous', 'name' => null, 'email' => null, 'access_level' => null, 'session' => false])
        ->and($anon['request']['approvers'][0])->toBe(['name' => 'Dina Pratiwi', 'decided' => false, 'opened' => false])
        ->and($anon['workspace'])->toBe(['name' => 'Alva Agency', 'slug' => $this->f['workspace']->slug])
        ->and($anon['access']['view_only'])->toBeFalse()
        ->and(ApprovalRequestView::query()->count())->toBe(0);

    $seen = $this->getJson($this->page, ['X-Client-Session' => $this->sessionToken])->assertOk()->json('data');
    expect($seen['viewer'])->toBe(['kind' => 'client', 'name' => 'Dina Pratiwi', 'email' => 'dina@brand.test', 'access_level' => 'own', 'session' => true])
        ->and($seen['access']['verification_required'])->toBeFalse()
        ->and($seen['request']['approvers'][0]['opened'])->toBeTrue();
    $view = ApprovalRequestView::query()->sole();
    expect($view->user_id)->toBe($this->dina['user']->id)
        ->and($view->first_opened_at->equalTo($view->last_opened_at))->toBeTrue();

    $this->travel(2)->hours();
    $this->getJson($this->page, ['X-Client-Session' => $this->sessionToken])->assertOk();
    $later = $view->fresh();
    expect($later->first_opened_at->equalTo($view->first_opened_at))->toBeTrue()
        ->and($later->last_opened_at->greaterThan($view->last_opened_at))->toBeTrue();
});

test('without a session or with a dead one the page reads as before; the legacy header still works and counts as opened', function () {
    $this->session->forceFill(['revoked_at' => now()])->save();

    $this->getJson($this->page, ['X-Client-Session' => $this->sessionToken])->assertOk()
        ->assertJsonPath('data.viewer.kind', 'anonymous')
        ->assertJsonPath('data.access.verification_required', true);
    expect(ApprovalRequestView::query()->count())->toBe(0);

    $legacy = $this->getJson($this->page, ['X-Lane-Code' => $this->dina['lane']->unique_code])->assertOk()->json('data');
    expect($legacy['viewer'])->toMatchArray(['kind' => 'client', 'access_level' => 'own', 'session' => false])
        ->and($legacy['access']['verification_required'])->toBeFalse()
        ->and($legacy['request']['approvers'][0]['opened'])->toBeTrue()
        ->and(ApprovalRequestView::query()->count())->toBe(1);
});

test('an all_view client may look and pin but never decide', function () {
    $this->dina['lane']->forceFill(['access_level' => 'all_view'])->save();
    $as = ['X-Client-Session' => $this->sessionToken];

    $this->getJson($this->page, $as)->assertOk()
        ->assertJsonPath('data.access.view_only', true)
        ->assertJsonPath('data.viewer.access_level', 'all_view');
    $this->postJson("{$this->page}/decision", ['outcome' => 'approved', 'approval_ids' => [$this->approvalId]], $as)
        ->assertStatus(403)
        ->assertJsonPath('code', 'view_only');
    expect(ApprovalDecision::query()->count())->toBe(0);

    $this->postJson("{$this->page}/comments", ['body' => 'The logo feels small'], $as)->assertCreated();
});

test('a named approver deciding through a session stores the session on the decision', function () {
    $as = ['X-Client-Session' => $this->sessionToken];

    $this->postJson("{$this->page}/decision", ['outcome' => 'approved', 'approval_ids' => [$this->approvalId]], $as)
        ->assertCreated()
        ->assertJsonPath('data.results.0.result', 'decided')
        ->assertJsonPath('data.request.status', 'approved');

    $decision = ApprovalDecision::query()->sole();
    expect($decision->client_session_id)->toBe($this->session->id)
        ->and($decision->actor_user_id)->toBe($this->dina['user']->id)
        ->and($decision->advisory)->toBeFalse()
        ->and(ApprovalRecordPdf::verifiedBy($decision))->toBe('personal link');

    $this->session->forceFill(['created_via' => ClientSession::VIA_CODE])->save();
    expect(ApprovalRecordPdf::verifiedBy($decision->fresh()))->toBe('verified · this device');
});
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/ClientPortal/RequestPageSessionTest.php --compact
```

Expected: FAIL — `viewer` has no `access_level`/`session` keys; the all_view decision returns 201, not 403; `client_session_id` is null.

- [ ] **Step 3: `ApprovalActor`** — `app/Services/Approval/ApprovalActor.php`: add `use App\Models\ClientSession;`; the constructor becomes

```php
    private function __construct(
        public readonly ?User $user,
        public readonly ?string $guestName,
        public readonly ?string $guestEmail,
        public readonly ?ClientLaneLink $lane,
        /** The device session the actor decides through (client portal §4.5). */
        public readonly ?string $clientSessionId = null,
    ) {}
```

and add after `guest()`:

```php
    /** The same actor, deciding through a client device session — stored on the decision. */
    public function withClientSession(?ClientSession $session): self
    {
        return new self($this->user, $this->guestName, $this->guestEmail, $this->lane, $session !== null ? (string) $session->id : null);
    }
```

- [ ] **Step 4: `recordDecision` stores it** — `app/Services/Approval/ApprovalService.php`, in `recordDecision()` replace

```php
            'ip_hash' => $ip !== null ? hash('sha256', $ip.(string) config('app.key')) : null,
            'decided_at' => now(),
```

with

```php
            'ip_hash' => $ip !== null ? hash('sha256', $ip.(string) config('app.key')) : null,
            'client_session_id' => $actor->clientSessionId,
            'decided_at' => now(),
```

- [ ] **Step 5: The record PDF reads it** — `app/Services/Approval/ApprovalRecordPdf.php`: add `use App\Models\ClientSession;`; in `data()` change `'approvals.decisions.laneLink',` to `'approvals.decisions.laneLink', 'approvals.decisions.clientSession',`; replace `verifiedBy()` with

```php
    /**
     * "personal link" / "code · this device" (spec §4.8, ruling S7); a
     * decision made through a client session reads its sign-in (client
     * portal §4.1, ruling PR19).
     */
    public static function verifiedBy(ApprovalDecision $decision): string
    {
        $via = $decision->clientSession?->created_via;
        $kind = $decision->laneLink?->kind;

        return match (true) {
            $via === ClientSession::VIA_CODE => 'verified · this device',
            $via === ClientSession::VIA_PERSONAL_LINK => 'personal link',
            $kind === ClientLaneLink::KIND_PERSONAL => 'personal link',
            $kind === ClientLaneLink::KIND_VERIFIED_GUEST => 'code · this device',
            $decision->actor_user_id !== null => 'frndOS account',
            default => 'not verified',
        };
    }
```

- [ ] **Step 6: "opened" in the public payload** — `app/Http/Resources/Approval/ApprovalRequestPresenter.php`: add `use App\Models\ApprovalRequestView;`; in `publicPayload()` add before `return [`:

```php
        // Client portal §4.5: which named approvers have opened this link.
        $opened = ApprovalRequestView::openedBy([(string) $request->id])[(string) $request->id] ?? [];
```

and replace the public `approvers` map

```php
                'approvers' => array_map(static fn (array $approver): array => [
                    'name' => (string) ($approver['name'] ?? ''),
                    'decided' => self::decided($approvals, self::userIdOf($approver)),
                ], $request->approvers ?? []),
```

with

```php
                'approvers' => array_map(static fn (array $approver): array => [
                    'name' => (string) ($approver['name'] ?? ''),
                    'decided' => self::decided($approvals, self::userIdOf($approver)),
                    'opened' => in_array((string) self::userIdOf($approver), $opened, true),
                ], $request->approvers ?? []),
```

(The agency `agency()` map is not touched — PR20.)

- [ ] **Step 7: `PublicShareLinkController`** (`app/Http/Controllers/Api/PublicShareLinkController.php`)

Imports: add `use App\Models\ApprovalRequestView;`, `use App\Models\ClientSession;`, `use App\Services\ClientLane\ClientSessionService;`. Constructor: add `private readonly ClientSessionService $sessions,` after `private readonly ApprovalRequestDecisionService $requestDecisions,`.

In `show()` replace

```php
        [$link, $subject, $lane] = $resolved;

        // An approval link with no request behind it is a dead link (R8).
```

with

```php
        [$link, $subject, $lane, $session] = $resolved;

        // An approval link with no request behind it is a dead link (R8).
```

replace

```php
        // After the resolve so a failed lookup is not recorded as a view.
        $this->shareLinks->touchAccessed($link);
```

with

```php
        // After the resolve so a failed lookup is not recorded as a view.
        $this->shareLinks->touchAccessed($link);

        // Client portal §4.5 (ruling PR6): a named client's open — session
        // or legacy lane header — is what "Opened" reads. Before the
        // payload, so the viewer sees their own open.
        if ($approvalRequest !== null && $lane !== null && $lane->isPersonal() && $lane->user_id !== null) {
            ApprovalRequestView::record((string) $approvalRequest->id, (string) $lane->user_id);
        }
```

replace `'workspace' => ['name' => (string) ($workspace?->name ?? '')],` with

```php
            // `slug` (client portal §6.5): the web builds "← Approvals" →
            // /s/{workspace.slug}/{brand.slug} from it.
            'workspace' => ['name' => (string) ($workspace?->name ?? ''), 'slug' => (string) ($workspace?->slug ?? '')],
```

replace (request branch)

```php
                    // Part D: a decision here needs an honoured lane.
                    'verification_required' => $lane === null,
                ],
                'viewer' => $this->viewer($lane),
```

with

```php
                    // Part D: a decision here needs an honoured lane.
                    'verification_required' => $lane === null,
                    'view_only' => self::viewOnly($lane),
                ],
                'viewer' => $this->viewer($lane, $session),
```

and replace (round branch)

```php
                'verification_required' => $subject->type === 'campaign'
                    && $lane === null,
            ],
            'viewer' => $this->viewer($lane),
```

with

```php
                'verification_required' => $subject->type === 'campaign'
                    && $lane === null,
                'view_only' => self::viewOnly($lane),
            ],
            'viewer' => $this->viewer($lane, $session),
```

In `decision()` replace

```php
        [$link, $subject, $lane] = $resolved;

        if ($link->role !== ShareLink::ROLE_COMMENT) {
            return $this->error(422, 'read_only_link', 'This link is read-only.');
        }

        if ($link->purpose === ShareLink::PURPOSE_APPROVAL) {
            return $this->decideOnRequest($request, $link, $subject, $lane, $validated);
        }
```

with

```php
        [$link, $subject, $lane, $session] = $resolved;

        if ($link->role !== ShareLink::ROLE_COMMENT) {
            return $this->error(422, 'read_only_link', 'This link is read-only.');
        }

        // Client portal P-6 / ruling PR7: an `all_view` client looks and
        // pins, never decides — on request and round links alike.
        if (self::viewOnly($lane)) {
            return $this->error(403, 'view_only', 'You can view everything here, but not decide. Ask the agency for approval access.');
        }

        if ($link->purpose === ShareLink::PURPOSE_APPROVAL) {
            return $this->decideOnRequest($request, $link, $subject, $lane, $validated, $session);
        }
```

and in the round path replace

```php
        $actor = $this->actor($lane, $validated);
        if ($actor === null) {
            return $this->error(422, 'guest_required', 'Tell us your name and email first.');
        }

        try {
            $decision = $this->approvals->decide($approval, $actor, $validated, $request->ip());
```

with

```php
        $actor = $this->actor($lane, $validated)?->withClientSession($session);
        if ($actor === null) {
            return $this->error(422, 'guest_required', 'Tell us your name and email first.');
        }

        try {
            $decision = $this->approvals->decide($approval, $actor, $validated, $request->ip());
```

In `decideOnRequest()` change the signature to

```php
    private function decideOnRequest(Request $request, ShareLink $link, ApprovalSubject $subject, ?ClientLaneLink $lane, array $validated, ?ClientSession $session = null): JsonResponse
```

and replace

```php
        $actor = $this->actor($lane, $validated);
        if ($actor === null) {
            return $this->error(422, 'guest_required', 'Tell us your name and email first.');
        }

        // Part D (spec §7, ruling R-D1)
```

with

```php
        $actor = $this->actor($lane, $validated)?->withClientSession($session);
        if ($actor === null) {
            return $this->error(422, 'guest_required', 'Tell us your name and email first.');
        }

        // Part D (spec §7, ruling R-D1)
```

In `resolve()` change the docblock `@return array{0: ShareLink, 1: ApprovalSubject, 2: ClientLaneLink|null}|null` to `@return array{0: ShareLink, 1: ApprovalSubject, 2: ClientLaneLink|null, 3: ClientSession|null}|null` and replace

```php
        // A standalone deck (`brand_id NULL`) has no brand for a lane to be
        // scoped to — `X-Lane-Code` never applies, viewer stays anonymous.
        $lane = $subject->brandId !== null
            ? $this->lanes->resolveHeader($request, $subject->brandId)
            : null;

        return [$link, $subject, $lane];
    }
```

with

```php
        // A standalone deck (`brand_id NULL`) has no brand for a lane to be
        // scoped to — no session or `X-Lane-Code` applies, viewer stays anonymous.
        [$lane, $session] = $subject->brandId !== null
            ? $this->viewerLane($request, $subject->brandId)
            : [null, null];

        return [$link, $subject, $lane, $session];
    }

    /**
     * Client portal §4.5: the session user's active lane on the subject's
     * brand first, else the legacy `X-Lane-Code` (kept through the
     * transition), else anonymous. The session is returned only when the
     * lane came from it.
     *
     * @return array{0: ClientLaneLink|null, 1: ClientSession|null}
     */
    private function viewerLane(Request $request, string $brandId): array
    {
        $principal = $this->sessions->principal($request);
        $lane = $principal?->laneFor($brandId);
        if ($lane !== null) {
            $this->lanes->touch($lane);

            return [$lane, $principal->session];
        }

        return [$this->lanes->resolveHeader($request, $brandId), null];
    }

    /** An `all_view` lane: looks and pins, never decides (PR7). */
    private static function viewOnly(?ClientLaneLink $lane): bool
    {
        return $lane !== null && $lane->access_level === ClientLaneLink::ACCESS_ALL_VIEW;
    }
```

Replace `viewer()` with

```php
    /** @return array<string, mixed> */
    private function viewer(?ClientLaneLink $lane, ?ClientSession $session = null): array
    {
        // Client portal §6.5: `session` tells the web to show the portal
        // header; `access_level` its view-only notice.
        $portal = ['access_level' => $lane?->access_level, 'session' => $session !== null];

        if ($lane === null) {
            return ['kind' => 'anonymous', 'name' => null, 'email' => null, ...$portal];
        }

        if ($lane->isPersonal() && $lane->user !== null) {
            return ['kind' => 'client', 'name' => $lane->user->name, 'email' => $lane->user->email, ...$portal];
        }

        return [
            'kind' => 'verified',
            'name' => ClientLaneService::nameFromEmail((string) $lane->email),
            'email' => $lane->email,
            ...$portal,
        ];
    }
```

- [ ] **Step 8: Run the new tests to verify they pass**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/ClientPortal/RequestPageSessionTest.php --compact
```

Expected: PASS (4 tests).

- [ ] **Step 9: Re-record the KV public snapshot (additive keys only)**

In `tests/Feature/Approval/KvRequestCharacterizationTest.php` replace

```php
    $this->kv['workspace']->forceFill(['name' => 'Alva Agency'])->save();
```

with

```php
    $this->kv['workspace']->forceFill(['name' => 'Alva Agency', 'slug' => 'alva-agency'])->save();
```

Record, then inspect the diff:

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && SNAPSHOT_UPDATE=1 DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/Approval/KvRequestCharacterizationTest.php --compact; /usr/bin/git diff --stat tests/Fixtures/approval-requests/ && /usr/bin/git diff tests/Fixtures/approval-requests/kv-public.json
```

Expected: the run ends **incomplete** ("Recorded 10 snapshot(s)…"); `--stat` lists **only** `kv-public.json`; its diff adds exactly `"slug": "alva-agency"` under `workspace`, `"view_only": false` under `access`, and `"access_level": null`, `"session": false` under `viewer` (plus trailing-comma changes on the lines before them). Anything else — STOP: a KV response changed that should not have. (The test's request has no named approvers, so no `opened` appears.)

Compare run:

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/Approval/KvRequestCharacterizationTest.php tests/Feature/Approval/DeckPlanRequestFlowTest.php tests/Feature/ClientPortal/ActiveLaneTest.php --compact
```

Expected: PASS (DeckPlanRequestFlowTest as in the baseline).

- [ ] **Step 10: Mutation check**
  - In `viewerLane()` drop the session branch (always `resolveHeader`) → "a session opens the request page…" fails (`kind` anonymous).
  - Remove the `ApprovalRequestView::record(...)` block → the first two tests fail at `opened`/the view count.
  - Remove the `if (self::viewOnly($lane))` block → "an all_view client…" fails (201).
  - Drop `?->withClientSession($session)` in `decideOnRequest()` → "a named approver deciding through a session…" fails at `client_session_id`.
  - Swap the two `$via` arms in `verifiedBy()` → the same test fails on the label.
  Restore; re-run green.

- [ ] **Step 11: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && for f in app/Http/Controllers/Api/PublicShareLinkController.php app/Http/Resources/Approval/ApprovalRequestPresenter.php app/Services/Approval/ApprovalActor.php app/Services/Approval/ApprovalService.php app/Services/Approval/ApprovalRecordPdf.php tests/Feature/Approval/KvRequestCharacterizationTest.php tests/Feature/ClientPortal/RequestPageSessionTest.php; do php -l "$f" || exit 1; done && vendor/bin/pint app/Http/Controllers/Api/PublicShareLinkController.php app/Http/Resources/Approval/ApprovalRequestPresenter.php app/Services/Approval/ApprovalActor.php app/Services/Approval/ApprovalService.php app/Services/Approval/ApprovalRecordPdf.php tests/Feature/Approval/KvRequestCharacterizationTest.php tests/Feature/ClientPortal/RequestPageSessionTest.php && vendor/bin/pint --test app/Http/Controllers/Api/PublicShareLinkController.php app/Http/Resources/Approval/ApprovalRequestPresenter.php app/Services/Approval/ApprovalActor.php app/Services/Approval/ApprovalService.php app/Services/Approval/ApprovalRecordPdf.php tests/Feature/Approval/KvRequestCharacterizationTest.php tests/Feature/ClientPortal/RequestPageSessionTest.php
/usr/bin/git add app/Http/Controllers/Api/PublicShareLinkController.php app/Http/Resources/Approval/ApprovalRequestPresenter.php app/Services/Approval/ApprovalActor.php app/Services/Approval/ApprovalService.php app/Services/Approval/ApprovalRecordPdf.php tests/Feature/Approval/KvRequestCharacterizationTest.php tests/Fixtures/approval-requests/kv-public.json tests/Feature/ClientPortal/RequestPageSessionTest.php
/usr/bin/git commit -m "feat(api): request page reads the client session — view only, opened, decision audit"
```

---
### Task 6: Portal `me` and the Approvals inbox (brand-scoped `client.session`)

**Files:**
- Create: `app/Services/ClientLane/ClientPortalInbox.php`
- Create: `app/Http/Resources/ClientPortal/PortalInboxPresenter.php`
- Create: `app/Support/ClientLane/PublicBrandLogo.php`
- Modify: `app/Http/Controllers/Api/ClientPortal/PortalController.php` (full file: `me`, `approvals`, `signOut`)
- Modify: `app/Http/Middleware/AuthenticateClientSession.php` (the `brand` scope)
- Modify: `app/Services/ClientLane/ClientLaneService.php` (`portalBrand`)
- Modify: `app/Http/Controllers/Api/PublicShareLinkController.php` (`brandLogoUrl` delegates)
- Modify: `routes/api.php` (`GET public/portal/me`, `GET public/portal/{workspaceSlug}/{brandSlug}/approvals`)
- Test: `tests/Feature/ClientPortal/PortalInboxTest.php` (created here)

**Interfaces:**
- Consumes: Task 2 `activeLanesFor()`, `touch()`; Task 3 `ClientPrincipal`, `client.session`; Task 5 views; `ApprovalRequestPresenter::decided(Collection $approvals, ?string $userId): bool` (existing).
- Produces:
  - `ClientLaneService::portalBrand(string $workspaceSlug, string $brandSlug): ?Brand` (not soft-deleted, scopes stripped).
  - `client.session:brand` — resolves `{workspaceSlug}/{brandSlug}`, requires `ClientPrincipal::laneFor()`, touches the lane, binds `AuthenticateClientSession::BRAND` (`Brand`) and `AuthenticateClientSession::LANE` (`ClientLaneLink`) request attributes; else `404 {"message":"Not found."}`.
  - `ClientPortalInbox::visible(ClientLaneLink): Builder`, `isWaitingOnYou(ApprovalRequest, ClientLaneLink): bool`, `waitingOnYouCount(ClientLaneLink): int`, `groups(ClientLaneLink, ?string $cursor): array{waiting_on_you: list<ApprovalRequest>, waiting_on_others: list<ApprovalRequest>, decided: list<ApprovalRequest>, decided_next_cursor: ?string}` (throws `InvalidArgumentException` on a bad cursor).
  - `PortalInboxPresenter::items(list<ApprovalRequest>, ClientLaneLink): list<array>`, `PortalInboxPresenter::messageLine(?string): ?string`.
  - `PublicBrandLogo::url(Brand): ?string`.

- [ ] **Step 1: Write the failing tests** — create `tests/Feature/ClientPortal/PortalInboxTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Http\Resources\ClientPortal\PortalInboxPresenter;
use App\Jobs\SendApprovalRequestDigest;
use App\Models\ApprovalRequest;
use App\Services\Approval\ApprovalActor;
use App\Services\Approval\ApprovalRequestDecisionService;
use App\Services\Approval\ApprovalRequestService;
use Illuminate\Support\Facades\Bus;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Mail;
use Tests\Support\ClientLaneFixtures;

/**
 * Client portal (spec 2026-10-06 §5.1–§5.2): `me`, the Approvals inbox per
 * access level, decided paging, and the brand-scoped 404.
 *
 * One brand ("Kopi Kenangan"), two clients. Dina is named on: Spring launch
 * (pending), Brand film (pending, with Andi; Dina approved), Autumn
 * (decided by Dina), Pulled (withdrawn). Andi alone: Summer teaser. Nobody:
 * Mood board.
 */
beforeEach(function () {
    Mail::fake();
    Bus::fake([SendApprovalRequestDigest::class]);
    config(['app.frontend_url' => 'https://app.frndos.test']);

    $this->f = ClientLaneFixtures::deck();
    $this->brand = $this->f['brand'];
    $this->dina = ClientLaneFixtures::namedClient($this->brand, 'dina@brand.test', 'Dina Pratiwi');
    $this->andi = ClientLaneFixtures::namedClient($this->brand, 'andi@brand.test', 'Andi Wijaya');

    $send = fn (string $title, array $emails, ?string $message = null): ApprovalRequest => app(ApprovalRequestService::class)->create(
        ClientLaneFixtures::deckOn($this->f, $title), $this->f['user'], null, $emails, $message, null, notify: false,
    )['request'];
    $approve = function (ApprovalRequest $request, array $who, ?string $note = null): void {
        app(ApprovalRequestDecisionService::class)->decide(
            $request,
            ApprovalActor::user($who['user'], $who['lane']),
            ['outcome' => 'approved', 'approval_ids' => $request->approvals()->pluck('id')->map(fn ($id) => (string) $id)->all(), 'note' => $note],
        );
    };

    $this->mine = $send('Spring launch', ['dina@brand.test'], "Final cut — please check the logo lockup\nSecond line");
    $this->andisOnly = $send('Summer teaser', ['andi@brand.test']);
    $this->both = $send('Brand film', ['dina@brand.test', 'andi@brand.test']);
    $this->decided = $send('Autumn', ['dina@brand.test']);
    $this->withdrawn = $send('Pulled', ['dina@brand.test']);
    $this->unnamed = $send('Mood board', []);
    $approve($this->both, $this->dina);
    $approve($this->decided, $this->dina, 'Lovely');
    app(ApprovalRequestService::class)->withdraw($this->withdrawn);

    [, $token] = ClientLaneFixtures::session($this->dina['user']);
    $this->as = ['X-Client-Session' => $token];
    $this->url = "/api/public/portal/{$this->f['workspace']->slug}/{$this->brand->slug}/approvals";
});

test('own sees only the requests naming them, grouped, in the item shape', function () {
    $mineToken = $this->mine->shareLink->token;
    $this->getJson("/api/public/share-links/{$mineToken}", $this->as)->assertOk(); // Dina opens Spring launch

    $response = $this->getJson($this->url, $this->as)->assertOk();
    expect($response->headers->get('Cache-Control'))->toContain('no-store');
    $data = $response->json('data');

    expect($data['access_level'])->toBe('own')
        ->and($data['brand'])->toBe(['name' => 'Kopi Kenangan', 'slug' => $this->brand->slug, 'workspace' => 'Alva Agency', 'logo_url' => null])
        ->and(array_column($data['waiting_on_you'], 'request_id'))->toBe([$this->mine->id])
        ->and(array_column($data['waiting_on_others'], 'request_id'))->toBe([$this->both->id])
        ->and(array_column($data['decided'], 'request_id'))->toBe([$this->decided->id])
        ->and($data['decided_next_cursor'])->toBeNull();

    expect($data['waiting_on_you'][0])->toMatchArray([
        'number' => 1,
        'url' => "/s/{$mineToken}",
        'subject' => ['type' => 'deck', 'title' => 'Spring launch', 'thumbnail_url' => null],
        'item_count' => 1,
        'message_line' => 'Final cut — please check the logo lockup',
        'requested_by' => ['name' => $this->f['user']->name],
        'my_role' => 'approver',
        'approvers' => [['name' => 'Dina Pratiwi', 'decided' => false, 'opened' => true]],
        'counts' => ['decided' => 0, 'total' => 1],
        'status' => 'pending',
        'resolved_at' => null,
        'outcome_line' => null,
    ]);
    expect($data['waiting_on_others'][0]['approvers'])->toBe([
        ['name' => 'Dina Pratiwi', 'decided' => true, 'opened' => false],
        ['name' => 'Andi Wijaya', 'decided' => false, 'opened' => false],
    ]);
    expect($data['decided'][0]['outcome_line'])->toMatchArray(['outcome' => 'approved', 'by' => 'Dina Pratiwi', 'note_excerpt' => 'Lovely'])
        ->and($data['decided'][0]['counts'])->toBe(['decided' => 1, 'total' => 1]);
});

test('all_approve sees every live request of the brand; all_view never has anything waiting on it', function () {
    $this->dina['lane']->forceFill(['access_level' => 'all_approve'])->save();
    $data = $this->getJson($this->url, $this->as)->assertOk()->json('data');

    expect(array_column($data['waiting_on_you'], 'request_id'))->toBe([$this->mine->id])
        ->and(array_column($data['waiting_on_others'], 'request_id'))->toEqualCanonicalizing([$this->both->id, $this->andisOnly->id, $this->unnamed->id])
        ->and(array_column($data['decided'], 'request_id'))->toBe([$this->decided->id]);
    $byId = collect($data['waiting_on_others'])->keyBy('request_id');
    expect($byId[$this->andisOnly->id]['my_role'])->toBe('viewer')
        ->and($byId[$this->both->id]['my_role'])->toBe('approver')
        ->and($byId[$this->unnamed->id]['approvers'])->toBe([]);

    $this->dina['lane']->forceFill(['access_level' => 'all_view'])->save();
    $view = $this->getJson($this->url, $this->as)->assertOk()->json('data');
    expect($view['access_level'])->toBe('all_view')
        ->and($view['waiting_on_you'])->toBe([])
        ->and(array_column($view['waiting_on_others'], 'request_id'))->toEqualCanonicalizing([$this->mine->id, $this->both->id, $this->andisOnly->id, $this->unnamed->id])
        ->and(collect($view['waiting_on_others'])->pluck('my_role')->unique()->values()->all())->toBe(['viewer']);
});

test('decided history: the last 90 days first, then a cursor for older', function () {
    $this->decided->forceFill(['resolved_at' => now()->subDays(10)])->save();
    $older = [];
    foreach ([100, 200] as $days) {
        $request = app(ApprovalRequestService::class)->create(
            ClientLaneFixtures::deckOn($this->f, "Archive {$days}"), $this->f['user'], null, ['dina@brand.test'], null, null, notify: false,
        )['request'];
        $request->forceFill(['status' => 'approved', 'resolved_at' => now()->subDays($days)])->save();
        $older[] = $request->id;
    }

    $first = $this->getJson($this->url, $this->as)->assertOk()->json('data');
    expect(array_column($first['decided'], 'request_id'))->toBe([$this->decided->id])
        ->and($first['decided_next_cursor'])->toBeString();

    $next = $this->getJson($this->url.'?decided_cursor='.$first['decided_next_cursor'], $this->as)->assertOk()->json('data');
    expect(array_column($next['decided'], 'request_id'))->toBe($older)
        ->and($next['decided_next_cursor'])->toBeNull()
        ->and(array_column($next['waiting_on_you'], 'request_id'))->toBe([$this->mine->id]);

    $this->getJson($this->url.'?decided_cursor=not-a-cursor', $this->as)
        ->assertStatus(422)
        ->assertJsonPath('code', 'invalid_cursor');
});

test('me lists only brands with an active lane, most waiting first', function () {
    $g = ClientLaneFixtures::deck();
    $g['brand']->forceFill(['name' => 'Bakmi GM'])->save();
    ClientLaneFixtures::namedClient($g['brand'], 'dina@brand.test', 'Dina Pratiwi');
    foreach (['Opening week', 'Menu boards'] as $title) {
        app(ApprovalRequestService::class)->create(ClientLaneFixtures::deckOn($g, $title), $g['user'], null, ['dina@brand.test'], null, null, notify: false);
    }
    $h = ClientLaneFixtures::deck();
    ClientLaneFixtures::namedClient($h['brand'], 'dina@brand.test', 'Dina Pratiwi')['lane']->forceFill(['revoked_at' => now()])->save();
    $this->dina['lane']->forceFill(['access_level' => 'all_approve'])->save();

    $data = $this->getJson('/api/public/portal/me', $this->as)->assertOk()->json('data');

    expect($data['user'])->toBe(['name' => 'Dina Pratiwi', 'email' => 'dina@brand.test'])
        ->and($data['brands'])->toBe([
            [
                'workspace' => ['name' => 'Alva Agency', 'slug' => $g['workspace']->slug],
                'brand' => ['name' => 'Bakmi GM', 'slug' => $g['brand']->slug, 'logo_url' => null],
                'access_level' => 'own',
                'waiting_on_you' => 2,
            ],
            [
                'workspace' => ['name' => 'Alva Agency', 'slug' => $this->f['workspace']->slug],
                'brand' => ['name' => 'Kopi Kenangan', 'slug' => $this->brand->slug, 'logo_url' => null],
                'access_level' => 'all_approve',
                'waiting_on_you' => 1,
            ],
        ]);
});

test('brand routes need a session and an active lane on that brand; anything else is the one 404', function () {
    $notFound = ['message' => 'Not found.'];
    $this->getJson($this->url)->assertStatus(401)->assertExactJson(['code' => 'session_required', 'message' => 'Sign in to continue.']);
    $this->getJson("/api/public/portal/{$this->f['workspace']->slug}/no-such-brand/approvals", $this->as)->assertNotFound()->assertExactJson($notFound);

    $g = ClientLaneFixtures::deck(); // a brand Dina was never named on
    $gUrl = "/api/public/portal/{$g['workspace']->slug}/{$g['brand']->slug}/approvals";
    $this->getJson($gUrl, $this->as)->assertNotFound()->assertExactJson($notFound);

    // Dina serves both brands; the agency removes her from Kopi Kenangan
    // while her portal is open (Review Focus 1).
    ClientLaneFixtures::namedClient($g['brand'], 'dina@brand.test', 'Dina Pratiwi');
    DB::table('user_brand_roles')->where('user_id', $this->dina['user']->id)->where('brand_id', $this->brand->id)->delete();

    $this->getJson($this->url, $this->as)->assertNotFound()->assertExactJson($notFound);
    $this->getJson($gUrl, $this->as)->assertOk();
    expect(collect($this->getJson('/api/public/portal/me', $this->as)->assertOk()->json('data.brands'))->pluck('brand.slug')->all())
        ->toBe([$g['brand']->slug]);
});

test('message_line is the first non-blank line, at most 120 characters', function () {
    expect(PortalInboxPresenter::messageLine("\n  \nHello there\nmore"))->toBe('Hello there')
        ->and(PortalInboxPresenter::messageLine(null))->toBeNull()
        ->and(PortalInboxPresenter::messageLine(" \n "))->toBeNull()
        ->and(PortalInboxPresenter::messageLine(str_repeat('a', 120)))->toBe(str_repeat('a', 120))
        ->and(PortalInboxPresenter::messageLine(str_repeat('é', 130)))->toBe(str_repeat('é', 119).'…')
        ->and(mb_strlen((string) PortalInboxPresenter::messageLine(str_repeat('é', 130))))->toBe(120);
});
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/ClientPortal/PortalInboxTest.php --compact
```

Expected: FAIL — the portal routes do not exist (404 route-not-found on every `assertOk`), and `Class "App\Http\Resources\ClientPortal\PortalInboxPresenter" not found`.

- [ ] **Step 3: `ClientLaneService::portalBrand()`** — in `app/Services/ClientLane/ClientLaneService.php` add `use App\Models\Workspace;` and, after `activeLane()`:

```php
    /**
     * The brand behind a portal URL `/s/{workspace}/{brand}` (spec P-4):
     * brand slugs are unique per workspace, workspace slugs globally.
     * Scopes stripped (no auth on a public route); a soft-deleted brand is
     * gone.
     */
    public function portalBrand(string $workspaceSlug, string $brandSlug): ?Brand
    {
        $workspaceId = Workspace::query()->where('slug', $workspaceSlug)->value('id');
        if ($workspaceId === null) {
            return null;
        }

        return Brand::query()->withoutGlobalScopes()
            ->whereNull('deleted_at')
            ->where('workspace_id', $workspaceId)
            ->where('slug', $brandSlug)
            ->first();
    }
```

- [ ] **Step 4: The `brand` scope in the middleware** — replace `app/Http/Middleware/AuthenticateClientSession.php` with:

```php
<?php

declare(strict_types=1);

namespace App\Http\Middleware;

// craftsman-ignore: PHP002 — middleware is not final in this codebase.

use App\Services\ClientLane\ClientLaneService;
use App\Services\ClientLane\ClientSessionService;
use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * `client.session` (client portal spec 2026-10-06 §4.4): `X-Client-Session`
 * → a live session → a ClientPrincipal on the request (ClientPrincipal::of).
 * Missing or dead → `401 session_required`.
 *
 * `client.session:brand` also resolves `{workspaceSlug}/{brandSlug}` and
 * requires an ACTIVE lane on that brand; anything else is the dead-link
 * `404 {"message":"Not found."}` — no hint that the brand exists. Every
 * response carries `Cache-Control: no-store`.
 */
class AuthenticateClientSession
{
    public const SESSION_REQUIRED = 'session_required';

    /** Request attributes a `client.session:brand` route reads. */
    public const BRAND = 'client_portal_brand';

    public const LANE = 'client_portal_lane';

    public function __construct(
        private readonly ClientSessionService $sessions,
        private readonly ClientLaneService $lanes,
    ) {}

    public function handle(Request $request, Closure $next, ?string $scope = null): Response
    {
        $principal = $this->sessions->principal($request);
        if ($principal === null) {
            return response()
                ->json(['code' => self::SESSION_REQUIRED, 'message' => 'Sign in to continue.'], 401)
                ->header('Cache-Control', 'no-store');
        }

        if ($scope === 'brand') {
            $brand = $this->lanes->portalBrand((string) $request->route('workspaceSlug'), (string) $request->route('brandSlug'));
            $lane = $brand !== null ? $principal->laneFor((string) $brand->id) : null;
            if ($lane === null) {
                return response()->json(['message' => 'Not found.'], 404)->header('Cache-Control', 'no-store');
            }

            // A portal visit is a use of the lane (Clients tab "last opened").
            $this->lanes->touch($lane);
            $request->attributes->set(self::BRAND, $brand);
            $request->attributes->set(self::LANE, $lane);
        }

        $response = $next($request);
        $response->headers->set('Cache-Control', 'no-store');

        return $response;
    }
}
```

- [ ] **Step 5: `app/Support/ClientLane/PublicBrandLogo.php`** (moved out of `PublicShareLinkController::brandLogoUrl`, whose body becomes `return PublicBrandLogo::url($brand);` with `use App\Support\ClientLane\PublicBrandLogo;` added):

```php
<?php

declare(strict_types=1);

namespace App\Support\ClientLane;

use App\Models\Brand;
use Illuminate\Support\Facades\Storage;

/**
 * A brand logo URL for UNAUTHENTICATED pages. `Brand::getLogoAttribute()`
 * resolves the S3 key only when `request()->wantsJson()`, which depends on
 * the caller's `Accept` header — resolve it directly instead.
 */
final class PublicBrandLogo
{
    public static function url(Brand $brand): ?string
    {
        $raw = $brand->getRawOriginal('logo');
        if (! $raw) {
            return null;
        }

        // Demo brands store a local web asset path, already a public URL.
        if (str_starts_with($raw, '/')) {
            return $raw;
        }

        return Storage::disk('s3')->url($raw);
    }
}
```

- [ ] **Step 6: `app/Services/ClientLane/ClientPortalInbox.php`**

```php
<?php

declare(strict_types=1);

namespace App\Services\ClientLane;

// craftsman-ignore: PHP002 — resolved from the container and swapped in tests.

use App\Http\Resources\Approval\ApprovalRequestPresenter;
use App\Models\Approval;
use App\Models\ApprovalRequest;
use App\Models\ClientLaneLink;
use DateTimeInterface;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Carbon;
use InvalidArgumentException;

/**
 * The client portal's Approvals inbox (spec 2026-10-06 §5.2): which of a
 * brand's requests a lane may see, and in which group.
 *
 *   own          requests whose `approvers` name the client
 *   all_approve  every request on the brand
 *   all_view     every request on the brand; never "waiting on you" (PR7)
 *
 * Withdrawn (`not_relevant`) requests never appear.
 */
class ClientPortalInbox
{
    /** Decided requests on the first page (ruling PR9). */
    public const DECIDED_DAYS = 90;

    public const PAGE = 50;

    /** Everything PortalInboxPresenter reads, loaded once per query. */
    private const WITH = ['approvals.decisions.actor:id,name', 'shareLink', 'requester:id,name'];

    /** @return Builder<ApprovalRequest> */
    public function visible(ClientLaneLink $lane): Builder
    {
        $query = ApprovalRequest::query()
            ->where('brand_id', (string) $lane->brand_id)
            ->where('status', '!=', Approval::STATUS_NOT_RELEVANT);

        if ($lane->access_level === ClientLaneLink::ACCESS_OWN) {
            // jsonb `@>`, served by approval_requests_approvers_gin.
            $query->whereJsonContains('approvers', [['user_id' => (string) $lane->user_id]]);
        }

        return $query;
    }

    /** Pending, named, some live item still lacks this client's decision — and they may decide. */
    public function isWaitingOnYou(ApprovalRequest $request, ClientLaneLink $lane): bool
    {
        $userId = (string) $lane->user_id;

        return $lane->access_level !== ClientLaneLink::ACCESS_ALL_VIEW
            && $request->isPending()
            && in_array($userId, $request->approverUserIds(), true)
            && ! ApprovalRequestPresenter::decided($request->approvals, $userId);
    }

    public function waitingOnYouCount(ClientLaneLink $lane): int
    {
        if ($lane->access_level === ClientLaneLink::ACCESS_ALL_VIEW) {
            return 0;
        }

        return $this->visible($lane)
            ->where('status', Approval::STATUS_PENDING)
            ->whereJsonContains('approvers', [['user_id' => (string) $lane->user_id]])
            ->with('approvals.decisions')
            ->get()
            ->filter(fn (ApprovalRequest $request): bool => $this->isWaitingOnYou($request, $lane))
            ->count();
    }

    /**
     * @return array{waiting_on_you: list<ApprovalRequest>, waiting_on_others: list<ApprovalRequest>, decided: list<ApprovalRequest>, decided_next_cursor: string|null}
     *
     * @throws InvalidArgumentException a malformed `decided_cursor`
     */
    public function groups(ClientLaneLink $lane, ?string $cursor): array
    {
        [$decided, $next] = $this->decidedPage($lane, $cursor);

        $open = $this->visible($lane)
            ->where('status', Approval::STATUS_PENDING)
            ->with(self::WITH)
            ->orderByRaw('decide_by ASC NULLS LAST')
            ->orderByDesc('sent_at')
            ->orderByDesc('id')
            ->get();

        $mine = [];
        $others = [];
        foreach ($open as $request) {
            if ($this->isWaitingOnYou($request, $lane)) {
                $mine[] = $request;
            } else {
                $others[] = $request;
            }
        }

        return ['waiting_on_you' => $mine, 'waiting_on_others' => $others, 'decided' => $decided, 'decided_next_cursor' => $next];
    }

    /** @return array{0: list<ApprovalRequest>, 1: string|null} */
    private function decidedPage(ClientLaneLink $lane, ?string $cursor): array
    {
        $decided = fn (): Builder => $this->visible($lane)->where('status', '!=', Approval::STATUS_PENDING);
        $ordered = fn (): Builder => $decided()->with(self::WITH)->orderByDesc('resolved_at')->orderByDesc('id');

        if ($cursor === null) {
            $boundary = now()->subDays(self::DECIDED_DAYS);
            $rows = $ordered()->where('resolved_at', '>=', $boundary)->limit(self::PAGE + 1)->get();
            $page = $rows->take(self::PAGE)->values();
            $last = $page->last();
            $more = $rows->count() > self::PAGE || $decided()->where('resolved_at', '<', $boundary)->exists();

            return [$page->all(), $more ? self::encode($last?->resolved_at ?? $boundary, $last !== null ? (string) $last->id : '') : null];
        }

        [$at, $id] = self::decode($cursor);
        $rows = $ordered()
            ->where(function (Builder $q) use ($at, $id) {
                $q->where('resolved_at', '<', $at)
                    ->orWhere(fn (Builder $tie) => $tie->where('resolved_at', '=', $at)->where('id', '<', $id));
            })
            ->limit(self::PAGE + 1)
            ->get();
        $page = $rows->take(self::PAGE)->values();
        $last = $page->last();

        return [$page->all(), $rows->count() > self::PAGE && $last !== null ? self::encode($last->resolved_at, (string) $last->id) : null];
    }

    /** Opaque to the web: base64url of `{"r": resolved_at (UTC, µs), "i": id}`. */
    private static function encode(DateTimeInterface $at, string $id): string
    {
        $json = json_encode(['r' => Carbon::instance($at)->utc()->format('Y-m-d\TH:i:s.u\Z'), 'i' => $id], JSON_THROW_ON_ERROR);

        return rtrim(strtr(base64_encode($json), '+/', '-_'), '=');
    }

    /**
     * @return array{0: string, 1: string} the instant as a Postgres literal (bound as a string, so the
     *                                    microseconds survive) and the tie-breaking id
     */
    private static function decode(string $cursor): array
    {
        $json = base64_decode(strtr($cursor, '-_', '+/'), true);
        $data = is_string($json) ? json_decode($json, true) : null;

        $valid = is_array($data)
            && is_string($data['r'] ?? null)
            && is_string($data['i'] ?? null)
            && preg_match('/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/', $data['r']) === 1
            && ($data['i'] === '' || preg_match('/^[0-9a-z]{26}$/', $data['i']) === 1);
        if (! $valid) {
            throw new InvalidArgumentException('Invalid decided cursor.');
        }

        return [str_replace('T', ' ', substr($data['r'], 0, -1)).'+00', $data['i']];
    }
}
```

- [ ] **Step 7: `app/Http/Resources/ClientPortal/PortalInboxPresenter.php`**

```php
<?php

declare(strict_types=1);

namespace App\Http\Resources\ClientPortal;

use App\Http\Resources\Approval\ApprovalRequestPresenter;
use App\Models\Approval;
use App\Models\ApprovalDecision;
use App\Models\ApprovalRequest;
use App\Models\ApprovalRequestView;
use App\Models\ClientLaneLink;
use App\Services\Approval\ApprovalSubject;
use Illuminate\Validation\ValidationException;

/**
 * The portal inbox `Item` (client portal spec 2026-10-06 §5.2; rulings
 * PR8, PR10–PR12).
 */
final class PortalInboxPresenter
{
    /**
     * @param  list<ApprovalRequest>  $requests  loaded with ClientPortalInbox's relations
     * @return list<array<string, mixed>>
     */
    public static function items(array $requests, ClientLaneLink $lane): array
    {
        $opened = ApprovalRequestView::openedBy(array_map(static fn (ApprovalRequest $r): string => (string) $r->id, $requests));

        $subjects = [];
        $items = [];
        foreach ($requests as $request) {
            $key = $request->subject_type.':'.$request->subject_id;
            if (! array_key_exists($key, $subjects)) {
                $subjects[$key] = self::subject($request);
            }
            // PR12: a deleted subject has nothing to open.
            if ($subjects[$key] === null) {
                continue;
            }
            $items[] = self::item($request, $subjects[$key], $lane, $opened[(string) $request->id] ?? []);
        }

        return $items;
    }

    /** First non-blank line, ≤ 120 characters (PR10). */
    public static function messageLine(?string $message): ?string
    {
        foreach (preg_split('/\R/u', (string) $message) ?: [] as $line) {
            $line = trim($line);
            if ($line !== '') {
                return self::cut($line, 120);
            }
        }

        return null;
    }

    /**
     * @param  list<string>  $openedBy
     * @return array<string, mixed>
     */
    private static function item(ApprovalRequest $request, ApprovalSubject $subject, ClientLaneLink $lane, array $openedBy): array
    {
        $named = in_array((string) $lane->user_id, $request->approverUserIds(), true);
        $counts = $request->counts();
        $decided = $counts['approved'] + $counts['approved_with_changes'] + $counts['changes_required'];
        $total = $decided + $counts['pending'];
        $link = $request->shareLink;

        return [
            'request_id' => (string) $request->id,
            'number' => $request->number,
            'url' => $link !== null && $link->isActive() ? '/s/'.$link->token : null,
            'subject' => ['type' => $subject->type, 'title' => $subject->title, 'thumbnail_url' => $subject->thumbnailUrl],
            'item_count' => $total,
            'message_line' => self::messageLine($request->message),
            'requested_by' => ['name' => $request->requester?->name],
            'sent_at' => $request->sent_at?->toISOString(),
            'decide_by' => $request->decide_by?->toISOString(),
            'my_role' => $named && $lane->access_level !== ClientLaneLink::ACCESS_ALL_VIEW ? 'approver' : 'viewer',
            'approvers' => array_map(static fn (array $approver): array => [
                'name' => (string) ($approver['name'] ?? ''),
                'decided' => ApprovalRequestPresenter::decided($request->approvals, isset($approver['user_id']) ? (string) $approver['user_id'] : null),
                'opened' => isset($approver['user_id']) && in_array((string) $approver['user_id'], $openedBy, true),
            ], $request->approvers ?? []),
            'counts' => ['decided' => $decided, 'total' => $total],
            'status' => $request->status,
            'resolved_at' => $request->resolved_at?->toISOString(),
            'outcome_line' => $request->isPending() ? null : self::outcomeLine($request),
        ];
    }

    /** @return array{outcome: string, by: string|null, at: string|null, note_excerpt: string|null} */
    private static function outcomeLine(ApprovalRequest $request): array
    {
        /** @var ApprovalDecision|null $closing */
        $closing = $request->approvals
            ->flatMap(static fn (Approval $approval) => $approval->decisions)
            ->filter(static fn (ApprovalDecision $d): bool => $d->isResolving() && ! $d->advisory)
            ->sortBy([['decided_at', 'desc'], ['id', 'desc']])
            ->first();
        $note = trim((string) ($closing?->note ?? ''));

        return [
            'outcome' => $request->status,
            'by' => $closing?->actorName(),
            'at' => $request->resolved_at?->toISOString(),
            'note_excerpt' => $note === '' ? null : self::cut($note, 140),
        ];
    }

    private static function subject(ApprovalRequest $request): ?ApprovalSubject
    {
        try {
            return ApprovalSubject::find((string) $request->subject_type, (string) $request->subject_id);
        } catch (ValidationException) {
            return null;
        }
    }

    private static function cut(string $text, int $max): string
    {
        return mb_strlen($text) > $max ? rtrim(mb_substr($text, 0, $max - 1)).'…' : $text;
    }
}
```

- [ ] **Step 8: `app/Http/Controllers/Api/ClientPortal/PortalController.php`** — replace the file:

```php
<?php

declare(strict_types=1);

namespace App\Http\Controllers\Api\ClientPortal;

// craftsman-ignore: PHP002 — controllers are not final in this codebase.

use App\Http\Controllers\Controller;
use App\Http\Middleware\AuthenticateClientSession;
use App\Http\Resources\ClientPortal\PortalInboxPresenter;
use App\Models\Brand;
use App\Models\ClientLaneLink;
use App\Models\Workspace;
use App\Services\ClientLane\ClientPortalInbox;
use App\Services\ClientLane\ClientPrincipal;
use App\Services\ClientLane\ClientSessionService;
use App\Support\ClientLane\PublicBrandLogo;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Http\Response;
use InvalidArgumentException;

/**
 * The client portal api (spec 2026-10-06 §5), behind `client.session`.
 */
class PortalController extends Controller
{
    public function __construct(
        private readonly ClientSessionService $sessions,
        private readonly ClientPortalInbox $inbox,
    ) {}

    /** GET public/portal/me (§5.1): the person and their brands with an active lane. */
    public function me(Request $request): JsonResponse
    {
        $principal = ClientPrincipal::of($request);

        $brands = [];
        foreach ($principal->lanes as $lane) {
            $brand = $lane->brand;
            if ($brand === null) {
                continue;
            }
            $workspace = Workspace::query()->find($brand->workspace_id);
            $brands[] = [
                'workspace' => ['name' => (string) ($workspace?->name ?? ''), 'slug' => (string) ($workspace?->slug ?? '')],
                'brand' => ['name' => (string) $brand->name, 'slug' => (string) $brand->slug, 'logo_url' => PublicBrandLogo::url($brand)],
                'access_level' => $lane->access_level,
                'waiting_on_you' => $this->inbox->waitingOnYouCount($lane),
            ];
        }

        // Most waiting first, then by name.
        usort($brands, static fn (array $a, array $b): int => [$b['waiting_on_you'], mb_strtolower($a['brand']['name'])]
            <=> [$a['waiting_on_you'], mb_strtolower($b['brand']['name'])]);

        return response()->json(['data' => [
            'user' => ['name' => (string) $principal->user->name, 'email' => (string) $principal->user->email],
            'brands' => $brands,
        ]]);
    }

    /** GET public/portal/{workspaceSlug}/{brandSlug}/approvals?decided_cursor= (§5.2). */
    public function approvals(Request $request): JsonResponse
    {
        $validated = $request->validate(['decided_cursor' => ['nullable', 'string', 'max:300']]);
        /** @var Brand $brand */
        $brand = $request->attributes->get(AuthenticateClientSession::BRAND);
        /** @var ClientLaneLink $lane */
        $lane = $request->attributes->get(AuthenticateClientSession::LANE);

        try {
            $groups = $this->inbox->groups($lane, $validated['decided_cursor'] ?? null);
        } catch (InvalidArgumentException) {
            return response()->json(['code' => 'invalid_cursor', 'message' => 'That page of history is not available.'], 422);
        }

        return response()->json(['data' => [
            'brand' => [
                'name' => (string) $brand->name,
                'slug' => (string) $brand->slug,
                'workspace' => (string) (Workspace::query()->whereKey($brand->workspace_id)->value('name') ?? ''),
                'logo_url' => PublicBrandLogo::url($brand),
            ],
            'access_level' => $lane->access_level,
            'waiting_on_you' => PortalInboxPresenter::items($groups['waiting_on_you'], $lane),
            'waiting_on_others' => PortalInboxPresenter::items($groups['waiting_on_others'], $lane),
            'decided' => PortalInboxPresenter::items($groups['decided'], $lane),
            'decided_next_cursor' => $groups['decided_next_cursor'],
        ]]);
    }

    /** DELETE public/portal/session — "Sign out this device" (§5.3). */
    public function signOut(Request $request): Response
    {
        $this->sessions->revoke(ClientPrincipal::of($request)->session);

        return response()->noContent();
    }
}
```

- [ ] **Step 9: Routes** — in `routes/api.php` replace the Task 3 group

```php
Route::middleware(['throttle:public-portal', 'client.session'])->group(function () {
    Route::delete('public/portal/session', [PortalController::class, 'signOut'])
        ->name('public.portal.session.destroy');
});
```

with

```php
Route::middleware(['throttle:public-portal', 'client.session'])->group(function () {
    Route::get('public/portal/me', [PortalController::class, 'me'])
        ->name('public.portal.me');
    Route::delete('public/portal/session', [PortalController::class, 'signOut'])
        ->name('public.portal.session.destroy');
});
// Brand-scoped: an active lane on {workspaceSlug}/{brandSlug} or the dead-link 404.
Route::middleware(['throttle:public-portal', 'client.session:brand'])->group(function () {
    Route::get('public/portal/{workspaceSlug}/{brandSlug}/approvals', [PortalController::class, 'approvals'])
        ->name('public.portal.approvals');
});
```

- [ ] **Step 10: Run the tests to verify they pass**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/ClientPortal/PortalInboxTest.php tests/Feature/ClientPortal/ClientSessionTest.php tests/Feature/ClientPortal/RequestPageSessionTest.php --compact
```

Expected: PortalInboxTest 6 passed; the other two still green.

- [ ] **Step 11: Mutation check**
  - Drop the `own` `whereJsonContains` in `visible()` → "own sees only…" fails (Summer teaser and Mood board appear).
  - Drop `&& $lane->access_level !== ACCESS_ALL_VIEW` in `isWaitingOnYou()` → "all_approve sees… all_view never…" fails (`waiting_on_you` not empty).
  - Drop `->where('status', '!=', not_relevant)` → "own sees only…" fails (Pulled in `decided`).
  - Drop `|| $decided()->where('resolved_at', '<', $boundary)->exists()` → "decided history…" fails (cursor null).
  - Remove the `usort` in `me()` → "me lists only…" fails on order.
  - In the middleware, skip the `$lane === null` 404 (bind a null lane) → "brand routes need…" fails.
  - Return `false` for `opened` → "own sees only…" fails at `opened: true`.
  Restore; re-run green.

- [ ] **Step 12: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && for f in app/Services/ClientLane/ClientPortalInbox.php app/Http/Resources/ClientPortal/PortalInboxPresenter.php app/Support/ClientLane/PublicBrandLogo.php app/Http/Controllers/Api/ClientPortal/PortalController.php app/Http/Middleware/AuthenticateClientSession.php app/Services/ClientLane/ClientLaneService.php app/Http/Controllers/Api/PublicShareLinkController.php routes/api.php tests/Feature/ClientPortal/PortalInboxTest.php; do php -l "$f" || exit 1; done && vendor/bin/pint app/Services/ClientLane/ClientPortalInbox.php app/Http/Resources/ClientPortal/PortalInboxPresenter.php app/Support/ClientLane/PublicBrandLogo.php app/Http/Controllers/Api/ClientPortal/PortalController.php app/Http/Middleware/AuthenticateClientSession.php app/Services/ClientLane/ClientLaneService.php app/Http/Controllers/Api/PublicShareLinkController.php tests/Feature/ClientPortal/PortalInboxTest.php && vendor/bin/pint --test app/Services/ClientLane/ClientPortalInbox.php app/Http/Resources/ClientPortal/PortalInboxPresenter.php app/Support/ClientLane/PublicBrandLogo.php app/Http/Controllers/Api/ClientPortal/PortalController.php app/Http/Middleware/AuthenticateClientSession.php app/Services/ClientLane/ClientLaneService.php app/Http/Controllers/Api/PublicShareLinkController.php tests/Feature/ClientPortal/PortalInboxTest.php
/usr/bin/git add app/Services/ClientLane/ClientPortalInbox.php app/Http/Resources/ClientPortal/PortalInboxPresenter.php app/Support/ClientLane/PublicBrandLogo.php app/Http/Controllers/Api/ClientPortal/PortalController.php app/Http/Middleware/AuthenticateClientSession.php app/Services/ClientLane/ClientLaneService.php app/Http/Controllers/Api/PublicShareLinkController.php routes/api.php tests/Feature/ClientPortal/PortalInboxTest.php
/usr/bin/git commit -m "feat(api): client portal me and the approvals inbox per access level"
```

---
### Task 7: Portal sign-in by code (enumeration-safe, throttled)

**Files:**
- Modify: `app/Services/ClientLane/ClientVerificationCodeService.php` (`requestForBrand`, `verifyForBrand`, `spendNewest`)
- Create: `app/Http/Controllers/Api/ClientPortal/PortalSignInController.php`
- Modify: `app/Providers/AppServiceProvider.php` (limiters `public-portal-code`, `public-portal-code-verify`)
- Modify: `routes/api.php`
- Test: `tests/Feature/ClientPortal/ClientSessionTest.php`

**Interfaces:**
- Consumes: Task 1 link-less codes; Task 2 `activeLane()`; Task 3 `ClientSessionService::issue()`; Task 6 `ClientLaneService::portalBrand()`.
- Produces:
  - `ClientVerificationCodeService::requestForBrand(string $email, Brand $brand): void` — silent unless the address has an active lane on the brand.
  - `ClientVerificationCodeService::verifyForBrand(string $email, string $code, Brand $brand): User` — throws `InvalidVerificationCodeException` / `VerificationCodeExpiredException`.
  - Routes `POST public/portal/{workspaceSlug}/{brandSlug}/code` (`public.portal.code`) and `…/code/verify` (`public.portal.code.verify`).

- [ ] **Step 1: Write the failing tests** (append to `tests/Feature/ClientPortal/ClientSessionTest.php`; add imports `use App\Mail\ClientVerificationCodeMail;`)

```php
test('a portal code request answers the same 202 for everyone and mails only an active client of that brand', function () {
    $f = ClientLaneFixtures::deck();
    $dina = ClientLaneFixtures::namedClient($f['brand'], 'dina@brand.test', 'Dina Pratiwi');
    $other = ClientLaneFixtures::deck();
    $url = "/api/public/portal/{$f['workspace']->slug}/{$f['brand']->slug}/code";

    $bodies = [];
    foreach ([
        [$url, 'nobody@brand.test'],                                                      // unknown address
        ["/api/public/portal/{$f['workspace']->slug}/no-such-brand/code", 'dina@brand.test'], // unknown brand
        ["/api/public/portal/{$other['workspace']->slug}/{$other['brand']->slug}/code", 'dina@brand.test'], // not her brand
    ] as [$target, $email]) {
        $bodies[] = $this->postJson($target, ['email' => $email])->assertStatus(202)->getContent();
    }
    Mail::assertNothingQueued();

    $bodies[] = $this->postJson($url, ['email' => 'DINA@brand.test'])->assertStatus(202)->getContent();
    Mail::assertQueued(ClientVerificationCodeMail::class, 1);
    expect(array_unique($bodies))->toHaveCount(1)
        ->and(ClientVerificationCode::query()->where('email', 'dina@brand.test')->where('brand_id', $f['brand']->id)->whereNull('share_link_id')->count())->toBe(1);

    // A revoked client gets nothing either.
    $dina['lane']->forceFill(['revoked_at' => now()])->save();
    $this->postJson($url, ['email' => 'dina@brand.test'])->assertStatus(202);
    Mail::assertQueued(ClientVerificationCodeMail::class, 1);
});

test('portal code requests are throttled per address and brand, and per IP', function () {
    $f = ClientLaneFixtures::deck();
    $url = "/api/public/portal/{$f['workspace']->slug}/{$f['brand']->slug}/code";

    foreach (range(1, 5) as $i) {
        $this->postJson($url, ['email' => 'dina@brand.test'])->assertStatus(202);
    }
    $this->postJson($url, ['email' => 'dina@brand.test'])->assertStatus(429); // 6th for (dina, brand)

    // Other addresses have their own bucket… until the IP bucket (10/min,
    // hit by all 6 requests above) runs out.
    foreach (range(1, 4) as $i) {
        $this->postJson($url, ['email' => "guest{$i}@brand.test"])->assertStatus(202);
    }
    $this->postJson($url, ['email' => 'guest9@brand.test'])->assertStatus(429);
});

test('a portal code verifies into a session; link and portal codes never cross; a removed client gets nothing', function () {
    $f = ClientLaneFixtures::sendRequest('deck');
    $dina = ClientLaneFixtures::namedClient($f['brand'], 'dina@brand.test', 'Dina Pratiwi');
    $verifyUrl = "/api/public/portal/{$f['workspace']->slug}/{$f['brand']->slug}/code/verify";
    $plant = fn (string $code, ?string $linkId) => ClientVerificationCode::create([
        'email' => 'dina@brand.test',
        'brand_id' => (string) $f['brand']->id,
        'share_link_id' => $linkId,
        'code_hash' => ClientVerificationCode::hashCode($code),
        'attempts' => 0,
        'expires_at' => now()->addMinutes(ClientVerificationCode::TTL_MINUTES),
    ]);

    // A request-link code is not a portal code.
    $plant('111111', (string) $f['link']->id);
    $this->postJson($verifyUrl, ['email' => 'dina@brand.test', 'code' => '111111'])->assertStatus(422)->assertJsonPath('code', 'code_expired');

    $plant('246810', null);
    $this->postJson($verifyUrl, ['email' => 'dina@brand.test', 'code' => '000000'])
        ->assertStatus(422)->assertJsonPath('code', 'invalid_code')->assertJsonPath('attempts_left', 4);
    $data = $this->postJson($verifyUrl, ['email' => 'dina@brand.test', 'code' => '246810'], ['User-Agent' => ClientLaneFixtures::UA_SAFARI_IPHONE])
        ->assertOk()->json('data');
    expect($data['session_token'])->toMatch('/^[A-Za-z0-9_-]{43}$/')
        ->and($data['expires_at'])->not->toBeNull();
    $session = ClientSession::query()->sole();
    expect($session->user_id)->toBe($dina['user']->id)
        ->and($session->created_via)->toBe('code')
        ->and($session->device_label)->toBe('Safari · iOS');

    // A portal code is not spendable on the link (the link's own code is checked instead).
    $plant('135790', null);
    $this->postJson('/api/public/lane/code/verify', ['email' => 'dina@brand.test', 'code' => '135790', 'share_token' => $f['link']->token])
        ->assertStatus(422)->assertJsonPath('code', 'invalid_code');

    // Removed after the code was sent (Review Focus 4).
    $plant('975310', null);
    DB::table('user_brand_roles')->where('user_id', $dina['user']->id)->delete();
    $this->postJson($verifyUrl, ['email' => 'dina@brand.test', 'code' => '975310'])->assertStatus(422)->assertJsonPath('code', 'code_expired');
    expect(ClientSession::query()->count())->toBe(1);
});
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/ClientPortal/ClientSessionTest.php --compact
```

Expected: the 7 earlier tests pass; the 3 new ones FAIL (no route: 404 instead of 202/422).

- [ ] **Step 3: Brand-scoped codes** — `app/Services/ClientLane/ClientVerificationCodeService.php`

Add imports `use App\Models\User;` and `use Illuminate\Database\Eloquent\Builder;`. Add after `verify()`:

```php
    /**
     * Portal sign-in (client portal spec §5.3, ruling PR14): mail a code
     * bound to (address, brand) — `share_link_id NULL` — only when the
     * address holds an ACTIVE lane on the brand. Silent otherwise; the
     * controller answers one `202` whatever happened.
     */
    public function requestForBrand(string $email, Brand $brand): void
    {
        $email = strtolower(trim($email));

        $user = User::query()->whereRaw('LOWER(email) = ?', [$email])->first();
        if ($user === null || $this->lanes->activeLane($user, (string) $brand->id) === null) {
            return;
        }

        $code = ClientVerificationCode::generate();

        DB::transaction(function () use ($email, $brand, $code): void {
            ClientVerificationCode::query()
                ->where('email', $email)
                ->where('brand_id', (string) $brand->id)
                ->whereNull('share_link_id')
                ->live()
                ->update(['expires_at' => now()]);

            ClientVerificationCode::create([
                'email' => $email,
                'brand_id' => (string) $brand->id,
                'share_link_id' => null,
                'code_hash' => ClientVerificationCode::hashCode($code),
                'attempts' => 0,
                'expires_at' => now()->addMinutes(ClientVerificationCode::TTL_MINUTES),
            ]);
        });

        Mail::to($email)->queue(new ClientVerificationCodeMail(
            code: $code,
            brandName: (string) $brand->name,
        ));
    }

    /**
     * Spend a portal code. The client's lane is re-checked AFTER the spend:
     * one removed since the code was mailed gets `code_expired`, never a
     * session.
     *
     * @throws InvalidVerificationCodeException a wrong code with 1..4 tries left
     * @throws VerificationCodeExpiredException no usable code, or no active lane any more
     */
    public function verifyForBrand(string $email, string $code, Brand $brand): User
    {
        $email = strtolower(trim($email));

        [$outcome, $payload] = $this->spendNewest(
            ClientVerificationCode::query()
                ->where('email', $email)
                ->where('brand_id', (string) $brand->id)
                ->whereNull('share_link_id'),
            $code,
        );

        if ($outcome === 'invalid') {
            throw new InvalidVerificationCodeException((int) $payload);
        }
        if ($outcome !== 'spent') {
            throw new VerificationCodeExpiredException;
        }

        $user = User::query()->whereRaw('LOWER(email) = ?', [$email])->first();
        if ($user === null || $this->lanes->activeLane($user, (string) $brand->id) === null) {
            throw new VerificationCodeExpiredException;
        }

        return $user;
    }

    /**
     * The newest live code of `$codes`, checked under lock. The outcome
     * leaves the transaction as a VALUE (as in verify()): throwing inside
     * would roll the attempts counter back and make the cap infinite.
     *
     * @param  Builder<ClientVerificationCode>  $codes
     * @return array{0: 'spent'|'invalid'|'expired', 1: ClientVerificationCode|int|null}
     */
    private function spendNewest(Builder $codes, string $code): array
    {
        return DB::transaction(function () use ($codes, $code): array {
            /** @var ClientVerificationCode|null $row */
            $row = $codes->live()->orderByDesc('created_at')->orderByDesc('id')->lockForUpdate()->first();
            if ($row === null) {
                return ['expired', null];
            }

            if (! hash_equals($row->code_hash, ClientVerificationCode::hashCode($code))) {
                $attempts = $row->attempts + 1;
                $row->forceFill(['attempts' => $attempts])->save();
                $left = ClientVerificationCode::MAX_ATTEMPTS - $attempts;

                return $left > 0 ? ['invalid', $left] : ['expired', null];
            }

            $row->forceFill(['used_at' => now()])->save();

            return ['spent', $row];
        });
    }
```

(`verify()` for link codes is left as it is: it mints the lane inside its own transaction.)

- [ ] **Step 4: `app/Http/Controllers/Api/ClientPortal/PortalSignInController.php`**

```php
<?php

declare(strict_types=1);

namespace App\Http\Controllers\Api\ClientPortal;

// craftsman-ignore: PHP002 — controllers are not final in this codebase.

use App\Exceptions\ClientLane\InvalidVerificationCodeException;
use App\Exceptions\ClientLane\VerificationCodeExpiredException;
use App\Http\Controllers\Controller;
use App\Models\ClientSession;
use App\Services\ClientLane\ClientLaneService;
use App\Services\ClientLane\ClientSessionService;
use App\Services\ClientLane\ClientVerificationCodeService;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;

/**
 * Portal sign-in by code (client portal spec 2026-10-06 §5.3, §6.4).
 *
 * SECURITY: `requestCode` is not an oracle — an unknown workspace, brand or
 * address, a revoked client and a real send all answer the same `202`.
 * `verifyCode` answers only `invalid_code` / `code_expired` failures, the
 * same set whether or not the brand exists. Called by the web's server
 * route: the token in its body never reaches page JavaScript.
 */
class PortalSignInController extends Controller
{
    public function __construct(
        private readonly ClientLaneService $lanes,
        private readonly ClientVerificationCodeService $codes,
        private readonly ClientSessionService $sessions,
    ) {}

    /** POST public/portal/{workspaceSlug}/{brandSlug}/code */
    public function requestCode(Request $request, string $workspaceSlug, string $brandSlug): JsonResponse
    {
        $validated = $request->validate(['email' => ['required', 'string', 'email', 'max:254']]);

        $brand = $this->lanes->portalBrand($workspaceSlug, $brandSlug);
        if ($brand !== null) {
            $this->codes->requestForBrand($validated['email'], $brand);
        }

        return response()
            ->json(['message' => 'If that address can open this portal, a code is on its way.'], 202)
            ->header('Cache-Control', 'no-store');
    }

    /** POST public/portal/{workspaceSlug}/{brandSlug}/code/verify */
    public function verifyCode(Request $request, string $workspaceSlug, string $brandSlug): JsonResponse
    {
        $validated = $request->validate([
            'email' => ['required', 'string', 'email', 'max:254'],
            'code' => ['required', 'string', 'regex:/^\d{6}$/'],
        ]);

        try {
            $brand = $this->lanes->portalBrand($workspaceSlug, $brandSlug);
            if ($brand === null) {
                throw new VerificationCodeExpiredException;
            }
            $user = $this->codes->verifyForBrand($validated['email'], $validated['code'], $brand);
        } catch (InvalidVerificationCodeException $e) {
            return response()
                ->json(['code' => InvalidVerificationCodeException::CODE, 'message' => $e->getMessage(), 'attempts_left' => $e->attemptsLeft], 422)
                ->header('Cache-Control', 'no-store');
        } catch (VerificationCodeExpiredException $e) {
            return response()
                ->json(['code' => VerificationCodeExpiredException::CODE, 'message' => $e->getMessage()], 422)
                ->header('Cache-Control', 'no-store');
        }

        [$session, $token] = $this->sessions->issue($user, ClientSession::VIA_CODE, $request);

        return response()
            ->json(['data' => ['session_token' => $token, 'expires_at' => $session->expires_at?->toISOString()]])
            ->header('Cache-Control', 'no-store');
    }
}
```

- [ ] **Step 5: Limiters and routes**

`app/Providers/AppServiceProvider.php`, after the `public-client-session` limiter:

```php
        // Portal sign-in codes (client portal §5.3, PR15). The bucket that
        // matters is per (address, brand): the web BFF proxies these calls,
        // so "per IP" sees the BFF. Same posture as `public-lane-code`.
        RateLimiter::for('public-portal-code', function (Request $request) use ($tooManyAttemptsResponse) {
            $email = strtolower(trim((string) $request->input('email', '')));
            $brand = (string) $request->route('workspaceSlug').'/'.(string) $request->route('brandSlug');

            return [
                Limit::perMinute(10)->by('ppc-ip|'.$request->ip())->response($tooManyAttemptsResponse),
                Limit::perHour(5)->by('ppc-email|'.sha1($email.'|'.$brand))->response($tooManyAttemptsResponse),
            ];
        });

        RateLimiter::for('public-portal-code-verify', function (Request $request) use ($tooManyAttemptsResponse) {
            $email = strtolower(trim((string) $request->input('email', '')));
            $brand = (string) $request->route('workspaceSlug').'/'.(string) $request->route('brandSlug');

            return [
                Limit::perMinute(10)->by('ppcv-ip|'.$request->ip())->response($tooManyAttemptsResponse),
                Limit::perHour(20)->by('ppcv-email|'.sha1($email.'|'.$brand))->response($tooManyAttemptsResponse),
            ];
        });
```

`routes/api.php` — add `use App\Http\Controllers\Api\ClientPortal\PortalSignInController;` with the imports, and after the `public/client/session` route:

```php
Route::post('public/portal/{workspaceSlug}/{brandSlug}/code', [PortalSignInController::class, 'requestCode'])
    ->middleware('throttle:public-portal-code')
    ->name('public.portal.code');
Route::post('public/portal/{workspaceSlug}/{brandSlug}/code/verify', [PortalSignInController::class, 'verifyCode'])
    ->middleware('throttle:public-portal-code-verify')
    ->name('public.portal.code.verify');
```

- [ ] **Step 6: Run the tests to verify they pass, plus the link-code paths**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/ClientPortal/ClientSessionTest.php tests/Feature/Approval/DeckPlanRequestFlowTest.php tests/Unit/Mail/ClientVerificationCodeMailTest.php --compact
```

Expected: ClientSessionTest 10 passed; the other two as in the baseline. If the throttle test's arithmetic differs (e.g. the 429 lands one request earlier or later), print `RateLimiter::attempts('ppc-ip|127.0.0.1')` around it, confirm how `ThrottleRequests` counts multi-limit hits in this Laravel version, and correct the counts — the behaviour under test (a per-(address, brand) cap at 5 and a per-IP cap at 10) must stay.

- [ ] **Step 7: Mutation check**
  - In `requestForBrand()` drop the `activeLane(...) === null` check → "a portal code request answers the same 202…" fails (`assertNothingQueued`).
  - Drop `->whereNull('share_link_id')` from `verifyForBrand()` → "a portal code verifies…" fails (the link code `111111` signs in).
  - Remove the post-spend `activeLane` re-check → the same test fails at the last 422 (a second session).
  - Remove the `Limit::perHour(5)` line → "portal code requests are throttled…" fails (6th is 202).
  Restore; re-run green.

- [ ] **Step 8: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && for f in app/Services/ClientLane/ClientVerificationCodeService.php app/Http/Controllers/Api/ClientPortal/PortalSignInController.php app/Providers/AppServiceProvider.php routes/api.php tests/Feature/ClientPortal/ClientSessionTest.php; do php -l "$f" || exit 1; done && vendor/bin/pint app/Services/ClientLane/ClientVerificationCodeService.php app/Http/Controllers/Api/ClientPortal/PortalSignInController.php tests/Feature/ClientPortal/ClientSessionTest.php && vendor/bin/pint --test app/Services/ClientLane/ClientVerificationCodeService.php app/Http/Controllers/Api/ClientPortal/PortalSignInController.php tests/Feature/ClientPortal/ClientSessionTest.php
/usr/bin/git add app/Services/ClientLane/ClientVerificationCodeService.php app/Http/Controllers/Api/ClientPortal/PortalSignInController.php app/Providers/AppServiceProvider.php routes/api.php tests/Feature/ClientPortal/ClientSessionTest.php
/usr/bin/git commit -m "feat(api): sign in to the client portal with a code, enumeration-safe and throttled"
```

---

### Task 8: Agency Clients endpoints — list, access level, portal link, remove

**Files:**
- Create: `app/Services/ClientLane/BrandClients.php`
- Create: `app/Http/Controllers/Api/Brand/BrandClientController.php`
- Modify: `app/Services/ClientLane/ClientLaneService.php` (`portalUrl`)
- Modify: `routes/api.php` (four routes in the `brands` group)
- Modify: `tests/Support/ClientLaneFixtures.php` (`actAsAgency` takes an allow rule)
- Test: `tests/Feature/ClientPortal/AgencyClientsTest.php` (created here)

**Interfaces:**
- Consumes: Task 2 (`UserBrandRole::deleted` revokes; `mintLaneLink` existing); Task 1 fixtures.
- Produces:
  - `BrandClients::ADDED_FROM` (`kv_file`/`deck`/`campaign` → label), `isClient(Brand, User): bool`, `rows(Brand, ?string $onlyUserId = null): list<array>` (ClientRow), `setAccessLevel(Brand, User, string $level): ClientLaneLink`, `remove(Brand, User): void`.
  - `ClientLaneService::portalUrl(Brand $brand, ClientLaneLink $lane): string` — absolute `…/s/{ws}/{brand}?k={code}`.
  - Routes `brands.clients.index|update|portal-link|destroy`.
  - `ClientLaneFixtures::actAsAgency(TestCase $test, User $user, bool|\Closure $allow = true)` — `false` denies every gate; a `Closure(string $ability): bool` decides per ability. Existing two-argument calls are unchanged.

- [ ] **Step 1: Write the failing tests** — create `tests/Feature/ClientPortal/AgencyClientsTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Http\Middleware\CheckPermissions;
use App\Jobs\SendApprovalRequestDigest;
use App\Models\BrandRole;
use App\Models\ClientLaneLink;
use App\Models\User;
use App\Models\UserBrandRole;
use App\Services\Approval\ApprovalRequestService;
use Illuminate\Support\Facades\Bus;
use Illuminate\Support\Facades\Mail;
use Tests\Support\ClientLaneFixtures;

/**
 * Client portal (spec 2026-10-06 §7.1, §7.3): the agency's Clients tab and
 * approver suggestions. `permissions:` is stripped (and its wiring asserted
 * on the routes); the controller's workspace and client checks run.
 */
beforeEach(function () {
    Mail::fake();
    Bus::fake([SendApprovalRequestDigest::class]);
    config(['app.frontend_url' => 'https://app.frndos.test']);

    $this->f = ClientLaneFixtures::deck();
    $this->dina = ClientLaneFixtures::namedClient($this->f['brand'], 'dina@brand.test', 'Dina Pratiwi');
    app(ApprovalRequestService::class)->create($this->f['deck'], $this->f['user'], null, ['dina@brand.test'], null, null, notify: false);
    $this->andi = ClientLaneFixtures::namedClient($this->f['brand'], 'andi@brand.test', 'Andi Wijaya');

    // An internal brand member — never a client row.
    $viewer = BrandRole::withoutGlobalScopes()->create([
        'workspace_id' => $this->f['workspace']->id, 'name' => 'Viewer', 'slug' => 'viewer',
        'is_locked' => false, 'is_default' => false, 'scope' => BrandRole::SCOPE_INTERNAL,
    ]);
    UserBrandRole::query()->create([
        'user_id' => User::factory()->create()->id, 'brand_id' => $this->f['brand']->id,
        'brand_role_id' => $viewer->id, 'workspace_id' => $this->f['workspace']->id,
    ]);

    $this->base = "/api/v1/brands/{$this->f['brand']->id}/clients";
    $this->login = function (bool|Closure $allow = true): void {
        ClientLaneFixtures::actAsAgency($this, $this->f['user'], $allow);
        $this->withoutMiddleware([CheckPermissions::class]);
    };
});

test("the Clients tab lists the brand's clients only, with access level, origin and status", function () {
    ($this->login)();
    $this->dina['lane']->forceFill(['last_used_at' => now()->subHours(2)])->save();

    $rows = collect($this->getJson($this->base)->assertOk()->json('data'))->keyBy('user.email');

    expect($rows->keys()->all())->toEqualCanonicalizing(['dina@brand.test', 'andi@brand.test'])
        ->and($rows['dina@brand.test']['user'])->toBe(['id' => $this->dina['user']->id, 'name' => 'Dina Pratiwi', 'email' => 'dina@brand.test'])
        ->and($rows['dina@brand.test'])->toMatchArray(['access_level' => 'own', 'added_from' => 'Deck approval request', 'status' => 'active'])
        ->and($rows['dina@brand.test']['last_opened_at'])->not->toBeNull()
        ->and($rows['dina@brand.test']['added_at'])->not->toBeNull()
        ->and($rows['andi@brand.test'])->toMatchArray(['added_from' => null, 'last_opened_at' => null, 'status' => 'not_opened']);
});

test('PATCH sets the access level on the active lane; a bad level is 422 and a non-client 404', function () {
    ($this->login)();

    $this->patchJson("{$this->base}/{$this->dina['user']->id}", ['access_level' => 'all_view'])
        ->assertOk()
        ->assertJsonPath('data.access_level', 'all_view')
        ->assertJsonPath('data.user.email', 'dina@brand.test');
    expect($this->dina['lane']->fresh()->access_level)->toBe('all_view');

    $this->patchJson("{$this->base}/{$this->dina['user']->id}", ['access_level' => 'admin'])->assertStatus(422);
    $this->patchJson("{$this->base}/".User::factory()->create()->id, ['access_level' => 'own'])->assertNotFound();
});

test('the portal link reuses the existing code, never rotating it', function () {
    ($this->login)();
    $expected = "https://app.frndos.test/s/{$this->f['workspace']->slug}/{$this->f['brand']->slug}?k={$this->dina['lane']->unique_code}";

    $this->postJson("{$this->base}/{$this->dina['user']->id}/portal-link")->assertOk()->assertExactJson(['data' => ['url' => $expected]]);
    $this->postJson("{$this->base}/{$this->dina['user']->id}/portal-link")->assertOk()->assertJsonPath('data.url', $expected);

    expect(ClientLaneLink::query()->where('user_id', $this->dina['user']->id)->count())->toBe(1)
        ->and($this->dina['lane']->fresh()->revoked_at)->toBeNull();
});

test('DELETE removes the client role and revokes the lane', function () {
    ($this->login)();

    $this->deleteJson("{$this->base}/{$this->dina['user']->id}")->assertNoContent();

    expect(UserBrandRole::query()->where('user_id', $this->dina['user']->id)->exists())->toBeFalse()
        ->and($this->dina['lane']->fresh()->revoked_at)->not->toBeNull();
    expect(collect($this->getJson($this->base)->assertOk()->json('data'))->pluck('user.email')->all())->toBe(['andi@brand.test']);
    $this->deleteJson("{$this->base}/{$this->dina['user']->id}")->assertNotFound();
});

test("another workspace's brand is a 404 and the routes carry the Members page permissions", function () {
    ($this->login)();
    $other = ClientLaneFixtures::deck();
    $this->getJson("/api/v1/brands/{$other['brand']->id}/clients")->assertNotFound();

    $routes = app('router')->getRoutes();
    expect($routes->getByName('brands.clients.index')->gatherMiddleware())->toContain('permissions:brand.settings.read');
    foreach (['brands.clients.update', 'brands.clients.portal-link', 'brands.clients.destroy'] as $name) {
        expect($routes->getByName($name)->gatherMiddleware())->toContain('permissions:brand.settings.write');
    }
});
```

and extend `ClientLaneFixtures::actAsAgency()` (same file `tests/Support/ClientLaneFixtures.php`) with an allow switch — replace its signature and the `Gate::before` line:

```php
    /** @param  bool|\Closure(string): bool  $allow  every gate, or a per-ability rule (authorisation tests) */
    public static function actAsAgency(TestCase $test, User $user, bool|\Closure $allow = true): void
    {
        $test->withoutMiddleware([
            CheckRoleScope::class,
            EnsureWorkspaceContext::class,
            RequestContextMiddleware::class,
            FeatureFlag::class,
        ]);
        Gate::before(static fn ($actor, string $ability): bool => is_bool($allow) ? $allow : $allow($ability));
        $test->actingAs($user, 'api');
    }
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/ClientPortal/AgencyClientsTest.php --compact
```

Expected: FAIL — no `clients` routes (404s) and `getByName('brands.clients.index')` is null.

- [ ] **Step 3: `ClientLaneService::portalUrl()`** — after `personalUrl()`:

```php
    /**
     * The client's personal link to the brand portal (client portal §7.1):
     * `/s/{workspace slug}/{brand slug}?k={code}`, absolute like every URL
     * the agency copies (ruling PR17).
     */
    public function portalUrl(Brand $brand, ClientLaneLink $lane): string
    {
        $workspaceSlug = (string) Workspace::query()->whereKey($brand->workspace_id)->value('slug');

        return sprintf(
            '%s/s/%s/%s?k=%s',
            rtrim((string) config('app.frontend_url'), '/'),
            $workspaceSlug,
            $brand->slug,
            $lane->unique_code,
        );
    }
```

- [ ] **Step 4: `app/Services/ClientLane/BrandClients.php`**

```php
<?php

declare(strict_types=1);

namespace App\Services\ClientLane;

// craftsman-ignore: PHP002 — resolved from the container and swapped in tests.

use App\Models\ApprovalRequest;
use App\Models\Brand;
use App\Models\BrandRole;
use App\Models\ClientLaneLink;
use App\Models\User;
use App\Models\UserBrandRole;
use Illuminate\Database\Eloquent\Builder;

/**
 * A brand's clients as the agency manages them (client portal spec
 * 2026-10-06 §7.1, rulings PR18, PR21): every holder of the brand's locked
 * `client` role, with the access level of their active personal lane.
 */
class BrandClients
{
    /** Where a client first came from (spec §7.1 `added_from`). */
    public const ADDED_FROM = [
        'kv_file' => 'KV approval request',
        'deck' => 'Deck approval request',
        'campaign' => 'Plan approval request',
    ];

    public function __construct(private readonly ClientLaneService $lanes) {}

    public function isClient(Brand $brand, User $user): bool
    {
        return $this->roleRows($brand)->where('user_brand_roles.user_id', $user->id)->exists();
    }

    /**
     * ClientRow per client (oldest first), or just one.
     *
     * @return list<array{user: array{id: string, name: string, email: string}, access_level: string, added_at: string|null, added_from: string|null, last_opened_at: string|null, status: string}>
     */
    public function rows(Brand $brand, ?string $onlyUserId = null): array
    {
        $query = $this->roleRows($brand)
            ->with('user:id,name,email')
            ->orderBy('user_brand_roles.created_at')
            ->orderBy('user_brand_roles.id');
        if ($onlyUserId !== null) {
            $query->where('user_brand_roles.user_id', $onlyUserId);
        }
        $roles = $query->get();

        $userIds = $roles->map(static fn (UserBrandRole $role): string => (string) $role->user_id)->all();
        $lanes = ClientLaneLink::query()
            ->where('brand_id', $brand->id)
            ->where('kind', ClientLaneLink::KIND_PERSONAL)
            ->whereIn('user_id', $userIds)
            ->get()
            ->groupBy(static fn (ClientLaneLink $lane): string => (string) $lane->user_id);
        $origins = $this->origins($brand, $userIds);

        return $roles->map(static function (UserBrandRole $role) use ($lanes, $origins): array {
            $userId = (string) $role->user_id;
            $userLanes = $lanes->get($userId, collect());
            $active = $userLanes->first(static fn (ClientLaneLink $lane): bool => $lane->isActive());
            $lastOpened = $userLanes->pluck('last_used_at')->filter()->max();

            return [
                'user' => ['id' => $userId, 'name' => (string) $role->user?->name, 'email' => (string) $role->user?->email],
                'access_level' => $active?->access_level ?? ClientLaneLink::ACCESS_OWN,
                'added_at' => $role->created_at?->toISOString(),
                'added_from' => $origins[$userId] ?? null,
                'last_opened_at' => $lastOpened?->toISOString(),
                'status' => $lastOpened !== null ? 'active' : 'not_opened',
            ];
        })->values()->all();
    }

    /** The access level lives on the active personal lane — minted when there is none (PR18). */
    public function setAccessLevel(Brand $brand, User $user, string $level): ClientLaneLink
    {
        $lane = $this->lanes->mintLaneLink($brand, $user);
        $lane->forceFill(['access_level' => $level])->save();

        return $lane;
    }

    /** Remove the client role — per model, so UserBrandRole::deleted revokes the lane (§4.2). */
    public function remove(Brand $brand, User $user): void
    {
        $this->roleRows($brand)->where('user_brand_roles.user_id', $user->id)->get()->each->delete();
    }

    /** @return Builder<UserBrandRole> */
    private function roleRows(Brand $brand): Builder
    {
        return UserBrandRole::query()
            ->join('brand_roles', 'brand_roles.id', '=', 'user_brand_roles.brand_role_id')
            ->where('user_brand_roles.brand_id', $brand->id)
            ->where('brand_roles.slug', BrandRole::CLIENT_SLUG)
            ->where('brand_roles.scope', BrandRole::SCOPE_EXTERNAL)
            ->select('user_brand_roles.*');
    }

    /**
     * The subject type of the oldest request on the brand naming each client (PR21).
     *
     * @param  list<string>  $userIds
     * @return array<string, string>
     */
    private function origins(Brand $brand, array $userIds): array
    {
        $out = [];
        $requests = ApprovalRequest::query()
            ->where('brand_id', $brand->id)
            ->orderBy('created_at')
            ->orderBy('id')
            ->get(['id', 'approvers', 'subject_type']);
        foreach ($requests as $request) {
            foreach ($request->approverUserIds() as $id) {
                if (! isset($out[$id]) && in_array($id, $userIds, true) && isset(self::ADDED_FROM[$request->subject_type])) {
                    $out[$id] = self::ADDED_FROM[$request->subject_type];
                }
            }
        }

        return $out;
    }
}
```

- [ ] **Step 5: `app/Http/Controllers/Api/Brand/BrandClientController.php`**

```php
<?php

declare(strict_types=1);

namespace App\Http\Controllers\Api\Brand;

// craftsman-ignore: PHP002 — controllers are not final in this codebase.

use App\Http\Controllers\Controller;
use App\Models\Brand;
use App\Models\ClientLaneLink;
use App\Models\User;
use App\Services\BrandRole\BrandRoleCacheInvalidator;
use App\Services\ClientLane\BrandClients;
use App\Services\ClientLane\ClientLaneService;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Http\Response;
use Illuminate\Validation\Rule;

/**
 * Brand Settings → Members → Clients (client portal spec 2026-10-06 §7.1).
 * `permissions:brand.settings.read|write` on the routes; here the brand
 * must sit in the caller's workspace (404 otherwise — the same carve-out
 * for superadmins as BrandClientLaneLinkController::rotate) and `{user}`
 * must hold the brand's client role (404 otherwise).
 */
class BrandClientController extends Controller
{
    public function __construct(
        private readonly BrandClients $clients,
        private readonly ClientLaneService $lanes,
    ) {}

    /** GET v1/brands/{brand}/clients */
    public function index(Request $request, Brand $brand): JsonResponse
    {
        $this->inWorkspace($request, $brand);

        return response()->json(['data' => $this->clients->rows($brand)]);
    }

    /** PATCH v1/brands/{brand}/clients/{user} {access_level} */
    public function update(Request $request, Brand $brand, User $user): JsonResponse
    {
        $this->inWorkspace($request, $brand);
        $validated = $request->validate([
            'access_level' => ['required', 'string', Rule::in(ClientLaneLink::ACCESS_LEVELS)],
        ]);
        $this->clientOr404($brand, $user);

        $this->clients->setAccessLevel($brand, $user, $validated['access_level']);

        return response()->json(['data' => $this->clients->rows($brand, (string) $user->id)[0]]);
    }

    /** POST v1/brands/{brand}/clients/{user}/portal-link — the existing code, never rotated. */
    public function portalLink(Request $request, Brand $brand, User $user): JsonResponse
    {
        $this->inWorkspace($request, $brand);
        $this->clientOr404($brand, $user);

        $lane = $this->lanes->mintLaneLink($brand, $user, $request->user());

        return response()->json(['data' => ['url' => $this->lanes->portalUrl($brand, $lane)]]);
    }

    /** DELETE v1/brands/{brand}/clients/{user} — "Remove access"; decisions stay on record. */
    public function destroy(Request $request, Brand $brand, User $user, BrandRoleCacheInvalidator $invalidator): Response
    {
        $this->inWorkspace($request, $brand);
        $this->clientOr404($brand, $user);

        $this->clients->remove($brand, $user);
        $invalidator->forgetForUsers([(string) $user->id], (string) $brand->workspace_id);

        return response()->noContent();
    }

    private function inWorkspace(Request $request, Brand $brand): void
    {
        $actor = $request->user();
        abort_if(
            ! $actor?->isSuperadmin() && (string) $brand->workspace_id !== (string) $actor?->current_workspace_id,
            404,
        );
    }

    private function clientOr404(Brand $brand, User $user): void
    {
        abort_unless($this->clients->isClient($brand, $user), 404);
    }
}
```

- [ ] **Step 6: Routes** — `routes/api.php`: add `use App\Http\Controllers\Api\Brand\BrandClientController;` with the imports, and in the `brands` group directly after

```php
                    Route::delete('{brand}/members/{user}', [BrandMemberController::class, 'destroy'])
                        ->middleware('permissions:brand.settings.write');
```

add

```php

                    // ---- Client portal: the Clients tab (spec 2026-10-06 §7.1) ----
                    Route::get('{brand}/clients', [BrandClientController::class, 'index'])
                        ->middleware('permissions:brand.settings.read')
                        ->name('brands.clients.index');
                    Route::patch('{brand}/clients/{user}', [BrandClientController::class, 'update'])
                        ->middleware('permissions:brand.settings.write')
                        ->name('brands.clients.update');
                    Route::post('{brand}/clients/{user}/portal-link', [BrandClientController::class, 'portalLink'])
                        ->middleware('permissions:brand.settings.write')
                        ->name('brands.clients.portal-link');
                    Route::delete('{brand}/clients/{user}', [BrandClientController::class, 'destroy'])
                        ->middleware('permissions:brand.settings.write')
                        ->name('brands.clients.destroy');
```

- [ ] **Step 7: Run the tests to verify they pass**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/ClientPortal/AgencyClientsTest.php tests/Feature/Approval/KvRequestCharacterizationTest.php --compact
```

Expected: AgencyClientsTest 5 passed; the characterization test green (the `actAsAgency` change is default-compatible).

- [ ] **Step 8: Mutation check**
  - Drop `->where('brand_roles.slug', BrandRole::CLIENT_SLUG)` in `roleRows()` → "the Clients tab lists…" fails (the internal member appears).
  - In `remove()` use `UserBrandRole::query()->where(...)->delete()` (mass) → "DELETE removes…" fails at `revoked_at`.
  - In `portalLink()` call `$this->lanes->rotate(...)` → "the portal link reuses…" fails (two lanes, code changed).
  - Change `index`'s route middleware to `permissions:brand.settings.write` → the last test fails.
  Restore; re-run green.

- [ ] **Step 9: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && for f in app/Services/ClientLane/BrandClients.php app/Http/Controllers/Api/Brand/BrandClientController.php app/Services/ClientLane/ClientLaneService.php routes/api.php tests/Support/ClientLaneFixtures.php tests/Feature/ClientPortal/AgencyClientsTest.php; do php -l "$f" || exit 1; done && vendor/bin/pint app/Services/ClientLane/BrandClients.php app/Http/Controllers/Api/Brand/BrandClientController.php app/Services/ClientLane/ClientLaneService.php tests/Support/ClientLaneFixtures.php tests/Feature/ClientPortal/AgencyClientsTest.php && vendor/bin/pint --test app/Services/ClientLane/BrandClients.php app/Http/Controllers/Api/Brand/BrandClientController.php app/Services/ClientLane/ClientLaneService.php tests/Support/ClientLaneFixtures.php tests/Feature/ClientPortal/AgencyClientsTest.php
/usr/bin/git add app/Services/ClientLane/BrandClients.php app/Http/Controllers/Api/Brand/BrandClientController.php app/Services/ClientLane/ClientLaneService.php routes/api.php tests/Support/ClientLaneFixtures.php tests/Feature/ClientPortal/AgencyClientsTest.php
/usr/bin/git commit -m "feat(api): the agency's Clients endpoints — access level, portal link, remove"
```

---
### Task 9: Approver suggestions for Request approval (bug 2, api side)

**Files:**
- Modify: `app/Http/Controllers/Api/Approval/ApprovalRequestController.php` (`approverSuggestions`)
- Modify: `routes/api.php` (`GET v1/approval-requests/approver-suggestions`)
- Test: `tests/Feature/ClientPortal/AgencyClientsTest.php`

**Interfaces:**
- Consumes: Task 8 `BrandClients::rows()`; the controller's existing private `subject(Request, string $type, string $id, bool $write): ApprovalSubject` and `subjectRules()`.
- Produces: `GET v1/approval-requests/approver-suggestions` (name `approval-requests.approver-suggestions`) → `{data: [{name, email, access_level}]}`.

- [ ] **Step 1: Write the failing tests** (append to `tests/Feature/ClientPortal/AgencyClientsTest.php`)

```php
test("approver suggestions list the clients of the subject's brand with their access level", function () {
    ($this->login)();
    $this->dina['lane']->forceFill(['access_level' => 'all_view'])->save();
    $query = http_build_query(['subject_type' => 'deck', 'subject_id' => $this->f['deck']->id]);

    $this->getJson("/api/v1/approval-requests/approver-suggestions?{$query}")
        ->assertOk()
        ->assertExactJson(['data' => [
            ['name' => 'Andi Wijaya', 'email' => 'andi@brand.test', 'access_level' => 'own'],
            ['name' => 'Dina Pratiwi', 'email' => 'dina@brand.test', 'access_level' => 'all_view'],
        ]]);

    $this->getJson('/api/v1/approval-requests/approver-suggestions?subject_type=deck')->assertStatus(422);
});

test('approver suggestions use the send authorisation: 404 outside the workspace, 403 without request permission', function () {
    // Every gate allows except `share` — the deck's REQUEST permission
    // (ApprovalPolicy::mayRequestOn); `view` (mayRead) stays allowed, so a
    // read-level check would wrongly answer 200.
    ($this->login)(fn (string $ability): bool => $ability !== 'share');
    $other = ClientLaneFixtures::deck();
    $query = fn ($deck): string => http_build_query(['subject_type' => 'deck', 'subject_id' => $deck->id]);

    $this->getJson("/api/v1/approval-requests/approver-suggestions?{$query($other['deck'])}")->assertNotFound();
    $this->getJson("/api/v1/approval-requests/approver-suggestions?{$query($this->f['deck'])}")->assertForbidden();
});
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/ClientPortal/AgencyClientsTest.php --compact
```

Expected: the 5 Task 8 tests pass; the 2 new ones FAIL (no route).

- [ ] **Step 3: The endpoint** — `app/Http/Controllers/Api/Approval/ApprovalRequestController.php`: add `use App\Services\ClientLane\BrandClients;` and, after `preview()`:

```php
    /**
     * GET v1/approval-requests/approver-suggestions?subject_type=&subject_id=
     * (client portal spec §7.3, the api half of bug 2): the clients of the
     * subject's brand for the Request-approval picker. Same authorisation
     * as SENDING a request — `GET brands/{id}/members` excludes clients and
     * needs settings permission, which is why the picker never showed them.
     */
    public function approverSuggestions(Request $request, BrandClients $clients): JsonResponse
    {
        $validated = $request->validate(self::subjectRules());
        $subject = $this->subject($request, $validated['subject_type'], $validated['subject_id'], write: true);

        $brand = $subject->brand();
        if ($brand === null) {
            return response()->json(['data' => []]);
        }

        $suggestions = array_map(static fn (array $row): array => [
            'name' => $row['user']['name'],
            'email' => $row['user']['email'],
            'access_level' => $row['access_level'],
        ], $clients->rows($brand));
        usort($suggestions, static fn (array $a, array $b): int => strcasecmp($a['name'], $b['name']));

        return response()->json(['data' => $suggestions]);
    }
```

- [ ] **Step 4: Route** — in `routes/api.php`, in the `approval-requests` prefix group, after `Route::get('preview', …)->name('approval-requests.preview');`:

```php
                // Client portal §7.3: the picker's clients, send authorisation.
                Route::get('approver-suggestions', [ApprovalRequestController::class, 'approverSuggestions'])->name('approval-requests.approver-suggestions');
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/ClientPortal/AgencyClientsTest.php --compact
```

Expected: PASS (7 tests).

- [ ] **Step 6: Mutation check**
  - Replace the `$this->subject(...)` call with `ApprovalSubject::find(...)` (no workspace/policy check) → the authorisation test fails twice (200s).
  - Pass `write: false` instead of `true` (read-level check) → the authorisation test fails at `assertForbidden` (deck `view` is allowed, `share` is not).
  - Drop the `usort` → the first test fails (`assertExactJson` order: Dina was added first).
  Restore; re-run green.

- [ ] **Step 7: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && for f in app/Http/Controllers/Api/Approval/ApprovalRequestController.php routes/api.php tests/Feature/ClientPortal/AgencyClientsTest.php; do php -l "$f" || exit 1; done && vendor/bin/pint app/Http/Controllers/Api/Approval/ApprovalRequestController.php tests/Feature/ClientPortal/AgencyClientsTest.php && vendor/bin/pint --test app/Http/Controllers/Api/Approval/ApprovalRequestController.php tests/Feature/ClientPortal/AgencyClientsTest.php
/usr/bin/git add app/Http/Controllers/Api/Approval/ApprovalRequestController.php routes/api.php tests/Feature/ClientPortal/AgencyClientsTest.php
/usr/bin/git commit -m "fix(api): approver suggestions list the brand's clients under the send permission"
```

---

### Task 10: Reserved workspace slugs (`session`, `verify`, `api`)

**Files:**
- Modify: `app/Models/Workspace.php` (`RESERVED_SLUGS`, generator skip, create/update guard)
- Create: `database/migrations/2026_10_06_200600_refuse_reserved_workspace_slugs.php`
- Test: `tests/Feature/ClientPortal/ReservedWorkspaceSlugTest.php` (created here)

**Interfaces:**
- Consumes: nothing new.
- Produces: `Workspace::RESERVED_SLUGS = ['session', 'verify', 'api']`; `Workspace::generateUniqueSlug()` never returns a reserved slug; creating or updating a workspace to a reserved slug throws `Illuminate\Validation\ValidationException` (`errors.slug`).

- [ ] **Step 1: Write the failing tests** — create `tests/Feature/ClientPortal/ReservedWorkspaceSlugTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Models\Workspace;
use Illuminate\Support\Facades\DB;
use Illuminate\Validation\ValidationException;

/**
 * Client portal (spec 2026-10-06 §4.1, P-4, ruling PR13): `/s/session`,
 * `/s/verify/*` and `/s/api/*` are static web routes beside the portal's
 * `/s/{workspace}/{brand}`, so no workspace may own those slugs.
 */
test('a workspace named like a reserved /s route gets a suffixed slug', function () {
    foreach (['Session' => 'session-2', 'Verify' => 'verify-2', 'API' => 'api-2'] as $name => $slug) {
        expect(Workspace::factory()->create(['name' => $name])->slug)->toBe($slug);
    }
});

test('an explicit reserved slug is refused on create and on update', function () {
    expect(fn () => Workspace::factory()->create(['slug' => 'verify']))->toThrow(ValidationException::class);

    $workspace = Workspace::factory()->create(['name' => 'Kopi Agency']);
    expect(fn () => $workspace->update(['slug' => 'Session']))->toThrow(ValidationException::class)
        ->and($workspace->fresh()->slug)->toBe('kopi-agency');
});

test('the migration fails loudly, naming a workspace that already holds a reserved slug', function () {
    $workspace = Workspace::factory()->create(['name' => 'Legacy API Team']);
    DB::table('workspaces')->where('id', $workspace->id)->update(['slug' => 'api']); // as an old row would be

    $migration = require base_path('database/migrations/2026_10_06_200600_refuse_reserved_workspace_slugs.php');
    try {
        $migration->up();
        $this->fail('The migration should refuse a reserved slug.');
    } catch (RuntimeException $e) {
        expect($e->getMessage())->toContain('Legacy API Team')->toContain('"api"')->toContain((string) $workspace->id);
    }
});
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/ClientPortal/ReservedWorkspaceSlugTest.php --compact
```

Expected: FAIL — the first test gets `session` (not `session-2`); the second throws nothing; the third: `Failed opening required …200600…` (no migration yet).

- [ ] **Step 3: The model** — `app/Models/Workspace.php`: add `use Illuminate\Validation\ValidationException;`. Replace `booted()` and the start of `generateUniqueSlug()`:

```php
    /**
     * Client portal (spec 2026-10-06 P-4): static web routes beside the
     * portal's `/s/{workspace}/{brand}` — no workspace may own these.
     *
     * @var list<string>
     */
    public const RESERVED_SLUGS = ['session', 'verify', 'api'];

    protected static function booted(): void
    {
        static::creating(function (self $workspace) {
            if (empty($workspace->slug)) {
                $workspace->slug = self::generateUniqueSlug((string) $workspace->name);
            }
            self::refuseReservedSlug($workspace);
        });

        static::updating(function (self $workspace) {
            if ($workspace->isDirty('slug')) {
                self::refuseReservedSlug($workspace);
            }
        });
    }

    public static function generateUniqueSlug(string $name): string
    {
        $base = Str::slug($name) ?: 'workspace';

        $taken = static::query()
            ->where('slug', $base)
            ->orWhere('slug', 'like', $base.'-%')
            ->pluck('slug')
            ->all();

        if (! in_array($base, $taken, true) && ! in_array($base, self::RESERVED_SLUGS, true)) {
            return $base;
        }
```

(the rest of `generateUniqueSlug()` — the `$suffix` loop — is unchanged). Add after `generateUniqueSlug()`:

```php
    /** Workspace slugs are never typed by a user (PR13): this guards every explicit write. */
    private static function refuseReservedSlug(self $workspace): void
    {
        $slug = strtolower((string) $workspace->slug);
        if (in_array($slug, self::RESERVED_SLUGS, true)) {
            throw ValidationException::withMessages(['slug' => "The workspace address \"{$slug}\" is reserved."]);
        }
    }
```

- [ ] **Step 4: The migration** — `database/migrations/2026_10_06_200600_refuse_reserved_workspace_slugs.php`:

```php
<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Support\Facades\DB;

/**
 * Client portal (spec 2026-10-06 §4.1, P-4): `/s/session`, `/s/verify/*`
 * and `/s/api/*` are static web routes beside the portal's
 * `/s/{workspace}/{brand}`. New workspaces can no longer take those slugs
 * (Workspace::RESERVED_SLUGS); this fails LOUDLY when an existing one
 * already does, naming it, so a human renames it before the portal ships.
 * Nothing is renamed automatically: a slug may be in links already sent.
 */
return new class extends Migration
{
    /** Literal on purpose: a migration must not move when the model's constant does. */
    private const RESERVED = ['session', 'verify', 'api'];

    public function up(): void
    {
        $taken = DB::table('workspaces')
            ->whereIn(DB::raw('LOWER(slug)'), self::RESERVED)
            ->get(['id', 'name', 'slug']);

        if ($taken->isNotEmpty()) {
            throw new RuntimeException(
                'Reserved workspace slugs are in use — rename these workspaces first: '
                .$taken->map(static fn (object $w): string => sprintf('"%s" (slug "%s", id %s)', $w->name, $w->slug, $w->id))->implode('; ')
            );
        }
    }

    public function down(): void
    {
        // Nothing to undo: the migration only checks.
    }
};
```

- [ ] **Step 5: Run the tests to verify they pass, plus workspace creation elsewhere**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/ClientPortal/ReservedWorkspaceSlugTest.php tests/Feature/ClientPortal/ActiveLaneTest.php --compact
```

Expected: ReservedWorkspaceSlugTest 3 passed; ActiveLaneTest still green (its fixtures create workspaces).

- [ ] **Step 6: Mutation check**
  - Drop `&& ! in_array($base, self::RESERVED_SLUGS, true)` → the first test fails (`session`).
  - Remove the `static::updating` hook → the second test fails at the update.
  - Change the migration's `LOWER(slug)` to `slug` and the seeded slug to `API` in a scratch copy of the test — confirm it then passes silently, i.e. the `LOWER` is what catches mixed case. Restore.
  Restore; re-run green.

- [ ] **Step 7: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && for f in app/Models/Workspace.php database/migrations/2026_10_06_200600_refuse_reserved_workspace_slugs.php tests/Feature/ClientPortal/ReservedWorkspaceSlugTest.php; do php -l "$f" || exit 1; done && vendor/bin/pint app/Models/Workspace.php database/migrations/2026_10_06_200600_refuse_reserved_workspace_slugs.php tests/Feature/ClientPortal/ReservedWorkspaceSlugTest.php && vendor/bin/pint --test app/Models/Workspace.php database/migrations/2026_10_06_200600_refuse_reserved_workspace_slugs.php tests/Feature/ClientPortal/ReservedWorkspaceSlugTest.php
/usr/bin/git add app/Models/Workspace.php database/migrations/2026_10_06_200600_refuse_reserved_workspace_slugs.php tests/Feature/ClientPortal/ReservedWorkspaceSlugTest.php
/usr/bin/git commit -m "feat(api): reserve the session, verify and api workspace slugs for /s routes"
```

- [ ] **Step 8: Check the dev data before anyone migrates it** (read-only)

```bash
psql -d frnd -Atc "SELECT id, name, slug FROM workspaces WHERE LOWER(slug) IN ('session','verify','api')"
```

Expected: no rows. If rows print, tell Daffa in the track file: the migration will refuse to run on that DB (and likely on staging/production) until those workspaces are renamed.

---

### Task 11: Retention — purge old client sessions (§10 Q1)

**Files:**
- Create: `app/Console/Commands/PurgeClientSessionsCommand.php`
- Modify: `routes/console.php` (daily schedule)
- Test: `tests/Feature/ClientPortal/ClientSessionTest.php`

**Interfaces:**
- Consumes: Task 1 `ClientSession`, `ApprovalRequestView`, `approval_decisions.client_session_id`.
- Produces: artisan `client-lane:purge-sessions` (`PurgeClientSessionsCommand::RETENTION_DAYS = 30`), scheduled daily.

- [ ] **Step 1: Write the failing test** (append to `tests/Feature/ClientPortal/ClientSessionTest.php`; add imports `use App\Models\ApprovalDecision;`, `use App\Models\ApprovalRequestView;`)

```php
test('the purge deletes sessions 30 days past expiry or revocation, keeps the rest and every view', function () {
    $r = ClientLaneFixtures::sendRequest('deck');
    $user = ClientLaneFixtures::personalLane($r['brand'])->user;
    $make = function (array $attrs) use ($user): ClientSession {
        [$session] = ClientLaneFixtures::session($user);
        $session->forceFill($attrs)->save();

        return $session;
    };

    $live = $make([]);
    $make(['expires_at' => now()->subDays(31)]);
    $make(['revoked_at' => now()->subDays(31)]);
    $recent = $make(['expires_at' => now()->subDays(5)]);
    $audited = $make(['expires_at' => now()->subDays(40)]);
    ApprovalDecision::create([
        'approval_id' => $r['request']->approvals()->value('id'),
        'actor_user_id' => $user->id,
        'outcome' => ApprovalDecision::OUTCOME_APPROVED,
        'advisory' => false,
        'pins' => [],
        'decided_at' => now(),
        'client_session_id' => $audited->id,
    ]);
    ApprovalRequestView::record((string) $r['request']->id, (string) $user->id);

    $this->artisan('client-lane:purge-sessions')->assertSuccessful();

    expect(ClientSession::query()->pluck('id')->all())->toEqualCanonicalizing([$live->id, $recent->id, $audited->id])
        ->and(ApprovalRequestView::query()->count())->toBe(1);
    $this->artisan('schedule:list')->expectsOutputToContain('client-lane:purge-sessions')->assertSuccessful();
});
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/ClientPortal/ClientSessionTest.php --compact
```

Expected: the 10 earlier tests pass; the new one FAILS with `The command "client-lane:purge-sessions" does not exist.`

- [ ] **Step 3: `app/Console/Commands/PurgeClientSessionsCommand.php`**

```php
<?php

declare(strict_types=1);

namespace App\Console\Commands;

use App\Models\ClientSession;
use Illuminate\Console\Command;

/**
 * Client portal retention (spec 2026-10-06 §10 Q1, ruling PR16): a client
 * session is deleted 30 days after it expired or was revoked. A session a
 * decision points at is kept — the approval record reads how that device
 * signed in. Request views are kept with the request.
 */
class PurgeClientSessionsCommand extends Command
{
    public const RETENTION_DAYS = 30;

    protected $signature = 'client-lane:purge-sessions';

    protected $description = 'Delete client sessions 30 days after they expired or were revoked (keeps any a decision points at)';

    public function handle(): int
    {
        $cutoff = now()->subDays(self::RETENTION_DAYS);

        $deleted = ClientSession::query()
            ->where(function ($q) use ($cutoff) {
                $q->where('revoked_at', '<', $cutoff)->orWhere('expires_at', '<', $cutoff);
            })
            ->whereNotExists(function ($q) {
                $q->selectRaw('1')
                    ->from('approval_decisions')
                    ->whereColumn('approval_decisions.client_session_id', 'client_sessions.id');
            })
            ->delete();

        $this->info("Purged {$deleted} client session(s).");

        return self::SUCCESS;
    }
}
```

- [ ] **Step 4: Schedule it** — `routes/console.php`, after the `Schedule::command('cache:prune-expired')…->runInBackground();` block:

```php

// Client portal retention (spec 2026-10-06 §10 Q1): sessions 30 days past
// expiry or revocation. Small, idempotent; daily is plenty.
Schedule::command('client-lane:purge-sessions')
    ->dailyAt('03:10')
    ->timezone('UTC')
    ->withoutOverlapping()
    ->onOneServer();
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/ClientPortal/ClientSessionTest.php --compact
```

Expected: PASS (11 tests).

- [ ] **Step 6: Mutation check** — drop the `whereNotExists` → the test fails (`$audited` deleted); change `RETENTION_DAYS` to `0` → the test fails (`$recent` deleted). Restore; re-run green.

- [ ] **Step 7: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && for f in app/Console/Commands/PurgeClientSessionsCommand.php routes/console.php tests/Feature/ClientPortal/ClientSessionTest.php; do php -l "$f" || exit 1; done && vendor/bin/pint app/Console/Commands/PurgeClientSessionsCommand.php tests/Feature/ClientPortal/ClientSessionTest.php && vendor/bin/pint --test app/Console/Commands/PurgeClientSessionsCommand.php tests/Feature/ClientPortal/ClientSessionTest.php
/usr/bin/git add app/Console/Commands/PurgeClientSessionsCommand.php routes/console.php tests/Feature/ClientPortal/ClientSessionTest.php
/usr/bin/git commit -m "feat(api): purge client sessions 30 days after expiry or revocation"
```

---
### Task 12: Gates, contract notes, track file

**Files:**
- Modify: `docs/prd/client-lane-p0a/api.md` (additive notes inside `## Contract`)
- Create: `docs/tracks/client-portal.track.md`

**Interfaces:**
- Consumes: everything above.
- Produces: a branch ready for Daffa's review — not pushed, no PR.

- [ ] **Step 1: Lint and format every PHP file this plan touched**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && BASE=$(/usr/bin/git reflog show --format=%H feature/daffa/vc-client-portal | tail -1) && /usr/bin/git diff --name-only "$BASE"..HEAD -- '*.php' | tee /tmp/client-portal-php.txt | while read -r f; do php -l "$f" >/dev/null || echo "LINT FAIL $f"; done; vendor/bin/pint --test $(/usr/bin/grep -v -e '^routes/api.php$' -e '^routes/console.php$' -e '^bootstrap/app.php$' -e '^app/Providers/AppServiceProvider.php$' /tmp/client-portal-php.txt)
```

Expected: no `LINT FAIL`; pint `--test` passes. (`BASE` is the branch's oldest reflog entry — the commit it was cut from in Task 0, whichever base Daffa chose.) The four large shared files are excluded from pint on purpose: run `vendor/bin/pint --test routes/api.php routes/console.php bootstrap/app.php app/Providers/AppServiceProvider.php` separately, and if it complains, fix by hand **only** lines this plan added (`/usr/bin/git diff "$BASE"..HEAD -- <file>` shows them) — never reformat the rest.

- [ ] **Step 2: Full run of every named test file (one process)**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest tests/Feature/ClientPortal/ActiveLaneTest.php tests/Feature/ClientPortal/ClientSessionTest.php tests/Feature/ClientPortal/RequestPageSessionTest.php tests/Feature/ClientPortal/PortalInboxTest.php tests/Feature/ClientPortal/AgencyClientsTest.php tests/Feature/ClientPortal/ReservedWorkspaceSlugTest.php tests/Feature/Approval/DeckPlanRequestFlowTest.php tests/Feature/Approval/KvRequestCharacterizationTest.php tests/Feature/Approval/ApprovalRequestDigestTest.php tests/Feature/Approval/KvArtboardThumbnailTest.php tests/Feature/Approval/KvSharePayloadItemsForTest.php tests/Feature/Sharing/ShareLinksRevokedListenerTest.php tests/Unit/Mail/ClientVerificationCodeMailTest.php --compact
```

Expected: the 6 new files all green (ActiveLaneTest 5, ClientSessionTest 11, RequestPageSessionTest 4, PortalInboxTest 6, AgencyClientsTest 7, ReservedWorkspaceSlugTest 3 = 36); the 7 existing files exactly as in the Task 0 baseline — no new failure.

- [ ] **Step 3: Route sanity against the code, not a cache**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && test ! -e bootstrap/cache/routes-v7.php && php artisan route:list --path=portal && php artisan route:list --path=client && php artisan route:list --path=approver-suggestions
```

Expected: `DELETE public/portal/session`, `GET public/portal/me`, `GET public/portal/{workspaceSlug}/{brandSlug}/approvals`, `POST public/portal/{workspaceSlug}/{brandSlug}/code`, `…/code/verify`, `POST public/client/session`, the four `v1/brands/{brand}/clients…` routes and `GET v1/approval-requests/approver-suggestions`.

- [ ] **Step 4: Contract notes** — append the plan's contract and rulings to `docs/prd/client-lane-p0a/api.md`, inside `## Contract` (just before `## Scope`), one heading level down:

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && python3 - <<'EOF'
plan = open('/Users/alva.e202511001/Desktop/work/frndos-agentic/docs/superpowers/plans/2026-10-06-client-portal-api.md').read()
rulings = plan.split('### Rulings (spec ambiguities resolved here; Task 12 writes them into the contract notes)\n', 1)[1].split('\n## API contract for web', 1)[0].strip()
contract = plan.split('## API contract for web\n', 1)[1].split('\n## Global Constraints', 1)[0].strip()
contract = contract.replace('\n### ', '\n#### ')
notes = (
    '### Additive notes (client portal — spec `docs/superpowers/specs/2026-10-06-client-portal-from-share-links-design.md`, 2026-10-06)\n\n'
    'Plan: `docs/superpowers/plans/2026-10-06-client-portal-api.md` (workspace root). Header `X-Client-Session`; the web BFF owns the `frnd_client` cookie.\n\n'
    '#### Rulings\n\n' + rulings + '\n\n' + contract + '\n\n'
)
path = 'docs/prd/client-lane-p0a/api.md'
doc = open(path).read()
assert doc.count('\n## Scope\n') == 1, 'anchor ## Scope not unique'
doc = doc.replace('\n## Scope\n', '\n' + notes + '## Scope\n', 1)
open(path, 'w').write(doc)
EOF
/usr/bin/grep -n "Additive notes (client portal" docs/prd/client-lane-p0a/api.md
```

Expected: one line printed, above `## Scope`. Read the inserted block once: headings `#### Session exchange …` through `#### Agency …`, and every PR1–PR22 ruling present.

- [ ] **Step 5: Track file** — create `docs/tracks/client-portal.track.md`:

```markdown
---
prd: client-portal
parent_prd: docs/superpowers/specs/2026-10-06-client-portal-from-share-links-design.md
service: api
branch: feature/daffa/vc-client-portal
pr_url: null
status: in_progress
---

# Track — Client Lane: client portal from the share links (api)

Plan: `docs/superpowers/plans/2026-10-06-client-portal-api.md` (workspace root). Builds on `feature/daffa/vc-client-lane-deck-plan-requests`.
Contract: "Additive notes (client portal …)" in `docs/prd/client-lane-p0a/api.md`.
Tests: `DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=2G vendor/bin/pest <file> --compact` — file paths only, one process at a time, worktree `api/.worktrees/client-portal`, after `test ! -e bootstrap/cache/config.php && rm -f bootstrap/cache/routes-v7.php`.

## Status

| Item | Status |
|------|--------|
| Wireframe | n/a (api) |
| PRD | spec 2026-10-06 (client portal) approved |
| Service PRD | contract notes appended |
| Implementation | completed (api) |
| PR | not_submitted |

## Task Checklist

- [x] TASK-0: Pre-flight — base branch, permission, worktree, caches, baseline
- [x] TASK-1: Schema — sessions, access level, views, decision audit, GIN, link-less codes
- [x] TASK-2: Active-lane rule + role-removal revocation (bug 1); rotation keeps the level
- [x] TASK-3: Client sessions — service, principal, `client.session`, sign-out
- [x] TASK-4: Session exchange — `?k=` and the request-link code (`issue_session`)
- [x] TASK-5: Request page with a session — viewer, `view_only`, opened, decision audit
- [x] TASK-6: Portal `me` and the Approvals inbox
- [x] TASK-7: Portal sign-in by code
- [x] TASK-8: Agency Clients endpoints
- [x] TASK-9: Approver suggestions (bug 2, api side)
- [x] TASK-10: Reserved workspace slugs
- [x] TASK-11: Session retention purge
- [x] TASK-12: Gates, contract notes, track file
- [ ] Before the PR: run the `security-review` skill on this branch (spec §8.1) and on the web branch
- [ ] Manual (spec §8.3): two devices; a multi-brand client in two workspaces; a view-only client; Remove while the portal is open

## Session Log
```

Then append one session-log entry with the real results of this run — the date and worker, the Task 0 baseline failures (names), every expectation corrected under the Global Constraints rule (test, old value, new value, why), the Task 10 Step 8 dev-data check result, the final run's pass counts, and "Next: security-review, then Daffa's manual checks; no push, no PR".

- [ ] **Step 6: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal && /usr/bin/git add docs/prd/client-lane-p0a/api.md docs/tracks/client-portal.track.md && /usr/bin/git commit -m "docs(api): client portal contract notes and track"
```

- [ ] **Step 7: Hand back to Daffa** — report the branch, the 12 commits, the final run, anything the track file flags (baseline failures, corrected expectations, reserved-slug rows in dev data), and the reminder: **`security-review` before the PR; nothing is pushed.**

---

## Spec coverage (self-review, 2026-10-06)

| Spec | Where |
|---|---|
| §1 bug 1 — removed role keeps the lane | Task 2 (`scopeHonoured`, events, per-model old routes) |
| §1 bug 2 — suggestions can't show clients (api) | Task 9 |
| §4.1 `client_sessions` | Task 1 (table), Task 3 (issue/slide/revoke) |
| §4.1 lane `access_level`, default/backfill `own` | Task 1 |
| §4.1 `approval_request_views` | Task 1 (model), Task 5 (recorded, `opened`) |
| §4.1 `approval_decisions.client_session_id` | Task 1, Task 5 (stored; record PDF label) |
| §4.1 GIN on `approvers` | Task 1 |
| §4.1 reserved slugs + loud migration | Task 10 |
| §4.2 active lane, `activeLanesFor`/`activeLane`, resolveHeader through the rule | Task 2 |
| §4.2 removal anywhere revokes, incl. old `DELETE members` | Task 2 (+ Task 8 model path) |
| §4.3 (1) `?k=` → `public/client/session` | Task 4 |
| §4.3 (2) code on a request link issues a session | Task 4 (`issue_session`, PR3) |
| §4.3 (3) portal code | Task 7 |
| §4.4 middleware, principal, 401 / brand 404, touch + slide | Task 3, Task 6 |
| §4.5 viewer order, legacy header, views, `403 view_only`, session on decision | Task 5 |
| §5 group: `no-store`, throttled | Tasks 3, 6, 7 |
| §5.1 `me` | Task 6 |
| §5.2 inbox, groups, `Item`, 90 days + cursor | Task 6 |
| §5.3 code request/verify, sign-out | Task 7, Task 3 |
| §7.1 Clients CRUD + portal-link | Task 8 |
| §7.3 approver suggestions | Task 9 |
| §8.1 token hash-only, header-only, enumeration-safe, throttles, revocation | Tasks 3, 4, 6, 7; `security-review` reminder in Task 12 |
| §8.2 legacy `frnd_lane` honoured; api before web | Task 5 (test 2), PR3 (old web unaffected) |
| §8.3 api tests | the six `tests/Feature/ClientPortal/*` files |
| §10 Q1 retention | Task 11 (PR16) |

Out of this plan (web plan or later stages): §6 portal web, §7.2 Clients tab UI, §7.3 web chips/analytics, §6.6 analytics, §10 Q2/Q3.
