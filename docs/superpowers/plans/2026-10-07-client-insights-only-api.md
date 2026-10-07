# Client "Insights only" access — api Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the client access level `insights_only`. These clients see only portal Insights. Approvals are closed server-side, and naming them as an approver auto-upgrades them to `own`.

**Architecture:** One new value in the existing `workspace_external_invites.access_level` (CHECK constraint + `ClientLaneLink` constants). Every place that branches on the level learns the new value:
- the inbox (`ClientPortalInbox`, `PortalController::approvals`);
- decisions (`PublicShareLinkController::decisionRefusal`);
- approver provisioning (`ClientLaneService::provisionApprovers`);
- the invite mail.

**Tech Stack:** Laravel 13, PHP 8.5, PostgreSQL, Pest 4.

**Spec:** `docs/superpowers/specs/2026-10-07-client-insights-only-access-design.md` (workspace repo).

## Global Constraints

- **Repo and branch:**
  - Work in `/Users/alva.e202511001/Desktop/work/frndos-agentic/api/.worktrees/client-portal` (currently detached at develop).
  - First run `git fetch origin develop && git switch -c feature/daffa/vc-client-insights-only origin/develop`.
- **Git:**
  - Commits: `feat(api): …` / `test(api): …`, NO Co-Authored-By trailer.
  - NEVER push, never open a PR, never stash, never force.
- **Formatting:** run `vendor/bin/pint --dirty --format agent` before each commit.
- **Pest, scratch DB only:**
  - First confirm `bootstrap/cache/config.php` is absent.
  - Command: `DB_CONNECTION=pgsql DB_HOST=localhost DB_PORT=5432 DB_DATABASE=frnd_testing TELESCOPE_ENABLED=false php -d memory_limit=3G vendor/bin/pest <paths> --compact`.
  - Baseline, which must stay green: `tests/Feature/ClientPortal tests/Feature/Approval tests/Feature/Share`.
- **Fixture traps:**
  - `HasWorkspaceScope` stamps new models with the signed-in user's workspace, so build "other workspace" fixtures before `ClientLaneFixtures::actAsAgency`.
  - Helpers are in `tests/Support/ClientLaneFixtures.php` (`namedClient`, `session(User, ?ClientLaneLink)`, `deck`, `brandedPlan`).
- **Value and label:** the value is exactly `insights_only`; the label (web) is "Insights only".
- **Response field:** `access_upgraded` is always present on the request-create and round-create 201 bodies: `list<array{email: string, name: string}>`, `[]` when nobody was upgraded.

## Review Focus

1. A client is `insights_only` on brand A and `own` on brand B. Brand B's inbox and decisions must be unaffected (levels are per lane).
2. An `insights_only` client holding an OLD request link (named before the downgrade) must get 403 `view_only` on decide/defer, not a decision.
3. Auto-upgrade must happen only for approvers actually named in this request. Another `insights_only` client on the same brand stays untouched.
4. A rolled-back request (for example `ApproverAccessEndedException` for another approver in the same send) must NOT leave anyone upgraded.
5. Changing a client back to `insights_only` through `PATCH` after an upgrade works, and the inbox closes again.

---

### Task 1: The level exists

**Files:**
- Create: `database/migrations/2026_10_08_100000_add_insights_only_to_client_access_level.php`
- Modify: `app/Models/ClientLaneLink.php` (constants ~64-71)
- Test: `tests/Feature/ClientPortal/InsightsOnlyAccessTest.php` (new)

**Interfaces:**
- Produces: `ClientLaneLink::ACCESS_INSIGHTS_ONLY = 'insights_only'`, included in `ClientLaneLink::ACCESS_LEVELS`.

- [ ] **Step 1: Failing tests.** In `InsightsOnlyAccessTest.php`:
  - `POST v1/brands/{brand}/clients` with `access_level: insights_only` returns 201, and the row's `access_level` is `insights_only`. Copy the request setup from `tests/Feature/ClientPortal/AddClientTest.php`.
  - `PATCH v1/brands/{brand}/clients/{user}` to `insights_only` returns 200 and persists.
  - A raw insert of `access_level = 'bogus'` still violates the CHECK constraint (pgsql).
- [ ] **Step 2:** Run them; they fail with 422 / a constraint violation.
- [ ] **Step 3: Migration.**

```php
<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Support\Facades\DB;

/**
 * Client portal "Insights only" (spec 2026-10-07): a fourth access level.
 * The client sees only the Insights tabs opened to clients; Approvals is closed.
 */
return new class extends Migration
{
    public function up(): void
    {
        if (DB::getDriverName() !== 'pgsql') {
            return;
        }
        DB::statement('ALTER TABLE workspace_external_invites DROP CONSTRAINT IF EXISTS workspace_external_invites_access_level_check');
        DB::statement("ALTER TABLE workspace_external_invites ADD CONSTRAINT workspace_external_invites_access_level_check CHECK (access_level IN ('own', 'all_approve', 'all_view', 'insights_only'))");
    }

    public function down(): void
    {
        if (DB::getDriverName() !== 'pgsql') {
            return;
        }
        // The old check would reject these rows; all_view is the closest read-only level.
        DB::table('workspace_external_invites')->where('access_level', 'insights_only')->update(['access_level' => 'all_view']);
        DB::statement('ALTER TABLE workspace_external_invites DROP CONSTRAINT IF EXISTS workspace_external_invites_access_level_check');
        DB::statement("ALTER TABLE workspace_external_invites ADD CONSTRAINT workspace_external_invites_access_level_check CHECK (access_level IN ('own', 'all_approve', 'all_view'))");
    }
};
```

