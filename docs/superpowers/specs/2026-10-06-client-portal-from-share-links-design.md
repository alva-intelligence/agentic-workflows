# Client Lane — client portal from the share links — Design

**Date:** 2026-10-06
**Author:** Daffa (with Claude)
**Status:** draft for review
**Source design:** *Mini client portal — frndOS UI* (13 boards; this spec covers boards 1 and 3 partly, plus 4, 6, 7 and 10).
**Builds on:**
- `docs/superpowers/specs/2026-10-01-client-lane-kv-approval-requests-design.md` (KV requests, lanes, code per device);
- `docs/superpowers/specs/2026-10-06-client-lane-deck-plan-approval-requests-design.md` (deck and plan on requests).
**Repos:** `api` (frnd-api-php), `web` (frnd-web).
**Branch:** `feature/daffa/vc-client-portal` in both, cut from `develop` **after** `feature/daffa/vc-client-lane-deck-plan-requests` merges.

---

## 1. Why

Today a client only sees approval work one link at a time (`/s/{token}`). The link arrives in WhatsApp or email, and nothing gathers "what is waiting on me for this brand". The P0a PRD listed a portal as a P0b non-goal. This spec builds the smallest portal that answers that question.

It grows the portal out of the existing share links instead of building a separate product:
- the links already sent keep working;
- the lane (personal access per brand) stays the permission;
- the decision page stays the review page.

Gap analysis (2026-10-06) found the parts this needs and lacks:
- a client identity that survives more than one brand. The `frnd_lane` cookie holds **one** lane code, so opening a second brand's personal link overwrites the first;
- any lane-authenticated api beyond `/s/{token}`;
- any list of a brand's clients, since `GET brands/{id}/members` excludes external roles;
- access levels.

It also found two live bugs, which this spec fixes:
1. Removing a client's brand role does not revoke their lane. `ClientLaneService::resolveHeader` never re-checks the role.
2. Approver suggestions in Request approval can never show clients. `useApproverEmails` reads `GET brands/{id}/members`, which excludes them and needs settings permission.

## 2. Scope

**In:**
- a client session per person per device;
- an access level per client per brand;
- a brand-scoped portal with an Approvals inbox across KV, deck and plan, a brand switcher, and sign-in by code;
- portal context on the review page (`/s/{token}`), including per-approver "opened";
- a minimal **Clients** tab in Brand Settings → Members;
- an approver-suggestions endpoint for the Request-approval picker;
- the two bug fixes.

**Out (later stages):**
- the "Invite a client" sheet and invite email;
- WhatsApp, title, access end date;
- Regenerate link, Resend invite, device tracking, and the "opened on 3 devices" alert;
- portal **Insights**, the Insights Tabs "Clients" column, and Preview as client;
- one inbox across brands;
- P0a rounds in the inbox (they are draining).

## 3. Decisions (brainstorming 2026-10-06)

| # | Decision | Why |
|---|---|---|
| P-1 | The portal grows from `/s/{token}`, the existing approval links. | Daffa's call. The brand is known from the link's subject (`brand_id`) and from the lane (`ClientLaneLink.brand_id`). |
| P-2 | **Identity is per person, access is per brand.** One `users` row per email across brands (already true). Permission is the per-brand lane. | One client can serve several brands, even across agencies. Revoking one brand must not touch another. |
| P-3 | The device remembers the **person**: a new `client_sessions` row plus cookie `frnd_client`. It replaces "one lane code in a cookie". | Fixes multi-brand overwrite, makes per-device sign-out possible, and gives a device record later stages need. Best practice over a cookie of many lane codes, or sanctum tokens for clients. |
| P-4 | Portal URL is **`/s/{workspace slug}/{brand slug}`**, e.g. `/s/fcn/frndglow`. Workspace slugs `session`, `verify` and `api` are reserved. | Brand slugs are unique only per workspace (`brands_workspace_id_slug_unique`), while workspace slugs are global (`workspaces_slug_unique`), so the pair is unique. The URL is readable and is not a credential. |
| P-5 | The inbox can show **all of a brand's requests**, governed by the client's access level. | Daffa chose this. |
| P-6 | **Three access levels per client per brand**: `own` (requests naming them), `all_approve` (all requests; decides those naming them), `all_view` (all requests, read-only). **Default `own` for every client, existing and new.** The agency raises it explicitly. | Least privilege. `own` equals today's behaviour, so the release opens nothing new. Matches the design's "Can" (View / View + Approve / Approve). |
| P-7 | Access levels are managed in a **minimal Clients tab**. Invite sheet, device tracking and the rest are later stages. | Daffa's call. |
| P-8 | **UI uses frndOS components** (§9): v2 first, then v1, then existing client-lane pieces. No new hex. Tokens per `frndos-design-foundations`. | Daffa's call; repo rule. |

