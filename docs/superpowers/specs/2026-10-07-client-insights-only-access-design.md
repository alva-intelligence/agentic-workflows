# Client portal — "Insights only" access level — Design

**Date:** 2026-10-07
**Author:** Daffa (with Claude)
**Status:** design approved in chat 2026-10-07
**Builds on:**
- `2026-10-06-client-portal-from-share-links-design.md` (access levels, P-6);
- `2026-10-07-client-portal-insights-design.md` (portal Insights).

Both are merged to develop (api#653, web#918).

**Repos:** `api`, `web`. New branch `feature/daffa/vc-client-insights-only` from develop in each repo.

## 1. Goal

An agency can give a client a portal that shows **only Insights**: no Approvals, enforced by the api.

The level is set per client per brand, like the three existing levels:

| Level | Sees | Decides |
|---|---|---|
| `own` | requests naming them | those requests |
| `all_approve` | every request | those naming them |
| `all_view` | every request | nothing |
| `insights_only` | **no requests** | nothing |

All four levels see the Insights tabs the agency opened for clients.

## 2. Decisions

| # | Decision |
|---|---|
| D-1 | A new `access_level` value, `insights_only`. Rejected: a separate boolean, which would allow meaningless combinations and make every check read two columns. |
| D-2 | Naming an `insights_only` client as an approver (KV, deck or plan request, or a new round) **auto-upgrades them to `own`** in the same transaction. The response lists who was upgraded, so the agency is told. |
| D-3 | When no Insights tab is open to clients, the portal still opens on Insights and shows an empty state. Invite is never blocked; it shows a non-blocking note instead. |
| D-4 | Approvals is closed **server-side**: the inbox returns the dead-link 404, and request links refuse decide/defer. Hiding it in the web is not enough. |

## 3. api

### 3.1 Data
- Migration: drop and re-add `workspace_external_invites_access_level_check` with `('own','all_approve','all_view','insights_only')`. The `down()` maps `insights_only` → `all_view` before restoring the old check.
- `ClientLaneLink::ACCESS_INSIGHTS_ONLY = 'insights_only'`, added to `ACCESS_LEVELS`. Add client (`store`) and change access (`PATCH`) accept it through `Rule::in(ACCESS_LEVELS)`.

### 3.2 Approvals closed
- **Portal inbox** (`ClientPortalInbox` / `PortalController` approvals): returns the dead-link 404 for an `insights_only` lane.
- **Request links** (`PublicShareLinkController::decisionRefusal`): an `insights_only` client is never a named approver (D-2 upgrades them first). They get the existing 403 `view_only` on decide/defer, and `access.view_only` is true on the page. Round links: same as `all_view`.
- **`me`**: already returns `access_level` per brand; the web uses it.

### 3.3 Auto-upgrade (D-2)
- Where approvers are provisioned (`ApprovalRequestService::provisionApprovers`, request and round paths): an approver whose active lane is `insights_only` is set to `own` in the same transaction.
- Create responses (request and round) add `access_upgraded: [{email, name}]`. The field is always present; `[]` when nobody was upgraded.
- Approver suggestions keep returning `access_level`, so the web can tag them.

### 3.4 Invite email
- `ClientInviteMail` copy branches on the level. For `insights_only` it reads "see {brand}'s insights" and omits the waiting-on-you count. Subject: "{inviter} shared {brand}'s insights with you on frndOS".

### 3.5 Tests (Pest, scratch DB)
- the migration accepts `insights_only`;
- store and PATCH accept it;
- inbox 404;
- decide/defer 403 on a request link;
- Insights stays open (client-visible tabs);
- naming them upgrades to `own`, `access_upgraded` lists them, and other levels are untouched;
- the round path upgrades too;
- invite email copy;
- `me` reports the level.

## 4. web

### 4.1 Portal
- `/s/{ws}/{brand}`: for an `insights_only` lane, the server redirects to `/s/{ws}/{brand}/insights` before rendering Approvals.
- `PortalNav`: an `insights_only` lane shows only **Insights**, with no Approvals and no count badge. Insights shows for this level even when no tab is open.
- `/insights` with no client-visible tab, for `insights_only`: empty state "{agency} hasn't shared any insights for {brand} yet." (frndOS components, tokens only, all three themes, phone width).
- Brand switcher: each brand follows its own level.
- A request link opened by this client: read-only, with the existing view-only notice.

### 4.2 Agency
- **Invite a client:**
  - "Can" gets a 4th chip, **Insights only**, with the hint "Sees only the Insights tabs you open to clients — no approvals.";
  - the message draft and WhatsApp text switch to the insights wording;
  - when no tab is open to clients, a non-blocking note with a link to Brand Settings → Insights Tabs.
- **Clients tab:** the access select gains "Insights only". The row label uses the same copy.
- **Request approval (KV, deck, plan):**
  - suggestions show an "Insights only" tag;
  - after send, a non-empty `access_upgraded` shows a toast: "Dina's access changed to Own requests so they can approve." / "2 clients' access changed to Own requests so they can approve.";
  - brand-clients is invalidated (already done on create).

### 4.3 Analytics
- Existing events carry `access_level`, which now includes the new value.
- The request-sent event gains `access_upgraded_count`.
- Update the taxonomy rows in `docs/tracks/client-portal.track.md`.

### 4.4 Tests (`bun test`, per file)
- **Pure rules:** labels, hints, chip, invite draft, WhatsApp text and upgrade toast copy.
- **Components:** `PortalNav` without Approvals; the Insights empty state; the 4th chip in Invite; the upgrade toast after send.

## 5. Out of scope
- Per-client (rather than per-brand) choice of which Insights tabs a client sees.
- Hiding Insights for the other three levels.
- An AskFRND tool for access changes.
