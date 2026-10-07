# Client portal — Insights (the brand share dashboard inside the portal) — Design

**Date:** 2026-10-07
**Author:** Daffa (with Claude)
**Status:** approved in chat 2026-10-07
**Builds on:** `2026-10-06-client-portal-from-share-links-design.md` (portal, `client.session`, lanes, access levels). This spec covers the portal's Insights tab: gap items 8 and 9 of the Mini client portal design.
**Repos:** `api`, `web`. Branch `feature/daffa/vc-client-portal` (continue).

## 1. Goal

A client opening `/s/{workspace}/{brand}` can open **Insights**. It shows the same read-only dashboard the brand's public share link shows today (`/share/brand/{slug}`: Overview, Campaigns, Business, Ads, Social Media, Influencers, ATL, Trends, Listening), but:
- it is gated by the **client's session and lane**, not by the public link;
- it shows only the tabs the agency opened **for clients**.

## 2. Decisions

| # | Decision | Why |
|---|---|---|
| I-1 | **Reuse the share pages, with access separated from presentation.** On the api, a brand-access resolver has two implementations: the public share link (slug + password) and the portal (client session + lane). Insight endpoints only ask "which brand may this request read". On the web, an `InsightSurface` context carries the transport, `basePath` and read-only capabilities, so one set of pages renders at `/share/brand/…` and at `/s/{ws}/{brand}/insights/…`. | Sustainable as the portal grows (Files, Calendar…): a new surface adds a resolver and a context, not a fork of 27 endpoints and ~30 components. Iframe and redirect were rejected: they need the public link on, can show its password wall, ignore the lane (revoking a client would not close Insights), and `/share/brand` bounces phones to /home. |
| I-2 | **Per-tab "Clients" visibility in Brand Settings → Insights Tabs, default OFF**, enforced server-side. It is independent of the public share link. | Least privilege. An agency can keep the public link off and still open tabs for clients, and the reverse. |
| I-3 | **Every access level** (`own`, `all_approve`, `all_view`) sees the Insights tabs opened for clients. | Insights is brand-level, not request-level. |
| I-4 | **Business and Listening can be opened for clients** like any tab. They show a small **"Sample data"** label wherever their data is illustrative: Business for every brand, Listening for non-demo brands. | Daffa's call. The label stops a client reading illustrative numbers as real. |
| I-5 | **Client payloads are trimmed**: no signal `ideations`, no report `createdBy`, and no reports shared in from other brands. | Agency-internal content. |
| I-6 | **Fix on the public share too:** hide "Review Signal" and "Ask a follow-up" (and the summary refresh) on the Overview when `isPublicView`. | They are live today and point at internal routes and the chat. |

## 3. api

### 3.1 Data

- New column on `brand_insights_tab_settings`: `client_visible` (boolean, default false).
- `InsightsTabResolver` gains `resolveForClients(Brand)`: the brand's resolved tabs with `is_visible = client_visible` (and the tab otherwise valid).
- The settings endpoints read and write `client_visible` per tab. They use the same permission as today's Insights Tabs settings.

### 3.2 Brand-access resolver

- New `App\Services\Insights\InsightBrandAccess` (interface) with `brandFor(Request): Brand` and `audience(): 'public'|'client'`.
  - `ShareLinkBrandAccess` is today's `resolveSlug` logic: `X-Share-Token` or `?share_token`, `link_enabled`, password.
  - `PortalBrandAccess` reads the brand that `client.session:brand` put on the request.
- `BrandShareInsightController` stops reading positional `$slug`. It takes the brand from the resolver bound for the route group, and its sub-ids come from `$request->route('id' | 'reportId' | 'content_id')`.
- A **tab guard** maps each endpoint to its tab key (`home`→overview, `reports*`→campaigns, `paid-media*`→paid-media, …).
  - For audience `client`, a tab that is not client-visible → 404.
  - For audience `public`, behaviour is unchanged.

### 3.3 Routes

- `public/portal/{workspaceSlug}/{brandSlug}/insight/*` mirrors all 27 share insight routes. It sits under `['throttle:public-portal', 'client.session:brand']` with `Cache-Control: no-store`.
- `GET public/portal/{workspaceSlug}/{brandSlug}/insight-info` returns `{brand_id, name, logo, tabs (resolveForClients), owned_media_table_view}`. The shape matches `getBrandResponse`.

### 3.4 Payload trim (audience `client` only)

- Signals: drop `ideations`.
- Reports: drop `createdBy`, and exclude reports whose source brand differs.

### 3.5 Tests (Pest, scratch DB)

- the resolver per audience;
- a client-hidden tab → 404, a client-visible tab → 200;
- no session → 401;
- a revoked lane → 404;
- the trims;
- the public share unchanged (the existing share tests stay green);
- the settings round-trip of `client_visible`.

## 4. web

### 4.1 Insight surface

- `PublicShareContext` (or a new `InsightSurfaceContext` that it becomes) carries `{ api: { client, prefix, headers }, basePath, isPublicView, audience }`.
- The ~31 share readers in `src/services/query.ts`, `labelling/api.ts` and `creative-analysis/api.ts` take the surface instead of `(slug, accessToken)`.
- The ~8 hardcoded `/share/brand/` hrefs use `basePath`.
- The share layout's tab and header logic is extracted into one shared `InsightSurfaceLayout`, used by both routes.

### 4.2 Portal

- Route `src/app/s/[token]/[brand]/insights/[[...tab]]/page.tsx`.
  - The transport is the portal BFF proxy (`/s/api/portal/{ws}/{brand}/insight/...`).
  - The proxy allowlist (`portalRouteOf`) widens to the insight GETs plus the reports query POST.
  - The middleware's portal regex widens to include the `insights` subpaths.
- `PortalNav` enables **Insights**. It shows only when at least one tab is client-visible.
- The Insights pages render inside the portal shell (top bar), follow the viewer's theme, and work on phones.
- **"Sample data"** label: a small pill in the tab header, shown on Business always and on Listening for non-demo brands.

### 4.3 Agency settings

- Brand Settings → Insights Tabs gains a **"Clients"** column. It is a toggle per tab (v2 `Checkbox`), default off.
- **"Preview as client"** opens the portal Insights view. It renders the client-visible tabs through the agency's own session, via a read-only preview mode on the settings page. It does not need a client lane.

### 4.4 Fix

`DailySummaryOverview`: hide "Review Signal", "Ask a follow-up" and refresh when `isPublicView`.

### 4.5 Analytics

- `client_lane.portal_insights_viewed {tab}`
- `insights_tab_client_visibility_changed {tab, visible}`
- `insights_preview_as_client_opened`

### 4.6 Tests

- **Pure rules (`bun test`):** tab mapping and client filtering, the "Sample data" rule, and the proxy allowlist.
- **Existing share tests stay green.**
- **Manual:** the public share link unchanged; the portal Insights with and without client-visible tabs; a revoked client; phone width; Midnight, Aurora and Daylight.

## 5. Out of scope

- Real data for Business and Listening.
- A per-client (rather than per-brand) Insights choice.
- Insights in the invite email.
