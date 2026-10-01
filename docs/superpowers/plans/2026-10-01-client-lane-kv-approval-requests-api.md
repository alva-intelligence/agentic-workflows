# Client Lane — KV Approval Requests (Part A) — API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the file-level multi-item round (`approval_items`) with KV approval *requests*: one `approval_requests` row per send, one `approvals` row per artboard per round (keyed by `subject_key`), one `purpose = approval` link per request, a roll-up status, a 15-minute decision digest, and the agency + public endpoints that read and write them — while deck and campaign-plan approvals behave exactly as P0a.

**Architecture:** `KvArtboardResolver` turns the existing ready-to-share payload (`KvSharePayloadService::itemsFor`) into `KvArtboard` values (phase, `subject_key`, rendered version, label, snapshot, artwork fingerprint). `ApprovalRequestPreviewService` classifies each artboard against its latest approval (eligible / already approved / waiting). `ApprovalRequestService` freezes the eligible set into one request + N approvals under a lock, supersedes pending approvals of the same artboard, mints the request's own link outside the view-link cap, and recalculates roll-ups through the pure `ApprovalRequestRollup`. Per-artboard resolution reuses P0a's `ApprovalService::resolve()` unchanged; `ApprovalRequestDecisionService` drives it for C-3 `approval_ids[]`. `PinWindow` is the one rule for "which pins belong to this approval", used by C-4, decision pins and `pin_count`. Notifications go through `ApprovalNotifier` (request mail, deferral) and `ApprovalRequestDigest` + the delayed `SendApprovalRequestDigest` job.

**Tech Stack:** Laravel 13, PHP 8.5, PostgreSQL (jsonb, expression unique index, `split_part`), Pest 4.

**Spec:** `docs/superpowers/specs/2026-10-01-client-lane-kv-approval-requests-design.md` (workspace root) — this plan implements §4 (Part A data model + api), §4.8 contract notes, the §8 api tests for Part A and §10 carry-over. Parts B, C, D are out of scope; nothing here blocks them (`share_links.purpose` and the `ShareLinksRevoked` extension ship here; the Part D verification gate does not).

### Rulings (spec ambiguities resolved here; all are written into the contract notes in Task 1)

- **R1 — "same version" = same `subject_version_id` AND same artwork fingerprint** (`KvArtboard::fingerprintOf()`: image/video URL, dimensions, overlays — never name, label or `is_master`). Why: a resize tile's version id is its row id, which regeneration never changes (spec §4.2), so the literal "same `subject_version_id`" rule would keep a regenerated tile "already approved" forever.
- **R2 — a pending approval on the same version is excluded from `items` and listed in an additive `waiting[]`** (preview). Why: spec §5.2's disabled reason "Everything marked is approved or waiting" is unreachable if waiting artboards count as new; re-sending identical artwork is never useful. `replaces` therefore appears only for a changed version.
- **R3 — preview `phases[]` counts ignore `kv_phases`**; `items`, `already_approved`, `waiting`, `total` respect it. Why: the form shows counts on every pill, including unselected ones (§5.2).
- **R4 — `supersedes_approval_id` is set only when the new approval replaces a still-pending one; `round` is always previous round + 1.** Why: "superseded" (counts, `replaced`, `superseded_by_request_number`, pin windows) must be derivable, and a withdrawn-then-resent artboard is not "replaced".
- **R5 — request-level `deferred` writes no `approval_decisions` row**; it sets `approval_requests.deferred_until/deferred_note` and notifies at once. Why: a deferral is about the request, not an artboard; a row per artboard would show "asked for more time" on every card.
- **R6 — an `approval_ids` entry that is not an approval of this request → `422 { code: "invalid_approval" }`, nothing recorded.** Pins are matched per approval across all ids in the post; a pin matching none → `422` on `pins`; pins on skipped approvals are dropped. `note_required` is checked per still-pending approval, all-or-nothing.
- **R7 — `approved_with_changes` is not accepted as an explicit outcome on an approval link** (`422` on `outcome`); it is only ever derived (approve + pins).
- **R8 — C-1 for an approval link:** `version = { type: "approval_request", id, label: "Request {n}", created_at: sent_at }`; `items[]` is each approval in the old item shape `{id, phase, label, version_id, status, snapshot}`; a withdrawn request is still served (spec §4.4) with `can_decide = false`; a link with no request row → the byte-identical 404. Every non-approval link answers `items: []`.
- **R9 — C-3 response is wrapped like P0a:** `201 { data: { results, request, approvals } }`. A withdrawn or fully replaced (`not_relevant`) request → `409 round_closed`; a decided request answers `201` with per-id skips.
- **R10 — pin windows:** a pin belongs to an approval when its version segment matches and `approval.created_at <= pin.created_at < successor.created_at` (no upper bound unless replaced). New root pins are accepted only on non-replaced approvals. Why: a resize row id is shared by both requests after a regenerate-and-resend, so without the upper bound request 2's pins would leak into request 1's page and `pin_count`.
- **R11 — approver `decided`** (agency and public) = no still-pending approval of the request lacks a resolving decision by that approver. **`counts`**: a withdrawn approval (not_relevant, no successor) is in no key.
- **R12 — approval links are not view links:** excluded from `MAX_ACTIVE_LINKS`, from `GET …/share-links`, from `PATCH`/`DELETE …/share-links/{id}` (404), and from the legacy `share_token` projection. `share_token: enable` replaces view links only; `share_token: disable` revokes every link of the file (approval links too → the listener withdraws pending requests).
- **R13 — `v1/approvals` and KV:** `POST` kv_file → `422 use_approval_requests` (no `kv_phases` / `kv_ready_item_id` rules remain); `GET` kv_file lists rows with `approval_request_id IS NULL`; `withdraw`/`resend` on a request-owned approval → `422 use_approval_requests`.
- **R14 — `decide_by`** (`Y-m-d`, after today) is stored as the end of that day in the app timezone.
- **R15 — one artboard reachable from two phases** (a chain spanning sketch and craft modes) is listed once, under the first canonical phase. Why: two rows with the same key and round would violate the new unique index and 500 the send.
- **R16 — digest wording:** client name = distinct decider names in order (`Dina`, `Dina and Bayu`, `Dina, Bayu +2`); counts line omits zero segments (`5 approved · 1 new version asked · 2 still open`; `approved` includes `approved_with_changes`; `No decisions yet` when all are zero).
- **R17 — lock order** for every request write: all `approval_requests` rows of the file (`FOR UPDATE`, ordered by `number`), then the artboards' `approvals` rows. The decision path locks its request row, then its approvals. A lost race on the first request answers `409 round_conflict`.
- **R18 — `BrandClientLaneLinkController::rotate`'s `personal_url`** also considers request links (moved into `ClientLaneService::newestDecisionLink()`). Why: KV approvals carry no `share_link_id` any more, so rotate would return `null` for every KV client.

## Global Constraints

- **Repo + shell:** every command runs from the api worktree root `/Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item`. Agent shells reset cwd, so prefix every shell call with `cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && `. Paths below are relative to that root unless absolute. The shell is zsh; an `rtk` hook rewrites `grep` / `git` output, so commands use `/usr/bin/grep` and `/usr/bin/git`.
- **Branch:** continue on `feature/daffa/vc-client-lane-multi-item` (unpushed). Never commit on `develop`. **Never push.** **Never `git stash`** (lesson: a popped stale stash corrupted files) — compare baselines with a worktree if ever needed.
- **api/AGENTS.md rule 1, verbatim: "DO NOT MAKE OR RUN ANY TESTS WITHOUT USER PERMISSION."** Task 0 asks Daffa (AskUserQuestion) for ONE explicit approval covering exactly the Pest files this plan names (create, run, and the seven obsolete files it deletes), run only on the scratch DB `frnd_testing`. No test is written, run or deleted before that yes. Anything beyond that list needs a new ask.
- **Never the dev DB `frnd`** for tests (the worktree `.env` points at `frnd`). Before every test run:
  1. `ls bootstrap/cache/config.php 2>/dev/null` must print nothing; if it prints a path run `php artisan config:clear`.
  2. If `bootstrap/cache/routes-v7.php` exists, move it aside: `mv bootstrap/cache/routes-v7.php /private/tmp/claude-501/routes-v7.php.bak`; never restore it (a stale route cache 405s every new route); tell Daffa it was moved.
  3. Run test FILE PATHS only, one Pest process at a time, never `php artisan test`, never `--filter` alone:
     `DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest <file> --compact`
     (`tests/TestCase.php` refuses any DB whose name lacks a `test` token.)
- **The full Feature suite is known-broken on fresh migrate for unrelated reasons.** Only run the files this plan names. If `migrate:fresh` itself fails in Task 0's pre-flight, STOP and report — do not fix unrelated migrations.
- **Dev DB step** (roll back the three `2026_09_30_120*` migrations if they ran, migrate the new ones, `TELESCOPE_ENABLED=false`) is Task 16 and must ASK Daffa first.
- **Commits:** api commit messages carry NO `Co-Authored-By` trailer and no "Generated with" line. Format `feat(api): …` / `test(api): …` / `docs(api): …` / `refactor(api): …`.
- **Gates at every commit:** `php -l` on each touched PHP file; `vendor/bin/pint <touched files>` then `vendor/bin/pint --test <touched files>` must pass (pint's `no_unused_imports` catches leftovers from the `approval_items` removal).
- **Deck and campaign-plan approvals must behave exactly as before:** `approval_request_id = null`, `subject_key = null`, one round per subject, C-1…C-9 unchanged. Task 3's regression file pins it; every later task re-runs it.
- **Mutation checks:** every key rule gets one: break the named line, run the named test file, watch the named test FAIL, restore, re-run green. If a test passes against the mutation, the test is wrong — fix the test, never the mutation. Where an expected value comes from real code (labels, payload fields), and an assertion fails on UNCHANGED production code, dump the actual value, confirm it by reading the code, and correct the expectation — never the service.
- **Queue in tests is `sync`** (`phpunit.xml`): any test that triggers `SendApprovalRequestDigest` must `Bus::fake([SendApprovalRequestDigest::class])` or the 15-minute delay is ignored and the job runs inline. Mail tests use `Mail::fake()`.
- **Public write throttle** (`public-share-link-write` = 10/min per IP): keep ≤ 9 public POSTs (comments + decisions) per test.
- **Postgres-only SQL** (jsonb, expression index, `split_part`): these tests cannot run on SQLite.
- **Time comparisons against `comments.created_at`** (naive `timestamp`) are done in SQL against bound Carbon values, never as PHP instants (multi-item final review #3: app on Asia/Jakarta, DB session on UTC).
- Line numbers cite branch HEAD `a0c1dc49d` as read on 2026-10-01. Earlier tasks shift them — re-read each file before editing and anchor edits on the quoted code, not the number.

## Review Focus

Inputs the spec implies but its happy paths would not exercise, most likely to bite first. Each has its test in the owning task.

1. **A resize tile regenerated after it was approved** keeps its row id (= `version_id`); it must come back as a new version in the preview, not sit in "Already approved" forever. → Task 6 test *"a changed version re-enters: a Craft iteration and a regenerated resize tile"*.
2. **jsonb round-trip of a stored snapshot** (key reordering, `{}` → `[]`, float formatting in overlay payloads) must not change the artwork fingerprint, or every approved artboard looks changed and is offered again. → Task 4 test *"the fingerprint survives a jsonb round-trip, overlays and all"*.
3. **"Approve all" racing another decider or a re-send:** some ids are already decided or replaced when the post lands — each gets its own skip result, the rest are decided, and pins on skipped artboards do not fail the batch. → Task 14 test *"each id gets its own result: decided, skipped_closed, skipped_replaced"*.
4. **The same resize row in two requests** (regenerated and re-sent): request 2's pins must not appear on request 1's page or in its `pin_count`, and request 1's pins must not appear on request 2's. → Task 12 test *"a pin on a re-sent tile stays with the request it was placed in"* and Task 9 test *"index … pin_count counts only pins placed while that approval was current"*.
5. **App timezone ≠ DB session timezone** (Asia/Jakarta vs UTC): a pin placed during the request must list and count as a decision pin. → Task 12 test *"a request pin counts even when the app and the database disagree on the timezone"* and Task 3's deck twin.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `docs/prd/client-lane-p0a/api.md` | Modify | Rewrite the multi-item contract notes for requests (Task 1) |
| `database/migrations/2026_09_30_120000_create_approval_items_table.php` | Delete | (Task 3) |
| `database/migrations/2026_09_30_120100_add_approval_item_id_to_approval_decisions.php` | Delete | (Task 3) |
| `database/migrations/2026_09_30_120200_backfill_approval_items.php` | Delete | (Task 3) |
| `database/migrations/2026_10_01_100000_create_approval_requests_table.php` | Create | `approval_requests` + CHECKs |
| `database/migrations/2026_10_01_100100_add_request_columns_to_approvals.php` | Create | 5 columns + unique swap to expression index + phase CHECK |
| `database/migrations/2026_10_01_100200_add_purpose_to_share_links.php` | Create | `share_links.purpose` + CHECK |
| `app/Models/ApprovalRequest.php` | Create | Request model, `counts()` |
| `database/factories/ApprovalRequestFactory.php` | Create | Factory |
| `app/Models/Approval.php` | Modify | New columns, `approvalRequest()`, `successorsOf()`; drop items |
| `app/Models/ApprovalDecision.php` | Restore from develop | Drop `approval_item_id` |
| `app/Models/ShareLink.php` | Modify | `PURPOSE_*`, `purpose` fillable, `scopeForSharing`, limit scope |
| `app/Models/StudioFile.php` | Modify | Legacy token ignores approval links |
| `app/Models/ApprovalItem.php`, `database/factories/ApprovalItemFactory.php`, `app/Services/Approval/FrozenItem.php`, `app/Exceptions/Approval/InvalidItemException.php` | Delete | (Task 3) |
| `app/Exceptions/Approval/UseApprovalRequestsException.php` | Create | `422 use_approval_requests` |
| `app/Exceptions/Approval/InvalidApprovalException.php` | Create | `422 invalid_approval` |
| `app/Exceptions/Approval/NoteRequiredException.php` | Create | `422 note_required` |
| `app/Exceptions/Approval/NothingReadyException.php`, `TooManyItemsException.php` | Modify | Docblocks: request wording |
| `app/Services/Approval/PinWindow.php` | Create | Which pins belong to an approval; client pin counts |
| `app/Services/Approval/KvArtboard.php` | Create | Value: phase, key, version, label, snapshot, fingerprint |
| `app/Services/Approval/KvArtboardKey.php` | Create | §4.2 key rules |
| `app/Services/Approval/KvArtboardResolver.php` | Create | Payload → artboards (dedupe by key) |
| `app/Services/Approval/ApprovalRequestRollup.php` | Create | Pure §4.3 roll-up |
| `app/Services/Approval/ApprovalRequestPreview.php` | Create | Preview value + `toArray()` |
| `app/Services/Approval/ApprovalRequestPreviewService.php` | Create | Eligibility |
| `app/Services/Approval/ApprovalRequestService.php` | Create | Create, recalculate, withdraw, resend, revoke |
| `app/Services/Approval/ApprovalRequestDecisionService.php` | Create | C-3 `approval_ids[]` |
| `app/Services/Approval/ApprovalRequestDigest.php` | Create | Digest sender |
| `app/Jobs/SendApprovalRequestDigest.php` | Create | Delayed digest job |
| `app/Mail/ApprovalRequestDigestMail.php` + `resources/views/emails/client-lane/approval-request-digest.blade.php` | Create | Digest mail |
| `app/Services/Approval/ApprovalService.php` | Modify | Back to one version per round; KV refusal; `recordDecision`, `ownPinsOn` |
| `app/Services/Approval/ApprovalNotifier.php` | Restore + Modify | Request mail, deferral, digest |
| `app/Mail/ApprovalDecidedMail.php`, `resources/views/emails/client-lane/approval-decided.blade.php` | Restore from develop | Drop `itemCount` |
| `app/Http/Resources/Approval/ApprovalPresenter.php` | Modify | Drop items; shared `personalUrls()` |
| `app/Http/Resources/Approval/ApprovalRequestPresenter.php` | Create | AgencyRequest + public payload |
| `app/Http/Controllers/Api/Approval/ApprovalController.php` | Modify | KV refusal, legacy-only index |
| `app/Http/Controllers/Api/Approval/ApprovalRequestController.php` | Create | `v1/approval-requests` |
| `app/Http/Controllers/Api/PublicShareLinkController.php` | Modify | Request branch for C-1/C-3/C-4 |
| `app/Http/Controllers/Api/Studio/StudioFileShareLinkController.php`, `StudioFileController.php` | Modify | Purpose filtering |
| `app/Http/Controllers/Api/Brand/BrandClientLaneLinkController.php`, `app/Services/ClientLane/ClientLaneService.php` | Modify | `newestDecisionLink()` |
| `app/Services/Sharing/ShareLinkService.php` | Modify | `createApprovalLink()` |
| `app/Listeners/WithdrawRoundsOnRevokedLinks.php`, `app/Events/Sharing/ShareLinksRevoked.php` | Modify | Requests too |
| `app/Policies/ApprovalPolicy.php` | Modify | `mayManageRequest()` |
| `app/Services/Studio/KvSharePayloadService.php` | Modify | Docblocks only |
| `routes/api.php` | Modify | `approval-requests` routes |
| `tests/Support/ClientLaneFixtures.php` | Modify | New seeders; drop item ones |
| `tests/Feature/Approval/{ApprovalItemsMigrationTest,ApprovalDecideItemsTest,ApprovalRequestItemsTest,ApprovalPinsMembershipTest,PublicShareLinkItemsTest,ApprovalControllerItemsTest,ApprovalNotifierLabelTest}.php` | Delete | Obsolete (Task 3) |
| `tests/Feature/Approval/ApprovalRequestSchemaTest.php` | Create | Task 2 |
| `tests/Feature/Approval/DeckPlanApprovalRegressionTest.php` | Create | Task 3 |
| `tests/Feature/Approval/KvArtboardKeyTest.php` | Create | Task 4 |
| `tests/Unit/Approval/ApprovalRequestRollupTest.php` | Create | Task 5 |
| `tests/Feature/Approval/ApprovalRequestPreviewTest.php` | Create | Task 6 |
| `tests/Feature/Approval/ShareLinkPurposeTest.php` | Create | Task 7 |
| `tests/Feature/Approval/ApprovalRequestCreateTest.php` | Create | Task 8 |
| `tests/Feature/Approval/ApprovalRequestControllerTest.php` | Create | Task 9 |
| `tests/Feature/Approval/ApprovalRequestRevokeTest.php` | Create | Task 10 |
| `tests/Feature/Approval/PublicApprovalRequestLinkTest.php` | Create | Task 11 |
| `tests/Feature/Approval/PublicApprovalRequestCommentsTest.php` | Create | Task 12 |
| `tests/Feature/Approval/ApprovalRequestDigestTest.php` | Create | Task 13 |
| `tests/Feature/Approval/PublicApprovalRequestDecisionTest.php` | Create | Task 14 |
| `docs/tracks/client-lane-multi-item.track.md` | Modify | Task 15 |

---

### Task 0: Pre-flight — permission, branch, caches, scratch DB

**Files:** none changed.

**Interfaces:**
- Consumes: nothing.
- Produces: Daffa's single test permission (recorded in the track file in Task 15) and a known-green scratch DB.

- [ ] **Step 1: Ask for the one test permission**

Use AskUserQuestion, exactly one question, options "Yes, approved" / "No":

> "api/AGENTS.md says no tests without your permission. This plan (docs/superpowers/plans/2026-10-01-client-lane-kv-approval-requests-api.md) needs ONE approval to (a) create and run these Pest files on the scratch DB `frnd_testing` only — tests/Feature/Approval/ApprovalRequestSchemaTest.php, DeckPlanApprovalRegressionTest.php, KvArtboardKeyTest.php, ApprovalRequestPreviewTest.php, ShareLinkPurposeTest.php, ApprovalRequestCreateTest.php, ApprovalRequestControllerTest.php, ApprovalRequestRevokeTest.php, PublicApprovalRequestLinkTest.php, PublicApprovalRequestCommentsTest.php, ApprovalRequestDigestTest.php, PublicApprovalRequestDecisionTest.php, tests/Unit/Approval/ApprovalRequestRollupTest.php; (b) run the existing tests/Feature/Approval/KvSharePayloadItemsForTest.php, tests/Feature/Studio/KvGenerationModelTest.php, tests/Feature/Studio/KvShareLinkTest.php, tests/Feature/Deck/DeckShareLinkTest.php, tests/Feature/CampaignPlan/CampaignPlanCrudTest.php, tests/Unit/CampaignPlan/PlanApprovalTest.php, tests/Unit/CampaignPlan/LifecycleStageTest.php as regression; (c) DELETE the seven obsolete multi-item test files tests/Feature/Approval/ApprovalItemsMigrationTest.php, ApprovalDecideItemsTest.php, ApprovalRequestItemsTest.php, ApprovalPinsMembershipTest.php, PublicShareLinkItemsTest.php, ApprovalControllerItemsTest.php, ApprovalNotifierLabelTest.php (their model is removed). Never the dev DB `frnd`. Approve?"

On anything but "Yes, approved": STOP. Do not write, run or delete any test.

- [ ] **Step 2: Confirm the branch and a clean tree**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && /usr/bin/git branch --show-current && /usr/bin/git status --short && /usr/bin/git log --oneline -1
```
Expected: `feature/daffa/vc-client-lane-multi-item`, no status lines, HEAD `a0c1dc49d feat(api): revoking a link withdraws the pending round riding on it` (or a later commit of this plan). If the tree is dirty, stop and ask Daffa (never stash).

- [ ] **Step 3: Check migration timestamps are free**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && ls database/migrations | tail -4
```
Expected: newest is `2026_09_30_120200_backfill_approval_items.php`. If any file sorts after `2026_10_01_100000_…`, bump all three new timestamps in this plan (keep their order) and use the new names everywhere.

- [ ] **Step 4: Cache files and scratch DB**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && ls bootstrap/cache/config.php bootstrap/cache/routes-v7.php 2>/dev/null; psql -lqt | cut -d'|' -f1 | /usr/bin/grep -E 'frnd_test'
```
Expected: no cache file listed (handle per Global Constraints if one is) and `frnd_testing` listed. If `frnd_testing` is missing, STOP and ask Daffa (do not create databases).

- [ ] **Step 5: Prove the scratch DB migrates**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/KvGenerationModelTest.php --compact
```
Expected: PASS. A failure inside `migrate:fresh` → STOP and report.

---

### Task 1: Contract notes — rewrite for approval requests

**Files:**
- Modify: `docs/prd/client-lane-p0a/api.md` — replace the whole section that starts at the heading `### Additive notes (multi-item approval rounds — spec \`docs/superpowers/specs/2026-09-30-client-lane-multi-item-approval-design.md\`, 2026-09-30)` (line 153) and ends at the last bullet before `## Scope` (line 164).

**Interfaces:**
- Consumes: the rulings above.
- Produces: the contract every later task implements. **The web plan copies the block below byte-identically into `web/docs/prd/client-lane-p0a/web.md`** (replacing its own multi-item notes section); this plan edits only the api copy.

- [ ] **Step 1: Replace the section**

Delete lines 153–164 (the heading through the "Revoking a link withdraws its pending round" bullet) and insert exactly this block in their place (one blank line before `## Scope`):

````markdown
### Additive notes (KV approval requests — spec `docs/superpowers/specs/2026-10-01-client-lane-kv-approval-requests-design.md`, 2026-10-01)

Replaces the "multi-item approval rounds" notes of 2026-09-30, which never shipped. Decks and campaign plans keep C-1…C-11 exactly as written above; only `kv_file` approval moves to approval requests. Byte-identical in `api.md` and `web.md`.

Name map for the guide (*KV approval rework — the ready marks are the request*, 30 Sep 2026):

| Guide | This contract |
|---|---|
| `approval_requests` (message, approvers, link, sent, deadline, deferred) | `approval_requests` |
| `approvals.approval_request_id`; subject becomes the artboard | `approvals.approval_request_id` + `subject_key` (subject stays the file) |
| "artboard subject type and key" | `subject_type = kv_file` + `subject_key` |
| one comment token per request, outside MAX_ACTIVE_LINKS | `share_links.purpose = approval` |

- **Model.** An approval request is what was sent together: `number` (1, 2, … per file), `policy`, `approvers`, `message`, `decide_by`, `deferred_until`, `deferred_note`, `status`, and its own link. Each artboard in it gets its own approval: `subject_type = kv_file`, `subject_id` = the file, `subject_key` = the artboard, `round` counted per artboard (1, 2, …), `policy` and `approvers` copied from the request. A deck or plan approval has `approval_request_id = null` and `subject_key = null` and behaves exactly as C-1…C-9 describe.
- **Artboard key** (`subject_key`; an identity — compare it, never parse it): sketch / craft board `board:{first generation id of the board's chain}` (unchanged by Craft iterations and restores; a board forked into a new artboard starts a new chain and gets a new key; a board with no recorded chain uses its tip id); resize tile `resize:{kv_resize_exports.id}`; motion clip `motion:{kv_motion_project_id}:{ratio}`. An artboard reachable from two phases is listed once, under the first phase in canonical order (sketch, craft, resize, motion).
- **Version.** `version_id` is the id the page renders: the board's chain tip, the resize row id, the newest motion render of its (project, ratio). `snapshot` is the payload item exactly as rendered when the request was sent — board `{ id, kind: "board", name, image_url, aspect_ratio, is_master, overlays }`, resize `{ id, kind: "resize", platform_id, platform_label, width, height, image_url, overlays, source_overlays, source_width, source_height }`, motion `{ id, kind: "motion", video_url, ratio, width, height, duration_ms }`. Two renders are the **same version** when `version_id` matches **and** the artwork matches (image or video URL, dimensions, overlays); a regenerated resize tile keeps its row id but is a new version. Labels: `"{Sketch|Craft} · {board name}"` (`Untitled board` when unnamed), `"Resize · {platform_label} · {w}×{h}"`, `"Motion · {ratio} · {w}×{h}"`; at most 160 chars (longer ones end in `...`); display text only.
- **Rules.** At most one `pending` approval per artboard. A new request that contains an artboard still pending in another request replaces it: the old approval becomes `not_relevant`, the new one gets `supersedes_approval_id` = the old id and the next round, and the other request stays open for its other artboards. `supersedes_approval_id` is set only when a pending approval was replaced. Resolution per approval is FR-3: `optional` → the first resolving decision settles the artboard; `required` → only named approvers count, any `changes_required` settles at once, otherwise it settles once every named approver has decided; advisory decisions never settle anything.
- **Request status**, recalculated with every decision, replacement and withdraw, ignoring `not_relevant` approvals: `pending` if any is pending; else `changes_required` if any is; else `approved_with_changes` if any is; else `approved`; `not_relevant` when nothing is left (every approval replaced, or the request withdrawn). `resolved_at` is set when it leaves `pending`. Withdraw sets every still-pending approval and the request to `not_relevant`.
- **`GET v1/approval-requests/preview?subject_type=kv_file&subject_id={file}&kv_phases[]=…`** (same auth as `GET v1/approvals`) → `200 { "data": { "phases": [ { "phase", "count" } ], "items": [ { "subject_key", "phase", "label", "version_id", "thumbnail_url": "…" | null, "replaces": { "request_number", "round" } | null } ], "already_approved": [ { "subject_key", "phase", "label", "version_id" } ], "waiting": [ { "subject_key", "phase", "label", "version_id", "request_number" } ], "total": n } }`. A candidate is an artboard that is marked ready and renders. Compared with its latest approval: none, a different version, or the same version that was not approved and is not pending → `items` (`replaces` set when that latest approval is still pending in another request); same version `approved` / `approved_with_changes` → `already_approved`; same version still `pending` → `waiting` (identical artwork is never re-sent). `kv_phases` (omitted = every phase) narrows `items`, `already_approved`, `waiting` and `total`; `phases` counts, per phase, the artboards that would be in `items` if that phase were selected, ignoring `kv_phases`. `total` = number of `items`. `thumbnail_url` = the snapshot's `image_url` (`null` for motion and for a layer-composed resize tile).
- **`POST v1/approval-requests`** `{ "subject_type": "kv_file", "subject_id": "…", "kv_phases": ["craft", "resize"] (optional, distinct), "approver_emails": ["…"] (0..10, distinct), "message": "…" (≤ 500), "decide_by": "YYYY-MM-DD" (optional, after today) }` → `201 { "data": { "request": AgencyRequest, "share_url": "https://{web}/s/{token}", "approvers": [ { "email", "name", "user_id", "personal_url", "mail_sent" } ] } }`. It sends exactly the preview's `items` for those phases, frozen as snapshots, and mints a new `role = comment`, `purpose = approval`, never-expiring link whose `phases` are the request's phases (a link is never reused across requests). Named approvers get a personal lane and `ApprovalRequestMail` labelled `Request {n} · {count} artboard(s)`. `policy` = `required` with approvers, else `optional`. `decide_by` is stored as the end of that day (app timezone) and returned as an ISO timestamp. Errors: `422 { "code": "nothing_ready" }`; `422 { "code": "too_many_items", "max": 50 }`; `422 { "code": "already_a_member", "email" }`; `409 { "code": "round_conflict" }` (a concurrent request won; retry); standard `422` validation.
- **`GET v1/approval-requests?subject_type=kv_file&subject_id={file}`** → `{ "data": [AgencyRequest, …] }`, open (`pending`) requests first, then newest first. `AgencyRequest = { "id", "number", "status", "policy", "message", "sent_at", "decide_by", "deferred_until", "deferred_note", "resolved_at", "created_at", "share_url": "…" | null, "share_link_active": bool, "counts": { "approved", "approved_with_changes", "changes_required", "pending", "superseded" }, "approvers": [ { "name", "email", "user_id", "personal_url": "…" | null, "decided": bool } ], "approvals": [ { "id", "subject_key", "phase", "label", "round", "version_id", "thumbnail_url", "status", "superseded_by_request_number": n | null, "pin_count": n, "decisions": [Decision…] } ] }`. `approvals` are ordered by phase (canonical), then send order. `counts.superseded` counts replaced approvals; a withdrawn approval is in no count. An approver is `decided` when no still-pending approval of the request is waiting on them. `personal_url` is `null` while the request's link or the approver's lane is not active. `pin_count` counts client root pins (guest or lane author) on that approval's version placed while it was the artboard's approval: at or after it was created and, if replaced, before its successor was created.
- **`POST v1/approval-requests/{id}/withdraw`** → `200 { "data": AgencyRequest }`; `409 { "code": "round_closed" }` when not pending. **`POST v1/approval-requests/{id}/resend`** → `200 { "sent": ["…"] }`; `422 { "code": "no_named_approvers" }` for an `optional` request. Gate: the requester, or a workspace member who may request approval on the file; another workspace's id is `404`.
- **`v1/approvals` and KV.** `POST v1/approvals` with `subject_type = kv_file` → `422 { "code": "use_approval_requests" }` (`kv_ready_item_id` and `kv_phases` are gone). `GET v1/approvals` for `kv_file` lists only approvals that belong to no request (none in practice). `withdraw` / `resend` on an approval that belongs to a request → `422 { "code": "use_approval_requests" }`.
- **Share links.** `share_links.purpose` is `share` (every link the panels create) or `approval` (minted by a request). Approval links never count against `MAX_ACTIVE_LINKS`, never appear in `GET v1/studio/files/{id}/share-links`, are `404` to `PATCH` / `DELETE v1/studio/files/{id}/share-links/{linkId}`, and never become the legacy `share_token`. `PATCH v1/studio/files/{id} { "share_token": "enable" }` replaces view links only; `{ "share_token": "disable" }` revokes every link of the file, approval links included. Revoking a request's link withdraws the request if it is still pending, exactly as Withdraw does; a decided request stays as it is.
- **C-1 for an approval link** (`purpose = approval`). The link shows the request it was sent for, forever — also once decided or withdrawn; a revoked or expired link is the usual 404. `approval` is `null`, and the body adds `"request": { "id", "number", "status", "message", "decide_by", "deferred_until", "deferred_note", "approvers": [ { "name", "decided" } ], "counts": { …as AgencyRequest… } }` and `"approvals": [ { "id", "phase", "label", "round", "version_id", "status", "snapshot", "replaced": bool, "decisions": [Decision…] } ]` (ordered as AgencyRequest). `items` mirrors `approvals` in the item shape `{ "id", "phase", "label", "version_id", "status", "snapshot" }`. `version` = `{ "type": "approval_request", "id": "<request id>", "label": "Request {n}", "created_at": "<sent_at>" }`. `document` is built from the snapshots — `{ "name", "brand_slug", "phases": [ { "phase", "items": [snapshot, …] } ] }`, canonical phase order, only phases that hold artboards, replaced artboards included — so edits or unmarks after sending never change the page. `access` = `{ "role": "comment", "expires_at": null, "can_decide": <request.status = pending>, "verification_required": false }`.
- **C-1 for every other link** (deck, plan, KV view or older comment link) is unchanged; `items` is `[]` and there is no `request` / `approvals` key. Decision objects carry no `item_id`.
- **C-3 for an approval link.** Body `{ "approval_ids": ["…"] (1..50, distinct, approvals of this request), "outcome": "approved" | "changes_required" | "deferred", "note": "…", "pins": ["…"], "deferred_until": "YYYY-MM-DD", "guest_name": "…", "guest_email": "…" }`. `approved` / `changes_required` require `approval_ids`; `deferred` prohibits it; `approved_with_changes` is not accepted (`422` on `outcome`). An id that is not an approval of this request → `422 { "code": "invalid_approval" }`, nothing recorded. Per id: still `pending` → a decision is recorded (`decided`); replaced → `skipped_replaced`; otherwise closed → `skipped_closed`. `pins` are the decider's own pins placed this visit; each is matched to the approval whose version it is anchored on and during which it was placed; a pin that matches no approval in `approval_ids` → `422` on `pins`; pins on skipped approvals are dropped. `approved` with ≥ 1 matched pin is stored as `approved_with_changes`. `changes_required` with no `note`, when any still-pending approval in the post has no matched pin → `422 { "code": "note_required" }`, nothing recorded. Advisory is decided per approval by the FR-3 rule. `deferred` sets the request's `deferred_until` (end of that day; after today, ≤ today + 14 days) and `deferred_note`, records no decision, and needs a pending request. A `not_relevant` request (withdrawn, or every artboard replaced) → `409 { "code": "round_closed" }`. `201 { "data": { "results": [ { "approval_id", "result": "decided" | "skipped_closed" | "skipped_replaced", "decision": Decision | null } ], "request": { …as C-1… }, "approvals": [ …as C-1… ] } }`; `results` is `[]` for `deferred`. `approval_ids` on any other link → `422` on `approval_ids`.
- **C-4 for an approval link.** `GET` lists root pins whose version segment is one of the request's approvals' `version_id` and that were placed while that approval was the artboard's approval (at or after it was created; for a replaced one, before its successor was created), plus their replies. `POST` accepts a new root pin only on the version of a non-replaced approval of the request (`422 { "code": "invalid_anchor", "message": "That element is not in this round." }` otherwise). For every other link, "this round's version" is the round's `subject_version_id`, and only root pins placed at or after the round started count.
- **Notifications for requests.** On send: inbox `approval_requested` (requester + internal brand members) and `ApprovalRequestMail` per named approver, label `Request {n} · {count} artboard(s)`. Decisions are not mailed one by one: every decision stamps the request, and one digest goes out 15 minutes after the last decision, or at once when the request leaves `pending`. The digest goes to the requester by mail (`{Client} reviewed Request {n} — {file}`, a counts line such as `5 approved · 1 new version asked · 2 still open`, and one line per artboard decided since the last digest with its pin count) and to the P0a inbox audience (`approval_decided`). `deferred` notifies at once (`ApprovalDecidedMail`, "{name} asked for more time"), as in P0a.
- **C-9 approvers** (agency shape of rounds and requests) carry `"personal_url": "<frontend>/s/{token}?k={lane code}" | null` — the named approver's own link; `null` once their lane is revoked or expired, or while the round's or request's link is not active. The public approver shape never carries it. `POST public/lane/magic-link` is unchanged; web also calls it from the decision page so a named approver on the plain link can get their personal lane back. `POST v1/brands/{brand}/clients/{user}/lane-link/rotate` points `personal_url` at the newest active link of a round or request that names that client.
- **Revoking a round's link** (`DELETE …/share-links/{id}`, or a path that revokes all of a subject's links) withdraws its still-pending round exactly as `POST v1/approvals/{id}/withdraw` does; decided rounds stay. The C-9 round shape carries `"share_link_active": boolean`.
````

- [ ] **Step 2: Check the edit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && /usr/bin/grep -n "^### Additive notes\|^## Scope\|multi-item approval rounds" docs/prd/client-lane-p0a/api.md
```
Expected: two `### Additive notes` headings (post-freeze, KV approval requests), then `## Scope`; the only "multi-item approval rounds" hit is inside the new section's first sentence.

- [ ] **Step 3: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && /usr/bin/git add docs/prd/client-lane-p0a/api.md && /usr/bin/git commit -m "docs(api): client-lane contract — KV approval requests replace multi-item rounds"
```

- [ ] **Step 4: Flag for Jeff and the web plan**

Tell Daffa: the contract diff (this commit, and the byte-identical web copy the web plan makes) needs Jeff's review; spec §9 open questions 1 and 4 (board key, revoke-withdraws) are visible in it. Implementation continues; no PR until Jeff acks.

---
### Task 2: Schema — `approval_requests`, request columns on `approvals`, `share_links.purpose`

Additive: the old `approval_items` tables stay until Task 3, so the branch is green after this commit.

**Files:**
- Create: `database/migrations/2026_10_01_100000_create_approval_requests_table.php`
- Create: `database/migrations/2026_10_01_100100_add_request_columns_to_approvals.php`
- Create: `database/migrations/2026_10_01_100200_add_purpose_to_share_links.php`
- Create: `app/Models/ApprovalRequest.php`
- Create: `database/factories/ApprovalRequestFactory.php`
- Modify: `app/Models/Approval.php` (docblock, `$fillable`, `casts()`, relations after `supersedes()`)
- Modify: `app/Models/ShareLink.php` (constants after `ROLES`, `$fillable`)
- Modify: `tests/Support/ClientLaneFixtures.php` (new seeders)
- Test: `tests/Feature/Approval/ApprovalRequestSchemaTest.php`

**Interfaces:**
- Consumes: `approvals`, `share_links`, `brands`, `workspaces`, `users` tables.
- Produces:
  - Table `approval_requests` (spec §4.1 columns), `UNIQUE(subject_type, subject_id, number)`.
  - `approvals.approval_request_id|subject_key|phase|label|snapshot`; unique index `approvals_subject_key_round_unique` on `(subject_type, subject_id, COALESCE(subject_key, ''), round)`.
  - `share_links.purpose` (`share` | `approval`, default `share`).
  - `App\Models\ApprovalRequest` — `SUBJECT_TYPES = ['kv_file']`, `approvals(): HasMany`, `shareLink(): BelongsTo`, `requester(): BelongsTo`, `isPending(): bool`, `approverUserIds(): list<string>`, `scopeForSubject(Builder, string, string)`.
  - `Approval::approvalRequest(): BelongsTo`, `Approval::PHASES = ['sketch','craft','resize','motion']`; fillable `approval_request_id, subject_key, phase, label, snapshot`; `snapshot` cast `array`.
  - `ShareLink::PURPOSE_SHARE = 'share'`, `ShareLink::PURPOSE_APPROVAL = 'approval'`, `ShareLink::PURPOSES`; `purpose` fillable.
  - `ClientLaneFixtures::owner(User, Workspace): void`, `::clientRole(Workspace): BrandRole`, `::kvRequest(StudioFile, User, int $number = 1, array $attrs = []): ApprovalRequest`.

- [ ] **Step 1: Write the failing test**

Create `tests/Feature/Approval/ApprovalRequestSchemaTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Models\Approval;
use App\Models\ApprovalRequest;
use App\Models\ShareLink;
use App\Services\Sharing\ShareLinkService;
use Illuminate\Database\QueryException;
use Illuminate\Support\Facades\DB;
use Tests\Support\ClientLaneFixtures;

/** SQLSTATE of what `$write` threw (inside a savepoint, so the test transaction survives), or null. */
function schemaTestSqlState(callable $write): ?string
{
    try {
        DB::transaction($write);
    } catch (QueryException $e) {
        return (string) $e->getCode();
    }

    return null;
}

beforeEach(function () {
    $this->kv = ClientLaneFixtures::kvFile();
    $this->file = $this->kv['file'];
    $this->user = $this->kv['user'];
    $this->request = ClientLaneFixtures::kvRequest($this->file, $this->user);
    $this->kvRow = fn (string $key, int $round = 1, array $attrs = []): Approval => Approval::factory()->create(array_merge([
        'subject_type' => 'kv_file',
        'subject_id' => $this->file->id,
        'workspace_id' => $this->file->workspace_id,
        'brand_id' => $this->file->brand_id,
        'approval_request_id' => $this->request->id,
        'subject_key' => $key,
        'phase' => 'craft',
        'label' => 'Craft · Hero board',
        'snapshot' => ['id' => 'g1', 'kind' => 'board'],
        'subject_version_type' => Approval::VERSION_KV_GENERATION,
        'subject_version_id' => strtolower((string) str()->ulid()),
        'round' => $round,
        'message' => null,
    ], $attrs));
});

test('KV artboards and deck rounds coexist under the new unique index', function () {
    ($this->kvRow)('board:01aaaaaaaaaaaaaaaaaaaaaaaa');
    ($this->kvRow)('resize:01bbbbbbbbbbbbbbbbbbbbbbbb');
    $deck = Approval::factory()->create();

    expect(Approval::query()->forSubject('kv_file', $this->file->id)->count())->toBe(2)
        ->and($deck->fresh()->approval_request_id)->toBeNull()
        ->and($deck->fresh()->subject_key)->toBeNull();
});

test('one artboard cannot hold the same round twice', function () {
    ($this->kvRow)('board:01aaaaaaaaaaaaaaaaaaaaaaaa');

    expect(schemaTestSqlState(fn () => ($this->kvRow)('board:01aaaaaaaaaaaaaaaaaaaaaaaa')))->toBe('23505')
        ->and(schemaTestSqlState(fn () => ($this->kvRow)('board:01aaaaaaaaaaaaaaaaaaaaaaaa', 2)))->toBeNull();
});

test('deck rounds keep their old uniqueness because their subject_key is null', function () {
    $first = Approval::factory()->create();

    expect(schemaTestSqlState(fn () => Approval::factory()->create([
        'subject_id' => $first->subject_id,
        'workspace_id' => $first->workspace_id,
        'brand_id' => $first->brand_id,
        'round' => 1,
    ])))->toBe('23505');
});

test('request numbers are unique per file and deleting a request deletes its approvals', function () {
    $approval = ($this->kvRow)('board:01aaaaaaaaaaaaaaaaaaaaaaaa');

    expect(schemaTestSqlState(fn () => ClientLaneFixtures::kvRequest($this->file, $this->user, 1)))->toBe('23505');

    $this->request->delete();

    expect(Approval::query()->find($approval->id))->toBeNull();
});

test('a phase outside the four, or a request status outside the five, is refused', function () {
    expect(schemaTestSqlState(fn () => ($this->kvRow)('board:01cccccccccccccccccccccccc', 1, ['phase' => 'deck'])))->toBe('23514')
        ->and(schemaTestSqlState(fn () => $this->request->forceFill(['status' => 'open'])->save()))->toBe('23514');
});

test('share links default to purpose share and accept only share or approval', function () {
    $link = app(ShareLinkService::class)->create($this->file, $this->user, ['craft']);

    expect($link->fresh()->purpose)->toBe(ShareLink::PURPOSE_SHARE)
        ->and(schemaTestSqlState(fn () => ShareLink::query()->whereKey($link->id)->update(['purpose' => 'other'])))->toBe('23514')
        ->and(schemaTestSqlState(fn () => ShareLink::query()->whereKey($link->id)->update(['purpose' => ShareLink::PURPOSE_APPROVAL])))->toBeNull();
});

test('a request round-trips its approvers, dates and relations', function () {
    $this->request->forceFill([
        'approvers' => [['user_id' => $this->user->id, 'lane_link_id' => null, 'email' => 'dina@brand.test', 'name' => 'Dina']],
        'decide_by' => now()->addDays(2)->endOfDay(),
    ])->save();
    $approval = ($this->kvRow)('board:01aaaaaaaaaaaaaaaaaaaaaaaa');

    $fresh = ApprovalRequest::query()->with('approvals')->find($this->request->id);

    expect($fresh->approverUserIds())->toBe([$this->user->id])
        ->and($fresh->decide_by)->not->toBeNull()
        ->and($fresh->isPending())->toBeTrue()
        ->and($fresh->approvals->pluck('id')->all())->toBe([$approval->id])
        ->and($approval->approvalRequest->is($fresh))->toBeTrue();
});
```

- [ ] **Step 2: Run — expect FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && ls bootstrap/cache/config.php 2>/dev/null; DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/ApprovalRequestSchemaTest.php --compact
```
Expected: FAIL — `Class "App\Models\ApprovalRequest" not found` (from `ClientLaneFixtures::kvRequest`).

- [ ] **Step 3: Create the three migrations**

`database/migrations/2026_10_01_100000_create_approval_requests_table.php`:

```php
<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * Client lane — KV approval requests (spec 2026-10-01 §4.1).
 *
 * One row per "Request approval" send on a KV file: what was sent together
 * (message, approvers, deadline, its own link). Each artboard in it is an
 * `approvals` row pointing back here (`approvals.approval_request_id`).
 * `number` counts requests per file (1, 2, …). `last_decision_at` /
 * `digest_sent_at` are the decision digest's bookkeeping (§4.7).
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('approval_requests', function (Blueprint $table) {
            $table->ulid('id')->primary();
            $table->foreignUlid('workspace_id')->constrained('workspaces')->cascadeOnDelete();
            $table->char('brand_id', 26);
            $table->string('subject_type', 32);
            $table->ulid('subject_id');
            $table->unsignedSmallInteger('number');
            $table->foreignUlid('requested_by')->nullable()->constrained('users')->nullOnDelete();
            $table->string('policy', 16);
            $table->jsonb('approvers')->default('[]');
            $table->text('message')->nullable();
            $table->foreignUlid('share_link_id')->nullable()->constrained('share_links')->nullOnDelete();
            $table->timestampTz('sent_at')->nullable();
            $table->timestampTz('decide_by')->nullable();
            $table->timestampTz('deferred_until')->nullable();
            $table->text('deferred_note')->nullable();
            $table->string('status', 32)->index();
            $table->timestampTz('resolved_at')->nullable();
            $table->timestampTz('last_decision_at')->nullable();
            $table->timestampTz('digest_sent_at')->nullable();
            $table->timestampsTz();

            $table->foreign('brand_id')->references('id')->on('brands')->cascadeOnDelete();
            $table->unique(['subject_type', 'subject_id', 'number']);
            $table->index('share_link_id');
        });

        if (DB::getDriverName() === 'pgsql') {
            DB::statement(
                'ALTER TABLE approval_requests ADD CONSTRAINT approval_requests_policy_check '
                ."CHECK (policy IN ('optional', 'required'))"
            );
            DB::statement(
                'ALTER TABLE approval_requests ADD CONSTRAINT approval_requests_status_check '
                ."CHECK (status IN ('pending', 'approved', 'approved_with_changes', 'changes_required', 'not_relevant'))"
            );
            DB::statement(
                'ALTER TABLE approval_requests ADD CONSTRAINT approval_requests_subject_type_check '
                ."CHECK (subject_type IN ('kv_file'))"
            );
        }
    }

    public function down(): void
    {
        Schema::dropIfExists('approval_requests');
    }
};
```

`database/migrations/2026_10_01_100100_add_request_columns_to_approvals.php`:

```php
<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * Client lane — KV approval requests (spec 2026-10-01 §4.1): one `approvals`
 * row per artboard per round. `subject_key` names the artboard (§4.2), so
 * uniqueness moves from (subject, round) to (subject, artboard, round). Deck
 * and plan rows keep `subject_key = NULL`, and `COALESCE(subject_key, '')`
 * gives them exactly the old (subject, round) uniqueness.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('approvals', function (Blueprint $table) {
            $table->foreignUlid('approval_request_id')->nullable()->constrained('approval_requests')->cascadeOnDelete();
            $table->string('subject_key', 160)->nullable();
            $table->string('phase', 16)->nullable();
            $table->string('label', 160)->nullable();
            $table->jsonb('snapshot')->nullable();

            $table->index('approval_request_id');
            $table->dropUnique(['subject_type', 'subject_id', 'round']);
        });

        DB::statement(
            'CREATE UNIQUE INDEX approvals_subject_key_round_unique '
            ."ON approvals (subject_type, subject_id, COALESCE(subject_key, ''), round)"
        );

        if (DB::getDriverName() === 'pgsql') {
            DB::statement(
                'ALTER TABLE approvals ADD CONSTRAINT approvals_phase_check '
                ."CHECK (phase IS NULL OR phase IN ('sketch', 'craft', 'resize', 'motion'))"
            );
        }
    }

    /**
     * Destructive on purpose: request-owned rows share rounds across
     * artboards and would violate the restored (subject, round) unique.
     */
    public function down(): void
    {
        DB::table('approvals')->whereNotNull('approval_request_id')->delete();

        if (DB::getDriverName() === 'pgsql') {
            DB::statement('ALTER TABLE approvals DROP CONSTRAINT IF EXISTS approvals_phase_check');
        }
        DB::statement('DROP INDEX IF EXISTS approvals_subject_key_round_unique');

        Schema::table('approvals', function (Blueprint $table) {
            $table->dropForeign(['approval_request_id']);
            $table->dropIndex(['approval_request_id']);
            $table->dropColumn(['approval_request_id', 'subject_key', 'phase', 'label', 'snapshot']);
            $table->unique(['subject_type', 'subject_id', 'round']);
        });
    }
};
```

`database/migrations/2026_10_01_100200_add_purpose_to_share_links.php`:

```php
<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * Client lane — KV approval requests (spec 2026-10-01 §4.4): a request mints
 * its own `purpose = approval` link, which is not a view link — it never
 * counts against MAX_ACTIVE_LINKS and never lists in the share panel.
 * Every existing link is a view (or P0a comment) link: `share`.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('share_links', function (Blueprint $table) {
            $table->string('purpose', 16)->default('share');
        });

        if (DB::getDriverName() === 'pgsql') {
            DB::statement(
                'ALTER TABLE share_links ADD CONSTRAINT share_links_purpose_check '
                ."CHECK (purpose IN ('share', 'approval'))"
            );
        }
    }

    public function down(): void
    {
        if (DB::getDriverName() === 'pgsql') {
            DB::statement('ALTER TABLE share_links DROP CONSTRAINT IF EXISTS share_links_purpose_check');
        }

        Schema::table('share_links', function (Blueprint $table) {
            $table->dropColumn('purpose');
        });
    }
};
```

- [ ] **Step 4: Create the model and factory**

`app/Models/ApprovalRequest.php`:

```php
<?php

declare(strict_types=1);

namespace App\Models;

// craftsman-ignore: PHP002 — Eloquent models are not final in this codebase.

use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Collection;
use Illuminate\Database\Eloquent\Concerns\HasUlids;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;
use Illuminate\Support\Carbon;

/**
 * What the agency sent together in one "Request approval" on a KV file
 * (docs/superpowers/specs/2026-10-01-client-lane-kv-approval-requests-design.md
 * §4.1): the message, the named approvers, the deadline, the deferral and its
 * own `purpose = approval` link. Each artboard in it is one `approvals` row
 * (`approval_request_id`); `status` is their roll-up
 * ({@see \App\Services\Approval\ApprovalRequestRollup}).
 *
 * @property string $id
 * @property string $workspace_id
 * @property string $brand_id
 * @property string $subject_type
 * @property string $subject_id
 * @property int $number
 * @property string|null $requested_by
 * @property string $policy
 * @property array<int, array{user_id: string|null, lane_link_id: int|null, email: string, name: string}> $approvers
 * @property string|null $message
 * @property string|null $share_link_id
 * @property Carbon|null $sent_at
 * @property Carbon|null $decide_by
 * @property Carbon|null $deferred_until
 * @property string|null $deferred_note
 * @property string $status
 * @property Carbon|null $resolved_at
 * @property Carbon|null $last_decision_at
 * @property Carbon|null $digest_sent_at
 * @property Carbon|null $created_at
 * @property-read Collection<int, Approval> $approvals
 */
class ApprovalRequest extends Model
{
    use HasFactory, HasUlids;

    protected $table = 'approval_requests';

    /** KV only (spec D-2): decks and plans keep P0a rounds. */
    public const SUBJECT_TYPES = ['kv_file'];

    protected $fillable = [
        'workspace_id',
        'brand_id',
        'subject_type',
        'subject_id',
        'number',
        'requested_by',
        'policy',
        'approvers',
        'message',
        'share_link_id',
        'sent_at',
        'decide_by',
        'deferred_until',
        'deferred_note',
        'status',
        'resolved_at',
        'last_decision_at',
        'digest_sent_at',
    ];

    protected function casts(): array
    {
        return [
            'number' => 'integer',
            'approvers' => 'array',
            'sent_at' => 'datetime',
            'decide_by' => 'datetime',
            'deferred_until' => 'datetime',
            'resolved_at' => 'datetime',
            'last_decision_at' => 'datetime',
            'digest_sent_at' => 'datetime',
        ];
    }

    /** One approval per artboard per round. */
    public function approvals(): HasMany
    {
        return $this->hasMany(Approval::class, 'approval_request_id');
    }

    public function shareLink(): BelongsTo
    {
        return $this->belongsTo(ShareLink::class, 'share_link_id');
    }

    public function requester(): BelongsTo
    {
        return $this->belongsTo(User::class, 'requested_by');
    }

    public function isPending(): bool
    {
        return $this->status === Approval::STATUS_PENDING;
    }

    /** @return list<string> user ids of the named approvers */
    public function approverUserIds(): array
    {
        return array_values(array_filter(array_map(
            static fn (array $a): ?string => isset($a['user_id']) ? (string) $a['user_id'] : null,
            $this->approvers ?? [],
        )));
    }

    public function scopeForSubject(Builder $query, string $subjectType, string $subjectId): Builder
    {
        return $query->where('subject_type', $subjectType)->where('subject_id', $subjectId);
    }
}
```

`database/factories/ApprovalRequestFactory.php`:

```php
<?php

namespace Database\Factories;

use App\Models\Approval;
use App\Models\ApprovalRequest;
use App\Models\Brand;
use App\Models\User;
use App\Models\Workspace;
use Illuminate\Database\Eloquent\Factories\Factory;
use Illuminate\Support\Str;

/**
 * @extends Factory<ApprovalRequest>
 */
class ApprovalRequestFactory extends Factory
{
    protected $model = ApprovalRequest::class;

    /** Callers pass the real file's workspace/brand/subject (see ClientLaneFixtures::kvRequest). */
    public function definition(): array
    {
        return [
            'workspace_id' => Workspace::factory(),
            'brand_id' => Brand::factory(),
            'subject_type' => 'kv_file',
            'subject_id' => strtolower((string) Str::ulid()),
            'number' => 1,
            'requested_by' => User::factory(),
            'policy' => Approval::POLICY_OPTIONAL,
            'approvers' => [],
            'message' => null,
            'share_link_id' => null,
            'sent_at' => now(),
            'status' => Approval::STATUS_PENDING,
        ];
    }
}
```

- [ ] **Step 5: Extend `Approval` and `ShareLink`**

In `app/Models/Approval.php`:
- Docblock: after `* @property string|null $resolved_by_decision_id` add
  ```php
   * @property string|null $approval_request_id
   * @property string|null $subject_key
   * @property string|null $phase
   * @property string|null $label
   * @property array<string, mixed>|null $snapshot
   * @property Carbon|null $created_at
  ```
- After `public const VERSION_FINGERPRINT = 'fingerprint';` add
  ```php
      /** KV artboard phases (KV approval requests §4.1); null for deck/plan rows. */
      public const PHASES = ['sketch', 'craft', 'resize', 'motion'];
  ```
- `$fillable`: append `'approval_request_id', 'subject_key', 'phase', 'label', 'snapshot',` after `'resolved_by_decision_id',`.
- `casts()`: add `'snapshot' => 'array',`.
- After `supersedes()` add:
  ```php
      /** The request this artboard approval was sent in; null for deck/plan rounds. */
      public function approvalRequest(): BelongsTo
      {
          return $this->belongsTo(ApprovalRequest::class, 'approval_request_id');
      }
  ```

In `app/Models/ShareLink.php` after `public const ROLES = [self::ROLE_VIEW, self::ROLE_COMMENT];` add:

```php
    /**
     * Why the link exists (KV approval requests §4.4). `share` = a view link
     * from a share panel (or a P0a comment link); `approval` = the token a KV
     * approval request minted for itself — never counted, listed or edited as
     * a view link.
     */
    public const PURPOSE_SHARE = 'share';

    public const PURPOSE_APPROVAL = 'approval';

    /** @var list<string> */
    public const PURPOSES = [self::PURPOSE_SHARE, self::PURPOSE_APPROVAL];
```
and add `'purpose',` to `$fillable` after `'role',`.

- [ ] **Step 6: Fixtures**

In `tests/Support/ClientLaneFixtures.php` add imports `use App\Models\ApprovalRequest;`, `use App\Models\BrandRole;`, `use App\Models\Role;` and these methods after `kvFile()`:

```php
    /**
     * Grant the `owner` workspace role with `internal` scope — clears both
     * the scope_role middleware and the studio file policy for HTTP tests
     * (same setup as tests/Feature/Studio/KvShareLinkTest.php).
     */
    public static function owner(User $user, Workspace $workspace): void
    {
        $role = Role::firstOrCreate(['slug' => 'owner'], ['name' => 'Owner']);
        $role->forceFill(['type' => 'workspace', 'scope' => 'internal'])->save();
        $user->roles()->attach($role->id, ['workspace_id' => $workspace->id]);
    }

    /** The workspace's external `client` brand role, which ClientLaneService::ensureClientUser() requires. */
    public static function clientRole(Workspace $workspace): BrandRole
    {
        return BrandRole::withoutGlobalScopes()->firstOrCreate(
            ['workspace_id' => $workspace->id, 'slug' => BrandRole::CLIENT_SLUG],
            ['name' => 'Client', 'scope' => 'external'],
        );
    }

    /**
     * A factory-made request on a KV file — no link, no approvals.
     *
     * @param  array<string, mixed>  $attrs
     */
    public static function kvRequest(StudioFile $file, User $user, int $number = 1, array $attrs = []): ApprovalRequest
    {
        return ApprovalRequest::factory()->create(array_merge([
            'workspace_id' => $file->workspace_id,
            'brand_id' => $file->brand_id,
            'subject_type' => 'kv_file',
            'subject_id' => $file->id,
            'number' => $number,
            'requested_by' => $user->id,
        ], $attrs));
    }
```

- [ ] **Step 7: Run — expect PASS**

Same command as Step 2. Expected: 7 passed.

- [ ] **Step 8: Mutation check**

1. In `…100100…` replace `COALESCE(subject_key, '')` with `subject_key` → run → *"deck rounds keep their old uniqueness…"* must FAIL (NULLs are distinct in a unique index, so two deck round-1 rows are accepted). Restore.
2. In `…100100…` delete the `dropUnique` line → *"KV artboards and deck rounds coexist…"* must FAIL with `23505` on the second KV row. Restore.
3. In `…100200…` delete the CHECK statement → *"share links default to purpose share…"* must FAIL (`'other'` accepted). Restore.

Re-run Step 2's command: 7 passed.

- [ ] **Step 9: Lint + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && F="database/migrations/2026_10_01_100000_create_approval_requests_table.php database/migrations/2026_10_01_100100_add_request_columns_to_approvals.php database/migrations/2026_10_01_100200_add_purpose_to_share_links.php app/Models/ApprovalRequest.php database/factories/ApprovalRequestFactory.php app/Models/Approval.php app/Models/ShareLink.php tests/Support/ClientLaneFixtures.php tests/Feature/Approval/ApprovalRequestSchemaTest.php"; for f in ${=F}; do php -l "$f"; done && vendor/bin/pint ${=F} && vendor/bin/pint --test ${=F}
```

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && /usr/bin/git add database/migrations/2026_10_01_1000*.php database/migrations/2026_10_01_1001*.php database/migrations/2026_10_01_1002*.php app/Models/ApprovalRequest.php database/factories/ApprovalRequestFactory.php app/Models/Approval.php app/Models/ShareLink.php tests/Support/ClientLaneFixtures.php tests/Feature/Approval/ApprovalRequestSchemaTest.php && /usr/bin/git commit -m "feat(api): approval_requests table, per-artboard approval columns and share link purpose"
```

---
### Task 3: Remove `approval_items`; decks and plans back to one version per round; KV refused on `v1/approvals`

Replaces the multi-item model, it does not leave it dormant: every `approval_items` / `approval_item_id` / `item_id` / `itemVersionIds` / `kv_phases` / `kv_ready_item_id` path goes. Deck and plan rounds end up exactly as P0a (plus the branch's kept fixes: pins scoped to their round, `personal_url`, `share_link_active`, revoke-withdraws).

**Files:**
- Delete: `database/migrations/2026_09_30_120000_create_approval_items_table.php`, `database/migrations/2026_09_30_120100_add_approval_item_id_to_approval_decisions.php`, `database/migrations/2026_09_30_120200_backfill_approval_items.php`, `app/Models/ApprovalItem.php`, `database/factories/ApprovalItemFactory.php`, `app/Services/Approval/FrozenItem.php`, `app/Exceptions/Approval/InvalidItemException.php`
- Delete (permission from Task 0): `tests/Feature/Approval/ApprovalItemsMigrationTest.php`, `ApprovalDecideItemsTest.php`, `ApprovalRequestItemsTest.php`, `ApprovalPinsMembershipTest.php`, `PublicShareLinkItemsTest.php`, `ApprovalControllerItemsTest.php`, `ApprovalNotifierLabelTest.php`
- Restore from `develop`: `app/Models/ApprovalDecision.php`, `app/Services/Approval/ApprovalNotifier.php`, `app/Mail/ApprovalDecidedMail.php`, `resources/views/emails/client-lane/approval-decided.blade.php`
- Create: `app/Exceptions/Approval/UseApprovalRequestsException.php`, `app/Services/Approval/PinWindow.php`
- Modify: `app/Models/Approval.php`, `app/Services/Approval/ApprovalService.php`, `app/Http/Resources/Approval/ApprovalPresenter.php`, `app/Http/Controllers/Api/Approval/ApprovalController.php`, `app/Http/Controllers/Api/PublicShareLinkController.php`, `tests/Support/ClientLaneFixtures.php`
- Test: `tests/Feature/Approval/DeckPlanApprovalRegressionTest.php`

**Interfaces:**
- Consumes: Task 2 columns (`approval_request_id`, `subject_key`, `share_links.purpose`).
- Produces:
  - `ApprovalService::request(ApprovalSubject $subject, User $requester, array $approverEmails = [], ?string $message = null, bool $send = true, bool $notify = true, bool $mintLink = true): array{approval, share_link, approvers}` — throws `UseApprovalRequestsException` for a `kv_file`.
  - `ApprovalService::decide()` / `withdraw()` throw `UseApprovalRequestsException` for a request-owned approval. `ApprovalService::resolve(Approval $locked, ?ApprovalDecision $closer = null): void` unchanged in meaning (reused by Task 14).
  - `App\Exceptions\Approval\UseApprovalRequestsException` — `CODE = 'use_approval_requests'`.
  - `App\Services\Approval\PinWindow` — `__construct(string $approvalId, string $versionId, CarbonInterface $from, ?CarbonInterface $until = null)`, `static forRound(Approval): self`, `static constrainRoots(Builder $query, list<PinWindow> $windows, string $table = 'comments'): void`.
  - `PublicShareLinkController::pinWindows(ShareLink): ?list<PinWindow>` (private; Task 12 extends it).
  - C-1 `items` is `[]` for every link; decisions carry no `item_id`.

- [ ] **Step 1: Write the failing regression test**

Create `tests/Feature/Approval/DeckPlanApprovalRegressionTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Models\Approval;
use App\Models\Deck\Deck;
use App\Models\Deck\DeckVersion;
use App\Services\Approval\ApprovalService;
use App\Services\Approval\ApprovalSubject;
use App\Services\Deck\DeckCollabWriter;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Mail;
use Tests\Support\ClientLaneFixtures;

// Spec 2026-10-01 D-2: decks and campaign plans keep the P0a round model.
// Every row they write has approval_request_id = null and subject_key = null.
beforeEach(function () {
    Mail::fake();
    $this->kv = ClientLaneFixtures::kvFile();
    $this->user = $this->kv['user'];
    $this->file = $this->kv['file'];
    ClientLaneFixtures::owner($this->user, $this->kv['workspace']);
    $this->actingAs($this->user, 'api');

    // Deck first, mock second: creating the deck must hit the real service.
    $this->deck = Deck::factory()->create([
        'workspace_id' => $this->kv['workspace']->id,
        'brand_id' => $this->kv['brand']->id,
        'created_by' => $this->user->id,
    ]);
    // No hocuspocus in tests: hand request() a live document.
    $this->mock(DeckCollabWriter::class, function ($mock) {
        $mock->shouldReceive('liveDocumentResolved')->andReturn([
            'document' => ['slides' => []],
            'source' => 'snapshot',
            'pending_count' => 0,
        ]);
    });
    $this->guest = ['guest_name' => 'Bayu', 'guest_email' => 'bayu@brand.test'];
});

test('a deck round is one approval on a frozen deck version, outside any request', function () {
    $first = app(ApprovalService::class)->request(ApprovalSubject::from($this->deck), $this->user, notify: false)['approval'];
    $second = app(ApprovalService::class)->request(ApprovalSubject::from($this->deck), $this->user, notify: false)['approval'];

    expect($first->fresh()->status)->toBe('not_relevant')
        ->and($second->round)->toBe(2)
        ->and($second->supersedes_approval_id)->toBe($first->id)
        ->and($second->subject_version_type)->toBe('deck_version')
        ->and($second->subject_version_id)->toBe((string) DeckVersion::query()->where('deck_id', $this->deck->id)->max('id'))
        ->and([$second->approval_request_id, $second->subject_key, $second->phase, $second->label, $second->snapshot])
        ->toBe([null, null, null, null, null])
        ->and($second->share_link_id)->toBe($first->share_link_id);
});

test('a plan round is one approval on the plan fingerprint, outside any request', function () {
    $fx = ClientLaneFixtures::plan();

    $approval = app(ApprovalService::class)->request(ApprovalSubject::from($fx['plan']), $fx['user'], notify: false, mintLink: false)['approval'];

    expect($approval->subject_version_type)->toBe('fingerprint')
        ->and($approval->subject_version_id)->toBe(ApprovalService::fingerprintPlan($fx['plan']))
        ->and($approval->approval_request_id)->toBeNull()
        ->and($approval->subject_key)->toBeNull()
        ->and($approval->round)->toBe(1);
});

test('a deck link decides the whole round, C-1 carries no items and no request', function () {
    $token = app(ApprovalService::class)->request(ApprovalSubject::from($this->deck), $this->user, notify: false)['share_link']->token;

    $this->postJson("/api/public/share-links/{$token}/decision", ['outcome' => 'approved', ...$this->guest])
        ->assertCreated()
        ->assertJsonPath('data.approval.status', 'approved')
        ->assertJsonMissingPath('data.decision.item_id');

    $data = $this->getJson("/api/public/share-links/{$token}")->assertOk()->json('data');

    expect($data['items'])->toBe([])
        ->and($data)->not->toHaveKey('request')
        ->and($data)->not->toHaveKey('approvals')
        ->and($data['approval']['status'])->toBe('approved')
        ->and($data['version']['type'])->toBe('deck_version');
});

test('POST v1/approvals for a kv_file answers use_approval_requests', function () {
    $this->postJson('/api/v1/approvals', ['subject_type' => 'kv_file', 'subject_id' => $this->file->id, 'kv_phases' => ['craft']])
        ->assertStatus(422)
        ->assertJson(['code' => 'use_approval_requests']);
});

test('GET v1/approvals for a kv_file lists only rounds that belong to no request', function () {
    $request = ClientLaneFixtures::kvRequest($this->file, $this->user);
    $base = [
        'subject_type' => 'kv_file',
        'subject_id' => $this->file->id,
        'workspace_id' => $this->file->workspace_id,
        'brand_id' => $this->file->brand_id,
        'requested_by' => $this->user->id,
        'subject_version_type' => Approval::VERSION_KV_GENERATION,
    ];
    $legacy = Approval::factory()->create([...$base, 'round' => 1, 'subject_version_id' => 'g-legacy']);
    Approval::factory()->create([...$base, 'round' => 1, 'subject_version_id' => 'g-artboard', 'approval_request_id' => $request->id, 'subject_key' => 'board:g-artboard', 'phase' => 'craft']);

    $ids = $this->getJson("/api/v1/approvals?subject_type=kv_file&subject_id={$this->file->id}")->assertOk()->json('data.*.id');

    expect($ids)->toBe([$legacy->id]);
});

test('withdraw and resend refuse an approval that belongs to a request', function () {
    $request = ClientLaneFixtures::kvRequest($this->file, $this->user);
    $approval = Approval::factory()->create([
        'subject_type' => 'kv_file',
        'subject_id' => $this->file->id,
        'workspace_id' => $this->file->workspace_id,
        'brand_id' => $this->file->brand_id,
        'requested_by' => $this->user->id,
        'approval_request_id' => $request->id,
        'subject_key' => 'board:g1',
        'phase' => 'craft',
        'subject_version_type' => Approval::VERSION_KV_GENERATION,
        'subject_version_id' => 'g1',
    ]);

    $this->postJson("/api/v1/approvals/{$approval->id}/withdraw")->assertStatus(422)->assertJson(['code' => 'use_approval_requests']);
    $this->postJson("/api/v1/approvals/{$approval->id}/resend")->assertStatus(422)->assertJson(['code' => 'use_approval_requests']);
    expect($approval->fresh()->status)->toBe('pending');
});

// Multi-item final review #3, kept for P0a rounds: `comments.created_at` is a
// naive `timestamp`, the round's a `timestamptz`. With the app on
// Asia/Jakarta and a UTC database session an instant comparison put the
// round 7 hours in the future and refused every pin placed in its first hours.
test('a deck pin placed during the round counts even when the app and the database disagree on the timezone', function () {
    config(['app.timezone' => 'Asia/Jakarta']);
    date_default_timezone_set('Asia/Jakarta');
    DB::statement("SET TIME ZONE 'UTC'");

    $result = app(ApprovalService::class)->request(ApprovalSubject::from($this->deck), $this->user, notify: false);
    $token = $result['share_link']->token;
    $anchor = 'deck-canvas:'.$result['approval']->subject_version_id.':slide-1';

    $pin = $this->postJson("/api/public/share-links/{$token}/comments", [
        'body' => 'Logo smaller',
        'anchor' => ['kind' => 'pin', 'id' => $anchor, 'x' => 0.3, 'y' => 0.3],
        ...$this->guest,
    ])->assertCreated()->json('data.id');

    expect($this->getJson("/api/public/share-links/{$token}/comments")->assertOk()->json('data.*.id'))->toBe([$pin]);

    $this->postJson("/api/public/share-links/{$token}/decision", [
        'outcome' => 'changes_required', 'note' => 'See pin', 'pins' => [$pin], ...$this->guest,
    ])->assertCreated()->assertJsonPath('data.decision.pins', [$pin]);
});
```

- [ ] **Step 2: Run — expect FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && ls bootstrap/cache/config.php 2>/dev/null; DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/DeckPlanApprovalRegressionTest.php --compact
```
Expected: FAIL — at least *"a deck link decides…"* (`items` holds one deck item; `item_id` present), *"POST v1/approvals for a kv_file…"* (validation error, no `code`), *"GET v1/approvals for a kv_file…"* (both ids listed), *"withdraw and resend refuse…"* (200).

- [ ] **Step 3: Delete and restore**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && /usr/bin/git rm -q database/migrations/2026_09_30_120000_create_approval_items_table.php database/migrations/2026_09_30_120100_add_approval_item_id_to_approval_decisions.php database/migrations/2026_09_30_120200_backfill_approval_items.php app/Models/ApprovalItem.php database/factories/ApprovalItemFactory.php app/Services/Approval/FrozenItem.php app/Exceptions/Approval/InvalidItemException.php tests/Feature/Approval/ApprovalItemsMigrationTest.php tests/Feature/Approval/ApprovalDecideItemsTest.php tests/Feature/Approval/ApprovalRequestItemsTest.php tests/Feature/Approval/ApprovalPinsMembershipTest.php tests/Feature/Approval/PublicShareLinkItemsTest.php tests/Feature/Approval/ApprovalControllerItemsTest.php tests/Feature/Approval/ApprovalNotifierLabelTest.php && /usr/bin/git checkout develop -- app/Models/ApprovalDecision.php app/Services/Approval/ApprovalNotifier.php app/Mail/ApprovalDecidedMail.php resources/views/emails/client-lane/approval-decided.blade.php
```
(The four restored files differ from `develop` only by the `approval_item_id` / `itemCount` / `v{round} · {n} items` changes — verified on 2026-10-01 with `git diff develop..HEAD`.)

- [ ] **Step 4: New exception and `PinWindow`**

`app/Exceptions/Approval/UseApprovalRequestsException.php`:

```php
<?php

declare(strict_types=1);

namespace App\Exceptions\Approval;

use RuntimeException;

/**
 * A KV file is approved per artboard through `v1/approval-requests`
 * (KV approval requests spec §4.5): the P0a round endpoints refuse it with
 * `422 { code: "use_approval_requests" }`.
 */
final class UseApprovalRequestsException extends RuntimeException
{
    public const CODE = 'use_approval_requests';

    public function __construct()
    {
        parent::__construct('KV files are approved per artboard. Send an approval request instead.');
    }
}
```

`app/Services/Approval/PinWindow.php`:

```php
<?php

declare(strict_types=1);

namespace App\Services\Approval;

use App\Models\Approval;
use Carbon\CarbonInterface;
use Illuminate\Contracts\Database\Query\Builder;

/**
 * Which pins belong to an approval (client lane P0a C-4; KV approval
 * requests spec §4.6 C-4): a ROOT comment whose anchor version segment
 * (`{phase}:{version}:{part}`) is the approval's version AND that was
 * placed while the approval was current — at or after it was created and,
 * when a newer request replaced it, before the successor was created.
 *
 * Bounds are compared in SQL against bound Carbon values, never as PHP
 * instants: `comments.created_at` is a naive `timestamp`, the approval's a
 * `timestamptz`, and with the app and the database session on different
 * timezones an instant comparison shifts the window by the offset
 * (multi-item final review #3).
 */
final readonly class PinWindow
{
    public function __construct(
        public string $approvalId,
        public string $versionId,
        public CarbonInterface $from,
        public ?CarbonInterface $until = null,
    ) {}

    /** A P0a round (deck, plan, a KV round from before requests): its version, from its start. */
    public static function forRound(Approval $approval): self
    {
        return new self((string) $approval->id, (string) $approval->subject_version_id, $approval->created_at);
    }

    /**
     * Restrict `$query` to root comments inside any of `$windows`. An empty
     * list matches nothing (never an empty SQL `IN ()`).
     *
     * @param  list<self>  $windows
     */
    public static function constrainRoots(Builder $query, array $windows, string $table = 'comments'): void
    {
        if ($windows === []) {
            $query->whereRaw('1 = 0');

            return;
        }

        $query->where(function ($any) use ($windows, $table): void {
            foreach ($windows as $window) {
                $any->orWhere(function ($one) use ($window, $table): void {
                    $one->whereRaw("split_part({$table}.anchor->>'id', ':', 2) = ?", [$window->versionId])
                        ->where("{$table}.created_at", '>=', $window->from);
                    if ($window->until !== null) {
                        $one->where("{$table}.created_at", '<', $window->until);
                    }
                });
            }
        });
    }
}
```

- [ ] **Step 5: `Approval` model**

In `app/Models/Approval.php` delete the `items()` and `itemVersionIds()` methods and the `* @property-read Collection<int, ApprovalItem> $items` docblock line; delete `use Illuminate\Database\Eloquent\Collection;` if nothing else uses it (pint will flag it).

- [ ] **Step 6: `ApprovalService` — one version per round, KV refused**

In `app/Services/Approval/ApprovalService.php`:

1. Imports: remove `InvalidItemException`, `NothingReadyException`, `TooManyItemsException`, `ApprovalItem`, `KvGeneration`, `KvMotionExport`, `KvResizeExport`, `ShareReadyItem`, `KvReadyToShareService`, `KvSharePayloadService`; add `use App\Exceptions\Approval\UseApprovalRequestsException;`. Keep `StudioFile` and `Collection` (used below).
2. Delete `public const MAX_ITEMS = 50;` and its docblock; delete the constructor parameter `private readonly KvSharePayloadService $kvPayload,`.
3. Replace the whole `request()` method (docblock included) with:

```php
    /**
     * One transaction: freeze the version, create round n+1, reuse-or-mint
     * the `comment` share link, provision each named approver (user + client
     * role + personal lane), then — after commit — notify and mail.
     *
     * Decks and campaign plans only. A KV file is approved per artboard
     * through {@see ApprovalRequestService} (KV approval requests spec §4).
     *
     * @param  list<string>  $approverEmails
     * @param  bool  $send  false = agency `draft` (round exists, `sent_at NULL`)
     * @param  bool  $notify  false for the legacy plan-status paths, which
     *                        have no approvers and no sheet
     * @param  bool  $mintLink  false for the legacy plan-status paths (client
     *                          lane P0a review M-6): those never surface a
     *                          share URL, so minting one is a pure side
     *                          effect that can throw {@see ShareLinkCapException}
     *                          on every unrelated edit once a brand is near
     *                          `MAX_ACTIVE_LINKS`. `approvals.share_link_id`
     *                          is nullable and `currentForLink()` already
     *                          tolerates it being unset.
     * @return array{approval: Approval, share_link: ShareLink|null, approvers: list<array{email: string, name: string, user_id: string, personal_url: string, mail_sent: bool}>}
     *
     * @throws UseApprovalRequestsException a `kv_file` subject
     * @throws ValidationException subject without brand
     * @throws AlreadyAMemberException
     * @throws ShareLinkCapException
     * @throws RoundConflictException a concurrent request opened this round first (409, retryable)
     */
    public function request(
        ApprovalSubject $subject,
        User $requester,
        array $approverEmails = [],
        ?string $message = null,
        bool $send = true,
        bool $notify = true,
        bool $mintLink = true,
    ): array {
        if ($subject->model instanceof StudioFile) {
            throw new UseApprovalRequestsException;
        }

        $emails = array_values(array_unique(array_map(
            static fn (string $e): string => strtolower(trim($e)),
            array_filter($approverEmails, static fn ($e) => is_string($e) && trim($e) !== ''),
        )));

        $brand = $subject->brand();
        if ($brand === null) {
            throw ValidationException::withMessages(['subject_id' => 'This subject has no brand.']);
        }

        // Read OUTSIDE the transaction (client lane P0a review M-1): a deck's
        // live document is a network round-trip to hocuspocus, and the
        // transaction below holds a row lock + a DB connection for its
        // duration if fetched from inside it. `freezeDeckVersion` writes the
        // fetched document, never fetches it itself, when one is supplied.
        $liveDeckDocument = $subject->model instanceof Deck
            ? ($this->collab->liveDocumentResolved($subject->model)['document'] ?? null)
            : null;

        try {
            /** @var array{approval: Approval, share_link: ShareLink|null, approvers: list<array{user: User, lane: ClientLaneLink}>} $result */
            $result = DB::transaction(function () use ($subject, $requester, $emails, $message, $send, $brand, $mintLink, $liveDeckDocument): array {
                // Lock the previous round row (client lane P0a review M-2): two
                // concurrent `request()` calls on the same subject must not both
                // read the same `$previous->round` and both try `round + 1`.
                // This closes the common case (a previous round exists); the
                // very first round on a subject has no row to lock, so the
                // catch around this transaction translates the resulting
                // unique-index collision instead.
                $previous = Approval::query()
                    ->forSubject($subject->type, (string) $subject->model->getKey())
                    ->whereNull('subject_key')
                    ->lockForUpdate()
                    ->orderByDesc('round')
                    ->first();
                $round = ($previous?->round ?? 0) + 1;

                // A new round supersedes a still-open one: close it as
                // not_relevant so a subject never carries two pending rounds
                // (the legacy "Share for approval" path re-requests freely).
                if ($previous !== null && $previous->isPending()) {
                    $previous->forceFill([
                        'status' => Approval::STATUS_NOT_RELEVANT,
                        'resolved_at' => now(),
                    ])->save();
                }

                [$versionType, $versionId] = $this->freezeVersion($subject, $round, $requester, $liveDeckDocument);

                $link = $mintLink ? $this->reuseOrMintCommentLink($subject, $requester) : null;

                $approvers = [];
                $approverRows = [];
                foreach ($emails as $email) {
                    $user = $this->lanes->ensureClientUser($brand, $email);
                    $lane = $this->lanes->mintLaneLink($brand, $user, $requester);
                    $approvers[] = ['user' => $user, 'lane' => $lane];
                    $approverRows[] = [
                        'user_id' => (string) $user->id,
                        'lane_link_id' => $lane->id,
                        'email' => (string) $user->email,
                        'name' => (string) $user->name,
                    ];
                }

                $approval = Approval::create([
                    'subject_type' => $subject->type,
                    'subject_id' => (string) $subject->model->getKey(),
                    'workspace_id' => $subject->workspaceId,
                    'brand_id' => $subject->brandId,
                    'requested_by' => $requester->id,
                    'round' => $round,
                    'supersedes_approval_id' => $previous?->id,
                    'policy' => $approverRows === [] ? Approval::POLICY_OPTIONAL : Approval::POLICY_REQUIRED,
                    'status' => Approval::STATUS_PENDING,
                    'subject_version_type' => $versionType,
                    'subject_version_id' => $versionId,
                    'approvers' => $approverRows,
                    'message' => $message !== null && trim($message) !== '' ? trim($message) : null,
                    'share_link_id' => $link?->id,
                    'sent_at' => $send ? now() : null,
                ]);

                return ['approval' => $approval, 'share_link' => $link, 'approvers' => $approvers];
            });
        } catch (QueryException $e) {
            // Any unique-index collision inside the closure is a lost race
            // with a concurrent request() on the same subject, not a caller
            // error: the round index on the very first round (no previous
            // row to lock), or `workspace_external_invites_active_personal_unique`
            // when two first rounds name the same new approver and both pass
            // mintLaneLink()'s find-then-create (client lane P0a review
            // round 2). Both answer the retryable `409 round_conflict`.
            if ((string) $e->getCode() === '23505') {
                throw new RoundConflictException;
            }
            throw $e;
        }

        $sent = [];
        if ($notify && $send) {
            $sent = $this->notifier->requested($result['approval'], $subject, $result['share_link'], $requester, $result['approvers']);
        }

        $approverOut = [];
        foreach ($result['approvers'] as $approver) {
            $approverOut[] = [
                'email' => (string) $approver['user']->email,
                'name' => (string) $approver['user']->name,
                'user_id' => (string) $approver['user']->id,
                'personal_url' => $this->lanes->personalUrl($result['share_link'], $approver['lane']),
                'mail_sent' => in_array((string) $approver['user']->email, $sent, true),
            ];
        }

        return [
            'approval' => $result['approval'],
            'share_link' => $result['share_link'],
            'approvers' => $approverOut,
        ];
    }
```

4. In `decide()`: delete `$item = $this->itemFor($locked, $input['item_id'] ?? null, $outcome);` and `'approval_item_id' => $item?->id,`; in its docblock change the `@param` shape to `array{outcome: string, note?: string|null, pins?: list<string>|null, deferred_until?: string|null}`, replace `@throws InvalidItemException …` with `@throws UseApprovalRequestsException an approval that belongs to a KV request`; and make the method's first statement:

```php
        // A KV artboard approval is decided through its request
        // (ApprovalRequestDecisionService): ids in batches, digest, no
        // per-decision mail.
        if ($approval->approval_request_id !== null) {
            throw new UseApprovalRequestsException;
        }
```

5. Replace `resolve()` (docblock included) with:

```php
    /**
     * FR-3, on an approval already locked by the caller. `$closer` forces
     * the round shut with that decision (agency sign-off). Runs unchanged
     * for a KV artboard approval: its policy and approvers are copied from
     * its request at creation (KV approval requests §4.1).
     */
    public function resolve(Approval $approval, ?ApprovalDecision $closer = null): void
    {
        if ($approval->isTerminal()) {
            return;
        }

        if ($closer !== null) {
            $this->close($approval, $closer->outcome, $closer);

            return;
        }

        $counting = $approval->decisions()
            ->where('advisory', false)
            ->whereIn('outcome', ApprovalDecision::RESOLVING_OUTCOMES)
            ->orderBy('id')
            ->get();

        $result = $this->outcomeFor($approval, $counting);
        if ($result !== null) {
            $this->close($approval, $result[0], $result[1]);
        }
    }
```

6. Delete `aggregateStatus()`, `freezeItems()`, `freezeKvItems()`, `resolveLegacyReadyItem()`, `kvPhasesOf()`, `setItemStatuses()`, `resolveItems()` and `itemFor()` entirely.
7. In `withdraw()`: delete `$this->setItemStatuses($locked, Approval::STATUS_NOT_RELEVANT);`, and add as the closure's first statement after the lock:

```php
            if ($locked->approval_request_id !== null) {
                throw new UseApprovalRequestsException;
            }
```
(and add `@throws UseApprovalRequestsException` to its docblock).
8. Add, where `freezeItems()` was:

```php
    /**
     * @param  array<string, mixed>|null  $liveDeckDocument  pre-fetched deck document (M-1), ignored for plans
     * @return array{0: string, 1: string} version type, version id
     */
    private function freezeVersion(ApprovalSubject $subject, int $round, User $requester, ?array $liveDeckDocument = null): array
    {
        $model = $subject->model;

        if ($model instanceof Deck) {
            return [Approval::VERSION_DECK, (string) $this->freezeDeckVersion($model, $round, $requester, $liveDeckDocument)->id];
        }

        if ($model instanceof CampaignPlan) {
            return [Approval::VERSION_FINGERPRINT, self::fingerprintPlan($model)];
        }

        throw ValidationException::withMessages(['subject_type' => 'Unsupported subject.']);
    }
```
9. Replace `reuseOrMintCommentLink()` (docblock included) with:

```php
    /**
     * The subject's active `comment` view link, or a new one counted against
     * `MAX_ACTIVE_LINKS`. A KV request's own `purpose = approval` link is
     * never reused here (decks and plans never have one).
     *
     * @throws ShareLinkCapException
     */
    private function reuseOrMintCommentLink(ApprovalSubject $subject, User $requester): ShareLink
    {
        $existing = ShareLink::query()
            ->where('shareable_type', $subject->type)
            ->where('shareable_id', (string) $subject->model->getKey())
            ->where('role', ShareLink::ROLE_COMMENT)
            ->where('purpose', ShareLink::PURPOSE_SHARE)
            ->active()
            ->orderByDesc('created_at')
            ->first();

        if ($existing !== null) {
            return $existing;
        }

        try {
            return $this->shareLinks->create(
                shareable: $subject->model,
                creator: $requester,
                phases: [],
                label: 'Client approval',
                expiresIn: null,
                role: ShareLink::ROLE_COMMENT,
                workspaceId: $subject->workspaceId,
            );
        } catch (ValidationException $e) {
            if (array_key_exists('share_link', $e->errors())) {
                throw new ShareLinkCapException;
            }
            throw $e;
        }
    }
```
10. In `validatePins()`: replace `$versionIds = $approval->itemVersionIds();` with `$versionId = (string) $approval->subject_version_id;`, replace `if (count($segments) < 2 || ! in_array($segments[1], $versionIds, true)) {` with `if (count($segments) < 2 || $segments[1] !== $versionId) {`, and in its docblock change "one of THIS round's item versions (`{stage}:{version}:{part}`) — C-3, multi-item spec §5.3 —" to "THIS round's version (`{stage}:{version}:{part}`) — C-3 —".
11. Replace `close()` (docblock included) with:

```php
    private function close(Approval $approval, string $status, ApprovalDecision $decision): void
    {
        $approval->forceFill([
            'status' => $status,
            'resolved_at' => now(),
            'resolved_by_decision_id' => $decision->id,
        ])->save();
    }
```

- [ ] **Step 7: `ApprovalPresenter`**

In `app/Http/Resources/Approval/ApprovalPresenter.php`: remove `use App\Models\ApprovalItem;`; change `$approval->loadMissing($agency ? ['decisions.actor:id,name', 'items'] : ['decisions.actor:id,name']);` to `$approval->loadMissing(['decisions.actor:id,name']);`; delete `$out['items'] = self::agencyItems($approval);`; delete the `'item_id' => $decision->approval_item_id,` line and its comment in `decision()`; delete the `items()` and `agencyItems()` methods; in the class docblock change "`created_at` and `items` on top" to "`created_at`, `share_link_active` and approver `personal_url` on top".

- [ ] **Step 8: `ApprovalController`**

In `app/Http/Controllers/Api/Approval/ApprovalController.php`:

1. Imports: remove `NothingReadyException`, `TooManyItemsException`, `KvSharePayloadService`; add `use App\Exceptions\Approval\UseApprovalRequestsException;`.
2. `index()`: change the query to

```php
        $rounds = Approval::query()
            ->forSubject($subject->type, (string) $subject->model->getKey())
            // KV artboard approvals live under v1/approval-requests.
            ->whereNull('approval_request_id')
            ->with(['decisions.actor:id,name'])
            ->orderByDesc('round')
            ->get();
```
3. `store()`: delete the `kv_ready_item_id`, `kv_phases` and `kv_phases.*` rules (and their comment); immediately after the `$request->validate([...])` call add

```php
        // KV is approved per artboard (KV approval requests §4.5).
        if ($validated['subject_type'] === 'kv_file') {
            return $this->useApprovalRequests();
        }
```
change the service call to `$result = $this->approvals->request($subject, $request->user(), $validated['approver_emails'] ?? [], $validated['message'] ?? null);` and delete the `NothingReadyException` and `TooManyItemsException` catch blocks.
4. `withdraw()` and `resend()`: right after `$this->authorizeManage($request, $approval);` add

```php
        if ($approval->approval_request_id !== null) {
            return $this->useApprovalRequests();
        }
```
5. `activeCommentLink()`: add `->where('purpose', ShareLink::PURPOSE_SHARE)` after the `role` condition.
6. Add:

```php
    private function useApprovalRequests(): JsonResponse
    {
        $e = new UseApprovalRequestsException;

        return response()->json(['code' => UseApprovalRequestsException::CODE, 'message' => $e->getMessage()], 422);
    }
```

- [ ] **Step 9: `PublicShareLinkController`**

In `app/Http/Controllers/Api/PublicShareLinkController.php`:

1. Imports: remove `use App\Exceptions\Approval\InvalidItemException;`; add `use App\Services\Approval\PinWindow;`.
2. `show()`: replace the two lines `// Multi-item (spec §5.2): …` / `'items' => $approval !== null ? ApprovalPresenter::items($approval) : [],` with

```php
            // Only a KV approval-request link carries artboards (Task 11).
            'items' => [],
```
3. `decision()`: delete the `item_id` rule and its comment, and the `catch (InvalidItemException $e) { … }` block.
4. Replace the whole `comments()` method body from `$approval = $this->currentApproval($link);` to the `->get();` with:

```php
        $windows = $this->pinWindows($link);
        if ($windows === null) {
            return response()->json(['data' => []])->header('Cache-Control', 'no-store');
        }

        // SECURITY (client lane P0a review #2): this is an UNAUTHENTICATED
        // surface — a lane code proves the mailbox, never workspace
        // membership. Reading the lane's `User` in here as `visibleTo`'s
        // member check would let a client who is LATER invited as a
        // workspace member (nothing revokes their lane on invite) unlock
        // `internal_only` threads by lane code alone. Always read as a
        // non-member.
        //
        // Roots inside one of the link's pin windows ({@see PinWindow}: the
        // version, placed while it was current), plus replies to those roots.
        $rows = Comment::query()
            ->where('commentable_type', $subject->type)
            ->where('commentable_id', (string) $subject->model->getKey())
            ->visibleTo(null, $subject->model)
            ->where(function ($q) use ($windows) {
                $q->where(function ($root) use ($windows) {
                    PinWindow::constrainRoots($root, $windows);
                })->orWhere(function ($reply) use ($windows) {
                    $reply->whereNotNull('parent_id')
                        ->whereExists(function ($sub) use ($windows) {
                            $sub->selectRaw('1')
                                ->from('comments as roots')
                                ->whereColumn('roots.id', 'comments.parent_id')
                                ->whereNull('roots.deleted_at');
                            PinWindow::constrainRoots($sub, $windows, 'roots');
                        });
                });
            })
            ->orderBy('created_at')
            ->with('author:id,name,avatar')
            ->get();
```
5. In `storeComment()` replace the block from `// A NEW pin (root anchor) must sit on one of THIS round's items —` through its closing `}` with:

```php
        // A NEW pin (root anchor) must sit on a version the link serves and
        // that is still current — never a stale, future or replaced one
        // (client lane P0a review M-7; KV approval requests R10). Replies
        // inherit their root's anchor and never carry their own (C-4).
        if (isset($validated['anchor']) && empty($validated['parent_id'])) {
            $windows = $this->pinWindows($link);
            if ($windows === null) {
                return $this->error(422, 'invalid_anchor', 'There is no open round to pin this to.');
            }
            $open = array_map(
                static fn (PinWindow $w): string => $w->versionId,
                array_filter($windows, static fn (PinWindow $w): bool => $w->until === null),
            );
            $anchorId = (string) $validated['anchor']['id'];
            if (
                preg_match('/^[a-z-]+:([^:]+):/', $anchorId, $match) !== 1
                || ! in_array($match[1], $open, true)
            ) {
                return $this->error(422, 'invalid_anchor', 'That element is not in this round.');
            }
        }
```
6. `document()`: replace the `StudioFile` branch with

```php
        if ($model instanceof StudioFile) {
            return $this->kvPayload->build($model, $link, (string) ($brandSlug ?? ''));
        }
```
update its docblock line for `kv_file` to "the live `KvSharePayloadService` payload for this link (an approval-request link is built from its snapshots — Task 11)", and delete `frozenKvDocument()`.
7. Add after `currentApproval()`:

```php
    /**
     * The pin windows of what this link serves: the current round's single
     * window, or null when it serves nothing (view link, withdrawn round).
     *
     * @return list<PinWindow>|null
     */
    private function pinWindows(ShareLink $link): ?array
    {
        $approval = $this->currentApproval($link);

        return $approval !== null ? [PinWindow::forRound($approval)] : null;
    }
```

- [ ] **Step 10: Fixtures**

In `tests/Support/ClientLaneFixtures.php` delete `roundWithItems()` and `requestKv()` and the imports they alone used (`ApprovalItem`, `ApprovalService`, `ApprovalSubject`, `ShareLink`); update the class docblock's spec reference to `docs/superpowers/specs/2026-10-01-client-lane-kv-approval-requests-design.md`.

- [ ] **Step 11: No leftovers**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && /usr/bin/grep -rn "ApprovalItem\|approval_item\|itemVersionIds\|FrozenItem\|InvalidItemException\|kv_ready_item_id\|kvPhases\|agencyItems\|aggregateStatus" app routes tests/Support tests/Feature/Approval database/factories; /usr/bin/grep -rn "item_id" app/Services/Approval app/Http/Controllers/Api/Approval app/Http/Controllers/Api/PublicShareLinkController.php app/Http/Resources/Approval app/Models/Approval.php app/Models/ApprovalDecision.php
```
Expected: no output from either (`KvSharePayloadService` docblock wording is Task 4's; `item_id` in deck media controllers is unrelated and outside the second grep). Any hit → remove it.

- [ ] **Step 12: Run — expect PASS**

Same command as Step 2. Expected: 7 passed. Then the kept file:

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/ApprovalRequestSchemaTest.php --compact && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/KvSharePayloadItemsForTest.php --compact
```
Expected: 7 passed; 3 passed.

- [ ] **Step 13: Mutation check**

1. `ApprovalController::store`: delete the `kv_file` early return → *"POST v1/approvals for a kv_file…"* must FAIL (500 from `UseApprovalRequestsException`). Restore.
2. `ApprovalController::index`: delete `->whereNull('approval_request_id')` → *"GET v1/approvals for a kv_file lists only…"* must FAIL. Restore.
3. `ApprovalController::withdraw`: delete the `approval_request_id` guard → *"withdraw and resend refuse…"* must FAIL. Restore.
4. `PinWindow::forRound`: pass `$approval->created_at->copy()->addHours(8)` → *"a deck pin placed during the round counts…"* must FAIL (pin not listed). Restore.

Re-run Step 2's command: 7 passed.

- [ ] **Step 14: Lint + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && F="app/Exceptions/Approval/UseApprovalRequestsException.php app/Services/Approval/PinWindow.php app/Models/Approval.php app/Models/ApprovalDecision.php app/Services/Approval/ApprovalService.php app/Services/Approval/ApprovalNotifier.php app/Mail/ApprovalDecidedMail.php app/Http/Resources/Approval/ApprovalPresenter.php app/Http/Controllers/Api/Approval/ApprovalController.php app/Http/Controllers/Api/PublicShareLinkController.php tests/Support/ClientLaneFixtures.php tests/Feature/Approval/DeckPlanApprovalRegressionTest.php"; for f in ${=F}; do php -l "$f"; done && vendor/bin/pint ${=F} && vendor/bin/pint --test ${=F}
```

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && /usr/bin/git add -A app/Exceptions/Approval app/Services/Approval app/Models app/Mail app/Http resources/views/emails/client-lane database/migrations database/factories tests/Support tests/Feature/Approval && /usr/bin/git status --short && /usr/bin/git commit -m "refactor(api): drop approval_items; decks and plans keep one version per round, KV refused on v1/approvals"
```
Expected `git status --short` before the commit: only the files of this task (deleted, restored, modified, created). Anything else → unstage it.

---
### Task 4: Artboard key, `KvArtboard` and the resolver

**Files:**
- Create: `app/Services/Approval/KvArtboard.php`
- Create: `app/Services/Approval/KvArtboardKey.php`
- Create: `app/Services/Approval/KvArtboardResolver.php`
- Modify: `app/Services/Studio/KvSharePayloadService.php` (docblocks of `itemsFor()` and `resolvePhase()` only)
- Modify: `tests/Support/ClientLaneFixtures.php` (`artboards()`, `kvApproval()`)
- Test: `tests/Feature/Approval/KvArtboardKeyTest.php`

**Interfaces:**
- Consumes: `KvSharePayloadService::itemsFor(StudioFile, array $phases): array<string, list<array>>`, `KvSnapshotService::chainForGeneration(StudioFile, string): list<string>` (chain = `version_ids` + tip; `[tip]` when none).
- Produces:
  - `KvArtboardKey::board(StudioFile $file, string $generationId): string` → `board:{chain[0]}`; `::resize(string $id): string` → `resize:{id}`; `::motion(string $projectId, string $ratio): string` → `motion:{project}:{ratio}`.
  - `KvArtboard` (readonly) — `string $phase, string $subjectKey, string $versionType, string $versionId, string $label, array $snapshot`; `static fromPayload(string $phase, string $subjectKey, array $item): self`; `fingerprint(): string`; `thumbnailUrl(): ?string`; `toApprovalAttributes(): array{subject_key, phase, label, snapshot, subject_version_type, subject_version_id}`; `static fingerprintOf(?array $snapshot): string`; `static thumbnailOf(?array $snapshot): ?string`; `static clip(string): string`; `LABEL_MAX = 160`.
  - `KvArtboardResolver::artboards(StudioFile $file, array $phases): list<KvArtboard>` — canonical phase order, payload order inside a phase, one entry per key (first phase wins).
  - `ClientLaneFixtures::artboards(StudioFile): array<string, KvArtboard>` (keyed by `subject_key`), `::kvApproval(ApprovalRequest, KvArtboard, array $attrs = []): Approval`.

- [ ] **Step 1: Fixtures**

In `tests/Support/ClientLaneFixtures.php` add imports `use App\Services\Approval\KvArtboard;`, `use App\Services\Approval\KvArtboardResolver;`, `use App\Services\Studio\KvSharePayloadService;` and:

```php
    /**
     * Every artboard the file shows a client right now, keyed by subject_key.
     *
     * @return array<string, KvArtboard>
     */
    public static function artboards(StudioFile $file): array
    {
        $out = [];
        foreach (app(KvArtboardResolver::class)->artboards($file->fresh(), KvSharePayloadService::PHASES) as $artboard) {
            $out[$artboard->subjectKey] = $artboard;
        }

        return $out;
    }

    /**
     * A KV approval row for one artboard inside a request — factory-made,
     * no service, round 1 unless `$attrs` says otherwise.
     *
     * @param  array<string, mixed>  $attrs
     */
    public static function kvApproval(ApprovalRequest $request, KvArtboard $artboard, array $attrs = []): Approval
    {
        return Approval::factory()->create(array_merge([
            'subject_type' => 'kv_file',
            'subject_id' => $request->subject_id,
            'workspace_id' => $request->workspace_id,
            'brand_id' => $request->brand_id,
            'requested_by' => $request->requested_by,
            'approval_request_id' => $request->id,
            'round' => 1,
            'policy' => $request->policy,
            'approvers' => $request->approvers ?? [],
            'message' => null,
            'sent_at' => null,
        ], $artboard->toApprovalAttributes(), $attrs));
    }
```

- [ ] **Step 2: Write the failing test**

Create `tests/Feature/Approval/KvArtboardKeyTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Models\KvMotionExport;
use App\Services\Approval\KvArtboard;
use Tests\Support\ClientLaneFixtures;

beforeEach(function () {
    $this->kv = ClientLaneFixtures::kvFile();
    $this->file = $this->kv['file'];
    $this->user = $this->kv['user'];
});

test('a board keeps its key across Craft iterations while its version follows the tip', function () {
    $first = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Hero board');
    ClientLaneFixtures::markReady('kv_generation', $first->id, $this->user);
    $second = ClientLaneFixtures::iterate($this->file, $this->user, $first, 'https://cdn.test/board-2.png');
    $tip = ClientLaneFixtures::iterate($this->file, $this->user, $second, 'https://cdn.test/board-3.png');

    $artboard = ClientLaneFixtures::artboards($this->file)["board:{$first->id}"] ?? null;

    expect($artboard)->not->toBeNull()
        ->and($artboard->phase)->toBe('craft')
        ->and($artboard->versionType)->toBe('kv_generation')
        ->and($artboard->versionId)->toBe($tip->id)
        ->and($artboard->label)->toBe('Craft · Hero board')
        ->and($artboard->snapshot['image_url'])->toBe('https://cdn.test/board-3.png');
});

test('a board with no recorded chain is keyed by its tip, and a forked board gets its own key', function () {
    $board = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Hero board');
    $fork = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Hero board copy', 'https://cdn.test/fork.png');
    ClientLaneFixtures::markReady('kv_generation', $board->id, $this->user);
    ClientLaneFixtures::markReady('kv_generation', $fork->id, $this->user);

    expect(array_keys(ClientLaneFixtures::artboards($this->file)))->toEqualCanonicalizing(["board:{$board->id}", "board:{$fork->id}"]);
});

test('a resize tile is keyed by its row, a motion clip by project and ratio across re-exports', function () {
    $board = ClientLaneFixtures::board($this->file, $this->user);
    $tile = ClientLaneFixtures::resizeTile($this->file, $this->user, $board);
    $clip = ClientLaneFixtures::motionExport($this->file, $this->user, $board);
    ClientLaneFixtures::markReady('kv_resize_export', $tile->id, $this->user);
    ClientLaneFixtures::markReady('kv_motion_export', $clip->id, $this->user);
    $newer = ClientLaneFixtures::reExport($clip, 'https://cdn.test/motion-2.mp4');

    $artboards = ClientLaneFixtures::artboards($this->file);
    $motionKey = "motion:{$clip->kv_motion_project_id}:instagram-story";

    expect(array_keys($artboards))->toBe(["resize:{$tile->id}", $motionKey])
        ->and($artboards["resize:{$tile->id}"]->versionId)->toBe($tile->id)
        ->and($artboards["resize:{$tile->id}"]->label)->toStartWith('Resize · ')->toEndWith(' · 1080×1920')
        ->and($artboards[$motionKey]->versionId)->toBe($newer->id)
        ->and($artboards[$motionKey]->versionType)->toBe('kv_motion_export')
        ->and($artboards[$motionKey]->label)->toBe('Motion · instagram-story · 1080×1920')
        ->and($artboards[$motionKey]->thumbnailUrl())->toBeNull();
});

// Ruling R15: two rows with one key and one round would violate the unique
// index and 500 the whole send.
test('an artboard reachable from two phases is listed once, under the first phase', function () {
    $sketch = ClientLaneFixtures::board($this->file, $this->user, 'sketch', 'Hero board');
    $craft = ClientLaneFixtures::iterate($this->file, $this->user, $sketch, 'https://cdn.test/craft.png');
    $craft->forceFill(['mode' => 'craft'])->save();
    ClientLaneFixtures::markReady('kv_generation', $sketch->id, $this->user);
    ClientLaneFixtures::markReady('kv_generation', $craft->id, $this->user);

    $artboards = array_values(ClientLaneFixtures::artboards($this->file));

    expect($artboards)->toHaveCount(1)
        ->and($artboards[0]->subjectKey)->toBe("board:{$sketch->id}")
        ->and($artboards[0]->phase)->toBe('sketch')
        ->and($artboards[0]->versionId)->toBe($craft->id);
});

test('the fingerprint ignores the name and follows the artwork', function () {
    $board = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Hero board');
    ClientLaneFixtures::markReady('kv_generation', $board->id, $this->user);
    $before = ClientLaneFixtures::artboards($this->file)["board:{$board->id}"];

    $metadata = $this->file->fresh()->metadata;
    $metadata['kv_canvas']['artboards'][$board->id]['name'] = 'Renamed board';
    $this->file->forceFill(['metadata' => $metadata])->save();
    $renamed = ClientLaneFixtures::artboards($this->file)["board:{$board->id}"];

    $board->forceFill(['image_url' => 'https://cdn.test/board-retouched.png'])->save();
    $retouched = ClientLaneFixtures::artboards($this->file)["board:{$board->id}"];

    expect($renamed->label)->toBe('Craft · Renamed board')
        ->and($renamed->fingerprint())->toBe($before->fingerprint())
        ->and($retouched->versionId)->toBe($before->versionId)
        ->and($retouched->fingerprint())->not->toBe($before->fingerprint());
});

// Review Focus 2: jsonb reorders object keys, and floats/empties must not
// make a stored snapshot look like different artwork.
test('the fingerprint survives a jsonb round-trip, overlays and all', function () {
    $board = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Hero board');
    $tile = ClientLaneFixtures::resizeTile($this->file, $this->user, $board);
    ClientLaneFixtures::markReady('kv_generation', $board->id, $this->user);
    ClientLaneFixtures::markReady('kv_resize_export', $tile->id, $this->user);
    $this->file->forceFill(['overlays' => [[
        'id' => 'ov-1',
        'board_generation_id' => $board->id,
        'z' => 2,
        'type' => 'text',
        'payload' => ['zeta' => 'last', 'alpha' => 'first', 'font_size' => 24.5, 'scale' => 1.0, 'x' => 0.30000000000000004, 'style' => [], 'gradient' => ['stops' => [['offset' => 0, 'color' => '#fff']]]],
    ]]])->save();

    $request = ClientLaneFixtures::kvRequest($this->file, $this->user);
    foreach (ClientLaneFixtures::artboards($this->file) as $artboard) {
        $stored = ClientLaneFixtures::kvApproval($request, $artboard)->fresh();

        expect(KvArtboard::fingerprintOf($stored->snapshot))->toBe($artboard->fingerprint());
    }
});

test('labels never overflow the column, whatever the board or tile is called', function () {
    $board = ClientLaneFixtures::board($this->file, $this->user, 'craft', str_repeat('Kampanye Ramadan ', 20)); // 340 chars
    $tile = ClientLaneFixtures::resizeTile($this->file, $this->user, $board, name: str_repeat('ポスター', 30)); // 120 multibyte chars
    ClientLaneFixtures::markReady('kv_generation', $board->id, $this->user);
    ClientLaneFixtures::markReady('kv_resize_export', $tile->id, $this->user);

    $artboards = array_values(ClientLaneFixtures::artboards($this->file));

    foreach ($artboards as $artboard) {
        expect(mb_strlen($artboard->label))->toBeLessThanOrEqual(160);
    }
    expect($artboards[0]->label)->toStartWith('Craft · Kampanye Ramadan')->toEndWith('...')
        ->and($artboards[1]->label)->toStartWith('Resize · ポスター');
});

test('a motion export whose project left the file is never an artboard', function () {
    $board = ClientLaneFixtures::board($this->file, $this->user);
    $clip = ClientLaneFixtures::motionExport($this->file, $this->user, $board);
    ClientLaneFixtures::markReady('kv_motion_export', $clip->id, $this->user);
    KvMotionExport::query()->whereKey($clip->id)->first()->project()->delete();

    expect(ClientLaneFixtures::artboards($this->file))->toBe([]);
});
```

- [ ] **Step 3: Run — expect FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && ls bootstrap/cache/config.php 2>/dev/null; DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/KvArtboardKeyTest.php --compact
```
Expected: FAIL — `Class "App\Services\Approval\KvArtboardResolver" not found`.

- [ ] **Step 4: Implement**

`app/Services/Approval/KvArtboardKey.php`:

```php
<?php

declare(strict_types=1);

namespace App\Services\Approval;

use App\Models\StudioFile;
use App\Services\Studio\KvSnapshotService;

/**
 * The stable identity of a KV artboard — `approvals.subject_key` (KV
 * approval requests spec §4.2, D-8). Stable across Craft iterations,
 * restores, tile regenerations and motion re-exports; a different value
 * means a different artboard. Compare keys, never parse them.
 */
final class KvArtboardKey
{
    /**
     * `board:{first generation id of the chain}`. A marked or tip id resolves
     * to its artboard's chain the way KvSnapshotService::resolvePublicBoards
     * does; a board with no recorded `version_ids` is its own chain, so the
     * tip id is the key. A forked board is a new artboard with a new chain.
     */
    public static function board(StudioFile $file, string $generationId): string
    {
        return 'board:'.KvSnapshotService::chainForGeneration($file, $generationId)[0];
    }

    /** `resize:{kv_resize_exports.id}` — regenerating overwrites the same row. */
    public static function resize(string $resizeExportId): string
    {
        return 'resize:'.$resizeExportId;
    }

    /** `motion:{project}:{ratio}` — a re-export appends a row; the pair is stable. */
    public static function motion(string $projectId, string $ratio): string
    {
        return 'motion:'.$projectId.':'.$ratio;
    }
}
```

`app/Services/Approval/KvArtboard.php`:

```php
<?php

declare(strict_types=1);

namespace App\Services\Approval;

use App\Models\Approval;
use Illuminate\Support\Str;

/**
 * One KV artboard as a client sees it right now (KV approval requests spec
 * §4.1–§4.2): its phase, its stable key, the version the page renders, a
 * display label and the payload item exactly as rendered — what one
 * `approvals` row freezes.
 */
final readonly class KvArtboard
{
    public const LABEL_MAX = 160;

    /**
     * The snapshot fields that ARE the artwork (ruling R1). Name, label and
     * `is_master` are not: renaming a board does not make it a new version.
     */
    private const ARTWORK_KEYS = [
        'board' => ['image_url', 'aspect_ratio', 'overlays'],
        'resize' => ['image_url', 'width', 'height', 'overlays', 'source_overlays', 'source_width', 'source_height'],
        'motion' => ['video_url', 'width', 'height', 'duration_ms'],
    ];

    /**
     * @param  array<string, mixed>  $snapshot
     */
    public function __construct(
        public string $phase,
        public string $subjectKey,
        public string $versionType,
        public string $versionId,
        public string $label,
        public array $snapshot,
    ) {}

    /**
     * Map one `KvSharePayloadService` item. The version is the item's own
     * `id` — the board tip, the newest motion render, the resize row — so it
     * always matches what the page renders and what pins anchor to.
     *
     * @param  array<string, mixed>  $item
     */
    public static function fromPayload(string $phase, string $subjectKey, array $item): self
    {
        $id = (string) $item['id'];

        return match ($item['kind'] ?? null) {
            'resize' => new self(
                'resize',
                $subjectKey,
                Approval::VERSION_KV_RESIZE_EXPORT,
                $id,
                self::clip(sprintf('Resize · %s · %d×%d', (string) ($item['platform_label'] ?? ''), (int) ($item['width'] ?? 0), (int) ($item['height'] ?? 0))),
                $item,
            ),
            'motion' => new self(
                'motion',
                $subjectKey,
                Approval::VERSION_KV_MOTION_EXPORT,
                $id,
                self::clip(sprintf('Motion · %s · %d×%d', (string) ($item['ratio'] ?? ''), (int) ($item['width'] ?? 0), (int) ($item['height'] ?? 0))),
                $item,
            ),
            default => new self(
                $phase,
                $subjectKey,
                Approval::VERSION_KV_GENERATION,
                $id,
                self::clip(ucfirst($phase).' · '.(trim((string) ($item['name'] ?? '')) !== '' ? (string) $item['name'] : 'Untitled board')),
                $item,
            ),
        };
    }

    public function fingerprint(): string
    {
        return self::fingerprintOf($this->snapshot);
    }

    public function thumbnailUrl(): ?string
    {
        return self::thumbnailOf($this->snapshot);
    }

    /** @return array{subject_key: string, phase: string, label: string, snapshot: array<string, mixed>, subject_version_type: string, subject_version_id: string} */
    public function toApprovalAttributes(): array
    {
        return [
            'subject_key' => $this->subjectKey,
            'phase' => $this->phase,
            'label' => $this->label,
            'snapshot' => $this->snapshot,
            'subject_version_type' => $this->versionType,
            'subject_version_id' => $this->versionId,
        ];
    }

    /**
     * Hash of the artwork fields of a snapshot, canonicalised so a jsonb
     * round-trip (reordered object keys, `1.0` read back as `1`) hashes the
     * same as the live payload. '' for a null snapshot.
     *
     * @param  array<string, mixed>|null  $snapshot
     */
    public static function fingerprintOf(?array $snapshot): string
    {
        if ($snapshot === null) {
            return '';
        }

        $keys = self::ARTWORK_KEYS[(string) ($snapshot['kind'] ?? 'board')] ?? self::ARTWORK_KEYS['board'];
        $artwork = [];
        foreach ($keys as $key) {
            $artwork[$key] = $snapshot[$key] ?? null;
        }

        return hash('sha256', (string) json_encode(self::canonical($artwork), JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE));
    }

    /**
     * The still to show for a snapshot: its `image_url`. Null for motion (a
     * clip has no still) and for a layer-composed resize tile (no image by
     * design).
     *
     * @param  array<string, mixed>|null  $snapshot
     */
    public static function thumbnailOf(?array $snapshot): ?string
    {
        if (! is_array($snapshot) || ($snapshot['kind'] ?? null) === 'motion') {
            return null;
        }

        $url = $snapshot['image_url'] ?? null;

        return is_string($url) && $url !== '' ? $url : null;
    }

    /** ≤ 160 chars (`approvals.label`); board names are unbounded canvas text. */
    public static function clip(string $label): string
    {
        return Str::limit($label, self::LABEL_MAX - 3);
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

`app/Services/Approval/KvArtboardResolver.php`:

```php
<?php

declare(strict_types=1);

namespace App\Services\Approval;

// craftsman-ignore: PHP002 — resolved from the container and swapped in tests.

use App\Models\KvMotionExport;
use App\Models\StudioFile;
use App\Services\Studio\KvSharePayloadService;

/**
 * Every artboard a client would see on this file right now, as
 * {@see KvArtboard} values (KV approval requests spec §4.2): the ready
 * items of the asked phases exactly as the guest page renders them
 * (`KvSharePayloadService::itemsFor`), each given its stable key.
 */
class KvArtboardResolver
{
    public function __construct(private readonly KvSharePayloadService $payload) {}

    /**
     * Canonical phase order, payload order within a phase. One entry per key:
     * a board chain spanning sketch and craft marks resolves to the same tip
     * twice, and is listed under the first phase only (ruling R15).
     *
     * @param  array<int, string>  $phases
     * @return list<KvArtboard>
     */
    public function artboards(StudioFile $file, array $phases): array
    {
        $byPhase = $this->payload->itemsFor($file, $phases);

        $motionIds = array_map(static fn (array $item): string => (string) $item['id'], $byPhase['motion'] ?? []);
        $projects = $motionIds === []
            ? []
            : KvMotionExport::query()->whereIn('id', $motionIds)->pluck('kv_motion_project_id', 'id')->all();

        $artboards = [];
        $seen = [];
        foreach ($byPhase as $phase => $items) {
            foreach ($items as $item) {
                $id = (string) $item['id'];
                $key = match ($item['kind'] ?? null) {
                    'resize' => KvArtboardKey::resize($id),
                    'motion' => isset($projects[$id]) ? KvArtboardKey::motion((string) $projects[$id], (string) $item['ratio']) : null,
                    default => KvArtboardKey::board($file, $id),
                };
                if ($key === null || isset($seen[$key])) {
                    continue;
                }
                $seen[$key] = true;
                $artboards[] = KvArtboard::fromPayload((string) $phase, $key, $item);
            }
        }

        return $artboards;
    }
}
```

In `app/Services/Studio/KvSharePayloadService.php`: in `itemsFor()`'s docblock replace "and an approval round's freeze (ApprovalService::request(), client lane multi-item spec §5.1)." with "and a KV approval request's artboards ({@see \App\Services\Approval\KvArtboardResolver})."; in `resolvePhase()`'s docblock replace "Public for the legacy one-item approval path (`kv_ready_item_id`), which resolves a single marked id rather than a whole phase." with "Public so a single phase can be resolved on its own (tests, KvArtboardResolver callers)."

- [ ] **Step 5: Run — expect PASS**

Same command as Step 3. Expected: 8 passed. If *"a motion export whose project left the file…"* errors on the delete (an FK or a non-soft-deleting project model), read `KvReadyToShareService::rawMarkedMotionIds()` and `KvMotionProject`, and change the test's way of removing the project to whatever the app does when a motion project is deleted — never the resolver.

- [ ] **Step 6: Mutation check**

1. `KvArtboardKey::board`: use `$generationId` instead of `chainForGeneration(...)[0]` → *"a board keeps its key across Craft iterations…"* must FAIL. Restore.
2. `KvArtboardResolver::artboards`: delete `|| isset($seen[$key])` → *"an artboard reachable from two phases is listed once…"* must FAIL on the `phase` assertion (the fixture keys by `subject_key`, so the later craft duplicate overwrites the sketch entry). Restore.
3. `KvArtboard::canonical`: delete the `ksort($value);` line → *"the fingerprint survives a jsonb round-trip…"* must FAIL. Restore.
4. `KvArtboard::ARTWORK_KEYS['board']`: add `'name'` → *"the fingerprint ignores the name…"* must FAIL. Restore.

Re-run Step 3's command: 8 passed.

- [ ] **Step 7: Lint + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && F="app/Services/Approval/KvArtboard.php app/Services/Approval/KvArtboardKey.php app/Services/Approval/KvArtboardResolver.php app/Services/Studio/KvSharePayloadService.php tests/Support/ClientLaneFixtures.php tests/Feature/Approval/KvArtboardKeyTest.php"; for f in ${=F}; do php -l "$f"; done && vendor/bin/pint ${=F} && vendor/bin/pint --test ${=F} && /usr/bin/git add ${=F} && /usr/bin/git commit -m "feat(api): KV artboard keys, versions and artwork fingerprints for approval requests"
```

---

### Task 5: Request roll-up — a pure unit with a table test

**Files:**
- Create: `app/Services/Approval/ApprovalRequestRollup.php`
- Test: `tests/Unit/Approval/ApprovalRequestRollupTest.php`

**Interfaces:**
- Consumes: `Approval::STATUS_*`.
- Produces: `ApprovalRequestRollup::status(array $approvalStatuses): string` (spec §4.3 rows 1–4; `not_relevant` approvals — replaced or withdrawn — are ignored).

- [ ] **Step 1: Write the failing test**

Create `tests/Unit/Approval/ApprovalRequestRollupTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Services\Approval\ApprovalRequestRollup;

// Pure — no container, no DB (like tests/Unit/CampaignPlan/PlanApprovalTest.php).
// Every row of spec §4.3 "Request roll-up".
test('the request status rolls up from its approvals', function (array $statuses, string $expected) {
    expect(ApprovalRequestRollup::status($statuses))->toBe($expected);
})->with([
    'all pending' => [['pending', 'pending'], 'pending'],
    'one still pending among decided' => [['approved', 'pending', 'changes_required'], 'pending'],
    'all approved' => [['approved', 'approved'], 'approved'],
    'approved with changes beats approved' => [['approved', 'approved_with_changes'], 'approved_with_changes'],
    'changes required beats approved with changes' => [['approved_with_changes', 'changes_required', 'approved'], 'changes_required'],
    'a replaced approval is ignored' => [['approved', 'not_relevant'], 'approved'],
    'a replaced approval does not hide a pending one' => [['not_relevant', 'pending'], 'pending'],
    'every approval replaced or withdrawn' => [['not_relevant', 'not_relevant'], 'not_relevant'],
    'no approvals at all' => [[], 'not_relevant'],
]);
```

- [ ] **Step 2: Run — expect FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Unit/Approval/ApprovalRequestRollupTest.php --compact
```
Expected: FAIL — `Class "App\Services\Approval\ApprovalRequestRollup" not found`.

- [ ] **Step 3: Implement**

`app/Services/Approval/ApprovalRequestRollup.php`:

```php
<?php

declare(strict_types=1);

namespace App\Services\Approval;

use App\Models\Approval;

/**
 * A KV approval request's status from its approvals' statuses (KV approval
 * requests spec §4.3 "Request roll-up"):
 *
 *   1. ignore `not_relevant` approvals (replaced by a newer request, or
 *      withdrawn with the request);
 *   2. any `pending` left → `pending`;
 *   3. else `changes_required` if any, else `approved_with_changes` if any,
 *      else `approved`;
 *   4. nothing left → `not_relevant`.
 *
 * Pure: callers recalculate it in the same transaction as the decision,
 * replacement or withdraw that changed an approval.
 */
final class ApprovalRequestRollup
{
    /** @param  array<int, string>  $approvalStatuses */
    public static function status(array $approvalStatuses): string
    {
        $live = array_values(array_filter(
            $approvalStatuses,
            static fn (string $status): bool => $status !== Approval::STATUS_NOT_RELEVANT,
        ));

        if ($live === []) {
            return Approval::STATUS_NOT_RELEVANT;
        }
        if (in_array(Approval::STATUS_PENDING, $live, true)) {
            return Approval::STATUS_PENDING;
        }
        if (in_array(Approval::STATUS_CHANGES_REQUIRED, $live, true)) {
            return Approval::STATUS_CHANGES_REQUIRED;
        }
        if (in_array(Approval::STATUS_APPROVED_WITH_CHANGES, $live, true)) {
            return Approval::STATUS_APPROVED_WITH_CHANGES;
        }

        return Approval::STATUS_APPROVED;
    }
}
```

- [ ] **Step 4: Run — expect PASS**

Same command as Step 2. Expected: 9 passed.

- [ ] **Step 5: Mutation check**

1. Swap the `CHANGES_REQUIRED` and `APPROVED_WITH_CHANGES` checks → *"changes required beats approved with changes"* must FAIL. Restore.
2. Delete the `array_filter` (use `$approvalStatuses` as `$live`) → *"a replaced approval is ignored"* and *"every approval replaced or withdrawn"* must FAIL. Restore.

Re-run: 9 passed.

- [ ] **Step 6: Lint + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && F="app/Services/Approval/ApprovalRequestRollup.php tests/Unit/Approval/ApprovalRequestRollupTest.php"; for f in ${=F}; do php -l "$f"; done && vendor/bin/pint ${=F} && vendor/bin/pint --test ${=F} && /usr/bin/git add ${=F} && /usr/bin/git commit -m "feat(api): approval request roll-up status"
```

---
### Task 6: Preview — which artboards a request would contain

**Files:**
- Create: `app/Services/Approval/ApprovalRequestPreview.php`
- Create: `app/Services/Approval/ApprovalRequestPreviewService.php`
- Test: `tests/Feature/Approval/ApprovalRequestPreviewTest.php`

**Interfaces:**
- Consumes: `KvArtboardResolver::artboards()`, `KvArtboard::fingerprintOf()`, `Approval::approvalRequest()`, fixtures `kvRequest()`, `kvApproval()`, `artboards()`.
- Produces:
  - `ApprovalRequestPreview` (readonly) — `list<array{phase: string, count: int}> $phases`, `list<array{artboard: KvArtboard, previous: Approval|null}> $eligible` (`previous` = the pending approval this one would replace, else null), `list<KvArtboard> $alreadyApproved`, `list<array{artboard: KvArtboard, previous: Approval}> $waiting`; `total(): int`; `artboards(): list<KvArtboard>`; `toArray(): array` (contract shape).
  - `ApprovalRequestPreviewService::preview(StudioFile $file, ?array $phases = null): ApprovalRequestPreview`; `::latestByKey(StudioFile $file, array $keys): array<string, Approval>` (newest round per key, `approvalRequest:id,number` loaded); `static classify(KvArtboard $artboard, ?Approval $latest): string` returning `ELIGIBLE` | `APPROVED` | `WAITING` constants.

- [ ] **Step 1: Write the failing test**

Create `tests/Feature/Approval/ApprovalRequestPreviewTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Models\Approval;
use App\Services\Approval\ApprovalRequestPreviewService;
use Tests\Support\ClientLaneFixtures;

beforeEach(function () {
    $this->kv = ClientLaneFixtures::kvFile();
    $this->file = $this->kv['file'];
    $this->user = $this->kv['user'];
    $this->board = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Hero board');
    $this->tile = ClientLaneFixtures::resizeTile($this->file, $this->user, $this->board);
    $this->clip = ClientLaneFixtures::motionExport($this->file, $this->user, $this->board);
    ClientLaneFixtures::markReady('kv_generation', $this->board->id, $this->user);
    ClientLaneFixtures::markReady('kv_resize_export', $this->tile->id, $this->user);
    ClientLaneFixtures::markReady('kv_motion_export', $this->clip->id, $this->user);

    $this->keys = [
        'board' => "board:{$this->board->id}",
        'tile' => "resize:{$this->tile->id}",
        'clip' => "motion:{$this->clip->kv_motion_project_id}:instagram-story",
    ];
    $this->request1 = ClientLaneFixtures::kvRequest($this->file, $this->user, 1);
    $this->preview = fn (?array $phases = null): array => app(ApprovalRequestPreviewService::class)->preview($this->file->fresh(), $phases)->toArray();
});

test('every marked artboard that renders is a candidate, grouped by phase', function () {
    $preview = ($this->preview)();

    expect($preview['phases'])->toBe([['phase' => 'craft', 'count' => 1], ['phase' => 'resize', 'count' => 1], ['phase' => 'motion', 'count' => 1]])
        ->and(array_column($preview['items'], 'subject_key'))->toBe(array_values($this->keys))
        ->and(array_keys($preview['items'][0]))->toBe(['subject_key', 'phase', 'label', 'version_id', 'thumbnail_url', 'replaces'])
        ->and($preview['items'][0])->toMatchArray(['phase' => 'craft', 'label' => 'Craft · Hero board', 'version_id' => $this->board->id, 'thumbnail_url' => 'https://cdn.test/board-1.png', 'replaces' => null])
        ->and($preview['items'][2]['thumbnail_url'])->toBeNull()
        ->and($preview['already_approved'])->toBe([])
        ->and($preview['waiting'])->toBe([])
        ->and($preview['total'])->toBe(3);
});

test('an artboard approved on this exact version is already approved, not offered again', function () {
    $artboards = ClientLaneFixtures::artboards($this->file);
    ClientLaneFixtures::kvApproval($this->request1, $artboards[$this->keys['board']], ['status' => Approval::STATUS_APPROVED]);
    ClientLaneFixtures::kvApproval($this->request1, $artboards[$this->keys['tile']], ['status' => Approval::STATUS_APPROVED_WITH_CHANGES]);

    $preview = ($this->preview)();

    expect(array_column($preview['items'], 'subject_key'))->toBe([$this->keys['clip']])
        ->and(array_column($preview['already_approved'], 'subject_key'))->toBe([$this->keys['board'], $this->keys['tile']])
        ->and(array_keys($preview['already_approved'][0]))->toBe(['subject_key', 'phase', 'label', 'version_id'])
        ->and($preview['phases'])->toBe([['phase' => 'motion', 'count' => 1]])
        ->and($preview['total'])->toBe(1);
});

// Review Focus 1: a tile's version id is its row id, which regeneration keeps.
test('a changed version re-enters: a Craft iteration and a regenerated resize tile', function () {
    $artboards = ClientLaneFixtures::artboards($this->file);
    ClientLaneFixtures::kvApproval($this->request1, $artboards[$this->keys['board']], ['status' => Approval::STATUS_APPROVED]);
    ClientLaneFixtures::kvApproval($this->request1, $artboards[$this->keys['tile']], ['status' => Approval::STATUS_APPROVED]);

    $tip = ClientLaneFixtures::iterate($this->file, $this->user, $this->board, 'https://cdn.test/board-2.png');
    $this->tile->forceFill(['image_url' => 'https://cdn.test/tile-2.png'])->save();

    $preview = ($this->preview)();
    $items = collect($preview['items'])->keyBy('subject_key');

    expect($items->keys()->all())->toBe(array_values($this->keys))
        ->and($items[$this->keys['board']]['version_id'])->toBe($tip->id)
        ->and($items[$this->keys['tile']]['version_id'])->toBe($this->tile->id)
        ->and($items[$this->keys['tile']]['replaces'])->toBeNull()
        ->and($preview['already_approved'])->toBe([]);
});

test('an artboard waiting on the same version is listed as waiting; a changed one replaces it', function () {
    $artboards = ClientLaneFixtures::artboards($this->file);
    ClientLaneFixtures::kvApproval($this->request1, $artboards[$this->keys['board']]);
    ClientLaneFixtures::kvApproval($this->request1, $artboards[$this->keys['tile']]);
    $this->tile->forceFill(['image_url' => 'https://cdn.test/tile-2.png'])->save();

    $preview = ($this->preview)();
    $items = collect($preview['items'])->keyBy('subject_key');

    expect($preview['waiting'])->toBe([[
        'subject_key' => $this->keys['board'],
        'phase' => 'craft',
        'label' => 'Craft · Hero board',
        'version_id' => $this->board->id,
        'request_number' => 1,
    ]])
        ->and($items->keys()->all())->toBe([$this->keys['tile'], $this->keys['clip']])
        ->and($items[$this->keys['tile']]['replaces'])->toBe(['request_number' => 1, 'round' => 1])
        ->and($items[$this->keys['clip']]['replaces'])->toBeNull();
});

test('changes asked on the same version are offered again', function () {
    $artboards = ClientLaneFixtures::artboards($this->file);
    ClientLaneFixtures::kvApproval($this->request1, $artboards[$this->keys['board']], ['status' => Approval::STATUS_CHANGES_REQUIRED]);

    $items = collect(($this->preview)()['items'])->keyBy('subject_key');

    expect($items->has($this->keys['board']))->toBeTrue()
        ->and($items[$this->keys['board']]['replaces'])->toBeNull();
});

test('the latest round decides: an old approval on an artboard does not hide a newer pending one', function () {
    $artboards = ClientLaneFixtures::artboards($this->file);
    ClientLaneFixtures::kvApproval($this->request1, $artboards[$this->keys['board']], ['status' => Approval::STATUS_APPROVED]);
    $request2 = ClientLaneFixtures::kvRequest($this->file, $this->user, 2);
    ClientLaneFixtures::kvApproval($request2, $artboards[$this->keys['board']], ['round' => 2]);

    $preview = ($this->preview)();

    expect(array_column($preview['waiting'], 'request_number'))->toBe([2])
        ->and($preview['already_approved'])->toBe([]);
});

test('kv_phases narrows the lists while every phase keeps its count', function () {
    $preview = ($this->preview)(['resize']);

    expect(array_column($preview['items'], 'subject_key'))->toBe([$this->keys['tile']])
        ->and($preview['total'])->toBe(1)
        ->and(array_column($preview['phases'], 'phase'))->toBe(['craft', 'resize', 'motion']);
});

test('a file with nothing marked has nothing to send', function () {
    $other = ClientLaneFixtures::kvFile();
    ClientLaneFixtures::board($other['file'], $other['user']);

    $preview = app(ApprovalRequestPreviewService::class)->preview($other['file']->fresh())->toArray();

    expect($preview)->toBe(['phases' => [], 'items' => [], 'already_approved' => [], 'waiting' => [], 'total' => 0]);
});
```

- [ ] **Step 2: Run — expect FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && ls bootstrap/cache/config.php 2>/dev/null; DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/ApprovalRequestPreviewTest.php --compact
```
Expected: FAIL — `Class "App\Services\Approval\ApprovalRequestPreviewService" not found`.

- [ ] **Step 3: Implement**

`app/Services/Approval/ApprovalRequestPreview.php`:

```php
<?php

declare(strict_types=1);

namespace App\Services\Approval;

use App\Models\Approval;

/**
 * What a KV approval request would contain right now (KV approval requests
 * spec §4.5 preview, rulings R2/R3). `eligible` is exactly what
 * `ApprovalRequestService::create()` freezes.
 */
final readonly class ApprovalRequestPreview
{
    /**
     * @param  list<array{phase: string, count: int}>  $phases  per-phase eligible counts, ignoring the phase filter
     * @param  list<array{artboard: KvArtboard, previous: Approval|null}>  $eligible  `previous` = the pending approval it would replace
     * @param  list<KvArtboard>  $alreadyApproved
     * @param  list<array{artboard: KvArtboard, previous: Approval}>  $waiting
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

    /** @return list<KvArtboard> */
    public function artboards(): array
    {
        return array_map(static fn (array $entry): KvArtboard => $entry['artboard'], $this->eligible);
    }

    /** @return array{phases: list<array{phase: string, count: int}>, items: list<array<string, mixed>>, already_approved: list<array<string, string>>, waiting: list<array<string, mixed>>, total: int} */
    public function toArray(): array
    {
        return [
            'phases' => $this->phases,
            'items' => array_map(static fn (array $entry): array => [
                'subject_key' => $entry['artboard']->subjectKey,
                'phase' => $entry['artboard']->phase,
                'label' => $entry['artboard']->label,
                'version_id' => $entry['artboard']->versionId,
                'thumbnail_url' => $entry['artboard']->thumbnailUrl(),
                'replaces' => $entry['previous'] !== null ? [
                    'request_number' => $entry['previous']->approvalRequest?->number,
                    'round' => $entry['previous']->round,
                ] : null,
            ], $this->eligible),
            'already_approved' => array_map(static fn (KvArtboard $artboard): array => [
                'subject_key' => $artboard->subjectKey,
                'phase' => $artboard->phase,
                'label' => $artboard->label,
                'version_id' => $artboard->versionId,
            ], $this->alreadyApproved),
            'waiting' => array_map(static fn (array $entry): array => [
                'subject_key' => $entry['artboard']->subjectKey,
                'phase' => $entry['artboard']->phase,
                'label' => $entry['artboard']->label,
                'version_id' => $entry['artboard']->versionId,
                'request_number' => $entry['previous']->approvalRequest?->number,
            ], $this->waiting),
            'total' => $this->total(),
        ];
    }
}
```

`app/Services/Approval/ApprovalRequestPreviewService.php`:

```php
<?php

declare(strict_types=1);

namespace App\Services\Approval;

// craftsman-ignore: PHP002 — resolved from the container and swapped in tests.

use App\Models\Approval;
use App\Models\StudioFile;
use App\Services\Studio\KvSharePayloadService;

/**
 * KV approval request eligibility (spec §4.5, rulings R1–R3): every
 * artboard marked ready that renders, compared with its latest approval.
 *
 *   none / other version / same version not approved and not pending → eligible
 *   same version approved or approved_with_changes                   → already approved
 *   same version still pending                                       → waiting
 *
 * "Same version" = same `subject_version_id` AND same artwork fingerprint
 * (R1): a resize tile keeps its row id across regenerations.
 */
class ApprovalRequestPreviewService
{
    public const ELIGIBLE = 'eligible';

    public const APPROVED = 'approved';

    public const WAITING = 'waiting';

    public function __construct(private readonly KvArtboardResolver $artboards) {}

    /** @param  list<string>|null  $phases  null or [] = every phase */
    public function preview(StudioFile $file, ?array $phases = null): ApprovalRequestPreview
    {
        $artboards = $this->artboards->artboards($file, KvSharePayloadService::PHASES);
        $latest = $this->latestByKey($file, array_map(static fn (KvArtboard $a): string => $a->subjectKey, $artboards));
        $selected = $phases === null || $phases === [] ? KvSharePayloadService::PHASES : $phases;

        $counts = [];
        $eligible = [];
        $approved = [];
        $waiting = [];
        foreach ($artboards as $artboard) {
            $previous = $latest[$artboard->subjectKey] ?? null;
            $verdict = self::classify($artboard, $previous);

            if ($verdict === self::ELIGIBLE) {
                $counts[$artboard->phase] = ($counts[$artboard->phase] ?? 0) + 1;
            }
            if (! in_array($artboard->phase, $selected, true)) {
                continue;
            }

            if ($verdict === self::ELIGIBLE) {
                $eligible[] = ['artboard' => $artboard, 'previous' => $previous?->isPending() ? $previous : null];
            } elseif ($verdict === self::APPROVED) {
                $approved[] = $artboard;
            } else {
                $waiting[] = ['artboard' => $artboard, 'previous' => $previous];
            }
        }

        $phaseRows = [];
        foreach (KvSharePayloadService::PHASES as $phase) {
            if (($counts[$phase] ?? 0) > 0) {
                $phaseRows[] = ['phase' => $phase, 'count' => $counts[$phase]];
            }
        }

        return new ApprovalRequestPreview($phaseRows, $eligible, $approved, $waiting);
    }

    /**
     * The newest-round approval of each artboard key on the file.
     *
     * @param  array<int, string>  $keys
     * @return array<string, Approval>
     */
    public function latestByKey(StudioFile $file, array $keys): array
    {
        if ($keys === []) {
            return [];
        }

        return Approval::query()
            ->forSubject('kv_file', (string) $file->id)
            ->whereIn('subject_key', $keys)
            ->with('approvalRequest:id,number')
            ->orderBy('round')
            ->get()
            ->keyBy('subject_key')
            ->all();
    }

    public static function classify(KvArtboard $artboard, ?Approval $latest): string
    {
        if ($latest === null) {
            return self::ELIGIBLE;
        }

        $sameVersion = (string) $latest->subject_version_id === $artboard->versionId
            && KvArtboard::fingerprintOf($latest->snapshot) === $artboard->fingerprint();
        if (! $sameVersion) {
            return self::ELIGIBLE;
        }

        return match ($latest->status) {
            Approval::STATUS_APPROVED, Approval::STATUS_APPROVED_WITH_CHANGES => self::APPROVED,
            Approval::STATUS_PENDING => self::WAITING,
            default => self::ELIGIBLE,
        };
    }
}
```

- [ ] **Step 4: Run — expect PASS**

Same command as Step 2. Expected: 8 passed.

- [ ] **Step 5: Mutation check**

1. `classify`: drop the fingerprint half of `$sameVersion` → *"a changed version re-enters…"* must FAIL (the regenerated tile lands in `already_approved`). Restore.
2. `classify`: map `STATUS_PENDING` to `self::ELIGIBLE` → *"an artboard waiting on the same version…"* must FAIL. Restore.
3. `latestByKey`: `orderBy('round')` → `orderByDesc('round')` → *"the latest round decides…"* must FAIL. Restore.
4. `preview`: move the `$counts` increment below the phase-filter `continue` → *"kv_phases narrows the lists…"* must FAIL. Restore.

Re-run: 8 passed.

- [ ] **Step 6: Lint + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && F="app/Services/Approval/ApprovalRequestPreview.php app/Services/Approval/ApprovalRequestPreviewService.php tests/Feature/Approval/ApprovalRequestPreviewTest.php"; for f in ${=F}; do php -l "$f"; done && vendor/bin/pint ${=F} && vendor/bin/pint --test ${=F} && /usr/bin/git add ${=F} && /usr/bin/git commit -m "feat(api): approval request preview — eligible, already approved and waiting artboards"
```

---

### Task 7: `purpose = approval` links — minted outside the cap, never a view link

**Files:**
- Modify: `app/Models/ShareLink.php` (`scopeCountingAgainstLimit`, new `scopeForSharing`)
- Modify: `app/Services/Sharing/ShareLinkService.php` (`create()` sets purpose; new `createApprovalLink()`)
- Modify: `app/Http/Controllers/Api/Studio/StudioFileShareLinkController.php` (`index()`, `findLinkForFile()`)
- Modify: `app/Models/StudioFile.php` (`legacyShareLink()`)
- Modify: `app/Http/Controllers/Api/Studio/StudioFileController.php` (`revokeActiveLinks()` + its two callers)
- Test: `tests/Feature/Approval/ShareLinkPurposeTest.php`

**Interfaces:**
- Consumes: Task 2 `ShareLink::PURPOSE_*`.
- Produces: `ShareLink::scopeForSharing(Builder): Builder`; `ShareLinkService::createApprovalLink(Model $shareable, User $creator, array $phases, ?string $workspaceId = null): ShareLink` (role `comment`, purpose `approval`, no expiry, label `Approval request`, no cap).

- [ ] **Step 1: Write the failing test**

Create `tests/Feature/Approval/ShareLinkPurposeTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Models\ShareLink;
use App\Services\Sharing\ShareLinkService;
use Illuminate\Validation\ValidationException;
use Tests\Support\ClientLaneFixtures;

beforeEach(function () {
    $this->kv = ClientLaneFixtures::kvFile();
    $this->file = $this->kv['file'];
    $this->user = $this->kv['user'];
    ClientLaneFixtures::owner($this->user, $this->kv['workspace']);
    $this->actingAs($this->user, 'api');
    $this->links = app(ShareLinkService::class);
});

test('approval links never count against the three view links', function () {
    foreach (range(1, 3) as $_) {
        $this->links->createApprovalLink($this->file, $this->user, ['craft']);
    }
    foreach (range(1, 3) as $_) {
        $this->links->create($this->file, $this->user, ['craft']);
    }

    expect(fn () => $this->links->create($this->file, $this->user, ['craft']))->toThrow(ValidationException::class)
        ->and(fn () => $this->links->createApprovalLink($this->file, $this->user, ['craft']))->not->toThrow(ValidationException::class);
});

test('an approval link is a never-expiring comment link with its own token', function () {
    $first = $this->links->createApprovalLink($this->file, $this->user, ['craft', 'resize'])->fresh();
    $second = $this->links->createApprovalLink($this->file, $this->user, ['craft'])->fresh();

    expect($first->purpose)->toBe(ShareLink::PURPOSE_APPROVAL)
        ->and($first->role)->toBe(ShareLink::ROLE_COMMENT)
        ->and($first->expires_at)->toBeNull()
        ->and($first->phaseList())->toBe(['craft', 'resize'])
        ->and($first->token)->not->toBe($second->token)
        ->and($this->links->create($this->file, $this->user, ['craft'])->fresh()->purpose)->toBe(ShareLink::PURPOSE_SHARE);
});

test('the share panel lists only view links, and cannot edit or revoke an approval link', function () {
    $view = $this->links->create($this->file, $this->user, ['craft']);
    $approval = $this->links->createApprovalLink($this->file, $this->user, ['craft']);
    $base = "/api/v1/studio/files/{$this->file->id}/share-links";

    expect($this->getJson($base)->assertOk()->json('data.*.id'))->toBe([$view->id]);

    $this->patchJson("{$base}/{$approval->id}", ['label' => 'Hijacked'])->assertNotFound();
    $this->deleteJson("{$base}/{$approval->id}")->assertNotFound();
    expect($approval->fresh()->revoked_at)->toBeNull();
});

test('the legacy share token never points at an approval link', function () {
    $view = $this->links->create($this->file, $this->user, ['craft']);
    $this->travel(1)->minutes();
    $this->links->createApprovalLink($this->file, $this->user, ['craft']);

    expect($this->file->fresh()->legacyShareLink()?->id)->toBe($view->id);
});

test('share_token enable replaces view links only; disable revokes approval links too', function () {
    $approval = $this->links->createApprovalLink($this->file, $this->user, ['craft']);

    $this->patchJson("/api/v1/studio/files/{$this->file->id}", ['share_token' => 'enable'])->assertOk();
    expect($approval->fresh()->revoked_at)->toBeNull();

    $this->patchJson("/api/v1/studio/files/{$this->file->id}", ['share_token' => 'disable'])->assertOk();
    expect($approval->fresh()->revoked_at)->not->toBeNull();
});
```

- [ ] **Step 2: Run — expect FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && ls bootstrap/cache/config.php 2>/dev/null; DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/ShareLinkPurposeTest.php --compact
```
Expected: FAIL — `Call to undefined method …ShareLinkService::createApprovalLink()`.

- [ ] **Step 3: Implement**

`app/Models/ShareLink.php` — replace `scopeCountingAgainstLimit` (docblock included) with:

```php
    /**
     * Links that count against the per-entity limit: active VIEW links.
     * Expired-but-not-revoked links are EXCLUDED: holding a slot hostage to a
     * dead link would force the user to tidy up before they can share again,
     * which is friction for no safety gain. A KV approval request's own link
     * is not a view link and never takes a slot (KV approval requests §4.4).
     */
    public function scopeCountingAgainstLimit(Builder $query): Builder
    {
        return $query->active()->forSharing();
    }

    /** View links (and P0a comment links) — never a request's own `purpose = approval` link. */
    public function scopeForSharing(Builder $query): Builder
    {
        return $query->where('purpose', self::PURPOSE_SHARE);
    }
```

`app/Services/Sharing/ShareLinkService.php` — in `create()` add `'purpose' => ShareLink::PURPOSE_SHARE,` after `'role' => $role,`; add after `create()`:

```php
    /**
     * The token a KV approval request mints for itself (KV approval requests
     * spec §4.4): `role = comment`, `purpose = approval`, never expires, a
     * new token per request, and — not being a view link — never counted
     * against MAX_ACTIVE_LINKS.
     *
     * @param  array<int, string>  $phases  the request's phases
     */
    public function createApprovalLink(Model $shareable, User $creator, array $phases, ?string $workspaceId = null): ShareLink
    {
        return ShareLink::create([
            'shareable_type' => $shareable->getMorphClass(),
            'shareable_id' => $shareable->getKey(),
            'workspace_id' => $workspaceId ?? $shareable->getAttribute('workspace_id'),
            'token' => self::mintToken(),
            'label' => 'Approval request',
            'phases' => array_values($phases),
            'role' => ShareLink::ROLE_COMMENT,
            'purpose' => ShareLink::PURPOSE_APPROVAL,
            'expires_at' => null,
            'created_by' => $creator->id,
        ]);
    }
```

`app/Http/Controllers/Api/Studio/StudioFileShareLinkController.php` — in `index()` add `->forSharing()` after `->whereNull('revoked_at')` and extend its comment with "A KV approval request's own link is not a view link and is never listed (KV approval requests §4.4)."; in `findLinkForFile()` add `->forSharing()` after `->whereNull('revoked_at')` and add to its docblock "Approval-request links are not addressable here either — the request owns them."

`app/Models/StudioFile.php` — in `legacyShareLink()` change the filter to

```php
            ->filter(fn (ShareLink $link) => $link->isActive()
                && ($link->purpose ?? ShareLink::PURPOSE_SHARE) === ShareLink::PURPOSE_SHARE)
```
and add to its docblock: "A KV approval request's own link never becomes the legacy token."

`app/Http/Controllers/Api/Studio/StudioFileController.php` — add `use App\Models\ShareLink;`; replace `revokeActiveLinks()` with

```php
    /**
     * `share_token: enable` replaces the VIEW links only — re-enabling the
     * legacy token must not withdraw an open KV approval request.
     * `share_token: disable` means sharing off: every link, approval links
     * included (their pending requests are withdrawn by the
     * ShareLinksRevoked listener).
     */
    private function revokeActiveLinks(StudioFile $file, bool $includeApprovalLinks): void
    {
        $file->shareLinks()
            ->whereNull('revoked_at')
            ->when(! $includeApprovalLinks, fn ($query) => $query->where('purpose', ShareLink::PURPOSE_SHARE))
            ->get()
            ->each(fn ($link) => $this->shareLinks->revoke($link));

        $file->load('shareLinks');
    }
```
and change its callers: under `share_token === 'disable'` → `$this->revokeActiveLinks($file, includeApprovalLinks: true);`, under `share_token === 'enable'` → `$this->revokeActiveLinks($file, includeApprovalLinks: false);`.

- [ ] **Step 4: Run — expect PASS**

Same command as Step 2. Expected: 5 passed. Then regression:

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Studio/KvShareLinkTest.php --compact
```
Expected: same result as before this task (76/76 on 2026-09-30). A new failure is yours.

- [ ] **Step 5: Mutation check**

1. `scopeCountingAgainstLimit`: drop `->forSharing()` → *"approval links never count…"* must FAIL. Restore.
2. `findLinkForFile`: drop `->forSharing()` → *"the share panel lists only view links…"* must FAIL (DELETE 204). Restore.
3. `StudioFileController` enable caller: pass `true` → *"share_token enable replaces view links only…"* must FAIL. Restore.

Re-run Step 2's command: 5 passed.

- [ ] **Step 6: Lint + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && F="app/Models/ShareLink.php app/Services/Sharing/ShareLinkService.php app/Http/Controllers/Api/Studio/StudioFileShareLinkController.php app/Models/StudioFile.php app/Http/Controllers/Api/Studio/StudioFileController.php tests/Feature/Approval/ShareLinkPurposeTest.php"; for f in ${=F}; do php -l "$f"; done && vendor/bin/pint ${=F} && vendor/bin/pint --test ${=F} && /usr/bin/git add ${=F} && /usr/bin/git commit -m "feat(api): approval-purpose share links outside the view-link cap and panel"
```

---
### Task 8: Create a request — freeze, supersede the same artboard only, mint the link, lanes, mail

**Files:**
- Create: `app/Services/Approval/ApprovalRequestService.php`
- Modify: `app/Models/Approval.php` (`successorsOf()`)
- Modify: `app/Models/ApprovalRequest.php` (`counts()`)
- Modify: `app/Services/Approval/ApprovalNotifier.php` (`audience()` and `mailApprovers()` signatures, `requestSent()`, `requestLabel()`)
- Modify: `app/Exceptions/Approval/NothingReadyException.php`, `TooManyItemsException.php` (docblocks)
- Modify: `tests/Support/ClientLaneFixtures.php` (`sendRequest()`)
- Test: `tests/Feature/Approval/ApprovalRequestCreateTest.php`

**Interfaces:**
- Consumes: `ApprovalRequestPreviewService::preview()->artboards()`, `::latestByKey()`, `ShareLinkService::createApprovalLink()`, `ClientLaneService::ensureClientUser()/mintLaneLink()/personalUrl()`, `ApprovalRequestRollup::status()`, `KvArtboard::toApprovalAttributes()`.
- Produces:
  - `ApprovalRequestService::MAX_ARTBOARDS = 50`.
  - `ApprovalRequestService::create(StudioFile $file, User $requester, ?array $phases = null, array $approverEmails = [], ?string $message = null, ?CarbonInterface $decideBy = null, bool $notify = true): array{request: ApprovalRequest, share_link: ShareLink, approvers: list<array{email: string, name: string, user_id: string, personal_url: string, mail_sent: bool}>}` — throws `NothingReadyException`, `TooManyItemsException`, `AlreadyAMemberException`, `RoundConflictException`, `ValidationException`.
  - `ApprovalRequestService::recalculate(ApprovalRequest $locked): void`.
  - `Approval::successorsOf(iterable $approvals): Collection<string, Approval>` (keyed by the replaced id, `approvalRequest:id,number` loaded).
  - `ApprovalRequest::counts(?Collection $successors = null): array{approved: int, approved_with_changes: int, changes_required: int, pending: int, superseded: int}`.
  - `ApprovalNotifier::requestSent(ApprovalRequest, ApprovalSubject, ShareLink, User $requester, list<array{user: User, lane: ClientLaneLink}> $approvers, int $artboardCount): list<string>`; `static requestLabel(int $number, int $artboards): string` → `Request {n} · {count} artboard(s)`.
  - `ClientLaneFixtures::sendRequest(StudioFile, User, ?array $phases = null, array $approverEmails = []): array` (service, no mail).

- [ ] **Step 1: Fixture**

In `tests/Support/ClientLaneFixtures.php` add `use App\Models\ShareLink;` (if absent) and `use App\Services\Approval\ApprovalRequestService;`, and:

```php
    /**
     * Send a KV approval request through the real service, without mail.
     *
     * @param  list<string>|null  $phases
     * @param  list<string>  $approverEmails
     * @return array{request: ApprovalRequest, share_link: ShareLink, approvers: list<array<string, mixed>>}
     */
    public static function sendRequest(StudioFile $file, User $user, ?array $phases = null, array $approverEmails = []): array
    {
        return app(ApprovalRequestService::class)->create($file->fresh(), $user, $phases, $approverEmails, notify: false);
    }
```

- [ ] **Step 2: Write the failing test**

Create `tests/Feature/Approval/ApprovalRequestCreateTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Enums\KvResizeExportStatus;
use App\Exceptions\Approval\NothingReadyException;
use App\Exceptions\Approval\TooManyItemsException;
use App\Mail\ApprovalRequestMail;
use App\Models\Approval;
use App\Models\ApprovalRequest;
use App\Models\KvResizeExport;
use App\Models\ShareLink;
use App\Services\Approval\ApprovalRequestService;
use App\Services\Approval\KvArtboard;
use App\Services\Sharing\ShareLinkService;
use App\Services\Studio\KvReadyToShareService;
use Illuminate\Support\Facades\Mail;
use Tests\Support\ClientLaneFixtures;

beforeEach(function () {
    Mail::fake();
    $this->kv = ClientLaneFixtures::kvFile();
    $this->file = $this->kv['file'];
    $this->user = $this->kv['user'];
    ClientLaneFixtures::clientRole($this->kv['workspace']);
    $this->board = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Hero board');
    $this->tile = ClientLaneFixtures::resizeTile($this->file, $this->user, $this->board);
    ClientLaneFixtures::markReady('kv_generation', $this->board->id, $this->user);
    ClientLaneFixtures::markReady('kv_resize_export', $this->tile->id, $this->user);
    $this->boardKey = "board:{$this->board->id}";
    $this->tileKey = "resize:{$this->tile->id}";
});

test('a request freezes one approval per eligible artboard: key, version, label, snapshot', function () {
    $artboards = ClientLaneFixtures::artboards($this->file);

    $request = ClientLaneFixtures::sendRequest($this->file, $this->user)['request']->fresh();
    $approvals = $request->approvals()->orderBy('id')->get();

    expect($request->only(['number', 'status', 'policy', 'subject_type', 'subject_id']))->toBe([
        'number' => 1, 'status' => 'pending', 'policy' => 'optional', 'subject_type' => 'kv_file', 'subject_id' => $this->file->id,
    ])
        ->and($request->sent_at)->not->toBeNull()
        ->and($approvals->pluck('subject_key')->all())->toBe([$this->boardKey, $this->tileKey])
        ->and($approvals[0]->only(['subject_type', 'subject_id', 'phase', 'label', 'round', 'status', 'subject_version_type', 'subject_version_id', 'supersedes_approval_id', 'share_link_id', 'message', 'sent_at', 'policy', 'approvers']))->toBe([
            'subject_type' => 'kv_file', 'subject_id' => $this->file->id, 'phase' => 'craft', 'label' => 'Craft · Hero board', 'round' => 1,
            'status' => 'pending', 'subject_version_type' => 'kv_generation', 'subject_version_id' => $this->board->id,
            'supersedes_approval_id' => null, 'share_link_id' => null, 'message' => null, 'sent_at' => null, 'policy' => 'optional', 'approvers' => [],
        ])
        ->and($approvals[1]->subject_version_type)->toBe('kv_resize_export')
        ->and(KvArtboard::fingerprintOf($approvals[0]->snapshot))->toBe($artboards[$this->boardKey]->fingerprint())
        ->and($approvals[1]->snapshot['id'])->toBe($this->tile->id);
});

test('named approvers make it required, get a personal lane and a mail labelled with the request', function () {
    $result = app(ApprovalRequestService::class)->create($this->file->fresh(), $this->user, null, ['Dina@Brand.test']);
    $request = $result['request']->fresh();

    expect($request->policy)->toBe('required')
        ->and(array_column($request->approvers, 'email'))->toBe(['dina@brand.test'])
        ->and($request->approvals()->pluck('policy')->unique()->all())->toBe(['required'])
        ->and($request->approvals()->first()->approverUserIds())->toBe($request->approverUserIds())
        ->and($result['approvers'][0]['personal_url'])->toContain('/s/'.$result['share_link']->token.'?k=')
        ->and($result['approvers'][0]['mail_sent'])->toBeTrue();

    Mail::assertQueued(ApprovalRequestMail::class, fn (ApprovalRequestMail $mail): bool => $mail->hasTo('dina@brand.test')
        && $mail->versionLabel === 'Request 1 · 2 artboards');
});

test('message and decide_by stay on the request, never on its approvals', function () {
    $decideBy = now()->addDays(2)->endOfDay();

    $request = app(ApprovalRequestService::class)->create($this->file->fresh(), $this->user, null, [], '  Smaller logo please  ', $decideBy, notify: false)['request']->fresh();

    expect($request->message)->toBe('Smaller logo please')
        ->and($request->decide_by->equalTo($decideBy))->toBeTrue()
        ->and($request->approvals()->whereNotNull('message')->count())->toBe(0);
});

test('a new request replaces only the same artboard and the other request stays open', function () {
    $first = ClientLaneFixtures::sendRequest($this->file, $this->user)['request'];
    $this->tile->forceFill(['image_url' => 'https://cdn.test/tile-2.png'])->save();

    $second = ClientLaneFixtures::sendRequest($this->file, $this->user)['request'];

    $old = $first->approvals()->where('subject_key', $this->tileKey)->sole();
    $new = $second->approvals()->sole();

    expect($second->number)->toBe(2)
        ->and($new->subject_key)->toBe($this->tileKey)
        ->and($new->round)->toBe(2)
        ->and($new->supersedes_approval_id)->toBe($old->id)
        ->and($old->status)->toBe('not_relevant')
        ->and($old->resolved_at)->not->toBeNull()
        ->and($first->fresh()->status)->toBe('pending')
        ->and($first->approvals()->where('subject_key', $this->boardKey)->value('status'))->toBe('pending')
        ->and($first->fresh()->counts())->toBe(['approved' => 0, 'approved_with_changes' => 0, 'changes_required' => 0, 'pending' => 1, 'superseded' => 1])
        ->and(Approval::query()->forSubject('kv_file', $this->file->id)->where('subject_key', $this->tileKey)->where('status', 'pending')->count())->toBe(1);
});

test('a request whose every artboard was replaced becomes not_relevant', function () {
    $first = ClientLaneFixtures::sendRequest($this->file, $this->user, ['resize'])['request'];
    $this->tile->forceFill(['image_url' => 'https://cdn.test/tile-2.png'])->save();

    ClientLaneFixtures::sendRequest($this->file, $this->user, ['resize']);

    expect($first->fresh()->status)->toBe('not_relevant')
        ->and($first->fresh()->resolved_at)->not->toBeNull();
});

test('sending again with nothing changed is nothing_ready: identical artwork is never re-sent', function () {
    ClientLaneFixtures::sendRequest($this->file, $this->user);

    expect(fn () => ClientLaneFixtures::sendRequest($this->file, $this->user))->toThrow(NothingReadyException::class)
        ->and(ApprovalRequest::query()->count())->toBe(1);
});

test('each request mints its own approval link with its phases, outside the view-link cap', function () {
    foreach (range(1, 3) as $_) {
        app(ShareLinkService::class)->create($this->file, $this->user, ['craft']);
    }

    $first = ClientLaneFixtures::sendRequest($this->file, $this->user);
    $this->tile->forceFill(['image_url' => 'https://cdn.test/tile-2.png'])->save();
    $second = ClientLaneFixtures::sendRequest($this->file, $this->user);

    expect($first['share_link']->purpose)->toBe(ShareLink::PURPOSE_APPROVAL)
        ->and($first['share_link']->role)->toBe(ShareLink::ROLE_COMMENT)
        ->and($first['share_link']->phaseList())->toBe(['craft', 'resize'])
        ->and($second['share_link']->phaseList())->toBe(['resize'])
        ->and($second['share_link']->token)->not->toBe($first['share_link']->token)
        ->and($first['request']->share_link_id)->toBe($first['share_link']->id);
});

test('nothing ready and too many artboards write nothing', function () {
    expect(fn () => ClientLaneFixtures::sendRequest($this->file, $this->user, ['motion']))->toThrow(NothingReadyException::class);

    // One tile per platform: (parent_generation_id, platform_id) is unique.
    $tiles = KvResizeExport::factory()->count(51)->sequence(fn ($seq) => ['platform_id' => 'custom-'.$seq->index])->create([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $this->board->id,
        'created_by' => $this->user->id,
        'status' => KvResizeExportStatus::Done,
        'image_url' => 'https://cdn.test/tile.png',
    ]);
    app(KvReadyToShareService::class)->markAll('kv_resize_export', $tiles->pluck('id')->all(), $this->user);

    $thrown = null;
    try {
        ClientLaneFixtures::sendRequest($this->file, $this->user, ['resize']);
    } catch (TooManyItemsException $e) {
        $thrown = $e;
    }

    expect($thrown?->max)->toBe(50)
        ->and(ApprovalRequest::query()->count())->toBe(0)
        ->and(ShareLink::query()->where('purpose', ShareLink::PURPOSE_APPROVAL)->count())->toBe(0);
});
```

- [ ] **Step 3: Run — expect FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && ls bootstrap/cache/config.php 2>/dev/null; DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/ApprovalRequestCreateTest.php --compact
```
Expected: FAIL — `Class "App\Services\Approval\ApprovalRequestService" not found`.

- [ ] **Step 4: Models — successors and counts**

In `app/Models/Approval.php` add `use Illuminate\Support\Collection as SupportCollection;` and, after `approvalRequest()`:

```php
    /**
     * The approval that REPLACED each of these KV artboard approvals, keyed by
     * the replaced id (KV approval requests ruling R4: a request sets
     * `supersedes_approval_id` only when it replaced a still-pending
     * approval, so "has a successor" means "replaced"). Not meaningful for
     * deck/plan rounds, whose rounds always point at their predecessor.
     *
     * @param  iterable<Approval>  $approvals
     * @return SupportCollection<string, Approval>
     */
    public static function successorsOf(iterable $approvals): SupportCollection
    {
        $ids = collect($approvals)->map(fn (Approval $approval): string => (string) $approval->id)->values()->all();
        if ($ids === []) {
            return collect();
        }

        return self::query()
            ->whereIn('supersedes_approval_id', $ids)
            ->with('approvalRequest:id,number')
            ->get()
            ->keyBy(fn (Approval $approval): string => (string) $approval->supersedes_approval_id);
    }
```

In `app/Models/ApprovalRequest.php` add `use Illuminate\Support\Collection as SupportCollection;` and:

```php
    /**
     * `counts` of the agency and public request shapes (spec §4.5): approvals
     * per status, a replaced one as `superseded`. A withdrawn approval
     * (not_relevant, never replaced) is in no key (ruling R11).
     *
     * @param  SupportCollection<string, Approval>|null  $successors  from Approval::successorsOf(), when the caller has it
     * @return array{approved: int, approved_with_changes: int, changes_required: int, pending: int, superseded: int}
     */
    public function counts(?SupportCollection $successors = null): array
    {
        $approvals = $this->relationLoaded('approvals') ? $this->approvals : $this->approvals()->get();
        $successors ??= Approval::successorsOf($approvals);

        $counts = ['approved' => 0, 'approved_with_changes' => 0, 'changes_required' => 0, 'pending' => 0, 'superseded' => 0];
        foreach ($approvals as $approval) {
            if ($successors->has((string) $approval->id)) {
                $counts['superseded']++;
            } elseif (array_key_exists($approval->status, $counts)) {
                $counts[$approval->status]++;
            }
        }

        return $counts;
    }
```

- [ ] **Step 5: Notifier — request mail**

In `app/Services/Approval/ApprovalNotifier.php` (restored from develop in Task 3):

1. Add `use App\Models\ApprovalRequest;`.
2. Change `private function audience(Approval $approval, ?User $requester): array` to `private function audience(string $brandId, string $workspaceId, ?User $requester): array`, using `$brandId` / `$workspaceId` in its two `where` clauses; update its two callers to `$this->audience((string) $approval->brand_id, (string) $approval->workspace_id, $requester)`.
3. Replace `mailApprovers()` with:

```php
    /**
     * @param  list<array{user: User, lane: ClientLaneLink}>  $approvers
     * @param  array<string, string>  $logContext  the round or request id, for the warning log
     * @return list<string>
     */
    private function mailApprovers(ApprovalSubject $subject, ShareLink $link, User $requester, array $approvers, string $versionLabel, ?string $note, array $logContext): array
    {
        $sent = [];
        $brandName = (string) ($subject->brand()?->name ?? '');
        $workspaceName = (string) ($subject->workspace()?->name ?? '');

        foreach ($approvers as $approver) {
            $email = (string) $approver['user']->email;
            if ($email === '') {
                continue;
            }

            try {
                Mail::to($email)->queue(new ApprovalRequestMail(
                    title: $subject->title,
                    versionLabel: $versionLabel,
                    brandName: $brandName,
                    workspaceName: $workspaceName,
                    requesterName: (string) $requester->name,
                    note: $note,
                    personalUrl: $this->lanes->personalUrl($link, $approver['lane']),
                    imageUrl: ClientLaneService::shareUrl($link).'/opengraph-image',
                ));
                $sent[] = $email;
            } catch (\Throwable $e) {
                Log::warning('ApprovalNotifier: ApprovalRequestMail failed', [...$logContext, 'email' => $email, 'error' => $e->getMessage()]);
            }
        }

        return $sent;
    }
```
and update its two P0a callers to `$this->mailApprovers($subject, $link, $requester, $approvers, $this->versionLabel($approval), $approval->message, ['approval_id' => (string) $approval->id])`.
4. Add after `resent()`:

```php
    /**
     * A KV approval request was sent (KV approval requests §4.5 step 6): the
     * P0a inbox fan-out and approver mail, labelled "Request {n} · {count}
     * artboard(s)".
     *
     * @param  list<array{user: User, lane: ClientLaneLink}>  $approvers
     * @return list<string> emails that were mailed
     */
    public function requestSent(ApprovalRequest $request, ApprovalSubject $subject, ShareLink $link, User $requester, array $approvers, int $artboardCount): array
    {
        $label = self::requestLabel($request->number, $artboardCount);
        $targetLabel = "{$subject->title} {$label}";

        try {
            $this->notifications->notifyUsers(
                $this->audience((string) $request->brand_id, (string) $request->workspace_id, $requester),
                'approval_requested',
                "Approval requested on {$targetLabel}",
                $request->message ?: 'Waiting on the client.',
                $subject->editorPath,
                $request->workspace_id,
                Kind::ApprovalRequested->value,
                $requester,
                'requested approval on',
                $targetLabel,
            );
        } catch (\Throwable $e) {
            Log::warning('ApprovalNotifier: inbox fan-out failed on request', ['approval_request_id' => $request->id, 'error' => $e->getMessage()]);
        }

        return $this->mailApprovers($subject, $link, $requester, $approvers, $label, $request->message, ['approval_request_id' => (string) $request->id]);
    }

    /** "Request 2 · 6 artboards" / "Request 3 · 1 artboard". */
    public static function requestLabel(int $number, int $artboards): string
    {
        return sprintf('Request %d · %d %s', $number, $artboards, $artboards === 1 ? 'artboard' : 'artboards');
    }
```

- [ ] **Step 6: The service**

Create `app/Services/Approval/ApprovalRequestService.php`:

```php
<?php

declare(strict_types=1);

namespace App\Services\Approval;

// craftsman-ignore: PHP002 — resolved from the container and swapped in tests.

use App\Exceptions\Approval\NothingReadyException;
use App\Exceptions\Approval\RoundConflictException;
use App\Exceptions\Approval\TooManyItemsException;
use App\Exceptions\ClientLane\AlreadyAMemberException;
use App\Models\Approval;
use App\Models\ApprovalRequest;
use App\Models\ClientLaneLink;
use App\Models\ShareLink;
use App\Models\StudioFile;
use App\Models\User;
use App\Services\ClientLane\ClientLaneService;
use App\Services\Sharing\ShareLinkService;
use App\Services\Studio\KvSharePayloadService;
use Carbon\CarbonInterface;
use Illuminate\Database\QueryException;
use Illuminate\Support\Facades\DB;
use Illuminate\Validation\ValidationException;

/**
 * KV approval requests (docs/superpowers/specs/2026-10-01-client-lane-kv-approval-requests-design.md
 * §4.3–§4.5): send the ready artboards as one request with one approval per
 * artboard, keep at most one pending approval per artboard, roll the
 * request's status up from its approvals.
 *
 * LOCK ORDER (ruling R17): every `approval_requests` row of the file
 * (`FOR UPDATE`, by number), then the artboards' `approvals` rows. The
 * decision path ({@see ApprovalRequestDecisionService}) locks its request,
 * then its approvals — the same order, so the two never deadlock.
 */
class ApprovalRequestService
{
    /** Most artboards one request may hold (spec §4.5 `too_many_items`). */
    public const MAX_ARTBOARDS = 50;

    public function __construct(
        private readonly ApprovalRequestPreviewService $previews,
        private readonly ShareLinkService $shareLinks,
        private readonly ClientLaneService $lanes,
        private readonly ApprovalNotifier $notifier,
    ) {}

    /**
     * Freeze the preview's eligible artboards (spec §4.5 steps 1–6).
     *
     * @param  list<string>|null  $phases  null = every phase
     * @param  list<string>  $approverEmails
     * @return array{request: ApprovalRequest, share_link: ShareLink, approvers: list<array{email: string, name: string, user_id: string, personal_url: string, mail_sent: bool}>}
     *
     * @throws NothingReadyException
     * @throws TooManyItemsException
     * @throws AlreadyAMemberException
     * @throws RoundConflictException a concurrent first request on the file won (409, retryable)
     * @throws ValidationException file without brand, workspace without a client role
     */
    public function create(
        StudioFile $file,
        User $requester,
        ?array $phases = null,
        array $approverEmails = [],
        ?string $message = null,
        ?CarbonInterface $decideBy = null,
        bool $notify = true,
    ): array {
        $subject = ApprovalSubject::from($file);
        $brand = $subject->brand();
        if ($brand === null) {
            throw ValidationException::withMessages(['subject_id' => 'This file has no brand.']);
        }

        $emails = array_values(array_unique(array_map(
            static fn (string $e): string => strtolower(trim($e)),
            array_filter($approverEmails, static fn ($e) => is_string($e) && trim($e) !== ''),
        )));

        // Resolved OUTSIDE the transaction (P0a review M-1's reasoning): the
        // payload resolver walks board chains, tiles and renders, and a
        // refusal writes nothing.
        $artboards = $this->previews->preview($file, $phases)->artboards();
        if ($artboards === []) {
            throw new NothingReadyException;
        }
        if (count($artboards) > self::MAX_ARTBOARDS) {
            throw new TooManyItemsException(self::MAX_ARTBOARDS);
        }

        try {
            /** @var array{request: ApprovalRequest, share_link: ShareLink, approvers: list<array{user: User, lane: ClientLaneLink}>} $result */
            $result = DB::transaction(function () use ($file, $requester, $emails, $message, $decideBy, $brand, $artboards): array {
                $existing = ApprovalRequest::query()
                    ->forSubject('kv_file', (string) $file->id)
                    ->orderBy('number')
                    ->lockForUpdate()
                    ->get();
                $number = (int) ($existing->max('number') ?? 0) + 1;

                $keys = array_map(static fn (KvArtboard $a): string => $a->subjectKey, $artboards);
                Approval::query()
                    ->forSubject('kv_file', (string) $file->id)
                    ->whereIn('subject_key', $keys)
                    ->lockForUpdate()
                    ->get(['id']);
                // Re-read under the lock: a request sent since the preview
                // may have opened a newer round on one of these artboards.
                $latest = $this->previews->latestByKey($file, $keys);

                $approvers = [];
                $approverRows = [];
                foreach ($emails as $email) {
                    $user = $this->lanes->ensureClientUser($brand, $email);
                    $lane = $this->lanes->mintLaneLink($brand, $user, $requester);
                    $approvers[] = ['user' => $user, 'lane' => $lane];
                    $approverRows[] = [
                        'user_id' => (string) $user->id,
                        'lane_link_id' => $lane->id,
                        'email' => (string) $user->email,
                        'name' => (string) $user->name,
                    ];
                }
                $policy = $approverRows === [] ? Approval::POLICY_OPTIONAL : Approval::POLICY_REQUIRED;

                $link = $this->shareLinks->createApprovalLink($file, $requester, self::phasesOf($artboards), (string) $file->workspace_id);

                $request = ApprovalRequest::create([
                    'workspace_id' => (string) $file->workspace_id,
                    'brand_id' => (string) $file->brand_id,
                    'subject_type' => 'kv_file',
                    'subject_id' => (string) $file->id,
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
                foreach ($artboards as $artboard) {
                    $previous = $latest[$artboard->subjectKey] ?? null;
                    // Supersede (spec §4.3): only a still-pending approval of the
                    // SAME artboard; the other request stays open for the rest.
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

                    Approval::create([
                        'subject_type' => 'kv_file',
                        'subject_id' => (string) $file->id,
                        'workspace_id' => (string) $file->workspace_id,
                        'brand_id' => (string) $file->brand_id,
                        'requested_by' => $requester->id,
                        'approval_request_id' => $request->id,
                        'round' => ($previous?->round ?? 0) + 1,
                        'supersedes_approval_id' => $replaced?->id,
                        // Copied once and never updated, so P0a FR-3
                        // resolution runs per approval unchanged (§4.1).
                        'policy' => $policy,
                        'approvers' => $approverRows,
                        'status' => Approval::STATUS_PENDING,
                        'message' => null,
                        'share_link_id' => null,
                        'sent_at' => null,
                        ...$artboard->toApprovalAttributes(),
                    ]);
                }

                foreach ($existing as $other) {
                    if (isset($touched[(string) $other->id])) {
                        $this->recalculate($other);
                    }
                }

                return ['request' => $request, 'share_link' => $link, 'approvers' => $approvers];
            });
        } catch (QueryException $e) {
            // A unique collision is a lost race, not a caller error: the
            // request number on the file's very first request (no row to
            // lock), an artboard's round, or a new approver's personal lane
            // minted twice. All answer the retryable 409.
            if ((string) $e->getCode() === '23505') {
                throw new RoundConflictException;
            }
            throw $e;
        }

        $sent = $notify
            ? $this->notifier->requestSent($result['request'], $subject, $result['share_link'], $requester, $result['approvers'], count($artboards))
            : [];

        $approverOut = [];
        foreach ($result['approvers'] as $approver) {
            $approverOut[] = [
                'email' => (string) $approver['user']->email,
                'name' => (string) $approver['user']->name,
                'user_id' => (string) $approver['user']->id,
                'personal_url' => $this->lanes->personalUrl($result['share_link'], $approver['lane']),
                'mail_sent' => in_array((string) $approver['user']->email, $sent, true),
            ];
        }

        return [
            'request' => $result['request'],
            'share_link' => $result['share_link'],
            'approvers' => $approverOut,
        ];
    }

    /**
     * Roll the request's status up from its approvals (spec §4.3), on a row
     * the caller has LOCKED, inside the caller's transaction. `resolved_at`
     * is stamped when the request leaves `pending`.
     */
    public function recalculate(ApprovalRequest $locked): void
    {
        $status = ApprovalRequestRollup::status(
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

    /**
     * Phases the request's artboards live in, canonical order — the phases
     * its link exposes.
     *
     * @param  list<KvArtboard>  $artboards
     * @return list<string>
     */
    private static function phasesOf(array $artboards): array
    {
        $phases = array_map(static fn (KvArtboard $a): string => $a->phase, $artboards);

        return array_values(array_intersect(KvSharePayloadService::PHASES, array_unique($phases)));
    }
}
```

Exception docblocks: `NothingReadyException` → "Nothing on the file is eligible for an approval request: no artboard is marked ready, renders and is unapproved/unsent on its current version — `422 { code: "nothing_ready" }` (KV approval requests §4.5)."; `TooManyItemsException` → "An approval request would hold more than `ApprovalRequestService::MAX_ARTBOARDS` artboards — `422 { code: "too_many_items", max }` (KV approval requests §4.5)." and its message → "A request can hold at most {$max} artboards. Pick fewer phases or unmark some artboards."

- [ ] **Step 7: Run — expect PASS**

Same command as Step 3. Expected: 8 passed. Also re-run `tests/Feature/Approval/DeckPlanApprovalRegressionTest.php` (the notifier changed): 7 passed.

- [ ] **Step 8: Mutation check**

1. In `create()`, set `'supersedes_approval_id' => null` and skip the `forceFill` on `$replaced` → *"a new request replaces only the same artboard…"* must FAIL. Restore.
2. Delete the `foreach ($existing …) recalculate` loop → *"a request whose every artboard was replaced becomes not_relevant"* must FAIL. Restore.
3. Hard-code `'round' => 1` → *"a new request replaces only the same artboard…"* must FAIL (409 `RoundConflictException` from the unique index). Restore.
4. In `create()` pass `count($artboards) + 1` to `requestSent()` → *"named approvers make it required…"* must FAIL (label `Request 1 · 3 artboards`). Restore.

Re-run Step 3's command: 8 passed.

- [ ] **Step 9: Lint + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && F="app/Services/Approval/ApprovalRequestService.php app/Models/Approval.php app/Models/ApprovalRequest.php app/Services/Approval/ApprovalNotifier.php app/Exceptions/Approval/NothingReadyException.php app/Exceptions/Approval/TooManyItemsException.php tests/Support/ClientLaneFixtures.php tests/Feature/Approval/ApprovalRequestCreateTest.php"; for f in ${=F}; do php -l "$f"; done && vendor/bin/pint ${=F} && vendor/bin/pint --test ${=F} && /usr/bin/git add ${=F} && /usr/bin/git commit -m "feat(api): send a KV approval request — one approval per artboard, supersede, own link, approver mail"
```

---
### Task 9: Agency endpoints `v1/approval-requests` — preview, index, store, withdraw, resend

**Files:**
- Create: `app/Http/Controllers/Api/Approval/ApprovalRequestController.php`
- Create: `app/Http/Resources/Approval/ApprovalRequestPresenter.php`
- Modify: `app/Http/Resources/Approval/ApprovalPresenter.php` (`personalUrls()` public + shared)
- Modify: `app/Services/Approval/PinWindow.php` (`forApprovals()`, `forRequest()`, `clientPinCounts()`)
- Modify: `app/Services/Approval/ApprovalRequestService.php` (`withdraw()`, `resend()`)
- Modify: `app/Services/Approval/ApprovalNotifier.php` (`requestResent()`)
- Modify: `app/Policies/ApprovalPolicy.php` (`mayManageRequest()`)
- Modify: `routes/api.php` (import + group after the `approvals` group, ~line 4182)
- Test: `tests/Feature/Approval/ApprovalRequestControllerTest.php`

**Interfaces:**
- Consumes: Task 6 preview, Task 8 `create()` / `counts()` / `successorsOf()`, `ApprovalPresenter::decision()`.
- Produces:
  - Routes `approval-requests.preview|index|store|withdraw|resend` (contract notes).
  - `ApprovalRequestPresenter::agency(ApprovalRequest): array` (AgencyRequest), `::ordered(Collection $approvals): Collection` (canonical phase, then id), `::decided(Collection $approvals, ?string $userId): bool` (R11).
  - `ApprovalPresenter::personalUrls(array $approvers, ?ShareLink $link): array<string, string>` keyed by lane id.
  - `PinWindow::forApprovals(iterable $approvals, Collection $successors): list<PinWindow>`, `::forRequest(ApprovalRequest): list<PinWindow>`, `::clientPinCounts(string $subjectType, string $subjectId, list<PinWindow>): array<string, int>`.
  - `ApprovalRequestService::withdraw(ApprovalRequest): ApprovalRequest` (409-able `ApprovalRoundClosedException`), `::resend(ApprovalRequest, User): list<string>` (`ValidationException` on `approvers`).
  - `ApprovalNotifier::requestResent(ApprovalRequest, ApprovalSubject, ShareLink, User, list<array{user, lane}>): list<string>`.
  - `ApprovalPolicy::mayManageRequest(User, ApprovalRequest): bool`.

- [ ] **Step 1: Write the failing test**

Create `tests/Feature/Approval/ApprovalRequestControllerTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Enums\KvResizeExportStatus;
use App\Mail\ApprovalRequestMail;
use App\Models\Approval;
use App\Models\ClientLaneLink;
use App\Models\Comment;
use App\Models\KvResizeExport;
use App\Models\StudioFile;
use App\Models\User;
use App\Services\Approval\ApprovalRequestService;
use App\Services\ClientLane\ClientLaneService;
use App\Services\Sharing\ShareLinkService;
use App\Services\Studio\KvReadyToShareService;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Mail;
use Tests\Support\ClientLaneFixtures;

/** A root pin written directly (the public store endpoint has its own tests); `$author` = an agency member, else a guest. */
function requestControllerPin(StudioFile $file, string $anchor, ?User $author = null): Comment
{
    $comment = new Comment;
    $comment->forceFill([
        'commentable_type' => 'kv_file',
        'commentable_id' => $file->id,
        'anchor' => ['kind' => 'pin', 'id' => $anchor, 'x' => 0.5, 'y' => 0.5],
        'body' => 'Crop the head less',
        'author_id' => $author?->id,
        'guest_name' => $author === null ? 'Bayu' : null,
        'guest_email' => $author === null ? 'bayu@brand.test' : null,
        'internal_only' => false,
    ])->save();

    return $comment;
}

beforeEach(function () {
    Mail::fake();
    $this->kv = ClientLaneFixtures::kvFile();
    $this->file = $this->kv['file'];
    $this->user = $this->kv['user'];
    ClientLaneFixtures::owner($this->user, $this->kv['workspace']);
    ClientLaneFixtures::clientRole($this->kv['workspace']);
    $this->actingAs($this->user, 'api');

    $this->board = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Hero board');
    $this->tile = ClientLaneFixtures::resizeTile($this->file, $this->user, $this->board);
    ClientLaneFixtures::markReady('kv_generation', $this->board->id, $this->user);
    ClientLaneFixtures::markReady('kv_resize_export', $this->tile->id, $this->user);
    $this->tileKey = "resize:{$this->tile->id}";
    $this->tileAnchor = "resize:{$this->tile->id}:tile.{$this->tile->id}";
    $this->subject = "subject_type=kv_file&subject_id={$this->file->id}";
});

test('preview answers the contract shape and validates its query', function () {
    $data = $this->getJson("/api/v1/approval-requests/preview?{$this->subject}&kv_phases[]=resize")->assertOk()->json('data');

    expect(array_keys($data))->toBe(['phases', 'items', 'already_approved', 'waiting', 'total'])
        ->and(array_column($data['items'], 'subject_key'))->toBe([$this->tileKey])
        ->and(array_column($data['phases'], 'phase'))->toBe(['craft', 'resize'])
        ->and($data['total'])->toBe(1);

    $this->getJson("/api/v1/approval-requests/preview?{$this->subject}&kv_phases[]=storyboard")->assertUnprocessable()->assertJsonValidationErrors('kv_phases.0');
    $this->getJson("/api/v1/approval-requests/preview?subject_type=deck&subject_id={$this->file->id}")->assertUnprocessable()->assertJsonValidationErrors('subject_type');
});

test('POST sends a request and answers the agency shape', function () {
    $tomorrow = now()->addDay()->toDateString();

    $data = $this->postJson('/api/v1/approval-requests', [
        'subject_type' => 'kv_file',
        'subject_id' => $this->file->id,
        'approver_emails' => ['dina@brand.test'],
        'message' => 'Two artboards ready',
        'decide_by' => $tomorrow,
    ])->assertCreated()->json('data');

    $request = $data['request'];
    expect(array_keys($data))->toBe(['request', 'share_url', 'approvers'])
        ->and(array_keys($request))->toBe(['id', 'number', 'status', 'policy', 'message', 'sent_at', 'decide_by', 'deferred_until', 'deferred_note', 'resolved_at', 'created_at', 'share_url', 'share_link_active', 'counts', 'approvers', 'approvals'])
        ->and($request)->toMatchArray(['number' => 1, 'status' => 'pending', 'policy' => 'required', 'message' => 'Two artboards ready', 'share_link_active' => true])
        ->and($request['share_url'])->toBe($data['share_url'])
        ->and($request['counts'])->toBe(['approved' => 0, 'approved_with_changes' => 0, 'changes_required' => 0, 'pending' => 2, 'superseded' => 0])
        ->and(array_keys($request['approvers'][0]))->toBe(['name', 'email', 'user_id', 'personal_url', 'decided'])
        ->and($request['approvers'][0]['personal_url'])->toBe($data['approvers'][0]['personal_url'])
        ->and($request['approvers'][0]['decided'])->toBeFalse()
        ->and(array_keys($request['approvals'][0]))->toBe(['id', 'subject_key', 'phase', 'label', 'round', 'version_id', 'thumbnail_url', 'status', 'superseded_by_request_number', 'pin_count', 'decisions'])
        ->and(array_column($request['approvals'], 'phase'))->toBe(['craft', 'resize'])
        ->and($request['approvals'][0])->toMatchArray(['label' => 'Craft · Hero board', 'round' => 1, 'version_id' => $this->board->id, 'thumbnail_url' => 'https://cdn.test/board-1.png', 'pin_count' => 0, 'decisions' => []])
        ->and(Carbon::parse($request['decide_by'])->timezone(config('app.timezone'))->toDateString())->toBe($tomorrow)
        ->and($data['approvers'][0])->toMatchArray(['email' => 'dina@brand.test', 'mail_sent' => true]);

    Mail::assertQueued(ApprovalRequestMail::class, 1);
});

test('POST validates its body and answers coded errors', function () {
    $base = ['subject_type' => 'kv_file', 'subject_id' => $this->file->id];

    $this->postJson('/api/v1/approval-requests', [...$base, 'kv_phases' => ['craft', 'craft']])->assertUnprocessable()->assertJsonValidationErrors('kv_phases.0');
    $this->postJson('/api/v1/approval-requests', [...$base, 'approver_emails' => ['not-an-email']])->assertUnprocessable()->assertJsonValidationErrors('approver_emails.0');
    $this->postJson('/api/v1/approval-requests', [...$base, 'message' => str_repeat('a', 501)])->assertUnprocessable()->assertJsonValidationErrors('message');
    $this->postJson('/api/v1/approval-requests', [...$base, 'decide_by' => now()->toDateString()])->assertUnprocessable()->assertJsonValidationErrors('decide_by');
    $this->postJson('/api/v1/approval-requests', [...$base, 'kv_phases' => ['motion']])->assertStatus(422)->assertJson(['code' => 'nothing_ready']);
    $this->postJson('/api/v1/approval-requests', [...$base, 'approver_emails' => [$this->user->email]])
        ->assertStatus(422)->assertJson(['code' => 'already_a_member', 'email' => strtolower($this->user->email)]);
});

test('POST above fifty artboards answers too_many_items', function () {
    $tiles = KvResizeExport::factory()->count(50)->sequence(fn ($seq) => ['platform_id' => 'custom-'.$seq->index])->create([
        'studio_file_id' => $this->file->id,
        'parent_generation_id' => $this->board->id,
        'created_by' => $this->user->id,
        'status' => KvResizeExportStatus::Done,
        'image_url' => 'https://cdn.test/tile.png',
    ]);
    app(KvReadyToShareService::class)->markAll('kv_resize_export', $tiles->pluck('id')->all(), $this->user);

    $this->postJson('/api/v1/approval-requests', ['subject_type' => 'kv_file', 'subject_id' => $this->file->id, 'kv_phases' => ['resize']])
        ->assertStatus(422)
        ->assertJson(['code' => 'too_many_items', 'max' => 50]);
});

// Review Focus 4 (agency side): the tile's row id is shared by both requests.
test('index lists open requests first, with counts, replacements and pin_count per approval', function () {
    Carbon::setTestNow('2026-10-01 09:00:00');
    $first = ClientLaneFixtures::sendRequest($this->file, $this->user)['request'];
    Carbon::setTestNow('2026-10-01 09:05:00');
    requestControllerPin($this->file, $this->tileAnchor);
    requestControllerPin($this->file, $this->tileAnchor, $this->user); // agency pin: never a client pin
    Carbon::setTestNow('2026-10-01 09:10:00');
    $this->tile->forceFill(['image_url' => 'https://cdn.test/tile-2.png'])->save();
    $second = ClientLaneFixtures::sendRequest($this->file, $this->user)['request'];
    Carbon::setTestNow('2026-10-01 09:15:00');
    requestControllerPin($this->file, $this->tileAnchor);
    $second->approvals()->update(['status' => Approval::STATUS_APPROVED]);
    app(ApprovalRequestService::class)->recalculate($second->fresh());

    $data = $this->getJson("/api/v1/approval-requests?{$this->subject}")->assertOk()->json('data');
    $firstTile = collect($data[0]['approvals'])->firstWhere('subject_key', $this->tileKey);
    $secondTile = collect($data[1]['approvals'])->firstWhere('subject_key', $this->tileKey);

    expect(array_column($data, 'number'))->toBe([1, 2])
        ->and(array_column($data, 'status'))->toBe(['pending', 'approved'])
        ->and($data[0]['counts'])->toBe(['approved' => 0, 'approved_with_changes' => 0, 'changes_required' => 0, 'pending' => 1, 'superseded' => 1])
        ->and($firstTile)->toMatchArray(['status' => 'not_relevant', 'superseded_by_request_number' => 2, 'pin_count' => 1])
        ->and($secondTile)->toMatchArray(['status' => 'approved', 'round' => 2, 'superseded_by_request_number' => null, 'pin_count' => 1]);

    Carbon::setTestNow();
});

test('personal_url and share_link_active follow the link and the lane', function () {
    $result = app(ApprovalRequestService::class)->create($this->file->fresh(), $this->user, null, ['dina@brand.test'], notify: false);
    $url = "/api/v1/approval-requests?{$this->subject}";

    expect($this->getJson($url)->json('data.0.approvers.0.personal_url'))->toBe($result['approvers'][0]['personal_url']);

    ClientLaneLink::query()->whereKey($result['request']->approvers[0]['lane_link_id'])->update(['revoked_at' => now()]);
    expect($this->getJson($url)->json('data.0.approvers.0.personal_url'))->toBeNull();

    app(ShareLinkService::class)->revoke($result['share_link']);
    expect($this->getJson($url)->json('data.0.share_link_active'))->toBeFalse();
});

test('withdraw closes every still-pending approval and the request; twice is round_closed', function () {
    $request = ClientLaneFixtures::sendRequest($this->file, $this->user)['request'];
    $request->approvals()->where('subject_key', "board:{$this->board->id}")->update(['status' => Approval::STATUS_APPROVED]);

    $data = $this->postJson("/api/v1/approval-requests/{$request->id}/withdraw")->assertOk()->json('data');

    expect($data['status'])->toBe('not_relevant')
        ->and($data['resolved_at'])->not->toBeNull()
        ->and(array_column($data['approvals'], 'status'))->toBe(['approved', 'not_relevant'])
        ->and($data['counts']['superseded'])->toBe(0);

    $this->postJson("/api/v1/approval-requests/{$request->id}/withdraw")->assertStatus(409)->assertJson(['code' => 'round_closed']);
});

test('resend mails the named approvers again; an optional request has nobody to resend to', function () {
    $named = app(ApprovalRequestService::class)->create($this->file->fresh(), $this->user, ['craft'], ['dina@brand.test'], notify: false)['request'];

    $this->postJson("/api/v1/approval-requests/{$named->id}/resend")->assertOk()->assertExactJson(['sent' => ['dina@brand.test']]);
    Mail::assertQueued(ApprovalRequestMail::class, fn (ApprovalRequestMail $mail): bool => $mail->versionLabel === 'Request 1 · 1 artboard');

    $optional = ClientLaneFixtures::sendRequest($this->file, $this->user, ['resize'])['request'];
    $this->postJson("/api/v1/approval-requests/{$optional->id}/resend")->assertStatus(422)->assertJson(['code' => 'no_named_approvers']);
});

test('another workspace can neither read the file nor manage its requests', function () {
    $request = ClientLaneFixtures::sendRequest($this->file, $this->user)['request'];
    $outsider = ClientLaneFixtures::kvFile();
    ClientLaneFixtures::owner($outsider['user'], $outsider['workspace']);
    $this->actingAs($outsider['user'], 'api');

    $this->getJson("/api/v1/approval-requests?{$this->subject}")->assertNotFound();
    $this->getJson("/api/v1/approval-requests/preview?{$this->subject}")->assertNotFound();
    $this->postJson("/api/v1/approval-requests/{$request->id}/withdraw")->assertNotFound();
    expect($request->fresh()->status)->toBe('pending');
});
```

- [ ] **Step 2: Run — expect FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && ls bootstrap/cache/config.php 2>/dev/null; ls bootstrap/cache/routes-v7.php 2>/dev/null; DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/ApprovalRequestControllerTest.php --compact
```
Expected: FAIL — 404 on every `v1/approval-requests` route.

- [ ] **Step 3: `PinWindow` — request windows and client pin counts**

In `app/Services/Approval/PinWindow.php` add imports `use App\Models\ApprovalRequest;`, `use App\Models\Comment;`, `use Illuminate\Support\Collection;` and:

```php
    /**
     * One window per KV request approval; a replaced approval's window ends
     * where its successor's begins (ruling R10), so a resize row shared by
     * two requests keeps each request's pins apart.
     *
     * @param  iterable<Approval>  $approvals
     * @param  Collection<string, Approval>  $successors  Approval::successorsOf($approvals)
     * @return list<self>
     */
    public static function forApprovals(iterable $approvals, Collection $successors): array
    {
        $windows = [];
        foreach ($approvals as $approval) {
            $windows[] = new self(
                (string) $approval->id,
                (string) $approval->subject_version_id,
                $approval->created_at,
                $successors->get((string) $approval->id)?->created_at,
            );
        }

        return $windows;
    }

    /** @return list<self> */
    public static function forRequest(ApprovalRequest $request): array
    {
        $approvals = $request->approvals()->get();

        return self::forApprovals($approvals, Approval::successorsOf($approvals));
    }

    /**
     * Client pins per approval — root comments by a guest or a lane actor
     * (never an agency member) inside each window — in one query
     * (`AgencyRequest.approvals[].pin_count`). Within one request every
     * window has its own version, so the CASE arms never overlap.
     *
     * @param  list<self>  $windows
     * @return array<string, int> approval id → pins
     */
    public static function clientPinCounts(string $subjectType, string $subjectId, array $windows): array
    {
        if ($windows === []) {
            return [];
        }

        $cases = [];
        $bindings = [];
        foreach ($windows as $window) {
            $condition = "split_part(anchor->>'id', ':', 2) = ? AND created_at >= ?";
            $bindings[] = $window->versionId;
            $bindings[] = $window->from;
            if ($window->until !== null) {
                $condition .= ' AND created_at < ?';
                $bindings[] = $window->until;
            }
            $cases[] = "WHEN {$condition} THEN ?";
            $bindings[] = $window->approvalId;
        }

        $query = Comment::query()
            ->selectRaw('CASE '.implode(' ', $cases).' END AS approval_id, COUNT(*) AS pins', $bindings)
            ->where('commentable_type', $subjectType)
            ->where('commentable_id', $subjectId)
            ->whereNull('parent_id')
            ->where(fn ($q) => $q->whereNotNull('lane_link_id')->orWhereNull('author_id'));
        self::constrainRoots($query, $windows);

        return $query->groupByRaw('1')
            ->toBase()
            ->get()
            ->mapWithKeys(fn (object $row): array => [(string) $row->approval_id => (int) $row->pins])
            ->all();
    }
```

- [ ] **Step 4: Presenters**

In `app/Http/Resources/Approval/ApprovalPresenter.php` replace `private static function personalUrls(Approval $approval): array` (docblock included) with:

```php
    /**
     * Live personal links of named approvers, keyed by lane id — for a P0a
     * round or a KV request alike. Empty while the link is missing, revoked
     * or expired; a revoked or expired lane is simply absent.
     *
     * @param  array<int, array<string, mixed>>  $approvers
     * @return array<string, string>
     */
    public static function personalUrls(array $approvers, ?ShareLink $link): array
    {
        $laneIds = array_values(array_filter(array_map(
            static fn (array $a) => $a['lane_link_id'] ?? null,
            $approvers,
        ), static fn ($id) => $id !== null));
        if ($laneIds === [] || $link === null || ! $link->isActive()) {
            return [];
        }

        $lanes = app(ClientLaneService::class);
        $urls = [];
        foreach (ClientLaneLink::query()->whereKey($laneIds)->active()->get() as $lane) {
            $urls[(string) $lane->id] = $lanes->personalUrl($link, $lane);
        }

        return $urls;
    }
```
change its caller in `approval()` to `self::personalUrls($approval->approvers ?? [], $approval->shareLink)`, and add `use App\Models\ShareLink;`.

Create `app/Http/Resources/Approval/ApprovalRequestPresenter.php`:

```php
<?php

declare(strict_types=1);

namespace App\Http\Resources\Approval;

use App\Models\Approval;
use App\Models\ApprovalDecision;
use App\Models\ApprovalRequest;
use App\Services\Approval\KvArtboard;
use App\Services\Approval\PinWindow;
use App\Services\ClientLane\ClientLaneService;
use App\Services\Studio\KvSharePayloadService;
use Illuminate\Support\Collection;

/**
 * KV approval requests as the agency reads them (`AgencyRequest`, spec
 * §4.5) and — Task 11 — as the public page reads them (§4.6). One builder,
 * so the Share dialog, the status chip and the client page agree on every
 * count.
 */
final class ApprovalRequestPresenter
{
    /** @return array<string, mixed> */
    public static function agency(ApprovalRequest $request): array
    {
        $request->loadMissing(['approvals.decisions.actor:id,name', 'shareLink']);
        $approvals = self::ordered($request->approvals);
        $successors = Approval::successorsOf($approvals);
        $pins = PinWindow::clientPinCounts(
            (string) $request->subject_type,
            (string) $request->subject_id,
            PinWindow::forApprovals($approvals, $successors),
        );
        $link = $request->shareLink;
        $personalUrls = ApprovalPresenter::personalUrls($request->approvers ?? [], $link);

        return [
            'id' => $request->id,
            'number' => $request->number,
            'status' => $request->status,
            'policy' => $request->policy,
            'message' => $request->message,
            'sent_at' => $request->sent_at?->toISOString(),
            'decide_by' => $request->decide_by?->toISOString(),
            'deferred_until' => $request->deferred_until?->toISOString(),
            'deferred_note' => $request->deferred_note,
            'resolved_at' => $request->resolved_at?->toISOString(),
            'created_at' => $request->created_at?->toISOString(),
            'share_url' => $link !== null ? ClientLaneService::shareUrl($link) : null,
            'share_link_active' => (bool) $link?->isActive(),
            'counts' => $request->counts($successors),
            'approvers' => array_map(static fn (array $approver): array => [
                'name' => (string) ($approver['name'] ?? ''),
                'email' => (string) ($approver['email'] ?? ''),
                'user_id' => isset($approver['user_id']) ? (string) $approver['user_id'] : null,
                'personal_url' => isset($approver['lane_link_id']) ? ($personalUrls[(string) $approver['lane_link_id']] ?? null) : null,
                'decided' => self::decided($approvals, isset($approver['user_id']) ? (string) $approver['user_id'] : null),
            ], $request->approvers ?? []),
            'approvals' => $approvals->map(static fn (Approval $approval): array => [
                'id' => $approval->id,
                'subject_key' => $approval->subject_key,
                'phase' => $approval->phase,
                'label' => $approval->label,
                'round' => $approval->round,
                'version_id' => (string) $approval->subject_version_id,
                'thumbnail_url' => KvArtboard::thumbnailOf($approval->snapshot),
                'status' => $approval->status,
                'superseded_by_request_number' => $successors->get((string) $approval->id)?->approvalRequest?->number,
                'pin_count' => $pins[(string) $approval->id] ?? 0,
                'decisions' => $approval->decisions->map(static fn (ApprovalDecision $d): array => ApprovalPresenter::decision($d))->values()->all(),
            ])->values()->all(),
        ];
    }

    /**
     * Phase in canonical order, then send order (ULIDs of one request are
     * minted in payload order by one process, so they sort as sent).
     *
     * @param  Collection<int, Approval>  $approvals
     * @return Collection<int, Approval>
     */
    public static function ordered(Collection $approvals): Collection
    {
        $rank = array_flip(KvSharePayloadService::PHASES);

        return $approvals
            ->sort(fn (Approval $a, Approval $b): int => [$rank[$a->phase] ?? 99, (string) $a->id] <=> [$rank[$b->phase] ?? 99, (string) $b->id])
            ->values();
    }

    /**
     * Ruling R11: an approver has `decided` once no still-pending approval
     * of the request is waiting on them.
     *
     * @param  Collection<int, Approval>  $approvals  with `decisions` loaded
     */
    public static function decided(Collection $approvals, ?string $userId): bool
    {
        if ($userId === null) {
            return false;
        }

        foreach ($approvals as $approval) {
            if (! $approval->isPending()) {
                continue;
            }
            $voted = $approval->decisions->contains(
                fn (ApprovalDecision $d): bool => (string) $d->actor_user_id === $userId && $d->isResolving(),
            );
            if (! $voted) {
                return false;
            }
        }

        return true;
    }
}
```

- [ ] **Step 5: Service — withdraw and resend; notifier; policy**

In `app/Services/Approval/ApprovalRequestService.php` add imports `App\Exceptions\Approval\ApprovalRoundClosedException` and append:

```php
    /**
     * Withdraw (spec §4.3): every still-pending approval and the request
     * become `not_relevant`. Decided approvals stay as the record. The link
     * keeps showing the request (§4.4).
     *
     * @throws ApprovalRoundClosedException the request is no longer pending
     */
    public function withdraw(ApprovalRequest $request): ApprovalRequest
    {
        return DB::transaction(function () use ($request): ApprovalRequest {
            /** @var ApprovalRequest $locked */
            $locked = ApprovalRequest::query()->lockForUpdate()->findOrFail($request->id);
            if (! $locked->isPending()) {
                throw new ApprovalRoundClosedException;
            }

            Approval::query()
                ->where('approval_request_id', $locked->id)
                ->where('status', Approval::STATUS_PENDING)
                ->update(['status' => Approval::STATUS_NOT_RELEVANT, 'resolved_at' => now(), 'updated_at' => now()]);

            $locked->forceFill([
                'status' => Approval::STATUS_NOT_RELEVANT,
                'resolved_at' => now(),
            ])->save();

            return $locked;
        });
    }

    /**
     * Re-mail the named approvers their personal links (P0a FR-48, applied
     * to a request).
     *
     * @return list<string> emails sent
     *
     * @throws ValidationException `approvers` — no named approvers, or the request can no longer be resent
     */
    public function resend(ApprovalRequest $request, User $actor): array
    {
        if ($request->policy !== Approval::POLICY_REQUIRED || $request->approverUserIds() === []) {
            throw ValidationException::withMessages(['approvers' => 'This request has no named approvers to resend to.']);
        }

        $subject = ApprovalSubject::find((string) $request->subject_type, (string) $request->subject_id);
        $link = $request->share_link_id !== null ? ShareLink::query()->find($request->share_link_id) : null;
        $brand = $subject?->brand();
        if ($subject === null || $link === null || ! $link->isActive() || $brand === null) {
            throw ValidationException::withMessages(['approvers' => 'This request can no longer be resent.']);
        }

        $approvers = [];
        foreach ($request->approverUserIds() as $userId) {
            $user = User::find($userId);
            if ($user !== null) {
                $approvers[] = ['user' => $user, 'lane' => $this->lanes->mintLaneLink($brand, $user, $actor)];
            }
        }

        return $this->notifier->requestResent($request, $subject, $link, $actor, $approvers);
    }
```

In `app/Services/Approval/ApprovalNotifier.php` add after `requestSent()`:

```php
    /**
     * "Resend" on a KV request — mail only, no inbox rows.
     *
     * @param  list<array{user: User, lane: ClientLaneLink}>  $approvers
     * @return list<string>
     */
    public function requestResent(ApprovalRequest $request, ApprovalSubject $subject, ShareLink $link, User $requester, array $approvers): array
    {
        $count = Approval::query()->where('approval_request_id', $request->id)->count();

        return $this->mailApprovers($subject, $link, $requester, $approvers, self::requestLabel($request->number, $count), $request->message, ['approval_request_id' => (string) $request->id]);
    }
```

In `app/Policies/ApprovalPolicy.php` add `use App\Models\ApprovalRequest;` and:

```php
    /**
     * Withdraw / resend a KV approval request: the requester, or any
     * workspace member who may request approval on the file (same rule as
     * `manage` on a round).
     */
    public static function mayManageRequest(User $user, ApprovalRequest $request): bool
    {
        if ($user->isSuperadmin()) {
            return true;
        }
        if ((string) $user->current_workspace_id !== (string) $request->workspace_id) {
            return false;
        }
        if ((string) $request->requested_by === (string) $user->id) {
            return true;
        }

        try {
            $subject = ApprovalSubject::find((string) $request->subject_type, (string) $request->subject_id);
        } catch (ValidationException) {
            return false;
        }

        return $subject !== null && self::mayRequestOn($user, $subject->model);
    }
```

- [ ] **Step 6: Controller and routes**

Create `app/Http/Controllers/Api/Approval/ApprovalRequestController.php`:

```php
<?php

declare(strict_types=1);

namespace App\Http\Controllers\Api\Approval;

// craftsman-ignore: PHP002 — controllers are not final in this codebase.

use App\Exceptions\Approval\ApprovalRoundClosedException;
use App\Exceptions\Approval\NothingReadyException;
use App\Exceptions\Approval\RoundConflictException;
use App\Exceptions\Approval\TooManyItemsException;
use App\Exceptions\ClientLane\AlreadyAMemberException;
use App\Http\Controllers\Controller;
use App\Http\Resources\Approval\ApprovalRequestPresenter;
use App\Models\Approval;
use App\Models\ApprovalRequest;
use App\Models\StudioFile;
use App\Policies\ApprovalPolicy;
use App\Services\Approval\ApprovalRequestPreviewService;
use App\Services\Approval\ApprovalRequestService;
use App\Services\Approval\ApprovalSubject;
use App\Services\ClientLane\ClientLaneService;
use App\Services\Studio\KvSharePayloadService;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Carbon;
use Illuminate\Validation\Rule;
use Illuminate\Validation\ValidationException;

/**
 * KV approval requests, agency side (spec 2026-10-01 §4.5): preview what a
 * request would contain, send it, list the file's requests, withdraw,
 * resend. Same auth as `v1/approvals`: `auth:sanctum`, workspace check,
 * then the file's own policy ({@see ApprovalPolicy}).
 */
class ApprovalRequestController extends Controller
{
    public function __construct(
        private readonly ApprovalRequestService $requests,
        private readonly ApprovalRequestPreviewService $previews,
    ) {}

    /** GET v1/approval-requests/preview?subject_type=kv_file&subject_id=&kv_phases[]= */
    public function preview(Request $request): JsonResponse
    {
        $validated = $request->validate([...self::subjectRules(), ...self::phaseRules()]);
        $file = $this->file($request, $validated['subject_id'], write: false);

        return response()->json(['data' => $this->previews->preview($file, $validated['kv_phases'] ?? null)->toArray()]);
    }

    /** GET v1/approval-requests?subject_type=kv_file&subject_id= — open first, then newest. */
    public function index(Request $request): JsonResponse
    {
        $validated = $request->validate(self::subjectRules());
        $file = $this->file($request, $validated['subject_id'], write: false);

        $requests = ApprovalRequest::query()
            ->forSubject('kv_file', (string) $file->id)
            ->with(['approvals.decisions.actor:id,name', 'shareLink'])
            ->get()
            ->sort(fn (ApprovalRequest $a, ApprovalRequest $b): int => [$a->isPending() ? 0 : 1, $b->number] <=> [$b->isPending() ? 0 : 1, $a->number])
            ->values();

        return response()->json([
            'data' => $requests->map(fn (ApprovalRequest $r): array => ApprovalRequestPresenter::agency($r))->all(),
        ]);
    }

    /** POST v1/approval-requests — the request form's Send. */
    public function store(Request $request): JsonResponse
    {
        $validated = $request->validate([
            ...self::subjectRules(),
            ...self::phaseRules(),
            'approver_emails' => ['nullable', 'array', 'max:10'],
            'approver_emails.*' => ['string', 'email', 'max:254', 'distinct'],
            'message' => ['nullable', 'string', 'max:500'],
            'decide_by' => ['nullable', 'date_format:Y-m-d', 'after:today'],
        ]);
        $file = $this->file($request, $validated['subject_id'], write: true);

        try {
            $result = $this->requests->create(
                $file,
                $request->user(),
                $validated['kv_phases'] ?? null,
                $validated['approver_emails'] ?? [],
                $validated['message'] ?? null,
                // Ruling R14: the end of that day, app timezone.
                isset($validated['decide_by']) ? Carbon::createFromFormat('Y-m-d', $validated['decide_by'])->endOfDay() : null,
            );
        } catch (AlreadyAMemberException $e) {
            return response()->json(['code' => AlreadyAMemberException::CODE, 'email' => $e->email, 'message' => $e->getMessage()], 422);
        } catch (NothingReadyException $e) {
            return response()->json(['code' => NothingReadyException::CODE, 'message' => $e->getMessage()], 422);
        } catch (TooManyItemsException $e) {
            return response()->json(['code' => TooManyItemsException::CODE, 'max' => $e->max, 'message' => $e->getMessage()], 422);
        } catch (RoundConflictException $e) {
            return response()->json(['code' => RoundConflictException::CODE, 'message' => $e->getMessage()], 409);
        }

        return response()->json(['data' => [
            'request' => ApprovalRequestPresenter::agency($result['request']->fresh()),
            'share_url' => ClientLaneService::shareUrl($result['share_link']),
            'approvers' => $result['approvers'],
        ]], 201);
    }

    /** POST v1/approval-requests/{approvalRequest}/withdraw */
    public function withdraw(Request $request, ApprovalRequest $approvalRequest): JsonResponse
    {
        $this->authorizeManage($request, $approvalRequest);

        try {
            $withdrawn = $this->requests->withdraw($approvalRequest);
        } catch (ApprovalRoundClosedException $e) {
            return response()->json(['code' => ApprovalRoundClosedException::CODE, 'message' => $e->getMessage()], 409);
        }

        return response()->json(['data' => ApprovalRequestPresenter::agency($withdrawn->fresh())]);
    }

    /** POST v1/approval-requests/{approvalRequest}/resend — re-mail the named approvers. */
    public function resend(Request $request, ApprovalRequest $approvalRequest): JsonResponse
    {
        $this->authorizeManage($request, $approvalRequest);

        if ($approvalRequest->policy !== Approval::POLICY_REQUIRED || $approvalRequest->approverUserIds() === []) {
            return response()->json(['code' => 'no_named_approvers', 'message' => 'This request has no named approvers to resend to.'], 422);
        }

        return response()->json(['sent' => $this->requests->resend($approvalRequest, $request->user())]);
    }

    /** @return array<string, array<int, mixed>> */
    private static function subjectRules(): array
    {
        return [
            'subject_type' => ['required', 'string', Rule::in(ApprovalRequest::SUBJECT_TYPES)],
            'subject_id' => ['required', 'string', 'size:26'],
        ];
    }

    /** @return array<string, array<int, mixed>> */
    private static function phaseRules(): array
    {
        return [
            'kv_phases' => ['nullable', 'array', 'min:1'],
            'kv_phases.*' => ['string', 'distinct', Rule::in(KvSharePayloadService::PHASES)],
        ];
    }

    /**
     * The KV file, after the same checks as v1/approvals: 404 outside the
     * caller's workspace (superadmins excepted), 403 without the file's
     * read (or, to send, request) permission.
     */
    private function file(Request $request, string $fileId, bool $write): StudioFile
    {
        try {
            $subject = ApprovalSubject::find('kv_file', $fileId);
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

        /** @var StudioFile $file */
        $file = $subject->model;

        return $file;
    }

    private function authorizeManage(Request $request, ApprovalRequest $approvalRequest): void
    {
        if (! ApprovalPolicy::mayManageRequest($request->user(), $approvalRequest)) {
            // 404 across workspaces: the id must not confirm a request exists elsewhere.
            $user = $request->user();
            abort(! $user->isSuperadmin() && (string) $approvalRequest->workspace_id !== (string) $user->current_workspace_id ? 404 : 403);
        }
    }
}
```

In `routes/api.php` add `use App\Http\Controllers\Api\Approval\ApprovalRequestController;` after the `ApprovalController` import (line 29), and right after the closing `});` of the `Route::prefix('approvals')` group:

```php
            // KV approval requests (spec 2026-10-01 §4.5): one request per
            // send, one approval per artboard. Same gate as `approvals`, in
            // the controller.
            Route::prefix('approval-requests')->group(function () {
                Route::get('preview', [ApprovalRequestController::class, 'preview'])->name('approval-requests.preview');
                Route::get('/', [ApprovalRequestController::class, 'index'])->name('approval-requests.index');
                Route::post('/', [ApprovalRequestController::class, 'store'])->name('approval-requests.store');
                Route::post('/{approvalRequest}/withdraw', [ApprovalRequestController::class, 'withdraw'])->name('approval-requests.withdraw');
                Route::post('/{approvalRequest}/resend', [ApprovalRequestController::class, 'resend'])->name('approval-requests.resend');
            });
```

- [ ] **Step 7: Run — expect PASS**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && php artisan route:list --path=approval-requests && DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/ApprovalRequestControllerTest.php --compact
```
Expected: five `approval-requests.*` routes; 9 passed. Re-run `DeckPlanApprovalRegressionTest.php` (presenter changed): 7 passed.

- [ ] **Step 8: Mutation check**

1. `ApprovalRequestController::index` sort: drop the `isPending()` term → *"index lists open requests first…"* must FAIL (`[2, 1]`). Restore.
2. `PinWindow::forApprovals`: pass `null` as `until` → *"index lists open requests first…"* must FAIL (old tile `pin_count` 2). Restore.
3. `PinWindow::clientPinCounts`: drop the guest/lane `where` → the same test must FAIL (agency pin counted). Restore.
4. `ApprovalPresenter::personalUrls`: drop `->active()` on the `ClientLaneLink` query → *"personal_url and share_link_active…"* must FAIL (the revoked lane still gets a URL). Restore.
5. `ApprovalRequestService::withdraw`: drop the `where('status', pending)` on the bulk update → *"withdraw closes every still-pending approval…"* must FAIL (approved board becomes not_relevant). Restore.

Re-run Step 7's Pest command: 9 passed.

- [ ] **Step 9: Lint + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && F="app/Http/Controllers/Api/Approval/ApprovalRequestController.php app/Http/Resources/Approval/ApprovalRequestPresenter.php app/Http/Resources/Approval/ApprovalPresenter.php app/Services/Approval/PinWindow.php app/Services/Approval/ApprovalRequestService.php app/Services/Approval/ApprovalNotifier.php app/Policies/ApprovalPolicy.php routes/api.php tests/Feature/Approval/ApprovalRequestControllerTest.php"; for f in ${=F}; do php -l "$f"; done && vendor/bin/pint ${=F} && vendor/bin/pint --test ${=F} && /usr/bin/git add ${=F} && /usr/bin/git commit -m "feat(api): v1/approval-requests — preview, send, list, withdraw, resend"
```

---
### Task 10: Revoke withdraws requests; rotate points at request links

**Files:**
- Modify: `app/Services/Approval/ApprovalRequestService.php` (`withdrawPendingOnLinks()`)
- Modify: `app/Listeners/WithdrawRoundsOnRevokedLinks.php`
- Modify: `app/Events/Sharing/ShareLinksRevoked.php` (docblock)
- Modify: `app/Services/ClientLane/ClientLaneService.php` (`newestDecisionLink()`)
- Modify: `app/Http/Controllers/Api/Brand/BrandClientLaneLinkController.php` (use it; delete `newestLinkFor()`)
- Test: `tests/Feature/Approval/ApprovalRequestRevokeTest.php`

**Interfaces:**
- Consumes: `ApprovalRequestService::withdraw()`, `ShareLinkService::revoke()` / `revokeAllActive()` (dispatch `ShareLinksRevoked`).
- Produces: `ApprovalRequestService::withdrawPendingOnLinks(list<string> $linkIds): void`; `ClientLaneService::newestDecisionLink(Brand $brand, User $user): ?ShareLink`.

- [ ] **Step 1: Write the failing test**

Create `tests/Feature/Approval/ApprovalRequestRevokeTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Models\Approval;
use App\Models\User;
use App\Services\Approval\ApprovalRequestService;
use App\Services\Approval\ApprovalService;
use App\Services\Approval\ApprovalSubject;
use App\Services\ClientLane\ClientLaneService;
use App\Services\Sharing\ShareLinkService;
use Illuminate\Support\Facades\Mail;
use Tests\Support\ClientLaneFixtures;

beforeEach(function () {
    Mail::fake();
    $this->kv = ClientLaneFixtures::kvFile();
    $this->file = $this->kv['file'];
    $this->user = $this->kv['user'];
    ClientLaneFixtures::owner($this->user, $this->kv['workspace']);
    ClientLaneFixtures::clientRole($this->kv['workspace']);
    $this->actingAs($this->user, 'api');
    $this->board = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Hero board');
    $this->tile = ClientLaneFixtures::resizeTile($this->file, $this->user, $this->board);
    ClientLaneFixtures::markReady('kv_generation', $this->board->id, $this->user);
    ClientLaneFixtures::markReady('kv_resize_export', $this->tile->id, $this->user);
});

test("revoking a pending request's link withdraws it; decided artboards stay", function () {
    $result = ClientLaneFixtures::sendRequest($this->file, $this->user);
    $result['request']->approvals()->where('subject_key', "board:{$this->board->id}")->update(['status' => Approval::STATUS_APPROVED]);

    app(ShareLinkService::class)->revoke($result['share_link']);

    $request = $result['request']->fresh();
    expect($request->status)->toBe('not_relevant')
        ->and($request->approvals()->orderBy('id')->pluck('status')->all())->toBe(['approved', 'not_relevant']);
});

test("a decided request keeps its decisions when its link is revoked", function () {
    $result = ClientLaneFixtures::sendRequest($this->file, $this->user);
    $result['request']->approvals()->update(['status' => Approval::STATUS_APPROVED]);
    app(ApprovalRequestService::class)->recalculate($result['request']->fresh());

    app(ShareLinkService::class)->revoke($result['share_link']);

    expect($result['request']->fresh()->status)->toBe('approved');
});

test('turning sharing off on the file withdraws its open request', function () {
    $request = ClientLaneFixtures::sendRequest($this->file, $this->user)['request'];

    $this->patchJson("/api/v1/studio/files/{$this->file->id}", ['share_token' => 'disable'])->assertOk();

    expect($request->fresh()->status)->toBe('not_relevant');
});

test('a plan round on a revoked link is still withdrawn, as in P0a', function () {
    $fx = ClientLaneFixtures::plan();
    $result = app(ApprovalService::class)->request(ApprovalSubject::from($fx['plan']), $fx['user'], notify: false);

    app(ShareLinkService::class)->revoke($result['share_link']);

    expect($result['approval']->fresh()->status)->toBe('not_relevant');
});

test("a rotated personal link points at the client's newest request link", function () {
    $result = app(ApprovalRequestService::class)->create($this->file->fresh(), $this->user, null, ['dina@brand.test'], notify: false);
    $dina = User::query()->where('email', 'dina@brand.test')->sole();
    $lanes = app(ClientLaneService::class);

    expect($lanes->newestDecisionLink($this->kv['brand'], $dina)?->id)->toBe($result['share_link']->id);

    app(ShareLinkService::class)->revoke($result['share_link']);

    expect($lanes->newestDecisionLink($this->kv['brand'], $dina))->toBeNull();
});
```

- [ ] **Step 2: Run — expect FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && ls bootstrap/cache/config.php 2>/dev/null; DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/ApprovalRequestRevokeTest.php --compact
```
Expected: FAIL — the three request tests (status stays `pending`) and the rotate test (`newestDecisionLink()` undefined). The plan-round test passes already (P0a behaviour, kept).

- [ ] **Step 3: Implement**

In `app/Services/Approval/ApprovalRequestService.php` append:

```php
    /**
     * Revoking a request's link withdraws the request (spec §4.3 Revoke):
     * its page is a 404 from then on and Resend would mail a dead link. A
     * request decided in the meantime stays decided.
     *
     * @param  list<string>  $linkIds
     */
    public function withdrawPendingOnLinks(array $linkIds): void
    {
        if ($linkIds === []) {
            return;
        }

        ApprovalRequest::query()
            ->whereIn('share_link_id', $linkIds)
            ->where('status', Approval::STATUS_PENDING)
            ->get()
            ->each(function (ApprovalRequest $request): void {
                try {
                    $this->withdraw($request);
                } catch (ApprovalRoundClosedException) {
                    // Decided between the read and the lock — it stays decided.
                }
            });
    }
```

Replace `app/Listeners/WithdrawRoundsOnRevokedLinks.php`'s class body and docblock with:

```php
/**
 * A pending approval round — or KV approval request — whose link is revoked
 * can never be decided: its page is a 404 and Resend would mail dead links.
 * Revoking the link therefore withdraws it (`not_relevant`), the same as
 * the agency's Withdraw. Decided rounds and requests are the record of what
 * the client said and stay as they are. Synchronous: the share sheet
 * re-reads right after the revoke answers.
 */
final class WithdrawRoundsOnRevokedLinks
{
    public function __construct(
        private readonly ApprovalService $approvals,
        private readonly ApprovalRequestService $requests,
    ) {}

    public function handle(ShareLinksRevoked $event): void
    {
        $this->approvals->withdrawPendingOnLinks($event->linkIds);
        $this->requests->withdrawPendingOnLinks($event->linkIds);
    }
}
```
(add `use App\Services\Approval\ApprovalRequestService;`). In `app/Events/Sharing/ShareLinksRevoked.php` change "an approval round waiting on its page" to "an approval round or a KV approval request waiting on its page".

In `app/Services/ClientLane/ClientLaneService.php` add `use App\Models\Approval;` and `use App\Models\ApprovalRequest;` (if absent) and:

```php
    /**
     * The newest ACTIVE link of a P0a round or a KV approval request that
     * names this client as an approver — where a rotated personal code
     * should point (FR-15; KV approval requests R18: KV rounds no longer
     * carry their own link, their request does).
     */
    public function newestDecisionLink(Brand $brand, User $user): ?ShareLink
    {
        $named = [['user_id' => (string) $user->id]];

        $candidates = collect([
            Approval::query()
                ->where('brand_id', $brand->id)
                ->whereNotNull('share_link_id')
                ->whereJsonContains('approvers', $named)
                ->orderByDesc('created_at')
                ->first(['share_link_id', 'created_at']),
            ApprovalRequest::query()
                ->where('brand_id', $brand->id)
                ->whereNotNull('share_link_id')
                ->whereJsonContains('approvers', $named)
                ->orderByDesc('created_at')
                ->first(['share_link_id', 'created_at']),
        ])->filter()->sortByDesc(fn ($row) => $row->created_at)->values();

        foreach ($candidates as $row) {
            $link = ShareLink::query()->find($row->share_link_id);
            if ($link !== null && $link->isActive()) {
                return $link;
            }
        }

        return null;
    }
```

In `app/Http/Controllers/Api/Brand/BrandClientLaneLinkController.php` replace `$link = $this->newestLinkFor($brand, $user);` with `$link = $this->lanes->newestDecisionLink($brand, $user);`, delete `newestLinkFor()`, and delete the imports it alone used (`Approval`, `ShareLink`; pint flags leftovers).

- [ ] **Step 4: Run — expect PASS**

Same command as Step 2. Expected: 5 passed.

- [ ] **Step 5: Mutation check**

1. Listener: delete the `$this->requests->…` line → *"revoking a pending request's link withdraws it…"* must FAIL. Restore.
2. `withdrawPendingOnLinks`: drop `->where('status', pending)` and swallow nothing (remove the try/catch) → *"a decided request keeps its decisions…"* must FAIL with `ApprovalRoundClosedException`. Restore.
3. `newestDecisionLink`: delete the `ApprovalRequest` candidate → *"a rotated personal link…"* must FAIL. Restore.

Re-run: 5 passed.

- [ ] **Step 6: Lint + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && F="app/Services/Approval/ApprovalRequestService.php app/Listeners/WithdrawRoundsOnRevokedLinks.php app/Events/Sharing/ShareLinksRevoked.php app/Services/ClientLane/ClientLaneService.php app/Http/Controllers/Api/Brand/BrandClientLaneLinkController.php tests/Feature/Approval/ApprovalRequestRevokeTest.php"; for f in ${=F}; do php -l "$f"; done && vendor/bin/pint ${=F} && vendor/bin/pint --test ${=F} && /usr/bin/git add ${=F} && /usr/bin/git commit -m "feat(api): revoking a request's link withdraws it; rotate points at request links"
```

---

### Task 11: C-1 — an approval link serves its request

**Files:**
- Modify: `app/Http/Resources/Approval/ApprovalRequestPresenter.php` (`publicPayload()`)
- Modify: `app/Http/Controllers/Api/PublicShareLinkController.php` (`show()`, new `requestFor()`)
- Test: `tests/Feature/Approval/PublicApprovalRequestLinkTest.php`

**Interfaces:**
- Consumes: `ApprovalRequestPresenter::ordered()/decided()`, `ApprovalRequest::counts()`, `Approval::successorsOf()`.
- Produces: `ApprovalRequestPresenter::publicPayload(ApprovalRequest $request, string $fileName, string $brandSlug): array{version: array, items: list<array>, document: array, request: array, approvals: list<array>}` (C-1 and, Task 14, C-3); `PublicShareLinkController::requestFor(ShareLink): ?ApprovalRequest` (private).

- [ ] **Step 1: Write the failing test**

Create `tests/Feature/Approval/PublicApprovalRequestLinkTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Services\Approval\ApprovalRequestService;
use App\Services\Sharing\ShareLinkService;
use App\Services\Studio\KvReadyToShareService;
use Tests\Support\ClientLaneFixtures;

beforeEach(function () {
    $this->kv = ClientLaneFixtures::kvFile();
    $this->file = $this->kv['file'];
    $this->user = $this->kv['user'];
    $this->board = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Hero board');
    $this->tile = ClientLaneFixtures::resizeTile($this->file, $this->user, $this->board);
    ClientLaneFixtures::markReady('kv_generation', $this->board->id, $this->user);
    ClientLaneFixtures::markReady('kv_resize_export', $this->tile->id, $this->user);
    $result = ClientLaneFixtures::sendRequest($this->file, $this->user);
    $this->request = $result['request'];
    $this->link = $result['share_link'];
    $this->show = fn (string $token): array => $this->getJson("/api/public/share-links/{$token}")->assertOk()->json('data');
});

test('an approval link serves its request: approvals, items mirroring them, no round', function () {
    $data = ($this->show)($this->link->token);

    expect(array_keys($data))->toBe(['type', 'brand', 'workspace', 'subject', 'version', 'items', 'document', 'approval', 'request', 'approvals', 'access', 'viewer'])
        ->and($data['approval'])->toBeNull()
        ->and($data['version'])->toMatchArray(['type' => 'approval_request', 'id' => $this->request->id, 'label' => 'Request 1'])
        ->and(array_keys($data['request']))->toBe(['id', 'number', 'status', 'message', 'decide_by', 'deferred_until', 'deferred_note', 'approvers', 'counts'])
        ->and($data['request']['counts'])->toBe(['approved' => 0, 'approved_with_changes' => 0, 'changes_required' => 0, 'pending' => 2, 'superseded' => 0])
        ->and(array_keys($data['approvals'][0]))->toBe(['id', 'phase', 'label', 'round', 'version_id', 'status', 'snapshot', 'replaced', 'decisions'])
        ->and(array_column($data['approvals'], 'phase'))->toBe(['craft', 'resize'])
        ->and($data['approvals'][0])->toMatchArray(['label' => 'Craft · Hero board', 'round' => 1, 'version_id' => $this->board->id, 'status' => 'pending', 'replaced' => false, 'decisions' => []])
        ->and($data['items'])->toBe(array_map(
            fn (array $a): array => array_intersect_key($a, array_flip(['id', 'phase', 'label', 'version_id', 'status', 'snapshot'])),
            $data['approvals'],
        ))
        ->and($data['access'])->toBe(['role' => 'comment', 'expires_at' => null, 'can_decide' => true, 'verification_required' => false]);
});

test('the document is frozen: edits and unmarks after sending change nothing', function () {
    $before = ($this->show)($this->link->token)['document'];

    ClientLaneFixtures::iterate($this->file, $this->user, $this->board, 'https://cdn.test/board-2.png');
    app(KvReadyToShareService::class)->unmark('kv_resize_export', $this->tile->id);

    $after = ($this->show)($this->link->token)['document'];

    expect($after)->toEqual($before)
        ->and($after['name'])->toBe('Ramadan hero KV')
        ->and(array_column($after['phases'], 'phase'))->toBe(['craft', 'resize'])
        ->and($after['phases'][0]['items'][0]['image_url'])->toBe('https://cdn.test/board-1.png');
});

test('a replaced artboard stays on the old page, marked replaced', function () {
    $this->tile->forceFill(['image_url' => 'https://cdn.test/tile-2.png'])->save();
    ClientLaneFixtures::sendRequest($this->file, $this->user);

    $data = ($this->show)($this->link->token);
    $tile = collect($data['approvals'])->firstWhere('phase', 'resize');

    expect($tile)->toMatchArray(['status' => 'not_relevant', 'replaced' => true])
        ->and($data['request']['counts']['superseded'])->toBe(1)
        ->and(array_column($data['document']['phases'], 'phase'))->toBe(['craft', 'resize']);
});

test('a withdrawn request is still shown, with nothing left to decide', function () {
    app(ApprovalRequestService::class)->withdraw($this->request);

    $data = ($this->show)($this->link->token);

    expect($data['request']['status'])->toBe('not_relevant')
        ->and($data['access']['can_decide'])->toBeFalse()
        ->and($data['approvals'])->toHaveCount(2);
});

test('a revoked approval link, or one with no request, is the byte-identical 404', function () {
    app(ShareLinkService::class)->revoke($this->link);
    $orphan = app(ShareLinkService::class)->createApprovalLink($this->file, $this->user, ['craft']);

    foreach ([$this->link->token, $orphan->token] as $token) {
        $this->getJson("/api/public/share-links/{$token}")->assertNotFound()->assertExactJson(['message' => 'Not found.']);
    }
});

test('a KV view link is unchanged: live document, no request', function () {
    $view = app(ShareLinkService::class)->create($this->file, $this->user, ['craft']);

    $data = ($this->show)($view->token);

    expect($data)->not->toHaveKey('request')
        ->and($data)->not->toHaveKey('approvals')
        ->and($data['approval'])->toBeNull()
        ->and($data['items'])->toBe([])
        ->and($data['version']['type'])->toBe('live')
        ->and(array_column($data['document']['phases'], 'phase'))->toBe(['craft']);
});
```

- [ ] **Step 2: Run — expect FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && ls bootstrap/cache/config.php 2>/dev/null; DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/PublicApprovalRequestLinkTest.php --compact
```
Expected: FAIL — the approval link answers the live/view shape (`request` key missing; the orphan link is 200).

- [ ] **Step 3: Presenter**

In `app/Http/Resources/Approval/ApprovalRequestPresenter.php` add:

```php
    /**
     * Everything the public page reads for an approval link (C-1, reused by
     * C-3), built once (spec §4.6, ruling R8). `document` is rebuilt from
     * the snapshots — replaced artboards included — so edits or unmarks
     * after sending never change the page.
     *
     * @return array{version: array<string, mixed>, items: list<array<string, mixed>>, document: array<string, mixed>, request: array<string, mixed>, approvals: list<array<string, mixed>>}
     */
    public static function publicPayload(ApprovalRequest $request, string $fileName, string $brandSlug): array
    {
        $request->loadMissing(['approvals.decisions.actor:id,name']);
        $approvals = self::ordered($request->approvals);
        $successors = Approval::successorsOf($approvals);

        $public = $approvals->map(static fn (Approval $approval): array => [
            'id' => $approval->id,
            'phase' => $approval->phase,
            'label' => $approval->label,
            'round' => $approval->round,
            'version_id' => (string) $approval->subject_version_id,
            'status' => $approval->status,
            'snapshot' => $approval->snapshot,
            'replaced' => $successors->has((string) $approval->id),
            'decisions' => $approval->decisions->map(static fn (ApprovalDecision $d): array => ApprovalPresenter::decision($d))->values()->all(),
        ])->values()->all();

        $phases = [];
        foreach (KvSharePayloadService::PHASES as $phase) {
            $snapshots = $approvals->where('phase', $phase)->pluck('snapshot')->filter()->values()->all();
            if ($snapshots !== []) {
                $phases[] = ['phase' => $phase, 'items' => $snapshots];
            }
        }

        return [
            'version' => [
                'type' => 'approval_request',
                'id' => $request->id,
                'label' => 'Request '.$request->number,
                'created_at' => ($request->sent_at ?? $request->created_at)?->toISOString(),
            ],
            'items' => array_map(static fn (array $a): array => [
                'id' => $a['id'],
                'phase' => $a['phase'],
                'label' => $a['label'],
                'version_id' => $a['version_id'],
                'status' => $a['status'],
                'snapshot' => $a['snapshot'],
            ], $public),
            'document' => ['name' => $fileName, 'brand_slug' => $brandSlug, 'phases' => $phases],
            'request' => [
                'id' => $request->id,
                'number' => $request->number,
                'status' => $request->status,
                'message' => $request->message,
                'decide_by' => $request->decide_by?->toISOString(),
                'deferred_until' => $request->deferred_until?->toISOString(),
                'deferred_note' => $request->deferred_note,
                'approvers' => array_map(static fn (array $approver): array => [
                    'name' => (string) ($approver['name'] ?? ''),
                    'decided' => self::decided($approvals, isset($approver['user_id']) ? (string) $approver['user_id'] : null),
                ], $request->approvers ?? []),
                'counts' => $request->counts($successors),
            ],
            'approvals' => $public,
        ];
    }
```

- [ ] **Step 4: Controller**

In `app/Http/Controllers/Api/PublicShareLinkController.php` add imports `use App\Http\Resources\Approval\ApprovalRequestPresenter;` and `use App\Models\ApprovalRequest;`, add after `currentApproval()`:

```php
    /**
     * The request an approval link was minted for (KV approval requests
     * §4.4) — shown forever, whatever its status. Null for every other link.
     */
    private function requestFor(ShareLink $link): ?ApprovalRequest
    {
        return $link->purpose === ShareLink::PURPOSE_APPROVAL
            ? ApprovalRequest::query()->where('share_link_id', $link->id)->first()
            : null;
    }
```
and replace `show()` with:

```php
    public function show(Request $request, string $token): JsonResponse
    {
        $resolved = $this->resolve($request, $token);
        if ($resolved === null) {
            return $this->notFound();
        }
        [$link, $subject, $lane] = $resolved;

        // An approval link with no request behind it is a dead link (R8).
        $approvalRequest = $this->requestFor($link);
        if ($link->purpose === ShareLink::PURPOSE_APPROVAL && $approvalRequest === null) {
            return $this->notFound();
        }

        // After the resolve so a failed lookup is not recorded as a view.
        $this->shareLinks->touchAccessed($link);

        $brand = $subject->brand();
        $workspace = $subject->workspace();
        $base = [
            'type' => $subject->type,
            'brand' => [
                'name' => (string) ($brand?->name ?? ''),
                'slug' => (string) ($brand?->slug ?? ''),
                'logo_url' => $brand !== null ? $this->brandLogoUrl($brand) : null,
            ],
            'workspace' => ['name' => (string) ($workspace?->name ?? '')],
            'subject' => [
                'id' => (string) $subject->model->getKey(),
                'title' => $subject->title,
                'thumbnail_url' => $subject->thumbnailUrl,
            ],
        ];

        if ($approvalRequest !== null) {
            // KV approval request (spec §4.6 C-1): no round; the request and
            // one approval per artboard instead, document from the snapshots.
            $payload = ApprovalRequestPresenter::publicPayload(
                $approvalRequest,
                (string) $subject->model->getAttribute('name'),
                (string) ($brand?->slug ?? ''),
            );

            return response()->json(['data' => [
                ...$base,
                'version' => $payload['version'],
                'items' => $payload['items'],
                'document' => $payload['document'],
                'approval' => null,
                'request' => $payload['request'],
                'approvals' => $payload['approvals'],
                'access' => [
                    'role' => $link->role ?? ShareLink::ROLE_COMMENT,
                    'expires_at' => $link->expires_at?->toISOString(),
                    'can_decide' => $approvalRequest->isPending(),
                    // Part D adds the verification gate; until then KV never asks.
                    'verification_required' => false,
                ],
                'viewer' => $this->viewer($lane),
            ]])->header('Cache-Control', 'no-store');
        }

        $approval = $this->currentApproval($link);

        $data = [
            ...$base,
            'version' => $approval !== null
                ? ApprovalPresenter::version($approval)
                : ['type' => 'live', 'id' => null, 'label' => 'Latest', 'created_at' => null],
            // Only a KV approval-request link carries artboards.
            'items' => [],
            'document' => $this->document($subject, $link, $approval, $brand?->slug),
            'approval' => $approval !== null ? ApprovalPresenter::approval($approval) : null,
            'access' => [
                'role' => $link->role ?? ShareLink::ROLE_VIEW,
                'expires_at' => $link->expires_at?->toISOString(),
                'can_decide' => $link->role === ShareLink::ROLE_COMMENT
                    && $approval !== null
                    && $approval->status === Approval::STATUS_PENDING,
                'verification_required' => $subject->type === 'campaign'
                    && $lane === null,
            ],
            'viewer' => $this->viewer($lane),
        ];

        // Decks render through the same slide renderer as the editor, which
        // needs the theme catalogue beside the frozen document. Additive to
        // the frozen C-1 shape (a sibling key, not a change to `document`).
        if ($subject->model instanceof Deck) {
            $data['deck'] = $this->deckRenderContext($subject->model, $data['document']);
        }

        return response()->json(['data' => $data])->header('Cache-Control', 'no-store');
    }
```

- [ ] **Step 5: Run — expect PASS**

Same command as Step 2. Expected: 6 passed. Re-run `DeckPlanApprovalRegressionTest.php`: 7 passed.

- [ ] **Step 6: Mutation check**

1. `publicPayload`: build `document.phases` from the live `KvSharePayloadService` instead — simplest form: replace `$approvals->where('phase', $phase)` with `$approvals->where('status', 'pending')->where('phase', $phase)` → *"a replaced artboard stays on the old page…"* must FAIL (resize phase gone). Restore.
2. `show()`: delete the orphan-link `notFound()` → *"a revoked approval link, or one with no request…"* must FAIL. Restore.
3. `show()`: `'can_decide' => true` → *"a withdrawn request is still shown…"* must FAIL. Restore.

Re-run: 6 passed.

- [ ] **Step 7: Lint + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && F="app/Http/Resources/Approval/ApprovalRequestPresenter.php app/Http/Controllers/Api/PublicShareLinkController.php tests/Feature/Approval/PublicApprovalRequestLinkTest.php"; for f in ${=F}; do php -l "$f"; done && vendor/bin/pint ${=F} && vendor/bin/pint --test ${=F} && /usr/bin/git add ${=F} && /usr/bin/git commit -m "feat(api): share-link resolver serves an approval request with per-artboard approvals"
```

---

### Task 12: C-4 — pins and comments on a request link

**Files:**
- Modify: `app/Http/Controllers/Api/PublicShareLinkController.php` (`pinWindows()`)
- Test: `tests/Feature/Approval/PublicApprovalRequestCommentsTest.php`

**Interfaces:**
- Consumes: `PinWindow::forRequest()`, `requestFor()` (Task 11), the Task 3 `comments()` / `storeComment()` that already read `pinWindows()`.
- Produces: `pinWindows()` answers one window per request approval (replaced ones bounded by their successor) for an approval link.

- [ ] **Step 1: Write the failing test**

Create `tests/Feature/Approval/PublicApprovalRequestCommentsTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Models\Comment;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\DB;
use Tests\Support\ClientLaneFixtures;

beforeEach(function () {
    $this->kv = ClientLaneFixtures::kvFile();
    $this->file = $this->kv['file'];
    $this->user = $this->kv['user'];
    $this->board = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Hero board');
    $this->tile = ClientLaneFixtures::resizeTile($this->file, $this->user, $this->board);
    ClientLaneFixtures::markReady('kv_generation', $this->board->id, $this->user);
    ClientLaneFixtures::markReady('kv_resize_export', $this->tile->id, $this->user);
    $this->guest = ['guest_name' => 'Bayu', 'guest_email' => 'bayu@brand.test'];
    $this->boardAnchor = "craft:{$this->board->id}:board";
    $this->tileAnchor = "resize:{$this->tile->id}:tile.{$this->tile->id}";
    $this->send = fn (): string => ClientLaneFixtures::sendRequest($this->file, $this->user)['share_link']->token;
    $this->pin = fn (string $token, string $anchor) => $this->postJson("/api/public/share-links/{$token}/comments", [
        'body' => 'Logo smaller',
        'anchor' => ['kind' => 'pin', 'id' => $anchor, 'x' => 0.4, 'y' => 0.4],
        ...$this->guest,
    ]);
    $this->ids = fn (string $token): array => $this->getJson("/api/public/share-links/{$token}/comments")->assertOk()->json('data.*.id');
});

test('a client can pin any artboard of the request, and nothing outside it', function () {
    $token = ($this->send)();
    $other = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Alt board');

    ($this->pin)($token, $this->boardAnchor)->assertCreated();
    ($this->pin)($token, $this->tileAnchor)->assertCreated();
    ($this->pin)($token, "craft:{$other->id}:board")
        ->assertStatus(422)
        ->assertExactJson(['code' => 'invalid_anchor', 'message' => 'That element is not in this round.']);
});

test('comments list every artboard pin plus replies, and nothing from outside the request', function () {
    $token = ($this->send)();
    $onBoard = ($this->pin)($token, $this->boardAnchor)->assertCreated()->json('data.id');
    $onTile = ($this->pin)($token, $this->tileAnchor)->assertCreated()->json('data.id');
    $reply = $this->postJson("/api/public/share-links/{$token}/comments", ['body' => 'Agreed', 'parent_id' => $onTile, ...$this->guest])
        ->assertCreated()->json('data.id');
    $other = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Alt board');
    // Written directly on purpose: the store endpoint would refuse it.
    $outside = Comment::query()->create([
        'commentable_type' => 'kv_file',
        'commentable_id' => $this->file->id,
        'anchor' => ['kind' => 'pin', 'id' => "craft:{$other->id}:board", 'x' => 0.5, 'y' => 0.5],
        'body' => 'Not in this request',
        'guest_name' => 'Bayu',
        'guest_email' => 'bayu@brand.test',
        'internal_only' => false,
    ])->id;

    $ids = ($this->ids)($token);

    expect($ids)->toEqualCanonicalizing([$onBoard, $onTile, $reply])
        ->and($ids)->not->toContain($outside);
});

test('a replaced artboard takes no new pins on the old link; the new link takes them', function () {
    $first = ($this->send)();
    $this->tile->forceFill(['image_url' => 'https://cdn.test/tile-2.png'])->save();
    $second = ($this->send)();

    ($this->pin)($first, $this->tileAnchor)->assertStatus(422)->assertJson(['code' => 'invalid_anchor']);
    ($this->pin)($first, $this->boardAnchor)->assertCreated();
    ($this->pin)($second, $this->tileAnchor)->assertCreated();
});

// Review Focus 4: the tile's row id is the version in BOTH requests.
test('a pin on a re-sent tile stays with the request it was placed in', function () {
    Carbon::setTestNow('2026-10-01 09:00:00');
    $first = ($this->send)();
    Carbon::setTestNow('2026-10-01 09:05:00');
    $old = ($this->pin)($first, $this->tileAnchor)->assertCreated()->json('data.id');
    Carbon::setTestNow('2026-10-01 09:10:00');
    $this->tile->forceFill(['image_url' => 'https://cdn.test/tile-2.png'])->save();
    $second = ($this->send)();
    Carbon::setTestNow('2026-10-01 09:15:00');
    $new = ($this->pin)($second, $this->tileAnchor)->assertCreated()->json('data.id');

    expect(($this->ids)($first))->toBe([$old])
        ->and(($this->ids)($second))->toBe([$new]);

    Carbon::setTestNow();
});

// Review Focus 5: `comments.created_at` is a naive timestamp, the approval's a
// timestamptz; an instant comparison would push the window 7 hours ahead.
test('a request pin counts even when the app and the database disagree on the timezone', function () {
    config(['app.timezone' => 'Asia/Jakarta']);
    date_default_timezone_set('Asia/Jakarta');
    DB::statement("SET TIME ZONE 'UTC'");

    $fx = ClientLaneFixtures::kvFile();
    $board = ClientLaneFixtures::board($fx['file'], $fx['user']);
    ClientLaneFixtures::markReady('kv_generation', $board->id, $fx['user']);
    $token = ClientLaneFixtures::sendRequest($fx['file'], $fx['user'])['share_link']->token;

    $pin = ($this->pin)($token, "craft:{$board->id}:board")->assertCreated()->json('data.id');

    expect(($this->ids)($token))->toBe([$pin]);
});
```

- [ ] **Step 2: Run — expect FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && ls bootstrap/cache/config.php 2>/dev/null; DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/PublicApprovalRequestCommentsTest.php --compact
```
Expected: FAIL — every pin on an approval link answers `422 invalid_anchor` ("There is no open round to pin this to."), and `GET …/comments` returns `[]`.

- [ ] **Step 3: Implement**

In `app/Http/Controllers/Api/PublicShareLinkController.php` replace `pinWindows()` (docblock included) with:

```php
    /**
     * The pin windows of what this link serves: one per approval of its KV
     * request (a replaced approval's window ends where its successor's
     * begins — R10), or the current round's single window; null when the
     * link serves nothing (view link, withdrawn round, orphan approval link).
     *
     * @return list<PinWindow>|null
     */
    private function pinWindows(ShareLink $link): ?array
    {
        if ($link->purpose === ShareLink::PURPOSE_APPROVAL) {
            $approvalRequest = $this->requestFor($link);

            return $approvalRequest !== null ? PinWindow::forRequest($approvalRequest) : null;
        }

        $approval = $this->currentApproval($link);

        return $approval !== null ? [PinWindow::forRound($approval)] : null;
    }
```

- [ ] **Step 4: Run — expect PASS**

Same command as Step 2. Expected: 5 passed. Re-run `DeckPlanApprovalRegressionTest.php`: 7 passed.

- [ ] **Step 5: Mutation check**

1. `PinWindow::forApprovals`: pass `null` as `until` → *"a pin on a re-sent tile stays with the request…"* must FAIL (`$new` listed on the first link) and *"a replaced artboard takes no new pins on the old link…"* must FAIL. Restore.
2. `PinWindow::constrainRoots`: drop the `>= $window->from` bound → *"a pin on a re-sent tile stays with the request…"* must FAIL (`$old` listed on the second link). Restore.

Re-run: 5 passed.

- [ ] **Step 6: Lint + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && F="app/Http/Controllers/Api/PublicShareLinkController.php tests/Feature/Approval/PublicApprovalRequestCommentsTest.php"; for f in ${=F}; do php -l "$f"; done && vendor/bin/pint ${=F} && vendor/bin/pint --test ${=F} && /usr/bin/git add ${=F} && /usr/bin/git commit -m "feat(api): pins and comments on a request link, scoped per artboard approval"
```

---
### Task 13: Decision digest — sender, delayed job, mail

**Files:**
- Create: `app/Services/Approval/ApprovalRequestDigest.php`
- Create: `app/Jobs/SendApprovalRequestDigest.php`
- Create: `app/Mail/ApprovalRequestDigestMail.php`
- Create: `resources/views/emails/client-lane/approval-request-digest.blade.php`
- Modify: `app/Services/Approval/ApprovalNotifier.php` (`requestDigest()`, `clientNames()`, `countsLine()`, `digestLines()`)
- Test: `tests/Feature/Approval/ApprovalRequestDigestTest.php`

**Interfaces:**
- Consumes: `ApprovalRequest::counts()`, `ApprovalSubject::find()`, the notifier's `audience()`.
- Produces:
  - `ApprovalRequestDigest::sendNow(string $requestId): bool` — sends what was decided since `digest_sent_at` (resolving outcomes only), stamps `digest_sent_at`; false when nothing is new. Idempotent; locks the request row.
  - `SendApprovalRequestDigest` — `public string $requestId, public string $stamp`; `DELAY_MINUTES = 15`; `static schedule(ApprovalRequest $request): void` (queue `default`, delay 15 min, stamp = `last_decision_at->toIso8601String()`); `handle(ApprovalRequestDigest)` skips when `last_decision_at` is newer than the stamp.
  - `ApprovalRequestDigestMail(string $clientName, int $requestNumber, string $title, string $brandName, string $countsLine, list<string> $lines, string $editorUrl)` — subject `{client} reviewed Request {n} — {title}`.
  - `ApprovalNotifier::requestDigest(ApprovalRequest, ApprovalSubject, Collection $decisions, array $counts): void`; `static clientNames(Collection $decisions): string`; `static countsLine(array $counts): string`; `static digestLines(Collection $decisions): list<string>` (ruling R16).

- [ ] **Step 1: Write the failing test**

Create `tests/Feature/Approval/ApprovalRequestDigestTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Jobs\SendApprovalRequestDigest;
use App\Mail\ApprovalRequestDigestMail;
use App\Models\Approval;
use App\Models\ApprovalDecision;
use App\Models\Notification;
use App\Services\Approval\ApprovalNotifier;
use App\Services\Approval\ApprovalRequestDigest;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Mail;
use Tests\Support\ClientLaneFixtures;

beforeEach(function () {
    Mail::fake();
    $this->kv = ClientLaneFixtures::kvFile();
    $this->file = $this->kv['file'];
    $this->user = $this->kv['user'];
    $this->board = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Hero board');
    $this->tile = ClientLaneFixtures::resizeTile($this->file, $this->user, $this->board);
    ClientLaneFixtures::markReady('kv_generation', $this->board->id, $this->user);
    ClientLaneFixtures::markReady('kv_resize_export', $this->tile->id, $this->user);
    $this->request = ClientLaneFixtures::sendRequest($this->file, $this->user)['request'];
    $this->boardApproval = $this->request->approvals()->where('subject_key', "board:{$this->board->id}")->sole();
    $this->tileApproval = $this->request->approvals()->where('subject_key', "resize:{$this->tile->id}")->sole();

    // A recorded guest decision that settled the artboard, stamped on the request.
    $this->decide = function (Approval $approval, string $outcome, string $name, array $pins = []): ApprovalDecision {
        $approval->forceFill(['status' => $outcome])->save();
        $this->request->forceFill(['last_decision_at' => now()])->save();

        return ApprovalDecision::query()->create([
            'approval_id' => $approval->id,
            'guest_name' => $name,
            'guest_email' => strtolower($name).'@brand.test',
            'outcome' => $outcome,
            'advisory' => false,
            'pins' => $pins,
            'decided_at' => now(),
        ]);
    };
    $this->digest = app(ApprovalRequestDigest::class);
});

test('the digest lists what was decided since the last one, once', function () {
    Carbon::setTestNow('2026-10-01 10:00:00');
    ($this->decide)($this->boardApproval, 'approved_with_changes', 'Dina', ['01aaaaaaaaaaaaaaaaaaaaaaaa', '01bbbbbbbbbbbbbbbbbbbbbbbb']);

    expect($this->digest->sendNow($this->request->id))->toBeTrue()
        ->and($this->digest->sendNow($this->request->id))->toBeFalse();

    Carbon::setTestNow('2026-10-01 10:05:00');
    ($this->decide)($this->tileApproval, 'changes_required', 'Bayu');
    expect($this->digest->sendNow($this->request->id))->toBeTrue();

    $mails = Mail::queued(ApprovalRequestDigestMail::class)->values();
    expect($mails)->toHaveCount(2)
        ->and($mails[0]->envelope()->subject)->toBe('Dina reviewed Request 1 — Ramadan hero KV')
        ->and($mails[0]->countsLine)->toBe('1 approved · 1 still open')
        ->and($mails[0]->lines)->toBe(['Craft · Hero board — Approved with fixes · 2 pins'])
        ->and($mails[0]->hasTo($this->user->email))->toBeTrue()
        ->and($mails[1]->clientName)->toBe('Bayu')
        ->and($mails[1]->countsLine)->toBe('1 approved · 1 new version asked')
        ->and($mails[1]->lines)->toHaveCount(1)
        ->and($mails[1]->lines[0])->toStartWith('Resize · ')->toEndWith(' — New version asked')
        ->and($mails[1]->render())->toContain('New version asked');

    Carbon::setTestNow();
});

test('a job whose stamp is older than the last decision sends nothing; the newest job sends both', function () {
    Carbon::setTestNow('2026-10-01 10:00:00');
    ($this->decide)($this->boardApproval, 'approved', 'Dina');
    $olderStamp = $this->request->fresh()->last_decision_at->toIso8601String();
    Carbon::setTestNow('2026-10-01 10:03:00');
    ($this->decide)($this->tileApproval, 'approved', 'Dina');
    $newerStamp = $this->request->fresh()->last_decision_at->toIso8601String();

    Carbon::setTestNow('2026-10-01 10:15:00');
    (new SendApprovalRequestDigest($this->request->id, $olderStamp))->handle($this->digest);
    Mail::assertNotQueued(ApprovalRequestDigestMail::class);

    Carbon::setTestNow('2026-10-01 10:18:00');
    (new SendApprovalRequestDigest($this->request->id, $newerStamp))->handle($this->digest);
    Mail::assertQueued(ApprovalRequestDigestMail::class, fn (ApprovalRequestDigestMail $mail): bool => count($mail->lines) === 2
        && $mail->countsLine === '2 approved');

    Carbon::setTestNow();
});

test('the digest reaches the inbox as approval_decided', function () {
    ($this->decide)($this->boardApproval, 'approved', 'Dina');

    $this->digest->sendNow($this->request->id);

    expect(Notification::query()->where('user_id', $this->user->id)->where('kind', 'approval_decided')->count())->toBe(1);
});

test('names and counts read naturally', function (array $names, string $expectedNames, array $counts, string $expectedCounts) {
    $decisions = collect(array_map(
        fn (string $name): ApprovalDecision => new ApprovalDecision(['guest_name' => $name, 'guest_email' => strtolower($name).'@brand.test', 'outcome' => 'approved']),
        $names,
    ));

    expect(ApprovalNotifier::clientNames($decisions))->toBe($expectedNames)
        ->and(ApprovalNotifier::countsLine([...['approved' => 0, 'approved_with_changes' => 0, 'changes_required' => 0, 'pending' => 0, 'superseded' => 0], ...$counts]))->toBe($expectedCounts);
})->with([
    'one client' => [['Dina'], 'Dina', ['approved' => 4, 'approved_with_changes' => 1, 'changes_required' => 1, 'pending' => 2], '5 approved · 1 new version asked · 2 still open'],
    'two clients' => [['Dina', 'Bayu', 'Dina'], 'Dina and Bayu', ['changes_required' => 2], '2 new versions asked'],
    'four clients' => [['Dina', 'Bayu', 'Sari', 'Rio'], 'Dina, Bayu +2', ['superseded' => 3], 'No decisions yet'],
]);
```

- [ ] **Step 2: Run — expect FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && ls bootstrap/cache/config.php 2>/dev/null; DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/ApprovalRequestDigestTest.php --compact
```
Expected: FAIL — `Class "App\Services\Approval\ApprovalRequestDigest" not found`.

- [ ] **Step 3: Mail and view**

`app/Mail/ApprovalRequestDigestMail.php`:

```php
<?php

namespace App\Mail;

use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Mail\Mailable;
use Illuminate\Mail\Mailables\Content;
use Illuminate\Mail\Mailables\Envelope;
use Illuminate\Queue\SerializesModels;

/**
 * "{Client} reviewed Request {n} — {file}" — the KV approval request
 * decision digest, to the REQUESTER only (KV approval requests §4.7): a
 * counts line and one line per artboard decided since the last digest.
 */
class ApprovalRequestDigestMail extends Mailable implements ShouldQueue
{
    use Queueable, SerializesModels;

    /**
     * @param  list<string>  $lines
     */
    public function __construct(
        public string $clientName,
        public int $requestNumber,
        public string $title,
        public string $brandName,
        public string $countsLine,
        public array $lines,
        public string $editorUrl,
    ) {}

    public function envelope(): Envelope
    {
        return new Envelope(
            subject: "{$this->clientName} reviewed Request {$this->requestNumber} — {$this->title}",
            tags: ['client-lane', 'approval-request-digest'],
            metadata: ['notification_type' => 'approval_request_digest'],
        );
    }

    public function content(): Content
    {
        return new Content(view: 'emails.client-lane.approval-request-digest');
    }
}
```

`resources/views/emails/client-lane/approval-request-digest.blade.php`:

```blade
{{-- KV approval requests (spec 2026-10-01 §4.7) — the decision digest, sent to the requester only. --}}
@extends('emails.client-lane.layout')

@section('title', 'Request reviewed')
@section('heading', "{$clientName} reviewed Request {$requestNumber}")
@section('subheading', "{$title} · {$brandName}")
@section('body')
{{ $countsLine }}@foreach($lines as $line)<br>{{ $line }}@endforeach
@endsection
@section('cta_url', $editorUrl)
@section('cta_label', 'Open in frndOS')
```

- [ ] **Step 4: Notifier**

In `app/Services/Approval/ApprovalNotifier.php` add `use App\Mail\ApprovalRequestDigestMail;` and `use Illuminate\Support\Collection;`, and:

```php
    /**
     * The decision digest (KV approval requests §4.7): one inbox fan-out
     * (`approval_decided`, the P0a audience) and one mail to the requester
     * for everything decided since the last digest.
     *
     * @param  Collection<int, ApprovalDecision>  $decisions  oldest first, `approval` loaded
     * @param  array{approved: int, approved_with_changes: int, changes_required: int, pending: int, superseded: int}  $counts
     */
    public function requestDigest(ApprovalRequest $request, ApprovalSubject $subject, Collection $decisions, array $counts): void
    {
        $client = self::clientNames($decisions);
        $headline = "{$client} reviewed Request {$request->number}";
        $countsLine = self::countsLine($counts);
        $requester = $request->requested_by !== null ? User::find($request->requested_by) : null;

        try {
            $this->notifications->notifyUsers(
                $this->audience((string) $request->brand_id, (string) $request->workspace_id, $requester),
                'approval_decided',
                "{$headline} — {$subject->title}",
                $countsLine,
                $subject->editorPath,
                $request->workspace_id,
                Kind::ApprovalDecided->value,
                null,
                null,
                "{$subject->title} Request {$request->number}",
            );
        } catch (\Throwable $e) {
            Log::warning('ApprovalNotifier: inbox fan-out failed on digest', ['approval_request_id' => $request->id, 'error' => $e->getMessage()]);
        }

        if ($requester === null || ! filled($requester->email)) {
            return;
        }

        try {
            Mail::to($requester->email)->queue(new ApprovalRequestDigestMail(
                clientName: $client,
                requestNumber: $request->number,
                title: $subject->title,
                brandName: (string) ($subject->brand()?->name ?? ''),
                countsLine: $countsLine,
                lines: self::digestLines($decisions),
                editorUrl: rtrim((string) config('app.frontend_url'), '/').$subject->editorPath,
            ));
        } catch (\Throwable $e) {
            Log::warning('ApprovalNotifier: ApprovalRequestDigestMail failed', ['approval_request_id' => $request->id, 'error' => $e->getMessage()]);
        }
    }

    /**
     * Who decided, in order (ruling R16): "Dina", "Dina and Bayu",
     * "Dina, Bayu +2".
     *
     * @param  Collection<int, ApprovalDecision>  $decisions
     */
    public static function clientNames(Collection $decisions): string
    {
        $names = $decisions->map(fn (ApprovalDecision $d): string => $d->actorName())->unique()->values()->all();

        return match (count($names)) {
            0 => 'Your client',
            1 => $names[0],
            2 => "{$names[0]} and {$names[1]}",
            default => "{$names[0]}, {$names[1]} +".(count($names) - 2),
        };
    }

    /**
     * "5 approved · 1 new version asked · 2 still open" — zero parts omitted,
     * `approved` includes approved with changes (ruling R16).
     *
     * @param  array{approved: int, approved_with_changes: int, changes_required: int, pending: int, superseded: int}  $counts
     */
    public static function countsLine(array $counts): string
    {
        $approved = $counts['approved'] + $counts['approved_with_changes'];
        $changes = $counts['changes_required'];

        $parts = [];
        if ($approved > 0) {
            $parts[] = "{$approved} approved";
        }
        if ($changes > 0) {
            $parts[] = "{$changes} new ".($changes === 1 ? 'version' : 'versions').' asked';
        }
        if ($counts['pending'] > 0) {
            $parts[] = "{$counts['pending']} still open";
        }

        return $parts === [] ? 'No decisions yet' : implode(' · ', $parts);
    }

    /**
     * One line per artboard decided in the batch, its latest decision:
     * "Craft · Hero board — Approved with fixes · 2 pins".
     *
     * @param  Collection<int, ApprovalDecision>  $decisions
     * @return list<string>
     */
    public static function digestLines(Collection $decisions): array
    {
        $latest = [];
        foreach ($decisions as $decision) {
            $latest[(string) $decision->approval_id] = $decision;
        }

        return array_values(array_map(static function (ApprovalDecision $decision): string {
            $verdict = match ($decision->outcome) {
                ApprovalDecision::OUTCOME_APPROVED => 'Approved',
                ApprovalDecision::OUTCOME_APPROVED_WITH_CHANGES => 'Approved with fixes',
                default => 'New version asked',
            };
            $pins = count($decision->pins ?? []);

            return sprintf(
                '%s — %s%s%s',
                (string) ($decision->approval?->label ?? 'Artboard'),
                $verdict,
                $decision->advisory ? ' (advisory)' : '',
                $pins > 0 ? ' · '.$pins.' '.($pins === 1 ? 'pin' : 'pins') : '',
            );
        }, $latest));
    }
```

- [ ] **Step 5: Sender and job**

`app/Services/Approval/ApprovalRequestDigest.php`:

```php
<?php

declare(strict_types=1);

namespace App\Services\Approval;

// craftsman-ignore: PHP002 — resolved from the container and swapped in tests.

use App\Models\Approval;
use App\Models\ApprovalDecision;
use App\Models\ApprovalRequest;
use Illuminate\Support\Facades\DB;

/**
 * Sends a KV approval request's decision digest (spec §4.7): everything
 * decided since `digest_sent_at`, then stamps it. Called by the delayed
 * {@see \App\Jobs\SendApprovalRequestDigest} and, at once, when a decision
 * takes the request out of `pending`. Idempotent: a second call with
 * nothing new sends nothing, so the immediate send and the later job never
 * double-mail.
 */
class ApprovalRequestDigest
{
    public function __construct(private readonly ApprovalNotifier $notifier) {}

    /** @return bool whether a digest went out */
    public function sendNow(string $requestId): bool
    {
        $batch = DB::transaction(function () use ($requestId): ?array {
            /** @var ApprovalRequest|null $request */
            $request = ApprovalRequest::query()->lockForUpdate()->find($requestId);
            if ($request === null) {
                return null;
            }

            $decisions = ApprovalDecision::query()
                ->whereIn('approval_id', Approval::query()->select('id')->where('approval_request_id', $request->id))
                ->whereIn('outcome', ApprovalDecision::RESOLVING_OUTCOMES)
                ->when($request->digest_sent_at !== null, fn ($q) => $q->where('decided_at', '>', $request->digest_sent_at))
                ->with(['approval', 'actor:id,name'])
                ->orderBy('decided_at')
                ->orderBy('id')
                ->get();
            if ($decisions->isEmpty()) {
                return null;
            }

            $request->forceFill(['digest_sent_at' => now()])->save();

            return [$request, $decisions];
        });

        if ($batch === null) {
            return false;
        }
        [$request, $decisions] = $batch;

        $subject = ApprovalSubject::find((string) $request->subject_type, (string) $request->subject_id);
        if ($subject === null) {
            return false;
        }

        $this->notifier->requestDigest($request, $subject, $decisions, $request->counts());

        return true;
    }
}
```

`app/Jobs/SendApprovalRequestDigest.php`:

```php
<?php

namespace App\Jobs;

use App\Models\ApprovalRequest;
use App\Services\Approval\ApprovalRequestDigest;
use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Queue\SerializesModels;
use Illuminate\Support\Carbon;

/**
 * The delayed half of the decision digest (KV approval requests §4.7):
 * every decision on a request dispatches one of these 15 minutes out,
 * stamped with the request's `last_decision_at`. When it runs, a newer
 * decision (a later stamp on the row) means a newer job will send — this
 * one skips. Otherwise it sends whatever is new since the last digest.
 */
class SendApprovalRequestDigest implements ShouldQueue
{
    use Dispatchable, InteractsWithQueue, Queueable, SerializesModels;

    public const DELAY_MINUTES = 15;

    public int $tries = 3;

    public function __construct(public string $requestId, public string $stamp) {}

    /** Dispatch for a request whose `last_decision_at` was just stamped (read back from the row). */
    public static function schedule(ApprovalRequest $request): void
    {
        self::dispatch((string) $request->id, (string) $request->last_decision_at?->toIso8601String())
            ->onQueue('default')
            ->delay(now()->addMinutes(self::DELAY_MINUTES));
    }

    public function handle(ApprovalRequestDigest $digest): void
    {
        $request = ApprovalRequest::query()->find($this->requestId);
        if ($request === null) {
            return;
        }

        if ($this->stamp !== '' && $request->last_decision_at !== null && $request->last_decision_at->gt(Carbon::parse($this->stamp))) {
            return;
        }

        $digest->sendNow((string) $request->id);
    }
}
```

- [ ] **Step 6: Run — expect PASS**

Same command as Step 2. Expected: 6 passed (3 tests + 3 dataset rows). If `Notification` lives elsewhere or the column is named differently, read `app/Jobs/NotifyUsersJob.php` and correct the test's model/column — never the notifier.

- [ ] **Step 7: Mutation check**

1. `SendApprovalRequestDigest::handle`: delete the stamp check → *"a job whose stamp is older…"* must FAIL (the older job mails). Restore.
2. `ApprovalRequestDigest::sendNow`: delete the `->when(digest_sent_at …)` line → *"the digest lists what was decided since the last one…"* must FAIL (the second `sendNow` in the same minute returns true, and mail 2 has two lines). Restore.
3. `countsLine`: always `'version'` → *"names and counts read naturally"* row "two clients" must FAIL. Restore.

Re-run: 6 passed.

- [ ] **Step 8: Lint + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && F="app/Services/Approval/ApprovalRequestDigest.php app/Jobs/SendApprovalRequestDigest.php app/Mail/ApprovalRequestDigestMail.php app/Services/Approval/ApprovalNotifier.php tests/Feature/Approval/ApprovalRequestDigestTest.php"; for f in ${=F}; do php -l "$f"; done && vendor/bin/pint ${=F} && vendor/bin/pint --test ${=F} && /usr/bin/git add ${=F} resources/views/emails/client-lane/approval-request-digest.blade.php && /usr/bin/git commit -m "feat(api): approval request decision digest — delayed job, immediate send, mail"
```

---

### Task 14: C-3 — decisions on a request link (`approval_ids[]`)

**Files:**
- Create: `app/Services/Approval/ApprovalRequestDecisionService.php`
- Create: `app/Exceptions/Approval/InvalidApprovalException.php`, `app/Exceptions/Approval/NoteRequiredException.php`
- Modify: `app/Services/Approval/ApprovalService.php` (extract `recordDecision()`, `ownPinsOn()`)
- Modify: `app/Services/Approval/ApprovalNotifier.php` (`requestDeferred()`)
- Modify: `app/Http/Controllers/Api/PublicShareLinkController.php` (`decision()`, new `decideOnRequest()`)
- Test: `tests/Feature/Approval/PublicApprovalRequestDecisionTest.php`

**Interfaces:**
- Consumes: `ApprovalService::resolve()` (P0a FR-3, unchanged), `ApprovalRequestService::recalculate()`, `SendApprovalRequestDigest::schedule()`, `ApprovalRequestDigest::sendNow()`, `ApprovalRequestPresenter::publicPayload()`, `Approval::successorsOf()`.
- Produces:
  - `ApprovalService::recordDecision(Approval $locked, ApprovalActor $actor, string $outcome, ?string $note, array $pins, ?string $ip, bool $agency = false, ?CarbonInterface $deferredUntil = null): ApprovalDecision`.
  - `ApprovalService::ownPinsOn(Approval $approval, ApprovalActor $actor, array $candidates): list<string>`.
  - `ApprovalRequestDecisionService::decide(ApprovalRequest $request, ApprovalActor $actor, array $input, ?string $ip = null): array{results: list<array{approval_id: string, result: 'decided'|'skipped_closed'|'skipped_replaced', decision: ApprovalDecision|null}>, request: ApprovalRequest}`.
  - `InvalidApprovalException::CODE = 'invalid_approval'`, `NoteRequiredException::CODE = 'note_required'`.
  - `ApprovalNotifier::requestDeferred(ApprovalRequest, ApprovalSubject, string $actorName, ?string $note): void`.

- [ ] **Step 1: Write the failing test**

Create `tests/Feature/Approval/PublicApprovalRequestDecisionTest.php`:

```php
<?php

// craftsman-ignore: PHP001 — Pest test files in this repo do not declare
// strict_types.

use App\Jobs\SendApprovalRequestDigest;
use App\Mail\ApprovalDecidedMail;
use App\Mail\ApprovalRequestDigestMail;
use App\Models\ApprovalDecision;
use App\Services\Approval\ApprovalRequestDigest;
use App\Services\Approval\ApprovalRequestService;
use App\Services\Sharing\ShareLinkService;
use App\Models\ShareLink;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Bus;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Mail;
use Tests\Support\ClientLaneFixtures;

beforeEach(function () {
    Mail::fake();
    Bus::fake([SendApprovalRequestDigest::class]);
    $this->kv = ClientLaneFixtures::kvFile();
    $this->file = $this->kv['file'];
    $this->user = $this->kv['user'];
    ClientLaneFixtures::clientRole($this->kv['workspace']);
    $this->board = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Hero board');
    $this->board2 = ClientLaneFixtures::board($this->file, $this->user, 'craft', 'Alt board', 'https://cdn.test/board-2.png');
    $this->tile = ClientLaneFixtures::resizeTile($this->file, $this->user, $this->board);
    foreach ([$this->board, $this->board2] as $board) {
        ClientLaneFixtures::markReady('kv_generation', $board->id, $this->user);
    }
    ClientLaneFixtures::markReady('kv_resize_export', $this->tile->id, $this->user);

    $this->send = fn (?array $phases = null, array $emails = []): array => app(ApprovalRequestService::class)->create($this->file->fresh(), $this->user, $phases, $emails, notify: false);
    $result = ($this->send)();
    $this->request = $result['request'];
    $this->token = $result['share_link']->token;
    $ids = $this->request->approvals()->pluck('id', 'subject_key')->all();
    $this->boardId = $ids["board:{$this->board->id}"];
    $this->board2Id = $ids["board:{$this->board2->id}"];
    $this->tileId = $ids["resize:{$this->tile->id}"];
    $this->boardAnchor = "craft:{$this->board->id}:board";
    $this->tileAnchor = "resize:{$this->tile->id}:tile.{$this->tile->id}";

    $this->guest = ['guest_name' => 'Bayu', 'guest_email' => 'bayu@brand.test'];
    $this->decide = fn (array $body, ?string $token = null) => $this->postJson('/api/public/share-links/'.($token ?? $this->token).'/decision', [...$body, ...$this->guest]);
    $this->pin = fn (string $anchor, array $who = []) => $this->postJson("/api/public/share-links/{$this->token}/comments", [
        'body' => 'Logo smaller',
        'anchor' => ['kind' => 'pin', 'id' => $anchor, 'x' => 0.4, 'y' => 0.4],
        ...($who ?: $this->guest),
    ])->assertCreated()->json('data.id');
});

// Review Focus 3: "Approve all" racing another decider and a re-send.
test('each id gets its own result: decided, skipped_closed, skipped_replaced', function () {
    $tilePin = ($this->pin)($this->tileAnchor);
    ($this->decide)(['outcome' => 'approved', 'approval_ids' => [$this->boardId]])->assertCreated();
    $this->tile->forceFill(['image_url' => 'https://cdn.test/tile-2.png'])->save();
    ($this->send)(['resize']);

    $data = ($this->decide)(['outcome' => 'approved', 'approval_ids' => [$this->boardId, $this->board2Id, $this->tileId], 'pins' => [$tilePin]])
        ->assertCreated()->json('data');

    expect(array_keys($data))->toBe(['results', 'request', 'approvals'])
        ->and(array_column($data['results'], 'approval_id'))->toBe([$this->boardId, $this->board2Id, $this->tileId])
        ->and(array_column($data['results'], 'result'))->toBe(['skipped_closed', 'decided', 'skipped_replaced'])
        ->and($data['results'][0]['decision'])->toBeNull()
        ->and($data['results'][1]['decision'])->toMatchArray(['outcome' => 'approved', 'pins' => []])
        ->and($data['request']['status'])->toBe('approved')
        ->and(collect($data['approvals'])->firstWhere('id', $this->tileId)['replaced'])->toBeTrue();
});

test("approve with the decider's own pin is approved with changes; the other artboard stays approved", function () {
    $pin = ($this->pin)($this->boardAnchor);

    $results = ($this->decide)(['outcome' => 'approved', 'approval_ids' => [$this->boardId, $this->tileId], 'pins' => [$pin]])
        ->assertCreated()->json('data.results');

    expect($results[0]['decision'])->toMatchArray(['outcome' => 'approved_with_changes', 'pins' => [$pin]])
        ->and($results[1]['decision'])->toMatchArray(['outcome' => 'approved', 'pins' => []])
        ->and($this->request->approvals()->whereKey($this->boardId)->value('status'))->toBe('approved_with_changes');
});

test('changes_required needs a note unless every still-open artboard carries a pin', function () {
    $pin = ($this->pin)($this->boardAnchor);

    ($this->decide)(['outcome' => 'changes_required', 'approval_ids' => [$this->boardId, $this->tileId], 'pins' => [$pin]])
        ->assertStatus(422)->assertJson(['code' => 'note_required']);
    expect(ApprovalDecision::query()->count())->toBe(0);

    ($this->decide)(['outcome' => 'changes_required', 'approval_ids' => [$this->boardId], 'pins' => [$pin]])
        ->assertCreated()->assertJsonPath('data.results.0.decision.outcome', 'changes_required');
    ($this->decide)(['outcome' => 'changes_required', 'approval_ids' => [$this->tileId], 'note' => 'Crop the head less'])
        ->assertCreated()->assertJsonPath('data.results.0.decision.note', 'Crop the head less');
});

test("a pin on no artboard of the post, or someone else's pin, is refused", function () {
    $tilePin = ($this->pin)($this->tileAnchor);
    $dinasPin = ($this->pin)($this->boardAnchor, ['guest_name' => 'Dina', 'guest_email' => 'dina@brand.test']);

    ($this->decide)(['outcome' => 'approved', 'approval_ids' => [$this->boardId], 'pins' => [$tilePin]])
        ->assertUnprocessable()->assertJsonValidationErrors('pins');
    ($this->decide)(['outcome' => 'approved', 'approval_ids' => [$this->boardId], 'pins' => [$dinasPin]])
        ->assertUnprocessable()->assertJsonValidationErrors('pins');
    expect(ApprovalDecision::query()->count())->toBe(0);
});

test('a foreign id, an approved_with_changes outcome and a missing or misplaced approval_ids are refused', function () {
    $this->tile->forceFill(['image_url' => 'https://cdn.test/tile-2.png'])->save();
    $foreign = ($this->send)(['resize'])['request']->approvals()->sole()->id;

    ($this->decide)(['outcome' => 'approved', 'approval_ids' => [$this->boardId, $foreign]])
        ->assertStatus(422)->assertJson(['code' => 'invalid_approval']);
    ($this->decide)(['outcome' => 'approved_with_changes', 'note' => 'n', 'approval_ids' => [$this->boardId]])
        ->assertUnprocessable()->assertJsonValidationErrors('outcome');
    ($this->decide)(['outcome' => 'approved'])
        ->assertUnprocessable()->assertJsonValidationErrors('approval_ids');
    ($this->decide)(['outcome' => 'deferred', 'deferred_until' => now()->addDays(2)->toDateString(), 'approval_ids' => [$this->boardId]])
        ->assertUnprocessable()->assertJsonValidationErrors('approval_ids');
    expect(ApprovalDecision::query()->count())->toBe(0);
});

test('under required policy a guest decision is advisory and settles nothing', function () {
    $fx = ClientLaneFixtures::kvFile();
    ClientLaneFixtures::clientRole($fx['workspace']);
    $board = ClientLaneFixtures::board($fx['file'], $fx['user']);
    ClientLaneFixtures::markReady('kv_generation', $board->id, $fx['user']);
    $result = app(ApprovalRequestService::class)->create($fx['file']->fresh(), $fx['user'], null, ['dina@brand.test'], notify: false);
    $id = $result['request']->approvals()->sole()->id;

    $data = ($this->decide)(['outcome' => 'approved', 'approval_ids' => [$id]], $result['share_link']->token)->assertCreated()->json('data');

    expect($data['results'][0])->toMatchArray(['result' => 'decided'])
        ->and($data['results'][0]['decision']['advisory'])->toBeTrue()
        ->and($data['approvals'][0]['status'])->toBe('pending')
        ->and($data['request']['status'])->toBe('pending');
});

test('deferred is request-level: no decision row, the deadline moves, the requester hears at once', function () {
    $until = now()->addDays(3)->toDateString();

    $data = ($this->decide)(['outcome' => 'deferred', 'deferred_until' => $until, 'note' => 'Back on Monday'])
        ->assertCreated()->json('data');

    expect($data['results'])->toBe([])
        ->and(Carbon::parse($data['request']['deferred_until'])->timezone(config('app.timezone'))->toDateString())->toBe($until)
        ->and($data['request']['deferred_note'])->toBe('Back on Monday')
        ->and(ApprovalDecision::query()->count())->toBe(0);
    Mail::assertQueued(ApprovalDecidedMail::class, fn (ApprovalDecidedMail $mail): bool => $mail->headline === 'Bayu asked for more time'
        && $mail->versionLabel === 'Request 1');
    Bus::assertNotDispatched(SendApprovalRequestDigest::class);

    ($this->decide)(['outcome' => 'deferred', 'deferred_until' => now()->addDays(15)->toDateString()])
        ->assertUnprocessable()->assertJsonValidationErrors('deferred_until');
});

test('every decision stamps the request and schedules a digest fifteen minutes out', function () {
    Carbon::setTestNow('2026-10-01 10:00:00');

    ($this->decide)(['outcome' => 'approved', 'approval_ids' => [$this->boardId]])->assertCreated();

    $stamped = $this->request->fresh()->last_decision_at;
    expect($stamped->equalTo(now()))->toBeTrue();
    Bus::assertDispatched(SendApprovalRequestDigest::class, fn (SendApprovalRequestDigest $job): bool => $job->requestId === $this->request->id
        && $job->queue === 'default'
        && $job->delay->equalTo(now()->addMinutes(15))
        && $job->stamp === $stamped->toIso8601String());
    Mail::assertNotQueued(ApprovalRequestDigestMail::class);

    Carbon::setTestNow();
});

test('the digest goes out at once when the last artboard is decided, and the later job adds nothing', function () {
    ($this->decide)(['outcome' => 'approved', 'approval_ids' => [$this->boardId, $this->board2Id, $this->tileId]])
        ->assertCreated()->assertJsonPath('data.request.status', 'approved');

    Mail::assertQueued(ApprovalRequestDigestMail::class, 1);

    Bus::dispatched(SendApprovalRequestDigest::class)->first()->handle(app(ApprovalRequestDigest::class));
    Mail::assertQueued(ApprovalRequestDigestMail::class, 1);
});

test('a withdrawn request answers round_closed; approval_ids on another link is refused', function () {
    app(ApprovalRequestService::class)->withdraw($this->request);
    ($this->decide)(['outcome' => 'approved', 'approval_ids' => [$this->boardId]])
        ->assertStatus(409)->assertJson(['code' => 'round_closed']);

    $view = app(ShareLinkService::class)->create($this->file, $this->user, ['craft'], role: ShareLink::ROLE_COMMENT);
    ($this->decide)(['outcome' => 'approved', 'approval_ids' => [$this->boardId]], $view->token)
        ->assertUnprocessable()->assertJsonValidationErrors('approval_ids');
});

// Review Focus 5, decision side.
test('a request decision pin counts even when the app and the database disagree on the timezone', function () {
    config(['app.timezone' => 'Asia/Jakarta']);
    date_default_timezone_set('Asia/Jakarta');
    DB::statement("SET TIME ZONE 'UTC'");

    $fx = ClientLaneFixtures::kvFile();
    $board = ClientLaneFixtures::board($fx['file'], $fx['user']);
    ClientLaneFixtures::markReady('kv_generation', $board->id, $fx['user']);
    $result = ClientLaneFixtures::sendRequest($fx['file'], $fx['user']);
    $token = $result['share_link']->token;
    $id = $result['request']->approvals()->sole()->id;
    $pin = $this->postJson("/api/public/share-links/{$token}/comments", [
        'body' => 'Logo smaller',
        'anchor' => ['kind' => 'pin', 'id' => "craft:{$board->id}:board", 'x' => 0.3, 'y' => 0.3],
        ...$this->guest,
    ])->assertCreated()->json('data.id');

    ($this->decide)(['outcome' => 'changes_required', 'approval_ids' => [$id], 'pins' => [$pin]], $token)
        ->assertCreated()->assertJsonPath('data.results.0.decision.pins', [$pin]);
});
```

- [ ] **Step 2: Run — expect FAIL**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && ls bootstrap/cache/config.php 2>/dev/null; DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/PublicApprovalRequestDecisionTest.php --compact
```
Expected: FAIL — every decision on the approval link answers `409 round_closed` (the P0a path finds no round on it).

- [ ] **Step 3: Exceptions**

`app/Exceptions/Approval/InvalidApprovalException.php`:

```php
<?php

declare(strict_types=1);

namespace App\Exceptions\Approval;

use RuntimeException;

/**
 * A request-link decision named an id that is not an approval of that
 * request — `422 { code: "invalid_approval" }`, nothing recorded (KV
 * approval requests ruling R6).
 */
final class InvalidApprovalException extends RuntimeException
{
    public const CODE = 'invalid_approval';

    public function __construct()
    {
        parent::__construct('One or more of those artboards are not in this request.');
    }
}
```

`app/Exceptions/Approval/NoteRequiredException.php`:

```php
<?php

declare(strict_types=1);

namespace App\Exceptions\Approval;

use RuntimeException;

/**
 * "Request new version" on an artboard with neither a pin nor a note —
 * `422 { code: "note_required" }` (KV approval requests §4.6 C-3).
 */
final class NoteRequiredException extends RuntimeException
{
    public const CODE = 'note_required';

    public function __construct()
    {
        parent::__construct('Tell us what should change, or pin it on the artboard.');
    }
}
```

- [ ] **Step 4: `ApprovalService` — share recording and pin matching**

In `app/Services/Approval/ApprovalService.php` add `use Carbon\CarbonInterface;` and:

1. Inside `decide()`'s transaction closure, replace everything from `$pins = $this->validatePins(…);` through `return $decision;` with:

```php
            $pins = $this->validatePins($locked, $actor, $input['pins'] ?? []);
            $note = isset($input['note']) && trim((string) $input['note']) !== '' ? trim((string) $input['note']) : null;
            $deferredUntil = $outcome === ApprovalDecision::OUTCOME_DEFERRED && ! empty($input['deferred_until'])
                ? now()->parse((string) $input['deferred_until'])->endOfDay()
                : null;

            return $this->recordDecision($locked, $actor, $outcome, $note, $pins, $ip, $agency, $deferredUntil);
```
2. Add after `decide()`:

```php
    /**
     * Insert one actor's decision on an approval the caller has LOCKED and
     * run FR-3 resolution (a deferral only mirrors its date). Shared by the
     * P0a round path ({@see decide()}) and KV approval requests
     * ({@see ApprovalRequestDecisionService}), so both record and resolve
     * the same way.
     *
     * @param  list<string>  $pins  already checked to be the actor's own, on this approval
     */
    public function recordDecision(
        Approval $locked,
        ApprovalActor $actor,
        string $outcome,
        ?string $note,
        array $pins,
        ?string $ip,
        bool $agency = false,
        ?CarbonInterface $deferredUntil = null,
    ): ApprovalDecision {
        $decision = ApprovalDecision::create([
            'approval_id' => $locked->id,
            'actor_user_id' => $actor->user?->id,
            'guest_name' => $actor->isUser() ? null : $actor->guestName,
            'guest_email' => $actor->isUser() ? null : $actor->guestEmail,
            'lane_link_id' => $actor->lane?->id,
            'outcome' => $outcome,
            'advisory' => ! $agency && $this->isAdvisory($locked, $actor),
            'note' => $note,
            'pins' => $pins,
            'deferred_until' => $deferredUntil,
            'verified_at' => $actor->lane?->verified_at,
            'ip_hash' => $ip !== null ? hash('sha256', $ip.(string) config('app.key')) : null,
            'decided_at' => now(),
        ]);

        if ($outcome === ApprovalDecision::OUTCOME_DEFERRED) {
            $locked->forceFill([
                'deferred_until' => $decision->deferred_until,
                'deferred_note' => $decision->note,
            ])->save();
        } else {
            $this->resolve($locked, $agency ? $decision : null);
        }

        return $decision;
    }

    /**
     * The candidates that are this actor's own pins on THIS approval's
     * version, placed since it started (C-3; KV approval requests R6) — in
     * candidate order. Ownership keys on `lane_link_id` when the actor has a
     * lane (client lane P0a review #3): a typed `guest_email` alone is not
     * proof; only a lane-less guest falls back to the email-string match.
     *
     * @param  array<int, mixed>  $candidates
     * @return list<string>
     */
    public function ownPinsOn(Approval $approval, ApprovalActor $actor, array $candidates): array
    {
        $candidates = array_values(array_unique(array_filter($candidates, 'is_string')));
        if ($candidates === []) {
            return [];
        }

        // Compared in SQL, never as PHP instants (multi-item final review
        // #3): `comments.created_at` is a naive `timestamp`.
        $rows = Comment::query()
            ->whereIn('id', $candidates)
            ->where('commentable_type', $approval->subject_type)
            ->where('commentable_id', $approval->subject_id)
            ->where('created_at', '>=', $approval->created_at)
            ->get()
            ->keyBy(fn (Comment $comment): string => (string) $comment->id);

        $versionId = (string) $approval->subject_version_id;
        $valid = [];
        foreach ($candidates as $id) {
            $comment = $rows->get($id);
            if ($comment === null) {
                continue;
            }

            $mine = match (true) {
                $actor->isUser() => (string) $comment->author_id === (string) $actor->user->id,
                $actor->lane !== null => $comment->lane_link_id !== null && (int) $comment->lane_link_id === (int) $actor->lane->id,
                default => $comment->author_id === null && $comment->lane_link_id === null
                    && strtolower((string) $comment->guest_email) === (string) $actor->guestEmail,
            };
            $segments = explode(':', (string) (($comment->anchor ?? [])['id'] ?? ''));
            if ($mine && count($segments) >= 2 && $segments[1] === $versionId) {
                $valid[] = (string) $comment->id;
            }
        }

        return $valid;
    }
```
3. Replace `validatePins()` (docblock included) with:

```php
    /**
     * Every pin must be this actor's own comment on the subject, anchored to
     * THIS round's version and placed during this round (C-3).
     *
     * @param  list<string>  $pins
     * @return list<string>
     *
     * @throws ValidationException
     */
    private function validatePins(Approval $approval, ApprovalActor $actor, array $pins): array
    {
        $pins = array_values(array_unique(array_filter($pins, 'is_string')));
        $valid = $this->ownPinsOn($approval, $actor, $pins);

        if (count($valid) !== count($pins)) {
            throw ValidationException::withMessages([
                'pins' => 'One or more pins are not yours or not in this round.',
            ]);
        }

        return $valid;
    }
```

- [ ] **Step 5: Notifier — deferral**

In `app/Services/Approval/ApprovalNotifier.php` add:

```php
    /**
     * "I need more time" on a KV request (spec §4.7 item 4): notifies at
     * once, like a P0a deferral — inbox `approval_decided` plus
     * `ApprovalDecidedMail` to the requester.
     */
    public function requestDeferred(ApprovalRequest $request, ApprovalSubject $subject, string $actorName, ?string $note): void
    {
        $headline = "{$actorName} asked for more time";
        $label = 'Request '.$request->number;
        $targetLabel = "{$subject->title} {$label}";
        $requester = $request->requested_by !== null ? User::find($request->requested_by) : null;

        try {
            $this->notifications->notifyUsers(
                $this->audience((string) $request->brand_id, (string) $request->workspace_id, $requester),
                'approval_decided',
                "{$headline} — {$targetLabel}",
                $note ?: $headline,
                $subject->editorPath,
                $request->workspace_id,
                Kind::ApprovalDecided->value,
                null,
                null,
                $targetLabel,
            );
        } catch (\Throwable $e) {
            Log::warning('ApprovalNotifier: inbox fan-out failed on request deferral', ['approval_request_id' => $request->id, 'error' => $e->getMessage()]);
        }

        if ($requester === null || ! filled($requester->email)) {
            return;
        }

        try {
            Mail::to($requester->email)->queue(new ApprovalDecidedMail(
                headline: $headline,
                title: $subject->title,
                versionLabel: $label,
                brandName: (string) ($subject->brand()?->name ?? ''),
                note: $note,
                pinCount: 0,
                editorUrl: rtrim((string) config('app.frontend_url'), '/').$subject->editorPath,
            ));
        } catch (\Throwable $e) {
            Log::warning('ApprovalNotifier: ApprovalDecidedMail failed on request deferral', ['approval_request_id' => $request->id, 'error' => $e->getMessage()]);
        }
    }
```

- [ ] **Step 6: The decision service**

Create `app/Services/Approval/ApprovalRequestDecisionService.php`:

```php
<?php

declare(strict_types=1);

namespace App\Services\Approval;

// craftsman-ignore: PHP002 — resolved from the container and swapped in tests.

use App\Exceptions\Approval\ApprovalRoundClosedException;
use App\Exceptions\Approval\InvalidApprovalException;
use App\Exceptions\Approval\NoteRequiredException;
use App\Jobs\SendApprovalRequestDigest;
use App\Models\Approval;
use App\Models\ApprovalDecision;
use App\Models\ApprovalRequest;
use Illuminate\Support\Facades\DB;
use Illuminate\Validation\ValidationException;

/**
 * C-3 on a KV approval-request link (spec §4.6, rulings R5–R7): one post
 * decides 1..50 artboards. Each still-pending id gets a decision through
 * the P0a recorder and FR-3 resolution; closed and replaced ids are
 * skipped, each with its own result. Everything is checked before anything
 * is written. Every decision stamps the request and schedules the digest;
 * leaving `pending` sends it at once (§4.7).
 */
class ApprovalRequestDecisionService
{
    public function __construct(
        private readonly ApprovalService $approvals,
        private readonly ApprovalRequestService $requests,
        private readonly ApprovalRequestDigest $digest,
        private readonly ApprovalNotifier $notifier,
    ) {}

    /**
     * @param  array{outcome: string, approval_ids?: list<string>|null, note?: string|null, pins?: list<string>|null, deferred_until?: string|null}  $input
     * @return array{results: list<array{approval_id: string, result: string, decision: ApprovalDecision|null}>, request: ApprovalRequest}
     *
     * @throws ApprovalRoundClosedException the request is not_relevant (or, to defer, not pending)
     * @throws InvalidApprovalException
     * @throws NoteRequiredException
     * @throws ValidationException `pins`
     */
    public function decide(ApprovalRequest $request, ApprovalActor $actor, array $input, ?string $ip = null): array
    {
        $outcome = (string) $input['outcome'];
        $note = isset($input['note']) && trim((string) $input['note']) !== '' ? trim((string) $input['note']) : null;

        if ($outcome === ApprovalDecision::OUTCOME_DEFERRED) {
            return ['results' => [], 'request' => $this->defer($request, $actor, $note, (string) $input['deferred_until'])];
        }

        $ids = array_values(array_unique(array_map('strval', $input['approval_ids'] ?? [])));
        $pins = array_values(array_unique(array_filter($input['pins'] ?? [], 'is_string')));

        [$results, $decidedAny, $completed, $locked] = DB::transaction(function () use ($request, $actor, $outcome, $note, $ids, $pins, $ip): array {
            /** @var ApprovalRequest $locked */
            $locked = ApprovalRequest::query()->lockForUpdate()->findOrFail($request->id);
            if ($locked->status === Approval::STATUS_NOT_RELEVANT) {
                throw new ApprovalRoundClosedException;
            }

            $approvals = Approval::query()
                ->where('approval_request_id', $locked->id)
                ->whereIn('id', $ids)
                ->orderBy('id')
                ->lockForUpdate()
                ->get()
                ->keyBy(fn (Approval $approval): string => (string) $approval->id);
            if ($approvals->count() !== count($ids)) {
                throw new InvalidApprovalException;
            }
            $replaced = Approval::successorsOf($approvals);

            // R6: pins matched per approval; nothing is written until every
            // check below has passed.
            $pinsFor = [];
            $matched = [];
            foreach ($ids as $id) {
                $pinsFor[$id] = $this->approvals->ownPinsOn($approvals[$id], $actor, $pins);
                array_push($matched, ...$pinsFor[$id]);
            }
            if (array_diff($pins, $matched) !== []) {
                throw ValidationException::withMessages(['pins' => 'One or more pins are not yours or not on these artboards.']);
            }
            if ($outcome === ApprovalDecision::OUTCOME_CHANGES_REQUIRED && $note === null) {
                foreach ($ids as $id) {
                    if ($approvals[$id]->isPending() && $pinsFor[$id] === []) {
                        throw new NoteRequiredException;
                    }
                }
            }

            $wasPending = $locked->isPending();
            $results = [];
            $decidedAny = false;
            foreach ($ids as $id) {
                $approval = $approvals[$id];
                if (! $approval->isPending()) {
                    $results[] = [
                        'approval_id' => $id,
                        'result' => $replaced->has($id) ? 'skipped_replaced' : 'skipped_closed',
                        'decision' => null,
                    ];

                    continue;
                }

                // Spec D-5: "Approve" with this decider's pins on the artboard
                // is stored as approved_with_changes.
                $stored = $outcome === ApprovalDecision::OUTCOME_APPROVED && $pinsFor[$id] !== []
                    ? ApprovalDecision::OUTCOME_APPROVED_WITH_CHANGES
                    : $outcome;
                $results[] = [
                    'approval_id' => $id,
                    'result' => 'decided',
                    'decision' => $this->approvals->recordDecision($approval, $actor, $stored, $note, $pinsFor[$id], $ip),
                ];
                $decidedAny = true;
            }

            if ($decidedAny) {
                $this->requests->recalculate($locked);
                $locked->forceFill(['last_decision_at' => now()])->save();
            }

            return [$results, $decidedAny, $wasPending && ! $locked->isPending(), $locked];
        });

        if ($decidedAny) {
            SendApprovalRequestDigest::schedule($locked->fresh());
        }
        if ($completed) {
            $this->digest->sendNow((string) $locked->id);
        }

        return ['results' => $results, 'request' => $locked->fresh()];
    }

    /**
     * "I need more time" for the whole request (spec D-6, ruling R5): no
     * decision row; the request's deadline moves and the requester hears at
     * once.
     *
     * @throws ApprovalRoundClosedException the request is not pending
     */
    private function defer(ApprovalRequest $request, ApprovalActor $actor, ?string $note, string $until): ApprovalRequest
    {
        $locked = DB::transaction(function () use ($request, $note, $until): ApprovalRequest {
            /** @var ApprovalRequest $locked */
            $locked = ApprovalRequest::query()->lockForUpdate()->findOrFail($request->id);
            if (! $locked->isPending()) {
                throw new ApprovalRoundClosedException;
            }

            $locked->forceFill([
                'deferred_until' => now()->parse($until)->endOfDay(),
                'deferred_note' => $note,
            ])->save();

            return $locked;
        });

        $subject = ApprovalSubject::find((string) $locked->subject_type, (string) $locked->subject_id);
        if ($subject !== null) {
            $this->notifier->requestDeferred($locked, $subject, $actor->name(), $note);
        }

        return $locked->fresh();
    }
}
```

- [ ] **Step 7: Controller — `decision()` branches on the link's purpose**

In `app/Http/Controllers/Api/PublicShareLinkController.php` add imports `App\Exceptions\Approval\InvalidApprovalException`, `App\Exceptions\Approval\NoteRequiredException`, `App\Services\Approval\ApprovalRequestDecisionService`, `App\Services\Approval\ApprovalRequestService`, `Illuminate\Support\Facades\Validator`; add `private readonly ApprovalRequestDecisionService $requestDecisions,` to the constructor; and replace `decision()` with:

```php
    public function decision(Request $request, string $token): JsonResponse
    {
        // Body validated BEFORE any DB read (C-3). An approval link takes
        // `changes_required` with pins and no note (KV approval requests
        // §4.6) — its own note rule runs in the service.
        $validated = $request->validate([
            'outcome' => ['required', 'string', Rule::in(ApprovalDecision::OUTCOMES)],
            'note' => [
                Rule::requiredIf(fn () => ! $request->has('approval_ids') && in_array($request->input('outcome'), [
                    ApprovalDecision::OUTCOME_APPROVED_WITH_CHANGES,
                    ApprovalDecision::OUTCOME_CHANGES_REQUIRED,
                ], true)),
                'nullable', 'string', 'max:2000',
            ],
            'pins' => ['nullable', 'array', 'max:200'],
            'pins.*' => ['string', 'size:26'],
            'deferred_until' => [
                Rule::requiredIf(fn () => $request->input('outcome') === ApprovalDecision::OUTCOME_DEFERRED),
                'nullable', 'date_format:Y-m-d', 'after:today',
                'before_or_equal:'.now()->addDays(ApprovalService::MAX_DEFERRAL_DAYS)->toDateString(),
            ],
            'approval_ids' => ['nullable', 'array', 'min:1', 'max:'.ApprovalRequestService::MAX_ARTBOARDS],
            'approval_ids.*' => ['string', 'size:26', 'distinct'],
            ...self::guestRules(),
        ]);

        $resolved = $this->resolve($request, $token);
        if ($resolved === null) {
            return $this->notFound();
        }
        [$link, $subject, $lane] = $resolved;

        if ($link->role !== ShareLink::ROLE_COMMENT) {
            return $this->error(422, 'read_only_link', 'This link is read-only.');
        }

        if ($link->purpose === ShareLink::PURPOSE_APPROVAL) {
            return $this->decideOnRequest($request, $link, $subject, $lane, $validated);
        }

        if (($validated['approval_ids'] ?? null) !== null) {
            throw ValidationException::withMessages(['approval_ids' => 'This link takes one decision for the whole round.']);
        }

        $approval = $this->currentApproval($link);
        if ($approval === null) {
            return $this->error(409, ApprovalRoundClosedException::CODE, 'This version is no longer open for a decision');
        }

        $actor = $this->actor($lane, $validated);
        if ($actor === null) {
            return $this->error(422, 'guest_required', 'Tell us your name and email first.');
        }

        try {
            $decision = $this->approvals->decide($approval, $actor, $validated, $request->ip());
        } catch (VerificationRequiredException $e) {
            return $this->error(403, VerificationRequiredException::CODE, $e->getMessage());
        } catch (ApprovalRoundClosedException $e) {
            return $this->error(409, ApprovalRoundClosedException::CODE, $e->getMessage());
        }

        $approval->refresh();

        return response()
            ->json(['data' => [
                'decision' => ApprovalPresenter::decision($decision),
                'approval' => ApprovalPresenter::approval($approval),
            ]], 201)
            ->header('Cache-Control', 'no-store');
    }

    /**
     * C-3 on a KV approval-request link (spec §4.6): `approval_ids[]`,
     * per-id results, request-level deferral.
     *
     * @param  array<string, mixed>  $validated
     */
    private function decideOnRequest(Request $request, ShareLink $link, ApprovalSubject $subject, ?ClientLaneLink $lane, array $validated): JsonResponse
    {
        $outcome = (string) $validated['outcome'];
        Validator::make($validated, [
            // R7: approved_with_changes is derived (approve + pins), never sent.
            'outcome' => [Rule::in([
                ApprovalDecision::OUTCOME_APPROVED,
                ApprovalDecision::OUTCOME_CHANGES_REQUIRED,
                ApprovalDecision::OUTCOME_DEFERRED,
            ])],
            'approval_ids' => [
                Rule::requiredIf($outcome !== ApprovalDecision::OUTCOME_DEFERRED),
                Rule::prohibitedIf($outcome === ApprovalDecision::OUTCOME_DEFERRED),
            ],
        ])->validate();

        $approvalRequest = $this->requestFor($link);
        if ($approvalRequest === null) {
            return $this->notFound();
        }

        $actor = $this->actor($lane, $validated);
        if ($actor === null) {
            return $this->error(422, 'guest_required', 'Tell us your name and email first.');
        }

        try {
            $result = $this->requestDecisions->decide($approvalRequest, $actor, $validated, $request->ip());
        } catch (ApprovalRoundClosedException $e) {
            return $this->error(409, ApprovalRoundClosedException::CODE, $e->getMessage());
        } catch (InvalidApprovalException $e) {
            return $this->error(422, InvalidApprovalException::CODE, $e->getMessage());
        } catch (NoteRequiredException $e) {
            return $this->error(422, NoteRequiredException::CODE, $e->getMessage());
        }

        $payload = ApprovalRequestPresenter::publicPayload(
            $result['request'],
            (string) $subject->model->getAttribute('name'),
            (string) ($subject->brand()?->slug ?? ''),
        );

        return response()
            ->json(['data' => [
                'results' => array_map(static fn (array $r): array => [
                    'approval_id' => $r['approval_id'],
                    'result' => $r['result'],
                    'decision' => $r['decision'] !== null ? ApprovalPresenter::decision($r['decision']) : null,
                ], $result['results']),
                'request' => $payload['request'],
                'approvals' => $payload['approvals'],
            ]], 201)
            ->header('Cache-Control', 'no-store');
    }
```

- [ ] **Step 8: Run — expect PASS**

Same command as Step 2. Expected: 11 passed. Then the deck/plan guard and the earlier request files (the recorder moved):

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && for f in tests/Feature/Approval/DeckPlanApprovalRegressionTest.php tests/Feature/Approval/PublicApprovalRequestCommentsTest.php tests/Feature/Approval/ApprovalRequestDigestTest.php; do DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest $f --compact || break; done
```
Expected: 7, 5, 6 passed.

- [ ] **Step 9: Mutation check**

1. `ApprovalRequestDecisionService::decide`: always store `$outcome` (drop the approved-with-pins branch) → *"approve with the decider's own pin…"* must FAIL. Restore.
2. Same: delete the `NoteRequiredException` loop → *"changes_required needs a note…"* must FAIL. Restore.
3. Same: report every non-pending id as `skipped_closed` → *"each id gets its own result…"* must FAIL. Restore.
4. Same: drop `if ($completed) { $this->digest->sendNow(…) }` → *"the digest goes out at once…"* must FAIL. Restore.
5. `ApprovalService::ownPinsOn`: drop the `$segments[1] === $versionId` check → *"a pin on no artboard of the post…"* must FAIL (the tile pin matches the board). Restore.
6. `decideOnRequest`: remove `ApprovalDecision::OUTCOME_APPROVED_WITH_CHANGES`-exclusion by adding it to the `Rule::in` list → *"a foreign id, an approved_with_changes outcome…"* must FAIL. Restore.

Re-run Step 2's command: 11 passed.

- [ ] **Step 10: Lint + commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && F="app/Services/Approval/ApprovalRequestDecisionService.php app/Exceptions/Approval/InvalidApprovalException.php app/Exceptions/Approval/NoteRequiredException.php app/Services/Approval/ApprovalService.php app/Services/Approval/ApprovalNotifier.php app/Http/Controllers/Api/PublicShareLinkController.php tests/Feature/Approval/PublicApprovalRequestDecisionTest.php"; for f in ${=F}; do php -l "$f"; done && vendor/bin/pint ${=F} && vendor/bin/pint --test ${=F} && /usr/bin/git add ${=F} && /usr/bin/git commit -m "feat(api): decide artboards on a request link — per-id results, pins per artboard, request-level deferral, digest"
```

---
### Task 15: Final gates and track file

**Files:**
- Modify: `docs/tracks/client-lane-multi-item.track.md`

**Interfaces:**
- Consumes: everything above.
- Produces: a green branch ready for review, and the updated track file.

- [ ] **Step 1: Static gates**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && /usr/bin/git diff --name-only --diff-filter=d develop...HEAD -- '*.php' | xargs -n1 php -l | /usr/bin/grep -v "^No syntax errors" ; vendor/bin/pint --test $(/usr/bin/git diff --name-only --diff-filter=d develop...HEAD -- '*.php')
```
Expected: no `php -l` output beyond the filtered lines; pint passes.

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && php artisan route:list --path=approval && php artisan route:list --path=public/share-links && /usr/bin/grep -rn "ApprovalItem\|approval_items\|itemVersionIds\|FrozenItem\|kv_ready_item_id" app routes database tests/Support tests/Feature/Approval
```
Expected: `approvals.index|store|withdraw|resend` and `approval-requests.preview|index|store|withdraw|resend`; the four `public/share-links/{token}…` routes unchanged; the grep prints nothing (the deleted migrations are gone from `database/`).

- [ ] **Step 2: Every new test file in one process, then the regression suites**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && ls bootstrap/cache/config.php 2>/dev/null; DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest tests/Feature/Approval/ApprovalRequestSchemaTest.php tests/Feature/Approval/DeckPlanApprovalRegressionTest.php tests/Feature/Approval/KvArtboardKeyTest.php tests/Unit/Approval/ApprovalRequestRollupTest.php tests/Feature/Approval/ApprovalRequestPreviewTest.php tests/Feature/Approval/ShareLinkPurposeTest.php tests/Feature/Approval/ApprovalRequestCreateTest.php tests/Feature/Approval/ApprovalRequestControllerTest.php tests/Feature/Approval/ApprovalRequestRevokeTest.php tests/Feature/Approval/PublicApprovalRequestLinkTest.php tests/Feature/Approval/PublicApprovalRequestCommentsTest.php tests/Feature/Approval/ApprovalRequestDigestTest.php tests/Feature/Approval/PublicApprovalRequestDecisionTest.php tests/Feature/Approval/KvSharePayloadItemsForTest.php --compact
```
Expected: all pass (7 + 7 + 8 + 9 + 8 + 5 + 8 + 9 + 5 + 6 + 5 + 6 + 11 + 3 = 97).

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && for f in tests/Feature/Studio/KvShareLinkTest.php tests/Feature/Deck/DeckShareLinkTest.php tests/Feature/CampaignPlan/CampaignPlanCrudTest.php tests/Unit/CampaignPlan/PlanApprovalTest.php tests/Unit/CampaignPlan/LifecycleStageTest.php; do DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest $f --compact; done
```
Expected: the 2026-09-30 counts (KvShareLinkTest 76/76, DeckShareLinkTest 21/21, CampaignPlanCrudTest 17/17, PlanApprovalTest 21/21, LifecycleStageTest 25/25). A new failure is this branch's; fix it before the commit.

- [ ] **Step 3: Update the track file**

In `docs/tracks/client-lane-multi-item.track.md`:

1. Frontmatter: `prd: client-lane-kv-approval-requests`, `parent_prd: docs/superpowers/specs/2026-10-01-client-lane-kv-approval-requests-design.md`; keep `branch`, `pr_url: null`, `status: in_progress`.
2. Replace the title and the intro lines above `## Status` with:

```markdown
# Track — Client Lane KV approval requests, Part A (api)

Supersedes the 2026-09-30 multi-item rounds on this branch (spec 2026-10-01 D-3: `approval_items` removed, never shipped).
Plan: `docs/superpowers/plans/2026-10-01-client-lane-kv-approval-requests-api.md` (workspace root). Previous plan: `docs/superpowers/plans/2026-09-30-client-lane-multi-item-api.md`.
Contract: "Additive notes (KV approval requests …)" in `docs/prd/client-lane-p0a/api.md` (byte-identical copy in web) — awaiting Jeff's review.
Tests: `DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false vendor/bin/pest <file> --compact` — file paths only, one process at a time. Permission: Daffa, once, for the files the plan names (Task 0).
```
3. Status table: `PRD | spec 2026-10-01 approved in chat; contract notes pending Jeff`, `Service PRD | contract notes rewritten for requests`, `Implementation | completed (api, Part A)`, `PR | not_submitted`.
4. Replace the Task Checklist with:

```markdown
- [x] TASK-0: Pre-flight — permission, branch, caches, scratch DB
- [x] TASK-1: Contract notes rewritten for approval requests (+ name map for the guide)
- [x] TASK-2: `approval_requests`, request columns + expression unique index on `approvals`, `share_links.purpose`
- [x] TASK-3: `approval_items` removed; decks/plans one version per round; KV refused on `v1/approvals`; `PinWindow`
- [x] TASK-4: artboard key, `KvArtboard` (fingerprint), resolver
- [x] TASK-5: request roll-up (pure)
- [x] TASK-6: preview — eligible / already approved / waiting
- [x] TASK-7: approval-purpose links outside the cap, the panel and the legacy token
- [x] TASK-8: send a request — supersede same artboard only, own link, lanes, mail
- [x] TASK-9: `v1/approval-requests` — preview, send, list, withdraw, resend
- [x] TASK-10: revoke withdraws requests; rotate points at request links
- [x] TASK-11: C-1 serves the request
- [x] TASK-12: C-4 pins/comments per artboard approval
- [x] TASK-13: decision digest — job, immediate send, mail
- [x] TASK-14: C-3 `approval_ids[]` — per-id results, pins per artboard, request-level deferral
- [x] TASK-15: gates + this file
- [ ] TASK-16: dev DB migration (asks Daffa)
```
5. APPEND (never delete earlier entries) to `## Session Log`:

```markdown
### 2026-10-01 — daffa (plan executor) — KV approval requests, Part A (api)
- Implemented TASK-0 … TASK-15 per the plan; new and kept Approval test files green on `frnd_testing` (fill in: N passed, M assertions); every task mutation-checked.
- Regression: (fill in the five suites' counts; note any pre-existing failure seen on develop too).
- Rulings R1–R18 are in the plan and the contract notes; the ones Jeff should see: R1/R2 (same version = id + artwork; waiting artboards are not re-offered), R12 (approval links are not view links), spec §9 Q1 (board key) and Q4 (revoke withdraws).
- Deviations from the plan: (fill in, or "none").
- NOT done: dev DB `frnd` migration (TASK-16, asks Daffa); PR (awaits Jeff's ack); Parts B, C, D (own plans).
```
Fill in the bracketed parts with real numbers and anything that deviated.

- [ ] **Step 4: Commit**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && /usr/bin/git add docs/tracks/client-lane-multi-item.track.md && /usr/bin/git commit -m "docs(api): track file for KV approval requests, Part A" && /usr/bin/git log --oneline a0c1dc49d..HEAD
```
Expected: 15 commits (Tasks 1–15; Task 0 commits nothing). Do not push or open a PR. If the route cache was moved aside in any task, tell Daffa it is gone (do not restore it).

- [ ] **Step 5: Hand the contract block to the web plan**

Tell Daffa / the web plan executor: the block under "### Additive notes (KV approval requests …)" in `docs/prd/client-lane-p0a/api.md` (Task 1) must be copied byte-identically into `web/docs/prd/client-lane-p0a/web.md`, replacing web's multi-item notes. Verify with:

```bash
diff <(sed -n '/^### Additive notes (KV approval requests/,/^## Scope/p' /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item/docs/prd/client-lane-p0a/api.md) <(sed -n '/^### Additive notes (KV approval requests/,/^## Scope/p' <path to the web worktree>/docs/prd/client-lane-p0a/web.md)
```
Expected (once web lands its copy): no output.

---

### Task 16: Dev DB migration (ask first)

**Files:** none changed in git.

**Interfaces:**
- Consumes: the worktree `.env` (points at the dev DB `frnd`); the deleted migrations as they were at `a0c1dc49d`.
- Produces: the dev DB with `approval_requests`, the new `approvals` columns/index and `share_links.purpose`, and without `approval_items`.

- [ ] **Step 1: Ask**

AskUserQuestion: "Migrate the dev DB `frnd` for KV approval requests now? Steps: (1) read which `2026_09_30_120*` migrations ran; (2) if they ran, roll them back from copies of the deleted files (drops `approval_items` and `approval_decisions.approval_item_id`); (3) run ONLY the three `2026_10_01_10*` migrations with `--path`, `TELESCOPE_ENABLED=false`. The dev server on :9191 serves the main `api/` checkout, which does not know these tables yet — it keeps working (deck/plan rows still unique per round)." Options "Yes, migrate" / "Not now". On "Not now": stop; leave TASK-16 unchecked.

- [ ] **Step 2: Read the state**

```bash
psql -d frnd -Atc "select migration, batch from migrations where migration like '2026_09_30_120%' or migration like '2026_10_01_10%' order by id" ; psql -d frnd -Atc "select max(batch) from migrations"; psql -d frnd -Atc "select to_regclass('public.approval_items'), (select count(*) from approvals)"
```
Expected on 2026-10-01: either no `2026_09_30_120*` rows (they never ran — skip to Step 4) or three rows; `approvals` count 0 (spec D-3). If `approvals` is not empty, STOP and show Daffa the count.

- [ ] **Step 3: Roll back the old three (only if Step 2 listed them)**

```bash
mkdir -p /private/tmp/claude-501/approval-items-rollback && cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && for f in 2026_09_30_120000_create_approval_items_table 2026_09_30_120100_add_approval_item_id_to_approval_decisions 2026_09_30_120200_backfill_approval_items; do /usr/bin/git show a0c1dc49d:database/migrations/$f.php > /private/tmp/claude-501/approval-items-rollback/$f.php; done && ls /private/tmp/claude-501/approval-items-rollback
```
If the three rows share the newest batch from Step 2 and nothing else is in that batch:

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && ls bootstrap/cache/config.php 2>/dev/null; TELESCOPE_ENABLED=false php artisan migrate:rollback --path=/private/tmp/claude-501/approval-items-rollback --realpath
```
Expected: the three `…120200`, `…120100`, `…120000` rolled back. If they are NOT alone in the newest batch, STOP and ask Daffa before anything else (a plain rollback would also undo the other migrations of that batch).

- [ ] **Step 4: Migrate only the new three**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-lane-multi-item && TELESCOPE_ENABLED=false php artisan migrate --path=database/migrations/2026_10_01_100000_create_approval_requests_table.php --path=database/migrations/2026_10_01_100100_add_request_columns_to_approvals.php --path=database/migrations/2026_10_01_100200_add_purpose_to_share_links.php
```

- [ ] **Step 5: Verify**

```bash
psql -d frnd -Atc "select to_regclass('public.approval_requests'), to_regclass('public.approval_items')" ; psql -d frnd -Atc "select indexname from pg_indexes where tablename = 'approvals' and indexname like '%round%'" ; psql -d frnd -Atc "select purpose, count(*) from share_links group by purpose"
```
Expected: `approval_requests` exists, `approval_items` is null; only `approvals_subject_key_round_unique`; every link `share`. Tick TASK-16 in the track file, add one Session Log line ("dev DB migrated 2026-10-01: …"), and commit with `docs(api): track — dev DB migrated for KV approval requests`.

---

## Spec coverage (self-review)

| Spec | Task |
|---|---|
| §4.1 `approval_requests` table | 2 |
| §4.1 `approvals` new columns, copied policy/approvers, null message/link/sent on KV rows | 2, 8 |
| §4.1 unique swap to `(subject_type, subject_id, COALESCE(subject_key,''), round)` | 2 |
| §4.1 `approval_decisions` unchanged, `approval_item_id` removed; `share_links.purpose` | 2, 3 |
| §4.1 delete `2026_09_30_120*`, model, backfill, all item code | 3 |
| §4.2 artboard key (board chain root, resize row, motion project:ratio) | 4 |
| §4.3 one pending per artboard, supersede same key only, other request stays open | 8 |
| §4.3 per-approval FR-3 resolution, advisory never settles | 3 (resolve kept), 14 |
| §4.3 roll-up rows 1–5 | 5, 8 (`recalculate`) |
| §4.3 withdraw; revoke withdraws (listener extended) | 9, 10 |
| §4.4 own link per request, outside MAX_ACTIVE_LINKS and the KV index, shows its request forever | 7, 8, 11 |
| §4.5 preview (eligibility, approved-on-same-version, `replaces`) | 6, 9 |
| §4.5 POST (freeze, supersede, link, lanes, mail label), errors | 8, 9 |
| §4.5 GET list (AgencyRequest incl. counts, personal_url, share_link_active, pin_count, superseded_by_request_number) | 9 |
| §4.5 withdraw / resend | 9 |
| §4.5 `POST v1/approvals` kv_file → `use_approval_requests`; GET legacy only | 3 |
| §4.6 C-1 for approval links (`request`, `approvals`, document from snapshots, `approval: null`, items/version compat) | 11 |
| §4.6 C-3 (`approval_ids`, per-id results, approve+pins → awc, `note_required`, deferred request-level, advisory, pins per approval) | 14 |
| §4.6 C-4 (new pins on request versions, `created_at >=` per approval) | 12 |
| §4.7 digest (15-min job, stamp skip, immediate on completion, deferred immediate, content) | 13, 14 |
| §4.8 contract notes + name map, byte-identical with web | 1, 15 |
| §8 api tests for Part A (model, request, roll-up, link, public decision, digest) | 2–14 |
| §10 carry-over (snapshots, pins by round per approval, revoke event, personal_url/share_link_active, magic-link copy) | 3, 4, 9, 10, 12 |
| Parts B, C, D; §5 web; §11 UI | out of scope (web plan / later plans) |
