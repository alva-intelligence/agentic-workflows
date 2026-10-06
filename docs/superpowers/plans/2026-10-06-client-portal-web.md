# Client Lane — Client Portal from the Share Links — Web Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A client who has opened one share link gets a brand-scoped portal at `/s/{workspace slug}/{brand slug}`: an Approvals inbox across KV, deck and plan requests, a brand switcher, sign-in by 6-digit code and "Sign out this device". The review page `/s/{token}` gains portal context. The agency gets a Clients tab under Brand Settings → Members and an approver picker that finally suggests clients.

**Architecture:** The device remembers the **person** through an HttpOnly `frnd_client` cookie that only Next route handlers read. Page JS never sees the token. Server components read the cookie only to forward it to the api.

- Every browser call that needs the session goes through a same-origin BFF. `src/app/s/api/portal/[...path]` forwards to `public/portal/*`, and `src/app/s/api/share-links/[...path]` forwards to `public/share-links/*`. Both strip any `session_token` from bodies, and both check `Origin`/`Sec-Fetch-Site`.
- `?k=` capture also runs on portal URLs. It marks the capture fresh, and the page then trades the lane for a session through `POST /s/session/exchange`.
- A 6-digit code on a request link is now spent through `POST /s/session/code`. That route sets both cookies and answers the lane only.
- Pure modules in `src/lib/client-lane/portal/*` own every rule: inbox lines, summary, switcher, sign-in state machine, error routing. Components only wire them up.
- The agency side adds `src/services/brand-clients.ts`, a v2 `ClientsTab`, and a reworked `useApproverEmails`.

**Tech Stack:** Next.js 16 app router (route handlers, async `params`, `middleware.ts`), React 19, TypeScript, Tailwind 3.4, TanStack Query v5 (`useInfiniteQuery`), `@base-ui/react` (frndOS v2), Radix (`BaseModal`), PostHog (`posthog-js`), `bun test` (vitest-compatible API, jsdom preload), Testing Library.

**Spec:** `docs/superpowers/specs/2026-10-06-client-portal-from-share-links-design.md` (workspace root). This plan is the web half:

- §6 (portal web) and §7.2 (Clients tab);
- §7.3 web (approver suggestions);
- §8 web tests and the manual checklist;
- §9 (the UI component map, which binds every UI task).

It builds on `docs/superpowers/specs/2026-10-01-client-lane-kv-approval-requests-design.md` and `…-2026-10-06-client-lane-deck-plan-approval-requests-design.md`. The api half is planned in `docs/superpowers/plans/2026-10-06-client-portal-api.md`, written in parallel.

## API contract assumed

> **Reconciled with the api plan (2026-10-06, coordinator).** `2026-10-06-client-portal-api.md` § "API contract for web" is authoritative. Changes to the assumptions below:
> 1. **Request-link code verify:** the route handler sends **`issue_session: true`** and reads the **flat** keys `data.session_token` (`null` for a verified-guest lane, which means cookie the lane only, as today) and `data.session_expires_at`. There is no nested `session` object.
> 2. **`POST public/client/session`** returns `{ session_token: string|null, expires_at, workspace_slug, brand_slug }`. **`session_token: null` means keep the current `frnd_client` cookie** (it already belongs to this person); only refresh its `Max-Age` from `expires_at`. A string replaces the cookie. `workspace_slug` / `brand_slug` give the exchange its redirect target.
> 3. **`X-Client-Session-Expires-At`** is sent by the api (confirmed), so the cookie slides.
> 4. **`X-Forwarded-For` is not trusted** by the api. Do not forward it as a trust signal. `User-Agent` is still forwarded on session-issuing calls.
> 5. `my_decision` and `subject.version_label` are confirmed. They are always present, possibly `null`.
> 6. Suggestions rows carry `user_id` (confirmed).
> 7. **Nullability per the api:** `Item.url` may be `null` when the link is revoked (render the row without a link); `requested_by.name`, `outcome_line.by` and `outcome_line.at` may be `null`. Types below must allow it.
> 8. **The portal-link `url` is absolute** (`https://…/s/{ws}/{brand}?k=…`). Use it as-is when it starts with `http`.
> 9. Share-link payload: `viewer.session: boolean` and `viewer.access_level` exist. Prefer `viewer.session` over slug matching to decide whether to show the portal header. Keep the slug match only to build the "← Approvals" href.


The api plan is being written in parallel. The web codes against the shapes below.

- Anything the spec pins is copied from §4–§5 and §7.
- Anything marked **(assumed)** is the web's reading. The two plans must reconcile it before Task 5 merges.
- Everything not listed keeps the request-link contract from the deck/plan spec.

**Headers and cookies**

| Name | Where | Notes |
|---|---|---|
| `X-Client-Session` | web server → api, on `public/portal/*`, `public/share-links/*`, `public/client/session` | The raw session token. Only route handlers and server components send it. |
| `X-Lane-Code` | web → api, share-link endpoints | Unchanged (legacy `frnd_lane`). |
| `X-Client-Session-Expires-At` | api → web, on any session-authenticated 2xx | **(assumed)** The slid `expires_at` (ISO). The proxy resets the cookie's `Max-Age` from it. If the api does not send it, the cookie keeps its first `Max-Age` (30 days from issue). |
| `X-Forwarded-For`, `User-Agent` | web server → api | **(assumed)** The api reads the client IP from `X-Forwarded-For` behind the web server (trusted proxy) for `ip_hash` and the per-IP throttles. It reads `device_label` from `User-Agent`. Without this, every portal call looks like the Next server's IP. |
| `frnd_client` | browser ↔ web only | HttpOnly, Secure (prod), SameSite=Lax, Path=`/s`. `Max-Age` comes from `expires_at`, capped at 90 days. |
| `frnd_lane_new` | browser ↔ web only | **Web-only.** It is set by the `?k=` capture beside `frnd_lane`, `"1"`, Max-Age 600. It tells the page to trade the lane for a session. |

Token format **(assumed)**: an opaque URL-safe string of 32–128 chars, `/^[A-Za-z0-9_-]{32,128}$/` (for example base64url of 32 random bytes = 43 chars).

**Session issue**

| Call | Body | Answer |
|---|---|---|
| `POST public/client/session` | `{ lane_code }` (+ optional `X-Client-Session`) | `200 { data: { session_token, expires_at } }` **(assumed: same shape as the code verify)**. Any non-200 = no session (lane inactive). If the request carries a session of the SAME user, the api may return that session instead of a new row **(assumed, optional; the web replaces the cookie either way)**. |
| `POST public/lane/code/verify` (existing, request link) | `{ email, code, share_token }` | `200 { data: { lane_code, kind, expires_at, session: { session_token, expires_at } \| null } }`. The `session` key is **(assumed)**. When it is absent or null, the web cookies the lane only, as today. `422 invalid_code` (+ `attempts_left`) / `code_expired`, `429` are unchanged. **The web now calls this from a route handler, never from page JS.** |

**Portal (`public/portal/*`, middleware `client.session`, `Cache-Control: no-store`, throttled)**

| Call | Answer |
|---|---|
| `GET me` | `{ data: PortalMe }`: brands with an active lane only, ordered by `waiting_on_you` desc, then name. |
| `GET {workspace}/{brand}/approvals?decided_cursor=` | `{ data: PortalApprovals }` |
| `POST {workspace}/{brand}/code` `{ email }` | Always `202` with the same body (the web ignores the body). |
| `POST {workspace}/{brand}/code/verify` `{ email, code }` | `200 { data: { session_token, expires_at } }`, consumed by the BFF only. `422 { code: "invalid_code", attempts_left? }` / `{ code: "code_expired" }`. `429`. |
| `DELETE session` | `204` **(assumed)**. The web clears its cookies whatever the status. |
| any, with a missing/invalid/revoked/expired session | `401 { code: "session_required" }` |
| a brand-scoped route without an active lane for it | `404 { "message": "Not found." }` |

`PortalMe`, `PortalApprovals` and `PortalItem` follow spec §5.1–§5.2 verbatim, plus two **(assumed)** optional fields:

- `PortalItem.my_decision: null | { outcome, at }`. It is the viewer's own latest decision on the request. Waiting-on-others reads "You approved Mon" from it. When it is absent, that clause is left out.
- `PortalItem.subject.version_label: string | null`, for example `"v4"`. Decided rows read "title · v4" from it. When it is absent, they read "title · Request {number}".

**Share links (`public/share-links/{token}*`)**

- The resolver reads the viewer in this order: the session user's active lane for the subject's brand, then `X-Lane-Code`, then anonymous. With a session it records `approval_request_views`. A session viewer with an active lane resolves as `viewer.kind = "client"` **(assumed)**.
- C-1 additions **(assumed)**:
  - `workspace.slug: string`. The review page matches the portal brand by `(workspace.slug, brand.slug)`, and falls back to `(workspace.name, brand.slug)` when `slug` is absent.
  - `request.approvers[].opened: boolean`. It is absent on old payloads, which read as "Not opened".
- `POST …/decision` answers `403 { code: "view_only" }` for an `all_view` client.

**Agency (`axiosInstance`, authenticated, Members page permission)**

| Call | Answer |
|---|---|
| `GET v1/brands/{brand}/clients` | `{ data: BrandClient[] }`. The envelope is **(assumed)**, and the row is spec §7.1 verbatim. |
| `PATCH v1/brands/{brand}/clients/{user}` `{ access_level }` | `200 { data: BrandClient }` (envelope **(assumed)**). |
| `POST v1/brands/{brand}/clients/{user}/portal-link` | `{ data: { url } }` **(assumed envelope)**. The reader also accepts a bare `{ url }`. `url` is relative (`/s/{ws}/{brand}?k=…`), and the web makes it absolute. |
| `DELETE v1/brands/{brand}/clients/{user}` | `204` **(assumed)** |
| `GET v1/approval-requests/approver-suggestions?subject_type=&subject_id=` | `{ data: [{ user_id, name, email, access_level }] }`. The `user_id` field and the envelope are **(assumed)**. The web needs `user_id` for the inline "Change to All requests + approve?" PATCH. |

**TypeScript (`src/lib/client-lane/portal/types.ts`, Task 1)**

```ts
export type ClientAccessLevel = "own" | "all_approve" | "all_view";

export interface PortalBrand {
  workspace: { name: string; slug: string };
  brand: { name: string; slug: string; logo_url: string | null };
  access_level: ClientAccessLevel;
  waiting_on_you: number;
}

export interface PortalMe {
  user: { name: string; email: string };
  brands: PortalBrand[];
}

export interface PortalItem {
  request_id: string;
  number: number;
  url: string; // "/s/{token}"
  subject: {
    type: ShareSubjectType;
    title: string;
    thumbnail_url: string | null;
    version_label?: string | null; // (assumed)
  };
  item_count: number;
  message_line: string | null;
  requested_by: { name: string };
  sent_at: string | null;
  decide_by: string | null;
  my_role: "approver" | "viewer";
  my_decision?: { outcome: DecisionOutcome; at: string } | null; // (assumed)
  approvers: Array<{ name: string; decided: boolean; opened: boolean }>;
  counts: { decided: number; total: number };
  status: ApprovalStatus;
  resolved_at: string | null;
  outcome_line: null | {
    outcome: DecisionOutcome | ApprovalStatus;
    by: string;
    at: string;
    note_excerpt: string | null;
  };
}

export interface PortalApprovals {
  brand: { name: string; slug: string; workspace: string; logo_url: string | null };
  access_level: ClientAccessLevel;
  waiting_on_you: PortalItem[];
  waiting_on_others: PortalItem[];
  decided: PortalItem[];
  decided_next_cursor: string | null;
}
```

Public type changes (`src/lib/client-lane/types.ts`, Task 14):
- `ShareLinkBase.workspace` becomes `{ name: string; slug?: string }`;
- `PublicRequestApprover` gains `opened?: boolean`;
- `PublicErrorCode` gains `"view_only" | "session_required"`.

---
## Global Constraints

- **Where to work:** worktree **WT** = `/Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-portal`, branch `feature/daffa/vc-client-portal`. Task 0 chooses its base. Agent shells reset cwd, so every command starts with `cd` to that literal path; `cd WT` below means exactly that path. Never write in `web/` itself, because Daffa may be live-testing there (memory: no write agents during live testing). Never touch `api/`.
- **Git:**
  - Use `/usr/bin/git` and `/usr/bin/grep`, because an rtk hook rewrites plain `git`/`grep` output.
  - The shell is zsh. Put file lists in arrays (`F=(a b)`) and quote every path containing `(`, `[` or `]`.
  - Commit with `/usr/bin/git commit -F - <<'EOF' … EOF`. The subject is `<type>(web): …`, and the last line is `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
  - **Never push. Never `git stash`.** Never open a PR.
- **Tools through `./node_modules/.bin/`:** a shell hook rewrites bare `eslint`/`prettier`/`tsc`. So:
  - `./node_modules/.bin/tsc --noEmit -p .`;
  - `./node_modules/.bin/eslint <files>`;
  - `./node_modules/.bin/prettier --write <files>`.

  Build with `node ./node_modules/next/dist/bin/next build`, never `bun run build` (memory: broken on Next's runtime). The build does NOT type-check (`ignoreBuildErrors`).
- **Tests:**
  - Run `bun test <file>`, ONE file per invocation. Never pass a directory (memory: a directory run blew up to 26 GB), and never use `bunx vitest`.
  - Query with `const body = () => within(document.body)`, never `screen` (memory: RTL `screen` is broken under bun).
  - Import `"@testing-library/jest-dom/vitest"` at the top of component tests.
  - Keep every test file **< 45 KB**: run `wc -c` before adding to an existing one, because bun dies past ~51 KB with a bogus SCSS error.
  - Read bun's `N error` line: a file that dies at import shows as one error, not as failures.
  - bun has no `vi.hoisted`, `vi.mocked` or `vi.waitFor`. Use RTL `waitFor` and cast spies.
  - **No test lives under `src/app/**/[…]/`**: bracketed route folders are awkward on the CLI. Route handlers are two-line wrappers around functions in `src/lib/client-lane/portal/*`, and the tests target those functions.
- **Mocks:** **never `vi.mock` / `mock.module` a module** (memory: bun's registry is process-global and binds once). Spy on the edges:
  - `vi.spyOn(axiosInstance, "get" | "post" | "patch" | "delete")` (`import axiosInstance from "@/services/axios"`);
  - `vi.spyOn(axiosPublic, …)` (`import { axiosPublic } from "@/services/axios"`);
  - `vi.spyOn(posthog, "capture")` (`import posthog from "posthog-js"`);
  - `vi.spyOn(globalThis, "fetch")`.

  Call `vi.restoreAllMocks()` in `beforeEach`. Existing suites register partial module mocks (`@/lib/featureFlags`, `@/store/useToast`, `@/lib/analytics/kv-generator-events`). Therefore:
  - no new or changed component except the Members **page** imports `@/lib/featureFlags`;
  - components read toasts only as `useToastStore((s) => s.showToast)`.
- **No `next/navigation` in new client components.** jsdom has no app router mounted, and `useRouter()` throws there. Navigation and reloads go through props with window defaults (`onNavigate = (h) => window.location.assign(h)`, `onSignedIn = () => window.location.reload()`). Tests pass `vi.fn()`. Public `/s/*` pages are full page loads anyway.
- **Every new test proves itself (memory: plan tests written from reasoning were vacuous 6×):**
  - Watch it FAIL for the stated reason before implementing.
  - Recompute every expected value from the real code, not from this plan.
  - After it passes, apply the **named mutation**, watch the named test fail, restore, and watch it pass.
  - If an expectation disagrees with code that matches the spec, fix the expectation and note it in the track's session log.
- **Type gate:**
  - `./node_modules/.bin/tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"` must stay ≤ the baseline recorded in Task 0.
  - `… | /usr/bin/grep -F -f /tmp/client-portal-touched.txt` must show no NEW lines.
- **Lint / format:**
  - `./node_modules/.bin/eslint <touched files>` must report 0 errors and no new warnings on changed lines.
  - Run `./node_modules/.bin/prettier --write` on NEW files, and on modified files whose base version is already prettier-clean. Check with `/usr/bin/git show <base>:<path> | ./node_modules/.bin/prettier --check --stdin-filepath <path>`.
  - `src/app/(dashboard)/brands/[id]/settings/members/page.tsx` is **not** prettier-clean on the base. Hand-format it and never run prettier on it (memory: formatter churn bloats the PR).
- **frndOS components first (spec §9, binding):**
  - Before any UI task, read `WT/.claude/skills/frndos-ui/SKILL.md`, then `frndos-components-v2`, `frndos-components`, `frndos-design-foundations` (Appearance tri-mode) and `frndos-rules`.
  - Priority: v2 → v1 → existing client-lane pieces. **No new frndOS component and no change to any v2 component's API.**
  - **One file never imports both v1 (`@/components/frndos/*`) and v2 (`@/components/frndos/v2`).** v1 pieces are used through single-purpose wrapper files that import only v1:
    - existing: `PersonAvatar`, `StatusPill`, `RequestProgressBar`;
    - new: `PortalEmailField`, `PortalEmptyState`, `ClientAvatar`, `ClientRemoveModal`, `ClientsEmptyState`.
- **Tokens only** on every line this plan writes or rewrites:
  - text `text-text-inverse`, `-subtle`, `-subtlest` (`text-text-inverse-default` where the Members page already uses it), and `text-negative-400` for errors;
  - sizes `text-textXs`, `text-textXsMedium`, `text-textSm`, `text-textSmMedium`, `text-displayXsMedium`;
  - radius `rounded-full`, `-2xl`, `-xl`, `-lg`;
  - surfaces `bg-white/5`, `/10` or `bg-surface-*`, and `bg-black` only for the public page ground (as `DecisionPage` does);
  - borders `border-white/10`, `border-border-default`, `divide-border-default`;
  - `font-geist`, `focus-visible:ring-2 focus-visible:ring-white/40`.

  Never use `text-[Npx]`, `text-white`, `text-gray-*`, an arbitrary `white/[0.0x]` or a new hex (memory: dark hex is invisible to the Aurora sweep).
  - **Public `/s/*` pages** are dark-scoped: the root carries `data-theme-scope="dark"` and `data-client-lane-page=""`, as `DecisionPage` does.
  - **Agency surfaces** (the Clients tab, the approver picker) must read right in **Midnight, Aurora and Daylight**.
- **Copy** (spec §6–§7, exact strings): Approvals; Waiting on you; Waiting on others; Decided; Review; Show older; "Nothing is waiting on you."; "One thing is waiting on you: {title}, {n} artboards, by {date}."; "{n} things are waiting on you."; "Nothing from {workspace} for {brand} yet."; "You can view everything {workspace} sends for {brand}. Ask {workspace} if you need to approve."; Sign out this device; "Deciding as {name}"; Not opened / Opened / Decided; Clients ({n}); Own requests / All requests + approve / All requests, view only; Opened {relative} / Not opened yet; "Added {d MMM} · from a {KV|Deck|Plan} approval request"; Copy portal link; Remove access; "{name} can no longer open {brand} links. Decisions they made stay on record."; "Clients appear here once you name them in a Request approval."; view only; New client; "Change to All requests + approve?". "artboard(s)" appears only for `kv_file`.
- **Security (spec §6.1, §8.1):**
  - The session token never reaches client JavaScript: no prop, no response body, no log, no URL. Only route handlers read and write `frnd_client`. Server components read it only to forward it to the api.
  - The BFF forwards only `Accept`, `Content-Type`, `User-Agent`, `X-Forwarded-For` and the cookie-derived `X-Client-Session` / `X-Lane-Code`, never the browser's `cookie` or `authorization`. It only proxies an allowlist of endpoint shapes.
  - Run the `security-review` skill before the PR (Task 19).
- **Toasts:** `useToastStore((s) => s.showToast)(title, description, type)`. **`Toast` renders nothing below `md`** (`src/components/frndos/Toast.tsx`: `if (isMobile) return null`), and the portal is phone-first. So portal errors are ALWAYS inline (`role="alert"`). The toast is only an extra desktop notice ("Code sent").
- **Analytics:** only through typed helpers in `src/lib/analytics/client-lane-events.ts`, never an inline `posthog.capture`. Public events are PII-free: no name, no email, no token, no slug. Every new event is listed for the Lark taxonomy in Task 19.
- **Flag:** the Clients tab sits behind `show-client-lane`, gated in the Members page with `useClientLaneEnabled()`. The approver picker is already inside flag-gated hosts. `/s/*` stays unflagged.
- **Next 16 (read `WT/node_modules/next/dist/docs/01-app/03-api-reference/03-file-conventions/route.md` and `dynamic-routes.md` before Tasks 5 and 13):**
  - `params` is a `Promise`.
  - `middleware.ts` is deprecated in favour of `proxy.ts` but is this repo's file, so do NOT migrate it here.
  - Two different dynamic names at one level are a build error, so the portal reuses `[token]` as the workspace slug: `src/app/s/[token]/[brand]/page.tsx`.

## Review Focus

These are the inputs the spec implies but no happy path exercises, most likely to bite first. Each one has a named test in its owning task.

1. **A traversal or unknown path through the BFF.** A segment like `..` that still matches an allowlisted shape (`["..", "frndglow", "approvals"]`), or a path outside the portal's routes, must 404 without calling the api. Otherwise a session header rides to an arbitrary api path. → Task 5 ("404s anything outside the portal's own routes without calling the api").
2. **A `session_token` in any relayed body.** The verify response, or an api that echoes it, must never reach page JS. Only the HttpOnly cookie may carry it. → Task 5 ("signs in: sets the session cookie and keeps the token out of the body", "strips a session_token anywhere in a relayed body") and Task 7 ("cookies the lane and the session, answers the lane only").
3. **A second personal link opened on a device that already has a session:** a second brand, or a different person. The fresh-capture marker must make the page adopt the link's person, whether or not a session exists, and the marker must be cleared on every outcome so the page never loops. → Task 4 ("marks a portal capture fresh", `shouldExchangeLane`) and Task 7 ("keeps the legacy lane when the api refuses", which checks the marker is cleared).
4. **Access removed while the portal is open.** The next approvals call answers `404` (or `401`). The page must fall back to the sign-in screen, with no "you were removed" hint and no retry storm. → Task 11 ("hands back to sign-in when the brand is gone").
5. **A view-only (`all_view`) client on a request link.** No Approve or Request-changes control anywhere, including KV artboard cards. The notice is shown instead, and pins stay placeable. → Task 14 ("replaces the decision controls with the view-only notice for an all_view client").

Also pinned, as cheaper rules:
- A GET from an old Safari that sends neither `Sec-Fetch-Site` nor `Origin` still works, but a header-less POST is refused (Task 5).
- Sign-out clears the cookies even when the api already forgot the session (Task 5).

---

## File Structure

All paths are relative to WT.

| File | Status | Responsibility |
|---|---|---|
| `docs/tracks/client-portal.track.md` | create | Track: baselines, checklist, session log |
| `src/lib/client-lane/portal/types.ts` | create | Portal wire types, `ClientAccessLevel`, `PortalSession` |
| `src/lib/client-lane/portal/fixtures.ts` | create | `portalBrand`, `portalMe`, `portalItem`, `portalApprovals` builders for tests |
| `src/lib/client-lane/portal/inbox.ts` (+ `.test.ts`) | create | Access-level labels; summary line; card, row and decided lines; page merge; empty and view-only copy |
| `src/lib/client-lane/portal/shell.ts` (+ `.test.ts`) | create | Switcher visibility and options; brand matching; portal href; identity line; error routing |
| `src/lib/client-lane/statusTone.ts` | modify | `approverTone` (Not opened / Opened / Decided) |
| `src/lib/client-lane/statusTone.approver.test.ts` | create | Approver tone tests |
| `src/lib/client-lane/portal/signIn.ts` (+ `.test.ts`) | create | Sign-in state machine and its copy |
| `src/lib/client-lane/cookie.ts` | modify | `frnd_client` and `frnd_lane_new` cookies, `shouldExchangeLane` |
| `src/lib/client-lane/cookie.session.test.ts` | create | Session cookie tests |
| `src/middleware.ts` | modify | `?k=` capture on `/s/{ws}/{brand}`; fresh marker; `api` reserved |
| `src/middleware.portal.test.ts` | create | Capture tests |
| `src/lib/client-lane/portal/proxy.ts` (+ `.test.ts`) | create | BFF: CSRF guard, allowlists, safe paths, header forwarding, token stripping, cookie set/clear/slide |
| `src/app/s/api/portal/[...path]/route.ts` | create | Thin wrapper → `portalProxy` |
| `src/app/s/api/share-links/[...path]/route.ts` | create | Thin wrapper → `shareLinkProxy` |
| `src/lib/client-lane/publicApi.ts` | modify | `LaneAuth` transport (direct or BFF); `verifyLaneCode` through `/s/session/code` |
| `src/lib/client-lane/publicApi.transport.test.ts` | create | Transport and verify tests |
| `src/lib/client-lane/laneCode.ts` | modify | `confirmLaneCode` no longer cookies from JS |
| `src/lib/client-lane/portal/sessionRoutes.ts` (+ `.test.ts`) | create | `exchangeLane`, `verifyRequestLinkCode` |
| `src/app/s/session/exchange/route.ts`, `src/app/s/session/code/route.ts` | create | Thin wrappers |
| `src/lib/client-lane/portal/me.ts` (+ `.test.ts`) | create | `fetchPortalMe` (server-side fetch, uncached) |
| `src/lib/client-lane/portal/server.ts` | create | `resolvePortalMeServer` = React `cache(fetchPortalMe)` |
| `src/lib/client-lane/server.ts` | modify | `resolvePublicShareServer(token, laneCode, sessionToken)` |
| `src/services/client-portal.ts` (+ `.test.ts`) | create | Browser portal calls via `/s/api/portal/`; `usePortalApprovals` |
| `src/lib/analytics/client-lane-events.ts` | modify | Portal, Clients-tab and suggestion events |
| `src/lib/analytics/client-lane-events.portal.test.ts` | create | Event-name tests |
| `src/components/client-lane/RequestRail.tsx` | modify | `export const RAIL_CARD` |
| `src/components/client-lane/portal/PortalFrame.tsx` | create | Dark-scoped page ground |
| `src/components/client-lane/portal/PortalHeader.tsx` (+ `.test.tsx`) | create | Logo, brand switcher (`SelectMenu`), avatar + name + account `ActionMenu` |
| `src/components/client-lane/portal/PortalNav.tsx` | create | `SegmentedTabs` "Approvals" + `CountBadge` |
| `src/components/client-lane/portal/PortalViewOnlyNotice.tsx` | create | `RAIL_CARD` note |
| `src/components/client-lane/portal/PortalEmptyState.tsx` | create | v1 `EmptyState` wrapper |
| `src/components/client-lane/portal/WaitingCard.tsx` | create | Waiting-on-you card |
| `src/components/client-lane/portal/PortalApprovals.tsx` | create | Approvals page body (presentational) |
| `src/components/client-lane/portal/PortalApp.tsx` (+ `.test.tsx`) | create | Query, view analytics, navigation, session-lost routing |
| `src/components/client-lane/portal/PortalEmailField.tsx` | create | v1 `Input` wrapper |
| `src/components/client-lane/portal/PortalSignIn.tsx` (+ `.test.tsx`) | create | Sign-in screen |
| `src/components/client-lane/portal/LaneExchange.tsx` (+ `.test.tsx`) | create | `LaneExchange`, `PortalExchangeGate`, `ReviewLaneExchange` |
| `src/app/s/[token]/[brand]/page.tsx` | create | The portal route |
| `src/app/s/[token]/page.tsx` | modify | Session → `X-Client-Session`, portal context, exchange |
| `src/components/client-lane/DecisionPage.tsx` | modify | `portal` prop: header, ← Approvals, Deciding as, approver list, view-only, BFF transport, `view_only` 403 |
| `src/components/client-lane/ApproverList.tsx` | modify | `RequestApproverList` |
| `src/components/client-lane/StatusPill.tsx` | modify | `ApproverPill` `opened` |
| `src/lib/client-lane/types.ts` | modify | `workspace.slug?`, `opened?`, error codes |
| `src/components/client-lane/DecisionPage.portal.test.tsx` | create | Portal context on the review page |
| `src/lib/client-lane/clients.ts` (+ `.test.ts`) | create | Clients-tab rules and copy, `BrandClient` |
| `src/lib/client-lane/approverSuggestions.ts` (+ `.test.ts`) | create | `ApproverSuggestion`, chip tags, view-only picks |
| `src/services/brand-clients.ts` (+ `.test.ts`) | create | Clients list/patch/link/remove, approver suggestions |
| `src/components/brands/settings/clients/ClientsTab.tsx` (+ `.test.tsx`) | create | The Clients tab (v2) |
| `src/components/brands/settings/clients/ClientAvatar.tsx`, `ClientRemoveModal.tsx`, `ClientsEmptyState.tsx` | create | v1 wrappers |
| `src/app/(dashboard)/brands/[id]/settings/members/page.tsx` | modify | Third PillTab behind the flag |
| `src/components/client-lane/agency/useApproverEmails.ts` | modify | Suggestions endpoint, subject-keyed |
| `src/components/client-lane/agency/ApproverEmailsField.tsx` (+ `.test.tsx`) | modify/create | Tags, inline upgrade, pick analytics |
| `src/components/client-lane/agency/RequestForm.tsx`, `RequestApprovalPanel.tsx` | modify | Hook arguments |
| `src/lib/client-lane/tokenHygiene.test.ts` | modify | New surfaces in the banned-class scan |
| `docs/prd/client-lane-p0a/web.md` | modify | `## Contract` section replaced from the api branch (Task 19) |

---
## Phase 1 — pure rules

### Task 0: Pre-flight — base branch, worktree, baselines, track file

**Files:**
- Create: `docs/tracks/client-portal.track.md`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - the worktree WT and its base (`BASE`);
  - `TSC_BASELINE`, per-file tsc counts and the per-file baseline test results, all recorded in the track.

  Every later gate compares against these.

- [ ] **Step 1: Find out whether the deck/plan branch has merged**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web && /usr/bin/git fetch origin && /usr/bin/git log --oneline -1 origin/develop && /usr/bin/git branch --list 'feature/daffa/vc-client-lane-deck-plan-requests' && (/usr/bin/git merge-base --is-ancestor feature/daffa/vc-client-lane-deck-plan-requests origin/develop && echo MERGED || echo NOT_MERGED)
```

Expected: the develop tip, then the local branch name, then `MERGED` or `NOT_MERGED`. As of 2026-10-06 the branch is local-only, so expect `NOT_MERGED`.

- [ ] **Step 2: Ask Daffa ONE question (AskUserQuestion) and wait**

Question: "Base for `feature/daffa/vc-client-portal` (web)? Step 1 printed <MERGED|NOT_MERGED>."

Options:
- (a) **"origin/develop"**: the deck/plan branch has merged. Recommended when Step 1 printed `MERGED`.
- (b) **"Stack on feature/daffa/vc-client-lane-deck-plan-requests"**: the portal builds on that branch's `RequestForm`, `RequestRail`, `DecisionPage` request entries and `subjectRequests.ts`. Recommended when Step 1 printed `NOT_MERGED`. The PR then targets that branch, or is rebased onto develop after it merges.

Set `BASE` to `origin/develop` or `feature/daffa/vc-client-lane-deck-plan-requests` from the answer. Do not continue without an answer.

- [ ] **Step 3: Create the worktree**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web && /usr/bin/git worktree add -b feature/daffa/vc-client-portal .worktrees/client-portal "$BASE"
```

Expected: `Preparing worktree (new branch 'feature/daffa/vc-client-portal')`. If the branch already exists, STOP and ask Daffa; never reset or delete it.

- [ ] **Step 4: Install and copy the env (memory: a worktree has no `node_modules` and no `.env.local`)**

```bash
cd /Users/alva.e202511001/Desktop/work/frndos-agentic/web/.worktrees/client-portal && bun install && cp ../../.env.local .env.local && /usr/bin/git status --short
```

Expected: the install finishes, and `git status --short` prints nothing (both are gitignored). If `web/.env.local` is missing, note it in the track. Tests do not need it, but `bun dev` would silently never call the api.

- [ ] **Step 5: Record the tsc baseline**

```bash
cd WT && ./node_modules/.bin/tsc --noEmit -p . > /tmp/client-portal-tsc-base.txt 2>&1; /usr/bin/grep -c "error TS" /tmp/client-portal-tsc-base.txt; /usr/bin/grep -oE "^src/[^(]+" /tmp/client-portal-tsc-base.txt | /usr/bin/grep -E "client-lane|middleware|settings/members|services/client-lane|analytics/client-lane" | sort | uniq -c
```

Expected: one number (the whole-project count; the last track recorded ≈895), plus per-file counts for the files this plan touches (often none). Write both into the track (Step 7).

- [ ] **Step 6: Run the baseline suites, one file per invocation**

```bash
cd WT && F=(src/lib/client-lane/round.test.ts src/lib/client-lane/pins.test.ts src/lib/client-lane/versionLabels.test.ts src/lib/client-lane/commentThreads.test.ts src/lib/client-lane/canvasApproval.test.ts src/lib/client-lane/subjectRequests.test.ts src/lib/client-lane/drain.test.ts src/lib/client-lane/planDecisions.test.ts src/lib/client-lane/requestDecision.test.ts src/lib/client-lane/recordPdf.test.ts src/lib/client-lane/requestRefresh.test.ts src/lib/client-lane/advisoryAnswer.test.ts src/lib/client-lane/tokenHygiene.test.ts src/services/client-lane.test.ts src/components/client-lane/DecisionPage.test.tsx src/components/client-lane/PinLayer.test.tsx src/components/client-lane/PinNotePopover.test.tsx src/components/client-lane/agency/ApprovalStatusBlock.test.tsx src/components/client-lane/agency/RequestLinkRow.test.tsx src/components/client-lane/agency/useArtboardThumbnailSync.test.ts src/components/client-lane/kv/KvLinkGallery.test.tsx src/components/client-lane/kv/KvRequestHero.test.tsx src/components/client-lane/kv/KvRoundHero.test.tsx src/components/client-lane/kv/KvShareBoardCanvas.test.tsx src/components/client-lane/kv/roundItems.test.ts src/components/client-lane/kv/swipe.test.ts src/middleware.kvShare.test.ts src/middleware.mobile.test.ts src/middleware.studio.test.ts src/lib/theme.test.ts src/components/frndos/v2/ActionMenu.test.tsx src/components/frndos/v2/ActionMenu.modal.test.tsx src/components/frndos/v2/SelectMenu.test.tsx src/components/frndos/v2/ItemRow.test.tsx); for f in "${F[@]}"; do echo "== $f"; [ -f "$f" ] || { echo MISSING; continue; }; bun test "$f" 2>&1 | /usr/bin/grep -E "^[[:space:]]*[0-9]+ (pass|fail)|^\(fail\)|[0-9]+ error"; done
```

Expected: pass/fail counts per file. A file printed as `MISSING` does not exist on this base; record that and drop it from the later gate lists. Record EVERY `(fail)` line name verbatim in the track. Later tasks compare their run of the same file against this list, and a failure that is not on the list is a regression.

- [ ] **Step 7: Write the track file**

Create `docs/tracks/client-portal.track.md`:

```markdown
---
prd: client-portal
parent_prd: docs/superpowers/specs/2026-10-06-client-portal-from-share-links-design.md
service: web
branch: feature/daffa/vc-client-portal
worktree: web/.worktrees/client-portal
base: <BASE> @ <short sha printed by `git rev-parse --short HEAD`>
flag: show-client-lane (Clients tab only; /s/* unflagged)
pr_url: null
status: in_progress
---

# Track — Client Lane: client portal from the share links (web)

Plan: `docs/superpowers/plans/2026-10-06-client-portal-web.md` (workspace root). The api half: `docs/superpowers/plans/2026-10-06-client-portal-api.md`, same branch name in `api/`; it deploys first (spec §8.2).

## Status

| Item | Status |
|------|--------|
| Spec | approved |
| Service PRD | n/a — spec + plan |
| Implementation | in_progress |
| PR | not_submitted |

## Baselines (Task 0)

- `tsc` errors, whole project: <N>
- `tsc` errors per touched file: <paste the uniq -c lines, or "none">
- Pre-existing test failures (one file per run): <file → failing test names, or "none">
- Missing on this base: <files printed MISSING, or "none">

## Task Checklist

- [x] Task 0: base, worktree, baselines, track
- [ ] Task 1: portal types + inbox display rules
- [ ] Task 2: shell rules + approver tone
- [ ] Task 3: sign-in state machine
- [ ] Task 4: session cookie + `?k=` on portal links
- [ ] Task 5: BFF portal proxy
- [ ] Task 6: share-link transport through the BFF
- [ ] Task 7: session routes (lane exchange, request-link code)
- [ ] Task 8: server `me` + browser portal service
- [ ] Task 9: analytics helpers
- [ ] Task 10: portal shell (header, nav, frame)
- [ ] Task 11: Approvals page + PortalApp
- [ ] Task 12: sign-in screen
- [ ] Task 13: portal route + exchange gate
- [ ] Task 14: review page portal context
- [ ] Task 15: Clients rules + agency services
- [ ] Task 16: Clients tab
- [ ] Task 17: approver picker
- [ ] Task 18: light-mode token pass
- [ ] Task 19: gates, manual pass, Lark rows, contract notes

## Session Log

### 2026-10-06 — daffa (plan executor)
- Task 0: worktree created on <BASE>, baselines recorded above.
```

Fill the `<…>` placeholders from Steps 1–6. Nothing may stay in angle brackets.

- [ ] **Step 8: Commit**

```bash
cd WT && /usr/bin/git add docs/tracks/client-portal.track.md && /usr/bin/git commit -F - <<'EOF'
docs(web): open track for the client portal

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 1: Portal wire types and inbox display rules

**Files:**
- Create: `src/lib/client-lane/portal/types.ts`
- Create: `src/lib/client-lane/portal/fixtures.ts`
- Create: `src/lib/client-lane/portal/inbox.ts`
- Test: `src/lib/client-lane/portal/inbox.test.ts`

**Interfaces:**
- Consumes: `deferralDate`, `shortWhen` (`src/lib/client-lane/format.ts`); `relativeTime(iso, { now })` (`src/lib/deck/relativeTime.ts`); `SUBJECT_NOUN` (`src/lib/client-lane/subjectRequests.ts`: `kv_file` → "Key visual", `deck` → "Deck", `campaign` → "Campaign plan").
- Produces:
  - types: `ClientAccessLevel`, `CLIENT_ACCESS_LEVELS`, `PortalBrand`, `PortalMe`, `PortalItem`, `PortalApprovals`, `PortalGroup`, `PortalSession`;
  - fixtures: `portalBrand()`, `portalMe()`, `portalItem()`, `portalApprovals()`;
  - from `inbox.ts`: `ACCESS_LEVEL_LABEL`, `joinNames`, `summaryLine`, `subjectLine`, `requestedLine`, `decideByLine`, `progressLine`, `weekdayOf`, `waitingOnOthersLine`, `decidedTitle`, `decidedLine`, `PortalApprovalsView`, `mergeApprovalPages`, `isPortalEmpty`, `emptyStateText`, `viewOnlyNotice`.

- [ ] **Step 1: Write the types and fixtures (no logic, nothing to fail yet)**

Create `src/lib/client-lane/portal/types.ts`:

```ts
/**
 * Wire types of the client portal (spec 2026-10-06 portal §5). Snake_case,
 * no mapping layer — a shape change here is a contract change first. Fields
 * marked (assumed) are the web's reading; see the plan's "API contract
 * assumed" section.
 */
import type {
  ApprovalStatus,
  DecisionOutcome,
  ShareSubjectType,
} from "../types";

/** Spec P-6: own requests / all + approve / all, view only. */
export type ClientAccessLevel = "own" | "all_approve" | "all_view";

export const CLIENT_ACCESS_LEVELS: readonly ClientAccessLevel[] = [
  "own",
  "all_approve",
  "all_view",
];

/** One brand the person has an active lane on (`GET public/portal/me`). */
export interface PortalBrand {
  workspace: { name: string; slug: string };
  brand: { name: string; slug: string; logo_url: string | null };
  access_level: ClientAccessLevel;
  waiting_on_you: number;
}

export interface PortalMe {
  user: { name: string; email: string };
  brands: PortalBrand[];
}

/** One request in the inbox (spec §5.2 `Item`). */
export interface PortalItem {
  request_id: string;
  number: number;
  /** "/s/{token}" — the request link. */
  url: string;
  subject: {
    type: ShareSubjectType;
    title: string;
    thumbnail_url: string | null;
    /** (assumed) "v4"; absent → "Request {number}". */
    version_label?: string | null;
  };
  item_count: number;
  /** First line of the agency message, ≤ 120 chars. */
  message_line: string | null;
  requested_by: { name: string };
  sent_at: string | null;
  decide_by: string | null;
  my_role: "approver" | "viewer";
  /** (assumed) The viewer's own latest decision on this request. */
  my_decision?: { outcome: DecisionOutcome; at: string } | null;
  approvers: Array<{ name: string; decided: boolean; opened: boolean }>;
  counts: { decided: number; total: number };
  status: ApprovalStatus;
  resolved_at: string | null;
  /** Decided only. */
  outcome_line: null | {
    outcome: DecisionOutcome | ApprovalStatus;
    by: string;
    at: string;
    note_excerpt: string | null;
  };
}

/** `GET public/portal/{workspace}/{brand}/approvals` (spec §5.2). */
export interface PortalApprovals {
  brand: {
    name: string;
    slug: string;
    workspace: string;
    logo_url: string | null;
  };
  access_level: ClientAccessLevel;
  waiting_on_you: PortalItem[];
  waiting_on_others: PortalItem[];
  decided: PortalItem[];
  decided_next_cursor: string | null;
}

export type PortalGroup = "waiting_on_you" | "waiting_on_others" | "decided";

/** What a server component hands the review page when a session holds a
 *  lane on the link's brand (spec §6.5). Never carries the token. */
export interface PortalSession {
  me: PortalMe;
  brand: PortalBrand;
}
```

Create `src/lib/client-lane/portal/fixtures.ts`:

```ts
/**
 * Builders for portal tests. Plain data, no logic — every test overrides
 * only what its rule reads.
 */
import type {
  PortalApprovals,
  PortalBrand,
  PortalItem,
  PortalMe,
} from "./types";

export function portalBrand(overrides: Partial<PortalBrand> = {}): PortalBrand {
  return {
    workspace: { name: "FCN", slug: "fcn" },
    brand: { name: "frndGlow", slug: "frndglow", logo_url: null },
    access_level: "all_approve",
    waiting_on_you: 1,
    ...overrides,
  };
}

export function portalMe(overrides: Partial<PortalMe> = {}): PortalMe {
  return {
    user: { name: "Dina Pratiwi", email: "dina@tokopedia.com" },
    brands: [portalBrand()],
    ...overrides,
  };
}

export function portalItem(overrides: Partial<PortalItem> = {}): PortalItem {
  return {
    request_id: "req1",
    number: 2,
    url: "/s/tok1",
    subject: {
      type: "kv_file",
      title: "Ramadan hero",
      thumbnail_url: null,
      version_label: null,
    },
    item_count: 3,
    message_line: "Three artboards for the Ramadan push.",
    requested_by: { name: "Andi" },
    sent_at: "2026-10-05T09:00:00.000Z",
    decide_by: "2026-10-10",
    my_role: "approver",
    my_decision: null,
    approvers: [{ name: "Dina Pratiwi", decided: false, opened: true }],
    counts: { decided: 0, total: 3 },
    status: "pending",
    resolved_at: null,
    outcome_line: null,
    ...overrides,
  };
}

export function portalApprovals(
  overrides: Partial<PortalApprovals> = {}
): PortalApprovals {
  return {
    brand: {
      name: "frndGlow",
      slug: "frndglow",
      workspace: "FCN",
      logo_url: null,
    },
    access_level: "all_approve",
    waiting_on_you: [],
    waiting_on_others: [],
    decided: [],
    decided_next_cursor: null,
    ...overrides,
  };
}
```

- [ ] **Step 2: Write the failing test**

Create `src/lib/client-lane/portal/inbox.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import { deferralDate, shortWhen } from "../format";

import { portalApprovals, portalItem } from "./fixtures";
import {
  ACCESS_LEVEL_LABEL,
  decidedLine,
  decidedTitle,
  emptyStateText,
  isPortalEmpty,
  joinNames,
  mergeApprovalPages,
  requestedLine,
  summaryLine,
  viewOnlyNotice,
  waitingOnOthersLine,
  weekdayOf,
} from "./inbox";

describe("ACCESS_LEVEL_LABEL (spec §7.2)", () => {
  it("names the three levels as the Clients tab and picker say them", () => {
    expect(ACCESS_LEVEL_LABEL).toEqual({
      own: "Own requests",
      all_approve: "All requests + approve",
      all_view: "All requests, view only",
    });
  });
});

describe("joinNames", () => {
  it("reads one, two and many names as a sentence", () => {
    expect(joinNames([])).toBe("");
    expect(joinNames(["Andi"])).toBe("Andi");
    expect(joinNames(["Andi", "Bo"])).toBe("Andi and Bo");
    expect(joinNames(["Andi", "Bo", "Cy"])).toBe("Andi, Bo and Cy");
  });
});

describe("summaryLine (spec §6.3)", () => {
  it("says nothing is waiting when the group is empty", () => {
    expect(summaryLine([])).toBe("Nothing is waiting on you.");
  });

  it("names the one item, its artboards and its date", () => {
    expect(summaryLine([portalItem()])).toBe(
      `One thing is waiting on you: Ramadan hero, 3 artboards, by ${deferralDate("2026-10-10")}.`
    );
  });

  it("says one artboard in the singular", () => {
    expect(summaryLine([portalItem({ item_count: 1, decide_by: null })])).toBe(
      "One thing is waiting on you: Ramadan hero, 1 artboard."
    );
  });

  it("never says artboards for a deck", () => {
    expect(
      summaryLine([
        portalItem({
          subject: { type: "deck", title: "Q4 deck", thumbnail_url: null },
          item_count: 1,
          decide_by: null,
        }),
      ])
    ).toBe("One thing is waiting on you: Q4 deck.");
  });

  it("counts several", () => {
    expect(summaryLine([portalItem(), portalItem({ request_id: "r2" })])).toBe(
      "2 things are waiting on you."
    );
  });
});

describe("requestedLine", () => {
  it("says who asked and how long ago", () => {
    expect(
      requestedLine(portalItem(), new Date("2026-10-05T11:00:00.000Z"))
    ).toBe("requested by Andi · 2 hours ago");
  });
});

describe("waitingOnOthersLine (spec §6.3)", () => {
  it("reads an approver's own answer, who is left and by when", () => {
    const item = portalItem({
      subject: { type: "deck", title: "Campaign deck", thumbnail_url: null },
      my_decision: { outcome: "approved", at: "2026-10-05T09:00:00.000Z" },
      approvers: [
        { name: "Dina Pratiwi", decided: true, opened: true },
        { name: "Andi", decided: false, opened: false },
      ],
      decide_by: "2026-10-09",
      counts: { decided: 1, total: 2 },
    });
    expect(waitingOnOthersLine(item)).toBe(
      `You approved ${weekdayOf("2026-10-05T09:00:00.000Z")} · Andi decides by ${deferralDate("2026-10-09")} · 1 of 2`
    );
  });

  it("reads a viewer's row as who it waits on", () => {
    const item = portalItem({
      my_role: "viewer",
      approvers: [{ name: "Andi", decided: false, opened: true }],
      counts: { decided: 0, total: 1 },
    });
    expect(waitingOnOthersLine(item)).toBe("Waiting on Andi · 0 of 1");
  });

  it("puts several undecided approvers in the plural", () => {
    const item = portalItem({
      my_decision: { outcome: "changes_required", at: "2026-10-05T09:00:00.000Z" },
      approvers: [
        { name: "Andi", decided: false, opened: false },
        { name: "Bo", decided: false, opened: true },
      ],
      decide_by: "2026-10-09",
      counts: { decided: 1, total: 3 },
    });
    expect(waitingOnOthersLine(item)).toBe(
      `You asked for changes ${weekdayOf("2026-10-05T09:00:00.000Z")} · Andi and Bo decide by ${deferralDate("2026-10-09")} · 1 of 3`
    );
  });
});

describe("decided rows", () => {
  it("titles a decided row with its version, else its request number", () => {
    expect(
      decidedTitle(
        portalItem({
          subject: {
            type: "deck",
            title: "Q4 deck",
            thumbnail_url: null,
            version_label: "v4",
          },
        })
      )
    ).toBe("Q4 deck · v4");
    expect(decidedTitle(portalItem())).toBe("Ramadan hero · Request 2");
  });

  it("says who decided, when, and quotes the note", () => {
    const at = "2026-10-01T09:00:00.000Z";
    expect(
      decidedLine(
        portalItem({
          status: "changes_required",
          outcome_line: {
            outcome: "changes_required",
            by: "Andi",
            at,
            note_excerpt: "Logo smaller",
          },
        })
      )
    ).toBe(`Andi · ${shortWhen(at)} · “Logo smaller”`);
  });
});

describe("mergeApprovalPages", () => {
  const d1 = portalItem({ request_id: "d1", status: "approved" });
  const d2 = portalItem({ request_id: "d2", status: "approved" });

  it("keeps the waiting groups of the first page and appends older decided rows once", () => {
    const view = mergeApprovalPages([
      portalApprovals({
        waiting_on_you: [portalItem()],
        decided: [d1],
        decided_next_cursor: "c1",
      }),
      portalApprovals({ decided: [d1, d2], decided_next_cursor: null }),
    ]);
    expect(view?.waiting_on_you.map((i) => i.request_id)).toEqual(["req1"]);
    expect(view?.decided.map((i) => i.request_id)).toEqual(["d1", "d2"]);
    expect(view?.hasOlder).toBe(false);
  });

  it("offers older rows while the last page has a cursor", () => {
    expect(
      mergeApprovalPages([portalApprovals({ decided_next_cursor: "c1" })])
        ?.hasOlder
    ).toBe(true);
  });

  it("is null before the first page lands", () => {
    expect(mergeApprovalPages([])).toBeNull();
  });
});

describe("empty and view-only copy (spec §6.3)", () => {
  it("is empty only when every group is empty and nothing older exists", () => {
    const empty = mergeApprovalPages([portalApprovals()]);
    expect(empty && isPortalEmpty(empty)).toBe(true);
    const older = mergeApprovalPages([
      portalApprovals({ decided_next_cursor: "c1" }),
    ]);
    expect(older && isPortalEmpty(older)).toBe(false);
  });

  it("names the workspace and the brand", () => {
    expect(emptyStateText("FCN", "frndGlow")).toBe(
      "Nothing from FCN for frndGlow yet."
    );
    expect(viewOnlyNotice("FCN", "frndGlow")).toBe(
      "You can view everything FCN sends for frndGlow. Ask FCN if you need to approve."
    );
  });
});
```

Mutations, one per rule:
- Drop the `kv_file` guard in `summaryLine`, and "never says artboards for a deck" fails.
- Return `"0 things…"` for an empty group, and "says nothing is waiting" fails.
- Concatenate decided rows without the `seen` set, and "appends older decided rows once" fails (`["d1","d1","d2"]`).
- Use `waiting.length` for the verb without the singular branch, and the first `waitingOnOthersLine` test fails.
- Drop the `my_role === "viewer"` branch, and "reads a viewer's row" fails.

- [ ] **Step 3: Run it to verify it fails**

Run: `cd WT && bun test src/lib/client-lane/portal/inbox.test.ts`
Expected: FAIL, with one `error` line: `Cannot find module './inbox'` (or similar).

- [ ] **Step 4: Write the implementation**

Create `src/lib/client-lane/portal/inbox.ts`:

```ts
/**
 * What the portal's Approvals page says (spec 2026-10-06 portal §6.3). Pure —
 * no React, no api. Every sentence the page renders is built here, so the
 * copy rules ("artboards" only for a key visual, a viewer's row reads
 * "Waiting on …") are tested once and the components only place them.
 */
import { relativeTime } from "@/lib/deck/relativeTime";

import { deferralDate, shortWhen } from "../format";
import { SUBJECT_NOUN } from "../subjectRequests";
import type { DecisionOutcome } from "../types";

import type { ClientAccessLevel, PortalApprovals, PortalItem } from "./types";

export const ACCESS_LEVEL_LABEL: Record<ClientAccessLevel, string> = {
  own: "Own requests",
  all_approve: "All requests + approve",
  all_view: "All requests, view only",
};

/** "Andi" / "Andi and Bo" / "Andi, Bo and Cy". */
export function joinNames(names: readonly string[]): string {
  if (names.length <= 1) return names[0] ?? "";
  return `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]}`;
}

function artboards(count: number): string {
  return `${count} ${count === 1 ? "artboard" : "artboards"}`;
}

/** The line under the page title. */
export function summaryLine(waiting: readonly PortalItem[]): string {
  if (waiting.length === 0) return "Nothing is waiting on you.";
  if (waiting.length > 1) return `${waiting.length} things are waiting on you.`;
  const [item] = waiting;
  const parts = [item.subject.title];
  if (item.subject.type === "kv_file") parts.push(artboards(item.item_count));
  if (item.decide_by) parts.push(`by ${deferralDate(item.decide_by)}`);
  return `One thing is waiting on you: ${parts.join(", ")}.`;
}

/** "Ramadan hero · Key visual" — a waiting card's title line. */
export function subjectLine(item: PortalItem): string {
  return `${item.subject.title} · ${SUBJECT_NOUN[item.subject.type].label}`;
}

/** "requested by Andi · 2 hours ago". */
export function requestedLine(item: PortalItem, now: Date = new Date()): string {
  const who = `requested by ${item.requested_by.name}`;
  return item.sent_at ? `${who} · ${relativeTime(item.sent_at, { now })}` : who;
}

export function decideByLine(item: PortalItem): string | null {
  return item.decide_by ? `Decide by ${deferralDate(item.decide_by)}` : null;
}

export function progressLine(item: PortalItem): string {
  return `${item.counts.decided} of ${item.counts.total} decided`;
}

/** "Mon" — the weekday of an answer, in the viewer's locale. */
export function weekdayOf(iso: string): string {
  const d = new Date(iso);
  return Number.isNaN(d.getTime())
    ? ""
    : d.toLocaleDateString(undefined, { weekday: "short" });
}

const MY_VERB: Record<DecisionOutcome, string> = {
  approved: "approved",
  approved_with_changes: "approved with fixes",
  changes_required: "asked for changes",
  deferred: "asked for more time",
};

/**
 * A waiting-on-others row: "You approved Mon · Andi decides by Fri · 1 of 2".
 * A viewer (all_view / all_approve, not named) reads "Waiting on Andi".
 */
export function waitingOnOthersLine(item: PortalItem): string {
  const parts: string[] = [];
  const waiting = item.approvers.filter((a) => !a.decided).map((a) => a.name);
  if (item.my_role === "viewer") {
    parts.push(
      waiting.length > 0
        ? `Waiting on ${joinNames(waiting)}`
        : "Waiting on the team"
    );
  } else {
    if (item.my_decision) {
      parts.push(
        `You ${MY_VERB[item.my_decision.outcome]} ${weekdayOf(item.my_decision.at)}`.trim()
      );
    }
    if (waiting.length > 0) {
      parts.push(
        item.decide_by
          ? `${joinNames(waiting)} ${waiting.length === 1 ? "decides" : "decide"} by ${deferralDate(item.decide_by)}`
          : `Waiting on ${joinNames(waiting)}`
      );
    }
  }
  parts.push(`${item.counts.decided} of ${item.counts.total}`);
  return parts.join(" · ");
}

/** "Q4 deck · v4" — falls back to the request number. */
export function decidedTitle(item: PortalItem): string {
  return item.subject.version_label
    ? `${item.subject.title} · ${item.subject.version_label}`
    : `${item.subject.title} · Request ${item.number}`;
}

/** "Andi · 1 Oct · “Logo smaller”". */
export function decidedLine(item: PortalItem): string {
  const line = item.outcome_line;
  if (!line) return shortWhen(item.resolved_at);
  return [
    line.by,
    shortWhen(line.at),
    line.note_excerpt ? `“${line.note_excerpt}”` : null,
  ]
    .filter((part): part is string => Boolean(part))
    .join(" · ");
}

export interface PortalApprovalsView {
  brand: PortalApprovals["brand"];
  access_level: ClientAccessLevel;
  waiting_on_you: PortalItem[];
  waiting_on_others: PortalItem[];
  decided: PortalItem[];
  /** The last page still has a `decided_next_cursor` ("Show older"). */
  hasOlder: boolean;
}

/**
 * The pages of the decided cursor as one view. The waiting groups come from
 * the FIRST page (later pages repeat or omit them); decided rows append in
 * page order, each request once.
 */
export function mergeApprovalPages(
  pages: readonly PortalApprovals[]
): PortalApprovalsView | null {
  if (pages.length === 0) return null;
  const [first] = pages;
  const last = pages[pages.length - 1];
  const seen = new Set<string>();
  const decided: PortalItem[] = [];
  for (const page of pages) {
    for (const item of page.decided) {
      if (seen.has(item.request_id)) continue;
      seen.add(item.request_id);
      decided.push(item);
    }
  }
  return {
    brand: first.brand,
    access_level: first.access_level,
    waiting_on_you: first.waiting_on_you,
    waiting_on_others: first.waiting_on_others,
    decided,
    hasOlder: last.decided_next_cursor !== null,
  };
}

export function isPortalEmpty(view: PortalApprovalsView): boolean {
  return (
    view.waiting_on_you.length === 0 &&
    view.waiting_on_others.length === 0 &&
    view.decided.length === 0 &&
    !view.hasOlder
  );
}

export function emptyStateText(workspace: string, brand: string): string {
  return `Nothing from ${workspace} for ${brand} yet.`;
}

export function viewOnlyNotice(workspace: string, brand: string): string {
  return `You can view everything ${workspace} sends for ${brand}. Ask ${workspace} if you need to approve.`;
}
```

- [ ] **Step 5: Run the test to verify it passes, then prove each named mutation**

Run: `cd WT && bun test src/lib/client-lane/portal/inbox.test.ts`
Expected: PASS, with no `error` line. If `requestedLine` prints anything other than `2 hours ago`, recompute it from `relativeTime` (date-fns `formatDistanceStrict`) and fix the expectation, not the code. Apply each mutation listed under Step 2, watch the named test fail, and restore.

- [ ] **Step 6: Lint, format, commit**

```bash
cd WT && F=(src/lib/client-lane/portal/types.ts src/lib/client-lane/portal/fixtures.ts src/lib/client-lane/portal/inbox.ts src/lib/client-lane/portal/inbox.test.ts) && ./node_modules/.bin/prettier --write "${F[@]}" && ./node_modules/.bin/eslint "${F[@]}" && /usr/bin/git add "${F[@]}" && /usr/bin/git commit -F - <<'EOF'
feat(web): portal wire types and inbox display rules

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 2: Shell rules and the approver tone

**Files:**
- Create: `src/lib/client-lane/portal/shell.ts`
- Test: `src/lib/client-lane/portal/shell.test.ts`
- Modify: `src/lib/client-lane/statusTone.ts` (append after `DECIDED_TONE`)
- Test: `src/lib/client-lane/statusTone.approver.test.ts`

**Interfaces:**
- Consumes: `PortalBrand`, `PortalMe` (Task 1); `ShareLinkData` (`src/lib/client-lane/types.ts`).
- Produces:
  - `brandKey(b)`: `"{ws}/{brand}"`;
  - `portalHref(b)`: `"/s/{ws}/{brand}"`, encoded;
  - `brandTitle(b)`: "frndGlow · via FCN";
  - `showSwitcher(me)`;
  - `switcherOptions(me)`: `Array<{ value: string; label: string; count?: number }>`;
  - `findPortalBrand(me, ws, brand)`;
  - `portalBrandForShare(me, share)`;
  - `portalIdentityLine(me, brand)`: `string | null`;
  - `PortalErrorAction = "sign_in" | "retry"`;
  - `portalErrorAction(status: number | null)`;
  - in `statusTone.ts`: `OPENED_TONE`, `NOT_OPENED_TONE`, `approverTone(decided: boolean, opened?: boolean): Tone`.

- [ ] **Step 1: Write the failing tests**

Create `src/lib/client-lane/portal/shell.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import { deckRequestLink } from "../testFixtures";

import { portalBrand, portalMe } from "./fixtures";
import {
  brandTitle,
  findPortalBrand,
  portalBrandForShare,
  portalErrorAction,
  portalHref,
  portalIdentityLine,
  showSwitcher,
  switcherOptions,
} from "./shell";

const garuda = portalBrand({
  workspace: { name: "Alva", slug: "alva" },
  brand: { name: "Garuda", slug: "garuda", logo_url: null },
  waiting_on_you: 0,
});

describe("brand switcher (spec §6.2)", () => {
  it("shows only for a client of more than one brand", () => {
    expect(showSwitcher(portalMe())).toBe(false);
    expect(showSwitcher(portalMe({ brands: [portalBrand(), garuda] }))).toBe(
      true
    );
  });

  it("lists each brand with its waiting count, none for zero", () => {
    expect(
      switcherOptions(portalMe({ brands: [portalBrand(), garuda] }))
    ).toEqual([
      { value: "fcn/frndglow", label: "frndGlow · via FCN", count: 1 },
      { value: "alva/garuda", label: "Garuda · via Alva", count: undefined },
    ]);
    expect(brandTitle(garuda)).toBe("Garuda · via Alva");
  });
});

describe("portalHref", () => {
  it("encodes both slugs", () => {
    expect(portalHref(garuda)).toBe("/s/alva/garuda");
    expect(
      portalHref(
        portalBrand({
          workspace: { name: "A B", slug: "a b" },
          brand: { name: "C", slug: "c/d", logo_url: null },
        })
      )
    ).toBe("/s/a%20b/c%2Fd");
  });
});

describe("findPortalBrand", () => {
  it("needs both slugs to match — brand slugs repeat across workspaces", () => {
    const sameSlug = portalBrand({
      workspace: { name: "Other", slug: "other" },
    });
    const me = portalMe({ brands: [sameSlug, portalBrand()] });
    expect(findPortalBrand(me, "fcn", "frndglow")).toBe(me.brands[1]);
    expect(findPortalBrand(me, "nope", "frndglow")).toBeNull();
  });
});

describe("portalBrandForShare (spec §6.5)", () => {
  const me = portalMe({ brands: [portalBrand(), garuda] });

  it("matches the link's brand by workspace slug when the api sends one", () => {
    const share = deckRequestLink({
      workspace: { name: "Renamed", slug: "alva" },
    });
    expect(portalBrandForShare(me, share)).toBe(garuda);
  });

  it("falls back to the workspace name on an api without slugs", () => {
    expect(portalBrandForShare(me, deckRequestLink())).toBe(garuda);
  });

  it("is null for a brand this person has no lane on", () => {
    expect(
      portalBrandForShare(portalMe(), deckRequestLink())
    ).toBeNull();
  });
});

describe("portalIdentityLine", () => {
  it("says who decides, except for a view-only client", () => {
    expect(portalIdentityLine(portalMe(), portalBrand())).toBe(
      "Deciding as Dina Pratiwi"
    );
    expect(
      portalIdentityLine(portalMe(), portalBrand({ access_level: "all_view" }))
    ).toBeNull();
  });
});

describe("portalErrorAction (spec §4.4, §8.1)", () => {
  it("sends a lost session or a lost brand back to sign-in", () => {
    expect(portalErrorAction(401)).toBe("sign_in");
    expect(portalErrorAction(404)).toBe("sign_in");
  });

  it("retries anything else", () => {
    expect(portalErrorAction(500)).toBe("retry");
    expect(portalErrorAction(null)).toBe("retry");
  });
});
```

`deckRequestLink()` has `workspace: { name: "Alva" }` and `brand.slug: "garuda"` (`src/lib/client-lane/testFixtures.ts`). The `slug` override type-checks only after Task 14 widens `workspace`. Until then, cast that one fixture: `{ name: "Renamed", slug: "alva" } as { name: string }`. Task 14 removes the cast.

Create `src/lib/client-lane/statusTone.approver.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import { approverTone } from "./statusTone";

describe("approverTone (spec §6.5)", () => {
  it("reads decided first, then opened, then not opened", () => {
    expect(approverTone(true, false).label).toBe("Decided");
    expect(approverTone(false, true).label).toBe("Opened");
    expect(approverTone(false, false).label).toBe("Not opened");
  });

  it("keeps the agency's Waiting when no opened state is known", () => {
    expect(approverTone(false).label).toBe("Waiting");
  });
});
```

Mutations:
- `showSwitcher` → `>= 1`, and "shows only for a client of more than one brand" fails.
- In `switcherOptions`, `count: b.waiting_on_you` (zero kept), and "lists each brand…" fails.
- `findPortalBrand` matching the brand slug only, and "needs both slugs" fails.
- `portalBrandForShare` ignoring the slug, and "matches … by workspace slug" fails (the name "Renamed" ≠ "Alva").
- `portalErrorAction(404)` → `"retry"`, and "sends a lost … brand back" fails.
- `approverTone` checking `opened` before `decided`, and "reads decided first…" fails: `(true, false)` then reads "Not opened".

- [ ] **Step 2: Run them to verify they fail**

Run: `cd WT && bun test src/lib/client-lane/portal/shell.test.ts`, then `bun test src/lib/client-lane/statusTone.approver.test.ts`
Expected: both FAIL. `./shell` is not found, and `approverTone` is not a function.

- [ ] **Step 3: Write the implementation**

Create `src/lib/client-lane/portal/shell.ts`:

```ts
/**
 * The portal shell's rules (spec 2026-10-06 portal §6.2, §6.5): which brands
 * the switcher lists, where a brand's portal lives, which portal brand a
 * share link belongs to, who the review page decides as, and what a failed
 * portal call means. Pure.
 */
import type { ShareLinkData } from "../types";

import type { PortalBrand, PortalMe } from "./types";

type Slugs = Pick<PortalBrand, "workspace" | "brand">;

export function brandKey(b: Slugs): string {
  return `${b.workspace.slug}/${b.brand.slug}`;
}

export function portalHref(b: Slugs): string {
  return `/s/${encodeURIComponent(b.workspace.slug)}/${encodeURIComponent(b.brand.slug)}`;
}

/** "frndGlow · via FCN". */
export function brandTitle(b: PortalBrand): string {
  return `${b.brand.name} · via ${b.workspace.name}`;
}

export function showSwitcher(me: PortalMe): boolean {
  return me.brands.length > 1;
}

/** `SelectMenu` options — structurally its `SelectMenuOption` (no import: lib never depends on a component). */
export function switcherOptions(
  me: PortalMe
): Array<{ value: string; label: string; count?: number }> {
  return me.brands.map((b) => ({
    value: brandKey(b),
    label: brandTitle(b),
    count: b.waiting_on_you > 0 ? b.waiting_on_you : undefined,
  }));
}

export function findPortalBrand(
  me: PortalMe,
  workspaceSlug: string,
  brandSlug: string
): PortalBrand | null {
  return (
    me.brands.find(
      (b) => b.workspace.slug === workspaceSlug && b.brand.slug === brandSlug
    ) ?? null
  );
}

/**
 * The portal brand a share link belongs to. Brand slugs are unique per
 * workspace only, so the workspace must match too — by slug when C-1 sends
 * one (assumed), else by name.
 */
export function portalBrandForShare(
  me: PortalMe,
  share: Pick<ShareLinkData, "brand" | "workspace">
): PortalBrand | null {
  const wsSlug = (share.workspace as { slug?: string }).slug;
  return (
    me.brands.find(
      (b) =>
        b.brand.slug === share.brand.slug &&
        (wsSlug
          ? b.workspace.slug === wsSlug
          : b.workspace.name === share.workspace.name)
    ) ?? null
  );
}

/** "Deciding as Dina" — none for view-only (the notice says it instead). */
export function portalIdentityLine(
  me: PortalMe,
  brand: PortalBrand
): string | null {
  return brand.access_level === "all_view"
    ? null
    : `Deciding as ${me.user.name}`;
}

export type PortalErrorAction = "sign_in" | "retry";

/**
 * 401 = the session is gone; 404 = this brand is gone for this person (lane
 * revoked, role removed — spec §4.4 answers both without a hint). Either way
 * the page goes back to sign-in; anything else is worth a retry.
 */
export function portalErrorAction(status: number | null): PortalErrorAction {
  return status === 401 || status === 404 ? "sign_in" : "retry";
}
```

Task 14 types `workspace.slug` properly. Until then the `(share.workspace as { slug?: string })` cast is needed, and Task 14 removes it.

Append to `src/lib/client-lane/statusTone.ts`, right after `export const DECIDED_TONE…`:

```ts
/** A named approver who opened the request link (spec 2026-10-06 portal §6.5). */
export const OPENED_TONE: Tone = { variant: "alert", label: "Opened" };

export const NOT_OPENED_TONE: Tone = { variant: "neutral", label: "Not opened" };

/**
 * A named approver's pill. `opened` undefined = the caller has no view data
 * (the agency surfaces) → the old Waiting.
 */
export function approverTone(decided: boolean, opened?: boolean): Tone {
  if (decided) return DECIDED_TONE;
  if (opened === undefined) return WAITING_TONE;
  return opened ? OPENED_TONE : NOT_OPENED_TONE;
}
```

- [ ] **Step 4: Run the tests to verify they pass, then prove each named mutation**

Run: `cd WT && bun test src/lib/client-lane/portal/shell.test.ts`, then `bun test src/lib/client-lane/statusTone.approver.test.ts`
Expected: PASS, with no `error` line. Apply each mutation, watch its test fail, and restore.

- [ ] **Step 5: Lint, format, commit**

`statusTone.ts` is an existing file. Check that it is prettier-clean on BASE before formatting it (Global Constraints).

```bash
cd WT && F=(src/lib/client-lane/portal/shell.ts src/lib/client-lane/portal/shell.test.ts src/lib/client-lane/statusTone.ts src/lib/client-lane/statusTone.approver.test.ts) && ./node_modules/.bin/prettier --write src/lib/client-lane/portal/shell.ts src/lib/client-lane/portal/shell.test.ts src/lib/client-lane/statusTone.approver.test.ts && ./node_modules/.bin/eslint "${F[@]}" && /usr/bin/git add "${F[@]}" && /usr/bin/git commit -F - <<'EOF'
feat(web): portal shell rules and the opened/not-opened approver tone

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 3: Sign-in state machine

**Files:**
- Create: `src/lib/client-lane/portal/signIn.ts`
- Test: `src/lib/client-lane/portal/signIn.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - constants: `PORTAL_CODE_LENGTH = 6`, `PORTAL_RESEND_SECONDS = 60`;
  - types: `SignInError`, `SignInState`, `SignInEvent`;
  - `initialSignIn`, `isEmail(value)`, `signInReducer(state, event)`;
  - `signInErrorText(state)`: `string | null`;
  - `canResend(state, now)` and `resendLabel(state, now)`.

- [ ] **Step 1: Write the failing test**

Create `src/lib/client-lane/portal/signIn.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import {
  canResend,
  initialSignIn,
  resendLabel,
  signInErrorText,
  signInReducer,
  type SignInEvent,
  type SignInState,
} from "./signIn";

const run = (events: SignInEvent[], from: SignInState = initialSignIn) =>
  events.reduce(signInReducer, from);

describe("signInReducer (spec §5.3, §6.4)", () => {
  it("refuses a malformed address without leaving the email step", () => {
    const state = run([{ type: "send", email: "dina" }]);
    expect(state).toMatchObject({
      step: "email",
      sending: false,
      error: "invalid_email",
    });
    expect(signInErrorText(state)).toBe("Enter a valid email address.");
  });

  it("goes to the code step only once the code is sent", () => {
    const sending = run([{ type: "send", email: " dina@brand.co " }]);
    expect(sending).toMatchObject({
      step: "email",
      sending: true,
      email: "dina@brand.co",
    });
    const sent = signInReducer(sending, { type: "sent", at: 1_000 });
    expect(sent).toMatchObject({ step: "code", sending: false, resendAt: 61_000 });
  });

  it("stays on the email step after a failed send and says why", () => {
    const state = run([
      { type: "send", email: "dina@brand.co" },
      { type: "send_failed", reason: "throttled" },
    ]);
    expect(state.step).toBe("email");
    expect(signInErrorText(state)).toBe(
      "Too many tries. Wait a minute and try again."
    );
  });

  it("counts the tries left on a wrong code", () => {
    const atCode = run([
      { type: "send", email: "dina@brand.co" },
      { type: "sent", at: 0 },
      { type: "verify" },
    ]);
    const two = signInReducer(atCode, {
      type: "verify_failed",
      reason: "invalid_code",
      attemptsLeft: 2,
    });
    expect(signInErrorText(two)).toBe("That code didn't match — 2 tries left.");
    const one = signInReducer(atCode, {
      type: "verify_failed",
      reason: "invalid_code",
      attemptsLeft: 1,
    });
    expect(signInErrorText(one)).toBe("That code didn't match — 1 try left.");
    expect(one.verifying).toBe(false);
  });

  it("lets an expired code be replaced at once", () => {
    const expired = run([
      { type: "send", email: "dina@brand.co" },
      { type: "sent", at: 0 },
      { type: "verify" },
      { type: "verify_failed", reason: "code_expired" },
    ]);
    expect(canResend(expired, 5_000)).toBe(true);
    expect(resendLabel(expired, 5_000)).toBe("Send a new code");
  });

  it("holds the resend until the countdown ends", () => {
    const sent = run([
      { type: "send", email: "dina@brand.co" },
      { type: "sent", at: 0 },
    ]);
    expect(canResend(sent, 30_000)).toBe(false);
    expect(resendLabel(sent, 30_000)).toBe("Resend in 30s");
    expect(canResend(sent, 60_000)).toBe(true);
    expect(resendLabel(sent, 60_000)).toBe("Resend code");
  });

  it("ignores a second verify while one is in flight", () => {
    const verifying = run([
      { type: "send", email: "dina@brand.co" },
      { type: "sent", at: 0 },
      { type: "verify" },
    ]);
    expect(signInReducer(verifying, { type: "verify" })).toBe(verifying);
  });

  it("goes back to the email step keeping the address", () => {
    const back = run([
      { type: "send", email: "dina@brand.co" },
      { type: "sent", at: 0 },
      { type: "change_email" },
    ]);
    expect(back).toMatchObject({ step: "email", email: "dina@brand.co", error: null });
  });
});
```

Mutations:
- Drop the `isEmail` guard in `send`, and "refuses a malformed address" fails.
- Set `step: "code"` on `send`, and "goes to the code step only once the code is sent" fails.
- Drop the `code_expired` clause in `canResend`, and "lets an expired code be replaced at once" fails.
- Ignore `attemptsLeft`, and "counts the tries left" fails.
- Remove the in-flight guard in `verify`, and "ignores a second verify" fails (new object).

- [ ] **Step 2: Run it to verify it fails**

Run: `cd WT && bun test src/lib/client-lane/portal/signIn.test.ts`
Expected: FAIL. `./signIn` is not found.

- [ ] **Step 3: Write the implementation**

Create `src/lib/client-lane/portal/signIn.ts`:

```ts
/**
 * The portal sign-in screen's rules (spec 2026-10-06 portal §5.3, §6.4):
 * email → 6-digit code → signed in. Pure — the screen dispatches events and
 * renders what comes back.
 *
 * Enumeration-safe by construction: the api answers the code request with
 * the same 202 whether or not the brand or the client exists, and "sent" is
 * the ONLY way to the code step — nothing here branches on existence.
 */
export const PORTAL_CODE_LENGTH = 6;
export const PORTAL_RESEND_SECONDS = 60;

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export type SignInError =
  | "invalid_email"
  | "send_failed"
  | "throttled"
  | "invalid_code"
  | "code_expired"
  | "verify_failed";

export interface SignInState {
  step: "email" | "code";
  email: string;
  sending: boolean;
  verifying: boolean;
  error: SignInError | null;
  /** `invalid_code` only: tries left on this code. */
  attemptsLeft: number | null;
  /** Epoch ms after which "Resend" is offered. */
  resendAt: number;
}

export type SignInEvent =
  | { type: "send"; email: string }
  | { type: "sent"; at: number }
  | { type: "send_failed"; reason: "throttled" | "failed" }
  | { type: "change_email" }
  | { type: "verify" }
  | { type: "verified" }
  | {
      type: "verify_failed";
      reason: "invalid_code" | "code_expired" | "throttled" | "failed";
      attemptsLeft?: number | null;
    };

export const initialSignIn: SignInState = {
  step: "email",
  email: "",
  sending: false,
  verifying: false,
  error: null,
  attemptsLeft: null,
  resendAt: 0,
};

export function isEmail(value: string): boolean {
  const v = value.trim();
  return v.length <= 254 && EMAIL.test(v);
}

export function signInReducer(
  state: SignInState,
  event: SignInEvent
): SignInState {
  switch (event.type) {
    case "send": {
      const email = event.email.trim();
      if (!isEmail(email)) {
        return { ...state, sending: false, error: "invalid_email" };
      }
      if (state.sending) return state;
      return { ...state, email, sending: true, error: null, attemptsLeft: null };
    }
    case "sent":
      return {
        ...state,
        step: "code",
        sending: false,
        error: null,
        attemptsLeft: null,
        resendAt: event.at + PORTAL_RESEND_SECONDS * 1000,
      };
    case "send_failed":
      return {
        ...state,
        sending: false,
        error: event.reason === "throttled" ? "throttled" : "send_failed",
      };
    case "change_email":
      return {
        ...state,
        step: "email",
        verifying: false,
        error: null,
        attemptsLeft: null,
      };
    case "verify":
      if (state.verifying || state.step !== "code") return state;
      return { ...state, verifying: true, error: null };
    case "verified":
      return { ...state, verifying: false, error: null };
    case "verify_failed":
      return {
        ...state,
        verifying: false,
        error:
          event.reason === "invalid_code"
            ? "invalid_code"
            : event.reason === "code_expired"
              ? "code_expired"
              : event.reason === "throttled"
                ? "throttled"
                : "verify_failed",
        attemptsLeft:
          event.reason === "invalid_code" ? (event.attemptsLeft ?? null) : null,
      };
  }
}

/** The inline error line (phones never see a Toast — `Toast` returns null below md). */
export function signInErrorText(
  state: Pick<SignInState, "error" | "attemptsLeft">
): string | null {
  switch (state.error) {
    case null:
      return null;
    case "invalid_email":
      return "Enter a valid email address.";
    case "send_failed":
      return "Couldn't send the code. Try again in a moment.";
    case "throttled":
      return "Too many tries. Wait a minute and try again.";
    case "invalid_code":
      if (state.attemptsLeft === null) return "That code didn't match.";
      return state.attemptsLeft === 1
        ? "That code didn't match — 1 try left."
        : `That code didn't match — ${state.attemptsLeft} tries left.`;
    case "code_expired":
      return "This code has expired. Send a new one.";
    case "verify_failed":
      return "That didn't go through. Check your connection and try again.";
  }
}

export function canResend(state: SignInState, now: number): boolean {
  if (state.step !== "code" || state.sending || state.verifying) return false;
  return state.error === "code_expired" || now >= state.resendAt;
}

export function resendLabel(state: SignInState, now: number): string {
  if (state.error === "code_expired") return "Send a new code";
  const left = Math.max(0, Math.ceil((state.resendAt - now) / 1000));
  return left > 0 ? `Resend in ${left}s` : "Resend code";
}
```

- [ ] **Step 4: Run the test to verify it passes, then prove each named mutation**

Run: `cd WT && bun test src/lib/client-lane/portal/signIn.test.ts`
Expected: PASS. Apply each mutation, watch its test fail, and restore.

- [ ] **Step 5: Lint, format, commit**

```bash
cd WT && F=(src/lib/client-lane/portal/signIn.ts src/lib/client-lane/portal/signIn.test.ts) && ./node_modules/.bin/prettier --write "${F[@]}" && ./node_modules/.bin/eslint "${F[@]}" && /usr/bin/git add "${F[@]}" && /usr/bin/git commit -F - <<'EOF'
feat(web): portal sign-in state machine

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---
## Phase 2 — session plumbing (cookie, middleware, BFF, session routes)

### Task 4: The session cookie and `?k=` capture on portal links

**Files:**
- Modify: `src/lib/client-lane/cookie.ts` (append)
- Test: `src/lib/client-lane/cookie.session.test.ts`
- Modify: `src/middleware.ts` (`RESERVED_SHARE_SEGMENTS`, new `portalPageSlugs`, the `?k=` block)
- Test: `src/middleware.portal.test.ts`

**Interfaces:**
- Consumes: `LaneCookieOptions`, `isLaneCode`, `laneCookie`, `LANE_COOKIE_MAX_AGE_DEFAULT` (existing in `cookie.ts`).
- Produces:
  - constants: `CLIENT_SESSION_COOKIE = "frnd_client"`, `LANE_FRESH_COOKIE = "frnd_lane_new"`, `LANE_FRESH_MAX_AGE = 600`, `CLIENT_SESSION_MAX_AGE_DEFAULT = 2_592_000`, `CLIENT_SESSION_MAX_AGE_CAP = 7_776_000`, `CLIENT_SESSION_PATTERN`;
  - `isClientSessionToken(v)`;
  - `clientSessionCookie(token, expiresAt)`: `LaneCookieOptions | null`;
  - `clearedClientSessionCookie()`;
  - `laneFreshCookie(clear?: boolean)`;
  - `shouldExchangeLane({ lane, fresh })`: `boolean`;
  - in `middleware.ts`: `portalPageSlugs(pathname)`: `{ workspace: string; brand: string } | null`.

- [ ] **Step 1: Write the failing tests**

Create `src/lib/client-lane/cookie.session.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import {
  CLIENT_SESSION_COOKIE,
  CLIENT_SESSION_MAX_AGE_CAP,
  CLIENT_SESSION_MAX_AGE_DEFAULT,
  clearedClientSessionCookie,
  clientSessionCookie,
  laneFreshCookie,
  shouldExchangeLane,
} from "./cookie";

const TOKEN = "s".repeat(43);
const LANE = "abcdefghijklmnop";
const inSeconds = (s: number) => new Date(Date.now() + s * 1000).toISOString();

describe("clientSessionCookie (spec §6.1)", () => {
  it("is HttpOnly, Lax, scoped to /s, and lives until the session's expiry", () => {
    const cookie = clientSessionCookie(TOKEN, inSeconds(3600));
    expect(cookie).toMatchObject({
      name: CLIENT_SESSION_COOKIE,
      value: TOKEN,
      httpOnly: true,
      sameSite: "lax",
      path: "/s",
    });
    expect(cookie?.maxAge).toBeGreaterThanOrEqual(3599);
    expect(cookie?.maxAge).toBeLessThanOrEqual(3600);
  });

  it("never outlives the 90-day cap", () => {
    expect(clientSessionCookie(TOKEN, inSeconds(200 * 86_400))?.maxAge).toBe(
      CLIENT_SESSION_MAX_AGE_CAP
    );
  });

  it("takes 30 days when the api sent no expiry", () => {
    expect(clientSessionCookie(TOKEN, null)?.maxAge).toBe(
      CLIENT_SESSION_MAX_AGE_DEFAULT
    );
  });

  it("refuses a malformed token or a past expiry", () => {
    expect(clientSessionCookie("short", inSeconds(60))).toBeNull();
    expect(clientSessionCookie(TOKEN, inSeconds(-60))).toBeNull();
  });

  it("clears with an empty value and Max-Age 0", () => {
    expect(clearedClientSessionCookie()).toMatchObject({
      name: CLIENT_SESSION_COOKIE,
      value: "",
      maxAge: 0,
      path: "/s",
    });
  });
});

describe("the fresh-capture marker", () => {
  it("is a short-lived HttpOnly flag", () => {
    expect(laneFreshCookie()).toMatchObject({
      name: "frnd_lane_new",
      value: "1",
      maxAge: 600,
      httpOnly: true,
      path: "/s",
    });
    expect(laneFreshCookie(true)).toMatchObject({ value: "", maxAge: 0 });
  });

  it("asks for an exchange only right after a personal link was opened", () => {
    expect(shouldExchangeLane({ lane: LANE, fresh: "1" })).toBe(true);
    expect(shouldExchangeLane({ lane: LANE, fresh: undefined })).toBe(false);
    expect(shouldExchangeLane({ lane: "nope", fresh: "1" })).toBe(false);
  });
});
```

Create `src/middleware.portal.test.ts`:

```ts
import { NextRequest } from "next/server";
import { describe, expect, it } from "vitest";

import { middleware, portalPageSlugs, shareLinkPageToken } from "./middleware";

const LANE = "abcdefghijklmnop";
const request = (path: string) =>
  new NextRequest(new URL(`https://app.frnd.io${path}`));

describe("portalPageSlugs (spec §6.1)", () => {
  it("reads the workspace and brand of a portal URL", () => {
    expect(portalPageSlugs("/s/fcn/frndglow")).toEqual({
      workspace: "fcn",
      brand: "frndglow",
    });
    expect(portalPageSlugs("/s/fcn/frndglow/")).toEqual({
      workspace: "fcn",
      brand: "frndglow",
    });
  });

  it("is not fooled by route handlers, the OG image or deeper paths", () => {
    expect(portalPageSlugs("/s/tok/opengraph-image")).toBeNull();
    expect(portalPageSlugs("/s/session/exchange")).toBeNull();
    expect(portalPageSlugs("/s/verify/expired")).toBeNull();
    expect(portalPageSlugs("/s/api/portal")).toBeNull();
    expect(portalPageSlugs("/s/fcn/frndglow/x")).toBeNull();
    expect(portalPageSlugs("/s/tok")).toBeNull();
  });

  it("keeps `api` out of the request-link capture too", () => {
    expect(shareLinkPageToken("/s/api")).toBeNull();
  });
});

describe("?k= capture on a portal link", () => {
  it("cookies the lane, marks the capture fresh and cleans the URL", () => {
    const res = middleware(request(`/s/fcn/frndglow?k=${LANE}`));
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("https://app.frnd.io/s/fcn/frndglow");
    expect(res.cookies.get("frnd_lane")?.value).toBe(LANE);
    expect(res.cookies.get("frnd_lane_new")?.value).toBe("1");
  });

  it("marks a request link's capture fresh as well", () => {
    const res = middleware(request(`/s/tok123?k=${LANE}`));
    expect(res.cookies.get("frnd_lane")?.value).toBe(LANE);
    expect(res.cookies.get("frnd_lane_new")?.value).toBe("1");
  });

  it("leaves the OG image alone", () => {
    const res = middleware(request(`/s/tok/opengraph-image?k=${LANE}`));
    expect(res.headers.get("location")).toBeNull();
  });
});
```

Mutations:
- Remove `brand === "opengraph-image"` in `portalPageSlugs`, and "is not fooled… OG image" fails.
- Drop `response.cookies.set(laneFreshCookie())`, and both marker tests fail.
- Drop the `c.fresh === "1"` check in `shouldExchangeLane`, and "asks for an exchange only right after…" fails.
- Drop the cap in `clientSessionCookie`, and "never outlives the 90-day cap" fails.

- [ ] **Step 2: Run them to verify they fail**

Run: `cd WT && bun test src/lib/client-lane/cookie.session.test.ts`, then `bun test src/middleware.portal.test.ts`
Expected: FAIL. The exports `clientSessionCookie` and `portalPageSlugs` do not exist.

- [ ] **Step 3: Implement the cookies**

Append to `src/lib/client-lane/cookie.ts`:

```ts
/* ── Client portal session (spec 2026-10-06 portal §4.3, §6.1) ─────────── */

/**
 * The person on this device. Set and cleared ONLY by route handlers
 * (`/s/session/*`, `/s/api/portal/*`); server components read it to forward
 * as `X-Client-Session`; page JS never sees it (HttpOnly, and no handler
 * ever answers with it).
 */
export const CLIENT_SESSION_COOKIE = "frnd_client";

/**
 * Set beside `frnd_lane` by the `?k=` capture: "a personal link was just
 * opened here — adopt its person". Web-only; the api never sees it. Cleared
 * by `POST /s/session/exchange` whatever the outcome, so a page never loops.
 */
export const LANE_FRESH_COOKIE = "frnd_lane_new";
export const LANE_FRESH_MAX_AGE = 600;

/** 30 days — the api's sliding window — when the api sent no expiry. */
export const CLIENT_SESSION_MAX_AGE_DEFAULT = 2_592_000;
/** 90 days — the hard cap from creation (spec §4.1). */
export const CLIENT_SESSION_MAX_AGE_CAP = 7_776_000;

/** Opaque, URL-safe (assumed: base64url of 32 random bytes = 43 chars). */
export const CLIENT_SESSION_PATTERN = /^[A-Za-z0-9_-]{32,128}$/;

export function isClientSessionToken(value: unknown): value is string {
  return typeof value === "string" && CLIENT_SESSION_PATTERN.test(value);
}

function scopedCookie(
  name: string,
  value: string,
  maxAge: number
): LaneCookieOptions {
  return {
    name,
    value,
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    path: "/s",
    maxAge,
  };
}

/** Null for a malformed token or an expiry already past. */
export function clientSessionCookie(
  token: string,
  expiresAt: string | null | undefined
): LaneCookieOptions | null {
  if (!isClientSessionToken(token)) return null;
  if (!expiresAt) {
    return scopedCookie(CLIENT_SESSION_COOKIE, token, CLIENT_SESSION_MAX_AGE_DEFAULT);
  }
  const seconds = Math.floor(
    (new Date(expiresAt).getTime() - Date.now()) / 1000
  );
  if (!Number.isFinite(seconds) || seconds <= 0) return null;
  return scopedCookie(
    CLIENT_SESSION_COOKIE,
    token,
    Math.min(seconds, CLIENT_SESSION_MAX_AGE_CAP)
  );
}

export function clearedClientSessionCookie(): LaneCookieOptions {
  return scopedCookie(CLIENT_SESSION_COOKIE, "", 0);
}

export function laneFreshCookie(clear = false): LaneCookieOptions {
  return scopedCookie(
    LANE_FRESH_COOKIE,
    clear ? "" : "1",
    clear ? 0 : LANE_FRESH_MAX_AGE
  );
}

/** Trade the lane for a session: only right after a `?k=` capture. */
export function shouldExchangeLane(c: {
  lane: string | null | undefined;
  fresh: string | null | undefined;
}): boolean {
  return isLaneCode(c.lane) && c.fresh === "1";
}
```

`LaneCookieOptions.name` is already `string`, so no type change is needed.

- [ ] **Step 4: Implement the middleware capture**

In `src/middleware.ts`, change the import block to add `laneFreshCookie`:

```ts
import {
  LANE_COOKIE_MAX_AGE_DEFAULT,
  isLaneCode,
  laneCookie,
  laneFreshCookie,
} from "@/lib/client-lane/cookie";
```

Replace

```ts
/** `/s/{token}` page paths reserve these first segments for route handlers. */
const RESERVED_SHARE_SEGMENTS = new Set(["session", "verify"]);
```

with

```ts
/**
 * First segments under `/s` that belong to route handlers, never to a share
 * token or a workspace slug (spec 2026-10-06 portal P-4 reserves the same
 * three as workspace slugs).
 */
const RESERVED_SHARE_SEGMENTS = new Set(["session", "verify", "api"]);
```

Add right after `shareLinkPageToken`:

```ts
/**
 * The workspace and brand of a portal PAGE request — `/s/{workspace}/{brand}`
 * (spec 2026-10-06 portal §6.1). Not a route handler (`/s/session/…`,
 * `/s/verify/…`, `/s/api/…`) and not `/s/{token}/opengraph-image`.
 */
export function portalPageSlugs(
  pathname: string
): { workspace: string; brand: string } | null {
  const match = /^\/s\/([^/]+)\/([^/]+)\/?$/.exec(pathname);
  if (!match) return null;
  const [, workspace, brand] = match;
  if (RESERVED_SHARE_SEGMENTS.has(workspace) || brand === "opengraph-image") {
    return null;
  }
  return { workspace, brand };
}
```

In `middleware()`, replace

```ts
  if (shareLinkPageToken(pathname) !== null) {
    const k = request.nextUrl.searchParams.get("k");
    if (k && isLaneCode(k)) {
      const clean = new URL(request.url);
      clean.searchParams.delete("k");
      const response = NextResponse.redirect(clean, 302);
      response.cookies.set(laneCookie(k, LANE_COOKIE_MAX_AGE_DEFAULT));
      response.headers.set("Cache-Control", "no-store");
      return response;
    }
  }
```

with

```ts
  // Portal links (`/s/{workspace}/{brand}?k=`) carry a personal code too.
  // The fresh marker tells the page to trade the lane for a client session
  // (`POST /s/session/exchange`) — a POST from page JS, so a mail scanner
  // that prefetches the link never creates a session or an "opened" view.
  if (
    shareLinkPageToken(pathname) !== null ||
    portalPageSlugs(pathname) !== null
  ) {
    const k = request.nextUrl.searchParams.get("k");
    if (k && isLaneCode(k)) {
      const clean = new URL(request.url);
      clean.searchParams.delete("k");
      const response = NextResponse.redirect(clean, 302);
      response.cookies.set(laneCookie(k, LANE_COOKIE_MAX_AGE_DEFAULT));
      response.cookies.set(laneFreshCookie());
      response.headers.set("Cache-Control", "no-store");
      return response;
    }
  }
```

- [ ] **Step 5: Run the tests to verify they pass, then prove each named mutation**

```bash
cd WT && for f in src/lib/client-lane/cookie.session.test.ts src/middleware.portal.test.ts src/middleware.kvShare.test.ts src/middleware.mobile.test.ts src/middleware.studio.test.ts; do echo "== $f"; bun test "$f" 2>&1 | /usr/bin/grep -E "^[[:space:]]*[0-9]+ (pass|fail)|^\(fail\)|[0-9]+ error"; done
```

Expected: the two new files show `0 fail` and no `error` line. The three old middleware files show exactly their Task 0 failure list. Apply each mutation, watch its test fail, and restore.

- [ ] **Step 6: Lint, format, commit**

Check that `cookie.ts` and `middleware.ts` are prettier-clean on BASE before running prettier on them. Otherwise hand-format.

```bash
cd WT && F=(src/lib/client-lane/cookie.ts src/lib/client-lane/cookie.session.test.ts src/middleware.ts src/middleware.portal.test.ts) && ./node_modules/.bin/prettier --write src/lib/client-lane/cookie.session.test.ts src/middleware.portal.test.ts && ./node_modules/.bin/eslint "${F[@]}" && /usr/bin/git add "${F[@]}" && /usr/bin/git commit -F - <<'EOF'
feat(web): client session cookie and ?k= capture on portal links

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 5: The BFF portal proxy

**Files:**
- Create: `src/lib/client-lane/portal/proxy.ts`
- Test: `src/lib/client-lane/portal/proxy.test.ts`
- Create: `src/app/s/api/portal/[...path]/route.ts`

**Interfaces:**
- Consumes: `CLIENT_SESSION_COOKIE`, `LANE_COOKIE`, `clearedClientSessionCookie`, `clientSessionCookie`, `isClientSessionToken`, `isLaneCode`, `laneCookie` (Task 4 + existing).
- Produces:
  - constants: `SESSION_HEADER = "X-Client-Session"`, `SESSION_EXPIRES_HEADER = "X-Client-Session-Expires-At"`;
  - `apiBase()`;
  - `proxyRequestAllowed(request)`;
  - `safeSegments(segments)`: `string | null`;
  - `PortalRoute`, `portalRouteOf(method, segments)`;
  - `shareRouteAllowed(method, segments)`;
  - `stripSessionTokens(value)`;
  - `upstreamHeaders(request, extra)`: `Headers`;
  - `relay(upstream)`: `Promise<{ response: NextResponse; json: unknown }>`;
  - `portalProxy(request: NextRequest, segments)`: `Promise<NextResponse>`;
  - `shareLinkProxy(request, segments)` (written in Task 6);
  - `jsonResponse(body, status)`.

- [ ] **Step 1: Read the Next 16 route-handler docs**

Read `WT/node_modules/next/dist/docs/01-app/03-api-reference/03-file-conventions/route.md` (the `params` Promise and the catch-all table) and `dynamic-routes.md` ("Catch-all Segments").

- [ ] **Step 2: Write the failing test**

Create `src/lib/client-lane/portal/proxy.test.ts`:

```ts
import { NextRequest } from "next/server";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { portalProxy, proxyRequestAllowed } from "./proxy";

const TOKEN = "s".repeat(43);
const ORIGIN = "https://app.test";

function request(
  path: string,
  init: {
    method?: string;
    headers?: Record<string, string>;
    body?: string;
    cookie?: string;
  } = {}
) {
  return new NextRequest(new URL(`${ORIGIN}${path}`), {
    method: init.method ?? "GET",
    headers: {
      origin: ORIGIN,
      cookie: init.cookie ?? `frnd_client=${TOKEN}`,
      ...init.headers,
    },
    body: init.body,
  });
}

function apiAnswers(
  status: number,
  body: unknown,
  headers: Record<string, string> = { "content-type": "application/json" }
) {
  return vi.spyOn(globalThis, "fetch").mockResolvedValue(
    new Response(
      body === null ? null : typeof body === "string" ? body : JSON.stringify(body),
      { status, headers }
    )
  );
}

function sentTo(spy: ReturnType<typeof apiAnswers>) {
  const [url, init] = spy.mock.calls[0] as [string, RequestInit];
  return { url, method: init.method, headers: new Headers(init.headers) };
}

const inDays = (d: number) => new Date(Date.now() + d * 86_400_000).toISOString();

describe("portalProxy — the client portal BFF (spec §6.1, §8.1)", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    process.env.NEXT_PUBLIC_API_URL = "https://api.test";
  });

  it("forwards the frnd_client cookie as X-Client-Session — never a client-sent one", async () => {
    const spy = apiAnswers(200, { data: { user: { name: "Dina" }, brands: [] } });
    const res = await portalProxy(
      request("/s/api/portal/me", {
        headers: { "x-client-session": "z".repeat(43) },
      }),
      ["me"]
    );
    expect(res.status).toBe(200);
    const sent = sentTo(spy);
    expect(sent.url).toBe("https://api.test/public/portal/me");
    expect(sent.headers.get("X-Client-Session")).toBe(TOKEN);
    expect(sent.headers.get("cookie")).toBeNull();
  });

  it("rejects a cross-site call before it reaches the api", async () => {
    const spy = apiAnswers(202, {});
    const viaFetchSite = await portalProxy(
      request("/s/api/portal/fcn/frndglow/code", {
        method: "POST",
        // Same Origin on purpose: Sec-Fetch-Site must win. If bun drops this
        // header, the request passes as same-origin and THIS test fails.
        headers: { "sec-fetch-site": "cross-site", "content-type": "application/json" },
        body: JSON.stringify({ email: "a@b.co" }),
      }),
      ["fcn", "frndglow", "code"]
    );
    expect(viaFetchSite.status).toBe(403);
    const viaOrigin = await portalProxy(
      request("/s/api/portal/fcn/frndglow/code", {
        method: "POST",
        headers: { origin: "https://evil.test", "content-type": "application/json" },
        body: JSON.stringify({ email: "a@b.co" }),
      }),
      ["fcn", "frndglow", "code"]
    );
    expect(viaOrigin.status).toBe(403);
    expect(spy).not.toHaveBeenCalled();
  });

  it("lets a header-less GET through but not a header-less POST", () => {
    expect(
      proxyRequestAllowed(new Request(`${ORIGIN}/s/api/portal/me`))
    ).toBe(true);
    expect(
      proxyRequestAllowed(
        new Request(`${ORIGIN}/s/api/portal/session`, { method: "POST" })
      )
    ).toBe(false);
  });

  it("404s anything outside the portal's own routes without calling the api", async () => {
    const spy = apiAnswers(200, {});
    const cases: Array<[string, string[]]> = [
      ["GET", ["..", "frndglow", "approvals"]],
      ["GET", ["v1", "users"]],
      ["GET", ["fcn", "frndglow", "code"]],
      ["GET", ["session"]],
      ["POST", ["me"]],
    ];
    for (const [method, segments] of cases) {
      const res = await portalProxy(
        request(`/s/api/portal/${segments.join("/")}`, {
          method,
          headers: { "content-type": "application/json" },
          body: method === "POST" ? "{}" : undefined,
        }),
        segments
      );
      expect(res.status, segments.join("/")).toBe(404);
    }
    expect(spy).not.toHaveBeenCalled();
  });

  it("signs in: sets the session cookie and keeps the token out of the body", async () => {
    apiAnswers(200, { data: { session_token: TOKEN, expires_at: inDays(30) } });
    const res = await portalProxy(
      request("/s/api/portal/fcn/frndglow/code/verify", {
        method: "POST",
        cookie: "",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ email: "dina@brand.co", code: "123456" }),
      }),
      ["fcn", "frndglow", "code", "verify"]
    );
    expect(res.status).toBe(200);
    const text = await res.text();
    expect(text).not.toContain(TOKEN);
    expect(JSON.parse(text)).toMatchObject({ data: { signed_in: true } });
    const cookie = res.cookies.get("frnd_client");
    expect(cookie?.value).toBe(TOKEN);
    expect(cookie?.httpOnly).toBe(true);
    expect(cookie?.path).toBe("/s");
  });

  it("passes a wrong code's 422 through and sets no cookie", async () => {
    apiAnswers(422, { code: "invalid_code", attempts_left: 2 });
    const res = await portalProxy(
      request("/s/api/portal/fcn/frndglow/code/verify", {
        method: "POST",
        cookie: "",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ email: "dina@brand.co", code: "000000" }),
      }),
      ["fcn", "frndglow", "code", "verify"]
    );
    expect(res.status).toBe(422);
    expect(await res.json()).toEqual({ code: "invalid_code", attempts_left: 2 });
    expect(res.cookies.get("frnd_client")).toBeUndefined();
  });

  it("strips a session_token anywhere in a relayed body", async () => {
    apiAnswers(200, { data: { user: { name: "Dina", session_token: TOKEN }, brands: [] } });
    const res = await portalProxy(request("/s/api/portal/me"), ["me"]);
    expect(await res.text()).not.toContain(TOKEN);
  });

  it("clears a session the api no longer knows", async () => {
    apiAnswers(401, { code: "session_required" });
    const res = await portalProxy(request("/s/api/portal/me"), ["me"]);
    expect(res.status).toBe(401);
    expect(res.cookies.get("frnd_client")).toMatchObject({ value: "", maxAge: 0 });
  });

  it("signs out even when the api already forgot the session — and drops the lane cookie too", async () => {
    apiAnswers(401, { code: "session_required" });
    const res = await portalProxy(
      request("/s/api/portal/session", { method: "DELETE" }),
      ["session"]
    );
    expect(res.status).toBe(204);
    expect(res.cookies.get("frnd_client")).toMatchObject({ value: "", maxAge: 0 });
    expect(res.cookies.get("frnd_lane")).toMatchObject({ value: "", maxAge: 0 });
  });

  it("slides the cookie when the api extends the session", async () => {
    apiAnswers(200, { data: { user: { name: "Dina" }, brands: [] } }, {
      "content-type": "application/json",
      "X-Client-Session-Expires-At": inDays(10),
    });
    const res = await portalProxy(request("/s/api/portal/me"), ["me"]);
    const cookie = res.cookies.get("frnd_client");
    expect(cookie?.value).toBe(TOKEN);
    expect(cookie?.maxAge).toBeGreaterThanOrEqual(10 * 86_400 - 2);
    expect(cookie?.maxAge).toBeLessThanOrEqual(10 * 86_400);
  });

  it("forwards the decided cursor, the client IP and the user agent", async () => {
    const spy = apiAnswers(200, { data: {} });
    await portalProxy(
      request("/s/api/portal/fcn/frndglow/approvals?decided_cursor=c1", {
        headers: { "x-forwarded-for": "203.0.113.9", "user-agent": "UA/1" },
      }),
      ["fcn", "frndglow", "approvals"]
    );
    const sent = sentTo(spy);
    expect(sent.url).toBe(
      "https://api.test/public/portal/fcn/frndglow/approvals?decided_cursor=c1"
    );
    expect(sent.headers.get("X-Forwarded-For")).toBe("203.0.113.9");
    expect(sent.headers.get("User-Agent")).toBe("UA/1");
  });
});
```

Mutations:
- Copy the request's `x-client-session` header into `extra`, and the first test fails.
- Make `proxyRequestAllowed` return `true`, and "rejects a cross-site call" fails.
- Drop `safeSegments` from `portalProxy`, and the 404 test fails on `["..","frndglow","approvals"]`.
- Return the relayed response unchanged on `code_verify`, and "keeps the token out of the body" fails.
- Skip `stripSessionTokens` in `relay`, and "strips a session_token" fails.
- Relay the api's status on `sign_out`, and the sign-out test fails.
- Drop the slide block, and "slides the cookie" fails.

If `res.cookies.get(…)` returns no `maxAge`/`httpOnly` under this Next version, print `res.headers.get("set-cookie")` once. Then assert on that string instead (`/frnd_client=;/`, `/Max-Age=0/i`, `/HttpOnly/i`), and note the change in the track.

- [ ] **Step 3: Run it to verify it fails**

Run: `cd WT && bun test src/lib/client-lane/portal/proxy.test.ts`
Expected: FAIL. `./proxy` is not found.

- [ ] **Step 4: Write the proxy**

Create `src/lib/client-lane/portal/proxy.ts`:

```ts
/**
 * The client portal's BFF (spec 2026-10-06 portal §6.1, §8.1). Route
 * handlers under `/s/api/*` call these; nothing else does.
 *
 * - The session token lives ONLY in the HttpOnly `frnd_client` cookie. This
 *   module reads it, forwards it as `X-Client-Session`, sets / clears /
 *   slides it — and strips any `session_token` from every body it relays,
 *   so the token never reaches page JS.
 * - CSRF: the api reads only a header, never a cookie; here, a request must
 *   be same-origin (`Sec-Fetch-Site`, else `Origin`). A GET with neither
 *   header (an old Safari) passes — it cannot read the answer cross-origin
 *   and changes nothing; a POST/DELETE with neither is refused.
 * - Only the portal's own endpoint shapes are proxied, and no path segment
 *   may be empty, `.`, `..` or contain a slash — the session header never
 *   rides to an api path it was not meant for.
 */
import { NextResponse, type NextRequest } from "next/server";

import {
  CLIENT_SESSION_COOKIE,
  clearedClientSessionCookie,
  clientSessionCookie,
  isClientSessionToken,
  laneCookie,
} from "../cookie";

export const SESSION_HEADER = "X-Client-Session";
/** (assumed) The api's slid expiry on any session-authenticated 2xx. */
export const SESSION_EXPIRES_HEADER = "X-Client-Session-Expires-At";

const MAX_BODY_BYTES = 65_536;
const NO_STORE = { "Cache-Control": "no-store" } as const;

export function apiBase(): string {
  return (process.env.NEXT_PUBLIC_API_URL ?? "").replace(/\/$/, "");
}

export function jsonResponse(body: unknown, status: number): NextResponse {
  return NextResponse.json(body, { status, headers: NO_STORE });
}

export function proxyRequestAllowed(request: Request): boolean {
  const site = request.headers.get("sec-fetch-site");
  if (site) return site === "same-origin";
  const origin = request.headers.get("origin");
  if (origin) {
    try {
      return new URL(origin).origin === new URL(request.url).origin;
    } catch {
      return false;
    }
  }
  return request.method === "GET" || request.method === "HEAD";
}

/** "fcn/frndglow/approvals", or null when any segment could escape the prefix. */
export function safeSegments(segments: readonly string[]): string | null {
  if (segments.length === 0) return null;
  for (const segment of segments) {
    if (!segment || segment === "." || segment === ".." || /[\\/]/.test(segment)) {
      return null;
    }
  }
  return segments.map(encodeURIComponent).join("/");
}

export type PortalRoute = "me" | "approvals" | "code" | "code_verify" | "sign_out";

/** The portal endpoints (spec §5) — anything else is a 404 here. */
export function portalRouteOf(
  method: string,
  segments: readonly string[]
): PortalRoute | null {
  const n = segments.length;
  if (n === 1 && segments[0] === "me" && method === "GET") return "me";
  if (n === 1 && segments[0] === "session" && method === "DELETE") return "sign_out";
  if (n === 3 && segments[2] === "approvals" && method === "GET") return "approvals";
  if (n === 3 && segments[2] === "code" && method === "POST") return "code";
  if (n === 4 && segments[2] === "code" && segments[3] === "verify" && method === "POST") {
    return "code_verify";
  }
  return null;
}

/** The share-link endpoints the client page calls (C-1, C-3, C-4, §4.8). */
export function shareRouteAllowed(method: string, segments: readonly string[]): boolean {
  const n = segments.length;
  if (n === 1) return method === "GET";
  if (n !== 2) return false;
  switch (segments[1]) {
    case "comments":
      return method === "GET" || method === "POST";
    case "decision":
      return method === "POST";
    case "record.pdf":
      return method === "GET";
    default:
      return false;
  }
}

export function stripSessionTokens(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(stripSessionTokens);
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [key, inner] of Object.entries(value)) {
      if (key === "session_token") continue;
      out[key] = stripSessionTokens(inner);
    }
    return out;
  }
  return value;
}

/** Never the browser's cookie or authorization — only what the api needs. */
export function upstreamHeaders(
  request: Request,
  extra: Record<string, string>
): Headers {
  const headers = new Headers({ Accept: "application/json" });
  const type = request.headers.get("content-type");
  if (type) headers.set("Content-Type", type);
  const agent = request.headers.get("user-agent");
  if (agent) headers.set("User-Agent", agent);
  const forwarded =
    request.headers.get("x-forwarded-for") ?? request.headers.get("x-real-ip");
  if (forwarded) headers.set("X-Forwarded-For", forwarded);
  for (const [name, value] of Object.entries(extra)) headers.set(name, value);
  return headers;
}

export async function callApi(
  request: NextRequest,
  upstreamPath: string,
  extra: Record<string, string>
): Promise<Response | "too_large"> {
  let body: string | undefined;
  if (request.method !== "GET" && request.method !== "HEAD") {
    const text = await request.text();
    if (text.length > MAX_BODY_BYTES) return "too_large";
    body = text || undefined;
  }
  return fetch(`${apiBase()}/${upstreamPath}${request.nextUrl.search}`, {
    method: request.method,
    headers: upstreamHeaders(request, extra),
    body,
    cache: "no-store",
  });
}

/** JSON → token-stripped JSON; anything else (the record PDF) streams through. */
export async function relay(
  upstream: Response
): Promise<{ response: NextResponse; json: unknown }> {
  const type = upstream.headers.get("content-type") ?? "";
  if (!type.includes("json")) {
    const headers = new Headers(NO_STORE);
    if (type) headers.set("Content-Type", type);
    const disposition = upstream.headers.get("content-disposition");
    if (disposition) headers.set("Content-Disposition", disposition);
    return {
      response: new NextResponse(upstream.body, { status: upstream.status, headers }),
      json: null,
    };
  }
  const text = await upstream.text();
  if (!text) {
    return {
      response: new NextResponse(null, { status: upstream.status, headers: NO_STORE }),
      json: null,
    };
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return { response: jsonResponse({ message: "Bad gateway." }, 502), json: null };
  }
  return {
    response: jsonResponse(stripSessionTokens(parsed), upstream.status),
    json: parsed,
  };
}

function signedOut(): NextResponse {
  const response = new NextResponse(null, { status: 204, headers: NO_STORE });
  response.cookies.set(clearedClientSessionCookie());
  // The legacy lane cookie decides on request links too — signing this
  // device out must drop it as well.
  response.cookies.set(laneCookie("", 0));
  return response;
}

export async function portalProxy(
  request: NextRequest,
  segments: readonly string[]
): Promise<NextResponse> {
  if (!proxyRequestAllowed(request)) {
    return jsonResponse({ message: "Cross-site request rejected." }, 403);
  }
  const route = portalRouteOf(request.method, segments);
  const path = safeSegments(segments);
  if (route === null || path === null) {
    return jsonResponse({ message: "Not found." }, 404);
  }

  const cookie = request.cookies.get(CLIENT_SESSION_COOKIE)?.value;
  const session = isClientSessionToken(cookie) ? cookie : null;
  const extra: Record<string, string> = session ? { [SESSION_HEADER]: session } : {};

  if (route === "sign_out") {
    // Local-first: the device is signed out whatever the api says.
    try {
      await callApi(request, `public/portal/${path}`, extra);
    } catch {
      // The api revokes it on its own expiry.
    }
    return signedOut();
  }

  let upstream: Response | "too_large";
  try {
    upstream = await callApi(request, `public/portal/${path}`, extra);
  } catch {
    return jsonResponse(
      { message: "The service is unavailable. Try again in a moment." },
      502
    );
  }
  if (upstream === "too_large") {
    return jsonResponse({ message: "Request too large." }, 413);
  }

  const { response, json } = await relay(upstream);

  if (route === "code_verify" && upstream.status === 200) {
    const data = (json as { data?: { session_token?: unknown; expires_at?: unknown } } | null)
      ?.data;
    const expiresAt = typeof data?.expires_at === "string" ? data.expires_at : null;
    const issued =
      typeof data?.session_token === "string"
        ? clientSessionCookie(data.session_token, expiresAt)
        : null;
    if (!issued) {
      return jsonResponse({ message: "Couldn't sign in. Try again." }, 502);
    }
    const signedIn = jsonResponse({ data: { signed_in: true, expires_at: expiresAt } }, 200);
    signedIn.cookies.set(issued);
    return signedIn;
  }

  if (upstream.status === 401 && session) {
    response.cookies.set(clearedClientSessionCookie());
    return response;
  }

  const slid = upstream.headers.get(SESSION_EXPIRES_HEADER);
  if (session && slid && upstream.status < 400) {
    const refreshed = clientSessionCookie(session, slid);
    if (refreshed) response.cookies.set(refreshed);
  }
  return response;
}
```

`shareLinkProxy` is added in Task 6.

Create `src/app/s/api/portal/[...path]/route.ts`:

```ts
import type { NextRequest } from "next/server";

import { portalProxy } from "@/lib/client-lane/portal/proxy";

/**
 * The client portal BFF (spec 2026-10-06 portal §6.1) — every rule lives in
 * `portalProxy`; this file only adapts Next's route signature.
 */
export const dynamic = "force-dynamic";

type Context = { params: Promise<{ path: string[] }> };

export async function GET(request: NextRequest, { params }: Context) {
  return portalProxy(request, (await params).path);
}

export async function POST(request: NextRequest, { params }: Context) {
  return portalProxy(request, (await params).path);
}

export async function DELETE(request: NextRequest, { params }: Context) {
  return portalProxy(request, (await params).path);
}
```

- [ ] **Step 5: Run the test to verify it passes, then prove each named mutation**

Run: `cd WT && bun test src/lib/client-lane/portal/proxy.test.ts`
Expected: PASS, with no `error` line. Apply each mutation, watch its test fail, and restore.

- [ ] **Step 6: Lint, format, commit**

```bash
cd WT && F=(src/lib/client-lane/portal/proxy.ts src/lib/client-lane/portal/proxy.test.ts "src/app/s/api/portal/[...path]/route.ts") && ./node_modules/.bin/prettier --write "${F[@]}" && ./node_modules/.bin/eslint "${F[@]}" && /usr/bin/git add "${F[@]}" && /usr/bin/git commit -F - <<'EOF'
feat(web): same-origin BFF for the client portal api

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 6: Share-link calls through the BFF when a session is held

**Files:**
- Modify: `src/lib/client-lane/portal/proxy.ts` (append `shareLinkProxy`)
- Modify: `src/lib/client-lane/portal/proxy.test.ts` (append a describe; check `wc -c` < 45 000 first)
- Create: `src/app/s/api/share-links/[...path]/route.ts`
- Modify: `src/lib/client-lane/publicApi.ts`
- Test: `src/lib/client-lane/publicApi.transport.test.ts`

**Interfaces:**
- Consumes: `proxyRequestAllowed`, `safeSegments`, `shareRouteAllowed`, `callApi`, `relay`, `jsonResponse`, `SESSION_HEADER` (Task 5); `LANE_COOKIE`, `isLaneCode`, `isClientSessionToken`.
- Produces:
  - `shareLinkProxy(request, segments)`;
  - in `publicApi.ts`:
    - `SessionLane = { laneCode: string | null; session: true }`;
    - `LaneAuth = string | null | undefined | SessionLane`;
    - `SHARE_PROXY_BASE = "/s/api/"`;
    - `shareLinkCall(path, lane)`: `{ url: string; config: { baseURL?: string; headers: Record<string, string> } }`.

    `resolveShareLink`, `listPublicComments`, `postPublicComment`, `postDecision`, `postRequestDecision` and `downloadPublicRecord` now take `lane?: LaneAuth` where they took `laneCode?: string | null`. That is source-compatible: a string or null behaves exactly as before.

Why: with a session and no `frnd_lane` (signed in by code on this device), the page's own calls (comments, decision, refresh, record) must carry the session. Only the BFF can add it. Without a session nothing changes (spec §6.5 "behaves exactly as today").

- [ ] **Step 1: Write the failing tests**

Append to `src/lib/client-lane/portal/proxy.test.ts` (add `shareLinkProxy` to the import from `./proxy`):

```ts
describe("shareLinkProxy — the review page's calls with a session", () => {
  const LANE = "abcdefghijklmnop";
  const OTHER = "ponmlkjihgfedcba";

  beforeEach(() => {
    vi.restoreAllMocks();
    process.env.NEXT_PUBLIC_API_URL = "https://api.test";
  });

  it("forwards the session and the lane cookie to the share-link endpoint", async () => {
    const spy = apiAnswers(200, { data: [] });
    await shareLinkProxy(
      request("/s/api/share-links/tok/comments", {
        cookie: `frnd_client=${TOKEN}; frnd_lane=${LANE}`,
      }),
      ["tok", "comments"]
    );
    const sent = sentTo(spy);
    expect(sent.url).toBe("https://api.test/public/share-links/tok/comments");
    expect(sent.headers.get("X-Client-Session")).toBe(TOKEN);
    expect(sent.headers.get("X-Lane-Code")).toBe(LANE);
  });

  it("prefers the lane code the page holds in memory", async () => {
    const spy = apiAnswers(200, { data: [] });
    await shareLinkProxy(
      request("/s/api/share-links/tok/comments", {
        cookie: `frnd_client=${TOKEN}; frnd_lane=${LANE}`,
        headers: { "x-lane-code": OTHER },
      }),
      ["tok", "comments"]
    );
    expect(sentTo(spy).headers.get("X-Lane-Code")).toBe(OTHER);
  });

  it("streams the approval record PDF", async () => {
    apiAnswers(200, "%PDF-1.7", { "content-type": "application/pdf" });
    const res = await shareLinkProxy(
      request("/s/api/share-links/tok/record.pdf"),
      ["tok", "record.pdf"]
    );
    expect(res.headers.get("content-type")).toBe("application/pdf");
    expect(await res.text()).toBe("%PDF-1.7");
  });

  it("404s a share-link path it does not know", async () => {
    const spy = apiAnswers(200, {});
    const res = await shareLinkProxy(
      request("/s/api/share-links/tok/admin"),
      ["tok", "admin"]
    );
    expect(res.status).toBe(404);
    expect(spy).not.toHaveBeenCalled();
  });
});
```

Create `src/lib/client-lane/publicApi.transport.test.ts`:

```ts
import { beforeEach, describe, expect, it, vi } from "vitest";

import { axiosPublic } from "@/services/axios";

import { listPublicComments, shareLinkCall } from "./publicApi";

const LANE = "abcdefghijklmnop";

describe("shareLinkCall (spec 2026-10-06 portal §6.5)", () => {
  it("calls the api directly without a session — exactly as before", () => {
    expect(shareLinkCall("public/share-links/tok/comments", LANE)).toEqual({
      url: "public/share-links/tok/comments",
      config: { headers: { "X-Lane-Code": LANE } },
    });
    expect(shareLinkCall("public/share-links/tok", null)).toEqual({
      url: "public/share-links/tok",
      config: { headers: {} },
    });
  });

  it("goes through the same-origin BFF with a session", () => {
    expect(
      shareLinkCall("public/share-links/tok/comments", {
        laneCode: LANE,
        session: true,
      })
    ).toEqual({
      url: "share-links/tok/comments",
      config: { baseURL: "/s/api/", headers: { "X-Lane-Code": LANE } },
    });
  });
});

describe("listPublicComments with a session", () => {
  beforeEach(() => vi.restoreAllMocks());

  it("asks the BFF", async () => {
    const get = vi
      .spyOn(axiosPublic, "get")
      .mockResolvedValue({ data: { data: [] } } as never);
    await listPublicComments("tok", { laneCode: null, session: true });
    expect(get).toHaveBeenCalledWith("share-links/tok/comments", {
      baseURL: "/s/api/",
      headers: {},
    });
  });
});
```

Mutations:
- In `shareLinkCall`, keep the `public/` prefix on the session branch, and "goes through the same-origin BFF" fails.
- Drop the `X-Client-Session` extra in `shareLinkProxy`, and "forwards the session and the lane cookie" fails.
- Read only the cookie's lane code, and "prefers the lane code the page holds in memory" fails.

- [ ] **Step 2: Run them to verify they fail**

Run: `cd WT && bun test src/lib/client-lane/portal/proxy.test.ts`, then `bun test src/lib/client-lane/publicApi.transport.test.ts`
Expected: both FAIL. `shareLinkProxy` and `shareLinkCall` are not exported.

- [ ] **Step 3: Implement `shareLinkProxy`**

In `src/lib/client-lane/portal/proxy.ts`, widen the cookie import to

```ts
import {
  CLIENT_SESSION_COOKIE,
  LANE_COOKIE,
  clearedClientSessionCookie,
  clientSessionCookie,
  isClientSessionToken,
  isLaneCode,
  laneCookie,
} from "../cookie";
```

and append:

```ts
/**
 * The review page's share-link calls while a client session is held (spec
 * §4.5: the resolver prefers the session's lane). The lane code the page
 * holds in memory (a code verified this visit) wins over the cookie's.
 */
export async function shareLinkProxy(
  request: NextRequest,
  segments: readonly string[]
): Promise<NextResponse> {
  if (!proxyRequestAllowed(request)) {
    return jsonResponse({ message: "Cross-site request rejected." }, 403);
  }
  const path = safeSegments(segments);
  if (path === null || !shareRouteAllowed(request.method, segments)) {
    return jsonResponse({ message: "Not found." }, 404);
  }
  const extra: Record<string, string> = {};
  const session = request.cookies.get(CLIENT_SESSION_COOKIE)?.value;
  if (isClientSessionToken(session)) extra[SESSION_HEADER] = session;
  const headerCode = request.headers.get("x-lane-code");
  const cookieCode = request.cookies.get(LANE_COOKIE)?.value;
  const lane = isLaneCode(headerCode)
    ? headerCode
    : isLaneCode(cookieCode)
      ? cookieCode
      : null;
  if (lane) extra["X-Lane-Code"] = lane;

  let upstream: Response | "too_large";
  try {
    upstream = await callApi(request, `public/share-links/${path}`, extra);
  } catch {
    return jsonResponse(
      { message: "The service is unavailable. Try again in a moment." },
      502
    );
  }
  if (upstream === "too_large") {
    return jsonResponse({ message: "Request too large." }, 413);
  }
  return (await relay(upstream)).response;
}
```

Create `src/app/s/api/share-links/[...path]/route.ts`:

```ts
import type { NextRequest } from "next/server";

import { shareLinkProxy } from "@/lib/client-lane/portal/proxy";

/** The review page's share-link calls with a client session (spec §6.5). */
export const dynamic = "force-dynamic";

type Context = { params: Promise<{ path: string[] }> };

export async function GET(request: NextRequest, { params }: Context) {
  return shareLinkProxy(request, (await params).path);
}

export async function POST(request: NextRequest, { params }: Context) {
  return shareLinkProxy(request, (await params).path);
}
```

- [ ] **Step 4: Implement the transport in `publicApi.ts`**

In `src/lib/client-lane/publicApi.ts`, replace

```ts
function laneHeaders(laneCode?: string | null): Record<string, string> {
  return laneCode ? { [LANE_CODE_HEADER]: laneCode } : {};
}
```

with

```ts
function laneHeaders(laneCode?: string | null): Record<string, string> {
  return laneCode ? { [LANE_CODE_HEADER]: laneCode } : {};
}

/** A client portal session is held: calls go through the BFF, which adds it. */
export interface SessionLane {
  laneCode: string | null;
  session: true;
}

/**
 * How the page authenticates a share-link call: a lane code (or none) —
 * straight to the api, as before — or a client session, through the
 * same-origin BFF (`/s/api/share-links/*`), which forwards the HttpOnly
 * `frnd_client` cookie as `X-Client-Session` (spec 2026-10-06 portal §6.5).
 */
export type LaneAuth = string | null | undefined | SessionLane;

export const SHARE_PROXY_BASE = "/s/api/";

export function shareLinkCall(
  path: string,
  lane: LaneAuth
): { url: string; config: { baseURL?: string; headers: Record<string, string> } } {
  if (lane && typeof lane === "object") {
    return {
      url: path.replace(/^public\//, ""),
      config: { baseURL: SHARE_PROXY_BASE, headers: laneHeaders(lane.laneCode) },
    };
  }
  return { url: path, config: { headers: laneHeaders(lane) } };
}
```

Then rewrite the six share-link functions to use it. Each keeps its name and return type; only the last parameter's name and type change, to `lane?: LaneAuth`. For example:

```ts
export async function resolveShareLink(
  token: string,
  lane?: LaneAuth
): Promise<ShareLinkData> {
  const { url, config } = shareLinkCall(
    `public/share-links/${encodeURIComponent(token)}`,
    lane
  );
  const res = await axiosPublic.get<{ data: ShareLinkData }>(url, config);
  return res.data.data;
}

export async function listPublicComments(
  token: string,
  lane?: LaneAuth
): Promise<PublicComment[]> {
  const { url, config } = shareLinkCall(
    `public/share-links/${encodeURIComponent(token)}/comments`,
    lane
  );
  const res = await axiosPublic.get<{ data: PublicComment[] }>(url, config);
  return res.data.data;
}

export async function postPublicComment(
  token: string,
  input: PublicCommentInput,
  lane?: LaneAuth
): Promise<PublicComment> {
  const { url, config } = shareLinkCall(
    `public/share-links/${encodeURIComponent(token)}/comments`,
    lane
  );
  const res = await axiosPublic.post<{ data: PublicComment }>(url, input, config);
  return res.data.data;
}

export async function postDecision(
  token: string,
  input: DecisionInput,
  lane?: LaneAuth
): Promise<DecisionResponse> {
  const { url, config } = shareLinkCall(
    `public/share-links/${encodeURIComponent(token)}/decision`,
    lane
  );
  const res = await axiosPublic.post<{ data: DecisionResponse }>(url, input, config);
  return res.data.data;
}

export async function postRequestDecision(
  token: string,
  input: RequestDecisionInput,
  lane?: LaneAuth
): Promise<RequestDecisionResponse> {
  const { url, config } = shareLinkCall(
    `public/share-links/${encodeURIComponent(token)}/decision`,
    lane
  );
  const res = await axiosPublic.post<{ data: RequestDecisionResponse }>(
    url,
    input,
    config
  );
  return res.data.data;
}

export async function downloadPublicRecord(
  token: string,
  lane?: LaneAuth
): Promise<Blob> {
  const { url, config } = shareLinkCall(
    `public/share-links/${encodeURIComponent(token)}/record.pdf`,
    lane
  );
  const res = await withDecodedErrorBody(() =>
    axiosPublic.get<Blob>(url, { ...config, responseType: "blob" })
  );
  return res.data;
}
```

Keep each function's existing doc comment above it. The direct branch builds `{ headers: laneHeaders(lane) }`, exactly the old config object, so `DecisionPage.test.tsx`'s URL-keyed stubs keep matching.

- [ ] **Step 5: Run the tests, the old public-api consumers, and prove each named mutation**

```bash
cd WT && for f in src/lib/client-lane/portal/proxy.test.ts src/lib/client-lane/publicApi.transport.test.ts src/components/client-lane/DecisionPage.test.tsx src/lib/client-lane/recordPdf.test.ts; do echo "== $f"; bun test "$f" 2>&1 | /usr/bin/grep -E "^[[:space:]]*[0-9]+ (pass|fail)|^\(fail\)|[0-9]+ error"; done
```

Expected: the new files show `0 fail` and no `error` line. `DecisionPage.test.tsx` and `recordPdf.test.ts` show exactly their Task 0 failure lists. Apply each mutation, watch its test fail, and restore.

- [ ] **Step 6: Lint, format, commit**

Check that `publicApi.ts` is prettier-clean on BASE before running prettier on it.

```bash
cd WT && F=(src/lib/client-lane/portal/proxy.ts src/lib/client-lane/portal/proxy.test.ts "src/app/s/api/share-links/[...path]/route.ts" src/lib/client-lane/publicApi.ts src/lib/client-lane/publicApi.transport.test.ts) && ./node_modules/.bin/prettier --write src/lib/client-lane/portal/proxy.ts src/lib/client-lane/portal/proxy.test.ts "src/app/s/api/share-links/[...path]/route.ts" src/lib/client-lane/publicApi.transport.test.ts && ./node_modules/.bin/eslint "${F[@]}" && wc -c src/lib/client-lane/portal/proxy.test.ts && /usr/bin/git add "${F[@]}" && /usr/bin/git commit -F - <<'EOF'
feat(web): review-page share-link calls ride the BFF when a client session is held

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 7: Session routes — trade a lane for a session; spend a request-link code server-side

**Files:**
- Create: `src/lib/client-lane/portal/sessionRoutes.ts`
- Test: `src/lib/client-lane/portal/sessionRoutes.test.ts`
- Create: `src/app/s/session/exchange/route.ts`, `src/app/s/session/code/route.ts`
- Modify: `src/lib/client-lane/publicApi.ts` (`verifyLaneCode` through the web)
- Modify: `src/lib/client-lane/publicApi.transport.test.ts` (append)
- Modify: `src/lib/client-lane/laneCode.ts` (`confirmLaneCode` stops cookieing from JS; `persistLaneCookie` removed)

**Interfaces:**
- Consumes: Task 4's cookies; `apiBase`, `upstreamHeaders`, `stripSessionTokens`, `jsonResponse`, `SESSION_HEADER` (Task 5); `isSameOriginRequest` (`src/lib/client-lane/sameOrigin.ts`); `laneCookie`, `laneMaxAge`, `isLaneCode`.
- Produces:
  - `exchangeLane(request: NextRequest)`: answers `{ signed_in: boolean }`;
  - `verifyRequestLinkCode(request: NextRequest)`: answers `{ data: LaneCodeVerified }` or the api's error, passed through;
  - `verifyLaneCode(email, code, shareToken)`: now calls `POST /s/session/code`. Its errors keep the axios shape, so `publicApiError` reads them unchanged.

Why the code route: spec §4.3 has the existing `public/lane/code/verify` "also issue a session". If page JS kept calling the api directly, JS would hold the token (spec §6.1). The route spends the code server-side, sets `frnd_lane` (replacing the `persistLaneCookie` round-trip) and `frnd_client`, and answers the lane only.

- [ ] **Step 1: Write the failing tests**

Create `src/lib/client-lane/portal/sessionRoutes.test.ts`:

```ts
import { NextRequest } from "next/server";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { exchangeLane, verifyRequestLinkCode } from "./sessionRoutes";

const TOKEN = "s".repeat(43);
const LANE = "abcdefghijklmnop";
const ORIGIN = "https://app.test";
const inDays = (d: number) => new Date(Date.now() + d * 86_400_000).toISOString();

function post(path: string, cookie: string, body?: unknown, origin = ORIGIN) {
  return new NextRequest(new URL(`${ORIGIN}${path}`), {
    method: "POST",
    headers: { origin, cookie, "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

function apiAnswers(status: number, body: unknown) {
  return vi.spyOn(globalThis, "fetch").mockResolvedValue(
    new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    })
  );
}

describe("exchangeLane (spec §4.3 path 1)", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    process.env.NEXT_PUBLIC_API_URL = "https://api.test";
  });

  it("adopts the person behind a freshly opened personal link", async () => {
    const spy = apiAnswers(200, { data: { session_token: TOKEN, expires_at: inDays(30) } });
    const res = await exchangeLane(
      post("/s/session/exchange", `frnd_lane=${LANE}; frnd_lane_new=1`)
    );
    expect(await res.json()).toEqual({ signed_in: true });
    const [url, init] = spy.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("https://api.test/public/client/session");
    expect(JSON.parse(String(init.body))).toEqual({ lane_code: LANE });
    expect(res.cookies.get("frnd_client")?.value).toBe(TOKEN);
    expect(res.cookies.get("frnd_lane_new")).toMatchObject({ value: "", maxAge: 0 });
  });

  it("does nothing without a fresh capture", async () => {
    const spy = apiAnswers(200, {});
    const res = await exchangeLane(post("/s/session/exchange", `frnd_lane=${LANE}`));
    expect(await res.json()).toEqual({ signed_in: false });
    expect(spy).not.toHaveBeenCalled();
  });

  it("keeps the legacy lane when the api refuses — and still clears the marker", async () => {
    apiAnswers(404, { message: "Not found." });
    const res = await exchangeLane(
      post("/s/session/exchange", `frnd_lane=${LANE}; frnd_lane_new=1`)
    );
    expect(await res.json()).toEqual({ signed_in: false });
    expect(res.cookies.get("frnd_client")).toBeUndefined();
    expect(res.cookies.get("frnd_lane_new")).toMatchObject({ maxAge: 0 });
  });
});

describe("verifyRequestLinkCode (spec §4.3 path 2)", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    process.env.NEXT_PUBLIC_API_URL = "https://api.test";
  });

  const body = { email: "dina@brand.co", code: "123456", share_token: "tok" };

  it("cookies the lane and the session, answers the lane only", async () => {
    apiAnswers(200, {
      data: {
        lane_code: LANE,
        kind: "personal",
        expires_at: null,
        session: { session_token: TOKEN, expires_at: inDays(30) },
      },
    });
    const res = await verifyRequestLinkCode(post("/s/session/code", "", body));
    const text = await res.text();
    expect(text).not.toContain(TOKEN);
    expect(JSON.parse(text)).toEqual({
      data: { lane_code: LANE, kind: "personal", expires_at: null },
    });
    expect(res.cookies.get("frnd_lane")?.value).toBe(LANE);
    expect(res.cookies.get("frnd_client")?.value).toBe(TOKEN);
  });

  it("still verifies on an api that issues no session", async () => {
    apiAnswers(200, { data: { lane_code: LANE, kind: "verified_guest", expires_at: inDays(30) } });
    const res = await verifyRequestLinkCode(post("/s/session/code", "", body));
    expect(res.status).toBe(200);
    expect(res.cookies.get("frnd_lane")?.value).toBe(LANE);
    expect(res.cookies.get("frnd_client")).toBeUndefined();
  });

  it("passes a wrong code's 422 through", async () => {
    apiAnswers(422, { code: "invalid_code", attempts_left: 3 });
    const res = await verifyRequestLinkCode(post("/s/session/code", "", body));
    expect(res.status).toBe(422);
    expect(await res.json()).toEqual({ code: "invalid_code", attempts_left: 3 });
  });

  it("refuses a cross-site POST without calling the api", async () => {
    const spy = apiAnswers(200, {});
    const res = await verifyRequestLinkCode(
      post("/s/session/code", "", body, "https://evil.test")
    );
    expect(res.status).toBe(403);
    expect(spy).not.toHaveBeenCalled();
  });
});
```

Append to `src/lib/client-lane/publicApi.transport.test.ts` (add `publicApiError, verifyLaneCode` to the import from `./publicApi`):

```ts
describe("verifyLaneCode goes through the web (spec §4.3, §6.1)", () => {
  beforeEach(() => vi.restoreAllMocks());

  it("posts to /s/session/code and returns the lane", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({ data: { lane_code: LANE, kind: "personal", expires_at: null } }),
        { status: 200, headers: { "content-type": "application/json" } }
      )
    );
    await expect(verifyLaneCode("dina@brand.co", "123456", "tok")).resolves.toEqual({
      lane_code: LANE,
      kind: "personal",
      expires_at: null,
    });
    const [url, init] = fetchSpy.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("/s/session/code");
    expect(JSON.parse(String(init.body))).toEqual({
      email: "dina@brand.co",
      code: "123456",
      share_token: "tok",
    });
  });

  it("rejects in the shape publicApiError reads", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ code: "invalid_code", attempts_left: 2 }), {
        status: 422,
        headers: { "content-type": "application/json" },
      })
    );
    const err = await verifyLaneCode("dina@brand.co", "000000", "tok").catch(
      (e: unknown) => e
    );
    expect(publicApiError(err)).toMatchObject({
      status: 422,
      code: "invalid_code",
      attemptsLeft: 2,
    });
  });
});
```

Mutations:
- In `exchangeLane`, skip setting `frnd_client`, and "adopts the person" fails.
- Call `shouldExchangeLane` with `fresh: "1"` hard-coded, and "does nothing without a fresh capture" fails.
- Forget the marker clear on the refusal branch, and "keeps the legacy lane… clears the marker" fails.
- Return the api payload unchanged in `verifyRequestLinkCode`, and "answers the lane only" fails.
- Throw `new Error(...)` without `response`, and "rejects in the shape publicApiError reads" fails.

- [ ] **Step 2: Run them to verify they fail**

Run: `cd WT && bun test src/lib/client-lane/portal/sessionRoutes.test.ts`, then `bun test src/lib/client-lane/publicApi.transport.test.ts`
Expected: FAIL. `./sessionRoutes` is not found, and `verifyLaneCode` still calls `axiosPublic` (fetch is never called).

- [ ] **Step 3: Write the session routes**

Create `src/lib/client-lane/portal/sessionRoutes.ts`:

```ts
/**
 * The two ways a device gets a client session from a share link (spec
 * 2026-10-06 portal §4.3), both route-handler side so the token never
 * reaches page JS:
 *
 * 1. `exchangeLane` — `POST /s/session/exchange`: right after a `?k=`
 *    capture (the `frnd_lane_new` marker), trade the lane for a session.
 *    Page JS triggers it, never a GET, so a mail scanner that prefetches a
 *    personal link creates no session and no "opened" view. The marker is
 *    cleared on EVERY outcome — the page can never loop.
 * 2. `verifyRequestLinkCode` — `POST /s/session/code`: the 6-digit code on
 *    a request link, spent server-side. Sets `frnd_lane` (what
 *    `persistLaneCookie` used to do from JS) and, when the api issued one,
 *    `frnd_client`; answers the lane only.
 */
import { NextResponse, type NextRequest } from "next/server";

import {
  CLIENT_SESSION_COOKIE,
  LANE_COOKIE,
  LANE_FRESH_COOKIE,
  clientSessionCookie,
  isClientSessionToken,
  isLaneCode,
  laneCookie,
  laneFreshCookie,
  laneMaxAge,
  shouldExchangeLane,
  type LaneCookieOptions,
} from "../cookie";
import { isSameOriginRequest } from "../sameOrigin";

import {
  SESSION_HEADER,
  apiBase,
  jsonResponse,
  stripSessionTokens,
  upstreamHeaders,
} from "./proxy";

const NO_STORE = { "Cache-Control": "no-store" } as const;

interface IssuedSession {
  session_token?: unknown;
  expires_at?: unknown;
}

function sessionCookieOf(issued: IssuedSession | null | undefined): LaneCookieOptions | null {
  if (!issued || typeof issued.session_token !== "string") return null;
  return clientSessionCookie(
    issued.session_token,
    typeof issued.expires_at === "string" ? issued.expires_at : null
  );
}

export async function exchangeLane(request: NextRequest): Promise<NextResponse> {
  if (!isSameOriginRequest(request)) {
    return jsonResponse({ message: "Cross-site request rejected." }, 403);
  }
  const lane = request.cookies.get(LANE_COOKIE)?.value;
  const fresh = request.cookies.get(LANE_FRESH_COOKIE)?.value;

  const done = (signedIn: boolean, cookie: LaneCookieOptions | null = null) => {
    const response = NextResponse.json({ signed_in: signedIn }, { headers: NO_STORE });
    response.cookies.set(laneFreshCookie(true));
    if (cookie) response.cookies.set(cookie);
    return response;
  };

  if (!shouldExchangeLane({ lane, fresh })) return done(false);

  const current = request.cookies.get(CLIENT_SESSION_COOKIE)?.value;
  let res: Response;
  try {
    res = await fetch(`${apiBase()}/public/client/session`, {
      method: "POST",
      headers: upstreamHeaders(request, {
        "Content-Type": "application/json",
        ...(isClientSessionToken(current) ? { [SESSION_HEADER]: current } : {}),
      }),
      body: JSON.stringify({ lane_code: lane }),
      cache: "no-store",
    });
  } catch {
    return done(false);
  }
  if (res.status !== 200) return done(false);
  const body = (await res.json().catch(() => null)) as { data?: IssuedSession } | null;
  const cookie = sessionCookieOf(body?.data);
  return done(cookie !== null, cookie);
}

export async function verifyRequestLinkCode(request: NextRequest): Promise<NextResponse> {
  if (!isSameOriginRequest(request)) {
    return jsonResponse({ message: "Cross-site request rejected." }, 403);
  }
  if (!(request.headers.get("content-type") ?? "").startsWith("application/json")) {
    return jsonResponse({ message: "Expected application/json." }, 415);
  }
  const input = (await request.json().catch(() => null)) as {
    email?: unknown;
    code?: unknown;
    share_token?: unknown;
  } | null;
  if (
    !input ||
    typeof input.email !== "string" ||
    typeof input.code !== "string" ||
    typeof input.share_token !== "string"
  ) {
    return jsonResponse({ message: "Invalid request." }, 422);
  }

  let res: Response;
  try {
    res = await fetch(`${apiBase()}/public/lane/code/verify`, {
      method: "POST",
      headers: upstreamHeaders(request, { "Content-Type": "application/json" }),
      body: JSON.stringify({
        email: input.email,
        code: input.code,
        share_token: input.share_token,
      }),
      cache: "no-store",
    });
  } catch {
    return jsonResponse(
      { message: "That didn't go through. Check your connection and try again." },
      502
    );
  }
  const payload = (await res.json().catch(() => null)) as
    | {
        data?: {
          lane_code?: unknown;
          kind?: unknown;
          expires_at?: unknown;
          session?: IssuedSession | null;
        };
      }
    | null;
  if (res.status !== 200) {
    return jsonResponse(stripSessionTokens(payload ?? {}), res.status);
  }
  const data = payload?.data;
  if (!data || !isLaneCode(data.lane_code)) {
    return jsonResponse({ message: "Bad gateway." }, 502);
  }
  const expiresAt = typeof data.expires_at === "string" ? data.expires_at : null;
  const response = jsonResponse(
    { data: { lane_code: data.lane_code, kind: data.kind, expires_at: expiresAt } },
    200
  );
  response.cookies.set(laneCookie(data.lane_code, laneMaxAge(expiresAt)));
  const session = sessionCookieOf(data.session);
  if (session) response.cookies.set(session);
  return response;
}
```

Create `src/app/s/session/exchange/route.ts`:

```ts
import type { NextRequest } from "next/server";

import { exchangeLane } from "@/lib/client-lane/portal/sessionRoutes";

/** Trade a freshly captured lane for a client session (spec 2026-10-06 portal §4.3). */
export const dynamic = "force-dynamic";

export async function POST(request: NextRequest) {
  return exchangeLane(request);
}
```

Create `src/app/s/session/code/route.ts`:

```ts
import type { NextRequest } from "next/server";

import { verifyRequestLinkCode } from "@/lib/client-lane/portal/sessionRoutes";

/** Spend a request link's 6-digit code server-side (spec 2026-10-06 portal §4.3). */
export const dynamic = "force-dynamic";

export async function POST(request: NextRequest) {
  return verifyRequestLinkCode(request);
}
```

`/s/session/route.ts` keeps GET, POST and DELETE unchanged. A folder with a `route.ts` may have child route folders.

- [ ] **Step 4: Move the code verify off the browser→api path**

In `src/lib/client-lane/publicApi.ts`, replace `verifyLaneCode` with:

```ts
/**
 * Spends the code THROUGH the web (`POST /s/session/code`): since the client
 * portal, a verified code also issues a client session, and its token must
 * never reach page JS — the route sets `frnd_lane` + `frnd_client` and
 * answers the lane only. A failure rejects in the axios shape
 * (`{ response: { status, data } }`) so `publicApiError` reads
 * `422 invalid_code` (with `attempts_left`) / `code_expired` / `429`
 * exactly as before.
 */
export async function verifyLaneCode(
  email: string,
  code: string,
  shareToken: string
): Promise<LaneCodeVerified> {
  const res = await fetch("/s/session/code", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email, code, share_token: shareToken }),
    cache: "no-store",
  });
  const body = (await res.json().catch(() => null)) as
    | { data?: LaneCodeVerified }
    | Record<string, unknown>
    | null;
  if (!res.ok) {
    throw Object.assign(new Error("Lane code verify failed"), {
      response: { status: res.status, data: body ?? {} },
    });
  }
  return (body as { data: LaneCodeVerified }).data;
}
```

In `src/lib/client-lane/laneCode.ts`:
- delete the `persistLaneCookie` function and its doc comment;
- in `confirmLaneCode`, delete the line `await persistLaneCookie(lane);`;
- change the module comment's "ask for a code, spend it, cookie the lane" to "ask for a code, spend it (the `/s/session/code` route cookies the lane and the client session)".

Then confirm nothing else used it:

```bash
cd WT && /usr/bin/grep -rn "persistLaneCookie" src || echo "no callers left"
```

Expected: `no callers left`.

- [ ] **Step 5: Run the tests, the old consumers, and prove each named mutation**

```bash
cd WT && for f in src/lib/client-lane/portal/sessionRoutes.test.ts src/lib/client-lane/publicApi.transport.test.ts src/components/client-lane/DecisionPage.test.tsx; do echo "== $f"; bun test "$f" 2>&1 | /usr/bin/grep -E "^[[:space:]]*[0-9]+ (pass|fail)|^\(fail\)|[0-9]+ error"; done
```

Expected: the new files show `0 fail`. `DecisionPage.test.tsx` shows its Task 0 list. Apply each mutation, watch its test fail, and restore.

- [ ] **Step 6: Lint, format, commit**

```bash
cd WT && F=(src/lib/client-lane/portal/sessionRoutes.ts src/lib/client-lane/portal/sessionRoutes.test.ts src/app/s/session/exchange/route.ts src/app/s/session/code/route.ts src/lib/client-lane/publicApi.ts src/lib/client-lane/publicApi.transport.test.ts src/lib/client-lane/laneCode.ts) && ./node_modules/.bin/prettier --write src/lib/client-lane/portal/sessionRoutes.ts src/lib/client-lane/portal/sessionRoutes.test.ts src/app/s/session/exchange/route.ts src/app/s/session/code/route.ts src/lib/client-lane/publicApi.transport.test.ts && ./node_modules/.bin/eslint "${F[@]}" && /usr/bin/git add "${F[@]}" && /usr/bin/git commit -F - <<'EOF'
feat(web): lane-to-session exchange and server-side request-link code verify

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---
### Task 8: Server-side `me` and the browser portal service

**Files:**
- Create: `src/lib/client-lane/portal/me.ts`
- Test: `src/lib/client-lane/portal/me.test.ts`
- Create: `src/lib/client-lane/portal/server.ts`
- Modify: `src/lib/client-lane/server.ts` (`resolvePublicShareServer` third parameter)
- Create: `src/services/client-portal.ts`
- Test: `src/services/client-portal.test.ts`

**Interfaces:**
- Consumes: `PortalMe`, `PortalApprovals` (Task 1); `portalErrorAction` (Task 2); `SESSION_HEADER`, `apiBase` (Task 5); `publicApiError` (`publicApi.ts`); `axiosPublic` (`@/services/axios`).
- Produces:
  - `fetchPortalMe(sessionToken)`: `Promise<PortalMe | null>`. It is null on 401/404 and throws otherwise;
  - `resolvePortalMeServer`: React `cache(fetchPortalMe)`;
  - `resolvePublicShareServer(token, laneCode, sessionToken = null)`;
  - in `client-portal.ts`:
    - `PORTAL_PROXY_BASE = "/s/api/portal/"`;
    - `portalApprovalsKey(ws, brand)`;
    - `fetchPortalApprovals(ws, brand, cursor)`;
    - `requestPortalCode(ws, brand, email)`;
    - `verifyPortalCode(ws, brand, email, code)`: `Promise<{ signed_in: true; expires_at: string | null }>`;
    - `signOutPortal()`;
    - `usePortalApprovals(ws, brand)`.

`me.ts` holds the plain fetch, and `server.ts` only wraps it in React `cache`. The test imports `me.ts`, so it never evaluates `cache()` outside a server-component environment.

- [ ] **Step 1: Write the failing tests**

Create `src/lib/client-lane/portal/me.test.ts`:

```ts
import { beforeEach, describe, expect, it, vi } from "vitest";

import { portalMe } from "./fixtures";
import { fetchPortalMe } from "./me";

const TOKEN = "s".repeat(43);

function apiAnswers(status: number, body: unknown) {
  return vi.spyOn(globalThis, "fetch").mockResolvedValue(
    new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    })
  );
}

describe("fetchPortalMe (spec §5.1)", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    process.env.NEXT_PUBLIC_API_URL = "https://api.test";
  });

  it("asks the api with the session header, never a cache", async () => {
    const me = portalMe();
    const spy = apiAnswers(200, { data: me });
    await expect(fetchPortalMe(TOKEN)).resolves.toEqual(me);
    const [url, init] = spy.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("https://api.test/public/portal/me");
    expect(new Headers(init.headers).get("X-Client-Session")).toBe(TOKEN);
    expect(init.cache).toBe("no-store");
  });

  it("reads a lost session as signed out", async () => {
    apiAnswers(401, { code: "session_required" });
    await expect(fetchPortalMe(TOKEN)).resolves.toBeNull();
  });

  it("throws on an outage so the error boundary shows, not a sign-in lie", async () => {
    apiAnswers(503, { message: "down" });
    await expect(fetchPortalMe(TOKEN)).rejects.toThrow("503");
  });
});
```

Create `src/services/client-portal.test.ts`:

```ts
import { beforeEach, describe, expect, it, vi } from "vitest";

import { axiosPublic } from "@/services/axios";

import {
  PORTAL_PROXY_BASE,
  fetchPortalApprovals,
  portalApprovalsKey,
  requestPortalCode,
  signOutPortal,
  verifyPortalCode,
} from "./client-portal";

describe("client portal service — always the same-origin BFF (spec §6.1)", () => {
  beforeEach(() => vi.restoreAllMocks());

  it("reads the first approvals page without a cursor", async () => {
    const get = vi
      .spyOn(axiosPublic, "get")
      .mockResolvedValue({ data: { data: {} } } as never);
    await fetchPortalApprovals("fcn", "frndglow", null);
    expect(get).toHaveBeenCalledWith("fcn/frndglow/approvals", {
      baseURL: PORTAL_PROXY_BASE,
    });
  });

  it("asks for older decided rows with the cursor, slugs encoded", async () => {
    const get = vi
      .spyOn(axiosPublic, "get")
      .mockResolvedValue({ data: { data: {} } } as never);
    await fetchPortalApprovals("a b", "frndglow", "c1");
    expect(get).toHaveBeenCalledWith("a%20b/frndglow/approvals", {
      baseURL: PORTAL_PROXY_BASE,
      params: { decided_cursor: "c1" },
    });
  });

  it("requests and verifies a code, and signs out, through the BFF", async () => {
    const post = vi.spyOn(axiosPublic, "post").mockResolvedValueOnce({
      status: 202,
      data: {},
    } as never);
    await requestPortalCode("fcn", "frndglow", "dina@brand.co");
    expect(post).toHaveBeenLastCalledWith(
      "fcn/frndglow/code",
      { email: "dina@brand.co" },
      { baseURL: PORTAL_PROXY_BASE }
    );
    post.mockResolvedValueOnce({
      data: { data: { signed_in: true, expires_at: null } },
    } as never);
    await expect(
      verifyPortalCode("fcn", "frndglow", "dina@brand.co", "123456")
    ).resolves.toEqual({ signed_in: true, expires_at: null });
    expect(post).toHaveBeenLastCalledWith(
      "fcn/frndglow/code/verify",
      { email: "dina@brand.co", code: "123456" },
      { baseURL: PORTAL_PROXY_BASE }
    );
    const del = vi
      .spyOn(axiosPublic, "delete")
      .mockResolvedValue({ status: 204 } as never);
    await signOutPortal();
    expect(del).toHaveBeenCalledWith("session", { baseURL: PORTAL_PROXY_BASE });
  });

  it("keys approvals by both slugs", () => {
    expect(portalApprovalsKey("fcn", "frndglow")).toEqual([
      "portal",
      "fcn",
      "frndglow",
      "approvals",
    ]);
  });
});
```

Mutations:
- Send `params: { decided_cursor: null }` on the first page, and "reads the first approvals page without a cursor" fails.
- Skip `encodeURIComponent`, and "slugs encoded" fails.
- Make `fetchPortalMe` return null on 503, and "throws on an outage" fails.

- [ ] **Step 2: Run them to verify they fail**

Run: `cd WT && bun test src/lib/client-lane/portal/me.test.ts`, then `bun test src/services/client-portal.test.ts`
Expected: both FAIL. The modules are not found.

- [ ] **Step 3: Write the server side**

Create `src/lib/client-lane/portal/me.ts`:

```ts
/**
 * `GET public/portal/me` from the SERVER (the portal page and the review
 * page's server component). Plain `fetch`, `no-store`: a revoked lane must
 * never render from a stale copy. Null = signed out (401) or nothing to show
 * (404); any other failure throws so the route's error boundary shows
 * rather than a sign-in screen lying about an outage.
 */
import { SESSION_HEADER, apiBase } from "./proxy";
import type { PortalMe } from "./types";

export async function fetchPortalMe(sessionToken: string): Promise<PortalMe | null> {
  const res = await fetch(`${apiBase()}/public/portal/me`, {
    headers: { Accept: "application/json", [SESSION_HEADER]: sessionToken },
    cache: "no-store",
  });
  if (res.status === 401 || res.status === 404) return null;
  if (!res.ok) throw new Error(`portal me failed: ${res.status}`);
  return ((await res.json()) as { data: PortalMe }).data;
}
```

Create `src/lib/client-lane/portal/server.ts`:

```ts
// Server-side only: imported by the /s/[token] and /s/[token]/[brand] server
// components. Never import from a client file.
import { cache } from "react";

import { fetchPortalMe } from "./me";

/** One `me` call per request, shared by a page and its metadata. */
export const resolvePortalMeServer = cache(fetchPortalMe);
```

In `src/lib/client-lane/server.ts`, change `resolvePublicShareServer`'s signature and headers. It becomes:

```ts
export const resolvePublicShareServer = cache(
  async (
    token: string,
    laneCode: string | null,
    /** The `frnd_client` session (spec 2026-10-06 portal §4.5): the api
     *  resolves the viewer from it first, then from the lane code. */
    sessionToken: string | null = null
  ): Promise<ShareLinkData | PublicScorecardReportShare | null> => {
    const base = (process.env.NEXT_PUBLIC_API_URL ?? "").replace(/\/$/, "");
    const headers: Record<string, string> = { Accept: "application/json" };
    if (laneCode) headers["X-Lane-Code"] = laneCode;
    if (sessionToken) headers["X-Client-Session"] = sessionToken;
```

The rest of the body is unchanged. `resolveShareLinkServer(token, laneCode)` (the OG image) keeps calling it with two arguments, because the OG crawler has no session.

- [ ] **Step 4: Write the browser service**

Create `src/services/client-portal.ts`:

```ts
/**
 * The client portal's browser calls (spec 2026-10-06 portal §5–§6). Every
 * call goes to the SAME-ORIGIN BFF (`/s/api/portal/*`), never to the api:
 * the session lives in the HttpOnly `frnd_client` cookie, which only the
 * route handler reads and forwards. `axiosPublic` (no auth interceptor) with
 * a per-call `baseURL`.
 */
import { useInfiniteQuery } from "@tanstack/react-query";

import { portalErrorAction } from "@/lib/client-lane/portal/shell";
import type { PortalApprovals } from "@/lib/client-lane/portal/types";
import { publicApiError } from "@/lib/client-lane/publicApi";
import { axiosPublic } from "@/services/axios";

export const PORTAL_PROXY_BASE = "/s/api/portal/";

const brandPath = (workspaceSlug: string, brandSlug: string) =>
  `${encodeURIComponent(workspaceSlug)}/${encodeURIComponent(brandSlug)}`;

export const portalApprovalsKey = (workspaceSlug: string, brandSlug: string) =>
  ["portal", workspaceSlug, brandSlug, "approvals"] as const;

export async function fetchPortalApprovals(
  workspaceSlug: string,
  brandSlug: string,
  cursor: string | null
): Promise<PortalApprovals> {
  const res = await axiosPublic.get<{ data: PortalApprovals }>(
    `${brandPath(workspaceSlug, brandSlug)}/approvals`,
    {
      baseURL: PORTAL_PROXY_BASE,
      ...(cursor ? { params: { decided_cursor: cursor } } : {}),
    }
  );
  return res.data.data;
}

/** Always 202 from the api — the screen never learns whether the address can sign in. */
export async function requestPortalCode(
  workspaceSlug: string,
  brandSlug: string,
  email: string
): Promise<void> {
  await axiosPublic.post(
    `${brandPath(workspaceSlug, brandSlug)}/code`,
    { email },
    { baseURL: PORTAL_PROXY_BASE }
  );
}

/** The BFF sets the cookie and answers without the token. */
export async function verifyPortalCode(
  workspaceSlug: string,
  brandSlug: string,
  email: string,
  code: string
): Promise<{ signed_in: true; expires_at: string | null }> {
  const res = await axiosPublic.post<{
    data: { signed_in: true; expires_at: string | null };
  }>(
    `${brandPath(workspaceSlug, brandSlug)}/code/verify`,
    { email, code },
    { baseURL: PORTAL_PROXY_BASE }
  );
  return res.data.data;
}

export async function signOutPortal(): Promise<void> {
  await axiosPublic.delete("session", { baseURL: PORTAL_PROXY_BASE });
}

/**
 * The inbox: the first page carries every group; "Show older" walks the
 * decided cursor. A 401/404 is not retried — the page goes back to sign-in.
 */
export function usePortalApprovals(workspaceSlug: string, brandSlug: string) {
  return useInfiniteQuery({
    queryKey: portalApprovalsKey(workspaceSlug, brandSlug),
    queryFn: ({ pageParam }) =>
      fetchPortalApprovals(workspaceSlug, brandSlug, pageParam),
    initialPageParam: null as string | null,
    getNextPageParam: (last: PortalApprovals) =>
      last.decided_next_cursor ?? undefined,
    staleTime: 15_000,
    retry: (failureCount, error) =>
      portalErrorAction(publicApiError(error).status) === "retry" &&
      failureCount < 2,
  });
}
```

- [ ] **Step 5: Run the tests to verify they pass, then prove each named mutation**

Run: `cd WT && bun test src/lib/client-lane/portal/me.test.ts`, then `bun test src/services/client-portal.test.ts`
Expected: PASS. Apply each mutation, watch its test fail, and restore.

- [ ] **Step 6: Lint, format, commit**

```bash
cd WT && F=(src/lib/client-lane/portal/me.ts src/lib/client-lane/portal/me.test.ts src/lib/client-lane/portal/server.ts src/lib/client-lane/server.ts src/services/client-portal.ts src/services/client-portal.test.ts) && ./node_modules/.bin/prettier --write src/lib/client-lane/portal/me.ts src/lib/client-lane/portal/me.test.ts src/lib/client-lane/portal/server.ts src/services/client-portal.ts src/services/client-portal.test.ts && ./node_modules/.bin/eslint "${F[@]}" && /usr/bin/git add "${F[@]}" && /usr/bin/git commit -F - <<'EOF'
feat(web): server-side portal me and the browser portal service

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 9: Analytics helpers for the portal, the Clients tab and suggestions

**Files:**
- Modify: `src/lib/analytics/client-lane-events.ts` (append; import types)
- Test: `src/lib/analytics/client-lane-events.portal.test.ts`

**Interfaces:**
- Consumes: `ClientAccessLevel`, `PortalGroup` (Task 1); `ShareSubjectType`.
- Produces:
  - portal (public, PII-free): `trackPortalViewed`, `trackPortalBrandSwitched`, `trackPortalItemOpened`, `trackPortalSigninCodeRequested`, `trackPortalSigninVerified`, `trackPortalSigninFailed`, `trackPortalSignedOut`;
  - agency: `ClientAccessChangeSource`, `trackClientAccessChanged`, `trackClientAccessChangeFailed`, `trackClientPortalLinkCopied`, `trackClientPortalLinkCopyFailed`, `trackClientRemoved`, `trackClientRemoveFailed`, `trackApproverSuggestionPicked`.

  Every name is `client_lane.<event>`, as spec §6.6 and §7.2–§7.3 list it. The `*_failed` twins follow the module's own convention ("every flow that can fail carries its failure twin") and the `frndos-analytics-events` skill (mutation success AND failure).

- [ ] **Step 1: Load the analytics skill**

Read `WT/.claude/skills/frndos-analytics-events/SKILL.md` and its `references/event-conventions.md`. Base context is automatic, so do not pass it. Public events carry no PII.

- [ ] **Step 2: Write the failing test**

Create `src/lib/analytics/client-lane-events.portal.test.ts`:

```ts
import posthog from "posthog-js";
import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  trackApproverSuggestionPicked,
  trackClientAccessChanged,
  trackClientAccessChangeFailed,
  trackClientPortalLinkCopied,
  trackClientPortalLinkCopyFailed,
  trackClientRemoved,
  trackClientRemoveFailed,
  trackPortalBrandSwitched,
  trackPortalItemOpened,
  trackPortalSignedOut,
  trackPortalSigninCodeRequested,
  trackPortalSigninFailed,
  trackPortalSigninVerified,
  trackPortalViewed,
} from "./client-lane-events";

describe("client portal events (spec §6.6, §7.2, §7.3)", () => {
  beforeEach(() => vi.restoreAllMocks());

  it("fires each event under its taxonomy name", () => {
    const capture = vi
      .spyOn(posthog, "capture")
      .mockImplementation(() => undefined as never);
    trackPortalViewed({ access_level: "own", waiting_on_you: 2 });
    trackPortalBrandSwitched({ brand_count: 2 });
    trackPortalItemOpened({ group: "decided", subject_type: "deck" });
    trackPortalSigninCodeRequested({ resend: false });
    trackPortalSigninVerified();
    trackPortalSigninFailed({ stage: "verify", reason: "invalid_code", http_status: 422 });
    trackPortalSignedOut({ surface: "portal" });
    trackClientAccessChanged({ from: "own", to: "all_view", source: "clients_tab" });
    trackClientAccessChangeFailed({ source: "clients_tab", reason: "network", http_status: null });
    trackClientPortalLinkCopied();
    trackClientPortalLinkCopyFailed({ reason: "unknown", http_status: 500 });
    trackClientRemoved({ access_level: "own" });
    trackClientRemoveFailed({ reason: "unknown", http_status: 500 });
    trackApproverSuggestionPicked({ subject_type: "kv_file", access_level: "all_view" });
    expect(capture.mock.calls.map(([name]) => name)).toEqual([
      "client_lane.portal_viewed",
      "client_lane.portal_brand_switched",
      "client_lane.portal_item_opened",
      "client_lane.portal_signin_code_requested",
      "client_lane.portal_signin_verified",
      "client_lane.portal_signin_failed",
      "client_lane.portal_signed_out",
      "client_lane.client_access_changed",
      "client_lane.client_access_change_failed",
      "client_lane.client_portal_link_copied",
      "client_lane.client_portal_link_copy_failed",
      "client_lane.client_removed",
      "client_lane.client_remove_failed",
      "client_lane.approver_suggestion_picked",
    ]);
  });

  it("sends the access level and the waiting count on a portal view", () => {
    const capture = vi
      .spyOn(posthog, "capture")
      .mockImplementation(() => undefined as never);
    trackPortalViewed({ access_level: "all_view", waiting_on_you: 0 });
    expect(capture).toHaveBeenCalledWith(
      "client_lane.portal_viewed",
      expect.objectContaining({ access_level: "all_view", waiting_on_you: 0 })
    );
  });
});
```

Mutation: misspell one name (e.g. `client_lane.portal_signout`), and the first test fails.

- [ ] **Step 3: Run it to verify it fails**

Run: `cd WT && bun test src/lib/analytics/client-lane-events.portal.test.ts`
Expected: FAIL. The imports do not exist (one `error` line).

- [ ] **Step 4: Write the helpers**

In `src/lib/analytics/client-lane-events.ts`, add to the imports:

```ts
import type {
  ClientAccessLevel,
  PortalGroup,
} from "@/lib/client-lane/portal/types";
```

Append at the end of the file:

```ts
/* ── Client portal (spec 2026-10-06 portal §6.6) — PUBLIC, PII-free ──── */

/** The Approvals page of a brand loaded (once per brand per page view). */
export const trackPortalViewed = (props: {
  access_level: ClientAccessLevel;
  waiting_on_you: number;
}) => safeCapture("client_lane.portal_viewed", props);

/** The header switcher picked another brand. */
export const trackPortalBrandSwitched = (props: { brand_count: number }) =>
  safeCapture("client_lane.portal_brand_switched", props);

/** A card's Review or a row was opened. */
export const trackPortalItemOpened = (props: {
  group: PortalGroup;
  subject_type: ShareSubjectType;
}) => safeCapture("client_lane.portal_item_opened", props);

export const trackPortalSigninCodeRequested = (props: { resend: boolean }) =>
  safeCapture("client_lane.portal_signin_code_requested", props);

export const trackPortalSigninVerified = () =>
  safeCapture("client_lane.portal_signin_verified");

export const trackPortalSigninFailed = (props: {
  stage: "request" | "verify";
  reason: string;
  http_status: number | null;
}) => safeCapture("client_lane.portal_signin_failed", props);

/** Where "Sign out this device" was used. */
export const trackPortalSignedOut = (props: {
  surface: "portal" | "review_page";
}) => safeCapture("client_lane.portal_signed_out", props);

/* ── Clients tab + approver picker (spec §7.2, §7.3) — agency side ──── */

/** Where an access level was changed. */
export type ClientAccessChangeSource = "clients_tab" | "approver_picker";

export const trackClientAccessChanged = (props: {
  from: ClientAccessLevel;
  to: ClientAccessLevel;
  source: ClientAccessChangeSource;
}) => safeCapture("client_lane.client_access_changed", props);

export const trackClientAccessChangeFailed = (props: {
  source: ClientAccessChangeSource;
  reason: string;
  http_status: number | null;
}) => safeCapture("client_lane.client_access_change_failed", props);

export const trackClientPortalLinkCopied = () =>
  safeCapture("client_lane.client_portal_link_copied");

export const trackClientPortalLinkCopyFailed = (props: {
  reason: string;
  http_status: number | null;
}) => safeCapture("client_lane.client_portal_link_copy_failed", props);

export const trackClientRemoved = (props: { access_level: ClientAccessLevel }) =>
  safeCapture("client_lane.client_removed", props);

export const trackClientRemoveFailed = (props: {
  reason: string;
  http_status: number | null;
}) => safeCapture("client_lane.client_remove_failed", props);

/** A suggested client was added as an approver (spec §7.3). */
export const trackApproverSuggestionPicked = (props: {
  subject_type: ShareSubjectType;
  access_level: ClientAccessLevel;
}) => safeCapture("client_lane.approver_suggestion_picked", props);
```

`safeCapture(event)` with no props works: the second parameter defaults to `{}`.

- [ ] **Step 5: Run the test to verify it passes, then prove the mutation**

Run: `cd WT && bun test src/lib/analytics/client-lane-events.portal.test.ts`
Expected: PASS. Apply the mutation, watch it fail, and restore.

- [ ] **Step 6: Lint, format, commit**

Check that `client-lane-events.ts` is prettier-clean on BASE before running prettier on it.

```bash
cd WT && F=(src/lib/analytics/client-lane-events.ts src/lib/analytics/client-lane-events.portal.test.ts) && ./node_modules/.bin/prettier --write src/lib/analytics/client-lane-events.portal.test.ts && ./node_modules/.bin/eslint "${F[@]}" && /usr/bin/git add "${F[@]}" && /usr/bin/git commit -F - <<'EOF'
feat(web): analytics for the client portal, the Clients tab and approver suggestions

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---
## Phase 3 — the portal (public, dark-scoped)

**Before Tasks 10–14:** read `WT/.claude/skills/frndos-ui/SKILL.md`, then `frndos-components-v2/SKILL.md` (§Aturan Prioritas, §Visual Consistency), `frndos-components/SKILL.md` (Avatar, Input, EmptyState, Label, ProgressBar), `frndos-design-foundations/SKILL.md` (§Text tokens, §Appearance Themes) and `frndos-rules/SKILL.md` (Toast). Spec §9 is the component map, and every row below cites it.

### Task 10: Portal shell — frame, header (switcher + account menu), nav

**Files:**
- Modify: `src/components/client-lane/RequestRail.tsx` (`const RAIL_CARD` → `export const RAIL_CARD`)
- Create: `src/components/client-lane/portal/PortalFrame.tsx`
- Create: `src/components/client-lane/portal/PortalHeader.tsx`
- Create: `src/components/client-lane/portal/PortalNav.tsx`
- Create: `src/components/client-lane/portal/PortalViewOnlyNotice.tsx`
- Test: `src/components/client-lane/portal/PortalHeader.test.tsx`

**Interfaces:**
- Consumes: `brandKey`, `brandTitle`, `portalHref`, `showSwitcher`, `switcherOptions` (Task 2); `signOutPortal` (Task 8); `trackPortalBrandSwitched`, `trackPortalSignedOut` (Task 9); `PersonAvatar` (`../agency/PersonAvatar`, the v1 `Avatar` wrapper); v2 `SelectMenu`, `ActionMenu`, `SegmentedTabs`, `CountBadge`.
- Produces:
  - `PortalFrame({ children })`;
  - `PortalHeader({ me, current, surface, onSignedOut?, onNavigate? })`;
  - `PortalNav({ waiting })`;
  - `PortalViewOnlyNotice({ text, className? })`;
  - `RAIL_CARD`, now exported.

§9 mapping and the two places it cannot be followed literally:

| Surface | Component |
|---|---|
| Brand switcher "frndGlow · via FCN ▾" | v2 `SelectMenu`, `appearance="text"`. The per-brand count uses `SelectMenuOption.count` (a quiet tabular number in the row). `SelectMenu` has no node slot for a `CountBadge` in an option, and spec P-8 forbids changing a v2 API. Reported as a spec/code mismatch. |
| Account menu "Dina ▾ → Sign out this device" | v2 `ActionMenu`. Its trigger is the fixed "•••" button. The avatar and name sit beside it (the name is hidden below `sm`), and the trigger's accessible name is "Account menu for {name}". `ActionMenu` takes no custom trigger. Reported. |
| Client avatar | v1 `Avatar` through `PersonAvatar` |
| Nav "Approvals (n)" | v2 `SegmentedTabs` (one item) + v2 `CountBadge`, with an sr-only count because `CountBadge` is `aria-hidden` |
| View-only notice | `RAIL_CARD` note |

- [ ] **Step 1: Write the failing test**

Create `src/components/client-lane/portal/PortalHeader.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { render, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import posthog from "posthog-js";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { portalBrand, portalMe } from "@/lib/client-lane/portal/fixtures";
import { axiosPublic } from "@/services/axios";

import { PortalHeader } from "./PortalHeader";

const body = () => within(document.body);

const garuda = portalBrand({
  workspace: { name: "Alva", slug: "alva" },
  brand: { name: "Garuda", slug: "garuda", logo_url: null },
  waiting_on_you: 0,
});

describe("PortalHeader (spec §6.2)", () => {
  beforeEach(() => vi.restoreAllMocks());

  it("signs this device out, then hands over", async () => {
    const user = userEvent.setup();
    const del = vi
      .spyOn(axiosPublic, "delete")
      .mockResolvedValue({ status: 204, data: "" } as never);
    const capture = vi
      .spyOn(posthog, "capture")
      .mockImplementation(() => undefined as never);
    const onSignedOut = vi.fn();
    render(
      <PortalHeader
        me={portalMe()}
        current={portalBrand()}
        surface="portal"
        onSignedOut={onSignedOut}
      />
    );
    await user.click(
      body().getByRole("button", { name: "Account menu for Dina Pratiwi" })
    );
    await user.click(
      await body().findByRole("menuitem", { name: "Sign out this device" })
    );
    await waitFor(() => expect(onSignedOut).toHaveBeenCalledTimes(1));
    expect(del).toHaveBeenCalledWith("session", { baseURL: "/s/api/portal/" });
    expect(capture).toHaveBeenCalledWith(
      "client_lane.portal_signed_out",
      expect.objectContaining({ surface: "portal" })
    );
  });

  it("switches brand through the menu", async () => {
    const user = userEvent.setup();
    const capture = vi
      .spyOn(posthog, "capture")
      .mockImplementation(() => undefined as never);
    const onNavigate = vi.fn();
    const me = portalMe({ brands: [portalBrand(), garuda] });
    render(
      <PortalHeader
        me={me}
        current={me.brands[0]}
        surface="portal"
        onNavigate={onNavigate}
      />
    );
    await user.click(
      body().getByRole("button", { name: "Switch brand: frndGlow · via FCN" })
    );
    await user.click(
      await body().findByRole("menuitemradio", { name: /Garuda · via Alva/ })
    );
    expect(onNavigate).toHaveBeenCalledWith("/s/alva/garuda");
    expect(capture).toHaveBeenCalledWith(
      "client_lane.portal_brand_switched",
      expect.objectContaining({ brand_count: 2 })
    );
  });

  it("shows the brand as plain text for a one-brand client", () => {
    render(
      <PortalHeader me={portalMe()} current={portalBrand()} surface="portal" />
    );
    expect(body().queryByRole("button", { name: /Switch brand/ })).toBeNull();
    expect(body().getByText("frndGlow")).toBeInTheDocument();
  });
});
```

Mutations:
- Drop `trackPortalSignedOut` from the sign-out handler, and "signs this device out" fails.
- Call `onNavigate(portalHref(current))` instead of the target, and "switches brand" fails.
- Render the switcher regardless of `showSwitcher`, and the one-brand test fails.

- [ ] **Step 2: Run it to verify it fails**

Run: `cd WT && bun test src/components/client-lane/portal/PortalHeader.test.tsx`
Expected: FAIL. `./PortalHeader` is not found.

- [ ] **Step 3: Export `RAIL_CARD`**

In `src/components/client-lane/RequestRail.tsx`, change `const RAIL_CARD =` to `export const RAIL_CARD =`. No other change.

- [ ] **Step 4: Write the shell components**

Create `src/components/client-lane/portal/PortalFrame.tsx`:

```tsx
import type { ReactNode } from "react";

/**
 * The portal's page ground (spec 2026-10-06 portal §6). Dark-scoped like the
 * rest of `/s` — `data-theme-scope="dark"` keeps Midnight under any viewer
 * theme and `data-client-lane-page` restores the Midnight token values the
 * shared components read (theme-light.css). Phones: globals.css locks
 * html/body scrolling ≤768px for the app shell, so this page scrolls itself,
 * as `DecisionPage` does. 16px gutters on a phone.
 */
export function PortalFrame({ children }: { children: ReactNode }) {
  return (
    <div
      data-theme-scope="dark"
      data-client-lane-page=""
      className="min-h-dvh bg-black font-geist [@media(max-width:768px)]:h-dvh [@media(max-width:768px)]:overflow-y-auto [@media(max-width:768px)]:overscroll-contain"
    >
      <div className="mx-auto flex w-full max-w-[880px] flex-col gap-6 px-4 pb-10 pt-4 sm:px-6">
        {children}
      </div>
    </div>
  );
}
```

Create `src/components/client-lane/portal/PortalHeader.tsx`:

```tsx
"use client";

import { SignOut } from "@phosphor-icons/react";

import { ActionMenu, SelectMenu } from "@/components/frndos/v2";
import {
  trackPortalBrandSwitched,
  trackPortalSignedOut,
} from "@/lib/analytics/client-lane-events";
import {
  brandKey,
  portalHref,
  showSwitcher,
  switcherOptions,
} from "@/lib/client-lane/portal/shell";
import type { PortalBrand, PortalMe } from "@/lib/client-lane/portal/types";
import { signOutPortal } from "@/services/client-portal";
import { useToastStore } from "@/store/useToast";

import { PersonAvatar } from "../agency/PersonAvatar";

export interface PortalHeaderProps {
  me: PortalMe;
  current: PortalBrand;
  surface: "portal" | "review_page";
  /** Default: reload — the server then renders the signed-out page. */
  onSignedOut?: () => void;
  /** Default: a full navigation (the portal is a public page). */
  onNavigate?: (href: string) => void;
}

/**
 * The portal header (spec §6.2, §9): brand logo, "frndGlow · via FCN" — a
 * brand switcher when the person has more than one brand — and on the right
 * their avatar, name and an account menu with "Sign out this device". On a
 * phone the name drops; the switcher and the menu stay.
 */
export function PortalHeader({
  me,
  current,
  surface,
  onSignedOut = () => window.location.reload(),
  onNavigate = (href) => window.location.assign(href),
}: PortalHeaderProps) {
  const showToast = useToastStore((s) => s.showToast);
  const logo =
    current.brand.logo_url && /^https?:\/\//.test(current.brand.logo_url)
      ? current.brand.logo_url
      : null;

  const signOut = async () => {
    try {
      await signOutPortal();
      trackPortalSignedOut({ surface });
      onSignedOut();
    } catch {
      showToast(
        "Couldn't sign out",
        "Check your connection and try again.",
        "error"
      );
    }
  };

  return (
    <header className="flex items-center justify-between gap-3 font-geist">
      <div className="flex min-w-0 items-center gap-2">
        {logo ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={logo}
            alt=""
            className="size-6 shrink-0 rounded-full object-cover"
          />
        ) : null}
        {showSwitcher(me) ? (
          <SelectMenu
            ariaLabel="Switch brand"
            appearance="text"
            align="start"
            options={switcherOptions(me)}
            value={brandKey(current)}
            onChange={(next) => {
              const target = me.brands.find((b) => brandKey(b) === next);
              if (!target) return;
              trackPortalBrandSwitched({ brand_count: me.brands.length });
              onNavigate(portalHref(target));
            }}
          />
        ) : (
          <p className="min-w-0 truncate text-textSm text-text-inverse-subtle">
            <span className="text-textSmMedium text-text-inverse">
              {current.brand.name}
            </span>
            {` · via ${current.workspace.name}`}
          </p>
        )}
      </div>
      <div className="flex shrink-0 items-center gap-1.5">
        <PersonAvatar name={me.user.name} />
        <span className="max-w-[160px] truncate text-textSm text-text-inverse max-sm:hidden">
          {me.user.name}
        </span>
        <ActionMenu
          ariaLabel={`Account menu for ${me.user.name}`}
          items={[
            {
              id: "sign-out",
              label: "Sign out this device",
              icon: <SignOut size={14} aria-hidden />,
              onSelect: () => void signOut(),
            },
          ]}
        />
      </div>
    </header>
  );
}
```

Create `src/components/client-lane/portal/PortalNav.tsx`:

```tsx
"use client";

import { CountBadge, SegmentedTabs } from "@/components/frndos/v2";

/**
 * The portal's sections (spec §6.2): "Approvals" with its waiting count.
 * Insights stays hidden until its stage. `CountBadge` is aria-hidden, so the
 * count is repeated for screen readers.
 */
export function PortalNav({ waiting }: { waiting: number }) {
  return (
    <SegmentedTabs
      aria-label="Portal sections"
      value="approvals"
      onValueChange={() => undefined}
      items={[
        {
          value: "approvals",
          label: (
            <span className="flex items-center gap-1.5">
              Approvals
              <CountBadge count={waiting} />
              {waiting > 0 ? (
                <span className="sr-only">{`, ${waiting} waiting on you`}</span>
              ) : null}
            </span>
          ),
        },
      ]}
    />
  );
}
```

Create `src/components/client-lane/portal/PortalViewOnlyNotice.tsx`:

```tsx
import clsx from "clsx";

import { RAIL_CARD } from "../RequestRail";

/** The `all_view` notice (spec §6.3, §6.5) — a client-lane card note. */
export function PortalViewOnlyNotice({
  text,
  className,
}: {
  text: string;
  className?: string;
}) {
  return (
    <p
      role="status"
      className={clsx(RAIL_CARD, "text-textSm text-text-inverse-subtle", className)}
    >
      {text}
    </p>
  );
}
```

- [ ] **Step 5: Run the test to verify it passes, then prove each named mutation**

Run: `cd WT && bun test src/components/client-lane/portal/PortalHeader.test.tsx`
Expected: PASS, with no `error` line. If the Base UI menu needs a second tick to open in jsdom, wrap the `findByRole` in RTL `waitFor`. Do not add `vi.useFakeTimers`. Apply each mutation, watch its test fail, and restore.

- [ ] **Step 6: Lint, format, commit**

```bash
cd WT && F=(src/components/client-lane/RequestRail.tsx src/components/client-lane/portal/PortalFrame.tsx src/components/client-lane/portal/PortalHeader.tsx src/components/client-lane/portal/PortalNav.tsx src/components/client-lane/portal/PortalViewOnlyNotice.tsx src/components/client-lane/portal/PortalHeader.test.tsx) && ./node_modules/.bin/prettier --write src/components/client-lane/portal/*.tsx && ./node_modules/.bin/eslint "${F[@]}" && /usr/bin/git add "${F[@]}" && /usr/bin/git commit -F - <<'EOF'
feat(web): portal shell — header with brand switcher and account menu, nav

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 11: The Approvals page and `PortalApp`

**Files:**
- Create: `src/components/client-lane/portal/PortalEmptyState.tsx`
- Create: `src/components/client-lane/portal/WaitingCard.tsx`
- Create: `src/components/client-lane/portal/PortalApprovals.tsx`
- Create: `src/components/client-lane/portal/PortalApp.tsx`
- Test: `src/components/client-lane/portal/PortalApp.test.tsx`

**Interfaces:**
- Consumes:
  - Task 1: `PortalApprovalsView`, `mergeApprovalPages`, `summaryLine`, `isPortalEmpty`, `emptyStateText`, `viewOnlyNotice`, `waitingOnOthersLine`, `decidedTitle`, `decidedLine`, `subjectLine`, `requestedLine`, `decideByLine`, `progressLine`;
  - Task 2: `brandKey`, `portalErrorAction`;
  - Task 8: `usePortalApprovals`;
  - Task 9: `trackPortalViewed`, `trackPortalItemOpened`;
  - Task 10: `PortalFrame`, `PortalHeader`, `PortalNav`, `PortalViewOnlyNotice`, `RAIL_CARD`;
  - existing: `StatusPill`, `RequestProgressBar`, `publicApiError`.
- Produces:
  - `PortalApp({ me, current, onNavigate?, onSessionLost? })`, which Task 13 mounts;
  - `PortalApprovals` (presentational).

§9 mapping:

| Surface | Component |
|---|---|
| Page title + summary | v2 `PageHeading` |
| Section titles | v2 `SectionHeading` with `count` |
| Waiting-on-you card | `RAIL_CARD` surface, v2 `Button` "Review" (rendered as `<a href>`), `RequestProgressBar` (v1 `ProgressBar` wrapper) |
| Waiting-on-others / Decided rows | v2 `ItemRow`: `icon` = `ItemRow.Glyph` with the subject's Phosphor glyph, `title`, `badge` = `StatusPill`, `description` = the line |
| Show older | v2 `Button variant="text"` |
| Empty state | v1 `EmptyState` (wrapper) |
| View-only notice | `PortalViewOnlyNotice` |

- [ ] **Step 1: Write the failing test**

Create `src/components/client-lane/portal/PortalApp.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import posthog from "posthog-js";
import { useState, type ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  portalApprovals,
  portalBrand,
  portalItem,
  portalMe,
} from "@/lib/client-lane/portal/fixtures";
import {
  summaryLine,
  waitingOnOthersLine,
} from "@/lib/client-lane/portal/inbox";
import type { PortalApprovals } from "@/lib/client-lane/portal/types";
import { axiosPublic } from "@/services/axios";

import { PortalApp } from "./PortalApp";

const body = () => within(document.body);

function QueryWrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

const mine = portalItem();
const others = portalItem({
  request_id: "r2",
  url: "/s/tok2",
  subject: { type: "deck", title: "Campaign deck", thumbnail_url: null },
  my_decision: { outcome: "approved", at: "2026-10-05T09:00:00.000Z" },
  approvers: [
    { name: "Dina Pratiwi", decided: true, opened: true },
    { name: "Andi", decided: false, opened: false },
  ],
  decide_by: "2026-10-09",
  counts: { decided: 1, total: 2 },
});
const decided = portalItem({
  request_id: "r3",
  status: "approved",
  subject: { type: "campaign", title: "Q4 plan", thumbnail_url: null, version_label: "v2" },
  outcome_line: { outcome: "approved", by: "Dina Pratiwi", at: "2026-10-01T09:00:00.000Z", note_excerpt: null },
});
const older = portalItem({
  request_id: "r4",
  status: "changes_required",
  subject: { type: "deck", title: "Old deck", thumbnail_url: null, version_label: "v1" },
  outcome_line: { outcome: "changes_required", by: "Andi", at: "2026-09-01T09:00:00.000Z", note_excerpt: "Logo smaller" },
});

function stubApprovals(pages: Record<string, PortalApprovals>) {
  return vi.spyOn(axiosPublic, "get").mockImplementation((async (
    url: string,
    config?: { params?: { decided_cursor?: string } }
  ) => {
    if (url !== "fcn/frndglow/approvals") throw new Error(`unexpected GET ${url}`);
    const page = pages[config?.params?.decided_cursor ?? "first"];
    if (!page) throw new Error("no such page");
    return { data: { data: page } };
  }) as never);
}

function renderApp(props: Partial<Parameters<typeof PortalApp>[0]> = {}) {
  return render(
    <PortalApp me={portalMe()} current={portalBrand()} {...props} />,
    { wrapper: QueryWrapper }
  );
}

describe("PortalApp — the Approvals page (spec §6.3)", () => {
  beforeEach(() => vi.restoreAllMocks());

  it("groups the inbox, pages older decisions, and counts the view once", async () => {
    const user = userEvent.setup();
    const capture = vi
      .spyOn(posthog, "capture")
      .mockImplementation(() => undefined as never);
    const get = stubApprovals({
      first: portalApprovals({
        waiting_on_you: [mine],
        waiting_on_others: [others],
        decided: [decided],
        decided_next_cursor: "c1",
      }),
      c1: portalApprovals({ decided: [older], decided_next_cursor: null }),
    });
    renderApp();

    expect(await body().findByText(summaryLine([mine]))).toBeInTheDocument();
    expect(body().getByRole("link", { name: "Review" })).toHaveAttribute("href", "/s/tok1");
    expect(body().getByText(waitingOnOthersLine(others))).toBeInTheDocument();
    expect(body().getByText("Q4 plan · v2")).toBeInTheDocument();

    await user.click(body().getByRole("button", { name: "Show older" }));
    expect(await body().findByText("Old deck · v1")).toBeInTheDocument();
    expect(get).toHaveBeenCalledWith("fcn/frndglow/approvals", {
      baseURL: "/s/api/portal/",
      params: { decided_cursor: "c1" },
    });
    await waitFor(() =>
      expect(body().queryByRole("button", { name: "Show older" })).toBeNull()
    );

    const views = capture.mock.calls.filter(([name]) => name === "client_lane.portal_viewed");
    expect(views).toHaveLength(1);
    expect(views[0][1]).toMatchObject({ access_level: "all_approve", waiting_on_you: 1 });
  });

  it("opens a row and says which group it came from", async () => {
    const user = userEvent.setup();
    const capture = vi
      .spyOn(posthog, "capture")
      .mockImplementation(() => undefined as never);
    stubApprovals({ first: portalApprovals({ waiting_on_others: [others] }) });
    const onNavigate = vi.fn();
    renderApp({ onNavigate });
    await user.click(
      await body().findByRole("button", { name: "Open Campaign deck" })
    );
    expect(onNavigate).toHaveBeenCalledWith("/s/tok2");
    expect(capture).toHaveBeenCalledWith(
      "client_lane.portal_item_opened",
      expect.objectContaining({ group: "waiting_on_others", subject_type: "deck" })
    );
  });

  it("hands back to sign-in when the brand is gone", async () => {
    vi.spyOn(axiosPublic, "get").mockRejectedValue({
      response: { status: 404, data: { message: "Not found." } },
    });
    const onSessionLost = vi.fn();
    renderApp({ onSessionLost });
    await waitFor(() => expect(onSessionLost).toHaveBeenCalledTimes(1));
  });

  it("tells a view-only client so, above everything", async () => {
    stubApprovals({ first: portalApprovals({ access_level: "all_view" }) });
    renderApp({ current: portalBrand({ access_level: "all_view" }) });
    expect(
      await body().findByText(
        "You can view everything FCN sends for frndGlow. Ask FCN if you need to approve."
      )
    ).toBeInTheDocument();
  });

  it("says nothing has come from the agency yet", async () => {
    stubApprovals({ first: portalApprovals() });
    renderApp();
    expect(
      await body().findByText("Nothing from FCN for frndGlow yet.")
    ).toBeInTheDocument();
  });
});
```

Mutations:
- Remove the `viewed.current === key` guard, and "counts the view once" fails (2 captures after Show older).
- Map 404 to "retry" in `portalErrorAction`, or skip the `onSessionLost` effect, and "hands back to sign-in" fails.
- Concatenate pages without `mergeApprovalPages`, so "Q4 plan" disappears on the second render, and the first test fails. Verify this one concretely: the mutation is "use `query.data.pages.at(-1)` instead of merging".
- Track `group: "decided"` for every row, and "opens a row and says which group" fails.

- [ ] **Step 2: Run it to verify it fails**

Run: `cd WT && bun test src/components/client-lane/portal/PortalApp.test.tsx`
Expected: FAIL. `./PortalApp` is not found.

- [ ] **Step 3: Write the components**

Create `src/components/client-lane/portal/PortalEmptyState.tsx`:

```tsx
"use client";

import { Tray } from "@phosphor-icons/react";

import { EmptyState } from "@/components/frndos/EmptyState";

/** The portal's empty state — frndOS v1 `EmptyState`, alone in its file so
 *  the v2 page never imports v1 (spec §9). */
export function PortalEmptyState({ title }: { title: string }) {
  return <EmptyState icon={<Tray size={24} aria-hidden />} title={title} noBackground />;
}
```

Create `src/components/client-lane/portal/WaitingCard.tsx`:

```tsx
"use client";

import clsx from "clsx";

import { Button } from "@/components/frndos/v2";
import {
  decideByLine,
  progressLine,
  requestedLine,
  subjectLine,
} from "@/lib/client-lane/portal/inbox";
import type { PortalItem } from "@/lib/client-lane/portal/types";

import { RequestProgressBar } from "../RequestProgressBar";
import { RAIL_CARD } from "../RequestRail";

/**
 * One request waiting on this person (spec §6.3): thumbnail, title · type,
 * the agency's first line, who asked and when, Decide by, the progress bar,
 * and Review — a real link, so it opens in a new tab like any link.
 */
export function WaitingCard({
  item,
  onReview,
}: {
  item: PortalItem;
  onReview: () => void;
}) {
  const thumb =
    item.subject.thumbnail_url && /^https?:\/\//.test(item.subject.thumbnail_url)
      ? item.subject.thumbnail_url
      : null;
  const decideBy = decideByLine(item);
  return (
    <article
      aria-label={item.subject.title}
      className={clsx(RAIL_CARD, "flex flex-col gap-3 sm:flex-row sm:items-start")}
    >
      {thumb ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img
          src={thumb}
          alt=""
          className="aspect-video w-full shrink-0 rounded-xl bg-white/5 object-cover sm:w-40"
        />
      ) : null}
      <div className="flex min-w-0 flex-1 flex-col gap-2">
        <div className="flex flex-col gap-0.5">
          <p className="truncate text-textSmMedium text-text-inverse">
            {subjectLine(item)}
          </p>
          {item.message_line ? (
            <p className="text-textSm text-text-inverse-subtle">{item.message_line}</p>
          ) : null}
          <p className="text-textXs text-text-inverse-subtlest">{requestedLine(item)}</p>
        </div>
        {decideBy ? (
          <p className="text-textXsMedium text-text-inverse-subtle">{decideBy}</p>
        ) : null}
        <div className="flex flex-col gap-1.5">
          <RequestProgressBar decided={item.counts.decided} total={item.counts.total} />
          <p className="text-textXs text-text-inverse-subtlest">{progressLine(item)}</p>
        </div>
        <Button
          size="medium"
          className="self-start"
          nativeButton={false}
          render={<a href={item.url} />}
          onClick={onReview}
        >
          Review
        </Button>
      </div>
    </article>
  );
}
```

Create `src/components/client-lane/portal/PortalApprovals.tsx`:

```tsx
"use client";

import { CalendarBlank, ImageSquare, Presentation } from "@phosphor-icons/react";
import type { ReactNode } from "react";

import {
  Button,
  ItemRow,
  PageHeading,
  SectionHeading,
} from "@/components/frndos/v2";
import {
  decidedLine,
  decidedTitle,
  emptyStateText,
  isPortalEmpty,
  summaryLine,
  viewOnlyNotice,
  waitingOnOthersLine,
  type PortalApprovalsView,
} from "@/lib/client-lane/portal/inbox";
import type {
  PortalBrand,
  PortalGroup,
  PortalItem,
} from "@/lib/client-lane/portal/types";
import type { ShareSubjectType } from "@/lib/client-lane/types";

import { StatusPill } from "../StatusPill";

import { PortalEmptyState } from "./PortalEmptyState";
import { PortalViewOnlyNotice } from "./PortalViewOnlyNotice";
import { WaitingCard } from "./WaitingCard";

const SUBJECT_GLYPH: Record<ShareSubjectType, ReactNode> = {
  kv_file: <ImageSquare size={18} aria-hidden />,
  deck: <Presentation size={18} aria-hidden />,
  campaign: <CalendarBlank size={18} aria-hidden />,
};

export interface PortalApprovalsProps {
  current: PortalBrand;
  view: PortalApprovalsView | null;
  loading: boolean;
  failed: boolean;
  loadingOlder: boolean;
  onOlder: () => void;
  onRetry: () => void;
  /** `navigate` = false for the card's Review link (the link navigates itself). */
  onOpen: (item: PortalItem, group: PortalGroup, navigate: boolean) => void;
}

/** The Approvals page body (spec §6.3, §9). Presentational — `PortalApp` wires it. */
export function PortalApprovals({
  current,
  view,
  loading,
  failed,
  loadingOlder,
  onOlder,
  onRetry,
  onOpen,
}: PortalApprovalsProps) {
  const workspace = current.workspace.name;
  const brand = current.brand.name;

  if (loading) {
    return (
      <p role="status" className="text-textSm text-text-inverse-subtle">
        Loading approvals…
      </p>
    );
  }
  if (failed || !view) {
    return (
      <div className="flex flex-col items-start gap-2">
        <p role="alert" className="text-textSm text-text-inverse-subtle">
          Couldn&apos;t load your approvals.
        </p>
        <Button variant="secondary" size="small" onClick={onRetry}>
          Try again
        </Button>
      </div>
    );
  }

  const row = (item: PortalItem, group: PortalGroup) => (
    <ItemRow
      key={item.request_id}
      icon={<ItemRow.Glyph>{SUBJECT_GLYPH[item.subject.type]}</ItemRow.Glyph>}
      title={group === "decided" ? decidedTitle(item) : item.subject.title}
      badge={group === "decided" ? <StatusPill status={item.status} /> : undefined}
      description={group === "decided" ? decidedLine(item) : waitingOnOthersLine(item)}
      openLabel={`Open ${item.subject.title}`}
      onOpen={() => onOpen(item, group, true)}
    />
  );

  return (
    <div className="flex flex-col gap-8">
      <PageHeading title="Approvals" description={summaryLine(view.waiting_on_you)} />
      {view.access_level === "all_view" ? (
        <PortalViewOnlyNotice text={viewOnlyNotice(workspace, brand)} />
      ) : null}
      {isPortalEmpty(view) ? (
        <PortalEmptyState title={emptyStateText(workspace, brand)} />
      ) : null}
      {view.waiting_on_you.length > 0 ? (
        <section className="flex flex-col gap-3">
          <SectionHeading title="Waiting on you" count={view.waiting_on_you.length} />
          <div className="flex flex-col gap-3">
            {view.waiting_on_you.map((item) => (
              <WaitingCard
                key={item.request_id}
                item={item}
                onReview={() => onOpen(item, "waiting_on_you", false)}
              />
            ))}
          </div>
        </section>
      ) : null}
      {view.waiting_on_others.length > 0 ? (
        <section className="flex flex-col gap-2">
          <SectionHeading title="Waiting on others" count={view.waiting_on_others.length} />
          <div className="flex flex-col gap-1">
            {view.waiting_on_others.map((item) => row(item, "waiting_on_others"))}
          </div>
        </section>
      ) : null}
      {view.decided.length > 0 || view.hasOlder ? (
        <section className="flex flex-col gap-2">
          <SectionHeading title="Decided" count={view.decided.length} />
          <div className="flex flex-col gap-1">
            {view.decided.map((item) => row(item, "decided"))}
          </div>
          {view.hasOlder ? (
            <Button
              variant="text"
              size="small"
              className="self-start"
              loading={loadingOlder}
              disabled={loadingOlder}
              onClick={onOlder}
            >
              Show older
            </Button>
          ) : null}
        </section>
      ) : null}
    </div>
  );
}
```

Create `src/components/client-lane/portal/PortalApp.tsx`:

```tsx
"use client";

import { useEffect, useMemo, useRef } from "react";

import {
  trackPortalItemOpened,
  trackPortalViewed,
} from "@/lib/analytics/client-lane-events";
import { mergeApprovalPages } from "@/lib/client-lane/portal/inbox";
import { brandKey, portalErrorAction } from "@/lib/client-lane/portal/shell";
import type {
  PortalBrand,
  PortalGroup,
  PortalItem,
  PortalMe,
} from "@/lib/client-lane/portal/types";
import { publicApiError } from "@/lib/client-lane/publicApi";
import { usePortalApprovals } from "@/services/client-portal";

import { PortalApprovals } from "./PortalApprovals";
import { PortalFrame } from "./PortalFrame";
import { PortalHeader } from "./PortalHeader";
import { PortalNav } from "./PortalNav";

/**
 * A signed-in client's portal for one brand (spec §6.2–§6.3). Owns the
 * query, the once-per-brand view event, opening an item, and the way back
 * to sign-in when the session or the brand is gone (401 / 404 — no hint).
 */
export function PortalApp({
  me,
  current,
  onNavigate = (href) => window.location.assign(href),
  onSessionLost = () => window.location.reload(),
}: {
  me: PortalMe;
  current: PortalBrand;
  onNavigate?: (href: string) => void;
  onSessionLost?: () => void;
}) {
  const query = usePortalApprovals(current.workspace.slug, current.brand.slug);
  const view = useMemo(
    () => mergeApprovalPages(query.data?.pages ?? []),
    [query.data]
  );

  const viewed = useRef<string | null>(null);
  useEffect(() => {
    if (!view) return;
    const key = brandKey(current);
    if (viewed.current === key) return;
    viewed.current = key;
    trackPortalViewed({
      access_level: view.access_level,
      waiting_on_you: view.waiting_on_you.length,
    });
  }, [view, current]);

  const errorStatus = query.error ? publicApiError(query.error).status : null;
  const lost = query.error !== null && portalErrorAction(errorStatus) === "sign_in";
  const handedBack = useRef(false);
  useEffect(() => {
    if (!lost || handedBack.current) return;
    handedBack.current = true;
    onSessionLost();
  }, [lost, onSessionLost]);

  const open = (item: PortalItem, group: PortalGroup, navigate: boolean) => {
    trackPortalItemOpened({ group, subject_type: item.subject.type });
    if (navigate) onNavigate(item.url);
  };

  return (
    <PortalFrame>
      <PortalHeader me={me} current={current} surface="portal" />
      <PortalNav waiting={view?.waiting_on_you.length ?? current.waiting_on_you} />
      <PortalApprovals
        current={current}
        view={view}
        loading={query.isPending || lost}
        failed={query.isError && !lost}
        loadingOlder={query.isFetchingNextPage}
        onOlder={() => void query.fetchNextPage()}
        onRetry={() => void query.refetch()}
        onOpen={open}
      />
    </PortalFrame>
  );
}
```

- [ ] **Step 4: Run the test to verify it passes, then prove each named mutation**

Run: `cd WT && bun test src/components/client-lane/portal/PortalApp.test.tsx`
Expected: PASS, with no `error` line.
- If `summaryLine([mine])` is not found because `PageHeading` splits text, query with `findByText((_, el) => el?.textContent === …)`.
- If `getByRole("link", { name: "Review" })` finds none, check that Base UI renders `<a>` with `nativeButton={false}`. That is the house pattern (`StudioAccessDenied.tsx`).

Apply each mutation, watch its test fail, and restore.

- [ ] **Step 5: Lint, format, commit**

```bash
cd WT && F=(src/components/client-lane/portal/PortalEmptyState.tsx src/components/client-lane/portal/WaitingCard.tsx src/components/client-lane/portal/PortalApprovals.tsx src/components/client-lane/portal/PortalApp.tsx src/components/client-lane/portal/PortalApp.test.tsx) && ./node_modules/.bin/prettier --write "${F[@]}" && ./node_modules/.bin/eslint "${F[@]}" && /usr/bin/git add "${F[@]}" && /usr/bin/git commit -F - <<'EOF'
feat(web): portal Approvals page — waiting cards, rows, older decisions

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---
### Task 12: The sign-in screen

**Files:**
- Create: `src/components/client-lane/portal/PortalEmailField.tsx`
- Create: `src/components/client-lane/portal/PortalSignIn.tsx`
- Test: `src/components/client-lane/portal/PortalSignIn.test.tsx`

**Interfaces:**
- Consumes:
  - Task 3: `signInReducer`, `initialSignIn`, `isEmail`, `signInErrorText`, `canResend`, `resendLabel`, `PORTAL_CODE_LENGTH`;
  - Task 8: `requestPortalCode`, `verifyPortalCode`;
  - Task 9: `trackPortalSigninCodeRequested`, `trackPortalSigninVerified`, `trackPortalSigninFailed`;
  - existing: `failureReason`, `publicApiError`, `PortalFrame`, v2 `CodeInput` and `Button`, v1 `Input` (wrapper), `useToastStore`.
- Produces: `PortalSignIn({ workspaceSlug, brandSlug, onSignedIn? })`, which Task 13 mounts.

§9 mapping:
- the email field is v1 `Input` (no native `<input>`), through `PortalEmailField`;
- the code is v2 `CodeInput`;
- submit is v2 `Button`;
- the "Code sent" notice is a v1 `Toast` via `useToastStore`.

Errors are inline `role="alert"`, because `Toast` renders nothing below `md`. Reported as a spec/code mismatch.

The header shows only what the URL carries (`{brand slug} · via {workspace slug}`). That way the screen is identical whether or not the brand or the client exists (spec §6.4, §8.1).

- [ ] **Step 1: Write the failing test**

Create `src/components/client-lane/portal/PortalSignIn.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { render, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import posthog from "posthog-js";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { axiosPublic } from "@/services/axios";

import { PortalSignIn } from "./PortalSignIn";

const body = () => within(document.body);

async function typeCode(user: ReturnType<typeof userEvent.setup>, digits: string) {
  const first = body().getByRole("textbox", { name: "Verification code" });
  await user.click(first);
  // Base UI OTPField fills box by box from the keyboard; if a jsdom run does
  // not advance focus, use `await user.paste(digits)` instead (OTPField
  // spreads a paste over every box) and note it in the track.
  await user.keyboard(digits);
}

describe("PortalSignIn (spec §5.3, §6.4)", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    vi.spyOn(posthog, "capture").mockImplementation(() => undefined as never);
  });

  it("sends a code and shows the boxes for any address — nothing says whether it exists", async () => {
    const user = userEvent.setup();
    const post = vi
      .spyOn(axiosPublic, "post")
      .mockResolvedValue({ status: 202, data: {} } as never);
    render(<PortalSignIn workspaceSlug="fcn" brandSlug="frndglow" onSignedIn={vi.fn()} />);
    expect(body().getByText("frndglow")).toBeInTheDocument();
    await user.type(body().getByPlaceholderText("you@brand.com"), "dina@brand.co");
    await user.click(body().getByRole("button", { name: "Send code" }));
    expect(
      await body().findByText("We sent a 6-digit code to dina@brand.co.")
    ).toBeInTheDocument();
    expect(post).toHaveBeenCalledWith(
      "fcn/frndglow/code",
      { email: "dina@brand.co" },
      { baseURL: "/s/api/portal/" }
    );
  });

  it("refuses a malformed address without calling the api", async () => {
    const user = userEvent.setup();
    const post = vi.spyOn(axiosPublic, "post");
    render(<PortalSignIn workspaceSlug="fcn" brandSlug="frndglow" onSignedIn={vi.fn()} />);
    await user.type(body().getByPlaceholderText("you@brand.com"), "dina");
    await user.click(body().getByRole("button", { name: "Send code" }));
    expect(body().getByRole("alert")).toHaveTextContent("Enter a valid email address.");
    expect(post).not.toHaveBeenCalled();
  });

  it("signs in on a valid code and hands over", async () => {
    const user = userEvent.setup();
    vi.spyOn(axiosPublic, "post").mockImplementation((async (url: string) => {
      if (url === "fcn/frndglow/code") return { status: 202, data: {} };
      if (url === "fcn/frndglow/code/verify") {
        return { data: { data: { signed_in: true, expires_at: null } } };
      }
      throw new Error(`unexpected POST ${url}`);
    }) as never);
    const onSignedIn = vi.fn();
    render(<PortalSignIn workspaceSlug="fcn" brandSlug="frndglow" onSignedIn={onSignedIn} />);
    await user.type(body().getByPlaceholderText("you@brand.com"), "dina@brand.co");
    await user.click(body().getByRole("button", { name: "Send code" }));
    await body().findByText("We sent a 6-digit code to dina@brand.co.");
    await typeCode(user, "123456");
    await waitFor(() => expect(onSignedIn).toHaveBeenCalledTimes(1));
  });

  it("says how many tries are left", async () => {
    const user = userEvent.setup();
    vi.spyOn(axiosPublic, "post").mockImplementation((async (url: string) => {
      if (url === "fcn/frndglow/code") return { status: 202, data: {} };
      throw { response: { status: 422, data: { code: "invalid_code", attempts_left: 2 } } };
    }) as never);
    const onSignedIn = vi.fn();
    render(<PortalSignIn workspaceSlug="fcn" brandSlug="frndglow" onSignedIn={onSignedIn} />);
    await user.type(body().getByPlaceholderText("you@brand.com"), "dina@brand.co");
    await user.click(body().getByRole("button", { name: "Send code" }));
    await body().findByText("We sent a 6-digit code to dina@brand.co.");
    await typeCode(user, "000000");
    expect(await body().findByRole("alert")).toHaveTextContent(
      "That code didn't match — 2 tries left."
    );
    expect(onSignedIn).not.toHaveBeenCalled();
  });
});
```

Mutations:
- Drop the `if (!isEmail(email)) return;` short-circuit in `send`, and "refuses a malformed address" fails because post is called.
- Dispatch `sent` before awaiting `requestPortalCode`, and the screen advances even when the send fails. No committed test pins this one. Check it once locally with a rejecting post, and note the result in the track.
- Drop `onSignedIn()`, and "signs in on a valid code" fails.
- Pass `attemptsLeft: null`, and "says how many tries are left" fails.

- [ ] **Step 2: Run it to verify it fails**

Run: `cd WT && bun test src/components/client-lane/portal/PortalSignIn.test.tsx`
Expected: FAIL. `./PortalSignIn` is not found.

- [ ] **Step 3: Write the components**

Create `src/components/client-lane/portal/PortalEmailField.tsx`:

```tsx
"use client";

import Input from "@/components/frndos/Input";

/** The sign-in email field — frndOS v1 `Input`, alone in its file so the v2
 *  screen never imports v1 (spec §9: no native `<input>`). */
export function PortalEmailField({
  value,
  onChange,
  invalid,
  disabled,
  describedBy,
}: {
  value: string;
  onChange: (next: string) => void;
  invalid: boolean;
  disabled: boolean;
  describedBy?: string;
}) {
  return (
    <Input
      label="Email"
      type="email"
      inputMode="email"
      autoComplete="email"
      maxLength={254}
      autoFocus
      value={value}
      onChange={(e) => onChange(e.target.value)}
      placeholder="you@brand.com"
      error={invalid}
      disabled={disabled}
      aria-invalid={invalid || undefined}
      aria-describedby={describedBy}
    />
  );
}
```

Create `src/components/client-lane/portal/PortalSignIn.tsx`:

```tsx
"use client";

import { useEffect, useReducer, useState } from "react";

import { Button, CodeInput } from "@/components/frndos/v2";
import {
  failureReason,
  trackPortalSigninCodeRequested,
  trackPortalSigninFailed,
  trackPortalSigninVerified,
} from "@/lib/analytics/client-lane-events";
import {
  PORTAL_CODE_LENGTH,
  canResend,
  initialSignIn,
  isEmail,
  resendLabel,
  signInErrorText,
  signInReducer,
} from "@/lib/client-lane/portal/signIn";
import { publicApiError } from "@/lib/client-lane/publicApi";
import { requestPortalCode, verifyPortalCode } from "@/services/client-portal";
import { useToastStore } from "@/store/useToast";

import { PortalEmailField } from "./PortalEmailField";
import { PortalFrame } from "./PortalFrame";

const ERROR_ID = "portal-signin-error";

/**
 * Sign-in by 6-digit code (spec §5.3, §6.4). Identical for any brand and any
 * address: the header shows only the URL's slugs, and the api's constant
 * 202 is the one way to the code step. On success the BFF has set the
 * HttpOnly cookie; `onSignedIn` (default: reload) lets the server render the
 * inbox.
 */
export function PortalSignIn({
  workspaceSlug,
  brandSlug,
  onSignedIn = () => window.location.reload(),
}: {
  workspaceSlug: string;
  brandSlug: string;
  onSignedIn?: () => void;
}) {
  const [state, dispatch] = useReducer(signInReducer, initialSignIn);
  const [draft, setDraft] = useState("");
  const [code, setCode] = useState("");
  const [now, setNow] = useState(() => Date.now());
  const showToast = useToastStore((s) => s.showToast);

  useEffect(() => {
    if (state.resendAt <= now) return;
    const id = window.setTimeout(() => setNow(Date.now()), 1000);
    return () => window.clearTimeout(id);
  }, [state.resendAt, now]);

  const send = async (email: string, resend: boolean) => {
    if (state.sending) return;
    dispatch({ type: "send", email });
    if (!isEmail(email)) return;
    try {
      await requestPortalCode(workspaceSlug, brandSlug, email.trim());
      const at = Date.now();
      setNow(at);
      setCode("");
      dispatch({ type: "sent", at });
      trackPortalSigninCodeRequested({ resend });
      showToast("Code sent", `Check ${email.trim()} for a 6-digit code.`, "success");
    } catch (e) {
      const err = publicApiError(e);
      const throttled = err.status === 429;
      trackPortalSigninFailed({
        stage: "request",
        reason: throttled ? "throttled" : failureReason(err),
        http_status: err.status,
      });
      dispatch({ type: "send_failed", reason: throttled ? "throttled" : "failed" });
    }
  };

  const verify = async (value: string) => {
    if (state.verifying || value.length !== PORTAL_CODE_LENGTH) return;
    dispatch({ type: "verify" });
    try {
      await verifyPortalCode(workspaceSlug, brandSlug, state.email, value);
      dispatch({ type: "verified" });
      trackPortalSigninVerified();
      onSignedIn();
    } catch (e) {
      const err = publicApiError(e);
      const reason =
        err.code === "invalid_code" || err.code === "code_expired"
          ? err.code
          : err.status === 429
            ? "throttled"
            : "failed";
      trackPortalSigninFailed({
        stage: "verify",
        reason: reason === "failed" ? failureReason(err) : reason,
        http_status: err.status,
      });
      setCode("");
      dispatch({ type: "verify_failed", reason, attemptsLeft: err.attemptsLeft });
    }
  };

  const error = signInErrorText(state);
  const errorLine = error ? (
    <p id={ERROR_ID} role="alert" className="text-textXs text-negative-400">
      {error}
    </p>
  ) : null;

  return (
    <PortalFrame>
      <header className="pt-2">
        <p className="truncate text-textSm text-text-inverse-subtle">
          <span className="text-textSmMedium text-text-inverse">{brandSlug}</span>
          {` · via ${workspaceSlug}`}
        </p>
      </header>
      <section className="mx-auto flex w-full max-w-sm flex-col gap-4 pt-8">
        <div className="flex flex-col gap-1">
          <h1 className="text-displayXsMedium text-text-inverse">
            Sign in to your approvals
          </h1>
          <p className="text-textSm text-text-inverse-subtle">
            {state.step === "email"
              ? "We'll email you a 6-digit code."
              : `We sent a 6-digit code to ${state.email}.`}
          </p>
        </div>
        {state.step === "email" ? (
          <form
            // Our own check and copy (`isEmail`, inline alert) — not the
            // browser's bubble, which differs per browser and hides on phones.
            noValidate
            className="flex flex-col gap-3"
            onSubmit={(e) => {
              e.preventDefault();
              void send(draft, false);
            }}
          >
            <PortalEmailField
              value={draft}
              onChange={setDraft}
              invalid={state.error === "invalid_email"}
              disabled={state.sending}
              describedBy={error ? ERROR_ID : undefined}
            />
            {errorLine}
            <Button type="submit" size="large" loading={state.sending} disabled={state.sending}>
              Send code
            </Button>
          </form>
        ) : (
          <form
            className="flex flex-col gap-3"
            onSubmit={(e) => {
              e.preventDefault();
              void verify(code);
            }}
          >
            <CodeInput
              label="Verification code"
              value={code}
              onChange={setCode}
              onComplete={(full) => void verify(full)}
              invalid={state.error === "invalid_code"}
              disabled={state.verifying || state.error === "code_expired"}
              autoFocus
              describedBy={error ? ERROR_ID : undefined}
            />
            {errorLine}
            <Button
              type="submit"
              size="large"
              loading={state.verifying}
              disabled={
                state.verifying ||
                state.error === "code_expired" ||
                code.length !== PORTAL_CODE_LENGTH
              }
            >
              Sign in
            </Button>
            <div className="flex items-center justify-between gap-3">
              <Button
                type="button"
                variant="text"
                size="tiny"
                disabled={state.verifying}
                onClick={() => dispatch({ type: "change_email" })}
              >
                Use another email
              </Button>
              <Button
                type="button"
                variant="text"
                size="tiny"
                disabled={!canResend(state, now)}
                onClick={() => void send(state.email, true)}
              >
                {resendLabel(state, now)}
              </Button>
            </div>
          </form>
        )}
      </section>
    </PortalFrame>
  );
}
```

`"Use another email"` keeps `draft` (still the typed address), so the field comes back prefilled.

- [ ] **Step 4: Run the test to verify it passes, then prove each named mutation**

Run: `cd WT && bun test src/components/client-lane/portal/PortalSignIn.test.tsx`
Expected: PASS, with no `error` line. If `getByRole("textbox", { name: "Verification code" })` matches nothing, read `CodeInput`: OTPField names its first box from the sr-only `<label>`. Query `getAllByRole("textbox")[0]` instead and note it. Apply each mutation, watch its test fail, and restore.

- [ ] **Step 5: Lint, format, commit**

```bash
cd WT && F=(src/components/client-lane/portal/PortalEmailField.tsx src/components/client-lane/portal/PortalSignIn.tsx src/components/client-lane/portal/PortalSignIn.test.tsx) && ./node_modules/.bin/prettier --write "${F[@]}" && ./node_modules/.bin/eslint "${F[@]}" && /usr/bin/git add "${F[@]}" && /usr/bin/git commit -F - <<'EOF'
feat(web): portal sign-in by 6-digit code

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 13: The portal route and the lane-exchange gate

**Files:**
- Create: `src/components/client-lane/portal/LaneExchange.tsx`
- Test: `src/components/client-lane/portal/LaneExchange.test.tsx`
- Create: `src/app/s/[token]/[brand]/page.tsx`

**Interfaces:**
- Consumes:
  - Task 4: `CLIENT_SESSION_COOKIE`, `LANE_COOKIE`, `LANE_FRESH_COOKIE`, `isClientSessionToken`, `shouldExchangeLane`;
  - Task 8: `resolvePortalMeServer`;
  - Task 2: `findPortalBrand`;
  - Tasks 11 and 12: `PortalApp`, `PortalSignIn`; Task 10: `PortalFrame`.
- Produces:
  - `LaneExchange({ onDone })`, where `onDone` receives `"signed_in" | "not_signed_in" | "network"`;
  - `PortalExchangeGate({ workspaceSlug, brandSlug })`;
  - `ReviewLaneExchange({ reload })`, which Task 14 mounts;
  - the `/s/{workspace}/{brand}` route.

Routing:
- Next forbids two dynamic names at one level, so the workspace slug reuses `[token]`.
- Static `/s/session/*`, `/s/verify/*` and `/s/api/*` win over it, and so does `/s/{token}/opengraph-image`.
- `[token]/loading.tsx` (the dark spinner) also covers this segment.

What the page renders:
1. A fresh `?k=` capture (marker + lane) renders `PortalExchangeGate`. It POSTs `/s/session/exchange`, and then reloads on any answer, because the marker is now gone. On a network failure it shows sign-in instead of looping. This runs even when a session exists, because the link's person wins (Review Focus 3).
2. Otherwise, a session whose `me` lists this brand renders `PortalApp`.
3. Otherwise, it renders `PortalSignIn`. This covers no session, a dead session, and a session without a lane here. The screen is identical in every case (spec §6.4).

- [ ] **Step 1: Write the failing test**

Create `src/components/client-lane/portal/LaneExchange.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { render, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { LaneExchange } from "./LaneExchange";

describe("LaneExchange (spec §4.3 path 1)", () => {
  beforeEach(() => vi.restoreAllMocks());

  it("posts once, even across re-renders, and reports a session", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ signed_in: true }), { status: 200 })
    );
    const onDone = vi.fn();
    const { rerender } = render(<LaneExchange onDone={onDone} />);
    rerender(<LaneExchange onDone={onDone} />);
    await waitFor(() => expect(onDone).toHaveBeenCalledWith("signed_in"));
    expect(fetchSpy).toHaveBeenCalledTimes(1);
    expect(fetchSpy).toHaveBeenCalledWith("/s/session/exchange", {
      method: "POST",
      cache: "no-store",
    });
  });

  it("reports a network failure apart from a refusal", async () => {
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new TypeError("offline"));
    const onDone = vi.fn();
    render(<LaneExchange onDone={onDone} />);
    await waitFor(() => expect(onDone).toHaveBeenCalledWith("network"));
  });
});
```

Mutations:
- Remove the `started` ref guard. Under a changed `onDone` identity the effect re-runs and posts twice, and the first test fails. To make it bite, rerender with `onDone={vi.fn()}` locally once.
- Map a rejection to `"not_signed_in"`, and the second test fails.

- [ ] **Step 2: Run it to verify it fails**

Run: `cd WT && bun test src/components/client-lane/portal/LaneExchange.test.tsx`
Expected: FAIL. `./LaneExchange` is not found.

- [ ] **Step 3: Write `LaneExchange.tsx`**

```tsx
"use client";

import { useCallback, useEffect, useRef, useState } from "react";

import { PortalFrame } from "./PortalFrame";
import { PortalSignIn } from "./PortalSignIn";

export type LaneExchangeOutcome = "signed_in" | "not_signed_in" | "network";

/**
 * Trades a freshly captured personal lane for a client session (spec
 * 2026-10-06 portal §4.3): one same-origin POST, from page JS — never a GET
 * a mail scanner could trigger. The route clears the fresh marker on every
 * answer, so a reload after it never loops.
 */
export function LaneExchange({
  onDone,
}: {
  onDone: (outcome: LaneExchangeOutcome) => void;
}) {
  const started = useRef(false);
  useEffect(() => {
    if (started.current) return;
    started.current = true;
    void (async () => {
      try {
        const res = await fetch("/s/session/exchange", {
          method: "POST",
          cache: "no-store",
        });
        const body = (await res.json().catch(() => null)) as {
          signed_in?: boolean;
        } | null;
        onDone(body?.signed_in ? "signed_in" : "not_signed_in");
      } catch {
        onDone("network");
      }
    })();
  }, [onDone]);
  return null;
}

/** The portal page right after a `?k=` capture: exchange, then let the server render. */
export function PortalExchangeGate({
  workspaceSlug,
  brandSlug,
}: {
  workspaceSlug: string;
  brandSlug: string;
}) {
  const [failed, setFailed] = useState(false);
  const onDone = useCallback((outcome: LaneExchangeOutcome) => {
    if (outcome === "network") setFailed(true);
    else window.location.reload();
  }, []);
  if (failed) {
    return <PortalSignIn workspaceSlug={workspaceSlug} brandSlug={brandSlug} />;
  }
  return (
    <PortalFrame>
      <LaneExchange onDone={onDone} />
      <p role="status" className="pt-16 text-center text-textSm text-text-inverse-subtle">
        Opening your approvals…
      </p>
    </PortalFrame>
  );
}

/**
 * The review page after a `?k=` capture. A first visit keeps working on the
 * lane (no reload — the session applies from the next load); a device that
 * already had a session reloads so the link's person replaces the old one.
 */
export function ReviewLaneExchange({ reload }: { reload: boolean }) {
  const onDone = useCallback(
    (outcome: LaneExchangeOutcome) => {
      if (outcome === "signed_in" && reload) window.location.reload();
    },
    [reload]
  );
  return <LaneExchange onDone={onDone} />;
}
```

- [ ] **Step 4: Write the route**

Create `src/app/s/[token]/[brand]/page.tsx`:

```tsx
import type { Metadata } from "next";
import { cookies } from "next/headers";

import { PortalApp } from "@/components/client-lane/portal/PortalApp";
import { PortalExchangeGate } from "@/components/client-lane/portal/LaneExchange";
import { PortalSignIn } from "@/components/client-lane/portal/PortalSignIn";
import {
  CLIENT_SESSION_COOKIE,
  LANE_COOKIE,
  LANE_FRESH_COOKIE,
  isClientSessionToken,
  shouldExchangeLane,
} from "@/lib/client-lane/cookie";
import { resolvePortalMeServer } from "@/lib/client-lane/portal/server";
import { findPortalBrand } from "@/lib/client-lane/portal/shell";

/**
 * The client portal — `/s/{workspace slug}/{brand slug}` (spec 2026-10-06
 * portal §6). The workspace slug rides the `[token]` segment: Next allows
 * one dynamic name per level, and `/s/{token}` already owns it. Static
 * `/s/session`, `/s/verify`, `/s/api` and `/s/{token}/opengraph-image` win.
 *
 * The session cookie is read here only to forward to the api; nothing below
 * receives it. `force-dynamic`: a revoked lane must never render from cache.
 */
export const dynamic = "force-dynamic";

// Generic on purpose: the title never confirms that a brand exists.
export const metadata: Metadata = {
  title: "Approvals — frndOS",
  robots: { index: false, follow: false },
};

type Params = Promise<{ token: string; brand: string }>;

export default async function ClientPortalPage({ params }: { params: Params }) {
  const { token: workspaceSlug, brand: brandSlug } = await params;
  const jar = await cookies();

  if (
    shouldExchangeLane({
      lane: jar.get(LANE_COOKIE)?.value,
      fresh: jar.get(LANE_FRESH_COOKIE)?.value,
    })
  ) {
    return <PortalExchangeGate workspaceSlug={workspaceSlug} brandSlug={brandSlug} />;
  }

  const session = jar.get(CLIENT_SESSION_COOKIE)?.value;
  if (isClientSessionToken(session)) {
    const me = await resolvePortalMeServer(session);
    const current = me ? findPortalBrand(me, workspaceSlug, brandSlug) : null;
    if (me && current) return <PortalApp me={me} current={current} />;
  }

  return <PortalSignIn workspaceSlug={workspaceSlug} brandSlug={brandSlug} />;
}
```

The `[token]/opengraph-image.tsx` file convention may be inherited by this nested segment. Its resolver answers `null` for a workspace slug, so the OG route serves the generic text card, which carries no brand. That is acceptable: nothing leaks and nothing breaks. Record in the track what the build output shows for `/s/[token]/[brand]`.

- [ ] **Step 5: Run the test, build, and prove the mutations**

```bash
cd WT && bun test src/components/client-lane/portal/LaneExchange.test.tsx 2>&1 | /usr/bin/grep -E "^[[:space:]]*[0-9]+ (pass|fail)|^\(fail\)|[0-9]+ error"
cd WT && node ./node_modules/next/dist/bin/next build 2>&1 | /usr/bin/grep -E "/s/|Failed|rror" | head -30
```

Expected:
- the test shows `0 fail`;
- the build's route table lists `/s/[token]`, `/s/[token]/[brand]`, `/s/[token]/opengraph-image`, `/s/api/portal/[...path]`, `/s/api/share-links/[...path]`, `/s/session`, `/s/session/code`, `/s/session/exchange`, `/s/verify/[token]` and `/s/verify/expired`;
- there is no "You cannot use different slug names" and no `Failed to compile`.

Apply each mutation, watch its test fail, and restore.

- [ ] **Step 6: Lint, format, commit**

```bash
cd WT && F=(src/components/client-lane/portal/LaneExchange.tsx src/components/client-lane/portal/LaneExchange.test.tsx "src/app/s/[token]/[brand]/page.tsx") && ./node_modules/.bin/prettier --write "${F[@]}" && ./node_modules/.bin/eslint "${F[@]}" && /usr/bin/git add "${F[@]}" && /usr/bin/git commit -F - <<'EOF'
feat(web): the /s/{workspace}/{brand} portal route and lane exchange gate

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---
### Task 14: The review page `/s/{token}` with a session

**Files:**
- Modify: `src/lib/client-lane/types.ts`
- Modify: `src/lib/client-lane/portal/shell.ts`, `shell.test.ts` (drop the Task 2 casts)
- Modify: `src/components/client-lane/StatusPill.tsx` (`ApproverPill` gains `opened`)
- Modify: `src/components/client-lane/ApproverList.tsx` (add `RequestApproverList`)
- Modify: `src/components/client-lane/DecisionPage.tsx`
- Modify: `src/app/s/[token]/page.tsx`
- Test: `src/components/client-lane/DecisionPage.portal.test.tsx`

**Interfaces:**
- Consumes:
  - Task 2: `portalHref`, `portalIdentityLine`, `portalBrandForShare`, `approverTone`;
  - Task 1: `viewOnlyNotice`, `PortalSession`;
  - Task 6: `LaneAuth`;
  - Task 10: `PortalHeader`, `PortalViewOnlyNotice`;
  - Task 13: `ReviewLaneExchange`;
  - Task 8: `resolvePortalMeServer`;
  - Task 4's cookies;
  - existing: `PersonAvatar`.
- Produces:
  - `DecisionPage({ token, initialData, portal? })`;
  - `RequestApproverList({ approvers })`;
  - `ApproverPill({ decided, opened? })`.

Spec §6.5 and §9:
- the portal header with the switcher;
- "← Approvals" as a v2 `Button variant="text"` with an icon;
- "Deciding as {name}";
- the approver list via `ApproverList` + `PersonAvatar` + `ApproverPill`, reading Not opened / Opened / Decided;
- for `all_view`, every decision control is replaced by the view-only notice, and pins stay placeable.

**Without a session (`portal` null) nothing changes**: same header, same direct api calls, same copy.

- [ ] **Step 1: Widen the public types**

In `src/lib/client-lane/types.ts`:

- In `PublicRequestApprover`, add after `decided: boolean;`:

```ts
  /** (assumed, portal) Opened the request link — `approval_request_views`.
   *  Absent on older payloads, which read as "Not opened". */
  opened?: boolean;
```

- In `ShareLinkBase`, change `workspace: { name: string };` to:

```ts
  /** `slug` (assumed, portal) lets the review page find the portal brand;
   *  absent on older payloads — the match falls back to the name. */
  workspace: { name: string; slug?: string };
```

- In `PublicErrorCode`, add `| "view_only"` and `| "session_required"` after `"code_expired"`.

In `src/lib/client-lane/portal/shell.ts`, replace `const wsSlug = (share.workspace as { slug?: string }).slug;` with `const wsSlug = share.workspace.slug;`. In `shell.test.ts`, drop the `as { name: string }` cast on the "Renamed" fixture.

- [ ] **Step 2: Write the failing test**

Create `src/components/client-lane/DecisionPage.portal.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, waitFor, within } from "@testing-library/react";
import posthog from "posthog-js";
import { useState, type ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { portalBrand, portalMe } from "@/lib/client-lane/portal/fixtures";
import type {
  ClientAccessLevel,
  PortalSession,
} from "@/lib/client-lane/portal/types";
import { deckRequestLink, publicRequest } from "@/lib/client-lane/testFixtures";
import type { ShareLinkData } from "@/lib/client-lane/types";
import { axiosPublic } from "@/services/axios";

import { DecisionPage } from "./DecisionPage";

const body = () => within(document.body);
const LANE = "abcdefghijklmnop";

/** `/s/session` hands back a lane code; comments answer empty on either path. */
function stub() {
  vi.spyOn(globalThis, "fetch").mockImplementation(
    (async () =>
      new Response(JSON.stringify({ code: LANE }), {
        status: 200,
      })) as unknown as typeof fetch
  );
  const get = vi.spyOn(axiosPublic, "get").mockImplementation((async (
    url: string
  ) => {
    if (
      url === "share-links/tok/comments" ||
      url === "public/share-links/tok/comments"
    ) {
      return { data: { data: [] } };
    }
    throw new Error(`unexpected GET ${url}`);
  }) as never);
  vi.spyOn(posthog, "capture").mockImplementation(() => undefined as never);
  return { get };
}

function QueryWrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

/** The deck fixture's brand: Garuda via Alva. */
function session(access: ClientAccessLevel): PortalSession {
  const brand = portalBrand({
    workspace: { name: "Alva", slug: "alva" },
    brand: { name: "Garuda", slug: "garuda", logo_url: null },
    access_level: access,
  });
  return { me: portalMe({ brands: [brand] }), brand };
}

function renderPage(
  portal: PortalSession | null,
  data: ShareLinkData = deckRequestLink()
) {
  return render(
    <DecisionPage token="tok" initialData={data} portal={portal} />,
    { wrapper: QueryWrapper }
  );
}

describe("DecisionPage with a client portal session (spec §6.5)", () => {
  beforeEach(() => vi.restoreAllMocks());

  it("replaces the decision controls with the view-only notice for an all_view client", async () => {
    stub();
    renderPage(session("all_view"));
    expect(
      await body().findByText(
        "You can view everything Alva sends for Garuda. Ask Alva if you need to approve."
      )
    ).toBeInTheDocument();
    expect(body().queryByRole("button", { name: "Approve deck" })).toBeNull();
    expect(body().queryByText("Deciding as Dina Pratiwi")).toBeNull();
  });

  it("decides as the session person and links back to Approvals", async () => {
    stub();
    renderPage(session("all_approve"));
    expect(await body().findByText("Deciding as Dina Pratiwi")).toBeInTheDocument();
    expect(body().getByRole("link", { name: "Approvals" })).toHaveAttribute(
      "href",
      "/s/alva/garuda"
    );
    expect(body().getByRole("button", { name: "Approve deck" })).toBeInTheDocument();
  });

  it("shows who opened the request", async () => {
    stub();
    renderPage(
      session("own"),
      deckRequestLink({
        request: publicRequest({
          approvers: [
            { name: "Dina Pratiwi", decided: false, opened: true },
            { name: "Andi", decided: false, opened: false },
          ],
        }),
      })
    );
    expect(await body().findByText("Opened")).toBeInTheDocument();
    expect(body().getByText("Not opened")).toBeInTheDocument();
  });

  it("sends its share-link calls through the same-origin BFF", async () => {
    const { get } = stub();
    renderPage(session("own"));
    await waitFor(() =>
      expect(get).toHaveBeenCalledWith("share-links/tok/comments", {
        baseURL: "/s/api/",
        headers: { "X-Lane-Code": LANE },
      })
    );
  });

  it("keeps the page exactly as before without a session", async () => {
    const { get } = stub();
    renderPage(null);
    await waitFor(() =>
      expect(get).toHaveBeenCalledWith("public/share-links/tok/comments", {
        headers: { "X-Lane-Code": LANE },
      })
    );
    expect(body().queryByRole("link", { name: "Approvals" })).toBeNull();
  });
});
```

Mutations:
- Drop `&& !viewOnly` from `requestCanDecide`, and the all_view test fails ("Approve deck" renders).
- Pass `laneCode` instead of `laneAuth` to `listPublicComments`, and "sends its share-link calls through the same-origin BFF" fails.
- Build `laneAuth` as `{ laneCode, session: true }` unconditionally, and "keeps the page exactly as before" fails.
- Render `ApproverPill decided={a.decided}` without `opened`, and "shows who opened" fails ("Waiting").

`deckRequestLink()` is `viewer.kind: "client"`, role `comment`, `can_decide: true`, one deck approval. Its button is "Approve deck" (`approveButtonLabel("deck")`). If the existing `DecisionPage.test.tsx` names it differently on this base, use the name it uses.

- [ ] **Step 3: Run it to verify it fails**

Run: `cd WT && bun test src/components/client-lane/DecisionPage.portal.test.tsx`
Expected: FAIL. TypeScript-level props are not checked at runtime, so it fails on behaviour: no view-only text, no "Deciding as", and the calls go direct.

- [ ] **Step 4: `ApproverPill` and `RequestApproverList`**

In `src/components/client-lane/StatusPill.tsx`, add `approverTone` to the `statusTone` import and replace `ApproverPill` with:

```tsx
/**
 * A named approver on a request: decided or waiting — or, where the page
 * knows views (the portal review page, spec 2026-10-06 portal §6.5),
 * Decided / Opened / Not opened.
 */
export function ApproverPill({
  decided,
  opened,
}: {
  decided: boolean;
  opened?: boolean;
}) {
  return <Pill tone={approverTone(decided, opened)} />;
}
```

`DECIDED_TONE` and `WAITING_TONE` may now be unused imports in `StatusPill.tsx`. Remove whichever eslint flags.

In `src/components/client-lane/ApproverList.tsx`, extend the imports:

```tsx
import type {
  Approval,
  PublicRequestApprover,
} from "@/lib/client-lane/types";

import { PersonAvatar } from "./agency/PersonAvatar";
import { ApproverPill } from "./StatusPill";
import { EYEBROW } from "./ui";
```

Then append:

```tsx
/**
 * The named approvers of a request, with who opened it (spec 2026-10-06
 * portal §6.5) — shown on the review page when a portal session is held.
 * Tokens only (this export is new code; the round list above is legacy).
 */
export function RequestApproverList({
  approvers,
}: {
  approvers: PublicRequestApprover[];
}) {
  if (approvers.length === 0) return null;
  return (
    <section
      aria-label="Approvers"
      className="flex flex-col gap-2 rounded-2xl border border-white/10 bg-white/5 p-4 font-geist"
    >
      <h2 className="text-textXsMedium uppercase tracking-wider text-text-inverse-subtlest">
        Approvers
      </h2>
      <ul className="flex flex-col gap-2">
        {approvers.map((approver, index) => (
          // Public approvers carry a name only — two may share it.
          <li key={`${approver.name}-${index}`} className="flex items-center gap-2">
            <PersonAvatar name={approver.name} />
            <span className="min-w-0 flex-1 truncate text-textSm text-text-inverse">
              {approver.name}
            </span>
            <ApproverPill decided={approver.decided} opened={approver.opened ?? false} />
          </li>
        ))}
      </ul>
    </section>
  );
}
```

- [ ] **Step 5: Wire the portal into `DecisionPage.tsx`**

Apply these edits exactly.

(a) Replace `import { FilePdf } from "@phosphor-icons/react";` with `import { ArrowLeft, FilePdf } from "@phosphor-icons/react";`.

(b) In the `@/lib/client-lane/publicApi` import block, add `type LaneAuth,` after `resolveShareLink,`.

(c) After `import { requestOf } from "@/lib/client-lane/requests";`, add:

```tsx
import { viewOnlyNotice } from "@/lib/client-lane/portal/inbox";
import {
  portalHref,
  portalIdentityLine,
} from "@/lib/client-lane/portal/shell";
import type { PortalSession } from "@/lib/client-lane/portal/types";
```

(d) Replace `import { ApproverList } from "./ApproverList";` with `import { ApproverList, RequestApproverList } from "./ApproverList";`.

(e) After `import { SubjectTextCard } from "./SubjectTextCard";`, add:

```tsx
import { PortalHeader } from "./portal/PortalHeader";
import { PortalViewOnlyNotice } from "./portal/PortalViewOnlyNotice";
```

(f) Replace

```tsx
export function DecisionPage({
  token,
  initialData,
}: {
  token: string;
  initialData: ShareLinkData;
}) {
  const [data, setData] = useState<ShareLinkData>(initialData);
  const [laneCode, setLaneCode] = useState<string | null>(null);
```

with

```tsx
export function DecisionPage({
  token,
  initialData,
  portal = null,
}: {
  token: string;
  initialData: ShareLinkData;
  /**
   * A client session holding a lane on this link's brand (spec 2026-10-06
   * portal §6.5), resolved by the server component. Null — no session, or
   * no lane here — keeps the page exactly as before.
   */
  portal?: PortalSession | null;
}) {
  const [data, setData] = useState<ShareLinkData>(initialData);
  const [laneCode, setLaneCode] = useState<string | null>(null);
  /** How share-link calls authenticate: the lane code alone (straight to
   *  the api, as before) or, with a portal session, through the BFF. */
  const laneAuth = useMemo<LaneAuth>(
    () => (portal ? { laneCode, session: true } : laneCode),
    [portal, laneCode]
  );
  /** spec §4.5: an `all_view` client reads and pins, never decides. */
  const viewOnly = portal?.brand.access_level === "all_view";
  const viewOnlyText = viewOnlyNotice(data.workspace.name, data.brand.name);
```

(g) Replace `  const canDecide = data.access.can_decide && roundOpen;` with `  const canDecide = data.access.can_decide && roundOpen && !viewOnly;`.

(h) Replace

```tsx
  const requestCanDecide =
    req !== null && data.access.can_decide && requestOpen;
```

with

```tsx
  const requestCanDecide =
    req !== null && data.access.can_decide && requestOpen && !viewOnly;
```

Folding view-only into these two flags removes every decision affordance downstream: the action bar, the KV card buttons (`onDecide: requestCanDecide …`), "Needs your decision", the phone bottom padding and the approver hint.

(i) Transport. In each of these calls, the last argument `laneCode` becomes `laneAuth`:
- `listPublicComments(token, laneCode)`;
- `resolveShareLink(token, laneCode)` inside `refresh`;
- `postDecision(…, laneCode)`;
- `postRequestDecision(…, laneCode)`;
- `downloadPublicRecord(token, laneCode)`;
- both `postPublicComment(…, laneCode)` calls (the pin and the reply).

In the dependency array of each effect or callback that holds one of those calls, `laneCode` becomes `laneAuth`. **Leave alone** `resolveShareLink(token, lane.lane_code)` inside `onCodeVerified`: a code just verified this visit goes direct, as before. Then check:

```bash
cd WT && /usr/bin/grep -n "laneCode" src/components/client-lane/DecisionPage.tsx
```

Expected, and nothing else: the `useState` declaration, the `laneAuth` memo (two lines), `setLaneCode(…)` calls, `isLaneCode(…)`, and `lane.lane_code`.

(j) Inside the ROUND decision's `catch` (the block that starts `if (err.code === "verification_required") {` and continues `writeDraft(token, draft); setVerifySent(false);`), replace

```tsx
          } else if (err.code === "round_closed") {
            clearDraft(token);
            setSheet(null);
            await refresh();
```

with

```tsx
          } else if (err.code === "view_only") {
            // The access level changed under an open page (spec §4.5).
            clearDraft(token);
            setSheet(null);
            setError(viewOnlyText);
          } else if (err.code === "round_closed") {
            clearDraft(token);
            setSheet(null);
            await refresh();
```

Then add `viewOnlyText` to that callback's dependency array, `[token, laneAuth, data.type, data.viewer.email, refresh, itemCount]`.

(k) Inside the REQUEST decision's `catch`, replace

```tsx
            setSheet({
              kind: "code",
              email: g?.email ?? data.viewer.email ?? "",
            });
          } else if (err.code === "guest_required") {
```

with

```tsx
            setSheet({
              kind: "code",
              email: g?.email ?? data.viewer.email ?? "",
            });
          } else if (err.code === "view_only") {
            clearDraft(token);
            setSheet(null);
            setError(viewOnlyText);
          } else if (err.code === "guest_required") {
```

Then add `viewOnlyText` to `doSubmitRequest`'s dependency array.

(l) Replace

```tsx
  const identityLine = verifiedSummary(
    hasLane ? data.viewer.kind : "anonymous",
    guest?.name ?? data.viewer.name,
    justVerified
  );
```

with

```tsx
  const identityLine = portal
    ? portalIdentityLine(portal.me, portal.brand)
    : verifiedSummary(
        hasLane ? data.viewer.kind : "anonymous",
        guest?.name ?? data.viewer.name,
        justVerified
      );
```

(m) In the header, wrap the existing brand line (the `<div className="flex items-center justify-between gap-3 text-[13px]">` block, from that line through its closing `</div>` just before `<div className="flex flex-col gap-1">`) as follows. The old block stays byte-identical inside the `: (` branch:

```tsx
          {portal ? (
            <>
              <PortalHeader
                me={portal.me}
                current={portal.brand}
                surface="review_page"
              />
              <Button
                variant="text"
                size="small"
                className="self-start"
                nativeButton={false}
                render={<a href={portalHref(portal.brand)} />}
                leftIcon={<ArrowLeft size={14} aria-hidden />}
              >
                Approvals
              </Button>
            </>
          ) : (
            <div className="flex items-center justify-between gap-3 text-[13px]">
              <span className="flex min-w-0 items-center gap-2 text-white/70">
                {data.brand.logo_url &&
                /^https?:\/\//.test(data.brand.logo_url) ? (
                  // eslint-disable-next-line @next/next/no-img-element
                  <img
                    src={data.brand.logo_url}
                    alt=""
                    className="h-6 w-6 shrink-0 rounded-full object-cover"
                  />
                ) : null}
                <span className="truncate">
                  <span className="font-medium text-white">
                    {data.brand.name}
                  </span>
                  {" · via "}
                  {data.workspace.name}
                </span>
              </span>
              <span className="flex shrink-0 items-center gap-1 text-white/60">
                {viewerName ? (
                  <>
                    <span className="text-white">{viewerName}</span>
                    <button
                      type="button"
                      onClick={notYou}
                      className="min-h-[32px] rounded-full px-2 text-[12px] text-white/45 underline-offset-2 hover:text-white hover:underline"
                    >
                      not you?
                    </button>
                  </>
                ) : null}
              </span>
            </div>
          )}
```

That `: (` branch is the existing block moved one level in, with its contents unchanged. Compare it with the base before committing: `git diff -w` must show only the wrapper lines. The legacy `text-[13px]` and `text-white` classes are pre-existing lines this plan does not rewrite.

(n) After the `RequestOverview` element, the one whose last prop is

```tsx
                className={
                  overviewHiddenOnPhone(data.type, focusedArtboard !== null)
                    ? "max-lg:hidden"
                    : undefined
                }
              />
```

add

```tsx
              {portal && (
                <RequestApproverList approvers={req.request.approvers} />
              )}
```

(o) Before

```tsx
          {notice && (
            <p
              role="status"
```

add

```tsx
          {portal && viewOnly && (requestOpen || roundOpen) && (
            <PortalViewOnlyNotice text={viewOnlyText} />
          )}
```

- [ ] **Step 6: The server component passes the session and the portal context**

In `src/app/s/[token]/page.tsx`:

Replace the cookie import line with:

```tsx
import {
  CLIENT_SESSION_COOKIE,
  LANE_COOKIE,
  LANE_FRESH_COOKIE,
  isClientSessionToken,
  isLaneCode,
  shouldExchangeLane,
} from "@/lib/client-lane/cookie";
```

Add these imports:

```tsx
import { ReviewLaneExchange } from "@/components/client-lane/portal/LaneExchange";
import { resolvePortalMeServer } from "@/lib/client-lane/portal/server";
import { portalBrandForShare } from "@/lib/client-lane/portal/shell";
import type { PortalSession } from "@/lib/client-lane/portal/types";
```

Add after `laneCodeFromRequest`:

```tsx
/**
 * The client session (spec 2026-10-06 portal §4.5) — read here ONLY to
 * forward to the api as `X-Client-Session`. It is never passed to a client
 * component; `DecisionPage` gets the resolved `me`, not the token.
 */
async function sessionFromRequest(): Promise<string | null> {
  const jar = await cookies();
  const value = jar.get(CLIENT_SESSION_COOKIE)?.value;
  return isClientSessionToken(value) ? value : null;
}

/** A `?k=` capture just happened (the middleware's fresh marker). */
async function freshLaneCapture(): Promise<boolean> {
  const jar = await cookies();
  return shouldExchangeLane({
    lane: jar.get(LANE_COOKIE)?.value,
    fresh: jar.get(LANE_FRESH_COOKIE)?.value,
  });
}

/** The portal context, or null — an outage of `me` must never break the page. */
async function portalFor(
  session: string,
  data: ShareLinkData
): Promise<PortalSession | null> {
  try {
    const me = await resolvePortalMeServer(session);
    if (!me) return null;
    const brand = portalBrandForShare(me, data);
    return brand ? { me, brand } : null;
  } catch {
    return null;
  }
}
```

The cookie import above replaces the old `import { LANE_COOKIE, isLaneCode } from "@/lib/client-lane/cookie";` line. In `generateMetadata`, replace

```tsx
  const laneCode = await laneCodeFromRequest();
```

with

```tsx
  const laneCode = await laneCodeFromRequest();
  const session = await sessionFromRequest();
```

and `resolved = await resolvePublicShareServer(token, laneCode);` with `resolved = await resolvePublicShareServer(token, laneCode, session);`. The page and its metadata must pass the SAME three arguments so React `cache` dedupes them into one api call.

Replace the page body

```tsx
  const { token } = await params;
  const laneCode = await laneCodeFromRequest();
  const data = await resolvePublicShareServer(token, laneCode);

  if (!data) return <DeadLinkPage />;
  if (isScorecardReportShare(data))
    return <PublicScorecardReport share={data} />;

  return <DecisionPage token={token} initialData={data} />;
```

with

```tsx
  const { token } = await params;
  const laneCode = await laneCodeFromRequest();
  const session = await sessionFromRequest();
  const data = await resolvePublicShareServer(token, laneCode, session);

  if (!data) return <DeadLinkPage />;
  if (isScorecardReportShare(data))
    return <PublicScorecardReport share={data} />;

  const portal = session ? await portalFor(session, data) : null;
  const exchange = await freshLaneCapture();

  return (
    <>
      <DecisionPage token={token} initialData={data} portal={portal} />
      {exchange ? <ReviewLaneExchange reload={session !== null} /> : null}
    </>
  );
```

- [ ] **Step 7: Run the new and the old client-page suites, then prove each named mutation**

```bash
cd WT && for f in src/components/client-lane/DecisionPage.portal.test.tsx src/components/client-lane/DecisionPage.test.tsx src/lib/client-lane/portal/shell.test.ts src/lib/client-lane/statusTone.approver.test.ts src/components/client-lane/agency/ApprovalStatusBlock.test.tsx; do echo "== $f"; bun test "$f" 2>&1 | /usr/bin/grep -E "^[[:space:]]*[0-9]+ (pass|fail)|^\(fail\)|[0-9]+ error"; done
cd WT && wc -c src/components/client-lane/DecisionPage.portal.test.tsx
```

Expected:
- the new file shows `0 fail`, no `error`, and is < 45 000 bytes;
- the old files show exactly their Task 0 failure lists;
- `ApprovalRequestsSection`'s `ApproverPill decided={…}` callers still read "Waiting"/"Decided", because `opened` is undefined.

Apply each mutation, watch its test fail, and restore.

- [ ] **Step 8: Types, lint, commit**

```bash
cd WT && ./node_modules/.bin/tsc --noEmit -p . 2>&1 | /usr/bin/grep -E "DecisionPage|ApproverList|StatusPill|client-lane/types|portal/shell|s/\[token\]/page" ; echo "tsc scan done"
cd WT && F=(src/lib/client-lane/types.ts src/lib/client-lane/portal/shell.ts src/lib/client-lane/portal/shell.test.ts src/components/client-lane/StatusPill.tsx src/components/client-lane/ApproverList.tsx src/components/client-lane/DecisionPage.tsx "src/app/s/[token]/page.tsx" src/components/client-lane/DecisionPage.portal.test.tsx) && ./node_modules/.bin/prettier --write src/components/client-lane/DecisionPage.portal.test.tsx && ./node_modules/.bin/eslint "${F[@]}" && /usr/bin/git add "${F[@]}" && /usr/bin/git commit -F - <<'EOF'
feat(web): review page knows the portal — header, Approvals link, deciding as, opened, view only

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

Expected: the tsc scan prints no line for these paths beyond the Task 0 per-file baseline. Run prettier only on the files that are prettier-clean on BASE, as listed in the Global Constraints check, and hand-format the rest.

---
## Phase 4 — agency side (behind `show-client-lane`)

### Task 15: Clients rules and the agency services

**Files:**
- Create: `src/lib/client-lane/clients.ts`
- Test: `src/lib/client-lane/clients.test.ts`
- Create: `src/lib/client-lane/approverSuggestions.ts`
- Test: `src/lib/client-lane/approverSuggestions.test.ts`
- Create: `src/services/brand-clients.ts`
- Test: `src/services/brand-clients.test.ts`

**Interfaces:**
- Consumes: `ClientAccessLevel`, `CLIENT_ACCESS_LEVELS` (Task 1); `ACCESS_LEVEL_LABEL` (Task 1); `relativeTime`; `date-fns` `format`; `axiosInstance`; `ShareSubjectType`.
- Produces:
  - in `clients.ts`:
    - types `BrandClient`, `ClientAddedFrom`;
    - `CLIENTS_EMPTY_TEXT`, `clientsTabLabel(count)`;
    - `clientStatusLine(c, now?)`, `clientAddedLine(c)`, `filterClients(rows, query)`;
    - `absolutePortalUrl(url, origin)`, `removeConfirmText(name, brand)`;
    - `accessLevelOptions()`, `isClientAccessLevel(v)`;
  - in `approverSuggestions.ts`:
    - types `ApproverSuggestion`, `ApproverChipTag`;
    - `approverChipTag(email, suggestions, ready)`, `viewOnlyPicks(emails, suggestions)`, `pickableSuggestions(suggestions, picked)`;
  - in `brand-clients.ts`:
    - keys `brandClientsKey(brandId)`, `APPROVER_SUGGESTIONS_ROOT`, `approverSuggestionsKey(type, id)`;
    - calls `listBrandClients`, `updateClientAccess`, `createClientPortalLink`, `removeBrandClient`, `listApproverSuggestions`;
    - hooks `useBrandClients(brandId, { enabled })`, `useUpdateClientAccess(brandId)`, `useClientPortalLink(brandId)`, `useRemoveBrandClient(brandId)`, `useApproverSuggestions(subject | null)`.

- [ ] **Step 1: Write the failing tests**

Create `src/lib/client-lane/clients.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import {
  absolutePortalUrl,
  accessLevelOptions,
  clientAddedLine,
  clientStatusLine,
  clientsTabLabel,
  filterClients,
  isClientAccessLevel,
  removeConfirmText,
  type BrandClient,
} from "./clients";

const client = (overrides: Partial<BrandClient> = {}): BrandClient => ({
  user: { id: "u1", name: "Dina Pratiwi", email: "dina@tokopedia.com" },
  access_level: "own",
  added_at: "2026-10-03T12:00:00.000Z",
  added_from: "KV approval request",
  last_opened_at: null,
  status: "not_opened",
  ...overrides,
});

describe("Clients tab copy (spec §7.2)", () => {
  it("says whether the client opened the portal", () => {
    expect(clientStatusLine(client())).toBe("Not opened yet");
    expect(
      clientStatusLine(
        client({ last_opened_at: "2026-10-06T08:00:00.000Z", status: "active" }),
        new Date("2026-10-06T10:00:00.000Z")
      )
    ).toBe("Opened 2 hours ago");
  });

  it("says when and from where the client was added", () => {
    expect(clientAddedLine(client())).toBe("Added 3 Oct · from a KV approval request");
    expect(clientAddedLine(client({ added_from: null }))).toBe("Added 3 Oct");
  });

  it("confirms a removal in the spec's words", () => {
    expect(removeConfirmText("Dina Pratiwi", "frndGlow")).toBe(
      "Dina Pratiwi can no longer open frndGlow links. Decisions they made stay on record."
    );
  });

  it("labels the tab with its count", () => {
    expect(clientsTabLabel(3)).toBe("Clients (3)");
    expect(clientsTabLabel(undefined)).toBe("Clients (0)");
  });

  it("offers the three levels in order", () => {
    expect(accessLevelOptions()).toEqual([
      { value: "own", label: "Own requests" },
      { value: "all_approve", label: "All requests + approve" },
      { value: "all_view", label: "All requests, view only" },
    ]);
    expect(isClientAccessLevel("all_view")).toBe(true);
    expect(isClientAccessLevel("admin")).toBe(false);
  });
});

describe("filterClients", () => {
  it("matches name or email, case-insensitively, trimmed", () => {
    const rows = [client(), client({ user: { id: "u2", name: "Andi", email: "andi@brand.co" } })];
    expect(filterClients(rows, "  ANDI ").map((c) => c.user.id)).toEqual(["u2"]);
    expect(filterClients(rows, "tokopedia").map((c) => c.user.id)).toEqual(["u1"]);
    expect(filterClients(rows, "")).toHaveLength(2);
  });
});

describe("absolutePortalUrl", () => {
  it("makes the api's relative portal link absolute on this origin", () => {
    expect(
      absolutePortalUrl("/s/fcn/frndglow?k=abcdefghijklmnop", "https://app.frnd.io")
    ).toBe("https://app.frnd.io/s/fcn/frndglow?k=abcdefghijklmnop");
  });
});
```

Create `src/lib/client-lane/approverSuggestions.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import {
  approverChipTag,
  pickableSuggestions,
  viewOnlyPicks,
  type ApproverSuggestion,
} from "./approverSuggestions";

const dina: ApproverSuggestion = {
  user_id: "u1",
  name: "Dina",
  email: "dina@tokopedia.com",
  access_level: "all_view",
};
const andi: ApproverSuggestion = {
  user_id: "u2",
  name: "Andi",
  email: "andi@tokopedia.com",
  access_level: "own",
};

describe("approver chip tags (spec §7.3)", () => {
  it("tags a view-only client and a brand-new address", () => {
    expect(approverChipTag("dina@tokopedia.com", [dina, andi], true)).toBe("view only");
    expect(approverChipTag("new@brand.co", [dina, andi], true)).toBe("New client");
    expect(approverChipTag("andi@tokopedia.com", [dina, andi], true)).toBeNull();
  });

  it("matches the address case-insensitively", () => {
    expect(approverChipTag("DINA@tokopedia.com", [dina], true)).toBe("view only");
  });

  it("tags nothing until the suggestions have loaded", () => {
    expect(approverChipTag("new@brand.co", [], false)).toBeNull();
  });
});

describe("viewOnlyPicks / pickableSuggestions", () => {
  it("finds the picked view-only clients", () => {
    expect(viewOnlyPicks(["dina@tokopedia.com", "andi@tokopedia.com"], [dina, andi])).toEqual([dina]);
  });

  it("suggests only who is not picked yet, six at most", () => {
    const many = Array.from({ length: 8 }, (_, i) => ({
      ...andi,
      user_id: `u${i}`,
      email: `p${i}@brand.co`,
    }));
    expect(pickableSuggestions([dina, andi], ["dina@tokopedia.com"])).toEqual([andi]);
    expect(pickableSuggestions(many, [])).toHaveLength(6);
  });
});
```

Create `src/services/brand-clients.test.ts`:

```ts
import { beforeEach, describe, expect, it, vi } from "vitest";

import axiosInstance from "@/services/axios";

import {
  createClientPortalLink,
  listApproverSuggestions,
  listBrandClients,
  removeBrandClient,
  updateClientAccess,
} from "./brand-clients";

describe("brand clients api (spec §7.1, §7.3)", () => {
  beforeEach(() => vi.restoreAllMocks());

  it("lists a brand's clients", async () => {
    const get = vi
      .spyOn(axiosInstance, "get")
      .mockResolvedValue({ data: { data: [] } } as never);
    await listBrandClients("b1");
    expect(get).toHaveBeenCalledWith("v1/brands/b1/clients");
  });

  it("changes one client's access level", async () => {
    const patch = vi
      .spyOn(axiosInstance, "patch")
      .mockResolvedValue({ data: { data: {} } } as never);
    await updateClientAccess("b1", "u1", "all_approve");
    expect(patch).toHaveBeenCalledWith("v1/brands/b1/clients/u1", {
      access_level: "all_approve",
    });
  });

  it("reads the portal link from either envelope", async () => {
    const post = vi
      .spyOn(axiosInstance, "post")
      .mockResolvedValueOnce({ data: { data: { url: "/s/fcn/frndglow?k=a" } } } as never)
      .mockResolvedValueOnce({ data: { url: "/s/fcn/frndglow?k=b" } } as never);
    await expect(createClientPortalLink("b1", "u1")).resolves.toBe("/s/fcn/frndglow?k=a");
    await expect(createClientPortalLink("b1", "u1")).resolves.toBe("/s/fcn/frndglow?k=b");
    expect(post).toHaveBeenCalledWith("v1/brands/b1/clients/u1/portal-link");
  });

  it("removes a client", async () => {
    const del = vi
      .spyOn(axiosInstance, "delete")
      .mockResolvedValue({ status: 204 } as never);
    await removeBrandClient("b1", "u1");
    expect(del).toHaveBeenCalledWith("v1/brands/b1/clients/u1");
  });

  it("asks for approver suggestions by subject — the send permission, not settings", async () => {
    const get = vi
      .spyOn(axiosInstance, "get")
      .mockResolvedValue({ data: { data: [] } } as never);
    await listApproverSuggestions("deck", "d1");
    expect(get).toHaveBeenCalledWith("v1/approval-requests/approver-suggestions", {
      params: { subject_type: "deck", subject_id: "d1" },
    });
  });
});
```

Mutations:
- `clientStatusLine` ignoring `last_opened_at`, and "says whether the client opened" fails.
- `approverChipTag` without the `ready` guard, and "tags nothing until…" fails.
- Compare emails case-sensitively, and "matches the address case-insensitively" fails.
- `createClientPortalLink` reading only `data.data.url`, and "either envelope" fails.

- [ ] **Step 2: Run them to verify they fail**

Run each: `cd WT && bun test src/lib/client-lane/clients.test.ts`, then `bun test src/lib/client-lane/approverSuggestions.test.ts`, then `bun test src/services/brand-clients.test.ts`
Expected: all FAIL. The modules are not found.

- [ ] **Step 3: Write the rules**

Create `src/lib/client-lane/clients.ts`:

```ts
/**
 * The Clients tab's rules and copy (spec 2026-10-06 portal §7.2). Pure.
 */
import { format } from "date-fns";

import { relativeTime } from "@/lib/deck/relativeTime";

import { ACCESS_LEVEL_LABEL } from "./portal/inbox";
import { CLIENT_ACCESS_LEVELS, type ClientAccessLevel } from "./portal/types";

export type ClientAddedFrom =
  | "KV approval request"
  | "Deck approval request"
  | "Plan approval request";

/** One row of `GET v1/brands/{brand}/clients` (spec §7.1). */
export interface BrandClient {
  user: { id: string; name: string; email: string };
  access_level: ClientAccessLevel;
  added_at: string;
  added_from: ClientAddedFrom | null;
  last_opened_at: string | null;
  status: "not_opened" | "active";
}

export const CLIENTS_EMPTY_TEXT =
  "Clients appear here once you name them in a Request approval.";

export function clientsTabLabel(count: number | undefined): string {
  return `Clients (${count ?? 0})`;
}

/** "Opened 2 hours ago" / "Not opened yet". */
export function clientStatusLine(client: BrandClient, now: Date = new Date()): string {
  return client.last_opened_at
    ? `Opened ${relativeTime(client.last_opened_at, { now })}`
    : "Not opened yet";
}

/** "Added 3 Oct · from a KV approval request". */
export function clientAddedLine(client: BrandClient): string {
  const day = format(new Date(client.added_at), "d MMM");
  return client.added_from
    ? `Added ${day} · from a ${client.added_from}`
    : `Added ${day}`;
}

export function filterClients(
  rows: readonly BrandClient[],
  query: string
): BrandClient[] {
  const q = query.trim().toLowerCase();
  if (!q) return [...rows];
  return rows.filter(
    (c) =>
      c.user.name.toLowerCase().includes(q) || c.user.email.toLowerCase().includes(q)
  );
}

/** The api answers `/s/{ws}/{brand}?k=…`; the clipboard needs the full URL. */
export function absolutePortalUrl(url: string, origin: string): string {
  return new URL(url, origin).toString();
}

export function removeConfirmText(name: string, brandName: string): string {
  return `${name} can no longer open ${brandName} links. Decisions they made stay on record.`;
}

export function accessLevelOptions(): Array<{ value: ClientAccessLevel; label: string }> {
  return CLIENT_ACCESS_LEVELS.map((value) => ({
    value,
    label: ACCESS_LEVEL_LABEL[value],
  }));
}

export function isClientAccessLevel(value: unknown): value is ClientAccessLevel {
  return (CLIENT_ACCESS_LEVELS as readonly unknown[]).includes(value);
}
```

Create `src/lib/client-lane/approverSuggestions.ts`:

```ts
/**
 * The Request-approval picker's view of the brand's clients (spec
 * 2026-10-06 portal §7.3). Pure.
 */
import type { ClientAccessLevel } from "./portal/types";

/** One row of `GET v1/approval-requests/approver-suggestions`. */
export interface ApproverSuggestion {
  /** (assumed) Needed for the inline "Change to All requests + approve?". */
  user_id: string;
  name: string | null;
  email: string;
  access_level: ClientAccessLevel;
}

export type ApproverChipTag = "view only" | "New client";

const same = (a: string, b: string) => a.trim().toLowerCase() === b.trim().toLowerCase();

/**
 * A picked email's tag: "view only" for an `all_view` client (they cannot
 * decide — spec §4.5), "New client" for an address that is not a client of
 * this brand yet (created as `own`). Nothing until the list has loaded, or
 * every chip would flash "New client".
 */
export function approverChipTag(
  email: string,
  suggestions: readonly ApproverSuggestion[],
  ready: boolean
): ApproverChipTag | null {
  if (!ready) return null;
  const match = suggestions.find((s) => same(s.email, email));
  if (!match) return "New client";
  return match.access_level === "all_view" ? "view only" : null;
}

/** Picked clients who can only view — each gets the inline upgrade. */
export function viewOnlyPicks(
  emails: readonly string[],
  suggestions: readonly ApproverSuggestion[]
): ApproverSuggestion[] {
  return suggestions.filter(
    (s) => s.access_level === "all_view" && emails.some((e) => same(e, s.email))
  );
}

/** One-tap suggestions: not picked yet, six at most. */
export function pickableSuggestions(
  suggestions: readonly ApproverSuggestion[],
  picked: readonly string[]
): ApproverSuggestion[] {
  return suggestions.filter((s) => !picked.some((e) => same(e, s.email))).slice(0, 6);
}
```

- [ ] **Step 4: Write the services**

Create `src/services/brand-clients.ts`:

```ts
/**
 * Agency side of the client portal (spec 2026-10-06 portal §7.1, §7.3) —
 * authenticated, over the normal axios instance. The Members page reads and
 * changes a brand's clients; the Request-approval picker reads suggestions
 * with the SAME permission as sending a request (not brand settings).
 */
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import type { ApproverSuggestion } from "@/lib/client-lane/approverSuggestions";
import type { BrandClient } from "@/lib/client-lane/clients";
import type { ClientAccessLevel } from "@/lib/client-lane/portal/types";
import type { ShareSubjectType } from "@/lib/client-lane/types";
import axiosInstance from "@/services/axios";

export const brandClientsKey = (brandId: string) => ["brand-clients", brandId] as const;
export const APPROVER_SUGGESTIONS_ROOT = ["approver-suggestions"] as const;
export const approverSuggestionsKey = (subjectType: ShareSubjectType, subjectId: string) =>
  [...APPROVER_SUGGESTIONS_ROOT, subjectType, subjectId] as const;

export async function listBrandClients(brandId: string): Promise<BrandClient[]> {
  const res = await axiosInstance.get<{ data: BrandClient[] }>(`v1/brands/${brandId}/clients`);
  return res.data.data;
}

export async function updateClientAccess(
  brandId: string,
  userId: string,
  accessLevel: ClientAccessLevel
): Promise<BrandClient> {
  const res = await axiosInstance.patch<{ data: BrandClient }>(
    `v1/brands/${brandId}/clients/${userId}`,
    { access_level: accessLevel }
  );
  return res.data.data;
}

/** Relative `/s/{ws}/{brand}?k=…` — the existing code, never rotated. */
export async function createClientPortalLink(brandId: string, userId: string): Promise<string> {
  const res = await axiosInstance.post<{ data?: { url: string }; url?: string }>(
    `v1/brands/${brandId}/clients/${userId}/portal-link`
  );
  return res.data.data?.url ?? res.data.url ?? "";
}

/** Removes the client role — which revokes the lane (spec §4.2). */
export async function removeBrandClient(brandId: string, userId: string): Promise<void> {
  await axiosInstance.delete(`v1/brands/${brandId}/clients/${userId}`);
}

export async function listApproverSuggestions(
  subjectType: ShareSubjectType,
  subjectId: string
): Promise<ApproverSuggestion[]> {
  const res = await axiosInstance.get<{ data: ApproverSuggestion[] }>(
    "v1/approval-requests/approver-suggestions",
    { params: { subject_type: subjectType, subject_id: subjectId } }
  );
  return res.data.data;
}

export function useBrandClients(brandId: string, opts: { enabled?: boolean } = {}) {
  return useQuery({
    queryKey: brandClientsKey(brandId),
    queryFn: () => listBrandClients(brandId),
    enabled: Boolean(brandId) && (opts.enabled ?? true),
    staleTime: 15_000,
  });
}

/** Both the tab and the picker read access levels — refresh both. */
function refreshClients(qc: ReturnType<typeof useQueryClient>, brandId: string) {
  void qc.invalidateQueries({ queryKey: brandClientsKey(brandId) });
  void qc.invalidateQueries({ queryKey: APPROVER_SUGGESTIONS_ROOT });
}

export function useUpdateClientAccess(brandId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (input: { userId: string; accessLevel: ClientAccessLevel }) =>
      updateClientAccess(brandId, input.userId, input.accessLevel),
    onSuccess: () => refreshClients(qc, brandId),
  });
}

export function useClientPortalLink(brandId: string) {
  return useMutation({
    mutationFn: (userId: string) => createClientPortalLink(brandId, userId),
  });
}

export function useRemoveBrandClient(brandId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (userId: string) => removeBrandClient(brandId, userId),
    onSuccess: () => refreshClients(qc, brandId),
  });
}

export function useApproverSuggestions(
  subject: { type: ShareSubjectType; id: string } | null
) {
  return useQuery({
    queryKey: approverSuggestionsKey(subject?.type ?? "kv_file", subject?.id ?? ""),
    queryFn: () => listApproverSuggestions(subject!.type, subject!.id),
    enabled: subject !== null && Boolean(subject.id),
    staleTime: 30_000,
  });
}
```

- [ ] **Step 5: Run the tests to verify they pass, then prove each named mutation**

Run the three files one per invocation (Step 2's commands).
Expected: PASS. If `clientStatusLine` prints something other than `2 hours ago`, recompute it from `relativeTime` and fix the expectation. `format(…, "d MMM")` renders in local time. `12:00Z` is "3 Oct" from UTC−11 to UTC+11; if the machine is outside that range, note it. Apply each mutation, watch its test fail, and restore.

- [ ] **Step 6: Lint, format, commit**

```bash
cd WT && F=(src/lib/client-lane/clients.ts src/lib/client-lane/clients.test.ts src/lib/client-lane/approverSuggestions.ts src/lib/client-lane/approverSuggestions.test.ts src/services/brand-clients.ts src/services/brand-clients.test.ts) && ./node_modules/.bin/prettier --write "${F[@]}" && ./node_modules/.bin/eslint "${F[@]}" && /usr/bin/git add "${F[@]}" && /usr/bin/git commit -F - <<'EOF'
feat(web): brand clients services and Clients-tab rules

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 16: The Clients tab in Brand Settings → Members

**Files:**
- Create: `src/components/brands/settings/clients/ClientAvatar.tsx` (v1 only)
- Create: `src/components/brands/settings/clients/ClientRemoveModal.tsx` (v1 only)
- Create: `src/components/brands/settings/clients/ClientsEmptyState.tsx` (v1 only)
- Create: `src/components/brands/settings/clients/ClientsTab.tsx` (v2 only)
- Test: `src/components/brands/settings/clients/ClientsTab.test.tsx`
- Modify: `src/app/(dashboard)/brands/[id]/settings/members/page.tsx` (hand-formatted; never run prettier on it)

**Interfaces:**
- Consumes: Task 15 rules and hooks; Task 9 `trackClientAccessChanged`, `trackClientAccessChangeFailed`, `trackClientPortalLinkCopied`, `trackClientPortalLinkCopyFailed`, `trackClientRemoved`, `trackClientRemoveFailed`; `failureReason`; `approvalApiError` (`@/services/client-lane`); `useToastStore`; `useClientLaneEnabled` (`@/lib/featureFlags`, page only); `useBrandDetail` (`@/hooks/useBrandBook`, which answers `{ data: { name } }`); `usePermissions().canWriteForBrand("brand.settings", brandId)`.
- Produces: `ClientsTab({ brandId, brandName, query, canEdit })`.

§9 mapping:

| Surface | Component |
|---|---|
| Tab | v1 `PillTabs`, as the page's third tab |
| Search | the page's existing v1 `Input`; `ClientsTab` takes `query` |
| Rows | the page's member-row layout with v1 `Avatar` (through `ClientAvatar`) |
| Access level select | v2 `SelectMenu` |
| Row "…" menu | v2 `ActionMenu`: Copy portal link, Remove access (danger) |
| Remove confirm | v1 `BaseModal` (`ClientRemoveModal`). The v2 `Button` footer (`alertPrimary`) is built in `ClientsTab` and passed in, so no file mixes v1 and v2. |
| Empty state | v1 `EmptyState` (`ClientsEmptyState`) |

Every mutating control needs `brand.settings.write` (`canEdit`). The api enforces it anyway (§7.1).

- [ ] **Step 1: Write the failing test**

Create `src/components/brands/settings/clients/ClientsTab.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import posthog from "posthog-js";
import { useState, type ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import type { BrandClient } from "@/lib/client-lane/clients";
import axiosInstance from "@/services/axios";

import { ClientsTab } from "./ClientsTab";

const body = () => within(document.body);

const dina: BrandClient = {
  user: { id: "u1", name: "Dina Pratiwi", email: "dina@tokopedia.com" },
  access_level: "own",
  added_at: "2026-10-03T12:00:00.000Z",
  added_from: "KV approval request",
  last_opened_at: null,
  status: "not_opened",
};

function QueryWrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

function renderTab(rows: BrandClient[] = [dina], canEdit = true) {
  vi.spyOn(axiosInstance, "get").mockResolvedValue({ data: { data: rows } } as never);
  const capture = vi
    .spyOn(posthog, "capture")
    .mockImplementation(() => undefined as never);
  render(<ClientsTab brandId="b1" brandName="frndGlow" query="" canEdit={canEdit} />, {
    wrapper: QueryWrapper,
  });
  return { capture };
}

describe("ClientsTab (spec §7.2)", () => {
  beforeEach(() => vi.restoreAllMocks());

  it("changes a client's access level and says from what to what", async () => {
    const user = userEvent.setup();
    const patch = vi
      .spyOn(axiosInstance, "patch")
      .mockResolvedValue({ data: { data: { ...dina, access_level: "all_view" } } } as never);
    const { capture } = renderTab();
    await user.click(
      await body().findByRole("button", { name: "Access level for Dina Pratiwi: Own requests" })
    );
    await user.click(await body().findByRole("menuitemradio", { name: "All requests, view only" }));
    await waitFor(() =>
      expect(patch).toHaveBeenCalledWith("v1/brands/b1/clients/u1", { access_level: "all_view" })
    );
    await waitFor(() =>
      expect(capture).toHaveBeenCalledWith(
        "client_lane.client_access_changed",
        expect.objectContaining({ from: "own", to: "all_view", source: "clients_tab" })
      )
    );
  });

  it("copies the absolute portal link", async () => {
    const user = userEvent.setup();
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "clipboard", { value: { writeText }, configurable: true });
    vi.spyOn(axiosInstance, "post").mockResolvedValue({
      data: { data: { url: "/s/fcn/frndglow?k=abcdefghijklmnop" } },
    } as never);
    renderTab();
    await user.click(await body().findByRole("button", { name: "Actions for Dina Pratiwi" }));
    await user.click(await body().findByRole("menuitem", { name: "Copy portal link" }));
    await waitFor(() =>
      expect(writeText).toHaveBeenCalledWith(
        `${window.location.origin}/s/fcn/frndglow?k=abcdefghijklmnop`
      )
    );
  });

  it("removes access only after the confirm", async () => {
    const user = userEvent.setup();
    const del = vi.spyOn(axiosInstance, "delete").mockResolvedValue({ status: 204 } as never);
    const { capture } = renderTab();
    await user.click(await body().findByRole("button", { name: "Actions for Dina Pratiwi" }));
    await user.click(await body().findByRole("menuitem", { name: "Remove access" }));
    expect(
      await body().findByText(
        "Dina Pratiwi can no longer open frndGlow links. Decisions they made stay on record."
      )
    ).toBeInTheDocument();
    expect(del).not.toHaveBeenCalled();
    await user.click(body().getByRole("button", { name: "Remove access" }));
    await waitFor(() => expect(del).toHaveBeenCalledWith("v1/brands/b1/clients/u1"));
    await waitFor(() =>
      expect(capture).toHaveBeenCalledWith(
        "client_lane.client_removed",
        expect.objectContaining({ access_level: "own" })
      )
    );
  });

  it("explains where clients come from when there are none", async () => {
    renderTab([]);
    expect(
      await body().findByText("Clients appear here once you name them in a Request approval.")
    ).toBeInTheDocument();
  });

  it("locks every change for a viewer without settings write", async () => {
    renderTab([dina], false);
    expect(
      await body().findByRole("button", { name: "Access level for Dina Pratiwi: Own requests" })
    ).toBeDisabled();
  });
});
```

Mutations:
- Track `from: next` instead of the row's level, and the first test fails.
- Copy the relative `url`, and "copies the absolute portal link" fails.
- Call `remove.mutate` straight from the menu (no confirm), and "removes access only after the confirm" fails.
- Ignore `canEdit` on the select, and "locks every change" fails.

- [ ] **Step 2: Run it to verify it fails**

Run: `cd WT && bun test src/components/brands/settings/clients/ClientsTab.test.tsx`
Expected: FAIL. `./ClientsTab` is not found.

- [ ] **Step 3: Write the v1 wrappers**

Create `src/components/brands/settings/clients/ClientAvatar.tsx`:

```tsx
"use client";

import { Avatar } from "@/components/frndos/Avatar";
import { getAvatarColor, getInitials } from "@/lib/getInitials";

/** A client's face in the Clients tab — frndOS v1 `Avatar` at the member
 *  rows' size, alone in its file so the v2 tab never imports v1. */
export function ClientAvatar({ name }: { name: string }) {
  return (
    <Avatar
      size="xs"
      initials={getInitials(name)}
      bgColor={getAvatarColor(name)}
      alt={name}
    />
  );
}
```

Create `src/components/brands/settings/clients/ClientRemoveModal.tsx`:

```tsx
"use client";

import type { ReactNode } from "react";

import BaseModal from "@/components/frndos/BaseModal";

/** The "Remove access" confirm — frndOS v1 `BaseModal`. The caller builds
 *  the footer from v2 buttons, so neither file mixes v1 and v2. */
export function ClientRemoveModal({
  isOpen,
  onClose,
  body,
  footer,
}: {
  isOpen: boolean;
  onClose: () => void;
  body: string;
  footer: ReactNode;
}) {
  return (
    <BaseModal
      isOpen={isOpen}
      onClose={onClose}
      title="Remove access?"
      footer={footer}
      showCloseButton
    >
      <p className="px-4 py-5 font-geist text-textSm text-text-inverse-subtle md:px-6">
        {body}
      </p>
    </BaseModal>
  );
}
```

Create `src/components/brands/settings/clients/ClientsEmptyState.tsx`:

```tsx
"use client";

import { UsersThree } from "@phosphor-icons/react";

import { EmptyState } from "@/components/frndos/EmptyState";

/** The empty Clients tab — frndOS v1 `EmptyState`. */
export function ClientsEmptyState({ text }: { text: string }) {
  return <EmptyState icon={<UsersThree size={24} aria-hidden />} title={text} />;
}
```

- [ ] **Step 4: Write `ClientsTab.tsx`**

```tsx
"use client";

import { LinkSimple, UserMinus } from "@phosphor-icons/react";
import { useState } from "react";

import { ActionMenu, Button, SelectMenu } from "@/components/frndos/v2";
import {
  failureReason,
  trackClientAccessChangeFailed,
  trackClientAccessChanged,
  trackClientPortalLinkCopied,
  trackClientPortalLinkCopyFailed,
  trackClientRemoveFailed,
  trackClientRemoved,
} from "@/lib/analytics/client-lane-events";
import {
  CLIENTS_EMPTY_TEXT,
  absolutePortalUrl,
  accessLevelOptions,
  clientAddedLine,
  clientStatusLine,
  filterClients,
  isClientAccessLevel,
  removeConfirmText,
  type BrandClient,
} from "@/lib/client-lane/clients";
import type { ClientAccessLevel } from "@/lib/client-lane/portal/types";
import {
  useBrandClients,
  useClientPortalLink,
  useRemoveBrandClient,
  useUpdateClientAccess,
} from "@/services/brand-clients";
import { approvalApiError } from "@/services/client-lane";
import { useToastStore } from "@/store/useToast";

import { ClientAvatar } from "./ClientAvatar";
import { ClientRemoveModal } from "./ClientRemoveModal";
import { ClientsEmptyState } from "./ClientsEmptyState";

/**
 * Brand Settings → Members → Clients (spec 2026-10-06 portal §7.2): who can
 * open this brand's links, at which access level, whether they opened the
 * portal, and the two verbs — copy their portal link, remove their access.
 * The page owns the flag, the search box and the permission.
 */
export function ClientsTab({
  brandId,
  brandName,
  query,
  canEdit,
}: {
  brandId: string;
  brandName: string;
  query: string;
  canEdit: boolean;
}) {
  const clients = useBrandClients(brandId);
  const update = useUpdateClientAccess(brandId);
  const link = useClientPortalLink(brandId);
  const remove = useRemoveBrandClient(brandId);
  const showToast = useToastStore((s) => s.showToast);
  const [removing, setRemoving] = useState<BrandClient | null>(null);

  const changeLevel = (client: BrandClient, to: ClientAccessLevel) => {
    if (to === client.access_level) return;
    update.mutate(
      { userId: client.user.id, accessLevel: to },
      {
        onSuccess: () => {
          trackClientAccessChanged({
            from: client.access_level,
            to,
            source: "clients_tab",
          });
          showToast("Access updated", `${client.user.name} — new access level saved.`, "success");
        },
        onError: (e) => {
          const err = approvalApiError(e);
          trackClientAccessChangeFailed({
            source: "clients_tab",
            reason: failureReason(err),
            http_status: err.status,
          });
          showToast("Couldn't change access", "Try again in a moment.", "error");
        },
      }
    );
  };

  const copyLink = async (client: BrandClient) => {
    try {
      const url = await link.mutateAsync(client.user.id);
      await navigator.clipboard.writeText(absolutePortalUrl(url, window.location.origin));
      trackClientPortalLinkCopied();
      showToast("Portal link copied", `Send it to ${client.user.name}.`, "success");
    } catch (e) {
      const err = approvalApiError(e);
      trackClientPortalLinkCopyFailed({
        reason: failureReason(err),
        http_status: err.status,
      });
      showToast("Couldn't copy the link", "Try again in a moment.", "error");
    }
  };

  const confirmRemove = async () => {
    if (!removing) return;
    const client = removing;
    try {
      await remove.mutateAsync(client.user.id);
      trackClientRemoved({ access_level: client.access_level });
      showToast("Access removed", `${client.user.name} can no longer open ${brandName} links.`, "success");
      setRemoving(null);
    } catch (e) {
      const err = approvalApiError(e);
      trackClientRemoveFailed({ reason: failureReason(err), http_status: err.status });
      showToast("Couldn't remove access", "Try again in a moment.", "error");
    }
  };

  if (clients.isLoading) {
    return (
      <div className="font-geist text-textSm text-text-inverse-subtle">Loading…</div>
    );
  }
  if (clients.isError) {
    return (
      <div className="flex flex-col items-start gap-2 font-geist">
        <p className="text-textSm text-text-inverse-subtle">Couldn&apos;t load clients.</p>
        <Button variant="secondary" size="small" onClick={() => void clients.refetch()}>
          Try again
        </Button>
      </div>
    );
  }

  const rows = clients.data ?? [];
  if (rows.length === 0) return <ClientsEmptyState text={CLIENTS_EMPTY_TEXT} />;
  const shown = filterClients(rows, query);

  return (
    <>
      <div className="flex flex-col divide-y divide-border-default rounded-xl border border-border-default">
        {shown.length === 0 ? (
          <div className="px-4 py-8 text-center font-geist text-textSm text-text-inverse-subtle">
            {`No clients match "${query.trim()}".`}
          </div>
        ) : (
          shown.map((client) => (
            <div key={client.user.id} className="flex items-center justify-between gap-4 px-4 py-3">
              <div className="flex min-w-0 flex-1 items-center gap-3">
                <ClientAvatar name={client.user.name} />
                <div className="flex min-w-0 flex-col">
                  <span className="truncate font-geist text-textSmMedium text-text-inverse-default">
                    {client.user.name}
                  </span>
                  <span className="truncate font-geist text-textXs text-text-inverse-subtlest">
                    {client.user.email}
                  </span>
                </div>
              </div>
              <div className="hidden shrink-0 flex-col items-end font-geist text-textXs md:flex">
                <span className="text-text-inverse-subtle">{clientStatusLine(client)}</span>
                <span className="text-text-inverse-subtlest">{clientAddedLine(client)}</span>
              </div>
              <SelectMenu
                ariaLabel={`Access level for ${client.user.name}`}
                options={accessLevelOptions()}
                value={client.access_level}
                disabled={!canEdit || update.isPending}
                onChange={(next) => {
                  if (isClientAccessLevel(next)) changeLevel(client, next);
                }}
              />
              <ActionMenu
                ariaLabel={`Actions for ${client.user.name}`}
                items={[
                  {
                    id: "copy",
                    label: "Copy portal link",
                    icon: <LinkSimple size={14} aria-hidden />,
                    disabled: !canEdit,
                    onSelect: () => void copyLink(client),
                  },
                  {
                    id: "remove",
                    label: "Remove access",
                    icon: <UserMinus size={14} aria-hidden />,
                    tone: "danger",
                    disabled: !canEdit,
                    onSelect: () => setRemoving(client),
                  },
                ]}
              />
            </div>
          ))
        )}
      </div>
      <ClientRemoveModal
        isOpen={removing !== null}
        onClose={() => setRemoving(null)}
        body={removing ? removeConfirmText(removing.user.name, brandName) : ""}
        footer={
          <div className="flex items-center justify-end gap-2 border-t border-border-default px-4 py-4 md:px-6">
            <Button variant="secondary" size="small" onClick={() => setRemoving(null)}>
              Cancel
            </Button>
            <Button
              variant="alertPrimary"
              size="small"
              loading={remove.isPending}
              disabled={remove.isPending}
              onClick={() => void confirmRemove()}
            >
              Remove access
            </Button>
          </div>
        }
      />
    </>
  );
}
```

`SelectMenu`'s disabled trigger renders without the caret. That matches `SelectMenu`'s documented "shown but inert" state.

- [ ] **Step 5: Mount the tab in the Members page (hand-formatted)**

In `src/app/(dashboard)/brands/[id]/settings/members/page.tsx`:

Add after `import { getWorkspaceMembers } from "@/services/query";`:

```tsx
import { ClientsTab } from "@/components/brands/settings/clients/ClientsTab";
import { useBrandDetail } from "@/hooks/useBrandBook";
import { usePermissions } from "@/hooks/usePermissions";
import { clientsTabLabel } from "@/lib/client-lane/clients";
import { useClientLaneEnabled } from "@/lib/featureFlags";
import { useBrandClients } from "@/services/brand-clients";
```

Replace `  const [activeTab, setActiveTab] = useState<"admins" | "members">("members");` with

```tsx
  const [activeTab, setActiveTab] = useState<"admins" | "members" | "clients">("members");
```

Add after `  const removeMemberMutation = useRemoveBrandMember(brandId);`:

```tsx
  // Client portal (spec 2026-10-06 portal §7.2) — agency side behind show-client-lane.
  const clientLane = useClientLaneEnabled();
  const clientsQuery = useBrandClients(brandId, { enabled: clientLane });
  const { canWriteForBrand } = usePermissions();
  const brandDetail = useBrandDetail(brandId, clientLane);
  const brandName =
    (brandDetail.data as { data?: { name?: string } } | undefined)?.data?.name ?? "this brand";
```

In the `PillTabs` `tabs={[ … ]}` array, after the "Workspace Admins" entry's closing `},`, add:

```tsx
                  ...(clientLane
                    ? [
                        {
                          label: clientsTabLabel(clientsQuery.data?.length),
                          active: activeTab === "clients",
                          onClick: () => { setActiveTab("clients"); setSearchQuery(""); },
                        },
                      ]
                    : []),
```

Replace the search placeholder `placeholder={activeTab === "members" ? "Search members…" : "Search admins…"}` with

```tsx
                placeholder={
                  activeTab === "members"
                    ? "Search members…"
                    : activeTab === "clients"
                      ? "Search clients…"
                      : "Search admins…"
                }
```

Replace `            {activeTab === "admins" ? (` (the "Tab content" ternary) with

```tsx
            {activeTab === "clients" && clientLane ? (
              <ClientsTab
                brandId={brandId}
                brandName={brandName}
                query={searchQuery}
                canEdit={canWriteForBrand("brand.settings", brandId)}
              />
            ) : activeTab === "admins" ? (
```

The members and admins branches are unchanged. If the flag flips off while the Clients tab is open, the members list shows.

- [ ] **Step 6: Run the test, then prove each named mutation**

Run: `cd WT && bun test src/components/brands/settings/clients/ClientsTab.test.tsx`
Expected: PASS, with no `error` line.
- If the access-level trigger's name differs, read `SelectMenu`. Its name is `${ariaLabel}: ${shown}`.
- If the confirm button name collides with the menu item, scope the query with `within(body().getByRole("dialog"))`.

Apply each mutation, watch its test fail, and restore.

- [ ] **Step 7: Lint, format, commit**

```bash
cd WT && F=(src/components/brands/settings/clients/ClientAvatar.tsx src/components/brands/settings/clients/ClientRemoveModal.tsx src/components/brands/settings/clients/ClientsEmptyState.tsx src/components/brands/settings/clients/ClientsTab.tsx src/components/brands/settings/clients/ClientsTab.test.tsx) && ./node_modules/.bin/prettier --write "${F[@]}" && ./node_modules/.bin/eslint "${F[@]}" "src/app/(dashboard)/brands/[id]/settings/members/page.tsx" && /usr/bin/git add "${F[@]}" "src/app/(dashboard)/brands/[id]/settings/members/page.tsx" && /usr/bin/git commit -F - <<'EOF'
feat(web): Clients tab in Brand Settings → Members (behind show-client-lane)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---
### Task 17: The approver picker suggests clients (bug 2)

**Files:**
- Modify: `src/components/client-lane/agency/useApproverEmails.ts`
- Modify: `src/components/client-lane/agency/ApproverEmailsField.tsx`
- Test: `src/components/client-lane/agency/ApproverEmailsField.test.tsx`
- Modify: `src/components/client-lane/agency/RequestForm.tsx` (one line: the hook call)
- Modify: `src/components/client-lane/agency/RequestApprovalPanel.tsx` (one line: the hook call in `useApprovalRequestForm`)

**Interfaces:**
- Consumes: Task 15 `useApproverSuggestions`, `useUpdateClientAccess`, `approverChipTag`, `viewOnlyPicks`, `pickableSuggestions`, `ApproverSuggestion`; Task 9 `trackApproverSuggestionPicked`, `trackClientAccessChanged`, `trackClientAccessChangeFailed`; `approvalApiError`; v2 `Chip`, `ItemRow` (for `ItemRow.Tag`), `Button`.
- Produces: `useApproverEmails(subject: { type: ShareSubjectType; id: string; brandId?: string | null } | null, initial?)`. It returns, in addition to what it returned before:
  - `subject`;
  - `allSuggestions: ApproverSuggestion[]`;
  - `suggestionsReady: boolean`;
  - `suggestions: ApproverSuggestion[]`, which now means pickable ones only.

  `ApproverEmailsField` keeps its props (`approvers`, `disabled`). Everything new comes through `approvers`, so no host changes beyond the hook argument.

Bug 2 (spec §1): the old hook read `GET brands/{id}/members`, which excludes clients and needs settings permission, so it could never suggest a client. The new endpoint uses the send permission.

Spec §7.3 and §9:
- a picked `all_view` client's chip reads "view only";
- a new address reads "New client" (v2 `Chip` + `ItemRow.Tag`);
- an inline v2 `Button variant="text"` "Change to All requests + approve?" PATCHes the level;
- a picked suggestion fires `approver_suggestion_picked`.

- [ ] **Step 1: Write the failing test**

Create `src/components/client-lane/agency/ApproverEmailsField.test.tsx`:

```tsx
import "@testing-library/jest-dom/vitest";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import posthog from "posthog-js";
import { useState, type ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import type { ApproverSuggestion } from "@/lib/client-lane/approverSuggestions";
import axiosInstance from "@/services/axios";

import { ApproverEmailsField } from "./ApproverEmailsField";
import { useApproverEmails } from "./useApproverEmails";

const body = () => within(document.body);

const dina: ApproverSuggestion = {
  user_id: "u1",
  name: "Dina",
  email: "dina@tokopedia.com",
  access_level: "all_view",
};

function QueryWrapper({ children }: { children: ReactNode }) {
  const [client] = useState(
    () => new QueryClient({ defaultOptions: { queries: { retry: false } } })
  );
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

/** A real hook behind the field — the same pairing every host uses. */
function Harness() {
  const approvers = useApproverEmails({ type: "deck", id: "d1", brandId: "b1" });
  return <ApproverEmailsField approvers={approvers} />;
}

describe("approver picker (spec §7.3)", () => {
  beforeEach(() => vi.restoreAllMocks());

  it("suggests a brand's clients from the suggestions endpoint", async () => {
    const get = vi
      .spyOn(axiosInstance, "get")
      .mockResolvedValue({ data: { data: [dina] } } as never);
    render(<Harness />, { wrapper: QueryWrapper });
    expect(await body().findByRole("button", { name: "+ Dina" })).toBeInTheDocument();
    expect(get).toHaveBeenCalledWith("v1/approval-requests/approver-suggestions", {
      params: { subject_type: "deck", subject_id: "d1" },
    });
  });

  it("tags a picked view-only client and offers the upgrade", async () => {
    const user = userEvent.setup();
    vi.spyOn(axiosInstance, "get").mockResolvedValue({ data: { data: [dina] } } as never);
    const patch = vi
      .spyOn(axiosInstance, "patch")
      .mockResolvedValue({ data: { data: {} } } as never);
    const capture = vi
      .spyOn(posthog, "capture")
      .mockImplementation(() => undefined as never);
    render(<Harness />, { wrapper: QueryWrapper });
    await user.click(await body().findByRole("button", { name: "+ Dina" }));
    expect(body().getByText("view only")).toBeInTheDocument();
    expect(capture).toHaveBeenCalledWith(
      "client_lane.approver_suggestion_picked",
      expect.objectContaining({ subject_type: "deck", access_level: "all_view" })
    );
    await user.click(
      body().getByRole("button", { name: "Change to All requests + approve?" })
    );
    await waitFor(() =>
      expect(patch).toHaveBeenCalledWith("v1/brands/b1/clients/u1", {
        access_level: "all_approve",
      })
    );
    await waitFor(() =>
      expect(capture).toHaveBeenCalledWith(
        "client_lane.client_access_changed",
        expect.objectContaining({
          from: "all_view",
          to: "all_approve",
          source: "approver_picker",
        })
      )
    );
  });

  it("tags an address that is not a client yet", async () => {
    const user = userEvent.setup();
    vi.spyOn(axiosInstance, "get").mockResolvedValue({ data: { data: [dina] } } as never);
    render(<Harness />, { wrapper: QueryWrapper });
    await body().findByRole("button", { name: "+ Dina" });
    await user.type(body().getByRole("textbox", { name: "Approver email" }), "new@brand.co{Enter}");
    expect(body().getByText("New client")).toBeInTheDocument();
  });
});
```

Mutations:
- Keep `useBrandMembers` as the source, and "suggests a brand's clients…" fails (wrong URL).
- Drop the tag render, and "tags a picked view-only client" fails.
- PATCH `all_view` → `own`, and the PATCH assertion fails.
- Use `approverChipTag(email, suggestions, …)` with the PICKABLE list. Dina is then removed once picked, so the tag turns into "New client" and "tags a picked view-only client" fails. That is the reason `allSuggestions` exists.

- [ ] **Step 2: Run it to verify it fails**

Run: `cd WT && bun test src/components/client-lane/agency/ApproverEmailsField.test.tsx`
Expected: FAIL. The hook still calls the members endpoint, and nothing renders "+ Dina".

- [ ] **Step 3: Rewrite the hook's source of suggestions**

In `src/components/client-lane/agency/useApproverEmails.ts`:
- Remove `import { useBrandMembers } from "@/hooks/useBrandRoles";`, the `ApproverSuggestion` interface and the `BrandMemberRow` interface.
- Add:

```ts
import {
  pickableSuggestions,
  type ApproverSuggestion,
} from "@/lib/client-lane/approverSuggestions";
import type { ShareSubjectType } from "@/lib/client-lane/types";
import { useApproverSuggestions } from "@/services/brand-clients";

export type { ApproverSuggestion };

/** What the picker is for — the suggestions endpoint is keyed by subject. */
export interface ApproverSubject {
  type: ShareSubjectType;
  id: string;
  /** The subject's brand — needed only for the inline access upgrade. */
  brandId?: string | null;
}
```

- Change the signature to:

```ts
export function useApproverEmails(
  subject: ApproverSubject | null,
  /** Prefilled approvers (the top-bar form carries the last request's). */
  initial?: readonly string[]
) {
```

- Replace the block from `// Existing clients of the brand (the locked \`client\` role).` through the end of the `suggestions` `useMemo` with:

```ts
  // The brand's clients, from the suggestions endpoint (spec 2026-10-06
  // portal §7.3) — same permission as sending a request. The old source,
  // `GET brands/{id}/members`, excluded clients and needed settings
  // permission, so it could never suggest one (bug 2).
  const suggestionsQuery = useApproverSuggestions(
    subject ? { type: subject.type, id: subject.id } : null
  );
  const allSuggestions = useMemo<ApproverSuggestion[]>(
    () => suggestionsQuery.data ?? [],
    [suggestionsQuery.data]
  );
  const suggestions = useMemo(
    () => pickableSuggestions(allSuggestions, emails),
    [allSuggestions, emails]
  );
```

- Add to the returned object: `subject`, `allSuggestions`, and `suggestionsReady: suggestionsQuery.isSuccess`.
- Update the doc comment: "plus the brand's clients as one-tap suggestions (`GET v1/approval-requests/approver-suggestions`)".

In `src/components/client-lane/agency/RequestForm.tsx`, replace `const approvers = useApproverEmails(brandId, initialEmails);` with

```ts
  const approvers = useApproverEmails(
    { type: subject.type, id: subject.id, brandId },
    initialEmails
  );
```

In `src/components/client-lane/agency/RequestApprovalPanel.tsx` (inside `useApprovalRequestForm`), replace `const approvers = useApproverEmails(brandId);` with

```ts
  const approvers = useApproverEmails({ type: subjectType, id: subjectId, brandId });
```

- [ ] **Step 4: Tags, the upgrade and the pick event in the field**

Rewrite `src/components/client-lane/agency/ApproverEmailsField.tsx`. It keeps its `FIELD` class, its input and its help text unchanged, and adds:

```tsx
"use client";

import clsx from "clsx";
import { useId } from "react";

import { Button, Chip, ItemRow } from "@/components/frndos/v2";
import {
  failureReason,
  trackApproverSuggestionPicked,
  trackClientAccessChangeFailed,
  trackClientAccessChanged,
} from "@/lib/analytics/client-lane-events";
import {
  approverChipTag,
  viewOnlyPicks,
  type ApproverSuggestion,
} from "@/lib/client-lane/approverSuggestions";
import { useUpdateClientAccess } from "@/services/brand-clients";
import { approvalApiError } from "@/services/client-lane";
import { useToastStore } from "@/store/useToast";

import type { ApproverEmails } from "./useApproverEmails";

/** frndOS has no v2 text input yet; this is the v2 field recipe (glass
 *  fill, white/10 border, ring on keyboard focus, no forms-plugin ring). */
const FIELD =
  "h-10 w-full rounded-xl border border-white/10 bg-white/5 px-3 font-geist text-textSm text-text-inverse outline-none transition-all duration-200 ease-out placeholder:text-text-inverse-subtlest focus:border-white/20 focus:ring-0 focus-visible:ring-2 focus-visible:ring-white/40 disabled:cursor-not-allowed disabled:opacity-50";

/**
 * The approvers of a request: committed emails as v2 `Chip`s — tagged
 * "view only" (an `all_view` client cannot decide) or "New client" (spec
 * 2026-10-06 portal §7.3) — the input (Enter / comma / space / blur commits,
 * Backspace on empty removes the last), the brand's clients as one-tap
 * suggestions, and an inline upgrade for a picked view-only client.
 */
export function ApproverEmailsField({
  approvers,
  disabled,
}: {
  approvers: ApproverEmails;
  disabled?: boolean;
}) {
  const helpId = useId();
  const showToast = useToastStore((s) => s.showToast);
  const brandId = approvers.subject?.brandId ?? "";
  const update = useUpdateClientAccess(brandId);
  const upgradeable = viewOnlyPicks(approvers.emails, approvers.allSuggestions);

  const pick = (s: ApproverSuggestion) => {
    if (!approvers.add(s.email)) return;
    if (approvers.subject) {
      trackApproverSuggestionPicked({
        subject_type: approvers.subject.type,
        access_level: s.access_level,
      });
    }
  };

  const upgrade = (s: ApproverSuggestion) => {
    if (!brandId) return;
    update.mutate(
      { userId: s.user_id, accessLevel: "all_approve" },
      {
        onSuccess: () => {
          trackClientAccessChanged({
            from: s.access_level,
            to: "all_approve",
            source: "approver_picker",
          });
          showToast(
            "Access updated",
            `${s.name ?? s.email} can now approve every request.`,
            "success"
          );
        },
        onError: (e) => {
          const err = approvalApiError(e);
          trackClientAccessChangeFailed({
            source: "approver_picker",
            reason: failureReason(err),
            http_status: err.status,
          });
          showToast("Couldn't change access", "Try again in a moment.", "error");
        },
      }
    );
  };

  return (
    <div className="flex flex-col gap-2">
      {approvers.emails.length > 0 && (
        <ul className="flex flex-wrap gap-1.5">
          {approvers.emails.map((email) => {
            const tag = approverChipTag(
              email,
              approvers.allSuggestions,
              approvers.suggestionsReady
            );
            return (
              <li key={email} className="flex max-w-full items-center gap-1">
                <Chip
                  label={email}
                  disabled={disabled}
                  onRemove={() => approvers.remove(email)}
                />
                {tag ? <ItemRow.Tag>{tag}</ItemRow.Tag> : null}
              </li>
            );
          })}
        </ul>
      )}
      {upgradeable.map((s) => (
        <p
          key={s.user_id}
          className="flex flex-wrap items-center gap-1 font-geist text-textXs text-text-inverse-subtle"
        >
          {`${s.name ?? s.email} can only view requests.`}
          <Button
            type="button"
            variant="text"
            size="tiny"
            disabled={disabled || !brandId || update.isPending}
            onClick={() => upgrade(s)}
          >
            Change to All requests + approve?
          </Button>
        </p>
      ))}
      <input
        type="email"
        aria-label="Approver email"
        aria-describedby={helpId}
        aria-invalid={Boolean(approvers.error)}
        className={FIELD}
        value={approvers.draft}
        disabled={disabled}
        placeholder="dina@brand.co.id — Enter to add"
        onChange={(e) => {
          approvers.setDraft(e.target.value);
          if (approvers.error) approvers.setError(null);
        }}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === "," || e.key === " ") {
            e.preventDefault();
            approvers.add(approvers.draft);
          }
          if (
            e.key === "Backspace" &&
            !approvers.draft &&
            approvers.emails.length > 0
          ) {
            approvers.pop();
          }
        }}
        onBlur={() => {
          if (approvers.draft.trim()) approvers.add(approvers.draft);
        }}
      />
      <p
        id={helpId}
        className={clsx(
          "font-geist text-textXs",
          approvers.error ? "text-negative-400" : "text-text-inverse-subtlest"
        )}
      >
        {approvers.error ??
          (approvers.emails.length === 0
            ? "No names: anyone with the link can decide. Named approvers get a personal link by email."
            : "Each named approver gets their own link by email.")}
      </p>
      {approvers.suggestions.length > 0 && (
        <div className="flex flex-wrap gap-1">
          {approvers.suggestions.map((s) => (
            <Button
              key={s.user_id}
              type="button"
              variant="text"
              size="tiny"
              disabled={disabled}
              onClick={() => pick(s)}
            >
              + {s.name ?? s.email}
            </Button>
          ))}
        </div>
      )}
    </div>
  );
}
```

The `<input>` and the help `<p>` are the base file's, unchanged; diff against BASE to confirm. The suggestion buttons are keyed by `s.user_id` now, where they used `m.id`. `approvers.add` returns `boolean`, so a pick that fails validation fires no event.

- [ ] **Step 5: Run the test and the agency suites, then prove each named mutation**

```bash
cd WT && for f in src/components/client-lane/agency/ApproverEmailsField.test.tsx src/components/client-lane/agency/ApprovalStatusBlock.test.tsx src/components/client-lane/agency/RequestLinkRow.test.tsx src/components/studio/kv-generator/KvSharePanel.test.tsx src/components/brands/campaign-planner/SharePlanDialog.test.tsx; do echo "== $f"; [ -f "$f" ] || { echo MISSING; continue; }; bun test "$f" 2>&1 | /usr/bin/grep -E "^[[:space:]]*[0-9]+ (pass|fail)|^\(fail\)|[0-9]+ error"; done
cd WT && /usr/bin/grep -rn "useApproverEmails(" src | /usr/bin/grep -v "useApproverEmails.ts"
```

Expected:
- the new file shows `0 fail`;
- the others show exactly their Task 0 lists. `KvSharePanel` mounts the request form; if a new GET to `approver-suggestions` hits a URL-keyed stub that throws, extend that suite's stub only if the failure is NEW, and record it;
- the grep lists only the two updated call sites and the test harness.

Apply each mutation, watch its test fail, and restore.

- [ ] **Step 6: Lint, format, commit**

```bash
cd WT && F=(src/components/client-lane/agency/useApproverEmails.ts src/components/client-lane/agency/ApproverEmailsField.tsx src/components/client-lane/agency/ApproverEmailsField.test.tsx src/components/client-lane/agency/RequestForm.tsx src/components/client-lane/agency/RequestApprovalPanel.tsx) && ./node_modules/.bin/prettier --write src/components/client-lane/agency/ApproverEmailsField.test.tsx && ./node_modules/.bin/eslint "${F[@]}" && /usr/bin/git add "${F[@]}" && /usr/bin/git commit -F - <<'EOF'
fix(web): approver picker suggests the brand's clients, tags view-only and new clients

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

## Phase 5 — light mode, gates, handover

### Task 18: Light-mode token pass for every surface this feature adds

**Files:**
- Modify: `src/lib/client-lane/tokenHygiene.test.ts` (the `FILES` list only)

**Interfaces:**
- Consumes: every file created or changed in Tasks 10–17.
- Produces: a banned-class scan that fails on `text-white`, an arbitrary `white/[0.x]`, a pixel font size or a hex in any of them.

- [ ] **Step 1: Extend the scan (it should fail on purpose first)**

In `src/lib/client-lane/tokenHygiene.test.ts`, append to `FILES`:

```ts
  // Client portal (spec 2026-10-06 portal §9) — public, dark-scoped.
  "src/components/client-lane/portal/PortalFrame.tsx",
  "src/components/client-lane/portal/PortalHeader.tsx",
  "src/components/client-lane/portal/PortalNav.tsx",
  "src/components/client-lane/portal/PortalViewOnlyNotice.tsx",
  "src/components/client-lane/portal/PortalEmptyState.tsx",
  "src/components/client-lane/portal/WaitingCard.tsx",
  "src/components/client-lane/portal/PortalApprovals.tsx",
  "src/components/client-lane/portal/PortalApp.tsx",
  "src/components/client-lane/portal/PortalEmailField.tsx",
  "src/components/client-lane/portal/PortalSignIn.tsx",
  "src/components/client-lane/portal/LaneExchange.tsx",
  // Agency side (§7.2, §7.3) — must read right in Midnight, Aurora, Daylight.
  "src/components/brands/settings/clients/ClientsTab.tsx",
  "src/components/brands/settings/clients/ClientAvatar.tsx",
  "src/components/brands/settings/clients/ClientRemoveModal.tsx",
  "src/components/brands/settings/clients/ClientsEmptyState.tsx",
  "src/components/client-lane/agency/ApproverEmailsField.tsx",
```

Before running, prove the scan bites: add `text-white` to `PortalNav.tsx`'s span temporarily.

- [ ] **Step 2: Run it — FAIL, then restore and PASS**

Run: `cd WT && bun test src/lib/client-lane/tokenHygiene.test.ts`
Expected: FAIL on `PortalNav.tsx uses theme tokens only` with `["text-white"]`. Remove the temporary class and run again. Expected: PASS for every file.
- A real hit in a new file is a bug: replace it with a token (Global Constraints) and re-run.
- `ApproverList.tsx` and `DecisionPage.tsx` stay OUT of the list: their legacy classes predate this plan, and Task 19's added-lines scan covers what this plan wrote there.

- [ ] **Step 3: Daylight / Aurora render check of the agency surfaces (Daffa or the executor with the browser pane)**

Start `cd WT && bun dev`, signed in, flag on (dev/staging is always on). Open Brand Settings → Members → Clients and a Request-approval form, then switch theme (profile menu → Miscellaneous → Theme) through Midnight, Aurora and Daylight. Check:
- row text, dividers and borders;
- the access-level `SelectMenu` trigger and its popup;
- the "…" `ActionMenu`;
- the Remove confirm (`BaseModal` + red `alertPrimary`; `text-fixed-white` comes from the v2 Button itself);
- the empty state;
- the "view only" / "New client" tags and the inline upgrade line.

Record ✓/✗ per theme in the track. Then run `cd WT && bun run theme:patches:check`. Expected: clean, since this plan adds no hex.

- [ ] **Step 4: Commit**

```bash
cd WT && /usr/bin/git add src/lib/client-lane/tokenHygiene.test.ts docs/tracks/client-portal.track.md && /usr/bin/git commit -F - <<'EOF'
test(web): token scan covers the client portal and the Clients tab

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

---

### Task 19: Gates, manual pass, Lark rows, contract notes, track

**Files:**
- Modify: `docs/tracks/client-portal.track.md`
- Modify: `docs/prd/client-lane-p0a/web.md` (ONLY its `## Contract` section, copied from the api branch)

**Interfaces:**
- Consumes: everything above.
- Produces: a branch ready for review (not pushed, no PR).

- [ ] **Step 1: Analytics completeness (memory: PostHog events are part of the feature)**

Load `frndos-analytics-events` and walk every interaction this plan adds:
- view inbox, switch brand, open item;
- request code, verify, fail, sign out;
- change level, copy link, remove;
- pick suggestion, upgrade.

Then:

```bash
cd WT && /usr/bin/grep -rn "posthog.capture" src/components/client-lane/portal src/components/brands/settings/clients src/components/client-lane/agency/ApproverEmailsField.tsx || echo "no inline captures"
cd WT && /usr/bin/grep -rn "session_token\|frnd_client" src/components src/services | /usr/bin/grep -v "\.test\." || echo "no token or cookie name in client code"
```

Expected: `no inline captures`, and `no token or cookie name in client code`. The cookie name may appear only under `src/lib/client-lane/` (route-handler helpers), `src/middleware.ts` and `src/app/s/**`.

- [ ] **Step 2: Types, lint, tests, build**

```bash
cd WT && ./node_modules/.bin/tsc --noEmit -p . 2>&1 | /usr/bin/grep -c "error TS"
cd WT && /usr/bin/git diff --name-only "$BASE" -- src | /usr/bin/grep -E "\.(ts|tsx)$" > /tmp/client-portal-touched.txt; ./node_modules/.bin/tsc --noEmit -p . 2>&1 | /usr/bin/grep -F -f /tmp/client-portal-touched.txt
cd WT && ./node_modules/.bin/eslint $(cat /tmp/client-portal-touched.txt)
cd WT && /usr/bin/git diff -w "$BASE" -U0 -- src | /usr/bin/grep -E "^\+" | /usr/bin/grep -nE "\btext-white\b|white/\[0?\.[0-9]+\]|text-\[[0-9]+px\]|#[0-9a-fA-F]{6}\b" || echo "no banned classes on added lines"
```

Expected:
- the first count is ≤ the Task 0 baseline;
- the second prints only lines listed as baseline in the track;
- eslint reports 0 errors and no new warnings on changed lines;
- `no banned classes on added lines`. `-w` ignores the header block that Task 14 only re-indented.

Every client-lane file runs one per invocation: the Task 0 list plus every new test.

```bash
cd WT && F=(src/lib/client-lane/portal/inbox.test.ts src/lib/client-lane/portal/shell.test.ts src/lib/client-lane/statusTone.approver.test.ts src/lib/client-lane/portal/signIn.test.ts src/lib/client-lane/cookie.session.test.ts src/middleware.portal.test.ts src/lib/client-lane/portal/proxy.test.ts src/lib/client-lane/publicApi.transport.test.ts src/lib/client-lane/portal/sessionRoutes.test.ts src/lib/client-lane/portal/me.test.ts src/services/client-portal.test.ts src/lib/analytics/client-lane-events.portal.test.ts src/components/client-lane/portal/PortalHeader.test.tsx src/components/client-lane/portal/PortalApp.test.tsx src/components/client-lane/portal/PortalSignIn.test.tsx src/components/client-lane/portal/LaneExchange.test.tsx src/components/client-lane/DecisionPage.portal.test.tsx src/lib/client-lane/clients.test.ts src/lib/client-lane/approverSuggestions.test.ts src/services/brand-clients.test.ts src/components/brands/settings/clients/ClientsTab.test.tsx src/components/client-lane/agency/ApproverEmailsField.test.tsx src/lib/client-lane/tokenHygiene.test.ts src/lib/client-lane/round.test.ts src/lib/client-lane/pins.test.ts src/lib/client-lane/versionLabels.test.ts src/lib/client-lane/commentThreads.test.ts src/lib/client-lane/canvasApproval.test.ts src/lib/client-lane/subjectRequests.test.ts src/lib/client-lane/drain.test.ts src/lib/client-lane/planDecisions.test.ts src/lib/client-lane/requestDecision.test.ts src/lib/client-lane/recordPdf.test.ts src/lib/client-lane/requestRefresh.test.ts src/lib/client-lane/advisoryAnswer.test.ts src/services/client-lane.test.ts src/components/client-lane/DecisionPage.test.tsx src/components/client-lane/PinLayer.test.tsx src/components/client-lane/PinNotePopover.test.tsx src/components/client-lane/agency/ApprovalStatusBlock.test.tsx src/components/client-lane/agency/RequestLinkRow.test.tsx src/components/client-lane/agency/useArtboardThumbnailSync.test.ts src/components/client-lane/kv/KvLinkGallery.test.tsx src/components/client-lane/kv/KvRequestHero.test.tsx src/components/client-lane/kv/KvRoundHero.test.tsx src/components/client-lane/kv/KvShareBoardCanvas.test.tsx src/components/client-lane/kv/roundItems.test.ts src/components/client-lane/kv/swipe.test.ts src/middleware.kvShare.test.ts src/middleware.mobile.test.ts src/middleware.studio.test.ts src/lib/theme.test.ts src/components/frndos/v2/ActionMenu.test.tsx src/components/frndos/v2/ActionMenu.modal.test.tsx src/components/frndos/v2/SelectMenu.test.tsx src/components/frndos/v2/ItemRow.test.tsx); for f in "${F[@]}"; do echo "== $f"; [ -f "$f" ] || { echo MISSING; continue; }; bun test "$f" 2>&1 | /usr/bin/grep -E "^[[:space:]]*[0-9]+ (pass|fail)|^\(fail\)|[0-9]+ error"; done
cd WT && for f in $(/usr/bin/git diff --name-only "$BASE" -- 'src/**/*.test.ts' 'src/**/*.test.tsx'); do printf "%s " "$f"; wc -c < "$f"; done
```

Expected:
- every new file: `0 fail`, no `error` line;
- every old file: exactly its Task 0 failure list (`MISSING` only for files Task 0 recorded as missing);
- every changed test file < 45 000 bytes.

Also run the new component suites together once, to catch bun's process-global mock collisions (memory):

```bash
cd WT && bun test src/components/client-lane/portal/PortalHeader.test.tsx src/components/client-lane/portal/PortalApp.test.tsx src/components/client-lane/portal/PortalSignIn.test.tsx src/components/client-lane/DecisionPage.portal.test.tsx 2>&1 | /usr/bin/grep -E "^[[:space:]]*[0-9]+ (pass|fail)|^\(fail\)|[0-9]+ error"
```

Expected: the same pass count as the four separate runs. No new suite registers a module mock, so a difference means a shared spy was not restored.

Build with node:

```bash
cd WT && node ./node_modules/next/dist/bin/next build 2>&1 | tail -40
```

Expected: the route table lists the ten `/s` routes from Task 13, Step 5, and there is no `Failed to compile` / module-not-found.

- [ ] **Step 3: Security review (spec §8.1)**

Run the `security-review` skill on this branch's diff against `BASE`. Hand it the threat list:
- token never in JS: proxy strip, routes, no prop;
- BFF CSRF (Sec-Fetch-Site / Origin) and the path allowlist;
- cookie attributes;
- enumeration-safe sign-in (identical screen, constant 202);
- `?k=` exchange only by POST;
- sign-out clears both cookies;
- header forwarding (no cookie / authorization upstream).

Record the summary in the track. Any high or critical finding blocks the PR.

- [ ] **Step 4: Manual pass (Daffa — spec §8.3; laptop + phone)**

Setup:
- The api branch `feature/daffa/vc-client-portal` runs on :9191 with its migrations applied, and deploys first (spec §8.2).
- In `web/`, stop the dev server, then run `cd WT && bun dev` on :3000.
- The phone opens links via the laptop's LAN IP or a tunnel.

Record each line ✓/✗ in the track.

1. **Personal link → portal.**
   - Open `/s/{ws}/{brand}?k=…` on the laptop: the URL is cleaned, "Opening your approvals…" shows, then the inbox.
   - DevTools → Application → Cookies: `frnd_client` is HttpOnly with Path `/s`.
   - Network: no response body contains the token.
2. **Two devices.**
   - Phone: open the same brand's portal URL without `?k=`, and get the sign-in screen.
   - Request a code, enter it, and get the inbox.
   - Laptop: "Sign out this device". The laptop is signed out; the phone is still in.
3. **Multi-brand client.** Name the same email as an approver in a second brand in a SECOND workspace, then open that brand's personal link.
   - Neither cookie overwrites the other (one `frnd_client`).
   - The switcher lists both brands with their waiting counts, and switching works.
4. **Access levels** (change them in the Clients tab between steps):
   - `own` shows only requests naming the client.
   - `all_approve` shows every request; Waiting-on-others rows read "Waiting on Andi" for requests not naming them.
   - `all_view`:
     - the notice appears at the top;
     - a request link shows the view-only notice in place of every Approve / Request-changes control, KV cards included;
     - pins can still be placed.
5. **Review page with a session.**
   - The portal header, "← Approvals" and "Deciding as {name}" appear.
   - The approver list reads Not opened / Opened / Decided, and "Opened" flips after another approver opens the link.
   - Without a session (private window) the page is exactly as before.
6. **Request-link code (Part D) still works.**
   - On a fresh device, decide on a request link: the code sheet appears, and the decision lands.
   - `frnd_client` is now set too.
   - Reload: the portal header appears.
7. **Remove while the portal is open.** Remove the client in the Clients tab. Within one refetch (focus the portal tab), the portal falls back to the sign-in screen with no "removed" wording.
8. **Enumeration.**
   - `/s/nope/nothing` shows the same sign-in screen.
   - Requesting a code for an unknown email still says "We sent a 6-digit code to …".
9. **Phone width (375px).**
   - The header shows the switcher and "•••" (the name is hidden), with 16px gutters and no horizontal scroll.
   - The cards stack, and "Review" is reachable.
   - The sign-in boxes fit.
10. **Clients tab.**
    - "Clients (n)" shows only with the flag.
    - It shows the level, status, added line and empty state.
    - Copy portal link pastes an absolute URL that opens the portal.
    - Remove confirms with the spec's sentence.
    - Check all of it in Midnight, Aurora and Daylight (Task 18, Step 3).
11. **Approver picker.**
    - The brand's clients appear as "+ Name".
    - A view-only pick reads "view only", and "Change to All requests + approve?" upgrades it; the Clients tab shows the new level.
    - A new address reads "New client".
12. **PostHog Live Events (signed in, local).** Every event from Task 9 fires once per gesture. `portal_viewed` fires once per brand view, not on refetch. No public event carries a name, email, slug or token.

- [ ] **Step 5: Lark taxonomy rows (Daffa — needs a signed-in session)**

List these in the track under "PENDING (human)", all new:

| Event | Props |
|---|---|
| `client_lane.portal_viewed` | `access_level`, `waiting_on_you` |
| `client_lane.portal_brand_switched` | `brand_count` |
| `client_lane.portal_item_opened` | `group`, `subject_type` |
| `client_lane.portal_signin_code_requested` | `resend` |
| `client_lane.portal_signin_verified` | — |
| `client_lane.portal_signin_failed` | `stage`, `reason`, `http_status` |
| `client_lane.portal_signed_out` | `surface` |
| `client_lane.client_access_changed` | `from`, `to`, `source` |
| `client_lane.client_access_change_failed` | `source`, `reason`, `http_status` |
| `client_lane.client_portal_link_copied` | — |
| `client_lane.client_portal_link_copy_failed` | `reason`, `http_status` |
| `client_lane.client_removed` | `access_level` |
| `client_lane.client_remove_failed` | `reason`, `http_status` |
| `client_lane.approver_suggestion_picked` | `subject_type`, `access_level` |

- [ ] **Step 6: Copy the contract notes — the `## Contract` section only, byte-identical**

The api plan updates the `## Contract` section of `api/docs/prd/client-lane-p0a/api.md` on `feature/daffa/vc-client-portal` (api repo). Replace ONLY the web file's `## Contract` section with the api's. The section runs from its `## Contract` heading up to (not including) the next `## ` heading. Every other section of `web.md` stays as it is. Then diff the two sections:

```bash
cd WT && /usr/bin/git -C /Users/alva.e202511001/Desktop/work/frndos-agentic/api show feature/daffa/vc-client-portal:docs/prd/client-lane-p0a/api.md > /tmp/client-portal-api.md && python3 - <<'PY'
import re
def section(text):
    start = text.index("\n## Contract") + 1
    end = text.index("\n## ", start + 3) + 1
    return start, end
api = open("/tmp/client-portal-api.md", encoding="utf-8").read()
path = "docs/prd/client-lane-p0a/web.md"
web = open(path, encoding="utf-8").read()
a0, a1 = section(api)
w0, w1 = section(web)
open(path, "w", encoding="utf-8").write(web[:w0] + api[a0:a1] + web[w1:])
web2 = open(path, encoding="utf-8").read()
b0, b1 = section(web2)
open("/tmp/client-portal-web-contract.md", "w", encoding="utf-8").write(web2[b0:b1])
open("/tmp/client-portal-api-contract.md", "w", encoding="utf-8").write(api[a0:a1])
PY
diff /tmp/client-portal-api-contract.md /tmp/client-portal-web-contract.md && echo IDENTICAL && /usr/bin/git diff --stat -- docs/prd/client-lane-p0a/web.md
```

Expected:
- `IDENTICAL`;
- a diffstat touching only lines inside the Contract section. `git diff` shows no change outside it.

If the api branch has no Contract update yet, stop and record "contract notes pending api plan" in the track. Never hand-write the block, and never overwrite the whole file.

Reconcile every **(assumed)** item in this plan's "API contract assumed" section against that Contract section. Each mismatch becomes a fix task in the track before the PR.

- [ ] **Step 7: Track file and commit**

Update `docs/tracks/client-portal.track.md`:
- tick Tasks 1–19;
- set the Status table to `Implementation | completed` and `PR | not_submitted`;
- append a session-log entry with:
  - commits since base (`git log --oneline "$BASE"..HEAD | wc -l`);
  - the gate results (tsc vs baseline, eslint, every suite, build);
  - the security-review summary;
  - the manual-pass results, or "PENDING (Daffa)";
  - the Lark rows;
  - the assumed-contract reconciliation outcome;
  - every expectation fixed during a mutation check;
  - every test-tooling fallback used (`set-cookie` header asserts, `user.paste` for `CodeInput`).

Keep `status: in_progress` in the frontmatter until the PR merges (CLAUDE.md track rules).

```bash
cd WT && /usr/bin/git add docs/tracks/client-portal.track.md docs/prd/client-lane-p0a/web.md && /usr/bin/git commit -F - <<'EOF'
docs(web): record gates, manual pass and contract notes for the client portal

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

Do NOT push and do NOT open a PR. The api deploys first (spec §8.2), and Daffa opens both PRs.

---
## Self-review (run against the spec, 2026-10-06)

**1. Spec coverage (web parts)**

| Spec | Where |
|---|---|
| §6.1 the portal route at `/s/{ws}/{brand}`, with static routes winning | Task 13. The route is `[token]/[brand]`, because Next forbids two dynamic names at one level; the build check is in Task 13, Step 5. |
| §6.1 BFF `/s/api/portal/[...path]`: reads `frnd_client`, forwards `X-Client-Session`, Origin check, no token in JS | Task 5. Task 6 adds the share-link sibling the review page needs. |
| §6.1 `/s/session` session exchange; cookie attributes | Task 7 (`/s/session/exchange`, `/s/session/code`), Task 4 (cookie) |
| §6.1 `?k=` capture on portal links; `/s` allowlisted; dark scope | Task 4 (middleware). The allowlist is already `/s`. `PortalFrame` is dark-scoped (Task 10). |
| §6.2 header, switcher with counts, name + "Sign out this device"; nav "Approvals (n)"; phone compaction | Task 10 |
| §6.3 summary line, Waiting on you cards, Waiting on others rows, viewer row, Decided rows + Show older, empty state, view-only notice | Task 1 (copy rules), Task 11 (page) |
| §6.4 sign-in: email → CodeInput → inbox, identical for any brand | Task 3 (state machine), Task 12 (screen), Task 13 (routing) |
| §6.5 review page: portal header + switcher, ← Approvals, Deciding as, Not opened / Opened / Decided, all_view notice in place of the bar, pins still placeable, unchanged without a session | Task 14 |
| §6.6 analytics | Task 9 (helpers) and Tasks 10–12 (wiring); Lark rows in Task 19 |
| §4.3 paths 1–3 on the web side | Task 7 (`?k=` exchange and request-link code), Task 5 (portal code verify) |
| §4.5 `403 view_only` | Task 14 (both catch blocks) |
| §7.2 Clients tab: columns, select, menu, confirm copy, empty state, analytics, flag | Tasks 15 and 16 |
| §7.3 web: picker on the suggestions endpoint, "view only" / "New client" tags, inline upgrade, analytics (bug 2) | Tasks 15 and 17 |
| §8.1 token, CSRF, enumeration, revocation, sign-out | Tasks 4–7, 12, 13; security review in Task 19 |
| §8.2 rollout: agency flag, `/s` unflagged, legacy `frnd_lane` honoured, api first | Task 16 (flag); the legacy lane is untouched (Tasks 6 and 14 keep the direct path); Task 19 (order) |
| §8.3 web tests: inbox grouping display, summary line, access-level labels, switcher visibility, proxy (Origin, header forwarding, no token in body) | Tasks 1, 2 and 5 |
| §8.3 manual: two devices, multi-brand, view-only, remove while open, three themes, phone width | Task 19, Step 4 |
| §9 component map | Tasks 10, 11, 12, 14, 16 and 17, with a mapping table per task. Two literal deviations (SelectMenu count, ActionMenu trigger) are named in Task 10. The Toast-only errors deviation is named in Task 12. No new frndOS component, and no v2 API change. |

**2. Placeholder scan:** no "TBD", "TODO", "similar to Task N" or "add error handling". Every step that changes code shows the code. Edits to existing files quote the exact text they replace (`DecisionPage.tsx` (a)–(o), `middleware.ts`, the Members page, `useApproverEmails.ts`, `publicApi.ts`, `laneCode.ts`).

**3. Type consistency:**
- `PortalSession { me, brand }` is used by Tasks 1, 14 and 13.
- `LaneAuth` / `SessionLane` (Task 6) is used by Task 14's `laneAuth`.
- `useUpdateClientAccess` takes `{ userId, accessLevel }` in Tasks 15, 16 and 17.
- `ApproverSuggestion.user_id` is used in Tasks 15 and 17.
- `portalErrorAction` (Task 2) is used by Tasks 8 and 11.
- `clientSessionCookie(token, expiresAt)` is used by Tasks 4, 5 and 7.
- `shouldExchangeLane({ lane, fresh })` is used by Tasks 4, 7, 13 and 14.
- `relay` / `callApi` / `jsonResponse` / `upstreamHeaders` (Task 5) are used by Tasks 6 and 7.
- `RAIL_CARD` is exported in Task 10 and used in Tasks 10 and 11.
- `approverTone` (Task 2) is used by Task 14's `ApproverPill`.
- Task 2's shell test and shell code carry a temporary cast; Task 14 removes it once `workspace.slug` is typed.

**4. Review Focus:** each of the five lines has its named test in the owning task (Tasks 5, 5+7, 4+7, 11, 14). The cheaper pins (header-less GET versus POST; sign-out clearing both cookies) are in Task 5.

**Spec ambiguities resolved here** (each also noted in the step that applies it):
1. `/s/session` "gains the session exchange". It is implemented as sub-routes `/s/session/exchange` and `/s/session/code`, so the existing GET/POST/DELETE contract of `/s/session` is untouched.
2. The request-link code verify (§4.3 path 2) issues a session. Page JS therefore no longer calls `public/lane/code/verify`; a route handler does (§6.1 "token never in JS").
3. With a session, the review page's own share-link calls must carry it, so a second BFF is added (`/s/api/share-links/*`). Without a session they still go direct ("behaves exactly as today").
4. When to trade a lane for a session:
   - only right after a `?k=` capture (the web-only `frnd_lane_new` marker), by POST from page JS;
   - never on GET, because mail scanners prefetch links and would create sessions and false "Opened" views;
   - not for legacy `frnd_lane` cookies without the marker, which keep working through `X-Lane-Code`.
5. A session that has no lane on the requested brand gets the plain sign-in screen (no hint), the same as no session.
6. The portal URL reuses the `[token]` segment for the workspace slug (a Next constraint).
7. The `SelectMenu` count, the `ActionMenu` trigger, and inline errors on public pages instead of the Toast: see Tasks 10 and 12.