## 4. Data and auth (api)

### 4.1 Tables

**`client_sessions`** (new): one row per signed-in device of a client.

| Column | Notes |
|---|---|
| `id` | ULID |
| `user_id` | FK `users`, the client |
| `token_hash` | sha256 of a random 32-byte token. The token is never stored. |
| `created_via` | `personal_link` \| `code` |
| `device_label` | parsed from user-agent ("Chrome · macOS") |
| `ip_hash` | |
| `last_seen_at` | |
| `expires_at` | 30 days after last use (sliding), capped at 90 days after creation |
| `revoked_at` | |
| timestamps | |

**Lane table** (`workspace_external_invites`, model `ClientLaneLink`): new column `access_level` string(16), values `own` \| `all_approve` \| `all_view`, default `own`. The migration backfills `own`.

**`approval_request_views`** (new):
- columns: `approval_request_id`, `user_id`, `first_opened_at`, `last_opened_at`;
- unique on (request, user).

**`approval_decisions`**: new nullable column `client_session_id`, for audit and the record PDF line "verified · this device".

**Index:** GIN on `approval_requests.approvers` (jsonb), for the `own` filter.

**Reserved workspace slugs:**
- `session`, `verify` and `api` are refused by workspace slug validation on create and update;
- the migration fails loudly, naming the workspace, if any existing slug collides.

### 4.2 Active lane

A lane is **active** when all three hold:
- `revoked_at` is null;
- `expires_at` is null or in the future;
- the user still holds the brand's `client` role (`user_brand_roles` on `BrandRole::CLIENT_SLUG`).

`ClientLaneService` gains `activeLanesFor(User)` and `activeLane(User, brandId)`. Every lane check goes through them, including `resolveHeader`. This is the fix for bug 1.

**Removing a client role anywhere revokes that brand's lane**, through a model event on `user_brand_roles` deletion. That covers the old `DELETE v1/brands/{brand}/members/{user}` as well as the new endpoint.

### 4.3 Creating a session

`ClientSessionService::issue(User, via, Request): [session, token]`. Called from:
1. **A personal link `?k=CODE`**, on a request link or a portal link. Web middleware captures it (as today). `/s/session` POSTs to `public/client/session` with `{lane_code}`. If the lane is active, a session is issued for its user and the token is returned to the web route, which sets the cookie. The URL is cleaned.
2. **A 6-digit code on a request link** (existing `public/lane/code/verify`). On success it also issues a session.
3. **A 6-digit code from the portal sign-in** (§5.3).

### 4.4 Middleware `client.session`

- Reads `X-Client-Session`, hashes it, and finds the session: not revoked, not expired.
- Touches `last_seen_at` and slides `expires_at`.
- Binds `ClientPrincipal { user, session, lanes: [brand_id => {lane, access_level}] }` to the request.
- Missing or invalid → `401 {code:"session_required"}`.
- Brand-scoped routes resolve `{workspace}/{brand}` and require an active lane for that brand. Otherwise `404 {"message":"Not found."}`: no hint that the brand exists.

### 4.5 The request page `/s/{token}` with a session

`PublicShareLinkController` resolves the viewer in this order:
1. the session user's active lane for the subject's brand;
2. else `X-Lane-Code`, the legacy `frnd_lane` cookie, kept through the transition;
3. else anonymous, as today.

When a session user opens a request link of a brand they have a lane on, the view is recorded in `approval_request_views`.

**Decisions:**
- a client whose lane is `all_view` gets `403 {code:"view_only"}`;
- otherwise rules are unchanged: a named approver decides, anyone else is advisory;
- the session id is stored on the decision.

## 5. Portal api

Route group `public/portal/*`: middleware `client.session`, `Cache-Control: no-store`, throttled.

### 5.1 `GET public/portal/me`

```json
{ "data": {
  "user": { "name": "Dina Pratiwi", "email": "dina@tokopedia.com" },
  "brands": [
    { "workspace": { "name": "FCN", "slug": "fcn" },
      "brand": { "name": "frndGlow", "slug": "frndglow", "logo_url": null },
      "access_level": "all_approve",
      "waiting_on_you": 1 }
  ] } }
```

