# Client Lane — Deck and Campaign Plan on Approval Requests — API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `v1/approval-requests` take `deck` and `campaign` subjects through one per-type subject adapter (KV refactored behind it first with byte-identical responses), give plans and decks the KV request flow end to end (preview with `blocked_reason`, send, supersede incl. pending P0a rounds, verification, digest, plan status, reopen-on-edit), and add a per-request approval record PDF for all three types — while P0a deck/plan rounds keep working (drain).

**Architecture:** A new `ApprovalRequestSubject` interface (`app/Services/Approval/Subjects/`) holds everything that differs per type — the candidate `RequestItem`s, how one is frozen, what its approval snapshots, how it is pictured and rendered on the public page. `KvRequestSubject` wraps today's `KvArtboardResolver`/`KvArtboard`/`KvArtboardThumbnails` logic unchanged; `DeckRequestSubject` (one item, version = a frozen `deck_versions` row via `ApprovalService::freezeDeckVersion`, label `v{round}`) and `PlanRequestSubject` (one item, version = `ApprovalService::fingerprintPlan`) are added. `ApprovalRequestSubjects` resolves the adapter from `subject_type`. `ApprovalRequestPreviewService`, `ApprovalRequestService::create`, `ApprovalRequestPresenter` and both controllers go through it; matching "the same item" becomes null-safe (`Approval::scopeForSubjectKeys`). `ApprovalService` gains `closePendingRequestApprovals()` (plan edit, manual status, drain) and re-rolls a request whose pending approval a P0a round replaces. `ApprovalRecordPdf` renders `resources/views/pdf/approval-record.blade.php` with `barryvdh/laravel-dompdf` on demand.

**Tech Stack:** Laravel 13, PHP 8.5, PostgreSQL (jsonb, the `approvals_subject_key_round_unique` expression index), Pest 4, barryvdh/laravel-dompdf ^3.1 (already a dependency).

**Spec:** `docs/superpowers/specs/2026-10-06-client-lane-deck-plan-approval-requests-design.md` (workspace root). This plan implements §4 entirely, §7.1 phases 1–3, §7.2 drain behaviour and the §8 api tests. Phase 0 (KV smoke of Parts B/C/D, done by Daffa) is a precondition checked in Task 0, not work in this plan. Predecessor: `docs/superpowers/specs/2026-10-01-client-lane-kv-approval-requests-design.md` and its plan `docs/superpowers/plans/2026-10-01-client-lane-kv-approval-requests-api.md` (rulings R1–R18 still hold).

### Rulings (spec ambiguities resolved here; Task 14 writes them into the contract notes)