- [ ] **Step 4: Constants.** Add next to the others, with a PHPDoc line in the same style:

```php
    /** Sees only the Insights tabs opened to clients; no requests at all (spec 2026-10-07 insights-only). */
    public const ACCESS_INSIGHTS_ONLY = 'insights_only';

    public const ACCESS_LEVELS = [self::ACCESS_OWN, self::ACCESS_ALL_APPROVE, self::ACCESS_ALL_VIEW, self::ACCESS_INSIGHTS_ONLY];
```

  `BrandClientController` validation already uses `Rule::in(ClientLaneLink::ACCESS_LEVELS)`. Grep for any other hard-coded list of the three levels (`'all_view'`) in app/ and include the new value where it is an allow-list.
- [ ] **Step 5:** Run the tests; they PASS. Run the baseline.
- [ ] **Step 6:** Commit `feat(api): insights_only client access level`.

### Task 2: Approvals closed for `insights_only`

**Files:**
- Modify: `app/Services/ClientLane/ClientPortalInbox.php` (`visible`, `isWaitingOnYou`, `waitingOnYouCount`)
- Modify: `app/Http/Controllers/Api/ClientPortal/PortalController.php` (`approvals` ~71)
- Modify: `app/Http/Controllers/Api/PublicShareLinkController.php` (`decisionRefusal`)
- Test: `tests/Feature/ClientPortal/InsightsOnlyAccessTest.php`