It lists brands with an active lane only, ordered by `waiting_on_you` desc, then name.

### 5.2 `GET public/portal/{workspace}/{brand}/approvals?decided_cursor=`

**Visible requests:**
- `own`: requests on this brand whose `approvers` contain the user;
- `all_approve` and `all_view`: every request on this brand (`approval_requests.brand_id`);
- requests with status `not_relevant` (withdrawn) are excluded.

**Groups:**
- **`waiting_on_you`**: the request is pending, the user is a named approver, and at least one live approval in it has no decision by the user.
- **`waiting_on_others`**: the request is pending and is not in `waiting_on_you`.
- **`decided`**: the request is not pending. 90 days by default, then a cursor (`resolved_at`, id) for "Show older".

Response:

```json
{ "data": {
  "brand": { "name": "frndGlow", "slug": "frndglow", "workspace": "FCN", "logo_url": null },
  "access_level": "all_approve",
  "waiting_on_you": [Item], "waiting_on_others": [Item], "decided": [Item],
  "decided_next_cursor": null } }
```

```text
Item = { request_id, number, url: "/s/{token}",
  subject: { type: kv_file|deck|campaign, title, thumbnail_url },
  item_count, message_line,               // first line of the agency message, ≤ 120 chars
  requested_by: { name }, sent_at, decide_by,
  my_role: "approver" | "viewer",
  approvers: [{ name, decided, opened }],  // opened from approval_request_views
  counts: { decided, total },
  status, resolved_at,
  outcome_line: null | { outcome, by, at, note_excerpt } }   // decided only
```

### 5.3 Sign-in and sign-out from the portal

**`POST public/portal/{workspace}/{brand}/code` `{email}`**
- Always `202` with the same body.
- A code (existing `ClientVerificationCodeService`, scoped to the brand) is sent only if the email has an active lane on that brand.
- Throttled per (email, brand) and per IP.

**`POST public/portal/{workspace}/{brand}/code/verify` `{email, code}`**
- Valid code → issues a session → `200 {data: {session_token, expires_at}}`, consumed only by the web route.
- `422 invalid_code | code_expired`, as today.

**`DELETE public/portal/session`** revokes the current session.

## 6. Portal web

### 6.1 Routes

- `src/app/s/[workspace]/[brand]/page.tsx` is the portal. Static `/s/session` and `/s/verify/*` win over the dynamic segments.
- `src/app/s/api/portal/[...path]/route.ts` is the BFF proxy:
  - it reads `frnd_client` and forwards it as `X-Client-Session`;
  - it rejects any request whose `Origin` is not same-origin;
  - **the session token never reaches client JavaScript.**
- `/s/session` gains the session exchange (§4.3). The cookie is `frnd_client`: HttpOnly, Secure, SameSite=Lax, Path=`/s`, Max-Age set from `expires_at`.
- The middleware `?k=` capture also works on `/s/{workspace}/{brand}`.
- `/s` is already in the public allowlist. The portal is dark-scoped like the rest of `/s` (`data-theme-scope="dark"`).

### 6.2 Portal shell (desktop and phone)

**Header:**
- brand logo;
- **"frndGlow · via FCN"**, which becomes a brand switcher with a per-brand `waiting_on_you` count when `me.brands.length > 1`;
- on the right, the client's name with a menu holding "Sign out this device".

**Nav:** "Approvals" with a count. Insights is hidden until its stage.

**Phone:** the header compacts. The switcher and the account menu stay in the header.

### 6.3 Approvals page

**Summary line:**
- "One thing is waiting on you: {title}, {n} artboards, by {decide_by}."
- "{n} things are waiting on you."
- "Nothing is waiting on you."

**Waiting on you:**
- one card per item: thumbnail, title · subject type, `message_line`, "requested by {name} · {when}", "Decide by …", "{decided} of {total} decided";
- a **Review** button that links to `url`.

**Waiting on others:** one row per item, e.g. "Campaign deck · You approved Mon · Andi decides by Fri · 1 of 2". A viewer's row reads "Waiting on Andi".

**Decided:** compact rows with an outcome pill, title and version, who, when, and the note excerpt, then "Show older".

**Empty state:** "Nothing from FCN for frndGlow yet."

**View-only notice:** at the top for `all_view`: "You can view everything FCN sends for frndGlow. Ask FCN if you need to approve."

### 6.4 Sign-in screen (no session)

- brand header, then an email field, then a 6-digit `CodeInput`;
- on success the inbox opens;
- the screen is identical whether or not the brand or client exists.