- **S1 — `brandId()` returns `?string`, not `?int`** (spec §4.2 table). Every brand id in this schema is a 26-char ULID string (`approval_requests.brand_id`, `decks.brand_id`).
- **S2 — `isCurrent(Approval $approval, RequestItem $item)` takes the item, not the subject** (spec §4.2 says `Model $subject`). A KV subject has up to 50 items; "is this approval on the current version" is a per-item question. Deck: the frozen `deck_versions.document` hashes the same as the live document (`DeckRequestSubject::documentFingerprint`, canonical key order, `1.0`→`1`). Plan: `subject_version_id === fingerprintPlan(plan)`. KV: unchanged rule R1.
- **S3 — The adapter has four more methods than the spec table:** `type()`, `composites()` + `thumbnailFields()` (the KV composite-thumbnail logic every presenter path already uses), `publicDocument()` (the per-type `document` + render context of spec §4.9) and `itemsNoun()` (mail copy, spec §4.7). They are the only places the presenters and notifier branched on KV.
- **S4 — A pending P0a round never makes a deck/plan "waiting".** Preview classifies it as eligible with `replaces: {request_number: null, round: n}`, whatever its version (spec §4.4 + §5.1 "v4 · replaces v3, still waiting"). Only a pending *request* approval on the same version is `waiting`. Without this a plan with a manual "draft"/"in review" P0a round, or a deck with a just-sent P0a round, could never be sent as a request.
- **S5 — Preview items gain `round`** (the round, hence deck label `v{round}`, the send would create) for every type, and the preview gains `blocked_reason` (`null` or `"no_brand"`) for every type. Both are additive; the KV characterization fixtures are re-recorded once in Task 4 and the diff must show only those two keys. `version_id` is `null` for a deck item before sending (the version row is minted by the send).
- **S6 — "complete" in spec §4.8 = the request's roll-up is no longer `pending`** (`approved`, `approved_with_changes`, `changes_required`); "withdrawn" = `not_relevant`. So the public PDF answers 404 exactly while `status = pending`. The **Final** stamp shows only for the three decided statuses (never for a withdrawn request).
- **S7 — The PDF lists approver *names* only**, never emails (the public payload's `request.approvers` already hides emails; the client can download this file). One block per item; inside it one line per resolving decision (multi-approver requests), advisory decisions marked. Verification label: lane `personal` → "personal link", lane `verified_guest` → "code · this device", no lane but a user → "frndOS account", else "not verified".
- **S8 — Plan edit closes only pending request approvals on another version** (`closePendingRequestApprovals('campaign', id, keepVersionId: fingerprintPlan(plan))`). A PATCH that changes nothing in the fingerprint (`name`, objective, budget, currency, allocation, scenarios, seasonality) keeps the request open. Manual status (spec §9 Q3) closes them regardless of version.
- **S9 — A pending plan request approval reads `in_review`** in `CampaignPlan::getApprovalStatusAttribute` (request approvals carry `sent_at = null`; the request holds it). Without this the plan lifecycle row would read `draft` for a plan that is out with the client.
- **S10 — Drain: a P0a round opened on a subject whose newest approval is a pending request approval closes it (as P0a always closed a pending round) AND re-rolls that request** (spec §7.2; the old production web still calls `v1/approvals`). Lock order R17 is kept: the subject's `approval_requests` rows are locked before the approval row.
- **S11 — `kv_phases` is ignored for `deck` and `campaign`** (not refused): the web may send the same body shape for every type.
- **S12 — Approval-purpose links leave the deck share-link panel:** `GET/PATCH/DELETE v1/decks/{deck}/share-links[/{id}]` use `ShareLink::forSharing()`, as KV ruling R12 did for files. Plans list only `role = view` links already.
- **S13 — `public/lane/magic-link` sends nothing for a `purpose = approval` link** (spec §4.6: magic links stay for P0a round links only). Still `202`, same body.

## API contract for web

Everything the web plan relies on. Field names are final; additive fields are marked **new**.

### Agency — `auth:sanctum`, same auth as `v1/approvals` (workspace → 404, subject policy → 403)

**`GET v1/approval-requests/preview?subject_type={kv_file|deck|campaign}&subject_id={ulid}[&kv_phases[]=…]`** — `kv_phases` honoured for `kv_file` only (S11).

```json
{ "data": {
  "phases": [],
  "items": [{
    "subject_key": null, "phase": null, "label": "Deck",
    "version_id": null,
    "thumbnail_url": "https://…/deck-preview.png",
    "fingerprint": "<sha256>",
    "snapshot": null,
    "replaces": { "request_number": null, "round": 3 },
    "round": 4
  }],
  "already_approved": [{ "subject_key": null, "phase": null, "label": "Deck", "version_id": null }],
  "waiting": [{ "subject_key": null, "phase": null, "label": "Deck", "version_id": null, "request_number": 2 }],
  "total": 1,
  "blocked_reason": null
}}
```

- `label`: `"Deck"` | `"Campaign plan"` | KV artboard label. `version_id`: deck `null` (minted at send), plan = fingerprint, KV = version row id.
- `replaces`: `null`, or the pending approval this send closes; `request_number: null` means a **P0a round** (S4).
- `round` **new** (S5): the round this send creates; deck version label = `"v" + round`.
- `blocked_reason` **new**: `null` | `"no_brand"` (deck with no brand; `total = 0`, all lists empty). KV files without a brand still answer 404 as today.
- deck/plan: `total = 1` when sendable; `total = 0` with `already_approved` (approved/approved-with-changes on the same version) or `waiting` (a pending **request** on the same version) filled.

**`POST v1/approval-requests`** `{ subject_type, subject_id, approver_emails?: string[≤10], message?: string≤500, decide_by?: "Y-m-d" (after today), kv_phases?: string[] }` → `201`:

```json
{ "data": { "request": AgencyRequest, "share_url": "https://app…/s/{token}",
  "approvers": [{ "email": "", "name": "", "user_id": "", "personal_url": "", "mail_sent": true }] } }
```

Errors: `422 {code:"nothing_ready"}` (nothing eligible, e.g. waiting), `422 {code:"already_a_member", email}`, `422 {code:"too_many_items", max}` (KV), `422 {code:"no_brand", message, errors:{subject_id:["This subject has no brand."]}}` (brand-less deck), `409 {code:"round_conflict"}` (retry), `404`, `403`. The request's link is `purpose = approval`, never counted in the 3 view-link cap and never listed in `GET v1/decks/{deck}/share-links` (S12).

**`GET v1/approval-requests?subject_type=&subject_id=`** → `{ data: AgencyRequest[] }`, open first then newest.

```text
AgencyRequest = { id, number, status: pending|approved|approved_with_changes|changes_required|not_relevant,
  policy, message, sent_at, decide_by, deferred_until, deferred_note, resolved_at, created_at,
  share_url, share_link_active, counts: {approved, approved_with_changes, changes_required, pending, superseded},
  approvers: [{name, email, user_id, personal_url, decided}],
  approvals: [{ id, subject_key: null, phase: null, label: "Deck"|"Campaign plan", round, version_id,
                thumbnail_url, fingerprint, snapshot: null, status, superseded_by_request_number, pin_count,
                decisions: [Decision] }] }
Decision = { id, actor, actor_kind: user|client|guest, verified, outcome, note, pins: string[], decided_at, advisory, deferred_until }
```

`POST v1/approval-requests/{id}/withdraw` and `…/resend` — unchanged, now for all three types.

**`GET v1/approval-requests/{id}/record.pdf`** **new** → `200 application/pdf`, `Content-Disposition: attachment; filename="approval-record-{title-slug}-request-{n}.pdf"`, any status. `404` outside the caller's workspace, `403` without read on the subject.

**`GET v1/approvals`, `POST v1/approvals`** (P0a rounds) — unchanged for deck/plan in this release (spec E-5): still `201` for `deck`/`campaign`; only `kv_file` answers `422 use_approval_requests`.

**Plan JSON** (`GET/PATCH v1/brands/{brand}/plans/{plan}`): `approvalStatus` reads `in_review` while a request approval is pending (S9); a PATCH that changes the fingerprint closes that pending approval (status then `null`, the request rolls up to `not_relevant` if it was its only item). `POST …/plans/{plan}/approval {status}` closes a pending request approval first, then applies the status (spec §9 Q3).

### Public — token is the credential, `X-Lane-Code` optional, `Cache-Control: no-store`

**`GET public/share-links/{token}`** on a deck/plan request link:

```json
{ "data": {
  "type": "deck",
  "brand": { "name": "", "slug": "", "logo_url": null },
  "workspace": { "name": "" },
  "subject": { "id": "", "title": "Ramadan 2027 strategy", "thumbnail_url": null },
  "version": { "type": "approval_request", "id": "<request id>", "label": "Request 2", "created_at": "" },
  "items": [{ "id": "<approval id>", "phase": null, "label": "Deck", "version_id": "<deck_versions.id>", "status": "pending",
              "snapshot": { "kind": "deck", "label": "Deck", "thumbnail_url": null, "fingerprint": "", "slide_count": 12 } }],
  "document": { "schema_version": 1, "slides": [] },
  "deck": { "theme": {}, "slide_themes": {}, "play_settings": {} },
  "approval": null,
  "request": { "id": "", "number": 2, "status": "pending", "message": null, "decide_by": null, "deferred_until": null,
               "deferred_note": null, "approvers": [{ "name": "", "decided": false }], "counts": {} },
  "approvals": [{ "id": "", "phase": null, "label": "Deck", "round": 4, "version_id": "", "status": "pending",
                  "snapshot": {}, "replaced": false, "decisions": [] }],
  "access": { "role": "comment", "expires_at": null, "can_decide": true, "verification_required": true },
  "viewer": { "kind": "anonymous", "name": null, "email": null }
}}
```

- deck: `document` is the **frozen** `deck_versions.document` of the request's approval; `deck` (theme, slide_themes, play_settings) is present only for decks.
- plan: `type: "campaign"`, `document` = the plan projection (`PublicCampaignPlanController::projection`, camelCase keys), snapshot `{ kind: "campaign", label: "Campaign plan", thumbnail_url, fingerprint }`, no `deck` key.
- deck/plan `approvals[].round` → header "Deck · v4 · Request 2".

**`POST public/share-links/{token}/comments`** — a pin's `anchor.id` is `"{segment}:{version_id}:{part}"` with `version_id` = `items[].version_id` (deck: the `deck_versions` id; plan: the fingerprint). Unchanged rule, now exercised for deck/plan.

**`POST public/share-links/{token}/decision`** — same as KV: `{ outcome: "approved"|"changes_required"|"deferred", approval_ids: [id], note?, pins?: [commentId], deferred_until? }`. `403 {code:"verification_required"}` without an honoured lane (every type); `422 {code:"note_required"}` for `changes_required` with no pins and no note; `422 {code:"invalid_approval"}`; `409 {code:"round_closed"}`; `201 { data: { results: [{approval_id, result, decision}], request, approvals } }`. `approved` + the decider's own pins on that version is stored as `approved_with_changes`.

**`POST public/lane/code`** / **`POST public/lane/code/verify`** — unchanged contract, now accepted for deck and plan request links (`202`; verify `200 {data:{lane_code, kind, expires_at}}`, `422 invalid_code|code_expired`).

**`POST public/lane/magic-link`** — unchanged `202` body; sends nothing for a `purpose = approval` link (S13).

**`GET public/share-links/{token}/record.pdf`** **new** → `200 application/pdf` (attachment) once the request is not `pending` (decided or withdrawn); `404 {"message":"Not found."}` (byte-identical dead-link body) while pending, for unknown/revoked/expired tokens and for non-request links.

## Global Constraints

- **Repo + shell:** every command runs from the worktree root `/Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-deck-plan-requests` (created in Task 0). Agent shells reset cwd, so prefix every shell call with `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-deck-plan-requests && `. Paths below are relative to that root unless absolute. The shell is zsh; an `rtk` hook rewrites `grep`/`git` output, so commands use `/usr/bin/grep` and `/usr/bin/git`. Daffa's dev api on :9191 serves the main `api/` checkout — never edit it.
- **Branch:** `feature/daffa/vc-client-lane-deck-plan-requests`, cut from `origin/develop` in Task 0. Never commit on `develop`. **Never push, never open a PR** (Daffa decides). **Never `git stash`** (lesson: a popped stale stash corrupted files).
- **api/AGENTS.md, verbatim: "DO NOT MAKE OR RUN ANY TESTS WITHOUT USER PERMISSION."** Task 0 asks Daffa (AskUserQuestion) for ONE approval covering exactly the Pest files this plan names (the 9 existing files of the baseline and the 11 new files), run only on the scratch DB. Nothing is written or run before that yes; anything beyond the list needs a new ask.
- **Commit trailer:** none. `api/AGENTS.md` forbids attribution trailers, and the repo rule wins over the session default (decided by the coordinator, 2026-10-06). Message format `<type>(api): …`.
- **Test DB = `frnd_testing`** (verified present with `psql -lqt` on 2026-10-06; it is the DB the 2026-09-30 run of this feature family used and the one `tests/TestCase.php` names; `frnd_test` also exists but is not used here). **Never `frnd`** (the dev DB; the worktree `.env` points at it). `tests/TestCase.php` refuses any DB without a `test` token. Before every test run:
  1. `ls bootstrap/cache/config.php 2>/dev/null` must print nothing; if it prints a path run `php artisan config:clear` (a cached config silently overrides the exported DB vars and has wiped the dev DB twice).
  2. If `bootstrap/cache/routes-v7.php` exists, delete it (`rm bootstrap/cache/routes-v7.php`) — never restore it; a stale route cache 405s every new route.
  3. Run **test file paths only**, one Pest process at a time, never `php artisan test`, never `--filter` alone:
     `DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest <file> [<file> …] --compact`
     (`TELESCOPE_ENABLED=false` is required — Telescope OOMs migrations. PHPUnit `<env>` is `force="false"`, so the exported vars win over `phpunit.xml`'s sqlite.)
- **The full Feature suite is known-broken for unrelated reasons** (`tests/Feature/Report/ReportQueryMultiBrandTest.php` kills the suite mapper). Only run the files this plan names. If `migrate:fresh` itself fails in Task 0, STOP and report.
- **Tests in this plan were written from reading the code, not from running it** (lesson: six such tests proved defective in one feature). For every test: run it against the code BEFORE the implementation step and confirm it fails *for the stated reason* (not a typo, not a fixture error); after it passes, apply the **named mutation**, watch the named test fail, restore, re-run green. If an assertion fails on UNCHANGED production code where the plan expected a pass (labels, JSON paths, counts), dump the actual value, confirm it by reading the code, and correct the expectation — never weaken the behaviour under test, and record the correction in the track file's session log.
- **No behaviour change for KV in Tasks 1–3.** Task 1's snapshot fixtures are recorded on unchanged code and every later task re-runs `tests/Feature/Approval/KvRequestCharacterizationTest.php`. The only intended KV JSON change in the whole plan is Task 4's two additive preview keys (S5).
- **Queue is `sync` in tests** (`phpunit.xml`): any test that triggers a decision must `Bus::fake([SendApprovalRequestDigest::class])`, or the 15-minute digest job runs inline. Mail tests use `Mail::fake()`.
- **Public throttles:** `public-share-link-write` is 10/min per IP — keep ≤ 9 public POSTs (comments + decisions) per test.
- **Deck tests never reach a collab server:** `ClientLaneFixtures::deck()` sets `services.collab.url` to `''` (then `DeckCollabWriter` reads `decks.document`) and `broadcasting.default` to `null`.
- **Gates at every commit:** `php -l` on each touched PHP file; `vendor/bin/pint <touched files>` then `vendor/bin/pint --test <touched files>` must pass. A commit touching `app/Http/Controllers/Api/ModelContextProtocol/` also runs `php artisan mcp:verify-mirror` (must print `Mirror OK`; api/AGENTS.md `build-askfrnd-tool` rule).
- **Lock order R17** for every write that touches requests: the subject's `approval_requests` rows (`FOR UPDATE`, by `number`), then `approvals` rows.
- **Time comparisons against `comments.created_at`** (naive `timestamp`) stay in SQL against bound Carbon values (`PinWindow`), never PHP instants.
- Line numbers cite `origin/develop @ 3d3bb8c42` as read on 2026-10-06. Earlier tasks shift them — re-read each file before editing and anchor edits on the quoted code.

## Review Focus

1. **The old production web opens a P0a round on a deck/plan that has a pending request approval** (spec E-5 drain): the request must re-roll (closed), not stay "waiting" forever with a dead approval. → Task 11, test "a P0a round closes a pending request approval and re-rolls its request".
2. **The collab server is unreachable while a deck is previewed and sent:** preview and send must both fall back to `decks.document`, hash and freeze the same document, and not 500. → Task 5, test "an unreachable collab server falls back to the stored document for both hash and freeze".
3. **A plan carrying a manual P0a "draft"/"in review" round is sent as a request:** it must be eligible and superseded (S4), not blocked as "waiting". → Task 4, test "a pending P0a plan round (manual draft) is replaced, not waited on".
4. **A plan is edited through the MCP tool while a request is pending:** the stale approval must close exactly as on the UI path. Both controllers call one service method (`ApprovalService::afterPlanEdit`); → Task 9, test "afterPlanEdit closes stale request approvals and keeps same-version ones" (service level; the MCP controller is a one-line call checked in review).
5. **The approval record of a withdrawn or partly replaced request:** must say "Withdrawn" / "Replaced by Request N", carry no Final stamp, and be downloadable by the client once withdrawn. → Task 12, test "a withdrawn request records Withdrawn and no Final stamp"; Task 13, test "the public record answers 404 while pending and the PDF once withdrawn".

---

## File Structure

Create:
- `app/Services/Approval/Subjects/ApprovalRequestSubject.php` — the adapter interface.
- `app/Services/Approval/Subjects/RequestItem.php` — one candidate item (value object).
- `app/Services/Approval/Subjects/ApprovalRequestSubjects.php` — type → adapter registry.
- `app/Services/Approval/Subjects/KvRequestSubject.php` — KV, wrapping `KvArtboardResolver`/`KvArtboard`/`KvArtboardThumbnails` unchanged.
- `app/Services/Approval/Subjects/DeckRequestSubject.php` — deck (one item, frozen `deck_versions`, render context).
- `app/Services/Approval/Subjects/PlanRequestSubject.php` — campaign plan (one item, fingerprint, projection).
- `app/Services/Approval/ApprovalRecordPdf.php` — record data, HTML, PDF download.
- `resources/views/pdf/approval-record.blade.php` — the record.
- `tests/Support/JsonSnapshot.php` — normalised JSON snapshot assertion.
- `tests/Fixtures/approval-requests/*.json` — KV characterization fixtures (recorded, committed).
- Tests: `tests/Feature/Approval/{KvRequestCharacterizationTest, KvRequestSubjectTest, DeckPlanRequestPreviewTest, DeckPlanRequestSendTest, DeckPlanRequestPublicTest, RequestVerificationTest, RequestNotifierCopyTest, DeckPlanRoundDrainTest, ApprovalRecordPdfTest, ApprovalRecordEndpointTest}.php`, `tests/Feature/CampaignPlan/PlanRequestStatusTest.php`.
- `docs/tracks/client-lane-deck-plan-requests.track.md`.

Modify:
- `app/Models/ApprovalRequest.php` (SUBJECT_TYPES), `app/Models/Approval.php` (`scopeForSubjectKeys`), `app/Models/CampaignPlan.php` (status accessor).
- `app/Services/Approval/ApprovalRequestPreview.php`, `ApprovalRequestPreviewService.php`, `ApprovalRequestService.php`, `ApprovalRequestRollup.php`, `ApprovalService.php`, `ApprovalNotifier.php`, `KvArtboard.php` (drop the now-unused `toApprovalAttributes`).
- `app/Http/Resources/Approval/ApprovalRequestPresenter.php`.
- `app/Http/Controllers/Api/Approval/ApprovalRequestController.php`, `app/Http/Controllers/Api/PublicShareLinkController.php`, `app/Http/Controllers/Api/PublicLaneController.php`, `app/Http/Controllers/Api/Deck/DeckShareLinkController.php`, `app/Http/Controllers/Api/CampaignPlan/CampaignPlansController.php`, `app/Http/Controllers/Api/ModelContextProtocol/CampaignPlanToolController.php`.
- `routes/api.php` (two `record.pdf` routes).
- `tests/Support/ClientLaneFixtures.php` (new helpers).
- `docs/prd/client-lane-p0a/api.md` (additive contract notes).

---

### Task 0: Pre-flight — worktree, permission, caches, baseline

**Files:** none changed (worktree + `vendor/` + `.env` only).

**Interfaces:**
- Consumes: nothing.
- Produces: the worktree, Daffa's answers (test permission, phase-0 status), and the baseline failure list every later task compares against.

- [ ] **Step 1: Ask Daffa (AskUserQuestion), two questions in one call**
  1. "Phase 0 (KV smoke of Parts B/C/D) — has the KV DoD checklist passed locally?" Options: *Yes, proceed* / *No, stop*. On *No*: STOP and report; this plan refactors the KV code that smoke covers.
  2. "May I create and run these Pest files on `frnd_testing` only? Existing (baseline + regression): `tests/Feature/Approval/ApprovalRequestDigestTest.php`, `tests/Feature/Approval/KvArtboardThumbnailTest.php`, `tests/Feature/Approval/KvSharePayloadItemsForTest.php`, `tests/Feature/Sharing/ShareLinksRevokedListenerTest.php`, `tests/Feature/Deck/DeckShareLinkTest.php`, `tests/Feature/CampaignPlan/CampaignPlanCrudTest.php`, `tests/Unit/CampaignPlan/PlanApprovalTest.php`, `tests/Unit/CampaignPlan/LifecycleStageTest.php`, `tests/Unit/CampaignPlan/ForecastRecomputeGateTest.php`. New: the 11 files listed in File Structure." Options: *Yes* / *No*. On *No*: STOP.

- [ ] **Step 2: Create the worktree from latest `origin/develop`**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api && /usr/bin/git fetch origin && /usr/bin/git worktree add .worktrees/client-lane-deck-plan-requests -b feature/daffa/vc-client-lane-deck-plan-requests origin/develop
```

Expected: `Preparing worktree (new branch 'feature/daffa/vc-client-lane-deck-plan-requests')`. (`.worktrees/` is in `.gitignore:61`.)

- [ ] **Step 3: Install dependencies and the env file in the worktree**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-deck-plan-requests && cp ../../.env .env && composer install --no-interaction --quiet && /usr/bin/git status --short
```

Expected: `git status` prints nothing (`.env` and `vendor/` are ignored). Do NOT symlink `vendor/` — Composer's autoloader resolves `dirname($vendorDir)` and would load the main checkout's classes.

- [ ] **Step 4: Cache and DB checks**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-deck-plan-requests && ls bootstrap/cache/config.php bootstrap/cache/routes-v7.php 2>/dev/null; psql -lqt | cut -d'|' -f1 | /usr/bin/grep -w frnd_testing
```

Expected: no cache file listed (if one is, `php artisan config:clear` / `rm bootstrap/cache/routes-v7.php`); `frnd_testing` printed. If `frnd_testing` is missing: `psql -d postgres -c 'CREATE DATABASE frnd_testing'`.

- [ ] **Step 5: Baseline run of the existing files (one process)**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-deck-plan-requests && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/ApprovalRequestDigestTest.php tests/Feature/Approval/KvArtboardThumbnailTest.php tests/Feature/Approval/KvSharePayloadItemsForTest.php tests/Feature/Sharing/ShareLinksRevokedListenerTest.php tests/Feature/Deck/DeckShareLinkTest.php tests/Feature/CampaignPlan/CampaignPlanCrudTest.php tests/Unit/CampaignPlan/PlanApprovalTest.php tests/Unit/CampaignPlan/LifecycleStageTest.php tests/Unit/CampaignPlan/ForecastRecomputeGateTest.php --compact
```

Expected: a pass/fail summary. Write every failing test name into a scratch note (it goes into the track file in Task 14). These are **pre-existing** failures: later tasks must not add to them, and must not "fix" them. If the run dies in `migrate:fresh`, STOP and report.

- [ ] **Step 6: No commit** (nothing tracked changed).

---

### Task 1: KV characterization snapshot (pinned BEFORE the refactor)

**Files:**
- Create: `tests/Support/JsonSnapshot.php`
- Modify: `tests/Support/ClientLaneFixtures.php` (add `actAsAgency`)
- Create: `tests/Feature/Approval/KvRequestCharacterizationTest.php`
- Create (recorded): `tests/Fixtures/approval-requests/kv-*.json`

**Interfaces:**
- Consumes: current `v1/approval-requests` (preview/store/index), `public/share-links/{token}` (show/decision), `ApprovalRequestDigestMail`.
- Produces: `Tests\Support\JsonSnapshot::assertMatches(string $name, mixed $data): void` and `JsonSnapshot::finish(): void` (last line of a snapshot test); `Tests\Support\ClientLaneFixtures::actAsAgency(\Tests\TestCase $test, \App\Models\User $user): void`; the fixtures every later task re-checks.

This task writes **no production code**. The test must pass on unchanged code — it is the regression net for Tasks 2–3.

- [ ] **Step 1: Write `tests/Support/JsonSnapshot.php`**

```php
<?php

namespace Tests\Support;

use PHPUnit\Framework\Assert;

/**
 * Characterization snapshots for the approval-request refactor (spec
 * 2026-10-06 §7.1 phase 1: "KV responses identical"). JSON is normalised so
 * two runs on unchanged code are byte-identical: ULIDs become `<id:N>` in
 * order of first appearance, timestamps `<ts>`, share/lane tokens `<token>`.
 *
 * Record on UNCHANGED code with SNAPSHOT_UPDATE=1: every assertMatches()
 * writes its file and the closing finish() marks the test incomplete, so a
 * recording run is never green. Otherwise compare. A missing file FAILS: a
 * snapshot test must never pass by having nothing to compare against.
 */
final class JsonSnapshot
{
    private const ULID = '/\b[0-9a-hjkmnp-tv-z]{26}\b/i';

    private const TIMESTAMP = '/\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?/';

    private const TOKEN = '#(/s/|[?&]k=)[A-Za-z0-9_-]{16}\b#';

    private static int $recorded = 0;

    public static function assertMatches(string $name, mixed $data): void
    {
        $dir = dirname(__DIR__).'/Fixtures/approval-requests';
        $path = "{$dir}/{$name}.json";
        $ids = [];
        $actual = json_encode(self::normalize($data, $ids), JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE)."\n";

        if (getenv('SNAPSHOT_UPDATE') === '1') {
            if (! is_dir($dir)) {
                mkdir($dir, 0775, true);
            }
            file_put_contents($path, $actual);
            self::$recorded++;

            return;
        }

        Assert::assertFileExists($path, "No snapshot {$name}.json — record it on UNCHANGED code with SNAPSHOT_UPDATE=1.");
        Assert::assertSame(file_get_contents($path), $actual, "Snapshot {$name}.json no longer matches.");
    }

    /** The last line of every snapshot test: a recording run ends incomplete, never green. */
    public static function finish(): void
    {
        if (self::$recorded === 0) {
            return;
        }
        $count = self::$recorded;
        self::$recorded = 0;
        Assert::markTestIncomplete("Recorded {$count} snapshot(s) — re-run without SNAPSHOT_UPDATE to compare.");
    }

    /** @param  array<string, string>  $ids */
    private static function normalize(mixed $value, array &$ids): mixed
    {
        if (is_array($value)) {
            $out = [];
            foreach ($value as $key => $item) {
                $out[is_string($key) ? self::normalizeString($key, $ids) : $key] = self::normalize($item, $ids);
            }

            return $out;
        }

        return is_string($value) ? self::normalizeString($value, $ids) : $value;
    }

    /** @param  array<string, string>  $ids */
    private static function normalizeString(string $value, array &$ids): string
    {
        $value = (string) preg_replace(self::TOKEN, '$1<token>', $value);
        $value = (string) preg_replace(self::TIMESTAMP, '<ts>', $value);

        return (string) preg_replace_callback(self::ULID, static function (array $match) use (&$ids): string {
            $key = strtolower($match[0]);
            $ids[$key] ??= '<id:'.(count($ids) + 1).'>';

            return $ids[$key];
        }, $value);
    }
}
```

- [ ] **Step 2: Add `actAsAgency` to `tests/Support/ClientLaneFixtures.php`**

Add these imports at the top of the file (keep the existing ones):

```php
use App\Http\Middleware\CheckRoleScope;
use App\Http\Middleware\EnsureWorkspaceContext;
use App\Http\Middleware\FeatureFlag;
use App\Http\Middleware\RequestContextMiddleware;
use Illuminate\Support\Facades\Gate;
use Tests\TestCase;
```

Add the method inside the class:

```php
    /**
     * Agency-side HTTP as `$user`: the middleware that needs a real
     * workspace session is stripped (as DeckShareLinkTest does) and every
     * policy allows. These tests pin approval-request behaviour, not
     * ApprovalPolicy, which this work does not change; the controller's own
     * workspace check (404) still runs.
     */
    public static function actAsAgency(TestCase $test, User $user): void
    {
        $test->withoutMiddleware([
            CheckRoleScope::class,
            EnsureWorkspaceContext::class,
            RequestContextMiddleware::class,
            FeatureFlag::class,
        ]);
        Gate::before(static fn (): bool => true);
        $test->actingAs($user, 'api');
    }
```

- [ ] **Step 3: Write the characterization test**

`tests/Feature/Approval/KvRequestCharacterizationTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Jobs\SendApprovalRequestDigest;
use App\Mail\ApprovalRequestDigestMail;
use App\Models\ClientLaneLink;
use Illuminate\Support\Facades\Bus;
use Illuminate\Support\Facades\Mail;
use Illuminate\Support\Str;
use Tests\Support\ClientLaneFixtures;
use Tests\Support\JsonSnapshot;

/**
 * KV approval requests, pinned before the subject-adapter refactor (spec
 * 2026-10-06 §7.1 phase 1, §8 "Snapshot the JSON before the phase-1
 * refactor and compare after"): preview, send, supersede, index (roll-up),
 * the public page, a decision and the digest.
 */
beforeEach(function () {
    Mail::fake();
    Bus::fake([SendApprovalRequestDigest::class]);
    config(['app.frontend_url' => 'https://app.frndos.test']);

    $this->kv = ClientLaneFixtures::kvFile();
    $this->file = $this->kv['file'];
    $this->user = $this->kv['user'];

    // Every value a snapshot can see is pinned: factories randomise names,
    // slugs and thumbnails.
    $this->kv['brand']->forceFill(['name' => 'Kopi Kenangan', 'slug' => 'kopi-kenangan', 'logo' => null])->save();
    $this->kv['workspace']->forceFill(['name' => 'Alva Agency'])->save();
    $this->file->forceFill(['thumbnail_url' => null])->save();

    $this->hero = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Hero board');
    $this->tile = ClientLaneFixtures::resizeTile($this->file, $this->user, $this->hero, 'instagram-story', 1080, 1920);
    ClientLaneFixtures::markReady('kv_generation', $this->hero->id, $this->user);
    ClientLaneFixtures::markReady('kv_resize_export', $this->tile->id, $this->user);

    ClientLaneFixtures::actAsAgency($this, $this->user);
    $this->query = http_build_query(['subject_type' => 'kv_file', 'subject_id' => $this->file->id]);
});

test('KV preview, send, supersede, index, public page, decision and digest answer exactly as before the refactor', function () {
    $preview = fn () => $this->getJson("/api/v1/approval-requests/preview?{$this->query}")->assertOk()->json('data');
    $index = fn () => $this->getJson("/api/v1/approval-requests?{$this->query}")->assertOk()->json('data');

    JsonSnapshot::assertMatches('kv-preview', $preview());

    $first = $this->postJson('/api/v1/approval-requests', [
        'subject_type' => 'kv_file',
        'subject_id' => $this->file->id,
        'message' => 'Round one',
        'decide_by' => now()->addDays(3)->toDateString(),
    ])->assertCreated()->json('data');
    JsonSnapshot::assertMatches('kv-store', $first);
    JsonSnapshot::assertMatches('kv-preview-waiting', $preview());

    // A regenerated tile keeps its row id but not its artwork (R1): the next
    // send replaces only the tile's pending approval; the hero stays waiting.
    $this->tile->forceFill(['image_url' => 'https://cdn.test/tile-2.png'])->save();
    JsonSnapshot::assertMatches('kv-preview-replaces', $preview());

    $second = $this->postJson('/api/v1/approval-requests', [
        'subject_type' => 'kv_file',
        'subject_id' => $this->file->id,
    ])->assertCreated()->json('data');
    JsonSnapshot::assertMatches('kv-store-second', $second);
    JsonSnapshot::assertMatches('kv-index', $index());

    $token = Str::afterLast($second['share_url'], '/s/');
    JsonSnapshot::assertMatches('kv-public', $this->getJson("/api/public/share-links/{$token}")->assertOk()->json('data'));

    $lane = ClientLaneLink::factory()->verifiedGuest()->create([
        'workspace_id' => $this->file->workspace_id,
        'brand_id' => $this->kv['brand']->id,
        'email' => 'dina@brand.test',
    ]);
    $decided = $this->withHeader('X-Lane-Code', $lane->unique_code)
        ->postJson("/api/public/share-links/{$token}/decision", [
            'outcome' => 'approved',
            'approval_ids' => collect($second['request']['approvals'])->pluck('id')->all(),
        ])->assertCreated()->json('data');
    JsonSnapshot::assertMatches('kv-decision', $decided);
    JsonSnapshot::assertMatches('kv-index-decided', $index());

    // Request 2 completed → the digest went out at once (§4.7).
    $digests = Mail::queued(ApprovalRequestDigestMail::class);
    expect($digests)->toHaveCount(1);
    $mail = $digests->first();
    JsonSnapshot::assertMatches('kv-digest', [
        'clientName' => $mail->clientName,
        'requestNumber' => $mail->requestNumber,
        'title' => $mail->title,
        'brandName' => $mail->brandName,
        'countsLine' => $mail->countsLine,
        'lines' => $mail->lines,
        'editorUrl' => $mail->editorUrl,
    ]);

    JsonSnapshot::finish();
});
```

- [ ] **Step 4: Record the fixtures on UNCHANGED production code**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-deck-plan-requests && SNAPSHOT_UPDATE=1 DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/KvRequestCharacterizationTest.php --compact
```

Expected: `1 incomplete` with the message "Recorded 10 snapshot(s)". `ls tests/Fixtures/approval-requests` → `kv-decision.json kv-digest.json kv-index-decided.json kv-index.json kv-preview-replaces.json kv-preview-waiting.json kv-preview.json kv-public.json kv-store-second.json kv-store.json`. If it ends FAILED instead, an HTTP assertion broke before the end — fix the test setup (never production code) and record again.

Then open each fixture and check it is meaningful: `kv-preview.json` lists two items (craft + resize) with `total: 2`; `kv-preview-waiting.json` has `total: 0` and two `waiting` entries; `kv-preview-replaces.json` has one item whose `replaces.request_number` is `1`; `kv-index-decided.json` shows request 2 `approved` and request 1 `pending` with `counts.superseded: 1`. If any is not, a fixture value is wrong — fix the test setup, never the production code.

- [ ] **Step 5: Compare twice (determinism proof)**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-deck-plan-requests && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/KvRequestCharacterizationTest.php --compact && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/KvRequestCharacterizationTest.php --compact
```

Expected: `1 passed` twice. If a run fails on a value that differs between runs (a faker name, a random slug, an integer id), pin that value in `beforeEach` with `forceFill` and re-record (Step 4). Never broaden the normaliser to drop a real field.

- [ ] **Step 6: Mutation check**

Mutation: in `app/Http/Resources/Approval/ApprovalRequestPresenter.php` change `'label' => 'Request '.$request->number,` to `'label' => 'Request #'.$request->number,`. Run the Step 5 command once → expected FAIL at `kv-public`. Restore the line, re-run → PASS. (`git diff app/` must be empty afterwards.)

- [ ] **Step 7: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-deck-plan-requests && php -l tests/Support/JsonSnapshot.php && php -l tests/Support/ClientLaneFixtures.php && php -l tests/Feature/Approval/KvRequestCharacterizationTest.php && vendor/bin/pint tests/Support/JsonSnapshot.php tests/Support/ClientLaneFixtures.php tests/Feature/Approval/KvRequestCharacterizationTest.php && vendor/bin/pint --test tests/Support/JsonSnapshot.php tests/Support/ClientLaneFixtures.php tests/Feature/Approval/KvRequestCharacterizationTest.php && /usr/bin/git add tests/Support/JsonSnapshot.php tests/Support/ClientLaneFixtures.php tests/Feature/Approval/KvRequestCharacterizationTest.php tests/Fixtures/approval-requests && /usr/bin/git commit -m "test(api): pin KV approval-request JSON before the subject-adapter refactor"
```

---

### Task 2: `ApprovalRequestSubject` interface, `RequestItem`, registry, `KvRequestSubject`

**Files:**
- Create: `app/Services/Approval/Subjects/ApprovalRequestSubject.php`
- Create: `app/Services/Approval/Subjects/RequestItem.php`
- Create: `app/Services/Approval/Subjects/ApprovalRequestSubjects.php`
- Create: `app/Services/Approval/Subjects/KvRequestSubject.php`
- Test: `tests/Feature/Approval/KvRequestSubjectTest.php`

**Interfaces:**
- Consumes: `KvArtboardResolver::artboards(StudioFile $file, array $phases): list<KvArtboard>`, `KvArtboard::{fingerprintOf, thumbnailOf}`, `KvArtboardThumbnails::{urlsFor, fieldsFor}`, `KvSharePayloadService::PHASES`.
- Produces (exact signatures later tasks use):

```php
namespace App\Services\Approval\Subjects;

interface ApprovalRequestSubject {
    public function type(): string;                                           // 'kv_file' | 'deck' | 'campaign'
    /** @param array{phases?: list<string>} $filters @return Collection<int, RequestItem> */
    public function items(Model $subject, array $filters = []): Collection;
    /** @return array{0: string, 1: string} [subject_version_type, subject_version_id] */
    public function freezeVersion(Model $subject, RequestItem $item, int $round, User $by): array;
    /** @return array<string, mixed> */
    public function snapshot(RequestItem $item): array;
    public function brandId(Model $subject): ?string;
    public function isCurrent(Approval $approval, RequestItem $item): bool;
    /** @param iterable<array<string, mixed>|null> $snapshots @return array<string, string> */
    public function composites(string $subjectId, iterable $snapshots): array;
    /** @return array{thumbnail_url: string|null, fingerprint: string, snapshot: array<string, mixed>|null} */
    public function thumbnailFields(?array $snapshot, array $composites): array;
    /** @param Collection<int, Approval> $approvals ordered @return array{document: array<string, mixed>, extra: array<string, mixed>} */
    public function publicDocument(Collection $approvals, Model $subject, string $brandSlug): array;
    public function itemsNoun(int $count): string;
}

final readonly class RequestItem {
    public function __construct(
        public ?string $subjectKey, public ?string $phase, public string $label,
        public string $versionType, public ?string $versionId, public ?string $thumbnailUrl,
        public string $fingerprint, public mixed $payload = null,
    ) {}
}

class ApprovalRequestSubjects {
    public function for(string $subjectType): ApprovalRequestSubject;   // throws InvalidArgumentException
    public function forModel(Model $subject): ApprovalRequestSubject;   // by getMorphClass()
}

class KvRequestSubject implements ApprovalRequestSubject {
    public static function toItem(KvArtboard $artboard): RequestItem;
}
```

Nothing calls these yet; Task 3 rewires.

- [ ] **Step 1: Write the failing test**

`tests/Feature/Approval/KvRequestSubjectTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Services\Approval\ApprovalRequestService;
use App\Services\Approval\KvArtboardResolver;
use App\Services\Approval\Subjects\ApprovalRequestSubjects;
use App\Services\Approval\Subjects\KvRequestSubject;
use App\Services\Studio\KvSharePayloadService;
use Illuminate\Support\Facades\Mail;
use Tests\Support\ClientLaneFixtures;

/**
 * The KV subject adapter (spec 2026-10-06 §4.2): today's artboard logic,
 * moved behind ApprovalRequestSubject without changes.
 */
beforeEach(function () {
    Mail::fake();
    $kv = ClientLaneFixtures::kvFile();
    $this->file = $kv['file'];
    $this->user = $kv['user'];
    $this->hero = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Hero board');
    $this->tile = ClientLaneFixtures::resizeTile($this->file, $this->user, $this->hero);
    ClientLaneFixtures::markReady('kv_generation', $this->hero->id, $this->user);
    ClientLaneFixtures::markReady('kv_resize_export', $this->tile->id, $this->user);
    $this->adapter = app(KvRequestSubject::class);
});

test('items are the ready artboards: same key, phase, label, version and artwork fingerprint as KvArtboard', function () {
    $artboards = app(KvArtboardResolver::class)->artboards($this->file, KvSharePayloadService::PHASES);
    $items = $this->adapter->items($this->file);

    expect($items)->toHaveCount(2);
    foreach ($artboards as $i => $artboard) {
        expect($items[$i]->subjectKey)->toBe($artboard->subjectKey)
            ->and($items[$i]->phase)->toBe($artboard->phase)
            ->and($items[$i]->label)->toBe($artboard->label)
            ->and($items[$i]->versionType)->toBe($artboard->versionType)
            ->and($items[$i]->versionId)->toBe($artboard->versionId)
            ->and($items[$i]->fingerprint)->toBe($artboard->fingerprint())
            ->and($this->adapter->snapshot($items[$i]))->toBe($artboard->snapshot);
    }
});

test('isCurrent: same row and artwork is current; a regenerated tile (same row, new image) is not', function () {
    $request = app(ApprovalRequestService::class)->create($this->file, $this->user, ['resize'], notify: false)['request'];
    $approval = $request->approvals()->sole();
    $tileItem = fn () => $this->adapter->items($this->file)->firstWhere('phase', 'resize');

    expect($this->adapter->isCurrent($approval, $tileItem()))->toBeTrue();

    $this->tile->forceFill(['image_url' => 'https://cdn.test/tile-2.png'])->save();

    expect($this->adapter->isCurrent($approval, $tileItem()))->toBeFalse();
});

test('the mail noun counts artboards', function () {
    expect($this->adapter->itemsNoun(1))->toBe('1 artboard')
        ->and($this->adapter->itemsNoun(6))->toBe('6 artboards');
});

test('the registry resolves kv_file and refuses an unknown type', function () {
    $subjects = app(ApprovalRequestSubjects::class);

    expect($subjects->for('kv_file'))->toBeInstanceOf(KvRequestSubject::class)
        ->and($subjects->forModel($this->file))->toBeInstanceOf(KvRequestSubject::class);
    expect(fn () => $subjects->for('report'))->toThrow(InvalidArgumentException::class);
});
```

Mutations (Step 6): (a) in `KvRequestSubject::isCurrent` drop the `&& KvArtboard::fingerprintOf(...) === $item->fingerprint` clause → test 2 fails on `toBeFalse`; (b) in `toItem` pass `label: $artboard->phase` → test 1 fails.

- [ ] **Step 2: Run it to verify it fails**

Run: `DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/KvRequestSubjectTest.php --compact`
Expected: FAIL — `Class "App\Services\Approval\Subjects\KvRequestSubject" not found`.

- [ ] **Step 3: Write the interface, the item and the registry**

`app/Services/Approval/Subjects/ApprovalRequestSubject.php`:

```php
<?php

declare(strict_types=1);

namespace App\Services\Approval\Subjects;

use App\Models\Approval;
use App\Models\User;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Collection;

/**
 * What differs between the three things a client can be asked to approve
 * (docs/superpowers/specs/2026-10-06-client-lane-deck-plan-approval-requests-design.md
 * §4.2, decision E-2): which items a request would hold, how one is frozen,
 * what its approval row snapshots, how it is pictured and rendered. Supersede,
 * links, roll-up, digest and verification stay one code path in
 * {@see \App\Services\Approval\ApprovalRequestService}.
 */
interface ApprovalRequestSubject
{
    /** Morph alias: `kv_file` | `deck` | `campaign`. */
    public function type(): string;

    /**
     * Candidate items right now, in display order.
     *
     * @param  array{phases?: list<string>}  $filters  KV only; deck and plan ignore it
     * @return Collection<int, RequestItem>
     */
    public function items(Model $subject, array $filters = []): Collection;

    /**
     * Freeze `$item` as round `$round`. Runs inside the request transaction.
     *
     * @return array{0: string, 1: string} [subject_version_type, subject_version_id]
     */
    public function freezeVersion(Model $subject, RequestItem $item, int $round, User $by): array;

    /** @return array<string, mixed> what `approvals.snapshot` stores for this item */
    public function snapshot(RequestItem $item): array;

    public function brandId(Model $subject): ?string;

    /** Whether `$approval` is on exactly `$item`'s current version (ruling S2). */
    public function isCurrent(Approval $approval, RequestItem $item): bool;

    /**
     * Stored composite thumbnails for these snapshots, keyed by fingerprint
     * (KV only; the others have none).
     *
     * @param  iterable<array<string, mixed>|null>  $snapshots
     * @return array<string, string>
     */
    public function composites(string $subjectId, iterable $snapshots): array;

    /**
     * @param  array<string, mixed>|null  $snapshot
     * @param  array<string, string>  $composites  from {@see composites()}
     * @return array{thumbnail_url: string|null, fingerprint: string, snapshot: array<string, mixed>|null}
     */
    public function thumbnailFields(?array $snapshot, array $composites): array;

    /**
     * What a request link's page renders (C-1, spec §4.9): `document`, plus
     * sibling keys merged into `data` (a deck's `deck` render context).
     *
     * @param  Collection<int, Approval>  $approvals  the request's approvals, display order
     * @return array{document: array<string, mixed>, extra: array<string, mixed>}
     */
    public function publicDocument(Collection $approvals, Model $subject, string $brandSlug): array;

    /** "6 artboards" / "deck" / "campaign plan" — mail and inbox copy (spec §4.7). */
    public function itemsNoun(int $count): string;
}
```

`app/Services/Approval/Subjects/RequestItem.php`:

```php
<?php

declare(strict_types=1);

namespace App\Services\Approval\Subjects;

/**
 * One thing a request would ask about (spec 2026-10-06 §4.2): a KV artboard,
 * the deck, or the plan.
 */
final readonly class RequestItem
{
    /**
     * @param  string|null  $subjectKey  stable key across rounds; null for deck and plan (one item)
     * @param  string|null  $phase  KV phase; null for deck and plan
     * @param  string|null  $versionId  the version a send freezes; null for a deck (minted by freezeVersion())
     * @param  string  $fingerprint  content hash isCurrent() compares
     * @param  mixed  $payload  adapter-private: the KvArtboard, or the deck's live document
     */
    public function __construct(
        public ?string $subjectKey,
        public ?string $phase,
        public string $label,
        public string $versionType,
        public ?string $versionId,
        public ?string $thumbnailUrl,
        public string $fingerprint,
        public mixed $payload = null,
    ) {}
}
```

`app/Services/Approval/Subjects/ApprovalRequestSubjects.php`:

```php
<?php

declare(strict_types=1);

namespace App\Services\Approval\Subjects;

// craftsman-ignore: PHP002 — resolved from the container and swapped in tests.

use Illuminate\Database\Eloquent\Model;
use InvalidArgumentException;

/** `subject_type` → its {@see ApprovalRequestSubject} (spec 2026-10-06 §4.1). */
class ApprovalRequestSubjects
{
    /** @var array<string, ApprovalRequestSubject> */
    private array $byType;

    public function __construct(KvRequestSubject $kv)
    {
        $this->byType = ['kv_file' => $kv];
    }

    public function for(string $subjectType): ApprovalRequestSubject
    {
        return $this->byType[$subjectType]
            ?? throw new InvalidArgumentException("No approval-request subject for [{$subjectType}].");
    }

    public function forModel(Model $subject): ApprovalRequestSubject
    {
        return $this->for($subject->getMorphClass());
    }
}
```

- [ ] **Step 4: Write `KvRequestSubject`**

`app/Services/Approval/Subjects/KvRequestSubject.php`:

```php
<?php

declare(strict_types=1);

namespace App\Services\Approval\Subjects;

// craftsman-ignore: PHP002 — resolved from the container and swapped in tests.

use App\Models\Approval;
use App\Models\StudioFile;
use App\Models\User;
use App\Services\Approval\KvArtboard;
use App\Services\Approval\KvArtboardResolver;
use App\Services\Approval\KvArtboardThumbnails;
use App\Services\Studio\KvSharePayloadService;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Collection;

/**
 * KV artboards (KV approval requests spec 2026-10-01 §4.1–§4.2) behind the
 * subject adapter — the artboard, phase, key and fingerprint rules moved
 * here without changes (spec 2026-10-06 §4.2, phase 1).
 */
class KvRequestSubject implements ApprovalRequestSubject
{
    public function __construct(private readonly KvArtboardResolver $artboards) {}

    public function type(): string
    {
        return 'kv_file';
    }

    public function items(Model $subject, array $filters = []): Collection
    {
        /** @var StudioFile $subject */
        return collect($this->artboards->artboards($subject, $filters['phases'] ?? KvSharePayloadService::PHASES))
            ->map(static fn (KvArtboard $artboard): RequestItem => self::toItem($artboard))
            ->values();
    }

    public static function toItem(KvArtboard $artboard): RequestItem
    {
        return new RequestItem(
            subjectKey: $artboard->subjectKey,
            phase: $artboard->phase,
            label: $artboard->label,
            versionType: $artboard->versionType,
            versionId: $artboard->versionId,
            thumbnailUrl: KvArtboard::thumbnailOf($artboard->snapshot),
            fingerprint: $artboard->fingerprint(),
            payload: $artboard,
        );
    }

    public function freezeVersion(Model $subject, RequestItem $item, int $round, User $by): array
    {
        // An artboard IS its rendered version (the board tip, the resize row,
        // the motion render): nothing to write.
        return [$item->versionType, (string) $item->versionId];
    }

    public function snapshot(RequestItem $item): array
    {
        /** @var KvArtboard $artboard */
        $artboard = $item->payload;

        return $artboard->snapshot;
    }

    public function brandId(Model $subject): ?string
    {
        $brandId = $subject->getAttribute('brand_id');

        return $brandId !== null ? (string) $brandId : null;
    }

    /** Ruling R1: same version row AND same artwork. */
    public function isCurrent(Approval $approval, RequestItem $item): bool
    {
        return (string) $approval->subject_version_id === (string) $item->versionId
            && KvArtboard::fingerprintOf($approval->snapshot) === $item->fingerprint;
    }

    public function composites(string $subjectId, iterable $snapshots): array
    {
        $fingerprints = [];
        foreach ($snapshots as $snapshot) {
            $fingerprints[] = KvArtboard::fingerprintOf($snapshot);
        }

        return KvArtboardThumbnails::urlsFor($subjectId, $fingerprints);
    }

    public function thumbnailFields(?array $snapshot, array $composites): array
    {
        return KvArtboardThumbnails::fieldsFor($snapshot, $composites);
    }

    public function publicDocument(Collection $approvals, Model $subject, string $brandSlug): array
    {
        // Rebuilt from the snapshots, replaced artboards included, so edits
        // after sending never change the page (KV spec §4.6, ruling R8).
        $phases = [];
        foreach (KvSharePayloadService::PHASES as $phase) {
            $snapshots = $approvals->where('phase', $phase)->pluck('snapshot')->filter()->values()->all();
            if ($snapshots !== []) {
                $phases[] = ['phase' => $phase, 'items' => $snapshots];
            }
        }

        return [
            'document' => ['name' => (string) $subject->getAttribute('name'), 'brand_slug' => $brandSlug, 'phases' => $phases],
            'extra' => [],
        ];
    }

    public function itemsNoun(int $count): string
    {
        return sprintf('%d %s', $count, $count === 1 ? 'artboard' : 'artboards');
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/KvRequestSubjectTest.php tests/Feature/Approval/KvRequestCharacterizationTest.php --compact`
Expected: PASS (5 tests).

- [ ] **Step 6: Mutation checks** — apply mutations (a) and (b) named under Step 1 one at a time; each must turn its named test red; restore; re-run green.

- [ ] **Step 7: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-deck-plan-requests && for f in app/Services/Approval/Subjects/*.php tests/Feature/Approval/KvRequestSubjectTest.php; do php -l $f || exit 1; done && vendor/bin/pint app/Services/Approval/Subjects tests/Feature/Approval/KvRequestSubjectTest.php && vendor/bin/pint --test app/Services/Approval/Subjects tests/Feature/Approval/KvRequestSubjectTest.php && /usr/bin/git add app/Services/Approval/Subjects tests/Feature/Approval/KvRequestSubjectTest.php && /usr/bin/git commit -m "refactor(api): add the approval-request subject adapter with the KV implementation"
```

---

### Task 3: Route preview, send, presenter and controllers through the adapter (no behaviour change)

**Files:**
- Modify: `app/Models/Approval.php` (add `scopeForSubjectKeys`)
- Modify: `app/Services/Approval/ApprovalRequestPreview.php`
- Modify: `app/Services/Approval/ApprovalRequestPreviewService.php`
- Modify: `app/Services/Approval/ApprovalRequestService.php`
- Modify: `app/Services/Approval/KvArtboard.php` (delete `toApprovalAttributes()`)
- Modify: `app/Http/Resources/Approval/ApprovalRequestPresenter.php`
- Modify: `app/Http/Controllers/Api/Approval/ApprovalRequestController.php`
- Modify: `app/Http/Controllers/Api/PublicShareLinkController.php` (two `publicPayload` calls, `extra` merge)
- Test (regression gate): `tests/Feature/Approval/KvRequestCharacterizationTest.php` (unchanged)

**Interfaces:**
- Consumes: Task 2's adapter, `RequestItem`, registry.
- Produces:
  - `Approval::scopeForSubjectKeys(Builder $query, array<int, string|null> $keys): Builder` — null-safe `subject_key IN`.
  - `ApprovalRequestPreviewService::preview(Model $subject, ?array $phases = null): ApprovalRequestPreview`
  - `ApprovalRequestPreviewService::latestByKey(Model $subject, array<int, string|null> $keys): array<string, Approval>` — keyed by `(string) subject_key` (`''` for a null key).
  - `ApprovalRequestPreviewService::classify(ApprovalRequestSubject $adapter, RequestItem $item, ?Approval $latest): string`
  - `ApprovalRequestPreview::items(): list<RequestItem>` (replaces `artboards()`); entries `eligible: list<array{item: RequestItem, previous: Approval|null, thumbnail: array}>`, `alreadyApproved: list<RequestItem>`, `waiting: list<array{item: RequestItem, previous: Approval}>`.
  - `ApprovalRequestService::create(Model $subject, User $requester, ?array $phases = null, array $approverEmails = [], ?string $message = null, ?CarbonInterface $decideBy = null, bool $notify = true): array` — same positional order as today (`StudioFile` is a `Model`, so every existing caller compiles).
  - `ApprovalRequestPresenter::agency(ApprovalRequest $request, ?Collection $successors = null, ?array $pins = null, ?array $composites = null, ?ApprovalRequestSubject $adapter = null): array`
  - `ApprovalRequestPresenter::publicPayload(ApprovalRequest $request, Model $subject, string $brandSlug): array{version, items, document, extra, request, approvals}` — **signature change** (was `string $fileName`).

The gate for this task is the Task 1 characterization test plus the four existing KV files: identical output, nothing new.

- [ ] **Step 1: Confirm the gate is green before touching code**

Run: `DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/KvRequestCharacterizationTest.php tests/Feature/Approval/KvArtboardThumbnailTest.php tests/Feature/Approval/ApprovalRequestDigestTest.php tests/Feature/Approval/KvSharePayloadItemsForTest.php tests/Feature/Sharing/ShareLinksRevokedListenerTest.php tests/Feature/Approval/KvRequestSubjectTest.php --compact`
Expected: PASS except the Task 0 baseline failures (if any were in these files).

- [ ] **Step 2: Add the null-safe key scope to `app/Models/Approval.php`** (after `scopeForSubject`)

```php
    /**
     * Null-safe `subject_key IN (…)` (spec 2026-10-06 §4.2): a deck or plan
     * item's key is NULL, which `whereIn` never matches.
     *
     * @param  array<int, string|null>  $keys
     */
    public function scopeForSubjectKeys(Builder $query, array $keys): Builder
    {
        $named = array_values(array_unique(array_filter($keys, static fn ($key): bool => $key !== null)));
        $unnamed = in_array(null, $keys, true);

        return $query->where(function (Builder $any) use ($named, $unnamed): void {
            if ($named !== []) {
                $any->whereIn('subject_key', $named);
            }
            if ($unnamed) {
                $any->orWhereNull('subject_key');
            }
            if ($named === [] && ! $unnamed) {
                $any->whereRaw('1 = 0');
            }
        });
    }
```

- [ ] **Step 3: Replace `app/Services/Approval/ApprovalRequestPreview.php`** (same JSON, generic entries)

```php
<?php

declare(strict_types=1);

namespace App\Services\Approval;

use App\Models\Approval;
use App\Services\Approval\Subjects\RequestItem;

/**
 * What an approval request would contain right now (KV spec §4.5 preview,
 * rulings R2/R3; spec 2026-10-06 §4.3 for every subject type). `eligible`
 * is exactly what `ApprovalRequestService::create()` freezes.
 */
final readonly class ApprovalRequestPreview
{
    /**
     * @param  list<array{phase: string, count: int}>  $phases  per-phase eligible counts, ignoring the phase filter (KV only)
     * @param  list<array{item: RequestItem, previous: Approval|null, thumbnail: array{thumbnail_url: string|null, fingerprint: string, snapshot: array<string, mixed>|null}}>  $eligible  `previous` = the pending approval it would replace
     * @param  list<RequestItem>  $alreadyApproved
     * @param  list<array{item: RequestItem, previous: Approval}>  $waiting
     */
    public function __construct(
        public array $phases,
        public array $eligible,
        public array $alreadyApproved,
        public array $waiting,
    ) {}

    public function total(): int
    {
        return count($this->eligible);
    }

    /** @return list<RequestItem> */
    public function items(): array
    {
        return array_map(static fn (array $entry): RequestItem => $entry['item'], $this->eligible);
    }

    /** @return array{phases: list<array{phase: string, count: int}>, items: list<array<string, mixed>>, already_approved: list<array<string, mixed>>, waiting: list<array<string, mixed>>, total: int} */
    public function toArray(): array
    {
        return [
            'phases' => $this->phases,
            'items' => array_map(static fn (array $entry): array => [
                'subject_key' => $entry['item']->subjectKey,
                'phase' => $entry['item']->phase,
                'label' => $entry['item']->label,
                'version_id' => $entry['item']->versionId,
                // thumbnail_url, fingerprint, and the snapshot to render from
                // only while no composite is stored (a settled preview stays small).
                ...$entry['thumbnail'],
                'replaces' => $entry['previous'] !== null ? [
                    'request_number' => $entry['previous']->approvalRequest?->number,
                    'round' => $entry['previous']->round,
                ] : null,
            ], $this->eligible),
            'already_approved' => array_map(static fn (RequestItem $item): array => [
                'subject_key' => $item->subjectKey,
                'phase' => $item->phase,
                'label' => $item->label,
                'version_id' => $item->versionId,
            ], $this->alreadyApproved),
            'waiting' => array_map(static fn (array $entry): array => [
                'subject_key' => $entry['item']->subjectKey,
                'phase' => $entry['item']->phase,
                'label' => $entry['item']->label,
                'version_id' => $entry['item']->versionId,
                'request_number' => $entry['previous']->approvalRequest?->number,
            ], $this->waiting),
            'total' => $this->total(),
        ];
    }
}
```

- [ ] **Step 4: Replace the body of `app/Services/Approval/ApprovalRequestPreviewService.php`**

Keep the class docblock and the three constants. Replace the imports, constructor and methods with:

```php
use App\Models\Approval;
use App\Services\Approval\Subjects\ApprovalRequestSubject;
use App\Services\Approval\Subjects\ApprovalRequestSubjects;
use App\Services\Approval\Subjects\RequestItem;
use App\Services\Studio\KvSharePayloadService;
use Illuminate\Database\Eloquent\Model;
```

```php
    public function __construct(private readonly ApprovalRequestSubjects $subjects) {}

    /** @param  list<string>|null  $phases  null or [] = every phase (KV only) */
    public function preview(Model $subject, ?array $phases = null): ApprovalRequestPreview
    {
        $adapter = $this->subjects->forModel($subject);
        $items = $adapter->items($subject)->all();
        $latest = $this->latestByKey($subject, array_map(static fn (RequestItem $item): ?string => $item->subjectKey, $items));
        $selected = $phases === null || $phases === [] ? KvSharePayloadService::PHASES : $phases;

        $counts = [];
        $eligible = [];
        $approved = [];
        $waiting = [];
        foreach ($items as $item) {
            $previous = $latest[(string) $item->subjectKey] ?? null;
            $verdict = self::classify($adapter, $item, $previous);

            if ($item->phase !== null && $verdict === self::ELIGIBLE) {
                $counts[$item->phase] = ($counts[$item->phase] ?? 0) + 1;
            }
            if ($item->phase !== null && ! in_array($item->phase, $selected, true)) {
                continue;
            }

            if ($verdict === self::ELIGIBLE) {
                $eligible[] = ['item' => $item, 'previous' => $previous?->isPending() ? $previous : null];
            } elseif ($verdict === self::APPROVED) {
                $approved[] = $item;
            } else {
                $waiting[] = ['item' => $item, 'previous' => $previous];
            }
        }

        $phaseRows = [];
        foreach (KvSharePayloadService::PHASES as $phase) {
            if (($counts[$phase] ?? 0) > 0) {
                $phaseRows[] = ['phase' => $phase, 'count' => $counts[$phase]];
            }
        }

        $composites = $adapter->composites(
            (string) $subject->getKey(),
            array_map(static fn (array $entry): array => $adapter->snapshot($entry['item']), $eligible),
        );
        foreach ($eligible as $i => $entry) {
            $eligible[$i]['thumbnail'] = $adapter->thumbnailFields($adapter->snapshot($entry['item']), $composites);
        }

        return new ApprovalRequestPreview($phaseRows, $eligible, $approved, $waiting);
    }

    /**
     * The newest-round approval of each item key on the subject, keyed by
     * `(string) subject_key` — a deck's or plan's single NULL key reads as ''.
     *
     * @param  array<int, string|null>  $keys
     * @return array<string, Approval>
     */
    public function latestByKey(Model $subject, array $keys): array
    {
        if ($keys === []) {
            return [];
        }

        return Approval::query()
            ->forSubject($subject->getMorphClass(), (string) $subject->getKey())
            ->forSubjectKeys($keys)
            ->with('approvalRequest:id,number')
            ->orderBy('round')
            ->get()
            ->keyBy(static fn (Approval $approval): string => (string) $approval->subject_key)
            ->all();
    }

    public static function classify(ApprovalRequestSubject $adapter, RequestItem $item, ?Approval $latest): string
    {
        if ($latest === null || ! $adapter->isCurrent($latest, $item)) {
            return self::ELIGIBLE;
        }

        return match ($latest->status) {
            Approval::STATUS_APPROVED, Approval::STATUS_APPROVED_WITH_CHANGES => self::APPROVED,
            Approval::STATUS_PENDING => self::WAITING,
            default => self::ELIGIBLE,
        };
    }
```

- [ ] **Step 5: Generalise `ApprovalRequestService::create` and `phasesOf`**

In `app/Services/Approval/ApprovalRequestService.php`:

1. Imports: add `use App\Services\Approval\Subjects\ApprovalRequestSubjects;`, `use App\Services\Approval\Subjects\RequestItem;`, `use Illuminate\Database\Eloquent\Model;`. Keep `StudioFile` (used in the brand message).
2. Constructor: add `private readonly ApprovalRequestSubjects $subjects,` as the last parameter.
3. Replace `create()` from its signature to the end of the `DB::transaction` closure with:

```php
    public function create(
        Model $subject,
        User $requester,
        ?array $phases = null,
        array $approverEmails = [],
        ?string $message = null,
        ?CarbonInterface $decideBy = null,
        bool $notify = true,
    ): array {
        $adapter = $this->subjects->forModel($subject);
        $info = ApprovalSubject::from($subject);
        $brand = $info->brand();
        if ($brand === null) {
            // `code` lets the web tell this 422 apart from other validation
            // errors (reconciled with the web plan, 2026-10-06); the
            // Laravel-shaped `message` + `errors.subject_id` stay as before.
            $text = $subject instanceof StudioFile ? 'This file has no brand.' : 'This subject has no brand.';
            throw new \Illuminate\Http\Exceptions\HttpResponseException(response()->json([
                'code' => 'no_brand', // = ApprovalRequestPreview::NO_BRAND (added in Task 4)
                'message' => $text,
                'errors' => ['subject_id' => [$text]],
            ], 422));
        }

        $emails = array_values(array_unique(array_map(
            static fn (string $e): string => strtolower(trim($e)),
            array_filter($approverEmails, static fn ($e) => is_string($e) && trim($e) !== ''),
        )));

        // Resolved OUTSIDE the transaction (P0a review M-1's reasoning): the
        // KV resolver walks board chains, a deck's live document is a network
        // read, and a refusal writes nothing.
        $items = $this->previews->preview($subject, $phases)->items();
        if ($items === []) {
            throw new NothingReadyException;
        }
        if (count($items) > self::MAX_ARTBOARDS) {
            throw new TooManyItemsException(self::MAX_ARTBOARDS);
        }

        $type = $adapter->type();
        $subjectId = (string) $subject->getKey();

        try {
            /** @var array{request: ApprovalRequest, share_link: ShareLink, approvers: list<array{user: User, lane: ClientLaneLink}>} $result */
            $result = DB::transaction(function () use ($subject, $adapter, $info, $type, $subjectId, $requester, $emails, $message, $decideBy, $brand, $items): array {
                $existing = ApprovalRequest::query()
                    ->forSubject($type, $subjectId)
                    ->orderBy('number')
                    ->lockForUpdate()
                    ->get();
                $number = (int) ($existing->max('number') ?? 0) + 1;

                $keys = array_map(static fn (RequestItem $item): ?string => $item->subjectKey, $items);
                Approval::query()
                    ->forSubject($type, $subjectId)
                    ->forSubjectKeys($keys)
                    ->lockForUpdate()
                    ->get(['id']);
                // Re-read under the lock: a request sent since the preview
                // may have opened a newer round on one of these items.
                $latest = $this->previews->latestByKey($subject, $keys);

                ['actors' => $approvers, 'rows' => $approverRows] = $this->lanes->provisionApprovers($brand, $emails, $requester);
                $policy = $approverRows === [] ? Approval::POLICY_OPTIONAL : Approval::POLICY_REQUIRED;

                $link = $this->shareLinks->createApprovalLink($subject, $requester, self::phasesOf($items), $info->workspaceId);

                $request = ApprovalRequest::create([
                    'workspace_id' => $info->workspaceId,
                    'brand_id' => (string) $info->brandId,
                    'subject_type' => $type,
                    'subject_id' => $subjectId,
                    'number' => $number,
                    'requested_by' => $requester->id,
                    'policy' => $policy,
                    'approvers' => $approverRows,
                    'message' => $message !== null && trim($message) !== '' ? trim($message) : null,
                    'share_link_id' => $link->id,
                    'sent_at' => now(),
                    'decide_by' => $decideBy,
                    'status' => Approval::STATUS_PENDING,
                ]);

                $touched = [];
                foreach ($items as $item) {
                    $previous = $latest[(string) $item->subjectKey] ?? null;
                    // Supersede (KV spec §4.3): only a still-pending approval of
                    // the SAME item; the other request stays open for the rest.
                    $replaced = $previous !== null && $previous->isPending() ? $previous : null;
                    if ($replaced !== null) {
                        $replaced->forceFill([
                            'status' => Approval::STATUS_NOT_RELEVANT,
                            'resolved_at' => now(),
                        ])->save();
                        if ($replaced->approval_request_id !== null) {
                            $touched[(string) $replaced->approval_request_id] = true;
                        }
                    }

                    $round = ($previous?->round ?? 0) + 1;
                    [$versionType, $versionId] = $adapter->freezeVersion($subject, $item, $round, $requester);

                    Approval::create([
                        'subject_type' => $type,
                        'subject_id' => $subjectId,
                        'workspace_id' => $info->workspaceId,
                        'brand_id' => (string) $info->brandId,
                        'requested_by' => $requester->id,
                        'approval_request_id' => $request->id,
                        'round' => $round,
                        'supersedes_approval_id' => $replaced?->id,
                        // Copied once and never updated, so P0a FR-3
                        // resolution runs per approval unchanged (KV §4.1).
                        'policy' => $policy,
                        'approvers' => $approverRows,
                        'status' => Approval::STATUS_PENDING,
                        'message' => null,
                        'share_link_id' => null,
                        'sent_at' => null,
                        'subject_key' => $item->subjectKey,
                        'phase' => $item->phase,
                        'label' => $item->label,
                        'snapshot' => $adapter->snapshot($item),
                        'subject_version_type' => $versionType,
                        'subject_version_id' => $versionId,
                    ]);
                }

                foreach ($existing as $other) {
                    if (isset($touched[(string) $other->id])) {
                        $this->recalculate($other);
                    }
                }

                return ['request' => $request, 'share_link' => $link, 'approvers' => $approvers];
            });
```

The `catch (QueryException …)` block and everything after it in `create()` stay, except: the notifier call keeps `count($items)` in place of `count($artboards)`, and `$subject` in that call becomes `$info`:

```php
        $sent = $notify
            ? $this->notifier->requestSent($result['request'], $info, $result['share_link'], $requester, $result['approvers'], count($items))
            : [];
```

4. Replace `phasesOf`:

```php
    /**
     * Phases the request's KV items live in, canonical order — the phases
     * its link exposes. Empty for a deck or plan.
     *
     * @param  list<RequestItem>  $items
     * @return list<string>
     */
    private static function phasesOf(array $items): array
    {
        $phases = array_filter(array_map(static fn (RequestItem $item): ?string => $item->phase, $items));

        return array_values(array_intersect(KvSharePayloadService::PHASES, array_unique($phases)));
    }
```

5. Update the class docblock's first line to "Approval requests (KV spec 2026-10-01 §4.3–§4.5; deck and plan, spec 2026-10-06 §4.1–§4.4)…" and the `@throws ValidationException` line to "subject without brand, workspace without a client role".

- [ ] **Step 6: Delete `KvArtboard::toApprovalAttributes()`**

Run `/usr/bin/grep -rn "toApprovalAttributes" app tests` — expected: only its definition in `app/Services/Approval/KvArtboard.php`. Delete that method (docblock included).

- [ ] **Step 7: Route `ApprovalRequestPresenter` through the adapter**

In `app/Http/Resources/Approval/ApprovalRequestPresenter.php`:

1. Imports: remove `KvArtboard`, `KvArtboardThumbnails`; add `use App\Services\Approval\Subjects\ApprovalRequestSubject;`, `use App\Services\Approval\Subjects\ApprovalRequestSubjects;`, `use Illuminate\Database\Eloquent\Model;`. Keep `KvSharePayloadService` (used by `ordered()`).
2. `agencyMany()`: replace `$composites = self::compositesFor((string) $first->subject_id, $all);` and the final `return` with:

```php
        $adapter = app(ApprovalRequestSubjects::class)->for((string) $first->subject_type);
        $composites = $adapter->composites((string) $first->subject_id, $all->pluck('snapshot'));

        return $requests->map(fn (ApprovalRequest $r): array => self::agency($r, $successors, $pins, $composites, $adapter))->values()->all();
```

3. `agency()`: new signature and the two adapter uses:

```php
    public static function agency(ApprovalRequest $request, ?Collection $successors = null, ?array $pins = null, ?array $composites = null, ?ApprovalRequestSubject $adapter = null): array
    {
        $request->loadMissing(['approvals.decisions.actor:id,name', 'shareLink']);
        $adapter ??= app(ApprovalRequestSubjects::class)->for((string) $request->subject_type);
        $approvals = self::ordered($request->approvals);
        $successors ??= Approval::successorsOf($approvals);
        $pins ??= PinWindow::clientPinCounts(
            (string) $request->subject_type,
            (string) $request->subject_id,
            PinWindow::forApprovals($approvals, $successors),
        );
        $composites ??= $adapter->composites((string) $request->subject_id, $approvals->pluck('snapshot'));
```

and inside the `'approvals' =>` map replace `...KvArtboardThumbnails::fieldsFor($approval->snapshot, $composites),` with `...$adapter->thumbnailFields($approval->snapshot, $composites),`. Leave every other key and its order as is.

4. `publicPayload()`: new signature and document from the adapter:

```php
    /**
     * Everything the public page reads for an approval link (C-1, reused by
     * C-3), built once (KV spec §4.6, ruling R8; spec 2026-10-06 §4.9).
     * `document` (and a deck's `deck` render context, returned in `extra`)
     * comes from the subject adapter.
     *
     * @return array{version: array<string, mixed>, items: list<array<string, mixed>>, document: array<string, mixed>, extra: array<string, mixed>, request: array<string, mixed>, approvals: list<array<string, mixed>>}
     */
    public static function publicPayload(ApprovalRequest $request, Model $subject, string $brandSlug): array
    {
        $request->loadMissing(['approvals.decisions.actor:id,name']);
        $approvals = self::ordered($request->approvals);
        $successors = Approval::successorsOf($approvals);
        ['document' => $document, 'extra' => $extra] = app(ApprovalRequestSubjects::class)
            ->for((string) $request->subject_type)
            ->publicDocument($approvals, $subject, $brandSlug);
```

Keep the `$public = …` block. Delete the `$phases = []; foreach (KvSharePayloadService::PHASES …)` block. In the returned array replace `'document' => ['name' => $fileName, 'brand_slug' => $brandSlug, 'phases' => $phases],` with:

```php
            'document' => $document,
            'extra' => $extra,
```

5. Delete the private `compositesFor()` method.

- [ ] **Step 8: Generalise `ApprovalRequestController`'s subject resolution**

In `app/Http/Controllers/Api/Approval/ApprovalRequestController.php`:

1. Remove `use App\Models\StudioFile;`.
2. Replace `preview()`, `index()` and the `$file = …` / `create(` lines of `store()`:

```php
    /** GET v1/approval-requests/preview?subject_type=&subject_id=&kv_phases[]= */
    public function preview(Request $request): JsonResponse
    {
        $validated = $request->validate([...self::subjectRules(), ...self::phaseRules()]);
        $subject = $this->subject($request, $validated['subject_type'], $validated['subject_id'], write: false);

        return response()->json(['data' => $this->previews->preview($subject->model, $validated['kv_phases'] ?? null)->toArray()]);
    }

    /** GET v1/approval-requests?subject_type=&subject_id= — open first, then newest. */
    public function index(Request $request): JsonResponse
    {
        $validated = $request->validate(self::subjectRules());
        $subject = $this->subject($request, $validated['subject_type'], $validated['subject_id'], write: false);

        $requests = ApprovalRequest::query()
            ->forSubject($subject->type, (string) $subject->model->getKey())
```

(rest of `index()` unchanged), and in `store()`:

```php
        $subject = $this->subject($request, $validated['subject_type'], $validated['subject_id'], write: true);

        try {
            $result = $this->requests->create(
                $subject->model,
```

3. Replace the private `file()` method with:

```php
    /**
     * The subject, after the same checks as v1/approvals: 404 outside the
     * caller's workspace (superadmins excepted) or for a template deck, 403
     * without read (or, to send, request) permission on the subject.
     */
    private function subject(Request $request, string $type, string $id, bool $write): ApprovalSubject
    {
        try {
            $subject = ApprovalSubject::find($type, $id);
        } catch (ValidationException) {
            $subject = null;
        }

        $user = $request->user();
        if ($subject === null || (! $user->isSuperadmin() && $subject->workspaceId !== (string) $user->current_workspace_id)) {
            abort(404);
        }
        $allowed = $write ? ApprovalPolicy::mayRequestOn($user, $subject->model) : ApprovalPolicy::mayRead($user, $subject->model);
        if (! $allowed) {
            abort(403);
        }

        return $subject;
    }
```

- [ ] **Step 9: Update the two `publicPayload` calls in `PublicShareLinkController`**

In `show()` replace the call and add the `extra` merge right after `'document'`:

```php
            $payload = ApprovalRequestPresenter::publicPayload(
                $approvalRequest,
                $subject->model,
                (string) ($brand?->slug ?? ''),
            );

            return response()->json(['data' => [
                ...$base,
                'version' => $payload['version'],
                'items' => $payload['items'],
                'document' => $payload['document'],
                ...$payload['extra'],
                'approval' => null,
```

In `decideOnRequest()`:

```php
        $payload = ApprovalRequestPresenter::publicPayload(
            $result['request'],
            $subject->model,
            (string) ($subject->brand()?->slug ?? ''),
        );
```

- [ ] **Step 10: Run the gate — identical KV output**

Run: `DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/KvRequestCharacterizationTest.php tests/Feature/Approval/KvArtboardThumbnailTest.php tests/Feature/Approval/ApprovalRequestDigestTest.php tests/Feature/Approval/KvSharePayloadItemsForTest.php tests/Feature/Sharing/ShareLinksRevokedListenerTest.php tests/Feature/Approval/KvRequestSubjectTest.php --compact`
Expected: PASS (same set as Step 1). A characterization failure here means the refactor changed KV output: read the diff in the failure message and fix the production code — never re-record in this task.

- [ ] **Step 11: Mutation check** — in `ApprovalRequestPreviewService::preview` change `if ($item->phase !== null && $verdict === self::ELIGIBLE)` to `if ($item->phase !== null)`; run the Step 10 command → `KvRequestCharacterizationTest` FAILS (`kv-preview-waiting` phase counts). Restore; green.

- [ ] **Step 12: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-deck-plan-requests && F="app/Models/Approval.php app/Services/Approval/ApprovalRequestPreview.php app/Services/Approval/ApprovalRequestPreviewService.php app/Services/Approval/ApprovalRequestService.php app/Services/Approval/KvArtboard.php app/Http/Resources/Approval/ApprovalRequestPresenter.php app/Http/Controllers/Api/Approval/ApprovalRequestController.php app/Http/Controllers/Api/PublicShareLinkController.php" && for f in ${=F}; do php -l $f || exit 1; done && vendor/bin/pint ${=F} && vendor/bin/pint --test ${=F} && /usr/bin/git add ${=F} && /usr/bin/git commit -m "refactor(api): route KV approval requests through the subject adapter, responses unchanged"
```

---

### Task 4: Deck and plan adapters; preview for every type (`round`, `blocked_reason`)

**Files:**
- Create: `app/Services/Approval/Subjects/DeckRequestSubject.php`
- Create: `app/Services/Approval/Subjects/PlanRequestSubject.php`
- Modify: `app/Services/Approval/Subjects/ApprovalRequestSubjects.php`
- Modify: `app/Models/ApprovalRequest.php` (`SUBJECT_TYPES` + docblock)
- Modify: `app/Services/Approval/ApprovalRequestPreview.php` (`round`, `blocked_reason`, `blocked()`)
- Modify: `app/Services/Approval/ApprovalRequestPreviewService.php` (S4 rule, `round`, no-brand gate)
- Modify: `tests/Support/ClientLaneFixtures.php` (`deck`, `brandedPlan`, `readyKvFile`, `sendRequest`, `personalLane`, `verifiedGuestLane`)
- Re-record: `tests/Fixtures/approval-requests/kv-preview*.json`
- Test: `tests/Feature/Approval/DeckPlanRequestPreviewTest.php`

**Interfaces:**
- Consumes: `ApprovalService::freezeDeckVersion(Deck $deck, int $round, User $requester, ?array $liveDocument = null): DeckVersion`, `ApprovalService::fingerprintPlan(CampaignPlan $plan): string`, `DeckCollabWriter::liveDocumentResolved(Deck $deck): array{document, source, pending_count}`, `DeckStyleCatalog::slideThemesPayload(...)`, `PublicCampaignPlanController::projection(CampaignPlan $plan): array`.
- Produces:
  - `DeckRequestSubject::LABEL = 'Deck'`, `DeckRequestSubject::renderContext(Deck $deck, array $document): array{theme, slide_themes, play_settings}`, `DeckRequestSubject::documentFingerprint(array $document): string`
  - `PlanRequestSubject::LABEL = 'Campaign plan'`
  - `ApprovalRequest::SUBJECT_TYPES = ['kv_file', 'deck', 'campaign']`
  - `ApprovalRequestPreview::NO_BRAND = 'no_brand'`, `ApprovalRequestPreview::blocked(string $reason): self`, entries gain `round: int`
  - Fixtures: `ClientLaneFixtures::deck(bool $branded = true): array{workspace, user, brand, deck, subject}`, `brandedPlan(): array{workspace, user, brand, plan, subject}`, `readyKvFile(): array{workspace, user, brand, file, subject}`, `sendRequest(string $type): array{workspace, user, brand, subject, request, link}`, `personalLane(Brand $brand, ?User $client = null): ClientLaneLink`, `verifiedGuestLane(Brand $brand, string $email = 'bayu@brand.test'): ClientLaneLink`.

- [ ] **Step 1: Add the fixtures to `tests/Support/ClientLaneFixtures.php`**

Imports to add: `use App\Models\ApprovalRequest;`, `use App\Models\ClientLaneLink;`, `use App\Models\Deck\Deck;`, `use App\Models\ShareLink;`, `use App\Services\Approval\ApprovalRequestService;`.

```php
    /**
     * A deck (branded unless asked otherwise) whose live document is its
     * stored one: no collab server, no broadcast.
     *
     * @return array{workspace: Workspace, user: User, brand: Brand, deck: Deck, subject: Deck}
     */
    public static function deck(bool $branded = true): array
    {
        config(['services.collab.url' => '', 'broadcasting.default' => 'null']);

        $workspace = Workspace::factory()->create(['type' => 'organization', 'name' => 'Alva Agency']);
        $user = User::factory()->create();
        $user->update(['current_workspace_id' => $workspace->id]);
        $user->workspaces()->attach($workspace->id);
        // Name pinned for the record PDF; the slug stays the factory's random
        // one, since a test may build a deck and a plan fixture side by side.
        $brand = Brand::factory()->create(['workspace_id' => $workspace->id, 'name' => 'Kopi Kenangan']);

        $deck = Deck::factory()->create([
            'workspace_id' => $workspace->id,
            'brand_id' => $branded ? $brand->id : null,
            'created_by' => $user->id,
            'title' => 'Ramadan 2027 strategy',
            'preview_url' => null,
            'document' => ['schema_version' => 1, 'slides' => [['id' => 's1', 'layout' => 'title', 'elements' => []]]],
        ]);

        return ['workspace' => $workspace, 'user' => $user, 'brand' => $brand, 'deck' => $deck, 'subject' => $deck];
    }

    /** @return array{workspace: Workspace, user: User, brand: Brand, plan: CampaignPlan, subject: CampaignPlan} */
    public static function brandedPlan(): array
    {
        $workspace = Workspace::factory()->create(['type' => 'organization', 'name' => 'Alva Agency']);
        $user = User::factory()->create();
        $user->update(['current_workspace_id' => $workspace->id]);
        $user->workspaces()->attach($workspace->id);
        $brand = Brand::factory()->create(['workspace_id' => $workspace->id, 'name' => 'Kopi Kenangan']);
        $plan = CampaignPlan::factory()->create(['brand_id' => $brand->id, 'created_by' => $user->id, 'name' => 'Ramadan 2027 media plan']);

        return ['workspace' => $workspace, 'user' => $user, 'brand' => $brand, 'plan' => $plan, 'subject' => $plan];
    }

    /** A KV file with one ready craft board. @return array{workspace: Workspace, user: User, brand: Brand, file: StudioFile, subject: StudioFile} */
    public static function readyKvFile(): array
    {
        $kv = self::kvFile();
        $board = self::board($kv['file'], $kv['user']);
        self::markReady('kv_generation', $board->id, $kv['user']);

        return [...$kv, 'subject' => $kv['file']];
    }

    /**
     * A sent, approver-less request on a fresh subject of `$type`.
     *
     * @return array{workspace: Workspace, user: User, brand: Brand, subject: Model, request: ApprovalRequest, link: ShareLink}
     */
    public static function sendRequest(string $type): array
    {
        $fixture = match ($type) {
            'kv_file' => self::readyKvFile(),
            'deck' => self::deck(),
            'campaign' => self::brandedPlan(),
        };
        $result = app(ApprovalRequestService::class)->create($fixture['subject'], $fixture['user'], notify: false);

        return [...$fixture, 'request' => $result['request'], 'link' => $result['share_link']];
    }

    /** A named client's personal lane on `$brand` (what a personal link carries). */
    public static function personalLane(Brand $brand, ?User $client = null): ClientLaneLink
    {
        $client ??= User::factory()->create(['email' => 'dina@brand.test', 'name' => 'Dina']);

        return ClientLaneLink::factory()->create([
            'workspace_id' => $brand->workspace_id,
            'brand_id' => $brand->id,
            'user_id' => $client->id,
            'email' => $client->email,
            'kind' => ClientLaneLink::KIND_PERSONAL,
            'verified_at' => now(),
        ]);
    }

    /** A 30-day verified-guest lane (what a spent 6-digit code hands back). */
    public static function verifiedGuestLane(Brand $brand, string $email = 'bayu@brand.test'): ClientLaneLink
    {
        return ClientLaneLink::factory()->verifiedGuest()->create([
            'workspace_id' => $brand->workspace_id,
            'brand_id' => $brand->id,
            'email' => $email,
        ]);
    }
```

Also add `use Illuminate\Database\Eloquent\Model;` for the `sendRequest` docblock.

- [ ] **Step 2: Write the failing test**

`tests/Feature/Approval/DeckPlanRequestPreviewTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Models\Approval;
use App\Services\Approval\ApprovalRequestService;
use App\Services\Approval\ApprovalService;
use App\Services\Approval\ApprovalSubject;
use Illuminate\Support\Facades\Mail;
use Tests\Support\ClientLaneFixtures;

/**
 * Preview for decks and plans (spec 2026-10-06 §4.3, rulings S4/S5): one
 * item, `round`, `blocked_reason`, already approved / waiting / replaces.
 */
beforeEach(function () {
    Mail::fake();
});

function previewOf(object $test, string $type, string $id): array
{
    return $test->getJson('/api/v1/approval-requests/preview?'.http_build_query(['subject_type' => $type, 'subject_id' => $id]))
        ->assertOk()
        ->json('data');
}

test('a fresh deck previews one sendable item, round 1, nothing blocking', function () {
    $f = ClientLaneFixtures::deck();
    $f['deck']->forceFill(['preview_url' => 'https://cdn.test/deck-preview.png'])->save();
    ClientLaneFixtures::actAsAgency($this, $f['user']);

    $data = previewOf($this, 'deck', $f['deck']->id);

    expect($data['total'])->toBe(1)
        ->and($data['blocked_reason'])->toBeNull()
        ->and($data['phases'])->toBe([])
        ->and($data['items'][0])->toMatchArray([
            'subject_key' => null,
            'phase' => null,
            'label' => 'Deck',
            'version_id' => null,
            'thumbnail_url' => 'https://cdn.test/deck-preview.png',
            'snapshot' => null,
            'replaces' => null,
            'round' => 1,
        ]);
});

test('a fresh plan previews one item whose version is its fingerprint', function () {
    $f = ClientLaneFixtures::brandedPlan();
    ClientLaneFixtures::actAsAgency($this, $f['user']);

    $data = previewOf($this, 'campaign', $f['plan']->id);

    expect($data['total'])->toBe(1)
        ->and($data['items'][0]['label'])->toBe('Campaign plan')
        ->and($data['items'][0]['version_id'])->toBe(ApprovalService::fingerprintPlan($f['plan']->fresh()))
        ->and($data['items'][0]['round'])->toBe(1);
});

test('a brand-less deck is blocked with no_brand and cannot be sent', function () {
    $f = ClientLaneFixtures::deck(branded: false);
    ClientLaneFixtures::actAsAgency($this, $f['user']);

    $data = previewOf($this, 'deck', $f['deck']->id);

    expect($data['blocked_reason'])->toBe('no_brand')
        ->and($data['total'])->toBe(0)
        ->and($data['items'])->toBe([]);

    $this->postJson('/api/v1/approval-requests', ['subject_type' => 'deck', 'subject_id' => $f['deck']->id])
        ->assertStatus(422)
        ->assertJsonValidationErrors(['subject_id'])
        ->assertJsonPath('code', 'no_brand'); // mutation: drop `code` from the 422 body → fails
});

test('a deck with three P0a rounds offers round 4 and replaces the pending P0a round 3', function () {
    $f = ClientLaneFixtures::deck();
    $rounds = app(ApprovalService::class);
    foreach (range(1, 3) as $ignored) {
        $rounds->request(ApprovalSubject::from($f['deck']), $f['user'], notify: false);
    }
    ClientLaneFixtures::actAsAgency($this, $f['user']);

    $data = previewOf($this, 'deck', $f['deck']->id);

    expect($data['total'])->toBe(1)
        ->and($data['waiting'])->toBe([])
        ->and($data['items'][0]['round'])->toBe(4)
        ->and($data['items'][0]['replaces'])->toBe(['request_number' => null, 'round' => 3]);
});

test('a pending P0a plan round (manual draft) is replaced, not waited on', function () {
    $f = ClientLaneFixtures::brandedPlan();
    app(ApprovalService::class)->applyPlanStatus($f['plan'], 'draft', $f['user']);
    ClientLaneFixtures::actAsAgency($this, $f['user']);

    $data = previewOf($this, 'campaign', $f['plan']->id);

    expect($data['total'])->toBe(1)
        ->and($data['items'][0]['replaces'])->toBe(['request_number' => null, 'round' => 1]);
});

test('a deck approved on this document is already approved; an edit makes it sendable again', function () {
    $f = ClientLaneFixtures::sendRequest('deck');
    $f['request']->approvals()->update(['status' => Approval::STATUS_APPROVED, 'resolved_at' => now()]);
    ClientLaneFixtures::actAsAgency($this, $f['user']);

    $approved = previewOf($this, 'deck', $f['subject']->id);
    expect($approved['total'])->toBe(0)
        ->and($approved['already_approved'])->toBe([['subject_key' => null, 'phase' => null, 'label' => 'Deck', 'version_id' => null]]);

    $f['subject']->forceFill(['document' => ['schema_version' => 1, 'slides' => [
        ['id' => 's1', 'layout' => 'title', 'elements' => []],
        ['id' => 's2', 'layout' => 'content', 'elements' => []],
    ]]])->save();

    $edited = previewOf($this, 'deck', $f['subject']->id);
    expect($edited['total'])->toBe(1)
        ->and($edited['items'][0]['replaces'])->toBeNull()
        ->and($edited['items'][0]['round'])->toBe(2);
});

test('a plan waiting on request 1 is not offered again until its numbers change', function () {
    $f = ClientLaneFixtures::sendRequest('campaign');
    ClientLaneFixtures::actAsAgency($this, $f['user']);

    $waiting = previewOf($this, 'campaign', $f['subject']->id);
    expect($waiting['total'])->toBe(0)
        ->and($waiting['waiting'][0]['request_number'])->toBe(1);

    // Changed outside the controller, so no reopen-on-edit runs (Task 9).
    $f['subject']->forceFill(['total_budget' => 150_000_000])->saveQuietly();

    $replaces = previewOf($this, 'campaign', $f['subject']->id);
    expect($replaces['total'])->toBe(1)
        ->and($replaces['items'][0]['replaces'])->toBe(['request_number' => 1, 'round' => 1]);
});
```

Mutations (Step 8): (a) delete the S4 line in `classify` → tests 4 and 5 FAIL (`total` 0); (b) delete the `brandId === null` gate in `preview()` → test 3 FAILS (`blocked_reason` null); (c) make `DeckRequestSubject::isCurrent` return `false` → test 6 FAILS (`total` 1 while approved); (d) make `PlanRequestSubject::isCurrent` compare `subject_version_type` only → test 7 FAILS (second preview still `total` 0).

- [ ] **Step 3: Run it to verify it fails**

Run: `DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/DeckPlanRequestPreviewTest.php --compact`
Expected: FAIL — every test `422` on `subject_type` (only `kv_file` is accepted).

- [ ] **Step 4: Write `DeckRequestSubject`**

`app/Services/Approval/Subjects/DeckRequestSubject.php`:

```php
<?php

declare(strict_types=1);

namespace App\Services\Approval\Subjects;

// craftsman-ignore: PHP002 — resolved from the container and swapped in tests.

use App\Models\Approval;
use App\Models\Deck\Deck;
use App\Models\Deck\DeckVersion;
use App\Models\User;
use App\Services\Approval\ApprovalService;
use App\Services\Deck\DeckCollabWriter;
use App\Services\Deck\DeckService;
use App\Services\Deck\DeckStyleCatalog;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Collection;

/**
 * A deck as one approval-request item (spec 2026-10-06 §4.2): the whole
 * deck, frozen as a `deck_versions` row labelled `v{round}` — so a deck's
 * round numbers continue from its P0a rounds (v3 → v4).
 */
class DeckRequestSubject implements ApprovalRequestSubject
{
    public const LABEL = 'Deck';

    public function __construct(
        private readonly DeckCollabWriter $collab,
        private readonly ApprovalService $approvals,
    ) {}

    public function type(): string
    {
        return 'deck';
    }

    public function items(Model $subject, array $filters = []): Collection
    {
        /** @var Deck $subject */
        $document = $this->collab->liveDocumentResolved($subject)['document'] ?? null;
        if (! is_array($document) || $document === []) {
            // Same fallback as ApprovalService::freezeDeckVersion(): the
            // fingerprint is of exactly what a send would freeze.
            $document = $subject->document ?? DeckService::emptyDocument();
        }

        return collect([new RequestItem(
            subjectKey: null,
            phase: null,
            label: self::LABEL,
            versionType: Approval::VERSION_DECK,
            versionId: null,
            thumbnailUrl: $subject->preview_url ?: null,
            fingerprint: self::documentFingerprint($document),
            payload: $document,
        )]);
    }

    public function freezeVersion(Model $subject, RequestItem $item, int $round, User $by): array
    {
        /** @var Deck $subject */
        /** @var array<string, mixed> $document */
        $document = $item->payload;

        return [Approval::VERSION_DECK, (string) $this->approvals->freezeDeckVersion($subject, $round, $by, $document)->id];
    }

    public function snapshot(RequestItem $item): array
    {
        $slides = is_array($item->payload['slides'] ?? null) ? $item->payload['slides'] : [];

        return [
            'kind' => 'deck',
            'label' => $item->label,
            'thumbnail_url' => $item->thumbnailUrl,
            'fingerprint' => $item->fingerprint,
            'slide_count' => count($slides),
        ];
    }

    public function brandId(Model $subject): ?string
    {
        $brandId = $subject->getAttribute('brand_id');

        return $brandId !== null ? (string) $brandId : null;
    }

    /** Ruling S2: the frozen document hashes the same as the live one. */
    public function isCurrent(Approval $approval, RequestItem $item): bool
    {
        if ($approval->subject_version_type !== Approval::VERSION_DECK) {
            return false;
        }
        $frozen = DeckVersion::query()->find((int) $approval->subject_version_id)?->document;

        return is_array($frozen) && self::documentFingerprint($frozen) === $item->fingerprint;
    }

    public function composites(string $subjectId, iterable $snapshots): array
    {
        return [];
    }

    public function thumbnailFields(?array $snapshot, array $composites): array
    {
        return [
            'thumbnail_url' => isset($snapshot['thumbnail_url']) && is_string($snapshot['thumbnail_url']) ? $snapshot['thumbnail_url'] : null,
            'fingerprint' => (string) ($snapshot['fingerprint'] ?? ''),
            'snapshot' => null,
        ];
    }

    public function publicDocument(Collection $approvals, Model $subject, string $brandSlug): array
    {
        /** @var Deck $subject */
        /** @var Approval|null $approval */
        $approval = $approvals->first();
        $frozen = $approval !== null && $approval->subject_version_type === Approval::VERSION_DECK
            ? DeckVersion::query()->find((int) $approval->subject_version_id)?->document
            : null;
        $document = is_array($frozen) ? $frozen : ($subject->document ?? DeckService::emptyDocument());

        return ['document' => $document, 'extra' => ['deck' => self::renderContext($subject, $document)]];
    }

    public function itemsNoun(int $count): string
    {
        return 'deck';
    }

    /**
     * What the slide renderer needs beside the document — the same keys
     * `PublicDeckController::show` returns beside `deck.document`.
     *
     * @param  array<string, mixed>  $document
     * @return array{theme: mixed, slide_themes: mixed, play_settings: mixed}
     */
    public static function renderContext(Deck $deck, array $document): array
    {
        $deck->loadMissing('theme');

        return [
            'theme' => $deck->theme,
            'slide_themes' => app(DeckStyleCatalog::class)->slideThemesPayload($deck, $document, $deck->theme),
            'play_settings' => $deck->play_settings,
        ];
    }

    /**
     * Content hash of a deck document, canonicalised so a jsonb round-trip
     * (reordered object keys, `1.0` read back as `1`) hashes the same as
     * the live document.
     *
     * @param  array<string, mixed>  $document
     */
    public static function documentFingerprint(array $document): string
    {
        return hash('sha256', (string) json_encode(self::canonical($document), JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE));
    }

    private static function canonical(mixed $value): mixed
    {
        if (is_float($value) && floor($value) === $value && abs($value) < PHP_INT_MAX) {
            return (int) $value;
        }
        if (! is_array($value)) {
            return $value;
        }
        if (! array_is_list($value)) {
            ksort($value);
        }

        return array_map([self::class, 'canonical'], $value);
    }
}
```

- [ ] **Step 5: Write `PlanRequestSubject`**

`app/Services/Approval/Subjects/PlanRequestSubject.php`:

```php
<?php

declare(strict_types=1);

namespace App\Services\Approval\Subjects;

// craftsman-ignore: PHP002 — resolved from the container and swapped in tests.

use App\Http\Controllers\Api\PublicCampaignPlanController;
use App\Models\Approval;
use App\Models\Brand;
use App\Models\CampaignPlan;
use App\Models\User;
use App\Services\Approval\ApprovalService;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Collection;

/**
 * A campaign plan as one approval-request item (spec 2026-10-06 §4.2):
 * version = the plan's content fingerprint, as for P0a plan rounds.
 */
class PlanRequestSubject implements ApprovalRequestSubject
{
    public const LABEL = 'Campaign plan';

    public function type(): string
    {
        return 'campaign';
    }

    public function items(Model $subject, array $filters = []): Collection
    {
        /** @var CampaignPlan $subject */
        $fingerprint = ApprovalService::fingerprintPlan($subject);

        return collect([new RequestItem(
            subjectKey: null,
            phase: null,
            label: self::LABEL,
            versionType: Approval::VERSION_FINGERPRINT,
            versionId: $fingerprint,
            thumbnailUrl: $subject->thumbnail_url ?: null,
            fingerprint: $fingerprint,
        )]);
    }

    public function freezeVersion(Model $subject, RequestItem $item, int $round, User $by): array
    {
        return [Approval::VERSION_FINGERPRINT, (string) $item->versionId];
    }

    public function snapshot(RequestItem $item): array
    {
        return [
            'kind' => 'campaign',
            'label' => $item->label,
            'thumbnail_url' => $item->thumbnailUrl,
            'fingerprint' => $item->fingerprint,
        ];
    }

    public function brandId(Model $subject): ?string
    {
        $brandId = $subject->getAttribute('brand_id');

        return $brandId !== null ? (string) $brandId : null;
    }

    public function isCurrent(Approval $approval, RequestItem $item): bool
    {
        return $approval->subject_version_type === Approval::VERSION_FINGERPRINT
            && (string) $approval->subject_version_id === $item->fingerprint;
    }

    public function composites(string $subjectId, iterable $snapshots): array
    {
        return [];
    }

    public function thumbnailFields(?array $snapshot, array $composites): array
    {
        return [
            'thumbnail_url' => isset($snapshot['thumbnail_url']) && is_string($snapshot['thumbnail_url']) ? $snapshot['thumbnail_url'] : null,
            'fingerprint' => (string) ($snapshot['fingerprint'] ?? ''),
            'snapshot' => null,
        ];
    }

    public function publicDocument(Collection $approvals, Model $subject, string $brandSlug): array
    {
        /** @var CampaignPlan $subject */
        // Scopes stripped so demo brands surface their name to signed-out
        // viewers — as the round branch and PublicCampaignPlanController do.
        $subject->setRelation('brand', Brand::query()->withoutGlobalScopes()->select('id', 'name')->find($subject->brand_id));

        return ['document' => PublicCampaignPlanController::projection($subject), 'extra' => []];
    }

    public function itemsNoun(int $count): string
    {
        return 'campaign plan';
    }
}
```

- [ ] **Step 6: Register them; widen `SUBJECT_TYPES`**

`ApprovalRequestSubjects` constructor:

```php
    public function __construct(KvRequestSubject $kv, DeckRequestSubject $deck, PlanRequestSubject $plan)
    {
        $this->byType = ['kv_file' => $kv, 'deck' => $deck, 'campaign' => $plan];
    }
```

`app/Models/ApprovalRequest.php`: replace the constant and its comment:

```php
    /** Every approvable subject (spec 2026-10-06 §4.1); one request is for one subject. */
    public const SUBJECT_TYPES = ['kv_file', 'deck', 'campaign'];
```

and the class docblock's first sentence: "What the agency sent together in one "Request approval" on a KV file, deck or campaign plan (KV spec 2026-10-01 §4.1; spec 2026-10-06 §4.1): …". In the `approvals()` docblock: "One approval per item per round."

- [ ] **Step 7: Preview — S4 rule, `round`, `blocked_reason`**

`ApprovalRequestPreview`: add the constant, the property, the factory, and the two keys (both appended last, so existing keys keep their order):

```php
    public const NO_BRAND = 'no_brand';
```

Constructor gains a fifth parameter `public ?string $blockedReason = null,`; the `eligible` docblock entry type gains `round: int`. Add:

```php
    /** Nothing can be sent, and why (spec 2026-10-06 §4.3). */
    public static function blocked(string $reason): self
    {
        return new self([], [], [], [], $reason);
    }
```

In `toArray()`: in the `items` map add `'round' => $entry['round'],` after `'replaces' => …`; after `'total' => $this->total(),` add `'blocked_reason' => $this->blockedReason,`. Update the `@return` shape accordingly.

`ApprovalRequestPreviewService::preview()`: right after `$adapter = …`:

```php
        if ($adapter->brandId($subject) === null) {
            // A brand-less deck: say why instead of offering a Request button
            // that 422s (spec 2026-10-06 §4.3, Jeff's handoff item).
            return ApprovalRequestPreview::blocked(ApprovalRequestPreview::NO_BRAND);
        }
```

and change the eligible append to carry the round:

```php
            if ($verdict === self::ELIGIBLE) {
                $eligible[] = [
                    'item' => $item,
                    'previous' => $previous?->isPending() ? $previous : null,
                    // The round this send creates (ruling S5): a deck's `v{round}`.
                    'round' => ($previous?->round ?? 0) + 1,
                ];
```

`classify()`:

```php
    public static function classify(ApprovalRequestSubject $adapter, RequestItem $item, ?Approval $latest): string
    {
        if ($latest === null) {
            return self::ELIGIBLE;
        }
        // Ruling S4: a pending P0a round (deck/plan) is always replaced by a
        // request, never waited on — whatever its version.
        if ($latest->isPending() && $latest->approval_request_id === null) {
            return self::ELIGIBLE;
        }
        if (! $adapter->isCurrent($latest, $item)) {
            return self::ELIGIBLE;
        }
```

(rest unchanged).

- [ ] **Step 8: Run the new test and the KV gate**

Run: `DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/DeckPlanRequestPreviewTest.php --compact`
Expected: PASS (7 tests). Then apply mutations (a)–(d) from Step 2 one at a time; each named test must FAIL; restore; green.

Run: `DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/KvRequestCharacterizationTest.php --compact`
Expected: FAIL at `kv-preview` — the two additive keys (S5). This is the one intended KV change.

- [ ] **Step 9: Re-record the KV preview fixtures and prove the diff is additive only**

Run the Task 1 Step 4 record command once (with `SNAPSHOT_UPDATE=1`; it rewrites all ten files and ends `1 incomplete`), then:

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-deck-plan-requests && /usr/bin/git diff --stat tests/Fixtures/approval-requests && /usr/bin/git diff -U0 tests/Fixtures/approval-requests | /usr/bin/grep '^[-+] ' | /usr/bin/grep -v -E '^\+ +"(round|blocked_reason)": ' ; echo "exit=$?"
```

Expected: only `kv-preview.json`, `kv-preview-waiting.json`, `kv-preview-replaces.json` changed, and the filtered diff prints nothing but trailing-comma adjustments (a `-`/`+` pair of the same line where a `,` was added after the previous last key). Any other changed line is a regression — fix the code, not the fixture. Then run the characterization test without `SNAPSHOT_UPDATE` → PASS.

- [ ] **Step 10: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-deck-plan-requests && F="app/Services/Approval/Subjects/DeckRequestSubject.php app/Services/Approval/Subjects/PlanRequestSubject.php app/Services/Approval/Subjects/ApprovalRequestSubjects.php app/Models/ApprovalRequest.php app/Services/Approval/ApprovalRequestPreview.php app/Services/Approval/ApprovalRequestPreviewService.php tests/Support/ClientLaneFixtures.php tests/Feature/Approval/DeckPlanRequestPreviewTest.php" && for f in ${=F}; do php -l $f || exit 1; done && vendor/bin/pint ${=F} && vendor/bin/pint --test ${=F} && /usr/bin/git add ${=F} tests/Fixtures/approval-requests && /usr/bin/git commit -m "feat(api): accept deck and campaign plan subjects in approval-request previews"
```

---

### Task 5: Send for deck and plan — own link outside the cap, v3 → v4, supersede

**Files:**
- Modify: `app/Http/Controllers/Api/Deck/DeckShareLinkController.php` (`index`, `findLinkForDeck` → `forSharing()`)
- Test: `tests/Feature/Approval/DeckPlanRequestSendTest.php`

**Interfaces:**
- Consumes: Task 3's generic `create()`, Task 4's adapters and fixtures, `ShareLinkService::create(...)`, `ShareLink::scopeCountingAgainstLimit`, `ShareLink::scopeForSharing`.
- Produces: no new symbols; S12 behaviour on `v1/decks/{deck}/share-links`.

`create()` is already generic (Task 3); this task proves it for decks/plans and fixes the one leak (approval links listed as deck view links).

- [ ] **Step 1: Write the failing test**

`tests/Feature/Approval/DeckPlanRequestSendTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Exceptions\Approval\NothingReadyException;
use App\Models\Approval;
use App\Models\ApprovalRequest;
use App\Models\Deck\DeckVersion;
use App\Models\ShareLink;
use App\Services\Approval\ApprovalService;
use App\Services\Approval\ApprovalSubject;
use App\Services\Sharing\ShareLinkService;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Mail;
use Illuminate\Support\Str;
use Tests\Support\ClientLaneFixtures;

/**
 * Sending a deck or plan request (spec 2026-10-06 §4.4, §8): its own
 * approval link outside the view-link cap, rounds continuing from P0a
 * (v3 → v4), and supersede of a pending P0a round or request approval.
 */
beforeEach(function () {
    Mail::fake();
});

test('sending a deck request freezes v1 and mints its own approval link', function () {
    $f = ClientLaneFixtures::deck();
    ClientLaneFixtures::actAsAgency($this, $f['user']);

    $data = $this->postJson('/api/v1/approval-requests', ['subject_type' => 'deck', 'subject_id' => $f['deck']->id, 'message' => 'Final cut'])
        ->assertCreated()
        ->json('data');

    expect($data['request']['number'])->toBe(1)
        ->and($data['request']['status'])->toBe('pending')
        ->and($data['request']['approvals'])->toHaveCount(1)
        ->and($data['request']['approvals'][0])->toMatchArray(['subject_key' => null, 'phase' => null, 'label' => 'Deck', 'round' => 1, 'status' => 'pending']);

    $version = DeckVersion::query()->where('deck_id', $f['deck']->id)->sole();
    expect($version->label)->toBe('v1')
        ->and($version->source)->toBe(DeckVersion::SOURCE_APPROVAL_REQUEST)
        ->and($data['request']['approvals'][0]['version_id'])->toBe((string) $version->id);

    $link = ShareLink::query()->where('token', Str::afterLast($data['share_url'], '/s/'))->sole();
    expect($link->purpose)->toBe(ShareLink::PURPOSE_APPROVAL)
        ->and($link->role)->toBe(ShareLink::ROLE_COMMENT);
});

test('a deck with three view links still sends; the approval link is neither counted nor listed', function () {
    $f = ClientLaneFixtures::deck();
    foreach (range(1, 3) as $n) {
        app(ShareLinkService::class)->create(shareable: $f['deck'], creator: $f['user'], phases: [], label: "View {$n}", expiresIn: null);
    }
    ClientLaneFixtures::actAsAgency($this, $f['user']);

    $this->postJson('/api/v1/approval-requests', ['subject_type' => 'deck', 'subject_id' => $f['deck']->id])->assertCreated();

    $counted = ShareLink::query()
        ->where('shareable_type', 'deck')->where('shareable_id', $f['deck']->id)
        ->countingAgainstLimit()->count();
    expect($counted)->toBe(3);
    $this->getJson("/api/v1/decks/{$f['deck']->id}/share-links")->assertOk()->assertJsonCount(3, 'data');
});

test('rounds continue from P0a: the request is round 4 (v4) and closes the pending P0a round 3', function () {
    $f = ClientLaneFixtures::deck();
    $p0a = null;
    foreach (range(1, 3) as $ignored) {
        $p0a = app(ApprovalService::class)->request(ApprovalSubject::from($f['deck']), $f['user'], notify: false);
    }
    $round3 = $p0a['approval'];
    ClientLaneFixtures::actAsAgency($this, $f['user']);

    $data = $this->postJson('/api/v1/approval-requests', ['subject_type' => 'deck', 'subject_id' => $f['deck']->id])
        ->assertCreated()->json('data');

    $approval = Approval::query()->findOrFail($data['request']['approvals'][0]['id']);
    expect($approval->round)->toBe(4)
        ->and($approval->supersedes_approval_id)->toBe($round3->id)
        ->and($round3->fresh()->status)->toBe(Approval::STATUS_NOT_RELEVANT)
        ->and(DeckVersion::query()->findOrFail((int) $approval->subject_version_id)->label)->toBe('v4');

    // The old round's link now shows that round as closed (§4.4).
    $this->getJson('/api/public/share-links/'.$p0a['share_link']->token)
        ->assertOk()
        ->assertJsonPath('data.approval', null)
        ->assertJsonPath('data.access.can_decide', false);
});

test('a second deck request replaces the first one\'s pending approval and re-rolls request 1', function () {
    $f = ClientLaneFixtures::sendRequest('deck');
    $f['subject']->forceFill(['document' => ['schema_version' => 1, 'slides' => [
        ['id' => 's1', 'layout' => 'title', 'elements' => []],
        ['id' => 's2', 'layout' => 'content', 'elements' => []],
    ]]])->save();
    ClientLaneFixtures::actAsAgency($this, $f['user']);

    $this->postJson('/api/v1/approval-requests', ['subject_type' => 'deck', 'subject_id' => $f['subject']->id])->assertCreated();

    expect($f['request']->fresh()->status)->toBe(Approval::STATUS_NOT_RELEVANT);
    $index = $this->getJson('/api/v1/approval-requests?'.http_build_query(['subject_type' => 'deck', 'subject_id' => $f['subject']->id]))
        ->assertOk()->json('data');
    expect(collect($index)->pluck('number')->all())->toBe([2, 1])
        ->and($index[1]['counts']['superseded'])->toBe(1)
        ->and($index[1]['approvals'][0]['superseded_by_request_number'])->toBe(2);
});

test('an unchanged deck waiting on a request has nothing ready to send', function () {
    $f = ClientLaneFixtures::sendRequest('deck');
    ClientLaneFixtures::actAsAgency($this, $f['user']);

    $this->postJson('/api/v1/approval-requests', ['subject_type' => 'deck', 'subject_id' => $f['subject']->id])
        ->assertStatus(422)
        ->assertJsonPath('code', NothingReadyException::CODE);
});

test('a plan request lists with its fingerprint version and the Campaign plan label', function () {
    $f = ClientLaneFixtures::sendRequest('campaign');
    ClientLaneFixtures::actAsAgency($this, $f['user']);

    $index = $this->getJson('/api/v1/approval-requests?'.http_build_query(['subject_type' => 'campaign', 'subject_id' => $f['subject']->id]))
        ->assertOk()->json('data');

    expect($index)->toHaveCount(1)
        ->and($index[0]['approvals'][0]['label'])->toBe('Campaign plan')
        ->and($index[0]['approvals'][0]['version_id'])->toBe(ApprovalService::fingerprintPlan($f['subject']->fresh()))
        ->and(ApprovalRequest::query()->sole()->subject_type)->toBe('campaign');
});

test('an unreachable collab server falls back to the stored document for both hash and freeze', function () {
    $f = ClientLaneFixtures::deck();
    config(['services.collab.url' => 'http://collab.test']);
    Http::fake(['collab.test/*' => Http::response('', 500)]);
    ClientLaneFixtures::actAsAgency($this, $f['user']);

    $this->getJson('/api/v1/approval-requests/preview?'.http_build_query(['subject_type' => 'deck', 'subject_id' => $f['deck']->id]))
        ->assertOk()->assertJsonPath('data.total', 1);
    $this->postJson('/api/v1/approval-requests', ['subject_type' => 'deck', 'subject_id' => $f['deck']->id])->assertCreated();

    expect(DeckVersion::query()->where('deck_id', $f['deck']->id)->sole()->document)->toBe($f['deck']->fresh()->document);
});
```

Mutations (Step 5): (a) remove `->forSharing()` from `DeckShareLinkController::index` → test 2 FAILS (4 links listed); (b) in `Approval::scopeForSubjectKeys` replace the body with `return $query->whereIn('subject_key', $keys);` → test 3 FAILS (`409 round_conflict` — round 1 collides with P0a round 1); (c) in `ApprovalRequestService::create` delete `$this->recalculate($other);` → test 4 FAILS (request 1 stays `pending`).

- [ ] **Step 2: Run it to verify it fails**

Run: `DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/DeckPlanRequestSendTest.php --compact`
Expected: test 2 FAILS (`assertJsonCount(3)` gets 4 — the approval link is listed); the others pass already (Task 3/4 made `create()` generic). If test 7 fails on `Http::fake` not intercepting, read `DeckCollabWriter::collabRequest()`: it must be built on the `Http` facade — if it is not, replace the fake with `config(['services.collab.url' => 'http://127.0.0.1:9'])` (closed port, refused at once) and note it in the track log.

- [ ] **Step 3: Implement S12 in `DeckShareLinkController`**

In `index()` add `->forSharing()` after `->where('shareable_id', $deck->id)`, and add this comment above the query: `// A request's own purpose = approval link is not a view link (spec 2026-10-06 §4.4, ruling S12).` In `findLinkForDeck()` add `->forSharing()` after its `->where('shareable_id', $deck->id)` (PATCH/DELETE on an approval link → 404, as KV R12).

- [ ] **Step 4: Run to verify it passes**

Run the Step 2 command. Expected: PASS (7 tests). Then the regression: `DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Deck/DeckShareLinkTest.php tests/Feature/Approval/KvRequestCharacterizationTest.php --compact` → baseline-equal.

- [ ] **Step 5: Mutation checks** — (a), (b), (c) from Step 1, one at a time; restore; green.

- [ ] **Step 6: Gates and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-deck-plan-requests && F="app/Http/Controllers/Api/Deck/DeckShareLinkController.php tests/Feature/Approval/DeckPlanRequestSendTest.php" && for f in ${=F}; do php -l $f || exit 1; done && vendor/bin/pint ${=F} && vendor/bin/pint --test ${=F} && /usr/bin/git add ${=F} && /usr/bin/git commit -m "feat(api): send deck and plan approval requests with their own link outside the cap"
```

---

### Task 6: The public page and decisions for deck and plan requests

**Files:**
- Modify: `app/Http/Controllers/Api/PublicShareLinkController.php` (`deckRenderContext` delegates to `DeckRequestSubject::renderContext`)
- Test: `tests/Feature/Approval/DeckPlanRequestPublicTest.php`

**Interfaces:**
- Consumes: `ApprovalRequestPresenter::publicPayload(...)` + `extra` merge (Task 3), `DeckRequestSubject::renderContext` / `publicDocument` (Task 4), `PlanRequestSubject::publicDocument`.
- Produces: the public deck/plan request payload in the API contract section.

- [ ] **Step 1: Write the failing test**

`tests/Feature/Approval/DeckPlanRequestPublicTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Jobs\SendApprovalRequestDigest;
use App\Models\Approval;
use App\Models\Deck\DeckVersion;
use Illuminate\Support\Facades\Bus;
use Illuminate\Support\Facades\Mail;
use Tests\Support\ClientLaneFixtures;

/**
 * The client page for a deck or plan request (spec 2026-10-06 §4.9, §6.3):
 * the frozen document and the deck render context, pins on the request's
 * version, and the one pins/decision rule.
 */
beforeEach(function () {
    Mail::fake();
    Bus::fake([SendApprovalRequestDigest::class]);
});

test('a deck request link serves the frozen document and the deck render context', function () {
    $f = ClientLaneFixtures::sendRequest('deck');
    $token = $f['link']->token;
    $approval = $f['request']->approvals()->sole();

    // An edit after sending never changes the page.
    $f['subject']->forceFill(['document' => ['schema_version' => 1, 'slides' => [
        ['id' => 's1', 'layout' => 'title', 'elements' => []],
        ['id' => 's2', 'layout' => 'content', 'elements' => []],
    ]]])->save();

    $data = $this->getJson("/api/public/share-links/{$token}")->assertOk()->json('data');

    expect($data['type'])->toBe('deck')
        ->and($data['version'])->toMatchArray(['type' => 'approval_request', 'label' => 'Request 1'])
        ->and($data['document'])->toBe(DeckVersion::query()->findOrFail((int) $approval->subject_version_id)->document)
        ->and($data['document']['slides'])->toHaveCount(1)
        ->and(array_keys($data['deck']))->toBe(['theme', 'slide_themes', 'play_settings'])
        ->and($data['items'][0])->toMatchArray(['label' => 'Deck', 'phase' => null, 'version_id' => (string) $approval->subject_version_id])
        ->and($data['items'][0]['snapshot'])->toMatchArray(['kind' => 'deck', 'slide_count' => 1])
        ->and($data['approvals'][0]['round'])->toBe(1)
        ->and($data['approval'])->toBeNull()
        ->and($data['access'])->toMatchArray(['can_decide' => true, 'verification_required' => true]);
});

test('a plan request link serves the plan projection and no deck context', function () {
    $f = ClientLaneFixtures::sendRequest('campaign');

    $this->getJson("/api/public/share-links/{$f['link']->token}")
        ->assertOk()
        ->assertJsonPath('data.type', 'campaign')
        ->assertJsonPath('data.document.id', $f['subject']->id)
        ->assertJsonPath('data.document.name', 'Ramadan 2027 media plan')
        ->assertJsonPath('data.items.0.label', 'Campaign plan')
        ->assertJsonMissingPath('data.deck');
});

test('a client pins the deck version and sends the pins as changes, no note needed', function () {
    $f = ClientLaneFixtures::sendRequest('deck');
    $lane = ClientLaneFixtures::verifiedGuestLane($f['brand']);
    $approval = $f['request']->approvals()->sole();
    $token = $f['link']->token;

    $pin = $this->withHeader('X-Lane-Code', $lane->unique_code)
        ->postJson("/api/public/share-links/{$token}/comments", [
            'body' => 'Make the logo bigger',
            'anchor' => ['kind' => 'pin', 'id' => "slide:{$approval->subject_version_id}:s1", 'x' => 0.5, 'y' => 0.5],
        ])->assertCreated()->json('data.id');

    $this->withHeader('X-Lane-Code', $lane->unique_code)
        ->postJson("/api/public/share-links/{$token}/decision", [
            'outcome' => 'changes_required',
            'approval_ids' => [$approval->id],
            'pins' => [$pin],
        ])->assertCreated()
        ->assertJsonPath('data.results.0.result', 'decided')
        ->assertJsonPath('data.request.status', 'changes_required');

    expect($approval->fresh()->status)->toBe(Approval::STATUS_CHANGES_REQUIRED);
});

test('approving a plan with your own pins on it is stored as approved with changes', function () {
    $f = ClientLaneFixtures::sendRequest('campaign');
    $lane = ClientLaneFixtures::verifiedGuestLane($f['brand']);
    $approval = $f['request']->approvals()->sole();
    $token = $f['link']->token;

    $pin = $this->withHeader('X-Lane-Code', $lane->unique_code)
        ->postJson("/api/public/share-links/{$token}/comments", [
            'body' => 'Shift 5% from paid social to digital',
            'anchor' => ['kind' => 'pin', 'id' => "plan:{$approval->subject_version_id}:allocation", 'x' => 0.2, 'y' => 0.4],
        ])->assertCreated()->json('data.id');

    $this->withHeader('X-Lane-Code', $lane->unique_code)
        ->postJson("/api/public/share-links/{$token}/decision", ['outcome' => 'approved', 'approval_ids' => [$approval->id], 'pins' => [$pin]])
        ->assertCreated();

    expect($approval->fresh()->status)->toBe(Approval::STATUS_APPROVED_WITH_CHANGES);
});
```

Mutations (Step 5): (a) in `DeckRequestSubject::publicDocument` return the live `$subject->document` instead of `$frozen` → test 1 FAILS (2 slides); (b) in `DeckRequestSubject::freezeVersion` return `[Approval::VERSION_FINGERPRINT, $item->fingerprint]` → test 3 FAILS (`DeckVersion::findOrFail` in test 1 / the pin anchor's version no longer matches → `422 invalid_anchor` in test 3); (c) in `PublicShareLinkController::show` delete `...$payload['extra'],` → test 1 FAILS (no `deck` key).

- [ ] **Step 2: Run it**

Run: `DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/DeckPlanRequestPublicTest.php --compact`
Expected: PASS already — Tasks 3–4 built the payload. Prove the tests are not vacuous with mutations (a)–(c) BEFORE Step 3 (each must FAIL), restore.

- [ ] **Step 3: Remove the duplicate render-context body**

In `PublicShareLinkController`, replace the body of `private function deckRenderContext(Deck $deck, array $document): array` with:

```php
        return DeckRequestSubject::renderContext($deck, $document);
```

Add `use App\Services\Approval\Subjects\DeckRequestSubject;`; remove `use App\Services\Deck\DeckStyleCatalog;` if pint reports it unused.

- [ ] **Step 4: Run to verify nothing moved**

Run: `DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/DeckPlanRequestPublicTest.php tests/Feature/Approval/KvRequestCharacterizationTest.php tests/Feature/Approval/DeckPlanRequestSendTest.php --compact`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-deck-plan-requests && F="app/Http/Controllers/Api/PublicShareLinkController.php tests/Feature/Approval/DeckPlanRequestPublicTest.php" && for f in ${=F}; do php -l $f || exit 1; done && vendor/bin/pint ${=F} && vendor/bin/pint --test ${=F} && /usr/bin/git add ${=F} && /usr/bin/git commit -m "feat(api): serve deck and plan approval requests on the client page"
```

---

### Task 7: One verification rule for every request link

**Files:**
- Modify: `app/Http/Controllers/Api/PublicLaneController.php` (`magicLink`: `forSharing()`)
- Test: `tests/Feature/Approval/RequestVerificationTest.php`

**Interfaces:**
- Consumes: `ClientVerificationCodeService::{request, verify}` (already type-agnostic: its `approvalLink()` checks only `purpose = approval` + `role = comment`), `ClientVerificationCode::hashCode(string $code): string`, `ClientVerificationCodeMail`, `ClientMagicLinkMail`, fixtures from Task 4.
- Produces: S13.

- [ ] **Step 1: Write the failing test**

`tests/Feature/Approval/RequestVerificationTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Jobs\SendApprovalRequestDigest;
use App\Mail\ClientMagicLinkMail;
use App\Mail\ClientVerificationCodeMail;
use App\Models\ApprovalDecision;
use App\Models\ClientVerificationCode;
use App\Services\Approval\ApprovalService;
use App\Services\Approval\ApprovalSubject;
use Illuminate\Support\Facades\Bus;
use Illuminate\Support\Facades\Mail;
use Tests\Support\ClientLaneFixtures;

/**
 * Spec 2026-10-06 §4.6 / E-7: a decision on any request link needs a
 * personal link or a 6-digit code once per device; looking needs nothing.
 * Magic links stay for P0a round links only (S13).
 */
beforeEach(function () {
    Mail::fake();
    Bus::fake([SendApprovalRequestDigest::class]);
});

test('a decision without a lane is refused with verification_required and records nothing', function (string $type) {
    $f = ClientLaneFixtures::sendRequest($type);
    $approval = $f['request']->approvals()->firstOrFail();

    $this->postJson("/api/public/share-links/{$f['link']->token}/decision", [
        'outcome' => 'approved',
        'approval_ids' => [$approval->id],
        'guest_name' => 'Dina',
        'guest_email' => 'dina@brand.test',
    ])->assertStatus(403)->assertJsonPath('code', 'verification_required');

    expect(ApprovalDecision::query()->count())->toBe(0);
})->with(['kv_file', 'deck', 'campaign']);

test('a code is mailed for a deck or plan request link, and the spent code decides', function (string $type) {
    $f = ClientLaneFixtures::sendRequest($type);
    $token = $f['link']->token;

    $this->postJson('/api/public/lane/code', ['email' => 'bayu@brand.test', 'share_token' => $token])->assertStatus(202);
    Mail::assertQueued(ClientVerificationCodeMail::class);

    // The mailed code is only stored hashed; plant a known one. verify()
    // checks only the newest live row (created_at, then id) — ULIDs minted
    // in the same millisecond do not sort reliably, so date it a minute on.
    $planted = ClientVerificationCode::create([
        'email' => 'bayu@brand.test',
        'brand_id' => (string) $f['request']->brand_id,
        'share_link_id' => (string) $f['link']->id,
        'code_hash' => ClientVerificationCode::hashCode('246810'),
        'attempts' => 0,
        'expires_at' => now()->addMinutes(ClientVerificationCode::TTL_MINUTES),
    ]);
    $planted->forceFill(['created_at' => now()->addMinute()])->save();
    $laneCode = $this->postJson('/api/public/lane/code/verify', ['email' => 'bayu@brand.test', 'code' => '246810', 'share_token' => $token])
        ->assertOk()->json('data.lane_code');

    $this->withHeader('X-Lane-Code', $laneCode)
        ->postJson("/api/public/share-links/{$token}/decision", ['outcome' => 'approved', 'approval_ids' => [$f['request']->approvals()->sole()->id]])
        ->assertCreated()
        ->assertJsonPath('data.results.0.decision.actor_kind', 'client');
})->with(['deck', 'campaign']);

test('a named approver\'s personal link decides without a code', function (string $type) {
    $f = ClientLaneFixtures::sendRequest($type);
    $lane = ClientLaneFixtures::personalLane($f['brand']);

    $this->withHeader('X-Lane-Code', $lane->unique_code)
        ->postJson("/api/public/share-links/{$f['link']->token}/decision", ['outcome' => 'approved', 'approval_ids' => [$f['request']->approvals()->sole()->id]])
        ->assertCreated()
        ->assertJsonPath('data.results.0.decision.actor_kind', 'user')
        ->assertJsonPath('data.request.status', 'approved');
})->with(['deck', 'campaign']);

test('a magic link is never sent for a request link, still for a P0a round link', function () {
    $f = ClientLaneFixtures::sendRequest('campaign');

    $this->postJson('/api/public/lane/magic-link', ['email' => 'dina@brand.test', 'share_token' => $f['link']->token])->assertStatus(202);
    Mail::assertNotQueued(ClientMagicLinkMail::class);

    $round = app(ApprovalService::class)->request(ApprovalSubject::from($f['subject']), $f['user'], notify: false);
    $this->postJson('/api/public/lane/magic-link', ['email' => 'dina@brand.test', 'share_token' => $round['share_link']->token])->assertStatus(202);
    Mail::assertQueued(ClientMagicLinkMail::class);
});
```

Mutations (Step 5): (a) in `ClientVerificationCodeService::approvalLink()` add `&& $link->shareable_type === 'kv_file'` → test 2 FAILS (no mail, verify `422 code_expired`); (b) remove `->forSharing()` from `PublicLaneController::magicLink` → test 4 FAILS; (c) in `PublicShareLinkController::decideOnRequest` delete the `if ($lane === null) { return … 403 … }` block → test 1 FAILS for every type.

- [ ] **Step 2: Run to verify it fails**

Run: `DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/RequestVerificationTest.php --compact`
Expected: only test 4 FAILS (`ClientMagicLinkMail` queued for the request link). Tests 1–3 pass already (verification is type-agnostic since Part D); prove them with mutations (a) and (c) now.

- [ ] **Step 3: Implement S13 in `PublicLaneController::magicLink`**

```php
        // Magic links stay for P0a round links (spec 2026-10-06 §4.6): a
        // request link verifies with a 6-digit code instead.
        $link = ShareLink::query()
            ->where('token', $validated['share_token'])
            ->whereIn('shareable_type', Approval::SUBJECT_TYPES)
            ->forSharing()
            ->active()
            ->first();
```

- [ ] **Step 4: Run to verify it passes** — Step 2 command → PASS (8 tests incl. datasets).

- [ ] **Step 5: Mutation checks** — (b) now; (a) and (c) were done in Step 2. Restore; green.

- [ ] **Step 6: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-deck-plan-requests && F="app/Http/Controllers/Api/PublicLaneController.php tests/Feature/Approval/RequestVerificationTest.php" && for f in ${=F}; do php -l $f || exit 1; done && vendor/bin/pint ${=F} && vendor/bin/pint --test ${=F} && /usr/bin/git add ${=F} && /usr/bin/git commit -m "feat(api): one verification rule for deck, plan and KV request links"
```

---

### Task 8: Notifier copy names the subject type

**Files:**
- Modify: `app/Services/Approval/ApprovalNotifier.php` (`requestSent`, `requestResent`, `requestLabel`)
- Modify: `app/Services/Approval/ApprovalRequestService.php` (pass the noun on send and resend)
- Test: `tests/Feature/Approval/RequestNotifierCopyTest.php`

**Interfaces:**
- Consumes: `ApprovalRequestSubject::itemsNoun(int $count): string` (Task 2/4).
- Produces (signature changes):
  - `ApprovalNotifier::requestSent(ApprovalRequest $request, ApprovalSubject $subject, ShareLink $link, User $requester, array $approvers, string $itemsNoun): array`
  - `ApprovalNotifier::requestResent(ApprovalRequest $request, ApprovalSubject $subject, ShareLink $link, User $requester, array $approvers, string $itemsNoun): array`
  - `ApprovalNotifier::requestLabel(int $number, string $itemsNoun): string` → `"Request 2 · 6 artboards"`, `"Request 2 · deck"`, `"Request 2 · campaign plan"`.

The notifier does NOT take the registry: `ApprovalNotifier` ← `ApprovalService` ← `DeckRequestSubject` ← registry would be a constructor cycle. The service passes the noun in.

- [ ] **Step 1: Write the failing test**

`tests/Feature/Approval/RequestNotifierCopyTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Jobs\SendApprovalRequestDigest;
use App\Mail\ApprovalRequestDigestMail;
use App\Services\Approval\ApprovalActor;
use App\Services\Approval\ApprovalNotifier;
use App\Services\Approval\ApprovalRequestDecisionService;
use App\Services\Approval\ApprovalRequestService;
use Illuminate\Support\Facades\Bus;
use Illuminate\Support\Facades\Mail;
use Tests\Support\ClientLaneFixtures;

/**
 * Spec 2026-10-06 §4.7: deck and plan requests use the KV request
 * notifier; the copy names the subject type.
 */
beforeEach(function () {
    Mail::fake();
    Bus::fake([SendApprovalRequestDigest::class]);
});

test('the request label names artboards, the deck or the campaign plan', function () {
    expect(ApprovalNotifier::requestLabel(2, '6 artboards'))->toBe('Request 2 · 6 artboards')
        ->and(ApprovalNotifier::requestLabel(2, 'deck'))->toBe('Request 2 · deck')
        ->and(ApprovalNotifier::requestLabel(3, 'campaign plan'))->toBe('Request 3 · campaign plan');
});

test('sending passes the subject type\'s noun to the notifier', function (string $type, string $noun) {
    $spy = Mockery::spy(ApprovalNotifier::class);
    app()->instance(ApprovalNotifier::class, $spy);
    $f = match ($type) {
        'kv_file' => ClientLaneFixtures::readyKvFile(),
        'deck' => ClientLaneFixtures::deck(),
        'campaign' => ClientLaneFixtures::brandedPlan(),
    };

    app(ApprovalRequestService::class)->create($f['subject'], $f['user']);

    $spy->shouldHaveReceived('requestSent')->once()->withArgs(
        fn ($request, $subject, $link, $requester, $approvers, $itemsNoun): bool => $itemsNoun === $noun,
    );
})->with([
    ['kv_file', '1 artboard'],
    ['deck', 'deck'],
    ['campaign', 'campaign plan'],
]);

test('a decided deck request digests as "Deck — Approved"', function () {
    $f = ClientLaneFixtures::sendRequest('deck');
    $lane = ClientLaneFixtures::verifiedGuestLane($f['brand']);

    app(ApprovalRequestDecisionService::class)->decide(
        $f['request'],
        ApprovalActor::guest('Bayu', 'bayu@brand.test', $lane),
        ['outcome' => 'approved', 'approval_ids' => [(string) $f['request']->approvals()->sole()->id]],
    );

    Mail::assertQueued(ApprovalRequestDigestMail::class, fn (ApprovalRequestDigestMail $mail): bool => $mail->lines === ['Deck — Approved']
        && $mail->countsLine === '1 approved'
        && $mail->title === 'Ramadan 2027 strategy');
});
```

Mutations (Step 5): (a) in `ApprovalRequestService::create` pass `(string) count($items)` as the noun → test 2 FAILS for all rows; (b) change `DeckRequestSubject::LABEL` to `'Artboard'` → test 3 FAILS.

- [ ] **Step 2: Run to verify it fails**

Run: `DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/RequestNotifierCopyTest.php --compact`
Expected: test 1 FAILS (`requestLabel(): Argument #2 must be of type int`); test 2 FAILS (the 6th argument is an int). Test 3 passes already (digest lines read `approvals.label`) — prove it with mutation (b) now.

- [ ] **Step 3: Implement**

`ApprovalNotifier`:

```php
    /**
     * An approval request was sent (KV spec §4.5 step 6; spec 2026-10-06
     * §4.7 for decks and plans): the P0a inbox fan-out and approver mail,
     * labelled "Request {n} · {items}".
     *
     * @param  list<array{user: User, lane: ClientLaneLink}>  $approvers
     * @param  string  $itemsNoun  "6 artboards" | "deck" | "campaign plan" (ApprovalRequestSubject::itemsNoun)
     * @return list<string> emails that were mailed
     */
    public function requestSent(ApprovalRequest $request, ApprovalSubject $subject, ShareLink $link, User $requester, array $approvers, string $itemsNoun): array
    {
        $label = self::requestLabel($request->number, $itemsNoun);
```

(rest of the body unchanged).

```php
    /**
     * "Resend" on a request — mail only, no inbox rows.
     *
     * @param  list<array{user: User, lane: ClientLaneLink}>  $approvers
     * @return list<string>
     */
    public function requestResent(ApprovalRequest $request, ApprovalSubject $subject, ShareLink $link, User $requester, array $approvers, string $itemsNoun): array
    {
        return $this->mailApprovers($subject, $link, $requester, $approvers, self::requestLabel($request->number, $itemsNoun), $request->message, ['approval_request_id' => (string) $request->id]);
    }

    /** "Request 2 · 6 artboards" / "Request 2 · deck" / "Request 3 · campaign plan". */
    public static function requestLabel(int $number, string $itemsNoun): string
    {
        return sprintf('Request %d · %s', $number, $itemsNoun);
    }
```

`ApprovalRequestService::create` notifier call:

```php
        $sent = $notify
            ? $this->notifier->requestSent($result['request'], $info, $result['share_link'], $requester, $result['approvers'], $adapter->itemsNoun(count($items)))
            : [];
```

`ApprovalRequestService::resend` last line:

```php
        $count = Approval::query()->where('approval_request_id', $request->id)->count();

        return $this->notifier->requestResent($request, $subject, $link, $actor, $approvers, $this->subjects->for((string) $request->subject_type)->itemsNoun($count));
```

- [ ] **Step 4: Run to verify it passes** — Step 2 command plus `tests/Feature/Approval/KvRequestCharacterizationTest.php tests/Feature/Approval/ApprovalRequestDigestTest.php` → PASS.

- [ ] **Step 5: Mutation check** — (a). Restore; green.

- [ ] **Step 6: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-deck-plan-requests && F="app/Services/Approval/ApprovalNotifier.php app/Services/Approval/ApprovalRequestService.php tests/Feature/Approval/RequestNotifierCopyTest.php" && for f in ${=F}; do php -l $f || exit 1; done && vendor/bin/pint ${=F} && vendor/bin/pint --test ${=F} && /usr/bin/git add ${=F} && /usr/bin/git commit -m "feat(api): name the subject type in approval-request mail and inbox copy"
```

---

### Task 9: Plan status from requests; an edit closes a stale request approval

**Files:**
- Modify: `app/Services/Approval/ApprovalRequestRollup.php` (static `recalculate`)
- Modify: `app/Services/Approval/ApprovalRequestService.php` (`recalculate` delegates)
- Modify: `app/Services/Approval/ApprovalService.php` (`closePendingRequestApprovals`, `afterPlanEdit`)
- Modify: `app/Models/CampaignPlan.php` (S9)
- Modify: `app/Http/Controllers/Api/CampaignPlan/CampaignPlansController.php` (`update`)
- Modify: `app/Http/Controllers/Api/ModelContextProtocol/CampaignPlanToolController.php` (`update`)
- Modify: `tests/Support/ClientLaneFixtures.php` (`planEditor`)
- Test: `tests/Feature/CampaignPlan/PlanRequestStatusTest.php`

**Interfaces:**
- Consumes: `ApprovalRequestRollup::status(array $approvalStatuses): string`.
- Produces:
  - `ApprovalRequestRollup::recalculate(ApprovalRequest $locked): void` (static; `ApprovalRequestService::recalculate` keeps its public signature and delegates). Static so `ApprovalService` can re-roll without depending on `ApprovalRequestService` (which would be a constructor cycle through `DeckRequestSubject`).
  - `ApprovalService::closePendingRequestApprovals(string $subjectType, string $subjectId, ?string $keepVersionId = null): int`
  - `ApprovalService::afterPlanEdit(CampaignPlan $plan, User $actor, bool $wasApproved): void`
  - `ClientLaneFixtures::planEditor(): array{user, workspace, brand, plan, subject}`

- [ ] **Step 1: Add the `planEditor` fixture**

Imports: `use App\Models\Permission;`.

```php
    /**
     * A plan its brand's campaign editor can PATCH and re-status over HTTP —
     * the permission seeding CampaignPlanCrudTest uses.
     *
     * @return array{user: User, workspace: Workspace, brand: Brand, plan: CampaignPlan, subject: CampaignPlan}
     */
    public static function planEditor(): array
    {
        $user = User::factory()->withPersonalWorkspace()->create();
        $workspace = $user->currentWorkspace;
        $brand = Brand::factory()->create(['workspace_id' => $workspace->id]);
        foreach (['brand.insight.campaign.read', 'brand.insight.campaign.write'] as $slug) {
            $permission = Permission::firstOrCreate(
                ['slug' => $slug],
                ['name' => $slug, 'description' => '', 'category' => 'brand', 'is_brand_scoped' => true],
            );
            $user->customPermissions()->attach($permission->id, ['workspace_id' => $workspace->id, 'brand_id' => $brand->id]);
        }
        $plan = CampaignPlan::factory()->create(['brand_id' => $brand->id, 'created_by' => $user->id, 'name' => 'Ramadan 2027 media plan']);

        return ['user' => $user, 'workspace' => $workspace, 'brand' => $brand, 'plan' => $plan, 'subject' => $plan];
    }
```

- [ ] **Step 2: Write the failing test**

`tests/Feature/CampaignPlan/PlanRequestStatusTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Jobs\SendApprovalRequestDigest;
use App\Models\Approval;
use App\Services\Approval\ApprovalRequestService;
use App\Services\Approval\ApprovalService;
use Illuminate\Support\Facades\Bus;
use Illuminate\Support\Facades\Mail;
use Tests\Support\ClientLaneFixtures;

/**
 * A plan's status reads its requests (spec 2026-10-06 §4.5, S9); editing a
 * plan closes a pending request approval on the old numbers (S8).
 */
beforeEach(function () {
    Mail::fake();
    Bus::fake([SendApprovalRequestDigest::class]);
    $this->f = ClientLaneFixtures::planEditor();
    $this->request = app(ApprovalRequestService::class)->create($this->f['plan'], $this->f['user'], notify: false)['request'];
    $this->approval = $this->request->approvals()->sole();
    $this->actingAs($this->f['user']);
    $this->planUrl = "/api/v1/brands/{$this->f['brand']->id}/plans/{$this->f['plan']->id}";
});

test('a plan with a pending request reads in review', function () {
    expect($this->f['plan']->fresh()->approval_status)->toBe('in_review');
});

test('a plan whose request was approved reads approved', function () {
    $lane = ClientLaneFixtures::personalLane($this->f['brand']);
    $this->withHeader('X-Lane-Code', $lane->unique_code)
        ->postJson("/api/public/share-links/{$this->request->shareLink->token}/decision", ['outcome' => 'approved', 'approval_ids' => [$this->approval->id]])
        ->assertCreated();

    expect($this->f['plan']->fresh()->approval_status)->toBe('approved');
});

test('editing the plan\'s numbers closes the pending request approval and re-rolls the request', function () {
    $this->patchJson($this->planUrl, ['totalBudget' => 150_000_000])->assertOk();

    expect($this->approval->fresh()->status)->toBe(Approval::STATUS_NOT_RELEVANT)
        ->and($this->request->fresh()->status)->toBe(Approval::STATUS_NOT_RELEVANT)
        ->and($this->f['plan']->fresh()->approval_status)->toBeNull();
});

test('afterPlanEdit closes stale request approvals and keeps same-version ones', function () {
    $approvals = app(ApprovalService::class);
    $plan = $this->f['plan']->fresh();

    // Same numbers: nothing to close.
    $approvals->afterPlanEdit($plan, $this->f['user'], wasApproved: false);
    expect($this->approval->fresh()->status)->toBe(Approval::STATUS_PENDING);

    $plan->forceFill(['total_budget' => 150_000_000])->saveQuietly();
    $approvals->afterPlanEdit($plan->fresh(), $this->f['user'], wasApproved: false);
    expect($this->approval->fresh()->status)->toBe(Approval::STATUS_NOT_RELEVANT)
        ->and($this->request->fresh()->status)->toBe(Approval::STATUS_NOT_RELEVANT);
});
```

Mutations (Step 6): (a) in `CampaignPlan::getApprovalStatusAttribute` drop `&& $approval->approval_request_id === null` → test 1 FAILS (`draft`); (b) in `closePendingRequestApprovals` drop the `->when($keepVersionId …)` filter → test 4 FAILS at its first expectation; (c) in `closePendingRequestApprovals` delete the `ApprovalRequestRollup::recalculate($request);` call → tests 3 and 4 FAIL on the request status; (d) in `CampaignPlansController::update` delete the `afterPlanEdit` call → test 3 FAILS.

- [ ] **Step 3: Run to verify it fails**

Run: `DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/CampaignPlan/PlanRequestStatusTest.php --compact`
Expected: test 1 FAILS (`draft`), test 3 FAILS (approval still pending), test 4 FAILS (`Call to undefined method …afterPlanEdit`). Test 2 passes or fails depending on S9 — read the failure and confirm it is `draft` vs `approved` is not the cause (approved never reads draft; it should pass).

- [ ] **Step 4: Implement**

`ApprovalRequestRollup` — add (imports `use App\Models\ApprovalRequest;`):

```php
    /**
     * Re-roll a request the caller has LOCKED, inside the caller's
     * transaction; `resolved_at` is stamped when it leaves `pending`.
     * Static so the P0a ApprovalService can re-roll without depending on
     * ApprovalRequestService (spec 2026-10-06 §4.5, §7.2).
     */
    public static function recalculate(ApprovalRequest $locked): void
    {
        $status = self::status(
            Approval::query()->where('approval_request_id', $locked->id)->pluck('status')->all(),
        );
        if ($status === $locked->status) {
            return;
        }

        $locked->forceFill([
            'status' => $status,
            'resolved_at' => $status === Approval::STATUS_PENDING ? null : ($locked->resolved_at ?? now()),
        ])->save();
    }
```

`ApprovalRequestService::recalculate` body becomes `ApprovalRequestRollup::recalculate($locked);`.

`ApprovalService` — imports `use App\Models\ApprovalRequest;`. Add after `reopenPlanForEdit()`:

```php
    /**
     * Close every still-pending REQUEST approval of a subject as
     * `not_relevant` and re-roll its request (spec 2026-10-06 §4.5, §9 Q3).
     * `$keepVersionId` spares approvals still on that version (a plan edit
     * that left the fingerprint alone — ruling S8). Lock order R17: the
     * subject's requests first, then its approvals.
     *
     * @return int approvals closed
     */
    public function closePendingRequestApprovals(string $subjectType, string $subjectId, ?string $keepVersionId = null): int
    {
        return DB::transaction(function () use ($subjectType, $subjectId, $keepVersionId): int {
            $requests = ApprovalRequest::query()
                ->forSubject($subjectType, $subjectId)
                ->orderBy('number')
                ->lockForUpdate()
                ->get()
                ->keyBy(fn (ApprovalRequest $request): string => (string) $request->id);

            $pending = Approval::query()
                ->forSubject($subjectType, $subjectId)
                ->whereNotNull('approval_request_id')
                ->where('status', Approval::STATUS_PENDING)
                ->when($keepVersionId !== null, fn ($query) => $query->where('subject_version_id', '!=', $keepVersionId))
                ->orderBy('id')
                ->lockForUpdate()
                ->get();

            foreach ($pending as $approval) {
                $approval->forceFill(['status' => Approval::STATUS_NOT_RELEVANT, 'resolved_at' => now()])->save();
            }
            foreach ($pending->pluck('approval_request_id')->unique() as $requestId) {
                $request = $requests->get((string) $requestId);
                if ($request !== null) {
                    ApprovalRequestRollup::recalculate($request);
                }
            }

            return $pending->count();
        });
    }

    /**
     * A saved plan edit (spec 2026-10-06 §4.5; PRD R4), from the UI and the
     * MCP tool alike: a pending request approval on the old numbers closes,
     * and an approved plan re-opens review with a new pending round, as
     * before.
     *
     * @throws RoundConflictException
     */
    public function afterPlanEdit(CampaignPlan $plan, User $actor, bool $wasApproved): void
    {
        $this->closePendingRequestApprovals('campaign', (string) $plan->id, self::fingerprintPlan($plan));

        if ($wasApproved) {
            $this->reopenPlanForEdit($plan, $actor);
        }
    }
```

`CampaignPlan::getApprovalStatusAttribute` — the pending arm and the docblock:

```php
     *   no round → null · pending + sent_at NULL → draft · pending + sent_at
     *   (or a pending request approval, whose request holds sent_at — spec
     *   2026-10-06 S9) → in_review · approved | approved_with_changes →
     *   approved · changes_required → changes_requested · not_relevant → null
```

```php
            Approval::STATUS_PENDING => $approval->sent_at === null && $approval->approval_request_id === null
                ? PlanApproval::DRAFT
                : PlanApproval::IN_REVIEW,
```

`CampaignPlansController::update` — replace from `$reopen = $plan->isDirty() && …;` through the closing brace of `if ($reopen) { … }` with:

```php
        $edited = $plan->isDirty();
        $reopen = $edited && $approvalStatus === PlanApproval::APPROVED;

        $plan->save();

        if ($edited) {
            // Spec 2026-10-06 §4.5: an edit also closes a pending request
            // approval on the old numbers (the client page then shows the
            // request closed rather than still asking).
            try {
                $approvals->afterPlanEdit($plan, $request->user(), $reopen);
            } catch (RoundConflictException $e) {
                return response()->json(['code' => RoundConflictException::CODE, 'message' => $e->getMessage()], 409);
            }
            $plan->unsetRelation('latestApproval');
        }
```

(keep the PRD R4 comment block above it).

`CampaignPlanToolController::update` — replace the block from `$approvalReset = $plan->isDirty() && …;` to the end of `if ($approvalReset) { … }` with:

```php
            $edited = $plan->isDirty();
            $approvalReset = $edited && $plan->approval_status === PlanApproval::APPROVED;

            $changedFields = array_keys($plan->getDirty());
            $plan->save();

            // Same as the UI endpoint (spec 2026-10-06 §4.5): close a stale
            // pending request approval; re-open review on an approved plan.
            if ($edited) {
                $this->approvals->afterPlanEdit($plan, $ctx->user, $approvalReset);
                $plan->unsetRelation('latestApproval');
            }
```

Keep `$approvalReset` — the response further down reports it; check with `/usr/bin/grep -n approvalReset app/Http/Controllers/Api/ModelContextProtocol/CampaignPlanToolController.php` that every later use still reads it.

- [ ] **Step 5: Run to verify it passes**

Run: `DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/CampaignPlan/PlanRequestStatusTest.php tests/Feature/CampaignPlan/CampaignPlanCrudTest.php tests/Unit/CampaignPlan/PlanApprovalTest.php tests/Unit/CampaignPlan/LifecycleStageTest.php tests/Unit/CampaignPlan/ForecastRecomputeGateTest.php --compact`
Expected: PASS except Task 0 baseline failures.

- [ ] **Step 6: Mutation checks** — (a)–(d) from Step 2; restore; green.

- [ ] **Step 7: Gates (incl. MCP mirror) and commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-deck-plan-requests && F="app/Services/Approval/ApprovalRequestRollup.php app/Services/Approval/ApprovalRequestService.php app/Services/Approval/ApprovalService.php app/Models/CampaignPlan.php app/Http/Controllers/Api/CampaignPlan/CampaignPlansController.php app/Http/Controllers/Api/ModelContextProtocol/CampaignPlanToolController.php tests/Support/ClientLaneFixtures.php tests/Feature/CampaignPlan/PlanRequestStatusTest.php" && for f in ${=F}; do php -l $f || exit 1; done && vendor/bin/pint ${=F} && vendor/bin/pint --test ${=F} && php artisan mcp:verify-mirror && /usr/bin/git add ${=F} && /usr/bin/git commit -m "feat(api): plan status reads approval requests; an edit closes a stale request approval"
```

Expected from `mcp:verify-mirror`: `Mirror OK` (no route or tool was added or removed).

---

### Task 10: Manual plan status closes an open request first (spec §9 Q3)

**Files:**
- Modify: `app/Services/Approval/ApprovalService.php` (`applyPlanStatus`)
- Test: `tests/Feature/CampaignPlan/PlanRequestStatusTest.php` (append)

**Interfaces:**
- Consumes: `closePendingRequestApprovals()` (Task 9).
- Produces: Q3 behaviour on `POST v1/brands/{brand}/plans/{plan}/approval`.

- [ ] **Step 1: Append the failing tests to `tests/Feature/CampaignPlan/PlanRequestStatusTest.php`**

```php
test('marking a plan approved while a request is open closes the request first (Q3)', function () {
    $this->postJson("{$this->planUrl}/approval", ['status' => 'approved'])->assertOk()
        ->assertJsonPath('data.approvalStatus', 'approved');

    expect($this->approval->fresh()->status)->toBe(Approval::STATUS_NOT_RELEVANT)
        ->and($this->request->fresh()->status)->toBe(Approval::STATUS_NOT_RELEVANT);
});

test('moving a plan back to draft while a request is open closes the request (Q3)', function () {
    $this->postJson("{$this->planUrl}/approval", ['status' => 'draft'])->assertOk()
        ->assertJsonPath('data.approvalStatus', 'draft');

    expect($this->request->fresh()->status)->toBe(Approval::STATUS_NOT_RELEVANT);
});
```

Mutation (Step 4): delete the new first line of `applyPlanStatus` → test "approved" FAILS (`500` — `decide()` throws `UseApprovalRequestsException` on the request approval) and test "draft" FAILS (reads `in_review`: the request approval only lost `sent_at`, S9 still says in review).

- [ ] **Step 2: Run to verify they fail**

Run: `DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/CampaignPlan/PlanRequestStatusTest.php --compact`
Expected: the two new tests FAIL as described in the mutation note (that IS the unfixed behaviour).

- [ ] **Step 3: Implement** — first statement of `ApprovalService::applyPlanStatus`, and a docblock line:

```php
     * A pending REQUEST approval is closed first (spec 2026-10-06 §9 Q3): the
     * agency's manual status wins, and the client page shows the request
     * closed rather than still asking.
```

```php
    public function applyPlanStatus(CampaignPlan $plan, string $status, User $actor): void
    {
        $this->closePendingRequestApprovals('campaign', (string) $plan->id);

        $subject = ApprovalSubject::from($plan);
```

- [ ] **Step 4: Run to verify, then mutation check** — Step 2 command → PASS (6 tests); apply the mutation; both new tests FAIL; restore; green. Also run `tests/Feature/CampaignPlan/CampaignPlanCrudTest.php` → baseline-equal.

- [ ] **Step 5: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-deck-plan-requests && F="app/Services/Approval/ApprovalService.php tests/Feature/CampaignPlan/PlanRequestStatusTest.php" && for f in ${=F}; do php -l $f || exit 1; done && vendor/bin/pint ${=F} && vendor/bin/pint --test ${=F} && /usr/bin/git add ${=F} && /usr/bin/git commit -m "feat(api): a manual plan status closes an open approval request first"
```

---

### Task 11: Drain — P0a rounds still work, and re-roll a request they replace

**Files:**
- Modify: `app/Services/Approval/ApprovalService.php` (`request()`: lock requests first; re-roll a replaced request approval)
- Test: `tests/Feature/Approval/DeckPlanRoundDrainTest.php`

**Interfaces:**
- Consumes: `ApprovalRequestRollup::recalculate()` (Task 9).
- Produces: S10. `POST v1/approvals` keeps accepting `deck`/`campaign` (spec E-5) — no refusal is added.

- [ ] **Step 1: Write the failing test**

`tests/Feature/Approval/DeckPlanRoundDrainTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Jobs\SendApprovalRequestDigest;
use App\Models\Approval;
use Illuminate\Support\Facades\Bus;
use Illuminate\Support\Facades\Mail;
use Illuminate\Support\Str;
use Tests\Support\ClientLaneFixtures;

/**
 * Drain (spec 2026-10-06 §7.2, E-5): the web still in production keeps
 * opening and deciding P0a deck/plan rounds through v1/approvals.
 */
beforeEach(function () {
    Mail::fake();
    Bus::fake([SendApprovalRequestDigest::class]);
});

test('a P0a deck round can still be created and decided by a guest', function () {
    $f = ClientLaneFixtures::deck();
    ClientLaneFixtures::actAsAgency($this, $f['user']);

    $shareUrl = $this->postJson('/api/v1/approvals', ['subject_type' => 'deck', 'subject_id' => $f['deck']->id])
        ->assertCreated()
        ->json('data.share_url');

    $this->postJson('/api/public/share-links/'.Str::afterLast($shareUrl, '/s/').'/decision', [
        'outcome' => 'approved',
        'guest_name' => 'Dina',
        'guest_email' => 'dina@brand.test',
    ])->assertCreated()->assertJsonPath('data.approval.status', 'approved');
});

test('a P0a plan round can still be created', function () {
    $f = ClientLaneFixtures::brandedPlan();
    ClientLaneFixtures::actAsAgency($this, $f['user']);

    $this->postJson('/api/v1/approvals', ['subject_type' => 'campaign', 'subject_id' => $f['plan']->id])
        ->assertCreated()
        ->assertJsonPath('data.approval.round', 1);
});

test('a P0a round closes a pending request approval and re-rolls its request', function () {
    $f = ClientLaneFixtures::sendRequest('deck');
    $requestApproval = $f['request']->approvals()->sole();
    ClientLaneFixtures::actAsAgency($this, $f['user']);

    $this->postJson('/api/v1/approvals', ['subject_type' => 'deck', 'subject_id' => $f['subject']->id])
        ->assertCreated()
        ->assertJsonPath('data.approval.round', 2);

    expect($requestApproval->fresh()->status)->toBe(Approval::STATUS_NOT_RELEVANT)
        ->and($f['request']->fresh()->status)->toBe(Approval::STATUS_NOT_RELEVANT);
});
```

Mutations (Step 5): (a) in `ApprovalController::store` change `if ($validated['subject_type'] === 'kv_file')` to `if ($validated['subject_type'] !== 'campaign')` → test 1 FAILS (`422 use_approval_requests`); (b) delete the new re-roll block in `request()` → test 3 FAILS (request stays `pending`).

Check before writing: `/usr/bin/grep -n "'round'\|'status'" app/Http/Resources/Approval/ApprovalResource.php app/Http/Resources/Approval/ApprovalPresenter.php` — `ApprovalResource` (store) must expose `round` and `ApprovalPresenter::approval()` (decision) `status`; if a key differs, use the actual key in the tests and log the correction.

- [ ] **Step 2: Run to verify it fails**

Run: `DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/DeckPlanRoundDrainTest.php --compact`
Expected: tests 1–2 PASS (prove 1 with mutation (a) now); test 3 FAILS — the request approval is closed but `$f['request']->fresh()->status` is still `pending`.

- [ ] **Step 3: Implement S10 in `ApprovalService::request()`**

Inside the `DB::transaction` closure, before `$previous = Approval::query()…`:

```php
                // Lock order R17 (spec 2026-10-06 §7.2): the subject's
                // requests before its approvals — a request send on the same
                // subject locks in that order too.
                $requests = ApprovalRequest::query()
                    ->forSubject($subject->type, (string) $subject->model->getKey())
                    ->orderBy('number')
                    ->lockForUpdate()
                    ->get();
```

and replace the supersede block:

```php
                if ($previous !== null && $previous->isPending()) {
                    $previous->forceFill([
                        'status' => Approval::STATUS_NOT_RELEVANT,
                        'resolved_at' => now(),
                    ])->save();

                    // Drain (ruling S10): the old web opened a round over a
                    // pending REQUEST approval — its request re-rolls.
                    $owner = $previous->approval_request_id !== null
                        ? $requests->first(fn (ApprovalRequest $r): bool => (string) $r->id === (string) $previous->approval_request_id)
                        : null;
                    if ($owner !== null) {
                        ApprovalRequestRollup::recalculate($owner);
                    }
                }
```

Update the method docblock: "Decks and campaign plans only (P0a rounds, kept for the drain — spec 2026-10-06 §7.2). A KV file is approved per artboard through ApprovalRequestService."

- [ ] **Step 4: Run to verify it passes** — Step 2 command → PASS (3 tests). Regression: `tests/Feature/CampaignPlan/PlanRequestStatusTest.php tests/Feature/CampaignPlan/CampaignPlanCrudTest.php tests/Feature/Approval/DeckPlanRequestSendTest.php` → PASS.

- [ ] **Step 5: Mutation check** — (b); restore; green.

- [ ] **Step 6: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-deck-plan-requests && F="app/Services/Approval/ApprovalService.php tests/Feature/Approval/DeckPlanRoundDrainTest.php" && for f in ${=F}; do php -l $f || exit 1; done && vendor/bin/pint ${=F} && vendor/bin/pint --test ${=F} && /usr/bin/git add ${=F} && /usr/bin/git commit -m "feat(api): keep P0a deck and plan rounds working and re-roll a request they replace"
```

---

### Task 12: The approval record — data and Blade view

**Files:**
- Create: `app/Services/Approval/ApprovalRecordPdf.php`
- Create: `resources/views/pdf/approval-record.blade.php`
- Test: `tests/Feature/Approval/ApprovalRecordPdfTest.php`

**Interfaces:**
- Consumes: `ApprovalRequestPresenter::ordered()`, `ApprovalPresenter::version(Approval): array{label, …}`, `Approval::successorsOf()`, `ApprovalSubject::find()`, the adapter's `composites()`/`thumbnailFields()`, `ApprovalDecision::{isResolving, actorName, laneLink}`, `ClientLaneService::shareUrl()`, `Barryvdh\DomPDF\Facade\Pdf`.
- Produces:
  - `ApprovalRecordPdf::data(ApprovalRequest $request): array<string, mixed>`
  - `ApprovalRecordPdf::html(ApprovalRequest $request): string`
  - `ApprovalRecordPdf::download(ApprovalRequest $request): \Illuminate\Http\Response` (application/pdf attachment)
  - `ApprovalRecordPdf::filename(string $title, int $number): string` → `approval-record-{slug}-request-{n}.pdf`
  - `ApprovalRecordPdf::verifiedBy(ApprovalDecision $decision): string`

- [ ] **Step 1: Write the failing test**

`tests/Feature/Approval/ApprovalRecordPdfTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Jobs\SendApprovalRequestDigest;
use App\Models\ApprovalDecision;
use App\Models\Comment;
use App\Services\Approval\ApprovalRecordPdf;
use App\Services\Approval\ApprovalRequestService;
use App\Services\ClientLane\ClientLaneService;
use Illuminate\Support\Facades\Bus;
use Illuminate\Support\Facades\Mail;
use Tests\Support\ClientLaneFixtures;

/**
 * The approval record (spec 2026-10-06 §4.8, rulings S6/S7): header, one
 * block per item with verdict, decider, verification and pins; the Final
 * stamp; Team-only comments never render.
 */
beforeEach(function () {
    Mail::fake();
    Bus::fake([SendApprovalRequestDigest::class]);
    $this->f = ClientLaneFixtures::sendRequest('deck');
    $this->approval = $this->f['request']->approvals()->sole();
    $this->records = app(ApprovalRecordPdf::class);
});

test('a decided deck request records who decided what, how verified, the note and numbered pins', function () {
    $lane = ClientLaneFixtures::verifiedGuestLane($this->f['brand']);
    $token = $this->f['link']->token;
    $pin = $this->withHeader('X-Lane-Code', $lane->unique_code)
        ->postJson("/api/public/share-links/{$token}/comments", [
            'body' => 'Make the logo bigger',
            'anchor' => ['kind' => 'pin', 'id' => "slide:{$this->approval->subject_version_id}:s1", 'x' => 0.5, 'y' => 0.5],
        ])->assertCreated()->json('data.id');
    $this->withHeader('X-Lane-Code', $lane->unique_code)
        ->postJson("/api/public/share-links/{$token}/decision", [
            'outcome' => 'changes_required', 'approval_ids' => [$this->approval->id], 'pins' => [$pin], 'note' => 'Swap the hero photo',
        ])->assertCreated();

    $html = $this->records->html($this->f['request']->fresh());

    expect($html)->toContain('Kopi Kenangan')
        ->toContain('Ramadan 2027 strategy')
        ->toContain('Deck · Request 1')
        ->toContain(e($this->f['user']->name))
        ->toContain('Changes requested')
        ->toContain('<div class="stamp">Final</div>')
        ->toContain('v1')
        ->toContain('code · this device')
        ->toContain('Swap the hero photo')
        ->toContain('<span class="pin-n">1</span> Make the logo bigger')
        ->toContain('class="no-thumb"')
        ->toContain(ClientLaneService::shareUrl($this->f['link']));
});

test('a Team-only comment never renders, even if its id sits in a decision\'s pins', function () {
    $lane = ClientLaneFixtures::verifiedGuestLane($this->f['brand']);
    $this->withHeader('X-Lane-Code', $lane->unique_code)
        ->postJson("/api/public/share-links/{$this->f['link']->token}/decision", ['outcome' => 'approved', 'approval_ids' => [$this->approval->id]])
        ->assertCreated();
    $internal = Comment::create([
        'commentable_type' => 'deck',
        'commentable_id' => $this->f['subject']->id,
        'author_id' => $this->f['user']->id,
        'body' => 'Team only: margin is thin on this one',
        'internal_only' => true,
        'anchor' => ['kind' => 'pin', 'id' => "slide:{$this->approval->subject_version_id}:s1", 'x' => 0.1, 'y' => 0.1],
    ]);
    // Through the model, so the `pins` array cast encodes it (a builder
    // update() would not).
    ApprovalDecision::query()->get()->each(fn (ApprovalDecision $d) => $d->forceFill(['pins' => [(string) $internal->id]])->save());

    expect($this->records->html($this->f['request']->fresh()))->not->toContain('margin is thin');
});

test('a pending request has no Final stamp; a personal link is named as such', function () {
    $plan = ClientLaneFixtures::brandedPlan();
    $request = app(ApprovalRequestService::class)->create($plan['plan'], $plan['user'], notify: false)['request'];

    $pending = $this->records->html($request->fresh());
    expect($pending)->not->toContain('<div class="stamp">Final</div>')->toContain('Waiting');

    $lane = ClientLaneFixtures::personalLane($plan['brand']);
    $this->withHeader('X-Lane-Code', $lane->unique_code)
        ->postJson("/api/public/share-links/{$request->shareLink->token}/decision", ['outcome' => 'approved', 'approval_ids' => [$request->approvals()->sole()->id]])
        ->assertCreated();

    expect($this->records->html($request->fresh()))->toContain('personal link')->toContain('Campaign plan · Request 1');
});

test('a withdrawn request records Withdrawn and no Final stamp', function () {
    app(ApprovalRequestService::class)->withdraw($this->f['request']);

    expect($this->records->html($this->f['request']->fresh()))
        ->toContain('Withdrawn')
        ->not->toContain('<div class="stamp">Final</div>');
});

test('the file name is a slug of the title and the request number', function () {
    expect(ApprovalRecordPdf::filename('Ramadan 2027 strategy', 3))->toBe('approval-record-ramadan-2027-strategy-request-3.pdf')
        ->and(ApprovalRecordPdf::filename('', 1))->toBe('approval-record-approval-request-1.pdf');
});
```

Mutations (Step 5): (a) delete `->where('internal_only', false)` in `data()` → test 2 FAILS; (b) set `'final' => true` → tests 3 and 4 FAIL; (c) make `verifiedBy()` return `'personal link'` for every lane → test 1 FAILS. S7's "names, never emails" has no test here (every fixture request is approver-less — naming approvers needs a workspace client role); the reviewer checks the `approvers` mapping by reading.

- [ ] **Step 2: Run to verify it fails**

Run: `DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/ApprovalRecordPdfTest.php --compact`
Expected: FAIL — `Class "App\Services\Approval\ApprovalRecordPdf" not found`.

- [ ] **Step 3: Write `app/Services/Approval/ApprovalRecordPdf.php`**

```php
<?php

declare(strict_types=1);

namespace App\Services\Approval;

// craftsman-ignore: PHP002 — resolved from the container and swapped in tests.

use App\Http\Resources\Approval\ApprovalPresenter;
use App\Http\Resources\Approval\ApprovalRequestPresenter;
use App\Models\Approval;
use App\Models\ApprovalDecision;
use App\Models\ApprovalRequest;
use App\Models\ClientLaneLink;
use App\Models\Comment;
use App\Services\Approval\Subjects\ApprovalRequestSubjects;
use App\Services\ClientLane\ClientLaneService;
use Barryvdh\DomPDF\Facade\Pdf;
use Illuminate\Http\Response;
use Illuminate\Support\Str;

/**
 * The approval record of one request (spec 2026-10-06 §4.8, decision E-6):
 * who approved what, which version, when, and how they were verified.
 * Rendered on demand from `pdf.approval-record`, never stored. Team-only
 * (`internal_only`) comments never reach the view; approvers are named,
 * never e-mailed (ruling S7).
 */
class ApprovalRecordPdf
{
    private const TYPE_LABELS = ['kv_file' => 'Key visual', 'deck' => 'Deck', 'campaign' => 'Campaign plan'];

    private const STATUS_LABELS = [
        Approval::STATUS_PENDING => 'Waiting',
        Approval::STATUS_APPROVED => 'Approved',
        Approval::STATUS_APPROVED_WITH_CHANGES => 'Approved with changes',
        Approval::STATUS_CHANGES_REQUIRED => 'Changes requested',
        Approval::STATUS_NOT_RELEVANT => 'Withdrawn',
    ];

    /** Request statuses that mean "every item is decided" (ruling S6). */
    private const FINAL_STATUSES = [
        Approval::STATUS_APPROVED,
        Approval::STATUS_APPROVED_WITH_CHANGES,
        Approval::STATUS_CHANGES_REQUIRED,
    ];

    public function __construct(private readonly ApprovalRequestSubjects $subjects) {}

    /** @return array<string, mixed> */
    public function data(ApprovalRequest $request): array
    {
        $request->loadMissing(['approvals.decisions.actor:id,name', 'approvals.decisions.laneLink', 'shareLink', 'requester:id,name']);
        $subject = ApprovalSubject::find((string) $request->subject_type, (string) $request->subject_id);
        $adapter = $this->subjects->for((string) $request->subject_type);
        $approvals = ApprovalRequestPresenter::ordered($request->approvals);
        $successors = Approval::successorsOf($approvals);
        $composites = $adapter->composites((string) $request->subject_id, $approvals->pluck('snapshot'));

        $pinIds = $approvals
            ->flatMap(fn (Approval $approval) => $approval->decisions->flatMap(fn (ApprovalDecision $d): array => $d->pins ?? []))
            ->unique()->values()->all();
        $pins = $pinIds === [] ? collect() : Comment::query()
            ->whereIn('id', $pinIds)
            ->where('commentable_type', (string) $request->subject_type)
            ->where('commentable_id', (string) $request->subject_id)
            // Team-only comments never leave the agency (spec §4.8).
            ->where('internal_only', false)
            ->get(['id', 'body'])
            ->keyBy(fn (Comment $comment): string => (string) $comment->id);

        return [
            'brand' => (string) ($subject?->brand()?->name ?? ''),
            'title' => (string) ($subject?->title ?? ''),
            'typeLabel' => self::TYPE_LABELS[(string) $request->subject_type] ?? 'Item',
            'requestLabel' => 'Request '.$request->number,
            'sender' => (string) ($request->requester?->name ?? ''),
            'approvers' => array_values(array_filter(array_map(
                static fn (array $approver): string => trim((string) ($approver['name'] ?? '')),
                $request->approvers ?? [],
            ))),
            'sentAt' => $request->sent_at?->format('j M Y, H:i'),
            'decideBy' => $request->decide_by?->format('j M Y'),
            'status' => self::STATUS_LABELS[$request->status] ?? $request->status,
            'final' => in_array($request->status, self::FINAL_STATUSES, true),
            'items' => $approvals->map(function (Approval $approval) use ($adapter, $composites, $successors, $pins): array {
                $replacedBy = $successors->get((string) $approval->id)?->approvalRequest?->number;

                return [
                    'thumbnail' => self::safeThumbnail($adapter->thumbnailFields($approval->snapshot, $composites)['thumbnail_url']),
                    'label' => (string) $approval->label,
                    'version' => (string) ApprovalPresenter::version($approval)['label'],
                    'verdict' => $replacedBy !== null
                        ? "Replaced by Request {$replacedBy}"
                        : (self::STATUS_LABELS[$approval->status] ?? $approval->status),
                    'decisions' => $approval->decisions
                        ->filter(fn (ApprovalDecision $decision): bool => $decision->isResolving())
                        ->values()
                        ->map(fn (ApprovalDecision $decision): array => [
                            'who' => $decision->actorName(),
                            'outcome' => self::STATUS_LABELS[$decision->outcome] ?? $decision->outcome,
                            'when' => $decision->decided_at?->format('j M Y, H:i'),
                            'verified' => self::verifiedBy($decision),
                            'advisory' => (bool) $decision->advisory,
                            'note' => $decision->note,
                            'pins' => array_values(array_filter(array_map(
                                static fn (string $id): ?string => $pins->get($id)?->body,
                                array_map('strval', $decision->pins ?? []),
                            ))),
                        ])->all(),
                ];
            })->all(),
            'generatedAt' => now()->format('j M Y, H:i T'),
            'link' => $request->shareLink !== null ? ClientLaneService::shareUrl($request->shareLink) : null,
        ];
    }

    public function html(ApprovalRequest $request): string
    {
        return view('pdf.approval-record', $this->data($request))->render();
    }

    public function download(ApprovalRequest $request): Response
    {
        $data = $this->data($request);

        return Pdf::loadView('pdf.approval-record', $data)
            ->setPaper('A4', 'portrait')
            ->setOptions([
                'isHtml5ParserEnabled' => true,
                // Thumbnails are https URLs the app stored itself
                // (safeThumbnail); same remote setting as InvoiceService.
                'isRemoteEnabled' => true,
                'defaultFont' => 'DejaVu Sans',
            ])
            ->download(self::filename((string) $data['title'], (int) $request->number));
    }

    public static function filename(string $title, int $number): string
    {
        $slug = Str::slug($title) ?: 'approval';

        return "approval-record-{$slug}-request-{$number}.pdf";
    }

    /** "personal link" / "code · this device" (spec §4.8, ruling S7). */
    public static function verifiedBy(ApprovalDecision $decision): string
    {
        $kind = $decision->laneLink?->kind;

        return match (true) {
            $kind === ClientLaneLink::KIND_PERSONAL => 'personal link',
            $kind === ClientLaneLink::KIND_VERIFIED_GUEST => 'code · this device',
            $decision->actor_user_id !== null => 'frndOS account',
            default => 'not verified',
        };
    }

    private static function safeThumbnail(?string $url): ?string
    {
        return is_string($url) && str_starts_with($url, 'https://') ? $url : null;
    }
}
```

- [ ] **Step 4: Write `resources/views/pdf/approval-record.blade.php`**

```blade
{{-- Approval record (spec 2026-10-06 §4.8): who approved what, which version, when, how verified. Team-only comments never reach this view. --}}
<!DOCTYPE html>
<html lang="en">
<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>
<title>Approval record — {{ $title }} — {{ $requestLabel }}</title>
<style>
    body { font-family: 'DejaVu Sans', sans-serif; font-size: 11px; color: #1a1a1a; margin: 0; }
    h1 { font-size: 18px; margin: 2px 0 4px; }
    .muted { color: #666666; }
    .header { position: relative; border-bottom: 1px solid #dddddd; padding-bottom: 10px; margin-bottom: 14px; }
    .stamp { position: absolute; top: 0; right: 0; border: 2px solid #1f7a3a; color: #1f7a3a; font-weight: bold; padding: 4px 12px; text-transform: uppercase; letter-spacing: 1px; }
    table.meta td { padding: 2px 14px 2px 0; vertical-align: top; }
    .item { border: 1px solid #dddddd; padding: 10px; margin-bottom: 10px; page-break-inside: avoid; }
    .thumb { width: 120px; }
    .no-thumb { width: 120px; height: 68px; border: 1px dashed #bbbbbb; color: #888888; text-align: center; font-size: 10px; padding-top: 26px; }
    .decision { margin-top: 6px; padding-top: 6px; border-top: 1px dotted #dddddd; }
    .pin-n { display: inline-block; width: 14px; height: 14px; line-height: 14px; border-radius: 7px; background: #1a1a1a; color: #ffffff; text-align: center; font-size: 9px; }
    .footer { margin-top: 16px; border-top: 1px solid #dddddd; padding-top: 6px; font-size: 9px; color: #666666; }
</style>
</head>
<body>
<div class="header">
    @if($final)<div class="stamp">Final</div>@endif
    <div class="muted">{{ $brand }}</div>
    <h1>{{ $title }}</h1>
    <div>{{ $typeLabel }} · {{ $requestLabel }}</div>
    <table class="meta">
        <tr><td class="muted">Sent by</td><td>{{ $sender }}</td></tr>
        <tr><td class="muted">Approvers</td><td>{{ $approvers === [] ? 'Anyone with the link' : implode(', ', $approvers) }}</td></tr>
        <tr><td class="muted">Sent</td><td>{{ $sentAt ?? '—' }}</td></tr>
        <tr><td class="muted">Decide by</td><td>{{ $decideBy ?? '—' }}</td></tr>
        <tr><td class="muted">Status</td><td>{{ $status }}</td></tr>
    </table>
</div>

@foreach($items as $item)
<div class="item">
    <table><tr>
        <td style="vertical-align: top; width: 130px;">
            @if($item['thumbnail'])<img class="thumb" src="{{ $item['thumbnail'] }}" alt="">@else<div class="no-thumb">{{ $item['label'] }}</div>@endif
        </td>
        <td style="vertical-align: top;">
            <strong>{{ $item['label'] }}</strong> <span class="muted">{{ $item['version'] }}</span><br>
            {{ $item['verdict'] }}
            @foreach($item['decisions'] as $decision)
                <div class="decision">
                    {{ $decision['outcome'] }} by {{ $decision['who'] }}@if($decision['advisory']) (advisory)@endif · {{ $decision['when'] }}<br>
                    <span class="muted">Verified: {{ $decision['verified'] }}</span>
                    @if($decision['note'])<div>“{{ $decision['note'] }}”</div>@endif
                    @foreach($decision['pins'] as $pin)
                        <div><span class="pin-n">{{ $loop->iteration }}</span> {{ $pin }}</div>
                    @endforeach
                </div>
            @endforeach
        </td>
    </tr></table>
</div>
@endforeach

<div class="footer">Generated {{ $generatedAt }}@if($link) · {{ $link }}@endif</div>
</body>
</html>
```

- [ ] **Step 5: Run to verify it passes, then mutation checks**

Run the Step 2 command → PASS (5 tests). If a `toContain` fails on whitespace around Blade output (e.g. the pin line), dump `$html`, confirm the rendered text, and adjust the expectation to the real markup — not the view's meaning. Apply mutations (a)–(c) from Step 1; each named test FAILS; restore; green.

- [ ] **Step 6: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-deck-plan-requests && F="app/Services/Approval/ApprovalRecordPdf.php tests/Feature/Approval/ApprovalRecordPdfTest.php" && for f in ${=F}; do php -l $f || exit 1; done && vendor/bin/pint ${=F} && vendor/bin/pint --test ${=F} && /usr/bin/git add ${=F} resources/views/pdf/approval-record.blade.php && /usr/bin/git commit -m "feat(api): render the approval record of a request"
```

---

### Task 13: `record.pdf` endpoints — agency any time, public once decided or withdrawn

**Files:**
- Modify: `app/Http/Controllers/Api/Approval/ApprovalRequestController.php` (`record`)
- Modify: `app/Http/Controllers/Api/PublicShareLinkController.php` (`record`)
- Modify: `routes/api.php` (two routes)
- Test: `tests/Feature/Approval/ApprovalRecordEndpointTest.php`

**Interfaces:**
- Consumes: `ApprovalRecordPdf::download()` (Task 12), the controllers' `subject()` / `resolve()` / `requestFor()` / `notFound()`.
- Produces: `GET v1/approval-requests/{approvalRequest}/record.pdf` (name `approval-requests.record`), `GET public/share-links/{token}/record.pdf` (name `public.share-links.record`).

- [ ] **Step 1: Write the failing test**

`tests/Feature/Approval/ApprovalRecordEndpointTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Models\User;
use App\Models\Workspace;
use App\Services\Approval\ApprovalRequestService;
use Illuminate\Support\Facades\Mail;
use Tests\Support\ClientLaneFixtures;

/**
 * Spec 2026-10-06 §4.8: the agency downloads the record any time; the
 * client once the request is decided or withdrawn (ruling S6).
 */
beforeEach(function () {
    Mail::fake();
});

test('the agency downloads a PDF record for every subject type', function (string $type) {
    $f = ClientLaneFixtures::sendRequest($type);
    ClientLaneFixtures::actAsAgency($this, $f['user']);

    $response = $this->get("/api/v1/approval-requests/{$f['request']->id}/record.pdf")->assertOk();

    expect($response->headers->get('Content-Type'))->toContain('application/pdf')
        ->and($response->headers->get('Content-Disposition'))->toContain('approval-record-')
        ->and(substr((string) $response->getContent(), 0, 4))->toBe('%PDF');
})->with(['kv_file', 'deck', 'campaign']);

test('another workspace gets a 404 for the record', function () {
    $f = ClientLaneFixtures::sendRequest('deck');
    $outsider = User::factory()->create();
    $outsider->update(['current_workspace_id' => Workspace::factory()->create()->id]);
    ClientLaneFixtures::actAsAgency($this, $outsider);

    $this->get("/api/v1/approval-requests/{$f['request']->id}/record.pdf")->assertNotFound();
});

test('the public record answers 404 while pending and the PDF once withdrawn', function () {
    $f = ClientLaneFixtures::sendRequest('campaign');
    $url = "/api/public/share-links/{$f['link']->token}/record.pdf";

    $this->get($url)->assertNotFound()->assertExactJson(['message' => 'Not found.']);

    app(ApprovalRequestService::class)->withdraw($f['request']);

    $response = $this->get($url)->assertOk();
    expect($response->headers->get('Content-Type'))->toContain('application/pdf')
        ->and($response->headers->get('Cache-Control'))->toContain('no-store')
        ->and(substr((string) $response->getContent(), 0, 4))->toBe('%PDF');
});

test('an unknown token and a view link both answer the dead-link 404', function () {
    $f = ClientLaneFixtures::deck();
    $view = app(\App\Services\Sharing\ShareLinkService::class)->create(shareable: $f['deck'], creator: $f['user'], phases: [], label: 'View', expiresIn: null);

    $this->get('/api/public/share-links/AAAAAAAAAAAAAAAA/record.pdf')->assertNotFound()->assertExactJson(['message' => 'Not found.']);
    $this->get("/api/public/share-links/{$view->token}/record.pdf")->assertNotFound()->assertExactJson(['message' => 'Not found.']);
});
```

Mutations (Step 5): (a) delete the workspace check in `ApprovalRequestController::record` → test 2 FAILS (200); (b) delete `|| $approvalRequest->isPending()` in `PublicShareLinkController::record` → test 3 FAILS at the first `assertNotFound`; (c) return `response($records->html(...))` from the agency action → test 1 FAILS (`%PDF`).

- [ ] **Step 2: Run to verify it fails**

Run: `DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/ApprovalRecordEndpointTest.php --compact`
Expected: FAIL — 404/405 on the record URLs (no routes yet). If tests 3–4 "pass" by 404, that is the missing route, not the rule — they become meaningful only after Step 3; mutation (b) proves test 3.

- [ ] **Step 3: Implement the actions and routes**

`ApprovalRequestController` — imports `use App\Services\Approval\ApprovalRecordPdf;`, `use Illuminate\Http\Response;`:

```php
    /**
     * GET v1/approval-requests/{approvalRequest}/record.pdf — the approval
     * record, any status (spec 2026-10-06 §4.8). Same auth as `index`.
     */
    public function record(Request $request, ApprovalRequest $approvalRequest, ApprovalRecordPdf $records): Response
    {
        $user = $request->user();
        if (! $user->isSuperadmin() && (string) $approvalRequest->workspace_id !== (string) $user->current_workspace_id) {
            abort(404);
        }
        $this->subject($request, (string) $approvalRequest->subject_type, (string) $approvalRequest->subject_id, write: false);

        return $records->download($approvalRequest);
    }
```

`PublicShareLinkController` — imports `use App\Services\Approval\ApprovalRecordPdf;`, `use Illuminate\Http\Response;`:

```php
    /**
     * GET public/share-links/{token}/record.pdf — the client's copy of the
     * approval record, once the request is decided or withdrawn (spec
     * 2026-10-06 §4.8, ruling S6). Every other case is the one dead-link 404.
     */
    public function record(Request $request, string $token, ApprovalRecordPdf $records): Response|JsonResponse
    {
        $resolved = $this->resolve($request, $token);
        if ($resolved === null) {
            return $this->notFound();
        }

        $approvalRequest = $this->requestFor($resolved[0]);
        if ($approvalRequest === null || $approvalRequest->isPending()) {
            return $this->notFound();
        }

        return $records->download($approvalRequest)->header('Cache-Control', 'no-store');
    }
```

`routes/api.php` — inside the `approval-requests` group, after the `resend` route:

```php
                Route::get('/{approvalRequest}/record.pdf', [ApprovalRequestController::class, 'record'])->name('approval-requests.record');
```

and after the `public.share-links.decision` route:

```php
// The approval record of a request link (spec 2026-10-06 §4.8): 404 until
// the request is decided or withdrawn.
Route::get('public/share-links/{token}/record.pdf', [PublicShareLinkController::class, 'record'])
    ->middleware('throttle:public-share-link')
    ->name('public.share-links.record');
```

- [ ] **Step 4: Run to verify it passes** — Step 2 command → PASS (6 tests incl. dataset). Then `php artisan route:list --path=record.pdf` → both routes listed.

- [ ] **Step 5: Mutation checks** — (a)–(c); restore; green.

- [ ] **Step 6: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-deck-plan-requests && F="app/Http/Controllers/Api/Approval/ApprovalRequestController.php app/Http/Controllers/Api/PublicShareLinkController.php routes/api.php tests/Feature/Approval/ApprovalRecordEndpointTest.php" && for f in ${=F}; do php -l $f || exit 1; done && vendor/bin/pint ${=F} && vendor/bin/pint --test ${=F} && /usr/bin/git add ${=F} && /usr/bin/git commit -m "feat(api): download the approval record as PDF, agency and client"
```

---

### Task 14: Gates, contract notes, track file

**Files:**
- Modify: `docs/prd/client-lane-p0a/api.md` (append an additive-notes block)
- Create: `docs/tracks/client-lane-deck-plan-requests.track.md`

**Interfaces:**
- Consumes: everything above.
- Produces: the branch, committed and green, NOT pushed.

- [ ] **Step 1: Full approval-related run (one process, file paths)**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-deck-plan-requests && ls bootstrap/cache/config.php bootstrap/cache/routes-v7.php 2>/dev/null; DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/KvRequestCharacterizationTest.php tests/Feature/Approval/KvRequestSubjectTest.php tests/Feature/Approval/DeckPlanRequestPreviewTest.php tests/Feature/Approval/DeckPlanRequestSendTest.php tests/Feature/Approval/DeckPlanRequestPublicTest.php tests/Feature/Approval/RequestVerificationTest.php tests/Feature/Approval/RequestNotifierCopyTest.php tests/Feature/Approval/DeckPlanRoundDrainTest.php tests/Feature/Approval/ApprovalRecordPdfTest.php tests/Feature/Approval/ApprovalRecordEndpointTest.php tests/Feature/CampaignPlan/PlanRequestStatusTest.php tests/Feature/Approval/ApprovalRequestDigestTest.php tests/Feature/Approval/KvArtboardThumbnailTest.php tests/Feature/Approval/KvSharePayloadItemsForTest.php tests/Feature/Sharing/ShareLinksRevokedListenerTest.php tests/Feature/Deck/DeckShareLinkTest.php tests/Feature/CampaignPlan/CampaignPlanCrudTest.php tests/Unit/CampaignPlan/PlanApprovalTest.php tests/Unit/CampaignPlan/LifecycleStageTest.php tests/Unit/CampaignPlan/ForecastRecomputeGateTest.php --compact
```

Expected: every new test passes; the only failures are the Task 0 baseline list, unchanged. Any new failure blocks this task.

- [ ] **Step 2: Static gates over the whole diff**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-deck-plan-requests && CHANGED=$(/usr/bin/git diff --name-only origin/develop...HEAD -- '*.php') && for f in ${=CHANGED}; do php -l $f || exit 1; done && vendor/bin/pint --test ${=CHANGED} && php artisan mcp:verify-mirror && php artisan route:list --path=approval-requests && /usr/bin/grep -rn "toApprovalAttributes\|compositesFor\|->artboards()" app tests ; echo "leftovers-exit=$?"
```

Expected: no syntax errors; pint clean; `Mirror OK`; `approval-requests.preview|index|store|withdraw|resend|record` listed; the leftover grep prints nothing (`leftovers-exit=1`).

- [ ] **Step 3: Append the contract notes to `docs/prd/client-lane-p0a/api.md`**

Insert, directly after the existing "Additive notes (KV approval requests Part D …)" block and before `## Scope`, a block headed:

`### Additive notes (deck and plan approval requests — spec `docs/superpowers/specs/2026-10-06-client-lane-deck-plan-approval-requests-design.md`, 2026-10-06)`

Its body is this plan's **API contract for web** section verbatim, followed by the rulings S1–S13 as one bullet each (copy the bullets from the Rulings section). End the block with: "The web copy of this file is synced by the web plan (`docs/superpowers/plans/2026-10-06-client-lane-deck-plan-requests-web.md`); until then the two copies differ by this block."

- [ ] **Step 4: Create `docs/tracks/client-lane-deck-plan-requests.track.md`**

```markdown
---
prd: client-lane-deck-plan-requests
parent_prd: docs/superpowers/specs/2026-10-06-client-lane-deck-plan-approval-requests-design.md
service: api
branch: feature/daffa/vc-client-lane-deck-plan-requests
pr_url: null
status: in_progress
---

# Track — Client Lane: deck and campaign plan on approval requests (api, Spec 1)

Plan: `docs/superpowers/plans/2026-10-06-client-lane-deck-plan-requests-api.md` (workspace root). Builds on KV approval requests (api#618).
Contract: "Additive notes (deck and plan approval requests …)" in `docs/prd/client-lane-p0a/api.md`.
Tests: `DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest <file> --compact` — file paths only, one process at a time, worktree `api/.worktrees/client-lane-deck-plan-requests`.

## Status

| Item | Status |
|------|--------|
| Wireframe | n/a (api) |
| PRD | spec 2026-10-06 approved (Jeff ticket) |
| Service PRD | contract notes appended |
| Implementation | completed (api, phases 1–3) |
| PR | not_submitted |

## Task Checklist

- [x] TASK-0: Pre-flight — worktree, permission, caches, baseline
- [x] TASK-1: KV characterization snapshot (pinned before the refactor)
- [x] TASK-2: subject adapter interface, RequestItem, registry, KvRequestSubject
- [x] TASK-3: preview/send/presenter/controllers through the adapter — KV unchanged
- [x] TASK-4: deck and plan adapters; preview `round` + `blocked_reason`
- [x] TASK-5: send for deck/plan — own link outside the cap, v3→v4, supersede
- [x] TASK-6: public page and decisions for deck/plan requests
- [x] TASK-7: one verification rule; magic link only for P0a links
- [x] TASK-8: notifier copy names the subject type
- [x] TASK-9: plan status from requests; edit closes a stale request approval
- [x] TASK-10: manual plan status closes an open request first (Q3)
- [x] TASK-11: drain — P0a rounds still work and re-roll a request they replace
- [x] TASK-12: approval record — data + Blade view
- [x] TASK-13: record.pdf endpoints, agency + public
- [x] TASK-14: gates, contract notes, this file
- [ ] TASK-15: push + PR (Daffa decides; api PR merges before web)

## Session Log

### 2026-10-06 — daffa (plan executor)
- Answers at Task 0: phase-0 KV smoke <yes/no + date>; test permission <yes>.
- Baseline failures (pre-existing, unchanged at Task 14): <list from Task 0 Step 5, or "none">.
- New tests: <N passed> across 11 files; every named mutation made its test fail.
- KV fixtures re-recorded once (Task 4, S5): only `round` and `blocked_reason` added.
- Expectation corrections made while executing (real value confirmed by reading code): <list or "none">.
- NOT done: push, PR, staging (Spec 2); contract (§7.3) — separate ticket.
```

Fill every `<…>` with the real value from this run before committing (no `<…>` may remain: `/usr/bin/grep -n '<' docs/tracks/client-lane-deck-plan-requests.track.md` must show only the markdown table/frontmatter, no placeholder).

- [ ] **Step 5: Commit (do NOT push)**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-deck-plan-requests && /usr/bin/git add docs/prd/client-lane-p0a/api.md docs/tracks/client-lane-deck-plan-requests.track.md && /usr/bin/git commit -m "docs(api): contract notes and track for deck and plan approval requests" && /usr/bin/git log --oneline origin/develop..HEAD && /usr/bin/git status --short
```

Expected: 14 commits listed (Tasks 1–14), clean status. Report the branch name and the commit list to Daffa; stop.

---

## Spec coverage map (self-review)

| Spec | Task |
|---|---|
| §4.1 SUBJECT_TYPES, gate removal, adapter resolution, ApprovalSubject policies | 3 (resolution), 4 (types) |
| §4.2 interface + KV/Deck/Plan adapters, null-safe matching | 2, 3, 4, 5 (mutation b) |
| §4.3 preview total / already approved / waiting / `no_brand`; store refuses brand-less | 4 |
| §4.4 own link outside the cap, supersede incl. pending P0a round, `reuseOrMintCommentLink` not used | 5 |
| §4.5 plan status reads requests; edit closes + re-rolls (UI + MCP); manual status stays | 9, 10 |
| §4.6 code for all three types, 403 without lane, magic link only P0a | 7 |
| §4.7 notifier: sent, resent, digest, deferred; copy names the type | 8 (sent/resent/digest; deferred is type-agnostic and unchanged) |
| §4.8 record.pdf agency + public, dompdf, contents, Team-only excluded | 12, 13 |
| §4.9 resolver render context (deck `data.deck`, plan projection) | 3 (merge), 4 (adapters), 6 |
| §7.1 phase 1 "KV responses identical" | 1, 3 |
| §7.2 drain: `v1/approvals` keeps rounds; supersede of a pending P0a round | 11, 5 |
| §8 api tests (KV regression; adapters; verification; plan; PDF; drain) | 1, 4–13 |
| §9 Q3 | 10 |