**Interfaces:**
- Consumes: `ClientLaneLink::ACCESS_INSIGHTS_ONLY`.
- Produces:
  - `GET public/portal/{ws}/{brand}/approvals` answers the dead-link 404 (`Support\ClientLane\DeadLink`'s body) for an `insights_only` lane;
  - `me` still lists the brand with `access_level: insights_only` and `waiting_on_you: 0`.

- [ ] **Step 1: Failing tests.**
  - With an `insights_only` lane and a session (`ClientLaneFixtures::namedClient` + `session`, then set the lane's `access_level`):
    - `approvals` → 404, with the exact dead-link body;
    - `me` → the brand shows `access_level` `insights_only` and a waiting count of 0;
    - the portal `insight-info` and an open tab (tick `client_visible` as in `PortalInsightsTest`) → 200.
  - Old request link: create a request naming the client while they are `own`, then switch them to `insights_only`. `POST public/share-links/{token}/decision` approve → 403 `view_only`; defer → 403 `view_only`; `GET` the link shows `access.view_only` true. Reuse `RequestPageSessionTest`'s decision helpers.
  - Review Focus 1: the same person is `own` on brand B. Brand B's `approvals` → 200.
- [ ] **Step 2:** Run them; they fail.
- [ ] **Step 3: Implement.**
  - `ClientPortalInbox::visible()`: for `insights_only` return a query that matches nothing (`->whereRaw('1 = 0')`), so callers stay safe.
  - `isWaitingOnYou()` / `waitingOnYouCount()`: treat `insights_only` like `all_view` (false / 0).
  - `PortalController::approvals()`: early `if ($lane->access_level === ClientLaneLink::ACCESS_INSIGHTS_ONLY) { return DeadLink response }`, using the same helper the codebase uses for the dead-link 404.
  - `decisionRefusal()`: after resolving `$client`, if the level is `insights_only`, return `'You can view this, but not decide. Ask the agency for approval access.'`. This applies to request and round links alike.
- [ ] **Step 4:** Run the tests and the baseline; they PASS. Mutation-check:
  - delete the `approvals` early return → the 404 test fails;
  - delete the `decisionRefusal` branch → the 403 test fails.

  Restore both by re-editing.
- [ ] **Step 5:** Commit `feat(api): insights_only clients get no approvals`.

### Task 3: Naming an `insights_only` client upgrades them to `own`

**Files:**
- Modify: `app/Services/ClientLane/ClientLaneService.php` (`provisionApprovers` ~131)
- Modify: `app/Services/Approval/ApprovalRequestService.php` (~140, the create result)
- Modify: `app/Services/Approval/ApprovalService.php` (~218, the round result)
- Modify: `app/Http/Controllers/Api/Approval/ApprovalRequestController.php` (`store` 201 body)
- Modify: `app/Http/Controllers/Api/Approval/ApprovalController.php` (round request 201 body)
- Test: `tests/Feature/ClientPortal/InsightsOnlyAccessTest.php`

**Interfaces:**
- Produces:
  - `provisionApprovers()` returns an extra key, `'upgraded' => list<array{email: string, name: string}>`;
  - both services pass it up as `'access_upgraded'`;
  - both 201 bodies include `access_upgraded` (always; `[]` when empty).

- [ ] **Step 1: Failing tests.**
  - KV, deck and plan request create, naming an `insights_only` client:
    - 201 with `data.access_upgraded == [['email' => …, 'name' => …]]`;
    - the lane is now `own`;
    - their `approvals` inbox → 200 and lists the request.
  - Naming an `own` client → `access_upgraded == []`, and the level is unchanged.
  - Review Focus 3: a second `insights_only` client on the brand who is NOT named stays `insights_only`.
  - Review Focus 4: name one `insights_only` client plus one client whose access ended → 422 `approver_access_ended`, and the `insights_only` client is STILL `insights_only` (the transaction rolled back).
  - Round path (`ApprovalController` request with `approver_emails`): same upgrade and the same `access_upgraded` field. Find the existing round tests under `tests/Feature/Approval/` for setup.
- [ ] **Step 2:** Run them; they fail.
- [ ] **Step 3: Implement in `provisionApprovers`.** After `mintLaneLink`, and only when the lane is active:

```php
            if ($lane->isActive() && $lane->access_level === ClientLaneLink::ACCESS_INSIGHTS_ONLY) {
                // Spec 2026-10-07 insights-only D-2: naming them is the agency asking them to approve.
                $lane->forceFill(['access_level' => ClientLaneLink::ACCESS_OWN])->save();
                $upgraded[] = ['email' => (string) $user->email, 'name' => (string) $user->name];
            }
```

  Declare `$upgraded = [];`, return `['actors' => …, 'rows' => …, 'upgraded' => $upgraded]`, and update the `@return` shape. Keep the `ApproverAccessEndedException` throw AFTER the loop; the callers' transaction rolls the upgrade back.
- [ ] **Step 4: Thread `upgraded` up.**
  - In both services, destructure `'upgraded' => $upgraded` beside `actors` / `rows`, and add `'access_upgraded' => $upgraded` to the returned result array. Initialise it to `[]` on paths that provision no approvers.
  - In both controllers, add `'access_upgraded' => $result['access_upgraded'] ?? []` to the 201 `data`.
- [ ] **Step 5:** Run the tests and the baseline; they PASS. Mutation-check: remove the `forceFill` → the upgrade tests fail. Restore.
- [ ] **Step 6:** Commit `feat(api): naming an insights_only client as approver upgrades them to own`.

### Task 4: Invite email copy per level

**Files:**
- Modify: `app/Mail/ClientInviteMail.php`
- Modify: `resources/views/emails/client-lane/client-invite.blade.php`
- Modify: `app/Services/ClientLane/BrandClients.php` (`sendInvite`, where the mail is built)
- Test: `tests/Feature/ClientPortal/AddClientTest.php` (or `InsightsOnlyAccessTest.php`)

**Interfaces:**
- Produces: the `ClientInviteMail` constructor gains `public bool $insightsOnly = false` (last parameter, defaulted, so existing calls stay valid).

- [ ] **Step 1: Failing test.** `Mail::fake()`; add a client with `access_level: insights_only` and `send_invite: true`. Assert `ClientInviteMail` was sent with `insightsOnly === true`, and that its rendered subject is `"{inviter} shared {brand}'s insights with you on frndOS"`. The rendered HTML contains "insights" and does NOT contain "waiting". An `own` invite keeps today's subject.
- [ ] **Step 2:** Run it; it fails.
- [ ] **Step 3: Implement.**
  - **Envelope subject:** `$this->insightsOnly ? "{$this->inviterName} shared {$this->brandName}'s insights with you on frndOS" : <today>`.
  - **`defaultNote()`:** gains `bool $insightsOnly = false`, returning `"Hi {$clientName} — this is where you'll see {$brandName}'s insights from {$workspaceName}. No password: this email is your link."` for that level.
  - **Blade:** when `$insightsOnly`, the subheading is `"{$brandName} via {$workspaceName} · insights"` and there is no waiting count. Swap any "approvals" wording in the body for "insights".
  - **`BrandClients::sendInvite`:** pass `insightsOnly: $lane->access_level === ClientLaneLink::ACCESS_INSIGHTS_ONLY`, and the default note with the same flag. `waiting` is 0 for this level anyway (Task 2).
- [ ] **Step 4:** Run the test and the baseline; they PASS.
- [ ] **Step 5:** Commit `feat(api): insights-only invite email copy`.

### Task 5: Wrap up

- [ ] Review Focus 5: test `PATCH` back to `insights_only` after an upgrade → the inbox is 404 again.
- [ ] Run the baseline plus `InsightsOnlyAccessTest.php`, then pint.
- [ ] Migrate the local dev DB: `TELESCOPE_ENABLED=false php -d memory_limit=1G artisan migrate --force`. It must say the new migration ran.
- [ ] Append a session-log entry to `docs/tracks/client-portal.track.md` (insights-only, the commits), then commit `docs(api): track insights-only access`.
- [ ] Report: commits, test counts, mutation checks, and the exact `access_upgraded` response shape.