### 6.5 Review page `/s/{token}` with a session

- the portal header (with the switcher) and a link **"← Approvals"** to `/s/{workspace}/{brand}`;
- the identity line "Deciding as {name}";
- the approver list shows "Not opened" / "Opened" / "Decided";
- **`all_view`:** the decision bar is replaced by the view-only notice. Pins stay readable and placeable as feedback;
- **without a session** the page behaves exactly as today.

### 6.6 Analytics (`client-lane-events.ts`)

- `client_lane.portal_viewed {access_level, waiting_on_you}`
- `portal_brand_switched`
- `portal_item_opened {group, subject_type}`
- `portal_signin_code_requested`, `portal_signin_verified`, `portal_signin_failed {reason}`
- `portal_signed_out`

They are added to the Lark taxonomy alongside the other client-lane events.

## 7. Agency side

### 7.1 Clients tab api

All endpoints use the Members page permission (`brand.settings.read` to read, `.write` to change):

| Endpoint | Returns or does |
|---|---|
| `GET v1/brands/{brand}/clients` | `[{ user: {id, name, email}, access_level, added_at, added_from: "KV approval request" \| "Deck approval request" \| "Plan approval request" \| null, last_opened_at, status: "not_opened" \| "active" }]` |
| `PATCH v1/brands/{brand}/clients/{user}` `{access_level}` | `200` with the row |
| `POST v1/brands/{brand}/clients/{user}/portal-link` | `{ url: "/s/{ws}/{brand}?k={lane code}" }`. The existing code is reused, not rotated. |
| `DELETE v1/brands/{brand}/clients/{user}` | removes the client role, which revokes the lane (§4.2) |

### 7.2 Clients tab web

Brand Settings → Members gains a third tab **"Clients (n)"** behind `show-client-lane`.

- **Columns:**
  - avatar, name and email;
  - an **access level** select (Own requests / All requests + approve / All requests, view only);
  - status ("Opened 2 hours ago" / "Not opened yet");
  - added ("Added 3 Oct · from a KV approval request").
- **Row "…" menu:**
  - **Copy portal link**;
  - **Remove access**, which confirms: "{name} can no longer open frndGlow links. Decisions they made stay on record."
- **Empty state:** "Clients appear here once you name them in a Request approval."
- **Analytics:** `client_lane.client_access_changed {from, to}`, `client_portal_link_copied`, `client_removed`.

### 7.3 Approver suggestions

**Api:** `GET v1/approval-requests/approver-suggestions?subject_type=&subject_id=` uses **the same authorisation as sending a request**. It returns `[{name, email, access_level}]`: the clients of the subject's brand.

**Web:** `useApproverEmails` switches to it. This is the fix for bug 2.
- An `all_view` chip reads "view only". Picking it shows an inline "Change to All requests + approve?", which PATCHes.
- A new email chip is tagged **"New client"**. New clients are created with `own`.
- Analytics: `approver_suggestion_picked`.

## 8. Security, rollout, testing

### 8.1 Security

- **Token:** random 32 bytes, stored as a hash only. HttpOnly cookie, BFF proxy, so no token in JS.
- **CSRF:** the portal api reads only a header, never a cookie. The proxy checks `Origin`.
- **Enumeration-safe:**
  - code request is always `202`;
  - no access is `404`;
  - the sign-in screen looks the same for any brand.
- **Throttles:** code requests per (email, brand) and per IP. Verification keeps 5 attempts and a 10-minute TTL.
- **Revocation:**
  - a lane revoked, or a role removed, drops the brand from every live session on the next request;
  - sign-out revokes one device.
- **Before the PR:** run the `security-review` skill on both branches.

### 8.2 Rollout

- **Agency side:** behind `show-client-lane`.
- **Client side:** `/s/*` stays unflagged, as today. The portal is reachable only with a session.
- **Legacy cookie:** `frnd_lane` is still honoured, and request links and personal links keep working.
- **Order:** api deploys before web. The old web sends no session header, and nothing breaks.

### 8.3 Testing

**api (Pest).** Scratch DB `frnd_testing`, explicit file paths, one process at a time.
- **Sessions:**
  - issued via `?k=` and via code;
  - sliding expiry and the 90-day cap;
  - sign-out.
- **Middleware:** missing, revoked or expired session; lane revoked; role removed → 401 or 404.
- **Inbox:** grouping for `own` / `all_approve` / `all_view`; withdrawn excluded; cursor.
- **Decisions:** `403 view_only`; a named approver with a session decides; the session id is stored.
- **Remove revokes the lane:** via the new endpoint and via the old `DELETE members/{user}`.
- **Code request:** enumeration-safe and throttled.
- **Approver suggestions:** permission and payload.
- **Reserved slugs:** rejected.

**web (`bun test`).** Pure rules:
- inbox grouping display, the summary line, labels per access level, switcher visibility;
- the proxy route (Origin check, header forwarding, no token in the response body).

**Manual:**
- two devices;
- a **multi-brand client**: a second brand in a second workspace. Neither cookie overwrites the other, and the switcher is right;
- a view-only client;
- Remove while the client has the portal open;
- the Clients tab in Midnight, Aurora and Daylight;
- the portal at phone width.

## 9. UI — frndOS components first

Rule order (`frndos-ui`):
1. **v2** (`@/components/frndos/v2`, Base UI);
2. **v1** (`@/components/frndos/*`) only where v2 has no equivalent;
3. existing **client-lane** pieces;
4. a new component only when none fits. It goes in **v2** with its story and skill row.

Text uses `text-text-inverse-*` / `text-text-default-*`, font-size tokens and `font-geist`. Surfaces use theme-aware tokens. No new hex, no `text-white`, no arbitrary `text-[Npx]`.

| Surface | Component |
|---|---|
| **Portal shell header** | |
| Brand switcher "frndGlow · via FCN ▾" | v2 `SelectMenu` (trigger reads the value; options carry `CountBadge`) |
| Account menu "Dina ▾ → Sign out this device" | v2 `ActionMenu` |
| Client avatar | v1 `Avatar` (as `PersonAvatar` already does) |
| Nav "Approvals (n)" | v2 `SegmentedTabs`, single item for now, with v2 `CountBadge` |
| **Approvals page** | |
| Page title + summary line | v2 `PageHeading` (`title`, `description`) |
| Section titles (Waiting on you · n …) | v2 `SectionHeading` |
| Waiting-on-you card | client-lane card surface (`RAIL_CARD` tokens) + v2 `Button` "Review" + `RequestProgressBar` (v1 `ProgressBar`) |
| Waiting-on-others / Decided rows | v2 `ItemRow` (`icon` = thumbnail glyph, `title`, `badge`, trailing meta) |
| Outcome / status pills | existing `StatusPill` / `OutcomePill` (v1 `Label`, toned by `statusTone`) |
| "Show older" | v2 `Button` variant `text` |
| Empty state | v1 `EmptyState` |
| View-only notice | client-lane `RAIL_CARD` note |
| **Sign-in screen** | |
| Email field | v1 `Input` (no native `<input>`) |
| Code entry | v2 `CodeInput` (used by `CodeSheet`) |
| Submit | v2 `Button` |
| Errors / sent notice | v1 `Toast` via `useToastStore` (`frndos-rules`) |
| **Review page additions** | |
| "← Approvals" | v2 `Button` variant `text` with an icon |
| Approver list with Opened / Not opened | existing `ApproverList` + `PersonAvatar` + `ApproverPill` |
| **Clients tab (Members page)** | |
| Tab | v1 `PillTabs` (the page already uses it for its two tabs) |
| Search | v1 `Input` (as the page's existing search) |
| Rows | the page's existing member-row layout with v1 `Avatar` |
| Access level select | v2 `SelectMenu` |
| Row "…" menu | v2 `ActionMenu` (portals into `BaseModal` correctly since the portal-container fix) |
| Remove confirm | v1 `BaseModal` + v2 `Button` (`alertPrimary`) |
| Empty state | v1 `EmptyState` |
| **Approver picker** | |
| Chips incl. "view only" / "New client" | v2 `Chip` (+ tag as in `ItemRow.Tag`) |
| "Change to All requests + approve?" | v2 `Button` variant `text` inline |

**No new frndOS component is expected.** If the shell header needs a reusable "brand header" across `/s` pages, it stays a client-lane component (`src/components/client-lane/portal/`), built from the pieces above.

## 10. Open questions

1. **Retention of `client_sessions` and `approval_request_views`.** Proposal: purge sessions 30 days after expiry or revocation, and keep views with the request.
2. **Agency-visible "opened".** Should the agency's request rows (Share dialog, status list) also show per-approver "Opened / Not opened"? The data exists after this spec, but the UI is out of scope.
3. **A client who is also a workspace member** (same email) is refused as an approver today (`already_a_member`). That rule is unchanged, so such a person never gets a portal.
